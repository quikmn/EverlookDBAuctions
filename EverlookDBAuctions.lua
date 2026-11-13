-- EverlookDB Auctions: auction house prices for WoW Forever.
--   Full scan   one button on the auction house reads every auction at once (allowed about every 15 minutes)
--   Searches    prices from the normal Blizzard search results are kept too, no scan needed
--   Tooltips    lowest buyout per item, how many are up, how old the price is, and the 30-day low
-- Prices are kept per realm and auction house (Alliance, Horde, or the neutral houses in Booty Bay, Gadgetzan and
-- Everlook). Sellers, bidders and other players are never read into the saved data.
-- /eah for status, /eah scan to start a full scan while the auction house is open.

local ADDON = ...
local VERSION = 1
local SCAN_COOLDOWN = 15 * 60   -- the server allows one full scan about every 15 minutes
local SCAN_TIMEOUT = 90         -- no answer by then: the server refused (throttled) or the AH closed
local BATCH = 1000              -- auctions read per frame, so a big scan doesn't freeze the game
local HISTORY_DAYS = 30
local STALE = 24 * 3600         -- older prices are shown grey
-- Zones whose auction house is the neutral one (Classic UiMapIDs): Stranglethorn Vale, Tanaris, Winterspring
local NEUTRAL_ZONES = { [1434] = true, [1446] = true, [1452] = true }

local db
local house          -- the house key while an auction house is open, e.g. "Everlook-Alliance"
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
  return (GetRealmName() or "?") .. "-" .. side
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

local function refreshPanel()
  if not panel or not house then return end
  local h = getHouse(house)
  local n = 0
  for _ in pairs(h.items) do n = n + 1 end
  local side = house:match("%-(%a+)$") or "?"
  panel.info:SetText(("%s auction house\n%d items priced%s"):format(side, n,
    h.scanned and ("\nlast full scan " .. ago(h.scanned)) or "\nno full scan yet"))
  local wait = h.tried and (h.tried + SCAN_COOLDOWN - time()) or 0
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

local function makePanel(parent)
  local f = CreateFrame("Frame", "EverlookAuctionsPanel", parent, "BackdropTemplate")
  f:SetSize(190, 128)
  f:SetPoint("TOPLEFT", parent, "TOPRIGHT", 4, -24)
  f:SetFrameStrata(parent:GetFrameStrata())
  f:SetBackdrop({
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 },
  })
  f:SetBackdropColor(0.06, 0.06, 0.08, 0.92)
  f:SetBackdropBorderColor(0.6, 0.5, 0.2, 1)

  local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  title:SetPoint("TOPLEFT", 10, -10)
  title:SetText("EverlookDB Auctions")

  f.info = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  f.info:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
  f.info:SetWidth(170)
  f.info:SetJustifyH("LEFT")

  f.button = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  f.button:SetSize(170, 22)
  f.button:SetPoint("BOTTOMLEFT", 10, 26)
  f.button:SetScript("OnClick", function() startScan() end)

  f.status = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  f.status:SetPoint("BOTTOMLEFT", 10, 10)
  f.status:SetWidth(170)
  f.status:SetJustifyH("LEFT")

  -- the cooldown countdown on the button
  local acc = 0
  f:SetScript("OnUpdate", function(_, dt)
    acc = acc + dt
    if acc >= 1 then acc = 0; refreshPanel() end
  end)
  return f
end

local function ahFrame()
  return _G.AuctionHouseFrame or _G.AuctionFrame
end

---------------------------------------------------------------------------------------------------------------------
-- Full scan

-- Reads auction i the same way for both APIs. Returns count, buyout, itemID; seller and bidder are skipped, never kept.
local function readModern(i)
  local okCall, _, _, count, _, _, _, _, _, _, buyout, _, _, _, _, _, _, itemID = pcall(C_AuctionHouse.GetReplicateItemInfo, i)
  if not okCall then return nil end
  return ok(count), ok(buyout), ok(itemID)
end

local function readClassic(i)
  local okCall, _, _, count, _, _, _, _, _, _, buyout, _, _, _, _, _, _, itemID = pcall(GetAuctionItemInfo, "list", i)
  if not okCall then return nil end
  return ok(count), ok(buyout), ok(itemID)
end

local function finishScan(h, agg, total, priced)
  local now, day = time(), today()
  h.items = {}
  for id, a in pairs(agg) do
    h.items[id] = { a.unit, a.qty, a.n, now }
    if a.unit then noteDay(h, id, a.unit, day) end
  end
  h.scanned = now
  pruneDays(h)
  scan = nil
  local n = 0
  for _ in pairs(agg) do n = n + 1 end
  setStatus(("Done: %d auctions, %d items."):format(total, n))
  say(("full scan done: %d auctions of %d different items (%d with a buyout)."):format(total, n, priced))
  refreshPanel()
end

