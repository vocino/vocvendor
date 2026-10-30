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
-- AND on the Sell Junk button, so the default stays safe. Checked
-- expansions join the same way, per expansion, across every item type:
-- whatever the vendor buys from a checked expansion sells. Dead
-- leftovers the vendor refuses (dead quest items, artifact-power
-- tokens) collect in the delete list instead, one confirm per item.
--
-- The expansion checklist. One opt-in row per expansion, all off:
-- checking an expansion vendors every vendorable item from it. IDs are
-- Blizzard's own expansion IDs (ExpansionLevel in the generated docs).
ns.CURRENT_EXPANSION_ID = 11 -- Midnight
ns.EXPANSIONS = {
  { id = 0, key = "Classic", label = "Classic" },
  { id = 1, key = "Tbc", label = "The Burning Crusade" },
  { id = 2, key = "Wotlk", label = "Wrath of the Lich King" },
  { id = 3, key = "Cata", label = "Cataclysm" },
  { id = 4, key = "Mop", label = "Mists of Pandaria" },
  { id = 5, key = "Wod", label = "Warlords of Draenor" },
  { id = 6, key = "Legion", label = "Legion" },
  { id = 7, key = "Bfa", label = "Battle for Azeroth" },
  { id = 8, key = "Sl", label = "Shadowlands" },
  { id = 9, key = "Df", label = "Dragonflight" },
  { id = 10, key = "Tww", label = "The War Within" },
  { id = 11, key = "Midnight", label = "Midnight" },
}
local defaults = {
  autoSell = true,        -- sell junk on every vendor visit
  autoRepair = true,      -- repair on every vendor visit
  guildRepair = true,     -- guild funds first, own gold as fallback
  announce = true,        -- chat line for sells and repairs
  junkOldGear = false,    -- old gear counts as junk
  oldGearIlvlGap = 30,    -- ...when this far below equipped
  oldGearBoE = false,     -- include Bind on Equip in old gear
  oldGearWarbound = false,-- include Warbound in old gear
  keepDisenchantable = true,
  compareAuction = true,  -- skip vendor sale when auction nets more
}
-- Per-expansion checklist: one opt-in boolean per expansion, all off.
-- (The old Midnight keep toggle is gone; an unchecked Midnight row
-- keeps current-expansion gear the same way.)
for _, e in ipairs(ns.EXPANSIONS) do defaults["sell" .. e.key] = false end
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

-- Auction math: vendor vs auction vs disenchant-then-auction. Other
-- pricing addons are guests (FAMILY.md principle 4): every call is
-- presence-gated and pcall-guarded, and no data means vendor wins.
-- Order follows install base: Auctionator, TradeSkillMaster, Oribos.
-- Blizzard takes a 5% cut on every auction sale, so gross prices are
-- compared net of it; ties keep the instant vendor sale.
ns.AH_CUT = 0.05
function ns.auctionNet(price)
  price = tonumber(price) or 0
  if price <= 0 then return 0 end
  return math.floor(price * (1 - ns.AH_CUT))
end
-- Guest price handles, resolved once per sale loop: presence is constant
-- for a visit, so per-item lookups reuse one resolution. Direct calls
-- resolve live, so late-loading guests just work.
function ns.priceGuests()
  local guests = {}
  local api = type(Auctionator) == "table" and Auctionator.API and Auctionator.API.v1 or nil
  if type(api) == "table" then guests.auctionator = api end
  if type(TSM_API) == "table" and type(TSM_API.GetCustomPriceValue) == "function"
    and type(TSM_API.ToItemString) == "function" then
    guests.tsm = TSM_API
  end
  if type(OEMarketInfo) == "function" then guests.oribos = OEMarketInfo end
  return guests
end
function ns.getAuctionPrice(link, itemID, guests)
  if not link and not itemID then return nil end
  if not itemID and link then itemID = ns.itemID(link) end
  guests = guests or ns.priceGuests()
  local api = guests.auctionator
  if api then
    if itemID and type(api.GetAuctionPriceByItemID) == "function" then
      local ok, price = pcall(api.GetAuctionPriceByItemID, "VocVendor", itemID)
      if ok and type(price) == "number" and price > 0 then return price end
    end
    if link and type(api.GetAuctionPriceByItemLink) == "function" then
      local ok, price = pcall(api.GetAuctionPriceByItemLink, "VocVendor", link)
      if ok and type(price) == "number" and price > 0 then return price end
    end
  end
  if guests.tsm and link then
    local okStr, itemStr = pcall(guests.tsm.ToItemString, link)
    if okStr and itemStr then
      local ok, price = pcall(guests.tsm.GetCustomPriceValue, "DBMarket", itemStr)
      if ok and type(price) == "number" and price > 0 then return price end
    end
  end
  if guests.oribos then
    local info = {}
    local ok = pcall(guests.oribos, link or itemID, info)
    if ok and type(info) == "table" then
      if tonumber(info.market) and info.market > 0 then return info.market end
      if tonumber(info.region) and info.region > 0 then return info.region end
    end
  end
  return nil
