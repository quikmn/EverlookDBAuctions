-- EverlookDB Auctions: query search over the last full scan, in the same language as EverlookDB.com.
--   items | where slot is trinket and price lt 5g | sort by price
-- The Advanced search button on the EverlookDB panel opens it over the auction list: type a query, press Enter.
-- Click a result to find it on the auction house and buy as usual.
-- Columns: name, quality, ilvl, reqlevel, slot, category, type, sell, stack, price (lowest buyout), median, qty,
-- auctions, stats str, agi, sta, int, spi, armor, ap, sp, healing, mp5, defense, dps, hit, crit, spellhit,
-- spellcrit, block, fire_res (and holy, nature, frost, shadow, arcane), and `stats` (all stats as text).
-- Steps: where, sort by <col> [asc|desc], top <n> [by <col>], count.

local ADDON, ns = ...

local ROWS = 16
local ROW_H = 20

local Q = { results = {}, offset = 0 }

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
}
for k in pairs(STATS) do KIND[k] = "number" end
KIND.stats = "text"   -- every stat on the item as text, e.g. "Stamina 5, Agility 3": `stats has agility`
local ALIAS = {
  rarity = "quality", subtype = "type", subclass = "type", itemclass = "category", level = "reqlevel", lvl = "reqlevel",
  req = "reqlevel", reqlvl = "reqlevel", minlevel = "reqlevel", vendor = "sell", low = "price", lowest = "price",
  buyout = "price", med = "median", typical = "median", quantity = "qty", count = "qty", up = "auctions",
  strength = "str", agility = "agi", stamina = "sta", stam = "sta", intellect = "int", intel = "int", spirit = "spi",
  ac = "armor", armour = "armor", firres = "fire_res", fireres = "fire_res", frostres = "frost_res",
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
      local c = column(p:value()) or p:fail("sort by which column?")
      local desc = false
      if p:isWord("desc") then p:next(); desc = true elseif p:isWord("asc") then p:next() end
      steps[#steps + 1] = { k = "sort", col = c, desc = desc }
    elseif word == "top" or word == "take" or word == "limit" then
      local n = tonumber(p:value()) or p:fail(word .. " needs a number")
      local step = { k = "top", n = n }
      if p:isWord("by") then
        p:next()
        step.col = column(p:value()) or p:fail("top by which column?")
        step.desc = true
        if p:isWord("asc") then p:next(); step.desc = false elseif p:isWord("desc") then p:next() end
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

local statsCache = {}

local function statsOf(row)
  local key = row.key
  local s = statsCache[key]
  if s then return s end
  local link = "item:" .. row.id .. (row.suffix ~= 0 and ("::::::::::::1:" .. row.suffix) or "")
  local okStats, t = pcall(C_Item.GetItemStats or GetItemStats, link)
  s = {}
  local names = {}
  if okStats and type(t) == "table" then
    for short, mod in pairs(STATS) do s[short] = t[mod] or 0 end
    for mod, n in pairs(t) do names[#names + 1] = (_G[mod] or mod) .. " " .. n end
  end
  table.sort(names)
  s.stats = table.concat(names, ", ")
  statsCache[key] = s
  return s
end

local function get(row, col)
  if STATS[col] then return statsOf(row)[col] or 0 end
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
    local name, _, quality, ilvl, req, category, kind, stack, equip, icon, sell = C_Item.GetItemInfo(id)
    if not name then
      missing = missing + 1
      if C_Item.RequestLoadItemDataByID then pcall(C_Item.RequestLoadItemDataByID, id) end
    else
      rows[#rows + 1] = {
        key = key, id = id, suffix = suffix, icon = icon,
        name = (suffix ~= 0 and f[13] and f[13] ~= "") and f[13] or name,
        quality = QUALITY[(quality or 1) + 1], ilvl = ilvl, reqlevel = req, category = category, type = kind,
        slot = EQUIP[equip or ""] or "none", stack = stack, sell = sell,
        price = tonumber(f[1]), median = tonumber(f[3]), qty = tonumber(f[4]), auctions = tonumber(f[5]),
      }
    end
  end
  -- only keep the result when every item was loaded, so the next search sees the rest
  if missing == 0 then Q.cacheFor, Q.cache, Q.missing = scanned, rows, 0 end
  return rows, scanned, missing
end

local function run(text)
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
    elseif st.k == "sort" or (st.k == "top" and st.col) then
      local c, desc = st.col, st.desc
      table.sort(out, function(a, b)
        local x, y = get(a, c), get(b, c)
        if KIND[c] == "enum" then x, y = ENUMS[c][tostring(x)], ENUMS[c][tostring(y)] end
        if x == nil then return false end
        if y == nil then return true end
        if x == y then return a.name < b.name end
        if type(x) ~= type(y) then x, y = tostring(x), tostring(y) end
        if desc then return x > y end
        return x < y
      end)
      if st.k == "top" then
        local kept = {}
        for k = 1, math.min(st.n, #out) do kept[k] = out[k] end
        out = kept
      end
    elseif st.k == "top" then
      local kept = {}
      for k = 1, math.min(st.n, #out) do kept[k] = out[k] end
      out = kept
    elseif st.k == "count" then
      counted = #out
    end
  end
  local head = counted and ("%s matching item versions"):format(ns.num(counted))
    or ("%s results"):format(ns.num(#out))
  head = head .. (" from the full scan %s"):format(ns.ago(scanned.at))
  if missing > 0 then head = head .. (" (%s items still loading; search again)"):format(ns.num(missing)) end
  return counted and {} or out, head
end

---------------------------------------------------------------------------------------------------------------------
-- Results over the browse list

local function render()
  local f = Q.frame
  local maxOffset = math.max(0, #Q.results - ROWS)
  if Q.offset > maxOffset then Q.offset = maxOffset end
  for k = 1, ROWS do
    local b, r = Q.rows[k], Q.results[Q.offset + k]
    b.row = r
    if r then
      b.icon:SetTexture(r.icon)
      local color = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[(ENUMS.quality[r.quality] or 2) - 1]
      b.name:SetText((color and color.hex or "|cffffffff") .. r.name .. "|r")
      b.lvl:SetText(r.ilvl or "")
      b.price:SetText(r.price and ns.money(r.price) or "|cff808080bids only|r")
      b.qty:SetText(ns.num(r.qty or 0))
      b:Show()
    else
      b:Hide()
    end
  end
  f.more:SetText(#Q.results > ROWS
    and ("%d-%d of %d (scroll)"):format(Q.offset + 1, math.min(Q.offset + ROWS, #Q.results), #Q.results) or "")
end

local function hideResults()
  if Q.frame then Q.frame:Hide() end
end

local function makeResults()
  local ah = _G.AuctionHouseFrame
  local area = ah and ah.BrowseResultsFrame
  if Q.frame or not area then return Q.frame end
  local f = CreateFrame("Frame", "EverlookAuctionsQueryResults", area, "BackdropTemplate")
  f:SetAllPoints(area)
  f:SetFrameLevel(area:GetFrameLevel() + 20)
  f:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 14, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
  f:SetBackdropColor(0.04, 0.04, 0.05, 0.97)
  f:SetBackdropBorderColor(0.6, 0.5, 0.2, 1)
  f:EnableMouse(true)

  local close = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  close:SetSize(56, 22)
  close:SetPoint("TOPRIGHT", -8, -8)
  close:SetText("Close")
  close:SetScript("OnClick", hideResults)

  local go = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  go:SetSize(70, 22)
  go:SetPoint("RIGHT", close, "LEFT", -4, 0)
  go:SetText("Search")

  local box = CreateFrame("EditBox", "EverlookAuctionsQueryBox", f, "InputBoxTemplate")
  box:SetHeight(22)
  box:SetPoint("TOPLEFT", 16, -8)
  box:SetPoint("RIGHT", go, "LEFT", -8, 0)
  box:SetAutoFocus(false)
  box:SetMaxLetters(400)
  box:SetFontObject("ChatFontNormal")
  local function search()
    local text = box:GetText()
    box:ClearFocus()
    if text:match("%S") then ns.query(text) end
  end
  box:SetScript("OnEnterPressed", search)
  box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  go:SetScript("OnClick", search)
  f.box = box

  local hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  hint:SetPoint("TOPLEFT", 12, -34)
  hint:SetPoint("RIGHT", -10, 0)
  hint:SetJustifyH("LEFT")
  hint:SetText("Same language as EverlookDB.com, e.g.  slot is trinket and price lt 5g | sort by price"
    .. "   or   items | where sta ge 10 and reqlevel le 40 | top 20 by sta")

  f.head = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  f.head:SetPoint("TOPLEFT", 12, -50)
  f.head:SetPoint("RIGHT", -10, 0)
  f.head:SetJustifyH("LEFT")
  f.head:SetText("Type a query and press Enter.")

  local cols = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  cols:SetPoint("TOPLEFT", 10, -68)
  cols:SetText("Item")
  local function colHead(text, x)
    local c = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    c:SetPoint("TOPRIGHT", f, "TOPRIGHT", x, -68)
    c:SetText(text)
  end
  colHead("iLvl", -200); colHead("Lowest", -60); colHead("Up", -12)

  Q.rows = {}
  for k = 1, ROWS do
    local b = CreateFrame("Button", nil, f)
    b:SetHeight(ROW_H)
    b:SetPoint("TOPLEFT", 8, -82 - (k - 1) * ROW_H)
    b:SetPoint("RIGHT", -8, 0)
    b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetSize(16, 16)
    b.icon:SetPoint("LEFT", 2, 0)
    b.qty = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.qty:SetPoint("RIGHT", -4, 0)
    b.price = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.price:SetPoint("RIGHT", -40, 0)
    b.lvl = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.lvl:SetPoint("RIGHT", -192, 0)
    b.name = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.name:SetPoint("LEFT", b.icon, "RIGHT", 6, 0)
    b.name:SetPoint("RIGHT", b.lvl, "LEFT", -8, 0)
    b.name:SetJustifyH("LEFT")
    b.name:SetWordWrap(false)
    b:SetScript("OnEnter", function(self)
      if not self.row then return end
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      local link = "item:" .. self.row.id .. (self.row.suffix ~= 0 and ("::::::::::::1:" .. self.row.suffix) or "")
      pcall(GameTooltip.SetHyperlink, GameTooltip, link)
      GameTooltip:AddLine("Click to find it on the auction house.", 0.4, 0.8, 1, true)
      GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    b:SetScript("OnClick", function(self)
      if not self.row then return end
      -- a normal Blizzard search for the name; buy from its results as usual
      local bar = AuctionHouseFrame.SearchBar
      Q.ownSearch = true
      bar:SetSearchText(self.row.name)
      bar:StartSearch()
    end)
    Q.rows[k] = b
  end

  f.more = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  f.more:SetPoint("BOTTOMRIGHT", -10, 8)

  f:EnableMouseWheel(true)
  f:SetScript("OnMouseWheel", function(_, delta)
    Q.offset = math.max(0, Q.offset - delta * 3)
    render()
  end)
  Q.frame = f
  return f
end

function ns.query(text)
  local f = makeResults()
  if not f then return end
  f.box:SetText(text)
  local results, head = run((text:gsub("^%s*where%s+", "")))
  Q.results = results or {}
  Q.offset = 0
  f.head:SetText(results and head or ("|cffff6060" .. head .. "|r"))
  f:Show()
  render()
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
  if AuctionHouseFrameDisplayMode and ah.GetDisplayMode and ah:GetDisplayMode() ~= AuctionHouseFrameDisplayMode.Buy then
    Q.opening = true
    ah:SetDisplayMode(AuctionHouseFrameDisplayMode.Buy)
    Q.opening = false
  end
  f:Show()
  render()
  f.box:SetFocus()
end

-- The Advanced search button on the EverlookDB panel.
local function makeButton()
  local panel = _G.EverlookAuctionsPanel
  if Q.button or not panel or not panel.button then return end
  local b = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
  b:SetSize(196, 24)
  b:SetPoint("BOTTOMLEFT", panel.button, "TOPLEFT", 0, 4)
  b:SetText("Advanced search")
  b:SetScript("OnClick", ns.openSearch)
  panel:SetHeight(panel:GetHeight() + 28)
  Q.button = b
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("AUCTION_HOUSE_SHOW")
ev:SetScript("OnEvent", function()
  C_Timer.After(0.2, function()
    hook()
    makeButton()
  end)
end)
