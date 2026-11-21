-- EverlookDB Auctions: the Upgrades tab. A bottom tab at the auction house (beside Quick sell and Shopping), and the
-- same view in a window of its own away from it (/eah up). From the last full scan (our own or the shared one):
--   header    last scan's age and whose it is, how many gear items it has and how many are upgrades
--   specs     one button per spec of the class: shop for another spec than the ones you gear for
--   filters   max price per item, smallest upgrade in %, rich mode (biggest upgrade, else most upgrade per gold)
--   slots     the paper doll: per slot the best upgrade within the max price; click one for its other options
--   options   the slot's upgrades, best first ("BEST" on the first); right-click finds it in Buy, Shift-click links it
--   summary   "Best upgrade in every slot: N items for <total>" and the gold Make shopping list (the Shopping tab's
--             lists, Shopping.lua)
-- Scoring runs in small batches over frames (Upgrades.lua) and waits while you're in combat.
local ADDON, ns = ...
local UI, T = ns.UI, ns.T
local U = ns.up

local V = {}
ns.upgradesView = V

local PLACE = T.places.upgrades
local GOOD = T.good
local CARD_H, CARD_W = 44, 206

local function plain(t) return (tostring(t or ""):gsub("|", "||")) end
local function money(c) return ns.money and ns.money(c) or tostring(c) end

local function qualityHex(q)
  local c = q and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q]
  if c and c.hex then return c.hex end
  if c and c.r then return UI.hex({ c.r, c.g, c.b }) end
  return UI.hex(T.text)
end

-- The spec shown: the one picked on the tab, else the first ticked one.
function V.spec()
  local c = U.char()
  local s = c.shown and U.spec(c.shown)
  return s or U.ticked()[1]
end

local function linkOf(e)
  local okL, _, link = pcall(C_Item.GetItemInfo, U.linkOf(e.id, e.suffix))
  return okL and link or nil
end

-- Right-click: the item in Advanced search on the Buy tab, with its live auctions.
local function findInBuy(e)
  if not (_G.AuctionHouseFrame and AuctionHouseFrame:IsShown()) then
    V.status("Open the auction house to buy it. " .. plain(e.name) .. " was " .. money(e.price) .. " in the last scan.", T.dim)
    return
  end
  if ns.openSearch then ns.openSearch() end
  if ns.query and ns.recipeList then ns.query(ns.recipeList.query(e.name)) end
end

local function itemClick(e, button)
  if not e then return end
  if button == "RightButton" then findInBuy(e); return true end
  if IsShiftKeyDown and IsShiftKeyDown() then
    local link = linkOf(e)
    if link and ChatEdit_InsertLink then ChatEdit_InsertLink(link) end
    return true
  end
end

local function itemTip(owner, e)
  if not e then return end
  GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
  local okT = pcall(GameTooltip.SetHyperlink, GameTooltip, U.linkOf(e.id, e.suffix))
  if not okT then GameTooltip:SetText(e.name) end
  GameTooltip:AddLine("Right-click: find it in Buy.  Shift-click: link it in chat.", T.dim[1], T.dim[2], T.dim[3], true)
  GameTooltip:Show()
end

---------------------------------------------------------------------------------------------------------------------
-- Text for a slot

local function upText(e)
  if not e then return "" end
  if e.cmp.note == "empty" then return "new slot" end
  return ("%+.0f%%"):format(e.cmp.pct or 0)
end

-- What a slot without a pick says.
function V.slotWhy(slot)
  if slot.nextLevel and slot.usable > 0 and slot.better == 0 then
    return ("Next upgrade needs level %d"):format(slot.nextLevel)
  end
  if slot.twohand then return "You wear a two-hander" end
  if (slot.overMax or 0) > 0 and slot.better == 0 then
    return ("%d over your max price"):format(slot.overMax)
  end
  if slot.usable == 0 then return "Nothing you can use" end
  return ("%d on the AH, none better than yours"):format(slot.usable)
end

---------------------------------------------------------------------------------------------------------------------
-- The frame

local F

local function setStatus(text, color)
  if not F then return end
  F.status:SetText(text or "")
  F.status:SetTextColor(unpack(color or T.dim))
end
V.status = setStatus

local render

