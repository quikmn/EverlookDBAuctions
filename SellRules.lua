-- EverlookDB Auctions: sell rules, for Sell all (SellAll.lua). No frames here: what to post, at what price and why,
-- and which of your auctions to cancel. The offline tests (tests/run.py) check it all.
--
-- A rule: which items (a search in the query language, as in Advanced search: `category is "trade goods" and name
-- has cloth`; empty = everything), and how to sell them:
--   floor     the lowest price, a price formula (Formula.lua) that also knows `deposit` (the deposit for one).
--             Default max(vendor + deposit, deposit): never under what a vendor pays plus the deposit.
--   normal    the price when nobody else is selling. Default first(median30, median): the 30-day median, else the
--             usual price at the last full scan.
--   undercut  1c, 1s, 5% or 0 (match); empty = the Undercut by setting.
--   keep      how many to keep in your bags; maxUp: at most this many up at once (0 = no limit); stack: at most this
--             many per post (0 = all); duration 1-3 (12, 24, 48 hours; 0 = as last time).
--   below     what happens when the price would be under the floor: "skip" (don't post), "floor" (post at the floor)
--             or "vendor" (don't post: sell it to a vendor).
-- Rules are in order; an item uses the first one that is on and matches it. The last rule, Everything, matches
-- every item and can't be removed: with no setup, Sell all posts everything at the cheapest price minus your
-- undercut, never under the floor.
-- Saved in EverlookAuctionsDB.sellRules = { list = { rule, ... }, base = rule }.
local _, ns = ...
local R = {}
ns.sellRules = R

R.DEFAULT_FLOOR = "max(vendor + deposit, deposit)"
R.DEFAULT_NORMAL = "first(median30, median)"
R.FRESH = 60          -- seconds a live price is good for: older ones are checked again before a post or a cancel
R.BELOW = {
  { value = "skip", text = "Don't post it" },
  { value = "floor", text = "Post it at the floor" },
  { value = "vendor", text = "Sell it to a vendor" },
}
R.DURATIONS = {
  { value = 0, text = "As last time" },
  { value = 1, text = "12 hours" },
  { value = 2, text = "24 hours" },
  { value = 3, text = "48 hours" },
}

local function money(c) return ns.money and ns.money(c) or (tostring(c) .. "c") end
local function trim(s) return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end
local function int(v, lo)
  v = math.floor(tonumber(v) or 0)
  if v < (lo or 0) then v = lo or 0 end
  return v
end

---------------------------------------------------------------------------------------------------------------------
-- Rules and their storage

function R.newRule(name)
  return { name = name or "New rule", query = "", floor = R.DEFAULT_FLOOR, normal = R.DEFAULT_NORMAL, undercut = "",
    keep = 0, maxUp = 0, stack = 0, duration = 0, below = "skip", on = true }
end

-- Fills what a saved rule lacks (an older or hand-edited one), in place.
function R.norm(r)
  local d = R.newRule()
  for k, v in pairs(d) do if r[k] == nil then r[k] = v end end
  r.name = trim(r.name) ~= "" and trim(r.name) or "Rule"
  r.query, r.undercut = trim(r.query), trim(r.undercut)
  if trim(r.floor) == "" then r.floor = "" end
  if trim(r.normal) == "" then r.normal = "" end
  r.keep, r.maxUp, r.stack = int(r.keep), int(r.maxUp), int(r.stack)
  r.duration = math.min(3, int(r.duration))
  if r.below ~= "floor" and r.below ~= "vendor" then r.below = "skip" end
  return r
end

function R.store(db)
  if not db then return nil end
  db.sellRules = type(db.sellRules) == "table" and db.sellRules or {}
  local s = db.sellRules
  s.list = type(s.list) == "table" and s.list or {}
  if type(s.base) ~= "table" then s.base = R.newRule("Everything") end
  for _, r in ipairs(s.list) do R.norm(r) end
  R.norm(s.base)
  s.base.query, s.base.on, s.base.base = "", true, true
  s.base.name = s.base.name ~= "Rule" and s.base.name or "Everything"
  return s
end

-- Every rule in order, Everything last.
function R.all(db)
  local s = R.store(db)
  if not s then return { R.norm(R.newRule("Everything")) } end
  local out = {}
  for _, r in ipairs(s.list) do out[#out + 1] = r end
  out[#out + 1] = s.base
  return out
end

function R.add(db, rule)
  local s = R.store(db)
  rule = R.norm(rule or R.newRule())
  s.list[#s.list + 1] = rule
  return rule, #s.list
end

-- Moves rule i up (delta -1) or down (+1); Everything stays last. True when it moved.
function R.move(db, i, delta)
  local s = R.store(db)
  local j = i + delta
  if not s.list[i] or not s.list[j] then return false end
  s.list[i], s.list[j] = s.list[j], s.list[i]
  return true
end

function R.remove(db, i)
  local s = R.store(db)
  if not s.list[i] then return false end
  table.remove(s.list, i)
  return true
end

---------------------------------------------------------------------------------------------------------------------
-- Checking what is typed

-- nil when the search can be read, else what is wrong.
function R.checkQuery(text)
  text = trim(text)
  if text == "" or not ns.queryParse then return nil end
  local okP, err = pcall(ns.queryParse, text)
  if okP then return nil end
  return type(err) == "table" and err.query or tostring(err)
end

-- nil when the formula can be read (deposit included), else what is wrong.
function R.checkFormula(text)
  text = trim(text)
  if text == "" or not ns.formulaRow then return nil end
  local v, err = ns.formulaRow(text, {}, { deposit = 0 })
  if v == nil and err then return err end
  return nil
end

-- The undercut of a rule: { copper = n } or { pct = n }; nil for "use the setting"; false and why when it can't be
-- read.
function R.parseUndercut(text)
  text = trim(text):lower():gsub("%s+", "")
  if text == "" then return nil end
  local pct = tonumber(text:match("^(%d+%.?%d*)%%$") or "")
  if pct then
    if pct >= 100 then return false, "an undercut in % is under 100%" end
    return { pct = pct }
  end
  if text == "0" then return { copper = 0 } end
  if text:gsub("%d+[gsc]", "") == "" then
    local total = 0
    for n, unit in text:gmatch("(%d+)([gsc])") do
      total = total + tonumber(n) * (unit == "g" and 10000 or unit == "s" and 100 or 1)
    end
    return { copper = total }
  end
  return false, ('"%s" isn\'t an undercut. Use 1c, 1s, 5%%, 0, or leave it empty for the Undercut by setting.'):format(text)
end

---------------------------------------------------------------------------------------------------------------------
-- Matching

-- Does the rule's search keep this row (a row of the query language: ns.queryItemRow)? An empty search matches all.
function R.matches(rule, row)
  if rule.on == false then return false end
  local q = trim(rule.query)
  if q == "" then return true end
  if not row or not ns.queryRows then return false end
  local out, err = ns.queryRows(q, { row })
  if not out then rule.err = err; return false end
  rule.err = nil
  return #out > 0
end

-- The first rule that is on and matches: the rule and its place (1 = first).
function R.ruleFor(rules, row)
  for i, r in ipairs(rules) do
    if R.matches(r, row) then return r, i end
  end
end

---------------------------------------------------------------------------------------------------------------------
-- Prices

-- The price `u` under p ({ copper } or { pct }), in steps of `step` (1 where the house takes copper, else 100).
-- A fixed undercut never takes more than 5% off (1s under an 80c auction is 79c, not 1c), as Quick sell does.
function R.undercutBy(p, u, step)
  step = step or 1
  u = u or { copper = 100 }
  local new
  if u.pct then
    new = p * (1 - u.pct / 100)
  else
    new = p - (u.copper or 100)
    if p - new > p * 0.05 then new = p - step end
  end
  new = math.floor(new / step) * step
  local wantsBelow = (u.pct and u.pct > 0) or (not u.pct and (u.copper or 0) > 0)
  if wantsBelow and new >= p then new = math.floor((p - 1) / step) * step end
  return math.max(step, new)
end

function R.undercutText(u)
  if not u then return "your undercut" end
  if u.pct then return u.pct == 0 and "matching" or (u.pct .. "%") end
  if (u.copper or 0) == 0 then return "matching" end
  return money(u.copper)
end

-- A formula's value (nil when not known), and the mistake if it can't be read.
local function value(text, row, extra)
  text = trim(text)
  if text == "" or not ns.formulaRow then return nil end
  return ns.formulaRow(text, row, extra)
end

-- The price for one item under a rule. c = {
--   row (query-language row), step, deposit (for one; nil: not known, counted as 0),
--   live = { lowestOther, lowestMine, lone, second, usual } or nil (no live answer: nothing is posted),
--   undercut (the setting, when the rule has none), last (your last price for it) }
-- Returns { action = "post" | "skip" | "vendor", price, floor, normal, cheapest, u, why = { lines }, short }.
-- A posted price is never under the floor.
function R.price(rule, c)
  local step = c.step or 1
  local extra = { deposit = c.deposit or 0 }
  local res = { why = {} }
  local floor, ferr = value(rule.floor, c.row, extra)
  local normal, nerr = value(rule.normal, c.row, extra)
  if ferr then res.why[#res.why + 1] = "Floor can't be read: " .. ferr end
  if nerr then res.why[#res.why + 1] = "Normal price can't be read: " .. nerr end
  if floor then floor = math.ceil(floor / step - 1e-9) * step end
  if normal then normal = math.max(step, math.floor(normal / step + 1e-9) * step) end
  res.floor, res.normal = floor, normal
  local u = R.parseUndercut(rule.undercut)
  if not u then u = c.undercut or { copper = 100 } end
  res.u = u
  local e = c.live
  local price, how
  if e and e.lowestOther and (not e.lowestMine or e.lowestOther < e.lowestMine) then
    local target = e.lowestOther
    if e.lone and e.second then
      target = e.second
      how = ("%s under the next cheapest, %s (skipped a lone one at %s)"):format(R.undercutText(u), money(target), money(e.lowestOther))
    else
      how = ("%s under the cheapest, %s"):format(R.undercutText(u), money(target))
    end
    if R.undercutText(u) == "matching" then how = how:gsub("^matching under", "Matches") end
    res.cheapest = target
    price = R.undercutBy(target, u, step)
  elseif e and e.lowestMine then
    price, how = e.lowestMine, ("Matches your own cheapest auction, %s"):format(money(e.lowestMine))
    res.cheapest = e.lowestOther
  elseif normal then
    price, how = normal, ("Nobody else is selling: your normal price, %s"):format(money(normal))
  elseif c.last then
    price, how = math.max(step, math.floor(c.last / step) * step), ("Nobody else is selling: your last price, %s"):format(money(c.last))
  else
    res.action = "skip"
    res.short = "no price"
    table.insert(res.why, 1, e and "Nobody else is selling and the normal price isn't known yet: set one in the rule."
      or "No live price yet.")
    return res
  end
  if floor and price < floor then
    if rule.below == "floor" then
      how = how .. (", under your floor: posted at the floor, %s"):format(money(floor))
      price = floor
    elseif rule.below == "vendor" then
      res.action, res.price, res.short = "vendor", price, "sell to a vendor"
      table.insert(res.why, 1, how .. (" is under your floor, %s: sell it to a vendor instead."):format(money(floor)))
      return res
    else
      res.action, res.price, res.short = "skip", price, "under the floor"
      table.insert(res.why, 1, how .. (" is under your floor, %s: not posted."):format(money(floor)))
      return res
    end
  end
  price = math.max(step, price)
  if floor and price < floor then price = floor end   -- never under the floor, whatever the rounding did
  res.action, res.price = "post", price
  table.insert(res.why, 1, how .. ".")
  return res
end

-- What the rule says about one item, for the "why" line: "Rule Cloth · floor 12c (max(vendor + deposit, deposit))".
function R.explain(rule, res)
  local bits = { "Rule " .. rule.name }
  bits[#bits + 1] = "floor " .. (res.floor and money(res.floor) or "none") .. (trim(rule.floor) ~= "" and (" = " .. rule.floor) or "")
  bits[#bits + 1] = "normal " .. (res.normal and money(res.normal) or "not known") .. (trim(rule.normal) ~= "" and (" = " .. rule.normal) or "")
  bits[#bits + 1] = "undercut " .. R.undercutText(res.u)
  return table.concat(bits, "  ·  ")
end

---------------------------------------------------------------------------------------------------------------------
-- How many

-- How many to post: what you have minus what to keep, no more than fit under "at most N up", in posts of at most
-- `stack`. Returns n and, when n is 0, why.
function R.quantity(rule, have, up)
  have, up = have or 0, up or 0
  local n = have - (rule.keep or 0)
  if n <= 0 then
    return 0, (rule.keep or 0) > 0 and ("keeping %d in your bags"):format(rule.keep) or "none in your bags"
  end
  if (rule.maxUp or 0) > 0 then
    local room = rule.maxUp - up
    if room <= 0 then return 0, ("%d up already (at most %d)"):format(up, rule.maxUp) end
    n = math.min(n, room)
  end
  if (rule.stack or 0) > 0 then n = math.min(n, rule.stack) end
  return n
end

---------------------------------------------------------------------------------------------------------------------
-- The post queue

-- Builds the queue from your bags. groups: Quick sell's items ({ key, id, count, name, ... }, in its order).
-- o = { rules, rowOf(g), upOf(g) (how many are up), hidden(g) (true: left out) }.
-- Entries: { g, rule, ruleIndex, qty, why (when qty is 0) }; items no rule matches aren't in it.
function R.queue(groups, o)
  local out = {}
  for _, g in ipairs(groups or {}) do
    if not (o.hidden and o.hidden(g)) then
      local rule, idx = R.ruleFor(o.rules, o.rowOf and o.rowOf(g) or nil)
      if rule then
        local qty, why = R.quantity(rule, g.count, o.upOf and o.upOf(g) or 0)
        out[#out + 1] = { g = g, rule = rule, ruleIndex = idx, qty = qty, why = why }
      end
    end
  end
  return out
end

-- Entries still to do: not done, not skipped, something to post.
function R.open(entry) return entry.qty > 0 and not entry.done and not entry.skipped end

-- The first open entry from position `from` (wrapping round), or nil.
function R.nextOpen(entries, from)
  local n = #entries
  from = from or 1
  for k = 0, n - 1 do
    local i = (from - 1 + k) % n + 1
    if R.open(entries[i]) then return i end
  end
end

-- Where an entry stands, for the one button. x = { done, posting, warned, held, live = { at, ... } or nil,
-- job (a search is out), result (R.price over that live answer) }.
--   "check"     no fresh live price: a click asks for one (one search)
--   "checking"  the search is out
--   "post"      a fresh price: a click posts (one post)
--   "wait"      a fresh price, but the button rests a moment after the queue moved (no double posts)
--   "confirm"   the auction house asks to confirm: a click confirms (one call)
--   "posting"   the post is out; "skip" the rule says don't post; "done"
function R.state(x, now)
  if x.done then return "done" end
  if x.posting then return "posting" end
  if x.warned then return "confirm" end
  local e = x.live
  if e and e.at and now - e.at <= R.FRESH then
    local res = x.result
    if res and res.action == "post" then return x.held and "wait" or "post" end
    return "skip"
  end
  if x.job then return "checking" end
  return "check"
end

-- The one auction house call a click makes in a state: "search", "post", "confirm", "cancel" or nil (none).
function R.clickCall(state, cancelling)
  if state == "check" then return "search" end
  if state == "post" then return cancelling and "cancel" or "post" end
  if state == "confirm" then return "confirm" end
  return nil
end

---------------------------------------------------------------------------------------------------------------------
-- Cancel undercut

-- Your auctions someone else is now cheaper than. owned: Quick sell's list ({ id, itemID, ckey, unit, qty, sold,
-- hasBid, name }). o = { live(a) -> live answer or nil, rule(a) -> rule, row(a), step, undercut (the setting),
-- deposit(a) (for one, or nil), sure(a) (false: a stackable good whose own price isn't sure yet), now }.
-- Each: { a, cheapest, by, repost, floor, ok, fresh, why }. The ones to cancel (ok) come first, most undercut first;
-- ones kept because a repost would go under the floor come after, with why.
function R.cancelQueue(owned, o)
  local ok, kept = {}, {}
  local step = o.step or 1
  for _, a in ipairs(owned or {}) do
    local e = not a.sold and a.unit and o.live(a) or nil
    if e and e.lowestOther and (not o.sure or o.sure(a) ~= false) then
      local target = (e.lone and e.second) or e.lowestOther
      if target < a.unit then
        local rule = o.rule and o.rule(a) or R.newRule("Everything")
        local u = R.parseUndercut(rule.undercut) or o.undercut or { copper = 100 }
        local repost = R.undercutBy(target, u, step)
        local floor = value(rule.floor, o.row and o.row(a) or nil, { deposit = o.deposit and o.deposit(a) or 0 })
        if floor then floor = math.ceil(floor / step - 1e-9) * step end
        local c = { a = a, cheapest = target, by = a.unit - target, repost = repost, floor = floor, rule = rule,
          fresh = e.at ~= nil and (o.now or 0) - e.at <= R.FRESH }
        if a.hasBid then
          c.why = "It has a bid, so it can't be cancelled."
          kept[#kept + 1] = c
        elseif floor and repost < floor then
          c.why = ("Undercut to %s, but posting again at %s would be under your floor, %s: kept up."):format(
            money(target), money(repost), money(floor))
          kept[#kept + 1] = c
        else
          c.ok = true
          c.why = ("Undercut by %s: %s is up at %s. Post it again at %s after."):format(money(c.by), a.name or "it",
            money(target), money(repost))
          ok[#ok + 1] = c
        end
      end
    end
  end
  table.sort(ok, function(x, y)
    if x.by ~= y.by then return x.by > y.by end
    return (x.a.id or 0) < (y.a.id or 0)
  end)
  for _, c in ipairs(kept) do ok[#ok + 1] = c end
  return ok
end

---------------------------------------------------------------------------------------------------------------------
-- The button's words

-- "Post 20 Linen Cloth · 12s each (3 of 14)"
function R.postLabel(entry, price, pos, total)
  return ("Post %d %s · %s each (%d of %d)"):format(entry.qty, entry.g.name, money(price), pos, total)
end

-- "Cancel Silk Cloth · undercut by 5s (1 of 4)"
function R.cancelLabel(c, pos, total)
  return ("Cancel %s · undercut by %s (%d of %d)"):format(c.a.name or "auction", money(c.by), pos, total)
end
