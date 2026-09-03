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
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local WorldData = require(ReplicatedStorage.Shared.Configs.WorldData)
local LootData = require(ReplicatedStorage.Shared.Configs.LootData)
local CartData = require(ReplicatedStorage.Shared.Configs.CartData)
local SoundController = require(script.Parent.SoundController)

local LootController = {}

local player = Players.LocalPlayer

type BagEntry = { itemId: string, count: number, sealed: boolean }

local bag: { BagEntry } = {}
local previousBagCount = 0
local nearNPC = false
local currentNearNPC: Model? = nil

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
				local result = requestOpenSealedItem:InvokeServer(entry.itemId) :: { success: boolean? }
				if result and result.success then
					SoundController.PlaySFX("ItemReveal")
				else
					SoundController.PlaySFX("UIDenied")
				end
			end)
		end

		card.Parent = rowsContainer
	end
end

local function renderSellButton()
	sellAllButton.Frame.BackgroundTransparency = nearNPC and 0 or 0.5
	sellAllButton.AutoButtonColor = nearNPC
end

-- §8 "NPC interaction feedback": a short idle "gesture" on trigger. The
-- placeholder NPC has no rigged Humanoid to animate (confirmed via live
-- inspection, §13 QA), and Model.Scale isn't a settable property on this
-- Roblox version (same finding as the cart pop-in bug -- see CartVisuals) --
-- so this bounces the PrimaryPart's own Size instead, mirroring that fix.
local NPC_GESTURE_INFO = TweenInfo.new(0.12, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local function playNPCGesture(npc: Model)
	local primaryPart = npc.PrimaryPart
	if not primaryPart then
		return
	end
	local baseSize = primaryPart.Size
	primaryPart.Size = baseSize * 1.08
	TweenService:Create(primaryPart, NPC_GESTURE_INFO, { Size = baseSize }):Play()
end

-- Sell-booth idle ambience, mirroring TrainController's Corral treatment: a
-- slow warm-gold breathing light plus a lazy upward glint drift, parented to
-- the NPC's HumanoidRootPart so it sits right at the counter regardless of
-- which World's booth layout it's attached to. All looping via TweenService
-- (RepeatCount = -1), no per-frame cost.
local BOOTH_PULSE_INFO = TweenInfo.new(2.0, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
local BOOTH_SELL_BURST_INFO = TweenInfo.new(0.15, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local function setupSellBoothAmbient(npc: Model)
	local root = npc.PrimaryPart
	if not root then
		return
	end

	local glow = Instance.new("PointLight")
	glow.Name = "PH_SellBoothAmbientGlow"
	glow.Color = Color3.fromRGB(255, 210, 90)
	glow.Range = 14
	glow.Brightness = 0.8
	glow.Parent = root
	TweenService:Create(glow, BOOTH_PULSE_INFO, { Brightness = 2.2 }):Play()

	local glintAttachment = Instance.new("Attachment")
	glintAttachment.Name = "PH_SellBoothGlintAnchor"
	glintAttachment.Position = Vector3.new(0, 2, 0)
	glintAttachment.Parent = root

	local glints = Instance.new("ParticleEmitter")
	glints.Color = ColorSequence.new(Color3.fromRGB(255, 225, 130))
	glints.Lifetime = NumberRange.new(1.0, 1.5)
	glints.Speed = NumberRange.new(1, 2)
	glints.SpreadAngle = Vector2.new(30, 30)
	glints.Size = NumberSequence.new(0.2)
	glints.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.15),
		NumberSequenceKeypoint.new(1, 1),
	})
	glints.Rate = 3
	glints.Parent = glintAttachment
end

