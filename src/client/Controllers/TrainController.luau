--!strict
-- Client-side visual train rendering (§4.1.3/§4.1.6/§11.1). Purely visual --
-- no physics, no per-cart networked Instance; each carried cart's position
-- is a lerped point along a CFrame-history trail behind the player,
-- reconstructed from the single trainCount value PlayerDataUpdated pushes.
--
-- Also owns the Corral-touch -> RequestReturnCarts trigger for Phase 1,
-- since no dedicated Corral controller exists yet in the Guide's Controller
-- list and this is the closest owning system. Phase 10 (§8) adds the full
-- Game Feel pass on top: collection snap/SFX, the rolling-wheels loop,
-- corral glow/cha-ching/confetti, the Legendary-only screen nudge, and the
-- two Legendary "social beat" broadcasts (spawn chime, collection beam)
-- visible to every player sharing the World, not just the collector.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local Debris = game:GetService("Debris")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CartData = require(ReplicatedStorage.Shared.Configs.CartData)
local WorldData = require(ReplicatedStorage.Shared.Configs.WorldData)
local FormatNumber = require(ReplicatedStorage.Shared.Modules.FormatNumber)
local CartAssembly = require(ReplicatedStorage.Shared.Modules.CartAssembly)

local TrainController = {}

local SPACING = 3 -- studs between train carts (§4.1.3)
local TRAIL_SAMPLE_DISTANCE = 0.5
local MAX_TRAIL_POINTS = 400

-- Cart-model test (see chat): CartBody_Golden's own local axes, as exported,
-- are +X = front (logo panel)/back = handle (-X), +Z/-Z = left/right width,
-- +Y = up -- established by screenshotting the body from each side in Edit
-- mode, not assumed. WheelModel_Industrial's identity rotation already
-- faces the right way for mounting (its axle is local Z, confirmed the same
-- way: an identity-rotated wheel viewed along world Z showed its full round
-- face -- see the wheel-orientation comparison test), so no wheelRotation
-- correction is needed, unlike a differently-exported wheel might.
--
-- Offsets are measured from CartBody_Golden's own bounding box (half-size
-- ~3.96 x 3.43 x 2.85 studs) and adjusted to sit under the visible leg
-- struts rather than at the raw bounding-box corners.
local CART_BODY_TEMPLATE = ReplicatedStorage.Assets.Placeholders:WaitForChild("CartBody_Golden") :: Model
local CART_WHEEL_TEMPLATE = ReplicatedStorage.Assets.Placeholders:WaitForChild("WheelModel_Industrial") :: Model
local CART_WHEEL_OFFSETS: { CartAssembly.WheelOffset } = {
	{ x = 3.0, z = 2.1 }, -- front-left
	{ x = 3.0, z = -2.1 }, -- front-right
	{ x = -3.2, z = 2.1 }, -- back-left
	{ x = -3.2, z = -2.1 }, -- back-right
}
local WHEEL_CENTER_Y = -2.882 -- body-local Y so the wheel's bottom just touches the ground
local WHEEL_RADIUS = 0.552

-- The trail is recorded straight from HumanoidRootPart CFrames, whose
-- forward (LookVector) is local -Z by Roblox's own character-rig
-- convention. The cart body's forward is local +X (see above), so every
-- trail sample needs this fixed remap before it's a valid body CFrame --
-- confirmed empirically in Play mode (see chat), not just derived on paper.
local BODY_FORWARD_ROTATION = CFrame.Angles(0, math.rad(90), 0)

-- Smooth, framerate-independent follow (replaces the old fixed Lerp alpha,
-- which visibly changed speed with frame rate and read as "snappy" at high
-- FPS) -- higher = catches up to the trail faster, lower = looser/laggier.
local FOLLOW_SMOOTHING_RATE = 9

