--!strict
-- Top-level screen/state router (�5.2/�9). Phase 2: a temporary debug-
-- readable Cash/Train label plus a minimal, functional-but-unstyled Upgrade
-- Menu (�9.2's full styled version is Phase 9). Also owns the client-side
-- merged PlayerData cache, since PlayerDataUpdated pushes diffs (�5.2) from
-- multiple Services, not a single full replace.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local EconomyConfig = require(ReplicatedStorage.Shared.Configs.EconomyConfig)
local EconomyMath = require(ReplicatedStorage.Shared.Modules.EconomyMath)
local UpgradeData = require(ReplicatedStorage.Shared.Configs.UpgradeData)
local RebirthConfig = require(ReplicatedStorage.Shared.Configs.RebirthConfig)

local UIController = {}

local player = Players.LocalPlayer

local STAT_ORDER: { EconomyConfig.UpgradeStatName } = { "capacity", "agility", "mobility", "range", "pushPower" }

type PlayerDataCache = {
	cash: number,
	trainCount: number,
	upgrades: { [string]: number },
	unlockedZoneIndex: number,
	currentLevel: number,
	currentXP: number,
	xpForNextLevel: number,
	totalLevel: number,
	rebirthCount: number,
	rebirthPushPowerMultiplier: number,
	rebirthCashMultiplier: number,
}

local cache: PlayerDataCache = {
	cash = 0,
	trainCount = 0,
	upgrades = { capacity = 0, agility = 0, mobility = 0, range = 0, pushPower = 0 },
	unlockedZoneIndex = 1,
	currentLevel = 1,
	currentXP = 0,
	xpForNextLevel = 20,
	totalLevel = 0,
	rebirthCount = 0,
	rebirthPushPowerMultiplier = 1,
	rebirthCashMultiplier = 1,
}

local cashLabel: TextLabel
local pushPowerLabel: TextLabel
local levelLabel: TextLabel
local upgradeFrame: Frame
local upgradeRows: { [string]: { LevelLabel: TextLabel, CostLabel: TextLabel, BuyButton: TextButton } } = {}

local rebirthBanner: Frame
local rebirthModal: Frame
local rebirthBannerDismissed = false

local function buildDebugHud(playerGui: PlayerGui): TextLabel
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "DebugHud"
	screenGui.ResetOnSpawn = false
	screenGui.Parent = playerGui

	local label = Instance.new("TextLabel")
	label.Name = "CashLabel"
	label.Position = UDim2.new(0, 16, 0, 16)
	label.Size = UDim2.new(0, 260, 0, 32)
	label.BackgroundTransparency = 0.3
	label.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
	label.TextColor3 = Color3.fromRGB(255, 255, 255)
	label.Font = Enum.Font.GothamBold
	label.TextSize = 20
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Text = "Cash: 0"
	label.Parent = screenGui

	local pushLabel = Instance.new("TextLabel")
	pushLabel.Name = "PushPowerLabel"
	pushLabel.Position = UDim2.new(0, 16, 0, 52)
	pushLabel.Size = UDim2.new(0, 340, 0, 28)
	pushLabel.BackgroundTransparency = 0.3
	pushLabel.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
	pushLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	pushLabel.Font = Enum.Font.Gotham
	pushLabel.TextSize = 16
	pushLabel.TextXAlignment = Enum.TextXAlignment.Left
	pushLabel.Text = "Push Power: 0"
	pushLabel.Parent = screenGui
	pushPowerLabel = pushLabel

	local lvlLabel = Instance.new("TextLabel")
	lvlLabel.Name = "LevelLabel"
	lvlLabel.Position = UDim2.new(0, 16, 0, 88)
	lvlLabel.Size = UDim2.new(0, 420, 0, 28)
	lvlLabel.BackgroundTransparency = 0.3
	lvlLabel.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
	lvlLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	lvlLabel.Font = Enum.Font.Gotham
	lvlLabel.TextSize = 16
	lvlLabel.TextXAlignment = Enum.TextXAlignment.Left
	lvlLabel.Text = "Level 1"
	lvlLabel.Parent = screenGui
	levelLabel = lvlLabel

	return label
end

-- Functional, unstyled Upgrade Menu (�9.2). Full styled version is Phase 9.
local function buildUpgradeMenu(playerGui: PlayerGui, requestPurchaseUpgrade: RemoteFunction): Frame
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "UpgradeMenu"
	screenGui.ResetOnSpawn = false
	screenGui.Parent = playerGui

	local toggleButton = Instance.new("TextButton")
	toggleButton.Name = "ToggleButton"
	toggleButton.Position = UDim2.new(1, -136, 0, 16)
	toggleButton.Size = UDim2.new(0, 120, 0, 32)
	toggleButton.BackgroundColor3 = Color3.fromRGB(40, 100, 200)
	toggleButton.TextColor3 = Color3.fromRGB(255, 255, 255)
	toggleButton.Font = Enum.Font.GothamBold
	toggleButton.TextSize = 18
	toggleButton.Text = "Upgrades"
	toggleButton.Parent = screenGui

	local frame = Instance.new("Frame")
	frame.Name = "Panel"
	frame.Position = UDim2.new(1, -260, 0, 56)
	frame.Size = UDim2.new(0, 244, 0, #STAT_ORDER * 44 + 8)
	frame.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
	frame.BackgroundTransparency = 0.2
	frame.Visible = false
	frame.Parent = screenGui

	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 4)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = frame

	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, 4)
	padding.PaddingLeft = UDim.new(0, 4)
	padding.Parent = frame

	toggleButton.MouseButton1Click:Connect(function()
		frame.Visible = not frame.Visible
	end)

	for index, stat in STAT_ORDER do
		local display = UpgradeData.Display[stat]

		local row = Instance.new("Frame")
		row.Name = stat
		row.LayoutOrder = index
		row.Size = UDim2.new(1, -8, 0, 40)
		row.BackgroundColor3 = Color3.fromRGB(35, 35, 35)
		row.Parent = frame

		local nameLabel = Instance.new("TextLabel")
		nameLabel.Size = UDim2.new(0.4, 0, 1, 0)
		nameLabel.BackgroundTransparency = 1
		nameLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
		nameLabel.Font = Enum.Font.GothamBold
		nameLabel.TextSize = 14
		nameLabel.TextXAlignment = Enum.TextXAlignment.Left
		nameLabel.Text = display.DisplayName
		nameLabel.Parent = row

		local levelLabel = Instance.new("TextLabel")
		levelLabel.Name = "LevelLabel"
		levelLabel.Position = UDim2.new(0.4, 0, 0, 0)
		levelLabel.Size = UDim2.new(0.25, 0, 1, 0)
		levelLabel.BackgroundTransparency = 1
		levelLabel.TextColor3 = Color3.fromRGB(200, 200, 200)
		levelLabel.Font = Enum.Font.Gotham
		levelLabel.TextSize = 12
		levelLabel.Text = "Lv 0"
		levelLabel.Parent = row

		local buyButton = Instance.new("TextButton")
		buyButton.Name = "BuyButton"
		buyButton.Position = UDim2.new(0.65, 0, 0, 2)
		buyButton.Size = UDim2.new(0.35, -4, 1, -4)
		buyButton.BackgroundColor3 = Color3.fromRGB(60, 160, 80)
		buyButton.TextColor3 = Color3.fromRGB(255, 255, 255)
		buyButton.Font = Enum.Font.GothamBold
		buyButton.TextSize = 13
		buyButton.Text = "Buy: --"
		buyButton.Parent = row

		buyButton.MouseButton1Click:Connect(function()
			requestPurchaseUpgrade:InvokeServer(stat, 1)
			-- No local optimistic mutation -- �9.2: the row re-syncs from the
			-- server's own PlayerDataUpdated push, which is the only source
			-- of truth for cost/level.
		end)

		upgradeRows[stat] = { LevelLabel = levelLabel, CostLabel = buyButton, BuyButton = buyButton }
	end

	return frame
