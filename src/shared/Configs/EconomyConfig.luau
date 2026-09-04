--!strict
-- Raw tunable constants derived in the Master Development Guide, section 3.
-- EconomyMath is the only module allowed to consume these directly; Services
-- must never re-derive or hardcode a number that already lives here.

export type RarityName = "Common" | "Uncommon" | "Rare" | "Epic" | "Legendary" | "Secret"

-- QA pass 2: "agility" (the "Collect Carts Faster" stat) removed entirely --
-- cart collection is now always instant, never gated by a stat/timer.
export type UpgradeStatName = "capacity" | "mobility" | "range" | "pushPower"

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
	LuckMultiplierBase = 1,
	LuckMultiplierPerRebirth = 0.15, -- RebirthLuckMultiplier(n) = 1 + 0.15*n -- Lost Cart migration Phase 2
}

-- World 1 economy rebalance: this map used to be a late-game World (old
-- World5), so cart cash was scaled by a `4.3^(world-1)` term that made a
-- single Common Zone-1 cart worth $1,710 -- a genuine bug, not a design
-- choice (confirmed: it's why a fresh player could make ~$40K off one
-- return). "World" no longer exists as a cash-scaling dimension now that
-- there's one connected lane -- GetCartValue is zone-only, matching GDD v3
-- �5.4's own formula shape (which never had a world term either). Reuses
-- the same 1.58 zone-growth constant CartWeight already uses below, per the
-- GDD's own "one ZONE_GROWTH constant for cash, weight, income" intent.
EconomyConfig.Cart = {
	Zone1CashBase = 5, -- a Common Zone-1 cart is worth $5
	CashZoneGrowth = 1.58,
	ZonesPerWorld = 8, -- fallback zone count only, when a World entry can't be found
}

-- �3.4.1 Rarity table (spawn weight + cash value multiplier)
-- Lost Cart GDD adds a 6th tier, Secret, above Legendary. Legendary's weight
-- is trimmed from 0.01 to 0.008 and Secret takes the remaining 0.002 so the
-- table still sums to exactly 1.0 -- nothing else here changed.
EconomyConfig.RarityOrder = { "Common", "Uncommon", "Rare", "Epic", "Legendary", "Secret" } :: { RarityName }

EconomyConfig.Rarity = {
	Common = { Weight = 0.60, ValueMultiplier = 1 },
	Uncommon = { Weight = 0.25, ValueMultiplier = 3 },
	Rare = { Weight = 0.10, ValueMultiplier = 10 },
	Epic = { Weight = 0.04, ValueMultiplier = 40 },
	Legendary = { Weight = 0.008, ValueMultiplier = 200 },
	Secret = { Weight = 0.002, ValueMultiplier = 1000 },
}

-- Lost Cart GDD v3 �5.3: real cart weight (kg), independent of the �3.4.1
-- Rarity table's `Weight` field above (that one is a spawn-roll probability
-- weight, not a physical mass -- deliberately separate namespaces so the two
-- are never confused for each other).
EconomyConfig.CartWeight = {
	RarityBaseKg = { Common = 20, Uncommon = 35, Rare = 55, Epic = 90, Legendary = 140, Secret = 200 },
	SizeRollMin = 0.6,
	SizeRollMax = 1.8,
	ZoneGrowth = 1.58, -- CartWeight = RarityBaseKg * SizeRoll * 1.58^(zone-1)
}

