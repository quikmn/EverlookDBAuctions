-- EverlookDB Auctions: crafting cost beside the profession window.
--   For the recipe you pick: each material with how many it takes and its lowest auction price, what the materials
--   cost together, what the result sells for (and what disenchanting it is worth, for gear), and the profit after
--   the auction house's 5% cut. Recipes come from the game itself (C_TradeSkillUI); prices are the saved ones for
--   your faction's auction house, so it works away from the auction house too. Nothing is crafted or bought here.
--   db.craft = false hides it (Options, General).
local _, ns = ...
local UI, T = ns.UI, ns.T
local C = {}
local MAX_ROWS = 8

local function try(fn, ...)
  if type(fn) ~= "function" then return nil end
  local okCall, a = pcall(fn, ...)
  if okCall then return a end
end

local function enabled()
  local db = ns.db and ns.db()
  return db and db.craft ~= false
end

local function priceOf(id)
  local it = ns.itemFor and ns.itemFor(id)
  return it and it[1], it and it[4]
end

local function nameOf(id)
  return try(C_Item.GetItemNameByID, id) or ("item " .. id)
end

-- What the picked recipe costs and makes: { mats = { { id, need, price } }, cost, unpriced, out, each, makes, de }.
local function work(recipeID)
  local sc = C_TradeSkillUI and try(C_TradeSkillUI.GetRecipeSchematic, recipeID, false)
  if not sc then return nil end
  local w = { mats = {}, cost = 0, unpriced = 0 }
  for _, slot in ipairs(sc.reagentSlotSchematics or {}) do
    local r = slot.reagents and slot.reagents[1]
    local need = ns.ok(slot.quantityRequired) or 0
    if r and r.itemID and need > 0 and not slot.hiddenInCraftingForm then
      local p = priceOf(r.itemID)
      w.mats[#w.mats + 1] = { r.itemID, need, p }
      if p then w.cost = w.cost + p * need else w.unpriced = w.unpriced + 1 end
    end
  end
  w.out = ns.ok(sc.outputItemID)
  w.makes = ((sc.quantityMin or 1) + (sc.quantityMax or sc.quantityMin or 1)) / 2
  if w.out then
    w.each = priceOf(w.out)
    w.de = ns.disenchantValue and ns.disenchantValue(w.out)
  end
  return w
end

local function render()
  local f = C.frame
  if not f then return end
  local form = ProfessionsFrame and ProfessionsFrame.CraftingPage and ProfessionsFrame.CraftingPage.SchematicForm
  local info = form and form.GetRecipeInfo and try(form.GetRecipeInfo, form)
  local w = enabled() and info and info.recipeID and work(info.recipeID)
  if not w or #w.mats == 0 then f:Hide(); return end
  local money = ns.money
  for i, row in ipairs(f.rows) do
    local m = w.mats[i]
    row:SetShown(m ~= nil)
    if m then
      row.name:SetText(("%s%s|r  %sx%d|r"):format(ns.qualityHex(try(C_Item.GetItemQualityByID, m[1])), nameOf(m[1]),
        UI.hex(T.mute), m[2]))
      row.price:SetText(m[3] and money(m[3] * m[2]) or (UI.hex(T.mute) .. "no price|r"))
      row.id = m[1]
    end
  end
  local shown = math.min(#w.mats, MAX_ROWS)
  f.summary:ClearAllPoints()
  f.summary:SetPoint("TOPLEFT", 1, -40 - shown * 20 - 6)
  f.summary:SetPoint("RIGHT", -1, 0)
  local s = f.summary
  s.cost:SetText(money(w.cost) .. (w.unpriced > 0 and (UI.hex(T.bad) .. (" + %d without a price|r"):format(w.unpriced)) or ""))
  local value = w.each and math.floor(w.each * w.makes)
  s.value:SetText(value and money(value) or (UI.hex(T.mute) .. "no price|r"))
  s.deLine:SetShown(w.de ~= nil)
  s.de:SetShown(w.de ~= nil)
  if w.de then s.de:SetText(money(w.de)) end
  -- profit goes under the last line shown
  local py = w.de and -66 or -48
  s.profit:SetPoint("TOPRIGHT", -10, py)
  s.profitLine:SetPoint("TOPLEFT", 10, py)
  if value and w.unpriced == 0 then
    local profit = math.floor(value * 0.95) - w.cost
    s.profit:SetText((profit >= 0 and UI.hex(T.good) or UI.hex(T.bad)) .. (profit < 0 and "-" or "") .. money(math.abs(profit)) .. "|r")
  else
    s.profit:SetText(UI.hex(T.mute) .. "-|r")
  end
  f:SetHeight(40 + shown * 20 + 6 + (w.de and 86 or 68))
  f:Show()
end

local function makeFrame()
  local pf = _G.ProfessionsFrame
  if C.frame or not pf then return C.frame end
  local f = UI.own(CreateFrame("Frame", "EverlookAuctionsCrafting", pf))
  f:SetWidth(240)
  f:SetPoint("TOPLEFT", pf, "TOPRIGHT", 6, -24)
  f:SetFrameStrata(pf:GetFrameStrata())
  f:EnableMouse(true)
  UI.panel(f, T.bg, T.edge)
  UI.shadow(f, 5)
  local band = f:CreateTexture(nil, "BACKGROUND", nil, -7)
  band:SetPoint("TOPLEFT", 1, -1)
  band:SetPoint("TOPRIGHT", -1, -1)
  band:SetHeight(28)
  UI.shade(band, T.raised, UI.LIFT)
  local title = UI.text(f, "title")
  title:SetPoint("LEFT", band, "LEFT", 10, 0)
  title:SetText("Crafting cost")
  local sub = UI.text(f, "mute")
  sub:SetPoint("RIGHT", band, "RIGHT", -10, 0)
  sub:SetText("lowest AH prices")

  f.rows = {}
  for i = 1, MAX_ROWS do
    local row = UI.row(f, 20)
    row:SetPoint("TOPLEFT", 1, -36 - (i - 1) * 20)
    row:SetPoint("RIGHT", -1, 0)
    row.price = UI.text(row, "small")
    row.price:SetPoint("RIGHT", -10, 0)
    row.price:SetJustifyH("RIGHT")
    row.name = UI.text(row, "small")
    row.name:SetPoint("LEFT", 10, 0)
    row.name:SetPoint("RIGHT", row.price, "LEFT", -6, 0)
    row:SetScript("OnEnter", function(self)
      if not self.id then return end
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      pcall(GameTooltip.SetItemByID, GameTooltip, self.id)
      GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    f.rows[i] = row
  end

  local s = CreateFrame("Frame", nil, f)
  s:SetHeight(100)
  local line = UI.line(s, true)
  line:SetPoint("TOPLEFT", 0, 0)
  line:SetPoint("TOPRIGHT", 0, 0)
  local y = -8
  local function pair(label, kind)
    local l = UI.text(s, "dim")
    l:SetPoint("TOPLEFT", 10, y)
    l:SetText(label)
    local v = UI.text(s, kind or "body")
    v:SetPoint("TOPRIGHT", -10, y)
    v:SetJustifyH("RIGHT")
    y = y - 18
    return v, l
  end
  s.cost = pair("Materials")
  s.value = pair("Sells for")
  s.de, s.deLine = pair("Disenchant (estimate)")
  s.profit, s.profitLine = pair("Profit after the 5% cut", "title")
  f.summary = s
  f:Hide()
  C.frame = f
  return f
end

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

local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("TRADE_SKILL_SHOW")
ev:SetScript("OnEvent", function(_, e, name)
  if e == "ADDON_LOADED" and name ~= "Blizzard_Professions" then return end
  hook()
  if e == "TRADE_SKILL_SHOW" then C_Timer.After(0.1, render) end
end)
