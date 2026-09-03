--!strict
-- Per-zone spawn/despawn loop (§5.2/§4.1.1), now driving the Lost Cart GDD's
-- real spawn -> hunt -> claim -> reveal loop instead of the old single
-- generic PH_Cart_Common. Generalizes across all 5 Worlds x 8 Zones; each
-- Zone keeps its small fixed spawn-point count (Phase 12's budget curve is
-- still deferred). Claim eligibility is gated per-cart by (a) matching the
-- player's current World (WorldService) and (b) the Zone it spawned in
-- against that World's unlocked-Zone frontier for this player (§3.5.4).
--
-- Lost Cart GDD security note (see LostCartData's own comment): the world
-- spawn is one of the 6 rarity COVER models only, carrying a Rarity
-- attribute and nothing else -- no client, including the eventual claimer's
-- own, ever knows the real CartID until CartRevealed fires at claim
-- finalize. The claim-timing mechanic itself (proximity + Agility-gated
-- dwell) is unchanged from the pre-GDD system -- this project's existing,
-- balanced stand-in for the GDD's "touch" trigger; re-architecting that
-- into literal physics Touched detection wasn't requested and would ripple
-- into the Agility upgrade stat's whole meaning.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local EconomyConfig = require(ReplicatedStorage.Shared.Configs.EconomyConfig)
local WorldData = require(ReplicatedStorage.Shared.Configs.WorldData)
local CartData = require(ReplicatedStorage.Shared.Configs.CartData)
local LostCartData = require(ReplicatedStorage.Shared.Configs.LostCartData)
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
	cover: Model,
	rarity: EconomyConfig.RarityName,
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
local coverTemplates: { [EconomyConfig.RarityName]: Model } = {}

local function cartKey(worldId: number, zoneIndex: number, attachmentName: string): string
	return worldId .. "_" .. zoneIndex .. "_" .. attachmentName
end

-- §4.1.1: "rolled at spawn time... using the current server-side Luck value
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

local function rollRarity(worldId: number, position: Vector3): EconomyConfig.RarityName
	local nearestPlayer = findNearestPlayerInWorld(worldId, position)
	local luck = nearestPlayer
		and IndexService.GetLuck(nearestPlayer) * MonetizationService.GetLuckMultiplier(nearestPlayer)
		or 1
	local weights = EconomyMath.LuckReallocate(luck)
	return EconomyMath.RollRarity(weights) :: EconomyConfig.RarityName
end

-- Lost Cart GDD "World Affinity": weighted pick among that rarity's real
-- carts, using each cart's own NativeWorld weight for the World this spawn
-- actually happened in. Server-only -- this is the one place the real
-- CartID is ever decided.
local function rollCartId(rarity: EconomyConfig.RarityName, worldId: number): string?
	local pool = LostCartData.CartIdsByRarity[rarity]
	if not pool or #pool == 0 then
		return nil
	end

	local totalWeight = 0
	for _, cartId in pool do
		totalWeight += LostCartData.GetWorldWeight(cartId, worldId)
	end
	if totalWeight <= 0 then
		return pool[math.random(1, #pool)]
	end

	local roll = math.random() * totalWeight
	local cumulative = 0
	for _, cartId in pool do
		cumulative += LostCartData.GetWorldWeight(cartId, worldId)
		if roll <= cumulative then
			return cartId
		end
	end
	return pool[#pool]
end

-- Phase 10 (§8): "a soft chime audible within ~40 studs" / "a distinct
-- 1-second particle beam visible to nearby players" both need every player
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

-- GDD §"Cover Presentation": idle ambience while a cover sits unclaimed in
-- the world, intensity driven entirely by CartData.RarityDisplay so Common
-- stays genuinely plain and Secret is unmistakable from across the map.
-- Every piece here (PointLight brightness, ParticleEmitter rate, the
-- floating "[RARITY] / ?" billboard's bob/scale/spin) is set up once as a
-- looping TweenService animation (RepeatCount = -1) -- these replicate their
-- animated properties to every client for free and cost nothing per-frame
-- server-side, the same pattern already proven on the Corral's ambient glow.
local function applyCoverPresentation(cover: Model, rarity: EconomyConfig.RarityName)
	local display = CartData.RarityDisplay[rarity]
	local root = cover.PrimaryPart
	if not display or not root then
		return
	end

	local color = Color3.new(display.Color[1], display.Color[2], display.Color[3])

	if display.IdleGlowBrightness > 0 then
		local light = Instance.new("PointLight")
		light.Name = "PH_CoverIdleGlow"
		light.Color = color
		light.Range = display.IdleGlowRange
		light.Brightness = display.IdleGlowBrightness * 0.5
		light.Parent = root
		TweenService
			:Create(
				light,
				TweenInfo.new(1.4, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
				{ Brightness = display.IdleGlowBrightness }
			)
			:Play()
	end

	if display.IdleParticleRate > 0 then
		local attachment = Instance.new("Attachment")
		attachment.Name = "PH_CoverIdleParticleAnchor"
		attachment.Position = Vector3.new(0, root.Size.Y * 0.5 + 0.5, 0)
		attachment.Parent = root

		local particles = Instance.new("ParticleEmitter")
		particles.Color = ColorSequence.new(color)
		particles.Lifetime = NumberRange.new(0.9, 1.4)
		particles.Speed = NumberRange.new(1, 2.5)
		particles.SpreadAngle = Vector2.new(25, 25)
		particles.Size = NumberSequence.new(0.22)
		particles.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.1),
			NumberSequenceKeypoint.new(1, 1),
		})
		particles.Rate = display.IdleParticleRate
		particles.Parent = attachment
	end

	if display.HasBeam then
		local beam = Instance.new("Part")
		beam.Name = "PH_CoverBeam"
		beam.Size = Vector3.new(2, 200, 2)
		beam.CFrame = root.CFrame * CFrame.new(0, 100, 0)
		beam.Anchored = true
		beam.CanCollide = false
		beam.CanQuery = false
		beam.CanTouch = false
		beam.Material = Enum.Material.Neon
		beam.Color = color
		beam.Transparency = 0.75
		beam.Parent = cover
		TweenService
			:Create(
				beam,
				TweenInfo.new(1.0, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
				{ Transparency = 0.4 }
			)
			:Play()
	end

	-- Floating "[RARITY] / ?" presentation, alive from far away without
	-- turning into a UI wall -- gentle float + scale-breathe for every
	-- tier, plus rotation for the higher ones (GDD: "higher rarities
	-- should have more dramatic animation").
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "PH_CoverRarityLabel"
	billboard.Size = UDim2.fromOffset(140, 70)
	billboard.StudsOffset = Vector3.new(0, root.Size.Y * 0.5 + 2.5, 0)
	billboard.AlwaysOnTop = true
	billboard.MaxDistance = 250
	billboard.Parent = root

	local rarityLabel = Instance.new("TextLabel")
	rarityLabel.Name = "RarityText"
	rarityLabel.BackgroundTransparency = 1
	rarityLabel.Size = UDim2.new(1, 0, 0.55, 0)
	rarityLabel.Font = Enum.Font.GothamBlack
	rarityLabel.TextScaled = true
	rarityLabel.Text = string.upper(display.DisplayName)
	rarityLabel.TextColor3 = color
	rarityLabel.TextStrokeTransparency = 0.2
	rarityLabel.Parent = billboard

	local questionLabel = Instance.new("TextLabel")
	questionLabel.Name = "QuestionText"
	questionLabel.BackgroundTransparency = 1
	questionLabel.Size = UDim2.new(1, 0, 0.45, 0)
	questionLabel.Position = UDim2.new(0, 0, 0.55, 0)
	questionLabel.Font = Enum.Font.GothamBlack
	questionLabel.TextScaled = true
	questionLabel.Text = "?"
	questionLabel.TextColor3 = Color3.new(1, 1, 1)
	questionLabel.TextStrokeTransparency = 0.2
	questionLabel.Parent = billboard

	-- Gentle vertical float, looping.
	local floatInfo = TweenInfo.new(1.6 + rarity:len() * 0.01, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
	TweenService
		:Create(billboard, floatInfo, { StudsOffset = billboard.StudsOffset + Vector3.new(0, 0.5, 0) })
		:Play()

	-- Scale-breathe, a touch stronger per rarity tier.
	local breatheAmount = 0.06 + (display.IdleParticleRate * 0.003)
	local baseSize = billboard.Size
	local biggerSize = UDim2.fromOffset(baseSize.X.Offset * (1 + breatheAmount), baseSize.Y.Offset * (1 + breatheAmount))
	TweenService
		:Create(billboard, TweenInfo.new(1.1, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), { Size = biggerSize })
		:Play()

	-- Subtle question-mark rotation, only for the tiers that "should
	-- immediately make somebody run across the map" (Rare+).
	if display.IdleSpinSpeed > 0 then
		TweenService
			:Create(
				questionLabel,
				TweenInfo.new(1.4, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
				{ Rotation = 12 }
			)
			:Play()
	end

	-- Whole-cover gentle bob + (higher tiers) slow spin, driven the same
	-- looping-tween way -- the model's own CFrame animates independent of
	-- the billboard's StudsOffset animation above.
	local baseCFrame = root.CFrame
	TweenService
		:Create(
			root,
			TweenInfo.new(display.IdleBobSpeed, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
			{ CFrame = baseCFrame * CFrame.new(0, display.IdleBobAmplitude, 0) }
		)
		:Play()
end

local function spawnCartAt(zone: ZoneRuntime, attachment: Attachment)
	local rarity = rollRarity(zone.worldId, attachment.WorldPosition)
	local template = coverTemplates[rarity]
	if not template then
		return
	end

	local cover = template:Clone()
	-- Sets the PrimaryPart's own CFrame directly rather than Model:PivotTo --
	-- several of the imported cover/cart meshes carry a custom WorldPivot
	-- baked in by their export tool (confirmed live: PivotTo alone landed
	-- one rarity's cover hundreds of studs away, in the sky) exactly like
	-- CartVisuals.PrepareCart's own comment already documented for the cart
	-- models. Safe here because every one of these is a single-MeshPart
	-- model -- no sibling parts whose relative offset would need to move
	-- with it.
	local root = cover.PrimaryPart :: BasePart
	-- The imported cover meshes ship Anchored = false -- confirmed live: an
	-- unanchored cover would sit correctly for a moment, then drift/fall
	-- once physics/gravity touched it. These are static world pickups, not
	-- physical objects, so every part gets anchored (matches CartVisuals.
	-- PrepareCart's same treatment of the real cart models).
	for _, descendant in cover:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
		end
	end
	root.CFrame = CFrame.new(attachment.WorldPosition)
	-- Security: the world object only ever knows its own rarity, never the
	-- real CartID -- LostCartData's Security note.
	cover:SetAttribute("Rarity", rarity)
	applyCoverPresentation(cover, rarity)

	cover.Parent = zone.folder
	activeCarts[cartKey(zone.worldId, zone.zoneIndex, attachment.Name)] = {
		cover = cover,
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
-- this player in this World, exclusive-on-touch (§4.1.5 -- no client ever
-- decides who "gets" a cart).
local function tryClaimCart(player: Player, zone: ZoneRuntime, attachment: Attachment)
	local key = cartKey(zone.worldId, zone.zoneIndex, attachment.Name)
	local entry = activeCarts[key]
	if not entry or entry.claiming then
		return
	end

	if zone.zoneIndex > PushPowerService.GetUnlockedZoneIndex(player, zone.worldId) then
		return -- §3.5.4: this Zone isn't this player's active cart-source yet
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
		local cartId = rollCartId(rarity, zone.worldId)
		local claimPosition = stillActive.cover:GetPivot().Position

		-- Remove from the claimable table immediately (no double-claim), but
		-- the cover Instance itself stays in Workspace a little longer so
		-- LostCartRevealController has something to animate -- see this
		-- Service's own top-of-file comment on why that split exists.
		activeCarts[key] = nil

		EconomyService.AddCartToTrain(player, { rarity = rarity, world = zone.worldId, zone = zone.zoneIndex, cartId = cartId })

		local cartEntry = cartId and LostCartData.GetCart(cartId)
		local isNew = cartId ~= nil and IndexService.RecordDiscovery(player, cartId)
		local display = CartData.RarityDisplay[rarity]

		local cartClaimed = remotesFolder:FindFirstChild("CartClaimed") :: RemoteEvent
		cartClaimed:FireClient(player, { rarity = rarity })

		local cartRevealed = remotesFolder:FindFirstChild("CartRevealed") :: RemoteEvent
		cartRevealed:FireClient(player, {
			cover = stillActive.cover,
			cartId = cartId,
			displayName = cartEntry and cartEntry.DisplayName or "???",
			rarity = rarity,
			isNew = isNew == true,
			mutation = nil, -- Lost Cart GDD Phase 4, not built yet -- see MutationData's own comment
		})

		if rarity == "Legendary" then
			firePlayersInWorld(zone.worldId, "LegendaryCartClaimed", { position = claimPosition })
		end

		-- Give the claiming client's reveal sequence time to actually see
		-- the cover before it's gone, then clean up + schedule the respawn
		-- exactly like before.
		local revealWindow = (display and display.RevealDuration or 0.3) + 0.35
		task.delay(revealWindow, function()
			if stillActive.cover.Parent then
				stillActive.cover:Destroy()
			end
			despawnAndScheduleRespawn(zone, attachment)
		end)
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

	local coversFolder = ServerStorage.LostCart.Covers :: Folder
	for rarity, display in CartData.RarityDisplay do
		local template = coversFolder:FindFirstChild(display.CoverModelName) :: Model?
		assert(template, "CartSpawnService: missing cover model '" .. display.CoverModelName .. "' for rarity " .. rarity)
		coverTemplates[rarity] = template
	end

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
