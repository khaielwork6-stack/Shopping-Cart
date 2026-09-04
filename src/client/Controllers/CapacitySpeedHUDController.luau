--!strict
-- Lost Cart GDD v3 §6.1: a persistent, always-visible readout for the two
-- numbers that used to be invisible -- "how full is my train" and "how much
-- is my train slowing me down." Studio-authored content (ScreenGui.
-- CapacitySpeedHUD, built to match the SELL/HOME/WORLDS pill-button
-- aesthetic already established) -- this Controller only pushes real data
-- into it and drives the tween/color/pulse feel, per §5.2's architecture
-- rule that no logic lives in Gui scripts.
--
-- Server is the one source of truth for both numbers (UpgradeService.
-- GetSnapshot already computes trainCapacity/trainSpeedFactor with the real
-- capacity-bonus and speed-curve math) -- this Controller never re-derives
-- either, just renders what it's told.

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CapacitySpeedHUDController = {}

local player = Players.LocalPlayer

local FILL_TWEEN_INFO = TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local PULSE_UP_INFO = TweenInfo.new(0.15, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local PULSE_DOWN_INFO = TweenInfo.new(0.35, Enum.EasingStyle.Elastic, Enum.EasingDirection.Out)

local SPEED_GREEN = Color3.fromRGB(120, 255, 130)
local SPEED_GREEN_DARK = Color3.fromRGB(60, 210, 90)
local SPEED_YELLOW = Color3.fromRGB(255, 221, 87)
local SPEED_YELLOW_DARK = Color3.fromRGB(230, 160, 30)
local SPEED_RED = Color3.fromRGB(255, 110, 100)
local SPEED_RED_DARK = Color3.fromRGB(210, 50, 45)

local SPEED_RED_THRESHOLD = 0.5
local SPEED_YELLOW_THRESHOLD = 0.85

local trainCount = 0
local trainCapacity = 1
local trainSpeedFactor = 1
local wasFull = false
local wasInRedZone = false

local capacityBar: Frame
local capacityFill: Frame
local capacityLabel: TextLabel
local speedBar: Frame
local speedFill: Frame
local speedFillGradient: UIGradient
local speedLabel: TextLabel

local function getOrCreateUIScale(guiObject: GuiObject): UIScale
	local uiScale = guiObject:FindFirstChildOfClass("UIScale")
	if not uiScale then
		uiScale = Instance.new("UIScale")
		uiScale.Scale = 1
		uiScale.Parent = guiObject
	end
	return uiScale
end

local function pulse(bar: Frame)
	local uiScale = getOrCreateUIScale(bar)
	local up = TweenService:Create(uiScale, PULSE_UP_INFO, { Scale = 1.12 })
	up:Play()
	up.Completed:Connect(function(state: Enum.PlaybackState)
		if state == Enum.PlaybackState.Completed then
			TweenService:Create(uiScale, PULSE_DOWN_INFO, { Scale = 1 }):Play()
		end
	end)
end

-- Two-stop lerp across three named colors (green -> yellow -> red), same
-- shape as the mutation-tier color ramps elsewhere in this project.
local function speedColor(factor: number): (Color3, Color3)
	if factor >= SPEED_YELLOW_THRESHOLD then
		local t = (factor - SPEED_YELLOW_THRESHOLD) / (1 - SPEED_YELLOW_THRESHOLD)
		return SPEED_YELLOW:Lerp(SPEED_GREEN, t), SPEED_YELLOW_DARK:Lerp(SPEED_GREEN_DARK, t)
	elseif factor >= SPEED_RED_THRESHOLD then
		local t = (factor - SPEED_RED_THRESHOLD) / (SPEED_YELLOW_THRESHOLD - SPEED_RED_THRESHOLD)
		return SPEED_RED:Lerp(SPEED_YELLOW, t), SPEED_RED_DARK:Lerp(SPEED_YELLOW_DARK, t)
	end
	return SPEED_RED, SPEED_RED_DARK
end

local function render()
	local capacityFraction = trainCapacity > 0 and math.clamp(trainCount / trainCapacity, 0, 1) or 0
	TweenService:Create(capacityFill, FILL_TWEEN_INFO, { Size = UDim2.new(capacityFraction, 0, 1, 0) }):Play()
	capacityLabel.Text = string.format("%d / %d", trainCount, trainCapacity)

	local isFull = trainCapacity > 0 and trainCount >= trainCapacity
	if isFull and not wasFull then
		pulse(capacityBar)
	end
	wasFull = isFull

	local speedFraction = math.clamp(trainSpeedFactor, 0, 1)
	TweenService:Create(speedFill, FILL_TWEEN_INFO, { Size = UDim2.new(speedFraction, 0, 1, 0) }):Play()
	speedLabel.Text = string.format("%d%%", math.floor(speedFraction * 100 + 0.5))

	-- TweenService can't interpolate a ColorSequence, so the gradient recolor
	-- itself is an instant swap -- only the fill WIDTH tweens smoothly above.
	local top, bottom = speedColor(speedFraction)
	speedFillGradient.Color = ColorSequence.new(top, bottom)

	local isInRedZone = speedFraction < SPEED_RED_THRESHOLD
	if isInRedZone and not wasInRedZone then
		pulse(speedBar)
	end
	wasInRedZone = isInRedZone
end

local function applyDataUpdate(data: { trainCount: number?, trainCapacity: number?, trainSpeedFactor: number? })
	local changed = false
	if data.trainCount ~= nil then
		trainCount = data.trainCount
		changed = true
	end
	if data.trainCapacity ~= nil then
		trainCapacity = data.trainCapacity
		changed = true
	end
	if data.trainSpeedFactor ~= nil then
		trainSpeedFactor = data.trainSpeedFactor
		changed = true
	end
	if changed then
		render()
	end
end

function CapacitySpeedHUDController.Init(initialSnapshot: { trainCount: number?, trainCapacity: number?, trainSpeedFactor: number? }?)
	local screenGui = player:WaitForChild("PlayerGui"):WaitForChild("ScreenGui") :: ScreenGui
	local hud = screenGui:WaitForChild("CapacitySpeedHUD") :: Frame

	capacityBar = hud:WaitForChild("Capacity") :: Frame
	capacityFill = capacityBar.Track.Fill
	capacityLabel = capacityBar.Track.Label
	speedBar = hud:WaitForChild("Speed") :: Frame
	speedFill = speedBar.Track.Fill
	speedFillGradient = speedFill:FindFirstChildOfClass("UIGradient") :: UIGradient
	speedLabel = speedBar.Track.Label

	-- Start at 0 width so the very first render tweens in rather than
	-- snapping, matching the game's general "everything eases in" feel.
	capacityFill.Size = UDim2.new(0, 0, 1, 0)
	speedFill.Size = UDim2.new(0, 0, 1, 0)

	if initialSnapshot then
		applyDataUpdate(initialSnapshot)
	end

	local remotesFolder = ReplicatedStorage:WaitForChild("Remotes") :: Folder
	local playerDataUpdated = remotesFolder:WaitForChild("PlayerDataUpdated") :: RemoteEvent
	playerDataUpdated.OnClientEvent:Connect(applyDataUpdate)

	print("[CapacitySpeedHUDController] Init")
end

return CapacitySpeedHUDController
