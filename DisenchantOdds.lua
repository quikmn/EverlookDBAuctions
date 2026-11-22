-- Disenchant odds: where an item's disenchant chances come from, for ns.disenchantValue (EverlookDBAuctions.lua).
--
--   1. Players' disenchants (the Price Feed addon, EverlookDBAuctions_Shared, filled by the EverlookDB App, defines
--      EverlookDB_DEOdds; it may be missing):
--        EverlookDB_DEOdds = { v = 1, updated = <unix>,
--          kinds = { ["<cls>:<q>:<ilvl>"] = { n = <disenchants>, mats = { [<mat id>] = { p = <chance 0-1>, c = <avg count when it drops> } } } },
--          items = { [<item id>] = { n = ..., mats = { same } } } }
--      - this item's own entry when it has 10 disenchants or more;
--      - else every kinds entry of the item's class and quality whose item level falls in the item's classic-db
--        bracket (DE_BRACKETS below), summed, when they have 30 disenchants together or more;
--   2. else classic-db's chances (Disenchant.lua).
-- The brackets, the lesser -> greater essences and the material names are classic-db's (CMaNGOS, GPL-3.0,
-- https://github.com/cmangos/classic-db), as DisenchantValue's tools/gen_data.py worked them out.
local _, ns = ...

-- [table class: 2 weapons, shields and held-in-off-hand items, 4 other armor][quality] = { { low, high }, ... }
local UNCOMMON = { { 5, 15 }, { 16, 20 }, { 21, 25 }, { 26, 30 }, { 31, 35 }, { 36, 40 }, { 41, 45 }, { 46, 50 },
  { 51, 55 }, { 56, 60 }, { 61, 65 } }
local RARE = { { 5, 25 }, { 26, 30 }, { 31, 35 }, { 36, 40 }, { 41, 45 }, { 46, 50 }, { 51, 55 }, { 56, 65 },
  { 66, 70 }, { 71, 74 } }
local EPIC = { { 5, 45 }, { 46, 50 }, { 51, 55 }, { 56, 60 }, { 61, 92 } }
ns.DE_BRACKETS = {
  [2] = { [2] = UNCOMMON, [3] = RARE, [4] = EPIC },
  [4] = { [2] = UNCOMMON, [3] = RARE, [4] = EPIC },
}

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

-- Shields and held-in-off-hand items use the weapon tables (classic-db); subclass and equipLoc may be nil.
function ns.deTableClass(cls, subclass, equipLoc)
  if cls == 4 and (subclass == 6 or equipLoc == "INVTYPE_HOLDABLE") then return 2 end
  return cls
end

-- The classic-db item-level bracket of an item: low, high; nil when there is none.
function ns.deBracket(cls, quality, ilvl, subclass, equipLoc)
  if type(ilvl) ~= "number" then return nil end
  local byClass = ns.DE_BRACKETS[ns.deTableClass(cls, subclass, equipLoc)]
  for _, b in ipairs(byClass and byClass[quality] or {}) do
    if ilvl >= b[1] and ilvl <= b[2] then return b[1], b[2] end
  end
end

-- Only weapons and armor of uncommon to epic quality disenchant.
function ns.deCanDisenchant(cls, quality)
  return (cls == 2 or cls == 4) and type(quality) == "number" and quality >= 2 and quality <= 4
end

local function num(v) return type(v) == "number" and v == v and v or nil end

-- A players' mats table as Disenchant.lua's rows { mat, chance %, count, count } (the average count as both min and
-- max, so value = chance x count x price either way); nil when there is nothing usable in it.
local function rows(mats)
  if type(mats) ~= "table" then return nil end
  local out = {}
  for mat, m in pairs(mats) do
    local id, p, c = num(tonumber(mat)), type(m) == "table" and num(m.p), type(m) == "table" and num(m.c)
    if id and p and c and p > 0 and p <= 1 and c > 0 and c < 100 then
      out[#out + 1] = { id, p * 100, c, c }
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

-- Players' odds for an item: rows (as Disenchant.lua's), "item" or "kind", and how many disenchants they are from;
-- nil when there aren't enough (then classic-db's are used). info = { cls, q, ilvl, sub, equipLoc } when the caller
-- has them (else they are read from the game's item cache).
function ns.deOdds(id, info)
  local o = odds()
  if not o or not id then return nil end
  local it = type(o.items) == "table" and o.items[id]
  if type(it) == "table" and (num(it.n) or 0) >= ns.DE_ITEM_MIN then
    local r = rows(it.mats)
    if r then return r, "item", it.n end
  end
  if type(o.kinds) ~= "table" then return nil end
  -- the kinds only stand in for items classic-db knows can be disenchanted
  if not (ns.DE_ITEMS and ns.DE_ITEMS[id]) then return nil end
  local cls, q, ilvl, sub, equipLoc
  if info then
    cls, q, ilvl, sub, equipLoc = info.cls, info.q, info.ilvl, info.sub, info.equipLoc
  else
    local okI, _, _, quality, level, _, _, _, _, loc, _, _, classID, subclassID = pcall(C_Item.GetItemInfo, id)
    if not okI then return nil end
    cls, q, ilvl, sub, equipLoc = classID, quality, level, subclassID, loc
  end
  if not ns.deCanDisenchant(cls, q) then return nil end
  local low, high = ns.deBracket(cls, q, ilvl, sub, equipLoc)
  if not low then return nil end
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
  local r = rows(mats)
  if r then return r, "kind", n end
end

-- A material's name: the game's, else the bundled one, else "item 12345".
function ns.deMatName(id)
  local okN, name = pcall(C_Item.GetItemInfo, id)
  return (okN and name) or ns.DE_NAMES[id] or ("item " .. tostring(id))
end
