--!strict
-- Loot rolls, the Bag, sealed containers (�5.2/�4.5). Fully independent of
-- the Cash rarity roll (Phase 2) -- same reallocation formula, separate
-- roll, separate outcome.
--
-- Phase 7: Luck now comes from IndexService (this project's chosen source,
-- see EconomyConfig.Index's comment) instead of a fixed x1, and a genuine
-- Loot find records a first-discovery with IndexService (�4.6).
--
-- EconomyService is required lazily: EconomyService needs this Service (to
-- roll Loot at the moment of a cart return) and this Service needs
-- EconomyService (Sell All grants Cash) -- the same mutual-dependency shape
-- as every other cross-Service edge since Phase 3, resolved the same way.
-- IndexService and PlayerDataService are leaves (nothing requires them
-- back), so they're safe top-level requires.
--
-- Phase 8: the Bag now lives in PlayerDataService's persisted table.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local EconomyConfig = require(ReplicatedStorage.Shared.Configs.EconomyConfig)
local WorldData = require(ReplicatedStorage.Shared.Configs.WorldData)
local LootData = require(ReplicatedStorage.Shared.Configs.LootData)
local EconomyMath = require(ReplicatedStorage.Shared.Modules.EconomyMath)
local RemotesSetup = require(ReplicatedStorage.Shared.Modules.RemotesSetup)
local RateLimiter = require(ReplicatedStorage.Shared.Modules.RateLimiter)
local PlayerDataService = require(script.Parent.PlayerDataService)
local WorldService = require(script.Parent.WorldService)
local IndexService = require(script.Parent.IndexService)

export type BagEntry = PlayerDataService.BagEntry

local LootService = {}

local remotesFolder: Folder

local economyServiceCache: { AddCash: (Player, number) -> (), GetLevelState: (Player) -> { rebirthCount: number } }? = nil
local function getEconomyService()
	if not economyServiceCache then
		economyServiceCache = require(script.Parent.EconomyService) :: any
	end
	return economyServiceCache :: any
end

-- Lazy: MonetizationService's Auto-Sell Loot loop already requires
-- LootService (to call SellAll), so a top-level require here would deadlock
-- Luau's require() at boot -- deferring this one edge breaks the cycle.
local monetizationServiceCache: { OwnsSellX2: (Player) -> boolean }? = nil
local function getMonetizationService()
	if not monetizationServiceCache then
		monetizationServiceCache = require(script.Parent.MonetizationService) :: any
	end
	return monetizationServiceCache :: any
end

local function getBag(player: Player): { BagEntry }
	return PlayerDataService.Get(player).lootBag
end

-- §13 QA: RequestPlayerDataSnapshot's source for this Service's slice.
function LootService.GetSnapshot(player: Player): { [string]: any }
	return { lootBag = getBag(player) }
end

local function pushBagData(player: Player)
	local playerDataUpdated = remotesFolder:FindFirstChild("PlayerDataUpdated") :: RemoteEvent
	playerDataUpdated:FireClient(player, LootService.GetSnapshot(player))
end

-- �4.5: Bag entries stack identical items -- a slot is a unique
-- (itemId, sealed) pair, not one slot per copy. If the Bag is full when a
-- roll hits, the roll is silently discarded (no negative popup, by design).
local function addToBag(player: Player, itemId: string, sealed: boolean, count: number): boolean
	local bag = getBag(player)

	for _, entry in bag do
		if entry.itemId == itemId and entry.sealed == sealed then
			entry.count += count
			pushBagData(player)
			return true
		end
	end

	if #bag >= EconomyConfig.Loot.BagCapacity then
		return false
	end

	table.insert(bag, { itemId = itemId, count = count, sealed = sealed })
	pushBagData(player)
	return true
end

-- Phase 4 �9: public API consumed by BaseService, so placing/removing a
-- Base item goes through this Service's single bag-mutation path (�6.6)
-- rather than BaseService reaching into `lootBag` directly.
function LootService.ReturnItemToBag(player: Player, itemId: string): boolean
	return addToBag(player, itemId, false, 1)
end

-- Only ever removes an UNSEALED copy -- a sealed item must be Opened first,
-- same rule as selling one.
function LootService.TakeItemFromBag(player: Player, itemId: string): boolean
	local bag = getBag(player)
	for i, entry in bag do
		if entry.itemId == itemId and not entry.sealed and entry.count > 0 then
			entry.count -= 1
			if entry.count <= 0 then
				table.remove(bag, i)
			end
			pushBagData(player)
			return true
		end
	end
	return false
end

local function rollDropOnly(luck: number): boolean
	local dropChance = EconomyMath.GetLootDropChance(luck)
	return math.random() < dropChance
end

-- �4.5: per-cart Loot roll, independent of the Cash rarity roll. Called by
-- EconomyService once per returned cart, at the moment of return.
function LootService.RollForCart(player: Player)
	-- Lost Cart migration Phase 2: Rebirth now also grows Luck (rebirth's own
	-- "changing rebirth completely" ask), folded in the same way the
	-- Monetization Luck gamepass already is.
	local rebirthCount = getEconomyService().GetLevelState(player).rebirthCount
	local luck = IndexService.GetLuck(player)
		* getMonetizationService().GetLuckMultiplier(player)
		* EconomyMath.GetRebirthLuckMultiplier(rebirthCount)

	if not rollDropOnly(luck) then
		return
	end

	local rarityWeights = EconomyMath.LuckReallocate(luck)
	local rarity = EconomyMath.RollRarity(rarityWeights)
	local candidates = LootData.GetItemsByRarity(rarity)
	if #candidates == 0 then
		return -- no items registered for this rarity yet (fine, per Phase 6's own note)
	end

	local item = candidates[math.random(1, #candidates)]
	local sealedChance = item.SealedChanceOverride or EconomyConfig.Loot.SealedChance
	local sealed = math.random() < sealedChance

	addToBag(player, item.Id, sealed, 1)
	IndexService.RecordDiscovery(player, item.Id) -- �4.6: first-time-only; duplicates are no-ops
end

-- Server-side "is the player at a Sell Loot NPC" check -- never trusts a
-- client-reported position (�5.6). NPCs are placed near each World's Corral.
local function isPlayerAtSellNPC(player: Player): boolean
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return false
	end

	local worldId = WorldService.GetCurrentWorld(player)
	local worldEntry = WorldData.GetWorld(worldId)
	local worldFolder = worldEntry and Workspace:FindFirstChild("Worlds") and Workspace.Worlds:FindFirstChild(worldEntry.FolderName)
	local npc = worldFolder and worldFolder:FindFirstChild("PH_NPC_LootSeller")
	local npcRoot = npc and (npc:FindFirstChild("HumanoidRootPart") or npc.PrimaryPart) :: BasePart?
	if not npcRoot then
		return false
	end

	return (root.Position - npcRoot.Position).Magnitude <= 10
end

-- Core sell logic, shared by the manual (NPC-gated) RemoteFunction path and
-- Auto-Sell Loot's periodic loop (which deliberately bypasses the NPC
-- check -- §12.2's whole point is not needing to walk there). Both paths
-- mutate Cash through this single function, never a duplicate path (§6.6).
local function sellBag(player: Player, useX2: boolean?): { success: boolean, reason: string?, cashEarned: number? }
	local bag = getBag(player)
	local total = 0
	local remaining: { BagEntry } = {}

	for _, entry in bag do
		if entry.sealed then
			table.insert(remaining, entry) -- must be Opened before it can be sold
		else
			local item = LootData.GetItem(entry.itemId)
			if item then
				total += item.SellValue * entry.count
			end
		end
	end

	if total <= 0 then
		return { success = false, reason = "NothingToSell" }
	end

	-- §12.2/§12.3 Sell x2 gamepass.
	if useX2 and getMonetizationService().OwnsSellX2(player) then
		total *= 2
	end

	PlayerDataService.Get(player).lootBag = remaining
	pushBagData(player)
	getEconomyService().AddCash(player, total)

	return { success = true, cashEarned = total }
end

local function handleRequestSellLoot(player: Player, useX2: boolean?)
	if not RateLimiter.Allow(player, "RequestSellLoot", 10) then
		return { success = false, reason = "RateLimited" }
	end

	if not isPlayerAtSellNPC(player) then
		return { success = false, reason = "NotAtNPC" }
	end
	return sellBag(player, useX2)
end

-- Public API consumed by MonetizationService's Auto-Sell Loot loop.
function LootService.SellAll(player: Player)
	sellBag(player, false)
end

local function handleRequestOpenSealedItem(player: Player, itemId: string)
	if not RateLimiter.Allow(player, "RequestOpenSealedItem", 20) then
		return { success = false, reason = "RateLimited" }
	end

	local bag = getBag(player)

	for i, entry in bag do
		if entry.itemId == itemId and entry.sealed then
			table.remove(bag, i)
			addToBag(player, itemId, false, entry.count)
			return { success = true }
		end
	end

	return { success = false, reason = "ItemNotFound" }
end

function LootService.Init()
	remotesFolder = RemotesSetup.CreateAll()

	local requestSellLoot = remotesFolder:FindFirstChild("RequestSellLoot") :: RemoteFunction
	requestSellLoot.OnServerInvoke = function(player: Player, useX2: boolean?)
		return handleRequestSellLoot(player, useX2)
	end

	local requestOpenSealedItem = remotesFolder:FindFirstChild("RequestOpenSealedItem") :: RemoteFunction
	requestOpenSealedItem.OnServerInvoke = function(player: Player, itemId: string)
		return handleRequestOpenSealedItem(player, itemId)
	end

	Players.PlayerAdded:Connect(function(player: Player)
		PlayerDataService.WaitForLoad(player) -- see PlayerDataService's own comment on why this matters
		pushBagData(player)
	end)

	-- Command-Bar-only test hook (same rationale/pattern as EconomyService's
	-- DebugGrantXP): statistically validating an 8% drop rate over 200+
	-- samples via real gameplay would mean 200+ real cart returns. A
	-- BindableFunction, never a Remote -- not reachable by any client.
	local debugRollStats = Instance.new("BindableFunction")
	debugRollStats.Name = "DebugRollStats"
	debugRollStats.Parent = script
	debugRollStats.OnInvoke = function(iterations: number, luck: number?)
		local hits = 0
		for _ = 1, iterations do
			if rollDropOnly(luck or 1) then
				hits += 1
			end
		end
		return hits
	end

	-- Same rationale: populating a real Bag via the 8% drop rate would need
	-- hundreds of real cart returns to reliably exercise Sell/Open/full-Bag
	-- paths. Actually rolls (and can hit the Bag), unlike DebugRollStats.
	local debugRollForCart = Instance.new("BindableFunction")
	debugRollForCart.Name = "DebugRollForCart"
	debugRollForCart.Parent = script
	debugRollForCart.OnInvoke = function(player: Player, iterations: number)
		for _ = 1, iterations do
			LootService.RollForCart(player)
		end
	end

	print("[LootService] Init")
end

return LootService
