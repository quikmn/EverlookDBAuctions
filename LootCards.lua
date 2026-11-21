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
-- Where the newest card goes: db.lootPos = { x, y } (its top right corner, from the screen's top right), else the right
-- side under the buffs, left of the minimap. /eah lootmove to drag it.

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
      if p then itemPatterns[#itemPatterns + 1] = { p, f[1]:find("PUSHED") ~= nil } end
    end
  end
  for _, p in ipairs(itemPatterns) do
    local link, n = msg:match(p[1])
    if link then return link, tonumber(n) or 1, p[2] end
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
  if it and it[1] and it[1] > 0 then return it[1], it.shared and "shared" or "ah" end
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

local function anchorXY()
  local d = db()
  local p = d and d.lootPos
  if p and tonumber(p[1]) and tonumber(p[2]) then return p[1], p[2] end
  return -math.floor(UIParent:GetWidth() * 0.17), -math.floor(UIParent:GetHeight() * 0.19)
end

local function layout()
  local x, y = anchorXY()
  for i, c in ipairs(cards) do
    c:ClearAllPoints()
    c:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", x, y - (i - 1) * (H + GAP))
  end
end

-- /eah lootmove: a card-sized handle to drag; the cards follow, the spot is saved
local mover
function L.move()
  if not mover then
    mover = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    mover:SetSize(W, H)
    mover:SetFrameStrata("DIALOG")
    mover:SetMovable(true)
    mover:EnableMouse(true)
    mover:RegisterForDrag("LeftButton")
    mover:SetClampedToScreen(true)
    if mover.SetBackdrop then
      mover:SetBackdrop({ bgFile = "Interface\Buttons\WHITE8x8", edgeFile = "Interface\Buttons\WHITE8x8", edgeSize = 1 })
      mover:SetBackdropColor(0.2, 0.6, 0.3, 0.35)
      mover:SetBackdropBorderColor(0.3, 0.9, 0.4, 1)
    end
    local t = mover:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    t:SetPoint("CENTER")
    t:SetText("Loot cards: drag me, right-click when done")
    mover:SetScript("OnDragStart", mover.StartMoving)
    mover:SetScript("OnDragStop", function(self)
      self:StopMovingOrSizing()
      local d = db()
      if d and self:GetRight() then
        d.lootPos = { math.floor(self:GetRight() - UIParent:GetRight() + 0.5), math.floor(self:GetTop() - UIParent:GetTop() + 0.5) }
      end
      self:ClearAllPoints()
      local x, y = anchorXY()
      self:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", x, y)
      layout()
    end)
    mover:SetScript("OnMouseUp", function(self, button) if button == "RightButton" then self:Hide() end end)
  end
  if mover:IsShown() then mover:Hide(); return end
  local x, y = anchorXY()
  mover:ClearAllPoints()
  mover:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", x, y)
  mover:Show()
end

function L.resetPos()
  local d = db()
  if d then d.lootPos = nil end
  layout()
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
      .. (src == "vendor" and "  at a vendor" or src == "shared" and "  at the AH (other players' scan)" or "  at the auction house"))
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
---------------------------------------------------------------------------------------------------------------------
-- Where loot came from. When the loot window opens, each slot says which corpse, node or container it is from (a
-- GUID); the name comes from the mobs you targeted, moused over or saw a nameplate of, the node you gathered
-- (the spell's target name), or the container you opened from your bags. The loot lines in chat come after that, so
-- each item (and the money) is matched to its source by item id. Unknown stays unknown: no guessing.

local names = {}       -- [guid] = name, for mobs you saw (kept small)
local nameCount = 0
local sent             -- the last gathering/opening spell: { target = name, spell = name, t }
local opened           -- the last item you opened from your bags: { name, t }
local fromItem = {}    -- [itemID] = { from, how, npc, t } while the loot window is up and just after
local fromMoney        -- { from, how, npc, t }

local function remember(guid, name)
  guid, name = okv(guid), okv(name)
  if type(guid) ~= "string" or type(name) ~= "string" or name == "" then return end
  if not names[guid] then
    nameCount = nameCount + 1
    if nameCount > 300 then names, nameCount = {}, 1 end
  end
  names[guid] = name
end

local function rememberUnit(unit)
  local okG, g = pcall(UnitGUID, unit)
  g = okG and okv(g)
  if type(g) ~= "string" or not g:match("^Creature") and not g:match("^Vehicle") then return end
  local okN, n = pcall(UnitName, unit)
  if okN then remember(g, n) end
end

local function unitName(guid)
  for _, u in ipairs({ "target", "mouseover", "focus", "softinteract", "softenemy" }) do
    local okG, g = pcall(UnitGUID, u)
    if okG and okv(g) == guid then
      local okN, n = pcall(UnitName, u)
      if okN and okv(n) then return n end
    end
  end
  for i = 1, 40 do
    local u = "nameplate" .. i
    local okG, g = pcall(UnitGUID, u)
    if okG and okv(g) == guid then
      local okN, n = pcall(UnitName, u)
      if okN and okv(n) then return n end
    end
  end
end

-- A loot slot's source: who or what, how (Mining, Fishing, ...) and the creature id when it is a mob.
local function sourceOf(slot)
  local okS, guid = pcall(GetLootSourceInfo, slot)
  guid = okS and okv(guid) or nil
  local now = GetTime()
  local recentSent = sent and now - sent.t < 15 and sent or nil
  if IsFishingLoot and select(2, pcall(IsFishingLoot)) == true then return "Fishing", "Fishing" end
  if type(guid) ~= "string" then return nil end
  local kind, npc = guid:match("^(%a+)%-"), nil
  if kind == "Creature" or kind == "Vehicle" then
    npc = tonumber(guid:match("^%a+%-%d+%-%d+%-%d+%-%d+%-(%d+)"))
    local name = names[guid] or unitName(guid)
    -- skinning, mining or herbing a corpse: the spell says how
    local how = recentSent and recentSent.target == name and recentSent.spell or nil
    return name, how, npc
  elseif kind == "GameObject" then
    if recentSent and recentSent.target and recentSent.target ~= "" then return recentSent.target, recentSent.spell end
    return nil, recentSent and recentSent.spell or nil
  elseif kind == "Item" then
    if opened and now - opened.t < 15 then return opened.name, "Opened" end
  end
end

local function readLootWindow()
  local now = GetTime()
  fromItem, fromMoney = {}, nil
  local okN, n = pcall(GetNumLootItems)
  for slot = 1, (okN and n or 0) do
    local from, how, npc = sourceOf(slot)
    if from or how then
      local src = { from = from, how = how, npc = npc, t = now }
      local okT, kind = pcall(GetLootSlotType, slot)
      local MONEY = (Enum and Enum.LootSlotType and Enum.LootSlotType.Money) or LOOT_SLOT_MONEY or 2
      if okT and kind == MONEY then
        fromMoney = fromMoney or src
      else
        local okL, link = pcall(GetLootSlotLink, slot)
        local id = okL and type(okv(link)) == "string" and tonumber(link:match("|Hitem:(%d+)"))
        if id and not fromItem[id] then fromItem[id] = src end
      end
    end
  end
end

-- the source of this loot, while the loot window's answer is fresh
local function sourceFor(e)
  local now = GetTime()
  local src = e.copper and fromMoney or (e.id and fromItem[e.id])
  if src and now - src.t < 60 then return src end
end
L.sourceFor = sourceFor

local src = CreateFrame("Frame")
for _, e in ipairs({ "LOOT_READY", "LOOT_OPENED", "UNIT_SPELLCAST_SENT",
    "PLAYER_TARGET_CHANGED", "UPDATE_MOUSEOVER_UNIT", "NAME_PLATE_UNIT_ADDED", "PLAYER_SOFT_INTERACT_CHANGED", "UNIT_TARGET" }) do
  pcall(src.RegisterEvent, src, e)
end
src:SetScript("OnEvent", function(_, event, ...)
  if event == "PLAYER_TARGET_CHANGED" then rememberUnit("target"); return end
  if event == "UPDATE_MOUSEOVER_UNIT" then rememberUnit("mouseover"); return end
  if event == "PLAYER_SOFT_INTERACT_CHANGED" then rememberUnit("softinteract"); return end
  if event == "NAME_PLATE_UNIT_ADDED" then local u = ...; if type(u) == "string" then rememberUnit(u) end; return end
  if event == "UNIT_TARGET" then
    -- what your party is fighting
    local u = ...
    if type(u) == "string" and (u == "player" or u:match("^party%d$") or u == "pet") then rememberUnit(u .. "target") end
    return
  end
  -- no combat log: this client doesn't let addons register for it (ADDON_ACTION_FORBIDDEN)
  if event == "UNIT_SPELLCAST_SENT" then
    local unit, target, _, spellID = ...
    if okv(unit) ~= "player" then return end
    local okS, info = pcall(C_Spell.GetSpellInfo, okv(spellID))
    sent = { target = okv(target), spell = okS and info and okv(info.name) or nil, t = GetTime() }
  elseif event == "LOOT_READY" or event == "LOOT_OPENED" then
    readLootWindow()
  end
end)

-- opening a container from your bags (a clam, a lockbox, a satchel)
if C_Container and C_Container.UseContainerItem then
  hooksecurefunc(C_Container, "UseContainerItem", function(bag, slot)
    local ok, info = pcall(C_Container.GetContainerItemInfo, bag, slot)
    local name = ok and info and okv(info.hyperlink)
    name = type(name) == "string" and name:match("%[(.-)%]") or nil
    if name then opened = { name = name, t = GetTime() } end
  end)
end

---------------------------------------------------------------------------------------------------------------------
-- Items that arrive without being looted: taken from the mail (an expired, cancelled or won auction, a letter), bought
-- from a merchant or traded. The game says "You receive item" for those too; they go in the log with where they came
-- from, marked as not loot (no card, not in today's loot).

local mailTaken        -- { from, how, t }: the mail you just took an item from
local atMerchant       -- the merchant's name while its window is open
local tradingWith      -- true while a trade window is open (the other player's name is never kept)

local function subjectIs(subject, global, fallback)
  local pat = pattern(_G[global] or fallback)
  return type(subject) == "string" and pat and subject:match(pat) ~= nil
end

local function noteMail(index)
  -- the sender's name is never read: the log saves no player names
  local ok, _, _, _, subject = pcall(GetInboxHeaderInfo, index)
  if not ok then return end
  subject = okv(subject)
  local from
  if subjectIs(subject, "AUCTION_EXPIRED_MAIL_SUBJECT", "Auction expired: %s") then from = "Expired auction"
  elseif subjectIs(subject, "AUCTION_REMOVED_MAIL_SUBJECT", "Auction cancelled: %s") then from = "Cancelled auction"
  elseif subjectIs(subject, "AUCTION_WON_MAIL_SUBJECT", "Auction won: %s") then from = "Won auction"
  else from = "Mail" end
  mailTaken = { from = from, how = "Mailbox", t = GetTime() }
end
for _, fn in ipairs({ "TakeInboxItem", "AutoLootMailItem" }) do
  if type(_G[fn]) == "function" then hooksecurefunc(fn, function(index) noteMail(index) end) end
end

local where = CreateFrame("Frame")
for _, e in ipairs({ "MERCHANT_SHOW", "MERCHANT_CLOSED", "TRADE_SHOW", "TRADE_CLOSED" }) do pcall(where.RegisterEvent, where, e) end
where:SetScript("OnEvent", function(_, event)
  if event == "MERCHANT_SHOW" then
    local ok, n = pcall(UnitName, "npc")
    atMerchant = ok and okv(n) or "a merchant"
  elseif event == "MERCHANT_CLOSED" then atMerchant = nil
  elseif event == "TRADE_SHOW" then
    tradingWith = true
  elseif event == "TRADE_CLOSED" then
    -- the trade's items arrive just after the window closes
    local who = tradingWith
    if C_Timer and C_Timer.After then C_Timer.After(3, function() if tradingWith == who then tradingWith = nil end end) else tradingWith = nil end
  end
end)
local function mailOpen() return MailFrame and MailFrame.IsShown and MailFrame:IsShown() end

-- Where a "You receive item" line came from when it wasn't loot: { from, how, got } or nil
local function notLoot(pushed)
  if not pushed then return nil end
  if mailTaken and GetTime() - mailTaken.t < 10 then return { from = mailTaken.from, how = mailTaken.how, got = "mail" } end
  if mailOpen() then return { from = "Mail", how = "Mailbox", got = "mail" } end
  if atMerchant then return { from = atMerchant, how = "Bought", got = "bought" } end
  if tradingWith then return { from = "Trade with a player", how = "Trade", got = "trade" } end
end
L.notLoot = notLoot
L.noteMail = noteMail

local function log(e, link)
  if not (ns.purchases and ns.purchases.noteLoot) then return end
  local s = e.got and e or sourceFor(e)
  if s then e.from, e.how, e.npc = s.from, s.how, s.npc end
  -- a failure here shows as a Lua error (the card still shows), never silently
  local ok, err = pcall(ns.purchases.noteLoot, e, link)
  if not ok and geterrorhandler then geterrorhandler()(err) end
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
  local link, n, pushed = parseItem(msg)
  if not link then return end
  local e = itemFrom(link, n)
  local other = notLoot(pushed)
  if other then e.from, e.how, e.got = other.from, other.how, other.got end
  log(e, link)
  if e.got then return end   -- not loot: no card
  if e.quality and d and d.lootMin and e.quality < d.lootMin then return end
  if enabled() then L.show(e) end
end)
