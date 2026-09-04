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
-- finalize.
--
-- QA pass 2: claiming is now instant on proximity -- the old Agility-gated
-- dwell timer (wait a few seconds after touching a cart before it attached)
-- was removed along with the Agility stat entirely; it read as unresponsive/
-- laggy rather than a real strategic delay. `tryClaimCart` below resolves
-- synchronously in the same Heartbeat tick a player enters claim radius.

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

-- QA pass 2: no `claiming` lock field anymore -- that existed only to guard
-- the Agility-gated delay's async window against a double-claim race. Claims
-- resolve synchronously now, so there's no window for one to occur.
type ActiveCart = {
	cover: Model,
	rarity: EconomyConfig.RarityName,
	worldId: number,
	zoneIndex: number,
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

-- World 1 economy rebalance, GDD v3 �12: rarity odds now scale with zone
-- depth -- a Legendary/Secret should almost never spawn in Zone 1 and
-- become meaningfully more common by Zone 10+. Previously rarity was
-- pure-Luck with zero zone term, so every Zone 1-13 had identical odds.
--
-- QA pass 2: GDD �12's literal "ZoneLuck = the zone number" only ever
-- amplifies (zone 1's ZoneLuck=1 leaves the already-nonzero base Legendary/
-- Secret weights completely unchanged) -- confirmed live: a fresh Zone 1
-- run showed 2 Legendaries at once, which isn't "almost never." Pivoted at
-- Zone 5 instead (ZoneLuck = zoneIndex/5) so early Zones actively SUPPRESS
-- rarity below the base table (LuckReallocate's shift formula runs the same
-- reallocation in reverse for a sub-1 Luck value -- verified it never goes
-- negative across Zones 1-13), Zone 5 sits at the original base rate, and
-- Zones 6-13 ramp up above it. Still cap-bounded at any magnitude
-- (EconomyConfig.Luck.ShiftCap), per GDD �12's own saturation table.
local function rollRarity(worldId: number, zoneIndex: number, position: Vector3): EconomyConfig.RarityName
	local nearestPlayer = findNearestPlayerInWorld(worldId, position)
	local zoneLuck = zoneIndex / 5
	local luck = nearestPlayer
			and IndexService.GetLuck(nearestPlayer)
				* MonetizationService.GetLuckMultiplier(nearestPlayer)
				* EconomyMath.GetRebirthLuckMultiplier(EconomyService.GetLevelState(nearestPlayer).rebirthCount)
				* zoneLuck
		or zoneLuck
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

	-- Whole-cover gentle bob + a real Y-axis spin (every tier gets a subtle
	-- turn, not just Rare+ -- a perfectly still cover reads as a dead prop
	-- from across the map even with particles/billboard going). Driven from
	-- Heartbeat rather than two competing TweenService yoyos: bob and spin
	-- both touch root.CFrame every frame, and a tweened bob would otherwise
	-- get clobbered by a tweened spin (or vice versa) fighting for the same
	-- property. IdleSpinSpeed stays the per-rarity dramatic ramp-up (GDD:
	-- "higher rarities should have more dramatic animation"); BASE_SPIN_SPEED
	-- is the floor so even Common (IdleSpinSpeed = 0) still visibly turns.
	local BASE_SPIN_SPEED = 0.25 -- radians/sec, applied on top of IdleSpinSpeed
	local baseCFrame = root.CFrame
	local spinSpeed = BASE_SPIN_SPEED + display.IdleSpinSpeed
	local spinAngle = 0
	local elapsed = 0
	local heartbeatConnection: RBXScriptConnection
	heartbeatConnection = RunService.Heartbeat:Connect(function(dt: number)
		if not root.Parent then
			heartbeatConnection:Disconnect()
			return
		end
		elapsed += dt
		spinAngle += spinSpeed * dt
		local bobOffset = (display.IdleBobAmplitude * 0.5) * (1 - math.cos(elapsed * math.pi / display.IdleBobSpeed))
		root.CFrame = baseCFrame * CFrame.new(0, bobOffset, 0) * CFrame.Angles(0, spinAngle, 0)
	end)
end

local function spawnCartAt(zone: ZoneRuntime, attachment: Attachment)
	local rarity = rollRarity(zone.worldId, zone.zoneIndex, attachment.WorldPosition)
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
	-- Bottom-aligned on the spawn point rather than centered on it -- with
	-- the covers now scaled up to a real, "hunt me from across the map"
	-- size, centering would sink half the model into the ground.
	local spawnPos = attachment.WorldPosition
	root.CFrame = CFrame.new(spawnPos.X, spawnPos.Y + root.Size.Y / 2, spawnPos.Z)
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
-- decides who "gets" a cart). QA pass 2: resolves instantly and
-- synchronously -- no Agility-gated dwell timer anymore (see this Service's
-- own top-of-file comment).
local function tryClaimCart(player: Player, zone: ZoneRuntime, attachment: Attachment)
	local key = cartKey(zone.worldId, zone.zoneIndex, attachment.Name)
	local entry = activeCarts[key]
	if not entry then
		return
	end

	if zone.zoneIndex > PushPowerService.GetUnlockedZoneIndex(player, zone.worldId) then
		return -- §3.5.4: this Zone isn't this player's active cart-source yet
	end

	if EconomyService.GetTrainCount(player) >= UpgradeService.GetCapacity(player) then
		return
	end

	local rarity = entry.rarity
	local cartId = rollCartId(rarity, zone.worldId)
	local claimPosition = entry.cover:GetPivot().Position

	-- Remove from the claimable table immediately (no double-claim), but
	-- the cover Instance itself stays in Workspace a little longer so
	-- LostCartRevealController has something to animate -- see this
	-- Service's own top-of-file comment on why that split exists.
	activeCarts[key] = nil

	-- Lost Cart GDD v3 �5.3: SizeRoll is rolled once, here, server-side --
	-- never client-supplied -- so the cart's weight is fixed for its whole
	-- lifetime in the train regardless of how many times Load gets read.
	local sizeRoll = EconomyConfig.CartWeight.SizeRollMin
		+ math.random() * (EconomyConfig.CartWeight.SizeRollMax - EconomyConfig.CartWeight.SizeRollMin)
	local weight = EconomyMath.GetCartWeight(rarity, zone.zoneIndex, sizeRoll)

	EconomyService.AddCartToTrain(
		player,
		{ rarity = rarity, world = zone.worldId, zone = zone.zoneIndex, cartId = cartId, weight = weight }
	)

	local cartEntry = cartId and LostCartData.GetCart(cartId)
	local isNew = cartId ~= nil and IndexService.RecordDiscovery(player, cartId)
	local display = CartData.RarityDisplay[rarity]

	local cartClaimed = remotesFolder:FindFirstChild("CartClaimed") :: RemoteEvent
	cartClaimed:FireClient(player, { rarity = rarity })

	local cartRevealed = remotesFolder:FindFirstChild("CartRevealed") :: RemoteEvent
	cartRevealed:FireClient(player, {
		cover = entry.cover,
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
		if entry.cover.Parent then
			entry.cover:Destroy()
		end
		despawnAndScheduleRespawn(zone, attachment)
	end)
end

local function heartbeatCheck()
	for _, player in Players:GetPlayers() do
		-- World unlocks are now Rebirth-gated (Phase 2), not Total-Level-gated --
		-- Rebirth count only changes on an explicit RequestRebirth call, so
		-- WorldService.CheckWorldUnlocks is triggered from RebirthService
		-- directly instead of polled here every frame.
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
						if entry then
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

	for _, worldEntry in WorldData.Worlds do
		local worldFolder = Workspace.Worlds:FindFirstChild(worldEntry.FolderName) :: Folder
		local worldZones = {}
		zonesByWorld[worldEntry.Id] = worldZones

		-- Phase 2: per-World zone count, not a shared global -- the Main Lane
		-- (World5) now runs 13 Zones while the Rebirth-gated bonus Worlds
		-- (1-4) stay at their original 8.
		for zoneIndex = 1, worldEntry.ZoneCount do
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
