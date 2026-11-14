-- EverlookDB Auctions: auction house prices for WoW Forever.
--   Full scan   one button on the auction house reads every auction at once (allowed about every 15 minutes)
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
local HISTORY_DAYS = 30
local MAX_SCANS = 4             -- full scans kept for upload to EverlookDB.com (newest; about 300 KB each)
local STALE = 24 * 3600         -- older prices are shown grey
-- Zones whose auction house is the neutral one (Classic UiMapIDs): Stranglethorn Vale, Tanaris, Winterspring
local NEUTRAL_ZONES = { [1434] = true, [1446] = true, [1452] = true }

local db
local house          -- the house key while an auction house is open, e.g. "Everlook-Alliance"
local houseSide      -- "Alliance", "Horde" or "Neutral" while an auction house is open
local panel          -- the small frame beside the auction house
local scan = nil     -- { started = time, mode = "replicate"|"getall" } while a full scan runs

-- Forever hides some values from addons ("secret values"). Treat any of them as unknown.
local isSecret = issecretvalue or function() return false end
local function ok(v)
  if v == nil or isSecret(v) then return nil end
  return v
end

local function say(msg) print("|cffffd100EverlookDB Auctions:|r " .. msg) end

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
-- Panel beside the auction house

local function setStatus(text)
  if panel then panel.status:SetText(text or "") end
end

local RETRY_AFTER = 60          -- a scan that didn't finish can be tried again by hand after a minute

-- A scan was started but never finished (UI reloaded, auction house closed, or no answer from the server).
local function unfinished(h)
  return not scan and h.tried ~= nil and (not h.scanned or h.scanned < h.tried)
end

-- Seconds until the Full scan button may be used again.
local function scanWait(h)
  if not h.tried then return 0 end
  return h.tried + (unfinished(h) and RETRY_AFTER or SCAN_COOLDOWN) - time()
end

local function refreshPanel()
  if not panel or not house then return end
  local h = getHouse(house)
  local n = 0
  for _ in pairs(h.items) do n = n + 1 end
  panel.values[1]:SetText(house:match("%-(%a+)$") or "?")
  panel.values[2]:SetText(num(n))
  panel.values[3]:SetText(h.scanned and ago(h.scanned) or "never")
  panel.warn:SetText(unfinished(h) and "The last scan didn't finish." or "")
  local wait = scanWait(h)
  if scan then
    panel.button:Disable()
    panel.button:SetText("Scanning...")
  elseif wait > 0 then
    panel.button:Disable()
    panel.button:SetText(("Scan in %d:%02d"):format(math.floor(wait / 60), wait % 60))
  else
    panel.button:Enable()
    panel.button:SetText("Full scan")
  end
end

local startScan

