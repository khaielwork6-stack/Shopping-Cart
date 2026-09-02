--!strict
-- Per-Zone-within-World static data (�4.7). Zones are procedurally identical
-- in formula (World/Zone index feed EconomyMath directly, per �4.7's "one
-- formula, many Worlds" rule) -- this table only holds per-zone overrides
-- that aren't derivable from the formulas, e.g. visual/spawn tag overrides.

export type ZoneOverride = {
	SpawnPointsTag: string, -- CollectionService tag for this zone's spawn Attachments
	VisualOverride: string?, -- optional cosmetic note, no gameplay effect
}

local ZoneData = {}

-- Keyed as ZoneData.Overrides[worldId][zoneIndex]; empty by default. A Phase
-- that needs a per-zone cosmetic override (e.g. World 3's "traffic jam"
-- denser cluster, �4.7) adds an entry here without touching EconomyConfig.
ZoneData.Overrides = {} :: { [number]: { [number]: ZoneOverride } }

function ZoneData.GetSpawnPointsTag(worldId: number, zoneIndex: number): string
	local worldOverrides = ZoneData.Overrides[worldId]
	local zoneOverride = worldOverrides and worldOverrides[zoneIndex]
	if zoneOverride then
		return zoneOverride.SpawnPointsTag
	end
	return string.format("World%dZone%dSpawnPoints", worldId, zoneIndex)
end

-- Each World's Zones are laid out linearly along +Z, each a 450-stud band,
-- Zone N centered at Z = 450*(N-1) (Zone 1 centered on the existing spawn
-- origin at Z=0) -- every World was normalized to this same common zone
-- length (previously 300, before that 100) per §13's second map-resize
-- pass, so this single constant covers all 5 Worlds even though they now
-- have different widths. This is Studio level-layout data, not an economy
-- formula -- purely for the client's cosmetic "which Zone am I standing
-- in" check (�4.2's resistance VFX). Nothing reward-bearing depends on
-- this: claim eligibility is gated per-cart by the Zone it actually
-- spawned in, and the Corral return's SpeedFactor uses the highest Zone
-- among the cargo itself.
local ZONE_BAND_SIZE = 450

function ZoneData.GetZoneIndexFromWorldZ(worldZ: number, zoneCount: number): number
	local index = math.round(worldZ / ZONE_BAND_SIZE) + 1
	return math.clamp(index, 1, zoneCount)
end

return ZoneData
