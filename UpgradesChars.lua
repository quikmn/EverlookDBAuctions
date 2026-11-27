-- EverlookDB Auctions: the characters of the account, for Gear upgrades ("upgrades for one of my alts").
--   Saved     per account (db.up.chars, keyed "Name-<realm ID>"): name, realm, faction, class, level, race, the
--             links of what each one wears (inventory slots 1-19), its talent ranks, and the spec last picked for it
--             on the Gear upgrades page. Written at login, when the gear or level changes, and at logout; values the
--             game hides (secret values) are skipped and the old ones kept.
--   Listed    the characters of this realm and faction (the ones that shop at this auction house): you first, then
--             by level. An alt shows up once it has logged in with this version.
--   Context   C.ctx(key): what Upgrades.lua scores with (U.ctx) for another character: its class, level, gear,
--             talents and weight picks. Nothing about other players is read or saved.
local ADDON, ns = ...
local U = ns.up

local C = {}
ns.upChars = C

local isSecret = issecretvalue or function() return false end
local function ok(v)
  if v == nil or isSecret(v) then return nil end
  return v
end
local function call(fn, ...)
  if type(fn) ~= "function" then return nil end
  local res = { pcall(fn, ...) }
  if not res[1] then return nil end
  return unpack(res, 2, table.maxn(res))
end
local function now() return time and time() or 0 end

function C.all()
  local d = U.db()
  if not d then return {} end
  if type(d.chars) ~= "table" then d.chars = {} end
  return d.chars
end

