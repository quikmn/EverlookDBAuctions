-- EverlookDB Auctions: query search over the last full scan, in the same language as EverlookDB.com.
--   slot is trinket and price lt 5g sort by price
-- The Advanced search button on Buy's search row opens it over the auction list: type a query, press Enter.
-- Click a result to find it on the auction house and buy as usual.
-- Columns: name, quality, ilvl, reqlevel, slot, category, type, sell, stack, price (lowest buyout), median, qty,
-- auctions, stats str, agi, sta, int, spi, armor, ap, sp, healing, mp5, defense, dps, hit, crit, spellhit,
-- spellcrit, block, fire_res (and holy, nature, frost, shadow, arcane), and `stats` (all stats as text).
-- effect: every Equip:, Use: and Chance on hit: line, joined with " / " (Data.lua, as on EverlookDB.com). text:
-- everything on the item's tooltip (read once per item version from the game and kept for the session). `has` without
-- a column searches text: `has "fire damage" and slot is trinket`, as on the site.
-- From EverlookDB's data (Data.lua): slots (bag size), source (every way you get it, as a list: "vendor, drop"; is,
-- has, in and the like compare whole ways, so `source is vendor` finds everything vendors sell, as on EverlookDB.com),
-- profession (that makes it), skill (needed to make it) and droprate (best drop chance, %).
-- Steps: sort by <col> [asc|desc] (no column: price), top <n> [by <col>], count; a | between steps is optional.
-- Below vendor price (Vendor.lua): `belowvendor` on its own, or a money column compared with another column
-- (`price lt vendor`). profit is the vendor price minus the lowest buyout, each; stackprofit is that for a full stack.
-- belowvendor works from the scan's single auctions (Vendor.lua): deals is how many auctions are under vendor price
-- and make at least 10s each (any amount when the search names profit), dealprofit what they make together.

local ADDON, ns = ...
local UI, T = ns.UI, ns.T
local V = ns.vendor
local PLACE = T.places.search   -- Advanced search's colour (and its buy panel's): where you are
local C_BAD, C_MUTE, C_DIM, C_GOOD, C_INFO, C_PLACE =
  UI.hex(T.bad), UI.hex(T.mute), UI.hex(T.dim), UI.hex(T.good), UI.hex(T.info), UI.hex(PLACE)

local ROW_H = 22

local Q = { results = {}, offset = 0 }
local liveStep   -- the live check (defined further down; the panel's scroll uses it)
local blizzardSearch, modeButton   -- Blizzard's search row on or off, the Advanced search button's look (further down)
local belowVendor   -- the Below vendor button (further down)
local live = { tried = {}, busy = nil }   -- the live check: items tried, the one being looked up

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
-- Everyday words for enum values: "slot is cloak", "quality is blue"
local ENUM_ALIAS = {
  quality = { grey = "poor", gray = "poor", white = "common", green = "uncommon", blue = "rare", purple = "epic",
    orange = "legendary" },
  slot = { cloak = "back", cape = "back", ring = "finger", helm = "head", helmet = "head", shoulders = "shoulder",
    belt = "waist", boots = "feet", bracers = "wrist", gloves = "hands", pants = "legs", ["1h"] = "onehand",
    ["2h"] = "twohand", ["one-hand"] = "onehand", ["two-hand"] = "twohand", ["off-hand"] = "offhand",
    ["main-hand"] = "mainhand", amulet = "neck", necklace = "neck" },
}
local function enumIndex(col, v)
  v = tostring(v):lower()
  local alias = ENUM_ALIAS[col]
  return ENUMS[col][alias and alias[v] or v]
end

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
  profit = "money", stackprofit = "money",
  deals = "number", dealprofit = "money",   -- below vendor: auctions under vendor price, and what they all make
}
for k in pairs(STATS) do KIND[k] = "number" end
KIND.stats = "text"   -- every stat on the item as text, e.g. "Stamina 5, Agility 3": `stats has agility`
KIND.effect = "text"  -- "Equip: ... / Use: ...": `effect has "run speed"`
KIND.text = "text"    -- everything on the tooltip: `text has "fire damage"`, or `has "fire damage"` on its own
local ALIAS = {
  rarity = "quality", subtype = "type", subclass = "type", itemclass = "category", level = "reqlevel", lvl = "reqlevel",
  req = "reqlevel", reqlvl = "reqlevel", lvlreq = "reqlevel", levelreq = "reqlevel", minlevel = "reqlevel", vendor = "sell", low = "price", lowest = "price",
  buyout = "price", med = "median", typical = "median", quantity = "qty", count = "qty", up = "auctions",
  strength = "str", agility = "agi", stamina = "sta", stam = "sta", intellect = "int", intel = "int", spirit = "spi",
  ac = "armor", armour = "armor", firres = "fire_res", fireres = "fire_res", frostres = "frost_res",
  drop = "droprate", dropchance = "droprate", chance = "droprate", bagslots = "slots", size = "slots", prof = "profession", craftedby = "profession", from = "source",
  vendorprofit = "profit", flip = "profit", totalprofit = "dealprofit", dealsprofit = "dealprofit", stack_profit = "stackprofit", perstack = "stackprofit",
  effects = "effect", tooltip = "text",
  natureres = "nature_res", shadowres = "shadow_res", arcaneres = "arcane_res", blockvalue = "block", attackpower = "ap", spellpower = "sp", heal = "healing", def = "defense",
}
-- Columns that hold a comma list ("vendor, drop"): is, has, in, startswith... compare each element, as on the site.
local LIST = { source = true }
-- The ways to get an item, in Data.lua's order (ns.SOURCES bits); kept here so a shorter ns.SOURCES can't make a
-- valid word an error. Other words for them, typed only: never shown.
local SOURCES = { "vendor", "crafted", "drop", "quest", "skinning", "pickpocket", "fishing", "herbalism", "mining",
  "object", "world drop", "container", "disenchant" }
local SOURCE_OK = index(SOURCES)
local SOURCE_ALIAS = { profession = "crafted", automatic = "auto", worlddrop = "world drop", world_drop = "world drop" }
-- Professions that aren't also a way to get an item: typed as a source, the error points at the profession column.
local PROFESSION = { alchemy = true, blacksmithing = true, cooking = true, enchanting = true, engineering = true,
  ["first aid"] = true, leatherworking = true, poisons = true, tailoring = true, jewelcrafting = true }
local function sourceWord(v)
  v = tostring(v):lower():match("^%s*(.-)%s*$")
  return SOURCE_ALIAS[v] or v
end

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

-- "5g", "50s", "1g50s", "20c", "1.5g", "2gold" -> copper; plain numbers stay numbers; anything else is nil
local function moneyValue(v)
  if type(v) ~= "string" then return v end
  local s = v:lower():gsub("gold", "g"):gsub("silver", "s"):gsub("copper", "c")
  local total, any = 0, false
  local rest = s:gsub("(%d+%.?%d*)([gsc])", function(n, unit)
    total = total + tonumber(n) * (unit == "g" and 10000 or unit == "s" and 100 or 1)
    any = true
    return ""
  end)
  if any then
    if rest:match("%S") then return nil end   -- "5gx": not money
    return math.floor(total + 0.5)
  end
  return tonumber(v)
end
local function moneyWord(v) return type(v) == "string" and v:lower():match("^%d+%.?%d*[gsc]$") ~= nil end

local Parser = {}
Parser.__index = Parser

function Parser:peek(o) return self.toks[self.pos + (o or 0)] end
function Parser:next() local t = self.toks[self.pos]; self.pos = self.pos + 1; return t end
function Parser:isWord(w, o) local t = self:peek(o); return t and t.t == "word" and t.v:lower() == w end
function Parser:isOp(v, o) local t = self:peek(o); return t and t.t == "op" and t.v == v end
function Parser:fail(msg) error({ query = msg }, 0) end

local EG = "type has wand and reqlevel le 29 sort by price"   -- the example most errors end with

-- An example value for a column, for error messages: "reqlvl le what? e.g. reqlvl le 29"
local EXAMPLE = { quality = "rare", slot = "trinket", type = "wand", category = '"Trade Goods"', name = '"of the bear"',
  stats = "spirit", source = "vendor", profession = "tailoring", effect = '"run speed"', text = '"fire damage"' }
local function example(col)
  return EXAMPLE[col] or KIND[col] == "money" and "5g" or KIND[col] == "text" and "wand" or "29"
end
local function exampleOp(col)
  return KIND[col] == "text" and "has" or KIND[col] == "enum" and "is" or "le"
end

-- missing: the error when there is no value here (what is missing, with an example)
function Parser:value(missing)
  local t = self:next()
  if not t or t.t == "op" then self:fail(missing or ("a value is missing; e.g. " .. EG)) end
  return t.v
end

