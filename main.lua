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
--     classID(12), subclassID(13), bindType(14), expansionID(15), setID(16),
--     isCraftingReagent(17), ... (ItemDocumentation).
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

-- ======= Sounds =======
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

-- ======= Palette =======
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

-- ======= Junk definition and defaults =======
-- The junk definition. Grays are always junk (Blizzard's own baseline,
-- and what the native button's tooltip promises), except crafting
-- reagents, which always keep. Old gear joins the
-- definition only when the player opts in: then it sells automatically
-- AND on the Sell Junk button, so the default stays safe. Checked
-- expansions join the same way, per expansion, across every item type:
-- whatever the vendor buys from a checked expansion sells, except
-- crafting reagents and confidently placed consumables, which keep. Dead
-- leftovers the vendor refuses (dead quest items, artifact-power
-- tokens) collect in the delete list instead, one confirm per item.
-- The checklist is Retail-only (Compat.hasExpansions): Forever has no
-- expansions, so the rows stay hidden there and every collector below
-- stays empty.
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
  sellVendorWins = false, -- sell anything the vendor buys above auction net
  sellConsumables = true, -- keep one stack of the strongest per category
  autoSellConsumables = false, -- ...automatically, or behind a confirm list
  useMacros = false, -- keep VV macros pointed at the strongest per quick-use slot
  fillAmmo = true, -- show the Fill Ammo button (Forever hunters)
  protectedItems = {},    -- item IDs that never sell (/vv protect)
  newSeen = {},           -- per-feature seen stamps for New tags (/vv dismiss-new)
}
-- Per-expansion checklist: one opt-in boolean per expansion, all off.
-- (The old Midnight keep toggle is gone; an unchecked Midnight row
-- keeps current-expansion gear the same way.)
for _, e in ipairs(ns.EXPANSIONS) do defaults["sell" .. e.key] = false end
ns.defaults = defaults

VocVendorDB = VocVendorDB or {}
ns.db = VocVendorDB

-- Principle 5 onboarding, with one explicit denylist. Sale-expanding
-- settings never auto-enable: a new sale category stays off until the
-- player opts in. Anything else missing from an existing DB turns on
-- with one chat line and a New tag; a fresh DB fills silently (no
-- login spam) and never tags.
ns.NEW_TAG_DAYS = 7
ns.NEW_TAG_WINDOW = 7 * 24 * 60 * 60
ns.MANUAL_OPT_IN = {
  junkOldGear = true, oldGearBoE = true, oldGearWarbound = true,
  autoSellConsumables = true, useMacros = true, sellVendorWins = true,
}
for _, e in ipairs(ns.EXPANSIONS) do ns.MANUAL_OPT_IN["sell" .. e.key] = true end

-- Epoch seconds for the New-tag horizon. Nil when the client cannot
-- say: the feature still enables, it just carries no tag.
function ns.now()
  if type(GetServerTime) ~= "function" then return nil end
  local ok, t = pcall(GetServerTime)
  if ok and type(t) == "number" then return t end
  return nil
end

function ns.isNew(key, now)
  local seen = type(ns.db) == "table" and ns.db.newSeen
  local ts = type(seen) == "table" and seen[key]
  return type(ts) == "number" and type(now) == "number"
    and (now - ts) < ns.NEW_TAG_WINDOW
end

function ns.opts()
  if type(ns.db) ~= "table" then ns.db = {} VocVendorDB = ns.db end
  if type(ns.db.newSeen) ~= "table" then ns.db.newSeen = {} end
  -- Fresh install: no saved keys yet, so there is no returning player
  -- to announce to. Fill silently.
  local fresh = true
  for k in pairs(ns.db) do
    if k ~= "newSeen" then fresh = false break end
  end
  for k, v in pairs(defaults) do
    if k ~= "newSeen" and type(ns.db[k]) ~= type(v) then
      if not fresh and type(v) == "boolean" and v == true
        and not ns.MANUAL_OPT_IN[k] then
        ns.db[k] = true
        local stamp = ns.now()
        ns.db.newSeen[k] = stamp or true
        ns.say("new setting on: " .. k)
      else
        ns.db[k] = v
      end
    end
  end
  -- The slider's own range (Settings panel), enforced here too so a
  -- hand-edited gap stays on it. A gap of 1 sells anything strictly
  -- worse than equipped (sidegrades keep); larger gaps keep more.
  local gap = ns.db.oldGearIlvlGap
  if not (gap >= 1 and gap <= 100) then ns.db.oldGearIlvlGap = defaults.oldGearIlvlGap end
  return ns.db
end

-- Dismiss-all for New tags: clears every tag at once.
function ns.dismissNew()
  if type(ns.db) ~= "table" or type(ns.db.newSeen) ~= "table" then return end
  local n = 0
  for _ in pairs(ns.db.newSeen) do n = n + 1 end
  ns.db.newSeen = {}
  if n > 0 then ns.say("new tags cleared") end
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

-- ======= Auction math =======
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
-- Losing consumables: one stack of the strongest per buff slot, the rest
-- vendors. A category is a buff slot (food, flask, battle elixir, ...):
-- two consumables in it never stack, so the strongest wins and every
-- other stack sells, including any of the winner past one full stack.
-- Placement is conservative: an unknown subclass, an unparsed effect, or
-- a special one-of-a-kind effect never sells, whatever its power. Only
-- bags are read, only the vendor buys, nothing is ever deleted.
ns.CONSUMABLE_SPECIAL = {
  "invisib", "water breath", "transform", "summon", "teleport", "portal",
  "resurrect", "polymorph", "mind control",
}
ns.OFFENSE_WORDS = { "strength", "agility", "intellect", "attack power",
  "critical", "haste", "mastery", "versatility", "damage", "primary stat" }
ns.DEFENSE_WORDS = { "stamina", "armor", "dodge", "parry", "block",
  "avoidance", "absorb" }
ns.RESOURCE_WORDS = { "rage", "energy", "focus", "runic", "fury", "insanity" }
ns.RESIST_WORDS = { "fire", "frost", "shadow", "nature", "arcane" }

local function hasAny(desc, words)
  for _, w in ipairs(words) do
    if desc:find(w, 1, true) then return true end
  end
  return false
end

-- Secondary offense words: useful to every spec, unlike a named
-- primary stat. Used to order the runners-up when neither item
-- matches the player's own stat (scrolls especially: an agility
-- scroll, a stamina scroll and a spirit scroll can share one number).
ns.SECONDARY_WORDS = { "critical", "haste", "mastery", "versatility",
  "attack power", "damage", "primary stat" }
ns.PRIMARY_WORDS = { "strength", "agility", "intellect" }

-- Usefulness tier for a spell description (lower wins): the player's
-- own primary stat, then secondary stats every spec uses, then
-- stamina and other defenses, then another spec's primary stat, then
-- whatever is left (spirit, resistances, ...).
function ns.statTier(desc, stat)
  if stat and desc:find(stat, 1, true) then return 0 end
  if hasAny(desc, ns.SECONDARY_WORDS) then return 1 end
  if hasAny(desc, ns.DEFENSE_WORDS) then return 2 end
  if hasAny(desc, ns.PRIMARY_WORDS) then return 3 end
  return 4
end

-- The item's Use-spell description, lowercased for keyword matching, or
-- nil when the client cannot say. Presence-gated and pcall-guarded: an
-- unknown spell keeps the item, never sells it. The optional memo shares
-- one spell read between the category and power passes of a scan.
function ns.consumableDesc(link, memo)
  if memo and memo[link] ~= nil then return memo[link] or nil end
  local function done(desc)
    if memo then memo[link] = desc or false end
    return desc
  end
  if type(C_Item) ~= "table" or type(C_Item.GetItemSpell) ~= "function" then
    return done(nil)
  end
  local ok, _, spellID = pcall(C_Item.GetItemSpell, link)
  if not ok or type(spellID) ~= "number" then return done(nil) end
  if type(C_Spell) ~= "table"
    or type(C_Spell.GetSpellDescription) ~= "function" then
    return done(nil)
  end
  local okD, desc = pcall(C_Spell.GetSpellDescription, spellID)
  if not okD or type(desc) ~= "string" or desc == "" then return done(nil) end
  return done(desc:lower())
end

function ns.isSpecialConsumable(desc)
  return hasAny(desc, ns.CONSUMABLE_SPECIAL)
end

-- True when this description is a Well Fed experience buff: the XP
-- food every food calculation prefers. Both words are needed: a
-- stat feast is Well Fed without experience, and an experience
-- grant without Well Fed is not food.
function ns.isXpFood(desc)
  if type(desc) ~= "string" then return false end
  return desc:find("well fed", 1, true) ~= nil
    and desc:find("experience", 1, true) ~= nil
end

-- Potion routing by what the description restores: health, mana, another
-- resource, or a resistance. Health-and-mana both compete where the
-- larger number is; anything else unrecognized keeps.
function ns.potionCategory(desc)
  for _, res in ipairs(ns.RESIST_WORDS) do
    if desc:find(res, 1, true)
      and (desc:find("absorb", 1, true) or desc:find("resist", 1, true)
        or desc:find("protect", 1, true) or desc:find("ward", 1, true)) then
      return "protection:" .. res
    end
  end
  local function nearNum(word)
    local n = desc:match("([%d,]+)%s+" .. word)
    n = n and n:gsub(",", "")
    return tonumber(n) or 0
  end
  local health = desc:find("health", 1, true) ~= nil
    and (desc:find("restor", 1, true) or desc:find("replenish", 1, true)
      or desc:find("heal", 1, true) or desc:find("regen", 1, true))
  local mana = desc:find("mana", 1, true) ~= nil
    and (desc:find("restor", 1, true) or desc:find("replenish", 1, true)
      or desc:find("regen", 1, true))
  if health and not mana then return "healpotion" end
  if mana and not health then return "manapotion" end
  if health and mana then
    if nearNum("health") >= nearNum("mana") then return "healpotion" end
    return "manapotion"
  end
  for _, res in ipairs(ns.RESOURCE_WORDS) do
    if desc:find(res, 1, true) then return "resource:" .. res end
  end
  return nil
end

-- The buff slot for a consumable link, or nil when the addon cannot
-- confidently place it. Never invents a category: subclass first, then
-- the spell description refines it, and anything ambiguous keeps.
function ns.consumableCategory(link, memo)
  if type(C_Item) ~= "table" or type(C_Item.GetItemInfo) ~= "function" then
    return nil
  end
  if type(Enum) ~= "table" or type(Enum.ItemClass) ~= "table" then return nil end
  local r = { pcall(C_Item.GetItemInfo, link) }
  if not r[1] then return nil end
  if r[13] ~= Enum.ItemClass.Consumable then return nil end -- 12th return
  local sub = r[14] -- 13th return
  local SC = Enum.ItemConsumableSubclass
  if type(SC) ~= "table" then return nil end
  if sub == SC.Flasksphials then return "flask" end
  if sub == SC.Bandage then return "bandage" end
  if sub == SC.Scroll then return "scroll" end
  if sub == SC.Itemenhancement or sub == SC.ItemenhancementTemporary then
    local desc = ns.consumableDesc(link, memo)
    if not desc or ns.isSpecialConsumable(desc) then return nil end
    -- Weapon oils coat a weapon, armor kits reinforce armor: different
    -- equip targets that stack, so offense keeps its own winner under
    -- "weapon" and defense keeps its own under "armor". A mixed
    -- enhancement proves nothing over either side, so it keeps like a
    -- mixed elixir does.
    local off = hasAny(desc, ns.OFFENSE_WORDS)
    local def = hasAny(desc, ns.DEFENSE_WORDS)
    if off and not def then return "weapon" end
    if def and not off then return "armor" end
    return nil
  end
  if sub == SC.Draught or sub == SC.VantusRune then
    local desc = ns.consumableDesc(link, memo)
    if not desc or ns.isSpecialConsumable(desc) then return nil end
    if hasAny(desc, ns.OFFENSE_WORDS) or hasAny(desc, ns.DEFENSE_WORDS) then
      return "utility"
    end
    return nil
  end
  if sub == SC.Elixir or sub == SC.Fooddrink or sub == SC.Potion then
    local desc = ns.consumableDesc(link, memo)
    if not desc or ns.isSpecialConsumable(desc) then return nil end
    if sub == SC.Potion then return ns.potionCategory(desc) end
    if sub == SC.Elixir then
      local off = hasAny(desc, ns.OFFENSE_WORDS)
      local def = hasAny(desc, ns.DEFENSE_WORDS)
      if off and not def then return "battle" end
      if def and not off then return "guardian" end
      return nil
    end
    -- Fooddrink: a buff makes it food; mana without a buff is a drink;
    -- plain health restores are food.
    local buff = desc:find("well fed", 1, true) ~= nil
      or hasAny(desc, ns.OFFENSE_WORDS) or desc:find("stamina", 1, true)
    if buff then return "food" end
    if desc:find("mana", 1, true) then return "drink" end
    if desc:find("health", 1, true) then return "food" end
    return nil
  end
  return nil
end

-- The largest number in a spell description (thousands separators
-- stripped): heals, restores, and stat buffs all read as one number.
function ns.spellPower(desc)
  local best = 0
  for num in desc:gmatch("(%d[%d,]*)") do
    local n = tonumber((num:gsub(",", "")))
    if n and n > best then best = n end
  end
  return best
end

-- The player's own primary stat as a description keyword, or nil on a
-- tie, a refused read, or a missing API. Strength, agility, and
-- intellect are UnitStat 1, 2, and 4; the highest is the spec's stat.
-- Secret values (Midnight) error on compare, so the literal
-- canaccessvalue guard below owns the comparisons, the way VocXP's
-- aura reads do; without the API there is nothing to refuse.
function ns.playerStatWord()
  if type(UnitStat) ~= "function" then return nil end
  local s, a, g = 0, 0, 0
  local okS, vs = pcall(UnitStat, "player", 1)
  if okS and type(vs) == "number" then s = vs end
  local okA, va = pcall(UnitStat, "player", 2)
  if okA and type(va) == "number" then a = va end
  local okG, vg = pcall(UnitStat, "player", 4)
  if okG and type(vg) == "number" then g = vg end
  if canaccessvalue then
    if not canaccessvalue(s) or not canaccessvalue(a)
      or not canaccessvalue(g) then
      return nil
    end
  end
  if s > a and s > g then return "strength" end
  if a > s and a > g then return "agility" end
  if g > s and g > a then return "intellect" end
  return nil
end

-- Rankable power for a consumable, or nil when the client cannot say.
-- Identical items are always comparable; different items need a parsed
-- number on the winning side (see collectConsumableSale).
function ns.consumablePower(link, memo)
  local desc = ns.consumableDesc(link, memo)
  if not desc then return nil end
  local id = ns.itemID(link)
  local ilvl = 0
  if type(C_Item.GetDetailedItemLevelInfo) == "function" then
    local okL, lvl = pcall(C_Item.GetDetailedItemLevelInfo, link)
    if okL and type(lvl) == "number" then ilvl = lvl end
  end
  return { num = ns.spellPower(desc), ilvl = ilvl, id = id or 0, desc = desc }
end

-- True when a outranks b. A Well Fed experience buff always wins
-- (the XP food the food slot exists to keep); then raw number, then
-- item level, then stat usefulness for the player's spec (a stronger
-- off-spec item still beats a weaker on-spec one; equal numbers fall
-- back to most-useful-first, so an agility scroll outranks a spirit
-- scroll for a hunter), then the lower item ID for determinism.
function ns.consumableBetter(a, b)
  local xa, xb = ns.isXpFood(a.desc), ns.isXpFood(b.desc)
  if xa ~= xb then return xa end
  if a.num ~= b.num then return a.num > b.num end
  if a.ilvl ~= b.ilvl then return a.ilvl > b.ilvl end
  local stat = ns.playerStatWord()
  if stat then
    local ta, tb = ns.statTier(a.desc, stat), ns.statTier(b.desc, stat)
    if ta ~= tb then return ta < tb end
  end
  return (a.id or 0) < (b.id or 0)
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
  -- Vendor wins is the same: its own toggle, sold with the junk. Slots
  -- already claimed above are excluded so no slot sells twice.
  local vendorWins = {}
  if ns.opts().sellVendorWins then
    local claimed = {}
    for _, list in ipairs({ oldGear, expJunk }) do
      for _, it in ipairs(list) do
        claimed[it.bag .. ":" .. it.slot] = true
      end
    end
    vendorWins = ns.collectVendorWins(claimed)
  end
  return { grayCount = grayCount, oldGear = oldGear, expJunk = expJunk,
    vendorWins = vendorWins }
end

-- Protected items never sell, on any path: grays (which Blizzard's
-- own bulk sale would otherwise take), old gear, expansion items,
-- vendor wins, consumables, and the delete list all check the keep
-- first, and each click re-checks it. Kept in the keeps window (/vv
-- protect) or on its slash line: the SavedVariables set holds item
-- IDs, and the stored link (when marked by link) names it back in
-- both. Links and numeric IDs resolve directly; a bare name keeps
-- every matching bag stack, so typing the name works like
-- shift-clicking it. One direct slash item toggles; names and
-- comma-separated lists only ever keep, so bulk-keeping can never
-- bulk-expose (unkeep one row or one item at a time).
function ns.isProtected(link)
  local id = ns.itemID(link)
  return id ~= nil and type(ns.db) == "table"
    and type(ns.db.protectedItems) == "table"
    and ns.db.protectedItems[id] ~= nil
end

