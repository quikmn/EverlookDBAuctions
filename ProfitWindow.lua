-- EverlookDB Auctions: the profit finder window (/eah profit), open anywhere: the recipes you know whose result sells
-- on the auction house for more than its materials cost, best profit first (Profit.lua does the sums).
--   One row per recipe: icon and name, the skill it needs, what one craft costs, what it sells for after the cut,
--   the profit and the margin, and a box for how many crafts you plan. Filters: skill from-to and a minimum profit.
--   The one gold button, Make shopping list, saves what the planned crafts need (materials cheaper to craft broken
--   down, minus what you have) as a list in the auction house's Shopping tab.
--   A missing price is said, never guessed: "≈" marks a row with a material that has no AH price (its real profit is
--   lower), recipes whose result has no AH price are counted under the list, and prices over a day old are grey.
-- Settings (db.profit = { from, to, min (copper), noCraft }): only numbers, never a name. Its settings page is
-- "Crafting profit" in /eah.
local ADDON, ns = ...
local Pr = ns.profit
local R = ns.recipeList
local UI = ns.UI
local W = {}
ns.profitWindow = W

local WIDTH, PAD, ROW, ROWS = 760, 14, 24, 12
local SKILL_W, MONEY_W, MARGIN_W, CRAFTS_W, GAP = 40, 84, 52, 44, 8

local EUI = LibStub and LibStub("EverlookUI-1", true)
local U = EUI and EUI.Util
local T

local function try(fn, ...)
  if type(fn) ~= "function" then return nil end
  local okCall, a = pcall(fn, ...)
  if okCall then return a end
end
local function rgba(c) return c[1], c[2], c[3], c[4] or 1 end
local function db() return ns.db and ns.db() end
local function settings()
  local d = db()
  if not d then return {} end
  d.profit = d.profit or {}
  return d.profit
end

local function itemName(id)
  local n = try(C_Item.GetItemNameByID, id)
  if not n and C_Item.RequestLoadItemDataByID then pcall(C_Item.RequestLoadItemDataByID, id) end
  return n
end
local function qualityColor(id)
  local q = try(C_Item.GetItemQualityByID, id)
  local c = q and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q]
  if c then return c.r, c.g, c.b end
  return 1, 1, 1
end
local function haveOf(id) return try(C_Item.GetItemCount, id, true, false, true) or 0 end
local function priceOf(id)
  local it = ns.itemFor and ns.itemFor(id)
  if it and it[1] then return it[1], it[4] end
end
local function stale(at) return at ~= nil and time() - at >= Pr.STALE end
local function houseKey()
  return (ns.house and ns.house()) or (((ns.realmName and ns.realmName()) or "?") .. "-" .. (UnitFactionGroup("player") or "?"))
end

-- The rows, worked out again from the saved recipes and prices.
local function compute()
  local s = settings()
  local d = db() or {}
  local ctx = Pr.context({ recipes = d.crafts or {}, price = priceOf, cut = ns.ahCut and ns.ahCut() or 0.05,
    craftMats = not s.noCraft, info = Pr.info })
  local rows, counts = Pr.list(ctx, { from = s.from or 1, to = s.to or 300, min = s.min })
  return ctx, rows, counts
end
W.compute = compute

local function text(parent, size, color, justify)
  local fs = EUI.Text(parent, size or T.font, color or T.text)
  fs:SetJustifyH(justify or "LEFT")
  fs:SetWordWrap(false)
  return fs
end

---------------------------------------------------------------------------------------------------------------------
-- Rows

