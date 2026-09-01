--!strict
-- Top-level screen/state router (�5.2/�9). Phase 1: a temporary debug-
-- readable Cash label only -- the real HUD (�9.1) is built in Phase 9.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local UIController = {}

local player = Players.LocalPlayer

local function buildDebugHud(): TextLabel
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "DebugHud"
	screenGui.ResetOnSpawn = false
	screenGui.Parent = player:WaitForChild("PlayerGui")

	local label = Instance.new("TextLabel")
	label.Name = "CashLabel"
	label.AnchorPoint = Vector2.new(0, 0)
	label.Position = UDim2.new(0, 16, 0, 16)
	label.Size = UDim2.new(0, 220, 0, 32)
	label.BackgroundTransparency = 0.3
	label.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
	label.TextColor3 = Color3.fromRGB(255, 255, 255)
	label.Font = Enum.Font.GothamBold
	label.TextSize = 20
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Text = "Cash: 0"
	label.Parent = screenGui

	return label
end

function UIController.Init()
	local cashLabel = buildDebugHud()

	local remotesFolder = ReplicatedStorage:WaitForChild("Remotes") :: Folder
	local playerDataUpdated = remotesFolder:FindFirstChild("PlayerDataUpdated") :: RemoteEvent
	playerDataUpdated.OnClientEvent:Connect(function(data: { cash: number, trainCount: number })
		cashLabel.Text = string.format("Cash: %d   Train: %d", data.cash, data.trainCount)
	end)

	print("[UIController] Init")
end

return UIController
