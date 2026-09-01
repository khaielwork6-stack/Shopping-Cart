--!strict
-- Index UI (�5.2/�9.7) -- functional, unstyled (full styled version is
-- Phase 9). Mirrors IndexService 1:1 per �5.7's Controller-naming rule,
-- kept as its own file per the same reasoning as Phase 6's LootController.
--
-- Loads instantly from the client's own cached discovered set (�9.7: "no
-- server round-trip needed to simply view it") -- the set itself still only
-- ever arrives via the server's authoritative PlayerDataUpdated push.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local EconomyConfig = require(ReplicatedStorage.Shared.Configs.EconomyConfig)
local LootData = require(ReplicatedStorage.Shared.Configs.LootData)

local IndexController = {}

local player = Players.LocalPlayer

local RARITY_TABS = EconomyConfig.RarityOrder -- Common, Uncommon, Rare, Epic, Legendary

local discoveredSet: { [string]: boolean } = {}
local pushPowerBonus = 1
local luck = 1
local currentTab = RARITY_TABS[1]

local headerLabel: TextLabel
local rowsContainer: ScrollingFrame
local tabButtons: { [string]: TextButton } = {}
local rowInstances: { Instance } = {}

local function clearRows()
	for _, row in rowInstances do
		row:Destroy()
	end
	table.clear(rowInstances)
end

local function renderHeader()
	local totalDiscovered = 0
	for _ in discoveredSet do
		totalDiscovered += 1
	end

	headerLabel.Text = string.format(
		"%d / %d discovered   Push Power Bonus: x%.3f   Luck: x%.2f",
		totalDiscovered,
		#LootData.Items,
		pushPowerBonus,
		luck
	)
end

local function renderTabHighlight()
	for rarity, button in tabButtons do
		button.BackgroundColor3 = rarity == currentTab and Color3.fromRGB(60, 120, 200) or Color3.fromRGB(50, 50, 50)
	end
end

local function renderGrid()
	clearRows()

	local items = LootData.GetItemsByRarity(currentTab)
	for index, item in items do
		local discovered = discoveredSet[item.Id] == true

		local row = Instance.new("Frame")
		row.Name = "Row" .. index
		row.LayoutOrder = index
		row.Size = UDim2.new(1, -8, 0, 30)
		row.BackgroundColor3 = discovered and Color3.fromRGB(35, 35, 35) or Color3.fromRGB(25, 25, 25)
		row.Parent = rowsContainer

		local label = Instance.new("TextLabel")
		label.Size = UDim2.new(1, -8, 1, 0)
		label.Position = UDim2.new(0, 4, 0, 0)
		label.BackgroundTransparency = 1
		label.TextColor3 = discovered and Color3.fromRGB(255, 255, 255) or Color3.fromRGB(120, 120, 120)
		label.Font = discovered and Enum.Font.GothamBold or Enum.Font.Gotham
		label.TextSize = 13
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.Text = discovered and (item.Name .. string.format("  (sells for %d)", item.SellValue)) or "???"
		label.Parent = row

		table.insert(rowInstances, row)
	end
end

