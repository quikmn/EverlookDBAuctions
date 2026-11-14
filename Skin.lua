-- EverlookDB look. One dark palette (the tokens in T) for everything the addon draws, a small kit of widgets built
-- from it (panels, buttons, inputs, rows, scrolling lists, fonts), and a skin for Blizzard's auction house in the
-- same palette. The skin only changes the art: Blizzard's auction house keeps doing all the searching, buying and
-- posting underneath. /eah skin off turns the skin of Blizzard's frames off (after a /reload); the addon's own
-- frames always use the palette.
local _, ns = ...

---------------------------------------------------------------------------------------------------------------------
-- Palette: every color the addon uses comes from here.

local T = {
  bg       = { 0.055, 0.063, 0.078, 0.98 },  -- #0e1014  window background
  surface  = { 0.082, 0.094, 0.114, 1 },     -- #15181d  panels and sections
  raised   = { 0.114, 0.129, 0.157, 1 },     -- #1d2128  buttons, header bands
  raisedHi = { 0.153, 0.173, 0.208, 1 },     -- #272c35  hovered buttons
  input    = { 0.039, 0.045, 0.055, 1 },     -- #0a0b0e  edit boxes, scroll tracks
  edge     = { 0.176, 0.196, 0.235, 1 },     -- #2d323c  1 px borders
  edgeHi   = { 0.290, 0.318, 0.376, 1 },     -- #4a5160  hovered borders
  text     = { 0.902, 0.914, 0.933, 1 },     -- #e6e9ee  main text
  dim      = { 0.604, 0.639, 0.698, 1 },     -- #9aa3b2  secondary text
  mute     = { 0.427, 0.455, 0.506, 1 },     -- #6d7481  labels, disabled
  accent   = { 1, 0.82, 0, 1 },              -- #ffd100  EverlookDB gold: active tab, selection, main actions
  accentBg = { 0.196, 0.161, 0.043, 1 },     -- #32290b  main action fill
  accentHi = { 0.263, 0.216, 0.063, 1 },     -- #433710  main action hovered
  hover    = { 1, 1, 1, 0.045 },             -- row hover
  select   = { 1, 0.82, 0, 0.10 },           -- selected row
  stripe   = { 1, 1, 1, 0.018 },             -- every other row
  thumb    = { 0.239, 0.263, 0.310, 1 },     -- scroll thumb
  good     = { 0.427, 0.792, 0.478, 1 },     -- #6dca7a
  bad      = { 0.925, 0.373, 0.341, 1 },     -- #ec5f57
  info     = { 0.478, 0.698, 1, 1 },         -- #7ab2ff
}
ns.T = T

local FLAT = "Interface\\Buttons\\WHITE8x8"
local UI = { FLAT = FLAT }
ns.UI = UI

local skins = setmetatable({}, { __mode = "k" })   -- frame -> its fill and border textures
local own = setmetatable({}, { __mode = "k" })     -- the addon's own frames: the Blizzard skin leaves them alone

-- "|cffrrggbb" for a palette color
local function hex(c)
  local function b(v) return math.floor(math.max(0, math.min(1, v)) * 255 + 0.5) end
  return ("|cff%02x%02x%02x"):format(b(c[1]), b(c[2]), b(c[3]))
end
UI.hex = hex

function UI.own(f)
  own[f] = true
  return f
end

---------------------------------------------------------------------------------------------------------------------
-- Fonts: the game's own typeface in a few readable sizes, with a soft shadow.

local FONT = STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"
local FONT_SPECS = {
  title = { 13, "text" }, body = { 12, "text" }, small = { 11, "text" }, dim = { 11, "dim" },
  mute = { 11, "mute" }, head = { 10, "mute" }, accent = { 12, "accent" }, big = { 15, "text" },
}
local fonts = {}

local function fontObject(kind)
  local f = fonts[kind]
  if f then return f end
  local spec = FONT_SPECS[kind] or FONT_SPECS.body
  f = CreateFont("EverlookDBFont_" .. kind)
  f:SetFont(FONT, spec[1], "")
  f:SetTextColor(unpack(T[spec[2]]))
  f:SetShadowColor(0, 0, 0, 0.8)
  f:SetShadowOffset(1, -1)
  fonts[kind] = f
  return f
end
UI.fontObject = fontObject

