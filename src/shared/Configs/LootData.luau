--!strict
-- The Loot Item registry (�4.5/�4.6). Phase 6 populates a first pass (5 per
-- rarity tier, 25 total) -- the guide's own note is that the system must
-- work correctly regardless of whether it's 10 items or 110; full 110-item
-- population (per �4.6's 40/30/25/10/5 split) is incremental data-entry
-- that can complete any time without touching LootService's logic.

export type LootItem = {
	Id: string,
	Name: string,
	Rarity: string, -- one of EconomyConfig.RarityOrder
	SellValue: number,
	SealedChanceOverride: number?, -- overrides EconomyConfig.Loot.SealedChance if set
	IconName: string?, -- ReplicatedStorage.Assets.Placeholders.Icons.<name>, see �7
}

local LootData = {}

LootData.Items = ({
	-- Common
	{ Id = "bent_hubcap", Name = "Bent Hubcap", Rarity = "Common", SellValue = 8 },
	{ Id = "flat_soda_can", Name = "Flattened Soda Can", Rarity = "Common", SellValue = 5 },
	{ Id = "single_glove", Name = "Single Lost Glove", Rarity = "Common", SellValue = 6 },
	{ Id = "receipt_novel", Name = "Receipt Longer Than a Novel", Rarity = "Common", SellValue = 7 },
	{ Id = "squeaky_wheel", Name = "Squeaky Wheel", Rarity = "Common", SellValue = 10 },

	-- Uncommon
	{ Id = "sunglasses", Name = "Cracked Sunglasses", Rarity = "Uncommon", SellValue = 25 },
	{ Id = "coupon_book", Name = "Expired Coupon Book", Rarity = "Uncommon", SellValue = 30 },
	{ Id = "umbrella", Name = "Inside-Out Umbrella", Rarity = "Uncommon", SellValue = 35 },
	{ Id = "parking_ticket", Name = "Uncashed Parking Voucher", Rarity = "Uncommon", SellValue = 40 },
	{ Id = "air_freshener", Name = "Novelty Air Freshener", Rarity = "Uncommon", SellValue = 28 },

	-- Rare
	{ Id = "gold_cart_token", Name = "Gold-Plated Cart Token", Rarity = "Rare", SellValue = 120 },
	{ Id = "designer_bag", Name = "Designer Shopping Bag", Rarity = "Rare", SellValue = 140 },
	{ Id = "car_keys", Name = "Someone's Car Keys", Rarity = "Rare", SellValue = 110 },
	{ Id = "vintage_radio", Name = "Vintage Parking-Lot Radio", Rarity = "Rare", SellValue = 150 },
	{ Id = "lucky_penny", Name = "Suspiciously Lucky Penny", Rarity = "Rare", SellValue = 100 },

	-- Epic
	{ Id = "diamond_cart_wheel", Name = "Diamond Cart Wheel", Rarity = "Epic", SellValue = 450 },
	{ Id = "vip_pass", Name = "VIP Corral Pass", Rarity = "Epic", SellValue = 500 },
	{ Id = "gilded_receipt", Name = "Gilded Golden Receipt", Rarity = "Epic", SellValue = 480 },
	{ Id = "mystery_briefcase", Name = "Unattended Mystery Briefcase", Rarity = "Epic", SellValue = 520 },
	{ Id = "solid_gold_hubcap", Name = "Solid Gold Hubcap", Rarity = "Epic", SellValue = 460 },

	-- Legendary
	{ Id = "golden_cart", Name = "The Golden Shopping Cart", Rarity = "Legendary", SellValue = 2000 },
	{ Id = "crown_of_carts", Name = "Crown of a Thousand Carts", Rarity = "Legendary", SellValue = 2200 },
	{ Id = "eternal_wheel", Name = "The Eternal Squeakless Wheel", Rarity = "Legendary", SellValue = 1900 },
	{ Id = "cart_whisperer_badge", Name = "Cart Whisperer's Badge", Rarity = "Legendary", SellValue = 2100 },
	{ Id = "corral_deed", Name = "Deed to the Corral Itself", Rarity = "Legendary", SellValue = 2500 },
} :: { LootItem })

local itemsByRarity: { [string]: { LootItem } } = {}
for _, item in LootData.Items do
	local list = itemsByRarity[item.Rarity]
	if not list then
		list = {}
		itemsByRarity[item.Rarity] = list
	end
	table.insert(list, item)
end

function LootData.GetItem(itemId: string): LootItem?
	for _, item in LootData.Items do
		if item.Id == itemId then
			return item
		end
	end
	return nil
end

function LootData.GetItemsByRarity(rarity: string): { LootItem }
	return itemsByRarity[rarity] or {}
end

return LootData
