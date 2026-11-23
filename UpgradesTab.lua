-- EverlookDB Auctions: the Upgrades tab. A bottom tab at the auction house (beside Quick sell and Shopping), and the
-- same view in a window of its own away from it (/eah up). It opens only when clicked or with /eah up: never on its
-- own when the auction house opens (Sell.lua remembers only the core tabs). From the last full scan (our own or the
-- shared one):
--   row 1     the character (you, or an alt of this realm saved by UpgradesChars.lua: its class, level and saved
--             gear), its spec buttons (one per spec; "Other..." for levelling builds and your own weights), and the
--             filters on the right:
--             max price per item, smallest upgrade in %, rich mode (biggest upgrade, else most upgrade per gold)
--   row 2     the status line, on its own row: last scan's age and whose it is, gear items and upgrades, and the
--             weights when they are estimates (the full text in its tooltip)
--   states    while there is no scan to read (a price update running, or none yet) one calm message in place of the
--             slots, which fills in by itself when the scan is done; "Reading the last scan" while it is scored
--   slots     the paper doll: per slot the best upgrade within the max price; click one for its other options
--   options   the slot's upgrades, best first ("BEST" on the first); right-click finds it in Buy, Shift-click links it
--   summary   "Best upgrade in every slot: N items for <total>" and the gold Make shopping list (the Shopping tab's
--             lists, Shopping.lua)
-- Scoring runs in small batches over frames (Upgrades.lua) and waits while you're in combat.
local ADDON, ns = ...
local UI, T = ns.UI, ns.T
local U = ns.up
local EUI = LibStub and LibStub("EverlookUI-1", true)

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

-- The character shown: nil for you, else the key of an alt saved by UpgradesChars.lua (this session only: the page
-- opens on you). V.ctx() is what Upgrades.lua scores with for it (U.ctx), nil for you.
V.who = nil
function V.ctx()
  local C = ns.upChars
  if not V.who or not C then return nil end
  local ctx = C.ctx(V.who)
  if not ctx then V.who = nil end   -- forgotten, or it is you after all
  return ctx
end

-- The spec shown: the one picked on the tab for that character, else its first spec (for you: the first ticked one).
function V.spec()
  local ctx = V.ctx()
  if ctx then
    local s = ctx.rec.shown and U.spec(ctx.rec.shown, ctx.class)
    if s then return s end
    local list = U.specs(ctx.class)
    for _, x in ipairs(list) do if not x.build then return x end end
    return list[1]
  end
  local c = U.char()
  local s = c.shown and U.spec(c.shown)
  return s or U.ticked()[1]
end

-- Shows a spec for the character shown, remembered for it.
function V.showSpec(key)
  local ctx = V.ctx()
  if ctx then
    ctx.rec.shown = key
  else
    U.char().shown = key
    local C = ns.upChars
    if C and C.meKey then C.setShown(C.meKey(), key) end
  end
  V.refresh()
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
  ns.itemTipOwner(owner, function(o) itemTip(o, e) end)   -- next to the mouse; "Equipped" only with Shift (ItemTip.lua)
  local okT = pcall(GameTooltip.SetHyperlink, GameTooltip, U.linkOf(e.id, e.suffix))
  if not okT then GameTooltip:SetText(e.name) end
  GameTooltip:AddLine("Right-click: find it in Buy.  Shift-click: link it in chat.", T.dim[1], T.dim[2], T.dim[3], true)
  GameTooltip:Show()
end

---------------------------------------------------------------------------------------------------------------------
-- Text for a slot

local function upText(e)
  if not e then return "" end
  if not e.cmp.pct then return e.cmp.note == "empty" and "new slot" or "" end
  return U.pctText(e.cmp)
end

-- What a slot card without a pick says: only what is particular to that slot (a two-hander, the level the next
-- upgrade needs); otherwise a quiet dash. The empty state and the filters are said once: in the footer, and in the
-- picked slot's panel.
V.QUIET = "\226\128\148"   -- an em dash
function V.slotWhy(slot)
  if not slot or (slot.better or 0) > 0 then return V.QUIET end
  if slot.twohand then return "You wear a two-hander" end
  if slot.nextLevel then return ("Next upgrade at level %d"):format(slot.nextLevel) end
  return V.QUIET
