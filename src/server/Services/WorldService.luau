--!strict
-- World unlock checks, portal teleports (�5.2/�4.6/�4.7). Total-Level-gated
-- unlocking fires the instant a threshold is crossed, independent of the
-- player's current World (�5.6's Phase 5 note: a farming-in-an-old-World
-- player still gets the news).
--
-- EconomyService is required lazily: EconomyService needs this Service (to
-- find the current World's Corral) and this Service needs EconomyService
-- (for Total Level) -- a top-level require on both sides would deadlock,
-- same as the UpgradeService/PushPowerService edges from Phases 3-4.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local WorldData = require(ReplicatedStorage.Shared.Configs.WorldData)
local RemotesSetup = require(ReplicatedStorage.Shared.Modules.RemotesSetup)

local WorldService = {}

local currentWorld: { [Player]: number } = {}
local unlockedWorlds: { [Player]: { [number]: boolean } } = {}
local remotesFolder: Folder

local economyServiceCache: { GetLevelState: (Player) -> { totalLevel: number } }? = nil
local function getEconomyService()
	if not economyServiceCache then
		economyServiceCache = require(script.Parent.EconomyService) :: any
	end
	return economyServiceCache :: any
end

local function getUnlockedSet(player: Player): { [number]: boolean }
	local set = unlockedWorlds[player]
	if not set then
		set = { [1] = true } -- World 1 is always available (matches PushPowerService's Zone 1 base case)
		unlockedWorlds[player] = set
	end
	return set
end

function WorldService.GetCurrentWorld(player: Player): number
	return currentWorld[player] or 1
end

function WorldService.IsWorldUnlocked(player: Player, worldId: number): boolean
	return getUnlockedSet(player)[worldId] == true
end

local function pushWorldData(player: Player)
	local unlocked = getUnlockedSet(player)
	local list = {}
	for worldId in unlocked do
		table.insert(list, worldId)
	end
	table.sort(list)

	local playerDataUpdated = remotesFolder:FindFirstChild("PlayerDataUpdated") :: RemoteEvent
	playerDataUpdated:FireClient(player, {
		currentWorld = WorldService.GetCurrentWorld(player),
		unlockedWorlds = list,
	})
end

-- �4.6/�4.7: Total Level crossing a threshold unlocks that World instantly,
-- regardless of which World the player is currently in. Polled from
-- CartSpawnService's existing per-frame player loop (�4.1.1), same pattern
-- as PushPowerService.CheckZoneUnlocks.
function WorldService.CheckWorldUnlocks(player: Player)
	local unlocked = getUnlockedSet(player)
	local totalLevel = getEconomyService().GetLevelState(player).totalLevel
	local changed = false

	for _, world in WorldData.Worlds do
		if not unlocked[world.Id] and totalLevel >= world.TotalLevelRequirement then
			unlocked[world.Id] = true
			changed = true

			local worldUnlocked = remotesFolder:FindFirstChild("WorldUnlocked") :: RemoteEvent
			worldUnlocked:FireClient(player, { worldId = world.Id, worldName = world.Name })
		end
	end

	if changed then
		pushWorldData(player)
	end
end

-- Server-side "is the player inside this World's Zone 8 Portal trigger"
-- check would live here too, but per �9.4 the portal is a confirm-then-
-- teleport RemoteFunction, not a physical trigger volume -- the client
-- opens the confirmation after its own Touched detection (display-only),
-- and this handler re-validates everything that matters (unlock state)
-- server-side regardless of what the client claims.
local function handleRequestEnterWorldPortal(player: Player, destinationWorldId: number)
	if not WorldService.IsWorldUnlocked(player, destinationWorldId) then
		return { success = false, reason = "WorldLocked" }
	end

	local destination = WorldData.GetWorld(destinationWorldId)
	if not destination then
		return { success = false, reason = "InvalidWorld" }
	end

	currentWorld[player] = destinationWorldId

	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local worldFolder = Workspace.Worlds:FindFirstChild(destination.FolderName)
	if root and worldFolder then
		local anchor = worldFolder.Zones.Zone1.ZoneSpawnPoints.SpawnPointAnchor :: BasePart
		root.CFrame = anchor.CFrame + Vector3.new(0, 4, -30) -- just ahead of Zone 1's spawn cluster
	end

	pushWorldData(player)

	return { success = true, world = destinationWorldId }
end

function WorldService.Init()
	remotesFolder = RemotesSetup.CreateAll()

	local requestEnterWorldPortal = remotesFolder:FindFirstChild("RequestEnterWorldPortal") :: RemoteFunction
	requestEnterWorldPortal.OnServerInvoke = function(player: Player, destinationWorldId: number)
		return handleRequestEnterWorldPortal(player, destinationWorldId)
	end

	Players.PlayerAdded:Connect(function(player: Player)
		currentWorld[player] = 1
		getUnlockedSet(player)
		pushWorldData(player)
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		currentWorld[player] = nil
		unlockedWorlds[player] = nil
	end)

	print("[WorldService] Init")
end

return WorldService
