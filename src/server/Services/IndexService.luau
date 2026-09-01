--!strict
-- First-discovery detection + passive Push Power bonus (�5.2/�4.6), and
-- this project's Luck source (�3.8/�7.3 -- see EconomyConfig.Index's
-- comment for why Index-completion was chosen). A leaf Service: nothing
-- else requires this one back, so every reference to it elsewhere is a
-- safe top-level require, no laziness needed.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local EconomyMath = require(ReplicatedStorage.Shared.Modules.EconomyMath)
local RemotesSetup = require(ReplicatedStorage.Shared.Modules.RemotesSetup)

local IndexService = {}

local discovered: { [Player]: { [string]: boolean } } = {}
local remotesFolder: Folder

local function getDiscoveredSet(player: Player): { [string]: boolean }
	local set = discovered[player]
	if not set then
		set = {}
		discovered[player] = set
	end
	return set
end

function IndexService.GetDiscoveredCount(player: Player): number
	local count = 0
	for _ in getDiscoveredSet(player) do
		count += 1
	end
	return count
end

function IndexService.IsDiscovered(player: Player, itemId: string): boolean
	return getDiscoveredSet(player)[itemId] == true
end

function IndexService.GetPushPowerBonus(player: Player): number
	return EconomyMath.GetIndexPushPowerBonus(IndexService.GetDiscoveredCount(player))
end

function IndexService.GetLuck(player: Player): number
	return EconomyMath.GetLuckFromDiscoveries(IndexService.GetDiscoveredCount(player))
end

local function pushIndexData(player: Player)
	local set = getDiscoveredSet(player)
	local list = {}
	for itemId in set do
		table.insert(list, itemId)
	end

	local playerDataUpdated = remotesFolder:FindFirstChild("PlayerDataUpdated") :: RemoteEvent
	playerDataUpdated:FireClient(player, {
		indexDiscovered = list,
		indexPushPowerBonus = IndexService.GetPushPowerBonus(player),
		luck = IndexService.GetLuck(player),
	})
end

-- �4.6: "the first time a given itemId is found, flip indexDiscovered[itemId]
-- = true"; subsequent finds of the same item are ordinary duplicates. This
-- is permanent and never resets on Rebirth (�6.1's schema, �4.6's own
-- explicit statement) -- nothing in this Service is ever cleared by
-- RebirthService. Returns true only on a genuine first discovery.
function IndexService.RecordDiscovery(player: Player, itemId: string): boolean
	local set = getDiscoveredSet(player)
	if set[itemId] then
		return false
	end

	set[itemId] = true
	pushIndexData(player)
	return true
end

function IndexService.Init()
	remotesFolder = RemotesSetup.CreateAll()

	Players.PlayerAdded:Connect(function(player: Player)
		getDiscoveredSet(player)
		pushIndexData(player)
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		discovered[player] = nil
	end)

	print("[IndexService] Init")
end

return IndexService
