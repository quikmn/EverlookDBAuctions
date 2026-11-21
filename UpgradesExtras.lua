-- EverlookDB Auctions: gear upgrades outside the Upgrades tab.
--   Spec question   the first time the auction house or the Upgrades window opens: which spec(s) this character
--                   gears for (Save, or Not now; later on the settings page or /eah up spec)
--   Tooltips        on gear: how big an upgrade it is for each ticked spec, or why it isn't one (the auction price
--                   lines stay EverlookDBAuctions.lua's; nothing is shown twice)
--   Bags            a small "+6.5%" (of your gear) on bag slots holding an upgrade (Blizzard's bags, Bagnon), and one chat line when
--                   new gear in the bags is an upgrade
--   Quest rewards   the upgrade on each choice, a star on the best, and a chat line
--   Vendors         sell grey (poor quality) items when a vendor opens (off by default), or /eah up junk
-- Everything waits while you're in combat where it can (PLAYER_REGEN_ENABLED).
local ADDON, ns = ...
local UI, T = ns.UI, ns.T
local U = ns.up

local X = {}
ns.upExtras = X

local function say(msg) if ns.say then ns.say(msg) end end
local function inCombat() return InCombatLockdown and InCombatLockdown() end
local function money(c) return ns.money and ns.money(c) or tostring(c) end
local GOOD_HEX = UI and UI.hex(T.good) or "|cff62cf88"

---------------------------------------------------------------------------------------------------------------------
-- One item against every ticked spec

local function nameOf(link) return tostring(link or ""):match("%[(.-)%]") or tostring(link or "") end

-- The upgrade of an item for one spec: the best over the slots it can go in (a one-hander: main or off hand).
-- Returns the compare result, or nil and why ("class", "armor", "stats" while loading, "notgear").
function X.forSpec(link, id, spec, worn)
  local okI, _, _, _, equipLoc = pcall(C_Item.GetItemInfoInstant, id)
  if not okI or not U.GROUP_OF[equipLoc or ""] then return nil, "notgear" end
  local info = ns.itemInfo and ns.itemInfo(id)
  local usable, why, needs = U.usable(id, spec, info)
  if not usable and why ~= "level" then return nil, why end
  local st = U.stats(link, id)
  if not st then return nil, "stats" end
  local best
  for _, g in ipairs(U.groupsFor(equipLoc)) do
    local loc = g == "offhand" and equipLoc == "INVTYPE_WEAPON" and "INVTYPE_WEAPONOFFHAND" or equipLoc
    local r = U.compare(st, id, loc, spec, worn)
    if r and (not best or (r.delta or -1e9) > (best.delta or -1e9)) then best = r end
  end
  if best and not usable then best.needs = needs end
  return best
end

-- Whether the item (by "id:suffix") is one of the worn ones.
local function isWorn(key, worn)
  for _, it in pairs(worn or U.worn()) do if it.key == key then return true end end
  return false
end

-- The best bag item of a slot group for a spec, other than `key`: { link, score } or nil.
local bagGear   -- { { link, id, key, equipLoc } } (rebuilt when the bags change)
local function readBags()
  local out = {}
  local C = C_Container
  if not C or not C.GetContainerNumSlots then return out end
  for bag = 0, 4 do
    local okN, n = pcall(C.GetContainerNumSlots, bag)
    for slot = 1, (okN and n or 0) do
      local okL, link = pcall(C.GetContainerItemLink, bag, slot)
      link = okL and ns.ok and ns.ok(link) or (okL and link) or nil
      if type(link) == "string" then
        local id = tonumber(link:match("item:(%d+)"))
        local okI, _, _, _, equipLoc = pcall(C_Item.GetItemInfoInstant, id)
        if id and okI and U.GROUP_OF[equipLoc or ""] then
          out[#out + 1] = { link = link, id = id, key = ns.variantOf and ns.variantOf(id, link) or (id .. ":0"), equipLoc = equipLoc, bag = bag, slot = slot }
        end
      end
    end
  end
  return out
end
function X.bagGear()
  if not bagGear then bagGear = X.testBags or readBags() end
  return bagGear
end

function X.betterInBags(key, group, score, spec)
  local best, bs
  local w = U.weights(spec)
  for _, b in ipairs(X.bagGear()) do
    if b.key ~= key and U.GROUP_OF[b.equipLoc] == group and U.usable(b.id, spec, ns.itemInfo and ns.itemInfo(b.id)) then
      local s = U.score(U.stats(b.link, b.id), w, group, b.id, spec.role)
      if s > score and (not bs or s > bs) then best, bs = b, s end
    end
  end
  return best
end

-- The tooltip's lines: { { left, right, note, detail, good } }. Pure apart from reading the game's item data.
-- While the game hasn't loaded the item: one "reading the item..." line, and X.waiting = its ID (the tooltip is read
-- again when GET_ITEM_INFO_RECEIVED brings it). With every spec counted (none picked): the best two and "+N more".
X.waiting = nil
function X.tipLines(link, id)
  local okI, _, _, _, equipLoc, _, classID, subID = pcall(C_Item.GetItemInfoInstant, id)
  if not okI or not U.GROUP_OF[equipLoc or ""] then return nil end
  local key = ns.variantOf and ns.variantOf(id, link) or (id .. ":0")
  local worn = U.worn()
  if isWorn(key, worn) then return nil end
  if not U.canUse(U.class(), classID, subID, equipLoc, 60) or (equipLoc == "INVTYPE_WEAPONOFFHAND" and not U.canDualWield(U.class())) then
    return { { left = "Gear upgrades", right = "Your class can't use this" } }
  end
  if not U.stats(link, id) then
    X.waiting = id
    return { { left = "Gear upgrades", right = "reading the item…" } }
  end
  if X.waiting == id then X.waiting = nil end
  local specs, all = U.ticked()
  local out = {}
  for _, spec in ipairs(specs) do
    local r, why = X.forSpec(link, id, spec, worn)
    if why == "armor" then
      out[#out + 1] = { left = spec.name, right = "Not your armor type" }
    elseif why == "class" then
      out[#out + 1] = { left = spec.name, right = "Your class can't use this" }
    elseif r and r.note == "twohand" then
      out[#out + 1] = { left = spec.name, right = "Not an upgrade", note = "you wear a two-handed weapon", rank = 1 }
    elseif r and U.isUpgrade(r, 0) then
      local line = { left = "Upgrade for " .. spec.name, right = r.pct and (U.pctText(r) .. " of your gear") or U.pctText(r),
        good = true, rank = 3 + (r.pct or 1000) }
      local notes = {}
      if r.note == "empty" and r.pct then notes[#notes + 1] = "fills an empty slot" end
      if r.vs and r.note ~= "empty" then notes[#notes + 1] = "vs " .. nameOf(r.vs.link) end
      if r.needs then notes[#notes + 1] = "needs level " .. r.needs end
      local it = ns.itemFor and ns.itemFor(id)
      if it and it[1] then notes[#notes + 1] = money(it[1]) end   -- the price next to the gain
      line.note = table.concat(notes, " \194\183 ")
      line.why = U.whyText(r)                                      -- always: why it's better
      line.detail = U.worthText(r)
      local better = X.betterInBags(key, r.group, r.score, spec)
      if better then line.bags = "You have a better one in your bags: " .. nameOf(better.link) end
      out[#out + 1] = line
    elseif r and r.same then
      out[#out + 1] = { left = spec.name, right = "About the same", note = "within the weights' margin", why = U.whyText(r), rank = 2 }
    elseif r then
      out[#out + 1] = { left = spec.name, right = "Not an upgrade", rank = 1 }
    end
  end
  if all and #out > 1 then out = X.trimAll(out) end
  return out
end

-- Every spec counted: the same verdict for all of them is one line; else the best two and "+N more specs".
function X.trimAll(out)
  local same = true
  for _, l in ipairs(out) do
    if l.good or l.why or l.right ~= out[1].right or (l.note or "") ~= (out[1].note or "") then same = false; break end
  end
  if same then return { { left = "All specs", right = out[1].right, note = out[1].note } } end
  if #out <= 2 then return out end
  for i, l in ipairs(out) do l.i = i end
  table.sort(out, function(a, b)
    if (a.rank or 0) ~= (b.rank or 0) then return (a.rank or 0) > (b.rank or 0) end
    return a.i < b.i
  end)
  local n = #out - 2
  return { out[1], out[2],
    { left = ("+%d more %s"):format(n, n == 1 and "spec" or "specs"), right = "", note = "pick yours: /eah up spec" } }
end

---------------------------------------------------------------------------------------------------------------------
-- Tooltip

local Tip = LibStub and LibStub("EverlookTooltip-1", true)
local function tooltipLines(t, ctx)
  if not U.get("tip") or not ctx.id then return end
  local link
  if ctx.tooltip and ctx.tooltip.GetItem then
    local okItem, _, l = pcall(ctx.tooltip.GetItem, ctx.tooltip)
    link = okItem and ns.ok and ns.ok(l) or nil
  end
  link = link or ("item:" .. ctx.id)
  local okL, lines = pcall(X.tipLines, link, ctx.id)
  if not okL or not lines then return end
  for _, l in ipairs(lines) do
    t:Line(l.left, l.good and (GOOD_HEX .. l.right .. "|r") or l.right, { note = l.note ~= "" and l.note or nil, stale = not l.good })
    if l.why and l.why ~= "" then t:Line("  " .. l.why, "", { stale = true }) end
    if l.detail then t:Detail(l.detail, "") end
    if l.bags then t:Detail(l.bags, "") end
  end
end

---------------------------------------------------------------------------------------------------------------------
-- The spec question (once per character)

local ask
function ns.upAsk()
  local c = U.char()
  if c.asked or #U.specs() == 0 then return end
  if ask then ask:Show(); return end
  local f = UI.own(CreateFrame("Frame", "EverlookAuctionsUpgradesAsk", UIParent))
  ask = f
  local specs = U.specs()
  local nBuilds = 0
  for _, s in ipairs(specs) do if s.build then nBuilds = 1 end end
  f:SetSize(360, 128 + #specs * 24 + nBuilds * 22)
  f:SetPoint("CENTER", 0, 120)
  f:SetFrameStrata("DIALOG")
  f:SetToplevel(true)
  f:SetClampedToScreen(true)
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", function(self) self:StartMoving() end)
  f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
  UI.place(f, "upgrades")
  UI.panel(f, T.bg, T.edgeHi)
  UI.placeEdge(f, T.places.upgrades)
  if UI.shadow then UI.shadow(f) end
  local head = UI.text(f, "title")
  head:SetPoint("TOPLEFT", 14, -14)
  head:SetText("Which spec or build do you gear for?")
  head:SetTextColor(unpack(T.places.upgrades))
  local body = UI.text(f, "dim")
  body:SetPoint("TOPLEFT", 14, -34)
  body:SetWidth(332)
  body:SetWordWrap(true)
  body:SetText("Gear upgrades compare items with what you wear, for the specs you tick. Not sure yet? Tick more than one.")
  local checks = {}
  local y, labelled = -64, false
  for _, s in ipairs(specs) do
    if s.build and not labelled then
      labelled = true
      local l = UI.label(f, "LEVELLING BUILDS")
      l:SetPoint("TOPLEFT", 16, y - 6)
      y = y - 22
    end
    local b = UI.check(f, s.name)
    b:SetPoint("TOPLEFT", 16, y)
    y = y - 24
    if s.note then UI.tip(b, s.name, s.note) end
    b:EdbChecked(c.specs[s.key])
    b.spec = s
    checks[#checks + 1] = b
  end
  local save = UI.button(f, "Save", 96, 24, "primary")
  save:SetPoint("BOTTOMRIGHT", -14, 14)
  save:SetScript("OnClick", function()
    local keys = {}
    for _, b in ipairs(checks) do if b.checked then keys[#keys + 1] = b.spec.key end end
    U.setSpecs(keys)
    f:Hide()
    local names = {}
    for _, s in ipairs(U.ticked()) do names[#names + 1] = s.name end
    say("gear upgrades for " .. table.concat(names, ", ") .. ". Change it on the Gear upgrades page of /eah, or /eah up spec <name>.")
    -- at the auction house: straight to the Upgrades tab (shared prices work without a scan of your own)
    if _G.AuctionHouseFrame and AuctionHouseFrame:IsShown() and ns.upgradesView then ns.upgradesView.open() end
  end)
  local later = UI.button(f, "Not now", 96, 24)
  later:SetPoint("RIGHT", save, "LEFT", -8, 0)
  later:SetScript("OnClick", function()
    U.char().asked = true
    f:Hide()
    say("gear upgrades count every spec of your class for now. Pick yours on the Gear upgrades page of /eah, or /eah up spec <name>.")
  end)
  f:Show()
end

---------------------------------------------------------------------------------------------------------------------
-- Bags

local badgeCache = {}   -- link -> text ("" when not an upgrade)

-- The badge of a bag item: "+6.5%" (its biggest gain over the ticked specs, as % of your gear), "new" for an empty
-- slot when nothing worn scores, or "".
function X.badgeText(link, id)
  local hit = badgeCache[link]
  if hit then return hit end
  local best, empty
  for _, spec in ipairs(U.ticked()) do
    local r = X.forSpec(link, id, spec)
    if r and not r.needs and U.isUpgrade(r, 0) then
      if not r.pct then empty = true
      elseif not best or r.pct > best then best = r.pct end
    end
  end
  local text = best and U.shortPct(best) or (empty and "new" or "")
  if text ~= "" or U.stats(link, id) then badgeCache[link] = text else X.badgePending = true end
  return text
end

local function badge(button, bag, slot)
  if not button or not bag or not slot then return end
  local text = ""
  if U.get("bags") then
    local okL, link = pcall(C_Container.GetContainerItemLink, bag, slot)
    link = okL and ns.ok and ns.ok(link) or (okL and link) or nil
    if type(link) == "string" then
      local id = tonumber(link:match("item:(%d+)"))
      local okB, t = pcall(X.badgeText, link, id)
      text = okB and t or ""
    end
  end
  local fs = button.edbUpgrade
  if text == "" then
    if fs then fs:Hide() end
    return
  end
  if not fs then
    fs = button:CreateFontString(nil, "OVERLAY")
    fs:SetFont(STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", 10, "OUTLINE")
    fs:SetPoint("TOPLEFT", 2, -2)
    fs:SetTextColor(T.good[1], T.good[2], T.good[3])
    button.edbUpgrade = fs
  end
  fs:SetText(text)
  fs:Show()
end

local function slotOf(button)
  local bag, slot
  if button.GetBagID then local okB, b = pcall(button.GetBagID, button); bag = okB and b or nil end
  if not bag and button.GetBag then local okB, b = pcall(button.GetBag, button); bag = okB and b or nil end
  if not bag and button.GetParent then
    local p = button:GetParent()
    if p and p.GetID then bag = p:GetID() end
  end
  if button.GetID then slot = button:GetID() end
  return bag, slot
end

local dirty = false
function X.updateBags()
  if inCombat() then dirty = true; return end
  dirty = false
  -- Blizzard's bags
  for i = 1, (NUM_CONTAINER_FRAMES or 13) do
    local frame = _G["ContainerFrame" .. i]
    if frame and frame:IsShown() then
      local name = frame:GetName()
      for j = 1, 36 do
        local b = _G[name .. "Item" .. j]
        if b and b:IsShown() then badge(b, slotOf(b)) end
      end
    end
  end
  local combined = _G.ContainerFrameCombinedBags
  if combined and combined:IsShown() and combined.EnumerateValidItems then
    for _, b in combined:EnumerateValidItems() do badge(b, slotOf(b)) end
  end
end

local function hookBagAddons()
  if X.bagsHooked then return end
  X.bagsHooked = true
  if ContainerFrame_Update then hooksecurefunc("ContainerFrame_Update", function() X.updateBags() end) end
  for i = 1, (NUM_CONTAINER_FRAMES or 13) do
    local frame = _G["ContainerFrame" .. i]
    if frame then frame:HookScript("OnShow", function() C_Timer.After(0, X.updateBags) end) end
  end
  -- Bagnon / BagBrother: every item button's Update
  local bagnon = rawget(_G, "Bagnon")
  local item = type(bagnon) == "table" and bagnon.Item
  if type(item) == "table" and item.Update then
    hooksecurefunc(item, "Update", function(self)
      if inCombat() then dirty = true; return end
      pcall(badge, self, slotOf(self))
    end)
  end
end

---------------------------------------------------------------------------------------------------------------------
-- New gear in the bags (a drop, a quest reward, the mail): one chat line per item, never again for that item

local seen          -- "bag:slot" -> link, as the bags were last time
local equippedAt = 0

-- The new links in now that weren't in before (by link, so moving an item between slots isn't new).
function X.newLinks(before, now)
  local had = {}
  for _, l in pairs(before or {}) do had[l] = (had[l] or 0) + 1 end
  local out = {}
  for _, l in pairs(now or {}) do
    if (had[l] or 0) > 0 then had[l] = had[l] - 1 else out[#out + 1] = l end
  end
  return out
end

local function snapshot()
  local out = {}
  for _, b in ipairs(X.bagGear()) do out[b.bag .. ":" .. b.slot] = b.link end
  return out
end

-- The chat line for a new item, or nil: the spec it is the biggest upgrade for.
function X.newUpgradeLine(link, id)
  local best, bestSpec
  for _, spec in ipairs(U.ticked()) do
    local r = X.forSpec(link, id, spec)
    if r and not r.needs and U.isUpgrade(r, 0) and (not best or (r.pct or 1000) > (best.pct or 1000)) then
      best, bestSpec = r, spec
    end
  end
  if not best then return nil end
  local vs = best.note == "empty" and "an empty slot" or (best.vs and best.vs.link or "?")
  local why = U.whyText(best)
  return ("New upgrade in your bags for %s: %s %s vs %s%s"):format(bestSpec.name, link,
    best.pct and (U.pctText(best) .. " of your gear") or "fills", vs, why and (" (" .. why .. ")") or "")
end

local function checkNew()
  if inCombat() then dirty = true; return end
  local now = snapshot()
  if not seen then seen = now; return end
  local before = seen
  seen = now
  if not U.get("chat") or GetTime() - equippedAt < 3 then return end
  local told = U.char()
  told.told = told.told or {}
  for _, link in ipairs(X.newLinks(before, now)) do
    local id = tonumber(link:match("item:(%d+)"))
    local key = ns.variantOf and ns.variantOf(id, link) or tostring(id)
    if id and not told.told[key] then
      local okL, line = pcall(X.newUpgradeLine, link, id)
      if okL and line then
        told.told[key] = time()
        say(line)
      end
    end
  end
  -- forget the oldest when there are many (the same item a year later can be news again)
  local n = 0
  for _ in pairs(told.told) do n = n + 1 end
  if n > 300 then
    local cut = time() - 30 * 86400
    for k, t in pairs(told.told) do if t < cut then told.told[k] = nil end end
  end
end

---------------------------------------------------------------------------------------------------------------------
-- Quest rewards

local function rewardButtons()
  local out = {}
  local frame = _G.QuestInfoRewardsFrame
  if frame and type(frame.RewardButtons) == "table" then
    for _, b in ipairs(frame.RewardButtons) do
      if b.type == "choice" and b:IsShown() then out[b:GetID()] = b end
    end
  end
  for i = 1, 10 do
    local b = _G["QuestInfoRewardsFrameQuestInfoItem" .. i] or _G["QuestInfoItem" .. i]
    if b and b:IsShown() and (b.type == nil or b.type == "choice") and not out[b:GetID() or i] then out[b:GetID() or i] = b end
  end
  return out
end

-- Per choice: the biggest upgrade over the ticked specs, and the chat lines. choices = { { link, id }, ... }.
-- Returns { [i] = { text, pct } }, the index of the best one (nil when none is an upgrade), and the lines.
function X.questPick(choices)
  local marks, lines, bestI, bestV = {}, {}, nil, nil
  for _, spec in ipairs(U.ticked()) do
    local sb, si
    for i, ch in ipairs(choices) do
      local r = ch.link and X.forSpec(ch.link, ch.id, spec)
      if r and U.isUpgrade(r, 0) then
        local v = r.pct or 1000
        local m = marks[i]
        if not m or v > m.v then marks[i] = { text = r.pct and U.shortPct(r.pct) or "new", v = v } end
        if not sb or v > sb.v then sb, si = { v = v, r = r }, i end
      end
    end
    if sb then
      local ch = choices[si]
      lines[#lines + 1] = sb.r.note == "empty" and ("Best quest reward for %s: %s fills an empty slot%s"):format(spec.name, ch.link,
          sb.r.pct and (" (" .. U.pctText(sb.r) .. " of your gear)") or "")
        or ("Best quest reward for %s: %s %s of your gear vs %s"):format(spec.name, ch.link, U.pctText(sb.r), sb.r.vs and sb.r.vs.link or "?")
      if not bestV or sb.v > bestV then bestI, bestV = si, sb.v end
    else
      -- none is an upgrade: the one that sells for the most (vendor or auction house)
      local top, tv, where
      for _, ch in ipairs(choices) do
        local okI, info = pcall(function() return { C_Item.GetItemInfo(ch.id) } end)
        local vendor = okI and info[11] or 0
        local it = ns.itemFor and ns.itemFor(ch.id)
        local ah = it and it[1] and math.floor(it[1] * 0.95) or 0
        local v = math.max(vendor or 0, ah)
        if v > 0 and (not tv or v > tv) then top, tv, where = ch, v, ah > (vendor or 0) and "on the AH" or "at a vendor" end
      end
      if top then
        lines[#lines + 1] = ("No quest reward is an upgrade for %s. %s sells for the most (%s %s)."):format(spec.name, top.link, money(tv), where)
      else
        lines[#lines + 1] = ("No quest reward is an upgrade for %s."):format(spec.name)
      end
    end
  end
  return marks, bestI, lines
end

local questShown   -- the quest whose rewards were said in chat
function X.markQuest(announce)
  if not U.get("quest") or not GetNumQuestChoices then return end
  local n = GetNumQuestChoices() or 0
  if n < 1 then return end
  local choices = {}
  for i = 1, n do
    local okL, link = pcall(GetQuestItemLink, "choice", i)
    link = okL and link or nil
    choices[i] = { link = link, id = link and tonumber(link:match("item:(%d+)")) }
  end
  local marks, best, lines = X.questPick(choices)
  for i, b in pairs(rewardButtons()) do
    local icon = b.Icon or b.icon or _G[(b:GetName() or "") .. "IconTexture"] or b
    if not b.edbUpgrade then
      b.edbUpgrade = b:CreateFontString(nil, "OVERLAY")
      b.edbUpgrade:SetFont(STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
      b.edbUpgrade:SetPoint("BOTTOMLEFT", icon, "BOTTOMLEFT", 1, 1)
      b.edbUpgrade:SetTextColor(T.good[1], T.good[2], T.good[3])
      b.edbStar = b:CreateTexture(nil, "OVERLAY")
      b.edbStar:SetSize(20, 20)
      b.edbStar:SetPoint("TOPLEFT", icon, "TOPLEFT", -7, 7)
      b.edbStar:SetTexture("Interface\\Common\\ReputationStar")
      b.edbStar:SetTexCoord(0, 0.5, 0, 0.5)
    end
    b.edbUpgrade:SetText(marks[i] and marks[i].text or "")
    b.edbStar:SetShown(best == i)
  end
  if announce then
    local title = GetTitleText and GetTitleText() or "?"
    if questShown ~= title then
      questShown = title
      for _, l in ipairs(lines) do say(l) end
    end
  end
end

---------------------------------------------------------------------------------------------------------------------
-- Grey items at vendors

-- The poor-quality items worth something: items = { { bag, slot, quality, sell, count, noValue, locked, id } }.
-- Only quality 0 (grey), never anything else.
function X.junkList(items)
  local out = {}
  for _, it in ipairs(items or {}) do
    if it.quality == 0 and not it.noValue and not it.locked and (it.sell or 0) > 0 then out[#out + 1] = it end
  end
  return out
end

local function bagItems()
  local out = {}
  local C = C_Container
  if not C then return out end
  for bag = 0, 4 do
    local okN, n = pcall(C.GetContainerNumSlots, bag)
    for slot = 1, (okN and n or 0) do
      local okI, info = pcall(C.GetContainerItemInfo, bag, slot)
      if okI and type(info) == "table" and info.itemID then
        local okS, sell = pcall(function() return select(11, C_Item.GetItemInfo(info.itemID)) end)
        out[#out + 1] = { bag = bag, slot = slot, id = info.itemID, quality = info.quality, count = info.stackCount or 1,
          noValue = info.hasNoValue, locked = info.isLocked, sell = okS and sell or 0 }
      end
    end
  end
  return out
end

local merchantOpen, selling = false, nil
function X.sellJunk(manual)
  if not merchantOpen then
    if manual then say("open a vendor first, then /eah up junk.") end
    return
  end
  if selling then return end
  local list = X.junkList(bagItems())
  if #list == 0 then
    if manual then say("no grey items to sell.") end
    return
  end
  local job = { i = 1, n = 0, copper = 0 }
  selling = job
  local function step()
    if selling ~= job then return end
    if not merchantOpen or job.i > #list then
      selling = nil
      if job.n > 0 then say(("Sold %d grey %s for %s."):format(job.n, job.n == 1 and "item" or "items", money(job.copper))) end
      return
    end
    local it = list[job.i]
    job.i = job.i + 1
    -- the slot is checked again right before: still that item, still grey
    local okI, info = pcall(C_Container.GetContainerItemInfo, it.bag, it.slot)
    if okI and type(info) == "table" and info.itemID == it.id and info.quality == 0 and not info.isLocked then
      C_Container.UseContainerItem(it.bag, it.slot)
      job.n = job.n + 1
      job.copper = job.copper + (it.sell or 0) * (info.stackCount or 1)
    end
    C_Timer.After(0.2, step)
  end
  step()
end

---------------------------------------------------------------------------------------------------------------------
-- Events

U.onChange(function() badgeCache = {}; if not inCombat() then X.updateBags() end end)
U.afterCombat = function()
  if dirty then X.updateBags(); checkNew() end
end

if CreateFrame then
  local ev = CreateFrame("Frame")
  for _, e in ipairs({ "ADDON_LOADED", "PLAYER_ENTERING_WORLD", "BAG_UPDATE_DELAYED", "PLAYER_EQUIPMENT_CHANGED",
      "QUEST_COMPLETE", "MERCHANT_SHOW", "MERCHANT_CLOSED", "AUCTION_HOUSE_SHOW", "GET_ITEM_INFO_RECEIVED" }) do
    pcall(ev.RegisterEvent, ev, e)
  end
  local pending = false
  ev:SetScript("OnEvent", function(_, e, arg)
    if e == "ADDON_LOADED" then
      if arg == ADDON and Tip then
        Tip:Register({ id = "EverlookDBAuctions.upgrade", kind = "item", order = 5, add = tooltipLines })
      end
      if arg == ADDON or arg == "Bagnon" then if arg ~= ADDON then X.bagsHooked = nil end; pcall(hookBagAddons) end
    elseif e == "PLAYER_ENTERING_WORLD" then
      -- what's in the bags at login isn't news
      C_Timer.After(3, function() bagGear = nil; seen = snapshot() end)
    elseif e == "BAG_UPDATE_DELAYED" then
      bagGear = nil
      if pending then return end
      pending = true
      C_Timer.After(0.5, function()
        pending = false
        checkNew()
        X.updateBags()
      end)
    elseif e == "PLAYER_EQUIPMENT_CHANGED" then
      equippedAt = GetTime()
      bagGear = nil
    elseif e == "QUEST_COMPLETE" then
      C_Timer.After(0.1, function() pcall(X.markQuest, true) end)
    elseif e == "MERCHANT_SHOW" then
      merchantOpen = true
      if U.get("junk") then C_Timer.After(0.3, function() X.sellJunk(false) end) end
    elseif e == "MERCHANT_CLOSED" then
      merchantOpen, selling = false, nil
    elseif e == "GET_ITEM_INFO_RECEIVED" then
      -- the one item a tooltip waits for: read that tooltip again
      if arg and arg == X.waiting then
        X.waiting = nil
        local tip = _G.GameTooltip
        if tip and tip:IsShown() and tip.RefreshData then pcall(tip.RefreshData, tip) end
      end
      -- bag badges that waited for their item: one update for a burst of them
      if X.badgePending and not pending then
        X.badgePending = nil
        pending = true
        C_Timer.After(0.5, function() pending = false; X.updateBags() end)
      end
    end
  end)
  if QuestInfo_Display then hooksecurefunc("QuestInfo_Display", function() pcall(X.markQuest, false) end) end
end
