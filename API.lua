-- EverlookDB Auctions: a small read-only API for other addons.
--
--   local api = EverlookDBAuctionsAPI
--   if api and api.version >= 1 then
--     local low, age, qty, auctions = api.price(itemID)
--   end
--
--   api.version                           number: goes up by one whenever something is added; nothing is ever removed
--   api.price(item[, suffix[, side]])     lowest buyout per unit in copper, its age in seconds, how many are up, how
--                                         many auctions (nil when only a search saw it), and (version 3) where it is
--                                         from: "own" (this player's scans and searches) or "shared" (other players'
--                                         newest scan, from the EverlookDB App); nil when there is no price
--   api.history(item[, side])             the lowest price per day for the last 30 days, oldest first:
--                                         { { day = unix time at the start of that day (UTC), low = copper }, ... }
--                                         (own and shared scans together: the lower of the two each day)
--   api.disenchant(item)                  what disenchanting the item is worth on the auction house, in copper, an
--                                         estimate from the drop chances in classic-db and today's material prices,
--                                         and how old the oldest material price is; nil when it can't be disenchanted
--                                         or a material has no price
--   api.addShoppingList(name, items)      (version 2) saves a shopping list in the auction house's Shopping tab:
--                                         items = { { itemID, count }, ... }. A list with the same name is
--                                         replaced, so pushing it again updates it. Returns true and whether the list
--                                         is new, or false and why: "no name", "no items", "loading" (the game hasn't
--                                         loaded every item's name yet: call again in a moment) or "not ready" (before
--                                         the addon has loaded its saved data). Only item names and counts are saved.
--
-- `item` is an item ID or an item link (a link carries its random-stat version, "of the Bear", so price() then
-- looks that version up; with an ID, pass the version's suffix ID as the second argument). Prices are for the player's
-- realm and their own faction's auction house, or the one that is open right now; `side` ("Alliance", "Horde" or
-- "Neutral") picks one. Every call reads what is already saved: nothing is sent to the server, and the tables
-- returned are copies. addShoppingList is the one call that writes: it only adds or replaces a list.
local _, ns = ...

local api = { version = 3 }

local function idOf(item)
  if type(item) == "number" then return item end
  if type(item) == "string" then return tonumber(item:match("item:(%-?%d+)") or item) end
end

function api.price(item, suffix, side)
  local id = idOf(item)
  if not id then return nil end
  if type(item) == "string" and suffix == nil then
    local _, s = ns.variantOf(id, item)
    if s and s ~= 0 then suffix = s end
  end
  if suffix and suffix ~= 0 then
    local row = ns.scanRowFor(id .. ":" .. suffix, side)
    if not row or not row.low then return nil end
    return row.low, math.max(0, GetServerTime() - row.at), row.qty, row.n, row.shared and "shared" or "own"
  end
  local it = ns.itemFor(id, side)
  if not it or not it[1] then return nil end
  return it[1], math.max(0, time() - (it[4] or 0)), it[2], it[3], it.shared and "shared" or "own"
end

function api.history(item, side)
  local id = idOf(item)
  local out = {}
  if not id then return out end
  for _, d in ipairs(ns.historyFor(id, side)) do out[#out + 1] = { day = d[1] * 86400, low = d[2] } end
  return out
end

function api.disenchant(item)
  local id = idOf(item)
  if not id or not ns.disenchantValue then return nil end
  local value, age = ns.disenchantValue(id)
  return value, age
end

function api.addShoppingList(name, items)
  local d = ns.db and ns.db()
  if type(d) ~= "table" or not ns.recipeList then return false, "not ready" end
  d.lists = d.lists or {}
  local l, why = ns.recipeList.saveCounts(d.lists, name, items, function(id)
    local okName, n = pcall(C_Item.GetItemNameByID, id)
    if not (okName and n) and C_Item.RequestLoadItemDataByID then pcall(C_Item.RequestLoadItemDataByID, id) end
    return okName and n or nil
  end)
  if not l then return false, why end
  if ns.shoppingRefresh then pcall(ns.shoppingRefresh) end
  return true, why and true or false
end

-- Read-only: writes to the table are refused, so one addon can't break it for another.
EverlookDBAuctionsAPI = setmetatable({}, {
  __index = api,
  __newindex = function() error("EverlookDBAuctionsAPI is read-only", 2) end,
  __metatable = false,
})
