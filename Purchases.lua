-- EverlookDB Auctions: AH purchases, a window of everything you bought at the auction house (/eah bought), open
-- anywhere, not only at the auction house.
--   Catching purchases: the game's buy calls are watched (hooksecurefunc, so purchases through Blizzard's window, our
--   Buy panel or another addon all count), and an entry is written only once the auction house says the purchase went
--   through. Commodities (cloth, herbs, bars): the quantity and the total price the auction house quoted. Other items:
--   the auction's buyout, one item. Bids are not logged (a bid you win arrives by mail later).
--   The window: newest first, a search box, Marked only. Click (or shift-click) an entry to mark it; shift-click with
--   the chat box open links the item instead. Under the list, a recipe (the one picked in your profession window, or
--   any you looked at before) with its cost per craft from what you paid for the marked entries; materials with no
--   marked entry use the lowest auction price, in grey.
--   The crafting box beside the profession window has a "Your buys" button that opens it on that recipe.
local _, ns = ...
local P = ns.purchaseLog
local UI = ns.UI
local B = {}

local W, PAD, ROW, ROWS = 520, 12, 18, 12
local DATE_W, QTY_W, EACH_W, TOTAL_W = 84, 40, 100, 100
local REC_ROWS = 8
local STALE = 24 * 3600

local QUIET = { 0.55, 0.55, 0.55 }
local WHITE = { 1, 1, 1 }
local GOOD = { 0.25, 1, 0.25 }
local BAD = { 1, 0.35, 0.35 }
local GOLD = { 1, 0.82, 0 }

local function try(fn, ...)
  if type(fn) ~= "function" then return nil end
  local okCall, a = pcall(fn, ...)
  if okCall then return a end
end
local function ok(v) return ns.ok and ns.ok(v) or v end

local function db() return ns.db and ns.db() end
local function list()
  local d = db()
  if not d then return {} end
  d.bought = d.bought or {}
  return d.bought
end
local function recipes()
  local d = db()
  if not d then return {} end
  d.recipes = d.recipes or {}
  return d.recipes
end

local function itemName(id)
  local name = try(C_Item.GetItemNameByID, id)
  if not name and C_Item.RequestLoadItemDataByID then pcall(C_Item.RequestLoadItemDataByID, id) end
  return name or ("item " .. id)
end
local function entryName(e) return (e.link and e.link:match("%[(.-)%]")) or itemName(e.id) end
local function qualityColor(id)
  local q = try(C_Item.GetItemQualityByID, id)
  local c = q and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q]
  if c then return c.r, c.g, c.b end
  return 1, 1, 1
end
local function priceOf(id)
  local it = ns.itemFor and ns.itemFor(id)
  return it and it[1], it and it[4]
end
local function money(c) return ns.money(c) end

---------------------------------------------------------------------------------------------------------------------
-- Catching purchases

local AH = C_AuctionHouse or {}
local seen = {}         -- auctionID -> { id, link, buyout } from the item search results the auction house sent
local pending = {}      -- auctionID -> the entry to write once the purchase goes through
local quote, buying     -- commodities: the last price quote, and the purchase waiting for its answer

local function houseKey() return ns.house and ns.house() end

local function readResults(itemKey)
  if type(itemKey) ~= "table" then return end
  local id = ok(itemKey.itemID)
  for i = 1, (try(AH.GetNumItemSearchResults, itemKey) or 0) do
    local r = try(AH.GetItemSearchResultInfo, itemKey, i)
    local aid = r and ok(r.auctionID)
    if aid and id then
      local link = ok(r.itemLink)
      seen[aid] = { id = id, link = link, buyout = ok(r.buyoutAmount) }
    end
  end
end

local function write(e)
  local d = db()
  if not d then return end
  e.t, e.h = time(), houseKey()
  if P.add(list(), e) and B.frame and B.frame:IsShown() then B.render() end
end

