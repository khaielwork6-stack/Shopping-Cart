--!strict
-- Input handling, including touch-equivalents for every input path (mobile-
-- first pillar, §2.2/§5.2). Stub for Phase 0 -- full implementation begins
-- Phase 1. §13: owns the one input-driven SFX (Jump) since nothing else
-- currently has a dedicated home for character-input feedback.

local Players = game:GetService("Players")

local SoundController = require(script.Parent.SoundController)

local InputController = {}

local player = Players.LocalPlayer

local function onCharacterAdded(character: Model)
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	humanoid.Jumping:Connect(function(active: boolean)
		if active then
			SoundController.PlaySFX("Jump")
		end
	end)
end

function InputController.Init()
	if player.Character then
		onCharacterAdded(player.Character)
	end
	player.CharacterAdded:Connect(onCharacterAdded)

	print("[InputController] Init")
end

return InputController
