--!strict
-- Shop screen button wiring (§12). Purely a thin adapter: every button here
-- calls into MonetizationController's PromptGamepass/PromptProduct, which
-- are themselves thin wrappers over MarketplaceService's native purchase
-- prompts -- this Controller creates no purchase logic of its own, per the
-- explicit ask not to build a second purchase system. Opening/closing the
-- Store panel itself is handled entirely by UIAnimationController's generic
-- name-matched frame system (the HUD's "Shop" button is named "Store",
-- matching Frames.Store) -- nothing below needs to touch that.

local Players = game:GetService("Players")

local ShopController = {}

local player = Players.LocalPlayer

local function wireBuyButton(button: TextButton, kind: "Gamepass" | "Product", key: string, monetizationController: any)
	button.MouseButton1Click:Connect(function()
		if kind == "Gamepass" then
			monetizationController.PromptGamepass(key)
		else
			monetizationController.PromptProduct(key)
		end
	end)
end

function ShopController.Init()
	local playerGui = player:WaitForChild("PlayerGui") :: PlayerGui
	local screenGui = playerGui:WaitForChild("ScreenGui") :: ScreenGui
	local monetizationController = require(script.Parent.MonetizationController)

	local store = screenGui.Frames.Store.ScrollingFrame

	-- Gem Packs: 3 tiers, each its own Dev Product (not a quantity
	-- multiplier on one product, unlike the pack's original "1x/3x/10x
	-- Lucky Block" design this card was adapted from).
	local gemPacks = store.GemPacks.Frame.Buy
	wireBuyButton(gemPacks["1"], "Product", "GemPackSmall", monetizationController)
	wireBuyButton(gemPacks["2"], "Product", "GemPackMedium", monetizationController)
	wireBuyButton(gemPacks["3"], "Product", "GemPackLarge", monetizationController)

	-- Starter Pack (Dev Product).
	wireBuyButton(store.StarterPack.Frame.Choose.Buy, "Product", "StarterPack", monetizationController)

	-- Temporary boosts (Dev Products).
	wireBuyButton(store.LuckBoost.Frame.Choose.Buy, "Product", "TempLuckBoost", monetizationController)
	wireBuyButton(store.TempCash.Frame.Choose.Buy, "Product", "TempTwoXCash", monetizationController)

	-- VIP (Gamepass).
	wireBuyButton(store.VIP.Frame.Choose.Buy, "Gamepass", "VIP", monetizationController)

	-- The 4 standing Gamepasses.
	wireBuyButton(store.Gamepasses.Gamepass_TwoXCash.Frame.Choose.Buy, "Gamepass", "TwoXCash", monetizationController)
	wireBuyButton(store.Gamepasses.Gamepass_CapacityPlus.Frame.Choose.Buy, "Gamepass", "CapacityPlus", monetizationController)
	wireBuyButton(store.Gamepasses.Gamepass_AutoSellLoot.Frame.Choose.Buy, "Gamepass", "AutoSellLoot", monetizationController)
	wireBuyButton(store.Gamepasses.Gamepass_SellX2.Frame.Choose.Buy, "Gamepass", "SellX2", monetizationController)

	print("[ShopController] Init")
end

return ShopController