-- §8-style "sale confirmed" feedback: a quick gold flash + coin-sparkle
-- burst at the booth, layered on top of the existing Sell SFX, so a
-- successful sell reads as a satisfying event rather than a silent number
-- change in the UI.
local function playSellBurst(npc: Model)
	local root = npc.PrimaryPart
	if not root then
		return
	end

	local flash = root:FindFirstChild("PH_SellBoothAmbientGlow") :: PointLight?
	if flash then
		local originalBrightness = flash.Brightness
		local tween = TweenService:Create(flash, TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Brightness = 6,
		})
		tween:Play()
		tween.Completed:Connect(function()
			TweenService:Create(flash, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
				Brightness = originalBrightness,
			}):Play()
		end)
	end

	local burstAttachment = Instance.new("Attachment")
	burstAttachment.Position = Vector3.new(0, 2, 0)
	burstAttachment.Parent = root

	local coins = Instance.new("ParticleEmitter")
	coins.Color = ColorSequence.new(Color3.fromRGB(255, 220, 80))
	coins.Lifetime = NumberRange.new(0.5, 0.8)
	coins.Speed = NumberRange.new(6, 10)
	coins.SpreadAngle = Vector2.new(180, 60)
	coins.Size = NumberSequence.new(0.3)
	coins.Rate = 0
	coins.Parent = burstAttachment

	coins:Emit(18)
	Debris:AddItem(burstAttachment, 1.5)

	local primaryPart = npc.PrimaryPart
	if primaryPart then
		local baseSize = primaryPart.Size
		primaryPart.Size = baseSize * 1.1
		TweenService:Create(primaryPart, BOOTH_SELL_BURST_INFO, { Size = baseSize }):Play()
	end
end

local function connectSellNPCs(requestSellLoot: RemoteFunction)
	local worldsFolder = Workspace:WaitForChild("Worlds")
	for _, worldEntry in WorldData.Worlds do
		local worldFolder = worldsFolder:WaitForChild(worldEntry.FolderName)
		local npc = worldFolder:FindFirstChild("PH_NPC_LootSeller") :: Model?
		local prompt = npc
			and npc:FindFirstChild("HumanoidRootPart")
			and npc.HumanoidRootPart:FindFirstChild("SellPrompt") :: ProximityPrompt?
		if prompt and npc then
			setupSellBoothAmbient(npc)
			prompt.PromptShown:Connect(function()
				nearNPC = true
				currentNearNPC = npc
				renderSellButton()
			end)
			prompt.PromptHidden:Connect(function()
				nearNPC = false
				if currentNearNPC == npc then
					currentNearNPC = nil
				end
				renderSellButton()
			end)
			prompt.Triggered:Connect(function()
				playNPCGesture(npc)
				SoundController.PlaySFX("NPCInteraction")
				uiAnimationController.OpenFrame("Sell")
			end)
		end
	end

	sellAllButton.MouseButton1Click:Connect(function()
		if not nearNPC then
			return
		end
		local result = requestSellLoot:InvokeServer(false) :: { success: boolean? }
		if result and result.success then
			SoundController.PlaySFX("Sell")
			if currentNearNPC then
				playSellBurst(currentNearNPC)
			end
		else
			SoundController.PlaySFX("UIDenied")
		end
	end)
end

-- §13 QA: `isInitial` suppresses the "LootFound" toast for RequestPlayerData
-- Snapshot's one-shot boot pull -- a returning player with a half-full Bag
-- must never see a found-item celebration fire the instant they join.
local function applyDataUpdate(requestOpenSealedItem: RemoteFunction, data: { lootBag: { BagEntry }? }, isInitial: boolean?)
	if data.lootBag ~= nil then
		bag = data.lootBag
		renderBag(requestOpenSealedItem)

		local newCount = totalItemCount()
		if not isInitial and newCount > previousBagCount then
			uiAnimationController.ShowNotification("LootFound")
		end
		previousBagCount = newCount
	end
end

function LootController.Init(initialSnapshot: { lootBag: { BagEntry }? }?)
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

	renderSellButton()
	connectSellNPCs(requestSellLoot)

	if initialSnapshot then
		applyDataUpdate(requestOpenSealedItem, initialSnapshot, true)
	else
		renderBag(requestOpenSealedItem)
	end

	local playerDataUpdated = remotesFolder:FindFirstChild("PlayerDataUpdated") :: RemoteEvent
	playerDataUpdated.OnClientEvent:Connect(function(data: { lootBag: { BagEntry }? })
		applyDataUpdate(requestOpenSealedItem, data)
	end)

	print("[LootController] Init")
end

return LootController
