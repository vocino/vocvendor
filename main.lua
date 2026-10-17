-- VocVendor: vendor automation built around one idea: junk is a
-- configurable definition, not a fixed pile of grays. The definition
-- drives both triggers: auto-sell on every vendor visit, and the
-- merchant frame's own Sell Junk button (which we enhance, not
-- replace). Gear kept for disenchanting opens a click-to-disenchant
-- window instead of a chat line.
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
--   C_SpellBook.ContainsAnyDisenchantSpell -- enchanter gate: true when
--     the player knows any Disenchant spell.
--   C_Spell.GetSpellName -- localized Disenchant for the disenchant
--     window's row macros (tainted calls allowed).
--   InCombatLockdown, IsMouseButtonDown, UIParent, UISpecialFrames,
--     BasicFrameTemplateWithInset, SecureActionButtonTemplate --
--     FrameXML technique shared with VocWarbank (presence-gated).
--   C_Item.GetItemInfo returns, in order: name, link, quality, level,
--     minLevel, type, subType, stackCount, equipLoc, texture, sellPrice(11),
--     classID(12), subclassID(13), bindType(14), ... (ItemDocumentation).
--   Enum.ItemBind.OnEquip (2) = BoE; Enum.ItemQuality.Heirloom (7).
--   C_Container.UseContainerItem on a bag slot sells the item while a
--     merchant window is open (the same action as right-clicking it).
--   C_Container.GetContainerItemEquipmentSetInfo(bag, slot) -> (inSet,
--     setList) -- the equipment-set safeguard: set gear never sells.

local name, ns = ...

-- Chat voice shared by every Voc addon (see FAMILY.md): one line, the
-- addon name as a colored prefix, then the message.
ns.PREFIX_COLOR = "ff66ccff"
function ns.say(msg)
  print("|c" .. ns.PREFIX_COLOR .. name .. "|r: " .. tostring(msg))
end

-- Confirmation sounds shared by every Voc addon (FAMILY.md "Sounds"):
-- SOUNDKIT names first, the numeric IDs behind them so a Blizzard
-- rename never silences the polish. Presence-gated: no sound API, no
-- sound, never an error. `sell` is the click Blizzard's own merchant
-- buttons use; `repair` is what its repair button plays.
ns.SOUNDS = {
  on = { "IG_MAINMENU_OPTION_CHECKBOX_ON", 856 },
  off = { "IG_MAINMENU_OPTION_CHECKBOX_OFF", 857 },
  open = { "IG_MAINMENU_OPEN", 850 },
  close = { "IG_MAINMENU_CLOSE", 851 },
  sell = { "IG_MAINMENU_OPTION_CHECKBOX_ON", 856 },
  repair = { "ITEM_REPAIR", 7994 },
}
function ns.play(kind)
  local s = ns.SOUNDS[kind]
  if not s or type(PlaySound) ~= "function" then return end
  local id = type(SOUNDKIT) == "table" and SOUNDKIT[s[1]] or nil
  pcall(PlaySound, type(id) == "number" and id or s[2])
end

-- Palette (FAMILY.md "Palette"), defined once. VocVendor paints only
-- its compartment tooltip, so only the text tokens are ever read.
ns.COLORS = {
  gold = { 1, 0.82, 0 },
  text = { 1, 1, 1 },
  muted = { 0.5, 0.5, 0.5 },
  red = { 0.9, 0.3, 0.25 },
  green = { 0.25, 0.9, 0.35 },
}
local COLORS = ns.COLORS

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
  keepDisenchantable = true, -- keep gear you could disenchant
}
ns.defaults = defaults

VocVendorDB = VocVendorDB or {}
ns.db = VocVendorDB

function ns.opts()
  if type(ns.db) ~= "table" then ns.db = {} VocVendorDB = ns.db end
  for k, v in pairs(defaults) do
    if type(ns.db[k]) ~= type(v) then ns.db[k] = v end
  end
  -- The slider's own range (Settings panel), enforced here too so a
  -- hand-edited gap can never make everything (or nothing) "old gear".
  local gap = ns.db.oldGearIlvlGap
  if not (gap >= 10 and gap <= 100) then ns.db.oldGearIlvlGap = defaults.oldGearIlvlGap end
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