end

-- Functional, unstyled Rebirth banner + confirmation modal (�4.4/�9.3).
-- The modal is the one screen in the game allowed to be a full-screen
-- blocking takeover (�9.3) -- a rare, high-stakes, infrequent action.
local function buildRebirthUI(playerGui: PlayerGui, requestRebirth: RemoteFunction)
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "RebirthUI"
	screenGui.ResetOnSpawn = false
	screenGui.DisplayOrder = 10
	screenGui.Parent = playerGui

	-- Banner (�4.4 step 1)
	local banner = Instance.new("Frame")
	banner.Name = "Banner"
	banner.AnchorPoint = Vector2.new(0.5, 0)
	banner.Position = UDim2.new(0.5, 0, 0, 16)
	banner.Size = UDim2.new(0, 460, 0, 56)
	banner.BackgroundColor3 = Color3.fromRGB(120, 40, 160)
	banner.Visible = false
	banner.Parent = screenGui
	rebirthBanner = banner

	local bannerText = Instance.new("TextLabel")
	bannerText.Name = "BannerText"
	bannerText.Position = UDim2.new(0, 8, 0, 4)
	bannerText.Size = UDim2.new(1, -220, 1, -8)
	bannerText.BackgroundTransparency = 1
	bannerText.TextColor3 = Color3.fromRGB(255, 255, 255)
	bannerText.Font = Enum.Font.GothamBold
	bannerText.TextSize = 14
	bannerText.TextWrapped = true
	bannerText.TextXAlignment = Enum.TextXAlignment.Left
	bannerText.Text = RebirthConfig.BannerText
	bannerText.Parent = banner

	local rebirthNowButton = Instance.new("TextButton")
	rebirthNowButton.Name = "RebirthNowButton"
	rebirthNowButton.Position = UDim2.new(1, -206, 0, 8)
	rebirthNowButton.Size = UDim2.new(0, 100, 0, 40)
	rebirthNowButton.BackgroundColor3 = Color3.fromRGB(60, 180, 90)
	rebirthNowButton.TextColor3 = Color3.fromRGB(255, 255, 255)
	rebirthNowButton.Font = Enum.Font.GothamBold
	rebirthNowButton.TextSize = 14
	rebirthNowButton.Text = "Rebirth Now"
	rebirthNowButton.Parent = banner

	local skipButton = Instance.new("TextButton")
	skipButton.Name = "SkipButton"
	skipButton.Position = UDim2.new(1, -100, 0, 8)
	skipButton.Size = UDim2.new(0, 92, 0, 40)
	skipButton.BackgroundColor3 = Color3.fromRGB(80, 80, 80)
	skipButton.TextColor3 = Color3.fromRGB(255, 255, 255)
	skipButton.Font = Enum.Font.Gotham
	skipButton.TextSize = 14
	skipButton.Text = "Keep Pushing"
	skipButton.Parent = banner

	-- Confirmation modal (�4.4 step 2 / �9.3)
	local modal = Instance.new("Frame")
	modal.Name = "ConfirmModal"
	modal.AnchorPoint = Vector2.new(0.5, 0.5)
	modal.Position = UDim2.new(0.5, 0, 0.5, 0)
	modal.Size = UDim2.new(0, 420, 0, 320)
	modal.BackgroundColor3 = Color3.fromRGB(15, 15, 15)
	modal.Visible = false
	modal.ZIndex = 2 -- above the banner/upgrade panel; a very high ZIndex (20) was found to break child TextLabel rendering
	modal.Parent = screenGui
	rebirthModal = modal

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.Size = UDim2.new(1, 0, 0, 32)
	title.BackgroundTransparency = 1
	title.TextColor3 = Color3.fromRGB(255, 255, 255)
	title.Font = Enum.Font.GothamBold
	title.TextSize = 20
	title.Text = "Confirm Rebirth"
	title.Parent = modal

	local resetsLabel = Instance.new("TextLabel")
	resetsLabel.Name = "ResetsLabel"
	resetsLabel.Position = UDim2.new(0, 12, 0, 40)
	resetsLabel.Size = UDim2.new(1, -24, 0, 90)
	resetsLabel.BackgroundTransparency = 1
	resetsLabel.TextColor3 = Color3.fromRGB(255, 140, 140)
	resetsLabel.Font = Enum.Font.Gotham
	resetsLabel.TextSize = 13
	resetsLabel.TextWrapped = true
	resetsLabel.TextYAlignment = Enum.TextYAlignment.Top
	resetsLabel.Text = "RESETS:\n- " .. table.concat(RebirthConfig.ResetsOnRebirth, "\n- ")
	resetsLabel.Parent = modal

	local keepsLabel = Instance.new("TextLabel")
	keepsLabel.Name = "KeepsLabel"
	keepsLabel.Position = UDim2.new(0, 12, 0, 136)
	keepsLabel.Size = UDim2.new(1, -24, 0, 140)
	keepsLabel.BackgroundTransparency = 1
	keepsLabel.TextColor3 = Color3.fromRGB(140, 220, 140)
	keepsLabel.Font = Enum.Font.Gotham
	keepsLabel.TextSize = 13
	keepsLabel.TextWrapped = true
	keepsLabel.TextYAlignment = Enum.TextYAlignment.Top
	keepsLabel.Text = "KEEPS:\n- " .. table.concat(RebirthConfig.PersistsAcrossRebirth, "\n- ")
	keepsLabel.Parent = modal

	local confirmButton = Instance.new("TextButton")
	confirmButton.Name = "ConfirmButton"
	confirmButton.Position = UDim2.new(0, 12, 1, -52)
	confirmButton.Size = UDim2.new(0.5, -18, 0, 40)
	confirmButton.BackgroundColor3 = Color3.fromRGB(60, 180, 90)
	confirmButton.TextColor3 = Color3.fromRGB(255, 255, 255)
	confirmButton.Font = Enum.Font.GothamBold
	confirmButton.TextSize = 16
	confirmButton.Text = "Confirm Rebirth"
	confirmButton.Parent = modal

	local cancelButton = Instance.new("TextButton")
	cancelButton.Name = "CancelButton"
	cancelButton.Position = UDim2.new(0.5, 6, 1, -52)
	cancelButton.Size = UDim2.new(0.5, -18, 0, 40)
	cancelButton.BackgroundColor3 = Color3.fromRGB(80, 80, 80)
	cancelButton.TextColor3 = Color3.fromRGB(255, 255, 255)
	cancelButton.Font = Enum.Font.Gotham
	cancelButton.TextSize = 16
	cancelButton.Text = "Cancel"
	cancelButton.Parent = modal

	rebirthNowButton.MouseButton1Click:Connect(function()
		modal.Visible = true
	end)

	skipButton.MouseButton1Click:Connect(function()
		rebirthBannerDismissed = true
		banner.Visible = false
	end)

	cancelButton.MouseButton1Click:Connect(function()
		modal.Visible = false
	end)

	confirmButton.MouseButton1Click:Connect(function()
		confirmButton.Text = "Rebirthing..."
		local result = requestRebirth:InvokeServer()
		confirmButton.Text = "Confirm Rebirth"
		if result.success then
			modal.Visible = false
			rebirthBannerDismissed = false -- freshly not-eligible; next eligibility re-arms it naturally
		end
	end)
