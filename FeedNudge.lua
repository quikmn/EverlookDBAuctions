-- EverlookDB Auctions: a gentle offer to reload for newer Price Feed prices.
--
-- The EverlookDB App writes the Price Feed (EverlookDBAuctions_Shared) whenever a house's prices change, about once
-- an hour, but the game reads that file only at login and /reload. So after a while in game the prices shown are
-- older than the ones on disk. This offers a reload, quietly:
--   * the line: one small "Prices: 3 h old · Reload (1 s)" under the minimap, only at a calm moment (out of combat,
--     not in an instance, no group member fighting, not typing, casting or on a flight) when resting in an inn or a
--     city, or just after a mailbox, a vendor, the auction house, a flight landing or a loading screen. At most once
--     an hour; the x (or right-click) keeps it away for 2 hours; it goes by itself after a minute and at once when a
--     fight starts. A click reloads (ReloadUI from the click).
--   * the minimap button: a small dot while the prices are that old, its tooltip says so, Shift-click reloads.
--   * the auction house's bar: a quiet Reload button beside Update prices.
--   * item tooltips: "/reload for newer prices" under the price, only while Shift is held.
-- Only when the prices shown come from the feed (not a newer scan of your own), the feed has this auction house, the
-- loaded copy is older than the setting (90 min), and the app looks like it is running: a copy already 6 hours old at
-- login means it isn't, and a reload that brought the same copy back keeps everything quiet for 2 hours. The addon
-- can't see the disk, so it says "may be newer".
-- Settings (General): "reloadhint" on/off, "reloadafter" the age in minutes. Saved in db.nudge.
local _, ns = ...

local N = {}
ns.feedNudge = N

N.DEFAULT_MINUTES = 90
N.CHOICES = { 60, 90, 120, 180, 360 }
N.EVERY = 3600          -- the line at most once an hour
N.QUIET = 2 * 3600      -- after the x, or after a reload that brought nothing new
N.SESSION = 15 * 60     -- no offer in the first 15 minutes after a login or reload
N.DEAD = 6 * 3600       -- a copy this old at login: the app isn't writing
N.SHOW_FOR = 60         -- the line goes by itself after a minute
N.MOMENT_FOR = 90       -- how long a mailbox, vendor, landing or loading screen counts as a calm place
N.loaded = time()       -- when this copy of the feed was read (the addon loads with it)

local momentTill = 0
local frame             -- the line, made the first time it shows
local hideAt

local function db()
  local d = ns.db and ns.db()
  if type(d) ~= "table" then return nil end
  return d
end

local function state()
  local d = db()
  if not d then return {} end
  d.nudge = type(d.nudge) == "table" and d.nudge or {}
  return d.nudge
end

local function call(f, ...)
  if type(f) ~= "function" then return nil end
  local okC, a, b = pcall(f, ...)
  if okC then return a, b end
  return nil
end

function N.on()
  local d = db()
  return not (d and d.reloadNudge == false)
end

-- The age setting in minutes (one of N.CHOICES).
function N.minutes()
  local d = db()
  local m = d and tonumber(d.reloadAfter)
  for _, c in ipairs(N.CHOICES) do if c == m then return m end end
  return N.DEFAULT_MINUTES
end

-- "3 h old", "75 min old"
function N.ageText(secs)
  local S = ns.shared
  if S and S.oldText then return S.oldText(time() - secs) end
  return math.floor(secs / 60 + 0.5) .. " min old"
end

-- How old the prices shown are, in seconds, when newer ones may be waiting in the feed; else nil and why not.
function N.stale(now)
  now = now or time()
  if not N.on() then return nil, "off" end
  local S = ns.shared
  if not (S and S.enabled and S.enabled() and S.state() == "on") then return nil, "nofeed" end
  local hk = ns.houseOrFaction and ns.houseOrFaction()
  if not (hk and S.house(hk)) then return nil, "nohouse" end
  local at, shared = nil, false
  if ns.pricesAt then at, shared = ns.pricesAt() end
  if not at or not shared then return nil, "own" end          -- a scan of your own is newer: nothing to fetch
  local limit = N.minutes() * 60
  local age = now - at
  if age < limit then return nil, "fresh" end
  local copy = S.copyAt and S.copyAt() or at
  if now - copy < limit then return nil, "fresh" end
  if N.loaded - copy > N.DEAD then return nil, "appidle" end   -- already old at login: the app isn't running
  if now - N.loaded < N.SESSION then return nil, "justloaded" end
  if (state().nothingTill or 0) > now then return nil, "nothingnew" end
  return age
end