if AH.PlaceBid then
  hooksecurefunc(AH, "PlaceBid", function(auctionID, amount)
    auctionID, amount = ok(auctionID), ok(amount)
    local a = auctionID and seen[auctionID]
    if not a and auctionID and AH.GetAuctionInfoByID then
      local info = try(AH.GetAuctionInfoByID, auctionID)
      local key = info and ok(info.itemKey)
      if key and ok(key.itemID) then
        a = { id = ok(key.itemID), link = ok(info.itemLink), buyout = ok(info.buyoutAmount) }
      end
    end
    -- a buyout only: a bid below the buyout may never win
    if a and amount and a.buyout and amount >= a.buyout then
      pending[auctionID] = { id = a.id, q = 1, c = amount, link = a.link }
    end
  end)
end
if AH.StartCommoditiesPurchase then
  hooksecurefunc(AH, "StartCommoditiesPurchase", function(id, qty)
    quote = { id = ok(id), q = ok(qty) }
  end)
end
if AH.ConfirmCommoditiesPurchase then
  hooksecurefunc(AH, "ConfirmCommoditiesPurchase", function(id, qty)
    id, qty = ok(id), ok(qty)
    if quote and quote.id == id and quote.total and (qty == nil or qty == quote.q) then
      buying = { id = id, q = quote.q, c = quote.total }
    end
  end)
end

local ev = CreateFrame("Frame")
for _, e in ipairs({ "ITEM_SEARCH_RESULTS_UPDATED", "ITEM_SEARCH_RESULTS_ADDED", "COMMODITY_PRICE_UPDATED",
    "COMMODITY_PURCHASE_SUCCEEDED", "COMMODITY_PURCHASE_FAILED", "AUCTION_HOUSE_PURCHASE_COMPLETED",
    "AUCTION_HOUSE_CLOSED", "GET_ITEM_INFO_RECEIVED" }) do
  pcall(ev.RegisterEvent, ev, e)
end
local soon
ev:SetScript("OnEvent", function(_, e, a1, a2)
  if e == "ITEM_SEARCH_RESULTS_UPDATED" or e == "ITEM_SEARCH_RESULTS_ADDED" then
    readResults(a1)
  elseif e == "COMMODITY_PRICE_UPDATED" then
    local total = ok(a2)
    if quote and type(total) == "number" and total > 0 then quote.total = total end
  elseif e == "COMMODITY_PURCHASE_SUCCEEDED" then
    if buying then write(buying) end
    buying, quote = nil, nil
  elseif e == "COMMODITY_PURCHASE_FAILED" then
    buying, quote = nil, nil
  elseif e == "AUCTION_HOUSE_PURCHASE_COMPLETED" then
    local aid = ok(a1)
    local p = aid and pending[aid]
    if p then
      pending[aid] = nil
      write(p)
    end
  elseif e == "AUCTION_HOUSE_CLOSED" then
    seen, pending, quote, buying = {}, {}, nil, nil
  elseif e == "GET_ITEM_INFO_RECEIVED" then
    if B.frame and B.frame:IsShown() and not soon then
      soon = true
      C_Timer.After(0.3, function() soon = nil; B.render() end)
    end
  end
end)

---------------------------------------------------------------------------------------------------------------------
-- The window

local function text(parent, font, justify)
  local fs = parent:CreateFontString(nil, "OVERLAY")
  if _G[font] then fs:SetFontObject(font) else fs:SetFontObject(GameFontHighlightSmall) end
  fs:SetJustifyH(justify or "LEFT")
  fs:SetWordWrap(false)
  return fs
end
local function divider(parent)
  local t = parent:CreateTexture(nil, "ARTWORK")
  t:SetHeight(1)
  t:SetColorTexture(1, 1, 1, 0.12)
  return t
end
local function setMoney(fs, copper, color)
  fs:SetText((copper < 0 and "-" or "") .. money(math.abs(copper)))
  fs:SetTextColor(unpack(color or WHITE))
