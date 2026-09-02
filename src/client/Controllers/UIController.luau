--!strict
-- Top-level screen/state router (�5.2/�9) -- Phase 9 rewrite targeting the
-- adapted UI pack's actual instances (StarterGui.ScreenGui) instead of the
-- plain debug UI built in earlier phases. UIAnimationController owns all
-- the open/close/hover/click juice; this Controller only pushes real game
-- data into the same instances and wires the buttons that don't just open
-- a frame (Buy, Rebirth, Home, Settings toggles).
--
-- Also owns the client-side merged PlayerData cache, since PlayerDataUpdated
-- pushes diffs (�5.2) from multiple Services, not a single full replace.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")

local EconomyConfig = require(ReplicatedStorage.Shared.Configs.EconomyConfig)
local EconomyMath = require(ReplicatedStorage.Shared.Modules.EconomyMath)
local FormatNumber = require(ReplicatedStorage.Shared.Modules.FormatNumber)
local WorldData = require(ReplicatedStorage.Shared.Configs.WorldData)
local DeviceProfile = require(ReplicatedStorage.Shared.Modules.DeviceProfile)

local UIController = {}

local player = Players.LocalPlayer

local FILL_TWEEN_INFO = TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

-- Progress-bar fills are anchored (0, 0.5) so growing Size.X.Scale extends
-- purely left->right; tweening it (instead of snapping) is what makes XP/
-- Rebirth gains read as a smooth fill rather than an instant jump.
local function tweenFillWidth(fill: Frame, targetScale: number)
	TweenService:Create(fill, FILL_TWEEN_INFO, { Size = UDim2.new(targetScale, 0, fill.Size.Y.Scale, fill.Size.Y.Offset) }):Play()
end

local STAT_ORDER: { EconomyConfig.UpgradeStatName } = { "capacity", "agility", "mobility", "range", "pushPower" }

type PlayerDataCache = {
	cash: number,
	upgrades: { [string]: number },
	currentLevel: number,
	currentXP: number,
	xpForNextLevel: number,
	totalLevel: number,
	rebirthCount: number,
	rebirthPushPowerMultiplier: number,
	rebirthCashMultiplier: number,
	currentWorld: number,
	settings: { musicVolume: number, sfxVolume: number },
}

local cache: PlayerDataCache = {
	cash = 0,
	upgrades = { capacity = 0, agility = 0, mobility = 0, range = 0, pushPower = 0 },
	currentLevel = 1,
	currentXP = 0,
	xpForNextLevel = 20,
	totalLevel = 0,
	rebirthCount = 0,
	rebirthPushPowerMultiplier = 1,
	rebirthCashMultiplier = 1,
	currentWorld = 1,
	settings = { musicVolume = 0.5, sfxVolume = 0.8 },
}

local screenGui: ScreenGui
local uiAnimationController: any
local rebirthIconButton: TextButton

local function renderHud()
	local bottom = screenGui.Bottom
	bottom.Currencies.Cash.Amount.Text = "$" .. FormatNumber.Format(cache.cash)
	bottom.Currencies.Rebirths.Amount.Text = tostring(cache.rebirthCount)
	bottom.Currencies.TotalLevel.Amount.Text = "Total Level: " .. cache.totalLevel

	local pb = screenGui.ProgressBar.Frame
	pb.LEVEL.Text = "Level " .. cache.currentLevel
	pb.AMOUNT.Text = string.format("%d / %d XP", cache.currentXP, cache.xpForNextLevel)
	local fraction = cache.xpForNextLevel > 0 and (cache.currentXP / cache.xpForNextLevel) or 0
	tweenFillWidth(pb.Frame, math.clamp(fraction, 0, 1))
end

local function renderUpgrades()
	local grid = screenGui.Frames.Upgrades.ScrollingFrame.Upgrades
	for _, stat in STAT_ORDER do
		local card = grid:FindFirstChild(stat)
		if card then
			local level = cache.upgrades[stat] or 0
			local cost = EconomyMath.GetUpgradeCost(stat, level)
			card.Frame.Boost.Multiplier1.Text = tostring(level)
			card.Frame.Boost.Multiplier2.Text = tostring(level + 1)
			card.Frame.Choose.Money.Frame.Price.Text = "$" .. FormatNumber.Format(cost)
		end
	end
