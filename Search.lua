-- EverlookDB Auctions: query search over the last full scan, in the same language as EverlookDB.com.
--   items | where slot is trinket and price lt 5g | sort by price
-- The Advanced search button on Buy's search row opens it over the auction list: type a query, press Enter.
-- Click a result to find it on the auction house and buy as usual.
-- Columns: name, quality, ilvl, reqlevel, slot, category, type, sell, stack, price (lowest buyout), median, qty,
-- auctions, stats str, agi, sta, int, spi, armor, ap, sp, healing, mp5, defense, dps, hit, crit, spellhit,
-- spellcrit, block, fire_res (and holy, nature, frost, shadow, arcane), and `stats` (all stats as text).
-- From EverlookDB's data (Data.lua): slots (bag size), source (vendor, crafted, drop, quest, skinning,
-- pickpocket), profession (that makes it), skill (needed to make it) and droprate (best drop chance, %).
-- Steps: where, sort by <col> [asc|desc], top <n> [by <col>], count.

local ADDON, ns = ...
local UI, T = ns.UI, ns.T
local C_BAD, C_MUTE, C_DIM, C_GOOD, C_INFO, C_ACCENT =
  UI.hex(T.bad), UI.hex(T.mute), UI.hex(T.dim), UI.hex(T.good), UI.hex(T.info), UI.hex(T.accent)

local ROW_H = 22

