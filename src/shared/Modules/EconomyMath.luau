--!strict
-- Every formula from Master Development Guide �3, implemented once. Services
-- call into this module; nothing recomputes a formula locally (�5.3).

local EconomyConfig = require(script.Parent.Parent.Configs.EconomyConfig)

type RarityName = EconomyConfig.RarityName
type UpgradeStatName = EconomyConfig.UpgradeStatName

local EconomyMath = {}

-- �3.2 Player Leveling
function EconomyMath.GetXPRequired(level: number): number
	return math.round(EconomyConfig.XP.CoefficientPerLevel * (level ^ EconomyConfig.XP.ExponentPerLevel))
end

function EconomyMath.GetCumulativeXP(level: number): number
	local total = 0
	for lvl = 1, level do
		total += EconomyMath.GetXPRequired(lvl)
	end
	return total
end

function EconomyMath.GetXPFromCashValue(cashValue: number): number
	return math.max(1, math.round(cashValue / EconomyConfig.XP.CashToXPDivisor))
end

-- �3.3 Rebirth requirements & multipliers
function EconomyMath.GetRebirthLevelRequirement(rebirthNumber: number): number
	return EconomyConfig.Rebirth.LevelRequirementPerRebirth * rebirthNumber
end

function EconomyMath.GetCumulativeTotalLevel(afterRebirths: number): number
	local k = afterRebirths
	return EconomyConfig.Rebirth.LevelRequirementPerRebirth * k * (k + 1) / 2
end

function EconomyMath.GetRebirthPushPowerMultiplier(completedRebirths: number): number
	return EconomyConfig.Rebirth.PushPowerMultiplierBase
		+ EconomyConfig.Rebirth.PushPowerMultiplierPerRebirth * completedRebirths
end

function EconomyMath.GetRebirthCashMultiplier(completedRebirths: number): number
	return EconomyConfig.Rebirth.CashMultiplierBase + EconomyConfig.Rebirth.CashMultiplierPerRebirth * completedRebirths
end

-- Lost Cart migration Phase 2: Rebirth now also grows Luck, alongside Cash
-- and Push Power -- same linear shape as the other two.
function EconomyMath.GetRebirthLuckMultiplier(completedRebirths: number): number
	return EconomyConfig.Rebirth.LuckMultiplierBase + EconomyConfig.Rebirth.LuckMultiplierPerRebirth * completedRebirths
end

-- World 1 economy rebalance: zone-only now -- see EconomyConfig.Cart's own
-- comment on why the old world-scaling term was a bug, not a design choice.
-- CartValue(zone, rarity) = 5 * 1.58^(zone-1) * RarityMult * RebirthMult,
-- matching GDD v3 �5.4's formula shape (which never had a world term).
function EconomyMath.GetCartValue(zone: number, rarity: RarityName, rebirthCashMult: number): number
	local zoneMult = EconomyConfig.Cart.CashZoneGrowth ^ (zone - 1)
	local rarityMult = EconomyConfig.Rarity[rarity].ValueMultiplier
	local base = EconomyConfig.Cart.Zone1CashBase * zoneMult * rarityMult
	return math.floor(base * rebirthCashMult + 0.5)
end

-- Lost Cart GDD v3 �5.3: CartWeight = RarityBaseKg * SizeRoll * 1.58^(zone-1).
-- sizeRoll is rolled once server-side at claim time and passed in here (never
-- re-rolled), so a cart's weight is stable for its lifetime in the train.
function EconomyMath.GetCartWeight(rarity: RarityName, zoneIndex: number, sizeRoll: number): number
	local baseKg = EconomyConfig.CartWeight.RarityBaseKg[rarity]
	return baseKg * sizeRoll * (EconomyConfig.CartWeight.ZoneGrowth ^ (zoneIndex - 1))
end

-- Lost Cart GDD v3 �6.3: PullPower(level) = 60 * 1.18^level, over the same
-- `pushPower` upgrade level the legacy zone-frontier formulas below also read.
function EconomyMath.GetPullPowerKg(pushPowerLevel: number): number
	return EconomyConfig.PullPower.BaseKg * (EconomyConfig.PullPower.GrowthPerLevel ^ pushPowerLevel)
