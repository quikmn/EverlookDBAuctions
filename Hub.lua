-- EverlookDB Auctions: the main window. One window holds everything the addon does: a Home page with one card per
-- area, the addon's own pages (Advanced search over the last scan and the Price Feed, the AH log, Crafting profit,
-- Gear upgrades, Merchant's Favor) and, under a Settings heading, every settings page. It is the EverlookUI window
-- /eah opens (Options.lua makes it); this file adds the pages and the ways in:
--   /eah (bare), the minimap button (MinimapButton.lua), Everlook Bar's launcher, a key binding (Bindings.xml) and
--   the "Open in EverlookDB Auctions" link on the auction house's price bar all open this one window.
-- The pages are the addon's existing views, moved in: the AH log (Purchases.lua), Crafting profit (ProfitWindow.lua),
-- Advanced search (Search.lua) and Gear upgrades (UpgradesTab.lua) draw into the page instead of a window of their
-- own. The auction house keeps its own tabs (Quick sell, Shopping, Upgrades, Advanced search).
-- It opens on the page used last, but never on Gear upgrades by itself (that page reads the whole scan).
-- Nothing here opens by itself, takes focus or closes another window; the window moves and Escape closes it.
local ADDON, ns = ...
local EUI = LibStub and LibStub("EverlookUI-1", true)
local U = EUI and EUI.Util

local H = {}
ns.hub = H

-- The addon's own pages, in sidebar order; the settings pages follow under "Settings".
H.PAGES = {
  { id = "home", title = "Home", icon = "home" },
  { id = "search", title = "Advanced search", icon = "search" },
  { id = "log", title = "AH log", icon = "coins" },
  { id = "crafts", title = "Crafting profit", icon = "hammer" },
  { id = "gear", title = "Gear upgrades", icon = "sword" },
  { id = "favor", title = "Merchant's Favor", icon = "star" },
}
H.FAVOR_CURRENCY = 3402   -- Merchant's Favor (WoW Forever)

local function rgba(c) return c[1], c[2], c[3], c[4] or 1 end
local function db() return ns.db and ns.db() end
local function money(c) return ns.money and ns.money(c) or tostring(c) end
local function try(fn, ...)
  if type(fn) ~= "function" then return nil end
  local okT, a, b, c, d = pcall(fn, ...)
  if okT then return a, b, c, d end
end

---------------------------------------------------------------------------------------------------------------------
-- Words and numbers (no frames: the tests run these offline)

-- The page to open when none is asked for: the one used last, except Gear upgrades (never by itself) and pages that
-- don't exist (any more).
function H.startPage(last, known)
  if type(last) ~= "string" or last == "gear" then return "home" end
  if known and not known[last] then return "home" end
  return last
end

-- Local midnight of the day `now` is in.
function H.dayStart(now)
  local t = date("*t", now)
  return time({ year = t.year, month = t.month, day = t.day, hour = 0, min = 0, sec = 0 })
end