end
function ns.getDisenchantValue(link, itemID, guests)
  if not link and not itemID then return nil end
  if not itemID and link then itemID = ns.itemID(link) end
  guests = guests or ns.priceGuests()
  local api = guests.auctionator
  if api then
    if link and type(api.GetDisenchantPriceByItemLink) == "function" then
      local ok, price = pcall(api.GetDisenchantPriceByItemLink, "VocVendor", link)
      if ok and type(price) == "number" and price > 0 then return price end
    end
    if itemID and type(api.GetDisenchantPriceByItemID) == "function" then
      local ok, price = pcall(api.GetDisenchantPriceByItemID, "VocVendor", itemID)
      if ok and type(price) == "number" and price > 0 then return price end
    end
  end
  return nil
end
function ns.compareItem(vendor, auction, deValue)
  vendor = tonumber(vendor) or 0
  local auctionNet = tonumber(auction) and auction > 0 and ns.auctionNet(auction) or 0
  local deNet = tonumber(deValue) and deValue > 0 and ns.auctionNet(deValue) or 0
  if deNet > vendor and deNet > auctionNet then return "disenchant" end
  if auctionNet > vendor then return "auction" end
  return "vendor"
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
  -- The checklist is its own consent: no parent toggle gates it.
  local expJunk = ns.collectExpansionJunk()
  return { grayCount = grayCount, oldGear = oldGear, expJunk = expJunk }
end

-- Deferred sale accounting: every sale in a vendor visit adds its count
-- and copper here; MERCHANT_CLOSED reports one line for the whole visit.
ns.visitCount = 0
ns.visitEarned = 0

function ns.recordSale(n, earned)
  ns.visitCount = ns.visitCount + (n or 0)
  ns.visitEarned = ns.visitEarned + (earned or 0)
end

-- One line per vendor visit. Nil when nothing sold.
function ns.visitLine(count, earned)
  if (count or 0) == 0 then return nil end
  local what = count == 1 and "1 item" or count .. " items"
  return "sold " .. what .. " for " .. ns.moneyString(earned or 0)
end

