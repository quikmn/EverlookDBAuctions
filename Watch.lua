-- EverlookDB Auctions: price alerts for items you watch.
--   Watching   /eah watch <item> (a name, an ID, or a shift-clicked link; on its own: the item under the mouse),
--              Ctrl+right-click an item in Quick sell, /eah unwatch <item>. The Price alerts page of the settings
--              lists them, each with Remove. Materials your crafting queue still needs (EverlookDB Crafting's queue)
--              count as watched too, while that setting is on.
--   When       a price update or the Price Feed brings a price (after Deals has worked its list out), and every quick
--              search of an item (Quick sell, Buy, the crafting price check): any of these under the setting's share
--              of the usual price (80%; usual = the middle of the last 30 days' daily lows, as Deals has it).
--   How        one chat line, and the item is marked "watched" in the Deals list. No popup, no sound.
--   No spam    once per item per price level (steps of 10% of the usual price): 72% says it once, 64% once more,
--              72% again says nothing. Back at its usual price, the next dip alerts again. Kept over /reload.
-- Saved: EverlookAuctionsDB.watch = { [item ID] = { name, at (when added), lvl (last level alerted), lvlAt } },
-- watchSeen = { [item ID] = { lvl, lvlAt } } (the crafting queue's materials), watchOff, watchPct, watchQueue.
local ADDON, ns = ...
local W = {}
ns.watch = W

W.PCT = 80                  -- alert under this share of the usual price
W.MAX_AGE = 3 * 3600        -- a price older than this never alerts
W.QUEUE_SECS = 30           -- the crafting queue's needs are read at most this often

local function db() return ns.db and ns.db() or nil end
local function money(c) return ns.money and ns.money(c) or tostring(c) end
local function num(n) return ns.num and ns.num(n) or tostring(n) end
local function try(fn, ...)
  if type(fn) ~= "function" then return nil end
  local okCall, a, b, c = pcall(fn, ...)
  if okCall then return a, b, c end
end
local function now() return time() end
local function say(msg) if ns.say then ns.say(msg) else print(msg) end end

function W.settings()
  local d = db() or {}
  local pct = tonumber(d.watchPct) or W.PCT
  return { on = not d.watchOff, pct = math.max(20, math.min(95, pct)), queue = d.watchQueue ~= false }
end

function W.store()
  local d = db()
  if not d then return nil end
  if type(d.watch) ~= "table" then d.watch = {} end
  return d.watch
end

function W.has(id)
  local d = db()
  return id ~= nil and d ~= nil and type(d.watch) == "table" and d.watch[id] ~= nil
end

local function nameOf(id)
  local n = try(C_Item and C_Item.GetItemNameByID, id)
  if not n and ns.listImport and ns.listImport.nameOf then n = ns.listImport.nameOf(id) end
  return n
end

local function linkOf(id, name)
  local okI, _, link = pcall(C_Item.GetItemInfo, id)
  if okI and type(link) == "string" then return link end
  return name or ("item " .. tostring(id))
end

function W.add(id, name)
  local s = W.store()
  id = tonumber(id)
  if not s or not id then return false end
  if s[id] then return false end
  s[id] = { name = name or nameOf(id), at = now() }
  return true
end

function W.remove(id)
  local s = W.store()
  id = tonumber(id)
  if not s or not id or not s[id] then return false end
  s[id] = nil
  return true
end

-- Adds or removes; with tell, says so in chat. Returns true when it is watched now.
function W.toggle(id, name, tell)
  id = tonumber(id)
  if not id then return false end
  name = name or nameOf(id) or ("item " .. id)
  if W.has(id) then
    W.remove(id)
    if tell then say(("stopped watching %s's price."):format(linkOf(id, name))) end
    W.changed()
    return false
  end
  W.add(id, name)
  if tell then
    say(("watching %s's price: one chat line when it is under %d%% of its usual price.%s"):format(linkOf(id, name),
      W.settings().pct, W.settings().on and "" or " (Price alerts are off: /eah set watchalerts on)"))
  end
  W.changed()
  return true
end

-- The watched items, by name: { { id, name, at } }.
function W.list()
  local out = {}
  for id, e in pairs(W.store() or {}) do
    if type(e) == "table" then
      if not e.name then e.name = nameOf(id) end
      out[#out + 1] = { id = id, name = e.name or ("item " .. id), at = e.at, lvl = e.lvl, lvlAt = e.lvlAt }
    end
  end
  table.sort(out, function(a, b) return tostring(a.name):lower() < tostring(b.name):lower() end)
  return out
end

-- Something changed the list: the settings page and Quick sell follow.
local watchers = {}
function W.onChange(fn) watchers[#watchers + 1] = fn end
function W.changed() for _, fn in ipairs(watchers) do pcall(fn) end end

---------------------------------------------------------------------------------------------------------------------
-- The numbers (no frames: the tests run these offline)

-- The alert level of a price: its share of the usual price in steps of 10% (0.62 -> 6), or nil when it isn't under
-- pct% of it.
function W.level(price, usual, pct)
  if type(price) ~= "number" or type(usual) ~= "number" or usual <= 0 or price <= 0 then return nil end
  local share = price / usual
  if share >= (pct or W.PCT) / 100 then return nil end
  return math.floor(share * 10)
end

-- Whether this level makes an alert, remembered in state (a watch entry): once per level, again only lower; nil (back
-- at its usual price) starts over.
function W.decide(state, lvl, t)
  if not lvl then
    state.lvl, state.lvlAt = nil, nil
    return false
  end
  if state.lvl and lvl >= state.lvl then return false end
  state.lvl, state.lvlAt = lvl, t or now()
  return true
end

-- "Price alert: [Silk Cloth] at 1s 20c, 62% of its usual 1s 95c."
function W.alertText(link, price, usual, need)
  local pct = math.floor(price / usual * 100 + 0.5)
  return ("price alert: %s at %s, %d%% of its usual %s.%s"):format(link, money(price), pct, money(usual),
    need and (" Your crafting queue needs %s."):format(num(need)) or "")
end

-- The usual price of an item (as Deals has it), or nil without 3 days of history.
function W.usual(id)
  local D = ns.deals
  if not (D and D.usualOf and ns.historyDays) then return nil end
  local okU, u = pcall(D.usualOf, ns.historyDays(id), ns.today and ns.today() or nil)
  return okU and u or nil
end

-- What the crafting queue still needs from the auction house (EverlookDB Crafting): { [item ID] = how many }.
local queueCache = { at = -math.huge, needs = {} }
function W.queueNeeds()
  if not W.settings().queue then return {} end
  local t = GetTime and GetTime() or now()
  if t - queueCache.at < W.QUEUE_SECS then return queueCache.needs end
  local needs = {}
  local api = rawget(_G, "EverlookCraftAPI")
  if api and (tonumber(api.version) or 0) >= 8 and type(api.queueMissing) == "function" then
    for _, m in ipairs(try(api.queueMissing) or {}) do
      local id, n = tonumber(m[1]), tonumber(m[2]) or 0
      if id and n > 0 and not m.vendor then needs[id] = n end
    end
  end
  queueCache.at, queueCache.needs = t, needs
  return needs
end
function W.forgetQueue() queueCache.at = -math.huge end

-- Is the item watched (by you or the crafting queue)? Returns its state table and how many the queue needs.
local function stateOf(id)
  local s = W.store()
  if s and s[id] then return s[id], nil end
  local need = W.queueNeeds()[id]
  if not need then return nil end
  local d = db()
  if not d then return nil end
  if type(d.watchSeen) ~= "table" then d.watchSeen = {} end
  local st = d.watchSeen[id]
  if not st then st = {}; d.watchSeen[id] = st end
  return st, need
end

-- For Deals: a function telling whether an item is watched, or nil when alerts are off or nothing is.
function W.dealsFilter()
  local st = W.settings()
  if not st.on then return nil end
  local s = W.store() or {}
  local q = W.queueNeeds()
  if next(s) == nil and next(q) == nil then return nil end
  return function(id) return id ~= nil and (s[id] ~= nil or q[id] ~= nil) end, st.pct
end

W.said = {}   -- the alerts of this session, newest last (for the tests and /eah watch)

-- One item at one price (copper each): says the alert when it is due. Returns the text said, if any.
function W.check(id, price, t)
  id = tonumber(id)
  if not id or not W.settings().on then return nil end
  local state, need = stateOf(id)
  if not state then return nil end
  local usual = W.usual(id)
  if not usual then return nil end
  local lvl = W.level(price, usual, W.settings().pct)
  if not W.decide(state, lvl, t) then return nil end
  local text = W.alertText(linkOf(id, state.name or nameOf(id)), price, usual, need)
  say(text)
  W.said[#W.said + 1] = text
  while #W.said > 20 do table.remove(W.said, 1) end
  return text
end

-- After a price update (or the Price Feed): every watched item at its newest price, when that is fresh.
function W.checkAll(t)
  if not W.settings().on or not ns.itemFor then return end
  t = t or now()
  local ids = {}
  for id in pairs(W.store() or {}) do ids[#ids + 1] = id end
  for id in pairs(W.queueNeeds()) do if not W.has(id) then ids[#ids + 1] = id end end
  for _, id in ipairs(ids) do
    local it = ns.itemFor(id)
    if type(it) == "table" and type(it[1]) == "number" and t - (it[4] or 0) <= W.MAX_AGE then W.check(id, it[1], t) end
  end
end

-- A quick search's answer (ns.noteLivePrice's rows: { unit, qty, mine }): the cheapest that isn't yours.
function W.onLive(id, rows)
  if not id or type(rows) ~= "table" or not W.settings().on then return end
  if not W.has(id) and not W.queueNeeds()[id] then return end
  local low
  for _, r in ipairs(rows) do
    if not r.mine and type(r.unit) == "number" and r.unit > 0 and (not low or r.unit < low) then low = r.unit end
  end
  if low then W.check(id, low) end
end

-- Reads "/eah watch" text: a link, an item ID or a name. Returns the ID and the name.
function W.resolve(text)
  text = tostring(text or ""):match("^%s*(.-)%s*$")
  if text == "" then return nil end
  local id = tonumber(text:match("|Hitem:(%d+)")) or tonumber(text:match("^item:(%d+)")) or tonumber(text:match("^(%d+)$"))
  local name = text:match("|h%[(.-)%]|h")
  if not id then
    name = text:gsub("^%[", ""):gsub("%]$", "")
    id = ns.listImport and ns.listImport.idOf and ns.listImport.idOf(name)
    if not id and C_Item and C_Item.GetItemInfoInstant then id = try(C_Item.GetItemInfoInstant, name) end
  end
  if not id then return nil, name end
  return id, nameOf(id) or name
end

-- The item under the mouse (the game's tooltip), for "/eah watch" on its own.
local function hoveredItem()
  local tt = _G.GameTooltip
  if not (tt and tt.IsShown and tt:IsShown() and tt.GetItem) then return nil end
  local okG, name, link = pcall(tt.GetItem, tt)
  if okG and type(link) == "string" then return tonumber(link:match("item:(%d+)")), name end
end

function W.command(rest, remove)
  local id, name = W.resolve(rest)
  if not id and (rest or ""):match("^%s*$") then id, name = hoveredItem() end
  if not id then
    if (rest or ""):match("%S") then
      say(("couldn't find an item called %s. Shift-click it into the chat line, or use its ID."):format(ns.plain and ns.plain(rest) or rest))
      return
    end
    local list = W.list()
    if #list == 0 then
      say("no watched items. /eah watch <item> (or a shift-clicked link) adds one; Ctrl+right-click in Quick sell too.")
    else
      local names = {}
      for _, e in ipairs(list) do names[#names + 1] = e.name end
      say(("watching %d: %s. /eah unwatch <item> removes one."):format(#list, table.concat(names, ", ")))
    end
    if ns.app then ns.app:Open("pricealerts") end
    return
  end
  if remove then
    if W.remove(id) then say(("stopped watching %s's price."):format(linkOf(id, name))); W.changed()
    else say(("%s isn't watched."):format(linkOf(id, name))) end
    return
  end
  if W.has(id) then
    say(("already watching %s's price. /eah unwatch removes it."):format(linkOf(id, name)))
    return
  end
  W.toggle(id, name, true)
end

---------------------------------------------------------------------------------------------------------------------
-- The Price alerts page of the settings, and the commands (Options.lua calls this)

local page = {}
function W.settingsFor(app, EUI)
  app:Setting({ key = "watchalerts", type = "bool", label = "Price alerts for watched items",
    chatLabel = "Price alerts", keywords = { "watch", "watched", "alert", "alerts", "price", "cheap", "notify", "deal" },
    desc = "One chat line when a watched item is clearly under its usual price, in a price update or a quick search. Once per item and price level.",
    get = function() return W.settings().on end,
    set = function(v) local d = db(); if d then d.watchOff = (not v) or nil end end })
  app:Setting({ key = "watchpct", type = "number", label = "Alert under this share of the usual price (%)", min = 30, max = 95, step = 5,
    keywords = { "watch", "alert", "percent", "usual", "cheap", "median" },
    desc = "80: an alert when a watched item is under 80% of its usual price (the middle of the last 30 days' daily lows).",
    get = function() return W.settings().pct end,
    set = function(v) local d = db(); if d then d.watchPct = tonumber(v) end end })
  app:Setting({ key = "watchqueue", type = "bool", label = "Also for materials my crafting queue still needs",
    chatLabel = "Price alerts for crafting queue materials", keywords = { "watch", "alert", "queue", "crafting", "materials", "reagents", "mats" },
    desc = "The materials EverlookDB Crafting's queue still needs from the auction house count as watched.",
    get = function() return W.settings().queue end,
    set = function(v) local d = db(); if d then d.watchQueue = v and true or false end; W.forgetQueue() end })
  app:Section("pricealerts", "Price alerts", function(stack)
    EUI.Header(stack, "Price alerts", "Watch an item and get one chat line when it is clearly under its usual price, after a price update or a quick search. It is marked \"watched\" in Deals too.")
    app:Widget(stack, "watchalerts")
    app:Widget(stack, "watchpct")
    app:Widget(stack, "watchqueue")
    EUI.Header(stack, "Watched items", "Add one with /eah watch <item> (or a shift-clicked link), or Ctrl+right-click it in Quick sell.")
    page.list = EUI.List(stack, {
      items = function() return W.list() end,
      empty = "Nothing watched yet.",
      rowHeight = 30,
      title = function(e) return e.name end,
      detail = function(e)
        local u = W.usual(e.id)
        local bits = { u and ("usual " .. money(u)) or "no usual price yet" }
        if e.lvlAt then bits[#bits + 1] = "last alert " .. (ns.ago and ns.ago(e.lvlAt) or date("%d %b", e.lvlAt)) end
        return table.concat(bits, "  \194\183  ")
      end,
      icon = function(e) return try(C_Item.GetItemIconByID, e.id) or 134400 end,
      tooltip = function(e, row)
        if ns.itemTooltip then ns.itemTooltip(row, e.id) else
          GameTooltip:SetOwner(row, "ANCHOR_RIGHT"); pcall(GameTooltip.SetItemByID, GameTooltip, e.id); GameTooltip:Show()
        end
      end,
      buttons = { { label = "Remove", width = 80, onClick = function(e) W.remove(e.id); W.changed() end } },
      max = 200,
    })
  end, { icon = "bell" })
  W.onChange(function() if page.list and app:IsShown() then pcall(page.list.Refresh, page.list) end end)
  app:Command("watch", "watch <item>", "price alerts: watch an item (a name, an ID or a shift-clicked link; on its own: the list)", function(rest) W.command(rest) end, { "alert", "alerts" })
  app:Command("unwatch", "unwatch <item>", "stop watching an item's price", function(rest) W.command(rest, true) end)
end

---------------------------------------------------------------------------------------------------------------------
-- When it checks

-- after every quick search that updates an item's price
local prevLive = ns.noteLivePrice
function ns.noteLivePrice(id, rows, ...)
  if prevLive then prevLive(id, rows, ...) end
  pcall(W.onLive, id, rows)
end

-- once Deals has worked its list out from a new scan or the Price Feed
if ns.deals and ns.deals.onChange then
  ns.deals.onChange(function() pcall(W.checkAll) end)
end
