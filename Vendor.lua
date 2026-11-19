-- EverlookDB Auctions: below vendor price. An auction whose buyout per unit is less than what a vendor pays for the
-- item is free money: buy it and sell it to any vendor. Vendors take no cut, so the profit is simply the vendor price
-- minus the buyout, per unit (and times the stack size for a full stack).
--   Advanced search   `belowvendor` (or `price lt vendor`) finds them in the last full scan, sorted by profit
--   Rows              Advanced search results, the buy panel and Blizzard's own lists mark them in green
-- Items without a vendor price (sell price 0) and quest items never count. An item's vendor price needs its details
-- from the game; until they arrive the item is simply not marked, and each item is asked for at most every 30 s.

local _, ns = ...
local T = ns.T

local V = {}
ns.vendor = V

local QUEST_CLASS = 12          -- Enum.ItemClass.Questitem
local ASK_AGAIN = 30            -- seconds before an item whose details never came is asked for again

-- Search words that mean "below vendor price".
V.WORDS = { belowvendor = true, undervendor = true }

-- Profit per unit from buying at `price` (copper each) and selling to a vendor for `sell` each, or nil when there is
-- nothing to compare (no buyout, no vendor price). Negative when the auction costs more than a vendor pays.
function V.profit(price, sell)
  if not price or not sell or price <= 0 or sell <= 0 then return nil end
  return sell - price
end

-- True when the auction is cheaper than what a vendor pays.
function V.below(price, sell)
  local p = V.profit(price, sell)
  return p ~= nil and p > 0
end

-- Profit for a full stack (stack size 1 for gear).
function V.stackProfit(price, sell, stack)
  local p = V.profit(price, sell)
  if not p then return nil end
  return p * math.max(1, stack or 1)
end

-- Quest items never count. The item class is known at once (no loading); the item's category name is the fallback.
local questCache = {}
function V.isQuest(id, category)
  local q = questCache[id]
  if q ~= nil then return q end
  local fn = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
  local classID
  if fn then
    local okCall, _, _, _, _, _, cls = pcall(fn, id)
    if okCall then classID = cls end
  end
  if classID then
    q = classID == QUEST_CLASS
  elseif category ~= nil then
    local questName = GetItemClassInfo and GetItemClassInfo(QUEST_CLASS) or "Quest"
    q = category == questName
  else
    return false   -- nothing known yet: not a quest item for now, and asked again next time
  end
  questCache[id] = q
  return q
end

-- What a vendor pays for one, or nil while the game hasn't sent the item's details yet. Asks for them, but not more
-- than once every 30 seconds per item, so a long list doesn't flood the server.
local asked = {}
function V.sellOf(id)
  if not id then return nil end
  local c = ns.itemInfo and ns.itemInfo(id)
  if c then return c[9] or 0, c end
  local now = GetTime and GetTime() or 0
  if not asked[id] or now - asked[id] > ASK_AGAIN then
    asked[id] = now
    if C_Item and C_Item.RequestLoadItemDataByID then pcall(C_Item.RequestLoadItemDataByID, id) end
  end
  return nil
end

-- Profit per unit from buying item `id` at `unit` copper each and vendoring it, or nil when it isn't below vendor
-- price (or no vendor price, a quest item, or details not loaded yet).
function V.flip(id, unit)
  local sell, c = V.sellOf(id)
  if not sell or sell <= 0 or V.isQuest(id, c and c[5]) then return nil end
  local p = V.profit(unit, sell)
  if p and p > 0 then return p end
  return nil
end

---------------------------------------------------------------------------------------------------------------------
-- Deals from the full scan: every single auction under vendor price, worked out once when the scan finishes, so the
-- Below vendor list opens at once and needs no live check per row. Saved per item version as "unit:count,..."; for
-- an item whose details (vendor price) aren't loaded yet, "?" and its cheapest few auctions, checked when the list
-- is built.

V.MIN_DEAL = 1000          -- an auction must make at least 10s (for the whole auction) to be listed
local PENDING_KEEP = 10

