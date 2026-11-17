-- EverlookDB Auctions: auction house prices for WoW Forever.
--   Full scan   Update prices on the bar along the auction house's bottom reads every auction at once (about
--               30 seconds, allowed about every 15 minutes, and automatic by default)
--   Searches    prices from the normal Blizzard search results are kept too, no scan needed
--   Tooltips    lowest buyout per item, how many are up, how old the price is, and the 30-day low
-- Prices are kept per realm and auction house (Alliance, Horde, or the neutral houses in Booty Bay, Gadgetzan and
-- Everlook). Each full scan is also kept as a summary for EverlookDB.com: region, realm, which auction house, the
-- server time, and per item version (item + random suffix) the lowest, 10th-percentile and median price per unit,
-- quantity, auctions, bid-only auctions, auctions with bids, time left and lowest bid. Sellers, bidders and other
-- players are never kept.
-- /eah for status, /eah scan to start a full scan while the auction house is open.

local ADDON, ns = ...
local VERSION = 2
local SCAN_COOLDOWN = 15 * 60   -- the server allows one full scan about every 15 minutes
local SCAN_TIMEOUT = 90         -- no answer by then: the server refused (throttled) or the AH closed
local BATCH = 1000              -- auctions read per frame, so a big scan doesn't freeze the game
local LOADS_PER_STEP = 15       -- item-detail requests per frame: a flood of them delays the player's own buys and posts
local YIELD_FOR = 4             -- seconds a running scan pauses after the player buys, bids, posts or cancels
local HISTORY_DAYS = 30
local MAX_SCANS = 4             -- full scans kept for upload to EverlookDB.com (newest; about 300 KB each)
local STALE = 24 * 3600         -- older prices are shown grey
-- Zones whose auction house is the neutral one (Classic UiMapIDs): Stranglethorn Vale, Tanaris, Winterspring
local NEUTRAL_ZONES = { [1434] = true, [1446] = true, [1452] = true }

local db
local house          -- the house key while an auction house is open, e.g. "Everlook-Alliance"
local houseSide      -- "Alliance", "Horde" or "Neutral" while an auction house is open
local panel          -- the bar along the bottom of the auction house
local scan = nil     -- { started = time, mode = "replicate"|"getall" } while a full scan runs

-- The player always goes first: while one of their auction house actions waits for the server, or for a few seconds
-- after it, a running scan stops reading and stops asking for item details.
local yieldUntil, awaiting, sentAt = 0, 0, 0
local function yielding()
  -- a reply that never comes stops counting after 5 seconds, so a lost one can't stall the scan
  return (awaiting > 0 and GetTime() - sentAt < 5) or GetTime() < yieldUntil
end
local function playerActed() yieldUntil = GetTime() + YIELD_FOR end
do
  local api = C_AuctionHouse or {}
  for _, name in ipairs({ "PlaceBid", "StartCommoditiesPurchase", "ConfirmCommoditiesPurchase", "PostItem",
      "PostCommodity", "CancelAuction" }) do
    if api[name] then hooksecurefunc(api, name, playerActed) end
  end
  for _, name in ipairs({ "PlaceAuctionBid", "PostAuction", "StartAuction", "CancelAuction" }) do
    if _G[name] then hooksecurefunc(name, playerActed) end
  end
end

-- Forever hides some values from addons ("secret values"). Treat any of them as unknown.
local isSecret = issecretvalue or function() return false end
local function ok(v)
  if v == nil or isSecret(v) then return nil end
  return v
end

local function say(msg) print("|cffffd100EverlookDB Auctions:|r " .. msg) end

-- Text the player typed or named (a command, a list name), safe to print: a lone | starts a WoW escape code and
-- garbles what follows, so it is doubled.
local function plain(text) return (tostring(text or ""):gsub("|", "||")) end

local function money(copper)
  copper = math.floor(copper or 0)
  if GetMoneyString then return GetMoneyString(copper, true) end
  local g, s, c = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
  return (g > 0 and g .. "g " or "") .. ((g > 0 or s > 0) and s .. "s " or "") .. c .. "c"
end

local function num(n) return BreakUpLargeNumbers and BreakUpLargeNumbers(n or 0) or tostring(n or 0) end

local function ago(t)
  local d = time() - (t or 0)
  if d < 90 then return "just now" end
  if d < 5400 then return math.floor(d / 60 + 0.5) .. " min ago" end
  if d < 129600 then return math.floor(d / 3600 + 0.5) .. " h ago" end
  return math.floor(d / 86400 + 0.5) .. " days ago"
end

-- Which auction API this client has: "modern" (C_AuctionHouse, retail UI) or "classic" (QueryAuctionItems).
local function apiKind()
  if C_AuctionHouse and C_AuctionHouse.ReplicateItems then return "modern" end
  if QueryAuctionItems then return "classic" end
  return nil
end

---------------------------------------------------------------------------------------------------------------------
-- Saved data
--   db.houses[key] = {
--     scanned = time of the last complete full scan,
--     tried   = time of the last full-scan request (for the cooldown),
--     items   = { [itemID] = { unit buyout (copper, lowest), quantity up, auctions (nil from searches), time } },
--     days    = { [itemID] = { [day number] = lowest unit buyout that day } },
--   }

local function zoneMapID()
  local map = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
  local info = map and C_Map.GetMapInfo(map)
  -- walk up from towns and caves (map type 4+) to the zone
  while info and (info.mapType or 0) > 3 and (info.parentMapID or 0) > 0 do
    info = C_Map.GetMapInfo(info.parentMapID)
  end
  return info and info.mapID
end

local function factionKey()
  return (GetRealmName() or "?") .. "-" .. (UnitFactionGroup("player") or "?")
end

local function currentHouseKey()
  local side = UnitFactionGroup("player") or "?"
  if NEUTRAL_ZONES[zoneMapID() or 0] then side = "Neutral" end
  return (GetRealmName() or "?") .. "-" .. side, side
end

