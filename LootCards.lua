-- EverlookDB Auctions: a card at the top of the screen for everything you loot, so it is easy to see. It shows the item's
-- icon, its name in its quality colour, how many, and roughly what it is worth (the auction price from the last scan,
-- else what a vendor pays). Money gets a card too. Each card stays 5 seconds, then fades; several stack under each
-- other (the newest on top), and looting more of the same item while its card is up adds to it.
--   db.lootCards = false turns them off; db.lootMin = the lowest quality that gets a card (0 Poor .. 4 Epic).
local _, ns = ...
local L = {}
ns.lootCards = L

local SHOW_FOR = 5      -- seconds on screen, then a fade of FADE
local FADE = 0.6
local MAX = 5           -- cards at once; the oldest goes first
local W, H, ICON, GAP = 300, 46, 34, 6
local TOP = -180        -- under the sale card (Celebrate.lua, at -90)

local function db() return ns.db and ns.db() end
local function enabled()
  local d = db()
  return d and d.lootCards ~= false
end
local function okv(v)
  if v == nil or (issecretvalue and issecretvalue(v)) then return nil end
  return v
end

-- "You receive loot: %s." as a pattern that captures what %s and %d stand for
local function pattern(f)
  if type(f) ~= "string" then return nil end
  f = f:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
  f = f:gsub("%%%%s", "(.+)"):gsub("%%%%d", "(%%d+)")
  return "^" .. f .. "$"
end

