--!strict
-- Index/discovery display data (�4.6). The discovery-bonus formula constant
-- itself lives in EconomyConfig.Index (single source of truth, consumed by
-- EconomyMath) -- this module only owns presentation: the shared per-rarity
-- "???" silhouette used before an item is discovered.

local EconomyConfig = require(script.Parent.EconomyConfig)

local IndexData = {}

-- One shared silhouette per rarity tier, not 110 unique ones (�4.6).
IndexData.SilhouetteByRarity = ({
	Common = "PH_Icon_Silhouette_Common",
	Uncommon = "PH_Icon_Silhouette_Uncommon",
	Rare = "PH_Icon_Silhouette_Rare",
	Epic = "PH_Icon_Silhouette_Epic",
	Legendary = "PH_Icon_Silhouette_Legendary",
	Secret = "PH_Icon_Silhouette_Secret",
} :: { [EconomyConfig.RarityName]: string })

return IndexData
