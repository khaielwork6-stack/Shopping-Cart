--!strict
-- World travel screen (�5.2/�9.4) -- mirrors WorldService 1:1 per §5.7.
-- The Top "Worlds" button/frame (repurposed from the UI pack's generic
-- "ItemShop") shows all 5 Worlds with a lock/unlock state the pack's own
-- card style already distinguishes visually (bright vs. dark+overlay);
-- this Controller just drives that state from real data and wires Travel.
--
-- Lost Cart migration, Phase 2: World5 is now the Main Lane (WorldData.
-- IsMainLane) -- always unlocked, since PlayerDataService seeds it into
-- unlockedWorlds and WorldService.CheckWorldUnlocks never touches it. No
-- special-casing needed here: its card renders "unlocked" for free, and
-- clicking it already calls RequestEnterWorldPortal(mainLaneId), which is
-- exactly "return to the Main Lane" when clicked from inside a bonus World.
-- Worlds 1-4 are now Rebirth-gated instead of Level-gated (WorldData.
-- RebirthRequirement replaces TotalLevelRequirement).
--
-- World 1 rebalance: Worlds 1-4 are temporarily disabled while they get
-- rebuilt from scratch as real content (WorldService.handleRequestEnterWorldPortal
-- now rejects travel to anything but the Main Lane). Their cards always
-- render locked with "COMING SOON" here, regardless of actual Rebirth
-- progress, so the UI doesn't promise a destination that isn't real yet.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local WorldData = require(ReplicatedStorage.Shared.Configs.WorldData)
local SoundController = require(script.Parent.SoundController)

local WorldController = {}

local player = Players.LocalPlayer
local unlockedWorlds: { [number]: boolean } = { [WorldData.GetMainLane().Id] = true }

local UNLOCKED_COLOR = Color3.fromRGB(140, 230, 60)
local LOCKED_COLOR = Color3.fromRGB(60, 60, 60)

-- World 1 rebalance QA: World1's card has no lock overlay at all in Studio
-- -- under the old system it was Level-0-required (always unlocked from the
-- start), so it never needed one authored. Now that it's Rebirth-gated and
-- rendered permanently locked, that gap would silently show it as a plain,
-- undimmed card with no "COMING SOON"/lock treatment -- cloned from the
-- first card that DOES have one (cached here) onto any card missing it,
-- rather than depending on every card being manually re-authored in Studio.
local overlayTemplate: Frame? = nil

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
			if not overlayTemplate then
				overlayTemplate = c
			end
			return c
		end
	end

	if overlayTemplate then
		local clone = overlayTemplate:Clone()
		clone.Parent = card
		return clone
	end

	return nil
end

local function renderWorldCard(card: Frame, world: WorldData.WorldEntry)
	-- World 1 rebalance: a non-Main-Lane World is always shown locked right
	-- now, independent of its real unlock state -- travel there is disabled
	-- server-side, so the UI shouldn't look like it's actually available.
	local unlocked = world.IsMainLane and unlockedWorlds[world.Id] == true
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
				overlayTitle.Text = world.IsMainLane
					and string.format(
						world.RebirthRequirement == 1 and "%d REBIRTH REQUIRED" or "%d REBIRTHS REQUIRED",
						world.RebirthRequirement
					)
					or "COMING SOON"
			end
		end
	end
end

local function renderAll()
	local scrolling = player.PlayerGui.ScreenGui.Frames.Worlds.ScrollingFrame

	-- Seed overlayTemplate from whichever card already has a real one before
	-- rendering any card -- otherwise a card that needs the cloned fallback
	-- but is iterated before the one real overlay is found would miss it on
	-- this pass (WorldData.Worlds iterates 1-5 in order; World1 specifically
	-- has no authored overlay, so it must never be the first one checked).
	if not overlayTemplate then
		for _, world in WorldData.Worlds do
			local card = scrolling:FindFirstChild("World" .. world.Id)
			if card then
				findLockOverlay(card :: Frame)
				if overlayTemplate then
					break
				end
			end
		end
	end

	for _, world in WorldData.Worlds do
		local card = scrolling:FindFirstChild("World" .. world.Id)
		if card then
			renderWorldCard(card, world)
		end
	end
end

local function applyDataUpdate(data: { unlockedWorlds: { number }? })
	if data.unlockedWorlds ~= nil then
		local set = {}
		for _, worldId in data.unlockedWorlds do
			set[worldId] = true
		end
		unlockedWorlds = set
		renderAll()
	end
end

-- §13 QA: `initialSnapshot` is RequestPlayerDataSnapshot's one-shot pull at
-- boot -- see server/init.server.luau's comment on the join-time race this
-- fixes (unlockedWorlds otherwise only arrives via a push that can fire
-- before this Controller has connected its listener).
function WorldController.Init(initialSnapshot: { unlockedWorlds: { number }? }?)
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

	if initialSnapshot then
		applyDataUpdate(initialSnapshot)
	else
		renderAll()
	end

	local playerDataUpdated = remotesFolder:FindFirstChild("PlayerDataUpdated") :: RemoteEvent
	playerDataUpdated.OnClientEvent:Connect(applyDataUpdate)

	print("[WorldController] Init")
end

return WorldController
