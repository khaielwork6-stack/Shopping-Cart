--!strict
-- Main.server.lua equivalent (�5.2/�5.4). This is the root Script of
-- ServerScriptService.Server (Rojo's init.server.luau convention maps this
-- file to that instance, per this project's existing default.project.json --
-- the Guide's literal "ServerScriptService.Main.server.lua" path is adapted
-- to fit, since Phase 0 must not edit default.project.json).
--
-- Boots every Service in the exact documented order from �5.4. Each
-- Service's :Init() may assume everything above it in this list is already
-- initialized; nothing below it may be assumed ready.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RemotesSetup = require(ReplicatedStorage.Shared.Modules.RemotesSetup)

-- Create the Remotes folder + instances before any Service that might need
-- to bind a handler to one.
RemotesSetup.CreateAll()

local BOOT_ORDER = {
	{ Name = "PlayerDataService", Module = script.Services.PlayerDataService },
	-- Phase 11: every other Service below reads Monetization effects
	-- (GetCashMultiplier/GetLuckMultiplier/GetCapacityBonus/OwnsSellX2) via
	-- a top-level require, so this only needs to boot before them for
	-- consistency/clarity -- none of those functions actually depend on
	-- MonetizationService.Init() having run yet, only PlayerDataService.
	{ Name = "MonetizationService", Module = script.Services.MonetizationService },
	{ Name = "EconomyService", Module = script.Services.EconomyService },
	{ Name = "UpgradeService", Module = script.Services.UpgradeService },
	{ Name = "PushPowerService", Module = script.Services.PushPowerService },
	{ Name = "RebirthService", Module = script.Services.RebirthService },
	{ Name = "WorldService", Module = script.Services.WorldService },
	{ Name = "CartSpawnService", Module = script.Services.CartSpawnService },
	{ Name = "LootService", Module = script.Services.LootService },
	{ Name = "IndexService", Module = script.Services.IndexService },
	{ Name = "LeaderboardService", Module = script.Services.LeaderboardService },
}

print("[Main] Booting services...")

for _, entry in BOOT_ORDER do
	local service = require(entry.Module) :: { Init: () -> () }
	service.Init()
end

print("[Main] Boot complete. Services initialized in order: " .. table.concat((function()
	local names = {}
	for _, entry in BOOT_ORDER do
		table.insert(names, entry.Name)
	end
	return names
end)(), ", "))

-- §13 QA: fixes a real join-time race -- six Services above each push their
-- own slice of PlayerDataUpdated independently, the instant their own
-- PlayerAdded handler's WaitForLoad resolves. DataStore loads often resolve
-- before the client has finished requiring every Controller and connecting
-- its OnClientEvent listener, so those pushes fire and are gone before
-- anyone's listening -- the client was left rendering its hardcoded
-- fallback defaults (Level 1, every upgrade 0) until some *later*,
-- unrelated push happened to arrive with a fresh full slice and silently
-- "fixed" it. The client now pulls this once, synchronously, at the very
-- start of boot, before rendering anything -- a pull can't lose a race the
-- way a push can. require()s below are cheap (Luau caches per-Instance),
-- not fresh copies, since every Service above is already required by name.
local PlayerDataService = require(script.Services.PlayerDataService)
local EconomyService = require(script.Services.EconomyService)
local UpgradeService = require(script.Services.UpgradeService)
local WorldService = require(script.Services.WorldService)
local LootService = require(script.Services.LootService)
local IndexService = require(script.Services.IndexService)
local PushPowerService = require(script.Services.PushPowerService)

local remotesFolder = RemotesSetup.CreateAll()
local requestPlayerDataSnapshot = remotesFolder:FindFirstChild("RequestPlayerDataSnapshot") :: RemoteFunction
requestPlayerDataSnapshot.OnServerInvoke = function(player: Player)
	PlayerDataService.WaitForLoad(player)

	local snapshot: { [string]: any } = {}
	for _, getSnapshot in {
		EconomyService.GetSnapshot,
		UpgradeService.GetSnapshot,
		WorldService.GetSnapshot,
		LootService.GetSnapshot,
		IndexService.GetSnapshot,
		PushPowerService.GetSnapshot,
	} do
		for key, value in getSnapshot(player) do
			snapshot[key] = value
		end
	end
	snapshot.settings = PlayerDataService.Get(player).settings

	return snapshot
end
