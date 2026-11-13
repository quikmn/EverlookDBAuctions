-- EverlookDB Auctions: selling.
--   Undercut   when Blizzard's sell frame fills in the cheapest auction someone else has up, the price is lowered by
--              your undercut (1 silver unless you set another with /eah undercut). Your own auctions are matched,
--              never undercut.
--   Nobody     when nobody is selling the item, the price comes from the last full scan (the typical price).
--   Bag list   a list beside the auction house of everything in your bags you can sell, with scan prices.
--              Click one to put it in Blizzard's sell frame, then press Post as usual.
-- Posting itself is always Blizzard's own Post button: one click per post.

local ADDON, ns = ...

local ROWS = 16
local ROW_H = 20

local S = { rows = {}, items = {}, offset = 0 }

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

-- The undercut setting: { copper = n } or { pct = n }. Default 1 silver.
local function undercut()
  local db = ns.db()
  return db and db.undercut or { copper = 100 }
end

local function undercutText()
  local u = undercut()
  if u.pct then return u.pct .. "%" end
  if (u.copper or 0) == 0 then return "none (match the cheapest)" end
  return ns.money(u.copper)
end

-- Auction house prices go in whole silver.
local function toSilver(copper) return math.max(100, math.floor(copper / 100) * 100) end

-- The price to post at when someone else's cheapest auction is `p`.
local function undercutPrice(p)
  local u = undercut()
  local new
  if u.pct then
    new = p * (1 - u.pct / 100)
  else
    new = p - (u.copper or 100)
  end
  new = math.floor(new / 100) * 100
  local wantsBelow = u.pct and u.pct > 0 or (u.copper or 0) > 0
  if wantsBelow and new >= p then new = math.floor((p - 1) / 100) * 100 end
  return math.max(100, new)
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
-- Hooks on Blizzard's sell frames

local function note(text)
  if S.frame then S.frame.note:SetText(text or "") end
end