local function getHouse(key)
  local h = db.houses[key]
  if not h then
    h = { items = {}, days = {} }
    db.houses[key] = h
  end
  return h
end

local function today() return math.floor(time() / 86400) end

local function noteDay(h, id, unit, day)
  local d = h.days[id]
  if not d then d = {}; h.days[id] = d end
  if not d[day] or unit < d[day] then d[day] = unit end
end

local function pruneDays(h)
  local oldest = today() - HISTORY_DAYS
  for id, d in pairs(h.days) do
    local any = false
    for day in pairs(d) do
      if day < oldest then d[day] = nil else any = true end
    end
    if not any then h.days[id] = nil end
  end
end

---------------------------------------------------------------------------------------------------------------------
-- The bar along the bottom of the auction house, beside the money: which house, how many items are priced, how old
-- the prices are, and the Update prices button (a gold progress bar while an update runs). Blizzard's window grows
-- by BAR_H to make room, so its lists keep their height; the addon's own tabs stop above the bar (ns.BAR_H).

local BAR_H = 28
ns.BAR_H = BAR_H
local FLASH_FOR = 6             -- seconds a message ("Prices updated", an error) stays on the bar
local flash                     -- { text, color, till }

local function setStatus(text, color)
  flash = text and text ~= "" and { text = text, color = color, till = GetTime() + FLASH_FOR } or nil
end

local RETRY_AFTER = 60          -- an update that didn't finish can be tried again by hand after a minute

-- An update was started but never finished (UI reloaded, auction house closed, or no answer from the server).
local function unfinished(h)
  return not scan and h.tried ~= nil and (not h.scanned or h.scanned < h.tried)
end

-- Seconds until Update prices may be used again.
local function scanWait(h)
  if not h.tried then return 0 end
  return h.tried + (unfinished(h) and RETRY_AFTER or SCAN_COOLDOWN) - time()
end

-- How long an update should take: as long as the last one on this house, else about 30 seconds.
local function expected(h)
  return math.min(math.max(h.took or 30, 10), 120)
end

local function refreshPanel()
  if not panel or not house then return end
  local T = ns.T
  local h = getHouse(house)
  if scan then
    local took = time() - scan.started
    local est = expected(h)
    local pct = math.min(0.95, took / est)
    local text
    if yielding() then
      text = "Updating prices… waiting for your purchase"
    elseif est - took >= 2 then
      text = ("Updating prices… about %d seconds left · keep browsing"):format(est - took)
    else
      text = "Updating prices… almost done · keep browsing"
    end
    panel.text:SetText(text)
    panel.text:SetTextColor(unpack(T.text))
    panel.button:Hide()
    local bar = panel.bar
    bar:Show()
    bar.fill:SetWidth(math.max(1, (bar:GetWidth() - 2) * pct))
    bar.label:SetText(("%d%%"):format(pct * 100))
    bar.label:SetTextColor(unpack(pct >= 0.5 and T.onAccent or T.text))
    return
  end
  panel.bar:Hide()
  panel.button:Show()
  local bad = unfinished(h)
  if flash and GetTime() < flash.till then
    panel.text:SetText(flash.text)
    panel.text:SetTextColor(unpack(flash.color or T.text))
  elseif bad then
    -- not alarm red: nothing is lost, the prices are as they were; red is kept for real problems
    panel.text:SetText("The last price update was cut off by a reload or closing the AH. Try again.")
    panel.text:SetTextColor(unpack(T.places.prices))
  else
    flash = nil
    local n = 0
    for _ in pairs(h.items) do n = n + 1 end
    panel.text:SetText(("%s%s|r · %s items priced · %s"):format(ns.UI.hex(T.places.prices), house:match("%-(%a+)$") or "?",
      num(n), h.scanned and ("updated " .. ago(h.scanned)) or "no update yet"))
    panel.text:SetTextColor(unpack(T.text))
  end
  local wait = scanWait(h)
  if wait > 0 then
    panel.button:Disable()
    -- "Next update" only when one will start by itself; with automatic updates off it is when one may be started
    local lead = bad and "Try again in" or db.auto == false and "Allowed in" or "Next update"
    panel.button:SetText(("%s %d:%02d"):format(lead, math.floor(wait / 60), wait % 60))
  else
    panel.button:Enable()
    panel.button:SetText(bad and "Try again" or "Update prices")
  end
end

local startScan

-- Once: Blizzard's window and its category list grow by BAR_H (Buy's results and the commodity view follow the list),
-- and the item view, which reaches the window's bottom, stops above the bar.
local grown = false
local function grow(ah)
  if grown then return end
  grown = true
  pcall(function()
    ah:SetHeight(ah:GetHeight() + BAR_H)
    if ah.CategoriesList then ah.CategoriesList:SetHeight(ah.CategoriesList:GetHeight() + BAR_H) end
    local f = ah.ItemBuyFrame
    if f then
      local points = {}
      for i = 1, f:GetNumPoints() do points[i] = { f:GetPoint(i) } end
      f:ClearAllPoints()
      for _, p in ipairs(points) do
        if p[1] == "BOTTOM" and p[2] == ah then p[5] = (p[5] or 0) + BAR_H end
        f:SetPoint(unpack(p))
      end
    end
  end)
end

local function tipText()
  local h = house and getHouse(house)
  local secs = h and expected(h) or 30
  if db.auto == false then
    return ("Automatic updates are off: press Update prices, or type /eah auto on. An update reads every auction on this auction house in about %d seconds, and you can keep buying and selling meanwhile. The server allows one about every 15 minutes."):format(secs)
  end
  return ("Prices update by themselves when you open the auction house and every 15 minutes while it is open. An update reads every auction in about %d seconds, and you can keep buying and selling meanwhile."):format(secs)
end

