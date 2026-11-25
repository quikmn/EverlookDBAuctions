-- EverlookDB Auctions: Deals, what is cheap in the newest full scan (yours or the Price Feed's).
--   When it is worked out  after every full scan, when the Price Feed is read (login and /reload), and when you
--                          open the auction house. Never by asking the auction house for anything.
--   What counts            under 60% of the usual price (the setting; the usual price is the middle of the last 30
--                          days' daily lows, else the scan's own middle price), below what a vendor pays (buy it and
--                          vendor it: vendors take no cut), below what disenchanting it is worth, under a shopping
--                          list's most to pay, and anything your own Deal searches find (the query language with
--                          formulas: `price lt 50% of median30 and quality ge rare`).
--   Order                  by the profit you can expect (after the AH cut where you'd sell it again), times how
--                          sure the deal is: a usual price from many steady days and several auctions is sure; one
--                          from 3 days, a jumpy price or a single auction is not. Unsure ones are hidden unless the
--                          setting shows them.
--   Where it shows         a quiet "4 deals" button on the auction house's price bar, a line on Home, the Deals page
--                          of the main window, and at the auction house the Deals view over Buy's list. No popups;
--                          no sound unless the setting turns it on.
--   Look again             the Deals view's one gold button: one click looks up one deal's live auctions (one search,
--                          the same as clicking a result in Advanced search) and says whether it is still there at
--                          that price. Still there: it is picked in the buy panel, then Buy, Confirm as always.
--                          Gone: it drops off the list. Nothing is ever searched or bought without your click.
-- Deals bought or gone stay off the list until a newer scan comes in.
local ADDON, ns = ...
local UI, T = ns.UI, ns.T

local D = { list = {}, gone = {}, look = { state = "idle" } }
ns.deals = D

D.MAX = 200                 -- deals kept in the list
D.SURE, D.LIKELY = 0.7, 0.45
local DEFAULTS = { pct = 60, min = 1000 }

local function db() return ns.db and ns.db() or nil end
local function money(c) return ns.money and ns.money(c) or tostring(c) end
local function num(n) return ns.num and ns.num(n) or tostring(n) end
local function try(fn, ...)
  if type(fn) ~= "function" then return nil end
  local okCall, a, b, c, d = pcall(fn, ...)
  if okCall then return a, b, c, d end
end
local function okv(v) if ns.ok then return ns.ok(v) end return v end
local function now() return time() end

---------------------------------------------------------------------------------------------------------------------
-- Settings (EverlookAuctionsDB.deal*)

function D.settings()
  local d = db() or {}
  local pct = tonumber(d.dealPct) or DEFAULTS.pct
  return {
    pct = math.max(5, math.min(95, pct)),
    min = tonumber(d.dealMin) or DEFAULTS.min,
    unsure = d.dealUnsure and true or false,
    sound = d.dealSound and true or false,
    cheap = d.dealCheap ~= false, vendor = d.dealVendor ~= false, de = d.dealDE ~= false, shop = d.dealShop ~= false,
  }
end

-- Deal searches: `name = query`, one per line or separated by ; (EverlookAuctionsDB.dealSearches). A line without a
-- name is named after its query. Returns { { name, query } }.
function D.searchesOf(text)
  local out = {}
  for part in (tostring(text or "") .. "\n"):gmatch("([^\n;]*)[\n;]") do
    part = part:match("^%s*(.-)%s*$")
    if part ~= "" then
      local name, q = part:match("^([%w_ ]-)%s*=%s*(.+)$")
      if not name or name == "" or q:match("^[%s]*$") then name, q = nil, part end
      out[#out + 1] = { name = name or q, query = q }
    end
  end
  return out
end

-- Checks Deal searches before they are saved: true, or false and what is wrong in plain words.
function D.checkSearches(text)
  for _, s in ipairs(D.searchesOf(text)) do
    if ns.queryParse then
      local okP, err = pcall(ns.queryParse, s.query)
      if not okP then
        return false, ("%s: %s"):format(s.name, type(err) == "table" and err.query or tostring(err))
      end
    end
  end
  return true
end

---------------------------------------------------------------------------------------------------------------------
-- The numbers (no frames: the tests run these offline)

-- The usual price from an item's daily lows ({ [day] = copper }): the middle one of the last 30 days (as median30),
-- with how many days and how steady they are (the lower quarter's price over the upper quarter's: 1 is flat).
function D.usualOf(days, today)
  local list = {}
  if type(days) == "table" then
    local first = (today or 0) - 29
    for day, p in pairs(days) do
      if (not today or day >= first) and type(p) == "number" and p > 0 then list[#list + 1] = p end
    end
  end
  local n = #list
  if n < 3 then return nil, n, 0 end
  table.sort(list)
  local mid = list[math.floor((n + 1) / 2)]
  local q1, q3 = list[math.max(1, math.ceil(n / 4))], list[math.max(1, math.ceil(n * 3 / 4))]
  local steady = q3 > 0 and q1 / q3 or 0
  return mid, n, steady
end

-- How sure a "cheap" deal is, 0 to 1: days of history (10 or more is best), how steady they are, how many auctions
-- are up. No history (the scan's own middle price) is never more than unsure. Your own auctions up: less sure (the
-- cheapest may be yours).
function D.confidence(days, steady, auctions, yours)
  local c
  if (days or 0) >= 3 then
    c = 0.35 * math.min(1, days / 10) + 0.45 * math.max(0, math.min(1, steady or 0)) + 0.2 * math.min(1, (auctions or 0) / 5)
  else
    c = 0.25 * math.min(1, (auctions or 0) / 5)
  end
  if yours then c = c * 0.6 end
  return c
end

function D.sureText(c)
  if c >= D.SURE then return "sure" end
  if c >= D.LIKELY then return "likely" end
  return "unsure"
end

-- Units at the deal's price we can count on: one for gear; for stackable goods one, or a tenth of what is up when even
-- the 10th-percentile price is under the limit.
local function unitsOf(row, limit)
  if (row.stack or 1) <= 1 then return 1 end
  if row.p10 and limit and row.p10 <= limit then return math.max(1, math.floor((row.qty or 1) * 0.1)) end
  return 1
end

local DE_QUALITY = { uncommon = true, rare = true, epic = true }   -- what can be disenchanted

local function pctText(price, usual)
  return ("%d%% of usual"):format(math.floor(price / usual * 100 + 0.5))
end

-- The deals in rows of a scan (Search.lua's dataset rows). o: settings (D.settings) plus
--   cut        the AH cut when selling again (0.05)
--   today      day number, for the history
--   days(id)   daily lows { [day] = copper }      devalue(id)  disenchant value or nil
--   price(row) the price to use (a fresh live price), default row.price
--   listed(id) how many you have up               gone         { [key] = true } bought or gone, left out
--   shop       { { list, name, rows = { [key] = { max, need } } } } shopping lists' lines with a max
--   searches   { { name, keys = { [key] = true } } } what each Deal search found
-- Returns the list, best first: { key, id, row, name, price, profit, conf, sure, units, limit, reasons = { { kind,
-- text, profit, limit, conf } } }, and how many unsure ones were left out.
function D.build(rows, o)
  o = o or {}
  local cut = o.cut or 0.05
  local minP = o.min or DEFAULTS.min
  local pct = (o.pct or DEFAULTS.pct) / 100
  local V = ns.vendor
  local out, hidden = {}, 0
  for _, row in ipairs(rows or {}) do
    local key = row.key
    local price = o.price and o.price(row)
    if price == nil then price = row.price end
    if key and not (o.gone and o.gone[key]) and not row.quest and type(price) == "number" and price > 0 then
      local reasons = {}
      local yours   -- asked only for a deal (it counts your characters' auctions)
      local function isYours()
        if yours == nil then yours = o.listed and (o.listed(row.id) or 0) > 0 or false end
        return yours
      end
      local usual, days, steady = D.usualOf(o.days and o.days(row.id), o.today)
      if not usual and type(row.median) == "number" and row.median > 0 then usual, days, steady = row.median, 0, 0 end
      local resale = usual and (usual * (1 - cut) - price) or nil
      -- under pct of the usual price, making at least the minimum after the cut
      if o.cheap ~= false and usual and price < usual * pct then
        local limit = math.floor(usual * pct)
        local units = unitsOf(row, limit)
        local profit = math.floor(resale * units)
        if profit >= minP then
          reasons[#reasons + 1] = { kind = "cheap", text = pctText(price, usual), profit = profit, limit = limit,
            conf = D.confidence(days, steady, row.auctions, isYours()), units = units }
        end
      end
      -- below what a vendor pays: the scan's single auctions under it (Vendor.lua), else the lowest price
      local sell = row.sell
      if o.vendor ~= false and V and type(sell) == "number" and sell > 0 and price < sell then
        local profit, units
        if row.dealText then
          local list = V.dealsOf(row.dealText, sell, V.MIN_DEAL)
          local n, total, _, u = V.dealSummary(list)
          if n > 0 then profit, units = total, u end
        else
          profit, units = sell - price, 1
          if profit < V.MIN_DEAL then profit = nil end
        end
        if profit then
          reasons[#reasons + 1] = { kind = "vendor", text = ("vendor pays %s more"):format(money(sell - price)),
            profit = profit, limit = sell - 1, conf = 1, units = units }
        end
      end
      -- below what disenchanting it is worth (gear only)
      if o.de ~= false and o.devalue and (row.stack or 1) <= 1 and DE_QUALITY[row.quality or ""] then
        local v = o.devalue(row.id)
        if type(v) == "number" and v > price then
          local profit = math.floor(v * (1 - cut) - price)
          if profit >= minP then
            reasons[#reasons + 1] = { kind = "de", text = ("disenchants for %s"):format(money(v)), profit = profit,
              limit = math.floor(v), conf = 0.6, units = 1 }
          end
        end
      end
      -- a shopping list's most to pay
      if o.shop ~= false then
        for _, s in ipairs(o.shop or {}) do
          local line = s.rows and s.rows[key]
          if line and type(line.max) == "number" and price <= line.max then
            local units = math.max(1, math.min(line.need or 1, row.qty or 1))
            reasons[#reasons + 1] = { kind = "shop", text = ("under your max of %s (%s)"):format(money(line.max), s.name),
              profit = math.floor((line.max - price) * units), limit = math.floor(line.max), conf = 1, units = units }
            break
          end
        end
      end
      -- your own Deal searches
      for _, s in ipairs(o.searches or {}) do
        if s.keys and s.keys[key] then
          reasons[#reasons + 1] = { kind = "search", text = ("your search %s"):format(s.name),
            profit = resale and math.max(0, math.floor(resale)) or 0, limit = price, conf = 1, units = 1 }
          break
        end
      end
      if #reasons > 0 then
        local best, top, profit, conf, limit = nil, nil, 0, 0, 0
        for _, r in ipairs(reasons) do
          if not best or r.profit * r.conf > best.profit * best.conf then best = r end
          if not top or r.profit > profit then top, profit = r, r.profit end
          if r.conf > conf then conf = r.conf end
          if r.limit > limit then limit = r.limit end
        end
        table.sort(reasons, function(a, b) return a.profit * a.conf > b.profit * b.conf end)
        local deal = { key = key, id = row.id, row = row, name = row.name or ("item " .. tostring(row.id)), icon = row.icon,
          quality = row.quality, price = price, qty = row.qty, auctions = row.auctions, usual = usual, yours = isYours() or nil,
          profit = profit, conf = conf, sure = D.sureText(conf), units = top.units or 1, limit = limit, reasons = reasons,
          score = best.profit * best.conf }
        if deal.sure == "unsure" and not o.unsure then
          hidden = hidden + 1
        else
          out[#out + 1] = deal
        end
      end
    end
  end
  table.sort(out, function(a, b)
    -- the profit the row shows, biggest first (sure before likely on a tie); unsure ones are left out unless asked for
    if a.profit ~= b.profit then return a.profit > b.profit end
    if a.score ~= b.score then return a.score > b.score end
    return a.name < b.name
  end)
  for k = #out, D.MAX + 1, -1 do out[k] = nil end
  return out, hidden
end

-- Why a deal is one, for its row: "38% of usual · vendor pays 1g more".
function D.whyText(deal)
  local bits = {}
  for _, r in ipairs(deal.reasons or {}) do bits[#bits + 1] = r.text end
  return table.concat(bits, " \194\183 ")
end

-- The quiet line: "4 deals", or nil when there are none.
function D.countText(n)
  n = n or #D.list
  if n <= 0 then return nil end
  return ("%d %s"):format(n, n == 1 and "deal" or "deals")
end

---------------------------------------------------------------------------------------------------------------------
-- Look again: one live search per click for one deal. States:
--   idle      the button says "Look again: <item>"
--   looking   one search on its way; more clicks do nothing until it is answered
--   found     still there at the deal's price: the buy panel has it picked (Buy, then Confirm)
--   gone      not there at that price any more: dropped from the list
--   noanswer  the auction house didn't answer in full: nothing dropped, the next click asks again
--   bought    you bought it: dropped from the list

D.lookFn = function(row, cb) return ns.lookAgain and ns.lookAgain(row, cb) end
D.ahOpen = function() return ns.house and ns.house() ~= nil end

local function byKey(key)
  for i, d in ipairs(D.list) do if d.key == key then return d, i end end
end
D.byKey = byKey

-- The deal Look again checks: the one picked in the list, else the top one.
function D.target()
  if D.sel then
    local d = byKey(D.sel)
    if d then return d end
    D.sel = nil
  end
  return D.list[1]
end

-- From a live answer (Buy.lua's rows, cheapest first): items, the cheapest auction from someone else with a buyout at
-- most `limit`; stackable goods, how many others sell at most at `limit` and what they cost. nil when there is none.
function D.livePick(rows, limit, commodity)
  if commodity then
    local qty, cost, unit = 0, 0, nil
    for _, r in ipairs(rows or {}) do
      local n = r.others or r.qty or 0
      if r.unit and r.unit <= limit and n > 0 then
        qty, cost = qty + n, cost + n * r.unit
        if not unit or r.unit < unit then unit = r.unit end
      end
    end
    if qty > 0 then return { qty = qty, cost = cost, unit = unit } end
    return nil
  end
  local best
  for _, r in ipairs(rows or {}) do
    if not r.mine and r.buyout and r.unit and r.unit <= limit and (not best or r.unit < best.unit) then best = r end
  end
  return best
end

-- The cheapest price from others in a live answer, for "gone: the cheapest is 12s now".
local function cheapestOf(rows)
  local low
  for _, r in ipairs(rows or {}) do
    if r.unit and not (r.mine and not r.others) and (r.others == nil or r.others > 0) and (not low or r.unit < low) then low = r.unit end
  end
  return low
end

-- Takes a deal off the list until a newer scan comes in.
function D.drop(key)
  if not key then return end
  D.gone[key] = D.scanAt or true
  local d = db()
  if d then
    d.dealsGone = d.dealsGone or {}
    d.dealsGone[key] = D.scanAt or 0
  end
  local _, i = byKey(key)
  if i then table.remove(D.list, i) end
  if D.sel == key then D.sel = nil end
  D.changed()
end

-- One click on Look again: true when a search was sent.
function D.click()
  local L = D.look
  if L.state == "looking" then return false end
  if not D.ahOpen() then
    D.look = { state = "away", text = "Look again works at the auction house." }
    D.changed()
    return false
  end
  local deal = D.target()
  if not deal then return false end
  D.look = { state = "looking", key = deal.key, at = now(), name = deal.name }
  local sent = D.lookFn(deal.row, function(rows, complete, commodity) return D.onLive(deal.key, rows, complete, commodity) end)
  if not sent then
    D.look = { state = "noanswer", key = deal.key, text = "Couldn't look it up right now. Click again." }
  end
  D.changed()
  return sent and true or false
end

-- The live answer for the deal Look again asked about. Returns what the buy panel does: the auction to pick (or for
-- stackable goods { qty, cost, unit }), "gone" (close it: the deal dropped), "noanswer", or nil (not ours).
function D.onLive(key, rows, complete, commodity)
  local L = D.look
  if L.state ~= "looking" or L.key ~= key then return nil end
  local deal = byKey(key)
  if not deal then
    D.look = { state = "idle" }
    D.changed()
    return "gone"
  end
  deal.checkedAt = now()
  if not complete then
    D.look = { state = "noanswer", key = key, name = deal.name,
      text = ("The auction house didn't answer in full for %s. Nothing was dropped; click Look again to ask again."):format(deal.name) }
    D.changed()
    return "noanswer"
  end
  local pick = D.livePick(rows, deal.limit, commodity)
  if pick then
    deal.live = pick.unit
    local each = pick.unit or deal.price
    local text
    if commodity then
      text = ("Still there: %s for %s, at most %s each. Buy, then Confirm."):format(num(pick.qty), money(pick.cost), money(deal.limit))
    else
      text = ("Still there at %s (%s). Buy, then Confirm."):format(money(each), D.whyText(deal))
    end
    D.look = { state = "found", key = key, name = deal.name, text = text }
    D.changed()
    return pick
  end
  local low = cheapestOf(rows)
  D.look = { state = "gone", name = deal.name, text = low
    and ("%s is gone at that price: the cheapest is %s now. Dropped from the list."):format(deal.name, money(low))
    or ("%s is sold out. Dropped from the list."):format(deal.name) }
  D.drop(key)
  return "gone"
end

-- You bought the deal Look again found.
function D.onBought(key)
  local deal = byKey(key)
  D.look = { state = "bought", text = ("Bought %s. It's in your mailbox."):format(deal and deal.name or "it") }
  D.drop(key)
end

-- The buy panel closed: a found deal is back to waiting for the next click.
function D.onBuyClosed()
  if D.look.state == "found" or D.look.state == "looking" then D.look = { state = "idle" } end
  D.changed()
end

-- The gold button's label and whether it can be clicked.
function D.buttonState()
  local L = D.look
  if L.state == "looking" then return ("Looking for %s..."):format(L.name or "it"), false end
  if not D.ahOpen() then return "Look again (at the auction house)", false end
  local deal = D.target()
  if not deal then return "No deals", false end
  return "Look again: " .. deal.name, true
end

---------------------------------------------------------------------------------------------------------------------
-- Working the list out from the game

local function cutNow()
  if ns.house and ns.house() and ns.ahCut then return ns.ahCut() end
  local key = ns.houseOrFaction and ns.houseOrFaction() or ""
  return tostring(key):match("%-Neutral$") and 0.15 or 0.05
end

local function shoppingLines(byKeyRows)
  local out = {}
  local d = db()
  for _, l in ipairs(d and d.lists or {}) do
    if type(l) == "table" and type(l.max) == "table" then
      local s = { name = l.name or "a shopping list", rows = {} }
      for _, q in ipairs(l.queries or {}) do
        local m = l.max[q]
        if m ~= nil and m ~= 0 and m ~= "" and ns.queryRunQuiet then
          local found = ns.queryRunQuiet(q)
          local want = l.want and tonumber(l.want[q])
          local got = l.got and l.got[q] and l.got[q].n or 0
          local need = want and (want - got) or nil
          if not need or need > 0 then
            for _, r in ipairs(found or {}) do
              local max = m
              if type(m) == "string" then max = ns.formulaRow and ns.formulaRow(m, r) or nil end
              if type(max) == "number" and max > 0 and byKeyRows[r.key] then
                s.rows[r.key] = { max = math.floor(max), need = need }
              end
            end
          end
        end
      end
      if next(s.rows) then out[#out + 1] = s end
    end
  end
  return out
end

local function searchHits()
  local out = {}
  local d = db()
  for _, s in ipairs(D.searchesOf(d and d.dealSearches)) do
    local found = ns.queryRunQuiet and ns.queryRunQuiet(s.query)
    if found then
      local keys = {}
      for _, r in ipairs(found) do if r.key then keys[r.key] = true end end
      out[#out + 1] = { name = '"' .. s.name .. '"', keys = keys }
    end
  end
  return out
end

-- Works the list out again from the newest scan. Quiet: no popup; a sound only when the setting is on and a deal is
-- new since the last time.
function D.compute()
  if not ns.queryDataset then return end
  local rows, scanned, missing = ns.queryDataset()
  if not rows or not scanned then
    D.list, D.scanAt, D.hidden = {}, nil, 0
    D.changed()
    return
  end
  local at = scanned.at or 0
  -- a newer scan: what was bought or gone may be back
  local d = db()
  if d then
    d.dealsGone = d.dealsGone or {}
    for k, v in pairs(d.dealsGone) do if v ~= at then d.dealsGone[k] = nil end end
  end
  if D.scanAt ~= at then D.gone = {} end
  for k in pairs(d and d.dealsGone or {}) do D.gone[k] = true end
  D.scanAt, D.scanShared, D.scanTime = at, scanned.shared and true or false, scanned.at
  if ns.queryFresh then ns.queryFresh() end
  local byKeyRows = {}
  for _, r in ipairs(rows) do byKeyRows[r.key] = r end
  local o = D.settings()
  o.cut, o.today, o.gone = cutNow(), ns.today and ns.today() or nil, D.gone
  o.days = ns.historyDays
  o.devalue = function(id) local v = try(ns.disenchantValue, id); return type(v) == "number" and v or nil end
  o.price = ns.queryValue and function(r) return ns.queryValue(r, "price") end or nil
  o.listed = ns.inventory and ns.inventory.column and function(id) return tonumber(try(ns.inventory.column, id, "listed")) or 0 end or nil
  o.shop = o.shop ~= false and shoppingLines(byKeyRows) or nil
  o.searches = searchHits()
  local before = {}
  for _, x in ipairs(D.list) do before[x.key] = true end
  local okB, list, hidden = pcall(D.build, rows, o)
  if not okB then D.error = list; return end
  D.error = nil
  -- keeps when each was checked
  local checked = {}
  for _, x in ipairs(D.list) do checked[x.key] = x.checkedAt end
  for _, x in ipairs(list) do x.checkedAt = checked[x.key] end
  D.list, D.hidden, D.missing, D.at = list, hidden or 0, missing or 0, now()
  local new = false
  for _, x in ipairs(list) do if not before[x.key] then new = true end end
  if new and o.sound and D.hadList then
    pcall(PlaySound, (SOUNDKIT and SOUNDKIT.MAP_PING) or 3175, "Master")
  end
  D.hadList = true
  D.changed()
  -- items still loading: once more in a while, so the list sees them
  if (missing or 0) > 0 and (D.retries or 0) < 3 and C_Timer then
    D.retries = (D.retries or 0) + 1
    C_Timer.After(15, function() D.compute() end)
  elseif (missing or 0) == 0 then
    D.retries = 0
  end
end

-- Soon, once: several triggers close together (a scan and the auction house opening) count once.
local soon = false
function D.computeSoon(delay)
  if soon or not C_Timer then return end
  soon = true
  C_Timer.After(delay or 1, function()
    soon = false
    pcall(D.compute)
  end)
end

-- What shows the list: the bar's button, the views. Set by the views below.
local watchers = {}
function D.onChange(fn) watchers[#watchers + 1] = fn end
function D.changed()
  for _, fn in ipairs(watchers) do pcall(fn) end
end

-- "from your scan 12 min ago" / "from other players' scan 1 h ago"
function D.sourceText()
  if not D.scanAt then return "No full scan of this auction house yet." end
  local ago = ns.ago and ns.ago(D.scanShared and (ns.shared and ns.shared.localAt and ns.shared.localAt({ at = D.scanAt })) or D.scanAt) or ""
  return ("From %s %s."):format(D.scanShared and "other players' scan" or "your full scan", ago)
end

---------------------------------------------------------------------------------------------------------------------
-- The Deals view at the auction house: over Advanced search's area on Buy (the Buy panel opens over it)

local ROW_H = 34
local V = {}
D.view = V

local function qualityHex(q)
  local idx = type(q) == "string" and ({ poor = 0, common = 1, uncommon = 2, rare = 3, epic = 4, legendary = 5 })[q] or q
  local c = idx and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[idx]
  return c and c.hex or "|cffffffff"
end

local SURE_COLOR = function(s) return s == "sure" and T.good or s == "likely" and T.info or T.mute end

local function checkedText(deal)
  if not deal.checkedAt then return "" end
  local secs = now() - deal.checkedAt
  if secs < 60 then return "checked just now" end
  return ("checked %d min ago"):format(math.floor(secs / 60))
end

local function buildRow(L)
  local b = UI.row(L, ROW_H)
  b.icon = b:CreateTexture(nil, "ARTWORK")
  b.icon:SetSize(22, 22)
  b.icon:SetPoint("LEFT", 8, 0)
  b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  b.sure = UI.badge(b, 56, 16)
  b.sure:SetPoint("RIGHT", -6, 0)
  b.profit = UI.text(b, "body")
  b.profit:SetPoint("RIGHT", b.sure, "LEFT", -10, 0)
  b.profit:SetWidth(100)
  b.profit:SetJustifyH("RIGHT")
  b.price = UI.text(b, "body")
  b.price:SetPoint("RIGHT", b.profit, "LEFT", -10, 0)
  b.price:SetWidth(100)
  b.price:SetJustifyH("RIGHT")
  b.name = UI.text(b, "body")
  b.name:SetPoint("TOPLEFT", b.icon, "TOPRIGHT", 8, 2)
  b.name:SetPoint("RIGHT", b.price, "LEFT", -8, 0)
  b.name:SetWordWrap(false)
  b.why = UI.text(b, "mute")
  b.why:SetPoint("TOPLEFT", b.name, "BOTTOMLEFT", 0, -2)
  b.why:SetPoint("RIGHT", b.price, "LEFT", -8, 0)
  b.why:SetWordWrap(false)
  b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  b:SetScript("OnClick", function(self, button)
    local deal = self.item
    if not deal then return end
    if button == "RightButton" then D.drop(deal.key); return end
    D.sel = deal.key
    V.render()
  end)
  b:SetScript("OnEnter", function(self)
    local deal = self.item
    if not deal then return end
    if ns.itemTipOwner then ns.itemTipOwner(self) else GameTooltip:SetOwner(self, "ANCHOR_RIGHT") end
    pcall(GameTooltip.SetItemByID, GameTooltip, deal.id)
    GameTooltip:AddLine(" ")
    for _, r in ipairs(deal.reasons) do
      GameTooltip:AddLine(("%s: about %s profit"):format(r.text, money(r.profit)), T.dim[1], T.dim[2], T.dim[3], true)
    end
    if deal.usual then GameTooltip:AddLine("Usual price: " .. money(deal.usual), T.dim[1], T.dim[2], T.dim[3]) end
    if deal.yours then GameTooltip:AddLine("You have some up too: the cheapest may be yours.", T.dim[1], T.dim[2], T.dim[3], true) end
    GameTooltip:AddLine("Click: Look again checks this one. Right-click: take it off the list.", T.info[1], T.info[2], T.info[3], true)
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)
  return b
end

local function fillRow(b, deal)
  b.icon:SetTexture(deal.icon)
  b.name:SetText(qualityHex(deal.quality) .. deal.name .. "|r" .. UI.hex(T.mute)
    .. ("  %s up"):format(num(deal.qty or 0)) .. ((deal.checkedAt and ("  \194\183  " .. checkedText(deal))) or "") .. "|r")
  b.why:SetText(D.whyText(deal))
  b.price:SetText(money(deal.price))
  b.profit:SetText(UI.hex(T.good) .. "+" .. money(deal.profit) .. "|r")
  b.sure:EdbSet(deal.sure, SURE_COLOR(deal.sure))
  local t = D.target()
  b:EdbSelect(t and t.key == deal.key)
end

local function makeView(parent)
  local O = UI.own(CreateFrame("Frame", "EverlookAuctionsDeals", parent))
  O:SetPoint("TOPLEFT", 1, -26)
  O:SetPoint("BOTTOMRIGHT", -1, 1)
  O:SetFrameLevel(parent:GetFrameLevel() + 20)
  UI.panel(O, T.bg, T.bg)
  O:EnableMouse(true)
  O:Hide()

  local close = UI.button(O, "Close", 60, 22, "small")
  close:SetPoint("TOPRIGHT", -10, -8)
  close:SetScript("OnClick", function() V.hide() end)
  local settings = UI.button(O, "Settings", 70, 22, "small")
  settings:SetPoint("RIGHT", close, "LEFT", -4, 0)
  settings:SetScript("OnClick", function() if ns.app and ns.app.Open then ns.app:Open("deals") end end)
  UI.tip(settings, "Deals settings", "How cheap counts as a deal, the smallest profit, which kinds, unsure deals, a sound, and your own Deal searches.")
  O.info = UI.text(O, "dim")
  O.info:SetPoint("TOPLEFT", 12, -12)
  O.info:SetPoint("RIGHT", settings, "LEFT", -10, 0)
  O.info:SetJustifyH("LEFT")
  O.info:SetWordWrap(false)

  local bd = UI.headerBand(O, 20)
  bd:SetPoint("TOPLEFT", 0, -38)
  bd:SetPoint("TOPRIGHT", 0, -38)
  for _, c in ipairs({ { "ITEM  \194\183  WHY", 38 }, { "PRICE EACH", -196, true }, { "PROFIT", -86, true }, { "HOW SURE", -16, true } }) do
    local l = UI.label(bd, c[1])
    if c[3] then l:SetPoint("RIGHT", bd, "RIGHT", c[2], 0); l:SetJustifyH("RIGHT") else l:SetPoint("LEFT", bd, "LEFT", c[2], 0) end
  end
  O.list = UI.list(O, ROW_H, buildRow, fillRow)
  O.list:SetPoint("TOPLEFT", 0, -58)
  O.list:SetPoint("BOTTOMRIGHT", -2, 82)

  local line = UI.line(O, true)
  line:SetPoint("BOTTOMLEFT", 0, 44)
  line:SetPoint("BOTTOMRIGHT", 0, 44)
  O.go = UI.button(O, "Look again", 300, 28, "primary")
  O.go:SetPoint("BOTTOMRIGHT", -10, 8)
  O.go:SetScript("OnClick", function() D.click() end)
  UI.tip(O.go, "Look again", "One search for this deal's live auctions: is it still there at that price? Still there: it is picked, then Buy and Confirm. Gone: it drops off the list. The auction house allows one search per click, so this never runs by itself.")
  O.note = UI.text(O, "mute")
  O.note:SetPoint("LEFT", O, "BOTTOMLEFT", 12, 22)
  O.note:SetPoint("RIGHT", O.go, "LEFT", -12, 0)
  O.note:SetJustifyH("LEFT")
  O.note:SetWordWrap(true)
  if O.note.SetMaxLines then O.note:SetMaxLines(2) end
  O.status = UI.text(O, "body")
  O.status:SetPoint("BOTTOMLEFT", 12, 52)
  O.status:SetPoint("RIGHT", O, "RIGHT", -12, 0)
  O.status:SetJustifyH("LEFT")
  O.status:SetWordWrap(false)

  O:SetScript("OnShow", function()
    if ns.searchPrimary and not ns.buyOpen then ns.searchPrimary(false) end   -- Look again is the gold button here
    if ns.searchCrumb then ns.searchCrumb(nil) end
    V.render()
  end)
  O:SetScript("OnHide", function()
    if ns.searchPrimary and not ns.buyOpen then ns.searchPrimary(true) end
    if ns.searchCrumb then ns.searchCrumb(nil) end
    if ns.liveStep then ns.liveStep() end   -- Advanced search's own live check goes on
  end)
  local tick = 0
  O:SetScript("OnUpdate", function(_, dt)
    tick = tick + dt
    if tick < 10 then return end
    tick = 0
    V.render()   -- "checked 3 min ago" moves on
  end)
  V.frame = O
  return O
end

function V.shown() return V.opening or (V.frame ~= nil and V.frame:IsVisible()) end
D.shown = V.shown

function V.render()
  local O = V.frame
  if not O or not O:IsShown() then return end
  local n = #D.list
  local bits = { D.sourceText() }
  if n > 0 then bits[#bits + 1] = ("%s, best first."):format(D.countText(n)) else bits[#bits + 1] = "No deals right now." end
  if (D.hidden or 0) > 0 then bits[#bits + 1] = ("%d unsure left out."):format(D.hidden) end
  O.info:SetText(table.concat(bits, "  "))
  O.list:SetItems(D.list)
  O.list.empty:SetText("Nothing under your deal rules in this scan. A new one comes with the next price update.")
  O.list.empty:SetShown(n == 0)
  local label, usable = D.buttonState()
  O.go:SetText(label)
  O.go:SetEnabled(usable)
  local L = D.look
  local color = (L.state == "gone" or L.state == "noanswer") and T.bad or (L.state == "found" or L.state == "bought") and T.good or T.text
  O.status:SetText(L.text or "")
  O.status:SetTextColor(unpack(color))
  O.note:SetText("Prices are from the scan; Look again checks one deal live per click. Right-click a deal to take it off.")
end

-- Opens the Deals view: at the auction house over Buy's list, else the Deals page of the main window.
function V.open()
  local ah = _G.AuctionHouseFrame
  if not (ah and ah:IsShown()) then
    if ns.hub then ns.hub.open("deals") end
    return
  end
  -- (opening: Advanced search's own live check waits, it would otherwise ask about its list before this covers it)
  V.opening = true
  if ns.openSearch then pcall(ns.openSearch, true) end
  V.opening = nil
  local host = _G.EverlookAuctionsQueryResults
  if not host then return end
  if ns.closeBuy then ns.closeBuy() end
  local O = V.frame or makeView(host)
  if O:GetParent() ~= host then O:SetParent(host); O:SetFrameLevel(host:GetFrameLevel() + 20) end
  O:Show()
  V.render()
end
D.open = V.open

function V.hide()
  if V.frame then V.frame:Hide() end
end

D.onChange(function() V.render() end)

---------------------------------------------------------------------------------------------------------------------
-- The Deals page of the main window (Hub.lua lists it)

local page = {}
function D.page(app, EUI)
  app:Section("deals", "Deals", function(stack)
    EUI.Header(stack, "Deals", "Cheap auctions in the newest full scan: under your share of the usual price, below what a vendor pays, below what disenchanting is worth, under a shopping list's max, and what your Deal searches find. Biggest profit first.")
    page.status = EUI.Note(stack, function()
      local n = #D.list
      local s = D.sourceText() .. "  " .. (n > 0 and (D.countText(n) .. ".") or "No deals right now.")
      if (D.hidden or 0) > 0 then s = s .. ("  %d unsure left out (Settings, Deals shows them)."):format(D.hidden) end
      return s .. "\nAt the auction house, the Deals view's Look again checks one deal per click and Buy, Confirm buys it."
    end)
    EUI.ButtonRow(stack, {
      { label = "Open at the auction house", width = 200, style = "accent", onClick = function() V.open() end,
        desc = "The Deals view over Buy's list, with Look again (the auction house must be open).", keywords = { "deals", "open", "look again" } },
      { label = "Deals settings", width = 130, onClick = function() app:Open("dealsettings") end,
        desc = "How cheap counts, which kinds, a sound, your Deal searches.", keywords = { "deals", "settings" } },
    })
    page.list = EUI.List(stack, {
      items = function() return D.list end,
      empty = "Nothing under your deal rules in the newest scan.",
      rowHeight = 40,
      title = function(d)
        -- stackable goods: the price is per item and the profit is for all of them, so say how many
        if (d.units or 1) > 1 then
          return ("%s  |cffffffff%s each|r  |cff6fd16f+%s for %s|r"):format(d.name, money(d.price), money(d.profit), num(d.units))
        end
        return ("%s  |cffffffff%s|r  |cff6fd16f+%s|r"):format(d.name, money(d.price), money(d.profit))
      end,
      color = function(d)
        local idx = ({ poor = 0, common = 1, uncommon = 2, rare = 3, epic = 4, legendary = 5 })[d.quality or ""]
        local c = idx and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[idx]
        return c and { c.r, c.g, c.b } or nil
      end,
      detail = function(d) return D.whyText(d) .. "  \194\183  " .. d.sure .. (d.checkedAt and ("  \194\183  " .. checkedText(d)) or "") end,
      icon = function(d) return d.icon end,
      tooltip = function(d, row)
        if ns.itemTooltip then ns.itemTooltip(row, d.id) else
          GameTooltip:SetOwner(row, "ANCHOR_RIGHT"); GameTooltip:SetItemByID(d.id); GameTooltip:Show()
        end
      end,
      max = D.MAX,
    })
  end, { group = "main", icon = "coins", desc = "Cheap auctions in the newest scan, best profit first." })
  D.onChange(function()
    if app:IsShown() and app.current == "deals" then
      if page.status then page.status:Refresh() end
      if page.list then page.list:Refresh() end
    end
  end)
end

---------------------------------------------------------------------------------------------------------------------
-- Settings page and commands (Options.lua calls this)

function D.settingsFor(app, EUI)
  local function set(key) return function(v) local d = db(); if d then d[key] = v end end end
  local function after() D.computeSoon(0.2) end
  app:Setting({ key = "dealpct", type = "number", label = "A deal is under this share of the usual price (%)", min = 10, max = 95, step = 5,
    keywords = { "deal", "deals", "cheap", "percent", "median", "usual", "sniper" },
    desc = "60: an auction at less than 60% of the usual price (the middle of the last 30 days' daily lows) is a deal.",
    get = function() return D.settings().pct end, set = set("dealPct"), after = after })
  app:Setting({ key = "dealmin", type = "string", label = "Smallest profit for a deal", width = 120, placeholder = "10s",
    keywords = { "deal", "deals", "profit", "minimum", "least" },
    desc = "A cheap or disenchant deal must make at least this much after the AH cut: 10s, 1g, 50c.",
    get = function() return money(D.settings().min) end,
    validate = function(v) if not (ns.parseMoney and ns.parseMoney(tostring(v or ""))) then return false, "money like 10s, 1g or 50c" end; return true end,
    set = function(v)
      local c = ns.parseMoney and ns.parseMoney(tostring(v or ""))
      if not c then app:Print("Smallest profit not saved: money like 10s, 1g or 50c."); return end
      local d = db(); if d then d.dealMin = c end
    end, after = after })
  for _, k in ipairs({
    { "dealcheap", "dealCheap", "Cheap: under that share of the usual price", { "cheap", "median", "usual" } },
    { "dealvendor", "dealVendor", "Below what a vendor pays", { "vendor", "flip", "belowvendor" } },
    { "dealde", "dealDE", "Below what disenchanting it is worth", { "disenchant", "devalue", "enchanting" } },
    { "dealshop", "dealShop", "Under a shopping list's most to pay", { "shopping", "list", "max" } },
  }) do
    app:Setting({ key = k[1], type = "bool", label = k[3], chatLabel = "Deals: " .. k[3]:lower(), keywords = { "deal", "deals", unpack(k[4]) },
      get = function() local d = db(); return not (d and d[k[2]] == false) end,
      set = function(v) local d = db(); if d then d[k[2]] = v and true or false end end, after = after })
  end
  app:Setting({ key = "dealunsure", type = "bool", label = "Show unsure deals too", keywords = { "deal", "deals", "unsure", "confidence", "sure" },
    desc = "A usual price from only a few days, a jumpy price or a single auction makes a deal unsure. Off: those are left out.",
    get = function() return D.settings().unsure end, set = set("dealUnsure"), after = after })
  app:Setting({ key = "dealsound", type = "bool", label = "A sound when a new deal comes in", keywords = { "deal", "deals", "sound", "alert", "ping" },
    desc = "Off by default: Deals never pops up, the count just changes on the price bar and on Home.",
    get = function() return D.settings().sound end, set = set("dealSound") })
  app:Setting({ key = "dealsearches", type = "string", label = "Deal searches", width = 340,
    placeholder = "cheap blues = price lt 50% of median30 and quality ge rare",
    keywords = { "deal", "deals", "search", "query", "formula", "sniper", "watch" },
    desc = "Your own searches for deals, name = search, separated by ; (cheap blues = price lt 50% of median30 and quality ge rare; cloth = name has cloth and price lt 80% of median). Everything they find is a deal.",
    get = function() local d = db(); return d and d.dealSearches and d.dealSearches:gsub("%s*\n%s*", "; ") or "" end,
    validate = function(v) return D.checkSearches(v) end,
    set = function(v)
      v = tostring(v or ""):match("^%s*(.-)%s*$")
      local okC, why = D.checkSearches(v)
      if not okC then app:Print("Deal searches not saved: " .. why); return end
      local d = db(); if d then d.dealSearches = v ~= "" and v or nil end
    end, after = after })
  app:Section("dealsettings", "Deals", function(stack)
    EUI.Header(stack, "Deals", "Worked out from each full scan and the Price Feed: the price bar and Home say how many there are, the Deals page and the auction house's Deals view list them.")
    app:Widget(stack, "dealpct")
    app:Widget(stack, "dealmin")
    EUI.Header(stack, "Which kinds")
    app:Widget(stack, "dealcheap")
    app:Widget(stack, "dealvendor")
    app:Widget(stack, "dealde")
    app:Widget(stack, "dealshop")
    app:Widget(stack, "dealunsure")
    app:Widget(stack, "dealsound")
    EUI.Header(stack, "Deal searches", "The same words as Advanced search, with price formulas: price lt 50% of median30, price lt devalue - 50s, quality ge rare.")
    app:Widget(stack, "dealsearches")
  end, { icon = "coins" })
  app:Command("deals", "deals", "the Deals: cheap auctions in the newest scan (the Deals view at the auction house)", function() V.open() end, { "deal", "snipe", "sniper" })
end

---------------------------------------------------------------------------------------------------------------------
-- When the list is worked out

local prevScan = ns.onScan
function ns.onScan(...)
  if prevScan then prevScan(...) end
  D.computeSoon(1)
end

if CreateFrame then
  local ev = CreateFrame("Frame")
  for _, e in ipairs({ "PLAYER_LOGIN", "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED" }) do pcall(ev.RegisterEvent, ev, e) end
  ev:SetScript("OnEvent", function(_, e)
    if e == "PLAYER_LOGIN" then
      D.computeSoon(8)   -- the Price Feed is read by now; items have had a moment to load
    elseif e == "AUCTION_HOUSE_SHOW" then
      D.computeSoon(1)   -- this house's scan (a neutral one, maybe)
    else
      if D.look.state == "looking" or D.look.state == "found" then D.look = { state = "idle" } end
      D.changed()
      D.computeSoon(1)   -- back to your faction's house (after a neutral one)
    end
  end)
end
