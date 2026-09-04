--!strict
-- Per-World static data (�4.7 / GDD). Cart value and Power Requirement math is
-- NOT duplicated here -- it lives in EconomyMath and is keyed off World index.
--
-- Lost Cart migration, Phase 2: World5_Airport is now the Main Lane (GDD v3's
-- single connected 13-zone lane) -- IsMainLane, always accessible, never
-- gated. Worlds 1-4 are kept as separate teleport-accessible "bonus Worlds",
-- re-gated by Rebirth count instead of Total Level (RebirthRequirement
-- replaces the old TotalLevelRequirement entirely -- GDD's "nothing to read"
-- pillar argues against leaving a dead, unused number sitting in this table).

export type WorldEntry = {
	Id: number,
	Name: string,
	Theme: string,
	RebirthRequirement: number, -- Rebirth count needed to unlock this World; 0 = always unlocked
	IsMainLane: boolean?, -- true only for the Main Lane -- never shown in the world-select UI, never gated
	ZoneCount: number,
	FolderName: string, -- Workspace.Worlds.<FolderName>
}

local WorldData = {}

WorldData.Worlds = ({
	{
		Id = 1,
		Name = "Suburban Strip-Mall Parking Lot",
		Theme = "Suburban strip-mall parking lot",
		RebirthRequirement = 1,
		ZoneCount = 8,
		FolderName = "World1_ParkingLot",
	},
	{
		Id = 2,
		Name = "Big-Box Warehouse Club",
		Theme = "Big-box warehouse club parking structure",
		RebirthRequirement = 2,
		ZoneCount = 8,
		FolderName = "World2_Warehouse",
	},
	{
		Id = 3,
		Name = "Mega-Mall Ring Road",
		Theme = "Mega-mall ring road (holiday-traffic themed)",
		RebirthRequirement = 3,
		ZoneCount = 8,
		FolderName = "World3_MegaMall",
	},
	{
		Id = 4,
		Name = "Downtown Metered Street Parking",
		Theme = "Downtown metered street parking",
		RebirthRequirement = 4,
		ZoneCount = 8,
		FolderName = "World4_DowntownStreet",
	},
	{
		Id = 5,
		Name = "Main Lane",
		Theme = "Your home base -- the game's starting Main Lane",
		RebirthRequirement = 0,
		IsMainLane = true,
		ZoneCount = 13,
		FolderName = "World5_Airport",
	},
} :: { WorldEntry })

function WorldData.GetWorld(worldId: number): WorldEntry?
	for _, world in WorldData.Worlds do
		if world.Id == worldId then
			return world
		end
	end
	return nil
end

function WorldData.GetMainLane(): WorldEntry
	for _, world in WorldData.Worlds do
		if world.IsMainLane then
			return world
		end
	end
	error("WorldData: no World is marked IsMainLane")
end

return WorldData
