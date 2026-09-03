--!strict
-- Rarity-tier display metadata (§4.1.6 / §8, extended for the Lost Cart GDD).
-- Value multipliers and spawn weights are economy constants and live in
-- EconomyConfig, not here -- this table only owns presentation: color, VFX
-- tier, and (new) the full cover-idle/reveal presentation profile the GDD's
-- "presentation intensity should progress with rarity" requirement calls
-- for. One row per rarity; LostCartService and the reveal Controller both
-- read this instead of hardcoding six copies of the same VFX logic.

local EconomyConfig = require(script.Parent.EconomyConfig)

export type RarityDisplay = {
	DisplayName: string,
	Color: { number }, -- RGB 0-1
	HasParticleWisp: boolean, -- §4.1.6: one-shot particle wisp for Rare+ (train collect)
	CoverModelName: string, -- ServerStorage.LostCart.Covers.<name>, exact literal Workspace name
	CollectPitch: number, -- §8: collection "thunk" SFX pitched higher per rarity tier

	-- Cover idle-ambience profile (GDD §"Cover Presentation"): 0/false means
	-- "omit this layer entirely," not "very small" -- Common should read as
	-- genuinely plain, not just a dimmer Secret.
	IdleGlowBrightness: number,
	IdleGlowRange: number,
	IdleParticleRate: number, -- ParticleEmitter.Rate, 0 = no particles
	IdleBobAmplitude: number, -- studs
	IdleBobSpeed: number, -- radians/sec
	IdleSpinSpeed: number, -- radians/sec around Y, 0 = no spin
	HasBeam: boolean, -- Legendary+: a vertical light beam visible across the map

	-- Reveal choreography (GDD §6: "Common = almost instant" up through
	-- "Secret = HUGE jackpot moment," but "NEVER lock the player into
	-- several seconds"). Total sequence length in seconds, and how many
	-- burst particles the pop gets.
	RevealDuration: number,
	BurstParticleCount: number,
}

local CartData = {}

CartData.RarityDisplay = ({
	Common = {
		DisplayName = "Common",
		Color = { 0.7, 0.7, 0.7 },
		HasParticleWisp = false,
		CoverModelName = "Common Cart ",
		CollectPitch = 1.0,
		IdleGlowBrightness = 0,
		IdleGlowRange = 0,
		IdleParticleRate = 0,
		IdleBobAmplitude = 0.15,
		IdleBobSpeed = 1.2,
		IdleSpinSpeed = 0,
		HasBeam = false,
		RevealDuration = 0.28,
		BurstParticleCount = 6,
	},
	Uncommon = {
		DisplayName = "Uncommon",
		Color = { 0.2, 0.8, 0.3 },
		HasParticleWisp = false,
		CoverModelName = "Uncommon Crate",
		CollectPitch = 1.08,
		IdleGlowBrightness = 1.2,
		IdleGlowRange = 10,
		IdleParticleRate = 2,
		IdleBobAmplitude = 0.25,
		IdleBobSpeed = 1.5,
		IdleSpinSpeed = 0.3,
		HasBeam = false,
		RevealDuration = 0.45,
		BurstParticleCount = 12,
	},
	Rare = {
		DisplayName = "Rare",
		Color = { 0.2, 0.5, 1.0 },
		HasParticleWisp = true,
		CoverModelName = "Rare Cart",
		CollectPitch = 1.18,
		IdleGlowBrightness = 2.2,
		IdleGlowRange = 14,
		IdleParticleRate = 5,
		IdleBobAmplitude = 0.35,
		IdleBobSpeed = 1.8,
		IdleSpinSpeed = 0.6,
		HasBeam = false,
		RevealDuration = 0.65,
		BurstParticleCount = 22,
	},
	Epic = {
		DisplayName = "Epic",
		Color = { 0.6, 0.2, 0.9 },
		HasParticleWisp = true,
		CoverModelName = "Epic Cart",
		CollectPitch = 1.32,
		IdleGlowBrightness = 3.2,
		IdleGlowRange = 18,
		IdleParticleRate = 9,
		IdleBobAmplitude = 0.45,
		IdleBobSpeed = 2.1,
		IdleSpinSpeed = 1.0,
		HasBeam = false,
		RevealDuration = 0.9,
		BurstParticleCount = 34,
	},
	Legendary = {
		DisplayName = "Legendary",
		Color = { 1.0, 0.75, 0.1 },
		HasParticleWisp = true,
		CoverModelName = "Legendary", -- literal Workspace name is missing its "Cart" suffix
		CollectPitch = 1.5,
		IdleGlowBrightness = 5,
		IdleGlowRange = 26,
		IdleParticleRate = 16,
		IdleBobAmplitude = 0.55,
		IdleBobSpeed = 2.4,
		IdleSpinSpeed = 1.5,
		HasBeam = true,
		RevealDuration = 1.25,
		BurstParticleCount = 55,
	},
	Secret = {
		DisplayName = "Secret",
		Color = { 1.0, 0.15, 0.75 },
		HasParticleWisp = true,
		CoverModelName = "Secret Cart",
		CollectPitch = 1.7,
		IdleGlowBrightness = 7,
		IdleGlowRange = 34,
		IdleParticleRate = 26,
		IdleBobAmplitude = 0.7,
		IdleBobSpeed = 2.8,
		IdleSpinSpeed = 2.2,
		HasBeam = true,
		RevealDuration = 1.6,
		BurstParticleCount = 80,
	},
} :: { [EconomyConfig.RarityName]: RarityDisplay })

return CartData