local function buildIndexUI(playerGui: PlayerGui)
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "IndexUI"
	screenGui.ResetOnSpawn = false
	screenGui.Parent = playerGui

	local toggleButton = Instance.new("TextButton")
	toggleButton.Name = "IndexToggleButton"
	toggleButton.Position = UDim2.new(1, -136, 0, 96)
	toggleButton.Size = UDim2.new(0, 120, 0, 32)
	toggleButton.BackgroundColor3 = Color3.fromRGB(60, 120, 200)
	toggleButton.TextColor3 = Color3.fromRGB(255, 255, 255)
	toggleButton.Font = Enum.Font.GothamBold
	toggleButton.TextSize = 18
	toggleButton.Text = "Index"
	toggleButton.Parent = screenGui

	local frame = Instance.new("Frame")
	frame.Name = "IndexPanel"
	frame.Position = UDim2.new(1, -340, 0, 136)
	frame.Size = UDim2.new(0, 320, 0, 380)
	frame.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
	frame.BackgroundTransparency = 0.1
	frame.Visible = false
	frame.Parent = screenGui

	local header = Instance.new("TextLabel")
	header.Name = "Header"
	header.Position = UDim2.new(0, 4, 0, 4)
	header.Size = UDim2.new(1, -8, 0, 36)
	header.BackgroundTransparency = 1
	header.TextColor3 = Color3.fromRGB(255, 255, 255)
	header.Font = Enum.Font.Gotham
	header.TextSize = 12
	header.TextWrapped = true
	header.Text = "0 / 0 discovered"
	header.Parent = frame
	headerLabel = header

	local tabBar = Instance.new("Frame")
	tabBar.Name = "TabBar"
	tabBar.Position = UDim2.new(0, 4, 0, 44)
	tabBar.Size = UDim2.new(1, -8, 0, 28)
	tabBar.BackgroundTransparency = 1
	tabBar.Parent = frame

	local tabLayout = Instance.new("UIListLayout")
	tabLayout.FillDirection = Enum.FillDirection.Horizontal
	tabLayout.Padding = UDim.new(0, 2)
	tabLayout.Parent = tabBar

	for _, rarity in RARITY_TABS do
		local tabButton = Instance.new("TextButton")
		tabButton.Name = rarity .. "Tab"
		tabButton.Size = UDim2.new(1 / #RARITY_TABS, -2, 1, 0)
		tabButton.BackgroundColor3 = Color3.fromRGB(50, 50, 50)
		tabButton.TextColor3 = Color3.fromRGB(255, 255, 255)
		tabButton.Font = Enum.Font.Gotham
		tabButton.TextSize = 11
		tabButton.Text = rarity
		tabButton.Parent = tabBar

		tabButton.MouseButton1Click:Connect(function()
			currentTab = rarity
			renderTabHighlight()
			renderGrid()
		end)

		tabButtons[rarity] = tabButton
	end

	local container = Instance.new("ScrollingFrame")
	container.Name = "Rows"
	container.Position = UDim2.new(0, 4, 0, 76)
	container.Size = UDim2.new(1, -8, 1, -80)
	container.BackgroundTransparency = 1
	container.BorderSizePixel = 0
	container.ScrollBarThickness = 6
	container.CanvasSize = UDim2.new(0, 0, 0, 0)
	container.AutomaticCanvasSize = Enum.AutomaticSize.Y
	container.Parent = frame
	rowsContainer = container

	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 2)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = container

	toggleButton.MouseButton1Click:Connect(function()
		frame.Visible = not frame.Visible
	end)
end

function IndexController.Init()
	local playerGui = player:WaitForChild("PlayerGui") :: PlayerGui
	local remotesFolder = ReplicatedStorage:WaitForChild("Remotes") :: Folder

	buildIndexUI(playerGui)
	renderTabHighlight()
	renderGrid()
	renderHeader()

	local playerDataUpdated = remotesFolder:FindFirstChild("PlayerDataUpdated") :: RemoteEvent
	playerDataUpdated.OnClientEvent:Connect(function(data: {
		indexDiscovered: { string }?,
		indexPushPowerBonus: number?,
		luck: number?,
	})
		local changed = false

		if data.indexDiscovered ~= nil then
			local set = {}
			for _, itemId in data.indexDiscovered do
				set[itemId] = true
			end
			discoveredSet = set
			changed = true
		end
		if data.indexPushPowerBonus ~= nil then
			pushPowerBonus = data.indexPushPowerBonus
			changed = true
		end
		if data.luck ~= nil then
			luck = data.luck
			changed = true
		end

		if changed then
			renderHeader()
			renderGrid()
		end
	end)

	print("[IndexController] Init")
end

return IndexController
