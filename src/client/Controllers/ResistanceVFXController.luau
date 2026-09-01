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
local ZoneData = require(ReplicatedStorage.Shared.Configs.ZoneData)
local EconomyMath = require(ReplicatedStorage.Shared.Modules.EconomyMath)

local ResistanceVFXController = {}

local CURRENT_WORLD = 1 -- Phase 3 is World 1 only
local ZONES_PER_WORLD = EconomyConfig.Cart.ZonesPerWorld

-- �4.2's named thresholds.
local HEAVY_THRESHOLD = 0.35
local LIGHT_THRESHOLD = 0.85

local player = Players.LocalPlayer
local cachedPushPowerLevel = 0
local dragEmitter: ParticleEmitter?
local zoneUnlockSound: Sound?

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

-- Three-tier VFX exactly per �4.2's pseudocode.
local function applyResistanceVFX(root: BasePart, speedFactor: number)
	local emitter = ensureDragEmitter(root)
	if speedFactor < HEAVY_THRESHOLD then
		emitter.Enabled = true
		emitter.Rate = 24
	elseif speedFactor < LIGHT_THRESHOLD then
		emitter.Enabled = true
		emitter.Rate = 8
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

	local zoneIndex = ZoneData.GetZoneIndexFromWorldZ(root.Position.Z, ZONES_PER_WORLD)
	local effectivePushPower = EconomyMath.GetEffectivePushPower(cachedPushPowerLevel, 1, 1)
	local requirement = EconomyMath.GetPowerRequirement(CURRENT_WORLD, zoneIndex)
	local speedFactor = EconomyMath.GetSpeedFactor(effectivePushPower, requirement)

	applyResistanceVFX(root, speedFactor)
end

local function playZoneUnlockFanfare()
	local world1 = Workspace:FindFirstChild("Worlds") and Workspace.Worlds:FindFirstChild("World1_ParkingLot")
	local corral = world1 and world1:FindFirstChild("Corral") :: BasePart?
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

	emitter:Emit(30)
	Debris:AddItem(attachment, 2)

	if zoneUnlockSound then
		zoneUnlockSound:Play()
	end
end

function ResistanceVFXController.Init()
	local remotesFolder = ReplicatedStorage:WaitForChild("Remotes") :: Folder

	-- PH_SFX_ZoneUnlock (�7): no SoundId set yet -- a future art pass fills
	-- this in; :Play() is already correctly wired.
	local sound = Instance.new("Sound")
	sound.Name = "PH_SFX_ZoneUnlock"
	sound.Parent = player:WaitForChild("PlayerGui")
	zoneUnlockSound = sound

	local playerDataUpdated = remotesFolder:FindFirstChild("PlayerDataUpdated") :: RemoteEvent
	playerDataUpdated.OnClientEvent:Connect(function(data: { upgrades: { [string]: number }? })
		if data.upgrades and data.upgrades.pushPower ~= nil then
			cachedPushPowerLevel = data.upgrades.pushPower
		end
	end)

	local zoneUnlocked = remotesFolder:FindFirstChild("ZoneUnlocked") :: RemoteEvent
	zoneUnlocked.OnClientEvent:Connect(function()
		playZoneUnlockFanfare()
	end)

	RunService.Heartbeat:Connect(onHeartbeat)

	print("[ResistanceVFXController] Init")
end

return ResistanceVFXController