end

-- Lost Cart GDD v3 �6.1: the real Load-vs-PullPower train speed curve.
-- "Never a hard stop" -- overloading to any degree still floors at
-- MinSpeedFactor rather than stopping the player outright.
function EconomyMath.GetTrainSpeedFactor(load: number, pullPowerKg: number): number
	if load <= pullPowerKg or pullPowerKg <= 0 then
		return 1.0
	end
	local overloadFraction = (load - pullPowerKg) / pullPowerKg
	return math.max(EconomyConfig.TrainSpeed.MinSpeedFactor, 1.0 - EconomyConfig.TrainSpeed.OverloadCoefficient * overloadFraction)
end

-- �3.5.1 Push Power Requirement -- zone-only, linear (not exponential) so it
-- paces evenly against Effective Push Power's own linear (1+level) shape --
-- see EconomyConfig.PushPower's own comment on both rebalance passes.
function EconomyMath.GetPowerRequirement(zone: number): number
	return EconomyConfig.PushPower.RequirementBase + EconomyConfig.PushPower.RequirementPerZone * (zone - 1)
end

-- �3.5.3 Effective Push Power = (1 + PushPowerLevel) * RebirthPushPowerMultiplier * IndexBonus
function EconomyMath.GetEffectivePushPower(pushPowerLevel: number, rebirthPushPowerMultiplier: number, indexPushPowerBonus: number): number
	return (1 + pushPowerLevel) * rebirthPushPowerMultiplier * indexPushPowerBonus
end

-- �3.5.3 / �4.2 SpeedFactor(r)
function EconomyMath.GetSpeedFactor(effectivePushPower: number, powerRequirement: number): number
	if powerRequirement <= 0 then
		return 1.0
	end
	local r = effectivePushPower / powerRequirement
	if r >= 1 then
		return 1.0
	end
	return math.max(EconomyConfig.PushPower.SpeedFactorFloor, r ^ EconomyConfig.PushPower.SpeedFactorExponent)
end

-- �3.5.4 Zone-advance soft gate
function EconomyMath.CanAdvanceToZone(effectivePushPower: number, nextZonePowerRequirement: number): boolean
	return effectivePushPower >= EconomyConfig.PushPower.ZoneAdvanceGateThreshold * nextZonePowerRequirement
end

-- �3.7.1 Cost(stat, level) = BaseCost(stat) * Growth(stat)^level
function EconomyMath.GetUpgradeCost(stat: UpgradeStatName, level: number): number
	local cfg = EconomyConfig.Upgrades[stat]
	return math.floor(cfg.BaseCost * (cfg.Growth ^ level) + 0.5)
end

-- �3.7.1 Per-stat effect helpers

function EconomyMath.GetTrainCapacity(capacityLevel: number): number
	return EconomyConfig.UpgradeEffects.capacity.BaseCapacity + capacityLevel
end

function EconomyMath.GetMobilityWalkSpeed(mobilityLevel: number): number
	local cfg = EconomyConfig.UpgradeEffects.mobility
	return cfg.BaseWalkSpeed * (1 + cfg.WalkSpeedBonusPerLevel * mobilityLevel)
end

function EconomyMath.GetMobilitySpeedMultiplier(mobilityLevel: number): number
	return 1 + EconomyConfig.UpgradeEffects.mobility.WalkSpeedBonusPerLevel * mobilityLevel
end

function EconomyMath.GetRangeRadiusMultiplier(rangeLevel: number): number
	return 1 + EconomyConfig.UpgradeEffects.range.RadiusBonusPerLevel * rangeLevel
end

function EconomyMath.GetRangeTravelTimeMultiplier(rangeLevel: number): number
	return EconomyConfig.UpgradeEffects.range.TravelTimeDecay ^ rangeLevel
end

-- �3.8 Luck -- mathematically safe reallocation formula
function EconomyMath.GetLuckShift(luck: number): number
	local raw = 1 - 1 / (1 + EconomyConfig.Luck.ShiftCoefficient * (luck - 1))
	return math.min(EconomyConfig.Luck.ShiftCap, raw)
end