end
local function quiet(fs, msg)
  fs:SetText(msg)
  fs:SetTextColor(unpack(QUIET))
end
local function tipFor(owner, title, line)
  owner:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(title, 1, 1, 1)
    GameTooltip:AddLine(line, nil, nil, nil, true)
    GameTooltip:Show()
  end)
  owner:SetScript("OnLeave", function() GameTooltip:Hide() end)
end
local function button(parent, label, width, onClick)
  local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  b:SetSize(width, 22)
  b:SetText(label)
  b:SetScript("OnClick", onClick)
  return b
end

local function chatOpen()
  local eb = ChatEdit_GetActiveWindow and ChatEdit_GetActiveWindow()
  return eb ~= nil
end

local function toggleMark(e)
  e.m = not e.m or nil
  B.render()
end

local function makeRow(f)
  local row = CreateFrame("Button", nil, f)
  row:SetHeight(ROW)
  row:RegisterForClicks("LeftButtonUp")
  row.bg = row:CreateTexture(nil, "BACKGROUND")
  row.bg:SetPoint("TOPLEFT", -4, 0)
  row.bg:SetPoint("BOTTOMRIGHT", 4, 0)
  row.bg:SetColorTexture(1, 0.82, 0, 0.16)
  row.check = row:CreateTexture(nil, "ARTWORK")
  row.check:SetSize(14, 14)
  row.check:SetPoint("LEFT", -2, 0)
  row.check:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
  row.date = text(row, "GameFontDisableSmall")
  row.date:SetPoint("LEFT", 14, 0)
  row.date:SetWidth(DATE_W - 14)
  row.total = text(row, "GameFontHighlightSmall", "RIGHT")
  row.total:SetPoint("RIGHT", 0, 0)
  row.total:SetWidth(TOTAL_W)
  row.each = text(row, "GameFontHighlightSmall", "RIGHT")
  row.each:SetPoint("RIGHT", row.total, "LEFT", -6, 0)
  row.each:SetWidth(EACH_W)
  row.qty = text(row, "GameFontHighlightSmall", "RIGHT")
  row.qty:SetPoint("RIGHT", row.each, "LEFT", -6, 0)
  row.qty:SetWidth(QTY_W)
  row.icon = row:CreateTexture(nil, "ARTWORK")
  row.icon:SetSize(14, 14)
  row.icon:SetPoint("LEFT", DATE_W, 0)
  row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  row.name = text(row, "GameFontHighlightSmall")
  row.name:SetPoint("LEFT", row.icon, "RIGHT", 5, 0)
  row.name:SetPoint("RIGHT", row.qty, "LEFT", -6, 0)
  local hl = row:CreateTexture(nil, "HIGHLIGHT")
  hl:SetPoint("TOPLEFT", -4, 0)
  hl:SetPoint("BOTTOMRIGHT", 4, 0)
  hl:SetColorTexture(1, 1, 1, 0.06)
  row:SetScript("OnClick", function(self)
    local e = self.entry
    if not e then return end
    if IsShiftKeyDown() and chatOpen() then
      local link = e.link
      if not link then
        local okInfo, _, l = pcall(C_Item.GetItemInfo, e.id)
        link = okInfo and l or nil
      end
      if link and ChatEdit_InsertLink then ChatEdit_InsertLink(link) end
      return
    end
    toggleMark(e)
  end)
  row:SetScript("OnEnter", function(self)
    local e = self.entry
    if not e then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    if e.link then pcall(GameTooltip.SetHyperlink, GameTooltip, e.link) else pcall(GameTooltip.SetItemByID, GameTooltip, e.id) end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(("Bought %s: %d for %s"):format(date("%d %b %Y %H:%M", e.t), e.q, money(e.c)), 1, 0.82, 0)
    GameTooltip:AddLine(e.m and "Marked. Click to unmark." or "Click to mark it for the recipe below.", 0.6, 0.6, 0.6)
    GameTooltip:Show()
  end)
  row:SetScript("OnLeave", function() GameTooltip:Hide() end)
  return row