-- This character: name, realm name, realm ID (each nil while the game doesn't say).
function C.who()
  local name = ok(call(UnitName, "player"))
  if type(name) ~= "string" or name == "" then name = nil end
  local realm, realmID
  if ns.realmInfo then
    local okR, n, id = pcall(ns.realmInfo)
    if okR then realm, realmID = ok(n), ok(id) end
  end
  if type(realm) ~= "string" or realm == "" then realm = nil end
  if type(realmID) ~= "number" or realmID <= 0 then realmID = nil end
  return name, realm, realmID
end

local function keyOf(name, realm, realmID)
  if not name or not (realmID or realm) then return nil end
  return name .. "-" .. tostring(realmID or realm)
end

function C.meKey() return keyOf(C.who()) end

-- Reads this character into its saved record. level: the new level (PLAYER_LEVEL_UP says it before UnitLevel does).
-- atLogout: by then the game has often taken the gear off already (every slot reads empty), and saving that wiped
-- every alt's gear (2026-11-27); an empty read at logout keeps the gear read during play.
-- Returns the record, or nil while the game doesn't say who this is.
function C.record(level, atLogout)
  local name, realm, realmID = C.who()
  local key = keyOf(name, realm, realmID)
  if not key then return nil end
  local all = C.all()
  local rec = type(all[key]) == "table" and all[key] or {}
  all[key] = rec
  rec.name, rec.realmID = name, realmID or rec.realmID
  rec.realm = realm or rec.realm
  local _, class, classID = call(UnitClass, "player")
  class, classID = ok(class), ok(classID)
  if type(class) == "string" and class ~= "" then rec.class = class end
  if type(classID) == "number" then rec.classID = classID end
  local _, race = call(UnitRace, "player")
  race = ok(race)
  if type(race) == "string" and race ~= "" then rec.race = race end
  local faction = ok(call(UnitFactionGroup, "player"))
  if faction == "Alliance" or faction == "Horde" then rec.faction = faction end
  level = tonumber(ok(level)) or tonumber(ok(call(UnitLevel, "player")))
  if level and level > 0 then rec.level = level end
  -- the gear: a slot the game hides keeps what was saved; an empty slot is empty
  local items = type(rec.items) == "table" and rec.items or {}
  local read, wears = {}, false
  for slot = 1, 19 do
    local okL, link = pcall(GetInventoryItemLink, "player", slot)
    if okL then
      if link == nil then
        -- an item the game hasn't loaded yet has an ID but no link: keep what was saved
        local okI, id = pcall(GetInventoryItemID, "player", slot)
        if okI and id ~= nil then wears = true else read[slot] = false end
      elseif not isSecret(link) and type(link) == "string" then
        read[slot] = link
        wears = true
      else
        wears = true
      end
    end
  end
  if wears or not atLogout then
    for slot, v in pairs(read) do items[slot] = v or nil end
  end
  rec.items = items
  -- talents: only the ranks taken, to keep it small
  if U.readTalents then
    local t = {}
    local okT, ranks = pcall(U.readTalents)
    if okT and type(ranks) == "table" then
      for k, v in pairs(ranks) do
        if type(v) == "number" and v > 0 and not isSecret(k) then t[k] = v end
      end
      if next(t) or not rec.talents then rec.talents = t end
    end
  end
  -- this character's spec on the page lives in its own settings; kept here too
  local c = U.char and U.char()
  if c and c.shown then rec.shown = c.shown end
  rec.at = now()   -- "Gear as of 2 h ago"
  return rec
end

-- The characters that shop at this auction house: this realm and faction. You first, then by level, then name.
-- Each { key, name, class, level, me, at, rec }.
function C.list()
  local meKey = C.meKey()
  local all = C.all()
  if meKey and not all[meKey] then C.record() end
  local me = meKey and all[meKey]
  local out = {}
  for key, rec in pairs(all) do
    if type(rec) == "table" then
      local same = true
      if me and key ~= meKey then
        if me.realmID and rec.realmID then same = me.realmID == rec.realmID
        elseif me.realm and rec.realm then same = me.realm == rec.realm end
        if same and me.faction and rec.faction and me.faction ~= rec.faction then same = false end
      end
      if same and rec.class then
        out[#out + 1] = { key = key, name = rec.name or key, class = rec.class, level = rec.level, me = key == meKey,
          at = rec.at, rec = rec }
      end
    end
  end
  table.sort(out, function(a, b)
    if a.me ~= b.me then return a.me end
    if (a.level or 0) ~= (b.level or 0) then return (a.level or 0) > (b.level or 0) end
    return tostring(a.name) < tostring(b.name)
  end)
  return out
end

-- Forgets a character (never the one you play). Returns true when one was forgotten.
function C.forget(key)
  if not key or key == C.meKey() then return false end
  local all = C.all()
  if not all[key] then return false end
  all[key] = nil
  C.contexts[key] = nil
  return true
end

-- The spec last picked for a character on the Gear upgrades page.
function C.shown(key)
  local rec = key and C.all()[key]
  return rec and rec.shown
end
function C.setShown(key, spec)
  local rec = key and C.all()[key]
  if rec then rec.shown = spec end
end

-- What Upgrades.lua scores with for another character (U.ctx); nil for you or a character not saved. The same
-- table while the record is unchanged (its worn gear is read once).
C.contexts = {}
function C.ctx(key)
  if not key or key == C.meKey() then return nil end
  local rec = C.all()[key]
  if type(rec) ~= "table" or not rec.class then return nil end
  local hit = C.contexts[key]
  if hit and hit.rec == rec and hit.at == rec.at then return hit end
  rec.profile = type(rec.profile) == "table" and rec.profile or {}
  local ctx = { key = key, name = rec.name, class = rec.class, classID = rec.classID, level = rec.level or 1,
    items = rec.items or {}, talents = rec.talents, profile = rec.profile, rec = rec, at = rec.at }
  C.contexts[key] = ctx
  return ctx
end

-- "Thrall" in its class colour.
function C.colored(name, class)
  local cc = type(class) == "string" and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
  local hex = "e8eaef"
  if cc and cc.r then hex = ("%02x%02x%02x"):format(math.floor(cc.r * 255 + 0.5), math.floor(cc.g * 255 + 0.5), math.floor(cc.b * 255 + 0.5)) end
  return "|cff" .. hex .. tostring(name or "?") .. "|r"
end

-- Events: login, gear, level, talents, logout. A burst of gear changes is read once.
if CreateFrame then
  local ev = CreateFrame("Frame")
  for _, e in ipairs({ "PLAYER_LOGIN", "PLAYER_ENTERING_WORLD", "PLAYER_EQUIPMENT_CHANGED", "PLAYER_LEVEL_UP",
      "CHARACTER_POINTS_CHANGED", "TRAIT_CONFIG_UPDATED", "PLAYER_LOGOUT" }) do
    pcall(ev.RegisterEvent, ev, e)
  end
  local queued = false
  local function later(delay)
    if queued then return end
    queued = true
    C_Timer.After(delay, function() queued = false; pcall(C.record) end)
  end
  ev:SetScript("OnEvent", function(_, e, a)
    if e == "PLAYER_LOGOUT" then
      pcall(C.record, nil, true)
    elseif e == "PLAYER_LEVEL_UP" then
      pcall(C.record, a)
    elseif e == "PLAYER_LOGIN" or e == "PLAYER_ENTERING_WORLD" then
      later(3)   -- the gear and realm are there a moment after login
    else
      later(0.5)
    end
  end)
end
