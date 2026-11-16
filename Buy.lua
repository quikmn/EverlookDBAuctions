-- EverlookDB Auctions: buying from Advanced search and shopping lists.
--   Click a result to open its live auctions over the results.
--   Items       pick an auction, press Buy, then press Confirm (the price is on the button): PlaceBid with its buyout.
--   Commodities type how many, press Buy: the server quotes the total; press Confirm to pay it.
-- Every purchase takes your two clicks (Buy, then Confirm) and buys once; nothing is bought on its own.
-- Sellers are never shown or kept. Auctions cheaper than a vendor pays get a green tag with the profit (Vendor.lua).

local _, ns = ...
local UI, T = ns.UI, ns.T
local AH = C_AuctionHouse or {}
local money, num = ns.money, ns.num
local C_MUTE = UI.hex(T.mute)

local SORTS = { { sortOrder = 0, reverseSort = false } }   -- by price
local ROW = 22
local CONFIRM_FOR = 6     -- seconds the Confirm button stays armed

local B = {}

local function try(fn, ...)
  if type(fn) ~= "function" then return nil end
  local okCall, a = pcall(fn, ...)
  if okCall then return a end
end

local function okv(v)
  if ns.ok then return ns.ok(v) end
  return v
end

local function setStatus(text, color)
  local f = B.frame
  if not f then return end
  f.status:SetText(text or "")
  f.status:SetTextColor(unpack(color or T.dim))
end

local BANDS = { [0] = "< 30m", [1] = "30m - 2h", [2] = "2 - 12h", [3] = "12 - 48h" }
local function fmtLeft(secs, band)
  if secs then
    if secs >= 3600 then return math.floor(secs / 3600 + 0.5) .. "h" end
    return math.max(1, math.floor(secs / 60)) .. "m"
  end
  return band and BANDS[band] or ""
end

---------------------------------------------------------------------------------------------------------------------
-- Searching

local function send()
  local key
  if B.commodity then
    key = try(AH.MakeItemKey, B.id, 0, 0, 0)
  else
    key = try(AH.MakeItemKey, B.id, B.levels[B.level] or 0, 0, 0)
  end
  if not key or not AH.SendSearchQuery then setStatus("This client can't search the auction house.", T.bad); return end
  B.key = key
  B.rows, B.loaded = {}, false
  if AH.IsThrottledMessageSystemReady and not AH.IsThrottledMessageSystemReady() then
    C_Timer.After(0.3, function() if B.frame and B.frame:IsShown() then send() end end)
    return
  end
  if not pcall(AH.SendSearchQuery, key, SORTS, true) then setStatus("The search failed.", T.bad) end
end

-- The quantity you'd get and what it would cost, cheapest first, from other sellers' commodities.
local function estimate(qty)
  local left, cost = qty, 0
  for _, r in ipairs(B.rows) do
    if left <= 0 then break end
    local take = math.min(left, r.others)
    if take > 0 and r.unit then
      cost = cost + take * r.unit
      left = left - take
    end
  end
  return qty - left, cost
end

local render

