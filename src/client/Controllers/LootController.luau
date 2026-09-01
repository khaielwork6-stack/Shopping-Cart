--!strict
-- Loot Bag UI (�5.2/�9.5/�9.6) -- functional, unstyled (full styled version
-- is Phase 9). Mirrors LootService 1:1 per �5.7's Controller-naming rule,
-- kept as its own file from the start rather than folded into UIController
-- (already flagged in Phase 5's report as past the �5.1 300-400 line
-- guideline).
--
-- The Bag is viewable from anywhere (read-only); Sell All only becomes
-- enabled while a ProximityPrompt at a Sell Loot NPC is actively shown
-- (�9.6: "visible-but-disabled when the player is not at the NPC").

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local WorldData = require(ReplicatedStorage.Shared.Configs.WorldData)
local LootData = require(ReplicatedStorage.Shared.Configs.LootData)

local LootController = {}

local player = Players.LocalPlayer

type BagEntry = { itemId: string, count: number, sealed: boolean }

local bag: { BagEntry } = {}
local nearNPC = false

local bagFrame: Frame
local rowsContainer: Frame
local sellButton: TextButton
local rowInstances: { Frame } = {}

local function clearRows()
	for _, row in rowInstances do
		row:Destroy()
	end
	table.clear(rowInstances)
end

local function renderBag(requestOpenSealedItem: RemoteFunction)
	clearRows()

	for index, entry in bag do
		local item = LootData.GetItem(entry.itemId)
		local displayName = item and item.Name or entry.itemId

		local row = Instance.new("Frame")
		row.Name = "Row" .. index
		row.LayoutOrder = index
		row.Size = UDim2.new(1, -8, 0, 32)
		row.BackgroundColor3 = entry.sealed and Color3.fromRGB(70, 55, 20) or Color3.fromRGB(35, 35, 35)
		row.Parent = rowsContainer

		local nameLabel = Instance.new("TextLabel")
		nameLabel.Size = UDim2.new(0.65, 0, 1, 0)
		nameLabel.BackgroundTransparency = 1
		nameLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
		nameLabel.Font = Enum.Font.Gotham
		nameLabel.TextSize = 13
		nameLabel.TextXAlignment = Enum.TextXAlignment.Left
		nameLabel.Text = string.format("%s%s x%d", entry.sealed and "[Sealed] " or "", displayName, entry.count)
		nameLabel.Parent = row

		if entry.sealed then
			local openButton = Instance.new("TextButton")
			openButton.Size = UDim2.new(0.33, -4, 1, -4)
			openButton.Position = UDim2.new(0.67, 0, 0, 2)
			openButton.BackgroundColor3 = Color3.fromRGB(160, 130, 40)
			openButton.TextColor3 = Color3.fromRGB(255, 255, 255)
			openButton.Font = Enum.Font.GothamBold
			openButton.TextSize = 12
			openButton.Text = "Open"
			openButton.Parent = row

			openButton.MouseButton1Click:Connect(function()
				requestOpenSealedItem:InvokeServer(entry.itemId)
			end)
		end

		table.insert(rowInstances, row)
	end

	if #bag == 0 then
		local emptyLabel = Instance.new("TextLabel")
		emptyLabel.Size = UDim2.new(1, -8, 0, 32)
		emptyLabel.BackgroundTransparency = 1
		emptyLabel.TextColor3 = Color3.fromRGB(180, 180, 180)
		emptyLabel.Font = Enum.Font.Gotham
		emptyLabel.TextSize = 13
		emptyLabel.Text = "No loot yet -- return carts to find some!"
		emptyLabel.Parent = rowsContainer
		table.insert(rowInstances, emptyLabel)
	end
end

local function renderSellButton()
	sellButton.Text = nearNPC and "Sell All" or "Sell All (go to NPC)"
	sellButton.BackgroundColor3 = nearNPC and Color3.fromRGB(60, 160, 80) or Color3.fromRGB(70, 70, 70)
end

