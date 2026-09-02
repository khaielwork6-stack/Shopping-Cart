--!strict
-- Client-side purchase prompts (§12). Gamepass/Dev Product purchases can be
-- prompted directly from the client -- MarketplaceService:PromptGamePassPurchase
-- and PromptProductPurchase need no Remote round-trip; only granting a Dev
-- Product's effect is server-side (MonetizationService's ProcessReceipt).
--
-- No custom purchase UI exists yet -- §12's own spec explicitly says
-- "Roblox's native gamepass/product prompts are acceptable and recommended,
-- no need to build custom purchase UI" -- so this Controller is the reusable
-- entry point a future Shop screen's buttons call into, one line per button,
-- keyed by the same GamepassIds/DevProductIds names as EconomyConfig.Monetization.

local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local EconomyConfig = require(ReplicatedStorage.Shared.Configs.EconomyConfig)

local MonetizationController = {}

local player = Players.LocalPlayer
local MonetizationConfig = EconomyConfig.Monetization

function MonetizationController.PromptGamepass(key: string)
	local id = MonetizationConfig.GamepassIds[key]
	if not id or id == 0 then
		warn("[MonetizationController] Gamepass '" .. key .. "' has no configured id yet")
		return
	end
	MarketplaceService:PromptGamePassPurchase(player, id)
end

function MonetizationController.PromptProduct(key: string)
	local id = MonetizationConfig.DevProductIds[key]
	if not id or id == 0 then
		warn("[MonetizationController] Dev Product '" .. key .. "' has no configured id yet")
		return
	end
	MarketplaceService:PromptProductPurchase(player, id)
end

function MonetizationController.Init()
	print("[MonetizationController] Init")
end

return MonetizationController
