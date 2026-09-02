--!strict
-- Index UI (�5.2/�9.7) -- Phase 9 rewrite targeting the adapted UI pack's
-- "Index" frame instead of the plain debug grid built in Phase 7. Mirrors
-- IndexService 1:1 per §5.7. Loads instantly from the client's own cached
-- discovered set (§9.7: "no server round-trip needed to simply view it").

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LootData = require(ReplicatedStorage.Shared.Configs.LootData)
local CartData = require(ReplicatedStorage.Shared.Configs.CartData)

local IndexController = {}

local player = Players.LocalPlayer

local discoveredSet: { [string]: boolean } = {}
local pushPowerBonus = 1
local luck = 1

local indexFrame: Frame
local grid: ScrollingFrame

local RARITY_COLOR: { [string]: Color3 } = {}
for rarity, display in CartData.RarityDisplay do
	RARITY_COLOR[rarity] = Color3.new(display.Color[1], display.Color[2], display.Color[3])
end

local UNDISCOVERED_COLOR = Color3.fromRGB(35, 35, 35)

local function renderHeader()
	local totalDiscovered = 0
	for _ in discoveredSet do
		totalDiscovered += 1
	end
	indexFrame.Features.Title.Text = string.format(
		"%d / %d discovered  |  Push Power +%.1f%%  |  Luck x%.2f",
		totalDiscovered,
		#LootData.Items,
		(pushPowerBonus - 1) * 100,
		luck
	)
end

local function renderGrid()
	for i, item in LootData.Items do
		local cell = grid:FindFirstChild("Item" .. i)
		if not cell then
			continue
		end

		local discovered = discoveredSet[item.Id] == true
		local nameLabel = cell.Frame:FindFirstChild("Name") :: TextLabel
		cell.BackgroundColor3 = discovered and (RARITY_COLOR[item.Rarity] or RARITY_COLOR.Common) or UNDISCOVERED_COLOR
		cell.Frame.Rarity.Visible = discovered
		nameLabel.Visible = discovered
		cell.Count.Visible = not discovered

		if discovered then
			cell.Frame.Rarity.Text = string.upper(item.Rarity)
			nameLabel.Text = item.Name
		end
	end
end

function IndexController.Init()
	local playerGui = player:WaitForChild("PlayerGui") :: PlayerGui
	local screenGui = playerGui:WaitForChild("ScreenGui") :: ScreenGui
	indexFrame = screenGui.Frames.Index
	grid = indexFrame.ScrollingFrame

	renderGrid()
	renderHeader()

	local remotesFolder = ReplicatedStorage:WaitForChild("Remotes") :: Folder
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
