-- EverlookDB Auctions: the profit finder window (/eah profit), open anywhere: the recipes you know whose result sells
-- on the auction house for more than its materials cost, best profit first (Profit.lua does the sums).
--   One row per recipe: icon and name, the skill it needs, what one craft costs, what it sells for after the cut,
--   the profit and the margin, and a box for how many crafts you plan. Money is in gold, silver and copper columns
--   with the game's coin icons, so the coins line up down the list. Click a column's heading to sort by it (again:
--   the other way). Filters: words in the name, skill from-to, profit at least, margin at least, cost at most, only
--   what you can make now (the materials are in your bags), and, with EverlookDB Crafting, the recipes of your alts
--   (ticked per character; a row then says who can make it). "Clear filters" puts them all back.
--   The one gold button, Make shopping list, saves what the planned crafts need (materials cheaper to craft broken
--   down, minus what you have) as a list in the auction house's Shopping tab.
--   A missing price is said, never guessed: "≈" marks a row with a material that has no AH price (its real profit is
--   lower), recipes whose result has no AH price are counted under the list, and prices over a day old are grey.
-- Settings (db.profit = { v, from, to, min (copper), maxCost (copper), minMargin (whole %), q (the search words),
-- canMake, sort, desc, noCraft, pos }); the alts ticked are per character (EverlookAuctionsCharDB.profitAlts =
-- { [character GUID, as EverlookDB Crafting keys them] = true }). Its settings page is "Crafting" in /eah.
local ADDON, ns = ...
local Pr = ns.profit
local R = ns.recipeList
local UI = ns.UI
local W = {}
ns.profitWindow = W

local WIDTH, PAD, ROW, ROWS = 760, 14, 24, 12
local SKILL_W, MONEY_W, COIN_W, MARGIN_W, CRAFTS_W, GAP = 40, 104, 30, 52, 44, 8
local LIST_TOP = -136
local CHECK_TEX, BOX_TEX = "Interface\\Buttons\\UI-CheckBox-Check", "Interface\\Buttons\\UI-CheckBox-Up"

local EUI = LibStub and LibStub("EverlookUI-1", true)
local U = EUI and EUI.Util
local T

local function try(fn, ...)
  if type(fn) ~= "function" then return nil end
  local okCall, a = pcall(fn, ...)
  if okCall then return a end
end
local function rgba(c) return c[1], c[2], c[3], c[4] or 1 end
local function hex(c) return ("%02x%02x%02x"):format(math.floor(c[1] * 255 + 0.5), math.floor(c[2] * 255 + 0.5), math.floor(c[3] * 255 + 0.5)) end
local function db() return ns.db and ns.db() end
local function settings()
  local d = db()
  if not d then return {} end
  d.profit = d.profit or {}
  Pr.migrate(d.profit)
  return d.profit
end
W.settings = settings

local function itemName(id)
  local n = try(C_Item.GetItemNameByID, id)
  if not n and C_Item.RequestLoadItemDataByID then pcall(C_Item.RequestLoadItemDataByID, id) end
  return n
end
local function rowName(r) return r.name or itemName(r.id) end
local function qualityColor(id)
  local q = try(C_Item.GetItemQualityByID, id)
  local c = q and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q]
  if c then return c.r, c.g, c.b end
  return 1, 1, 1
end
local function haveOf(id) return try(C_Item.GetItemCount, id, true, false, true) or 0 end
local function bagCount(id) return try(C_Item.GetItemCount, id) or 0 end   -- bags only: what you can craft with now
local function priceOf(id)
  local it = ns.itemFor and ns.itemFor(id)
  if it and it[1] then return it[1], it[4] end
end
local function stale(at) return at ~= nil and time() - at >= Pr.STALE end
local function houseKey()
  return (ns.house and ns.house()) or (((ns.realmName and ns.realmName()) or "?") .. "-" .. (UnitFactionGroup("player") or "?"))
end

---------------------------------------------------------------------------------------------------------------------
-- Alts: EverlookDB Crafting (API v6) knows each character's professions and recipes

local function craftAPI()
  local api = rawget(_G, "EverlookCraftAPI")
  if api and (tonumber(api.version) or 0) >= 6 and api.characters and api.recipesOf then return api end
end
W.craftAPI = craftAPI

