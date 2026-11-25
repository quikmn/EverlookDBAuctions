-- EverlookDB Auctions: the Gold page of the main window, and the Home card's gold line.
--   Gold per day   one point per character per day (its gold at login, at logout and whenever it changes; the newest
--                  of the day counts), kept for good. A line chart of all characters on this auction house (this realm
--                  and faction), the total or each character, over 7 days, 30 days or everything kept.
--   This week and last week   income by kind and costs by kind from the income ledger (Ledger.lua) and the AH
--                  purchases log (PurchaseLog.lua), Monday to Sunday, and the net.
--   Best sellers, biggest buys, flips (your average buy against your average sell), and the money in your listings.
--   Export         the lists as CSV in a box to copy.
-- Saved per account in EverlookAuctionsDB.goldDays = { v, chars = { ["Name-<realm ID>"] (Inventory.lua's key) = {
--   name, class, realm, realmID, faction, last (day), d = { [YYYYMMDD] = copper } } } }: a few bytes per character per
--   day it logs in. Values the game hides (secret values) are never written. Nothing here runs per frame: a sample
--   waits for the money to settle (one per burst), the page draws when it is shown or the gold changes.
local ADDON, ns = ...

local G = {}
ns.gold = G

G.VERSION = 1
G.MAX_POINTS = 92      -- points on the chart (a long range shows every few days)
G.TOP = 8              -- rows in each list
G.RANGES = { { id = "7", days = 7, label = "7 days" }, { id = "30", days = 30, label = "30 days" }, { id = "all", label = "All" } }

-- the week's rows: income, then costs (AH sales before the cut; the cut is a cost of its own)
G.INCOME = {
  { "sale", "AH sales" }, { "vendor", "Vendor sales" }, { "loot", "Looted coins" }, { "quest", "Quest gold" },
  { "player", "Mail from others" }, { "npc", "NPC mail" },
}
G.COSTS = {
  { "bought", "AH purchases" }, { "cut", "AH cuts" }, { "deposit", "Deposits lost" }, { "repair", "Repairs" },
  { "vendorbuy", "Vendor buys" }, { "training", "Training" }, { "cod", "C.O.D. paid" },
}

local isSecret = issecretvalue or function() return false end
local function ok(v)
  if v == nil or isSecret(v) then return nil end
  return v
end
local function try(fn, ...)
  if type(fn) ~= "function" then return nil end
  local res, a, b = pcall(fn, ...)
  if res then return ok(a), ok(b) end
end
local function now_(t) return t or (time and time()) or 0 end
local function db() return ns.db and ns.db() end
local function money(c) return ns.money and ns.money(c) or tostring(c) end

---------------------------------------------------------------------------------------------------------------------
-- The store and the days

function G.store(d)
  d = d or db()
  if type(d) ~= "table" then return nil end
  local s = d.goldDays
  if type(s) ~= "table" then s = { v = G.VERSION, chars = {} }; d.goldDays = s end
  if type(s.chars) ~= "table" then s.chars = {} end
  return s
end

-- 20261125 for a time on 25 November 2026 (local time)
function G.dayKey(t) return tonumber(date("%Y%m%d", now_(t))) end
-- noon of a day key (noon: a day plus or minus a day never trips over a clock change)
function G.dayTime(k)
  return time({ year = math.floor(k / 10000), month = math.floor(k / 100) % 100, day = k % 100, hour = 12, min = 0, sec = 0 })
end
function G.addDays(k, n)
  local d = date("*t", G.dayTime(k))
  return G.dayKey(time({ year = d.year, month = d.month, day = d.day + n, hour = 12, min = 0, sec = 0 }))
end

-- A character's gold today: one point per day, the newest sample wins. info = { name, class, realm, realmID, faction }.
function G.note(s, key, info, c, t)
  c = tonumber(ok(c))
  if not s or type(key) ~= "string" or key == "" or not c or c < 0 then return nil end
  local e = s.chars[key]
  if type(e) ~= "table" then e = {}; s.chars[key] = e end
  if type(e.d) ~= "table" then e.d = {} end
  for _, k in ipairs({ "name", "class", "realm", "realmID", "faction" }) do
    local v = info and ok(info[k])
    if v ~= nil then e[k] = v end
  end
  local day = G.dayKey(t)
  e.d[day] = math.floor(c)
  e.last = day
  return day
end

-- This character's Inventory record and key (its name, realm and faction).
local function meRec()
  local I = ns.inventory
  if not I or not I.store then return nil end
  local key = I.meKey()
  local s = I.store()
  return key and s and s.chars[key], key
end

-- Reads this character's gold and writes today's point. True when written.
function G.sample(t)
  local c = tonumber(try(GetMoney))
  if not c then return false end
  local s = G.store()
  local rec, key = meRec()
  if not s or not key then return false end
  local info = rec or {}
  if not info.name then
    local name = try(UnitName, "player")
    info = { name = type(name) == "string" and name or nil }
  end
  return G.note(s, key, info, c, t) ~= nil
end

