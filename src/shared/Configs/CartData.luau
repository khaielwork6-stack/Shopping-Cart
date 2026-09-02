--!strict
-- Rarity-tier display metadata (�4.1.6 / �8). Value multipliers and spawn
-- weights are economy constants and live in EconomyConfig, not here -- this
-- table only owns presentation: color, VFX tier, base placeholder icon.

local EconomyConfig = require(script.Parent.EconomyConfig)

export type RarityDisplay = {
	DisplayName: string,
	Color: { number }, -- RGB 0-1
	HasParticleWisp: boolean, -- �4.1.6: one-shot particle wisp for Rare+
	PlaceholderModelName: string, -- ServerStorage.CartTemplates.<name>, see �7
	CollectPitch: number, -- �8: collection "thunk" SFX pitched higher per rarity tier
}

local CartData = {}

CartData.RarityDisplay = ({
	Common = {
		DisplayName = "Common",
		Color = { 0.7, 0.7, 0.7 },
		HasParticleWisp = false,
		PlaceholderModelName = "PH_Cart_Common",
		CollectPitch = 1.0,
	},
	Uncommon = {
		DisplayName = "Uncommon",
		Color = { 0.2, 0.8, 0.3 },
		HasParticleWisp = false,
		PlaceholderModelName = "PH_Cart_Uncommon",
		CollectPitch = 1.08,
	},
	Rare = {
		DisplayName = "Rare",
		Color = { 0.2, 0.5, 1.0 },
		HasParticleWisp = true,
		PlaceholderModelName = "PH_Cart_Rare",
		CollectPitch = 1.18,
	},
	Epic = {
		DisplayName = "Epic",
		Color = { 0.6, 0.2, 0.9 },
		HasParticleWisp = true,
		PlaceholderModelName = "PH_Cart_Epic",
		CollectPitch = 1.32,
	},
	Legendary = {
		DisplayName = "Legendary",
		Color = { 1.0, 0.75, 0.1 },
		HasParticleWisp = true,
		PlaceholderModelName = "PH_Cart_Legendary",
		CollectPitch = 1.5,
	},
} :: { [EconomyConfig.RarityName]: RarityDisplay })

return CartData
