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

	-- Lost Cart GDD v3 �6.2: unhooks the back cart. A RemoteEvent, not a
	-- RemoteFunction -- fire-and-forget like every other input-driven action,
	-- the client learns the outcome via the usual PlayerDataUpdated push.
	RequestDumpCart = "RemoteEvent",

	-- Phase 4 �9: Base item placement -- server-authoritative swap, so both
	-- need a real response (success/failure), unlike the fire-and-forget
	-- events above.
	RequestPlaceItem = "RemoteFunction",
	RequestRemoveItem = "RemoteFunction",

	-- §13 QA: one-shot pull the client fires at boot, before any Controller
	-- renders anything -- see server/init.server.luau's own comment on the
	-- join-time race this fixes.
	RequestPlayerDataSnapshot = "RemoteFunction",

	-- server -> client, RemoteEvent (past-tense-noun-named per �5.7)
	CartClaimed = "RemoteEvent",

	-- Lost Cart GDD: fired at the exact moment a claim finalizes, carrying
	-- the real CartID rolled server-side (see the Security note in
	-- LostCartData -- never sent any earlier than this) plus the
	-- already-in-Workspace cover Instance, so LostCartRevealController can
	-- play the compress/burst/reveal sequence in place before handing off
	-- to TrainController.
	CartRevealed = "RemoteEvent",

	PlayerDataUpdated = "RemoteEvent",
	ZoneUnlocked = "RemoteEvent",

	-- Phase 5 addition: �5.2's initial Remotes list didn't enumerate this one,
	-- but Phase 5's own text calls for "the one-time World-unlock banner
	-- (�8)" -- a VFX-trigger-only event, exactly mirroring ZoneUnlocked's
	-- existing pattern, not a new kind of thing.
	WorldUnlocked = "RemoteEvent",

	-- Phase 10 (�8) additions: the two Legendary "social beat" VFX triggers
	-- (spawn chime, collection beam) are broadcast to every player sharing
	-- the same World, not just the one player CartClaimed already targets.
	LegendaryCartSpawned = "RemoteEvent",
	LegendaryCartClaimed = "RemoteEvent",

	-- Phase 4 �9.4: fired once at join if there was a real offline gap to
	-- pay out -- the client's "one button" claim panel is a receipt toast
	-- (UIAnimationController.ShowNotification), the cash is already granted
	-- server-side by the time this fires.
	OfflineEarningsReady = "RemoteEvent",

	-- Phase 5 �10: server -> client, fired at the target on a landed bat
	-- hit -- cosmetic-only (screen shake/thud SFX). The knockdown/ragdoll
	-- itself needs no remote at all: it's a real Motor6D/BallSocketConstraint
	-- + Humanoid.PlatformStand change on a real server-owned Instance, which
	-- replicates to every client on its own.
	PlayerKnockedDown = "RemoteEvent",
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
