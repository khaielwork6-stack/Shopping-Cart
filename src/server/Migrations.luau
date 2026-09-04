--!strict
-- One function per version transition (�6.5), applied in order on load
-- until version matches current. No migration is ever destructive -- if in
-- doubt, keep the old field alongside the new one rather than delete-and-
-- hope.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local WorldData = require(ReplicatedStorage.Shared.Configs.WorldData)

local Migrations = {}

-- Keyed by the version a save is CURRENTLY at; each entry migrates it to
-- the next version up.
Migrations.Steps = {} :: { [number]: (data: any) -> any }

-- v1 -> v2: Lost Cart migration Phase 2 replaced the old 5-World system
-- (every player defaulted into World1_ParkingLot, TotalLevelRequirement = 0)
-- with a single Main Lane (World5_Airport) every player now starts in,
-- plus four Rebirth-gated bonus Worlds. Every save persisted before this
-- change is at v1 and carries two now-outdated assumptions forward verbatim
-- unless corrected here:
--   1. `currentWorld` was very likely left at 1 (the old default/starter
--      World) -- WorldService/CartSpawnService both trust this field as the
--      player's authoritative location, so an uncorrected v1 save keeps
--      spawning and claim-checking in World1_ParkingLot forever, even
--      though that's now a locked bonus World, not the main loop. This is
--      the exact bug report: "pickup only works in the old World 1."
--   2. `unlockedWorlds` may have Worlds 2-4 grandfathered in from the old
--      Total-Level gates, which the new Rebirth gates (§6.3) never granted.
-- Cash, upgrades, rebirth count, and every other stat are untouched --
-- this only corrects which World the save thinks it's in/has access to.
Migrations.Steps[1] = function(data: any)
	local mainLaneId = WorldData.GetMainLane().Id
	data.currentWorld = mainLaneId

	local correctedUnlocked = { [mainLaneId] = true }
	for _, world in WorldData.Worlds do
		if not world.IsMainLane and data.rebirthCount >= world.RebirthRequirement then
			correctedUnlocked[world.Id] = true
		end
	end
	data.unlockedWorlds = correctedUnlocked

	data.version = 2
	return data
end

function Migrations.Apply(data: any, fromVersion: number, currentVersion: number): any
	local version = fromVersion
	while version < currentVersion do
		local step = Migrations.Steps[version]
		if not step then
			break -- no migration registered for this version -- leave as-is rather than guess
		end
		data = step(data)
		version = data.version or (version + 1)
	end
	return data
end

return Migrations
