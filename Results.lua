-- EverlookDB Auctions: Your results, what your own auctions did, item by item (the numbers only; the AH log's Results
-- view in Purchases.lua draws them, and Quick sell shows one line for the picked item).
-- Read from the income ledger (Ledger.lua): every auction you posted in the period, with its outcome.
--   posted     auctions put up (not items: a stack of 20 is one auction)
--   sold, expired, cancelled; ended = sold + expired (a cancel is your own choice, so it doesn't count against the
--              item); sell rate = sold / ended
--   time to sell  from posting to the sale, only where both are known well (a sale first seen in its mail a day
--              later says nothing about how fast it went)
--   money      what the sales brought after the auction house's cut, minus the deposits lost on expired and
--              cancelled auctions
-- An item with at least MIN_ENDED auctions ended gets a plain advice line ("Keeps expiring: 6 of 8 expired. Try a
-- lower price or a longer duration."). Durations are WoW Forever's 2, 8 and 24 hours (Ledger.lua's HOURS); records
-- from before 0.35.8 that Quick sell called "12h" were 2 hour auctions all along and count as such.
local _, ns = ...
local R = {}
ns.results = R

R.DAYS = 30
R.MIN_ENDED = 3          -- fewer ended auctions: too few to tell
R.FAST = 4 * 3600        -- "sells fast": every one sold within this
R.SLACK = 1800           -- a sale seen up to this long after its auction's end still says how long it took
R.CACHE_SECS = 60        -- Quick sell's line is worked out at most once a minute

local function now_(t) return t or (time and time()) or 0 end
local function hoursOf(r)
  local L = ns.ledger
  return L and L.HOURS and L.HOURS[tonumber(r.dur) or 0] or nil
end

-- How long a sold auction took to sell (seconds), or nil when that isn't known well.
function R.sellSecs(r)
  if type(r) ~= "table" or r.st ~= "sold" or not r.t or not r.at then return nil end
  local secs = r.at - r.t
  if secs < 0 then return nil end
  local limit = (hoursOf(r) or 24) * 3600
  if secs > limit + R.SLACK then return nil end   -- known only later (its mail, the next visit)
  return math.min(secs, limit)
end

-- "40 min", "3 hours" (rounded up, for "within ..."); short: "40m", "3 h".
function R.withinText(secs, short)
  secs = tonumber(secs) or 0
  if secs < 3600 then
    local m = math.max(1, math.ceil(secs / 60 / 5) * 5)
    if m >= 60 then return short and "1 h" or "an hour" end
    return short and (m .. "m") or (m .. " min")
  end
  local h = math.ceil(secs / 3600 - 0.05)
  if short then return h .. " h" end
  return h == 1 and "an hour" or (h .. " hours")
end

-- "3h 10m", "40m": a time to sell for the list.
function R.durText(secs)
  if not secs then return "" end
  secs = math.floor(secs + 0.5)
  if secs < 3600 then return ("%dm"):format(math.max(1, math.floor(secs / 60 + 0.5))) end
  return ("%dh %02dm"):format(math.floor(secs / 3600), math.floor(secs % 3600 / 60))
end

-- The advice for one item: the sentence, a short tag for the list, and its tone ("ok", "danger", "accent", "muted").
function R.advice(e)
  local ended = e.ended or 0
  if ended < R.MIN_ENDED then
    if ended == 0 and (e.open or 0) > 0 then return nil, "Still up", "muted" end
    return nil, "Too few yet", "muted"
  end
  local sold, expired = e.sold or 0, e.expired or 0
  if sold == ended and e.maxSecs and e.timed == sold and e.maxSecs <= R.FAST then
    return ("Sells fast: %d of %d sold within %s."):format(sold, ended, R.withinText(e.maxSecs)), "Sells fast", "ok"
  end
  if sold / ended >= 0.75 then
    local within = e.avgSecs and (", usually within " .. R.withinText(e.avgSecs)) or ""
    return ("Sells well: %d of %d sold%s."):format(sold, ended, within), "Sells well", "ok"
  end
  if expired / ended >= 0.6 then
    -- mostly posted short: a longer duration may be all it needs
    local longer = (e.shortest or 3) < 3 and " or a longer duration" or ""
    return ("Keeps expiring: %d of %d expired. Try a lower price%s."):format(expired, ended, longer), "Keeps expiring", "danger"
  end
  return ("Sells sometimes: %d of %d sold."):format(sold, ended), "Sells sometimes", "accent"
end

-- Every item you posted since `since`, one entry each: { key, item, name, posted, items, sold, expired, cancelled,
-- open, ended, rate, net (after the cut), depLost, money (net - depLost), avgSecs, maxSecs, timed, last, durs,
-- advice, short, tone }. opt: { h = only this house, ch = only this character }.
function R.summary(s, since, opt)
  opt = opt or {}
  local by, list = {}, {}
  for _, r in ipairs(s and s.auctions or {}) do
    local when = r.t or r.at or 0
    local key = r.item or r.name
    if key and (not since or when >= since) and (not opt.h or not r.h or r.h == opt.h) and (not opt.ch or not r.ch or r.ch == opt.ch) then
      local e = by[key]
      if not e then
        e = { key = key, item = r.item, name = r.name, posted = 0, items = 0, sold = 0, expired = 0, cancelled = 0,
          open = 0, net = 0, depLost = 0, timed = 0, secsSum = 0, last = 0, durs = {} }
        by[key] = e
        list[#list + 1] = e
      end
      e.item, e.name = e.item or r.item, e.name or r.name
      e.link = e.link or r.link
      e.posted = e.posted + 1
      e.items = e.items + math.max(1, tonumber(r.q) or 1)
      if when > e.last then e.last = when end
      local d = tonumber(r.dur)
      if d then
        e.durs[d] = (e.durs[d] or 0) + 1
        if not e.shortest or d < e.shortest then e.shortest = d end
      end
      if r.st == "sold" then
        e.sold = e.sold + 1
        e.net = e.net + (r.net or r.est or 0)
        local secs = R.sellSecs(r)
        if secs then
          e.timed = e.timed + 1
          e.secsSum = e.secsSum + secs
          if not e.maxSecs or secs > e.maxSecs then e.maxSecs = secs end
        end
      elseif r.st == "expired" then
        e.expired = e.expired + 1
      elseif r.st == "cancelled" then
        e.cancelled = e.cancelled + 1
      else
        e.open = e.open + 1
      end
      if r.depLost and (r.dep or 0) > 0 then e.depLost = e.depLost + r.dep end
    end
  end
  for _, e in ipairs(list) do
    e.ended = e.sold + e.expired
    e.rate = e.ended > 0 and e.sold / e.ended or nil
    e.avgSecs = e.timed > 0 and e.secsSum / e.timed or nil
    e.money = e.net - e.depLost
    e.advice, e.short, e.tone = R.advice(e)
  end
  return list
end

-- Sorting the list: by "money" (default), "rate", "posted", "time", "advice" (most expired first) or "name".
local SORTS = {
  money = function(e) return e.money end,
  rate = function(e) return e.rate or -1 end,
  posted = function(e) return e.posted end,
  time = function(e) return e.avgSecs or math.huge end,
  advice = function(e) return e.ended > 0 and e.expired / e.ended or -1 end,
}
R.SORT_DESC = { money = true, rate = true, posted = true, time = false, advice = true, name = false }
function R.sort(list, by, desc)
  by = SORTS[by] and by or (by == "name" and "name") or "money"
  if desc == nil then desc = R.SORT_DESC[by] end
  local function name(e) return tostring(e.name or e.item or ""):lower() end
  table.sort(list, function(a, b)
    if by ~= "name" then
      local x, y = SORTS[by](a), SORTS[by](b)
      if x ~= y then if desc then return x > y end return x < y end
      if a.posted ~= b.posted then return a.posted > b.posted end
      return name(a) < name(b)
    end
    if desc then return name(a) > name(b) end
    return name(a) < name(b)
  end)
  return list
end

-- The totals of a summary: items, posted, sold, expired, ended, money.
function R.totals(list)
  local t = { items = #list, posted = 0, sold = 0, expired = 0, ended = 0, money = 0 }
  for _, e in ipairs(list) do
    t.posted, t.sold, t.expired = t.posted + e.posted, t.sold + e.sold, t.expired + e.expired
    t.ended, t.money = t.ended + e.ended, t.money + e.money
  end
  return t
end

-- Quick sell's line for an item on this house: "Sold 5 of 8 here, within 4 h" (the average time), or nil when none of its
-- auctions have ended in the last DAYS days. Worked out from the whole ledger at most once a minute.
local cache = { at = -1 }
function R.quickLine(s, id, house, t)
  if not s or not id then return nil end
  t = now_(t)
  if cache.s ~= s or cache.house ~= house or t - cache.at >= R.CACHE_SECS or cache.n ~= #s.auctions then
    cache.s, cache.house, cache.at, cache.n, cache.by = s, house, t, #s.auctions, {}
    for _, e in ipairs(R.summary(s, t - R.DAYS * 86400, { h = house })) do
      if e.item then cache.by[e.item] = e end
    end
  end
  local e = cache.by[id]
  if not e or e.ended == 0 then return nil end
  -- short: it sits in Quick sell's narrow line under the item's name
  if e.sold == 0 then
    return ("0 of %d sold here lately"):format(e.ended), "danger"
  end
  local within = e.avgSecs and (", within " .. R.withinText(e.avgSecs, true)) or ""
  return ("Sold %d of %d here%s"):format(e.sold, e.ended, within), e.rate >= 0.75 and "ok" or (e.rate < 0.4 and "danger" or "muted")
end
function R.forget() cache.at = -1 end

return R
