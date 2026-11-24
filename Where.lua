-- EverlookDB Auctions: what your characters have, for the player (Inventory.lua keeps it).
--   Tooltip   one line on every item tooltip: "You have 52  Mara 40 (bank) · Thorn 12 (mail)", the total on the
--             right; holding Shift lists each character with its places. Tooltips setting "tiphave" turns it off.
--   Where is it?   a page of the main window: a search in the query language over everything your characters on this
--             realm have (`have gt 20 and name has cloth`, `char is Mara`, `place is bank`), each item with who has it
--             where, and your gold per character. /eah where <item or query> answers in chat and opens the page.
--   Home      the "Your characters" card: gold on all of them (Hub.lua draws it from W.goldLines).
local ADDON, ns = ...
local I = ns.inventory

local W = {}
ns.where = W

local Tip = LibStub and LibStub("EverlookTooltip-1", true)
local SEP = " \194\183 "

local function count(n) return (Tip and Tip.Count(n)) or tostring(n or 0) end
local function nameOf(e) return Tip and Tip.ClassName(e.name, e.class) or tostring(e.name) end
local function money(c) return ns.money and ns.money(c) or tostring(c) end
local function mute(s) return Tip and (Tip.Hex(Tip.COLOR.note) .. s .. "|r") or s end

