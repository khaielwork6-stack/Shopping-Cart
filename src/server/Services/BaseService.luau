--!strict
-- Phase 4 (GDD v3 §9): the Base system. Players place unsealed Loot items
-- into slots for passive income; a Lock/Vulnerable cycle runs visibly even
-- though nothing consumes the Vulnerable state yet (no steal mechanic until
-- Phase 6 -- the migration plan's own "isolate one system at a time" note).
-- Offline earnings are computed once at join from a server timestamp,
-- never a client-reported elapsed time (§18).
--
-- 5 physical plots exist in the Main Lane's Lobby (Studio content, see
-- Workspace.Worlds.World5_Airport.Lobby.BasePlots) -- the first 5 players to
-- join a server each get one. A 6th+ concurrent player still has real slot
-- data and still earns passive income; they just have no physical plot to
-- interact with this pass (a real scope limit, not a bug).
--
-- EconomyService is required at the top level for AddCash (§6.6: currency
-- mutation only ever goes through that one Service) -- safe, EconomyService
-- never requires this Service back. LootService likewise for the bag
-- transfer functions it now exposes (ReturnItemToBag/TakeItemFromBag).

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local EconomyConfig = require(ReplicatedStorage.Shared.Configs.EconomyConfig)
local LootData = require(ReplicatedStorage.Shared.Configs.LootData)
local EconomyMath = require(ReplicatedStorage.Shared.Modules.EconomyMath)
local RemotesSetup = require(ReplicatedStorage.Shared.Modules.RemotesSetup)
local RateLimiter = require(ReplicatedStorage.Shared.Modules.RateLimiter)
local PlayerDataService = require(script.Parent.PlayerDataService)
local EconomyService = require(script.Parent.EconomyService)
local LootService = require(script.Parent.LootService)

type BaseSlot = PlayerDataService.BaseSlot

local BaseService = {}

local PLOT_COUNT = 5
local LOCK_STATE_LOCKED = "Locked"
local LOCK_STATE_VULNERABLE = "Vulnerable"

type LockState = {
	state: string,
	changesAt: number, -- os.clock() timestamp of the next state flip
}

local remotesFolder: Folder
local plotAssignments: { [Player]: number } = {}
local plotNameplates: { [number]: TextLabel } = {}
local lockStates: { [Player]: LockState } = {}
local incomeAccumulator: { [Player]: number } = {} -- fractional cash carried between Heartbeat ticks

local function getSlots(player: Player): { BaseSlot }
	local data = PlayerDataService.Get(player)
	local targetCount = EconomyMath.GetBaseSlotCount(data.rebirthCount)
	-- Grow (never shrink) to match the player's current slot count -- a
	-- Rebirth can only ever add slots (§9.1), so existing indices stay valid.
	while #data.baseSlots < targetCount do
		table.insert(data.baseSlots, false)
	end
	return data.baseSlots
end

-- §13 QA: RequestPlayerDataSnapshot's source for this Service's slice.
function BaseService.GetSnapshot(player: Player): { [string]: any }
	local lock = lockStates[player]
	return {
		baseSlots = getSlots(player),
		baseLockState = lock and lock.state,
		baseLockChangesIn = lock and math.max(0, lock.changesAt - os.clock()),
	}
end

local function pushBaseData(player: Player)
	local playerDataUpdated = remotesFolder:FindFirstChild("PlayerDataUpdated") :: RemoteEvent
	playerDataUpdated:FireClient(player, BaseService.GetSnapshot(player))
end

local function totalIncomePerSec(player: Player): number
	local total = 0
	for _, slot in getSlots(player) do
		if slot and type(slot) == "table" then
			local item = LootData.GetItem(slot.itemId)
			if item then
				total += EconomyMath.GetItemIncomePerSec(item.SellValue)
			end
		end
	end
	return total
end

