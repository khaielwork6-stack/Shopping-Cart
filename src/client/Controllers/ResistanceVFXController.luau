--!strict
-- Client-side shadow SpeedFactor recalculation, display-only (�4.2/�5.5).
-- Recomputes the same formula the server uses, purely so the resistance
-- feel (heavy/light/none VFX tiers) updates every frame without a network
-- round-trip -- this copy is never trusted for anything reward-bearing;
-- the server's own SpeedFactor (inside EconomyService's return-trip dwell)
-- is the only one that actually gates Cash.
--
-- Also owns the one-time ZoneUnlocked fanfare (�4.2/�8): a particle burst
-- at the Corral + a placeholder chime (PH_SFX_ZoneUnlock -- see �7; no
-- SoundId set yet, correctly named so a future art pass can fill it in
-- without touching trigger code).

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local EconomyConfig = require(ReplicatedStorage.Shared.Configs.EconomyConfig)
local WorldData = require(ReplicatedStorage.Shared.Configs.WorldData)
local ZoneData = require(ReplicatedStorage.Shared.Configs.ZoneData)
local EconomyMath = require(ReplicatedStorage.Shared.Modules.EconomyMath)
local DeviceProfile = require(ReplicatedStorage.Shared.Modules.DeviceProfile)

local ResistanceVFXController = {}

local ZONES_PER_WORLD = EconomyConfig.Cart.ZonesPerWorld

-- �4.2's named thresholds.
local HEAVY_THRESHOLD = 0.35
local LIGHT_THRESHOLD = 0.85

local player = Players.LocalPlayer
local cachedPushPowerLevel = 0
local cachedCurrentWorld = 1
local cachedRebirthPushPowerMultiplier = 1
local cachedIndexPushPowerBonus = 1
local dragEmitter: ParticleEmitter?
local zoneUnlockSound: Sound?
local worldUnlockSound: Sound?

local function ensureDragEmitter(root: BasePart)
	if dragEmitter and dragEmitter.Parent then
		return dragEmitter
	end

	local attachment = Instance.new("Attachment")
	attachment.Name = "ResistanceDragAttachment"
	attachment.Position = Vector3.new(0, -2, 0)
	attachment.Parent = root

	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "PH_VFX_ResistanceDrag"
	emitter.Color = ColorSequence.new(Color3.fromRGB(180, 160, 130))
	emitter.Lifetime = NumberRange.new(0.3, 0.5)
	emitter.Speed = NumberRange.new(1, 2)
	emitter.Size = NumberSequence.new(0.4)
	emitter.Transparency = NumberSequence.new(0.4)
	emitter.Rate = 0
	emitter.Enabled = false
	emitter.Parent = attachment

	dragEmitter = emitter
	return emitter
end

-- Three-tier VFX exactly per §4.2's pseudocode. This is the one continuous
-- (not one-shot) emitter in the whole game -- it can run for as long as a
-- player is fighting through resistance -- so it's the highest-value place
-- for §11.7's mobile density scaling to actually matter.
local function applyResistanceVFX(root: BasePart, speedFactor: number)
	local emitter = ensureDragEmitter(root)
	if speedFactor < HEAVY_THRESHOLD then
		emitter.Enabled = true
		emitter.Rate = DeviceProfile.ScaleRate(24)
	elseif speedFactor < LIGHT_THRESHOLD then
		emitter.Enabled = true
		emitter.Rate = DeviceProfile.ScaleRate(8)
	else
		emitter.Enabled = false
		emitter.Rate = 0
	end
end

local function onHeartbeat()
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return
	end

	-- Z-banding is identical across every World (only X differs, per-World),
	-- so this needs no World-specific adjustment -- only which World's
	-- PowerRequirement table applies does.
	local zoneIndex = ZoneData.GetZoneIndexFromWorldZ(root.Position.Z, ZONES_PER_WORLD)
	local effectivePushPower = EconomyMath.GetEffectivePushPower(
		cachedPushPowerLevel,
		cachedRebirthPushPowerMultiplier,
		cachedIndexPushPowerBonus
	)
	local requirement = EconomyMath.GetPowerRequirement(cachedCurrentWorld, zoneIndex)
	local speedFactor = EconomyMath.GetSpeedFactor(effectivePushPower, requirement)

	applyResistanceVFX(root, speedFactor)
