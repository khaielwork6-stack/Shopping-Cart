--!strict
-- Per-zone spawn/despawn loop (�5.2/�4.1.1). Phase 2: fixed-count spawn at
-- World1/Zone1 only (per-zone despawn budget curve generalizes in Phase
-- 3/5), now with a rarity roll at spawn time (�4.1.1) and Capacity/
-- Agility/Range-driven claim behavior (�3.7) sourced from UpgradeService.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local EconomyConfig = require(ReplicatedStorage.Shared.Configs.EconomyConfig)
local CartData = require(ReplicatedStorage.Shared.Configs.CartData)
local EconomyMath = require(ReplicatedStorage.Shared.Modules.EconomyMath)
local RemotesSetup = require(ReplicatedStorage.Shared.Modules.RemotesSetup)
local EconomyService = require(script.Parent.EconomyService)
local UpgradeService = require(script.Parent.UpgradeService)

local CartSpawnService = {}

type ActiveCart = {
	cart: Model,
	rarity: string,
	claiming: Player?,
}

local activeCarts: { [string]: ActiveCart } = {}
local remotesFolder: Folder
local zone1: Folder
local spawnAnchor: BasePart
local cartTemplate: Model

local function getSpawnAttachments(): { Attachment }
	local attachments = {}
	for _, child in spawnAnchor:GetChildren() do
		if child:IsA("Attachment") then
			table.insert(attachments, child)
		end
	end
	return attachments
end

-- �4.1.1: rarity is rolled at spawn time, not collection time. Luck is
-- fixed at x1 until Phase 7 wires a real per-player Luck value through here.
local function rollRarity(): string
	local weights = EconomyMath.LuckReallocate(1)
	return EconomyMath.RollRarity(weights)
end

local function spawnCartAt(attachment: Attachment)
	local rarity = rollRarity()
	local cart = cartTemplate:Clone()
	cart:PivotTo(CFrame.new(attachment.WorldPosition))

	local display = CartData.RarityDisplay[rarity]
	local body = cart:FindFirstChild("Body") :: BasePart?
	if body and display then
		body.Color = Color3.new(display.Color[1], display.Color[2], display.Color[3])
	end

	cart.Parent = zone1
	activeCarts[attachment.Name] = { cart = cart, rarity = rarity, claiming = nil }
end

local function despawnAndScheduleRespawn(attachment: Attachment)
	activeCarts[attachment.Name] = nil
	local respawnDelay = math.random(EconomyConfig.Spawn.RespawnDelayMin, EconomyConfig.Spawn.RespawnDelayMax)
	task.delay(respawnDelay, function()
		if not activeCarts[attachment.Name] then
			spawnCartAt(attachment)
		end
	end)
end

-- Server-authoritative claim: proximity + open Capacity, exclusive-on-touch
-- (�4.1.5 -- no client ever decides who "gets" a cart).
local function tryClaimCart(player: Player, attachment: Attachment)
	local entry = activeCarts[attachment.Name]
	if not entry or entry.claiming then
		return
	end

	if EconomyService.GetTrainCount(player) >= UpgradeService.GetCapacity(player) then
		return
	end

	entry.claiming = player

	local collectTime = EconomyMath.GetAgilityCollectTime(UpgradeService.GetLevel(player, "agility"))

	task.delay(collectTime, function()
		local stillActive = activeCarts[attachment.Name]
		if not stillActive or stillActive.claiming ~= player then
			return -- cart was already resolved/removed
		end

		if not player.Parent then
			-- player disconnected mid-collect; release so someone else can claim it
			stillActive.claiming = nil
			return
		end

		local rarity = stillActive.rarity
		stillActive.cart:Destroy()
		despawnAndScheduleRespawn(attachment)

		EconomyService.AddCartToTrain(player, { rarity = rarity, world = 1, zone = 1 })

		local cartClaimed = remotesFolder:FindFirstChild("CartClaimed") :: RemoteEvent
		cartClaimed:FireClient(player, { rarity = rarity })
	end)
end

local function heartbeatCheck()
	local attachments = getSpawnAttachments()
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if root then
			local claimRadius = EconomyConfig.Collection.BaseClaimRadius
				* EconomyMath.GetRangeRadiusMultiplier(UpgradeService.GetLevel(player, "range"))

			for _, attachment in attachments do
				local entry = activeCarts[attachment.Name]
				if entry and not entry.claiming then
					local distance = (root.Position - attachment.WorldPosition).Magnitude
					if distance <= claimRadius then
						tryClaimCart(player, attachment)
					end
				end
			end
		end
	end
end

function CartSpawnService.Init()
	remotesFolder = RemotesSetup.CreateAll()
	zone1 = Workspace.Worlds.World1_ParkingLot.Zones.Zone1
	spawnAnchor = zone1.ZoneSpawnPoints.SpawnPointAnchor
	cartTemplate = ServerStorage.CartTemplates.PH_Cart_Common

	for _, attachment in getSpawnAttachments() do
		spawnCartAt(attachment)
	end

	RunService.Heartbeat:Connect(heartbeatCheck)

	print("[CartSpawnService] Init")
end

return CartSpawnService
