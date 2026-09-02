--!strict
-- World travel screen (�5.2/�9.4) -- mirrors WorldService 1:1 per §5.7.
-- The Top "Worlds" button/frame (repurposed from the UI pack's generic
-- "ItemShop") shows all 5 Worlds with a lock/unlock state the pack's own
-- card style already distinguishes visually (bright vs. dark+overlay);
-- this Controller just drives that state from real data and wires Travel.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local WorldData = require(ReplicatedStorage.Shared.Configs.WorldData)
local SoundController = require(script.Parent.SoundController)

local WorldController = {}

local player = Players.LocalPlayer
local unlockedWorlds: { [number]: boolean } = { [1] = true }

local UNLOCKED_COLOR = Color3.fromRGB(140, 230, 60)
local LOCKED_COLOR = Color3.fromRGB(60, 60, 60)

-- Two children are both named "Title" (world name + status subtitle) --
-- dot-indexing only ever reaches the first one, so both need GetChildren().
local function getTitles(frame: Instance): { TextLabel }
	local titles = {}
	for _, c in frame:GetChildren() do
		if c.Name == "Title" and c:IsA("TextLabel") then
			table.insert(titles, c)
		end
	end
	return titles
end

-- The lock-dimmer overlay is a second, identically-named "Frame" sibling of
-- the card's main content Frame -- distinguished by being the one with a
-- bare "ImageLabel" (its lock icon) as a direct child.
local function findLockOverlay(card: Frame): Frame?
	for _, c in card:GetChildren() do
		if c:IsA("Frame") and c:FindFirstChild("ImageLabel") then
			return c
		end
	end
	return nil
end

local function renderWorldCard(card: Frame, world: WorldData.WorldEntry)
	local unlocked = unlockedWorlds[world.Id] == true
	card.BackgroundColor3 = unlocked and UNLOCKED_COLOR or LOCKED_COLOR
	card.Frame.Choose.Money.Visible = unlocked

	-- The status subtitle (2nd Title) only makes sense on its own when
	-- unlocked ("Unlocked from the start!") -- while locked, the dimmer
	-- overlay's own big requirement text replaces it, so hide this one to
	-- avoid the two messages overlapping and reading as clutter.
	local titles = getTitles(card.Frame)
	if titles[2] then
		titles[2].Visible = unlocked
	end

	local overlay = findLockOverlay(card)
	if overlay then
		overlay.Visible = not unlocked
		if not unlocked then
			local overlayTitle = overlay:FindFirstChild("Title") :: TextLabel?
			if overlayTitle then
				overlayTitle.Text = string.format("%d TOTAL LEVEL REQUIRED", world.TotalLevelRequirement)
			end
		end
	end
end

local function renderAll()
	local scrolling = player.PlayerGui.ScreenGui.Frames.Worlds.ScrollingFrame
	for _, world in WorldData.Worlds do
		local card = scrolling:FindFirstChild("World" .. world.Id)
		if card then
			renderWorldCard(card, world)
		end
	end
end

function WorldController.Init()
	local remotesFolder = ReplicatedStorage:WaitForChild("Remotes") :: Folder
	local requestEnterWorldPortal = remotesFolder:FindFirstChild("RequestEnterWorldPortal") :: RemoteFunction

	local scrolling = player.PlayerGui:WaitForChild("ScreenGui").Frames.Worlds.ScrollingFrame
	for _, world in WorldData.Worlds do
		local card = scrolling:FindFirstChild("World" .. world.Id)
		if card then
			card.Frame.Choose.Money.MouseButton1Click:Connect(function()
				local result = requestEnterWorldPortal:InvokeServer(world.Id) :: { success: boolean? }
				if result and result.success then
					SoundController.PlaySFX("PortalEnter")
				else
					SoundController.PlaySFX("UIDenied")
				end
			end)
		end
	end

	renderAll()

	local playerDataUpdated = remotesFolder:FindFirstChild("PlayerDataUpdated") :: RemoteEvent
	playerDataUpdated.OnClientEvent:Connect(function(data: { unlockedWorlds: { number }? })
		if data.unlockedWorlds ~= nil then
			local set = {}
			for _, worldId in data.unlockedWorlds do
				set[worldId] = true
			end
			unlockedWorlds = set
			renderAll()
		end
	end)

	print("[WorldController] Init")
end

return WorldController