-- A one-line text in one of the sizes above (wrap it yourself with SetWordWrap(true) and a width).
function UI.text(parent, kind, layer)
  local fs = parent:CreateFontString(nil, layer or "OVERLAY")
  fs:SetFontObject(fontObject(kind))
  fs:SetJustifyH("LEFT")
  fs:SetWordWrap(false)
  return fs
end

---------------------------------------------------------------------------------------------------------------------
-- Fills and 1 px borders

local function onePixel(t, horizontal)
  if PixelUtil then
    if horizontal then PixelUtil.SetHeight(t, 1, 1) else PixelUtil.SetWidth(t, 1, 1) end
  elseif horizontal then t:SetHeight(1) else t:SetWidth(1) end
end

-- A flat fill with a 1 px border, drawn behind the frame's content. l/t/r/b move the edges in or out.
local function paint(f, fill, edge, l, t, r, b)
  local s = skins[f]
  if not s then
    s = {}
    s.fill = f:CreateTexture(nil, "BACKGROUND", nil, -8)
    s.fill:SetPoint("TOPLEFT", l or 0, t or 0)
    s.fill:SetPoint("BOTTOMRIGHT", r or 0, b or 0)
    local function side(p1, p2, horizontal)
      local tex = f:CreateTexture(nil, "BORDER", nil, -8)
      tex:SetPoint(p1, s.fill)
      tex:SetPoint(p2, s.fill)
      onePixel(tex, horizontal)
      return tex
    end
    s.edges = {
      side("TOPLEFT", "TOPRIGHT", true), side("BOTTOMLEFT", "BOTTOMRIGHT", true),
      side("TOPLEFT", "BOTTOMLEFT", false), side("TOPRIGHT", "BOTTOMRIGHT", false),
    }
    skins[f] = s
  end
  if fill then s.fill:SetColorTexture(unpack(fill)) end
  if edge then for _, tex in ipairs(s.edges) do tex:SetColorTexture(unpack(edge)) end end
  return s
end

local function setEdge(f, edge)
  local s = skins[f]
  if s then for _, tex in ipairs(s.edges) do tex:SetColorTexture(unpack(edge)) end end
end

local function setFill(f, fill)
  local s = skins[f]
  if s then s.fill:SetColorTexture(unpack(fill)) end
end

UI.paint, UI.setEdge, UI.setFill = paint, setEdge, setFill

-- A section: surface fill and border (or the colors given).
function UI.panel(f, fill, edge)
  paint(f, fill or T.surface, edge or T.edge)
  return f
end

-- A 1 px line in the border color.
function UI.line(parent, horizontal, color, layer)
  local t = parent:CreateTexture(nil, layer or "BORDER")
  t:SetColorTexture(unpack(color or T.edge))
  onePixel(t, horizontal)
  return t
end

-- A soft shadow outside a window: a few rings one pixel wide, fading out.
local function shadow(f, size)
  size = size or 5
  for i = 1, size do
    local alpha = 0.26 * (1 - (i - 1) / size)
    local function strip(p1, x1, y1, p2, x2, y2)
      local t = f:CreateTexture(nil, "BACKGROUND", nil, -8)
      t:SetPoint(p1, x1, y1)
      t:SetPoint(p2, x2, y2)
      t:SetColorTexture(0, 0, 0, alpha)
    end
    strip("TOPLEFT", -i, i, "TOPRIGHT", i, i - 1)              -- top
    strip("BOTTOMLEFT", -i, -i + 1, "BOTTOMRIGHT", i, -i)      -- bottom
    strip("TOPLEFT", -i, i - 1, "BOTTOMLEFT", -i + 1, -i + 1)  -- left
    strip("TOPRIGHT", i - 1, i - 1, "BOTTOMRIGHT", i, -i + 1)  -- right
  end
end
UI.shadow = shadow

---------------------------------------------------------------------------------------------------------------------
-- Buttons: "primary" (gold, for the one main action), "small", or plain. Plain buttons can be toggles
-- (b:EdbActive(true)). Add tooltips with HookScript, so the hover look keeps working.

local function buttonState(b)
  local enabled = b:IsEnabled()
  local over, down, on = b.edbOver and enabled, b.edbDown and enabled, b.edbOn
  local fill, edge, text
  if b.edbKind == "primary" then
    fill = not enabled and T.raised or down and T.accentBg or over and T.accentHi or T.accentBg
    edge = enabled and T.accent or T.edge
    text = enabled and T.accent or T.mute
  else
    fill = not enabled and T.surface or down and T.input or (over or on) and T.raisedHi or T.raised
    edge = on and T.accent or over and T.edgeHi or T.edge
    text = not enabled and T.mute or on and T.accent or T.text
  end
  setFill(b, fill)
  setEdge(b, edge)
  if b.edbLabel then b.edbLabel:SetTextColor(text[1], text[2], text[3], text[4] or 1) end