function Parser:list(missing)
  if not self:isOp("(") then return { self:value(missing) } end
  self:next()
  local out = {}
  repeat
    out[#out + 1] = self:value(missing)
    if self:isOp(",") then self:next() else break end
  until false
  if not self:isOp(")") then self:fail("a ) is missing; e.g. slot in (head, chest)") end
  self:next()
  return out
end

-- Money typed with spaces: "price lt 1g 50s" is one amount, not 1g and a name search for "50s".
function Parser:moneyMore(col, v)
  if KIND[col] ~= "money" or not moneyWord(v) then return v end
  while self:peek() and self:peek().t == "word" and moneyWord(self:peek().v) do v = v .. self:next().v end
  return v
end

-- A value that can't mean anything for its column is an error with an example, not a search that finds nothing.
local TEXT_OPS = { has = true, starts = true, ends = true, like = true, notlike = true }
local VALUE_EG = { quality = "quality ge rare", slot = "slot is back" }
local SOURCE_CHECK = { eq = true, ne = true, has = true, ["in"] = true }
function Parser:check(col, word, op, v)
  local kind = KIND[col]
  if col == "source" and SOURCE_CHECK[op] then
    local w = sourceWord(v)
    if w == "" or SOURCE_OK[w] then return end
    local list = table.concat(SOURCES, ", ")
    if PROFESSION[w] then
      self:fail(('%s is a profession, not a way to get an item; source is how you get it, one of: %s; e.g. profession is %s')
        :format(w, list, w))
    end
    self:fail(('no item comes from "%s"; source is how you get it, one of: %s; e.g. %s is vendor'):format(v, list, word))
  end
  if TEXT_OPS[op] or kind == "text" then return end
  if kind == "enum" then
    if enumIndex(col, v) then return end
    local list = col == "quality" and "poor, common, uncommon, rare, epic or legendary" or "head, chest, back, finger, trinket... (the Guide lists them all)"
    self:fail(('no %s called "%s"; try %s; e.g. %s'):format(col, v, list, VALUE_EG[col]))
  end
  local ref = column(v)
  if ref and (KIND[ref] == "money" or KIND[ref] == "number") then return end   -- another column: price lt vendor
  if kind == "money" then
    if moneyValue(v) then return end
    self:fail(('"%s" isn\'t an amount of money; e.g. %s lt 1g50s, or %s lt 2.5g'):format(v, word, word))
  end
  if not tonumber(v) then
    self:fail(('"%s" isn\'t a number; e.g. %s %s %s'):format(v, word, exampleOp(col), example(col)))
  end
end

-- a column, a comparison and a value: "slot is trinket", "price lt 5g", "ilvl between (20 .. 30)"
-- word is the column as typed (an alias like lvlreq), for error messages
function Parser:comparison(col, word)
  word = word or col
  local negate = false
  if self:isWord("not") or self:isOp("!") then self:next(); negate = true end
  local t = self:next()
  local op = t and OPS[t.v:lower()]
  if t and t.t == "word" and t.v:lower() == "is" and self:isWord("not") then self:next(); op = "ne" end
  if t and t.v == "!" then op = nil end
  if not op then
    self:fail(("after %s comes a comparison like is, gt, ge, lt, le or has; e.g. %s %s %s"):format(
      word, word, exampleOp(col), example(col)))
  end
  local opWord = t.v
  if op == "between" then
    local lo, hi = "20", "30"
    if KIND[col] == "money" then lo, hi = "1g", "5g" end
    local missing = ("%s between what? e.g. %s between (%s .. %s)"):format(word, word, lo, hi)
    if self:isOp("(") then self:next() end
    local a = self:moneyMore(col, self:value(missing))
    if self:isOp("..") then self:next() elseif self:isWord("and") then self:next() end
    local b = self:moneyMore(col, self:value(missing))
    if self:isOp(")") then self:next() end
    self:check(col, word, op, a)
    self:check(col, word, op, b)
    return { k = "cmp", col = col, op = op, a = a, b = b, neg = negate }
  end
  local mode
  if self:isWord("any") or self:isWord("anyof") then self:next(); mode = "any"
  elseif self:isWord("all") or self:isWord("allof") then self:next(); mode = "all" end
  if mode and self:isWord("of") then self:next() end
  local values
  if op == "in" or mode then
    values = self:list(("%s %s what? e.g. %s %s (head, chest)"):format(word, opWord, word, opWord))
  else
    values = { self:value(("%s %s what? e.g. %s %s %s"):format(word, opWord, word, opWord, example(col))) }
  end
  for i, v in ipairs(values) do
    values[i] = self:moneyMore(col, v)
    self:check(col, word, op, values[i])
  end
  if col == "price" or col == "profit" or col == "stackprofit" then
    for _, v in ipairs(values) do if column(v) == "sell" or col ~= "price" then self.vendor = true end end
  end
  return { k = "cmp", col = col, op = op == "in" and "eq" or op, values = values, all = mode == "all", neg = negate }
end

-- Step words. Without a | in front, one starts a step only where a new condition or the end could come, and only
-- when what follows fits the step: "type has wand sort by price", while "name has sort" and "count gt 5" stay as
-- they are.
local STEP = { where = true, sort = true, order = true, top = true, take = true, limit = true, count = true }
local DIR = { asc = true, ascending = true, desc = true, descending = true }

function Parser:atStep()
  local t = self:peek()
  if not t or t.t ~= "word" then return false end
  local w = t.v:lower()
  if not STEP[w] then return false end
  local n = self:peek(1)
  local nw = n and n.v:lower()
  if w == "where" and (nw == "has" or nw == "contains") then return true end   -- "where has speed"
  if n and n.t == "op" and n.v ~= "|" then return false end   -- "count >= 5"
  if nw and OPS[nw] then return false end                     -- "count gt 5"
  if w == "sort" or w == "order" then
    return not n or n.t == "op" or nw == "by" or DIR[nw] or STEP[nw] or column((nw:gsub("^%-", ""))) ~= nil
  elseif w == "top" or w == "take" or w == "limit" then
    return n ~= nil and tonumber(n.v) ~= nil
  elseif w == "count" then
    return not n or n.t == "op" or STEP[nw] or false
  end
  return n ~= nil and n.t == "word"   -- where
end

function Parser:primary()
  if self:isOp("(") then
    self:next()
    local e = self:orExpr()
    if not self:isOp(")") then self:fail("a ) is missing; e.g. (slot is head or slot is chest) and int ge 5") end
    self:next()
    return e
  end
  if self:isWord("not") or self:isOp("!") then
    self:next()
    return { k = "not", e = self:primary() }
  end
  local prev = self:peek(-1)
  local t = self:next()
  if not t then
    if prev then self:fail(("something is missing after %s; e.g. %s"):format(prev.v, EG)) end
    self:fail("type a search, e.g. " .. EG)
  end
  if t.t == "op" then self:fail(("%s can't go here; e.g. %s"):format(t.v, EG)) end
  local nxt = self:peek()
  -- belowvendor: auctions cheaper than a vendor pays
  if t.t == "word" and V.WORDS[t.v:lower()] and not (nxt and OPS[nxt.v:lower()]) then
    self.vendor = true
    return { k = "below" }
  end
  -- has without a column searches everything on the tooltip: `has "fire damage"` is `text has "fire damage"` (as on
  -- EverlookDB.com). At the end, or before a | or ), it stays a word.
  local tw = t.t == "word" and t.v:lower()
  if (tw == "has" or tw == "contains") and nxt and not (nxt.t == "op" and (nxt.v == "|" or nxt.v == ")")) then
    self.pos = self.pos - 1
    return self:comparison("text")
  end
  local col = t.t == "word" and column(t.v)
  if col and nxt and (OPS[nxt.v:lower()] or nxt.v:lower() == "not" or nxt.v == "!") then
    return self:comparison(col, t.v)
  end
  -- a word on its own searches names
  return { k = "cmp", col = "name", op = "has", values = { t.v } }
end

function Parser:andExpr()
  local e = self:primary()
  while true do
    if self:isWord("and") then
      self:next()
      if self:atStep() then break end   -- "... and sort by price": the and leads into the step
    elseif not self:peek() or self:isWord("or") or self:isOp(")") or self:isOp("|") or self:atStep() then
      break
    end
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

local SORT_EG = "e.g. sort by price asc, or sort by ilvl desc, price"

