--!strict
-- Cart value/return resolution, currency mutation (�5.2/�4.1/�3.4), and
-- Level/XP/Total Level tracking (�3.2/�3.3). Level/XP is kept here rather
-- than a separate LevelingService (Phase 4's own text allows either)
-- because it is earned in the exact same transaction as Cash (�3.2: XP =
-- CashValue/5 per cart), and Rebirth's reset touches both together --
-- splitting them would just add a cross-service call for no separation-of-
-- concerns benefit.
--
-- Phase 8: cash/currentLevel/currentXP/totalLevel/rebirthCount now live in
-- PlayerDataService's persisted table instead of a private in-memory one.
-- The in-progress train (uncollected cart cargo) deliberately stays local
-- and unpersisted -- �4.1.4 states it's liquidated to Cash on disconnect,
-- not saved as raw cargo (see LiquidateTrainOnLeave).
--
-- Phase 3: the Corral return takes real time, gated by Push Power's
-- SpeedFactor over the highest-Zone item in the train (�4.2's "return-trip-
-- to-corral time") -- see EconomyConfig.Resistance for why this is the
-- chosen concrete mechanic.
--
-- Phase 4: Rebirth's Cash Multiplier is derived from rebirthCount at the
-- moment of each return (never stored redundantly, per �6.1's warning
-- against desyncable derived fields) via EconomyMath.GetRebirthCashMultiplier.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local EconomyConfig = require(ReplicatedStorage.Shared.Configs.EconomyConfig)
local WorldData = require(ReplicatedStorage.Shared.Configs.WorldData)
local CartData = require(ReplicatedStorage.Shared.Configs.CartData)
local LostCartData = require(ReplicatedStorage.Shared.Configs.LostCartData)
local EconomyMath = require(ReplicatedStorage.Shared.Modules.EconomyMath)
local RemotesSetup = require(ReplicatedStorage.Shared.Modules.RemotesSetup)
local RateLimiter = require(ReplicatedStorage.Shared.Modules.RateLimiter)
local CartVisuals = require(ReplicatedStorage.Shared.Modules.CartVisuals)
local CartTemplateLookup = require(ReplicatedStorage.Shared.Modules.CartTemplateLookup)
local PlayerDataService = require(script.Parent.PlayerDataService)
local PushPowerService = require(script.Parent.PushPowerService)
local WorldService = require(script.Parent.WorldService)
local LootService = require(script.Parent.LootService)
local MonetizationService = require(script.Parent.MonetizationService)
local UpgradeService = require(script.Parent.UpgradeService)

export type TrainItem = {
	rarity: string,
	world: number,
	zone: number,
	cartId: string?, -- Lost Cart GDD: which of the 23 real carts this is, for
	-- the train's visual model. Optional so any pre-Lost-Cart-system caller
	-- (none currently) still type-checks; cash value is still computed from
	-- world/zone/rarity only (see LostCartData's own comment on why).
	weight: number, -- Lost Cart GDD v3 �5.3: real kg, rolled once at claim time (Phase 3)
}

-- Lost Cart GDD v3 �6.2: a dumped cart sitting in the world, grabbable by
-- anyone (after a brief grace window) for a limited time.
type DroppedCart = {
	model: Model,
	item: TrainItem,
	claimableAt: number,
	expiresAt: number,
}

export type LevelState = {
	currentLevel: number,
	currentXP: number,
	totalLevel: number,
	rebirthCount: number,
}

local EconomyService = {}

local DWELL_STEP_SECONDS = 0.1

local trains: { [Player]: { TrainItem } } = {}
local isReturning: { [Player]: boolean } = {}
local droppedCarts: { [Model]: DroppedCart } = {}
local remotesFolder: Folder

local function getTrain(player: Player): { TrainItem }
	local train = trains[player]
	if not train then
		train = {}
		trains[player] = train
	end
	return train
end

-- §13 QA: also the RequestPlayerDataSnapshot aggregator's source for this
-- Service's slice (server/init.server.luau) -- the exact same fields this
-- Service would otherwise only push reactively, available as a synchronous
-- pull so the client's first render never has to race that push.
function EconomyService.GetSnapshot(player: Player): { [string]: any }
	local data = PlayerDataService.Get(player)
	return {
		cash = data.cash,
		trainCount = #getTrain(player),
		currentLevel = data.currentLevel,
		currentXP = data.currentXP,
		xpForNextLevel = EconomyMath.GetXPRequired(data.currentLevel),
		totalLevel = data.totalLevel,
		rebirthCount = data.rebirthCount,
		rebirthPushPowerMultiplier = EconomyMath.GetRebirthPushPowerMultiplier(data.rebirthCount),
		rebirthCashMultiplier = EconomyMath.GetRebirthCashMultiplier(data.rebirthCount),
		rebirthLuckMultiplier = EconomyMath.GetRebirthLuckMultiplier(data.rebirthCount),
	}
end

local function pushPlayerData(player: Player)
	local playerDataUpdated = remotesFolder:FindFirstChild("PlayerDataUpdated") :: RemoteEvent
	playerDataUpdated:FireClient(player, EconomyService.GetSnapshot(player))
end

-- Public API consumed by CartSpawnService when a claim finalizes.
function EconomyService.GetTrainCount(player: Player): number
	return #getTrain(player)
end

function EconomyService.AddCartToTrain(player: Player, item: TrainItem)
	table.insert(getTrain(player), item)
	pushPlayerData(player)
	UpgradeService.RefreshWalkSpeed(player) -- Lost Cart GDD v3 �6.1: Load just went up
end

-- Lost Cart GDD v3 �6.1: total real kg currently being hauled -- the Load
-- term in the Load-vs-PullPower speed curve. Public API consumed by
-- UpgradeService.RefreshWalkSpeed.
function EconomyService.GetTrainLoad(player: Player): number
	local total = 0
	for _, item in getTrain(player) do
		total += item.weight
	end
	return total
end

-- Public API consumed by UpgradeService (and any future currency sink) --
-- EconomyService remains the single owner of currency mutation (�5.2).
function EconomyService.GetCash(player: Player): number
	return PlayerDataService.Get(player).cash
end

function EconomyService.TrySpendCash(player: Player, amount: number): boolean
	local data = PlayerDataService.Get(player)
	if data.cash < amount then
		return false
	end
	data.cash -= amount
	pushPlayerData(player)
	return true
end

-- Public API consumed by LootService (Sell All / Sell x2) -- any currency
-- gain outside a cart return still flows through this single mutation
-- point (�6.6: no second code path may ever add Cash).
function EconomyService.AddCash(player: Player, amount: number)
	local data = PlayerDataService.Get(player)
	data.cash += amount
	pushPlayerData(player)
end

-- Public API consumed by PushPowerService (Rebirth Push Power Multiplier)
-- and RebirthService (eligibility check + reset).
function EconomyService.GetLevelState(player: Player): LevelState
	local data = PlayerDataService.Get(player)
	return {
		currentLevel = data.currentLevel,
		currentXP = data.currentXP,
		totalLevel = data.totalLevel,
		rebirthCount = data.rebirthCount,
	}
end

-- �4.4: resets Current Level/XP to base and increments rebirthCount. Total
-- Level, Cash, and every upgrade level except Push Power are untouched --
-- Push Power's own reset is UpgradeService's responsibility, called
-- separately within the same RequestRebirth handler (�4.4's "atomic"
-- requirement is about no exploitable window between the two, not that
-- they must be a single function call). �6.3: Rebirth is one of the two
-- events that force an immediate save alongside the 3-minute autosave.
function EconomyService.PerformRebirthReset(player: Player): number
	local data = PlayerDataService.Get(player)
	data.currentLevel = 1
	data.currentXP = 0
	data.rebirthCount += 1
	data.lifetimeStats.totalRebirths += 1
	pushPlayerData(player)
	PlayerDataService.RequestImmediateSave(player)
	return data.rebirthCount
end

-- �4.1.4: uncollected train cargo is liquidated to Cash (never XP, never a
-- Loot roll -- the Guide is specific that only "Cash value" is preserved)
-- the moment a player disconnects, rather than persisted as raw cargo.
-- Called by PlayerDataService just before it saves on leave/BindToClose.
function EconomyService.LiquidateTrainOnLeave(player: Player)
	local train = getTrain(player)
	if #train == 0 then
		return
	end

	local data = PlayerDataService.Get(player)
	local rebirthCashMult = EconomyMath.GetRebirthCashMultiplier(data.rebirthCount)
	local total = 0
	for _, item in train do
		total += EconomyMath.GetCartValue(item.zone, item.rarity :: any, rebirthCashMult)
	end

	data.cash += total
	table.clear(train)
end

-- §13 QA: in-memory cleanup only (the `trains`/`isReturning` keys, not
-- anything persisted) -- must run strictly after LiquidateTrainOnLeave has
-- read and cleared this player's train, so PlayerDataService's single
-- onPlayerRemoving handler calls this explicitly right after that, rather
-- than this Service racing it via its own separate PlayerRemoving
-- connection (see Init's comment on the bug that caused).
function EconomyService.CleanupPlayer(player: Player)
	trains[player] = nil
	isReturning[player] = nil
end

-- �3.2: awards XP (CashValue/5, min 1, per cart) and cascades level-ups;
-- Total Level increments once per level gained and never decreases.
local function awardXPAndLevelUp(data: PlayerDataService.PlayerDataSchema, xpEarned: number)
	data.currentXP += xpEarned
	while true do
		local required = EconomyMath.GetXPRequired(data.currentLevel)
		if data.currentXP < required then
			break
		end
		data.currentXP -= required
		data.currentLevel += 1
		data.totalLevel += 1
	end
end

-- Server-side "is the player inside the current World's Corral trigger"
-- check -- never trusts a client-reported position (�5.6). Phase 5: keyed
-- off WorldService's authoritative currentWorld, not hardcoded to World 1.
local function isPlayerAtCorral(player: Player): boolean
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return false
	end

	local worldId = WorldService.GetCurrentWorld(player)
	local worldEntry = WorldData.GetWorld(worldId)
	local worldFolder = worldEntry and Workspace:FindFirstChild("Worlds") and Workspace.Worlds:FindFirstChild(worldEntry.FolderName)
	local corral = worldFolder and worldFolder:FindFirstChild("Corral") :: BasePart?
	if not corral then
		return false
	end

	local relative = corral.CFrame:PointToObjectSpace(root.Position)
	local halfSize = corral.Size / 2
	return math.abs(relative.X) <= halfSize.X
		and math.abs(relative.Y) <= halfSize.Y + 5 -- generous vertical tolerance for a floor trigger
		and math.abs(relative.Z) <= halfSize.Z
end

-- �4.2: SpeedFactor over the highest-Zone item actually being carried --
-- a train made entirely of Zone 1 cargo returns at full speed regardless of
-- the player's current frontier; a train including frontier-Zone cargo is
-- gated by that Zone's requirement. World 1 economy rebalance: zone-only
-- now (see EconomyConfig.PushPower's own comment) -- World no longer
-- factors into this at all.
local function getReturnSpeedFactor(player: Player, train: { TrainItem }): number
	local maxZone = 1
	for _, item in train do
		if item.zone > maxZone then
			maxZone = item.zone
		end
	end
	return PushPowerService.GetSpeedFactorForZone(player, maxZone)
end

local function handleRequestReturnCarts(player: Player)
	if not RateLimiter.Allow(player, "RequestReturnCarts", 5) then
		return { success = false, reason = "RateLimited" }
	end

	if isReturning[player] then
		return { success = false, reason = "AlreadyReturning" }
	end

	local train = getTrain(player)

	if #train == 0 then
		return { success = false, reason = "TrainEmpty" }
	end

	if not isPlayerAtCorral(player) then
		return { success = false, reason = "NotAtCorral" }
	end

	isReturning[player] = true

	local speedFactor = getReturnSpeedFactor(player, train)
	local duration = EconomyConfig.Resistance.BaseReturnDuration / speedFactor

	local elapsed = 0
	while elapsed < duration do
		task.wait(DWELL_STEP_SECONDS)
		elapsed += DWELL_STEP_SECONDS

		if not player.Parent then
			isReturning[player] = nil
			return { success = false, reason = "PlayerLeft" }
		end
		if not isPlayerAtCorral(player) then
			isReturning[player] = nil
			return { success = false, reason = "LeftCorralEarly" }
		end
		if #train == 0 then
			isReturning[player] = nil
			return { success = false, reason = "TrainEmpty" }
		end
	end

	local data = PlayerDataService.Get(player)
	-- §12.2: 2x Cash/VIP multiply the same final Cash value the Rebirth
	-- multiplier already scales, never a separate/parallel path (§12's
	-- design constraint) -- XP scales with it too, consistent with how
	-- rebirthCashMult already flowed into XP before Monetization existed.
	local cashMultiplier = EconomyMath.GetRebirthCashMultiplier(data.rebirthCount) * MonetizationService.GetCashMultiplier(player)
	local total = 0
	local xpEarned = 0
	local cartsReturned = #train
	for _, item in train do
		local cashValue = EconomyMath.GetCartValue(item.zone, item.rarity :: any, cashMultiplier)
		total += cashValue
		xpEarned += EconomyMath.GetXPFromCashValue(cashValue)

		-- �4.5: per-cart Loot roll, independent of this Cash rarity roll.
		LootService.RollForCart(player)
	end

	data.cash += total
	data.lifetimeStats.totalCashEarned += total
	data.lifetimeStats.totalCartsReturned += cartsReturned
	local isPersonalBest = total > data.lifetimeStats.bestSingleReturn
	if isPersonalBest then
		data.lifetimeStats.bestSingleReturn = total
	end
	table.clear(train)
	awardXPAndLevelUp(data, xpEarned)
	isReturning[player] = nil
	pushPlayerData(player)
	UpgradeService.RefreshWalkSpeed(player) -- Lost Cart GDD v3 �6.1: Load just dropped to 0

	return {
		success = true,
		cashEarned = total,
		newCash = data.cash,
		xpEarned = xpEarned,
		isPersonalBest = isPersonalBest,
	}
end

-- Lost Cart GDD v3 �6.2/�10.2: unhooks the back cart (the last one inserted
-- -- matches TrainController's own trailing order, and its setTrainCount
-- shrink-from-the-end logic, so the visual train shrinks correctly for free
-- off the pushPlayerData below). Drops it in place as a real, grabbable
-- pickup for a limited time. Shared by the voluntary dump (§6.2, a longer
-- 20s grab window) and a Phase 5 bat hit landing on a hauling player
-- (§10.2, a shorter 15s window) -- same mechanic, two different callers,
-- one implementation.
local function dropLastCart(player: Player, grabDelaySeconds: number, despawnSeconds: number): boolean
	local train = getTrain(player)
	local item = table.remove(train)
	if not item then
		return false
	end

	pushPlayerData(player)
	UpgradeService.RefreshWalkSpeed(player) -- Load just dropped

	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return true -- disconnected mid-request; the cart is simply lost, not stranded in the void
	end

	-- Same shared visual modules TrainController already uses for the train
	-- itself (both live under ReplicatedStorage, safe to use server-side) --
	-- a dumped cart is already revealed, so it shows its real model, not a
	-- mystery cover.
	local template = CartTemplateLookup.Get(item.cartId)
	local model = CartVisuals.PrepareCart(template)
	local body = model.PrimaryPart :: BasePart
	body.CFrame = root.CFrame
	model.Parent = Workspace

	local now = os.clock()
	droppedCarts[model] = {
		model = model,
		item = item,
		claimableAt = now + grabDelaySeconds,
		expiresAt = now + despawnSeconds,
	}
	return true
end

local function handleRequestDumpCart(player: Player)
	if not RateLimiter.Allow(player, "RequestDumpCart", 5) then
		return
	end
	dropLastCart(player, EconomyConfig.Dump.GrabDelaySeconds, EconomyConfig.Dump.DespawnSeconds)
end

-- Phase 5 public API consumed by BatService -- a bat hit landing on a
-- hauling player drops their last cart the same way a voluntary dump does,
-- just with §10.2's own (shorter) grab window instead of §6.2's. Returns
-- whether a cart was actually dropped (false if the train was empty), so
-- BatService can skip firing knockback/VFX cues that only make sense when
-- something visibly hits the ground.
function EconomyService.DropLastCartFromHit(player: Player): boolean
	return dropLastCart(player, EconomyConfig.Bat.CartDropGrabSeconds, EconomyConfig.Dump.DespawnSeconds)
end

-- Proximity-based, not .Touched -- CartVisuals.PrepareCart sets CanTouch =
-- false on every part ("trains are visual, not physical"), so Touched would
-- never fire. Matches CartSpawnService.heartbeatCheck's own established
-- per-frame-proximity convention for world pickups.
local function dumpedCartHeartbeat()
	local now = os.clock()

	for model, dropped in droppedCarts do
		if now >= dropped.expiresAt then
			droppedCarts[model] = nil
			model:Destroy()
			continue
		end

		if now < dropped.claimableAt then
			continue
		end

		local body = model.PrimaryPart :: BasePart?
		if not body then
			continue
		end

		for _, player in Players:GetPlayers() do
			local character = player.Character
			local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
			if root and (root.Position - body.Position).Magnitude <= EconomyConfig.Collection.BaseClaimRadius then
				droppedCarts[model] = nil -- no double-claim

				EconomyService.AddCartToTrain(player, dropped.item)

				-- Same remote/payload shape CartSpawnService.tryClaimCart fires
				-- on an original claim, so LostCartRevealController's existing
				-- compress/burst/reveal ceremony plays anchored at the real
				-- drop position with zero new client code, then hands off into
				-- the grabber's train exactly like a fresh claim.
				local cartEntry = dropped.item.cartId and LostCartData.GetCart(dropped.item.cartId)
				local cartRevealed = remotesFolder:FindFirstChild("CartRevealed") :: RemoteEvent
				cartRevealed:FireClient(player, {
					cover = model,
					cartId = dropped.item.cartId,
					displayName = cartEntry and cartEntry.DisplayName or "???",
					rarity = dropped.item.rarity,
					isNew = false,
					mutation = nil,
				})

				local display = CartData.RarityDisplay[dropped.item.rarity :: any]
				local revealWindow = (display and display.RevealDuration or 0.3) + 0.35
				task.delay(revealWindow, function()
					if model.Parent then
						model:Destroy()
					end
				end)

				break -- claimed; stop checking other players for this cart
			end
		end
	end
end

function EconomyService.Init()
	remotesFolder = RemotesSetup.CreateAll()

	local requestReturnCarts = remotesFolder:FindFirstChild("RequestReturnCarts") :: RemoteFunction
	requestReturnCarts.OnServerInvoke = function(player: Player)
		return handleRequestReturnCarts(player)
	end

	local requestDumpCart = remotesFolder:FindFirstChild("RequestDumpCart") :: RemoteEvent
	requestDumpCart.OnServerEvent:Connect(handleRequestDumpCart)

	RunService.Heartbeat:Connect(dumpedCartHeartbeat)

	Players.PlayerAdded:Connect(function(player: Player)
		PlayerDataService.WaitForLoad(player) -- see PlayerDataService's own comment on why this matters
		getTrain(player)
		pushPlayerData(player)
	end)

	-- §13 QA: cleanup used to be its own Players.PlayerRemoving connection
	-- here, racing against PlayerDataService's own onPlayerRemoving (which
	-- calls LiquidateTrainOnLeave above) -- multiple listeners on the same
	-- signal have no guaranteed relative ordering, and live testing confirmed
	-- this one could win, wiping trains[player] before LiquidateTrainOnLeave
	-- ever read it and silently discarding a leaving player's uncollected
	-- Cash value. EconomyService.CleanupPlayer (below) replaces it, called
	-- explicitly and deterministically from that single handler instead.

	-- Command-Bar-only test hook (Phase 4's own Test Procedure explicitly
	-- sanctions "Command-Bar-grant XP for test speed" -- reaching Level 25
	-- through real play takes ~25 min per the Guide's own simulation, �3.9).
	-- A BindableFunction, not a RemoteFunction -- Bindables never cross the
	-- client/server boundary, so this is not reachable by any client under
	-- any circumstance, unlike a RemoteFunction would be.
	local debugGrantXP = Instance.new("BindableFunction")
	debugGrantXP.Name = "DebugGrantXP"
	debugGrantXP.Parent = script
	debugGrantXP.OnInvoke = function(player: Player, amount: number)
		local data = PlayerDataService.Get(player)
		awardXPAndLevelUp(data, amount)
		pushPlayerData(player)
	end

	print("[EconomyService] Init")
end

return EconomyService
