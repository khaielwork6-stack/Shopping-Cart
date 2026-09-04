--!strict
-- Phase 5 (GDD v3 §10-11): the bat. Every player spawns holding one, no
-- equip menu -- a placeholder Tool built procedurally here (no Studio art
-- pass yet, matches this project's PH_-prefixed placeholder convention).
-- M1/tap swings it (Tool.Activated, which Roblox already replicates
-- client-click -> server-fire on its own -- no custom RemoteEvent needed
-- for the swing itself). A landed hit ragdolls the target (a real physics
-- ragdoll -- Motor6D -> BallSocketConstraint swap -- per this project's own
-- explicit choice over a canned knockdown animation), knocks them back, and
-- drops their last cart if they're hauling one (EconomyService.
-- DropLastCartFromHit).
--
-- Bat *tiers* (§11, one per completed Index zone-set) are deferred -- the
-- Index has no zone-set data yet (Phase 7). "Carrying a stolen item" as a
-- drop case (§10.2) is deferred too -- no steal mechanic exists until
-- Phase 6. This phase is intentionally underwhelming in isolation per the
-- GDD's own §20 note: the bat only matters once it's defending something.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local EconomyConfig = require(ReplicatedStorage.Shared.Configs.EconomyConfig)
local RemotesSetup = require(ReplicatedStorage.Shared.Modules.RemotesSetup)
local PlayerDataService = require(script.Parent.PlayerDataService)
local EconomyService = require(script.Parent.EconomyService)

local BatService = {}

local BAT_CFG = EconomyConfig.Bat

type RagdollState = {
	joints: { { motor: Motor6D, constraint: BallSocketConstraint, a0: Attachment, a1: Attachment } },
	animationConstraints: { AnimationConstraint },
	restoreAt: number,
	humanoid: Humanoid,
}

local remotesFolder: Folder
local lastSwingAt: { [Player]: number } = {}
local targetHitState: { [Player]: { streak: number, lastHitAt: number } } = {}
local immuneUntil: { [Player]: number } = {}
local sessionJoinedAt: { [Player]: number } = {}
local activeRagdolls: { [Player]: RagdollState } = {}

local function isProtected(player: Player): boolean
	local data = PlayerDataService.Get(player)
	if data.currentLevel >= BAT_CFG.NewPlayerProtectionLevel then
		return false
	end
	local joinedAt = sessionJoinedAt[player]
	if not joinedAt then
		return false
	end
	return os.clock() - joinedAt < BAT_CFG.NewPlayerProtectionSeconds
end

local function createBatTool(): Tool
	local tool = Instance.new("Tool")
	tool.Name = "Bat"
	tool.RequiresHandle = true
	tool.CanBeDropped = false

	local handle = Instance.new("Part")
	handle.Name = "Handle"
	handle.Size = Vector3.new(0.6, 3, 0.6)
	handle.Material = Enum.Material.Wood
	handle.Color = Color3.fromRGB(150, 84, 63) -- matches this session's brick/wood palette
	handle.CanCollide = false
	handle.Parent = tool

	local barrel = Instance.new("Part")
	barrel.Name = "Barrel"
	barrel.Shape = Enum.PartType.Cylinder
	barrel.Size = Vector3.new(1.4, 0.9, 0.9)
	barrel.Material = Enum.Material.Wood
	barrel.Color = Color3.fromRGB(196, 154, 108)
	barrel.CanCollide = false
	barrel.CFrame = handle.CFrame * CFrame.new(0, 1.8, 0) * CFrame.Angles(0, 0, math.rad(90))
	barrel.Parent = tool
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = handle
	weld.Part1 = barrel
	weld.Parent = handle

	return tool
end

local function equipBat(player: Player, character: Model)
	local backpack = player:FindFirstChild("Backpack")
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not backpack or not humanoid then
		return
	end

	local tool = createBatTool()
	tool.Parent = backpack
	humanoid:EquipTool(tool)

	tool.Activated:Connect(function()
		BatService.HandleSwing(player)
	end)
