-- EverlookDB Auctions: the income ledger (the logic and the saved shape, no frames and no events: LedgerWatch.lua
-- feeds it from the game, Purchases.lua draws it as the AH log's Income view, /eah income).
--
-- Every auction you post has one lifecycle record: posted (item, how many, bid/buyout, duration, deposit, when), then
-- exactly one outcome: sold (the money net of the cut, the buyer, when the money's mail came and when you took it),
-- expired (the item back by mail) or cancelled (the item back by mail, the deposit lost). Money is a list of entries,
-- each in one category: real gains (income), money that isn't a gain (from players, your alts, refunds), costs, or
-- "unsorted" with the reason when it can't be placed (a click on it in the window picks the right one).
--
-- Saved shape: EverlookAuctionsDB.ledger = {
--   v, seq,
--   auctions = { oldest first: { id, ch (character fingerprint), h (house), t (posted, nil when adopted), item (id),
--     name, link (random stats only), q (items in the auction), unit, bid, buy (buyout of the whole auction), dur
--     (1/2/3 = 12/24/48 h), dep (deposit), aid (the auction house's id), ends, st = "listed"|"ended"|"sold"|"expired"|
--     "cancelled", at (when st was set), gross, cut, net (sold: gross - cut), est (a guess before the mail), eta,
--     mailAt (its mail seen), done (the money or the item taken from the mail), why (adopted: how we know of it) } },
--   money = { oldest first: { t, cat, c (copper, always positive), ch, h, item, name, q, rec (record id), gross, cut,
--     dep, why, fixed (picked by hand) } },
--   mails = { { key, exp, cat, rec, took = { money = t, items = n } } },   -- mails already seen: one take counts once
--   alts = { [fingerprint] = true },   -- your characters, as a short hash of the name (never the name)
--   migrated = { at, income, pending, forSale = { [ch] = n } } }
-- Buyer names are kept per character only (EverlookAuctionsCharDB.buyers[record id]), never in this account file.
local _, ns = ...
local L = {}
ns.ledger = L

L.VERSION = 1
L.MAX_MONEY, L.MAX_AUCTIONS, L.MAX_MAILS = 6000, 4000, 400
L.KEEP_DAYS = 120          -- closed records older than this go (money entries stay until MAX_MONEY)
L.MAIL_DAYS = 30           -- auction house mail lasts 30 days
L.HOURS = { 12, 24, 48 }   -- durations 1, 2, 3

-- categories, in the order the window lists them
L.GROUPS = {
  { id = "income", title = "Income", cats = { "sale", "vendor", "loot", "quest", "npc" } },
  { id = "other", title = "Not income", cats = { "player", "alt", "refund" } },
  { id = "cost", title = "Costs", cats = { "bought", "deposit", "cod", "repair", "vendorbuy", "training" } },
}
L.LABEL = {
  sale = "AH sales", vendor = "Vendor sales", loot = "Looted money", quest = "Quest rewards", npc = "NPC mail",
  player = "From players", alt = "From your alts", refund = "Outbid refunds",
  bought = "AH purchases", deposit = "Deposits lost", cod = "C.O.D. paid", repair = "Repairs", vendorbuy = "Vendor buys",
  training = "Training", unsorted = "Unsorted",
}
L.SHORT = {
  sale = "AH sale", vendor = "Vendor", loot = "Loot", quest = "Quest", npc = "NPC mail", player = "From player",
  alt = "From alt", refund = "Refund", bought = "AH buy", deposit = "Deposit lost", cod = "C.O.D.", repair = "Repair",
  vendorbuy = "Vendor buy", training = "Training", unsorted = "Unsorted",
}
L.GROUP_OF = {}
for _, g in ipairs(L.GROUPS) do for _, c in ipairs(g.cats) do L.GROUP_OF[c] = g.id end end
L.GROUP_OF.unsorted = "unsorted"
-- the categories a money entry can be set to by hand (purchases are their own log)
L.PICKABLE = { "sale", "vendor", "loot", "quest", "npc", "player", "alt", "refund", "deposit", "cod" }

L.STATE = {
  listed = "Listed", ended = "Ended, waiting for mail", sold = "Sold, money waiting", expired = "Expired, item in mail",
  cancelled = "Cancelled, item in mail",
}

local function now_(t) return t or (time and time()) or 0 end

function L.store(db)
  if type(db) ~= "table" then return nil end
  local s = db.ledger
  if type(s) ~= "table" then s = {}; db.ledger = s end
  s.v = s.v or L.VERSION
  s.seq = tonumber(s.seq) or 0
  for _, k in ipairs({ "auctions", "money", "mails", "alts" }) do
    if type(s[k]) ~= "table" then s[k] = {} end
  end
  return s
end

local function nextId(s)
  s.seq = (s.seq or 0) + 1
  return s.seq
end

local function trim(list, max)
  while #list > max do table.remove(list, 1) end
end

---------------------------------------------------------------------------------------------------------------------
-- Money

-- Adds a money entry; returns it (nil for no money).
function L.addMoney(s, cat, c, extra, t)
  c = tonumber(c)
  if not s or not c or c <= 0 or type(cat) ~= "string" then return nil end
  local e = { t = now_(t), cat = L.LABEL[cat] and cat or "unsorted", c = math.floor(c + 0.5) }
  if not L.LABEL[cat] then e.why = "unknown category " .. tostring(cat) end
  for k, v in pairs(extra or {}) do if e[k] == nil then e[k] = v end end
  s.money[#s.money + 1] = e
  trim(s.money, L.MAX_MONEY)
  return e
end

-- Puts a money entry in another category (by hand).
function L.setCategory(e, cat)
  if type(e) ~= "table" or not L.LABEL[cat] then return false end
  e.cat, e.fixed = cat, cat ~= "unsorted" or nil
  if e.fixed then e.wasWhy, e.why = e.why or e.wasWhy, nil end
  return true
end

---------------------------------------------------------------------------------------------------------------------
-- Auctions

local OPEN = { listed = true, ended = true }
function L.isOpen(r)
  if type(r) ~= "table" then return false end
  if OPEN[r.st] then return true end
  return (r.st == "sold" or r.st == "expired" or r.st == "cancelled") and not r.done
end

-- The state words for the window: "Listed", "Sold, money waiting", ...
function L.stateText(r)
  if not r then return "" end
  if r.done then
    return r.st == "sold" and "Sold, money taken" or (r.st == "expired" and "Expired, item back") or
      (r.st == "cancelled" and "Cancelled, item back") or (L.STATE[r.st] or r.st)
  end
  if r.st == "sold" and not r.mailAt then return "Sold, money on its way" end
  return L.STATE[r.st] or tostring(r.st)
end

-- A new auction (one per auction the auction house created). p = { item, name, link, q, unit, bid, buy, dur, dep, aid,
-- ch, h }.
function L.post(s, p, t)
  if not s or type(p) ~= "table" or not (p.item or p.name) then return nil end
  t = now_(t)
  local q = math.max(1, tonumber(p.q) or 1)
  local r = { id = nextId(s), ch = p.ch, h = p.h, t = t, item = p.item, name = p.name, link = p.link, q = q,
    unit = p.unit, bid = p.bid, buy = p.buy or (p.unit and p.unit * q) or nil, dur = p.dur, dep = p.dep, aid = p.aid,
    st = "listed", at = t }
  local hours = p.dur and L.HOURS[p.dur]
  if hours then r.ends = t + hours * 3600 end
  s.auctions[#s.auctions + 1] = r
  return r
end

function L.byAid(s, aid)
  if not s or not aid then return nil end
  for i = #s.auctions, 1, -1 do
    if s.auctions[i].aid == aid then return s.auctions[i] end
  end
end

function L.byId(s, id)
  if not s or not id then return nil end
  for i = #s.auctions, 1, -1 do
    if s.auctions[i].id == id then return s.auctions[i] end
  end
end

-- Same item: by id when both know it, else by name.
local function sameItem(r, id, name)
  if id and r.item then return r.item == id end
  return name ~= nil and r.name == name
end

-- The oldest record of this character and item in one of these states (and not done), preferring the same count.
function L.match(s, ch, id, name, count, states)
  if not s then return nil end
  local best
  for _, r in ipairs(s.auctions) do
    if states[r.st] and not r.done and (not ch or not r.ch or r.ch == ch) and sameItem(r, id, name) then
      if count and r.q == count then return r end
      best = best or r
    end
  end
  return best
end

-- A record of an auction we never saw posted (posted elsewhere, or before the ledger): known from the auction house
-- or its mail.
local function adopt(s, info, st, why, t)
  t = now_(t)
  local r = { id = nextId(s), ch = info.ch, h = info.h, item = info.item, name = info.name, link = info.link,
    q = math.max(1, tonumber(info.q) or 1), unit = info.unit, buy = info.buy, aid = info.aid, ends = info.ends,
    st = st, at = t, why = why }
  s.auctions[#s.auctions + 1] = r
  return r
end
L.adopt = adopt

-- A deposit lost (cancelled or expired): one cost entry per record.
local function depositLost(s, r, t)
  if r.depLost or not r.dep or r.dep <= 0 then return end
  r.depLost = true
  L.addMoney(s, "deposit", r.dep, { ch = r.ch, h = r.h, item = r.item, name = r.name, q = r.q, rec = r.id }, t)
end

local function settle(s, r, st, t)
  if r.st == st then return r end
  r.st, r.at = st, now_(t)
  if st == "cancelled" or st == "expired" then depositLost(s, r, t) end
  return r
end

-- The auction house says one of yours sold: info = { aid, item, name, est, q, ch, h }.
function L.sold(s, info, t)
  if not s or type(info) ~= "table" then return nil end
  t = now_(t)
  local r = info.aid and L.byAid(s, info.aid)
  local guessed = false
  if r then
    -- told again with the auction id: a record marked sold by name a moment ago, if another one, was a guess
    for _, x in ipairs(s.auctions) do
      if x ~= r and x.guess and x.st == "sold" and not x.mailAt and (x.at or 0) >= t - 10 and sameItem(x, r.item, r.name) then
        x.st, x.at, x.est, x.guess = "listed", t, nil, nil
      end
    end
    r.guess = nil
  else
    r = L.match(s, info.ch, info.item, info.name, info.q, OPEN)
    guessed = r ~= nil
  end
  if not r then
    if not (info.item or info.name) then return nil end
    r = adopt(s, info, "sold", "sold: the ledger didn't see it posted", t)
  end
  if r.st ~= "sold" and guessed then r.guess = true end
  return L.markSold(s, r, info, t)
end

-- A record is sold: its state, and about what it brings after the cut until the mail says exactly.
function L.markSold(s, r, info, t)
  if r.st ~= "sold" then settle(s, r, "sold", t) end
  if not r.est and not r.net then
    local cut = (info and info.cut) or 0.05
    local gross = r.buy or (info and info.est)
    if gross then r.est = math.floor(gross * (1 - cut) + 0.5) end
  end
  return r
end

-- Cancelled (AUCTION_CANCELED, or its mail).
function L.cancelled(s, info, t)
  if not s or type(info) ~= "table" then return nil end
  local r = info.aid and L.byAid(s, info.aid)
  if not r then r = L.match(s, info.ch, info.item, info.name, info.q, OPEN) end
  if not r then
    if not (info.item or info.name) then return nil end
    r = adopt(s, info, "cancelled", "cancelled: the ledger didn't see it posted", t)
  end
  if r.st == "listed" or r.st == "ended" then settle(s, r, "cancelled", t) end
  return r
end

-- Expired (its mail).
function L.expired(s, info, t)
  if not s or type(info) ~= "table" then return nil end
  local r = info.aid and L.byAid(s, info.aid)
  if not r then r = L.match(s, info.ch, info.item, info.name, info.q, OPEN) end
  if not r then
    if not (info.item or info.name) then return nil end
    r = adopt(s, info, "expired", "expired: the ledger didn't see it posted", t)
  end
  if r.st == "listed" or r.st == "ended" then settle(s, r, "expired", t) end
  return r
end

-- Your auctions as the auction house lists them now (Sell.lua's readOwned rows: { id = auctionID, itemID, name, link,
-- qty, unit, sold, left }). New ones are adopted, sold ones marked, records the list no longer has are "ended" (the
-- mail will say how), and a record wrongly marked sold by name goes back to listed.
function L.reconcile(s, owned, ch, h, t)
  if not s or type(owned) ~= "table" then return end
  t = now_(t)
  local seen = {}
  for _, a in ipairs(owned) do
    local aid = a.id
    local r = aid and L.byAid(s, aid)
    if not r then
      -- a record without its auction id yet (posted before the id came, or migrated): same item, same count
      for _, x in ipairs(s.auctions) do
        if not x.aid and OPEN[x.st] and (not x.ch or x.ch == ch) and sameItem(x, a.itemID, a.name) and x.q == (a.qty or 1) then
          r = x; r.aid = aid; break
        end
      end
    end
    if not r and a.sold then
      -- a sale told by name before (the chat line): the same item, sold, its mail not seen yet
      for _, x in ipairs(s.auctions) do
        if not x.aid and x.st == "sold" and not x.mailAt and not x.done and (not x.ch or x.ch == ch)
          and sameItem(x, a.itemID, a.name) and (not x.q or x.q == (a.qty or 1) or x.why) then
          r = x; r.aid = aid; r.q = a.qty or r.q; break
        end
      end
    end
    if not r then
      r = adopt(s, { ch = ch, h = h, item = a.itemID, name = a.name, link = a.link, q = a.qty or 1, unit = a.unit,
        buy = a.unit and a.unit * (a.qty or 1) or nil, aid = aid, ends = a.left and (t + a.left) or nil },
        a.sold and "sold" or "listed", "listed: found in your auctions", t)
    end
    if aid then seen[aid] = true end
    r.ch = r.ch or ch
    if a.left and r.st == "listed" then r.ends = t + a.left end
    r.item = r.item or a.itemID
    if a.sold then
      if r.st ~= "sold" then L.markSold(s, r, nil, t) end
    elseif r.st == "sold" and not r.mailAt and not r.done then
      r.st, r.at, r.est = "listed", t, nil
    elseif r.st == "ended" then
      r.st, r.at = "listed", t
    end
  end
  for _, r in ipairs(s.auctions) do
    if r.st == "listed" and r.aid and not seen[r.aid] and (not r.ch or r.ch == ch) then
      r.st, r.at = "ended", t
    end
  end
end

-- Listed auctions past their end time are "ended" (the auction house took them down; their mail will say how).
function L.tick(s, t)
  if not s then return end
  t = now_(t)
  for _, r in ipairs(s.auctions) do
    if r.st == "listed" and r.ends and r.ends < t - 60 then r.st, r.at = "ended", t end
  end
end

---------------------------------------------------------------------------------------------------------------------
-- Mail. m is a mail as EverlookMailClassify reads it (MailClassify.lua).

-- The seen-mail entry of this mail (made when new). Mails with the same key are told apart by their expiry.
local function mailEntry(s, m, make, claimed)
  local C = L.classifier and L.classifier()
  local key = C and C.key(m) or tostring(m.subject)
  local slack = C and C.SAME_MAIL or 180
  local best, bestD
  for _, e in ipairs(s.mails) do
    if e.key == key and not (claimed and claimed[e]) then
      local d = (m.exp and e.exp) and math.abs(m.exp - e.exp) or 0
      if d <= slack and (not bestD or d < bestD) then best, bestD = e, d end
    end
  end
  if best or not make then return best end
  best = { key = key, exp = m.exp, cat = m.cat, took = {} }
  s.mails[#s.mails + 1] = best
  trim(s.mails, L.MAX_MAILS)
  return best
end
L.mailEntry = mailEntry

local function info(m, ch, h)
  local first = m.items and m.items[1]
  local inv = m.invoice
  return { ch = ch, h = h, item = first and first.id or nil, name = m.item or (first and first.name),
    q = (inv and inv.count) or m.count or (first and first.count), link = first and first.link }
end

-- What a sale's mail says: the money net of the cut and over the deposit, the buyer.
local function fromInvoice(r, inv, t)
  if not inv then return end
  if inv.bid and inv.bid > 0 then
    r.gross, r.cut = inv.bid, inv.cut or 0
    r.net = inv.bid - (inv.cut or 0)
    if inv.deposit and inv.deposit > 0 then r.dep = r.dep or inv.deposit end
  end
  if inv.type == "seller_temp_invoice" and inv.delay then r.eta = now_(t) + inv.delay end
  if inv.buyer then r.buyer = inv.buyer end   -- LedgerWatch.lua moves it to the per-character file
end

-- A mail seen in the inbox (a scan). Ties it to its auction record: a sale's money is waiting, an item is back.
-- Returns the record, if any. claimed: the entries this scan already used (two mails alike in one inbox).
function L.mailSeen(s, m, ch, h, t, claimed)
  if not s or type(m) ~= "table" or not m.cat then return nil end
  local e = mailEntry(s, m, true, claimed)
  if claimed then claimed[e] = true end
  e.cat = e.cat or m.cat
  local r = e.rec and L.byId(s, e.rec)
  if not r then
    local i = info(m, ch, h)
    if m.cat == "ah_sold" then
      r = L.match(s, ch, i.item, i.name, i.q, { listed = true, ended = true, sold = true })
      if r and r.mailAt then r = nil end
      if not r then r = adopt(s, i, "sold", "sold: known from its mail", t) end
      settle(s, r, "sold", t)
    elseif m.cat == "ah_expired" then
      r = L.match(s, ch, i.item, i.name, i.q, { listed = true, ended = true, expired = true })
      if r and r.mailAt then r = nil end
      r = r or adopt(s, i, "expired", "expired: known from its mail", t)
      settle(s, r, "expired", t)
    elseif m.cat == "ah_cancelled" then
      r = L.match(s, ch, i.item, i.name, i.q, { listed = true, ended = true, cancelled = true })
      if r and r.mailAt then r = nil end
      r = r or adopt(s, i, "cancelled", "cancelled: known from its mail", t)
      settle(s, r, "cancelled", t)
    end
    if r then
      e.rec = r.id
      r.mailAt = r.mailAt or now_(t)
    end
  end
  if r and m.cat == "ah_sold" then
    fromInvoice(r, m.invoice, t)
    r.pending = m.pending or nil
  end
  return r, e
end

-- Something was taken from a mail: part = "money" (all of m.money) or "item" (slot = the attachment, nil for all).
-- Returns the money entry written, if any. A take reported twice (two hooks, or EverlookDB Mail's API too) counts once.
function L.mailTaken(s, m, part, slot, ch, h, t)
  if not s or type(m) ~= "table" or not m.cat then return nil end
  t = now_(t)
  local r, e = L.mailSeen(s, m, ch, h, t)
  e.took = e.took or {}
  local out
  if part == "money" then
    if e.took.money or (m.money or 0) <= 0 then return nil end
    e.took.money = t
    local c = m.money
    local base = { ch = ch, h = h, name = m.item, q = m.count }
    if m.cat == "ah_sold" then
      local inv = m.invoice
      local dep = (inv and inv.deposit) or 0
      base.rec = r and r.id or nil
      base.item = r and r.item or nil
      if inv and inv.bid and inv.bid > 0 then
        base.gross, base.cut, base.dep = inv.bid, inv.cut, dep
        c = c - dep
      else
        base.why = "no invoice: the deposit back may be included"
      end
      out = L.addMoney(s, "sale", c, base, t)
      if r then r.done = t; r.net = r.net or c end
    elseif m.cat == "ah_outbid" then
      out = L.addMoney(s, "refund", c, base, t)
    elseif m.cat == "player" or m.cat == "alt" or m.cat == "npc" then
      out = L.addMoney(s, m.cat, c, base, t)
    elseif m.cat == "ah_expired" or m.cat == "ah_cancelled" or m.cat == "ah_won" then
      base.why = "money on an auction house mail that brings an item (" .. m.cat .. ")"
      out = L.addMoney(s, "unsorted", c, base, t)
      out.why = base.why
    else
      out = L.addMoney(s, "unsorted", c, base, t)
      out.why = "gold from a mail of unknown kind" .. (m.subject and (": " .. m.subject) or "")
    end
    return out
  end
  -- items
  local n = slot and 1 or math.max(1, #(m.items or {}))
  e.took.items = (e.took.items or 0) + n
  if (m.cod or 0) > 0 and not e.took.cod then
    e.took.cod = t
    out = L.addMoney(s, "cod", m.cod, { ch = ch, h = h, name = m.items and m.items[1] and m.items[1].name or m.subject }, t)
  end
  if r and (m.cat == "ah_expired" or m.cat == "ah_cancelled") then r.done = t end
  return out
end

---------------------------------------------------------------------------------------------------------------------
-- Sums

function L.dayStart(t)
  local d = date("*t", t)
  return time({ year = d.year, month = d.month, day = d.day, hour = 0, min = 0, sec = 0 })
end

-- Since when a period starts: "today", "week" (7 days), "month" (30 days), "all".
function L.since(period, t)
  t = now_(t)
  if period == "today" then return L.dayStart(t) end
  if period == "week" then return t - 7 * 86400 end
  if period == "month" then return t - 30 * 86400 end
  return nil
end

-- Sums per category since a time: { [cat] = copper, income = , other = , cost = , unsorted = , net = , n = { [cat] = } }.
-- bought: the AH purchases log (db.bought) for the "AH purchases" cost. ch: one character only (nil: all).
function L.summary(s, since, bought, ch)
  local out = { n = {}, income = 0, other = 0, cost = 0, unsorted = 0 }
  for c in pairs(L.LABEL) do out[c] = 0; out.n[c] = 0 end
  for _, e in ipairs(s and s.money or {}) do
    if (not since or (e.t or 0) >= since) and (not ch or e.ch == ch) and out[e.cat] then
      out[e.cat] = out[e.cat] + (e.c or 0)
      out.n[e.cat] = out.n[e.cat] + 1
    end
  end
  for _, e in ipairs(bought or {}) do
    if not since or (e.t or 0) >= since then
      out.bought = out.bought + (e.c or 0)
      out.n.bought = out.n.bought + 1
    end
  end
  for c, g in pairs(L.GROUP_OF) do
    if g ~= "unsorted" then out[g] = out[g] + (out[c] or 0) end   -- "unsorted" is both a category and its group
  end
  out.net = out.income - out.cost
  -- items that came back (expired, cancelled) in the period
  out.back = 0
  for _, r in ipairs(s and s.auctions or {}) do
    if (r.st == "expired" or r.st == "cancelled") and (not since or (r.at or 0) >= since) and (not ch or r.ch == ch) then
      out.back = out.back + 1
    end
  end
  return out
end

-- The open auctions of a character (all with nil), in the order the window shows them: money waiting, items
-- waiting, ended, listed; then the oldest first.
local RANK = { sold = 1, expired = 2, cancelled = 2, ended = 3, listed = 4 }
function L.openList(s, ch)
  local out = {}
  for _, r in ipairs(s and s.auctions or {}) do
    if L.isOpen(r) and (not ch or not r.ch or r.ch == ch) then out[#out + 1] = r end
  end
  table.sort(out, function(a, b)
    local ra, rb = RANK[a.st] or 9, RANK[b.st] or 9
    if ra ~= rb then return ra < rb end
    return (a.at or 0) < (b.at or 0)
  end)
  return out
end

-- How many are open in each state, and what the sold ones bring (about): listed, ended, sold, back, soldCopper.
function L.openCounts(s, ch)
  local c = { listed = 0, ended = 0, sold = 0, back = 0, soldCopper = 0, other = 0 }
  for _, r in ipairs(s and s.auctions or {}) do
    if L.isOpen(r) then
      if ch and r.ch and r.ch ~= ch then
        c.other = c.other + 1
      elseif r.st == "sold" then
        c.sold = c.sold + 1
        c.soldCopper = c.soldCopper + (r.net or r.est or 0)
      elseif r.st == "expired" or r.st == "cancelled" then
        c.back = c.back + 1
      elseif r.st == "ended" then
        c.ended = c.ended + 1
      else
        c.listed = c.listed + 1
      end
    end
  end
  return c
end

-- What the Home card and the minimap tooltip show: income today and in the last 7 days, sales waiting and about what
-- they bring (every character).
function L.hubNumbers(s, bought, t)
  t = now_(t)
  local today = L.summary(s, L.since("today", t), bought).income
  local week = L.summary(s, L.since("week", t), bought).income
  local c = L.openCounts(s)
  return today, week, c.sold, c.soldCopper
end

---------------------------------------------------------------------------------------------------------------------
-- Keeping it small: closed records older than KEEP_DAYS go. An outcome whose mail can no longer be in the mailbox
-- (more than 31 days ago) and was never taken is closed as "lapsed" (the mail went back or was deleted).
function L.prune(s, t)
  if not s then return end
  t = now_(t)
  local keep = {}
  for _, r in ipairs(s.auctions) do
    local closed = not L.isOpen(r)
    if not closed and (r.st ~= "listed") and (r.at or t) < t - (L.MAIL_DAYS + 1) * 86400 then
      r.done, r.lapsed = r.done or t, true
      closed = true
    end
    if not (closed and (r.at or t) < t - L.KEEP_DAYS * 86400) then keep[#keep + 1] = r end
  end
  s.auctions = keep
  trim(s.auctions, L.MAX_AUCTIONS)
  local mails = {}
  for _, e in ipairs(s.mails) do
    if not e.exp or e.exp > t - 86400 then mails[#mails + 1] = e end
  end
  s.mails = mails
end

---------------------------------------------------------------------------------------------------------------------
-- Migration of what the AH log kept before the ledger (once; the old tables stay where they are).

function L.migrate(db, s, t)
  if not s or s.migrated then return nil end
  t = now_(t)
  local m = { at = t, income = 0, pending = 0, forSale = {} }
  for _, e in ipairs(type(db.income) == "table" and db.income or {}) do
    local c = tonumber(e.c)
    if c and c > 0 then
      local extra = { h = e.h, name = e.name, item = e.id, q = e.q, gross = e.gross, migrated = true }
      local x
      if e.kind == "sale" then
        extra.why = "from before the ledger: the deposit back may be included"
        x = L.addMoney(s, "sale", c, extra, e.t)
      elseif e.kind == "ah" then
        x = L.addMoney(s, "refund", c, extra, e.t)
      else
        x = L.addMoney(s, "unsorted", c, extra, e.t)
        if x then x.why = "from before the ledger: gold from the mail, its sender wasn't kept (a player, your alt or an NPC?)" end
      end
      if x then x.t = tonumber(e.t) or t; m.income = m.income + 1 end
    end
  end
  for _, e in ipairs(type(db.soldPending) == "table" and db.soldPending or {}) do
    if type(e.name) == "string" and e.name ~= "" then
      local r = adopt(s, { h = e.h, name = e.name, q = e.q }, "sold", "sold before the ledger (from the old waiting list)", e.t)
      r.est = tonumber(e.est)
      m.pending = m.pending + 1
    end
  end
  -- oldest first, as everything else
  table.sort(s.money, function(a, b) return (a.t or 0) < (b.t or 0) end)
  s.migrated = m
  return m
end

-- A character's For sale snapshot (EverlookAuctionsCharDB.forSale) as listed records, once per character.
function L.migrateForSale(s, forSale, ch, t)
  if not s or not ch or type(forSale) ~= "table" or type(forSale.list) ~= "table" then return 0 end
  s.migrated = s.migrated or { at = now_(t) }
  s.migrated.forSale = s.migrated.forSale or {}
  if s.migrated.forSale[ch] then return 0 end
  local n = 0
  for _, a in ipairs(forSale.list) do
    if a.name or a.id then
      adopt(s, { ch = ch, item = a.id, name = a.name, link = a.link, q = a.q, buy = a.c,
        unit = a.c and math.floor(a.c / math.max(1, a.q or 1)) or nil, ends = a.ends }, "listed",
        "listed: from the AH log's For sale list", forSale.at or t)
      n = n + 1
    end
  end
  s.migrated.forSale[ch] = n
  return n
end

-- A character's looted coins from the loot log (EverlookAuctionsCharDB.looted) as "Looted money", once per character.
-- Only real loot (e.loot, not items or gold from the mail).
function L.migrateLoot(s, looted, ch, t)
  if not s or not ch or type(looted) ~= "table" then return 0 end
  s.migrated = s.migrated or { at = now_(t) }
  s.migrated.loot = s.migrated.loot or {}
  if s.migrated.loot[ch] then return 0 end
  local n = 0
  for _, e in ipairs(looted) do
    local c = type(e) == "table" and tonumber(e.copper)
    if c and c > 0 and e.loot and not e.got then
      local x = L.addMoney(s, "loot", c, { ch = ch, zone = e.zone, migrated = true }, e.t)
      if x then x.t = tonumber(e.t) or x.t; n = n + 1 end
    end
  end
  table.sort(s.money, function(a, b) return (a.t or 0) < (b.t or 0) end)
  s.migrated.loot[ch] = n
  return n
end

-- The item ID of a record or entry that only has a name: from another record or entry with the same name.
function L.itemByName(s, name)
  if not s or type(name) ~= "string" then return nil end
  for i = #s.auctions, 1, -1 do
    local r = s.auctions[i]
    if r.item and r.name == name then return r.item end
  end
  for i = #s.money, 1, -1 do
    local e = s.money[i]
    if e.item and e.name == name then return e.item end
  end
end

return L