local function makePanel(parent)
  local UI, T = ns.UI, ns.T
  local modern = parent == _G.AuctionHouseFrame
  local f = UI.own(CreateFrame("Frame", "EverlookAuctionsBar", parent))
  f:SetHeight(BAR_H)
  if modern then
    grow(parent)
    -- a raised band across the window's bottom with a line on top in the price updates' colour; the money display
    -- sits on it, the bar's content to its right
    local band = parent:CreateTexture(nil, "BACKGROUND", nil, -6)
    band:SetPoint("BOTTOMLEFT", 1, 1)
    band:SetPoint("BOTTOMRIGHT", -1, 1)
    band:SetHeight(BAR_H + 2)
    UI.shade(band, T.raised, UI.LIFT)
    local line = UI.line(parent, true, T.places.prices, "BORDER")
    line:SetPoint("BOTTOMLEFT", band, "TOPLEFT")
    line:SetPoint("BOTTOMRIGHT", band, "TOPRIGHT")
    f:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", 182, 2)
    f:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -6, 2)
  else
    -- the old auction house window: the bar hangs under it
    f:SetPoint("TOPLEFT", parent, "BOTTOMLEFT", 14, -4)
    f:SetPoint("TOPRIGHT", parent, "BOTTOMRIGHT", -40, -4)
    UI.panel(f, T.bg, T.places.prices)
  end
  UI.place(f, "prices")   -- the bar's own colour: price updates, not buying or posting
  f:SetFrameLevel(parent:GetFrameLevel() + 200)
  f:EnableMouse(true)

  local mark = f:CreateTexture(nil, "ARTWORK")
  mark:SetSize(16, 16)
  mark:SetPoint("LEFT", 4, 0)
  mark:SetTexture("Interface\\AddOns\\" .. ADDON .. "\\Media\\icon")

  -- a small quiet button: updating prices is housekeeping, not a money action like Buy or Post
  f.button = UI.button(f, "Update prices", 128, 18, "quiet")
  f.button:SetPoint("RIGHT", -2, 0)
  f.button:SetScript("OnClick", function() startScan() end)
  UI.tip(f.button, "Update prices", tipText)

  local bar = CreateFrame("Frame", nil, f)
  bar:SetAllPoints(f.button)
  UI.panel(bar, T.input, T.edge)
  bar.fill = bar:CreateTexture(nil, "ARTWORK")
  bar.fill:SetPoint("TOPLEFT", 1, -1)
  bar.fill:SetPoint("BOTTOMLEFT", 1, 1)
  bar.fill:SetWidth(1)
  bar.fill:SetColorTexture(unpack(T.places.prices))
  bar.label = UI.text(bar, "small", "OVERLAY")
  bar.label:SetPoint("CENTER")
  bar.label:SetShadowOffset(0, 0)
  bar:EnableMouse(true)
  UI.tip(bar, "Updating prices", tipText)
  bar:Hide()
  f.bar = bar

  f.text = UI.text(f, "body")
  f.text:SetPoint("LEFT", mark, "RIGHT", 8, 0)
  f.text:SetPoint("RIGHT", f.button, "LEFT", -12, 0)
  f.text:SetJustifyH("LEFT")
  f.text:SetWordWrap(false)
  UI.tip(f, "Auction prices", tipText)

  -- the countdown on the button and the progress bar, and a fresh update every 15 minutes while the auction house
  -- is open (this only runs while the bar, and so the auction house, is shown)
  local acc = 0
  f:SetScript("OnUpdate", function(_, dt)
    acc = acc + dt
    if acc < (scan and 0.2 or 1) then return end
    acc = 0
    refreshPanel()
    if db.auto ~= false and not scan and house then
      local h = getHouse(house)
      if h.tried and time() - h.tried >= SCAN_COOLDOWN then startScan(true) end
    end
  end)
  return f
end

local function ahFrame()
  return _G.AuctionHouseFrame or _G.AuctionFrame
end

---------------------------------------------------------------------------------------------------------------------
-- Full scan

-- Reads auction i the same way for both APIs: count, buyout, itemID, minimum bid, current bid, item link, time-left
-- band (0 short .. 3 very long). Seller and bidder come back from the same call; they are skipped, never kept.
local function readModern(i)
  local okCall, _, _, count, _, _, _, _, minBid, _, buyout, bid, _, _, _, _, _, itemID = pcall(C_AuctionHouse.GetReplicateItemInfo, i)
  if not okCall then return nil end
  local okLink, link = pcall(C_AuctionHouse.GetReplicateItemLink, i)
  local okLeft, left = pcall(C_AuctionHouse.GetReplicateItemTimeLeft, i)
  return ok(count), ok(buyout), ok(itemID), ok(minBid), ok(bid), okLink and ok(link) or nil, okLeft and ok(left) or nil
end

local function readClassic(i)
  local okCall, _, _, count, _, _, _, _, minBid, _, buyout, bid, _, _, _, _, _, itemID = pcall(GetAuctionItemInfo, "list", i)
  if not okCall then return nil end
  local okLink, link = pcall(GetAuctionItemLink, "list", i)
  local okLeft, left = pcall(GetAuctionItemTimeLeft, "list", i)
  left = okLeft and ok(left)
  return ok(count), ok(buyout), ok(itemID), ok(minBid), ok(bid), okLink and ok(link) or nil, left and (left - 1) or nil
end

-- The item's own name ("Bandit Cloak"), when the game has it loaded.
local function baseName(id)
  local get = (C_Item and C_Item.GetItemNameByID) or GetItemInfo
  local okName, n = pcall(get, id)
  return okName and n or nil
end

local linkSamples   -- set while a scan is read: a few links of random-stat items, so the format can be checked

