--!strict
-- Owns load/save/cache; the ONLY Service that touches DataStore (�5.2/�6).
-- Stub for Phase 0 -- full implementation lands in Phase 8.

local PlayerDataService = {}

function PlayerDataService.Init()
	print("[PlayerDataService] Init")
end

return PlayerDataService