function EconomyMath.LuckReallocate(luck: number): { [string]: number }
	local shift = EconomyMath.GetLuckShift(luck)

	local base = EconomyConfig.Rarity
	local movable = base.Common.Weight + base.Uncommon.Weight
	local moved = movable * shift

	local highTotal = base.Rare.Weight + base.Epic.Weight + base.Legendary.Weight + base.Secret.Weight

	local weights = {}
	weights.Common = base.Common.Weight * (1 - shift)
	weights.Uncommon = base.Uncommon.Weight * (1 - shift)
	weights.Rare = base.Rare.Weight + moved * (base.Rare.Weight / highTotal)
	weights.Epic = base.Epic.Weight + moved * (base.Epic.Weight / highTotal)
	weights.Legendary = base.Legendary.Weight + moved * (base.Legendary.Weight / highTotal)
	weights.Secret = base.Secret.Weight + moved * (base.Secret.Weight / highTotal)

	return weights
end

-- �4.1.1 Weighted rarity roll from a weights table (base EconomyConfig.Rarity
-- weights, or a Luck-reallocated table from LuckReallocate). Kept generic on
-- the weights argument so the caller decides which Luck value applies.
function EconomyMath.RollRarity(weights: { [string]: number }): RarityName
	local roll = math.random()
	local cumulative = 0
	for _, rarity in EconomyConfig.RarityOrder do
		cumulative += weights[rarity] or 0
		if roll <= cumulative then
			return rarity
		end
	end
	return EconomyConfig.RarityOrder[#EconomyConfig.RarityOrder] -- floating-point edge case fallback
end

-- �4.5 Loot drop chance shares the same bounded shift term as rarity
function EconomyMath.GetLootDropChance(luck: number): number
	local shift = EconomyMath.GetLuckShift(luck)
	return EconomyConfig.Loot.BaseDropChance * (1 + EconomyConfig.Loot.DropChanceShiftCoefficient * shift)
end

-- �4.6 Index passive Push Power bonus
function EconomyMath.GetIndexPushPowerBonus(uniqueItemsDiscovered: number): number
	return 1 + EconomyConfig.Index.PushPowerBonusPerTenDiscovered * math.floor(uniqueItemsDiscovered / 10)
end

-- �7.3/�3.8: this project's chosen Luck source (see EconomyConfig.Index's
-- comment) -- a slow passive gain from Index completion, the same shape as
-- the Push Power bonus above. Future gamepass/event Luck sources (�12.2)
-- multiply on top of this base value, per the GDD's stacking rule.
function EconomyMath.GetLuckFromDiscoveries(uniqueItemsDiscovered: number): number
	return 1 + EconomyConfig.Index.LuckBonusPerTenDiscovered * math.floor(uniqueItemsDiscovered / 10)
end

-- �4.1.1 Per-Zone active cart spawn cap
function EconomyMath.GetMaxActiveCarts(zoneIndexWithinWorld: number): number
	return EconomyConfig.Spawn.MaxActiveCartsBase + EconomyConfig.Spawn.MaxActiveCartsPerZoneIndex * zoneIndexWithinWorld
end

-- Phase 4 �9.1: Base slot count grows with Rebirth, same linear shape as
-- every other Rebirth-scaled quantity in this project.
function EconomyMath.GetBaseSlotCount(rebirthCount: number): number
	return EconomyConfig.Base.BaseSlotCount + EconomyConfig.Base.SlotsPerRebirth * rebirthCount
end

-- Phase 4 �8.3: IncomePerSec derived from the item's existing SellValue via
-- the GDD's own ratio, inverted -- never a second per-item number to keep
-- in sync with SellValue by hand.
function EconomyMath.GetItemIncomePerSec(sellValue: number): number
	return sellValue / EconomyConfig.Base.IncomeSellValueDivisor
end

-- Phase 4 �9.2: how long a Base stays Locked before its next Vulnerable
-- window, scaled by Rebirth.
function EconomyMath.GetBaseLockSeconds(rebirthCount: number): number
	return EconomyConfig.Base.LockSeconds + EconomyConfig.Base.LockSecondsPerRebirth * rebirthCount
end

return EconomyMath