end

local function makeMatRow(f)
  local row = CreateFrame("Frame", nil, f)
  row:SetHeight(ROW)
  row:EnableMouse(true)
  row.icon = row:CreateTexture(nil, "ARTWORK")
  row.icon:SetSize(14, 14)
  row.icon:SetPoint("LEFT", 0, 0)
  row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  row.cost = text(row, "GameFontHighlightSmall", "RIGHT")
  row.cost:SetPoint("RIGHT", 0, 0)
  row.cost:SetWidth(TOTAL_W)
  row.src = text(row, "GameFontDisableSmall", "RIGHT")
  row.src:SetPoint("RIGHT", row.cost, "LEFT", -6, 0)
  row.src:SetWidth(200)
  row.name = text(row, "GameFontHighlightSmall")
  row.name:SetPoint("LEFT", row.icon, "RIGHT", 5, 0)
  row.name:SetPoint("RIGHT", row.src, "LEFT", -6, 0)
  row:SetScript("OnEnter", function(self)
    if not self.id then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    pcall(GameTooltip.SetItemByID, GameTooltip, self.id)
    GameTooltip:Show()
  end)
  row:SetScript("OnLeave", function() GameTooltip:Hide() end)
  return row
end

local function makeLine(f)
  local line = CreateFrame("Frame", nil, f)
  line:SetHeight(ROW)
  line.label = text(line, "GameFontNormalSmall")
  line.label:SetPoint("LEFT", 0, 0)
  line.value = text(line, "GameFontHighlightSmall", "RIGHT")
  line.value:SetPoint("RIGHT", 0, 0)
  line.label:SetPoint("RIGHT", line.value, "LEFT", -8, 0)
  return line
end

