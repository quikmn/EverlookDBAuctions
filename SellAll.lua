-- EverlookDB Auctions: Sell all, a view of the Quick sell tab (its "Sell all" button at the top right).
--   Post queue       everything in your bags a sell rule covers (SellRules.lua), in Quick sell's order. One gold
--                    button: "Post 20 Linen Cloth · 12s each (3 of 14)". The live price of the item up next is asked
--                    for by itself (a search, as Quick sell does when you pick an item); one click posts it at the
--                    price its rule picks, and the queue goes on. When the live price is over a minute old or didn't
--                    come, the button says "Check price" and that click asks again. Skip leaves one out for this
--                    visit. Each row says why: the rule, the floor, the normal price, the undercut.
--   Cancel undercut  your auctions someone else is now cheaper than, most undercut first, one click per cancel.
--                    One a repost would put under its rule's floor is kept up and says so.
--   Your alts        what they have that your rules would sell, as a line (mail it here to sell it).
-- Every auction house call is one click of yours on the one gold button: a post, a confirm, a cancel or a price
-- check. Nothing is posted or cancelled on its own. Posts go through Quick sell's own post code, so the AH log
-- (LedgerWatch.lua) and the remembered prices see them as usual.
-- The rules are edited on the Sell rules page of the settings (/eah rules).
local _, ns = ...
local UI, T = ns.UI, ns.T
local R = ns.sellRules
local AH = C_AuctionHouse or {}
local money, num = ns.money, ns.num

local A = { mode = "post", entries = {}, skipped = {}, cskip = {}, doneN = 0, holdUntil = 0, cpos = 1 }
ns.sellAll = A

local ROW_H = 34

local function core() return ns.sellCore end
local function try(fn, ...)
  if type(fn) ~= "function" then return nil end
  local okCall, a = pcall(fn, ...)
  if okCall then return a end
end
local function now() return time() end

---------------------------------------------------------------------------------------------------------------------
-- What the rules see of an item