-- your characters with recipes (you first), from EverlookDB Crafting; {} without it
function W.characters()
  local api = craftAPI()
  local list = api and try(api.characters)
  return type(list) == "table" and list or {}
end

-- the alts ticked on this character
function W.altTicks()
  EverlookAuctionsCharDB = EverlookAuctionsCharDB or {}
  local c = EverlookAuctionsCharDB
  if type(c.profitAlts) ~= "table" then c.profitAlts = {} end
  return c.profitAlts
end

function W.toggleAlt(key)
  if type(key) ~= "string" then return end
  local t = W.altTicks()
  t[key] = not t[key] or nil
  W.offset = 0
  W.refresh()
end

local function classHex(class)
  local cc = type(class) == "string" and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
  if cc and cc.r then return hex({ cc.r, cc.g, cc.b }) end
  return "e8eaef"
end
local function charName(c) return "|cff" .. classHex(c.class) .. tostring(c.name or "?") .. "|r" end
local function profText(profs)
  local out = {}
  for _, p in ipairs(profs or {}) do out[#out + 1] = p.rank and (p.name .. " " .. p.rank) or p.name end
  return table.concat(out, ", ")
end
W.profText = profText

-- An item-keyed recipe table (as db.crafts) from EverlookDB Crafting's recipes; the reagents this addon read in a
-- profession window win (they are the server's).
local function toRecipes(list, crafts)
  local out = {}
  for _, r in ipairs(list or {}) do
    local id = r.creates
    if id then out[id] = crafts[id] or { mats = r.mats, makes = tonumber(r.yield) or 1, rid = r.spell, name = r.name } end
  end
  return out
end

-- Whose recipes the list has: you first, then the alts ticked. Your recipes are EverlookDB Crafting's record of this
-- character when it has one, else every recipe this addon has seen (db.crafts, as before alts).
function W.sources()
  local d = db() or {}
  local crafts = d.crafts or {}
  local api = craftAPI()
  local chars = api and W.characters() or {}
  local me
  for _, c in ipairs(chars) do if c.me then me = c end end
  local mine = me and try(api.recipesOf, me.key)
  local sources = { { key = me and me.key, name = me and me.name, class = me and me.class, profs = me and me.profs, me = true,
    recipes = (type(mine) == "table" and #mine > 0) and toRecipes(mine, crafts) or crafts } }
  local ticks = W.altTicks()
  for _, c in ipairs(chars) do
    if not c.me and ticks[c.key] then
      local list = try(api.recipesOf, c.key)
      if type(list) == "table" then
        sources[#sources + 1] = { key = c.key, name = c.name, class = c.class, profs = c.profs,
          recipes = toRecipes(list, crafts), bags = (api.bagsOf and try(api.bagsOf, c.key)) or {} }
      end
    end
  end
  return sources
end

-- Can this crafter make one now? You: your bags right now; an alt: its bags when it was last seen.
local function crafterCan(c, r)
  if not c or c.me or not c.bags then return Pr.canMake(r, bagCount) end
  return Pr.canMake(r, function(id) return c.bags[id] or 0 end)
end

-- The rows, worked out again from the saved recipes and prices (best profit first; render sorts them as chosen).
local function compute()
  local s = settings()
  local sources = W.sources()
  local recipes, who = Pr.merge(sources)
  local ctx = Pr.context({ recipes = recipes, price = priceOf, cut = ns.ahCut and ns.ahCut() or 0.05,
    craftMats = not s.noCraft, info = Pr.info })
  local rows, counts = Pr.list(ctx, { from = s.from or 1, to = s.to or 300, min = s.min, maxCost = s.maxCost,
    minMargin = s.minMargin, q = s.q, nameOf = rowName, who = who, canMake = s.canMake and crafterCan or nil })
  return ctx, rows, counts, sources
end
W.compute = compute

-- the sort chosen: column, high to low
function W.sortState()
  local s = settings()
  local key = Pr.SORTS[s.sort] ~= nil and s.sort or "profit"
  local desc = s.desc
  if desc == nil then desc = Pr.SORTS[key] end
  return key, desc and true or false
end

function W.sortBy(key)
  if Pr.SORTS[key] == nil then return end
  local s = settings()
  local cur, desc = W.sortState()
  if cur == key then desc = not desc else desc = Pr.SORTS[key] end
  if key == "profit" and desc then s.sort, s.desc = nil, nil else s.sort, s.desc = key, desc end
  W.offset = 0
  W.render()
end

local function text(parent, size, color, justify)
  local fs = EUI.Text(parent, size or T.font, color or T.text)
  fs:SetJustifyH(justify or "LEFT")
  fs:SetWordWrap(false)
  return fs
end

---------------------------------------------------------------------------------------------------------------------
-- Money cells: gold, silver and copper each right-aligned in a column of its own

local function moneyCell(parent)
  local cell = CreateFrame("Frame", nil, parent)
  cell:SetSize(MONEY_W, ROW)
  cell.p = {}
  for i = 1, 3 do
    local fs = text(cell, T.font, T.text, "RIGHT")
    fs:SetPoint("RIGHT", cell, "RIGHT", -(3 - i) * COIN_W, 0)
    cell.p[i] = fs
  end
  return cell
end

local function setMoney(cell, copper, opt, color)
  local cells = Pr.coinCells(copper, opt)
  for i = 1, 3 do
    cell.p[i]:SetText(cells[i])
    cell.p[i]:SetTextColor(rgba(color or T.text))
  end
  cell.copper = copper
end

---------------------------------------------------------------------------------------------------------------------
-- Rows

-- "you", "Bob", "you + 2": who can make a row, when the list has alts
local function whoTag(who)
  if not W.multi or type(who) ~= "table" or #who == 0 then return "" end
  local first = who[1]
  local s = first.me and "|cffaab1bdyou|r" or ("|cff8d94a3" .. tostring(first.name or "?") .. "|r")
  if #who > 1 then s = s .. "|cff8d94a3 + " .. (#who - 1) .. "|r" end
  return s
end
W.whoTag = whoTag

local function rowTooltip(self)
  local r = self.data
  if not r then return end
  ns.itemTipOwner(self)   -- next to the mouse; "Equipped" only with Shift (ItemTip.lua)
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
  if W.multi and type(r.who) == "table" and #r.who > 0 then
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(settings().canMake and "Can make it now:" or "Can make it:", 1, 0.82, 0)
    for _, c in ipairs(r.who) do
      GameTooltip:AddDoubleLine(charName(c) .. (c.me and " |cff8d94a3(you)|r" or ""), profText(c.profs), 1, 1, 1, 0.55, 0.58, 0.64)
    end
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
  row.profit = moneyCell(row)
  row.profit:SetPoint("RIGHT", row.margin, "LEFT", -GAP, 0)
  row.sale = moneyCell(row)
  row.sale:SetPoint("RIGHT", row.profit, "LEFT", -GAP, 0)
  row.cost = moneyCell(row)
  row.cost:SetPoint("RIGHT", row.sale, "LEFT", -GAP, 0)
  row.skill = text(row, T.font, T.muted, "RIGHT")
  row.skill:SetPoint("RIGHT", row.cost, "LEFT", -GAP, 0)
  row.skill:SetWidth(SKILL_W)
  row.icon = row:CreateTexture(nil, "ARTWORK")
  row.icon:SetSize(18, 18)
  row.icon:SetPoint("LEFT", 0, 0)
  row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  -- who can make it (with alts): its own text at the end of the name's room, so a long name never hides it
  row.tag = text(row, T.font - 1, T.muted, "RIGHT")
  row.tag:SetPoint("RIGHT", row.skill, "LEFT", -GAP, 0)
  row.name = text(row, T.font)
  row.name:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
  row.name:SetPoint("RIGHT", row.tag, "LEFT", -6, 0)
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
  row.tag:SetText(whoTag(r.who))
  row.name:SetText(rowName(r) or ("item " .. r.id))
  row.name:SetTextColor(qualityColor(r.id))
  row.skill:SetText(r.skill and tostring(r.skill) or "?")
  local old = r.oldest and stale(r.oldest)
  setMoney(row.cost, r.cost, { prefix = r.approx and "≈ " or nil }, r.approx and T.danger or (old and T.muted or T.text))
  setMoney(row.sale, r.sale, nil, stale(r.lowAt) and T.muted or T.text)
  setMoney(row.profit, r.profit, { prefix = r.approx and "≈ " or nil, sign = not r.approx }, r.profit > 0 and T.ok or T.danger)
  -- no margin for a row with an unpriced material: its cost is too low, so the percentage would mean nothing
  row.margin:SetText((r.margin and not r.approx) and (("%+d%%"):format(math.floor(r.margin * 100 + 0.5))) or "")
  local n = W.crafts[r.id]
  row.crafts:SetText(n and tostring(n) or "")
end

---------------------------------------------------------------------------------------------------------------------
-- The filters

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

-- A box for money: "1g 20s", "120s", "1.2g" or a plain number of silver. A box that isn't money goes red and changes
-- nothing; leaving it writes the amount back the same way every time ("1g 20s").
local function moneyBox(parent, w, field, tip)
  local b = EUI.EditBox(parent, w, 24)
  b:SetMaxLetters(16)
  b:SetJustifyH("RIGHT")
  b:SetTextInsets(4, 8, 0, 0)
  b:SetScript("OnTextChanged", function(self, user)
    if not user then return end
    local c, good = Pr.parseMoney(self:GetText())
    if self.border and self.border.SetColor then self.border:SetColor(rgba(good and T.accent or T.danger)) end
    if not good then return end
    settings()[field] = (c and c > 0) and c or nil
    W.offset = 0
    W.render()
  end)
  b:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
  b:HookScript("OnEditFocusLost", function(self)
    if self.border and self.border.SetColor then self.border:SetColor(rgba(T.border)) end
    local v = settings()[field]
    self:SetText(v and Pr.moneyText(v) or "")
  end)
  b:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:SetText(tip, 1, 1, 1)
    GameTooltip:AddLine("Type 1g 20s, 120s, 1.2g or 50c. A plain number is silver.", nil, nil, nil, true)
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)
  return b
end

-- A tick box with its words; the whole thing clicks.
local function tickBox(parent, label, width, onClick)
  local b = CreateFrame("Button", nil, parent)
  b:SetSize(width, 24)
  b.box = CreateFrame("Frame", nil, b)
  b.box:SetSize(16, 16)
  b.box:SetPoint("LEFT", 0, 0)
  b.box.fill, b.box.edge = U.RoundBox(b.box, 4, T.surface, T.border)
  b.check = b.box:CreateTexture(nil, "OVERLAY")
  b.check:SetSize(12, 12)
  b.check:SetPoint("CENTER")
  if EUI.SetIcon(b.check, "check") then b.check:SetVertexColor(rgba(T.accent)) else b.check:SetTexture(CHECK_TEX) end
  b.label = text(b, T.font, T.muted)
  b.label:SetPoint("LEFT", b.box, "RIGHT", 6, 0)
  b.label:SetText(label)
  function b:SetOn(on)
    self.on = on and true or false
    self.check:SetShown(self.on)
    self.label:SetTextColor(rgba(self.on and T.text or T.muted))
  end
  b:SetScript("OnClick", function(self) onClick(not self.on) end)
  b:SetScript("OnEnter", function(self) self.label:SetTextColor(rgba(T.text)) end)
  b:SetScript("OnLeave", function(self) self.label:SetTextColor(rgba(self.on and T.text or T.muted)) end)
  b:SetOn(false)
  return b
end

-- A text link (no button look): muted, the accent under the mouse.
local function link(parent, label, onClick)
  local b = CreateFrame("Button", nil, parent)
  b:SetSize(90, 24)
  b.label = text(b, T.font, T.muted, "RIGHT")
  b.label:SetPoint("RIGHT", 0, 0)
  b.label:SetText(label)
  b:SetScript("OnClick", onClick)
  b:SetScript("OnEnter", function(self) self.label:SetTextColor(rgba(T.accent)) end)
  b:SetScript("OnLeave", function(self) self.label:SetTextColor(rgba(T.muted)) end)
  return b
end

-- The alts list: one row per character with recipes (you at the top, always in), a tick per alt. The list stays
-- open while you tick.
function W.openAlts(owner)
  local chars = W.characters()
  local ticks = W.altTicks()
  local items = {}
  local alts = 0
  for _, c in ipairs(chars) do
    local line = charName(c) .. "  |cff8d94a3" .. profText(c.profs) .. "|r"
    if c.me then
      items[#items + 1] = { title = true, text = line .. "  |cff8d94a3(you, always in)|r" }
    else
      alts = alts + 1
      items[#items + 1] = { value = c.key, text = line, icon = ticks[c.key] and CHECK_TEX or BOX_TEX }
    end
  end
  if alts == 0 then
    items[#items + 1] = { title = true, text = "No alts with recipes yet: open each alt's profession windows once." }
  end
  if EUI.OpenPopup then
    EUI.OpenPopup(owner, items, nil, function(key)
      W.toggleAlt(key)
      W.openAlts(owner)
    end, { width = 360 })
  end
end

local function altsLabel()
  local ticks = W.altTicks()
  local n, one = 0, nil
  for _, c in ipairs(W.characters()) do
    if not c.me and ticks[c.key] then n = n + 1; one = c end
  end
  if n == 0 then return "Alts: none" end
  if n == 1 then return "Alts: " .. tostring(one.name or "?") end
  return "Alts: " .. n
end

-- Puts the saved filters into their boxes.
function W.fillBoxes()
  local f = W.frame
  if not f then return end
  local s = settings()
  f.search:SetText(s.q or "")
  f.search.hint:SetShown((s.q or "") == "")
  f.from:SetText(tostring(s.from or 1))
  f.to:SetText(tostring(s.to or 300))
  f.min:SetText(s.min and Pr.moneyText(s.min) or "")
  f.margin:SetText(s.minMargin and tostring(s.minMargin) or "")
  f.maxCost:SetText(s.maxCost and Pr.moneyText(s.maxCost) or "")
  f.canMake:SetOn(s.canMake)
end

function W.clearFilters()
  Pr.clearFilters(settings())
  W.offset = 0
  W.fillBoxes()
  W.render()
end

---------------------------------------------------------------------------------------------------------------------
-- The window

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
  f.closeButton = EUI.CloseButton(f, T)

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

  -- filters, first row: search, skill from-to, only what I can make now; Clear crafts on the right
  local function changed() W.offset = 0; W.render() end
  f.search = EUI.EditBox(f, 170, 24)
  f.search:SetPoint("TOPLEFT", 20, -70)
  f.search:SetMaxLetters(40)
  f.search.hint = text(f.search, T.font, T.muted)
  f.search.hint:SetPoint("LEFT", 8, 0)
  f.search.hint:SetText("Search recipes")
  f.search:SetScript("OnTextChanged", function(self, user)
    local q = self:GetText() or ""
    self.hint:SetShown(q == "")
    if not user then return end
    settings().q = q ~= "" and q or nil
    changed()
  end)
  f.search:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
  local lbl = text(f, T.font, T.muted)
  lbl:SetPoint("LEFT", f.search, "RIGHT", 16, 0)
  lbl:SetText("Skill")
  f.from = numberBox(f, 44, 3, function(v) settings().from = v; changed() end)
  f.from:SetPoint("LEFT", lbl, "RIGHT", 6, 0)
  local dash = text(f, T.font, T.muted)
  dash:SetPoint("LEFT", f.from, "RIGHT", 6, 0)
  dash:SetText("to")
  f.to = numberBox(f, 44, 3, function(v) settings().to = v; changed() end)
  f.to:SetPoint("LEFT", dash, "RIGHT", 6, 0)
  f.canMake = tickBox(f, "Only what I can make now", 176, function(on)
    settings().canMake = on or nil
    f.canMake:SetOn(on)
    changed()
  end)
  f.canMake:SetPoint("LEFT", f.to, "RIGHT", 16, 0)
  f.canMake:HookScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:SetText("Only what I can make now", 1, 1, 1)
    GameTooltip:AddLine("Recipes whose materials are in your bags right now (an alt's: in its bags when you last played it).", nil, nil, nil, true)
    GameTooltip:Show()
  end)
  f.canMake:HookScript("OnLeave", function() GameTooltip:Hide() end)
  f.clear = EUI.Button(f, "Clear crafts", function()
    wipe(W.crafts)
    W.status = nil
    W.render()
  end, 110)
  f.clear:SetHeight(24)
  f.clear:SetPoint("TOPRIGHT", -20, -70)

  -- second row: profit at least, margin at least, cost at most, alts; Clear filters on the right
  local pl = text(f, T.font, T.muted)
  pl:SetPoint("TOPLEFT", 20, -106)
  pl:SetText("Profit at least")
  f.min = moneyBox(f, 70, "min", "Profit at least")
  f.min:SetPoint("LEFT", pl, "RIGHT", 6, 0)
  local mgl = text(f, T.font, T.muted)
  mgl:SetPoint("LEFT", f.min, "RIGHT", 14, 0)
  mgl:SetText("Margin at least")
  f.margin = numberBox(f, 40, 4, function(v) settings().minMargin = v; changed() end)
  f.margin:SetPoint("LEFT", mgl, "RIGHT", 6, 0)
  local pct = text(f, T.font, T.muted)
  pct:SetPoint("LEFT", f.margin, "RIGHT", 4, 0)
  pct:SetText("%")
  local cl = text(f, T.font, T.muted)
  cl:SetPoint("LEFT", pct, "RIGHT", 14, 0)
  cl:SetText("Cost at most")
  f.maxCost = moneyBox(f, 70, "maxCost", "Cost at most")
  f.maxCost:SetPoint("LEFT", cl, "RIGHT", 6, 0)
  if EUI.DropButton then
    f.alts, f.altsText = EUI.DropButton(f, T, 150)
    f.alts:SetHeight(24)
    f.alts:SetPoint("LEFT", f.maxCost, "RIGHT", 14, 0)
    f.alts:SetScript("OnClick", function(self) W.openAlts(self) end)
    f.alts:HookScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
      GameTooltip:SetText("Alts", 1, 1, 1)
      GameTooltip:AddLine("Add the recipes your other characters know (from EverlookDB Crafting). Each row then says who can make it.", nil, nil, nil, true)
      GameTooltip:Show()
    end)
    f.alts:HookScript("OnLeave", function() GameTooltip:Hide() end)
  end
  f.clearFilters = link(f, "Clear filters", function() W.clearFilters() end)
  f.clearFilters:SetPoint("TOPRIGHT", -20, -100)

  -- the list card
  f.list = CreateFrame("Frame", nil, f)
  f.list.fill, f.list.edge = U.RoundBox(f.list, T.radius, T.card, T.divider)
  f.list:SetPoint("TOPLEFT", 16, LIST_TOP)
  f.list:SetPoint("RIGHT", -16, 0)
  local head = CreateFrame("Frame", nil, f.list)
  head:SetHeight(16)
  head:SetPoint("TOPLEFT", PAD, -10)
  head:SetPoint("RIGHT", -PAD, 0)
  f.heads = {}
  -- a heading: click sorts by it, again the other way; the arrow shows the sort
  local function heading(key, label, width, right, left)
    local h = CreateFrame("Button", nil, head)
    h:SetHeight(16)
    if left then
      h:SetPoint("LEFT", head, "LEFT", 24, 0)
      h:SetWidth(width)
    else
      h:SetPoint("RIGHT", head, "RIGHT", -right, 0)
      h:SetWidth(width)
    end
    h.label = text(h, T.fontSmall, T.muted, left and "LEFT" or "RIGHT")
    h.label:SetText(label)
    if left then h.label:SetPoint("LEFT", 0, 0) else h.label:SetPoint("RIGHT", 0, 0) end
    h.arrow = h:CreateTexture(nil, "ARTWORK")
    h.arrow:SetSize(8, 8)
    if left then h.arrow:SetPoint("LEFT", h.label, "RIGHT", 4, 0) else h.arrow:SetPoint("RIGHT", h.label, "LEFT", -4, 0) end
    if not EUI.SetIcon(h.arrow, "chevron") then h.arrow:SetTexture("Interface\\Buttons\\Arrow-Down-Up") end
    h.arrow:Hide()
    h.key = key
    h:SetScript("OnClick", function() W.sortBy(key) end)
    h:SetScript("OnEnter", function(self)
      self.label:SetTextColor(rgba(T.text))
      GameTooltip:SetOwner(self, "ANCHOR_TOP")
      GameTooltip:SetText("Sort by " .. label:lower(), 1, 1, 1)
      GameTooltip:AddLine("Click again for the other way.", nil, nil, nil, true)
      GameTooltip:Show()
    end)
    h:SetScript("OnLeave", function(self) W.paintHeads(); GameTooltip:Hide() end)
    f.heads[key] = h
    return h
  end
  local x = 0
  local function col(key, label, width)
    heading(key, label, width, x)
    x = x + width + GAP
  end
  col("crafts", "CRAFTS", CRAFTS_W)
  col("margin", "MARGIN", MARGIN_W)
  col("profit", "PROFIT", MONEY_W)
  col("sale", "SELLS FOR", MONEY_W)
  col("cost", "COST", MONEY_W)
  col("skill", "SKILL", SKILL_W)
  heading("name", "RECIPE", 120, nil, true)
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
  local pos = settings().pos
  if pos then f:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4]) else f:SetPoint("CENTER", 0, 40) end
  f:Hide()
  W.frame = f
  W.fillBoxes()
  return f
end

-- The headings: the sorted one bright with its arrow (down: high to low).
function W.paintHeads()
  local f = W.frame
  if not f or not f.heads then return end
  local key, desc = W.sortState()
  for k, h in pairs(f.heads) do
    local on = k == key
    h.label:SetTextColor(rgba(on and T.text or T.muted))
    h.arrow:SetShown(on)
    if on then
      h.arrow:SetVertexColor(rgba(T.accent))
      if h.arrow.SetRotation then h.arrow:SetRotation(desc and 0 or math.pi) end
    end
    if on then h.desc = desc else h.desc = nil end
  end
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
  local s = settings()
  if not keep or not W.rows then
    local _, rows, counts, sources = compute()
    local key, desc = W.sortState()
    Pr.sort(rows, key, desc, { nameOf = rowName, crafts = W.crafts })
    W.rows, W.counts = rows, counts
    W.multi = #sources > 1
  end
  local rows, counts = W.rows, W.counts
  W.paintHeads()
  if f.alts then
    f.alts:SetShown(craftAPI() ~= nil)
    f.altsText:SetText(altsLabel())
  end
  f.clearFilters:SetShown(Pr.filtered(s) or s.sort ~= nil)
  local h = d.houses and d.houses[houseKey()]
  local nPrices = 0
  if h and h.items then for _ in pairs(h.items) do nPrices = nPrices + 1 end end
  -- other players' scan (shared prices) counts too, and says so when it is the newer one
  local sh = ns.shared and ns.shared.house(houseKey())
  if sh then for _ in pairs(sh.items) do nPrices = nPrices + 1 end end
  local pricesAt, shared = nil, false
  if ns.pricesAt then pricesAt, shared = ns.pricesAt(houseKey():match("%-(%a+)$")) end
  local _, side = houseKey():match("^(.*)%-(%a+)$")
  local where = side and (side .. " auction house") or "your auction house"
  local whose = W.multi and "you and your alts know" or "you know"
  if nPrices == 0 then
    f.sub:SetText(("From the %d recipes %s. No prices yet for the %s."):format(counts.known, whose, where))
    f.sub:SetTextColor(rgba(T.danger))
  else
    local when = shared and ("other players' scan " .. ns.ago(pricesAt))
      or (h and h.scanned) and ("full update " .. ns.ago(h.scanned)) or "no full update yet"
    f.sub:SetText(("From the %d recipes %s, at the %s's prices (%s), after its %d%% cut."):format(counts.known, whose, where,
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
    elseif Pr.filtered(s) and counts.noSale < counts.known then
      f.empty:SetText("No recipe matches these filters. Loosen one, or click Clear filters to see them all.")
    elseif nPrices == 0 then
      f.empty:SetText("No auction prices yet. Open the auction house: prices update by themselves while it is open (or type /eah scan there).")
    else
      f.empty:SetText("No recipe has an auction price for what it makes yet.")
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
  if #rows > ROWS then
    f.pos:SetText(("%d-%d of %d"):format(W.offset + 1, W.offset + shown, #rows))
  else
    f.pos:SetText(#rows > 0 and ("%d %s"):format(#rows, #rows == 1 and "recipe" or "recipes") or "")
  end
  local listH = -(y - 8 - 16 - 10)
  f.list:SetHeight(listH)

  local by = LIST_TOP - listH - 14
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

-- A page of the main window (Hub.lua); a window of its own only when that window couldn't be made.
function W.open()
  W.status = nil
  if ns.hub and ns.hub.open("crafts") then return end
  local f = makeFrame()
  if not f then return end
  f:Show()
  W.render()
end
function W.toggle()
  if ns.hub and ns.hub.ready then
    if ns.hub.isOpen("crafts") then ns.hub.close() else W.open() end
    return
  end
  local f = makeFrame()
  if f and f:IsShown() then f:Hide() else W.open() end
end

-- Into the main window's page, as wide as the page; out of sight when another page takes its place.
function W.dock(holder)
  local f = makeFrame()
  if not f or not ns.hub then return end
  ns.hub.dock(f, holder)
  W.docked = holder
  f:SetWidth(math.max(WIDTH, math.floor((holder:GetWidth() or WIDTH) + 0.5)))
  f.gear:ClearAllPoints()
  f.gear:SetPoint("TOPRIGHT", -14, -10)
  f:Show()
  W.render()
end
function W.undock() if W.frame then W.frame:Hide() end end
function W.refresh() if W.frame and W.frame:IsShown() then W.render() end end

---------------------------------------------------------------------------------------------------------------------
-- The command and the settings page, added to the /eah app once Options.lua has made it.

local FILTER_WORDS = { "profit", "crafting", "filter", "search", "recipes", "sort", "column", "skill", "margin", "percent",
  "cost", "maximum", "gold", "silver", "copper", "money", "coins", "can make", "bags", "materials", "alts", "alt",
  "characters", "professions", "clear filters" }
local function words(extra)
  local out = {}
  for _, w in ipairs(extra) do out[#out + 1] = w end
  for _, w in ipairs(FILTER_WORDS) do out[#out + 1] = w end
  return out
end

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
  -- silver, as it always was (the page's box takes gold and copper too; both write the same copper amount)
  app:Setting({
    key = "profitmin", type = "number", label = "Show recipes making at least this much profit (silver)", min = 0, max = 1000, step = 5,
    chatLabel = "Profit: minimum", keywords = words({ "minimum", "least", "at least" }),
    get = function() return math.floor((settings().min or 0) / 100) end,
    set = function(v)
      v = math.max(0, math.floor(tonumber(v) or 0))
      settings().min = v > 0 and v * 100 or nil
      if W.frame then W.frame.min:SetText(v > 0 and Pr.moneyText(v * 100) or "") end
    end,
    after = W.refresh,
  })
  app:Command("profit", "profit", "the recipes you know that sell for more than their materials cost (works anywhere)",
    function() W.toggle() end, { "profits", "craftprofit", "flip" })
  app:Section("profit", "Crafting", function(stack)
    local EU = EUI
    EU.Header(stack, "Crafting", "The crafting cost box beside your profession window, and Crafting profit: the recipes you know whose result sells for more than its materials cost, after the cut (/eah profit).")
    if app:GetSetting("crafting") then app:Widget(stack, "crafting") end
    EU.Header(stack, "Crafting profit")
    EU.ButtonRow(stack, {
      { label = "Open Crafting profit", width = 170, onClick = function() W.open() end,
        desc = "The list of your profitable recipes, with a shopping list for the crafts you plan. Sort by any column; filter by name, skill, profit, margin, cost, what you can make now and your alts' recipes.",
        keywords = words({ "finder", "open", "flip" }) },
      { label = "Clear filters", width = 120, onClick = function() W.clearFilters() end,
        desc = "Puts Crafting profit's filters and sort back: every recipe, best profit first.",
        keywords = words({ "reset" }) },
    })
    app:Widget(stack, "profitcraft")
    app:Widget(stack, "profitmin")
    EU.Note(stack, "Prices are your last scan of the auction house; nothing is guessed. A material without an AH price shows ≈ (the real profit is lower), and a recipe whose result has no price is left out. Open each profession window once so the addon knows your recipes; with EverlookDB Crafting, your alts' recipes can be added too (Alts, on the page).")
  end, { icon = "wrench" })
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("BAG_UPDATE_DELAYED")
ev:SetScript("OnEvent", function(_, event, name)
  if event == "BAG_UPDATE_DELAYED" then
    -- "Only what I can make now" follows your bags
    if settings().canMake then W.refresh() end
    return
  end
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