-- A place where a reload doesn't hurt: resting (inn, city), or just after a mailbox, vendor, the auction house, a
-- flight landing or a loading screen.
local function groupFighting()
  if not (IsInGroup and call(IsInGroup)) then return false end
  local raid = IsInRaid and call(IsInRaid)
  local n = (GetNumGroupMembers and call(GetNumGroupMembers)) or 0
  for i = 1, math.min(n, 40) do
    local unit = raid and ("raid" .. i) or ("party" .. i)
    if call(UnitAffectingCombat, unit) then return true end
  end
  return false
end

-- Whether now is a calm moment, and why not.
function N.calm(now)
  now = now or time()
  if (InCombatLockdown and call(InCombatLockdown)) or call(UnitAffectingCombat, "player") then return false, "combat" end
  if IsInInstance and call(IsInInstance) then return false, "instance" end
  if groupFighting() then return false, "group" end
  if call(UnitIsDeadOrGhost, "player") then return false, "dead" end
  if call(UnitOnTaxi, "player") then return false, "flying" end
  if call(UnitCastingInfo, "player") or call(UnitChannelInfo, "player") then return false, "casting" end
  if GetCurrentKeyBoardFocus and call(GetCurrentKeyBoardFocus) then return false, "typing" end
  if ns.house and ns.house() then return false, "auctionhouse" end   -- the bar there has its own Reload button
  if not ((IsResting and call(IsResting)) or momentTill > now) then return false, "place" end
  return true
end

-- Whether the line may show now (rate limits and the x).
function N.allowed(now)
  now = now or time()
  local s = state()
  if (s.quietTill or 0) > now then return false, "dismissed" end
  if s.shown and now - s.shown < N.EVERY then return false, "hourly" end
  return true
end

-- A mailbox, a vendor, a flight landing, a loading screen: a calm place for a little while.
function N.moment(now)
  momentTill = (now or time()) + N.MOMENT_FOR
end

function N.shown() return frame ~= nil and frame:IsShown() end

---------------------------------------------------------------------------------------------------------------------
-- The line

local function anchor(f)
  f:ClearAllPoints()
  local p = state().pos
  if type(p) == "table" and type(p[1]) == "number" and type(p[2]) == "number" then
    f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", p[1], p[2])
  elseif Minimap then
    f:SetPoint("TOPRIGHT", Minimap, "BOTTOMRIGHT", 0, -18)
  else
    f:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -16, -200)
  end
end

local function make()
  if frame then return frame end
  local UI, T = ns.UI, ns.T
  local f = CreateFrame("Button", "EverlookDBAuctionsReloadHint", UIParent)
  if UI and UI.own then UI.own(f) end
  f:SetSize(230, 22)
  f:SetFrameStrata("HIGH")
  f:SetClampedToScreen(true)
  f:SetMovable(true)
  f:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  f:RegisterForDrag("LeftButton")
  if UI and UI.panel and T then UI.panel(f, T.surface, T.edge) end
  if UI and UI.line and T then
    local top = UI.line(f, true, T.places.prices, "BORDER")
    top:SetPoint("TOPLEFT", 1, -1)
    top:SetPoint("TOPRIGHT", -1, -1)
  end
  f.text = UI and UI.text and UI.text(f, "small") or f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  f.text:SetPoint("LEFT", 8, 0)
  f.text:SetPoint("RIGHT", -20, 0)
  f.text:SetJustifyH("LEFT")
  f.text:SetWordWrap(false)
  local x = CreateFrame("Button", nil, f)
  x:SetSize(16, 16)
  x:SetPoint("RIGHT", -3, 0)
  x.label = x:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  x.label:SetPoint("CENTER")
  x.label:SetText("x")
  x:SetScript("OnClick", function() N.dismiss() end)
  x:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText("Not now", 1, 1, 1)
    GameTooltip:AddLine("Quiet for 2 hours.", 0.66, 0.69, 0.75, true)
    GameTooltip:Show()
  end)
  x:SetScript("OnLeave", function() GameTooltip:Hide() end)
  f.close = x
  f:SetScript("OnClick", function(_, which)
    if which == "RightButton" then N.dismiss() else N.reload() end
  end)
  f:SetScript("OnDragStart", function(self) self:StartMoving() end)
  f:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local l, t = self:GetLeft(), self:GetTop()
    if l and t then state().pos = { math.floor(l + 0.5), math.floor(t + 0.5) } end
  end)
  f:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")
    GameTooltip:SetText("Newer prices may be ready", 1, 1, 1)
    GameTooltip:AddLine("The EverlookDB App usually brings new prices every hour, but the game only reads them at login or /reload.", 0.66, 0.69, 0.75, true)
    GameTooltip:AddDoubleLine("Click", "reload now (about a second)", 0.6, 0.6, 0.6, 1, 1, 1)
    GameTooltip:AddDoubleLine("Right-click or x", "not now (2 hours)", 0.6, 0.6, 0.6, 1, 1, 1)
    GameTooltip:AddDoubleLine("Drag", "move it", 0.6, 0.6, 0.6, 1, 1, 1)
    GameTooltip:AddLine("Turn it off: /eah reloadhint off (settings, General)", 0.55, 0.58, 0.64, true)
    GameTooltip:Show()
  end)
  f:SetScript("OnLeave", function() GameTooltip:Hide() end)
  f:Hide()
  anchor(f)
  frame = f
  N.frame = f
  return f