local function makeCard(parent, group)
  local b = UI.row(parent, CARD_H)
  b:SetWidth(CARD_W)
  UI.panel(b, T.surface, T.edge)
  b.group = group
  b.icon = UI.icon(b, 30)
  b.icon:SetPoint("LEFT", 7, 0)
  b.slot = UI.text(b, "head")
  b.slot:SetPoint("TOPLEFT", b.icon, "TOPRIGHT", 8, 1)
  b.slot:SetText(U.SLOT_NAME[group]:upper())
  b.pct = UI.text(b, "body")
  b.pct:SetPoint("TOPRIGHT", -8, -6)
  b.pct:SetJustifyH("RIGHT")
  b.price = UI.text(b, "small")
  b.price:SetPoint("RIGHT", b.pct, "LEFT", -8, 0)
  b.price:SetJustifyH("RIGHT")
  b.name = UI.text(b, "small")
  b.name:SetPoint("BOTTOMLEFT", b.icon, "BOTTOMRIGHT", 8, 0)
  b.name:SetPoint("RIGHT", b, "RIGHT", -8, 0)
  b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  b:SetScript("OnClick", function(self, button)
    if itemClick(self.best, button) then return end
    V.sel = self.group
    render()
  end)
  b:SetScript("OnEnter", function(self) if self.best then itemTip(self, self.best) end end)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)
  return b
end

local function fillCard(b, slot)
  local e = slot and slot.best
  b.best = e
  b:EdbSelect(V.sel == b.group)
  if e then
    b.icon:EdbSet(e.icon, e.quality)
    b.icon:SetAlpha(1)
    b.name:SetText(qualityHex(e.quality) .. plain(e.name) .. "|r")
    b.pct:SetText(UI.hex(GOOD) .. upText(e) .. "|r")
    b.price:SetText(money(e.price))
  else
    b.icon:EdbSet(nil)
    b.icon:SetAlpha(0.5)
    b.name:SetText(UI.hex(T.mute) .. (slot and V.slotWhy(slot) or "") .. "|r")
    b.pct:SetText("")
    b.price:SetText("")
  end
end

local function buildOption(L)
  local b = UI.row(L, 24)
  b.icon = UI.icon(b, 18)
  b.icon:SetPoint("LEFT", 6, 0)
  b.best = UI.badge(b, 34, 15)
  b.best:SetPoint("RIGHT", -6, 0)
  b.price = UI.text(b, "small")
  b.price:SetPoint("RIGHT", b.best, "LEFT", -6, 0)
  b.price:SetJustifyH("RIGHT")
  b.price:SetWidth(66)
  b.pct = UI.text(b, "small")
  b.pct:SetPoint("RIGHT", b.price, "LEFT", -4, 0)
  b.pct:SetJustifyH("RIGHT")
  b.pct:SetWidth(44)
  b.name = UI.text(b, "small")
  b.name:SetPoint("LEFT", b.icon, "RIGHT", 6, 0)
  b.name:SetPoint("RIGHT", b.pct, "LEFT", -4, 0)
  b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  b:SetScript("OnClick", function(self, button) itemClick(self.item, button) end)
  b:SetScript("OnEnter", function(self) itemTip(self, self.item) end)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)
  return b
end

local function fillOption(b, e, i)
  b.icon:EdbSet(e.icon, e.quality)
  b.name:SetText(qualityHex(e.quality) .. plain(e.name) .. "|r")
  b.pct:SetText(UI.hex(GOOD) .. upText(e) .. "|r")
  b.price:SetText(money(e.price))
  b.best:EdbSet(i == 1 and "BEST" or nil, T.accent)
  b.best:SetShown(i == 1)
  b:EdbStripe(i % 2 == 0)
end

-- The spec buttons: the specs and builds you gear for, the one shown, and "Other" to step through the rest of the
-- class's specs and levelling builds.
local function layoutSpecs(f)
  local shown = V.spec()
  local c = U.char()
  local x = 0
  for _, b in ipairs(f.specs) do
    local on = c.specs[b.spec.key] or (shown and shown.key == b.spec.key) or (not next(c.specs) and not b.spec.build)
    b:SetShown(on and true or false)
    if on then
      b:ClearAllPoints()
      b:SetPoint("LEFT", x, 0)
      x = x + b:GetWidth() + 4
    end
  end
  f.other:ClearAllPoints()
  f.other:SetPoint("LEFT", x, 0)
  f.specBar:SetWidth(math.max(1, x + f.other:GetWidth()))
end