-- The query-language row of an item in your bags (Search.lua's queryItemRow), with the last full scan's usual price
-- as `median`, so the default normal price has something when the 30-day history is short.
local rowCache = {}
local function rowOf(id, key)
  local c = rowCache[key or id]
  if c then return c end
  local row = ns.queryItemRow and ns.queryItemRow(id)
  if not row then return { id = id, key = key or (id .. ":0"), name = "", pcRun = nil } end   -- not loaded yet: only Everything
  row.key = key or row.key
  local scan = ns.latestRow and ns.latestRow(row.key)
  if scan then
    row.median = row.median or scan.med
    row.price = row.price or scan.low
  end
  rowCache[key or id] = row
  return row
end
A.rowOf = rowOf

-- How many of an item you have up: from your auctions as the auction house listed them this visit, else as the
-- inventory store last saw them.
local function upOf(id)
  local C = core()
  if C and C.S.ownedLoaded then
    local n = 0
    for _, a in ipairs(C.S.owned or {}) do
      if a.itemID == id and not a.sold then n = n + (a.qty or 1) end
    end
    return n
  end
  local inv = ns.inventory and ns.inventory.count(id)
  for _, e in ipairs(inv and inv.chars or {}) do if e.me then return e.listed or 0 end end
  return 0
end

-- What your alts on this auction house have of an item (bags, bank, mail): the number and who, "Thorn 40, Mara 4".
local function altsOf(id)
  local inv = ns.inventory and ns.inventory.count(id)
  if not inv then return 0, "" end
  local n, who = 0, {}
  for _, e in ipairs(inv.chars or {}) do
    if not e.me then
      local k = (e.bags or 0) + (e.bank or 0) + (e.mail or 0)
      if k > 0 then n = n + k; who[#who + 1] = ("%s %d"):format(e.name or "?", k) end
    end
  end
  return n, table.concat(who, ", ")
end
A.altsOf = altsOf

local function rules() return R.all(ns.db and ns.db()) end

local function durationOf(e)
  local C = core()
  local s = C and C.sdb()
  if e.rule.duration and e.rule.duration > 0 then return e.rule.duration end
  local mem = s and s.memory[e.g.key]
  return (mem and mem.d) or (s and s.duration) or 1
end

-- The deposit for one, for the floor's `deposit` (0 when the auction house can't say).
local function depositEach(e, qty)
  local g = e.g
  local dur = durationOf(e)
  qty = math.max(1, qty or e.qty or 1)
  local dep
  if g.commodity then dep = try(AH.CalculateCommodityDeposit, g.id, dur, qty)
  elseif g.loc then dep = try(AH.CalculateItemDeposit, g.loc, dur, qty) end
  return (type(dep) == "number" and dep > 0) and dep / qty or 0
end

---------------------------------------------------------------------------------------------------------------------
-- The post queue

local function prepared(e)
  if not e.prepared then
    core().prepare(e.g)
    e.prepared = true
  end
  return e.g
end

-- The item's live answer (any age) or nil.
local function liveOf(e)
  local C = core()
  local g = e.g
  return C.liveFor(g.ckey, g.id, g.commodity)
end

-- The rule's price over the live answer, when it is fresh enough to post by.
local function resultOf(e)
  local live = liveOf(e)
  if not live or now() - (live.at or 0) > R.FRESH then return nil, live end
  local C = core()
  local s = C.sdb()
  local mem = s and s.memory[e.g.key]
  local res = R.price(e.rule, {
    row = rowOf(e.g.id, e.g.key), step = C.priceStep(), deposit = depositEach(e), live = live,
    undercut = C.undercut(), last = mem and mem.p,
  })
  return res, live
end
A.resultOf = resultOf

function A.stateOf(e)
  if not e then return "done" end
  local C = core()
  local res, live = resultOf(e)
  local job = C.S.posting
  return R.state({
    posting = job ~= nil and job.entry == e,
    warned = C.S.warned ~= nil and C.S.warned.entry == e,
    held = GetTime() < A.holdUntil,
    live = live, job = e.g.ckey and C.Live.jobs[e.g.ckey] ~= nil, result = res,
  }, now()), res
end

local function hold(secs)
  A.holdUntil = GetTime() + secs
  C_Timer.After(secs + 0.05, function() A.render() end)
end

-- Builds the queue again from your bags (after a post, a bag change, a rule change), keeping what was skipped.
function A.build()
  local C = core()
  if not C then return end
  wipe(rowCache)
  C.collect()
  local s = C.sdb()
  local all = rules()
  A.rules = all
  local was = A.entries[A.pos or 0]
  A.entries = R.queue(C.S.groups, {
    rules = all,
    rowOf = function(g) return rowOf(g.id, g.key) end,
    upOf = function(g) return upOf(g.id) end,
    hidden = function(g) return s and s.hidden[g.key] end,
  })
  for _, e in ipairs(A.entries) do
    e.skipped = A.skipped[e.g.key]
    local alts = altsOf(e.g.id)
    e.alts = alts
  end
  -- the same item stays up next while there is more of it to post (a rule's stack size), else the next one
  local at = 1
  if was then
    for i, e in ipairs(A.entries) do if e.g.key == was.g.key then at = i; break end end
  end
  A.pos = R.nextOpen(A.entries, at)
  A.altLine = A.altsSummary(all)
end

-- Your alts' items your rules would sell that aren't in your bags: "On your alts: 40 Silk Cloth (Thorn), and 3
-- more. Mail them here to sell them." Only stackable goods count (gear may be soulbound, which the store can't tell).
function A.altsSummary(all)
  local I = ns.inventory
  if not I or not I.owned then return "" end
  local okAll, everyone = pcall(I.owned, true)
  local okMe, mine = pcall(I.owned, false)
  if not (okAll and okMe) then return "" end
  local inBags = {}
  for _, e in ipairs(A.entries) do inBags[e.g.id] = true end
  local found, seen = {}, 0
  for id, n in pairs(everyone) do
    local alt = n - (mine[id] or 0)
    seen = seen + 1
    if seen > 600 then break end
    if alt > 0 and not inBags[id] then
      local row = rowOf(id)
      if row.name ~= "" and (row.stack or 1) > 1 and not row.quest and R.ruleFor(all, row) then
        found[#found + 1] = { id = id, n = alt, name = row.name, worth = alt * (row.price or 0) }
      end
    end
  end
  if #found == 0 then return "" end
  table.sort(found, function(a, b) if a.worth ~= b.worth then return a.worth > b.worth end return a.name < b.name end)
  local top = found[1]
  local _, who = altsOf(top.id)
  return ("On your alts: %d %s (%s)%s. Mail them here to sell them."):format(top.n, top.name, who,
    #found > 1 and (", and %d more"):format(#found - 1) or "")
end

local function current() return A.pos and A.entries[A.pos] or nil end
A.current = current

-- Open entries: (done this visit + 1) of (done + still open), for "(3 of 14)".
local function counts()
  local open = 0
  for _, e in ipairs(A.entries) do if R.open(e) then open = open + 1 end end
  return A.doneN + 1, A.doneN + open, open
end

-- The item up next gets its live price by itself (a search, never a post); the one after it is asked for behind it.
local function lookAhead()
  local C = core()
  local e = current()
  if not e then return end
  for k, x in ipairs({ e, A.entries[R.nextOpen(A.entries, (A.pos or 1) + 1) or 0] }) do
    if x and (k == 1 or x ~= e) then
      local g = prepared(x)
      local live = liveOf(x)
      local stale = not live or now() - (live.at or 0) > R.FRESH
      local failed = g.ckey and C.Live.failed[g.ckey]
      if stale and g.itemKey and not (g.ckey and C.Live.jobs[g.ckey]) and not (failed and x.asked) then
        x.asked = true
        C.request(g.itemKey, g.commodity, k == 1)
      end
    end
  end
end

-- The live answer says the rule doesn't post it (under the floor, sell to a vendor, no price): it is left out and
-- the queue moves on, without a click (no auction house call).
local function skipRuled()
  for _ = 1, #A.entries do
    local e = current()
    if not e then return end
    local st, res = A.stateOf(e)
    if st ~= "skip" then return end
    e.ruled = res
    A.skipped[e.g.key] = "rule"
    e.skipped = "rule"
    A.pos = R.nextOpen(A.entries, A.pos)
    hold(1)
  end
end

-- After a post went up: the next post of this item needs a new live price (with yours in it).
local function onPosted(job)
  local C = core()
  A.doneN = A.doneN + 1
  local g = job.entry and job.entry.g
  if g and g.ckey then C.Live.cache[g.ckey] = nil end
  if g and g.commodity then C.Live.byId[g.id] = nil end
  hold(1)
  A.build()
  A.refresh()
end

-- The confirm the auction house asked for: the gold button becomes "Post anyway".
local function onConfirm(job)
  core().setStatus(("The auction house asks you to confirm: %d %s at %s each. Post anyway, or Don't."):format(
    job.qty, job.name, money(job.unit)), T.accent)
  A.render()
end

---------------------------------------------------------------------------------------------------------------------
-- Cancel undercut

local function sureOf(a)
  local C = core()
  local s = C.sdb()
  return not a.commodity or (s and s.ownedTotal ~= nil)
end

function A.cancelList()
  local C = core()
  local all = A.rules or rules()
  return R.cancelQueue(C.S.owned, {
    live = function(a) return C.liveFor(a.ckey, a.itemID, a.commodity) end,
    rule = function(a) return R.ruleFor(all, rowOf(a.itemID)) end,
    row = function(a) return rowOf(a.itemID) end,
    step = C.priceStep(), undercut = C.undercut(), now = now(), sure = sureOf,
    deposit = function(a)
      if not a.commodity then return 0 end
      local d = try(AH.CalculateCommodityDeposit, a.itemID, 1, math.max(1, a.qty or 1))
      return d and d / math.max(1, a.qty or 1) or 0
    end,
  })
end

local function cancelOpen(list)
  local out = {}
  for _, c in ipairs(list) do
    if c.ok and not A.cskip[c.a.id] and not c.a.cancelling then out[#out + 1] = c end
  end
  return out
end

function A.cancelState(c)
  local C = core()
  if not c then return "done" end
  if c.a.cancelling or C.S.cancelPending then return "posting" end
  if c.fresh then return GetTime() < A.holdUntil and "wait" or "post" end
  if c.a.ckey and C.Live.jobs[c.a.ckey] then return "checking" end
  return "check"
end

---------------------------------------------------------------------------------------------------------------------
-- The one button: one auction house call per click

function A.click()
  local C = core()
  if not C then return end
  if A.mode == "cancel" then
    local open = cancelOpen(A.cancelList())
    local c = open[1]
    local st = A.cancelState(c)
    local call = R.clickCall(st, true)
    if call == "search" then
      C.request(c.a.key, c.a.commodity, true)
    elseif call == "cancel" then
      if C.cancelAuction(c.a) then A.cdone = (A.cdone or 0) + 1; hold(1) end
    end
    A.render()
    return call
  end
  local e = current()
  if not e then return end
  local st, res = A.stateOf(e)
  local call = R.clickCall(st)
  if call == "search" then
    local g = prepared(e)
    if g.itemKey then
      C.Live.failed[g.ckey or ""] = nil
      C.request(g.itemKey, g.commodity, true)
    else
      C.setStatus(("%s can't be looked up on the auction house: Skip it, or sell it in Quick sell."):format(g.name), T.bad)
    end
  elseif call == "post" then
    local g = e.g
    local loc = C.locate(g)
    if not loc then
      C.setStatus(("%s is no longer in your bags."):format(g.name), T.bad)
      A.build()
    else
      g.loc = loc
      local avail = C.available(g)
      local qty = math.min(e.qty, avail or e.qty)
      if qty >= 1 and res and res.price then
        C.postJob(g, loc, qty, res.price, durationOf(e), { owner = "all", entry = e, onDone = onPosted, onConfirm = onConfirm })
      end
    end
  elseif call == "confirm" then
    local job = C.S.warned
    if job then C.confirmJob(job) end
  end
  A.render()
  return call
end

-- Skip (plain): this one is left out for this visit (or the confirm is answered no).
function A.skip()
  local C = core()
  if A.mode == "cancel" then
    local c = cancelOpen(A.cancelList())[1]
    if c then A.cskip[c.a.id] = true end
    hold(0.5)
    A.render()
    return
  end
  if C.S.warned and C.S.warned.entry then
    C.S.warned = nil
    C.setStatus("Not posted.", T.dim)
    A.render()
    return
  end
  local e = current()
  if not e then return end
  A.skipped[e.g.key] = "you"
  e.skipped = "you"
  A.pos = R.nextOpen(A.entries, A.pos)
  hold(0.5)
  A.refresh()
end

---------------------------------------------------------------------------------------------------------------------
-- Drawing

local function label(st, e, res, pos, total)
  if st == "post" or st == "wait" then return R.postLabel(e, res.price, pos, total) end
  if st == "confirm" then
    local job = core().S.warned
    return ("Post anyway: %d %s · %s each"):format(job.qty, job.name, money(job.unit))
  end
  if st == "checking" then return ("Checking the price of %s..."):format(e.g.name) end
  if st == "posting" then return ("Posting %s..."):format(e.g.name) end
  return ("Check price: %s (%d of %d)"):format(e.g.name, pos, total)
end

local function entryBadge(e, isCur)
  if e.skipped == "you" then return "Skipped", T.mute end
  if e.skipped == "rule" then
    local s = e.ruled and e.ruled.short or "skipped"
    return s == "sell to a vendor" and "To a vendor" or s == "no price" and "No price" or "Under floor", T.bad
  end
  if e.qty <= 0 then return "Keeping", T.mute end
  if isCur then return "Next", T.accent end
  return "Waiting", T.dim
end

local function whyLine(e)
  if e.skipped == "rule" and e.ruled then return e.ruled.why[1] or "" end
  if e.qty <= 0 then return "Not posted: " .. (e.why or "") .. "." end
  local res = resultOf(e)
  if res then return res.why[1] or "" end
  return ("Rule %s%s"):format(e.rule.name, e.alts and e.alts > 0 and ("  ·  your alts have %d more"):format(e.alts) or "")
end

function A.render()
  local f = A.frame
  if not f or not f:IsShown() then return end
  local C = core()
  f.postMode:EdbActive(A.mode == "post")
  f.cancelMode:EdbActive(A.mode == "cancel")
  if A.mode == "cancel" then return A.renderCancel() end
  f.postBand:Show(); f.cancelBand:Hide(); f.list:Show(); f.clist:Hide()
  skipRuled()
  local e = current()
  local pos, total, open = counts()
  local kept, ruled = 0, 0
  for _, x in ipairs(A.entries) do
    if x.qty <= 0 then kept = kept + 1 elseif x.skipped then ruled = ruled + 1 end
  end
  f.info:SetText(("%d to post%s%s"):format(open, kept > 0 and ("  ·  %d kept"):format(kept) or "",
    ruled > 0 and ("  ·  %d skipped"):format(ruled) or ""))
  f.list.empty:SetText(#A.entries == 0 and "Nothing in your bags is covered by a sell rule. Shift+right-click in Quick sell hides an item; the Sell rules page says what is sold."
    or "")
  f.list:SetItems(A.entries)
  local st, res = A.stateOf(e)
  if not e then
    f.go:SetText(A.doneN > 0 and ("All done: %d posted"):format(A.doneN) or "Nothing to post")
    f.go:Disable()
    f.skip:Disable()
    f.why1:SetText(#A.entries > 0 and "Everything the rules cover is posted, kept or skipped. Skipped ones come back next visit." or "")
    f.why2:SetText("")
  else
    lookAhead()
    st, res = A.stateOf(e)
    f.go:SetText(label(st, e, res, pos, total))
    f.go:SetEnabled(st == "post" or st == "check" or st == "confirm")
    f.skip:SetText(st == "confirm" and "Don't" or "Skip")
    f.skip:Enable()
    if res then
      f.why1:SetText(R.explain(e.rule, res))
      f.why2:SetText((res.why[1] or "") .. (e.alts > 0 and ("  Your alts have %d more."):format(e.alts) or ""))
    else
      local failed = e.g.ckey and C.Live.failed[e.g.ckey] and not C.Live.jobs[e.g.ckey]
      f.why1:SetText(("Rule %s  ·  %s"):format(e.rule.name, (e.rule.query ~= "" and e.rule.query) or "every item"))
      f.why2:SetText(failed and "The auction house didn't answer the price check: Check price asks again."
        or st == "checking" and "Checking the live auctions..." or "The live price is over a minute old: Check price asks again.")
    end
  end
  f.alts:SetText(A.altLine or "")
end

function A.renderCancel()
  local f = A.frame
  local C = core()
  f.postBand:Hide(); f.cancelBand:Show(); f.list:Hide(); f.clist:Show()
  local list = A.cancelList()
  local open = cancelOpen(list)
  local checking = 0
  for _, a in ipairs(C.S.owned or {}) do
    if not a.sold and a.ckey and C.Live.jobs[a.ckey] then checking = checking + 1 end
  end
  f.info:SetText(("%d to cancel%s"):format(#open, checking > 0 and ("  ·  checking %d"):format(checking) or ""))
  f.clist.empty:SetText(not C.S.ownedLoaded and "Asking the auction house for your auctions..."
    or checking > 0 and "Checking your auctions' live prices..." or "None of your auctions is undercut.")
  f.clist:SetItems(list)
  local c = open[1]
  local st = A.cancelState(c)
  local done = A.cdone or 0
  if not c then
    f.go:SetText(done > 0 and ("All done: %d cancelled"):format(done) or "Nothing to cancel")
    f.go:Disable()
    f.skip:Disable()
    f.why1:SetText("")
    f.why2:SetText("")
  else
    local pos, total = done + 1, done + #open
    f.go:SetText(st == "check" and ("Check price: %s (%d of %d)"):format(c.a.name, pos, total)
      or st == "checking" and ("Checking the price of %s..."):format(c.a.name)
      or st == "posting" and "Cancelling..." or R.cancelLabel(c, pos, total))
    f.go:SetEnabled(st == "post" or st == "check")
    f.skip:SetText("Skip")
    f.skip:Enable()
    local cost = try(AH.GetCancelCost, c.a.id)
    f.why1:SetText(("Rule %s  ·  floor %s"):format(c.rule.name, c.floor and money(c.floor) or "none"))
    f.why2:SetText(c.why .. ((cost and cost > 0) and (" Cancelling costs " .. money(cost) .. ".") or "")
      .. (c.fresh and "" or " The live price is over a minute old: Check price asks again."))
  end
  f.alts:SetText("Cancelled auctions come back by mail.")
end

-- Bags or rules changed: the queue again, then the view.
function A.refresh()
  if not A.frame or not A.frame:IsShown() then return end
  A.build()
  A.render()
end

---------------------------------------------------------------------------------------------------------------------
-- The view

local function buildRow(L)
  local b = UI.row(L, ROW_H)
  b.icon = b:CreateTexture(nil, "ARTWORK")
  b.icon:SetSize(22, 22)
  b.icon:SetPoint("LEFT", 8, 0)
  b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  b.state = UI.badge(b, 72, 16)
  b.state:SetPoint("RIGHT", -6, 0)
  b.price = UI.text(b, "body")
  b.price:SetPoint("RIGHT", b.state, "LEFT", -10, 0)
  b.price:SetWidth(120)
  b.price:SetJustifyH("RIGHT")
  b.rule = UI.text(b, "dim")
  b.rule:SetPoint("RIGHT", b.price, "LEFT", -10, 0)
  b.rule:SetWidth(120)
  b.rule:SetJustifyH("LEFT")
  b.rule:SetWordWrap(false)
  b.name = UI.text(b, "body")
  b.name:SetPoint("TOPLEFT", b.icon, "TOPRIGHT", 8, 2)
  b.name:SetPoint("RIGHT", b.rule, "LEFT", -8, 0)
  b.name:SetWordWrap(false)
  b.why = UI.text(b, "mute")
  b.why:SetPoint("TOPLEFT", b.name, "BOTTOMLEFT", 0, -2)
  b.why:SetPoint("RIGHT", b.rule, "LEFT", -8, 0)
  b.why:SetWordWrap(false)
  b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  b:SetScript("OnClick", function(self, button)
    local e = self.item
    if not e then return end
    if button == "RightButton" then
      -- skipped ones come back; others are skipped
      if e.skipped then A.skipped[e.g.key] = nil else A.skipped[e.g.key] = "you" end
      A.refresh()
      return
    end
    if R.open(e) then
      for i, x in ipairs(A.entries) do if x == e then A.pos = i end end
      hold(0.5)
      A.render()
    end
  end)
  b:SetScript("OnEnter", function(self)
    local e = self.item
    if not e then return end
    ns.itemTipOwner(self)
    if not (e.g.link and pcall(GameTooltip.SetHyperlink, GameTooltip, e.g.link)) then pcall(GameTooltip.SetItemByID, GameTooltip, e.g.id) end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Rule: " .. e.rule.name .. (e.rule.query ~= "" and (" (" .. e.rule.query .. ")") or " (every item)"), T.dim[1], T.dim[2], T.dim[3], true)
    local res = resultOf(e) or e.ruled
    if res then GameTooltip:AddLine(R.explain(e.rule, res), T.dim[1], T.dim[2], T.dim[3], true) end
    if e.alts and e.alts > 0 then
      local _, who = altsOf(e.g.id)
      GameTooltip:AddLine("Your alts have " .. who .. ".", T.dim[1], T.dim[2], T.dim[3], true)
    end
    GameTooltip:AddLine("Click: this one next. Right-click: skip it for this visit, or bring it back.", T.info[1], T.info[2], T.info[3], true)
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)
  return b
end

local function fillRow(b, e)
  local C = core()
  local g = e.g
  local cur = current() == e
  b.icon:SetTexture(g.icon)
  b.name:SetText(C.qualityHex(g.quality) .. g.name .. "|r" .. UI.hex(T.mute) .. ("  %d in bags%s|r"):format(g.count,
    e.qty > 0 and e.qty < g.count and (", posts %d"):format(e.qty) or ""))
  b.why:SetText(whyLine(e))
  b.rule:SetText(e.rule.name)
  local res = (e.skipped == "rule" and e.ruled) or (e.qty > 0 and resultOf(e)) or nil
  b.price:SetText(res and res.price and money(res.price) or (UI.hex(T.mute) .. "-|r"))
  b.state:EdbSet(entryBadge(e, cur))
  b:EdbSelect(cur)
end

local function buildCancelRow(L)
  local b = UI.row(L, ROW_H)
  b.icon = b:CreateTexture(nil, "ARTWORK")
  b.icon:SetSize(22, 22)
  b.icon:SetPoint("LEFT", 8, 0)
  b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  b.state = UI.badge(b, 72, 16)
  b.state:SetPoint("RIGHT", -6, 0)
  b.price = UI.text(b, "body")
  b.price:SetPoint("RIGHT", b.state, "LEFT", -10, 0)
  b.price:SetWidth(220)
  b.price:SetJustifyH("RIGHT")
  b.name = UI.text(b, "body")
  b.name:SetPoint("TOPLEFT", b.icon, "TOPRIGHT", 8, 2)
  b.name:SetPoint("RIGHT", b.price, "LEFT", -8, 0)
  b.name:SetWordWrap(false)
  b.why = UI.text(b, "mute")
  b.why:SetPoint("TOPLEFT", b.name, "BOTTOMLEFT", 0, -2)
  b.why:SetPoint("RIGHT", b.price, "LEFT", -8, 0)
  b.why:SetWordWrap(false)
  b:SetScript("OnEnter", function(self)
    local c = self.item
    if not c then return end
    ns.itemTipOwner(self)
    if c.a.link then pcall(GameTooltip.SetHyperlink, GameTooltip, c.a.link) elseif c.a.itemID then pcall(GameTooltip.SetItemByID, GameTooltip, c.a.itemID) end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(c.why, T.dim[1], T.dim[2], T.dim[3], true)
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)
  return b
end

local function fillCancelRow(b, c)
  local C = core()
  b.icon:SetTexture(c.a.icon)
  b.name:SetText(C.qualityHex(c.a.quality) .. (c.a.name or "?") .. "|r" .. UI.hex(T.mute) .. ("  x%d|r"):format(c.a.qty or 1))
  b.why:SetText(c.why)
  b.price:SetText(money(c.a.unit) .. UI.hex(T.mute) .. "  now " .. "|r" .. money(c.cheapest))
  local first = cancelOpen(A.cancelList())[1]
  if c.a.cancelling then b.state:EdbSet("Cancelling", T.mute)
  elseif A.cskip[c.a.id] then b.state:EdbSet("Skipped", T.mute)
  elseif not c.ok then b.state:EdbSet("Kept", T.dim)
  elseif first == c then b.state:EdbSet("Next", T.accent)
  else b.state:EdbSet("Undercut", T.bad) end
  b:EdbSelect(first == c)
end

local function makeView(f)
  local PLACE = ns.T.places and ns.T.places.sell or T.accent
  local O = UI.panel(CreateFrame("Frame", nil, f), UI.tint(T.surface, PLACE, UI.WASH_INNER), UI.tint(T.edge, PLACE, UI.WASH_EDGE))
  O:SetPoint("TOPLEFT", 8, -28)
  O:SetPoint("BOTTOMRIGHT", -8, 30)
  O:SetFrameLevel(f:GetFrameLevel() + 5)
  O:EnableMouse(true)
  O:Hide()
  A.frame = O

  O.postMode = UI.button(O, "Post queue", 110, 22, "small")
  UI.place(O.postMode, "sell")
  O.postMode:SetPoint("TOPLEFT", 10, -8)
  O.postMode:SetScript("OnClick", function() A.mode = "post"; A.refresh() end)
  UI.tip(O.postMode, "Post queue", "Everything in your bags your sell rules cover. One click posts one.")
  O.cancelMode = UI.button(O, "Cancel undercut", 130, 22, "small")
  UI.place(O.cancelMode, "sell")
  O.cancelMode:SetPoint("LEFT", O.postMode, "RIGHT", 4, 0)
  O.cancelMode:SetScript("OnClick", function()
    A.mode = "cancel"
    core().queryOwned()
    A.refresh()
  end)
  UI.tip(O.cancelMode, "Cancel undercut", "Your auctions someone else is now cheaper than. One click cancels one; ones a repost would put under the rule's floor stay up.")
  local rulesBtn = UI.button(O, "Sell rules", 90, 22, "small")
  rulesBtn:SetPoint("TOPRIGHT", -10, -8)
  rulesBtn:SetScript("OnClick", function() A.openRules() end)
  UI.tip(rulesBtn, "Sell rules", "Which items are sold, the lowest price (floor), the price when nobody else sells, undercut, how many to keep and more. In the settings.")
  O.info = UI.text(O, "mute")
  O.info:SetPoint("RIGHT", rulesBtn, "LEFT", -10, 0)
  O.info:SetJustifyH("RIGHT")

  local function band(cols)
    local bd = UI.headerBand(O, 20)
    bd:SetPoint("TOPLEFT", 1, -38)
    bd:SetPoint("TOPRIGHT", -1, -38)
    for _, c in ipairs(cols) do
      local l = UI.label(bd, c[1])
      if c[3] then l:SetPoint("RIGHT", bd, "RIGHT", c[2], 0); l:SetJustifyH("RIGHT") else l:SetPoint("LEFT", bd, "LEFT", c[2], 0) end
    end
    return bd
  end
  O.postBand = band({ { "ITEM", 38 }, { "RULE", -350, true }, { "PRICE EACH", -108, true }, { "STATUS", -26, true } })
  O.cancelBand = band({ { "YOUR AUCTION", 38 }, { "YOURS  ·  NOW", -108, true }, { "STATUS", -26, true } })
  O.list = UI.list(O, ROW_H, buildRow, fillRow)
  O.list:SetPoint("TOPLEFT", 1, -58)
  O.list:SetPoint("BOTTOMRIGHT", -3, 92)
  O.clist = UI.list(O, ROW_H, buildCancelRow, fillCancelRow)
  O.clist:SetPoint("TOPLEFT", 1, -58)
  O.clist:SetPoint("BOTTOMRIGHT", -3, 92)

  local line = UI.line(O, true)
  line:SetPoint("BOTTOMLEFT", 1, 90)
  line:SetPoint("BOTTOMRIGHT", -1, 90)
  -- why this price, for the one up next
  O.go = UI.button(O, "Post", 380, 30, "primary")
  O.go:SetPoint("BOTTOMRIGHT", -12, 12)
  O.go:SetScript("OnClick", function() A.click() end)
  O.skip = UI.button(O, "Skip", 70, 30)
  O.skip:SetPoint("RIGHT", O.go, "LEFT", -8, 0)
  O.skip:SetScript("OnClick", function() A.skip() end)
  UI.tip(O.skip, "Skip", "Leave this one out for this visit and go on to the next.")
  O.why1 = UI.text(O, "dim")
  O.why1:SetPoint("BOTTOMLEFT", 12, 70)
  O.why1:SetPoint("RIGHT", O, "RIGHT", -12, 0)
  O.why1:SetWordWrap(false)
  O.why2 = UI.text(O, "body")
  O.why2:SetPoint("BOTTOMLEFT", 12, 52)
  O.why2:SetPoint("RIGHT", O, "RIGHT", -12, 0)
  O.why2:SetWordWrap(false)
  O.alts = UI.text(O, "mute")
  O.alts:SetPoint("LEFT", O, "BOTTOMLEFT", 12, 27)
  O.alts:SetPoint("RIGHT", O.skip, "LEFT", -12, 0)
  O.alts:SetWordWrap(true)
  if O.alts.SetMaxLines then O.alts:SetMaxLines(2) end
  O:SetScript("OnShow", function() A.refresh() end)
  -- a live price goes stale after a minute: the button says so without waiting for an event
  local tick = 0
  O:SetScript("OnUpdate", function(_, dt)
    tick = tick + dt
    if tick < 3 then return end
    tick = 0
    A.render()
  end)
  return O
end

-- Sell all in place of Quick sell's panels, or back.
function A.show(on)
  local C = core()
  local f = C and C.makeFrame()
  if not f then return end
  local O = A.frame or makeView(f)
  for _, p in ipairs(f.mainParts or {}) do p:SetShown(not on) end
  f.sellAllBtn:SetText(on and "Quick sell" or "Sell all")
  f.sellAllBtn:EdbActive(on)
  O:SetShown(on)
  A.on = on
  if ns.ahTitle then ns.ahTitle(on and "Quick sell · Sell all" or "Quick sell", ns.T.places and ns.T.places.sell) end
end

function A.toggle() A.show(not A.on) end

-- Quick sell opened: Sell all as it was left this visit.
function A.onShow()
  if not A.frame then return end
  A.show(A.on and true or false)
  -- the tab sets its own title just after this: Sell all's comes a frame later
  if A.on then C_Timer.After(0, function() if A.on and ns.ahTitle then ns.ahTitle("Quick sell · Sell all", ns.T.places and ns.T.places.sell) end end) end
end

function A.openRules()
  if ns.app and ns.app.Open then ns.app:Open("sellrules") else ns.say("the settings aren't loaded yet.") end
end

-- Quick sell's events (Sell.lua): posts, cancels, bags, your auctions, live prices.
function ns.sellAllEvent(e)
  if e == "AUCTION_HOUSE_CLOSED" then
    wipe(A.skipped)
    wipe(A.cskip)
    A.doneN, A.cdone, A.pos = 0, 0, nil
    A.entries = {}
    return
  end
  if not A.frame or not A.frame:IsShown() then return end
  if e == "BAG_UPDATE_DELAYED" or e == "OWNED_AUCTIONS_UPDATED" then A.refresh() else A.render() end
end

---------------------------------------------------------------------------------------------------------------------
-- The Sell rules page of the settings (Options.lua calls this): the rules in order, and the one being edited.

local FIELDS = {
  { "rulename", "name", "Name", { "name", "rule" }, "What the rule is called.", "Cloth" },
  { "rulesearch", "query", "Which items (a search)", { "search", "query", "items", "which", "match", "filter" },
    "A search in the language of Advanced search, like category is \"trade goods\" and name has cloth. Empty: every item.", "name has cloth" },
  { "rulefloor", "floor", "Floor (lowest price)", { "floor", "minimum", "lowest", "min price", "loss", "deposit", "formula" },
    "Never posted under this. A price formula that also knows deposit (the deposit for one): max(vendor + deposit, deposit) never posts under what a vendor pays plus the deposit.", R.DEFAULT_FLOOR },
  { "rulenormal", "normal", "Normal price (nobody else selling)", { "normal", "default", "median", "nobody", "formula" },
    "The price when nobody else is selling. first(median30, median) is the 30-day median, else the usual price at the last full scan.", R.DEFAULT_NORMAL },
  { "ruleundercut", "undercut", "Undercut", { "undercut", "cheaper", "under" },
    "1c, 1s, 5% or 0 to match the cheapest. Empty: the Undercut by setting.", "1c" },
  { "rulekeep", "keep", "Keep in bags", { "keep", "reserve", "hold", "bags" }, "How many to keep in your bags (0: sell all).", "20" },
  { "rulemaxup", "maxUp", "At most up at once", { "max", "most", "limit", "up", "listed" }, "Never more than this many up at once (0: no limit).", "100" },
  { "rulestack", "stack", "At most per post", { "stack", "size", "per post", "batch" }, "Post in lots of at most this many (0: all at once).", "20" },
}

function A.settings(app, EUI)
  local editing   -- the rule being edited
  local function db() return ns.db and ns.db() end
  local function list() return R.all(db()) end
  local function edited()
    local all = list()
    for _, r in ipairs(all) do if r == editing then return r end end
    editing = all[1]
    return editing
  end
  local function changed()
    if A.frame and A.frame:IsShown() then A.refresh() end
    app:Refresh()
  end
  for _, fd in ipairs(FIELDS) do
    local key, field = fd[2], fd[2]
    local numeric = field == "keep" or field == "maxUp" or field == "stack"
    -- what is wrong with a value for this field, or nil
    local function problem(v)
      v = tostring(v or ""):match("^%s*(.-)%s*$")
      local r = edited()
      if field == "query" then
        if r.base and v ~= "" then return "Everything covers every item. Make a New rule for a search." end
        return R.checkQuery(v)
      elseif field == "floor" or field == "normal" then
        return R.checkFormula(v)
      elseif field == "undercut" then
        local u, why = R.parseUndercut(v)
        if u == false then return why end
      elseif numeric then
        if v ~= "" and not v:match("^%d+$") then return "a whole number, like 20 (0: none)" end
      end
    end
    app:Setting({
      key = fd[1], type = "string", label = fd[3], chatLabel = "Sell rule being edited: " .. fd[3]:lower(),
      keywords = fd[4], desc = fd[5], placeholder = fd[6], width = (field == "query" or field == "floor" or field == "normal") and 340 or 160,
      get = function() local r = edited(); return tostring(r[key] or "") end,
      validate = function(v)
        local bad = problem(v)
        if bad then return false, bad end
        return true
      end,
      set = function(v)
        v = tostring(v or ""):match("^%s*(.-)%s*$")
        local r = edited()
        -- the window's box saves without the chat command's check: the same check here
        local bad = problem(v)
        if bad then app:Print(fd[3] .. " not saved: " .. bad); return end
        if field == "query" and r.base then return end
        if field == "floor" and v == "" then v = R.DEFAULT_FLOOR end
        if field == "normal" and v == "" then v = R.DEFAULT_NORMAL end
        if numeric then r[key] = tonumber(v) or 0 else r[key] = v end
        R.norm(r)
      end,
      after = changed,
    })
  end
  app:Setting({
    key = "ruleduration", type = "choice", label = "Duration", chatLabel = "Sell rule being edited: duration",
    keywords = { "duration", "hours", "time", "length" }, width = 160, choices = R.DURATIONS,
    desc = "How long its auctions run. As last time: what you used for the item last, else the Default duration.",
    get = function() return edited().duration or 0 end,
    set = function(v) edited().duration = tonumber(v) or 0; R.norm(edited()) end,
    after = changed,
  })
  app:Setting({
    key = "rulebelow", type = "choice", label = "When the price is under the floor", chatLabel = "Sell rule being edited: under the floor",
    keywords = { "floor", "below", "under", "vendor", "skip" }, width = 200, choices = R.BELOW,
    desc = "Under the floor after your undercut: don't post it, post it at the floor, or leave it for a vendor.",
    get = function() return edited().below or "skip" end,
    set = function(v) edited().below = v; R.norm(edited()) end,
    after = changed,
  })

  app:Section("sellrules", "Sell rules", function(stack)
    EUI.Header(stack, "Sell rules", "Sell all, on the Quick sell tab, posts what these rules cover, one click per post. An item uses the first rule that is on and matches it; Everything, last, covers the rest.")
    EUI.List(stack, {
      rowHeight = 40,
      items = list,
      title = function(r) return (r == edited() and "> " or "") .. r.name end,
      detail = function(r)
        local q = r.query ~= "" and r.query or "every item"
        return q .. "  ·  floor " .. (r.floor ~= "" and r.floor or "none") .. (r.keep > 0 and ("  ·  keep " .. r.keep) or "")
      end,
      icon = function() return "list" end,
      toggle = {
        get = function(r) return r.on ~= false end,
        set = function(r, on) if not r.base then r.on = on and true or false end; changed() end,
      },
      buttons = {
        { label = "Edit", width = 54, onClick = function(r) editing = r; changed() end },
        { label = "Up", width = 40, usable = function(r) return not r.base end, onClick = function(r)
          local s = R.store(db())
          for i, x in ipairs(s.list) do if x == r then R.move(db(), i, -1); break end end
          changed()
        end },
        { label = "Down", width = 50, usable = function(r) return not r.base end, onClick = function(r)
          local s = R.store(db())
          for i, x in ipairs(s.list) do if x == r then R.move(db(), i, 1); break end end
          changed()
        end },
        { label = "Remove", width = 70, style = "danger", confirm = true, shown = function(r) return not r.base end, onClick = function(r)
          local s = R.store(db())
          for i, x in ipairs(s.list) do if x == r then R.remove(db(), i); break end end
          if editing == r then editing = nil end
          changed()
        end },
      },
      tooltip = function(r)
        return { r.name, r.base and "Covers every item no other rule does. It can't be removed, but you can change how it sells."
          or ("Which items: " .. (r.query ~= "" and r.query or "every item")) }
      end,
    })
    EUI.ButtonRow(stack, {
      { label = "New rule", width = 110, onClick = function()
          local r = R.add(db(), R.newRule("Rule " .. (#R.store(db()).list + 1)))
          editing = r
          changed()
        end,
        desc = "A new rule above Everything: give it a search, then a floor and the rest.", keywords = { "new", "add", "rule", "create" } },
    })
    EUI.Header(stack, "The rule you edit")
    EUI.Note(stack, function()
      local r = edited()
      return ("Editing %s%s. Prices: price, median, low30, median30, vendor, craftcost, devalue, avgbuy, avgsell, deposit and your My prices; + - * /, min, max, first, 5g, 80%% of median."):format(
        r.name, r.base and " (covers every item)" or "")
    end)
    for _, fd in ipairs(FIELDS) do app:Widget(stack, fd[1]) end
    app:Widget(stack, "ruleduration")
    app:Widget(stack, "rulebelow")
  end, { icon = "list" })
  app:Command("rules", "rules", "the Sell rules page (what Sell all posts and how)", function() app:Open("sellrules") end, { "sellrules", "sellall" })
end