end

function UI.button(parent, label, w, h, kind)
  local b = CreateFrame("Button", nil, parent)
  b:SetSize(w or 100, h or 24)
  b.edbKind = kind
  paint(b, T.raised, T.edge)
  local fs = b:CreateFontString(nil, "OVERLAY")
  fs:SetFontObject(fontObject(kind == "small" and "small" or "body"))
  fs:SetPoint("LEFT", 4, 0)
  fs:SetPoint("RIGHT", -4, 0)
  fs:SetWordWrap(false)
  b:SetFontString(fs)
  b.edbLabel = fs
  b:SetText(label or "")
  b:HookScript("OnEnter", function() b.edbOver = true; buttonState(b) end)
  b:HookScript("OnLeave", function() b.edbOver = false; b.edbDown = false; buttonState(b) end)
  b:HookScript("OnMouseDown", function() b.edbDown = true; buttonState(b) end)
  b:HookScript("OnMouseUp", function() b.edbDown = false; buttonState(b) end)
  b:HookScript("OnEnable", function() buttonState(b) end)
  b:HookScript("OnDisable", function() buttonState(b) end)
  b.EdbActive = function(self, on) self.edbOn = on and true or nil; buttonState(self) end
  b.EdbRefresh = buttonState
  buttonState(b)
  return UI.own(b)
end

-- A tooltip on hover: a white title and an optional grey line (either can be a function returning the text).
function UI.tip(f, title, body)
  f:HookScript("OnEnter", function(self)
    local head = type(title) == "function" and title() or title
    if not head then return end
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText(head, 1, 1, 1)
    local text = type(body) == "function" and body() or body
    if text then GameTooltip:AddLine(text, T.dim[1], T.dim[2], T.dim[3], true) end
    GameTooltip:Show()
  end)
  f:HookScript("OnLeave", function() GameTooltip:Hide() end)
end

---------------------------------------------------------------------------------------------------------------------
-- Edit boxes: dark well, 1 px border that lights up on hover and turns gold while typing. opts.hint shows grey text
-- while empty; opts.numeric allows digits only; opts.right aligns right; opts.max limits the length.

function UI.input(parent, w, h, opts)
  opts = opts or {}
  local e = CreateFrame("EditBox", nil, parent)
  e:SetSize(w or 120, h or 24)
  e:SetAutoFocus(false)
  e:SetFontObject(fontObject("body"))
  e:SetTextInsets(7, 7, 0, 0)
  e:SetJustifyH(opts.right and "RIGHT" or "LEFT")
  if opts.numeric then e:SetNumeric(true) end
  if opts.max then e:SetMaxLetters(opts.max) end
  paint(e, T.input, T.edge)
  local function edge()
    setEdge(e, e:HasFocus() and T.accent or e.edbOver and T.edgeHi or T.edge)
    if e.edbHint then e.edbHint:SetShown(e:GetText() == "" and not e:HasFocus()) end
  end
  if opts.hint then
    e.edbHint = UI.text(e, "mute")
    e.edbHint:SetPoint("LEFT", 7, 0)
    e.edbHint:SetPoint("RIGHT", -7, 0)
    e.edbHint:SetJustifyH(opts.right and "RIGHT" or "LEFT")
    e.edbHint:SetText(opts.hint)
  end
  e:HookScript("OnEnter", function() e.edbOver = true; edge() end)
  e:HookScript("OnLeave", function() e.edbOver = false; edge() end)
  e:HookScript("OnEditFocusGained", edge)
  e:HookScript("OnEditFocusLost", edge)
  e:HookScript("OnTextChanged", edge)
  e:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  e:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
  edge()
  return UI.own(e)
end

---------------------------------------------------------------------------------------------------------------------
-- List rows: hover, selected (tint and a gold bar on the left) and every other row a shade lighter.

