-- EverlookDB Auctions: shopping lists from a recipe (the logic, no frames).
--   The Shopping list button in the crafting box lists the recipe's materials with how many to buy (what the crafts
--   need minus what you have), ticked when you have too few. Create list saves the ticked ones as a shopping list
--   named after the recipe, in the same lists as the Shopping tab: one search per material (name is "Copper Bar"),
--   and how many to buy of each in list.want[search]. Making the list again for the same recipe updates it.
-- Saved shape: db.lists = { { name = "Runed Copper Rod", queries = { 'name is "Copper Bar"', ... },
--   want = { ['name is "Copper Bar"'] = 4 } } }. Only item names and counts, never a player name.
local _, ns = ...
local R = {}
ns.recipeList = R

-- How many to buy: what the crafts need minus what you have, never below 0.
function R.toBuy(need, have, crafts)
  local total = (tonumber(need) or 0) * math.max(1, math.floor(tonumber(crafts) or 1))
  return math.max(0, total - (tonumber(have) or 0))
end

-- The search for one item, in the Advanced search language: its exact name, in quotes.
function R.query(name)
  name = tostring(name or ""):gsub('"', "")
  return ('name is "%s"'):format(name)
end

-- One row per material: { id, name, need (for all crafts), have, buy, tick, price, at (when the price was seen) }.
--   mats = { { id, need per craft, price each, when seen }, ... } (as the crafting box works them out)
--   haveOf(id) and nameOf(id) come from the game.
function R.rows(mats, crafts, haveOf, nameOf)
  crafts = math.max(1, math.floor(tonumber(crafts) or 1))
  local out = {}
  for _, m in ipairs(mats or {}) do
    local have = haveOf and haveOf(m[1]) or 0
    local buy = R.toBuy(m[2], have, crafts)
    out[#out + 1] = { id = m[1], name = nameOf and nameOf(m[1]) or ("item " .. m[1]), need = m[2] * crafts,
      have = have, buy = buy, tick = buy > 0, price = m[3], at = m[4] }
  end
  return out
end

-- What the ticked rows cost at the lowest price: total copper and how many ticked rows have no price.
function R.total(rows)
  local sum, unpriced = 0, 0
  for _, r in ipairs(rows or {}) do
    if r.tick and (r.buy or 0) > 0 then
      if r.price then sum = sum + r.price * r.buy else unpriced = unpriced + 1 end
    end
  end
  return sum, unpriced
end

-- Saves the ticked rows (with something to buy) as a list named after the recipe, into lists (db.lists).
-- A list with the same name is updated in place. Returns the list and whether it was new, or nil when nothing is
-- ticked.
function R.save(lists, recipeName, rows)
  local queries, want = {}, {}
  for _, r in ipairs(rows or {}) do
    local n = math.floor(tonumber(r.buy) or 0)
    if r.tick and n > 0 then
      local q = R.query(r.name)
      if not want[q] then queries[#queries + 1] = q end
      want[q] = (want[q] or 0) + n
    end
  end
  if #queries == 0 then return nil end
  local name = tostring(recipeName or ""):match("^%s*(.-)%s*$")
  if name == "" then name = "Shopping list" end
  for i, l in ipairs(lists) do
    if l.name == name then
      l.queries, l.want = queries, want
      return l, false, i
    end
  end
  local l = { name = name, queries = queries, want = want }
  lists[#lists + 1] = l
  return l, true, #lists
end