local function rowTooltip(self)
  local r = self.data
  if not r then return end
  GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
  if not pcall(GameTooltip.SetItemByID, GameTooltip, r.id) then GameTooltip:SetText(r.name or "?", 1, 1, 1) end
  GameTooltip:AddLine(" ")
  GameTooltip:AddLine(r.makes ~= 1 and ("One craft makes %s. Materials for one craft:"):format(r.makes) or "Materials for one craft:", 1, 0.82, 0)
  for _, m in ipairs(r.mats) do
    local n = itemName(m.id) or ("item " .. m.id)
    local right
    if m.each then
      right = ns.money(math.floor(m.each * m.need + 0.5)) .. (m.how == "craft" and " |cff8d94a3(craft it)|r" or "")
    else
      right = "|cffff6060no AH price|r"
    end
    GameTooltip:AddDoubleLine(("%dx %s"):format(m.need, n), right, 1, 1, 1, 1, 1, 1)
  end
  if r.approx then
    GameTooltip:AddLine("A material has no AH price, so the cost is too low and the real profit lower.", 1, 0.4, 0.4, true)
  end
  if r.oldest and stale(r.oldest) then
    GameTooltip:AddLine("The oldest price used is from " .. ns.ago(r.oldest) .. ". Update prices at the auction house.", 0.6, 0.6, 0.6, true)
  end
  GameTooltip:AddLine("Type how many crafts in its box to plan them. Shift-click links the item.", 0.55, 0.55, 0.55, true)
  GameTooltip:Show()
end

local function makeRow(parent)
  local row = CreateFrame("Button", nil, parent)
  row:SetHeight(ROW)
  row:RegisterForClicks("LeftButtonUp")
  row.bg = U.Round(row, 4, "BACKGROUND")
  row.bg:SetPoint("TOPLEFT", -6, 0)
  row.bg:SetPoint("BOTTOMRIGHT", 6, 0)
  row.bg:SetVertexColor(rgba(T.surfaceHi))
  row.bg:Hide()
  row.crafts = EUI.EditBox(row, CRAFTS_W, 20)
  row.crafts:SetPoint("RIGHT", 0, 0)
  row.crafts:SetNumeric(true)
  row.crafts:SetMaxLetters(3)
  row.crafts:SetJustifyH("RIGHT")
  row.crafts:SetTextInsets(4, 6, 0, 0)
  row.crafts:SetScript("OnTextChanged", function(self, user)
    if not user or not row.data then return end
    local n = tonumber(self:GetText()) or 0
    W.crafts[row.data.id] = n > 0 and n or nil
    W.footer()
  end)
  row.crafts:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
  row.margin = text(row, T.font, T.muted, "RIGHT")
  row.margin:SetPoint("RIGHT", row.crafts, "LEFT", -GAP, 0)
  row.margin:SetWidth(MARGIN_W)
  row.profit = text(row, T.font, T.ok, "RIGHT")
  row.profit:SetPoint("RIGHT", row.margin, "LEFT", -GAP, 0)
  row.profit:SetWidth(MONEY_W)
  row.sale = text(row, T.font, T.text, "RIGHT")
  row.sale:SetPoint("RIGHT", row.profit, "LEFT", -GAP, 0)
  row.sale:SetWidth(MONEY_W)
  row.cost = text(row, T.font, T.text, "RIGHT")
  row.cost:SetPoint("RIGHT", row.sale, "LEFT", -GAP, 0)
  row.cost:SetWidth(MONEY_W)
  row.skill = text(row, T.font, T.muted, "RIGHT")
  row.skill:SetPoint("RIGHT", row.cost, "LEFT", -GAP, 0)
  row.skill:SetWidth(SKILL_W)
  row.icon = row:CreateTexture(nil, "ARTWORK")
  row.icon:SetSize(18, 18)
  row.icon:SetPoint("LEFT", 0, 0)
  row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  row.name = text(row, T.font)
  row.name:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
  row.name:SetPoint("RIGHT", row.skill, "LEFT", -GAP, 0)
  row:SetScript("OnEnter", function(self) self.bg:Show(); rowTooltip(self) end)
  row:SetScript("OnLeave", function(self) self.bg:Hide(); GameTooltip:Hide() end)
  row:SetScript("OnClick", function(self)
    local r = self.data
    if not r then return end
    if IsShiftKeyDown() then
      local okInfo, _, link = pcall(C_Item.GetItemInfo, r.id)
      if okInfo and link and ChatEdit_InsertLink then ChatEdit_InsertLink(link) end
      return
    end
    self.crafts:SetFocus()
  end)
  return row