local function buildBagUI(playerGui: PlayerGui, requestSellLoot: RemoteFunction, requestOpenSealedItem: RemoteFunction)
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "LootUI"
	screenGui.ResetOnSpawn = false
	screenGui.Parent = playerGui

	local toggleButton = Instance.new("TextButton")
	toggleButton.Name = "BagToggleButton"
	toggleButton.Position = UDim2.new(1, -136, 0, 56)
	toggleButton.Size = UDim2.new(0, 120, 0, 32)
	toggleButton.BackgroundColor3 = Color3.fromRGB(140, 100, 40)
	toggleButton.TextColor3 = Color3.fromRGB(255, 255, 255)
	toggleButton.Font = Enum.Font.GothamBold
	toggleButton.TextSize = 18
	toggleButton.Text = "Bag"
	toggleButton.Parent = screenGui

	local frame = Instance.new("Frame")
	frame.Name = "BagPanel"
	frame.Position = UDim2.new(1, -320, 0, 96)
	frame.Size = UDim2.new(0, 300, 0, 320)
	frame.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
	frame.BackgroundTransparency = 0.1
	frame.Visible = false
	frame.Parent = screenGui
	bagFrame = frame

	-- A plain Frame silently clips/overlaps entries past its bounds once the
	-- Bag holds more than fits on screen -- a ScrollingFrame with an
	-- auto-sized canvas keeps every entry reachable.
	local container = Instance.new("ScrollingFrame")
	container.Name = "Rows"
	container.Position = UDim2.new(0, 4, 0, 4)
	container.Size = UDim2.new(1, -8, 1, -52)
	container.BackgroundTransparency = 1
	container.BorderSizePixel = 0
	container.ScrollBarThickness = 6
	container.CanvasSize = UDim2.new(0, 0, 0, 0)
	container.AutomaticCanvasSize = Enum.AutomaticSize.Y
	container.Parent = frame
	rowsContainer = container

	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 3)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = container

	local sell = Instance.new("TextButton")
	sell.Name = "SellAllButton"
	sell.Position = UDim2.new(0, 4, 1, -44)
	sell.Size = UDim2.new(1, -8, 0, 40)
	sell.BackgroundColor3 = Color3.fromRGB(70, 70, 70)
	sell.TextColor3 = Color3.fromRGB(255, 255, 255)
	sell.Font = Enum.Font.GothamBold
	sell.TextSize = 15
	sell.Text = "Sell All (go to NPC)"
	sell.Parent = frame
	sellButton = sell

	toggleButton.MouseButton1Click:Connect(function()
		frame.Visible = not frame.Visible
	end)

	sell.MouseButton1Click:Connect(function()
		if not nearNPC then
			return
		end
		requestSellLoot:InvokeServer(false)
	end)
end

local function connectSellNPCs()
	local worldsFolder = Workspace:WaitForChild("Worlds")
	for _, worldEntry in WorldData.Worlds do
		local worldFolder = worldsFolder:WaitForChild(worldEntry.FolderName)
		local npc = worldFolder:FindFirstChild("PH_NPC_LootSeller")
		local prompt = npc and npc:FindFirstChild("HumanoidRootPart") and npc.HumanoidRootPart:FindFirstChild("SellPrompt") :: ProximityPrompt?
		if prompt then
			prompt.PromptShown:Connect(function()
				nearNPC = true
				renderSellButton()
			end)
			prompt.PromptHidden:Connect(function()
				nearNPC = false
				renderSellButton()
			end)
			prompt.Triggered:Connect(function()
				bagFrame.Visible = true
			end)
		end
	end
end

function LootController.Init()
	local playerGui = player:WaitForChild("PlayerGui") :: PlayerGui
	local remotesFolder = ReplicatedStorage:WaitForChild("Remotes") :: Folder
	local requestSellLoot = remotesFolder:FindFirstChild("RequestSellLoot") :: RemoteFunction
	local requestOpenSealedItem = remotesFolder:FindFirstChild("RequestOpenSealedItem") :: RemoteFunction

	buildBagUI(playerGui, requestSellLoot, requestOpenSealedItem)
	renderBag(requestOpenSealedItem)
	renderSellButton()
	connectSellNPCs()

	local playerDataUpdated = remotesFolder:FindFirstChild("PlayerDataUpdated") :: RemoteEvent
	playerDataUpdated.OnClientEvent:Connect(function(data: { lootBag: { BagEntry }? })
		if data.lootBag ~= nil then
			bag = data.lootBag
			renderBag(requestOpenSealedItem)
		end
	end)

	print("[LootController] Init")
end

return LootController
