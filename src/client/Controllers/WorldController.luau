--!strict
-- World travel screen (�5.2/�9.4) -- mirrors WorldService 1:1 per §5.7.
-- The Top "Worlds" button/frame (repurposed from the UI pack's generic
-- "ItemShop") shows all 5 Worlds with a lock/unlock state the pack's own
-- card style already distinguishes visually (bright vs. dark+overlay);
-- this Controller just drives that state from real data and wires Travel.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local WorldData = require(ReplicatedStorage.Shared.Configs.WorldData)

local WorldController = {}

local player = Players.LocalPlayer
local unlockedWorlds: { [number]: boolean } = { [1] = true }

local UNLOCKED_COLOR = Color3.fromRGB(140, 230, 60)
local LOCKED_COLOR = Color3.fromRGB(60, 60, 60)

local function renderWorldCard(card: Frame, worldId: number)
	local unlocked = unlockedWorlds[worldId] == true
	card.BackgroundColor3 = unlocked and UNLOCKED_COLOR or LOCKED_COLOR
	card.Frame.Choose.Money.Visible = unlocked
end

local function renderAll()
	local scrolling = player.PlayerGui.ScreenGui.Frames.Worlds.ScrollingFrame
	for _, world in WorldData.Worlds do
		local card = scrolling:FindFirstChild("World" .. world.Id)
		if card then
			renderWorldCard(card, world.Id)
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
				requestEnterWorldPortal:InvokeServer(world.Id)
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