-- Equipment-set safeguard: never sell gear in a saved equipment set.
-- Fail closed: a missing API or a failed call keeps the item, never
-- sells it.
function ns.inEquipmentSet(bag, slot)
  if type(C_Container) ~= "table" then return true end
  if type(C_Container.GetContainerItemEquipmentSetInfo) ~= "function" then return true end
  local ok, inSet = pcall(C_Container.GetContainerItemEquipmentSetInfo, bag, slot)
  if not ok then return true end
  return inSet == true
end

-- Sells a candidate list, re-verifying each slot first: bags shift
-- between the dry-run and the click, and we never sell the wrong item.
-- Set membership and vendor value are rechecked too: a slot that joined
-- a set, or that the vendor won't buy, stays put.
-- Quiet: the caller composes the announcement. Returns count and copper.
function ns.sellOldGearItems(items)
  local n, value = 0, 0
  if type(C_Container) ~= "table" then return n, value end
  if type(C_Container.GetContainerItemLink) ~= "function" then return n, value end
  for _, it in ipairs(items or {}) do
    if C_Container.GetContainerItemLink(it.bag, it.slot) == it.link
      and not ns.inEquipmentSet(it.bag, it.slot)
      and ns.slotHasValue(it.bag, it.slot) then
      local ok = pcall(C_Container.UseContainerItem, it.bag, it.slot)
      if ok then
        n = n + 1
        value = value + (it.price or 0)
      end
    end
  end
  return n, value
end

