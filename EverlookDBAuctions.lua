-- EverlookDB Auctions: auction house prices for WoW Forever.
--   Full scan   Update prices on the bar along the auction house's bottom reads every auction at once (about
--               30 seconds, allowed about every 15 minutes, and automatic by default)
--   Searches    prices from the normal Blizzard search results are kept too, no scan needed
--   Tooltips    lowest buyout per item, how many are up, how old the price is, and the 30-day low
-- Prices are kept per realm and auction house (Alliance, Horde, or the neutral houses in Booty Bay, Gadgetzan and
-- Everlook). Each full scan is also kept as a summary for EverlookDB.com: region, realm, which auction house, the
-- server time, and per item version (item + random suffix) the lowest, 10th-percentile and median price per unit,
-- quantity, auctions, bid-only auctions, auctions with bids, time left and lowest bid. Sellers, bidders and other
-- players are never kept. The scans of the last 7 days are kept (up to 60, about 6 MB), so few are lost while the
-- uploader or the site is down; all but the newest per house are packed into one compressed string each. Scans dropped
-- to stay under that size are counted, and /eah status says so.
-- The game writes saved variables only at /reload, logout or a character switch: the bar notes when scans wait for one.
-- /eah for status, /eah scan to start a full scan while the auction house is open.

local ADDON, ns = ...
local VERSION = 2
local SCAN_COOLDOWN = 15 * 60   -- the server allows one full scan about every 15 minutes
-- Automatic updates leave every other window free: other addons (Cheap Upgrades, Auctionator...) need the same full
-- scan, and the server allows one per 15 minutes for everyone, so ours runs every 30 and theirs fit in between.
local AUTO_EVERY = 30 * 60
local AUTO_DELAY = 8            -- seconds the auction house is open before an automatic update starts
local SCAN_TIMEOUT = 90         -- no answer by then: the server refused (throttled) or the AH closed
local BATCH = 1000              -- auctions read per frame, so a big scan doesn't freeze the game
local LOADS_PER_STEP = 15       -- item-detail requests per frame: a flood of them delays the player's own buys and posts
local YIELD_FOR = 4             -- seconds a running scan pauses after the player buys, bids, posts or cancels
local HISTORY_DAYS = 30
-- Full scans kept for upload to EverlookDB.com (it dedupes on house and time, so sending one twice is harmless): every
-- scan of the last KEEP_DAYS, up to MAX_SCANS and about MAX_SCAN_BYTES of saved text. Only the newest scan per house
-- keeps its rows as a table (Search, Below vendor and tooltips read it); older ones are packed into one string.
local KEEP_DAYS = 7
local MAX_SCANS = 60
-- (6 MB: about 10 packed scans beside the newest per house; the whole saved file stays under about 8 MB, which the
-- game reads at every login and writes at every reload)
local MAX_SCAN_BYTES = 6 * 1024 * 1024
local ROW_BYTES = 76            -- what one row of a scan still kept as a table takes in the saved file (measured)
local UNSAVED_AFTER = 30 * 60   -- scans not yet on disk this long: the bar quietly says they are saved at logout
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
  -- searches, a click on a column to sort (Blizzard asks the server again for every sort), More results: the scan
  -- stops reading and loading item details for a few seconds, so the answer you wait for isn't stuck behind it
  for _, name in ipairs({ "SendBrowseQuery", "SendSearchQuery", "SendSellSearchQuery", "SearchForFavorites",
      "SearchForItemKeys", "RefreshItemSearchResults", "RefreshCommoditySearchResults", "RequestMoreBrowseResults",
      "RequestMoreItemSearchResults", "RequestMoreCommoditySearchResults" }) do
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

---------------------------------------------------------------------------------------------------------------------
-- The realm. Since the WoW Forever client update of 2026-11-21 (1.60.1, build 71037) GetRealmName() and
-- GetNormalizedRealmName() return "" (every scan of that build: no realm name; EverlookDB Crafting saves realm "" for
-- every character too), and GetRealmID() can return 0 (report K46304), while the character's GUID
-- ("Player-6946-07376D91") still carries the realm ID. EverlookDB.com refused such scans ("This scan has a bad realm").
-- So the realm is read from every source there is and kept for the session once known:
--   id    GetRealmID(), else the realm in the character's GUID
--   name  GetRealmName(), else for that ID: the name remembered per account (db.realms[id] = { name, norm }), a saved
--         scan of ours that has both, or the Price Feed (the EverlookDB App's copy of the site's houses)
--   norm  GetNormalizedRealmName(), else the name without spaces
-- (UnitFullName("player")'s realm is not used: on this build it is part of the character's name, not the realm.)
local realmNow = {}   -- { name, id, norm } as far as known this session
local realmUnfixed = 0  -- saved scans that name no realm at all (/eah status); counted at login and per scan

local function textOnly(v) v = ok(v); return type(v) == "string" and v ~= "" and v or nil end
local function idOnly(v) v = ok(v); return type(v) == "number" and v > 0 and v or nil end
local function squash(s) return s and (s:gsub("[%s%-']", ""):lower()) or nil end

-- A realm name for this realm ID from what is saved: db.realms, our own scans, the Price Feed.
local function knownName(id)
  local known = db and type(db.realms) == "table" and db.realms or nil
  if known and type(known[id]) == "table" and textOnly(known[id].name) then return known[id].name end
  for i = #(db and db.scans or {}), 1, -1 do
    local sc = db.scans[i]
    if type(sc) == "table" and sc.realmID == id and textOnly(sc.realm) and sc.realm ~= "?" then return sc.realm end
  end
  local feed = rawget(_G, "EverlookDBAuctionsShared")
  if type(feed) == "table" and type(feed.houses) == "table" then
    for _, h in pairs(feed.houses) do
      if type(h) == "table" and h.realmID == id and textOnly(h.realm) then return h.realm end
    end
  end
  return nil
end

local function readRealm()
  if realmNow.name and realmNow.id then return realmNow.name, realmNow.id, realmNow.norm end
  local name = textOnly(GetRealmName and GetRealmName())
  local id = idOnly(GetRealmID and GetRealmID())
  if not id and UnitGUID then
    local guid = textOnly(UnitGUID("player"))
    id = guid and idOnly(tonumber(guid:match("^Player%-(%d+)%-")))
  end
  local norm = textOnly(GetNormalizedRealmName and GetNormalizedRealmName())
  -- known earlier this session
  name, id, norm = name or realmNow.name, id or realmNow.id, norm or realmNow.norm
  if id and not name then name = knownName(id) end
  if not id and name and db and type(db.realms) == "table" then
    for kid, r in pairs(db.realms) do
      if type(r) == "table" and r.name == name then id = kid; break end
    end
  end
  if not norm and name then norm = (name:gsub("[%s%-]", "")) end
  realmNow.name, realmNow.id, realmNow.norm = name, id, norm
  if db and name and id then
    db.realms = type(db.realms) == "table" and db.realms or {}
    db.realms[id] = { name = name, norm = norm }
  end
  return name, id, norm
end

-- The realm's name, or nil while nothing says it.
local function realmName() return (readRealm()) end
-- The realm part of a house key: the name, or "?" while it isn't known (put right at the next login, below).
local function realmKey() return realmName() or "?" end

local function say(msg) print("|cffffd100EverlookDB Auctions|r: " .. msg) end -- the prefix every EverlookDB addon uses

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
--   db.scans = { oldest first: { region, realm, side, at (server time), ..., and either rows = { ["id:suffix"] = row }
--     (the newest per house, with deals) or, packed, z = base64 zlib text (zm = "zlib-b64") or packed = text, and nrows } }

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
  return realmKey() .. "-" .. (UnitFactionGroup("player") or "?")
end

local function currentHouseKey()
  local side = UnitFactionGroup("player") or "?"
  if NEUTRAL_ZONES[zoneMapID() or 0] then side = "Neutral" end
  return realmKey() .. "-" .. side, side
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


-- An update was started but never finished (UI reloaded, auction house closed, or no answer from the server).
-- The last 20 price updates on this house and how each ended, for /eah status: { at, how, secs }.
local function logScan(h, how)
  h.log = h.log or {}
  table.insert(h.log, 1, { at = time(), how = how, secs = h.tried and (time() - h.tried) or nil })
  while #h.log > 20 do table.remove(h.log) end
end
ns.logScan = logScan

-- How many items have a saved price on a house: counted once, then kept up as prices come in (the bar shows it every
-- second while the auction house is open). Keyed by the items table, so a new one (a full scan) is counted afresh.
local itemCounts = setmetatable({}, { __mode = "k" })
function ns.countItems(h)
  local n = itemCounts[h.items]
  if not n then
    n = 0
    for _ in pairs(h.items) do n = n + 1 end
    itemCounts[h.items] = n
  end
  return n
end

-- Saves an item's price on a house, keeping its count.
local function setItem(h, id, v)
  local n = itemCounts[h.items]
  if n and h.items[id] == nil then itemCounts[h.items] = n + 1 end
  h.items[id] = v
end

local function unfinished(h)
  return not scan and h.tried ~= nil and (not h.scanned or h.scanned < h.tried)
end

-- Seconds until Update prices may be used again.
local function scanWait(h)
  if not h.tried then return 0 end
  -- the server counts every request against its 15 minutes, answered or not: asking again sooner only gets ignored
  -- (that is how one cut-off update turned into "no answer" after "no answer")
  return h.tried + SCAN_COOLDOWN - time()
