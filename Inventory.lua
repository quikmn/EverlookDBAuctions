-- EverlookDB Auctions: what every character of the account has, and where. One store for every EverlookDB addon:
-- this addon's tooltips, Buy this list and Crafting profit read it, EverlookDB Crafting (planning, shopping list,
-- skill-up routes) and EverlookDB Mail read it through the API (EverlookDBAuctionsAPI.inventory, API.lua).
--
-- Saved per account in EverlookAuctionsDB.inv (this PC only, never uploaded):
--   v, chars = { ["Name-<realm ID>"] (the key Gear upgrades uses, UpgradesChars.lua) = {
--     name, realm, realmID, faction, class, at (last seen),
--     money, moneyAt                     gold on the character
--     bags = { [item] = n }, bagsAt      backpack, bags, the reagent bag and the keyring
--     bank = { [item] = n }, bankAt      bank, bank bags and reagent bank, from the last time the bank was open
--     mail = { [item] = n }, mailAt, mailMoney   the mailbox as it was last open (C.O.D. money not counted)
--     incoming = { { t, from, subj, items = { [item] = n }, money } }   sent to this character by mail from another
--                                         of yours and not seen in its mailbox yet (counted as mail)
--     listed = { { id, q, ends } }, listedAt   its auctions, as the auction house last listed them (ended ones drop)
--     worn = { [item] = n }               what it wears (slots 1-19)
--     guild = guild key } }
--   guilds = { ["Guild-<realm ID>"] = { name, realmID, at, tabs = { [tab] = { [item] = n } } } }  the guild bank, per
--     tab, from the last time each tab was looked at
-- Empty places are nil, so a character without a bank visit costs nothing.
--
-- Reading: bags BAG_UPDATE_DELAYED (a second after things settle), the bank while it is open, the mailbox while it is
-- open (MAIL_INBOX_UPDATE), your auctions whenever the auction house lists them, the guild bank's tab on screen,
-- gear on PLAYER_EQUIPMENT_CHANGED, gold on PLAYER_MONEY. Every read waits for a quiet moment and runs once per burst:
-- nothing per frame. Values the game hides (secret values) are skipped and the saved ones kept.
--
-- Counting: only the characters that share this auction house (this realm and faction: they can mail each other).
-- I.count(id) is cached until something changes, so a tooltip costs a table lookup.
local ADDON, ns = ...

local I = { listeners = {}, gen = 0 }
ns.inventory = I

I.VERSION = 1
-- the places of a character, in the order a tooltip names them
I.PLACES = { "bags", "bank", "mail", "listed", "worn" }
I.WORD = { bags = "bags", bank = "bank", mail = "mail", listed = "AH", worn = "worn", guild = "guild bank" }
-- the places that count as having materials (Buy this list, Crafting): not what is up for sale, worn or the guild's
I.USABLE = { bags = true, bank = true, mail = true }
I.TRANSIT = 3700       -- mail between characters takes an hour: after that, a sent mail not in the mailbox was taken
I.INCOMING_DAYS = 30

local isSecret = issecretvalue or function() return false end
local function ok(v)
  if v == nil or isSecret(v) then return nil end
  return v
end
local function try(fn, ...)
  if type(fn) ~= "function" then return nil end
  local res = { pcall(fn, ...) }
  if not res[1] then return nil end
  return unpack(res, 2, table.maxn(res))
end
local function now() return time and time() or 0 end
local function num(v) v = ok(v); return type(v) == "number" and v or nil end
local function text(v) v = ok(v); return type(v) == "string" and v ~= "" and v or nil end

---------------------------------------------------------------------------------------------------------------------
-- The store

function I.store()
  local d = ns.db and ns.db()
  if type(d) ~= "table" then return nil end
  local s = d.inv
  if type(s) ~= "table" then s = { v = I.VERSION }; d.inv = s end
  if type(s.chars) ~= "table" then s.chars = {} end
  if type(s.guilds) ~= "table" then s.guilds = {} end
  return s
end

-- Something changed: the caches go and the listeners hear it (once per batch of reads).
function I.changed()
  I.gen = I.gen + 1
  I.cache, I.itemsCache = nil, nil
  for _, fn in ipairs(I.listeners) do pcall(fn) end