-- "bank", "bank, mail": a character's places for an item, the biggest first.
function W.placesText(e)
  local list = {}
  for _, p in ipairs(I.PLACES) do if (e[p] or 0) > 0 then list[#list + 1] = p end end
  table.sort(list, function(a, b) return e[a] > e[b] end)
  for i, p in ipairs(list) do list[i] = I.WORD[p] end
  return table.concat(list, ", ")
end
-- "40 bags · 12 bank": every place with its count
function W.detailText(e)
  local out = {}
  for _, p in ipairs(I.PLACES) do if (e[p] or 0) > 0 then out[#out + 1] = count(e[p]) .. " " .. I.WORD[p] end end
  return table.concat(out, SEP)
end

-- The tooltip's lines for an item: { label, note, value, details = { { label, value, note } } } or nil when none of
-- your characters (or your guild bank) has any. max: how many other holders the line names (3).
function W.tipLines(id, max)
  local r = I and I.count(id)
  if not r or (r.total == 0 and r.guild == 0) then return nil end
  max = max or 3
  local others, holders = {}, 0
  for _, e in ipairs(r.chars) do
    if e.total > 0 then
      holders = holders + 1
      if not e.me then others[#others + 1] = ("%s %s (%s)"):format(nameOf(e), count(e.total), W.placesText(e)) end
    end
  end
  for _, g in ipairs(r.guilds) do
    holders = holders + 1
    others[#others + 1] = ("Guild bank %s"):format(count(g.n))
  end
  if #others == max + 1 then max = #others end   -- never "+1": that one is shown instead
  local shown = {}
  for i = 1, math.min(#others, max) do shown[i] = others[i] end
  local note = table.concat(shown, SEP)
  if #others > max then note = note .. " " .. mute("+" .. (#others - max)) end
  local res = { note = note }
  res.label = r.mine > 0 and ("You have " .. count(r.mine)) or "Your alts have"
  if holders > 1 or r.mine == 0 then res.value = count(r.total + r.guild) end
  res.details = {}
  for _, e in ipairs(r.chars) do
    if e.total > 0 then
      res.details[#res.details + 1] = { label = e.me and "You" or nameOf(e), value = count(e.total), note = W.detailText(e) }
    end
  end
  for _, g in ipairs(r.guilds) do
    res.details[#res.details + 1] = { label = g.name, value = count(g.n), note = "guild bank" }
  end
  return res
end

local function shiftDown() return IsShiftKeyDown and IsShiftKeyDown() and true or false end

function W.tooltip(t, id)
  if not id or not (ns.tipOn and ns.tipOn("have")) then return end
  local l = W.tipLines(id)
  if not l then return end
  t:Line(l.label, l.value, { note = l.note })
  if shiftDown() then
    for _, d in ipairs(l.details) do t:Detail(d.label, d.value, { always = true, note = d.note }) end
  end
end

if Tip then
  Tip:Register({ id = "EverlookDBAuctions.have", kind = "item", order = Tip.ORDER.alts or 85,
    add = function(t, ctx) if ctx.id then W.tooltip(t, ctx.id) end end })
end

---------------------------------------------------------------------------------------------------------------------
-- The search ("Where is it?")

W.DEFAULT_SORT = { { col = "have", desc = true }, { col = "name" } }

-- Every item your characters have as rows of the query language, then the query over them: rows, a head line, how
-- many items the game is still loading, or nil and the error.
function W.search(query)
  local rows, missing = {}, 0
  for id in pairs(I.items()) do
    local row = ns.queryItemRow and ns.queryItemRow(id)
    if row then
      rows[#rows + 1] = row
    else
      missing = missing + 1
      if C_Item and C_Item.RequestLoadItemDataByID then pcall(C_Item.RequestLoadItemDataByID, id) end
    end
  end
  query = tostring(query or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if not ns.queryRows then return nil, "the search isn't loaded" end
  local out, counted
  if query == "" then
    out = ns.queryRows("sort by have desc, name", rows)
  else
    out, counted = ns.queryRows(query, rows, W.DEFAULT_SORT)
  end
  if not out then return nil, counted end
  local head
  if counted then head = ("%s matching items"):format(count(counted))
  else head = ("%s %s"):format(count(#out), #out == 1 and "item" or "items") end
  return out, head, missing
end

-- What a result row says under its name: "You 40 (bags) · Mara 12 (bank) · Guild bank 3"
function W.holdersText(id)
  local r = I.count(id)
  if not r then return "" end
  local out = {}
  for _, e in ipairs(r.chars) do
    if e.total > 0 then out[#out + 1] = ("%s %s (%s)"):format(e.me and "You" or nameOf(e), count(e.total), W.detailText(e)) end
  end
  for _, g in ipairs(r.guilds) do out[#out + 1] = ("%s %s (guild bank)"):format(g.name, count(g.n)) end
  return table.concat(out, SEP)
end

-- Gold: "1,234g on 4 characters" and "Mara 800g · Thorn 300g · you 134g" (Home's card and this page).
function W.goldLines(max)
  local total, list = I.gold()
  if #list == 0 then return nil end
  local parts = {}
  max = max or 3
  for i = 1, math.min(#list, max) do
    local e = list[i]
    parts[#parts + 1] = (e.me and "you" or nameOf(e)) .. " " .. money(e.money + e.mail)
  end
  if #list > max then parts[#parts + 1] = ("%d more"):format(#list - max) end
  return ("%s on %d %s"):format(money(total), #list, #list == 1 and "character" or "characters"), table.concat(parts, SEP), total, list
end

-- The chat answer of /eah where <query>: a few lines.
function W.say(query, max)
  local out, head = W.search(query)
  if not out then ns.say("|cffef5d5d" .. tostring(head) .. "|r"); return end
  max = max or 6
  if #out == 0 then
    ns.say(("nothing your characters have matches %s."):format(query))
    return
  end
  ns.say(head .. ":")
  for i = 1, math.min(#out, max) do
    local r = out[i]
    print(("  %s  %s: %s"):format(r.name or ("item " .. r.id), count(I.column(r.id, "have")), W.holdersText(r.id)))
  end
  if #out > max then print(("  %d more on the Where is it? page."):format(#out - max)) end
end

---------------------------------------------------------------------------------------------------------------------
-- The page

local page = { query = "" }

local function qualityColor(q)
  local idx = { poor = 0, common = 1, uncommon = 2, rare = 3, epic = 4, legendary = 5, artifact = 6, heirloom = 7 }
  local c = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[idx[q] or 1]
  if c then return { c.r, c.g, c.b, 1 } end
end

function W.open(query)
  if query then page.query = query end
  if page.box and page.box.box then page.box.box:SetText(page.query) end
  if ns.hub and ns.hub.open("where") then
    if page.status then page.status:Refresh() end
    if page.list then page.list:Refresh() end
    return true
  end
  return false
end

-- the status line runs the search (page.rows), then the list draws it
local function refresh()
  if page.status then page.status:Refresh() end
  if page.list then page.list:Refresh() end
  if page.gold then page.gold:Refresh() end
end

function W.page(app, UI)
  app:Section("where", "Where is it?", function(stack)
    UI.Header(stack, "Where is it?", "Everything your characters on this realm have: bags, bank, mail, auctions, what they wear and your guild bank.")
    page.box = UI.Input(stack, {
      placeholder = "An item, or a query like  have gt 20 and name has cloth", width = 460,
      get = function() return page.query end,
      set = function(v) page.query = v or "" end,
      onChange = function(v) page.query = v or ""; refresh() end,
      onEnter = function(v) page.query = v or ""; refresh() end,
      button = { label = "Find", style = "accent", width = 90, onClick = function(v) page.query = v or ""; refresh() end },
    })
    page.status = UI.Note(stack, function()
      local out, head, missing = W.search(page.query)
      page.rows = out or {}
      if not out then return "|cffef5d5d" .. tostring(head) .. "|r" end
      local extra = (missing or 0) > 0 and ("  \194\183  %d still loading"):format(missing) or ""
      return head .. extra .. "  \194\183  also: char is Mara, place is bank, mail gt 0, listed gt 0, have gt 20 sort by have"
    end)
    page.list = UI.List(stack, {
      items = function() return page.rows or {} end,
      empty = "Nothing found. Each character is counted once it logs in; the bank, mailbox and guild bank once they are opened.",
      rowHeight = 40,
      title = function(r) return ("%s  |cffffffff%s|r"):format(r.name or ("item " .. r.id), count(I.column(r.id, "have"))) end,
      color = function(r) return qualityColor(r.quality) end,
      detail = function(r) return W.holdersText(r.id) end,
      icon = function(r) return r.icon end,
      tooltip = function(r, row)
        if ns.itemTooltip then ns.itemTooltip(row, r.id) else
          GameTooltip:SetOwner(row, "ANCHOR_RIGHT"); GameTooltip:SetItemByID(r.id); GameTooltip:Show()
        end
      end,
      max = 200,
    })
    UI.Header(stack, "Gold", "On each character when it last logged out, and what waits for it in the mail.")
    page.gold = UI.Note(stack, function()
      local total, list = I.gold()
      if #list == 0 then return "Each character's gold shows once it has logged in." end
      local lines = { ("All characters: %s"):format(money(total)) }
      for _, e in ipairs(list) do
        lines[#lines + 1] = ("%s  %s%s"):format(e.me and "You" or nameOf(e), money(e.money),
          e.mail > 0 and ("  (+%s in the mail)"):format(money(e.mail)) or "")
      end
      return table.concat(lines, "\n")
    end)
    UI.Note(stack, "Everything here stays on this PC. Shift on an item's tooltip lists who has it where; Settings, Tooltips turns the line off.")
  end, { group = "main", icon = "user", desc = "Find any item on any of your characters, and their gold." })

  app:Command("where", "where <item or query>", "which of your characters has an item, and where (bags, bank, mail, auctions, guild bank)", function(rest)
    rest = tostring(rest or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if rest == "" then W.open(); return end
    W.say(rest)
    W.open(rest)
  end, { "have", "inventory", "inv", "find" })

  I.onChange(function()
    if app:IsShown() and app.current == "where" then refresh() end
  end)
end
