--!strict
-- Single source of truth for the Remotes list (�5.2). Server calls CreateAll()
-- once at boot, before any Service that needs a handler; client calls
-- WaitForAll() to get the same instances once replicated. No Phase after 0
-- should create a Remote instance anywhere except here.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

export type RemoteKind = "RemoteEvent" | "RemoteFunction"

local REMOTES: { [string]: RemoteKind } = {
	-- client -> server, RemoteFunction (verb-named per �5.7)
	RequestReturnCarts = "RemoteFunction",
	RequestPurchaseUpgrade = "RemoteFunction",
	RequestRebirth = "RemoteFunction",
	RequestSellLoot = "RemoteFunction",
	RequestOpenSealedItem = "RemoteFunction",
	RequestEnterWorldPortal = "RemoteFunction",
	RequestUpdateSettings = "RemoteFunction",

	-- server -> client, RemoteEvent (past-tense-noun-named per �5.7)
	CartClaimed = "RemoteEvent",
	PlayerDataUpdated = "RemoteEvent",
	ZoneUnlocked = "RemoteEvent",

	-- Phase 5 addition: �5.2's initial Remotes list didn't enumerate this one,
	-- but Phase 5's own text calls for "the one-time World-unlock banner
	-- (�8)" -- a VFX-trigger-only event, exactly mirroring ZoneUnlocked's
	-- existing pattern, not a new kind of thing.
	WorldUnlocked = "RemoteEvent",
}

local RemotesSetup = {}

local FOLDER_NAME = "Remotes"

-- Server-only: creates the Remotes folder + every instance in REMOTES.
-- Idempotent -- safe to call more than once (returns existing instances).
function RemotesSetup.CreateAll(): Folder
	local existing = ReplicatedStorage:FindFirstChild(FOLDER_NAME)
	local folder: Folder
	if existing then
		folder = existing :: Folder
	else
		local newFolder = Instance.new("Folder")
		newFolder.Name = FOLDER_NAME
		newFolder.Parent = ReplicatedStorage
		folder = newFolder
	end

	for name, kind in REMOTES do
		if not folder:FindFirstChild(name) then
			local instance = Instance.new(kind)
			instance.Name = name
			instance.Parent = folder
		end
	end

	return folder
end

-- Client-only: waits for the Remotes folder and every named instance in it.
function RemotesSetup.WaitForAll(): { [string]: RemoteEvent | RemoteFunction }
	local folder = ReplicatedStorage:WaitForChild(FOLDER_NAME) :: Folder

	local remotes: { [string]: RemoteEvent | RemoteFunction } = {}
	for name in REMOTES do
		remotes[name] = folder:WaitForChild(name) :: RemoteEvent | RemoteFunction
	end

	return remotes
end

return RemotesSetup
