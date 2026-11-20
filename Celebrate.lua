-- EverlookDB Auctions: a little celebration when one of your auctions sells. The game says "A buyer has been found for
-- your auction of X." (anywhere, not only at the auction house); a card at the top of the screen says Hurray! with
-- fireworks: the item's icon, what sold, and roughly for how much: the price you last posted it at with Quick sell (that many at
-- that price each, before the auction house's cut). Several sales close together share one card.
--   db.cheer = false turns it off (Options, General; /eah cheer off).
local _, ns = ...
local C = {}
ns.cheer = C

local SHOW_FOR = 5        -- seconds on screen, then it fades
local SPARKS = 18         -- sparks per burst
local COLORS = {
  { 1, 0.82, 0.2 }, { 0.4, 0.75, 1 }, { 1, 0.45, 0.75 }, { 0.45, 1, 0.55 }, { 1, 1, 1 },
}

local function enabled()
  local d = ns.db and ns.db()
  return d and d.cheer ~= false
end

-- "A buyer has been found for your auction of %s." as a pattern that captures the item name
local function soldPattern()
  local f = ERR_AUCTION_SOLD_S or "A buyer has been found for your auction of %s."
  f = f:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1"):gsub("%%%%s", "(.+)")
  return "^" .. f .. "$"
end

-- What the sale likely brought: the last Quick sell post of this item (price each times how many were posted).
function C.guess(name)
  local s = ns.sellSettings and ns.sellSettings()
  local okId, id = pcall(C_Item.GetItemInfoInstant, name)
  if not (s and s.memory and okId and type(id) == "number") then return nil end
  local m = s.memory[id .. ":0"]
  if not m then
    for key, v in pairs(s.memory) do
      if key:match("^(%d+):") == tostring(id) then m = v; break end
    end
  end
  if m and m.p then return m.p * math.max(1, m.q or 1), m.q end
end

---------------------------------------------------------------------------------------------------------------------
-- The banner and the fireworks

local CARD_W, CARD_H, ICON = 340, 76, 48

local function makeFrame()
  if C.frame then return C.frame end
  -- the card: dark slate, a gold line along the top, the item's icon, then Hurray!, what sold and the money
  local EUI = LibStub and LibStub("EverlookUI-1", true)
  local f = CreateFrame("Frame", "EverlookAuctionsCheer", UIParent, (not EUI) and "BackdropTemplate" or nil)
  f:SetSize(CARD_W, CARD_H)
  f:SetPoint("TOP", 0, -90)
  f:SetFrameStrata("FULLSCREEN_DIALOG")
  f:EnableMouse(false)
  if EUI then
    -- the EverlookDB window look: a rounded slate card with a gold line along the top
    local T = EUI.MakeTheme(ns.T and ns.T.accent or { 1, 0.82, 0 })
    f.eluiTheme = T
    EUI.WindowChrome(f, T)
  elseif f.SetBackdrop then
    f:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
    f:SetBackdropColor(0.07, 0.09, 0.12, 0.96)
    f:SetBackdropBorderColor(0.22, 0.26, 0.32, 1)
    f.accent = f:CreateTexture(nil, "ARTWORK")
    f.accent:SetPoint("TOPLEFT", 1, -1)
    f.accent:SetPoint("TOPRIGHT", -1, -1)
    f.accent:SetHeight(2)
    f.accent:SetColorTexture(1, 0.82, 0, 1)
  end
  f.icon = f:CreateTexture(nil, "ARTWORK")
  f.icon:SetSize(ICON, ICON)
  f.icon:SetPoint("LEFT", 14, -1)
  f.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  f.iconBorder = f:CreateTexture(nil, "BACKGROUND", nil, 1)
  f.iconBorder:SetPoint("TOPLEFT", f.icon, -1, 1)
  f.iconBorder:SetPoint("BOTTOMRIGHT", f.icon, 1, -1)
  f.iconBorder:SetColorTexture(0.75, 0.62, 0.15, 0.9)
  f.big = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  f.big:SetPoint("TOPLEFT", f.icon, "TOPRIGHT", 12, 1)
  f.big:SetText("Hurray! Sold")
  f.big:SetTextColor(1, 0.82, 0)
  f.line = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  f.line:SetPoint("TOPLEFT", f.big, "BOTTOMLEFT", 0, -4)
  f.line:SetPoint("RIGHT", -12, 0)
  f.line:SetJustifyH("LEFT")
  f.line:SetWordWrap(false)
  f.money = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  f.money:SetPoint("TOPLEFT", f.line, "BOTTOMLEFT", 0, -4)
  f.money:SetPoint("RIGHT", -12, 0)
  f.money:SetJustifyH("LEFT")
  f.sparks = {}
  for i = 1, SPARKS * 3 do
    local t = f:CreateTexture(nil, "OVERLAY")
    t:SetTexture("Interface\\Cooldown\\star4")
    t:SetBlendMode("ADD")
    t:SetSize(18, 18)
    t:Hide()
    f.sparks[i] = t
  end
  f:SetScript("OnUpdate", function(self, el)
    self.age = (self.age or 0) + el
    local a = self.age
    -- sparks: three bursts around the card, a moment apart, each flying out and fading
    for _, sp in ipairs(self.sparks) do
      local t = a - sp.delay
      if t > 0 and t < 1.4 then
        local d = sp.speed * (1 - (1 - t / 1.4) ^ 2)
        sp:ClearAllPoints()
        sp:SetPoint("CENTER", self, "CENTER", sp.x + math.cos(sp.angle) * d, sp.y + math.sin(sp.angle) * d - 30 * t * t)
        sp:SetAlpha(1 - t / 1.4)
        sp:Show()
      else
        sp:Hide()
      end
    end
    -- the card slides down a little as it fades in, and fades out at the end
    local alpha = a < 0.25 and a / 0.25 or (a > SHOW_FOR and math.max(0, 1 - (a - SHOW_FOR) / 1) or 1)
    self:SetAlpha(alpha)
    self:ClearAllPoints()
    self:SetPoint("TOP", 0, -90 + (a < 0.25 and (1 - a / 0.25) * 16 or 0))
    if a > SHOW_FOR + 1 then self:Hide() end
  end)
  f:Hide()
  C.frame = f
  return f
