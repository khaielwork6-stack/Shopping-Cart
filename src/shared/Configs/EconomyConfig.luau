--!strict
-- Raw tunable constants derived in the Master Development Guide, section 3.
-- EconomyMath is the only module allowed to consume these directly; Services
-- must never re-derive or hardcode a number that already lives here.

export type RarityName = "Common" | "Uncommon" | "Rare" | "Epic" | "Legendary"

export type UpgradeStatName = "capacity" | "agility" | "mobility" | "range" | "pushPower"

local EconomyConfig = {}

-- �3.2 Player Leveling
EconomyConfig.XP = {
	ExponentPerLevel = 1.4,
	CoefficientPerLevel = 20,
	CashToXPDivisor = 5,
}

-- �3.3 Rebirth Level Requirements & multipliers
EconomyConfig.Rebirth = {
	LevelRequirementPerRebirth = 25, -- RebirthLevelRequirement(k) = 25 * k
	PushPowerMultiplierBase = 1,
	PushPowerMultiplierPerRebirth = 0.5, -- RebirthPushPowerMultiplier(n) = 1 + 0.5*n
	CashMultiplierBase = 1,
	CashMultiplierPerRebirth = 0.2, -- RebirthCashMultiplier(n) = 1 + 0.2*n
}

-- �3.4 Cart Cash Value
EconomyConfig.Cart = {
	WorldCashBaseStart = 5, -- WorldCashBase(world) = 5 * 4.3 ^ (world - 1)
	WorldCashBaseGrowth = 4.3,
	ZoneValueMultiplierGrowth = 1.22, -- ZoneValueMultiplier(zone) = 1.22 ^ (zone - 1)
	ZonesPerWorld = 8,
}

-- �3.4.1 Rarity table (spawn weight + cash value multiplier)
EconomyConfig.RarityOrder = { "Common", "Uncommon", "Rare", "Epic", "Legendary" } :: { RarityName }

EconomyConfig.Rarity = {
	Common = { Weight = 0.60, ValueMultiplier = 1 },
	Uncommon = { Weight = 0.25, ValueMultiplier = 3 },
	Rare = { Weight = 0.10, ValueMultiplier = 10 },
	Epic = { Weight = 0.04, ValueMultiplier = 40 },
	Legendary = { Weight = 0.01, ValueMultiplier = 200 },
}

-- �3.5.1 / �3.5.3 Push Power / Resistance
EconomyConfig.PushPower = {
	RequirementBase = 3.0, -- PowerRequirement(world, zone) = 3.0 * 3.6^(world-1) * 1.42^(zone-1)
	RequirementWorldGrowth = 3.6,
	RequirementZoneGrowth = 1.42,
	SpeedFactorFloor = 0.12,
	SpeedFactorExponent = 0.6,
	ZoneAdvanceGateThreshold = 0.95, -- �3.5.4 soft gate
}

-- �3.7.1 Upgrade cost formula: Cost(stat, level) = BaseCost(stat) * Growth(stat)^level
EconomyConfig.Upgrades = {
	capacity = { BaseCost = 18, Growth = 1.24 },
	agility = { BaseCost = 15, Growth = 1.24 },
	mobility = { BaseCost = 12, Growth = 1.20 },
	range = { BaseCost = 12, Growth = 1.20 },
	pushPower = { BaseCost = 10, Growth = 1.27 },
}

-- �3.7.1 Per-level effect constants. BaseCapacity and BaseWalkSpeed are not
-- pinned to a specific number anywhere in the Guide's �3 -- BaseCapacity
-- continues Phase 1's stopgap hardcoded value (10) as the real level-0
-- value, and BaseWalkSpeed uses Roblox's own default Humanoid.WalkSpeed
-- (16 studs/s) as the multiplier's base.
EconomyConfig.UpgradeEffects = {
	capacity = { BaseCapacity = 10 }, -- +1 train slot per level (Capacity(level) = 10 + level)
	agility = { CollectTimeBase = 1.0, CollectTimeDecay = 0.965 }, -- CollectTime = 1.0 * 0.965^level
	mobility = { BaseWalkSpeed = 16, WalkSpeedBonusPerLevel = 0.05 }, -- BaseSpeed * (1 + 0.05*level)
	range = {
		RadiusBonusPerLevel = 0.05, -- BaseRadius * (1 + 0.05*level)
		TravelTimeDecay = 0.97, -- effective inter-cart travel time * 0.97^level
	},
	pushPower = {}, -- +1 Push Power level per purchase; resets to 0 on Rebirth
}

-- �3.8 Luck (mathematically safe reallocation formula)
EconomyConfig.Luck = {
	ShiftCap = 0.70,
	ShiftCoefficient = 0.15, -- shift = min(0.70, 1 - 1/(1 + 0.15*(luck-1)))
}

-- �4.5 Loot pipeline
EconomyConfig.Loot = {
	BaseDropChance = 0.08, -- LootDropChance = 0.08 * (1 + 0.6*shift)
	DropChanceShiftCoefficient = 0.6,
	SealedChance = 0.15,
	BagCapacity = 40,
}

