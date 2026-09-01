--!strict
-- Client-side visual train rendering (�4.1.3/�4.1.6/�11.1). Purely visual --
-- no physics, no per-cart networked Instance; each carried cart's position
-- is a lerped point along a CFrame-history trail behind the player,
-- reconstructed from the single trainCount value PlayerDataUpdated pushes.
--
-- Also owns the Corral-touch -> RequestReturnCarts trigger for Phase 1,
-- since no dedicated Corral controller exists yet in the Guide's Controller
-- list and this is the closest owning system (full UI/VFX corral feedback
-- lands in Phase 9/10).

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CartData = require(ReplicatedStorage.Shared.Configs.CartData)

local TrainController = {}

local SPACING = 3 -- studs between train carts (�4.1.3)
local TRAIL_SAMPLE_DISTANCE = 0.5
local LERP_ALPHA = 0.35
local MAX_TRAIL_POINTS = 400

local player = Players.LocalPlayer

local trailPoints: { CFrame } = {}
local visualCarts: { Model } = {}
local cartTemplate: Model
local returnDebounce = false

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

local function setTrainCount(count: number)
	while #visualCarts < count do
		local clone = cartTemplate:Clone()
		clone.Parent = Workspace
		table.insert(visualCarts, clone)
	end
	while #visualCarts > count do
		local cart = table.remove(visualCarts)
		if cart then
			cart:Destroy()
		end
	end
end

local function onHeartbeat()
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return
	end

	updateTrail(root.CFrame)

	for i, cartModel in visualCarts do
		local target = getTrailCFrameAtDistance(i * SPACING)
		if target then
			cartModel:PivotTo(cartModel:GetPivot():Lerp(target, LERP_ALPHA))
		end
	end
end

-- �4.1.6/�8: rarity-tier visual feedback fires once, at collection, not
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

local function tryReturnCarts(remotesFolder: Folder)
	if returnDebounce then
		return
	end
	returnDebounce = true

	local requestReturnCarts = remotesFolder:FindFirstChild("RequestReturnCarts") :: RemoteFunction
	requestReturnCarts:InvokeServer()

	task.wait(0.5)
	returnDebounce = false
end

function TrainController.Init()
	local remotesFolder = ReplicatedStorage:WaitForChild("Remotes") :: Folder
	cartTemplate = ReplicatedStorage.Assets.Placeholders.PH_Cart_Common

	-- PlayerDataUpdated pushes a diff (�5.2), not a full replace -- different
	-- Services push different subsets of fields, so every field is optional.
	local playerDataUpdated = remotesFolder:FindFirstChild("PlayerDataUpdated") :: RemoteEvent
	playerDataUpdated.OnClientEvent:Connect(function(data: { trainCount: number? })
		if data.trainCount ~= nil then
			setTrainCount(data.trainCount)
		end
	end)

	local cartClaimed = remotesFolder:FindFirstChild("CartClaimed") :: RemoteEvent
	cartClaimed.OnClientEvent:Connect(function(data: { rarity: string })
		playRarityWisp(data.rarity)
	end)

	RunService.Heartbeat:Connect(onHeartbeat)

	local world1 = Workspace:WaitForChild("Worlds"):WaitForChild("World1_ParkingLot")
	local corral = world1:WaitForChild("Corral") :: BasePart
	corral.Touched:Connect(function(hit: BasePart)
		local character = player.Character
		if character and hit:IsDescendantOf(character) then
			tryReturnCarts(remotesFolder)
		end
	end)

	print("[TrainController] Init")
end

return TrainController
