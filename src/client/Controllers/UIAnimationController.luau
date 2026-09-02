--!strict
-- Generic UI "juice" engine for the purchased UI pack adapted in Phase 9:
-- hover/press/ripple/rotation-punch on every GuiButton, slide-up+blur open/
-- close on every Frame whose name matches a button's name, and a toast
-- notification system. Ported from the pack's original StarterGui
-- LocalScript into a tracked Controller per §5.2's architecture rule
-- ("no logic lives in Gui scripts") -- the GUI itself stays Studio-authored
-- content (like Workspace level geometry has been since Phase 1), this
-- Controller is the only thing that drives it.
--
-- Entirely name-driven and data-agnostic: it knows nothing about Cash,
-- Levels, or any other game concept. Other Controllers (UIController,
-- LootController, IndexController, WorldController) push real data into
-- the same instances this Controller animates; the two layers don't
-- depend on each other.

local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")
local Lighting = game:GetService("Lighting")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local UIAnimationController = {}

local SCREEN_GUI_NAME = "ScreenGui"
local FRAMES_FOLDER_NAME = "Frames"

local NORMAL_SCALE = 1
local HOVER_SCALE = 1.1
local CLICK_SCALE = 0.88

local hoverTweenInfo = TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local unhoverTweenInfo = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local pressTweenInfo = TweenInfo.new(0.08, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)
local releaseTweenInfo = TweenInfo.new(0.4, Enum.EasingStyle.Elastic, Enum.EasingDirection.Out)

local ROTATION_PUNCH_ANGLE = 6

local RIPPLE_COLOR = Color3.new(1, 1, 1)
local RIPPLE_START_TRANSPARENCY = 0.45
local RIPPLE_SIZE_MULTIPLIER = 1.6
local RIPPLE_TIME = 0.45
local RIPPLE_CONTAINER_ZINDEX = 0

