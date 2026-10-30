-- VocVendor regression tests. Stub-harness: no WoW client needed.
-- Run from anywhere:  lua tests/run.lua   (repo root also fine)
-- Works on Lua 5.1 (the client's dialect) and 5.2+.
--
-- Convention: each test resets stubs, drives ns.* or the frame's OnEvent
-- handler, and asserts. Any failed assert aborts with the test name.

local testDir = debug.getinfo(1, "S").source:gsub("\\", "/"):match("@?(.*/)") or ""
local mainPath = testDir .. "../main.lua"

local passed = 0
local function check(name, cond)
  if not cond then error("FAIL: " .. name, 2) end
  passed = passed + 1
end

-- Fresh stub world per test.
local function loadAddon(world)
  local g = {}
  for k, v in pairs(_G) do g[k] = v end -- inherit stdlib (string, table...)
  g._G = g
  g.print = function(...) world.printed[#world.printed + 1] = table.concat({...}, " ") end
  g.strtrim = function(s) return (tostring(s or ""):gsub("^%s*(.-)%s*$", "%1")) end
  g.SlashCmdList = {}
  g.NUM_BAG_SLOTS = 4
  g.Enum = {
    ItemClass = { Weapon = 2, Armor = 4 },
    ItemQuality = { Poor = 0, Common = 1, Uncommon = 2, Rare = 3, Epic = 4, Heirloom = 7 },
    ItemBind = { OnEquip = 2, OnAcquire = 1 },
  }
  g.C_Container = {
    GetContainerNumSlots = function(bag) return #(world.bags[bag] or {}) end,
    GetContainerItemLink = function(bag, slot)
      if world.removed[bag .. ":" .. slot] then return nil end
      local b = world.bags[bag]
      return b and b[slot] or nil
    end,
    UseContainerItem = function(bag, slot)
      -- world.sellErrors["bag:slot"] makes the click fail; world.stuck
      -- leaves the item behind so the post-click check sees it.
      if world.sellErrors[bag .. ":" .. slot] then error("sell failed") end
      world.sold[#world.sold + 1] = { bag = bag, slot = slot }
      if not world.stuck[bag .. ":" .. slot] then
        world.removed[bag .. ":" .. slot] = true
      end
      return true
    end,
    -- world.equipSets["bag:slot"] = true marks a slot in a saved set.
    GetContainerItemEquipmentSetInfo = function(bag, slot)
      return world.equipSets[bag .. ":" .. slot] == true, ""
    end,
    -- world.noValues["bag:slot"] = true marks a slot the vendor will not
    -- buy (C_Container.GetContainerItemInfo reports hasNoValue there).
    -- world.noContainerInfo simulates a client without that API.
    GetContainerItemInfo = function(bag, slot)
      if world.noContainerInfo then return nil end
      return { hasNoValue = world.noValues[bag .. ":" .. slot] == true }
    end,
  }
  g.C_Item = {
    GetItemInfoInstant = function(link)
      return world.itemIDs[link], nil, nil, world.slots[link], nil,
        world.classIDs[link], world.subclassIDs[link]
    end,
    GetItemInfo = function(link)
      if world.uncached[link] then return nil end
      return link, link, world.rarities[link], world.levels[link],
        world.minLevels[link], nil, nil, nil, world.slots[link], nil,
        world.prices[link], world.classIDs[link], world.subclassIDs[link],
        world.bindTypes[link], world.expansions[link], world.setIDs[link], nil, nil
    end,
    GetDetailedItemLevelInfo = function(link) return world.levels[link] end,
    IsItemBindToAccountUntilEquip = function(link) return world.warbound[link] == true end,
    -- world.cosmetic[itemID] marks a cosmetic item; world.transmogSet
    -- [itemID] a transmog-set piece. Both default to ordinary gear.
    -- (Blizzard takes the numeric ID here, like its own callers do.)
    IsCosmeticItem = function(itemID) return world.cosmetic[itemID] == true end,
    GetItemLearnTransmogSet = function(itemID) return world.transmogSet[itemID] end,
  }
  g.C_TransmogCollection = {
    -- world.noTransmog[link] marks an appearance the player lacks.
    PlayerHasTransmogByItemInfo = function(link)
      return world.noTransmog[link] ~= true
    end,
  }
  g.C_ToyBox = {
    -- world.toyInfo[itemID] non-nil marks a toy item.
    GetToyInfo = function(itemID) return world.toyInfo[itemID] end,
  }
  -- world.ownedToys[itemID] marks a toy the player owns.
  g.PlayerHasToy = function(itemID) return world.ownedToys[itemID] == true end
  g.C_PetJournal = {
    -- world.petSpecies[itemID] = speciesID marks a pet item; the 13th
    -- return is the species, matching Blizzard's signature.
    GetPetInfoByItemID = function(itemID)
      local s = world.petSpecies[itemID]
      if s == nil then return nil end
      return nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, s
    end,
    -- world.petOwned[speciesID] marks a collected pet.
    GetNumCollectedInfo = function(speciesID)
      if world.petOwned[speciesID] then return 1, 1 end
      return 0, 1
    end,
  }
  g.C_AddOns = {
    -- world.loadedAddons[name] = true marks an installed+loaded addon.
    IsAddOnLoaded = function(n) return world.loadedAddons[n] == true end,
  }
  g.C_MerchantFrame = {
    GetNumJunkItems = function() return world.junkCount end,
    SellAllJunkItems = function()
      world.junkSold = true
      world.money = world.money + world.junkValue
    end,
  }
  g.C_SpellBook = {
    ContainsAnyDisenchantSpell = function() return world.canDE == true end,
  }
  g.GetMoney = function() return world.money end
  g.GetInventoryItemLink = function(_, slotID) return world.equipped[slotID] end
  g.CanMerchantRepair = function() return world.canRepair end
  g.GetRepairAllCost = function() return world.repairCost, world.repairCan end
  g.RepairAllItems = function(useGuild)
    world.repairs[#world.repairs + 1] = useGuild and true or false
    if useGuild and not world.guildCovers then
      return -- guild attempt fails: damage remains
    end
    world.repairCan = false
    world.money = world.money - world.repairCost
  end
  g.CanGuildBankRepair = function() return world.guildRepair end
  g.SOUNDKIT = { ITEM_REPAIR = 7994, IG_MAINMENU_OPTION_CHECKBOX_ON = 856 }
  g.PlaySound = function(id) world.playedSounds[#world.playedSounds + 1] = id end
  g.MerchantFrame = {
    IsShown = function() return world.merchantOpen end,
  }
  world.blizzClick = function() world.blizzClicked = true end
  g.MerchantSellAllJunkButton = {
    IsShown = function() return true end,
    GetScript = function(_, n)
      if n == "OnClick" then return world.blizzClick end
    end,
    SetScript = function(_, n, fn) world.hookedClick[n] = fn end,
    SetEnabled = function(_, e) world.buttonEnabled = e end,
  }
  g.hooksecurefunc = function(n, fn) world.hooks[n] = fn end
  g.UIParent = {}
  g.UISpecialFrames = {}
  g.InCombatLockdown = function() return world.combat == true end
  g.IsMouseButtonDown = function() return false end
  g.C_Spell = {
    GetSpellName = function(spellID) return world.deSpellName end,
  }
  local function makeFrame(ftype, fname, template)
    local f = { events = {}, scripts = {}, attrs = {}, ctype = ftype,
      cname = fname, ctemplate = template, shown = false }
    f.RegisterEvent = function(_, e) f.events[e] = true end
    f.SetScript = function(_, n, fn) f.scripts[n] = fn end
    f.GetScript = function(_, n) return f.scripts[n] end
    f.HookScript = function(_, n, fn)
      local prev = f.scripts[n]
      f.scripts[n] = function(...)
        if prev then prev(...) end
        return fn(...)
      end
    end
    f.SetAttribute = function(_, n, v) f.attrs[n] = v end
    f.GetAttribute = function(_, n) return f.attrs[n] end
    f.RegisterForClicks = function() end
    f.SetText = function(_, t) f.text = t end
    f.SetSize = function(_, w, h) f.size = { w, h } end
    f.SetPoint = function(_, ...) f.point = { ... } end
    f.ClearAllPoints = function() f.cleared = true end
    f.SetMovable = function() end
    f.EnableMouse = function() end
    f.RegisterForDrag = function() end
    f.StartMoving = function() end
    f.StopMovingOrSizing = function() end
    f.Show = function() f.shown = true end
    f.Hide = function()
      f.shown = false
      if f.scripts.OnHide then f.scripts.OnHide(f) end
    end
    f.IsShown = function() return f.shown end
    f.CreateFontString = function()
      local fs = {}
      fs.SetPoint = function() end
      fs.SetText = function(_, t) fs.text = t end
      fs.SetTextColor = function() end
      fs.Show = function() end
      fs.Hide = function() end
      return fs
    end
    f.CreateTexture = function()
      local tx = {}
      tx.SetSize = function() end
      tx.SetPoint = function() end
      tx.SetAllPoints = function() end
      tx.SetTexture = function(_, t) tx.texture = t end
      tx.Show = function() tx.hidden = false end
      tx.Hide = function() tx.hidden = true end
      return tx
    end
    -- BasicFrameTemplateWithInset ships TitleText and CloseButton.
    if type(template) == "string"
      and template:find("BasicFrameTemplateWithInset", 1, true) then
      f.TitleText = { SetText = function(_, t) f.title = t end }
      f.CloseButton = {
        SetScript = function(_, n, fn)
          f.closeScripts = f.closeScripts or {}
          f.closeScripts[n] = fn
        end,
        SetPoint = function() end,
      }
    end
    return f
  end
  g.CreateFrame = function(ftype, fname, parent, template)
    if ftype == "Button" and type(template) == "string"
      and template:find("SecureActionButtonTemplate", 1, true)
      and world.noSecure then
      return nil -- client without secure buttons: the window stays shut
    end
    local f = makeFrame(ftype, fname, template)
    world.frames[#world.frames + 1] = f
    return f
  end
  g.GameTooltip = {
    SetOwner = function(_, owner, anchor) world.gametip.owner, world.gametip.anchor = owner, anchor end,
    SetText = function(_, t, r, gg, b) world.gametip.title = t world.gametip.titleColor = { r, gg, b } end,
    AddLine = function(_, t) world.gametip.lines[#world.gametip.lines + 1] = t end,
    Show = function() world.gametip.shown = true end,
    Hide = function() world.gametip.shown = false end,
    SetHyperlink = function(_, link) world.gametip.link = link end,
  }
  g.StaticPopupDialogs = {}
  g.StaticPopup_Show = function(which, a, b, data)
    world.popups[#world.popups + 1] = { which = which, a = a, b = b, data = data }
  end
  g.Settings = {
    RegisterVerticalLayoutCategory = function(n)
      world.settingsCategory = n
      return { id = 7, GetID = function() return 7 end }
    end,
    RegisterAddOnCategory = function() end,
    RegisterAddOnSetting = function(_, var, key, _, _, label, default)
      world.settingsReg[var] = { key = key, label = label, default = default }
      return { var = var, SetValueChangedCallback = function() end }
    end,
    CreateCheckbox = function() world.settingsChecks = world.settingsChecks + 1 end,
    CreateSliderOptions = function(min, max, step)
      return { min = min, max = max, step = step,
        SetLabelFormatter = function() end }
    end,
    CreateSlider = function() world.settingsSliders = world.settingsSliders + 1 end,
    OpenToCategory = function() end,
  }
  g.MinimalSliderWithSteppersMixin = { Label = { Right = {} } }
  -- Pawn guest: world.pawnUpgrades[link] = true means Pawn flags an upgrade.
  if world.withPawn then
    g.PawnGetItemData = function(link) return { Link = link } end
    g.PawnIsItemAnUpgrade = function(item)
      if world.pawnUpgrades[item.Link] then return { { UpgradeInfo = 0.1 } } end
      return {}
    end
  end

  local src = assert(io.open(mainPath, "r")):read("*a")
  local chunk
  if setfenv then
    chunk = assert(loadstring(src, "@" .. mainPath))
    setfenv(chunk, g)
  else
    chunk = assert(load(src, "@" .. mainPath, "t", g))
  end
  local ns = {}
  chunk("VocVendor", ns)
  world.frame = world.frames[1] -- the event frame, created at load
  world.frame.onEvent = function(...)
    return world.frames[1].scripts.OnEvent(...)
  end
  world.ns = ns
  world.env = g
  return ns
end

local function newWorld()
  return {
    bags = {}, slots = {}, minLevels = {}, levels = {}, classIDs = {},
    subclassIDs = {}, rarities = {}, prices = {}, bindTypes = {},
    setIDs = {}, itemIDs = {}, uncached = {}, warbound = {}, equipSets = {}, expansions = {},
    equipped = {}, printed = {}, frames = {}, gametip = { lines = {} },
    money = 100000, junkCount = 0, junkValue = 0, junkSold = false,
    sold = {}, repairs = {}, popups = {},
    canRepair = true, repairCost = 0, repairCan = false,
    guildRepair = false, guildCovers = true,
    merchantOpen = true, withPawn = false, pawnUpgrades = {}, canDE = false,
    settingsReg = {}, settingsChecks = 0, settingsSliders = 0,
    settingsCategory = nil, savedVars = nil,
    blizzClicked = false, hookedClick = {}, hooks = {}, buttonEnabled = nil,
    playedSounds = {}, noValues = {},
    removed = {}, stuck = {}, sellErrors = {},
    cosmetic = {}, transmogSet = {}, noTransmog = {},
    toyInfo = {}, ownedToys = {}, petSpecies = {}, petOwned = {},
    loadedAddons = {},
    combat = false, deSpellName = "Disenchant", noSecure = false,
  }
end

-- Simulate the client deserializing SavedVariables (a FRESH table replaces
-- the file-top default) and then firing ADDON_LOADED.
local function clientLoaded(w)
  w.env.VocVendorDB = w.savedVars or {}
  w.frame.onEvent(nil, "ADDON_LOADED", "VocVendor")
end

-- Gear factory: unique link with the fields isOldGear reads.
local gearSeq = 0
local function gear(w, o)
  gearSeq = gearSeq + 1
  local link = "item:gear" .. gearSeq
  w.itemIDs[link] = 1000 + gearSeq
  w.slots[link] = o.slot or "INVTYPE_HEAD"
  w.classIDs[link] = o.classID or 4 -- armor
  w.subclassIDs[link] = 0
  w.rarities[link] = o.rarity or 4
  w.levels[link] = o.level or 100
  w.minLevels[link] = 1
  w.prices[link] = o.price or 1000
  w.bindTypes[link] = o.bindType or 1 -- BoP
  -- Previous expansion by default, so existing sell-expectations hold;
  -- pass expansion = 11 for current-expansion (Midnight) gear.
  w.expansions[link] = o.expansion or 10
  if o.warbound then w.warbound[link] = true end
  return link
end

local function putBag(w, link)
  w.bags[0] = w.bags[0] or {}
  w.bags[0][#w.bags[0] + 1] = link
  return 0, #w.bags[0]
end

-- 1. Defaults fill in on a fresh SavedVariables table.
do
  local w = newWorld()
  local ns = loadAddon(w)
  clientLoaded(w)
  local o = ns.opts()
  check("default autoSell", o.autoSell == true)
  check("default autoRepair", o.autoRepair == true)
  check("default guildRepair", o.guildRepair == true)
  check("default announce", o.announce == true)
  check("default gap", o.oldGearIlvlGap == 30)
  check("default BoE excluded", o.oldGearBoE == false)
  check("default Warbound excluded", o.oldGearWarbound == false)
  check("default keep current expansion", o.keepCurrentExpansion == true)
  check("default keep disenchantable", o.keepDisenchantable == true)
  check("default compareAuction", o.compareAuction == true)
end

-- 1b. An out-of-range gap (hand-edited SavedVariables) resets to the
-- slider range's default instead of redefining junk wholesale.
do
  local w = newWorld()
  local ns = loadAddon(w)
  clientLoaded(w)
  ns.db.oldGearIlvlGap = 5000
  check("gap above slider range reset", ns.opts().oldGearIlvlGap == 30)
  ns.db.oldGearIlvlGap = 1
  check("gap below slider range reset", ns.opts().oldGearIlvlGap == 30)
  ns.db.oldGearIlvlGap = 45
  check("gap inside slider range kept", ns.opts().oldGearIlvlGap == 45)
end

-- 2. Money formatting.
do
  local w = newWorld()
  local ns = loadAddon(w)
  check("money gold", ns.moneyString(1234567) == "123g 45s")
  check("money silver", ns.moneyString(4567) == "45s 67c")
  check("money copper", ns.moneyString(89) == "89c")
  check("money zero", ns.moneyString(0) == "0c")
  check("money negative", ns.moneyString(-5) == "0c")
end

-- 2b. The visit line counts every item sold, whatever pile it came
-- from. Nil when nothing sold, so the close stays silent.
do
  local w = newWorld()
  local ns = loadAddon(w)
  check("visit grays", ns.visitLine(3, 450) == "sold 3 items for 4s 50c")
  check("visit single", ns.visitLine(1, 0) == "sold 1 item for 0c")
  check("visit mixed", ns.visitLine(3, 1450) == "sold 3 items for 14s 50c")
  check("visit nothing", ns.visitLine(0, 0) == nil)
end

-- 2c. Identical junk merges by item ID into summary groups with summed
-- quantity and total; links without a known ID merge by link.
do
  local w = newWorld()
  local ns = loadAddon(w)
  local a = "item:mergeA"
  local b = "item:mergeB"
  w.itemIDs[a], w.itemIDs[b] = 501, 502
  local groups = ns.mergeByID({
    { link = a, price = 100 }, { link = b, price = 50 },
    { link = a, price = 100 },
  })
  check("two groups", #groups == 2)
  check("first-seen order", groups[1].link == a and groups[2].link == b)
  check("summed quantity", groups[1].qty == 2)
  check("summed total", groups[1].total == 200)
  check("single row", ns.mergedLine(groups[2]) == "  " .. b .. " for 50c")
  check("merged row", ns.mergedLine(groups[1]) == "  2x " .. a .. " for 2s 0c")
  check("itemID known", ns.itemID(a) == 501)
  check("itemID unknown", ns.itemID("item:ghost") == nil)
end

-- 3. The sale happens on MERCHANT_SHOW; the one deferred line for the
-- visit lands on MERCHANT_CLOSED.
do
  local w = newWorld()
  w.junkCount = 3
  w.junkValue = 450
  w.repairCan = false
  loadAddon(w)
  clientLoaded(w)
  w.frame.onEvent(nil, "MERCHANT_SHOW")
  check("junk sold", w.junkSold == true)
  check("no chat before close", #w.printed == 0)
  w.frame.onEvent(nil, "MERCHANT_CLOSED")
  check("one line for the visit", w.printed[1] == "|cff66ccffVocVendor|r: sold 3 items for 4s 50c")
end

-- 4. Junk sells before repair, so the proceeds can pay for it.
do
  local w = newWorld()
  w.junkCount = 2
  w.junkValue = 100
  w.repairCost = 60
  w.repairCan = true
  w.money = 0 -- could not afford the repair without the junk gold
  local order = {}
  loadAddon(w)
  w.env.C_MerchantFrame.SellAllJunkItems = function()
    order[#order + 1] = "sell"
    w.junkSold = true
    w.money = w.money + w.junkValue
  end
  local origRepair = w.env.RepairAllItems
  w.env.RepairAllItems = function(useGuild)
    order[#order + 1] = "repair"
    return origRepair(useGuild)
  end
  clientLoaded(w)
  w.frame.onEvent(nil, "MERCHANT_SHOW")
  check("sell before repair", order[1] == "sell" and order[2] == "repair")
  check("repair happened", #w.repairs == 1)
end

-- 5. Auto-sell off: MERCHANT_SHOW does nothing.
do
  local w = newWorld()
  w.junkCount = 3
  w.repairCan = false
  local ns = loadAddon(w)
  clientLoaded(w)
  ns.opts().autoSell = false
  w.frame.onEvent(nil, "MERCHANT_SHOW")
  check("no auto sell", w.junkSold == false)
  check("no announce", #w.printed == 0)
end

-- 6. No junk, no sale, no line.
do
  local w = newWorld()
  w.junkCount = 0
  w.repairCan = false
  loadAddon(w)
  clientLoaded(w)
  w.frame.onEvent(nil, "MERCHANT_SHOW")
  check("no junk no sale", w.junkSold == false)
  check("no junk no announce", #w.printed == 0)
  check("no sound when empty", #w.playedSounds == 0)
end

-- 7. Auto-repair, personal gold.
do
  local w = newWorld()
  w.junkCount = 0
  w.repairCost = 250
  w.repairCan = true
  loadAddon(w)
  clientLoaded(w)
  w.frame.onEvent(nil, "MERCHANT_SHOW")
  check("personal repair", #w.repairs == 1 and w.repairs[1] == false)
  check("repair announce", w.printed[1] == "|cff66ccffVocVendor|r: repaired for 2s 50c")
  check("repair sound", w.playedSounds[1] == 7994)
end

-- 8. Guild funds first when the guild can repair.
do
  local w = newWorld()
  w.junkCount = 0
  w.repairCost = 250
  w.repairCan = true
  w.guildRepair = true
  loadAddon(w)
  clientLoaded(w)
  w.frame.onEvent(nil, "MERCHANT_SHOW")
  check("guild repair", #w.repairs == 1 and w.repairs[1] == true)
  check("guild announce", w.printed[1]:find("%(guild funds%)") ~= nil)
end

-- 9. Guild attempt that leaves damage falls back to personal gold.
do
  local w = newWorld()
  w.junkCount = 0
  w.repairCost = 250
  w.repairCan = true
  w.guildRepair = true
  w.guildCovers = false -- guild repair fails: damage remains
  loadAddon(w)
  clientLoaded(w)
  w.frame.onEvent(nil, "MERCHANT_SHOW")
  check("fallback repair count", #w.repairs == 2)
  check("fallback is personal", w.repairs[2] == false)
  check("fallback not guild-tagged", w.printed[1]:find("guild") == nil)
end

-- 10. Can't afford, no guild: silent, no repair.
do
  local w = newWorld()
  w.junkCount = 0
  w.repairCost = 250
  w.repairCan = true
  w.money = 10
  loadAddon(w)
  clientLoaded(w)
  w.frame.onEvent(nil, "MERCHANT_SHOW")
  check("no repair when broke", #w.repairs == 0)
  check("no announce when broke", #w.printed == 0)
end

-- 11. Merchant that can't repair: repair skipped, junk still sells.
do
  local w = newWorld()
  w.junkCount = 1
  w.junkValue = 10
  w.canRepair = false
  w.repairCan = true
  w.repairCost = 50
  loadAddon(w)
  clientLoaded(w)
  w.frame.onEvent(nil, "MERCHANT_SHOW")
  check("junk still sells", w.junkSold == true)
  check("no repair call", #w.repairs == 0)
end

-- 12. isOldGear: gap math against the equipped piece.
do
  local w = newWorld()
  local ns = loadAddon(w)
  clientLoaded(w)
  local worn = gear(w, { slot = "INVTYPE_HEAD", level = 400 })
  w.equipped[1] = worn
  local old = gear(w, { slot = "INVTYPE_HEAD", level = 370 })   -- 30 below
  local fresh = gear(w, { slot = "INVTYPE_HEAD", level = 371 }) -- 29 below
  check("30 below is old", ns.isOldGear(old, 30) == true)
  check("29 below is not", ns.isOldGear(fresh, 30) == false)
end

-- 13. Two-slot: old only when below BOTH equipped rings.
do
  local w = newWorld()
  local ns = loadAddon(w)
  clientLoaded(w)
  w.equipped[11] = gear(w, { slot = "INVTYPE_FINGER", level = 400 })
  w.equipped[12] = gear(w, { slot = "INVTYPE_FINGER", level = 350 })
  local betterThanWeak = gear(w, { slot = "INVTYPE_FINGER", level = 360 })
  local worseThanBoth = gear(w, { slot = "INVTYPE_FINGER", level = 315 })
  check("beats weak ring: keep", ns.isOldGear(betterThanWeak, 30) == false)
  check("below both: sell", ns.isOldGear(worseThanBoth, 30) == true)
end

-- 14. Exclusions: BoE, Warbound, heirloom, no price, uncached.
do
  local w = newWorld()
  local ns = loadAddon(w)
  clientLoaded(w)
  w.equipped[1] = gear(w, { slot = "INVTYPE_HEAD", level = 400 })
  local boe = gear(w, { slot = "INVTYPE_HEAD", level = 300, bindType = 2 })
  local warb = gear(w, { slot = "INVTYPE_HEAD", level = 300, warbound = true })
  local heir = gear(w, { slot = "INVTYPE_HEAD", level = 300, rarity = 7 })
  local noprice = gear(w, { slot = "INVTYPE_HEAD", level = 300, price = 0 })
  local ghost = gear(w, { slot = "INVTYPE_HEAD", level = 300 })
  w.uncached[ghost] = true
  check("BoE excluded by default", ns.isOldGear(boe, 30) == false)
  check("Warbound excluded by default", ns.isOldGear(warb, 30) == false)
  check("heirloom excluded", ns.isOldGear(heir, 30) == false)
  check("no sell price excluded", ns.isOldGear(noprice, 30) == false)
  check("uncached skipped", ns.isOldGear(ghost, 30) == false)
  ns.opts().oldGearBoE = true
  ns.opts().oldGearWarbound = true
  check("BoE included when opted in", ns.isOldGear(boe, 30) == true)
  check("Warbound included when opted in", ns.isOldGear(warb, 30) == true)
end

-- 15. Pawn guest: never sell what Pawn flags as an upgrade.
do
  local w = newWorld()
  w.withPawn = true
  local ns = loadAddon(w)
  clientLoaded(w)
  w.equipped[1] = gear(w, { slot = "INVTYPE_HEAD", level = 400 })
  local flagged = gear(w, { slot = "INVTYPE_HEAD", level = 300 })
  w.pawnUpgrades[flagged] = true
  local plain = gear(w, { slot = "INVTYPE_HEAD", level = 300 })
  check("Pawn upgrade kept", ns.isOldGear(flagged, 30) == false)
  check("plain old gear sells", ns.isOldGear(plain, 30) == true)
end

-- 16. Non-equippables never qualify.
do
  local w = newWorld()
  local ns = loadAddon(w)
  clientLoaded(w)
  w.equipped[1] = gear(w, { slot = "INVTYPE_HEAD", level = 400 })
  local trinketTool = gear(w, { slot = "", level = 1 }) -- no equip loc
  local potion = gear(w, { slot = "INVTYPE_HEAD", level = 1, classID = 0 })
  check("no equip loc rejected", ns.isOldGear(trinketTool, 30) == false)
  check("non gear class rejected", ns.isOldGear(potion, 30) == false)
end

-- 17. collectJunk: grays always; old gear only when opted in.
do
  local w = newWorld()
  local ns = loadAddon(w)
  clientLoaded(w)
  w.junkCount = 2
  w.equipped[1] = gear(w, { slot = "INVTYPE_HEAD", level = 400 })
  putBag(w, gear(w, { slot = "INVTYPE_HEAD", level = 300 }))
  local junk = ns.collectJunk()
  check("grays counted", junk.grayCount == 2)
  check("old gear excluded by default", #junk.oldGear == 0)
  ns.opts().junkOldGear = true
  junk = ns.collectJunk()
  check("old gear included when opted in", #junk.oldGear == 1)
end

-- 18. Auto-sell with old gear in the definition: one combined sale.
do
  local w = newWorld()
  w.junkCount = 2
  w.junkValue = 450
  w.repairCan = false
  local ns = loadAddon(w)
  clientLoaded(w)
  ns.opts().junkOldGear = true
  w.equipped[1] = gear(w, { slot = "INVTYPE_HEAD", level = 400 })
  putBag(w, gear(w, { slot = "INVTYPE_HEAD", level = 300, price = 1000 }))
  w.frame.onEvent(nil, "MERCHANT_SHOW")
  check("grays sold", w.junkSold == true)
  check("old gear sold", #w.sold == 1)
  check("silent before close", #w.printed == 0)
  w.frame.onEvent(nil, "MERCHANT_CLOSED")
  check("one line for both piles",
    w.printed[1] == "|cff66ccffVocVendor|r: sold 3 items for 14s 50c")
end

-- 19. Native button hook: installs once, preserves Blizzard's click.
do
  local w = newWorld()
  local ns = loadAddon(w)
  clientLoaded(w)
  w.repairCan = false
  w.frame.onEvent(nil, "MERCHANT_SHOW")
  w.frame.onEvent(nil, "MERCHANT_SHOW")
  check("hook installed", type(w.hookedClick.OnClick) == "function")
  check("original preserved", ns.blizzJunkClick == w.blizzClick)
  check("update hooked", type(w.hooks.MerchantFrame_Update) == "function")
end

-- 20. Native button, grays only: Blizzard's original click runs untouched.
do
  local w = newWorld()
  loadAddon(w)
  clientLoaded(w)
  w.junkCount = 2
  w.repairCan = false
  w.frame.onEvent(nil, "MERCHANT_SHOW")
  w.junkSold = false
  w.printed = {}
  w.blizzClicked = false
  w.hookedClick.OnClick(w.env.MerchantSellAllJunkButton)
  check("blizzard click runs", w.blizzClicked == true)
  check("no dry-run popup", #w.popups == 0)
end

-- 21. Native button with old gear: itemized dry-run, one confirm popup.
do
  local w = newWorld()
  local ns = loadAddon(w)
  clientLoaded(w)
  ns.opts().junkOldGear = true
  w.junkCount = 3
  w.equipped[1] = gear(w, { slot = "INVTYPE_HEAD", level = 400 })
  local old1 = gear(w, { slot = "INVTYPE_HEAD", level = 300, price = 1200 })
  local old2 = gear(w, { slot = "INVTYPE_HEAD", level = 310, price = 800 })
  putBag(w, old1)
  putBag(w, old2)
  ns.opts().autoSell = false -- manual-only: keep the bags intact for the click
  ns.opts().autoRepair = false
  w.frame.onEvent(nil, "MERCHANT_SHOW") -- installs the button hook
  w.hookedClick.OnClick(w.env.MerchantSellAllJunkButton)
  check("dry-run header",
    w.printed[1] == "|cff66ccffVocVendor|r: junk to sell (3 gray, 2 old gear):")
  check("dry-run merges by item",
    w.printed[2] == "  " .. old1 .. " for 12s 0c"
    and w.printed[3] == "  " .. old2 .. " for 8s 0c")
  check("one popup", #w.popups == 1)
  check("popup count", w.popups[1].a == 5)
  check("popup total", w.popups[1].b == "20s 0c")
  check("popup carries data",
    w.popups[1].data.grayCount == 3 and #w.popups[1].data.oldGear == 2)
  check("blizzard click skipped", w.blizzClicked == false)
end

-- 22. Popup confirm sells both piles; moved bag slots are skipped.
do
  local w = newWorld()
  local ns = loadAddon(w)
  clientLoaded(w)
  w.junkCount = 2
  w.junkValue = 450
  w.equipped[1] = gear(w, { slot = "INVTYPE_HEAD", level = 400 })
  local old1 = gear(w, { slot = "INVTYPE_HEAD", level = 300, price = 1000 })
  local old2 = gear(w, { slot = "INVTYPE_HEAD", level = 310, price = 1000 })
  local b1, s1 = putBag(w, old1)
  local b2, s2 = putBag(w, old2)
  -- Bag shifted between dry-run and confirm: old2 moved away.
  w.bags[b2][s2] = gear(w, { slot = "INVTYPE_HEAD", level = 399 })
  ns.sellJunkNow({
    grayCount = 2,
    oldGear = {
      { link = old1, bag = b1, slot = s1, price = 1000 },
      { link = old2, bag = b2, slot = s2, price = 1000 },
    },
  })
  check("grays sold on confirm", w.junkSold == true)
  check("only matching slot sold", #w.sold == 1)
  check("right slot sold", w.sold[1].bag == b1 and w.sold[1].slot == s1)
  check("moved slot listed with reason",
    w.printed[1] == "|cff66ccffVocVendor|r: couldn't sell 1 item:"
    and w.printed[2] == "  " .. old2 .. " (moved)")
  check("silent before close", #w.printed == 2)
  w.frame.onEvent(nil, "MERCHANT_CLOSED")
  check("deferred confirm line",
    w.printed[3] == "|cff66ccffVocVendor|r: sold 3 items for 14s 50c")
end

-- 23. refreshJunkButton: enabled with old gear but no grays, off when empty.
do
  local w = newWorld()
  local ns = loadAddon(w)
  clientLoaded(w)
  ns.opts().junkOldGear = true
  w.equipped[1] = gear(w, { slot = "INVTYPE_HEAD", level = 400 })
  putBag(w, gear(w, { slot = "INVTYPE_HEAD", level = 300 }))
  w.junkCount = 0
  ns.refreshJunkButton()
  check("enabled on old gear alone", w.buttonEnabled == true)
  w.bags[0] = {}
  ns.refreshJunkButton()
  check("disabled when empty", w.buttonEnabled == false)
end

-- 24. Slash: bare runs the button flow at a vendor, warns away from one.
do
  local w = newWorld()
  w.junkCount = 2
  loadAddon(w)
  clientLoaded(w)
  w.repairCan = false
  w.env.SlashCmdList.VOCVENDOR("off") -- manual-only mode
  w.repairCan = false
  w.frame.onEvent(nil, "MERCHANT_SHOW") -- installs the button hook
  w.junkSold = false
  w.blizzClicked = false
  w.env.SlashCmdList.VOCVENDOR("")
  check("slash runs button flow", w.blizzClicked == true)
  w.merchantOpen = false
  w.env.SlashCmdList.VOCVENDOR("")
  check("slash warns away", w.printed[#w.printed] == "|cff66ccffVocVendor|r: open a vendor first")
end

-- 25. Slash: on/off toggles auto-sell; repair triggers repair.
-- 26. Slash: on/off toggles auto-sell; repair triggers repair.
do
  local w = newWorld()
  local ns = loadAddon(w)
  clientLoaded(w)
  w.env.SlashCmdList.VOCVENDOR("off")
  check("auto-sell off", ns.opts().autoSell == false)
  check("off announce names the re-enable command",
    w.printed[1] == "|cff66ccffVocVendor|r: auto-sell junk off (turn back on with /vv on)")
  check("off confirms with the checkbox pair (fallback: no OFF constant in the stub)",
    w.playedSounds[1] == 857)
  w.env.SlashCmdList.VOCVENDOR("on")
  check("auto-sell on", ns.opts().autoSell == true)
  check("on confirms with the SOUNDKIT constant", w.playedSounds[2] == 856)
  local before = #w.printed
  w.env.SlashCmdList.VOCVENDOR("help")
  check("/vv help lists every command", #w.printed == before + 1 + #ns.HELP)
  check("help names config and help last",
    ns.HELP[#ns.HELP - 1]:find("^/vv config") ~= nil and ns.HELP[#ns.HELP]:find("^/vv help") ~= nil
    and ns.HELP[#ns.HELP]:find("/vocvendor works too", 1, true) ~= nil)
  before = #w.printed
  w.env.SlashCmdList.VOCVENDOR("onn") -- typo: help, never a toggle
  check("unknown subcommand prints help", #w.printed == before + 1 + #ns.HELP)
  check("unknown subcommand never toggles", ns.opts().autoSell == true)
  check("short and long slash registered",
    w.env.SLASH_VOCVENDOR1 == "/vv" and w.env.SLASH_VOCVENDOR2 == "/vocvendor")
  w.repairCost = 100
  w.repairCan = true
  w.env.SlashCmdList.VOCVENDOR("repair")
  check("slash repair", #w.repairs == 1)
end

-- 27. Settings panel registers the expected controls.
do
  local w = newWorld()
  loadAddon(w)
  clientLoaded(w)
  check("category", w.settingsCategory == "VocVendor")
  check("autoSell setting", w.env.Settings and w.settingsReg["VocVendor_autoSell"] ~= nil)
  check("gap slider", w.settingsSliders == 1)
  check("gap default", w.settingsReg["VocVendor_oldGearIlvlGap"].default == 30)
  check("checkboxes", w.settingsChecks == 10)
  check("current-expansion setting", w.settingsReg["VocVendor_keepCurrentExpansion"] ~= nil)
  check("current-expansion default", w.settingsReg["VocVendor_keepCurrentExpansion"].default == true)
  check("keep disenchantable setting", w.settingsReg["VocVendor_keepDisenchantable"] ~= nil)
  check("keep default", w.settingsReg["VocVendor_keepDisenchantable"].default == true)
  check("compare setting", w.settingsReg["VocVendor_compareAuction"] ~= nil)
  check("compare default", w.settingsReg["VocVendor_compareAuction"].default == true)
end

-- 28. Compartment click opens the addon's Settings category.
do
  local w = newWorld()
  loadAddon(w)
  clientLoaded(w)
  local opened = nil
  w.env.Settings.OpenToCategory = function(id) opened = id end
  check("compartment global", type(w.env.VocVendor_CompartmentClick) == "function")
  w.env.VocVendor_CompartmentClick("VocVendor", "LeftButton")
  check("compartment opens config", opened == 7)
  w.env.Settings = nil -- Settings API missing: say where, don't error
  w.env.VocVendor_CompartmentClick("VocVendor", "LeftButton")
  check("compartment fallback",
    w.printed[#w.printed] == "|cff66ccffVocVendor|r: open Settings > AddOns > VocVendor")
  -- Hover follows the tooltip contract: gold title, one line, the slash hint.
  local btn = {}
  w.env.VocVendor_CompartmentEnter("VocVendor", btn)
  check("compartment tooltip anchors to the button", w.gametip.owner == btn and w.gametip.shown == true)
  check("compartment tooltip title is gold", w.gametip.title == "VocVendor"
    and w.gametip.titleColor[1] == 1 and w.gametip.titleColor[2] == 0.82)
  check("compartment tooltip teaches the slash", #w.gametip.lines == 2
    and w.gametip.lines[2]:find("/vv", 1, true) ~= nil)
  w.env.VocVendor_CompartmentLeave("VocVendor", btn)
  check("compartment leave hides the tooltip", w.gametip.shown == false)
end

-- 28b. Settings registration retries at PLAYER_LOGIN when the API was
-- late, and never registers twice.
do
  local w = newWorld()
  local ns = loadAddon(w)
  local S = w.env.Settings
  w.env.Settings = nil
  clientLoaded(w)
  check("no Settings at ADDON_LOADED: nothing built", ns.settingsBuilt == false)
  w.env.Settings = S
  w.frame.onEvent(nil, "PLAYER_LOGIN")
  check("PLAYER_LOGIN builds the panel", ns.settingsBuilt == true and w.settingsCategory == "VocVendor")
  local n = w.settingsChecks
  w.frame.onEvent(nil, "PLAYER_LOGIN")
  check("built once", w.settingsChecks == n)
end

-- 29. Auto-sell confirms with the merchant click, even unannounced.
do
  local w = newWorld()
  w.junkCount = 3
  w.junkValue = 450
  w.repairCan = false
  local ns = loadAddon(w)
  clientLoaded(w)
  ns.opts().announce = false
  w.frame.onEvent(nil, "MERCHANT_SHOW")
  check("sell sound without announce", w.playedSounds[1] == 856)
  check("no chat before close", #w.printed == 0)
  w.frame.onEvent(nil, "MERCHANT_CLOSED")
  check("no chat after close when unannounced", #w.printed == 0)
end

-- 30. Popup confirm plays the numeric fallback when SOUNDKIT renames.
do
  local w = newWorld()
  local ns = loadAddon(w)
  clientLoaded(w)
  w.env.SOUNDKIT = {} -- Blizzard renamed the constant: fallback covers it
  w.junkCount = 2
  w.junkValue = 450
  ns.sellJunkNow({ grayCount = 2, oldGear = {} })
  check("fallback sound", w.playedSounds[1] == 856)
end

-- 31. Manual no-ops answer instead of staying silent.
do
  local w = newWorld()
  local ns = loadAddon(w)
  clientLoaded(w)
  w.junkCount = 0
  w.repairCan = false
  w.env.SlashCmdList.VOCVENDOR("")
  check("nothing to sell", w.printed[1] == "|cff66ccffVocVendor|r: nothing to sell")
  check("native click skipped when empty", w.blizzClicked == false)
  check("repairNow reports nothing", ns.repairNow() == false)
  w.env.SlashCmdList.VOCVENDOR("repair")
  check("nothing to repair", w.printed[2] == "|cff66ccffVocVendor|r: nothing to repair")
  w.merchantOpen = false
  w.env.SlashCmdList.VOCVENDOR("repair")
  check("repair away from vendor",
    w.printed[3] == "|cff66ccffVocVendor|r: open a vendor first")
  w.merchantOpen = true
  w.repairCost = 100
  w.repairCan = true
  w.env.SlashCmdList.VOCVENDOR("repair")
  check("repair success announces",
    w.printed[4] == "|cff66ccffVocVendor|r: repaired for 1s 0c")
end

-- 32. Equipment-set safeguard: set gear is never collected, never sold.
do
  local w = newWorld()
  local ns = loadAddon(w)
  clientLoaded(w)
  ns.opts().junkOldGear = true
  w.equipped[1] = gear(w, { slot = "INVTYPE_HEAD", level = 400 })
  local kept = gear(w, { slot = "INVTYPE_HEAD", level = 300, price = 1000 })
  local kb, ks = putBag(w, kept)
  w.equipSets[kb .. ":" .. ks] = true
  local free = gear(w, { slot = "INVTYPE_HEAD", level = 300, price = 1000 })
  local fb, fs = putBag(w, free)
  local junk = ns.collectJunk()
  check("set gear excluded from collection", #junk.oldGear == 1)
  check("free gear still collected", junk.oldGear[1].link == free)
  local n = ns.sellOldGearItems({
    { link = kept, bag = kb, slot = ks, price = 1000 },
    { link = free, bag = fb, slot = fs, price = 1000 },
  })
  check("set gear skipped at sell", n == 1 and #w.sold == 1)
  check("free gear sold", w.sold[1].bag == fb and w.sold[1].slot == fs)
end

-- 33. Missing or broken equipment-set API keeps old gear (fail closed).
do
  local w = newWorld()
  local ns = loadAddon(w)
  clientLoaded(w)
  ns.opts().junkOldGear = true
  w.equipped[1] = gear(w, { slot = "INVTYPE_HEAD", level = 400 })
  putBag(w, gear(w, { slot = "INVTYPE_HEAD", level = 300 }))
  w.env.C_Container.GetContainerItemEquipmentSetInfo = nil
  check("missing API keeps the item", ns.inEquipmentSet(0, 1) == true)
  check("nothing collected without the API", #ns.collectJunk().oldGear == 0)
  w.env.C_Container.GetContainerItemEquipmentSetInfo = function() error("boom") end
  check("erroring API keeps the item", ns.inEquipmentSet(0, 1) == true)
end

-- 34. Enchanter with the toggle on: DE-able old gear is kept, not sold.
do
  local w = newWorld()
  w.canDE = true
  w.repairCan = false
  local ns = loadAddon(w)
  clientLoaded(w)
  ns.opts().junkOldGear = true
  w.equipped[1] = gear(w, { slot = "INVTYPE_HEAD", level = 400 })
  local old = gear(w, { slot = "INVTYPE_HEAD", level = 300, price = 1000 })
  putBag(w, old)
  check("DE-able old gear excluded", ns.isOldGear(old, 30) == false)
  check("ignoring DE it qualifies", ns.isOldGear(old, 30, true) == true)
  check("kept line", ns.keptLine(ns.collectKeptDisenchantables()) == "kept 1 for disenchant")
  check("no kept line when empty", ns.keptLine({}) == nil)
  w.frame.onEvent(nil, "MERCHANT_SHOW")
  check("kept gear not sold", #w.sold == 0)
  check("window opened for kept gear", ns.deWindow ~= nil and ns.deWindow:IsShown())
  check("one row for one kept item", #ns.deRows == 1)
  check("row holds the kept link", ns.deRows[1].deLink == old)
  check("no kept chat: the window is the notice", #w.printed == 0)
  check("window confirms open", w.playedSounds[1] == 850)
end

-- 35. Toggle off: the same gear sells like any other old gear.
do
  local w = newWorld()
  w.canDE = true
  w.repairCan = false
  local ns = loadAddon(w)
  clientLoaded(w)
  ns.opts().junkOldGear = true
  ns.opts().keepDisenchantable = false
  w.equipped[1] = gear(w, { slot = "INVTYPE_HEAD", level = 400 })
  putBag(w, gear(w, { slot = "INVTYPE_HEAD", level = 300, price = 1000 }))
  check("nothing kept when toggled off", #ns.collectKeptDisenchantables() == 0)
  w.frame.onEvent(nil, "MERCHANT_SHOW")
  check("old gear sold when toggled off", #w.sold == 1)
  w.frame.onEvent(nil, "MERCHANT_CLOSED")
  check("sold announce, no kept line",
    #w.printed == 1 and w.printed[1] == "|cff66ccffVocVendor|r: sold 1 item for 10s 0c")
  check("no disenchant window without kept gear",
    ns.deWindow == nil or not ns.deWindow:IsShown())
end

-- 36. Non-enchanter: the toggle is inert, sales unchanged.
do
  local w = newWorld()
  w.repairCan = false
  local ns = loadAddon(w)
  clientLoaded(w)
  check("not an enchanter", ns.canDisenchant() == false)
  ns.opts().junkOldGear = true
  w.equipped[1] = gear(w, { slot = "INVTYPE_HEAD", level = 400 })
  putBag(w, gear(w, { slot = "INVTYPE_HEAD", level = 300, price = 1000 }))
  check("nothing kept for non-enchanter", #ns.collectKeptDisenchantables() == 0)
  w.frame.onEvent(nil, "MERCHANT_SHOW")
  check("old gear still sells", #w.sold == 1)
  check("silent before close", #w.printed == 0)
  w.frame.onEvent(nil, "MERCHANT_CLOSED")
  check("one line, no kept line", #w.printed == 1)
  check("no disenchant window for non-enchanters",
    ns.deWindow == nil or not ns.deWindow:IsShown())
end

-- 37. Missing or broken spellbook API keeps selling (fail closed).
do
  local w = newWorld()
  w.canDE = true
  w.repairCan = false
  local ns = loadAddon(w)
  clientLoaded(w)
  ns.opts().junkOldGear = true
  w.equipped[1] = gear(w, { slot = "INVTYPE_HEAD", level = 400 })
  putBag(w, gear(w, { slot = "INVTYPE_HEAD", level = 300 }))
  w.env.C_SpellBook = nil
  check("missing API is not an enchanter", ns.canDisenchant() == false)
  check("missing API keeps nothing", #ns.collectKeptDisenchantables() == 0)
  w.frame.onEvent(nil, "MERCHANT_SHOW")
  check("missing API still sells", #w.sold == 1)
end
do
  local w = newWorld()
  w.canDE = true
  w.repairCan = false
  local ns = loadAddon(w)
  clientLoaded(w)
  ns.opts().junkOldGear = true
  w.equipped[1] = gear(w, { slot = "INVTYPE_HEAD", level = 400 })
  putBag(w, gear(w, { slot = "INVTYPE_HEAD", level = 300 }))
  w.env.C_SpellBook = { ContainsAnyDisenchantSpell = function() error("boom") end }
  check("erroring API is not an enchanter", ns.canDisenchant() == false)
  w.frame.onEvent(nil, "MERCHANT_SHOW")
  check("erroring API still sells", #w.sold == 1)
end

-- 38. Disenchantable heuristic: uncommon, rare, or epic weapons/armor only.
do
  local w = newWorld()
  local ns = loadAddon(w)
  clientLoaded(w)
  local epic = gear(w, { slot = "INVTYPE_HEAD", level = 300 })
  local rare = gear(w, { slot = "INVTYPE_HEAD", level = 300, rarity = 3 })
  local common = gear(w, { slot = "INVTYPE_HEAD", level = 300, rarity = 1 })
  local heir = gear(w, { slot = "INVTYPE_HEAD", level = 300, rarity = 7 })
  local noprice = gear(w, { slot = "INVTYPE_HEAD", level = 300, price = 0 })
  local ghost = gear(w, { slot = "INVTYPE_HEAD", level = 300 })
  w.uncached[ghost] = true
  local potion = gear(w, { slot = "INVTYPE_HEAD", level = 300, classID = 0 })
  local tool = gear(w, { slot = "", level = 300 })
  check("epic disenchantable", ns.isDisenchantable(epic) == true)
  check("rare disenchantable", ns.isDisenchantable(rare) == true)
  check("common is not", ns.isDisenchantable(common) == false)
  check("heirloom is not", ns.isDisenchantable(heir) == false)
  check("no price is not", ns.isDisenchantable(noprice) == false)
  check("uncached is not", ns.isDisenchantable(ghost) == false)
  check("non gear is not", ns.isDisenchantable(potion) == false)
  check("no equip loc is not", ns.isDisenchantable(tool) == false)
end

-- 39. Manual sale with only kept gear: answers kept, runs no sale.
do
  local w = newWorld()
  w.canDE = true
  local ns = loadAddon(w)
  clientLoaded(w)
  ns.opts().junkOldGear = true
  ns.opts().autoSell = false
  ns.opts().autoRepair = false
  w.equipped[1] = gear(w, { slot = "INVTYPE_HEAD", level = 400 })
  putBag(w, gear(w, { slot = "INVTYPE_HEAD", level = 300 }))
  w.frame.onEvent(nil, "MERCHANT_SHOW") -- installs the button hook
  w.env.SlashCmdList.VOCVENDOR("")
  check("manual kept opens the window", ns.deWindow ~= nil and ns.deWindow:IsShown())
  check("manual kept lists the item", #ns.deRows == 1)
  check("no kept chat on manual sale", #w.printed == 0)
  check("native click skipped when only kept", w.blizzClicked == false)
  check("no popup when only kept", #w.popups == 0)
end

-- 40. Dry-run mixes: common old gear sells, epic old gear is kept.
do
  local w = newWorld()
  w.canDE = true
  local ns = loadAddon(w)
  clientLoaded(w)
  ns.opts().junkOldGear = true
  ns.opts().autoSell = false
  ns.opts().autoRepair = false
  w.equipped[1] = gear(w, { slot = "INVTYPE_HEAD", level = 400 })
  local commonOld = gear(w, { slot = "INVTYPE_HEAD", level = 300, price = 1200, rarity = 1 })
  putBag(w, commonOld)
  putBag(w, gear(w, { slot = "INVTYPE_HEAD", level = 300, price = 800 }))
  w.frame.onEvent(nil, "MERCHANT_SHOW") -- installs the button hook
  w.hookedClick.OnClick(w.env.MerchantSellAllJunkButton)
  check("dry-run sells only the common",
    w.printed[1] == "|cff66ccffVocVendor|r: junk to sell (0 gray, 1 old gear):")
  check("dry-run merges the common", w.printed[2] == "  " .. commonOld .. " for 12s 0c")
  check("dry-run opens the disenchant window", ns.deWindow ~= nil and ns.deWindow:IsShown())
  check("window lists only the kept epic", #ns.deRows == 1)
  check("no kept chat beside the window", #w.printed == 2)
  check("one popup for the common", #w.popups == 1 and w.popups[1].a == 1)
  check("popup totals the common", w.popups[1].b == "12s 0c")
  check("blizzard click skipped", w.blizzClicked == false)
end

-- 41. Popup confirm also reports what was kept.
do
  local w = newWorld()
  w.canDE = true
  w.junkCount = 2
  w.junkValue = 450
  local ns = loadAddon(w)
  clientLoaded(w)
  ns.opts().junkOldGear = true
  w.equipped[1] = gear(w, { slot = "INVTYPE_HEAD", level = 400 })
  putBag(w, gear(w, { slot = "INVTYPE_HEAD", level = 300 }))
  ns.sellJunkNow({ grayCount = 2, oldGear = {} })
  check("confirm stays silent before close", #w.printed == 0)
  w.frame.onEvent(nil, "MERCHANT_CLOSED")
  check("confirm line deferred to close",
    w.printed[1] == "|cff66ccffVocVendor|r: sold 2 items for 4s 50c")
  check("confirm opens the window for kept gear",
    ns.deWindow ~= nil and ns.deWindow:IsShown())
  check("confirm lists the kept item", #ns.deRows == 1)
end

-- 42. Row click arms a Disenchant macro for the item's slot, then clears.
do
  local w = newWorld()
  w.canDE = true
  w.repairCan = false
  local ns = loadAddon(w)
  clientLoaded(w)
  ns.opts().junkOldGear = true
  ns.opts().announce = false -- the window opens regardless of announce
  w.equipped[1] = gear(w, { slot = "INVTYPE_HEAD", level = 400 })
  local old = gear(w, { slot = "INVTYPE_HEAD", level = 300, price = 1000 })
  putBag(w, old)
  w.frame.onEvent(nil, "MERCHANT_SHOW")
  check("window opens unannounced", ns.deWindow:IsShown() and #w.printed == 0)
  check("row shows the kept link", ns.deRows[1].text.text == old)
  local row = ns.deRows[1]
  row.scripts.PreClick(row, "LeftButton", true)
  check("row arms a macro", row.attrs.type == "macro")
  check("macro casts Disenchant on the slot",
    row.attrs.macrotext == "/cast Disenchant\n/use 0 1")
  row.scripts.PostClick(row)
  check("macro cleared after click", row.attrs.type == nil)
  row.scripts.OnClick(row, "LeftButton", false)
  check("row click confirms with sound", w.playedSounds[#w.playedSounds] == 856)
end

-- 43. Stale slots re-resolve by link; vanished links disarm the click.
do
  local w = newWorld()
  w.canDE = true
  w.repairCan = false
  local ns = loadAddon(w)
  clientLoaded(w)
  ns.opts().junkOldGear = true
  w.equipped[1] = gear(w, { slot = "INVTYPE_HEAD", level = 400 })
  local old = gear(w, { slot = "INVTYPE_HEAD", level = 300, price = 1000 })
  putBag(w, old)
  w.frame.onEvent(nil, "MERCHANT_SHOW")
  local row = ns.deRows[1]
  -- Bag shifted: another item sits in slot 1, the kept item in slot 2.
  local other = gear(w, { slot = "INVTYPE_HEAD", level = 399 })
  w.bags[0][1] = other
  w.bags[0][2] = old
  row.scripts.PreClick(row, "LeftButton", true)
  check("click follows the link", row.attrs.macrotext == "/cast Disenchant\n/use 0 2")
  w.bags[0][2] = other -- the kept item left the bags entirely
  row.scripts.PreClick(row, "LeftButton", true)
  check("vanished link disarms the click", row.attrs.type == nil)
end

-- 44. Bag updates empty the list: disenchant everything, window closes.
do
  local w = newWorld()
  w.canDE = true
  w.repairCan = false
  local ns = loadAddon(w)
  clientLoaded(w)
  ns.opts().junkOldGear = true
  w.equipped[1] = gear(w, { slot = "INVTYPE_HEAD", level = 400 })
  putBag(w, gear(w, { slot = "INVTYPE_HEAD", level = 300, price = 1000 }))
  w.frame.onEvent(nil, "MERCHANT_SHOW")
  check("window open before disenchanting", ns.deWindow:IsShown())
  check("bag update registered", w.frame.events.BAG_UPDATE == true)
  w.bags[0] = {} -- the item is disenchanted: gone from the bags
  w.frame.onEvent(nil, "BAG_UPDATE")
  check("window closes when emptied", not ns.deWindow:IsShown())
  check("close confirms", w.playedSounds[#w.playedSounds] == 851)
end

-- 45. Slash reopens the list anywhere; empty bags answer instead.
do
  local w = newWorld()
  w.canDE = true
  local ns = loadAddon(w)
  clientLoaded(w)
  ns.opts().junkOldGear = true
  w.equipped[1] = gear(w, { slot = "INVTYPE_HEAD", level = 400 })
  putBag(w, gear(w, { slot = "INVTYPE_HEAD", level = 300, price = 1000 }))
  w.env.SlashCmdList.VOCVENDOR("disenchant")
  check("slash opens the list", ns.deWindow:IsShown() and #ns.deRows == 1)
  w.bags[0] = {}
  if ns.deWindow:IsShown() then ns.deWindow:Hide() end
  w.playedSounds = {}
  w.env.SlashCmdList.VOCVENDOR("disenchant")
  check("empty list answers",
    w.printed[#w.printed] == "|cff66ccffVocVendor|r: nothing to disenchant")
  check("help lists disenchant",
    table.concat(ns.HELP, "\n"):find("/vv disenchant", 1, true) ~= nil)
end

-- 46. No secure buttons: the kept report falls back to chat.
do
  local w = newWorld()
  w.canDE = true
  w.repairCan = false
  w.noSecure = true
  local ns = loadAddon(w)
  clientLoaded(w)
  ns.opts().junkOldGear = true
  w.equipped[1] = gear(w, { slot = "INVTYPE_HEAD", level = 400 })
  putBag(w, gear(w, { slot = "INVTYPE_HEAD", level = 300, price = 1000 }))
  w.frame.onEvent(nil, "MERCHANT_SHOW")
  check("fallback chat", w.printed[1] == "|cff66ccffVocVendor|r: kept 1 for disenchant")
  check("no rows without secure buttons", #ns.deRows == 0)
end

-- 47. Combat: clicks arm nothing, the list stays put.
do
  local w = newWorld()
  w.canDE = true
  w.repairCan = false
  local ns = loadAddon(w)
  clientLoaded(w)
  ns.opts().junkOldGear = true
  w.equipped[1] = gear(w, { slot = "INVTYPE_HEAD", level = 400 })
  putBag(w, gear(w, { slot = "INVTYPE_HEAD", level = 300, price = 1000 }))
  w.frame.onEvent(nil, "MERCHANT_SHOW")
  local row = ns.deRows[1]
  w.combat = true
  row.scripts.PreClick(row, "LeftButton", true)
  check("combat click arms nothing", row.attrs.type == nil)
  check("combat click says so",
    w.printed[#w.printed] == "|cff66ccffVocVendor|r: can't disenchant during combat")
  w.frame.onEvent(nil, "BAG_UPDATE") -- combat refresh leaves the list alone
  check("combat bag update keeps the list", ns.deWindow:IsShown())
  check("combat show falls back to chat",
    ns.refreshDEWindow(ns.collectKeptDisenchantables()) == nil)
end

-- 48. Compartment click opens the list while kept gear waits.
do
  local w = newWorld()
  w.canDE = true
  local ns = loadAddon(w)
  clientLoaded(w)
  ns.opts().junkOldGear = true
  w.equipped[1] = gear(w, { slot = "INVTYPE_HEAD", level = 400 })
  putBag(w, gear(w, { slot = "INVTYPE_HEAD", level = 300, price = 1000 }))
  local opened = nil
  w.env.Settings.OpenToCategory = function(id) opened = id end
  w.env.VocVendor_CompartmentClick("VocVendor", "LeftButton")
  check("compartment opens the list", ns.deWindow:IsShown())
  check("compartment skips settings when items wait", opened == nil)
  w.bags[0] = {}
  if ns.deWindow:IsShown() then ns.deWindow:Hide() end
  w.env.VocVendor_CompartmentClick("VocVendor", "LeftButton")
  check("compartment opens settings when empty", opened == 7)
end

-- 49. Legendary and artifact gear is never listed for disenchant: the
-- Disenchant spell targets uncommon, rare, and epic weapons/armor only.
-- (Screenshot regression: artifact weapons opened the disenchant list.)
do
  local w = newWorld()
  w.canDE = true
  local ns = loadAddon(w)
  clientLoaded(w)
  ns.opts().junkOldGear = true
  w.equipped[1] = gear(w, { slot = "INVTYPE_HEAD", level = 400 })
  local legendary = gear(w, { slot = "INVTYPE_HEAD", level = 300, rarity = 5 })
  local artifact = gear(w, { slot = "INVTYPE_HEAD", level = 300, rarity = 6 })
  local epic = gear(w, { slot = "INVTYPE_HEAD", level = 300, rarity = 4 })
  check("legendary is not disenchantable", ns.isDisenchantable(legendary) == false)
  check("artifact is not disenchantable", ns.isDisenchantable(artifact) == false)
  check("epic still is", ns.isDisenchantable(epic) == true)
  putBag(w, artifact)
  putBag(w, legendary)
  check("no artifact or legendary kept for disenchant",
    #ns.collectKeptDisenchantables() == 0)
  check("artifact and legendary sell as old gear",
    #ns.collectJunk().oldGear == 2)
end

-- 50. Slots the vendor will not buy are never collected or sold.
do
  local w = newWorld()
  local ns = loadAddon(w)
  clientLoaded(w)
  ns.opts().junkOldGear = true
  w.equipped[1] = gear(w, { slot = "INVTYPE_HEAD", level = 400 })
  local refused = gear(w, { slot = "INVTYPE_HEAD", level = 300, price = 1000 })
  local rb, rs = putBag(w, refused)
  w.noValues[rb .. ":" .. rs] = true
  local wanted = gear(w, { slot = "INVTYPE_HEAD", level = 300, price = 1000 })
  local wb, ws = putBag(w, wanted)
  check("slot without value detected", ns.slotHasValue(rb, rs) == false)
  check("slot with value detected", ns.slotHasValue(wb, ws) == true)
  local junk = ns.collectJunk()
  check("refused slot not collected",
    #junk.oldGear == 1 and junk.oldGear[1].link == wanted)
  local n = ns.sellOldGearItems({
    { link = refused, bag = rb, slot = rs, price = 1000 },
    { link = wanted, bag = wb, slot = ws, price = 1000 },
  })
  check("refused slot not sold at confirm", n == 1 and #w.sold == 1)
  check("wanted slot sold", w.sold[1].bag == wb and w.sold[1].slot == ws)
end

-- 51. Missing container value API keeps old gear (fail closed).
do
  local w = newWorld()
  local ns = loadAddon(w)
  clientLoaded(w)
  ns.opts().junkOldGear = true
  w.equipped[1] = gear(w, { slot = "INVTYPE_HEAD", level = 400 })
  putBag(w, gear(w, { slot = "INVTYPE_HEAD", level = 300 }))
  w.noContainerInfo = true -- GetContainerItemInfo returns nothing
  check("missing value API keeps the item", ns.slotHasValue(0, 1) == false)
  check("nothing collected without the API", #ns.collectJunk().oldGear == 0)
end

-- 52. A failing click halts the loop: the failing item and everything
-- after it come back as leftovers with per-row reasons, and nothing
-- later is even attempted.
do
  local w = newWorld()
  local ns = loadAddon(w)
  clientLoaded(w)
  ns.opts().junkOldGear = true
  w.equipped[1] = gear(w, { slot = "INVTYPE_HEAD", level = 400 })
  local first = gear(w, { slot = "INVTYPE_HEAD", level = 300, price = 1000 })
  local bad = gear(w, { slot = "INVTYPE_HEAD", level = 310, price = 1000 })
  local after = gear(w, { slot = "INVTYPE_HEAD", level = 320, price = 1000 })
  local b1, s1 = putBag(w, first)
  local b2, s2 = putBag(w, bad)
  local b3, s3 = putBag(w, after)
  w.sellErrors[b2 .. ":" .. s2] = true -- the click errors
  local n, value, leftover = ns.sellOldGearItems({
    { link = first, bag = b1, slot = s1, price = 1000 },
    { link = bad, bag = b2, slot = s2, price = 1000 },
    { link = after, bag = b3, slot = s3, price = 1000 },
  })
  check("one sold before the failure", n == 1 and value == 1000)
  check("loop halted at the failure", #w.sold == 1)
  check("failing item listed", leftover[1].link == bad)
  check("failing reason", leftover[1].reason == "sell failed")
  check("rest listed as stopped",
    #leftover == 2 and leftover[2].link == after
    and leftover[2].reason == "sale stopped")
  ns.reportLeftover(leftover)
  check("leftover header",
    w.printed[1] == "|cff66ccffVocVendor|r: couldn't sell 2 items:")
  check("leftover rows name reasons",
    w.printed[2] == "  " .. bad .. " (sell failed)"
    and w.printed[3] == "  " .. after .. " (sale stopped)")
  check("empty leftover stays silent",
    (function() local before = #w.printed ns.reportLeftover({}) return #w.printed == before end)())
end

-- 53. An item the click leaves behind halts too, without retrying.
do
  local w = newWorld()
  local ns = loadAddon(w)
  clientLoaded(w)
  ns.opts().junkOldGear = true
  w.equipped[1] = gear(w, { slot = "INVTYPE_HEAD", level = 400 })
  local stuck = gear(w, { slot = "INVTYPE_HEAD", level = 300, price = 1000 })
  local sb, ss = putBag(w, stuck)
  w.stuck[sb .. ":" .. ss] = true -- sold but still in the slot
  local n, _, leftover = ns.sellOldGearItems({
    { link = stuck, bag = sb, slot = ss, price = 1000 },
  })
  check("stuck item not counted", n == 0)
  check("no retry", #w.sold == 1)
  check("stuck reason", #leftover == 1 and leftover[1].reason == "still in bags")
end

-- 54. Collection gate: uncollected appearances, toys, and pets never
-- count as old gear. Collected ones sell like anything else.
do
  local w = newWorld()
  local ns = loadAddon(w)
  clientLoaded(w)
  ns.opts().junkOldGear = true
  w.equipped[1] = gear(w, { slot = "INVTYPE_HEAD", level = 400 })
  local cosmetic = gear(w, { slot = "INVTYPE_HEAD", level = 300 })
  w.cosmetic[w.itemIDs[cosmetic]] = true
  w.noTransmog[cosmetic] = true
  check("unknown appearance kept", ns.isUncollectedCollectible(cosmetic) == true)
  check("unknown appearance never old gear", ns.isOldGear(cosmetic, 30) == false)
  w.noTransmog[cosmetic] = nil -- appearance learned since
  check("known appearance sells", ns.isOldGear(cosmetic, 30) == true)
  local toy = gear(w, { slot = "INVTYPE_HEAD", level = 300 })
  w.toyInfo[w.itemIDs[toy]] = 1 -- the toy journal knows this item
  check("unowned toy kept", ns.isUncollectedCollectible(toy) == true)
  w.ownedToys[w.itemIDs[toy]] = true
  check("owned toy sells", ns.isUncollectedCollectible(toy) == false)
  local pet = gear(w, { slot = "INVTYPE_HEAD", level = 300 })
  w.petSpecies[w.itemIDs[pet]] = 77
  check("uncollected pet kept", ns.isUncollectedCollectible(pet) == true)
  check("uncollected pet never old gear", ns.isOldGear(pet, 30) == false)
  w.petOwned[77] = true -- duplicate of a collected pet
  check("collected pet sells", ns.isUncollectedCollectible(pet) == false)
  check("ordinary gear unaffected", ns.isUncollectedCollectible(
    gear(w, { slot = "INVTYPE_HEAD", level = 300 })) == false)
end

-- 55. Collection gate fails closed: a missing or broken API keeps.
do
  local w = newWorld()
  local ns = loadAddon(w)
  clientLoaded(w)
  local link = gear(w, { slot = "INVTYPE_HEAD", level = 300 })
  w.env.C_TransmogCollection = nil
  w.cosmetic[w.itemIDs[link]] = true
  check("missing appearance API keeps", ns.isUncollectedCollectible(link) == true)
  w.env.C_TransmogCollection = { PlayerHasTransmogByItemInfo = function() error("boom") end }
  check("erroring appearance API keeps", ns.isUncollectedCollectible(link) == true)
end

-- 56. Rival detection: a loaded same-job addon warns once and pauses
-- auto-sell, naming the exact re-enable command.
do
  local w = newWorld()
  local ns = loadAddon(w)
  w.loadedAddons.Scrap = true
  clientLoaded(w) -- ADDON_LOADED fires the check
  check("rival found", ns.findRival() == "Scrap")
  check("rival pauses auto-sell", ns.opts().autoSell == false)
  check("rival names the re-enable",
    w.printed[1] == "|cff66ccffVocVendor|r: Scrap also sells junk: auto-sell paused (turn back on with /vv on)")
  w.frame.onEvent(nil, "PLAYER_LOGIN")
  check("warned once", #w.printed == 1)
  w.env.SlashCmdList.VOCVENDOR("on") -- the player takes it back
  check("re-enable works", ns.opts().autoSell == true)
  check("still warned once", #w.printed == 2)
end

-- 57. No rival, no warning, nothing touched.
do
  local w = newWorld()
  local ns = loadAddon(w)
  clientLoaded(w)
  w.frame.onEvent(nil, "PLAYER_LOGIN")
  check("no rival", ns.findRival() == nil)
  check("auto-sell untouched", ns.opts().autoSell == true)
  check("silent without rival", #w.printed == 0)
end

-- 58. Two visits, two lines: the visit count resets on close.
do
  local w = newWorld()
  w.junkCount = 1
  w.junkValue = 100
  w.repairCan = false
  loadAddon(w)
  clientLoaded(w)
  w.frame.onEvent(nil, "MERCHANT_SHOW")
  w.frame.onEvent(nil, "MERCHANT_CLOSED")
  check("first visit one line",
    #w.printed == 1 and w.printed[1] == "|cff66ccffVocVendor|r: sold 1 item for 1s 0c")
  w.junkCount = 2
  w.junkValue = 50
  w.frame.onEvent(nil, "MERCHANT_SHOW")
  w.frame.onEvent(nil, "MERCHANT_CLOSED")
  check("second visit one line",
    #w.printed == 2 and w.printed[2] == "|cff66ccffVocVendor|r: sold 2 items for 50c")
end

-- 59. Auction math: net-of-cut comparison across vendor, auction, disenchant.
do
  local w = newWorld()
  local ns = loadAddon(w)
  check("net cuts 5 percent", ns.auctionNet(100) == 95)
  check("net floors", ns.auctionNet(101) == 95)
  check("net zero", ns.auctionNet(0) == 0)
  check("net nil", ns.auctionNet(nil) == 0)
  check("no data vendors", ns.compareItem(1000, nil, nil) == "vendor")
  check("tie vendors", ns.compareItem(1000, 1052, nil) == "vendor")
  check("auction wins", ns.compareItem(1000, 2000, nil) == "auction")
  check("losing auction vendors", ns.compareItem(1000, 500, nil) == "vendor")
  check("disenchant wins", ns.compareItem(1000, nil, 2000) == "disenchant")
  check("best of three disenchant", ns.compareItem(1000, 2000, 3000) == "disenchant")
  check("best of three auction", ns.compareItem(1000, 3000, 2000) == "auction")
end

-- 60. Price providers: Auctionator first, then TSM, then Oribos; broken
-- guests never break the lookup.
do
  local w = newWorld()
  local ns = loadAddon(w)
  w.itemIDs["item:priced"] = 777
  w.env.Auctionator = { API = { v1 = {
    GetAuctionPriceByItemID = function(_, id) return id == 777 and 3000 or nil end,
    GetAuctionPriceByItemLink = function() return 2500 end,
  } } }
  check("auctionator by ID", ns.getAuctionPrice("item:priced") == 3000)
  w.env.Auctionator.API.v1.GetAuctionPriceByItemID = nil
  check("auctionator by link", ns.getAuctionPrice("item:priced") == 2500)
  w.env.Auctionator.API.v1.GetAuctionPriceByItemLink = function() error("boom") end
  w.env.TSM_API = {
    ToItemString = function(link) return "i:" .. link end,
    GetCustomPriceValue = function() return 2000 end,
  }
  check("erroring guest falls through to TSM", ns.getAuctionPrice("item:priced") == 2000)
  w.env.TSM_API.ToItemString = function() error("boom") end
  w.env.OEMarketInfo = function(link, info) info.market = 1500 end
  check("broken TSM falls through to Oribos", ns.getAuctionPrice("item:priced") == 1500)
  w.env.OEMarketInfo = function() error("boom") end
  check("all broken means no opinion", ns.getAuctionPrice("item:priced") == nil)
  check("no guests means no opinion", ns.getAuctionPrice("item:ghost") == nil)
end

-- 61. Disenchant value comes from Auctionator's DE data, guarded too.
do
  local w = newWorld()
  local ns = loadAddon(w)
  check("no DE data", ns.getDisenchantValue("item:de") == nil)
  w.itemIDs["item:de"] = 888
  w.env.Auctionator = { API = { v1 = {
    GetDisenchantPriceByItemLink = function() return 4000 end,
  } } }
  check("DE by link", ns.getDisenchantValue("item:de") == 4000)
  w.env.Auctionator.API.v1.GetDisenchantPriceByItemLink = function() error("boom") end
  check("broken DE guarded", ns.getDisenchantValue("item:de") == nil)
end

-- 62. The vendor sale skips whatever the auction math favors, and says why.
do
  local w = newWorld()
  local ns = loadAddon(w)
  clientLoaded(w)
  local seq = 9000
  local function stock(link, price)
    seq = seq + 1
    w.itemIDs[link] = seq
    w.slots[link] = "INVTYPE_HEAD"
    w.classIDs[link] = 4
    w.rarities[link] = 2
    w.levels[link] = 100
    w.prices[link] = price
    w.bindTypes[link] = 1
    w.bags[0] = w.bags[0] or {}
    w.bags[0][#w.bags[0] + 1] = link
    return 0, #w.bags[0]
  end
  local bagA, slotA = stock("item:aucwin", 1000)
  local bagB, slotB = stock("item:vendorwin", 1000)
  w.env.Auctionator = { API = { v1 = {
    GetAuctionPriceByItemID = function(_, id)
      if id == w.itemIDs["item:aucwin"] then return 5000 end
      return nil
    end,
  } } }
  local n, value, leftover = ns.sellOldGearItems({
    { link = "item:aucwin", bag = bagA, slot = slotA, price = 1000 },
    { link = "item:vendorwin", bag = bagB, slot = slotB, price = 1000 },
  })
  check("auction-better skipped", n == 1 and value == 1000)
  check("skip names the reason",
    #leftover == 1 and leftover[1].reason:find("auction worth more", 1, true) ~= nil)
  check("skip shows the net",
    leftover[1].reason:find("47s 50c net", 1, true) ~= nil)
  check("rest sold", #w.sold == 1)
end

-- 63. A disenchant net above vendor also holds the item back.
do
  local w = newWorld()
  local ns = loadAddon(w)
  clientLoaded(w)
  w.itemIDs["item:dewin"] = 9201
  w.slots["item:dewin"] = "INVTYPE_HEAD"
  w.classIDs["item:dewin"] = 4
  w.rarities["item:dewin"] = 2
  w.levels["item:dewin"] = 100
  w.prices["item:dewin"] = 1000
  w.bindTypes["item:dewin"] = 1
  w.bags[0] = { "item:dewin" }
  w.env.Auctionator = { API = { v1 = {
    GetDisenchantPriceByItemID = function() return 5000 end,
  } } }
  local n, _, leftover = ns.sellOldGearItems({
    { link = "item:dewin", bag = 0, slot = 1, price = 1000 },
  })
  check("de-better skipped",
    n == 0 and #leftover == 1
    and leftover[1].reason:find("disenchant worth more", 1, true) ~= nil)
end

-- 64. compareAuction off sells everything the vendor buys, like before.
do
  local w = newWorld()
  local ns = loadAddon(w)
  clientLoaded(w)
  ns.opts().compareAuction = false
  w.itemIDs["item:plain"] = 9301
  w.bags[0] = { "item:plain" }
  w.env.Auctionator = { API = { v1 = {
    GetAuctionPriceByItemID = function() return 50000 end,
  } } }
  local n, _, leftover = ns.sellOldGearItems({
    { link = "item:plain", bag = 0, slot = 1, price = 100 },
  })
  check("opt-out sells", n == 1 and #leftover == 0)
end

-- 65. Kept gear worth more on the auction gets a hint line.
do
  local w = newWorld()
  local ns = loadAddon(w)
  clientLoaded(w)
  w.itemIDs["item:keephint"] = 9101
  w.env.Auctionator = { API = { v1 = {
    GetAuctionPriceByItemID = function() return 5000 end,
    GetDisenchantPriceByItemLink = function() return 1000 end,
  } } }
  local hints = ns.keptAuctionHints({ { link = "item:keephint" } })
  check("hint listed",
    #hints == 1 and hints[1]:find("47s 50c net on auction", 1, true) ~= nil)
  w.env.Auctionator.API.v1.GetDisenchantPriceByItemLink = function() return 9000 end
  check("de-better silent",
    #ns.keptAuctionHints({ { link = "item:keephint" } }) == 0)
  ns.opts().compareAuction = false
  check("opt-out silent",
    #ns.keptAuctionHints({ { link = "item:keephint" } }) == 0)
end

-- 66. Current-expansion gear is never old gear, even far below the
-- equipped piece. Older expansions sell like before; unknown keeps.
do
  local w = newWorld()
  local ns = loadAddon(w)
  clientLoaded(w)
  ns.opts().junkOldGear = true
  w.equipped[1] = gear(w, { slot = "INVTYPE_HEAD", level = 400 })
  local current = gear(w, { slot = "INVTYPE_HEAD", level = 300, expansion = 11 })
  local older = gear(w, { slot = "INVTYPE_HEAD", level = 300, expansion = 10 })
  local unknown = gear(w, { slot = "INVTYPE_HEAD", level = 300 })
  w.expansions[unknown] = nil
  check("current expansion kept", ns.isOldGear(current, 30) == false)
  check("older expansion sells", ns.isOldGear(older, 30) == true)
  check("unknown expansion keeps", ns.isOldGear(unknown, 30) == false)
  check("expansion helper reads the ID", ns.expansionID(current) == 11)
  check("expansion helper nil when unknown", ns.expansionID(unknown) == nil)
  check("current helper true", ns.isCurrentExpansion(current) == true)
  check("current helper false for older", ns.isCurrentExpansion(older) == false)
  ns.opts().keepCurrentExpansion = false
  check("opt-out sells current too", ns.isOldGear(current, 30) == true)
  check("helper off", ns.isCurrentExpansion(current) == false)
end

print("ok - " .. passed .. " checks passed")
