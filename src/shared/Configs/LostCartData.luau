--!strict
-- Lost Cart GDD "Cart Data Schema" -- the single centralized database for
-- every real, collectible cart. Adding cart #24 is "one new entry in
-- LostCartData.Carts + one model dropped in
-- ReplicatedStorage.Assets.LostCart.Carts" -- never a new script.
--
-- Security (GDD explicit warning): this module is Shared (client-readable),
-- and that's fine -- knowing the roster and odds isn't the leak. The actual
-- CartID for any given world spawn is rolled server-side, in
-- LostCartService, at the moment of collection, and only sent to that one
-- client via the CartRevealed remote. The world-spawned cover instance
-- itself only ever carries a Rarity attribute -- never a CartID -- so
-- nothing here lets a client see through a wall to know which specific
-- cart a given spawn actually is before touching it.
--
-- BaseValue here is the GDD schema's own field (display/reference data for
-- a future Index card), deliberately NOT wired into the actual cash-value
-- calculation -- this project's existing cash economy
-- (EconomyMath.GetCartValue, world/zone/rarity-driven) is proven-balanced
-- and out of scope to rebuild for this pass. Rebalance/wire it later if the
-- GDD's per-cart-value economy is explicitly requested.

local EconomyConfig = require(script.Parent.EconomyConfig)

export type WeightClass = "Light" | "Medium" | "Heavy"
export type LootLuckBand = "Poor" | "Below Average" | "Average" | "Good" | "Great" | "Excellent" | "Insane"

export type CartEntry = {
	CartID: string,
	DisplayName: string, -- also the exact Workspace model name, unchanged from import
	Rarity: EconomyConfig.RarityName,
	BaseValue: number,
	Weight: WeightClass,
	LootLuckBand: LootLuckBand,
	NativeWorld: number, -- 1-5, "Very High" spawn weight; every other World gets "Low"
	FlavorText: string?,
}

local LostCartData = {}

-- World affinity weights (GDD: "soft, not locked" -- every cart CAN appear
-- anywhere). NativeWorld gets the "Very High" weight below; every other
-- World gets the "Low" weight, so a cross-world rare find stays possible
-- but genuinely uncommon.
LostCartData.WorldAffinityWeight = {
	Native = 20,
	Global = 1,
}

