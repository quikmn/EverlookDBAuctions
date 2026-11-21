-- Health self-test: what the game gives this addon right now, saved with the scans (EverlookAuctionsDB.health) so
-- EverlookDB.com can tell a game update that broke something apart from real prices, and its canary can warn early.
-- Only words, true/false and counts are kept: never a GUID, a name or a realm.
--   build, addon    the client build and this addon's version
--   day             the date of the last check
--   realm           "ok" or "empty": whether GetRealmName answers (WoW Forever answers "" since build 71037; the
--                   addon then finds the realm itself, see readRealm)
--   item            "ok", "slow" (not loaded within a few seconds) or "none" (no item API)
--   missing         auction APIs that are not there (a full scan can't work without them)
local _, ns = ...

-- what a full scan needs, on the auction API this client has
local MODERN = {
  "GetBuildInfo", "GetServerTime", "C_AuctionHouse.ReplicateItems", "C_AuctionHouse.GetNumReplicateItems",
  "C_AuctionHouse.GetReplicateItemInfo", "C_AuctionHouse.GetReplicateItemLink", "C_AuctionHouse.GetReplicateItemTimeLeft",
}
local CLASSIC = { "GetBuildInfo", "GetServerTime", "QueryAuctionItems", "GetAuctionItemInfo", "GetNumAuctionItems" }
local PROBE_ITEM = 2589  -- Linen Cloth: in every client

local function lookup(path)
  local t = _G
  for part in path:gmatch("[^.]+") do
    if type(t) ~= "table" then return nil end
    t = t[part]
  end
  return t
end

local function call(f, ...)
  if type(f) ~= "function" then return nil end
  local okCall, a, b = pcall(f, ...)
  if okCall then return a, b end
  return nil
end

local function itemName(id)
  local get = (C_Item and C_Item.GetItemInfo) or GetItemInfo
  if type(get) ~= "function" then return nil, false end
  local name = call(get, id)
  return type(name) == "string" and name ~= "" and name or nil, true
end

-- Run the test and return the health table (in `db`). Never throws: a broken API is what it reports.
function ns.HealthCheck(db, version)
  local v, b = call(GetBuildInfo)
  local h = {
    build = (type(v) == "string" and b) and (v .. "." .. tostring(b)) or "?",
    addon = version,
    day = call(date, "%Y-%m-%d"),
  }
  db.health = h
  local missing = {}
  for _, name in ipairs((C_AuctionHouse or not QueryAuctionItems) and MODERN or CLASSIC) do
    if type(lookup(name)) ~= "function" then missing[#missing + 1] = name end
  end
  h.missing = #missing > 0 and missing or nil
  local realm = call(GetRealmName)
  h.realm = (type(realm) == "string" and realm ~= "") and "ok" or "empty"
  local name, api = itemName(PROBE_ITEM)
  if not api then
    h.item = "none"
  elseif name then
    h.item = "ok"
  else
    h.item = "slow"
    if C_Item and C_Item.RequestLoadItemDataByID then call(C_Item.RequestLoadItemDataByID, PROBE_ITEM) end
    if C_Timer and C_Timer.After then C_Timer.After(10, function() if itemName(PROBE_ITEM) then h.item = "ok" end end) end
  end
  return h
end
