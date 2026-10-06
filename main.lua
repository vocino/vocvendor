-- VocVendor: vendor automation. Sells junk, repairs gear, and offers one
-- smart button (Sell Old Gear) on the merchant frame. Never sells old
-- gear automatically: the button shows a dry-run list first.
--
-- Sources of truth (verified against the live 12.x client, see AGENTS.md):
--   C_MerchantFrame.SellAllJunkItems / GetNumJunkItems -- Blizzard's own
--     junk sale (the merchant frame's built-in Sell All Junk button calls
--     the same API; we just automate it).
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

local defaults = {
  autoSell = true,        -- sell junk on every vendor visit
  autoRepair = true,      -- repair on every vendor visit
  guildRepair = true,     -- guild funds first, own gold as fallback
  announce = true,        -- chat line for sells and repairs
  oldGearIlvlGap = 30,    -- sell gear this far below equipped
  oldGearBoE = false,     -- include Bind on Equip in Sell Old Gear
  oldGearWarbound = false,-- include Warbound in Sell Old Gear
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

-- Junk sale. Uses Blizzard's own junk definition and sale API: the
-- merchant frame's built-in Sell All Junk button calls
-- C_MerchantFrame.SellAllJunkItems(); we call the same thing
-- automatically. Presence-gated so a client without it simply skips.
function ns.sellJunk()
  if type(C_MerchantFrame) ~= "table" then return end
  if type(C_MerchantFrame.GetNumJunkItems) ~= "function" then return end
  if type(C_MerchantFrame.SellAllJunkItems) ~= "function" then return end
  local ok, n = pcall(C_MerchantFrame.GetNumJunkItems)
  if not ok or type(n) ~= "number" or n == 0 then return end
  local before = GetMoney()
  pcall(C_MerchantFrame.SellAllJunkItems)
  local earned = GetMoney() - before
  if earned < 0 then earned = 0 end
  dbg("vocvendor", "sold_junk", "n=" .. n)
  if ns.opts().announce then
    ns.say("sold " .. n .. " junk for " .. ns.moneyString(earned))
  end
end

-- Repair. Mirrors the merchant frame's own buttons: guild first when
-- allowed (RepairAllItems(true)), own gold otherwise. If the guild
-- attempt leaves damage behind (no funds / no permission), fall back to
-- personal gold. Announces only when something was actually repaired.
function ns.repairNow()
  if type(CanMerchantRepair) ~= "function" or not CanMerchantRepair() then return end
  if type(GetRepairAllCost) ~= "function" then return end
  if type(RepairAllItems) ~= "function" then return end
  local ok, cost, canRepair = pcall(GetRepairAllCost)
  cost = tonumber(cost) or 0
  if not ok or not canRepair or cost == 0 then return end
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
    if o.announce then
      ns.say("repaired for " .. ns.moneyString(cost)
        .. (usedGuild and " (guild funds)" or ""))
    end
  end
end

function ns.onMerchantShow()
  ns.ensureVendorButton()
  -- Sell first: junk gold pays for the repair that follows.
  local o = ns.opts()
  if o.autoSell then ns.sellJunk() end
  if o.autoRepair then ns.repairNow() end
end

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

-- The button never sells on its own: it prints the itemized dry-run to
-- chat (links stay clickable there) and asks for one confirmation.
function ns.onSellOldGearClick()
  local items = ns.collectOldGear()
  if #items == 0 then
    ns.say("no old gear to sell")
    return
  end
  local total = 0
  for _, it in ipairs(items) do total = total + (it.price or 0) end
  ns.say("old gear to sell (" .. #items .. "):")
  for _, it in ipairs(items) do print("  " .. it.link) end
  StaticPopup_Show("VOCVENDOR_SELL_OLD_GEAR", #items,
    ns.moneyString(total), { items = items })
end

-- Re-verifies each slot before selling: bags shift between the dry-run
-- and the click, and we never sell the wrong item.
function ns.sellOldGearNow(items)
  local n = 0
  for _, it in ipairs(items or {}) do
    if C_Container.GetContainerItemLink(it.bag, it.slot) == it.link then
      local ok = pcall(C_Container.UseContainerItem, it.bag, it.slot)
      if ok then n = n + 1 end
    end
  end
  dbg("vocvendor", "sold_old_gear", "n=" .. n)
  if ns.opts().announce and n > 0 then
    ns.say("sold " .. n .. " old items")
  end
end

StaticPopupDialogs["VOCVENDOR_SELL_OLD_GEAR"] = {
  text = "Sell %d old items for %s?",
  button1 = "Sell",
  button2 = "Cancel",
  OnAccept = function(_, data) ns.sellOldGearNow(data and data.items) end,
  timeout = 0,
  whileDead = true,
  hideOnEscape = true,
}

-- One button on the merchant frame, stock chrome. Blizzard already ships
-- the manual Sell All Junk button, so ours is only the smart one.
ns.vendorButton = nil
function ns.ensureVendorButton()
  if ns.vendorButton then return end
  if type(MerchantFrame) ~= "table" then return end
  if type(CreateFrame) ~= "function" then return end
  local b = CreateFrame("Button", nil, MerchantFrame, "UIPanelButtonTemplate")
  b:SetSize(120, 22)
  b:SetText("Sell Old Gear")
  b:SetPoint("BOTTOMRIGHT", MerchantFrame, "BOTTOMRIGHT", -10, 10)
  b:SetScript("OnClick", function() ns.onSellOldGearClick() end)
  b:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText("Sell Old Gear")
    GameTooltip:AddLine(
      "Sell bag gear far below your equipped item level, after review.",
      1, 1, 1, true)
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)
  ns.vendorButton = b
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
    "Sell gray-quality junk automatically on every vendor visit.")
  check("autoRepair", "Auto-repair",
    "Repair all gear automatically at vendors that repair.")
  check("guildRepair", "Guild funds first",
    "Pay repairs from the guild bank when possible, your own gold otherwise.")
  check("announce", "Chat announcements",
    "Print a line when VocVendor sells or repairs.")
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
      "Sell Old Gear only lists gear this far below your equipped item level.")
  end
  check("oldGearBoE", "Also sell Bind on Equip",
    "Include BoE gear in Sell Old Gear. Off keeps it safe: BoE can sell well on the auction house.")
  check("oldGearWarbound", "Also sell Warbound",
    "Include Warbound gear in Sell Old Gear. Off keeps it safe: alts can use it through the warbank.")
  ns.settingsBuilt = true
  ns.settingsCategory = category
end

function ns.openConfig()
  local ok = pcall(function() Settings.OpenToCategory(ns.settingsCategory:GetID()) end)
  if not ok then ns.say("open Settings > AddOns > VocVendor") end
end

-- Slash. Bare command sells junk now (the manual trigger); on/off flips
-- auto-sell.
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
    ns.sellJunk()
  elseif msg == "on" or msg == "off" then
    o.autoSell = (msg == "on")
    ns.say("auto-sell junk " .. (o.autoSell and "on" or "off"))
  elseif msg == "repair" then
    ns.repairNow()
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