end

-- The line's text: "Prices: 3 h old · Reload (1 s)".
function N.lineText(age)
  local gold = "|cffffd100"
  return ("Prices: %s · %sReload|r (1 s)"):format(N.ageText(age), gold)
end

function N.show(age, now)
  now = now or time()
  local f = make()
  f.text:SetText(N.lineText(age))
  anchor(f)
  f:Show()
  state().shown = now
  hideAt = now + N.SHOW_FOR
end

function N.hide()
  hideAt = nil
  if frame then frame:Hide() end
end

-- The x: quiet for 2 hours.
function N.dismiss(now)
  state().quietTill = (now or time()) + N.QUIET
  N.hide()
end

-- Reload for the newer copy; remembers which copy was loaded, so a reload that brings the same one back says so.
function N.reload()
  if (InCombatLockdown and call(InCombatLockdown)) then return false end
  local S = ns.shared
  state().reloadFrom = S and S.written and S.written() or nil
  N.hide()
  if ReloadUI then ReloadUI() end
  return true
end

-- The regular look: show the line when all is right, put it away after its minute, keep the minimap dot current.
function N.check(now)
  now = now or time()
  if frame and frame:IsShown() then
    local fighting = (InCombatLockdown and call(InCombatLockdown)) or call(UnitAffectingCombat, "player")
    if (hideAt and now >= hideAt) or fighting then N.hide() end
  end
  if ns.minimapButton and ns.minimapButton.badge then pcall(ns.minimapButton.badge, N.stale(now) ~= nil) end
  if N.shown() then return false end
  local age = N.stale(now)
  if not age or not N.allowed(now) or not N.calm(now) then return false end
  N.show(age, now)
  return true
end

-- After a login or reload: did a reload we offered bring a newer copy? If not, the app isn't writing: say so once and
-- keep quiet for 2 hours.
function N.afterLoad(now)
  now = now or time()
  local s = state()
  local from = s.reloadFrom
  if from == nil then return end
  s.reloadFrom = nil
  local S = ns.shared
  local w = S and S.written and S.written()
  if w and w == from then
    s.nothingTill = now + N.QUIET
    if ns.say then ns.say("no newer prices on disk yet: is the EverlookDB App running? (asking again in 2 hours)") end
  end
end

-- Events. A fight hides the line at once.
local events = {
  PLAYER_LOGIN = function() N.loaded = time(); N.afterLoad() end,
  PLAYER_REGEN_DISABLED = function() N.hide() end,
  PLAYER_ENTERING_WORLD = function(initial, reloading)
    if initial or reloading then return end   -- a login or reload just read the feed
    N.moment()
    if IsInInstance and call(IsInInstance) then N.hide() end
  end,
  MAIL_SHOW = N.moment, MERCHANT_SHOW = N.moment, AUCTION_HOUSE_CLOSED = N.moment, TAXIMAP_OPENED = N.moment,
  PLAYER_CONTROL_GAINED = N.moment,   -- also a flight landing
  PLAYER_UPDATE_RESTING = function() end,
}
N.events = events

if CreateFrame then
  local ev = CreateFrame("Frame")
  for e in pairs(events) do pcall(ev.RegisterEvent, ev, e) end
  ev:SetScript("OnEvent", function(_, e, ...)
    local fn = events[e]
    if fn then pcall(fn, ...) end
    -- look a moment later: the loading screen fades, the mailbox opens, the flight lands
    if e ~= "PLAYER_REGEN_DISABLED" and e ~= "PLAYER_LOGIN" and C_Timer and C_Timer.After then
      C_Timer.After(2, function() pcall(N.check) end)
    end
  end)
  if C_Timer and C_Timer.NewTicker then
    C_Timer.NewTicker(10, function() pcall(N.check) end)
  end
end