end

local function renderRebirth()
	local nextRebirthNumber = cache.rebirthCount + 1
	local requirement = EconomyMath.GetRebirthLevelRequirement(nextRebirthNumber)
	local nextPushMult = EconomyMath.GetRebirthPushPowerMultiplier(nextRebirthNumber)
	local nextCashMult = EconomyMath.GetRebirthCashMultiplier(nextRebirthNumber)
	local eligible = cache.currentLevel >= requirement

	local inner = screenGui.Frames.Rebirth.Frame
	inner.Boost.Multiplier1.Frame.Price.Text = string.format("x%.1f", cache.rebirthPushPowerMultiplier)
	inner.Boost.Multiplier2.Frame.Price.Text = string.format("x%.1f", nextPushMult)
	inner.ProgressBar.Progress.Text = string.format("Level %d / %d", cache.currentLevel, requirement)
	local fraction = requirement > 0 and (cache.currentLevel / requirement) or 0
	tweenFillWidth(inner.ProgressBar.Frame.Frame, math.clamp(fraction, 0, 1))

	inner.Buttons.Money.Frame.Price.Text = eligible and "Rebirth!" or "Not yet"

	-- The Rebirth icon button glows (pulses) when eligible -- this replaces
	-- the separate "Ready to Rebirth!" banner from the plain-UI version;
	-- the reset/keep info is always visible inside the panel itself instead
	-- of gating behind a second confirmation step (�4.4's spirit, simplified
	-- to match the pack's one-screen flow).
	if eligible then
		rebirthIconButton:SetAttribute("RebirthEligible", true)
	else
		rebirthIconButton:SetAttribute("RebirthEligible", false)
		local uiScale = rebirthIconButton:FindFirstChildOfClass("UIScale")
		if uiScale then
			uiScale.Scale = 1
		end
	end
end

local function startRebirthGlowLoop()
	task.spawn(function()
		while true do
			task.wait(0.05)
			if rebirthIconButton:GetAttribute("RebirthEligible") then
				local uiScale = rebirthIconButton:FindFirstChildOfClass("UIScale")
				if uiScale then
					local pulse = (math.sin(os.clock() * 4) + 1) / 2 -- 0..1
					uiScale.Scale = 1 + pulse * 0.08
				end
				local stroke = rebirthIconButton:FindFirstChildOfClass("UIStroke")
				if stroke then
					stroke.Color = Color3.fromHSV((os.clock() * 0.5) % 1, 0.6, 1)
				end
			end
		end
	end)
end

-- §8 "Level-up": a brief radial burst at the player's feet + a chime + the
-- HUD Level number punching up in scale once.
local function playLevelUpBurst()
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if root then
		local attachment = Instance.new("Attachment")
		attachment.Position = Vector3.new(0, -3, 0)
		attachment.Parent = root

		local emitter = Instance.new("ParticleEmitter")
		emitter.Color = ColorSequence.new(Color3.fromRGB(255, 255, 150))
		emitter.Lifetime = NumberRange.new(0.5, 0.7)
		emitter.Speed = NumberRange.new(8, 14)
		emitter.SpreadAngle = Vector2.new(180, 0)
		emitter.Size = NumberSequence.new(0.5)
		emitter.Rate = 0
		emitter.Parent = attachment

		emitter:Emit(DeviceProfile.ScaleParticleCount(24))
		Debris:AddItem(attachment, 1)
	end

	local sound = Instance.new("Sound")
	sound.Name = "PH_SFX_LevelUp"
	sound.Parent = player:WaitForChild("PlayerGui")
	sound:Play()
	Debris:AddItem(sound, 2)

	local levelLabel = screenGui.ProgressBar.Frame.LEVEL :: TextLabel
	local uiScale = levelLabel:FindFirstChildOfClass("UIScale")
	if not uiScale then
		uiScale = Instance.new("UIScale")
		uiScale.Parent = levelLabel
	end
	uiScale.Scale = 1.4
	TweenService:Create(uiScale, TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
end

-- §4.4/§8: the ~2-3s Rebirth ceremony -- camera pulls back (via FieldOfView,
-- so it never fights the built-in camera controller's CFrame ownership), a
-- light-burst VFX at the player, and a chime, all before the
-- RebirthComplete toast reveals the new multipliers. The reset itself has
-- already resolved server-side by the time this plays; this is purely the
-- ceremony §4.4 asks for layered on top.
local REBIRTH_CINEMATIC_DURATION = 2.2
local function playRebirthCinematic()
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	local originalFOV = camera.FieldOfView

	TweenService:Create(
		camera,
		TweenInfo.new(REBIRTH_CINEMATIC_DURATION * 0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ FieldOfView = originalFOV + 15 }
	):Play()

	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if root then
		local attachment = Instance.new("Attachment")
		attachment.Parent = root

		local emitter = Instance.new("ParticleEmitter")
		emitter.Color = ColorSequence.new(Color3.fromRGB(255, 255, 255))
		emitter.Lifetime = NumberRange.new(0.6, 1.0)
		emitter.Speed = NumberRange.new(6, 14)
		emitter.SpreadAngle = Vector2.new(180, 180)
		emitter.Size = NumberSequence.new(0.6)
		emitter.Rate = 0
		emitter.Parent = attachment

		emitter:Emit(DeviceProfile.ScaleParticleCount(50))
		Debris:AddItem(attachment, 2)
	end

	local sound = Instance.new("Sound")
	sound.Name = "PH_SFX_Rebirth"
	sound.Parent = player:WaitForChild("PlayerGui")
	sound:Play()
	Debris:AddItem(sound, 3)

	task.wait(REBIRTH_CINEMATIC_DURATION)

	TweenService:Create(camera, TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
		FieldOfView = originalFOV,
	}):Play()
end

local function setupHomeButton()
	local homeButton = screenGui.Top.Home
	homeButton.MouseButton1Click:Connect(function()
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		local worldEntry = WorldData.GetWorld(cache.currentWorld)
		if root and worldEntry then
			local worldFolder = Workspace:FindFirstChild("Worlds") and Workspace.Worlds:FindFirstChild(worldEntry.FolderName)
			if worldFolder then
				local anchor = worldFolder.Zones.Zone1.ZoneSpawnPoints.SpawnPointAnchor :: BasePart
				root.CFrame = anchor.CFrame + Vector3.new(0, 4, -30)
			end
		end
	end)
end

-- §8 "Upgrade purchase": a short SFX on every successful buy, alongside the
-- button's own micro-bounce/ripple (already handled generically by
-- UIAnimationController for every GuiButton).
local function playPurchaseSFX()
	local sound = Instance.new("Sound")
	sound.Name = "PH_SFX_Purchase"
	sound.Parent = player:WaitForChild("PlayerGui")
	sound:Play()
	Debris:AddItem(sound, 2)
end

local function setupUpgradeButtons(requestPurchaseUpgrade: RemoteFunction)
	local grid = screenGui.Frames.Upgrades.ScrollingFrame.Upgrades
	for _, stat in STAT_ORDER do
		local card = grid:FindFirstChild(stat)
		if card then
			card.Frame.Choose.Money.MouseButton1Click:Connect(function()
				local result = requestPurchaseUpgrade:InvokeServer(stat, 1) :: { success: boolean? }
				if result and result.success then
					playPurchaseSFX()
				end
			end)
		end
	end
end

local function setupRebirthButton(requestRebirth: RemoteFunction)
	local inner = screenGui.Frames.Rebirth.Frame
	inner.Buttons.Money.MouseButton1Click:Connect(function()
		local result = requestRebirth:InvokeServer() :: { success: boolean }
		if result and result.success then
			playRebirthCinematic()
			uiAnimationController.ShowNotification("RebirthComplete")
		end
	end)
end

-- �9.9 Settings: simplified to plain ON/OFF toggles rather than the pack's
-- drag-slider control (our schema stores a volume number, but a toggle is
-- far simpler to make reliable, and Phase 10 owns actually wiring real
-- audio -- this just persists the on/off intent).
local function setupSettingsToggles(requestUpdateSettings: RemoteFunction)
	local scrolling = screenGui.Frames.Settings.ScrollingFrame

	local function wireToggle(row: Frame, get: () -> number, set: (number) -> (), persist: (number) -> ())
		local button = row.Frame.Zipper.Frame.CanvasGroup.Button
		local priceLabel = button.Frame.Price
		local function render()
			priceLabel.Text = get() > 0 and "ON" or "OFF"
		end
		render()
		button.MouseButton1Click:Connect(function()
			local newValue = get() > 0 and 0 or 1
			set(newValue)
			render()
			persist(newValue)
		end)
	end

	wireToggle(scrolling.Music, function()
		return cache.settings.musicVolume
	end, function(v)
		cache.settings.musicVolume = v
	end, function(v)
		requestUpdateSettings:InvokeServer(v, nil)
	end)
	wireToggle(scrolling.Sound_Effects, function()
		return cache.settings.sfxVolume
	end, function(v)
		cache.settings.sfxVolume = v
	end, function(v)
		requestUpdateSettings:InvokeServer(nil, v)
	end)
end

function UIController.Init()
	local playerGui = player:WaitForChild("PlayerGui") :: PlayerGui
	screenGui = playerGui:WaitForChild("ScreenGui") :: ScreenGui
	rebirthIconButton = screenGui.Buttons.Left.Rebirth
	uiAnimationController = require(script.Parent.UIAnimationController)

	local remotesFolder = ReplicatedStorage:WaitForChild("Remotes") :: Folder
	local requestPurchaseUpgrade = remotesFolder:FindFirstChild("RequestPurchaseUpgrade") :: RemoteFunction
	local requestRebirth = remotesFolder:FindFirstChild("RequestRebirth") :: RemoteFunction
	local requestUpdateSettings = remotesFolder:FindFirstChild("RequestUpdateSettings") :: RemoteFunction

	setupUpgradeButtons(requestPurchaseUpgrade)
	setupRebirthButton(requestRebirth)
	setupHomeButton()
	setupSettingsToggles(requestUpdateSettings)
	startRebirthGlowLoop()

	renderHud()
	renderUpgrades()
	renderRebirth()

	-- PlayerDataUpdated pushes a diff (�5.2) -- merge whichever fields are
	-- present rather than assuming a full replace.
	local playerDataUpdated = remotesFolder:FindFirstChild("PlayerDataUpdated") :: RemoteEvent
	playerDataUpdated.OnClientEvent:Connect(function(data: {
		cash: number?,
		upgrades: { [string]: number }?,
		currentLevel: number?,
		currentXP: number?,
		xpForNextLevel: number?,
		totalLevel: number?,
		rebirthCount: number?,
		rebirthPushPowerMultiplier: number?,
		rebirthCashMultiplier: number?,
		currentWorld: number?,
	})
		if data.cash ~= nil then
			cache.cash = data.cash
		end
		if data.upgrades ~= nil then
			cache.upgrades = data.upgrades
		end
		if data.currentLevel ~= nil then
			if data.currentLevel > cache.currentLevel then
				playLevelUpBurst()
			end
			cache.currentLevel = data.currentLevel
		end
		if data.currentXP ~= nil then
			cache.currentXP = data.currentXP
		end
		if data.xpForNextLevel ~= nil then
			cache.xpForNextLevel = data.xpForNextLevel
		end
		if data.totalLevel ~= nil then
			cache.totalLevel = data.totalLevel
		end
		if data.rebirthCount ~= nil then
			cache.rebirthCount = data.rebirthCount
		end
		if data.rebirthPushPowerMultiplier ~= nil then
			cache.rebirthPushPowerMultiplier = data.rebirthPushPowerMultiplier
		end
		if data.rebirthCashMultiplier ~= nil then
			cache.rebirthCashMultiplier = data.rebirthCashMultiplier
		end
		if data.currentWorld ~= nil then
			cache.currentWorld = data.currentWorld
		end

		renderHud()
		renderUpgrades()
		renderRebirth()
	end)

	print("[UIController] Init")
end

return UIController