-- Split a protect input on commas, keeping full item links intact:
-- a display name may itself contain a comma, so commas inside a link
-- (|c...|Hitem...|h[name]|h|r) never split. Bare links ("item:...") and
-- numeric IDs have no commas or spaces and split normally.
---@param text string
local function splitProtectInput(text)
  local tokens = {}
  local pos = 1
  while pos <= #text do
    local s, e = text:find("|c.-|Hitem.-|h.-|h|r", pos)
    if not s then s, e = text:find("|Hitem.-|h.-|h", pos) end
    if not s then break end
    local before = text:sub(pos, s - 1)
    for piece in (before .. ","):gmatch("(.-),") do
      piece = strtrim(piece)
      if piece ~= "" then tokens[#tokens + 1] = piece end
    end
    tokens[#tokens + 1] = strtrim(text:sub(s, e))
    pos = e + 1
  end
  for piece in (text:sub(pos) .. ","):gmatch("(.-),") do
    piece = strtrim(piece)
    if piece ~= "" then tokens[#tokens + 1] = piece end
  end
  return tokens
end

-- Keep-token resolution: a link or numeric ID resolves directly; a
-- bare name keeps every matching bag stack by ID (case-insensitive
-- exact match on the client's own item name), so typing the name of
-- what's in the bags works like shift-clicking it. Names only match
-- what the bags hold right now, so a typo still errors instead of
-- silently keeping nothing. Returns a list of { id, shown } plus
-- whether the token was the direct (link-or-ID) form.
local function resolveKeepToken(tok)
  local found, seen = {}, {}
  local function add(id, shown, linked)
    if id ~= nil and not seen[id] then
      seen[id] = true
      found[#found + 1] = { id = id, shown = shown, linked = linked }
    end
  end
  if tok:find("item:", 1, true) then
    local id = ns.itemID(tok)
    if id then add(id, tok, true) end
    return found, true
  end
  local num = tonumber(tok)
  if num then
    add(num, "item:" .. num, false)
    return found, true
  end
  local want = strtrim(tok):lower()
  if want ~= "" and type(C_Container) == "table"
    and type(C_Container.GetContainerNumSlots) == "function"
    and type(C_Container.GetContainerItemLink) == "function"
    and type(C_Item) == "table"
    and type(C_Item.GetItemInfo) == "function" then
    for bag = 0, NUM_BAG_SLOTS do
      local slots = C_Container.GetContainerNumSlots(bag)
      for slot = 1, slots do
        local link = C_Container.GetContainerItemLink(bag, slot)
        if link then
          local ok, name = pcall(C_Item.GetItemInfo, link)
          if ok and type(name) == "string" and name:lower() == want then
            local id = ns.itemID(link)
            if id then add(id, link, true) end
          end
        end
      end
    end
  end
  return found, false
end

local function keepFailure(tok)
  return "couldn't find " .. tok .. " (shift-click it, or give its name or itemID)"
end

---@param text string
function ns.toggleProtect(text)
  text = strtrim(text or "")
  if text == "" then
    ns.say("couldn't find that item (shift-click it, or give its name or itemID)")
    return
  end
  if type(ns.db.protectedItems) ~= "table" then ns.db.protectedItems = {} end
  local tokens = splitProtectInput(text)
  -- One direct item keeps the exact toggle: repeat to stop keeping
  -- it. A bare name only ever keeps what it names, so naming a kept
  -- item reports instead of toggling it off.
  if #tokens <= 1 then
    local one = tokens[1] or text
    local resolved, direct = resolveKeepToken(one)
    if #resolved == 0 then
      ns.say(keepFailure(one))
      return
    end
    if direct and #resolved == 1 then
      local id, shown = resolved[1].id, resolved[1].shown
      if ns.db.protectedItems[id] then
        ns.db.protectedItems[id] = nil
        ns.play("off")
        ns.say("no longer protected: " .. shown)
      else
        ns.db.protectedItems[id] = one:find("item:", 1, true) and one or true
        ns.play("on")
        ns.say("protected: " .. shown)
      end
      return
    end
    ns.keepMatches(resolved)
    return
  end
  -- A comma-separated list only ever keeps: bulk unprotecting by
  -- accident could sell something the player meant to keep, so repeats
  -- report instead of toggling off (unkeep one item at a time).
  ns.keepText(text)
end

-- Keeps every resolved match, reporting repeats instead of toggling
-- them off. Shared by named singles and comma-separated lists.
function ns.keepMatches(resolved)
  if type(ns.db.protectedItems) ~= "table" then ns.db.protectedItems = {} end
  local added = false
  for _, m in ipairs(resolved or {}) do
    if ns.db.protectedItems[m.id] then
      ns.say("already protected: " .. m.shown)
    else
      ns.db.protectedItems[m.id] = m.linked and m.shown or true
      ns.say("protected: " .. m.shown)
      added = true
    end
  end
  if added then ns.play("on") end
end

-- Add-only keep for text from the slash line or the keeps box: every
-- resolvable entry is kept, repeats report instead of toggling off,
-- and failures name their entry without blocking the rest. Lines read
-- in typed order, with one confirmation sound for the whole list.
function ns.keepText(text)
  if type(ns.db.protectedItems) ~= "table" then ns.db.protectedItems = {} end
  local added, seen = false, {}
  for _, tok in ipairs(splitProtectInput(strtrim(text or ""))) do
    local matches = resolveKeepToken(tok)
    if #matches == 0 then
      ns.say(keepFailure(tok))
    end
    for _, m in ipairs(matches) do
      if not seen[m.id] then
        seen[m.id] = true
        if ns.db.protectedItems[m.id] then
          ns.say("already protected: " .. m.shown)
        else
          ns.db.protectedItems[m.id] = m.linked and m.shown or true
          ns.say("protected: " .. m.shown)
          added = true
        end
      end
    end
  end
  if added then ns.play("on") end
end

-- One unkeep by item ID: the keeps window row click behind it. Only
-- ever removes, so it never sells or exposes anything by itself.
function ns.unkeep(id, shown)
  if type(ns.db) ~= "table"
    or type(ns.db.protectedItems) ~= "table" then
    return
  end
  if tonumber(id) == nil or ns.db.protectedItems[id] == nil then return end
  ns.db.protectedItems[id] = nil
  ns.play("off")
  ns.say("no longer protected: " .. tostring(shown or ("item:" .. id)))
end

-- Sorted keeps for the window and the chat list, so both read the
-- same stable order instead of hash order.
function ns.listProtectedItems()
  local out = {}
  for id, shown in pairs(type(ns.db) == "table"
    and ns.db.protectedItems or {}) do
    out[#out + 1] = { id = id,
      shown = type(shown) == "string" and shown or ("item:" .. id) }
  end
  table.sort(out, function(a, b) return a.shown < b.shown end)
  return out
end

function ns.listProtected()
  local items = ns.listProtectedItems()
  for _, it in ipairs(items) do print("  " .. tostring(it.shown)) end
  if #items == 0 then ns.say("nothing protected")
  else ns.play("open") end
end

-- Keeps window. The visual counterpart to the slash keeps: one row
-- per kept item (click unkeeps), and an entry box on top where
-- shift-clicking an item inserts its link and Enter keeps it, commas
-- ok for lists. Built like the disenchant and delete windows; when
-- it cannot open, the chat list is the readout.
ns.keepWindow = nil
ns.keepRows = {}
ns.keepBox = nil
ns.keepBoxFocus = false
ns.linkHooked = false

-- Shift-click reception. Blizzard's own funnel, verified on both
-- branches (ItemButtonTemplate.lua HandleModifiedItemClick calls
-- ChatFrameUtil.InsertLink on IsModifiedClick("CHATLINK"); the
-- Mainline override in ChatFrameUtilOverrides.lua serves the macro
-- box, professions search, communities chat, the active chat window,
-- and the auction house; Deprecated_ChatFrame.lua keeps the old
-- ChatEdit_InsertLink name as an alias): a custom box gets nothing
-- unless it hooks in. The post-hook below keeps the link only while
-- the keeps box has focus, so normal chat shift-clicks pass through
-- untouched. Presence-gated and pcall-guarded throughout: without
-- the funnel or the hook API, typed entry still works.
function ns.hookInsertLink()
  if ns.linkHooked then return end
  if type(hooksecurefunc) ~= "function" then return end
  if type(ChatFrameUtil) ~= "table" then return end
  if type(ChatFrameUtil.InsertLink) ~= "function" then return end
  local ok = pcall(hooksecurefunc, ChatFrameUtil, "InsertLink", function(text)
    pcall(function()
      if not ns.keepBoxFocus then return end
      if not (ns.keepWindow and ns.keepWindow:IsShown()) then return end
      if type(text) ~= "string" then return end
      if not text:find("item:", 1, true) then return end
      ns.keepText(text)
      ns.refreshKeepWindow()
    end)
  end)
  if ok then ns.linkHooked = true end
end

function ns.ensureKeepWindow()
  if ns.keepWindow then return ns.keepWindow end
  if type(CreateFrame) ~= "function" then return nil end
  if type(UIParent) ~= "table" then return nil end
  local ok, window = pcall(CreateFrame, "Frame", "VocVendorKeepWindow",
    UIParent, "BasicFrameTemplateWithInset")
  if not ok or window == nil then return nil end
  window:SetSize(280, 100)
  window:SetPoint("CENTER")
  window:SetMovable(true)
  window:EnableMouse(true)
  window:RegisterForDrag("LeftButton")
  window:SetScript("OnDragStart", window.StartMoving)
  window:SetScript("OnDragStop", window.StopMovingOrSizing)
  if window.TitleText then window.TitleText:SetText("Keeps") end
  if not window.CloseButton then
    local closeBtn = CreateFrame("Button", nil, window, "UIPanelCloseButton")
    if closeBtn then
      closeBtn:SetPoint("TOPRIGHT", window, "TOPRIGHT", -4, -4)
      closeBtn:SetScript("OnClick", function() window:Hide() end)
    end
  end
  local hint = window:CreateFontString(nil, "ARTWORK", "GameFontDisable")
  hint:SetPoint("TOPLEFT", window, "TOPLEFT", 16, -30)
  hint:SetText("Shift-click, or type a name or ID (commas ok), then Enter")
  local box = nil
  local okBox, madeBox =
    pcall(CreateFrame, "EditBox", nil, window, "InputBoxTemplate")
  if okBox and madeBox ~= nil then box = madeBox end
  if not box then
    local okPlain, madePlain = pcall(CreateFrame, "EditBox", nil, window)
    if okPlain and madePlain ~= nil then box = madePlain end
  end
  if box then
    box:SetSize(248, 22)
    box:SetPoint("TOPLEFT", window, "TOPLEFT", 16, -48)
    if type(box.SetAutoFocus) == "function" then box:SetAutoFocus(false) end
    box:SetScript("OnEditFocusGained", function() ns.keepBoxFocus = true end)
    box:SetScript("OnEditFocusLost", function() ns.keepBoxFocus = false end)
    ns.hookInsertLink()
    box:SetScript("OnEnterPressed", function(self)
      local text = ""
      if type(self.GetText) == "function" then text = self:GetText() or "" end
      if type(self.SetText) == "function" then self:SetText("") end
      if type(self.ClearFocus) == "function" then self:ClearFocus() end
      if strtrim(text) ~= "" then
        ns.keepText(text)
        ns.refreshKeepWindow()
      end
    end)
    box:SetScript("OnEscapePressed", function(self)
      if type(self.ClearFocus) == "function" then self:ClearFocus() end
    end)
    if type(box.HookScript) == "function" then
      box:HookScript("OnEnter", function(self)
        if type(IsMouseButtonDown) == "function" and IsMouseButtonDown() then return end
        if type(GameTooltip) ~= "table" then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Shift-click, or type a name or ID; commas separate lists",
          COLORS.text[1], COLORS.text[2], COLORS.text[3])
        GameTooltip:Show()
      end)
      box:HookScript("OnLeave", function()
        if type(GameTooltip) == "table" then GameTooltip:Hide() end
      end)
    end
    ns.keepBox = box
  end
  window.emptyNote = window:CreateFontString(nil, "ARTWORK", "GameFontDisable")
  window.emptyNote:SetPoint("TOPLEFT", window, "TOPLEFT", 16, -78)
  window.emptyNote:SetText("nothing protected yet")
  if type(UISpecialFrames) == "table" then
    table.insert(UISpecialFrames, "VocVendorKeepWindow")
  end
  window:Hide()
  window:SetScript("OnHide", function() ns.play("close") end)
  ns.keepWindow = window
  return window
end

-- One keeps row: the kept item's link, plain button. Clicking
-- unkeeps it and the window re-reads the set.
local function newKeepRow(window)
  local ok, row = pcall(CreateFrame, "Button", nil, window)
  if not ok or row == nil then return nil end
  row:SetSize(248, 22)
  row.text = row:CreateFontString(nil, "ARTWORK", "GameFontNormal")
  row.text:SetPoint("LEFT", row, "LEFT", 2, 0)
  row:SetScript("OnClick", function(self)
    ns.unkeep(self.keepID, self.keepShown)
    ns.refreshKeepWindow()
  end)
  -- Tooltip contract: one white line saying what the row does.
  row:SetScript("OnEnter", function(self)
    if type(IsMouseButtonDown) == "function" and IsMouseButtonDown() then return end
    if type(GameTooltip) ~= "table" then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    if type(GameTooltip.SetHyperlink) == "function" then
      pcall(GameTooltip.SetHyperlink, GameTooltip, self.keepShown)
    end
    GameTooltip:AddLine("Click to stop keeping",
      COLORS.text[1], COLORS.text[2], COLORS.text[3])
    GameTooltip:Show()
  end)
  row:SetScript("OnLeave", function()
    if type(GameTooltip) == "table" then GameTooltip:Hide() end
  end)
  return row
end

function ns.refreshKeepWindow()
  local window = ns.ensureKeepWindow()
  if not window then return nil end
  local items = ns.listProtectedItems()
  for i = #ns.keepRows + 1, #items do
    local row = newKeepRow(window)
    if not row then return nil end
    ns.keepRows[#ns.keepRows + 1] = row
  end
  for i, row in ipairs(ns.keepRows) do
    local it = items[i]
    if it then
      row.keepID = it.id
      row.keepShown = it.shown
      row.text:SetText(it.shown)
      row:ClearAllPoints()
      row:SetPoint("TOPLEFT", window, "TOPLEFT", 16, -(78 + (i - 1) * 24))
      row:Show()
    else
      row:Hide()
    end
  end
  if window.emptyNote then
    if #items == 0 then window.emptyNote:Show() else window.emptyNote:Hide() end
  end
  window:SetSize(280, 102 + #items * 24)
  if not window:IsShown() then
    window:Show()
    ns.play("open")
  end
  return #items
end

-- Manual keeps path: the window is the readout, chat only when it
-- cannot open (same fallback contract as the other lists).
function ns.openKeeps()
  if ns.refreshKeepWindow() then return end
  ns.listProtected()
end

-- One full stack for a consumable link (its own max stack), nil when
-- the client cannot say: then a winner never counts as over-kept.
function ns.maxStack(link)
  if type(C_Item) ~= "table" or type(C_Item.GetItemInfo) ~= "function" then
    return nil
  end
  local r = { pcall(C_Item.GetItemInfo, link) }
  if not r[1] then return nil end
  return tonumber(r[9]) -- 8th return
end

-- Items in a bag slot, 1 when the client cannot say.
function ns.slotCount(bag, slot)
  if type(C_Container) ~= "table" then return 1 end
  if type(C_Container.GetContainerItemInfo) ~= "function" then return 1 end
  local ok, info = pcall(C_Container.GetContainerItemInfo, bag, slot)
  if not ok or type(info) ~= "table" then return 1 end
  return tonumber(info.stackCount) or 1
end

-- ======= Consumables =======
-- Confidently placed bag consumables, grouped by buff slot in first-seen
-- order. Each item carries its slot, vendor price, and stack count.
-- Not a sale: ranking (keep the winner) happens in ns.rankCategory, so
-- the merchant sale and the diagnose readout share one implementation.
function ns.groupConsumables(descs)
  local memo = {} -- collectible answers, per item ID
  local byCat, order = {}, {}
  for bag = 0, NUM_BAG_SLOTS do
    local slots = C_Container.GetContainerNumSlots(bag)
    for slot = 1, slots do
      local link = C_Container.GetContainerItemLink(bag, slot)
      if link and not ns.isProtected(link)
        and ns.slotHasValue(bag, slot) and not ns.questKeeps(link)
        and not ns.isUncollectedCollectible(link, memo) then
        local _, _, _, _, _, _, _, _, _, _, sellPrice = C_Item.GetItemInfo(link)
        if sellPrice and sellPrice > 0 then
          local cat = ns.consumableCategory(link, descs)
          if cat then
            if not byCat[cat] then
              byCat[cat] = {}
              order[#order + 1] = cat
            end
            byCat[cat][#byCat[cat] + 1] = { link = link, bag = bag,
              slot = slot, price = sellPrice,
              count = ns.slotCount(bag, slot) }
          end
        end
      end
    end
  end
  return byCat, order
end

-- Ranked outcome for one category's items: the winning link, how many
-- of it stay, and which stacks sell. Unranked items (no spell data)
-- never appear in either list. A numberless winner proves nothing over
-- other numbers: only identical stacks thin out, and different items
-- all keep.
function ns.rankCategory(items, descs)
  local ranked = {}
  for _, it in ipairs(items or {}) do
    local p = ns.consumablePower(it.link, descs)
    if p then
      it.power = p
      ranked[#ranked + 1] = it
    end
  end
  if #ranked == 0 then return nil end
  local winner = ranked[1]
  for i = 2, #ranked do
    if ns.consumableBetter(ranked[i].power, winner.power) then
      winner = ranked[i]
    end
  end
  local cap = ns.maxStack(winner.link)
  local kept, sale = 0, {}
  for _, it in ipairs(items) do
    if it.power then
      if it.link == winner.link then
        local n = ns.slotCount(it.bag, it.slot)
        if cap and kept + n > cap then
          sale[#sale + 1] = it
        else
          kept = kept + n
        end
      elseif winner.power.num > 0 then
        sale[#sale + 1] = it
      end
    end
  end
  return { winner = winner, kept = kept, sale = sale }
end

-- The losing consumables in the bags right now: every stack past the
-- winner's one full stack, plus every loser completely.
function ns.collectConsumableSale()
  if not ns.opts().sellConsumables then return {} end
  local descs = {} -- spell descriptions, per link: one read per scan
  local byCat, order = ns.groupConsumables(descs)
  local sale = {}
  for _, cat in ipairs(order) do
    local ranked = ns.rankCategory(byCat[cat], descs)
    if ranked then
      for _, it in ipairs(ranked.sale) do sale[#sale + 1] = it end
    end
  end
  return sale
end

-- The engine's own verdict on a refused click (UI_ERROR_MESSAGE
-- during the visit: the vendor refusing the item, the gold cap, ...).
-- Nil most of the time; cleared at the start of every sale, so a row
-- never wears another visit's error.
ns.lastVendorError = nil

-- True when the client reports this slot locked (another operation is
-- moving the item): a click there silently does nothing.
function ns.slotLocked(bag, slot)
  if type(C_Container) ~= "table" then return false end
  if type(C_Container.GetContainerItemInfo) ~= "function" then return false end
  local ok, info = pcall(C_Container.GetContainerItemInfo, bag, slot)
  return ok and type(info) == "table" and info.isLocked == true
end

-- One leftover row, with the discriminating facts attached: whether the
-- slot was locked and what the engine said (if anything). Rows with
-- neither read exactly as before.
local function leftoverEntry(it, reason)
  local e = { link = it.link, reason = reason }
  if reason == "still in bags" then
    local extra = {}
    if ns.slotLocked(it.bag, it.slot) then extra[#extra + 1] = "locked" end
    if ns.lastVendorError ~= nil then
      extra[#extra + 1] = tostring(ns.lastVendorError)
    end
    if #extra > 0 then e.detail = table.concat(extra, ", ") end
  end
  return e
end

-- One sale attempt for a consumable stack: a guard reason, or the
-- sold count once the click has cleared the slot. A protection marked
-- after the confirm still holds at the click.
local function attemptConsumableSale(it)
  if not ns.merchantOpen() then
    return "vendor closed", 0
  elseif C_Container.GetContainerItemLink(it.bag, it.slot) ~= it.link then
    return "moved", 0
  elseif ns.isProtected(it.link) then
    return "protected", 0
  elseif not ns.slotHasValue(it.bag, it.slot) then
    return "vendor won't buy", 0
  end
  local count = ns.slotCount(it.bag, it.slot)
  local ok = pcall(C_Container.UseContainerItem, it.bag, it.slot)
  local still = false
  if type(C_Container.GetContainerItemLink) == "function" then
    local okLink, now = pcall(C_Container.GetContainerItemLink, it.bag, it.slot)
    still = okLink and now == it.link
  end
  if ok and not still then return nil, count end
  return ((not ok) and "sell failed" or "still in bags"), 0
end

-- Sells a consumable list, re-verifying each slot first like the old-gear
-- sale does. Same attempt-everything contract, same leftover report:
-- one refusal no longer vetoes the rest, and click failures get one
-- second chance after the pass.
function ns.sellConsumableItems(items)
  local n, value = 0, 0
  local leftover = {}
  local failed = {}
  ns.lastVendorError = nil
  if type(C_Container) ~= "table" then return n, value, leftover end
  if type(C_Container.GetContainerItemLink) ~= "function" then
    return n, value, leftover
  end
  items = items or {}
  for _, it in ipairs(items) do
    local reason, count = attemptConsumableSale(it)
    if reason == "sell failed" or reason == "still in bags" then
      failed[#failed + 1] = it
    elseif reason then
      leftover[#leftover + 1] = leftoverEntry(it, reason)
    else
      n = n + count
      value = value + (it.price or 0) * count
    end
  end
  for _, it in ipairs(failed) do
    local reason, count = attemptConsumableSale(it)
    if reason then
      leftover[#leftover + 1] = leftoverEntry(it, reason)
    else
      n = n + count
      value = value + (it.price or 0) * count
    end
  end
  return n, value, leftover
end

-- Merged rows with true item counts: one row per link, summed stacks
-- and vendor totals. Sale lists carry per-slot counts.
function ns.mergeStacks(items)
  local groups, byID = {}, {}
  for _, it in ipairs(items or {}) do
    local id = ns.itemID(it.link) or it.link
    local g = byID[id]
    if not g then
      g = { link = it.link, qty = 0, total = 0 }
      byID[id] = g
      groups[#groups + 1] = g
    end
    local n = tonumber(it.count) or 1
    g.qty = g.qty + n
    g.total = g.total + (it.price or 0) * n
  end
  return groups
end

-- A blocked sale click, named by the client. Taint blocks are engine
-- events, not Lua errors, so no pcall ever sees them: without this the
-- sale just reports "still in bags". Only our own blocks announce, with
-- the function the client refused, so a silent failure becomes a fact.
-- The last block stays on ns for /vv diag.
function ns.onActionBlocked(isTainted, fn)
  if isTainted ~= name then return end
  ns.lastBlock = tostring(fn)
  ns.say("the client blocked " .. tostring(fn)
    .. " (sale click refused; nothing sold - /reload and try once more)")
end

-- Diagnose the consumable ranks from chat: one line per buff slot naming
-- the winner with its parsed power and item level, how much of it stays,
-- and how much sells, plus every sale row. No windows, no sales: facts
-- for a bug report instead of memory.
function ns.diagConsumables()
  local descs = {}
  local byCat, order = ns.groupConsumables(descs)
  if #order == 0 then
    ns.say("no ranked consumables in bags")
    return
  end
  ns.play("open") -- the ranks are the readout
  ns.say("consumable ranks:")
  for _, cat in ipairs(order) do
    local ranked = ns.rankCategory(byCat[cat], descs)
    if ranked then
      local w = ranked.winner.power
      local what = #ranked.sale == 1 and "1 stack" or #ranked.sale .. " stacks"
      print("  " .. cat .. ": " .. ranked.winner.link
        .. " wins (" .. w.num .. ", ilvl " .. w.ilvl .. "): keeps "
        .. ranked.kept .. ", sells " .. what)
      for _, it in ipairs(ranked.sale) do
        print("    " .. tostring(it.link) .. " x" .. (it.count or 1))
      end
    end
  end
  if ns.lastBlock then
    print("  blocked earlier: " .. ns.lastBlock)
  end
end

-- The sale itself, shared by the auto path and the confirm dialog: an
-- itemized summary, always shown, then the visit total.
function ns.sellConsumablesNow(items)
  items = items or {}
  if #items == 0 then return end
  local n, value, leftover = ns.sellConsumableItems(items)
  ns.reportLeftover(leftover)
  if n > 0 then
    ns.sellSound()
    local what = n == 1 and "1 item" or n .. " items"
    ns.say("sold losing consumables (" .. what
      .. " for " .. ns.moneyString(value) .. "):")
    for _, g in ipairs(ns.mergeStacks(items)) do print(ns.mergedLine(g)) end
    ns.recordSale(n, value)
  end
end

-- Dialog text for the Sell All confirm: the question plus one row per
-- distinct item, so the decision happens with the list in front of the
-- player, not just in chat. Capped: the chat already carries the full
-- list, so the dialog names the overflow instead of growing unbounded.
local CONSUMABLE_DIALOG_ROWS = 10
function ns.consumableDialogText(sale)
  local groups = ns.mergeStacks(sale)
  local total, n = 0, 0
  for _, g in ipairs(groups) do
    total, n = total + g.total, n + g.qty
  end
  local lines = { "Sell " .. n .. " losing consumables for "
    .. ns.moneyString(total) .. "?", "" }
  for i, g in ipairs(groups) do
    if i > CONSUMABLE_DIALOG_ROWS then
      lines[#lines + 1] = "  ...and " .. (#groups - CONSUMABLE_DIALOG_ROWS)
        .. " more (full list in chat)"
      break
    end
    lines[#lines + 1] = ns.mergedLine(g)
  end
  return table.concat(lines, "\n")
end

-- The confirm list: the question plus one row per item, in the dialog
-- as well as chat, plus a Sell All / Cancel popup.
function ns.reportConsumables(sale)
  if not sale or #sale == 0 then return end
  local groups = ns.mergeStacks(sale)
  local total, n = 0, 0
  for _, g in ipairs(groups) do
    total, n = total + g.total, n + g.qty
  end
  local what = n == 1 and "1 item" or n .. " items"
  ns.say("losing consumables (" .. what .. "):")
  for _, g in ipairs(groups) do print(ns.mergedLine(g)) end
  ns.play("open") -- the confirm list is the readout
  StaticPopupDialogs["VOCVENDOR_SELL_CONSUMABLES"].text =
    ns.consumableDialogText(sale)
  StaticPopup_Show("VOCVENDOR_SELL_CONSUMABLES",
    n, ns.moneyString(total), { items = sale })
end

StaticPopupDialogs["VOCVENDOR_SELL_CONSUMABLES"] = {
  text = "Sell %d losing consumables for %s?",
  button1 = "Sell All",
  button2 = "Cancel",
  OnAccept = function(_, data) ns.sellConsumablesNow(data and data.items) end,
  timeout = 0,
  whileDead = true,
  hideOnEscape = true,
}

-- Live-apply for the consumable toggles: turning the feature off
-- mid-visit withdraws its pending confirm.
function ns.refreshConsumablePopup()
  if ns.opts().sellConsumables then return end
  if type(StaticPopup_Hide) == "function" then
    pcall(StaticPopup_Hide, "VOCVENDOR_SELL_CONSUMABLES")
  end
end

-- ======= Use macros =======
-- The sell logic already crowns one winner per buff slot
-- (groupConsumables + rankCategory); the use macros point at those
-- winners for the six quick-use slots, so the kept stack and the
-- macro always agree. Collection differs on purpose: the sale wants
-- vendorable stacks (a price), use wants usable ones (your level or
-- below, quest and collectible keeps still excluded, protect still
-- holds). Conjured items have no price and never sell, but they are
-- first-class picks here. Bandages you lack the skill for are only
-- gated by level: the skill check lives in tooltip red text, which
-- this addon never reads.
ns.USE_MACROS = {
  { key = "food", name = "VV Food", label = "food" },
  { key = "drink", name = "VV Drink", label = "drink" },
  { key = "healpotion", name = "VV Health", label = "health potion" },
  { key = "manapotion", name = "VV Mana", label = "mana potion" },
  { key = "bandage", name = "VV Bandage", label = "bandage" },
  { key = "scroll", name = "VV Scrolls", label = "scroll" },
}
-- 120 account + 30 character slots (MacroConstantsDocumentation,
-- same values on both branches).
ns.MACRO_SLOTS = 150
ns.usePending = false -- a bag change arrived while macros could not edit
ns.useIncomplete = false -- a use-slot item ranked without spell data
ns.macroHooked = false -- the MacroFrame OnHide hook, installed once
ns.macroFullWarned = false -- the macro-slots-full line, said once

-- True when the character has a mana bar. Characters without mana
-- keep no drink or mana macros. Unknown API or failed read keeps
-- nothing: pointing at a mana item you cannot use is worse than none.
function ns.hasMana()
  if type(UnitPowerMax) ~= "function" then return false end
  -- 0 is mana (PowerTypeConstantsDocumentation; Enum.PowerType.Mana
  -- when the client names it, as in EasyConsumables).
  local manaType = 0
  if type(Enum) == "table" and type(Enum.PowerType) == "table"
    and type(Enum.PowerType.Mana) == "number" then
    manaType = Enum.PowerType.Mana
  end
  local ok, max = pcall(UnitPowerMax, "player", manaType)
  return ok and (tonumber(max) or 0) > 0
end

function ns.playerLevel()
  if type(UnitLevel) ~= "function" then return nil end
  local ok, lvl = pcall(UnitLevel, "player")
  if ok and type(lvl) == "number" then return lvl end
  return nil
end

-- True when the character may use this link: its required level is
-- known and met, or unknowable. An unknown minimum never blocks.
function ns.linkUsable(link)
  if type(C_Item) ~= "table"
    or type(C_Item.GetItemInfo) ~= "function" then
    return true
  end
  local r = { pcall(C_Item.GetItemInfo, link) }
  if not r[1] or r[2] == nil then return true end
  local minLevel = r[6] -- 5th return
  local level = ns.playerLevel()
  if type(minLevel) == "number" and type(level) == "number"
    and minLevel > level then
    return false
  end
  return true
end

-- Confidently placed, usable bag consumables for the six quick-use
-- slots. Shares the category router and the ranker with the sale;
-- only the collection guards differ (see above).
function ns.groupUsables(descs)
  local memo = {}
  local byCat = {}
  for bag = 0, NUM_BAG_SLOTS do
    local slots = C_Container.GetContainerNumSlots(bag)
    for slot = 1, slots do
      local link = C_Container.GetContainerItemLink(bag, slot)
      if link and not ns.isProtected(link) and not ns.questKeeps(link)
        and not ns.isUncollectedCollectible(link, memo)
        and ns.linkUsable(link) then
        local cat = ns.consumableCategory(link, descs)
        if cat == "food" or cat == "drink" or cat == "healpotion"
          or cat == "manapotion" or cat == "bandage" or cat == "scroll" then
          if not byCat[cat] then byCat[cat] = {} end
          byCat[cat][#byCat[cat] + 1] = { link = link }
        end
      end
    end
  end
  return byCat
end

-- One winning pick per quick-use slot: link, numeric item ID, and
-- icon texture for the macro. Items the client cannot rank yet mark
-- the scan incomplete, so item data arriving later re-ranks.
function ns.usePicks()
  local descs = {}
  local byCat = ns.groupUsables(descs)
  local picks = {}
  ns.useIncomplete = false
  for _, def in ipairs(ns.USE_MACROS) do
    local items = byCat[def.key]
    local ranked = items and ns.rankCategory(items, descs) or nil
    if ranked then
      for _, it in ipairs(items) do
        if it.power == nil then ns.useIncomplete = true break end
      end
      local id = ns.itemID(ranked.winner.link)
      if id then
        local r = { pcall(C_Item.GetItemInfo, ranked.winner.link) }
        picks[def.key] = { link = ranked.winner.link, id = id,
          texture = r[11] } -- 10th return
      end
    end
  end
  return picks
end

function ns.useMacroBody(itemID)
  return "#showtooltip\n/use item:" .. tostring(itemID)
end

-- Macro slot holding this name, or 0. Blizzard's own MacroUI reads
-- macros the same way (GetMacroInfo by slot on both branches); the
-- scan stays inside the documented 150 slots.
function ns.findMacro(macroName)
  if type(GetMacroInfo) ~= "function" then return 0 end
  for id = 1, ns.MACRO_SLOTS do
    local ok, found = pcall(GetMacroInfo, id)
    if ok and found == macroName then return id end
  end
  return 0
end

-- Macros cannot edit in combat, and Blizzard's macro window saves
-- over our edits when it closes, so both park the update instead.
function ns.canEditMacros()
  if type(InCombatLockdown) == "function" and InCombatLockdown() then
    return false
  end
  if type(MacroFrame) == "table"
    and type(MacroFrame.IsShown) == "function" then
    local ok, shown = pcall(MacroFrame.IsShown, MacroFrame)
    if ok and shown then return false end
  end
  return true
end

-- Re-run a parked update when the macro window closes. Installed
-- once, presence-gated: windowless clients never park here.
function ns.hookMacroFrame()
  if ns.macroHooked then return end
  if type(MacroFrame) ~= "table" then return end
  if type(MacroFrame.HookScript) ~= "function" then return end
  ns.macroHooked = true
  pcall(MacroFrame.HookScript, MacroFrame, "OnHide", function()
    if ns.usePending then ns.updateUseMacros() end
  end)
end

-- One macro write: create it once (character-specific, like
-- EasyConsumables), then rewrite only when the body changed. A
-- missing icon fails closed: no icon, no macro.
function ns.writeUseMacro(def, pick)
  if pick.texture == nil then return end
  local idx = ns.findMacro(def.name)
  local body = ns.useMacroBody(pick.id)
  if idx == 0 then
    if type(GetNumMacros) ~= "function" then return end
    local okN, _, nChar = pcall(GetNumMacros)
    if not okN then return end
    -- 30 character slots (MacroConstantsDocumentation, both branches).
    if (tonumber(nChar) or 0) >= 30 then
      if not ns.macroFullWarned then
        ns.macroFullWarned = true
        ns.say("macro slots are full, so " .. def.name
          .. " was not created (free one up and run /vv use)")
      end
      return
    end
    pcall(CreateMacro, def.name, pick.texture, body, true)
  else
    local okI, _, _, current = pcall(GetMacroInfo, idx)
    if okI and current ~= body then
      pcall(EditMacro, idx, def.name, pick.texture, body)
    end
  end
end

-- Point every maintained macro at its current winner. Reads run any
-- time; writes wait for combat and the macro window to clear.
function ns.updateUseMacros()
  if not ns.opts().useMacros then return end
  if type(GetMacroInfo) ~= "function"
    or type(CreateMacro) ~= "function"
    or type(EditMacro) ~= "function"
    or type(GetNumMacros) ~= "function" then
    return
  end
  if not ns.canEditMacros() then
    ns.usePending = true
    return
  end
  ns.usePending = false
  local picks = ns.usePicks()
  for _, def in ipairs(ns.USE_MACROS) do
    local pick = picks[def.key]
    local needsMana = def.key == "drink" or def.key == "manapotion"
    if pick and (not needsMana or ns.hasMana()) then
      ns.writeUseMacro(def, pick)
    end
  end
end

-- The /vv use readout: one line per slot naming the winner, plus a
-- hint when the macros are off. No windows: facts for the chat line.
function ns.reportUsePicks(picks, maintained)
  ns.play("open") -- the picks are the readout
  ns.say("best consumables:")
  for _, def in ipairs(ns.USE_MACROS) do
    local p = picks and picks[def.key]
    if p then print("  " .. def.label .. ": " .. p.link)
    else print("  " .. def.label .. ": none in bags") end
  end
  if not maintained then
    print("  macros off (Settings > AddOns > VocVendor to maintain them)")
  end
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

-- Gray slots that never sell: Poor quality the vendor would buy that
-- is either kept by ID or a crafting reagent (profession fuel). Reagents
-- keep by Blizzard's own flag, not the keeps list, so a Poor reagent
-- never rides the bulk sale either. collectProtectedGrays stays the
-- keeps-list half (cheap when nothing is kept); collectKeptGrays is the
-- union every gray path below uses, so every path stays exactly as
-- before until a keep or a Poor reagent exists.
function ns.collectReagentGrays()
  local out = {}
  if type(C_Container) ~= "table" then return out end
  if type(C_Container.GetContainerNumSlots) ~= "function"
    or type(C_Container.GetContainerItemLink) ~= "function" then
    return out
  end
  if type(C_Item) ~= "table" or type(C_Item.GetItemInfo) ~= "function" then
    return out
  end
  if type(Enum) ~= "table" or type(Enum.ItemQuality) ~= "table" then
    return out
  end
  for bag = 0, NUM_BAG_SLOTS do
    local slots = C_Container.GetContainerNumSlots(bag)
    for slot = 1, slots do
      local link = C_Container.GetContainerItemLink(bag, slot)
      if link and ns.slotHasValue(bag, slot) and ns.isCraftingReagent(link) then
        local r = { pcall(C_Item.GetItemInfo, link) }
        if r[1] and r[4] == Enum.ItemQuality.Poor then
          out[#out + 1] = { link = link, bag = bag, slot = slot }
        end
      end
    end
  end
  return out
end

function ns.collectKeptGrays()
  local out, seen = {}, {}
  for _, list in ipairs({ ns.collectProtectedGrays(), ns.collectReagentGrays() }) do
    for _, it in ipairs(list) do
      local key = it.bag .. ":" .. it.slot
      if not seen[key] then
        seen[key] = true
        out[#out + 1] = it
      end
    end
  end
  return out
end

-- The keeps-list half: Poor quality the vendor would buy, kept by ID.
-- Empty (and cheap) when nothing is kept.
function ns.collectProtectedGrays()
  local out = {}
  if type(ns.db) ~= "table" or type(ns.db.protectedItems) ~= "table" then
    return out
  end
  local any = false
  for _ in pairs(ns.db.protectedItems) do any = true break end
  if not any then return out end
  if type(C_Container) ~= "table" then return out end
  if type(C_Container.GetContainerNumSlots) ~= "function"
    or type(C_Container.GetContainerItemLink) ~= "function" then
    return out
  end
  if type(C_Item) ~= "table" or type(C_Item.GetItemInfo) ~= "function" then
    return out
  end
  if type(Enum) ~= "table" or type(Enum.ItemQuality) ~= "table" then
    return out
  end
  for bag = 0, NUM_BAG_SLOTS do
    local slots = C_Container.GetContainerNumSlots(bag)
    for slot = 1, slots do
      local link = C_Container.GetContainerItemLink(bag, slot)
      if link and ns.isProtected(link) and ns.slotHasValue(bag, slot) then
        local r = { pcall(C_Item.GetItemInfo, link) }
        if r[1] and r[4] == Enum.ItemQuality.Poor then
          out[#out + 1] = { link = link, bag = bag, slot = slot }
        end
      end
    end
  end
  return out
end

-- One gray click: the bulk sale minus keeps and reagents (the bulk call
-- sells set and locked slots too, so this path invents no new keeps).
-- Returns the sold stack count, or 0 when the slot holds.
local function attemptGraySale(it)
  if not ns.merchantOpen() then return 0 end
  if type(C_Container.GetContainerItemLink) ~= "function" then return 0 end
  local okLink, now = pcall(C_Container.GetContainerItemLink, it.bag, it.slot)
  if not okLink or now ~= it.link then return 0 end
  if ns.isProtected(it.link) then return 0 end
  if ns.isCraftingReagent(it.link) then return 0 end
  if not ns.slotHasValue(it.bag, it.slot) then return 0 end
  local count = ns.slotCount(it.bag, it.slot)
  local ok = pcall(C_Container.UseContainerItem, it.bag, it.slot)
  local okGone, after = pcall(C_Container.GetContainerItemLink, it.bag, it.slot)
  if ok and okGone and after ~= it.link then return count end
  return 0
end

-- Sells the gray pile via Blizzard's own API. Kept grays (keeps list
-- plus crafting reagents) never ride the bulk call (it sells
-- everything), so with any kept the rest go one click at a time instead.
-- Returns copper earned and items sold.
function ns.sellGrays()
  if type(C_MerchantFrame) ~= "table" then return 0, 0 end
  if type(C_MerchantFrame.SellAllJunkItems) ~= "function" then return 0, 0 end
  local before = GetMoney()
  if #ns.collectKeptGrays() == 0 then
    local okN, n = pcall(C_MerchantFrame.GetNumJunkItems)
    pcall(C_MerchantFrame.SellAllJunkItems)
    local earned = GetMoney() - before
    return (earned > 0 and earned or 0), (okN and n or 0)
  end
  if type(C_Container) ~= "table" then return 0, 0 end
  if type(C_Container.GetContainerNumSlots) ~= "function"
    or type(C_Container.GetContainerItemLink) ~= "function" then
    return 0, 0
  end
  if type(C_Item) ~= "table" or type(C_Item.GetItemInfo) ~= "function" then
    return 0, 0
  end
  if type(Enum) ~= "table" or type(Enum.ItemQuality) ~= "table" then
    return 0, 0
  end
  local sold = 0
  for bag = 0, NUM_BAG_SLOTS do
    local slots = C_Container.GetContainerNumSlots(bag)
    for slot = 1, slots do
      local link = C_Container.GetContainerItemLink(bag, slot)
      if link then
        local r = { pcall(C_Item.GetItemInfo, link) }
        if r[1] and r[4] == Enum.ItemQuality.Poor then
          sold = sold + attemptGraySale({ link = link, bag = bag, slot = slot })
        end
      end
    end
  end
  local earned = GetMoney() - before
  return (earned > 0 and earned or 0), sold
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

-- Whether a merchant session is open. The MERCHANT_SHOW /
-- MERCHANT_CLOSED pair owns it: the sale runs inside the SHOW dispatch,
-- before the merchant frame itself is shown, so visibility alone reads
-- false there and every item reports "vendor closed". The frame check
-- stays as a fallback (a reload mid-visit never re-fires SHOW).
-- Sale clicks outside a session silently do nothing (a confirm popup
-- outlives its window), so the sale stops with a reason instead of a
-- "still in bags" cascade.
ns.merchant = false

-- Deferred sale. The merchant session is not ready the instant
-- MERCHANT_SHOW fires (its buy list is still on the way), so clicks
-- made inside the SHOW dispatch silently leave items in the bags while
-- a click a moment later sells fine. The visit work therefore waits a
-- beat: a short timer, guarded again at fire time (a closed visit
-- sells nothing - selling outside a session would equip the gear).
-- Without a timer API the work runs now, guarded per item as before.
function ns.deferSale(fn)
  if type(C_Timer) == "table" and type(C_Timer.After) == "function" then
    local ok = pcall(C_Timer.After, 0.5, function()
      if ns.merchantOpen() then fn() end
    end)
    if ok then return end
  end
  if ns.merchantOpen() then fn() end
end

function ns.merchantOpen()
  if ns.merchant == true then return true end
  if type(MerchantFrame) ~= "table" then return false end
  if type(MerchantFrame.IsShown) ~= "function" then return false end
  local ok, shown = pcall(MerchantFrame.IsShown, MerchantFrame)
  return ok and shown == true
end

-- One sale attempt for a candidate: a guard reason, or nil once the
-- click has cleared the slot. Guards (moved, equipment set, vendor
-- value, auction verdict) hold the item without touching it; only a
-- click that errors or leaves the item behind reports a failure.
local function attemptOldGearSale(it, guests)
  if not ns.merchantOpen() then
    return "vendor closed"
  elseif C_Container.GetContainerItemLink(it.bag, it.slot) ~= it.link then
    return "moved"
  elseif ns.isProtected(it.link) then
    return "protected"
  elseif ns.inEquipmentSet(it.bag, it.slot) then
    return "in equipment set"
  elseif not ns.slotHasValue(it.bag, it.slot) then
    return "vendor won't buy"
  elseif ns.isProfessionTool(it.link) then
    return "profession tool"
  elseif ns.opts().compareAuction then
    local auction = ns.getAuctionPrice(it.link, nil, guests)
    local deValue = ns.isDisenchantable(it.link) and ns.getDisenchantValue(it.link, nil, guests) or nil
    local verdict = ns.compareItem(it.price, auction, deValue)
    if verdict == "auction" then
      return "auction worth more (" .. ns.moneyString(ns.auctionNet(auction)) .. " net)"
    elseif verdict == "disenchant" then
      return "disenchant worth more (" .. ns.moneyString(ns.auctionNet(deValue)) .. " net)"
    end
  end
  local ok = pcall(C_Container.UseContainerItem, it.bag, it.slot)
  local still = false
  if type(C_Container.GetContainerItemLink) == "function" then
    local okLink, now = pcall(C_Container.GetContainerItemLink, it.bag, it.slot)
    still = okLink and now == it.link
  end
  if ok and not still then return nil end
  return (not ok) and "sell failed" or "still in bags"
end

-- Sells a candidate list, re-verifying each slot first: bags shift
-- between the dry-run and the click, and we never sell the wrong item.
-- Set membership and vendor value are rechecked too: a slot that joined
-- a set, or that the vendor won't buy, holds without touching anything.
-- Every candidate is attempted: one refusal no longer vetoes the visit,
-- and each click stays independently verified, so a shifted bag still
-- cannot sell the wrong item. Click failures get one second chance
-- after the pass (a transient refusal heals by then; a genuine refusal
-- just fails again and reports). Bounded: one extra click per failed
-- item, never a loop.
-- Quiet: the caller composes the announcement.
-- Returns count, copper, and the leftover list.
function ns.sellOldGearItems(items)
  local n, value = 0, 0
  local leftover = {}
  local failed = {}
  local guests = ns.priceGuests()
  ns.lastVendorError = nil
  if type(C_Container) ~= "table" then return n, value, leftover end
  if type(C_Container.GetContainerItemLink) ~= "function" then return n, value, leftover end
  items = items or {}
  for _, it in ipairs(items) do
    local reason = attemptOldGearSale(it, guests)
    if reason == "sell failed" or reason == "still in bags" then
      failed[#failed + 1] = it
    elseif reason then
      leftover[#leftover + 1] = leftoverEntry(it, reason)
    else
      n = n + 1
      value = value + (it.price or 0)
    end
  end
  for _, it in ipairs(failed) do
    local reason = attemptOldGearSale(it, guests)
    if reason then
      leftover[#leftover + 1] = leftoverEntry(it, reason)
    else
      n = n + 1
      value = value + (it.price or 0)
    end
  end
  return n, value, leftover
end

-- ======= Vendor wins =======
-- Items the vendor buys above the auction net: with Auctionator,
-- TradeSkillMaster, or Oribos data saying the auction house nets less
-- than the vendor price (net of the 5% cut), the vendor is the better
-- sale. Opt-in only (sellVendorWins): nothing here sells on the junk
-- definition alone. The ilvl gap does not apply; every keep gate does.
-- No price data means keep: an unknown auction value never sells.
function ns.isVendorWins(link, bag, slot, scan, guests)
  if not link then return false end
  guests = guests or ns.priceGuests()
  if not (guests.auctionator or guests.tsm or guests.oribos) then
    return false
  end
  if ns.isProtected(link) then return false end
  if ns.isCraftingReagent(link) then return false end
  if ns.inEquipmentSet(bag, slot) then return false end
  if not ns.slotHasValue(bag, slot) then return false end
  if type(C_Item) ~= "table"
    or type(C_Item.GetItemInfo) ~= "function" then
    return false
  end
  local r = { pcall(C_Item.GetItemInfo, link) }
  if not r[1] then return false end
  -- Past the pcall flag: quality is the 3rd return, the vendor price
  -- the 11th, class the 12th, bind type the 14th, reagent the 17th.
  local quality, sellPrice, classID, bindType = r[4], r[12], r[13], r[15]
  if not quality then return false end
  if quality == Enum.ItemQuality.Poor then return false end
  if quality == Enum.ItemQuality.Heirloom then return false end
  if not sellPrice or sellPrice == 0 then return false end
  -- Crafting reagents never sell here, whatever the vendor offers.
  if r[18] == true then return false end
  -- Consumables defer to the consumable sale (winners keep a stack
  -- there); this sweep never thins them, categorized or not.
  if type(Enum) == "table" and type(Enum.ItemClass) == "table"
    and classID == Enum.ItemClass.Consumable then
    return false
  end
  if ns.questKeeps(link) then return false end
  if ns.isUncollectedCollectible(link, scan and scan.memo) then
    return false
  end
  if ns.isProfessionTool(link) then return false end
  local o = ns.opts()
  if bindType == Enum.ItemBind.OnEquip and not o.oldGearBoE then
    return false
  end
  if ns.isWarbound(link) and not o.oldGearWarbound then return false end
  if ns.pawnSaysUpgrade(link) then return false end
  if ns.autoGearSaysUpgrade(link, scan) then return false end
  local auction = ns.getAuctionPrice(link, nil, guests)
  if not auction then return false end
  -- Strictly above: ties keep, since this sweep sells items the junk
  -- definition alone would leave behind.
  if sellPrice <= ns.auctionNet(auction) then return false end
  if not o.keepDisenchantable then
    -- The keep is off: still hold when disenchanting nets more, the
    -- same guard the old-gear sale applies at the click.
    if ns.isDisenchantable(link) then
      local deValue = ns.getDisenchantValue(link, nil, guests)
      if deValue and ns.auctionNet(deValue) > sellPrice then
        return false
      end
    end
  else
    -- The keep is on: disenchantables divert to the disenchant list,
    -- never to this sale.
    local canDE = scan and scan.canDE
    if canDE == nil then canDE = ns.canDisenchant() end
    if canDE and ns.isDisenchantable(link) then return false end
  end
  return true
end

-- Every vendor-wins bag slot right now, minus already-claimed slots.
-- One guest resolution and one scan serve the whole sweep.
function ns.collectVendorWins(exclude)
  if not ns.opts().sellVendorWins then return {} end
  local guests = ns.priceGuests()
  if not (guests.auctionator or guests.tsm or guests.oribos) then
    return {}
  end
  local out = {}
  local scan = { canDE = ns.canDisenchant(), memo = {}, scores = {} }
  for bag = 0, NUM_BAG_SLOTS do
    local slots = C_Container.GetContainerNumSlots(bag)
    for slot = 1, slots do
      if not (exclude and exclude[bag .. ":" .. slot]) then
        local link = C_Container.GetContainerItemLink(bag, slot)
        if link and ns.isVendorWins(link, bag, slot, scan, guests) then
          local _, _, _, _, _, _, _, _, _, _, sellPrice =
            C_Item.GetItemInfo(link)
          out[#out + 1] = { link = link, bag = bag, slot = slot,
            price = sellPrice or 0, count = ns.slotCount(bag, slot) }
        end
      end
    end
  end
  return out
end

-- One sale attempt for a vendor-wins candidate: a guard reason, or the
-- sold count once the click has cleared the slot. The auction verdict
-- is re-read here: data arriving between the dry-run and the click
-- holds the item instead of selling it short.
local function attemptVendorWinsSale(it, guests)
  if not ns.merchantOpen() then
    return "vendor closed", 0
  elseif C_Container.GetContainerItemLink(it.bag, it.slot) ~= it.link then
    return "moved", 0
  elseif ns.isProtected(it.link) then
    return "protected", 0
  elseif ns.inEquipmentSet(it.bag, it.slot) then
    return "in equipment set", 0
  elseif not ns.slotHasValue(it.bag, it.slot) then
    return "vendor won't buy", 0
  elseif ns.isProfessionTool(it.link) then
    return "profession tool", 0
  elseif ns.opts().compareAuction then
    local auction = ns.getAuctionPrice(it.link, nil, guests)
    local deValue = ns.isDisenchantable(it.link)
      and ns.getDisenchantValue(it.link, nil, guests) or nil
    local verdict = ns.compareItem(it.price, auction, deValue)
    if verdict == "auction" then
      return "auction worth more (" .. ns.moneyString(ns.auctionNet(auction)) .. " net)", 0
    elseif verdict == "disenchant" then
      return "disenchant worth more (" .. ns.moneyString(ns.auctionNet(deValue)) .. " net)", 0
    end
  end
  local count = ns.slotCount(it.bag, it.slot)
  local ok = pcall(C_Container.UseContainerItem, it.bag, it.slot)
  local still = false
  if type(C_Container.GetContainerItemLink) == "function" then
    local okLink, now = pcall(C_Container.GetContainerItemLink, it.bag, it.slot)
    still = okLink and now == it.link
  end
  if ok and not still then return nil, count end
  return ((not ok) and "sell failed" or "still in bags"), 0
end

-- Sells a vendor-wins list with the same attempt-everything contract
-- as the other sales: one refusal never vetoes the visit, click
-- failures get one second chance, and the caller composes the
-- announcement. Stacks count fully (price times the slot count).
function ns.sellVendorWinsItems(items)
  local n, value = 0, 0
  local leftover = {}
  local failed = {}
  local guests = ns.priceGuests()
  ns.lastVendorError = nil
  if type(C_Container) ~= "table" then return n, value, leftover end
  if type(C_Container.GetContainerItemLink) ~= "function" then
    return n, value, leftover
  end
  items = items or {}
  for _, it in ipairs(items) do
    local reason, count = attemptVendorWinsSale(it, guests)
    if reason == "sell failed" or reason == "still in bags" then
      failed[#failed + 1] = it
    elseif reason then
      leftover[#leftover + 1] = leftoverEntry(it, reason)
    else
      n = n + (count or 1)
      value = value + (it.price or 0) * (count or 1)
    end
  end
  for _, it in ipairs(failed) do
    local reason, count = attemptVendorWinsSale(it, guests)
    if reason then
      leftover[#leftover + 1] = leftoverEntry(it, reason)
    else
      n = n + (count or 1)
      value = value + (it.price or 0) * (count or 1)
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
    print("  " .. tostring(it.link) .. " (" .. it.reason
      .. (it.detail and ("; " .. it.detail) or "") .. ")")
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
    -- Stacked rows (vendor wins) carry their slot count; single-piece
    -- gear has none and still counts one.
    local n = tonumber(it.count) or 1
    g.qty = g.qty + n
    g.total = g.total + (it.price or 0) * n
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

-- ======= Sales and repair =======
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
    and #(junk.vendorWins or {}) == 0
    and #kept == 0 and #dead == 0 then
    return
  end
  local earned = 0
  local nGray = 0
  ns.reportKept(kept)
  ns.reportDead(dead)
  if junk.grayCount > 0 then
    earned, nGray = ns.sellGrays()
  end
  local nOld, oldValue, leftover = ns.sellOldGearItems(junk.oldGear)
  local nExp, expValue, leftoverExp = ns.sellOldGearItems(junk.expJunk)
  for _, it in ipairs(leftoverExp) do leftover[#leftover + 1] = it end
  local nVw, vwValue, leftoverVw = ns.sellVendorWinsItems(junk.vendorWins)
  for _, it in ipairs(leftoverVw) do leftover[#leftover + 1] = it end
  ns.reportLeftover(leftover)
  if nGray + nOld + nExp + nVw > 0 then
    ns.sellSound()
    ns.recordSale(nGray + nOld + nExp + nVw, earned + oldValue + expValue + vwValue)
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
  -- The session starts before anything else: the sale below runs inside
  -- this dispatch, ahead of the merchant frame showing itself.
  ns.merchant = true
  -- A visit whose close we missed (reload mid-visit) still gets its one
  -- line before the new visit starts counting.
  ns.flushVisit()
  ns.hookJunkButton()
  ns.ensureMerchantSearch() -- the goods search box, built once
  ns.hookMerchantSearch() -- re-apply the dim after every refresh
  ns.applyMerchantSearch() -- names may still be arriving; the hook re-applies
  ns.ensureAmmoButton() -- the Fill Ammo button, built once
  ns.refreshAmmoButton() -- only shows for an ammo user with ammo to buy
  local o = ns.opts()
  if o.autoSell or o.sellConsumables or o.autoRepair then
    -- Deferred a beat: clicks inside the SHOW dispatch silently fail
    -- (the session is not ready yet) while a moment later they sell
    -- fine. Sale first, so junk gold pays for the repair that follows.
    ns.deferSale(function()
      local live = ns.opts()
      if live.autoSell then ns.autoSell() end
      if live.sellConsumables then
        local sale = ns.collectConsumableSale()
        if #sale > 0 then
          if live.autoSellConsumables then ns.sellConsumablesNow(sale)
          else ns.reportConsumables(sale) end
        end
      end
      if live.autoRepair then ns.repairNow() end
    end)
  end
end

-- Visit close: the one deferred line for everything sold since SHOW.
function ns.onMerchantClosed()
  ns.merchant = false
  ns.flushVisit()
end

-- ======= Sell Junk hook =======
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
  if not ns.opts().junkOldGear and not ns.opts().sellVendorWins then
    setEnabled(false)
    return
  end
  local junk = ns.collectJunk()
  setEnabled(junk.grayCount > 0 or #junk.oldGear > 0 or #junk.expJunk > 0
    or #(junk.vendorWins or {}) > 0)
end

-- Manual path (native button or /vv): same definition as auto-sell, but
-- old gear goes through the itemized dry-run first. Grays alone keep
-- Blizzard's original click and popup.
function ns.onJunkButtonClick(button)
  local kept = ns.collectKeptDisenchantables()
  local dead = ns.collectDeadItems()
  local junk = ns.collectJunk()
  junk.vendorWins = junk.vendorWins or {}
  if junk.grayCount == 0 and #junk.oldGear == 0 and #junk.expJunk == 0
    and #junk.vendorWins == 0 then
    if #kept > 0 then
      ns.reportKept(kept, true)
    elseif #dead > 0 then
      ns.reportDead(dead, true)
    else
      ns.say("nothing to sell")
    end
    return
  end
  -- Kept grays (keeps list plus crafting reagents) never ride
  -- Blizzard's own click (it sells everything), so a pure-gray pile
  -- with keeps sells one click at a time instead.
  local keptGray = ns.collectKeptGrays()
  local sellableGray = math.max(0, junk.grayCount - #keptGray)
  if #junk.oldGear == 0 and #junk.expJunk == 0 and #junk.vendorWins == 0 then
    if #keptGray == 0 then
      if type(ns.blizzJunkClick) == "function" then
        ns.blizzJunkClick(button)
      end
      return
    end
    local earned, nGray = ns.sellGrays()
    if nGray > 0 then
      ns.sellSound()
      ns.recordSale(nGray, earned)
    else
      ns.say("kept " .. (#keptGray == 1 and "1 gray"
        or #keptGray .. " gray"))
    end
    return
  end
  local sale = {}
  for _, list in ipairs({ junk.oldGear, junk.expJunk, junk.vendorWins }) do
    for _, it in ipairs(list) do sale[#sale + 1] = it end
  end
  local total = 0
  for _, it in ipairs(sale) do
    total = total + (it.price or 0) * (it.count or 1)
  end
  local header = "junk to sell (" .. sellableGray .. " gray, "
    .. #junk.oldGear .. " old gear, " .. #junk.expJunk .. " expansion"
    .. (#junk.vendorWins > 0 and ", " .. #junk.vendorWins .. " vendor wins" or "")
    .. "):"
  ns.say(header)
  for _, g in ipairs(ns.mergeByID(sale)) do print(ns.mergedLine(g)) end
  StaticPopup_Show("VOCVENDOR_SELL_JUNK",
    sellableGray + #sale, ns.moneyString(total),
    { grayCount = sellableGray, oldGear = junk.oldGear,
      expJunk = junk.expJunk, vendorWins = junk.vendorWins })
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
    earned, nGray = ns.sellGrays()
  end
  local nOld, oldValue, leftover = ns.sellOldGearItems(data.oldGear)
  local nExp, expValue, leftoverExp = ns.sellOldGearItems(data.expJunk)
  for _, it in ipairs(leftoverExp) do leftover[#leftover + 1] = it end
  local nVw, vwValue, leftoverVw = ns.sellVendorWinsItems(data.vendorWins)
  for _, it in ipairs(leftoverVw) do leftover[#leftover + 1] = it end
  ns.reportLeftover(leftover)
  if nGray + nOld + nExp + nVw > 0 then
    ns.sellSound()
    ns.recordSale(nGray + nOld + nExp + nVw, earned + oldValue + expValue + vwValue)
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

-- ======= Merchant search =======
-- A bag-style search box on Blizzard's own merchant window: type to dim
-- the goods that do not match, page freely, clear to restore. Matching
-- is a case-insensitive substring on the displayed name. The buyback tab
-- is untouched: switching to it parks the box and restores full
-- brightness. Everything is presence-gated: without the merchant frame
-- or its API the box never builds and the update hook never installs.
--
-- Sources of truth (both clients, same shape and flow): Vanilla and
-- Mainline MerchantFrame.lua address rows as _G["MerchantItem"..i]
-- across pages of MERCHANT_ITEMS_PER_PAGE (10) under
-- MerchantFrame_Update, gated on MerchantFrame.selectedTab == 1 for
-- goods. Names come from C_MerchantFrame.GetItemInfo(index) (documented
-- on both branches, and the only read live Mainline uses); the bare
-- GetMerchantItemInfo(index) with the name first (Vanilla's own call)
-- covers clients without the namespace. SearchBoxTemplate is
-- Blizzard's own in Shared InputBoxTemplates.xml on both branches.
ns.merchantSearch = ""
ns.merchantSearchHooked = false
ns.merchantSearchBox = nil
ns.merchantRowHit = {} -- per-row match flags, by visible row 1..10

-- The displayed name for this merchant row index: the name, nil for
-- an empty slot, or false when unreadable. C_MerchantFrame is the read
-- Blizzard's own update uses on both clients; the bare read covers
-- clients without the namespace. Every call is pcall-guarded.
function ns.merchantIndexName(index)
  if type(C_MerchantFrame) == "table"
    and type(C_MerchantFrame.GetItemInfo) == "function" then
    local ok, info = pcall(C_MerchantFrame.GetItemInfo, index)
    if ok and type(info) == "table" then
      if type(info.name) == "string" and info.name ~= "" then
        return info.name
      end
      return nil
    end
  end
  if type(GetMerchantItemInfo) == "function" then
    local okBare, itemName = pcall(GetMerchantItemInfo, index)
    if okBare then
      if type(itemName) == "string" and itemName ~= "" then
        return itemName
      end
      return nil
    end
  end
  return false
end

-- True when this merchant row index matches the query: a refused read
-- matches nothing typed, while an empty slot (no name) stays bright -
-- there is nothing to filter there.
function ns.merchantIndexMatches(index, query)
  if query == "" then return true end
  local itemName = ns.merchantIndexName(index)
  if itemName == nil then return true end
  if itemName == false then return false end
  return itemName:lower():find(query, 1, true) ~= nil
end

-- Dims merchant rows that do not match, in place like the bag search.
-- Runs after every Blizzard refresh (paging, tab switches, stock
-- updates): the update hook owns re-application, typing only stores the
-- query. Returns the hit count on the goods tab, nil elsewhere.
function ns.applyMerchantSearch()
  if type(MerchantFrame) ~= "table" then return nil end
  local perPage = tonumber(MERCHANT_ITEMS_PER_PAGE) or 10
  local query = type(ns.merchantSearch) == "string" and ns.merchantSearch or ""
  local box = ns.merchantSearchBox
  if MerchantFrame.selectedTab ~= 1 then
    -- Buyback: park the box, restore the rows.
    if type(box) == "table" then
      if type(box.ClearFocus) == "function" then box:ClearFocus() end
      if type(box.Hide) == "function" then box:Hide() end
    end
    for i = 1, perPage do
      local row = _G["MerchantItem" .. i]
      if type(row) == "table" and type(row.IsShown) == "function" and row:IsShown() then
        ns.merchantRowHit[i] = true
        if type(row.SetAlpha) == "function" then row:SetAlpha(1) end
      end
    end
    return nil
  end
  if type(box) == "table" and type(box.Show) == "function" then box:Show() end
  local page = tonumber(MerchantFrame.page) or 1
  local hits = 0
  for i = 1, perPage do
    local index = (page - 1) * perPage + i
    local row = _G["MerchantItem" .. i]
    if type(row) == "table" and type(row.IsShown) == "function" and row:IsShown() then
      local hit = ns.merchantIndexMatches(index, query)
      ns.merchantRowHit[i] = hit
      if type(row.SetAlpha) == "function" then row:SetAlpha(hit and 1 or 0.35) end
      if hit then hits = hits + 1 end
    end
  end
  return hits
end

-- Builds the search box once, on first merchant visit. SearchBoxTemplate
-- is Blizzard's own (its hint and clear button come with it); the
-- InputBoxTemplate fallback covers clients without it. The template
-- owns its own text-changed behavior, so the query hooks on (never
-- replacing it), with a plain set as the last resort.
function ns.ensureMerchantSearch()
  if ns.merchantSearchBox then return ns.merchantSearchBox end
  if type(MerchantFrame) ~= "table" then return nil end
  if type(CreateFrame) ~= "function" then return nil end
  local box = nil
  local ok, made = pcall(CreateFrame, "EditBox", nil, MerchantFrame, "SearchBoxTemplate")
  if ok and made ~= nil then box = made end
  if not box then
    local okFb, madeFb = pcall(CreateFrame, "EditBox", nil, MerchantFrame, "InputBoxTemplate")
    if okFb and madeFb ~= nil then box = madeFb end
  end
  if not box then return nil end
  box:SetSize(150, 20)
  box:SetPoint("TOPRIGHT", MerchantFrame, "TOPRIGHT", -34, -30)
  if type(box.SetAutoFocus) == "function" then box:SetAutoFocus(false) end
  if box.Instructions and type(box.Instructions.SetText) == "function" then
    box.Instructions:SetText("Search")
  end
  local function onQuery(self)
    local text = ""
    if type(self.GetText) == "function" then text = self:GetText() or "" end
    ns.merchantSearch = strtrim(text):lower()
    ns.applyMerchantSearch()
  end
  if type(box.HookScript) == "function" then
    box:HookScript("OnTextChanged", onQuery)
    box:HookScript("OnEnter", function(self)
      if type(IsMouseButtonDown) == "function" and IsMouseButtonDown() then return end
      if type(GameTooltip) ~= "table" then return end
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:AddLine("Find goods by name - non-matches dim",
        COLORS.text[1], COLORS.text[2], COLORS.text[3])
      GameTooltip:Show()
    end)
    box:HookScript("OnLeave", function()
      if type(GameTooltip) == "table" then GameTooltip:Hide() end
    end)
  elseif type(box.SetScript) == "function" then
    box:SetScript("OnTextChanged", onQuery)
  end
  if type(MerchantFrame.HookScript) == "function" then
    pcall(MerchantFrame.HookScript, MerchantFrame, "OnHide", function()
      -- A closed merchant reopens unfiltered, like the bags do.
      if type(box.GetText) == "function" and type(box.SetText) == "function"
        and box:GetText() ~= "" then
        box:SetText("")
      end
      ns.merchantSearch = ""
    end)
  end
  ns.merchantSearchBox = box
  return box
end

-- Post-hook: re-apply the dim after Blizzard rebuilds the rows (paging,
-- tab switches, MERCHANT_UPDATE stock refreshes). Never replaces the
-- update, only reads after it.
function ns.hookMerchantSearch()
  if ns.merchantSearchHooked then return end
  if type(hooksecurefunc) ~= "function" then return end
  if type(MerchantFrame) ~= "table" then return end
  if type(MerchantFrame_Update) ~= "function" then return end
  hooksecurefunc("MerchantFrame_Update", ns.onMerchantUpdated)
  ns.merchantSearchHooked = true
end

-- One post-hook serves both merchant extras: the search dim and the ammo
-- button visibility, re-applied after every Blizzard refresh.
function ns.onMerchantUpdated()
  ns.applyMerchantSearch()
  ns.refreshAmmoButton()
end

-- ======= Fill Ammo (Forever hunters) =======
-- Hunters on the Forever client shoot ammo: arrows live in a quiver, bullets
-- in an ammo pouch. When the player uses ammo and the vendor sells something
-- usable, the merchant window grows a Fill Ammo button; one click buys the
-- best usable ammo until every quiver and ammo pouch holds full stacks.
--
-- Sources of truth (forever branch only; Retail hides: neither ammo API is
-- there): UnitUsesAmmo(unit) -> bool (UnitDocumentation) and
-- C_PaperDollInfo.AmmoNeeded() -> bool (PaperDollInfoDocumentation) gate the
-- whole feature. C_PaperDollInfo.GetInventorySlotInfo("AmmoSlot") names the
-- equipped-ammo slot (PaperDollFrame.lua matches slotName "AmmoSlot" there),
-- and GetInventoryItemLink reads it; the vendor pick must share its subclass
-- (arrows vs bullets), so bullets never answer for arrows and back.
-- C_Container.GetContainerNumFreeSlots(bag) -> (free, bagFamily) flags the
-- restricted bags, and the equipped bag's own item class
-- (Enum.ItemClass.Quiver = 11, ItemConstantsDocumentation) confirms a quiver
-- or ammo pouch through CharacterBag0Slot:GetID() + bag - 1, Blizzard's own
-- bag-button math (MainMenuBarBagButtons.lua). C_Item.GetItemFamily(itemInfo)
-- (ItemDocumentation) declares what an item fits into, so the quiver's own
-- family names the wanted ammo without any arrow/bullet ID or locale string:
-- arrows land in quivers, bullets in ammo pouches (warcraft.wiki.gg Ammunition
-- prose: arrows were ammo for bows and crossbows, bullets for guns; Blizzard
-- never enumerated the projectile subclasses, so the code never names them).
-- Buying follows Blizzard's own
-- forever Mainline flow: C_MerchantFrame.GetItemInfo(index) describes the
-- goods (MerchantItemInfo: price, stackCount, numAvailable, isPurchasable,
-- isUsable, hasExtendedCost), GetMerchantItemLink(index) links them,
-- GetMerchantNumItems() counts them, GetMerchantItemMaxStack(index) sizes the
-- stacks, and BuyMerchantItem(index[, quantity]) buys them (all called by
-- Blizzard's own MerchantFrame.lua there). Bought ammo lands through the
-- client's own autostore, so the confirm recounts after a beat (like the
-- deferred sale) instead of trusting the click.

-- True when this character shoots ammo. Both reads are pcall-guarded and
-- presence-gated: without them there is no ammo user, no button, no scan.
function ns.usesAmmo()
  if type(UnitUsesAmmo) == "function" then
    local ok, uses = pcall(UnitUsesAmmo, "player")
    if ok and uses == true then return true end
  end
  if type(C_PaperDollInfo) == "table"
    and type(C_PaperDollInfo.AmmoNeeded) == "function" then
    local ok, needed = pcall(C_PaperDollInfo.AmmoNeeded)
    if ok and needed == true then return true end
  end
  return false
end

-- Inventory slot holding the equipped ammo, nil when the client cannot say.
function ns.ammoSlotID()
  if type(C_PaperDollInfo) ~= "table" then return nil end
  if type(C_PaperDollInfo.GetInventorySlotInfo) ~= "function" then return nil end
  local ok, id = pcall(C_PaperDollInfo.GetInventorySlotInfo, "AmmoSlot")
  if ok and type(id) == "number" then return id end
  return nil
end

-- The equipped ammo: link plus its class facts, or nil. Only the subclass
-- matters downstream (arrows vs bullets); unknown keeps every type eligible.
function ns.equippedAmmo()
  local slot = ns.ammoSlotID()
  if not slot then return nil end
  if type(GetInventoryItemLink) ~= "function" then return nil end
  local okL, link = pcall(GetInventoryItemLink, "player", slot)
  if not okL or type(link) ~= "string" then return nil end
  if type(C_Item) ~= "table" or type(C_Item.GetItemInfo) ~= "function" then
    return nil
  end
  local r = { pcall(C_Item.GetItemInfo, link) }
  if not r[1] or r[2] == nil then return nil end
  return { link = link, classID = tonumber(r[13]), subClassID = tonumber(r[14]) }
end

-- Inventory slot holding equipped bag `bag` (1..NUM_BAG_SLOTS), nil when the
-- client cannot say.
function ns.bagInvSlot(bag)
  if type(CharacterBag0Slot) ~= "table" then return nil end
  if type(CharacterBag0Slot.GetID) ~= "function" then return nil end
  local ok, base = pcall(CharacterBag0Slot.GetID, CharacterBag0Slot)
  if ok and type(base) == "number" then return base + (bag - 1) end
  return nil
end

-- True when this bag item is a quiver or ammo pouch (Enum.ItemClass.Quiver).
function ns.isQuiverBagItem(link)
  if not link then return false end
  if type(C_Item) ~= "table" or type(C_Item.GetItemInfo) ~= "function" then
    return false
  end
  if type(Enum) ~= "table" or type(Enum.ItemClass) ~= "table" then return false end
  local quiver = Enum.ItemClass.Quiver or 11
  local r = { pcall(C_Item.GetItemInfo, link) }
  if not r[1] or r[2] == nil then return false end
  return tonumber(r[13]) == quiver
end

-- True when every non-empty slot in this bag holds projectile ammo (and at
-- least one does). The family flag alone cannot name the bag (its values
-- are not documented), so contents decide: a soul bag full of shards is
-- never an ammo bag, whatever its family.
function ns.bagHoldsOnlyAmmo(bag)
  if type(C_Container) ~= "table" then return false end
  if type(C_Container.GetContainerNumSlots) ~= "function"
    or type(C_Container.GetContainerItemLink) ~= "function" then
    return false
  end
  if type(C_Item) ~= "table" or type(C_Item.GetItemInfo) ~= "function" then
    return false
  end
  if type(Enum) ~= "table" or type(Enum.ItemClass) ~= "table" then return false end
  local projectile = Enum.ItemClass.Projectile or 6
  local found = false
  local slots = C_Container.GetContainerNumSlots(bag)
  for slot = 1, slots do
    local link = C_Container.GetContainerItemLink(bag, slot)
    if link then
      local r = { pcall(C_Item.GetItemInfo, link) }
      if not r[1] or r[2] == nil or tonumber(r[13]) ~= projectile then
        return false
      end
      found = true
    end
  end
  return found
end

-- True when no slot in this bag holds anything. Restricted bags read empty
-- on clients that cannot name them, so an empty quiver still fills there.
local function bagIsEmpty(bag)
  if type(C_Container) ~= "table" then return false end
  if type(C_Container.GetContainerNumSlots) ~= "function"
    or type(C_Container.GetContainerItemLink) ~= "function" then
    return false
  end
  local slots = C_Container.GetContainerNumSlots(bag)
  for slot = 1, slots do
    if C_Container.GetContainerItemLink(bag, slot) then return false end
  end
  return true
end

-- The bag's own family (the second GetContainerNumFreeSlots return), or nil
-- when the client cannot say. Zero reads as unknown here: a family the
-- client reports as normal proves nothing about a confirmed ammo bag.
function ns.bagFamily(bag)
  if type(C_Container) ~= "table" then return nil end
  if type(C_Container.GetContainerNumFreeSlots) ~= "function" then return nil end
  local ok, _, family = pcall(C_Container.GetContainerNumFreeSlots, bag)
  if not ok or type(family) ~= "number" or family == 0 then return nil end
  return family
end

-- What this ammo fits into (C_Item.GetItemFamily), or nil when the client
-- cannot say. Links resolve first, item IDs second; either may fail, and a
-- zero reads as unknown the same way the bag side does.
function ns.ammoFamily(link)
  if not link then return nil end
  if type(C_Item) ~= "table" or type(C_Item.GetItemFamily) ~= "function" then
    return nil
  end
  local ok, fam = pcall(C_Item.GetItemFamily, link)
  if ok and type(fam) == "number" and fam ~= 0 then return fam end
  local id = ns.itemID(link)
  if id then
    local okID, famID = pcall(C_Item.GetItemFamily, id)
    if okID and type(famID) == "number" and famID ~= 0 then return famID end
  end
  return nil
end

-- The wanted ammo type, resolved smart from the hunter's own loadout.
-- Every comparison downstream is numeric equality, so no arrow/bullet ID
-- and no locale string ever enters the code:
--   1. the equipped ammo's own subclass (what the hunter shoots right now);
--   2. the ammo bags' own family, when every bag agrees on one nonzero
--      family: the quiver declares what it holds, and the ammo declares
--      what it fits into (a mixed quiver plus pouch decides nothing);
--   3. the reserves' vote: the single distinct subclass across projectile
--      stacks already sitting in the ammo bags.
-- Anything unknowable stays nil, and the scan treats unknown as eligible.
function ns.wantAmmo()
  local want = { sub = nil, family = nil }
  local equipped = ns.equippedAmmo()
  if equipped and equipped.subClassID then want.sub = equipped.subClassID end
  local bags = ns.ammoBags()
  if #bags == 0 then return want end
  local fam, unanimous = nil, true
  for _, bag in ipairs(bags) do
    local f = ns.bagFamily(bag)
    if f == nil then unanimous = false break end
    if fam == nil then fam = f elseif fam ~= f then unanimous = false break end
  end
  if unanimous then want.family = fam end
  if not want.sub then
    if type(C_Item) ~= "table" or type(C_Item.GetItemInfo) ~= "function" then
      return want
    end
    if type(Enum) ~= "table" or type(Enum.ItemClass) ~= "table" then
      return want
    end
    local projectile = Enum.ItemClass.Projectile or 6
    local voted, single = nil, true
    for _, bag in ipairs(bags) do
      local slots = C_Container.GetContainerNumSlots(bag)
      for slot = 1, slots do
        local link = C_Container.GetContainerItemLink(bag, slot)
        if link then
          local r = { pcall(C_Item.GetItemInfo, link) }
          if r[1] and r[2] ~= nil and tonumber(r[13]) == projectile then
            local s = tonumber(r[14])
            if voted == nil then voted = s
            elseif voted ~= s then single = false break end
          end
        end
      end
      if not single then break end
    end
    if single then want.sub = voted end
  end
  return want
end

-- True when this bag may hold this ammo for the fill: same-link stacks
-- always top up (the caller counts those), and empty slots count unless
-- both families are known and disagree (a bullet pouch never fills with
-- arrows). Unknown on either side assumes fit; the confirm recounts.
function ns.bagTakesAmmoType(bag, link)
  local af = ns.ammoFamily(link)
  if af == nil then return true end
  local bf = ns.bagFamily(bag)
  if bf == nil then return true end
  return bf == af
end

-- Every quiver and ammo pouch equipped right now, in bag order. Confirmed
-- bags (the equipped item says quiver) always count; a restricted bag that
-- only holds ammo counts too, so the feature survives a client without the
-- bag buttons. Empty restricted bags count only when nothing confirmed: an
-- empty quiver on a button-less client still fills, while an empty soul bag
-- beside a real quiver never inflates the order.
function ns.ammoBags()
  local out = {}
  if type(C_Container) ~= "table" then return out end
  if type(C_Container.GetContainerNumSlots) ~= "function" then return out end
  local empties = {}
  for bag = 1, NUM_BAG_SLOTS do
    local confirmed = false
    local inv = ns.bagInvSlot(bag)
    if inv and type(GetInventoryItemLink) == "function" then
      local okL, bagLink = pcall(GetInventoryItemLink, "player", inv)
      if okL then confirmed = ns.isQuiverBagItem(bagLink) end
    end
    if confirmed then
      out[#out + 1] = bag
    else
      local restricted = nil
      if type(C_Container.GetContainerNumFreeSlots) == "function" then
        local ok, _, family = pcall(C_Container.GetContainerNumFreeSlots, bag)
        if ok then restricted = family ~= nil and family ~= 0 end
      end
      if restricted then
        if ns.bagHoldsOnlyAmmo(bag) then
          out[#out + 1] = bag
        elseif bagIsEmpty(bag) then
          empties[#empties + 1] = bag
        end
      end
    end
  end
  if #out == 0 then out = empties end
  return out
end

-- Every usable projectile this vendor sells, best first. Best means the
-- highest required level the player meets (stronger ammo needs higher
-- level); ties break by item level, then the lower item ID. A vendor pick
-- must fit the wanted type (ns.wantAmmo), so bullets never answer for
-- arrows. Extended-cost goods never qualify (gold only), and an empty
-- shelf (numAvailable 0) never qualifies either.
function ns.scanMerchantAmmo()
  local out = {}
  if not ns.usesAmmo() then return out end
  if type(C_MerchantFrame) ~= "table"
    or type(C_MerchantFrame.GetItemInfo) ~= "function" then
    return out
  end
  if type(GetMerchantNumItems) ~= "function"
    or type(GetMerchantItemLink) ~= "function" then
    return out
  end
  if type(C_Item) ~= "table" or type(C_Item.GetItemInfo) ~= "function" then
    return out
  end
  if type(Enum) ~= "table" or type(Enum.ItemClass) ~= "table" then return out end
  local projectile = Enum.ItemClass.Projectile or 6
  local okN, num = pcall(GetMerchantNumItems)
  if not okN or type(num) ~= "number" or num <= 0 then return out end
  local want = ns.wantAmmo()
  local level = ns.playerLevel()
  for index = 1, num do
    local okI, info = pcall(C_MerchantFrame.GetItemInfo, index)
    if okI and type(info) == "table" and type(info.name) == "string" then
      if not info.hasExtendedCost and info.numAvailable ~= 0
        and info.isPurchasable ~= false and info.isUsable ~= false then
        local okL, link = pcall(GetMerchantItemLink, index)
        if okL and type(link) == "string" then
          local r = { pcall(C_Item.GetItemInfo, link) }
          if r[1] and r[2] ~= nil and tonumber(r[13]) == projectile then
            local minLevel = tonumber(r[6]) -- 5th return
            local sub = tonumber(r[14]) -- 13th return
            -- The wanted type rules arrows vs bullets: a known subclass
            -- must match exactly, while a known family only excludes what
            -- provably fits elsewhere (unknown on either side stays
            -- eligible, and the bought link names the pick in chat).
            local wrongSub = want.sub ~= nil and sub ~= want.sub
            local wrongFam = false
            if not wrongSub and want.sub == nil and want.family ~= nil then
              local af = ns.ammoFamily(link)
              wrongFam = af ~= nil and af ~= 0 and af ~= want.family
            end
            if (minLevel == nil or level == nil or minLevel <= level)
              and not wrongSub and not wrongFam then
              local maxStack = nil
              if type(GetMerchantItemMaxStack) == "function" then
                local okM, m = pcall(GetMerchantItemMaxStack, index)
                if okM and type(m) == "number" and m > 0 then maxStack = m end
              end
              maxStack = maxStack or tonumber(r[9]) or 1 -- 8th return
              if maxStack < 1 then maxStack = 1 end
              local perStack = tonumber(info.stackCount) or 0
              if perStack <= 0 then perStack = maxStack end
              out[#out + 1] = { index = index, link = link,
                itemID = ns.itemID(link),
                minLevel = minLevel or 0, ilvl = tonumber(r[5]) or 0,
                price = tonumber(info.price) or 0,
                stackCount = perStack,
                numAvailable = tonumber(info.numAvailable),
                maxStack = maxStack }
            end
          end
        end
      end
    end
  end
  table.sort(out, function(a, b)
    if a.minLevel ~= b.minLevel then return a.minLevel > b.minLevel end
    if a.ilvl ~= b.ilvl then return a.ilvl > b.ilvl end
    return (a.itemID or 0) < (b.itemID or 0)
  end)
  return out
end

-- Free units for this ammo across these bags: empty slots take a full
-- stack when the bag may hold the type (ns.bagTakesAmmoType, so a bullet
-- pouch's empties never inflate an arrow order), partial stacks of the
-- same link top up, anything else holds.
function ns.ammoSpace(bags, link, maxStack)
  local free = 0
  if type(C_Container) ~= "table" then return 0 end
  if type(C_Container.GetContainerNumSlots) ~= "function"
    or type(C_Container.GetContainerItemLink) ~= "function" then
    return 0
  end
  for _, bag in ipairs(bags or {}) do
    local slots = C_Container.GetContainerNumSlots(bag)
    for slot = 1, slots do
      local now = C_Container.GetContainerItemLink(bag, slot)
      if not now then
        if ns.bagTakesAmmoType(bag, link) then free = free + maxStack end
      elseif now == link then
        free = free + math.max(0, maxStack - ns.slotCount(bag, slot))
      end
    end
  end
  return free
end

-- Units of this link across every bag, for the Fill Ammo confirm.
function ns.countAmmo(link)
  local n = 0
  if type(C_Container) ~= "table" then return 0 end
  if type(C_Container.GetContainerNumSlots) ~= "function"
    or type(C_Container.GetContainerItemLink) ~= "function" then
    return 0
  end
  for bag = 0, NUM_BAG_SLOTS do
    local slots = C_Container.GetContainerNumSlots(bag)
    for slot = 1, slots do
      if C_Container.GetContainerItemLink(bag, slot) == link then
        n = n + ns.slotCount(bag, slot)
      end
    end
  end
  return n
end

-- "14x link" for whole stacks, raw units otherwise. math.floor keeps the
-- count whole on Lua 5.3+, where / always divides to float.
function ns.ammoBoughtLine(units, maxStack, link)
  if units % maxStack == 0 then
    return math.floor(units / maxStack) .. "x " .. link
  end
  return units .. "x " .. link
end

-- The Fill Ammo click (and /vv ammo): buy the vendor's best usable ammo
-- until the quivers and pouches hold full stacks. Money and the vendor's
-- own stock cap the order; the confirm recounts after a beat, because
-- bought ammo lands through the client's autostore, not the click.
function ns.fillAmmo()
  if not ns.merchantOpen() then
    ns.say("open a vendor first")
    return
  end
  if not ns.usesAmmo() then
    ns.say("this character uses no ammo")
    return
  end
  local goods = ns.scanMerchantAmmo()
  local best = goods[1]
  if not best then
    ns.say("no usable ammo from this vendor")
    return
  end
  local bags = ns.ammoBags()
  if #bags == 0 then
    ns.say("equip a quiver or ammo pouch first")
    return
  end
  local need = ns.ammoSpace(bags, best.link, best.maxStack)
  if need <= 0 then
    ns.say("no room for " .. best.link .. " (quiver full)")
    return
  end
  -- The vendor's own stock caps the order: numAvailable counts the shelf,
  -- unlimited shelves read -1.
  if (best.numAvailable or -1) > 0 then
    need = math.min(need, best.numAvailable * best.stackCount)
  end
  -- Gold caps it too: price buys stackCount units.
  if best.price > 0 and type(GetMoney) == "function" then
    local afford = math.floor(GetMoney() / (best.price / best.stackCount))
    if afford <= 0 then
      ns.say("not enough gold for " .. best.link)
      return
    end
    need = math.min(need, afford)
  end
  if type(BuyMerchantItem) ~= "function" then
    ns.say("can't buy here")
    return
  end
  local before = ns.countAmmo(best.link)
  local bought, remaining = 0, need
  while remaining > 0 do
    local qty = math.min(best.maxStack, remaining)
    local ok
    if qty == best.stackCount then
      ok = pcall(BuyMerchantItem, best.index)
    else
      ok = pcall(BuyMerchantItem, best.index, qty)
    end
    if not ok then break end
    bought, remaining = bought + qty, remaining - qty
  end
  if bought <= 0 then
    ns.say("couldn't buy " .. best.link)
    return
  end
  ns.play("sell") -- the purchase confirms like any other sale
  local planned = ns.ammoBoughtLine(bought, best.maxStack, best.link)
  local function confirm()
    local landed = ns.countAmmo(best.link) - before
    if landed <= 0 then
      ns.say("bought " .. planned .. " (check the bags)")
    elseif landed < bought then
      ns.say("filled ammo: " .. ns.ammoBoughtLine(landed, best.maxStack, best.link)
        .. " (the shelf or the bags ran short)")
    else
      ns.say("filled ammo: " .. planned)
    end
  end
  if type(C_Timer) == "table" and type(C_Timer.After) == "function" then
    pcall(C_Timer.After, 1, confirm)
  else
    ns.say("bought " .. planned)
  end
end

-- The merchant window button, built once on first visit. It sits left of
-- the search box, in the same title band, and only shows for its moment.
ns.ammoButton = nil
function ns.ensureAmmoButton()
  if ns.ammoButton then return ns.ammoButton end
  if type(MerchantFrame) ~= "table" then return nil end
  if type(CreateFrame) ~= "function" then return nil end
  if not ns.usesAmmo() then return nil end -- no ammo user, no button
  local ok, btn = pcall(CreateFrame, "Button", "VocVendorAmmoButton",
    MerchantFrame, "UIPanelButtonTemplate")
  if not ok or btn == nil then return nil end
  btn:SetSize(96, 22)
  local box = ns.merchantSearchBox
  if type(box) == "table" then
    btn:SetPoint("RIGHT", box, "LEFT", -6, 0)
  else
    btn:SetPoint("TOPRIGHT", MerchantFrame, "TOPRIGHT", -190, -30)
  end
  if type(btn.SetText) == "function" then btn:SetText("Fill Ammo") end
  btn:SetScript("OnClick", function() ns.fillAmmo() end)
  if type(btn.HookScript) == "function" then
    btn:HookScript("OnEnter", function(self)
      if type(IsMouseButtonDown) == "function" and IsMouseButtonDown() then return end
      if type(GameTooltip) ~= "table" then return end
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetText("Fill Ammo",
        COLORS.gold[1], COLORS.gold[2], COLORS.gold[3])
      -- One line, naming the pick when the shelf names one.
      local line = "Buy the best ammo here until the quiver or ammo pouch holds full stacks"
      local goods = ns.scanMerchantAmmo()
      if goods[1] then line = "Fill with " .. goods[1].link end
      GameTooltip:AddLine(line,
        COLORS.text[1], COLORS.text[2], COLORS.text[3])
      GameTooltip:Show()
    end)
    btn:HookScript("OnLeave", function()
      if type(GameTooltip) == "table" then GameTooltip:Hide() end
    end)
  end
  btn:Hide() -- refreshAmmoButton owns visibility from here
  ns.ammoButton = btn
  return btn
end

-- Shows the button only for its moment: the setting on, an ammo user, an
-- open merchant on the goods tab, and a vendor whose best usable ammo
-- still has room. A full quiver hides the button; the click then has
-- nothing left to explain.
function ns.refreshAmmoButton()
  local btn = ns.ammoButton
  if not btn then return end
  local show = ns.opts().fillAmmo
    and ns.usesAmmo()
    and ns.merchantOpen()
    and type(MerchantFrame) == "table"
    and MerchantFrame.selectedTab == 1
  if show then
    local goods = ns.scanMerchantAmmo()
    local best = goods[1]
    show = best ~= nil
      and ns.ammoSpace(ns.ammoBags(), best.link, best.maxStack) > 0
  end
  if type(btn.IsShown) == "function" and type(btn.Show) == "function"
    and type(btn.Hide) == "function" then
    if show then btn:Show() else btn:Hide() end
  end
end

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

-- ======= Expansions and dead items =======
-- Expansion data: the item's own expansion ID (C_Item.GetItemInfo
-- return 15, verified against Blizzard's generated docs on live and
-- forever). Fail closed: an unknown item, or an uncached one, is never
-- expansion junk and never a dead item. Grays are unaffected here:
-- the gray sale owns them (reagents keep there too, by flag).
function ns.expansionID(link)
  if type(C_Item) ~= "table" then return nil end
  if type(C_Item.GetItemInfo) ~= "function" then return nil end
  local r = { pcall(C_Item.GetItemInfo, link) }
  if not r[1] then return nil end
  return tonumber(r[16]) -- 15th return, past the pcall flag
end
function ns.expansionChecked(id)
  -- Retail-only checklist: Forever has no expansions (Compat).
  if not ns.hasExpansions() then return false end
  for _, e in ipairs(ns.EXPANSIONS) do
    if e.id == id then return ns.opts()["sell" .. e.key] == true end
  end
  return false
end

-- Crafting reagents always keep: the vendor buys them, but they are
-- profession fuel, not junk (e.g. Pristine Hide). Blizzard's own flag
-- (C_Item.GetItemInfo 17th return, ItemDocumentation on live + forever)
-- names them directly, so no class heuristic is needed. Fail closed the
-- safe way: without the API, or a failed or uncached read, nothing
-- counts as a reagent here, and the callers keep unknown items anyway.
function ns.isCraftingReagent(link)
  if not link then return false end
  if type(C_Item) ~= "table" then return false end
  if type(C_Item.GetItemInfo) ~= "function" then return false end
  local r = { pcall(C_Item.GetItemInfo, link) }
  if not r[1] then return false end
  return r[18] == true -- 17th return, past the pcall flag
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

-- AutoGear guest: the rater on clients without Pawn (Forever). Its
-- tooltip-shown score comes from built-in stat weights there
-- (AutoGear defaults away from Pawn on Forever), so this is the same
-- authorship signal Pawn gives on retail: another addon is a guest
-- (FAMILY.md principle 4), presence-gated and pcall-guarded.
--
-- Two jobs, both fail closed. ns.autoGearSaysUpgrade is the veto, like
-- Pawn: never sell what the guest rates above equipped. ns.gearScore
-- is the primary rank for isOldGear wherever it rates both ends: the
-- guest's stat weights outrank raw item level, so callers sell on a
-- strictly lower score and the ilvl gap covers only what the guest
-- cannot score. A missing guest or a failed read scores nil (unknown
-- keeps), never zero (zero is a score, and it loses). Ties keep: a
-- scored epsilon tie is not proven worse.
-- (No margin cushion: while questing, replacements land a few points
-- below equipped, and a cushion keeps every one of them.)

-- The guest score for one link, or nil. Link-only on purpose, like the
-- Pawn guest: the info reader resolves the slot itself.
function ns.autoGearScoreLink(link)
  if not link then return nil end
  if type(AutoGearReadItemInfo) ~= "function" then return nil end
  if type(AutoGearDetermineItemScore) ~= "function" then return nil end
  local ok, info = pcall(AutoGearReadItemInfo, nil, nil, nil, nil, nil, link)
  if not ok or type(info) ~= "table" or info.empty then return nil end
  local okS, score = pcall(AutoGearDetermineItemScore, info)
  if not okS or type(score) ~= "number" then return nil end
  return score
end

-- The guest score, memoized per scan by link. Scans already memoize
-- their collectible answers; scores ride the same table shape on
-- scan.scores so one sweep reads each link once.
function ns.gearScore(link, scan)
  if not link then return nil end
  local memo = scan and scan.scores
  if memo and memo[link] ~= nil then return memo[link] or nil end
  local score = ns.autoGearScoreLink(link)
  if memo then memo[link] = score or false end
  return score
end

-- True when the guest rates the link above anything equipped in its
-- slot(s). Same slot walk as the ilvl rank; a strict improvement only,
-- so sidegrades never veto.
function ns.autoGearSaysUpgrade(link, scan)
  local score = ns.gearScore(link, scan)
  if not score then return false end
  if type(C_Item) ~= "table" then return false end
  if type(C_Item.GetItemInfoInstant) ~= "function" then return false end
  if type(GetInventoryItemLink) ~= "function" then return false end
  local _, _, _, equipLoc = C_Item.GetItemInfoInstant(link)
  if not equipLoc or equipLoc == "" then return false end
  local slots = ns.slotPairs[equipLoc] or { ns.primarySlot[equipLoc] }
  for _, slotID in ipairs(slots) do
    if slotID then
      local eqLink = GetInventoryItemLink("player", slotID)
      if eqLink then
        local eqScore = ns.gearScore(eqLink, scan)
        if eqScore and score > eqScore then return true end
      end
    end
  end
  return false
end

-- True when the bag item is weapons/armor gear at least `gap` item levels
-- below everything equipped in its slot(s) -- or strictly lower-scored
-- wherever AutoGear rates both ends -- passing the exclusion
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
-- Profession implements are tools, not junk: fishing poles, skinning
-- knives, mining picks, and profession-class tools/gear. A Classic
-- skinning knife is a Weapon-class Generic-subclass implement sitting
-- in a weapon slot (Forever database: One-Hand Miscellaneous with
-- damage, class 2 sub 14); DF+ implements are ItemClass Profession
-- (19, verified in ItemConstantsDocumentation on live + forever) or
-- sit in the profession equip slots. Fail closed: without the item
-- API nothing counts as a tool here, and the callers keep unknown
-- items anyway.
function ns.isProfessionTool(link)
  if type(C_Item) ~= "table" then return false end
  if type(C_Item.GetItemInfoInstant) ~= "function" then return false end
  if type(Enum) ~= "table" or type(Enum.ItemClass) ~= "table" then return false end
  local ok, _, _, _, equipLoc, _, classID, subClassID =
    pcall(C_Item.GetItemInfoInstant, link)
  if not ok then return false end
  local Profession = Enum.ItemClass.Profession or 19
  local Miscellaneous = Enum.ItemClass.Miscellaneous or 15
  if classID == Profession then return true end
  local fishingpole = 20
  local generic = 14
  if type(Enum.ItemWeaponSubclass) == "table" then
    if Enum.ItemWeaponSubclass.Fishingpole ~= nil then
      fishingpole = Enum.ItemWeaponSubclass.Fishingpole
    end
    if Enum.ItemWeaponSubclass.Generic ~= nil then
      generic = Enum.ItemWeaponSubclass.Generic
    end
  end
  if classID == Enum.ItemClass.Weapon and subClassID == fishingpole then
    return true
  end
  -- Weapon/Generic implements (skinning knives, mining picks): real
  -- weapons always carry a specific subclass (dagger, sword, ...),
  -- while the profession implements share the Generic slot.
  if classID == Enum.ItemClass.Weapon and subClassID == generic then
    return true
  end
  if equipLoc == "INVTYPE_PROFESSION_TOOL"
    or equipLoc == "INVTYPE_PROFESSION_GEAR" then
    return true
  end
  if classID == Miscellaneous and type(equipLoc) == "string" and equipLoc ~= "" then
    if type(ns.slotPairs) == "table" and type(ns.primarySlot) == "table" then
      if ns.slotPairs[equipLoc] ~= nil or ns.primarySlot[equipLoc] ~= nil then
        return true
      end
    end
  end
  return false
end

-- The `why` table is the audit readout (/vv why): when given, the
-- first failing gate names itself in why.reason instead of silently
-- keeping, so a bag that never sells explains itself in one chat line.
function ns.isOldGear(link, gap, ignoreDE, scan, why)
  local function stop(reason)
    if why then why.reason = reason end
    return false
  end
  if ns.isProtected(link) then
    return stop("kept (/vv protect)")
  end
  if ns.isUncollectedCollectible(link, scan and scan.memo) then
    return stop("uncollected appearance, toy, or pet")
  end
  local _, _, _, equipLoc, _, classID = C_Item.GetItemInfoInstant(link)
  if not equipLoc or equipLoc == "" then return stop("not equipment") end
  if classID ~= Enum.ItemClass.Weapon and classID ~= Enum.ItemClass.Armor then
    return stop("not weapon or armor")
  end
  -- Profession implements are tools, not gear: never junk by item
  -- level, whatever is equipped (see ns.isProfessionTool).
  if ns.isProfessionTool(link) then
    return stop("profession tool")
  end
  local _, _, quality, _, _, _, _, _, _, _, sellPrice, _, _, bindType =
    C_Item.GetItemInfo(link)
  if not quality then return stop("unknown item") end
  if quality == Enum.ItemQuality.Heirloom then return stop("heirloom") end
  if not sellPrice or sellPrice == 0 then return stop("vendor won't buy") end
  local o = ns.opts()
  if bindType == Enum.ItemBind.OnEquip and not o.oldGearBoE then
    return stop("Bind on Equip (off)")
  end
  if ns.isWarbound(link) and not o.oldGearWarbound then
    return stop("Warbound (off)")
  end
  if not ignoreDE and o.keepDisenchantable and ns.isDisenchantable(link) then
    -- canDE is the per-scan hoist; nil resolves live for direct calls.
    local canDE = scan and scan.canDE
    if canDE == nil then canDE = ns.canDisenchant() end
    if canDE then return stop("kept for disenchanting") end
  end
  if ns.pawnSaysUpgrade(link) then return stop("Pawn rates it an upgrade") end
  if ns.autoGearSaysUpgrade(link, scan) then
    return stop("AutoGear rates it an upgrade")
  end
  local slots = ns.slotPairs[equipLoc] or { ns.primarySlot[equipLoc] }
  local candLevel = C_Item.GetDetailedItemLevelInfo(link)
  local candScore = ns.gearScore(link, scan)
  -- Score-first: the guest outranks raw ilvl wherever it rates both
  -- ends. Same-level gear clusters within a point or two of ilvl
  -- while stats differ (Forever quest greens), so an ilvl gap alone
  -- keeps nearly everything. Score mode needs the candidate plus
  -- anything equipped in its slots scored; otherwise the ilvl gap
  -- covers the item, and an item with neither metric keeps.
  local useScore = candScore ~= nil
  if useScore then
    useScore = false
    for _, slotID in ipairs(slots) do
      if slotID then
        local eqLink = GetInventoryItemLink("player", slotID)
        if eqLink and ns.gearScore(eqLink, scan) then
          useScore = true
          break
        end
      end
    end
  end
  if not useScore and candLevel == nil and candScore == nil then
    return stop("no AutoGear score")
  end
  local compared, best = false, 0
  for _, slotID in ipairs(slots) do
    if slotID then
      local eqLink = GetInventoryItemLink("player", slotID)
      if eqLink then
        if useScore then
          local eqScore = ns.gearScore(eqLink, scan)
          if eqScore then
            compared = true
            if eqScore > best then best = eqScore end
            -- Below the weakest equipped score, or keep.
            if candScore >= eqScore then
              return stop("score " .. candScore .. " vs " .. eqScore .. " equipped")
            end
          end
        else
          local eqLevel = C_Item.GetDetailedItemLevelInfo(eqLink)
          if eqLevel and candLevel then
            compared = true
            if eqLevel > best then best = eqLevel end
            -- Below the weakest equipped piece by the full gap, or keep.
            if candLevel + gap > eqLevel then
              return stop("within " .. gap .. " ilvls of " .. eqLevel .. " equipped")
            end
          end
        end
      end
    end
  end
  if not compared then return stop("nothing equipped to compare") end
  if why then
    why.reason = "sells: " .. (useScore
      and ("score " .. candScore .. " vs " .. best .. " equipped")
      or ("ilvl " .. candLevel .. ", " .. gap .. " below " .. best .. " equipped"))
  end
  return true
end

-- Diagnose the old-gear definition over the bags: one line per
-- weapon/armor piece naming the verdict, so a bag that never sells
-- explains itself instead of staying silent.
function ns.diagOldGear()
  local gap = ns.opts().oldGearIlvlGap or 30
  local scan = { canDE = ns.canDisenchant(), memo = {}, scores = {} }
  local lines = {}
  for bag = 0, NUM_BAG_SLOTS do
    local slots = C_Container.GetContainerNumSlots(bag)
    for slot = 1, slots do
      local link = C_Container.GetContainerItemLink(bag, slot)
      if link then
        local _, _, _, equipLoc, _, classID = C_Item.GetItemInfoInstant(link)
        if equipLoc and equipLoc ~= ""
          and (classID == Enum.ItemClass.Weapon or classID == Enum.ItemClass.Armor) then
          local why = {}
          ns.isOldGear(link, gap, nil, scan, why)
          lines[#lines + 1] = (why.reason or "keeps") .. ": " .. tostring(link)
        end
      end
    end
  end
  if #lines == 0 then
    ns.say("no gear in bags")
  else
    ns.play("open") -- the verdicts are the readout
    for _, line in ipairs(lines) do ns.say(line) end
  end
end

function ns.collectOldGear()
  local gap = ns.opts().oldGearIlvlGap or 30
  local out = {}
  -- Per-scan hoists: the enchanter gate is player-level, and collectible
  -- lookups repeat per item ID, so resolve and memoize once per sweep.
  local scan = { canDE = ns.canDisenchant(), memo = {}, scores = {} }
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
-- whatever the type, except crafting reagents (profession fuel, never
-- junk) and confidently placed consumables: those belong
-- to the consumable sale, where winners keep one stack and losers sell
-- with a summary. The check on the row is the consent, so the ilvl
-- gap does not apply here; every keep gate does (equipment sets,
-- transmog/toy/pet, Pawn upgrades, live quest items, heirlooms,
-- profession tools), and disenchantables divert to the disenchant list
-- first unless ignoreDE.
function ns.isExpansionJunk(link, bag, slot, ignoreDE, scan)
  -- Retail-only: Forever has no expansions (Compat).
  if not ns.hasExpansions() then return false end
  if ns.isProtected(link) then return false end
  if ns.isCraftingReagent(link) then return false end
  local id = ns.expansionID(link)
  if id == nil or not ns.expansionChecked(id) then return false end
  if ns.isProfessionTool(link) then return false end
  if ns.inEquipmentSet(bag, slot) then return false end
  if not ns.slotHasValue(bag, slot) then return false end
  if ns.consumableCategory(link, scan and scan.descs) ~= nil then return false end
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
  if not ns.hasExpansions() then return out end
  local scan = { canDE = ns.canDisenchant(), memo = {}, descs = {} }
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
  -- Retail-only: the delete list is checked-expansion leftovers (Compat).
  if not ns.hasExpansions() then return nil end
  if ns.isProtected(link) then return nil end
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
  if not ns.hasExpansions() then return out end
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

-- ======= Ranks and keeps =======
-- Gear kept for disenchanting: items that would sell but for the
-- disenchant exclusion, from the old-gear gap or a checked expansion.
-- Only non-empty when the toggle is on, the player can disenchant, and
-- something is actually for sale; everyone else skips the scan.
function ns.anyExpansionChecked()
  if not ns.hasExpansions() then return false end
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
  local scan = { canDE = true, memo = {}, scores = {} }
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
      COLORS.text[1], COLORS.text[2], COLORS.text[3])
    if type(InCombatLockdown) == "function" and InCombatLockdown() then
      GameTooltip:AddLine("Does not work in combat",
        COLORS.red[1], COLORS.red[2], COLORS.red[3])
    end
    GameTooltip:Show()
  end)
  row:SetScript("OnLeave", function()
    if type(GameTooltip) == "table" then GameTooltip:Hide() end
  end)
  return row
end

-- ======= Disenchant and delete windows =======
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
    ns.play("open") -- the chat list is the readout on window-less clients
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
  -- Tooltip contract (gold title is the item link itself): one white
  -- line saying what the row does, and a red line while it cannot.
  row:SetScript("OnEnter", function(self)
    if type(IsMouseButtonDown) == "function" and IsMouseButtonDown() then return end
    if type(GameTooltip) ~= "table" then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetHyperlink(self.deLink)
    GameTooltip:AddLine("Click to delete (confirms first)",
      COLORS.text[1], COLORS.text[2], COLORS.text[3])
    if type(InCombatLockdown) == "function" and InCombatLockdown() then
      GameTooltip:AddLine("Does not work in combat",
        COLORS.red[1], COLORS.red[2], COLORS.red[3])
    end
    GameTooltip:Show()
  end)
  row:SetScript("OnLeave", function()
    if type(GameTooltip) == "table" then GameTooltip:Hide() end
  end)
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
    ns.play("open") -- the chat list is the readout on window-less clients
    local what = #dead == 1 and "1 item" or #dead .. " items"
    ns.say("dead items the vendor won't buy (" .. what .. "):")
    for _, it in ipairs(dead) do print("  " .. tostring(it.link)) end
  end
end

-- ======= Settings =======
-- Settings. Every setting carries a value-changed callback (FAMILY.md
-- "Settings"): the definition reads live on every event, and a change
-- mid-visit re-evaluates the merchant button at once.
function ns.onSettingChanged(setting, fn)
  if setting and type(setting.SetValueChangedCallback) == "function" then
    setting:SetValueChangedCallback(fn)
  end
end
ns.settingsBuilt = false
function ns.ensureSettings()
  if ns.settingsBuilt then return end
  if type(Settings) ~= "table" then return end
  if type(Settings.RegisterVerticalLayoutCategory) ~= "function" then return end
  local category = Settings.RegisterVerticalLayoutCategory("VocVendor")
  Settings.RegisterAddOnCategory(category)
  local db = ns.opts() -- bound, defaulted table
  local now = ns.now()
  -- A fresh (New) tag while the feature is still unseen and inside the
  -- 7-day horizon; the panel builds once, so the tag expires next load.
  local function newLabel(base, key)
    if key and ns.isNew(key, now) then return base .. " (New)" end
    return base
  end
  -- Blizzard's own section headers (presence-gated): without them the
  -- panel builds exactly as before, one flat list.
  local canHead = type(Settings.RegisterInitializer) == "function"
    and type(CreateSettingsListSectionHeaderInitializer) == "function"
  local function header(title, tooltip)
    if not canHead then return end
    local ok, init = pcall(CreateSettingsListSectionHeaderInitializer, title, tooltip)
    if ok and init ~= nil then
      pcall(Settings.RegisterInitializer, category, init)
    end
  end
  -- Child options gate on their parent: off shows them disabled, never
  -- hidden, with the reason on the parent row (FAMILY.md "Settings").
  local function gateChild(childInit, parentInit, parentKey)
    if type(childInit) == "table"
      and type(childInit.SetParentInitializer) == "function" then
      childInit:SetParentInitializer(parentInit, function()
        return ns.opts()[parentKey] == true
      end)
    end
  end
  local function check(key, label, tooltip, onChange)
    local s = Settings.RegisterAddOnSetting(
      category, "VocVendor_" .. key, key, db, type(defaults[key]), newLabel(label, key), defaults[key])
    local init = Settings.CreateCheckbox(category, s, tooltip)
    ns.onSettingChanged(s, onChange or ns.refreshJunkButton)
    return init
  end
  header("Selling",
    "What counts as junk and how it sells. Item keeps live in /vv protect: type a name or ID, or shift-click an item (commas ok), click a row to unkeep.")
  check("autoSell", "Auto-sell junk",
    "Sell junk automatically on every vendor visit. Junk is what you configure below.")
  local junkInit = check("junkOldGear", "Old gear counts as junk",
    "Gear far below your equipped item level sells with junk, automatically and on the Sell Junk button. Off keeps it out of the definition.")
  do
    local s = Settings.RegisterAddOnSetting(
      category, "VocVendor_oldGearIlvlGap", "oldGearIlvlGap",
      db, type(defaults.oldGearIlvlGap), newLabel("Old gear ilvl gap", "oldGearIlvlGap"), defaults.oldGearIlvlGap)
    local sliderOpts = Settings.CreateSliderOptions(1, 100, 1)
    local rightLabel = MinimalSliderWithSteppersMixin
      and MinimalSliderWithSteppersMixin.Label
      and MinimalSliderWithSteppersMixin.Label.Right
    if rightLabel and type(sliderOpts.SetLabelFormatter) == "function" then
      sliderOpts:SetLabelFormatter(rightLabel)
    end
    local gapInit = Settings.CreateSlider(category, s, sliderOpts,
      "Gear this far below your equipped item level counts as old gear. When AutoGear scores both items, its score decides instead.")
    ns.onSettingChanged(s, ns.refreshJunkButton)
    gateChild(gapInit, junkInit, "junkOldGear")
  end
  gateChild(check("oldGearBoE", "Also sell Bind on Equip",
    "Include BoE gear in old gear. Off keeps it safe: BoE can sell well on the auction house."),
    junkInit, "junkOldGear")
  gateChild(check("oldGearWarbound", "Also sell Warbound",
    "Include Warbound gear in old gear. Off keeps it safe: alts can use it through the warbank."),
    junkInit, "junkOldGear")
  local consumeInit = check("sellConsumables", "Sell losing consumables",
    "Keep one stack of the strongest food, flask, potion and more; the rest sells with junk. Unrecognized and special items never sell.",
    ns.refreshConsumablePopup)
  gateChild(check("autoSellConsumables", "Auto-sell losing consumables",
    "Sell losing consumables automatically on every vendor visit. Off shows a confirm list first.",
    ns.refreshConsumablePopup),
    consumeInit, "sellConsumables")
  check("compareAuction", "Compare auction prices",
    "Skip vendor sale when auction data says the auction house or disenchanting nets more. Needs Auctionator, TradeSkillMaster, or Oribos Exchange.")
  check("sellVendorWins", "Sell when vendor beats auction",
    "Sell bag items the vendor buys for more than the auction house nets after the 5% cut, using Auctionator, TradeSkillMaster, or Oribos Exchange data. Items without price data keep; BoE needs Also sell Bind on Equip, Warbound needs Also sell Warbound, and kept disenchantables still divert.")
  check("keepDisenchantable", "Keep disenchantable gear",
    "Enchanters only: keep gear you could disenchant out of junk sales. Off sells it with junk like any other old gear.")
  check("fillAmmo", "Show Fill Ammo button",
    "Hunters on the Forever client: show a Fill Ammo button on vendors that sell usable arrows or bullets. One click buys the best usable ammo until the quiver or ammo pouch holds full stacks.",
    ns.refreshAmmoButton)
  header("Using",
    "Use macros point at the strongest consumable in each quick-use slot.")
  check("useMacros", "Maintain use macros",
    "Keep VV Food, VV Drink, VV Health, VV Mana, VV Bandage and VV Scrolls pointed at the strongest consumable in each slot. They update when your bags change.",
    ns.updateUseMacros)
  header("Repair", "Repairs at vendors that repair, guild funds first when allowed.")
  local repairInit = check("autoRepair", "Auto-repair",
    "Repair all gear automatically at vendors that repair.")
  gateChild(check("guildRepair", "Guild funds first",
    "Pay repairs from the guild bank when possible, your own gold otherwise."),
    repairInit, "autoRepair")
  header("Announcements", "Chat lines for sells, repairs, and new settings.")
  check("announce", "Chat announcements",
    "Print a line when VocVendor sells or repairs.")
  -- Retail-only: Forever has no expansions, so the checklist stays
  -- hidden there instead of showing rows that could never apply.
  if ns.hasExpansions() then
    header("Expansions",
      "Check an expansion to sell everything the vendor buys from it. Dead leftovers the vendor refuses collect for confirmed delete instead. (Retail only)")
    for _, e in ipairs(ns.EXPANSIONS) do
      local ename = "Vendor " .. e.label .. " items"
      if e.id == ns.CURRENT_EXPANSION_ID then ename = ename .. " (current)" end
      check("sell" .. e.key, ename,
        "Sell everything the vendor buys from " .. e.label .. " when checked. Dead leftovers the vendor refuses collect for confirmed delete instead.")
    end
  end
  ns.settingsBuilt = true
  ns.settingsCategory = category
end

function ns.openConfig()
  local ok = pcall(function() Settings.OpenToCategory(ns.settingsCategory:GetID()) end)
  if ok then ns.play("open") -- the panel is the readout
  else ns.say("open Settings > AddOns > VocVendor") end
end

-- Addon compartment (FAMILY.md "Addon compartment"): the toc names
-- these three globals; Blizzard's compartment menu calls them with
-- (addonName, button). Left opens the disenchant list while kept gear
-- waits, settings otherwise; right always opens Settings; any click in
-- combat no-ops. Hover follows the tooltip contract: gold title, one
-- line, the slash hint. Clients without the compartment ignore the
-- metadata.
function VocVendor_CompartmentClick(_, button)
  if type(InCombatLockdown) == "function" and InCombatLockdown() then return end
  if button == "RightButton" then ns.openConfig() return end
  local kept = ns.collectKeptDisenchantables()
  if #kept > 0 and ns.refreshDEWindow(kept) then return end
  local dead = ns.collectDeadItems()
  if #dead > 0 and ns.refreshDeadWindow(dead) then return end
  ns.openConfig()
end

function VocVendor_CompartmentEnter(_, button)
  if type(GameTooltip) ~= "table" then return end
  GameTooltip:SetOwner(button, "ANCHOR_LEFT")
  GameTooltip:ClearLines()
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

-- ======= Slash and events =======
-- Slash grammar shared by every Voc addon (FAMILY.md): the bare command
-- does the one main thing (the manual junk sale, same as the native
-- Sell Junk button), `config` opens the panel, `help` lists the rest,
-- and anything unrecognized prints help instead of acting.
ns.HELP = {
  "/vv               sell junk now",
  "/vv on|off        auto-sell junk on vendor visits",
  "/vv repair        repair now",
  "/vv disenchant    open the disenchant list",
  "/vv destroy       delete dead expansion items (confirms each)",
  "/vv consume       sell losing consumables",
  "/vv use           use best consumables (refresh macros)",
  "/vv ammo          fill quiver or ammo pouch with the best ammo here",
  "/vv protect       open the keeps list (names, shift-click, commas ok)",
  "/vv diag          show consumable ranks",
  "/vv why           explain each gear verdict",
  "/vv dismiss-new   clear all New tags",
  "/vv config        open Settings > AddOns > VocVendor",
  "/vv help          this list (/vocvendor works too)",
}
function ns.help()
  ns.say("commands")
  for _, line in ipairs(ns.HELP) do print("  " .. line) end
end

-- Blizzard's slash dispatcher reads SLASH_* globals by name, so these
-- cannot be namespaced (they are declared in .luacheckrc instead).
SLASH_VOCVENDOR1 = "/vv"
SLASH_VOCVENDOR2 = "/vocvendor"
---@param msg string
SlashCmdList.VOCVENDOR = function(msg)
  local raw = strtrim(msg or "")
  msg = raw:lower()
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
  elseif msg == "consume" then
    if type(MerchantFrame) ~= "table" or not MerchantFrame:IsShown() then
      ns.say("open a vendor first")
      return
    end
    local sale = ns.collectConsumableSale()
    if #sale == 0 then
      ns.say("nothing to sell")
    elseif ns.opts().autoSellConsumables then
      ns.sellConsumablesNow(sale)
    else
      ns.reportConsumables(sale)
    end
  elseif msg == "use" then
    local maintained = ns.opts().useMacros
    if maintained then ns.updateUseMacros() end
    ns.reportUsePicks(ns.usePicks(), maintained)
  elseif msg == "ammo" then
    ns.fillAmmo()
  elseif msg == "protect" then
    ns.openKeeps()
  elseif msg:sub(1, 8) == "protect " then
    ns.toggleProtect(raw:sub(9))
    if ns.keepWindow and ns.keepWindow:IsShown() then ns.refreshKeepWindow() end
  elseif msg == "diag" then
    ns.diagConsumables()
  elseif msg == "why" then
    ns.diagOldGear()
  elseif msg == "dismiss-new" then
    ns.dismissNew()
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
ns.frame:RegisterEvent("MERCHANT_UPDATE")
ns.frame:RegisterEvent("BAG_UPDATE")
ns.frame:RegisterEvent("BAG_UPDATE_DELAYED")
ns.frame:RegisterEvent("PLAYER_REGEN_ENABLED")
ns.frame:RegisterEvent("PLAYER_LEVEL_UP")
ns.frame:RegisterEvent("SKILL_LINES_CHANGED")
ns.frame:RegisterEvent("GET_ITEM_INFO_RECEIVED")
ns.frame:RegisterEvent("QUEST_TURNED_IN")
ns.frame:RegisterEvent("UI_ERROR_MESSAGE")
ns.frame:RegisterEvent("ADDON_ACTION_BLOCKED")
ns.frame:SetScript("OnEvent", function(_, event, arg1, arg2)
  if event == "ADDON_LOADED" and arg1 == name then
    -- The client replaces the SavedVariables global with the loaded
    -- table after our file ran, so rebind or settings never persist.
    if type(VocVendorDB) ~= "table" then VocVendorDB = {} end
    ns.db = VocVendorDB
    ns.ensureSettings()
    ns.checkRivals() -- a same-job addon loaded before us stands us down
    ns.hookMacroFrame() -- the macro window may already be up
  elseif event == "ADDON_LOADED" then
    ns.checkRivals() -- a same-job addon loaded after us does the same
    ns.hookMacroFrame() -- Blizzard_MacroUI loads on demand
  elseif event == "PLAYER_LOGIN" then
    ns.ensureSettings() -- in case Settings wasn't up at ADDON_LOADED
    ns.checkRivals()
    ns.hookMacroFrame()
    ns.updateUseMacros() -- bags are settled: point macros at winners
  elseif event == "MERCHANT_SHOW" then
    ns.onMerchantShow()
  elseif event == "MERCHANT_CLOSED" then
    ns.onMerchantClosed()
  elseif event == "MERCHANT_UPDATE" then
    ns.refreshAmmoButton() -- stock changed: the button tracks the shelf
  elseif event == "BAG_UPDATE" then
    ns.refreshDEWindow() -- the disenchant list tracks the bags live
    ns.refreshDeadWindow() -- and so does the delete list
    ns.refreshAmmoButton() -- bought ammo lands here: hide when full
  elseif event == "BAG_UPDATE_DELAYED" then
    ns.updateUseMacros() -- winning stacks changed: re-point the macros
  elseif event == "PLAYER_REGEN_ENABLED" then
    if ns.usePending then ns.updateUseMacros() end -- combat parked one
  elseif event == "PLAYER_LEVEL_UP" or event == "SKILL_LINES_CHANGED" then
    ns.updateUseMacros() -- usability may have changed
  elseif event == "GET_ITEM_INFO_RECEIVED" then
    if ns.useIncomplete then ns.updateUseMacros() end -- data arrived
  elseif event == "QUEST_TURNED_IN" then
    ns.refreshQuests() -- a new completion changes what counts as dead
  elseif event == "UI_ERROR_MESSAGE" then
    if ns.merchant then ns.lastVendorError = arg2 end -- the engine's
    -- own verdict on a refused click, read by the leftover rows
  elseif event == "ADDON_ACTION_BLOCKED" then
    ns.onActionBlocked(arg1, arg2) -- our own taint blocks, named
  end
end)