local function readCommodity()
  local rows = {}
  for i = 1, (try(AH.GetNumCommoditySearchResults, B.id) or 0) do
    local r = try(AH.GetCommoditySearchResultInfo, B.id, i)
    if r then
      local q = okv(r.quantity) or 0
      local mine = okv(r.numOwnerItems) or 0
      rows[#rows + 1] = { unit = okv(r.unitPrice), qty = q, others = q - mine, mine = mine > 0, left = okv(r.timeLeftSeconds) }
    end
  end
  B.rows, B.loaded = rows, true
  render()
end

local function readItems(itemKey)
  local rows = {}
  local n = try(AH.GetNumItemSearchResults, itemKey) or 0
  for i = 1, n do
    local r = try(AH.GetItemSearchResultInfo, itemKey, i)
    if r then
      local link = okv(r.itemLink)
      local vkey = link and ns.variantOf(B.id, link)
      -- random-stat items: only the version you clicked
      if not (B.suffix ~= 0 and vkey and vkey ~= B.vkey) then
        local q = okv(r.quantity) or 1
        local buy = okv(r.buyoutAmount)
        rows[#rows + 1] = {
          auctionID = okv(r.auctionID), buyout = buy, unit = buy and math.floor(buy / math.max(1, q)), qty = q,
          mine = okv(r.containsOwnerItem) == true, left = okv(r.timeLeftSeconds), band = okv(r.timeLeft), link = link,
        }
      end
    end
  end
  table.sort(rows, function(a, b)
    if a.unit and b.unit then return a.unit < b.unit end
    return a.unit ~= nil and b.unit == nil
  end)
  -- gear is listed under its item level; try 0 next when nothing came back
  if n == 0 and B.level < #B.levels then
    B.level = B.level + 1
    send()
    return
  end
  B.rows, B.loaded = rows, true
  render()
end

---------------------------------------------------------------------------------------------------------------------
-- Buying: Buy arms Confirm; Confirm buys once.

local function disarm()
  B.armed = nil
  if B.frame then render() end
end

local function arm()
  local mine = {}
  B.armed = mine
  render()
  C_Timer.After(CONFIRM_FOR, function() if B.armed == mine then disarm() end end)
end

local function buyItem()
  local r = B.sel
  if not r or not r.buyout or not r.auctionID or r.mine then return end
  if not B.armed then arm(); return end
  B.armed = nil
  if GetMoney() < r.buyout then setStatus("Not enough money.", T.bad); render(); return end
  if not AH.PlaceBid then setStatus("This client can't buy auctions.", T.bad); return end
  local okCall, err = pcall(AH.PlaceBid, r.auctionID, r.buyout)
  if okCall then
    local id = r.auctionID
    B.pending = id
    setStatus(("Buying for %s..."):format(money(r.buyout)), T.dim)
    -- no word back in time: look again
    C_Timer.After(5, function()
      if B.pending == id then
        B.pending, B.sel, B.level = nil, nil, 1
        if ns.buyOpen then send() end
        render()
      end
    end)
  else
    setStatus("Couldn't buy: " .. tostring(err), T.bad)
  end
  render()
end

local function buyCommodity()
  local qty = B.qty or 0
  if qty < 1 then return end
  if B.quote then
    -- second click: pay the quoted price
    local quote = B.quote
    B.quote = nil
    if GetMoney() < quote.total then setStatus("Not enough money.", T.bad); render(); return end
    if not AH.ConfirmCommoditiesPurchase then setStatus("This client can't buy commodities.", T.bad); return end
    local okCall, err = pcall(AH.ConfirmCommoditiesPurchase, B.id, quote.qty)
    if okCall then
      B.pending = "commodity"
      C_Timer.After(8, function()
        if B.pending == "commodity" then
          B.pending, B.level = nil, 1
          if ns.buyOpen then send() end
          render()
        end
      end)
      setStatus(("Buying %s for %s..."):format(num(quote.qty), money(quote.total)), T.dim)
    else
      setStatus("Couldn't buy: " .. tostring(err), T.bad)
    end
    render()
    return
  end
  if not AH.StartCommoditiesPurchase then setStatus("This client can't buy commodities.", T.bad); return end
  local okCall, err = pcall(AH.StartCommoditiesPurchase, B.id, qty)
  if okCall then
    B.starting = qty
    setStatus("Asking the auction house for the price...", T.dim)
  else
    setStatus("Couldn't start the purchase: " .. tostring(err), T.bad)
  end
  render()
end

local function cancelQuote()
  if (B.quote or B.starting) and AH.CancelCommoditiesPurchase then pcall(AH.CancelCommoditiesPurchase) end
  B.quote, B.starting = nil, nil
end

---------------------------------------------------------------------------------------------------------------------
-- The panel

local function buildRow(L)
  local b = UI.row(L, ROW)
  b.price = UI.text(b, "body")
  b.price:SetPoint("LEFT", 12, 0)
  b.tag = UI.text(b, "small")
  b.tag:SetPoint("LEFT", b.price, "RIGHT", 10, 0)
  b.tag:SetTextColor(unpack(T.accent))
  b.vendor = UI.badge(b, 60, 16)
  b.vendor:SetPoint("LEFT", b.tag, "RIGHT", 6, 0)
  b.vendor:Hide()
  b.left = UI.text(b, "dim")
  b.left:SetPoint("RIGHT", -10, 0)
  b.left:SetWidth(80)
  b.left:SetJustifyH("RIGHT")
  b.qty = UI.text(b, "body")
  b.qty:SetPoint("RIGHT", b.left, "LEFT", -10, 0)
  b.qty:SetWidth(70)
  b.qty:SetJustifyH("RIGHT")
  b.total = UI.text(b, "dim")
  b.total:SetPoint("RIGHT", b.qty, "LEFT", -10, 0)
  b.total:SetWidth(120)
  b.total:SetJustifyH("RIGHT")
  b:SetScript("OnClick", function(self)
    if B.commodity or not self.item then return end
    B.sel = self.item
    B.armed = nil
    render()
  end)
  b:SetScript("OnEnter", function(self)
    local r = self.item
    if not r then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    if r.link then pcall(GameTooltip.SetHyperlink, GameTooltip, r.link) else pcall(GameTooltip.SetItemByID, GameTooltip, B.id) end
    local p = ns.vendor and r.unit and ns.vendor.flip(B.id, r.unit)
    if p then
      GameTooltip:AddLine(("Below vendor price: buy and vendor it for %s each, %s for all %d."):format(
        money(p), money(p * r.qty), r.qty), T.good[1], T.good[2], T.good[3], true)
    end
    if not B.commodity then
      GameTooltip:AddLine(r.mine and "Your own auction." or "Click to pick it, then Buy.", T.info[1], T.info[2], T.info[3])
    end
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)
  return b
end

local function fillRow(b, r)
  b.price:SetText(r.unit and money(r.unit) or (C_MUTE .. "bids only|r"))
  b.tag:SetText(r.mine and "yours" or "")
  -- below vendor price: a green tag with what buying and vendoring makes, each
  local p = not r.mine and ns.vendor and r.unit and ns.vendor.flip(B.id, r.unit)
  if p then
    b.vendor:EdbSet("vendor +" .. money(p), T.good)
    b.vendor:SetWidth(b.vendor.text:GetStringWidth() + 12)
    b.vendor:Show()
  else
    b.vendor:Hide()
  end
  b.qty:SetText(num(r.qty))
  b.total:SetText((not B.commodity and r.buyout and r.qty > 1) and money(r.buyout) or "")
  b.left:SetText(fmtLeft(r.left, r.band))
  b:EdbSelect(B.sel == r)
end

function render()
  local f = B.frame
  if not f or not f:IsShown() then return end
  -- the vendor price joins the line under the name once the item's details are there
  if not B.subVendor and B.bits and ns.vendor then
    local sell, c = ns.vendor.sellOf(B.id)
    if sell then
      B.subVendor = true
      if sell > 0 and not ns.vendor.isQuest(B.id, c and c[5]) then
        f.sub:SetText(table.concat(B.bits, "   ") .. "   vendor " .. money(sell))
      end
    end
  end
  f.list.empty:SetText(B.loaded and "Nobody is selling this right now." or "Looking up the live auctions...")
  f.list:SetItems(B.rows or {})
  f.qtyLabel:SetShown(B.commodity)
  f.qty:SetShown(B.commodity)
  f.max:SetShown(B.commodity)
  local btn = f.buy
  if B.commodity then
    local got, cost = estimate(B.qty or 0)
    f.summary:SetText(B.loaded and (got > 0 and ("%s for about %s"):format(num(got), money(cost)) or "none for sale") or "")
    if B.quote then
      btn:SetText("Confirm " .. money(B.quote.total))
      btn:EdbActive(true)
      btn:SetEnabled(GetMoney() >= B.quote.total)
    else
      btn:SetText(B.starting and "Getting price..." or "Buy")
      btn:EdbActive(false)
      btn:SetEnabled(B.loaded and not B.starting and not B.pending and got > 0 and got == (B.qty or 0))
    end
  else
    local r = B.sel
    f.summary:SetText(r and r.buyout and ("%s x%d, %s"):format(r.mine and "your auction" or "picked", r.qty, money(r.buyout))
      or (B.loaded and #B.rows > 0 and "Pick an auction." or ""))
    if B.armed and r and r.buyout then
      btn:SetText("Confirm " .. money(r.buyout))
      btn:EdbActive(true)
    else
      btn:SetText("Buy")
      btn:EdbActive(false)
    end
    btn:SetEnabled(r ~= nil and r.buyout ~= nil and not r.mine and not B.pending and GetMoney() >= (r.buyout or 0))
  end
end

local function close()
  B.pending = nil
  if B.frame then B.frame:Hide() end
end
ns.closeBuy = close
ns.buyRefresh = function() if ns.buyOpen then render() end end

local function makeFrame()
  local host = _G.EverlookAuctionsQueryResults
  if B.frame or not host then return B.frame end
  local f = UI.own(CreateFrame("Frame", nil, host))
  f:SetPoint("TOPLEFT", 1, -40)
  f:SetPoint("BOTTOMRIGHT", -1, 1)
  f:SetFrameLevel(host:GetFrameLevel() + 30)
  UI.panel(f, T.bg, T.bg)
  f:EnableMouse(true)
  f:Hide()
  -- also when Advanced search closes: let go of a quoted price and let its live check go on
  f:SetScript("OnHide", function()
    cancelQuote()
    B.armed = nil
    ns.buyOpen = false
    if ns.liveStep then ns.liveStep() end
  end)
  f:SetScript("OnShow", function() ns.buyOpen = true end)
  B.frame = f

  f.icon = UI.icon(f, 36)
  f.icon:SetPoint("TOPLEFT", 12, -10)
  f.name = UI.text(f, "big")
  f.name:SetPoint("TOPLEFT", f.icon, "TOPRIGHT", 10, -2)
  f.name:SetPoint("RIGHT", f, "RIGHT", -230, 0)
  f.sub = UI.text(f, "dim")
  f.sub:SetPoint("TOPLEFT", f.name, "BOTTOMLEFT", 0, -5)
  f.sub:SetPoint("RIGHT", f, "RIGHT", -230, 0)

  local back = UI.button(f, "Back", 60, 22, "small")
  back:SetPoint("TOPRIGHT", -10, -12)
  back:SetScript("OnClick", close)
  local blizz = UI.button(f, "Blizzard's list", 104, 22, "small")
  blizz:SetPoint("RIGHT", back, "LEFT", -4, 0)
  blizz:SetScript("OnClick", function()
    local name = B.name
    close()
    if ns.closeSearch then ns.closeSearch() end
    local bar = _G.AuctionHouseFrame and AuctionHouseFrame.SearchBar
    if bar and name then
      bar:SetSearchText(name)
      bar:StartSearch()
    end
  end)
  UI.tip(blizz, "Show it in Blizzard's own list", "Buy, bid and see every version there.")
  local refresh = UI.button(f, "Refresh", 64, 22, "small")
  refresh:SetPoint("RIGHT", blizz, "LEFT", -4, 0)
  refresh:SetScript("OnClick", function()
    cancelQuote()
    B.sel, B.armed, B.level = nil, nil, 1
    send()
    render()
  end)

  local band = UI.headerBand(f, 20)
  band:SetPoint("TOPLEFT", 0, -56)
  band:SetPoint("TOPRIGHT", 0, -56)
  local function col(text, x, right)
    local l = UI.label(band, text)
    if right then l:SetPoint("RIGHT", band, "RIGHT", x, 0); l:SetJustifyH("RIGHT") else l:SetPoint("LEFT", band, "LEFT", x, 0) end
  end
  col("PRICE EACH", 12)
  col("BUYOUT", -196, true)
  col("AVAILABLE", -106, true)
  col("TIME LEFT", -26, true)

  f.list = UI.list(f, ROW, buildRow, fillRow)
  f.list:SetPoint("TOPLEFT", 0, -76)
  f.list:SetPoint("BOTTOMRIGHT", -2, 46)

  -- bottom bar
  local line = UI.line(f, true)
  line:SetPoint("BOTTOMLEFT", 0, 44)
  line:SetPoint("BOTTOMRIGHT", 0, 44)
  f.buy = UI.button(f, "Buy", 160, 28, "primary")
  f.buy:SetPoint("BOTTOMRIGHT", -10, 8)
  f.buy:SetScript("OnClick", function()
    if B.commodity then buyCommodity() else buyItem() end
  end)
  UI.tip(f.buy, function() return B.armed and "Click again to pay" or nil end)
  f.qtyLabel = UI.label(f, "QUANTITY")
  f.qtyLabel:SetPoint("BOTTOMLEFT", 12, 16)
  f.qty = UI.input(f, 60, 24, { numeric = true, right = true, max = 6 })
  f.qty:SetPoint("BOTTOMLEFT", 76, 10)
  f.qty:HookScript("OnTextChanged", function(self, user)
    if not user then return end
    cancelQuote()
    B.qty = tonumber(self:GetText()) or 0
    render()
  end)
  f.max = UI.button(f, "Max", 44, 24, "small")
  f.max:SetPoint("LEFT", f.qty, "RIGHT", 4, 0)
  f.max:SetScript("OnClick", function()
    cancelQuote()
    local total = 0
    for _, r in ipairs(B.rows or {}) do total = total + r.others end
    B.qty = total
    f.qty:SetText(tostring(total))
    render()
  end)
  f.summary = UI.text(f, "body")
  f.summary:SetPoint("RIGHT", f.buy, "LEFT", -12, 0)
  f.summary:SetJustifyH("RIGHT")
  f.status = UI.text(f, "dim")
  f.status:SetPoint("BOTTOMLEFT", 12, 52)
  f.status:SetPoint("RIGHT", f, "RIGHT", -12, 0)
  return f
end

-- Opens the live auctions of a search result (row from Search.lua: id, suffix, key, name, icon, quality, ilvl, slot).
function ns.openBuy(row)
  local f = makeFrame()
  if not f or not row or not row.id then return false end
  cancelQuote()
  B.id, B.suffix, B.vkey, B.name = row.id, row.suffix or 0, row.key, row.name
  local info = try(AH.GetItemKeyInfo, try(AH.MakeItemKey, row.id, 0, 0, 0))
  if info and info.isCommodity ~= nil then
    B.commodity = info.isCommodity
  else
    local stack = ns.itemInfo and ns.itemInfo(row.id)
    B.commodity = (stack and (stack[10] or 1) or 1) > 1
  end
  B.levels = (not B.commodity and row.slot ~= "none" and (row.ilvl or 0) > 0) and { row.ilvl, 0 } or { 0 }
  B.level, B.sel, B.armed, B.pending, B.rows, B.loaded = 1, nil, nil, nil, {}, false
  B.qty = 1
  f.qty:SetText("1")
  local quality = ITEM_QUALITY_COLORS and row.quality and ({ poor = 0, common = 1, uncommon = 2, rare = 3, epic = 4, legendary = 5 })[row.quality]
  f.icon:EdbSet(row.icon, quality)
  local c = quality and ITEM_QUALITY_COLORS[quality]
  f.name:SetText((c and c.hex or "|cffffffff") .. row.name .. "|r")
  local bits = { B.commodity and "commodity: buy any amount" or "item: pick an auction" }
  if row.median then bits[#bits + 1] = "typical " .. money(row.median) end
  B.bits = bits
  f.sub:SetText(table.concat(bits, "   "))
  B.subVendor = false
  setStatus("Buy, then Confirm: two clicks for each purchase.", T.mute)
  ns.buyOpen = true
  f:Show()
  render()
  send()
  return true
end

---------------------------------------------------------------------------------------------------------------------
-- Events

local events = {}

function events.COMMODITY_SEARCH_RESULTS_UPDATED(itemID)
  if ns.buyOpen and B.commodity and itemID == B.id then readCommodity() end
end
events.COMMODITY_SEARCH_RESULTS_ADDED = events.COMMODITY_SEARCH_RESULTS_UPDATED

function events.ITEM_SEARCH_RESULTS_UPDATED(itemKey)
  if ns.buyOpen and not B.commodity and type(itemKey) == "table" and itemKey.itemID == B.id then readItems(itemKey) end
end
events.ITEM_SEARCH_RESULTS_ADDED = events.ITEM_SEARCH_RESULTS_UPDATED

function events.COMMODITY_PRICE_UPDATED(unit, total)
  if not ns.buyOpen or not B.starting then return end
  B.quote = { qty = B.starting, unit = okv(unit), total = okv(total) or 0 }
  B.starting = nil
  setStatus(("The auction house quotes %s (%s each). Confirm to pay."):format(money(B.quote.total), money(B.quote.unit or 0)), T.accent)
  render()
end

function events.COMMODITY_PRICE_UNAVAILABLE()
  if not ns.buyOpen then return end
  B.starting, B.quote = nil, nil
  setStatus("That many aren't for sale at the moment.", T.bad)
  render()
end

local function bought(text)
  B.pending, B.sel, B.armed = nil, nil, nil
  setStatus(text, T.good)
  C_Timer.After(0.5, function() if ns.buyOpen then B.level = 1; send() end end)
  render()
end

function events.COMMODITY_PURCHASE_SUCCEEDED()
  if ns.buyOpen and B.pending == "commodity" then bought("Bought. It's in your mailbox.") end
end

function events.COMMODITY_PURCHASE_FAILED()
  if not ns.buyOpen or B.pending ~= "commodity" then return end
  B.pending = nil
  setStatus("The purchase failed.", T.bad)
  render()
end

function events.AUCTION_HOUSE_PURCHASE_COMPLETED(auctionID)
  if ns.buyOpen and B.pending and B.pending == auctionID then bought("Bought. It's in your mailbox.") end
end

function events.PLAYER_MONEY() render() end

function events.AUCTION_HOUSE_CLOSED()
  if B.frame and B.frame:IsShown() then close() end
end

local ev = CreateFrame("Frame")
for e in pairs(events) do pcall(ev.RegisterEvent, ev, e) end
ev:SetScript("OnEvent", function(_, e, ...) events[e](...) end)
