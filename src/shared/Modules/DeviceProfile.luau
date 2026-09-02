--!strict
-- Mobile/device detection + VFX density scaling (§11.7: "anything that
-- works beautifully on PC but sucks on mobile is unfinished"). Client-only
-- in practice (UserInputService only means anything on a client), but lives
-- in Shared.Modules alongside this project's other pure-logic modules
-- rather than a new client-only folder, since nothing here touches an
-- Instance beyond reading UserInputService's own state.

local UserInputService = game:GetService("UserInputService")

local DeviceProfile = {}

-- TouchEnabled-without-KeyboardEnabled is the standard Roblox heuristic for
-- "this is a touch-only device" (phone/tablet) rather than a touchscreen
-- laptop, which also reports KeyboardEnabled.
function DeviceProfile.IsMobile(): boolean
	return UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
end

-- Scales a PC-tuned one-shot particle burst count down for mobile, per
-- §11.7's "lower preset automatically on mobile device detection."
function DeviceProfile.ScaleParticleCount(baseCount: number): number
	if DeviceProfile.IsMobile() then
		return math.max(1, math.floor(baseCount / 2))
	end
	return baseCount
end

-- Same idea for a continuous emitter's Rate (particles/second).
function DeviceProfile.ScaleRate(baseRate: number): number
	if DeviceProfile.IsMobile() then
		return baseRate / 2
	end
	return baseRate
end

return DeviceProfile
