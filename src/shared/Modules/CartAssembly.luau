--!strict
-- Reusable cart-body + wheel assembler. A cart body model (single or
-- multi-part, PrimaryPart set) and a wheel model (PrimaryPart set, exported
-- so its identity rotation already faces the correct mounting direction --
-- see the wheel offset table's comment at its call site if a future wheel
-- asset needs a rotation correction) get combined into one Model with 4
-- positioned wheel copies, cosmetic-only (no physics constraints, matching
-- §11.1's "trains are visual, not physical" rule -- a WeldConstraint per
-- wheel would add real physics/network cost for no visual benefit, since
-- wheel position is driven by CFrame math every frame anyway).
--
-- Kept generic on purpose ("the setup is reusable so future cart variants
-- can use the exact same wheel system"): BuildCart takes the body/wheel
-- templates and the corner offsets as parameters, not hardcoded constants --
-- a new cart body only needs its own offset table (measured from its own
-- bounding box, same way TrainController's CART_WHEEL_OFFSETS was), not a
-- new copy of this module.

local CartAssembly = {}

export type WheelOffset = { x: number, z: number }

export type WheelMount = {
	part: BasePart,
	offset: CFrame, -- rest CFrame relative to the body's PrimaryPart
}

export type Assembly = {
	model: Model,
	body: BasePart,
	wheels: { WheelMount },
}

-- Builds one assembled cart: clones the body, clones+positions one wheel per
-- offset entry into a "Wheels" folder under the returned Model. wheelCenterY
-- is the wheel hub's local Y offset from the body's PrimaryPart (negative --
-- below the body's own pivot, per the body's own bounding box). wheelRotation
-- is an optional extra rotation applied to every wheel before the corner
-- offset, for wheel assets whose identity orientation doesn't already face
-- the right way (this specific body/wheel pair needs none -- see
-- TrainController's comment on how that was verified).
function CartAssembly.BuildCart(
	bodyTemplate: Model,
	wheelTemplate: Model,
	wheelOffsets: { WheelOffset },
	wheelCenterY: number,
	wheelRotation: CFrame?
): Assembly
	local model = bodyTemplate:Clone()
	local body = model.PrimaryPart :: BasePart
	assert(body, "CartAssembly.BuildCart: body template has no PrimaryPart set")

	-- §11.1: trains are visual, not physical -- a visual cart must never
	-- collide with the player, other players, or other carts in the same
	-- train (that's what was causing the jitter/bumping). Every part in the
	-- assembly is driven entirely by CFrame writes each frame, so physics
	-- simulation is disabled outright, not just collision.
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = false
			descendant.Massless = true
		end
	end

	local wheelSourcePart = wheelTemplate.PrimaryPart :: BasePart
	assert(wheelSourcePart, "CartAssembly.BuildCart: wheel template has no PrimaryPart set")

	local wheelsFolder = Instance.new("Folder")
	wheelsFolder.Name = "Wheels"
	wheelsFolder.Parent = model

	local wheels: { WheelMount } = {}
	for i, o in wheelOffsets do
		local wheelPart = wheelSourcePart:Clone()
		wheelPart.Name = "Wheel" .. i
		wheelPart.Anchored = true
		wheelPart.CanCollide = false
		wheelPart.CanQuery = false
		wheelPart.CanTouch = false
		wheelPart.Massless = true

		local offset = CFrame.new(o.x, wheelCenterY, o.z) * (wheelRotation or CFrame.new())
		wheelPart.CFrame = body.CFrame * offset
		wheelPart.Parent = wheelsFolder

		table.insert(wheels, { part = wheelPart, offset = offset })
	end

	return { model = model, body = body, wheels = wheels }
end

-- Repositions the whole assembly at bodyCFrame and spins every wheel in
-- place around its own mounted axle (local Z, per this wheel model's
-- exported orientation) by spinAngle radians -- one call per cart per frame
-- rather than one per wheel, so a long train stays cheap (§11.5).
function CartAssembly.UpdateAssembly(assembly: Assembly, bodyCFrame: CFrame, spinAngle: number)
	assembly.body.CFrame = bodyCFrame
	local spin = CFrame.Angles(0, 0, spinAngle)
	for _, wheel in assembly.wheels do
		wheel.part.CFrame = bodyCFrame * wheel.offset * spin
	end
end

function CartAssembly.Destroy(assembly: Assembly)
	assembly.model:Destroy()
end

return CartAssembly