-- the recipe picker: the recipes you looked at in a profession window, newest first
local function openPicker(anchor)
  local f = B.frame
  local m = B.picker
  if not m then
    m = CreateFrame("Frame", nil, f, "TooltipBackdropTemplate")
    m:SetFrameLevel(f:GetFrameLevel() + 30)
    m:EnableMouse(true)
    m.items = {}
    B.picker = m
  end
  if m:IsShown() then m:Hide(); return end
  local rs = recipes()
  for i = 1, math.max(#rs, #m.items) do
    local r, b = rs[i], m.items[i]
    if r then
      if not b then
        b = CreateFrame("Button", nil, m)
        b:SetHeight(18)
        b.label = text(b, "GameFontHighlightSmall")
        b.label:SetPoint("LEFT", 4, 0)
        b.label:SetPoint("RIGHT", -4, 0)
        local hl = b:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(1, 1, 1, 0.08)
        m.items[i] = b
      end
      b:ClearAllPoints()
      b:SetPoint("TOPLEFT", 8, -8 - (i - 1) * 18)
      b:SetPoint("RIGHT", -8, 0)
      b.label:SetText(r.name or ("recipe " .. r.id))
      b:SetScript("OnClick", function()
        local d = db()
        if d then d.boughtRecipe = r.id end
        m:Hide()
        B.render()
      end)
      b:Show()
    elseif b then
      b:Hide()
    end
  end
  m:SetSize(260, 16 + math.max(1, #rs) * 18)
  m:ClearAllPoints()
  m:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -2)
  m:Show()
end

local function makeFrame()
  if B.frame then return B.frame end
  local f = CreateFrame("Frame", "EverlookAuctionsPurchases", UIParent, "TooltipBackdropTemplate")
  UI.own(f)
  f:SetWidth(W)
  f:SetFrameStrata("HIGH")
  f:SetToplevel(true)
  f:SetClampedToScreen(true)
  f:EnableMouse(true)
  f:SetMovable(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local d = db()
    if d then
      local p, _, rp, x, y = self:GetPoint()
      d.boughtPos = { p, rp, x, y }
    end
  end)
  f:EnableMouseWheel(true)
  f:SetScript("OnMouseWheel", function(_, delta)
    B.offset = math.max(0, (B.offset or 0) - delta * 3)
    B.render()
  end)
  tinsert(UISpecialFrames, "EverlookAuctionsPurchases")   -- Escape closes it

  f.title = text(f, "GameFontNormal")
  f.title:SetPoint("TOPLEFT", PAD, -PAD)
  f.title:SetText("AH purchases")
  f.sub = text(f, "GameFontDisableSmall")
  f.sub:SetPoint("LEFT", f.title, "RIGHT", 10, 0)
  f.sub:SetText("click the ones you used to mark them")
  local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
  close:SetSize(24, 24)
  close:SetPoint("TOPRIGHT", -2, -2)
  close:SetScript("OnClick", function() f:Hide() end)

  -- search, marked only, clear marks
  f.search = CreateFrame("EditBox", nil, f, "SearchBoxTemplate")
  f.search:SetSize(170, 20)
  f.search:SetPoint("TOPLEFT", PAD + 6, -PAD - 22)
  f.search:SetAutoFocus(false)
  f.search:HookScript("OnTextChanged", function(self)
    B.filter = self:GetText() or ""
    B.offset = 0
    B.render()
  end)
  f.marked = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
  f.marked:SetSize(22, 22)
  f.marked:SetPoint("LEFT", f.search, "RIGHT", 10, 0)
  f.marked:SetScript("OnClick", function(self)
    B.markedOnly = self:GetChecked() and true or false
    B.offset = 0
    B.render()
  end)
  local ml = text(f, "GameFontHighlightSmall")
  ml:SetPoint("LEFT", f.marked, "RIGHT", 2, 0)
  ml:SetText("Marked only")
  f.clear = button(f, "Clear marks", 100, function()
    for _, e in ipairs(list()) do e.m = nil end
    B.render()
  end)
  f.clear:SetPoint("TOPRIGHT", -PAD, -PAD - 21)

  -- column heads
  local y = -PAD - 50
  local head = CreateFrame("Frame", nil, f)
  head:SetHeight(14)
  head:SetPoint("TOPLEFT", PAD, y)
  head:SetPoint("RIGHT", -PAD, 0)
  local function col(label, right, width, justify)
    local h = text(head, "GameFontDisableSmall", justify or "RIGHT")
    h:SetText(label)
    h:SetPoint("RIGHT", right, 0)
    h:SetWidth(width)
  end
  col("Total", 0, TOTAL_W)
  col("Each", -(TOTAL_W + 6), EACH_W)
  col("Qty", -(TOTAL_W + EACH_W + 12), QTY_W)
  local hd = text(head, "GameFontDisableSmall")
  hd:SetPoint("LEFT", 14, 0)
  hd:SetText("Bought")
  local hi = text(head, "GameFontDisableSmall")
  hi:SetPoint("LEFT", DATE_W, 0)
  hi:SetText("Item")
  y = y - 16

  f.rows = {}
  for i = 1, ROWS do
    local row = makeRow(f)
    row:SetPoint("TOPLEFT", PAD, y - (i - 1) * ROW)
    row:SetPoint("RIGHT", -PAD, 0)
    f.rows[i] = row
  end
  f.empty = text(f, "GameFontDisableSmall")
  f.empty:SetWordWrap(true)
  f.empty:SetPoint("TOPLEFT", PAD, y - 4)
  f.empty:SetPoint("RIGHT", -PAD, 0)
  y = y - ROWS * ROW - 4
  f.pos = text(f, "GameFontDisableSmall", "RIGHT")
  f.pos:SetPoint("TOPRIGHT", -PAD, y)
  f.sum = text(f, "GameFontHighlightSmall")
  f.sum:SetPoint("TOPLEFT", PAD, y)
  y = y - 20

  f.mid = divider(f)
  f.mid:SetPoint("TOPLEFT", PAD, y)
  f.mid:SetPoint("TOPRIGHT", -PAD, y)
  y = y - 8

  -- the recipe
  local rl = text(f, "GameFontNormal")
  rl:SetPoint("TOPLEFT", PAD, y - 3)
  rl:SetText("Recipe")
  f.pick = button(f, "Pick a recipe", 300, function(self) openPicker(self) end)
  f.pick:SetPoint("TOPLEFT", PAD + 60, y)
  tipFor(f.pick, "Recipe", "The recipes you picked in a profession window. Open your profession window and pick one to add it.")
  f.recipeTop = y - 28
  f.mats, f.lines = {}, {}
  for i = 1, REC_ROWS do f.mats[i] = makeMatRow(f) end
  for i = 1, 4 do f.lines[i] = makeLine(f) end
  f.note = text(f, "GameFontDisableSmall")
  f.note:SetWordWrap(true)
  f.note:SetWidth(W - PAD * 2)

  local d = db()
  local pos = d and d.boughtPos
  if pos then f:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4]) else f:SetPoint("CENTER", 0, 60) end
  f:Hide()
  B.frame = f
  return f