end

-- QA (playtest, confirmed live): this project's actual character rig does
-- NOT use classic Motor6D joints at all -- it's Roblox's newer
-- constraint-based R15 rig, where each limb is already held in its animated
-- pose by a real `AnimationConstraint` sitting alongside an already-present
-- `BallSocketConstraint` (verified directly: 0 Motor6Ds found, 15
-- AnimationConstraints found, disabling them and letting the existing
-- BallSocketConstraints take over produced real, physics-driven limb
-- movement). Motor6D swapping (the originally-planned approach, and still
-- the right one for a classic rig) is kept as a fallback for a character
-- that genuinely has no AnimationConstraints, so this works either way
-- without needing to know the rig style ahead of time.
local function startRagdoll(player: Player, character: Model, duration: number)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end

	local existing = activeRagdolls[player]
	if existing then
		-- Already ragdolled from an earlier hit -- just extend the timer,
		-- don't double up a second set of joints/constraints.
		existing.restoreAt = math.max(existing.restoreAt, os.clock() + duration)
		return
	end

	humanoid.PlatformStand = true

	local animationConstraints: { AnimationConstraint } = {}
	for _, descendant in character:GetDescendants() do
		if descendant:IsA("AnimationConstraint") then
			table.insert(animationConstraints, descendant)
		end
	end

	local joints = {}
	if #animationConstraints > 0 then
		for _, constraint in animationConstraints do
			constraint.Enabled = false
		end
	else
		-- Classic Motor6D rig fallback: bridge every joint with a
		-- BallSocketConstraint at the same C0/C1 offsets, then disable the
		-- Motor6D so physics drives the limb instead of animation.
		for _, descendant in character:GetDescendants() do
			if descendant:IsA("Motor6D") and descendant.Part0 and descendant.Part1 then
				local motor = descendant
				local a0 = Instance.new("Attachment")
				a0.CFrame = motor.C0
				a0.Parent = motor.Part0

				local a1 = Instance.new("Attachment")
				a1.CFrame = motor.C1
				a1.Parent = motor.Part1

				local constraint = Instance.new("BallSocketConstraint")
				constraint.Attachment0 = a0
				constraint.Attachment1 = a1
				constraint.Parent = motor.Part0

				motor.Enabled = false
				table.insert(joints, { motor = motor, constraint = constraint, a0 = a0, a1 = a1 })
			end
		end
	end

	activeRagdolls[player] =
		{ joints = joints, animationConstraints = animationConstraints, restoreAt = os.clock() + duration, humanoid = humanoid }

	task.delay(duration, function()
		local state = activeRagdolls[player]
		if not state or state.humanoid ~= humanoid then
			return -- already restored (e.g. a respawn) or superseded
		end
		if os.clock() < state.restoreAt then
			return -- extended by a later hit -- a fresh delay is already queued for that
		end

		activeRagdolls[player] = nil
		for _, constraint in state.animationConstraints do
			if constraint.Parent then
				constraint.Enabled = true
			end
		end
		for _, joint in state.joints do
			joint.constraint:Destroy()
			joint.a0:Destroy()
			joint.a1:Destroy()
			if joint.motor.Parent then
				joint.motor.Enabled = true
			end
		end
		if humanoid.Parent then
			humanoid.PlatformStand = false
		end

		immuneUntil[player] = os.clock() + BAT_CFG.PostStandImmunitySeconds
	end)
end

local function restoreRagdollImmediately(player: Player)
	local state = activeRagdolls[player]
	if not state then
		return
	end
	activeRagdolls[player] = nil
	for _, joint in state.joints do
		joint.constraint:Destroy()
		joint.a0:Destroy()
		joint.a1:Destroy()
	end
	-- No AnimationConstraint/PlatformStand/immunity bookkeeping here -- this
	-- path only runs on a respawn, where the old character is gone anyway.