end

local function playZoneUnlockFanfare(sound: Sound?)
	local worldEntry = WorldData.GetWorld(cachedCurrentWorld)
	local worldFolder = worldEntry and Workspace:FindFirstChild("Worlds") and Workspace.Worlds:FindFirstChild(worldEntry.FolderName)
	local corral = worldFolder and worldFolder:FindFirstChild("Corral") :: BasePart?
	if not corral then
		return
	end

	local attachment = Instance.new("Attachment")
	attachment.Position = Vector3.new(0, 3, 0)
	attachment.Parent = corral

	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "PH_VFX_ZoneUnlockBurst"
	emitter.Color = ColorSequence.new(Color3.fromRGB(255, 230, 120))
	emitter.Lifetime = NumberRange.new(0.6, 0.9)
	emitter.Speed = NumberRange.new(8, 14)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Size = NumberSequence.new(0.8)
	emitter.Rate = 0
	emitter.Parent = attachment

	emitter:Emit(DeviceProfile.ScaleParticleCount(30))
	Debris:AddItem(attachment, 2)

	if sound then
		sound:Play()
	end
end

function ResistanceVFXController.Init()
	local remotesFolder = ReplicatedStorage:WaitForChild("Remotes") :: Folder
	local uiAnimationController = require(script.Parent.UIAnimationController)

	-- PH_SFX_ZoneUnlock / PH_SFX_WorldUnlock (�7): no SoundId set yet -- a
	-- future art pass fills these in; :Play() is already correctly wired.
	local zoneSound = Instance.new("Sound")
	zoneSound.Name = "PH_SFX_ZoneUnlock"
	zoneSound.Parent = player:WaitForChild("PlayerGui")
	zoneUnlockSound = zoneSound

	local worldSound = Instance.new("Sound")
	worldSound.Name = "PH_SFX_WorldUnlock"
	worldSound.Parent = player:WaitForChild("PlayerGui")
	worldUnlockSound = worldSound

	local playerDataUpdated = remotesFolder:FindFirstChild("PlayerDataUpdated") :: RemoteEvent
	playerDataUpdated.OnClientEvent:Connect(function(data: {
		upgrades: { [string]: number }?,
		currentWorld: number?,
		rebirthPushPowerMultiplier: number?,
		indexPushPowerBonus: number?,
	})
		if data.upgrades and data.upgrades.pushPower ~= nil then
			cachedPushPowerLevel = data.upgrades.pushPower
		end
		if data.currentWorld ~= nil then
			cachedCurrentWorld = data.currentWorld
		end
		if data.rebirthPushPowerMultiplier ~= nil then
			cachedRebirthPushPowerMultiplier = data.rebirthPushPowerMultiplier
		end
		if data.indexPushPowerBonus ~= nil then
			cachedIndexPushPowerBonus = data.indexPushPowerBonus
		end
	end)

	local zoneUnlocked = remotesFolder:FindFirstChild("ZoneUnlocked") :: RemoteEvent
	zoneUnlocked.OnClientEvent:Connect(function(data: { world: number, zone: number })
		playZoneUnlockFanfare(zoneUnlockSound)
		uiAnimationController.ShowNotification("ZoneUnlocked", "Zone " .. data.zone .. " unlocked!")
	end)

	-- §4.7/§8 World unlock sequence: reuses the same Corral-burst fanfare, but
	-- with its own SFX and a banner that names the actual new World per §8's
	-- requirement, not a generic message.
	local worldUnlocked = remotesFolder:FindFirstChild("WorldUnlocked") :: RemoteEvent
	worldUnlocked.OnClientEvent:Connect(function(data: { worldId: number, worldName: string })
		playZoneUnlockFanfare(worldUnlockSound)
		uiAnimationController.ShowNotification("ZoneUnlocked", data.worldName .. " unlocked!")
	end)

	RunService.Heartbeat:Connect(onHeartbeat)

	print("[ResistanceVFXController] Init")
end

return ResistanceVFXController
