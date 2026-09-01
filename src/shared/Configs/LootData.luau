--!strict
-- The Loot Item registry (�4.5/�4.6). Correctly shaped but empty at Phase 0 --
-- Phase 6 populates a first pass, full 110-item population can complete
-- incrementally per �14 Phase 6's note that the system must work regardless
-- of whether it's 10 items or 110.

export type LootItem = {
	Id: string,
	Name: string,
	Rarity: string, -- one of EconomyConfig.RarityOrder
	SellValue: number,
	SealedChanceOverride: number?, -- overrides EconomyConfig.Loot.SealedChance if set
	IconName: string?, -- ReplicatedStorage.Assets.Placeholders.Icons.<name>, see �7
}

local LootData = {}

LootData.Items = {} :: { LootItem }

function LootData.GetItem(itemId: string): LootItem?
	for _, item in LootData.Items do
		if item.Id == itemId then
			return item
		end
	end
	return nil
end

return LootData