-- The characters on this auction house with any points: { { key, name, class, rec, me } }, you first, then by name.
function G.chars(s, me, meKey)
  local I = ns.inventory
  local out = {}
  for key, e in pairs(s and s.chars or {}) do
    if type(e) == "table" and type(e.d) == "table" and next(e.d) and (not (I and I.sameHouse) or I.sameHouse(e, me)) then
      out[#out + 1] = { key = key, name = e.name or key:match("^[^-]+") or key, class = e.class, rec = e, me = key == meKey }
    end
  end
  table.sort(out, function(a, b)
    if a.me ~= b.me then return a.me end
    return tostring(a.name) < tostring(b.name)
  end)
  return out
end

-- The chart's numbers: days (keys, oldest first), total[i], per[key][i] (a character's gold on that day: its last
-- point on or before it, nil before its first). days: how many days back (nil: from the first point). Long ranges
-- are thinned to MAX_POINTS (today always in).
function G.series(chars, days, t)
  local today = G.dayKey(t)
  local first
  if days then
    first = G.addDays(today, -(days - 1))
  else
    for _, c in ipairs(chars) do
      for d in pairs(c.rec.d) do if not first or d < first then first = d end end
    end
  end
  if not first then return nil end
  if first > today then first = today end
  local list, k = {}, first
  while k <= today and #list < 20000 do
    list[#list + 1] = k
    k = G.addDays(k, 1)
  end
  if #list > G.MAX_POINTS then
    local step = math.ceil(#list / G.MAX_POINTS)
    local thin = {}
    for i = #list, 1, -step do table.insert(thin, 1, list[i]) end
    list = thin
  end
  local per, total = {}, {}
  for _, c in ipairs(chars) do
    local keys = {}
    for d in pairs(c.rec.d) do keys[#keys + 1] = d end
    table.sort(keys)
    local vals, j, last = {}, 1, nil
    for i, day in ipairs(list) do
      while keys[j] and keys[j] <= day do last = c.rec.d[keys[j]]; j = j + 1 end
      vals[i] = last
      if last then total[i] = (total[i] or 0) + last end
    end
    per[c.key] = vals
  end
  return { days = list, total = total, per = per, n = #list }
end

-- The first and last known value of a line, and their difference.
function G.change(vals, n)
  local a, b
  for i = 1, n or #vals do
    local v = vals[i]
    if v then a = a or v; b = v end
  end
  if not a then return nil end
  return b - a, a, b
end

---------------------------------------------------------------------------------------------------------------------
-- Weeks: income and costs

-- Monday 00:00 of the week t is in (local time).
function G.weekStart(t)
  local d = date("*t", now_(t))
  local back = (d.wday + 5) % 7   -- wday: 1 Sunday ... 7 Saturday
  return time({ year = d.year, month = d.month, day = d.day - back, hour = 0, min = 0, sec = 0 })
end

-- Sums from the ledger's money and the purchases log between from (in) and to (out); nil: no bound. AH sales are
-- before the cut and the cut is a cost, so the net is what came in: { [kind] = copper, income, cost, net, unsorted }.
function G.sums(s, bought, from, to)
  local out = { income = 0, cost = 0, unsorted = 0, n = 0 }
  for _, d in ipairs(G.INCOME) do out[d[1]] = 0 end
  for _, d in ipairs(G.COSTS) do out[d[1]] = 0 end
  local function inside(t)
    t = tonumber(t) or 0
    return (not from or t >= from) and (not to or t < to)
  end
  for _, e in ipairs(s and s.money or {}) do
    if type(e) == "table" and inside(e.t) then
      local c = tonumber(e.c) or 0
      if e.cat == "sale" then
        local cut = tonumber(e.cut) or 0
        out.sale = out.sale + c + cut
        out.cut = out.cut + cut
      elseif e.cat == "unsorted" then
        out.unsorted = out.unsorted + c
        out.n = out.n + 1
      elseif out[e.cat] and e.cat ~= "income" and e.cat ~= "cost" and e.cat ~= "n" then
        out[e.cat] = out[e.cat] + c
      end
    end
  end
  for _, e in ipairs(bought or {}) do
    if type(e) == "table" and inside(e.t) then out.bought = out.bought + (tonumber(e.c) or 0) end
  end
  for _, d in ipairs(G.INCOME) do out.income = out.income + out[d[1]] end
  for _, d in ipairs(G.COSTS) do out.cost = out.cost + out[d[1]] end
  out.net = out.income - out.cost
  return out
end

-- This week and last week.
function G.weeks(s, bought, t)
  local w = G.weekStart(t)
  local d = date("*t", w)
  local prev = time({ year = d.year, month = d.month, day = d.day - 7, hour = 0, min = 0, sec = 0 })
  return G.sums(s, bought, w, nil), G.sums(s, bought, prev, w), w, prev
end

---------------------------------------------------------------------------------------------------------------------
-- Items: averages, best sellers, biggest buys, flips, listings

local function itemName(id, name)
  if name then return name end
  if id and C_Item and C_Item.GetItemNameByID then
    local n = try(C_Item.GetItemNameByID, id)
    if type(n) == "string" then return n end
  end
  return id and ("item " .. id) or "?"
end
G.itemName = itemName

-- Your averages per item at this auction house (as avgbuy and avgsell in Advanced search): what you paid for one
-- (the purchases log) and what one sold for before the cut (the ledger's sold auctions).
-- { buy = { [id] = copper }, sell = { [id] = copper }, bq = { [id] = n }, sq = { [id] = n } }
function G.averages(d, s, house)
  local bc, bq, sc, sq = {}, {}, {}, {}
  for _, e in ipairs(d and d.bought or {}) do
    if type(e) == "table" and e.id and (e.q or 0) > 0 and (e.c or 0) > 0 and (not house or not e.h or e.h == house) then
      bc[e.id], bq[e.id] = (bc[e.id] or 0) + e.c, (bq[e.id] or 0) + e.q
    end
  end
  for _, r in ipairs(s and s.auctions or {}) do
    local gross = r.gross or (r.st == "sold" and r.buy) or nil
    if r.st == "sold" and r.item and (r.q or 0) > 0 and (gross or 0) > 0 and (not house or not r.h or r.h == house) then
      sc[r.item], sq[r.item] = (sc[r.item] or 0) + gross, (sq[r.item] or 0) + r.q
    end
  end
  local out = { buy = {}, sell = {}, bq = bq, sq = sq }
  for id, c in pairs(bc) do out.buy[id] = math.floor(c / bq[id] + 0.5) end
  for id, c in pairs(sc) do out.sell[id] = math.floor(c / sq[id] + 0.5) end
  return out
end

-- Your sales since a time, per item: { id, name, sold (items), n (auctions), expired, gross, money (after the cut),
-- cost (what the sold ones cost you at your average buy, when you bought that item), profit, avg (one, before the
-- cut) }; sorted by profit, and a copy sorted by how many sold.
function G.sellers(s, avg, since)
  local by, list = {}, {}
  for _, r in ipairs(s and s.auctions or {}) do
    if (r.st == "sold" or r.st == "expired" or r.st == "cancelled") and (not since or (r.at or 0) >= since) then
      local key = r.item or r.name
      if key then
        local e = by[key]
        if not e then
          e = { id = r.item, name = r.name, sold = 0, n = 0, expired = 0, gross = 0, money = 0, cost = 0 }
          by[key] = e
          list[#list + 1] = e
        end
        e.name = e.name or r.name
        if r.st == "sold" then
          local q = r.q or 1
          e.sold, e.n = e.sold + q, e.n + 1
          e.gross = e.gross + (r.gross or r.buy or 0)
          e.money = e.money + (r.net or r.est or 0)
          local paid = r.item and avg and avg.buy[r.item]
          if paid then e.cost, e.bought = e.cost + paid * q, true end
        elseif r.st == "expired" then
          e.expired = e.expired + 1
        end
      end
    end
  end
  local out = {}
  for _, e in ipairs(list) do
    if e.n > 0 then
      e.profit = e.money - e.cost
      e.avg = e.sold > 0 and math.floor(e.gross / e.sold + 0.5) or 0
      out[#out + 1] = e
    end
  end
  table.sort(out, function(a, b)
    if a.profit ~= b.profit then return a.profit > b.profit end
    return tostring(a.name) < tostring(b.name)
  end)
  local byCount = {}
  for i, e in ipairs(out) do byCount[i] = e end
  table.sort(byCount, function(a, b)
    if a.sold ~= b.sold then return a.sold > b.sold end
    return a.profit > b.profit
  end)
  return out, byCount
end

-- The biggest single purchases since a time, most first.
function G.biggestBuys(bought, since)
  local out = {}
  for _, e in ipairs(bought or {}) do
    if type(e) == "table" and (e.c or 0) > 0 and (not since or (e.t or 0) >= since) then out[#out + 1] = e end
  end
  table.sort(out, function(a, b)
    if a.c ~= b.c then return a.c > b.c end
    return (a.t or 0) > (b.t or 0)
  end)
  return out
end

-- Items you have both bought and sold: { id, buy, sell, margin (one sold after the cut, less one bought), bq, sq },
-- the best margin first.
function G.flips(avg, cut)
  cut = cut or 0.05
  local out = {}
  for id, b in pairs(avg and avg.buy or {}) do
    local sv = avg.sell[id]
    if sv then
      out[#out + 1] = { id = id, buy = b, sell = sv, margin = math.floor(sv * (1 - cut) - b + 0.5), bq = avg.bq[id], sq = avg.sq[id] }
    end
  end
  table.sort(out, function(a, b)
    if a.margin ~= b.margin then return a.margin > b.margin end
    return a.id < b.id
  end)
  return out
end

-- Money in your listings (every character's auctions still up): copper at buyout, how many auctions.
function G.listed(s)
  local c, n = 0, 0
  for _, r in ipairs(s and s.auctions or {}) do
    if r.st == "listed" then
      n = n + 1
      c = c + (r.buy or ((r.unit or 0) * (r.q or 1)))
    end
  end
  return c, n
end

---------------------------------------------------------------------------------------------------------------------
-- CSV

local function gold(c) -- 12.3456 (gold with the copper)
  if not c then return "" end
  local s = ("%.4f"):format(c / 10000):gsub("0+$", ""):gsub("%.$", "")
  return s
end
G.goldNumber = gold
local function cell(v)
  v = tostring(v == nil and "" or v)
  if v:find('[,"\n]') then v = '"' .. v:gsub('"', '""') .. '"' end
  return v
end
local function row(t)
  local out = {}
  for i = 1, #t do out[i] = cell(t[i]) end
  return table.concat(out, ",")
end
G.csvRow = row

function G.csvDays(ser, chars)
  if not ser then return "" end
  local head = { "date", "total_gold" }
  for _, c in ipairs(chars) do head[#head + 1] = c.name end
  local lines = { row(head) }
  for i, k in ipairs(ser.days) do
    local r = { ("%04d-%02d-%02d"):format(math.floor(k / 10000), math.floor(k / 100) % 100, k % 100), gold(ser.total[i]) }
    for _, c in ipairs(chars) do r[#r + 1] = gold(ser.per[c.key] and ser.per[c.key][i]) end
    lines[#lines + 1] = row(r)
  end
  return table.concat(lines, "\n")
end

function G.csvWeeks(this, last)
  local lines = { row({ "kind", "group", "this_week_gold", "last_week_gold" }) }
  for _, d in ipairs(G.INCOME) do lines[#lines + 1] = row({ d[2], "income", gold(this[d[1]]), gold(last[d[1]]) }) end
  for _, d in ipairs(G.COSTS) do lines[#lines + 1] = row({ d[2], "cost", gold(this[d[1]]), gold(last[d[1]]) }) end
  lines[#lines + 1] = row({ "Income", "total", gold(this.income), gold(last.income) })
  lines[#lines + 1] = row({ "Costs", "total", gold(this.cost), gold(last.cost) })
  lines[#lines + 1] = row({ "Net", "total", gold(this.net), gold(last.net) })
  return table.concat(lines, "\n")
end

function G.csvSellers(list)
  local lines = { row({ "item", "item_id", "sold", "auctions", "expired", "avg_price_gold", "after_cut_gold", "paid_gold", "profit_gold" }) }
  for _, e in ipairs(list or {}) do
    lines[#lines + 1] = row({ itemName(e.id, e.name), e.id or "", e.sold, e.n, e.expired, gold(e.avg), gold(e.money),
      e.bought and gold(e.cost) or "", gold(e.profit) })
  end
  return table.concat(lines, "\n")
end

function G.csvFlips(list)
  local lines = { row({ "item", "item_id", "avg_buy_gold", "avg_sell_gold", "margin_gold", "bought", "sold" }) }
  for _, e in ipairs(list or {}) do
    lines[#lines + 1] = row({ itemName(e.id), e.id, gold(e.buy), gold(e.sell), gold(e.margin), e.bq or 0, e.sq or 0 })
  end
  return table.concat(lines, "\n")
end

---------------------------------------------------------------------------------------------------------------------
-- Words

-- "1,234g" for the chart's axis (no silver or copper)
function G.short(c)
  c = math.floor((c or 0) / 10000 + 0.5)
  return (ns.num and ns.num(c) or tostring(c)) .. "g"
end
-- "+12g 30s" / "-5g"
function G.signed(c)
  if not c then return "" end
  if c < 0 then return "-" .. money(-c) end
  return "+" .. money(c)
end

-- "12g" from 1 gold up, else "56s 20c": for one-line summaries
function G.brief(c)
  c = c or 0
  if math.abs(c) >= 10000 then return (c < 0 and "-" or "") .. G.short(math.abs(c)) end
  return c < 0 and ("-" .. money(-c)) or money(c)
end
function G.briefSigned(c)
  if not c then return "" end
  return (c < 0 and "" or "+") .. G.brief(c)
end

-- Home's card: "Gold on 3 characters: 1,234g 5s  ·  +56g this week" and "This week: income 80g, costs 24g, net +56g".
function G.homeLines(t)
  t = now_(t)
  local s = G.store()
  local me, meKey = meRec()
  local chars = s and G.chars(s, me, meKey) or {}
  local l1
  if #chars > 0 then
    local ser = G.series(chars, 7, t)
    local total = ser and ser.total[ser.n]
    local diff = ser and G.change(ser.total, ser.n)
    l1 = ("All characters %s"):format(money(total or 0))
    if diff and diff ~= 0 then l1 = l1 .. ("  \194\183  %s in 7 days"):format(G.signed(diff)) end
  end
  local LG = ns.ledger
  local led = LG and LG.get and LG.get()
  local d = db() or {}
  local l2
  if led then
    local this = G.weeks(led, d.bought, t)
    -- whole gold once it is a gold or more, so the line fits Home's card (11g 86s 42c three times did not)
    l2 = ("This week: income %s, costs %s, net %s"):format(G.brief(this.income), G.brief(this.cost), G.briefSigned(this.net))
  end
  return l1, l2
end

---------------------------------------------------------------------------------------------------------------------
-- The page

local page = { range = "30", mode = "total", export = "days" }
G.pageState = page
local EUI, T

local function rgba(c) return c[1], c[2], c[3], c[4] or 1 end
local function hexOf(c) return ("%02x%02x%02x"):format(math.floor(c[1] * 255 + 0.5), math.floor(c[2] * 255 + 0.5), math.floor(c[3] * 255 + 0.5)) end

local function rangeDays()
  for _, r in ipairs(G.RANGES) do if r.id == page.range then return r.days end end
end
local function rangeSince(t)
  local days = rangeDays()
  if not days then return nil end
  return G.dayTime(G.addDays(G.dayKey(t), -(days - 1))) - 12 * 3600
end
local function rangeWords()
  local days = rangeDays()
  return days and ("the last %d days"):format(days) or "everything kept"
end

local PALETTE = {
  { 0.353, 0.663, 1.0 }, { 0.961, 0.776, 0.341 }, { 0.384, 0.812, 0.533 }, { 0.937, 0.365, 0.365 },
  { 0.70, 0.52, 0.95 }, { 0.30, 0.82, 0.82 }, { 0.95, 0.55, 0.25 }, { 0.85, 0.85, 0.85 },
}
local function charColor(c, i)
  local cc = c.class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[c.class]
  if cc then return { cc.r, cc.g, cc.b, 1 } end
  return PALETTE[((i - 1) % #PALETTE) + 1]
end

-- Everything the page shows, worked out once per refresh.
function G.compute(t)
  t = now_(t)
  local d = db() or {}
  local s = G.store(d)
  local me, meKey = meRec()
  page.chars = s and G.chars(s, me, meKey) or {}
  page.series = G.series(page.chars, rangeDays(), t)
  local LG = ns.ledger
  local led = LG and LG.get and LG.get()
  page.ledger = led
  page.this, page.last = G.weeks(led, d.bought, t)
  local house = (ns.house and ns.house()) or (ns.houseOrFaction and ns.houseOrFaction())
  page.avg = G.averages(d, led, house)
  local since = rangeSince(t)
  page.byProfit, page.byCount = G.sellers(led, page.avg, since)
  page.buys = G.biggestBuys(d.bought, since)
  page.flips = G.flips(page.avg, ns.ahCut and ns.ahCut() or 0.05)
  page.listedC, page.listedN = G.listed(led)
  page.at = t
  return page
end

-- The lines the chart draws: { { vals, color, name } }
local function chartLines()
  local ser = page.series
  if not ser then return {} end
  if page.mode == "total" then return { { vals = ser.total, color = T.accent, name = "All characters" } } end
  local out = {}
  for i, c in ipairs(page.chars) do
    out[#out + 1] = { vals = ser.per[c.key] or {}, color = charColor(c, i), name = c.me and (c.name .. " (you)") or c.name }
  end
  return out
end

local CHART_H, LEFT, BOTTOM = 210, 64, 22
local function dayLabel(k) return date("%b %d", G.dayTime(k)) end

local function drawChart(f)
  local U = EUI.Util
  local w = (f:GetWidth() or 0)
  if w <= 1 then w = f.stackWidth or 600 end
  local pw, ph = w - LEFT - 10, CHART_H - BOTTOM - 10
  if pw < 40 then return end
  f.plot:SetSize(pw, ph)
  for _, l in ipairs(f.lines) do l:Hide() end
  for _, d in ipairs(f.dots) do d:Hide() end
  for _, b in ipairs(f.hits) do b:Hide() end
  for _, g in ipairs(f.grid) do g.line:Hide(); g.label:Hide() end
  for _, x in ipairs(f.xlabels) do x:Hide() end
  f.hover:Hide()
  local ser = page.series
  local lines = chartLines()
  f.drawn = nil
  local lo, hi
  for _, ln in ipairs(lines) do
    for i = 1, ser and ser.n or 0 do
      local v = ln.vals[i]
      if v then lo, hi = math.min(lo or v, v), math.max(hi or v, v) end
    end
  end
  if not lo then
    f.empty:SetText("No gold days yet. Each character adds one point a day when it logs in and whenever its gold changes.")
    f.empty:Show()
    return
  end
  f.empty:Hide()
  local span = hi - lo
  if span <= 0 then span = math.max(10000, hi * 0.1) end
  lo, hi = math.max(0, lo - span * 0.15), hi + span * 0.15
  local n = ser.n
  local function X(i) return n == 1 and pw / 2 or (i - 1) / (n - 1) * pw end
  local function Y(v) return (v - lo) / (hi - lo) * ph end
  -- the grid: four lines with their gold on the left
  for gi = 1, 4 do
    local g = f.grid[gi]
    if not g then
      g = { line = U.Solid(f.plot, "BACKGROUND", rgba(T.divider)), label = EUI.Text(f, T.fontSmall, T.muted) }
      g.label:SetJustifyH("RIGHT")
      g.label:SetWidth(LEFT - 8)
      f.grid[gi] = g
    end
    local frac = (gi - 1) / 3
    local y = frac * ph
    g.line:ClearAllPoints()
    g.line:SetPoint("BOTTOMLEFT", f.plot, "BOTTOMLEFT", 0, y)
    g.line:SetSize(pw, 1)
    g.line:Show()
    g.label:ClearAllPoints()
    g.label:SetPoint("RIGHT", f.plot, "BOTTOMLEFT", -8, y)
    g.label:SetText(G.short(lo + frac * (hi - lo)))
    g.label:Show()
  end
  -- three dates under it
  local marks = n == 1 and { 1 } or (n == 2 and { 1, 2 } or { 1, math.floor((n + 1) / 2), n })
  for xi, i in ipairs(marks) do
    local x = f.xlabels[xi]
    if not x then x = EUI.Text(f, T.fontSmall, T.muted); f.xlabels[xi] = x end
    x:ClearAllPoints()
    x:SetPoint("TOP", f.plot, "BOTTOMLEFT", X(i), -6)
    x:SetText(dayLabel(ser.days[i]))
    x:Show()
  end
  -- the lines (a dot on each day when there are few)
  local li, di = 0, 0
  local canLine = f.plot.CreateLine ~= nil and not f.noLines
  local dots = n <= 31 or not canLine
  for _, ln in ipairs(lines) do
    local r, g, b = ln.color[1], ln.color[2], ln.color[3]
    local px, py
    for i = 1, n do
      local v = ln.vals[i]
      if v then
        local x, y = X(i), Y(v)
        if px and canLine then
          local l = f.lines[li + 1]
          if not l then
            l = f.plot:CreateLine(nil, "ARTWORK")
            if l then
              if l.SetThickness then l:SetThickness(2) end
              f.lines[li + 1] = l
            else
              f.noLines, canLine, dots = true, false, true   -- no lines in this client: dots only
            end
          end
          if l then
            li = li + 1
            l:SetColorTexture(r, g, b, 1)
            l:SetStartPoint("BOTTOMLEFT", f.plot, px, py)
            l:SetEndPoint("BOTTOMLEFT", f.plot, x, y)
            l:Show()
          end
        end
        if dots then
          di = di + 1
          local d = f.dots[di]
          if not d then d = f.plot:CreateTexture(nil, "OVERLAY"); d:SetTexture(U.WHITE); d:SetSize(4, 4); f.dots[di] = d end
          d:SetVertexColor(r, g, b, 1)
          d:ClearAllPoints()
          d:SetPoint("CENTER", f.plot, "BOTTOMLEFT", x, y)
          d:Show()
        end
        px, py = x, y
      else
        px, py = nil, nil
      end
    end
  end
  f.drawn = { points = n, lines = li, dots = di, lo = lo, hi = hi }
  -- hover: one invisible column per day, its tooltip says the day's gold
  local colW = n == 1 and pw or pw / (n - 1)
  for i = 1, n do
    local b = f.hits[i]
    if not b then
      b = CreateFrame("Button", nil, f.plot)
      b:SetScript("OnEnter", function(self)
        local k = page.series and page.series.days[self.index]
        if not k then return end
        f.hover:ClearAllPoints()
        f.hover:SetPoint("BOTTOM", f.plot, "BOTTOMLEFT", self.x, 0)
        f.hover:SetSize(1, f.plot:GetHeight() or ph)
        f.hover:Show()
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(date("%A %d %B %Y", G.dayTime(k)), 1, 0.82, 0)
        local tot = page.series.total[self.index]
        if tot then GameTooltip:AddDoubleLine("All characters", money(tot), 1, 1, 1, 1, 1, 1) end
        for ci, c in ipairs(page.chars) do
          local v = page.series.per[c.key] and page.series.per[c.key][self.index]
          if v then
            local col = charColor(c, ci)
            GameTooltip:AddDoubleLine(c.name, money(v), col[1], col[2], col[3], 0.9, 0.9, 0.9)
          end
        end
        GameTooltip:Show()
      end)
      b:SetScript("OnLeave", function() f.hover:Hide(); GameTooltip:Hide() end)
      f.hits[i] = b
    end
    b.index, b.x = i, X(i)
    b:ClearAllPoints()
    b:SetPoint("BOTTOM", f.plot, "BOTTOMLEFT", X(i), 0)
    b:SetSize(math.max(2, colW), ph)
    b:Show()
  end
end

local function buildChart(stack)
  local f = CreateFrame("Frame")
  f:SetParent(stack.parent)
  f.lines, f.dots, f.hits, f.grid, f.xlabels = {}, {}, {}, {}, {}
  f.stackWidth = stack.width
  f.plot = CreateFrame("Frame", nil, f)
  f.plot:SetPoint("TOPLEFT", f, "TOPLEFT", LEFT, -10)
  f.hover = f.plot:CreateTexture(nil, "OVERLAY")
  f.hover:SetTexture(EUI.Util.WHITE)
  f.hover:SetVertexColor(rgba(T.muted))
  f.hover:SetAlpha(0.5)
  f.hover:Hide()
  f.empty = EUI.Text(f, T.font, T.muted)
  f.empty:SetPoint("CENTER", 0, 0)
  f.empty:Hide()
  function f:Refresh()
    local okD, err = pcall(drawChart, f)
    f.drawError = not okD and tostring(err) or false
  end
  f:SetScript("OnSizeChanged", function(self) self:Refresh() end)
  stack:Add(f, CHART_H, 8)
  f:Refresh()
  return f
end

-- The week table: a label and two columns of money, one row per kind.
local ROW_H = 17
local function buildWeeks(stack)
  local f = CreateFrame("Frame")
  f:SetParent(stack.parent)
  f.rows = {}
  local rows = { { head = true } }
  for _, d in ipairs(G.INCOME) do rows[#rows + 1] = { key = d[1], label = d[2] } end
  rows[#rows + 1] = { key = "income", label = "Income", bold = true, color = T.ok }
  for _, d in ipairs(G.COSTS) do rows[#rows + 1] = { key = d[1], label = d[2], cost = true } end
  rows[#rows + 1] = { key = "cost", label = "Costs", bold = true, cost = true, color = T.danger }
  rows[#rows + 1] = { key = "net", label = "Net", bold = true, net = true }
  for i, r in ipairs(rows) do
    local y = -(i - 1) * ROW_H
    local l = EUI.Text(f, r.bold and T.font or T.font - 1, r.head and T.muted or (r.bold and T.text or T.muted))
    l:SetPoint("TOPLEFT", 0, y)
    l:SetWidth(200)
    l:SetText(r.head and "" or r.label)
    local a = EUI.Text(f, T.font - (r.bold and 0 or 1), T.text)
    a:SetJustifyH("RIGHT")
    a:SetWidth(130)
    a:SetPoint("TOPLEFT", 210, y)
    local b = EUI.Text(f, T.font - (r.bold and 0 or 1), T.text)
    b:SetJustifyH("RIGHT")
    b:SetWidth(130)
    b:SetPoint("TOPLEFT", 350, y)
    if r.head then
      a:SetText("THIS WEEK"); b:SetText("LAST WEEK")
      a:SetTextColor(rgba(T.muted)); b:SetTextColor(rgba(T.muted))
    end
    f.rows[i] = { def = r, label = l, a = a, b = b }
  end
  function f:Refresh()
    local this, last = page.this, page.last
    if not this then return end
    for _, rw in ipairs(f.rows) do
      local r = rw.def
      if not r.head then
        for _, pair in ipairs({ { rw.a, this }, { rw.b, last } }) do
          local fs, sum = pair[1], pair[2]
          local v = sum[r.key] or 0
          if r.net then
            fs:SetText(G.signed(v))
            fs:SetTextColor(rgba(v >= 0 and T.ok or T.danger))
          elseif v == 0 then
            fs:SetText("-")
            fs:SetTextColor(rgba(T.muted))
          else
            fs:SetText(r.cost and ("-" .. money(v)) or money(v))
            fs:SetTextColor(rgba(r.color or (r.cost and T.danger) or T.text))
          end
        end
      end
    end
  end
  stack:Add(f, #rows * ROW_H + 4, 8)
  f:Refresh()
  return f
end

-- A box of CSV to copy (several lines).
local function buildExport(stack)
  local f = CreateFrame("Frame")
  f:SetParent(stack.parent)
  local area = EUI.TextArea(f, stack.width, 110)
  area:SetPoint("TOPLEFT")
  area:SetPoint("RIGHT")
  f.area = area
  local function value()
    if page.export == "weeks" then return page.this and G.csvWeeks(page.this, page.last) or "" end
    if page.export == "sellers" then return G.csvSellers(page.byProfit) end
    if page.export == "flips" then return G.csvFlips(page.flips) end
    return G.csvDays(page.series, page.chars)
  end
  -- read only: any typing puts the text back
  area.box:SetScript("OnTextChanged", function(self, user)
    if user then self:SetText(value()); self:HighlightText() end
  end)
  area.box:HookScript("OnEditFocusGained", function(self) self:HighlightText() end)
  function f:Refresh() area.box:SetText(value()) end
  stack:Add(f, 110, 8)
  f:Refresh()
  return f
end

local function refreshPage()
  if not page.stack then return end
  pcall(G.compute)
  page.stack:RefreshAll()
end
G.refreshPage = refreshPage

local function qualityColor(id)
  local q = id and C_Item and C_Item.GetItemQualityByID and try(C_Item.GetItemQualityByID, id)
  local c = q and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q]
  if c then return { c.r, c.g, c.b, 1 } end
end
local function itemIcon(id) return id and C_Item and C_Item.GetItemIconByID and try(C_Item.GetItemIconByID, id) or nil end
local function itemTip(id, row)
  if not id then return end
  if ns.itemTooltip then ns.itemTooltip(row, id) else
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT"); GameTooltip:SetItemByID(id); GameTooltip:Show()
  end
end

-- One row of plain buttons; the picked one has its label in the accent colour (the page has no gold button).
local function choiceRow(stack, choices, get, set, extra)
  local defs = {}
  for i, c in ipairs(choices) do
    defs[i] = { label = c.label, width = c.width or 96, desc = c.desc, onClick = function() set(c.id, c.group); refreshPage() end }
  end
  defs.keywords = extra and extra.keywords
  defs.refresh = function(row)
    for i, c in ipairs(choices) do
      local b = row.buttons[i]
      if b and b.label then b.label:SetTextColor(rgba(get(c.id, c.group) and T.accent or T.text)) end
    end
  end
  return EUI.ButtonRow(stack, defs)
end

function G.page(app, UI)
  EUI, T = UI, app.T or UI.Theme
  app:Section("gold", "Gold", function(stack)
    page.stack = stack
    UI.Header(stack, "Gold", "Your gold on every character of this realm and faction, day by day, and where it came from and went. Everything here stays on this PC.")
    -- works the numbers out first on every refresh (a frame with no room)
    local calc = CreateFrame("Frame")
    calc:SetParent(stack.parent)
    function calc:Refresh() pcall(G.compute) end
    stack:Add(calc, 0, 0)
    calc:Refresh()

    choiceRow(stack, {
      { id = "7", group = "range", label = "7 days", width = 80 },
      { id = "30", group = "range", label = "30 days", width = 80 },
      { id = "all", group = "range", label = "All", width = 64 },
      { id = "total", group = "mode", label = "Total", width = 80, desc = "One line: all your characters together." },
      { id = "per", group = "mode", label = "Each character", width = 120, desc = "One line per character, in its class colour." },
    }, function(id, group) return page[group] == id end, function(id, group) page[group] = id end,
      { keywords = { "gold", "chart", "graph", "days", "range", "character" } })
    page.status = UI.Note(stack, function()
      local ser = page.series
      if not ser or #page.chars == 0 then return "Gold per day starts today: every character adds its point when it logs in." end
      local total = ser.total[ser.n] or 0
      local diff = G.change(ser.total, ser.n)
      local s = ("All %d %s: %s"):format(#page.chars, #page.chars == 1 and "character" or "characters", money(total))
      if diff then s = s .. ("  \194\183  %s over %s"):format(G.signed(diff), rangeWords()) end
      return s
    end)
    page.chart = buildChart(stack)
    page.legend = UI.Note(stack, function()
      if page.mode ~= "per" or #page.chars == 0 then return "Hover the chart for a day's gold on each character." end
      local parts = {}
      for i, c in ipairs(page.chars) do
        local ser = page.series
        local v = ser and ser.per[c.key] and ser.per[c.key][ser.n]
        parts[#parts + 1] = ("|cff%s%s|r %s"):format(hexOf(charColor(c, i)), c.name, v and money(v) or "-")
      end
      return table.concat(parts, "   ")
    end)

    UI.Header(stack, "This week and last week", "Monday to Sunday, every character. AH sales before the auction house's cut; the cut is a cost.")
    page.weeks = buildWeeks(stack)
    page.weekNote = UI.Note(stack, function()
      local this = page.this
      local parts = {}
      if this and this.unsorted > 0 then
        parts[#parts + 1] = ("%s this week is unsorted (%d): the AH log's Income view lets you pick what it was."):format(money(this.unsorted), this.n)
      end
      parts[#parts + 1] = "Not counted: gold between your own characters. Repairs, vendor buys and training count from this version on."
      return table.concat(parts, "\n")
    end)

    UI.Header(stack, "Best sellers", "Your sold auctions per item: after the cut, less what you paid when you bought them at the auction house.")
    page.sellNote = UI.Note(stack, function()
      return ("By profit, over %s. Expired: auctions that came back unsold."):format(rangeWords())
    end)
    local function sellerTitle(e)
      return ("%s  |cffffffff%s|r"):format(itemName(e.id, e.name), G.signed(e.profit))
    end
    local function sellerDetail(e)
      local s = ("%d sold in %d %s at %s avg  \194\183  %s after the cut"):format(e.sold, e.n, e.n == 1 and "auction" or "auctions", money(e.avg), money(e.money))
      if e.bought then s = s .. ("  \194\183  paid %s"):format(money(e.cost)) end
      if e.expired > 0 then s = s .. ("  \194\183  %d expired"):format(e.expired) end
      return s
    end
    page.sellers = UI.List(stack, {
      items = function() return page.byProfit or {} end,
      empty = "No sales in this range yet. Each auction you sell lands here once the auction house says so.",
      rowHeight = 40, max = G.TOP,
      title = sellerTitle, detail = sellerDetail,
      color = function(e) return qualityColor(e.id) end,
      icon = function(e) return itemIcon(e.id) end,
      tooltip = function(e, row) itemTip(e.id, row) end,
    })
    UI.Note(stack, "By how many sold:")
    page.counts = UI.List(stack, {
      items = function() return page.byCount or {} end,
      empty = "No sales in this range yet.",
      rowHeight = 40, max = G.TOP,
      title = function(e) return ("%s  |cffffffff%d sold|r"):format(itemName(e.id, e.name), e.sold) end,
      detail = sellerDetail,
      color = function(e) return qualityColor(e.id) end,
      icon = function(e) return itemIcon(e.id) end,
      tooltip = function(e, row) itemTip(e.id, row) end,
    })

    UI.Header(stack, "Biggest buys", "Your largest single purchases at the auction house in this range.")
    page.buyList = UI.List(stack, {
      items = function() return page.buys or {} end,
      empty = "Nothing bought at the auction house in this range.",
      rowHeight = 40, max = G.TOP,
      title = function(e) return ("%s  |cffffffff%s|r"):format(itemName(e.id, e.link and e.link:match("%[(.-)%]")), money(e.c)) end,
      detail = function(e)
        local q = e.q or 1
        return ("%d bought, %s each  \194\183  %s"):format(q, money(math.floor(e.c / math.max(1, q) + 0.5)), date("%d %b %Y", e.t or 0))
      end,
      color = function(e) return qualityColor(e.id) end,
      icon = function(e) return itemIcon(e.id) end,
      tooltip = function(e, row) itemTip(e.id, row) end,
    })

    UI.Header(stack, "Flips", "Items you have both bought and sold here: your average buy against your average sell, after the cut. Everything kept.")
    page.flipList = UI.List(stack, {
      items = function() return page.flips or {} end,
      empty = "Nothing you have both bought and sold yet.",
      rowHeight = 40, max = 12,
      title = function(e)
        return ("%s  |cff%s%s each|r"):format(itemName(e.id), e.margin >= 0 and "6fd16f" or "ef5d5d", G.signed(e.margin))
      end,
      detail = function(e)
        return ("Buy %s avg (%d bought)  \194\183  sell %s avg (%d sold)"):format(money(e.buy), e.bq or 0, money(e.sell), e.sq or 0)
      end,
      color = function(e) return qualityColor(e.id) end,
      icon = function(e) return itemIcon(e.id) end,
      tooltip = function(e, row) itemTip(e.id, row) end,
    })

    UI.Header(stack, "On the auction house now")
    page.listedNote = UI.Note(stack, function()
      if (page.listedN or 0) == 0 then return "No auctions up on any character." end
      return ("%s in %d %s at buyout, on every character (as the auction house last listed them)."):format(
        money(page.listedC), page.listedN, page.listedN == 1 and "auction" or "auctions")
    end, T.text)

    UI.Header(stack, "Export", "CSV to paste into a spreadsheet: click the box, Ctrl+A, Ctrl+C. Gold with the copper as decimals.")
    choiceRow(stack, {
      { id = "days", label = "Gold per day", width = 120 },
      { id = "weeks", label = "Weeks", width = 80 },
      { id = "sellers", label = "Best sellers", width = 110 },
      { id = "flips", label = "Flips", width = 80 },
    }, function(id) return page.export == id end, function(id) page.export = id end, { keywords = { "export", "csv", "copy", "spreadsheet" } })
    page.exportBox = buildExport(stack)
  end, { group = "main", icon = "bars", desc = "Gold on all your characters per day, income and costs per week, best sellers and flips." })

  app:Command("gold", "gold", "the Gold page: gold per day on all characters, this week's income and costs, best sellers", function()
    if ns.hub then ns.hub.open("gold") end
  end, { "money", "dashboard", "networth", "wealth" })

  G.onChange = function()
    if app:IsShown() and app.current == "gold" then refreshPage() end
  end
end

---------------------------------------------------------------------------------------------------------------------
-- Sampling: at login, at logout and a moment after the gold changes (once per burst)

local queued
local function sampleSoon(delay)
  if queued then return end
  queued = true
  local function go()
    queued = nil
    if pcall(G.sample) and G.onChange then pcall(G.onChange) end
  end
  if C_Timer and C_Timer.After then C_Timer.After(delay or 2, go) else go() end
end
G.sampleSoon = sampleSoon

if CreateFrame then
  local ev = CreateFrame("Frame")
  for _, e in ipairs({ "PLAYER_ENTERING_WORLD", "PLAYER_MONEY", "PLAYER_LOGOUT" }) do pcall(ev.RegisterEvent, ev, e) end
  ev:SetScript("OnEvent", function(_, e)
    if e == "PLAYER_LOGOUT" then pcall(G.sample)
    elseif e == "PLAYER_ENTERING_WORLD" then sampleSoon(4)
    else sampleSoon(2) end
  end)
end

return G
