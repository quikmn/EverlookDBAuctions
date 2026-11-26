-- EverlookDB Auctions: the profit finder (the logic, no frames; ProfitWindow.lua has the window).
--   For every recipe you know (db.crafts, read when a profession window opens, Purchases.lua): what one craft costs,
--   what it sells for on the auction house after the cut, and the profit. A material costs the cheaper of its lowest
--   AH price and crafting it yourself from a recipe you know (bars, bolts), worked out the same way all the way down;
--   a loop (a transmute and its way back) is cut, never followed twice. A material with neither price is left out of
--   the cost and the row is marked approximate (its real profit is lower). Nothing is guessed: no vendor or made-up
--   fallback prices.
--   Shopping: the picked recipes and how many crafts of each become what to buy, with the materials cheaper to craft
--   broken down into their own materials, minus what is in your bags and bank.
--   Also the list's sorting and filters, money split into gold/silver/copper cells for its columns, the money boxes'
--   parsing, and the saved settings' migration (all without frames, for the tests).
local _, ns = ...
local Pr = {}
ns.profit = Pr

Pr.STALE = 24 * 3600    -- prices older than this show as old
Pr.MAX_DEPTH = 8        -- how deep materials are broken down (bolts into cloth; deeper chains don't exist)

-- A context for one pass: ctx = { recipes = { [itemID made] = { mats = { { id, need } }, makes, rid, name } },
-- price = fn(id) -> copper each, when seen (nil when unknown), cut = 0.05, craftMats = true (false: buy everything),
-- info = fn(id) -> skill, profession (optional), paid = { [id] = { unit, q, c, t } } (what you paid lately, from
-- Pr.paidPrices: a material you bought costs that, not the market price) }.
function Pr.context(opts)
  local ctx = {}
  for k, v in pairs(opts or {}) do ctx[k] = v end
  ctx.recipes = ctx.recipes or {}
  ctx.cut = tonumber(ctx.cut) or 0.05
  ctx.memo, ctx.busy = {}, {}
  return ctx
end

local function older(a, b)
  if not a then return b end
  if not b then return a end
  return math.min(a, b)
end

local costOf

-- What one craft of r takes, at the cheapest way to get each material: copper, how many materials have no price, the
-- ids without a price, the oldest price used, and whether a loop was cut on the way.
local function craftCost(ctx, r, depth)
  local total, unpriced, missing, oldest, cut, paidIn = 0, 0, {}, nil, false, false
  for _, m in ipairs(r.mats or {}) do
    local c, sub = costOf(ctx, m[1], depth + 1)
    cut = cut or sub
    if c.cost then
      total = total + c.cost * (m[2] or 1)
      oldest = older(oldest, c.oldest)
      paidIn = paidIn or c.paid ~= nil or c.paidIn or false
    else
      unpriced = unpriced + 1
      for _, id in ipairs(c.missing) do missing[#missing + 1] = id end
    end
  end
  return total, unpriced, missing, oldest, cut, paidIn
end

-- The cheapest way to get one of an item: { cost = copper or nil, how = "buy"/"craft"/nil, oldest = when the
-- oldest price used was seen, missing = { ids without a price } }, and whether a loop was cut below it (such an
-- answer isn't remembered, since it depends on where the walk came from).
function costOf(ctx, id, depth)
  local known = ctx.memo[id]
  if known then return known, false end
  -- bought lately: what you paid is what it costs (you have them), whatever the market says now
  local pd = ctx.paid and ctx.paid[id]
  if pd and pd.unit then
    known = { cost = pd.unit, how = "buy", paid = pd, missing = {} }
    ctx.memo[id] = known
    return known, false
  end
  local buy, at = ctx.price(id)
  local best = buy and { cost = buy, how = "buy", oldest = at, missing = {} } or nil
  local r = ctx.craftMats ~= false and ctx.recipes[id]
  local cut = false
  if r then
    if ctx.busy[id] or (depth or 0) >= Pr.MAX_DEPTH then
      cut = true
    else
      ctx.busy[id] = true
      local total, unpriced, missing, oldest, sub, paidIn = craftCost(ctx, r, depth or 0)
      ctx.busy[id] = nil
      cut = sub
      local each = unpriced == 0 and total / math.max(r.makes or 1, 0.01) or nil
      if each and (not best or each < best.cost) then
        best = { cost = each, how = "craft", oldest = oldest, missing = {}, paidIn = paidIn or nil }
      elseif not best then
        best = { missing = #missing > 0 and missing or { id } }
      end
    end
  end
  best = best or { missing = { id } }
  if not cut then ctx.memo[id] = best end
  return best, cut
end

function Pr.unitCost(ctx, id) return (costOf(ctx, id, 0)) end

-- One recipe's row: { id (made), rid, name, makes, cost (copper per craft), unpriced, missing, approx, low (AH price
-- each of what it makes), lowAt, sale (what one craft's yield brings after the cut), profit, margin (profit / cost),
-- oldest (the oldest price used), skill, profession, paid (true when a material's cost is what you paid), mats =
-- { { id, need, each, how, paid = { unit, q, c, t } (bought lately), paidIn (made from such), market (AH price each) } } }.
function Pr.row(ctx, out, r)
  ctx.busy[out] = true   -- a loop back to what is being made is cut
  local row = { id = out, rid = r.rid, name = r.name, makes = r.makes or 1, cost = 0, unpriced = 0, missing = {}, mats = {} }
  for _, m in ipairs(r.mats or {}) do
    local c = costOf(ctx, m[1], 1)
    row.mats[#row.mats + 1] = { id = m[1], need = m[2] or 1, each = c.cost, how = c.how, paid = c.paid, paidIn = c.paidIn,
      market = c.paid and (ctx.price(m[1])) or nil }
    if c.paid or c.paidIn then row.paid = true end
    if c.cost then
      row.cost = row.cost + c.cost * (m[2] or 1)
      row.oldest = older(row.oldest, c.oldest)
    else
      row.unpriced = row.unpriced + 1
      for _, id in ipairs(c.missing) do row.missing[#row.missing + 1] = id end
    end
  end
  ctx.busy[out] = nil
  row.cost = math.floor(row.cost + 0.5)
  row.approx = row.unpriced > 0
  row.low, row.lowAt = ctx.price(out)
  if row.low then
    row.sale = math.floor(row.low * row.makes * (1 - ctx.cut) + 0.5)
    row.profit = row.sale - row.cost
    row.margin = row.cost > 0 and row.profit / row.cost or nil
    row.oldest = older(row.oldest, row.lowAt)
  end
  if ctx.info then row.skill, row.profession = ctx.info(out) end
  return row
end

---------------------------------------------------------------------------------------------------------------------
-- What you paid, and Check prices

Pr.PAID_DAYS = 3     -- materials bought this lately cost what you paid
Pr.DROP = 0.3        -- Check prices: a result selling this much below what the page showed is taken out of the queue
Pr.THIN = 0.15       -- Check prices: a margin under this is "thin"

-- What you paid for each item lately, from the AH log (db.bought): { [id] = { unit = copper each (the average over
-- the purchases), q, c (copper in all), t = the newest purchase } }. Only purchases at this auction house (house =
-- "Realm-Side"; nil: any), within `days` of now.
function Pr.paidPrices(bought, house, now, days)
  local since = (tonumber(now) or 0) - (tonumber(days) or Pr.PAID_DAYS) * 86400
  local out = {}
  for _, e in ipairs(type(bought) == "table" and bought or {}) do
    local id, q, c, t = tonumber(e.id), tonumber(e.q), tonumber(e.c), tonumber(e.t)
    if id and q and q > 0 and c and c > 0 and t and t >= since and (not house or not e.h or e.h == house) then
      local p = out[id] or { q = 0, c = 0 }
      p.q, p.c = p.q + q, p.c + c
      if not p.t or t > p.t then p.t = t end
      out[id] = p
    end
  end
  for _, p in pairs(out) do p.unit = p.c / p.q end
  return out
end

-- Whether a queued recipe turned bad at today's prices: "drop" (what it makes sells for more than Pr.DROP below
-- what the page showed), "loss" (no profit any more), or nil (still good, or no price to tell by).
function Pr.verdict(before, after, drop)
  if not (after and after.low) then return nil end
  drop = tonumber(drop) or Pr.DROP
  if before and before.low and after.low < before.low * (1 - drop) then return "drop" end
  if after.profit and after.profit <= 0 then return "loss" end
  return nil
end

-- The Check prices message: items = { { name, n (crafts), made (items it makes), verdict, was, now (lowest price of
-- what it makes, before and now), profit (all crafts, now), costNow (materials of all crafts at today's listings),
-- costWas (what the table said), margin (profit / cost, now), listed (of what it makes, now), short (a material with
-- fewer listed than needed) }. Each recipe gets a verdict: good, thin (a margin under Pr.THIN) or not worth it.
-- money(copper) -> text. Returns the lines (a heading for each group) and the names taken out.
function Pr.checkLines(items, money)
  money = money or Pr.short
  local out, gone, good = {}, {}, {}
  for _, it in ipairs(items or {}) do
    if it.verdict then gone[#gone + 1] = it else good[#good + 1] = it end
  end
  local function sign(c) return (c > 0 and "+" or "") .. money(c) end
  if #gone > 0 then
    local parts = {}
    for _, it in ipairs(gone) do
      if it.verdict == "drop" then
        parts[#parts + 1] = ("%s: sells for %s now (was %s)"):format(it.name, money(it.now), money(it.was))
      else
        parts[#parts + 1] = ("%s: %s profit at today's prices"):format(it.name, sign(it.profit or 0))
      end
    end
    out[#out + 1] = "Not worth it, taken out of the queue: " .. table.concat(parts, "; ") .. "."
  end
  for _, it in ipairs(good) do
    local line
    if it.profit and it.margin and it.margin < Pr.THIN then
      line = ("Thin: %s, %s profit (%d%% margin) at today's prices."):format(it.name, sign(it.profit),
        math.floor(it.margin * 100 + 0.5))
    elseif it.profit then
      line = ("Good: %s, %s profit at today's prices."):format(it.name, sign(it.profit))
    else
      line = ("%s: no price to check it by."):format(it.name)
    end
    local was, now = tonumber(it.costWas), tonumber(it.costNow)
    if was and now and math.abs(now - was) >= math.max(100, was * 0.15) then
      line = line .. (" Mats for %d: %s at today's listings (the table said %s)."):format(it.n or 1, money(now), money(was))
    end
    if it.short then line = line .. (" Not enough %s listed for all of them."):format(it.short) end
    if it.listed and it.made and it.made > it.listed then
      line = line .. (" %d vs %d listed: selling them all may take a while or lower the price."):format(it.made, it.listed)
    end
    out[#out + 1] = line
  end
  local names = {}
  for _, it in ipairs(gone) do names[#names + 1] = it.name end
  return out, names
end

-- Can a crafter make one craft of r now? count(id) -> how many of the material they have.
function Pr.canMake(r, count)
  if not r or count == nil then return false end
  for _, m in ipairs(r.mats or {}) do
    if (tonumber(count(m[1])) or 0) < (m[2] or 1) then return false end
  end
  return true
end

-- The recipes of several crafters as one: sources = { { key, name, class, me, recipes = { [item made] = recipe } } },
-- you first. The first source with a recipe for an item gives its materials. Returns the recipes and who knows each:
-- { [item made] = { source, ... } } in the sources' order.
function Pr.merge(sources)
  local recipes, who = {}, {}
  for _, src in ipairs(sources or {}) do
    for id, r in pairs(src.recipes or {}) do
      if not recipes[id] then recipes[id] = r end
      who[id] = who[id] or {}
      who[id][#who[id] + 1] = src
    end
  end
  return recipes, who
end

local function lower(s) return tostring(s or ""):lower() end

-- Every recipe that passes the filter, best profit first. filter = { from, to (skill), min (copper), q (words in the
-- name, any case; nameOf(row) gives it when row.name is nil), minMargin (whole percent), maxCost (copper), who
-- ({ [item] = { crafter } } from Pr.merge), canMake (fn(crafter, recipe) -> true when that crafter has the materials
-- now: only those crafters are kept, and a row nobody can make now is left out) }. A recipe whose skill isn't known
-- passes only while the skill range is the whole 1-300. A row with an unpriced material has no real margin, so a
-- margin filter leaves it out. Rows get who = the crafters that pass. Returns the rows and the counts:
-- { known = recipes known, noSale = recipes whose result has no AH price, approx = rows with an unpriced material }.
function Pr.list(ctx, filter)
  filter = filter or {}
  local from, to = tonumber(filter.from) or 1, tonumber(filter.to) or 300
  local whole = from <= 1 and to >= 300
  local min = tonumber(filter.min)
  local minMargin, maxCost = tonumber(filter.minMargin), tonumber(filter.maxCost)
  local learnMax = tonumber(filter.learnMax)   -- recipes you don't know: the cheapest way to learn, at most
  local q = filter.q and lower(filter.q):gsub("^%s+", ""):gsub("%s+$", "") or ""
  local out, counts = {}, { known = 0, noSale = 0, approx = 0 }
  for id, r in pairs(filter.recipes or ctx.recipes) do
    counts.known = counts.known + 1
    local row = Pr.row(ctx, id, r)
    row.recipe = r
    if r.start then
      row.start = r.start
      row.skill = r.start.need or row.skill
      row.profession = r.start.prof or row.profession
      row.payback = Pr.payback(r.start.cost, row.profit)
    end
    local s = row.skill
    local inRange = s and s >= from and s <= to or (not s and whole)
    if not row.sale then
      if inRange then counts.noSale = counts.noSale + 1 end
    elseif inRange and (not min or row.profit >= min)
      and (not maxCost or row.cost <= maxCost)
      and (not minMargin or (row.margin and not row.approx and row.margin * 100 >= minMargin - 1e-9))
      and (not filter.onAH or (row.start and row.start.ah))
      and (not learnMax or (row.start and row.start.cost and row.start.cost <= learnMax))
      and (q == "" or lower(row.name or (filter.nameOf and filter.nameOf(row))):find(q, 1, true)) then
      local who = filter.who and filter.who[id]
      local keep = true
      if filter.canMake then
        -- without a who list the crafter is you ({})
        local can = {}
        for _, c in ipairs(who or { {} }) do if filter.canMake(c, r) then can[#can + 1] = c end end
        keep = #can > 0
        if who then who = can end
      end
      row.who = who
      if keep then
        out[#out + 1] = row
        if row.approx then counts.approx = counts.approx + 1 end
      end
    end
  end
  table.sort(out, function(a, b)
    if a.profit ~= b.profit then return a.profit > b.profit end
    return tostring(a.name or a.id) < tostring(b.name or b.id)
  end)
  return out, counts
end

-- What a selection costs and makes: picks = { { row = row, crafts = n } }. Returns gold in (material cost), profit
-- (what selling brings after the cut, minus that) and how many crafts; approx when a row has an unpriced material.
function Pr.totals(picks)
  local cost, profit, crafts, approx = 0, 0, 0, false
  for _, p in ipairs(picks or {}) do
    local n = math.max(0, math.floor(tonumber(p.crafts) or 0))
    if n > 0 and p.row then
      cost = cost + (p.row.cost or 0) * n
      profit = profit + (p.row.profit or 0) * n
      crafts = crafts + n
      approx = approx or p.row.approx
    end
  end
  return cost, profit, crafts, approx
end

-- What to buy for the picks: materials cheaper to craft are broken down into their own materials; what you have
-- (haveOf, bags and bank) is used first, intermediates included. Returns { { id, need, have, buy } } in first-seen
-- order. Counts are whole items (a recipe that makes 2 at a time needs half the crafts, rounded up).
function Pr.shopping(ctx, picks, haveOf)
  local left, need, order = {}, {}, {}
  local function have(id)
    if left[id] == nil then left[id] = math.max(0, math.floor(tonumber(haveOf and haveOf(id)) or 0)) end
    return left[id]
  end
  local function leaf(id, units)
    if not need[id] then need[id] = 0; order[#order + 1] = id end
    need[id] = need[id] + units
  end
  local function expand(id, units, depth, path)
    local c = Pr.unitCost(ctx, id)
    local r = ctx.recipes[id]
    if c.how == "craft" and r and depth < Pr.MAX_DEPTH and not path[id] then
      local h = have(id)
      local use = math.min(h, units)
      left[id] = h - use
      units = units - use
      if units <= 0 then return end
      local crafts = math.ceil(units / math.max(r.makes or 1, 0.01) - 1e-9)
      path[id] = true
      for _, m in ipairs(r.mats or {}) do expand(m[1], (m[2] or 1) * crafts, depth + 1, path) end
      path[id] = nil
    else
      leaf(id, units)
    end
  end
  for _, p in ipairs(picks or {}) do
    local n = math.max(0, math.floor(tonumber(p.crafts) or 0))
    local r = p.row and (ctx.recipes[p.row.id] or p.row.recipe)   -- a recipe you don't know yet: its own row's
    if n > 0 and r then
      for _, m in ipairs(r.mats or {}) do expand(m[1], (m[2] or 1) * n, 1, { [p.row.id] = true }) end
    end
  end
  local rows = {}
  for _, id in ipairs(order) do
    local units = math.ceil(need[id] - 1e-9)
    local h = have(id)
    rows[#rows + 1] = { id = id, need = units, have = h, buy = math.max(0, units - h) }
  end
  return rows
end

-- The skill and profession of what a recipe makes, from Data.lua (classic-db): nil when not known.
function Pr.info(id)
  local d = ns.ITEMDATA and ns.ITEMDATA[id]
  if not d or not d[1] then return nil end
  local crafted = math.floor(d[1] / 2) % 2 == 1   -- source bit 2: crafted
  if not crafted or not d[3] or d[3] <= 0 then return nil end
  return d[3], ns.PROFESSIONS and ns.PROFESSIONS[d[2] or 0]
end

---------------------------------------------------------------------------------------------------------------------
-- Recipes you don't know yet (the "Easy to get" and "All recipes" scopes, from EverlookDB Crafting's recipe data)

-- The scopes: the recipes you know, the ones easy to learn (a trainer, a vendor or the auction house, at most EASY
-- skill points above yours), and every recipe of every profession. The default sort of the other two is margin.
Pr.SCOPES = { known = true, easy = true, all = true }
Pr.EASY = 25

-- After how many crafts the recipe has paid for itself: learn cost / profit per craft, rounded up; nil when it costs
-- nothing, has no known cost, or makes no profit.
function Pr.payback(cost, profit)
  cost, profit = tonumber(cost), tonumber(profit)
  if not cost or cost <= 0 or not profit or profit <= 0 then return nil end
  return math.ceil(cost / profit - 1e-9)
end

local HOW_WORDS = { drop = "drops", quest = "quest", rep = "reputation", dungeon = "dungeon drop", world = "world drop",
  fish = "fishing", container = "container", chest = "chest", object = "found in the world", cur = "currency",
  limited = "limited vendor" }

-- How to start making a recipe you don't know: e = one of EverlookDB Crafting's api.allRecipes() rows, ahPrice(item)
-- = the recipe item's cheapest price at the auction house (nil when it isn't there), rank = your skill in its
-- profession (nil: you don't have it). Returns { how = "trainer" / "vendor" / "ah" / other ways ("drops", "quest",
-- ...) / "unknown", cost (copper, nil when not known), fee, vendor, ah (AH price of the recipe item), item, need
-- (skill), rank, prof, easy (a trainer, vendor or the AH, at most Pr.EASY points above your skill) }. The cheapest
-- of the ways with a price wins.
function Pr.start(e, ahPrice, rank)
  local st = { item = e.item, need = tonumber(e.learn), rank = rank, prof = e.prof, fee = e.fee }
  local ways = {}
  if (e.tier == 0 or e.trained or e.auto) and (not e.item or e.trained or e.auto) then
    ways[#ways + 1] = { "trainer", (e.fee or 0) }
  end
  if e.item and (e.tier == 1 or e.tier == 2) and e.price and e.price > 0 then
    st.vendor = e.price
    ways[#ways + 1] = { "vendor", e.price + (e.fee or 0) }
  end
  if e.item and ahPrice then
    st.ah = ahPrice(e.item)
    if st.ah then ways[#ways + 1] = { "ah", st.ah + (e.fee or 0) } end
  end
  table.sort(ways, function(a, b) return a[2] < b[2] end)
  if ways[1] then
    st.how, st.cost = ways[1][1], ways[1][2]
  else
    local w = e.why ~= "" and e.why or nil
    st.how = (w and w ~= "unknown" and (HOW_WORDS[w] or w)) or (e.item and "pattern") or "unknown"
  end
  local near = rank ~= nil and (st.need or 1) <= rank + Pr.EASY
  st.easy = near and (st.how == "trainer" or st.how == "vendor" or st.how == "ah") or false
  return st
end

-- The recipes of a scope, as Pr.list takes them: { [item made] = { mats, makes, rid, name, start } }. all = EverlookDB
-- Crafting's api.allRecipes(), known = { [item made] = true } (yours and your alts' that the list counts), ranks =
-- { [skill line] = your skill }. "easy": only easy ones in your professions; "all": every one. One recipe per item:
-- the cheapest to start.
function Pr.scopeRecipes(scope, all, known, ranks, ahPrice)
  local out = {}
  known, ranks = known or {}, ranks or {}
  for _, e in ipairs(all or {}) do
    local id = e.creates
    if id and not known[id] then
      local st = Pr.start(e, ahPrice, ranks[e.skill])
      if scope == "all" or (scope == "easy" and st.easy) then
        local have = out[id]
        if not have or (st.cost or math.huge) < (have.start.cost or math.huge) then
          out[id] = { mats = e.mats, makes = tonumber(e.yield) or 1, rid = e.spell, name = e.name, start = st }
        end
      end
    end
  end
  return out
end

-- The short "to start" text in a row: "trainer 1g 20s", "AH 4g", "vendor 50s", "drops", "source unknown".
function Pr.startText(st)
  if not st then return "" end
  if st.how == "trainer" then return st.cost and st.cost > 0 and ("trainer " .. Pr.short(st.cost)) or "trainer" end
  if st.how == "vendor" then return "vendor " .. Pr.short(st.cost) end
  if st.how == "ah" then return "AH " .. Pr.short(st.cost) end
  if st.how == "unknown" then return "source unknown" end
  return st.how
end

-- "Needs 225 Tailoring, you're 180." / "You don't have Tailoring." / nil when you have the skill.
function Pr.skillText(st)
  if not st then return nil end
  local prof = st.prof or "this profession"
  if st.rank == nil then return ("You don't have %s; it needs %d."):format(prof, st.need or 1) end
  if (st.need or 1) > st.rank then return ("Needs %d %s, you're %d."):format(st.need, prof, st.rank) end
  return nil
end

-- "Recipe 4g, profit 1g 20s per craft: pays back after 4 crafts."
function Pr.paybackText(st, profit, money)
  money = money or Pr.short
  if not st or not st.cost or st.cost <= 0 then return nil end
  local n = Pr.payback(st.cost, profit)
  if not n then return ("Learning costs %s; no profit per craft to pay it back."):format(money(st.cost)) end
  return ("Learning %s, profit %s per craft: pays back after %d %s."):format(money(st.cost), money(profit), n,
    n == 1 and "craft" or "crafts")
end

---------------------------------------------------------------------------------------------------------------------
-- Sorting the list by a column

-- The columns the list sorts by, and which way a first click sorts (true: high to low).
Pr.SORTS = { name = false, skill = false, cost = false, sale = true, profit = true, margin = true, crafts = true }

-- Sorts rows in place by a column (Pr.SORTS; anything else is profit), desc = high to low. A row without a value
-- (unknown skill, no real margin) goes last either way; ties go by profit, high first, then name. opt = { nameOf(row),
-- crafts = { [item] = planned crafts } }.
function Pr.sort(rows, key, desc, opt)
  opt = opt or {}
  if Pr.SORTS[key] == nil then key = "profit" end
  local names = {}
  local function name(r)
    local n = names[r]
    if not n then
      n = lower(r.name or (opt.nameOf and opt.nameOf(r)) or r.id)
      names[r] = n
    end
    return n
  end
  local function value(r)
    if key == "name" then return name(r) end
    if key == "margin" then return (not r.approx) and r.margin or nil end
    if key == "crafts" then return (opt.crafts and opt.crafts[r.id]) or 0 end
    return r[key]
  end
  table.sort(rows, function(a, b)
    local va, vb = value(a), value(b)
    if va ~= vb then
      if va == nil then return false end
      if vb == nil then return true end
      if desc then return va > vb end
      return va < vb
    end
    if a.profit ~= b.profit then return (a.profit or 0) > (b.profit or 0) end
    return name(a) < name(b)
  end)
  return rows
end

---------------------------------------------------------------------------------------------------------------------
-- Money in columns: gold, silver and copper each in a cell of its own, so the coins line up down the list

Pr.COIN = {
  "|TInterface\\MoneyFrame\\UI-GoldIcon:0:0:2:0|t",
  "|TInterface\\MoneyFrame\\UI-SilverIcon:0:0:2:0|t",
  "|TInterface\\MoneyFrame\\UI-CopperIcon:0:0:2:0|t",
}

local function group(n)
  local s = tostring(n):reverse():gsub("(%d%d%d)", "%1,"):reverse()
  return (s:gsub("^,", ""))
end

-- Copper as its parts: gold, silver, copper (whole, of the amount without its sign) and whether it is below 0.
function Pr.coinParts(c)
  c = tonumber(c) or 0
  local neg = c < 0
  c = math.floor(math.abs(c) + 0.5)
  return math.floor(c / 10000), math.floor(c / 100) % 100, c % 100, neg and c > 0
end

-- The three cells of an amount: { gold, silver, copper } texts with their coin icons, "" for a part that is 0 (0 itself
-- is "0" copper). The text in front (opt.prefix, "≈ "; then "-" below 0, or "+" above 0 with opt.sign) goes on the
-- biggest part shown, so every part stays in its column. nil copper is "?" in the copper cell.
function Pr.coinCells(c, opt)
  opt = opt or {}
  if c == nil then return { "", "", "?" } end
  local g, s, cc, neg = Pr.coinParts(c)
  local cells = { g > 0 and (group(g) .. Pr.COIN[1]) or "", s > 0 and (s .. Pr.COIN[2]) or "", cc > 0 and (cc .. Pr.COIN[3]) or "" }
  if g == 0 and s == 0 and cc == 0 then cells[3] = "0" .. Pr.COIN[3] end
  local lead = (opt.prefix or "") .. (neg and "-" or ((opt.sign and tonumber(c) > 0) and "+" or ""))
  if lead ~= "" then
    for i = 1, 3 do
      if cells[i] ~= "" then cells[i] = lead .. cells[i]; break end
    end
  end
  return cells
end

-- Copper as text for a box: "1g 20s 5c", "15s", "0c" (no icons, parts that are 0 left out).
function Pr.moneyText(c)
  if not tonumber(c) then return "" end
  local g, s, cc, neg = Pr.coinParts(c)
  local out = {}
  if g > 0 then out[#out + 1] = g .. "g" end
  if s > 0 then out[#out + 1] = s .. "s" end
  if cc > 0 or #out == 0 then out[#out + 1] = cc .. "c" end
  return (neg and "-" or "") .. table.concat(out, " ")
end

-- What a money box says, as copper: "1g 20s", "1g20s5c", "120s", "1.2g", "1,000g", or a plain number, which is silver
-- (the box was silver before). Returns copper, true; nil, true for an empty box; nil, false when it isn't money.
function Pr.parseMoney(text)
  local t = lower(text):gsub(",", ""):gsub("^%s+", ""):gsub("%s+$", "")
  if t == "" then return nil, true end
  local plain = tonumber(t:match("^(%d*%.?%d+)$") or "")
  if plain then return math.floor(plain * 100 + 0.5), true end
  local total, seen = 0, {}
  local rest = t:gsub("(%d*%.?%d+)%s*([gsc])", function(n, unit)
    if seen[unit] then seen.twice = true end
    seen[unit] = true
    total = total + tonumber(n) * (unit == "g" and 10000 or unit == "s" and 100 or 1)
    return ""
  end)
  if seen.twice or not rest:match("^%s*$") or not next(seen) then return nil, false end
  return math.floor(total + 0.5), true
end

---------------------------------------------------------------------------------------------------------------------
-- The window's saved settings (db.profit)

Pr.SETTINGS_VERSION = 2

-- Puts saved settings right, once: v1 (before the column filters) had from, to and min (copper, from the silver box
-- and the "profitmin" setting, which stays silver); anything that isn't a number in range is dropped. Sort and the
-- new filters start empty (profit, high to low). Returns s.
function Pr.migrate(s)
  if type(s) ~= "table" then return s end
  if (tonumber(s.v) or 1) >= Pr.SETTINGS_VERSION then return s end
  local function whole(v, lo, hi)
    v = tonumber(v)
    if not v then return nil end
    v = math.floor(v + 0.5)
    if v < lo or v > hi then return nil end
    return v
  end
  s.from, s.to = whole(s.from, 1, 300), whole(s.to, 1, 300)
  s.min = whole(s.min, 1, 1e9)
  s.maxCost = whole(s.maxCost, 1, 1e9)
  s.minMargin = whole(s.minMargin, 0, 100000)
  if type(s.q) ~= "string" or s.q == "" then s.q = nil end
  s.canMake = s.canMake == true or nil
  if Pr.SORTS[s.sort] == nil then s.sort, s.desc = nil, nil end
  s.v = Pr.SETTINGS_VERSION
  return s
end

-- Clear filters: every filter and the sort back to the start (alts and the window's place stay).
function Pr.clearFilters(s)
  for _, k in ipairs({ "from", "to", "min", "maxCost", "minMargin", "q", "canMake", "onAH", "sort", "desc" }) do s[k] = nil end
  return s
end

-- Whether any filter is set (for the "Clear filters" link and the empty list's words).
function Pr.filtered(s)
  s = s or {}
  return ((s.from and s.from > 1) or (s.to and s.to < 300) or s.min or s.maxCost or s.minMargin or (s.q and s.q ~= "")
    or s.canMake or s.onAH) and true or false
end

-- Copper as short text for tight columns: 12g 34s, 5s 20c, 80c (no coin icons).
function Pr.short(c)
  if not c then return "?" end
  local neg = c < 0
  c = math.floor(math.abs(c) + 0.5)
  local g, s, cc = math.floor(c / 10000), math.floor(c / 100) % 100, c % 100
  local t
  if g >= 100 then t = g .. "g"
  elseif g > 0 then t = s > 0 and (g .. "g " .. s .. "s") or (g .. "g")
  elseif s > 0 then t = cc > 0 and (s .. "s " .. cc .. "c") or (s .. "s")
  else t = cc .. "c" end
  return (neg and "-" or "") .. t
end