-- The panel: a header with the addon's mark, what is saved for this auction house, and the Full scan button
-- (Search.lua adds Advanced search above it).
local function makePanel(parent)
  local UI, T = ns.UI, ns.T
  local f = UI.own(CreateFrame("Frame", "EverlookAuctionsPanel", parent))
  f:SetSize(220, 176)
  f:SetPoint("TOPLEFT", parent, "TOPRIGHT", 6, -24)
  f:SetFrameStrata(parent:GetFrameStrata())
  f:EnableMouse(true)
  UI.panel(f, T.bg, T.edge)
  UI.shadow(f, 5)

  local band = f:CreateTexture(nil, "BACKGROUND", nil, -7)
  band:SetPoint("TOPLEFT", 1, -1)
  band:SetPoint("TOPRIGHT", -1, -1)
  band:SetHeight(28)
  band:SetColorTexture(unpack(T.raised))
  local line = UI.line(f, true)
  line:SetPoint("TOPLEFT", band, "BOTTOMLEFT")
  line:SetPoint("TOPRIGHT", band, "BOTTOMRIGHT")
  local mark = f:CreateTexture(nil, "ARTWORK")
  mark:SetSize(16, 16)
  mark:SetPoint("LEFT", band, "LEFT", 9, 0)
  mark:SetTexture("Interface\\AddOns\\" .. ADDON .. "\\Media\\icon")
  local title = UI.text(f, "title")
  title:SetPoint("LEFT", mark, "RIGHT", 7, 0)
  title:SetText("EverlookDB Auctions")

  -- label / value pairs
  f.values = {}
  for k, label in ipairs({ "Auction house", "Items priced", "Last full scan" }) do
    local l = UI.text(f, "mute")
    l:SetPoint("TOPLEFT", 12, -40 - (k - 1) * 18)
    l:SetText(label)
    local v = UI.text(f, "small")
    v:SetPoint("TOPRIGHT", -12, -40 - (k - 1) * 18)
    v:SetJustifyH("RIGHT")
    f.values[k] = v
  end
  f.warn = UI.text(f, "small")
  f.warn:SetPoint("TOPLEFT", 12, -40 - 3 * 18)
  f.warn:SetTextColor(unpack(T.bad))

  f.button = UI.button(f, "Full scan", 196, 26)
  f.button:SetPoint("BOTTOMLEFT", 12, 40)
  f.button:SetScript("OnClick", function() startScan() end)

  f.status = UI.text(f, "mute")
  f.status:SetPoint("TOPLEFT", f.button, "BOTTOMLEFT", 0, -8)
  f.status:SetWidth(196)
  f.status:SetWordWrap(true)

  -- the cooldown countdown on the button, and a fresh full scan every 15 minutes while the auction house is open
  local acc = 0
  f:SetScript("OnUpdate", function(_, dt)
    acc = acc + dt
    if acc < 1 then return end
    acc = 0
    refreshPanel()
    -- this only runs while the panel (and so the auction house) is shown
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
    scan = nil
    setStatus(("Done: %s auctions, %s items."):format(num(total), num(#list)))
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
    setStatus("The server sent an empty list. Try again later.")
    say("the server sent an empty auction list; prices were left as they were.")
    refreshPanel()
    return
  end
  local h = getHouse(house)
  local vars, pending, requested = {}, {}, {}
  local unlinked = {}   -- item ID -> auctions that never got a link
  linkSamples = {}
  local load = C_Item and C_Item.RequestLoadItemDataByID

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
            if load and not requested[id] then requested[id] = true; pcall(load, id) end
          end
        end
      end
      i = stop + 1
      if list then
        setStatus(("Loading item details: %s left..."):format(num(n - math.min(i - 1, n))))
      else
        setStatus(("Reading %s / %s..."):format(num(math.min(i - 1, n)), num(n)))
      end
      if i > n then done(missing) else C_Timer.After(0, step) end
    end
    step()
  end

  local round, rounds = 0, {}
  local function after(missing)
    rounds[#rounds + 1] = #missing
    if #missing == 0 or round >= #RETRY_WAITS then
      if #missing == 0 then
        setStatus("Saving...")
        finishScan(h, vars, total, 0, rounds, unlinked)
      else
        -- last try: whatever still has no link counts under suffix 0
        pass(missing, true, function(still)
          setStatus("Saving...")
          finishScan(h, vars, total, #still, rounds, unlinked)
        end)
      end
      return
    end
    round = round + 1
    requested = {}   -- ask again each round: some loads fail or get dropped
    setStatus(("Loading item details for %s auctions..."):format(num(#missing)))
    C_Timer.After(RETRY_WAITS[round], function()
      if stopped() then return end
      pass(missing, false, after)
    end)
  end
  pass(nil, false, after)
end

function startScan(auto)
  if scan then return end
  if not house or not ahFrame() or not ahFrame():IsShown() then say("open the auction house first."); return end
  local h = getHouse(house)
  local wait = scanWait(h)
  if wait > 0 then say(("the server allows one full scan about every 15 minutes; try again in %d:%02d."):format(math.floor(wait / 60), wait % 60)); return end
  local kind = apiKind()
  if kind == "modern" then
    scan = { started = time(), mode = "replicate", side = houseSide, at = GetServerTime() }
    C_AuctionHouse.ReplicateItems()
  elseif kind == "classic" then
    local canQuery, canAll = CanSendAuctionQuery()
    if not canAll then say("the server doesn't allow a full scan right now; try again later."); return end
    scan = { started = time(), mode = "getall", side = houseSide, at = GetServerTime() }
    QueryAuctionItems("", nil, nil, 0, nil, nil, true, false, nil)
  else
    say("this client has no auction house API I know. Type /eah status and send that to EverlookDB.")
    return
  end
  h.tried = time()
  setStatus(auto and "Gathering auction prices (about 30 seconds)..." or "Asked the server for every auction...")
  refreshPanel()
  local mine = scan
  C_Timer.After(SCAN_TIMEOUT, function()
    if scan == mine and not mine.reading then
      scan = nil
      setStatus("No answer from the server. Try again later.")
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

local function priceLines(tooltip, id)
  if not db then return end
  local stack = IsShiftKeyDown() and tipOn("stack") and stackSize(id) or 1
  local function each(p) return stack > 1 and (p * stack) or p end
  local suffix = stack > 1 and (" x" .. stack) or ""
  local keys = { factionKey() }
  local neutral = (GetRealmName() or "?") .. "-Neutral"
  if db.houses[neutral] then keys[#keys + 1] = neutral end
  for _, key in ipairs(keys) do
    local h = db.houses[key]
    local it = h and h.items[id]
    local label = key:match("%-(%a+)$") == "Neutral" and "Neutral AH" or "AH"
    if tipOn("auction") then
      if it and it[1] then
        local fresh = (time() - it[4]) < STALE
        local r, g, b = fresh and 1 or 0.6, fresh and 0.82 or 0.6, fresh and 0 or 0.6
        tooltip:AddDoubleLine(label .. suffix .. " (" .. (it[2] or "?") .. " up, " .. ago(it[4]) .. ")", money(each(it[1])),
          r, g, b, 1, 1, 1)
      elseif h and h.scanned and h.days[id] then
        tooltip:AddDoubleLine(label, "none up in the last scan", 0.6, 0.6, 0.6, 0.6, 0.6, 0.6)
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
  setStatus("")
  refreshPanel()
  -- Automatic full scan when the last one is 15+ minutes old (db.auto, on by default; /eah auto off).
  -- A short wait first, so the auction house window finishes opening before the list comes in.
  if db.auto ~= false and not scan then
    local h = getHouse(house)
    if not h.tried or time() - h.tried >= SCAN_COOLDOWN then
      setStatus("Gathering auction prices (about 30 seconds)...")
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
  hookTooltips()
end

function events.AUCTION_HOUSE_SHOW() onShow() end

function events.AUCTION_HOUSE_CLOSED()
  if scan then
    if scan.reading then scan.aborted = true else scan = nil end
  end
  house = nil
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

function events.AUCTION_HOUSE_BROWSE_RESULTS_UPDATED() captureBrowse() end
function events.AUCTION_HOUSE_BROWSE_RESULTS_ADDED() captureBrowse() end

local frame = CreateFrame("Frame")
for e in pairs(events) do pcall(frame.RegisterEvent, frame, e) end  -- some events exist only on one API
frame:SetScript("OnEvent", function(_, e, ...) events[e](...) end)

SLASH_EVERLOOKAUCTIONS1 = "/eah"
SlashCmdList.EVERLOOKAUCTIONS = function(msg)
  msg = (msg or ""):lower():match("^%s*(.-)%s*$")
  if ns.slash and ns.slash(msg) then return end
  if msg == "scan" then startScan(); return end
  if msg == "test" then
    db.reloadAfterScan = not db.reloadAfterScan
    say(db.reloadAfterScan and "test mode on: the UI reloads after the next full scan, so it is saved at once."
      or "test mode off.")
    return
  end
  if msg == "auto off" or msg == "auto on" then
    db.auto = msg == "auto on"
    say(db.auto and "automatic full scans are on (when you open the auction house, then every 15 minutes while it is open)."
      or "automatic full scans are off. Press Full scan or type /eah scan when you want one.")
    return
  end
  say("status")
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
  if not any then print("  no prices yet: open the auction house and press Full scan, or just search.") end
  print("  /eah scan  start a full scan (auction house open)")
  if ns.help then ns.help() end
  print(("  /eah test  reload after every full scan so it is saved at once (now %s)"):format(db.reloadAfterScan and "on" or "off"))
  print(("  /eah auto on|off  automatic full scan when you open the auction house (now %s)"):format(db.auto == false and "off" or "on"))
end

-- Shared with Sell.lua, Search.lua and Skin.lua
ns.db = function() return db end
ns.house = function() return house end
ns.money, ns.num, ns.ago, ns.say, ns.variantOf, ns.ahFrame, ns.ok = money, num, ago, say, variantOf, ahFrame, ok

-- The newest full scan's row for "id:suffix" on the open auction house: { low, p10, med, qty, n, at }.
function ns.latestRow(key)
  if not db or not house then return nil end
  local side = house:match("%-(%a+)$")
  local realm = GetRealmName()
  for k = #db.scans, 1, -1 do
    local sc = db.scans[k]
    if sc.realm == realm and sc.side == side then
      local row = sc.rows and sc.rows[key]
      if not row then return nil end
      local f = { strsplit(",", row) }
      return { low = tonumber(f[1]), p10 = tonumber(f[2]), med = tonumber(f[3]), qty = tonumber(f[4]), n = tonumber(f[5]), at = sc.at }
    end
  end
end

-- Lowest price per day for an item on the open auction house (last 30 days), oldest first: { { day, price }, ... }.
function ns.history(id)
  local out = {}
  local h = db and house and db.houses[house]
  local d = h and h.days[id]
  if d then for day, p in pairs(d) do out[#out + 1] = { day, p } end end
  table.sort(out, function(a, b) return a[1] < b[1] end)
  return out
end

-- The open auction house's saved price for an item: { lowest unit buyout, quantity, auctions, time } or nil.
function ns.houseItem(id)
  local h = db and house and db.houses[house]
  return h and h.items[id]
end
ns.today = today
