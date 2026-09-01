--!strict
-- Per-zone spawn/despawn loop (�5.2/�4.1.1). Depends on WorldService knowing
-- which worlds/zones are live (�5.4). Stub for Phase 0 -- basic version is
-- Phase 1, full budget curve is Phase 2/3.

local CartSpawnService = {}

function CartSpawnService.Init()
	print("[CartSpawnService] Init")
end

return CartSpawnService