function ns.junkSummary(grayCount, earned, nOld)
  local parts = {}
  if grayCount > 0 then
    parts[#parts + 1] = grayCount .. " junk"
  end
  if nOld > 0 then
    parts[#parts + 1] = nOld .. " old gear"
  end
  if #parts == 0 then return nil end
  return "sold " .. table.concat(parts, ", ") .. " for "
    .. ns.moneyString(earned)
end

-- Kept-for-disenchant report: nil when nothing was kept.
function ns.keptLine(kept)
  if not kept or #kept == 0 then return nil end
  return "kept " .. #kept .. " for disenchant"
end

-- Sale confirmation, independent of the announce toggle: sound confirms
-- the action, chat reports it.
function ns.sellSound()
  ns.play("sell")
end

-- Auto path: sells the whole configured definition, no popup. The player
-- opted into every part of it via settings.
function ns.autoSell()
  local junk = ns.collectJunk()
  local kept = ns.collectKeptDisenchantables()
  if junk.grayCount == 0 and #junk.oldGear == 0 and #kept == 0 then return end
  local earned = 0
  ns.reportKept(kept)
  if junk.grayCount > 0 then earned = ns.sellGrays() end
  local nOld, oldValue = ns.sellOldGearItems(junk.oldGear)
  local line = ns.junkSummary(junk.grayCount, earned + oldValue, nOld)
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
      local okStill, _, stillCan = pcall(GetRepairAllCost)
      usedGuild = okStill and not stillCan
      didRepair = usedGuild
    end
  end
  if not didRepair and GetMoney() >= cost then
    pcall(RepairAllItems)
    didRepair = true
  end
  if didRepair then
    -- Blizzard's own repair button plays this; mirror it so the
    -- automatic repair confirms the same way a click would.
    ns.play("repair")
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
  local kept = ns.collectKeptDisenchantables()
  local junk = ns.collectJunk()
  if junk.grayCount == 0 and #junk.oldGear == 0 then
    if #kept > 0 then
      ns.reportKept(kept, true)
    else
      ns.say("nothing to sell")
    end
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
  ns.reportKept(kept, true)
end

-- Confirm handler for the dry-run popup: sells the configured junk.
function ns.sellJunkNow(data)
  data = data or {}
  local earned = 0
  ns.reportKept(ns.collectKeptDisenchantables())
  if (data.grayCount or 0) > 0 then earned = ns.sellGrays() end
  local nOld, oldValue = ns.sellOldGearItems(data.oldGear)
  local line = ns.junkSummary(data.grayCount or 0, earned + oldValue, nOld)
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

-- Enchanter gate: true when the player knows any Disenchant spell.
-- Presence-gated and fail closed: without the API nothing counts as
-- kept for disenchanting, so sales behave as if the toggle were off.
function ns.canDisenchant()
  if type(C_SpellBook) ~= "table" then return false end
  if type(C_SpellBook.ContainsAnyDisenchantSpell) ~= "function" then return false end
  local ok, knows = pcall(C_SpellBook.ContainsAnyDisenchantSpell)
  return ok and knows == true
end

-- Per-slot vendor truth: Blizzard's own container info flags the slots no
-- merchant will buy (hasNoValue). The static GetItemInfo price alone lists
-- items the vendor refuses, so collection and the sell click both check the
-- slot. Fail closed: a missing API or a failed call keeps the item, never
-- sells it.
function ns.slotHasValue(bag, slot)
  if type(C_Container) ~= "table" then return false end
  if type(C_Container.GetContainerItemInfo) ~= "function" then return false end
  local ok, info = pcall(C_Container.GetContainerItemInfo, bag, slot)
  if not ok or type(info) ~= "table" then return false end
  return info.hasNoValue == false
end

-- Heuristic for "rather disenchant than sell": uncommon, rare, or epic
-- weapons/armor with a vendor price. Anything the Disenchant spell cannot
-- target stays out of the list. Uncached items fail closed, like every
-- other unknown in this file.
function ns.isDisenchantable(link)
  local _, _, _, equipLoc, _, classID = C_Item.GetItemInfoInstant(link)
  if not equipLoc or equipLoc == "" then return false end
  if classID ~= Enum.ItemClass.Weapon and classID ~= Enum.ItemClass.Armor then
    return false
  end
  local _, _, quality, _, _, _, _, _, _, _, sellPrice = C_Item.GetItemInfo(link)
  if not quality then return false end
  if not sellPrice or sellPrice == 0 then return false end
  -- Uncommon, rare, or epic only: the Disenchant spell cannot target
  -- legendary, artifact, or heirloom gear (nor commons).
  return quality == Enum.ItemQuality.Uncommon
    or quality == Enum.ItemQuality.Rare
    or quality == Enum.ItemQuality.Epic
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
-- filters. Gear kept for disenchanting never qualifies (unless
-- ignoreDE). Uncached items are skipped rather than guessed about.
function ns.isOldGear(link, gap, ignoreDE)
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
  if not ignoreDE and o.keepDisenchantable
    and ns.canDisenchant() and ns.isDisenchantable(link) then
    return false
  end
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
      if link and not ns.inEquipmentSet(bag, slot)
        and ns.slotHasValue(bag, slot)
        and ns.isOldGear(link, gap) then
        local _, _, _, _, _, _, _, _, _, _, sellPrice = C_Item.GetItemInfo(link)
        out[#out + 1] = { link = link, bag = bag, slot = slot,
          price = sellPrice or 0 }
      end
    end
  end
  return out
end

-- Gear kept for disenchanting: items that would be old gear but for the
-- disenchant exclusion. Only non-empty when old gear is junk, the toggle
-- is on, and the player can disenchant; everyone else skips the scan.
function ns.collectKeptDisenchantables()
  local o = ns.opts()
  if not o.junkOldGear then return {} end
  if not o.keepDisenchantable then return {} end
  if not ns.canDisenchant() then return {} end
  local gap = o.oldGearIlvlGap or 30
  local out = {}
  for bag = 0, NUM_BAG_SLOTS do
    local slots = C_Container.GetContainerNumSlots(bag)
    for slot = 1, slots do
      local link = C_Container.GetContainerItemLink(bag, slot)
      if link and not ns.inEquipmentSet(bag, slot)
        and ns.isOldGear(link, gap, true)
        and ns.isDisenchantable(link) then
        out[#out + 1] = { link = link, bag = bag, slot = slot }
      end
    end
  end
  return out
end

-- Disenchant window. Gear kept out of junk sales for disenchanting is
-- actionable, not a chat line: after every sale the kept list opens
-- here, one row per item, and clicking a row disenchants that bag slot.
--
-- Each row is a secure action button (the same path Blizzard's own
-- macros take, and the same technique VocWarbank's in-person
-- disenchant button uses): PreClick writes a "/cast <Disenchant> /use
-- bag slot" macro for the row's item, the template's own OnClick runs
-- it, PostClick clears it. One item per click: a cast is in flight
-- after each. Attributes cannot change in combat, so a combat click
-- arms nothing and says so instead.
--
-- The Disenchant spell ID is the one VocWarbank resolves.
ns.DE_SPELL = 13262
ns.deWindow = nil
ns.deRows = {}

-- Localized Disenchant name for the row macros, nil when the client
-- has no such spell. Presence-gated: no spell API, no window.
function ns.deSpellName()
  if type(C_Spell) ~= "table" then return nil end
  if type(C_Spell.GetSpellName) ~= "function" then return nil end
  local ok, spellName = pcall(C_Spell.GetSpellName, ns.DE_SPELL)
  if not ok or type(spellName) ~= "string" or spellName == "" then return nil end
  return spellName
end

-- Current bag slot holding the link, skipping equipment sets. Bag
-- slots shift after every sale and every disenchant, so a row
-- re-resolves its link on every click instead of trusting its seat.
function ns.findKeptSlot(link)
  if type(C_Container) ~= "table" then return nil end
  if type(C_Container.GetContainerItemLink) ~= "function" then return nil end
  if type(C_Container.GetContainerNumSlots) ~= "function" then return nil end
  for bag = 0, NUM_BAG_SLOTS do
    local slots = C_Container.GetContainerNumSlots(bag)
    for slot = 1, slots do
      if C_Container.GetContainerItemLink(bag, slot) == link
        and not ns.inEquipmentSet(bag, slot) then
        return bag, slot
      end
    end
  end
  return nil
end

-- PreClick: arm this row's macro for its item's current slot. A slot
-- that drifted since the list was built is re-resolved by link; a
-- link that is gone (disenchanted, banked) disarms the click.
local function armDE(row, _, down)
  if type(InCombatLockdown) == "function" and InCombatLockdown() then
    if down then ns.say("can't disenchant during combat") end
    return
  end
  local spell = ns.deSpellName()
  if not spell then row:SetAttribute("type", nil) return end
  local bag, slot = row.deBag, row.deSlot
  local same = bag ~= nil and slot ~= nil
    and type(C_Container) == "table"
    and type(C_Container.GetContainerItemLink) == "function"
    and C_Container.GetContainerItemLink(bag, slot) == row.deLink
  if not same then bag, slot = ns.findKeptSlot(row.deLink) end
  if not bag then row:SetAttribute("type", nil) return end
  row.deBag, row.deSlot = bag, slot
  row:SetAttribute("type", "macro")
  row:SetAttribute("macrotext",
    "/cast " .. spell .. "\n/use " .. bag .. " " .. slot)
end

-- PostClick: clear the macro so a later click never fires a stale one.
local function afterDE(row)
  if type(InCombatLockdown) ~= "function" or not InCombatLockdown() then
    row:SetAttribute("type", nil)
  end
end

-- One clickable row: the item's icon and link. Nil when the client
-- cannot build a secure button, so the caller falls back to chat
-- instead of showing a list that cannot act.
local function newDERow(window)
  local ok, row = pcall(CreateFrame, "Button", nil, window,
    "SecureActionButtonTemplate")
  if not ok or row == nil or type(row.SetAttribute) ~= "function" then
    return nil
  end
  row:SetSize(248, 22)
  -- Both edges registered: the template fires the action on the one
  -- the ActionButtonUseKeyDown cvar picks (as in VocWarbank).
  row:RegisterForClicks("AnyDown", "AnyUp")
  row:SetScript("PreClick", armDE)
  row:SetScript("PostClick", afterDE)
  -- Stock buttons play nothing on click, so the row confirms here;
  -- the up edge is the one that sounds, like every other button.
  if type(row.HookScript) == "function" then
    row:HookScript("OnClick", function(_, _, down)
      if not down then ns.play("on") end
    end)
  end
  row.icon = row:CreateTexture(nil, "ARTWORK")
  row.icon:SetSize(18, 18)
  row.icon:SetPoint("LEFT", row, "LEFT", 2, 0)
  row.text = row:CreateFontString(nil, "ARTWORK", "GameFontNormal")
  row.text:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
  row:SetScript("OnEnter", function(self)
    if type(IsMouseButtonDown) == "function" and IsMouseButtonDown() then return end
    if type(GameTooltip) ~= "table" then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetHyperlink(self.deLink)
    GameTooltip:AddLine("Click to disenchant",
      COLORS.muted[1], COLORS.muted[2], COLORS.muted[3])
    GameTooltip:Show()
  end)
  row:SetScript("OnLeave", function()
    if type(GameTooltip) == "table" then GameTooltip:Hide() end
  end)
  return row
end

-- Lazily builds the window on Blizzard's own dialog template: gold
-- title, stock close button, escapable, draggable. Nil when the
-- template is missing, so sales still report over chat there.
function ns.ensureDEWindow()
  if ns.deWindow then return ns.deWindow end
  if type(CreateFrame) ~= "function" then return nil end
  if type(UIParent) ~= "table" then return nil end
  local ok, window = pcall(CreateFrame, "Frame", "VocVendorDEWindow",
    UIParent, "BasicFrameTemplateWithInset")
  if not ok or window == nil then return nil end
  window:SetSize(280, 120)
  window:SetPoint("CENTER")
  window:SetMovable(true)
  window:EnableMouse(true)
  window:RegisterForDrag("LeftButton")
  window:SetScript("OnDragStart", window.StartMoving)
  window:SetScript("OnDragStop", window.StopMovingOrSizing)
  if window.TitleText then window.TitleText:SetText("Disenchant") end
  -- BasicFrameTemplate ships its own CloseButton; an older template
  -- without one gets a stock close button (as in VocWarbank).
  if not window.CloseButton then
    local closeBtn = CreateFrame("Button", nil, window, "UIPanelCloseButton")
    if closeBtn then
      closeBtn:SetPoint("TOPRIGHT", window, "TOPRIGHT", -4, -4)
      closeBtn:SetScript("OnClick", function() window:Hide() end)
    end
  end
  local hint = window:CreateFontString(nil, "ARTWORK", "GameFontDisable")
  hint:SetPoint("TOPLEFT", window, "TOPLEFT", 16, -30)
  hint:SetText("Click an item to disenchant it")
  if type(UISpecialFrames) == "table" then
    table.insert(UISpecialFrames, "VocVendorDEWindow")
  end
  window:Hide() -- silent: the confirm below is for the player, not the build
  window:SetScript("OnHide", function() ns.play("close") end)
  ns.deWindow = window
  return window
end

-- Rebuilds the rows from the kept list and shows the window. Takes an
-- already-collected list (sale, slash, and compartment paths) or
-- collects when nil (bag updates): nil with a hidden window is a
-- no-op without a bag scan. Returns the row count, or nil when the
-- window cannot open (combat, missing template or spell, no secure
-- buttons): the caller reports over chat instead. The list stays
-- small by construction (gap-filtered old gear), so rows lay out
-- without a scroll frame.
function ns.refreshDEWindow(kept)
  local locked = type(InCombatLockdown) == "function" and InCombatLockdown()
  if kept == nil then
    if not ns.deWindow or not ns.deWindow:IsShown() then return 0 end
    if locked then return #ns.deRows end
    kept = ns.collectKeptDisenchantables()
  elseif locked then
    return nil
  end
  if #kept == 0 then
    if ns.deWindow and ns.deWindow:IsShown() then ns.deWindow:Hide() end
    return 0
  end
  if not ns.deSpellName() then return nil end
  local window = ns.ensureDEWindow()
  if not window then return nil end
  for i = #ns.deRows + 1, #kept do
    local row = newDERow(window)
    if not row then return nil end
    ns.deRows[#ns.deRows + 1] = row
  end
  for i, row in ipairs(ns.deRows) do
    local it = kept[i]
    if it then
      row.deLink, row.deBag, row.deSlot = it.link, it.bag, it.slot
      row.text:SetText(it.link)
      local _, _, _, _, _, _, _, _, _, texture = C_Item.GetItemInfo(it.link)
      if texture then
        row.icon:SetTexture(texture)
        row.icon:Show()
      else
        row.icon:Hide()
      end
      row:ClearAllPoints()
      row:SetPoint("TOPLEFT", window, "TOPLEFT", 16, -(52 + (i - 1) * 24))
      row:Show()
    else
      row:Hide()
    end
  end
  window:SetSize(280, 64 + #kept * 24)
  if not window:IsShown() then
    window:Show()
    ns.play("open")
  end
  return #kept
end

-- The kept report: the window is the notice, chat only when it cannot
-- open. `chatAlways` keeps the manual paths as informative as before
-- on window-less clients; the automatic sale honors announce.
function ns.reportKept(kept, chatAlways)
  if not kept or #kept == 0 then return end
  if ns.refreshDEWindow(kept) then return end
  if chatAlways or ns.opts().announce then
    ns.say(ns.keptLine(kept))
  end
end

-- Settings
ns.settingsBuilt = false
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
  check("keepDisenchantable", "Keep disenchantable gear",
    "Enchanters only: keep gear you could disenchant out of junk sales. Off sells it with junk like any other old gear.")
  ns.settingsBuilt = true
  ns.settingsCategory = category
end

function ns.openConfig()
  local ok = pcall(function() Settings.OpenToCategory(ns.settingsCategory:GetID()) end)
  if not ok then ns.say("open Settings > AddOns > VocVendor") end
end

-- Addon compartment (FAMILY.md "Addon compartment"): the toc names
-- these three globals; Blizzard's compartment menu calls them with
-- (addonName, button). The click opens the disenchant list while kept
-- gear waits, settings otherwise; hover follows the tooltip contract:
-- gold title, one line, the slash hint. Clients without the
-- compartment ignore the metadata.
function VocVendor_CompartmentClick()
  local kept = ns.collectKeptDisenchantables()
  if #kept > 0 and ns.refreshDEWindow(kept) then return end
  ns.openConfig()
end

function VocVendor_CompartmentEnter(_, button)
  if type(GameTooltip) ~= "table" then return end
  GameTooltip:SetOwner(button, "ANCHOR_LEFT")
  GameTooltip:SetText("VocVendor", COLORS.gold[1], COLORS.gold[2], COLORS.gold[3])
  GameTooltip:AddLine("Sells junk and repairs on every vendor visit. Junk is what you define.",
    COLORS.text[1], COLORS.text[2], COLORS.text[3], true)
  GameTooltip:AddLine("/vv sells junk now. /vv help lists the rest.",
    COLORS.muted[1], COLORS.muted[2], COLORS.muted[3], true)
  GameTooltip:Show()
end

function VocVendor_CompartmentLeave()
  if type(GameTooltip) == "table" then GameTooltip:Hide() end
end

-- Slash grammar shared by every Voc addon (FAMILY.md): the bare command
-- does the one main thing (the manual junk sale, same as the native
-- Sell Junk button), `config` opens the panel, `help` lists the rest,
-- and anything unrecognized prints help instead of acting.
ns.HELP = {
  "/vv            sell junk now",
  "/vv on|off     auto-sell junk on vendor visits",
  "/vv repair     repair now",
  "/vv disenchant open the disenchant list",
  "/vv config     open Settings > AddOns > VocVendor",
  "/vv help       this list (/vocvendor works too)",
}
function ns.help()
  ns.say("commands")
  for _, line in ipairs(ns.HELP) do print("  " .. line) end
end

-- Blizzard's slash dispatcher reads SLASH_* globals by name, so these
-- cannot be namespaced (they are declared in .luacheckrc instead).
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
    ns.play(o.autoSell and "on" or "off")
    ns.say("auto-sell junk " .. (o.autoSell and "on" or "off"))
  elseif msg == "repair" then
    if type(MerchantFrame) ~= "table" or not MerchantFrame:IsShown() then
      ns.say("open a vendor first")
      return
    end
    if not ns.repairNow() then ns.say("nothing to repair") end
  elseif msg == "disenchant" then
    local kept = ns.collectKeptDisenchantables()
    if #kept == 0 then
      ns.say("nothing to disenchant")
    else
      ns.reportKept(kept, true)
    end
  elseif msg == "config" then
    ns.openConfig()
  else
    ns.help()
  end
end

-- Events
ns.frame = CreateFrame("Frame")
ns.frame:RegisterEvent("ADDON_LOADED")
ns.frame:RegisterEvent("PLAYER_LOGIN")
ns.frame:RegisterEvent("MERCHANT_SHOW")
ns.frame:RegisterEvent("BAG_UPDATE")
ns.frame:SetScript("OnEvent", function(_, event, arg1)
  if event == "ADDON_LOADED" and arg1 == name then
    -- The client replaces the SavedVariables global with the loaded
    -- table after our file ran, so rebind or settings never persist.
    if type(VocVendorDB) ~= "table" then VocVendorDB = {} end
    ns.db = VocVendorDB
    ns.ensureSettings()
  elseif event == "PLAYER_LOGIN" then
    ns.ensureSettings() -- in case Settings wasn't up at ADDON_LOADED
  elseif event == "MERCHANT_SHOW" then
    ns.onMerchantShow()
  elseif event == "BAG_UPDATE" then
    ns.refreshDEWindow() -- the disenchant list tracks the bags live
  end
end)
