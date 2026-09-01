--!strict
-- Per-zone spawn/despawn loop (�5.2/�4.1.1). Phase 3: generalizes across all
-- 8 Zones of World 1 (per-zone despawn budget curve formula still deferred
-- to Phase 5/12 -- each Zone keeps Phase 1/2's small fixed spawn-point
-- count for now). Claim eligibility is now gated per-cart by the Zone it
-- spawned in against the player's unlocked-Zone frontier (�3.5.4) --
-- earlier Zones stay fully farmable, a Zone beyond the frontier simply
-- doesn't serve that player yet (per-cart, so a further-along player in the
-- same server can still farm it).

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
local PushPowerService = require(script.Parent.PushPowerService)

local CartSpawnService = {}

local CURRENT_WORLD = 1 -- Phase 3 is World 1 only; Phase 5 generalizes

type ActiveCart = {
	cart: Model,
	rarity: string,
	zoneIndex: number,
	claiming: Player?,
}

type ZoneRuntime = {
	zoneIndex: number,
	folder: Folder,
	attachments: { Attachment },
}

local activeCarts: { [string]: ActiveCart } = {} -- keyed "<zoneIndex>_<attachmentName>"
local zones: { ZoneRuntime } = {}
local remotesFolder: Folder
local cartTemplate: Model

local function cartKey(zoneIndex: number, attachmentName: string): string
	return zoneIndex .. "_" .. attachmentName
end

-- �4.1.1: rarity is rolled at spawn time, not collection time. Luck is
-- fixed at x1 until Phase 7 wires a real per-player Luck value through here.
local function rollRarity(): string
	local weights = EconomyMath.LuckReallocate(1)
	return EconomyMath.RollRarity(weights)
end

local function spawnCartAt(zone: ZoneRuntime, attachment: Attachment)
	local rarity = rollRarity()
	local cart = cartTemplate:Clone()
	cart:PivotTo(CFrame.new(attachment.WorldPosition))

	local display = CartData.RarityDisplay[rarity]
	local body = cart:FindFirstChild("Body") :: BasePart?
	if body and display then
		body.Color = Color3.new(display.Color[1], display.Color[2], display.Color[3])
	end

	cart.Parent = zone.folder
	activeCarts[cartKey(zone.zoneIndex, attachment.Name)] = {
		cart = cart,
		rarity = rarity,
		zoneIndex = zone.zoneIndex,
		claiming = nil,
	}
end

local function despawnAndScheduleRespawn(zone: ZoneRuntime, attachment: Attachment)
	local key = cartKey(zone.zoneIndex, attachment.Name)
	activeCarts[key] = nil
	local respawnDelay = math.random(EconomyConfig.Spawn.RespawnDelayMin, EconomyConfig.Spawn.RespawnDelayMax)
	task.delay(respawnDelay, function()
		if not activeCarts[key] then
			spawnCartAt(zone, attachment)
		end
	end)
end

-- Server-authoritative claim: proximity + open Capacity + Zone unlocked for
-- this player, exclusive-on-touch (�4.1.5 -- no client ever decides who
-- "gets" a cart).
local function tryClaimCart(player: Player, zone: ZoneRuntime, attachment: Attachment)
	local key = cartKey(zone.zoneIndex, attachment.Name)
	local entry = activeCarts[key]
	if not entry or entry.claiming then
		return
	end

	if zone.zoneIndex > PushPowerService.GetUnlockedZoneIndex(player) then
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
		stillActive.cart:Destroy()
		despawnAndScheduleRespawn(zone, attachment)

		EconomyService.AddCartToTrain(player, { rarity = rarity, world = CURRENT_WORLD, zone = zone.zoneIndex })

		local cartClaimed = remotesFolder:FindFirstChild("CartClaimed") :: RemoteEvent
		cartClaimed:FireClient(player, { rarity = rarity })
	end)
end

local function heartbeatCheck()
	for _, player in Players:GetPlayers() do
		PushPowerService.CheckZoneUnlocks(player)

		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if root then
			local claimRadius = EconomyConfig.Collection.BaseClaimRadius
				* EconomyMath.GetRangeRadiusMultiplier(UpgradeService.GetLevel(player, "range"))

			for _, zone in zones do
				for _, attachment in zone.attachments do
					local entry = activeCarts[cartKey(zone.zoneIndex, attachment.Name)]
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

local function buildZoneRuntime(zoneIndex: number): ZoneRuntime
	local zoneFolder = Workspace.Worlds.World1_ParkingLot.Zones:FindFirstChild("Zone" .. zoneIndex) :: Folder
	local spawnAnchor = zoneFolder.ZoneSpawnPoints.SpawnPointAnchor :: BasePart

	local attachments = {}
	for _, child in spawnAnchor:GetChildren() do
		if child:IsA("Attachment") then
			table.insert(attachments, child)
		end
	end

	return { zoneIndex = zoneIndex, folder = zoneFolder, attachments = attachments }
end

function CartSpawnService.Init()
	remotesFolder = RemotesSetup.CreateAll()
	cartTemplate = ServerStorage.CartTemplates.PH_Cart_Common

	local zonesPerWorld = EconomyConfig.Cart.ZonesPerWorld
	for zoneIndex = 1, zonesPerWorld do
		local zone = buildZoneRuntime(zoneIndex)
		table.insert(zones, zone)
		for _, attachment in zone.attachments do
			spawnCartAt(zone, attachment)
		end
	end

	RunService.Heartbeat:Connect(heartbeatCheck)

	print("[CartSpawnService] Init")
end

return CartSpawnService
