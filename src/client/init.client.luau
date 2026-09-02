--!strict
-- Client boot script (Rojo's init.client.luau convention maps this file to
-- StarterPlayer.StarterPlayerScripts.Client, per this project's existing
-- default.project.json). Mirrors Main.server.lua's boot pattern, one
-- Controller per relevant Service (�5.2).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RemotesSetup = require(ReplicatedStorage.Shared.Modules.RemotesSetup)

-- Wait for the server to have created the Remotes folder/instances.
RemotesSetup.WaitForAll()

local BOOT_ORDER = {
	{ Name = "UIAnimationController", Module = script.Controllers.UIAnimationController },
	{ Name = "UIController", Module = script.Controllers.UIController },
	{ Name = "WorldController", Module = script.Controllers.WorldController },
	{ Name = "InputController", Module = script.Controllers.InputController },
	{ Name = "TrainController", Module = script.Controllers.TrainController },
	{ Name = "ResistanceVFXController", Module = script.Controllers.ResistanceVFXController },
	{ Name = "LootController", Module = script.Controllers.LootController },
	{ Name = "IndexController", Module = script.Controllers.IndexController },
}

print("[Client Main] Booting controllers...")

for _, entry in BOOT_ORDER do
	local controller = require(entry.Module) :: { Init: () -> () }
	controller.Init()
end

print("[Client Main] Boot complete.")
