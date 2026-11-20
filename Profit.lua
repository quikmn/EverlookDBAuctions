-- EverlookDB Auctions: the profit finder (the logic, no frames; ProfitWindow.lua has the window).
--   For every recipe you know (db.crafts, read when a profession window opens, Purchases.lua): what one craft costs,
--   what it sells for on the auction house after the cut, and the profit. A material costs the cheaper of its lowest
--   AH price and crafting it yourself from a recipe you know (bars, bolts), worked out the same way all the way down;
--   a loop (a transmute and its way back) is cut, never followed twice. A material with neither price is left out of
--   the cost and the row is marked approximate (its real profit is lower). Nothing is guessed: no vendor or made-up
--   fallback prices.
--   Shopping: the picked recipes and how many crafts of each become what to buy, with the materials cheaper to craft
--   broken down into their own materials, minus what is in your bags and bank.
local _, ns = ...
local Pr = {}
ns.profit = Pr

Pr.STALE = 24 * 3600    -- prices older than this show as old
Pr.MAX_DEPTH = 8        -- how deep materials are broken down (bolts into cloth; deeper chains don't exist)

-- A context for one pass: ctx = { recipes = { [itemID made] = { mats = { { id, need } }, makes, rid, name } },
-- price = fn(id) -> copper each, when seen (nil when unknown), cut = 0.05, craftMats = true (false: buy everything),
-- info = fn(id) -> skill, profession (optional) }.
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
  local total, unpriced, missing, oldest, cut = 0, 0, {}, nil, false
  for _, m in ipairs(r.mats or {}) do
    local c, sub = costOf(ctx, m[1], depth + 1)
    cut = cut or sub
    if c.cost then
      total = total + c.cost * (m[2] or 1)
      oldest = older(oldest, c.oldest)
    else
      unpriced = unpriced + 1
      for _, id in ipairs(c.missing) do missing[#missing + 1] = id end
    end
  end
  return total, unpriced, missing, oldest, cut
end

-- The cheapest way to get one of an item: { cost = copper or nil, how = "buy"/"craft"/nil, oldest = when the
-- oldest price used was seen, missing = { ids without a price } }, and whether a loop was cut below it (such an
-- answer isn't remembered, since it depends on where the walk came from).
function costOf(ctx, id, depth)
  local known = ctx.memo[id]
  if known then return known, false end
  local buy, at = ctx.price(id)
  local best = buy and { cost = buy, how = "buy", oldest = at, missing = {} } or nil
  local r = ctx.craftMats ~= false and ctx.recipes[id]
  local cut = false
  if r then
    if ctx.busy[id] or (depth or 0) >= Pr.MAX_DEPTH then
      cut = true
    else
      ctx.busy[id] = true
      local total, unpriced, missing, oldest, sub = craftCost(ctx, r, depth or 0)
      ctx.busy[id] = nil
      cut = sub
      local each = unpriced == 0 and total / math.max(r.makes or 1, 0.01) or nil
      if each and (not best or each < best.cost) then
        best = { cost = each, how = "craft", oldest = oldest, missing = {} }
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
-- oldest (the oldest price used), skill, profession, mats = { { id, need, each, how } } }.
function Pr.row(ctx, out, r)
  ctx.busy[out] = true   -- a loop back to what is being made is cut
  local row = { id = out, rid = r.rid, name = r.name, makes = r.makes or 1, cost = 0, unpriced = 0, missing = {}, mats = {} }
  for _, m in ipairs(r.mats or {}) do
    local c = costOf(ctx, m[1], 1)
    row.mats[#row.mats + 1] = { id = m[1], need = m[2] or 1, each = c.cost, how = c.how }
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

-- Every recipe that passes the filter, best profit first. filter = { from, to (skill), min (copper) }. A recipe whose
-- skill isn't known passes only while the skill range is the whole 1-300. Returns the rows and the counts:
-- { known = recipes known, noSale = recipes whose result has no AH price, approx = rows with an unpriced material }.
function Pr.list(ctx, filter)
  filter = filter or {}
  local from, to = tonumber(filter.from) or 1, tonumber(filter.to) or 300
  local whole = from <= 1 and to >= 300
  local min = tonumber(filter.min)
  local out, counts = {}, { known = 0, noSale = 0, approx = 0 }
  for id, r in pairs(ctx.recipes) do
    counts.known = counts.known + 1
    local row = Pr.row(ctx, id, r)
    local s = row.skill
    local inRange = s and s >= from and s <= to or (not s and whole)
    if not row.sale then
      if inRange then counts.noSale = counts.noSale + 1 end
    elseif inRange and (not min or row.profit >= min) then
      out[#out + 1] = row
      if row.approx then counts.approx = counts.approx + 1 end
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
    local r = p.row and ctx.recipes[p.row.id]
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
