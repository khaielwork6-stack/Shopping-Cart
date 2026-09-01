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

return ZoneData
