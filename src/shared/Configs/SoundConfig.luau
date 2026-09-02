--!strict
-- Single source of truth for real SFX/music asset ids (§7 Placeholder
-- Registry resolution -- these replace the PH_SFX_* placeholders that had
-- no SoundId set). Keyed by the same names Controllers pass to
-- SoundController.PlaySFX, so adding a new sound later is just one new
-- entry here plus the PlaySFX call at its trigger site.

export type SoundName =
	"CartCollect"
	| "UpgradePurchase"
	| "LevelUp"
	| "Rebirth"
	| "ZoneUnlock"
	| "WorldUnlock"
	| "Sell"
	| "UIClick"
	| "UIOpenClose"
	| "UIDenied"
	| "ItemReveal"
	| "PortalEnter"
	| "Notification"
	| "NPCInteraction"
	| "PersonalBest"
	| "Jump"
	| "HoverButton"
	| "BackgroundMusic"

local SoundConfig: { [SoundName]: string } = {
	CartCollect = "rbxassetid://96267401354076",
	UpgradePurchase = "rbxassetid://80736831159506",
	LevelUp = "rbxassetid://17648982831",
	Rebirth = "rbxassetid://116975598122611",
	ZoneUnlock = "rbxassetid://113307491257691",
	WorldUnlock = "rbxassetid://93360393539898",
	Sell = "rbxassetid://138979515680965",
	UIClick = "rbxassetid://15675059323",
	UIOpenClose = "rbxassetid://127877437691780",
	UIDenied = "rbxassetid://87047730068459",
	ItemReveal = "rbxassetid://115267983058615",
	PortalEnter = "rbxassetid://113799140589345",
	Notification = "rbxassetid://131661992591924",
	NPCInteraction = "rbxassetid://78566355879660",
	PersonalBest = "rbxassetid://136182414783063",
	Jump = "rbxassetid://109397400639910",
	HoverButton = "rbxassetid://136108770017536",
	BackgroundMusic = "rbxassetid://138465914285393",
}

return SoundConfig