-- Visit close: the single deferred line. Resets either way, so a visit
-- never reports twice.
function ns.flushVisit()
  local line = ns.visitLine(ns.visitCount, ns.visitEarned)
  ns.visitCount, ns.visitEarned = 0, 0
  if line and ns.opts().announce then ns.say(line) end
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
-- a set, or that the vendor won't buy, stays put and the loop moves on.
-- A sale that fails stops the loop: the failing item and everything
-- after it come back as the leftover list with per-row reasons, and the
-- caller surfaces them. Nothing retries: a failed click left the item
-- in the bags, and clicking again only spams the server.
-- Quiet: the caller composes the announcement.
-- Returns count, copper, and the leftover list.
function ns.sellOldGearItems(items)
  local n, value = 0, 0
  local leftover = {}
  local guests = ns.priceGuests()
  if type(C_Container) ~= "table" then return n, value, leftover end
  if type(C_Container.GetContainerItemLink) ~= "function" then return n, value, leftover end
  items = items or {}
  for i, it in ipairs(items) do
    local reason = nil
    if C_Container.GetContainerItemLink(it.bag, it.slot) ~= it.link then
      reason = "moved"
    elseif ns.inEquipmentSet(it.bag, it.slot) then
      reason = "in equipment set"
    elseif not ns.slotHasValue(it.bag, it.slot) then
      reason = "vendor won't buy"
    elseif ns.opts().compareAuction then
      local auction = ns.getAuctionPrice(it.link, nil, guests)
      local deValue = ns.isDisenchantable(it.link) and ns.getDisenchantValue(it.link, nil, guests) or nil
      local verdict = ns.compareItem(it.price, auction, deValue)
      if verdict == "auction" then
        reason = "auction worth more (" .. ns.moneyString(ns.auctionNet(auction)) .. " net)"
      elseif verdict == "disenchant" then
        reason = "disenchant worth more (" .. ns.moneyString(ns.auctionNet(deValue)) .. " net)"
      end
    end
    if reason then
      leftover[#leftover + 1] = { link = it.link, reason = reason }
    else
      local ok = pcall(C_Container.UseContainerItem, it.bag, it.slot)
      local still = false
      if type(C_Container.GetContainerItemLink) == "function" then
        local okLink, now = pcall(C_Container.GetContainerItemLink, it.bag, it.slot)
        still = okLink and now == it.link
      end
      if ok and not still then
        n = n + 1
        value = value + (it.price or 0)
      else
        leftover[#leftover + 1] = { link = it.link,
          reason = (not ok) and "sell failed" or "still in bags" }
        for j = i + 1, #items do
          leftover[#leftover + 1] = { link = items[j].link, reason = "sale stopped" }
        end
        break
      end
    end
  end
  return n, value, leftover
end

-- The leftover report: a header through the addon voice, then one row
-- per item with its reason. Always shown: a failed sale is information,
-- not an announcement.
function ns.reportLeftover(leftover)
  if not leftover or #leftover == 0 then return end
  local what = #leftover == 1 and "1 item" or #leftover .. " items"
  ns.say("couldn't sell " .. what .. ":")
  for _, it in ipairs(leftover) do
    print("  " .. tostring(it.link) .. " (" .. it.reason .. ")")
  end
end

-- Numeric item ID for a bag link, nil when the client cannot say.
function ns.itemID(link)
  if type(C_Item) ~= "table" then return nil end
  if type(C_Item.GetItemInfoInstant) ~= "function" then return nil end
  local ok, id = pcall(C_Item.GetItemInfoInstant, link)
  if ok and type(id) == "number" then return id end
  return nil
end

-- Merges identical junk by item ID into summary groups with summed
-- quantity and total, first-seen order. Links without a known ID merge
-- by link, so uncached items still group instead of scattering.
function ns.mergeByID(items)
  local groups, byID = {}, {}
  for _, it in ipairs(items or {}) do
    local id = ns.itemID(it.link) or it.link
    local g = byID[id]
    if not g then
      g = { link = it.link, qty = 0, total = 0 }
      byID[id] = g
      groups[#groups + 1] = g
    end
    g.qty = g.qty + 1
    g.total = g.total + (it.price or 0)
  end
  return groups
end

-- One merged summary row: quantity, link, and summed total.
function ns.mergedLine(g)
  local what = g.qty == 1 and g.link or g.qty .. "x " .. g.link
  return "  " .. what .. " for " .. ns.moneyString(g.total)
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
  local dead = ns.collectDeadItems()
  if junk.grayCount == 0 and #junk.oldGear == 0 and #junk.expJunk == 0
    and #kept == 0 and #dead == 0 then
    return
  end
  local earned = 0
  local nGray = 0
  ns.reportKept(kept)
  ns.reportDead(dead)
  if junk.grayCount > 0 then
    earned = ns.sellGrays()
    nGray = junk.grayCount
  end
  local nOld, oldValue, leftover = ns.sellOldGearItems(junk.oldGear)
  local nExp, expValue, leftoverExp = ns.sellOldGearItems(junk.expJunk)
  for _, it in ipairs(leftoverExp) do leftover[#leftover + 1] = it end
  ns.reportLeftover(leftover)
  if nGray + nOld + nExp > 0 then
    ns.sellSound()
    ns.recordSale(nGray + nOld + nExp, earned + oldValue + expValue)
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
  -- A visit whose close we missed (reload mid-visit) still gets its one
  -- line before the new visit starts counting.
  ns.flushVisit()
  ns.hookJunkButton()
  -- Sell first: junk gold pays for the repair that follows.
  local o = ns.opts()
  if o.autoSell then ns.autoSell() end
  if o.autoRepair then ns.repairNow() end
end

-- Visit close: the one deferred line for everything sold since SHOW.
function ns.onMerchantClosed()
  ns.flushVisit()
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
  local setEnabled = function(on)
    if type(MerchantSellAllJunkButton.SetEnabled) == "function" then
      MerchantSellAllJunkButton:SetEnabled(on)
    end
  end
  -- Grays alone enable the button: one Blizzard call decides it, and the
  -- old-gear bag scan runs only when grays are absent and old gear counts.
  if type(C_MerchantFrame) == "table"
    and type(C_MerchantFrame.GetNumJunkItems) == "function" then
    local ok, n = pcall(C_MerchantFrame.GetNumJunkItems)
    if ok and type(n) == "number" and n > 0 then
      setEnabled(true)
      return
    end
  end
  if not ns.opts().junkOldGear then
    setEnabled(false)
    return
  end
  local junk = ns.collectJunk()
  setEnabled(junk.grayCount > 0 or #junk.oldGear > 0 or #junk.expJunk > 0)
end

-- Manual path (native button or /vv): same definition as auto-sell, but
-- old gear goes through the itemized dry-run first. Grays alone keep
-- Blizzard's original click and popup.
function ns.onJunkButtonClick(button)
  local kept = ns.collectKeptDisenchantables()
  local dead = ns.collectDeadItems()
  local junk = ns.collectJunk()
  if junk.grayCount == 0 and #junk.oldGear == 0 and #junk.expJunk == 0 then
    if #kept > 0 then
      ns.reportKept(kept, true)
    elseif #dead > 0 then
      ns.reportDead(dead, true)
    else
      ns.say("nothing to sell")
    end
    return
  end
  if #junk.oldGear == 0 and #junk.expJunk == 0 then
    if type(ns.blizzJunkClick) == "function" then
      ns.blizzJunkClick(button)
    end
    return
  end
  local sale = {}
  for _, list in ipairs({ junk.oldGear, junk.expJunk }) do
    for _, it in ipairs(list) do sale[#sale + 1] = it end
  end
  local total = 0
  for _, it in ipairs(sale) do total = total + (it.price or 0) end
  ns.say("junk to sell (" .. junk.grayCount .. " gray, "
    .. #junk.oldGear .. " old gear, " .. #junk.expJunk .. " expansion):")
  for _, g in ipairs(ns.mergeByID(sale)) do print(ns.mergedLine(g)) end
  StaticPopup_Show("VOCVENDOR_SELL_JUNK",
    junk.grayCount + #sale, ns.moneyString(total),
    { grayCount = junk.grayCount, oldGear = junk.oldGear,
      expJunk = junk.expJunk })
  ns.reportKept(kept, true)
  ns.reportDead(dead, true)
end

-- Confirm handler for the dry-run popup: sells the configured junk.
function ns.sellJunkNow(data)
  data = data or {}
  local earned = 0
  local nGray = 0
  ns.reportKept(ns.collectKeptDisenchantables())
  if (data.grayCount or 0) > 0 then
    earned = ns.sellGrays()
    nGray = data.grayCount
  end
  local nOld, oldValue, leftover = ns.sellOldGearItems(data.oldGear)
  local nExp, expValue, leftoverExp = ns.sellOldGearItems(data.expJunk)
  for _, it in ipairs(leftoverExp) do leftover[#leftover + 1] = it end
  ns.reportLeftover(leftover)
  if nGray + nOld + nExp > 0 then
    ns.sellSound()
    ns.recordSale(nGray + nOld + nExp, earned + oldValue + expValue)
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

-- Delete confirm: one dead item per dialog, named by link. The Accept
-- click is the hardware event the container delete needs.
StaticPopupDialogs["VOCVENDOR_DELETE_ITEM"] = {
  text = "Delete %s?",
  button1 = "Delete",
  button2 = "Cancel",
  OnAccept = function(_, data) ns.deleteDeadNow(data) end,
  timeout = 0,
  whileDead = true,
  hideOnEscape = true,
  showAlert = true,
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

-- Expansion data: the item's own expansion ID (C_Item.GetItemInfo
-- return 15, verified against Blizzard's generated docs on live and
-- forever). Fail closed: an unknown item, or an uncached one, is never
-- expansion junk and never a dead item. Grays are unaffected:
-- Blizzard's own sale takes them all.
function ns.expansionID(link)
  if type(C_Item) ~= "table" then return nil end
  if type(C_Item.GetItemInfo) ~= "function" then return nil end
  local r = { pcall(C_Item.GetItemInfo, link) }
  if not r[1] then return nil end
  return tonumber(r[16]) -- 15th return, past the pcall flag
end
function ns.expansionChecked(id)
  for _, e in ipairs(ns.EXPANSIONS) do
    if e.id == id then return ns.opts()["sell" .. e.key] == true end
  end
  return false
end

-- Quest guard: quest-class items and quest-bound items keep unless the
-- quest is complete (dead quest items may sell, or collect for
-- confirmed destroy). Fail closed: without data the item keeps.
function ns.questKeeps(link)
  if type(C_Item) ~= "table" then return true end
  if type(C_Item.GetItemInfo) ~= "function" then return true end
  local r = { pcall(C_Item.GetItemInfo, link) }
  if not r[1] then return true end
  local classID, bindType = r[13], r[15] -- 12th and 14th returns
  if classID ~= 12 and bindType ~= 4 then return false end
  return not ns.isDeadQuestItem(link)
end

-- Dead quest items. Ports VocWarbank's detector: the completed-quest
-- title set is built once per session from C_QuestLog, and each link's
-- tooltip is parsed for one of those titles. Definitive-false: no
-- completed set, no tooltip, no match -> alive, keeps.
ns.questTip = nil
ns.deadQuestTitles = nil
ns.deadQuestMemo = {}
function ns.buildDeadQuestTitles()
  if type(C_QuestLog) ~= "table" then return end
  if type(C_QuestLog.GetAllCompletedQuestIDs) ~= "function" then return end
  if type(C_QuestLog.GetTitleForQuestID) ~= "function" then return end
  local ok, ids = pcall(C_QuestLog.GetAllCompletedQuestIDs)
  if not ok or type(ids) ~= "table" then return end
  local titles = {}
  for _, id in ipairs(ids) do
    local okTitle, title = pcall(C_QuestLog.GetTitleForQuestID, id)
    if okTitle and type(title) == "string" and title ~= "" then
      titles[title] = true
    end
  end
  ns.deadQuestTitles = titles
end
function ns.refreshQuests()
  ns.deadQuestTitles = nil
  ns.deadQuestMemo = {}
end
function ns.questTitleFromLink(link)
  if not link then return nil end
  if ns.deadQuestMemo[link] then return ns.deadQuestMemo[link] end
  if type(CreateFrame) ~= "function" then return nil end
  if type(UIParent) ~= "table" then return nil end
  if not ns.questTip then
    local ok, tip = pcall(CreateFrame, "GameTooltip", "VocVendorQuestTip",
      UIParent, "GameTooltipTemplate")
    if not ok or tip == nil then return nil end
    ns.questTip = tip
  end
  ns.questTip:SetOwner(UIParent, "ANCHOR_NONE")
  ns.questTip:ClearLines()
  if not pcall(ns.questTip.SetHyperlink, ns.questTip, link) then return nil end
  for i = 2, ns.questTip:NumLines() do
    local line = _G["VocVendorQuestTipTextLeft" .. i]
    local text = line and line.GetText and line:GetText()
    if text and text ~= "" and ns.deadQuestTitles[text] then
      ns.deadQuestMemo[link] = text
      return text
    end
  end
  return nil
end
function ns.isDeadQuestItem(link)
  if ns.deadQuestTitles == nil then ns.buildDeadQuestTitles() end
  if ns.deadQuestTitles == nil then return false end
  return ns.questTitleFromLink(link) ~= nil
end

-- Artifact-power tokens (Legion and kin): no vendor price, no use once
-- their expansion is done. C_Item.IsArtifactPowerItem names them
-- directly. Missing API or failed call lists nothing, never.
function ns.isArtifactPower(link)
  if type(C_Item) ~= "table" then return false end
  if type(C_Item.IsArtifactPowerItem) ~= "function" then return false end
  local ok, v = pcall(C_Item.IsArtifactPowerItem, link)
  return ok and v == true
end

-- True only when the client positively says the vendor takes nothing
-- from this slot. A missing API or a failed call is not proof, so it
-- keeps (false) instead of listing for destroy.
function ns.slotRefused(bag, slot)
  if type(C_Container) ~= "table" then return false end
  if type(C_Container.GetContainerItemInfo) ~= "function" then return false end
  local ok, info = pcall(C_Container.GetContainerItemInfo, bag, slot)
  if not ok or type(info) ~= "table" then return false end
  return info.hasNoValue == true
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
-- weapons/armor with a vendor price. It cannot see Blizzard's per-item
-- disenchant flag (set on some gear, e.g. class-hall pieces) or the
-- caster's skill, so a listed row can still fail at the cast with
-- "That item is not a valid target"; those sell by hand. Uncached items
-- fail closed, like every other unknown in this file.
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
--
-- Collection safety gate: true when the item teaches something the
-- player lacks -- a transmog appearance, a toy, or a pet -- so it is
-- never junk, no matter how far below the equipped piece it sits.
-- Fail closed: an unknown item, or a missing API, keeps the item.
-- Every name here is verified against both clients (see AGENTS.md);
-- each check is presence-gated so the gate degrades to keeping.
function ns.isUncollectedCollectible(link, memo)
  if type(C_Item) ~= "table" then return true end
  if type(C_Item.GetItemInfoInstant) ~= "function" then return true end
  local okInst, itemID = pcall(C_Item.GetItemInfoInstant, link)
  if not okInst or type(itemID) ~= "number" then return true end
  -- Per-scan memo: appearance answers repeat per item ID, and they cannot
  -- change mid-sweep. Only computed results memoize; unknown items still
  -- fail closed every time.
  if memo and memo[itemID] ~= nil then return memo[itemID] end
  local known = ns.checkCollectible(itemID, link)
  if memo then memo[itemID] = known end
  return known
end

-- True when the item teaches something the player lacks: a transmog
-- appearance, a toy, or a pet. Fail closed: an unknown item, or a
-- missing API, keeps the item.
function ns.checkCollectible(itemID, link)
  local cosmetic = false
  if type(C_Item.IsCosmeticItem) == "function" then
    local ok, v = pcall(C_Item.IsCosmeticItem, itemID)
    if not ok then return true end
    cosmetic = v == true
  end
  local teachesSet = false
  if type(C_Item.GetItemLearnTransmogSet) == "function" then
    local ok, v = pcall(C_Item.GetItemLearnTransmogSet, itemID)
    if not ok then return true end
    teachesSet = v ~= nil
  end
  if cosmetic or teachesSet then
    if type(C_TransmogCollection) ~= "table" then return true end
    if type(C_TransmogCollection.PlayerHasTransmogByItemInfo) ~= "function" then
      return true
    end
    local ok, has = pcall(C_TransmogCollection.PlayerHasTransmogByItemInfo, link)
    if not ok then return true end
    if not has then return true end
  end
  if type(C_ToyBox) == "table"
    and type(C_ToyBox.GetToyInfo) == "function" then
    local ok, info = pcall(C_ToyBox.GetToyInfo, itemID)
    if not ok then return true end
    if info ~= nil then
      if type(PlayerHasToy) ~= "function" then return true end
      local okHas, has = pcall(PlayerHasToy, itemID)
      if not okHas then return true end
      if not has then return true end
    end
  end
  if type(C_PetJournal) == "table"
    and type(C_PetJournal.GetPetInfoByItemID) == "function"
    and type(C_PetJournal.GetNumCollectedInfo) == "function" then
    local r = { pcall(C_PetJournal.GetPetInfoByItemID, itemID) }
    if not r[1] then return true end
    local speciesID = tonumber(r[14]) or 0
    if speciesID ~= 0 then
      local okN, owned = pcall(C_PetJournal.GetNumCollectedInfo, speciesID)
      if not okN then return true end
      if (tonumber(owned) or 0) == 0 then return true end
    end
  end
  return false
end
function ns.isOldGear(link, gap, ignoreDE, scan)
  if ns.isUncollectedCollectible(link, scan and scan.memo) then return false end
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
  if not ignoreDE and o.keepDisenchantable and ns.isDisenchantable(link) then
    -- canDE is the per-scan hoist; nil resolves live for direct calls.
    local canDE = scan and scan.canDE
    if canDE == nil then canDE = ns.canDisenchant() end
    if canDE then return false end
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
  -- Per-scan hoists: the enchanter gate is player-level, and collectible
  -- lookups repeat per item ID, so resolve and memoize once per sweep.
  local scan = { canDE = ns.canDisenchant(), memo = {} }
  for bag = 0, NUM_BAG_SLOTS do
    local slots = C_Container.GetContainerNumSlots(bag)
    for slot = 1, slots do
      local link = C_Container.GetContainerItemLink(bag, slot)
      if link and not ns.inEquipmentSet(bag, slot)
        and ns.slotHasValue(bag, slot)
        and ns.isOldGear(link, gap, nil, scan) then
        local _, _, _, _, _, _, _, _, _, _, sellPrice = C_Item.GetItemInfo(link)
        out[#out + 1] = { link = link, bag = bag, slot = slot,
          price = sellPrice or 0 }
      end
    end
  end
  return out
end

-- Expansion junk: everything the vendor buys from a checked expansion,
-- whatever the type. The check on the row is the consent, so the ilvl
-- gap does not apply here; every keep gate does (equipment sets,
-- transmog/toy/pet, Pawn upgrades, live quest items, heirlooms), and
-- disenchantables divert to the disenchant list first unless ignoreDE.
function ns.isExpansionJunk(link, bag, slot, ignoreDE, scan)
  local id = ns.expansionID(link)
  if id == nil or not ns.expansionChecked(id) then return false end
  if ns.inEquipmentSet(bag, slot) then return false end
  if not ns.slotHasValue(bag, slot) then return false end
  if ns.isUncollectedCollectible(link, scan and scan.memo) then return false end
  local _, _, quality, _, _, _, _, _, _, _, sellPrice = C_Item.GetItemInfo(link)
  if not quality then return false end
  if quality == Enum.ItemQuality.Heirloom then return false end
  if not sellPrice or sellPrice == 0 then return false end
  if ns.questKeeps(link) then return false end
  if ns.pawnSaysUpgrade(link) then return false end
  if not ignoreDE and ns.opts().keepDisenchantable and ns.isDisenchantable(link) then
    local canDE = scan and scan.canDE
    if canDE == nil then canDE = ns.canDisenchant() end
    if canDE then return false end
  end
  return true
end

function ns.collectExpansionJunk()
  local out = {}
  local scan = { canDE = ns.canDisenchant(), memo = {} }
  for bag = 0, NUM_BAG_SLOTS do
    local slots = C_Container.GetContainerNumSlots(bag)
    for slot = 1, slots do
      local link = C_Container.GetContainerItemLink(bag, slot)
      if link and ns.isExpansionJunk(link, bag, slot, nil, scan) then
        local _, _, _, _, _, _, _, _, _, _, sellPrice = C_Item.GetItemInfo(link)
        out[#out + 1] = { link = link, bag = bag, slot = slot,
          price = sellPrice or 0 }
      end
    end
  end
  return out
end

-- Dead items: checked-expansion leftovers the vendor refuses, proven
-- dead: a completed quest's item, or an artifact-power token. One
-- confirm per item in the delete list; nothing else qualifies, and an
-- uncached item never does.
function ns.deadReason(link, bag, slot)
  local id = ns.expansionID(link)
  if id == nil or not ns.expansionChecked(id) then return nil end
  if ns.inEquipmentSet(bag, slot) then return nil end
  if not ns.slotRefused(bag, slot) then
    local _, _, _, _, _, _, _, _, _, _, sellPrice = C_Item.GetItemInfo(link)
    if sellPrice and sellPrice > 0 then return nil end
  end
  local _, _, quality = C_Item.GetItemInfo(link)
  if not quality then return nil end
  if ns.isUncollectedCollectible(link) then return nil end
  if ns.isDeadQuestItem(link) then return "quest complete" end
  if ns.isArtifactPower(link) then return "artifact power" end
  return nil
end

function ns.collectDeadItems()
  local out = {}
  for bag = 0, NUM_BAG_SLOTS do
    local slots = C_Container.GetContainerNumSlots(bag)
    for slot = 1, slots do
      local link = C_Container.GetContainerItemLink(bag, slot)
      if link then
        local reason = ns.deadReason(link, bag, slot)
        if reason then
          out[#out + 1] = { link = link, bag = bag, slot = slot,
            reason = reason }
        end
      end
    end
  end
  return out
end

-- Gear kept for disenchanting: items that would sell but for the
-- disenchant exclusion, from the old-gear gap or a checked expansion.
-- Only non-empty when the toggle is on, the player can disenchant, and
-- something is actually for sale; everyone else skips the scan.
function ns.anyExpansionChecked()
  for _, e in ipairs(ns.EXPANSIONS) do
    if ns.opts()["sell" .. e.key] == true then return true end
  end
  return false
end
function ns.collectKeptDisenchantables()
  local o = ns.opts()
  if not o.keepDisenchantable then return {} end
  if not ns.canDisenchant() then return {} end
  if not o.junkOldGear and not ns.anyExpansionChecked() then return {} end
  local gap = o.oldGearIlvlGap or 30
  local out = {}
  local scan = { canDE = true, memo = {} }
  for bag = 0, NUM_BAG_SLOTS do
    local slots = C_Container.GetContainerNumSlots(bag)
    for slot = 1, slots do
      local link = C_Container.GetContainerItemLink(bag, slot)
      if link and not ns.inEquipmentSet(bag, slot)
        and ns.isDisenchantable(link)
        and ((o.junkOldGear and ns.isOldGear(link, gap, true, scan))
          or ns.isExpansionJunk(link, bag, slot, true, scan)) then
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

-- Auction hints for kept gear: an item whose own auction net beats its
-- disenchant net is worth listing, not breaking. Returns hint lines.
function ns.keptAuctionHints(kept)
  local hints = {}
  if not ns.opts().compareAuction then return hints end
  local guests = ns.priceGuests()
  for _, it in ipairs(kept or {}) do
    local auction = ns.getAuctionPrice(it.link, nil, guests)
    if auction then
      local deValue = ns.getDisenchantValue(it.link, nil, guests)
      if not deValue or ns.auctionNet(auction) > ns.auctionNet(deValue) then
        hints[#hints + 1] = "  " .. tostring(it.link) .. " worth " .. ns.moneyString(ns.auctionNet(auction)) .. " net on auction"
      end
    end
  end
  return hints
end
-- The kept report: the window is the notice, chat only when it cannot
-- open. `chatAlways` keeps the manual paths as informative as before
-- on window-less clients; the automatic sale honors announce.
function ns.reportKept(kept, chatAlways)
  if not kept or #kept == 0 then return end
  if ns.refreshDEWindow(kept) then return end
  if chatAlways or ns.opts().announce then
    ns.say(ns.keptLine(kept))
    for _, h in ipairs(ns.keptAuctionHints(kept)) do print(h) end
  end
end

-- Delete list. Dead items the vendor refuses are actionable, like kept
-- gear: one row per item, and clicking a row asks once, then deletes
-- that bag slot. The confirm dialog owns the protected calls
-- (PickupContainerItem + DeleteCursorItem need the click's hardware
-- event, like every container move): the row only names the item.
-- Deletions are always announced; a failed delete reports instead of
-- retrying, like a failed sale.
ns.deadWindow = nil
ns.deadRows = {}

function ns.ensureDeadWindow()
  if ns.deadWindow then return ns.deadWindow end
  if type(CreateFrame) ~= "function" then return nil end
  if type(UIParent) ~= "table" then return nil end
  local ok, window = pcall(CreateFrame, "Frame", "VocVendorDeadWindow",
    UIParent, "BasicFrameTemplateWithInset")
  if not ok or window == nil then return nil end
  window:SetSize(280, 120)
  window:SetPoint("CENTER")
  window:SetMovable(true)
  window:EnableMouse(true)
  window:RegisterForDrag("LeftButton")
  window:SetScript("OnDragStart", window.StartMoving)
  window:SetScript("OnDragStop", window.StopMovingOrSizing)
  if window.TitleText then window.TitleText:SetText("Delete") end
  if not window.CloseButton then
    local closeBtn = CreateFrame("Button", nil, window, "UIPanelCloseButton")
    if closeBtn then
      closeBtn:SetPoint("TOPRIGHT", window, "TOPRIGHT", -4, -4)
      closeBtn:SetScript("OnClick", function() window:Hide() end)
    end
  end
  local hint = window:CreateFontString(nil, "ARTWORK", "GameFontDisable")
  hint:SetPoint("TOPLEFT", window, "TOPLEFT", 16, -30)
  hint:SetText("Dead items the vendor won't buy. Click to delete (confirms first)")
  if type(UISpecialFrames) == "table" then
    table.insert(UISpecialFrames, "VocVendorDeadWindow")
  end
  window:Hide()
  window:SetScript("OnHide", function() ns.play("close") end)
  ns.deadWindow = window
  return window
end

-- One row: the item's icon, link, and why it is dead. Plain buttons:
-- the dialog behind the click does the protected work.
local function newDeadRow(window)
  local ok, row = pcall(CreateFrame, "Button", nil, window)
  if not ok or row == nil then return nil end
  row:SetSize(248, 22)
  row.icon = row:CreateTexture(nil, "ARTWORK")
  row.icon:SetSize(18, 18)
  row.icon:SetPoint("LEFT", row, "LEFT", 2, 0)
  row.text = row:CreateFontString(nil, "ARTWORK", "GameFontNormal")
  row.text:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
  row:SetScript("OnClick", function(self)
    if type(InCombatLockdown) == "function" and InCombatLockdown() then
      ns.say("can't delete during combat")
      return
    end
    StaticPopup_Show("VOCVENDOR_DELETE_ITEM", self.deLink, nil,
      { link = self.deLink })
  end)
  if type(row.HookScript) == "function" then
    row:HookScript("OnClick", function(_, _, down)
      if not down then ns.play("on") end
    end)
  end
  return row
end

function ns.refreshDeadWindow(dead)
  local locked = type(InCombatLockdown) == "function" and InCombatLockdown()
  if dead == nil then
    if not ns.deadWindow or not ns.deadWindow:IsShown() then return 0 end
    if locked then return #ns.deadRows end
    dead = ns.collectDeadItems()
  elseif locked then
    return nil
  end
  if #dead == 0 then
    if ns.deadWindow and ns.deadWindow:IsShown() then ns.deadWindow:Hide() end
    return 0
  end
  local window = ns.ensureDeadWindow()
  if not window then return nil end
  for i = #ns.deadRows + 1, #dead do
    local row = newDeadRow(window)
    if not row then return nil end
    ns.deadRows[#ns.deadRows + 1] = row
  end
  for i, row in ipairs(ns.deadRows) do
    local it = dead[i]
    if it then
      row.deLink = it.link
      row.text:SetText(it.link .. " (" .. it.reason .. ")")
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
  window:SetSize(280, 64 + #dead * 24)
  if not window:IsShown() then
    window:Show()
    ns.play("open")
  end
  return #dead
end

function ns.deleteDeadNow(data)
  local link = data and data.link
  if not link then return end
  if type(C_Container) ~= "table" then return end
  if type(C_Container.PickupContainerItem) ~= "function" then
    ns.say("can't delete here")
    return
  end
  if type(DeleteCursorItem) ~= "function" then
    ns.say("can't delete here")
    return
  end
  if type(InCombatLockdown) == "function" and InCombatLockdown() then
    ns.say("can't delete during combat")
    return
  end
  local bag, slot = ns.findKeptSlot(link)
  if bag == nil then return end
  local okPick = pcall(C_Container.PickupContainerItem, bag, slot)
  local okDel = okPick and pcall(DeleteCursorItem)
  local gone = false
  if okDel then
    local okLink, now = pcall(C_Container.GetContainerItemLink, bag, slot)
    gone = okLink and now ~= link
  end
  if gone then
    ns.play("sell")
    ns.say("deleted " .. link)
  else
    -- A picked-up item left on the cursor goes back to its slot.
    pcall(C_Container.PickupContainerItem, bag, slot)
    ns.say("couldn't delete " .. link)
  end
end

function ns.reportDead(dead, chatAlways)
  if not dead or #dead == 0 then return end
  if ns.refreshDeadWindow(dead) then return end
  if chatAlways or ns.opts().announce then
    local what = #dead == 1 and "1 item" or #dead .. " items"
    ns.say("dead items the vendor won't buy (" .. what .. "):")
    for _, it in ipairs(dead) do print("  " .. tostring(it.link)) end
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
  check("compareAuction", "Compare auction prices",
    "Skip vendor sale when auction data says the auction house or disenchanting nets more. Needs Auctionator, TradeSkillMaster, or Oribos Exchange.")
  check("keepDisenchantable", "Keep disenchantable gear",
    "Enchanters only: keep gear you could disenchant out of junk sales. Off sells it with junk like any other old gear.")
  for _, e in ipairs(ns.EXPANSIONS) do
    local label = "Vendor " .. e.label .. " items"
    if e.id == ns.CURRENT_EXPANSION_ID then label = label .. " (current)" end
    check("sell" .. e.key, label,
      "Sell everything the vendor buys from " .. e.label .. " when checked. Dead leftovers the vendor refuses collect for confirmed delete instead.")
  end
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
  local dead = ns.collectDeadItems()
  if #dead > 0 and ns.refreshDeadWindow(dead) then return end
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

-- Same-job addons that also work the merchant. When one is loaded we
-- warn once and stand down instead of fighting it over every sale;
-- either addon alone does the job, both together double-sell nothing
-- but double-report everything.
ns.RIVALS = { "Scrap", "Dejunk", "SellJunk", "JunkIt" }
ns.rivalWarned = false

function ns.findRival()
  if type(C_AddOns) ~= "table" then return nil end
  if type(C_AddOns.IsAddOnLoaded) ~= "function" then return nil end
  for _, other in ipairs(ns.RIVALS) do
    local ok, loaded = pcall(C_AddOns.IsAddOnLoaded, other)
    if ok and loaded then return other end
  end
  return nil
end

-- Warns once per session and pauses auto-sell while the rival is
-- loaded. The stand-down names its exact re-enable command, so the
-- player is never left wondering how to get the job back.
function ns.checkRivals()
  if ns.rivalWarned then return end
  local rival = ns.findRival()
  if not rival then return end
  ns.rivalWarned = true
  if ns.opts().autoSell then
    ns.opts().autoSell = false
    ns.say(rival .. " also sells junk: auto-sell paused (turn back on with /vv on)")
  else
    ns.say(rival .. " also sells junk: auto-sell stays off (turn on with /vv on)")
  end
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
  "/vv destroy    delete dead expansion items (confirms each)",
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
    ns.say("auto-sell junk " .. (o.autoSell and "on" or "off (turn back on with /vv on)"))
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
  elseif msg == "destroy" then
    local dead = ns.collectDeadItems()
    if #dead == 0 then
      ns.say("nothing to delete")
    else
      ns.reportDead(dead, true)
    end
  elseif msg == "config" then
    ns.openConfig()
  else
    ns.help()
  end
end

-- Events
---@type Frame
ns.frame = CreateFrame("Frame")
ns.frame:RegisterEvent("ADDON_LOADED")
ns.frame:RegisterEvent("PLAYER_LOGIN")
ns.frame:RegisterEvent("MERCHANT_SHOW")
ns.frame:RegisterEvent("MERCHANT_CLOSED")
ns.frame:RegisterEvent("BAG_UPDATE")
ns.frame:RegisterEvent("QUEST_TURNED_IN")
ns.frame:SetScript("OnEvent", function(_, event, arg1)
  if event == "ADDON_LOADED" and arg1 == name then
    -- The client replaces the SavedVariables global with the loaded
    -- table after our file ran, so rebind or settings never persist.
    if type(VocVendorDB) ~= "table" then VocVendorDB = {} end
    ns.db = VocVendorDB
    ns.ensureSettings()
    ns.checkRivals() -- a same-job addon loaded before us stands us down
  elseif event == "ADDON_LOADED" then
    ns.checkRivals() -- a same-job addon loaded after us does the same
  elseif event == "PLAYER_LOGIN" then
    ns.ensureSettings() -- in case Settings wasn't up at ADDON_LOADED
    ns.checkRivals()
  elseif event == "MERCHANT_SHOW" then
    ns.onMerchantShow()
  elseif event == "MERCHANT_CLOSED" then
    ns.onMerchantClosed()
  elseif event == "BAG_UPDATE" then
    ns.refreshDEWindow() -- the disenchant list tracks the bags live
    ns.refreshDeadWindow() -- and so does the delete list
  elseif event == "QUEST_TURNED_IN" then
    ns.refreshQuests() -- a new completion changes what counts as dead
  end
end)
