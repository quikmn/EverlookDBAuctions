-- EverlookDB Auctions: shopping lists.
--   A Shopping tab with your saved lists. A list is a name and a few searches in the Advanced search language
--   (slot is trinket and price lt 5g, "*of the eagle", ...). Run a list to see every search's results one after
--   another in Advanced search, each under its query, with live prices; run a single search the same way.
--   Save in Advanced search adds the search you just ran to the picked list.
--   Lists go in and out as plain text (Import / Export), one list per "# name" line and one search per line, so
--   they can be shared in chat or on a forum.
-- db.lists = { { name = "...", queries = { "...", ... }, want = { [query] = how many to buy } }, ... },
-- db.listSel = index of the picked list. want is there for lists made from a recipe (Crafting.lua, RecipeList.lua).
-- Searching never buys anything: buy from the results as usual.

local _, ns = ...
local UI, T = ns.UI, ns.T
local num = ns.num
local C_GOOD, C_MUTE = UI.hex(T.good), UI.hex(T.mute)

local SH = {}
local ROW = 24

local function lists()
  local db = ns.db()
  if not db then return {} end
  db.lists = db.lists or {}
  return db.lists
end

local function picked()
  local db = ns.db()
  local all = lists()
  if #all == 0 then return nil end
  db.listSel = math.max(1, math.min(db.listSel or 1, #all))
  return all[db.listSel], db.listSel
end

local function uniqueName(name)
  local taken = {}
  for _, l in ipairs(lists()) do taken[l.name] = true end
  if not taken[name] then return name end
  local n = 2
  while taken[name .. " (" .. n .. ")"] do n = n + 1 end
  return name .. " (" .. n .. ")"
end

local function newList(name, queries)
  local all = lists()
  local l = { name = uniqueName(name or "Shopping list"), queries = queries or {} }
  all[#all + 1] = l
  ns.db().listSel = #all
  return l
end

---------------------------------------------------------------------------------------------------------------------
-- Plain text: "# name" starts a list, every other line that isn't empty is a search.

local function exportText(l)
  local out = { "# " .. l.name }
  for _, q in ipairs(l.queries) do out[#out + 1] = q end
  return table.concat(out, "\n")
end

local function importText(text)
  local made, cur = {}, nil
  for raw in (text or ""):gsub("\r", ""):gmatch("[^\n]+") do
    local line = raw:match("^%s*(.-)%s*$"):gsub("||", "|")
    local name = line:match("^#%s*(.+)$")
    if name then
      cur = { name = name, queries = {} }
      made[#made + 1] = cur
    elseif line ~= "" then
      if not cur then
        cur = { name = "Imported", queries = {} }
        made[#made + 1] = cur
      end
      cur.queries[#cur.queries + 1] = line
    end
  end
  for _, l in ipairs(made) do newList(l.name, l.queries) end
  return #made
end

---------------------------------------------------------------------------------------------------------------------
-- The tab

local render

local function setStatus(text, color)
  if not SH.frame then return end
  SH.frame.status:SetText(text or "")
  SH.frame.status:SetTextColor(unpack(color or T.dim))
end

-- Runs a list (or one search) in Advanced search, on the Buy tab.
local function runList(l)
  if not l or #l.queries == 0 then setStatus("Add a search to the list first.", T.bad); return end
  if ns.openSearch then ns.openSearch() end
  if ns.queryList then ns.queryList(l) end
end

local function runOne(q)
  if ns.openSearch then ns.openSearch() end
  if ns.query then ns.query(q) end
end

local function buildListRow(L)
  local b = UI.row(L, ROW)
  b.name = UI.text(b, "body")
  b.name:SetPoint("LEFT", 10, 0)
  b.name:SetPoint("RIGHT", -40, 0)
  b.count = UI.text(b, "mute")
  b.count:SetPoint("RIGHT", -8, 0)
  b.count:SetJustifyH("RIGHT")
  b:SetScript("OnClick", function(self)
    if not self.index then return end
    ns.db().listSel = self.index
    SH.deleteArmed = nil
    render()
  end)
  b:SetScript("OnDoubleClick", function(self) runList(self.item) end)
  UI.tip(b, function() return b.item and b.item.name end, "Click to open. Double-click to run it.")
  return b
end

local function fillListRow(b, l, i)
  local _, sel = picked()
  b.name:SetText(l.name)
  b.count:SetText(num(#l.queries))
  b:EdbSelect(i == sel)
end

local function buildQueryRow(L)
  local b = UI.row(L, ROW)
  b.remove = UI.button(b, "Remove", 64, 18, "small danger")
  b.remove:SetPoint("RIGHT", -2, 0)
  b.run = UI.button(b, "Run", 44, 18, "small")
  b.run:SetPoint("RIGHT", b.remove, "LEFT", -4, 0)
  b.want = UI.text(b, "mute")
  b.want:SetPoint("RIGHT", b.run, "LEFT", -10, 0)
  b.want:SetJustifyH("RIGHT")
  b.text = UI.text(b, "body")
  b.text:SetPoint("LEFT", 10, 0)
  b.text:SetPoint("RIGHT", b.want, "LEFT", -8, 0)
  b.run:SetScript("OnClick", function() if b.item then runOne(b.item) end end)
  b.remove:SetScript("OnClick", function()
    local l = picked()
    if l and b.index then
      local q = table.remove(l.queries, b.index)
      if l.want and q then l.want[q] = nil end
      render()
    end
  end)
  b:SetScript("OnClick", function(self)
    -- put it in the box to change it
    if self.item then
      SH.frame.add:SetText(self.item)
      SH.frame.add:SetFocus()
    end
  end)
  return b
end

local function fillQueryRow(b, q)
  b.text:SetText(C_GOOD .. q .. "|r")
  local l = picked()
  local n = l and l.want and l.want[q]
  b.want:SetText(n and ("buy " .. num(n)) or "")
end

function render()
  local f = SH.frame
  if not f or not f:IsShown() then return end
  local all = lists()
  f.lists.empty:SetText("No lists yet. Press New.")
  f.lists:SetItems(all)
  local l = picked()
  for _, w in ipairs(f.needList) do w:SetShown(l ~= nil) end
  f.none:SetShown(l == nil)
  if not l then return end
  if not f.name:HasFocus() then f.name:SetText(l.name) end
  f.queries.empty:SetText("No searches yet. Type one above and press Add.")
  f.queries:SetItems(l.queries)
  f.del:SetText(SH.deleteArmed and "Sure?" or "Delete")
  f.del:EdbActive(SH.deleteArmed and true or false)
  f.count:SetText(("%s searches"):format(num(#l.queries)))
end

local function showText(mode)
  local f = SH.frame
  local l = picked()
  f.io.mode = mode
  f.io.title:SetText(mode == "export" and "Export: copy this text (Ctrl+C)" or "Import: paste lists (Ctrl+V), then press Import")
  f.io.box:SetText(mode == "export" and l and exportText(l) or "")
  f.io.go:SetShown(mode == "import")
  f.io:Show()
  f.io.box:SetFocus()
  if mode == "export" then f.io.box:HighlightText() end
end

local function makeFrame()
  local ah = _G.AuctionHouseFrame
  if SH.frame or not ah then return SH.frame end
  local f = UI.own(CreateFrame("Frame", "EverlookAuctionsShopping", ah))
  f:SetPoint("TOPLEFT", ah, "TOPLEFT", 2, -24)
  f:SetPoint("BOTTOMRIGHT", ah, "BOTTOMRIGHT", -2, (ns.BAR_H or 0) + 2)   -- the bar along the bottom stays visible
  f:SetFrameLevel(ah:GetFrameLevel() + 150)
  f:EnableMouse(true)
  UI.panel(f, T.bg, T.bg)
  f:Hide()
  SH.frame = f

  -- lists (left)
  local left = UI.panel(CreateFrame("Frame", nil, f))
  left:SetPoint("TOPLEFT", 8, -8)
  left:SetPoint("BOTTOMLEFT", 8, 30)
  left:SetWidth(256)
  local title = UI.text(left, "title")
  title:SetPoint("TOPLEFT", 10, -10)
  title:SetText("Shopping lists")
  local new = UI.button(left, "New", 76, 22, "small")
  new:SetPoint("TOPLEFT", 10, -34)
  new:SetScript("OnClick", function()
    newList("Shopping list")
    render()
    f.name:SetFocus()
    f.name:HighlightText()
  end)
  local imp = UI.button(left, "Import", 76, 22, "small")
  imp:SetPoint("LEFT", new, "RIGHT", 4, 0)
  imp:SetScript("OnClick", function() showText("import") end)
  local sep = UI.line(left, true)
  sep:SetPoint("TOPLEFT", 1, -64)
  sep:SetPoint("TOPRIGHT", -1, -64)
  f.lists = UI.list(left, ROW, buildListRow, fillListRow)
  f.lists:SetPoint("TOPLEFT", 1, -65)
  f.lists:SetPoint("BOTTOMRIGHT", -3, 4)

  -- the picked list (right)
  local R = UI.panel(CreateFrame("Frame", nil, f))
  R:SetPoint("TOPLEFT", left, "TOPRIGHT", 8, 0)
  R:SetPoint("BOTTOMRIGHT", -8, 30)
  f.needList = {}
  local function needs(w) f.needList[#f.needList + 1] = w; return w end

  f.none = UI.text(R, "dim")
  f.none:SetPoint("TOPLEFT", 14, -16)
  f.none:SetText("Make a list with New, or Import one. Save in Advanced search adds searches to it.")

  local nl = needs(UI.label(R, "LIST NAME"))
  nl:SetPoint("TOPLEFT", 12, -10)
  f.name = needs(UI.input(R, 220, 24, { max = 60 }))
  f.name:SetPoint("TOPLEFT", 12, -24)
  f.name:SetScript("OnEnterPressed", function(self)
    local l = picked()
    local newName = self:GetText():match("^%s*(.-)%s*$")
    if l and newName ~= "" and newName ~= l.name then l.name = uniqueName(newName) end
    self:ClearFocus()
    render()
  end)
  f.name:HookScript("OnEditFocusLost", function() render() end)

  f.del = needs(UI.button(R, "Delete", 64, 24, "small danger"))
  f.del:SetPoint("TOPRIGHT", -12, -24)
  f.del:SetScript("OnClick", function()
    local l, i = picked()
    if not l then return end
    if not SH.deleteArmed then
      SH.deleteArmed = true
      render()
      C_Timer.After(3, function() if SH.deleteArmed then SH.deleteArmed = nil; render() end end)
      return
    end
    SH.deleteArmed = nil
    table.remove(lists(), i)
    setStatus("Deleted " .. l.name .. ".", T.dim)
    render()
  end)
  UI.tip(f.del, "Delete this list", "Click twice.")
  local exp = needs(UI.button(R, "Export", 64, 24, "small"))
  exp:SetPoint("RIGHT", f.del, "LEFT", -4, 0)
  exp:SetScript("OnClick", function() showText("export") end)
  local run = needs(UI.button(R, "Run list", 96, 24, "primary"))
  run:SetPoint("RIGHT", exp, "LEFT", -8, 0)
  run:SetScript("OnClick", function() runList(picked()) end)
  UI.tip(run, "Run every search in this list", "Results show in Advanced search, one search after another.")

  local div = needs(UI.line(R, true))
  div:SetPoint("TOPLEFT", 1, -60)
  div:SetPoint("TOPRIGHT", -1, -60)

  local al = needs(UI.label(R, "ADD A SEARCH"))
  al:SetPoint("TOPLEFT", 12, -70)
  f.count = needs(UI.text(R, "mute"))
  f.count:SetPoint("TOPRIGHT", -12, -70)
  f.count:SetJustifyH("RIGHT")
  local addBtn = needs(UI.button(R, "Add", 56, 24))
  addBtn:SetPoint("TOPRIGHT", -12, -84)
  f.add = needs(UI.input(R, 100, 24, { hint = "slot is trinket and price lt 5g sort by price", max = 400 }))
  f.add:SetPoint("TOPLEFT", 12, -84)
  f.add:SetPoint("RIGHT", addBtn, "LEFT", -6, 0)
  local function add()
    local l = picked()
    local q = f.add:GetText():gsub("||", "|"):match("^%s*(.-)%s*$")
    if not l or q == "" then return end
    for _, have in ipairs(l.queries) do if have == q then f.add:SetText(""); return end end
    l.queries[#l.queries + 1] = q
    f.add:SetText("")
    f.add:ClearFocus()
    render()
  end
  f.add:SetScript("OnEnterPressed", add)
  addBtn:SetScript("OnClick", add)

  local bd = needs(UI.headerBand(R, 20))
  bd:SetPoint("TOPLEFT", 1, -118)
  bd:SetPoint("TOPRIGHT", -1, -118)
  local ql = UI.label(bd, "SEARCHES   click one to edit it in the box above")
  ql:SetPoint("LEFT", 12, 0)
  f.queries = needs(UI.list(R, ROW, buildQueryRow, fillQueryRow))
  f.queries:SetPoint("TOPLEFT", 1, -138)
  f.queries:SetPoint("BOTTOMRIGHT", -3, 4)

  -- import / export text
  local io = UI.panel(CreateFrame("Frame", nil, R), T.raised, T.edgeHi)
  io:SetPoint("TOPLEFT", 8, -8)
  io:SetPoint("BOTTOMRIGHT", -8, 8)
  io:SetFrameLevel(R:GetFrameLevel() + 20)
  io:EnableMouse(true)
  io:Hide()
  io.title = UI.text(io, "title")
  io.title:SetPoint("TOPLEFT", 12, -12)
  local close = UI.button(io, "Close", 64, 24)
  close:SetPoint("BOTTOMRIGHT", -10, 10)
  close:SetScript("OnClick", function() io:Hide() end)
  io.go = UI.button(io, "Import", 80, 24, "primary")
  io.go:SetPoint("RIGHT", close, "LEFT", -6, 0)
  local well = UI.panel(CreateFrame("Frame", nil, io), T.input, T.edge)
  well:SetPoint("TOPLEFT", 10, -36)
  well:SetPoint("BOTTOMRIGHT", -10, 44)
  local scroll
  local box = CreateFrame("EditBox")
  box:SetMultiLine(true)
  box:SetAutoFocus(false)
  box:SetFontObject(UI.fontObject("body"))
  box:SetWidth(400)
  box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  box:SetScript("OnCursorChanged", function(_, _, y, _, h)
    -- keep the cursor in view
    local top = scroll:GetVerticalScroll()
    local bottom = top + scroll:GetHeight()
    y = -y
    if y < top then
      scroll:SetVerticalScroll(math.floor(y))
    elseif y + h > bottom then
      scroll:SetVerticalScroll(math.ceil(y + h - scroll:GetHeight()))
    end
  end)
  -- the mouse wheel or the scroll bar on the right (drag it, or click above or below the thumb) scrolls the text
  scroll = UI.scrollFrame(well, box)
  scroll:SetPoint("TOPLEFT", 8, -8)
  scroll:SetPoint("BOTTOMRIGHT", -(UI.BAR_W + 10), 8)
  scroll:HookScript("OnSizeChanged", function(_, w) box:SetWidth(w) end)
  well:EnableMouse(true)
  well:SetScript("OnMouseDown", function() box:SetFocus() end)
  io.box = box
  io.go:SetScript("OnClick", function()
    local n = importText(box:GetText())
    io:Hide()
    setStatus(n > 0 and ("Imported %d list%s."):format(n, n == 1 and "" or "s") or "Nothing to import.", n > 0 and T.good or T.bad)
    render()
  end)
  f.io = io

  f.status = UI.text(f, "dim")
  f.status:SetPoint("BOTTOMLEFT", 12, 9)
  f.status:SetPoint("RIGHT", f, "RIGHT", -12, 0)

  f:SetScript("OnShow", function()
    f.io:Hide()
    render()
  end)
  return f
end

local function closeShopping()
  if not SH.frame or not SH.frame:IsShown() then return end
  SH.frame:Hide()
  if SH.tab then pcall(PanelTemplates_DeselectTab, SH.tab) end
  if ns.blizzardTabs then ns.blizzardTabs(true) end
end

local function openShopping()
  local f = makeFrame()
  if not f then return end
  if ns.closeSearch then ns.closeSearch() end
  if ns.closeSelling then ns.closeSelling() end
  if ns.blizzardTabs then ns.blizzardTabs(false) end
  if SH.tab then pcall(PanelTemplates_SelectTab, SH.tab) end
  if ns.raise then ns.raise(f) end
  f:Show()
  if PlaySound and SOUNDKIT and SOUNDKIT.IG_CHARACTER_INFO_TAB then pcall(PlaySound, SOUNDKIT.IG_CHARACTER_INFO_TAB) end
end

-- The other tabs close this one.
function ns.closeOthers(except)
  if except ~= "shopping" then closeShopping() end
end

-- Save in Advanced search: add a search to the picked list (a new list when there is none).
function ns.saveToList(q)
  if not ns.db() then return end
  local l = picked() or newList("Shopping list")
  for _, have in ipairs(l.queries) do
    if have == q then ns.say(("already in %s."):format(l.name)); return end
  end
  l.queries[#l.queries + 1] = q
  ns.say(("saved to %s (%d searches). The Shopping tab has your lists."):format(l.name, #l.queries))
  render()
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("AUCTION_HOUSE_SHOW")
ev:RegisterEvent("AUCTION_HOUSE_CLOSED")
ev:SetScript("OnEvent", function(_, e)
  if e == "AUCTION_HOUSE_CLOSED" then
    if SH.frame then SH.frame:Hide() end
    if SH.tab then pcall(PanelTemplates_DeselectTab, SH.tab) end
    return
  end
  -- after the Selling tab (made 0.2 s after the auction house opens)
  C_Timer.After(0.3, function()
    if not SH.tab and ns.makeTab then
      SH.tab = ns.makeTab("EverlookAuctionsShoppingTab", "Shopping", openShopping, closeShopping)
    end
    makeFrame()
  end)
end)

-- A list made elsewhere (the profession window's Shopping list) shows at once if the tab is open.
function ns.shoppingRefresh() render() end

local prevSlash, prevHelp = ns.slash, ns.help
function ns.slash(msg)
  if msg == "shop" or msg == "shopping" or msg == "lists" then
    if _G.AuctionHouseFrame and AuctionHouseFrame:IsShown() then openShopping() else ns.say("open the auction house first.") end
    return true
  end
  local listName = msg:match("^run%s+(.+)$")
  if listName then
    for _, l in ipairs(lists()) do
      if l.name:lower() == listName then runList(l); return true end
    end
    ns.say("no list called " .. listName .. ".")
    return true
  end
  return prevSlash and prevSlash(msg) or false
end
function ns.help()
  if prevHelp then prevHelp() end
  print("  /eah shop  open the Shopping tab;  /eah run <list>  run a shopping list")
end