end

local function renderList(f)
  local all = list()
  local shown = P.view(all, B.filter, B.markedOnly, entryName)
  local maxOff = math.max(0, #shown - ROWS)
  B.offset = math.min(B.offset or 0, maxOff)
  for i = 1, ROWS do
    local row = f.rows[i]
    local e = shown[i + B.offset]
    row.entry = e
    if e then
      row.check:SetShown(e.m == true)
      row.bg:SetShown(e.m == true)
      row.date:SetText(date("%d %b %H:%M", e.t))
      row.icon:SetTexture(try(C_Item.GetItemIconByID, e.id) or 134400)
      row.name:SetText(entryName(e))
      row.name:SetTextColor(qualityColor(e.id))
      row.qty:SetText(ns.num(e.q))
      setMoney(row.each, math.floor(e.c / e.q + 0.5))
      setMoney(row.total, e.c)
      row:Show()
    else
      row:Hide()
    end
  end
  f.empty:SetShown(#shown == 0)
  if #all == 0 then
    f.empty:SetText("Nothing bought yet. Every buyout from now on shows up here: from our Buy panel, Blizzard's auction house or another addon. Bids aren't logged.")
  elseif B.markedOnly then
    f.empty:SetText("Nothing marked" .. ((B.filter or "") ~= "" and " matches." or ". Untick Marked only and click the purchases you crafted with."))
  else
    f.empty:SetText("Nothing matches.")
  end
  f.pos:SetText(#shown > ROWS and ("%d-%d of %d · scroll for more"):format(B.offset + 1, math.min(#shown, B.offset + ROWS), #shown)
    or (#shown > 0 and ("%d purchases"):format(#shown) or ""))
  local n, q, c = P.markedTotal(all)
  if n > 0 then
    f.sum:SetText(("Marked: %d %s, %s items, %s"):format(n, n == 1 and "purchase" or "purchases", ns.num(q), money(c)))
    f.sum:SetTextColor(unpack(GOLD))
  else
    quiet(f.sum, "Nothing marked")
  end
  f.clear:SetEnabled(n > 0)
end

local function renderRecipe(f)
  local d = db() or {}
  local rs = recipes()
  local r = P.findRecipe(rs, d.boughtRecipe) or rs[1]
  local y = f.recipeTop
  f.pick:SetText(r and ((r.name or ("recipe " .. r.id))) or "Pick a recipe")
  f.pick:SetEnabled(#rs > 0)
  local c = r and P.cost(list(), r, priceOf)
  for i, row in ipairs(f.mats) do
    local m = c and c.mats[i]
    row:SetShown(m ~= nil)
    row.id = m and m.id
    if m then
      row:ClearAllPoints()
      row:SetPoint("TOPLEFT", PAD, y)
      row:SetPoint("RIGHT", -PAD, 0)
      row.icon:SetTexture(try(C_Item.GetItemIconByID, m.id) or 134400)
      row.name:SetText(("%s  x%s"):format(itemName(m.id), m.need))
      row.name:SetTextColor(qualityColor(m.id))
      if m.src == "paid" then
        row.src:SetText(("you paid %s each (%d marked)"):format(money(math.floor(m.unit + 0.5)), m.have))
        row.src:SetTextColor(unpack(GOLD))
        setMoney(row.cost, math.floor(m.unit * m.need + 0.5))
      elseif m.src == "ah" then
        quiet(row.src, "not marked: lowest AH price")
        setMoney(row.cost, math.floor(m.unit * m.need + 0.5), QUIET)
      else
        quiet(row.src, "not marked, no AH price")
        quiet(row.cost, "-")
      end
      y = y - ROW
    end
  end
  local lines = {}
  if c and #c.mats > 0 then
    y = y - 4
    lines[#lines + 1] = { "Cost per craft", c.total, c.paidAll and GOLD or WHITE }
    if c.crafts then lines[#lines + 1] = { "Your marked purchases cover", ("%d %s"):format(c.crafts, c.crafts == 1 and "craft" or "crafts") } end
    local each, at = r.out and priceOf(r.out)
    if each then
      local makes = r.makes or 1
      local value = math.floor(each * makes)
      lines[#lines + 1] = { makes > 1 and ("Sells for (makes %s)"):format(makes) or "Sells for", value,
        (at and time() - at >= STALE) and QUIET or nil }
      if c.unpriced == 0 then
        local cut = ns.ahCut and ns.ahCut() or 0.05
        local profit = math.floor(value * (1 - cut)) - c.total
        lines[#lines + 1] = { ("Profit after the %d%% AH cut"):format(cut * 100), profit, profit >= 0 and GOOD or BAD }
      end
    end
  end
  for i, line in ipairs(f.lines) do
    local l = lines[i]
    line:SetShown(l ~= nil)
    if l then
      line:ClearAllPoints()
      line:SetPoint("TOPLEFT", PAD, y)
      line:SetPoint("RIGHT", -PAD, 0)
      line.label:SetText(l[1])
      if type(l[2]) == "number" then setMoney(line.value, l[2], l[3]) else line.value:SetText(l[2]); line.value:SetTextColor(unpack(WHITE)) end
      y = y - ROW
    end
  end
  local note
  if not r then
    note = "Open your profession window and pick a recipe: it shows up here, with its cost from the purchases you marked."
  elseif c.unpriced > 0 then
    note = "A material with no marked purchase and no AH price isn't counted."
  elseif not c.paidAll then
    note = "Grey materials aren't from your marked purchases: they use the lowest AH price. Mark a purchase of them to use what you paid."
  end
  f.note:SetShown(note ~= nil)
  if note then
    f.note:ClearAllPoints()
    f.note:SetPoint("TOPLEFT", PAD, y - 4)
    f.note:SetText(note)
    y = y - 6 - math.max(12, f.note:GetStringHeight() or 12)
  end
  f:SetHeight(-(y - PAD))
end

function B.render()
  local f = B.frame
  if not (f and f:IsShown()) then return end
  renderList(f)
  renderRecipe(f)
end

function B.open(recipeID)
  local f = makeFrame()
  local d = db()
  if recipeID and d then d.boughtRecipe = recipeID end
  f:Show()
  B.render()
end

function B.toggle()
  local f = makeFrame()
  if f:IsShown() then f:Hide() else B.open() end
end

-- The crafting box tells us each recipe you pick, so the window can show it later without the profession window.
function B.noteRecipe(w, changed)
  local d = db()
  if not d then return end
  P.noteRecipe(recipes(), w)
  if changed then d.boughtRecipe = w.recipeID end
  if B.frame and B.frame:IsShown() then B.render() end
end

ns.purchases = B
