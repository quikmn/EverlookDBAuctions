-- EverlookDB Auctions: price formulas, the same as on EverlookDB.com (Quarry crates/core/src/formula.rs; the shared
-- fixture tests/formula_fixture.json checks both give the same answers).
--
--   price lt 60% of median          price lt devalue - 50s          sort by median - price
--   myfloor = max(vendor * 1.5, 80% of low30)                       (a My price: a formula saved under a name)
--
-- A formula is numbers, money (5g, 2g50s, 30s, 1g 50s), names (price columns, number columns, My prices), + - * /,
-- parentheses, N% of x, min(...), max(...) and first(...). The rules:
--   * a value that isn't known is nil; + - * / and % of give nil when a side is nil; dividing by 0 gives nil;
--   * min and max take the known values (nil when none is), first the first known one;
--   * money is copper and stays unrounded.
-- Parsed once per search and compiled into closures, so a row costs a few calls and makes no garbage.
local _, ns = ...
local F = {}
ns.formula = F

local function fail(msg) error({ query = msg }, 0) end

local function fmtNum(n)
  if n == math.floor(n) and math.abs(n) < 1e15 then return ("%d"):format(n) end
  return tostring(n)
end
F.fmtNum = fmtNum

-- The token at position i (after spaces): kind ("num", "money", "id", "op"), value, start, end (one past). nil at a
-- character that can't be in a formula (a quote, |, <, =...) or at the end: the formula ends there.
local function token(src, i)
  i = src:find("[^%s]", i) or (#src + 1)
  local start = i
  local c = src:sub(i, i)
  if c == "" then return nil end
  if c:match("%d") then
    local copper, money = 0, false
    while true do
      local ns_ = i
      i = select(2, src:find("^%d+", i)) + 1
      if src:find("^%.%d", i) then i = select(2, src:find("^%.%d+", i)) + 1 end
      local n = tonumber(src:sub(ns_, i - 1))
      local u = src:sub(i, i):lower()
      local len = 1
      local function word(w) return src:sub(i, i + #w - 1):lower() == w end
      if u == "g" and word("gold") then len = 4
      elseif u == "s" and word("silver") then len = 6
      elseif u == "c" and word("copper") then len = 6 end
      local after = src:sub(i + len, i + len)
      local ends = after == "" or not after:match("[%a_]")
      if (u == "g" or u == "s" or u == "c") and ends then
        copper = copper + n * (u == "g" and 10000 or u == "s" and 100 or 1)
        money = true
        i = i + len
        if not src:sub(i, i):match("%d") then break end   -- 2g50s goes on
      elseif money then
        fail("an amount of money is g, s and c, like 2g50s")
      else
        return "num", n, start, i
      end
    end
    return "money", copper, start, i
  end
  if c:match("[%a_]") then
    local e = select(2, src:find("^[%w_]+", i))
    return "id", src:sub(i, e), start, e + 1
  end
  if c:match("[%+%-%*/%%%(%),]") then return "op", c, start, i + 1 end
  return nil
end

local P = {}
P.__index = P

function P:read(at)
  self.k, self.v, self.s, self.e = token(self.src, at)
end
function P:bump()
  local k, v, s, e = self.k, self.v, self.s, self.e
  self.stop = e
  self:read(e)
  return k, v, s, e
end
function P:isOp(c) return self.k == "op" and self.v == c end
function P:startsOperand()
  return self.k == "num" or self.k == "money" or self.k == "id" or (self.k == "op" and (self.v == "(" or self.v == "-"))
end
function P:missing(after) fail(("something is missing after %s; e.g. price lt devalue - 50s"):format(after)) end
function P:operand(after, f)
  if not self:startsOperand() then self:missing(after) end
  return f(self)
end

function P:sum()
  local a = self:prod()
  while self:isOp("+") or self:isOp("-") do
    local op = self.v
    self:bump()
    a = { k = "bin", op = op, a = a, b = self:operand(op, P.prod) }
  end
  return a
end

function P:prod()
  local a = self:unary()
  while self:isOp("*") or self:isOp("/") do
    local op = self.v
    self:bump()
    a = { k = "bin", op = op, a = a, b = self:operand(op, P.unary) }
  end
  return a
end

function P:unary()
  if self:isOp("-") then
    self:bump()
    return { k = "neg", x = self:operand("-", P.unary) }
  end
  return self:atom()
end

local FUN = { min = "min", max = "max", first = "first" }

function P:atom()
  local k, v = self.k, self.v
  if not k then self:missing("this") end
  if k == "num" then
    self:bump()
    if self:isOp("%") then
      self:bump()
      if not (self.k == "id" and self.v:lower() == "of") then
        fail(("%s%% of what? e.g. price lt %s%% of median"):format(fmtNum(v), fmtNum(v)))
      end
      self:bump()
      return { k = "pct", n = v, x = self:operand("of", P.unary) }
    end
    return { k = "num", v = v }
  end
  if k == "money" then
    self:bump()
    local copper = v
    while self.k == "money" do copper = copper + self.v; self:bump() end   -- 1g 50s is one amount
    return { k = "money", v = copper }
  end
  if k == "id" then
    self:bump()
    if not self:isOp("(") then return { k = "name", v = v } end
    local fun = FUN[v:lower()]
    if not fun then fail(("there is no %s(...); use min, max or first, e.g. max(vendor, 80%% of median)"):format(v)) end
    self:bump()
    local args = {}
    while true do
      if not self:startsOperand() then self:missing(#args == 0 and "(" or ",") end
      args[#args + 1] = self:sum()
      if self:isOp(",") then
        self:bump()
      elseif self:isOp(")") then
        self:bump()
        break
      else
        fail(("a ) is missing after %s(...; e.g. max(vendor, median)"):format(v))
      end
    end
    return { k = "call", f = fun, args = args }
  end
  if v == "(" then
    self:bump()
    if not self:startsOperand() then self:missing("(") end
    local x = self:sum()
    if not self:isOp(")") then fail("a ) is missing in the price formula; e.g. (median - price) * 2") end
    self:bump()
    return x
  end
  fail(("a price formula can't start with %s; e.g. 80%% of median"):format(v))
end

-- Reads a formula at position `at` of src, as far as it goes: the formula and the position just after it; nil when
-- no formula starts there. Errors are { query = message }.
function F.parseAt(src, at)
  local p = setmetatable({ src = src, stop = at }, P)
  p:read(at)
  if not p:startsOperand() then return nil end
  local f = p:sum()
  return f, p.stop
end

-- A whole text as one formula (a My price, a shopping list's max price).
function F.parse(src)
  src = tostring(src or "")
  local f, stop = F.parseAt(src, 1)
  if not f then
    if not src:match("%S") then fail("the price formula is empty; e.g. 80% of median") end
    fail("this isn't a price formula; e.g. max(vendor, 80% of median)")
  end
  local rest = src:sub(stop):match("^%s*(.-)%s*$")
  if rest ~= "" then
    fail(("not sure what %s means in the price formula; e.g. max(vendor * 1.5, 80%% of low30)"):format(rest))
  end
  return f
end

-- Just a number or just a name: the query language's plain value, not a formula.
function F.isPlain(f)
  return f.k == "num" or f.k == "name" or (f.k == "neg" and f.x.k == "num")
end
-- Has a part that isn't a name or + and - between names (`name is Hillsbrad - Foothills` stays text).
function F.hasMath(f)
  if f.k == "name" then return false end
  if f.k == "bin" and (f.op == "+" or f.op == "-") then return F.hasMath(f.a) or F.hasMath(f.b) end
  return true
end

---------------------------------------------------------------------------------------------------------------------
-- Compiling: closures over a row

local function const(v) return function() return v end end

-- resolve(name) gives a function(row) -> number or nil for a column, or a parsed formula (a My price) to compile in
-- its place; it raises { query = ... } for a name that is neither.
local function compile(f, resolve, using)
  local k = f.k
  if k == "num" or k == "money" then return const(f.v) end
  if k == "name" then
    local r = resolve(f.v)
    if type(r) == "function" then return r end
    local key = f.v:lower()
    for _, u in ipairs(using) do
      if u == key then
        fail(("the My price %s uses itself (%s → %s); change one of them"):format(f.v, table.concat(using, " → "), f.v))
      end
    end
    if #using >= 16 then fail("My prices use each other too deep (16 at most)") end
    using[#using + 1] = key
    local c = compile(r, resolve, using)
    using[#using] = nil
    return c
  end
  if k == "neg" then
    local x = compile(f.x, resolve, using)
    return function(row) local a = x(row); return a and -a end
  end
  if k == "pct" then
    local x, n = compile(f.x, resolve, using), f.n
    return function(row) local a = x(row); return a and a * n / 100 end
  end
  if k == "bin" then
    local A, B, op = compile(f.a, resolve, using), compile(f.b, resolve, using), f.op
    if op == "+" then return function(row) local a = A(row); if a == nil then return nil end; local b = B(row); return b and a + b end end
    if op == "-" then return function(row) local a = A(row); if a == nil then return nil end; local b = B(row); return b and a - b end end
    if op == "*" then return function(row) local a = A(row); if a == nil then return nil end; local b = B(row); return b and a * b end end
    return function(row)
      local a = A(row)
      if a == nil then return nil end
      local b = B(row)
      if b == nil or b == 0 then return nil end
      return a / b
    end
  end
  -- min, max, first
  local xs = {}
  for i, a in ipairs(f.args) do xs[i] = compile(a, resolve, using) end
  local n = #xs
  if f.f == "first" then
    return function(row)
      for i = 1, n do local v = xs[i](row); if v ~= nil then return v end end
      return nil
    end
  end
  local isMin = f.f == "min"
  return function(row)
    local best
    for i = 1, n do
      local v = xs[i](row)
      if v ~= nil and (best == nil or (isMin and v < best) or (not isMin and v > best)) then best = v end
    end
    return best
  end
end

function F.compile(f, resolve) return compile(f, resolve, {}) end

---------------------------------------------------------------------------------------------------------------------
-- My prices: `name = formula`, one per line or separated by ;

local WORDS = { min = true, max = true, first = true, of = true, ["and"] = true, ["or"] = true, ["not"] = true,
  is = true, ["in"] = true, by = true, sort = true, top = true, where = true, has = true, like = true }

-- A My price's name: one word of letters, digits and _, starting with a letter, not a column or query word.
-- taken(lower name) says whether a column has it.
function F.checkName(name, taken)
  if not name:match("^%a[%w_]*$") then
    return ('a My price\'s name is one word of letters, digits and _, like myfloor (not "%s")'):format(name)
  end
  local lower = name:lower()
  if WORDS[lower] then return ("%s is a word of the query language; pick another name, like my%s"):format(name, lower) end
  if taken and taken(lower) then return ("%s is already a column; pick another name, like my%s"):format(name, lower) end
end

-- The pairs { { name, formula text } } in order (a later one of the same name wins), or nil and what is wrong.
function F.parseMy(text, taken)
  local out = {}
  for part in (tostring(text or "") .. "\n"):gmatch("([^\n;]*)[\n;]") do
    part = part:match("^%s*(.-)%s*$")
    if part ~= "" then
      local name, formula = part:match("^([^=]*)=(.*)$")
      if not name then
        return nil, ('"%s": write a name, =, then the formula, like myfloor = max(vendor * 1.5, 80%% of low30)'):format(part)
      end
      name, formula = name:match("^%s*(.-)%s*$"), formula:match("^%s*(.-)%s*$")
      local bad = F.checkName(name, taken)
      if bad then return nil, bad end
      local ok, err = pcall(F.parse, formula)
      if not ok then return nil, name .. ": " .. (type(err) == "table" and err.query or tostring(err)) end
      for i = #out, 1, -1 do if out[i][1]:lower() == name:lower() then table.remove(out, i) end end
      out[#out + 1] = { name, formula }
    end
  end
  return out
end
