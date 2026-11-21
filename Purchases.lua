-- EverlookDB Auctions: AH purchases, a window of everything you bought at the auction house (/eah bought), open
-- anywhere, not only at the auction house. Its Income view (/eah income) lists the money you took from the mail:
-- auctions sold (item, how many, what you got after the cut) and any other gold, with what you earned and spent in the
-- last 7 days. A sold item you can craft also says what one costs to craft again at today's lowest AH prices.
--   Catching purchases: the game's buy calls are watched (hooksecurefunc, so purchases through Blizzard's window, our
--   Buy panel or another addon all count), and an entry is written only once the auction house says the purchase went
--   through. Commodities (cloth, herbs, bars): the quantity and the total price the auction house quoted. Other items:
--   the auction's buyout, one item. Bids are not logged (a bid you win arrives by mail later).
--   The window: newest first, a search box, Marked only. Click (or shift-click) an entry to mark it; shift-click with
--   the chat box open links the item instead. Under the list, a recipe (the one picked in your profession window, or
--   any you looked at before) with its cost per craft from what you paid for the marked entries; materials with no
--   marked entry use the lowest auction price, in grey.
--   The crafting box beside the profession window has a "Your buys" button that opens it on that recipe.
local _, ns = ...
local P = ns.purchaseLog
local UI = ns.UI
local B = {}

local W, PAD, ROW = 700, 14, 22
local DATE_W, QTY_W, EACH_W, TOTAL_W, CRAFT_W = 110, 40, 104, 104, 108
local REC_ROWS = 8
local STALE = 24 * 3600


local function try(fn, ...)
  if type(fn) ~= "function" then return nil end
  local okCall, a = pcall(fn, ...)
  if okCall then return a end
end
local function ok(v) return ns.ok and ns.ok(v) or v end

local function db() return ns.db and ns.db() end
local function okv(v)
  if v == nil or (issecretvalue and issecretvalue(v)) then return nil end
  return v
end
local function list()
  local d = db()
  if not d then return {} end
  d.bought = d.bought or {}
  return d.bought
end
local function incomeList()
  local d = db()
  if not d then return {} end
  d.income = d.income or {}
  return d.income
end
local function crafts()
  local d = db()
  if not d then return {} end
  d.crafts = d.crafts or {}
  return d.crafts
end
local function recipes()
  local d = db()
  if not d then return {} end
  d.recipes = d.recipes or {}
  return d.recipes
end

local function itemName(id)
  local name = try(C_Item.GetItemNameByID, id)
  if not name and C_Item.RequestLoadItemDataByID then pcall(C_Item.RequestLoadItemDataByID, id) end
  return name or ("item " .. id)
end
local function entryName(e)
  if e.kind == "mail" then return "Gold from mail" end
  if e.loot then return e.copper and "Money" or (e.link and e.link:match("%[(.-)%]")) or e.name or "?" end
  if e.pending or e.sale then return (e.link and e.link:match("%[(.-)%]")) or e.name or "?" end
  if e.kind == "ah" then return "Auction house refund" end
  return (e.link and e.link:match("%[(.-)%]")) or e.name or (e.id and itemName(e.id)) or "?"
end
local function qualityColor(id)
  if not id then return 1, 0.82, 0 end
  local q = try(C_Item.GetItemQualityByID, id)
  local c = q and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q]
  if c then return c.r, c.g, c.b end
  return 1, 1, 1
end
local function priceOf(id)
  local it = ns.itemFor and ns.itemFor(id)
  return it and it[1], it and it[4]
end
local function money(c) return ns.money(c) end

-- A sold item's id: saved with the sale, or found from its name once the game knows the item.
local function saleID(e)
  if e.id or (e.kind ~= "sale" and not e.pending) or not e.name then return e.id end
  local okId, id = pcall(C_Item.GetItemInfoInstant, e.name)
  if okId and type(id) == "number" then e.id = id end
  return e.id
end

-- What one more costs to craft at the latest AH prices (nil when you don't know a recipe for it, or a material has
-- no price), how many materials have no price, and when the oldest price used was seen.
local function craftNow(id)
  local r = id and crafts()[id]
  if not r then return nil, nil end
  local oldest
  local cost, missing = P.craftEach(r, function(m)
    local p, at = priceOf(m)
    if p and at and (not oldest or at < oldest) then oldest = at end
    return p
  end)
  return cost, missing, oldest, r
end
B.craftNow = craftNow

---------------------------------------------------------------------------------------------------------------------
-- Catching purchases

local AH = C_AuctionHouse or {}
local seen = {}         -- auctionID -> { id, link, buyout } from the item search results the auction house sent
local pending = {}      -- auctionID -> the entry to write once the purchase goes through
local quote, buying     -- commodities: the last price quote, and the purchase waiting for its answer

local function houseKey() return ns.house and ns.house() end

local function readResults(itemKey)
  if type(itemKey) ~= "table" then return end
  local id = ok(itemKey.itemID)
  for i = 1, (try(AH.GetNumItemSearchResults, itemKey) or 0) do
    local r = try(AH.GetItemSearchResultInfo, itemKey, i)
    local aid = r and ok(r.auctionID)
    if aid and id then
      local link = ok(r.itemLink)
      seen[aid] = { id = id, link = link, buyout = ok(r.buyoutAmount) }
    end
  end
end

local function write(e)
  local d = db()
  if not d or d.logBuys == false then return end
  e.t, e.h = time(), houseKey()
  if P.add(list(), e) and B.frame and B.frame:IsShown() then B.render() end
end

if AH.PlaceBid then
  hooksecurefunc(AH, "PlaceBid", function(auctionID, amount)
    auctionID, amount = ok(auctionID), ok(amount)
    local a = auctionID and seen[auctionID]
    if not a and auctionID and AH.GetAuctionInfoByID then
      local info = try(AH.GetAuctionInfoByID, auctionID)
      local key = info and ok(info.itemKey)
      if key and ok(key.itemID) then
        a = { id = ok(key.itemID), link = ok(info.itemLink), buyout = ok(info.buyoutAmount) }
      end
    end
    -- a buyout only: a bid below the buyout may never win
    if a and amount and a.buyout and amount >= a.buyout then
      pending[auctionID] = { id = a.id, q = 1, c = amount, link = a.link }
    end
  end)
end
if AH.StartCommoditiesPurchase then
  hooksecurefunc(AH, "StartCommoditiesPurchase", function(id, qty)
    quote = { id = ok(id), q = ok(qty) }
  end)
end
if AH.ConfirmCommoditiesPurchase then
  hooksecurefunc(AH, "ConfirmCommoditiesPurchase", function(id, qty)
    id, qty = ok(id), ok(qty)
    if quote and quote.id == id and quote.total and (qty == nil or qty == quote.q) then
      buying = { id = id, q = quote.q, c = quote.total }
    end
  end)
end

local ev = CreateFrame("Frame")
for _, e in ipairs({ "ITEM_SEARCH_RESULTS_UPDATED", "ITEM_SEARCH_RESULTS_ADDED", "COMMODITY_PRICE_UPDATED",
    "COMMODITY_PURCHASE_SUCCEEDED", "COMMODITY_PURCHASE_FAILED", "AUCTION_HOUSE_PURCHASE_COMPLETED",
    "AUCTION_HOUSE_CLOSED", "GET_ITEM_INFO_RECEIVED" }) do
  pcall(ev.RegisterEvent, ev, e)
end
local soon
ev:SetScript("OnEvent", function(_, e, a1, a2)
  if e == "ITEM_SEARCH_RESULTS_UPDATED" or e == "ITEM_SEARCH_RESULTS_ADDED" then
    readResults(a1)
  elseif e == "COMMODITY_PRICE_UPDATED" then
    local total = ok(a2)
    if quote and type(total) == "number" and total > 0 then quote.total = total end
  elseif e == "COMMODITY_PURCHASE_SUCCEEDED" then
    if buying then write(buying) end
    buying, quote = nil, nil
  elseif e == "COMMODITY_PURCHASE_FAILED" then
    buying, quote = nil, nil
  elseif e == "AUCTION_HOUSE_PURCHASE_COMPLETED" then
    local aid = ok(a1)
    local p = aid and pending[aid]
    if p then
      pending[aid] = nil
      write(p)
    end
  elseif e == "AUCTION_HOUSE_CLOSED" then
    seen, pending, quote, buying = {}, {}, nil, nil
  elseif e == "GET_ITEM_INFO_RECEIVED" then
    if B.frame and B.frame:IsShown() and not soon then
      soon = true
      C_Timer.After(0.3, function() soon = nil; B.render() end)
    end
  end
end)

