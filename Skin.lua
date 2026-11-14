-- EverlookDB look for the whole auction house: flat navy panels, thin borders, gold for the active tab and the main
-- actions (the same look as everlookdb.com). Only the art changes: Blizzard's auction house keeps doing all the
-- searching, buying and posting underneath. /eah skin turns it off (after a /reload).
local _, ns = ...

local C = {
  bg     = { 0.071, 0.094, 0.149, 0.97 },  -- #121826
  panel  = { 0.094, 0.125, 0.200, 1 },     -- #182033
  input  = { 0.047, 0.063, 0.106, 1 },
  edge   = { 0.169, 0.212, 0.322, 1 },     -- #2b3652
  gold   = { 1, 0.82, 0, 1 },              -- #ffd100
  hover  = { 1, 1, 1, 0.06 },
  select = { 1, 0.82, 0, 0.16 },
  stripe = { 1, 1, 1, 0.025 },
  thumb  = { 0.28, 0.33, 0.46, 1 },
  cross  = { 0.55, 0.60, 0.70, 1 },
}
ns.colors = C

local function enabled()
  local db = ns.db and ns.db()
  return not db or db.skin ~= false
end

local FLAT = "Interface\\Buttons\\WHITE8x8"
local hidden = CreateFrame("Frame")
hidden:Hide()
local styled = setmetatable({}, { __mode = "k" })
local skins = setmetatable({}, { __mode = "k" })
local tabs = setmetatable({}, { __mode = "k" })

local function isTex(r)
  return type(r) == "table" and r.GetObjectType and r:GetObjectType() == "Texture"
end

-- Moved under a hidden frame, so it stays gone even when Blizzard sets its art again (tabs, buttons and scroll
-- thumbs change their art on hover and press).
local function kill(r)
  if not r then return end
  if not pcall(r.SetParent, r, hidden) then r:SetAlpha(0) end
end

local function onePixel(t, horizontal)
  if PixelUtil then
    if horizontal then PixelUtil.SetHeight(t, 1, 1) else PixelUtil.SetWidth(t, 1, 1) end
  elseif horizontal then t:SetHeight(1) else t:SetWidth(1) end
end

-- A soft top-to-bottom gradient of a color: a little lighter at the top, a little darker at the bottom.
local function shade(t, c, lift)
  lift = lift or 0.035
  local ok = CreateColor and pcall(function()
    t:SetColorTexture(1, 1, 1, 1)
    t:SetGradient("VERTICAL", CreateColor(c[1] - lift * 0.5, c[2] - lift * 0.5, c[3] - lift * 0.5, c[4] or 1),
      CreateColor(c[1] + lift, c[2] + lift, c[3] + lift, c[4] or 1))
  end)
  if not ok then t:SetColorTexture(unpack(c)) end
end

-- A soft drop shadow outside the frame: rings one pixel wide, fading out.
local function shadow(f, size)
  size = size or 6
  for i = 1, size do
    local alpha = 0.32 * (1 - (i - 1) / size)
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

-- A gradient fill with a 1 px border, drawn behind the frame's own content. l/t/r/b move the edges.
local function paint(f, fill, edge, l, t, r, b)
  local s = skins[f]
  if not s then
    s = {}
    s.fill = f:CreateTexture(nil, "BACKGROUND", nil, -8)
    s.fill:SetPoint("TOPLEFT", l or 0, t or 0)
    s.fill:SetPoint("BOTTOMRIGHT", r or 0, b or 0)
    s.top = f:CreateTexture(nil, "BORDER", nil, -8)
    s.top:SetPoint("TOPLEFT", s.fill)
    s.top:SetPoint("TOPRIGHT", s.fill)
    onePixel(s.top, true)
    s.bottom = f:CreateTexture(nil, "BORDER", nil, -8)
    s.bottom:SetPoint("BOTTOMLEFT", s.fill)
    s.bottom:SetPoint("BOTTOMRIGHT", s.fill)
    onePixel(s.bottom, true)
    s.left = f:CreateTexture(nil, "BORDER", nil, -8)
    s.left:SetPoint("TOPLEFT", s.fill)
    s.left:SetPoint("BOTTOMLEFT", s.fill)
    onePixel(s.left, false)
    s.right = f:CreateTexture(nil, "BORDER", nil, -8)
    s.right:SetPoint("TOPRIGHT", s.fill)
    s.right:SetPoint("BOTTOMRIGHT", s.fill)
    onePixel(s.right, false)
    -- a faint light line just inside the top edge, so panels and buttons read as raised
    s.shine = f:CreateTexture(nil, "BORDER", nil, -7)
    s.shine:SetPoint("TOPLEFT", s.fill, 1, -1)
    s.shine:SetPoint("TOPRIGHT", s.fill, -1, -1)
    onePixel(s.shine, true)
    s.shine:SetColorTexture(1, 1, 1, 0.07)
    skins[f] = s
  end
  if fill then shade(s.fill, fill) end
  if edge then
    for _, k in ipairs({ "top", "bottom", "left", "right" }) do s[k]:SetColorTexture(unpack(edge)) end
  end
  s.edgeColor = edge or s.edgeColor
  return s