-- Your own loot only: what you looted, and items given to you (a quest reward). The more specific ("x%d") first.
local ITEM_FORMATS = {
  { "LOOT_ITEM_SELF_MULTIPLE", "You receive loot: %sx%d." },
  { "LOOT_ITEM_PUSHED_SELF_MULTIPLE", "You receive item: %sx%d." },
  { "LOOT_ITEM_SELF", "You receive loot: %s." },
  { "LOOT_ITEM_PUSHED_SELF", "You receive item: %s." },
}
local itemPatterns
local function parseItem(msg)
  if not itemPatterns then
    itemPatterns = {}
    for _, f in ipairs(ITEM_FORMATS) do
      local p = pattern(_G[f[1]] or f[2])
      if p then itemPatterns[#itemPatterns + 1] = p end
    end
  end
  for _, p in ipairs(itemPatterns) do
    local link, n = msg:match(p)
    if link then return link, tonumber(n) or 1 end
  end
end
L.parseItem = parseItem

-- "You loot 1 Gold, 5 Silver, 3 Copper" (and "Your share of the loot is ..."): the copper in it
local function parseMoney(msg)
  local c = 0
  for _, unit in ipairs({ { "GOLD_AMOUNT", "%d Gold", 10000 }, { "SILVER_AMOUNT", "%d Silver", 100 }, { "COPPER_AMOUNT", "%d Copper", 1 } }) do
    local f = (_G[unit[1]] or unit[2]):gsub("%%d", "(%%d+)")
    local n = msg:match(f)
    if n then c = c + tonumber(n) * unit[3] end
  end
  return c > 0 and c or nil
end
L.parseMoney = parseMoney


-- Roughly what one is worth: the lowest auction from the last scan, else the vendor price.
function L.worth(id)
  local it = ns.itemFor and ns.itemFor(id)
  if it and it[1] and it[1] > 0 then return it[1], "ah" end
  local ok, _, _, _, _, _, _, _, _, _, _, sell = pcall(C_Item.GetItemInfo, id)
  if ok and type(sell) == "number" and sell > 0 then return sell, "vendor" end
end

---------------------------------------------------------------------------------------------------------------------
-- The cards

local cards = {}   -- shown, newest first
local pool = {}

local function makeCard()
  local EUI = LibStub and LibStub("EverlookUI-1", true)
  local f = CreateFrame("Frame", nil, UIParent, (not EUI) and "BackdropTemplate" or nil)
  f:SetSize(W, H)
  f:SetFrameStrata("FULLSCREEN_DIALOG")
  f:EnableMouse(false)
  if EUI then
    local T = EUI.MakeTheme(ns.T and ns.T.accent or { 1, 0.82, 0 })
    f.eluiTheme = T
    EUI.WindowChrome(f, T)
  elseif f.SetBackdrop then
    f:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
    f:SetBackdropColor(0.07, 0.09, 0.12, 0.96)
    f:SetBackdropBorderColor(0.22, 0.26, 0.32, 1)
  end
  f.icon = f:CreateTexture(nil, "ARTWORK")
  f.icon:SetSize(ICON, ICON)
  f.icon:SetPoint("LEFT", 8, 0)
  f.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  f.iconBorder = f:CreateTexture(nil, "BACKGROUND", nil, 1)
  f.iconBorder:SetPoint("TOPLEFT", f.icon, -1, 1)
  f.iconBorder:SetPoint("BOTTOMRIGHT", f.icon, 1, -1)
  f.name = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  f.name:SetPoint("TOPLEFT", f.icon, "TOPRIGHT", 10, -1)
  f.name:SetPoint("RIGHT", -10, 0)
  f.name:SetJustifyH("LEFT")
  f.name:SetWordWrap(false)
  f.sub = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  f.sub:SetPoint("BOTTOMLEFT", f.icon, "BOTTOMRIGHT", 10, 1)
  f.sub:SetPoint("RIGHT", -10, 0)
  f.sub:SetJustifyH("LEFT")
  f.sub:SetTextColor(0.62, 0.66, 0.72)
  f:SetScript("OnUpdate", function(self, el)
    self.age = (self.age or 0) + el
    local a = self.age
    self:SetAlpha(a < 0.2 and a / 0.2 or (a > SHOW_FOR and math.max(0, 1 - (a - SHOW_FOR) / FADE) or 1))
    if a > SHOW_FOR + FADE then L.drop(self) end
  end)
  return f
end

local function layout()
  for i, c in ipairs(cards) do
    c:ClearAllPoints()
    c:SetPoint("TOP", UIParent, "TOP", 0, TOP - (i - 1) * (H + GAP))
  end
end

function L.drop(card)
  for i, c in ipairs(cards) do
    if c == card then table.remove(cards, i); break end
  end
  card:Hide()
  card.key = nil
  pool[#pool + 1] = card
  layout()
end

local function money(c) return ns.money and ns.money(c) or (c .. "c") end

local function fill(card)
  local e = card.e
  if e.copper then
    card.icon:SetTexture(133784)   -- coins
    card.iconBorder:SetColorTexture(0.75, 0.62, 0.15, 0.9)
    card.name:SetText(money(e.copper))
    card.name:SetTextColor(1, 0.82, 0)
    card.sub:SetText("Money")
    card.name:ClearAllPoints()
    card.name:SetPoint("TOPLEFT", card.icon, "TOPRIGHT", 10, -1)
    card.name:SetPoint("RIGHT", -10, 0)
    return
  end
  card.icon:SetTexture(e.icon or 134400)
  local c = e.quality and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[e.quality]
  local r, g, b = c and c.r or 1, c and c.g or 1, c and c.b or 1
  card.iconBorder:SetColorTexture(r, g, b, 0.9)
  card.name:SetText((e.count > 1 and (e.count .. "x ") or "") .. (e.name or "?"))
  card.name:SetTextColor(r, g, b)
  local each, src = L.worth(e.id)
  -- the name in the middle when there is no price under it
  card.name:ClearAllPoints()
  if each then card.name:SetPoint("TOPLEFT", card.icon, "TOPRIGHT", 10, -1) else card.name:SetPoint("LEFT", card.icon, "RIGHT", 10, 0) end
  card.name:SetPoint("RIGHT", -10, 0)
  if each then
    local total = each * e.count
    card.sub:SetText((e.count > 1 and ("%s (%s each)"):format(money(total), money(each)) or money(total))
      .. (src == "vendor" and "  at a vendor" or "  at the auction house"))
  else
    card.sub:SetText("")
  end
end

-- Shows a card for this loot, or adds to the card of the same thing still up.
function L.show(e)
  if not enabled() then return end
  local key = e.copper and "money" or ("item:" .. tostring(e.id or e.name))
  for _, c in ipairs(cards) do
    if c.key == key and (c.age or 0) < SHOW_FOR then
      if e.copper then c.e.copper = c.e.copper + e.copper else c.e.count = c.e.count + e.count end
      c.age = math.min(c.age or 0, 0.2)   -- stays another full 5 seconds
      fill(c)
      return c
    end
  end
  local card = table.remove(pool) or makeCard()
  card.key, card.e, card.age = key, e, 0
  fill(card)
  table.insert(cards, 1, card)
  while #cards > MAX do L.drop(cards[#cards]) end
  card:SetAlpha(0)
  card:Show()
  layout()
  return card
end

-- An item from a loot line: its id, name, quality and icon from the link (names of items the game hasn't loaded yet
-- come from the link text).
local function itemFrom(link, count)
  local id = tonumber(link:match("|Hitem:(%d+)"))
  local name = link:match("|h%[(.-)%]|h") or link
  local ok, _, _, _, _, icon = pcall(C_Item.GetItemInfoInstant, id or name)
  local q = id and C_Item.GetItemQualityByID and select(2, pcall(C_Item.GetItemQualityByID, id))
  if type(q) ~= "number" then
    -- the colour code in the link says the quality too
    local hex = link:match("|c(%x%x%x%x%x%x%x%x)")
    for i = 0, 7 do
      local c = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[i]
      if hex and c and c.hex and c.hex:lower():find(hex:lower(), 1, true) then q = i; break end
    end
  end
  return { id = id, name = name, count = count or 1, quality = type(q) == "number" and q or nil, icon = ok and icon or nil }
end
L.itemFrom = itemFrom

local ev = CreateFrame("Frame")
pcall(ev.RegisterEvent, ev, "CHAT_MSG_LOOT")
pcall(ev.RegisterEvent, ev, "CHAT_MSG_MONEY")
local function log(e, link)
  if ns.purchases and ns.purchases.noteLoot then pcall(ns.purchases.noteLoot, e, link) end
end
ev:SetScript("OnEvent", function(_, event, msg)
  msg = okv(msg)
  if type(msg) ~= "string" then return end
  local d = db()
  if event == "CHAT_MSG_MONEY" then
    local c = parseMoney(msg)
    if not c then return end
    log({ copper = c })
    if enabled() and not (d and d.lootMoney == false) then L.show({ copper = c }) end
    return
  end
  local link, n = parseItem(msg)
  if not link then return end
  local e = itemFrom(link, n)
  log(e, link)
  if e.quality and d and d.lootMin and e.quality < d.lootMin then return end
  if enabled() then L.show(e) end
end)