local FRAME_SLIDE_EXTRA_PADDING = 60
local frameOpenSlideInfo = TweenInfo.new(0.45, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local frameOpenFadeInfo = TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local frameCloseSlideInfo = TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local frameCloseFadeInfo = TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

local BLUR_SIZE = 18
local blurInTweenInfo = TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local blurOutTweenInfo = TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

local NOTIFICATION_DISPLAY_TIME = 2 -- longer than the pack's original 1s -- our toasts carry real information to read
local NOTIFICATION_STAGGER_TIME = 0.3
local notifGrowTweenInfo = TweenInfo.new(0.4, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local notifPopTweenInfo = TweenInfo.new(0.45, Enum.EasingStyle.Elastic, Enum.EasingDirection.Out)
local notifShrinkTweenInfo = TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

local OWN_HUD_WHITELIST = { Notifications = true }

local screenGui: ScreenGui
local framesFolder: Folder
local blurEffect: BlurEffect

local currentlyOpenFrame: Frame? = nil
local originalFrameData: { [Frame]: { Position: UDim2, BackgroundTransparency: number } } = {}
local hudElementsWeHid: { [GuiObject]: boolean } = {}

local function updateBlur(shouldShow: boolean)
	if not blurEffect then
		return
	end
	local targetSize = shouldShow and BLUR_SIZE or 0
	local info = shouldShow and blurInTweenInfo or blurOutTweenInfo
	TweenService:Create(blurEffect, info, { Size = targetSize }):Play()
end

local function hideVisibleGuiObjects(container: Instance, exceptChild: Instance)
	for _, child in container:GetChildren() do
		if child ~= exceptChild and not OWN_HUD_WHITELIST[child.Name] then
			if child:IsA("GuiObject") then
				if child.Visible then
					hudElementsWeHid[child] = true
					child.Visible = false
				end
			elseif child:IsA("Folder") then
				hideVisibleGuiObjects(child, exceptChild)
			end
		end
	end
end

local function hideOwnHud()
	hideVisibleGuiObjects(screenGui, framesFolder)
end

local function restoreOwnHud()
	for object in hudElementsWeHid do
		if object and object.Parent then
			object.Visible = true
		end
		hudElementsWeHid[object] = nil
	end
end

local function getOrCreateUIScale(guiObject: GuiObject): UIScale
	local uiScale = guiObject:FindFirstChildOfClass("UIScale")
	if not uiScale then
		uiScale = Instance.new("UIScale")
		uiScale.Scale = 1
		uiScale.Parent = guiObject
	end
	return uiScale
end

local function animateScale(uiScale: UIScale, targetScale: number, tweenInfo: TweenInfo)
	TweenService:Create(uiScale, tweenInfo, { Scale = targetScale }):Play()
end

local function punchRotation(button: GuiObject)
	local originalRotation = button:GetAttribute("_OrigRotation")
	if originalRotation == nil then
		originalRotation = button.Rotation
		button:SetAttribute("_OrigRotation", originalRotation)
	end

	local direction = (math.random(0, 1) == 0) and -1 or 1
	local kickInfo = TweenInfo.new(0.07, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)
	local settleInfo = TweenInfo.new(0.3, Enum.EasingStyle.Elastic, Enum.EasingDirection.Out)

	local kick = TweenService:Create(button, kickInfo, { Rotation = (originalRotation :: number) + (ROTATION_PUNCH_ANGLE * direction) })
	kick:Play()
	kick.Completed:Connect(function(state)
		if state == Enum.PlaybackState.Completed then
			TweenService:Create(button, settleInfo, { Rotation = originalRotation }):Play()
		end
	end)
end

local function getOrCreateRippleContainer(button: GuiObject): CanvasGroup
	local container = button:FindFirstChild("_RippleContainer") :: CanvasGroup?
	if container then
		return container
	end

	local newContainer = Instance.new("CanvasGroup")
	newContainer.Name = "_RippleContainer"
	newContainer.BackgroundTransparency = 1
	newContainer.BorderSizePixel = 0
	newContainer.Size = UDim2.new(1, 0, 1, 0)
	newContainer.ZIndex = RIPPLE_CONTAINER_ZINDEX
	newContainer.ClipsDescendants = true
	newContainer.Parent = button

	local existingCorner = button:FindFirstChildOfClass("UICorner")
	if existingCorner then
		existingCorner:Clone().Parent = newContainer
	end

	return newContainer
end

local function createRipple(button: GuiObject, inputPosition: Vector3?)
	local absPos = button.AbsolutePosition
	local absSize = button.AbsoluteSize
	if absSize.X <= 0 or absSize.Y <= 0 then
		return
	end

	local container = getOrCreateRippleContainer(button)

	local relX, relY = 0.5, 0.5
	if inputPosition then
		relX = (inputPosition.X - absPos.X) / absSize.X
		relY = (inputPosition.Y - absPos.Y) / absSize.Y
	end

	local ripple = Instance.new("Frame")
	ripple.Name = "_Ripple"
	ripple.AnchorPoint = Vector2.new(0.5, 0.5)
	ripple.BackgroundColor3 = RIPPLE_COLOR
	ripple.BackgroundTransparency = RIPPLE_START_TRANSPARENCY
	ripple.BorderSizePixel = 0
	ripple.Position = UDim2.new(relX, 0, relY, 0)
	ripple.Size = UDim2.new(0, 0, 0, 0)
	ripple.Parent = container

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = ripple

	local maxDimension = math.max(absSize.X, absSize.Y) * RIPPLE_SIZE_MULTIPLIER
	local rippleTween = TweenService:Create(ripple, TweenInfo.new(RIPPLE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = UDim2.new(0, maxDimension, 0, maxDimension),
		BackgroundTransparency = 1,
	})
	rippleTween:Play()
	rippleTween.Completed:Connect(function()
		ripple:Destroy()
	end)
end

local function getSlideDownOffset(frame: Frame): number
	local camera = Workspace.CurrentCamera
	local viewportHeight = camera and camera.ViewportSize.Y or 1080
	local framePosY = frame.AbsolutePosition.Y
	local frameHeight = frame.AbsoluteSize.Y
	local distanceToBottom = math.max(0, viewportHeight - framePosY)
	return distanceToBottom + frameHeight + FRAME_SLIDE_EXTRA_PADDING
end

local closeFrame: (frame: Frame, skipRestore: boolean?) -> ()
local openFrame: (frame: Frame) -> ()
local closeAllFrames: () -> ()

closeFrame = function(frame, skipRestore)
	local data = originalFrameData[frame]
	if not data or not frame.Visible then
		return
	end

	local offset = getSlideDownOffset(frame)
	local slideTween = TweenService:Create(frame, frameCloseSlideInfo, { Position = data.Position + UDim2.new(0, 0, 0, offset) })
	TweenService:Create(frame, frameCloseFadeInfo, { BackgroundTransparency = 1 }):Play()
	slideTween:Play()
	slideTween.Completed:Connect(function(state)
		if state == Enum.PlaybackState.Completed then
			frame.Visible = false
		end
	end)

	if currentlyOpenFrame == frame then
		currentlyOpenFrame = nil
	end

	if not skipRestore then
		updateBlur(false)
		restoreOwnHud()
	end
end

closeAllFrames = function()
	for frame in originalFrameData do
		if frame.Visible then
			closeFrame(frame, true)
		end
	end
	currentlyOpenFrame = nil
end

openFrame = function(frame)
	local data = originalFrameData[frame]
	if not data then
		return
	end
	if currentlyOpenFrame == frame and frame.Visible then
		return
	end

	closeAllFrames()

	local offset = getSlideDownOffset(frame)
	frame.Visible = true
	frame.BackgroundTransparency = 1
	frame.Position = data.Position + UDim2.new(0, 0, 0, offset)

	TweenService:Create(frame, frameOpenSlideInfo, { Position = data.Position }):Play()
	TweenService:Create(frame, frameOpenFadeInfo, { BackgroundTransparency = data.BackgroundTransparency }):Play()

	currentlyOpenFrame = frame
	updateBlur(true)
	hideOwnHud()
end

local function setupFrame(frame: Frame)
	if originalFrameData[frame] then
		return
	end
	originalFrameData[frame] = { Position = frame.Position, BackgroundTransparency = frame.BackgroundTransparency }

	local closeButton: GuiButton? = nil
	for _, descendant in frame:GetDescendants() do
		if descendant.Name == "Close" and descendant:IsA("GuiButton") then
			closeButton = descendant
			break
		end
	end

	if closeButton then
		closeButton.MouseButton1Click:Connect(function()
			closeFrame(frame)
		end)
	end
end

local function setupButton(button: GuiButton)
	if button:GetAttribute("_UIHandlerSetup") then
		return
	end
	button:SetAttribute("_UIHandlerSetup", true)

	local uiScale = getOrCreateUIScale(button)
	local isHovering = false
	local isPressed = false

	local matchingFrame = framesFolder:FindFirstChild(button.Name)
	if matchingFrame and matchingFrame:IsA("Frame") then
		setupFrame(matchingFrame)
	end

	button.MouseEnter:Connect(function()
		isHovering = true
		if not isPressed then
			animateScale(uiScale, HOVER_SCALE, hoverTweenInfo)
		end
	end)

	button.MouseLeave:Connect(function()
		isHovering = false
		if not isPressed then
			animateScale(uiScale, NORMAL_SCALE, unhoverTweenInfo)
		end
	end)

	button.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			isPressed = true
			animateScale(uiScale, CLICK_SCALE, pressTweenInfo)
			createRipple(button, input.Position)
		end
	end)

	button.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			isPressed = false
			animateScale(uiScale, isHovering and HOVER_SCALE or NORMAL_SCALE, releaseTweenInfo)
		end
	end)

	button.MouseButton1Click:Connect(function()
		punchRotation(button)

		if matchingFrame and matchingFrame:IsA("Frame") then
			if currentlyOpenFrame == matchingFrame and matchingFrame.Visible then
				closeFrame(matchingFrame)
			else
				openFrame(matchingFrame)
			end
		end
	end)
