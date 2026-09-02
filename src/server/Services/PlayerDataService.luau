--!strict
-- Load/save/cache; the ONLY Service that touches DataStore (�5.2/�6). Every
-- other Service now reads/writes its persisted fields through the single
-- table this owns (PlayerDataService.Get(player)) instead of its own
-- private in-memory table -- Phase 8's refactor, per �14's own note that
-- this phase legitimately touches a wide swath of earlier code.
--
-- Two categories of per-player state are deliberately NOT in this schema,
-- matching the Guide's own omissions rather than an oversight on this
-- project's part:
--   1. Zone-unlock frontier (PushPowerService.unlockedZoneIndex): this is a
--      pure function of already-persisted state (Push Power level +
--      Rebirth count via EffectivePushPower), and CartSpawnService's
--      existing per-frame CheckZoneUnlocks already re-derives it within
--      one frame of rejoining -- storing it too would be exactly the kind
--      of redundant-derived-value desync risk �6.1 explicitly warns against
--      for Rebirth's multipliers.
--   2. In-progress train cargo (EconomyService's train): �4.1.4 explicitly
--      states this is liquidated to Cash on disconnect ("an immediate
--      partial server-side 'auto-return' credit"), not persisted as raw
--      cargo -- see LiquidateTrainOnLeave's lazy call below.
--
-- EconomyService is required lazily: it needs this Service (every
-- persisted field it owns lives here now) and this Service needs
-- EconomyService (to liquidate train cargo before the final save) -- the
-- same mutual-dependency shape resolved the same way since Phase 3.

local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local EconomyConfig = require(ReplicatedStorage.Shared.Configs.EconomyConfig)
local LootData = require(ReplicatedStorage.Shared.Configs.LootData)
local Migrations = require(script.Parent.Parent.Migrations)
local RemotesSetup = require(ReplicatedStorage.Shared.Modules.RemotesSetup)
local RateLimiter = require(ReplicatedStorage.Shared.Modules.RateLimiter)

export type UpgradeLevels = {
	capacity: number,
	agility: number,
	mobility: number,
	range: number,
	pushPower: number,
}

export type BagEntry = {
	itemId: string,
	count: number,
	sealed: boolean,
}

export type Settings = {
	musicVolume: number,
	sfxVolume: number,
	uiScale: number,
}

export type LifetimeStats = {
	totalCashEarned: number,
	totalCartsReturned: number,
	totalRebirths: number,
	bestSingleReturn: number, -- Phase 10 (§8): drives the cash-popup "personal best" gold tint
}

export type PlayerDataSchema = {
	version: number,
	cash: number,
	gems: number,
	currentLevel: number,
	currentXP: number,
	totalLevel: number,
	rebirthCount: number,
	upgrades: UpgradeLevels,
	unlockedWorlds: { [number]: boolean },
	currentWorld: number,
	lootBag: { BagEntry },
	indexDiscovered: { [string]: boolean },
	settings: Settings,
	lifetimeStats: LifetimeStats,
	grantedPurchaseIds: { [string]: boolean }, -- Phase 11 (§6.6): every ProcessReceipt PurchaseId ever granted, so a retried receipt after a mid-grant crash can never double-grant
	lastSaved: number,
}

local PlayerDataService = {}

-- This is the first Phase this project has ever persisted data -- there is
-- no real prior schema history, so version starts at 1 (the Guide's own
-- example schema shows "version = 3" purely as sample/illustrative data,
-- not a mandate to start there).
local CURRENT_VERSION = 1

local DEFAULT_PLAYER_DATA: PlayerDataSchema = {
	version = CURRENT_VERSION,
	cash = 0,
	gems = 0,
	currentLevel = 1,
	currentXP = 0,
	totalLevel = 0,
	rebirthCount = 0,
	upgrades = { capacity = 0, agility = 0, mobility = 0, range = 0, pushPower = 0 },
	unlockedWorlds = { [1] = true },
	currentWorld = 1,
	lootBag = {},
	indexDiscovered = {},
	settings = { musicVolume = 0.5, sfxVolume = 0.8, uiScale = 1.0 },
	lifetimeStats = { totalCashEarned = 0, totalCartsReturned = 0, totalRebirths = 0, bestSingleReturn = 0 },
	grantedPurchaseIds = {},
	lastSaved = 0,
}

local playerDataStore = DataStoreService:GetDataStore("PlayerData_v1")
local corruptedBackupsStore = DataStoreService:GetDataStore("CorruptedBackups")

local playerData: { [Player]: PlayerDataSchema } = {}
local loaded: { [Player]: boolean } = {}
local autosaveThreads: { [Player]: thread } = {}

local economyServiceCache: { LiquidateTrainOnLeave: (Player) -> () }? = nil
local function getEconomyService()
	if not economyServiceCache then
		economyServiceCache = require(script.Parent.EconomyService) :: any
	end
	return economyServiceCache :: any
end

local function deepCopy<T>(value: T): T
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for k, v in value :: any do
		copy[k] = deepCopy(v)
	end
	return (copy :: any) :: T
end

-- Public API: the single shared table every other Service reads/writes
-- its persisted fields through. Returns the DEFAULT shape (never nil) even
-- before load completes, so a Service touching data during the brief
-- loading window degrades safely rather than erroring -- IsLoaded() lets a
-- caller that cares (e.g. before granting a reward) check first.
function PlayerDataService.Get(player: Player): PlayerDataSchema
	local data = playerData[player]
	if not data then
		data = deepCopy(DEFAULT_PLAYER_DATA)
		playerData[player] = data
	end
	return data
end

function PlayerDataService.IsLoaded(player: Player): boolean
	return loaded[player] == true
end

-- GetAsync yields (a real network call), but Roblox fires every connected
-- PlayerAdded handler in its own coroutine -- without this, another
-- Service's PlayerAdded handler could call Get()/push initial data before
-- loadPlayerData finishes, showing a player their own fresh save as all-
-- default values for a moment. Every other Service's PlayerAdded handler
-- calls this first instead of assuming load has already finished.
local loadedSignals: { [Player]: BindableEvent } = {}

function PlayerDataService.WaitForLoad(player: Player): PlayerDataSchema
	if not loaded[player] then
		local signal = loadedSignals[player]
		if not signal then
			signal = Instance.new("BindableEvent")
			loadedSignals[player] = signal
		end
		signal.Event:Wait()
	end
	return PlayerDataService.Get(player)
end

local function notifyLoaded(player: Player)
	loaded[player] = true
	local signal = loadedSignals[player]
	if signal then
		signal:Fire()
		signal:Destroy()
		loadedSignals[player] = nil
	end
end

-- �6.2: every field is type-checked, range-clamped, and backfilled from
-- the default template rather than causing a load failure. Sets
-- (unlockedWorlds, indexDiscovered) are stored as arrays at rest (safer
-- DataStore round-tripping than a sparse numeric-keyed table) and
-- converted back to sets here.
local function validateAndBackfill(raw: any): PlayerDataSchema
	if type(raw) ~= "table" then
		return deepCopy(DEFAULT_PLAYER_DATA)
	end

	local data = deepCopy(DEFAULT_PLAYER_DATA)

	if type(raw.version) == "number" then
		data.version = raw.version
	end
	if type(raw.cash) == "number" then
		data.cash = math.max(0, raw.cash)
	end
	if type(raw.gems) == "number" then
		data.gems = math.max(0, raw.gems)
	end
	if type(raw.currentLevel) == "number" then
		data.currentLevel = math.max(1, raw.currentLevel)
	end
	if type(raw.currentXP) == "number" then
		data.currentXP = math.max(0, raw.currentXP)
	end
	if type(raw.totalLevel) == "number" then
		data.totalLevel = math.max(0, raw.totalLevel)
	end
	if type(raw.rebirthCount) == "number" then
		data.rebirthCount = math.max(0, raw.rebirthCount)
	end
	if type(raw.currentWorld) == "number" then
		data.currentWorld = raw.currentWorld
	end
	if type(raw.lastSaved) == "number" then
		data.lastSaved = raw.lastSaved
	end

	if type(raw.upgrades) == "table" then
		for stat in data.upgrades :: any do
			local value = raw.upgrades[stat]
			if type(value) == "number" then
				(data.upgrades :: any)[stat] = math.max(0, value)
			end
		end
	end

	if type(raw.unlockedWorlds) == "table" then
		for _, worldId in raw.unlockedWorlds do
			if type(worldId) == "number" then
				data.unlockedWorlds[worldId] = true
			end
		end
	end
	data.unlockedWorlds[1] = true -- always available, per PushPowerService/WorldService's own base case

	if type(raw.lootBag) == "table" then
		local validBag = {}
		for _, entry in raw.lootBag do
			if type(entry) == "table" and type(entry.itemId) == "string" and LootData.GetItem(entry.itemId) then
				table.insert(validBag, {
					itemId = entry.itemId,
					count = math.max(1, math.floor(tonumber(entry.count) or 1)),
					sealed = entry.sealed == true,
				})
			end
		end
		data.lootBag = validBag
	end

	if type(raw.indexDiscovered) == "table" then
		local validDiscovered = {}
		for _, itemId in raw.indexDiscovered do
			if type(itemId) == "string" and LootData.GetItem(itemId) then
				validDiscovered[itemId] = true
			end
		end
		data.indexDiscovered = validDiscovered
	end

	if type(raw.grantedPurchaseIds) == "table" then
		local validGranted = {}
		for _, purchaseId in raw.grantedPurchaseIds do
			if type(purchaseId) == "string" then
				validGranted[purchaseId] = true
			end
		end
		data.grantedPurchaseIds = validGranted
	end

	if type(raw.settings) == "table" then
		if type(raw.settings.musicVolume) == "number" then
			data.settings.musicVolume = math.clamp(raw.settings.musicVolume, 0, 1)
		end
		if type(raw.settings.sfxVolume) == "number" then
			data.settings.sfxVolume = math.clamp(raw.settings.sfxVolume, 0, 1)
		end
		if type(raw.settings.uiScale) == "number" then
			data.settings.uiScale = math.clamp(raw.settings.uiScale, 0.5, 2)
		end
	end

	if type(raw.lifetimeStats) == "table" then
		for stat in data.lifetimeStats :: any do
			local value = raw.lifetimeStats[stat]
			if type(value) == "number" then
				(data.lifetimeStats :: any)[stat] = math.max(0, value)
			end
		end
	end

	return Migrations.Apply(data, data.version, CURRENT_VERSION)
end

-- Converts the live (Set-shaped) in-memory table into the Array-shaped form
-- this Service persists, without mutating the live table.
local function serializeForSave(data: PlayerDataSchema): any
	local copy = deepCopy(data)

	local worldsArray = {}
	for worldId in data.unlockedWorlds do
		table.insert(worldsArray, worldId)
	end
	copy.unlockedWorlds = worldsArray

	local discoveredArray = {}
	for itemId in data.indexDiscovered do
		table.insert(discoveredArray, itemId)
	end
	copy.indexDiscovered = discoveredArray

	local grantedArray = {}
	for purchaseId in data.grantedPurchaseIds do
		table.insert(grantedArray, purchaseId)
	end
	copy.grantedPurchaseIds = grantedArray

	copy.lastSaved = os.time()
	return copy
end

local function archiveCorrupted(player: Player, rawData: any)
	local key = player.UserId .. "_" .. os.time()
	pcall(function()
		corruptedBackupsStore:SetAsync(key, rawData)
	end)
	warn(string.format("[PlayerDataService] Archived corrupted save for %s under key %s", player.Name, key))
end

local function loadPlayerData(player: Player)
	local key = "Player_" .. player.UserId
	local ok, result = pcall(function()
		return playerDataStore:GetAsync(key)
	end)

	if not ok then
		warn(string.format("[PlayerDataService] GetAsync failed for %s: %s", player.Name, tostring(result)))
		playerData[player] = deepCopy(DEFAULT_PLAYER_DATA)
		notifyLoaded(player)
		return
	end

	if result == nil then
		-- First-ever join, or genuinely lost -- indistinguishable, both load
		-- as a fresh default with no error surfaced (�6.4).
		playerData[player] = deepCopy(DEFAULT_PLAYER_DATA)
		notifyLoaded(player)
		return
	end

	-- Catastrophic corruption: not a table at all. Archive before discarding.
	if type(result) ~= "table" then
		archiveCorrupted(player, result)
		playerData[player] = deepCopy(DEFAULT_PLAYER_DATA)
		notifyLoaded(player)
		return
	end

	local success, validated = pcall(validateAndBackfill, result)
	if not success then
		archiveCorrupted(player, result)
		playerData[player] = deepCopy(DEFAULT_PLAYER_DATA)
	else
		playerData[player] = validated
	end
	notifyLoaded(player)
end

-- �6.3: up to 3 attempts with exponential backoff (1s/4s/9s); if all fail,
-- the failure is logged and the previous successful save remains
-- authoritative (this function simply doesn't overwrite anything on
-- failure -- there is nothing else to roll back since DataStore itself
-- keeps the last successful write).
local function savePlayerData(player: Player): boolean
	local data = playerData[player]
	if not data then
		return false -- never loaded (e.g. failed instantly on join); nothing to save
	end

	local key = "Player_" .. player.UserId
	local payload = serializeForSave(data)

	for attempt = 1, EconomyConfig.Save.MaxRetryAttempts do
		local ok = pcall(function()
			playerDataStore:SetAsync(key, payload)
		end)

		if ok then
			data.lastSaved = payload.lastSaved
			return true
		end

		local backoffSeconds = EconomyConfig.Save.RetryBackoffSeconds[attempt]
		if backoffSeconds then
			task.wait(backoffSeconds)
		end
	end

	warn(string.format("[PlayerDataService] Save failed for %s after %d attempts", player.Name, EconomyConfig.Save.MaxRetryAttempts))
	return false
end

function PlayerDataService.RequestImmediateSave(player: Player)
	task.spawn(savePlayerData, player)
end

local function startAutosaveLoop(player: Player)
	local thread = task.spawn(function()
		while true do
			task.wait(EconomyConfig.Save.AutosaveIntervalSeconds)
			if not player.Parent then
				return
			end
			savePlayerData(player)
		end
	end)
	autosaveThreads[player] = thread
end

local function onPlayerRemoving(player: Player)
	RateLimiter.ClearPlayer(player)

	local thread = autosaveThreads[player]
	if thread then
		task.cancel(thread)
		autosaveThreads[player] = nil
	end

	-- �4.1.4: uncollected train cargo is liquidated to Cash, never persisted
	-- as raw cargo -- must happen before the final save captures Cash.
	getEconomyService().LiquidateTrainOnLeave(player)

	savePlayerData(player)

	playerData[player] = nil
	loaded[player] = nil

	local signal = loadedSignals[player]
	if signal then
		signal:Destroy()
		loadedSignals[player] = nil
	end
end

function PlayerDataService.Init()
	Players.PlayerAdded:Connect(function(player: Player)
		loadPlayerData(player)
		startAutosaveLoop(player)
	end)

	Players.PlayerRemoving:Connect(onPlayerRemoving)

	local remotesFolder = RemotesSetup.CreateAll()
	local requestUpdateSettings = remotesFolder:FindFirstChild("RequestUpdateSettings") :: RemoteFunction
	requestUpdateSettings.OnServerInvoke = function(player: Player, musicVolume: number?, sfxVolume: number?)
		if not RateLimiter.Allow(player, "RequestUpdateSettings", 10) then
			return { success = false, reason = "RateLimited" }
		end

		local data = PlayerDataService.Get(player)
		if type(musicVolume) == "number" then
			data.settings.musicVolume = math.clamp(musicVolume, 0, 1)
		end
		if type(sfxVolume) == "number" then
			data.settings.sfxVolume = math.clamp(sfxVolume, 0, 1)
		end
		return { success = true }
	end

	game:BindToClose(function()
		-- Final blocking pass: every currently-connected player gets the
		-- same liquidate+save sequence as a normal leave, sequentially
		-- (Roblox budgets a limited window here; a full server rarely has
		-- enough concurrently-saving players for this to matter before
		-- Phase 12's real scale testing).
		for _, player in Players:GetPlayers() do
			onPlayerRemoving(player)
		end
	end)

	print("[PlayerDataService] Init")
end

return PlayerDataService
