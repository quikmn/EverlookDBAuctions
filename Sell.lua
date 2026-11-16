-- EverlookDB Auctions: selling.
--   Selling tab  a tab on the auction house with everything in your bags you can sell on the left, a post panel
--                (quantity, unit price, total, duration, deposit, 30-day price chart) and the live auctions for the
--                picked item, and your own auctions with a Cancel button each. Each item's last price, quantity
--                and duration are remembered. Right-click an item to make it a favourite (kept at the top);
--                Shift+right-click hides it.
--   Price        the cheapest auction someone else has up, lowered by your undercut (1 silver unless you set
--                another, in the tab or with /eah undercut). Your own auctions are matched, never undercut. When
--                nobody else is selling, your last price for the item, or else the typical price from the last
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

local function sdb()
  local db = ns.db()
  if not db then return nil end
  db.sell = db.sell or {}
  local s = db.sell
  s.memory = s.memory or {}
  s.fav = s.fav or {}
  s.hidden = s.hidden or {}
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
    local copper = parseMoney(arg)
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

-- Nobody is selling it right now: fill in the scan's typical price (only over Blizzard's default guess).
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
              count = 0, slots = {}, scan = row and (row.med or row.low),
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
  g.itemKey = (g.loc and try(AH.GetItemKeyFromItem, g.loc)) or try(AH.MakeItemKey, g.id, 0, 0, 0)
  g.ckey = ckey(g.itemKey)
  local info = ns.itemInfo and ns.itemInfo(g.id)
  g.vendor = info and info[9] or 0
  g.de = ns.disenchantValue and ns.disenchantValue(g.id)
end

local function available(g)
  local n = g.loc and try(AH.GetAvailablePostCount, g.loc)
  return (n and n > 0) and n or g.count
end

---------------------------------------------------------------------------------------------------------------------
-- Live auctions, one item at a time (the server answers one search at a time)
-- cache[ckey] = { rows = { { unit, qty, others (not yours), mine, left, band } }, lowestOther, lowestMine, at }

local Live = { cache = {}, byId = {}, queue = {}, busy = nil }
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
  return rows, try(AH.HasFullCommoditySearchResults, id)
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
  return rows, try(AH.HasFullItemSearchResults, k)
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

local pump

ns.sellBusy = function() return Live.busy ~= nil end   -- the shared queue waits for these too

local function finish()
  Live.busy = nil
  C_Timer.After(0.1, pump)
end

function pump()
  if Live.busy or #Live.queue == 0 then return end
  local ah = ns.ahFrame()
  if not ah or not ah:IsShown() then wipe(Live.queue); return end
  -- one search at a time across the addon: wait while the shared queue (AHQuery.lua) has one out
  if (AH.IsThrottledMessageSystemReady and not AH.IsThrottledMessageSystemReady()) or (ns.ahq and ns.ahq.busy) then
    C_Timer.After(0.3, pump)
    return
  end
  local job = table.remove(Live.queue, 1)
  local send = AH.SendSellSearchQuery or AH.SendSearchQuery
  Live.busy = job
  if not send or not pcall(send, job.key, SORTS, true) then
    Live.busy = nil
    C_Timer.After(0.1, pump)
    return
  end
  -- no answer in time: move on
  C_Timer.After(5, function() if Live.busy == job then finish() end end)
end

