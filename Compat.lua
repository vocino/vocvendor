local ns = select(2, ...)
-- Compat: flavor detection lives here and nowhere else. Every other
-- file asks Compat or probes a capability; nothing checks
-- WOW_PROJECT_ID, GetBuildInfo, or Interface version outside this file
-- (FAMILY.md "Dual clients, one codebase").
local project = WOW_PROJECT_ID
local mainline = WOW_PROJECT_MAINLINE
local camelot = WOW_PROJECT_CAMELOT
if type(camelot) ~= "number" then camelot = 18 end
ns.IS_RETAIL = project ~= nil and project == mainline
ns.IS_FOREVER = project ~= nil and project == camelot
if not ns.IS_RETAIL and not ns.IS_FOREVER and type(GetBuildInfo) == "function" then
  local ok, interface = pcall(function()
    return select(4, GetBuildInfo())
  end)
  if ok and interface == 16001 then
    ns.IS_FOREVER = true
  end
end
ns.FLAVOR = ns.IS_FOREVER and "forever" or "retail"

-- Capability first: if the API exists, use it. Branch on flavor only
-- for what no existence check can decide.
function ns.hasAPI(table_, fname)
  return type(table_) == "table" and type(table_[fname]) == "function"
end

-- Feature matrix (FAMILY.md "Dual clients, one codebase"): the
-- expansion checklist, and the dead-item list built from it, are
-- Retail-only. Forever has no expansions, so there is nothing to
-- check and nothing to clean up: the settings stay hidden and every
-- collector stays empty there. Unknown clients behave like Retail
-- (nothing hides, nothing stops selling).
function ns.hasExpansions()
  return ns.IS_FOREVER ~= true
end
