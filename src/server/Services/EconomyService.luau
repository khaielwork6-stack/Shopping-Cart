--!strict
-- Cart value/return resolution, currency mutation (�5.2/�4.1/�3.4).
-- Phase 1: flat Common-only value at World1/Zone1, in-memory only (no
-- persistence -- that is Phase 8). Rarity variance is Phase 2.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local EconomyMath = require(ReplicatedStorage.Shared.Modules.EconomyMath)
local RemotesSetup = require(ReplicatedStorage.Shared.Modules.RemotesSetup)

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

local playerStates: { [Player]: PlayerState } = {}
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

local function handleRequestReturnCarts(player: Player)
	local state = getState(player)

	if #state.train == 0 then
		return { success = false, reason = "TrainEmpty" }
	end

	if not isPlayerAtCorral(player) then
		return { success = false, reason = "NotAtCorral" }
	end

	local total = 0
	for _, item in state.train do
		total += EconomyMath.GetCartValue(item.world, item.zone, item.rarity :: any, REBIRTH_CASH_MULT)
	end

	state.cash += total
	table.clear(state.train)
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
	end)

	print("[EconomyService] Init")
end

return EconomyService
