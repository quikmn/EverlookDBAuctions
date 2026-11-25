-- EverlookDB Auctions: Buy this list. A guided walk through a shopping list at the open auction house, one item at a
-- time, in a small panel docked to the right of the auction house window:
--   "Buy 60 Light Leather?"  [Yes] [Skip]
--   Yes looks at the live auctions and shows the cheapest way to get that many: how many at which price, the total
--   and the price each, and a warning when that is far above the usual price, when fewer are listed than wanted, or
--   when your max price leaves some out.
--   [Buy for 1g 32s]  one click buys it. Stackable goods: the auction house is asked for the exact price first (a
--   price quote buys nothing), and the button shows that price. Single items: each click buys one.
--   Then the next item, until the list is done, with what was bought, skipped and spent.
-- Nothing is ever bought without your click on Buy, and every Buy click buys once.
-- What is still needed: the list's amount minus what was bought on earlier runs (list.got) and, for lists that count
-- what you have (list.countHave: imported lists), minus what is in your bags and bank (and on your alts when
-- EverlookDB Crafting counts them).
-- Saved: list.got[query] = { n = bought so far, base = what you had when buying started }, list.max[query] = the
-- most to pay for one, in copper. Only items and amounts, never a player name.

local _, ns = ...
local UI, T = ns.UI, ns.T
local money, num = ns.money, ns.num

local W = {}
ns.buyList = W

local QUOTE_WAIT = 8      -- seconds to wait for a price quote
local BUY_WAIT = 8        -- seconds to wait for word about a purchase
local PRICEY = 1.5        -- an average this many times the usual price is "far above"
local MAX_REQUOTES = 3    -- price quotes asked again on their own for one item, before Get the price takes a click

local function AH() return C_AuctionHouse or {} end

local function try(fn, ...)
  if type(fn) ~= "function" then return nil end
  local okCall, a = pcall(fn, ...)
  if okCall then return a end
end

local function okv(v)
  if ns.ok then return ns.ok(v) end
  return v
end

local function plain(text) return (tostring(text or ""):gsub("|", "||")) end

---------------------------------------------------------------------------------------------------------------------
-- The logic (no frames; tests/run.py uses these directly)

