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
local TweenService = game:GetService("TweenService")
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

-- How long the fade in/out itself takes, at the start of the track and
-- again right before it loops back to the start -- long enough to read as
-- an intentional fade, short enough that the track still feels like it's
-- almost always at full volume.
local MUSIC_FADE_TIME = 2.5

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

-- Fades the track in at the start of every loop, then fades it back out
-- right before Roblox's own seamless Looped=true wrap -- this is an
-- envelope on top of `sound.Volume` (0..1), entirely separate from
-- `musicGroup.Volume` (the user's saved setting) -- the two multiply
-- together, so a mid-loop 0.6 setting still reads as loud as it should,
-- just fading in and out around it rather than snapping.
local function fadeIn(sound: Sound)
	sound.Volume = 0
	TweenService:Create(sound, TweenInfo.new(MUSIC_FADE_TIME, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), { Volume = 1 }):Play()
end

local function startFadeLoop(sound: Sound)
	fadeIn(sound)
	sound.DidLoop:Connect(function()
		fadeIn(sound)
	end)

	task.spawn(function()
		while sound.Parent do
			if sound.TimeLength > 0 then
				local remaining = sound.TimeLength - sound.TimePosition
				if remaining <= MUSIC_FADE_TIME then
					TweenService:Create(sound, TweenInfo.new(math.max(remaining, 0.05), Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), { Volume = 0 }):Play()
					task.wait(remaining + 0.05)
					continue
				end
			end
			task.wait(0.5)
		end
	end)
end

function SoundController.Init(initialSnapshot: { settings: { musicVolume: number?, sfxVolume: number? }? }?)
	musicGroup = getOrCreateGroup("Music")
	sfxGroup = getOrCreateGroup("SFX")
	musicGroup.Volume = DEFAULT_MUSIC_VOLUME
	sfxGroup.Volume = DEFAULT_SFX_VOLUME
	if initialSnapshot and initialSnapshot.settings then
		SoundController.ApplySettings(initialSnapshot.settings)
	end

	-- SoundGroup Volume is the user's saved setting; this Sound's own
	-- Volume is the fade envelope above -- the two multiply, never compound
	-- into something silently too quiet.
	musicSound = Instance.new("Sound")
	musicSound.Name = "BackgroundMusic"
	musicSound.SoundId = SoundConfig.BackgroundMusic
	musicSound.Looped = true
	musicSound.SoundGroup = musicGroup
	musicSound.Parent = SoundService
	musicSound:Play()
	startFadeLoop(musicSound)

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
