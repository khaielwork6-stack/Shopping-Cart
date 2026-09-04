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

local economyServiceCache: { GetLevelState: (Player) -> { totalLevel: number, rebirthCount: number } }? = nil
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

-- Lost Cart migration, Phase 2: bonus-World unlocks are now Rebirth-gated,
-- not Total-Level-gated -- each successful Rebirth is what can cross a
-- threshold, so this is called directly from RebirthService right after a
-- rebirth completes (event-driven) instead of polled every frame from
-- CartSpawnService's per-frame loop -- Rebirth count changes far too rarely
-- to justify a per-frame check. The Main Lane (IsMainLane) is skipped
-- entirely: it's always accessible and never fires a fanfare. �6.3: a World
-- unlock is one of the two events that force an immediate save alongside the
-- 3-minute autosave.
function WorldService.CheckWorldUnlocks(player: Player)
	local unlocked = getUnlockedSet(player)
	local rebirthCount = getEconomyService().GetLevelState(player).rebirthCount
	local changed = false

	for _, world in WorldData.Worlds do
		if not world.IsMainLane and not unlocked[world.Id] and rebirthCount >= world.RebirthRequirement then
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

-- Shared by the Portal handler and every character spawn (§13 QA below) --
-- the one place that actually moves a character into a World, so both
-- paths can never drift out of sync with each other.
--
-- §13: every World now has a dedicated Lobby before Zone 1 (no cart
-- spawns there) -- a player must always land in the Lobby, never straight
-- into Zone 1's gameplay, whether that's their first join, a respawn, or a
-- fresh Portal arrival. Falls back to Zone 1's own spawn anchor only if a
-- World is somehow missing its Lobby (should never happen post-§13, but a
-- missing Lobby shouldn't strand a player with no spawn at all).
local function teleportToWorldZone1(character: Model, worldId: number)
	local root = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local worldEntry = WorldData.GetWorld(worldId)
	local worldFolder = worldEntry and Workspace.Worlds:FindFirstChild(worldEntry.FolderName)
	if not (root and worldFolder) then
		return
	end

	local lobbySpawn = worldFolder:FindFirstChild("Lobby") and worldFolder.Lobby:FindFirstChild("LobbySpawnAnchor")
	if lobbySpawn then
		root.CFrame = (lobbySpawn :: BasePart).CFrame + Vector3.new(0, 4, 0)
	else
		local anchor = worldFolder.Zones.Zone1.ZoneSpawnPoints.SpawnPointAnchor :: BasePart
		root.CFrame = anchor.CFrame + Vector3.new(0, 4, -30) -- just ahead of Zone 1's spawn cluster
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

	-- World 1 rebalance: this map is now the game's actual starting World --
	-- the old Worlds 1-4 are disabled for now while they get rebuilt from
	-- scratch as real early/mid-game content (they're late-game-calibrated
	-- leftovers otherwise). Rebirth still runs and still tracks their
	-- unlock state (WorldService.CheckWorldUnlocks), it just has no
	-- player-facing effect until travel is re-enabled. Never disable travel
	-- back to the Main Lane itself.
	local destinationEntry = WorldData.GetWorld(destinationWorldId)
	if not destinationEntry then
		return { success = false, reason = "InvalidWorld" }
	end
	if not destinationEntry.IsMainLane then
		return { success = false, reason = "WorldsDisabled" }
	end

	if not WorldService.IsWorldUnlocked(player, destinationWorldId) then
		return { success = false, reason = "WorldLocked" }
	end

	PlayerDataService.Get(player).currentWorld = destinationWorldId

	local character = player.Character
	if character then
		teleportToWorldZone1(character, destinationWorldId)
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

	-- Phase 2 QA (playtest, Play Solo): PlayerAdded never fires for a player
	-- already in the game at the moment this Service's Init runs (WorldService
	-- is the 7th of 11 Services booted) -- the local test player can already
	-- exist by then, silently skipping both the initial teleport and the
	-- CharacterAdded re-teleport listener below, leaving them stranded at
	-- Roblox's generic default spawn instead of the Main Lane. Same
	-- already-may-exist principle as this function's own Character handling
	-- one level down, just one level up: handle players already present, in
	-- addition to (not instead of) every future PlayerAdded.
	local function onPlayerAdded(player: Player)
		PlayerDataService.WaitForLoad(player) -- see PlayerDataService's own comment on why this matters
		pushWorldData(player)

		-- §13 QA: real bug -- only the Portal handler ever physically moved a
		-- character to match currentWorld. Roblox's generic SpawnLocation
		-- (or a plain respawn) always drops a character in World1's physical
		-- space regardless of what World the player's save says they're in,
		-- so any player who was last in World 2-5 when they disconnected
		-- would rejoin standing in World1 while every server-side check
		-- (claim eligibility, Corral, Sell NPC) still used their persisted
		-- currentWorld -- carts they could see and walk into would just
		-- never claim, with no error, since heartbeatCheck was comparing
		-- their real position against the WRONG World's spawn points
		-- entirely. Fixed by re-teleporting on every spawn (initial join and
		-- every respawn after death), not just an explicit Portal use.
		--
		-- That alone wasn't enough, though (confirmed live): Roblox often
		-- spawns the character before this async WaitForLoad resolves, so a
		-- CharacterAdded connected only here would silently miss that very
		-- first spawn's event entirely, leaving a non-World1 player standing
		-- wherever Roblox's generic SpawnLocation put them -- physically in
		-- World1 -- until their *next* respawn or Portal use. Handle the
		-- character that may already exist too, in addition to (not instead
		-- of) every future spawn.
		if player.Character then
			teleportToWorldZone1(player.Character, WorldService.GetCurrentWorld(player))
		end
		player.CharacterAdded:Connect(function(character: Model)
			teleportToWorldZone1(character, WorldService.GetCurrentWorld(player))
		end)
	end

	Players.PlayerAdded:Connect(onPlayerAdded)
	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end

	print("[WorldService] Init")
end

return WorldService