-- What you have of an item: bags and bank (the game's count, right now), what waits in your mail, and your alts'
-- bags, bank and mail (Inventory.lua), unless EverlookDB Crafting's "Don't count my alts' materials" is on.
function W.haveOf(id)
  local n = try(C_Item and C_Item.GetItemCount, id, true, false, true) or 0
  local api, cdb = rawget(_G, "EverlookCraftAPI"), rawget(_G, "EverlookCraftDB")
  local noAlts = type(cdb) == "table" and type(cdb.settings) == "table" and cdb.settings.noAlts
  local I = ns.inventory
  if I and I.count and I.store() then
    local r = I.count(id)
    for _, e in ipairs(r and r.chars or {}) do
      if e.me then n = n + e.mail
      elseif not noAlts then n = n + e.bags + e.bank + e.mail end
    end
  elseif api and type(api.stock) == "function" and not noAlts then
    local s = try(api.stock, id)
    if type(s) == "table" and tonumber(s.alts) then n = n + s.alts end
  end
  return n
end

-- How many of a list's item are still to buy, and how many it wants. have: what you have now.
function W.need(l, q, have)
  local want = math.floor(tonumber(l.want and l.want[q]) or 0)
  local g = l.got and l.got[q]
  local got = g and g.n or 0
  if l.countHave then
    local base = g and g.base or have or 0
    return math.max(0, want - math.max(have or 0, base + got)), want
  end
  return math.max(0, want - got), want
end

-- The list's items to buy, in its order: { { q, id, name, max } } (searches without an amount are left out).
function W.entries(l, idOf)
  local out = {}
  for _, q in ipairs(l.queries or {}) do
    local want = l.want and l.want[q]
    local name = q:match('^name is "(.*)"$')
    if want and want > 0 and name then
      local id = l.items and l.items[q] or (idOf and idOf(name))
      if id then
        local max, maxText = l.max and l.max[q], nil
        -- a price formula ("80% of median"): worked out for this item now; one that isn't known pays nothing
        if type(max) == "string" then
          maxText = max
          max = ns.formulaFor and ns.formulaFor(max, id)
          max = max and math.floor(max) or 0
        end
        out[#out + 1] = { q = q, id = id, name = name, max = max, maxText = maxText }
      end
    end
  end
  return out
end

-- The cheapest way to get `want` from the live auctions (rows cheapest first: { unit, qty or others, mine }).
-- Returns { take = { { unit, n, row } }, got, cost, avg, avail (listed by others within max), overMax (listed above
-- it) }.
function W.plan(rows, want, commodity, max)
  local sorted = {}
  for _, r in ipairs(rows or {}) do sorted[#sorted + 1] = r end
  table.sort(sorted, function(a, b) return (a.unit or math.huge) < (b.unit or math.huge) end)
  local p = { take = {}, got = 0, cost = 0, avail = 0, overMax = 0 }
  for _, r in ipairs(sorted) do
    local n
    if commodity then n = r.others or r.qty or 0 else n = (r.mine or not r.auctionID) and 0 or (r.qty or 1) end
    if r.unit and r.unit > 0 and n > 0 then
      if max and r.unit > max then
        p.overMax = p.overMax + n
      else
        p.avail = p.avail + n
        local t = math.min(n, want - p.got)
        if t > 0 then
          p.take[#p.take + 1] = { unit = r.unit, n = t, row = r }
          p.got, p.cost = p.got + t, p.cost + t * r.unit
        end
      end
    end
  end
  p.avg = p.got > 0 and math.floor(p.cost / p.got + 0.5) or nil
  return p
end

-- The usual price of one: the middle of the last 30 days' daily lows (3 days or more), else the last scan's median,
-- else its lowest price. nil when nothing is known.
function W.usual(id)
  local h = ns.historyFor and ns.historyFor(id) or {}
  if #h >= 3 then
    local lows = {}
    for i, d in ipairs(h) do lows[i] = d[2] end
    table.sort(lows)
    return lows[math.floor((#lows + 1) / 2)]
  end
  local row = ns.scanRowFor and ns.scanRowFor(id .. ":0")
  if row and row.med then return row.med end
  local it = ns.itemFor and ns.itemFor(id)
  return it and it[1] or nil
end

-- What a list should cost at usual prices (the middle of the last 30 days' lows, else the last scan's): for what is
-- still needed. Returns { total, priced = n, unpriced = { names }, each = { [query] = { need, usual, cost } } }.
function W.estimate(l, idOf)
  local out = { total = 0, priced = 0, unpriced = {}, each = {} }
  if not l then return out end
  for _, e in ipairs(W.entries(l, idOf)) do
    local need = W.need(l, e.q, W.haveOf(e.id))
    if need > 0 then
      local usual = W.usual(e.id)
      if usual and usual > 0 then
        local cost = math.floor(usual * need + 0.5)
        out.total, out.priced = out.total + cost, out.priced + 1
        out.each[e.q] = { need = need, usual = usual, cost = cost }
      else
        out.unpriced[#out.unpriced + 1] = e.name
        out.each[e.q] = { need = need }
      end
    end
  end
  return out
end

-- "26% over the usual price" (red from PRICEY's share up), "8% under the usual price" (green), "about the usual price"
function W.vsUsual(avg, usual)
  if not (avg and usual and usual > 0) then return nil end
  local pct = math.floor((avg / usual - 1) * 100 + 0.5)
  if pct >= 5 then
    local c = avg > usual * PRICEY and "|cffef5d5d" or "|cffffd100"
    return ("%s%d%% over the usual price|r (usually %s each)"):format(c, pct, money(usual))
  elseif pct <= -5 then
    return ("|cff6fd16f%d%% under the usual price|r (usually %s each)"):format(-pct, money(usual))
  end
  return ("About the usual price (%s each)"):format(money(usual))
end

-- The lines that explain a plan: how many at which price (the first few prices), then the total.
function W.planLines(p)
  local lines, shown = {}, 0
  local groups = {}
  for _, t in ipairs(p.take) do
    local g = groups[#groups]
    if g and g.unit == t.unit then g.n = g.n + t.n else groups[#groups + 1] = { unit = t.unit, n = t.n } end
  end
  for _, g in ipairs(groups) do
    shown = shown + 1
    if shown <= 4 then
      lines[#lines + 1] = ("%s at %s each"):format(num(g.n), money(g.unit))
    end
  end
  if #groups > 4 then lines[#lines + 1] = ("and %d more prices"):format(#groups - 4) end
  if p.got > 1 then lines[#lines + 1] = ("Total %s, about %s each"):format(money(p.cost), money(p.avg)) end
  return lines
end

-- Warnings for a plan: fewer than wanted (and why), far above the usual price.
function W.warnings(p, want, usual, max)
  local out = {}
  if p.got == 0 then
    if p.overMax > 0 then
      out[#out + 1] = ("None under your max of %s each (%s listed above it)."):format(money(max), num(p.overMax))
    else
      out[#out + 1] = "None for sale right now."
    end
    return out
  end
  if p.got < want then
    if p.overMax > 0 then
      out[#out + 1] = ("Only %s under your max of %s (you want %s)."):format(num(p.got), money(max), num(want))
    else
      out[#out + 1] = ("Only %s listed (you want %s)."):format(num(p.got), num(want))
    end
  end
  if usual and usual > 0 and p.avg and p.avg > usual * PRICEY and p.avg - usual >= 50 then
    out[#out + 1] = ("Far above the usual price: about %s each, %d%% over the usual %s."):format(money(p.avg),
      math.floor((p.avg / usual - 1) * 100 + 0.5), money(usual))
  end
  return out
end

-- The end: what was bought, skipped and spent.
function W.summaryLines(t)
  local lines = {}
  local spent, n = 0, 0
  for _, b in ipairs(t.bought) do spent, n = spent + b.cost, n + 1 end
  lines[#lines + 1] = ("Bought %d item%s for %s."):format(n, n == 1 and "" or "s", money(spent))
  for _, b in ipairs(t.bought) do
    local short = b.want and b.n < b.want and (" (of %s)"):format(num(b.want)) or ""
    lines[#lines + 1] = ("  %s %s%s  %s"):format(num(b.n), plain(b.name), short, money(b.cost))
  end
  local function names(list) local o = {} for k, v in ipairs(list) do o[k] = plain(v) end return table.concat(o, ", ") end
  if #t.skipped > 0 then lines[#lines + 1] = "Skipped: " .. names(t.skipped) end
  if #t.none > 0 then lines[#lines + 1] = "None to buy: " .. names(t.none) end
  if #t.enough > 0 then lines[#lines + 1] = "Had enough: " .. names(t.enough) end
  return lines, spent
end

---------------------------------------------------------------------------------------------------------------------
-- The walk

local run          -- the walk going on: { list, entries, i, step, tally, cur }
local render, search, ask, finishItem, requestQuote, cancelQuote
local events = {}
W.events = events

local function db() return ns.db and ns.db() end

local function setStatus(text, color)
  if run then run.status, run.statusColor = text, color end
end

local function after(secs, fn)
  local r, c = run, run and run.cur
  C_Timer.After(secs, function() if run == r and run and run.cur == c then fn() end end)
end

-- Notes a purchase in the list (bought so far, and what you had when buying started).
local function noteBought(l, q, n, have)
  l.got = l.got or {}
  local g = l.got[q]
  if not g then
    g = { n = 0, base = l.countHave and have or nil }
    l.got[q] = g
  end
  g.n = g.n + n
end

function ask(i)
  local r = run
  if not r then return end
  cancelQuote()
  while i <= #r.entries do
    local e = r.entries[i]
    local have = W.haveOf(e.id)
    local need, want = W.need(r.list, e.q, have)
    if need > 0 then
      r.i, r.step = i, "ask"
      r.cur = { e = e, need = need, want = want, have = have, max = e.max, maxText = e.maxText, n = 0, cost = 0, requotes = 0 }
      render()
      return
    end
    r.tally.enough[#r.tally.enough + 1] = e.name
    i = i + 1
  end
  r.i, r.step, r.cur = #r.entries + 1, "done", nil
  ns.listBuying = nil
  if ns.ahq then ns.ahq.cancel("buylist") end
  if ns.shoppingRefresh then pcall(ns.shoppingRefresh) end
  render()
end

local function nextItem() if run then ask(run.i + 1) end end

-- The item's live auctions, read the way the buy panel reads them (Buy.lua).
local function commodityRows(id)
  local rows = {}
  for i = 1, (try(AH().GetNumCommoditySearchResults, id) or 0) do
    local x = try(AH().GetCommoditySearchResultInfo, id, i)
    if x then
      local q = okv(x.quantity) or 0
      local mine = okv(x.numOwnerItems) or 0
      rows[#rows + 1] = { unit = okv(x.unitPrice), qty = q, others = q - mine }
    end
  end
  return rows
end

local function itemRows(key)
  local rows = {}
  for i = 1, (try(AH().GetNumItemSearchResults, key) or 0) do
    local x = try(AH().GetItemSearchResultInfo, key, i)
    if x then
      local buy = okv(x.buyoutAmount)
      if buy and buy <= 0 then buy = nil end
      rows[#rows + 1] = { auctionID = okv(x.auctionID), unit = buy, qty = okv(x.quantity) or 1,
        mine = okv(x.containsOwnerItem) == true }
    end
  end
  return rows
end

local function makePlan()
  local c = run and run.cur
  if not c then return end
  c.plan = W.plan(c.rows, c.need - c.n, c.commodity, c.max)
  c.usual = c.usual or W.usual(c.e.id)
  c.warn = W.warnings(c.plan, c.need - c.n, c.usual, c.max)
  run.step = "plan"
  if c.commodity and c.plan.got > 0 then
    local d = db()
    if not (d and d.quoteByClick) then requestQuote() end
  end
  render()
end

function search()
  local r = run
  local c = r and r.cur
  if not c then return end
  cancelQuote()
  r.step, c.err, c.plan = "search", nil, nil
  if not ns.ahq then c.err = "This client can't search the auction house."; r.step = "plan"; render(); return end
  ns.ahq.cancel("buylist")
  local stack = ns.itemInfo and ns.itemInfo(c.e.id)
  c.commodity = (stack and (stack[10] or 1) or 1) > 1   -- until the auction house's own key says
  local function noAnswer()
    if run ~= r or r.cur ~= c then return end
    c.err = "The auction house didn't answer."
    r.step = "plan"
    render()
  end
  ns.ahq.browse(c.e.name, c.e.id, { owner = "buylist", front = true, confirmEmpty = true }, function(answer)
    if run ~= r or r.cur ~= c then return end
    if not answer.ok then noAnswer(); return end
    if #answer.entries == 0 then
      c.rows = {}
      makePlan()
      return
    end
    local keys = ns.ahq.pickKeys(answer.entries, c.e.name, ns.ahq.nameOf)
    local info = try(AH().GetItemKeyInfo, keys[1])
    if info and okv(info.isCommodity) ~= nil then c.commodity = okv(info.isCommodity) and true or false end
    local got, left = {}, #keys
    for _, key in ipairs(keys) do
      ns.ahq.items(key, { owner = "buylist", front = true, commodity = c.commodity, onFail = noAnswer },
        function(k, _, final)
          if run ~= r or r.cur ~= c then return end
          got[ns.ahq.keyText(k)] = c.commodity and commodityRows(c.e.id) or itemRows(k)
          if not final then return end
          left = left - 1
          if left > 0 then return end
          local rows = {}
          for _, list in pairs(got) do for _, x in ipairs(list) do rows[#rows + 1] = x end end
          c.rows = rows
          makePlan()
        end)
    end
  end)
  render()
end

function cancelQuote()
  local c = run and run.cur
  if c and (c.quote or c.quoting) and AH().CancelCommoditiesPurchase then pcall(AH().CancelCommoditiesPurchase) end
  if c then c.quote, c.quoting, c.waitReady = nil, nil, nil end
end

-- Asks the auction house for the exact price of the planned amount (buys nothing).
function requestQuote()
  local c = run and run.cur
  if not (c and c.plan and c.plan.got > 0) or c.pending then return end
  if c.quoting or c.waitReady then return end   -- one on its way: another click would cancel it and start over
  -- right after a search the auction house drops anything else sent to it: wait until it says it's ready
  local ready = AH().IsThrottledMessageSystemReady
  if ready then
    local okR, isReady = pcall(ready)
    if okR and isReady == false then
      c.waitReady = true
      setStatus(nil)
      render()
      return
    end
  end
  cancelQuote()
  if not AH().StartCommoditiesPurchase then c.quoteFailed = true; return end
  local okCall = pcall(AH().StartCommoditiesPurchase, c.e.id, c.plan.got)
  if not okCall then c.quoteFailed = true; return end
  local ask = { qty = c.plan.got }
  c.quoting, c.quoteFailed = ask, nil
  after(QUOTE_WAIT, function()
    if c.quoting == ask then
      cancelQuote()
      -- dropped because the auction house was busy (another search went out): ask again by itself once it's ready
      local ready = AH().IsThrottledMessageSystemReady
      local okR, isReady = pcall(ready or function() return true end)
      if okR and isReady == false and (c.requotes or 0) < MAX_REQUOTES then
        c.requotes = (c.requotes or 0) + 1
        c.waitReady = true
        render()
        return
      end
      c.quoteFailed = true
      setStatus("The auction house didn't send a price. Press Get the price to ask again.", T.mute)
      render()
    end
  end)
end

local function buyNow()
  local r = run
  local c = r and r.cur
  if not (c and c.plan) or c.pending then return end
  if c.commodity then
    local quote = c.quote
    if not quote then requestQuote(); render(); return end   -- Get the price: asking for a price buys nothing
    local left = try(AH().GetQuoteDurationRemaining)
    if (type(left) == "number" and left <= 0) or (quote.endsAt and GetTime() >= quote.endsAt) then
      cancelQuote()
      c.quoteFailed = true
      setStatus("The price ran out, so nothing was bought. Press Get the price to ask again.", T.mute)
      render()
      return
    end
    if GetMoney() < quote.total then render(); return end
    if not AH().ConfirmCommoditiesPurchase then return end
    c.quote = nil
    local okCall, err = pcall(AH().ConfirmCommoditiesPurchase, c.e.id, quote.qty)
    if not okCall then setStatus("Couldn't buy: " .. tostring(err), T.bad); render(); return end
    c.pending, c.buying = "commodity", { qty = quote.qty, cost = quote.total }
  else
    local t = c.plan.take[1]
    local row = t and t.row
    if not (row and row.auctionID and row.unit) then return end
    if GetMoney() < row.unit then render(); return end
    if not AH().PlaceBid then return end
    local okCall, err = pcall(AH().PlaceBid, row.auctionID, row.unit)
    if not okCall then setStatus("Couldn't buy: " .. tostring(err), T.bad); render(); return end
    c.pending, c.buying = row.auctionID, { qty = 1, cost = row.unit, row = row }
  end
  r.step = "buying"
  setStatus(nil)
  local mine = c.pending
  after(BUY_WAIT, function()
    if c.pending == mine then
      c.pending, c.late, c.lateBuying = nil, mine, c.buying
      c.buying = nil
      setStatus("No word from the auction house about that purchase yet: check your mailbox before buying it again. Looking at the auctions again.", T.bad)
      search()
    end
  end)
  render()
end

-- A purchase went through: count it, then the next item (or the next one of the same item).
local function bought(b)
  local r = run
  local c = r and r.cur
  if not c or not b then return end
  c.pending, c.buying, c.late, c.lateBuying = nil, nil, nil, nil
  c.n, c.cost = c.n + b.qty, c.cost + b.cost
  r.tally.spentNow = (r.tally.spentNow or 0) + b.cost
  noteBought(r.list, c.e.q, b.qty, c.have)
  if ns.shoppingRefresh then pcall(ns.shoppingRefresh) end
  if b.row then
    -- one item of an auction: the rest of it is still up
    b.row.qty = (b.row.qty or 1) - 1
    if c.n < c.need then
      local p = W.plan(c.rows, c.need - c.n, false, c.max)
      if p.got > 0 then
        setStatus(("Bought %s of %s %s for %s so far."):format(num(c.n), num(c.need), plain(c.e.name), money(c.cost)), T.good)
        makePlan()
        return
      end
    end
  end
  setStatus(("Bought %s %s for %s."):format(num(c.n), plain(c.e.name), money(c.cost)), T.good)
  finishItem()
end

function finishItem()
  local r = run
  local c = r and r.cur
  if not c then return end
  if c.n > 0 then
    r.tally.bought[#r.tally.bought + 1] = { name = c.e.name, n = c.n, want = c.need, cost = c.cost }
  end
  nextItem()
end

local function failed(text)
  local c = run and run.cur
  if not c then return end
  c.pending, c.buying = nil, nil
  if c.late then c.late, c.lateBuying = nil, nil end
  setStatus(text, T.bad)
  C_Timer.After(0.5, function() if run and run.cur == c then search() end end)
  render()
end

function W.yes()
  if not run or not run.cur then return end
  setStatus(nil)
  search()
end

function W.skip()
  local r = run
  if not r or not r.cur or r.cur.pending then return end
  local c = r.cur
  if c.n > 0 then
    r.tally.bought[#r.tally.bought + 1] = { name = c.e.name, n = c.n, want = c.need, cost = c.cost }
  elseif c.plan and c.plan.got == 0 then
    r.tally.none[#r.tally.none + 1] = c.e.name
  else
    r.tally.skipped[#r.tally.skipped + 1] = c.e.name
  end
  setStatus(nil)
  nextItem()
end

-- The one gold button: what it does depends on the step.
function W.primary()
  local r = run
  if not r then return end
  local c = r.cur
  if r.step == "done" then W.stop(); return end
  if not c then return end
  if r.step == "ask" then W.yes(); return end
  if r.step == "plan" then
    if c.err then search(); return end
    if c.plan and c.plan.got == 0 then W.skip(); return end
    buyNow()
  end
end

-- The most to pay for one, from the box: saved in the list, and the plan worked out again.
function W.setMax(text)
  local c = run and run.cur
  if not c then return end
  text = tostring(text or ""):match("^%s*(.-)%s*$")
  local m = (text ~= "" and text:lower() ~= "any") and ns.listImport.money(text) or nil
  local formula
  if text ~= "" and text:lower() ~= "any" and not m then
    -- a price formula: 80% of median, max(vendor, low30), myfloor
    local v, why = ns.formulaFor and ns.formulaFor(text, c.e.id)
    if why then
      setStatus("Type a price like 25s or 1g 50s, or a price formula like 80% of median (empty: any price). " .. why, T.bad)
      render()
      return
    end
    formula, m = text, v and math.floor(v) or 0
  end
  c.max, c.maxText = m, formula
  local l = run.list
  l.max = l.max or {}
  l.max[c.e.q] = formula or m
  if run.step == "plan" and c.rows and not c.pending then makePlan() else render() end
end

-- only: one search of the list (a row's Buy button): just that item, with the same price check and Buy click
function W.start(l, only)
  if not l then return false, "no list" end
  if not (_G.AuctionHouseFrame and AuctionHouseFrame:IsShown()) then return false, "closed" end
  local entries = W.entries(l, ns.listImport and ns.listImport.idOf)
  if only then
    local one = {}
    for _, e in ipairs(entries) do if e.q == only then one[1] = e end end
    entries = one
  end
  if #entries == 0 then return false, "empty" end
  if ns.closeBuy then pcall(ns.closeBuy) end
  if run then cancelQuote() end
  run = { list = l, entries = entries, i = 0, tally = { bought = {}, skipped = {}, none = {}, enough = {} } }
  ns.listBuying = true
  W.show()
  ask(1)
  -- one row's Buy: that click was the Yes, so it looks at the auctions at once
  if only and run and run.step == "ask" then W.yes() end
  return true
end

function W.stop()
  local r = run
  if not r then if W.frame then W.frame:Hide() end return end
  if r.cur and r.cur.pending then return end   -- a purchase is on its way: wait for its answer
  cancelQuote()
  if r.step ~= "done" and r.cur then
    if r.cur.n > 0 then
      r.tally.bought[#r.tally.bought + 1] = { name = r.cur.e.name, n = r.cur.n, want = r.cur.need, cost = r.cur.cost }
    end
    r.cur = nil
    r.step = "done"
    r.stopped = true
    ns.listBuying = nil
    if ns.ahq then ns.ahq.cancel("buylist") end
    render()
    return
  end
  run = nil
  ns.listBuying = nil
  if ns.ahq then ns.ahq.cancel("buylist") end
  if W.frame then W.frame:Hide() end
end

W.state = function() return run end   -- for tests

---------------------------------------------------------------------------------------------------------------------
-- Events

function events.COMMODITY_PRICE_UPDATED(unit, total)
  local c = run and run.cur
  if not (c and c.quoting) then return end
  total = okv(total)
  local ask = c.quoting
  c.quoting = nil
  if type(total) ~= "number" or total <= 0 then
    cancelQuote()
    c.quoteFailed = true
    setStatus("The auction house's price couldn't be read. Press Get the price to ask again.", T.bad)
    render()
    return
  end
  local secs = try(AH().GetQuoteDurationRemaining)
  if type(secs) ~= "number" or secs <= 0 then secs = 30 end
  local quote = { qty = ask.qty, total = total, unit = okv(unit), endsAt = GetTime() + math.max(1, secs - 1) }
  c.quote = quote
  if c.plan and total > c.plan.cost * 1.05 then
    setStatus(("The price went up to %s (from %s): some sold meanwhile."):format(money(total), money(c.plan.cost)), T.bad)
  end
  after(math.max(1, secs - 1), function()
    if c.quote == quote then
      cancelQuote()
      c.quoteFailed = true
      setStatus("The price ran out, so nothing was bought. Press Get the price to ask again.", T.mute)
      render()
    end
  end)
  render()
end

function events.COMMODITY_PRICE_UNAVAILABLE()
  local c = run and run.cur
  if not (c and (c.quoting or c.quote)) then return end
  c.quoting, c.quote = nil, nil
  c.requotes = c.requotes + 1
  setStatus("That many aren't for sale any more (some sold meanwhile). Looking at the auctions again.", T.bad)
  if c.requotes >= MAX_REQUOTES then c.quoteFailed = true; render(); return end
  search()
end

function events.COMMODITY_PURCHASE_SUCCEEDED()
  local c = run and run.cur
  if not c then return end
  if c.pending == "commodity" then bought(c.buying)
  elseif c.late == "commodity" then bought(c.lateBuying) end
end

function events.COMMODITY_PURCHASE_FAILED()
  local c = run and run.cur
  if not (c and (c.pending == "commodity" or c.late == "commodity")) then return end
  failed("That purchase didn't go through, so nothing was paid (the auctions changed). Looking at them again.")
end

function events.AUCTION_HOUSE_PURCHASE_COMPLETED(auctionID)
  local c = run and run.cur
  if not c or auctionID == nil then return end
  if c.pending == auctionID then bought(c.buying)
  elseif c.late == auctionID then bought(c.lateBuying) end
end

function events.AUCTION_HOUSE_SHOW_ERROR(err)
  local c = run and run.cur
  if not (c and type(c.pending) == "number") then return end
  local row = c.buying and c.buying.row
  if row then row.qty = 0 end   -- gone or refused: not offered again
  local why = _G.AuctionHouseUtil and AuctionHouseUtil.GetErrorText and try(AuctionHouseUtil.GetErrorText, err)
  failed("The auction house refused it" .. ((why and why ~= "") and (": " .. why) or "") ..
    ". Nothing was paid. Looking at the auctions again.")
end

function events.PLAYER_MONEY() if run then render() end end

-- the auction house is ready for the next message: a price quote that waited for it goes now
function events.AUCTION_HOUSE_THROTTLED_SYSTEM_READY()
  local c = run and run.cur
  if c and c.waitReady then
    c.waitReady = nil
    requestQuote()
    render()
  end
end

-- Asking for a price can need a click on some clients: then Get the price takes one, from now on.
function events.ADDON_ACTION_BLOCKED(addon, fn)
  if addon ~= "EverlookDBAuctions" or not tostring(fn or ""):find("StartCommoditiesPurchase") then return end
  local d = db()
  if d then d.quoteByClick = true end
  local c = run and run.cur
  if c then c.quoting, c.quoteFailed = nil, true; render() end
end

function events.AUCTION_HOUSE_CLOSED()
  local r = run
  if not r then return end
  if r.cur and r.cur.n > 0 and r.step ~= "done" then
    r.tally.bought[#r.tally.bought + 1] = { name = r.cur.e.name, n = r.cur.n, want = r.cur.need, cost = r.cur.cost }
  end
  local lines = W.summaryLines(r.tally)
  if #r.tally.bought > 0 and ns.say then
    ns.say(("buying %s stopped: the auction house closed. %s"):format(plain(r.list.name), lines[1]))
  end
  run = nil
  ns.listBuying = nil
  if W.frame then W.frame:Hide() end
end

local ev = CreateFrame("Frame")
for e in pairs(events) do pcall(ev.RegisterEvent, ev, e) end
ev:SetScript("OnEvent", function(_, e, ...) local h = events[e]; if h then h(...) end end)

---------------------------------------------------------------------------------------------------------------------
-- The panel, docked to the right of the auction house window

local function makeFrame()
  local ah = _G.AuctionHouseFrame
  if W.frame or not ah then return W.frame end
  local f = UI.own(CreateFrame("Frame", "EverlookAuctionsBuyList", ah))
  f:SetSize(300, 340)
  f:SetPoint("TOPLEFT", ah, "TOPRIGHT", 6, 0)
  f:EnableMouse(true)
  local PLACE = T.places.shopping
  UI.panel(f, T.bg, T.edge)
  UI.placeEdge(f, PLACE)
  f:Hide()
  W.frame = f

  f.title = UI.label(f, "BUY THIS LIST")
  f.title:SetTextColor(unpack(PLACE))
  f.title:SetPoint("TOPLEFT", 12, -12)
  f.stopBtn = UI.button(f, "Stop", 50, 18, "small quiet")
  f.stopBtn:SetPoint("TOPRIGHT", -8, -8)
  f.stopBtn:SetScript("OnClick", function() W.stop() end)
  UI.tip(f.stopBtn, "Stop buying", "What was bought so far stays ticked off on the list.")
  f.progress = UI.text(f, "mute")
  f.progress:SetPoint("RIGHT", f.stopBtn, "LEFT", -8, 0)
  f.progress:SetJustifyH("RIGHT")
  f.listName = UI.text(f, "dim")
  f.listName:SetPoint("TOPLEFT", 12, -28)
  f.listName:SetPoint("RIGHT", f, "RIGHT", -12, 0)

  f.icon = UI.icon(f, 32)
  f.icon:SetPoint("TOPLEFT", 12, -50)
  f.head = UI.text(f, "big")
  f.head:SetPoint("TOPLEFT", f.icon, "TOPRIGHT", 10, 0)
  f.head:SetPoint("RIGHT", f, "RIGHT", -12, 0)
  f.head:SetWordWrap(true)
  f.sub = UI.text(f, "dim")
  f.sub:SetPoint("TOPLEFT", f.head, "BOTTOMLEFT", 0, -4)
  f.sub:SetPoint("RIGHT", f, "RIGHT", -12, 0)

  f.body = UI.text(f, "body")
  f.body:SetPoint("TOPLEFT", 12, -96)
  f.body:SetPoint("RIGHT", f, "RIGHT", -12, 0)
  f.body:SetWordWrap(true)
  f.body:SetJustifyV("TOP")
  f.warn = UI.text(f, "body")
  f.warn:SetPoint("TOPLEFT", f.body, "BOTTOMLEFT", 0, -6)
  f.warn:SetPoint("RIGHT", f, "RIGHT", -12, 0)
  f.warn:SetWordWrap(true)
  f.warn:SetTextColor(unpack(T.bad))

  f.maxLabel = UI.label(f, "MAX EACH")
  f.maxLabel:SetPoint("BOTTOMLEFT", 12, 82)
  f.max = UI.input(f, 90, 22, { hint = "any price", max = 60 })
  f.max:SetPoint("LEFT", f.maxLabel, "RIGHT", 8, 0)
  f.max:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
  f.max:HookScript("OnEditFocusLost", function(self) W.setMax(self:GetText()) end)
  UI.tip(f.max, "The most to pay for one", "Like 25s or 1g 50s, or a price formula like 80% of median or one of your My prices (myfloor). Empty: any price. Saved in the list.")

  f.status = UI.text(f, "dim")
  f.status:SetPoint("BOTTOMLEFT", 12, 44)
  f.status:SetPoint("RIGHT", f, "RIGHT", -12, 0)
  f.status:SetWordWrap(true)
  f.status:SetJustifyV("BOTTOM")
  if f.status.SetMaxLines then f.status:SetMaxLines(3) end

  f.go = UI.button(f, "Yes", 176, 28, "primary")
  f.go:SetPoint("BOTTOMRIGHT", -10, 10)
  f.go:SetScript("OnClick", function() W.primary() end)
  f.skip = UI.button(f, "Skip", 90, 28)
  f.skip:SetPoint("RIGHT", f.go, "LEFT", -6, 0)
  f.skip:SetScript("OnClick", function() W.skip() end)
  UI.tip(f.skip, "Skip this item", "Go on with the next item of the list.")
  return f
end

function W.show()
  local f = makeFrame()
  if not f then return end
  if ns.raise then ns.raise(f) end
  f:Show()
end

function render()
  local f = W.frame
  local r = run
  if not f then return end
  if not r then f:Hide(); return end
  if not f:IsShown() then f:Show() end
  f.listName:SetText(plain(r.list.name))
  local c = r.cur
  local total = #r.entries
  f.progress:SetText(r.step == "done" and "" or ("%d of %d"):format(math.min(r.i, total), total))
  f.stopBtn:SetShown(r.step ~= "done")
  local go, skip = f.go, f.skip
  local body, warn, sub = {}, {}, ""
  local showMax = false
  go:SetEnabled(true)
  skip:SetShown(true)

  if r.step == "done" or not c then
    f.icon:EdbSet(nil)
    local lines = W.summaryLines(r.tally)
    f.head:SetText(r.stopped and "Stopped" or "Done")
    sub = (#r.tally.bought > 0) and "Everything bought is in your mailbox." or ""
    for _, l in ipairs(lines) do body[#body + 1] = l end   -- names already made safe; money keeps its coin icons
    go:SetText("Close")
    skip:SetShown(false)
  else
    local e = c.e
    local qty = try(C_Item and C_Item.GetItemQualityByID, e.id)
    f.icon:EdbSet(try(C_Item and C_Item.GetItemIconByID, e.id) or 134400, qty)
    local left = c.need - c.n
    f.head:SetText(r.step == "ask" and ("Buy %s %s?"):format(num(left), plain(e.name)) or ("%s %s"):format(num(left), plain(e.name)))
    if r.list.countHave then
      sub = ("The list wants %s, you have %s"):format(num(c.want), num(c.have))
    elseif c.want > c.need then
      sub = ("%s of %s bought before"):format(num(c.want - c.need), num(c.want))
    else
      sub = ("The list wants %s"):format(num(c.want))
    end
    if c.n > 0 then sub = sub .. (", bought %s now"):format(num(c.n)) end
    showMax = r.step == "ask" or r.step == "plan"
    if r.step == "ask" then
      go:SetText("Yes")
      if r.i == 1 or not r.estimate then
        r.estimate = r.estimate or W.estimate(r.list, ns.listImport and ns.listImport.idOf)
        local est = r.estimate
        if est.priced > 1 then
          body[#body + 1] = ("The whole list: about %s at usual prices%s."):format(money(est.total),
            #est.unpriced > 0 and (" (%d without a price yet)"):format(#est.unpriced) or "")
        end
      end
      local usual = c.usual or W.usual(e.id)
      c.usual = usual
      if usual and usual > 0 then
        body[#body + 1] = ("This one: about %s (%s each, usually)."):format(money(math.floor(usual * left + 0.5)), money(usual))
      else
        body[#body + 1] = "No usual price for this one yet: the auctions will tell."
      end
      if c.maxText and c.max == 0 then
        body[#body + 1] = ("Paying at most %s each: not known for this item yet, so nothing is bought."):format(c.maxText)
      elseif c.maxText then
        body[#body + 1] = ("Paying at most %s each (%s)."):format(money(c.max), c.maxText)
      elseif c.max then
        body[#body + 1] = ("Paying at most %s each."):format(money(c.max))
      end
    elseif r.step == "search" then
      body[#body + 1] = "Looking at the auctions..."
      go:SetText("Looking...")
      go:SetEnabled(false)
    elseif r.step == "buying" then
      for _, l in ipairs(W.planLines(c.plan)) do body[#body + 1] = l end
      go:SetText("Buying...")
      go:SetEnabled(false)
      skip:SetShown(false)
    elseif r.step == "plan" then
      local p = c.plan
      if c.err then
        body[#body + 1] = c.err
        go:SetText("Try again")
      elseif p and p.got == 0 then
        for _, w in ipairs(c.warn or {}) do warn[#warn + 1] = w end
        go:SetText("Next item")
        skip:SetShown(false)
      elseif p then
        for _, l in ipairs(W.planLines(p)) do body[#body + 1] = l end
        -- how that compares with the usual price (the warning below says it when it's far above)
        local vs = W.vsUsual(p.avg, c.usual)
        if vs and not (c.usual and p.avg > c.usual * PRICEY) then body[#body + 1] = vs end
        for _, w in ipairs(c.warn or {}) do warn[#warn + 1] = w end
        if c.commodity then
          if c.quote then
            go:SetText("Buy for " .. money(c.quote.total))
            if GetMoney() < c.quote.total then
              go:SetEnabled(false)
              warn[#warn + 1] = ("Not enough money: you have %s."):format(money(GetMoney()))
            end
          elseif c.quoting or c.waitReady then
            go:SetText(c.waitReady and "Waiting for the auction house..." or "Getting the price...")
            go:SetEnabled(false)
          else
            go:SetText("Get the price")
          end
        else
          local t = p.take[1]
          go:SetText(("Buy 1 for %s"):format(money(t.unit)))
          if p.got > 1 then body[#body + 1] = ("One click buys one: %d to go."):format(p.got) end
          if GetMoney() < t.unit then
            go:SetEnabled(false)
            warn[#warn + 1] = ("Not enough money: you have %s."):format(money(GetMoney()))
          end
        end
      end
    end
  end
  f.sub:SetText(sub)
  f.body:SetText(table.concat(body, "\n"))
  f.warn:SetText(table.concat(warn, "\n"))
  f.maxLabel:SetShown(showMax)
  f.max:SetShown(showMax)
  if showMax and not f.max:HasFocus() then
    f.max:SetText(c and (c.maxText or c.max and ns.listImport.moneyText(c.max)) or "")
  end
  f.status:SetText(r.status or "")
  f.status:SetTextColor(unpack(r.statusColor or T.dim))
end
W.render = function() render() end

---------------------------------------------------------------------------------------------------------------------
-- /eah buy [list]

local function lists()
  local d = db()
  return d and d.lists or {}
end

-- Starts buying a list and says why when it can't.
function W.begin(l, only)
  local okStart, why = W.start(l, only)
  if okStart then return true end
  if why == "closed" then
    ns.say("open the auction house first, then press Buy this list on the Shopping tab (or /eah buy " .. plain(l and l.name:lower() or "<list>") .. ").")
  elseif why == "empty" then
    ns.say(("%s has no items with an amount to buy. Import a list (Shopping tab, Import) with amounts like \"60 Light Leather\"."):format(plain(l and l.name or "That list")))
  end
  return false
end

local prevSlash, prevHelp = ns.slash, ns.help
function ns.slash(msg)
  local name = msg:match("^buy%s+(.+)$")
  if msg == "buy" then
    local d = db()
    local all = lists()
    local l = all[math.max(1, math.min(d and d.listSel or 1, #all))]
    if not l then ns.say("no shopping lists yet. Import one: /eah import (auction house open)."); return true end
    W.begin(l)
    return true
  end
  if name then
    for _, l in ipairs(lists()) do
      if l.name:lower() == name then W.begin(l); return true end
    end
    local names = {}
    for i, l in ipairs(lists()) do if i <= 5 then names[#names + 1] = plain(l.name:lower()) end end
    ns.say(("no list called \"%s\". %s"):format(plain(name), #names > 0 and ("Your lists: " .. table.concat(names, ", ") .. ".") or "Import one with /eah import."))
    return true
  end
  return prevSlash and prevSlash(msg) or false
end
function ns.help()
  if prevHelp then prevHelp() end
  print("  /eah buy [list]  buy a shopping list item by item;  /eah import  paste a list of items to buy")
end
