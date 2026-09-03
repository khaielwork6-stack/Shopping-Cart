--!strict
-- Lost Cart GDD "Mutation System" (flagship depth layer, independent of
-- rarity/cart). NOT wired into the reveal roll yet -- v1 priority per the
-- GDD is "23 real carts -> correct reveal -> polished train join" first,
-- and mutations are explicitly "do not derail this task building the
-- entire mutation system before the base loop is excellent."
--
-- This module exists so the reveal/train pipeline has a real shape to plug
-- into later: LostCartService's reveal payload already carries an optional
-- `mutation: string?` field (always nil today), and
-- LostCartRevealController already branches on it being present. Adding the
-- system later is "roll a MutationData key here" plus real VFX per mutation
-- -- no reveal/train code changes required.

export type MutationName = "Shiny" | "Flaming" | "Frozen" | "Charged" | "Rainbow" | "Corrupted"

export type MutationEntry = {
	DisplayName: string,
	ValueMultiplier: number, -- applied on top of the cart's BaseValue, GDD table
	Color: { number }, -- RGB 0-1, presentation-only for now
}

local MutationData = {}

MutationData.Mutations = ({
	Shiny = { DisplayName = "Shiny", ValueMultiplier = 2, Color = { 1, 1, 1 } },
	Flaming = { DisplayName = "Flaming", ValueMultiplier = 3, Color = { 1, 0.4, 0.1 } },
	Frozen = { DisplayName = "Frozen", ValueMultiplier = 4, Color = { 0.6, 0.85, 1 } },
	Charged = { DisplayName = "Charged", ValueMultiplier = 6, Color = { 1, 0.95, 0.3 } },
	Rainbow = { DisplayName = "Rainbow", ValueMultiplier = 10, Color = { 1, 0.4, 0.9 } },
	-- GDD: "??? (rarest)" -- no pinned multiplier yet, left as a placeholder
	-- until this system is actually built out.
	Corrupted = { DisplayName = "Corrupted", ValueMultiplier = 20, Color = { 0.4, 0.05, 0.5 } },
} :: { [MutationName]: MutationEntry })

return MutationData