function UI.row(parent, h)
  local b = CreateFrame("Button", nil, parent)
  b:SetHeight(h)
  local stripe = b:CreateTexture(nil, "BACKGROUND", nil, 1)
  stripe:SetAllPoints()
  stripe:SetColorTexture(unpack(T.stripe))
  stripe:Hide()
  local sel = b:CreateTexture(nil, "BACKGROUND", nil, 2)
  sel:SetAllPoints()
  sel:SetColorTexture(unpack(T.select))
  sel:Hide()
  local bar = b:CreateTexture(nil, "ARTWORK", nil, 7)
  bar:SetPoint("TOPLEFT")
  bar:SetPoint("BOTTOMLEFT")
  bar:SetWidth(2)
  bar:SetColorTexture(unpack(T.accent))
  bar:Hide()
  local hl = b:CreateTexture(nil, "HIGHLIGHT")
  hl:SetAllPoints()
  hl:SetColorTexture(unpack(T.hover))
  b.EdbSelect = function(_, on) sel:SetShown(on and true or false); bar:SetShown(on and true or false) end
  b.EdbStripe = function(_, on) stripe:SetShown(on and true or false) end
  return UI.own(b)
end

-- An item icon with a 1 px border (in the item's quality color when given).
function UI.icon(parent, size)
  local f = CreateFrame("Frame", nil, parent)
  f:SetSize(size, size)
  paint(f, T.input, T.edge)
  f.tex = f:CreateTexture(nil, "ARTWORK")
  f.tex:SetPoint("TOPLEFT", 1, -1)
  f.tex:SetPoint("BOTTOMRIGHT", -1, 1)
  f.tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  f.EdbSet = function(self, icon, quality)
    self.tex:SetTexture(icon)
    local c = quality and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
    setEdge(self, (c and quality ~= 1) and { c.r, c.g, c.b, 0.9 } or T.edge)
  end
  return UI.own(f)
end

---------------------------------------------------------------------------------------------------------------------
-- A scrolling list that only makes the rows that fit. build(list, i) makes row i (use UI.row);
-- fill(row, item, index) shows an item in it. list:SetItems(items), list:Refresh(). Mouse wheel and a slim thumb
-- you can drag scroll it; list.onScroll(list) runs after it scrolls.

local function listRefresh(L)
  local n = L.count or 0
  local total = #L.items
  local maxOff = math.max(0, total - n)
  L.offset = math.max(0, math.min(L.offset, maxOff))
  for i = 1, #L.rows do
    local row = L.rows[i]
    local idx = L.offset + i
    local item = i <= n and L.items[idx] or nil
    row.item, row.index = item, idx
    if item then
      L.fill(row, item, idx)
      if row.EdbStripe then row:EdbStripe(idx % 2 == 0) end
      row:Show()
    else
      row:Hide()
    end
  end
  if L.empty then L.empty:SetShown(total == 0 and (L.empty:GetText() or "") ~= "") end
  if total <= n or n == 0 then
    L.bar:Hide()
  else
    L.bar:Show()
    local h = L.bar:GetHeight()
    local th = math.max(18, h * n / total)
    L.thumb:SetHeight(th)
    L.thumb:ClearAllPoints()
    L.thumb:SetPoint("TOP", L.bar, "TOP", 0, -(h - th) * L.offset / maxOff)
  end
end

local function listLayout(L)
  local want = math.max(0, math.floor((L:GetHeight() + 0.5) / L.rowH))
  for i = #L.rows + 1, want do
    local row = L.build(L, i)
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", L, "TOPLEFT", 0, -(i - 1) * L.rowH)
    row:SetPoint("RIGHT", L, "RIGHT", -10, 0)
    row:SetHeight(L.rowH)
    L.rows[i] = row
  end
  L.count = want
  listRefresh(L)
end

local function listScroll(L, delta)
  local before = L.offset
  L.offset = L.offset + delta
  listRefresh(L)
  if L.offset ~= before and L.onScroll then L.onScroll(L) end
end

function UI.list(parent, rowH, build, fill)
  local L = CreateFrame("Frame", nil, parent)
  L.rows, L.items, L.offset, L.rowH, L.build, L.fill = {}, {}, 0, rowH, build, fill
  local bar = CreateFrame("Frame", nil, L)
  bar:SetPoint("TOPRIGHT", 0, 0)
  bar:SetPoint("BOTTOMRIGHT", 0, 0)
  bar:SetWidth(6)
  local track = bar:CreateTexture(nil, "BACKGROUND")
  track:SetAllPoints()
  track:SetColorTexture(unpack(T.input))
  local thumb = CreateFrame("Button", nil, bar)
  thumb:SetWidth(6)
  local tt = thumb:CreateTexture(nil, "ARTWORK")
  tt:SetAllPoints()
  tt:SetColorTexture(unpack(T.thumb))
  thumb:SetScript("OnEnter", function() tt:SetColorTexture(unpack(T.edgeHi)) end)
  thumb:SetScript("OnLeave", function() if not thumb.dragging then tt:SetColorTexture(unpack(T.thumb)) end end)
  thumb:SetScript("OnMouseDown", function(self)
    local _, y = GetCursorPosition()
    self.dragging, self.startY, self.startOff = true, y / self:GetEffectiveScale(), L.offset
    self:SetScript("OnUpdate", function(s)
      local _, cy = GetCursorPosition()
      cy = cy / s:GetEffectiveScale()
      local room = bar:GetHeight() - s:GetHeight()
      local maxOff = math.max(0, #L.items - (L.count or 0))
      if room > 0 and maxOff > 0 then
        local off = math.floor(s.startOff + (s.startY - cy) / room * maxOff + 0.5)
        if off ~= L.offset then listScroll(L, off - L.offset) end
      end
    end)
  end)
  local function stop(self)
    self.dragging = false
    self:SetScript("OnUpdate", nil)
    if not self:IsMouseOver() then tt:SetColorTexture(unpack(T.thumb)) end
  end
  thumb:SetScript("OnMouseUp", stop)
  thumb:SetScript("OnHide", stop)
  L.bar, L.thumb = bar, thumb
  L:EnableMouseWheel(true)
  L:SetScript("OnMouseWheel", function(_, delta) listScroll(L, -delta * 3) end)
  L:SetScript("OnSizeChanged", function() listLayout(L) end)
  L:SetScript("OnShow", function() listLayout(L) end)
  L.SetItems = function(self, items)
    self.items = items or {}
    listRefresh(self)
  end
  L.Refresh = function(self) listRefresh(self) end
  L.ScrollToTop = function(self) self.offset = 0; listRefresh(self) end
  -- a grey line shown while the list is empty (list.empty:SetText(...))
  L.empty = UI.text(L, "mute")
  L.empty:SetPoint("TOPLEFT", 10, -10)
  L.empty:SetPoint("RIGHT", -16, 0)
  L.empty:SetWordWrap(true)
  L.empty:Hide()
  return UI.own(L)
end

-- The band above a list's rows: raised, with a line under it, for small grey column labels.
function UI.headerBand(parent, h)
  local band = CreateFrame("Frame", nil, parent)
  band:SetHeight(h or 20)
  local bg = band:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetColorTexture(unpack(T.raised))
  local line = UI.line(band, true)
  line:SetPoint("BOTTOMLEFT")
  line:SetPoint("BOTTOMRIGHT")
  return UI.own(band)
end

-- A small grey column label.
function UI.label(parent, text, kind)
  local fs = UI.text(parent, kind or "head")
  fs:SetText(text)
  return fs
end

---------------------------------------------------------------------------------------------------------------------
-- Skin for Blizzard's auction house frames

local function enabled()
  local db = ns.db and ns.db()
  return not db or db.skin ~= false
end

local hidden = CreateFrame("Frame")
hidden:Hide()
local styled = setmetatable({}, { __mode = "k" })
local tabs = setmetatable({}, { __mode = "k" })
local recolored = setmetatable({}, { __mode = "k" })

local function isTex(r)
  return type(r) == "table" and r.GetObjectType and r:GetObjectType() == "Texture"
end

-- Moved under a hidden frame, so it stays gone even when Blizzard sets its art again (tabs, buttons and scroll
-- thumbs change their art on hover and press).
local function kill(r)
  if not r then return end
  if not pcall(r.SetParent, r, hidden) then r:SetAlpha(0) end
end

-- A plain color that stays when Blizzard sets the texture's art again.
local function recolor(t, color)
  if not isTex(t) then return end
  local function apply()
    t:SetColorTexture(unpack(color))
    t:SetBlendMode("BLEND")
  end
  apply()
  if not recolored[t] then
    recolored[t] = true
    hooksecurefunc(t, "SetAtlas", apply)
    hooksecurefunc(t, "SetTexture", function(_, file) if file then apply() end end)
  end
end

local MAIN = { SearchButton = true, BuyoutButton = true, BuyButton = true, PostButton = true, BuyNowButton = true }

local function isMain(f)
  local p = f:GetParent()
  if not p then return false end
  for k in pairs(MAIN) do if rawget(p, k) == f then return true end end
  return false
end

-- Blizzard buttons look like the addon's own: plain ones raised grey, the main actions (Search, Buyout, Post) gold.
local function blizzButtonState(b)
  local s = skins[b]
  local on = b:IsEnabled()
  local over, down = s.over and on, s.down and on
  if s.main then
    setFill(b, not on and T.raised or down and T.accentBg or over and T.accentHi or T.accentBg)
    setEdge(b, on and T.accent or T.edge)
  else
    setFill(b, not on and T.surface or down and T.input or over and T.raisedHi or T.raised)
    setEdge(b, over and T.edgeHi or T.edge)
  end
end

local function styleButton(b)
  local s = paint(b, T.raised, T.edge)
  s.main = isMain(b)
  local hl = b.GetHighlightTexture and b:GetHighlightTexture()
  if hl then recolor(hl, { 0, 0, 0, 0 }) end
  local pushed = b.GetPushedTexture and b:GetPushedTexture()
  if pushed and not pushed:GetAtlas() then pushed:SetAlpha(0) end
  b:HookScript("OnEnter", function() s.over = true; blizzButtonState(b) end)
  b:HookScript("OnLeave", function() s.over, s.down = false, false; blizzButtonState(b) end)
  b:HookScript("OnMouseDown", function() s.down = true; blizzButtonState(b) end)
  b:HookScript("OnMouseUp", function() s.down = false; blizzButtonState(b) end)
  pcall(b.HookScript, b, "OnEnable", function() blizzButtonState(b) end)
  pcall(b.HookScript, b, "OnDisable", function() blizzButtonState(b) end)
  blizzButtonState(b)
end

-- Tabs hang under the frame and overlap their neighbours by 15; the insets leave a 1 px gap between them. The active
-- tab is the surface color with a gold line along its bottom; the others sit darker.
local function tabState(tab, selected)
  if not tabs[tab] then return end
  local s = paint(tab, selected and T.surface or T.bg, T.edge)
  if not s.bar then
    s.bar = tab:CreateTexture(nil, "BORDER", nil, -6)
    s.bar:SetPoint("BOTTOMLEFT", s.fill, 1, 1)
    s.bar:SetPoint("BOTTOMRIGHT", s.fill, -1, 1)
    s.bar:SetHeight(2)
    s.bar:SetColorTexture(unpack(T.accent))
  end
  s.bar:SetShown(selected and true or false)
  tabs[tab] = selected and "on" or "off"
end

local function styleTab(tab)
  tabs[tab] = "off"
  paint(tab, T.bg, T.edge, 8, -3, -8, 6)
  local p = tab:GetParent()
  tabState(tab, p and p.selectedTab and tab.GetID and p.selectedTab == tab:GetID())
  tab:HookScript("OnEnter", function() if tabs[tab] ~= "on" then setEdge(tab, T.edgeHi) end end)
  tab:HookScript("OnLeave", function() if tabs[tab] ~= "on" then setEdge(tab, T.edge) end end)
end

local function styleScrollBar(sb)
  local track = sb.Track
  local thumb = (track and track.Thumb) or sb.Thumb
  for _, r in ipairs({ sb:GetRegions() }) do if isTex(r) then kill(r) end end
  if sb.Background then
    if isTex(sb.Background) then kill(sb.Background)
    else for _, r in ipairs({ sb.Background:GetRegions() }) do if isTex(r) then kill(r) end end end
  end
  if track then
    for _, r in ipairs({ track:GetRegions() }) do if isTex(r) then kill(r) end end
    paint(track, T.input, T.input)
  end
  if thumb then
    for _, r in ipairs({ thumb:GetRegions() }) do if isTex(r) then kill(r) end end
    paint(thumb, T.thumb, T.thumb, 2, 0, -2, 0)
    thumb:HookScript("OnEnter", function() paint(thumb, T.edgeHi, T.edgeHi) end)
    thumb:HookScript("OnLeave", function() paint(thumb, T.thumb, T.thumb) end)
  end
end

local function styleCategory(b)
  kill(b.NormalTexture)
  kill(b.Lines)
  recolor(b.HighlightTexture, T.hover)
  recolor(b.SelectedTexture, T.select)
end

local function styleRow(row)
  recolor(row.HighlightTexture, T.hover)
  local sel = row.SelectedHighlight
  recolor(sel, T.select)
  if isTex(sel) then
    local bar = row:CreateTexture(nil, "OVERLAY", nil, 7)
    bar:SetPoint("TOPLEFT", sel)
    bar:SetPoint("BOTTOMLEFT", sel)
    bar:SetWidth(2)
    bar:SetColorTexture(unpack(T.accent))
    local function sync() bar:SetShown(sel:IsShown()) end
    hooksecurefunc(sel, "Show", sync)
    hooksecurefunc(sel, "Hide", sync)
    hooksecurefunc(sel, "SetShown", sync)
    sync()
  end
end

local function styleClose(b)
  for _, get in ipairs({ "GetNormalTexture", "GetPushedTexture", "GetHighlightTexture", "GetDisabledTexture" }) do
    local t = b[get] and b[get](b)
    if t then kill(t) end
  end
  local lines = {}
  for k, angle in ipairs({ 45, -45 }) do
    local t = b:CreateTexture(nil, "ARTWORK")
    t:SetColorTexture(unpack(T.dim))
    t:SetSize(13, 2)
    t:SetPoint("CENTER")
    t:SetRotation(math.rad(angle))
    lines[k] = t
  end
  b:HookScript("OnEnter", function() for _, t in ipairs(lines) do t:SetColorTexture(unpack(T.text)) end end)
  b:HookScript("OnLeave", function() for _, t in ipairs(lines) do t:SetColorTexture(unpack(T.dim)) end end)
end

local function flatten(f)
  local bd = f:GetBackdrop()
  if not bd or bd.bgFile == FLAT then return end
  local hasEdge = bd.edgeFile ~= nil
  f:SetBackdrop({ bgFile = FLAT, edgeFile = hasEdge and FLAT or nil, edgeSize = 1 })
  f:SetBackdropColor(unpack(hasEdge and T.surface or T.input))
  if hasEdge then f:SetBackdropBorderColor(unpack(T.edge)) end
end

-- Art that is only decoration, by key...
local TEX_KEYS = {
  "Left", "Middle", "Right", "Mid",
  "LeftActive", "MiddleActive", "RightActive",
  "LeftHighlight", "MiddleHighlight", "RightHighlight",
  "LeftDisabled", "MiddleDisabled", "RightDisabled",
  "Background", "Bg", "BG", "TopTileStreaks",
}
-- ...by atlas...
local function decorAtlas(a)
  return a:find("^auctionhouse%-background") or a:find("itemheaderframe") or a:find("selltab")
    or a:find("^auctionhouse%-nav%-button") or a:find("^common%-dropdown") or a:find("^common%-search%-border")
end
-- ...and by file.
local function decorFile(p)
  p = p:lower()
  return p:find("auctionframe\\ui%-auction") or p:find("framegeneral\\ui%-frame") or p:find("ui%-textbackground")
end

local function isFrame(f)
  return type(f) == "table" and f.GetObjectType and f:GetObjectType() == "Frame"
end
local function isNineSlice(f)
  return isFrame(f) and (f.layoutType or f.TopLeftCorner or f.Center) ~= nil
end

local watched = setmetatable({}, { __mode = "k" })
local walk

local function watchScrollBox(sb)
  if watched[sb] then return end
  watched[sb] = true
  -- rows are made as the list scrolls; style each new one
  local okAdd = ScrollUtil and ScrollUtil.AddAcquiredFrameCallback
    and pcall(ScrollUtil.AddAcquiredFrameCallback, sb, function(_, frame) walk(frame) end, sb, true)
  if not okAdd and sb.Update then
    hooksecurefunc(sb, "Update", function() walk(sb.ScrollTarget or sb) end)
  end
end

local function style(f)
  if f.IsForbidden and f:IsForbidden() then return end
  if f.Track and (f.Track.Thumb or f.Thumb) then styleScrollBar(f); return end
  if f.SelectedTexture and f.Lines then styleCategory(f); return end
  if f.SelectedHighlight and f.HighlightTexture then styleRow(f) end
  if f.ScrollTarget then watchScrollBox(f) end
  if f == (_G.AuctionHouseFrame and _G.AuctionHouseFrame.CloseButton) then styleClose(f); return end

  local killed = false
  if isFrame(f.NineSlice) then kill(f.NineSlice); killed = true end
  if isNineSlice(f.Border) then kill(f.Border); killed = true end
  if f.PortraitContainer then kill(f.PortraitContainer); killed = true end
  for _, k in ipairs(TEX_KEYS) do
    local r = f[k]
    if isTex(r) then kill(r); killed = true end
  end
  for _, r in ipairs({ f:GetRegions() }) do
    if isTex(r) and r:GetParent() == f then
      local a = r:GetAtlas()
      if a and a:find("rowstripe") then
        recolor(r, T.stripe)
      elseif a and decorAtlas(a) then
        kill(r); killed = true
      else
        local okPath, p = pcall(r.GetTextureFilePath, r)
        if okPath and type(p) == "string" and decorFile(p) then kill(r); killed = true end
      end
    end
  end

  if f.GetBackdrop and f:GetBackdrop() then flatten(f) end
  if not killed then return end
  if f:IsObjectType("EditBox") then
    paint(f, T.input, T.edge, -5, 0, 0, 0)
    f:HookScript("OnEnter", function() if not f:HasFocus() then setEdge(f, T.edgeHi) end end)
    f:HookScript("OnLeave", function() if not f:HasFocus() then setEdge(f, T.edge) end end)
    f:HookScript("OnEditFocusGained", function() setEdge(f, T.accent) end)
    f:HookScript("OnEditFocusLost", function() setEdge(f, T.edge) end)
  elseif f:IsObjectType("Button") then
    if f.LeftActive or f.MiddleActive then styleTab(f) else styleButton(f) end
  elseif f == _G.AuctionHouseFrame then
    paint(f, T.bg, T.edge)
    shadow(f, 6)
    -- the title bar: a raised band with a line under it
    local band = f:CreateTexture(nil, "BACKGROUND", nil, -7)
    band:SetPoint("TOPLEFT", 1, -1)
    band:SetPoint("TOPRIGHT", -1, -1)
    band:SetHeight(22)
    band:SetColorTexture(unpack(T.raised))
    local line = f:CreateTexture(nil, "BORDER", nil, -6)
    line:SetPoint("TOPLEFT", band, "BOTTOMLEFT")
    line:SetPoint("TOPRIGHT", band, "BOTTOMRIGHT")
    onePixel(line, true)
    line:SetColorTexture(unpack(T.edge))
  else
    paint(f, T.surface, T.edge)
  end
end

function walk(f)
  if type(f) ~= "table" or not f.GetChildren or own[f] then return end
  if not styled[f] then
    styled[f] = true
    local okStyle, err = pcall(style, f)
    if not okStyle and ns.skinErrors then ns.skinErrors[#ns.skinErrors + 1] = err end
  end
  for _, c in ipairs({ f:GetChildren() }) do walk(c) end
end
ns.skinErrors = {}

local applied = false
local function apply()
  local ah = _G.AuctionHouseFrame
  if not ah or not enabled() then return end
  walk(ah)
  if applied then return end
  applied = true
  pcall(hooksecurefunc, "PanelTemplates_SelectTab", function(t) tabState(t, true) end)
  pcall(hooksecurefunc, "PanelTemplates_DeselectTab", function(t) tabState(t, false) end)
  if ah.SetDisplayMode then hooksecurefunc(ah, "SetDisplayMode", function() walk(ah) end) end
  ah:HookScript("OnShow", function() C_Timer.After(0.3, function() walk(ah) end) end)
end
ns.applySkin = apply

local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("AUCTION_HOUSE_SHOW")
ev:SetScript("OnEvent", function(_, e, name)
  if e == "ADDON_LOADED" and name ~= "Blizzard_AuctionHouseUI" then return end
  apply()
  -- the Selling tab is made a moment after the auction house opens
  C_Timer.After(0.4, apply)
end)
if _G.AuctionHouseFrame then apply() end

-- /eah skin
local prevSlash, prevHelp = ns.slash, ns.help
function ns.slash(msg)
  if msg == "skin" or msg == "skin on" or msg == "skin off" then
    local db = ns.db()
    if msg == "skin" then db.skin = db.skin == false else db.skin = msg == "skin on" end
    ns.say(("EverlookDB look is %s. Type /reload to apply."):format(db.skin and "on" or "off"))
    return true
  end
  if msg == "skin errors" then
    ns.say(#ns.skinErrors .. " skin errors")
    for i = 1, math.min(10, #ns.skinErrors) do print("  " .. tostring(ns.skinErrors[i])) end
    return true
  end
  return prevSlash and prevSlash(msg) or false
end
function ns.help()
  if prevHelp then prevHelp() end
  print(("  /eah skin on|off  the EverlookDB look for the auction house (now %s)"):format(enabled() and "on" or "off"))
end
