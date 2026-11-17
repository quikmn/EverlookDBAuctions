-- EverlookDB Auctions: buying from Advanced search and shopping lists.
--   Click a result to open its live auctions over the results.
--   Items       pick an auction, press Buy, then press Confirm (the price is on the button): PlaceBid with its buyout.
--   Commodities type how many, press Buy: the server quotes the total; press Confirm to pay it.
-- Every purchase takes your two clicks (Buy, then Confirm) and buys once; nothing is bought on its own.
-- Start buying (below vendor price): the panel opens each item of the list in turn with its cheapest auction under
-- vendor price picked; one click on Buy buys it (stackable goods: Buy, then Confirm the quoted price), then the next
-- comes up. Every purchase is still your own click.
-- Sellers are never shown or kept. Auctions cheaper than a vendor pays get a green tag with the profit (Vendor.lua).

local _, ns = ...
local UI, T = ns.UI, ns.T
local AH = C_AuctionHouse or {}
local money, num = ns.money, ns.num
local C_MUTE = UI.hex(T.mute)

local ROW = 22
local CONFIRM_FOR = 6     -- seconds the Confirm button stays armed

local B = {}
local render, send   -- defined further down
local dealPick, nextDeal   -- Start buying (further down)

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

local function itemRows(itemKey)
  local rows = {}
  for i = 1, (try(AH.GetNumItemSearchResults, itemKey) or 0) do
    local r = try(AH.GetItemSearchResultInfo, itemKey, i)
    if r then
      local link = okv(r.itemLink)
      local q = okv(r.quantity) or 1
      local buy = okv(r.buyoutAmount)
      local vname
      if link then vname = select(3, ns.variantOf(B.id, link)) end
      rows[#rows + 1] = {
        auctionID = okv(r.auctionID), buyout = buy, unit = buy and math.floor(buy / math.max(1, q)), qty = q,
        mine = okv(r.containsOwnerItem) == true, left = okv(r.timeLeftSeconds), band = okv(r.timeLeft), link = link,
        vname = vname,
      }
    end
  end
  return rows
end

