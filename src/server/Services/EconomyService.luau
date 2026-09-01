--!strict
-- Cart value/return resolution, currency mutation (�5.2/�4.1/�3.4). In-
-- memory only (no persistence -- that is Phase 8).
--
-- Phase 3: the Corral return now takes real time, gated by Push Power's
-- SpeedFactor over the highest-Zone item in the train (�4.2's "return-trip-
-- to-corral time") -- see EconomyConfig.Resistance for why this is the
-- chosen concrete mechanic. The RemoteFunction handler blocks for the
-- dwell duration and re-validates every tick, mirroring the existing
-- CollectTime dwell pattern from Phase 1/2 rather than inventing a new one.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local EconomyConfig = require(ReplicatedStorage.Shared.Configs.EconomyConfig)
local EconomyMath = require(ReplicatedStorage.Shared.Modules.EconomyMath)
local RemotesSetup = require(ReplicatedStorage.Shared.Modules.RemotesSetup)
local PushPowerService = require(script.Parent.PushPowerService)

export type TrainItem = {
	rarity: string,
	world: number,
	zone: number,
}

export type PlayerState = {
	cash: number,
	train: { TrainItem },
}

local EconomyService = {}

local REBIRTH_CASH_MULT = 1 -- Rebirth doesn't exist yet (Phase 4); base multiplier only
local DWELL_STEP_SECONDS = 0.1

local playerStates: { [Player]: PlayerState } = {}
local isReturning: { [Player]: boolean } = {}
local remotesFolder: Folder

local function getState(player: Player): PlayerState
	local state = playerStates[player]
	if not state then
		state = { cash = 0, train = {} }
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

-- Server-side "is the player inside the Corral trigger" check -- never
-- trusts a client-reported position (�5.6).
local function isPlayerAtCorral(player: Player): boolean
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return false
	end

	local world1 = Workspace:FindFirstChild("Worlds") and Workspace.Worlds:FindFirstChild("World1_ParkingLot")
	local corral = world1 and world1:FindFirstChild("Corral") :: BasePart?
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
-- gated by that Zone's requirement.
local function getReturnSpeedFactor(player: Player, state: PlayerState): number
	local maxZone = 1
	for _, item in state.train do
		if item.zone > maxZone then
			maxZone = item.zone
		end
	end
	return PushPowerService.GetSpeedFactorForZone(player, maxZone)
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

	local total = 0
	for _, item in state.train do
		total += EconomyMath.GetCartValue(item.world, item.zone, item.rarity :: any, REBIRTH_CASH_MULT)
	end

	state.cash += total
	table.clear(state.train)
	isReturning[player] = nil
	pushPlayerData(player)

	return { success = true, cashEarned = total, newCash = state.cash }
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

	print("[EconomyService] Init")
end

return EconomyService
