--!strict
-- Push Power / resistance state machine (�5.2/�4.2/�3.5). Tracks each
-- player's unlocked-Zone frontier PER WORLD (�3.5.4's 95% soft gate --
-- Phase 5 generalizes this from Phase 3's World-1-only version, since each
-- World has its own independent 8-Zone progression) and exposes Effective
-- Push Power / SpeedFactor for other Services to consume.
--
-- Index bonus (Phase 7) doesn't exist yet, held at its neutral value (1).
-- EconomyService (Rebirth multiplier) is required lazily -- it already
-- requires this Service at module top level (for return-trip SpeedFactor),
-- so a top-level require back would deadlock Luau's loader.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local EconomyConfig = require(ReplicatedStorage.Shared.Configs.EconomyConfig)
local EconomyMath = require(ReplicatedStorage.Shared.Modules.EconomyMath)
local RemotesSetup = require(ReplicatedStorage.Shared.Modules.RemotesSetup)
local UpgradeService = require(script.Parent.UpgradeService)
local WorldService = require(script.Parent.WorldService)

local PushPowerService = {}

local ZONES_PER_WORLD = EconomyConfig.Cart.ZonesPerWorld

local unlockedZoneIndex: { [Player]: { [number]: number } } = {}
local remotesFolder: Folder

local economyServiceCache: { GetLevelState: (Player) -> { rebirthCount: number } }? = nil
local function getEconomyService()
	if not economyServiceCache then
		economyServiceCache = require(script.Parent.EconomyService) :: any
	end
	return economyServiceCache :: any
end

local function getWorldUnlocks(player: Player): { [number]: number }
	local perWorld = unlockedZoneIndex[player]
	if not perWorld then
		perWorld = {}
		unlockedZoneIndex[player] = perWorld
	end
	return perWorld
end

local function getUnlocked(player: Player, worldId: number): number
	return getWorldUnlocks(player)[worldId] or 1
end

function PushPowerService.GetUnlockedZoneIndex(player: Player, worldId: number): number
	return getUnlocked(player, worldId)
end

function PushPowerService.GetEffectivePushPower(player: Player): number
	local level = UpgradeService.GetLevel(player, "pushPower")
	local rebirthCount = getEconomyService().GetLevelState(player).rebirthCount
	local rebirthPushPowerMultiplier = EconomyMath.GetRebirthPushPowerMultiplier(rebirthCount)
	return EconomyMath.GetEffectivePushPower(level, rebirthPushPowerMultiplier, 1) -- no Index bonus yet
end

function PushPowerService.GetSpeedFactorForZone(player: Player, worldId: number, zoneIndex: number): number
	local effectivePower = PushPowerService.GetEffectivePushPower(player)
	local requirement = EconomyMath.GetPowerRequirement(worldId, zoneIndex)
	return EconomyMath.GetSpeedFactor(effectivePower, requirement)
end

local function pushZoneData(player: Player, worldId: number)
	local playerDataUpdated = remotesFolder:FindFirstChild("PlayerDataUpdated") :: RemoteEvent
	playerDataUpdated:FireClient(player, {
		unlockedZoneIndex = getUnlocked(player, worldId),
		unlockedZoneIndexWorld = worldId,
	})
end

-- Called whenever Push Power level (or the player's current World) might
-- have changed (polled from CartSpawnService's existing per-frame player
-- loop, �4.1.1 -- avoids a circular require while still reacting within one
-- frame of a purchase or a Portal use). Only checks the player's CURRENT
-- World -- each World's frontier only matters while the player is there.
function PushPowerService.CheckZoneUnlocks(player: Player)
	local worldId = WorldService.GetCurrentWorld(player)
	local current = getUnlocked(player, worldId)
	if current >= ZONES_PER_WORLD then
		return
	end

	local effectivePower = PushPowerService.GetEffectivePushPower(player)
	local changed = false

	while current < ZONES_PER_WORLD do
		local nextRequirement = EconomyMath.GetPowerRequirement(worldId, current + 1)
		if EconomyMath.CanAdvanceToZone(effectivePower, nextRequirement) then
			current += 1
			changed = true
		else
			break
		end
	end

	if changed then
		getWorldUnlocks(player)[worldId] = current
		pushZoneData(player, worldId)

		local zoneUnlocked = remotesFolder:FindFirstChild("ZoneUnlocked") :: RemoteEvent
		zoneUnlocked:FireClient(player, { world = worldId, zone = current })
	end
end

function PushPowerService.Init()
	remotesFolder = RemotesSetup.CreateAll()

	Players.PlayerAdded:Connect(function(player: Player)
		getWorldUnlocks(player)
		pushZoneData(player, 1)
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		unlockedZoneIndex[player] = nil
	end)

	print("[PushPowerService] Init")
end

return PushPowerService