end

-- How long an update should take: as long as the last one on this house, else about 30 seconds.
local function expected(h)
  return math.min(math.max(h.took or 30, 10), 120)
end

-- What the bar says about an update that didn't finish: why, when that is known (h.why is set where it stopped; none
-- means a reload cut it off), and that the prices are as they were.
function ns.unfinishedText(h)
  local why = h.why == "noanswer" and "got no answer from the server"
    or h.why == "empty" and "got an empty list from the server"
    or h.why == "closed" and "stopped when the AH closed"
    or h.why == "stalled" and "stopped partway"
    or "was cut off by a reload"
  return ("The last price update %s. Prices are unchanged."):format(why)
end

-- The bar's line in the body size, one size down when it would be cut off (the line beside the money is about 440 px;
-- "The last price update got no answer from the server. Prices are unchanged." is about that long).
local function fitBarText()
  local fs = panel.text
  fs:SetFontObject(ns.UI.fontObject("body"))
  local w = fs:GetWidth() or 0
  local need = fs.GetUnboundedStringWidth and fs:GetUnboundedStringWidth() or fs:GetStringWidth() or 0
  if w > 0 and need > w then fs:SetFontObject(ns.UI.fontObject("small")) end
end

-- The Price Feed's line under the bar's own (SharedPrices.lua): "Price Feed: Alliance · other players' scan, 12 min
-- old", or why there is none.
local function refreshFeedLine()
  if not panel.feed then return end
  local okF, line = pcall(function()
    return ns.shared and ns.shared.feedLine(house, house:match("%-(%a+)$")) or nil
  end)
  local fs = panel.feed
  fs:SetText(okF and line or "")
  -- one size down when it would be cut off ("Price Feed: off · the EverlookDB App brings..." is about the width)
  fs:SetFontObject(ns.UI.fontObject("mute"))
  local w = fs:GetWidth() or 0
  local need = fs.GetUnboundedStringWidth and fs:GetUnboundedStringWidth() or fs:GetStringWidth() or 0
  if w > 0 and need > w then fs:SetFontObject(ns.UI.fontObject("head")) end
end

