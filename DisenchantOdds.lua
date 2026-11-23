-- Disenchant odds: where an item's disenchant chances come from, for ns.disenchantValue (EverlookDBAuctions.lua).
--
--   1. Players' disenchants (the Price Feed addon, EverlookDBAuctions_Shared, filled by the EverlookDB App, defines
--      EverlookDB_DEOdds; it may be missing):
--        EverlookDB_DEOdds = { v = 1, updated = <unix>,
--          kinds = { ["<cls>:<q>:<ilvl>"] = { n = <disenchants>, mats = { [<mat id>] = { p = <chance 0-1>, c = <avg count when it drops> } } } },
--          items = { [<item id>] = { n = ..., mats = { same } } } }
--      - this item's own entry when it has 10 disenchants or more;
--      - else every kinds entry of the item's class and quality whose item level falls in the item's bracket (the
--        client's, Disenchant.lua's DE_KINDS), summed, when they have 30 disenchants together or more;
--   2. else measured in vanilla (Enchantrix, Disenchant.lua): this item's own odds (DE_ITEM_ODDS), else its
--      bracket's when they are measured;
--   3. else classic-db's chances for its bracket (an estimate);
--   4. else, for the rare brackets new in WoW Forever (item level 5-15 and 16-20), Disenchantry's rough estimate
--      (Disenchant.lua, source "d"; Disenchantry 1.3.0 by x_Raven_x, based on Disenchant Helper by Rakuga, both MIT:
--      see THIRD-PARTY-NOTICES.md);
--   5. a bracket with none of these can be disenchanted, but nobody has measured what it gives yet.
-- A material row is { material, chance %, min, max[, average count] }: min-max is the range it comes in (the bracket's
-- when the average falls inside it, else the average as both), the average gives the value (else (min + max) / 2).
-- The brackets, which items can be disenchanted and their class (shields and off-hands are armor) are the WoW Forever
-- client's. The lesser -> greater essences and the material names are classic-db's (CMaNGOS, GPL-3.0,
-- https://github.com/cmangos/classic-db).
local _, ns = ...

-- lesser essence -> greater essence (3 lesser combine into 1 greater)
ns.DE_LESSER = { [10938] = 10939, [10998] = 11082, [11134] = 11135, [11174] = 11175, [16202] = 16203 }

-- names to show until the game has the material cached
ns.DE_NAMES = {
  [10938] = "Lesser Magic Essence", [10939] = "Greater Magic Essence", [10940] = "Strange Dust",
  [10978] = "Small Glimmering Shard", [10998] = "Lesser Astral Essence", [11082] = "Greater Astral Essence",
  [11083] = "Soul Dust", [11084] = "Large Glimmering Shard", [11134] = "Lesser Mystic Essence",
  [11135] = "Greater Mystic Essence", [11137] = "Vision Dust", [11138] = "Small Glowing Shard",
  [11139] = "Large Glowing Shard", [11174] = "Lesser Nether Essence", [11175] = "Greater Nether Essence",
  [11176] = "Dream Dust", [11177] = "Small Radiant Shard", [11178] = "Large Radiant Shard",
  [14343] = "Small Brilliant Shard", [14344] = "Large Brilliant Shard", [16202] = "Lesser Eternal Essence",
  [16203] = "Greater Eternal Essence", [16204] = "Illusion Dust", [20725] = "Nexus Crystal",
}

ns.DE_ITEM_MIN = 10   -- an item's own disenchants needed to use them
ns.DE_KIND_MIN = 30   -- disenchants of its kind (class, quality, item-level bracket) needed

-- The client's item-level bracket for an item of this class, quality and item level: low, high and its loot ID; nil
-- when there is none. Shields and off-hands are armor (class 4) like any other armor.
function ns.deBracket(cls, quality, ilvl)
  if type(ilvl) ~= "number" then return nil end
  for id, k in pairs(ns.DE_KINDS or {}) do
    if k[1] == cls and k[2] == quality and ilvl >= k[3] and ilvl <= k[4] then return k[3], k[4], id end
  end
end

-- Only weapons and armor of uncommon to epic quality disenchant.
function ns.deCanDisenchant(cls, quality)
  return (cls == 2 or cls == 4) and type(quality) == "number" and quality >= 2 and quality <= 4
end

local function num(v) return type(v) == "number" and v == v and v or nil end

-- A material's average count: its own, else the middle of its range.
function ns.deAvg(m) return m[5] or (m[3] + m[4]) / 2 end

-- The range a material comes in, from its bracket's row for it, when the average falls inside it; else the average
-- as both.
local function rangeOf(k, mat, avg)
  for i = 6, #(k or {}) do
    local r = k[i]
    if r[1] == mat and r[3] == math.floor(r[3]) and r[4] == math.floor(r[4]) and avg >= r[3] - 0.05 and avg <= r[4] + 0.05 then
      return r[3], r[4]
    end
  end
  return avg, avg
end
ns.deRangeOf = rangeOf

-- "1-2", "1", or "~2.5" when only an average is known.
function ns.deCountText(m)
  local lo, hi = m[3], m[4]
  if lo ~= hi then return lo .. "-" .. hi end
  if lo == math.floor(lo) then return tostring(lo) end
  return ("~%.1f"):format(lo)
end

-- "75%", "4.5%", "0.1%"
function ns.deChanceText(p)
  if p >= 10 then return ("%d%%"):format(math.floor(p + 0.5)) end
  return (("%.1f"):format(p):gsub("%.0$", "")) .. "%"
end

-- A players' mats table as Disenchant.lua's rows { mat, chance %, min, max, average } (the range from the item's
-- bracket k); nil when there is nothing usable in it.
local function rows(mats, k)
  if type(mats) ~= "table" then return nil end
  local out = {}
  for mat, m in pairs(mats) do
    local id, p, c = num(tonumber(mat)), type(m) == "table" and num(m.p), type(m) == "table" and num(m.c)
    if id and p and c and p > 0 and p <= 1 and c > 0 and c < 100 then
      local lo, hi = rangeOf(k, id, c)
      out[#out + 1] = { id, p * 100, lo, hi, c }
    end
  end
  if #out == 0 then return nil end
  table.sort(out, function(a, b) return a[2] > b[2] end)
  return out
end

-- Several kinds entries as one: n summed, each material's chance weighted by its entry's n, the count by its drops.
local function combine(entries)
  local n, hits, counts = 0, {}, {}
  for _, e in ipairs(entries) do
    n = n + e.n
    for mat, m in pairs(e.mats) do
      local p, c = type(m) == "table" and num(m.p), type(m) == "table" and num(m.c)
      if p and c and p > 0 and p <= 1 and c > 0 then
        hits[mat] = (hits[mat] or 0) + p * e.n
        counts[mat] = (counts[mat] or 0) + p * c * e.n
      end
    end
  end
  local mats = {}
  for mat, h in pairs(hits) do mats[mat] = { p = h / n, c = counts[mat] / h } end
  return mats, n
end

local function odds()
  local o = rawget(_G, "EverlookDB_DEOdds")
  if type(o) == "table" and o.v == 1 then return o end
end
ns.deOddsTable = odds

-- The bracket an item disenchants by: its DE_KINDS entry and loot ID; nil when it can't be disenchanted.
local function kindOf(id)
  local lid = ns.DE_ITEMS and ns.DE_ITEMS[id]
  local k = lid and ns.DE_KINDS and ns.DE_KINDS[lid]
  if k then return k, lid end
end
ns.deKindOf = kindOf

-- Players' odds for an item: rows (as Disenchant.lua's), "item" or "kind", and how many disenchants they are from;
-- nil when there aren't enough (then ns.deFallback's are used).
function ns.deOdds(id)
  local o = odds()
  if not o or not id then return nil end
  local k = kindOf(id)
  local it = type(o.items) == "table" and o.items[id]
  if type(it) == "table" and (num(it.n) or 0) >= ns.DE_ITEM_MIN then
    local r = rows(it.mats, k)
    if r then return r, "item", it.n end
  end
  if type(o.kinds) ~= "table" then return nil end
  -- the kinds only stand in for items the client says can be disenchanted
  if not k then return nil end
  local cls, q, low, high = k[1], k[2], k[3], k[4]
  local entries, total = {}, 0
  for l = low, high do
    local e = o.kinds[cls .. ":" .. q .. ":" .. l]
    if type(e) == "table" and (num(e.n) or 0) > 0 and type(e.mats) == "table" then
      entries[#entries + 1] = e
      total = total + e.n
    end
  end
  if total < ns.DE_KIND_MIN then return nil end
  local mats, n = combine(entries)
  local r = rows(mats, k)
  if r then return r, "kind", n end
end

-- Without enough players' disenchants: rows, "measured" (vanilla's disenchants: this item's own, else its
-- bracket's), "estimate" (classic-db's) or "rough" (Disenchantry's, for WoW Forever's new rare brackets), and for
-- this item's own the disenchants they are from. nil, "unmeasured" for an item that can be disenchanted but whose
-- bracket nobody has measured; nil when it can't be disenchanted.
function ns.deFallback(id)
  local k = kindOf(id)
  if not k then return nil end
  local own = ns.DE_ITEM_ODDS and ns.DE_ITEM_ODDS[id]
  if own then
    local out = {}
    for i = 2, #own - 2, 3 do
      local lo, hi = rangeOf(k, own[i], own[i + 2])
      out[#out + 1] = { own[i], own[i + 1], lo, hi, own[i + 2] }
    end
    if #out > 0 then return out, "measured", own[1] end
  end
  if k[5] == "m" or k[5] == "e" or k[5] == "d" then
    local out = {}
    for i = 6, #k do out[#out + 1] = k[i] end
    if #out > 0 then return out, k[5] == "m" and "measured" or k[5] == "e" and "estimate" or "rough" end
  end
  return nil, "unmeasured"
end

-- A material's name: the game's, else the bundled one, else "item 12345".
function ns.deMatName(id)
  local okN, name = pcall(C_Item.GetItemInfo, id)
  return (okN and name) or ns.DE_NAMES[id] or ("item " .. tostring(id))
end
