-- EverlookDB Auctions: crafting cost beside the profession window, and a shopping list from the recipe.
--   For the recipe you pick: each material with how many it takes and its lowest auction price, what the materials
--   cost together, what the result sells for (and what disenchanting it is worth, for gear), and the profit after
--   the auction house's 5% cut. Recipes come from the game itself (C_TradeSkillUI); prices are the saved ones for
--   your faction's auction house, so it works away from the auction house too. Nothing is crafted or bought here.
--   The box is drawn like the game's own tooltips and sits right of the profession window, clear of any tab buttons
--   along its right edge.
--   Shopping list (the button at the bottom of the box) opens a small panel under it: the recipe's materials with a
--   tick, how many you have and how many to buy. Create list saves the ticked ones as a list named after the recipe
--   in the Shopping tab (RecipeList.lua has the logic).
--   db.craft = false hides both (Options, General).
local _, ns = ...
local UI = ns.UI
local R = ns.recipeList
local C = {}

-- the price columns fit a 4-digit gold price with its silver and copper ("1,234g 56s 78c" with coin icons)
local W, PAD, ROW, GAP = 300, 10, 18, 2
local PRICE_W, COUNT_W = 112, 30
local LIST_W, LIST_ROW, LIST_MAX = 320, 22, 10
local LIST_PRICE_W = 104
local STALE = 24 * 3600   -- older prices show grey, as in the tooltips

local QUIET = { 0.5, 0.5, 0.5 }
local WHITE = { 1, 1, 1 }
local GOOD = { 0.25, 1, 0.25 }
local BAD = { 1, 0.35, 0.35 }

local function try(fn, ...)
  if type(fn) ~= "function" then return nil end
  local okCall, a = pcall(fn, ...)
  if okCall then return a end
end

local function enabled()
  local db = ns.db and ns.db()
  return db and db.craft ~= false
end

-- The saved lowest price and when it was seen (nil when unknown).
local function priceOf(id)
  local it = ns.itemFor and ns.itemFor(id)
  return it and it[1], it and it[4]
end

-- Whether a price seen at `at` is over a day old.
local function stale(at) return at ~= nil and time() - at >= STALE end

local function nameOf(id)
  local name = try(C_Item.GetItemNameByID, id)
  if not name and C_Item.RequestLoadItemDataByID then pcall(C_Item.RequestLoadItemDataByID, id) end
  return name or ("item " .. id)
end

local function qualityColor(id)
  local q = try(C_Item.GetItemQualityByID, id)
  local c = q and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q]
  if c then return c.r, c.g, c.b end
  return 1, 1, 1
end

-- bags and bank
local function haveOf(id)
  return try(C_Item.GetItemCount, id, true, false, true) or 0
end

-- The game's own fonts, with the addon's as a fallback.
local function text(parent, font, justify)
  local fs = parent:CreateFontString(nil, "OVERLAY")
  if _G[font] then fs:SetFontObject(font) else fs:SetFontObject(UI.fontObject("small")) end
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

-- A frame in the game's tooltip style (dark fill, the standard tooltip border).
local function tooltipFrame(name, parent)
  local okMade, f = pcall(CreateFrame, "Frame", name, parent, "TooltipBackdropTemplate")
  if okMade and f then return f end
  f = CreateFrame("Frame", name, parent, "BackdropTemplate")
  if f.SetBackdrop and BACKDROP_TOOLTIP_16_16_5555 then
    f:SetBackdrop(BACKDROP_TOOLTIP_16_16_5555)
    f:SetBackdropColor(0.06, 0.06, 0.08, 0.95)
  end
  return f
end

local function quiet(fs, msg)
  fs:SetText(msg)
  fs:SetTextColor(unpack(QUIET))
end

local function setMoney(fs, copper, color)
  fs:SetText((copper < 0 and "-" or "") .. ns.money(math.abs(copper)))
  fs:SetTextColor(unpack(color or WHITE))
end

---------------------------------------------------------------------------------------------------------------------
-- What the picked recipe costs and makes

