--!strict
-- Rebirth requirement checks + the atomic reset/multiplier transaction
-- (�5.2/�4.4/�3.3). Requires EconomyService (Level/XP/rebirthCount owner)
-- and UpgradeService (Push Power level owner) at the top level -- neither
-- of those requires this Service back, so there is no cycle here (unlike
-- the PushPowerService/EconomyService edge, which does need laziness).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local EconomyMath = require(ReplicatedStorage.Shared.Modules.EconomyMath)
local RemotesSetup = require(ReplicatedStorage.Shared.Modules.RemotesSetup)
local RateLimiter = require(ReplicatedStorage.Shared.Modules.RateLimiter)
local EconomyService = require(script.Parent.EconomyService)
local UpgradeService = require(script.Parent.UpgradeService)
local WorldService = require(script.Parent.WorldService)

local RebirthService = {}

local remotesFolder: Folder

-- �3.3: RebirthLevelRequirement(k) for the rebirth the player is currently
-- working toward (k = rebirthCount + 1).
function RebirthService.GetNextRebirthRequirement(player: Player): number
	local levelState = EconomyService.GetLevelState(player)
	return EconomyMath.GetRebirthLevelRequirement(levelState.rebirthCount + 1)
end

function RebirthService.CanRebirth(player: Player): boolean
	local levelState = EconomyService.GetLevelState(player)
	return levelState.currentLevel >= RebirthService.GetNextRebirthRequirement(player)
end

-- �4.4 point 4: "Server applies the reset + multiplier update atomically
-- (single validated RemoteFunction call -- never two separate calls a
-- client could split and exploit between)". This handler is that single
-- call; the two internal mutations below happen synchronously with no
-- yield between them, so there is no window a client could interleave
-- another action into.
local function handleRequestRebirth(player: Player)
	if not RateLimiter.Allow(player, "RequestRebirth", 5) then
		return { success = false, reason = "RateLimited" }
	end

	if not RebirthService.CanRebirth(player) then
		return { success = false, reason = "RequirementNotMet" }
	end

	local newRebirthCount = EconomyService.PerformRebirthReset(player)
	UpgradeService.ResetPushPower(player)

	-- Lost Cart migration Phase 2: bonus-World unlocks are Rebirth-gated now,
	-- not Total-Level-gated -- this replaces the old per-frame poll as the
	-- one and only place a bonus World can newly unlock.
	WorldService.CheckWorldUnlocks(player)

	return {
		success = true,
		rebirthCount = newRebirthCount,
		pushPowerMultiplier = EconomyMath.GetRebirthPushPowerMultiplier(newRebirthCount),
		cashMultiplier = EconomyMath.GetRebirthCashMultiplier(newRebirthCount),
		luckMultiplier = EconomyMath.GetRebirthLuckMultiplier(newRebirthCount),
	}
end

function RebirthService.Init()
	remotesFolder = RemotesSetup.CreateAll()

	local requestRebirth = remotesFolder:FindFirstChild("RequestRebirth") :: RemoteFunction
	requestRebirth.OnServerInvoke = function(player: Player)
		return handleRequestRebirth(player)
	end

	print("[RebirthService] Init")
end

return RebirthService
