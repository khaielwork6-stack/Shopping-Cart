--!strict
-- World unlock checks, portal teleports (�5.2/�4.6/�4.7). Total-Level-gated
-- unlocking fires the instant a threshold is crossed, independent of the
-- player's current World (�5.6's Phase 5 note: a farming-in-an-old-World
-- player still gets the news).
--
-- Phase 8: currentWorld/unlockedWorlds now live in PlayerDataService's
-- persisted table. EconomyService is required lazily: EconomyService needs
-- this Service (to find the current World's Corral) and this Service needs
-- EconomyService (for Total Level) -- a top-level require on both sides
-- would deadlock, same as the UpgradeService/PushPowerService edges from
-- Phases 3-4. PlayerDataService is a leaf, so it's a safe top-level require.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local WorldData = require(ReplicatedStorage.Shared.Configs.WorldData)
local RemotesSetup = require(ReplicatedStorage.Shared.Modules.RemotesSetup)
local RateLimiter = require(ReplicatedStorage.Shared.Modules.RateLimiter)
local PlayerDataService = require(script.Parent.PlayerDataService)

local WorldService = {}

local remotesFolder: Folder

local economyServiceCache: { GetLevelState: (Player) -> { totalLevel: number } }? = nil
local function getEconomyService()
	if not economyServiceCache then
		economyServiceCache = require(script.Parent.EconomyService) :: any
	end
	return economyServiceCache :: any
end

local function getUnlockedSet(player: Player): { [number]: boolean }
	return PlayerDataService.Get(player).unlockedWorlds
end

function WorldService.GetCurrentWorld(player: Player): number
	return PlayerDataService.Get(player).currentWorld
end

function WorldService.IsWorldUnlocked(player: Player, worldId: number): boolean
	return getUnlockedSet(player)[worldId] == true
end

-- §13 QA: RequestPlayerDataSnapshot's source for this Service's slice.
function WorldService.GetSnapshot(player: Player): { [string]: any }
	local unlocked = getUnlockedSet(player)
	local list = {}
	for worldId in unlocked do
		table.insert(list, worldId)
	end
	table.sort(list)

	return {
		currentWorld = WorldService.GetCurrentWorld(player),
		unlockedWorlds = list,
	}
end

local function pushWorldData(player: Player)
	local playerDataUpdated = remotesFolder:FindFirstChild("PlayerDataUpdated") :: RemoteEvent
	playerDataUpdated:FireClient(player, WorldService.GetSnapshot(player))
end

-- �4.6/�4.7: Total Level crossing a threshold unlocks that World instantly,
-- regardless of which World the player is currently in. Polled from
-- CartSpawnService's existing per-frame player loop (�4.1.1), same pattern
-- as PushPowerService.CheckZoneUnlocks. �6.3: a World unlock is one of the
-- two events that force an immediate save alongside the 3-minute autosave.
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
		PlayerDataService.RequestImmediateSave(player)
	end
end

-- Server-side "is the player inside this World's Zone 8 Portal trigger"
-- check would live here too, but per �9.4 the portal is a confirm-then-
-- teleport RemoteFunction, not a physical trigger volume -- the client
-- opens the confirmation after its own Touched detection (display-only),
-- and this handler re-validates everything that matters (unlock state)
-- server-side regardless of what the client claims.
local function handleRequestEnterWorldPortal(player: Player, destinationWorldId: number)
	if not RateLimiter.Allow(player, "RequestEnterWorldPortal", 5) then
		return { success = false, reason = "RateLimited" }
	end

	if not WorldService.IsWorldUnlocked(player, destinationWorldId) then
		return { success = false, reason = "WorldLocked" }
	end

	local destination = WorldData.GetWorld(destinationWorldId)
	if not destination then
		return { success = false, reason = "InvalidWorld" }
	end

	PlayerDataService.Get(player).currentWorld = destinationWorldId

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
		PlayerDataService.WaitForLoad(player) -- see PlayerDataService's own comment on why this matters
		pushWorldData(player)
	end)

	print("[WorldService] Init")
end

return WorldService