-- Reads the whole list a slice per frame.
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
  local agg, i, last, priced = {}, first, first + total - 1, 0
  local function step()
    if not scan then return end
    if scan.aborted then
      -- the auction house closed while reading: keep the old prices rather than half a scan
      scan = nil
      say("the full scan stopped because the auction house closed; prices were left as they were.")
      return
    end
    local stop = math.min(i + BATCH - 1, last)
    for k = i, stop do
      local count, buyout, id = read(k)
      if id and count and count > 0 then
        local a = agg[id]
        if not a then a = { qty = 0, n = 0 }; agg[id] = a end
        a.qty = a.qty + count
        a.n = a.n + 1
        if buyout and buyout > 0 then
          local unit = math.floor(buyout / count)
          if not a.unit or unit < a.unit then a.unit = unit end
          priced = priced + 1
        end
      end
    end
    i = stop + 1
    setStatus(("Reading %d / %d..."):format(math.min(i - first, total), total))
    if i > last then finishScan(h, agg, total, priced) else C_Timer.After(0, step) end
  end
  step()
end

function startScan()
  if scan then return end
  if not house or not ahFrame() or not ahFrame():IsShown() then say("open the auction house first."); return end
  local h = getHouse(house)
  local wait = h.tried and (h.tried + SCAN_COOLDOWN - time()) or 0
  if wait > 0 then say(("the server allows one full scan about every 15 minutes; try again in %d:%02d."):format(math.floor(wait / 60), wait % 60)); return end
  local kind = apiKind()
  if kind == "modern" then
    scan = { started = time(), mode = "replicate" }
    C_AuctionHouse.ReplicateItems()
  elseif kind == "classic" then
    local canQuery, canAll = CanSendAuctionQuery()
    if not canAll then say("the server doesn't allow a full scan right now; try again later."); return end
    scan = { started = time(), mode = "getall" }
    QueryAuctionItems("", nil, nil, 0, nil, nil, true, false, nil)
  else
    say("this client has no auction house API I know. Type /eah status and send that to EverlookDB.")
    return
  end
  h.tried = time()
  setStatus("Asked the server for every auction...")
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

local function priceLines(tooltip, id)
  if not db then return end
  local keys = { factionKey() }
  local neutral = (GetRealmName() or "?") .. "-Neutral"
  if db.houses[neutral] then keys[#keys + 1] = neutral end
  for _, key in ipairs(keys) do
    local h = db.houses[key]
    local it = h and h.items[id]
    local label = key:match("%-(%a+)$") == "Neutral" and "Neutral AH" or "AH"
    if it and it[1] then
      local fresh = (time() - it[4]) < STALE
      local r, g, b = fresh and 1 or 0.6, fresh and 0.82 or 0.6, fresh and 0 or 0.6
      tooltip:AddDoubleLine(label .. " (" .. (it[2] or "?") .. " up, " .. ago(it[4]) .. ")", money(it[1]),
        r, g, b, 1, 1, 1)
    elseif h and h.scanned and h.days[id] then
      tooltip:AddDoubleLine(label, "none up in the last scan", 0.6, 0.6, 0.6, 0.6, 0.6, 0.6)
    end
    local d = h and h.days[id]
    if d then
      local low
      for _, p in pairs(d) do if not low or p < low then low = p end end
      if low and (not it or low < (it[1] or math.huge)) then
        tooltip:AddDoubleLine("  " .. HISTORY_DAYS .. "-day low", money(low), 0.6, 0.6, 0.6, 0.8, 0.8, 0.8)
      end
    end
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
  house = currentHouseKey()
  local parent = ahFrame()
  -- Blizzard loads the auction house UI on this same event; if it isn't there yet, look again next frame
  if not parent and not retried then C_Timer.After(0, function() if house then onShow(true) end end); return end
  if parent and not panel then panel = makePanel(parent) end
  setStatus("")
  refreshPanel()
end

local events = {}

function events.ADDON_LOADED(name)
  if name ~= ADDON then return end
  EverlookAuctionsDB = EverlookAuctionsDB or {}
  db = EverlookAuctionsDB
  db.version = VERSION
  db.houses = db.houses or {}
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
  if msg == "scan" then startScan(); return end
  say("status")
  local kind = apiKind()
  print(("  auction API: %s; frame: %s"):format(kind or "none found",
    _G.AuctionHouseFrame and "AuctionHouseFrame (modern)" or _G.AuctionFrame and "AuctionFrame (classic)" or "not loaded yet"))
  local any = false
  for key, h in pairs(db.houses) do
    local n = 0
    for _ in pairs(h.items) do n = n + 1 end
    print(("  %s: %d items priced, %s"):format(key, n, h.scanned and ("last full scan " .. ago(h.scanned)) or "no full scan yet"))
    any = true
  end
  if not any then print("  no prices yet: open the auction house and press Full scan, or just search.") end
  print("  /eah scan  start a full scan (auction house open)")
end