-- Copper taken from the mail today and in the last 7 days (the AH log's Income), and the sales waiting in the mail.
function H.income(list, pending, now)
  now = now or time()
  -- the income ledger (Ledger.lua): real gains only, sales waiting from the auctions' records
  local LG = ns.ledger
  local s = LG and LG.get and LG.get()
  if s then return LG.hubNumbers(s, db() and db().bought, now) end
  local since, week = H.dayStart(now), now - 7 * 86400
  local today, sevenDays = 0, 0
  for _, e in ipairs(list or {}) do
    local t, c = tonumber(e.t) or 0, tonumber(e.c) or 0
    if t >= week then sevenDays = sevenDays + c end
    if t >= since then today = today + c end
  end
  local waiting, est = 0, 0
  for _, e in ipairs(pending or {}) do
    waiting = waiting + 1
    est = est + (tonumber(e.est) or 0)
  end
  return today, sevenDays, waiting, est
end

-- "12 min old", "3 h old", "2 days old"
function H.age(t, now)
  local d = math.max(0, (now or time()) - (t or 0))
  if d < 90 then return "just now" end
  if d < 5400 then return math.floor(d / 60 + 0.5) .. " min old" end
  if d < 129600 then return math.floor(d / 3600 + 0.5) .. " h old" end
  return math.floor(d / 86400 + 0.5) .. " days old"
end

-- Where the newest prices of this realm's (your faction's) auction house come from and how old they are:
-- "Alliance: 8,123 prices, 12 min old", "Price Feed: other players' scan, 5 min old", or why there are none.
function H.priceLines(now)
  local out = {}
  local key = ns.houseOrFaction and ns.houseOrFaction()
  local d = db()
  local h = key and d and d.houses and d.houses[key]
  local side = key and key:match("%-(%a+)$") or "This auction house"
  if h and h.scanned then
    local n = ns.countItems and ns.countItems(h) or 0
    out[#out + 1] = ("%s: %s prices, your scan %s"):format(side, ns.num and ns.num(n) or n, H.age(h.scanned, now))
  else
    out[#out + 1] = side .. ": no scan of your own yet (open the auction house once)"
  end
  local sh = ns.shared and key and ns.shared.house(key)
  if sh and ns.shared.localAt then
    out[#out + 1] = "Price Feed: other players' scan, " .. H.age(ns.shared.localAt(sh), now)
  elseif ns.shared and ns.shared.state then
    local st = ns.shared.state()
    out[#out + 1] = st == "none" and "Price Feed: off (the EverlookDB App brings it)" or "Price Feed: no scan of this house yet"
  end
  return out
end

-- The age of the newest prices, own or the Price Feed's: seconds, and whether they are the feed's.
function H.newestPrices(now)
  local at, shared = nil, false
  if ns.pricesAt then at, shared = ns.pricesAt() end
  if not at then return nil end
  return math.max(0, (now or time()) - at), shared
end

-- Bags: what sells for more at the auction house than at a vendor (not soulbound), and grey items for a vendor.
-- Returns { auction = n, auctionWorth = copper, junk = n, junkWorth = copper }.
function H.bagAdvice()
  local out = { auction = 0, auctionWorth = 0, junk = 0, junkWorth = 0 }
  local C = C_Container
  if not C or not C.GetContainerNumSlots then return out end
  for bag = 0, 5 do
    for slot = 1, (try(C.GetContainerNumSlots, bag) or 0) do
      local info = try(C.GetContainerItemInfo, bag, slot)
      local id = info and info.itemID
      if id then
        local n = info.stackCount or 1
        if info.quality == 0 then
          local okI, _, _, _, _, _, _, _, _, _, _, sell = pcall(C_Item.GetItemInfo, id)
          if okI and type(sell) == "number" and sell > 0 then
            out.junk, out.junkWorth = out.junk + 1, out.junkWorth + sell * n
          end
        elseif not info.isBound and ns.sellVerdict then
          local which = ns.sellVerdict(id)
          local it = which == "auction" and ns.itemFor and ns.itemFor(id)
          if it and it[1] then
            out.auction, out.auctionWorth = out.auction + 1, out.auctionWorth + it[1] * n
          end
        end
      end
    end
  end
  return out
end

-- Merchant's Favor you have (nil when the game doesn't say).
function H.favorHave()
  local C = C_CurrencyInfo
  local info = C and try(C.GetCurrencyInfo, H.FAVOR_CURRENCY)
  return info and tonumber(info.quantity) or nil
end

-- EverlookDB Crafting's best crates (its API, version 4), or nil when it isn't loaded or is older.
function H.favorBest(n)
  local api = rawget(_G, "EverlookCraftAPI")
  if not api or (api.version or 0) < 4 or not api.favorBest then return nil end
  return try(api.favorBest, n or 3)
end

-- The minimap button's place on the edge: x, y from the minimap's centre for an angle (degrees). Round minimaps put
-- it on the circle; square corners push it out to the square's edge. shape is GetMinimapShape()'s answer.
local QUADRANTS = {
  ROUND = { true, true, true, true }, SQUARE = { false, false, false, false },
  ["CORNER-TOPLEFT"] = { false, false, false, true }, ["CORNER-TOPRIGHT"] = { false, false, true, false },
  ["CORNER-BOTTOMLEFT"] = { false, true, false, false }, ["CORNER-BOTTOMRIGHT"] = { true, false, false, false },
  ["SIDE-LEFT"] = { false, true, false, true }, ["SIDE-RIGHT"] = { true, false, true, false },
  ["SIDE-TOP"] = { false, false, true, true }, ["SIDE-BOTTOM"] = { true, true, false, false },
  ["TRICORNER-TOPLEFT"] = { false, true, true, true }, ["TRICORNER-TOPRIGHT"] = { true, false, true, true },
  ["TRICORNER-BOTTOMLEFT"] = { true, true, false, true }, ["TRICORNER-BOTTOMRIGHT"] = { true, true, true, false },
}
-- quadrants: 1 bottom right, 2 bottom left, 3 top right, 4 top left; true = round there
function H.minimapOffset(angle, shape, radius)
  local a = math.rad(angle or 0)
  local x, y = math.cos(a), math.sin(a)
  local q = 1
  if x < 0 then q = q + 1 end
  if y > 0 then q = q + 2 end
  local round = (QUADRANTS[shape or "ROUND"] or QUADRANTS.ROUND)[q]
  if round then return x * radius, y * radius end
  local diag = math.sqrt(2 * radius * radius) - 10
  return math.max(-radius, math.min(x * diag, radius)), math.max(-radius, math.min(y * diag, radius))
end

---------------------------------------------------------------------------------------------------------------------
-- Opening the window

local function app() return ns.app end

-- Opens the window on a page (default: the page used last, never Gear upgrades). True when it opened.
function H.open(page)
  local a = app()
  if not a or not a.sections or not H.ready then return false end
  if page and not a.sections[page] then page = nil end
  a:Open(page)
  return true
end

function H.close() local a = app(); if a then a:Close() end end
function H.isOpen(page)
  local a = app()
  if not a or not a:IsShown() then return false end
  return page == nil or a.current == page
end
-- Open, or close when that page is already up.
function H.toggle(page)
  if H.isOpen(page) then H.close(); return end
  H.open(page)
end
-- The page matching what the auction house shows now (its price bar's "Open in EverlookDB Auctions"): Gear upgrades
-- or Advanced search, else nil (the page used last).
function H.ahPage()
  local V = ns.upgradesView
  if V and V.inAH then return "gear" end
  local q = rawget(_G, "EverlookAuctionsQueryResults")
  if q and q:IsVisible() then return "search" end
  return nil
end

-- The key binding (Bindings.xml)
function EverlookDBAuctions_ToggleMain() H.toggle() end
BINDING_HEADER_EVERLOOKDBAUCTIONS = "EverlookDB Auctions"
BINDING_NAME_EVERLOOKDBAUCTIONS_TOGGLE = "Open or close EverlookDB Auctions"

-- Moves one of the addon's own windows into a page: no window edge, close button, dragging or keys of its own (the
-- main window has them), at holder's top left.
function H.dock(f, holder, x, y)
  if f:GetParent() ~= holder then f:SetParent(holder) end
  f:ClearAllPoints()
  f:SetPoint("TOPLEFT", holder, "TOPLEFT", x or 0, y or 0)
  f.edbDocked = holder
  if f.SetMovable then f:SetMovable(false) end
  if f.RegisterForDrag then f:RegisterForDrag() end
  f:SetScript("OnDragStart", nil)
  f:SetScript("OnDragStop", nil)
  f:SetScript("OnKeyDown", nil)
  if f.EnableKeyboard then f:EnableKeyboard(false) end
  if f.SetToplevel then f:SetToplevel(false) end
  f:SetFrameStrata(holder:GetFrameStrata())
  f:SetFrameLevel((holder:GetFrameLevel() or 1) + 2)
  for _, k in ipairs({ "bgFill", "bgEdge", "accentLine", "closeButton", "grip" }) do
    if f[k] and f[k].Hide then f[k]:Hide() end
  end
end

---------------------------------------------------------------------------------------------------------------------
-- Drawing helpers: the same title row as the AH log and Crafting profit (icon, title, one grey line under it)

local T
local PAD = 20

local function text(parent, size, color, justify)
  local fs = EUI.Text(parent, size, color)
  fs:SetJustifyH(justify or "LEFT")
  return fs
end

function H.head(holder, icon, title, sub)
  local h = {}
  h.icon = holder:CreateTexture(nil, "ARTWORK")
  h.icon:SetSize(18, 18)
  h.icon:SetPoint("TOPLEFT", PAD, -20)
  if EUI.SetIcon(h.icon, icon) then h.icon:SetVertexColor(rgba(T.accent)) end
  h.title = text(holder, T.fontHuge, T.text)
  h.title:SetPoint("LEFT", h.icon, "RIGHT", 8, 0)
  h.title:SetText(title)
  h.sub = text(holder, T.font - 1, T.muted)
  h.sub:SetPoint("TOPLEFT", PAD, -48)
  h.sub:SetPoint("RIGHT", holder, "RIGHT", -PAD, 0)
  h.sub:SetWordWrap(false)
  h.sub:SetText(sub or "")
  return h
end

-- A page body under the title row, inset like the AH log's card.
local function body(holder, top)
  local b = CreateFrame("Frame", nil, holder)
  b:SetPoint("TOPLEFT", holder, "TOPLEFT", 16, -(top or 64))
  b:SetPoint("BOTTOMRIGHT", holder, "BOTTOMRIGHT", -16, 16)
  return b
end

-- A note behind a moved-in view, for when the auction house has it right now.
local function awayNote(holder, what)
  local n = text(holder, T.font, T.muted, "CENTER")
  n:SetPoint("CENTER", 0, 20)
  n:SetText(what .. " is open at the auction house right now.\nClose it there, or pick this page again.")
  return n
end

-- A home card: a line icon, a title, two lines, and the whole card a button into its page (a chevron on the right).
local CARD_H = 84
local function card(parent, icon, title, onOpen)
  local c = CreateFrame("Button", nil, parent)
  c:SetHeight(CARD_H)
  c.bg = U.Round(c, T.radius, "BACKGROUND")
  c.bg:SetAllPoints(c)
  c.bg:SetVertexColor(rgba(T.card))
  c.edge = U.RoundOutline and U.RoundOutline(c, T.radius, "BORDER") or nil
  if c.edge then c.edge:SetAllPoints(c); c.edge:SetVertexColor(rgba(T.divider)) end
  c.icon = c:CreateTexture(nil, "ARTWORK")
  c.icon:SetSize(20, 20)
  c.icon:SetPoint("TOPLEFT", 16, -16)
  if EUI.SetIcon(c.icon, icon) then c.icon:SetVertexColor(rgba(T.accent)) end
  c.title = text(c, T.fontTitle, T.text)
  c.title:SetPoint("TOPLEFT", 48, -16)
  c.title:SetText(title)
  c.line1 = text(c, T.font, T.text)
  c.line1:SetPoint("TOPLEFT", 48, -38)
  c.line1:SetPoint("RIGHT", -36, 0)
  c.line1:SetWordWrap(false)
  c.line2 = text(c, T.font - 1, T.muted)
  c.line2:SetPoint("TOPLEFT", 48, -57)
  c.line2:SetPoint("RIGHT", -36, 0)
  c.line2:SetWordWrap(false)
  if onOpen then
    c.chev = c:CreateTexture(nil, "ARTWORK")
    c.chev:SetSize(10, 10)
    c.chev:SetPoint("RIGHT", -16, 0)
    if EUI.SetIcon(c.chev, "chevron") then c.chev:SetVertexColor(rgba(T.muted)) end
    -- the chevron atlas points down; turned a quarter it points right, "go there"
    if c.chev.SetRotation then c.chev:SetRotation(math.pi / 2) end
    c:SetScript("OnClick", onOpen)
    c:SetScript("OnEnter", function(self)
      self.bg:SetVertexColor(rgba(T.surface))
      if self.chev then self.chev:SetVertexColor(rgba(T.accent)) end
    end)
    c:SetScript("OnLeave", function(self)
      self.bg:SetVertexColor(rgba(T.card))
      if self.chev then self.chev:SetVertexColor(rgba(T.muted)) end
    end)
  else
    c:EnableMouse(false)
  end
  function c:Set(l1, l2)
    self.line1:SetText(l1 or "")
    self.line2:SetText(l2 or "")
  end
  return c
end

---------------------------------------------------------------------------------------------------------------------
-- Home

local home = {}

-- Search the last scan and the Price Feed from Home: Advanced search with the words in it.
function H.searchPrices(words)
  words = tostring(words or ""):gsub("^%s+", ""):gsub("%s+$", "")
  H.pendingQuery = words ~= "" and words or nil
  H.open("search")
end

local function buildHome(holder)
  home.frame = holder
  local head = H.head(holder, "home", "Home", "Everything EverlookDB Auctions keeps for you, one click from here.")
  home.head = head

  -- Prices anywhere: the remote auction house, a search box on Home
  local p = card(holder, "search", "Prices anywhere", nil)
  p:SetPoint("TOPLEFT", PAD, -76)
  p:SetPoint("RIGHT", holder, "RIGHT", -PAD, 0)
  p:SetHeight(104)
  p:EnableMouse(true)
  p.line1:SetPoint("RIGHT", -16, 0)
  p.line2:SetPoint("RIGHT", -16, 0)
  local box = EUI.EditBox(p, 360, 26)
  box:SetPoint("TOPLEFT", 48, -70)
  box:SetPoint("RIGHT", p, "RIGHT", -112, 0)
  box:SetTextInsets(10, 10, 0, 0)
  box.hint = text(box, T.font, T.muted)
  box.hint:SetPoint("LEFT", 10, 0)
  box.hint:SetText("An item's name, or a query like  slot is trinket and price lt 5g")
  box:HookScript("OnTextChanged", function(self) self.hint:SetShown((self:GetText() or "") == "") end)
  box:SetScript("OnEnterPressed", function(self) self:ClearFocus(); H.searchPrices(self:GetText()) end)
  box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  home.box = box
  -- the page's one gold button
  local go = EUI.Button(p, "Search", function() box:ClearFocus(); H.searchPrices(box:GetText()) end, 84, "accent")
  go:SetPoint("LEFT", box, "RIGHT", 12, 0)
  home.prices = p

  -- the cards, two columns
  local cards = {
    { "income", "coins", "Income", function() if ns.purchases then ns.purchases.mode = "income" end; H.open("log") end },
    { "loot", "bag", "Loot", function() if ns.purchases then ns.purchases.mode = "looted" end; H.open("log") end },
    { "favor", "star", "Merchant's Favor", function() H.open("favor") end },
    { "gear", "sword", "Gear upgrades", function() H.open("gear") end },
    { "crafts", "hammer", "Crafting profit", function() H.open("crafts") end },
    { "ah", "grid", "At the auction house", nil },
  }
  home.cards = {}
  for i, d in ipairs(cards) do
    local c = card(holder, d[2], d[3], d[4])
    home.cards[d[1]] = c
    c.slotIndex = i
  end
  local function layout()
    local w = holder:GetWidth() or 0
    if w <= 0 then return end
    local cw = math.floor((w - PAD * 2 - 12) / 2)
    for _, c in pairs(home.cards) do
      local i = c.slotIndex - 1
      local col, row = i % 2, math.floor(i / 2)
      c:ClearAllPoints()
      c:SetPoint("TOPLEFT", holder, "TOPLEFT", PAD + col * (cw + 12), -(76 + 104 + 12 + row * (CARD_H + 12)))
      c:SetWidth(cw)
    end
  end
  holder:SetScript("OnSizeChanged", layout)
  layout()
  home.layout = layout

  home.foot = text(holder, T.fontSmall, T.muted)
  home.foot:SetPoint("BOTTOMLEFT", PAD, 14)
  home.foot:SetText("/eah opens this window  \194\183  right-click the minimap button for settings  \194\183  set a key in Key Bindings, AddOns")
end

local function fillHome()
  if not home.frame then return end
  local now = time()
  home.layout()

  -- prices
  local lines = H.priceLines(now)
  home.prices:Set(lines[1], lines[2])

  -- income
  local d = db() or {}
  local today, week, waiting, est = H.income(d.income, d.soldPending, now)
  home.cards.income:Set(("Today %s  \194\183  last 7 days %s"):format(money(today), money(week)),
    waiting > 0 and (("%d sold, waiting in your mail%s"):format(waiting, est > 0 and (" (about " .. money(est) .. ")") or ""))
      or "Sales and other gold you take from the mail")

  -- loot: today's, and what to do with what is in the bags
  local n, worth, coins = 0, 0, 0
  if ns.purchases and ns.purchases.lootToday then n, worth, coins = ns.purchases.lootToday() end
  local advice = H.bagAdvice()
  local tip
  if advice.auction > 0 then
    tip = ("%d %s in your bags sell for more at the auction house (about %s)"):format(advice.auction,
      advice.auction == 1 and "item" or "items", money(advice.auctionWorth))
  elseif advice.junk > 0 then
    tip = ("%d grey %s to sell to a vendor (%s)"):format(advice.junk, advice.junk == 1 and "item" or "items", money(advice.junkWorth))
  else
    tip = "Each pick-up gets a card with what it is worth"
  end
  home.cards.loot:Set(("Today %d %s, about %s"):format(n, n == 1 and "item" or "items", money(worth + coins)), tip)

  -- Merchant's Favor
  local have = H.favorHave()
  local best = H.favorBest(1)
  local first = best and best[1]
  local l1 = have and ("You have %s Merchant's Favor"):format(ns.num and ns.num(have) or have) or "Waylaid Crates for Merchant's Favor"
  local l2
  if first then
    l2 = ("Best crate now: %s, %s"):format(first.name or "?", first.perFavorText or "")
  elseif rawget(_G, "EverlookCraftAPI") then
    l2 = "Ranked by gold per Favor in EverlookDB Crafting (/ecraft favor)"
  else
    l2 = "EverlookDB Crafting ranks crates by gold per Favor"
  end
  home.cards.favor:Set(l1, l2)

  -- gear upgrades (the last reading of the scan; never started from here)
  local up = ns.up
  local r = up and up.result
  local view = ns.upgradesView
  local spec = view and view.spec and try(view.spec)
  if r and r.done and not r.none and spec and r.spec == spec then
    local bestE, bestPct
    for _, slot in pairs(r.slots or {}) do
      local e = slot.best
      local pct = e and e.cmp and e.cmp.pct
      if pct and (not bestPct or pct > bestPct) then bestE, bestPct = e, pct end
    end
    if (r.count or 0) > 0 then
      home.cards.gear:Set(("%s: %d %s on the auction house"):format(spec.name, r.count, r.count == 1 and "slot has an upgrade" or "slots have upgrades"),
        bestE and ("Best: %s, %s (%s)"):format(bestE.name or "?", up.pctText and up.pctText(bestE.cmp) or "", money(bestE.price)) or "")
    else
      home.cards.gear:Set(spec.name .. ": nothing better on the auction house right now", "From the last scan, within your max price")
    end
  else
    home.cards.gear:Set(spec and (spec.name .. ": the best upgrade per slot from the last scan") or "The best upgrade per slot from the last scan",
      "Open to read the newest scan for your spec")
  end

  -- crafting profit
  local W = ns.profitWindow
  local okC, _, rows = false, nil, nil
  if W and W.compute then okC, _, rows = pcall(W.compute) end
  if okC and type(rows) == "table" and #rows > 0 then
    local b = rows[1]
    local name = b.name or (b.out and C_Item and try(C_Item.GetItemNameByID, b.out)) or "?"
    home.cards.crafts:Set(("%d %s for more than %s materials"):format(#rows, #rows == 1 and "recipe sells" or "recipes sell", #rows == 1 and "its" or "their"),
      b.profit and ("Best: %s, %s profit each"):format(name, money(b.profit)) or "")
  else
    home.cards.crafts:Set("Recipes you know that sell for more than they cost", "Open each profession window once so the addon knows them")
  end

  -- the auction house's own tabs
  local atAH = _G.AuctionHouseFrame and AuctionHouseFrame:IsShown()
  home.cards.ah:Set("Quick sell, Shopping, Upgrades, Advanced search",
    atAH and "They are the tabs at the bottom of the auction house" or "Tabs of their own, at the auction house")
end
H.fillHome = fillHome

---------------------------------------------------------------------------------------------------------------------
-- Merchant's Favor (EverlookDB Crafting has the crates and their costs; this page shows the best and opens it)

local favor = {}
local function buildFavor(holder)
  favor.head = H.head(holder, "star", "Merchant's Favor", "Waylaid Crates, ranked by gold per Favor at your auction house's prices.")
  favor.have = card(holder, "star", "Your Favor", nil)
  favor.have:SetPoint("TOPLEFT", PAD, -76)
  favor.have:SetPoint("RIGHT", holder, "RIGHT", -PAD, 0)
  favor.rows = {}
  for i = 1, 3 do
    local c = card(holder, "check", "", function() local api = rawget(_G, "EverlookCraftAPI"); if api and api.openFavor then pcall(api.openFavor) end end)
    c:SetPoint("TOPLEFT", PAD, -(76 + (CARD_H + 12) * i))
    c:SetPoint("RIGHT", holder, "RIGHT", -PAD, 0)
    favor.rows[i] = c
  end
  favor.open = EUI.Button(holder, "Open in EverlookDB Crafting", function()
    local api = rawget(_G, "EverlookCraftAPI")
    if api and api.openFavor then pcall(api.openFavor) end
  end, 220)
  favor.open:SetPoint("BOTTOMRIGHT", -PAD, 16)
  favor.note = text(holder, T.font - 1, T.muted)
  favor.note:SetPoint("BOTTOMLEFT", PAD, 22)
  favor.note:SetPoint("RIGHT", favor.open, "LEFT", -12, 0)
  favor.note:SetWordWrap(true)
end

local function fillFavor()
  local have = H.favorHave()
  favor.have:Set(have and (ns.num and ns.num(have) or tostring(have)) .. " Merchant's Favor" or "Merchant's Favor: the game hasn't said how much you have",
    "Fill a Waylaid Crate with one bundle, seal it and hand it to your faction's Inventory Intake clerk")
  local api = rawget(_G, "EverlookCraftAPI")
  local best = H.favorBest(3)
  for i, c in ipairs(favor.rows) do
    local b = best and best[i]
    c:SetShown(b ~= nil)
    if b then
      c.title:SetText(("%d. %s"):format(i, b.name or "?"))
      c:Set(b.perFavorText or "", b.fill or "")
    end
  end
  favor.open:SetShown(api ~= nil and api.openFavor ~= nil)
  if best and #best > 0 then
    favor.note:SetText("Click a crate, or Open, for every crate, its bundles and where to turn it in.")
  elseif api then
    favor.note:SetText("Update EverlookDB Crafting to see its best crates here. /ecraft favor shows them all.")
  else
    favor.note:SetText("EverlookDB Crafting ranks every Waylaid Crate by gold per Favor with these prices. Get it on CurseForge or with the EverlookDB App.")
  end
end

---------------------------------------------------------------------------------------------------------------------
-- The pages that are the addon's existing views

local search, gear = {}, {}

local function buildSearch(holder)
  search.head = H.head(holder, "search", "Advanced search",
    "Every item in the last full scan or the Price Feed, anywhere. Live prices and buying need the auction house.")
  search.body = body(holder, 70)
  search.note = awayNote(search.body, "Advanced search")
end
local function showSearch()
  if ns.openSearchIn then ns.openSearchIn(search.body, H.pendingQuery) end
  H.pendingQuery = nil
  local q = rawget(_G, "EverlookAuctionsQueryResults")
  search.note:SetShown(not (q and q:GetParent() == search.body and q:IsShown()))
end
local function hideSearch() if ns.closeSearchIn then ns.closeSearchIn(search.body) end end

local function buildGear(holder)
  gear.head = H.head(holder, "sword", "Gear upgrades",
    "The best upgrade for your spec in every slot, from the last full scan. Buying needs the auction house.")
  gear.body = body(holder, 70)
  gear.body:SetPoint("BOTTOMRIGHT", holder, "BOTTOMRIGHT", -16, 8)   -- the slot grid needs the height
  gear.note = awayNote(gear.body, "Gear upgrades")
end
local function showGear()
  if ns.upgradesView and ns.upgradesView.dock then ns.upgradesView.dock(gear.body) end
  local v = rawget(_G, "EverlookAuctionsUpgrades")
  gear.note:SetShown(not (v and v:GetParent() == gear.body and v:IsShown()))
  -- the spec question (once per character) sits over this page, not somewhere behind the window
  local ask = rawget(_G, "EverlookAuctionsUpgradesAsk")
  if ask and ask:IsShown() then
    ask:ClearAllPoints()
    ask:SetPoint("CENTER", gear.body, "CENTER", 0, 40)
    ask:SetFrameStrata("FULLSCREEN_DIALOG")
  end
end
local function hideGear() if ns.upgradesView and ns.upgradesView.undock then ns.upgradesView.undock(gear.body) end end

local function showLog(holder) if ns.purchases and ns.purchases.dock then ns.purchases.dock(holder) end end
local function hideLog() if ns.purchases and ns.purchases.undock then ns.purchases.undock() end end
local function showCrafts(holder) if ns.profitWindow and ns.profitWindow.dock then ns.profitWindow.dock(holder) end end
local function hideCrafts() if ns.profitWindow and ns.profitWindow.undock then ns.profitWindow.undock() end end

---------------------------------------------------------------------------------------------------------------------
-- Adding the pages to the window (Options.lua made it on ADDON_LOADED, before this file's turn)

function H.addPages(a)
  if not a or H.ready or not EUI then return end
  T = a.T
  local function page(id, build, show, hide, opts)
    local p
    for _, d in ipairs(H.PAGES) do if d.id == id then p = d end end
    local o = { group = "main", panel = true, icon = p.icon, show = show, hide = hide }
    for k, v in pairs(opts or {}) do o[k] = v end
    a:Section(id, p.title, build, o)
  end
  page("home", buildHome, function() fillHome() end)
  page("search", buildSearch, showSearch, hideSearch)
  page("log", function() end, showLog, hideLog)
  page("crafts", function() end, showCrafts, hideCrafts)
  page("gear", buildGear, showGear, hideGear)
  page("favor", buildFavor, function() fillFavor() end)
  -- open on the page used last (never Gear upgrades by itself)
  local d = db()
  local known = {}
  for id in pairs(a.sections) do known[id] = true end
  a.current = H.startPage(d and d.hubPage, known)
  local open = a.Open
  function a:Open(id)
    if not id then id = H.startPage(self.current, self.sections) end
    return open(self, id)
  end
  H.ready = true
end

-- Remembers the page (spec.onPage, Options.lua).
function H.onPage(_, id)
  local d = db()
  if d then d.hubPage = id end
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:SetScript("OnEvent", function(_, _, name)
  if name ~= ADDON then return end
  ev:UnregisterEvent("ADDON_LOADED")
  if ns.app then H.addPages(ns.app) else C_Timer.After(0, function() H.addPages(ns.app) end) end
end)
