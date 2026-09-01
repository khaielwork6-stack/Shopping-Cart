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

-- �3.4 Cart Cash Value
function EconomyMath.GetWorldCashBase(world: number): number
	return EconomyConfig.Cart.WorldCashBaseStart * (EconomyConfig.Cart.WorldCashBaseGrowth ^ (world - 1))
end

function EconomyMath.GetZoneValueMultiplier(zone: number): number
	return EconomyConfig.Cart.ZoneValueMultiplierGrowth ^ (zone - 1)
end

-- �3.4.3 Cart Cash Value -- full formula for Claude Code
function EconomyMath.GetCartValue(world: number, zone: number, rarity: RarityName, rebirthCashMult: number): number
	local worldBase = EconomyMath.GetWorldCashBase(world)
	local zoneMult = EconomyMath.GetZoneValueMultiplier(zone)
	local rarityMult = EconomyConfig.Rarity[rarity].ValueMultiplier
	local base = worldBase * zoneMult * rarityMult
	return math.floor(base * rebirthCashMult + 0.5)
end

-- �3.5.1 Push Power Requirement
function EconomyMath.GetPowerRequirement(world: number, zone: number): number
	return EconomyConfig.PushPower.RequirementBase
		* (EconomyConfig.PushPower.RequirementWorldGrowth ^ (world - 1))
		* (EconomyConfig.PushPower.RequirementZoneGrowth ^ (zone - 1))
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
function EconomyMath.GetAgilityCollectTime(agilityLevel: number): number
	local cfg = EconomyConfig.UpgradeEffects.agility
	return cfg.CollectTimeBase * (cfg.CollectTimeDecay ^ agilityLevel)
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

	local highTotal = base.Rare.Weight + base.Epic.Weight + base.Legendary.Weight

	local weights = {}
	weights.Common = base.Common.Weight * (1 - shift)
	weights.Uncommon = base.Uncommon.Weight * (1 - shift)
	weights.Rare = base.Rare.Weight + moved * (base.Rare.Weight / highTotal)
	weights.Epic = base.Epic.Weight + moved * (base.Epic.Weight / highTotal)
	weights.Legendary = base.Legendary.Weight + moved * (base.Legendary.Weight / highTotal)

	return weights
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

-- �4.1.1 Per-Zone active cart spawn cap
function EconomyMath.GetMaxActiveCarts(zoneIndexWithinWorld: number): number
	return EconomyConfig.Spawn.MaxActiveCartsBase + EconomyConfig.Spawn.MaxActiveCartsPerZoneIndex * zoneIndexWithinWorld
end

return EconomyMath