-- "item:ID:enchant:gem1:gem2:gem3:gem4:suffix:unique:level:spec:mods:context:numBonus:bonus1:..."
-- -> variant key "ID:suffix", the suffix, and the shown name. Random stats ("of the Bear") are the old suffix field,
-- or, when that is empty and the shown name differs from the item's own name, the first bonus ID.
local function variantOf(id, link)
  if type(link) ~= "string" then return nil end
  local rest, name = link:match("|Hitem:%-?%d+:([^|]*)|h%[(.-)%]|h")
  if not rest then return nil end
  local f = { strsplit(":", rest) }
  local suffix = tonumber(f[6]) or 0
  if suffix == 0 then
    local base = baseName(id)
    if base and name and name ~= base then
      local nb = tonumber(f[12]) or 0
      if nb > 0 then suffix = tonumber(f[13]) or 0 end
      if linkSamples and #linkSamples < 30 then
        -- unique ID, level and spec say nothing about the item; blank them
        f[7], f[8], f[9] = "", "", ""
        linkSamples[#linkSamples + 1] = id .. ":" .. table.concat(f, ":") .. " [" .. name .. "]"
      end
    end
  end
  return id .. ":" .. suffix, suffix, name
end

-- Lowest, 10th-percentile and median price per unit, counting every item in a stack (not every auction).
local function summarize(v)
  local n = #v.units
  if n == 0 then return nil end
  local idx = {}
  for k = 1, n do idx[k] = k end
  local units, counts = v.units, v.counts
  table.sort(idx, function(a, b) return units[a] < units[b] end)
  local total = 0
  for k = 1, n do total = total + counts[k] end
  local acc, p10, med = 0, nil, nil
  for _, k in ipairs(idx) do
    acc = acc + counts[k]
    if not p10 and acc >= total * 0.1 then p10 = units[k] end
    if acc >= total * 0.5 then med = units[k]; break end
  end
  return units[idx[1]], p10, med
end

local function addonVersion()
  local get = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
  local v = get and get(ADDON, "Version")
  return (v and not v:find("@")) and v or "dev"
end

-- Turns the variants into saved rows (a slice per frame), then stores the scan and the tooltip prices.
local function topUnlinked(unlinked)
  local list = {}
  for id, n in pairs(unlinked or {}) do list[#list + 1] = { id, n } end
  table.sort(list, function(a, b) return a[2] > b[2] end)
  local out = {}
  for k = 1, math.min(50, #list) do out[k] = list[k][1] .. ":" .. list[k][2] end
  return out
end

local function finishScan(h, vars, total, noLink, linkRounds, unlinked)
  local list = {}
  for key in pairs(vars) do list[#list + 1] = key end
  local rows, items = {}, {}
  local deals = {}   -- below vendor price: "unit:count,..." per item version (Vendor.lua), worked out once here
  local i = 1
  local function step()
    local stop = math.min(i + 499, #list)
    for k = i, stop do
      local key = list[k]
      local v = vars[key]
      local low, p10, med = summarize(v)
      -- low,p10,median,quantity,auctions,bid-only,with bids,short,medium,long,very long,lowest bid[,suffix name]
      local row = table.concat({ low or "", p10 or "", med or "", v.qty, v.n, v.bidOnly, v.withBids,
        v.tl[1], v.tl[2], v.tl[3], v.tl[4], v.minBid or "" }, ",")
      if v.suffix ~= 0 and v.name then row = row .. "," .. v.name end
      rows[key] = row
      if ns.vendor and ns.vendor.scanDeals then
        local d = ns.vendor.scanDeals(v.id, v.units, v.counts)
        if d then deals[key] = d end
      end
      local it = items[v.id]
      if not it then it = { nil, 0, 0 }; items[v.id] = it end
      if low and (not it[1] or low < it[1]) then it[1] = low end
      it[2] = it[2] + v.qty
      it[3] = it[3] + v.n
    end
    i = stop + 1
    if i <= #list then C_Timer.After(0, step); return end

    local now, day = time(), today()
    h.items = {}
    for id, it in pairs(items) do
      h.items[id] = { it[1], it[2], it[3], now }
      if it[1] then noteDay(h, id, it[1], day) end
    end
    h.scanned = now
    pruneDays(h)
    local build = select(2, GetBuildInfo())
    table.insert(db.scans, {
      region = ok(GetCurrentRegionName and GetCurrentRegionName()),
      regionID = ok(GetCurrentRegion and GetCurrentRegion()),
      realm = ok(GetRealmName()),
      realmID = ok(GetRealmID and GetRealmID()),
      realmNormalized = ok(GetNormalizedRealmName and GetNormalizedRealmName()),
      side = scan.side,
      at = scan.at,                       -- server time the scan was requested (same clock for every player)
      took = GetServerTime() - scan.at,   -- seconds until the list was read
      build = build,
      addon = addonVersion(),
      auctions = total,
      noLink = noLink,                    -- auctions whose item link wasn't loaded (counted under suffix 0)
      linkRounds = linkRounds,            -- auctions still without a link after the first read and each retry
      noLinkItems = topUnlinked(unlinked), -- the 50 items with the most auctions that never got a link: "ID:auctions"
      linkSamples = linkSamples,          -- up to 30 links of random-stat items (unique ID, level and spec blanked)
      rows = rows,
      deals = deals,                      -- auctions under vendor price, or the cheapest ones of items not loaded
    })
    while #db.scans > MAX_SCANS do table.remove(db.scans, 1) end
    linkSamples = nil
    if ns.onScan then ns.onScan() end
    if db.reloadAfterScan then
      -- test mode (/eah test, one scan): reload so the game writes the scan to disk right away
      db.reloadAfterScan = nil
      say("test mode: reloading in 3 seconds so the scan is saved.")
      C_Timer.After(3, function() if not scan then ReloadUI() end end)
    end
    h.took = time() - scan.started
    scan = nil
    setStatus(("Prices updated · %s auctions, %s items"):format(num(total), num(#list)), ns.T.good)
    say(("full scan done: %s auctions, %s item versions."):format(num(total), num(#list)))
    refreshPanel()
  end
  step()
end

-- Adds one auction to its item version.
local function addAuction(vars, id, count, buyout, minBid, bid, link, left)
  local key, suffix, name = variantOf(id, link)
  if not key then key, suffix = id .. ":0", 0 end
  local v = vars[key]
  if not v then
    v = { id = id, suffix = suffix, units = {}, counts = {}, qty = 0, n = 0, bidOnly = 0, withBids = 0, tl = { 0, 0, 0, 0 } }
    vars[key] = v
  end
  if suffix ~= 0 and name and not v.name then v.name = name end
  v.qty = v.qty + count
  v.n = v.n + 1
  if buyout and buyout > 0 then
    v.units[#v.units + 1] = math.floor(buyout / count)
    v.counts[#v.counts + 1] = count
  else
    v.bidOnly = v.bidOnly + 1
  end
  if bid and bid > 0 then v.withBids = v.withBids + 1 end
  if minBid and minBid > 0 then
    local mb = math.floor(minBid / count)
    if not v.minBid or mb < v.minBid then v.minBid = mb end
  end
  local band = left and v.tl[left + 1]
  if band then v.tl[left + 1] = band + 1 end
end

local RETRY_WAITS = { 2, 3, 5 }   -- seconds before each re-read of auctions whose item wasn't loaded yet

-- Reads the whole list a slice per frame. Auctions whose item isn't loaded yet have no link (so no random suffix):
-- the game is asked to load those items, and they are read again up to three times before counting as suffix 0.
local function processList(total, first, read)
  if total <= 0 then
    -- an empty answer (refused or not loaded): never let it wipe the saved prices
    scan = nil
    setStatus("The server sent an empty list. Prices were left as they were.", ns.T.bad)
    say("the server sent an empty auction list; prices were left as they were.")
    refreshPanel()
    return
  end
  local h = getHouse(house)
  local vars, requested = {}, {}
  local unlinked = {}   -- item ID -> auctions that never got a link
  linkSamples = {}
  local load = C_Item and C_Item.RequestLoadItemDataByID
  local queue, qi = {}, 1   -- item IDs waiting to be asked for, a few per frame

  local function pump()
    local stop = math.min(qi + LOADS_PER_STEP - 1, #queue)
    for k = qi, stop do pcall(load, queue[k]) end
    qi = stop + 1
  end

  local function stopped()
    if not scan then return true end
    if scan.aborted then
      -- the auction house closed while reading: keep the old prices rather than half a scan
      scan = nil
      say("the full scan stopped because the auction house closed; prices were left as they were.")
      return true
    end
  end

  -- reads indices from `list` (or first..last), a slice per frame; `final` counts unlinked auctions as suffix 0
  local function pass(list, final, done)
    local n = list and #list or total
    local i, missing = 1, {}
    local function step()
      if stopped() then return end
      if yielding() then
        C_Timer.After(0.25, step)
        return
      end
      if load then pump() end
      local stop = math.min(i + BATCH - 1, n)
      for j = i, stop do
        local k = list and list[j] or (first + j - 1)
        local count, buyout, id, minBid, bid, link, left = read(k)
        if id and count and count > 0 then
          if link or final then
            addAuction(vars, id, count, buyout, minBid, bid, link, left)
            if final and not link then
              missing[#missing + 1] = k
              unlinked[id] = (unlinked[id] or 0) + 1
            end
          else
            missing[#missing + 1] = k
            if load and not requested[id] then requested[id] = true; queue[#queue + 1] = id end
          end
        end
      end
      i = stop + 1
      if i > n then done(missing) else C_Timer.After(0, step) end
    end
    step()
  end

  local round, rounds = 0, {}
  local function after(missing)
    rounds[#rounds + 1] = #missing
    if #missing == 0 or round >= #RETRY_WAITS then
      if #missing == 0 then
        finishScan(h, vars, total, 0, rounds, unlinked)
      else
        -- last try: whatever still has no link counts under suffix 0
        pass(missing, true, function(still)
          finishScan(h, vars, total, #still, rounds, unlinked)
        end)
      end
      return
    end
    round = round + 1
    local function drain()
      if stopped() then return end
      if load and qi <= #queue then
        if not yielding() then pump() end
        C_Timer.After(0, drain)
        return
      end
      requested, queue, qi = {}, {}, 1   -- ask again next round: some loads fail or get dropped
      C_Timer.After(RETRY_WAITS[round], function()
        if stopped() then return end
        pass(missing, false, after)
      end)
    end
    drain()
  end
  pass(nil, false, after)
end

function startScan(auto)
  if scan then return end
  if not house or not ahFrame() or not ahFrame():IsShown() then say("open the auction house first."); return end
  local h = getHouse(house)
  local wait = scanWait(h)
  if wait > 0 then
    if auto then return end
    say(("the server allows one price update about every 15 minutes; try again in %d:%02d."):format(math.floor(wait / 60), wait % 60))
    return
  end
  local kind = apiKind()
  if kind == "modern" then
    scan = { started = time(), mode = "replicate", side = houseSide, at = GetServerTime() }
    C_AuctionHouse.ReplicateItems()
  elseif kind == "classic" then
    local _, canAll = CanSendAuctionQuery()
    if not canAll then
      -- the automatic update asks every second while the window is open: only a press of the button gets a reply
      if not auto then say("the server doesn't allow a price update right now; try again in a minute.") end
      return
    end
    scan = { started = time(), mode = "getall", side = houseSide, at = GetServerTime() }
    QueryAuctionItems("", nil, nil, 0, nil, nil, true, false, nil)
  else
    say("this client has no auction house API I know. Type /eah status and send that to EverlookDB.")
    return
  end
  h.tried = time()
  setStatus(nil)
  refreshPanel()
  local mine = scan
  C_Timer.After(SCAN_TIMEOUT, function()
    if scan == mine and not mine.reading then
      scan = nil
      setStatus("No answer from the server. Prices were left as they were.", ns.T.bad)
      say("the server didn't send the auction list (it may limit full scans). Try again later.")
      refreshPanel()
    end
  end)
end

---------------------------------------------------------------------------------------------------------------------
-- Prices from normal searches (modern auction house only: its browse results carry each item's lowest price)

local function captureBrowse()
  if scan or not house or not (C_AuctionHouse and C_AuctionHouse.GetBrowseResults) then return end
  local okCall, results = pcall(C_AuctionHouse.GetBrowseResults)
  if not okCall or type(results) ~= "table" then return end
  local h = getHouse(house)
  local now, day = time(), today()
  local seen = {}
  for _, r in ipairs(results) do
    local key = r.itemKey
    local id = key and ok(key.itemID)
    local price, qty = ok(r.minPrice), ok(r.totalQuantity)
    if id and price and price > 0 then
      local s = seen[id]
      -- one item can show as several rows (random suffixes): keep its lowest price and add up the quantities
      if not s then
        s = { price, qty or 0 }
        seen[id] = s
      else
        if price < s[1] then s[1] = price end
        s[2] = s[2] + (qty or 0)
      end
    end
  end
  for id, s in pairs(seen) do
    h.items[id] = { s[1], s[2], nil, now }
    noteDay(h, id, s[1], day)
  end
end

---------------------------------------------------------------------------------------------------------------------
-- Tooltips

-- Which tooltip lines to show (db.tip, set in the options): auction price, 30-day low and median, vendor price,
-- and with Shift held, the price of a full stack.
local function tipOn(key)
  local t = db and db.tip
  if not t or t[key] == nil then return key ~= "vendor" end   -- everything but the vendor line is on by default
  return t[key]
end
ns.tipOn = tipOn

local function stackSize(id)
  local okGet, n = pcall(C_Item.GetItemMaxStackSizeByID or function() return nil end, id)
  if okGet and n then return n end
  local info = { pcall(C_Item.GetItemInfo, id) }
  return info[1] and info[9] or 1
end

-- What the tooltip's auction line says for one auction house. stack = " x20" while Shift shows a full stack's price
-- (only on lines with a price). it = the saved price { low, quantity, auctions, time }
-- or nil; row = the newest full scan's row for this random-stat version ("of the Bear") or nil; scanned = when the
-- last full scan finished. Returns the left text, the price (nil for a text-only line) and whether it is current.
-- Every line says how old it is: a price is never shown as if it were live.
function ns.auctionLine(label, stack, it, row, scanned, now, serverNow)
  if row and row.low then
    local at = now - (serverNow - (row.at or serverNow))
    return ("%s%s, this version (%s up, %s)"):format(label, stack, row.qty or "?", ago(at)), row.low, now - at < STALE
  end
  if it and it[1] then
    return ("%s%s%s (%s up, %s)"):format(label, stack, row == false and ", any version" or "", it[2] or "?", ago(it[4])), it[1],
      now - (it[4] or 0) < STALE
  end
  if it and (it[2] or 0) > 0 then
    -- the last full scan found some, but only with a bid and no buyout
    return ("%s: %s up with bids only, no buyout (%s)"):format(label, it[2], ago(it[4])), nil, false
  end
  if scanned then return ("%s: none up in the full scan %s"):format(label, ago(scanned)), nil, false end
end

local function priceLines(tooltip, id)
  if not db then return end
  local stack = IsShiftKeyDown() and tipOn("stack") and stackSize(id) or 1
  local function each(p) return stack > 1 and (p * stack) or p end
  local suffix = stack > 1 and (" x" .. stack) or ""
  local keys = { factionKey() }
  local neutral = (GetRealmName() or "?") .. "-Neutral"
  if db.houses[neutral] then keys[#keys + 1] = neutral end
  -- random-stat gear: the tooltip's own version ("of the Bear") has its own price in the full scan
  local vkey
  if tooltip.GetItem then
    local okItem, _, link = pcall(tooltip.GetItem, tooltip)
    local key, sfx = variantOf(id, okItem and link or nil)
    if key and sfx and sfx ~= 0 then vkey = key end
  end
  for _, key in ipairs(keys) do
    local h = db.houses[key]
    local it = h and h.items[id]
    local side = key:match("%-(%a+)$")
    local label = side == "Neutral" and "Neutral AH" or "AH"
    if tipOn("auction") and h then
      -- false: a version that isn't in the newest scan, so the line says the price is for any version
      local row = vkey and (ns.scanRowFor(vkey, side) or false) or nil
      local left, price, fresh = ns.auctionLine(label, suffix, it, row, h.scanned and h.days[id] and h.scanned,
        time(), GetServerTime and GetServerTime() or time())
      if left and price then
        local r, g, b = fresh and 1 or 0.6, fresh and 0.82 or 0.6, fresh and 0 or 0.6
        tooltip:AddDoubleLine(left, money(each(price)), r, g, b, 1, 1, 1)
      elseif left then
        tooltip:AddLine(left, 0.6, 0.6, 0.6)
      end
    end
    local d = h and h.days[id]
    if d and tipOn("history") then
      local list = {}
      for _, p in pairs(d) do list[#list + 1] = p end
      table.sort(list)
      if #list > 0 then
        local low, med = list[1], list[math.floor((#list + 1) / 2)]
        tooltip:AddDoubleLine("  " .. HISTORY_DAYS .. "-day low" .. (#list > 2 and " / median" or ""),
          money(each(low)) .. (#list > 2 and (" / " .. money(each(med))) or ""), 0.6, 0.6, 0.6, 0.8, 0.8, 0.8)
      end
    end
  end
  if tipOn("disenchant") and ns.disenchantValue then
    local value, oldest = ns.disenchantValue(id)
    if value then
      -- how old the oldest material price is, so an old estimate doesn't pass for today's
      local fresh = (oldest or 0) < STALE
      tooltip:AddDoubleLine(("Disenchant (estimate, prices %s)"):format(ago(time() - (oldest or 0))), money(value),
        0.6, 0.6, 0.6, fresh and 1 or 0.6, fresh and 1 or 0.6, fresh and 1 or 0.6)
    end
  end
  if tipOn("vendor") then
    local info = { pcall(C_Item.GetItemInfo, id) }
    local sell = info[1] and info[12]
    if sell and sell > 0 then tooltip:AddDoubleLine("Vendor" .. suffix, money(each(sell)), 0.6, 0.6, 0.6, 1, 1, 1) end
  end
end

local function hookTooltips()
  if TooltipDataProcessor and Enum.TooltipDataType then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip, data)
      local id = data and ok(data.id)
      if id then priceLines(tooltip, id) end
    end)
  end
end

---------------------------------------------------------------------------------------------------------------------
-- Events and commands

local function onShow(retried)
  house, houseSide = currentHouseKey()
  local parent = ahFrame()
  -- Blizzard loads the auction house UI on this same event; if it isn't there yet, look again next frame
  if not parent and not retried then C_Timer.After(0, function() if house then onShow(true) end end); return end
  if parent and not panel then panel = makePanel(parent) end
  setStatus(nil)
  refreshPanel()
  -- Automatic full scan when the last one is 15+ minutes old (db.auto, on by default; /eah auto off).
  -- A short wait first, so the auction house window finishes opening before the list comes in.
  if db.auto ~= false and not scan then
    local h = getHouse(house)
    if not h.tried or time() - h.tried >= SCAN_COOLDOWN then
      C_Timer.After(1.5, function()
        if house and not scan and ahFrame() and ahFrame():IsShown() then startScan(true) end
      end)
    end
  end
end

local events = {}

function events.ADDON_LOADED(name)
  if name ~= ADDON then return end
  EverlookAuctionsDB = EverlookAuctionsDB or {}
  db = EverlookAuctionsDB
  db.version = VERSION
  db.houses = db.houses or {}
  db.scans = db.scans or {}
  -- day lows older than 30 days go at every load too: with automatic updates off they would otherwise pile up from
  -- searches alone (they used to be cut only when a full scan finished)
  for _, h in pairs(db.houses) do
    h.items, h.days = h.items or {}, h.days or {}
    pruneDays(h)
  end
  hookTooltips()
end

function events.AUCTION_HOUSE_SHOW() onShow() end

function events.AUCTION_HOUSE_CLOSED()
  if scan then
    if scan.reading then scan.aborted = true else scan = nil end
  end
  house = nil
  awaiting = 0
end

function events.REPLICATE_ITEM_LIST_UPDATE()
  if not scan or scan.mode ~= "replicate" or scan.reading then return end
  scan.reading = true
  local total = C_AuctionHouse.GetNumReplicateItems() or 0
  processList(total, 0, readModern)   -- the replicate list counts from 0
end

function events.AUCTION_ITEM_LIST_UPDATE()
  if not scan or scan.mode ~= "getall" or scan.reading then return end
  scan.reading = true
  local _, total = GetNumAuctionItems("list")
  processList(total or 0, 1, readClassic)
end

function events.AUCTION_HOUSE_THROTTLED_MESSAGE_SENT() awaiting = awaiting + 1; sentAt = GetTime() end
local function answered() awaiting = math.max(0, awaiting - 1) end
events.AUCTION_HOUSE_THROTTLED_MESSAGE_RESPONSE_RECEIVED = answered
events.AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED = answered
function events.AUCTION_HOUSE_THROTTLED_SYSTEM_READY() awaiting = 0 end

function events.AUCTION_HOUSE_BROWSE_RESULTS_UPDATED() captureBrowse() end
function events.AUCTION_HOUSE_BROWSE_RESULTS_ADDED() captureBrowse() end

local frame = CreateFrame("Frame")
for e in pairs(events) do pcall(frame.RegisterEvent, frame, e) end  -- some events exist only on one API
frame:SetScript("OnEvent", function(_, e, ...) events[e](...) end)

local showStatus   -- /eah status (below)
SLASH_EVERLOOKAUCTIONS1 = "/eah"
SlashCmdList.EVERLOOKAUCTIONS = function(msg)
  msg = (msg or ""):lower():match("^%s*(.-)%s*$")
  if ns.slash and ns.slash(msg) then return end
  if msg == "scan" then startScan(); return end
  if msg == "debug" then
    -- what is shown where: for bug reports about tabs and panels ("I click Selling and nothing changes")
    local ah = _G.AuctionHouseFrame
    say(("debug: AuctionHouseFrame %s, mode %s, tab %s"):format(ah and (ah:IsShown() and "shown" or "hidden") or "missing",
      tostring(ah and ah.GetDisplayMode and select(2, pcall(ah.GetDisplayMode, ah))), tostring(ah and ah.selectedTab)))
    for _, name in ipairs({ "EverlookAuctionsBar", "EverlookAuctionsSelling", "EverlookAuctionsShopping", "EverlookAuctionsQueryResults",
        "EverlookAuctionsSellingTab", "EverlookAuctionsShoppingTab", "EverlookAuctionsCrafting", "EverlookAuctionsRecipeList" }) do
      local f = _G[name]
      if not f then
        print(("  %s: not made"):format(name))
      else
        local w, h = f:GetSize()
        print(("  %s: %s (visible %s), %dx%d, strata %s level %d, alpha %.2f, parent %s"):format(name,
          f:IsShown() and "shown" or "hidden", tostring(f:IsVisible()), w or 0, h or 0, f:GetFrameStrata(),
          f:GetFrameLevel(), f:GetEffectiveAlpha(), tostring(f:GetParent() and f:GetParent():GetName())))
      end
    end
    if ns.ahq then for _, line in ipairs(ns.ahq.debugLines()) do print("  " .. line) end end
    if ns.craftDebug and ns.craftDebug() then
      print(("  crafting box: %d px right of the profession window (clear of its tab buttons)"):format(ns.craftDebug()))
    end
    for i, t in ipairs(ah and ah.Tabs or {}) do
      print(("  Blizzard tab %d: %s, id %s"):format(i, plain(t:GetText()), tostring(t:GetID())))
    end
    -- labels on screen that don't fit their button or tag
    local cut = ns.UI and ns.UI.cutOff and ns.UI.cutOff() or {}
    print(#cut == 0 and "  no cut-off labels on screen" or ("  %d cut-off labels on screen:"):format(#cut))
    for i = 1, math.min(15, #cut) do print("    " .. cut[i]) end
    return
  end
  if msg == "test" then
    db.reloadAfterScan = not db.reloadAfterScan
    say(db.reloadAfterScan and "test mode on: the UI reloads after the next full scan, so it is saved at once."
      or "test mode off.")
    return
  end
  if msg == "auto off" or msg == "auto on" then
    db.auto = msg == "auto on"
    if ns.optionsRefresh then ns.optionsRefresh() end   -- the options window shows the change if it is open
    say(db.auto and "prices update by themselves (when you open the auction house, then every 15 minutes while it is open)."
      or "automatic price updates are off. Press Update prices or type /eah scan when you want one.")
    return
  end
  if msg == "auto" then
    say(("automatic price updates are %s. Set them with /eah auto on or /eah auto off."):format(db.auto == false and "off" or "on"))
    return
  end
  if msg == "" then
    -- bare /eah: the options (Options.lua says so itself, or why they didn't open)
    if not (ns.slash and ns.slash("options")) then say("the options aren't loaded. /eah help lists the commands.") end
    return
  end
  if msg == "status" then
    say("status")
    showStatus()
    return
  end
  if msg == "help" or msg == "?" or msg == "commands" then
    say("commands")
    print("  /eah  open the options")
    print("  /eah status  which auction houses have prices, and how old")
    print("  /eah scan  update prices now (auction house open)")
    if ns.help then ns.help() end
    print(("  /eah auto on  or  /eah auto off  update prices by themselves while the auction house is open (now %s)"):format(db.auto == false and "off" or "on"))
    print(("  /eah test  reload after every full scan so it is saved at once (now %s)"):format(db.reloadAfterScan and "on" or "off"))
    print("  /eah debug  what is shown where, the addon's auction house searches and any cut-off labels (for bug reports)")
    return
  end
  say(("unknown command \"%s\". /eah help lists the commands, for example /eah scan or /eah undercut 1s."):format(plain(msg)))
end

-- /eah status
function showStatus()
  local kind = apiKind()
  print(("  auction API: %s; frame: %s"):format(kind or "none found",
    _G.AuctionHouseFrame and "AuctionHouseFrame (modern)" or _G.AuctionFrame and "AuctionFrame (classic)" or "not loaded yet"))
  local any = false
  for key, h in pairs(db.houses) do
    local n = 0
    for _ in pairs(h.items) do n = n + 1 end
    print(("  %s: %s items priced, %s"):format(key, num(n), h.scanned and ("last full scan " .. ago(h.scanned)) or "no full scan yet"))
    any = true
  end
  if not any then print("  no prices yet: open the auction house and let it update prices, or just search.") end
  print("  /eah help lists the commands.")
end

-- The full scan, for Advanced search's Below vendor: how old the last one is, whether one can start now (else in how
-- many seconds), and starting one.
ns.scanAge = function()
  local h = house and db.houses[house]
  return h and h.scanned and (time() - h.scanned) or nil
end
ns.scanWaitLeft = function() return house and math.max(0, scanWait(getHouse(house))) or nil end
ns.scanning = function() return scan ~= nil end
ns.startScan = function() startScan() end

-- Shared with Sell.lua, Search.lua and Skin.lua
ns.db = function() return db end
ns.house = function() return house end
ns.money, ns.num, ns.ago, ns.say, ns.variantOf, ns.ahFrame, ns.ok = money, num, ago, say, variantOf, ahFrame, ok
ns.plain = plain

-- Which saved auction house to read: the one given ("Alliance", "Horde" or "Neutral" on this realm), else the one
-- that is open, else the player's own faction's.
local function keyFor(side)
  if side then return (GetRealmName() or "?") .. "-" .. side end
  return house or factionKey()
end

-- The newest full scan's row for "id:suffix": { low, p10, med, qty, n, at } (at is server time), or nil.
function ns.scanRowFor(key, side)
  if not db then return nil end
  local realm, want = keyFor(side):match("^(.*)%-(%a+)$")
  for k = #db.scans, 1, -1 do
    local sc = db.scans[k]
    if sc.realm == realm and sc.side == want then
      local row = sc.rows and sc.rows[key]
      if not row then return nil end
      local f = { strsplit(",", row) }
      return { low = tonumber(f[1]), p10 = tonumber(f[2]), med = tonumber(f[3]), qty = tonumber(f[4]), n = tonumber(f[5]), at = sc.at }
    end
  end
end

-- Lowest price per day for an item (last 30 days), oldest first: { { day, price }, ... }.
function ns.historyFor(id, side)
  local out = {}
  local h = db and db.houses[keyFor(side)]
  local d = h and h.days[id]
  if d then for day, p in pairs(d) do out[#out + 1] = { day, p } end end
  table.sort(out, function(a, b) return a[1] < b[1] end)
  return out
end

-- The saved price for an item: { lowest unit buyout, quantity, auctions, time } or nil.
function ns.itemFor(id, side)
  local h = db and db.houses[keyFor(side)]
  return h and h.items[id]
end

-- What disenchanting an item is worth: the sum over its materials of chance x average count x the material's
-- lowest saved price (Disenchant.lua, from classic-db). Returns the value in copper, the age in seconds of the oldest
-- material price, and the materials { { itemID, chance %, min, max, price }, ... }; nil when the item can't be
-- disenchanted or a material has no price yet.
function ns.disenchantValue(id, side)
  local kind = ns.DE_ITEMS and ns.DE_ITEMS[id]
  local mats = kind and ns.DE_GROUPS[kind]
  if not mats then return nil end
  local value, oldest, out = 0, 0, {}
  for k, m in ipairs(mats) do
    local it = ns.itemFor(m[1], side)
    if not it or not it[1] then return nil end
    value = value + m[2] / 100 * (m[3] + m[4]) / 2 * it[1]
    oldest = math.max(oldest, time() - (it[4] or 0))
    out[k] = { m[1], m[2], m[3], m[4], it[1] }
  end
  return math.floor(value + 0.5), oldest, out
end

-- The same three for the open auction house only (nil while it is closed).
function ns.latestRow(key) return house and ns.scanRowFor(key) end
function ns.history(id) return house and ns.historyFor(id) or {} end
function ns.houseItem(id) return house and ns.itemFor(id) end
ns.today = today
