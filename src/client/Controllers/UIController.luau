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

local UIController = {}

local player = Players.LocalPlayer

local STAT_ORDER: { EconomyConfig.UpgradeStatName } = { "capacity", "agility", "mobility", "range", "pushPower" }

type PlayerDataCache = {
	cash: number,
	trainCount: number,
	upgrades: { [string]: number },
	unlockedZoneIndex: number,
}

local cache: PlayerDataCache = {
	cash = 0,
	trainCount = 0,
	upgrades = { capacity = 0, agility = 0, mobility = 0, range = 0, pushPower = 0 },
	unlockedZoneIndex = 1,
}

local cashLabel: TextLabel
local pushPowerLabel: TextLabel
local upgradeFrame: Frame
local upgradeRows: { [string]: { LevelLabel: TextLabel, CostLabel: TextLabel, BuyButton: TextButton } } = {}

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
	local effectivePower = EconomyMath.GetEffectivePushPower(pushLevel, 1, 1)
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
end

function UIController.Init()
	local playerGui = player:WaitForChild("PlayerGui") :: PlayerGui
	local remotesFolder = ReplicatedStorage:WaitForChild("Remotes") :: Folder
	local requestPurchaseUpgrade = remotesFolder:FindFirstChild("RequestPurchaseUpgrade") :: RemoteFunction

	cashLabel = buildDebugHud(playerGui)
	upgradeFrame = buildUpgradeMenu(playerGui, requestPurchaseUpgrade)
	renderUpgradeMenu()
	renderHud()

	-- PlayerDataUpdated pushes a diff (�5.2) -- merge whichever fields are
	-- present rather than assuming a full replace.
	local playerDataUpdated = remotesFolder:FindFirstChild("PlayerDataUpdated") :: RemoteEvent
	playerDataUpdated.OnClientEvent:Connect(function(data: {
		cash: number?,
		trainCount: number?,
		upgrades: { [string]: number }?,
		unlockedZoneIndex: number?,
	})
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
		renderHud()
		renderUpgradeMenu()
	end)

	print("[UIController] Init")
end

return UIController
