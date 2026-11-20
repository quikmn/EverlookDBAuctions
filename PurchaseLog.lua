-- EverlookDB Auctions: the log of what you bought at the auction house (the logic, no frames; Purchases.lua has the
-- window and catches the purchases).
--   Every buyout that goes through, from our Buy panel, Blizzard's own or another addon's, is one entry: when, what,
--   how many and what it cost in all. You mark the entries you crafted with, pick a recipe, and the cost per craft
--   uses what you paid for the marked ones (the average per item, over all marked entries of that item). A material
--   with no marked entry uses its lowest auction price instead, and says so.
-- Saved shape: db.bought = { oldest first: { t = time, id = itemID, q = quantity, c = copper paid in all,
--   link = item link (items that aren't commodities, for "of the Bear"), h = "Realm-Side", m = true when marked } }.
--   db.recipes = { newest first: { id = recipeID, name, mats = { { itemID, need } }, out = itemID, makes } }.
--   db.income = { oldest first: { t, kind = "sale" (an auction sold: name, id when known, q, gross = what the
--   buyer paid), "ah" (other auction house money: an outbid refund...) or "mail" (gold from anyone else), c = copper
--   you took from the mail, h } }. The sender and subject of a mail are never kept.
--   db.crafts = { [itemID made] = { mats = { { itemID, need } }, makes } }: every recipe you know, read when a
--   profession window opens, so a sold item can say what crafting it again costs.
-- Only items, amounts and prices: never a seller's, buyer's, sender's or your own character's name.
local _, ns = ...
local P = {}
ns.purchaseLog = P

P.MAX = 3000          -- entries kept (the oldest go first)
P.MAX_RECIPES = 30    -- recipes remembered for the window's recipe list

-- Adds a purchase; returns it, or nil for one that can't be right (no item, no price, nothing bought).
function P.add(list, e, max)
  if type(e) ~= "table" or not tonumber(e.id) or not tonumber(e.q) or not tonumber(e.c) then return nil end
  if e.q <= 0 or e.c <= 0 then return nil end
  list[#list + 1] = e
  max = max or P.MAX
  while #list > max do table.remove(list, 1) end
  return e
end

-- Adds money taken from the mail; returns it, or nil when there was none.
function P.addIncome(list, e, max)
  if type(e) ~= "table" or not tonumber(e.c) or e.c <= 0 then return nil end
  e.q = tonumber(e.q) or 1
  if e.q <= 0 then e.q = 1 end
  list[#list + 1] = e
  max = max or P.MAX
  while #list > max do table.remove(list, 1) end
  return e
end

-- Copper in all of the entries since a time (all of them without one).
function P.sum(list, since)
  local c = 0
  for _, e in ipairs(list or {}) do
    if not since or (e.t or 0) >= since then c = c + (e.c or 0) end
  end
  return c
end

-- What one item made by recipe r costs in materials at priceOf (lowest AH price), and how many materials have no
-- price (then the cost is nil).
function P.craftEach(r, priceOf)
  if type(r) ~= "table" or type(r.mats) ~= "table" or #r.mats == 0 then return nil, 0 end
  local cost, missing = 0, 0
  for _, m in ipairs(r.mats) do
    local p = priceOf and priceOf(m[1])
    if p then cost = cost + p * (m[2] or 1) else missing = missing + 1 end
  end
  if missing > 0 then return nil, missing end
  return math.floor(cost / math.max(1, r.makes or 1) + 0.5), 0
end

-- Remembers a recipe picked in the profession window (newest first, once each). w = { recipeID, name, mats =
-- { { itemID, need, ... } }, out, makes } as the crafting box works it out.
function P.noteRecipe(recipes, w, max)
  if type(w) ~= "table" or not w.recipeID or type(w.mats) ~= "table" or #w.mats == 0 then return nil end
  local r = { id = w.recipeID, name = w.name, out = w.out, makes = w.makes, mats = {} }
  for _, m in ipairs(w.mats) do r.mats[#r.mats + 1] = { m[1], m[2] } end
  for i = #recipes, 1, -1 do
    if recipes[i].id == r.id then table.remove(recipes, i) end
  end
  table.insert(recipes, 1, r)
  max = max or P.MAX_RECIPES
  while #recipes > max do table.remove(recipes) end
  return r
end

function P.findRecipe(recipes, id)
  for _, r in ipairs(recipes or {}) do
    if r.id == id then return r end
  end
end

-- What the marked entries add up to: entries, items, copper.
function P.markedTotal(list)
  local n, q, c = 0, 0, 0
  for _, e in ipairs(list or {}) do
    if e.m then n, q, c = n + 1, q + e.q, c + e.c end
  end
  return n, q, c
end

-- The marked entries of one item: how many items, what they cost in all, how many entries.
function P.paidFor(list, id)
  local q, c, n = 0, 0, 0
  for _, e in ipairs(list or {}) do
    if e.m and e.id == id then q, c, n = q + e.q, c + e.c, n + 1 end
  end
  return q, c, n
end

-- The cost of one craft of recipe r.
--   priceOf(id) -> lowest auction price per item (or nil), for materials you have no marked purchase of.
-- Returns { mats = { { id, need, unit, src = "paid"|"ah"|nil, lots, have = items marked } }, total, unpriced,
--   paidAll = every material from your purchases, crafts = how many crafts the marked purchases cover (nil when
--   some material isn't from them) }.
function P.cost(list, r, priceOf)
  local out = { mats = {}, total = 0, unpriced = 0, paidAll = true }
  local crafts
  for _, m in ipairs(r and r.mats or {}) do
    local id, need = m[1], m[2] or 1
    local q, c, n = P.paidFor(list, id)
    local row = { id = id, need = need, lots = n, have = q }
    if q > 0 then
      row.unit, row.src = c / q, "paid"
      local k = math.floor(q / need)
      crafts = crafts and math.min(crafts, k) or k
    else
      out.paidAll = false
      local p = priceOf and priceOf(id)
      if p then row.unit, row.src = p, "ah" end
    end
    if row.unit then out.total = out.total + row.unit * need else out.unpriced = out.unpriced + 1 end
    out.mats[#out.mats + 1] = row
  end
  if #out.mats == 0 then out.paidAll = false end
  out.total = math.floor(out.total + 0.5)
  out.crafts = out.paidAll and crafts or nil
  return out
end

-- The entries to show, newest first: only marked ones, or those whose name holds the words (any case).
--   nameOf(entry) -> its item name.
function P.view(list, filter, markedOnly, nameOf)
  local out = {}
  filter = filter and filter:lower():match("^%s*(.-)%s*$") or ""
  for i = #(list or {}), 1, -1 do
    local e = list[i]
    if (not markedOnly or e.m) and (filter == "" or (nameOf(e) or ""):lower():find(filter, 1, true)) then
      out[#out + 1] = e
    end
  end
  return out
end

return P
