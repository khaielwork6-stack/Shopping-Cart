--!strict
-- Per-zone spawn/despawn loop (�5.2/�4.1.1). Phase 1: basic version -- fixed-
-- count spawn at World1/Zone1 only, no per-zone despawn budget curve yet
-- (that generalizes in Phase 3/5). Proximity claim + collection timer per
-- �4.1.2.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local EconomyConfig = require(ReplicatedStorage.Shared.Configs.EconomyConfig)
local RemotesSetup = require(ReplicatedStorage.Shared.Modules.RemotesSetup)
local EconomyService = require(script.Parent.EconomyService)

local CartSpawnService = {}

-- Phase 1 stopgaps -- both become real, purchasable stats in Phase 2.
local HARDCODED_CAPACITY = 10
local BASE_COLLECT_TIME = EconomyConfig.UpgradeEffects.agility.CollectTimeBase -- Agility level 0

type ActiveCart = {
	cart: Model,
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

local function spawnCartAt(attachment: Attachment)
	local cart = cartTemplate:Clone()
	cart:PivotTo(CFrame.new(attachment.WorldPosition))
	cart.Parent = zone1
	activeCarts[attachment.Name] = { cart = cart, claiming = nil }
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

	if EconomyService.GetTrainCount(player) >= HARDCODED_CAPACITY then
		return
	end

	entry.claiming = player

	task.delay(BASE_COLLECT_TIME, function()
		local stillActive = activeCarts[attachment.Name]
		if not stillActive or stillActive.claiming ~= player then
			return -- cart was already resolved/removed
		end

		if not player.Parent then
			-- player disconnected mid-collect; release so someone else can claim it
			stillActive.claiming = nil
			return
		end

		stillActive.cart:Destroy()
		despawnAndScheduleRespawn(attachment)

		EconomyService.AddCartToTrain(player, { rarity = "Common", world = 1, zone = 1 })

		local cartClaimed = remotesFolder:FindFirstChild("CartClaimed") :: RemoteEvent
		cartClaimed:FireClient(player, { rarity = "Common" })
	end)
end

local function heartbeatCheck()
	local attachments = getSpawnAttachments()
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if root then
			for _, attachment in attachments do
				local entry = activeCarts[attachment.Name]
				if entry and not entry.claiming then
					local distance = (root.Position - attachment.WorldPosition).Magnitude
					if distance <= EconomyConfig.Collection.BaseClaimRadius then
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