end
function I.onChange(fn) if type(fn) == "function" then I.listeners[#I.listeners + 1] = fn end end

-- This character: its key and saved record (made on first use); nil while the game doesn't say who this is.
local function who()
  if ns.upChars and ns.upChars.who then return ns.upChars.who() end
  local name = text(try(UnitName, "player"))
  local g = text(try(UnitGUID, "player"))
  local id = g and tonumber(g:match("^Player%-(%d+)%-")) or nil
  return name, nil, id
end
local function keyOf(name, realm, realmID)
  if not name or not (realmID or realm) then return nil end
  return name .. "-" .. tostring(realmID or realm)
end
I.keyOf = keyOf

function I.meKey() return keyOf(who()) end

function I.me()
  local s = I.store()
  local name, realm, realmID = who()
  local key = keyOf(name, realm, realmID)
  if not s or not key then return nil, nil end
  local rec = s.chars[key]
  if type(rec) ~= "table" then rec = {}; s.chars[key] = rec end
  rec.name, rec.realmID = name, realmID or rec.realmID
  rec.realm = realm or rec.realm
  local f = text(try(UnitFactionGroup, "player"))
  if f == "Alliance" or f == "Horde" then rec.faction = f end
  local _, class = try(UnitClass, "player")
  class = text(class)
  if class then rec.class = class end
  rec.at = now()
  return rec, key
end

-- Does this character shop at the same auction house as `me` (same realm, same faction)? A record that doesn't say
-- its faction counts (it can't be told apart).
function I.sameHouse(rec, me)
  if type(rec) ~= "table" then return false end
  if not me or rec == me then return true end
  local same = true
  if me.realmID and rec.realmID then same = me.realmID == rec.realmID
  elseif me.realm and rec.realm then same = me.realm == rec.realm end
  if same and me.faction and rec.faction and me.faction ~= rec.faction then same = false end
  return same
end

-- The characters counted from here: { { key, rec, me } }, you first.
function I.chars()
  local s = I.store()
  if not s then return {} end
  local meKey = I.meKey()
  local me = meKey and s.chars[meKey]
  local out = {}
  for key, rec in pairs(s.chars) do
    if type(rec) == "table" and I.sameHouse(rec, me) then
      out[#out + 1] = { key = key, rec = rec, me = key == meKey }
    end
  end
  table.sort(out, function(a, b)
    if a.me ~= b.me then return a.me end
    return tostring(a.rec.name or a.key) < tostring(b.rec.name or b.key)
  end)
  return out, me
end

-- How many of an item a character has in one place.
function I.placeCount(rec, place, id, t)
  if place == "listed" then
    local n = 0
    t = t or now()
    for _, a in ipairs(rec.listed or {}) do
      if a.id == id and (not a.ends or a.ends > t) then n = n + (a.q or 1) end
    end
    return n
  end
  local n = (type(rec[place]) == "table" and rec[place][id]) or 0
  if place == "mail" then
    for _, e in ipairs(rec.incoming or {}) do n = n + ((e.items or {})[id] or 0) end
  end
  return n
end

local function guildCount(g, id)
  local n = 0
  for _, tab in pairs(g.tabs or {}) do n = n + (tab[id] or 0) end
  return n
end

-- Every holder of an item: { id, total (your characters), mine, alts, guild, chars = { { key, name, class, me, total,
-- bags, bank, mail, listed, worn } } (you first, then the most), guilds = { { key, name, n } } }. Cached until the
-- next change; callers must not change it (the API hands out copies).
function I.count(id)
  id = tonumber(id)
  if not id then return nil end
  I.cache = I.cache or {}
  local hit = I.cache[id]
  if hit then return hit end
  local res = { id = id, total = 0, mine = 0, alts = 0, guild = 0, chars = {}, guilds = {} }
  local list, me = I.chars()
  local t = now()
  for _, c in ipairs(list) do
    local e = { key = c.key, name = c.rec.name or c.key, class = c.rec.class, me = c.me, total = 0 }
    for _, p in ipairs(I.PLACES) do
      local n = I.placeCount(c.rec, p, id, t)
      e[p] = n
      e.total = e.total + n
    end
    if e.total > 0 or c.me then res.chars[#res.chars + 1] = e end
    res.total = res.total + e.total
    if c.me then res.mine = e.total else res.alts = res.alts + e.total end
  end
  local s = I.store()
  for key, g in pairs(s and s.guilds or {}) do
    if type(g) == "table" and I.sameHouse(g, me and { realmID = me.realmID, realm = me.realm }) then
      local n = guildCount(g, id)
      if n > 0 then
        res.guilds[#res.guilds + 1] = { key = key, name = g.name or key, n = n }
        res.guild = res.guild + n
      end
    end
  end
  table.sort(res.chars, function(a, b)
    if a.me ~= b.me then return a.me end
    if a.total ~= b.total then return a.total > b.total end
    return tostring(a.name) < tostring(b.name)
  end)
  table.sort(res.guilds, function(a, b) return a.n > b.n end)
  I.cache[id] = res
  return res
end

-- What counts as having it for buying and crafting: bags, bank and mail (incoming too); your alts' as well unless
-- withAlts is false.
function I.usable(id, withAlts)
  local r = I.count(id)
  if not r then return 0 end
  local n = 0
  for _, e in ipairs(r.chars) do
    if e.me or withAlts ~= false then n = n + e.bags + e.bank + e.mail end
  end
  return n
end

-- Every item in usable places: { [item] = n } (your alts' too unless withAlts is false).
function I.owned(withAlts)
  local out = {}
  local list = I.chars()
  for _, c in ipairs(list) do
    if c.me or withAlts ~= false then
      for place in pairs(I.USABLE) do
        for id, n in pairs(c.rec[place] or {}) do out[id] = (out[id] or 0) + n end
      end
      for _, e in ipairs(c.rec.incoming or {}) do
        for id, n in pairs(e.items or {}) do out[id] = (out[id] or 0) + n end
      end
    end
  end
  return out
end

-- Every item anyone here holds anywhere (the "Where is it?" search's rows): { [item] = true }.
function I.items()
  if I.itemsCache then return I.itemsCache end
  local out = {}
  local list, me = I.chars()
  local t = now()
  for _, c in ipairs(list) do
    for _, p in ipairs({ "bags", "bank", "mail", "worn" }) do
      for id in pairs(c.rec[p] or {}) do out[id] = true end
    end
    for _, e in ipairs(c.rec.incoming or {}) do for id in pairs(e.items or {}) do out[id] = true end end
    for _, a in ipairs(c.rec.listed or {}) do if not a.ends or a.ends > t then out[a.id] = true end end
  end
  local s = I.store()
  for _, g in pairs(s and s.guilds or {}) do
    if type(g) == "table" and I.sameHouse(g, me and { realmID = me.realmID, realm = me.realm }) then
      for _, tab in pairs(g.tabs or {}) do for id in pairs(tab) do out[id] = true end end
    end
  end
  I.itemsCache = out
  return out
end

-- One column of the query language for an item (Search.lua): have (your characters), mine, alts, bags, bank, mail,
-- listed, worn, guildbank, char (who holds it, "Mara, Thorn") and place (where: "bags, bank").
function I.column(id, col)
  local r = I.count(id)
  if not r then return (col == "char" or col == "place") and "" or 0 end
  if col == "have" then return r.total end
  if col == "mine" then return r.mine end
  if col == "alts" then return r.alts end
  if col == "guildbank" then return r.guild end
  if col == "char" then
    local names = {}
    for _, e in ipairs(r.chars) do if e.total > 0 then names[#names + 1] = e.name end end
    return table.concat(names, ", ")
  end
  if col == "place" then
    local words = {}
    for _, p in ipairs(I.PLACES) do
      local n = 0
      for _, e in ipairs(r.chars) do n = n + (e[p] or 0) end
      if n > 0 then words[#words + 1] = p end
    end
    if r.guild > 0 then words[#words + 1] = "guildbank" end
    return table.concat(words, ", ")
  end
  local n = 0
  for _, e in ipairs(r.chars) do n = n + (e[col] or 0) end
  return n
end

-- Gold: total, { { key, name, class, me, money, mail (waiting in the mailbox and on its way), at } } (most first).
function I.gold()
  local total, out = 0, {}
  for _, c in ipairs((I.chars())) do
    local m = c.rec.money
    if m then
      local mail = c.rec.mailMoney or 0
      for _, e in ipairs(c.rec.incoming or {}) do mail = mail + (e.money or 0) end
      out[#out + 1] = { key = c.key, name = c.rec.name or c.key, class = c.rec.class, me = c.me, money = m, mail = mail,
        at = c.rec.moneyAt }
      total = total + m + mail
    end
  end
  table.sort(out, function(a, b)
    if a.money + a.mail ~= b.money + b.mail then return a.money + a.mail > b.money + b.mail end
    return tostring(a.name) < tostring(b.name)
  end)
  return total, out
end

-- Forgets a character's items (Gear upgrades' Forget does it too).
function I.forget(key)
  local s = I.store()
  if not s or not key or key == I.meKey() or not s.chars[key] then return false end
  s.chars[key] = nil
  I.changed()
  return true
end

---------------------------------------------------------------------------------------------------------------------
-- Reading the game

local function containerSlots(bag)
  if C_Container and C_Container.GetContainerNumSlots then return num(try(C_Container.GetContainerNumSlots, bag)) or 0 end
  return num(try(GetContainerNumSlots, bag)) or 0
end
-- id and count in a slot; nil for an empty slot, false when the game hides it (secret)
local function containerItem(bag, slot)
  if C_Container and C_Container.GetContainerItemInfo then
    local info = try(C_Container.GetContainerItemInfo, bag, slot)
    if info == nil then return nil end
    if type(info) ~= "table" then return false end
    local id, n = ok(info.itemID), ok(info.stackCount)
    if id == nil then return false end
    return id, n or 1
  end
  local _, n, _, _, _, _, _, _, _, id = try(GetContainerItemInfo, bag, slot)
  if id == nil then return nil end
  id, n = ok(id), ok(n)
  if not id then return false end
  return id, n or 1
end

function I.bagIDs()
  local n = tonumber(NUM_BAG_SLOTS) or 4
  local r = tonumber(NUM_REAGENTBAG_SLOTS) or 1
  local bags = {}
  for b = 0, n + r do bags[#bags + 1] = b end
  bags[#bags + 1] = tonumber(KEYRING_CONTAINER) or -2
  local bank = { tonumber(BANK_CONTAINER) or -1 }
  for b = n + r + 1, n + r + (tonumber(NUM_BANKBAGSLOTS) or 7) do bank[#bank + 1] = b end
  bank[#bank + 1] = tonumber(REAGENTBANK_CONTAINER) or -3
  return bags, bank
end

-- { [item] = n } for some bags, or nil when the game hid a slot (the saved count stays then).
function I.countBags(list)
  local out, any = {}, false
  for _, bag in ipairs(list) do
    for slot = 1, containerSlots(bag) do
      local id, n = containerItem(bag, slot)
      if id == false then return nil end
      if id then out[id] = (out[id] or 0) + n; any = true end
    end
  end
  return any and out or nil, true
end

local function readBags(rec)
  local bags = I.bagIDs()
  local t, done = I.countBags(bags)
  if t or done then rec.bags, rec.bagsAt = t, now() end
end
local function readBank(rec)
  local _, bank = I.bagIDs()
  local t, done = I.countBags(bank)
  if t or done then rec.bank, rec.bankAt = t, now() end
end
local function readWorn(rec)
  local out, any = {}, false
  for slot = 1, 19 do
    local okI, id = pcall(GetInventoryItemID, "player", slot)
    if okI then
      if isSecret(id) then return end
      if type(id) == "number" then out[id] = (out[id] or 0) + 1; any = true end
    end
  end
  rec.worn = any and out or nil
end
local function readMoney(rec)
  local m = num(try(GetMoney))
  if m then rec.money, rec.moneyAt = m, now() end
end

-- The mailbox, read by the shared mail classifier (MailClassify.lua): items, money (not C.O.D.), and what was
-- sent to this character and has arrived (taken off incoming).
function I.readMailList(rec, list, t)
  t = t or now()
  local items, money = {}, 0
  local any = false
  local seen = {}
  for _, m in ipairs(list or {}) do
    if type(m) == "table" then
      if (m.cod or 0) == 0 then money = money + (tonumber(m.money) or 0) end
      for _, it in ipairs(m.items or {}) do
        if it.id and not it.currency then items[it.id] = (items[it.id] or 0) + (it.count or 1); any = true end
      end
      local from = m.sender and (tostring(m.sender):match("^([^%-]+)") or m.sender)
      if from then seen[from:lower() .. "\0" .. tostring(m.subject or "")] = true end
    end
  end
  rec.mail, rec.mailMoney, rec.mailAt = any and items or nil, money > 0 and money or nil, t
  -- sent from another of your characters: here now (in the list), or taken already (an hour gone), else on its way
  if rec.incoming then
    local keep = {}
    for _, e in ipairs(rec.incoming) do
      local k = tostring(e.from or ""):lower() .. "\0" .. tostring(e.subj or "")
      if not seen[k] and t - (e.t or 0) < I.TRANSIT then keep[#keep + 1] = e end
    end
    rec.incoming = #keep > 0 and keep or nil
  end
end

local function classifier() return LibStub and LibStub("EverlookMailClassify-1", true) end
local function readMail(rec)
  local C = classifier()
  if not C or not C.scan then return end
  local okS, list = pcall(C.scan)
  if okS and type(list) == "table" then I.readMailList(rec, list) end
end

-- Your auctions as the auction house listed them (Sell.lua -> Purchases.noteOwned): { itemID, qty, sold, left }.
function I.noteOwned(owned, t)
  local rec = I.me()
  if not rec or type(owned) ~= "table" then return end
  t = t or now()
  local out = {}
  for _, a in ipairs(owned) do
    local id = tonumber(ok(a.itemID))
    if id and not a.sold then
      out[#out + 1] = { id = id, q = tonumber(ok(a.qty)) or 1, ends = tonumber(ok(a.left)) and (t + a.left) or nil }
    end
  end
  rec.listed, rec.listedAt = #out > 0 and out or nil, t
  I.changed()
end

-- A sale the game told you about ("A buyer has been found for your auction of X."): that auction is gone.
function I.sold(name)
  local rec = I.me()
  if not rec or type(name) ~= "string" or not rec.listed then return end
  for i, a in ipairs(rec.listed) do
    local n = C_Item and try(C_Item.GetItemNameByID, a.id)
    if n == name then
      table.remove(rec.listed, i)
      if #rec.listed == 0 then rec.listed = nil end
      I.changed()
      return true
    end
  end
end

-- Mail sent to another of your characters: what goes out, read as SendMail is called; it counts once the game says
-- it was sent.
local pendingSend
function I.sending(to, subject, items, money)
  local short = type(to) == "string" and (to:match("^%s*([^%-%s]+)") or to) or nil
  if not short or short == "" then pendingSend = nil; return end
  pendingSend = { to = short, subj = subject, items = items, money = money }
end
function I.sent(t)
  local p = pendingSend
  pendingSend = nil
  if not p then return end
  local list, me = I.chars()
  for _, c in ipairs(list) do
    if not c.me and type(c.rec.name) == "string" and c.rec.name:lower() == p.to:lower() then
      local any = (p.money or 0) > 0 or next(p.items or {}) ~= nil
      if not any then return end
      c.rec.incoming = c.rec.incoming or {}
      table.insert(c.rec.incoming, { t = t or now(), from = me and me.name, subj = p.subj or "",
        items = next(p.items or {}) and p.items or nil, money = (p.money or 0) > 0 and p.money or nil })
      -- an old one that never got read (the alt hasn't been on for a month): gone
      local cut = (t or now()) - I.INCOMING_DAYS * 86400
      for i = #c.rec.incoming, 1, -1 do if (c.rec.incoming[i].t or 0) < cut then table.remove(c.rec.incoming, i) end end
      I.changed()
      return c.key
    end
  end
end
function I.sendFailed() pendingSend = nil end

local function readSendMail()
  local items = {}
  for a = 1, tonumber(ATTACHMENTS_MAX_SEND) or 12 do
    local _, id, _, count = try(GetSendMailItem, a)
    id, count = tonumber(ok(id)), tonumber(ok(count))
    if id then items[id] = (items[id] or 0) + (count or 1) end
  end
  local cod = num(try(GetSendMailCOD)) or 0
  local money = cod > 0 and 0 or (num(try(GetSendMailMoney)) or 0)
  return items, money
end

-- The guild bank tab on screen: { [item] = n }, or nil when the game hides something.
local function readGuildTab()
  if type(GetCurrentGuildBankTab) ~= "function" or type(GetGuildBankItemInfo) ~= "function" then return end
  local tab = num(try(GetCurrentGuildBankTab))
  if not tab then return end
  local out = {}
  for slot = 1, tonumber(MAX_GUILDBANK_SLOTS_PER_TAB) or 98 do
    local link = try(GetGuildBankItemLink, tab, slot)
    if isSecret(link) then return end
    if type(link) == "string" then
      local id = tonumber(link:match("item:(%d+)"))
      local _, count = try(GetGuildBankItemInfo, tab, slot)
      count = num(count)
      if id then out[id] = (out[id] or 0) + (count or 1) end
    end
  end
  return tab, out
end
local function readGuild(rec)
  local gname = text(try(GetGuildInfo, "player"))
  if not gname or not rec.realmID and not rec.realm then return end
  local tab, items = readGuildTab()
  if not tab then return end
  local s = I.store()
  local key = gname .. "-" .. tostring(rec.realmID or rec.realm)
  local g = type(s.guilds[key]) == "table" and s.guilds[key] or { tabs = {} }
  s.guilds[key] = g
  g.name, g.realmID, g.realm, g.faction, g.at = gname, rec.realmID, rec.realm, rec.faction, now()
  g.tabs = g.tabs or {}
  g.tabs[tab] = next(items) and items or nil
  rec.guild = key
end

-- EverlookDB Crafting counted bags and bank before this store did: its characters this store hasn't seen yet start
-- with what it knew (once each; the next login of that character reads the real thing).
function I.seed(cdb)
  local s = I.store()
  cdb = cdb or rawget(_G, "EverlookCraftDB")
  if not s or type(cdb) ~= "table" or type(cdb.chars) ~= "table" then return 0 end
  local n = 0
  for _, c in pairs(cdb.chars) do
    local key = type(c) == "table" and keyOf(text(c.name), text(c.realm), tonumber(c.realmID))
    if key and not s.chars[key] and (next(c.bags or {}) or next(c.bank or {})) then
      local rec = { name = c.name, realm = c.realm, realmID = tonumber(c.realmID), class = c.class, seeded = true,
        faction = (c.side == "a" and "Alliance") or (c.side == "h" and "Horde") or nil }
      local function copy(t)
        if type(t) ~= "table" or not next(t) then return nil end
        local o = {}
        for id, v in pairs(t) do if tonumber(id) and tonumber(v) then o[tonumber(id)] = tonumber(v) end end
        return next(o) and o or nil
      end
      rec.bags, rec.bagsAt = copy(c.bags), c.bagsAt
      rec.bank, rec.bankAt = copy(c.bank), c.bankAt
      s.chars[key] = rec
      n = n + 1
    end
  end
  if n > 0 then I.changed() end
  return n
end

---------------------------------------------------------------------------------------------------------------------
-- Events: every read waits for a quiet moment, and a burst of events is one read

local dirty, queued = {}, false
I.bankOpen, I.mailOpen, I.guildOpen = false, false, false

function I.flush()
  queued = false
  local d = dirty
  dirty = {}
  local rec = I.me()
  if not rec then return end
  if d.bags then readBags(rec) end
  if d.bank and I.bankOpen then readBank(rec) end
  if d.worn then readWorn(rec) end
  if d.money then readMoney(rec) end
  if d.mail and I.mailOpen then readMail(rec) end
  if d.guild and I.guildOpen then readGuild(rec) end
  I.changed()
end

function I.mark(what, delay)
  dirty[what] = true
  if queued then return end
  queued = true
  if C_Timer and C_Timer.After then C_Timer.After(delay or 1, I.flush) else I.flush() end
end

local SOLD = (function()
  local f = ERR_AUCTION_SOLD_S or "A buyer has been found for your auction of %s."
  return "^" .. f:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1"):gsub("%%%%s", "(.+)") .. "$"
end)()

if CreateFrame then
  local ev = CreateFrame("Frame")
  local EVENTS = { "PLAYER_LOGIN", "PLAYER_ENTERING_WORLD", "PLAYER_LOGOUT", "BAG_UPDATE_DELAYED", "PLAYER_MONEY",
    "PLAYER_EQUIPMENT_CHANGED", "BANKFRAME_OPENED", "BANKFRAME_CLOSED", "PLAYERBANKSLOTS_CHANGED",
    "PLAYERREAGENTBANKSLOTS_CHANGED", "MAIL_SHOW", "MAIL_CLOSED", "MAIL_INBOX_UPDATE", "MAIL_SEND_SUCCESS",
    "MAIL_FAILED", "GUILDBANKFRAME_OPENED", "GUILDBANKFRAME_CLOSED", "GUILDBANKBAGSLOTS_CHANGED", "CHAT_MSG_SYSTEM" }
  for _, e in ipairs(EVENTS) do pcall(ev.RegisterEvent, ev, e) end
  ev:SetScript("OnEvent", function(_, e, a1)
    if e == "PLAYER_LOGIN" then
      pcall(I.seed)
      I.mark("bags", 3); I.mark("worn"); I.mark("money")
    elseif e == "PLAYER_ENTERING_WORLD" then
      I.mark("bags", 3); I.mark("worn"); I.mark("money")
    elseif e == "PLAYER_LOGOUT" then
      local rec = I.me()
      if rec then pcall(readBags, rec); pcall(readMoney, rec); pcall(readWorn, rec) end
    elseif e == "BAG_UPDATE_DELAYED" then
      I.mark("bags")
      if I.bankOpen then I.mark("bank") end
    elseif e == "PLAYER_MONEY" then I.mark("money")
    elseif e == "PLAYER_EQUIPMENT_CHANGED" then I.mark("worn")
    elseif e == "BANKFRAME_OPENED" then I.bankOpen = true; I.mark("bank", 0.5)
    elseif e == "BANKFRAME_CLOSED" then I.bankOpen = false
    elseif e == "PLAYERBANKSLOTS_CHANGED" or e == "PLAYERREAGENTBANKSLOTS_CHANGED" then
      if I.bankOpen then I.mark("bank", 0.5) end
    elseif e == "MAIL_SHOW" then I.mailOpen = true; I.mark("mail", 0.5)
    elseif e == "MAIL_CLOSED" then I.mailOpen = false
    elseif e == "MAIL_INBOX_UPDATE" then if I.mailOpen then I.mark("mail", 0.5) end
    elseif e == "MAIL_SEND_SUCCESS" then I.sent()
    elseif e == "MAIL_FAILED" then I.sendFailed()
    elseif e == "GUILDBANKFRAME_OPENED" then I.guildOpen = true; I.mark("guild", 0.5)
    elseif e == "GUILDBANKFRAME_CLOSED" then I.guildOpen = false
    elseif e == "GUILDBANKBAGSLOTS_CHANGED" then if I.guildOpen then I.mark("guild", 0.5) end
    elseif e == "CHAT_MSG_SYSTEM" then
      local msg = ok(a1)
      local name = type(msg) == "string" and msg:match(SOLD)
      if name then I.sold(name) end
    end
  end)
end

-- What goes out by mail, read while it is still on the send form (the game clears it once it is sent).
if hooksecurefunc and type(SendMail) == "function" then
  hooksecurefunc("SendMail", function(to, subject)
    local okR, items, money = pcall(readSendMail)
    if okR then I.sending(ok(to), ok(subject), items, money) end
  end)
end
-- your auctions: each time the auction house lists them (Sell.lua hands them to Purchases.noteOwned)
if hooksecurefunc and ns.purchases and type(ns.purchases.noteOwned) == "function" then
  hooksecurefunc(ns.purchases, "noteOwned", function(owned) pcall(I.noteOwned, owned) end)
end
-- Gear upgrades' Forget forgets the character's items too
if ns.upChars and type(ns.upChars.forget) == "function" then
  local forget = ns.upChars.forget
  ns.upChars.forget = function(key)
    local r = forget(key)
    if r then pcall(I.forget, key) end
    return r
  end
end
