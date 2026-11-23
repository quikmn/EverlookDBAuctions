-- Disenchant preview: on the Disenchanting page (/eah de, /dv), the items in your bags that can be disenchanted, each
-- with what it would disenchant into, the expected value and whether that beats selling it (vendor or auction after
-- the cut). Click one to preview it: its materials with count, chance and worth, and a "Disenchant" button that casts
-- Disenchant on that bag slot - one click per item, never automatic, never in combat.
--
-- The idea of a bag list with a material forecast and a one-click Disenchant button comes from Disenchantry 1.3.0
-- (https://www.curseforge.com/wow/addons/disenchantry), MIT License:
--   Copyright (c) 2026 x_Raven_x
--   Copyright (c) 2026 Rakuga (Disenchant Helper, which Disenchantry is based on)
-- The full licence text is in THIRD-PARTY-NOTICES.md. This file is our own code on our own data
-- (ns.deMaterials, EverlookDBAuctions.lua).
--
-- The button is a SecureActionButtonTemplate macro button ("/cast Disenchant" then "/use <bag> <slot>"). Out of combat
-- it sits on the page (its parent is the page's place for it, so the page's scrolling clips it); when combat starts it
-- hides and goes back to UIParent, so the window never has a protected child in combat. Its attributes change only out
-- of combat.
local ADDON, ns = ...

local P = {}
ns.dePreview = P

local DISENCHANT_SPELL = 13262
local function isSecret(v) return issecretvalue ~= nil and issecretvalue(v) and true or false end
local function plain(v) if v ~= nil and not isSecret(v) then return v end end
local function inCombat() return InCombatLockdown and InCombatLockdown() and true or false end

local function money(c)
  local Tip = LibStub and LibStub("EverlookTooltip-1", true)
  if Tip and Tip.Money then return Tip.Money(c) or "" end
  return GetMoneyString and GetMoneyString(c) or tostring(c)
end

---------------------------------------------------------------------------------------------------------------------
-- The bags

local function bagSlots(bag)
  local okN, n = pcall(C_Container.GetContainerNumSlots, bag)
  return okN and plain(n) or 0
end

-- One bag slot as the preview needs it, or nil when it holds nothing that can be disenchanted.
function P.slotEntry(bag, slot)
  local okL, link = pcall(C_Container.GetContainerItemLink, bag, slot)
  link = okL and plain(link) or nil
  if type(link) ~= "string" then return nil end
  local id = tonumber(link:match("item:(%d+)"))
  if not id or not (ns.DE_ITEMS and ns.DE_ITEMS[id]) then return nil end
  local info
  if C_Container.GetContainerItemInfo then
    local okI, i = pcall(C_Container.GetContainerItemInfo, bag, slot)
    info = okI and type(i) == "table" and i or nil
  end
  local bound = info and plain(info.isBound) and true or false
  local icon = info and plain(info.iconFileID)
  if not icon then
    local okIc, ic = pcall(C_Item.GetItemIconByID, id)
    icon = okIc and plain(ic) or nil
  end
  local mats, value, _, source = ns.deMaterials(id)
  local best = ns.bestSale and ns.bestSale(id, bound)
  local okL2, ilvl = pcall(C_Item.GetDetailedItemLevelInfo, link)
  return { bag = bag, slot = slot, id = id, link = link, icon = icon, bound = bound, mats = mats, value = value,
    source = source, best = best, ilvl = okL2 and plain(ilvl) or nil,
    beats = value ~= nil and best ~= nil and value > best }
end

-- Every item in your bags that can be disenchanted: the ones where disenchanting beats selling first, then by value.
function P.bagItems()
  local out = {}
  if not C_Container then return out end
  for bag = 0, (NUM_BAG_SLOTS or 4) do
    for slot = 1, bagSlots(bag) do
      local e = P.slotEntry(bag, slot)
      if e then out[#out + 1] = e end
    end
  end
  table.sort(out, function(a, b)
    if a.beats ~= b.beats then return a.beats end
    local va, vb = a.value or -1, b.value or -1
    if va ~= vb then return va > vb end
    if a.bag ~= b.bag then return a.bag < b.bag end
    return a.slot < b.slot
  end)
  return out
end

-- "~17s 30c · beats selling (12s)" for a list row.
function P.summary(e)
  local parts = {}
  if e.value then
    parts[#parts + 1] = "Disenchant " .. money(e.value)
    if e.best then
      parts[#parts + 1] = e.beats and ("|cff5ce070beats selling (" .. money(e.best) .. ")|r")
        or ("|cffff7366selling pays more (" .. money(e.best) .. ")|r")
    end
  elseif e.source == "unmeasured" then
    parts[#parts + 1] = "not measured yet"
  else
    parts[#parts + 1] = "no material prices yet"
  end
  if e.source == "rough" then parts[#parts + 1] = "rough estimate" end
  return table.concat(parts, "  \194\183  ")
end

---------------------------------------------------------------------------------------------------------------------
-- The selection and the Disenchant button

P.selected = nil   -- { bag, slot, id }

local function sameItem(e, sel) return e and sel and e.bag == sel.bag and e.slot == sel.slot and e.id == sel.id end

-- The selected item's entry, read again from its bag slot; nil when it has gone (disenchanted, moved).
function P.current()
  local sel = P.selected
  if not sel then return nil end
  local e = P.slotEntry(sel.bag, sel.slot)
  if sameItem(e, sel) then return e end
end

function P.select(e)
  P.selected = e and { bag = e.bag, slot = e.slot, id = e.id } or nil
  P.refresh()
end

-- Whether this character knows Disenchant (true when the game can't tell us).
function P.knowsDisenchant()
  if IsPlayerSpell then
    local okK, known = pcall(IsPlayerSpell, DISENCHANT_SPELL)
    if okK and plain(known) ~= nil then return known and true or false end
  end
  if IsSpellKnown then
    local okK, known = pcall(IsSpellKnown, DISENCHANT_SPELL)
    if okK and plain(known) ~= nil then return known and true or false end
  end
  return true
end

-- The macro the button runs for a bag slot.
function P.macroFor(bag, slot)
  local okS, name = pcall(C_Spell.GetSpellName, DISENCHANT_SPELL)
  name = okS and plain(name) or "Disenchant"
  return "/cast " .. name .. "\n/use " .. bag .. " " .. slot
end

local button, holder

local function hideButton()
  if button and not inCombat() then
    button:Hide()
    button:ClearAllPoints()
    button:SetParent(UIParent)
  end
end

-- The secure button: made once, out of combat.
local function makeButton(T)
  if button or inCombat() then return button end
  button = CreateFrame("Button", "EverlookDBAuctionsDisenchantButton", UIParent, "SecureActionButtonTemplate")
  button:RegisterForClicks("LeftButtonUp")
  button:SetAttribute("useOnKeyDown", false)
  button:SetAttribute("type", "macro")
  local fill = (T and (T.accentFill or T.accent)) or { 0.85, 0.68, 0.2, 1 }
  local bg = button:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetColorTexture(fill[1], fill[2], fill[3], 1)
  button.bg = bg
  local label = button:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  label:SetPoint("CENTER")
  local on = (T and T.onAccent) or { 0.05, 0.07, 0.1, 1 }
  label:SetTextColor(on[1], on[2], on[3], 1)
  button.label = label
  button:SetScript("OnEnter", function(self)
    local a = (T and T.accent) or fill
    self.bg:SetColorTexture(a[1], a[2], a[3], 1)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine("Disenchant this item", 1, 1, 1)
    GameTooltip:AddLine("One click disenchants the selected item. Nothing happens on its own.", nil, nil, nil, true)
    GameTooltip:Show()
  end)
  button:SetScript("OnLeave", function(self)
    self.bg:SetColorTexture(fill[1], fill[2], fill[3], 1)
    GameTooltip:Hide()
  end)
  button:Hide()
  return button
end

-- Puts the button over its place on the page for the selected item, or hides it; the place says why when it can't.
function P.updateButton()
  if not holder then return end
  local e = P.current()
  local why
  if inCombat() then why = "Not in combat."
  elseif not e then why = "Click an item above to preview it."
  elseif not P.knowsDisenchant() then why = "This character doesn't know Disenchant."
  end
  holder.text:SetText(why or "")
  if why or not holder:IsVisible() then
    hideButton()
    return
  end
  local b = makeButton(holder.T)
  if not b then return end
  b:SetAttribute("macrotext", P.macroFor(e.bag, e.slot))
  local okN, name = pcall(C_Item.GetItemInfo, e.link)
  b.label:SetText("Disenchant " .. ((okN and plain(name)) or "item"))
  b:SetParent(holder)
  b:ClearAllPoints()
  b:SetPoint("TOPLEFT", holder, "TOPLEFT", 0, 0)
  b:SetSize(260, 26)
  b:SetFrameStrata(holder:GetFrameStrata())
  b:SetFrameLevel(holder:GetFrameLevel() + 10)
  b:Show()
end

---------------------------------------------------------------------------------------------------------------------
-- The page

local ui = {}   -- the widgets of the latest build

function P.refresh()
  -- a selection that has gone (disenchanted, moved) moves to the best item left
  if P.selected and not P.current() then
    local first = P.bagItems()[1]
    P.selected = first and { bag = first.bag, slot = first.slot, id = first.id } or nil
  end
  for _, w in pairs(ui) do if w.Refresh then pcall(w.Refresh, w) end end
  P.updateButton()
end

function P.build(stack, app, UI)
  ui = {}
  UI.Header(stack, "In your bags", "What each item would disenchant into, and whether that beats selling it. Click one to preview it.")
  ui.list = UI.List(stack, {
    items = P.bagItems,
    empty = "Nothing in your bags can be disenchanted.",
    rowHeight = 40,
    icon = function(e) return e.icon or 134400 end,
    title = function(e)
      local mark = sameItem(e, P.selected) and "|cffffd100>|r " or ""
      return mark .. e.link .. (e.ilvl and ("  |cff8f9bb3item level " .. e.ilvl .. "|r") or "")
    end,
    detail = P.summary,
    tooltip = function(e, row)
      GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
      if GameTooltip.SetBagItem then GameTooltip:SetBagItem(e.bag, e.slot) else GameTooltip:SetHyperlink(e.link) end
      GameTooltip:Show()
    end,
    onClick = function(e) P.select(e) end,
    max = 60,
  })
  UI.Header(stack, "Preview", "What the selected item disenchants into, and what each material is worth at today's prices.")
  ui.item = UI.Stat(stack, "Item", function()
    local e = P.current()
    return e and (e.link .. (e.ilvl and ("  item level " .. e.ilvl) or "")) or "none selected"
  end)
  ui.mats = UI.List(stack, {
    items = function() local e = P.current() return e and e.mats or {} end,
    empty = "Click an item above.",
    icon = function(m) local okI, ic = pcall(C_Item.GetItemIconByID, m[1]) return okI and plain(ic) or 134400 end,
    title = function(m) return ns.deMatText(m, true) end,
    detail = function(m) return m[7] and money(m[7]) or "" end,
    titleWidth = 300,
    tooltip = function(m, row)
      GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
      GameTooltip:SetHyperlink("item:" .. m[1])
      GameTooltip:Show()
    end,
  })
  ui.value = UI.Stat(stack, "Disenchant value", function()
    local e = P.current()
    if not e then return "" end
    if not e.value then return e.source == "unmeasured" and "not measured yet" or "no material prices yet" end
    return money(e.value) .. "  (" .. ns.deSourceText(e.source) .. ")"
  end)
  ui.sale = UI.Stat(stack, "Selling it pays", function()
    local e = P.current()
    if not e or not e.best then return "" end
    local verdict = e.value and (e.beats and "  |cff5ce070disenchanting pays more|r" or "  |cffff7366selling pays more|r") or ""
    return money(e.best) .. (e.bound and " (vendor)" or "") .. verdict
  end)
  -- the place of the secure Disenchant button
  holder = CreateFrame("Frame")
  holder:SetParent(stack.parent)
  holder.T = stack.T
  holder.text = holder:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  holder.text:SetPoint("LEFT", 4, 0)
  holder:SetScript("OnShow", function() P.updateButton() end)
  holder:SetScript("OnHide", function() hideButton() end)
  function holder:Refresh() P.updateButton() end
  stack:Add(holder, 26, 12)
  ui.holder = holder
  P.updateButton()
end

---------------------------------------------------------------------------------------------------------------------
-- Events

local f = CreateFrame("Frame")
f:RegisterEvent("BAG_UPDATE_DELAYED")
f:RegisterEvent("PLAYER_REGEN_DISABLED")
f:RegisterEvent("PLAYER_REGEN_ENABLED")
f:SetScript("OnEvent", function(_, event)
  if event == "PLAYER_REGEN_DISABLED" then
    -- still allowed here: the lockdown starts after this event
    if button then button:Hide(); button:ClearAllPoints(); button:SetParent(UIParent) end
    if holder and holder.text then holder.text:SetText("Not in combat.") end
    return
  end
  if holder and holder:IsVisible() then P.refresh() end
end)
