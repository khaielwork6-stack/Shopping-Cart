--!strict
-- Input handling, including touch-equivalents for every input path (mobile-
-- first pillar, §2.2/§5.2). Stub for Phase 0 -- full implementation begins
-- Phase 1. §13: owns the one input-driven SFX (Jump) since nothing else
-- currently has a dedicated home for character-input feedback.
--
-- Lost Cart GDD v3 �6.2/�19: dumping the back cart is PC's "Key" input.
-- Mobile's specified equivalent ("hold the train icon") needs a touch UI
-- element that doesn't exist yet -- Mobile UI is its own later phase in both
-- the GDD's �20 and the migration plan's �6, so only the PC keybind ships
-- here; a mobile player simply has no dump input until that phase lands.

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SoundController = require(script.Parent.SoundController)

local InputController = {}

local player = Players.LocalPlayer

local DUMP_CART_KEY = Enum.KeyCode.Q

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

	local remotesFolder = ReplicatedStorage:WaitForChild("Remotes") :: Folder
	local requestDumpCart = remotesFolder:WaitForChild("RequestDumpCart") :: RemoteEvent
	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessedEvent: boolean)
		if gameProcessedEvent then
			return
		end
		if input.KeyCode == DUMP_CART_KEY then
			requestDumpCart:FireServer()
		end
	end)

	print("[InputController] Init")
end

return InputController
