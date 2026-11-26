-- EverlookDB Auctions: market hints on item tooltips, the light version. At most one quiet line, and only when it is
-- notable and there are enough days behind it:
--   "Rising   up 40% this week" / "Falling   down 30% this week": the middle of the last 3 days' daily lows against
--             the middle of those 6 to 10 days ago (ns.historyDays: your scans and the Price Feed's). Needs MIN_DAYS
--             days of lows, 2 in each window, and a change of TREND or more.
--   "Many listed   400, about 4x the usual": the newest count against a running average of the counts your own price
--             updates saw (one per day, about two weeks' worth). Needs QTY_DAYS days, QTY_X times the usual and at
--             least QTY_MIN up; the newest count must be from the last day.
-- Tooltip setting "tipmarket" (Tooltips page) turns it off. A hover costs a lookup and a 30-entry pass at most, and the
-- answer is kept for a minute per item.
-- Saved: EverlookAuctionsDB.houses[house].qty = { [item ID] = { usual count, days counted, day of the newest, newest
-- count } }, written at the end of a price update (EverlookDBAuctions.lua calls M.noteQty for each item).
local ADDON, ns = ...
local M = {}
ns.market = M

M.MIN_DAYS = 7
M.TREND = 0.25
M.QTY_DAYS = 5
M.QTY_X = 3
M.QTY_MIN = 20
M.QTY_KEEP = 14
M.KEEP_DAYS = 30
M.FRESH = 24 * 3600
M.CACHE_SECS = 60

local function median(list)
  table.sort(list)
  return list[math.floor((#list + 1) / 2)]
end

-- The week's change from daily lows ({ [day] = copper }): +0.4 is up 40%, or nil when not notable or too few days.
function M.trend(days, today)
  if type(days) ~= "table" or not today then return nil end
  local recent, earlier, n = {}, {}, 0
  for day, p in pairs(days) do
    if type(p) == "number" and p > 0 then
      local age = today - day
      if age >= 0 and age < 30 then
        n = n + 1
        if age <= 2 then recent[#recent + 1] = p
        elseif age >= 6 and age <= 10 then earlier[#earlier + 1] = p end
      end
    end
  end
  if n < M.MIN_DAYS or #recent < 2 or #earlier < 2 then return nil end
  local r, e = median(recent), median(earlier)
  if not (e and e > 0) then return nil end
  local change = r / e - 1
  if math.abs(change) < M.TREND then return nil end
  return change
end

-- One item's count at a price update: folds the day before into the running average, keeps today's newest count.
function M.noteQty(h, id, qty, day)
  if type(h) ~= "table" or not id or type(qty) ~= "number" then return end
  local all = h.qty
  if type(all) ~= "table" then all = {}; h.qty = all end
  local e = all[id]
  if type(e) ~= "table" then
    all[id] = { 0, 0, day, qty }
    return
  end
  if e[3] ~= day then
    if type(e[4]) == "number" then
      local k = math.min(e[2] or 0, M.QTY_KEEP - 1)
      e[1] = ((e[1] or 0) * k + e[4]) / (k + 1)
      e[2] = (e[2] or 0) + 1
    end
    e[3] = day
  end
  e[4] = qty
end

-- Counts not seen for KEEP_DAYS go (once a day per house).
function M.prune(h, today)
  if type(h) ~= "table" or type(h.qty) ~= "table" or h.qtyPruned == today then return end
  h.qtyPruned = today
  for id, e in pairs(h.qty) do
    if type(e) ~= "table" or (e[3] or 0) < today - M.KEEP_DAYS then h.qty[id] = nil end
  end
end

-- "Many listed": the count now against the usual one. Returns the count and the times, or nil.
function M.many(e, qty)
  if type(e) ~= "table" or type(qty) ~= "number" or (e[2] or 0) < M.QTY_DAYS then return nil end
  local usual = e[1] or 0
  if usual <= 0 or qty < M.QTY_MIN or qty < usual * M.QTY_X then return nil end
  return qty, qty / usual
end

-- The hint for an item: label, value and tone, or nil. days: daily lows; e: the count entry; it: ns.itemFor's
-- { price, count, auctions, time }.
function M.hint(days, today, e, it, now)
  if type(it) == "table" and (now or 0) - (it[4] or 0) <= M.FRESH then
    local n, x = M.many(e, it[2])
    if n then
      return "Many listed", ("%s, about %dx the usual"):format(ns.num and ns.num(n) or tostring(n), math.floor(x + 0.5)), "note"
    end
  end
  local change = M.trend(days, today)
  if change then
    local pct = math.floor(math.abs(change) * 100 + 0.5)
    if change > 0 then return "Rising", ("up %d%% this week"):format(pct), "note" end
    return "Falling", ("down %d%% this week"):format(pct), "note"
  end
end

local cache, cached = {}, 0
function M.forget() cache, cached = {}, 0 end

-- The tooltip line (EverlookTooltip's t), for your faction's house.
function M.tooltip(t, id)
  if not id or not (ns.tipOn and ns.tipOn("market")) then return end
  local clock = GetTime and GetTime() or time()
  local c = cache[id]
  if not c or clock - c.at >= M.CACHE_SECS then
    local h = ns.houseData and ns.houseData()
    local okH, label, value, tone = pcall(M.hint, ns.historyDays and ns.historyDays(id), ns.today and ns.today(),
      h and h.qty and h.qty[id], ns.itemFor and ns.itemFor(id), time())
    if not okH then label = nil end
    c = { at = clock, label = label, value = value, tone = tone }
    if cached > 2000 then M.forget() end
    cache[id] = c
    cached = cached + 1
  end
  if c.label then t:Line(c.label, c.value, { tone = c.tone }) end
end

local Tip = LibStub and LibStub("EverlookTooltip-1", true)
if Tip then
  Tip:Register({ id = "EverlookDBAuctions.market", kind = "item", order = (Tip.ORDER.history or 20) + 1,
    add = function(t, ctx) if ctx.id then M.tooltip(t, ctx.id) end end })
end
if ns.tooltipLines then ns.tooltipLines.market = M.tooltip end
