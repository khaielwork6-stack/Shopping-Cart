--!strict
-- §13/§7: single owner of audio playback and the two mixer SoundGroups
-- (Music, SFX) that the Settings screen's Music/Sound Effects toggles
-- actually control. Every other Controller plays a named SFX through
-- SoundController.PlaySFX instead of building its own raw Sound instance --
-- that's what makes the user's saved volume apply uniformly to every sound
-- in the game, present and future, without each site re-wiring it.
--
-- Boots first (client/init.client.luau) since UIAnimationController and
-- every other Controller call into this from their own Init.

local Players = game:GetService("Players")
local SoundService = game:GetService("SoundService")
local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SoundConfig = require(ReplicatedStorage.Shared.Configs.SoundConfig)

local SoundController = {}

local player = Players.LocalPlayer

-- Defaults mirror PlayerDataService's own DEFAULT_PLAYER_DATA.settings --
-- applied immediately at boot, before the server's real saved values
-- arrive, so there's never a silent/full-volume flash in between.
local DEFAULT_MUSIC_VOLUME = 0.5
local DEFAULT_SFX_VOLUME = 0.8

local musicGroup: SoundGroup
local sfxGroup: SoundGroup
local musicSound: Sound

local function getOrCreateGroup(name: string): SoundGroup
	local existing = SoundService:FindFirstChild(name)
	if existing and existing:IsA("SoundGroup") then
		return existing
	end
	local group = Instance.new("SoundGroup")
	group.Name = name
	group.Parent = SoundService
	return group
end

-- Plays a one-shot named SFX through the SFX mixer group. `overrides` lets a
-- caller tune per-play properties (e.g. PlaybackSpeed for a rarity pitch, or
-- a lower Volume for a sound that would otherwise dominate the mix) without
-- needing its own SoundGroup routing -- SoundGroup itself always stays SFX.
function SoundController.PlaySFX(name: string, overrides: { [string]: any }?): Sound?
	local id = SoundConfig[name]
	if not id then
		warn("[SoundController] No SFX configured for: " .. tostring(name))
		return nil
	end

	local sound = Instance.new("Sound")
	sound.Name = "SFX_" .. name
	sound.SoundId = id
	sound.Volume = 1
	sound.SoundGroup = sfxGroup
	if overrides then
		for key, value in overrides do
			(sound :: any)[key] = value
		end
	end
	sound.Parent = player:WaitForChild("PlayerGui")
	sound:Play()
	Debris:AddItem(sound, 6)
	return sound
end

-- Applies a (possibly partial) settings diff -- mirrors PlayerDataUpdated's
-- own diff-push convention (§5.2) rather than requiring a full settings
-- table on every call.
function SoundController.ApplySettings(settings: { musicVolume: number?, sfxVolume: number? })
	if settings.musicVolume ~= nil then
		musicGroup.Volume = settings.musicVolume
	end
	if settings.sfxVolume ~= nil then
		sfxGroup.Volume = settings.sfxVolume
	end
end

function SoundController.Init()
	musicGroup = getOrCreateGroup("Music")
	sfxGroup = getOrCreateGroup("SFX")
	musicGroup.Volume = DEFAULT_MUSIC_VOLUME
	sfxGroup.Volume = DEFAULT_SFX_VOLUME

	-- Volume is entirely the SoundGroup's job (driven by the user's saved
	-- 0-1 setting) -- the instance itself stays at full Volume so the two
	-- multipliers are never silently compounded into something too quiet.
	musicSound = Instance.new("Sound")
	musicSound.Name = "BackgroundMusic"
	musicSound.SoundId = SoundConfig.BackgroundMusic
	musicSound.Looped = true
	musicSound.Volume = 1
	musicSound.SoundGroup = musicGroup
	musicSound.Parent = SoundService
	musicSound:Play()

	local remotesFolder = ReplicatedStorage:WaitForChild("Remotes") :: Folder
	local playerDataUpdated = remotesFolder:FindFirstChild("PlayerDataUpdated") :: RemoteEvent
	playerDataUpdated.OnClientEvent:Connect(function(data: { settings: { musicVolume: number?, sfxVolume: number? }? })
		if data.settings ~= nil then
			SoundController.ApplySettings(data.settings)
		end
	end)

	print("[SoundController] Init")
end

return SoundController
