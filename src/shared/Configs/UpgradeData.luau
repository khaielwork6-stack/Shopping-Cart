--!strict
-- Per-stat display metadata (�5.3). Costs/effects are computed via
-- EconomyMath from EconomyConfig, never stored per-level here.

export type UpgradeDisplay = {
	DisplayName: string,
	Description: string,
	IconName: string, -- ReplicatedStorage.Assets.Placeholders.Icons.<name>, see �7
}

local UpgradeData = {}

UpgradeData.Display = ({
	capacity = {
		DisplayName = "Capacity",
		Description = "Increases how many carts your train can carry.",
		IconName = "PH_Icon_Capacity",
	},
	mobility = {
		DisplayName = "Mobility",
		Description = "Increases your walk speed.",
		IconName = "PH_Icon_Mobility",
	},
	range = {
		DisplayName = "Range",
		Description = "Increases your auto-collect pickup radius.",
		IconName = "PH_Icon_Range",
	},
	pushPower = {
		DisplayName = "Push Power",
		Description = "Lets you push through denser resistance in later Zones. Resets on Rebirth.",
		IconName = "PH_Icon_PushPower",
	},
} :: { [string]: UpgradeDisplay })

return UpgradeData
