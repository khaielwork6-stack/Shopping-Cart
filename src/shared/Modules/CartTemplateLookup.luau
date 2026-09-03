--!strict
-- Lost Cart GDD: the one place that maps a CartID to its actual Model
-- template, shared by TrainController (visual train slots) and
-- LostCartRevealController (the reveal pop) so there's exactly one lookup
-- to keep correct, not two copies that could drift.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LostCartData = require(ReplicatedStorage.Shared.Configs.LostCartData)

local CartTemplateLookup = {}

local CARTS_FOLDER = ReplicatedStorage.Assets.LostCart.Carts :: Folder

-- Pre-GDD single-cart fallback, kept only so an unknown/missing cartId
-- (shouldn't happen) still renders something instead of erroring.
CartTemplateLookup.FallbackTemplate = ReplicatedStorage.Assets.Placeholders:WaitForChild("Cart_Frostbite") :: Model

-- LostCartData.DisplayName is kept identical to the model's own Workspace
-- name at import (never renamed), so this is a direct lookup, not a mapping
-- table that needs to be kept in sync by hand.
function CartTemplateLookup.Get(cartId: string?): Model
	local entry = cartId and LostCartData.GetCart(cartId)
	local template = entry and CARTS_FOLDER:FindFirstChild(entry.DisplayName)
	return (template :: Model?) or CartTemplateLookup.FallbackTemplate
end

return CartTemplateLookup