end

-- The picked slot's panel when it has no upgrade: plain words, then what there is.
function V.slotNote(slot)
  if slot.twohand then return "You wear a two-handed weapon: an off-hand would need a one-hander too." end
  local hidden = (slot.overMax or 0) + (slot.underMin or 0)
  local parts = { hidden > 0 and "No upgrade within your filters." or "No upgrade on the AH right now." }
  if (slot.overMax or 0) > 0 then
    parts[#parts + 1] = ("%d %s over your max price."):format(slot.overMax, slot.overMax == 1 and "is" or "are")
  end
  if (slot.underMin or 0) > 0 then
    parts[#parts + 1] = ("%d %s smaller than your min %%."):format(slot.underMin, slot.underMin == 1 and "is" or "are")
  end
  if slot.nextLevel then parts[#parts + 1] = ("A better one needs level %d."):format(slot.nextLevel) end
  if (slot.usable or 0) > 0 and hidden == 0 then
    parts[#parts + 1] = ("%d for this slot that you can use, none better than yours."):format(slot.usable)
  end
  return table.concat(parts, " ")
end

-- The line under the slots. When no slot has an upgrade: the filters only when they hide something (and which one
-- to loosen), else the plain empty state, said this once.
function V.footer(r)
  if not r or not r.done or r.none then return "" end
  if (r.count or 0) > 0 then
    return ("Best upgrade in every slot: %d %s for %s"):format(r.count, r.count == 1 and "item" or "items", money(r.total))
  end
  local over, under = r.overMax or 0, r.underMin or 0
  if over > 0 and under > 0 then
    return ("No upgrades within your filters: %d over your max price, %d below your min %%. Raise MAX PRICE or lower MIN %%."):format(over, under)
  elseif over > 0 then
    return ("No upgrades within your filters: %d over your max price. Raise MAX PRICE to see %s."):format(over, over == 1 and "it" or "them")
  elseif under > 0 then
    return ("No upgrades within your filters: %d below your min %%. Lower MIN %% to see %s."):format(under, under == 1 and "it" or "them")
  end
  return "No upgrade on the AH right now" .. (r.spec and (" for " .. r.spec.name) or "") .. "."
end

-- "Updating prices… upgrades show when it's done (99%)"
function V.scanText()
  local okP, pct = false, nil
  if ns.scanProgress then okP, pct = pcall(ns.scanProgress) end
  return "Updating prices\226\128\166 upgrades show when it's done"
    .. ((okP and type(pct) == "number") and (" (%d%%)"):format(math.floor(pct * 100)) or "")
end

-- What the tab shows: "ready" (the slots), or a calm message in their place:
--   "nospec"    no weights for this class or spec: nothing to score with
--   "scanning"  a price update runs and there is no scan of this house yet
--   "none"      no scan of this house yet (and none running)
--   "reading"   the last scan is being scored for this spec
-- Returns the state, the message and a second, dimmer line.
function V.state(r, spec)
  if not spec then
    return "nospec", "No stat weights for your class yet", "Gear upgrades need stat weights for your class to score gear with."
  end
  local w = U.weights(spec)
  if type(w) ~= "table" or not next(w) then
    return "nospec", ("No stat weights for %s"):format(spec.name),
      "Pick another spec above, or set your own weights on the Gear upgrades page of /eah."
  end
  local scanning = ns.scanning and ns.scanning() or false
  if not U.newestScan() then
    if scanning then
      return "scanning", V.scanText(), "Gear upgrades are read from this auction house's newest prices. This fills in by itself."
    end
    return "none", "No prices for this auction house yet",
      "Upgrades show after the first price update. It starts when you open the auction house, or type /eah scan."
  end
  local ctx = V.ctx()
  if not r or r.spec ~= spec or r.whoKey ~= (ctx and ctx.key or nil) or not r.done or r.none then
    local p = V.reading and V.reading.spec == spec and V.reading.progress or 0
    return "reading", ("Reading the last scan\226\128\166 %d%%"):format(math.floor(p * 100)),
      "Scoring every item in it for " .. spec.name .. "."
  end
  return "ready"
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
    b.name:SetText(UI.hex(T.mute) .. V.slotWhy(slot) .. "|r")
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

-- The spec buttons of a class (made once per class: an alt's class gets its own).
local specSets = {}   -- class -> its buttons
local function specButtons(f, class)
  if specSets[class] then return specSets[class] end
  local set = {}
  for _, s in ipairs(U.specs(class)) do
    local w = math.max(56, math.min(220, #s.name * 7 + 18))
    local b = UI.button(f.specBar, s.name, w, 20, "small")
    b.spec = s
    b:Hide()
    b:SetScript("OnClick", function(self) V.showSpec(self.spec.key) end)
    UI.tip(b, "Upgrades for " .. s.name, function()
      local ctx = V.ctx()
      if ctx then return (s.note and (s.note .. " ") or "") .. "Upgrades for " .. tostring(ctx.name) .. " as " .. s.name .. "." end
      return (s.note and (s.note .. " ") or "") .. (U.char().specs[s.key] and "You gear for this." or "You don't gear for this (tick it in /eah up spec or the settings); shown to shop for it.")
    end)
    set[#set + 1] = b
  end
  specSets[class] = set
  return set
end

-- The spec buttons: one per spec of the shown character's class (and the levelling builds you gear for, and the one
-- shown), then "Other..." for the rest: builds, specs left out for room, and weights of your own.
local function layoutSpecs(f)
  local ctx = V.ctx()
  local class = ctx and ctx.class or U.class()
  local shown = V.spec()
  local c = U.char()
  for k, set in pairs(specSets) do
    if k ~= class then for _, b in ipairs(set) do b:Hide() end end
  end
  f.specs = specButtons(f, class)
  local x = 0
  -- room up to the filters on the same row (MAX PRICE ... Rich mode); a button that wouldn't fit is left out (it is
  -- in "Other..."), except the one shown
  local room = math.huge
  local fl, ml = f.specBar:GetLeft(), f.maxL and f.maxL:GetLeft()
  if type(fl) == "number" and type(ml) == "number" then room = ml - fl - 16 - (f.other:GetWidth() or 0) end
  for _, b in ipairs(f.specs) do
    local isShown = shown and shown.key == b.spec.key
    local on = isShown or not b.spec.build or (not ctx and c.specs[b.spec.key])
    if on and not isShown and x + (b:GetWidth() or 0) > room then on = false end
    b:SetShown(on and true or false)
    if on then
      b:ClearAllPoints()
      b:SetPoint("LEFT", x, 0)
      x = x + (b:GetWidth() or 0) + 4
    end
  end
  f.other:ClearAllPoints()
  f.other:SetPoint("LEFT", x, 0)
  f.specBar:SetWidth(math.max(1, x + (f.other:GetWidth() or 0)))
end

-- "Other...": the specs and levelling builds without a button, and weights of your own for this class (profiles,
-- account-wide per class), the built-in ones back, and where to make or import more.
function V.otherItems()
  local ctx = V.ctx()
  local class = ctx and ctx.class or U.class()
  local shown = V.spec()
  local items = {}
  local rest = {}
  for _, b in ipairs((F and F.specs) or {}) do
    if not b:IsShown() then rest[#rest + 1] = b.spec end
  end
  if #rest > 0 then
    items[#items + 1] = { title = true, text = "Specs and levelling builds" }
    for _, s in ipairs(rest) do items[#items + 1] = { value = "s:" .. s.key, text = s.name } end
  end
  local profs = U.as(ctx, U.profiles)
  local active = shown and U.as(ctx, U.activeProfile, shown.key)
  items[#items + 1] = { title = true, text = "Weights of your own" }
  local n = 0
  for i, p in ipairs(profs or {}) do
    local s = p.spec and U.spec(p.spec, class)
    if s then
      n = n + 1
      items[#items + 1] = { value = "p:" .. i, text = s.name .. ": " .. tostring(p.name) }
    end
  end
  if active then items[#items + 1] = { value = "b", text = "Built-in weights for " .. shown.name } end
  if class == U.as(nil, U.class) then
    items[#items + 1] = { value = "edit", text = n > 0 and "Make or import more weights..." or "Make or import weights..." }
  elseif n == 0 then
    items[#items + 1] = { title = true, text = "None yet: make them on a character of this class" }
  end
  local cur = (not active and shown) and ("s:" .. shown.key) or nil
  for i, p in ipairs(profs or {}) do if p == active then cur = "p:" .. i end end
  return items, cur, profs
end

function V.pickOther(value, profs)
  local ctx = V.ctx()
  local shown = V.spec()
  if type(value) ~= "string" then return end
  if value:sub(1, 2) == "s:" then
    V.showSpec(value:sub(3))
  elseif value:sub(1, 2) == "p:" then
    local p = profs and profs[tonumber(value:sub(3))]
    if not p then return end
    U.as(ctx, function() U.picks()[p.spec] = p.name end)
    if ctx then ctx.rec.shown = p.spec else U.char().shown = p.spec end
    U.changed()
  elseif value == "b" and shown then
    U.as(ctx, function() U.picks()[shown.key] = nil end)
    U.changed()
  elseif value == "edit" then
    if ns.app and ns.app.Open then pcall(ns.app.Open, ns.app, "upgrades") end
  end
end

local function makeSpecButtons(f)
  f.specs = {}
  f.other = UI.button(f.specBar, "Other...", 64, 20, "quiet")
  f.other:SetScript("OnClick", function(self)
    local items, cur, profs = V.otherItems()
    if EUI and EUI.OpenPopup then
      EUI.OpenPopup(self, items, cur, function(v) V.pickOther(v, profs) end, { width = 280 })
    end
  end)
  UI.tip(f.other, "Other specs and your own weights", "Levelling builds, specs without a button, and stat weights of your own.")
end

---------------------------------------------------------------------------------------------------------------------
-- The character picker: you and your alts on this realm and faction

local MUTE_HEX = "|cff8d94a3"

local function charText(c)
  local C = ns.upChars
  local name = C and C.colored(c.name, c.class) or tostring(c.name)
  return name .. " " .. MUTE_HEX .. (c.level and tostring(c.level) or "?") .. "|r" .. (c.me and (" " .. MUTE_HEX .. "(you)|r") or "")
end
V.charText = charText

-- The list: you first, then your alts by level; a hint for alts not seen yet; "Forget a character..." when there are
-- alts. Values: "" for you, an alt's key, "\0forget".
function V.charItems()
  local C = ns.upChars
  local items, alts = {}, 0
  for _, c in ipairs(C and C.list() or {}) do
    items[#items + 1] = { value = c.me and "" or c.key, text = charText(c) }
    if not c.me then alts = alts + 1 end
  end
  items[#items + 1] = { title = true, text = MUTE_HEX .. "Log in once on an alt to add it|r" }
  if alts > 0 then items[#items + 1] = { value = "\0forget", text = MUTE_HEX .. "Forget a character...|r" } end
  return items
end

function V.forgetItems()
  local C = ns.upChars
  local items = { { title = true, text = "Forget (it comes back when it logs in)" } }
  for _, c in ipairs(C and C.list() or {}) do
    if not c.me then items[#items + 1] = { value = c.key, text = "Forget " .. charText(c) } end
  end
  return items
end

-- Picks a character ("" or nil: you).
function V.pickChar(key)
  if key == "" then key = nil end
  local C = ns.upChars
  if key and C and key == C.meKey() then key = nil end
  V.who = key
  V.refresh()
end

function V.forgetChar(key)
  local C = ns.upChars
  if not C or not C.forget(key) then return false end
  if V.who == key then V.who = nil end
  V.refresh()
  return true
end

local function charLabel()
  local C = ns.upChars
  if not C then return "" end
  local want = V.who or C.meKey()
  for _, c in ipairs(C.list()) do
    if c.key == want then return charText(c) end
  end
  return C.colored(select(1, C.who()) or "You", U.as(nil, U.class))
end

local function openChars(owner)
  if not (EUI and EUI.OpenPopup) then return end
  EUI.OpenPopup(owner, V.charItems(), V.who or "", function(v)
    if v == "\0forget" then
      EUI.OpenPopup(owner, V.forgetItems(), nil, function(key) V.forgetChar(key) end, { width = 260 })
    else
      V.pickChar(v)
    end
  end, { width = 220 })
end

local function make(parent)
  if F then return F end
  local f = UI.own(CreateFrame("Frame", "EverlookAuctionsUpgrades", parent))
  f:EnableMouse(true)
  UI.place(f, "upgrades")
  -- opaque: the Buy panel's search row (Filter, Search) sits under this one and mustn't show through
  UI.panel(f, { T.bg[1], T.bg[2], T.bg[3], 1 }, T.edge)
  UI.placeEdge(f, PLACE)
  f:Hide()
  F = f

  -- the character first (you or an alt), then its specs
  if EUI and EUI.MakeTheme then f.eluiTheme = EUI.MakeTheme(T.accent or { 1, 0.82, 0 }) end
  if EUI and EUI.DropButton and f.eluiTheme then
    f.charBtn, f.charText = EUI.DropButton(f, f.eluiTheme, 150)
    f.charBtn:SetHeight(22)
  else
    f.charBtn = UI.button(f, "", 150, 20, "small")
    f.charText = f.charBtn
  end
  f.charBtn:SetPoint("TOPLEFT", 12, -9)
  f.charBtn:SetScript("OnClick", function(self) openChars(self) end)
  UI.tip(f.charBtn, "Character", "Upgrades for you or one of your alts on this realm: its class, level and the gear it last wore.")
  f.specBar = CreateFrame("Frame", nil, f)
  f.specBar:SetHeight(20)
  f.specBar:SetPoint("LEFT", f.charBtn, "RIGHT", 8, 0)   -- the title bar says "Gear upgrades"; the spec buttons lead here
  makeSpecButtons(f)

  -- the status line: a row of its own under the spec buttons and filters, never under them; cut short with "..."
  -- when it is long, the whole of it in the tooltip
  f.head = UI.text(f, "dim")
  f.head:SetPoint("TOPLEFT", 12, -38)
  f.head:SetPoint("RIGHT", f, "RIGHT", -12, 0)
  f.head:SetWordWrap(false)
  f.headHit = CreateFrame("Frame", nil, f)
  f.headHit:SetPoint("TOPLEFT", 10, -34)
  f.headHit:SetPoint("RIGHT", f, "RIGHT", -10, 0)
  f.headHit:SetHeight(20)
  f.headHit:EnableMouse(true)
  f.headHit:SetScript("OnEnter", function(self)
    if not V.headTip or #V.headTip == 0 then return end
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")
    GameTooltip:SetText("Gear upgrades")
    for _, l in ipairs(V.headTip) do GameTooltip:AddLine(l, T.dim[1], T.dim[2], T.dim[3], true) end
    GameTooltip:Show()
  end)
  f.headHit:SetScript("OnLeave", function() GameTooltip:Hide() end)

  -- filters, top right, on the spec buttons' row
  f.rich = UI.check(f, "Rich mode", function(_, on) U.set("rich", on); V.refresh() end)
  f.rich:SetPoint("TOPRIGHT", -12, -10)
  UI.tip(f.rich, "Rich mode", "On: the biggest upgrade within your max price. Off: the most upgrade per gold.")
  f.min = UI.input(f, 40, 20, { hint = "0", max = 3, numeric = true, right = true })
  f.min:SetPoint("RIGHT", f.rich, "LEFT", -18, 0)
  local minL = UI.label(f, "MIN %")
  minL:SetPoint("RIGHT", f.min, "LEFT", -6, 0)
  f.max = UI.input(f, 74, 20, { hint = "any", max = 14 })
  f.max:SetPoint("RIGHT", minL, "LEFT", -12, 0)
  local maxL = UI.label(f, "MAX PRICE")
  maxL:SetPoint("RIGHT", f.max, "LEFT", -6, 0)
  f.maxL = maxL
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
  UI.tip(f.min, "Smallest upgrade", "Upgrades smaller than this many percent of your gear aren't shown.")

  -- slots, two columns like the character window
  f.cards = {}
  local area = CreateFrame("Frame", nil, f)
  f.area = area
  area:SetPoint("TOPLEFT", 10, -62)
  area:SetSize(CARD_W * 2 + 8, CARD_H * 8 + 7 * 4)
  for i, g in ipairs(U.ORDER) do
    local c = makeCard(area, g)
    local col, row = (i <= 8) and 0 or 1, (i <= 8) and (i - 1) or (i - 9)
    c:SetPoint("TOPLEFT", col * (CARD_W + 8), -row * (CARD_H + 4))
    f.cards[g] = c
  end

  -- the picked slot's options
  local R = UI.panel(CreateFrame("Frame", nil, f), T.surface, T.edge)
  f.R = R
  R:SetPoint("TOPLEFT", area, "TOPRIGHT", 10, 0)
  R:SetPoint("BOTTOMRIGHT", -10, 44)

  -- the calm message in place of the slots (no scan yet, a price update running, reading the scan)
  local M = CreateFrame("Frame", nil, f)
  f.msg = M
  M:SetPoint("TOPLEFT", 10, -62)
  M:SetPoint("BOTTOMRIGHT", -10, 44)
  M:Hide()
  f.msgTitle = UI.text(M, "title")
  f.msgTitle:SetPoint("BOTTOMLEFT", M, "LEFT", 40, 6)
  f.msgTitle:SetPoint("BOTTOMRIGHT", M, "RIGHT", -40, 6)
  f.msgTitle:SetJustifyH("CENTER")
  f.msgTitle:SetTextColor(unpack(PLACE))
  f.msgBody = UI.text(M, "dim")
  f.msgBody:SetPoint("TOPLEFT", M, "LEFT", 60, -4)
  f.msgBody:SetPoint("TOPRIGHT", M, "RIGHT", -60, -4)
  f.msgBody:SetJustifyH("CENTER")
  f.msgBody:SetWordWrap(true)
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

  f:SetScript("OnShow", function() V.wasScanning = nil; V.refresh() end)
  -- once a second while shown: the scan's % while a price update runs, and the slots read again by themselves when
  -- it ends (saved or not), when a scan arrives some other way (the Price Feed), or when items were still loading
  local tick = 0
  f:SetScript("OnUpdate", function(_, elapsed)
    tick = tick + (elapsed or 0)
    if tick < 1 then return end
    tick = 0
    V.poll()
  end)
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

-- The status line and its tooltip: the line, and the tooltip's lines.
function V.headText(r, spec)
  local who = r.source == "shared" and "other players (Price Feed)" or "you"
  local ctx = V.ctx()
  local parts = {}
  local first
  if ctx then
    local age = ctx.rec and ctx.rec.at and ns.ago and ns.ago(ctx.rec.at) or "unknown"
    parts[1] = ("Gear as of %s"):format(age)
    first = ("Upgrades for %s, level %d, against the gear %s wore %s (the last time you played it)."):format(
      tostring(ctx.name), ctx.level or 0, tostring(ctx.name), age)
  end
  parts[#parts + 1] = ("Last scan %s by %s"):format(ageText(r), who)
  parts[#parts + 1] = ("%s gear items"):format(ns.num and ns.num(r.gear) or r.gear)
  parts[#parts + 1] = ("%s upgrades"):format(ns.num and ns.num(r.upgrades) or r.upgrades)
  local tip = { ("Read from the last full scan of this auction house, %s by %s."):format(ageText(r), who) }
  if first then table.insert(tip, 1, first) end
  if ns.scanning and ns.scanning() then
    local okP, pct = false, nil
    if ns.scanProgress then okP, pct = pcall(ns.scanProgress) end
    parts[#parts + 1] = "updating prices" .. ((okP and type(pct) == "number") and (" %d%%"):format(math.floor(pct * 100)) or "")
    tip[#tip + 1] = "Prices are updating now: the upgrades are read again when that's done."
  end
  local _, _, from, _, meta = U.weights(spec)
  if from == "built-in" and meta and meta.src == "estimate" then
    parts[#parts + 1] = ("using estimated weights for %s at level %d"):format(spec.name, U.level())
    tip[#tip + 1] = "The stat weights for " .. spec.name .. " at your level are estimates" .. (meta.why and (" (" .. meta.why .. ")") or "")
      .. ", so close calls can go either way."
  end
  if (r.pending or 0) > 0 then
    parts[#parts + 1] = ("%s items still loading"):format(ns.num and ns.num(r.pending) or r.pending)
    tip[#tip + 1] = "Some items weren't loaded by the game yet; they are read again in a moment."
  end
  local line = table.concat(parts, " \194\183 ")
  table.insert(tip, 1, line)
  return line, tip
end

local function showMessage(f, title, body)
  f.area:Hide()
  f.R:Hide()
  f.msg:Show()
  f.msgTitle:SetText(title or "")
  f.msgBody:SetText(body or "")
  f.head:SetText("")
  V.headTip = nil
  f.sum:SetText("")
  f.make:Disable()
  f.make:Hide()
end

local function renderNow()
  local f = F
  if not f or not f:IsShown() then return end
  local spec = V.spec()
  if f.charText then f.charText:SetText(charLabel()) end
  layoutSpecs(f)
  for _, b in ipairs(f.specs) do b:EdbActive(spec and b.spec.key == spec.key) end
  if not f.max:HasFocus() then f.max:SetText(U.get("max") and U.moneyShort(U.get("max")) or "") end
  if not f.min:HasFocus() then f.min:SetText((tonumber(U.get("min")) or 0) > 0 and tostring(U.get("min")) or "") end
  f.rich:EdbChecked(U.get("rich"))
  local r = U.result
  local kind, title, body = V.state(r, spec)
  V.kind = kind
  if kind ~= "ready" then
    showMessage(f, title, body)
    return
  end
  f.msg:Hide()
  f.area:Show()
  f.R:Show()
  f.make:Show()
  local line, tip = V.headText(r, spec)
  f.head:SetText(line)
  V.headTip = tip
  for _, g in ipairs(U.ORDER) do fillCard(f.cards[g], r.slots[g]) end
  local sel = V.sel or "head"
  local slot = r.slots[sel]
  local n = slot and #slot.list or 0
  f.optTitle:SetText(("%s: %d %s"):format(U.SLOT_NAME[sel], n, n == 1 and "upgrade" or "upgrades"))
  local note
  if slot and #slot.list == 0 then
    note = V.slotNote(slot)
  elseif slot then
    local best = slot.best
    local vs = best and best.cmp.vs and best.cmp.vs.link
    note = (U.get("rich") and "Biggest first" or "Most per gold first") .. ", gains in % of your gear"
      .. (best and U.whyText(best.cmp, 2) and (". Best: " .. U.whyText(best.cmp, 2)) or "") .. "."
      .. (vs and ("\nAgainst " .. vs) or (best and best.cmp.note == "empty" and "\nYou wear nothing there." or ""))
  end
  f.optNote:SetText(note or "")
  f.opts.empty:SetText("")
  f.opts:SetItems(slot and slot.list or {})
  f.sum:SetText(V.footer(r))
  if r.count and r.count > 0 then f.make:Enable() else f.make:Disable() end
end

-- Drawn as the character shown (an alt: its class, level and gear for the weights and texts).
function render()
  local ctx = V.ctx()
  if ctx then U.as(ctx, renderNow) else renderNow() end
end
V.render = function() render() end

-- Scores the newest scan again for the shown spec (in the background) and redraws.
function V.refresh()
  if not F or not F:IsShown() then return end
  local spec = V.spec()
  if not spec then render(); return end
  U.onProgress = function(r) V.reading = r; render() end
  V.reading = nil
  U.collect(spec, function(r)
    V.reading = nil
    -- items the game hadn't loaded: read again in a few seconds, three times at most per scan
    if V.retryScan ~= r.scan then V.retryScan, V.retries = r.scan, 0 end
    if (r.pending or 0) > 0 and (V.retries or 0) < 3 and not r.none then
      V.retries = (V.retries or 0) + 1
      V.retryAt = (GetTime and GetTime() or 0) + 5
    end
    render()
  end, nil, V.ctx())
  render()
  if InCombatLockdown and InCombatLockdown() then setStatus("Waiting for combat to end before reading the scan.", T.dim) end
end

-- Once a second while the view is shown (OnUpdate): the slots are read again when a price update ends (saved or
-- not), when a scan turns up while there was none (the Price Feed), or after items that were still loading.
function V.poll()
  if not F or not F:IsShown() then return end
  local scanning = ns.scanning and ns.scanning() or false
  local was = V.wasScanning
  V.wasScanning = scanning
  if was and not scanning then V.refresh(); return end
  if V.kind == "none" or V.kind == "scanning" then
    if U.newestScan() then V.refresh() else render() end
    return
  end
  if V.retryAt and (GetTime and GetTime() or 0) >= V.retryAt then
    V.retryAt = nil
    V.refresh()
    return
  end
  if scanning then render() end
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
  local ctx = V.ctx()
  local name = "Gear upgrades: " .. (ctx and (tostring(ctx.name) .. ", ") or "") .. (r.spec and r.spec.name or "")
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
  V.inAH = nil
  if tab then pcall(PanelTemplates_DeselectTab, tab) end
  if ns.blizzardTabs then ns.blizzardTabs(true) end
  if ns.ahTitle then ns.ahTitle(nil) end
end
V.closeTab = closeTab

-- top: how far below the parent's top the view starts away from the auction house (its own window has a title bar)
local function place(parent, inAH, top)
  local f = make(parent)
  f:SetParent(parent)
  f:ClearAllPoints()
  f:SetFrameStrata(parent:GetFrameStrata())
  if inAH then
    f:SetFrameLevel(parent:GetFrameLevel() + 150)
    f:SetPoint("TOPLEFT", parent, "TOPLEFT", 2, -24)
    f:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -2, (ns.BAR_H or 0) + 2)   -- the price bar and tabs stay visible
  else
    f:SetFrameLevel(parent:GetFrameLevel() + 2)
    f:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -(top or 26))
    f:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 0, 0)
  end
  return f
end

function V.openTab()
  local ah = _G.AuctionHouseFrame
  if not ah then return end
  if win then win:Hide() end
  local f = place(ah, true)
  V.inAH, V.inHub = true, nil
  if ns.closeSearch then ns.closeSearch() end
  if ns.closeSelling then ns.closeSelling() end
  if ns.closeOthers then ns.closeOthers("upgrades") end
  if ns.blizzardTabs then ns.blizzardTabs(false) end
  if tab then pcall(PanelTemplates_SelectTab, tab) end
  if ns.raise then ns.raise(f) end
  f:Show()
  if ns.ahTitle then ns.ahTitle("Gear upgrades", PLACE) end
  -- not remembered as the last tab: the auction house never opens on Upgrades by itself
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
  local EUI = LibStub and LibStub("EverlookUI-1", true)
  if EUI and EUI.CloseOnEscape then EUI.CloseOnEscape(w) end   -- Escape closes it (never UISpecialFrames)
  local d = U.db()
  if d and type(d.winPos) == "table" then
    w:ClearAllPoints()
    pcall(w.SetPoint, w, d.winPos[1], UIParent, d.winPos[2], d.winPos[3], d.winPos[4])
  end
  w:Hide()
  win = w
  return w
end

-- The Gear upgrades page of the main window (Hub.lua): the same view, in the page; the auction house's Upgrades
-- tab takes it back while it is open there.
function V.dock(area)
  if V.inAH and F and F:IsShown() then closeTab() end   -- the auction house's tab had it: it moves here
  V.inHub = area
  local f = place(area, false, 0)
  if win then win:Hide() end
  f:Show()
  V.refresh()
  if ns.upAsk then ns.upAsk() end
end
function V.undock(area)
  if V.inHub == area and F and F:GetParent() == area then F:Hide() end
end

function V.openWindow()
  if ns.hub and ns.hub.open("gear") then return end
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
      -- never opened here: Upgrades opens when its tab is clicked or with /eah up (a saved lastTab of "upgrades"
      -- from 0.16.0 is forgotten in Sell.lua's openStartTab)
      if ns.upAsk then ns.upAsk() end
    end)
  end)
end

-- a new full scan: read it again if the view is open
-- (a moment later: the scan still counts as running until just after this call)
local prevScan = ns.onScan
function ns.onScan(...)
  if prevScan then prevScan(...) end
  C_Timer.After(0.1, function()
    V.wasScanning = nil
    if F and F:IsShown() then V.refresh() end
  end)
end
