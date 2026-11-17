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

-- Text with any | doubled, so a list name or search shows as typed (a lone | starts a WoW escape code).
local function plain(text) return (tostring(text or ""):gsub("|", "||")) end

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
  UI.tip(b, function() return b.item and plain(b.item.name) end, "Click to open. Double-click to run it.")
  return b
end

local function fillListRow(b, l, i)
  local _, sel = picked()
  b.name:SetText(plain(l.name))
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
      if SH.editing and SH.editing.query == q then SH.editing = nil end
      render()
    end
  end)
  b:SetScript("OnClick", function(self)
    -- put it in the box to change it: Save then replaces it in place (Add while nothing is being changed)
    if self.item then
      SH.editing = { list = picked(), query = self.item }
      SH.frame.add:SetText(plain(self.item))
      SH.frame.add:SetFocus()
      render()
    end
  end)
  return b
end

local function fillQueryRow(b, q)
  b.text:SetText(C_GOOD .. plain(q) .. "|r")
  local l = picked()
  local n = l and l.want and l.want[q]
  b.want:SetText(n and ("buy " .. num(n)) or "")
end

function render()
  local f = SH.frame
  if not f or not f:IsShown() then return end
  local all = lists()
  f.lists.empty:SetText("No lists yet. Press New list on the right.")
  f.lists:SetItems(all)
  local l = picked()
  for _, w in ipairs(f.needList) do w:SetShown(l ~= nil) end
  f.none:SetShown(l == nil)
  if not l then return end
  if f.name:HasFocus() and f.name.edbList ~= l then f.name:ClearFocus() end   -- saves the name for its own list
  if not f.name:HasFocus() then f.name:SetText(plain(l.name)) end
  f.queries.empty:SetText("No searches yet. Type one above and press Add.")
  f.queries:SetItems(l.queries)
  f.del:SetText(SH.deleteArmed and "Sure?" or "Delete")
  f.del:EdbActive(SH.deleteArmed and true or false)
  f.count:SetText(("%s searches"):format(num(#l.queries)))
  -- the search being changed: still in this list?
  local e = SH.editing
  if e and e.list ~= l then SH.editing, e = nil, nil end
  f.addBtn:SetText(e and "Save" or "Add")
end

-- Saves a typed search into list l: a new one, or in place of the search being changed (keeping its amount to
-- buy). Returns what happened: "added", "saved", "same" (already there) or nil (nothing typed).
function SH.store(l, q, editing)
  if not l or q == "" then return nil end
  if editing and editing.list == l then
    for i, have in ipairs(l.queries) do
      if have == editing.query then
        if q ~= have then
          for _, other in ipairs(l.queries) do if other == q then return "same" end end
          l.queries[i] = q
          if l.want and l.want[have] then l.want[q], l.want[have] = l.want[have], nil end
        end
        return "saved"
      end
    end
  end
  for _, have in ipairs(l.queries) do if have == q then return "same" end end
  l.queries[#l.queries + 1] = q
  return "added"
end

local function showText(mode)
  local f = SH.frame
  local l = picked()
  f.io.mode = mode
  f.io.title:SetText(mode == "export" and "Export: copy this text (Ctrl+C)" or "Import: paste lists (Ctrl+V), then press Import")
  f.io.box:SetText(mode == "export" and l and plain(exportText(l)) or "")   -- Import turns || back into |
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
  local PLACE = UI.place(f, "shopping")   -- Shopping's colour: where you are
  UI.panel(f, T.bg, PLACE)
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
  title:SetTextColor(unpack(PLACE))
  local function startList()
    newList("Shopping list")
    render()
    f.name:SetFocus()
    f.name:HighlightText()
    setStatus("New list made. Name it, then type a search under Add a search and press Add.", T.good)
  end
  local new = UI.button(left, "New", 76, 22, "small")
  new:SetPoint("TOPLEFT", 10, -34)
  new:SetScript("OnClick", startList)
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

  -- no lists yet: what the tab is for, in big plain words, and the button to start, front and centre
  local none = CreateFrame("Frame", nil, R)
  none:SetPoint("TOPLEFT", 24, -24)
  none:SetPoint("BOTTOMRIGHT", -24, 24)
  f.none = none
  local block = CreateFrame("Frame", nil, none)
  block:SetSize(440, 300)
  block:SetPoint("CENTER", 0, 10)
  local head = UI.text(block, "big")
  head:SetFont(STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", 20, "")
  head:SetTextColor(unpack(PLACE))
  head:SetPoint("TOP", 0, 0)
  head:SetJustifyH("CENTER")
  head:SetText("Shopping lists: searches you run often")
  local body = UI.text(block, "body")
  body:SetFont(STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", 14, "")
  body:SetTextColor(unpack(T.text))
  body:SetWidth(440)
  body:SetWordWrap(true)
  body:SetJustifyH("CENTER")
  body:SetPoint("TOP", head, "BOTTOM", 0, -16)
  body:SetText("Keep the things you shop for in a list, like Linen Cloth or trinkets under 5 gold. "
    .. "Run the whole list with one click and the results of every search show one after another, "
    .. "with live prices. Nothing is bought until you click Buy.")
  local go = UI.button(block, "New list", 170, 34, "primary")
  go:SetPoint("TOP", body, "BOTTOM", -70, -24)
  go:SetScript("OnClick", startList)
  local imp2 = UI.button(block, "Import a list", 130, 34)
  imp2:SetPoint("LEFT", go, "RIGHT", 10, 0)
  imp2:SetScript("OnClick", function() showText("import") end)
  local how = UI.text(block, "dim")
  how:SetWidth(440)
  how:SetWordWrap(true)
  how:SetJustifyH("CENTER")
  how:SetPoint("TOP", go, "BOTTOM", 70, -20)
  how:SetText("You can also press Save in Advanced search to add the search you just ran, or make a list of a "
    .. "recipe's materials with Shopping list beside the profession window.")

  local nl = needs(UI.label(R, "LIST NAME"))
  nl:SetPoint("TOPLEFT", 12, -10)
  f.name = needs(UI.input(R, 220, 24, { max = 60 }))
  f.name:SetPoint("TOPLEFT", 12, -24)
  -- the name is kept when you press Enter or click elsewhere (New list puts you straight in here, and the next
  -- thing you do is type a search below); Escape puts the old name back
  local function saveName(self)
    local l = self.edbList   -- the list whose name was in the box, even when another one got picked meanwhile
    self.edbList = nil
    local newName = self:GetText():gsub("||", "|"):match("^%s*(.-)%s*$")
    local still = false
    for _, x in ipairs(lists()) do if x == l then still = true end end
    if still and newName ~= "" and newName ~= l.name then l.name = uniqueName(newName) end
  end
  f.name:HookScript("OnEditFocusGained", function(self) self.edbList = picked() end)
  f.name:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
  f.name:SetScript("OnEscapePressed", function(self)
    self.edbUndo = true
    self:ClearFocus()
  end)
  f.name:HookScript("OnEditFocusLost", function(self)
    if self.edbUndo then self.edbUndo = nil else saveName(self) end
    render()
  end)

  f.del = needs(UI.button(R, "Delete", 64, 24, "small danger"))
  f.del:SetPoint("TOPRIGHT", -12, -24)
  f.del:SetScript("OnClick", function()
    local l, i = picked()
    if not l then return end
    if not SH.deleteArmed then
      -- armed for 3 seconds; a timer from an earlier press doesn't disarm a newer one
      local armed = {}
      SH.deleteArmed = armed
      render()
      C_Timer.After(3, function() if SH.deleteArmed == armed then SH.deleteArmed = nil; render() end end)
      return
    end
    SH.deleteArmed = nil
    table.remove(lists(), i)
    SH.editing = nil
    setStatus("Deleted " .. plain(l.name) .. ".", T.dim)
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
  al:SetTextColor(unpack(PLACE))
  al:SetPoint("TOPLEFT", 12, -70)
  f.count = needs(UI.text(R, "mute"))
  f.count:SetPoint("TOPRIGHT", -12, -70)
  f.count:SetJustifyH("RIGHT")
  local addBtn = needs(UI.button(R, "Add", 56, 24))
  addBtn:SetPoint("TOPRIGHT", -12, -84)
  f.addBtn = addBtn
  f.add = needs(UI.input(R, 100, 24, { hint = "slot is trinket and price lt 5g sort by price", max = 400 }))
  f.add:SetPoint("TOPLEFT", 12, -84)
  f.add:SetPoint("RIGHT", addBtn, "LEFT", -6, 0)
  local function add()
    local l = picked()
    local q = f.add:GetText():gsub("||", "|"):match("^%s*(.-)%s*$")
    local done = SH.store(l, q, SH.editing)
    if not done then return end
    if done == "same" then
      setStatus("That search is already in the list.", T.dim)
    else
      setStatus(done == "saved" and "Search changed." or "Search added.", T.good)
    end
    SH.editing = nil
    f.add:SetText("")
    f.add:ClearFocus()
    render()
  end
  f.add:SetScript("OnEnterPressed", add)
  -- Escape, or emptying the box, stops changing a search: Add adds a new one again
  f.add:SetScript("OnEscapePressed", function(self)
    self:ClearFocus()
    if SH.editing then SH.editing = nil; self:SetText(""); render() end
  end)
  f.add:HookScript("OnTextChanged", function(self)
    if SH.editing and self:GetText() == "" then SH.editing = nil; render() end
  end)
  addBtn:SetScript("OnClick", add)

  local bd = needs(UI.headerBand(R, 20))
  bd:SetPoint("TOPLEFT", 1, -118)
  bd:SetPoint("TOPRIGHT", -1, -118)
  local ql = UI.label(bd, UI.hex(PLACE) .. "SEARCHES|r   click one to edit it in the box above")
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
  io.title:SetTextColor(unpack(PLACE))
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
  if ns.ahTitle then ns.ahTitle(nil) end
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
  if ns.ahTitle then ns.ahTitle("Shopping lists") end
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
    if have == q then ns.say(("already in %s."):format(plain(l.name))); return end
  end
  l.queries[#l.queries + 1] = q
  ns.say(("saved to %s (%d searches). The Shopping tab has your lists."):format(plain(l.name), #l.queries))
  render()
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("AUCTION_HOUSE_SHOW")
ev:RegisterEvent("AUCTION_HOUSE_CLOSED")
ev:SetScript("OnEvent", function(_, e)
  if e == "AUCTION_HOUSE_CLOSED" then
    closeShopping()   -- Blizzard's tab and title back for the next visit
    if SH.frame then SH.frame:Hide() end
    if SH.tab then pcall(PanelTemplates_DeselectTab, SH.tab) end
    return
  end
  -- after the Quick sell tab (made 0.2 s after the auction house opens)
  C_Timer.After(0.3, function()
    if not SH.tab and ns.makeTab then
      SH.tab = ns.makeTab("EverlookAuctionsShoppingTab", "Shopping", openShopping, closeShopping, "shopping")
    end
    makeFrame()
  end)
end)

ns.shoppingStore = SH.store   -- for tests/run.py

-- A list made elsewhere (the profession window's Shopping list) shows at once if the tab is open.
function ns.shoppingRefresh() render() end

local prevSlash, prevHelp = ns.slash, ns.help
function ns.slash(msg)
  if msg == "shop" or msg == "shopping" or msg == "lists" then
    if _G.AuctionHouseFrame and AuctionHouseFrame:IsShown() then openShopping() else ns.say("open the auction house first.") end
    return true
  end
  local listName = msg:match("^run%s+(.+)$")
  if msg == "run" then
    ns.say("which list? For example /eah run " .. plain(lists()[1] and lists()[1].name:lower() or "shopping list") .. ".")
    return true
  end
  if listName then
    if not (_G.AuctionHouseFrame and AuctionHouseFrame:IsShown()) then
      ns.say("open the auction house first, then /eah run " .. plain(listName) .. ".")
      return true
    end
    for _, l in ipairs(lists()) do
      if l.name:lower() == listName then runList(l); return true end
    end
    local names = {}
    for i, l in ipairs(lists()) do if i <= 5 then names[#names + 1] = plain(l.name:lower()) end end
    ns.say(("no list called \"%s\". %s"):format(plain(listName), #names > 0
      and ("Your lists: " .. table.concat(names, ", ") .. ". For example /eah run " .. names[1] .. ".")
      or "Make one in the auction house's Shopping tab with New."))
    return true
  end
  return prevSlash and prevSlash(msg) or false
end
function ns.help()
  if prevHelp then prevHelp() end
  print("  /eah shop  open the Shopping tab;  /eah run <list>  run a shopping list")
end