local function handleRequestPlaceItem(player: Player, itemId: string, slotIndex: number): { success: boolean, reason: string? }
	if not RateLimiter.Allow(player, "RequestPlaceItem", 10) then
		return { success = false, reason = "RateLimited" }
	end

	local item = LootData.GetItem(itemId)
	if not item then
		return { success = false, reason = "InvalidItem" }
	end

	local slots = getSlots(player)
	slotIndex = math.floor(slotIndex)
	if slotIndex < 1 or slotIndex > #slots then
		return { success = false, reason = "InvalidSlot" }
	end

	if not LootService.TakeItemFromBag(player, itemId) then
		return { success = false, reason = "ItemNotInBag" }
	end

	-- Swap, not overwrite -- whatever was already in this slot goes back to
	-- the bag before the new item takes its place.
	local existing = slots[slotIndex]
	if existing and type(existing) == "table" then
		if not LootService.ReturnItemToBag(player, existing.itemId) then
			-- Bag is full -- undo the take so nothing is silently destroyed.
			LootService.ReturnItemToBag(player, itemId)
			return { success = false, reason = "BagFull" }
		end
	end

	slots[slotIndex] = { itemId = itemId }
	pushBaseData(player)
	return { success = true }
end

local function handleRequestRemoveItem(player: Player, slotIndex: number): { success: boolean, reason: string? }
	if not RateLimiter.Allow(player, "RequestRemoveItem", 10) then
		return { success = false, reason = "RateLimited" }
	end

	local slots = getSlots(player)
	slotIndex = math.floor(slotIndex)
	if slotIndex < 1 or slotIndex > #slots then
		return { success = false, reason = "InvalidSlot" }
	end

	local existing = slots[slotIndex]
	if not existing or type(existing) ~= "table" then
		return { success = false, reason = "SlotEmpty" }
	end

	if not LootService.ReturnItemToBag(player, existing.itemId) then
		return { success = false, reason = "BagFull" }
	end

	slots[slotIndex] = false
	pushBaseData(player)
	return { success = true }
end

-- §9.4: computed once, right after load, from a server timestamp only.
local function grantOfflineEarnings(player: Player)
	local data = PlayerDataService.Get(player)
	if data.lastOnlineTimestamp <= 0 then
		return -- never saved before (brand-new player) -- nothing to pay out
	end

	local elapsed = math.min(os.time() - data.lastOnlineTimestamp, EconomyConfig.Base.OfflineCapSeconds)
	if elapsed <= 0 then
		return
	end

	local rate = totalIncomePerSec(player)
	if rate <= 0 then
		return
	end

	local earned = math.floor(rate * elapsed * EconomyConfig.Base.OfflineRate + 0.5)
	if earned <= 0 then
		return
	end

	EconomyService.AddCash(player, earned)

	local offlineEarningsReady = remotesFolder:FindFirstChild("OfflineEarningsReady") :: RemoteEvent
	offlineEarningsReady:FireClient(player, { cashEarned = earned, elapsedSeconds = elapsed })
end

-- §9.2: Locked -> Vulnerable -> Locked, looping automatically. Nothing
-- reacts to Vulnerable yet -- this only builds the timer and its visible
-- countdown (GetSnapshot above), per the migration plan's own note.
local function tickLockState(player: Player, dt: number)
	local lock = lockStates[player]
	if not lock then
		return
	end

	local remaining = lock.changesAt - os.clock()
	if remaining > 0 then
		return
	end

	if lock.state == LOCK_STATE_LOCKED then
		lock.state = LOCK_STATE_VULNERABLE
		lock.changesAt = os.clock() + EconomyConfig.Base.VulnerableSeconds
	else
		local rebirthCount = PlayerDataService.Get(player).rebirthCount
		lock.state = LOCK_STATE_LOCKED
		lock.changesAt = os.clock() + EconomyMath.GetBaseLockSeconds(rebirthCount)
	end
	pushBaseData(player)
end

local function assignPlot(player: Player)
	for plotIndex = 1, PLOT_COUNT do
		local taken = false
		for _, assigned in plotAssignments do
			if assigned == plotIndex then
				taken = true
				break
			end
		end
		if not taken then
			plotAssignments[player] = plotIndex
			local nameplate = plotNameplates[plotIndex]
			if nameplate then
				nameplate.Text = player.Name
			end
			return
		end
	end
	-- No free plot (6th+ concurrent player) -- they keep real slot data and
	-- still earn income, just with no physical plot this pass.
end

local function releasePlot(player: Player)
	local plotIndex = plotAssignments[player]
	if not plotIndex then
		return
	end
	plotAssignments[player] = nil
	local nameplate = plotNameplates[plotIndex]
	if nameplate then
		nameplate.Text = "Empty"
	end
end

local function findPlotOwner(plotIndex: number): Player?
	for player, assigned in plotAssignments do
		if assigned == plotIndex then
			return player
		end
	end
	return nil
end