end

-- §19: "a proximity cone in front of the player, not a raycast at a
-- cursor" -- lands with one tap, no camera control, works identically on
-- mobile once that input path exists.
local function findTargetsInCone(attacker: Player, attackerRoot: BasePart): { Player }
	local targets = {}
	local lookVector = attackerRoot.CFrame.LookVector
	local halfAngleCos = math.cos(math.rad(BAT_CFG.SwingConeHalfAngleDegrees))

	for _, other in Players:GetPlayers() do
		if other == attacker then
			continue
		end
		local character = other.Character
		local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if not root then
			continue
		end

		local offset = root.Position - attackerRoot.Position
		local distance = offset.Magnitude
		if distance > 0 and distance <= BAT_CFG.SwingConeRadius then
			local direction = offset.Unit
			if lookVector:Dot(direction) >= halfAngleCos then
				table.insert(targets, other)
			end
		end
	end

	return targets
end

function BatService.HandleSwing(attacker: Player)
	if isProtected(attacker) then
		return -- §10.4: protection is symmetric -- a protected player can't swing either
	end

	local now = os.clock()
	if now - (lastSwingAt[attacker] or 0) < BAT_CFG.SwingCooldownSeconds then
		return
	end
	lastSwingAt[attacker] = now

	local character = attacker.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return
	end

	for _, target in findTargetsInCone(attacker, root) do
		if isProtected(target) then
			continue
		end
		if (immuneUntil[target] or 0) > now then
			continue -- §10.1: 15s immunity after standing up
		end

		local targetCharacter = target.Character
		local targetRoot = targetCharacter and targetCharacter:FindFirstChild("HumanoidRootPart") :: BasePart?
		if not targetCharacter or not targetRoot then
			continue
		end

		-- §10.1: diminishing returns tracked per VICTIM, not per
		-- attacker-target pair -- otherwise two different attackers could
		-- still floor-lock one player indefinitely between them.
		local hitState = targetHitState[target]
		local streak = 1
		if hitState and now - hitState.lastHitAt <= BAT_CFG.DiminishingReturnWindowSeconds then
			streak = math.min(hitState.streak + 1, #BAT_CFG.DiminishingReturnDurations)
		end
		targetHitState[target] = { streak = streak, lastHitAt = now }
		local duration = BAT_CFG.DiminishingReturnDurations[streak]

		-- §10.2: knockback away from the attacker, applied once at impact.
		local knockDirection = (targetRoot.Position - root.Position)
		knockDirection = (knockDirection.Magnitude > 0 and knockDirection.Unit or root.CFrame.LookVector)
		targetRoot.AssemblyLinearVelocity = knockDirection * BAT_CFG.KnockbackSpeed + Vector3.new(0, BAT_CFG.KnockbackSpeed * 0.3, 0)

		startRagdoll(target, targetCharacter, duration)

		-- §10.2: hauling a train -> drops the last cart. Empty-handed ->
		-- knockdown only, nothing else happens.
		EconomyService.DropLastCartFromHit(target)

		local playerKnockedDown = remotesFolder:FindFirstChild("PlayerKnockedDown") :: RemoteEvent
		playerKnockedDown:FireClient(target, { attackerName = attacker.Name })
	end
end

function BatService.Init()
	remotesFolder = RemotesSetup.CreateAll()

	Players.PlayerAdded:Connect(function(player: Player)
		sessionJoinedAt[player] = os.clock()

		if player.Character then
			equipBat(player, player.Character)
		end
		player.CharacterAdded:Connect(function(character: Model)
			restoreRagdollImmediately(player)
			equipBat(player, character)
		end)
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		restoreRagdollImmediately(player)
		lastSwingAt[player] = nil
		targetHitState[player] = nil
		immuneUntil[player] = nil
		sessionJoinedAt[player] = nil
	end)

	print("[BatService] Init")
end

return BatService
