--!strict
-- Push Power / resistance state machine (�5.2/�4.2/�3.5). Tracks each
-- player's unlocked-Zone frontier (�3.5.4's 95% soft gate) and exposes
-- Effective Push Power / SpeedFactor for other Services to consume.
--
-- Index bonus (Phase 7) doesn't exist yet, held at its neutral value (1).
-- Rebirth Push Power Multiplier (Phase 4) is read from EconomyService,
-- lazily -- EconomyService already requires this Service at module top
-- level (for return-trip SpeedFactor), so a top-level require back would
-- deadlock Luau's loader; deferring to first-use breaks the cycle exactly
-- like UpgradeService's lazy EconomyService reference does.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local EconomyConfig = require(ReplicatedStorage.Shared.Configs.EconomyConfig)
local EconomyMath = require(ReplicatedStorage.Shared.Modules.EconomyMath)
local RemotesSetup = require(ReplicatedStorage.Shared.Modules.RemotesSetup)
local UpgradeService = require(script.Parent.UpgradeService)

local PushPowerService = {}

local CURRENT_WORLD = 1 -- Phase 3 is World 1 only; Phase 5 generalizes
local ZONES_PER_WORLD = EconomyConfig.Cart.ZonesPerWorld

local unlockedZoneIndex: { [Player]: number } = {}
local remotesFolder: Folder

local economyServiceCache: { GetLevelState: (Player) -> { rebirthCount: number } }? = nil
local function getEconomyService()
	if not economyServiceCache then
		economyServiceCache = require(script.Parent.EconomyService) :: any
	end
	return economyServiceCache :: any
end

local function getUnlocked(player: Player): number
	return unlockedZoneIndex[player] or 1
end

function PushPowerService.GetUnlockedZoneIndex(player: Player): number
	return getUnlocked(player)
end

function PushPowerService.GetEffectivePushPower(player: Player): number
	local level = UpgradeService.GetLevel(player, "pushPower")
	local rebirthCount = getEconomyService().GetLevelState(player).rebirthCount
	local rebirthPushPowerMultiplier = EconomyMath.GetRebirthPushPowerMultiplier(rebirthCount)
	return EconomyMath.GetEffectivePushPower(level, rebirthPushPowerMultiplier, 1) -- no Index bonus yet
end

function PushPowerService.GetSpeedFactorForZone(player: Player, zoneIndex: number): number
	local effectivePower = PushPowerService.GetEffectivePushPower(player)
	local requirement = EconomyMath.GetPowerRequirement(CURRENT_WORLD, zoneIndex)
	return EconomyMath.GetSpeedFactor(effectivePower, requirement)
end

local function pushZoneData(player: Player)
	local playerDataUpdated = remotesFolder:FindFirstChild("PlayerDataUpdated") :: RemoteEvent
	playerDataUpdated:FireClient(player, { unlockedZoneIndex = getUnlocked(player) })
end

-- Called whenever Push Power level might have changed (currently polled
-- from CartSpawnService's existing per-frame player loop, �4.1.1 --
-- avoids a UpgradeService<->PushPowerService circular require while still
-- reacting within one frame of a purchase).
function PushPowerService.CheckZoneUnlocks(player: Player)
	local current = getUnlocked(player)
	if current >= ZONES_PER_WORLD then
		return
	end

	local effectivePower = PushPowerService.GetEffectivePushPower(player)
	local changed = false

	while current < ZONES_PER_WORLD do
		local nextRequirement = EconomyMath.GetPowerRequirement(CURRENT_WORLD, current + 1)
		if EconomyMath.CanAdvanceToZone(effectivePower, nextRequirement) then
			current += 1
			changed = true
		else
			break
		end
	end

	if changed then
		unlockedZoneIndex[player] = current
		pushZoneData(player)

		local zoneUnlocked = remotesFolder:FindFirstChild("ZoneUnlocked") :: RemoteEvent
		zoneUnlocked:FireClient(player, { world = CURRENT_WORLD, zone = current })
	end
end

function PushPowerService.Init()
	remotesFolder = RemotesSetup.CreateAll()

	Players.PlayerAdded:Connect(function(player: Player)
		unlockedZoneIndex[player] = 1
		pushZoneData(player)
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		unlockedZoneIndex[player] = nil
	end)

	print("[PushPowerService] Init")
end

return PushPowerService
