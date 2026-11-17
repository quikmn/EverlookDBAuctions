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
  mute     = { 0.471, 0.502, 0.557, 1 },     -- #78808e  labels, disabled (4.5:1 on the surface)
  accent   = { 1, 0.82, 0, 1 },              -- #ffd100  EverlookDB gold: active tab, selection, main actions
  accentBg = { 0.196, 0.161, 0.043, 1 },     -- #32290b  main action fill
  accentHi = { 0.263, 0.216, 0.063, 1 },     -- #433710  main action hovered
  hover    = { 1, 1, 1, 0.045 },             -- row hover
  select   = { 1, 0.82, 0, 0.10 },           -- selected row
  stripe   = { 1, 1, 1, 0.018 },             -- every other row
  thumb    = { 0.239, 0.263, 0.310, 1 },     -- scroll thumb
  good     = { 0.427, 0.792, 0.478, 1 },     -- #6dca7a
  bad      = { 0.925, 0.373, 0.341, 1 },     -- #ec5f57
  badBg    = { 0.212, 0.090, 0.086, 1 },     -- #361716  danger action hovered
  info     = { 0.478, 0.698, 1, 1 },         -- #7ab2ff
  accentUp = { 1, 0.871, 0.251, 1 },         -- #ffde40  main action hovered
  onAccent = { 0.090, 0.071, 0.012, 1 },     -- #171203  text on a gold fill
  sheen    = { 1, 1, 1, 0.05 },              -- the light top edge of raised things
  glow     = { 1, 0.82, 0, 0.22 },           -- soft ring around a focused box or an armed button
}
-- Where you are: one colour per place of the addon. It shows in the place's thin border, its title text, its tab's
-- selected line and text, its section headers and the focus ring of its boxes. Gold stays for the one main action of
-- a screen (Buy, Post, Search...), so money and actions look the same everywhere; this colour only says where you
-- are. All read at 5:1 or better on the window background and stay apart for red-green and blue-yellow colour
-- blindness. Blizzard's own views keep their look.
T.places = {
  search   = { 0.200, 0.573, 1, 1 },         -- #3392ff  Advanced search and its buy panel: blue
  sell     = { 0.325, 0.776, 0.573, 1 },     -- #53c692  Quick sell: green
  shopping = { 0.765, 0.651, 1, 1 },         -- #c3a6ff  Shopping: violet
  prices   = { 0.561, 0.663, 0.710, 1 },     -- #8fa9b5  price updates (the bar along the bottom): cyan-grey
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

-- Marks f as a place (a key of T.places); everything inside it takes that place's colour. Returns the colour.
function UI.place(f, name)
  assert(T.places[name], "unknown place " .. tostring(name))
  f.edbPlace = name
  return T.places[name]
end

-- The colour of the place f is in (f or the nearest parent marked with UI.place), else gold; and the place's name.
function UI.accentOf(f)
  local depth = 0
  while type(f) == "table" and depth < 30 do
    local p = rawget(f, "edbPlace")
    if p and T.places[p] then return T.places[p], p end
    f = f.GetParent and f:GetParent() or nil
    depth = depth + 1
  end
  return T.accent
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

-- Raised things (buttons, header bands) are a touch lighter at the top, so they read as raised, not printed.
local LIFT = 0.022
local canGradient = CreateColor ~= nil
local function shade(tex, c, lift)
  if lift and canGradient and tex.SetGradient then
    tex:SetColorTexture(1, 1, 1, 1)
    local a = c[4] or 1
    tex:SetGradient("VERTICAL", CreateColor(c[1], c[2], c[3], a),
      CreateColor(math.min(1, c[1] + lift), math.min(1, c[2] + lift), math.min(1, c[3] + lift), a))
  else
    tex:SetColorTexture(c[1], c[2], c[3], c[4] or 1)
  end
end
UI.shade, UI.LIFT = shade, LIFT

local function setFill(f, fill)
  local s = skins[f]
  if s then shade(s.fill, fill, s.lift) end
end

UI.paint, UI.setEdge, UI.setFill = paint, setEdge, setFill

-- A section: surface fill and border (or the colors given).
function UI.panel(f, fill, edge)
  paint(f, fill or T.surface, edge or T.edge)
  return f
end

-- base mixed with a share a (0..1) of colour c: panels take a light wash of their place's colour, so a place reads
-- as that colour across the whole panel, not just its edge.
function UI.tint(base, c, a)
  return { base[1] + (c[1] - base[1]) * a, base[2] + (c[2] - base[2]) * a, base[3] + (c[3] - base[3]) * a, base[4] or 1 }
end
UI.WASH, UI.WASH_INNER, UI.WASH_EDGE = 0.10, 0.08, 0.45

-- A place's frame: a 2 px border in its colour around the whole panel, so you see at a glance which part of the
-- addon you are in (the 1 px panel edge alone was too faint to read as a colour).
function UI.placeEdge(f, c)
  local W = 2
  local function bar(p1, p2, horizontal)
    local t = f:CreateTexture(nil, "OVERLAY", nil, 7)
    t:SetColorTexture(unpack(c))
    t:SetPoint(p1)
    t:SetPoint(p2)
    if horizontal then t:SetHeight(W) else t:SetWidth(W) end
    return t
  end
  return { bar("TOPLEFT", "TOPRIGHT", true), bar("BOTTOMLEFT", "BOTTOMRIGHT", true),
    bar("TOPLEFT", "BOTTOMLEFT", false), bar("TOPRIGHT", "BOTTOMRIGHT", false) }
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
-- Colors that change smoothly: a hover or press fades over a tenth of a second instead of snapping. One shared
-- frame runs only while something is fading.

local FADE = 0.10
local fading = {}
local fader = CreateFrame("Frame")
local function lerp(a, b, t)
  return { a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, a[3] + (b[3] - a[3]) * t,
    (a[4] or 1) + ((b[4] or 1) - (a[4] or 1)) * t }
end
local function eased(f, now)
  local t = math.min(1, (now - f.start) / FADE)
  return 1 - (1 - t) * (1 - t), t
end
local function fadeStep()
  local now, any = GetTime(), false
  for obj, f in pairs(fading) do
    local e, t = eased(f, now)
    for k, to in pairs(f.to) do f.apply(obj, k, lerp(f.from[k], to, e)) end
    if t >= 1 then fading[obj] = nil else any = true end
  end
  if not any then fader:SetScript("OnUpdate", nil) end
end
-- Fades obj's named colors to `to` (name -> color); draw(obj, name, color) draws one. The first call, and
-- `instant`, draw at once.
local function fadeTo(obj, cur, to, draw, instant)
  if instant or not cur.shown then
    for k, c in pairs(to) do cur[k] = c; draw(obj, k, c) end
    cur.shown = true
    fading[obj] = nil
    return
  end
  local from, f, now = {}, fading[obj], GetTime()
  for k, c in pairs(to) do
    -- start from where a running fade is now, so a quick in-and-out stays smooth
    from[k] = (f and f.to[k]) and lerp(f.from[k], f.to[k], (eased(f, now))) or cur[k] or c
    cur[k] = c
  end
  fading[obj] = { start = now, from = from, to = to, apply = draw }
  fader:SetScript("OnUpdate", fadeStep)
end
UI.fadeTo = fadeTo

-- A soft 2 px ring just outside a frame (a focused box, an armed button); ring:SetShown(on).
local function ring(f)
  local r = CreateFrame("Frame", nil, f)
  r:SetPoint("TOPLEFT", -2, 2)
  r:SetPoint("BOTTOMRIGHT", 2, -2)
  for _, p in ipairs({ { "TOPLEFT", "TOPRIGHT", true }, { "BOTTOMLEFT", "BOTTOMRIGHT", true },
      { "TOPLEFT", "BOTTOMLEFT", false }, { "TOPRIGHT", "BOTTOMRIGHT", false } }) do
    local t = r:CreateTexture(nil, "BACKGROUND")
    t:SetPoint(p[1])
    t:SetPoint(p[2])
    if p[3] then t:SetHeight(2) else t:SetWidth(2) end
    t:SetColorTexture(unpack(T.glow))
    r[#r + 1] = t
  end
  -- r:EdbColor(c): the ring in a soft tint of c
  r.EdbColor = function(self, c)
    for _, t in ipairs(self) do t:SetColorTexture(c[1], c[2], c[3], T.glow[4]) end
  end
  r:Hide()
  return r
end
UI.ring = ring

---------------------------------------------------------------------------------------------------------------------
-- Buttons, by role:
--   "primary"  the one main action of a panel (Post, Buy, Search): solid gold with dark text
--   "danger"   something that takes an auction or a list away (Cancel, Delete): red text, a red tint on hover
--   "quiet"    a small housekeeping action that is not about money (Update prices, Try again): no fill, a thin
--              edge and text in the colour of the place it is in (UI.place), a faint tint on hover; compact text
--   plain      everything else: raised grey; can be a toggle (b:EdbActive(true)) with a gold edge and text, or in the
--              colour of its own place when the button itself is marked with UI.place (the Advanced search button)
-- Add "small" for the compact text in rows and toolbars ("small", "small danger"). An active primary button
-- (b:EdbActive(true), e.g. Confirm) gets a soft gold ring. Add tooltips with HookScript, so the hover look keeps
-- working.

local function buttonColors(b)
  local enabled = b:IsEnabled()
  local over, down, on = b.edbOver and enabled, b.edbDown and enabled, b.edbOn
  if b.edbRole == "quiet" then
    local c = UI.accentOf(b)
    if not enabled then return { c[1], c[2], c[3], 0 }, T.edge, T.mute end
    return { c[1], c[2], c[3], down and 0.20 or over and 0.12 or 0 },
      { c[1], c[2], c[3], over and 1 or 0.55 }, over and T.text or c
  end
  if not enabled then return b.edbRole == "primary" and T.raised or T.surface, T.edge, T.mute end
  if b.edbRole == "primary" then
    local fill = down and T.accentHi or over and T.accentUp or T.accent
    return fill, fill, down and T.accent or T.onAccent
  elseif b.edbRole == "danger" then
    return down and T.input or (over or on) and T.badBg or T.raised, (over or on) and T.bad or T.edge, T.bad
  end
  local onColor = rawget(b, "edbPlace") and T.places[b.edbPlace] or T.accent
  return down and T.input or (over or on) and T.raisedHi or T.raised,
    on and onColor or over and T.edgeHi or T.edge,
    on and onColor or T.text
end

local function drawButton(b, k, c)
  if k == "fill" then setFill(b, c)
  elseif k == "edge" then setEdge(b, c)
  elseif b.edbLabel then b.edbLabel:SetTextColor(c[1], c[2], c[3], c[4] or 1) end
end

local function buttonState(b, instant)
  local fill, edge, text = buttonColors(b)
  b.edbCur = b.edbCur or {}
  fadeTo(b, b.edbCur, { fill = fill, edge = edge, text = text }, drawButton, instant == true)
  local enabled = b:IsEnabled()
  if b.edbRing then b.edbRing:SetShown(b.edbOn and enabled and true or false) end
  b.edbSheen:SetShown(enabled and not b.edbDown and b.edbRole ~= "quiet" and true or false)
end

function UI.button(parent, label, w, h, kind)
  local b = CreateFrame("Button", nil, parent)
  b:SetSize(w or 100, h or 24)
  kind = kind or ""
  b.edbRole = kind:find("primary") and "primary" or kind:find("danger") and "danger"
    or kind:find("quiet") and "quiet" or nil
  local s = paint(b, T.raised, T.edge)
  s.lift = b.edbRole ~= "quiet" and LIFT or nil
  b.edbSheen = b:CreateTexture(nil, "BORDER", nil, -7)
  b.edbSheen:SetPoint("TOPLEFT", 1, -1)
  b.edbSheen:SetPoint("TOPRIGHT", -1, -1)
  onePixel(b.edbSheen, true)
  b.edbSheen:SetColorTexture(unpack(T.sheen))
  if b.edbRole == "primary" then b.edbRing = ring(b) end
  local fs = b:CreateFontString(nil, "OVERLAY")
  fs:SetFontObject(fontObject((kind:find("small") or kind:find("quiet")) and "small" or "body"))
  if b.edbRole == "primary" then fs:SetShadowOffset(0, 0) end   -- dark text on gold needs no shadow
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
  -- Enable, Disable and SetEnabled redraw it at once: no fade when the program changes it, only the pointer
  local function now() buttonState(b, true) end
  hooksecurefunc(b, "Enable", now)
  hooksecurefunc(b, "Disable", now)
  hooksecurefunc(b, "SetEnabled", now)
  b.EdbActive = function(self, on) self.edbOn = on and true or nil; buttonState(self) end
  b.EdbRefresh = function(self) buttonState(self, true) end
  buttonState(b, true)
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
-- Edit boxes: dark well, 1 px border that lights up on hover and, while typing, takes the colour of the place the box
-- is in (gold outside one). opts.hint shows grey text
-- while empty; opts.numeric allows digits only; opts.right aligns right; opts.max limits the length.
-- opts.lines makes a box that many lines tall whose text wraps: still one line of text (Enter runs opts.onEnter
-- instead of breaking the line, pasted line breaks become spaces), scrolled to keep the cursor in view. Anchor and
-- size box.edbWell (the box itself when it is one line). opts.onEnter runs on Enter; without it Enter clears focus.

-- Text with its line breaks as single spaces, and no spaces left at either end where a break was.
function UI.oneLine(text)
  text = tostring(text or "")
  if not text:find("[\r\n]") then return text end
  return (text:gsub("%s*[\r\n]+%s*", " "):gsub("^%s+", ""):gsub("%s+$", ""))
end

function UI.input(parent, w, h, opts)
  opts = opts or {}
  local lines = opts.lines and opts.lines > 1 and opts.lines
  local e, well
  if lines then
    -- the well holds a scroll frame that clips the box to the well; the box grows as its text wraps
    well = CreateFrame("Frame", nil, parent)
    well:SetSize(w or 120, h or 24)
    local clip = CreateFrame("ScrollFrame", nil, well)
    clip:SetPoint("TOPLEFT", 0, -1)
    clip:SetPoint("BOTTOMRIGHT", 0, 1)
    e = CreateFrame("EditBox", nil, clip)
    e:SetMultiLine(true)
    clip:SetScrollChild(e)
    e:SetSize(w or 120, (h or 24) - 2)
    clip:HookScript("OnSizeChanged", function(_, cw, ch)
      e:SetWidth(cw)
      if (e:GetHeight() or 0) < ch then e:SetHeight(ch) end
    end)
    e:SetTextInsets(7, 7, 4, 4)
    -- keep the line with the cursor in view
    e:HookScript("OnCursorChanged", function(_, _, y, _, lineH)
      local top, view, at = -(y or 0), clip:GetHeight() or 0, clip:GetVerticalScroll() or 0
      if top - 4 < at then at = top - 4
      elseif top + (lineH or 0) + 4 > at + view then at = top + (lineH or 0) + 4 - view end
      local range = clip.GetVerticalScrollRange and clip:GetVerticalScrollRange() or at
      clip:SetVerticalScroll(math.max(0, math.min(at, math.max(range, 0))))
    end)
  else
    e = CreateFrame("EditBox", nil, parent)
    e:SetSize(w or 120, h or 24)
    e:SetTextInsets(7, 7, 0, 0)
    well = e
  end
  e.edbWell = well
  e:SetAutoFocus(false)
  e:SetFontObject(fontObject("body"))
  e:SetJustifyH(opts.right and "RIGHT" or "LEFT")
  if opts.numeric then e:SetNumeric(true) end
  if opts.max then e:SetMaxLetters(opts.max) end
  paint(well, T.input, T.edge)
  e.edbRing = ring(well)
  local hint
  local function edge()
    local focus = e:HasFocus()
    local c = focus and UI.accentOf(well)
    setEdge(well, c or e.edbOver and T.edgeHi or T.edge)
    if c then e.edbRing:EdbColor(c) end
    e.edbRing:SetShown(focus)
    if hint then hint:SetShown(e:GetText() == "" and not e:HasFocus()) end
  end
  if opts.hint then
    hint = UI.text(e, "mute")
    e.edbHint = hint
    if lines then
      hint:SetPoint("TOPLEFT", 7, -4)
      hint:SetPoint("RIGHT", -7, 0)
    else
      hint:SetPoint("LEFT", 7, 0)
      hint:SetPoint("RIGHT", -7, 0)
    end
    hint:SetJustifyH(opts.right and "RIGHT" or "LEFT")
    hint:SetText(opts.hint)
  end
  -- Enter: once per key press, whether the game reports it as Enter or as a typed line break
  local entered
  local function enter()
    local now = GetTime()
    if entered == now then return end
    entered = now
    if opts.onEnter then opts.onEnter(e) else e:ClearFocus() end
  end
  if lines then
    local before = ""
    e:HookScript("OnTextChanged", function(self, typed)
      local text = self:GetText()
      if text:find("[\r\n]") then
        -- one break typed and nothing else changed: that was Enter, so the text goes back to what it was
        local i = text:find("[\r\n]")
        local wasEnter = typed and text:sub(1, i - 1) .. text:sub(i + 1) == before
        local clean = wasEnter and before or UI.oneLine(text)
        local pos = wasEnter and i - 1 or self:GetCursorPosition() or #clean
        before = clean
        self:SetText(clean)
        self:SetCursorPosition(math.min(pos, #clean))
        if wasEnter then enter() end
        return
      end
      before = text
    end)
  end
  e:HookScript("OnEnter", function() e.edbOver = true; edge() end)
  e:HookScript("OnLeave", function() e.edbOver = false; edge() end)
  e:HookScript("OnEditFocusGained", edge)
  e:HookScript("OnEditFocusLost", edge)
  e:HookScript("OnTextChanged", edge)
  e:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  e:SetScript("OnEnterPressed", enter)
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
-- Scroll bar: a 12 px track with a thumb you grab and drag with the left mouse button; a click on the track above or
-- below the thumb jumps a page; the mouse wheel over it scrolls too. It knows nothing about what it scrolls:
--   opts.get() the position now, opts.max() the furthest position, opts.set(v) scrolls there (v is whole and in
--   range), opts.view() how much of the whole is visible (0..1), opts.page() how far one page is, opts.wheel how far
--   one wheel notch goes. Positions are whole numbers (rows, or pixels: half pixels blur text).
-- bar:Update() after the content or the position changes; it hides itself when there's nothing to scroll.

UI.BAR_W = 12
local BAR_MIN_THUMB = 30

-- Where a drag puts the position: the start position plus the cursor's travel, scaled from the room the thumb has
-- to move in to the whole range. Whole numbers, never past either end.
function UI.scrollDrag(start, travel, room, max)
  if not room or room <= 0 or not max or max <= 0 then return 0 end
  local v = math.floor(start + travel * max / room + 0.5)
  return math.max(0, math.min(max, v))
end

-- The thumb's height and how far down the track it sits.
function UI.scrollThumb(trackH, view, pos, max)
  local h = math.min(trackH, math.max(BAR_MIN_THUMB, trackH * math.max(0, math.min(1, view or 1))))
  local y = (max and max > 0) and (trackH - h) * math.max(0, math.min(1, pos / max)) or 0
  return h, y
end

function UI.scrollbar(parent, opts)
  local bar = CreateFrame("Frame", nil, parent)
  bar:SetWidth(UI.BAR_W)
  local track = bar:CreateTexture(nil, "BACKGROUND")
  track:SetAllPoints()
  track:SetColorTexture(unpack(T.input))
  local thumb = CreateFrame("Frame", nil, bar)
  thumb:SetWidth(UI.BAR_W)
  local tt = thumb:CreateTexture(nil, "ARTWORK")
  tt:SetPoint("TOPLEFT", 2, 0)
  tt:SetPoint("BOTTOMRIGHT", -2, 0)
  tt:SetColorTexture(unpack(T.thumb))
  bar.thumb = thumb

  local function maxPos() return math.max(0, math.floor((opts.max() or 0) + 0.5)) end
  local function lit(on) tt:SetColorTexture(unpack(on and T.edgeHi or T.thumb)) end
  local function set(v)
    v = math.max(0, math.min(maxPos(), math.floor(v + 0.5)))
    if v ~= opts.get() then opts.set(v) end
    bar:Update()
  end
  bar.Scroll = function(_, by) set(opts.get() + by) end

  function bar:Update()
    local m = maxPos()
    if m <= 0 then self:Hide(); return end
    local trackH = self:GetHeight()
    if not trackH or trackH <= 0 then return end
    local h, y = UI.scrollThumb(trackH, opts.view(), opts.get(), m)
    thumb:SetHeight(h)
    thumb:ClearAllPoints()
    thumb:SetPoint("TOP", self, "TOP", 0, -y)
    self:Show()
  end

  thumb:EnableMouse(true)
  thumb:SetScript("OnEnter", function() lit(true) end)
  thumb:SetScript("OnLeave", function(self) if not self.drag then lit(false) end end)
  -- follows the cursor every frame only while dragging: an idle scroll bar does no per-frame work
  local function follow(self)
    local d = self.drag
    if not d then self:SetScript("OnUpdate", nil); return end
    if not IsMouseButtonDown("LeftButton") then self.drag = nil; self:SetScript("OnUpdate", nil); lit(self:IsMouseOver()); return end
    local _, y = GetCursorPosition()
    y = y / self:GetEffectiveScale()
    set(UI.scrollDrag(d.start, d.y - y, bar:GetHeight() - self:GetHeight(), maxPos()))
  end
  thumb:SetScript("OnMouseDown", function(self, button)
    if button ~= "LeftButton" then return end
    local _, y = GetCursorPosition()
    self.drag = { y = y / self:GetEffectiveScale(), start = opts.get() }
    lit(true)
    self:SetScript("OnUpdate", follow)
  end)
  local function stop(self)
    self.drag = nil
    self:SetScript("OnUpdate", nil)
    lit(self:IsMouseOver())
  end
  thumb:SetScript("OnMouseUp", stop)
  thumb:SetScript("OnHide", function(self) self.drag = nil; self:SetScript("OnUpdate", nil); lit(false) end)
  bar:EnableMouse(true)
  bar:SetScript("OnMouseDown", function(self, button)
    if button ~= "LeftButton" then return end
    local _, y = GetCursorPosition()
    y = y / self:GetEffectiveScale()
    local page = math.max(1, opts.page() or 1)
    local bottom = thumb:GetBottom()
    if bottom and y < bottom then set(opts.get() + page) else set(opts.get() - page) end
  end)
  bar:EnableMouseWheel(true)
  bar:SetScript("OnMouseWheel", function(_, delta) set(opts.get() - delta * (opts.wheel or 1)) end)
  bar:SetScript("OnSizeChanged", function(self) self:Update() end)
  bar:Hide()
  return UI.own(bar)
end

-- A pixel-scrolling area: a ScrollFrame (anchor it yourself) showing child, with a scroll bar right of it, outside
-- it, so leave UI.BAR_W + 4 px free on its right. The wheel scrolls 40 px. Returns the ScrollFrame; scroll.bar is
-- the bar, scroll.Update() re-reads the content's height.
function UI.scrollFrame(parent, child)
  local scroll = CreateFrame("ScrollFrame", nil, parent)
  child:SetParent(scroll)
  scroll:SetScrollChild(child)
  local function maxScroll() return math.max(0, (child:GetHeight() or 0) - (scroll:GetHeight() or 0)) end
  local bar = UI.scrollbar(parent, {
    get = function() return scroll:GetVerticalScroll() end,
    max = maxScroll,
    set = function(v) scroll:SetVerticalScroll(v) end,
    view = function()
      local h, c = scroll:GetHeight() or 0, child:GetHeight() or 0
      return c > 0 and h / c or 1
    end,
    page = function() return (scroll:GetHeight() or 0) - 40 end,
    wheel = 40,
  })
  bar:SetPoint("TOPLEFT", scroll, "TOPRIGHT", 4, 0)
  bar:SetPoint("BOTTOMLEFT", scroll, "BOTTOMRIGHT", 4, 0)
  scroll.bar = bar
  local function update()
    local m = maxScroll()
    if scroll:GetVerticalScroll() > m then scroll:SetVerticalScroll(m) end
    if scroll:IsShown() then bar:Update() else bar:Hide() end
  end
  scroll.Update = update
  scroll:EnableMouseWheel(true)
  scroll:SetScript("OnMouseWheel", function(_, delta) bar:Scroll(-delta * 40) end)
  scroll:HookScript("OnVerticalScroll", function() bar:Update() end)
  scroll:HookScript("OnSizeChanged", update)
  scroll:HookScript("OnShow", update)
  scroll:HookScript("OnHide", function() bar:Hide() end)
  child:HookScript("OnSizeChanged", update)
  return scroll
end

---------------------------------------------------------------------------------------------------------------------
-- A scrolling list that only makes the rows that fit. build(list, i) makes row i (use UI.row);
-- fill(row, item, index) shows an item in it. list:SetItems(items), list:Refresh(). The mouse wheel and the scroll
-- bar on the right (drag it, or click above or below the thumb) scroll it; list.onScroll(list) runs after it scrolls.

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
  L.bar:Update()
end

local function listLayout(L)
  local want = math.max(0, math.floor((L:GetHeight() + 0.5) / L.rowH))
  for i = #L.rows + 1, want do
    local row = L.build(L, i)
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", L, "TOPLEFT", 0, -(i - 1) * L.rowH)
    row:SetPoint("RIGHT", L, "RIGHT", -(UI.BAR_W + 4), 0)
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
  local bar = UI.scrollbar(L, {
    get = function() return L.offset end,
    max = function() return #L.items - (L.count or 0) end,
    set = function(v) listScroll(L, v - L.offset) end,
    view = function() return #L.items > 0 and (L.count or 0) / #L.items or 1 end,
    page = function() return math.max(1, (L.count or 1) - 1) end,
    wheel = 3,
  })
  bar:SetPoint("TOPRIGHT", 0, 0)
  bar:SetPoint("BOTTOMRIGHT", 0, 0)
  L.bar = bar
  L:EnableMouseWheel(true)
  L:SetScript("OnMouseWheel", function(_, delta) bar:Scroll(-delta * 3) end)
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
  L.empty:SetPoint("RIGHT", -(UI.BAR_W + 10), 0)
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
  shade(bg, T.raised, LIFT)
  local line = UI.line(band, true)
  line:SetPoint("BOTTOMLEFT")
  line:SetPoint("BOTTOMRIGHT")
  return UI.own(band)
end

-- A check box with a label: b:EdbChecked(on), b.checked. onClick(b, checked) runs after a click.
function UI.check(parent, text, onClick)
  local b = CreateFrame("Button", nil, parent)
  b:SetHeight(20)
  local box = CreateFrame("Frame", nil, b)
  box:SetSize(16, 16)
  box:SetPoint("LEFT", 0, 0)
  paint(box, T.input, T.edge)
  local mark = box:CreateTexture(nil, "ARTWORK")
  mark:SetPoint("TOPLEFT", 4, -4)
  mark:SetPoint("BOTTOMRIGHT", -4, 4)
  mark:SetColorTexture(unpack(T.accent))
  local fs = UI.text(b, "body")
  fs:SetPoint("LEFT", box, "RIGHT", 8, 0)
  fs:SetText(text)
  b:SetWidth(24 + math.max(40, fs:GetStringWidth()))
  b.EdbChecked = function(self, on)
    self.checked = on and true or false
    mark:SetShown(self.checked)
  end
  b:SetScript("OnEnter", function() setEdge(box, T.edgeHi) end)
  b:SetScript("OnLeave", function() setEdge(box, T.edge) end)
  b:SetScript("OnClick", function(self)
    self:EdbChecked(not self.checked)
    if onClick then onClick(self, self.checked) end
  end)
  b:EdbChecked(false)
  return UI.own(b)
end

-- A status tag: short text on a faint tint of its color (Undercut, Lowest, Sold...). tag:EdbSet(text, color).
-- A text wider than the tag widens it (from its anchor), so it never spills over its neighbours.
function UI.badge(parent, w, h)
  local f = CreateFrame("Frame", nil, parent)
  f.edbW = w or 64
  f:SetSize(f.edbW, h or 16)
  f.bg = f:CreateTexture(nil, "BACKGROUND", nil, 3)
  f.bg:SetAllPoints()
  f.text = UI.text(f, "small")
  f.text:SetPoint("CENTER", 0, 0)
  f.EdbSet = function(self, text, color)
    self.text:SetText(text or "")
    color = color or T.mute
    self.text:SetTextColor(color[1], color[2], color[3], 1)
    self.bg:SetColorTexture(color[1], color[2], color[3], (text and text ~= "") and 0.14 or 0)
    self:SetWidth(math.max(self.edbW, math.ceil(self.text:GetStringWidth() or 0) + 10))
  end
  return UI.own(f)
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
    local fill = not on and T.raised or down and T.accentHi or over and T.accentUp or T.accent
    setFill(b, fill)
    setEdge(b, on and fill or T.edge)
    local fs = b.GetFontString and b:GetFontString()
    if fs then
      local c = on and T.onAccent or T.mute
      fs:SetTextColor(c[1], c[2], c[3], 1)
      fs:SetShadowOffset(0, 0)
    end
  else
    setFill(b, not on and T.surface or down and T.input or over and T.raisedHi or T.raised)
    setEdge(b, over and T.edgeHi or T.edge)
  end
end

local function styleButton(b)
  local s = paint(b, T.raised, T.edge)
  s.lift = LIFT
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
-- tab is the surface color with a line along its bottom: gold on Blizzard's tabs, the place's colour (and text) on
-- ours (marked with UI.place); the others sit darker.
local function tabState(tab, selected)
  if not tabs[tab] then return end
  local s = paint(tab, selected and T.surface or T.bg, T.edge)
  if not s.bar then
    s.bar = tab:CreateTexture(nil, "BORDER", nil, -6)
    s.bar:SetPoint("BOTTOMLEFT", s.fill, 1, 1)
    s.bar:SetPoint("BOTTOMRIGHT", s.fill, -1, 1)
    s.bar:SetHeight(2)
  end
  local place = rawget(tab, "edbPlace") and T.places[tab.edbPlace]
  s.bar:SetColorTexture(unpack(place or T.accent))
  s.bar:SetShown(selected and true or false)
  local fs = place and tab.GetFontString and tab:GetFontString()
  if fs then
    local c = selected and place or (NORMAL_FONT_COLOR and { NORMAL_FONT_COLOR:GetRGB() }) or T.accent
    fs:SetTextColor(c[1], c[2], c[3], 1)
  end
  -- Blizzard drops a selected tab's text 3 to 5 px to sit in its taller tab art; our flat tabs keep one shape, so the
  -- text stays in the middle of the tab, selected or not
  local text = tab.Text or (tab.GetFontString and tab:GetFontString())
  if text and text.SetPoint then
    text:ClearAllPoints()
    text:SetPoint("CENTER", s.fill, "CENTER", 0, 0)
  end
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

-- Your money, bottom left of the auction house: Blizzard's box is shorter than the coins, so they stuck out of its
-- top. Our box keeps Blizzard's bottom edge and width but is MONEY_BOX_H tall (the 13 px coins and text with room
-- above and below), and the money sits in its middle, 8 px in from the right, so four-digit gold still fits.
local MONEY_BOX_H = 24
local function moneyBox(f)
  -- the frame itself grows (it is anchored by its bottom, so it grows upward): Blizzard's own gold edge stretches
  -- with it, and box, edge and coins share one middle. Growing only our fill left the 19 px gold edge behind, and the
  -- coins, centred in the taller fill, stuck out of its top.
  f:SetHeight(MONEY_BOX_H)
  local s = paint(f, T.surface, T.edge)
  s.fill:ClearAllPoints()
  s.fill:SetAllPoints(f)
  local m = f.MoneyFrame
  m:ClearAllPoints()
  m:SetPoint("RIGHT", f, "RIGHT", -8, 0)
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
  elseif f == (_G.AuctionHouseFrame and _G.AuctionHouseFrame.MoneyFrameBorder) and f.MoneyFrame then
    moneyBox(f)
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

-- The addon's own texts that don't fit right now ("Below ven…"): buttons and tags on screen whose label is cut off
-- or wider than they are. For /eah debug, so cut-off labels can be found without hunting for them.
function UI.cutOff()
  local out = {}
  for f in pairs(own) do
    local fs = f.edbLabel or (f.edbW and f.text)
    if fs and f.IsVisible and f:IsVisible() then
      local text = fs:GetText() or ""
      local need = (fs.GetUnboundedStringWidth and fs:GetUnboundedStringWidth()) or fs:GetStringWidth() or 0
      local room = (f:GetWidth() or 0) - (f.edbLabel and 8 or 4)   -- a button's label sits 4 px in from each side
      local cut = (fs.IsTruncated and fs:IsTruncated()) or need > room
      if text ~= "" and cut then
        local p = f:GetParent()
        out[#out + 1] = ("\"%s\" (%d px wide, needs %d) in %s"):format((text:gsub("|", "||")), f:GetWidth() or 0,
          math.ceil(need) + (f.edbLabel and 8 or 4), tostring(p and p.GetName and p:GetName() or "an unnamed frame"))
      end
    end
  end
  table.sort(out)
  return out
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("AUCTION_HOUSE_SHOW")
ev:SetScript("OnEvent", function(_, e, name)
  if e == "ADDON_LOADED" and name ~= "Blizzard_AuctionHouseUI" then return end
  apply()
  -- the Quick sell tab is made a moment after the auction house opens
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
    if ns.optionsRefresh then ns.optionsRefresh() end   -- the settings window shows it if it is open
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
  print(("  /eah skin on  or  /eah skin off  the EverlookDB look for the auction house (now %s)"):format(enabled() and "on" or "off"))
end
