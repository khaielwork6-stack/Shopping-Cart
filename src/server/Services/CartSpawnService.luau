--!strict
-- Per-zone spawn/despawn loop (�5.2/�4.1.1). Phase 5: generalizes across all
-- 5 Worlds x 8 Zones (per-zone despawn budget curve formula still deferred
-- to Phase 12 -- each Zone keeps Phase 1/2's small fixed spawn-point count
-- for now). Claim eligibility is gated per-cart by (a) matching the
-- player's current World (WorldService) and (b) the Zone it spawned in
-- against that World's unlocked-Zone frontier for this player (�3.5.4) --
-- earlier Zones stay fully farmable, a Zone beyond the frontier simply
-- doesn't serve that player yet.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local EconomyConfig = require(ReplicatedStorage.Shared.Configs.EconomyConfig)
local WorldData = require(ReplicatedStorage.Shared.Configs.WorldData)
local CartData = require(ReplicatedStorage.Shared.Configs.CartData)
local EconomyMath = require(ReplicatedStorage.Shared.Modules.EconomyMath)
local RemotesSetup = require(ReplicatedStorage.Shared.Modules.RemotesSetup)
local EconomyService = require(script.Parent.EconomyService)
local UpgradeService = require(script.Parent.UpgradeService)
local PushPowerService = require(script.Parent.PushPowerService)
local WorldService = require(script.Parent.WorldService)
local IndexService = require(script.Parent.IndexService)
local MonetizationService = require(script.Parent.MonetizationService)

local CartSpawnService = {}

type ActiveCart = {
	cart: Model,
	rarity: string,
	worldId: number,
	zoneIndex: number,
	claiming: Player?,
}

type ZoneRuntime = {
	worldId: number,
	zoneIndex: number,
	folder: Folder,
	attachments: { Attachment },
}

local activeCarts: { [string]: ActiveCart } = {} -- keyed "<worldId>_<zoneIndex>_<attachmentName>"
local zonesByWorld: { [number]: { ZoneRuntime } } = {}
local remotesFolder: Folder
local cartTemplate: Model

local function cartKey(worldId: number, zoneIndex: number, attachmentName: string): string
	return worldId .. "_" .. zoneIndex .. "_" .. attachmentName
end

-- �4.1.1: "rolled at spawn time... using the current server-side Luck value
-- for whichever player is nearest that spawn point." Falls back to neutral
-- Luck (x1) if no player is currently in that Zone's World (e.g. the
-- initial spawn at boot, before anyone has joined).
local function findNearestPlayerInWorld(worldId: number, position: Vector3): Player?
	local nearest: Player? = nil
	local nearestDistance = math.huge

	for _, player in Players:GetPlayers() do
		if WorldService.GetCurrentWorld(player) == worldId then
			local character = player.Character
			local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
			if root then
				local distance = (root.Position - position).Magnitude
				if distance < nearestDistance then
					nearestDistance = distance
					nearest = player
				end
			end
		end
	end

	return nearest
end

local function rollRarity(worldId: number, position: Vector3): string
	local nearestPlayer = findNearestPlayerInWorld(worldId, position)
	local luck = nearestPlayer
		and IndexService.GetLuck(nearestPlayer) * MonetizationService.GetLuckMultiplier(nearestPlayer)
		or 1
	local weights = EconomyMath.LuckReallocate(luck)
	return EconomyMath.RollRarity(weights)
end

-- Phase 10 (�8): "a soft chime audible within ~40 studs" / "a distinct 1-
-- second particle beam visible to nearby players" both need every player
-- sharing the Legendary cart's World to hear/see it, not just whoever
-- eventually claims it -- CartClaimed alone (single-target) can't do that.
local function firePlayersInWorld(worldId: number, remoteName: string, data: { [string]: any })
	local remote = remotesFolder:FindFirstChild(remoteName) :: RemoteEvent
	for _, player in Players:GetPlayers() do
		if WorldService.GetCurrentWorld(player) == worldId then
			remote:FireClient(player, data)
		end
	end
end

local function spawnCartAt(zone: ZoneRuntime, attachment: Attachment)
	local rarity = rollRarity(zone.worldId, attachment.WorldPosition)
	local cart = cartTemplate:Clone()
	cart:PivotTo(CFrame.new(attachment.WorldPosition))

	local display = CartData.RarityDisplay[rarity]
	local body = cart:FindFirstChild("Body") :: BasePart?
	if body and display then
		body.Color = Color3.new(display.Color[1], display.Color[2], display.Color[3])
	end

	cart.Parent = zone.folder
	activeCarts[cartKey(zone.worldId, zone.zoneIndex, attachment.Name)] = {
		cart = cart,
		rarity = rarity,
		worldId = zone.worldId,
		zoneIndex = zone.zoneIndex,
		claiming = nil,
	}

	if rarity == "Legendary" then
		firePlayersInWorld(zone.worldId, "LegendaryCartSpawned", { position = attachment.WorldPosition })
	end
end

