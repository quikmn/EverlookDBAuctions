-- EverlookDB Auctions: say what a click in Blizzard's commodity list did. Commodities (cloth, herbs, ore...) always
-- sell cheapest first, so clicking a row there sets Quantity to every unit at or below that row's price ("buy up to
-- this price") and marks all those rows. That is Blizzard's behaviour and stays; when one click picks more than one row
-- we put a line under Buy with how many, up to what price, and about what it costs, so it is never a surprise.

local _, ns = ...
local T = ns.T

local N = {}
ns.commodityNote = N

-- Buying `qty` cheapest first from search results ({ quantity, unitPrice }, cheapest first): how many you get, what it
-- costs, the highest price paid each, and how many rows it reaches into.
function N.cost(results, qty)
  local left, cost, top, rows = qty or 0, 0, nil, 0
  for _, r in ipairs(results or {}) do
    if left <= 0 then break end
    local q, u = r.quantity or 0, r.unitPrice
    if u and q > 0 then
      local take = math.min(left, q)
      cost, left, top, rows = cost + take * u, left - take, u, rows + 1
    end
  end
  return (qty or 0) - left, cost, top, rows
end

function N.text(qty, cost, top, rows)
  return ("Quantity set to %s: every one up to %s each, from %d rows, about %s. Commodities always sell cheapest first, so a click buys up to that price.")
    :format(ns.num(qty), ns.money(top), rows, ns.money(cost))
end

local function parts()
  local ah = _G.AuctionHouseFrame
  local cb = ah and ah.CommoditiesBuyFrame
  return cb, cb and cb.BuyDisplay
end

local function call(o, m)
  if o and o[m] then
    local okCall, v = pcall(o[m], o)
    if okCall then return v end
  end
end

local function quantity(bd)
  local q = call(bd, "GetQuantitySelected")
  if q then return q end
  local qi = bd and bd.QuantityInput
  local box = qi and (qi.InputBox or qi)
  return call(box, "GetNumber")
end

local function results(id)
  local C = _G.C_AuctionHouse
  local out = {}
  if not (id and C and C.GetNumCommoditySearchResults and C.GetCommoditySearchResultInfo) then return out end
  for i = 1, C.GetNumCommoditySearchResults(id) or 0 do
    local r = C.GetCommoditySearchResultInfo(id, i)
    if r then out[#out + 1] = r end
  end
  return out
end

local label, noted
local function hide()
  noted = nil
  if label then label:Hide() end
end

local function show()
  local cb, bd = parts()
  if not bd then return end
  local id, q = call(cb, "GetItemID"), quantity(bd)
  if not id or not q or q < 1 then return hide() end
  local got, cost, top, rows = N.cost(results(id), q)
  if rows < 2 or got < 1 then return hide() end
  if not label then
    label = bd:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    local anchor = bd.BuyButton or bd
    label:SetPoint("TOP", anchor, "BOTTOM", 0, -8)
    label:SetWidth(math.max(220, (bd:GetWidth() or 300) - 30))
    label:SetJustifyH("CENTER")
    label:SetWordWrap(true)
    local c = T and T.accent or { 1, 0.82, 0 }
    label:SetTextColor(c[1], c[2], c[3])
    -- typing another quantity takes the note away
    local qi = bd.QuantityInput
    local box = qi and (qi.InputBox or qi)
    if box and box.HookScript then
      box:HookScript("OnTextChanged", function() if noted and quantity(bd) ~= noted then hide() end end)
    end
  end
  noted = q
  label:SetText(N.text(got, cost, top, rows))
  label:Show()
end

-- Rows are recycled frames: hook each one's click once, then read what Blizzard set right after it.
local hookedRows = setmetatable({}, { __mode = "k" })
local function hookRow(row)
  if hookedRows[row] or not row.HookScript then return end
  hookedRows[row] = true
  row:HookScript("OnClick", function() C_Timer.After(0, function() pcall(show) end) end)
end

local hookedBox
local function hookList()
  local cb = parts()
  local sb = cb and cb.ItemList and cb.ItemList.ScrollBox
  if not sb then return end
  if sb.ForEachFrame then pcall(sb.ForEachFrame, sb, hookRow) end
  if hookedBox ~= sb and sb.Update then
    hookedBox = sb
    hooksecurefunc(sb, "Update", function() if sb.ForEachFrame then pcall(sb.ForEachFrame, sb, hookRow) end end)
  end
end

local ev = CreateFrame("Frame")
for _, e in ipairs({ "AUCTION_HOUSE_SHOW", "COMMODITY_SEARCH_RESULTS_UPDATED", "AUCTION_HOUSE_CLOSED" }) do
  pcall(ev.RegisterEvent, ev, e)
end
ev:SetScript("OnEvent", function(_, e)
  if e == "AUCTION_HOUSE_CLOSED" then return hide() end
  if e == "COMMODITY_SEARCH_RESULTS_UPDATED" then
    -- another item, or the list changed under the note: only keep it while the quantity still matches
    local _, bd = parts()
    if noted and bd and quantity(bd) ~= noted then hide() end
  end
  C_Timer.After(0, function() pcall(hookList) end)
end)
