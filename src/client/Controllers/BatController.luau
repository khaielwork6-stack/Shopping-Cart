--!strict
-- Phase 5 (GDD v3 §10): almost no logic lives here on purpose -- the swing
-- itself is server-driven via Tool.Activated (Roblox's own networking, no
-- custom RemoteEvent), and the ragdoll is a real server-owned Motor6D/
-- BallSocketConstraint change that replicates on its own. This Controller
-- only owns the cosmetic "you got hit" feedback, same
-- server-fires-a-cue-Controller-plays-VFX pattern as TrainController's
-- Legendary screen nudge.
--
-- No dedicated hit SFX yet -- every existing SoundConfig entry is themed
-- for UI/economy beats, not a physical impact, and guessing a new asset id
-- without being able to verify it risks a silently broken/wrong sound.
-- Camera-shake-only until a real "hit" SFX is sourced.

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BatController = {}

local player = Players.LocalPlayer

local SHAKE_OFFSET = 0.6
local SHAKE_INFO = TweenInfo.new(0.35, Enum.EasingStyle.Elastic, Enum.EasingDirection.Out)

local function playHitShake()
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end

	local signX = math.random(0, 1) == 0 and -1 or 1
	local signY = math.random(0, 1) == 0 and -1 or 1
	humanoid.CameraOffset = Vector3.new(signX, signY, 0).Unit * SHAKE_OFFSET
	TweenService:Create(humanoid, SHAKE_INFO, { CameraOffset = Vector3.zero }):Play()
end

function BatController.Init()
	local remotesFolder = ReplicatedStorage:WaitForChild("Remotes") :: Folder
	local playerKnockedDown = remotesFolder:WaitForChild("PlayerKnockedDown") :: RemoteEvent
	playerKnockedDown.OnClientEvent:Connect(function(_data: { attackerName: string })
		playHitShake()
	end)

	print("[BatController] Init")
end

return BatController