local function refreshPanel()
  if not panel or not house then return end
  local T = ns.T
  local h = getHouse(house)
  refreshFeedLine()
  if scan then
    local took = time() - scan.started
    local pct = scan.total and scan.total > 0 and math.min(0.99, (scan.done or 0) / scan.total) or 0
    local text
    if not scan.reading then
      -- nothing has come back yet: say so, with the time waited, not a made-up percentage
      -- (short enough for the bar beside the money: the rest is in the tooltip)
      text = ("Asking the server for every auction… %d:%02d · usually within a minute")
        :format(math.floor(took / 60), took % 60)
    elseif yielding() then
      text = "Updating prices… paused while you buy, post or cancel"
    elseif (scan.done or 0) >= (scan.total or 0) then
      -- every auction read; the ones whose item wasn't loaded yet are read again for a few seconds
      text = ("Updating prices… read all %s auctions, loading item details"):format(num(scan.total or 0))
    else
      text = ("Updating prices… read %s of %s auctions · keep browsing"):format(num(scan.done or 0), num(scan.total or 0))
    end
    panel.text:SetText(text)
    fitBarText()
    panel.text:SetTextColor(unpack(T.text))
    panel.button:Hide()
    local bar = panel.bar
    bar:Show()
    bar.fill:SetWidth(math.max(1, (bar:GetWidth() - 2) * pct))
    bar.label:SetText(scan.reading and ("%d%%"):format(pct * 100) or "waiting")
    bar.label:SetTextColor(unpack(pct >= 0.5 and T.onAccent or T.text))
    return
  end
  panel.bar:Hide()
  panel.button:Show()
  local bad = unfinished(h)
  -- (each branch below sets the text, then fitBarText; the colour after, as a font change resets it)
  if flash and GetTime() < flash.till then
    panel.text:SetText(flash.text)
    fitBarText()
    panel.text:SetTextColor(unpack(flash.color or T.text))
  elseif bad then
    -- not alarm red: nothing is lost, the prices are as they were; red is kept for real problems. Says why when that
    -- is known (h.why, set where the update stopped); none known means a reload cut it off.
    panel.text:SetText(ns.unfinishedText(h))
    fitBarText()
    panel.text:SetTextColor(unpack(T.places.prices))
  else
    flash = nil
    local n = ns.countItems(h)
    local side = ("%s%s|r"):format(ns.UI.hex(T.places.prices), house:match("%-(%a+)$") or "?")
    local updated = h.scanned and ("updated " .. ago(h.scanned)) or "no update yet"
    local waiting = ns.unsavedText()
    if waiting then
      -- scans the game hasn't written to disk yet: a quiet note in place of the item count, so the line still fits
      panel.text:SetText(("%s · %s · %s%s|r"):format(side, updated, ns.UI.hex(T.mute), waiting))
    else
      panel.text:SetText(("%s · %s items priced · %s"):format(side, num(n), updated))
    end
    fitBarText()
    panel.text:SetTextColor(unpack(T.text))
  end
  local wait = scanWait(h)
  if wait > 0 then
    panel.button:Disable()
    -- the manual button's wait (15 minutes); the automatic one comes later (30), so this is when you may start one
    local lead = bad and "Try again in" or "Allowed in"
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
    -- Blizzard's Auctions view ends at the money display and hangs its Cancel Auction button 22 px below that, in the
    -- bottom strip where our bar now sits; lift the views that end at the money display above the bar instead
    -- (by the button's 22 px plus a gap; Blizzard's Sell view keeps its place: its Post button sits inside it)
    for _, key in ipairs({ "AuctionsFrame" }) do
      local v = ah[key]
      if v then
        local pts = {}
        for i = 1, v:GetNumPoints() do pts[i] = { v:GetPoint(i) } end
        v:ClearAllPoints()
        for _, p in ipairs(pts) do
          if p[1] == "BOTTOM" and (p[2] == ah.MoneyFrameBorder or p[2] == ah) then p[5] = (p[5] or 0) + 24 end
          v:SetPoint(unpack(p))
        end
      end
    end
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
  return ("Prices update by themselves when you open the auction house and every 30 minutes while it is open, which leaves other addons room for their own scans in between. An update reads every auction in about %d seconds, and you can keep buying and selling meanwhile."):format(secs)
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
    local EUI = rawget(UI, "EUI")
    local band
    if EUI then
      -- rounded bottom corners, inside the window's own
      band = EUI.Util.Round(parent, 7, "BACKGROUND", -6, { bl = true, br = true })
    else
      band = parent:CreateTexture(nil, "BACKGROUND", nil, -6)
    end
    band:SetPoint("BOTTOMLEFT", 1, 1)
    band:SetPoint("BOTTOMRIGHT", -1, 1)
    band:SetHeight(BAR_H + 2)
    UI.shade(band, T.raised, UI.LIFT)
    local line = UI.line(parent, true, T.places.prices, "BORDER")
    line:SetPoint("BOTTOMLEFT", band.box or band, "TOPLEFT")
    line:SetPoint("BOTTOMRIGHT", band.box or band, "TOPRIGHT")
    f:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", 182, 2)
    f:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -6, 2)
  else
    -- the old auction house window: the bar hangs under it
    f:SetPoint("TOPLEFT", parent, "BOTTOMLEFT", 14, -4)
    f:SetPoint("TOPRIGHT", parent, "BOTTOMRIGHT", -40, -4)
    UI.panel(f, T.bg, T.edge)
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

  -- the way to the main window (Hub.lua), on the page of the tab you are on where it has one
  f.open = UI.button(f, "Open in EverlookDB Auctions", 176, 18, "quiet")
  f.open:SetPoint("RIGHT", f.button, "LEFT", -6, 0)
  f.open:SetScript("OnClick", function() if ns.hub then ns.hub.open(ns.hub.ahPage()) end end)
  UI.tip(f.open, "Open in EverlookDB Auctions", "The main window: Home, the AH log, Advanced search, Crafting profit, Gear upgrades, Merchant's Favor and the settings. /eah, the minimap button or a key (Key Bindings, AddOns) opens it anywhere.")

  local bar = CreateFrame("Frame", nil, f)
  bar:SetAllPoints(f.button)
  UI.panel(bar, T.input, T.edge)
  bar.edbRadius = 4
  local EUIb = rawget(UI, "EUI")
  if EUIb then
    bar.fill = EUIb.Util.Round(bar, 3, "ARTWORK")   -- rounded, inside the bar's rounded edge
    bar.fill:SetVertexColor(unpack(T.places.prices))
  else
    bar.fill = bar:CreateTexture(nil, "ARTWORK")
    bar.fill:SetColorTexture(unpack(T.places.prices))
  end
  bar.fill:SetPoint("TOPLEFT", 1, -1)
  bar.fill:SetPoint("BOTTOMLEFT", 1, 1)
  bar.fill:SetWidth(1)
  bar.label = UI.text(bar, "small", "OVERLAY")
  bar.label:SetPoint("CENTER")
  bar.label:SetShadowOffset(0, 0)
  bar:EnableMouse(true)
  UI.tip(bar, "Updating prices", tipText)
  bar:Hide()
  f.bar = bar

  -- two lines: the house's prices, and under it the Price Feed's (quieter, smaller)
  f.text = UI.text(f, "body")
  f.text:SetPoint("LEFT", mark, "RIGHT", 8, 6)
  f.text:SetPoint("RIGHT", f.open, "LEFT", -12, 6)
  f.text:SetJustifyH("LEFT")
  f.text:SetWordWrap(false)
  f.feed = UI.text(f, "mute")
  f.feed:SetPoint("LEFT", mark, "RIGHT", 8, -7)
  f.feed:SetPoint("RIGHT", f.open, "LEFT", -12, -7)
  f.feed:SetJustifyH("LEFT")
  f.feed:SetWordWrap(false)
  UI.tip(f, "Auction prices", tipText)

  -- the countdown on the button and the progress bar, and a fresh update every 30 minutes while the auction house
  -- is open (this only runs while the bar, and so the auction house, is shown)
  local acc = 0
  f:SetScript("OnUpdate", function(_, dt)
    acc = acc + dt
    if acc < (scan and 0.2 or 1) then return end
    acc = 0
    if ns.dropStalled then ns.dropStalled() end
    refreshPanel()
    if db.auto ~= false and not scan and house then
      local h = getHouse(house)
      if h.tried and time() - h.tried >= AUTO_EVERY then startScan(true) end
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
-- Only plain numbers and strings count: anything else (a hidden value, a broken row) is unknown.
local function numOnly(v) v = ok(v); return type(v) == "number" and v or nil end
local function strOnly(v) v = ok(v); return type(v) == "string" and v or nil end

local function readModern(i)
  local okCall, _, _, count, _, _, _, _, minBid, _, buyout, bid, _, _, _, _, _, itemID = pcall(C_AuctionHouse.GetReplicateItemInfo, i)
  if not okCall then return nil end
  local okLink, link = pcall(C_AuctionHouse.GetReplicateItemLink, i)
  local okLeft, left = pcall(C_AuctionHouse.GetReplicateItemTimeLeft, i)
  return numOnly(count), numOnly(buyout), numOnly(itemID), numOnly(minBid), numOnly(bid), okLink and strOnly(link) or nil, okLeft and numOnly(left) or nil
end

local function readClassic(i)
  local okCall, _, _, count, _, _, _, _, minBid, _, buyout, bid, _, _, _, _, _, itemID = pcall(GetAuctionItemInfo, "list", i)
  if not okCall then return nil end
  local okLink, link = pcall(GetAuctionItemLink, "list", i)
  local okLeft, left = pcall(GetAuctionItemTimeLeft, "list", i)
  left = okLeft and numOnly(left)
  return numOnly(count), numOnly(buyout), numOnly(itemID), numOnly(minBid), numOnly(bid), okLink and strOnly(link) or nil, left and (left - 1) or nil
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

-- Older scans, packed: one line per item version, "id:suffix=row" (the row exactly as saved), sorted by key. Stored
-- zlib-compressed in base64 (sc.z, sc.zm = "zlib-b64") when the game can compress and the round trip gives the same
-- text back, else as the plain text (sc.packed). The newest scan per house keeps its rows table.
local function packRows(rows)
  local keys = {}
  for key in pairs(rows) do keys[#keys + 1] = key end
  table.sort(keys)
  local lines = {}
  for i, key in ipairs(keys) do lines[i] = key .. "=" .. rows[key] end
  return table.concat(lines, "\n"), #keys
end

local function zip(packed)
  local E = C_EncodingUtil
  local method = Enum and Enum.CompressionMethod and Enum.CompressionMethod.Zlib
  if not (E and method and E.CompressString and E.DecompressString and E.EncodeBase64 and E.DecodeBase64) then return nil end
  local level = Enum.CompressionLevel and Enum.CompressionLevel.OptimizeForSize
  local fine, z = pcall(function()
    local raw
    if level then raw = E.CompressString(packed, method, level) else raw = E.CompressString(packed, method) end
    return E.EncodeBase64(raw)
  end)
  if not fine or type(z) ~= "string" or z == "" then return nil end
  local same, back = pcall(function() return E.DecompressString(E.DecodeBase64(z), method) end)
  if not same or back ~= packed then return nil end
  return z
end

local function compactScan(sc)
  if not sc.rows then return end
  local packed, n = packRows(sc.rows)
  local z = zip(packed)
  if z then sc.z, sc.zm = z, "zlib-b64" else sc.packed = packed end
  sc.nrows = n
  sc.rows, sc.deals, sc.linkSamples = nil, nil, nil
end
ns.compactScan = compactScan

-- A scan's house for trimming: realm ID and side (a scan saved without its realm name is still the same house; on
-- 2026-11-21 one such scan kept two unpacked "newest" scans of one house and pushed five older ones out for room).
local function houseOf(sc)
  local id = type(sc.realmID) == "number" and sc.realmID > 0 and sc.realmID
  return (id and ("#" .. id) or tostring(sc.realm)) .. "-" .. tostring(sc.side)
end

-- The newest scan of each house: { [scan] = true }.
local function newestPerHouse(scans)
  local keep, seen = {}, {}
  for i = #scans, 1, -1 do
    local key = houseOf(scans[i])
    if not seen[key] then seen[key], keep[scans[i]] = true, true end
  end
  return keep
end

local function scanBytes(sc)
  if sc.z then return #sc.z end
  if sc.packed then return #sc.packed end
  local n = sc.nrows
  if not n then n = 0; for _ in pairs(sc.rows or {}) do n = n + 1 end end
  return n * ROW_BYTES
end

-- Packs every scan but the newest per house, then drops scans older than KEEP_DAYS (server time); over MAX_SCANS or
-- MAX_SCAN_BYTES it drops a scan with a newer one of its house in the same server hour first (the site keeps one per
-- hour), oldest first, then the oldest. The newest scan per house is never dropped. Returns how many were dropped,
-- and how many of those went for room (younger than KEEP_DAYS: the uploader may not have sent them yet).
local function trimScans(scans, now)
  local keep = newestPerHouse(scans)
  for _, sc in ipairs(scans) do if not keep[sc] then compactScan(sc) end end
  local dropped = 0
  local cutoff = now - KEEP_DAYS * 86400
  for i = #scans, 1, -1 do
    local sc = scans[i]
    if not keep[sc] and (sc.at or 0) < cutoff then table.remove(scans, i); dropped = dropped + 1 end
  end
  local bytes, forRoom = 0, 0
  for _, sc in ipairs(scans) do bytes = bytes + scanBytes(sc) end
  while #scans > MAX_SCANS or bytes > MAX_SCAN_BYTES do
    local pick
    for i, sc in ipairs(scans) do
      if not keep[sc] then
        local hour, key = math.floor((sc.at or 0) / 3600), houseOf(sc)
        for j = i + 1, #scans do
          local o = scans[j]
          if houseOf(o) == key and (o.at or 0) > (sc.at or 0) and math.floor((o.at or 0) / 3600) == hour then
            pick = i
            break
          end
        end
        if pick then break end
      end
    end
    if not pick then
      for i, sc in ipairs(scans) do if not keep[sc] then pick = i; break end end
    end
    if not pick then break end
    bytes = bytes - scanBytes(scans[pick])
    table.remove(scans, pick)
    dropped, forRoom = dropped + 1, forRoom + 1
  end
  return dropped, forRoom
end
ns.trimScans = trimScans

-- Scans finished this session are only in memory until the game writes saved variables (/reload, logout, character
-- switch): { { scan = scan, finished = server time } }, oldest first.
local unsavedScans = {}

-- How many scans wait for a /reload, and the server time the oldest of them finished (only scans still kept count).
local function unsavedInfo()
  local kept = {}
  for _, sc in ipairs(db and db.scans or {}) do kept[sc] = true end
  local n, oldest = 0, nil
  for _, u in ipairs(unsavedScans) do
    if kept[u.scan] then
      n = n + 1
      if not oldest or u.finished < oldest then oldest = u.finished end
    end
  end
  return n, oldest
end
ns.unsavedInfo = unsavedInfo

-- The bar's quiet note once the oldest unsaved scan is UNSAVED_AFTER old, else nil.
function ns.unsavedText(now)
  local n, oldest = unsavedInfo()
  if n == 0 or (now or GetServerTime()) - oldest <= UNSAVED_AFTER then return nil end
  -- a quiet note, not a call to reload mid-session: logging out saves them just as well
  return ("%d %s waiting to upload · saved at logout"):format(n, n == 1 and "scan" or "scans")
end
-- Scans dropped to keep the saved file small (db.dropped: server times, the last KEEP_DAYS), and the line /eah status
-- shows for them.
function ns.noteDropped(n, now)
  db.dropped = db.dropped or {}
  for _ = 1, n or 0 do db.dropped[#db.dropped + 1] = now end
  local cutoff = now - KEEP_DAYS * 86400
  for i = #db.dropped, 1, -1 do if db.dropped[i] < cutoff then table.remove(db.dropped, i) end end
  if #db.dropped == 0 then db.dropped = nil end
end
function ns.droppedText()
  local n = db.dropped and #db.dropped or 0
  if n == 0 then return nil end
  return ("%d older %s dropped in the last %d days to keep the saved file small; any the uploader hadn't sent are lost"
    .. " (run it more often to keep them)"):format(n, n == 1 and "scan was" or "scans were", KEEP_DAYS)
end
function ns.noteUnsaved(sc, finished) unsavedScans[#unsavedScans + 1] = { scan = sc, finished = finished } end

local function finishScan(h, vars, total, noLink, linkRounds, unlinked)
  local list = {}
  for key in pairs(vars) do list[#list + 1] = key end
  local rows, items = {}, {}
  local deals = {}   -- below vendor price: "unit:count,..." per item version (Vendor.lua), worked out once here
  local i = 1
  local badRows = (scan and scan.badRows) or 0
  local function addRow(key)
    local v = vars[key]
    local low, p10, med = summarize(v)
    -- low,p10,median,quantity,auctions,bid-only,with bids,short,medium,long,very long,lowest bid[,suffix name]
    local row = table.concat({ low or "", p10 or "", med or "", v.qty, v.n, v.bidOnly, v.withBids,
      v.tl[1], v.tl[2], v.tl[3], v.tl[4], v.minBid or "" }, ",")
    if v.suffix ~= 0 and v.name then row = row .. "," .. v.name end
    rows[key] = row
    if ns.vendor and ns.vendor.scanDeals then
      local okDeal, d = pcall(ns.vendor.scanDeals, v.id, v.units, v.counts)
      if okDeal and d then deals[key] = d end
    end
    local it = items[v.id]
    if not it then it = { nil, 0, 0 }; items[v.id] = it end
    if low and (not it[1] or low < it[1]) then it[1] = low end
    it[2] = it[2] + v.qty
    it[3] = it[3] + v.n
  end
  local mine = scan
  local function step()
    if not mine or scan ~= mine then return end   -- thrown away meanwhile
    mine.beat = GetTime()
    local stop = math.min(i + 499, #list)
    for k = i, stop do
      -- one odd item never costs the whole update: it is skipped and counted
      if not pcall(addRow, list[k]) then badRows = badRows + 1 end
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
    logScan(h, scan.aborted and "done (AH closed; item details skipped)" or "done")
    pruneDays(h)
    local build = select(2, GetBuildInfo())
    -- never an empty realm when any source names it; when none does, the scan is marked and put right at a login
    local realm, realmID, realmNorm = readRealm()
    local sc = {
      region = textOnly(GetCurrentRegionName and GetCurrentRegionName()),
      regionID = ok(GetCurrentRegion and GetCurrentRegion()),
      realm = realm,
      realmID = realmID,
      realmNormalized = realmNorm,
      needsRealm = (not realm or not realmID) or nil,
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
      badRows = badRows > 0 and badRows or nil, -- auctions or items skipped because they couldn't be read
    }
    table.insert(db.scans, sc)
    if not realm and not realmID then realmUnfixed = realmUnfixed + 1 end
    -- packs the house's previous scan, drops what is past keeping; drops for room are noted for /eah status
    local _, forRoom = trimScans(db.scans, GetServerTime())
    ns.noteDropped(forRoom, GetServerTime())
    ns.noteUnsaved(sc, GetServerTime())
    linkSamples = nil
    if ns.onScan then ns.onScan() end
    if db.reloadAfterScan then
      -- test mode (/eah test, one scan): reload so the game writes the scan to disk right away
      db.reloadAfterScan = nil
      say("test mode: reloading in 3 seconds so the scan is saved.")
      C_Timer.After(3, function() if not scan then ReloadUI() end end)
    end
    h.took = time() - scan.started
    -- automatic updates are quiet: the price bar says how they went; an update asked for answers in chat too
    local auto = scan.auto
    scan = nil
    setStatus(("Prices updated · %s auctions, %s items"):format(num(total), num(#list)), ns.T.good)
    if not auto then say(("full scan done: %s auctions, %s item versions."):format(num(total), num(#list))) end
    refreshPanel()
  end
  step()
end

-- Adds one auction to its item version.
local function addOne(vars, id, count, buyout, minBid, bid, link, left)
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

-- The same, but an auction that can't be read is skipped and counted (scan.badRows), never the end of the update.
local function addAuction(vars, ...)
  if not pcall(addOne, vars, ...) and scan then scan.badRows = (scan.badRows or 0) + 1 end
end

local RETRY_WAITS = { 2, 3, 5 }   -- seconds before each re-read of auctions whose item wasn't loaded yet

-- Reads the whole list a slice per frame. Auctions whose item isn't loaded yet have no link (so no random suffix):
-- their numbers are kept from the first read, the game is asked to load those items, and they are read again up to
-- three times for the link before counting as suffix 0 (their plain version).
-- Once the list has arrived the update always finishes: when the auction house closes, the retries are skipped and
-- the auctions still without a link count from the numbers kept, so nothing more is needed from the auction house.
local function processList(total, first, read)
  local mine = scan
  if total <= 0 then
    -- an empty answer (refused or not loaded): never let it wipe the saved prices
    scan = nil
    if house then getHouse(house).why = "empty"; logScan(getHouse(house), "empty list") end
    setStatus("The server sent an empty list. Prices were left as they were.", ns.T.bad)
    if not mine.auto then say("the server sent an empty auction list; prices were left as they were.") end
    refreshPanel()
    return
  end
  local h = getHouse(house)
  scan.total, scan.done = total, 0
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
  local function ask(id)
    if load and not requested[id] then requested[id] = true; queue[#queue + 1] = id end
  end

  local function gone() return scan ~= mine end        -- finished, or thrown away
  local function closed() return mine.aborted end      -- the auction house closed after the list arrived

  -- every auction without a link counts under its plain version (suffix 0), from the numbers kept at the first read
  local rounds = {}
  local function finish(missing)
    for _, r in ipairs(missing) do
      addAuction(vars, r[2], r[3], r[4], r[5], r[6], nil, r[7])
      unlinked[r[2]] = (unlinked[r[2]] or 0) + 1
    end
    finishScan(h, vars, total, #missing, rounds, unlinked)
  end

  -- The first read, first..first+total-1. An auction without a link is kept as { index, id, count, buyout, minBid,
  -- bid, time left }. Should the auction house close before every auction is read and the list go with it, the
  -- update is thrown away (half a scan would drop the prices of everything not read).
  local function firstPass(done)
    local i, missing, lost = 1, {}, 0
    local function step()
      if gone() then return end
      mine.beat = GetTime()
      if not closed() and yielding() then
        C_Timer.After(0.25, step)
        return
      end
      if load and not closed() then pump() end
      local stop = math.min(i + BATCH - 1, total)
      for j = i, stop do
        local k = first + j - 1
        local count, buyout, id, minBid, bid, link, left = read(k)
        if id and count and count > 0 then
          if link then
            addAuction(vars, id, count, buyout, minBid, bid, link, left)
          else
            missing[#missing + 1] = { k, id, count, buyout, minBid, bid, left }
            ask(id)
          end
        elseif closed() then
          lost = lost + 1
        end
      end
      if lost > math.max(10, total * 0.01) then
        scan = nil
        h.why = "closed"
        logScan(h, "AH closed while reading")
        if not mine.auto then say("the full scan stopped because the auction house closed; prices were left as they were.") end
        return
      end
      i = stop + 1
      scan.done = math.min(stop, total)
      if i > total then done(missing) else C_Timer.After(0, step) end
    end
    step()
  end

  -- A re-read of the auctions still without a link; the auction house closing ends it at once with the rest unread.
  local function retry(missing, done)
    local i, still = 1, {}
    local function step()
      if gone() then return end
      mine.beat = GetTime()
      if closed() then
        for j = i, #missing do still[#still + 1] = missing[j] end
        done(still)
        return
      end
      if yielding() then
        C_Timer.After(0.25, step)
        return
      end
      if load then pump() end
      local stop = math.min(i + BATCH - 1, #missing)
      for j = i, stop do
        local r = missing[j]
        local count, buyout, id, minBid, bid, link, left = read(r[1])
        if link and id == r[2] and count and count > 0 then
          addAuction(vars, id, count, buyout, minBid, bid, link, left)
        else
          still[#still + 1] = r
          ask(r[2])
        end
      end
      i = stop + 1
      if i > #missing then done(still) else C_Timer.After(0, step) end
    end
    step()
  end

  local round = 0
  local function after(missing)
    rounds[#rounds + 1] = #missing
    if #missing == 0 or round >= #RETRY_WAITS or closed() then finish(missing); return end
    round = round + 1
    local function drain()
      if gone() then return end
      mine.beat = GetTime()
      if closed() then finish(missing); return end
      if load and qi <= #queue then
        if not yielding() then pump() end
        C_Timer.After(0, drain)
        return
      end
      requested, queue, qi = {}, {}, 1   -- ask again next round: some loads fail or get dropped
      -- the wait ends early when the auction house closes (AUCTION_HOUSE_CLOSED calls scan.wake)
      local woke = false
      local function wake()
        if woke or gone() then return end
        woke, mine.wake = true, nil
        if closed() then finish(missing) else retry(missing, after) end
      end
      mine.wake = wake
      C_Timer.After(RETRY_WAITS[round], wake)
    end
    drain()
  end
  firstPass(after)
end

-- A running update that has made no progress for STALL_AFTER seconds (an error stopped it): let it go, so the next
-- update can start instead of waiting for a /reload. The prices stay as they were.
local STALL_AFTER = 120
local function dropStalled()
  if not scan or not scan.reading or GetTime() - (scan.beat or GetTime()) < STALL_AFTER then return false end
  scan = nil
  if house then
    local h = getHouse(house)
    h.why = "stalled"
    logScan(h, "stopped (no progress)")
  end
  return true
end
ns.dropStalled = dropStalled

function startScan(auto)
  dropStalled()
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
    scan = { started = time(), mode = "replicate", side = houseSide, at = GetServerTime(), auto = auto }
    C_AuctionHouse.ReplicateItems()
  elseif kind == "classic" then
    local _, canAll = CanSendAuctionQuery()
    if not canAll then
      -- the automatic update asks every second while the window is open: only a press of the button gets a reply
      if not auto then say("the server doesn't allow a price update right now; try again in a minute.") end
      return
    end
    scan = { started = time(), mode = "getall", side = houseSide, at = GetServerTime(), auto = auto }
    QueryAuctionItems("", nil, nil, 0, nil, nil, true, false, nil)
  else
    if not auto then say("this client has no auction house API I know. Type /eah status and send that to EverlookDB.") end
    return
  end
  h.tried, h.why = time(), nil
  setStatus(nil)
  refreshPanel()
  local mine = scan
  C_Timer.After(SCAN_TIMEOUT, function()
    if scan == mine and not mine.reading then
      scan = nil
      h.why = "noanswer"
      logScan(h, "no answer")
      setStatus("No answer from the server. Prices were left as they were.", ns.T.bad)
      if not mine.auto then say("the server didn't send the auction list (it may limit full scans). Try again later.") end
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
    setItem(h, id, { s[1], s[2], nil, now })
    noteDay(h, id, s[1], day)
  end
end

-- One item's live auctions, looked up by Quick sell or Buy: the newest lowest price, so the tooltip and the 30-day
-- low follow what was just seen instead of the last full scan. rows = { { unit = copper each, qty = n }, ... }, every
-- variant of the item (one random-suffix variant alone says nothing about the item's lowest price).
function ns.noteLivePrice(id, rows)
  if scan or not house or not id or type(rows) ~= "table" then return end
  local low, qty = nil, 0
  for _, r in ipairs(rows) do
    if r.unit and r.unit > 0 and (not low or r.unit < low) then low = r.unit end
    qty = qty + (r.qty or 0)
  end
  if not low then return end   -- nothing up with a buyout: keep the last known price
  local h = getHouse(house)
  setItem(h, id, { low, qty, nil, time() })
  noteDay(h, id, low, today())
end

---------------------------------------------------------------------------------------------------------------------
-- Tooltips

-- Which tooltip lines to show (db.tip, set in the options): auction price, 30-day low and median, vendor price,
-- and with Shift held, the price of a full stack.
local function tipOn(key)
  local t = db and db.tip
  if not t or t[key] == nil then return true end   -- all on by default (the vendor line hides itself where the game shows one)
  return t[key]
end
ns.tipOn = tipOn

local function stackSize(id)
  local okGet, n = pcall(C_Item.GetItemMaxStackSizeByID or function() return nil end, id)
  if okGet and n then return n end
  local info = { pcall(C_Item.GetItemInfo, id) }
  return info[1] and info[9] or 1
end

-- The shared tooltip layout (Libs/EverlookUI/EverlookTooltip.lua): labels left, prices right, one order for every
-- EverlookDB addon's lines.
local Tip = LibStub and LibStub("EverlookTooltip-1", true)

-- The parts of a note joined with " · ", skipping empty ones.
local function join(...)
  local out = {}
  for i = 1, select("#", ...) do
    local p = select(i, ...)
    if type(p) == "string" and p ~= "" then out[#out + 1] = p end
  end
  return table.concat(out, " \194\183 ")
end
local function listed(n) return (n and (Tip and Tip.Count(n) or num(n)) or "?") .. " listed" end

-- What the tooltip's auction line says for one auction house. stack = " x20" while Shift shows a full stack's price
-- (only on lines with a price). it = the saved price { low, quantity, auctions, time }
-- or nil; row = the newest full scan's row for this random-stat version ("of the Bear") or nil; scanned = when the
-- last full scan finished. Returns the label, the muted note after it ("3,365 listed · 76 min ago"), the price (nil
-- for a line without one), whether it is current, and for a line without a price the word on the right.
-- Every line says how old it is: a price is never shown as if it were live.
function ns.auctionLine(label, stack, it, row, scanned, now, serverNow)
  -- shared prices (SharedPrices.lua) say whose scan they are: "other players' scan · 12 min ago"
  local function src(p) return type(p) == "table" and p.shared and "other players' scan" or nil end
  if row and row.low then
    local at = now - (serverNow - (row.at or serverNow))
    return label .. stack, join("this version", src(row), listed(row.qty), ago(at)), row.low, now - at < STALE, nil
  end
  if it and it[1] then
    return label .. stack, join(row == false and "any version" or nil, src(it), listed(it[2]), ago(it[4])), it[1],
      now - (it[4] or 0) < STALE, nil
  end
  if it and (it[2] or 0) > 0 then
    -- the last full scan found some, but only with a bid and no buyout
    return label, join(listed(it[2]) .. " with bids only", src(it), ago(it[4])), nil, false, "no buyout"
  end
  if scanned then return label, join("full scan " .. ago(scanned)), nil, false, "none listed" end
end

-- How many are in the stack the mouse is over (a bag or bank slot), or nil: from the slot itself, else the count the
-- button shows.
local function hoveredCount(tooltip)
  if not tooltip or not tooltip.GetOwner then return nil end
  local okO, owner = pcall(tooltip.GetOwner, tooltip)
  if not okO or type(owner) ~= "table" then return nil end
  if owner.GetBagID and owner.GetID and C_Container and C_Container.GetContainerItemInfo then
    local okB, bag = pcall(owner.GetBagID, owner)
    local okS, slot = pcall(owner.GetID, owner)
    if okB and okS and bag and slot then
      local okI, info = pcall(C_Container.GetContainerItemInfo, bag, slot)
      local n = okI and info and ok(info.stackCount)
      if type(n) == "number" and n > 0 then return n end
    end
  end
  if type(owner.count) == "number" and owner.count > 0 then return owner.count end
  local fs = owner.Count or (owner.GetName and owner:GetName() and _G[owner:GetName() .. "Count"])
  local n = fs and fs.GetText and tonumber(ok(fs:GetText()) or "")
  return n and n > 0 and n or nil
end

-- How many the price lines are for: Ctrl = the stack under the mouse (14 flowers), Shift = a full stack, else one.
local function tipMultiplier(id, tooltip)
  if IsControlKeyDown and IsControlKeyDown() and tipOn("stack") then
    local n = hoveredCount(tooltip)
    if n then return n end
  end
  return IsShiftKeyDown() and tipOn("stack") and stackSize(id) or 1
end

-- The auction house lines and their 30-day low and median, for the tooltip's item id.
local function auctionLines(t, id, tooltip)
  if not db then return end
  local stack = tipMultiplier(id, tooltip)
  local function each(p) return stack > 1 and (p * stack) or p end
  local suffix = stack > 1 and (" x" .. stack) or ""
  local keys = { factionKey() }
  local neutral = realmKey() .. "-Neutral"
  if db.houses[neutral] or (ns.shared and ns.shared.house(neutral)) then keys[#keys + 1] = neutral end
  -- random-stat gear: the tooltip's own version ("of the Bear") has its own price in the full scan
  local vkey
  if tooltip and tooltip.GetItem then
    local okItem, _, link = pcall(tooltip.GetItem, tooltip)
    local key, sfx = variantOf(id, okItem and ok(link) or nil)
    if key and sfx and sfx ~= 0 then vkey = key end
  end
  for _, key in ipairs(keys) do
    local h = db.houses[key]
    local side = key:match("%-(%a+)$")
    -- our own prices and other players' shared scan, the newer of the two (ns.itemFor)
    local it = ns.itemFor(id, side)
    local d = ns.historyDays(id, side)
    local label = side == "Neutral" and "Neutral auction house" or "Auction house"
    if tipOn("auction") and (h or (ns.shared and ns.shared.house(key))) then
      -- false: a version that isn't in the newest scan, so the line says the price is for any version
      local row = vkey and (ns.scanRowFor(vkey, side) or false) or nil
      local left, note, price, fresh, word = ns.auctionLine(label, suffix, it, row, d and ns.pricesAt(side),
        time(), GetServerTime and GetServerTime() or time())
      if left then
        t:Line(left, price and Tip.Money(each(price)) or word, { note = note, stale = not fresh })
      end
    end
    if d and tipOn("history") then
      local list = {}
      for _, p in pairs(d) do list[#list + 1] = p end
      table.sort(list)
      if #list > 0 then
        -- one price per line, so every price sits in the right-hand column
        local low, med = list[1], list[math.floor((#list + 1) / 2)]
        t:Detail(HISTORY_DAYS .. "-day low" .. suffix, Tip.Money(each(low)))
        if #list > 2 then t:Detail(HISTORY_DAYS .. "-day median" .. suffix, Tip.Money(each(med))) end
      end
    end
  end
end

local function disenchantLine(t, id)
  if not db or not tipOn("disenchant") or not ns.disenchantValue then return end
  local value, oldest = ns.disenchantValue(id)
  if value then
    -- how old the oldest material price is, so an old estimate doesn't pass for today's
    t:Line("Disenchant", Tip.Money(value), { note = join("estimate", "prices " .. ago(time() - (oldest or 0))),
      stale = (oldest or 0) >= STALE })
  end
end

-- What crafting one costs from the latest AH prices, for items you know a recipe for (Purchases.lua reads your
-- recipes when a profession window opens).
local function craftLine(t, id)
  if not db or not tipOn("craft") or not (ns.purchases and ns.purchases.craftLine) then return end
  local cost, missing, oldest, makes = ns.purchases.craftLine(id)
  if cost then
    -- green when crafting it is cheaper than buying it, red when dearer
    local it = ns.itemFor and ns.itemFor(id)
    local ah = it and it[1]
    local tone = type(ah) == "number" and ah > 0 and (cost < ah and "good" or cost > ah and "bad") or nil
    t:Line("Craft cost", Tip.Money(cost), { note = join(makes and makes > 1 and "each" or nil, "AH materials",
      oldest and ago(oldest) or nil), stale = oldest ~= nil and time() - oldest >= STALE, tone = tone or nil })
  elseif missing and missing > 0 then
    t:Line("Craft cost", missing == 1 and "1 material unpriced" or (missing .. " materials unpriced"), { stale = true })
  end
end

-- Whether the game already put its own "Sell Price" on this tooltip (it does in bags, not on quest rewards, loot or links)
local tipDebug   -- /eah tipdebug: the next item tooltip prints what the vendor line saw
local function gameShowsSellPrice(tt)
  if not tt then return false end
  -- a money frame that is really on this tooltip (the count alone can be left over from an earlier tooltip)
  local tname = tt.GetName and tt:GetName()
  for i = 1, (tt.shownMoneyFrames or 0) do
    local mf = tname and _G[tname .. "MoneyFrame" .. i]
    if mf and mf.IsShown and mf:IsShown() and (not mf.GetParent or mf:GetParent() == tt) then return true end
  end
  local name, label = tt.GetName and tt:GetName(), SELL_PRICE
  if not name or not label then return false end
  for i = 1, (tt.NumLines and tt:NumLines() or 0) do
    local fs = _G[name .. "TextLeft" .. i]
    local text = fs and fs.GetText and fs:GetText()
    if text and text:find(label, 1, true) == 1 then return true end
  end
  return false
end

local function vendorLine(t, id, tt)
  if tipDebug and tt then
    tipDebug = nil
    local info = { pcall(C_Item.GetItemInfo, id) }
    print(("|cff4fc3f7EverlookDB Auctions|r tooltip: item %s, sell price %s, setting %s, game shows a sell price: %s (money frames %s)"):format(
      tostring(id), tostring(info[1] and info[12]), tostring(tipOn("vendor")), tostring(gameShowsSellPrice(tt)),
      tostring(tt.shownMoneyFrames)))
  end
  if not db or not tipOn("vendor") or gameShowsSellPrice(tt) then return end
  local stack = tipMultiplier(id, tt)
  local info = { pcall(C_Item.GetItemInfo, id) }
  local sell = ok(info[1] and info[12])
  if sell and sell > 0 then
    t:Line("Vendor" .. (stack > 1 and (" x" .. stack) or ""), Tip.Money(sell * stack))
  end
end

-- "More to vendor" or "More to auction": which pays more for this item, the vendor or the auction house after its
-- cut (5%, or 15% at the neutral houses in Booty Bay, Gadgetzan and Everlook; the deposit is left out: it comes back
-- when the item sells). Only when both prices are known; an old auction price makes the line grey.
-- Returns "auction" or "vendor", the difference per item in copper, whether the price is old, and the cut in percent.
function ns.sellVerdict(id)
  local it = ns.itemFor(id)
  local ah = it and it[1]
  local info = { pcall(C_Item.GetItemInfo, id) }
  local sell = ok(info[1] and info[12])
  if type(ah) ~= "number" or ah <= 0 or type(sell) ~= "number" or sell <= 0 then return nil end
  local cut = tostring(ns.houseOrFaction and ns.houseOrFaction() or ""):match("%-Neutral$") and 15 or 5
  local net = math.floor(ah * (1 - cut / 100))
  return net > sell and "auction" or "vendor", math.abs(net - sell), time() - (it[4] or 0) >= STALE, cut
end

local function verdictLine(t, id, tt)
  if not db or not tipOn("verdict") then return end
  local which, diff, stale, cut = ns.sellVerdict(id)
  if not which then return end
  local stack = tipMultiplier(id, tt)
  -- "Auction beats vendor  after 5% cut   +1s 97c": how much more the better way pays, per item (or stack)
  if diff <= 0 then
    t:Line("Auction or vendor", "same", { note = "after " .. cut .. "% cut", stale = stale })
    return
  end
  t:Line(which == "auction" and "Auction beats vendor" or "Vendor beats auction", Tip.Money(diff * stack, { sign = true }),
    { note = "after " .. cut .. "% cut", tone = not stale and "good" or nil, stale = stale })
end

-- Whether 30-day lows and medians need Shift held (db.tip.detail = "shift"; shown always by default). The setting is
-- shared by every EverlookDB addon's detail lines on the tooltip.
function ns.tipDetail(mode)
  if mode ~= nil and db then
    db.tip = db.tip or {}
    db.tip.detail = mode == "shift" and "shift" or nil
  end
  local m = db and db.tip and db.tip.detail or "always"
  if Tip then Tip:SetDetail(m) end
  return m
end

local function hookTooltips()
  if not Tip then return end
  ns.tipDetail()
  if Tip.LoadSolid then Tip:LoadSolid(db and db.tip) end
  Tip:Register({ id = "EverlookDBAuctions.auction", kind = "item", order = Tip.ORDER.auction,
    add = function(t, ctx) if ctx.id then auctionLines(t, ctx.id, ctx.tooltip) end end })
  Tip:Register({ id = "EverlookDBAuctions.disenchant", kind = "item", order = Tip.ORDER.disenchant,
    add = function(t, ctx) if ctx.id then disenchantLine(t, ctx.id) end end })
  Tip:Register({ id = "EverlookDBAuctions.craft", kind = "item", order = Tip.ORDER.craftCost or (Tip.ORDER.disenchant + 2),
    add = function(t, ctx) if ctx.id then craftLine(t, ctx.id) end end })
  Tip:Register({ id = "EverlookDBAuctions.vendor", kind = "item", order = Tip.ORDER.vendor,
    add = function(t, ctx) if ctx.id then vendorLine(t, ctx.id, ctx.tooltip) end end })
  Tip:Register({ id = "EverlookDBAuctions.verdict", kind = "item", order = Tip.ORDER.verdict or (Tip.ORDER.vendor + 1),
    add = function(t, ctx) if ctx.id then verdictLine(t, ctx.id, ctx.tooltip) end end })
end
ns.tooltipLines = { auction = auctionLines, disenchant = disenchantLine, vendor = vendorLine, craft = craftLine }

---------------------------------------------------------------------------------------------------------------------
-- Events and commands

local visits = 0   -- counts auction house visits, so a timer from an earlier visit does nothing

local function onShow(retried)
  if not retried then visits = visits + 1 end
  house, houseSide = currentHouseKey()
  local parent = ahFrame()
  -- Blizzard loads the auction house UI on this same event; if it isn't there yet, look again next frame
  if not parent and not retried then C_Timer.After(0, function() if house then onShow(true) end end); return end
  if parent and not panel then panel = makePanel(parent) end
  setStatus(nil)
  refreshPanel()
  -- once per account, without the Price Feed's data: one quiet chat line saying where it comes from
  if ns.shared and ns.shared.hintOnce then pcall(ns.shared.hintOnce) end
  -- Automatic full scan when the last one is 30+ minutes old (db.auto, on by default; /eah auto off).
  -- AUTO_DELAY seconds after opening first: a quick visit (buy one thing, close) doesn't spend the server's one scan
  -- per 15 minutes on a list nobody waits for, and the window finishes opening before the list comes in.
  if db.auto ~= false and not scan then
    local h = getHouse(house)
    if not h.tried or time() - h.tried >= AUTO_EVERY then
      local visit = visits
      C_Timer.After(AUTO_DELAY, function()
        if visit == visits and house and not scan and ahFrame() and ahFrame():IsShown() then startScan(true) end
      end)
    end
  end
end

local FIX_FROM = 20773   -- 2026-11-16 (days since 1970, UTC): the day before v0.10.0 shipped
local FIX_MEMORY_FROM = 20771   -- 2026-11-14: Quick sell suggested the divided price from its first version
local function maxStackOf(id)
  -- the addon's own saved item details first (there at login), then the game
  local info = db and db.itemInfo and db.itemInfo[id]
  if type(info) == "table" and type(info[10]) == "number" then return info[10] end
  if type(info) == "string" then   -- packed "quality^ilvl^req^category^type^equip^icon^sell^stack^name" (Search.lua)
    local n = 0
    for part in (info .. "^"):gmatch("([^%^]*)%^") do
      n = n + 1
      if n == 9 then local v = tonumber(part); if v then return v end; break end
    end
  end
  local okS, n = pcall(C_Item.GetItemMaxStackSizeByID or function() return nil end, id)
  if okS and type(n) == "number" then return n end
  return nil
end

-- Scans and houses saved while the game didn't say the realm (v0.16.0 and older on client build 71037 saved realm ""
-- and realm ID 0 or the real ID, and the house "-Alliance"; this version saves "?" and marks the scan needsRealm). At each login, once the realm is known,
-- they get this realm, but only when that is certain:
--   - the scan names its realm in part (its ID, name or normalized name) and that part is this realm's, or
--   - nothing in it names a realm, it is of this character's side (or Neutral), and the account's saved data names
--     no other realm (houses, scans, realms seen).
-- Everything else stays as it is and /eah status says so. The scan's file changes, so the app sends it again.
local function noRealm(s) return s == nil or s == "" or s == "?" end
local function noRealmID(n) return type(n) ~= "number" or n <= 0 end

local function otherRealmKnown(name, id)
  for key in pairs(db.houses) do
    local r = tostring(key):match("^(.*)%-%a+$")
    if r and not noRealm(r) and r ~= name then return true end
  end
  for _, sc in ipairs(db.scans) do
    if not noRealm(sc.realm) and sc.realm ~= name then return true end
    if not noRealmID(sc.realmID) and sc.realmID ~= id then return true end
  end
  for kid in pairs(type(db.realms) == "table" and db.realms or {}) do if kid ~= id then return true end end
  return false
end

local function mergeHouse(from, to)
  to.items, to.days = to.items or {}, to.days or {}
  for id, v in pairs(from.items or {}) do
    local w = to.items[id]
    if type(v) == "table" and (type(w) ~= "table" or (v[4] or 0) > (w[4] or 0)) then to.items[id] = v end
  end
  for id, d in pairs(from.days or {}) do
    if type(d) == "table" then
      local t = to.days[id] or {}
      to.days[id] = t
      for day, low in pairs(d) do if not t[day] or low < t[day] then t[day] = low end end
    end
  end
  if (from.scanned or 0) > (to.scanned or 0) then to.scanned, to.took = from.scanned, from.took end
  for k, v in pairs(from) do if to[k] == nil then to[k] = v end end
end

local function repairRealms()
  if not db then return end
  local name, id, norm = readRealm()
  local pending = {}
  for _, sc in ipairs(db.scans) do
    if type(sc) == "table" and (noRealm(sc.realm) or noRealmID(sc.realmID) or sc.needsRealm) then pending[#pending + 1] = sc end
  end
  local houseKeys = {}
  for key in pairs(db.houses) do
    local r, side = tostring(key):match("^(.*)%-(%a+)$")
    if r and noRealm(r) then houseKeys[#houseKeys + 1] = { key = key, side = side } end
  end
  -- /eah status counts the scans that name no realm at all (one with its name or ID the site places by itself)
  local function count()
    realmUnfixed = 0
    for _, sc in ipairs(pending) do
      if noRealm(sc.realm) and noRealmID(sc.realmID) then realmUnfixed = realmUnfixed + 1 end
    end
  end
  count()
  -- the ID is enough for a scan (the site names the realm from its ID); a house key needs the name
  if not id or (#pending == 0 and #houseKeys == 0) then return end
  local faction = ok(UnitFactionGroup and UnitFactionGroup("player"))
  local others = otherRealmKnown(name, id)
  local function mySide(side) return side == "Neutral" or (faction ~= nil and side == faction) end
  local region = textOnly(GetCurrentRegionName and GetCurrentRegionName())
  for _, sc in ipairs(pending) do
    local same
    if not noRealmID(sc.realmID) then same = sc.realmID == id
    elseif not noRealm(sc.realm) then same = name ~= nil and sc.realm == name
    elseif textOnly(sc.realmNormalized) and norm then same = squash(sc.realmNormalized) == squash(norm)
    else same = not others and mySide(sc.side) end
    if same and ((noRealm(sc.realm) and name) or noRealmID(sc.realmID)) then
      if noRealm(sc.realm) then sc.realm = name end
      if noRealmID(sc.realmID) then sc.realmID = id end
      sc.realmNormalized = norm or textOnly(sc.realmNormalized)
      sc.region = textOnly(sc.region) or region
      sc.realmFixed = true
    end
    if not noRealm(sc.realm) and not noRealmID(sc.realmID) then sc.needsRealm = nil end
  end
  count()
  if others or not name then return end
  for _, k in ipairs(houseKeys) do
    if mySide(k.side) then
      local from, to = db.houses[k.key], name .. "-" .. k.side
      db.houses[k.key] = nil
      if type(from) == "table" then
        if type(db.houses[to]) == "table" then mergeHouse(from, db.houses[to]) else db.houses[to] = from end
      end
    end
  end
end
ns.repairRealms = repairRealms

local events = {}

-- the realm is surely known by the time the character is in the world: put old scans right then
function events.PLAYER_LOGIN() repairRealms() end
function events.PLAYER_ENTERING_WORLD() repairRealms() end

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
    -- v0.10.0-v0.12.0 divided an item's live price by how many were up (39s with 19 up became 2s 5c) and saved that as
    -- the item's price and day low. Once: drop search-saved prices and day lows since then for items that don't stack
    -- (those are never commodities, so they're the ones affected); the next update puts the real ones back.
    if not db.fixedLiveUnit2 then
      for id, v in pairs(h.items) do
        if type(v) == "table" and v[3] == nil and (v[4] or 0) >= FIX_FROM * 86400 and (maxStackOf(id) or 1) == 1 then h.items[id] = nil end
      end
      for id, d in pairs(h.days) do
        if (maxStackOf(id) or 1) == 1 then   -- not known yet counts too: better a lost day than a wrong low
          for day in pairs(d) do if day >= FIX_FROM then d[day] = nil end end
          if next(d) == nil then h.days[id] = nil end
        end
      end
    end
    -- an update that was running when the UI reloaded or the game closed ended without a word: log it once
    if h.tried and (not h.scanned or h.scanned < h.tried) and not h.why then
      h.why = "reload"
      h.log = h.log or {}
      table.insert(h.log, 1, { at = h.tried, how = "cut off by a reload or logout" })
      while #h.log > 20 do table.remove(h.log) end
    end
  end
  -- the prices you posted at in those versions were the wrong suggestion too: forget them for items that don't stack
  if not db.fixedLiveUnit2 and type(db.sell) == "table" and type(db.sell.memory) == "table" then
    for key, m in pairs(db.sell.memory) do
      local id = tonumber(tostring(key):match("^(%d+)"))
      if type(m) == "table" and (m.at or 0) >= FIX_MEMORY_FROM * 86400 and id and (maxStackOf(id) or 1) == 1 then db.sell.memory[key] = nil end
    end
  end
  db.fixedLiveUnit2 = true
  -- what the game gives us on this build, for EverlookDB.com's canary (Health.lua); a failing test never stops loading
  if ns.HealthCheck then pcall(ns.HealthCheck, db, addonVersion()) end
  repairRealms()
  hookTooltips()
end

function events.AUCTION_HOUSE_SHOW() onShow() end

function events.AUCTION_HOUSE_CLOSED()
  if scan then
    if scan.reading then
      -- the list is here: the update finishes without the auction house (processList), at once if it is waiting
      scan.aborted = true
      if scan.wake then scan.wake() end
    else
      -- nothing answered yet: the request goes unused, so the wait for the next one is given back
      scan = nil
      if house then
        local h = getHouse(house)
        h.why = "closed"
        logScan(h, "AH closed while waiting")
        h.tried = nil
      end
    end
  end
  house = nil
  awaiting = 0
end

function events.REPLICATE_ITEM_LIST_UPDATE()
  if not scan or scan.mode ~= "replicate" or scan.reading then return end
  scan.reading, scan.beat = true, GetTime()
  local total = C_AuctionHouse.GetNumReplicateItems() or 0
  processList(total, 0, readModern)   -- the replicate list counts from 0
end

function events.AUCTION_ITEM_LIST_UPDATE()
  if not scan or scan.mode ~= "getall" or scan.reading then return end
  scan.reading, scan.beat = true, GetTime()
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

-- /eah debug: what is shown where, for bug reports about tabs and panels ("I click Selling and nothing changes"),
-- and the technical side of price updates: the auction API, each house's update log, the scans kept.
function ns.debugReport()
  local ah = _G.AuctionHouseFrame
  say(("debug: version %s; auction API: %s; frame: %s"):format(addonVersion(), apiKind() or "none found",
    _G.AuctionHouseFrame and "AuctionHouseFrame (modern)" or _G.AuctionFrame and "AuctionFrame (classic)" or "not loaded yet"))
  for key, h in pairs(db.houses) do
    print(("  %s: %s items priced, %s"):format(key, num(ns.countItems(h)), h.scanned and ("last full scan " .. ago(h.scanned)) or "no full scan yet"))
    for i, e in ipairs(h.log or {}) do
      if i > 8 then break end
      print(("    %s: %s%s"):format(ago(e.at), e.how, e.secs and (" after " .. e.secs .. " s") or ""))
    end
  end
  local packed = 0
  for _, sc in ipairs(db.scans) do if not sc.rows then packed = packed + 1 end end
  print(("  full scans kept for EverlookDB.com: %d (%d packed); the last %d days, up to %d"):format(#db.scans, packed,
    KEEP_DAYS, MAX_SCANS))
  local n, oldest = unsavedInfo()
  if n > 0 then
    print(("  %d %s from this session not on disk yet (oldest %d min)"):format(n, n == 1 and "scan" or "scans",
      math.floor((GetServerTime() - oldest) / 60)))
  end
  print(("  test mode (/eah test, reload after every full scan): %s"):format(db.reloadAfterScan and "on" or "off"))
  print(("  AuctionHouseFrame %s, mode %s, tab %s"):format(ah and (ah:IsShown() and "shown" or "hidden") or "missing",
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
end

-- /eah test: reload after every full scan, so it is saved at once
function ns.toggleTestMode()
  db.reloadAfterScan = not db.reloadAfterScan
  say(db.reloadAfterScan and "test mode on: the UI reloads after the next full scan, so it is saved at once."
    or "test mode off.")
end
ns.testMode = function() return db.reloadAfterScan and true or false end

-- /eah: the shared EverlookDB command pattern (EverlookUI, set up in Options.lua): help, get/set, search, status,
-- version and suggestions; the commands below are registered there. Without the options (they failed to build) the
-- old handling below still answers.
SLASH_EVERLOOKAUCTIONS1 = "/eah"
SlashCmdList.EVERLOOKAUCTIONS = function(msg)
  msg = (msg or ""):lower():match("^%s*(.-)%s*$")
  if ns.app then ns.app:HandleSlash(msg) return end
  if ns.slash and ns.slash(msg) then return end
  if msg == "scan" then startScan(); return end
  if msg == "bought" or msg == "purchases" then if ns.purchases then ns.purchases.toggle() end return end
  if msg == "debug" then ns.debugReport() return end
  if msg == "tipdebug" then tipDebug = true; print("|cff4fc3f7EverlookDB Auctions|r: hover an item; its tooltip prints what the vendor line saw.") return end
  if msg == "test" then ns.toggleTestMode() return end
  if msg == "auto off" or msg == "auto on" then
    db.auto = msg == "auto on"
    if ns.optionsRefresh then ns.optionsRefresh() end   -- the options window shows the change if it is open
    say(db.auto and "prices update by themselves (when you open the auction house, then every 30 minutes while it is open)."
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
    say("version " .. addonVersion())
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
    return
  end
  say(("unknown command \"%s\". /eah help lists the commands, for example /eah scan or /eah undercut 1s."):format(plain(msg)))
end

-- /eah status, for players: one line per auction house with prices ("Alliance: 8,123 prices, updated 12 min ago"),
-- then the scans waiting to be saved for upload. The version comes first (EverlookUI prints it; the old path below
-- says it itself). The technical lines are in /eah debug.
local function houseName(key)
  local realm, side = key:match("^(.*)%-(%a+)$")
  if not realm then return key end
  return realm == realmName() and side or (side .. " (" .. realm .. ")")
end

function ns.statusLines()
  local out = {}
  local keys = {}
  for key in pairs(db.houses) do keys[#keys + 1] = key end
  table.sort(keys, function(a, b) return houseName(a) < houseName(b) end)
  for _, key in ipairs(keys) do
    local h = db.houses[key]
    out[#out + 1] = ("%s: %s prices, %s"):format(houseName(key), num(ns.countItems(h)),
      h.scanned and ("updated " .. ago(h.scanned)) or "no full update yet")
  end
  local shared = ns.shared and ns.shared.statusLines() or {}
  for _, l in ipairs(shared) do out[#out + 1] = l end
  if #keys == 0 and #shared == 0 then out[#out + 1] = "No prices yet: open the auction house and let it update prices, or just search." end
  local n = unsavedInfo()
  if n > 0 then
    out[#out + 1] = ("%d %s waiting to upload: saved for EverlookDB.com when you log out or reload"):format(n,
      n == 1 and "scan" or "scans")
  end
  if ns.droppedText then
    local dropped = ns.droppedText()
    if dropped then out[#out + 1] = dropped end
  end
  if realmUnfixed > 0 then
    out[#out + 1] = ("%d %s saved without the realm it is from, so EverlookDB.com can't take %s yet. %s put right when"
      .. " you log in on that realm, unless this account has played on other realms too: then it can't be told which.")
      :format(realmUnfixed, realmUnfixed == 1 and "scan was" or "scans were", realmUnfixed == 1 and "it" or "them",
        realmUnfixed == 1 and "It is" or "They are")
  end
  return out
end

function showStatus()
  for _, line in ipairs(ns.statusLines()) do print("  " .. line) end
end
ns.showStatus = function() showStatus() end

-- The full scan, for Advanced search's Below vendor: how old the last one is, whether one can start now (else in how
-- many seconds), and starting one.
ns.scanAge = function()
  local h = house and db.houses[house]
  return h and h.scanned and (time() - h.scanned) or nil
end
ns.scanWaitLeft = function() return house and math.max(0, scanWait(getHouse(house))) or nil end
ns.scanning = function() return scan ~= nil end
-- How far the running full scan is (0 to 0.99, as the price bar shows it), nil when none runs (the Upgrades tab).
ns.scanProgress = function()
  if not scan then return nil end
  if not scan.reading or not scan.total or scan.total <= 0 then return 0 end
  return math.min(0.99, (scan.done or 0) / scan.total)
end
ns.startScan = function() startScan() end

-- Shared with Sell.lua, Search.lua and Skin.lua
ns.db = function() return db end
ns.house = function() return house end
ns.money, ns.num, ns.ago, ns.say, ns.variantOf, ns.ahFrame, ns.ok = money, num, ago, say, variantOf, ahFrame, ok
ns.plain = plain
ns.realmName = realmName   -- the realm's name, or nil while nothing says it
ns.realmInfo = readRealm    -- name, ID, normalized name (each nil while unknown)

-- Which saved auction house to read: the one given ("Alliance", "Horde" or "Neutral" on this realm), else the one
-- that is open, else the player's own faction's.
local function keyFor(side)
  if side then return realmKey() .. "-" .. side end
  return house or factionKey()
end
-- the open auction house, else your faction's (what tooltips use), for searches away from the auction house
ns.houseOrFaction = function() return keyFor() end

-- The Price Feed (SharedPrices.lua): other players' newest scan, from the EverlookDB App. It is never written into
-- db; each lookup below takes whichever is newer, our own or the shared one, per item and per item version.

-- The newest full scan's row for "id:suffix": { low, p10, med, qty, n, at } (at is server time), or nil. A row from
-- the shared scan has shared = true.
function ns.scanRowFor(key, side)
  if not db then return nil end
  local hk = keyFor(side)
  local realm, want = hk:match("^(.*)%-(%a+)$")
  local mine, mineAt
  for k = #db.scans, 1, -1 do
    local sc = db.scans[k]
    if sc.realm == realm and sc.side == want then
      mineAt = sc.at or 0
      local row = sc.rows and sc.rows[key]
      if row then
        local f = { strsplit(",", row) }
        mine = { low = tonumber(f[1]), p10 = tonumber(f[2]), med = tonumber(f[3]), qty = tonumber(f[4]), n = tonumber(f[5]), at = sc.at }
      end
      break
    end
  end
  local sh = ns.shared and ns.shared.house(hk)
  if sh and (not mineAt or sh.at > mineAt) then
    -- the newer full scan is the shared one: what it doesn't list wasn't up
    return ns.shared.row(hk, key) or nil
  end
  return mine
end

-- Lowest price per day for an item over the last 30 days, ours and the shared scans' together (the lower of the
-- two each day): { [day number] = copper } or nil.
function ns.historyDays(id, side)
  local hk = keyFor(side)
  local h = db and db.houses[hk]
  local mine = h and h.days[id]
  local theirs = ns.shared and ns.shared.days(hk, id)
  if not theirs then return mine end
  local oldest = today() - HISTORY_DAYS
  local out = {}
  for day, p in pairs(theirs) do if day >= oldest then out[day] = p end end
  for day, p in pairs(mine or {}) do if not out[day] or p < out[day] then out[day] = p end end
  return next(out) and out or mine
end

-- Lowest price per day for an item (last 30 days), oldest first: { { day, price }, ... }.
function ns.historyFor(id, side)
  local out = {}
  local d = db and ns.historyDays(id, side)
  if d then for day, p in pairs(d) do out[#out + 1] = { day, p } end end
  table.sort(out, function(a, b) return a[1] < b[1] end)
  return out
end

-- The price for an item: { lowest unit buyout, quantity, auctions, time } or nil: our own saved one, or the shared
-- scan's (with shared = true) when that is newer. Callers only read it.
function ns.itemFor(id, side)
  local hk = keyFor(side)
  local h = db and db.houses[hk]
  local mine = h and h.items[id]
  local theirs = ns.shared and ns.shared.item(hk, id)
  if theirs and (not mine or theirs[4] > (mine[4] or 0)) then return theirs end
  return mine
end

-- How old a house's prices are and whose they are: the newer of our last full scan and the shared scan (local
-- time), and true when it is the shared one. nil when there is neither.
function ns.pricesAt(side)
  local hk = keyFor(side)
  local h = db and db.houses[hk]
  local mine = h and h.scanned
  local sh = ns.shared and ns.shared.house(hk)
  local theirs = sh and ns.shared.localAt(sh)
  if theirs and (not mine or theirs > mine) then return theirs, true end
  return mine, false
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
-- What the auction house keeps of a sale: 5%, or 15% at the neutral houses (Booty Bay, Gadgetzan, Everlook).
function ns.ahCut() return houseSide == "Neutral" and 0.15 or 0.05 end
ns.today = today