end

local function paintRow(row, r)
  row.data = r
  row.icon:SetTexture(try(C_Item.GetItemIconByID, r.id) or 134400)
  row.name:SetText(r.name or itemName(r.id) or ("item " .. r.id))
  row.name:SetTextColor(qualityColor(r.id))
  row.skill:SetText(r.skill and tostring(r.skill) or "?")
  local old = r.oldest and stale(r.oldest)
  row.cost:SetText((r.approx and "≈ " or "") .. Pr.short(r.cost))
  row.cost:SetTextColor(rgba(r.approx and T.danger or (old and T.muted or T.text)))
  row.sale:SetText(Pr.short(r.sale))
  row.sale:SetTextColor(rgba(stale(r.lowAt) and T.muted or T.text))
  row.profit:SetText((r.approx and "≈ " or (r.profit > 0 and "+" or "")) .. Pr.short(r.profit))
  row.profit:SetTextColor(rgba(r.profit > 0 and T.ok or T.danger))
  -- no margin for a row with an unpriced material: its cost is too low, so the percentage would mean nothing
  row.margin:SetText((r.margin and not r.approx) and (("%+d%%"):format(math.floor(r.margin * 100 + 0.5))) or "")
  local n = W.crafts[r.id]
  row.crafts:SetText(n and tostring(n) or "")
end

---------------------------------------------------------------------------------------------------------------------
-- The window

local function numberBox(parent, w, letters, onChange)
  local b = EUI.EditBox(parent, w, 24)
  b:SetNumeric(true)
  b:SetMaxLetters(letters)
  b:SetJustifyH("RIGHT")
  b:SetTextInsets(4, 8, 0, 0)
  b:SetScript("OnTextChanged", function(self, user) if user then onChange(tonumber(self:GetText())) end end)
  b:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
  return b
end

