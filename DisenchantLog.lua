-- Disenchanting: a log of every disenchant on every character, your own results on item tooltips, the setting for the
-- materials on the tooltip (drawn by EverlookDBAuctions.lua's disenchant block), the Disenchanting page of the main
-- window (with DisenchantPreview.lua's list of your bags) and /dv.
--
-- The log (a fixed format the EverlookDB App reads; never change it):
--   EverlookDBAuctionsDB.deLog = { { t = <unix time>, item = <item id>, ilvl = <item level>, q = <quality 0-5>,
--     cls = <item class id: 2 weapon, 4 armor>, mats = { [<material item id>] = <count>, ... } }, ... }
--   oldest first, the newest DE_LOG_CAP kept. No character names, GUIDs, realms or zones.
-- Settings live in EverlookAuctionsDB.de: announce, breakdown ("shift", "always", "never": the materials on the
-- tooltip), observed, essenceCap, importedUpTo (the newest disenchant taken over from DisenchantValue's own log,
-- DisenchantValueDB), matsShown (1 once the materials became shown always by default).
--
-- A disenchant is told by its cast: the item clicked while the Disenchant cursor is up (or found in the bags by the
-- name UNIT_SPELLCAST_SENT gives), UNIT_SPELLCAST_SUCCEEDED for Disenchant (13262), then the loot window
-- (LOOT_READY / LOOT_OPENED) within a few seconds. Never the combat log.
-- An older DisenchantValue (before 0.3.0) still loaded draws the breakdown, your results and /dv itself: then this
-- file adds none of them, so there is only one of each.
local ADDON, ns = ...

local D = {}
ns.deLog = D

local DISENCHANT_SPELL = 13262
local LOOT_WINDOW = 5
D.CAP = 5000

local function saved()
  EverlookDBAuctionsDB = type(EverlookDBAuctionsDB) == "table" and EverlookDBAuctionsDB or {}
  if type(EverlookDBAuctionsDB.deLog) ~= "table" then EverlookDBAuctionsDB.deLog = {} end
  return EverlookDBAuctionsDB
end
function D.log() return saved().deLog end

local DEFAULTS = { announce = false, breakdown = "always", observed = true, essenceCap = true }
function D.settings()
  local db = ns.db and ns.db()
  if not db then return DEFAULTS end
  if type(db.de) ~= "table" then db.de = {} end
  -- the materials were behind Shift by default before; the saved default becomes the new one, once
  if db.de.matsShown == nil then
    if db.de.breakdown == "shift" then db.de.breakdown = "always" end
    db.de.matsShown = 1
  end
  for k, v in pairs(DEFAULTS) do if db.de[k] == nil then db.de[k] = v end end
  return db.de
end
local function opt(k) return D.settings()[k] end

-- An older DisenchantValue that still does all of this itself.
function D.oldAddon()
  local dv = rawget(_G, "DisenchantValue")
  return type(dv) == "table" and not dv.merged and dv.ObservedFor ~= nil
end

-- Goes up whenever the log changes, so tooltips keep their sums until then.
D.generation = 0
function D.changed() D.generation = D.generation + 1 end

-- Keeps the newest CAP entries (one shift, not a table.remove per entry).
function D.trim(log)
  log = log or D.log()
  local n = #log
  local over = n - D.CAP
  if over > 0 then
    for i = 1, n - over do log[i] = log[i + over] end
    for i = n - over + 1, n do log[i] = nil end
  end
end

local function matsSig(mats)
  local parts = {}
  for id, n in pairs(mats) do parts[#parts + 1] = id .. "x" .. n end
  table.sort(parts)
  return table.concat(parts, ",")
end

-- Adds one disenchant in the log's format (kept in time order). Returns the entry.
function D.add(e)
  local log = D.log()
  local entry = { t = e.t, item = e.item, ilvl = e.ilvl, q = e.q, cls = e.cls, mats = e.mats }
  local i = #log
  while i > 0 and (log[i].t or 0) > entry.t do i = i - 1 end
  table.insert(log, i + 1, entry)
  D.trim(log)
  D.changed()
  return entry
end

---------------------------------------------------------------------------------------------------------------------
-- Taking over DisenchantValue's log (once per disenchant: everything newer than the newest one taken so far)

local QUALITY_BY_COLOR = { ["9d9d9d"] = 0, ffffff = 1, ["1eff00"] = 2, ["0070dd"] = 3, a335ee = 4, ff8000 = 5 }
local function qualityFromLink(link)
  local c = type(link) == "string" and link:match("|c%x%x(%x%x%x%x%x%x)")
  return c and QUALITY_BY_COLOR[c:lower()]
end

local function cleanMats(mats)
  if type(mats) ~= "table" then return nil end
  local out, any = {}, false
  for id, n in pairs(mats) do
    id, n = tonumber(id), tonumber(n)
    if id and n and id > 0 and n > 0 and id == math.floor(id) then out[id] = math.floor(n); any = true end
  end
  return any and out or nil
end

-- Moves DisenchantValueDB's log into ours: names, realms and links left behind, duplicates (the same item and
-- materials within 5 seconds, from both addons logging the same cast) skipped. Returns how many were added.
function D.import(old)
  old = old or rawget(_G, "DisenchantValueDB")
  if type(old) ~= "table" or type(old.log) ~= "table" then return 0 end
  local s = D.settings()
  local from = tonumber(s.importedUpTo) or 0
  local items = type(old.items) == "table" and old.items or {}
  local log = D.log()
  local seen = {}
  for _, e in ipairs(log) do
    local k = tostring(e.item) .. "|" .. matsSig(e.mats or {})
    seen[k] = seen[k] or {}
    table.insert(seen[k], e.t or 0)
  end
  local added, newest = 0, from
  for _, e in ipairs(old.log) do
    local t, id = tonumber(type(e) == "table" and e.t), tonumber(type(e) == "table" and e.itemID)
    local mats = t and id and t > from and cleanMats(e.mats)
    if mats then
      local info = type(items[id]) == "table" and items[id] or {}
      local q = tonumber(info.quality) or qualityFromLink(e.link)
      local cls = tonumber(info.classID)
      if not cls and C_Item and C_Item.GetItemInfoInstant then
        local okI, _, _, _, _, _, classID = pcall(C_Item.GetItemInfoInstant, id)
        cls = okI and classID or nil
      end
      local ilvl = tonumber(e.ilvl) or tonumber(info.ilvl)
      if ns.deCanDisenchant(cls, q) and ilvl then
        local k = id .. "|" .. matsSig(mats)
        local dup = false
        for _, at in ipairs(seen[k] or {}) do if math.abs(at - t) <= 5 then dup = true break end end
        if not dup then
          local log2 = D.log()
          log2[#log2 + 1] = { t = t, item = id, ilvl = ilvl, q = q, cls = cls, mats = mats }
          seen[k] = seen[k] or {}
          table.insert(seen[k], t)
          added = added + 1
        end
      end
      if t > newest then newest = t end
    end
  end
  if added > 0 then
    table.sort(log, function(a, b) return (a.t or 0) < (b.t or 0) end)
    D.trim(log)
    D.changed()
  end
  s.importedUpTo = newest
  return added
end

---------------------------------------------------------------------------------------------------------------------
-- Telling a disenchant

local pending, awaitingLoot

local function spellName(id)
  if C_Spell and C_Spell.GetSpellName then return C_Spell.GetSpellName(id) end
  if GetSpellInfo then return (GetSpellInfo(id)) end
end
local function isDisenchant(spellID)
  if spellID == DISENCHANT_SPELL then return true end
  local name = spellID and spellName(spellID)
  return name ~= nil and name == spellName(DISENCHANT_SPELL)
end

local function itemLevel(link)
  local f = (C_Item and C_Item.GetDetailedItemLevelInfo) or GetDetailedItemLevelInfo
  local okL, l = pcall(f, link)
  return okL and tonumber(l) or nil
end

-- What we know of an item: the class from GetItemInfoInstant (always there), the quality from the link's colour
-- while the item isn't cached.
local function describe(link)
  if type(link) ~= "string" then return nil end
  local itemID, _, _, _, _, instantClass = C_Item.GetItemInfoInstant(link)
  local name, _, quality, _, _, _, _, _, _, _, _, classID = C_Item.GetItemInfo(link)
  return { link = link, item = itemID, name = name or link:match("|h%[(.-)%]|h"),
    q = quality or qualityFromLink(link), cls = classID or instantClass, ilvl = itemLevel(link) }
end
D.describe = describe

-- Unknown (nil) counts as possible until the loot window.
local function mayDisenchant(it)
  if it.cls ~= nil and it.cls ~= 2 and it.cls ~= 4 then return false end
  if it.q ~= nil and (it.q < 2 or it.q > 4) then return false end
  return true
end

local function findInBags(itemName)
  if not itemName or itemName == "" then return nil end
  for bag = 0, (NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4) do
    for slot = 1, (C_Container.GetContainerNumSlots(bag) or 0) do
      local link = C_Container.GetContainerItemLink(bag, slot)
      if link and C_Item.GetItemInfo(link) == itemName then return link end
    end
  end
end

-- "3x Strange Dust, 1x Lesser Magic Essence"
function D.matsText(mats)
  local parts = {}
  for id, n in pairs(mats or {}) do parts[#parts + 1] = n .. "x " .. ns.deMatName(id) end
  table.sort(parts)
  return table.concat(parts, ", ")
end

local function record(it, mats)
  local fresh = describe(it.link)
  if fresh then for k, v in pairs(fresh) do if it[k] == nil then it[k] = v end end end
  -- a crate or bag opened right after the cast is no disenchant
  if not (it.item and it.ilvl and ns.deCanDisenchant(it.cls, it.q)) then return end
  D.add({ t = time(), item = it.item, ilvl = it.ilvl, q = it.q, cls = it.cls, mats = mats })
  if opt("announce") == true and ns.say then ns.say(it.link .. " -> " .. D.matsText(mats)) end
end

local function readLoot()
  if not awaitingLoot or GetTime() - awaitingLoot.at > LOOT_WINDOW then awaitingLoot = nil; return end
  local it = awaitingLoot.item
  awaitingLoot = nil
  local mats = {}
  for i = 1, GetNumLootItems() do
    local link = GetLootSlotLink(i)
    local id = link and C_Item.GetItemInfoInstant(link)
    if id then
      local _, _, quantity = GetLootSlotInfo(i)
      mats[id] = (mats[id] or 0) + (quantity or 1)
    end
  end
  if next(mats) then record(it, mats) end
end

if C_Container and C_Container.UseContainerItem and hooksecurefunc then
  hooksecurefunc(C_Container, "UseContainerItem", function(bag, slot)
    if SpellIsTargeting and SpellIsTargeting() then
      local it = describe(C_Container.GetContainerItemLink(bag, slot))
      pending = it and mayDisenchant(it) and it or nil
    end
  end)
end

---------------------------------------------------------------------------------------------------------------------
-- Your results: sums over the log per item and per class:quality:item level, kept until the log changes

local index
local function addTo(out, e)
  out.count = out.count + 1
  for id, n in pairs(e.mats or {}) do
    local m = out.mats[id] or { total = 0, hits = 0 }
    m.total, m.hits = m.total + n, m.hits + 1
    out.mats[id] = m
  end
end
local function merge(out, agg)
  out.count = out.count + agg.count
  for id, m in pairs(agg.mats) do
    local o = out.mats[id] or { total = 0, hits = 0 }
    o.total, o.hits = o.total + m.total, o.hits + m.hits
    out.mats[id] = o
  end
end
local function getIndex()
  if index and index.generation == D.generation then return index end
  index = { generation = D.generation, items = {}, kinds = {} }
  for _, e in ipairs(D.log()) do
    if e.item then
      index.items[e.item] = index.items[e.item] or { count = 0, mats = {} }
      addTo(index.items[e.item], e)
    end
    if e.cls and e.q and e.ilvl then
      local k = e.cls .. ":" .. e.q .. ":" .. e.ilvl
      index.kinds[k] = index.kinds[k] or { count = 0, mats = {} }
      addTo(index.kinds[k], e)
    end
  end
  return index
end

-- This item's results and its class / quality / item-level bracket's (low..high): { count, mats = { [id] = { total,
-- hits } } } each, or nil when there are none.
function D.observed(id, cls, q, low, high)
  local idx = getIndex()
  local mine = idx.items[id]
  local bracket
  if low and cls and q then
    bracket = { count = 0, mats = {} }
    for l = low, high do
      local k = idx.kinds[cls .. ":" .. q .. ":" .. l]
      if k then merge(bracket, k) end
    end
    if bracket.count == 0 then bracket = nil end
  end
  return mine, bracket
end

-- Totals: disenchants, different items.
function D.summary()
  local n, items = 0, 0
  for _ in pairs(getIndex().items) do items = items + 1 end
  n = #D.log()
  return n, items
end

---------------------------------------------------------------------------------------------------------------------
-- Tooltips

local Tip = LibStub and LibStub("EverlookTooltip-1", true)

local function showBreakdown()
  local mode = opt("breakdown")
  return mode == "always" or (mode == "shift" and IsShiftKeyDown and IsShiftKeyDown())
end
D.showBreakdown = showBreakdown

local function tipOn() return not ns.tipOn or ns.tipOn("disenchant") end

-- Whether the tooltip lists what an item disenchants into (else one "Disenchant" line). An older DisenchantValue still
-- loaded draws its own breakdown.
function D.showMaterials() return showBreakdown() and not D.oldAddon() end

local function observedLine(t, which, obs)
  local value, missing = 0, false
  for id, m in pairs(obs.mats) do
    local price = ns.deMatPrice and ns.deMatPrice(id)
    if price then value = value + price * m.total / obs.count else missing = true end
  end
  local note = Tip.Join(which, obs.count .. (obs.count == 1 and " disenchant" or " disenchants"), missing and value > 0 and "partial" or nil)
  if value > 0 then
    t:Line("Your disenchants", Tip.Money(math.floor(value + 0.5), { approx = true }), { note = note })
  else
    t:Line("Your disenchants", "no prices", { note = note, stale = true })
  end
  -- what you got, each material: behind Shift (the materials of the odds above already show by default)
  if opt("breakdown") ~= "never" and IsShiftKeyDown and IsShiftKeyDown() then
    local rows = {}
    for id, m in pairs(obs.mats) do
      rows[#rows + 1] = { ("%d%%  %s"):format(math.floor(m.hits / obs.count * 100 + 0.5), ns.deMatName(id)),
        ("%.1f each time"):format(m.total / m.hits), hits = m.hits }
    end
    table.sort(rows, function(a, b) return a.hits > b.hits end)
    t:List(rows, { always = true, max = 6 })
  end
end

-- The item behind a tooltip, as the bracket needs it: cls, q, ilvl.
local function itemInfo(ctx)
  local okI, _, _, q, baseLevel, _, _, _, _, _, _, _, cls = pcall(C_Item.GetItemInfo, ctx.link or ctx.id)
  if not okI or not ns.deCanDisenchant(cls, q) then return nil end
  local ilvl = (ctx.link and itemLevel(ctx.link)) or baseLevel
  return cls, q, ilvl
end

local function addObserved(t, ctx)
  if not ctx.id or not tipOn() or D.oldAddon() or opt("observed") == false then return end
  local cls, q, ilvl = itemInfo(ctx)
  if not cls then return end
  local low, high = ns.deBracket(cls, q, ilvl)
  local mine, bracket = D.observed(ctx.id, cls, q, low, high)
  if mine then observedLine(t, "this item", mine) end
  if bracket and (not mine or bracket.count > mine.count) then
    observedLine(t, ("item level %d-%d"):format(low, high), bracket)
  end
end

if Tip then
  Tip:Register({ id = "EverlookDBAuctions.disenchantOwn", kind = "item", order = Tip.ORDER.disenchantOwn, add = addObserved })
end

---------------------------------------------------------------------------------------------------------------------
-- Settings, the Disenchanting page and /dv

-- The newest n entries, newest first, that match the words (item or material names); all with no words.
function D.recent(n, words)
  local log, out = D.log(), {}
  words = tostring(words or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
  for i = #log, 1, -1 do
    local e = log[i]
    local ok = words == ""
    if not ok then
      local okN, name = pcall(C_Item.GetItemInfo, e.item)
      local hay = ((okN and name) or ("item " .. tostring(e.item))) .. " " .. D.matsText(e.mats)
      ok = hay:lower():find(words, 1, true) ~= nil
    end
    if ok then
      out[#out + 1] = e
      if #out >= n then break end
    end
  end
  return out
end

local function itemText(id)
  local okN, name, link = pcall(C_Item.GetItemInfo, id)
  return (okN and (link or name)) or ("item " .. tostring(id))
end

-- Where the odds on tooltips come from.
function D.oddsLine()
  local o = ns.deOddsTable and ns.deOddsTable()
  if not o then return "Odds measured in vanilla, else estimates. The Price Feed (from the EverlookDB App) brings players' disenchants" end
  local n = 0
  for _ in pairs(type(o.items) == "table" and o.items or {}) do n = n + 1 end
  local at = tonumber(o.updated)
  return ("Players' disenchants (%d items%s), odds measured in vanilla where there are too few"):format(n,
    at and (", updated " .. date("%Y-%m-%d", at)) or "")
end

function D.summaryLine()
  local n, items = D.summary()
  return ("%d %s logged, %d different %s"):format(n, n == 1 and "disenchant" or "disenchants", items, items == 1 and "item" or "items")
end

function D.printRecent()
  local list = D.recent(10)
  if #list == 0 then ns.say("no disenchants logged yet.") return end
  for i = #list, 1, -1 do
    local e = list[i]
    print(("  %s  %s -> %s"):format(date("%m-%d %H:%M", e.t), itemText(e.item), D.matsText(e.mats)))
  end
end

function D.settingsFor(app, UI)
  local function s() return D.settings() end
  app:Setting({
    key = "debreakdown", type = "choice", label = "What an item disenchants into, on its tooltip", width = 200,
    chatLabel = "Disenchant materials", keywords = { "disenchant", "breakdown", "materials", "mats", "shift", "detail", "preview", "dust", "essence", "shard" },
    desc = "Each material with its count, chance and worth, then the disenchant value. Otherwise one line with the value.",
    choices = { { value = "shift", text = "While Shift is held" }, { value = "always", text = "Always" }, { value = "never", text = "Never" } },
    get = function() return s().breakdown end,
    set = function(v) if v == "shift" or v == "always" or v == "never" then s().breakdown = v end end,
    disabled = function() return not tipOn() end,
  })
  app:Setting({
    key = "deobserved", type = "bool", label = "Your own disenchant results on tooltips", chatLabel = "Your disenchant results",
    keywords = { "disenchant", "history", "observed", "my results", "log" },
    desc = "What your characters actually got from this item, and from items of its kind and item level.",
    get = function() return s().observed ~= false end, set = function(v) s().observed = v end,
    disabled = function() return not tipOn() end,
  })
  app:Setting({
    key = "deessencecap", type = "bool", label = "Price lesser essences at a third of a greater one at most",
    chatLabel = "Lesser essence price cap", keywords = { "disenchant", "essence", "cap", "combine" },
    desc = "Three lesser essences combine into one greater, so a lesser one is never worth more than a third of it.",
    get = function() return s().essenceCap ~= false end, set = function(v) s().essenceCap = v end,
  })
  app:Setting({
    key = "deannounce", type = "bool", label = "Chat line after each disenchant", chatLabel = "Disenchant chat line",
    keywords = { "disenchant", "announce", "message", "chat", "quiet" },
    get = function() return s().announce == true end, set = function(v) s().announce = v end,
  })
  app:Section("disenchanting", "Disenchanting", function(stack)
    UI.Header(stack, "Disenchanting", "The \"Disenchant\" line on item tooltips and the log of every disenchant you do.")
    if app:GetSetting("tipdisenchant") then app:Widget(stack, "tipdisenchant") end
    app:Widget(stack, "debreakdown")
    app:Widget(stack, "deobserved")
    app:Widget(stack, "deessencecap")
    app:Widget(stack, "deannounce")
    UI.ButtonRow(stack, {
      { label = "Forget every disenchant", width = 220, confirm = true, onClick = function()
        local log = D.log()
        for i = #log, 1, -1 do log[i] = nil end
        D.changed()
        app:Refresh()
        ns.say("the disenchant log is empty.")
      end, desc = "Empties the log of every character. Can't be undone.",
      keywords = { "reset", "clear", "delete", "wipe", "disenchant", "history" } },
    })
  end, { icon = "sparkle" })
  -- /eah de: the page; /eah de recent, /eah de status
  app:Command("de", "de [recent|status]", "the Disenchanting page: what your bags disenchant into (also /dv)", function(rest)
    rest = (rest or ""):lower()
    if rest:match("^recent") then D.printRecent()
    elseif rest:match("^status") or rest:match("^summary") then
      ns.say(D.summaryLine() .. ".")
      ns.say("Odds: " .. D.oddsLine() .. ".")
    elseif ns.hub then ns.hub.open("disenchant") end
  end, { "disenchant", "dv" })
end

-- The Disenchanting page of the main window: overview, recent disenchants and a search over them.
function D.page(app, UI)
  local filter = ""
  app:Section("disenchant", "Disenchanting", function(stack)
    UI.Header(stack, "Disenchanting", "What your disenchants are worth, and what every character of yours has got.")
    UI.Stat(stack, "Logged", D.summaryLine)
    UI.Stat(stack, "Odds", D.oddsLine)
    UI.Stat(stack, "Latest", function()
      local log = D.log()
      local e = log[#log]
      return e and (date("%Y-%m-%d %H:%M", e.t) .. "  " .. itemText(e.item)) or "nothing yet"
    end)
    UI.Note(stack, "Every disenchant on every character goes into one log. Item tooltips then show what you actually got, for that item and for items of its kind and item level.")
    if ns.dePreview then ns.dePreview.build(stack, app, UI) end
    UI.Header(stack, "Recent disenchants", "Newest first. Hover one for the item.")
    local list
    UI.Input(stack, { placeholder = "Search by item or material", width = 320,
      onChange = function(text) filter = text or ""; if list then list:Refresh() end end })
    list = UI.List(stack, {
      items = function() return D.recent(100, filter) end,
      empty = "Nothing logged yet. Disenchant something!",
      rowHeight = 40,
      title = function(e) return itemText(e.item) end,
      detail = function(e) return ("%s  \194\183  item level %s  \194\183  %s"):format(date("%Y-%m-%d %H:%M", e.t), tostring(e.ilvl), D.matsText(e.mats)) end,
      tooltip = function(e, row)
        GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
        GameTooltip:SetHyperlink("item:" .. e.item)
        GameTooltip:Show()
      end,
      max = 100,
    })
  end, { group = "main", icon = "sparkle" })
end

-- /dv: DisenchantValue's command, now the Disenchanting page. Its setting names still work (/dv announce off).
local DV_KEYS = { tooltip = "tipdisenchant", breakdown = "debreakdown", observed = "deobserved",
  essencecap = "deessencecap", announce = "deannounce" }
function D.slash(msg)
  msg = tostring(msg or ""):gsub("^%s+", ""):gsub("%s+$", "")
  local w = msg:match("^(%S*)"):lower()
  if msg == "" then if ns.hub then ns.hub.open("disenchant") end return "page" end
  if w == "recent" then D.printRecent() return "recent" end
  if w == "status" or w == "summary" then
    ns.say(D.summaryLine() .. ".")
    ns.say("Odds: " .. D.oddsLine() .. ".")
    return "status"
  end
  if w == "quiet" then
    local s = D.settings()
    s.announce = not (s.announce == true)
    ns.say("chat line after each disenchant " .. (s.announce and "on" or "off"))
    return "quiet"
  end
  local out = {}
  for word in msg:gmatch("%S+") do out[#out + 1] = DV_KEYS[word:lower()] or word end
  if ns.app then ns.app:HandleSlash(table.concat(out, " ")) end
  return "eah"
end

---------------------------------------------------------------------------------------------------------------------
-- Events

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("UNIT_SPELLCAST_SENT")
f:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
f:RegisterEvent("UNIT_SPELLCAST_FAILED")
f:RegisterEvent("UNIT_SPELLCAST_INTERRUPTED")
f:RegisterEvent("LOOT_READY")
f:RegisterEvent("LOOT_OPENED")
f:SetScript("OnEvent", function(_, event, unit, ...)
  if event == "PLAYER_LOGIN" then
    saved()
    D.trim()
    pcall(D.import)
    D.changed()
    -- /dv, unless an older DisenchantValue still answers it
    if not D.oldAddon() and SlashCmdList then
      SLASH_EVERLOOKDBDV1 = "/dv"
      SlashCmdList.EVERLOOKDBDV = D.slash
    end
    return
  end
  if event == "LOOT_READY" or event == "LOOT_OPENED" then readLoot() return end
  if unit ~= "player" then return end
  if event == "UNIT_SPELLCAST_SENT" then
    local target, _, spellID = ...
    if isDisenchant(spellID) then
      local fromBags = findInBags(target)
      if not pending or (fromBags and pending.name ~= target) then pending = describe(fromBags) end
    end
  elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
    local _, spellID = ...
    if isDisenchant(spellID) and pending and pending.item then
      awaitingLoot = { item = pending, at = GetTime() }
      pending = nil
    end
  else
    local _, spellID = ...
    if isDisenchant(spellID) then pending = nil end
  end
end)
