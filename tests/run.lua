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
    ItemQuality = { Heirloom = 7, Epic = 4 },
    ItemBind = { OnEquip = 2, OnAcquire = 1 },
  }
  g.C_Container = {
    GetContainerNumSlots = function(bag) return #(world.bags[bag] or {}) end,
    GetContainerItemLink = function(bag, slot)
      local b = world.bags[bag]
      return b and b[slot] or nil
    end,
    UseContainerItem = function(bag, slot)
      world.sold[#world.sold + 1] = { bag = bag, slot = slot }
      return true
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
        world.bindTypes[link], nil, world.setIDs[link], nil, nil
    end,
    GetDetailedItemLevelInfo = function(link) return world.levels[link] end,
    IsItemBindToAccountUntilEquip = function(link) return world.warbound[link] == true end,
  }
  g.C_MerchantFrame = {
    GetNumJunkItems = function() return world.junkCount end,
    SellAllJunkItems = function()
      world.junkSold = true
      world.money = world.money + world.junkValue
    end,
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
  g.MerchantFrame = {
    IsShown = function() return world.merchantOpen end,
  }
  g.CreateFrame = function(ftype)
    local f = { events = {}, scripts = {}, ctype = ftype }
    f.RegisterEvent = function(_, e) f.events[e] = true end
    f.SetScript = function(_, n, fn) f.scripts[n] = fn end
    f.SetText = function(_, t) f.text = t end
    f.SetSize = function(_, w, h) f.size = { w, h } end
    f.SetPoint = function(_, ...) f.point = { ... } end
    world.frames[#world.frames + 1] = f
    return f
  end
  g.GameTooltip = {
    SetOwner = function() end,
    SetText = function(_, t) world.gametip.title = t end,
    AddLine = function(_, t) world.gametip.line = t end,
    Show = function() end,
    Hide = function() end,
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
    setIDs = {}, itemIDs = {}, uncached = {}, warbound = {},
    equipped = {}, printed = {}, frames = {}, gametip = {},
    money = 100000, junkCount = 0, junkValue = 0, junkSold = false,
    sold = {}, repairs = {}, popups = {},
    canRepair = true, repairCost = 0, repairCan = false,
    guildRepair = false, guildCovers = true,
    merchantOpen = true, withPawn = false, pawnUpgrades = {},
    settingsReg = {}, settingsChecks = 0, settingsSliders = 0,
    settingsCategory = nil, savedVars = nil,
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

-- 3. MERCHANT_SHOW auto-sells junk and announces the take.
do
  local w = newWorld()
  w.junkCount = 3
  w.junkValue = 450
  w.repairCan = false
  loadAddon(w)
  clientLoaded(w)
  w.frame.onEvent(nil, "MERCHANT_SHOW")
  check("junk sold", w.junkSold == true)
  check("junk announce", w.printed[1] == "|cff66ccffVocVendor|r: sold 3 junk for 4s 50c")
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

-- 17. Sell Old Gear click with nothing: says so, no popup.
do
  local w = newWorld()
  local ns = loadAddon(w)
  clientLoaded(w)
  w.equipped[1] = gear(w, { slot = "INVTYPE_HEAD", level = 400 })
  putBag(w, gear(w, { slot = "INVTYPE_HEAD", level = 395 })) -- too new
  ns.onSellOldGearClick()
  check("empty says so", w.printed[1] == "|cff66ccffVocVendor|r: no old gear to sell")
  check("empty no popup", #w.popups == 0)
end

-- 18. Sell Old Gear click: itemized dry-run in chat, one confirm popup.
do
  local w = newWorld()
  local ns = loadAddon(w)
  clientLoaded(w)
  w.equipped[1] = gear(w, { slot = "INVTYPE_HEAD", level = 400 })
  local old1 = gear(w, { slot = "INVTYPE_HEAD", level = 300, price = 1200 })
  local old2 = gear(w, { slot = "INVTYPE_HEAD", level = 310, price = 800 })
  putBag(w, old1)
  putBag(w, old2)
  ns.onSellOldGearClick()
  check("dry-run header", w.printed[1] == "|cff66ccffVocVendor|r: old gear to sell (2):")
  check("dry-run lists links", w.printed[2] == "  " .. old1 and w.printed[3] == "  " .. old2)
  check("one popup", #w.popups == 1)
  check("popup count", w.popups[1].a == 2)
  check("popup total", w.popups[1].b == "20s 0c")
  check("popup carries items", #(w.popups[1].data.items) == 2)
end

-- 19. Confirm sells exactly the listed slots; skips moved items.
do
  local w = newWorld()
  local ns = loadAddon(w)
  clientLoaded(w)
  w.equipped[1] = gear(w, { slot = "INVTYPE_HEAD", level = 400 })
  local old1 = gear(w, { slot = "INVTYPE_HEAD", level = 300 })
  local old2 = gear(w, { slot = "INVTYPE_HEAD", level = 310 })
  local b1, s1 = putBag(w, old1)
  local b2, s2 = putBag(w, old2)
  -- Bag shifted between dry-run and confirm: old2 moved away.
  w.bags[b2][s2] = gear(w, { slot = "INVTYPE_HEAD", level = 399 })
  ns.sellOldGearNow({
    { link = old1, bag = b1, slot = s1 },
    { link = old2, bag = b2, slot = s2 },
  })
  check("only matching slot sold", #w.sold == 1)
  check("right slot sold", w.sold[1].bag == b1 and w.sold[1].slot == s1)
  check("sold announce", w.printed[1] == "|cff66ccffVocVendor|r: sold 1 old items")
end

-- 20. Vendor button: created once on first merchant visit.
do
  local w = newWorld()
  loadAddon(w)
  clientLoaded(w)
  w.repairCan = false
  w.frame.onEvent(nil, "MERCHANT_SHOW")
  w.frame.onEvent(nil, "MERCHANT_SHOW")
  local buttons = {}
  for _, f in ipairs(w.frames) do
    if f.text == "Sell Old Gear" then buttons[#buttons + 1] = f end
  end
  check("one button", #buttons == 1)
  buttons[1].scripts.OnEnter(buttons[1])
  check("button tooltip title", w.gametip.title == "Sell Old Gear")
  -- Clicking with no candidates says so (no popup).
  buttons[1].scripts.OnClick()
  check("button click empty", w.printed[1] == "|cff66ccffVocVendor|r: no old gear to sell")
end

-- 21. Slash: bare sells junk at a vendor, warns away from one.
do
  local w = newWorld()
  w.junkCount = 2
  loadAddon(w)
  clientLoaded(w)
  w.env.SlashCmdList.VOCVENDOR("")
  check("slash sells junk", w.junkSold == true)
  w.junkSold = false
  w.merchantOpen = false
  w.env.SlashCmdList.VOCVENDOR("")
  check("slash warns away", w.printed[#w.printed] == "|cff66ccffVocVendor|r: open a vendor first")
  check("slash no sale away", w.junkSold == false)
end

-- 22. Slash: on/off toggles auto-sell; repair triggers repair.
do
  local w = newWorld()
  local ns = loadAddon(w)
  clientLoaded(w)
  w.env.SlashCmdList.VOCVENDOR("off")
  check("auto-sell off", ns.opts().autoSell == false)
  check("off announce", w.printed[1] == "|cff66ccffVocVendor|r: auto-sell junk off")
  w.env.SlashCmdList.VOCVENDOR("on")
  check("auto-sell on", ns.opts().autoSell == true)
  w.repairCost = 100
  w.repairCan = true
  w.env.SlashCmdList.VOCVENDOR("repair")
  check("slash repair", #w.repairs == 1)
end

-- 23. Settings panel registers the expected controls.
do
  local w = newWorld()
  loadAddon(w)
  clientLoaded(w)
  check("category", w.settingsCategory == "VocVendor")
  check("autoSell setting", w.env.Settings and w.settingsReg["VocVendor_autoSell"] ~= nil)
  check("gap slider", w.settingsSliders == 1)
  check("gap default", w.settingsReg["VocVendor_oldGearIlvlGap"].default == 30)
  check("checkboxes", w.settingsChecks == 6)
end

print("ok - " .. passed .. " checks passed")
