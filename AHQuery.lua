-- EverlookDB Auctions: one queue for every auction house search the addon sends (the full scan, ReplicateItems, is
-- a separate system and stays out of it).
--
-- The auction house answers one search at a time and drops or delays searches sent while it is busy. So:
--   * one search in flight, sent only when IsThrottledMessageSystemReady says so;
--   * an answer only counts when it is for the search in flight (item results for the same ItemKey; browse results
--     while our browse is out). Anything else is ignored, never read as "nothing for sale";
--   * no answer in time is "no answer": it is asked again (after 1, 2, 4 s), and after that the caller hears
--     "no answer", never zero;
--   * "nobody is selling" is only believed from a complete answer (HasFull...Results) to the same search Blizzard's
--     own Search button sends: a browse by name. The ItemKeys come from that browse, never built by hand: random-stat
--     gear has one ItemKey per suffix ("Dwarven Magestaff of the Bear"), and a hand-made key finds nothing;
--   * our background searches (live prices) wait while the buy panel is open or Blizzard's own search is running.

local _, ns = ...

local Q = { list = {}, busy = nil, pausedUntil = 0, waiters = {} }
ns.ahq = Q

local TIMEOUT = 5          -- seconds to wait for an answer
local BACKOFF = { 1, 2, 4 } -- seconds before asking again
local MAX_TRIES = 3
local MAX_PAGES = 8        -- "more results" requests per search
local BLIZZARD_PAUSE = 6   -- longest wait for Blizzard's own search to be answered

local function AH() return C_AuctionHouse or {} end
local function now() return GetTime() end
local function okv(v) if ns.ok then return ns.ok(v) end return v end

local function call(name, ...)
  local f = AH()[name]
  if type(f) ~= "function" then return nil end
  local okCall, a, b = pcall(f, ...)
  if okCall then return a, b end
end

local function ready()
  local f = AH().IsThrottledMessageSystemReady
  if type(f) ~= "function" then return true end
  local okCall, r = pcall(f)
  return not okCall or r ~= false
end

local function sortOrder(name, fallback)
  return Enum and Enum.AuctionHouseSortOrder and Enum.AuctionHouseSortOrder[name] or fallback
end
-- what Blizzard's browse sends: by price, then name; item searches: by price
local function browseSorts()
  return { { sortOrder = sortOrder("Price", 0), reverseSort = false }, { sortOrder = sortOrder("Name", 1), reverseSort = false } }
end
local function itemSorts() return { { sortOrder = sortOrder("Price", 0), reverseSort = false } } end

function Q.sameKey(a, b)
  if type(a) ~= "table" or type(b) ~= "table" then return false end
  return a.itemID == b.itemID and (a.itemLevel or 0) == (b.itemLevel or 0) and (a.itemSuffix or 0) == (b.itemSuffix or 0)
    and (a.battlePetSpeciesID or 0) == (b.battlePetSpeciesID or 0)
end

function Q.keyText(k)
  if type(k) ~= "table" then return "none" end
  return ("item %s level %s suffix %s"):format(tostring(k.itemID), tostring(k.itemLevel or 0), tostring(k.itemSuffix or 0))
end

-- The name the game gives an ItemKey ("Dwarven Magestaff of the Bear"), or nil while it isn't loaded.
function Q.nameOf(key)
  local info = call("GetItemKeyInfo", key)
  return info and okv(info.itemName) or nil
end

---------------------------------------------------------------------------------------------------------------------
-- The queue

local pumpQueued
local function later(secs)
  if pumpQueued then return end
  pumpQueued = true
  C_Timer.After(secs, function() pumpQueued = false; Q.pump() end)
end

local function allowed(job)
  return not (job.background and (ns.buyOpen or Q.blizzard))
end