local function makeFrame()
  if W.frame then return W.frame end
  if not EUI then return nil end
  T = EUI.MakeTheme(ns.T and ns.T.accent or { 1, 0.82, 0 })
  W.crafts = W.crafts or {}
  local f = CreateFrame("Frame", "EverlookAuctionsProfit", UIParent)
  f.eluiTheme = T
  if UI and UI.own then UI.own(f) end
  f:SetWidth(WIDTH)
  f:SetFrameStrata("HIGH")
  f:SetToplevel(true)
  f:SetClampedToScreen(true)
  f:EnableMouse(true)
  f:SetMovable(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local p, _, rp, x, y = self:GetPoint()
    settings().pos = { p, rp, x, y }
  end)
  f:EnableMouseWheel(true)
  f:SetScript("OnMouseWheel", function(_, delta)
    W.offset = math.max(0, (W.offset or 0) - delta * 3)
    W.render(true)
  end)
  EUI.WindowChrome(f, T)
  EUI.CloseButton(f, T)
  if UISpecialFrames then tinsert(UISpecialFrames, "EverlookAuctionsProfit") end   -- Escape closes it, like the Prices window

  f.icon = f:CreateTexture(nil, "ARTWORK")
  f.icon:SetSize(18, 18)
  f.icon:SetPoint("TOPLEFT", 20, -20)
  if EUI.SetIcon(f.icon, "hammer") then f.icon:SetVertexColor(rgba(T.accent)) end
  f.title = text(f, T.fontHuge, T.text)
  f.title:SetPoint("LEFT", f.icon, "RIGHT", 8, 0)
  f.title:SetText("Crafting profit")
  f.gear = CreateFrame("Button", nil, f)
  f.gear:SetSize(24, 24)
  f.gear:SetPoint("TOPRIGHT", -38, -10)
  f.gear.icon = f.gear:CreateTexture(nil, "ARTWORK")
  f.gear.icon:SetSize(13, 13)
  f.gear.icon:SetPoint("CENTER")
  EUI.SetIcon(f.gear.icon, "gear")
  f.gear.icon:SetVertexColor(rgba(T.muted))
  f.gear:SetScript("OnClick", function() if ns.app then ns.app:Open("profit") end end)
  f.gear:SetScript("OnEnter", function(self)
    self.icon:SetVertexColor(rgba(T.text))
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText("Crafting profit settings", 1, 1, 1)
    GameTooltip:AddLine("Making materials yourself, the minimum profit.", nil, nil, nil, true)
    GameTooltip:Show()
  end)
  f.gear:SetScript("OnLeave", function(self) self.icon:SetVertexColor(rgba(T.muted)); GameTooltip:Hide() end)
  f.sub = text(f, T.font - 1, T.muted)
  f.sub:SetPoint("TOPLEFT", 20, -48)
  f.sub:SetPoint("RIGHT", -20, 0)

  -- filters: skill from-to, minimum profit
  local s = settings()
  local lbl = text(f, T.font, T.muted)
  lbl:SetPoint("TOPLEFT", 20, -74)
  lbl:SetText("Skill")
  f.from = numberBox(f, 48, 3, function(v) settings().from = v; W.offset = 0; W.render() end)
  f.from:SetPoint("LEFT", lbl, "RIGHT", 8, 0)
  local dash = text(f, T.font, T.muted)
  dash:SetPoint("LEFT", f.from, "RIGHT", 6, 0)
  dash:SetText("to")
  f.to = numberBox(f, 48, 3, function(v) settings().to = v; W.offset = 0; W.render() end)
  f.to:SetPoint("LEFT", dash, "RIGHT", 6, 0)
  local ml = text(f, T.font, T.muted)
  ml:SetPoint("LEFT", f.to, "RIGHT", 20, 0)
  ml:SetText("Profit at least")
  f.min = numberBox(f, 56, 5, function(v) settings().min = v and v * 100 or nil; W.offset = 0; W.render() end)
  f.min:SetPoint("LEFT", ml, "RIGHT", 8, 0)
  local sl = text(f, T.font, T.muted)
  sl:SetPoint("LEFT", f.min, "RIGHT", 6, 0)
  sl:SetText("silver")
  f.from:SetText(tostring(s.from or 1))
  f.to:SetText(tostring(s.to or 300))
  f.min:SetText(s.min and tostring(math.floor(s.min / 100)) or "")
  f.clear = EUI.Button(f, "Clear crafts", function()
    wipe(W.crafts)
    W.status = nil
    W.render()
  end, 110)
  f.clear:SetHeight(24)
  f.clear:SetPoint("TOPRIGHT", -20, -69)

  -- the list card
  f.list = CreateFrame("Frame", nil, f)
  f.list.fill, f.list.edge = U.RoundBox(f.list, T.radius, T.card, T.divider)
  f.list:SetPoint("TOPLEFT", 16, -104)
  f.list:SetPoint("RIGHT", -16, 0)
  local head = CreateFrame("Frame", nil, f.list)
  head:SetHeight(16)
  head:SetPoint("TOPLEFT", PAD, -10)
  head:SetPoint("RIGHT", -PAD, 0)
  local x = 0
  local function col(label, width)
    local h = text(head, T.fontSmall, T.muted, "RIGHT")
    h:SetText(label)
    h:SetPoint("RIGHT", -x, 0)
    h:SetWidth(width)
    x = x + width + GAP
  end
  col("CRAFTS", CRAFTS_W)
  col("MARGIN", MARGIN_W)
  col("PROFIT", MONEY_W)
  col("SELLS FOR", MONEY_W)
  col("COST", MONEY_W)
  col("SKILL", SKILL_W)
  local hn = text(head, T.fontSmall, T.muted)
  hn:SetPoint("LEFT", 24, 0)
  hn:SetText("RECIPE (BEST PROFIT FIRST)")
  f.rows = {}
  for i = 1, ROWS do
    local row = makeRow(f.list)
    row:SetPoint("TOPLEFT", PAD, -32 - (i - 1) * ROW)
    row:SetPoint("RIGHT", -PAD, 0)
    f.rows[i] = row
  end
  f.empty = text(f.list, T.font, T.muted)
  f.empty:SetWordWrap(true)
  f.empty:SetPoint("TOPLEFT", PAD, -36)
  f.empty:SetPoint("RIGHT", -PAD, 0)
  f.foot = U.Solid(f.list, "ARTWORK", rgba(T.divider))
  f.foot:SetHeight(1)
  f.note = text(f.list, T.font - 1, T.muted)
  f.note:SetWordWrap(true)
  f.pos = text(f.list, T.font - 1, T.muted, "RIGHT")

  -- under the card: the selection, the one gold button, what happened
  f.sum = text(f, T.font, T.text)
  f.make = EUI.Button(f, "Make shopping list", function() W.makeList() end, 170, "accent")
  f.status = text(f, T.font - 1, T.muted)
  f.status:SetWordWrap(true)

  EUI.CloseOnEscape(f)
  local pos = s.pos
  if pos then f:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4]) else f:SetPoint("CENTER", 0, 40) end
  f:Hide()
  W.frame = f
  return f