-- Subtle rolling bob/sway (§8's "small and tasteful", not "bouncing around
-- like a toy"): a tiny sine wave keyed to distance actually traveled, not
-- elapsed time, so a stationary cart never bobs in place.
local BOB_AMPLITUDE = 0.05
local BOB_FREQUENCY = 1.35 -- radians per stud traveled

-- Slight lean into turns, derived from how fast the cart's own heading is
-- changing frame to frame -- capped low so it reads as "natural roll," not
-- a toy tipping over. The raw per-frame turn rate is itself clamped before
-- the response multiplier is applied, so a single very-fast direction
-- change (a sharp real turn, or a teleport-like snap) can't spike the lean
-- past its cap even for one frame.
local LEAN_MAX = math.rad(3)
local LEAN_RESPONSE = 0.35
local MAX_TURN_RATE = 6 -- radians/second, clamps the input before LEAN_RESPONSE scales it

local COLLECT_POP_SCALE_START = 0.85
local COLLECT_POP_INFO = TweenInfo.new(0.15, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

local ROLL_VOLUME_PER_CART = 0.035
local ROLL_MAX_VOLUME = 0.5

local LEGENDARY_CHIME_RADIUS = 40
local LEGENDARY_NUDGE_OFFSET = 0.12
local LEGENDARY_NUDGE_INFO = TweenInfo.new(0.07, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)

local player = Players.LocalPlayer

type VisualCart = {
	assembly: CartAssembly.Assembly,
	spinAngle: number,
	distanceTraveled: number,
	lastForward: Vector3?,
}

local trailPoints: { CFrame } = {}
local visualCarts: { VisualCart } = {}
local returnDebounce = false
local rollingWheelsSound: Sound
local currentWorld = 1
local corralsByWorld: { [number]: BasePart } = {}

local function updateTrail(rootCFrame: CFrame)
	local last = trailPoints[#trailPoints]
	if not last or (last.Position - rootCFrame.Position).Magnitude >= TRAIL_SAMPLE_DISTANCE then
		table.insert(trailPoints, rootCFrame)
		while #trailPoints > MAX_TRAIL_POINTS do
			table.remove(trailPoints, 1)
		end
	end
end

local function getTrailCFrameAtDistance(distance: number): CFrame?
	if #trailPoints == 0 then
		return nil
	end

	local traveled = 0
	for i = #trailPoints, 2, -1 do
		local a = trailPoints[i]
		local b = trailPoints[i - 1]
		local segment = (a.Position - b.Position).Magnitude
		if traveled + segment >= distance then
			local alpha = segment > 0 and (distance - traveled) / segment or 0
			return a:Lerp(b, alpha)
		end
		traveled += segment
	end

	return trailPoints[1]
end

-- §8 "Train movement": a subtle rolling-wheels loop while train length > 0,
-- pitched/volumed up slightly with train length (capped, never obnoxious).
local function updateRollingWheels(count: number)
	if not rollingWheelsSound then
		return
	end
	if count <= 0 then
		if rollingWheelsSound.Playing then
			rollingWheelsSound:Stop()
		end
		return
	end

	rollingWheelsSound.Volume = math.min(ROLL_MAX_VOLUME, count * ROLL_VOLUME_PER_CART)
	if not rollingWheelsSound.Playing then
		rollingWheelsSound:Play()
	end
end

-- §8 "Cart collection": scales up then snaps into train position over
-- ~0.15s -- the position snap itself is already handled by onHeartbeat's
-- smoothed follow toward the trail; this just adds the pop-in scale on the
-- assembly freshly built this frame.
local function playCollectPop(cart: Model)
	local ok = pcall(function()
		cart.Scale = COLLECT_POP_SCALE_START
	end)
	if ok then
		TweenService:Create(cart, COLLECT_POP_INFO, { Scale = 1 }):Play()
	end
end

local function createVisualCart(): VisualCart
	local assembly = CartAssembly.BuildCart(CART_BODY_TEMPLATE, CART_WHEEL_TEMPLATE, CART_WHEEL_OFFSETS, WHEEL_CENTER_Y)
	assembly.model.Parent = Workspace
	playCollectPop(assembly.model)
	return { assembly = assembly, spinAngle = 0, distanceTraveled = 0, lastForward = nil }
end

local function setTrainCount(count: number)
	while #visualCarts < count do
		table.insert(visualCarts, createVisualCart())
	end
	while #visualCarts > count do
		local cart = table.remove(visualCarts)
		if cart then
			CartAssembly.Destroy(cart.assembly)
		end
	end
	updateRollingWheels(count)
end

-- Framerate-independent smoothing + procedural bob/lean/wheel-spin, all
-- driven by the same "how far did the body actually move this frame" value
-- so a stationary train never bobs or spins in place. Runs once per cart
-- per frame -- no per-wheel work outside CartAssembly.UpdateAssembly's own
-- single CFrame write per wheel (§11.5's VFX/perf budget).
local function onHeartbeat(dt: number)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return
	end

	updateTrail(root.CFrame)

	local followAlpha = 1 - math.exp(-FOLLOW_SMOOTHING_RATE * dt)

	for i, visualCart in visualCarts do
		local target = getTrailCFrameAtDistance(i * SPACING)
		if not target then
			continue
		end

		local orientedTarget = target * BODY_FORWARD_ROTATION
		local currentCFrame = visualCart.assembly.body.CFrame
		local smoothedCFrame = currentCFrame:Lerp(orientedTarget, followAlpha)

		local moved = (smoothedCFrame.Position - currentCFrame.Position).Magnitude
		visualCart.distanceTraveled += moved
		visualCart.spinAngle -= moved / WHEEL_RADIUS

		local lean = 0
		local newForward = smoothedCFrame.LookVector
		if visualCart.lastForward and dt > 0 then
			local rawTurnRate = visualCart.lastForward:Cross(newForward).Y / dt
			local clampedTurnRate = math.clamp(rawTurnRate, -MAX_TURN_RATE, MAX_TURN_RATE)
			lean = math.clamp(clampedTurnRate * LEAN_RESPONSE, -LEAN_MAX, LEAN_MAX)
		end
		visualCart.lastForward = newForward

		local bob = math.sin(visualCart.distanceTraveled * BOB_FREQUENCY) * BOB_AMPLITUDE
		local finalCFrame = smoothedCFrame * CFrame.new(0, bob, 0) * CFrame.Angles(lean, 0, 0)

		CartAssembly.UpdateAssembly(visualCart.assembly, finalCFrame, visualCart.spinAngle)
	end
end

-- §4.1.6/§8: rarity-tier visual feedback fires once, at collection, not
-- continuously. Color tint on the pickup itself is server-side (visible in
-- the Zone before collection); this one-shot wisp is the collection-moment
-- particle burst for Rare+.
local function playRarityWisp(rarity: string)
	local display = CartData.RarityDisplay[rarity]
	if not display or not display.HasParticleWisp then
		return
	end

	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return
	end

	local attachment = Instance.new("Attachment")
	attachment.Parent = root

	local emitter = Instance.new("ParticleEmitter")
	emitter.Color = ColorSequence.new(Color3.new(display.Color[1], display.Color[2], display.Color[3]))
	emitter.Lifetime = NumberRange.new(0.4, 0.6)
	emitter.Speed = NumberRange.new(4, 6)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Size = NumberSequence.new(0.5)
	emitter.Rate = 0
	emitter.Parent = attachment

	emitter:Emit(16)
	Debris:AddItem(attachment, 1)
end

-- §8: a "thunk" SFX pitched slightly higher per rarity tier, on every
-- collection (all 5 tiers, unlike the wisp which is Rare+ only).
local function playCollectSFX(rarity: string)
	local display = CartData.RarityDisplay[rarity]
	if not display then
		return
	end
	local sound = Instance.new("Sound")
	sound.Name = "PH_SFX_Collect"
	sound.PlaybackSpeed = display.CollectPitch
	sound.Volume = 0.5
	sound.Parent = player:WaitForChild("PlayerGui")
	sound:Play()
	Debris:AddItem(sound, 2)
end

-- §8 "Screen feedback": a very subtle (<0.15s) camera nudge, reserved for
-- Legendary pickups only -- achieved via Humanoid.CameraOffset rather than
-- fighting the built-in camera controller's own CFrame ownership.
local function playLegendaryScreenNudge()
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end

	local signX = math.random(0, 1) == 0 and -1 or 1
	local signY = math.random(0, 1) == 0 and -1 or 1
	local direction = Vector3.new(signX, signY, 0).Unit * LEGENDARY_NUDGE_OFFSET
	humanoid.CameraOffset = direction
	task.delay(LEGENDARY_NUDGE_INFO.Time, function()
		if humanoid.Parent then
			TweenService:Create(humanoid, LEGENDARY_NUDGE_INFO, { CameraOffset = Vector3.zero }):Play()
		end
	end)
end

-- §8 "Legendary spawn feedback": audible within ~40 studs when a Legendary
-- cart spawns (not collected) -- encourages nearby players to notice.
local function playLegendarySpawnChime(position: Vector3)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root or (root.Position - position).Magnitude > LEGENDARY_CHIME_RADIUS then
		return
	end

	local sound = Instance.new("Sound")
	sound.Name = "PH_SFX_LegendarySpawn"
	sound.Volume = 0.6
	sound.Parent = player:WaitForChild("PlayerGui")
	sound:Play()
	Debris:AddItem(sound, 3)
end

-- §8 "Rarity feedback": Legendary additionally gets a 1-second particle
-- beam visible to nearby players -- a social "somebody found something!"
-- beat, broadcast server-side to everyone in the same World (§5.2).
local function playLegendaryCollectionBeam(position: Vector3)
	local anchor = Instance.new("Part")
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(0.2, 0.2, 0.2)
	anchor.CFrame = CFrame.new(position)
	anchor.Parent = Workspace

	local attachment = Instance.new("Attachment")
	attachment.Parent = anchor

	local emitter = Instance.new("ParticleEmitter")
	local legendary = CartData.RarityDisplay.Legendary
	emitter.Color = ColorSequence.new(Color3.new(legendary.Color[1], legendary.Color[2], legendary.Color[3]))
	emitter.Lifetime = NumberRange.new(0.8, 1.0)
	emitter.Speed = NumberRange.new(2, 4)
	emitter.SpreadAngle = Vector2.new(15, 15)
	emitter.Size = NumberSequence.new(0.6)
	emitter.Rate = 0
	emitter.Parent = attachment

	emitter:Emit(40)
	Debris:AddItem(anchor, 1.5)
end

-- §8 "Corral feedback": corral glows on a successful return -- a brief
-- brightness/color pulse via a temporary PointLight, restored afterward.
local function playCorralGlow(corral: BasePart, isPersonalBest: boolean)
	local light = Instance.new("PointLight")
	light.Color = isPersonalBest and Color3.fromRGB(255, 220, 80) or Color3.fromRGB(255, 255, 255)
	light.Range = 16
	light.Brightness = 0
	light.Parent = corral

	local tween = TweenService:Create(light, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Brightness = 4,
	})
	tween:Play()
	tween.Completed:Connect(function()
		local fadeOut = TweenService:Create(light, TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
			Brightness = 0,
		})
		fadeOut:Play()
		fadeOut.Completed:Connect(function()
			light:Destroy()
		end)
	end)

	local sound = Instance.new("Sound")
	sound.Name = "PH_SFX_Return"
	sound.Parent = corral
	sound:Play()
	Debris:AddItem(sound, 3)

	if isPersonalBest then
		local attachment = Instance.new("Attachment")
		attachment.Position = Vector3.new(0, 3, 0)
		attachment.Parent = corral

		local confetti = Instance.new("ParticleEmitter")
		confetti.Color = ColorSequence.new(Color3.fromRGB(255, 220, 80))
		confetti.Lifetime = NumberRange.new(0.6, 1.0)
		confetti.Speed = NumberRange.new(6, 12)
		confetti.SpreadAngle = Vector2.new(180, 180)
		confetti.Size = NumberSequence.new(0.4)
		confetti.Rate = 0
		confetti.Parent = attachment

		confetti:Emit(30)
		Debris:AddItem(attachment, 2)
	end
end

-- Phase 3: the server call itself now blocks for the real resistance-gated
-- dwell duration (§4.2), so debounce just needs to cover the in-flight
-- InvokeServer call -- no fixed extra wait needed.
local function tryReturnCarts(remotesFolder: Folder, uiAnimationController: any)
	if returnDebounce then
		return
	end
	returnDebounce = true

	local requestReturnCarts = remotesFolder:FindFirstChild("RequestReturnCarts") :: RemoteFunction
	local result = requestReturnCarts:InvokeServer()
		:: { success: boolean, cashEarned: number?, isPersonalBest: boolean? }

	if result and result.success and result.cashEarned then
		local prefix = result.isPersonalBest and "NEW BEST! " or ""
		uiAnimationController.ShowNotification(
			"ReturnComplete",
			prefix .. "+$" .. FormatNumber.Format(result.cashEarned) .. " returned!"
		)

		local corral = corralsByWorld[currentWorld]
		if corral then
			playCorralGlow(corral, result.isPersonalBest == true)
		end
	end

	returnDebounce = false
end

function TrainController.Init()
	local remotesFolder = ReplicatedStorage:WaitForChild("Remotes") :: Folder
	local uiAnimationController = require(script.Parent.UIAnimationController)

	rollingWheelsSound = Instance.new("Sound")
	rollingWheelsSound.Name = "PH_SFX_TrainRoll"
	rollingWheelsSound.Looped = true
	rollingWheelsSound.Volume = 0
	rollingWheelsSound.Parent = player:WaitForChild("PlayerGui")

	-- PlayerDataUpdated pushes a diff (§5.2), not a full replace -- different
	-- Services push different subsets of fields, so every field is optional.
	local playerDataUpdated = remotesFolder:FindFirstChild("PlayerDataUpdated") :: RemoteEvent
	playerDataUpdated.OnClientEvent:Connect(function(data: { trainCount: number?, currentWorld: number? })
		if data.trainCount ~= nil then
			setTrainCount(data.trainCount)
		end
		if data.currentWorld ~= nil then
			currentWorld = data.currentWorld
		end
	end)

	local cartClaimed = remotesFolder:FindFirstChild("CartClaimed") :: RemoteEvent
	cartClaimed.OnClientEvent:Connect(function(data: { rarity: string })
		playRarityWisp(data.rarity)
		playCollectSFX(data.rarity)
		if data.rarity == "Legendary" then
			playLegendaryScreenNudge()
		end
	end)

	local legendarySpawned = remotesFolder:FindFirstChild("LegendaryCartSpawned") :: RemoteEvent
	legendarySpawned.OnClientEvent:Connect(function(data: { position: Vector3 })
		playLegendarySpawnChime(data.position)
	end)

	local legendaryClaimed = remotesFolder:FindFirstChild("LegendaryCartClaimed") :: RemoteEvent
	legendaryClaimed.OnClientEvent:Connect(function(data: { position: Vector3 })
		playLegendaryCollectionBeam(data.position)
	end)

	RunService.Heartbeat:Connect(onHeartbeat)

	-- Phase 5: a player can be in any of the 5 Worlds (Portal travel), so
	-- every World's Corral needs its own Touched connection -- the server
	-- only actually honors a return while it's the player's CURRENT World's
	-- Corral (WorldService), so touching another World's Corral (never
	-- possible in practice, since physical position always matches
	-- currentWorld) would just harmlessly fail server-side.
	local worldsFolder = Workspace:WaitForChild("Worlds")
	for _, worldEntry in WorldData.Worlds do
		local worldFolder = worldsFolder:WaitForChild(worldEntry.FolderName)
		local corral = worldFolder:WaitForChild("Corral") :: BasePart
		corralsByWorld[worldEntry.Id] = corral
		corral.Touched:Connect(function(hit: BasePart)
			local character = player.Character
			if character and hit:IsDescendantOf(character) then
				tryReturnCarts(remotesFolder, uiAnimationController)
			end
		end)
	end

	print("[TrainController] Init")
end

return TrainController