-- Studio content: Workspace.Worlds.World5_Airport.Lobby.BasePlots.Plot<N>,
-- each with a Nameplate (BillboardGui TextLabel) and a Pedestals folder of
-- 8 Parts tagged with a SlotIndex attribute, each carrying a ProximityPrompt.
local function setupPlots()
	local lobby = Workspace:WaitForChild("Worlds"):WaitForChild("World5_Airport"):WaitForChild("Lobby")
	local basePlots = lobby:FindFirstChild("BasePlots")
	if not basePlots then
		warn("[BaseService] No BasePlots folder found in the Lobby -- physical plot interaction is disabled this session.")
		return
	end

	for plotIndex = 1, PLOT_COUNT do
		local plot = basePlots:FindFirstChild("Plot" .. plotIndex)
		if not plot then
			continue
		end

		local nameplate = plot:FindFirstChild("Nameplate", true)
		local nameplateLabel = nameplate and nameplate:FindFirstChildWhichIsA("TextLabel", true)
		if nameplateLabel then
			plotNameplates[plotIndex] = nameplateLabel :: TextLabel
			nameplateLabel.Text = "Empty"
		end

		local pedestals = plot:FindFirstChild("Pedestals")
		if not pedestals then
			continue
		end

		for _, pedestal in pedestals:GetChildren() do
			local slotIndex = pedestal:GetAttribute("SlotIndex")
			local prompt = pedestal:FindFirstChildWhichIsA("ProximityPrompt")
			if prompt and type(slotIndex) == "number" then
				prompt.Triggered:Connect(function(player: Player)
					if plotAssignments[player] ~= plotIndex then
						return -- not this player's own plot
					end

					local slots = getSlots(player)
					local existing = slots[slotIndex]
					if existing and type(existing) == "table" then
						handleRequestRemoveItem(player, slotIndex)
					else
						-- Simplest first-pass interaction (no drag/drop item
						-- picker UI yet): place the highest-value unsealed
						-- item in the bag.
						local bestItemId: string? = nil
						local bestValue = -1
						for _, entry in PlayerDataService.Get(player).lootBag do
							if not entry.sealed and entry.count > 0 then
								local itemData = LootData.GetItem(entry.itemId)
								if itemData and itemData.SellValue > bestValue then
									bestValue = itemData.SellValue
									bestItemId = entry.itemId
								end
							end
						end
						if bestItemId then
							handleRequestPlaceItem(player, bestItemId, slotIndex)
						end
					end
				end)
			end
		end
	end
end

function BaseService.Init()
	remotesFolder = RemotesSetup.CreateAll()

	local requestPlaceItem = remotesFolder:FindFirstChild("RequestPlaceItem") :: RemoteFunction
	requestPlaceItem.OnServerInvoke = function(player: Player, itemId: string, slotIndex: number)
		return handleRequestPlaceItem(player, itemId, slotIndex)
	end

	local requestRemoveItem = remotesFolder:FindFirstChild("RequestRemoveItem") :: RemoteFunction
	requestRemoveItem.OnServerInvoke = function(player: Player, slotIndex: number)
		return handleRequestRemoveItem(player, slotIndex)
	end

	setupPlots()

	Players.PlayerAdded:Connect(function(player: Player)
		PlayerDataService.WaitForLoad(player) -- see PlayerDataService's own comment on why this matters
		getSlots(player) -- ensure the array is grown to the right length before anything reads it
		grantOfflineEarnings(player)

		local rebirthCount = PlayerDataService.Get(player).rebirthCount
		lockStates[player] = { state = LOCK_STATE_LOCKED, changesAt = os.clock() + EconomyMath.GetBaseLockSeconds(rebirthCount) }
		incomeAccumulator[player] = 0

		assignPlot(player)
		pushBaseData(player)
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		releasePlot(player)
		lockStates[player] = nil
		incomeAccumulator[player] = nil
	end)

	RunService.Heartbeat:Connect(function(dt: number)
		for _, player in Players:GetPlayers() do
			tickLockState(player, dt)

			local rate = totalIncomePerSec(player)
			if rate > 0 then
				local acc = (incomeAccumulator[player] or 0) + rate * dt
				local wholeCash = math.floor(acc)
				if wholeCash > 0 then
					EconomyService.AddCash(player, wholeCash)
					acc -= wholeCash
				end
				incomeAccumulator[player] = acc
			end
		end
	end)

	print("[BaseService] Init")
end

return BaseService