local Q = { results = {}, offset = 0 }
local liveStep   -- the live check (defined further down; the panel's scroll uses it)

---------------------------------------------------------------------------------------------------------------------
-- Columns

local QUALITY = { "poor", "common", "uncommon", "rare", "epic", "legendary", "artifact", "heirloom" }
local SLOT = { "none", "head", "neck", "shoulder", "shirt", "chest", "waist", "legs", "feet", "wrist", "hands", "finger",
  "trinket", "onehand", "shield", "ranged", "back", "twohand", "bag", "tabard", "robe", "mainhand", "offhand", "holdable",
  "ammo", "thrown", "wand", "quiver", "relic" }
local EQUIP = {
  INVTYPE_HEAD = "head", INVTYPE_NECK = "neck", INVTYPE_SHOULDER = "shoulder", INVTYPE_BODY = "shirt",
  INVTYPE_CHEST = "chest", INVTYPE_WAIST = "waist", INVTYPE_LEGS = "legs", INVTYPE_FEET = "feet", INVTYPE_WRIST = "wrist",
  INVTYPE_HAND = "hands", INVTYPE_FINGER = "finger", INVTYPE_TRINKET = "trinket", INVTYPE_WEAPON = "onehand",
  INVTYPE_SHIELD = "shield", INVTYPE_RANGED = "ranged", INVTYPE_CLOAK = "back", INVTYPE_2HWEAPON = "twohand",
  INVTYPE_BAG = "bag", INVTYPE_TABARD = "tabard", INVTYPE_ROBE = "robe", INVTYPE_WEAPONMAINHAND = "mainhand",
  INVTYPE_WEAPONOFFHAND = "offhand", INVTYPE_HOLDABLE = "holdable", INVTYPE_AMMO = "ammo", INVTYPE_THROWN = "thrown",
  INVTYPE_RANGEDRIGHT = "wand", INVTYPE_QUIVER = "quiver", INVTYPE_RELIC = "relic",
}
local function index(list)
  local t = {}
  for i, v in ipairs(list) do t[v] = i end
  return t
end
local ENUMS = { quality = index(QUALITY), slot = index(SLOT) }

local STATS = {
  str = "ITEM_MOD_STRENGTH_SHORT", agi = "ITEM_MOD_AGILITY_SHORT", sta = "ITEM_MOD_STAMINA_SHORT",
  int = "ITEM_MOD_INTELLECT_SHORT", spi = "ITEM_MOD_SPIRIT_SHORT", armor = "RESISTANCE0_NAME",
  ap = "ITEM_MOD_ATTACK_POWER_SHORT", sp = "ITEM_MOD_SPELL_POWER_SHORT", healing = "ITEM_MOD_SPELL_HEALING_DONE_SHORT",
  mp5 = "ITEM_MOD_MANA_REGENERATION_SHORT", defense = "ITEM_MOD_DEFENSE_SKILL_RATING_SHORT",
  dps = "ITEM_MOD_DAMAGE_PER_SECOND_SHORT", hit = "ITEM_MOD_HIT_RATING_SHORT", crit = "ITEM_MOD_CRIT_RATING_SHORT",
  spellhit = "ITEM_MOD_HIT_SPELL_RATING_SHORT", spellcrit = "ITEM_MOD_CRIT_SPELL_RATING_SHORT",
  block = "ITEM_MOD_BLOCK_VALUE_SHORT", holy_res = "RESISTANCE1_NAME", fire_res = "RESISTANCE2_NAME",
  nature_res = "RESISTANCE3_NAME", frost_res = "RESISTANCE4_NAME", shadow_res = "RESISTANCE5_NAME",
  arcane_res = "RESISTANCE6_NAME",
}
local KIND = {   -- text, number, enum or money
  name = "text", category = "text", type = "text", quality = "enum", slot = "enum",
  ilvl = "number", reqlevel = "number", stack = "number", qty = "number", auctions = "number",
  sell = "money", price = "money", median = "money",
  slots = "number", skill = "number", profession = "text", source = "text", droprate = "number",
}
for k in pairs(STATS) do KIND[k] = "number" end
KIND.stats = "text"   -- every stat on the item as text, e.g. "Stamina 5, Agility 3": `stats has agility`
local ALIAS = {
  rarity = "quality", subtype = "type", subclass = "type", itemclass = "category", level = "reqlevel", lvl = "reqlevel",
  req = "reqlevel", reqlvl = "reqlevel", minlevel = "reqlevel", vendor = "sell", low = "price", lowest = "price",
  buyout = "price", med = "median", typical = "median", quantity = "qty", count = "qty", up = "auctions",
  strength = "str", agility = "agi", stamina = "sta", stam = "sta", intellect = "int", intel = "int", spirit = "spi",
  ac = "armor", armour = "armor", firres = "fire_res", fireres = "fire_res", frostres = "frost_res",
  drop = "droprate", dropchance = "droprate", chance = "droprate", bagslots = "slots", size = "slots", prof = "profession", craftedby = "profession", from = "source",
  natureres = "nature_res", shadowres = "shadow_res", arcaneres = "arcane_res", blockvalue = "block", attackpower = "ap", spellpower = "sp", heal = "healing", def = "defense",
}
local function column(word)
  word = word and word:lower()
  word = ALIAS[word] or word
  return KIND[word] and word or nil
end

---------------------------------------------------------------------------------------------------------------------
-- Tokens and parsing

local function tokenize(s)
  local out, i, n = {}, 1, #s
  while i <= n do
    local c = s:sub(i, i)
    if c:match("%s") then
      i = i + 1
    elseif c == '"' or c == "'" then
      local j = s:find(c, i + 1, true) or (n + 1)
      out[#out + 1] = { t = "str", v = s:sub(i + 1, j - 1) }
      i = j + 1
    elseif s:sub(i, i + 1) == ".." then
      out[#out + 1] = { t = "op", v = ".." }; i = i + 2
    elseif s:sub(i, i + 1):match("^[<>!=]=$") then
      out[#out + 1] = { t = "op", v = s:sub(i, i + 1) }; i = i + 2
    elseif c:match("[|(),<>!=]") then
      out[#out + 1] = { t = "op", v = c }; i = i + 1
    else
      local j = i
      while j <= n and not s:sub(j, j):match("[%s|(),<>!=\"']") and s:sub(j, j + 1) ~= ".." do j = j + 1 end
      out[#out + 1] = { t = "word", v = s:sub(i, j - 1) }
      i = j
    end
  end
  return out
end

local OPS = {
  is = "eq", eq = "eq", equals = "eq", ["=="] = "eq", ["="] = "eq", ne = "ne", ["!="] = "ne",
  gt = "gt", above = "gt", [">"] = "gt", ge = "ge", gte = "ge", [">="] = "ge",
  lt = "lt", below = "lt", ["<"] = "lt", le = "le", lte = "le", ["<="] = "le",
  has = "has", contains = "has", startswith = "starts", endswith = "ends", like = "like", notlike = "notlike",
  between = "between", ["in"] = "in",
}

-- "5g", "50s", "1g50s", "20c" -> copper; plain numbers stay numbers
local function moneyValue(v)
  if type(v) ~= "string" then return v end
  local total, any = 0, false
  for n, unit in v:lower():gmatch("(%d+)([gsc])") do
    total = total + tonumber(n) * (unit == "g" and 10000 or unit == "s" and 100 or 1)
    any = true
  end
  if any then return total end
  return tonumber(v)
end

local Parser = {}
Parser.__index = Parser

function Parser:peek(o) return self.toks[self.pos + (o or 0)] end
function Parser:next() local t = self.toks[self.pos]; self.pos = self.pos + 1; return t end
function Parser:isWord(w, o) local t = self:peek(o); return t and t.t == "word" and t.v:lower() == w end
function Parser:isOp(v, o) local t = self:peek(o); return t and t.t == "op" and t.v == v end
function Parser:fail(msg) error({ query = msg }, 0) end

function Parser:value()
  local t = self:next()
  if not t or t.t == "op" then self:fail("a value is missing") end
  return t.v
end

function Parser:list()
  if not self:isOp("(") then return { self:value() } end
  self:next()
  local out = {}
  repeat
    out[#out + 1] = self:value()
    if self:isOp(",") then self:next() else break end
  until false
  if not self:isOp(")") then self:fail("a ) is missing") end
  self:next()
  return out
end

-- a column, a comparison and a value: "slot is trinket", "price lt 5g", "ilvl between (20 .. 30)"
function Parser:comparison(col)
  local negate = false
  if self:isWord("not") or self:isOp("!") then self:next(); negate = true end
  local t = self:next()
  local op = t and OPS[t.v:lower()]
  if t and t.t == "word" and t.v:lower() == "is" and self:isWord("not") then self:next(); op = "ne" end
  if t and t.v == "!" then op = nil end
  if not op then self:fail("after " .. col .. " comes a comparison like is, gt, lt or has") end
  if op == "between" then
    if self:isOp("(") then self:next() end
    local a = self:value()
    if self:isOp("..") then self:next() elseif self:isWord("and") then self:next() end
    local b = self:value()
    if self:isOp(")") then self:next() end
    return { k = "cmp", col = col, op = op, a = a, b = b, neg = negate }
  end
  local mode
  if self:isWord("any") or self:isWord("anyof") then self:next(); mode = "any"
  elseif self:isWord("all") or self:isWord("allof") then self:next(); mode = "all" end
  if mode and self:isWord("of") then self:next() end
  local values = (op == "in" or mode) and self:list() or { self:value() }
  return { k = "cmp", col = col, op = op == "in" and "eq" or op, values = values, all = mode == "all", neg = negate }
end

function Parser:primary()
  if self:isOp("(") then
    self:next()
    local e = self:orExpr()
    if not self:isOp(")") then self:fail("a ) is missing") end
    self:next()
    return e
  end
  if self:isWord("not") or self:isOp("!") then
    self:next()
    return { k = "not", e = self:primary() }
  end
  local t = self:next()
  if not t then self:fail("the condition ends too early") end
  local col = t.t == "word" and column(t.v)
  local nxt = self:peek()
  if col and nxt and (OPS[nxt.v:lower()] or nxt.v:lower() == "not" or nxt.v == "!") then
    return self:comparison(col)
  end
  -- a word on its own searches names
  return { k = "cmp", col = "name", op = "has", values = { t.v } }
end

function Parser:andExpr()
  local e = self:primary()
  while true do
    if self:isWord("and") then self:next()
    elseif not self:peek() or self:isWord("or") or self:isOp(")") or self:isOp("|") then break end
    e = { k = "and", a = e, b = self:primary() }
  end
  return e
end

function Parser:orExpr()
  local e = self:andExpr()
  while self:isWord("or") do
    self:next()
    e = { k = "or", a = e, b = self:andExpr() }
  end
  return e
end

-- "items | where ... | sort by price desc | top 10 by ilvl | count" -> list of steps
local function parse(text)
  local p = setmetatable({ toks = tokenize(text), pos = 1 }, Parser)
  local steps = {}
  if p:isWord("items") or p:isWord("item") then p:next() end
  if p:peek() and not p:isOp("|") then
    -- no "items |" in front: treat the rest as a where
    steps[#steps + 1] = { k = "where", e = p:orExpr() }
  end
  while p:peek() do
    if not p:isOp("|") then p:fail("steps are separated by |") end
    p:next()
    local w = p:next()
    local word = w and w.v:lower()
    if word == "where" then
      steps[#steps + 1] = { k = "where", e = p:orExpr() }
    elseif word == "sort" or word == "order" then
      if p:isWord("by") then p:next() end
      local keys = {}
      repeat
        local desc = false
        if p:isWord("desc") or p:isWord("descending") then p:next(); desc = true
        elseif p:isWord("asc") or p:isWord("ascending") then p:next() end
        local name = p:value()
        if name:sub(1, 1) == "-" then desc, name = true, name:sub(2) end
        local c = column(name) or p:fail("can't sort by " .. name .. "; try ilvl, reqlevel, price, median, qty, sta...")
        if p:isWord("desc") or p:isWord("descending") then p:next(); desc = true
        elseif p:isWord("asc") or p:isWord("ascending") then p:next(); desc = false end
        keys[#keys + 1] = { col = c, desc = desc }
        local more = p:isOp(",")
        if more then p:next() end
      until not more
      steps[#steps + 1] = { k = "sort", keys = keys }
    elseif word == "top" or word == "take" or word == "limit" then
      local n = tonumber(p:value()) or p:fail(word .. " needs a number")
      local step = { k = "top", n = n }
      if p:isWord("by") then
        p:next()
        local c = column(p:value()) or p:fail("top by which column?")
        local desc = true
        if p:isWord("asc") or p:isWord("ascending") then p:next(); desc = false
        elseif p:isWord("desc") or p:isWord("descending") then p:next() end
        step.keys = { { col = c, desc = desc } }
      end
      steps[#steps + 1] = step
    elseif word == "count" then
      steps[#steps + 1] = { k = "count" }
    else
      p:fail("unknown step " .. tostring(w and w.v) .. "; use where, sort by, top or count")
    end
  end
  return steps
end

---------------------------------------------------------------------------------------------------------------------
-- Rows and evaluation

-- Item details are saved once in the addon's own file (db.itemInfo, db.itemStats): the game keeps only so many items
-- in memory, so asking it again on every search would give a different set each time.
local function store()
  local db = ns.db()
  if not db then return nil end
  db.itemInfo = db.itemInfo or {}
  db.itemStats = db.itemStats or {}
  return db
end

-- { name, quality, ilvl, reqlevel, category, type, equipLoc, icon, sell, stack } or nil while the game loads it.
local function itemInfo(id)
  local db = store()
  local c = db and db.itemInfo[id]
  if c then return c end
  local name, _, quality, ilvl, req, category, kind, stack, equip, icon, sell = C_Item.GetItemInfo(id)
  if not name then return nil end
  c = { name, quality or 1, ilvl or 0, req or 0, category or "", kind or "", equip or "", icon or 0, sell or 0, stack or 1 }
  if db then db.itemInfo[id] = c end
  return c
end
ns.itemInfo = itemInfo

local EMPTY_STATS = { stats = "" }

-- Stats of an item version, saved once the game has the item loaded.
local function statsOf(row)
  local db = store()
  local s = db and db.itemStats[row.key]
  if s then return s end
  if not C_Item.GetItemInfo(row.id) then return EMPTY_STATS end   -- not loaded right now: nothing to read yet
  local link = "item:" .. row.id .. (row.suffix ~= 0 and ("::::::::::::1:" .. row.suffix) or "")
  local okStats, t = pcall(C_Item.GetItemStats or GetItemStats, link)
  s = {}
  local names = {}
  if okStats and type(t) == "table" then
    for short, mod in pairs(STATS) do
      if t[mod] and t[mod] ~= 0 then s[short] = t[mod] end
    end
    for mod, n in pairs(t) do names[#names + 1] = (_G[mod] or mod) .. " " .. n end
  end
  table.sort(names)
  s.stats = table.concat(names, ", ")
  if db then db.itemStats[row.key] = s end
  return s
end

local LIVE_TTL = 300   -- a live check counts for 5 minutes

Q.live = {}   -- "id:suffix" -> { price, qty, n, at, gone } from the live check; survives re-running the query

local function liveOf(r)
  local l = Q.live[r.key]
  if l and time() - l.at < LIVE_TTL then return l end
end
local function liveFresh(r) return liveOf(r) ~= nil end
ns.liveFresh = liveFresh

local function get(row, col)
  if STATS[col] then return statsOf(row)[col] or 0 end
  -- price and quantity: the live check when there is a fresh one (sold out = nothing up)
  local l = (col == "price" or col == "qty" or col == "auctions") and liveOf(row)
  if l then
    if l.gone then return col ~= "price" and 0 or nil end
    return l[col == "auctions" and "n" or col]
  end
  if col == "stats" then return statsOf(row).stats end
  return row[col]
end

local function textMatch(have, op, want)
  have, want = tostring(have or ""):lower(), tostring(want):lower()
  if op == "eq" then return have == want end
  if op == "has" then return have:find(want, 1, true) ~= nil end
  if op == "starts" then return have:sub(1, #want) == want end
  if op == "ends" then return want == "" or have:sub(-#want) == want end
  if op == "like" or op == "notlike" then
    local r
    if not want:find("[%*%?]") then
      r = have:find(want, 1, true) ~= nil
    else
      local pat = "^" .. want:gsub("[%^%$%(%)%%%.%[%]%+%-]", "%%%0"):gsub("%*", ".*"):gsub("%?", ".") .. "$"
      r = have:match(pat) ~= nil
    end
    if op == "notlike" then return not r end
    return r
  end
  if op == "ne" then return have ~= want end
  return false
end

local function numberOf(col, v)
  local kind = KIND[col]
  if kind == "enum" then return ENUMS[col][tostring(v):lower()] end
  if kind == "money" then return moneyValue(v) end
  return tonumber(v)
end

local function compare(have, op, want)
  if have == nil or want == nil then return false end
  if op == "eq" then return have == want end
  if op == "ne" then return have ~= want end
  if op == "gt" then return have > want end
  if op == "ge" then return have >= want end
  if op == "lt" then return have < want end
  if op == "le" then return have <= want end
  return false
end

local function test(row, e)
  if e.k == "and" then return test(row, e.a) and test(row, e.b) end
  if e.k == "or" then return test(row, e.a) or test(row, e.b) end
  if e.k == "not" then return not test(row, e.e) end
  local col, op = e.col, e.op
  local kind = KIND[col]
  local r
  if op == "between" then
    local v = kind == "enum" and ENUMS[col][tostring(get(row, col))] or get(row, col)
    local a, b = numberOf(col, e.a), numberOf(col, e.b)
    r = v ~= nil and a ~= nil and b ~= nil and v >= a and v <= b
  else
    local one = function(want)
      if kind == "text" or op == "has" or op == "starts" or op == "ends" or op == "like" or op == "notlike" then
        return textMatch(get(row, col), op, want)
      end
      local have = get(row, col)
      if kind == "enum" then have = ENUMS[col][tostring(have)] end
      return compare(have, op, numberOf(col, want))
    end
    if e.all then
      r = true
      for _, w in ipairs(e.values) do if not one(w) then r = false; break end end
    else
      r = false
      for _, w in ipairs(e.values) do if one(w) then r = true; break end end
    end
  end
  if e.neg then return not r end
  return r
end

-- Every item version in the newest full scan of the open auction house, with item details.
-- Data.lua: { source bits, profession index, skill, bag slots, best drop chance in % } per item
local EMPTY_DATA = {}
local sourceCache = {}
local function sourceText(bits)
  bits = bits or 0
  if sourceCache[bits] then return sourceCache[bits] end
  local t = {}
  for i, name in ipairs(ns.SOURCES or {}) do
    if bit.band(bits, 2 ^ (i - 1)) ~= 0 then t[#t + 1] = name end
  end
  sourceCache[bits] = table.concat(t, ", ")
  return sourceCache[bits]
end

local function dataset()
  local db, house = ns.db(), ns.house()
  if not db or not house then return nil end
  local side, realm = house:match("%-(%a+)$"), GetRealmName()
  local scanned
  for k = #db.scans, 1, -1 do
    local sc = db.scans[k]
    if sc.realm == realm and sc.side == side then scanned = sc; break end
  end
  if not scanned then return nil end
  if Q.cacheFor == scanned then return Q.cache, scanned, Q.missing end
  local rows, missing = {}, 0
  for key, line in pairs(scanned.rows) do
    local id, suffix = key:match("^(%d+):(%-?%d+)$")
    id, suffix = tonumber(id), tonumber(suffix)
    local f = { strsplit(",", line) }
    local c = itemInfo(id)
    if not c then
      missing = missing + 1
    else
      local d = ns.ITEMDATA and ns.ITEMDATA[id] or EMPTY_DATA
      rows[#rows + 1] = {
        key = key, id = id, suffix = suffix, icon = c[8],
        name = (suffix ~= 0 and f[13] and f[13] ~= "") and f[13] or c[1],
        quality = QUALITY[(c[2] or 1) + 1], ilvl = c[3], reqlevel = c[4], category = c[5], type = c[6],
        slot = EQUIP[c[7] or ""] or "none", stack = c[10], sell = c[9],
        price = tonumber(f[1]), median = tonumber(f[3]), qty = tonumber(f[4]), auctions = tonumber(f[5]),
        source = sourceText(d[1]), profession = ns.PROFESSIONS and ns.PROFESSIONS[d[2] or 0] or "",
        skill = d[3] or 0, slots = d[4] or 0, droprate = d[5] or 0,
      }
    end
  end
  -- only keep the result when every item was loaded, so the next search sees the rest
  if missing == 0 then Q.cacheFor, Q.cache, Q.missing = scanned, rows, 0 end
  return rows, scanned, missing
end

-- Sorts rows by one or more { col, desc } keys; rows missing the value go last, then by name.
local function sortRows(rows, keys)
  table.sort(rows, function(a, b)
    for _, key in ipairs(keys) do
      local c = key.col
      local x, y = get(a, c), get(b, c)
      if KIND[c] == "enum" then x, y = ENUMS[c][tostring(x)], ENUMS[c][tostring(y)] end
      if x ~= y then
        if x == nil then return false end
        if y == nil then return true end
        if type(x) ~= type(y) then x, y = tostring(x), tostring(y) end
        if type(x) == "string" then x, y = x:lower(), y:lower() end
        if x ~= y then
          if key.desc then return x > y end
          return x < y
        end
      end
    end
    return a.name < b.name
  end)
end
ns.sortRows = sortRows

local function run(text)
  local lower = " " .. (text or ""):lower() .. " "
  Q.extra = lower:find("[^%w_]slots[^%w_]") and "slots" or lower:find("[^%w_]skill[^%w_]") and "skill"
    or lower:find("[^%w_]droprate[^%w_]") and "droprate" or nil
  local okParse, steps = pcall(parse, text)
  if not okParse then
    return nil, type(steps) == "table" and steps.query or tostring(steps)
  end
  local rows, scanned, missing = dataset()
  if not rows then return nil, "No full scan of this auction house yet: open it and let the scan finish first." end
  local out = {}
  for _, r in ipairs(rows) do out[#out + 1] = r end
  local counted
  for _, st in ipairs(steps) do
    if st.k == "where" then
      local kept = {}
      for _, r in ipairs(out) do if test(r, st.e) then kept[#kept + 1] = r end end
      out = kept
    elseif st.k == "sort" or st.k == "top" then
      if st.keys then sortRows(out, st.keys) end
      if st.k == "top" then
        local kept = {}
        for k = 1, math.min(st.n, #out) do kept[k] = out[k] end
        out = kept
      end
    elseif st.k == "count" then
      counted = #out
    end
  end
  local head = counted and ("%s matching item versions"):format(ns.num(counted))
    or ("%s results"):format(ns.num(#out))
  head = head .. (" in the full scan %s"):format(ns.ago(scanned.at))
  return counted and {} or out, head, missing
end

---------------------------------------------------------------------------------------------------------------------
-- The Advanced search panel, over the auction list

local ROW_TOP = 84          -- first result row, from the top of the panel

-- Result columns: header, column to sort by, right edge (from the panel's right), width, and how to show the value.
-- Live-checked values are white; values only from the scan are grey; sold-out rows say so.
local GREY = C_DIM .. ""
local COLS = {
  { "Up", "qty", -10, 40, function(r)
    local l = liveOf(r)
    if l then return l.gone and C_BAD .. "-|r" or ns.num(l.qty or 0) end
    return GREY .. ns.num(r.qty or 0) .. "|r"
  end },
  { "Typical", "median", -56, 86, function(r) return r.median and (GREY .. ns.money(r.median) .. "|r") or "" end },
  { "Lowest", "price", -148, 86, function(r)
    local l = liveOf(r)
    if l then
      if l.gone then return C_BAD .. "sold out|r" end
      return l.price and ns.money(l.price) or C_MUTE .. "bids only|r"
    end
    return r.price and (GREY .. ns.money(r.price) .. "|r") or C_MUTE .. "bids only|r"
  end },
  { "Req", "reqlevel", -240, 30, function(r)
    local v = r[Q.extra or "reqlevel"] or 0
    return v > 0 and v or ""
  end },
  { "iLvl", "ilvl", -276, 30, function(r) return r.ilvl or "" end },
}
local NAME_RIGHT = -312     -- the item name stops here

local function rowsFit(f)
  return math.max(4, math.floor((f:GetHeight() - ROW_TOP - 22) / ROW_H))
end

local function render()
  local f = Q.frame
  local n = #Q.rows
  local maxOffset = math.max(0, #Q.results - n)
  if Q.offset > maxOffset then Q.offset = maxOffset end
  for k = 1, n do
    local b, r = Q.rows[k], Q.results[Q.offset + k]
    b.row = r
    if r and r.header then
      -- a shopping list's search: its query and how many it found
      b.icon:SetTexture(nil)
      b.name:SetPoint("RIGHT", f, "RIGHT", -12, 0)
      local tail = r.err or (ns.num(r.count) .. " found" .. (r.sum and r.count > 1 and (", one of each " .. ns.money(r.sum)) or ""))
      b.name:SetText(C_ACCENT .. r.name .. "|r   " .. C_MUTE .. tail .. "|r")
      for c in ipairs(COLS) do b.cells[c]:SetText("") end
      b:Show()
    elseif r then
      b.name:SetPoint("RIGHT", f, "RIGHT", NAME_RIGHT, 0)
      b.icon:SetTexture(r.icon)
      local color = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[(ENUMS.quality[r.quality] or 2) - 1]
      local l = liveOf(r)
      b.name:SetText((l and l.gone and GREY or color and color.hex or "|cffffffff") .. r.name .. "|r")
      for c, col in ipairs(COLS) do b.cells[c]:SetText(col[5](r)) end
      b:Show()
    else
      b:Hide()
    end
  end
  for _, h in ipairs(Q.headers) do
    if h.col == "reqlevel" or h.col == "slots" or h.col == "skill" or h.col == "droprate" then
      h.col = Q.extra or "reqlevel"
      h.label = Q.extra == "slots" and "Slots" or Q.extra == "skill" and "Skill" or Q.extra == "droprate" and "Drop%" or "Req"
    end
    local mark = ""
    if Q.sortCol == h.col then mark = Q.sortDesc and " v" or " ^" end
    h.text:SetText(h.label .. mark)
    h.text:SetTextColor(unpack(Q.sortCol == h.col and T.accent or T.mute))
  end
  f.more:SetText(#Q.results > n
    and ("%d-%d of %d, scroll for more"):format(Q.offset + 1, math.min(Q.offset + n, #Q.results), #Q.results) or "")
end

local function hideResults()
  if Q.frame then Q.frame:Hide() end
end
ns.closeSearch = hideResults

-- Blizzard's own list (its tip text and column headers) would show through, so it is hidden while ours is open.
local function blizzardList(shown)
  local area = _G.AuctionHouseFrame and AuctionHouseFrame.BrowseResultsFrame
  if not area then return end
  for _, child in ipairs({ area:GetChildren() }) do
    if child ~= Q.frame then child:SetAlpha(shown and 1 or 0) end
  end
  for _, region in ipairs({ area:GetRegions() }) do region:SetAlpha(shown and 1 or 0) end
end

local function setStatus(text, isError)
  if not Q.frame then return end
  Q.headBase = not isError and text or nil
  Q.frame.head:SetText(isError and (C_BAD .. text .. "|r") or text)
end

---------------------------------------------------------------------------------------------------------------------
-- Query guide

local EXAMPLES = {
  { "slot is trinket | sort by price", "Every trinket, cheapest first" },
  { "slot is back and agi ge 5 | sort by price", "Cloaks with 5+ agility" },
  { "name like \"*of the eagle\" and reqlevel le 40", "Every \"of the Eagle\" item you can wear by 40" },
  { "slot is wand and reqlevel le 30 | sort by dps desc", "Best wands up to level 30" },
  { "stats has spirit and slot in (head, chest, robe) | top 20 by spi", "Top 20 spirit helmets and chests" },
  { "quality ge rare and price lt 10g | sort by ilvl desc", "Blue or better under 10 gold" },
  { "type is cloth and int ge 8 and reqlevel le 35 | sort by price", "Cloth with 8+ intellect up to 35" },
  { "fire_res ge 5 | sort by fire_res desc, price", "Fire resistance gear" },
}

local GUIDE = table.concat({
  C_ACCENT .. "How it works|r",
  "Searches everything in the last full scan of this auction house (it rescans every 15 minutes while it is open), then checks each result live. White prices are live; grey ones are from the scan and still being checked; sold out means none are up now. Click a result to see its auctions and buy it.",
  "",
  C_ACCENT .. "Conditions|r   join them with " .. C_INFO .. "and|r, " .. C_INFO .. "or|r, " .. C_INFO .. "not|r and ( )",
  C_INFO .. "is|r, " .. C_INFO .. "is not|r   " .. C_INFO .. "gt|r, " .. C_INFO .. "ge|r (at least), " .. C_INFO .. "lt|r, " .. C_INFO .. "le|r (at most)   " .. C_INFO .. "has|r (contains)",
  C_INFO .. "like|r \"*of the bear\"  (* = anything)   " .. C_INFO .. "between|r (20 .. 30)   " .. C_INFO .. "in|r (head, chest)",
  "A word on its own searches names:  " .. C_GOOD .. "wand|r",
  "",
  C_ACCENT .. "Steps|r   after a |",
  C_INFO .. "| sort by|r price   " .. C_INFO .. "| sort by|r ilvl desc, price   " .. C_INFO .. "| top|r 10 " .. C_INFO .. "by|r sta   " .. C_INFO .. "| count|r",
  "Or click a column header to sort; click again to flip it.",
  "",
  C_ACCENT .. "Columns|r",
  "name, quality (poor, common, uncommon, rare, epic, legendary), ilvl, reqlevel, category, type (Cloth, Wand, Potion...)",
  "slot: head, neck, shoulder, back, chest, robe, shirt, tabard, wrist, hands, waist, legs, feet, finger, trinket, onehand, twohand, mainhand, offhand, holdable, shield, ranged, wand, thrown, bag",
  "price (lowest buyout), median (typical), qty (how many up), auctions, sell (vendor price)",
  "slots (bag size), source (vendor, crafted, drop, quest, skinning), profession, skill, droprate (best drop %)",
  "Money: 5g, 50s, 1g50s, 20c",
  "",
  C_ACCENT .. "Stats|r",
  "str, agi, sta, int, spi, armor, ap, sp, healing, mp5, defense, dps, hit, crit, block",
  "fire_res, frost_res, nature_res, shadow_res, arcane_res, and " .. C_INFO .. "stats|r (every stat as text: stats has spirit)",
  "",
  C_ACCENT .. "Examples|r   click one to run it",
}, "\n")

local function makeGuide(f)
  local g = UI.own(CreateFrame("Frame", nil, f))
  g:SetPoint("TOPLEFT", 1, -40)
  g:SetPoint("BOTTOMRIGHT", -1, 1)
  g:SetFrameLevel(f:GetFrameLevel() + 20)
  UI.panel(g, T.bg, T.bg)
  g:EnableMouse(true)
  g:Hide()

  -- scrolls with the mouse wheel; the thin bar on the right shows where you are
  local scroll = CreateFrame("ScrollFrame", nil, g)
  scroll:SetPoint("TOPLEFT", 14, -10)
  scroll:SetPoint("BOTTOMRIGHT", -20, 10)
  local content = CreateFrame("Frame", nil, scroll)
  content:SetSize(10, 10)
  scroll:SetScrollChild(content)
  scroll:SetScript("OnSizeChanged", function(_, w) content:SetWidth(w) end)
  local track = g:CreateTexture(nil, "ARTWORK")
  track:SetPoint("TOPRIGHT", -8, -10)
  track:SetPoint("BOTTOMRIGHT", -8, 10)
  track:SetWidth(4)
  track:SetColorTexture(unpack(T.input))
  local thumb = g:CreateTexture(nil, "OVERLAY")
  thumb:SetWidth(4)
  thumb:SetColorTexture(unpack(T.thumb))
  local function place()
    local range = scroll:GetVerticalScrollRange() or 0
    local h = track:GetHeight()
    if range <= 0 or h <= 0 then thumb:Hide(); return end
    local th = math.max(20, h * h / (h + range))
    thumb:SetHeight(th)
    thumb:ClearAllPoints()
    thumb:SetPoint("TOP", track, "TOP", 0, -(h - th) * scroll:GetVerticalScroll() / range)
    thumb:Show()
  end
  scroll:EnableMouseWheel(true)
  scroll:SetScript("OnMouseWheel", function(self, delta)
    local range = self:GetVerticalScrollRange() or 0
    self:SetVerticalScroll(math.max(0, math.min(range, self:GetVerticalScroll() - delta * 40)))
    place()
  end)

  local text = UI.text(content, "small")
  text:SetPoint("TOPLEFT", 0, 0)
  text:SetPoint("RIGHT", content, "RIGHT", 0, 0)
  text:SetWordWrap(true)
  text:SetSpacing(4)
  text:SetText(GUIDE)

  local prev
  for _, ex in ipairs(EXAMPLES) do
    local b = UI.row(content, 22)
    b:SetPoint("LEFT", content, "LEFT", 0, 0)
    b:SetPoint("RIGHT", content, "RIGHT", 0, 0)
    if prev then b:SetPoint("TOP", prev, "BOTTOM", 0, 0) else b:SetPoint("TOP", text, "BOTTOM", 0, -8) end
    local q = UI.text(b, "small")
    q:SetPoint("LEFT", 6, 0)
    q:SetText(C_GOOD .. ex[1] .. "|r")
    local d = UI.text(b, "dim")
    d:SetPoint("RIGHT", -6, 0)
    d:SetText(ex[2])
    b:SetScript("OnClick", function()
      g:Hide()
      ns.query(ex[1])
    end)
    prev = b
  end

  -- size the scroll content once the text has its real height
  g:SetScript("OnShow", function()
    content:SetWidth(scroll:GetWidth())
    content:SetHeight(text:GetStringHeight() + 12 + #EXAMPLES * 22)
    scroll:SetVerticalScroll(0)
    C_Timer.After(0, place)
  end)
  return g
end

---------------------------------------------------------------------------------------------------------------------
-- The panel

local function headerClick(self)
  if Q.grouped then return end   -- a shopping list keeps its searches in order
  if Q.sortCol == self.col then
    Q.sortDesc = not Q.sortDesc
  else
    -- names A-Z first; numbers biggest first, except prices (cheapest first)
    Q.sortCol = self.col
    Q.sortDesc = not (self.col == "name" or self.col == "price" or self.col == "median")
  end
  sortRows(Q.results, { { col = Q.sortCol, desc = Q.sortDesc } })
  Q.offset = 0
  render()
end

local function makeHeader(f, label, col, right, width)
  local h = UI.own(CreateFrame("Button", nil, f))
  h:SetSize(width, 20)
  if right then
    h:SetPoint("TOPRIGHT", f, "TOPRIGHT", right, -(ROW_TOP - 21))
  else
    h:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -(ROW_TOP - 21))
  end
  h.text = UI.text(h, "head")
  h.text:SetPoint(right and "RIGHT" or "LEFT", 0, 0)
  h.label, h.col = label, col
  h:SetScript("OnClick", headerClick)
  h:SetScript("OnEnter", function(self) self.text:SetTextColor(unpack(T.text)) end)
  h:SetScript("OnLeave", function(self) self.text:SetTextColor(unpack(Q.sortCol == self.col and T.accent or T.mute)) end)
  Q.headers[#Q.headers + 1] = h
end

local function makeRow(f, k)
  local b = UI.row(f, ROW_H)
  b:SetPoint("TOPLEFT", 1, -ROW_TOP - (k - 1) * ROW_H)
  b:SetPoint("RIGHT", -1, 0)
  b.icon = b:CreateTexture(nil, "ARTWORK")
  b.icon:SetSize(18, 18)
  b.icon:SetPoint("LEFT", 12, 0)
  b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  b.cells = {}
  for c, col in ipairs(COLS) do
    local fs = UI.text(b, "body")
    fs:SetPoint("RIGHT", f, "RIGHT", col[3], 0)
    fs:SetPoint("TOP", b, "TOP", 0, 0)
    fs:SetPoint("BOTTOM", b, "BOTTOM", 0, 0)
    fs:SetWidth(col[4])
    fs:SetJustifyH("RIGHT")
    b.cells[c] = fs
  end
  b.name = UI.text(b, "body")
  b.name:SetPoint("LEFT", b.icon, "RIGHT", 8, 0)
  b.name:SetPoint("RIGHT", f, "RIGHT", NAME_RIGHT, 0)
  b:SetScript("OnEnter", function(self)
    if not self.row or self.row.header then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    local link = "item:" .. self.row.id .. (self.row.suffix ~= 0 and ("::::::::::::1:" .. self.row.suffix) or "")
    pcall(GameTooltip.SetHyperlink, GameTooltip, link)
    GameTooltip:AddLine("Click to see its live auctions and buy.", T.info[1], T.info[2], T.info[3], true)
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)
  b:SetScript("OnClick", function(self)
    if not self.row or self.row.header then return end
    if ns.openBuy and ns.openBuy(self.row) then return end
    -- a normal Blizzard search for the name shows its live auctions; buy from there as usual
    local bar = AuctionHouseFrame.SearchBar
    bar:SetSearchText(self.row.name)
    bar:StartSearch()
  end)
  return b
end

local function makeResults()
  local ah = _G.AuctionHouseFrame
  local area = ah and ah.BrowseResultsFrame
  if Q.frame or not area then return Q.frame end
  local f = UI.own(CreateFrame("Frame", "EverlookAuctionsQueryResults", area))
  f:SetAllPoints(area)
  f:SetFrameLevel(area:GetFrameLevel() + 200)
  UI.panel(f, T.bg, T.edge)
  f:EnableMouse(true)
  f:SetScript("OnShow", function() blizzardList(false) end)
  f:SetScript("OnHide", function() blizzardList(true) end)
  f:Hide()   -- frames start shown; hiding first makes the first Show run OnShow too

  -- top bar: query box, Search, Guide, Close
  local close = UI.button(f, "Close", 60, 24)
  close:SetPoint("TOPRIGHT", -8, -8)
  close:SetScript("OnClick", hideResults)

  local help = UI.button(f, "Guide", 64, 24)
  help:SetPoint("RIGHT", close, "LEFT", -6, 0)

  local go = UI.button(f, "Search", 76, 24, "primary")
  go:SetPoint("RIGHT", help, "LEFT", -6, 0)

  local save = UI.button(f, "Save", 56, 24)
  save:SetPoint("RIGHT", go, "LEFT", -6, 0)
  save:SetScript("OnClick", function()
    local q = Q.last or f.box:GetText():gsub("||", "|")
    if ns.saveToList and q and q:match("%S") then ns.saveToList(q) end
  end)
  UI.tip(save, "Save to a shopping list", "Adds this search to the shopping list picked in the Shopping tab.")

  local box = UI.input(f, 100, 24, { hint = "slot is trinket and price lt 5g | sort by price", max = 400 })
  box:SetPoint("TOPLEFT", 8, -8)
  box:SetPoint("RIGHT", save, "LEFT", -6, 0)
  local function search()
    box:ClearFocus()
    if box:GetText():match("%S") then ns.query(box:GetText()) end
  end
  box:SetScript("OnEnterPressed", search)
  go:SetScript("OnClick", search)
  f.box = box

  f.head = UI.text(f, "dim")
  f.head:SetPoint("TOPLEFT", 12, -44)
  f.head:SetPoint("RIGHT", -12, 0)
  f.head:SetText("Type a query and press Enter. Guide explains how.")

  local band = UI.headerBand(f, 22)
  band:SetPoint("TOPLEFT", 1, -(ROW_TOP - 22))
  band:SetPoint("TOPRIGHT", -1, -(ROW_TOP - 22))
  band:SetFrameLevel(f:GetFrameLevel() + 1)

  Q.headers = {}
  makeHeader(f, "Item", "name", nil, 120)
  for _, col in ipairs(COLS) do makeHeader(f, col[1], col[2], col[3], col[4]) end
  for _, h in ipairs(Q.headers) do h:SetFrameLevel(band:GetFrameLevel() + 1) end

  Q.rows = {}
  for k = 1, rowsFit(f) do Q.rows[k] = makeRow(f, k) end

  f.more = UI.text(f, "mute")
  f.more:SetPoint("BOTTOMRIGHT", -12, 8)

  f:EnableMouseWheel(true)
  f:SetScript("OnMouseWheel", function(_, delta)
    Q.offset = math.max(0, Q.offset - delta * 3)
    render()
    liveStep()
  end)

  f.guide = makeGuide(f)
  help:SetScript("OnClick", function()
    f.guide:SetShown(not f.guide:IsShown())
    help:EdbActive(f.guide:IsShown())
  end)
  f.guide:HookScript("OnHide", function() help:EdbActive(false) end)

  Q.frame = f
  return f
end

---------------------------------------------------------------------------------------------------------------------
-- Running queries, item loading, rescans

-- Item details the game hasn't loaded yet: ask for them a slice per frame, so searches see every item.
local warming = { ids = nil, i = 1, left = 0 }

-- Items in the open auction house's last scan whose details aren't saved yet.
local function unsaved()
  local db, house = ns.db(), ns.house()
  if not db or not house then return {} end
  store()
  local side, realm = house:match("%-(%a+)$"), GetRealmName()
  local rows
  for k = #db.scans, 1, -1 do
    local sc = db.scans[k]
    if sc.realm == realm and sc.side == side then rows = sc.rows; break end
  end
  local ids, seen = {}, {}
  for key in pairs(rows or {}) do
    local id = tonumber(key:match("^(%d+)"))
    if id and not seen[id] then
      seen[id] = true
      if not db.itemInfo[id] and not itemInfo(id) then ids[#ids + 1] = id end
    end
  end
  return ids
end

-- Asks the game for 100 items at a time and saves each as it arrives (GET_ITEM_INFO_RECEIVED), so nothing is lost
-- when the game drops items from memory. Only needed once per item.
local function warm()
  if warming.ids or not C_Item.RequestLoadItemDataByID then return end
  local ids = unsaved()
  if #ids == 0 then return end
  warming.ids, warming.i, warming.left = ids, 1, #ids
  local function batch()
    if not warming.ids then return end
    local stop = math.min(warming.i + 99, #ids)
    for k = warming.i, stop do pcall(C_Item.RequestLoadItemDataByID, ids[k]) end
    warming.i = stop + 1
    C_Timer.After(0.5, function()
      -- whatever arrived in the meantime is saved by the event; count what is still missing
      local left = 0
      local db = store()
      for k = 1, #ids do if not db.itemInfo[ids[k]] then left = left + 1 end end
      warming.left = left
      if warming.i <= #ids then
        batch()
      else
        warming.ids = nil
        -- anything that never arrived gets one more round later
        if left > 0 then C_Timer.After(5, warm) end
      end
    end)
  end
  batch()
end
ns.warming = warming

-- Live check: ask the server for each result item's current auctions (a few per second, the rows on screen first),
-- then show live lowest price and quantity, or "sold out".
local LIVE_MAX = 150
local SORTS = { { sortOrder = 0, reverseSort = false } }   -- Enum.AuctionHouseSortOrder.Price
local live = { tried = {}, busy = nil }

local function liveHead()
  if not Q.frame or not Q.headBase then return end
  local total, done = 0, 0
  for k = 1, math.min(#Q.results, LIVE_MAX) do
    local r = Q.results[k]
    if not r.header then
      total = total + 1
      if liveFresh(r) then done = done + 1 end
    end
  end
  local tail
  if total == 0 then tail = ""
  elseif done >= total then tail = "  " .. C_GOOD .. "live prices checked|r"
  else tail = ("  " .. C_INFO .. "checking live prices %d/%d...|r"):format(done, total) end
  Q.frame.head:SetText(Q.headBase .. tail)
end

local function applyLive(id, groups, complete)
  local now = time()
  for _, r in ipairs(Q.results) do
    if r.id == id then
      local g = groups[r.key]
      if g then
        Q.live[r.key] = { price = g.price, qty = g.qty, n = g.n, at = now }
      elseif complete then
        Q.live[r.key] = { at = now, gone = true }
      end
    end
  end
end

local function liveDone()
  live.busy = nil
  render()
  liveHead()
  C_Timer.After(0.1, liveStep)
end

local function liveSend()
  local b = live.busy
  b.key = C_AuctionHouse.MakeItemKey(b.id, b.levels[b.at], 0, 0)
  local mine, attempt = b, b.at
  local okSend = pcall(C_AuctionHouse.SendSearchQuery, b.key, SORTS, true)
  if not okSend then liveDone(); return end
  -- no answer in time: leave the row as it was and move on
  C_Timer.After(4, function() if live.busy == mine and mine.at == attempt then liveDone() end end)
end

function liveStep()
  if ns.buyOpen then return end   -- the buy panel is using the search results
  if live.busy or not Q.frame or not Q.frame:IsShown() or not C_AuctionHouse.SendSearchQuery then return end
  local function pick(from, to)
    for k = from, to do
      local r = Q.results[k]
      if r and not r.header and not liveFresh(r) and not live.tried[r.id] then return r end
    end
  end
  local r = pick(Q.offset + 1, Q.offset + #Q.rows) or pick(1, math.min(#Q.results, LIVE_MAX))
  if not r then liveHead(); return end
  if C_AuctionHouse.IsThrottledMessageSystemReady and not C_AuctionHouse.IsThrottledMessageSystemReady() then
    C_Timer.After(0.3, liveStep)
    return
  end
  live.tried[r.id] = true
  -- gear is listed under its item level; everything else under 0
  local levels = (r.slot ~= "none" and (r.ilvl or 0) > 0) and { r.ilvl, 0 } or { 0 }
  live.busy = { id = r.id, levels = levels, at = 1 }
  liveSend()
end

local function liveItemResults(itemKey)
  local b = live.busy
  if not b or type(itemKey) ~= "table" or itemKey.itemID ~= b.id then return end
  local groups, unknown = {}, false
  local n = C_AuctionHouse.GetNumItemSearchResults(itemKey) or 0
  for i = 1, n do
    local info = C_AuctionHouse.GetItemSearchResultInfo(itemKey, i)
    if info then
      local vkey = info.itemLink and ns.variantOf(b.id, info.itemLink)
      if not vkey then unknown, vkey = true, b.id .. ":0" end
      local g = groups[vkey]
      if not g then g = { qty = 0, n = 0 }; groups[vkey] = g end
      local q = info.quantity or 1
      g.qty, g.n = g.qty + q, g.n + 1
      if info.buyoutAmount and info.buyoutAmount > 0 then
        local unit = math.floor(info.buyoutAmount / q)
        if not g.price or unit < g.price then g.price = unit end
      end
    end
  end
  local full = C_AuctionHouse.HasFullItemSearchResults(itemKey)
  if n == 0 and b.at < #b.levels then
    b.at = b.at + 1
    liveSend()
    return
  end
  -- only call something sold out when the whole list came back and every auction could be told apart
  applyLive(b.id, groups, full and not unknown)
  liveDone()
end

local function liveCommodityResults(itemID)
  local b = live.busy
  if not b or itemID ~= b.id then return end
  local n = C_AuctionHouse.GetNumCommoditySearchResults(itemID) or 0
  local g = { qty = 0, n = 0 }
  for i = 1, n do
    local info = C_AuctionHouse.GetCommoditySearchResultInfo(itemID, i)
    if info then
      g.qty, g.n = g.qty + (info.quantity or 0), g.n + 1
      if info.unitPrice and (not g.price or info.unitPrice < g.price) then g.price = info.unitPrice end
    end
  end
  local total = C_AuctionHouse.GetCommoditySearchResultsQuantity and C_AuctionHouse.GetCommoditySearchResultsQuantity(itemID)
  if total and total > g.qty then g.qty = total end
  applyLive(itemID, n > 0 and { [itemID .. ":0"] = g } or {}, C_AuctionHouse.HasFullCommoditySearchResults(itemID))
  liveDone()
end

local rerunToken = 0
local function show(text)
  local results, head, missing = run(text)
  if not results then
    Q.results = {}
    setStatus(head, true)
  else
    Q.results = results
    -- a click-sort stays when the query has no sort of its own
    if Q.sortCol and not text:lower():find("sort") and not text:lower():find("top") then
      sortRows(Q.results, { { col = Q.sortCol, desc = Q.sortDesc } })
    end
    if (missing or 0) > 0 then
      setStatus(head .. ("  " .. C_DIM .. "learning %s more items (only the first time)...|r"):format(ns.num(missing)))
    else
      setStatus(head)
    end
  end
  render()
  liveHead()
  liveStep()
  -- while items are still loading, run the query again a few times as they arrive
  if results and (missing or 0) > 0 then
    rerunToken = rerunToken + 1
    local mine, tries = rerunToken, (Q.tries or 0) + 1
    Q.tries = tries
    if tries <= 200 then
      C_Timer.After(3, function()
        if mine == rerunToken and Q.frame and Q.frame:IsShown() and Q.last == text then show(text) end
      end)
    end
  end
end

function ns.query(text)
  local f = makeResults()
  if not f then return end
  if ns.closeBuy then ns.closeBuy() end
  f.box:SetText(text)
  f.guide:Hide()
  f:Show()
  -- the game's edit boxes give a typed | back as || (| starts its escape codes)
  local plain = text:gsub("||", "|"):gsub("^%s*where%s+", "")
  if plain ~= Q.last then Q.sortCol = nil end
  live.tried = {}
  Q.last, Q.tries, Q.offset, Q.grouped = plain, 0, 0, nil
  show(plain)
end
ns.lastQuery = function() return Q.last end
ns.liveStep = function() liveStep() end

-- Runs every search of a shopping list over the last full scan and shows the results one search after another,
-- each under its query. Live prices are checked as for a single search.
function ns.queryList(list)
  local f = makeResults()
  if not f or not list then return end
  if ns.closeBuy then ns.closeBuy() end
  f.guide:Hide()
  f.box:SetText("")
  f:Show()
  local out, total = {}, 0
  for _, q in ipairs(list.queries or {}) do
    local plain = q:gsub("||", "|"):gsub("^%s*where%s+", "")
    local results, head = run(plain)
    -- what one of each costs at the lowest price (from the scan): a list of materials shows its total
    local sum, priced = 0, 0
    for _, r in ipairs(results or {}) do
      if r.price then sum, priced = sum + r.price, priced + 1 end
    end
    out[#out + 1] = { header = true, name = q, count = results and #results or 0, err = not results and head or nil,
      sum = priced > 0 and sum or nil }
    for _, r in ipairs(results or {}) do out[#out + 1] = r end
    total = total + (results and #results or 0)
  end
  live.tried = {}
  Q.results, Q.grouped, Q.groupList, Q.last, Q.offset, Q.sortCol = out, list.name, list, nil, 0, nil
  setStatus(("%s: %d searches, %s results in the last full scan"):format(list.name, #(list.queries or {}), ns.num(total)))
  render()
  liveHead()
  liveStep()
end

-- A new full scan came in: search again with the fresh prices.
function ns.onScan()
  Q.cacheFor = nil
  warm()
  if Q.frame and Q.frame:IsShown() and Q.last then
    Q.tries = 0
    show(Q.last)
  elseif Q.frame and Q.frame:IsShown() and Q.grouped and Q.groupList then
    ns.queryList(Q.groupList)
  end
end

local function hook()
  local ah = _G.AuctionHouseFrame
  if Q.hooked or not ah or not ah.SendBrowseQuery then return end
  Q.hooked = true
  -- a normal Blizzard search, a category click or another tab hides the results (Advanced search brings them back)
  hooksecurefunc(ah, "SendBrowseQuery", hideResults)
  hooksecurefunc(ah, "SetDisplayMode", function() if not Q.opening then hideResults() end end)
end

-- Opens Advanced search over the auction list (switching to the Buy tab first), with the last results.
function ns.openSearch()
  local ah = _G.AuctionHouseFrame
  if not ah then return end
  local f = makeResults()
  if not f then return end
  -- the addon's own tabs cover the auction list; close them
  if ns.closeSelling then ns.closeSelling() end
  if ns.closeOthers then ns.closeOthers() end
  if AuctionHouseFrameDisplayMode and ah.GetDisplayMode and ah:GetDisplayMode() ~= AuctionHouseFrameDisplayMode.Buy then
    Q.opening = true
    ah:SetDisplayMode(AuctionHouseFrameDisplayMode.Buy)
    Q.opening = false
  end
  f:Show()
  render()
  liveStep()
  f.box:SetFocus()
end

-- The Advanced search button: on Buy's search row, above the categories (Blizzard's row has no room between its
-- search box and Filter). It belongs to the search row, so it shows on Buy only.
local function makeButton()
  local ah = _G.AuctionHouseFrame
  local row = ah and ah.SearchBar
  if Q.button or not row then return end
  local b = UI.button(row, "Advanced search", 150, 22, "primary")
  b:SetPoint("RIGHT", row, "LEFT", -8, 0)
  b:SetScript("OnClick", ns.openSearch)
  UI.tip(b, "Advanced search", "Search everything in the last price update with the same query language as EverlookDB.com: stats, slot, item and required level, price. For example: slot is trinket and price lt 5g")
  Q.button = b
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("AUCTION_HOUSE_SHOW")
ev:RegisterEvent("ITEM_SEARCH_RESULTS_UPDATED")
ev:RegisterEvent("COMMODITY_SEARCH_RESULTS_UPDATED")
ev:RegisterEvent("GET_ITEM_INFO_RECEIVED")
ev:SetScript("OnEvent", function(_, e, arg)
  if e == "GET_ITEM_INFO_RECEIVED" then
    if warming.ids and arg then itemInfo(arg) end
    return
  end
  if e == "ITEM_SEARCH_RESULTS_UPDATED" then liveItemResults(arg); return end
  if e == "COMMODITY_SEARCH_RESULTS_UPDATED" then liveCommodityResults(arg); return end
  C_Timer.After(0.2, function()
    hook()
    makeButton()
    warm()
  end)
end)