-- "type has wand and reqlevel le 29 sort by price desc top 10 by ilvl" -> list of steps. "items | where" in front
-- and a | between steps are optional. A sort without a column sorts by price (the lowest buyout).
local function parse(text)
  local p = setmetatable({ toks = tokenize(text), pos = 1 }, Parser)
  local steps = {}
  if p:isWord("items") or p:isWord("item") then p:next() end
  if p:isWord("where") and p:atStep() then p:next() end
  local leading = (p:isWord("sort") or p:isWord("order") or p:isWord("top") or p:isWord("take") or p:isWord("limit"))
    and p:atStep()
  if p:peek() and not p:isOp("|") and not leading then
    -- no "items |" in front: treat the rest as a where
    steps[#steps + 1] = { k = "where", e = p:orExpr() }
  end
  while p:peek() do
    local w
    if p:isOp("|") then
      p:next()
      w = p:peek()
      if not w then p:fail("a step is missing after |; e.g. | sort by price") end
      if w.t ~= "word" or not STEP[w.v:lower()] then w = nil end   -- "| type has wand": a where without the word
    elseif p:atStep() then
      w = p:peek()
    else
      p:fail(("not sure what %s means here; e.g. %s"):format(p:peek().v, EG))
    end
    if w then p:next() end
    local word = w and w.v:lower() or "where"
    if word == "where" then
      steps[#steps + 1] = { k = "where", e = p:orExpr() }
    elseif word == "sort" or word == "order" then
      if p:isWord("by") then p:next() end
      local keys = {}
      repeat
        local desc = false
        if p:isWord("desc") or p:isWord("descending") then p:next(); desc = true
        elseif p:isWord("asc") or p:isWord("ascending") then p:next() end
        local t, name = p:peek(), nil
        if #keys == 0 and (not t or t.t == "op" or (p:atStep() and not column(t.v))) then
          name = "price"   -- no column: by the lowest buyout ("sort", "sort asc", "sort by desc")
        else
          name = p:value("sort by which column? " .. SORT_EG)
        end
        if name:sub(1, 1) == "-" then desc, name = true, name:sub(2) end
        local c = column(name)
          or p:fail(("can't sort by %s; e.g. sort by price, or sort by ilvl desc"):format(name))
        if p:isWord("desc") or p:isWord("descending") then p:next(); desc = true
        elseif p:isWord("asc") or p:isWord("ascending") then p:next(); desc = false end
        keys[#keys + 1] = { col = c, desc = desc }
        local more = p:isOp(",")
        if more then p:next() end
      until not more
      steps[#steps + 1] = { k = "sort", keys = keys }
    elseif word == "top" or word == "take" or word == "limit" then
      local missing = ("%s how many? e.g. %s 10, or %s 10 by ilvl"):format(word, word, word)
      local n = tonumber(p:value(missing)) or p:fail(missing)
      local step = { k = "top", n = n }
      if p:isWord("by") then
        p:next()
        local by = ("%s %d by which column? e.g. %s %d by sta"):format(word, n, word, n)
        local c = column(p:value(by)) or p:fail(by)
        local desc = true
        if p:isWord("asc") or p:isWord("ascending") then p:next(); desc = false
        elseif p:isWord("desc") or p:isWord("descending") then p:next() end
        step.keys = { { col = c, desc = desc } }
      end
      steps[#steps + 1] = step
    elseif word == "count" then
      steps[#steps + 1] = { k = "count" }
    end
  end
  steps.vendor = p.vendor   -- a below-vendor search: shows profit columns, sorted by profit unless it says otherwise
  return steps
end

---------------------------------------------------------------------------------------------------------------------
-- Rows and evaluation

-- Item details are saved once in the addon's own file (db.itemInfo, db.itemStats): the game keeps only so many items
-- in memory, so asking it again on every search would give a different set each time.
-- Saved compactly, one line of text per item ("quality^ilvl^req^category^type^slot^icon^sell^stack^name", the slot
-- without its INVTYPE_), about half the size of a table per item; read into tables as they are used.
local packedOnce = false
local unpackItem
local function packItem(c)
  local equip = tostring(c[7] or ""):gsub("^INVTYPE_", "")
  return table.concat({ c[2] or 1, c[3] or 0, c[4] or 0, c[5] or "", c[6] or "", equip, c[8] or 0, c[9] or 0,
    c[10] or 1, (tostring(c[1] or ""):gsub("%^", "")) }, "^")
end
local function store()
  local db = ns.db()
  if not db then return nil end
  db.itemInfo = db.itemInfo or {}
  db.itemStats = db.itemStats or {}
  if not packedOnce then
    -- details saved as tables by earlier versions: packed once per session
    packedOnce = true
    for id, c in pairs(db.itemInfo) do
      if type(c) == "table" then db.itemInfo[id] = packItem(c) end
    end
  end
  return db
end

function unpackItem(text)
  local q, ilvl, req, cat, kind, equip, icon, sell, stack, name =
    text:match("^([^^]*)^([^^]*)^([^^]*)^([^^]*)^([^^]*)^([^^]*)^([^^]*)^([^^]*)^([^^]*)^(.*)$")
  if not q then return nil end
  return { name, tonumber(q) or 1, tonumber(ilvl) or 0, tonumber(req) or 0, cat, kind,
    equip ~= "" and ("INVTYPE_" .. equip) or "", tonumber(icon) or icon, tonumber(sell) or 0, tonumber(stack) or 1 }
end

local unpacked = {}   -- id -> the saved line read into a table, this session

-- { name, quality, ilvl, reqlevel, category, type, equipLoc, icon, sell, stack } or nil while the game loads it.
local function itemInfo(id)
  local db = store()
  local saved = db and db.itemInfo[id]
  if type(saved) == "table" then return saved end
  if saved then
    local c = unpacked[id]
    if c and c.edbFrom == saved then return c end
    c = unpackItem(saved)
    if c then
      c.edbFrom = saved
      unpacked[id] = c
      return c
    end
  end
  local name, _, quality, ilvl, req, category, kind, stack, equip, icon, sell = C_Item.GetItemInfo(id)
  if not name then return nil end
  local c = { name, quality or 1, ilvl or 0, req or 0, category or "", kind or "", equip or "", icon or 0, sell or 0, stack or 1 }
  if db then
    db.itemInfo[id] = packItem(c)
    c.edbFrom = db.itemInfo[id]
    unpacked[id] = c
  end
  return c
end
ns.itemInfo = itemInfo
ns.packItem, ns.unpackItem = packItem, function(t) return unpackItem(t) end   -- for tests/run.py

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

-- The effect and text columns, as on EverlookDB.com.
-- effect: on an English client from Data.lua (the site's own lines: instant, no tooltip needed, the same results as
-- the site); an item Data.lua has no line for uses its tooltip's Equip/Use/Chance on hit lines once the tooltip has
-- been read. On other languages always from the tooltip, so effect words are in the client's language.
-- text: everything the game's tooltip for the item version says (read with C_TooltipInfo once per version and kept
-- for the session, never per search), plus its name and effect lines. Until a tooltip can be read it is the name and
-- effect lines. Reading starts in the background when Advanced search opens, a few items per frame.
local ENGLISH = not GetLocale or (GetLocale() or "enUS"):sub(1, 2) == "en"
local tipText, tipEffect = {}, {}   -- "id:suffix" -> the tooltip's lines, and its own effect lines, joined " / "
local effectCache = {}               -- item id -> Data.lua's effect lines joined, or false

local function dataEffect(id)
  local c = effectCache[id]
  if c ~= nil then return c or nil end
  local e = ns.EFFECT and ns.EFFECT[id]
  local lines = ns.EFFECTLINES or {}
  if type(e) == "number" then
    c = lines[e]
  elseif type(e) == "table" then
    local t = {}
    for _, k in ipairs(e) do t[#t + 1] = lines[k] end
    c = table.concat(t, " / ")
  end
  effectCache[id] = c or false
  return c
end

-- One tooltip line as the site keeps it: no colour or grammar codes (|4Sec:Sec; -> Sec), single spaces.
local function tidy(s)
  s = s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|4([^:;]*):[^;]*;", "%1")
  return (s:gsub("%s+", " "):match("^ ?(.-) ?$"))
end

local function triggers()
  return { (ITEM_SPELL_TRIGGER_ONEQUIP or "Equip:") .. " ", (ITEM_SPELL_TRIGGER_ONUSE or "Use:") .. " ",
    (ITEM_SPELL_TRIGGER_ONPROC or "Chance on hit:") .. " " }
end

local function itemLink(row)
  return "item:" .. row.id .. (row.suffix ~= 0 and ("::::::::::::1:" .. row.suffix) or "")
end

-- Reads an item version's tooltip once: true when it is (now) known, false while the game is still loading it.
local function readTip(row)
  local key = row.key
  if tipText[key] then return true end
  local api = C_TooltipInfo
  if not api then return false end
  -- not in the game's memory: ask for it, read it next time (the tooltip would only say it is retrieving)
  if C_Item.IsItemDataCachedByID and not C_Item.IsItemDataCachedByID(row.id) then
    if C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(row.id) end
    return false
  end
  local ok, data
  if row.suffix ~= 0 and api.GetHyperlink then ok, data = pcall(api.GetHyperlink, itemLink(row)) end
  if not (ok and type(data) == "table") and api.GetItemByID then ok, data = pcall(api.GetItemByID, row.id) end
  if not ok or type(data) ~= "table" or type(data.lines) ~= "table" or #data.lines == 0 then return false end
  local retrieving = RETRIEVING_ITEM_INFO or "Retrieving item information"
  local trig = triggers()
  local teaches = trig[2] .. "Teaches"   -- a recipe's own "Use: Teaches ..." line can come after the made item
  local all, eff, embedded = {}, {}, false
  for _, l in ipairs(data.lines) do
    for side = 1, 2 do
      local raw = side == 1 and l.leftText or l.rightText
      if type(raw) == "string" and raw ~= "" then
        -- a recipe shows the item it makes below a line starting with a line break: those effects aren't its own
        if side == 1 and raw:sub(1, 1) == "\n" then embedded = true end
        local line = tidy(raw)
        if line == retrieving then return false end
        if line ~= "" then
          all[#all + 1] = line
          if side == 1 and (not embedded or line:sub(1, #teaches) == teaches) then
            for _, p in ipairs(trig) do
              if line:sub(1, #p) == p then eff[#eff + 1] = line; break end
            end
          end
        end
      end
    end
  end
  tipText[key], tipEffect[key] = table.concat(all, " / "), table.concat(eff, " / ")
  return true
end

local function effectOf(row)
  if ENGLISH then
    local e = dataEffect(row.id)
    if e then return e end
    return tipEffect[row.key] or ""
  end
  readTip(row)
  return tipEffect[row.key] or ""
end

-- The name, the tooltip's lines and the effect lines, each line once (like the site's text column).
local textCache = {}
local function textOf(row)
  local c = textCache[row.key]
  if c then return c end
  local known = readTip(row)
  local lines, seen = {}, {}
  local function add(s)
    if not s or s == "" then return end
    local i = 1
    while true do
      local j = s:find(" / ", i, true)
      local line = s:sub(i, (j or 0) - 1)
      if line ~= "" and not seen[line] then seen[line] = true; lines[#lines + 1] = line end
      if not j then break end
      i = j + 3
    end
  end
  add(row.name)
  add(tipText[row.key])
  add(effectOf(row))
  c = table.concat(lines, " / ")
  if known then textCache[row.key] = c else Q.tipsPending = (Q.tipsPending or 0) + 1 end
  return c
end

-- Reads the tooltips of the whole scan a few per frame while Advanced search is open, so a text search finds them
-- read already; one run at a time.
local tipWarming
local function warmTips(rows)
  if tipWarming or not rows or not C_TooltipInfo then return end
  tipWarming = true
  local k = 1
  local function step()
    local done = 0
    while k <= #rows and done < 20 do
      if not tipText[rows[k].key] then readTip(rows[k]); done = done + 1 end
      k = k + 1
    end
    if k <= #rows and Q.frame and Q.frame:IsShown() then
      C_Timer.After(0.1, step)
    else
      tipWarming = nil
    end
  end
  step()
end

local LIVE_TTL = 300   -- a live check counts for 5 minutes

Q.live = {}   -- "id:suffix" -> { price, qty, n, at, gone } from the live check; survives re-running the query

local function liveOf(r)
  local l = Q.live[r.key]
  if l and time() - l.at < LIVE_TTL then return l end
end
local function liveFresh(r) return liveOf(r) ~= nil end
ns.liveFresh = liveFresh
-- The buy panel's complete live answer for a row's key ({ price, qty } or { gone = true }), so the row shows it.
function ns.setLive(key, entry)
  if not key or type(entry) ~= "table" then return end
  entry.at = time()
  Q.live[key] = entry
  if Q.liveMiss then Q.liveMiss[key] = nil end
end

-- Rows the live check asked about but got no price for: "noanswer" (the auction house didn't answer) or "unclear"
-- (an incomplete answer that can't tell this version apart). Asked again after LIVE_RETRY seconds.
local LIVE_RETRY = 60
Q.liveMiss = {}   -- "id:suffix" -> { at, why }
local function missOf(r)
  local m = Q.liveMiss[r.key]
  if m and time() - m.at < LIVE_RETRY then return m end
end

local function get(row, col)
  if STATS[col] then return statsOf(row)[col] or 0 end
  if col == "deals" then return row.dealN end
  if col == "dealprofit" then return row.dealProfit end
  -- what buying at the lowest price and selling to a vendor makes (vendors take no cut); none for quest items
  if col == "profit" or col == "stackprofit" then
    if row.quest then return nil end
    local price = get(row, "price")
    if col == "profit" then return V.profit(price, row.sell) end
    return V.stackProfit(price, row.sell, row.stack)
  end
  -- price and quantity: the live check when there is a fresh one (sold out = nothing up)
  local l = (col == "price" or col == "qty" or col == "auctions") and liveOf(row)
  if l then
    if l.gone then return col ~= "price" and 0 or nil end
    local v = l[col == "auctions" and "n" or col]
    if v ~= nil then return v end
  end
  if col == "stats" then return statsOf(row).stats end
  if col == "effect" then return effectOf(row) end
  if col == "text" then return textOf(row) end
  if col == "scanprice" then return row.price end
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

-- A list column ("vendor, drop"): want compared with each element; ne and notlike are the opposite of a match.
-- An empty want compares the whole text: `source is ""` is no source at all.
local function listMatch(have, op, want)
  want = sourceWord(want)
  if want == "" then return textMatch(have, op, want) end
  local elOp = (op == "ne" or op == "has") and "eq" or op == "notlike" and "like" or op
  local found = false
  for el in tostring(have or ""):gmatch("[^,]+") do
    el = el:match("^%s*(.-)%s*$")
    if el ~= "" and textMatch(el, elOp, want) then found = true; break end
  end
  if op == "ne" or op == "notlike" then return not found end
  return found
end

local function numberOf(col, v)
  local kind = KIND[col]
  if kind == "enum" then return enumIndex(col, v) end
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

-- A value that names a number or money column compares with that column of the same row: `price lt vendor`.
-- The vendor price of a quest item or of an item vendors don't buy counts as no value.
local function valueOf(row, col, want)
  local ref = KIND[col] ~= "text" and KIND[col] ~= "enum" and type(want) == "string" and column(want)
  if ref and (KIND[ref] == "money" or KIND[ref] == "number") then
    if ref == "sell" and (row.quest or (row.sell or 0) <= 0) then return nil end
    return get(row, ref)
  end
  return numberOf(col, want)
end

-- A condition that reads tooltips (text, and effect on a non-English client): the first search over a whole scan
-- reads the game's tooltip of every item it has to look at, so and/or look at the other side first and only read the
-- tooltips of items that side leaves open (`has "fire damage" and slot is trinket` reads trinkets' tooltips only).
local function slow(e)
  if e.k == "and" or e.k == "or" then return slow(e.a) or slow(e.b) end
  if e.k == "not" then return slow(e.e) end
  return e.k == "cmp" and (e.col == "text" or (e.col == "effect" and not ENGLISH)) or false
end

local function test(row, e)
  if e.k == "below" then
    if row.dealN ~= nil then return row.dealN > 0 end
    local p = get(row, "profit")
    return p ~= nil and p > 0
  end
  if e.k == "and" or e.k == "or" then
    if e.slowFirst == nil then e.slowFirst = slow(e.a) and not slow(e.b) end
    local a, b = e.a, e.b
    if e.slowFirst then a, b = b, a end   -- same answer either way: these tests have no side effects on the result
    if e.k == "and" then return test(row, a) and test(row, b) end
    return test(row, a) or test(row, b)
  end
  if e.k == "not" then return not test(row, e.e) end
  local col, op = e.col, e.op
  local kind = KIND[col]
  local r
  if op == "between" then
    local v = kind == "enum" and ENUMS[col][tostring(get(row, col))] or get(row, col)
    local a, b = valueOf(row, col, e.a), valueOf(row, col, e.b)
    r = v ~= nil and a ~= nil and b ~= nil and v >= a and v <= b
  else
    local one = function(want)
      if LIST[col] then return listMatch(get(row, col), op, want) end
      if kind == "text" or op == "has" or op == "starts" or op == "ends" or op == "like" or op == "notlike" then
        return textMatch(get(row, col), op, want)
      end
      local have = get(row, col)
      if kind == "enum" then have = ENUMS[col][tostring(have)] end
      return compare(have, op, valueOf(row, col, want))
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

-- The newest full scan of a house ("Realm-Side"): our own, or other players' shared one (SharedPrices.lua, the same
-- row form, shared = true) when that is newer. nil when there is neither.
local function newestScan(db, house)
  local side = house:match("%-(%a+)$")
  local realm, realmID
  if ns.realmInfo then realm, realmID = ns.realmInfo() else realm = GetRealmName() end
  local scanned
  for k = #db.scans, 1, -1 do
    local sc = db.scans[k]
    -- by name, or by realm ID (a scan saved while the game didn't say the realm's name)
    if sc.side == side and ((realm and sc.realm == realm) or (realmID and sc.realmID == realmID)) then scanned = sc; break end
  end
  local shared = ns.shared and ns.shared.scan(house)
  if shared and (not scanned or shared.at > (scanned.at or 0)) then return shared end
  return scanned
end

local function dataset()
  local db, house = ns.db(), ns.house() or (ns.houseOrFaction and ns.houseOrFaction())
  if not db or not house then return nil end
  local scanned = newestScan(db, house)
  if not scanned then return nil end
  if Q.cacheFor == scanned then return Q.cache, scanned, Q.missing end
  local rows, missing = {}, 0
  for key, line in pairs(scanned.rows or {}) do
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
        quest = V.isQuest(id, c[5]),
        source = sourceText(d[1]), profession = ns.PROFESSIONS and ns.PROFESSIONS[d[2] or 0] or "",
        skill = d[3] or 0, slots = d[4] or 0, droprate = d[5] or 0,
        dealText = scanned.deals and scanned.deals[key] or nil,
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
ns.queryParse = function(text) return parse(text) end   -- for the offline tests

local function run(text)
  local lower = " " .. (text or ""):lower() .. " "
  Q.extra = lower:find("[^%w_]slots[^%w_]") and "slots" or lower:find("[^%w_]skill[^%w_]") and "skill"
    or lower:find("[^%w_]droprate[^%w_]") and "droprate" or nil
  local okParse, steps = pcall(parse, text)
  if not okParse then
    return nil, type(steps) == "table" and steps.query or tostring(steps)
  end
  local rows, scanned, missing = dataset()
  Q.tipsPending = 0
  if not rows then
    return nil, Q.away and "No full scan of your faction's auction house yet: visit it once and let the scan finish."
      or "No full scan of this auction house yet: open it and let the scan finish first."
  end
  -- a below-vendor search: each item's auctions under vendor price from the scan, those making at least 10s (any
  -- amount when the search says how much profit it wants); biggest total first unless it orders itself
  local deals = steps.vendor and scanned.deals ~= nil
  -- does the search order its own results (sort, or top n by a column)? Then a header click doesn't re-sort them.
  local ordered = false
  for _, st in ipairs(steps) do if st.k == "sort" or st.keys then ordered = true end end
  if steps.vendor then
    local minProfit = lower:find("profit") and 0 or V.MIN_DEAL
    for _, r in ipairs(rows) do
      if deals and not r.quest and r.dealText then
        local list = V.dealsOf(r.dealText, r.sell, minProfit)
        r.deals = list
        r.dealN, r.dealProfit = V.dealSummary(list)
      elseif deals then
        r.deals, r.dealN, r.dealProfit = nil, 0, nil
      else
        r.deals, r.dealN, r.dealProfit = nil, nil, nil   -- a scan from before deals were saved: the old way
      end
    end
    if not ordered then
      steps[#steps + 1] = { k = "sort", keys = { { col = deals and "dealprofit" or "profit", desc = true } } }
    end
  end
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
  head = head .. (scanned.shared and " in other players' scan %s" or " in the full scan %s"):format(ns.ago(scanned.at))
  Q.deals = deals
  Q.ordered = ordered
  -- tooltips the game is still loading count as items still to learn: the search runs again as they arrive
  return counted and {} or out, head, (missing or 0) + Q.tipsPending, steps.vendor and true or false
end

ns.queryRun = function(text) return run(text) end
ns.queryOrdered = function() return Q.ordered end   -- for the offline tests: did the last search order itself

---------------------------------------------------------------------------------------------------------------------
-- The Advanced search panel, over the auction list

local ROW_TOP = 122         -- first result row, from the top of the panel (under the title, query box, buttons, headers)

-- Result columns: header, column to sort by, right edge (from the panel's right), width, and how to show the value.
-- Live-checked values are white; values only from the scan are grey; sold-out rows say so.
local GREY = C_DIM .. ""
local function upCell(r)
  local l = liveOf(r)
  if l then return l.gone and C_BAD .. "0|r" or ns.num(l.qty or 0) end
  return GREY .. ns.num(r.qty or 0) .. "|r"
end
-- Now: only what the auction house said in the last few minutes, never the scan. No answer is never "none up".
local function lowestCell(r)
  local l = liveOf(r)
  if l then
    if l.gone then return C_BAD .. "none up|r" end
    return l.price and ns.money(l.price) or C_MUTE .. "bids only|r"
  end
  local m = missOf(r)
  if m then return C_MUTE .. (m.why == "noanswer" and "no answer yet|r" or "couldn't tell|r") end
  if Q.vendor and Q.deals then return C_MUTE .. "click to check|r" end   -- below vendor isn't checked row by row
  if Q.away then return C_MUTE .. "-|r" end   -- live prices only at the auction house
  return C_MUTE .. "checking...|r"
end
-- Last scan: the cheapest at the last full scan, always grey because it can be out of date
local function scanCell(r)
  return r.price and (GREY .. ns.money(r.price) .. "|r") or C_MUTE .. "bids only|r"
end
-- Profit after buying and vendoring: green once the live price is checked, grey from the scan, and "none now" when
-- the live price is no longer under the vendor price.
local function profitCell(col)
  return function(r)
    local p = get(r, col)
    if not p then return "" end
    if p <= 0 then return C_MUTE .. (liveOf(r) and "none now|r" or "none at scan|r") end
    return (liveOf(r) and C_GOOD or GREY) .. "+" .. ns.money(p) .. "|r"
  end
end
-- Up is wide enough for 6-digit counts ("123,456"), the money columns for 4-digit gold with silver and copper.
local COLS = {
  { "Up", "qty", -10, 52, upCell },
  { "Last scan", "scanprice", -68, 112, scanCell },
  { "Now", "price", -186, 112, lowestCell },
  { "Req lvl", "reqlevel", -304, 50, function(r)
    local v = r[Q.extra or "reqlevel"] or 0
    return v > 0 and v or ""
  end },
  { "iLvl", "ilvl", -360, 30, function(r) return r.ilvl or "" end },
}
-- A below-vendor search shows the profit instead of the typical price and the levels.
local function dealsCell(r)
  if r.dealN == nil then return upCell(r) end
  return ns.num(r.dealN)
end
local function dealProfitCell(r)
  if r.dealN == nil then return profitCell("stackprofit")(r) end
  return r.dealProfit and (C_GOOD .. "+" .. ns.money(r.dealProfit) .. "|r") or ""
end
local VCOLS = {
  { "Deals", "deals", -10, 52, dealsCell },
  { "Total", "dealprofit", -68, 112, dealProfitCell },
  { "Profit each", "profit", -186, 104, profitCell("profit") },
  { "Now", "price", -296, 112, lowestCell },
}
local BAR_SHIFT = 16        -- room for the scroll bar on the right: every column moves left by this much
local NAME_RIGHT = -396 - BAR_SHIFT   -- the item name stops here
local VNAME_RIGHT = -414 - BAR_SHIFT  -- ... and here in a below-vendor search

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
      b.name:SetPoint("RIGHT", f, "RIGHT", -12 - BAR_SHIFT, 0)
      local tail = r.err or (ns.num(r.count) .. " found" .. (r.sum and r.count > 1 and (", one of each " .. ns.money(r.sum)) or ""))
      if r.want then tail = "buy " .. ns.num(r.want) .. "   " .. tail end
      b.name:SetText(C_PLACE .. r.name .. "|r   " .. C_MUTE .. tail .. "|r")
      for c in ipairs(COLS) do b.cells[c]:SetText("") end
      for c in ipairs(VCOLS) do b.vcells[c]:SetText("") end
      b.flag:EdbSet(nil)
      b.flag:Hide()
      b:Show()
    elseif r then
      b.icon:SetTexture(r.icon)
      local color = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[(ENUMS.quality[r.quality] or 2) - 1]
      local l = liveOf(r)
      b.name:SetText((l and l.gone and GREY or color and color.hex or "|cffffffff") .. r.name .. "|r")
      local cols, cells, other = COLS, b.cells, b.vcells
      if Q.vendor then cols, cells, other = VCOLS, b.vcells, b.cells end
      for c, col in ipairs(cols) do cells[c]:SetText(col[5](r)) end
      for c in ipairs(other) do other[c]:SetText("") end
      -- outside a below-vendor search, a small green tag marks results cheaper than a vendor pays
      local p = not Q.vendor and get(r, "profit")
      if p and p > 0 then
        b.flag:EdbSet("Below vendor", T.good)
        b.flag:Show()
        b.name:SetPoint("RIGHT", b.flag, "LEFT", -6, 0)
      else
        b.flag:Hide()
        b.name:SetPoint("RIGHT", f, "RIGHT", Q.vendor and VNAME_RIGHT or NAME_RIGHT, 0)
      end
      b:Show()
    else
      b:Hide()
    end
  end
  for _, h in ipairs(Q.headers) do
    if h.mode then h:SetShown(h.mode == (Q.vendor and "vendor" or "normal")) end
    if h.mode == "normal" and (h.col == "reqlevel" or h.col == "slots" or h.col == "skill" or h.col == "droprate") then
      h.col = Q.extra or "reqlevel"
      h.label = Q.extra == "slots" and "Slots" or Q.extra == "skill" and "Skill" or Q.extra == "droprate" and "Drop %" or "Req lvl"
    end
    local mark = ""
    if Q.sortCol == h.col then mark = Q.sortDesc and " v" or " ^" end
    h.text:SetText(h.label .. mark)
    h.text:SetTextColor(unpack(Q.sortCol == h.col and PLACE or T.mute))
  end
  if f.bar then f.bar:Update() end
  f.more:SetText(#Q.results > n
    and ("%d-%d of %d, scroll for more"):format(Q.offset + 1, math.min(Q.offset + n, #Q.results), #Q.results) or "")
end

local function hideResults()
  if Q.frame then Q.frame:Hide() end
  if ns.ahq then ns.ahq.cancel("live") end
  live.busy = nil
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

-- Blizzard's search box, Filter, favourites star and Search button: dimmed and switched off while Advanced search is
-- open, so it's plain which search is active; put back exactly as they were when it closes.
local saved = {}
function blizzardSearch(on)
  local bar = _G.AuctionHouseFrame and AuctionHouseFrame.SearchBar
  if not bar then return end
  for _, k in ipairs({ "SearchBox", "FilterButton", "SearchButton", "FavoritesSearchButton" }) do
    local w = bar[k]
    if w then
      if not on then
        if not saved[k] then
          saved[k] = { alpha = w:GetAlpha(), enabled = not w.IsEnabled or w:IsEnabled() }
        end
        if w.ClearFocus then w:ClearFocus() end
        w:SetAlpha(0.3)
        if w.Disable then w:Disable() elseif w.SetEnabled then w:SetEnabled(false) end
        if w.EnableMouse then w:EnableMouse(false) end
      elseif saved[k] then
        w:SetAlpha(saved[k].alpha)
        if w.EnableMouse then w:EnableMouse(true) end
        if w.UpdateState then
          w:UpdateState()   -- the favourites star: on only when there are favourites now, as Blizzard sets it
        elseif saved[k].enabled then
          if w.Enable then w:Enable() elseif w.SetEnabled then w:SetEnabled(true) end
        end
        saved[k] = nil
      end
    end
  end
end

-- The Advanced search button shows whether Advanced search is open, and closes it again.
function modeButton()
  local b = Q.button
  if not b then return end
  local open = Q.frame and Q.frame:IsShown()
  b:SetText(open and "Close advanced search" or "Advanced search")
  b:EdbActive(open)
end

-- The line at the panel's top left: where you are.
function ns.searchCrumb(item)
  if not Q.frame then return end
  Q.frame.crumb:SetText(C_PLACE .. "Advanced search|r" .. (item and (C_MUTE .. "  >  |r" .. item) or ""))
end

-- The Below vendor button: Start buying on a below-vendor list, else Below vendor.
local function vendorButton()
  local b = Q.frame and Q.frame.vendor
  if not b then return end
  local buying = Q.vendor and Q.deals and #Q.results > 0
  b:SetText(buying and "Start buying" or "Below vendor")
  b:EdbActive(buying and true or false)
end
ns.vendorButton = vendorButton

local function setStatus(text, isError)
  if not Q.frame then return end
  Q.headBase = not isError and text or nil
  Q.frame.head:SetText(isError and (C_BAD .. text .. "|r") or text)
end

---------------------------------------------------------------------------------------------------------------------
-- Query guide

local EXAMPLES = {
  { "belowvendor", "Cheaper than a vendor pays: buy and vendor" },
  { "slot is trinket sort by price", "Every trinket, cheapest first" },
  { "slot is back and agi ge 5 sort by price", "Cloaks with 5+ agility" },
  { "name like \"*of the eagle\" and reqlevel le 40", "Every \"of the Eagle\" item you can wear by 40" },
  { "type has wand and reqlevel le 29 sort by dps desc", "Best wands up to level 29" },
  { "stats has spirit and slot in (head, chest, robe) top 20 by spi", "Top 20 spirit helmets and chests" },
  { "quality ge rare and price lt 10g sort by ilvl desc", "Blue or better under 10 gold" },
  { "type is cloth and int ge 8 and reqlevel le 35 sort by price", "Cloth with 8+ intellect up to 35" },
  { "fire_res ge 5 sort by fire_res desc, price", "Fire resistance gear" },
  { 'has "fire damage" and slot is trinket', "Trinkets that mention fire damage anywhere on the tooltip" },
  { 'slot is feet and effect has "speed"', "Boots with a speed effect" },
  { 'effect has "chance on hit" and category is Weapon top 10 by dps', "Weapons with a proc" },
}

local GUIDE = table.concat({
  C_PLACE .. "How it works|r",
  "Searches everything in the last full scan of this auction house (it rescans every 15 minutes while it is open), then asks the auction house about each result. " .. C_INFO .. "Now|r is that live price (from the last 5 minutes); " .. C_INFO .. "Last scan|r is the price at the full scan, grey because it can be out of date. " .. C_INFO .. "none up|r means nobody is selling it now; " .. C_INFO .. "no answer yet|r means the auction house didn't answer, and it is asked again in a minute. Click a result to see its auctions and buy it.",
  "",
  C_PLACE .. "Conditions|r   join them with " .. C_INFO .. "and|r, " .. C_INFO .. "or|r, " .. C_INFO .. "not|r and ( )",
  C_INFO .. "is|r, " .. C_INFO .. "is not|r   " .. C_INFO .. "gt|r, " .. C_INFO .. "ge|r (at least), " .. C_INFO .. "lt|r, " .. C_INFO .. "le|r (at most)   " .. C_INFO .. "has|r (contains)",
  C_INFO .. "like|r \"*of the bear\"  (* = anything)   " .. C_INFO .. "between|r (20 .. 30)   " .. C_INFO .. "in|r (head, chest)",
  "A word on its own searches names:  " .. C_GOOD .. "wand|r   " .. C_INFO .. "has|r on its own searches the whole tooltip:  " .. C_GOOD .. "has \"fire damage\"|r",
  "",
  C_PLACE .. "Steps|r   at the end:  " .. C_GOOD .. "type has wand and reqlevel le 29 sort by price|r",
  C_INFO .. "sort by|r price   " .. C_INFO .. "sort by|r ilvl desc, price   " .. C_INFO .. "sort desc|r (no column: by price)   " .. C_INFO .. "top|r 10 " .. C_INFO .. "by|r sta   " .. C_INFO .. "count|r",
  "Every search is over items, so there is nothing to put in front. reqlevel is also lvl, lvlreq or reqlvl.",
  "Or click a column header to sort; click again to flip it.",
  "",
  C_PLACE .. "Columns|r",
  "name, quality (poor, common, uncommon, rare, epic, legendary), ilvl, reqlevel, category, type (Cloth, Wand, Potion...)",
  "slot: head, neck, shoulder, back, chest, robe, shirt, tabard, wrist, hands, waist, legs, feet, finger, trinket, onehand, twohand, mainhand, offhand, holdable, shield, ranged, wand, thrown, relic, ammo, quiver, bag",
  "price (the cheapest buyout for one), median (the usual price: half the auctions cheaper, half dearer), qty (how many are up), auctions, sell (what a vendor pays), stack (how many fit in a stack)",
  "slots (bag size), profession, skill, droprate (best drop %)",
  C_INFO .. "source|r (or " .. C_INFO .. "from|r): every way you get it: vendor, crafted, drop, quest, skinning, pickpocket, fishing, herbalism, mining, object, world drop, container, disenchant. " .. C_GOOD .. "source is vendor|r finds every item vendors sell, also ones you can get other ways too:  " .. C_GOOD .. "source is vendor and profession is tailoring|r   " .. C_GOOD .. "source has \"world drop\"|r",
  "Money: 5g, 50s, 1g50s, 1g 50s, 2.5g, 20c. Or another column: " .. C_GOOD .. "price lt vendor|r",
  "Quality also takes colours (grey, white, green, blue, purple, orange); slot takes cloak, ring, helm, gloves, boots, belt, 1h, 2h.",
  "",
  C_PLACE .. "Below vendor price|r",
  C_GOOD .. "belowvendor|r lists every auction in the last full scan that is cheaper than a vendor pays and makes at least 10s, biggest total first. Buy them and sell them to any vendor: vendors take no cut. Quest items and items vendors don't buy never count. " .. C_INFO .. "deals|r is how many such auctions, " .. C_INFO .. "dealprofit|r what they make together. Start buying opens them one after another.",
  C_INFO .. "profit|r (vendor price minus the lowest buyout, each) and " .. C_INFO .. "stackprofit|r (for a full stack):  " .. C_GOOD .. "belowvendor and profit ge 10s|r",
  "Elsewhere, a green " .. C_GOOD .. "Below vendor|r tag marks such results.",
  "",
  C_PLACE .. "Stats|r",
  "str, agi, sta, int, spi, armor, ap, sp, healing, mp5, defense, dps, hit, crit, block",
  "fire_res, frost_res, nature_res, shadow_res, arcane_res, and " .. C_INFO .. "stats|r (every stat as text: stats has spirit)",
  "",
  C_PLACE .. "What an item does, and anything on its tooltip|r",
  C_INFO .. "effect|r holds every " .. C_INFO .. "Equip:|r, " .. C_INFO .. "Use:|r and " .. C_INFO .. "Chance on hit:|r line, as the tooltip shows it, several joined with /. A recipe says what it teaches:  " .. C_GOOD .. "effect has \"run speed\"|r",
  C_INFO .. "text|r holds everything on the tooltip: name, stats, binds, effect lines, the set and its bonuses, the flavour text. " .. C_INFO .. "has|r without a column searches it:  " .. C_GOOD .. "has \"fire damage\" and slot is trinket|r  means  " .. C_GOOD .. "text has \"fire damage\" and slot is trinket|r",
  "A quoted word on its own still searches names. Effects are worded as the game words them: movement is run speed, movement speed or mount speed; attack speed and casting speed are something else.",
  "",
  C_PLACE .. "Examples|r   click one to run it",
}, "\n")

local function makeGuide(f)
  local g = UI.own(CreateFrame("Frame", nil, f))
  g:SetPoint("TOPLEFT", 1, -(ROW_TOP - 22))   -- under the query box and buttons
  g:SetPoint("BOTTOMRIGHT", -1, 1)
  g:SetFrameLevel(f:GetFrameLevel() + 20)
  UI.panel(g, T.bg, T.bg)
  g:EnableMouse(true)
  g:Hide()

  -- scrolls with the mouse wheel or the scroll bar on the right (drag it, or click above or below the thumb)
  local content = CreateFrame("Frame")
  content:SetSize(10, 10)
  local scroll = UI.scrollFrame(g, content)
  scroll:SetPoint("TOPLEFT", 14, -10)
  scroll:SetPoint("BOTTOMRIGHT", -(UI.BAR_W + 12), 10)
  scroll:HookScript("OnSizeChanged", function(_, w) content:SetWidth(w) end)

  local text = UI.text(content, "small")
  text:SetPoint("TOPLEFT", 0, 0)
  text:SetPoint("RIGHT", content, "RIGHT", 0, 0)
  text:SetWordWrap(true)
  text:SetSpacing(4)
  text:SetText(GUIDE)

  -- each example on two lines, the query over what it finds: on one line a long query ran into its description
  local EX_H = 34
  local prev
  for _, ex in ipairs(EXAMPLES) do
    local b = UI.row(content, EX_H)
    b:SetPoint("LEFT", content, "LEFT", 0, 0)
    b:SetPoint("RIGHT", content, "RIGHT", 0, 0)
    if prev then b:SetPoint("TOP", prev, "BOTTOM", 0, 0) else b:SetPoint("TOP", text, "BOTTOM", 0, -8) end
    local q = UI.text(b, "small")
    q:SetPoint("TOPLEFT", 6, -4)
    q:SetPoint("RIGHT", -6, 0)
    q:SetText(C_GOOD .. ex[1] .. "|r")
    local d = UI.text(b, "dim")
    d:SetPoint("TOPLEFT", q, "BOTTOMLEFT", 0, -3)
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
    content:SetHeight(text:GetStringHeight() + 12 + #EXAMPLES * EX_H)
    scroll:SetVerticalScroll(0)
    C_Timer.After(0, scroll.Update)
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
    Q.sortDesc = not (self.col == "name" or self.col == "price" or self.col == "scanprice" or self.col == "median")
  end
  sortRows(Q.results, { { col = Q.sortCol, desc = Q.sortDesc } })
  Q.offset = 0
  render()
end

local function makeHeader(f, label, col, right, width, mode)
  local h = UI.own(CreateFrame("Button", nil, f))
  h:SetSize(width, 20)
  if right then
    h:SetPoint("TOPRIGHT", f, "TOPRIGHT", right - BAR_SHIFT, -(ROW_TOP - 21))
  else
    h:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -(ROW_TOP - 21))
  end
  h.text = UI.text(h, "head")
  h.text:SetPoint(right and "RIGHT" or "LEFT", 0, 0)
  h.label, h.col, h.mode = label, col, mode
  h:SetScript("OnClick", headerClick)
  local tips = {
    price = "The cheapest buyout for one, checked with the auction house in the last 5 minutes: what you'd pay now. Says checking... until the check is in, none up when nobody is selling it, and no answer yet when the auction house didn't answer (asked again in a minute).",
    scanprice = "The cheapest buyout for one at the last full scan (its age is in the line above). Can be out of date: Now is the real price.",
    qty = "How many are up for sale: white when checked live in the last 5 minutes, grey from the last full scan.",
    reqlevel = "The level you need to use it.",
    slots = "How many bag slots it has.",
    skill = "The profession skill needed to make it.",
    droprate = "Its best drop chance, in percent.",
    ilvl = "Item level: how strong the item is.",
    profit = "What one makes: what a vendor pays minus the cheapest buyout.",
    dealprofit = "What buying every auction under vendor price and selling it to a vendor makes.",
    deals = "How many auctions are under vendor price.",
  }
  h:SetScript("OnEnter", function(self)
    self.text:SetTextColor(unpack(T.text))
    if tips[self.col] then
      GameTooltip:SetOwner(self, "ANCHOR_TOP")
      GameTooltip:AddLine(self.label, 1, 1, 1)
      GameTooltip:AddLine(tips[self.col], nil, nil, nil, true)
      GameTooltip:AddLine("Click to sort.", 0.6, 0.6, 0.6)
      GameTooltip:Show()
    end
  end)
  h:SetScript("OnLeave", function(self)
    self.text:SetTextColor(unpack(Q.sortCol == self.col and PLACE or T.mute))
    GameTooltip:Hide()
  end)
  Q.headers[#Q.headers + 1] = h
end

local function makeRow(f, k)
  local b = UI.row(f, ROW_H)
  b:SetPoint("TOPLEFT", 1, -ROW_TOP - (k - 1) * ROW_H)
  b:SetPoint("RIGHT", -(BAR_SHIFT + 1), 0)
  b.icon = b:CreateTexture(nil, "ARTWORK")
  b.icon:SetSize(18, 18)
  b.icon:SetPoint("LEFT", 12, 0)
  b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  local function cells(cols)
    local out = {}
    for c, col in ipairs(cols) do
      local fs = UI.text(b, "body")
      fs:SetPoint("RIGHT", f, "RIGHT", col[3] - BAR_SHIFT, 0)
      fs:SetPoint("TOP", b, "TOP", 0, 0)
      fs:SetPoint("BOTTOM", b, "BOTTOM", 0, 0)
      fs:SetWidth(col[4])
      fs:SetJustifyH("RIGHT")
      out[c] = fs
    end
    return out
  end
  b.cells, b.vcells = cells(COLS), cells(VCOLS)
  b.flag = UI.badge(b, 84, 16)
  b.flag:SetPoint("RIGHT", b, "RIGHT", NAME_RIGHT + BAR_SHIFT + 1, 0)   -- on its own row, left of the price columns
  b.flag:Hide()
  b.name = UI.text(b, "body")
  b.name:SetPoint("LEFT", b.icon, "RIGHT", 8, 0)
  b.name:SetPoint("RIGHT", f, "RIGHT", NAME_RIGHT, 0)
  b:SetScript("OnEnter", function(self)
    if not self.row or self.row.header then return end
    ns.itemTipOwner(self)   -- next to the mouse; "Equipped" only with Shift (ItemTip.lua)
    local link = "item:" .. self.row.id .. (self.row.suffix ~= 0 and ("::::::::::::1:" .. self.row.suffix) or "")
    pcall(GameTooltip.SetHyperlink, GameTooltip, link)
    local r = self.row
    local p = get(r, "profit")
    if p and p > 0 then
      local stack = math.max(1, r.stack or 1)
      GameTooltip:AddLine(("Below vendor price: a vendor pays %s each. Buy and vendor it for %s each%s."):format(
        ns.money(r.sell), ns.money(p), stack > 1 and (", %s for a stack of %d"):format(ns.money(p * stack), stack) or ""),
        T.good[1], T.good[2], T.good[3], true)
    end
    if r.median then
      GameTooltip:AddLine("Usual price at the last scan: " .. ns.money(r.median) .. " (half the auctions cheaper, half dearer)", 0.7, 0.7, 0.7, true)
    end
    GameTooltip:AddLine("Click to see its live auctions and buy.", T.info[1], T.info[2], T.info[3], true)
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)
  b:SetScript("OnClick", function(self)
    if not self.row or self.row.header then return end
    if Q.away then return end   -- buying needs the auction house; the tooltip has the prices
    if ns.openBuy and ns.openBuy(self.row) then return end
    -- Blizzard's own search for the name shows its live auctions; buy from there as usual
    local c = itemInfo(self.row.id)
    if ns.ahq then ns.ahq.showInBlizzard(c and c[1] or self.row.name) end
  end)
  return b
end

-- Advanced search sits over the auction list while the auction house is open, and in a window of its own anywhere
-- else (/eah prices): the same search over the last saved scan; buying and live prices need the auction house.
local function away() return not (_G.AuctionHouseFrame and AuctionHouseFrame:IsShown()) end

local function makeHost()
  if Q.host then return Q.host end
  local EUI = LibStub and LibStub("EverlookUI-1", true)
  local h = UI.own(CreateFrame("Frame", "EverlookAuctionsPrices", UIParent))
  h:SetSize(860, 500)
  local d = ns.db and ns.db()
  local pos = d and d.pricesPos
  if pos then h:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4]) else h:SetPoint("CENTER", 0, 40) end
  h:SetFrameStrata("HIGH")
  h:SetToplevel(true)
  h:SetClampedToScreen(true)
  h:EnableMouse(true)
  h:SetMovable(true)
  -- the title bar on top (and any edge outside the list) moves the window; it stays where you leave it
  h:RegisterForDrag("LeftButton")
  h:SetScript("OnDragStart", h.StartMoving)
  h:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local p1, _, p2, x, y = self:GetPoint()
    local db = ns.db and ns.db()
    if db then db.pricesPos = { p1, p2, x, y } end
  end)
  local theme = EUI and EUI.MakeTheme and EUI.MakeTheme(T.accent)
  if EUI and EUI.WindowChrome and theme then
    h.eluiTheme = theme
    EUI.WindowChrome(h, theme)
    if EUI.CloseButton then EUI.CloseButton(h, theme) end
  else
    UI.panel(h, T.bg, T.edge)
  end
  h.icon = h:CreateTexture(nil, "ARTWORK")
  h.icon:SetSize(16, 16)
  h.icon:SetPoint("TOPLEFT", 18, -16)
  if EUI and EUI.SetIcon and EUI.SetIcon(h.icon, "search") then h.icon:SetVertexColor(T.accent[1], T.accent[2], T.accent[3]) end
  h.title = UI.text(h, "text")
  h.title:SetPoint("LEFT", h.icon, "RIGHT", 8, 0)
  h.title:SetText("Prices")
  h.hint = UI.text(h, "dim")
  h.hint:SetPoint("LEFT", h.title, "RIGHT", 10, 0)
  h.hint:SetText("drag this bar to move the window")
  h.area = CreateFrame("Frame", nil, h)
  h.area:SetPoint("TOPLEFT", 10, -42)
  h.area:SetPoint("BOTTOMRIGHT", -10, 12)
  h:SetScript("OnHide", function() if Q.frame and Q.away then Q.frame:Hide() end end)
  tinsert(UISpecialFrames, "EverlookAuctionsPrices")
  h:Hide()
  Q.host = h
  return h
end

-- Away from the auction house with nothing searched yet: start with one of these, so the list isn't empty.
local STARTERS = {
  "auctions ge 10 sort by auctions desc top 100",
  "quality ge rare sort by price desc top 100",
  "source is crafted sort by auctions desc top 100",
  "price lt vendor sort by profit desc top 100",
  "type has recipe sort by price top 100",
}
ns.priceStarters = STARTERS   -- for the offline tests

-- as many rows as the place it sits in has room for
local function fitRows(f)
  if not Q.allRows then return end
  local n = rowsFit(f)
  for k = #Q.allRows + 1, n do Q.allRows[k] = Q.makeRow(f, k) end
  Q.rows = {}
  for k, b in ipairs(Q.allRows) do
    if k <= n then Q.rows[k] = b else b:Hide() end
  end
end

local function placeIn(area)
  local f = Q.frame
  f:SetParent(area)
  f:ClearAllPoints()
  f:SetAllPoints(area)
  f:SetFrameLevel(area:GetFrameLevel() + 200)
  fitRows(f)
end

local function makeResults()
  local ah = _G.AuctionHouseFrame
  local area = ah and ah.BrowseResultsFrame
  if Q.frame then return Q.frame end
  if not area then area = makeHost().area end
  local f = UI.own(CreateFrame("Frame", "EverlookAuctionsQueryResults", area))
  f:SetAllPoints(area)
  f:SetFrameLevel(area:GetFrameLevel() + 200)
  UI.place(f, "search")
  UI.panel(f, T.bg, T.edge)   -- the blue edge: you are in Advanced search
  UI.placeEdge(f, PLACE)
  f:EnableMouse(true)
  f:SetScript("OnShow", function() if not Q.away then blizzardList(false); blizzardSearch(false) end; modeButton() end)
  f:SetScript("OnHide", function() blizzardList(true); blizzardSearch(true); modeButton(); if Q.away and Q.host then Q.host:Hide() end end)
  f:Hide()   -- frames start shown; hiding first makes the first Show run OnShow too

  -- where you are: "Advanced search", and "Advanced search > item" while buying (Buy.lua sets it)
  f.crumb = UI.text(f, "title")
  f.crumb:SetPoint("TOPLEFT", 12, -8)
  f.crumb:SetPoint("RIGHT", -12, 0)
  f.crumb:SetJustifyH("LEFT")
  f.crumb:SetWordWrap(false)
  f.crumb:SetText(C_PLACE .. "Advanced search|r")

  -- the query box across the whole top, two lines tall; under it the status line, with the buttons on the right
  local search   -- Enter and the Search button
  local box = UI.input(f, 100, 40, { hint = "type has wand and reqlevel le 29 sort by price", max = 400, lines = 2,
    onEnter = function() search() end })
  box.edbWell:SetPoint("TOPLEFT", 8, -26)
  box.edbWell:SetPoint("TOPRIGHT", -8, -26)
  f.box = box

  local close = UI.button(f, "Close", 54, 24)
  close:SetPoint("TOPRIGHT", -8, -72)
  close:SetScript("OnClick", hideResults)

  local help = UI.button(f, "Guide", 54, 24)
  help:SetPoint("RIGHT", close, "LEFT", -6, 0)

  local go = UI.button(f, "Search", 68, 24, "primary")
  go:SetPoint("RIGHT", help, "LEFT", -6, 0)
  -- one gold button on screen: while the Buy panel (gold Buy) is open, Search is a plain button
  function ns.searchPrimary(on)
    go.edbRole = on and "primary" or nil
    if go.edbLabel then
      if on then go.edbLabel:SetShadowOffset(0, 0) else go.edbLabel:SetShadowOffset(1, -1) end
    end
    if go.EdbRefresh then go:EdbRefresh() end
  end
  if ns.buyOpen then ns.searchPrimary(false) end

  local save = UI.button(f, "Save", 48, 24)
  save:SetPoint("RIGHT", go, "LEFT", -6, 0)
  save:SetScript("OnClick", function()
    local typed = UI.oneLine(f.box:GetText()):gsub("||", "|")
    local q = typed:match("%S") and typed or Q.last
    if ns.saveToList and q and q:match("%S") then ns.saveToList(q) end
  end)
  UI.tip(save, "Save to a shopping list", "Adds this search to the shopping list picked in the Shopping tab.")

  local vendor = UI.button(f, "Below vendor", 104, 24)
  vendor:SetPoint("RIGHT", save, "LEFT", -6, 0)
  vendor:SetScript("OnClick", function()
    if Q.vendor and Q.deals and #Q.results > 0 then
      if ns.startDeals then ns.startDeals(Q.results) end
      return
    end
    belowVendor()
  end)
  UI.tip(vendor, function() return (Q.vendor and Q.deals and #Q.results > 0) and "Start buying" or "Below vendor price" end,
    function()
      if Q.vendor and Q.deals and #Q.results > 0 then
        return "Opens the top item with its cheapest auction under vendor price picked. Buy buys it, then the next one comes up. Every purchase is your own click."
      end
      return "Auctions cheaper than what a vendor pays for the item: buy them and sell them to any vendor. Biggest profit first, from the last full scan (a new one starts first when it is over 5 minutes old and the server allows one). The same as the search: belowvendor"
    end)
  f.vendor = vendor

  function search()
    box:ClearFocus()
    local text = UI.oneLine(box:GetText())
    if text:match("%S") then ns.query(text) end
  end
  go:SetScript("OnClick", search)

  -- the status line: up to two lines left of the buttons
  f.head = UI.text(f, "dim")
  f.head:SetPoint("TOPLEFT", 12, -69)
  f.head:SetPoint("BOTTOMRIGHT", vendor, "BOTTOMLEFT", -8, -3)
  f.head:SetJustifyH("LEFT")
  f.head:SetJustifyV("MIDDLE")
  f.head:SetWordWrap(true)
  if f.head.SetMaxLines then f.head:SetMaxLines(2) end
  f.head:SetText("Type a query and press Enter. Guide explains how.")
  -- two lines hold most of it; when a long error or note doesn't fit, pointing at it shows all of it
  local headHit = CreateFrame("Frame", nil, f)
  headHit:SetAllPoints(f.head)
  if headHit.SetMouseMotionEnabled then headHit:SetMouseMotionEnabled(true) else headHit:EnableMouse(true) end
  headHit:SetScript("OnEnter", function(self)
    if not (f.head.IsTruncated and f.head:IsTruncated()) then return end
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")
    GameTooltip:AddLine(f.head:GetText(), 1, 1, 1, true)
    GameTooltip:Show()
  end)
  headHit:SetScript("OnLeave", function() GameTooltip:Hide() end)

  local band = UI.headerBand(f, 22)
  band:SetPoint("TOPLEFT", 1, -(ROW_TOP - 22))
  band:SetPoint("TOPRIGHT", -1, -(ROW_TOP - 22))
  band:SetFrameLevel(f:GetFrameLevel() + 1)

  Q.headers = {}
  makeHeader(f, "Item", "name", nil, 120)
  for _, col in ipairs(COLS) do makeHeader(f, col[1], col[2], col[3], col[4], "normal") end
  for _, col in ipairs(VCOLS) do makeHeader(f, col[1], col[2], col[3], col[4], "vendor") end
  for _, h in ipairs(Q.headers) do h:SetFrameLevel(band:GetFrameLevel() + 1) end

  Q.rows, Q.allRows = {}, {}
  Q.makeRow = makeRow
  for k = 1, rowsFit(f) do Q.rows[k] = makeRow(f, k); Q.allRows[k] = Q.rows[k] end

  f.more = UI.text(f, "mute")
  f.more:SetPoint("BOTTOMRIGHT", -12, 8)

  -- the scroll bar beside the rows: drag it, or click above or below the thumb for the next page
  f.bar = UI.scrollbar(f, {
    get = function() return Q.offset end,
    max = function() return #Q.results - #Q.rows end,
    set = function(v)
      Q.offset = v
      render()
      liveStep()
    end,
    view = function() return #Q.results > 0 and #Q.rows / #Q.results or 1 end,
    page = function() return math.max(1, #Q.rows - 1) end,
    wheel = 3,
  })
  f.bar:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -ROW_TOP)
  f.bar:SetHeight(#Q.rows * ROW_H)

  f:EnableMouseWheel(true)
  f:SetScript("OnMouseWheel", function(_, delta) f.bar:Scroll(-delta * 3) end)

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
  local sc = newestScan(db, house)
  local rows = sc and sc.rows
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

local function liveHead()
  if not Q.frame or not Q.headBase then return end
  if Q.vendor and Q.deals then Q.frame.head:SetText(Q.headBase); return end
  local total, done, missed = 0, 0, 0
  for k = 1, math.min(#Q.results, LIVE_MAX) do
    local r = Q.results[k]
    if not r.header then
      total = total + 1
      if liveFresh(r) then done = done + 1
      elseif missOf(r) then done, missed = done + 1, missed + 1 end
    end
  end
  local tail
  if total == 0 or Q.away then tail = ""
  elseif done >= total and missed > 0 then
    tail = (" \194\183 " .. C_MUTE .. "live prices checked, %d without an answer (asked again in a minute)|r"):format(missed)
  elseif done >= total then tail = " \194\183 " .. C_GOOD .. "live prices checked|r"
  else tail = (" \194\183 " .. C_INFO .. "checking live prices %d/%d...|r"):format(done, total) end
  Q.frame.head:SetText(Q.headBase .. tail)
end

local function liveDone()
  live.busy = nil
  render()
  liveHead()
  C_Timer.After(0.1, liveStep)
end

-- One browse by the item's name (what Blizzard's Search button sends) gives the lowest price and how many are up
-- for every version of it at once. A row is only called sold out from a complete answer (AHQuery.lua).
-- A live price lasts LIVE_TTL and a missed one LIVE_RETRY; then the row is asked again while the panel is open, so
-- "Now" never goes back to "checking..." for good. IsVisible, not IsShown: the panel keeps its shown flag while the
-- auction house is closed, and nothing may be sent then.
local function liveLater()
  if live.timer then return end
  live.timer = true
  C_Timer.After(15, function() live.timer = nil; liveStep() end)
end

function liveStep()
  if ns.buyOpen then return end   -- the buy panel goes first
  if Q.away or away() then return end   -- live prices only at the auction house
  if Q.vendor and Q.deals then return end   -- below vendor: scan prices; the row you open is checked live
  if live.busy or not Q.frame or not Q.frame:IsVisible() or not ns.ahq then return end
  local t0 = time()
  local function pick(from, to)
    for k = from, to do
      local r = Q.results[k]
      if r and not r.header and not liveFresh(r) and not missOf(r)
          and not (live.tried[r.id] and t0 - live.tried[r.id] < LIVE_RETRY) then
        return r
      end
    end
  end
  local r = pick(Q.offset + 1, Q.offset + #Q.rows) or pick(1, math.min(#Q.results, LIVE_MAX))
  if not r then liveHead(); liveLater(); return end
  live.tried[r.id] = t0
  local id = r.id
  local c = itemInfo(id)
  live.busy = id
  ns.ahq.browse(c and c[1] or r.name, id, { owner = "live", background = true, confirmEmpty = true }, function(answer)
    if live.busy ~= id then return end
    local rows = {}
    for _, x in ipairs(Q.results) do if x.id == id and not x.header then rows[#rows + 1] = x end end
    local got = ns.ahq.liveFromBrowse(rows, answer, ns.ahq.nameOf)
    local t = time()
    for i, x in ipairs(rows) do
      local g = got[i]
      if g and g.gone then Q.live[x.key], Q.liveMiss[x.key] = { at = t, gone = true }, nil
      elseif g then Q.live[x.key], Q.liveMiss[x.key] = { price = g.price, qty = g.qty, at = t }, nil
      else Q.liveMiss[x.key] = { at = t, why = answer.ok and "unclear" or "noanswer" } end
    end
    liveDone()
  end)
end

-- Below vendor: the list from the last full scan, with a new scan first when that one is over 5 minutes old and the
-- server allows one (the list fills when it is done), else when the next one is possible.
local FRESH = 300
function belowVendor()
  local age = ns.scanAge and ns.scanAge()
  local wait = ns.scanWaitLeft and ns.scanWaitLeft()
  if (not age or age > FRESH) and wait == 0 and ns.startScan and not (ns.scanning and ns.scanning()) then
    ns.startScan()
    ns.query("belowvendor")
    if Q.frame then
      Q.headBase = nil
      Q.frame.head:SetText((Q.frame.head:GetText() or "") .. "  " .. C_INFO .. "Updating prices first; the list fills when done.|r")
    end
    return
  end
  ns.query("belowvendor")
  if Q.frame and ns.scanning and ns.scanning() then
    Q.frame.head:SetText((Q.frame.head:GetText() or "") .. "  " .. C_INFO .. "Prices are updating; the list fills when it's done.|r")
  elseif Q.frame and age and age > FRESH and wait and wait > 0 then
    Q.frame.head:SetText((Q.frame.head:GetText() or "") .. "  " .. C_DIM .. ("next price update possible in %d:%02d|r"):format(math.floor(wait / 60), wait % 60))
  end
end

local rerunToken = 0
local function show(text)
  local results, head, missing, vendor = run(text)
  local ordered = results and Q.ordered
  Q.vendor = vendor or false
  if not results then
    Q.results = {}
    setStatus(head, true)
  else
    Q.results = results
    if vendor and Q.deals then
      head = head .. "  " .. C_DIM .. "prices from that scan; open one for its live auctions|r"
    elseif vendor then
      head = head .. "  " .. C_DIM .. "profit = vendor price minus the lowest buyout|r"
    end
    -- (not a look for "sort" or "top" in the text: "name has topaz" has no sort of its own)
    if vendor and not ordered and not Q.sortCol then Q.sortCol, Q.sortDesc = Q.deals and "dealprofit" or "profit", true end
    -- a click-sort stays when the query has no sort of its own
    if Q.sortCol and not ordered then
      sortRows(Q.results, { { col = Q.sortCol, desc = Q.sortDesc } })
    end
    if (missing or 0) > 0 then
      setStatus(head .. ("  " .. C_DIM .. "learning %s more items (only the first time)...|r"):format(ns.num(missing)))
    else
      setStatus(head)
    end
  end
  render()
  vendorButton()
  liveHead()
  liveStep()
  if results then warmTips((dataset())) end   -- tooltips for text searches, read a few per frame
  -- while items are still loading, run the query again a few times as they arrive
  if results and (missing or 0) > 0 then
    rerunToken = rerunToken + 1
    local mine, tries = rerunToken, (Q.tries or 0) + 1
    Q.tries = tries
    if tries <= 200 then
      C_Timer.After(3, function()
        if mine == rerunToken and Q.frame and Q.frame:IsVisible() and Q.last == text then show(text) end
      end)
    end
  end
end

function ns.query(text)
  local f = makeResults()
  if not f then return end
  if ns.closeBuy then ns.closeBuy() end
  text = UI.oneLine(text)
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

-- A row whose deals are bought or gone leaves the list.
function ns.dropResult(row)
  for k, r in ipairs(Q.results) do
    if r == row then table.remove(Q.results, k); break end
  end
  if Q.frame then render(); vendorButton() end
end
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
    local plain = UI.oneLine(q):gsub("||", "|"):gsub("^%s*where%s+", "")
    local results, head = run(plain)
    -- what one of each costs at the lowest price (from the scan): a list of materials shows its total
    local sum, priced = 0, 0
    for _, r in ipairs(results or {}) do
      if r.price then sum, priced = sum + r.price, priced + 1 end
    end
    out[#out + 1] = { header = true, name = q, count = results and #results or 0, err = not results and head or nil,
      sum = priced > 0 and sum or nil, want = list.want and list.want[q] }
    for _, r in ipairs(results or {}) do out[#out + 1] = r end
    total = total + (results and #results or 0)
  end
  live.tried = {}
  Q.results, Q.grouped, Q.groupList, Q.last, Q.offset, Q.sortCol, Q.vendor = out, list.name, list, nil, 0, nil, false
  setStatus(("%s: %d searches, %s results in the last full scan"):format(list.name, #(list.queries or {}), ns.num(total)))
  render()
  liveHead()
  liveStep()
end

-- A new full scan came in: search again with the fresh prices.
function ns.onScan()
  Q.cacheFor = nil
  warm()
  if Q.frame and Q.frame:IsVisible() and Q.last then
    Q.tries = 0
    show(Q.last)
  elseif Q.frame and Q.frame:IsVisible() and Q.grouped and Q.groupList then
    ns.queryList(Q.groupList)
  end
end

local function hook()
  local ah = _G.AuctionHouseFrame
  Q.hookAH()
  return f
end

-- Blizzard's searches hide our results (installed once the auction house exists)
function Q.hookAH()
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
  if away() then
    -- away from the auction house: the window of its own
    local f = makeResults()
    if not f then return end
    Q.away = true
    f.crumb:SetText(C_PLACE .. "Prices from the last scan|r" .. C_MUTE .. "   live prices and buying at the auction house|r")
    local h = makeHost()
    h:Show()
    placeIn(h.area)
    f:Show()
    render()
    if #Q.results == 0 and not (f.box:GetText() or ""):match("%S") then
      local q = STARTERS[math.random(#STARTERS)]
      f.box:SetText(q)
      ns.query(q)
    else
      f.box:SetFocus()
    end
    return
  end
  local f = makeResults()
  if not f then return end
  if Q.away then
    Q.away = nil
    if Q.host then Q.host:Hide() end
    placeIn(ah.BrowseResultsFrame)
    f.crumb:SetText(C_PLACE .. "Advanced search|r")
  end
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
  local b = UI.button(row, "Advanced search", 150, 22)
  UI.place(b, "search")   -- while open it shows in Advanced search's blue, like our tabs
  b:SetPoint("RIGHT", row, "LEFT", -8, 0)
  b:SetScript("OnClick", function()
    if Q.frame and Q.frame:IsShown() then hideResults() else ns.openSearch() end
  end)
  UI.tip(b, function() return Q.frame and Q.frame:IsShown() and "Close Advanced search" or "Advanced search" end,
    function()
      if Q.frame and Q.frame:IsShown() then return "Back to Blizzard's own search." end
      return "Search everything in the last price update with the same query language as EverlookDB.com: stats, slot, item and required level, price. For example: type has wand and reqlevel le 29 sort by price"
    end)
  Q.button = b
  modeButton()
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("AUCTION_HOUSE_SHOW")
ev:RegisterEvent("AUCTION_HOUSE_CLOSED")
ev:RegisterEvent("GET_ITEM_INFO_RECEIVED")
ev:SetScript("OnEvent", function(_, e, arg)
  if e == "GET_ITEM_INFO_RECEIVED" then
    if warming.ids and arg then itemInfo(arg) end
    return
  end
  if e == "AUCTION_HOUSE_CLOSED" then
    -- the queue drops every search without an answer when the auction house closes (AHQuery.lua): forget the one
    -- in flight, or the live check would wait for it forever after reopening
    live.busy = nil
    return
  end
  if e == "AUCTION_HOUSE_SHOW" and Q.away and Q.host then Q.host:Hide() end
  C_Timer.After(0.2, function()
    if Q.hookAH then Q.hookAH() end
    hook()
    makeButton()
    warm()
  end)
end)
