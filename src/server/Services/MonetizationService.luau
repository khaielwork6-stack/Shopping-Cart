--!strict
-- Gamepass ownership + Dev Product receipts (§5.2/§12). Every effect below
-- flows through the same EconomyMath/Service call sites every other system
-- already uses (§12's explicit design constraint) -- this Service never
-- mutates Cash/Gems/levels itself except inside handleProcessReceipt, and
-- even there it goes through PlayerDataService's own table + the same
-- UpgradeService level-increment shape a real purchase uses, not a
-- special-cased direct write.
--
-- Requires only PlayerDataService (a leaf) at the top level, and is itself
-- a leaf every other Service can safely require at the top level -- no
-- Service in this project needs MonetizationService to know about it back.

local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local EconomyConfig = require(ReplicatedStorage.Shared.Configs.EconomyConfig)
local PlayerDataService = require(script.Parent.PlayerDataService)

local MonetizationService = {}

local MonetizationConfig = EconomyConfig.Monetization
local GAMEPASS_IDS = MonetizationConfig.GamepassIds
local DEV_PRODUCT_IDS = MonetizationConfig.DevProductIds

-- Per-player ownership cache: UserOwnsGamePassAsync is a real API call, and
-- ownership can never change mid-session for a gamepass (unlike a temp
-- boost), so checking once per player per gamepass is enough.
local ownedGamepassCache: { [Player]: { [string]: boolean } } = {}

-- Per-player, per-boost-key expiry timestamps (os.clock()-based, in-memory
-- only -- a temp boost intentionally does not survive a rejoin, matching
-- how every other temporary, non-persisted piece of session state in this
-- project behaves).
local tempBoostExpiry: { [Player]: { [string]: number } } = {}

local function ownsGamepass(player: Player, key: string): boolean
	local id = GAMEPASS_IDS[key]
	if not id or id == 0 then
		return false -- not configured on the Creator Dashboard yet -- inert, not an error
	end

	local cache = ownedGamepassCache[player]
	if cache and cache[key] ~= nil then
		return cache[key]
	end

	local ok, owns = pcall(function()
		return MarketplaceService:UserOwnsGamePassAsync(player.UserId, id)
	end)
	local result = ok and owns == true

	cache = ownedGamepassCache[player] or {}
	cache[key] = result
	ownedGamepassCache[player] = cache

	return result
end

local function hasTempBoost(player: Player, key: string): boolean
	local expiries = tempBoostExpiry[player]
	local expiry = expiries and expiries[key]
	return expiry ~= nil and expiry > os.clock()
end

function MonetizationService.GrantTempBoost(player: Player, key: string, durationSeconds: number)
	local expiries = tempBoostExpiry[player] or {}
	expiries[key] = os.clock() + durationSeconds
	tempBoostExpiry[player] = expiries
end

-- §12.2: the 2x Cash gamepass and its temp Dev Product equivalent stack
-- multiplicatively with each other and with VIP's own small bonus -- all
-- three only ever benefit a paying player further, never interact badly.
function MonetizationService.GetCashMultiplier(player: Player): number
	local multiplier = 1
	if ownsGamepass(player, "TwoXCash") then
		multiplier *= MonetizationConfig.TwoXCashMultiplier
	end
	if hasTempBoost(player, "TempTwoXCash") then
		multiplier *= MonetizationConfig.TwoXCashMultiplier
	end
	if ownsGamepass(player, "VIP") then
		multiplier *= 1 + MonetizationConfig.VIPCashBonus
	end
	return multiplier
end

-- §3.8/§12.2: feeds into the same single Luck value EconomyMath.LuckReallocate
-- already reallocates safely -- bounded by construction regardless of how
-- many sources multiply into it here.
function MonetizationService.GetLuckMultiplier(player: Player): number
	local multiplier = 1
	if ownsGamepass(player, "LuckBoost") then
		multiplier *= MonetizationConfig.LuckBoostMultiplier
	end
	if hasTempBoost(player, "TempLuckBoost") then
		multiplier *= MonetizationConfig.LuckBoostMultiplier
	end
	return multiplier
end

function MonetizationService.GetCapacityBonus(player: Player): number
	return ownsGamepass(player, "CapacityPlus") and MonetizationConfig.CapacityPlusBonus or 0
end

function MonetizationService.OwnsSellX2(player: Player): boolean
	return ownsGamepass(player, "SellX2")
end

function MonetizationService.OwnsAutoSellLoot(player: Player): boolean
	return ownsGamepass(player, "AutoSellLoot")
end

-- §12.2 Starter Pack: routes through the same PlayerDataService table and
-- UpgradeLevels shape a real purchase/upgrade would touch -- never a
-- special-cased direct write path (§6.6, §11 ProcessReceipt idempotency).
local function grantStarterPack(player: Player)
	local data = PlayerDataService.Get(player)
	local pack = MonetizationConfig.StarterPack
	data.cash += pack.Cash
	data.gems += pack.Gems
	data.upgrades.capacity += pack.CapacityLevels
	data.upgrades.agility += pack.AgilityLevels
end

-- §6.6/§11: ProcessReceipt must be idempotent -- a receipt can be retried
-- by Roblox after a successful grant if the server never returned
-- PurchaseGranted (e.g. a crash between granting and returning). Every
-- already-seen PurchaseId is recorded in the player's own persisted data
-- (§6.1-style additive field) so a retry after a crash re-checks against a
-- durable record, not just this server's in-memory state.
local function handleProcessReceipt(receiptInfo: any): Enum.ProductPurchaseDecision
	local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
	if not player then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local data = PlayerDataService.Get(player)
	if data.grantedPurchaseIds[receiptInfo.PurchaseId] then
		return Enum.ProductPurchaseDecision.PurchaseGranted -- already granted, safe to no-op
	end

	local productId = receiptInfo.ProductId
	local granted = false

	if productId == DEV_PRODUCT_IDS.TempTwoXCash and productId ~= 0 then
		MonetizationService.GrantTempBoost(player, "TempTwoXCash", MonetizationConfig.TempBoostDurationSeconds)
		granted = true
	elseif productId == DEV_PRODUCT_IDS.TempLuckBoost and productId ~= 0 then
		MonetizationService.GrantTempBoost(player, "TempLuckBoost", MonetizationConfig.TempBoostDurationSeconds)
		granted = true
	elseif productId == DEV_PRODUCT_IDS.GemPackSmall and productId ~= 0 then
		data.gems += MonetizationConfig.GemPackAmounts.Small
		granted = true
	elseif productId == DEV_PRODUCT_IDS.GemPackMedium and productId ~= 0 then
		data.gems += MonetizationConfig.GemPackAmounts.Medium
		granted = true
	elseif productId == DEV_PRODUCT_IDS.GemPackLarge and productId ~= 0 then
		data.gems += MonetizationConfig.GemPackAmounts.Large
		granted = true
	elseif productId == DEV_PRODUCT_IDS.StarterPack and productId ~= 0 then
		grantStarterPack(player)
		granted = true
	end

	if not granted then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	data.grantedPurchaseIds[receiptInfo.PurchaseId] = true
	PlayerDataService.RequestImmediateSave(player)

	return Enum.ProductPurchaseDecision.PurchaseGranted
end

-- §12.2/§12.5 Auto-Sell Loot: the one sanctioned automation-adjacent
-- gamepass. Sells through the exact same internal sell logic a manual Sell
-- All does (LootService.SellAll, required lazily to avoid a boot cycle
-- since LootService already requires EconomyService, which would require
-- this Service, which would require LootService back) -- never a
-- duplicate/parallel Cash-granting path.
local lootServiceCache: { SellAll: (Player) -> () }? = nil
local function getLootService()
	if not lootServiceCache then
		lootServiceCache = require(script.Parent.LootService) :: any
	end
	return lootServiceCache :: any
end

local function autoSellLoop()
	while true do
		task.wait(MonetizationConfig.AutoSellIntervalSeconds)
		for _, player in Players:GetPlayers() do
			if MonetizationService.OwnsAutoSellLoot(player) then
				getLootService().SellAll(player)
			end
		end
	end
end

function MonetizationService.Init()
	MarketplaceService.ProcessReceipt = handleProcessReceipt

	Players.PlayerRemoving:Connect(function(player: Player)
		ownedGamepassCache[player] = nil
		tempBoostExpiry[player] = nil
	end)

	task.spawn(autoSellLoop)

	print("[MonetizationService] Init")
end

return MonetizationService