-- Looks up an item's live auctions (searches only: nothing is bought or posted); `front` puts it first.
local function request(k, commodity, front)
  local c = ckey(k)
  if not c then return end
  if Live.busy and Live.busy.c == c then return end
  for i, j in ipairs(Live.queue) do
    if j.c == c then
      if not front then return end
      table.remove(Live.queue, i)
      break
    end
  end
  local job = { key = k, c = c, commodity = commodity }
  if front then table.insert(Live.queue, 1, job) else Live.queue[#Live.queue + 1] = job end
  pump()
end

local function onCommodityResults(itemID)
  local b = Live.busy
  local k, c
  if b and b.commodity and b.key.itemID == itemID then k, c = b.key, b.c
  elseif S.sel and S.sel.commodity and S.sel.id == itemID and S.sel.itemKey then k, c = S.sel.itemKey, S.sel.ckey end
  if not k then return end
  store(k, c, true)
  if b and b.c == c then finish() end
  if onLive then onLive(c) end
end

local function onItemResults(itemKey)
  if type(itemKey) ~= "table" then return end
  local b = Live.busy
  local k, c
  if b and not b.commodity and b.key.itemID == itemKey.itemID then k, c = itemKey, b.c
  elseif S.sel and not S.sel.commodity and S.sel.ckey == ckey(itemKey) then k, c = itemKey, S.sel.ckey end
  if not k then return end
  store(k, c, false)
  if b and b.c == c then finish() end
  if onLive then onLive(c) end
end

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

-- "Undercut" (someone else is cheaper now), "Lowest", "Sold", or from the scan only "Maybe".
local function ownedState(a)
  if a.sold then return "Sold", T.good end
  local e = (a.ckey and Live.cache[a.ckey]) or (a.commodity and Live.byId[a.itemID])
  if e then
    if e.lowestOther and a.unit and e.lowestOther < a.unit then return "Undercut", T.bad, e.lowestOther end
    return "Lowest", T.good
  end
  local it = ns.houseItem(a.itemID)
  if it and it[1] and a.unit and it[1] < a.unit then return "Maybe", T.accent, it[1] end
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
      if not e or now - e.at > CHECK_AGAIN then request(a.key, a.commodity, false) end
    end
  end
end

---------------------------------------------------------------------------------------------------------------------
-- The Selling tab

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
    return
  end
  f.gold:SetText(tostring(math.floor(unit / 10000)))
  f.silver:SetText(tostring(math.floor(unit / 100) % 100))
end

-- Total, deposit, the price's source and the Post button.
local function updateTotals()
  local f, g = S.frame, S.sel
  if not f then return end
  local qty, unit = S.qty or 0, S.unit or 0
  if not g then
    f.total:SetText("-")
    f.deposit:SetText("-")
    f.source:SetText("")
    f.post:Disable()
    f.post:SetText("Post")
    return
  end
  f.total:SetText((unit > 0 and qty > 0) and money(unit * qty) or "-")
  local dep
  if g.commodity then dep = try(AH.CalculateCommodityDeposit, g.id, S.dur, qty)
  elseif g.loc then dep = try(AH.CalculateItemDeposit, g.loc, S.dur, qty) end
  f.deposit:SetText(dep and money(dep) or "-")
  -- the auction house keeps 5% of a sale (more at a neutral house): say so when a vendor or disenchanting pays more
  local net = math.floor(unit * 0.95)
  local warn
  if unit > 0 and (g.vendor or 0) > net then
    warn = ("A vendor pays %s each, more than this nets after the 5%% cut."):format(money(g.vendor))
  elseif unit > 0 and g.de and g.de > net then
    warn = ("Disenchanting is worth about %s, more than this nets after the 5%% cut."):format(money(g.de))
  end
  f.source:SetText(warn and (UI.hex(T.bad) .. warn .. "|r") or S.source or "")
  f.post:SetEnabled(not S.posting and not S.warned and qty >= 1 and qty <= (S.avail or 0) and unit >= 100)
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
  local e = g.ckey and Live.cache[g.ckey]
  if e and e.lowestOther and (not e.lowestMine or e.lowestOther < e.lowestMine) then
    local why = ("Undercuts the cheapest auction (%s) by %s."):format(money(e.lowestOther), undercutText())
    local usual = e.lone and e.usual
    if usual then why = why .. (" The cheapest is a lone one far under the usual %s."):format(money(usual)) end
    return undercutPrice(e.lowestOther), why
  end
  if e and e.lowestMine then
    return e.lowestMine, ("Matches your own cheapest auction (%s)."):format(money(e.lowestMine))
  end
  local lead = e and "Nobody else is selling this. " or ""
  local tail = e and "" or " Checking live auctions..."
  if mem and mem.p then return mem.p, lead .. "Your last price (" .. ns.ago(mem.at) .. ")." .. tail end
  if g.scan then return roundPrice(g.scan), lead .. "Typical price from the last full scan." .. tail end
  return nil, e and "Nobody is selling this. Set a price." or "Checking live auctions..."
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
  local e = g and g.ckey and Live.cache[g.ckey]
  if not g then
    f.cur.empty:SetText("Pick an item from your bags to see its auctions.")
  elseif not e then
    f.cur.empty:SetText("Checking live auctions...")
  else
    f.cur.empty:SetText("Nobody is selling this right now.")
  end
  f.cur:SetItems(e and e.rows or {})
  if S.view == "cur" then
    local up = 0
    for _, r in ipairs(e and e.rows or {}) do up = up + r.qty end
    f.info:SetText(e and ("%s auctions, %s up"):format(num(#e.rows), num(up)) or "")
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
  f.own.empty:SetText("You have no auctions up.")
  f.own:SetItems(S.owned)
  if S.view == "own" then
    local n, under = 0, 0
    for _, a in ipairs(S.owned) do
      if not a.sold then
        n = n + 1
        if ownedState(a) == "Undercut" then under = under + 1 end
      end
    end
    f.info:SetText(("%s up"):format(num(n)))
    f.cutNext:SetText(under > 0 and ("Undercut: cancel (%d)"):format(under) or "None undercut")
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
      b:SetHeight(3 + math.floor(frac * 22 + 0.5))
      b:SetColorTexture(unpack(h[1] == today and T.accent or T.edgeHi))
      b:Show()
    end
  end
  sp.stats:SetText(("low %s   median %s"):format(money(lo), money(med)))
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
    f.qty:SetText("")
    drawHistory()
    updateTotals()
    return
  end
  f.icon:EdbSet(g.icon, g.quality)
  f.name:SetText(qualityHex(g.quality) .. g.name .. "|r")
  f.name:SetTextColor(unpack(T.text))
  local bits = { num(g.count) .. " in your bags" }
  if g.maxStack > 1 then bits[#bits + 1] = "stacks of " .. g.maxStack end
  bits[#bits + 1] = g.commodity and "commodity" or "item"
  local s = sdb()
  local mem = s and s.memory[g.key]
  if mem and mem.p then bits[#bits + 1] = "last posted at " .. money(mem.p) end
  if g.de then bits[#bits + 1] = "disenchant ~" .. money(g.de) end
  f.sub:SetText(table.concat(bits, "   "))
  f.qty:SetText(tostring(S.qty or 1))
  f.stack:SetShown(g.maxStack > 1)
  if g.maxStack > 1 then f.stack:SetText("Stack " .. math.min(g.maxStack, S.avail or g.maxStack)) end
  f.all:SetText("All " .. num(S.avail or g.count))
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
  S.dur = (mem and mem.d) or (s and s.duration) or 2
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
  if qty < 1 or unit < 100 or qty > (S.avail or 0) then return end
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
    C_Timer.After(5, function() if S.cancelPending == mine then S.cancelPending = nil; renderOwned() end end)
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
    GameTooltip:SetBagItem(g.slots[1][1], g.slots[1][2])
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
    if r.others == 0 then
      S.unit = roundPrice(r.unit)
      S.source = ("Matches your auction at %s."):format(money(r.unit))
    else
      S.unit = undercutPrice(r.unit)
      S.source = ("Undercuts the auction you picked (%s) by %s."):format(money(r.unit), undercutText())
    end
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
  b.price:SetWidth(100)
  b.price:SetJustifyH("RIGHT")
  b.qty = UI.text(b, "dim")
  b.qty:SetPoint("RIGHT", b.price, "LEFT", -8, 0)
  b.qty:SetWidth(36)
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
    local state, _, lower = ownedState(a)
    if lower then GameTooltip:AddLine(("Cheapest other auction: %s"):format(money(lower)), T.bad[1], T.bad[2], T.bad[3]) end
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

local function label(parent, text, x, y)
  local l = UI.label(parent, text)
  l:SetPoint("TOPLEFT", x, y)
  return l
end

local function coin(parent, box, file)
  local t = parent:CreateTexture(nil, "ARTWORK")
  t:SetSize(12, 12)
  t:SetPoint("LEFT", box, "RIGHT", 4, 0)
  t:SetTexture(file)
  return t
end

local function makeFrame()
  local ah = _G.AuctionHouseFrame
  if S.frame or not ah then return S.frame end
  local f = UI.own(CreateFrame("Frame", "EverlookAuctionsSelling", ah))
  f:SetPoint("TOPLEFT", ah, "TOPLEFT", 2, -24)
  f:SetPoint("BOTTOMRIGHT", ah, "BOTTOMRIGHT", -2, (ns.BAR_H or 0) + 2)   -- the bar along the bottom stays visible
  f:SetFrameLevel(ah:GetFrameLevel() + 150)
  f:EnableMouse(true)
  UI.panel(f, T.bg, T.bg)
  f:Hide()
  S.frame = f

  ------------------------------------------------------------------------------------------------ bags (left)
  local left = UI.panel(CreateFrame("Frame", nil, f))
  left:SetPoint("TOPLEFT", 8, -8)
  left:SetPoint("BOTTOMLEFT", 8, 30)
  left:SetWidth(256)
  local title = UI.text(left, "title")
  title:SetPoint("TOPLEFT", 10, -10)
  title:SetText("Your bags")
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
  local P = UI.panel(CreateFrame("Frame", nil, f))
  P:SetPoint("TOPLEFT", left, "TOPRIGHT", 8, 0)
  P:SetPoint("TOPRIGHT", -8, -8)
  P:SetHeight(226)
  f.needItem = {}
  local function needs(w) f.needItem[#f.needItem + 1] = w; return w end

  f.icon = UI.icon(P, 44)
  f.icon:SetPoint("TOPLEFT", 12, -12)
  f.name = UI.text(P, "big")
  f.name:SetPoint("TOPLEFT", 66, -16)
  f.name:SetPoint("RIGHT", P, "RIGHT", -180, 0)
  f.sub = UI.text(P, "dim")
  f.sub:SetPoint("TOPLEFT", f.name, "BOTTOMLEFT", 0, -7)
  f.sub:SetPoint("RIGHT", P, "RIGHT", -180, 0)

  -- 30-day price chart
  local sp = needs(CreateFrame("Frame", nil, P))
  sp:SetPoint("TOPRIGHT", -12, -10)
  sp:SetSize(150, 48)
  local spl = UI.label(sp, "30-DAY LOW")
  spl:SetPoint("TOPLEFT", 0, 0)
  local base = UI.line(sp, true)
  base:SetPoint("BOTTOMLEFT", 0, 12)
  base:SetPoint("BOTTOMRIGHT", 0, 12)
  sp.bars = {}
  for i = 1, 30 do
    local b = sp:CreateTexture(nil, "ARTWORK")
    b:SetWidth(4)
    b:SetPoint("BOTTOMLEFT", (i - 1) * 5, 13)
    b:Hide()
    sp.bars[i] = b
  end
  sp.stats = UI.text(sp, "mute")
  sp.stats:SetPoint("BOTTOMLEFT", 0, -2)
  sp.stats:SetPoint("RIGHT", sp, "RIGHT", 0, 0)
  sp:EnableMouse(true)
  -- hovering shows the day under the pointer (its bar lights up) and the 30-day low, median and high
  local function hovered(self)
    local x = GetCursorPosition() / self:GetEffectiveScale() - (self:GetLeft() or 0)
    local i = math.floor(x / 5) + 1
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

  local div = UI.line(P, true)
  div:SetPoint("TOPLEFT", 1, -66)
  div:SetPoint("TOPRIGHT", -1, -66)

  -- quantity
  needs(label(P, "QUANTITY", 12, -78))
  local minus = needs(UI.button(P, "-", 24, 24))
  minus:SetPoint("TOPLEFT", 12, -92)
  minus:SetScript("OnClick", function() setQty((S.qty or 1) - 1) end)
  f.qty = needs(UI.input(P, 56, 24, { numeric = true, right = true, max = 6 }))
  f.qty:SetPoint("LEFT", minus, "RIGHT", 4, 0)
  f.qty:HookScript("OnTextChanged", function(self, user)
    if not user then return end
    local n = tonumber(self:GetText())
    if n then
      S.qty = clamp(n, 0, S.avail or 0)
      updateTotals()
    end
  end)
  f.qty:HookScript("OnEditFocusLost", function(self) setQty(tonumber(self:GetText()) or 1) end)
  local plus = needs(UI.button(P, "+", 24, 24))
  plus:SetPoint("LEFT", f.qty, "RIGHT", 4, 0)
  plus:SetScript("OnClick", function() setQty((S.qty or 0) + 1) end)
  f.stack = needs(UI.button(P, "Stack", 70, 24, "small"))
  f.stack:SetPoint("LEFT", plus, "RIGHT", 8, 0)
  f.stack:SetScript("OnClick", function() if S.sel then setQty(S.sel.maxStack) end end)
  UI.tip(f.stack, "One full stack")
  f.all = needs(UI.button(P, "All", 70, 24, "small"))
  f.all:SetPoint("LEFT", f.stack, "RIGHT", 4, 0)
  f.all:SetScript("OnClick", function() setQty(S.avail or 1) end)
  UI.tip(f.all, "Everything of this in your bags")

  -- duration
  needs(label(P, "DURATION", 330, -78))
  f.durs = {}
  for k, d in ipairs(DURATIONS) do
    local b = needs(UI.button(P, d[2], 52, 24, "small"))
    b:SetPoint("TOPLEFT", 330 + (k - 1) * 56, -92)
    b.dur = d[1]
    b:SetScript("OnClick", function() setDur(d[1]) end)
    f.durs[k] = b
  end

  -- unit price
  needs(label(P, "PRICE EACH", 12, -126))
  f.gold = needs(UI.input(P, 76, 24, { numeric = true, right = true, max = 7 }))
  f.gold:SetPoint("TOPLEFT", 12, -140)
  local gi = needs(coin(P, f.gold, "Interface\\MoneyFrame\\UI-GoldIcon"))
  f.silver = needs(UI.input(P, 40, 24, { numeric = true, right = true, max = 2 }))
  f.silver:SetPoint("LEFT", gi, "RIGHT", 6, 0)
  needs(coin(P, f.silver, "Interface\\MoneyFrame\\UI-SilverIcon"))
  local function typed(_, user)
    if not user then return end
    S.userPrice = true
    S.unit = (tonumber(f.gold:GetText()) or 0) * 10000 + math.min(99, tonumber(f.silver:GetText()) or 0) * 100
    S.source = "Your price."
    updateTotals()
  end
  f.gold:HookScript("OnTextChanged", typed)
  f.silver:HookScript("OnTextChanged", typed)
  f.gold:SetScript("OnTabPressed", function() f.silver:SetFocus() end)
  f.silver:SetScript("OnTabPressed", function() f.gold:SetFocus() end)

  local reset = needs(UI.button(P, "Suggest", 70, 24, "small"))
  reset:SetPoint("TOPLEFT", 196, -140)
  reset:SetScript("OnClick", function()
    S.userPrice = false
    applySuggestion()
  end)
  UI.tip(reset, "Back to the suggested price", "Just under the cheapest auction someone else has up.")

  -- undercut
  needs(label(P, "UNDERCUT BY", 330, -126))
  f.cut = needs(UI.input(P, 76, 24, { hint = "1s or 5%", max = 10 }))
  f.cut:SetPoint("TOPLEFT", 330, -140)
  f.cut:SetText(undercutShort())
  f.cut:SetScript("OnEnterPressed", function(self)
    local okSet, why = setUndercut(self:GetText())
    if okSet then
      setStatus("Undercut set to " .. undercutText() .. stepNote() .. ".", T.good)
      S.userPrice = false
      applySuggestion()
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

  -- where the price comes from, then total and deposit
  f.source = needs(UI.text(P, "mute"))
  f.source:SetPoint("TOPLEFT", 12, -170)
  f.source:SetPoint("RIGHT", P, "RIGHT", -12, 0)
  needs(label(P, "TOTAL", 12, -188))
  f.total = needs(UI.text(P, "big"))
  f.total:SetPoint("TOPLEFT", 12, -202)
  needs(label(P, "DEPOSIT", 150, -188))
  f.deposit = needs(UI.text(P, "body"))
  f.deposit:SetPoint("TOPLEFT", 150, -202)

  f.post = UI.button(P, "Post", 150, 30, "primary")
  f.post:SetPoint("BOTTOMRIGHT", -12, 12)
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
  local Lw = UI.panel(CreateFrame("Frame", nil, f))
  Lw:SetPoint("TOPLEFT", P, "BOTTOMLEFT", 0, -8)
  Lw:SetPoint("BOTTOMRIGHT", -8, 30)
  f.curBtn = UI.button(Lw, "Current auctions", 128, 22, "small")
  f.curBtn:SetPoint("TOPLEFT", 10, -8)
  f.curBtn:SetScript("OnClick", function() setView("cur") end)
  f.ownBtn = UI.button(Lw, "Your auctions", 112, 22, "small")
  f.ownBtn:SetPoint("LEFT", f.curBtn, "RIGHT", 4, 0)
  f.ownBtn:SetScript("OnClick", function() setView("own") end)
  local refresh = UI.button(Lw, "Refresh", 70, 22, "small")
  refresh:SetPoint("TOPRIGHT", -10, -8)
  refresh:SetScript("OnClick", function()
    if S.view == "own" then
      wipe(Live.cache)
      wipe(Live.byId)
      queryOwned()
    elseif S.sel then
      Live.cache[S.sel.ckey or ""] = nil
      renderCurrent()
      request(S.sel.itemKey, S.sel.commodity, true)
    end
  end)
  f.cutNext = UI.button(Lw, "Cancel undercut", 120, 22, "small danger")
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
  f.ownBand = band({ { "ITEM", 30 }, { "QTY", -270, true }, { "PRICE EACH", -150, true }, { "STATUS", -76, true } })
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

local function closeSelling()
  if not S.frame or not S.frame:IsShown() then return end
  S.frame:Hide()
  if S.tab then pcall(PanelTemplates_DeselectTab, S.tab) end
  blizzardTabs(true)
end
ns.closeSelling = closeSelling

local function openSelling()
  local f = makeFrame()
  if not f then return end
  if ns.closeSearch then ns.closeSearch() end
  if ns.closeOthers then ns.closeOthers("selling") end
  blizzardTabs(false)
  if S.tab then pcall(PanelTemplates_SelectTab, S.tab) end
  f:Show()
  if PlaySound and SOUNDKIT and SOUNDKIT.IG_CHARACTER_INFO_TAB then pcall(PlaySound, SOUNDKIT.IG_CHARACTER_INFO_TAB) end
end
ns.openSelling = openSelling

-- A tab after Blizzard's (and after any tab made before it). Shared with Shopping.lua.
function ns.makeTab(name, text, onClick, onBlizzard)
  local ah = _G.AuctionHouseFrame
  if not ah then return nil end
  local tabsList = ah.Tabs or {}
  local last = ns.lastTab or tabsList[#tabsList] or ah.AuctionsTab
  if not last then return nil end
  local okTab, tab = pcall(CreateFrame, "Button", name, ah, "PanelTabButtonTemplate")
  local templated = okTab and tab ~= nil
  if not templated then tab = UI.button(ah, text, 90, 26) end
  tab:SetID(100)
  tab:SetText(text)
  if templated then pcall(PanelTemplates_TabResize, tab, 0) end
  tab:SetPoint("LEFT", last, "RIGHT", templated and -15 or 4, 0)
  tab:SetScript("OnClick", onClick)
  if templated then pcall(PanelTemplates_DeselectTab, tab) end
  ns.lastTab = tab
  -- Blizzard's tabs (and anything that switches its view) close ours
  for _, t in ipairs(tabsList) do t:HookScript("OnClick", onBlizzard) end
  if ah.SetDisplayMode then hooksecurefunc(ah, "SetDisplayMode", onBlizzard) end
  if ns.applySkin then ns.applySkin() end
  return tab
end

local function makeTab()
  if S.tab then return end
  S.tab = ns.makeTab("EverlookAuctionsSellingTab", "Selling", openSelling, closeSelling)
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
  if S.frame then S.frame:Hide() end
  if S.tab then pcall(PanelTemplates_DeselectTab, S.tab) end
  wipe(Live.queue)
  Live.busy, S.posting, S.warned, S.sel = nil, nil, nil, nil
  if S.frame then S.frame.confirm:Hide() end
end

function events.BAG_UPDATE_DELAYED() refreshBags() end

function events.COMMODITY_SEARCH_RESULTS_UPDATED(itemID) onCommodityResults(itemID) end
function events.COMMODITY_SEARCH_RESULTS_ADDED(itemID) onCommodityResults(itemID) end
function events.ITEM_SEARCH_RESULTS_UPDATED(itemKey) onItemResults(itemKey) end
function events.ITEM_SEARCH_RESULTS_ADDED(itemKey) onItemResults(itemKey) end

function events.OWNED_AUCTIONS_UPDATED()
  if not S.frame or not S.frame:IsShown() then return end
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
  local job = S.posting
  if not job or not S.frame or not S.frame:IsShown() then return end
  -- Blizzard's own confirm would act on its own sell frame; ours posts what you set here
  askConfirm(job)
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
  if msg == "sell" or msg == "selling" then
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
  if S.frame then S.frame.cut:SetText(undercutShort()) end
  ns.say("undercut set to " .. undercutText() .. stepNote() .. ".")
  return true
end

function ns.help()
  if prevHelp then prevHelp() end
  print("  /eah sell  open the Selling tab (auction house open)")
  print(("  /eah undercut 1s, 50c, 5%% or 0  how far under the cheapest auction to price (now %s)"):format(undercutText()))
end