local function makeSpecButtons(f)
  f.specs = {}
  for _, s in ipairs(U.specs()) do
    local w = math.max(56, math.min(220, #s.name * 7 + 18))
    local b = UI.button(f.specBar, s.name, w, 20, "small")
    b.spec = s
    b:SetScript("OnClick", function(self)
      U.char().shown = self.spec.key
      V.refresh()
    end)
    UI.tip(b, "Upgrades for " .. s.name, function()
      return (s.note and (s.note .. " ") or "") .. (U.char().specs[s.key] and "You gear for this." or "You don't gear for this (tick it in /eah up spec or the settings); shown to shop for it.")
    end)
    f.specs[#f.specs + 1] = b
  end
  f.other = UI.button(f.specBar, "Other...", 64, 20, "quiet")
  f.other:SetScript("OnClick", function()
    -- the next spec or build after the shown one
    local list, cur = U.specs(), V.spec()
    local i = 0
    for k, s in ipairs(list) do if cur and s.key == cur.key then i = k end end
    local nxt = list[i % #list + 1]
    if nxt then U.char().shown = nxt.key; V.refresh() end
  end)
  UI.tip(f.other, "Other specs and levelling builds", "Shows the next spec or build of your class, to shop for it.")
end

local function make(parent)
  if F then return F end
  local f = UI.own(CreateFrame("Frame", "EverlookAuctionsUpgrades", parent))
  f:EnableMouse(true)
  UI.place(f, "upgrades")
  UI.panel(f, T.bg, T.edge)
  UI.placeEdge(f, PLACE)
  f:Hide()
  F = f

  f.title = UI.text(f, "title")
  f.title:SetPoint("TOPLEFT", 12, -12)
  f.title:SetText("Gear upgrades")
  f.title:SetTextColor(unpack(PLACE))
  f.specBar = CreateFrame("Frame", nil, f)
  f.specBar:SetHeight(20)
  f.specBar:SetPoint("LEFT", f.title, "RIGHT", 14, 0)
  makeSpecButtons(f)

  f.head = UI.text(f, "dim")
  f.head:SetPoint("TOPLEFT", 12, -36)
  f.head:SetPoint("RIGHT", f, "RIGHT", -320, 0)

  -- filters, top right
  f.rich = UI.check(f, "Rich mode", function(_, on) U.set("rich", on); V.refresh() end)
  f.rich:SetPoint("TOPRIGHT", -12, -32)
  UI.tip(f.rich, "Rich mode", "On: the biggest upgrade within your max price. Off: the most upgrade per gold.")
  f.min = UI.input(f, 40, 20, { hint = "0", max = 3, numeric = true, right = true })
  f.min:SetPoint("RIGHT", f.rich, "LEFT", -18, 0)
  local minL = UI.label(f, "MIN %")
  minL:SetPoint("RIGHT", f.min, "LEFT", -6, 0)
  f.max = UI.input(f, 74, 20, { hint = "any", max = 14 })
  f.max:SetPoint("RIGHT", minL, "LEFT", -12, 0)
  local maxL = UI.label(f, "MAX PRICE")
  maxL:SetPoint("RIGHT", f.max, "LEFT", -6, 0)
  local function saveFilters()
    local m = (f.max:GetText() or ""):match("^%s*(.-)%s*$")
    if m == "" or m == "any" then
      U.set("max", nil)
    else
      local c = U.parseMoney(m)
      if c then U.set("max", c) else setStatus("Max price: type it like 25g, 5s or 1g 50s.", T.bad) end
    end
    U.set("min", tonumber(f.min:GetText()) or 0)
    V.refresh()
  end
  for _, box in ipairs({ f.max, f.min }) do
    box:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    box:HookScript("OnEditFocusLost", saveFilters)
  end
  UI.tip(f.max, "Max price per item", "Upgrades that cost more aren't suggested. 25g, 5s or 1g 50s; empty for any price.")
  UI.tip(f.min, "Smallest upgrade", "Upgrades smaller than this many percent aren't shown.")

  -- slots, two columns like the character window
  f.cards = {}
  local area = CreateFrame("Frame", nil, f)
  area:SetPoint("TOPLEFT", 10, -60)
  area:SetSize(CARD_W * 2 + 8, CARD_H * 8 + 7 * 4)
  for i, g in ipairs(U.ORDER) do
    local c = makeCard(area, g)
    local col, row = (i <= 8) and 0 or 1, (i <= 8) and (i - 1) or (i - 9)
    c:SetPoint("TOPLEFT", col * (CARD_W + 8), -row * (CARD_H + 4))
    f.cards[g] = c
  end

  -- the picked slot's options
  local R = UI.panel(CreateFrame("Frame", nil, f), T.surface, T.edge)
  R:SetPoint("TOPLEFT", area, "TOPRIGHT", 10, 0)
  R:SetPoint("BOTTOMRIGHT", -10, 44)
  f.optTitle = UI.text(R, "title")
  f.optTitle:SetPoint("TOPLEFT", 10, -10)
  f.optTitle:SetPoint("RIGHT", -10, 0)
  f.optTitle:SetTextColor(unpack(PLACE))
  f.optNote = UI.text(R, "dim")
  f.optNote:SetPoint("TOPLEFT", 10, -28)
  f.optNote:SetPoint("RIGHT", -10, 0)
  f.optNote:SetWordWrap(true)
  local band = UI.headerBand(R, 18)
  band:SetPoint("TOPLEFT", 1, -64)
  band:SetPoint("TOPRIGHT", -1, -64)
  local l1 = UI.label(band, "ITEM")
  l1:SetPoint("LEFT", 30, 0)
  local l2 = UI.label(band, "UPGRADE · PRICE")
  l2:SetPoint("RIGHT", -46, 0)
  f.opts = UI.list(R, 24, buildOption, fillOption)
  f.opts:SetPoint("TOPLEFT", 1, -82)
  f.opts:SetPoint("BOTTOMRIGHT", -3, 4)

  -- summary and the one gold button
  f.make = UI.button(f, "Make shopping list", 150, 26, "primary")
  f.make:SetPoint("BOTTOMRIGHT", -10, 10)
  f.make:SetScript("OnClick", function() V.makeList() end)
  UI.tip(f.make, "Make a shopping list", "Saves the best upgrade of every slot as a list in the Shopping tab, to search and buy one by one.")
  f.sum = UI.text(f, "body")
  f.sum:SetPoint("BOTTOMLEFT", 12, 24)
  f.sum:SetPoint("RIGHT", f.make, "LEFT", -12, 0)
  f.status = UI.text(f, "dim")
  f.status:SetPoint("BOTTOMLEFT", 12, 9)
  f.status:SetPoint("RIGHT", f.make, "LEFT", -12, 0)

  f:SetScript("OnShow", function() V.refresh() end)
  return f
end

local function ageText(r)
  local at = r.at
  if not at then return "" end
  if r.source == "shared" and ns.shared and ns.shared.localAt then
    local okA, l = pcall(ns.shared.localAt, r.scan)
    if okA and l then at = l end
  end
  return ns.ago and ns.ago(at) or ""
end

function render()
  local f = F
  if not f or not f:IsShown() then return end
  local spec = V.spec()
  layoutSpecs(f)
  for _, b in ipairs(f.specs) do b:EdbActive(spec and b.spec.key == spec.key) end
  if not f.max:HasFocus() then f.max:SetText(U.get("max") and U.moneyShort(U.get("max")) or "") end
  if not f.min:HasFocus() then f.min:SetText((tonumber(U.get("min")) or 0) > 0 and tostring(U.get("min")) or "") end
  f.rich:EdbChecked(U.get("rich"))
  local r = U.result
  if not r or not spec or r.spec ~= spec then
    f.head:SetText("Reading the last scan…")
    for _, g in ipairs(U.ORDER) do fillCard(f.cards[g], nil) end
    f.opts:SetItems({})
    f.sum:SetText("")
    f.make:Disable()
    return
  end
  if r.none then
    f.head:SetText("No scan yet: open the auction house and let it update prices, or run the EverlookDB App for shared prices.")
  else
    local who = r.source == "shared" and "other players (shared prices)" or "you"
    local busy = not r.done and (" · reading %d%%"):format((r.progress or 0) * 100) or ""
    local _, _, from, _, meta = U.weights(spec)
    local est = (from == "built-in" and meta and meta.src == "estimate") and " · weights: estimates at your level" or ""
    f.head:SetText(("Last scan %s by %s · %s gear items · %s upgrades%s%s"):format(ageText(r), who,
      ns.num and ns.num(r.gear) or r.gear, ns.num and ns.num(r.upgrades) or r.upgrades, est, busy))
  end
  for _, g in ipairs(U.ORDER) do fillCard(f.cards[g], r.slots[g]) end
  local sel = V.sel or "head"
  local slot = r.slots[sel]
  local n = slot and #slot.list or 0
  f.optTitle:SetText(("%s: %d %s"):format(U.SLOT_NAME[sel], n, n == 1 and "upgrade" or "upgrades"))
  local note
  if slot and #slot.list == 0 then
    note = slot.usable == 0 and "Nothing for this slot on the AH that you can use."
      or slot.twohand and "You wear a two-handed weapon: an off-hand would need a one-hander too."
      or (slot.nextLevel and ("%d items for this slot on the AH, none better than yours at your level. Next upgrade needs level %d."):format(slot.usable, slot.nextLevel))
      or ("%d items for this slot on the AH, none better than yours%s."):format(slot.usable,
        (slot.overMax or 0) > 0 and (" within your max price (" .. slot.overMax .. " over it)") or "")
  elseif slot then
    local best = slot.best
    local vs = best and best.cmp.vs and best.cmp.vs.link
    note = (U.get("rich") and "Biggest first" or "Most per gold first")
      .. (best and U.whyText(best.cmp, 2) and (". Best: " .. U.whyText(best.cmp, 2)) or "") .. "."
      .. (vs and ("\nAgainst " .. vs) or (best and best.cmp.note == "empty" and "\nYou wear nothing there." or ""))
  end
  f.optNote:SetText(note or "")
  f.opts.empty:SetText("")
  f.opts:SetItems(slot and slot.list or {})
  if r.count and r.count > 0 then
    f.sum:SetText(("Best upgrade in every slot: %d %s for %s"):format(r.count, r.count == 1 and "item" or "items", money(r.total)))
    f.make:Enable()
  else
    f.sum:SetText(r.done and "No upgrades within your filters." or "")
    f.make:Disable()
  end
end
V.render = function() render() end

-- Scores the newest scan again for the shown spec (in the background) and redraws.
function V.refresh()
  if not F or not F:IsShown() then return end
  local spec = V.spec()
  if not spec then render(); return end
  U.onProgress = function() render() end
  U.collect(spec, function() render() end)
  render()
  if InCombatLockdown and InCombatLockdown() then setStatus("Waiting for combat to end before reading the scan.", T.dim) end
end

-- The best upgrade per slot as a shopping list ("Gear upgrades: Fury"), in the Shopping tab.
function V.makeList()
  local r = U.result
  if not r or not r.count or r.count == 0 then return end
  local rows = {}
  for _, g in ipairs(U.ORDER) do
    local e = r.slots[g].best
    if e then rows[#rows + 1] = { name = e.name, buy = 1, tick = true } end
  end
  local d = ns.db and ns.db()
  if not d or not ns.recipeList then return end
  d.lists = d.lists or {}
  local name = "Gear upgrades: " .. (r.spec and r.spec.name or "")
  local l, isNew = ns.recipeList.save(d.lists, name, rows)
  if not l then return end
  for i, x in ipairs(d.lists) do if x == l then d.listSel = i end end
  if ns.shoppingRefresh then pcall(ns.shoppingRefresh) end
  setStatus(("%s list %s with %d items. Open the Shopping tab to search them."):format(isNew and "Made the" or "Updated the",
    plain(name), #rows), GOOD)
end

---------------------------------------------------------------------------------------------------------------------
-- Where it shows: the auction house tab, or its own window away from it

local tab, win

local function closeTab()
  if not F or not F:IsShown() or F:GetParent() ~= _G.AuctionHouseFrame then return end
  F:Hide()
  if tab then pcall(PanelTemplates_DeselectTab, tab) end
  if ns.blizzardTabs then ns.blizzardTabs(true) end
  if ns.ahTitle then ns.ahTitle(nil) end
end
V.closeTab = closeTab

local function place(parent, inAH)
  local f = make(parent)
  f:SetParent(parent)
  f:ClearAllPoints()
  if inAH then
    f:SetFrameLevel(parent:GetFrameLevel() + 150)
    f:SetPoint("TOPLEFT", parent, "TOPLEFT", 2, -24)
    f:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -2, (ns.BAR_H or 0) + 2)   -- the price bar and tabs stay visible
  else
    f:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -26)
    f:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 0, 0)
  end
  return f
end

function V.openTab()
  local ah = _G.AuctionHouseFrame
  if not ah then return end
  if win then win:Hide() end
  local f = place(ah, true)
  if ns.closeSearch then ns.closeSearch() end
  if ns.closeSelling then ns.closeSelling() end
  if ns.closeOthers then ns.closeOthers("upgrades") end
  if ns.blizzardTabs then ns.blizzardTabs(false) end
  if tab then pcall(PanelTemplates_SelectTab, tab) end
  if ns.raise then ns.raise(f) end
  f:Show()
  if ns.ahTitle then ns.ahTitle("Gear upgrades", PLACE) end
  if ns.noteTab then ns.noteTab("upgrades") end
  if PlaySound and SOUNDKIT and SOUNDKIT.IG_CHARACTER_INFO_TAB then pcall(PlaySound, SOUNDKIT.IG_CHARACTER_INFO_TAB) end
  if ns.upAsk then ns.upAsk() end
end

-- Away from the auction house: a movable window (it closes only itself; Escape closes it).
local function makeWindow()
  if win then return win end
  local w = UI.own(CreateFrame("Frame", "EverlookAuctionsUpgradesWindow", UIParent))
  w:SetSize(800, 520)
  w:SetPoint("CENTER", 0, 40)
  w:SetFrameStrata("HIGH")
  w:SetToplevel(true)
  w:SetClampedToScreen(true)
  w:SetMovable(true)
  w:EnableMouse(true)
  w:RegisterForDrag("LeftButton")
  w:SetScript("OnDragStart", function(self) self:StartMoving() end)
  w:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local d = U.db()
    if d then local p, _, rp, x, y = self:GetPoint(); d.winPos = { p, rp, x, y } end
  end)
  UI.panel(w, T.bg, T.edgeHi)
  if UI.shadow then UI.shadow(w) end
  local title = UI.text(w, "title")
  title:SetPoint("TOPLEFT", 12, -8)
  title:SetText("EverlookDB Auctions · Gear upgrades from the last scan")
  local close = UI.button(w, "Close", 60, 18, "small")
  close:SetPoint("TOPRIGHT", -6, -4)
  close:SetScript("OnClick", function() w:Hide() end)
  if UISpecialFrames then tinsert(UISpecialFrames, "EverlookAuctionsUpgradesWindow") end
  local d = U.db()
  if d and type(d.winPos) == "table" then
    w:ClearAllPoints()
    pcall(w.SetPoint, w, d.winPos[1], UIParent, d.winPos[2], d.winPos[3], d.winPos[4])
  end
  w:Hide()
  win = w
  return w
end

function V.openWindow()
  local w = makeWindow()
  local f = place(w, false)
  w:Show()
  f:Show()
  V.refresh()
  if ns.upAsk then ns.upAsk() end
end

-- /eah up: the tab at the auction house, else the window.
function V.open()
  if _G.AuctionHouseFrame and AuctionHouseFrame:IsShown() then
    if not tab and ns.makeTab then tab = ns.makeTab("EverlookAuctionsUpgradesTab", "Upgrades", V.openTab, closeTab, "upgrades") end
    V.openTab()
  else
    V.openWindow()
  end
end

-- The other tabs close this one (Shopping.lua's closeOthers is the shared hook).
local prevClose = ns.closeOthers
function ns.closeOthers(except)
  if prevClose then prevClose(except) end
  if except ~= "upgrades" then closeTab() end
end

U.onChange(function() if F and F:IsShown() then V.refresh() end end)

if CreateFrame then
  local ev = CreateFrame("Frame")
  ev:RegisterEvent("AUCTION_HOUSE_SHOW")
  ev:RegisterEvent("AUCTION_HOUSE_CLOSED")
  ev:SetScript("OnEvent", function(_, e)
    if e == "AUCTION_HOUSE_CLOSED" then
      closeTab()
      return
    end
    -- after the Shopping tab (0.3 s after the auction house opens)
    C_Timer.After(0.4, function()
      if not (_G.AuctionHouseFrame and AuctionHouseFrame:IsShown()) then return end
      if not tab and ns.makeTab then tab = ns.makeTab("EverlookAuctionsUpgradesTab", "Upgrades", V.openTab, closeTab, "upgrades") end
      if win and win:IsShown() then win:Hide() end
      local d = ns.db and ns.db()
      if d and (d.openOn or "last") == "last" and d.lastTab == "upgrades" then V.openTab() end
      if ns.upAsk then ns.upAsk() end
    end)
  end)
end

-- a new full scan: read it again if the view is open
local prevScan = ns.onScan
function ns.onScan(...)
  if prevScan then prevScan(...) end
  if F and F:IsShown() then V.refresh() end
end