end

local function setEdge(f, edge)
  local s = skins[f]
  if not s then return end
  for _, k in ipairs({ "top", "bottom", "left", "right" }) do s[k]:SetColorTexture(unpack(edge)) end
end

-- A plain color that stays when Blizzard sets the texture's art again.
local function recolor(t, color)
  if not isTex(t) then return end
  local function apply()
    t:SetColorTexture(unpack(color))
    t:SetBlendMode("BLEND")
  end
  apply()
  if not skins[t] then
    skins[t] = true
    hooksecurefunc(t, "SetAtlas", apply)
    hooksecurefunc(t, "SetTexture", function(_, file) if file then apply() end end)
  end
end

-- Hover: the border turns gold; the main actions keep a gold border.
local function hoverEdge(f, base)
  f:HookScript("OnEnter", function() setEdge(f, C.gold) end)
  f:HookScript("OnLeave", function() setEdge(f, base) end)
end

local MAIN = { SearchButton = true, BuyoutButton = true, BuyButton = true, PostButton = true, BuyNowButton = true }

local function keyOf(f)
  local p = f:GetParent()
  if not p then return nil end
  for k in pairs(MAIN) do if rawget(p, k) == f then return k end end
end

local function styleButton(b)
  local base = keyOf(b) and C.gold or C.edge
  paint(b, C.panel, base)
  local hl = b.GetHighlightTexture and b:GetHighlightTexture()
  if hl then recolor(hl, C.hover) end
  local pushed = b.GetPushedTexture and b:GetPushedTexture()
  if pushed and not pushed:GetAtlas() then pushed:SetAlpha(0) end
  hoverEdge(b, base)
  b:HookScript("OnMouseDown", function() if b:IsEnabled() then shade(skins[b].fill, C.input) end end)
  b:HookScript("OnMouseUp", function() shade(skins[b].fill, C.panel) end)
end

-- Tabs hang under the frame and overlap their neighbours by 15; the insets leave a 1 px gap between them.
local function tabState(tab, selected)
  if not tabs[tab] then return end
  local s = paint(tab, selected and C.panel or C.bg, selected and C.gold or C.edge)
  if not s.bar then
    s.bar = tab:CreateTexture(nil, "BORDER", nil, -6)
    s.bar:SetPoint("BOTTOMLEFT", s.fill, 1, 1)
    s.bar:SetPoint("BOTTOMRIGHT", s.fill, -1, 1)
    s.bar:SetHeight(2)
    s.bar:SetColorTexture(unpack(C.gold))
  end
  s.bar:SetShown(selected and true or false)
  tabs[tab] = selected and "on" or "off"
end

local function styleTab(tab)
  tabs[tab] = "off"
  paint(tab, C.bg, C.edge, 8, -3, -8, 6)
  local p = tab:GetParent()
  tabState(tab, p and p.selectedTab and tab.GetID and p.selectedTab == tab:GetID())
  tab:HookScript("OnEnter", function() if tabs[tab] ~= "on" then setEdge(tab, C.gold) end end)
  tab:HookScript("OnLeave", function() if tabs[tab] ~= "on" then setEdge(tab, C.edge) end end)
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
    paint(track, C.input, C.input)
  end
  if thumb then
    for _, r in ipairs({ thumb:GetRegions() }) do if isTex(r) then kill(r) end end
    paint(thumb, C.thumb, C.thumb, 2, 0, -2, 0)
    thumb:HookScript("OnEnter", function() paint(thumb, C.cross, C.cross) end)
    thumb:HookScript("OnLeave", function() paint(thumb, C.thumb, C.thumb) end)
  end
