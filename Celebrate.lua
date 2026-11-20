-- EverlookDB Auctions: a little celebration when one of your auctions sells. The game says "A buyer has been found for
-- your auction of X." (anywhere, not only at the auction house); a banner at the top of the screen says Hurray! with
-- fireworks and what sold, and roughly for how much: the price you last posted it at with Quick sell (that many at
-- that price each, before the auction house's cut). Several sales close together share one banner.
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

local function makeFrame()
  if C.frame then return C.frame end
  local f = CreateFrame("Frame", "EverlookAuctionsCheer", UIParent)
  f:SetSize(600, 120)
  f:SetPoint("TOP", 0, -90)
  f:SetFrameStrata("FULLSCREEN_DIALOG")
  f:EnableMouse(false)
  f.big = f:CreateFontString(nil, "OVERLAY", _G.GameFontNormalHuge3 and "GameFontNormalHuge3" or "GameFontNormalHuge")
  f.big:SetPoint("TOP", 0, -10)
  f.big:SetText("Hurray!")
  f.big:SetTextColor(1, 0.82, 0)
  f.line = f:CreateFontString(nil, "OVERLAY", _G.GameFontHighlightLarge and "GameFontHighlightLarge" or "GameFontHighlight")
  f.line:SetPoint("TOP", f.big, "BOTTOM", 0, -8)
  f.line:SetWidth(580)
  f.line:SetWordWrap(true)
  f.sparks = {}
  for i = 1, SPARKS * 3 do
    local t = f:CreateTexture(nil, "ARTWORK")
    t:SetTexture("Interface\\Cooldown\\star4")
    t:SetBlendMode("ADD")
    t:SetSize(18, 18)
    t:Hide()
    f.sparks[i] = t
  end
  f:SetScript("OnUpdate", function(self, el)
    self.age = (self.age or 0) + el
    local a = self.age
    -- sparks: three bursts, a moment apart, each flying out from its own point and fading
    for _, sp in ipairs(self.sparks) do
      local t = a - sp.delay
      if t > 0 and t < 1.4 then
        local d = sp.speed * (1 - (1 - t / 1.4) ^ 2)
        sp:ClearAllPoints()
        sp:SetPoint("CENTER", self, "TOP", sp.x + math.cos(sp.angle) * d, -50 + sp.y + math.sin(sp.angle) * d - 30 * t * t)
        sp:SetAlpha(1 - t / 1.4)
        sp:Show()
      else
        sp:Hide()
      end
    end
    local alpha = a < 0.25 and a / 0.25 or (a > SHOW_FOR and math.max(0, 1 - (a - SHOW_FOR) / 1) or 1)
    self.big:SetAlpha(alpha)
    self.line:SetAlpha(alpha)
    self.big:SetScale(a < 0.3 and (0.6 + a / 0.3 * 0.4) or 1)
    if a > SHOW_FOR + 1 then self:Hide() end
  end)
  f:Hide()
  C.frame = f
  return f
end

local function burst(f, from, delay)
  local cx, cy = ({ -180, 0, 180 })[from], ({ 0, 25, 0 })[from]
  local c = COLORS[math.random(#COLORS)]
  for i = 1, SPARKS do
    local sp = f.sparks[(from - 1) * SPARKS + i]
    sp.delay = delay
    sp.angle = (i / SPARKS) * math.pi * 2 + math.random() * 0.3
    sp.speed = 60 + math.random() * 50
    sp.x, sp.y = cx, cy
    sp:SetVertexColor(c[1], c[2], c[3])
  end
end

function C.show(name, total, count)
  if not enabled() then return end
  local f = makeFrame()
  local now = GetTime()
  -- another sale while the banner is up: one banner for all of them
  if f:IsShown() and C.since and now - C.since < SHOW_FOR then
    C.n = C.n + 1
    C.total = C.total and total and (C.total + total) or nil
    f.line:SetText(("%d auctions sold%s"):format(C.n, C.total and (" for about " .. ns.money(C.total)) or ""))
    f.age = 0.3
  else
    C.n, C.total = 1, total
    local what = (count and count > 1) and (count .. "x " .. name) or name
    f.line:SetText(total and ("%s sold for about %s"):format(what, ns.money(total)) or (what .. " sold!"))
    f.age = 0
  end
  C.since = now
  for k = 1, 3 do burst(f, k, (k - 1) * 0.35) end
  f:Show()
  if SOUNDKIT and PlaySound then
    pcall(PlaySound, SOUNDKIT.UI_EPICLOOT_TOAST or SOUNDKIT.LOOT_WINDOW_COIN_SOUND or 120)
  end
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("CHAT_MSG_SYSTEM")
ev:SetScript("OnEvent", function(_, _, msg)
  if type(msg) ~= "string" or (issecretvalue and issecretvalue(msg)) then return end
  C.pattern = C.pattern or soldPattern()
  local name = msg:match(C.pattern)
  if not name then return end
  local total, count = C.guess(name)
  C.show(name, total, count)
end)
