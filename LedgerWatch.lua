-- EverlookDB Auctions: feeds the income ledger (Ledger.lua) from the game.
--   Posting: hooks on C_AuctionHouse.PostItem / PostCommodity / ConfirmPost* (whatever window posts: Quick sell,
--     Blizzard's Sell tab, another addon), one record per AUCTION_HOUSE_AUCTION_CREATED, the deposit from the auction
--     house's own calculation (or the money it took).
--   Outcomes: AUCTION_CANCELED after a CancelAuction call, the sale notification (Celebrate.lua passes its auction id),
--     the owned-auctions list (Purchases.noteOwned, every visit), and the mail: a scan at MAIL_SHOW / MAIL_INBOX_UPDATE
--     ties each auction house mail to its record; taking money or items (TakeInboxMoney, TakeInboxItem,
--     AutoLootMailItem: Blizzard's Open All, a click, EverlookDB Mail or any mail addon) ticks it off.
--   Other money: CHAT_MSG_MONEY (looted coins, through LootCards.lua and Purchases.noteLoot), money gained while a
--     merchant window is open (vendor sales), QUEST_TURNED_IN's money.
-- Every game read is in pcall. db.logIncome = false (Settings > Logging) stops it all.
local _, ns = ...
local L = ns.ledger
local W = {}
L.watch = W

local AH = C_AuctionHouse or {}

function L.classifier() return (LibStub and LibStub("EverlookMailClassify-1", true)) end

local function okv(v)
  if v == nil or (issecretvalue and issecretvalue(v)) then return nil end
  return v
end
local function try(fn, ...)
  if type(fn) ~= "function" then return nil end
  local okCall, a, b, c = pcall(fn, ...)
  if okCall then return okv(a), okv(b), okv(c) end
end

local function db() return ns.db and ns.db() end
function L.get()
  local d = db()
  if not d or d.logIncome == false then return nil end
  return L.store(d)
end
local function charDB()
  EverlookAuctionsCharDB = EverlookAuctionsCharDB or {}
  return EverlookAuctionsCharDB
end

local me = {}   -- this character: ch (fingerprint of the GUID), fp (fingerprint of the name)
function L.ch()
  if me.ch then return me.ch end
  local C = L.classifier()
  local g = try(UnitGUID, "player")
  if C and type(g) == "string" and g ~= "" then me.ch = "c" .. C.hash(g) end
  return me.ch
end
local function house() return ns.house and ns.house() end

-- Your own characters, known by a fingerprint of their names (each one adds itself when it logs in), and EverlookDB
-- Mail's alt list when it is loaded.
function L.isAlt(name)
  if type(name) ~= "string" or name == "" then return false end
  local mail = rawget(_G, "EverlookDBMailAPI")
  if type(mail) == "table" and type(mail.isAlt) == "function" then
    local okA, yes = pcall(mail.isAlt, name)
    if okA and yes then return true end
  end
  local s, C = L.get(), L.classifier()
  local short = C and C.shortName(name)
  return (s and C and short and s.alts[C.hash(short)] and short ~= me.name) and true or false
end

local function refresh()
  if ns.purchases and ns.purchases.refresh then pcall(ns.purchases.refresh) end
end

---------------------------------------------------------------------------------------------------------------------
-- Posting

local posting   -- { item, name, link, dur, left (auctions still to come), q, unit, bid, buy, dep, money, at }

local function itemOf(loc)
  if not loc or not C_Item then return nil end
  local id = try(C_Item.GetItemID, loc)
  local link = try(C_Item.GetItemLink, loc)
  local name = try(C_Item.GetItemName, loc) or (type(link) == "string" and link:match("%[(.-)%]")) or (id and try(C_Item.GetItemNameByID, id))
  return id, name, link
end

local function startPost(commodity, loc, dur, qty, bid, price)
  if not L.get() then return end
  local id, name, link = itemOf(loc)
  qty = tonumber(okv(qty)) or 1
  dur = tonumber(okv(dur))
  local dep
  if commodity then dep = id and try(AH.CalculateCommodityDeposit, id, dur, qty)
  else dep = try(AH.CalculateItemDeposit, loc, dur, qty) end
  price, bid = tonumber(okv(price)), tonumber(okv(bid))
  posting = { item = id, name = name, dur = dur, at = GetTime and GetTime() or 0, money = try(GetMoney),
    dep = tonumber(dep) }
  -- only a link that says more than the id (random stats: "of the Bear")
  if type(link) == "string" and link:match("|Hitem:%d+:[^|]*[1-9]") then posting.link = link:match("|c%x+|Hitem:.-|h|r") or link end
  if commodity then
    posting.left, posting.q, posting.unit = 1, qty, price
    posting.buy = price and price * qty or nil
  else
    -- one auction per item (Blizzard's Sell tab and Quick sell alike); the buyout is per auction
    posting.left, posting.q, posting.unit, posting.buy, posting.bid = qty, 1, price, price, bid
    if posting.dep and qty > 1 then posting.dep = math.floor(posting.dep / qty + 0.5) end
  end
end
W.startPost = startPost

for _, fn in ipairs({ "PostItem", "ConfirmPostItem" }) do
  if type(AH[fn]) == "function" then
    hooksecurefunc(AH, fn, function(loc, dur, qty, bid, buyout) pcall(startPost, false, loc, dur, qty, bid, buyout) end)
  end
end
for _, fn in ipairs({ "PostCommodity", "ConfirmPostCommodity" }) do
  if type(AH[fn]) == "function" then
    hooksecurefunc(AH, fn, function(loc, dur, qty, unit) pcall(startPost, true, loc, dur, qty, nil, unit) end)
  end
end

local function created(aid)
  local p = posting
  local s = L.get()
  if not (p and s) then return end
  if GetTime and GetTime() - (p.at or 0) > 60 then posting = nil; return end
  local dep = p.dep
  if not dep and p.money then
    local now = try(GetMoney)
    if now and p.money - now > 0 then dep = p.money - now end
  end
  L.post(s, { item = p.item, name = p.name, link = p.link, q = p.q, unit = p.unit, bid = p.bid, buy = p.buy,
    dur = p.dur, dep = dep, aid = okv(aid), ch = L.ch(), h = house() })
  p.left = (p.left or 1) - 1
  if p.left <= 0 then posting = nil end
  refresh()
end
W.created = created

-- Cancelling: the id asked for, then the auction house's answer.
local cancelAsk
if type(AH.CancelAuction) == "function" then
  hooksecurefunc(AH, "CancelAuction", function(aid) cancelAsk = { aid = okv(aid), at = GetTime and GetTime() or 0 } end)
end
local function cancelled(aid)
  local s = L.get()
  if not s then return end
  aid = okv(aid)
  if (not aid or aid == 0) and cancelAsk and GetTime and GetTime() - cancelAsk.at < 30 then aid = cancelAsk.aid end
  cancelAsk = nil
  if aid then L.cancelled(s, { aid = aid, ch = L.ch(), h = house() }) end
  refresh()
end
W.cancelled = cancelled

-- A sale the game told about (Celebrate.lua): by auction id when the notification has one, else by name.
function W.sold(name, est, count, aid)
  local s = L.get()
  if not s then return nil end
  local id
  if type(name) == "string" and name ~= "" and name ~= "An auction" then
    local okId, x = pcall(C_Item.GetItemInfoInstant, name)
    id = okId and type(x) == "number" and x or nil
  else
    name = nil
  end
  local r = L.sold(s, { aid = okv(aid), name = name, item = id, est = est, q = count, ch = L.ch(), h = house(),
    cut = ns.ahCut and ns.ahCut() or 0.05 })
  refresh()
  return r
end

-- Your auctions as the auction house listed them (Purchases.noteOwned, from Sell.lua's readOwned).
function W.owned(owned)
  local s = L.get()
  if not s then return end
  L.reconcile(s, owned, L.ch(), house())
end

---------------------------------------------------------------------------------------------------------------------
-- Mail

-- buyer names go to this character's own file, never the account file
local function keepBuyer(r)
  if r and r.buyer then
    local c = charDB()
    c.buyers = c.buyers or {}
    c.buyers[r.id] = r.buyer
    r.buyer = nil
  end
end
function L.buyerOf(r)
  local c = charDB()
  return r and c.buyers and c.buyers[r.id] or nil
end

function W.seen(list)
  local s = L.get()
  if not s or type(list) ~= "table" then return end
  local ch, h = L.ch(), house()
  local claimed = {}
  for _, m in ipairs(list) do
    if type(m) == "table" and m.cat then
      local okS, r = pcall(L.mailSeen, s, m, ch, h, nil, claimed)
      if okS then keepBuyer(r) end
    end
  end
  refresh()
end

local scanQueued
function W.scan()
  local C = L.classifier()
  if not (C and L.get()) then return end
  W.seen(C.scan(L.isAlt))
end
local function queueScan()
  if scanQueued then return end
  scanQueued = true
  local function go() scanQueued = nil; pcall(W.scan) end
  if C_Timer and C_Timer.After then C_Timer.After(0.3, go) else go() end
end

-- What was taken: read the mail as it is taken (the server hasn't removed anything yet).
function W.took(m, part, slot)
  local s = L.get()
  if not s or type(m) ~= "table" or not m.cat then return end
  local ch, h = L.ch(), house()
  if part == "money" or part == "all" then
    if (m.money or 0) > 0 then pcall(L.mailTaken, s, m, "money", nil, ch, h) end
  end
  if part == "item" or part == "all" then
    if (m.itemCount or 0) > 0 or (m.items and #m.items > 0) then
      local okT = pcall(L.mailTaken, s, m, "item", part == "item" and slot or nil, ch, h)
      if okT and m.cat == "ah_won" and ns.purchases and ns.purchases.noteWon then pcall(ns.purchases.noteWon, m) end
    end
  end
  local r = L.mailEntry(s, m) and L.byId(s, L.mailEntry(s, m).rec)
  keepBuyer(r)
  refresh()
end

local function takeHook(part)
  return function(i, slot)
    local C = L.classifier()
    if not (C and L.get()) then return end
    local m = C.read(okv(i), L.isAlt)
    if m then W.took(m, part, okv(slot)) end
  end
end
for name, part in pairs({ TakeInboxMoney = "money", TakeInboxItem = "item", AutoLootMailItem = "all" }) do
  if type(_G[name]) == "function" then hooksecurefunc(name, takeHook(part)) end
end
W.takeHook = takeHook

---------------------------------------------------------------------------------------------------------------------
-- Other money: loot (Purchases.noteLoot), vendor sales, quests

function L.note(cat, c, extra)
  local s = L.get()
  if not s then return nil end
  extra = extra or {}
  extra.ch, extra.h = extra.ch or L.ch(), extra.h or house()
  local e = L.addMoney(s, cat, c, extra)
  if e then refresh() end
  return e
end

local atMerchant, lastMoney
local ev = CreateFrame("Frame")
for _, e in ipairs({ "PLAYER_LOGIN", "AUCTION_HOUSE_AUCTION_CREATED", "AUCTION_CANCELED", "AUCTION_HOUSE_POST_ERROR",
    "MAIL_SHOW", "MAIL_INBOX_UPDATE", "MERCHANT_SHOW", "MERCHANT_CLOSED", "PLAYER_MONEY", "QUEST_TURNED_IN" }) do
  pcall(ev.RegisterEvent, ev, e)
end
ev:SetScript("OnEvent", function(_, e, a1, a2, a3)
  if e == "AUCTION_HOUSE_AUCTION_CREATED" then pcall(created, a1)
  elseif e == "AUCTION_HOUSE_POST_ERROR" then posting = nil
  elseif e == "AUCTION_CANCELED" then pcall(cancelled, a1)
  elseif e == "MAIL_SHOW" or e == "MAIL_INBOX_UPDATE" then queueScan()
  elseif e == "MERCHANT_SHOW" then atMerchant, lastMoney = true, try(GetMoney)
  elseif e == "MERCHANT_CLOSED" then atMerchant, lastMoney = nil, nil
  elseif e == "PLAYER_MONEY" then
    if atMerchant then
      local m = try(GetMoney)
      if m and lastMoney and m > lastMoney then L.note("vendor", m - lastMoney) end
      lastMoney = m
    end
  elseif e == "QUEST_TURNED_IN" then
    local c = tonumber(okv(a3))
    if c and c > 0 then L.note("quest", c, { quest = tonumber(okv(a1)) }) end
  elseif e == "PLAYER_LOGIN" then
    pcall(W.login)
  end
end)

-- At login: this character's fingerprints, the one-time move of the old AH log, a tidy up.
function W.login()
  local s, C = L.get(), L.classifier()
  if not s then return end
  local name = try(UnitName, "player")
  if C and type(name) == "string" and name ~= "" then
    me.name = name
    s.alts[C.hash(name)] = true
  end
  local d = db()
  L.migrate(d, s)
  local ch = L.ch()
  if ch then
    L.migrateForSale(s, charDB().forSale, ch)
    L.migrateLoot(s, charDB().looted, ch)
  end
  L.prune(s)
  L.tick(s)
end

-- For EverlookDB Mail (API.lua, EverlookDBAuctionsAPI.mail): its scan of the inbox and what it took. Our own hooks see
-- the same takes; one take counts once.
L.api = {
  version = 1,
  scanned = function(list) local okS = pcall(W.seen, list); return okS end,
  taken = function(m, part, slot) local okT = pcall(W.took, m, part, slot); return okT end,
  classifier = function() return L.classifier() end,
}