local function commodityRows()
  local rows = {}
  for i = 1, (try(AH.GetNumCommoditySearchResults, B.id) or 0) do
    local r = try(AH.GetCommoditySearchResultInfo, B.id, i)
    if r then
      local q = okv(r.quantity) or 0
      local mine = okv(r.numOwnerItems) or 0
      rows[#rows + 1] = { unit = okv(r.unitPrice), qty = q, others = q - mine, mine = mine > 0, left = okv(r.timeLeftSeconds) }
    end
  end
  return rows
end

-- The picked auction in a fresh list (the rows are new tables each time), or nil when it isn't up any more.
function B.buyMatch(rows, sel)
  for _, r in ipairs(rows or {}) do
    if r.auctionID == sel.auctionID then
      if B.dealSel == sel then B.dealSel = r end
      return r
    end
  end
  if B.dealSel == sel then B.dealSel = nil end
  return nil
end

local function byPrice(a, b)
  if a.unit and b.unit then return a.unit < b.unit end
  return a.unit ~= nil and b.unit == nil
end

-- The base name ("Dwarven Magestaff"): what Blizzard's search box takes; a browse by it lists every version.
local function baseName()
  local c = ns.itemInfo and ns.itemInfo(B.id)
  return c and c[1] or B.name
end

-- Looks up the live auctions the way Blizzard's Search button does: a browse by name gives the item's real
-- ItemKeys (one per random-stat version), then each key's auctions. "Nobody is selling" only comes from a complete
-- answer; no answer says so and is asked again.
function send()
  if not ns.ahq then setStatus("This client can't search the auction house.", T.bad); return end
  B.gen = (B.gen or 0) + 1
  local gen = B.gen
  ns.ahq.cancel("buy")
  B.rows, B.loaded, B.state = {}, false, "waiting"
  local function retrying() if gen == B.gen then B.state = "retry"; render() end end
  local function noAnswer()
    if gen ~= B.gen then return end
    B.state = "noanswer"
    if #(B.rows or {}) > 0 then
      setStatus("Some of the auctions didn't come: the list may be missing some. Press Refresh to ask again.", T.bad)
    end
    render()
  end
  local function queryKeys()
    if gen ~= B.gen then return end
    local got, left = {}, #B.keys
    B.partial = false
    for _, key in ipairs(B.keys) do
      ns.ahq.items(key, { owner = "buy", front = true, commodity = B.commodity, onRetry = retrying, onFail = noAnswer },
        function(k, full, final)
          if gen ~= B.gen then return end
          got[ns.ahq.keyText(k)] = B.commodity and commodityRows() or itemRows(k)
          if final then
            left = left - 1
            if not full then B.partial = true end
          end
          local rows = {}
          for _, list in pairs(got) do for _, r in ipairs(list) do rows[#rows + 1] = r end end
          table.sort(rows, byPrice)
          B.rows = rows
          B.sel = B.sel and B.sel.auctionID and B.buyMatch(rows, B.sel) or nil
          if not B.sel then B.armed = nil end
          if left <= 0 then B.loaded, B.state = true, nil end
          render()
          if left <= 0 and B.deal then dealPick() end
        end)
    end
  end
  if B.keys then queryKeys(); render(); return end
  ns.ahq.browse(baseName(), B.id, { owner = "buy", front = true, confirmEmpty = true, onRetry = retrying },
    function(answer)
      if gen ~= B.gen then return end
      if not answer.ok then noAnswer(); return end
      if #answer.entries == 0 then
        if answer.full then B.rows, B.loaded, B.state = {}, true, nil else B.state = "partial" end
        render()
        if answer.full and B.deal then dealPick() end
        return
      end
      B.keys, B.showAll = ns.ahq.pickKeys(answer.entries, B.name, ns.ahq.nameOf)
      local info = try(AH.GetItemKeyInfo, B.keys[1])
      if info and okv(info.isCommodity) ~= nil then B.commodity = okv(info.isCommodity) and true or false end
      queryKeys()
    end)
  render()
end
ns.buyKeys = function() return B.keys, B.showAll end

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

-- The line beside Buy for stackable goods: what that many would cost, or why Buy can't be pressed.
function B.summaryText(qty, loaded)
  if not loaded then return "" end
  if qty < 1 then return "Type how many to buy." end
  local got, cost = estimate(qty)
  if got <= 0 then return "None for sale from other sellers." end
  if got < qty then return ("Only %s for sale (about %s)."):format(num(got), money(cost)) end
  return ("%s for about %s"):format(num(got), money(cost))
end

---------------------------------------------------------------------------------------------------------------------
-- Buying: Buy arms Confirm; Confirm buys once.

local function cancelQuote()
  if (B.quote or B.starting) and AH.CancelCommoditiesPurchase then pcall(AH.CancelCommoditiesPurchase) end
  B.quote, B.starting, B.asking = nil, nil, nil
end

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
  -- Start buying: one click buys the auction it picked (under vendor price); any other auction you pick takes Confirm
  if not B.armed and not (B.deal and B.dealSel == r) then arm(); return end
  B.armed = nil
  if GetMoney() < r.buyout then setStatus("Not enough money.", T.bad); render(); return end
  if not AH.PlaceBid then setStatus("This client can't buy auctions.", T.bad); return end
  local okCall, err = pcall(AH.PlaceBid, r.auctionID, r.buyout)
  if okCall then
    local id = r.auctionID
    B.pending, B.late = id, nil
    B.buying = { qty = r.qty, cost = r.buyout }
    setStatus(("Buying for %s..."):format(money(r.buyout)), T.dim)
    -- no word back in time: say so (it may still go through) and look again
    C_Timer.After(5, function()
      if B.pending == id then
        B.pending, B.sel, B.late = nil, nil, id
        setStatus("No word from the auction house about that purchase yet. Check your mailbox before you buy again; looking at the auctions again.", T.bad)
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
    if GetMoney() < quote.total then
      cancelQuote()
      setStatus(("Not enough money: that costs %s and you have %s."):format(money(quote.total), money(GetMoney())), T.bad)
      render()
      return
    end
    B.quote = nil
    B.buying = { qty = quote.qty, cost = quote.total }
    if not AH.ConfirmCommoditiesPurchase then setStatus("This client can't buy commodities.", T.bad); return end
    local okCall, err = pcall(AH.ConfirmCommoditiesPurchase, B.id, quote.qty)
    if okCall then
      B.pending, B.late = "commodity", nil
      C_Timer.After(8, function()
        if B.pending == "commodity" then
          B.pending, B.late = nil, "commodity"
          setStatus("No word from the auction house about that purchase yet. Check your mailbox before you buy again; looking at the auctions again.", T.bad)
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
    local ask = {}
    B.starting, B.asking = qty, ask
    setStatus("Asking the auction house for the price...", T.dim)
    -- no price in time: let go, so the button works again
    C_Timer.After(8, function()
      if B.asking == ask and B.starting then
        cancelQuote()
        setStatus("The auction house didn't send a price, so nothing was bought. Press Buy to ask again.", T.bad)
        render()
      end
    end)
  else
    setStatus("Couldn't start the purchase: " .. tostring(err), T.bad)
  end
  render()
end

---------------------------------------------------------------------------------------------------------------------
-- The panel

local function buildRow(L)
  local b = UI.row(L, ROW)
  b.price = UI.text(b, "body")
  b.price:SetPoint("LEFT", 12, 0)
  -- the green below-vendor tag right after the price, then "yours" / the version's name, which stops short of the
  -- buyout column (anchored in fillRow)
  b.vendor = UI.badge(b, 60, 16)
  b.vendor:SetPoint("LEFT", b.price, "RIGHT", 10, 0)
  b.vendor:Hide()
  b.tag = UI.text(b, "small")
  b.tag:SetTextColor(unpack(T.accent))
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
  b.tag:SetPoint("RIGHT", b.total, "LEFT", -10, 0)
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
    local p = not r.mine and ns.vendor and r.unit and ns.vendor.flip(B.id, r.unit)
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

-- A version's own part of its name ("of the Bear" from "Dwarven Magestaff of the Bear"), short enough for its row.
function B.versionName(full, base)
  if type(full) ~= "string" then return "" end
  if base and base ~= "" and full:sub(1, #base) == base then
    local rest = full:sub(#base + 1):gsub("^%s+", "")
    if rest ~= "" then return rest end
  end
  return full
end

local function fillRow(b, r)
  b.price:SetText(r.unit and money(r.unit) or (C_MUTE .. "bids only|r"))
  local tag = r.mine and "yours" or ""
  if B.showAll and r.vname then tag = (r.mine and "yours, " or "") .. B.versionName(r.vname, baseName()) end
  b.tag:SetText(tag)
  -- below vendor price: a green tag with what buying and vendoring makes, each
  local p = not r.mine and ns.vendor and r.unit and ns.vendor.flip(B.id, r.unit)
  b.tag:ClearAllPoints()
  b.tag:SetPoint("RIGHT", b.total, "LEFT", -10, 0)
  if p then
    b.vendor:EdbSet("vendor +" .. money(p), T.good)
    b.vendor:SetWidth(b.vendor.text:GetStringWidth() + 12)
    b.vendor:Show()
    b.tag:SetPoint("LEFT", b.vendor, "RIGHT", 6, 0)
  else
    b.vendor:Hide()
    b.tag:SetPoint("LEFT", b.price, "RIGHT", 10, 0)
  end
  b.qty:SetText(num(r.qty))
  b.total:SetText((not B.commodity and r.buyout and r.qty > 1) and money(r.buyout) or "")
  b.left:SetText(fmtLeft(r.left, r.band))
  b:EdbSelect(B.sel == r)
end

function render()
  local f = B.frame
  if not f or not f:IsShown() then return end
  -- the line under the name: how it's sold (the auction house's own key can change our guess), the usual price, and
  -- the vendor price once the item's details are there
  if B.bits then
    B.bits[1] = B.commodity and "sold by amount: type how many" or "pick an auction to buy"
    local text = table.concat(B.bits, "   ")
    local sell, c = ns.vendor and ns.vendor.sellOf(B.id)
    if sell and sell > 0 and not ns.vendor.isQuest(B.id, c and c[5]) then text = text .. "   a vendor pays " .. money(sell) end
    f.sub:SetText(text)
  end
  local empty = "Waiting for the auction house..."
  if B.loaded and B.partial then empty = "The auction house didn't send its whole list. Press Refresh to ask again."
  elseif B.loaded then empty = "Nobody is selling this right now."
  elseif B.state == "retry" then empty = "The auction house didn't answer. Retrying..."
  elseif B.state == "noanswer" then empty = "The auction house didn't answer. Press Refresh to try again."
  elseif B.state == "partial" then empty = "The auction house didn't send its whole list for this name. Try Show in Blizzard search." end
  f.list.empty:SetText(empty)
  f.list:SetItems(B.rows or {})
  f.qtyLabel:SetShown(B.commodity)
  f.qty:SetShown(B.commodity)
  f.max:SetShown(B.commodity)
  if f.stackHead then f.stackHead:SetShown(not B.commodity) end
  local btn = f.buy
  if B.commodity then
    f.summary:SetText(B.summaryText(B.qty or 0, B.loaded))
    if B.quote then
      btn:SetText("Confirm " .. money(B.quote.total))
      btn:EdbActive(true)
      btn:SetEnabled(GetMoney() >= B.quote.total)
    else
      btn:SetText(B.starting and "Getting price..." or "Buy")
      btn:EdbActive(false)
      local got = estimate(B.qty or 0)
      btn:SetEnabled(B.loaded and not B.starting and not B.pending and got > 0 and got == (B.qty or 0))
    end
  else
    local r = B.sel
    local text = ""
    if r and r.buyout then
      text = ("%s: %s for %s"):format(r.mine and "Your auction" or "Picked", num(r.qty), money(r.buyout))
      if not r.mine and GetMoney() < r.buyout then text = text .. "  " .. UI.hex(T.bad) .. "not enough money|r" end
    elseif r then
      text = "Bids only: no buyout. Bid in Blizzard search."
    elseif B.loaded and #B.rows > 0 then
      text = "Pick an auction."
    end
    f.summary:SetText(text)
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
  B.deal = nil
  B.gen = (B.gen or 0) + 1   -- answers still on their way are dropped
  if ns.ahq then ns.ahq.cancel("buy") end
  if B.frame then B.frame:Hide() end
end
ns.closeBuy = close
ns.buyRefresh = function() if ns.buyOpen then render() end end

local function makeFrame()
  local host = _G.EverlookAuctionsQueryResults
  if B.frame or not host then return B.frame end
  local f = UI.own(CreateFrame("Frame", nil, host))
  f:SetPoint("TOPLEFT", 1, -26)   -- under the "Advanced search > item" line
  f:SetPoint("BOTTOMRIGHT", -1, 1)
  f:SetFrameLevel(host:GetFrameLevel() + 30)
  UI.panel(f, T.bg, T.bg)
  f:EnableMouse(true)
  f:Hide()
  -- also when Advanced search closes (or another auction house tab hides it): let go of a quoted price, stop a
  -- buying run, drop answers on their way, and stay closed, so it never comes back later with old auctions
  f:SetScript("OnHide", function(self)
    cancelQuote()
    B.armed, B.pending, B.deal = nil, nil, nil
    B.gen = (B.gen or 0) + 1
    if ns.ahq then ns.ahq.cancel("buy") end
    if self:IsShown() then self:Hide() end
    ns.buyOpen = false
    if ns.searchCrumb then ns.searchCrumb(nil) end
    if ns.liveStep then ns.liveStep() end
  end)
  f:SetScript("OnShow", function()
    ns.buyOpen = true
    if ns.searchCrumb then ns.searchCrumb(B.name) end
  end)
  B.frame = f

  f.icon = UI.icon(f, 36)
  f.icon:SetPoint("TOPLEFT", 12, -10)
  f.name = UI.text(f, "big")
  f.name:SetPoint("TOPLEFT", f.icon, "TOPRIGHT", 10, -2)
  f.name:SetPoint("RIGHT", f, "RIGHT", -296, 0)
  f.sub = UI.text(f, "dim")
  f.sub:SetPoint("TOPLEFT", f, "TOPLEFT", 58, -38)   -- under the buttons, so it can use the whole width
  f.sub:SetPoint("RIGHT", f, "RIGHT", -12, 0)

  local back = UI.button(f, "Back", 60, 22, "small")
  back:SetPoint("TOPRIGHT", -10, -12)
  back:SetScript("OnClick", close)
  local blizz = UI.button(f, "Show in Blizzard search", 150, 22, "small")
  blizz:SetPoint("RIGHT", back, "LEFT", -4, 0)
  blizz:SetScript("OnClick", function()
    local name = baseName()
    if ns.ahq then ns.ahq.showInBlizzard(name) end
  end)
  UI.tip(blizz, "Show it in Blizzard's own search", "Closes Advanced search and searches its name there: buy, bid and see every version.")
  local refresh = UI.button(f, "Refresh", 64, 22, "small")
  refresh:SetPoint("RIGHT", blizz, "LEFT", -4, 0)
  refresh:SetScript("OnClick", function()
    cancelQuote()
    B.sel, B.armed, B.keys = nil, nil, nil   -- look for the item's versions again too
    send()
    render()
  end)

  local band = UI.headerBand(f, 20)
  band:SetPoint("TOPLEFT", 0, -56)
  band:SetPoint("TOPRIGHT", 0, -56)
  local function col(text, x, right)
    local l = UI.label(band, text)
    if right then l:SetPoint("RIGHT", band, "RIGHT", x, 0); l:SetJustifyH("RIGHT") else l:SetPoint("LEFT", band, "LEFT", x, 0) end
    return l
  end
  -- right edges as in the rows: a row ends 18 px from the right (the list's 2 + the scroll bar's 16)
  col("PRICE EACH", 12)
  f.stackHead = col("WHOLE AUCTION", -198, true)
  col("AVAILABLE", -118, true)
  col("TIME LEFT", -28, true)

  f.list = UI.list(f, ROW, buildRow, fillRow)
  f.list:SetPoint("TOPLEFT", 0, -76)
  f.list:SetPoint("BOTTOMRIGHT", -2, 82)

  -- bottom bar
  local line = UI.line(f, true)
  line:SetPoint("BOTTOMLEFT", 0, 44)
  line:SetPoint("BOTTOMRIGHT", 0, 44)
  f.buy = UI.button(f, "Buy", 190, 28, "primary")
  f.buy:SetPoint("BOTTOMRIGHT", -10, 8)
  f.buy:SetScript("OnClick", function()
    if B.commodity then buyCommodity() else buyItem() end
  end)
  UI.tip(f.buy, function()
    if B.armed or B.quote then return "Click again to pay" end
    if B.deal and not B.commodity and B.sel and B.sel == B.dealSel then return "One click buys this auction" end
    return nil
  end)
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
    for _, r in ipairs(B.rows or {}) do total = total + (r.others or 0) end
    total = math.min(total, 999999)   -- what the box holds
    B.qty = total
    f.qty:SetText(tostring(total))
    render()
  end)
  f.summary = UI.text(f, "body")
  f.summary:SetPoint("RIGHT", f.buy, "LEFT", -12, 0)
  f.summary:SetPoint("LEFT", f, "BOTTOMLEFT", 196, 23)   -- clear of the quantity box and Max
  f.summary:SetJustifyH("RIGHT")
  -- the status line: up to two lines between the list and the bottom bar
  f.status = UI.text(f, "dim")
  f.status:SetPoint("BOTTOMLEFT", 12, 50)
  f.status:SetPoint("RIGHT", f, "RIGHT", -12, 0)
  f.status:SetJustifyV("BOTTOM")
  f.status:SetWordWrap(true)
  if f.status.SetMaxLines then f.status:SetMaxLines(2) end
  return f
end

-- Opens the live auctions of a search result (row from Search.lua: id, suffix, key, name, icon, quality, ilvl, slot).
local function open(row, deal)
  local f = makeFrame()
  if not f or not row or not row.id then return false end
  cancelQuote()
  B.deal, B.row, B.buying, B.dealSel, B.dealWait, B.late = deal, row, nil, nil, nil, nil
  B.id, B.suffix, B.vkey, B.name = row.id, row.suffix or 0, row.key, row.name
  local stack = ns.itemInfo and ns.itemInfo(row.id)
  B.commodity = (stack and (stack[10] or 1) or 1) > 1   -- until the auction house's own key says
  B.keys, B.showAll, B.state = nil, false, nil
  B.sel, B.armed, B.pending, B.rows, B.loaded = nil, nil, nil, {}, false
  B.qty = 1
  f.qty:SetText("1")
  local quality = ITEM_QUALITY_COLORS and row.quality and ({ poor = 0, common = 1, uncommon = 2, rare = 3, epic = 4, legendary = 5 })[row.quality]
  f.icon:EdbSet(row.icon, quality)
  local c = quality and ITEM_QUALITY_COLORS[quality]
  f.name:SetText((c and c.hex or "|cffffffff") .. row.name .. "|r")
  local bits = { B.commodity and "sold by amount: type how many" or "pick an auction to buy" }
  if row.median then bits[#bits + 1] = "usual price at the last scan " .. money(row.median) end
  B.bits = bits
  f.sub:SetText(table.concat(bits, "   "))
  if deal then
    setStatus("Start buying: looking for its auctions under vendor price.  " .. ns.vendor.tallyText(deal.tally, money), T.mute)
  else
    setStatus("Buy, then Confirm: two clicks for each purchase.", T.mute)
  end
  ns.buyOpen = true
  f:Show()
  if ns.searchCrumb then ns.searchCrumb(deal and ("Below vendor  >  " .. row.name) or row.name) end
  render()
  send()
  return true
end

function ns.openBuy(row) return open(row, nil) end

-- Start buying: the first item of the below-vendor list (the list shrinks as items are bought out or gone).
function nextDeal()
  local deal = B.deal
  if not deal then return end
  -- headers (a shopping list's query lines) and rows without an item are skipped
  local row
  for _, r in ipairs(deal.list) do
    if r.id and not r.header then row = r; break end
  end
  if not row then
    B.deal = nil
    close()
    if ns.say then ns.say("nothing under vendor price is left in the list. " .. ns.vendor.tallyText(deal.tally, money)) end
    return
  end
  if not open(row, deal) then B.deal = nil end
end

-- The live auctions are in: pick the cheapest one under vendor price, or, when there is none any more, drop the item
-- from the list and go on with the next.
function dealPick()
  local deal = B.deal
  if not deal then return end
  local sell = ns.vendor.sellOf(B.id)
  if not sell then
    -- the vendor price isn't loaded yet: wait for it (it is asked for) instead of dropping the item as if it had no deals
    local id, row = B.id, B.row
    B.dealWait = (B.dealWait or 0) + 1
    if B.dealWait > 20 then
      B.dealWait = nil
      setStatus("The game didn't send this item's vendor price, so it can't be checked. Press Refresh to try again.", T.bad)
      return
    end
    setStatus("Waiting for the game to send the item's vendor price...", T.mute)
    C_Timer.After(0.5, function() if B.deal == deal and B.id == id and B.row == row then dealPick() end end)
    return
  end
  B.dealWait = nil
  local pick = ns.vendor.nextDeal(B.rows, sell, B.commodity)
  if not pick then
    if ns.dropResult and B.row then ns.dropResult(B.row) end
    for k, r in ipairs(deal.list) do
      if r == B.row then table.remove(deal.list, k); break end   -- when the list was a copy
    end
    C_Timer.After(0.2, function() if B.deal == deal then nextDeal() end end)
    return
  end
  local tally = ns.vendor.tallyText(deal.tally, money)
  if B.commodity then
    B.qty = pick.qty
    B.frame.qty:SetText(tostring(pick.qty))
    setStatus(("%d under vendor price for %s (vendor pays %s). Buy, then Confirm.  %s"):format(
      pick.qty, money(pick.cost), money(sell * pick.qty), tally), T.accent)
  else
    B.sel, B.dealSel = pick, pick
    setStatus(("Picked: %s, vendor pays %s. One click on Buy buys it.  %s"):format(
      money(pick.buyout), money(sell * pick.qty), tally), T.accent)
  end
  render()
end

function ns.startDeals(list)
  if not list or #list == 0 then return end
  B.deal = { list = list, tally = nil }
  nextDeal()
end

---------------------------------------------------------------------------------------------------------------------
-- Events

local events = {}

function events.COMMODITY_PRICE_UPDATED(unit, total)
  if not ns.buyOpen or not B.starting then return end
  total = okv(total)
  if type(total) ~= "number" or total <= 0 then
    -- a price we can't read is never paid
    cancelQuote()
    setStatus("The auction house's price couldn't be read, so nothing was bought. Press Buy to ask again.", T.bad)
    render()
    return
  end
  local quote = { qty = B.starting, unit = okv(unit), total = total }
  B.quote, B.starting, B.asking = quote, nil, nil
  local sell = B.deal and ns.vendor.sellOf(B.id)
  if B.deal and (not sell or quote.total > sell * quote.qty) then
    setStatus(("The auction house quotes %s, more than a vendor pays (%s). Not bought; Refresh to look again."):format(
      money(quote.total), sell and money(sell * quote.qty) or "unknown"), T.bad)
    cancelQuote()
    render()
    return
  end
  -- the quote holds for a short while; then it's gone and Buy asks again
  local secs = try(AH.GetQuoteDurationRemaining)
  if type(secs) ~= "number" or secs <= 0 then secs = 30 end
  C_Timer.After(secs, function()
    if B.quote == quote then
      cancelQuote()
      setStatus("The price quote ran out, so nothing was bought. Press Buy to ask again.", T.mute)
      render()
    end
  end)
  local each = money(quote.unit or math.floor(quote.total / math.max(1, quote.qty)))
  local _, listed = estimate(quote.qty)
  if listed > 0 and quote.total > listed * 1.05 then
    setStatus(("The auction house quotes %s (%s each), more than the %s listed: the cheapest went meanwhile. Confirm within %d seconds to pay it anyway."):format(
      money(quote.total), each, money(listed), secs), T.bad)
  else
    setStatus(("The auction house quotes %s (%s each). Confirm within %d seconds to pay."):format(money(quote.total), each, secs), T.accent)
  end
  render()
end

function events.COMMODITY_PRICE_UNAVAILABLE()
  if not ns.buyOpen or not (B.starting or B.quote) then return end
  B.starting, B.quote, B.asking = nil, nil, nil
  setStatus("That many aren't for sale right now (some sold meanwhile). Nothing was bought; try a smaller amount.", T.bad)
  render()
end

local function bought(text)
  B.pending, B.sel, B.armed, B.dealSel, B.late = nil, nil, nil, nil, nil
  if B.deal and B.buying then
    local sell = ns.vendor.sellOf(B.id) or 0
    B.deal.tally = ns.vendor.tally(B.deal.tally, B.buying.qty, B.buying.cost, sell)
    text = text .. "  " .. ns.vendor.tallyText(B.deal.tally, money)
  end
  B.buying = nil
  setStatus(text, T.good)
  C_Timer.After(0.5, function() if ns.buyOpen then send() end end)
  render()
end

-- An answer that comes after we stopped waiting (B.late) still counts.
function events.COMMODITY_PURCHASE_SUCCEEDED()
  if ns.buyOpen and (B.pending == "commodity" or B.late == "commodity") then bought("Bought. It's in your mailbox.") end
end

function events.COMMODITY_PURCHASE_FAILED()
  if not ns.buyOpen or (B.pending ~= "commodity" and B.late ~= "commodity") then return end
  B.pending, B.late, B.buying = nil, nil, nil
  setStatus("The purchase didn't go through, so nothing was paid (the auctions may have changed). Looking at them again.", T.bad)
  C_Timer.After(0.5, function() if ns.buyOpen then send() end end)
  render()
end

function events.AUCTION_HOUSE_PURCHASE_COMPLETED(auctionID)
  if ns.buyOpen and auctionID ~= nil and (B.pending == auctionID or B.late == auctionID) then
    bought("Bought. It's in your mailbox.")
  end
end

-- The auction house refused an item purchase (sold already, not enough money...): say why and look again.
function events.AUCTION_HOUSE_SHOW_ERROR(err)
  if not ns.buyOpen or type(B.pending) ~= "number" then return end
  B.pending, B.sel, B.armed, B.buying, B.dealSel = nil, nil, nil, nil, nil
  local why = _G.AuctionHouseUtil and AuctionHouseUtil.GetErrorText and try(AuctionHouseUtil.GetErrorText, err)
  setStatus("The auction house refused the purchase" .. ((why and why ~= "") and (": " .. why) or "") ..
    ". Nothing was paid. Looking at the auctions again.", T.bad)
  C_Timer.After(0.5, function() if ns.buyOpen then send() end end)
  render()
end

function events.PLAYER_MONEY() render() end

function events.AUCTION_HOUSE_CLOSED()
  if B.frame and B.frame:IsShown() then close() end
end

local ev = CreateFrame("Frame")
for e in pairs(events) do pcall(ev.RegisterEvent, ev, e) end
ev:SetScript("OnEvent", function(_, e, ...) events[e](...) end)
