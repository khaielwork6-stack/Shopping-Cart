--!strict
-- One function per version transition (�6.5), applied in order on load
-- until version matches current. No migration is ever destructive -- if in
-- doubt, keep the old field alongside the new one rather than delete-and-
-- hope. Empty for now: this is the first version this project has ever
-- persisted, so there is nothing to migrate from yet -- structurally ready
-- for the first real schema change.

local Migrations = {}

-- Keyed by the version a save is CURRENTLY at; each entry migrates it to
-- the next version up. Example for the future:
--   Migrations.Steps[1] = function(data) data.gems = data.gems or 0; data.version = 2; return data end
Migrations.Steps = {} :: { [number]: (data: any) -> any }

function Migrations.Apply(data: any, fromVersion: number, currentVersion: number): any
	local version = fromVersion
	while version < currentVersion do
		local step = Migrations.Steps[version]
		if not step then
			break -- no migration registered for this version -- leave as-is rather than guess
		end
		data = step(data)
		version = data.version or (version + 1)
	end
	return data
end

return Migrations