-- { recipeID, name, mats = { { id, need, price } }, cost, unpriced, out, each, makes, de }
local function work(info)
  local sc = C_TradeSkillUI and try(C_TradeSkillUI.GetRecipeSchematic, info.recipeID, false)
  if not sc then return nil end
  local w = { recipeID = info.recipeID, name = info.name or sc.name, mats = {}, cost = 0, unpriced = 0 }
  for _, slot in ipairs(sc.reagentSlotSchematics or {}) do
    local r = slot.reagents and slot.reagents[1]
    local need = ns.ok(slot.quantityRequired) or 0
    if r and r.itemID and need > 0 and not slot.hiddenInCraftingForm then
      local p, at = priceOf(r.itemID)
      w.mats[#w.mats + 1] = { r.itemID, need, p, at }
      if p then w.cost = w.cost + p * need else w.unpriced = w.unpriced + 1 end
      if p and at and (not w.oldest or at < w.oldest) then w.oldest = at end
    end
  end
  w.out = ns.ok(sc.outputItemID)
  w.makes = ((sc.quantityMin or 1) + (sc.quantityMax or sc.quantityMin or 1)) / 2
  if w.out then
    local at
    w.each, at = priceOf(w.out)
    w.eachAt = at
    if w.each and at and (not w.oldest or at < w.oldest) then w.oldest = at end
    w.de = ns.disenchantValue and ns.disenchantValue(w.out)
  end
  return w
end

local function pickedRecipe()
  local form = ProfessionsFrame and ProfessionsFrame.CraftingPage and ProfessionsFrame.CraftingPage.SchematicForm
  local info = form and form.GetRecipeInfo and try(form.GetRecipeInfo, form)
  return info and info.recipeID and info
end

---------------------------------------------------------------------------------------------------------------------
-- Where the box goes: right of the profession window, past any small buttons (tabs) along its right edge.

local function tabsEdge(pf)
  local edge = pf:GetRight()
  local top, bottom = pf:GetTop(), pf:GetBottom()
  if not (edge and top and bottom) then return 0 end
  local scale = pf:GetEffectiveScale()
  local found, seen = {}, 0
  local function look(f)
    if f.IsForbidden and f:IsForbidden() then return false end
    if not f:IsShown() then return false end
    local l, r, t, b = f:GetLeft(), f:GetRight(), f:GetTop(), f:GetBottom()
    if l and r and t and b then
      local k = f:GetEffectiveScale() / scale
      l, r, t, b = l * k, r * k, t * k, b * k
      -- small, near the right edge, beside the window
      if r > edge + 2 and l > edge - 60 and (r - l) <= 90 and t <= top + 40 and b >= bottom - 40 then
        found[#found + 1] = { l, r }
      end
    end
    return true
  end
  local function collect(f, depth)
    if seen > 3000 or f == C.frame or f == C.list then return end
    seen = seen + 1
    local okLook, shown = pcall(look, f)
    if okLook and shown and depth > 0 then
      for _, child in ipairs({ f:GetChildren() }) do collect(child, depth - 1) end
    end
  end
  collect(pf, 3)
  for _, child in ipairs({ UIParent:GetChildren() }) do
    if child ~= pf then collect(child, 0) end
  end
  -- chain: each button that starts at (or just past) the edge so far pushes it out
  local best, grew = edge, true
  while grew do
    grew = false
    for _, s in ipairs(found) do
      if s[2] > best and s[1] <= best + 6 then best, grew = s[2], true end
    end
  end
  return best - edge
end

local function place(f, pf)
  local clear = tabsEdge(pf)
  C.clear = clear
  f:ClearAllPoints()
  f:SetPoint("TOPLEFT", pf, "TOPRIGHT", clear + 4, -24)
end

---------------------------------------------------------------------------------------------------------------------
-- The crafting box

local function makeRow(f)
  local row = CreateFrame("Button", nil, f)
  row:SetHeight(ROW)
  row.icon = row:CreateTexture(nil, "ARTWORK")
  row.icon:SetSize(14, 14)
  row.icon:SetPoint("LEFT", 0, 0)
  row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  row.price = text(row, "GameFontHighlightSmall", "RIGHT")
  row.price:SetPoint("RIGHT", 0, 0)
  row.price:SetWidth(PRICE_W)
  row.count = text(row, "GameFontDisableSmall", "RIGHT")
  row.count:SetPoint("RIGHT", row.price, "LEFT", -6, 0)
  row.count:SetWidth(COUNT_W)
  row.name = text(row, "GameFontHighlightSmall")
  row.name:SetPoint("LEFT", row.icon, "RIGHT", 5, 0)
  row.name:SetPoint("RIGHT", row.count, "LEFT", -4, 0)
  local hl = row:CreateTexture(nil, "HIGHLIGHT")
  hl:SetPoint("TOPLEFT", -4, 0)
  hl:SetPoint("BOTTOMRIGHT", 4, 0)
  hl:SetColorTexture(1, 1, 1, 0.06)
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

local openList, refreshList

local function makeFrame()
  local pf = _G.ProfessionsFrame
  if C.frame or not pf then return C.frame end
  local f = UI.own(tooltipFrame("EverlookAuctionsCrafting", pf))
  f:SetWidth(W)
  f:SetFrameStrata(pf:GetFrameStrata())
  f:SetFrameLevel(pf:GetFrameLevel() + 20)
  f:EnableMouse(true)

  f.title = text(f, "GameFontNormal")
  f.title:SetPoint("TOPLEFT", PAD, -PAD)
  f.title:SetText("Crafting cost")
  f.sub = text(f, "GameFontDisableSmall", "RIGHT")
  f.sub:SetPoint("TOPRIGHT", -PAD, -PAD - 1)
  f.sub:SetText("lowest AH price")
  f.top = divider(f)
  f.top:SetPoint("TOPLEFT", PAD, -PAD - 18)
  f.top:SetPoint("TOPRIGHT", -PAD, -PAD - 18)

  f.rows, f.lines = {}, {}
  f.mid = divider(f)
  for k = 1, 4 do f.lines[k] = makeLine(f) end
  f.note = text(f, "GameFontDisableSmall")
  f.note:SetWordWrap(true)
  f.note:SetWidth(W - PAD * 2)

  f.shop = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  f.shop:SetSize(120, 22)
  f.shop:SetText("Shopping list")
  f.shop:SetScript("OnClick", function()
    if C.list and C.list:IsShown() then C.list:Hide() else openList() end
  end)
  f.shop:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText("Shopping list", 1, 1, 1)
    GameTooltip:AddLine("Pick the materials to buy and save them as a list in the auction house's Shopping tab.",
      nil, nil, nil, true)
    GameTooltip:Show()
  end)
  f.shop:SetScript("OnLeave", function() GameTooltip:Hide() end)
  f:Hide()
  C.frame = f
  return f
end

local function render()
  local f = C.frame
  if not f then return end
  local info = enabled() and pickedRecipe()
  local w = info and work(info)
  if not w or #w.mats == 0 then
    f:Hide()
    if C.list then C.list:Hide() end
    return
  end
  local changed = not C.work or C.work.recipeID ~= w.recipeID
  C.work = w
  place(f, ProfessionsFrame)

  -- how old the prices are: the oldest one used (a price over a day old is grey)
  if w.oldest and ns.ago then
    f.sub:SetText("AH prices, oldest " .. ns.ago(w.oldest))
    f.sub:SetTextColor(unpack(stale(w.oldest) and BAD or QUIET))
  else
    f.sub:SetText("lowest AH price")
    f.sub:SetTextColor(unpack(QUIET))
  end

  -- materials: icon and name, how many, what they cost
  local y = -PAD - 24
  for i, m in ipairs(w.mats) do
    local row = f.rows[i] or makeRow(f)
    f.rows[i] = row
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", PAD, y)
    row:SetPoint("RIGHT", -PAD, 0)
    row.id = m[1]
    row.icon:SetTexture(try(C_Item.GetItemIconByID, m[1]) or 134400)
    row.name:SetText(nameOf(m[1]))
    row.name:SetTextColor(qualityColor(m[1]))
    row.count:SetText("x" .. m[2])
    if m[3] then setMoney(row.price, m[3] * m[2], stale(m[4]) and QUIET or nil) else quiet(row.price, "no AH price") end
    row:Show()
    y = y - ROW - GAP
  end
  for i = #w.mats + 1, #f.rows do f.rows[i]:Hide() end

  y = y - 4
  f.mid:ClearAllPoints()
  f.mid:SetPoint("TOPLEFT", PAD, y)
  f.mid:SetPoint("TOPRIGHT", -PAD, y)
  y = y - 6

  -- totals: only the lines there is something to say on
  local value = w.each and math.floor(w.each * w.makes)
  local lines = {}
  if w.unpriced < #w.mats then
    lines[#lines + 1] = { "Materials", w.cost, w.unpriced > 0 and QUIET or nil }
  end
  if w.out then
    lines[#lines + 1] = { w.makes > 1 and ("Sells for (makes %s)"):format(w.makes) or "Sells for", value,
      stale(w.eachAt) and QUIET or nil }
    if w.de then lines[#lines + 1] = { "Disenchant (estimate)", w.de } end
    if value and w.unpriced == 0 then
      local profit = math.floor(value * 0.95) - w.cost
      lines[#lines + 1] = { "Profit after the 5% AH cut", profit, profit >= 0 and GOOD or BAD }
    end
  end
  for k, line in ipairs(f.lines) do
    local l = lines[k]
    line:SetShown(l ~= nil)
    if l then
      line:ClearAllPoints()
      line:SetPoint("TOPLEFT", PAD, y)
      line:SetPoint("RIGHT", -PAD, 0)
      line.label:SetText(l[1])
      if l[2] then setMoney(line.value, l[2], l[3]) else quiet(line.value, "no AH price") end
      y = y - ROW
    end
  end

  -- one quiet note for what is missing
  local note
  if w.unpriced > 0 then
    note = w.unpriced == 1 and "1 material has no AH price yet, so it isn't counted."
      or ("%d materials have no AH price yet, so they aren't counted."):format(w.unpriced)
  elseif w.out and not value then
    note = "Profit shows once the result has an AH price."
  end
  f.note:SetShown(note ~= nil)
  if note then
    f.note:ClearAllPoints()
    f.note:SetPoint("TOPLEFT", PAD, y - 4)
    f.note:SetText(note)
    y = y - 4 - math.max(12, f.note:GetStringHeight() or 12)
  end

  y = y - 8
  f.shop:ClearAllPoints()
  f.shop:SetPoint("TOPLEFT", PAD - 2, y)
  y = y - 22 - PAD
  f:SetHeight(-y)
  f:Show()
  -- a new recipe starts the shopping list over; the same one keeps your ticks and amounts
  if changed and C.list and C.list:IsShown() then refreshList() end
end

---------------------------------------------------------------------------------------------------------------------
-- The shopping list panel, under the box

local function listTotal()
  local L = C.list
  local sum, unpriced = R.total(C.rows)
  if sum == 0 and unpriced > 0 then quiet(L.total, "no AH price") else setMoney(L.total, sum) end
  L.totalNote:SetText(unpriced > 0 and sum > 0 and ("+ %d without a price"):format(unpriced) or "")
end

local function makeListRow(L)
  local row = CreateFrame("Frame", nil, L)
  row:SetHeight(LIST_ROW)
  row.check = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
  row.check:SetSize(22, 22)
  row.check:SetPoint("LEFT", -4, 0)
  row.check:SetScript("OnClick", function(self)
    if row.data then row.data.tick = self:GetChecked() and true or false end
    listTotal()
  end)
  row.price = text(row, "GameFontHighlightSmall", "RIGHT")
  row.price:SetPoint("RIGHT", 0, 0)
  row.price:SetWidth(LIST_PRICE_W)
  row.buy = CreateFrame("EditBox", nil, row, "InputBoxTemplate")
  row.buy:SetSize(34, 18)
  row.buy:SetPoint("RIGHT", row.price, "LEFT", -10, 0)
  row.buy:SetAutoFocus(false)
  row.buy:SetNumeric(true)
  row.buy:SetMaxLetters(4)
  row.buy:SetJustifyH("RIGHT")
  row.buy:SetScript("OnTextChanged", function(self, user)
    if not user or not row.data then return end
    row.data.buy = tonumber(self:GetText()) or 0
    row.data.typed = true   -- your amount: a bag change leaves it alone
    if row.data.buy > 0 and not row.data.tick then
      row.data.tick = true
      row.check:SetChecked(true)
    end
    listTotal()
  end)
  row.buy:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
  row.have = text(row, "GameFontDisableSmall", "RIGHT")
  row.have:SetPoint("RIGHT", row.buy, "LEFT", -10, 0)
  row.have:SetWidth(44)
  row.name = text(row, "GameFontHighlightSmall")
  row.name:SetPoint("LEFT", row.check, "RIGHT", 2, 0)
  row.name:SetPoint("RIGHT", row.have, "LEFT", -4, 0)
  row:EnableMouse(true)
  row:SetScript("OnEnter", function(self)
    if not self.data then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    pcall(GameTooltip.SetItemByID, GameTooltip, self.data.id)
    GameTooltip:Show()
  end)
  row:SetScript("OnLeave", function() GameTooltip:Hide() end)
  return row
end

function refreshList()
  local L, w = C.list, C.work
  if not L or not w then return end
  local crafts = tonumber(L.crafts:GetText()) or 1
  C.rows = R.rows(w.mats, crafts, haveOf, nameOf)
  L.recipe:SetText(w.name or "")
  L.status:SetText("")
  local y = -PAD - 64
  L.head:ClearAllPoints()
  L.head:SetPoint("TOPLEFT", PAD, y + 16)
  L.head:SetPoint("RIGHT", -PAD, 0)
  for i = 1, math.max(#C.rows, #L.rows) do
    local d = C.rows[i]
    local row = L.rows[i]
    if d and i <= LIST_MAX then
      row = row or makeListRow(L)
      L.rows[i] = row
      row.data = d
      row:ClearAllPoints()
      row:SetPoint("TOPLEFT", PAD, y)
      row:SetPoint("RIGHT", -PAD, 0)
      row.check:SetChecked(d.tick)
      row.name:SetText(d.name)
      row.name:SetTextColor(qualityColor(d.id))
      row.have:SetText(("%d/%d"):format(d.have, d.need))
      row.have:SetTextColor(unpack(d.have >= d.need and GOOD or QUIET))
      row.buy:SetText(tostring(d.buy))
      if d.price then setMoney(row.price, d.price, stale(d.at) and QUIET or nil) else quiet(row.price, "no AH price") end
      row:Show()
      y = y - LIST_ROW
    elseif row then
      row:Hide()
      row.data = nil
    end
  end
  y = y - 6
  L.mid:ClearAllPoints()
  L.mid:SetPoint("TOPLEFT", PAD, y)
  L.mid:SetPoint("TOPRIGHT", -PAD, y)
  L.totalLabel:ClearAllPoints()
  L.totalLabel:SetPoint("TOPLEFT", PAD, y - 8)
  listTotal()
  y = y - 30
  L.create:ClearAllPoints()
  L.create:SetPoint("TOPRIGHT", -PAD + 2, y)
  L.status:ClearAllPoints()
  L.status:SetPoint("TOPLEFT", PAD, y - 28)
  L.status:SetPoint("RIGHT", -PAD, 0)
  L:SetHeight(-(y - 28 - 26 - PAD))
end

local function createList()
  local db = ns.db and ns.db()
  local L = C.list
  if not db or not C.rows or not C.work then return end
  -- the searches use item names: wait until the game has them all
  for _, d in ipairs(C.rows) do
    d.name = nameOf(d.id)
    if d.tick and d.name == "item " .. d.id then
      L.status:SetText("Item names are still loading. Try again in a moment.")
      L.status:SetTextColor(unpack(BAD))
      return
    end
  end
  db.lists = db.lists or {}
  local l, new, i = R.save(db.lists, C.work.name, C.rows)
  if not l then
    L.status:SetText("Tick at least one item with something to buy.")
    L.status:SetTextColor(unpack(BAD))
    return
  end
  db.listSel = i
  L.status:SetText(("%s \"%s\" in the auction house's Shopping tab, %d items."):format(new and "Saved as" or "Updated",
    l.name, #l.queries))
  L.status:SetTextColor(unpack(GOOD))
  if ns.shoppingRefresh then ns.shoppingRefresh() end
end

local function makeList()
  if C.list then return C.list end
  local f = C.frame
  local L = UI.own(tooltipFrame("EverlookAuctionsRecipeList", f))
  L:SetWidth(LIST_W)
  L:SetPoint("TOPLEFT", f, "BOTTOMLEFT", 0, -4)
  L:SetFrameLevel(f:GetFrameLevel() + 2)
  L:EnableMouse(true)
  L.rows = {}

  L.title = text(L, "GameFontNormal")
  L.title:SetPoint("TOPLEFT", PAD, -PAD)
  L.title:SetText("Shopping list")
  local close = CreateFrame("Button", nil, L, "UIPanelCloseButton")
  close:SetSize(24, 24)
  close:SetPoint("TOPRIGHT", -2, -2)
  close:SetScript("OnClick", function() L:Hide() end)
  L.recipe = text(L, "GameFontHighlight")
  L.recipe:SetPoint("TOPLEFT", PAD, -PAD - 20)
  L.recipe:SetPoint("RIGHT", -96, 0)

  L.crafts = CreateFrame("EditBox", nil, L, "InputBoxTemplate")
  L.crafts:SetSize(30, 18)
  L.crafts:SetPoint("TOPRIGHT", -PAD - 2, -PAD - 18)
  L.crafts:SetAutoFocus(false)
  L.crafts:SetNumeric(true)
  L.crafts:SetMaxLetters(3)
  L.crafts:SetJustifyH("RIGHT")
  L.crafts:SetText("1")
  L.crafts:SetScript("OnTextChanged", function(_, user) if user then refreshList() end end)
  L.crafts:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
  L.crafts:SetScript("OnEditFocusLost", function(self)
    if (tonumber(self:GetText()) or 0) < 1 then self:SetText("1"); refreshList() end
  end)
  local cl = text(L, "GameFontNormalSmall", "RIGHT")
  cl:SetText("Crafts")
  cl:SetPoint("RIGHT", L.crafts, "LEFT", -8, 0)

  -- column heads, lined up with the rows' columns
  L.head = CreateFrame("Frame", nil, L)
  L.head:SetHeight(14)
  local function head(label, right, width)
    local h = text(L.head, "GameFontDisableSmall", "RIGHT")
    h:SetText(label)
    h:SetPoint("RIGHT", right, 0)
    h:SetWidth(width)
  end
  head("Price each", 0, LIST_PRICE_W)
  head("Buy", -(LIST_PRICE_W + 10), 34)
  head("Have", -(LIST_PRICE_W + 10 + 34 + 10), 44)
  local hi = text(L.head, "GameFontDisableSmall")
  hi:SetPoint("LEFT", 20, 0)
  hi:SetText("Item")

  L.mid = divider(L)
  L.totalLabel = text(L, "GameFontNormalSmall")
  L.totalLabel:SetText("Ticked items cost")
  L.total = text(L, "GameFontHighlightSmall", "RIGHT")
  L.total:SetPoint("TOP", L.totalLabel, "TOP", 0, 0)
  L.total:SetPoint("RIGHT", L, "RIGHT", -PAD, 0)
  L.totalNote = text(L, "GameFontDisableSmall", "RIGHT")
  L.totalNote:SetPoint("RIGHT", L.total, "LEFT", -6, 0)

  L.create = CreateFrame("Button", nil, L, "UIPanelButtonTemplate")
  L.create:SetSize(110, 22)
  L.create:SetText("Create list")
  L.create:SetScript("OnClick", createList)
  L.status = text(L, "GameFontHighlightSmall")
  L.status:SetWordWrap(true)
  L:Hide()
  C.list = L
  return L
end

function openList()
  if not C.work then return end
  local L = makeList()
  L.crafts:SetText("1")
  L:Show()
  refreshList()
end

---------------------------------------------------------------------------------------------------------------------
-- Hooks

local function hook()
  local page = _G.ProfessionsFrame and ProfessionsFrame.CraftingPage
  local form = page and page.SchematicForm
  if C.hooked or not form then return end
  C.hooked = true
  makeFrame()
  for _, name in ipairs({ "Init", "Refresh" }) do
    if type(form[name]) == "function" then hooksecurefunc(form, name, function() C_Timer.After(0, render) end) end
  end
  ProfessionsFrame:HookScript("OnShow", function() C_Timer.After(0, render) end)
end
ns.craftRefresh = function() if C.frame then render() end end
ns.craftDebug = function() return C.clear end

-- names and icons arrive a moment later; bag changes update the counts
local pending
local function soon()
  if pending or not (C.frame and C.frame:IsShown()) then return end
  pending = true
  C_Timer.After(0.3, function() pending = nil; render() end)
end

-- Bags changed (bought, looted, crafted): the shopping list's "have" counts follow, and an amount to buy that was
-- worked out from them goes down with them. Amounts you typed and your ticks stay.
function C.bagsChanged()
  local L = C.list
  if not (L and L:IsShown() and C.rows) then return end
  local crafts = tonumber(L.crafts:GetText()) or 1
  for _, row in ipairs(L.rows) do
    local d = row:IsShown() and row.data
    if d then
      local have = haveOf(d.id)
      if have ~= d.have then
        if not d.typed then d.buy = R.toBuy(d.need / math.max(1, math.floor(crafts)), have, crafts) end
        d.have = have
        row.have:SetText(("%d/%d"):format(d.have, d.need))
        row.have:SetTextColor(unpack(d.have >= d.need and GOOD or QUIET))
        row.buy:SetText(tostring(d.buy))
      end
    end
  end
  listTotal()
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("TRADE_SKILL_SHOW")
ev:RegisterEvent("GET_ITEM_INFO_RECEIVED")
ev:RegisterEvent("BAG_UPDATE_DELAYED")
ev:SetScript("OnEvent", function(_, e, name)
  if e == "GET_ITEM_INFO_RECEIVED" then soon(); return end
  if e == "BAG_UPDATE_DELAYED" then C.bagsChanged(); return end
  if e == "ADDON_LOADED" and name ~= "Blizzard_Professions" then return end
  hook()
  if e == "TRADE_SKILL_SHOW" then C_Timer.After(0.1, render) end
end)