local function despawnAndScheduleRespawn(zone: ZoneRuntime, attachment: Attachment)
	local key = cartKey(zone.worldId, zone.zoneIndex, attachment.Name)
	activeCarts[key] = nil
	local respawnDelay = math.random(EconomyConfig.Spawn.RespawnDelayMin, EconomyConfig.Spawn.RespawnDelayMax)
	task.delay(respawnDelay, function()
		if not activeCarts[key] then
			spawnCartAt(zone, attachment)
		end
	end)
end

-- Server-authoritative claim: proximity + open Capacity + Zone unlocked for
-- this player in this World, exclusive-on-touch (�4.1.5 -- no client ever
-- decides who "gets" a cart).
local function tryClaimCart(player: Player, zone: ZoneRuntime, attachment: Attachment)
	local key = cartKey(zone.worldId, zone.zoneIndex, attachment.Name)
	local entry = activeCarts[key]
	if not entry or entry.claiming then
		return
	end

	if zone.zoneIndex > PushPowerService.GetUnlockedZoneIndex(player, zone.worldId) then
		return -- �3.5.4: this Zone isn't this player's active cart-source yet
	end

	if EconomyService.GetTrainCount(player) >= UpgradeService.GetCapacity(player) then
		return
	end

	entry.claiming = player

	local collectTime = EconomyMath.GetAgilityCollectTime(UpgradeService.GetLevel(player, "agility"))

	task.delay(collectTime, function()
		local stillActive = activeCarts[key]
		if not stillActive or stillActive.claiming ~= player then
			return -- cart was already resolved/removed
		end

		if not player.Parent then
			-- player disconnected mid-collect; release so someone else can claim it
			stillActive.claiming = nil
			return
		end

		local rarity = stillActive.rarity
		local claimPosition = stillActive.cart:GetPivot().Position
		stillActive.cart:Destroy()
		despawnAndScheduleRespawn(zone, attachment)

		EconomyService.AddCartToTrain(player, { rarity = rarity, world = zone.worldId, zone = zone.zoneIndex })

		local cartClaimed = remotesFolder:FindFirstChild("CartClaimed") :: RemoteEvent
		cartClaimed:FireClient(player, { rarity = rarity })

		if rarity == "Legendary" then
			firePlayersInWorld(zone.worldId, "LegendaryCartClaimed", { position = claimPosition })
		end
	end)
end

local function heartbeatCheck()
	for _, player in Players:GetPlayers() do
		WorldService.CheckWorldUnlocks(player)
		PushPowerService.CheckZoneUnlocks(player)

		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if root then
			local claimRadius = EconomyConfig.Collection.BaseClaimRadius
				* EconomyMath.GetRangeRadiusMultiplier(UpgradeService.GetLevel(player, "range"))

			-- Only the player's CURRENT World's Zones are checked -- a cart
			-- in a World the player isn't in can never be in claim range
			-- anyway (the Worlds are physically far apart in Workspace), so
			-- this is both a correctness gate and a performance one.
			local currentWorldZones = zonesByWorld[WorldService.GetCurrentWorld(player)]
			if currentWorldZones then
				for _, zone in currentWorldZones do
					for _, attachment in zone.attachments do
						local entry = activeCarts[cartKey(zone.worldId, zone.zoneIndex, attachment.Name)]
						if entry and not entry.claiming then
							local distance = (root.Position - attachment.WorldPosition).Magnitude
							if distance <= claimRadius then
								tryClaimCart(player, zone, attachment)
							end
						end
					end
				end
			end
		end
	end
end

local function buildZoneRuntime(worldId: number, worldFolder: Folder, zoneIndex: number): ZoneRuntime
	local zoneFolder = worldFolder.Zones:FindFirstChild("Zone" .. zoneIndex) :: Folder
	local spawnAnchor = zoneFolder.ZoneSpawnPoints.SpawnPointAnchor :: BasePart

	local attachments = {}
	for _, child in spawnAnchor:GetChildren() do
		if child:IsA("Attachment") then
			table.insert(attachments, child)
		end
	end

	return { worldId = worldId, zoneIndex = zoneIndex, folder = zoneFolder, attachments = attachments }
end

function CartSpawnService.Init()
	remotesFolder = RemotesSetup.CreateAll()
	cartTemplate = ServerStorage.CartTemplates.PH_Cart_Common

	local zonesPerWorld = EconomyConfig.Cart.ZonesPerWorld
	for _, worldEntry in WorldData.Worlds do
		local worldFolder = Workspace.Worlds:FindFirstChild(worldEntry.FolderName) :: Folder
		local worldZones = {}
		zonesByWorld[worldEntry.Id] = worldZones

		for zoneIndex = 1, zonesPerWorld do
			local zone = buildZoneRuntime(worldEntry.Id, worldFolder, zoneIndex)
			table.insert(worldZones, zone)
			for _, attachment in zone.attachments do
				spawnCartAt(zone, attachment)
			end
		end
	end

	RunService.Heartbeat:Connect(heartbeatCheck)

	print("[CartSpawnService] Init")
end

return CartSpawnService
