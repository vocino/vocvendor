-- VocVendor: vendor automation built around one idea: junk is a
-- configurable definition, not a fixed pile of grays. The definition
-- drives both triggers: auto-sell on every vendor visit, and the
-- merchant frame's own Sell Junk button (which we enhance, not
-- replace).
--
-- Sources of truth (verified against the live 12.x client, see AGENTS.md):
--   C_MerchantFrame.SellAllJunkItems / GetNumJunkItems -- Blizzard's own
--     junk sale; the native Sell Junk button calls the same API.
--   MerchantSellAllJunkButton (MerchantFrame.xml) calls
--     MerchantFrame_OnSellAllJunkButtonClicked on click; its enabled
--     state is refreshed inside MerchantFrame_Update.
--   RepairAllItems(useGuildBank), CanMerchantRepair, CanGuildBankRepair,
--     GetRepairAllCost -> (cost, canRepair) -- Blizzard's own repair flow
--     (MerchantFrame.xml guild-bank repair button).
--   C_Item.IsItemBindToAccountUntilEquip -- Warbound detection (used by
--     Blizzard's own MerchantFrame.lua).
--   C_Item.GetItemInfo returns, in order: name, link, quality, level,
--     minLevel, type, subType, stackCount, equipLoc, texture, sellPrice(11),
--     classID(12), subclassID(13), bindType(14), ... (ItemDocumentation).
--   Enum.ItemBind.OnEquip (2) = BoE; Enum.ItemQuality.Heirloom (7).
--   C_Container.UseContainerItem on a bag slot sells the item while a
--     merchant window is open (the same action as right-clicking it).

local name, ns = ...

-- VocDebug guest hook: silent no-op unless VocDebug is loaded.
local dbg = VOCDBG or function() end

ns.PREFIX_COLOR = "ff66ccff"
function ns.say(msg)
  print("|c" .. ns.PREFIX_COLOR .. name .. "|r: " .. tostring(msg))
end

-- The junk definition. Grays are always junk (Blizzard's own baseline,
-- and what the native button's tooltip promises). Old gear joins the
-- definition only when the player opts in: then it sells automatically
-- AND on the Sell Junk button, so the default stays safe.
local defaults = {
  autoSell = true,        -- sell junk on every vendor visit
  autoRepair = true,      -- repair on every vendor visit
  guildRepair = true,     -- guild funds first, own gold as fallback
  announce = true,        -- chat line for sells and repairs
  junkOldGear = false,    -- old gear counts as junk
  oldGearIlvlGap = 30,    -- ...when this far below equipped
  oldGearBoE = false,     -- include Bind on Equip in old gear
  oldGearWarbound = false,-- include Warbound in old gear
}

VocVendorDB = VocVendorDB or {}
ns.db = VocVendorDB

function ns.opts()
  if type(ns.db) ~= "table" then ns.db = {} VocVendorDB = ns.db end
  for k, v in pairs(defaults) do
    if type(ns.db[k]) ~= type(v) then ns.db[k] = v end
  end
  return ns.db
end

function ns.moneyString(copper)
  copper = math.floor(tonumber(copper) or 0)
  if copper < 0 then copper = 0 end
  local g = math.floor(copper / 10000)
  local s = math.floor((copper % 10000) / 100)
  local c = copper % 100
  if g > 0 then return string.format("%dg %ds", g, s) end
  if s > 0 then return string.format("%ds %dc", s, c) end
  return string.format("%dc", c)
end

-- The configured junk right now: gray count (Blizzard's definition) plus
-- the old-gear list when the player opted it into the definition.
function ns.collectJunk()
  local grayCount = 0
  if type(C_MerchantFrame) == "table"
    and type(C_MerchantFrame.GetNumJunkItems) == "function" then
    local ok, n = pcall(C_MerchantFrame.GetNumJunkItems)
    if ok and type(n) == "number" then grayCount = n end
  end
  local oldGear = {}
  if ns.opts().junkOldGear then
    oldGear = ns.collectOldGear()
  end
  return { grayCount = grayCount, oldGear = oldGear }
end

-- Sells the gray pile via Blizzard's own API. Returns copper earned.
function ns.sellGrays()
  if type(C_MerchantFrame) ~= "table" then return 0 end
  if type(C_MerchantFrame.SellAllJunkItems) ~= "function" then return 0 end
  local before = GetMoney()
  pcall(C_MerchantFrame.SellAllJunkItems)
  local earned = GetMoney() - before
  return earned > 0 and earned or 0
end

-- Sells a candidate list, re-verifying each slot first: bags shift
-- between the dry-run and the click, and we never sell the wrong item.
-- Quiet: the caller composes the announcement. Returns count and copper.
function ns.sellOldGearItems(items)
  local n, value = 0, 0
  for _, it in ipairs(items or {}) do
    if C_Container.GetContainerItemLink(it.bag, it.slot) == it.link then
      local ok = pcall(C_Container.UseContainerItem, it.bag, it.slot)
      if ok then
        n = n + 1
        value = value + (it.price or 0)
      end
    end
  end
  return n, value
end

function ns.junkSummary(junk, earned, nOld)
  local parts = {}
  if junk.grayCount > 0 then
    parts[#parts + 1] = junk.grayCount .. " junk"
  end
  if nOld > 0 then
    parts[#parts + 1] = nOld .. " old gear"
  end
  if #parts == 0 then return nil end
  return "sold " .. table.concat(parts, ", ") .. " for "
    .. ns.moneyString(earned)
end

-- Sale confirmation: the click Blizzard's own merchant buttons use
-- (MerchantFrame.lua in the live UI source), with a numeric fallback
-- so a Blizzard rename never silently kills the polish. Independent of
-- the announce toggle: sound confirms the action, chat reports it.
function ns.sellSound()
  local sound = (SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON) or 856
  pcall(PlaySound, sound)
end

-- Auto path: sells the whole configured definition, no popup. The player
-- opted into every part of it via settings.
function ns.autoSell()
  local junk = ns.collectJunk()
  if junk.grayCount == 0 and #junk.oldGear == 0 then return end
  local earned = 0
  if junk.grayCount > 0 then earned = ns.sellGrays() end
  local nOld, oldValue = ns.sellOldGearItems(junk.oldGear)
  dbg("vocvendor", "auto_sell",
    "gray=" .. junk.grayCount .. " old=" .. nOld)
  local line = ns.junkSummary(junk, earned + oldValue, nOld)
  if line then
    ns.sellSound()
    if ns.opts().announce then ns.say(line) end
  end
end

-- Repair. Mirrors the merchant frame's own buttons: guild first when
-- allowed (RepairAllItems(true)), own gold otherwise. If the guild
-- attempt leaves damage behind (no funds / no permission), fall back to
-- personal gold. Announces only when repaired; returns whether it did.
function ns.repairNow()
  if type(CanMerchantRepair) ~= "function" or not CanMerchantRepair() then return false end
  if type(GetRepairAllCost) ~= "function" then return false end
  if type(RepairAllItems) ~= "function" then return false end
  local ok, cost, canRepair = pcall(GetRepairAllCost)
  cost = tonumber(cost) or 0
  if not ok or not canRepair or cost == 0 then return false end
  local usedGuild = false
  local didRepair = false
  local o = ns.opts()
  if o.guildRepair and type(CanGuildBankRepair) == "function" then
    local okG, canG = pcall(CanGuildBankRepair)
    if okG and canG then
      pcall(RepairAllItems, true)
      local _, stillCan = GetRepairAllCost()
      usedGuild = not stillCan
      didRepair = usedGuild
    end
  end
  if not didRepair and GetMoney() >= cost then
    pcall(RepairAllItems)
    didRepair = true
  end
  if didRepair then
    dbg("vocvendor", "repaired", "cost=" .. cost .. " guild=" .. tostring(usedGuild))
    -- Blizzard's own repair button plays this; mirror it so the
    -- automatic repair confirms the same way a click would.
    local sound = (SOUNDKIT and SOUNDKIT.ITEM_REPAIR) or 7994
    pcall(PlaySound, sound)
    if o.announce then
      ns.say("repaired for " .. ns.moneyString(cost)
        .. (usedGuild and " (guild funds)" or ""))
    end
  end
  return didRepair
end

function ns.onMerchantShow()
  ns.hookJunkButton()
  -- Sell first: junk gold pays for the repair that follows.
  local o = ns.opts()
  if o.autoSell then ns.autoSell() end
  if o.autoRepair then ns.repairNow() end
end

-- The native Sell Junk button, enhanced. We keep Blizzard's button,
-- tooltip, and grays-only flow untouched; when the player's junk
-- definition includes old gear, the click runs our dry-run first.
-- Everything is presence-gated: on a client without the button (or
-- without its API) we simply don't hook.
ns.junkHooked = false
ns.blizzJunkClick = nil

function ns.hookJunkButton()
  if ns.junkHooked then return end
  if type(MerchantSellAllJunkButton) ~= "table" then return end
  if type(MerchantSellAllJunkButton.GetScript) ~= "function" then return end
  if type(MerchantSellAllJunkButton.SetScript) ~= "function" then return end
  ns.blizzJunkClick = MerchantSellAllJunkButton:GetScript("OnClick")
  MerchantSellAllJunkButton:SetScript("OnClick",
    function(button) ns.onJunkButtonClick(button) end)
  if type(hooksecurefunc) == "function" then
    hooksecurefunc("MerchantFrame_Update", function() ns.refreshJunkButton() end)
  end
  ns.junkHooked = true
end

-- Blizzard enables the button on grays alone; re-enable when our
-- definition has old gear but no grays. Runs after MerchantFrame_Update.
function ns.refreshJunkButton()
  if type(MerchantSellAllJunkButton) ~= "table" then return end
  if type(MerchantSellAllJunkButton.IsShown) == "function"
    and not MerchantSellAllJunkButton:IsShown() then
    return
  end
  local junk = ns.collectJunk()
  local has = junk.grayCount > 0 or #junk.oldGear > 0
  if type(MerchantSellAllJunkButton.SetEnabled) == "function" then
    MerchantSellAllJunkButton:SetEnabled(has)
  end
end

-- Manual path (native button or /vv): same definition as auto-sell, but
-- old gear goes through the itemized dry-run first. Grays alone keep
-- Blizzard's original click and popup.
function ns.onJunkButtonClick(button)
  local junk = ns.collectJunk()
  if junk.grayCount == 0 and #junk.oldGear == 0 then
    ns.say("nothing to sell")
    return
  end
  if #junk.oldGear == 0 then
    if type(ns.blizzJunkClick) == "function" then
      ns.blizzJunkClick(button)
    end
    return
  end
  local total = 0
  for _, it in ipairs(junk.oldGear) do total = total + (it.price or 0) end
  ns.say("junk to sell (" .. junk.grayCount .. " gray, "
    .. #junk.oldGear .. " old gear):")
  for _, it in ipairs(junk.oldGear) do print("  " .. it.link) end
  StaticPopup_Show("VOCVENDOR_SELL_JUNK",
    junk.grayCount + #junk.oldGear, ns.moneyString(total),
    { grayCount = junk.grayCount, oldGear = junk.oldGear })
end

-- Confirm handler for the dry-run popup: sells the configured junk.
function ns.sellJunkNow(data)
  data = data or {}
  local earned = 0
  if (data.grayCount or 0) > 0 then earned = ns.sellGrays() end
  local nOld, oldValue = ns.sellOldGearItems(data.oldGear)
  dbg("vocvendor", "manual_sell",
    "gray=" .. (data.grayCount or 0) .. " old=" .. nOld)
  local line = ns.junkSummary(
      { grayCount = data.grayCount or 0 }, earned + oldValue, nOld)
  if line then
    ns.sellSound()
    if ns.opts().announce then ns.say(line) end
  end
end

StaticPopupDialogs["VOCVENDOR_SELL_JUNK"] = {
  text = "Sell %d items for %s?",
  button1 = "Sell",
  button2 = "Cancel",
  OnAccept = function(_, data) ns.sellJunkNow(data) end,
  timeout = 0,
  whileDead = true,
  hideOnEscape = true,
}

-- Sell Old Gear: bag gear far below the equipped item level.
-- Slot tables duplicated from VocGear (same client build, same source);
-- no shared runtime dependency between family addons.
ns.slotPairs = { INVTYPE_FINGER = { 11, 12 }, INVTYPE_TRINKET = { 13, 14 } }
ns.primarySlot = {
  INVTYPE_HEAD = 1, INVTYPE_NECK = 2, INVTYPE_SHOULDER = 3, INVTYPE_BODY = 4,
  INVTYPE_CHEST = 5, INVTYPE_ROBE = 5, INVTYPE_WAIST = 6, INVTYPE_LEGS = 7,
  INVTYPE_FEET = 8, INVTYPE_WRIST = 9, INVTYPE_HAND = 10, INVTYPE_FINGER = 11,
  INVTYPE_TRINKET = 13, INVTYPE_CLOAK = 15, INVTYPE_WEAPON = 16,
  INVTYPE_SHIELD = 17, INVTYPE_2HWEAPON = 16, INVTYPE_WEAPONMAINHAND = 16,
  INVTYPE_RANGED = 16, INVTYPE_RANGEDRIGHT = 16, INVTYPE_WEAPONOFFHAND = 17,
  INVTYPE_HOLDABLE = 17, INVTYPE_TABARD = 19,
}

function ns.isWarbound(link)
  if type(C_Item) ~= "table" then return false end
  if type(C_Item.IsItemBindToAccountUntilEquip) ~= "function" then return false end
  local ok, warbound = pcall(C_Item.IsItemBindToAccountUntilEquip, link)
  return ok and warbound == true
end

-- Pawn guest: never sell what Pawn flags as an upgrade. Pawn API verified
-- against Pawn's current source (see VocGear's .reference/pawn-analysis.md):
-- PawnGetItemData(link) -> item table; PawnIsItemAnUpgrade(item) -> entries.
function ns.pawnSaysUpgrade(link)
  if type(_G.PawnGetItemData) ~= "function" then return false end
  if type(_G.PawnIsItemAnUpgrade) ~= "function" then return false end
  local ok, item = pcall(_G.PawnGetItemData, link)
  if not ok or type(item) ~= "table" then return false end
  local okUp, upgrades = pcall(_G.PawnIsItemAnUpgrade, item)
  if not okUp or type(upgrades) ~= "table" then return false end
  for _, entry in pairs(upgrades) do
    if type(entry) == "table" and entry.UpgradeInfo
      and tonumber(entry.UpgradeInfo) and entry.UpgradeInfo > 0 then
      return true
    end
  end
  return false
end

-- True when the bag item is weapons/armor gear at least `gap` item levels
-- below everything equipped in its slot(s), passing the exclusion
-- filters. Uncached items are skipped rather than guessed about.
function ns.isOldGear(link, gap)
  local _, _, _, equipLoc, _, classID = C_Item.GetItemInfoInstant(link)
  if not equipLoc or equipLoc == "" then return false end
  if classID ~= Enum.ItemClass.Weapon and classID ~= Enum.ItemClass.Armor then
    return false
  end
  local _, _, quality, _, _, _, _, _, _, _, sellPrice, _, _, bindType =
    C_Item.GetItemInfo(link)
  if not quality then return false end
  if quality == Enum.ItemQuality.Heirloom then return false end
  if not sellPrice or sellPrice == 0 then return false end
  local o = ns.opts()
  if bindType == Enum.ItemBind.OnEquip and not o.oldGearBoE then return false end
  if ns.isWarbound(link) and not o.oldGearWarbound then return false end
  if ns.pawnSaysUpgrade(link) then return false end
  local slots = ns.slotPairs[equipLoc] or { ns.primarySlot[equipLoc] }
  local candLevel = C_Item.GetDetailedItemLevelInfo(link)
  if not candLevel then return false end
  local compared = false
  for _, slotID in ipairs(slots) do
    if slotID then
      local eqLink = GetInventoryItemLink("player", slotID)
      if eqLink then
        local eqLevel = C_Item.GetDetailedItemLevelInfo(eqLink)
        if eqLevel then
          compared = true
          -- Below the weakest equipped piece by the full gap, or keep.
          if candLevel + gap > eqLevel then return false end
        end
      end
    end
  end
  return compared
end

function ns.collectOldGear()
  local gap = ns.opts().oldGearIlvlGap or 30
  local out = {}
  for bag = 0, NUM_BAG_SLOTS do
    local slots = C_Container.GetContainerNumSlots(bag)
    for slot = 1, slots do
      local link = C_Container.GetContainerItemLink(bag, slot)
      if link and ns.isOldGear(link, gap) then
        local _, _, _, _, _, _, _, _, _, _, sellPrice = C_Item.GetItemInfo(link)
        out[#out + 1] = { link = link, bag = bag, slot = slot,
          price = sellPrice or 0 }
      end
    end
  end
  return out
end

-- Settings
ns.settingsBuilt = false
function ns.onSettingChanged(setting, fn)
  if setting and type(setting.SetValueChangedCallback) == "function" then
    setting:SetValueChangedCallback(fn)
  end
end

function ns.ensureSettings()
  if ns.settingsBuilt then return end
  if type(Settings) ~= "table" then return end
  if type(Settings.RegisterVerticalLayoutCategory) ~= "function" then return end
  local category = Settings.RegisterVerticalLayoutCategory("VocVendor")
  Settings.RegisterAddOnCategory(category)
  local db = ns.opts() -- bound, defaulted table
  local function check(key, label, tooltip)
    local s = Settings.RegisterAddOnSetting(
      category, "VocVendor_" .. key, key, db, type(defaults[key]), label, defaults[key])
    Settings.CreateCheckbox(category, s, tooltip)
  end
  check("autoSell", "Auto-sell junk",
    "Sell junk automatically on every vendor visit. Junk is what you configure below.")
  check("autoRepair", "Auto-repair",
    "Repair all gear automatically at vendors that repair.")
  check("guildRepair", "Guild funds first",
    "Pay repairs from the guild bank when possible, your own gold otherwise.")
  check("announce", "Chat announcements",
    "Print a line when VocVendor sells or repairs.")
  check("junkOldGear", "Old gear counts as junk",
    "Gear far below your equipped item level sells with junk, automatically and on the Sell Junk button. Off keeps it out of the definition.")
  do
    local s = Settings.RegisterAddOnSetting(
      category, "VocVendor_oldGearIlvlGap", "oldGearIlvlGap",
      db, type(defaults.oldGearIlvlGap), "Old gear ilvl gap", defaults.oldGearIlvlGap)
    local sliderOpts = Settings.CreateSliderOptions(10, 100, 5)
    local rightLabel = MinimalSliderWithSteppersMixin
      and MinimalSliderWithSteppersMixin.Label
      and MinimalSliderWithSteppersMixin.Label.Right
    if rightLabel and type(sliderOpts.SetLabelFormatter) == "function" then
      sliderOpts:SetLabelFormatter(rightLabel)
    end
    Settings.CreateSlider(category, s, sliderOpts,
      "Gear this far below your equipped item level counts as old gear.")
  end
  check("oldGearBoE", "Also sell Bind on Equip",
    "Include BoE gear in old gear. Off keeps it safe: BoE can sell well on the auction house.")
  check("oldGearWarbound", "Also sell Warbound",
    "Include Warbound gear in old gear. Off keeps it safe: alts can use it through the warbank.")
  ns.settingsBuilt = true
  ns.settingsCategory = category
end

function ns.openConfig()
  local ok = pcall(function() Settings.OpenToCategory(ns.settingsCategory:GetID()) end)
  if not ok then ns.say("open Settings > AddOns > VocVendor") end
end

-- Addon compartment entry, wired declaratively: ## AddonCompartmentFunc
-- in the .toc names this function, and Blizzard's compartment menu
-- calls it with (addonName, buttonName). Clients without the
-- compartment ignore the metadata, so no gate is needed here.
function VocVendor_CompartmentClick()
  ns.openConfig()
end

-- Slash. Bare command runs the manual junk sale (same as clicking the
-- native Sell Junk button); on/off flips auto-sell.
ns.HELP = {
  "/vv -- sell junk now",
  "/vv on|off -- auto-sell junk on vendor visits",
  "/vv repair -- repair now",
  "/vv config -- open settings",
}
function ns.help()
  ns.say("commands")
  for _, line in ipairs(ns.HELP) do print("  " .. line) end
end

SLASH_VOCVENDOR1 = "/vv"
SLASH_VOCVENDOR2 = "/vocvendor"
SlashCmdList.VOCVENDOR = function(msg)
  msg = strtrim(msg or ""):lower()
  local o = ns.opts()
  if msg == "" then
    if type(MerchantFrame) ~= "table" or not MerchantFrame:IsShown() then
      ns.say("open a vendor first")
      return
    end
    ns.onJunkButtonClick(MerchantSellAllJunkButton)
  elseif msg == "on" or msg == "off" then
    o.autoSell = (msg == "on")
    ns.say("auto-sell junk " .. (o.autoSell and "on" or "off"))
  elseif msg == "repair" then
    if type(MerchantFrame) ~= "table" or not MerchantFrame:IsShown() then
      ns.say("open a vendor first")
      return
    end
    if not ns.repairNow() then ns.say("nothing to repair") end
  elseif msg == "config" then
    ns.openConfig()
  else
    ns.help()
  end
end

-- Events
ns.frame = CreateFrame("Frame")
ns.frame:RegisterEvent("ADDON_LOADED")
ns.frame:RegisterEvent("MERCHANT_SHOW")
ns.frame:SetScript("OnEvent", function(_, event, arg1)
  if event == "ADDON_LOADED" and arg1 == name then
    if type(VocVendorDB) ~= "table" then VocVendorDB = {} end
    ns.db = VocVendorDB
    ns.ensureSettings()
  elseif event == "MERCHANT_SHOW" then
    ns.onMerchantShow()
  end
end)