---------------------------------------------------------------------------------------------------------------------
-- Money from the mail: read the mail as its money is taken (Blizzard's Open All, a click on the coins, or a mail addon),
-- before the server removes it. One mail is logged once even when both calls reach it.

local AH_SENDER = BUTTON_LAG_AUCTIONHOUSE or "Auction House"
local recentMail = {}

local function takeMail(i)
  if not GetInboxHeaderInfo then return end
  local okH, _, _, sender, subject, cash, _, daysLeft = pcall(GetInboxHeaderInfo, i)
  cash = okH and ok(cash)
  if type(cash) ~= "number" or cash <= 0 then return end
  local d = db()
  if not d or d.logIncome == false then return end
  local sig = tostring(subject) .. "|" .. cash .. "|" .. tostring(daysLeft)
  local now = GetTime and GetTime() or time()
  if recentMail[sig] and now - recentMail[sig] < 10 then return end
  recentMail[sig] = now
  local e = { c = cash, kind = "mail" }
  local okI, kind, item, _, bid, _, _, _, _, _, _, count = pcall(GetInboxInvoiceInfo or function() end, i)
  if okI and ok(kind) == "seller" and ok(item) then
    e.kind, e.name, e.q, e.gross = "sale", ok(item), ok(count) or 1, ok(bid)
    saleID(e)
    P.settlePending(B.pending(), e.name)
  elseif ok(sender) == AH_SENDER then
    e.kind = "ah"
  end
  e.t, e.h = time(), houseKey()
  if P.addIncome(incomeList(), e) and B.frame and B.frame:IsShown() then B.render() end
end
for _, name in ipairs({ "TakeInboxMoney", "AutoLootMailItem" }) do
  if _G[name] then hooksecurefunc(name, takeMail) end
end
B.takeMail = takeMail

-- Your auctions as the auction house last showed them (per character: EverlookAuctionsCharDB.forSale =
-- { at = when, list = { { id, name, link, q, c = buyout of all of it (nil: bids only), ends = time it runs out } } }).
-- Read on every visit to the auction house; a sale the game tells you about takes its auction off.
local function charDB()
  EverlookAuctionsCharDB = EverlookAuctionsCharDB or {}
  return EverlookAuctionsCharDB
end
function B.forSale()
  local c = charDB()
  c.forSale = c.forSale or { list = {} }
  return c.forSale
end
function B.noteOwned(owned)
  if type(owned) ~= "table" then return end
  local now = time()
  local out = {}
  for _, a in ipairs(owned) do
    if not a.sold then
      out[#out + 1] = { id = a.itemID, name = a.name, link = a.link, q = a.qty or 1, t = now,
        c = a.unit and a.unit * (a.qty or 1) or nil, ends = a.left and (now + a.left) or nil, band = a.band, sale = true }
    end
  end
  local fs = B.forSale()
  fs.at, fs.list = now, out
  if B.frame and B.frame:IsShown() then B.render() end
end
local function offSale(name)
  local fs = B.forSale()
  for i, e in ipairs(fs.list or {}) do
    if e.name == name then table.remove(fs.list, i); return end
  end
end
-- one look at your auctions per visit to the auction house, so For sale is fresh without opening Quick sell
local ahev = CreateFrame("Frame")
pcall(ahev.RegisterEvent, ahev, "AUCTION_HOUSE_SHOW")
ahev:SetScript("OnEvent", function()
  if C_Timer and ns.sellQueryOwned then C_Timer.After(2, function() pcall(ns.sellQueryOwned) end) end
end)

-- Everything you looted (per character, EverlookAuctionsCharDB.looted, oldest first: { t, id, name, link, q, quality,
-- zone } or { t, copper, zone }), newest LOOT_MAX kept. LootCards.lua reads the loot lines and calls B.noteLoot.
local LOOT_MAX = 5000
function B.looted()
  local c = charDB()
  c.looted = c.looted or {}
  return c.looted
end
function B.noteLoot(e, link)
  local d = db()
  if d and d.logLoot == false then return end
  local zone = GetRealZoneText and okv(GetRealZoneText()) or nil
  local r = { t = time(), zone = zone, loot = true, from = e.from, how = e.how, npc = e.npc, got = e.got }
  if e.copper then
    r.copper = e.copper
  else
    r.id, r.name, r.q, r.quality = e.id, e.name, e.count or 1, e.quality
    -- the link only when it says more than the id (random stats: "of the Bear")
    if link and link:match("|Hitem:%d+:[^|]*[1-9]") then r.link = link:match("|c%x+|Hitem:.-|h|r") or nil end
  end
  local list = B.looted()
  list[#list + 1] = r
  while #list > LOOT_MAX do table.remove(list, 1) end
  if B.frame and B.frame:IsShown() and B.mode == "looted" then B.render() end
  if B.broker then B.broker() end
end

-- Sales still in the mail (Celebrate.lua calls B.noteSold when the game says one of your auctions sold).
function B.pending()
  local d = db()
  if not d then return {} end
  d.soldPending = d.soldPending or {}
  return d.soldPending
end
function B.noteSold(name, est, count)
  local d = db()
  if not d or d.logIncome == false then return end
  offSale(name)
  local e = { t = time(), name = name, q = count, est = est, h = houseKey(), pending = true }
  if P.addPending(B.pending(), e, e.t) and B.frame and B.frame:IsShown() then B.render() end
end

-- Every recipe you know, read when a profession window opens: what it makes and from what.
local function readRecipes()
  local T = C_TradeSkillUI
  if not (T and T.GetAllRecipeIDs and T.GetRecipeSchematic) then return end
  local ids = try(T.GetAllRecipeIDs)
  if type(ids) ~= "table" then return end
  local store = crafts()
  for _, rid in ipairs(ids) do
    local info = T.GetRecipeInfo and try(T.GetRecipeInfo, rid)
    if not info or ok(info.learned) ~= false then
      local sc = try(T.GetRecipeSchematic, rid, false)
      local out = sc and ok(sc.outputItemID)
      if out then
        local r = { mats = {}, makes = ((sc.quantityMin or 1) + (sc.quantityMax or sc.quantityMin or 1)) / 2 }
        for _, slot in ipairs(sc.reagentSlotSchematics or {}) do
          local rg = slot.reagents and slot.reagents[1]
          local need = ok(slot.quantityRequired) or 0
          if rg and rg.itemID and need > 0 and not slot.hiddenInCraftingForm then r.mats[#r.mats + 1] = { rg.itemID, need } end
        end
        r.rid, r.name = rid, ok(info and info.name) or ok(sc.name)
        if #r.mats > 0 then store[out] = r end
      end
    end
  end
end
B.readRecipes = readRecipes

-- A recipe from a link: a recipe link (shift-click in the profession window) or an item you know how to craft.
local function recipeFromLink(link)
  if type(link) ~= "string" then return nil end
  local T = C_TradeSkillUI
  local rid = link:match("|Henchant:(%d+)") or link:match("|Hspell:(%d+)") or link:match("|Htrade:[^:]*:(%d+)")
  rid = tonumber(rid)
  if rid and T and T.GetRecipeSchematic then
    local sc = try(T.GetRecipeSchematic, rid, false)
    if sc then
      local w = { recipeID = rid, name = ok(sc.name) or link:match("%[(.-)%]"), mats = {}, out = ok(sc.outputItemID),
        makes = ((sc.quantityMin or 1) + (sc.quantityMax or sc.quantityMin or 1)) / 2 }
      for _, slot in ipairs(sc.reagentSlotSchematics or {}) do
        local rg = slot.reagents and slot.reagents[1]
        local need = ok(slot.quantityRequired) or 0
        if rg and rg.itemID and need > 0 and not slot.hiddenInCraftingForm then w.mats[#w.mats + 1] = { rg.itemID, need } end
      end
      if #w.mats > 0 then return w end
    end
  end
  local id = tonumber(link:match("|Hitem:(%d+)"))
  local r = id and crafts()[id]
  if r and r.rid then
    return { recipeID = r.rid, name = r.name or itemName(id), mats = r.mats, out = id, makes = r.makes }
  end
end

local function linked(link)
  if not (B.frame and B.frame:IsShown()) then return end
  local w = recipeFromLink(link)
  if not w then return end
  P.noteRecipe(recipes(), w)
  local d = db()
  if d then d.boughtRecipe = w.recipeID end
  B.mode = "bought"
  B.render()
end
B.linked = linked
if ChatEdit_InsertLink then hooksecurefunc("ChatEdit_InsertLink", linked) end
if ChatFrameUtil and ChatFrameUtil.InsertLink then hooksecurefunc(ChatFrameUtil, "InsertLink", linked) end

-- The tooltip line (EverlookDBAuctions.lua registers it with the other price lines): what crafting one costs.
function B.craftLine(id)
  local cost, missing, oldest, r = craftNow(id)
  return cost, missing, oldest, r and r.makes
end
local readQueued
local rev = CreateFrame("Frame")
for _, e in ipairs({ "TRADE_SKILL_SHOW", "TRADE_SKILL_LIST_UPDATE" }) do pcall(rev.RegisterEvent, rev, e) end
rev:SetScript("OnEvent", function()
  if readQueued then return end
  readQueued = true
  C_Timer.After(1, function() readQueued = nil; pcall(readRecipes) end)
end)

---------------------------------------------------------------------------------------------------------------------
-- The window, on the shared EverlookUI look (the same as the settings window): a rounded slate window with a gold
-- line along the top, the list and the recipe in rounded cards, the softened gold for filled buttons. Its opacity and
-- how many rows it shows are settings (Options, AH log page).

local EUI = LibStub and LibStub("EverlookUI-1", true)
local U = EUI and EUI.Util
local T   -- the theme, made with the window (EverlookDB gold as the accent)

local function rgba(c) return c[1], c[2], c[3], c[4] or 1 end
local function setting(key, default)
  local d = db()
  local v = d and d[key]
  if v == nil then return default end
  return v
end
local MIN_ROWS, MAX_ROWS = 3, 40
local function rows() return math.max(MIN_ROWS, math.min(MAX_ROWS, math.floor(tonumber(setting("logRows", 12)) or 12))) end

-- The window's width (drag its corner): narrow is the essentials (time, item, how many, total), normal adds each and
-- the third column, wide gives names and sources more room.
local MIN_W, MAX_W, MINI_W, COMPACT_W, WIDE_W = 340, 1200, 480, 620, 860
local function width() return math.max(MIN_W, math.min(MAX_W, math.floor(tonumber(setting("logW", W)) or W))) end
local function layoutNow()
  local w = width()
  local compact, wide = w < COMPACT_W, w >= WIDE_W
  local mini = w < MINI_W   -- narrower still: no title, short tabs
  local mode = B.mode or "bought"
  local L = { w = w, compact = compact, mini = mini, wide = wide, looted = mode == "looted",
    craftW = wide and 170 or CRAFT_W, totalW = mini and 80 or TOTAL_W, top = compact and 84 or 104 }
  -- Columns by what matters most in each view, each only while item names keep NAME_MIN of room: in Looted where it
  -- came from, and nothing else (how many goes with the name, the total says what it is worth); elsewhere how many,
  -- then each, then the craft cost. The full date last.
  local NAME_MIN = 150
  local order = mode == "looted" and { "craft" } or (mode == "bought" and { "qty", "each" } or { "qty", "each", "craft" })
  local widths = { qty = QTY_W, each = EACH_W, craft = L.craftW }
  local room = w - 32 - PAD * 2 - 22 - L.totalW - 60
  for _, c in ipairs(order) do
    local need = widths[c] + 8 + ((c == "craft" and L.looted) and 8 or 0)
    if room - need >= NAME_MIN then L[c] = true; room = room - need end
  end
  L.fullDate = room - (DATE_W - 60) >= NAME_MIN
  L.dateW = L.fullDate and DATE_W or 60
  if L.fullDate then room = room - (DATE_W - 60) end
  -- Looted: FROM takes half the spare room, so it sits between the item and the total instead of hugging the total
  if L.looted and L.craft and room > NAME_MIN then L.craftW = L.craftW + math.floor((room - NAME_MIN) / 2) end
  return L
end
B.layoutNow = layoutNow
local function alpha() return math.max(0.3, math.min(1, tonumber(setting("logAlpha", 0.97)) or 0.97)) end

local function text(parent, size, color, justify)
  local fs = EUI.Text(parent, size or T.font, color or T.text)
  fs:SetJustifyH(justify or "LEFT")
  fs:SetWordWrap(false)
  return fs
end
local function setMoney(fs, copper, color)
  fs:SetText((copper < 0 and "-" or "") .. money(math.abs(copper)))
  fs:SetTextColor(rgba(color or T.text))
end
local function quiet(fs, msg)
  fs:SetText(msg)
  fs:SetTextColor(rgba(T.muted))
end
local function tipFor(owner, title, line)
  owner:HookScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(title, 1, 1, 1)
    GameTooltip:AddLine(line, nil, nil, nil, true)
    GameTooltip:Show()
  end)
  owner:HookScript("OnLeave", function() GameTooltip:Hide() end)
end

-- A rounded card; its fill follows the window's opacity.
local function card(parent)
  local c = CreateFrame("Frame", nil, parent)
  c.fill, c.edge = U.RoundBox(c, T.radius, T.card, T.divider)
  return c
end

-- A small on/off chip (Marked only): accent-tinted when on.
local function chip(parent, label, onClick)
  local b = EUI.Button(parent, label, onClick, 110)
  b:SetHeight(24)
  function b:SetOn(on)
    self.on = on and true or false
    self.bg:SetVertexColor(rgba(on and T.accentDim or T.surface))
    self.border:SetColor(rgba(on and (T.accentFill or T.accent) or T.border))
    self.label:SetTextColor(rgba(on and T.accent or T.text))
  end
  b:HookScript("OnLeave", function(self) self:SetOn(self.on) end)
  return b
end

local function chatOpen()
  local eb = ChatEdit_GetActiveWindow and ChatEdit_GetActiveWindow()
  return eb ~= nil
end

local function toggleMark(e)
  e.m = not e.m or nil
  B.render()
end

local function paintRow(row)
  local e = row.entry
  if row.hover then
    row.bg:SetVertexColor(rgba(T.surfaceHi)); row.bg:Show()
  elseif e and e.m and B.mode ~= "income" then
    row.bg:SetVertexColor(rgba(T.accentDim)); row.bg:Show()
  else
    row.bg:Hide()
  end
end

local function rowTooltip(self)
  local e = self.entry
  if not e then return end
  GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
  if B.mode == "looted" then
    if e.copper then
      GameTooltip:SetText(money(e.copper), 1, 0.82, 0)
    elseif e.link then pcall(GameTooltip.SetHyperlink, GameTooltip, e.link)
    elseif e.id then pcall(GameTooltip.SetItemByID, GameTooltip, e.id) end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(("Looted %s%s"):format(date("%d %b %Y %H:%M", e.t), e.zone and (" in " .. e.zone) or ""), 1, 0.82, 0)
    if e.from or e.how then
      GameTooltip:AddLine("From: " .. (e.from or "?") .. (e.how and e.how ~= e.from and (" (" .. e.how .. ")") or ""), 1, 1, 1)
    end
    GameTooltip:Show()
    return
  end
  if B.mode == "forsale" then
    if e.link then pcall(GameTooltip.SetHyperlink, GameTooltip, e.link) elseif e.id then pcall(GameTooltip.SetItemByID, GameTooltip, e.id) end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(e.c and ("Up for sale: %d for %s (%s each)"):format(e.q, money(e.c), money(math.floor(e.c / math.max(1, e.q) + 0.5)))
      or ("Up for sale: %d, bids only"):format(e.q), 1, 0.82, 0)
    local cost = craftNow(e.id)
    if cost and e.c then
      local m = math.floor(e.c / math.max(1, e.q) + 0.5) - cost
      GameTooltip:AddLine(("Crafting one costs about %s at today's lowest AH prices: %s %s each if it sells."):format(money(cost),
        m >= 0 and "you make" or "you lose", money(math.abs(m))), m >= 0 and 0.38 or 0.94, m >= 0 and 0.81 or 0.37, m >= 0 and 0.53 or 0.37, true)
    end
    GameTooltip:AddLine("As the auction house showed it on your last visit.", 0.6, 0.6, 0.6, true)
    GameTooltip:Show()
    return
  end
  if B.mode == "income" then
    local id = saleID(e)
    if id then pcall(GameTooltip.SetItemByID, GameTooltip, id) else GameTooltip:SetText(entryName(e), 1, 0.82, 0) end
    GameTooltip:AddLine(" ")
    if e.pending then
      GameTooltip:AddLine(("Sold %s: the money is waiting in your mail."):format(date("%d %b %Y %H:%M", e.t)), 1, 0.82, 0)
      if e.est then
        GameTooltip:AddLine(("About %s, from the price you last posted it at with Quick sell, before the auction house's cut."):format(money(e.est)), 0.6, 0.6, 0.6, true)
      end
      GameTooltip:AddLine("It moves to your income when you take the money from the mail.", 0.6, 0.6, 0.6, true)
    elseif e.kind == "sale" then
      local each = math.floor(e.c / e.q + 0.5)
      GameTooltip:AddLine(("Sold %d; money taken %s: %s (%s each)"):format(e.q, date("%d %b %Y %H:%M", e.t), money(e.c), money(each)), 1, 0.82, 0)
      if e.gross and e.gross > e.c then
        GameTooltip:AddLine(("The buyer paid %s; the auction house kept %s."):format(money(e.gross), money(e.gross - e.c)), 0.6, 0.6, 0.6)
      end
      local cost, missing = craftNow(id)
      if cost then
        local m = each - cost
        GameTooltip:AddLine(("Crafting one again costs about %s at today's lowest AH prices: %s %s each."):format(money(cost),
          m >= 0 and "you made" or "you lost", money(math.abs(m))), m >= 0 and 0.38 or 0.94, m >= 0 and 0.81 or 0.37, m >= 0 and 0.53 or 0.37, true)
      elseif missing then
        GameTooltip:AddLine("You can craft this, but a material has no AH price yet.", 0.6, 0.6, 0.6, true)
      end
    else
      GameTooltip:AddLine(("Taken from the mail %s: %s"):format(date("%d %b %Y %H:%M", e.t), money(e.c)), 1, 0.82, 0)
    end
    GameTooltip:Show()
    return
  end
  if e.link then pcall(GameTooltip.SetHyperlink, GameTooltip, e.link) else pcall(GameTooltip.SetItemByID, GameTooltip, e.id) end
  GameTooltip:AddLine(" ")
  GameTooltip:AddLine(("Bought %s: %d for %s"):format(date("%d %b %Y %H:%M", e.t), e.q, money(e.c)), 1, 0.82, 0)
  GameTooltip:AddLine(e.m and "Marked. Click to unmark." or "Click to mark it for the recipe below.", 0.6, 0.6, 0.6)
  GameTooltip:Show()
end

local function makeRow(parent)
  local row = CreateFrame("Button", nil, parent)
  row:SetHeight(ROW)
  row:RegisterForClicks("LeftButtonUp")
  row.bg = U.Round(row, 4, "BACKGROUND")
  row.bg:SetPoint("TOPLEFT", -6, 1)
  row.bg:SetPoint("BOTTOMRIGHT", 6, -1)
  row.bg:Hide()
  row.check = row:CreateTexture(nil, "ARTWORK")
  row.check:SetSize(10, 10)
  row.check:SetPoint("LEFT", 0, 0)
  if not EUI.SetIcon(row.check, "check") then row.check:SetTexture("Interface\\Buttons\\UI-CheckBox-Check") end
  row.check:SetVertexColor(rgba(T.accent))
  row.date = text(row, T.font - 1, T.muted)
  row.date:SetPoint("LEFT", 16, 0)
  row.date:SetWidth(DATE_W - 16)
  row.total = text(row, T.font, T.text, "RIGHT")
  row.total:SetPoint("RIGHT", 0, 0)
  row.total:SetWidth(TOTAL_W)
  row.craft = text(row, T.font, T.text, "RIGHT")
  row.craft:SetPoint("RIGHT", row.total, "LEFT", -8, 0)
  row.craft:SetWidth(CRAFT_W)
  row.each = text(row, T.font, T.text, "RIGHT")
  row.each:SetPoint("RIGHT", row.craft, "LEFT", -8, 0)
  row.each:SetWidth(EACH_W)
  row.qty = text(row, T.font, T.text, "RIGHT")
  row.qty:SetPoint("RIGHT", row.each, "LEFT", -8, 0)
  row.qty:SetWidth(QTY_W)
  row.icon = row:CreateTexture(nil, "ARTWORK")
  row.icon:SetSize(16, 16)
  row.icon:SetPoint("LEFT", DATE_W, 0)
  row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  row.name = text(row, T.font)
  row.name:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
  row.name:SetPoint("RIGHT", row.qty, "LEFT", -8, 0)
  row:SetScript("OnClick", function(self)
    local e = self.entry
    if not e then return end
    if IsShiftKeyDown() and chatOpen() then
      local link = e.link
      if not link and e.id then
        local okInfo, _, l = pcall(C_Item.GetItemInfo, e.id)
        link = okInfo and l or nil
      end
      if link and ChatEdit_InsertLink then ChatEdit_InsertLink(link) end
      return
    end
    if B.mode ~= "income" then toggleMark(e) end
  end)
  row:SetScript("OnEnter", function(self) self.hover = true; paintRow(self); rowTooltip(self) end)
  row:SetScript("OnLeave", function(self) self.hover = nil; paintRow(self); GameTooltip:Hide() end)
  return row
end

local function makeMatRow(parent)
  local row = CreateFrame("Frame", nil, parent)
  row:SetHeight(ROW)
  row:EnableMouse(true)
  row.icon = row:CreateTexture(nil, "ARTWORK")
  row.icon:SetSize(16, 16)
  row.icon:SetPoint("LEFT", 0, 0)
  row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  row.cost = text(row, T.font, T.text, "RIGHT")
  row.cost:SetPoint("RIGHT", 0, 0)
  row.cost:SetWidth(TOTAL_W)
  row.src = text(row, T.font - 1, T.muted, "RIGHT")
  row.src:SetPoint("RIGHT", row.cost, "LEFT", -8, 0)
  row.src:SetWidth(220)
  row.name = text(row, T.font)
  row.name:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
  row.name:SetPoint("RIGHT", row.src, "LEFT", -8, 0)
  row:SetScript("OnEnter", function(self)
    if not self.id then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    pcall(GameTooltip.SetItemByID, GameTooltip, self.id)
    GameTooltip:Show()
  end)
  row:SetScript("OnLeave", function() GameTooltip:Hide() end)
  return row
end

local function makeLine(parent)
  local line = CreateFrame("Frame", nil, parent)
  line:SetHeight(ROW)
  line.label = text(line, T.font, T.muted)
  line.label:SetPoint("LEFT", 0, 0)
  line.value = text(line, T.font, T.text, "RIGHT")
  line.value:SetPoint("RIGHT", 0, 0)
  line.label:SetPoint("RIGHT", line.value, "LEFT", -8, 0)
  return line
end

-- the recipe picker: the recipes you looked at in a profession window, newest first
local function openPicker(anchor)
  local f = B.frame
  local m = B.picker
  if not m then
    m = CreateFrame("Frame", nil, f)
    m:SetFrameLevel(f:GetFrameLevel() + 30)
    m:EnableMouse(true)
    m.fill, m.edge = U.RoundBox(m, 6, T.bg, T.border)
    m.fill:SetVertexColor(T.bg[1], T.bg[2], T.bg[3], 1)
    m.items = {}
    B.picker = m
  end
  if m:IsShown() then m:Hide(); return end
  local rs = recipes()
  for i = 1, math.max(#rs, #m.items) do
    local r, b = rs[i], m.items[i]
    if r then
      if not b then
        b = CreateFrame("Button", nil, m)
        b:SetHeight(22)
        b.hl = U.Round(b, 4, "BACKGROUND")
        b.hl:SetAllPoints(b)
        b.hl:SetVertexColor(rgba(T.surfaceHi))
        b.hl:Hide()
        b.label = text(b, T.font)
        b.label:SetPoint("LEFT", 8, 0)
        b.label:SetPoint("RIGHT", -8, 0)
        b:SetScript("OnEnter", function(self) self.hl:Show() end)
        b:SetScript("OnLeave", function(self) self.hl:Hide() end)
        m.items[i] = b
      end
      b:ClearAllPoints()
      b:SetPoint("TOPLEFT", 6, -6 - (i - 1) * 22)
      b:SetPoint("RIGHT", -6, 0)
      b.label:SetText(r.name or ("recipe " .. r.id))
      local d = db()
      b.label:SetTextColor(rgba((d and d.boughtRecipe == r.id) and T.accent or T.text))
      b:SetScript("OnClick", function()
        local dd = db()
        if dd then dd.boughtRecipe = r.id end
        m:Hide()
        B.render()
      end)
      b:Show()
    elseif b then
      b:Hide()
    end
  end
  m:SetSize(300, 12 + math.max(1, #rs) * 22)
  m:ClearAllPoints()
  m:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -4)
  m:Show()
end

local function addRows(f, n)
  for i = #f.rows + 1, n do
    local row = makeRow(f.list)
    row:SetPoint("TOPLEFT", PAD, -(32 + (i - 1) * ROW))
    row:SetPoint("RIGHT", -PAD, 0)
    f.rows[i] = row
  end
end

local function makeFrame()
  if B.frame then return B.frame end
  if not EUI then return nil end
  T = EUI.MakeTheme(ns.T and ns.T.accent or { 1, 0.82, 0 })
  local f = CreateFrame("Frame", "EverlookAuctionsPurchases", UIParent)
  f.eluiTheme = T
  UI.own(f)
  f:SetWidth(W)
  f:SetFrameStrata("HIGH")
  f:SetToplevel(true)
  f:SetClampedToScreen(true)
  f:EnableMouse(true)
  f:SetMovable(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local d = db()
    if d then
      local p, _, rp, x, y = self:GetPoint()
      d.boughtPos = { p, rp, x, y }
    end
  end)
  f:EnableMouseWheel(true)
  f:SetScript("OnMouseWheel", function(_, delta)
    B.offset = math.max(0, (B.offset or 0) - delta * 3)
    B.render()
  end)
  EUI.WindowChrome(f, T)
  EUI.CloseButton(f, T)
  if UISpecialFrames then tinsert(UISpecialFrames, "EverlookAuctionsPurchases") end   -- Escape closes it, like the Prices window

  -- header: icon, title, the two views, the settings
  f.icon = f:CreateTexture(nil, "ARTWORK")
  f.icon:SetSize(18, 18)
  f.icon:SetPoint("TOPLEFT", 20, -20)
  if EUI.SetIcon(f.icon, "coins") then f.icon:SetVertexColor(rgba(T.accent)) end
  f.title = text(f, T.fontHuge, T.text)
  f.title:SetPoint("LEFT", f.icon, "RIGHT", 8, 0)
  f.title:SetText("AH log")
  f.tabs = {}
  local prev
  for _, t in ipairs({ { "bought", "Bought" }, { "forsale", "For sale", "Sale" }, { "income", "Income" }, { "looted", "Looted", "Loot" } }) do
    local b = CreateFrame("Button", nil, f)
    b:SetSize(84, 26)
    if prev then b:SetPoint("LEFT", prev, "RIGHT", 4, 0) else b:SetPoint("LEFT", f.title, "RIGHT", 18, 0) end
    b.bg = U.Round(b, 4, "BACKGROUND")
    b.bg:SetAllPoints(b)
    b.label = text(b, T.font, T.text, "CENTER")
    b.label:SetPoint("CENTER")
    b.label:SetText(t[2])
    b.bar = U.Solid(b, "ARTWORK", rgba(T.accent))
    b.bar:SetHeight(2)
    b.bar:SetPoint("BOTTOMLEFT", 10, 0)
    b.bar:SetPoint("BOTTOMRIGHT", -10, 0)
    b.mode = t[1]
    b.full, b.short = t[2], t[3] or t[2]
    b:SetScript("OnClick", function()
      B.mode, B.offset = t[1], 0
      if B.picker then B.picker:Hide() end
      B.render()
    end)
    b:SetScript("OnEnter", function(self) if not self.active then self.bg:SetVertexColor(rgba(T.surface)); self.bg:Show() end end)
    b:SetScript("OnLeave", function(self) if not self.active then self.bg:Hide() end end)
    f.tabs[#f.tabs + 1] = b
    prev = b
  end
  f.gear = CreateFrame("Button", nil, f)
  f.gear:SetSize(24, 24)
  f.gear:SetPoint("TOPRIGHT", -38, -10)
  f.gear.icon = f.gear:CreateTexture(nil, "ARTWORK")
  f.gear.icon:SetSize(13, 13)
  f.gear.icon:SetPoint("CENTER")
  EUI.SetIcon(f.gear.icon, "gear")
  f.gear.icon:SetVertexColor(rgba(T.muted))
  f.gear:SetScript("OnClick", function() if ns.app then ns.app:Open("ahlog") end end)
  f.gear:SetScript("OnEnter", function(self)
    self.icon:SetVertexColor(rgba(T.text))
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText("AH log settings", 1, 1, 1)
    GameTooltip:AddLine("Opacity, rows shown, what is logged.", nil, nil, nil, true)
    GameTooltip:Show()
  end)
  f.gear:SetScript("OnLeave", function(self) self.icon:SetVertexColor(rgba(T.muted)); GameTooltip:Hide() end)
  f.sub = text(f, T.font - 1, T.muted)
  f.sub:SetPoint("TOPLEFT", 20, -48)
  f.sub:SetPoint("RIGHT", -20, 0)

  -- toolbar: search, marked only, clear marks
  f.search = EUI.EditBox(f, 220, 26)
  f.search:SetPoint("TOPLEFT", 20, -68)
  f.search.hint = text(f.search, T.font, T.muted)
  f.search.hint:SetPoint("LEFT", 8, 0)
  f.search.hint:SetText("Search items")
  f.search:HookScript("OnTextChanged", function(self)
    local t = self:GetText() or ""
    self.hint:SetShown(t == "")
    B.filter = t
    B.offset = 0
    B.render()
  end)
  f.marked = chip(f, "Marked only", function(self)
    B.markedOnly = not B.markedOnly
    self:SetOn(B.markedOnly)
    B.offset = 0
    B.render()
  end)
  f.marked:SetPoint("LEFT", f.search, "RIGHT", 8, 0)
  f.marked:SetOn(false)
  f.clear = EUI.Button(f, "Clear marks", function()
    for _, e in ipairs(list()) do e.m = nil end
    B.render()
  end, 110)
  f.clear:SetHeight(24)
  f.clear:SetPoint("TOPRIGHT", -20, -69)

  -- the list card: column heads, rows, then the sum and where you are
  f.list = card(f)
  f.list:SetPoint("TOPLEFT", 16, -104)
  f.list:SetPoint("RIGHT", -16, 0)
  local head = CreateFrame("Frame", nil, f.list)
  head:SetHeight(16)
  head:SetPoint("TOPLEFT", PAD, -10)
  head:SetPoint("RIGHT", -PAD, 0)
  local function col(label, right, width, justify)
    local h = text(head, T.fontSmall, T.muted, justify or "RIGHT")
    h:SetText(label)
    h:SetPoint("RIGHT", right, 0)
    h:SetWidth(width)
    return h
  end
  f.totalHead = col("TOTAL", 0, TOTAL_W)
  f.craftHead = col("CRAFT NOW, EACH", -(TOTAL_W + 8), CRAFT_W)
  -- EACH and QTY move right in Bought, where there is no craft column, so names get the room
  f.eachHead = col("EACH", -(TOTAL_W + CRAFT_W + 16), EACH_W)
  f.qtyHead = col("QTY", -(TOTAL_W + CRAFT_W + EACH_W + 24), QTY_W)
  local hd = text(head, T.fontSmall, T.muted)
  hd:SetPoint("LEFT", 16, 0)
  hd:SetText("WHEN")
  f.headWhen = hd
  local hi = text(head, T.fontSmall, T.muted)
  hi:SetPoint("LEFT", DATE_W, 0)
  hi:SetText("ITEM")
  f.headItem = hi
  f.rows = {}
  f.empty = text(f.list, T.font, T.muted)
  f.empty:SetWordWrap(true)
  f.empty:SetPoint("TOPLEFT", PAD, -34)
  f.empty:SetPoint("RIGHT", -PAD, 0)
  f.foot = U.Solid(f.list, "ARTWORK", rgba(T.divider))
  f.foot:SetHeight(1)
  f.sum = text(f.list, T.font, T.text)
  f.pos = text(f.list, T.font - 1, T.muted, "RIGHT")

  -- the recipe card
  f.recipe = card(f)
  f.recipe:SetPoint("RIGHT", -16, 0)
  f.recipeLabel = text(f.recipe, T.fontTitle, T.gold)
  f.recipeLabel:SetPoint("TOPLEFT", PAD, -14)
  f.recipeLabel:SetText("Recipe")
  f.pick = EUI.Button(f.recipe, "Pick a recipe", function(self) openPicker(self) end, 320)
  f.pick:SetPoint("TOPLEFT", PAD + 70, -9)
  f.pick.chev = f.pick:CreateTexture(nil, "ARTWORK")
  f.pick.chev:SetSize(10, 10)
  f.pick.chev:SetPoint("RIGHT", -10, 0)
  if EUI.SetIcon(f.pick.chev, "chevron") then f.pick.chev:SetVertexColor(rgba(T.muted)) end
  tipFor(f.pick, "Recipe", "The recipes you picked in a profession window. Or shift-click a recipe, or an item you can craft, while this window is open.")
  f.mats, f.lines = {}, {}
  for i = 1, REC_ROWS do f.mats[i] = makeMatRow(f.recipe) end
  for i = 1, 4 do f.lines[i] = makeLine(f.recipe) end
  f.note = text(f.recipe, T.font - 1, T.muted)
  f.note:SetWordWrap(true)
  f.note:SetWidth(W - 32 - PAD * 2)

  -- the corner grip: drag for width (narrow, normal, wide layouts) and rows
  f.grip = CreateFrame("Button", nil, f)
  f.grip:SetSize(16, 16)
  f.grip:SetPoint("BOTTOMRIGHT", -4, 4)
  f.grip:SetFrameLevel(f:GetFrameLevel() + 20)
  f.grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
  f.grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
  f.grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
  f.grip:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText("Resize", 1, 1, 1)
    GameTooltip:AddLine("Narrower shows only the essentials, wider shows more. Taller shows more rows.", nil, nil, nil, true)
    GameTooltip:Show()
  end)
  f.grip:SetScript("OnLeave", function() GameTooltip:Hide() end)
  f.grip:SetScript("OnMouseDown", function()
    local s = f:GetEffectiveScale()
    local x, y = GetCursorPosition()
    -- the top left corner stays put while you drag
    local left, top = f:GetLeft(), f:GetTop()
    if left and top then
      f:ClearAllPoints()
      f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
    end
    f.sizing = { x = x / s, y = y / s, w = width(), rows = rows() }
    GameTooltip:Hide()
  end)
  f.grip:SetScript("OnMouseUp", function()
    f.sizing = nil
    local d = db()
    if d and f:GetLeft() then d.boughtPos = { "TOPLEFT", "BOTTOMLEFT", f:GetLeft(), f:GetTop() } end
  end)
  f.grip:SetScript("OnUpdate", function()
    local z = f.sizing
    if not z then return end
    if not IsMouseButtonDown("LeftButton") then f.grip:GetScript("OnMouseUp")(); return end
    local s = f:GetEffectiveScale()
    local x, y = GetCursorPosition()
    local w = math.max(MIN_W, math.min(MAX_W, math.floor(z.w + x / s - z.x)))
    local n = math.max(MIN_ROWS, math.min(MAX_ROWS, z.rows + math.floor((z.y - y / s) / ROW + 0.5)))
    local d = db()
    if d and (w ~= width() or n ~= rows()) then
      d.logW, d.logRows = w, n
      B.render()
    end
  end)

  f:SetScript("OnShow", function() end)
  EUI.CloseOnEscape(f)
  f:HookScript("OnHide", function() if B.picker then B.picker:Hide() end end)

  local d = db()
  local pos = d and d.boughtPos
  if pos then f:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4]) else f:SetPoint("CENTER", 0, 60) end
  f:Hide()
  B.frame = f
  return f
end

-- the window's opacity (a setting): the window and its cards
local function paintAlpha(f)
  local a = alpha()
  f.bgFill:SetVertexColor(T.bg[1], T.bg[2], T.bg[3], a)
  f.bgEdge:SetVertexColor(T.border[1], T.border[2], T.border[3], math.min(1, a + 0.1))
  for _, c in ipairs({ f.list, f.recipe }) do
    c.fill:SetVertexColor(T.card[1], T.card[2], T.card[3], a)
    c.edge:SetVertexColor(T.divider[1], T.divider[2], T.divider[3], a)
  end
end

local function renderList(f)
  local income = B.mode == "income"
  local sale = B.mode == "forsale"
  local looted = B.mode == "looted"
  local side = income or sale or looted   -- the layout with the third money column, no marks
  local all = income and incomeList() or (sale and (B.forSale().list or {})) or (looted and B.looted()) or list()
  local shown = P.view(all, B.filter, B.markedOnly and not side,
    looted and function(e) return entryName(e) .. " " .. (e.from or "") .. " " .. (e.how or "") .. " " .. (e.zone or "") end or entryName)
  if sale then
    -- what runs out first, first
    table.sort(shown, function(x, y) return (x.ends or math.huge) < (y.ends or math.huge) end)
  end
  -- sales waiting in the mail go on top, newest first
  if income then
    local waiting = P.view(B.pending(), B.filter, false, entryName)
    for i = #waiting, 1, -1 do table.insert(shown, 1, waiting[i]) end
  end
  local n = rows()
  addRows(f, n)
  local maxOff = math.max(0, #shown - n)
  B.offset = math.min(B.offset or 0, maxOff)
  for i, row in ipairs(f.rows) do
    local e = i <= n and shown[i + B.offset] or nil
    row.entry = e
    if e then
      row.check:SetShown(not side and e.m == true)
      local L = B.lay or layoutNow()
      if not L.fullDate then
        -- today: the time; before: the day
        row.date:SetText(date("%d %b", e.t) == date("%d %b") and date("%H:%M", e.t) or date("%d %b", e.t))
      else
        row.date:SetText(date("%d %b %H:%M", e.t))
      end
      if sale then row.date:SetText(not L.fullDate and (B.leftText(e):match("^(%S+)") or "") or B.leftText(e)) end
      row.date:SetWidth(L.dateW - 16)
      row.icon:ClearAllPoints()
      row.icon:SetPoint("LEFT", L.dateW, 0)
      row.craft:SetWidth(L.craftW)
      row.craft:SetJustifyH((looted and L.wide) and "LEFT" or "RIGHT")
      local id = income and saleID(e) or e.id
      row.icon:SetTexture(id and try(C_Item.GetItemIconByID, id) or ((e.copper or (e.kind and e.kind ~= "sale")) and 133784) or 134400)
      row.name:SetText(entryName(e))
      row.name:SetTextColor(qualityColor(id))
      -- a sold item you can craft: what one costs to make again today, green when you sold above it
      local cost = ((income and e.kind == "sale") or (sale and e.c)) and craftNow(id)
      local q = math.max(1, tonumber(e.q) or 1)
      if cost then setMoney(row.craft, cost, math.floor(e.c / q + 0.5) >= cost and T.ok or T.danger) else row.craft:SetText("") end
      row.each:ClearAllPoints()
      row.each:SetPoint("RIGHT", side and row.craft or row.total, "LEFT", (looted and L.wide) and -24 or -8, 0)
      row.craft:SetShown((side and not L.compact) and true or false)
      row.each:SetShown(not L.compact)
      row.qty:ClearAllPoints()
      row.qty:SetPoint("RIGHT", L.compact and row.total or row.each, "LEFT", -8, 0)
      if e.pending then row.date:SetTextColor(rgba(T.accent)) else row.date:SetTextColor(rgba(T.muted)) end
      row.qty:SetText(e.q and ns.num(e.q) or "")
      row.total:SetWidth(L.totalW)
      row.qty:SetShown(not L.mini)
      row.qty:SetWidth(L.mini and 1 or QTY_W)
      if not L.qty and e.q and tonumber(e.q) and tonumber(e.q) > 1 then
        row.name:SetText(entryName(e) .. " |cff8a93a0x" .. ns.num(e.q) .. "|r")
      end
      if looted then
        -- where it dropped, then what it is worth today (the last scan, else a vendor)
        -- where it came from (a mob, a node, a container); the zone when that isn't known
        if e.from or e.how then row.craft:SetText(e.from or e.how); row.craft:SetTextColor(rgba(T.text)) else quiet(row.craft, e.zone and ("in " .. e.zone) or "") end
        if e.copper then
          quiet(row.each, ""); setMoney(row.total, e.copper, T.accent)
        else
          local each = ns.lootCards and ns.lootCards.worth(e.id)
          if each then setMoney(row.each, each); setMoney(row.total, each * q) else quiet(row.each, ""); quiet(row.total, "") end
        end
      elseif sale and not e.c then
        quiet(row.each, ""); quiet(row.total, "bids only")
      elseif e.pending then
        -- not taken yet: what it likely brings, in grey ("~"), or "in mail" with no guess
        quiet(row.craft, "in your mail")
        if e.est then
          row.each:SetText("~" .. money(math.floor(e.est / q + 0.5))); row.each:SetTextColor(rgba(T.muted))
          row.total:SetText("~" .. money(e.est)); row.total:SetTextColor(rgba(T.muted))
        else
          quiet(row.each, ""); quiet(row.total, "")
        end
      else
        setMoney(row.each, math.floor(e.c / q + 0.5))
        setMoney(row.total, e.c)
      end
      B.placeRow(row, L)
      paintRow(row)
      row:Show()
    else
      row:Hide()
    end
  end
  f.empty:SetShown(#shown == 0)
  if #all == 0 and looted then
    f.empty:SetText("Nothing looted yet on this character. From now on every item and coin you pick up shows here, with when and where.")
  elseif #all == 0 and sale then
    f.empty:SetText(B.forSale().at and "Nothing of yours was up for sale on your last visit to the auction house."
      or "Visit the auction house once on this character and your auctions show here, with how long each has left. Sales after that move to Income (in your mail).")
  elseif #all == 0 and income then
    f.empty:SetText("No money from the mail yet. From now on, gold you take from the mail shows up here: every auction you sold (item, how many, what you got after the cut) and any other gold. A sold item you can craft shows what one costs to craft again at today's prices (open your profession window once so the addon knows your recipes).")
  elseif #all == 0 then
    f.empty:SetText("Nothing bought yet. Every buyout from now on shows up here: from our Buy panel, Blizzard's auction house or another addon. Bids aren't logged.")
  elseif B.markedOnly and not side then
    f.empty:SetText("Nothing marked" .. ((B.filter or "") ~= "" and " matches." or ". Turn off Marked only and click the purchases you crafted with."))
  else
    f.empty:SetText("Nothing matches.")
  end
  -- the card's foot, under the last row slot
  local bottom = 32 + n * ROW + 8
  f.foot:ClearAllPoints()
  f.foot:SetPoint("TOPLEFT", PAD, -bottom)
  f.foot:SetPoint("TOPRIGHT", -PAD, -bottom)
  f.sum:ClearAllPoints()
  f.sum:SetPoint("TOPLEFT", PAD, -(bottom + 10))
  f.pos:ClearAllPoints()
  f.pos:SetPoint("TOPRIGHT", -PAD, -(bottom + 10))
  f.list:SetHeight(bottom + 32)
  f.pos:SetText(#shown > n and ("%d-%d of %d, scroll for more"):format(B.offset + 1, math.min(#shown, B.offset + n), #shown)
    or (#shown > 0 and ("%d %s"):format(#shown, income and "entries" or (sale and "auctions") or (looted and "loots") or "purchases") or ""))
  if looted then
    local n, worth, coins = B.lootToday()
    if B.lay and B.lay.mini then
      -- one number: what the items are worth plus the money, without copper once it is gold
      local all = worth + coins
      f.sum:SetText(("Today: %d items, ~%s"):format(n, money(all >= 10000 and math.floor(all / 100) * 100 or all)))
    else
      f.sum:SetText(("Today: %d items, worth about %s, and %s in money"):format(n, money(worth), money(coins)))
    end
    f.sum:SetTextColor(rgba(T.text))
    return
  end
  if sale then
    local worth, n = 0, 0
    for _, e in ipairs(all) do n = n + 1; worth = worth + (e.c or 0) end
    f.sum:SetText(n > 0 and (((B.lay and B.lay.mini) and "%d up, %s if all sell" or "Up for sale: %d auctions, %s if all sell (before the 5%% cut)")):format(n, money(worth)) or "")
    f.sum:SetTextColor(rgba(T.text))
    return
  end
  if income then
    local since = time() - 7 * 86400
    local earned, spent = P.sum(all, since), P.sum(list(), since)
    local net = earned - spent
    local np, cp = P.pendingTotal(B.pending())
    if B.lay and B.lay.mini then
      f.sum:SetText(("7 days: net %s%s"):format(net < 0 and "-" or "", money(math.abs(net))))
    else
      f.sum:SetText(("Last 7 days: earned %s, spent %s, net %s%s"):format(money(earned), money(spent),
        net < 0 and "-" or "", money(math.abs(net))))
    end
    if np > 0 then
      f.sub:SetText(("%d sold, money waiting in your mail%s. Below: gold you took from the mail."):format(np,
        cp > 0 and (" (about " .. money(cp) .. ")") or ""))
    end
    f.sum:SetTextColor(rgba(net >= 0 and T.ok or T.danger))
    return
  end
  local nm, q, c = P.markedTotal(all)
  if nm > 0 then
    f.sum:SetText((B.lay and B.lay.mini) and ("Marked: %s items, %s"):format(ns.num(q), money(c))
      or ("Marked: %d %s, %s items, %s"):format(nm, nm == 1 and "purchase" or "purchases", ns.num(q), money(c)))
    f.sum:SetTextColor(rgba(T.accent))
  else
    quiet(f.sum, "Nothing marked")
  end
  f.clear:SetUsable(nm > 0)
end

local function renderRecipe(f)
  local d = db() or {}
  local rs = recipes()
  local r = P.findRecipe(rs, d.boughtRecipe) or rs[1]
  local y = -46
  f.pick:SetText(r and ((r.name or ("recipe " .. r.id))) or "Pick a recipe")
  f.pick:SetUsable(#rs > 0)
  local c = r and P.cost(list(), r, priceOf)
  for i, row in ipairs(f.mats) do
    local m = c and c.mats[i]
    row:SetShown(m ~= nil)
    row.id = m and m.id
    if m then
      row:ClearAllPoints()
      row:SetPoint("TOPLEFT", PAD, y)
      row:SetPoint("RIGHT", -PAD, 0)
      row.icon:SetTexture(try(C_Item.GetItemIconByID, m.id) or 134400)
      row.name:SetText(("%s  x%s"):format(itemName(m.id), m.need))
      row.name:SetTextColor(qualityColor(m.id))
      if m.src == "paid" then
        row.src:SetText(("you paid %s each (%d marked)"):format(money(math.floor(m.unit + 0.5)), m.have))
        row.src:SetTextColor(rgba(T.accent))
        setMoney(row.cost, math.floor(m.unit * m.need + 0.5))
      elseif m.src == "ah" then
        quiet(row.src, "not marked: lowest AH price")
        setMoney(row.cost, math.floor(m.unit * m.need + 0.5), T.muted)
      else
        quiet(row.src, "not marked, no AH price")
        quiet(row.cost, "-")
      end
      y = y - ROW
    end
  end
  local lines = {}
  if c and #c.mats > 0 then
    y = y - 6
    lines[#lines + 1] = { "Cost per craft", c.total, c.paidAll and T.accent or T.text }
    if c.crafts then lines[#lines + 1] = { "Your marked purchases cover", ("%d %s"):format(c.crafts, c.crafts == 1 and "craft" or "crafts") } end
    local each, at = r.out and priceOf(r.out)
    if each then
      local makes = r.makes or 1
      local value = math.floor(each * makes)
      local it = ns.itemFor and ns.itemFor(r.out)
      local sells = it and it.shared and "Sells for (other players' scan)" or "Sells for"
      lines[#lines + 1] = { makes > 1 and ("%s (makes %s)"):format(sells, makes) or sells, value,
        (at and time() - at >= STALE) and T.muted or nil }
      if c.unpriced == 0 then
        local cut = ns.ahCut and ns.ahCut() or 0.05
        local profit = math.floor(value * (1 - cut)) - c.total
        lines[#lines + 1] = { ("Profit after the %d%% AH cut"):format(cut * 100), profit, profit >= 0 and T.ok or T.danger }
      end
    end
  end
  for i, line in ipairs(f.lines) do
    local l = lines[i]
    line:SetShown(l ~= nil)
    if l then
      line:ClearAllPoints()
      line:SetPoint("TOPLEFT", PAD, y)
      line:SetPoint("RIGHT", -PAD, 0)
      line.label:SetText(l[1])
      if type(l[2]) == "number" then setMoney(line.value, l[2], l[3]) else line.value:SetText(l[2]); line.value:SetTextColor(rgba(T.text)) end
      y = y - ROW
    end
  end
  local note
  if not r then
    note = "Pick a recipe in your profession window, or shift-click a recipe or an item you can craft: it shows up here, with its cost per craft."
  elseif c.unpriced > 0 then
    note = "A material with no marked purchase and no AH price isn't counted."
  elseif not c.paidAll then
    note = "Grey materials aren't from your marked purchases: they use the lowest AH price. Mark a purchase of them to use what you paid."
  end
  f.note:SetShown(note ~= nil)
  if note then
    f.note:ClearAllPoints()
    f.note:SetPoint("TOPLEFT", PAD, y - 6)
    f.note:SetText(note)
    y = y - 8 - math.max(12, f.note:GetStringHeight() or 12)
  end
  f.recipe:SetHeight(-y + 12)
end

-- The columns right to left: total, then the ones this width has room for (B.layoutNow). Hidden ones keep a 1 wide
-- place in the chain so the item name always ends before the first shown column.
local CHAIN = { "craft", "each", "qty" }
local function colWidth(L, c) return c == "craft" and L.craftW or c == "each" and EACH_W or QTY_W end
function B.placeRow(row, L)
  row.date:SetWidth(L.dateW - 16)
  row.icon:ClearAllPoints()
  row.icon:SetPoint("LEFT", L.dateW, 0)
  row.total:SetWidth(L.totalW)
  row.craft:SetJustifyH(L.looted and "LEFT" or "RIGHT")
  local prev = row.total
  for _, c in ipairs(CHAIN) do
    local fs = row[c]
    fs:ClearAllPoints()
    if L[c] then
      fs:SetWidth(colWidth(L, c))
      -- a left-aligned FROM needs air after it
      fs:SetPoint("RIGHT", prev, "LEFT", (prev == row.craft and L.looted) and -16 or -8, 0)
      fs:Show()
      prev = fs
    else
      fs:SetWidth(1)
      fs:SetPoint("RIGHT", prev, "LEFT", 0, 0)
      fs:Hide()
    end
  end
end
function B.placeHeads(f, L)
  f.totalHead:SetWidth(L.totalW)
  f.headItem:ClearAllPoints()
  f.headItem:SetPoint("LEFT", L.dateW, 0)
  f.craftHead:SetJustifyH(L.looted and "LEFT" or "RIGHT")
  local heads = { craft = f.craftHead, each = f.eachHead, qty = f.qtyHead }
  local x, afterCraft = L.totalW, false
  for _, c in ipairs(CHAIN) do
    local h = heads[c]
    if L[c] then
      local gap = (afterCraft and L.looted) and 16 or 8
      local cw = colWidth(L, c)
      h:ClearAllPoints()
      h:SetPoint("RIGHT", -(x + gap), 0)
      h:SetWidth(cw)
      h:Show()
      x, afterCraft = x + gap + cw, c == "craft"
    else
      h:Hide()
    end
  end
end

-- How long an auction has left: "5h 20m", "40m", or "ended" (it comes back by mail if it didn't sell).
function B.leftText(e)
  if not e.ends then
    -- only the auction house's band: Short (under 30 minutes), Medium (30 minutes to 2 hours), Long, Very long
    return ({ "Short", "Medium", "Long", "Very long" })[(tonumber(e.band) or -1) + 1] or "?"
  end
  local s = e.ends - time()
  if s <= 0 then return "ended" end
  if s >= 3600 then return ("%dh %02dm"):format(math.floor(s / 3600), math.floor(s % 3600 / 60)) end
  return ("%dm"):format(math.max(1, math.floor(s / 60)))
end

-- What you looted since midnight: items, their worth today, and money.
function B.lootToday()
  local d = date("*t")
  local since = time({ year = d.year, month = d.month, day = d.day, hour = 0 })
  local n, worth, coins = 0, 0, 0
  local list = B.looted()
  for i = #list, 1, -1 do
    local e = list[i]
    if e.t < since then break end
    if e.got then   -- from the mail, a merchant or a trade: not loot
    elseif e.copper then coins = coins + e.copper
    else
      n = n + (e.q or 1)
      local each = ns.lootCards and ns.lootCards.worth(e.id)
      if each then worth = worth + each * (e.q or 1) end
    end
  end
  return n, worth, coins
end

-- The Everlook Bar (or any LibDataBroker display) plugin: today's loot; left-click the loot log, right-click the AH log.
local function setupBroker()
  local LDB = LibStub and LibStub("LibDataBroker-1.1", true)
  if not LDB or B.ldb then return end
  B.ldb = LDB:NewDataObject("EverlookDBAuctionsLog", {
    type = "data source", label = "Loot", text = "", icon = "Interface\\Icons\\INV_Misc_Bag_10",
    OnClick = function(_, button)
      if button == "RightButton" then B.toggle("bought") elseif IsShiftKeyDown() then B.toggle("income") else B.toggle("looted") end
    end,
    OnTooltipShow = function(tip)
      local n, worth, coins = B.lootToday()
      tip:AddLine("Loot today", 1, 0.82, 0)
      tip:AddDoubleLine("Items", ("%d, worth about %s"):format(n, money(worth)), 1, 1, 1, 1, 1, 1)
      tip:AddDoubleLine("Money", money(coins), 1, 1, 1, 1, 1, 1)
      tip:AddDoubleLine("Together", money(worth + coins), 1, 1, 1, 1, 0.82, 0)
      tip:AddLine(" ")
      tip:AddDoubleLine("Click", "loot log", 0.6, 0.6, 0.6, 0.6, 0.6, 0.6)
      tip:AddDoubleLine("Shift-click", "income", 0.6, 0.6, 0.6, 0.6, 0.6, 0.6)
      tip:AddDoubleLine("Right-click", "purchases", 0.6, 0.6, 0.6, 0.6, 0.6, 0.6)
    end,
  })
  B.broker()
end
function B.broker()
  if not B.ldb then return end
  -- the number of items first, so it doesn't read like the Gold plugin
  local n, worth, coins = B.lootToday()
  B.ldb.text = ("%d |cff9aa3ad·|r %s"):format(n, money(worth + coins))
end
local brokerEv = CreateFrame("Frame")
brokerEv:RegisterEvent("PLAYER_LOGIN")
brokerEv:SetScript("OnEvent", function() setupBroker() end)

function B.render()
  local f = B.frame
  if not (f and f:IsShown()) then return end
  paintAlpha(f)
  local income = B.mode == "income"
  local sale = B.mode == "forsale"
  local looted = B.mode == "looted"
  local side = income or sale or looted
  for _, b in ipairs(f.tabs) do
    local on = b.mode == (B.mode or "bought")
    b.active = on
    b.bar:SetShown(on)
    b.bg:SetVertexColor(rgba(T.accentDim))
    b.bg:SetShown(on)
    b.label:SetTextColor(rgba(on and T.accent or T.muted))
  end
  local fs = B.forSale()
  f.sub:SetText(looted and "Everything you picked up on this character, newest first: where it came from, and what it is worth today."
    or income and "Gold you took from the mail. Hover a sale for its margin over crafting it again."
    or sale and (fs.at and ("Your auctions as the auction house showed them on %s. Sales since then move to Income."):format(date("%d %b %H:%M", fs.at))
      or "Your auctions, read on every visit to the auction house.")
    or "Everything you bought at the auction house. Click the purchases you crafted with to mark them.")
  local L = layoutNow()
  B.lay = L
  f:SetWidth(L.w)
  f.sub:SetShown(not L.compact)
  f.search:ClearAllPoints()
  f.search:SetPoint("TOPLEFT", 20, L.compact and -48 or -68)
  f.search:SetWidth(L.mini and (side and (L.w - 40) or 140) or (L.compact and 150 or 220))
  f.clear:ClearAllPoints()
  f.clear:SetPoint("TOPRIGHT", -20, L.compact and -49 or -69)
  f.list:ClearAllPoints()
  f.list:SetPoint("TOPLEFT", 16, -L.top)
  f.list:SetPoint("RIGHT", -16, 0)
  -- narrow: smaller tabs closer together, so the gear and close button keep their room
  f.title:SetShown(not L.mini)
  for i, b in ipairs(f.tabs) do
    b:SetWidth(L.mini and 54 or (L.compact and 62 or 84))
    b.label:SetText(L.mini and b.short or b.full)
    b:ClearAllPoints()
    if i == 1 then
      if L.mini then b:SetPoint("LEFT", f.icon, "RIGHT", 8, 0) else b:SetPoint("LEFT", f.title, "RIGHT", L.compact and 10 or 18, 0) end
    else b:SetPoint("LEFT", f.tabs[i - 1], "RIGHT", L.compact and 2 or 4, 0) end
  end
  f.totalHead:SetWidth(L.totalW)
  f.qtyHead:SetShown(not L.mini)
  f.pick:SetWidth(math.min(320, L.w - 32 - PAD * 2 - 70))
  f.note:SetWidth(L.w - 32 - PAD * 2)
  for _, m in ipairs(f.mats) do m.src:SetWidth(L.mini and 1 or (L.compact and 110 or 220)); m.src:SetAlpha(L.mini and 0 or 1); m.cost:SetWidth(L.totalW) end
  f.headItem:ClearAllPoints()
  f.headItem:SetPoint("LEFT", L.dateW, 0)
  f.craftHead:SetWidth(L.craftW)
  f.craftHead:SetJustifyH((looted and L.wide) and "LEFT" or "RIGHT")
  f.craftHead:SetShown(side and not L.compact)
  f.eachHead:SetShown(not L.compact)
  local shift = side and 0 or (L.craftW + 8)
  local gap = (looted and L.wide) and 16 or 0   -- the left-aligned FROM column needs air after EACH
  f.eachHead:SetPoint("RIGHT", -(TOTAL_W + L.craftW + 16 + gap) + shift, 0)
  f.qtyHead:SetPoint("RIGHT", L.compact and -(TOTAL_W + 8) or (-(TOTAL_W + L.craftW + EACH_W + 24 + gap) + shift), 0)
  for _, w in ipairs({ f.marked, f.clear, f.recipe }) do w:SetShown(not side) end
  if L.mini then f.clear:Hide() end
  B.placeHeads(f, L)
  f.headWhen:SetText(sale and (L.fullDate and "TIME LEFT" or "LEFT") or "WHEN")
  f.craftHead:SetText(looted and "FROM" or "CRAFT NOW, EACH")
  renderList(f)
  local listH = f.list:GetHeight() or 0
  if side then
    if B.picker then B.picker:Hide() end
    f:SetHeight(L.top + listH + 16)
    f.pos:SetShown(not L.compact)
    return
  end
  renderRecipe(f)
  f.recipe:ClearAllPoints()
  f.recipe:SetPoint("TOPLEFT", f.list, "BOTTOMLEFT", 0, -10)
  f.recipe:SetPoint("RIGHT", -16, 0)
  f.pos:SetShown(not L.compact)
  f:SetHeight(L.top + listH + 10 + (f.recipe:GetHeight() or 0) + 16)
end

function B.open(recipeID)
  local f = makeFrame()
  if not f then
    if ns.say then ns.say("the AH log needs the EverlookUI library, which didn't load.") end
    return
  end
  local d = db()
  if recipeID then B.mode = "bought" end
  if recipeID and d then d.boughtRecipe = recipeID end
  f:Show()
  B.render()
end

function B.toggle(mode)
  local f = makeFrame()
  if not f then return B.open() end
  if f:IsShown() and (mode or "bought") == (B.mode or "bought") then f:Hide(); return end
  B.mode = mode or "bought"
  B.open()
end

-- A setting changed (opacity, rows): the open window follows.
function B.refresh() if B.frame and B.frame:IsShown() then B.render() end end

-- The crafting box tells us each recipe you pick, so the window can show it later without the profession window.
function B.noteRecipe(w, changed)
  local d = db()
  if not d then return end
  P.noteRecipe(recipes(), w)
  if changed then d.boughtRecipe = w.recipeID end
  if B.frame and B.frame:IsShown() then B.render() end
end

ns.purchases = B