end

-- ============================================================
-- Notifications (public API for other Controllers)
-- ============================================================

local notificationsFrame: Frame
local notificationTemplates: { [string]: GuiObject } = {}
local notificationLayoutOrder = 0
local notificationQueue: { string } = {}
local isNotificationSequenceRunning = false
local NOTIFICATION_ENTER_DURATION = math.max(notifGrowTweenInfo.Time, notifPopTweenInfo.Time)

local function showNotification(templateName: string)
	local template = notificationTemplates[templateName]
	if not template then
		warn("[UIAnimationController] No notification template named: " .. templateName)
		return
	end

	local targetSize = (template :: any).Size

	local container = Instance.new("CanvasGroup")
	container.Name = "_Notification_" .. templateName
	container.BackgroundTransparency = 1
	container.BorderSizePixel = 0
	container.GroupTransparency = 1
	container.Size = UDim2.new(targetSize.X.Scale, targetSize.X.Offset, 0, 0)

	notificationLayoutOrder -= 1
	container.LayoutOrder = notificationLayoutOrder
	container.Parent = notificationsFrame

	local clone = template:Clone()
	clone.Visible = true
	clone.Size = UDim2.new(1, 0, 1, 0)
	clone.Position = UDim2.new(0, 0, 0, 0)
	clone.Parent = container

	local uiScale = Instance.new("UIScale")
	uiScale.Scale = 0.5
	uiScale.Parent = clone

	TweenService:Create(container, notifGrowTweenInfo, { Size = targetSize, GroupTransparency = 0 }):Play()
	TweenService:Create(uiScale, notifPopTweenInfo, { Scale = 1 }):Play()

	task.delay(NOTIFICATION_DISPLAY_TIME, function()
		if not container.Parent then
			return
		end
		local shrinkTween = TweenService:Create(container, notifShrinkTweenInfo, {
			Size = UDim2.new(targetSize.X.Scale, targetSize.X.Offset, 0, 0),
			GroupTransparency = 1,
		})
		shrinkTween:Play()
		shrinkTween.Completed:Connect(function(state)
			if state == Enum.PlaybackState.Completed then
				container:Destroy()
			end
		end)
	end)
