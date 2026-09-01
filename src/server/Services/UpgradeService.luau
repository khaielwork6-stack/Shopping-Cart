--!strict
-- Tracks the five purchasable stat levels and exposes cost/effect via
-- EconomyMath (�5.2/�3.7). Currency mutation itself stays owned by
-- EconomyService (�5.2's stated responsibility split) -- this Service only
-- owns levels and the immediate side effect a level has on the character
-- (Mobility's WalkSpeed).
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

local economyServiceCache: { TrySpendCash: (Player, number) -> boolean, GetCash: (Player) -> number }? = nil
local function getEconomyService()
	if not economyServiceCache then
		economyServiceCache = require(script.Parent.EconomyService) :: any
	end
	return economyServiceCache :: any
end

type UpgradeStatName = EconomyConfig.UpgradeStatName

export type UpgradeLevels = {
	capacity: number,
	agility: number,
	mobility: number,
	range: number,
	pushPower: number,
}

local UpgradeService = {}

local STAT_NAMES: { UpgradeStatName } = { "capacity", "agility", "mobility", "range", "pushPower" }
local MAX_PURCHASE_QUANTITY = 999 -- sane upper bound; "Buy Max Affordable" UI lands in Phase 9

local playerUpgrades: { [Player]: UpgradeLevels } = {}
local remotesFolder: Folder

local function getLevels(player: Player): UpgradeLevels
	local levels = playerUpgrades[player]
	if not levels then
		levels = { capacity = 0, agility = 0, mobility = 0, range = 0, pushPower = 0 }
		playerUpgrades[player] = levels
	end
	return levels
end

function UpgradeService.GetLevel(player: Player, stat: UpgradeStatName): number
	return getLevels(player)[stat]
end

function UpgradeService.GetCapacity(player: Player): number
	return EconomyMath.GetTrainCapacity(getLevels(player).capacity)
end

local function applyMobilityEffect(player: Player)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.WalkSpeed = EconomyMath.GetMobilityWalkSpeed(getLevels(player).mobility)
	end
end

local function pushUpgradeData(player: Player)
	local playerDataUpdated = remotesFolder:FindFirstChild("PlayerDataUpdated") :: RemoteEvent
	playerDataUpdated:FireClient(player, { upgrades = table.clone(getLevels(player)) })
end

local function handleRequestPurchaseUpgrade(player: Player, statName: string, quantity: number?)
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
		if stat == "mobility" then
			applyMobilityEffect(player)
		end
		pushUpgradeData(player)
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
		getLevels(player)
		pushUpgradeData(player)
		player.CharacterAdded:Connect(function()
			applyMobilityEffect(player)
		end)
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		playerUpgrades[player] = nil
	end)

	print("[UpgradeService] Init")
end

return UpgradeService