-- Lost Cart GDD v3 �6.3: Pull Power expressed in the same kg unit as train
-- Load, read off the existing `pushPower` upgrade stat/level -- a second,
-- kg-denominated formula over that same level, separate from the legacy
-- zone-frontier EconomyConfig.PushPower namespace below (which still governs
-- an unrelated mechanic, �3.5.4's soft Zone-advance gate).
--
-- QA pass 2: BaseKg=60 let a level-0 player carry only ~2 average Common
-- Zone-1 carts (~24kg each) before overloading -- punishing before a player
-- has bought a single upgrade. Bumped so the START is comfortable (~4-5
-- Commons) without touching progression further out -- PullPower still
-- grows the same 1.18x per level, so it's still a real, earned upgrade for
-- heavier rarities and deeper Zones.
EconomyConfig.PullPower = {
	BaseKg = 110,
	GrowthPerLevel = 1.18, -- PullPower(level) = 110 * 1.18^level
}

-- Lost Cart GDD v3 �6.1: the real Load-vs-PullPower train speed curve.
EconomyConfig.TrainSpeed = {
	MinSpeedFactor = 0.25, -- "never a hard stop" -- floors at 25%, however overloaded
	OverloadCoefficient = 0.5,
}

-- Lost Cart GDD v3 �6.2: dumping the back cart.
EconomyConfig.Dump = {
	GrabDelaySeconds = 2, -- brief grace window (applies to everyone, including the dropper) so an instant self-repickup can't trivially negate the mechanic
	DespawnSeconds = 20,
}

-- �3.5.1 / �3.5.3 Push Power / Resistance
-- World 1 economy rebalance: PowerRequirement used to also scale by
-- `3.6^(world-1)`, which put Zone 1's requirement at ~504 for a fresh
-- player whose starting Effective Push Power is 1 -- meaning Zone 2 was
-- mathematically unreachable and the Corral's SpeedFactor was permanently
-- floored (the "slow sell pad").
--
-- QA pass 2: the first zone-only fix used an EXPONENTIAL requirement
-- (Base * Growth^(zone-1)), which is backloaded when paired with Effective
-- Push Power's own LINEAR formula (1 + level) -- the first few zones'
-- requirements were so small that 1-2 Push Power levels cleared several of
-- them AT ONCE, then the curve turned into a wall near Zone 13. That's
-- exactly "unlocked a ton of zones with barely any upgrades." Requirement
-- is now LINEAR instead (Base + PerZone*(zone-1)), matching Effective Push
-- Power's own linear shape -- every zone step now costs a comparable,
-- deliberate ~2 Push Power levels, evenly, all the way to Zone 13 (~level
-- 22, still the same ~60-90 minute target from the approved economy plan).
EconomyConfig.PushPower = {
	RequirementBase = 1.2, -- PowerRequirement(zone) = 1.2 + 1.85*(zone-1)
	RequirementPerZone = 1.85,
	SpeedFactorFloor = 0.12,
	SpeedFactorExponent = 0.6,
	ZoneAdvanceGateThreshold = 0.95, -- �3.5.4 soft gate
}

-- �3.7.1 Upgrade cost formula: Cost(stat, level) = BaseCost(stat) * Growth(stat)^level
EconomyConfig.Upgrades = {
	capacity = { BaseCost = 18, Growth = 1.24 },
	mobility = { BaseCost = 12, Growth = 1.20 },
	range = { BaseCost = 12, Growth = 1.20 },
	pushPower = { BaseCost = 10, Growth = 1.27 },
}

-- �3.7.1 Per-level effect constants. BaseCapacity and BaseWalkSpeed are not
-- pinned to a specific number anywhere in the Guide's �3 -- BaseCapacity
-- continues Phase 1's stopgap hardcoded value (10) as the real level-0
-- value, and BaseWalkSpeed uses Roblox's own default Humanoid.WalkSpeed
-- (16 studs/s) as the multiplier's base.
-- QA pass 2: Agility ("Collect Carts Faster") removed entirely -- claiming a
-- cart is now always instant, no stat/timer gates it anymore.
EconomyConfig.UpgradeEffects = {
	capacity = { BaseCapacity = 10 }, -- +1 train slot per level (Capacity(level) = 10 + level)
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

-- �4.1.2 Collection. The Guide references Range's "BaseRadius" but never
-- pins a concrete base radius anywhere in �3 -- this is the one number this
-- project must choose for itself. 6 studs is picked as a comfortable
-- walk-into-it radius at Range level 0 (Phase 1 uses this directly; Range's
-- �3.7.4 multiplier applies starting Phase 2). Collection itself is instant
-- on touch (QA pass 2 removed the Agility-gated collect timer entirely).
EconomyConfig.Collection = {
	BaseClaimRadius = 6,
}

-- Phase 4 �9: the Base system. Slots(rebirthCount) = 8 + 2*rebirthCount
-- (�9.1). Item income is derived from LootData's existing SellValue via
-- �8.3's own ratio (SellPrice = IncomePerSec * 600), not a new per-item
-- field -- one number to keep in sync, not two.
EconomyConfig.Base = {
	BaseSlotCount = 8,
	SlotsPerRebirth = 2,
	IncomeSellValueDivisor = 600,
	OfflineRate = 0.30, -- �9.4
	OfflineCapSeconds = 4 * 3600, -- 4 hours
	LockSeconds = 60, -- �9.2
	LockSecondsPerRebirth = 10,
	VulnerableSeconds = 30,
}

-- Phase 5 �10-11: the bat. Base/only tier for now (bat tiers need the
-- Index's zone-set data, Phase 7) -- already at �11's stated 4s stun cap so
-- a future tier system only ever has to scale knockback, never stun.
EconomyConfig.Bat = {
	SwingCooldownSeconds = 1.5,
	SwingConeRadius = 8, -- studs, "a proximity cone in front of the player" (�19), never a raycast at a cursor
	SwingConeHalfAngleDegrees = 60,
	KnockdownDurationSeconds = 3,
	DiminishingReturnDurations = { 3, 1.5, 0.5 }, -- �10.1: same target hit again within the window
	DiminishingReturnWindowSeconds = 15,
	PostStandImmunitySeconds = 15,
	KnockbackSpeed = 45, -- studs/sec, applied once as an impulse away from the attacker
	CartDropGrabSeconds = 15, -- �10.2 -- distinct from EconomyConfig.Dump's voluntary-dump window (20s)
	NewPlayerProtectionLevel = 10, -- �10.4: protected until Level 10 or 15 minutes, whichever first
	NewPlayerProtectionSeconds = 900,
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

	-- �12.2 Starter Pack: a small Cash+Gems grant plus an early Capacity
	-- level pre-bought -- calibrated to be worth roughly the first 10-15
	-- minutes of grinding, never enough alone to skip an entire World.
	-- Explicitly never Push Power (�12.1/�12.4). Agility no longer exists
	-- (QA pass 2 -- collection is always instant), so its pre-bought level
	-- was removed rather than left dangling.
	StarterPack = {
		Cash = 500,
		Gems = 50,
		CapacityLevels = 1,
	},

	-- �12.5: no AFK/full-automation product -- Auto-Sell Loot is the one
	-- sanctioned automation-adjacent gamepass, and even it only ever saves
	-- a repetitive trip, never plays the core loop for the player.
	AutoSellIntervalSeconds = 60,
}

return EconomyConfig