end

-- Queued so overlapping calls (e.g. several Loot finds in one return) don't
-- stack their enter animations on top of each other.
function UIAnimationController.ShowNotification(templateName: string, overrideText: string?)
	if overrideText and notificationTemplates[templateName] then
		local template = notificationTemplates[templateName]
		local title = template:FindFirstChild("Info") and template.Info:FindFirstChild("Title")
		if title then
			(title :: TextLabel).Text = overrideText
		end
	end

	table.insert(notificationQueue, templateName)
	if isNotificationSequenceRunning then
		return
	end
	isNotificationSequenceRunning = true

	task.spawn(function()
		while #notificationQueue > 0 do
			local name = table.remove(notificationQueue, 1) :: string
			showNotification(name)
			task.wait(NOTIFICATION_ENTER_DURATION + NOTIFICATION_STAGGER_TIME)
		end
		isNotificationSequenceRunning = false
	end)
end

function UIAnimationController.OpenFrame(frameName: string)
	local frame = framesFolder:FindFirstChild(frameName)
	if frame and frame:IsA("Frame") then
		setupFrame(frame)
		openFrame(frame)
	end
end

function UIAnimationController.CloseAll()
	closeAllFrames()
	updateBlur(false)
	restoreOwnHud()
end

local function scanAndSetupButtons(root: Instance)
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("GuiButton") then
			setupButton(descendant)
		end
	end
end

function UIAnimationController.Init()
	screenGui = playerGui:WaitForChild(SCREEN_GUI_NAME) :: ScreenGui
	framesFolder = screenGui:WaitForChild(FRAMES_FOLDER_NAME) :: Folder
	notificationsFrame = screenGui:WaitForChild("Notifications") :: Frame

	blurEffect = Lighting:FindFirstChild("UIBlur") :: BlurEffect?
	if not blurEffect then
		local newBlur = Instance.new("BlurEffect")
		newBlur.Name = "UIBlur"
		newBlur.Size = 0
		newBlur.Parent = Lighting
		blurEffect = newBlur
	end

	for _, child in notificationsFrame:GetChildren() do
		if child:IsA("Frame") or child:IsA("ImageLabel") or child:IsA("CanvasGroup") then
			notificationTemplates[child.Name] = child
			child.Visible = false
		end
	end

	for _, frame in framesFolder:GetChildren() do
		if frame:IsA("Frame") then
			setupFrame(frame)
		end
	end

	scanAndSetupButtons(screenGui)

	screenGui.DescendantAdded:Connect(function(descendant)
		task.defer(function()
			if descendant:IsA("GuiButton") then
				setupButton(descendant)
			elseif descendant:IsA("Frame") and descendant.Parent == framesFolder then
				setupFrame(descendant)
			end
		end)
	end)

	print("[UIAnimationController] Init")
end

return UIAnimationController