end

local function renderRebirthBanner()
	local nextRequirement = EconomyMath.GetRebirthLevelRequirement(cache.rebirthCount + 1)
	local eligible = cache.currentLevel >= nextRequirement
	rebirthBanner.Visible = eligible and not rebirthBannerDismissed
end

local function renderUpgradeMenu()
	for stat, row in upgradeRows do
		local level = cache.upgrades[stat] or 0
		local cost = EconomyMath.GetUpgradeCost(stat :: any, level)
		row.LevelLabel.Text = "Lv " .. level
		row.BuyButton.Text = "Buy: " .. cost
		row.BuyButton.BackgroundColor3 = cache.cash >= cost and Color3.fromRGB(60, 160, 80) or Color3.fromRGB(120, 60, 60)
	end
end

local ZONES_PER_WORLD = EconomyConfig.Cart.ZonesPerWorld

local function renderHud()
	cashLabel.Text = string.format("Cash: %d   Train: %d", cache.cash, cache.trainCount)

	local pushLevel = cache.upgrades.pushPower or 0
	local effectivePower = EconomyMath.GetEffectivePushPower(pushLevel, cache.rebirthPushPowerMultiplier, 1)
	local nextZone = math.min(cache.unlockedZoneIndex + 1, ZONES_PER_WORLD)
	local nextRequirement = EconomyMath.GetPowerRequirement(1, nextZone)
	pushPowerLabel.Text = string.format(
		"Push Power: Lv%d (%.1f / %.1f for Zone %d)   Unlocked: Zone %d",
		pushLevel,
		effectivePower,
		nextRequirement,
		nextZone,
		cache.unlockedZoneIndex
	)

	levelLabel.Text = string.format(
		"Level %d (%d / %d XP)   Total Lv %d   Rebirths: %d (PushMult x%.1f, CashMult x%.1f)",
		cache.currentLevel,
		cache.currentXP,
		cache.xpForNextLevel,
		cache.totalLevel,
		cache.rebirthCount,
		cache.rebirthPushPowerMultiplier,
		cache.rebirthCashMultiplier
	)
