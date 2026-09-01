--!strict
-- Cart value/return resolution, currency mutation (�5.2/�4.1/�3.4), and
-- Level/XP/Total Level tracking (�3.2/�3.3). In-memory only (no persistence
-- -- that is Phase 8). Level/XP is kept here rather than a separate
-- LevelingService (Phase 4's own text allows either) because it is earned
-- in the exact same transaction as Cash (�3.2: XP = CashValue/5 per cart),
-- and Rebirth's reset touches both together -- splitting them would just
-- add a cross-service call for no separation-of-concerns benefit.
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
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local EconomyConfig = require(ReplicatedStorage.Shared.Configs.EconomyConfig)
local WorldData = require(ReplicatedStorage.Shared.Configs.WorldData)
local EconomyMath = require(ReplicatedStorage.Shared.Modules.EconomyMath)
local RemotesSetup = require(ReplicatedStorage.Shared.Modules.RemotesSetup)
local PushPowerService = require(script.Parent.PushPowerService)
local WorldService = require(script.Parent.WorldService)

export type TrainItem = {
	rarity: string,
	world: number,
	zone: number,
}

export type PlayerState = {
	cash: number,
	train: { TrainItem },
	currentLevel: number,
	currentXP: number,
	totalLevel: number,
	rebirthCount: number,
}

export type LevelState = {
	currentLevel: number,
	currentXP: number,
	totalLevel: number,
	rebirthCount: number,
}

local EconomyService = {}

local DWELL_STEP_SECONDS = 0.1

local playerStates: { [Player]: PlayerState } = {}
local isReturning: { [Player]: boolean } = {}
local remotesFolder: Folder

local function getState(player: Player): PlayerState
	local state = playerStates[player]
	if not state then
		state = {
			cash = 0,
			train = {},
			currentLevel = 1,
			currentXP = 0,
			totalLevel = 0,
			rebirthCount = 0,
		}
		playerStates[player] = state
	end
	return state
end

local function pushPlayerData(player: Player)
	local state = getState(player)
	local playerDataUpdated = remotesFolder:FindFirstChild("PlayerDataUpdated") :: RemoteEvent
	playerDataUpdated:FireClient(player, {
		cash = state.cash,
		trainCount = #state.train,
		currentLevel = state.currentLevel,
		currentXP = state.currentXP,
		xpForNextLevel = EconomyMath.GetXPRequired(state.currentLevel),
		totalLevel = state.totalLevel,
		rebirthCount = state.rebirthCount,
		rebirthPushPowerMultiplier = EconomyMath.GetRebirthPushPowerMultiplier(state.rebirthCount),
		rebirthCashMultiplier = EconomyMath.GetRebirthCashMultiplier(state.rebirthCount),
	})
end

-- Public API consumed by CartSpawnService when a claim finalizes.
function EconomyService.GetTrainCount(player: Player): number
	return #getState(player).train
end

function EconomyService.AddCartToTrain(player: Player, item: TrainItem)
	local state = getState(player)
	table.insert(state.train, item)
	pushPlayerData(player)
end

-- Public API consumed by UpgradeService (and any future currency sink) --
-- EconomyService remains the single owner of currency mutation (�5.2).
function EconomyService.GetCash(player: Player): number
	return getState(player).cash
end

function EconomyService.TrySpendCash(player: Player, amount: number): boolean
	local state = getState(player)
	if state.cash < amount then
		return false
	end
	state.cash -= amount
	pushPlayerData(player)
	return true
end

-- Public API consumed by PushPowerService (Rebirth Push Power Multiplier)
-- and RebirthService (eligibility check + reset).
function EconomyService.GetLevelState(player: Player): LevelState
	local state = getState(player)
	return {
		currentLevel = state.currentLevel,
		currentXP = state.currentXP,
		totalLevel = state.totalLevel,
		rebirthCount = state.rebirthCount,
	}
end

-- �4.4: resets Current Level/XP to base and increments rebirthCount. Total
-- Level, Cash, and every upgrade level except Push Power are untouched --
-- Push Power's own reset is UpgradeService's responsibility, called
-- separately within the same RequestRebirth handler (�4.4's "atomic"
-- requirement is about no exploitable window between the two, not that
-- they must be a single function call).
function EconomyService.PerformRebirthReset(player: Player): number
	local state = getState(player)
	state.currentLevel = 1
	state.currentXP = 0
	state.rebirthCount += 1
	pushPlayerData(player)
	return state.rebirthCount
end

-- �3.2: awards XP (CashValue/5, min 1, per cart) and cascades level-ups;
-- Total Level increments once per level gained and never decreases.
local function awardXPAndLevelUp(state: PlayerState, xpEarned: number)
	state.currentXP += xpEarned
	while true do
		local required = EconomyMath.GetXPRequired(state.currentLevel)
		if state.currentXP < required then
			break
		end
		state.currentXP -= required
		state.currentLevel += 1
		state.totalLevel += 1
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
-- gated by that Zone's requirement. Trains only ever contain cargo from a
-- single World in practice (claiming is gated to the player's current
-- World, �3.5.4/Phase 5), but this compares (world, zone) pairs directly
-- rather than assuming that to stay correct if that ever changes.
local function getReturnSpeedFactor(player: Player, state: PlayerState): number
	local maxWorld, maxZone = 1, 1
	for _, item in state.train do
		if item.world > maxWorld or (item.world == maxWorld and item.zone > maxZone) then
			maxWorld = item.world
			maxZone = item.zone
		end
	end
	return PushPowerService.GetSpeedFactorForZone(player, maxWorld, maxZone)
end

local function handleRequestReturnCarts(player: Player)
	if isReturning[player] then
		return { success = false, reason = "AlreadyReturning" }
	end

	local state = getState(player)

	if #state.train == 0 then
		return { success = false, reason = "TrainEmpty" }
	end

	if not isPlayerAtCorral(player) then
		return { success = false, reason = "NotAtCorral" }
	end

	isReturning[player] = true

	local speedFactor = getReturnSpeedFactor(player, state)
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
		if #state.train == 0 then
			isReturning[player] = nil
			return { success = false, reason = "TrainEmpty" }
		end
	end

	local rebirthCashMult = EconomyMath.GetRebirthCashMultiplier(state.rebirthCount)
	local total = 0
	local xpEarned = 0
	for _, item in state.train do
		local cashValue = EconomyMath.GetCartValue(item.world, item.zone, item.rarity :: any, rebirthCashMult)
		total += cashValue
		xpEarned += EconomyMath.GetXPFromCashValue(cashValue)
	end

	state.cash += total
	table.clear(state.train)
	awardXPAndLevelUp(state, xpEarned)
	isReturning[player] = nil
	pushPlayerData(player)

	return { success = true, cashEarned = total, newCash = state.cash, xpEarned = xpEarned }
end

function EconomyService.Init()
	remotesFolder = RemotesSetup.CreateAll()

	local requestReturnCarts = remotesFolder:FindFirstChild("RequestReturnCarts") :: RemoteFunction
	requestReturnCarts.OnServerInvoke = function(player: Player)
		return handleRequestReturnCarts(player)
	end

	Players.PlayerAdded:Connect(function(player: Player)
		getState(player)
		pushPlayerData(player)
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		playerStates[player] = nil
		isReturning[player] = nil
	end)

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
		local state = getState(player)
		awardXPAndLevelUp(state, amount)
		pushPlayerData(player)
	end

	print("[EconomyService] Init")
end

return EconomyService
