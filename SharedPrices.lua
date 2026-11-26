-- EverlookDB Auctions: the Price Feed, the newest scans other players uploaded to EverlookDB.com.
--
-- The Price Feed is its own small addon, EverlookDBAuctions_Shared ("EverlookDB Auctions: Price Feed"). It ships
-- empty (written = 0, no houses); the EverlookDB App fills it with the scans of the player's auction houses. It sets the
-- global EverlookDBAuctionsShared = { version = 1, written = <unix time>, houses = { [server key] = {
--   region, realm, realmID, side, at (server time of the scan), auctions, firstDay (day number of lows' first value),
--   rows = { ["id:suffix"] = row text, the same as our own scans' rows },
--   lows = { [itemID] = "28,,30": the lowest price per day from firstDay on, all versions together } } } }.
-- The game loads it at login and /reload (the TOC's OptionalDeps loads it first), so it is as fresh as that.
--
-- Everything in it is checked before use (it is a file on disk anyone could edit): wrong types, odd keys and rows
-- that aren't plain numbers are skipped, and a missing or broken file is the same as none. It is kept apart from the
-- player's own saved data and never written into it: the core merges the two at read time, newest first
-- (ns.itemFor, ns.scanRowFor, ns.historyFor, the tooltip and the Prices window). db.ignoreShared turns it off.
local _, ns = ...

local S = {}
ns.shared = S

local SIDES = { Alliance = true, Horde = true, Neutral = true }
local MAX_PRICE = 99999999999
local houses   -- "realm-side" -> house, read once

local function plain(n)
  return type(n) == "number" and n == n and n >= 0 and n <= MAX_PRICE and math.floor(n) == n
end

-- Reads the global once: the newest house per realm and side, with its facts checked.
local function load()
  if houses then return houses end
  houses = {}
  local d = rawget(_G, "EverlookDBAuctionsShared")
  if type(d) ~= "table" or d.version ~= 1 or type(d.houses) ~= "table" then return houses end
  for key, h in pairs(d.houses) do
    if type(key) == "string" and type(h) == "table" and type(h.realm) == "string" and SIDES[h.side]
        and plain(h.at) and h.at > 0 and type(h.rows) == "table" then
      local hk = h.realm .. "-" .. h.side
      local old = houses[hk]
      if not old or old.at < h.at then
        houses[hk] = { key = key, realm = h.realm, side = h.side, at = h.at, raw = h.rows,
          lows = type(h.lows) == "table" and h.lows or {}, firstDay = plain(h.firstDay) and h.firstDay or nil }
      end
    end
  end
  return houses
end

-- One row's numbers, or nil when it isn't the plain "low,p10,med,qty,n,..." form (a price may be empty).
local function readRow(text)
  if type(text) ~= "string" or #text > 300 then return nil end
  local low, p10, med, qty, n = text:match("^(%d*),(%d*),(%d*),(%d+),(%d+)")
  if not qty then return nil end
  low, p10, med, qty, n = tonumber(low), tonumber(p10), tonumber(med), tonumber(qty), tonumber(n)
  if (low and not plain(low)) or (med and not plain(med)) or not plain(qty) or not plain(n) or n < 1 then return nil end
  return low, p10, med, qty, n
end

-- The checked rows (same form as our own scans, so the Prices window can read them like one) and per item the
-- lowest price, quantity and auctions over all its versions. Worked out once, the first time they're needed.
local function prepare(h)
  if h.rows then return h end
  local rows, items = {}, {}
  for key, text in pairs(h.raw) do
    if type(key) == "string" and key:match("^%d+:%-?%d+$") then
      local low, _, _, qty, n = readRow(text)
      if qty then
        rows[key] = text
        local id = tonumber(key:match("^(%d+)"))
        local it = items[id]
        if not it then it = { nil, 0, 0 }; items[id] = it end
        if low and (not it[1] or low < it[1]) then it[1] = low end
        it[2] = it[2] + qty
        it[3] = it[3] + n
      end
    end
  end
  h.rows, h.items, h.raw = rows, items, nil
  h.scan = { realm = h.realm, side = h.side, at = h.at, rows = rows, shared = true }
  return h
end

function S.enabled()
  local db = ns.db and ns.db()
  return not (type(db) == "table" and db.ignoreShared)
end

-- The shared house for "realm-side", or nil (none, or ignored).
function S.house(hk)
  if not S.enabled() or type(hk) ~= "string" then return nil end
  local h = load()[hk]
  return h and prepare(h)
end

-- When the shared scan was taken, on this computer's clock (what time() and our own prices use).
function S.localAt(h)
  local server = GetServerTime and GetServerTime() or time()
  return h.at - (server - time())
end

-- The item's price in the shared scan, in the form of our saved prices: { low, quantity, auctions, time, shared = true }.
function S.item(hk, id)
  local h = S.house(hk)
  local it = h and h.items[id]
  if not it then return nil end
  return { it[1], it[2], it[3], S.localAt(h), shared = true }
end

-- One item version's row: { low, p10, med, qty, n, at (server time), shared = true }; false when the shared scan
-- doesn't list it; nil when there is no shared scan.
function S.row(hk, key)
  local h = S.house(hk)
  if not h then return nil end
  local low, p10, med, qty, n = readRow(h.rows[key])
  if not qty then return false end
  return { low = low, p10 = p10, med = med, qty = qty, n = n, at = h.at, shared = true }
end

-- The shared daily lows of an item: { [day number] = lowest price }, or nil.
function S.days(hk, id)
  local h = S.house(hk)
  local text = h and h.firstDay and h.lows[id]
  if type(text) ~= "string" or #text > 600 then return nil end
  h.dayCache = h.dayCache or {}
  if h.dayCache[id] ~= nil then return h.dayCache[id] or nil end
  local out, i, any = {}, 0, false
  for v in (text .. ","):gmatch("([^,]*),") do
    local p = tonumber(v)
    if p and plain(p) then out[h.firstDay + i] = p; any = true end
    i = i + 1
  end
  h.dayCache[id] = any and out or false
  return any and out or nil
end

-- The shared scan as one of our own scans ({ realm, side, at, rows, shared = true }), for the Prices window.
function S.scan(hk)
  local h = S.house(hk)
  return h and h.scan
end

-- Where a price comes from, for the notes beside it: "other players' scan" for shared ones, else nil.
function S.source(p)
  return type(p) == "table" and p.shared and "other players' scan" or nil
end

-- The Price Feed's lines, where the addon shows its scan status (the bar at the bottom of the auction house, the
-- General settings page, /eah status and the one-time hint).
S.OFF_TEXT = "Price Feed: off · the EverlookDB App brings other players' newest scans (everlookdb.com)"
S.EMPTY_TEXT = "Price Feed: no data yet · the EverlookDB App fills it (everlookdb.com)"
S.IGNORED_TEXT = "Price Feed: turned off in your settings (/eah, General)"
-- the same, short, for where the long ones don't fit (the auction house bar with its buttons beside it)
S.SHORT = {
  off = "Price Feed: off · get the EverlookDB App (everlookdb.com)",
  empty = "Price Feed: no data yet · see everlookdb.com",
  ignored = "Price Feed: turned off (/eah, General)",
}

-- "on" (it holds scans), "empty" (installed, but nothing in it yet: the shipped empty copy, the app isn't running)
-- or "none" (not installed, or not loaded).
function S.state()
  local d = rawget(_G, "EverlookDBAuctionsShared")
  if type(d) ~= "table" or d.version ~= 1 then return "none" end
  return next(load()) and "on" or "empty"
end

-- How old a scan is: "12 min old".
local function old(t)
  local d = math.max(0, time() - (t or 0))
  if d < 5400 then return math.max(1, math.floor(d / 60 + 0.5)) .. " min old" end
  if d < 129600 then return math.floor(d / 3600 + 0.5) .. " h old" end
  return math.floor(d / 86400 + 0.5) .. " days old"
end

-- The house to show when none is given (the settings page): this realm's, your faction's first.
local function here()
  local realm = ns.realmName and ns.realmName()
  if not realm then return nil end
  local all = load()
  for _, side in ipairs({ UnitFactionGroup and UnitFactionGroup("player") or "?", "Neutral" }) do
    if all[realm .. "-" .. side] then return realm .. "-" .. side end
  end
  return nil
end

-- One line: "Price Feed: <house> · other players' scan, 12 min old", or why there is none. `label` names the house
-- in the line (the bar says only the side, as its own line does). `short`: a shorter line saying the same.
function S.feedLine(hk, label, short)
  if not S.enabled() then return short and S.SHORT.ignored or S.IGNORED_TEXT end
  local state = S.state()
  if state == "none" then return short and S.SHORT.off or S.OFF_TEXT end
  if state == "empty" then return short and S.SHORT.empty or S.EMPTY_TEXT end
  hk = hk or here()
  local h = hk and load()[hk]
  if not h then
    if short then return "Price Feed: on · no scan of this house yet" end
    if hk then return "Price Feed: on · no one has uploaded a scan of this auction house yet" end
    return "Price Feed: on · no scan of this realm's auction houses yet"
  end
  if short then return ("Price Feed: %s, %s"):format(label or h.side, old(S.localAt(h))) end
  return ("Price Feed: %s · other players' scan, %s"):format(label or (h.realm .. " " .. h.side), old(S.localAt(h)))
end

-- Once per account, the first time the auction house opens without the feed's data: one quiet chat line.
function S.hintOnce()
  local db = ns.db and ns.db()
  if type(db) ~= "table" or db.feedHinted or not S.enabled() then return false end
  local state = S.state()
  if state == "on" then return false end
  db.feedHinted = true
  if ns.say then ns.say(state == "empty" and S.EMPTY_TEXT or S.OFF_TEXT) end
  return true
end

-- For /eah status: one line per house in the feed, or why there is none.
function S.statusLines()
  local out = {}
  if not S.enabled() or S.state() ~= "on" then return { S.feedLine() } end
  for hk, h in pairs(load()) do
    prepare(h)
    local n = 0
    for _ in pairs(h.items) do n = n + 1 end
    out[#out + 1] = ("Price Feed, %s: %s items, other players' scan %s"):format(hk, ns.num and ns.num(n) or n,
      ns.ago and ns.ago(S.localAt(h)) or "")
  end
  table.sort(out)
  return out
end

-- When the EverlookDB App wrote the copy the game loaded (its own `written`), on this computer's clock; nil when the
-- copy doesn't say (or is the shipped empty one). The game reads the file only at login and /reload, so newer data
-- can only be on disk when this was a while ago.
function S.copyAt()
  local d = rawget(_G, "EverlookDBAuctionsShared")
  local w = type(d) == "table" and d.written
  if not plain(w) or w <= 0 then return nil end
  local server = GetServerTime and GetServerTime() or time()
  return w - (server - time())
end

-- The raw `written` of the loaded copy (server time), to tell after a reload whether the file changed.
function S.written()
  local d = rawget(_G, "EverlookDBAuctionsShared")
  local w = type(d) == "table" and d.written
  return plain(w) and w > 0 and w or nil
end

S.oldText = old

-- Tests: read the global again.
function S.reset() houses = nil end

-- Reading the rows takes a moment for a big house (20,000 rows): do it a few seconds after login, not on the first
-- tooltip.
if CreateFrame and C_Timer and C_Timer.After then
  local f = CreateFrame("Frame")
  f:RegisterEvent("PLAYER_LOGIN")
  f:SetScript("OnEvent", function()
    C_Timer.After(5, function()
      local realm = ns.realmName and ns.realmName()
      if not realm then return end
      for _, side in ipairs({ UnitFactionGroup and UnitFactionGroup("player") or "?", "Neutral" }) do
        pcall(S.house, realm .. "-" .. side)
      end
    end)
  end)
end