end

function UIController.Init()
	local playerGui = player:WaitForChild("PlayerGui") :: PlayerGui
	local remotesFolder = ReplicatedStorage:WaitForChild("Remotes") :: Folder
	local requestPurchaseUpgrade = remotesFolder:FindFirstChild("RequestPurchaseUpgrade") :: RemoteFunction
	local requestRebirth = remotesFolder:FindFirstChild("RequestRebirth") :: RemoteFunction

	cashLabel = buildDebugHud(playerGui)
	upgradeFrame = buildUpgradeMenu(playerGui, requestPurchaseUpgrade)
	buildRebirthUI(playerGui, requestRebirth)
	renderUpgradeMenu()
	renderHud()
	renderRebirthBanner()

	-- PlayerDataUpdated pushes a diff (�5.2) -- merge whichever fields are
	-- present rather than assuming a full replace.
	local playerDataUpdated = remotesFolder:FindFirstChild("PlayerDataUpdated") :: RemoteEvent
	playerDataUpdated.OnClientEvent:Connect(function(data: {
		cash: number?,
		trainCount: number?,
		upgrades: { [string]: number }?,
		unlockedZoneIndex: number?,
		currentLevel: number?,
		currentXP: number?,
		xpForNextLevel: number?,
		totalLevel: number?,
		rebirthCount: number?,
		rebirthPushPowerMultiplier: number?,
		rebirthCashMultiplier: number?,
	})
		-- �4.4: "the banner re-appears each time the player returns a cart
		-- while still eligible" -- a return is the only path that raises
		-- Cash and Level together, so use that as the re-arm signal (an
		-- Upgrade purchase only ever lowers Cash).
		if data.cash ~= nil and data.cash > cache.cash then
			rebirthBannerDismissed = false
		end

		if data.cash ~= nil then
			cache.cash = data.cash
		end
		if data.trainCount ~= nil then
			cache.trainCount = data.trainCount
		end
		if data.upgrades ~= nil then
			cache.upgrades = data.upgrades
		end
		if data.unlockedZoneIndex ~= nil then
			cache.unlockedZoneIndex = data.unlockedZoneIndex
		end
		if data.currentLevel ~= nil then
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

		renderHud()
		renderUpgradeMenu()
		renderRebirthBanner()
	end)

	print("[UIController] Init")
end

return UIController
