-- Lint config shared across the Voc family (see the skill's family/FAMILY.md). The WoW
-- client runs Lua 5.1; tests may use 5.4 features behind guards.
--
-- read_globals is the allowlist of WoW API verified against the build
-- in `## Interface:` (Blizzard_APIDocumentationGenerated for that
-- build, see the skill's family/FAMILY.md "Sources of truth"). Lint fails on any other
-- global on purpose: add a name here only after confirming it exists,
-- under that namespace, in the current build. Never from a wiki.
std = "lua51"
max_line_length = false
self = false
unused_args = false
exclude_files = { ".reference/**" }

-- Globals this addon owns: SavedVariables, slash registration, and the
-- StaticPopup dialog key.
globals = {
  "VocVendorDB",
  "SLASH_VOCVENDOR1", "SLASH_VOCVENDOR2",
  "SlashCmdList",
  "StaticPopupDialogs",
  "VocVendor_CompartmentClick", "VocVendor_CompartmentEnter", "VocVendor_CompartmentLeave",
}

-- WoW API and UI globals read by the addon. Verified on live +
-- forever (see .reference/api-verification.md); every remaining read
-- is presence-gated and fails closed.
read_globals = {
  "_G",
  "C_Container", "C_Item", "C_MerchantFrame", "C_Spell", "C_SpellBook", -- bags, prices, junk sale, disenchant gate (live + forever)
  "C_AddOns", -- rival detection via IsAddOnLoaded (live + forever)
  "C_Timer", -- deferred visit work via After, presence-gated with an immediate fallback
  "C_ToyBox", "C_PetJournal", "C_TransmogCollection", -- collection keep gates (UI-source ok/ok; calls presence-gated)
  "C_QuestLog", -- dead-quest title set (QuestLogDocumentation, live + forever)
  "DeleteCursorItem", -- bare C global, HasRestrictions: confirm click only
  "PlayerHasToy", -- bare C global; Blizzard still calls it bare on both clients
  "CreateFrame", "GetInventoryItemLink", "GetMoney", "UnitStat", -- spec-fit tiebreak
  "canaccessvalue", -- secret-aware stat reads, presence-gated (as in VocXP)
  "InCombatLockdown", -- combat guards on every click path (live + forever)
  "IsMouseButtonDown", "UIParent", "UISpecialFrames",
  "MerchantFrame", "MerchantSellAllJunkButton", -- native Sell Junk hook (MerchantFrame.xml, live + forever)
  "GetMerchantItemInfo", "MERCHANT_ITEMS_PER_PAGE", -- merchant search (MerchantFrame.lua, Vanilla + Mainline)
  "MerchantFrame_Update", -- refresh post-hook for the merchant search
  "GetMerchantNumItems", "GetMerchantItemLink", "GetMerchantItemMaxStack", -- Fill Ammo buys (forever Mainline MerchantFrame.lua)
  "BuyMerchantItem", -- Fill Ammo purchase (forever Mainline MerchantFrame.lua)
  "C_PaperDollInfo", -- AmmoNeeded + AmmoSlot (forever PaperDollInfoDocumentation)
  "UnitUsesAmmo", -- Fill Ammo gate (forever UnitDocumentation)
  "CharacterBag0Slot", -- Fill Ammo bag math (forever MainMenuBarBagButtons.lua)
  "MacroFrame", -- Blizzard_MacroUI owns it on both branches; the OnHide hook and IsShown are presence-gated
  "GetMacroInfo", "GetNumMacros", "CreateMacro", "EditMacro", -- bare macro writes, called by Blizzard_MacroUI on both branches
  "UnitLevel", "UnitPowerMax", -- winner usability + mana gates (UnitDocumentation, both branches)
  "NUM_BAG_SLOTS", -- bag 0 plus worn bags, presence-gated
  "CanGuildBankRepair", "CanMerchantRepair", "GetRepairAllCost",
  "RepairAllItems", -- mirror of the merchant repair buttons (live + forever)
  "Settings", -- native panel, retried at PLAYER_LOGIN (live + forever)
  "GetBuildInfo", -- Interface-version flavor fallback in Compat.lua (BuildDocumentation, live + forever)
  "WOW_PROJECT_CAMELOT", "WOW_PROJECT_ID", "WOW_PROJECT_MAINLINE", -- flavor identity, read only in Compat.lua
  "CreateSettingsListSectionHeaderInitializer", -- section headers, presence-gated (live + forever)
  "GetServerTime", -- New-tag horizon clock, presence-gated (live + forever)
  "MinimalSliderWithSteppersMixin", -- slider label formatter, presence-gated
  "StaticPopup_Show", "StaticPopup_Hide", -- Sell All confirms (live + forever)
  "Enum", -- ItemClass/ItemBind/ItemQuality values identical on both clients
  "PlaySound", "SOUNDKIT", -- presence-gated; ns.play falls back to numeric IDs
  "GameTooltip",
  "ChatFrameUtil", -- shift-click funnel (HandleModifiedItemClick -> InsertLink, live + forever UI source); hook-only, presence-gated
  "hooksecurefunc", "strtrim",
  -- Optional guests: Pawn upgrades never sell; Auctionator/TSM/Oribos feed auction math
  "PawnGetItemData", "PawnIsItemAnUpgrade",
  "AutoGearReadItemInfo", "AutoGearDetermineItemScore", -- guest rater on Forever
  "Auctionator", "TSM_API", "OEMarketInfo",
}

files["tests/**"] = {
  std = "+lua54",
  globals = { "print" },
  read_globals = { "setfenv", "loadstring", "unpack" },
}