end

-- The selection line under the list: how many crafts are planned, what they cost and make.
function W.footer()
  local f = W.frame
  if not f then return end
  local picks = {}
  for _, r in ipairs(W.rows or {}) do
    if W.crafts[r.id] then picks[#picks + 1] = { row = r, crafts = W.crafts[r.id] } end
  end
  W.picks = picks
  local cost, profit, crafts, approx = Pr.totals(picks)
  if crafts == 0 then
    f.sum:SetText("Type how many crafts you plan in a recipe's box, then make a shopping list.")
    f.sum:SetTextColor(rgba(T.muted))
  else
    f.sum:SetText(("Planned: %d %s, %d %s.  Gold in %s%s,  profit %s%s"):format(#picks, #picks == 1 and "recipe" or "recipes",
      crafts, crafts == 1 and "craft" or "crafts", approx and "≈ " or "", ns.money(cost), approx and "≈ " or "",
      (profit < 0 and "-" or "") .. ns.money(math.abs(profit))))
    f.sum:SetTextColor(rgba(T.text))
  end
  f.make:SetUsable(crafts > 0)
end

-- Draws the window. keep: only scrolled, so the rows aren't worked out again.
function W.render(keep)
  local f = W.frame
  if not (f and f:IsShown()) then return end
  local d = db() or {}
  if not keep or not W.rows then
    local _, rows, counts = compute()
    W.rows, W.counts = rows, counts
  end
  local rows, counts = W.rows, W.counts
  local h = d.houses and d.houses[houseKey()]
  local nPrices = 0
  if h and h.items then for _ in pairs(h.items) do nPrices = nPrices + 1 end end
  -- other players' scan (shared prices) counts too, and says so when it is the newer one
  local sh = ns.shared and ns.shared.house(houseKey())
  if sh then for _ in pairs(sh.items) do nPrices = nPrices + 1 end end
  local pricesAt, shared = nil, false
  if ns.pricesAt then pricesAt, shared = ns.pricesAt(houseKey():match("%-(%a+)$")) end
  local realm, side = houseKey():match("^(.*)%-(%a+)$")
  local where = side and (side .. " auction house") or "your auction house"
  if nPrices == 0 then
    f.sub:SetText(("From the %d recipes you know. No prices yet for the %s."):format(counts.known, where))
    f.sub:SetTextColor(rgba(T.danger))
  else
    local when = shared and ("other players' scan " .. ns.ago(pricesAt))
      or (h and h.scanned) and ("full update " .. ns.ago(h.scanned)) or "no full update yet"
    f.sub:SetText(("From the %d recipes you know, at the %s's prices (%s), after its %d%% cut."):format(counts.known, where,
      when, math.floor((ns.ahCut and ns.ahCut() or 0.05) * 100 + 0.5)))
    f.sub:SetTextColor(rgba((not pricesAt or time() - pricesAt >= Pr.STALE) and T.danger or T.muted))
  end

  local maxOff = math.max(0, #rows - ROWS)
  W.offset = math.max(0, math.min(W.offset or 0, maxOff))
  local shown = 0
  for i = 1, ROWS do
    local r = rows[W.offset + i]
    local row = f.rows[i]
    if r then paintRow(row, r); row:Show(); shown = i else row:Hide(); row.data = nil end
  end
  f.empty:SetShown(#rows == 0)
  if #rows == 0 then
    if counts.known == 0 then
      f.empty:SetText("No recipes yet. Open each of your profession windows once, so the addon learns your recipes; they show here after that.")
    elseif nPrices == 0 then
      f.empty:SetText("No auction prices yet. Open the auction house: prices update by themselves while it is open (or type /eah scan there).")
    else
      local s = settings()
      f.empty:SetText(("No recipe in skill %d to %d%s. Lower the minimum profit or widen the skill range."):format(s.from or 1,
        s.to or 300, s.min and (" makes at least " .. ns.money(s.min) .. " profit") or " makes a profit"))
    end
  end

  local y = -32 - math.max(shown, #rows == 0 and 2 or 0) * ROW - 8
  f.foot:ClearAllPoints()
  f.foot:SetPoint("TOPLEFT", PAD, y)
  f.foot:SetPoint("TOPRIGHT", -PAD, y)
  local notes = {}
  if counts.approx > 0 then
    notes[#notes + 1] = ("≈ %d %s a material with no AH price: the cost shown is too low."):format(counts.approx,
      counts.approx == 1 and "recipe has" or "recipes have")
  end
  if counts.noSale > 0 then
    notes[#notes + 1] = ("%d %s left out: no AH price for what %s."):format(counts.noSale,
      counts.noSale == 1 and "recipe" or "recipes", counts.noSale == 1 and "it makes" or "they make")
  end
  f.note:SetText(#notes > 0 and table.concat(notes, "  ") or "Prices over a day old are grey. Hover a recipe for its materials.")
  f.note:ClearAllPoints()
  f.note:SetPoint("TOPLEFT", PAD, y - 8)
  f.note:SetPoint("RIGHT", f.pos, "LEFT", -12, 0)
  f.pos:ClearAllPoints()
  f.pos:SetPoint("TOPRIGHT", -PAD, y - 8)
  f.pos:SetWidth(90)
  f.pos:SetText(#rows > ROWS and ("%d-%d of %d"):format(W.offset + 1, W.offset + shown, #rows) or "")
  local listH = -(y - 8 - 16 - 10)
  f.list:SetHeight(listH)

  local by = -104 - listH - 14
  f.sum:ClearAllPoints()
  f.sum:SetPoint("TOPLEFT", 20, by - 6)
  f.sum:SetPoint("RIGHT", f.make, "LEFT", -12, 0)
  f.make:ClearAllPoints()
  f.make:SetPoint("TOPRIGHT", -16, by)
  f.status:ClearAllPoints()
  f.status:SetPoint("TOPLEFT", 20, by - 34)
  f.status:SetPoint("RIGHT", -20, 0)
  local st = W.status
  f.status:SetText(st and st[1] or "")
  if st then f.status:SetTextColor(rgba(st[2] or T.muted)) end
  f:SetHeight(-(by - 34 - (st and 30 or 4) - 10))
  W.footer()
end

-- Make shopping list: what the planned crafts need, as one list in the Shopping tab.
function W.makeList()
  local d = db()
  if not d or not W.picks or #W.picks == 0 then return end
  local ctx = compute()
  local need = Pr.shopping(ctx, W.picks, haveOf)
  local items, leftOut = {}, {}
  for _, m in ipairs(need) do
    if m.buy > 0 then
      local vendorOnly = not priceOf(m.id) and ns.ITEMDATA and ns.ITEMDATA[m.id] and (ns.ITEMDATA[m.id][1] or 0) % 2 == 1
      if vendorOnly then leftOut[#leftOut + 1] = itemName(m.id) or ("item " .. m.id)
      else items[#items + 1] = { m.id, m.buy } end
    end
  end
  if #items == 0 then
    W.status = { #leftOut > 0 and ("Nothing to buy at the auction house; vendors sell the rest: " .. table.concat(leftOut, ", ") .. ".")
      or "You have everything these crafts need.", T.ok }
    W.render(true)
    return
  end
  local name = #W.picks == 1 and (W.picks[1].row.name or "Crafting profit") or "Crafting profit"
  d.lists = d.lists or {}
  local l, new, i = R.saveCounts(d.lists, name, items, itemName)
  if not l then
    W.status = { new == "loading" and "Item names are still loading. Try again in a moment." or "Couldn't make the list.", T.danger }
  else
    d.listSel = i
    local msg = ("%s \"%s\" in the auction house's Shopping tab: %d %s."):format(new and "Saved as" or "Updated", l.name,
      #l.queries, #l.queries == 1 and "item" or "items")
    if #leftOut > 0 then msg = msg .. " Left out, vendors sell them: " .. table.concat(leftOut, ", ") .. "." end
    W.status = { msg, T.ok }
    if ns.shoppingRefresh then pcall(ns.shoppingRefresh) end
  end
  W.render(true)
end

function W.open()
  local f = makeFrame()
  if not f then return end
  W.status = nil
  f:Show()
  W.render()
end
function W.toggle()
  local f = makeFrame()
  if f and f:IsShown() then f:Hide() else W.open() end
end
function W.refresh() if W.frame and W.frame:IsShown() then W.render() end end

---------------------------------------------------------------------------------------------------------------------
-- The command and the settings page, added to the /eah app once Options.lua has made it.

local function addToApp(app)
  if not app or W.added then return end
  W.added = true
  app:Setting({
    key = "profitcraft", type = "bool", label = "Count making a material yourself when that is cheaper than buying it (bars, bolts)",
    chatLabel = "Profit: craft materials", keywords = { "profit", "crafting", "materials", "intermediate", "bars", "bolts", "buy" },
    get = function() return not settings().noCraft end,
    set = function(v) settings().noCraft = not v or nil end,
    after = W.refresh,
  })
  app:Setting({
    key = "profitmin", type = "number", label = "Show recipes making at least this much profit (silver)", min = 0, max = 1000, step = 5,
    chatLabel = "Profit: minimum", keywords = { "profit", "minimum", "silver", "filter", "crafting" },
    get = function() return math.floor((settings().min or 0) / 100) end,
    set = function(v)
      v = math.max(0, math.floor(tonumber(v) or 0))
      settings().min = v > 0 and v * 100 or nil
      if W.frame then W.frame.min:SetText(v > 0 and tostring(v) or "") end
    end,
    after = W.refresh,
  })
  app:Command("profit", "profit", "the recipes you know that sell for more than their materials cost (works anywhere)",
    function() W.toggle() end, { "profits", "craftprofit", "flip" })
  app:Section("profit", "Crafting profit", function(stack)
    local EU = EUI
    EU.Header(stack, "Crafting profit", "The recipes you know whose result sells on the auction house for more than its materials cost, after the cut. Open it anywhere with /eah profit.")
    EU.ButtonRow(stack, {
      { label = "Open profit finder", width = 170, style = "accent", onClick = function() W.open() end,
        desc = "The list of your profitable recipes, with a shopping list for the crafts you plan.",
        keywords = { "profit", "finder", "crafting", "open", "flip", "recipes" } },
    })
    app:Widget(stack, "profitcraft")
    app:Widget(stack, "profitmin")
    EU.Note(stack, "Prices are your last scan of the auction house; nothing is guessed. A material without an AH price shows ≈ (the real profit is lower), and a recipe whose result has no price is left out. Open each profession window once so the addon knows your recipes.")
  end, { icon = "hammer" })
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:SetScript("OnEvent", function(_, _, name)
  if name ~= ADDON then return end
  ev:UnregisterEvent("ADDON_LOADED")
  -- Options.lua makes the app on this same event, and loads first
  if ns.app then addToApp(ns.app) else C_Timer.After(0, function() addToApp(ns.app) end) end
end)

-- /eah profit also works when the settings window couldn't be built
local prevSlash = ns.slash
function ns.slash(msg)
  if msg == "profit" or msg == "profits" then W.toggle(); return true end
  return prevSlash and prevSlash(msg) or false
end