-- front: ahead of background searches (after other front ones, so they keep their order)
function Q.add(job, front)
  job.tries = job.tries or 0
  job.front = front and true or nil
  if front then
    local at = 1
    while Q.list[at] and Q.list[at].front do at = at + 1 end
    table.insert(Q.list, at, job)
  else
    Q.list[#Q.list + 1] = job
  end
  Q.pump()
  return job
end

-- Drops an owner's waiting searches. One already sent is still waited for (one at a time), then its answer dropped.
function Q.cancel(owner)
  for i = #Q.list, 1, -1 do
    if Q.list[i].owner == owner then Q.list[i].cancelled = true; table.remove(Q.list, i) end
  end
  if Q.busy and Q.busy.owner == owner then Q.busy.cancelled = true end
end

-- Runs fn once nothing of ours is in flight and the auction house takes searches (before any queued search).
function Q.whenIdle(fn)
  Q.waiters[#Q.waiters + 1] = fn
  Q.pump()
end

local function finish(job)
  if Q.busy == job then Q.busy = nil end
  job.token = nil
  later(0.05)
end

local function startTimer(job)
  local token = {}
  job.token = token
  C_Timer.After(job.timeout or TIMEOUT, function()
    if Q.busy == job and job.token == token then Q.noAnswer(job) end
  end)
end

-- No answer (or a failure): ask again after a pause; after MAX_TRIES tell the caller "no answer".
function Q.noAnswer(job)
  finish(job)
  if job.cancelled then return end
  if job.tries < MAX_TRIES then
    if job.onRetry then job.onRetry(job.tries) end
    C_Timer.After(BACKOFF[job.tries] or BACKOFF[#BACKOFF], function()
      if job.cancelled then return end
      if job.reset then job.reset() end
      Q.add(job, job.front)
    end)
  elseif job.onFail then
    job.onFail("noanswer")
  end
end

local function again(job)
  finish(job)
  job.tries = job.tries - 1
  if job.reset then job.reset() end
  Q.add(job, true)
end

function Q.pump()
  if Q.busy then return end
  if Q.blizzard and now() >= (Q.blizzardUntil or 0) then Q.blizzard = nil end
  local pending = #Q.list > 0 or #Q.waiters > 0
  if not pending then return end
  if not ready() or now() < Q.pausedUntil or (ns.sellBusy and ns.sellBusy()) then
    later(0.3)
    return
  end
  if #Q.waiters > 0 then
    local fn = table.remove(Q.waiters, 1)
    fn()
    later(0.3)
    return
  end
  local pick
  for i, job in ipairs(Q.list) do
    if allowed(job) then pick = table.remove(Q.list, i); break end
  end
  if not pick then later(0.5); return end   -- only background searches waiting, and they must wait
  pick.tries = pick.tries + 1
  Q.busy = pick
  Q.sentAt = now()
  local okSend = pcall(pick.send)
  if not okSend then Q.noAnswer(pick); return end
  startTimer(pick)
end

-- Every auction house search event comes through here.
function Q.onEvent(e, ...)
  if e == "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED" or e == "AUCTION_HOUSE_BROWSE_RESULTS_ADDED"
      or e == "AUCTION_HOUSE_BROWSE_FAILURE" then
    Q.lastBrowseEvent = now()
    if Q.blizzard then
      -- the answer to Blizzard's own search: theirs, not ours
      Q.blizzard = nil
      Q.pausedUntil = now() + 0.5
      later(0.6)
      return
    end
  end
  local job = Q.busy
  if not job or not job.handles(e, ...) then return end   -- not the answer to our search: ignored
  if job.cancelled then finish(job); return end
  local r = job.onEvent(e, ...)
  if r == true then finish(job)
  elseif r == "again" then again(job)
  elseif r == "fail" then Q.noAnswer(job)
  else startTimer(job) end   -- asked for more: wait again
end

-- Blizzard's own search started: our browse in flight would be mixed up with theirs, so it goes back in the queue,
-- and background searches wait until theirs is answered.
function Q.blizzardSearch(isBrowse)
  Q.blizzardUntil = now() + (isBrowse and BLIZZARD_PAUSE or 2)
  Q.pausedUntil = math.max(Q.pausedUntil, Q.blizzardUntil)
  if isBrowse then Q.blizzard = true end
  local job = Q.busy
  if isBrowse and job and job.kind == "browse" then
    Q.busy, job.token = nil, nil
    job.tries = job.tries - 1
    if not job.cancelled then
      if job.reset then job.reset() end
      table.insert(Q.list, 1, job)
    end
  end
  later(0.3)
end

---------------------------------------------------------------------------------------------------------------------
-- Searches

-- A browse by name, as Blizzard's Search button sends it, keeping the rows of item `id`.
-- cb({ ok = true, full = all pages came, entries = { { itemKey, minPrice, totalQuantity } } }) or cb({ ok = false }).
-- opts: owner, front, background, confirmEmpty (ask once more before believing "none"), onRetry.
function Q.browse(text, id, opts, cb)
  opts = opts or {}
  local job = { kind = "browse", owner = opts.owner, background = opts.background, onRetry = opts.onRetry,
    what = ('browse "%s" for item %s'):format(tostring(text), tostring(id)) }
  local entries, pages
  function job.reset() entries, pages = {}, 0 end
  job.reset()
  function job.send()
    AH().SendBrowseQuery({ searchString = text, minLevel = 0, maxLevel = 0, filters = {}, sorts = browseSorts() })
  end
  function job.handles(e)
    return e == "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED" or e == "AUCTION_HOUSE_BROWSE_RESULTS_ADDED"
      or e == "AUCTION_HOUSE_BROWSE_FAILURE"
  end
  function job.onEvent(e, added)
    if e == "AUCTION_HOUSE_BROWSE_FAILURE" then return "fail" end
    local list
    if e == "AUCTION_HOUSE_BROWSE_RESULTS_ADDED" and type(added) == "table" then
      list = added
    else
      list = call("GetBrowseResults") or {}
      entries = {}
    end
    for _, r in ipairs(list) do
      local key = r.itemKey
      if type(key) == "table" and okv(key.itemID) == id then
        entries[#entries + 1] = { itemKey = key, minPrice = okv(r.minPrice), totalQuantity = okv(r.totalQuantity) }
      end
    end
    local full = call("HasFullBrowseResults") == true
    if not full and pages < MAX_PAGES then
      pages = pages + 1
      call("RequestMoreBrowseResults")
      return false
    end
    if #entries == 0 and full and opts.confirmEmpty and not job.confirmed then
      job.confirmed = true
      return "again"
    end
    Q.lastBrowse = { text = text, id = id, full = full, n = #entries }
    cb({ ok = true, full = full, entries = entries })
    return true
  end
  function job.onFail() cb({ ok = false }) end
  return Q.add(job, opts.front)
end

-- The auctions of one ItemKey (from a browse). cb(key, full, final) each time results arrive; read them with
-- GetNumItemSearchResults(key) / GetNumCommoditySearchResults(key.itemID). opts: owner, front, commodity,
-- onRetry, onFail.
function Q.items(key, opts, cb)
  opts = opts or {}
  local job = { kind = "items", owner = opts.owner, background = opts.background, onRetry = opts.onRetry,
    what = (opts.commodity and "commodity " or "items ") .. Q.keyText(key) }
  local pages
  function job.reset() pages = 0 end
  job.reset()
  function job.send() AH().SendSearchQuery(key, itemSorts(), true) end
  function job.handles(e, arg)
    if opts.commodity then
      return (e == "COMMODITY_SEARCH_RESULTS_UPDATED" or e == "COMMODITY_SEARCH_RESULTS_ADDED") and arg == key.itemID
    end
    return (e == "ITEM_SEARCH_RESULTS_UPDATED" or e == "ITEM_SEARCH_RESULTS_ADDED") and Q.sameKey(arg, key)
  end
  function job.onEvent()
    local full
    if opts.commodity then full = call("HasFullCommoditySearchResults", key.itemID) == true
    else full = call("HasFullItemSearchResults", key) == true end
    if not full and pages < MAX_PAGES then
      pages = pages + 1
      if opts.commodity then call("RequestMoreCommoditySearchResults", key.itemID)
      else call("RequestMoreItemSearchResults", key) end
      cb(key, false, false)
      return false
    end
    cb(key, full, true)
    return true
  end
  function job.onFail(why) if opts.onFail then opts.onFail(why) end end
  return Q.add(job, opts.front)
end

---------------------------------------------------------------------------------------------------------------------
-- Reading answers (no game calls: the offline tests use these directly)

-- Which of an item's ItemKeys to open for a result named wantName: the ones the game names the same, else all of
-- them (then showAll is true and the panel names each auction's version).
function Q.pickKeys(entries, wantName, nameOf)
  local all, match = {}, {}
  local want = wantName and wantName:lower()
  for _, e in ipairs(entries or {}) do
    all[#all + 1] = e.itemKey
    local n = nameOf(e.itemKey)
    if want and n and n:lower() == want then match[#match + 1] = e.itemKey end
  end
  if #match > 0 then return match, false end
  return all, #all > 1
end

-- Live prices for the result rows of one item ({ name, suffix }) from a browse answer: per row { price, qty },
-- { gone = true } (nobody sells it: only from a complete answer that can tell the versions apart), or nil (can't
-- tell; the row keeps its scan price).
function Q.liveFromBrowse(rows, answer, nameOf)
  local out = {}
  if not answer or not answer.ok then return out end
  local entries = answer.entries or {}
  if #entries == 0 then
    if answer.full then for i in ipairs(rows) do out[i] = { gone = true } end end
    return out
  end
  local function add(acc, e)
    acc = acc or { qty = 0 }
    if e.minPrice and e.minPrice > 0 and (not acc.price or e.minPrice < acc.price) then acc.price = e.minPrice end
    acc.qty = acc.qty + (e.totalQuantity or 0)
    return acc
  end
  local versions = false
  for _, r in ipairs(rows) do if (r.suffix or 0) ~= 0 then versions = true end end
  if not versions then
    local acc
    for _, e in ipairs(entries) do acc = add(acc, e) end
    for i in ipairs(rows) do out[i] = acc end
    return out
  end
  local byName, allNamed = {}, true
  for _, e in ipairs(entries) do
    local n = nameOf(e.itemKey)
    if n then n = n:lower(); byName[n] = add(byName[n], e) else allNamed = false end
  end
  for i, r in ipairs(rows) do
    local hit = r.name and byName[r.name:lower()]
    if hit then out[i] = hit
    elseif allNamed and answer.full then out[i] = { gone = true } end
  end
  return out
end

---------------------------------------------------------------------------------------------------------------------
-- Blizzard's list

-- Shows a name in Blizzard's own search: closes our panels, waits until the auction house takes searches and none
-- of ours is out, then does what pressing Blizzard's Search does (SearchBar:StartSearch). Asks once more when no
-- answer comes. Our panel's closing used to fire a live-price search in the same frame, so Blizzard's search went
-- out while the auction house was busy and came back "No items found".
function Q.showInBlizzard(name)
  if ns.closeBuy then ns.closeBuy() end
  if ns.closeSearch then ns.closeSearch() end
  Q.cancel("buy")
  Q.cancel("live")
  local bar = _G.AuctionHouseFrame and AuctionHouseFrame.SearchBar
  if not bar or not name then return end
  bar:SetSearchText(name)
  Q.whenIdle(function()
    -- a category picked on the left would limit the search to it ("No items found" for a sword under Consumables)
    local cats = AuctionHouseFrame.GetCategoriesList and AuctionHouseFrame:GetCategoriesList()
    if cats and cats.GetSelectedCategory and cats:GetSelectedCategory() and cats.SetSelectedCategory then
      pcall(cats.SetSelectedCategory, cats, nil)
    end
    local sentAt = now()
    bar:SetSearchText(name)
    bar:StartSearch()
    C_Timer.After(3, function()
      if (Q.lastBrowseEvent or 0) < sentAt and AuctionHouseFrame:IsShown() then
        bar:SetSearchText(name)
        bar:StartSearch()
      end
    end)
  end)
end

---------------------------------------------------------------------------------------------------------------------
-- /eah debug

function Q.debugLines()
  local out = {}
  out[#out + 1] = ("search queue: %s in flight, %d waiting%s%s"):format(Q.busy and Q.busy.what or "nothing", #Q.list,
    Q.blizzard and ", Blizzard's search running" or "", now() < Q.pausedUntil and ", paused" or "")
  for i, job in ipairs(Q.list) do
    if i > 5 then out[#out + 1] = "    ..."; break end
    out[#out + 1] = ("    %d. %s%s"):format(i, job.what or "?", job.background and " (background)" or "")
  end
  if Q.lastBrowse then
    local b = Q.lastBrowse
    out[#out + 1] = ('last browse: "%s" item %s: %d rows%s'):format(b.text, tostring(b.id), b.n, b.full and "" or " (incomplete)")
  end
  if ns.buyKeys then
    local keys, showAll = ns.buyKeys()
    if keys then
      out[#out + 1] = ("buy panel ItemKeys%s:"):format(showAll and " (every version)" or "")
      for _, k in ipairs(keys) do out[#out + 1] = ("    %s  %s"):format(Q.keyText(k), tostring(Q.nameOf(k) or "?")) end
    else
      out[#out + 1] = "buy panel ItemKeys: none yet"
    end
  end
  return out
end

---------------------------------------------------------------------------------------------------------------------
-- Events

local hooked
local function hook()
  local ah = _G.AuctionHouseFrame
  if hooked or not ah then return end
  hooked = true
  if ah.SendBrowseQueryInternal then hooksecurefunc(ah, "SendBrowseQueryInternal", function() Q.blizzardSearch(true) end) end
  if ah.QueryItem then hooksecurefunc(ah, "QueryItem", function() Q.blizzardSearch(false) end) end
  -- the favourites star (and opening the auction house with favourites) sends a browse that isn't a
  -- SendBrowseQueryInternal; its answer is a browse answer too and must not be read as ours
  if ah.QueryAll then
    hooksecurefunc(ah, "QueryAll", function(_, context)
      local fav = _G.AuctionHouseSearchContext and AuctionHouseSearchContext.AllFavorites
      Q.blizzardSearch(fav ~= nil and context == fav)
    end)
  end
end

local ev = CreateFrame("Frame")
for _, e in ipairs({ "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED", "AUCTION_HOUSE_BROWSE_RESULTS_ADDED",
    "AUCTION_HOUSE_BROWSE_FAILURE", "ITEM_SEARCH_RESULTS_UPDATED", "ITEM_SEARCH_RESULTS_ADDED",
    "COMMODITY_SEARCH_RESULTS_UPDATED", "COMMODITY_SEARCH_RESULTS_ADDED", "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED" }) do
  pcall(ev.RegisterEvent, ev, e)
end
ev:SetScript("OnEvent", function(_, e, ...)
  if e == "AUCTION_HOUSE_SHOW" then hook(); return end
  if e == "AUCTION_HOUSE_CLOSED" then
    for _, job in ipairs(Q.list) do job.cancelled = true end
    if Q.busy then Q.busy.cancelled = true end
    Q.list, Q.busy, Q.waiters, Q.blizzard = {}, nil, {}, nil
    return
  end
  Q.onEvent(e, ...)
end)