-- �4.6 Index
EconomyConfig.Index = {
	TotalItems = 110,
	RaritySplit = { Common = 40, Uncommon = 30, Rare = 25, Epic = 10, Legendary = 5 },
	PushPowerBonusPerTenDiscovered = 0.025, -- 1 + 0.025 * floor(discovered/10)

	-- �3.8/�7.3's Luck source is left as "a recommendation" by the Guide
	-- ("a slow passive gain from Index completion milestones... this
	-- project's choice, not a pinned formula"). Mirrors the Push Power
	-- bonus's own shape (+X per 10 discovered) for consistency. At the
	-- current 25-item first-pass registry this caps Luck at x1.2; once
	-- population reaches all 110 items (incremental, per Phase 6's note)
	-- it reaches x2.1, matching �3.8's table's meaningfully-impactful range.
	LuckBonusPerTenDiscovered = 0.1, -- Luck = 1 + 0.1 * floor(discovered/10)
}

-- �4.1.1 Cart spawn / respawn
EconomyConfig.Spawn = {
	MaxActiveCartsBase = 14, -- MaxActiveCarts(zone) = 14 + 3 * zoneIndexWithinWorld
	MaxActiveCartsPerZoneIndex = 3,
	RespawnDelayMin = 2,
	RespawnDelayMax = 6,
}

-- �4.1.2 Collection. The Guide references Range's "BaseRadius" and Agility's
-- collect timer but never pins a concrete base radius anywhere in �3 -- this
-- is the one number this project must choose for itself. 6 studs is picked
-- as a comfortable walk-into-it radius at Range level 0 (Phase 1 uses this
-- directly; Range's �3.7.4 multiplier applies starting Phase 2).
EconomyConfig.Collection = {
	BaseClaimRadius = 6,
}

-- �4.2 Push Power resistance. The Guide describes SpeedFactor as dividing
-- into "a cart's approach/travel time and the return-trip-to-corral time,"
-- while also stating -- unambiguously -- that the player's own WalkSpeed is
-- never touched by resistance ("communicated via animation playback-speed
-- scaling... not character root movement"). Those two statements only both
-- hold if "travel time" is an abstracted quantity, not literal WalkSpeed.
-- This project's concrete implementation: resistance becomes a genuine
-- required-dwell-time at the Corral before a return completes (mirroring
-- the existing CollectTime dwell-timer pattern from �4.1.2), scaled by
-- SpeedFactor exactly as �4.2 specifies for "return-trip-to-corral time."
-- "Cart approach/travel time" is satisfied by the real-time cost of
-- physical walking (already governed by Mobility/Range, per �3.7.4's own
-- "effective inter-cart travel time" language, which is itself an
-- abstraction over literal movement) -- WalkSpeed itself is never modified
-- by Push Power, matching the Guide's explicit constraint. BaseReturnDuration
-- is not pinned to a number anywhere in �3 -- this project's choice.
EconomyConfig.Resistance = {
	BaseReturnDuration = 1.5, -- seconds, before SpeedFactor is applied
}

-- �6.3 Save system timing
EconomyConfig.Save = {
	AutosaveIntervalSeconds = 180,
	RetryBackoffSeconds = { 1, 4, 9 },
	MaxRetryAttempts = 3,
}

-- Monetization (PROPOSED ADDITION per the Guide's �12 -- every multiplier
-- here was calculated against �3.9's pacing model, not guessed). Product
-- IDs are placeholders (0 = "not yet configured") until the corresponding
-- Gamepass/Dev Product is actually created for this experience on the
-- Creator Dashboard and its real numeric ID is pasted in here -- nothing
-- in MonetizationService calls MarketplaceService for an id of 0, so an
-- unconfigured product is simply inert rather than erroring.
EconomyConfig.Monetization = {
	GamepassIds = {
		TwoXCash = 0,
		LuckBoost = 0,
		CapacityPlus = 0,
		VIP = 0,
		AutoSellLoot = 0,
		SellX2 = 0,
	},
	DevProductIds = {
		TempTwoXCash = 0,
		TempLuckBoost = 0,
		GemPackSmall = 0,
		GemPackMedium = 0,
		GemPackLarge = 0,
		StarterPack = 0,
	},

	-- �12.2 calculated effects
	TwoXCashMultiplier = 2,
	LuckBoostMultiplier = 2,
	CapacityPlusBonus = 10, -- flat +10 train slots
	VIPCashBonus = 0.10, -- +10% passive Cash, deliberately the weakest numeric effect (VIP should sell on status/cosmetics, not power)

	-- �12.3 Dev products
	TempBoostDurationSeconds = 1800, -- 30 min
	GemPackAmounts = { Small = 100, Medium = 550, Large = 1200 },

	-- �12.2 Starter Pack: a small Cash+Gems grant plus 1-2 early
	-- Capacity/Agility levels pre-bought -- calibrated to be worth roughly
	-- the first 10-15 minutes of grinding, never enough alone to skip an
	-- entire World. Explicitly never Push Power (�12.1/�12.4).
	StarterPack = {
		Cash = 500,
		Gems = 50,
		CapacityLevels = 1,
		AgilityLevels = 1,
	},

	-- �12.5: no AFK/full-automation product -- Auto-Sell Loot is the one
	-- sanctioned automation-adjacent gamepass, and even it only ever saves
	-- a repetitive trip, never plays the core loop for the player.
	AutoSellIntervalSeconds = 60,
}

return EconomyConfig