end

local function styleCategory(b)
  kill(b.NormalTexture)
  kill(b.Lines)
  recolor(b.HighlightTexture, C.hover)
  recolor(b.SelectedTexture, C.select)
end

local function styleRow(row)
  recolor(row.HighlightTexture, C.hover)
  local sel = row.SelectedHighlight
  recolor(sel, C.select)
  if isTex(sel) then
    local bar = row:CreateTexture(nil, "OVERLAY", nil, 7)
    bar:SetPoint("TOPLEFT", sel)
    bar:SetPoint("BOTTOMLEFT", sel)
    bar:SetWidth(2)
    bar:SetColorTexture(unpack(C.gold))
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
    t:SetColorTexture(unpack(C.cross))
    t:SetSize(14, 2)
    t:SetPoint("CENTER")
    t:SetRotation(math.rad(angle))
    lines[k] = t
  end
  b:HookScript("OnEnter", function() for _, t in ipairs(lines) do t:SetColorTexture(unpack(C.gold)) end end)
  b:HookScript("OnLeave", function() for _, t in ipairs(lines) do t:SetColorTexture(unpack(C.cross)) end end)
end

local function flatten(f)
  local bd = f:GetBackdrop()
  if not bd or bd.bgFile == FLAT then return end
  local hasEdge = bd.edgeFile ~= nil
  f:SetBackdrop({ bgFile = FLAT, edgeFile = hasEdge and FLAT or nil, edgeSize = 1 })
  f:SetBackdropColor(unpack(hasEdge and C.bg or C.input))
  if hasEdge then f:SetBackdropBorderColor(unpack(C.edge)) end
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
  local ok = ScrollUtil and ScrollUtil.AddAcquiredFrameCallback
    and pcall(ScrollUtil.AddAcquiredFrameCallback, sb, function(_, frame) walk(frame) end, sb, true)
  if not ok and sb.Update then
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
        recolor(r, C.stripe)
      elseif a and decorAtlas(a) then
        kill(r); killed = true
      else
        local okPath, p = pcall(r.GetTextureFilePath, r)
        if okPath and type(p) == "string" and decorFile(p) then kill(r); killed = true end
      end
    end
  end

  if f.GetBackdrop and f:GetBackdrop() then
    flatten(f)
    local name = f.GetName and f:GetName()
    if name == "EverlookAuctionsPanel" or name == "EverlookAuctionsSell" then shadow(f, 6) end
  end
  if not killed then return end
  if f:IsObjectType("EditBox") then
    paint(f, C.input, C.edge, -5, 0, 0, 0)
    hoverEdge(f, C.edge)
  elseif f:IsObjectType("Button") then
    if f.LeftActive or f.MiddleActive then styleTab(f) else styleButton(f) end
  elseif f == _G.AuctionHouseFrame then
    local s = paint(f, C.bg, C.edge)
    shadow(f, 8)
    local band = f:CreateTexture(nil, "BACKGROUND", nil, -7)
    band:SetPoint("TOPLEFT", 1, -1)
    band:SetPoint("TOPRIGHT", -1, -1)
    band:SetHeight(22)
    shade(band, C.panel, 0.05)
    local line = f:CreateTexture(nil, "BORDER", nil, -6)
    line:SetPoint("TOPLEFT", band, "BOTTOMLEFT")
    line:SetPoint("TOPRIGHT", band, "BOTTOMRIGHT")
    onePixel(line, true)
    line:SetColorTexture(C.gold[1], C.gold[2], C.gold[3], 0.45)
    s.shine:Hide()
  else
    paint(f, C.panel, C.edge)
  end
end

function walk(f)
  if type(f) ~= "table" or not f.GetChildren then return end
  if not styled[f] then
    styled[f] = true
    local ok, err = pcall(style, f)
    if not ok and ns.skinErrors then ns.skinErrors[#ns.skinErrors + 1] = err end
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
  -- our own panels are made a moment after the auction house opens
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