end

local function burst(f, from, delay)
  local cx, cy = ({ -CARD_W / 2, 0, CARD_W / 2 })[from], ({ 10, CARD_H / 2 + 6, 10 })[from]
  local c = COLORS[math.random(#COLORS)]
  for i = 1, SPARKS do
    local sp = f.sparks[(from - 1) * SPARKS + i]
    sp.delay = delay
    sp.angle = (i / SPARKS) * math.pi * 2 + math.random() * 0.3
    sp.speed = 50 + math.random() * 45
    sp.x, sp.y = cx, cy
    sp:SetVertexColor(c[1], c[2], c[3])
  end
end

local function iconAndColor(name)
  local okId, id, _, _, _, icon = pcall(C_Item.GetItemInfoInstant, name)
  if not (okId and id) then return 133784, 1, 1, 1 end
  local q = C_Item.GetItemQualityByID and select(2, pcall(C_Item.GetItemQualityByID, id))
  local c = type(q) == "number" and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q]
  return icon or (C_Item.GetItemIconByID and select(2, pcall(C_Item.GetItemIconByID, id))) or 134400,
    c and c.r or 1, c and c.g or 1, c and c.b or 1
end

function C.show(name, total, count)
  if not enabled() then return end
  local f = makeFrame()
  local now = GetTime()
  -- another sale while the card is up: one card for all of them
  if f:IsShown() and C.since and now - C.since < SHOW_FOR then
    C.n = C.n + 1
    C.total = C.total and total and (C.total + total) or nil
    f.big:SetText("Hurray! Sold")
    f.line:SetText(("%d auctions"):format(C.n))
    f.line:SetTextColor(1, 1, 1)
    f.icon:SetTexture(133784)   -- coins
    f.money:SetText(C.total and ("for about " .. ns.money(C.total)) or "")
    f.age = 0.3
  else
    C.n, C.total = 1, total
    local icon, r, g, b = iconAndColor(name)
    f.icon:SetTexture(icon)
    f.line:SetText((count and count > 1) and (count .. "x " .. name) or name)
    f.line:SetTextColor(r, g, b)
    f.money:SetText(total and ("for about " .. ns.money(total)) or "")
    f.age = 0
  end
  C.since = now
  for k = 1, 3 do burst(f, k, (k - 1) * 0.35) end
  f:Show()
  if SOUNDKIT and PlaySound then
    pcall(PlaySound, SOUNDKIT.UI_EPICLOOT_TOAST or SOUNDKIT.LOOT_WINDOW_COIN_SOUND or 120)
  end
end

-- One sale can reach us more than one way (the auction house's notification, the system chat line, the line drawn in
-- a chat window): the same item within a moment counts once.
local lastName, lastAt = nil, 0
local function sold(name)
  if type(name) ~= "string" or name == "" or (issecretvalue and issecretvalue(name)) then return end
  name = name:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|H.-|h%[?(.-)%]?|h", "%1")
  local now = GetTime()
  if name == lastName and now - lastAt < 0.5 then return end
  lastName, lastAt = name, now
  local total, count = C.guess(name)
  C.show(name, total, count)
end
C.sold = sold

local function fromText(msg)
  if type(msg) ~= "string" or (issecretvalue and issecretvalue(msg)) then return end
  C.pattern = C.pattern or soldPattern()
  local name = msg:match(C.pattern)
  if name then sold(name) end
end
C.fromText = fromText

-- The ways a sale is told (the retail-style auction house sends a notification, which the game itself writes to chat;
-- a plain system message on other clients), and, as a last resort, the line as a chat window draws it.
local SOLD = Enum and Enum.AuctionHouseNotification and Enum.AuctionHouseNotification.AuctionSold or 4
local ev = CreateFrame("Frame")
for _, e in ipairs({ "CHAT_MSG_SYSTEM", "AUCTION_HOUSE_SHOW_FORMATTED_NOTIFICATION", "AUCTION_HOUSE_SHOW_NOTIFICATION",
    "PLAYER_LOGIN" }) do
  pcall(ev.RegisterEvent, ev, e)
end
ev:SetScript("OnEvent", function(_, e, a1, a2)
  if e == "CHAT_MSG_SYSTEM" then
    fromText(a1)
  elseif e == "AUCTION_HOUSE_SHOW_FORMATTED_NOTIFICATION" then
    if a1 == SOLD then sold(a2) end
  elseif e == "AUCTION_HOUSE_SHOW_NOTIFICATION" then
    -- no item name with this one: say so without one
    if a1 == SOLD then sold("An auction") end
  elseif e == "PLAYER_LOGIN" then
    for i = 1, (NUM_CHAT_WINDOWS or 10) do
      local cf = _G["ChatFrame" .. i]
      if cf and cf.AddMessage then pcall(hooksecurefunc, cf, "AddMessage", function(_, msg) fromText(msg) end) end
    end
  end
end)
