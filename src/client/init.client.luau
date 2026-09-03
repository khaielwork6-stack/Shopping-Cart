--!strict
-- Client boot script (Rojo's init.client.luau convention maps this file to
-- StarterPlayer.StarterPlayerScripts.Client, per this project's existing
-- default.project.json). Mirrors Main.server.lua's boot pattern, one
-- Controller per relevant Service (�5.2).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RemotesSetup = require(ReplicatedStorage.Shared.Modules.RemotesSetup)

-- Wait for the server to have created the Remotes folder/instances.
local remotes = RemotesSetup.WaitForAll()

-- §13 QA: fixes a real join-time race. Several Services each independently
-- push their own slice of PlayerDataUpdated the instant the server finishes
-- loading this player's save -- often before this very script has finished
-- requiring every Controller below and connecting its own OnClientEvent
-- listener, since DataStore loads routinely resolve faster than that. Those
-- pushes fire and are gone; a listener that connects late never sees them.
-- The symptom was exactly what QA reported: Level 1 and every upgrade at 0
-- on first join, "fixing itself" the instant any *later* push happened to
-- arrive (a purchase, a cart claim) with a fresh full slice.
--
-- Pulling this once, synchronously, before any Controller runs can't lose
-- that race the way a push can -- see server/init.server.luau's matching
-- comment on the aggregator this calls into.
local initialSnapshot = (remotes.RequestPlayerDataSnapshot :: RemoteFunction):InvokeServer()

local BOOT_ORDER = {
	{ Name = "SoundController", Module = script.Controllers.SoundController },
	{ Name = "UIAnimationController", Module = script.Controllers.UIAnimationController },
	{ Name = "UIController", Module = script.Controllers.UIController },
	{ Name = "WorldController", Module = script.Controllers.WorldController },
	{ Name = "InputController", Module = script.Controllers.InputController },
	{ Name = "TrainController", Module = script.Controllers.TrainController },
	{ Name = "LostCartRevealController", Module = script.Controllers.LostCartRevealController },
	{ Name = "ResistanceVFXController", Module = script.Controllers.ResistanceVFXController },
	{ Name = "LootController", Module = script.Controllers.LootController },
	{ Name = "IndexController", Module = script.Controllers.IndexController },
	{ Name = "MonetizationController", Module = script.Controllers.MonetizationController },
	{ Name = "ShopController", Module = script.Controllers.ShopController },
}

print("[Client Main] Booting controllers...")

for _, entry in BOOT_ORDER do
	local controller = require(entry.Module) :: { Init: (any) -> () }
	controller.Init(initialSnapshot)
end

print("[Client Main] Boot complete.")