LostCartData.Carts = ({
	-- Common (4)
	RustyCart = {
		CartID = "RustyCart",
		DisplayName = "Rusty Cart",
		Rarity = "Common",
		BaseValue = 50,
		Weight = "Medium",
		LootLuckBand = "Poor",
		NativeWorld = 1,
		FlavorText = "Older than the store itself.",
	},
	RedCart = {
		CartID = "RedCart",
		DisplayName = "Red Cart",
		Rarity = "Common",
		BaseValue = 60,
		Weight = "Medium",
		LootLuckBand = "Poor",
		NativeWorld = 1,
	},
	GreenCart = {
		CartID = "GreenCart",
		DisplayName = "Green Cart",
		Rarity = "Common",
		BaseValue = 60,
		Weight = "Medium",
		LootLuckBand = "Poor",
		NativeWorld = 2,
	},
	BananaCart = {
		CartID = "BananaCart",
		DisplayName = "Banana Cart",
		Rarity = "Common",
		BaseValue = 75,
		Weight = "Light",
		LootLuckBand = "Below Average",
		NativeWorld = 2,
	},

	-- Uncommon (4)
	SodaCart = {
		CartID = "SodaCart",
		DisplayName = "Soda Cart",
		Rarity = "Uncommon",
		BaseValue = 180,
		Weight = "Light",
		LootLuckBand = "Average",
		NativeWorld = 1,
	},
	CamelCart = {
		CartID = "CamelCart",
		DisplayName = "Camel Cart",
		Rarity = "Uncommon",
		BaseValue = 220,
		Weight = "Medium",
		LootLuckBand = "Average",
		NativeWorld = 4,
	},
	CappuccinaCart = {
		CartID = "CappuccinaCart",
		DisplayName = "cappuccina cart",
		Rarity = "Uncommon",
		BaseValue = 240,
		Weight = "Light",
		LootLuckBand = "Average",
		NativeWorld = 3,
	},
	FriesCart = {
		CartID = "FriesCart",
		DisplayName = "Fries cart",
		Rarity = "Uncommon",
		BaseValue = 200,
		Weight = "Light",
		LootLuckBand = "Average",
		NativeWorld = 1,
	},

	-- Rare (5)
	CrystalCart = {
		CartID = "CrystalCart",
		DisplayName = "Crystal Cart",
		Rarity = "Rare",
		BaseValue = 650,
		Weight = "Heavy",
		LootLuckBand = "Good",
		NativeWorld = 2,
		FlavorText = "Catches the light from every angle.",
	},
	TreasureCart = {
		CartID = "TreasureCart",
		DisplayName = "Treasure Cart",
		Rarity = "Rare",
		BaseValue = 800,
		Weight = "Heavy",
		LootLuckBand = "Good",
		NativeWorld = 3,
	},
	Pizzarino = {
		CartID = "Pizzarino",
		DisplayName = "Pizzarino",
		Rarity = "Rare",
		BaseValue = 700,
		Weight = "Medium",
		LootLuckBand = "Good",
		NativeWorld = 3,
	},
	ChickenJockyCart = {
		CartID = "ChickenJockyCart",
		DisplayName = "Chicken Jocky Cart",
		Rarity = "Rare",
		BaseValue = 750,
		Weight = "Medium",
		LootLuckBand = "Good",
		NativeWorld = 3,
	},
	CapybaraCart = {
		CartID = "CapybaraCart",
		DisplayName = "Capybara Cart",
		Rarity = "Rare",
		BaseValue = 700,
		Weight = "Medium",
		LootLuckBand = "Good",
		NativeWorld = 4,
	},

	-- Epic (5)
	DodgeCart = {
		CartID = "DodgeCart",
		DisplayName = "Dodge Cart",
		Rarity = "Epic",
		BaseValue = 2800,
		Weight = "Medium",
		LootLuckBand = "Great",
		NativeWorld = 4,
	},
	TungTungCart = {
		CartID = "TungTungCart",
		DisplayName = "Tung Tung Cart",
		Rarity = "Epic",
		BaseValue = 3200,
		Weight = "Heavy",
		LootLuckBand = "Great",
		NativeWorld = 4,
		FlavorText = "It's coming for your cart.",
	},
	BananittaCart = {
		CartID = "BananittaCart",
		DisplayName = " Bananitta Cart",
		Rarity = "Epic",
		BaseValue = 3000,
		Weight = "Medium",
		LootLuckBand = "Great",
		NativeWorld = 4,
	},
	LavaCart = {
		CartID = "LavaCart",
		DisplayName = "Lava Cart",
		Rarity = "Epic",
		BaseValue = 3500,
		Weight = "Heavy",
		LootLuckBand = "Great",
		NativeWorld = 5,
	},
	Cart67 = {
		CartID = "Cart67",
		DisplayName = "67 cart",
		Rarity = "Epic",
		BaseValue = 3000,
		Weight = "Light",
		LootLuckBand = "Great",
		NativeWorld = 5,
	},

	-- Legendary (3)
	AngelCart = {
		CartID = "AngelCart",
		DisplayName = "Angel Cart",
		Rarity = "Legendary",
		BaseValue = 14000,
		Weight = "Heavy",
		LootLuckBand = "Excellent",
		NativeWorld = 5,
		FlavorText = "Descended, apparently, to shop.",
	},
	NukeCart = {
		CartID = "NukeCart",
		DisplayName = "Nuke Cart",
		Rarity = "Legendary",
		BaseValue = 16000,
		Weight = "Heavy",
		LootLuckBand = "Excellent",
		NativeWorld = 5,
	},
	GlitchCart = {
		CartID = "GlitchCart",
		DisplayName = "Glitch Cart",
		Rarity = "Legendary",
		BaseValue = 15000,
		Weight = "Medium",
		LootLuckBand = "Excellent",
		NativeWorld = 5,
	},

	-- Secret (2)
	EvilCart = {
		CartID = "EvilCart",
		DisplayName = "Evil Cart",
		Rarity = "Secret",
		BaseValue = 60000,
		Weight = "Heavy",
		LootLuckBand = "Insane",
		NativeWorld = 5,
		FlavorText = "It was never lost. It was waiting.",
	},
	TralaleroCart = {
		CartID = "TralaleroCart",
		DisplayName = "Tralalero Cart",
		Rarity = "Secret",
		BaseValue = 75000,
		Weight = "Light",
		LootLuckBand = "Insane",
		NativeWorld = 5,
		FlavorText = "Tralalero Tralala.",
	},
} :: { [string]: CartEntry })

-- Derived: CartID list grouped by rarity, for the weighted in-rarity roll.
-- Built once at require time, not recomputed per spawn.
LostCartData.CartIdsByRarity = {} :: { [EconomyConfig.RarityName]: { string } }
for cartId, entry in LostCartData.Carts do
	local list = LostCartData.CartIdsByRarity[entry.Rarity]
	if not list then
		list = {}
		LostCartData.CartIdsByRarity[entry.Rarity] = list
	end
	table.insert(list, cartId)
end

function LostCartData.GetCart(cartId: string): CartEntry?
	return LostCartData.Carts[cartId]
end

-- §GDD World Affinity: per-World spawn weight for one cart, "Very High"
-- (LostCartData.WorldAffinityWeight.Native) in its NativeWorld, "Low"
-- (.Global) everywhere else.
function LostCartData.GetWorldWeight(cartId: string, worldId: number): number
	local entry = LostCartData.Carts[cartId]
	if not entry then
		return 0
	end
	if entry.NativeWorld == worldId then
		return LostCartData.WorldAffinityWeight.Native
	end
	return LostCartData.WorldAffinityWeight.Global
end

return LostCartData