local function describe(loc)
  local row = scanRow(loc)
  if not row then
    note("No full-scan price for this item yet.")
    return
  end
  local parts = {}
  if row.low then parts[#parts + 1] = "lowest " .. ns.money(row.low) end
  if row.med then parts[#parts + 1] = "typical " .. ns.money(row.med) end
  note(("Last scan (%s): %s, %s up."):format(ns.ago(row.at), table.concat(parts, ", "), ns.num(row.qty or 0)))
end

-- Nobody is selling it right now: fill in the scan's typical price (only over Blizzard's default guess).
local function fallback(frame, commodity)
  local loc = frame:GetItem()
  if not loc or not loc:IsValid() then return end
  if frame.PriceInput:GetAmount() ~= frame:GetDefaultPrice() then return end
  local n, full
  if commodity then
    local id = C_Item.GetItemID(loc)
    n, full = C_AuctionHouse.GetNumCommoditySearchResults(id), C_AuctionHouse.HasFullCommoditySearchResults(id)
  else
    local key = frame.listDisplayedItemKey
    if not key then return end
    n, full = C_AuctionHouse.GetNumItemSearchResults(key), C_AuctionHouse.HasFullItemSearchResults(key)
  end
  if (n or 0) > 0 or not full then return end
  local row = scanRow(loc)
  local p = row and (row.med or row.low)
  if p then
    frame.PriceInput:SetAmount(toSilver(p))
    note("Nobody is selling this now; the price is the typical price from the last full scan.")
  end
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
  hooksecurefunc(items, "UpdatePriceSelection", function(self) fallback(self, false) end)
  hooksecurefunc(goods, "UpdatePriceSelection", function(self) fallback(self, true) end)
  hooksecurefunc(items, "SetItem", function(self) if self:GetItem() then describe(self:GetItem()) end end)
  hooksecurefunc(goods, "SetItem", function(self) if self:GetItem() then describe(self:GetItem()) end end)
end

---------------------------------------------------------------------------------------------------------------------
-- Bag list

local function collect()
  wipe(S.items)
  local byKey = {}
  local lastBag = NUM_BAG_SLOTS or 4
  for bag = 0, lastBag do
    for slot = 1, (C_Container.GetContainerNumSlots(bag) or 0) do
      local info = C_Container.GetContainerItemInfo(bag, slot)
      if info and info.itemID and not info.isBound then
        local loc = ItemLocation:CreateFromBagAndSlot(bag, slot)
        local okValid, valid = pcall(C_AuctionHouse.IsSellItemValid, loc, false)
        if okValid and valid then
          local key = ns.variantOf(info.itemID, info.hyperlink) or (info.itemID .. ":0")
          local it = byKey[key]
          if not it then
            local row = ns.latestRow(key)
            it = {
              key = key, bag = bag, slot = slot, count = 0, icon = info.iconFileID, quality = info.quality,
              name = info.hyperlink and info.hyperlink:match("%[(.-)%]") or ("item " .. info.itemID),
              price = row and (row.med or row.low),
            }
            byKey[key] = it
            S.items[#S.items + 1] = it
          end
          it.count = it.count + (info.stackCount or 1)
        end
      end
    end
  end
  -- most valuable first; items without a scan price last, by name
  table.sort(S.items, function(a, b)
    local va, vb = a.price and a.price * a.count, b.price and b.price * b.count
    if va and vb then return va > vb end
    if va or vb then return va ~= nil end
    return a.name < b.name
  end)
end

local function render()
  local f = S.frame
  if not f then return end
  local maxOffset = math.max(0, #S.items - ROWS)
  if S.offset > maxOffset then S.offset = maxOffset end
  for k = 1, ROWS do
    local b, it = S.rows[k], S.items[S.offset + k]
    b.item = it
    if it then
      b.icon:SetTexture(it.icon)
      local color = it.quality and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[it.quality]
      b.name:SetText((color and color.hex or "|cffffffff") .. it.name .. "|r" .. (it.count > 1 and (" x" .. it.count) or ""))
      b.price:SetText(it.price and ns.money(it.price) or "|cff808080?|r")
      b:Show()
    else
      b:Hide()
    end
  end
  f.empty:SetShown(#S.items == 0)
  f.more:SetText(#S.items > ROWS and ("%d-%d of %d"):format(S.offset + 1, math.min(S.offset + ROWS, #S.items), #S.items) or "")
end

local function refresh()
  if not S.frame or not S.frame:IsShown() then return end
  collect()
  render()
end

local function makeRow(parent, k)
  local b = CreateFrame("Button", nil, parent)
  b:SetSize(196, ROW_H)
  b:SetPoint("TOPLEFT", parent.list, "TOPLEFT", 0, -(k - 1) * ROW_H)
  b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
  b.icon = b:CreateTexture(nil, "ARTWORK")
  b.icon:SetSize(16, 16)
  b.icon:SetPoint("LEFT", 0, 0)
  b.price = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  b.price:SetPoint("RIGHT", 0, 0)
  b.price:SetJustifyH("RIGHT")
  b.name = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  b.name:SetPoint("LEFT", b.icon, "RIGHT", 4, 0)
  b.name:SetPoint("RIGHT", b.price, "LEFT", -4, 0)
  b.name:SetJustifyH("LEFT")
  b.name:SetWordWrap(false)
  b:SetScript("OnClick", function(self)
    local it = self.item
    if not it or not _G.AuctionHouseFrame then return end
    local loc = ItemLocation:CreateFromBagAndSlot(it.bag, it.slot)
    if not loc:IsValid() then refresh(); return end
    AuctionHouseFrame:SetPostItem(loc)
  end)
  b:SetScript("OnEnter", function(self)
    if not self.item then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetBagItem(self.item.bag, self.item.slot)
    GameTooltip:AddLine("Click to sell: your price is filled in, then press Post.", 0.4, 0.8, 1, true)
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)
  return b
end

local function makeFrame()
  local panel = _G.EverlookAuctionsPanel
  if S.frame or not panel then return end
  local f = CreateFrame("Frame", "EverlookAuctionsSell", panel, "BackdropTemplate")
  f:SetSize(220, 92 + ROWS * ROW_H)
  f:SetPoint("TOPLEFT", panel, "BOTTOMLEFT", 0, -4)
  f:SetBackdrop(panel:GetBackdrop())
  f:SetBackdropColor(panel:GetBackdropColor())
  f:SetBackdropBorderColor(panel:GetBackdropBorderColor())

  local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  title:SetPoint("TOPLEFT", 12, -12)
  title:SetText("Sell from your bags")

  f.note = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  f.note:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
  f.note:SetWidth(196)
  f.note:SetJustifyH("LEFT")
  f.note:SetText("Click an item, check the price, press Post.")

  f.list = CreateFrame("Frame", nil, f)
  f.list:SetPoint("TOPLEFT", 12, -60)
  f.list:SetSize(196, ROWS * ROW_H)
  for k = 1, ROWS do S.rows[k] = makeRow(f, k) end

  f.empty = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  f.empty:SetPoint("TOPLEFT", f.list, "TOPLEFT", 0, -4)
  f.empty:SetText("Nothing in your bags can be sold here.")

  f.more = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  f.more:SetPoint("BOTTOMLEFT", 12, 12)

  f.cut = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  f.cut:SetPoint("BOTTOMRIGHT", -12, 12)

  f:EnableMouseWheel(true)
  f:SetScript("OnMouseWheel", function(_, delta)
    S.offset = math.max(0, S.offset - delta * 3)
    render()
  end)
  f:SetScript("OnShow", function()
    f.cut:SetText("undercut " .. undercutText())
    refresh()
  end)
  S.frame = f
  f.cut:SetText("undercut " .. undercutText())
end

---------------------------------------------------------------------------------------------------------------------
-- Events and commands

local ev = CreateFrame("Frame")
ev:RegisterEvent("AUCTION_HOUSE_SHOW")
ev:RegisterEvent("BAG_UPDATE_DELAYED")
ev:SetScript("OnEvent", function(_, e)
  if e == "AUCTION_HOUSE_SHOW" then
    -- the main panel is made on this same event (sometimes a frame later)
    C_Timer.After(0.2, function()
      hookSellFrames()
      makeFrame()
      S.offset = 0
      refresh()
    end)
  else
    refresh()
  end
end)

function ns.slash(msg)
  local arg = msg:match("^undercut%s*(.*)$")
  if not arg then return false end
  local db = ns.db()
  if arg == "" then
    ns.say("undercut is " .. undercutText() .. ". Set it with /eah undercut 1s, 50c, 1g, 5% or 0.")
    return true
  end
  local pct = tonumber(arg:match("^(%d+%.?%d*)%s*%%$") or "")
  if pct and pct < 100 then
    db.undercut = { pct = pct }
  elseif arg == "0" then
    db.undercut = { copper = 0 }
  else
    local copper = parseMoney(arg)
    if not copper then
      ns.say("didn't understand that. Examples: /eah undercut 1s, 50c, 1g, 5% or 0.")
      return true
    end
    db.undercut = { copper = copper }
  end
  if S.frame then S.frame.cut:SetText("undercut " .. undercutText()) end
  ns.say("undercut set to " .. undercutText() .. ".")
  return true
end

function ns.help()
  print(("  /eah undercut 1s|50c|5%%|0  how far under the cheapest auction to price (now %s)"):format(undercutText()))
end