function V.scanDeals(id, units, counts)
  if not units or #units == 0 then return nil end
  local c = ns.itemInfo and ns.itemInfo(id)   -- no load request here: Search.lua loads missing items in batches
  local sell = c and (c[9] or 0)
  if sell then
    if sell <= 0 or V.isQuest(id, c and c[5]) then return nil end
    local out = {}
    for k, u in ipairs(units) do
      if u < sell then out[#out + 1] = u .. ":" .. (counts[k] or 1) end
    end
    return #out > 0 and table.concat(out, ",") or nil
  end
  local idx = {}
  for k = 1, #units do idx[k] = k end
  table.sort(idx, function(a, b) return units[a] < units[b] end)
  local out = {}
  for k = 1, math.min(PENDING_KEEP, #idx) do out[k] = units[idx[k]] .. ":" .. (counts[idx[k]] or 1) end
  return "?" .. table.concat(out, ",")
end

-- The auctions under vendor price `sell` in a saved deals text, each { unit, count, profit } (profit for the whole
-- auction), keeping those that make at least `minProfit`; biggest profit first.
function V.dealsOf(text, sell, minProfit)
  local out = {}
  if type(text) ~= "string" or not sell or sell <= 0 then return out end
  for u, n in text:gmatch("(%d+):(%d+)") do
    u, n = tonumber(u), tonumber(n)
    if u < sell then
      local profit = (sell - u) * n
      if profit >= (minProfit or 0) then out[#out + 1] = { unit = u, count = n, profit = profit } end
    end
  end
  table.sort(out, function(a, b)
    if a.profit ~= b.profit then return a.profit > b.profit end
    return a.unit < b.unit
  end)
  return out
end

-- How many, the total profit and the cheapest unit price of a deals list.
function V.dealSummary(list)
  local n, total, best, units = 0, 0, nil, 0
  for _, d in ipairs(list or {}) do
    n, total, units = n + 1, total + d.profit, units + d.count
    if not best or d.unit < best then best = d.unit end
  end
  return n, total, best, units
end

-- Start buying (Buy.lua): what to buy next of an item from its live auctions (sorted cheapest first). Items: the
-- cheapest auction under vendor price that isn't yours. Stackable goods: how many are up under vendor price from
-- other sellers, and what they cost. nil when nothing is under vendor price any more. minProfit (copper, default 0):
-- the same bar as the list: an auction of an item must make that much, stackable goods that much together.
function V.nextDeal(rows, sell, commodity, minProfit)
  if not sell or sell <= 0 then return nil end
  minProfit = minProfit or 0
  if commodity then
    local qty, cost = 0, 0
    for _, r in ipairs(rows or {}) do
      local n = r.others or r.qty or 0
      if r.unit and r.unit < sell and n > 0 then qty, cost = qty + n, cost + n * r.unit end
    end
    if qty > 0 and qty * sell - cost >= minProfit then return { qty = qty, cost = cost } end
    return nil
  end
  for _, r in ipairs(rows or {}) do
    if not r.mine and r.unit and r.buyout and r.unit < sell and sell - r.unit >= minProfit then   -- one item per click
      return r
    end
  end
  return nil
end

-- The running total of a buying run.
function V.tally(t, qty, cost, sell)
  t = t or { n = 0, cost = 0, value = 0 }
  t.n, t.cost, t.value = t.n + qty, t.cost + cost, t.value + qty * (sell or 0)
  return t
end

function V.tallyText(t, money)
  if not t or t.n == 0 then return "Nothing bought yet." end
  return ("Bought %d for %s, vendor value %s, profit %s."):format(t.n, money(t.cost), money(t.value), money(t.value - t.cost))
end

---------------------------------------------------------------------------------------------------------------------
-- Blizzard's own lists (browse results, an item's auctions, a commodity's prices): a faint green tint and a green
-- edge on rows below vendor price. Only colors are added; the rows keep working as before.

local MARK = T.good

-- The item and unit price of a row's data, whatever list it comes from. nil for your own auctions (one auction of
-- an item, or a commodity price whose units are all yours): there's nothing to buy there.
function V.rowPrice(d)
  if type(d) ~= "table" then return nil end
  local ok = ns.ok or function(v) return v end
  local id = ok(d.itemID) or (type(d.itemKey) == "table" and ok(d.itemKey.itemID))
  local own, q = ok(d.numOwnerItems), ok(d.quantity)
  if own then
    if q and own >= q then return nil end   -- a commodity price: every unit at it is yours
  elseif ok(d.auctionID) and ok(d.containsOwnerItem) == true then
    return nil                              -- one auction of an item: yours
  end
  local unit = ok(d.unitPrice) or ok(d.minPrice)
  if not unit then
    local buy = ok(d.buyoutAmount)
    if buy then unit = buy end   -- an item row: the buyout is per item, quantity is how many are up
  end
  return id, unit
end
local rowPrice = V.rowPrice

local function markRow(row)
  if not row or (row.IsForbidden and row:IsForbidden()) then return end
  local d = row.rowData
  if d == nil and row.GetElementData then
    local okCall, data = pcall(row.GetElementData, row)
    if okCall then d = data end
  end
  local id, unit = rowPrice(d)
  local p = id and unit and V.flip(id, unit)
  local m = row.edbVendor
  if not p then
    if m then m.tint:Hide(); m.edge:Hide() end
    return
  end
  if not m then
    m = {}
    m.tint = row:CreateTexture(nil, "ARTWORK", nil, -7)
    m.tint:SetAllPoints()
    m.tint:SetColorTexture(MARK[1], MARK[2], MARK[3], 0.08)
    m.edge = row:CreateTexture(nil, "OVERLAY", nil, 7)
    m.edge:SetPoint("TOPRIGHT")
    m.edge:SetPoint("BOTTOMRIGHT")
    m.edge:SetWidth(3)
    m.edge:SetColorTexture(MARK[1], MARK[2], MARK[3], 0.9)
    row.edbVendor = m
  end
  m.tint:Show()
  m.edge:Show()
end

local function lists()
  local ah = _G.AuctionHouseFrame
  if not ah then return {} end
  local out = {}
  for _, holder in ipairs({ ah.BrowseResultsFrame, ah.ItemBuyFrame, ah.CommoditiesBuyFrame }) do
    local sb = holder and holder.ItemList and holder.ItemList.ScrollBox
    if sb then out[#out + 1] = sb end
  end
  return out
end

local function markAll()
  for _, sb in ipairs(lists()) do
    if sb.ForEachFrame then pcall(sb.ForEachFrame, sb, markRow) end
  end
end
V.markAll = function() pcall(markAll) end

local hooked = setmetatable({}, { __mode = "k" })
local function hookLists()
  for _, sb in ipairs(lists()) do
    if not hooked[sb] and sb.Update then
      hooked[sb] = true
      hooksecurefunc(sb, "Update", function() pcall(markAll) end)
    end
  end
end

-- Item details arriving can turn on marks; gather them into one refresh a moment later.
local soon = false
local function refreshSoon()
  if soon then return end
  soon = true
  C_Timer.After(0.3, function()
    soon = false
    V.markAll()
    if ns.buyRefresh then ns.buyRefresh() end
  end)
end

local ev = CreateFrame("Frame")
for _, e in ipairs({ "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED", "AUCTION_HOUSE_BROWSE_RESULTS_ADDED",
    "ITEM_SEARCH_RESULTS_UPDATED", "COMMODITY_SEARCH_RESULTS_UPDATED", "GET_ITEM_INFO_RECEIVED" }) do
  pcall(ev.RegisterEvent, ev, e)
end
ev:SetScript("OnEvent", function(_, e)
  if e == "GET_ITEM_INFO_RECEIVED" then
    if _G.AuctionHouseFrame and AuctionHouseFrame:IsShown() then refreshSoon() end
    return
  end
  if e == "AUCTION_HOUSE_SHOW" then C_Timer.After(0.5, function() pcall(hookLists) end) end
  pcall(hookLists)
  C_Timer.After(0, V.markAll)
end)
