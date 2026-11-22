-- EverlookDB Auctions: pasting a list of items to buy into a shopping list (the logic, no frames).
--   One item per line, in any common form:
--     60 Light Leather        60x Light Leather       60 x Light Leather      Light Leather x60
--     Light Leather, 60       Light Leather: 60       Light Leather - 60      Light Leather 60     Light Leather (60)
--     [Light Leather] x60     an item link            2318 60 (item ID, then how many)          item:2318 x60
--     60 Light Leather #2318  (everlookdb.com's "Copy for the addon": the ID after # wins over the name)
--     name is "Light Leather"  buy 60  (this addon's own Export)
--   Bullets, numbering ("1. ") and check boxes ("[ ]") in front are left out. "max 25s" (or "max 1g 50s", "under
--   25s") anywhere after the item sets the most to pay for one. "# Name" starts a list of that name.
--   A line without an amount that reads like a search ("slot is trinket", quotes, "price lt 5g") stays a search; one
--   that names an item buys one. Lines are never dropped: what can't be read or found is returned to show.
-- Saved shape (Shopping.lua): list.queries (one 'name is "X"' per item), list.want[q] how many, list.items[q] the
-- item ID, list.max[q] the most to pay for one (copper), list.countHave = true when what you have counts against it.
local _, ns = ...
local I = {}
ns.listImport = I

local function trim(s) return (tostring(s or ""):match("^%s*(.-)%s*$")) end

---------------------------------------------------------------------------------------------------------------------
-- Money: "25s", "1g 50s", "1g50s20c", "2.5g", "1 gold 5 silver". nil when there is no g, s or c.

function I.money(text)
  text = tostring(text or ""):lower()
  local total, any = 0, false
  for n, unit in text:gmatch("(%d+%.?%d*)%s*([gsc])%a*") do
    local v = tonumber(n)
    if v then
      any = true
      total = total + v * (unit == "g" and 10000 or unit == "s" and 100 or 1)
    end
  end
  if not any then return nil end
  return math.floor(total + 0.5)
end

---------------------------------------------------------------------------------------------------------------------
-- One line

-- What reads like the Advanced search language rather than an item name.
local SEARCHY = { " is ", " lt ", " gt ", " le ", " ge ", " and ", " or ", " not ", "sort by", "<", ">", "=", '"', "*" }
local function searchy(text)
  local t = " " .. text:lower() .. " "
  for _, w in ipairs(SEARCHY) do if t:find(w, 1, true) then return true end end
  return false
end

-- Reads one line. Returns nil for an empty line or a comment, else a table:
--   { header = "List name" } for "# List name"
--   { id = n or nil, name = "..." or nil, n = amount or nil, max = copper or nil, maxBad = true when "max" had no
--     g/s/c, line = the line as typed }, { search = text } when it is a search, { bad = why } when nothing is in it
function I.parseLine(raw)
  local line = trim(tostring(raw or ""):gsub("||", "|"))
  if line == "" or line:match("^//") or line:match("^%-%-") then return nil end
  local head = line:match("^#%s*(.-)%s*$")
  if head and not line:match("^#%d") then
    if head == "" then return nil end
    return { header = head }
  end
  local e = { line = line }
  local s = (line:gsub("\195\151", "x"))   -- the times sign
  -- bullets, numbering, check boxes
  s = s:gsub("^[%-%*]+%s*", ""):gsub("^\226\128\162%s*", ""):gsub("^\194\183%s*", "")
  s = s:gsub("^%[[%sxX]?%]%s*", "")
  if s:match("^%d+[%.%)]%s+.*%a") then s = s:gsub("^%d+[%.%)]%s+", "") end
  -- the most to pay: "max 25s", "max price: 1g", "(max 25s)", "under 25s", "<= 25s"
  local lower = s:lower()
  local p, q = lower:find("%f[%a]max%f[%A]")
  if not p then p, q = lower:find("%f[%a]under%f[%A]") end
  if not p then p, q = lower:find("<=?") end
  if p then
    local after = s:sub(q + 1):gsub("^%s*[Pp]rice", ""):gsub("^%s*[:=]?%s*", ""):gsub("%)%s*$", "")
    if after:match("%d") then
      local m = I.money(after)
      if m then e.max = m else e.maxBad = true end
      s = trim(s:sub(1, p - 1):gsub("[%s,;%(]+$", ""))
    end
  end
  -- an item link, or the ID in any of its forms
  local linkID = s:match("|Hitem:(%d+)")
  if linkID then
    e.id = tonumber(linkID)
    e.name = s:match("|h%[(.-)%]|h")
    s = trim(s:gsub("|H.-|h%[.-%]|h", " "):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
  end
  local function takeID(pat)
    if e.id then return end
    local a, id, b = s:match("^(.-)" .. pat .. "(.*)$")
    if id then e.id = tonumber(id); s = trim(a .. " " .. b) end
  end
  takeID("[Ii]tem[:=](%d+)")
  takeID("%f[%w]i:(%d+)")
  takeID("#(%d+)")
  s = trim(s)
  -- our own Export of a search: name is "X" (buy N)
  local qn, qbuy = s:match('^[Nn]ame%s+is%s+"(.-)"%s*[Bb]uy%s+(%d+)$')
  if qn then e.name, e.n, s = qn, tonumber(qbuy), "" end
  -- a name in brackets, as chat shows it without the link: "[Light Leather] x60"
  local bracket = s:match("%[(.-)%]")
  if bracket and not e.name and not bracket:match("^%d+$") then
    e.name = bracket
    s = trim(s:gsub("%[.-%]", " ", 1))
  end
  -- the amount and the name
  local n, name
  if s ~= "" then
    local a, b = s:match("^(%d+)%s+(%d+)$")
    if a and not e.id then
      e.id, n = tonumber(a), tonumber(b)            -- "2318 60": the ID, then how many
    elseif s:match("^%d+$") then
      if e.id or e.name then n = tonumber(s) else e.id = tonumber(s) end
    elseif (e.id or e.name) and s:match("^[xX%*]%s*%d+$") then
      n = tonumber(s:match("(%d+)$"))
    else
      local x, rest = s:match("^(%d+)%s*[xX%*]%s+(.+)$")
      if not x then x, rest = s:match("^(%d+)[xX%*](%u.*)$") end
      if not x then x, rest = s:match("^(%d+)%s+(.+)$") end
      if x then
        n, name = tonumber(x), rest
      else
        local nm, y = s:match("^(.-)%s+[xX]%s*(%d+)$")
        if not nm then nm, y = s:match("^(.-)%s*%*%s*(%d+)$") end
        if not nm then nm, y = s:match("^(.-)%s*[,;:=]%s*(%d+)$") end
        if not nm then nm, y = s:match("^(.-)%s+%-%s*(%d+)$") end
        if not nm then nm, y = s:match("^(.-)%s*%((%d+)%)$") end
        if not nm then nm, y = s:match("^(.-)%s+(%d+)$") end
        if nm and trim(nm) ~= "" then n, name = tonumber(y), nm else name = s end
      end
    end
  end
  if name then
    name = trim(trim(name):gsub("^[\"']+", ""):gsub("[\"']+$", ""):gsub("[,;:]+$", ""))
    if name ~= "" and not e.name then e.name = name end
  end
  e.n = e.n or n
  if e.n and e.n < 1 then e.n = nil end
  -- no amount, no ID, no link: a search when it reads like one
  if not e.n and not e.id and searchy(line) then return { search = line, line = line } end
  if not e.id and not e.name then return { bad = "nothing to read", line = line } end
  return e
end

-- Auctionator-style exports: "List^"Light Leather";;0;0;0;0;0;0;0;0;;#;;60^..." become one item per line.
function I.unpack(text)
  text = tostring(text or ""):gsub("\r", "")
  if not text:find("%^") or text:find("\n.*%^") and not text:find(";") then return text end
  local out = {}
  for line in text:gmatch("[^\n]+") do
    if line:find("%^") and line:find(";") then
      local first = true
      for chunk in line:gmatch("[^%^]+") do
        if chunk:find(";") then
          local fields = {}
          for f in (chunk .. ";"):gmatch("(.-);") do fields[#fields + 1] = f end
          local name = trim((fields[1] or ""):gsub('"', ""))
          local qty
          for k = #fields, 2, -1 do
            local v = tonumber(fields[k])
            if v then qty = v; break end
          end
          if name ~= "" then out[#out + 1] = (qty and qty > 0) and (math.floor(qty) .. " " .. name) or name end
        elseif first then
          out[#out + 1] = "# " .. trim(chunk)
        end
        first = false
      end
    else
      out[#out + 1] = line
    end
  end
  return table.concat(out, "\n")
end

---------------------------------------------------------------------------------------------------------------------
-- The whole paste

-- The search for one item: its exact name, in quotes (as RecipeList.lua makes it).
function I.query(name) return ('name is "%s"'):format((tostring(name or ""):gsub('"', ""))) end

-- Reads a paste. lookup = { idOf(name) -> id or nil, nameOf(id) -> name or nil (nil while the game loads it) }.
-- Returns {
--   lists = { { name, items = { { id, name, n, max } (one per item, amounts added up) }, searches = { text } } },
--   bad = { { line, why } }   lines that couldn't be used (why: "unknown", "loading", "nothing to read"),
--   loading = { id, ... }    item IDs whose names the game hasn't sent yet (ask again in a moment),
--   maxBad = { line }        "max ..." without g, s or c (the item still counts, without a max price) }
-- defaultName names the lines before the first "# name".
function I.read(text, lookup, defaultName)
  lookup = lookup or {}
  local res = { lists = {}, bad = {}, loading = {}, maxBad = {} }
  local cur
  local function list(name)
    for _, l in ipairs(res.lists) do if l.name == name then return l end end
    local l = { name = name, items = {}, searches = {}, byID = {} }
    res.lists[#res.lists + 1] = l
    return l
  end
  local waiting = {}
  for raw in I.unpack(text):gmatch("[^\n]+") do
    local e = I.parseLine(raw)
    if e and e.header then
      cur = list(e.header)
    elseif e then
      cur = cur or list(trim(defaultName or "") ~= "" and trim(defaultName) or "Shopping list")
      if e.search then
        cur.searches[#cur.searches + 1] = e.search
      elseif e.bad then
        res.bad[#res.bad + 1] = { line = e.line, why = e.bad }
      else
        if e.maxBad then res.maxBad[#res.maxBad + 1] = e.line end
        local id = e.id
        if not id and e.name and lookup.idOf then id = lookup.idOf(e.name) end
        local name = id and lookup.nameOf and lookup.nameOf(id)
        if id and not name then
          res.bad[#res.bad + 1] = { line = e.line, why = "loading", id = id }
          if not waiting[id] then waiting[id] = true; res.loading[#res.loading + 1] = id end
        elseif not id then
          -- a bare name nobody knows, without an amount: kept as a search, and said
          if not e.n and not e.max and e.name and not e.line:find("%[") then
            cur.searches[#cur.searches + 1] = e.line
            res.asSearch = res.asSearch or {}
            res.asSearch[#res.asSearch + 1] = e.line
          else
            res.bad[#res.bad + 1] = { line = e.line, why = "unknown" }
          end
        else
          local it = cur.byID[id]
          if not it then
            it = { id = id, name = name, n = 0 }
            cur.byID[id] = it
            cur.items[#cur.items + 1] = it
          end
          it.n = it.n + (e.n or 1)
          if e.max and (not it.max or e.max < it.max) then it.max = e.max end
        end
      end
    end
  end
  for _, l in ipairs(res.lists) do l.byID = nil end
  return res
end

-- Saves what I.read found into lists (db.lists): a list with the same name gets the items added to it (amounts of
-- the same item add up), else a new list is made. countHave: what you have counts against the amounts. Returns
-- { { list, new, items = n, searches = n } }.
function I.save(lists, res, countHave)
  local done = {}
  for _, src in ipairs(res.lists or {}) do
    if #src.items > 0 or #src.searches > 0 then
      local l, new
      for _, x in ipairs(lists) do if x.name == src.name then l = x end end
      if not l then
        l = { name = src.name, queries = {} }
        lists[#lists + 1] = l
        new = true
      end
      l.queries = l.queries or {}
      local have = {}
      for _, q in ipairs(l.queries) do have[q] = true end
      for _, it in ipairs(src.items) do
        local q = I.query(it.name)
        if not have[q] then l.queries[#l.queries + 1] = q; have[q] = true end
        l.want, l.items = l.want or {}, l.items or {}
        l.want[q] = (l.want[q] or 0) + it.n
        l.items[q] = it.id
        if it.max then
          l.max = l.max or {}
          l.max[q] = it.max
        end
      end
      for _, q in ipairs(src.searches) do
        if not have[q] then l.queries[#l.queries + 1] = q; have[q] = true end
      end
      if #src.items > 0 then l.countHave = countHave and true or nil end
      done[#done + 1] = { list = l, new = new, items = #src.items, searches = #src.searches, index = nil }
      for i, x in ipairs(lists) do if x == l then done[#done].index = i end end
    end
  end
  return done
end

-- Lines of a list as text again: items as "60 Light Leather #2318 max 25s", other searches as they are.
function I.export(l, moneyText)
  local out = { "# " .. l.name }
  for _, q in ipairs(l.queries or {}) do
    local n = l.want and l.want[q]
    local name = q:match('^name is "(.*)"$')
    if n and name then
      local line = ("%d %s"):format(n, name)
      local id = l.items and l.items[q]
      if id then line = line .. " #" .. id end
      local m = l.max and l.max[q]
      if m then line = line .. " max " .. (moneyText and moneyText(m) or (m .. "c")) end
      out[#out + 1] = line
    else
      out[#out + 1] = q
    end
  end
  return table.concat(out, "\n")
end

-- Money as typed text, for Export and the max box: "1g50s", "25s", "75c".
function I.moneyText(c)
  c = math.floor(tonumber(c) or 0)
  local g, s, k = math.floor(c / 10000), math.floor(c / 100) % 100, c % 100
  local out = (g > 0 and (g .. "g") or "") .. (s > 0 and (s .. "s") or "") .. (k > 0 and (k .. "c") or "")
  return out ~= "" and out or "0c"
end

---------------------------------------------------------------------------------------------------------------------
-- Names to item IDs, from the game (items it has seen) and the addon's own item cache (every item a scan saw)

-- Built once and again only when a name isn't in it and it is a few seconds old (the cache grows with every scan).
local index, indexAt
local function nameIndex(fresh)
  local db = ns.db and ns.db()
  local cache = db and db.itemInfo
  if not cache then return {} end
  local now = GetTime and GetTime() or 0
  if index and not (fresh and now - indexAt > 5) then return index end
  index, indexAt = {}, now
  for id, v in pairs(cache) do
    local name
    if type(v) == "table" then name = v[1]
    elseif type(v) == "string" then name = v:match("^[^^]*^[^^]*^[^^]*^[^^]*^[^^]*^[^^]*^[^^]*^[^^]*^[^^]*^(.*)$") end
    if type(name) == "string" and name ~= "" then
      local k = name:lower()
      if not index[k] or id < index[k] then index[k] = id end
    end
  end
  return index
end

local function try(fn, ...)
  if type(fn) ~= "function" then return nil end
  local okCall, a = pcall(fn, ...)
  if okCall then return a end
end

function I.idOf(name)
  name = trim(name)
  if name == "" then return nil end
  local function find(n)
    local id = nameIndex()[n:lower()] or nameIndex(true)[n:lower()]
    if id then return id end
    local link
    for _, fn in ipairs({ C_Item and C_Item.GetItemInfo or false, rawget(_G, "GetItemInfo") or false }) do
      if not link and type(fn) == "function" then
        local okCall, _, l = pcall(fn, n)
        if okCall then link = l end
      end
    end
    if type(link) == "string" then return tonumber(link:match("item:(%d+)")) end
  end
  local id = find(name)
  if id then return id end
  -- "Light Leathers": the name without a plural s
  if name:match("[^s]s$") then return find(name:sub(1, -2)) end
end

function I.nameOf(id)
  local c = ns.itemInfo and ns.itemInfo(id)
  if c and c[1] then return c[1] end
  local n = try(C_Item and C_Item.GetItemNameByID, id)
  if not n and C_Item and C_Item.RequestLoadItemDataByID then pcall(C_Item.RequestLoadItemDataByID, id) end
  return n
end

I.lookup = { idOf = function(n) return I.idOf(n) end, nameOf = function(id) return I.nameOf(id) end }
