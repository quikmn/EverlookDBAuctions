-- EverlookDB Auctions: selling.
--   Quick sell   a tab on the auction house (named apart from Blizzard's own Sell tab) with everything in your bags you can sell on the left, a post panel
--                (quantity, unit price, total, duration, deposit, 30-day price chart) and the live auctions for the
--                picked item, and your own auctions with a Cancel button each. Each item's last price, quantity
--                and duration are remembered. Right-click an item to make it a favourite (kept at the top);
--                Shift+right-click hides it.
--   Price        the cheapest auction someone else has up, lowered by your undercut (1 silver unless you set
--                another, in the tab or with /eah undercut). Your own auctions are matched, never undercut. When
--                nobody else is selling, your last price for the item, or else the usual price at the last
--                full scan.
--   Your auctions  each is checked against the live auctions and marked Undercut when someone else is cheaper.
--   Blizzard's own Sell tab gets the same undercut when you pick an auction in its list.
-- Every post and every cancel is one click of yours on one button: nothing is posted or cancelled on its own.
-- Sellers, bidders and other players are never read into anything kept.

local _, ns = ...
local UI, T = ns.UI, ns.T
local AH = C_AuctionHouse or {}
local money, num = ns.money, ns.num
local C_MUTE = UI.hex(T.mute)

local SORTS = { { sortOrder = 0, reverseSort = false } }   -- by price (Enum.AuctionHouseSortOrder.Price)
local DURATIONS = { { 1, "12h" }, { 2, "24h" }, { 3, "48h" } }
local BAG_ROW, LIST_ROW = 26, 22
local SPARK_PITCH, SPARK_H = 4, 12   -- the 30-day chart: a 3 px bar every 4 px, at most 12 px tall
local CHECK_AGAIN = 120          -- seconds before an item's live auctions are looked up again for Your auctions

local S = { groups = {}, mode = "all", filter = "", view = "cur", owned = {} }

-- Calls an API function that might not exist in this client, or might error: the result, or nil.
local function try(fn, ...)
  if type(fn) ~= "function" then return nil end
  local okCall, a, b = pcall(fn, ...)
  if okCall then return a, b end
  return nil
end
ns.try = try

-- Values the game hides from addons count as unknown.
local function okv(v)
  if ns.ok then return ns.ok(v) end
  return v
end

local function clamp(n, lo, hi) return math.max(lo, math.min(hi, n)) end

---------------------------------------------------------------------------------------------------------------------
-- Settings: db.sell = { duration, memory = { [item key] = { p = unit price, d = duration, q = quantity, at } },
-- fav = { [key] = true }, hidden = { [key] = true } }. db.undercut is shared with /eah undercut.

local MEMORY_DAYS = 180          -- an item's remembered price is forgotten after this long without a post

-- Drops remembered prices not used for MEMORY_DAYS (they would only grow the saved file). Returns how many went.
local function pruneMemory(memory, now)
  local gone = 0
  for k, m in pairs(memory) do
    if type(m) ~= "table" or (now - (m.at or 0)) > MEMORY_DAYS * 86400 then memory[k] = nil; gone = gone + 1 end
  end
  return gone
end
ns.pruneSellMemory = pruneMemory

local function sdb()
  local db = ns.db()
  if not db then return nil end
  db.sell = db.sell or {}
  local s = db.sell
  s.memory = s.memory or {}
  s.fav = s.fav or {}
  s.hidden = s.hidden or {}
  if not S.pruned then
    S.pruned = true
    pruneMemory(s.memory, time())
  end
  return s
end
ns.sellSettings = sdb

---------------------------------------------------------------------------------------------------------------------
-- Prices

-- "1g50s", "75s", "20c", "1g" -> copper
local function parseMoney(text)
  local total, any = 0, false
  for n, unit in text:gmatch("(%d+)%s*([gsc])") do
    total = total + tonumber(n) * (unit == "g" and 10000 or unit == "s" and 100 or 1)
    any = true
  end
  return any and total or nil
end
ns.parseMoney = parseMoney

-- The undercut setting: { copper = n } or { pct = n }. Default 1 silver.
local function undercut()
  local db = ns.db()
  return db and db.undercut or { copper = 100 }
end

-- 1g50s style, for the undercut box
local function shortMoney(c)
  local g, s, cc = math.floor(c / 10000), math.floor(c / 100) % 100, c % 100
  local out = (g > 0 and g .. "g" or "") .. (s > 0 and s .. "s" or "") .. (cc > 0 and cc .. "c" or "")
  return out ~= "" and out or "0"
end

local function undercutShort()
  local u = undercut()
  if u.pct then return u.pct .. "%" end
  return shortMoney(u.copper or 0)
end

local function undercutText()
  local u = undercut()
  if u.pct then return u.pct .. "%" end
  if (u.copper or 0) == 0 then return "none (match the cheapest)" end
  return money(u.copper)
end

-- Sets the undercut from "1s", "50c", "1g", "5%" or "0". Returns true, or false and why.
local function setUndercut(arg)
  local db = ns.db()
  if not db then return false, "not loaded yet" end
  arg = (arg or ""):lower():gsub("%s+", "")
  local pct = tonumber(arg:match("^(%d+%.?%d*)%%$") or "")
  if pct and pct < 100 then
    db.undercut = { pct = pct }
  elseif arg == "0" then
    db.undercut = { copper = 0 }
  else
    -- only gold, silver and copper amounts: "1.5s" or "1s banana" are not quietly read as 5s or 1s
    local copper = arg:gsub("%d+[gsc]", "") == "" and parseMoney(arg) or nil
    if not copper then return false, ("\"%s\" isn't an undercut. Use 1s, 50c, 1g, 5%% or 0, for example /eah undercut 1c."):format(arg) end
    db.undercut = { copper = copper }
  end
  return true
end
ns.setUndercut, ns.undercutShort = setUndercut, undercutShort

-- The smallest price step this auction house takes: copper when C_AuctionHouse.SupportsCopperValues() says so
-- (WoW Forever does, for items and stackable goods alike: Blizzard's own sell frame asks the same function), else
-- whole silver.
local function priceStep()
  local f = AH.SupportsCopperValues
  if type(f) == "function" then
    local okCall, v = pcall(f)
    if okCall and v then return 1 end
  end
  return 100
end
ns.priceStep = priceStep

local function roundPrice(copper)
  local step = priceStep()
  return math.max(step, math.floor(copper / step) * step)
end

-- The price to post at when someone else's cheapest auction is `p`.
local function undercutPrice(p)
  local u = undercut()
  local step = priceStep()
  local new
  if u.pct then
    new = p * (1 - u.pct / 100)
  else
    new = p - (u.copper or 100)
  end
  new = math.floor(new / step) * step
  local wantsBelow = u.pct and u.pct > 0 or (u.copper or 0) > 0
  if wantsBelow and new >= p then new = math.floor((p - 1) / step) * step end
  return math.max(step, new)
end
ns.undercutPrice = undercutPrice

-- How the suggested price relates to the cheapest auction: "1c under the cheapest auction, 1s 21c."
local function underText(cheapest, what)
  local u = undercut()
  what = what or "the cheapest auction"
  if (u.pct and u.pct == 0) or (not u.pct and (u.copper or 0) == 0) then
    return ("Matches %s, %s."):format(what, money(cheapest))
  end
  return ("%s under %s, %s."):format(u.pct and (u.pct .. "%") or money(u.copper), what, money(cheapest))
end
ns.underText = underText

-- The short line under Quantity: only for commodities (stackable goods on this auction house), which go up as one
-- listing that buyers take any amount of. Other items go up as that many auctions of one, as the Post button says.
local function qtyNote(commodity, qty)
  if not commodity or not qty or qty < 1 then return "" end
  return "Buyers can buy any amount."
end
ns.sellQtyNote = qtyNote

-- The price for a click on a row of Current auctions: your undercut under it, or the same price when it's your own
-- auction (you never undercut yourself). Returns the price and the line saying where it comes from.
local function rowPrice(r)
  if r.others == 0 then
    return roundPrice(r.unit), ("Matches your auction, %s."):format(money(r.unit))
  end
  return undercutPrice(r.unit), underText(r.unit, "the auction you picked")
end
ns.sellRowPrice = rowPrice

-- A deposit bigger than the sale brings: what to say, or nil. vendorTotal is what a vendor pays for the same amount.
local function depositWarning(deposit, total, vendorTotal)
  if not deposit or deposit <= 0 or not total or total <= 0 or deposit <= total then return nil end
  local out = ("The deposit (%s) is more than this sells for (%s). If it doesn't sell you lose %s."):format(
    money(deposit), money(total), money(deposit))
  if vendorTotal and vendorTotal > total then
    return out .. (" A vendor pays %s for them."):format(money(vendorTotal))
  end
  return out .. " Selling more at once spreads the deposit."
end
ns.depositWarning = depositWarning

-- Said after the undercut is set: when this auction house only takes whole silver, a copper undercut can't be exact.
local function stepNote()
  local u = undercut()
  if priceStep() > 1 and not u.pct and (u.copper or 0) % 100 ~= 0 then
    return " (this auction house only takes whole silver, so prices round down to it)"
  end
  return ""
end

-- The last full scan's numbers for the item at `loc` (its random-stat version when it has one).
local function scanRow(loc)
  if not loc or not loc:IsValid() then return nil end
  local id = C_Item.GetItemID(loc)
  local link = C_Item.GetItemLink(loc)
  if not id then return nil end
  local key = ns.variantOf(id, link) or (id .. ":0")
  return ns.latestRow(key)
end

---------------------------------------------------------------------------------------------------------------------
-- Blizzard's own Sell tab: the same undercut when you pick an auction in its list, and the scan price when nobody
-- is selling.

-- Nobody is selling it right now: fill in the scan's usual price (only over Blizzard's default guess).
local function fallback(frame, commodity)
  local loc = frame:GetItem()
  if not loc or not loc:IsValid() then return end
  if frame.PriceInput:GetAmount() ~= frame:GetDefaultPrice() then return end
  local n, full
  if commodity then
    local id = C_Item.GetItemID(loc)
    n, full = AH.GetNumCommoditySearchResults(id), AH.HasFullCommoditySearchResults(id)
  else
    local key = frame.listDisplayedItemKey
    if not key then return end
    n, full = AH.GetNumItemSearchResults(key), AH.HasFullItemSearchResults(key)
  end
  if (n or 0) > 0 or not full then return end
  local row = scanRow(loc)
  local p = row and (row.med or row.low)
  if p then frame.PriceInput:SetAmount(roundPrice(p)) end
end

-- Blizzard's Sell tab: the deposit warning, in a line of ours under its Post button.
local function blizzardDepositLine(frame)
  if not frame.edbDepositLine then
    local anchor = frame.PostButton
    if not anchor then return end
    local fs = frame:CreateFontString(nil, "OVERLAY", "GameFontRedSmall")
    fs:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", -74, -10)
    fs:SetWidth(330)
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(true)
    frame.edbDepositLine = fs
  end
  local text
  local loc = frame:GetItem()
  if loc and loc:IsValid() then
    local deposit, total = frame:GetDepositAmount(), frame:GetTotalPrice()
    local qty = frame.GetQuantity and frame:GetQuantity() or 1
    local id = C_Item.GetItemID(loc)
    local sell = id and select(11, C_Item.GetItemInfo(id))
    text = depositWarning(deposit, total, (sell or 0) * qty)
  end
  frame.edbDepositLine:SetText(text or "")
end

local function hookSellFrames()
  local ah = _G.AuctionHouseFrame
  if S.hooked or not ah or not ah.ItemSellFrame or not ah.CommoditiesSellFrame then return end
  S.hooked = true
  local items, goods = ah.ItemSellFrame, ah.CommoditiesSellFrame

  hooksecurefunc(items, "OnSearchResultSelected", function(self, r)
    if not r or not r.buyoutAmount or r.containsOwnerItem or r == self.noneAvailableEntry then return end
    self.PriceInput:SetAmount(undercutPrice(r.buyoutAmount))
  end)
  hooksecurefunc(goods, "OnAuctionSelected", function(self, r)
    if not r or not r.unitPrice or r.containsOwnerItem then return end
    self.PriceInput:SetAmount(undercutPrice(r.unitPrice))
  end)
  hooksecurefunc(items, "UpdatePriceSelection", function(self) pcall(fallback, self, false) end)
  hooksecurefunc(goods, "UpdatePriceSelection", function(self) pcall(fallback, self, true) end)
  -- a red line under Post when the deposit is more than the sale brings
  for _, fr in ipairs({ items, goods }) do
    if fr.UpdateDeposit then hooksecurefunc(fr, "UpdateDeposit", function(self) pcall(blizzardDepositLine, self) end) end
    if fr.UpdateTotalPrice then hooksecurefunc(fr, "UpdateTotalPrice", function(self) pcall(blizzardDepositLine, self) end) end
  end
end

---------------------------------------------------------------------------------------------------------------------
-- Your bags: everything you can sell here, one entry per item version, stacks added up

local function maxStack(id)
  local n = try(C_Item.GetItemMaxStackSizeByID, id)
  if n then return n end
  local info = { pcall(C_Item.GetItemInfo, id) }
  return (info[1] and info[9]) or 1
end

local function collect()
  local s = sdb()
  local groups, byKey = {}, {}
  for bag = 0, NUM_BAG_SLOTS or 4 do
    for slot = 1, (C_Container.GetContainerNumSlots(bag) or 0) do
      local info = C_Container.GetContainerItemInfo(bag, slot)
      if info and info.itemID and not info.isBound then
        local loc = ItemLocation:CreateFromBagAndSlot(bag, slot)
        local okValid, valid = pcall(AH.IsSellItemValid, loc, false)
        if okValid and valid then
          local key = ns.variantOf(info.itemID, info.hyperlink) or (info.itemID .. ":0")
          local g = byKey[key]
          if not g then
            local row = ns.latestRow(key)
            g = {
              key = key, id = info.itemID, link = info.hyperlink, icon = info.iconFileID, quality = info.quality,
              name = info.hyperlink and info.hyperlink:match("%[(.-)%]") or ("item " .. info.itemID),
              count = 0, slots = {}, scan = row and (row.med or row.low), scanAt = row and row.at,
            }
            byKey[key] = g
            groups[#groups + 1] = g
          end
          g.count = g.count + (info.stackCount or 1)
          g.slots[#g.slots + 1] = { bag, slot }
        end
      end
    end
  end
  -- favourites first, then the most valuable, then by name
  local fav = s and s.fav or {}
  local mem = s and s.memory or {}
  local function value(g)
    local p = (mem[g.key] and mem[g.key].p) or g.scan
    return p and p * g.count
  end
  table.sort(groups, function(a, b)
    local fa, fb = fav[a.key] and 1 or 0, fav[b.key] and 1 or 0
    if fa ~= fb then return fa > fb end
    local va, vb = value(a), value(b)
    if va and vb and va ~= vb then return va > vb end
    if (va ~= nil) ~= (vb ~= nil) then return va ~= nil end
    return a.name < b.name
  end)
  S.groups = groups
end

-- A bag slot that still holds this item version.
local function locate(g)
  for _, bs in ipairs(g.slots) do
    local loc = ItemLocation:CreateFromBagAndSlot(bs[1], bs[2])
    if loc:IsValid() and C_Item.GetItemID(loc) == g.id then
      local link = C_Item.GetItemLink(loc)
      if (ns.variantOf(g.id, link) or (g.id .. ":0")) == g.key then return loc end
    end
  end
end

local function ckey(k)
  return type(k) == "table" and ((k.itemID or 0) .. ":" .. (k.itemLevel or 0) .. ":" .. (k.itemSuffix or 0)) or nil
end

-- What the auction house needs to know about the picked item: where it is, commodity or not, its item key.
local function prepare(g)
  g.loc = locate(g)
  g.maxStack = maxStack(g.id)
  local status = g.loc and try(AH.GetItemCommodityStatus, g.loc)
  if status == 2 then g.commodity = true
  elseif status == 1 then g.commodity = false
  else g.commodity = g.maxStack > 1 end       -- not known yet: stackable things are commodities on this auction house
  -- the key from the item itself; a hand-made one (suffix 0) finds nothing for random-stat gear, so only plain items
  -- get one
  g.itemKey = (g.loc and try(AH.GetItemKeyFromItem, g.loc))
    or (g.key == g.id .. ":0" and try(AH.MakeItemKey, g.id, 0, 0, 0)) or nil
  g.ckey = ckey(g.itemKey)
  local info = ns.itemInfo and ns.itemInfo(g.id)
  g.vendor = info and info[9] or nil   -- nil: not loaded yet (shown as …), 0: vendors don't buy it
  g.de = ns.disenchantValue and ns.disenchantValue(g.id)
end

local function available(g)
  local n = g.loc and try(AH.GetAvailablePostCount, g.loc)
  return (n and n > 0) and n or g.count
end

---------------------------------------------------------------------------------------------------------------------
-- Live auctions, one item at a time, through the addon's one search queue (AHQuery.lua): it waits for Blizzard's own
-- searches, asks again when no answer comes, fetches every page, and says "no answer" instead of "nobody".
-- cache[ckey] = { rows = { { unit, qty, others (not yours), mine, left, band } }, full, lowestOther, lowestMine, at }
-- jobs[ckey] = the search out for it; failed[ckey] = when the auction house last gave no answer for it.

local Live = { cache = {}, byId = {}, jobs = {}, failed = {} }
local onLive          -- runs when an item's results came in (set further down)

local function summarize(e)
  table.sort(e.rows, function(a, b)
    if a.unit and b.unit then return a.unit < b.unit end
    return a.unit ~= nil and b.unit == nil
  end)
  local others = 0
  for _, r in ipairs(e.rows) do
    if r.unit then
      if r.others > 0 and not e.lowestOther then e.lowestOther = r.unit end
      if r.mine and not e.lowestMine then e.lowestMine = r.unit end
      others = others + r.others
    end
  end
  -- the median price per unit of everyone else's; the cheapest is "lone" when it is a single unit under 60% of that
  local acc, first = 0, nil
  for _, r in ipairs(e.rows) do
    if r.unit and r.others > 0 then
      first = first or r
      acc = acc + r.others
      if acc >= others / 2 then e.usual = r.unit; break end
    end
  end
  e.lone = first ~= nil and others >= 5 and first.others == 1 and e.usual ~= nil and first.unit < e.usual * 0.6
end
ns.sellSummarize = summarize

-- An answer we can go by: complete, or (sorted by price) at least showing a priced auction. A part answer with no
-- price in it says nothing about who is selling.
local function usable(e)
  return type(e) == "table" and (e.full == true or e.lowestOther ~= nil or e.lowestMine ~= nil)
end
ns.sellUsable = usable

local function liveFor(c, itemID, commodity)
  local e = c and Live.cache[c] or nil
  if not e and commodity and itemID then e = Live.byId[itemID] end
  return usable(e) and e or nil
end

local function readCommodity(id)
  local rows = {}
  for i = 1, (try(AH.GetNumCommoditySearchResults, id) or 0) do
    local r = try(AH.GetCommoditySearchResultInfo, id, i)
    if r then
      local q = okv(r.quantity) or 0
      local mine = okv(r.numOwnerItems) or (okv(r.containsOwnerItem) and q or 0)
      rows[#rows + 1] = { unit = okv(r.unitPrice), qty = q, others = q - mine, mine = mine > 0, left = okv(r.timeLeftSeconds) }
    end
  end
  return rows, try(AH.HasFullCommoditySearchResults, id) == true
end

local function readItems(k)
  local rows = {}
  for i = 1, (try(AH.GetNumItemSearchResults, k) or 0) do
    local r = try(AH.GetItemSearchResultInfo, k, i)
    if r then
      local q = okv(r.quantity) or 1
      local buy = okv(r.buyoutAmount)
      local mine = okv(r.containsOwnerItem) == true
      rows[#rows + 1] = {
        unit = (buy and buy > 0) and math.floor(buy / math.max(1, q)) or nil, qty = q, others = mine and 0 or q,
        mine = mine, left = okv(r.timeLeftSeconds), band = okv(r.timeLeft),
      }
    end
  end
  return rows, try(AH.HasFullItemSearchResults, k) == true
end

local function store(k, c, commodity)
  local rows, full
  if commodity then rows, full = readCommodity(k.itemID) else rows, full = readItems(k) end
  local e = { rows = rows, full = full, at = time() }
  summarize(e)
  Live.cache[c] = e
  if commodity then Live.byId[k.itemID] = e end
  return e
end

-- Looks up an item's live auctions (searches only: nothing is bought or posted). `front` puts it ahead of the
-- background checks of your other auctions.
local function request(k, commodity, front)
  local c = ckey(k)
  local Q = ns.ahq
  if not c or not Q or not Q.items then return end
  local j = Live.jobs[c]
  if j and not j.cancelled then
    -- already asked: a waiting background one moves to the front
    if front and not j.front then
      for i, x in ipairs(Q.list) do
        if x == j then table.remove(Q.list, i); j.background = nil; Q.add(j, true); break end
      end
    end
    return
  end
  Live.failed[c] = nil
  local job
  job = Q.items(k, {
    owner = "sell", front = front, background = not front, commodity = commodity,
    onFail = function()
      if Live.jobs[c] == job then Live.jobs[c] = nil end
      Live.failed[c] = time()
      if onLive then onLive(c) end
    end,
  }, function(_, _, final)
    store(k, c, commodity)
    if final then
      if Live.jobs[c] == job then Live.jobs[c] = nil end
      -- the last page came and still says nothing (incomplete, no price in it): as good as no answer
      if not usable(Live.cache[c]) then Live.failed[c] = time() end
    end
    if onLive then onLive(c) end
  end)
  Live.jobs[c] = job   -- answers only come with events, never inside Q.items itself
end
ns.sellLive, ns.sellRequest = Live, request   -- for the offline tests

---------------------------------------------------------------------------------------------------------------------
-- Your auctions

local function queryOwned()
  if AH.QueryOwnedAuctions then pcall(AH.QueryOwnedAuctions, SORTS) end
end

-- Whether an owned commodity auction's buyoutAmount is the price of the whole auction or of one: learned from your
-- own posts (the price you posted at is remembered), kept in db.sell.ownedTotal. Until then, one (as on retail).
local function learnOwnedPrice(itemID, qty, buy)
  local s = sdb()
  if not s or s.ownedTotal ~= nil or qty < 2 or not itemID then return end
  local mem = s.memory[itemID .. ":0"]
  if not mem or not mem.p then return end
  if buy == mem.p * qty then s.ownedTotal = true elseif buy == mem.p then s.ownedTotal = false end
end

local function ownedUnit(commodity, qty, buy)
  if not buy or buy <= 0 then return nil end
  local s = sdb()
  if commodity and not (s and s.ownedTotal) then return buy end
  return math.floor(buy / math.max(1, qty))
end

local function readOwned()
  local list = {}
  for i = 1, (try(AH.GetNumOwnedAuctions) or 0) do
    local a = try(AH.GetOwnedAuctionInfo, i)
    local id = a and okv(a.auctionID)
    if id then
      local k = a.itemKey
      local itemID = k and k.itemID
      local info = k and try(AH.GetItemKeyInfo, k)
      local link = okv(a.itemLink)
      local qty = okv(a.quantity) or 1
      local buy = okv(a.buyoutAmount)
      local commodity = info and info.isCommodity
      if commodity then learnOwnedPrice(itemID, qty, buy) end
      list[#list + 1] = {
        id = id, key = k, ckey = ckey(k), itemID = itemID, link = link, commodity = commodity,
        name = (link and link:match("%[(.-)%]")) or (info and info.itemName) or (itemID and try(C_Item.GetItemNameByID, itemID)) or "?",
        quality = (info and info.quality) or (itemID and try(C_Item.GetItemQualityByID, itemID)),
        icon = (info and info.iconFileID) or (itemID and try(C_Item.GetItemIconByID, itemID)),
        qty = qty, unit = ownedUnit(commodity, qty, buy),
        sold = okv(a.status) == 1, left = okv(a.timeLeftSeconds), band = okv(a.timeLeft),
        hasBid = (okv(a.bidAmount) or 0) > 0,
      }
    end
  end
  table.sort(list, function(x, y)
    if x.sold ~= y.sold then return y.sold end
    if x.name ~= y.name then return x.name < y.name end
    return (x.unit or 0) < (y.unit or 0)
  end)
  S.owned = list
end

-- "Undercut" (someone else is cheaper now), "Lowest", "Sold", "No answer" (the live check got none), or from saved
-- prices only "Maybe". The fourth value is where the third (a cheaper price) comes from: "live" or "saved".
local function ownedState(a)
  if a.sold then return "Sold", T.good end
  local e = liveFor(a.ckey, a.itemID, a.commodity)
  if e then
    if e.lowestOther and a.unit and e.lowestOther < a.unit then return "Undercut", T.bad, e.lowestOther, "live" end
    return "Lowest", T.good
  end
  local it = ns.houseItem and ns.houseItem(a.itemID)
  if it and it[1] and a.unit and it[1] < a.unit then return "Maybe", T.accent, it[1], "saved" end
  if a.ckey and Live.failed[a.ckey] and not Live.jobs[a.ckey] then return "No answer", T.mute end
  return "Checking", T.mute
end
ns.ownedState = ownedState

-- Looks up the live auctions of everything you have up (one search at a time, behind the picked item).
local function checkOwned()
  local seen, now = {}, time()
  for _, a in ipairs(S.owned) do
    if not a.sold and a.ckey and not seen[a.ckey] then
      seen[a.ckey] = true
      local e = Live.cache[a.ckey]
      if (not e or now - e.at > CHECK_AGAIN) and not (Live.failed[a.ckey] and now - Live.failed[a.ckey] < CHECK_AGAIN) then
        request(a.key, a.commodity, false)
      end
    end
  end
end

---------------------------------------------------------------------------------------------------------------------
-- The Quick sell tab

local BANDS = { [0] = "< 30m", [1] = "30m - 2h", [2] = "2 - 12h", [3] = "12 - 48h" }
local function fmtLeft(secs, band)
  if secs then
    if secs >= 3600 then return math.floor(secs / 3600 + 0.5) .. "h" end
    return math.max(1, math.floor(secs / 60)) .. "m"
  end
  return band and BANDS[band] or ""
end

local function qualityHex(q)
  local c = q and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q]
  return c and c.hex or "|cffffffff"
end
ns.qualityHex = qualityHex

local function setStatus(text, color)
  local f = S.frame
  if not f then return end
  f.status:SetText(text or "")
  f.status:SetTextColor(unpack(color or T.dim))
end

local function writePrice(unit)
  local f = S.frame
  if not unit or unit <= 0 then
    f.gold:SetText("")
    f.silver:SetText("")
    f.copper:SetText("")
    return
  end
  f.gold:SetText(tostring(math.floor(unit / 10000)))
  f.silver:SetText(tostring(math.floor(unit / 100) % 100))
  f.copper:SetText(tostring(unit % 100))
end

-- The copper box shows only where the auction house takes copper.
local function showCopper(on)
  local f = S.frame
  f.copper:SetShown(on)
end

-- Total, deposit, the price's source and the Post button.
local function updateTotals()
  local f, g = S.frame, S.sel
  if not f then return end
  local qty, unit = S.qty or 0, S.unit or 0
  if not g then
    f.total:SetText("-")
    if f.net then f.net:SetText("") end
    f.deposit:SetText("-")
    f.source:SetText("")
    f.qtyNote:SetText("")
    f.suggest:Hide()
    f.post:Disable()
    f.post:SetText("Post")
    return
  end
  f.total:SetText((unit > 0 and qty > 0) and money(unit * qty) or "-")
  f.qtyNote:SetText(qtyNote(g.commodity, qty))
  f.suggest:SetShown(S.userPrice and true or false)   -- "Undercut cheapest": back from your own price
  local dep
  if g.commodity then dep = try(AH.CalculateCommodityDeposit, g.id, S.dur, qty)
  elseif g.loc then dep = try(AH.CalculateItemDeposit, g.loc, S.dur, qty) end
  f.deposit:SetText(dep and money(dep) or "-")
  -- the auction house keeps 5% of a sale (15% at a neutral house): show what you get, and say so when a vendor or
  -- disenchanting pays more
  local cut = ns.ahCut and ns.ahCut() or 0.05
  local net = math.floor(unit * (1 - cut))
  if f.net then
    f.net:SetText((unit > 0 and qty > 0) and money(net * qty) or "-")
    f.netNote:SetText(("after the %d%% AH cut"):format(cut * 100))
  end
  if f.vendorPrice then
    local v = g.vendor
    if v == nil then
      f.vendorPrice:SetText("…")
      f.vendorNote:SetText("")
    elseif v <= 0 then
      f.vendorPrice:SetText(UI.hex(T.dim) .. "Can't|r")
      f.vendorNote:SetText(UI.hex(T.dim) .. "vendors won't buy it|r")
    else
      f.vendorPrice:SetText(money(v))
      if unit <= 0 then
        f.vendorNote:SetText("")
      elseif v >= net then
        f.vendorNote:SetText(UI.hex(T.bad) .. "pays more than the AH|r")
      else
        f.vendorNote:SetText(UI.hex(T.good) .. "AH pays " .. money(net - v) .. " more|r")
      end
    end
  end
  local warn = (unit > 0 and qty > 0) and depositWarning(dep, unit * qty, (g.vendor or 0) * qty) or nil
  if warn then
    -- said first: the deposit is lost when it doesn't sell
  elseif unit > 0 and (g.vendor or 0) > net then
    warn = ("A vendor pays %s each, more than this gets you after the AH's %d%% cut."):format(money(g.vendor), cut * 100)
  elseif unit > 0 and g.de and g.de > net then
    warn = ("Disenchanting is worth about %s, more than this gets you after the AH's %d%% cut."):format(money(g.de), cut * 100)
  end
  f.source:SetText(warn and (UI.hex(T.bad) .. warn .. "|r") or S.source or "")
  f.post:SetEnabled(not S.posting and not S.warned and qty >= 1 and qty <= (S.avail or 0) and unit >= priceStep())
  local m = S.posting and S.posting.multi
  f.post:SetText(m and ("Posting %d / %d"):format(m[1], m[2]) or S.posting and "Posting..."
    or (qty > 1 and ("Post " .. num(qty)) or "Post"))
end

local function setQty(n)
  S.qty = clamp(math.floor(tonumber(n) or 1), 1, math.max(1, S.avail or 1))
  if S.frame then S.frame.qty:SetText(tostring(S.qty)) end
  updateTotals()
end

local function setDur(d)
  S.dur = d
  for _, b in ipairs(S.frame.durs) do b:EdbActive(b.dur == d) end
  updateTotals()
end

-- The price to suggest for the picked item, and where it comes from.
local function suggest()
  local g = S.sel
  if not g then return nil end
  local s = sdb()
  local mem = s and s.memory[g.key]
  local e = liveFor(g.ckey)
  -- live auctions older than a minute and a half say when they were checked
  local age = (e and time() - e.at >= 90) and (" Checked " .. ns.ago(e.at) .. ".") or ""
  if e and e.lowestOther and (not e.lowestMine or e.lowestOther < e.lowestMine) then
    local why = underText(e.lowestOther)
    local usual = e.lone and e.usual
    if usual then why = why .. (" It's a lone one far under the usual %s."):format(money(usual)) end
    return undercutPrice(e.lowestOther), why .. age
  end
  if e and e.lowestMine then
    return e.lowestMine, ("Matches your own cheapest auction, %s."):format(money(e.lowestMine)) .. age
  end
  local failed = not e and g.ckey and Live.failed[g.ckey] and not Live.jobs[g.ckey]
  local lead = e and "Nobody else is selling this." .. age .. " " or ""
  local tail = e and "" or failed and " The auction house didn't answer; Refresh asks again." or " Checking live auctions..."
  if mem and mem.p then return mem.p, lead .. "Your last price (" .. ns.ago(mem.at) .. ")." .. tail end
  if g.scan then
    local when = g.scanAt and (", " .. ns.ago(g.scanAt)) or ""
    return roundPrice(g.scan), lead .. "Usual price at the last full scan" .. when .. "." .. tail
  end
  if e then return nil, "Nobody is selling this." .. age .. " Set a price." end
  return nil, failed and "The auction house didn't answer. Click Refresh to ask again, or set a price." or "Checking live auctions..."
end

local function applySuggestion()
  if not S.frame then return end
  if not S.userPrice then
    local p, src = suggest()
    S.unit = p and roundPrice(p) or 0
    writePrice(S.unit)
    S.source = src
  end
  updateTotals()
end

local function renderBags()
  local f = S.frame
  if not f then return end
  local s = sdb() or { fav = {}, hidden = {} }
  local out = {}
  for _, g in ipairs(S.groups) do
    local hid, fav = s.hidden[g.key], s.fav[g.key]
    local pass = (S.mode == "hidden" and hid) or (S.mode == "fav" and fav and not hid) or (S.mode == "all" and not hid)
    if pass and (S.filter == "" or g.name:lower():find(S.filter, 1, true)) then out[#out + 1] = g end
  end
  f.bags.empty:SetText(S.mode == "fav" and "No favourites in your bags. Right-click an item to make it one."
    or S.mode == "hidden" and "Nothing hidden. Shift+right-click an item to hide it."
    or S.filter ~= "" and "Nothing matches." or "Nothing in your bags can be sold here.")
  f.bags:SetItems(out)
  S.visible = out
  f.bagCount:SetText(num(#S.groups) .. " items")
  for _, b in ipairs(f.modes) do b:EdbActive(b.mode == S.mode) end
end

local function renderCurrent()
  local f = S.frame
  if not f then return end
  local g = S.sel
  local raw = g and g.ckey and Live.cache[g.ckey]
  local e = g and liveFor(g.ckey)
  if not g then
    f.cur.empty:SetText("Pick an item from your bags to see its auctions.")
  elseif not e then
    local failed = Live.failed[g.ckey] and not Live.jobs[g.ckey]
    f.cur.empty:SetText(failed and "The auction house didn't answer. Click Refresh to ask again." or "Checking live auctions...")
  else
    f.cur.empty:SetText("Nobody is selling this right now.")
  end
  f.cur:SetItems(raw and raw.rows or {})
  if S.view == "cur" then
    local up = 0
    for _, r in ipairs(raw and raw.rows or {}) do up = up + r.qty end
    f.info:SetText(raw and ("%s auctions, %s up%s"):format(num(#raw.rows), num(up), raw.full and "" or " so far") or "")
  end
end

-- The first of your auctions someone else is cheaper than, or nil.
local function nextUndercut()
  for _, a in ipairs(S.owned) do
    if not a.sold and not a.cancelling and ownedState(a) == "Undercut" then return a end
  end
end

local function renderOwned()
  local f = S.frame
  if not f then return end
  -- "none" only once the auction house has sent the list for this visit; until then it is being asked
  f.own.empty:SetText(S.ownedLoaded and "You have no auctions up." or "Asking the auction house for your auctions...")
  f.own:SetItems(S.owned)
  if S.view == "own" then
    local n, under = 0, 0
    for _, a in ipairs(S.owned) do
      if not a.sold then
        n = n + 1
        if ownedState(a) == "Undercut" then under = under + 1 end
      end
    end
    f.info:SetText(S.ownedLoaded and ("%s up"):format(num(n)) or "")
    f.cutNext:SetText(under > 0 and ("Cancel undercut (%d)"):format(under) or "None undercut")
    f.cutNext:SetEnabled(under > 0 and not S.cancelPending and nextUndercut() ~= nil)
  end
  f.cutNext:SetShown(S.view == "own")
end

local function setView(v)
  local f = S.frame
  S.view = v
  f.curBtn:EdbActive(v == "cur")
  f.ownBtn:EdbActive(v == "own")
  f.curBand:SetShown(v == "cur")
  f.cur:SetShown(v == "cur")
  f.ownBand:SetShown(v == "own")
  f.own:SetShown(v == "own")
  if v == "own" then
    queryOwned()
    renderOwned()
  else
    renderCurrent()
  end
end

-- The 30-day chart: one bar per day with a price, the lowest of that day.
local function drawHistory()
  local sp = S.frame.spark
  for _, b in ipairs(sp.bars) do b:Hide() end
  local g = S.sel
  local hist = g and ns.history(g.id) or {}
  sp.data = hist
  if #hist == 0 then
    sp.stats:SetText(g and (C_MUTE .. "no price history yet|r") or "")
    return
  end
  local lo, hi = math.huge, 0
  local prices = {}
  for _, h in ipairs(hist) do
    lo, hi = math.min(lo, h[2]), math.max(hi, h[2])
    prices[#prices + 1] = h[2]
  end
  table.sort(prices)
  local med = prices[math.floor((#prices + 1) / 2)]
  sp.lo, sp.hi, sp.med = lo, hi, med
  local today = ns.today()
  local first = today - 29
  for _, h in ipairs(hist) do
    local b = sp.bars[h[1] - first + 1]
    if b then
      local frac = hi > lo and (h[2] - lo) / (hi - lo) or 0.5
      b:SetHeight(2 + math.floor(frac * (SPARK_H - 2) + 0.5))
      b:SetColorTexture(unpack(h[1] == today and T.accent or T.edgeHi))
      b:Show()
    end
  end
  sp.stats:SetText(money(lo))   -- under "30-DAY LOW"; the median and highest are in the tooltip
end

local function updatePost()
  local f = S.frame
  local g = S.sel
  f.icon:SetShown(g ~= nil)
  for _, w in ipairs(f.needItem) do w:SetShown(g ~= nil) end
  if not g then
    f.name:SetText("Pick an item from your bags")
    f.name:SetTextColor(unpack(T.dim))
    f.sub:SetText("Its live auctions show below, with a price just under the cheapest.")
    S.unit, S.qty = 0, 0
    writePrice(0)
    showCopper(false)
    f.qty:SetText("")
    drawHistory()
    updateTotals()
    return
  end
  f.icon:EdbSet(g.icon, g.quality)
  f.name:SetText(qualityHex(g.quality) .. g.name .. "|r")
  f.name:SetTextColor(unpack(T.text))
  local bits = { num(g.count) .. " in your bags" }
  local s = sdb()
  local mem = s and s.memory[g.key]
  if mem and mem.p then bits[#bits + 1] = "last posted at " .. money(mem.p) end
  if g.de then bits[#bits + 1] = "disenchant ~" .. money(g.de) end
  f.sub:SetText(table.concat(bits, "   "))
  f.qty:SetText(tostring(S.qty or 1))
  showCopper(priceStep() == 1)
  for _, b in ipairs(f.durs) do b:EdbActive(b.dur == S.dur) end
  drawHistory()
  applySuggestion()
end

local function selectGroup(g)
  local s = sdb()
  prepare(g)
  S.sel = g
  S.userPrice = false
  S.avail = available(g)
  local mem = s and s.memory[g.key]
  S.dur = (mem and mem.d) or (s and s.duration) or 1   -- 12 hours unless set in the options
  S.qty = clamp((mem and mem.q) or (g.commodity and S.avail or 1), 1, math.max(1, S.avail))
  if S.frame.confirm:IsShown() then S.frame.confirm:Hide(); S.warned = nil end
  updatePost()
  renderBags()
  if S.view ~= "cur" then setView("cur") else renderCurrent() end
  request(g.itemKey, g.commodity, true)
end

-- Bags changed: read them again and keep the picked item (or let go of it when it's gone).
local function refreshBags()
  if not S.frame or not S.frame:IsShown() then return end
  local g = S.sel
  local was
  for i, v in ipairs(S.visible or {}) do if g and v.key == g.key then was = i; break end end
  collect()
  if g then
    local again
    for _, n in ipairs(S.groups) do if n.key == g.key then again = n; break end end
    if again then
      prepare(again)
      S.sel = again
      S.avail = available(again)
      S.qty = clamp(S.qty or 1, 1, math.max(1, S.avail))
      updatePost()
    else
      S.sel = nil
      updatePost()
      renderCurrent()
    end
  end
  renderBags()
  -- you just posted the last of the picked item: pick the one that took its place in the list
  if g and not S.sel and S.advance == g.key and was then
    S.advance = nil
    local nxt = S.visible[was] or S.visible[#S.visible]
    if nxt then selectGroup(nxt) end
  end
end

function onLive(c)
  if not S.frame or not S.frame:IsShown() then return end
  if S.sel and S.sel.ckey == c then
    applySuggestion()
    renderCurrent()
  end
  if S.view == "own" then renderOwned() end
end

-- A post was sent: wait for the server. Several of an item (not a commodity) go up as that many auctions of one, one
-- after another (the game's "multisell"); Post stays off until the last one is up or it stops.
local function waitForPost(job)
  S.posting = job
  setStatus(("Posting %s x %s..."):format(num(job.qty), job.name), T.dim)
  updateTotals()
  local function check()
    if S.posting ~= job then return end
    -- a multisell that is still moving gets more time; anything else is given up on after 5 seconds of silence
    if job.multi and GetTime() - (job.heard or 0) < 5 then C_Timer.After(1, check); return end
    S.posting = nil
    -- no word back: say so (it may still have gone up), and look at Your auctions again
    local done = job.multi and job.multi[1] or 0
    setStatus(done > 0 and ("No word from the auction house after %d of %d. Check Your auctions before posting again."):format(done, job.multi[2])
      or "No word from the auction house about the post. Check Your auctions before posting again.", T.bad)
    queryOwned()
    updateTotals()
  end
  job.heard = GetTime()
  C_Timer.After(5, check)
end

-- The server wants a confirm for this post (an unusual price): show our own, which posts exactly what is set here.
local function askConfirm(job)
  if StaticPopup_Hide then pcall(StaticPopup_Hide, "AUCTION_HOUSE_POST_WARNING") end
  S.posting, S.warned = nil, job
  S.frame.confirm:Show()
  setStatus("Confirm the post, or don't.", T.accent)
  updateTotals()
end

-- Post: one click, one post. The price, quantity and duration are remembered for this item.
local function post()
  local g = S.sel
  if not g or S.posting or S.warned then return end
  local loc = locate(g)
  if not loc then
    setStatus("That item is no longer in your bags.", T.bad)
    refreshBags()
    return
  end
  local qty, unit, dur = S.qty or 0, S.unit or 0, S.dur or 2
  if qty < 1 or unit < priceStep() or qty > (S.avail or 0) then return end
  local okCall, needsConfirm
  if g.commodity then
    if not AH.PostCommodity then setStatus("This client can't post commodities.", T.bad); return end
    okCall, needsConfirm = pcall(AH.PostCommodity, loc, dur, qty, unit)
  else
    -- quantity is how many auctions of one; the buyout is per auction, so per item (as Blizzard's own Sell tab does)
    if not AH.PostItem then setStatus("This client can't post items.", T.bad); return end
    okCall, needsConfirm = pcall(AH.PostItem, loc, dur, qty, nil, unit)
  end
  if not okCall then
    setStatus("Couldn't post: " .. tostring(needsConfirm), T.bad)
    return
  end
  local s = sdb()
  if s then s.memory[g.key] = { p = unit, d = dur, q = qty, at = time() } end
  local job = { name = g.name, qty = qty, unit = unit, commodity = g.commodity, loc = loc, dur = dur, id = g.id, key = g.key }
  -- several of an item go up one auction at a time; count them until the last one is up
  if not g.commodity and qty > 1 then job.multi = { 0, qty } end
  if needsConfirm == true then askConfirm(job) else waitForPost(job) end
end

-- The confirm: one more click posts it.
local function confirmPost()
  local job = S.warned
  S.frame.confirm:Hide()
  S.warned = nil
  if not job then return end
  local okCall
  if job.commodity and AH.ConfirmPostCommodity then
    okCall = pcall(AH.ConfirmPostCommodity, job.loc, job.dur, job.qty, job.unit)
  elseif not job.commodity and AH.ConfirmPostItem then
    okCall = pcall(AH.ConfirmPostItem, job.loc, job.dur, job.qty, nil, job.unit)
  end
  if okCall then
    waitForPost(job)
  else
    setStatus("Couldn't confirm the post.", T.bad)
    updateTotals()
  end
end

-- Cancel: one click, one auction.
local function cancelAuction(a)
  if not a or a.sold or a.cancelling then return end
  if not AH.CancelAuction then setStatus("This client can't cancel auctions.", T.bad); return end
  if AH.CanCancelAuction then
    local okCan, can = pcall(AH.CanCancelAuction, a.id)
    if okCan and not can then setStatus("This auction can't be cancelled (it may have a bid).", T.bad); return end
  end
  local okCall, err = pcall(AH.CancelAuction, a.id)
  if okCall then
    a.cancelling = true
    -- one cancel at a time: the next waits for the server's answer (or 5 seconds)
    local mine = {}
    S.cancelPending = mine
    C_Timer.After(5, function()
      if S.cancelPending ~= mine then return end
      S.cancelPending = nil
      a.cancelling = nil
      setStatus(("No word from the auction house about cancelling %s. Your auctions shows whether it went."):format(a.name), T.bad)
      queryOwned()
      renderOwned()
    end)
    setStatus(("Cancelling %s..."):format(a.name), T.dim)
    renderOwned()
  else
    setStatus("Couldn't cancel: " .. tostring(err), T.bad)
  end
end

---------------------------------------------------------------------------------------------------------------------
-- Building the tab

local function buildBagRow(L)
  local b = UI.row(L, BAG_ROW)
  b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  b.icon = b:CreateTexture(nil, "ARTWORK")
  b.icon:SetSize(20, 20)
  b.icon:SetPoint("LEFT", 8, 0)
  b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  b.star = b:CreateTexture(nil, "OVERLAY")
  b.star:SetSize(13, 13)
  b.star:SetPoint("CENTER", b.icon, "TOPLEFT", 1, -1)
  if not pcall(b.star.SetAtlas, b.star, "auctionhouse-icon-favorite") then
    b.star:SetSize(6, 6)
    b.star:SetColorTexture(unpack(T.accent))
  end
  b.price = UI.text(b, "dim")
  b.price:SetPoint("RIGHT", -6, 0)
  b.price:SetJustifyH("RIGHT")
  b.name = UI.text(b, "body")
  b.name:SetPoint("LEFT", b.icon, "RIGHT", 8, 0)
  b.name:SetPoint("RIGHT", b.price, "LEFT", -6, 0)
  b:SetScript("OnClick", function(self, button)
    local g = self.item
    if not g then return end
    local s = sdb()
    if button == "RightButton" and s then
      if IsShiftKeyDown() then s.hidden[g.key] = (not s.hidden[g.key]) or nil
      else s.fav[g.key] = (not s.fav[g.key]) or nil end
      collect()
      renderBags()
      return
    end
    selectGroup(g)
  end)
  b:SetScript("OnEnter", function(self)
    local g = self.item
    if not g or not g.slots[1] then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    -- the item's own tooltip, so a name cut short in the row is shown in full; when it has moved in the bags since,
    -- its link, or at least its name
    local shown = pcall(GameTooltip.SetBagItem, GameTooltip, g.slots[1][1], g.slots[1][2])
      and C_Container.GetContainerItemID and C_Container.GetContainerItemID(g.slots[1][1], g.slots[1][2]) == g.id
    if not shown then
      GameTooltip:ClearLines()
      if not (g.link and pcall(GameTooltip.SetHyperlink, GameTooltip, g.link)) then
        GameTooltip:SetText(qualityHex(g.quality) .. g.name .. "|r", 1, 1, 1, 1, true)
      end
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Click to sell. Right-click: favourite. Shift+right-click: hide.", T.info[1], T.info[2], T.info[3], true)
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)
  return b
end

local function fillBagRow(b, g)
  local s = sdb()
  b.icon:SetTexture(g.icon)
  b.star:SetShown(s and s.fav[g.key] and true or false)
  local hid = s and s.hidden[g.key]
  b.name:SetText((hid and C_MUTE or qualityHex(g.quality)) .. g.name .. "|r" .. (g.count > 1 and (C_MUTE .. "  x" .. g.count .. "|r") or ""))
  local mem = s and s.memory[g.key]
  local p = (mem and mem.p) or g.scan
  b.price:SetText(p and money(p) or (C_MUTE .. "-|r"))
  b:EdbSelect(S.sel and S.sel.key == g.key)
end

local function buildCurRow(L)
  local b = UI.row(L, LIST_ROW)
  b.price = UI.text(b, "body")
  b.price:SetPoint("LEFT", 12, 0)
  b.tag = UI.text(b, "small")
  b.tag:SetPoint("LEFT", b.price, "RIGHT", 10, 0)
  b.tag:SetTextColor(unpack(T.accent))
  b.left = UI.text(b, "dim")
  b.left:SetPoint("RIGHT", -10, 0)
  b.left:SetWidth(80)
  b.left:SetJustifyH("RIGHT")
  b.qty = UI.text(b, "body")
  b.qty:SetPoint("RIGHT", b.left, "LEFT", -10, 0)
  b.qty:SetWidth(80)
  b.qty:SetJustifyH("RIGHT")
  b:SetScript("OnClick", function(self)
    local r = self.item
    if not r or not r.unit or not S.sel then return end
    S.userPrice = true
    S.unit, S.source = rowPrice(r)
    writePrice(S.unit)
    updateTotals()
  end)
  UI.tip(b, function() return b.item and b.item.unit and "Click to price under this auction" or nil end,
    function() return b.item and b.item.others == 0 and "It's yours, so the price matches it." or nil end)
  return b
end

local function fillCurRow(b, r)
  b.price:SetText(r.unit and money(r.unit) or (C_MUTE .. "bids only|r"))
  b.tag:SetText(r.mine and (r.others > 0 and "incl. yours" or "yours") or "")
  b.qty:SetText(num(r.qty))
  b.left:SetText(fmtLeft(r.left, r.band))
end

local function buildOwnRow(L)
  local b = UI.row(L, LIST_ROW)
  b.icon = b:CreateTexture(nil, "ARTWORK")
  b.icon:SetSize(16, 16)
  b.icon:SetPoint("LEFT", 8, 0)
  b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  b.cancel = UI.button(b, "Cancel", 58, 18, "small danger")
  b.cancel:SetPoint("RIGHT", -2, 0)
  b.cancel:SetScript("OnClick", function() cancelAuction(b.item) end)
  b.state = UI.badge(b, 70, 16)
  b.state:SetPoint("RIGHT", b.cancel, "LEFT", -6, 0)
  b.price = UI.text(b, "body")
  b.price:SetPoint("RIGHT", b.state, "LEFT", -8, 0)
  b.price:SetWidth(130)   -- room for thousands of gold with silver and copper
  b.price:SetJustifyH("RIGHT")
  b.qty = UI.text(b, "dim")
  b.qty:SetPoint("RIGHT", b.price, "LEFT", -8, 0)
  b.qty:SetWidth(44)
  b.qty:SetJustifyH("RIGHT")
  b.name = UI.text(b, "body")
  b.name:SetPoint("LEFT", b.icon, "RIGHT", 6, 0)
  b.name:SetPoint("RIGHT", b.qty, "LEFT", -6, 0)
  b:SetScript("OnClick", function(self)
    local a = self.item
    if a and not a.sold then
      request(a.key, a.commodity, true)
      setStatus(("Checking the live auctions for %s..."):format(a.name), T.dim)
    end
  end)
  b:SetScript("OnEnter", function(self)
    local a = self.item
    if not a then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    if a.link then pcall(GameTooltip.SetHyperlink, GameTooltip, a.link)
    elseif a.itemID then pcall(GameTooltip.SetItemByID, GameTooltip, a.itemID) end
    local state, _, lower, from = ownedState(a)
    local e = liveFor(a.ckey, a.itemID, a.commodity)
    if lower and from == "live" then
      GameTooltip:AddLine(("Cheapest other auction: %s"):format(money(lower)), T.bad[1], T.bad[2], T.bad[3])
    elseif lower then
      local it = ns.houseItem and ns.houseItem(a.itemID)
      GameTooltip:AddLine(("Your last scan or search saw one at %s (%s), maybe yours. Not checked live yet."):format(
        money(lower), ns.ago(it and it[4])), T.accent[1], T.accent[2], T.accent[3], true)
    elseif state == "No answer" then
      GameTooltip:AddLine("The auction house didn't answer the live check.", T.mute[1], T.mute[2], T.mute[3], true)
    end
    if e then GameTooltip:AddLine("Live auctions checked " .. ns.ago(e.at) .. ".", T.mute[1], T.mute[2], T.mute[3]) end
    if state ~= "Sold" then
      GameTooltip:AddLine(("Time left: %s"):format(fmtLeft(a.left, a.band)), T.dim[1], T.dim[2], T.dim[3])
      if a.hasBid then GameTooltip:AddLine("Has a bid", T.accent[1], T.accent[2], T.accent[3]) end
      GameTooltip:AddLine("Click to check its live auctions again.", T.info[1], T.info[2], T.info[3], true)
    end
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)
  UI.tip(b.cancel, "Cancel this auction", function()
    local a = b.item
    local cost = a and try(AH.GetCancelCost, a.id)
    return (cost and cost > 0) and ("Costs " .. money(cost) .. ". One click cancels one auction.") or "One click cancels one auction."
  end)
  return b
end

local function fillOwnRow(b, a)
  b.icon:SetTexture(a.icon)
  b.name:SetText(qualityHex(a.quality) .. a.name .. "|r")
  b.qty:SetText(num(a.qty))
  b.price:SetText(a.unit and money(a.unit) or (C_MUTE .. "-|r"))
  local state, color = ownedState(a)
  b.state:EdbSet(a.cancelling and "Cancelling" or state, a.cancelling and T.mute or color)
  b.cancel:SetShown(not a.sold)
  b.cancel:SetEnabled(not a.cancelling)
end

local function makeFrame()
  local ah = _G.AuctionHouseFrame
  if S.frame or not ah then return S.frame end
  local f = UI.own(CreateFrame("Frame", "EverlookAuctionsSelling", ah))
  f:SetPoint("TOPLEFT", ah, "TOPLEFT", 2, -24)
  f:SetPoint("BOTTOMRIGHT", ah, "BOTTOMRIGHT", -2, (ns.BAR_H or 0) + 2)   -- the bar along the bottom stays visible
  f:SetFrameLevel(ah:GetFrameLevel() + 150)
  f:EnableMouse(true)
  local PLACE = UI.place(f, "sell")   -- Quick sell's colour: where you are
  UI.panel(f, UI.tint(T.bg, PLACE, UI.WASH), PLACE)
  UI.placeEdge(f, PLACE)
  f:Hide()
  S.frame = f

  -- a title strip, so this is never mistaken for Blizzard's own Sell tab
  local head = UI.text(f, "title")
  head:SetPoint("TOPLEFT", 12, -8)
  head:SetText(UI.hex(PLACE) .. "Quick sell|r")
  local headNote = UI.text(f, "mute")
  headNote:SetPoint("LEFT", head, "RIGHT", 10, 0)
  headNote:SetPoint("RIGHT", f, "RIGHT", -12, 0)
  headNote:SetText("EverlookDB's selling: everything in your bags, priced from the live auctions. Blizzard's Sell tab is separate.")

  ------------------------------------------------------------------------------------------------ bags (left)
  local left = UI.panel(CreateFrame("Frame", nil, f), UI.tint(T.surface, PLACE, UI.WASH_INNER), UI.tint(T.edge, PLACE, UI.WASH_EDGE))
  left:SetPoint("TOPLEFT", 8, -28)
  left:SetPoint("BOTTOMLEFT", 8, 30)
  left:SetWidth(256)
  local title = UI.text(left, "title")
  title:SetPoint("TOPLEFT", 10, -10)
  title:SetText("Your bags")
  title:SetTextColor(unpack(PLACE))
  f.bagCount = UI.text(left, "mute")
  f.bagCount:SetPoint("TOPRIGHT", -10, -11)
  f.bagCount:SetJustifyH("RIGHT")

  local filter = UI.input(left, 236, 24, { hint = "Filter by name" })
  filter:SetPoint("TOPLEFT", 10, -32)
  filter:HookScript("OnTextChanged", function(self)
    S.filter = self:GetText():lower()
    renderBags()
  end)

  f.modes = {}
  for k, m in ipairs({ { "all", "All" }, { "fav", "Favourites" }, { "hidden", "Hidden" } }) do
    local b = UI.button(left, m[2], 76, 22, "small")
    b:SetPoint("TOPLEFT", 10 + (k - 1) * 80, -62)
    b.mode = m[1]
    b:SetScript("OnClick", function()
      S.mode = m[1]
      f.bags:ScrollToTop()
      renderBags()
    end)
    f.modes[k] = b
  end

  local sep = UI.line(left, true)
  sep:SetPoint("TOPLEFT", 1, -92)
  sep:SetPoint("TOPRIGHT", -1, -92)
  f.bags = UI.list(left, BAG_ROW, buildBagRow, fillBagRow)
  f.bags:SetPoint("TOPLEFT", 1, -93)
  f.bags:SetPoint("BOTTOMRIGHT", -3, 4)

  ------------------------------------------------------------------------------------------------ post panel
  -- Three bands in one visual language. On top, the item on a raised strip: what it is, and two stat blocks (what a
  -- vendor pays, the 30-day low). In the middle, your auction: a two-column grid, labels left of their controls.
  -- At the bottom, the summary on a raised strip: Deposit, Total price and You get as stat blocks, then Post.
  -- A stat block is always the same: a small grey caps label, a big value, a small note under it.
  local P = UI.panel(CreateFrame("Frame", nil, f), UI.tint(T.surface, PLACE, UI.WASH_INNER), UI.tint(T.edge, PLACE, UI.WASH_EDGE))
  P:SetPoint("TOPLEFT", left, "TOPRIGHT", 8, 0)
  P:SetPoint("TOPRIGHT", -8, -28)
  local TOP_H, FOOT_H = 76, 62               -- the item band and the summary band
  local SECT, ROW1, ROW2 = -86, -102, -146   -- the section title, then the tops of the two rows of 24 px controls
  local LAB_X, CTL_X = 12, 84                -- left column: labels, then controls
  local RLAB_W = 80                          -- right column: its labels start this far left of its controls
  local STAT_W, FOOT_W = 136, 112            -- stat blocks in the item band and in the summary band
  P:SetHeight(280)
  f.needItem = {}
  local function needs(w) f.needItem[#f.needItem + 1] = w; return w end

  -- the two raised strips, a touch of Quick sell's green in them like the panel, each with a line on its inner side
  local bandFill = UI.tint(T.raised, PLACE, UI.WASH_INNER)
  local topBand = P:CreateTexture(nil, "BACKGROUND", nil, -7)
  topBand:SetPoint("TOPLEFT", 1, -1)
  topBand:SetPoint("TOPRIGHT", -1, -1)
  topBand:SetHeight(TOP_H - 1)
  UI.shade(topBand, bandFill, UI.LIFT)
  local topLine = UI.line(P, true)
  topLine:SetPoint("TOPLEFT", 1, -TOP_H)
  topLine:SetPoint("TOPRIGHT", -1, -TOP_H)
  local footBand = P:CreateTexture(nil, "BACKGROUND", nil, -7)
  footBand:SetPoint("BOTTOMLEFT", 1, 1)
  footBand:SetPoint("BOTTOMRIGHT", -1, 1)
  footBand:SetHeight(FOOT_H - 1)
  UI.shade(footBand, bandFill, UI.LIFT)
  local footLine = UI.line(P, true)
  footLine:SetPoint("BOTTOMLEFT", 1, FOOT_H)
  footLine:SetPoint("BOTTOMRIGHT", -1, FOOT_H)

  -- A money value starts big and steps down a size until all of it fits its block: never cut off, even in
  -- thousands of gold.
  local FIT = { "big", "title", "body", "small" }
  local function fit(fs)
    for _, kind in ipairs(FIT) do
      fs:SetFontObject(UI.fontObject(kind))
      local w = fs.GetUnboundedStringWidth and fs:GetUnboundedStringWidth() or fs:GetStringWidth()
      if (w or 0) <= fs.edbFitW then return end
    end
  end
  -- label 10 px at the top, value 15 px from 14 px down, note 11 px from 34 px down (two lines at most)
  local function stat(text, w)
    local b = CreateFrame("Frame", nil, P)
    b:SetSize(w, 58)
    b.label = UI.label(b, text)
    b.label:SetPoint("TOPLEFT", 0, 0)
    b.value = UI.text(b, "big")
    b.value:SetPoint("TOPLEFT", 0, -14)
    b.value:SetWidth(w)
    b.value.edbFitW = w
    hooksecurefunc(b.value, "SetText", fit)
    b.note = UI.text(b, "mute")
    b.note:SetPoint("TOPLEFT", 0, -34)
    b.note:SetWidth(w)
    b.note:SetWordWrap(true)
    if b.note.SetMaxLines then b.note:SetMaxLines(2) end
    return b
  end

  ---------------------------------------------------------------- the item band
  -- the 30-day low at the right edge, what a vendor pays left of it: the first two things to weigh before posting
  local sp = needs(stat("30-DAY LOW", STAT_W))
  sp:SetPoint("TOPRIGHT", -12, -12)
  local vb = needs(stat("SELLS TO VENDOR", STAT_W))
  vb:SetPoint("TOPRIGHT", sp, "TOPLEFT", -12, 0)
  f.vendorPrice, f.vendorNote = vb.value, vb.note
  vb:EnableMouse(true)
  UI.tip(vb, "Sells to vendor", "What a vendor pays for one, right now and with no fee. If it is close to what the "
    .. "auction house gets you after its cut, selling to a vendor is the safer choice: no deposit to lose, no wait.")

  f.icon = UI.icon(P, 40)
  f.icon:SetPoint("TOPLEFT", 12, -14)
  f.name = UI.text(P, "big")   -- one line: a long name ends in "...", the tooltip has all of it
  f.name:SetPoint("TOPLEFT", 62, -15)
  f.name:SetWordWrap(false)
  f.sub = UI.text(P, "dim")
  f.sub:SetPoint("TOPLEFT", f.name, "BOTTOMLEFT", 0, -6)
  f.sub:SetWordWrap(true)
  if f.sub.SetMaxLines then f.sub:SetMaxLines(3) end
  -- the name and the line under it stop before the stat blocks, or run the whole width when there's no item
  local function nameRoom(on)
    f.name:SetPoint("RIGHT", on and vb or P, on and "LEFT" or "RIGHT", -12, 0)
    f.sub:SetPoint("RIGHT", on and vb or P, on and "LEFT" or "RIGHT", -12, 0)
  end
  nameRoom(true)
  hooksecurefunc(vb, "SetShown", function(_, on) nameRoom(on) end)

  -- the picked item's tooltip on the icon and the name, like anywhere else in the game (vendor price included)
  local hover = needs(CreateFrame("Frame", nil, P))
  hover:SetPoint("TOPLEFT", f.icon, "TOPLEFT")
  hover:SetPoint("BOTTOMRIGHT", f.sub, "BOTTOMRIGHT")
  hover:EnableMouse(true)
  hover:SetScript("OnEnter", function(self)
    local g = S.sel
    if not g then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    if not (g.link and pcall(GameTooltip.SetHyperlink, GameTooltip, g.link)) then pcall(GameTooltip.SetItemByID, GameTooltip, g.id) end
    GameTooltip:Show()
  end)
  hover:SetScript("OnLeave", function() GameTooltip:Hide() end)

  -- the 30-day chart is the low's note: one 3 px bar per day on a base line, in the note's 12 px
  local base = UI.line(sp, true)
  base:SetPoint("TOPLEFT", 0, -46)
  base:SetWidth(30 * SPARK_PITCH - 1)
  sp.bars = {}
  for i = 1, 30 do
    local b = sp:CreateTexture(nil, "ARTWORK")
    b:SetWidth(SPARK_PITCH - 1)
    b:SetPoint("BOTTOMLEFT", sp, "TOPLEFT", (i - 1) * SPARK_PITCH, -46)
    b:Hide()
    sp.bars[i] = b
  end
  sp.stats = sp.value
  sp:EnableMouse(true)
  -- hovering shows the day under the pointer (its bar lights up) and the 30-day low, median and high
  local function hovered(self)
    local x = GetCursorPosition() / self:GetEffectiveScale() - (self:GetLeft() or 0)
    local i = math.floor(x / SPARK_PITCH) + 1
    local first = ns.today() - 29
    for _, h in ipairs(self.data or {}) do
      if h[1] - first + 1 == i then return h, i end
    end
  end
  local function showTip(self)
    local h, i = hovered(self)
    if h == self.tipDay and self.tipShown then return end
    self.tipDay, self.tipShown = h, true
    for k, bar in ipairs(self.bars) do
      if bar:IsShown() then bar:SetColorTexture(unpack(k == i and T.text or k == 30 and T.accent or T.edgeHi)) end
    end
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    if h then
      local d = ns.today() - h[1]
      GameTooltip:SetText(money(h[2]), 1, 1, 1)
      GameTooltip:AddLine(d == 0 and "Lowest today" or d == 1 and "Lowest yesterday" or ("Lowest %d days ago"):format(d),
        T.dim[1], T.dim[2], T.dim[3])
    else
      GameTooltip:SetText("Lowest price per day", 1, 1, 1)
    end
    GameTooltip:AddDoubleLine("30-day low", money(self.lo), T.dim[1], T.dim[2], T.dim[3], 1, 1, 1)
    GameTooltip:AddDoubleLine("Median", money(self.med), T.dim[1], T.dim[2], T.dim[3], 1, 1, 1)
    GameTooltip:AddDoubleLine("Highest", money(self.hi), T.dim[1], T.dim[2], T.dim[3], 1, 1, 1)
    GameTooltip:AddLine(("%d of the last 30 days, from your scans and searches."):format(#self.data), T.mute[1], T.mute[2], T.mute[3], true)
    GameTooltip:Show()
  end
  sp:SetScript("OnEnter", function(self)
    if not self.data or #self.data == 0 then return end
    self.tipShown = false
    showTip(self)
    self:SetScript("OnUpdate", showTip)
  end)
  sp:SetScript("OnLeave", function(self)
    self:SetScript("OnUpdate", nil)
    GameTooltip:Hide()
    drawHistory()
  end)
  f.spark = sp

  ---------------------------------------------------------------- your auction
  -- In the order of Blizzard's own Sell frame, as a grid: Quantity and Unit price on the left, Duration and Undercut
  -- by on the right. Every label is the same dim text, centred on its control's row.
  local section = needs(UI.label(P, "YOUR AUCTION"))
  section:SetPoint("TOPLEFT", LAB_X, SECT)
  section:SetTextColor(unpack(PLACE))
  local function lab(text, anchor, x, y)
    local l = needs(UI.text(P, "dim"))
    l:SetPoint("LEFT", anchor, anchor == P and "TOPLEFT" or "LEFT", x, y or 0)
    l:SetText(text)
    return l
  end

  -- quantity: a box and Max (everything of it in your bags)
  lab("Quantity", P, LAB_X, ROW1 - 12)
  f.qty = needs(UI.input(P, 64, 24, { numeric = true, right = true, max = 6 }))
  f.qty:SetPoint("TOPLEFT", CTL_X, ROW1)
  f.qty:HookScript("OnTextChanged", function(self, user)
    if not user then return end
    local n = tonumber(self:GetText())
    if n then
      S.qty = clamp(n, 0, S.avail or 0)
      updateTotals()
    end
  end)
  f.qty:HookScript("OnEditFocusLost", function(self) setQty(tonumber(self:GetText()) or 1) end)
  f.all = needs(UI.button(P, "Max", 52, 24, "small"))
  f.all:SetPoint("LEFT", f.qty, "RIGHT", 4, 0)
  f.all:SetScript("OnClick", function() setQty(S.avail or 1) end)
  UI.tip(f.all, "Max", function() return ("Sell all %s in your bags."):format(num(S.avail or 0)) end)
  -- one short line, for stackable goods only: they go up as one listing that buyers take any amount of
  f.qtyNote = UI.text(P, "mute")
  f.qtyNote:SetPoint("TOPLEFT", CTL_X, ROW1 - 28)

  -- unit price: gold, silver and copper boxes, each with its coin inside, like Blizzard's money input
  lab("Unit price", P, LAB_X, ROW2 - 12)
  local function coinBox(w, max, file)
    local e = needs(UI.input(P, w, 24, { numeric = true, right = true, max = max }))
    e:SetTextInsets(7, 22, 0, 0)   -- the digits stop short of the coin
    local icon = e:CreateTexture(nil, "OVERLAY")
    icon:SetSize(13, 13)
    icon:SetPoint("RIGHT", -6, 0)
    icon:SetTexture(file)
    return e
  end
  f.gold = coinBox(84, 7, "Interface\\MoneyFrame\\UI-GoldIcon")
  f.gold:SetPoint("TOPLEFT", CTL_X, ROW2)
  f.silver = coinBox(50, 2, "Interface\\MoneyFrame\\UI-SilverIcon")
  f.silver:SetPoint("LEFT", f.gold, "RIGHT", 4, 0)
  -- copper: shown only where the auction house takes copper (showCopper); not in needs, showCopper decides
  f.copper = coinBox(50, 2, "Interface\\MoneyFrame\\UI-CopperIcon")
  f.needItem[#f.needItem] = nil
  f.copper:SetPoint("LEFT", f.silver, "RIGHT", 4, 0)
  local function typed(_, user)
    if not user then return end
    S.userPrice = true
    S.unit = (tonumber(f.gold:GetText()) or 0) * 10000 + math.min(99, tonumber(f.silver:GetText()) or 0) * 100
      + (f.copper:IsShown() and math.min(99, tonumber(f.copper:GetText()) or 0) or 0)
    S.source = "Your price."
    updateTotals()
  end
  f.gold:HookScript("OnTextChanged", typed)
  f.silver:HookScript("OnTextChanged", typed)
  f.copper:HookScript("OnTextChanged", typed)
  f.gold:SetScript("OnTabPressed", function() f.silver:SetFocus() end)
  f.silver:SetScript("OnTabPressed", function() if f.copper:IsShown() then f.copper:SetFocus() else f.gold:SetFocus() end end)
  f.copper:SetScript("OnTabPressed", function() f.gold:SetFocus() end)

  -- where the price comes from, right under it: up to three lines (a deposit warning is long), red when it warns
  f.source = needs(UI.text(P, "mute"))
  f.source:SetPoint("TOPLEFT", CTL_X, ROW2 - 29)
  f.source:SetPoint("RIGHT", P, "RIGHT", -12, 0)
  f.source:SetWordWrap(true)
  if f.source.SetMaxLines then f.source:SetMaxLines(3) end

  -- duration: three buttons ending at the right edge; the picked one lights up in Quick sell's colour (a choice, not
  -- a money action)
  f.durs = {}
  for k, d in ipairs(DURATIONS) do
    local b = needs(UI.button(P, d[2], 40, 24, "small"))
    b:SetPoint("TOPRIGHT", -12 - (#DURATIONS - k) * 44, ROW1)
    UI.place(b, "sell")
    b.dur = d[1]
    b:SetScript("OnClick", function() setDur(d[1]) end)
    f.durs[k] = b
  end
  lab("Duration", f.durs[1], -RLAB_W)

  -- undercut, under the first duration button
  f.cut = needs(UI.input(P, 76, 24, { hint = "1s or 5%", max = 10 }))
  f.cut:SetPoint("TOPLEFT", f.durs[1], "TOPLEFT", 0, ROW2 - ROW1)
  lab("Undercut by", f.cut, -RLAB_W)
  f.cut:SetText(undercutShort())
  f.cut:SetScript("OnEnterPressed", function(self)
    local okSet, why = setUndercut(self:GetText())
    if okSet then
      setStatus("Undercut set to " .. undercutText() .. stepNote() .. ".", T.good)
      S.userPrice = false
      applySuggestion()
      if ns.optionsRefresh then ns.optionsRefresh() end
    else
      setStatus(why, T.bad)
    end
    self:ClearFocus()
  end)
  f.cut:HookScript("OnEditFocusLost", function(self) self:SetText(undercutShort()) end)
  UI.tip(f.cut, "How far under the cheapest auction", function()
    return "1s, 50c, 1c, 1g, 5%, or 0 to match it. Press Enter to keep it."
      .. (priceStep() > 1 and " This auction house only takes whole silver, so prices round down to it." or "")
  end)

  -- back to the automatic price: a small text link at the right of the section's title, shown only once you've set
  -- your own (updateTotals)
  local back = CreateFrame("Button", nil, P)
  back:SetPoint("RIGHT", P, "TOPRIGHT", -12, SECT - 5)
  back:SetHeight(14)
  back.text = UI.text(back, "small")
  back.text:SetPoint("RIGHT")
  back.text:SetJustifyH("RIGHT")
  back.text:SetText("Undercut cheapest")
  back.text:SetTextColor(unpack(PLACE))
  back:SetWidth(math.max(60, math.ceil(back.text:GetStringWidth() or 0) + 2))
  back:SetScript("OnClick", function()
    S.userPrice = false
    applySuggestion()
  end)
  back:HookScript("OnEnter", function() back.text:SetTextColor(unpack(T.text)) end)
  back:HookScript("OnLeave", function() back.text:SetTextColor(unpack(PLACE)) end)
  UI.tip(back, "Undercut cheapest", function()
    return ("Sets the price to the cheapest live auction minus your undercut (%s)."):format(undercutText())
  end)
  back:Hide()
  f.suggest = back

  ---------------------------------------------------------------- the summary band
  -- Deposit, Total price and You get as three equal stat blocks, Post at the right, all centred in the band
  local function summary(text, k)
    local b = needs(stat(text, FOOT_W))
    b:SetPoint("TOPLEFT", P, "BOTTOMLEFT", 12 + (k - 1) * (FOOT_W + 12), FOOT_H / 2 + 23)
    return b
  end
  f.deposit = summary("DEPOSIT", 1).value
  f.total = summary("TOTAL PRICE", 2).value
  -- what you actually get when it sells: the total minus the auction house's cut, the cut in the note
  local net = summary("YOU GET", 3)
  f.net, f.netNote = net.value, net.note

  f.post = UI.button(P, "Post", 120, 30, "primary")
  f.post:SetPoint("RIGHT", P, "BOTTOMRIGHT", -12, FOOT_H / 2)
  f.post:SetScript("OnClick", post)

  -- the server's "are you sure" about a post
  local cf = UI.panel(CreateFrame("Frame", nil, P), T.raised, T.accent)
  cf:SetPoint("BOTTOMLEFT", 8, 8)
  cf:SetPoint("BOTTOMRIGHT", -8, 8)
  cf:SetHeight(38)
  cf:SetFrameLevel(P:GetFrameLevel() + 10)
  cf:EnableMouse(true)
  cf:Hide()
  local ct = UI.text(cf, "small")
  ct:SetPoint("LEFT", 10, 0)
  ct:SetText("The auction house asks you to confirm this post.")
  local yes = UI.button(cf, "Post anyway", 100, 24, "primary")
  yes:SetPoint("RIGHT", -8, 0)
  yes:SetScript("OnClick", confirmPost)
  local no = UI.button(cf, "Don't", 60, 24)
  no:SetPoint("RIGHT", yes, "LEFT", -6, 0)
  no:SetScript("OnClick", function()
    S.warned = nil
    cf:Hide()
    setStatus("Not posted.", T.dim)
    updateTotals()
  end)
  f.confirm = cf

  ------------------------------------------------------------------------------------------------ lists (lower right)
  local Lw = UI.panel(CreateFrame("Frame", nil, f), UI.tint(T.surface, PLACE, UI.WASH_INNER), UI.tint(T.edge, PLACE, UI.WASH_EDGE))
  Lw:SetPoint("TOPLEFT", P, "BOTTOMLEFT", 0, -8)
  Lw:SetPoint("BOTTOMRIGHT", -8, 30)
  f.curBtn = UI.button(Lw, "Current auctions", 128, 22, "small")
  UI.place(f.curBtn, "sell")   -- the view toggles light up in Quick sell's colour, not the gold of an action
  f.curBtn:SetPoint("TOPLEFT", 10, -8)
  f.curBtn:SetScript("OnClick", function() setView("cur") end)
  f.ownBtn = UI.button(Lw, "Your auctions", 112, 22, "small")
  UI.place(f.ownBtn, "sell")
  f.ownBtn:SetPoint("LEFT", f.curBtn, "RIGHT", 4, 0)
  f.ownBtn:SetScript("OnClick", function() setView("own") end)
  local refresh = UI.button(Lw, "Refresh", 70, 22, "small")
  refresh:SetPoint("TOPRIGHT", -10, -8)
  refresh:SetScript("OnClick", function()
    if S.view == "own" then
      wipe(Live.cache)
      wipe(Live.byId)
      wipe(Live.failed)
      queryOwned()
    elseif S.sel then
      Live.cache[S.sel.ckey or ""] = nil
      Live.failed[S.sel.ckey or ""] = nil
      renderCurrent()
      request(S.sel.itemKey, S.sel.commodity, true)
    end
  end)
  f.cutNext = UI.button(Lw, "Cancel undercut", 140, 22, "small danger")
  f.cutNext:SetPoint("LEFT", f.ownBtn, "RIGHT", 12, 0)
  f.cutNext:SetScript("OnClick", function() cancelAuction(nextUndercut()) end)
  UI.tip(f.cutNext, "Cancel your next undercut auction", function()
    local a = nextUndercut()
    if not a then return "None of your auctions is undercut right now." end
    local cost = try(AH.GetCancelCost, a.id)
    return ("%s, at %s.%s One click cancels one auction."):format(a.name, a.unit and money(a.unit) or "-",
      (cost and cost > 0) and (" Costs " .. money(cost) .. ".") or "")
  end)
  f.cutNext:Hide()
  f.info = UI.text(Lw, "mute")
  f.info:SetPoint("RIGHT", refresh, "LEFT", -10, 0)
  f.info:SetJustifyH("RIGHT")

  local function band(cols)
    local bd = UI.headerBand(Lw, 20)
    bd:SetPoint("TOPLEFT", 1, -38)
    bd:SetPoint("TOPRIGHT", -1, -38)
    for _, c in ipairs(cols) do
      local l = UI.label(bd, c[1])
      if c[3] then
        l:SetPoint("RIGHT", bd, "RIGHT", c[2], 0)
        l:SetJustifyH("RIGHT")
      else
        l:SetPoint("LEFT", bd, "LEFT", c[2], 0)
      end
    end
    return bd
  end
  f.curBand = band({ { "PRICE EACH", 12 }, { "AVAILABLE", -116, true }, { "TIME LEFT", -26, true } })
  f.cur = UI.list(Lw, LIST_ROW, buildCurRow, fillCurRow)
  f.cur:SetPoint("TOPLEFT", 1, -58)
  f.cur:SetPoint("BOTTOMRIGHT", -3, 4)
  -- rows stop 18 px short of the band (the scroll bar): the labels sit over the columns' right edges
  f.ownBand = band({ { "ITEM", 30 }, { "QUANTITY", -300, true }, { "PRICE EACH", -180, true }, { "STATUS", -98, true } })
  f.own = UI.list(Lw, LIST_ROW, buildOwnRow, fillOwnRow)
  f.own:SetPoint("TOPLEFT", 1, -58)
  f.own:SetPoint("BOTTOMRIGHT", -3, 4)

  ------------------------------------------------------------------------------------------------ footer
  f.status = UI.text(f, "dim")
  f.status:SetPoint("BOTTOMLEFT", 12, 9)
  f.status:SetPoint("RIGHT", f, "RIGHT", -12, 0)

  f:SetScript("OnShow", function()
    f.cut:SetText(undercutShort())
    collect()
    renderBags()
    updatePost()
    setView(S.view)
    queryOwned()
  end)
  return f
end

---------------------------------------------------------------------------------------------------------------------
-- The tab under the auction house, after Blizzard's tabs

local function blizzardTabs(selectCurrent)
  local ah = _G.AuctionHouseFrame
  for _, t in ipairs(ah and ah.Tabs or {}) do
    if selectCurrent and ah.selectedTab and t.GetID and t:GetID() == ah.selectedTab then
      pcall(PanelTemplates_SelectTab, t)
    else
      pcall(PanelTemplates_DeselectTab, t)
    end
  end
end

ns.blizzardTabs = blizzardTabs

-- The window's title while one of our tabs is open ("Quick sell", "Shopping"), and Blizzard's own back when it closes
-- (its tab click doesn't set the title again when its view didn't change underneath ours).
function ns.ahTitle(text, color)
  local ah = _G.AuctionHouseFrame
  if not ah then return end
  if text then
    if ah.SetTitle then pcall(ah.SetTitle, ah, color and (ns.UI.hex(color) .. text .. "|r") or text) end
  elseif ah.UpdateTitle then
    pcall(ah.UpdateTitle, ah)
  end
end

local function closeSelling()
  if not S.frame or not S.frame:IsShown() then return end
  S.frame:Hide()
  if S.tab then pcall(PanelTemplates_DeselectTab, S.tab) end
  blizzardTabs(true)
  ns.ahTitle(nil)
end
ns.closeSelling = closeSelling

local function openSelling()
  local f = makeFrame()
  if not f then return end
  if ns.closeSearch then ns.closeSearch() end
  if ns.closeOthers then ns.closeOthers("selling") end
  blizzardTabs(false)
  if S.tab then pcall(PanelTemplates_SelectTab, S.tab) end
  ns.raise(f)
  f:Show()
  ns.ahTitle("Quick sell", ns.T.places.sell)
  if PlaySound and SOUNDKIT and SOUNDKIT.IG_CHARACTER_INFO_TAB then pcall(PlaySound, SOUNDKIT.IG_CHARACTER_INFO_TAB) end
end
ns.openSelling = openSelling

-- Puts one of our full panels above everything Blizzard shows in the auction house (its buy and sell views sit at
-- high frame levels, and a panel under them opens invisibly). Called on every open, since Blizzard's levels change.
function ns.raise(f)
  local ah = _G.AuctionHouseFrame
  if not (f and ah) then return end
  local top = ah:GetFrameLevel()
  local function walk(frame, depth)
    for _, c in ipairs({ frame:GetChildren() }) do
      if c ~= f and c:IsShown() then
        top = math.max(top, c:GetFrameLevel())
        if depth < 3 then walk(c, depth + 1) end
      end
    end
  end
  walk(ah, 1)
  f:SetFrameStrata(ah:GetFrameStrata())
  f:SetFrameLevel(math.min(top + 20, 9000))
end

-- A tab after Blizzard's (and after any tab made before it), selected in its place's colour. Shared with Shopping.lua.
function ns.makeTab(name, text, onClick, onBlizzard, place)
  local ah = _G.AuctionHouseFrame
  if not ah then return nil end
  local tabsList = ah.Tabs or {}
  local last = ns.lastTab or tabsList[#tabsList] or ah.AuctionsTab
  if not last then return nil end
  local okTab, tab = pcall(CreateFrame, "Button", name, ah, "PanelTabButtonTemplate")
  local templated = okTab and tab ~= nil
  if not templated then tab = UI.button(ah, text, 90, 26) end
  tab:SetID(100)
  if place then UI.place(tab, place) end
  tab:SetText(text)
  if templated then
    -- sized like Blizzard's own auction house tabs (their padding and smallest width), also when the template sizes
    -- it again on show or a screen size change, so the name never runs to the tab's edges
    local function size(self) pcall(PanelTemplates_TabResize, self, 20, nil, 70) end
    size(tab)
    tab:HookScript("OnShow", size)
    tab:HookScript("OnEvent", size)
  end
  tab:SetPoint("LEFT", last, "RIGHT", templated and -15 or 4, 0)
  tab:SetScript("OnClick", onClick)
  if templated then pcall(PanelTemplates_DeselectTab, tab) end
  ns.lastTab = tab
  -- Blizzard's tabs (and anything that switches its view) close ours. The tab template adds every new tab, ours too,
  -- to ah.Tabs, so only tabs that aren't ours get the hook: hooking our own made each click open and close at once.
  ns.ourTabs = ns.ourTabs or {}
  ns.ourTabs[tab] = true
  for _, t in ipairs(tabsList) do
    if not ns.ourTabs[t] then t:HookScript("OnClick", onBlizzard) end
  end
  if ah.SetDisplayMode then hooksecurefunc(ah, "SetDisplayMode", onBlizzard) end
  if ns.applySkin then ns.applySkin() end
  return tab
end

local function makeTab()
  if S.tab then return end
  S.tab = ns.makeTab("EverlookAuctionsSellingTab", "Quick sell", openSelling, closeSelling, "sell")
end

---------------------------------------------------------------------------------------------------------------------
-- Events and commands

local events = {}

function events.AUCTION_HOUSE_SHOW()
  -- the auction house UI is made on this same event (sometimes a frame later)
  C_Timer.After(0.2, function()
    hookSellFrames()
    makeTab()
    makeFrame()
  end)
end

function events.AUCTION_HOUSE_CLOSED()
  -- closed with Quick sell open: put Blizzard's tab and title back, or the next visit opens with no tab selected
  -- (Blizzard doesn't select its tab again when its view is still the same one)
  closeSelling()
  if S.frame then S.frame:Hide() end
  if S.tab then pcall(PanelTemplates_DeselectTab, S.tab) end
  -- live prices are only shown while fresh: the next visit asks again
  wipe(Live.cache)
  wipe(Live.byId)
  wipe(Live.jobs)
  wipe(Live.failed)
  S.posting, S.warned, S.sel, S.cancelPending, S.advance = nil, nil, nil, nil, nil
  -- your auctions are asked for again next visit; until the answer the list says so instead of showing old ones
  S.owned, S.ownedLoaded = {}, nil
  if S.frame then S.frame.confirm:Hide() end
end

function events.BAG_UPDATE_DELAYED() refreshBags() end


function events.OWNED_AUCTIONS_UPDATED()
  if not S.frame or not S.frame:IsShown() then return end
  S.ownedLoaded = true
  readOwned()
  renderOwned()
  checkOwned()
end

local function posted(job)
  S.posting = nil
  S.advance = job.key   -- when that was the last of it, the next item in the list gets picked
  setStatus(("Posted %s x %s at %s each."):format(num(job.qty), job.name, money(job.unit)), T.good)
  updateTotals()
  queryOwned()
  -- the new auction shows in the list after a moment
  C_Timer.After(0.5, function()
    if S.sel and S.sel.id == job.id and S.frame:IsShown() then request(S.sel.itemKey, S.sel.commodity, true) end
  end)
end

function events.AUCTION_HOUSE_AUCTION_CREATED()
  local job = S.posting
  if not job then return end
  if not job.multi then posted(job); return end
  -- one auction of a multisell is up; AUCTION_MULTISELL_UPDATE counts them when the client sends it
  job.heard, job.created = GetTime(), (job.created or 0) + 1
  if not job.counted then
    job.multi[1] = math.min(job.created, job.multi[2])
    if job.multi[1] >= job.multi[2] then posted(job); return end
  end
  updateTotals()
end

function events.AUCTION_MULTISELL_START(total)
  local job = S.posting
  if not job then return end
  job.multi, job.heard, job.counted = { 0, tonumber(total) or job.qty }, GetTime(), true
  updateTotals()
end

function events.AUCTION_MULTISELL_UPDATE(done, total)
  local job = S.posting
  if not job then return end
  job.multi, job.heard, job.counted = { tonumber(done) or 0, tonumber(total) or job.qty }, GetTime(), true
  if job.multi[1] >= job.multi[2] then posted(job) else updateTotals() end
end

function events.AUCTION_MULTISELL_FAILURE()
  local job = S.posting
  if not job then return end
  S.posting = nil
  local done = job.multi and job.multi[1] or 0
  setStatus(("Posting stopped after %d of %d."):format(done, job.qty), T.bad)
  updateTotals()
  queryOwned()
end

function events.AUCTION_HOUSE_POST_WARNING()
  if S.posting and S.frame and S.frame:IsShown() then askConfirm(S.posting) end
  if not S.warned then return end
  -- Blizzard shows its own confirm for this warning too (now or a moment later), and its Accept would act on its own,
  -- empty sell frame: only ours stays
  local function hide() if S.warned and StaticPopup_Hide then pcall(StaticPopup_Hide, "AUCTION_HOUSE_POST_WARNING") end end
  hide()
  C_Timer.After(0, hide)
  C_Timer.After(0.2, hide)
end

function events.AUCTION_HOUSE_POST_ERROR()
  if not S.posting then return end
  S.posting = nil
  setStatus("The post didn't go through.", T.bad)
  updateTotals()
end

function events.AUCTION_CANCELED()
  S.cancelPending = nil
  if not S.frame or not S.frame:IsShown() then return end
  setStatus("Auction cancelled.", T.good)
  queryOwned()
end

local ev = CreateFrame("Frame")
for e in pairs(events) do pcall(ev.RegisterEvent, ev, e) end   -- some events may not exist in this client
ev:SetScript("OnEvent", function(_, e, ...) events[e](...) end)

local prevSlash, prevHelp = ns.slash, ns.help
function ns.slash(msg)
  if msg == "sell" or msg == "selling" or msg == "quicksell" or msg == "quick sell" then
    if _G.AuctionHouseFrame and AuctionHouseFrame:IsShown() then
      makeTab()
      openSelling()
    else
      ns.say("open the auction house first.")
    end
    return true
  end
  local arg = msg:match("^undercut%s*(.*)$")
  if not arg then return prevSlash and prevSlash(msg) or false end
  if arg == "" then
    ns.say("undercut is " .. undercutText() .. stepNote() .. ". Set it with /eah undercut 1s, 50c, 1g, 5% or 0, for example /eah undercut 1c.")
    return true
  end
  local okSet, why = setUndercut(arg)
  if not okSet then
    ns.say(why)
    return true
  end
  if ns.undercutChanged then ns.undercutChanged() end
  ns.say("undercut set to " .. undercutText() .. stepNote() .. ".")
  return true
end

-- The undercut changed (here, by /eah undercut or in the options): the open Quick sell and options show it, and a
-- price that wasn't typed by hand follows it.
function ns.undercutChanged()
  if S.frame then
    S.frame.cut:SetText(undercutShort())
    if S.frame:IsShown() then applySuggestion() end
  end
  if ns.optionsRefresh then ns.optionsRefresh() end
end

function ns.help()
  if prevHelp then prevHelp() end
  print("  /eah sell  open the Quick sell tab (auction house open)")
  print(("  /eah undercut 1s, 50c, 5%% or 0  how far under the cheapest auction to price (now %s)"):format(undercutText()))
end
