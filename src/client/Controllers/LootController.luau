--!strict
-- Loot Bag UI (�5.2/�9.5/�9.6) -- Phase 9 rewrite targeting the adapted UI
-- pack's "Sell" frame (StarterGui.ScreenGui.Frames.Sell) instead of the
-- plain debug UI built in Phase 6. Mirrors LootService 1:1 per §5.7.
--
-- The Bag is viewable from anywhere (read-only); Sell All only becomes
-- enabled while a ProximityPrompt at a Sell Loot NPC is actively shown
-- (§9.6: "visible-but-disabled when the player is not at the NPC").

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local WorldData = require(ReplicatedStorage.Shared.Configs.WorldData)
local LootData = require(ReplicatedStorage.Shared.Configs.LootData)
local CartData = require(ReplicatedStorage.Shared.Configs.CartData)

local LootController = {}

local player = Players.LocalPlayer

type BagEntry = { itemId: string, count: number, sealed: boolean }

local bag: { BagEntry } = {}
local previousBagCount = 0
local nearNPC = false

local sellFrame: Frame
local rowsContainer: ScrollingFrame
local itemTemplate: Frame
local sellAllButton: TextButton
local uiAnimationController: any

local RARITY_COLOR: { [string]: Color3 } = {}
for rarity, display in CartData.RarityDisplay do
	RARITY_COLOR[rarity] = Color3.new(display.Color[1], display.Color[2], display.Color[3])
end

local function totalItemCount(): number
	local total = 0
	for _, entry in bag do
		total += entry.count
	end
	return total
end

local function renderBag(requestOpenSealedItem: RemoteFunction)
	for _, child in rowsContainer:GetChildren() do
		if child.Name ~= "ItemTemplate" and (child:IsA("Frame")) then
			child:Destroy()
		end
	end

	for index, entry in bag do
		local item = LootData.GetItem(entry.itemId)
		local displayName = item and item.Name or entry.itemId
		local rarity = item and item.Rarity or "Common"

		local card = itemTemplate:Clone()
		card.Name = "BagItem" .. index
		card.LayoutOrder = index
		card.Visible = true
		card.BackgroundColor3 = RARITY_COLOR[rarity] or RARITY_COLOR.Common

		local titles = {}
		for _, child in card.Frame:GetChildren() do
			if child.Name == "Title" then
				table.insert(titles, child)
			end
		end
		titles[1].Text = displayName
		titles[2].Text = string.upper(rarity)
		titles[3].Visible = entry.sealed

		card.Frame.BrainrotFrame["1"].Frame.Earns.Text = "x" .. entry.count

		card.Frame.Choose.Money.Visible = entry.sealed
		if entry.sealed then
			card.Frame.Choose.Money.MouseButton1Click:Connect(function()
				requestOpenSealedItem:InvokeServer(entry.itemId)
			end)
		end

		card.Parent = rowsContainer
	end
end

local function renderSellButton()
	sellAllButton.Frame.BackgroundTransparency = nearNPC and 0 or 0.5
	sellAllButton.AutoButtonColor = nearNPC
end

local function connectSellNPCs(requestSellLoot: RemoteFunction)
	local worldsFolder = Workspace:WaitForChild("Worlds")
	for _, worldEntry in WorldData.Worlds do
		local worldFolder = worldsFolder:WaitForChild(worldEntry.FolderName)
		local npc = worldFolder:FindFirstChild("PH_NPC_LootSeller")
		local prompt = npc
			and npc:FindFirstChild("HumanoidRootPart")
			and npc.HumanoidRootPart:FindFirstChild("SellPrompt") :: ProximityPrompt?
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
				uiAnimationController.OpenFrame("Sell")
			end)
		end
	end

	sellAllButton.MouseButton1Click:Connect(function()
		if not nearNPC then
			return
		end
		requestSellLoot:InvokeServer(false)
	end)
end

function LootController.Init()
	local playerGui = player:WaitForChild("PlayerGui") :: PlayerGui
	local screenGui = playerGui:WaitForChild("ScreenGui") :: ScreenGui
	uiAnimationController = require(script.Parent.UIAnimationController)

	sellFrame = screenGui.Frames.Sell
	rowsContainer = sellFrame.ScrollingFrame
	itemTemplate = rowsContainer.ItemTemplate
	sellAllButton = sellFrame.Top.Frame.SellAll

	local remotesFolder = ReplicatedStorage:WaitForChild("Remotes") :: Folder
	local requestSellLoot = remotesFolder:FindFirstChild("RequestSellLoot") :: RemoteFunction
	local requestOpenSealedItem = remotesFolder:FindFirstChild("RequestOpenSealedItem") :: RemoteFunction

	renderBag(requestOpenSealedItem)
	renderSellButton()
	connectSellNPCs(requestSellLoot)

	local playerDataUpdated = remotesFolder:FindFirstChild("PlayerDataUpdated") :: RemoteEvent
	playerDataUpdated.OnClientEvent:Connect(function(data: { lootBag: { BagEntry }? })
		if data.lootBag ~= nil then
			bag = data.lootBag
			renderBag(requestOpenSealedItem)

			local newCount = totalItemCount()
			if newCount > previousBagCount then
				uiAnimationController.ShowNotification("LootFound")
			end
			previousBagCount = newCount
		end
	end)

	print("[LootController] Init")
end

return LootController
