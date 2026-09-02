--!strict
-- Standard-scale, physics-disabled cart visuals (§11.1: "trains are visual,
-- not physical"). Every cart model going forward ships as one complete,
-- self-contained model -- cart and wheels baked in by whoever authors it --
-- so this module's only job is making any such model render at the same
-- standard size and never physically interact with anything. Swapping to a
-- new cart variant is then a one-line template change in TrainController,
-- never a new animation/assembly pass.

local CartVisuals = {}

-- The one number every future cart model gets normalized to, so swapping
-- models never changes gameplay feel or requires retuning TrainController's
-- hover/spacing constants. Picked to read as roughly character-height --
-- visible and satisfying without dominating the screen.
CartVisuals.STANDARD_HEIGHT = 5.0

-- Clones template, uniformly rescales it so its height matches
-- STANDARD_HEIGHT (preserving its own proportions, whatever its native
-- size), and disables physics on every part -- the whole model is
-- repositioned by a single CFrame write every frame (TrainController), so
-- nothing in it should ever be simulated or collide.
--
-- Deliberately does not use Model:GetExtentsSize()/ScaleTo() -- both a cart
-- and its wheel, per this project's actual imported assets, carry a custom
-- WorldPivot baked in by their export tool that made GetExtentsSize()
-- return a nonsensical value (and ScaleTo() blow the model up ~19x rather
-- than shrink it, confirmed by inspecting a live instance, not guessed).
-- Reading the PrimaryPart's own .Size and resizing it directly sidesteps
-- that pivot entirely and is correct for the current single-MeshPart cart
-- shape this project uses; a future multi-part cart body would need this
-- extended to also scale each part's offset from the PrimaryPart, not just
-- each part's own Size.
function CartVisuals.PrepareCart(template: Model): Model
	local model = template:Clone()
	local body = model.PrimaryPart :: BasePart
	assert(body, "CartVisuals.PrepareCart: template has no PrimaryPart set")

	local currentHeight = body.Size.Y
	if currentHeight > 0 then
		local scaleFactor = CartVisuals.STANDARD_HEIGHT / currentHeight
		body.Size = body.Size * scaleFactor
	end

	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = false
			descendant.Massless = true
		end
	end

	return model
end

return CartVisuals
