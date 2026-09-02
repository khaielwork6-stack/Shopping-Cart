--!strict
-- Per-player, per-Remote call-frequency guard (§5.6's anti-exploit baseline:
-- every RemoteFunction/RemoteEvent handler must bound how often a single
-- client can invoke it, independent of whatever the handler's own
-- validation already checks). §13 QA found every handler already validated
-- its arguments and server-side state correctly, but nothing bounded raw
-- call frequency -- a client could still hammer a cheap-to-validate Remote
-- (e.g. RequestSellLoot when NotAtNPC) thousands of times a second for pure
-- server-load griefing, which is its own exploit even with zero payout.

local RateLimiter = {}

-- [Player][remoteName] = { windowStart: number, count: number }
local buckets: { [Player]: { [string]: { windowStart: number, count: number } } } = {}

local WINDOW_SECONDS = 1

-- Returns true if this call is allowed under `maxPerSecond` for this
-- (player, remoteName) pair, and records the call either way. Callers
-- should check this first, before any other validation, and return their
-- own handler's failure shape (never throw) when it's false.
function RateLimiter.Allow(player: Player, remoteName: string, maxPerSecond: number): boolean
	local now = os.clock()
	local playerBuckets = buckets[player]
	if not playerBuckets then
		playerBuckets = {}
		buckets[player] = playerBuckets
	end

	local bucket = playerBuckets[remoteName]
	if not bucket or now - bucket.windowStart >= WINDOW_SECONDS then
		playerBuckets[remoteName] = { windowStart = now, count = 1 }
		return true
	end

	if bucket.count >= maxPerSecond then
		return false
	end

	bucket.count += 1
	return true
end

function RateLimiter.ClearPlayer(player: Player)
	buckets[player] = nil
end

return RateLimiter
