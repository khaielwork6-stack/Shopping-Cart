--!strict
-- Rebirth-specific display copy (�4.4). Multiplier formulas live in
-- EconomyConfig/EconomyMath; this module only owns the UI-facing text and
-- the reset/keep lists used to render the confirmation modal.

local RebirthConfig = {}

RebirthConfig.BannerText = "Ready to Rebirth!"

RebirthConfig.ResetsOnRebirth = {
	"Push Power level (back to base)",
	"Current Level / XP (back to 1 / 0)",
}

RebirthConfig.PersistsAcrossRebirth = {
	"Total Level",
	"Capacity / Agility / Mobility / Range levels",
	"Rebirth count",
	"Push Power Multiplier",
	"Cash Multiplier",
	"Unlocked Worlds",
	"Loot inventory",
	"Index discoveries",
	"Cash and Gems on hand",
	"Cosmetics, settings, lifetime stats",
}

RebirthConfig.CinematicDurationSeconds = 2.5 -- �4.4/�8: 2-3s ceremony beat, capped under 3s

return RebirthConfig
