--!strict
-- Per-World static data (�4.7 / GDD). Cart value and Power Requirement math is
-- NOT duplicated here -- it lives in EconomyMath and is keyed off World index.

export type WorldEntry = {
	Id: number,
	Name: string,
	Theme: string,
	TotalLevelRequirement: number, -- Total Level needed to unlock this World
	ZoneCount: number,
	FolderName: string, -- Workspace.Worlds.<FolderName>
}

local WorldData = {}

WorldData.Worlds = ({
	{
		Id = 1,
		Name = "Suburban Strip-Mall Parking Lot",
		Theme = "Suburban strip-mall parking lot",
		TotalLevelRequirement = 0,
		ZoneCount = 8,
		FolderName = "World1_ParkingLot",
	},
	{
		Id = 2,
		Name = "Big-Box Warehouse Club",
		Theme = "Big-box warehouse club parking structure",
		TotalLevelRequirement = 185,
		ZoneCount = 8,
		FolderName = "World2_Warehouse",
	},
	{
		Id = 3,
		Name = "Mega-Mall Ring Road",
		Theme = "Mega-mall ring road (holiday-traffic themed)",
		TotalLevelRequirement = 380,
		ZoneCount = 8,
		FolderName = "World3_MegaMall",
	},
	{
		Id = 4,
		Name = "Downtown Metered Street Parking",
		Theme = "Downtown metered street parking",
		TotalLevelRequirement = 570,
		ZoneCount = 8,
		FolderName = "World4_DowntownStreet",
	},
	{
		Id = 5,
		Name = "Airport Cell-Phone Waiting Lot",
		Theme = "Airport cell-phone waiting lot (absurdist capstone)",
		TotalLevelRequirement = 770,
		ZoneCount = 8,
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

return WorldData
