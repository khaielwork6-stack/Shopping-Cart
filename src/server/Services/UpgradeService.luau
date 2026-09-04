--!strict
-- Tracks the five purchasable stat levels and exposes cost/effect via
-- EconomyMath (�5.2/�3.7). Currency mutation itself stays owned by
-- EconomyService (�5.2's stated responsibility split) -- this Service only
-- owns the immediate side effect a level has on the character (Mobility's
-- WalkSpeed).
--
-- Phase 8: levels now live in PlayerDataService's persisted table
-- (PlayerDataService is a pure leaf that boots before this Service, so
-- requiring it at the top level is always safe).
--
-- EconomyService is required lazily (on first use, not at module top level)
-- because Phase 3 introduced a genuine mutual dependency: EconomyService's
-- return-trip resistance needs PushPowerService, which needs this Service's
-- levels, which needs EconomyService's currency -- a real 3-way cycle. A
-- top-level require on any one edge deadlocks Luau's require() at boot;
-- deferring this one edge breaks the cycle since, by the time a purchase
-- actually happens, every Service has already finished loading.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local EconomyConfig = require(ReplicatedStorage.Shared.Configs.EconomyConfig)
local EconomyMath = require(ReplicatedStorage.Shared.Modules.EconomyMath)
local RemotesSetup = require(ReplicatedStorage.Shared.Modules.RemotesSetup)
local RateLimiter = require(ReplicatedStorage.Shared.Modules.RateLimiter)
local PlayerDataService = require(script.Parent.PlayerDataService)
local MonetizationService = require(script.Parent.MonetizationService)

local economyServiceCache: {
	TrySpendCash: (Player, number) -> boolean,
	GetCash: (Player) -> number,
	GetTrainLoad: (Player) -> number,
}? = nil
local function getEconomyService()
	if not economyServiceCache then
		economyServiceCache = require(script.Parent.EconomyService) :: any
	end
	return economyServiceCache :: any
end

type UpgradeStatName = EconomyConfig.UpgradeStatName

local UpgradeService = {}

local STAT_NAMES: { UpgradeStatName } = { "capacity", "mobility", "range", "pushPower" }
local MAX_PURCHASE_QUANTITY = 999 -- sane upper bound; "Buy Max Affordable" UI lands in Phase 9

local remotesFolder: Folder

local function getLevels(player: Player): PlayerDataService.UpgradeLevels
	return PlayerDataService.Get(player).upgrades
end

function UpgradeService.GetLevel(player: Player, stat: UpgradeStatName): number
	return getLevels(player)[stat]
end

-- §12.2 Capacity+ gamepass: a flat bonus on top of purchased levels, not a
-- multiplier -- comparable in effect to being several Capacity levels
-- ahead, per the Guide's own description.
function UpgradeService.GetCapacity(player: Player): number
	return EconomyMath.GetTrainCapacity(getLevels(player).capacity) + MonetizationService.GetCapacityBonus(player)
end

-- §13 QA: RequestPlayerDataSnapshot's source for this Service's slice.
-- Lost Cart GDD v3 �6.1: trainCapacity/trainSpeedFactor are pushed here too
-- (not just raw upgrade levels) so the client HUD never has to duplicate the
-- capacity-bonus or speed-curve math -- the server stays the one source of
-- truth for both.
function UpgradeService.GetSnapshot(player: Player): { [string]: any }
	local levels = getLevels(player)
	local load = getEconomyService().GetTrainLoad(player)
	local pullPowerKg = EconomyMath.GetPullPowerKg(levels.pushPower)
	return {
		upgrades = table.clone(levels),
		trainCapacity = UpgradeService.GetCapacity(player),
		trainSpeedFactor = EconomyMath.GetTrainSpeedFactor(load, pullPowerKg),
	}
end

local function pushUpgradeData(player: Player)
	local playerDataUpdated = remotesFolder:FindFirstChild("PlayerDataUpdated") :: RemoteEvent
	playerDataUpdated:FireClient(player, UpgradeService.GetSnapshot(player))
end

-- Lost Cart GDD v3 �6.1: WalkSpeed is Mobility's base speed scaled by the
-- real Load-vs-PullPower train speed curve -- the one place Humanoid.WalkSpeed
-- ever gets set, so anything that changes either input (a Mobility/Push
-- Power purchase, or the train's Load changing via a claim/return/dump) must
-- call this to recompute it. Exported so EconomyService (which owns Load)
-- can trigger a recompute without duplicating the formula. Also re-pushes
-- the snapshot so the client HUD's capacity/speed bars stay live.
function UpgradeService.RefreshWalkSpeed(player: Player)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		local levels = getLevels(player)
		local baseSpeed = EconomyMath.GetMobilityWalkSpeed(levels.mobility)
		local load = getEconomyService().GetTrainLoad(player)
		local pullPowerKg = EconomyMath.GetPullPowerKg(levels.pushPower)
		humanoid.WalkSpeed = baseSpeed * EconomyMath.GetTrainSpeedFactor(load, pullPowerKg)
	end
	pushUpgradeData(player)
end

-- Public API consumed by RebirthService (�4.4: "Push Power level -- back to
-- base"). Capacity/Mobility/Range are explicitly never touched here -- �4.4's
-- persistent list -- Rebirth must never call this for anything but pushPower.
function UpgradeService.ResetPushPower(player: Player)
	local levels = getLevels(player)
	levels.pushPower = 0
	UpgradeService.RefreshWalkSpeed(player) -- Lost Cart GDD v3 �6.1: PullPower just reset, re-derive WalkSpeed + re-push
end

local function handleRequestPurchaseUpgrade(player: Player, statName: string, quantity: number?)
	if not RateLimiter.Allow(player, "RequestPurchaseUpgrade", 20) then
		return { success = false, reason = "RateLimited" }
	end

	if not table.find(STAT_NAMES, statName) then
		return { success = false, reason = "InvalidStat" }
	end
	local stat = statName :: UpgradeStatName

	local requestedQuantity = math.clamp(math.floor(quantity or 1), 1, MAX_PURCHASE_QUANTITY)
	local levels = getLevels(player)
	local economyService = getEconomyService()

	local purchased = 0
	for _ = 1, requestedQuantity do
		local cost = EconomyMath.GetUpgradeCost(stat, levels[stat])
		if not economyService.TrySpendCash(player, cost) then
			break
		end
		levels[stat] += 1
		purchased += 1
	end

	if purchased > 0 then
		-- Always refresh, not just for mobility/pushPower -- it also re-pushes
		-- the snapshot (trainCapacity changes on a Capacity purchase too), and
		-- recomputing WalkSpeed for an unrelated stat is harmless (same value).
		UpgradeService.RefreshWalkSpeed(player)
	end

	return {
		success = purchased > 0,
		levelsPurchased = purchased,
		newLevel = levels[stat],
	}
end

function UpgradeService.Init()
	remotesFolder = RemotesSetup.CreateAll()

	local requestPurchaseUpgrade = remotesFolder:FindFirstChild("RequestPurchaseUpgrade") :: RemoteFunction
	requestPurchaseUpgrade.OnServerInvoke = function(player: Player, statName: string, quantity: number?)
		return handleRequestPurchaseUpgrade(player, statName, quantity)
	end

	Players.PlayerAdded:Connect(function(player: Player)
		PlayerDataService.WaitForLoad(player) -- see PlayerDataService's own comment on why this matters
		pushUpgradeData(player)

		-- §13 QA: real bug -- Roblox often spawns the character before this
		-- async WaitForLoad resolves, so a CharacterAdded connected only
		-- here would silently miss that very first spawn's event entirely.
		-- WalkSpeed stayed at Roblox's default (16) regardless of Mobility
		-- level until some *later* purchase happened to re-apply it. Handle
		-- the character that may already exist, in addition to (not instead
		-- of) every future spawn.
		if player.Character then
			UpgradeService.RefreshWalkSpeed(player)
		end
		player.CharacterAdded:Connect(function()
			UpgradeService.RefreshWalkSpeed(player)
		end)
	end)

	print("[UpgradeService] Init")
end

return UpgradeService
