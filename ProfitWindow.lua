-- EverlookDB Auctions: the profit finder window (/eah profit), open anywhere: the recipes you know whose result sells
-- on the auction house for more than its materials cost, best profit first (Profit.lua does the sums).
--   One row per recipe: icon and name, the skill it needs, what one craft costs, what it sells for after the cut,
--   the profit and the margin, and a box for how many crafts you plan. Money is in gold, silver and copper columns
--   with the game's coin icons, so the coins line up down the list. Click a column's heading to sort by it (again:
--   the other way). Filters: words in the name, skill from-to, profit at least, margin at least, cost at most, only
--   what you can make now (the materials are in your bags), and, with EverlookDB Crafting, the recipes of your alts
--   (ticked per character; a row then says who can make it). "Clear filters" puts them all back.
--   The one gold button, Make shopping list, saves what the planned crafts need (materials cheaper to craft broken
--   down, minus what you have) as a list in the auction house's Shopping tab.
--   With EverlookDB Crafting (API v8) the planned crafts are its crafting queue, one queue for both addons: a row's box
--   shows and sets how many of that recipe are queued, a click on a row with an empty box queues 5, Clear queue empties
--   it (two clicks), and Make shopping list / Buy materials buy what the whole queue still misses (Crafting works that
--   out from what you have on every character, as its queue window shows it). Without it, planned crafts stay here.
--   The table is a "worth a look" hint, estimated from the last scan; Check prices gives the verdict before you buy.
--   What you paid: a material you bought at this auction house in the last 3 days (the AH log, db.bought) costs what
--   you paid, not the market price; such a row's cost is blue with a "paid" tag, and its tooltip says "paid X each"
--   against "market Y". Profit, margin, the sort and the filters follow from it.
--   Check prices (plain, right before the gold button; auction house open): looks at the listings right now for the
--   queued recipes' materials and what they make (one search at a time, through AHQuery.lua). The fresh prices
--   replace the scan's (ns.noteLivePrice); a material is priced at the average of the cheapest listings that cover
--   the whole queue (BuyList's plan). Each queued recipe then gets a verdict: good, thin, or not worth it (no profit,
--   or what it makes sells for over 30% less than the page showed): those come out of the queue, with Undo.
--   A missing price is said, never guessed: "≈" marks a row with a material that has no AH price (its real profit is
--   lower), recipes whose result has no AH price are counted under the list, and prices over a day old are grey.
-- Settings (db.profit = { v, from, to, min (copper), maxCost (copper), minMargin (whole %), q (the search words),
-- canMake, sort, desc, noCraft, pos }); the alts ticked are per character (EverlookAuctionsCharDB.profitAlts =
-- { [character GUID, as EverlookDB Crafting keys them] = true }). Its settings page is "Crafting" in /eah.
local ADDON, ns = ...
local Pr = ns.profit
local R = ns.recipeList
local UI = ns.UI
local W = {}
ns.profitWindow = W

local WIDTH, PAD, ROW, ROWS = 760, 14, 24, 12
local SKILL_W, MONEY_W, COIN_W, MARGIN_W, CRAFTS_W, GAP = 40, 104, 30, 52, 44, 8
local LIST_TOP = -136
local PAID = { 0.353, 0.663, 1.000, 1 }   -- a cost from what you paid (blue: the gold accent is the button's)
local LIVE_FOR = 1800                     -- Check prices' listings count for half an hour
local CHECK_W = 120
local CHECK_TEX, BOX_TEX = "Interface\\Buttons\\UI-CheckBox-Check", "Interface\\Buttons\\UI-CheckBox-Up"

local EUI = LibStub and LibStub("EverlookUI-1", true)
local U = EUI and EUI.Util
local T

local function try(fn, ...)
  if type(fn) ~= "function" then return nil end
  local okCall, a = pcall(fn, ...)
  if okCall then return a end
end
local function rgba(c) return c[1], c[2], c[3], c[4] or 1 end
local function hex(c) return ("%02x%02x%02x"):format(math.floor(c[1] * 255 + 0.5), math.floor(c[2] * 255 + 0.5), math.floor(c[3] * 255 + 0.5)) end
local function db() return ns.db and ns.db() end
local function settings()
  local d = db()
  if not d then return {} end
  d.profit = d.profit or {}
  Pr.migrate(d.profit)
  return d.profit
end
W.settings = settings

local function itemName(id)
  local n = try(C_Item.GetItemNameByID, id)
  if not n and C_Item.RequestLoadItemDataByID then pcall(C_Item.RequestLoadItemDataByID, id) end
  return n
end
local function rowName(r) return r.name or itemName(r.id) end
local function qualityColor(id)
  local q = try(C_Item.GetItemQualityByID, id)
  local c = q and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q]
  if c then return c.r, c.g, c.b end
  return 1, 1, 1
end
-- materials on hand for the shopping list: bags and bank, your mail and your alts' (Buy this list counts the same)
local function haveOf(id)
  if ns.buyList and ns.buyList.haveOf then return ns.buyList.haveOf(id) end
  return try(C_Item.GetItemCount, id, true, false, true) or 0
end
local function bagCount(id) return try(C_Item.GetItemCount, id) or 0 end   -- bags only: what you can craft with now
local function priceOf(id)
  local it = ns.itemFor and ns.itemFor(id)
  if it and it[1] then return it[1], it[4] end
end
local function stale(at) return at ~= nil and time() - at >= Pr.STALE end
local function houseKey()
  return (ns.house and ns.house()) or (((ns.realmName and ns.realmName()) or "?") .. "-" .. (UnitFactionGroup("player") or "?"))
end

---------------------------------------------------------------------------------------------------------------------
-- Alts: EverlookDB Crafting (API v6) knows each character's professions and recipes

local function craftAPI()
  local api = rawget(_G, "EverlookCraftAPI")
  if api and (tonumber(api.version) or 0) >= 6 and api.characters and api.recipesOf then return api end
end
W.craftAPI = craftAPI

-- EverlookDB Crafting (API v8) owns the crafting queue: then the planned crafts are that queue
local function queueAPI()
  local api = rawget(_G, "EverlookCraftAPI")
  if api and (tonumber(api.version) or 0) >= 8 and api.queueSet and api.queueCount and api.queue and api.queueMissing then
    return api
  end
end
W.queueAPI = queueAPI

-- How many crafts of a row are planned: queued in EverlookDB Crafting (by its recipe), else typed here.
function W.planned(r)
  local q = queueAPI()
  if q and r and r.rid then
    local n = tonumber(try(q.queueCount, r.rid)) or 0
    return n > 0 and n or nil
  end
  return r and W.crafts[r.id]
end

-- Plan n crafts of a row (0: none): into the queue when there is one, else here.
function W.setPlanned(r, n)
  if not r then return end
  n = math.max(0, math.floor(tonumber(n) or 0))
  local q = queueAPI()
  if q and r.rid then
    try(q.queueSet, r.rid, n)
  else
    W.crafts[r.id] = n > 0 and n or nil
  end
end

-- { [item made] = crafts planned } for sorting by the column
function W.plannedMap()
  local q = queueAPI()
  if not q then return W.crafts end
  local out = {}
  for _, e in ipairs(try(q.queue) or {}) do
    if e.creates and (e.n or 0) > 0 then out[e.creates] = (out[e.creates] or 0) + e.n end
  end
  return out
end

-- your characters with recipes (you first), from EverlookDB Crafting; {} without it
function W.characters()
  local api = craftAPI()
  local list = api and try(api.characters)
  return type(list) == "table" and list or {}
end

-- the alts ticked on this character
-- This character's own Crafting profit settings (EverlookAuctionsCharDB): recipeMax, the "Recipe under" box.
function W.charSettings()
  EverlookAuctionsCharDB = EverlookAuctionsCharDB or {}
  local c = EverlookAuctionsCharDB
  if type(c.profit) ~= "table" then c.profit = {} end
  return c.profit
end

function W.altTicks()
  EverlookAuctionsCharDB = EverlookAuctionsCharDB or {}
  local c = EverlookAuctionsCharDB
  if type(c.profitAlts) ~= "table" then c.profitAlts = {} end
  return c.profitAlts
end

function W.toggleAlt(key)
  if type(key) ~= "string" then return end
  local t = W.altTicks()
  t[key] = not t[key] or nil
  W.offset = 0
  W.refresh()
end

local function classHex(class)
  local cc = type(class) == "string" and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
  if cc and cc.r then return hex({ cc.r, cc.g, cc.b }) end
  return "e8eaef"
end
local function charName(c) return "|cff" .. classHex(c.class) .. tostring(c.name or "?") .. "|r" end
local function profText(profs)
  local out = {}
  for _, p in ipairs(profs or {}) do out[#out + 1] = p.rank and (p.name .. " " .. p.rank) or p.name end
  return table.concat(out, ", ")
end
W.profText = profText

-- An item-keyed recipe table (as db.crafts) from EverlookDB Crafting's recipes; the reagents this addon read in a
-- profession window win (they are the server's).
local function toRecipes(list, crafts)
  local out = {}
  for _, r in ipairs(list or {}) do
    local id = r.creates
    if id then out[id] = crafts[id] or { mats = r.mats, makes = tonumber(r.yield) or 1, rid = r.spell, name = r.name } end
  end
  return out
end

-- Whose recipes the list has: you first, then the alts ticked. Your recipes are EverlookDB Crafting's record of this
-- character when it has one, else every recipe this addon has seen (db.crafts, as before alts).
function W.sources()
  local d = db() or {}
  local crafts = d.crafts or {}
  local api = craftAPI()
  local chars = api and W.characters() or {}
  local me
  for _, c in ipairs(chars) do if c.me then me = c end end
  local mine = me and try(api.recipesOf, me.key)
  local sources = { { key = me and me.key, name = me and me.name, class = me and me.class, profs = me and me.profs, me = true,
    recipes = (type(mine) == "table" and #mine > 0) and toRecipes(mine, crafts) or crafts } }
  local ticks = W.altTicks()
  for _, c in ipairs(chars) do
    if not c.me and ticks[c.key] then
      local list = try(api.recipesOf, c.key)
      if type(list) == "table" then
        sources[#sources + 1] = { key = c.key, name = c.name, class = c.class, profs = c.profs,
          recipes = toRecipes(list, crafts), bags = (api.bagsOf and try(api.bagsOf, c.key)) or {} }
      end
    end
  end
  return sources
end

-- Can this crafter make one now? You: your bags right now; an alt: its bags when it was last seen.
local function crafterCan(c, r)
  if not c or c.me or not c.bags then return Pr.canMake(r, bagCount) end
  return Pr.canMake(r, function(id) return c.bags[id] or 0 end)
end

-- The scope shown: "known" (the recipes you know), "easy" (easy to learn) or "all" (every recipe).
function W.scope()
  local sc = settings().scope
  return Pr.SCOPES[sc] and sc or "known"
end
function W.setScope(sc)
  local s = settings()
  s.scope = (Pr.SCOPES[sc] and sc ~= "known") and sc or nil
  W.offset = 0
  W.render()
end

-- EverlookDB Crafting (API v7) has every recipe and how it is learned.
local function recipesAPI()
  local api = rawget(_G, "EverlookCraftAPI")
  if api and (tonumber(api.version) or 0) >= 7 and api.allRecipes then return api end
end
W.recipesAPI = recipesAPI

-- Your skill in each of your professions: { [skill line] = rank } (EverlookDB Crafting's record of you).
function W.ranks()
  local out = {}
  for _, c in ipairs(W.characters()) do
    if c.me then for _, p in ipairs(c.profs or {}) do out[p.skill] = tonumber(p.rank) end end
  end
  return out
end

-- Every recipe in EverlookDB Crafting's data (read once a minute at most: it doesn't change while you play).
local allCache, allAt
local function allRecipes(api)
  local now = GetTime and GetTime() or 0
  if not allCache or not allAt or now - allAt > 60 then
    allCache = try(api.allRecipes) or {}
    allAt = now
  end
  return allCache
end
function W.forgetAll() allCache, allAt = nil, nil end

-- Check prices' listings: { [item] = { avg (each, for the queue's amount), low, listed, at } }.
W.live = W.live or {}

-- The market price of an item: Check prices' listings while fresh (the average for the queued amount), else the
-- saved lowest price.
local function marketPrice(id)
  local lv = W.live[id]
  if lv and lv.avg and time() - (lv.at or 0) < LIVE_FOR then return lv.avg, lv.at end
  return priceOf(id)
end
W.marketPrice = marketPrice

-- What you paid lately for each item at this auction house (the AH log), unless that's turned off.
function W.paid()
  local d = db()
  if not d or settings().noPaid then return nil end
  return Pr.paidPrices(d.bought, houseKey(), time(), Pr.PAID_DAYS)
end

-- The rows, worked out again from the saved recipes and prices (best profit first; render sorts them as chosen).
local function compute(scope)
  local s = settings()
  local sources = W.sources()
  local recipes, who = Pr.merge(sources)
  local ctx = Pr.context({ recipes = recipes, price = marketPrice, cut = ns.ahCut and ns.ahCut() or 0.05,
    craftMats = not s.noCraft, info = Pr.info, paid = W.paid() })
  scope = scope or W.scope()
  local list
  if scope ~= "known" then
    local api = recipesAPI()
    local known = {}
    for id in pairs(recipes) do known[id] = true end
    list = api and Pr.scopeRecipes(scope, allRecipes(api), known, W.ranks(), function(id) return (priceOf(id)) end) or {}
    who = nil
  end
  local rows, counts = Pr.list(ctx, { from = s.from or 1, to = s.to or 300, min = s.min, maxCost = s.maxCost,
    minMargin = s.minMargin, q = s.q, nameOf = rowName, who = who, recipes = list,
    canMake = (scope == "known" and s.canMake) and crafterCan or nil, onAH = scope ~= "known" and s.onAH or nil,
    learnMax = scope ~= "known" and W.charSettings().recipeMax or nil })
  return ctx, rows, counts, sources
end
-- (the main window's start page counts the recipes you know, whatever the list shows)
function W.compute(scope) return compute(scope or "known") end

-- the sort chosen: column, high to low
-- Best profit first for the recipes you know; best margin first for the ones to learn.
function W.defaultSort() return W.scope() == "known" and "profit" or "margin" end
function W.sortState()
  local s = settings()
  local key = Pr.SORTS[s.sort] ~= nil and s.sort or W.defaultSort()
  local desc = s.desc
  if desc == nil then desc = Pr.SORTS[key] end
  return key, desc and true or false
end

function W.sortBy(key)
  if Pr.SORTS[key] == nil then return end
  local s = settings()
  local cur, desc = W.sortState()
  if cur == key then desc = not desc else desc = Pr.SORTS[key] end
  if key == W.defaultSort() and desc == Pr.SORTS[key] then s.sort, s.desc = nil, nil else s.sort, s.desc = key, desc end
  W.offset = 0
  W.render()
end

local function text(parent, size, color, justify)
  local fs = EUI.Text(parent, size or T.font, color or T.text)
  fs:SetJustifyH(justify or "LEFT")
  fs:SetWordWrap(false)
  return fs
end

---------------------------------------------------------------------------------------------------------------------
-- Money cells: gold, silver and copper each right-aligned in a column of its own

local function moneyCell(parent)
  local cell = CreateFrame("Frame", nil, parent)
  cell:SetSize(MONEY_W, ROW)
  cell.p = {}
  for i = 1, 3 do
    local fs = text(cell, T.font, T.text, "RIGHT")
    fs:SetPoint("RIGHT", cell, "RIGHT", -(3 - i) * COIN_W, 0)
    cell.p[i] = fs
  end
  return cell
end

local function setMoney(cell, copper, opt, color)
  local cells = Pr.coinCells(copper, opt)
  for i = 1, 3 do
    cell.p[i]:SetText(cells[i])
    cell.p[i]:SetTextColor(rgba(color or T.text))
  end
  cell.copper = copper
end

---------------------------------------------------------------------------------------------------------------------
-- Rows

-- "you", "Bob", "you + 2": who can make a row, when the list has alts
local function whoTag(who)
  if not W.multi or type(who) ~= "table" or #who == 0 then return "" end
  local first = who[1]
  local s = first.me and "|cffaab1bdyou|r" or ("|cff8d94a3" .. tostring(first.name or "?") .. "|r")
  if #who > 1 then s = s .. "|cff8d94a3 + " .. (#who - 1) .. "|r" end
  return s
end
W.whoTag = whoTag

local function rowTooltip(self)
  local r = self.data
  if not r then return end
  ns.itemTipOwner(self)   -- next to the mouse; "Equipped" only with Shift (ItemTip.lua)
  if not pcall(GameTooltip.SetItemByID, GameTooltip, r.id) then GameTooltip:SetText(r.name or "?", 1, 1, 1) end
  GameTooltip:AddLine(" ")
  GameTooltip:AddLine(r.makes ~= 1 and ("One craft makes %s. Materials for one craft:"):format(r.makes) or "Materials for one craft:", 1, 0.82, 0)
  for _, m in ipairs(r.mats) do
    local n = itemName(m.id) or ("item " .. m.id)
    local right
    if m.paid then
      right = ("|cff%spaid %s each|r |cff8d94a3(%s)|r"):format(hex(PAID), ns.money(math.floor(m.paid.unit + 0.5)),
        ns.ago and ns.ago(m.paid.t) or "")
    elseif m.each then
      right = (m.how == "craft" and "craft it, %s each" or "market %s each"):format(ns.money(math.floor(m.each + 0.5)))
        .. (m.paidIn and (" |cff" .. hex(PAID) .. "(from what you paid)|r") or "")
    else
      right = "|cffff6060no AH price|r"
    end
    GameTooltip:AddDoubleLine(("%dx %s"):format(m.need, n), right, 1, 1, 1, 1, 1, 1)
    if m.paid then
      GameTooltip:AddDoubleLine(" ", m.market and ("market %s each"):format(ns.money(math.floor(m.market + 0.5)))
        or "no market price", 1, 1, 1, 0.55, 0.58, 0.64)
    end
  end
  if r.paid then
    GameTooltip:AddLine(("Blue: the cost uses what you paid for materials in the last %d days, the market price for the rest.")
      :format(Pr.PAID_DAYS), PAID[1], PAID[2], PAID[3], true)
  end
  local lv = W.live[r.id]
  if lv and lv.at and time() - lv.at < LIVE_FOR then
    GameTooltip:AddLine(("Checked %s: %s listed, from %s each."):format(ns.ago and ns.ago(lv.at) or "just now",
      tostring(lv.listed or 0), lv.low and ns.money(lv.low) or "?"), 0.55, 0.58, 0.64, true)
  end
  if W.multi and type(r.who) == "table" and #r.who > 0 then
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(settings().canMake and "Can make it now:" or "Can make it:", 1, 0.82, 0)
    for _, c in ipairs(r.who) do
      GameTooltip:AddDoubleLine(charName(c) .. (c.me and " |cff8d94a3(you)|r" or ""), profText(c.profs), 1, 1, 1, 0.55, 0.58, 0.64)
    end
  end
  if r.start then
    local st = r.start
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("You don't know this recipe yet. To start:", 1, 0.82, 0)
    local how
    if st.how == "trainer" then how = "From a trainer" .. ((st.cost or 0) > 0 and (", " .. ns.money(st.cost)) or "")
    elseif st.how == "vendor" then how = "The recipe from a vendor, " .. ns.money(st.vendor or st.cost)
    elseif st.how == "ah" then how = "The recipe on the auction house now, " .. ns.money(st.ah or st.cost)
    elseif st.how == "unknown" then how = "Source unknown"
    else how = "Learned from: " .. st.how end
    if st.how ~= "ah" and st.ah then how = how .. " (on the AH: " .. ns.money(st.ah) .. ")" end
    if st.fee and st.how ~= "trainer" then how = how .. ", plus a trainer fee of " .. ns.money(st.fee) end
    GameTooltip:AddLine(how, 1, 1, 1, true)
    local sk = Pr.skillText(st)
    if sk then GameTooltip:AddLine(sk, 1, 0.4, 0.4, true)
    else GameTooltip:AddLine(("Needs %d %s, you're %d."):format(st.need or 1, st.prof or "", st.rank or 0), 0.55, 0.58, 0.64, true) end
    local pb = r.profit and Pr.paybackText(st, r.profit, ns.money)
    if pb then GameTooltip:AddLine(pb, 0.38, 0.81, 0.53, true) end
    if st.item and W.inAH then
      GameTooltip:AddLine("Right-click: find the recipe in Buy.", 0.55, 0.55, 0.55, true)
    end
  end
  if r.approx then
    GameTooltip:AddLine("A material has no AH price, so the cost is too low and the real profit lower.", 1, 0.4, 0.4, true)
  end
  if r.oldest and stale(r.oldest) then
    GameTooltip:AddLine("The oldest price used is from " .. ns.ago(r.oldest) .. ". Update prices at the auction house.", 0.6, 0.6, 0.6, true)
  end
  if queueAPI() and r.rid then
    local n = W.planned(r)
    GameTooltip:AddLine(n and ("In your crafting queue: %d. Change the box to queue more or fewer (0 takes it off)."):format(n)
      or "Click: queue 5 in your crafting queue (EverlookDB Crafting); type another number in its box.", 0.55, 0.55, 0.55, true)
    GameTooltip:AddLine("Shift-click links the item.", 0.55, 0.55, 0.55, true)
  else
    GameTooltip:AddLine("Type how many crafts in its box to plan them. Shift-click links the item.", 0.55, 0.55, 0.55, true)
  end
  if W.inAH and not r.start then
    local n = bagCount(r.id)
    GameTooltip:AddLine(n > 0 and ("Right-click: sell it in Quick sell (%d in your bags)."):format(n)
      or "Right-click: sell it in Quick sell, once you've made it.", 0.55, 0.55, 0.55, true)
  end
  GameTooltip:Show()
end

local function makeRow(parent)
  local row = CreateFrame("Button", nil, parent)
  row:SetHeight(ROW)
  row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  row.bg = U.Round(row, 4, "BACKGROUND")
  row.bg:SetPoint("TOPLEFT", -6, 0)
  row.bg:SetPoint("BOTTOMRIGHT", 6, 0)
  row.bg:SetVertexColor(rgba(T.surfaceHi))
  row.bg:Hide()
  row.crafts = EUI.EditBox(row, CRAFTS_W, 20)
  row.crafts:SetPoint("RIGHT", 0, 0)
  row.crafts:SetNumeric(true)
  row.crafts:SetMaxLetters(3)
  row.crafts:SetJustifyH("RIGHT")
  row.crafts:SetTextInsets(4, 6, 0, 0)
  row.crafts:SetScript("OnTextChanged", function(self, user)
    if not user or not row.data then return end
    local n = tonumber(self:GetText()) or 0
    W.setPlanned(row.data, n)
    W.footer()
  end)
  row.crafts:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
  row.margin = text(row, T.font, T.muted, "RIGHT")
  row.margin:SetPoint("RIGHT", row.crafts, "LEFT", -GAP, 0)
  row.margin:SetWidth(MARGIN_W)
  row.profit = moneyCell(row)
  row.profit:SetPoint("RIGHT", row.margin, "LEFT", -GAP, 0)
  row.sale = moneyCell(row)
  row.sale:SetPoint("RIGHT", row.profit, "LEFT", -GAP, 0)
  row.cost = moneyCell(row)
  row.cost:SetPoint("RIGHT", row.sale, "LEFT", -GAP, 0)
  row.skill = text(row, T.font, T.muted, "RIGHT")
  row.skill:SetPoint("RIGHT", row.cost, "LEFT", -GAP, 0)
  row.skill:SetWidth(SKILL_W)
  row.icon = row:CreateTexture(nil, "ARTWORK")
  row.icon:SetSize(18, 18)
  row.icon:SetPoint("LEFT", 0, 0)
  row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  -- who can make it (with alts): its own text at the end of the name's room, so a long name never hides it
  row.tag = text(row, T.font - 1, T.muted, "RIGHT")
  row.tag:SetPoint("RIGHT", row.skill, "LEFT", -GAP, 0)
  row.name = text(row, T.font)
  row.name:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
  row.name:SetPoint("RIGHT", row.tag, "LEFT", -6, 0)
  row:SetScript("OnEnter", function(self) self.bg:Show(); rowTooltip(self) end)
  row:SetScript("OnLeave", function(self) self.bg:Hide(); GameTooltip:Hide() end)
  row:SetScript("OnClick", function(self, button)
    local r = self.data
    if not r then return end
    if button == "RightButton" then W.sell(r); return end
    if IsShiftKeyDown() then
      local okInfo, _, link = pcall(C_Item.GetItemInfo, r.id)
      if okInfo and link and ChatEdit_InsertLink then ChatEdit_InsertLink(link) end
      return
    end
    -- with the crafting queue: a click on a row with nothing queued queues 5 (the box can change it)
    if queueAPI() and r.rid and not W.planned(r) then
      W.setPlanned(r, 5)
      self.crafts:SetText("5")
      W.footer()
    end
    self.crafts:SetFocus()
  end)
  return row
end

local function paintRow(row, r)
  row.data = r
  row.icon:SetTexture(try(C_Item.GetItemIconByID, r.id) or 134400)
  if r.start then
    -- a recipe you don't know: how to start, in green when it's easy, grey otherwise
    local st = r.start
    row.tag:SetText("|cff" .. hex((st.how == "trainer" or st.how == "vendor" or st.how == "ah") and T.ok or T.muted)
      .. Pr.startText(st) .. "|r")
  else
    local who = whoTag(r.who)
    row.tag:SetText(r.paid and ("|cff" .. hex(PAID) .. "paid|r" .. (who ~= "" and ("  " .. who) or "")) or who)
  end
  row.name:SetText(rowName(r) or ("item " .. r.id))
  row.name:SetTextColor(qualityColor(r.id))
  row.skill:SetText(r.skill and tostring(r.skill) or "?")
  local above = r.start and (r.start.rank == nil or (r.start.need or 1) > r.start.rank)
  row.skill:SetTextColor(rgba(above and T.danger or T.muted))
  local old = r.oldest and stale(r.oldest)
  setMoney(row.cost, r.cost, { prefix = r.approx and "≈ " or nil },
    r.approx and T.danger or (r.paid and PAID) or (old and T.muted or T.text))
  setMoney(row.sale, r.sale, nil, stale(r.lowAt) and T.muted or T.text)
  setMoney(row.profit, r.profit, { prefix = r.approx and "≈ " or nil, sign = not r.approx }, r.profit > 0 and T.ok or T.danger)
  -- no margin for a row with an unpriced material: its cost is too low, so the percentage would mean nothing
  row.margin:SetText((r.margin and not r.approx) and (("%+d%%"):format(math.floor(r.margin * 100 + 0.5))) or "")
  local n = W.planned(r)
  if not (row.crafts.HasFocus and row.crafts:HasFocus()) then row.crafts:SetText(n and tostring(n) or "") end
end

---------------------------------------------------------------------------------------------------------------------
-- The filters

local function numberBox(parent, w, letters, onChange)
  local b = EUI.EditBox(parent, w, 24)
  b:SetNumeric(true)
  b:SetMaxLetters(letters)
  b:SetJustifyH("RIGHT")
  b:SetTextInsets(4, 8, 0, 0)
  b:SetScript("OnTextChanged", function(self, user) if user then onChange(tonumber(self:GetText())) end end)
  b:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
  return b
end

-- A box for money: "1g 20s", "120s", "1.2g" or a plain number of silver. A box that isn't money goes red and changes
-- nothing; leaving it writes the amount back the same way every time ("1g 20s").
local function moneyBox(parent, w, field, tip, store)
  store = store or settings
  local b = EUI.EditBox(parent, w, 24)
  b:SetMaxLetters(16)
  b:SetJustifyH("RIGHT")
  b:SetTextInsets(4, 8, 0, 0)
  b:SetScript("OnTextChanged", function(self, user)
    if not user then return end
    local c, good = Pr.parseMoney(self:GetText())
    if self.border and self.border.SetColor then self.border:SetColor(rgba(good and T.accent or T.danger)) end
    if not good then return end
    store()[field] = (c and c > 0) and c or nil
    W.offset = 0
    W.render()
  end)
  b:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
  b:HookScript("OnEditFocusLost", function(self)
    if self.border and self.border.SetColor then self.border:SetColor(rgba(T.border)) end
    local v = store()[field]
    self:SetText(v and Pr.moneyText(v) or "")
  end)
  b:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:SetText(tip, 1, 1, 1)
    GameTooltip:AddLine("Type 1g 20s, 120s, 1.2g or 50c. A plain number is silver.", nil, nil, nil, true)
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)
  return b
end

-- A tick box with its words; the whole thing clicks.
local function tickBox(parent, label, width, onClick)
  local b = CreateFrame("Button", nil, parent)
  b:SetSize(width, 24)
  b.box = CreateFrame("Frame", nil, b)
  b.box:SetSize(16, 16)
  b.box:SetPoint("LEFT", 0, 0)
  b.box.fill, b.box.edge = U.RoundBox(b.box, 4, T.surface, T.border)
  b.check = b.box:CreateTexture(nil, "OVERLAY")
  b.check:SetSize(12, 12)
  b.check:SetPoint("CENTER")
  if EUI.SetIcon(b.check, "check") then b.check:SetVertexColor(rgba(T.accent)) else b.check:SetTexture(CHECK_TEX) end
  b.label = text(b, T.font, T.muted)
  b.label:SetPoint("LEFT", b.box, "RIGHT", 6, 0)
  b.label:SetText(label)
  function b:SetOn(on)
    self.on = on and true or false
    self.check:SetShown(self.on)
    self.label:SetTextColor(rgba(self.on and T.text or T.muted))
  end
  b:SetScript("OnClick", function(self) onClick(not self.on) end)
  b:SetScript("OnEnter", function(self) self.label:SetTextColor(rgba(T.text)) end)
  b:SetScript("OnLeave", function(self) self.label:SetTextColor(rgba(self.on and T.text or T.muted)) end)
  b:SetOn(false)
  return b
end

-- A text link (no button look): muted, the accent under the mouse.
local function link(parent, label, onClick)
  local b = CreateFrame("Button", nil, parent)
  b:SetSize(90, 24)
  b.label = text(b, T.font, T.muted, "RIGHT")
  b.label:SetPoint("RIGHT", 0, 0)
  b.label:SetText(label)
  b:SetScript("OnClick", onClick)
  b:SetScript("OnEnter", function(self) self.label:SetTextColor(rgba(T.accent)) end)
  b:SetScript("OnLeave", function(self) self.label:SetTextColor(rgba(T.muted)) end)
  return b
end

-- The alts list: one row per character with recipes (you at the top, always in), a tick per alt. The list stays
-- open while you tick.
function W.openAlts(owner)
  local chars = W.characters()
  local ticks = W.altTicks()
  local items = {}
  local alts = 0
  for _, c in ipairs(chars) do
    local line = charName(c) .. "  |cff8d94a3" .. profText(c.profs) .. "|r"
    if c.me then
      items[#items + 1] = { title = true, text = line .. "  |cff8d94a3(you, always in)|r" }
    else
      alts = alts + 1
      items[#items + 1] = { value = c.key, text = line, icon = ticks[c.key] and CHECK_TEX or BOX_TEX }
    end
  end
  if alts == 0 then
    items[#items + 1] = { title = true, text = "No alts with recipes yet: open each alt's profession windows once." }
  end
  if EUI.OpenPopup then
    EUI.OpenPopup(owner, items, nil, function(key)
      W.toggleAlt(key)
      W.openAlts(owner)
    end, { width = 360 })
  end
end

local function altsLabel()
  local ticks = W.altTicks()
  local n, one = 0, nil
  for _, c in ipairs(W.characters()) do
    if not c.me and ticks[c.key] then n = n + 1; one = c end
  end
  if n == 0 then return "Alts: none" end
  if n == 1 then return "Alts: " .. tostring(one.name or "?") end
  return "Alts: " .. n
end

-- Puts the saved filters into their boxes.
function W.fillBoxes()
  local f = W.frame
  if not f then return end
  local s = settings()
  f.search:SetText(s.q or "")
  f.search.hint:SetShown((s.q or "") == "")
  f.from:SetText(tostring(s.from or 1))
  f.to:SetText(tostring(s.to or 300))
  f.min:SetText(s.min and Pr.moneyText(s.min) or "")
  f.margin:SetText(s.minMargin and tostring(s.minMargin) or "")
  f.maxCost:SetText(s.maxCost and Pr.moneyText(s.maxCost) or "")
  f.canMake:SetOn(s.canMake)
  f.onAH:SetOn(s.onAH)
  local rm = W.charSettings().recipeMax
  f.recipeMax:SetText(rm and Pr.moneyText(rm) or "")
end

-- The scope buttons: the one shown bright and underlined; the tick that fits the scope.
function W.paintScopes()
  local f = W.frame
  if not f or not f.scopes then return end
  local sc = W.scope()
  for _, b in ipairs(f.scopes) do
    local on = b.scope == sc
    b.label:SetTextColor(rgba(on and T.text or T.muted))
    b.line:SetShown(on)
  end
  f.canMake:SetShown(sc == "known")
  f.onAH:SetShown(sc ~= "known")
  f.recipeL:SetShown(sc ~= "known")
  f.recipeMax:SetShown(sc ~= "known")
end

function W.clearFilters()
  Pr.clearFilters(settings())
  W.charSettings().recipeMax = nil
  W.offset = 0
  W.fillBoxes()
  W.render()
end

---------------------------------------------------------------------------------------------------------------------
-- The window

local function makeFrame()
  if W.frame then return W.frame end
  if not EUI then return nil end
  T = EUI.MakeTheme(ns.T and ns.T.accent or { 1, 0.82, 0 })
  W.crafts = W.crafts or {}
  local f = CreateFrame("Frame", "EverlookAuctionsProfit", UIParent)
  f.eluiTheme = T
  if UI and UI.own then UI.own(f) end
  f:SetWidth(WIDTH)
  f:SetFrameStrata("HIGH")
  f:SetToplevel(true)
  f:SetClampedToScreen(true)
  f:EnableMouse(true)
  f:SetMovable(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local p, _, rp, x, y = self:GetPoint()
    settings().pos = { p, rp, x, y }
  end)
  f:EnableMouseWheel(true)
  f:SetScript("OnMouseWheel", function(_, delta)
    W.offset = math.max(0, (W.offset or 0) - delta * 3)
    W.render(true)
  end)
  EUI.WindowChrome(f, T)
  f.closeButton = EUI.CloseButton(f, T)

  f.icon = f:CreateTexture(nil, "ARTWORK")
  f.icon:SetSize(18, 18)
  f.icon:SetPoint("TOPLEFT", 20, -20)
  if EUI.SetIcon(f.icon, "hammer") then f.icon:SetVertexColor(rgba(T.accent)) end
  f.title = text(f, T.fontHuge, T.text)
  f.title:SetPoint("LEFT", f.icon, "RIGHT", 8, 0)
  f.title:SetText("Crafting profit")
  f.gear = CreateFrame("Button", nil, f)
  f.gear:SetSize(24, 24)
  f.gear:SetPoint("TOPRIGHT", -38, -10)
  f.gear.icon = f.gear:CreateTexture(nil, "ARTWORK")
  f.gear.icon:SetSize(13, 13)
  f.gear.icon:SetPoint("CENTER")
  EUI.SetIcon(f.gear.icon, "gear")
  f.gear.icon:SetVertexColor(rgba(T.muted))
  f.gear:SetScript("OnClick", function() if ns.app then ns.app:Open("profit") end end)
  f.gear:SetScript("OnEnter", function(self)
    self.icon:SetVertexColor(rgba(T.text))
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText("Crafting profit settings", 1, 1, 1)
    GameTooltip:AddLine("Making materials yourself, the minimum profit.", nil, nil, nil, true)
    GameTooltip:Show()
  end)
  f.gear:SetScript("OnLeave", function(self) self.icon:SetVertexColor(rgba(T.muted)); GameTooltip:Hide() end)
  f.sub = text(f, T.font - 1, T.muted)
  f.sub:SetPoint("TOPLEFT", 20, -48)
  f.sub:SetPoint("RIGHT", -20, 0)

  -- filters, first row: search, skill from-to, only what I can make now; Clear crafts on the right
  local function changed() W.offset = 0; W.render() end
  f.search = EUI.EditBox(f, 170, 24)
  f.search:SetPoint("TOPLEFT", 20, -70)
  f.search:SetMaxLetters(40)
  f.search.hint = text(f.search, T.font, T.muted)
  f.search.hint:SetPoint("LEFT", 8, 0)
  f.search.hint:SetText("Search recipes")
  f.search:SetScript("OnTextChanged", function(self, user)
    local q = self:GetText() or ""
    self.hint:SetShown(q == "")
    if not user then return end
    settings().q = q ~= "" and q or nil
    changed()
  end)
  f.search:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
  local lbl = text(f, T.font, T.muted)
  lbl:SetPoint("LEFT", f.search, "RIGHT", 16, 0)
  lbl:SetText("Skill")
  f.from = numberBox(f, 44, 3, function(v) settings().from = v; changed() end)
  f.from:SetPoint("LEFT", lbl, "RIGHT", 6, 0)
  local dash = text(f, T.font, T.muted)
  dash:SetPoint("LEFT", f.from, "RIGHT", 6, 0)
  dash:SetText("to")
  f.to = numberBox(f, 44, 3, function(v) settings().to = v; changed() end)
  f.to:SetPoint("LEFT", dash, "RIGHT", 6, 0)
  f.canMake = tickBox(f, "Only what I can make now", 176, function(on)
    settings().canMake = on or nil
    f.canMake:SetOn(on)
    changed()
  end)
  f.canMake:SetPoint("LEFT", f.to, "RIGHT", 16, 0)
  f.canMake:HookScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:SetText("Only what I can make now", 1, 1, 1)
    GameTooltip:AddLine("Recipes whose materials are in your bags right now (an alt's: in its bags when you last played it).", nil, nil, nil, true)
    GameTooltip:Show()
  end)
  f.canMake:HookScript("OnLeave", function() GameTooltip:Hide() end)
  f.onAH = tickBox(f, "Only recipes on the AH now", 176, function(on)
    settings().onAH = on or nil
    f.onAH:SetOn(on)
    changed()
  end)
  f.onAH:SetPoint("LEFT", f.to, "RIGHT", 16, 0)
  f.onAH:HookScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:SetText("Only recipes on the AH now", 1, 1, 1)
    GameTooltip:AddLine("Recipes whose recipe item is on the auction house in the last scan, to buy and learn today.", nil, nil, nil, true)
    GameTooltip:Show()
  end)
  f.onAH:HookScript("OnLeave", function() GameTooltip:Hide() end)
  f.onAH:Hide()

  -- the scope: the recipes you know, the ones easy to learn, every recipe
  f.scopes = {}
  local prevScope
  for _, d in ipairs({ { "known", "Recipes I know", "The recipes you know (and your alts', with Alts)." },
      { "easy", "Easy to get", "Recipes you don't know yet that are easy to learn: a trainer, a vendor or the auction house, at most " .. Pr.EASY .. " points over your skill." },
      { "all", "All recipes", "Every recipe of every profession you don't know yet, to find the best margins anywhere." } }) do
    local b = CreateFrame("Button", nil, f)
    b:SetHeight(22)
    b.label = text(b, T.font, T.muted, "CENTER")
    b.label:SetPoint("CENTER", 0, 1)
    b.label:SetText(d[2])
    b:SetWidth(math.max(70, math.floor((b.label:GetStringWidth() or 80) + 20)))
    b.line = U.Solid(b, "ARTWORK", rgba(T.accent))
    b.line:SetHeight(2)
    b.line:SetPoint("BOTTOMLEFT", 6, 0)
    b.line:SetPoint("BOTTOMRIGHT", -6, 0)
    b.scope = d[1]
    b:SetScript("OnClick", function() W.setScope(d[1]) end)
    b:SetScript("OnEnter", function(self)
      self.label:SetTextColor(rgba(T.text))
      GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
      GameTooltip:SetText(d[2], 1, 1, 1)
      GameTooltip:AddLine(d[3], nil, nil, nil, true)
      GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() W.paintScopes(); GameTooltip:Hide() end)
    if prevScope then b:SetPoint("LEFT", prevScope, "RIGHT", 4, 0) end
    prevScope = b
    f.scopes[#f.scopes + 1] = b
  end
  f.clear = EUI.Button(f, "Clear crafts", function() W.clearPlanned() end, 110)
  f.clear:SetHeight(24)
  f.clear:SetPoint("TOPRIGHT", -20, -70)

  -- second row: profit at least, margin at least, cost at most, alts; Clear filters on the right
  local pl = text(f, T.font, T.muted)
  f.pl = pl
  pl:SetPoint("TOPLEFT", 20, -106)
  pl:SetText("Profit at least")
  f.min = moneyBox(f, 70, "min", "Profit at least")
  f.min:SetPoint("LEFT", pl, "RIGHT", 6, 0)
  local mgl = text(f, T.font, T.muted)
  mgl:SetPoint("LEFT", f.min, "RIGHT", 14, 0)
  mgl:SetText("Margin at least")
  f.margin = numberBox(f, 40, 4, function(v) settings().minMargin = v; changed() end)
  f.margin:SetPoint("LEFT", mgl, "RIGHT", 6, 0)
  local pct = text(f, T.font, T.muted)
  pct:SetPoint("LEFT", f.margin, "RIGHT", 4, 0)
  pct:SetText("%")
  local cl = text(f, T.font, T.muted)
  cl:SetPoint("LEFT", pct, "RIGHT", 14, 0)
  cl:SetText("Cost at most")
  f.maxCost = moneyBox(f, 70, "maxCost", "Cost at most")
  f.maxCost:SetPoint("LEFT", cl, "RIGHT", 6, 0)
  if EUI.DropButton then
    f.alts, f.altsText = EUI.DropButton(f, T, 150)
    f.alts:SetHeight(24)
    f.alts:SetPoint("LEFT", f.maxCost, "RIGHT", 14, 0)
    f.alts:SetScript("OnClick", function(self) W.openAlts(self) end)
    f.alts:HookScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
      GameTooltip:SetText("Alts", 1, 1, 1)
      GameTooltip:AddLine("Add the recipes your other characters know (from EverlookDB Crafting). Each row then says who can make it.", nil, nil, nil, true)
      GameTooltip:Show()
    end)
    f.alts:HookScript("OnLeave", function() GameTooltip:Hide() end)
  end
  f.recipeL = text(f, T.font, T.muted)
  f.recipeL:SetPoint("LEFT", f.maxCost, "RIGHT", 14, 0)
  f.recipeL:SetText("Recipe under")
  f.recipeMax = moneyBox(f, 70, "recipeMax", "Recipe under", W.charSettings)
  f.recipeMax:SetPoint("LEFT", f.recipeL, "RIGHT", 6, 0)
  f.recipeMax:HookScript("OnEnter", function()
    GameTooltip:AddLine("Recipes you don't know yet whose cheapest way to learn (the AH, a vendor or a trainer's fee) costs at most this. Empty: any. Kept for this character.", nil, nil, nil, true)
    GameTooltip:Show()
  end)
  f.recipeL:Hide()
  f.recipeMax:Hide()
  f.clearFilters = link(f, "Clear filters", function() W.clearFilters() end)
  f.clearFilters:SetPoint("TOPRIGHT", -20, -100)

  -- the list card
  f.list = CreateFrame("Frame", nil, f)
  f.list.fill, f.list.edge = U.RoundBox(f.list, T.radius, T.card, T.divider)
  f.list:SetPoint("TOPLEFT", 16, LIST_TOP)
  f.list:SetPoint("RIGHT", -16, 0)
  local head = CreateFrame("Frame", nil, f.list)
  head:SetHeight(16)
  head:SetPoint("TOPLEFT", PAD, -10)
  head:SetPoint("RIGHT", -PAD, 0)
  f.heads = {}
  -- a heading: click sorts by it, again the other way; the arrow shows the sort
  local function heading(key, label, width, right, left)
    local h = CreateFrame("Button", nil, head)
    h:SetHeight(16)
    if left then
      h:SetPoint("LEFT", head, "LEFT", 24, 0)
      h:SetWidth(width)
    else
      h:SetPoint("RIGHT", head, "RIGHT", -right, 0)
      h:SetWidth(width)
    end
    h.label = text(h, T.fontSmall, T.muted, left and "LEFT" or "RIGHT")
    h.label:SetText(label)
    if left then h.label:SetPoint("LEFT", 0, 0) else h.label:SetPoint("RIGHT", 0, 0) end
    h.arrow = h:CreateTexture(nil, "ARTWORK")
    h.arrow:SetSize(8, 8)
    if left then h.arrow:SetPoint("LEFT", h.label, "RIGHT", 4, 0) else h.arrow:SetPoint("RIGHT", h.label, "LEFT", -4, 0) end
    if not EUI.SetIcon(h.arrow, "chevron") then h.arrow:SetTexture("Interface\\Buttons\\Arrow-Down-Up") end
    h.arrow:Hide()
    h.key = key
    h:SetScript("OnClick", function() W.sortBy(key) end)
    h:SetScript("OnEnter", function(self)
      self.label:SetTextColor(rgba(T.text))
      GameTooltip:SetOwner(self, "ANCHOR_TOP")
      GameTooltip:SetText("Sort by " .. label:lower(), 1, 1, 1)
      GameTooltip:AddLine("Click again for the other way.", nil, nil, nil, true)
      GameTooltip:Show()
    end)
    h:SetScript("OnLeave", function(self) W.paintHeads(); GameTooltip:Hide() end)
    f.heads[key] = h
    return h
  end
  local x = 0
  local function col(key, label, width)
    heading(key, label, width, x)
    x = x + width + GAP
  end
  col("crafts", "CRAFTS", CRAFTS_W)
  col("margin", "MARGIN", MARGIN_W)
  col("profit", "PROFIT", MONEY_W)
  col("sale", "SELLS FOR", MONEY_W)
  col("cost", "COST", MONEY_W)
  col("skill", "SKILL", SKILL_W)
  heading("name", "RECIPE", 120, nil, true)
  f.rows = {}
  for i = 1, ROWS do
    local row = makeRow(f.list)
    row:SetPoint("TOPLEFT", PAD, -32 - (i - 1) * ROW)
    row:SetPoint("RIGHT", -PAD, 0)
    f.rows[i] = row
  end
  f.empty = text(f.list, T.font, T.muted)
  f.empty:SetWordWrap(true)
  f.empty:SetPoint("TOPLEFT", PAD, -36)
  f.empty:SetPoint("RIGHT", -PAD, 0)
  f.foot = U.Solid(f.list, "ARTWORK", rgba(T.divider))
  f.foot:SetHeight(1)
  f.note = text(f.list, T.font - 1, T.muted)
  f.note:SetWordWrap(true)
  f.pos = text(f.list, T.font - 1, T.muted, "RIGHT")

  -- under the card: the selection, the one gold button, what happened
  f.sum = text(f, T.font, T.text)
  f.sum:SetWordWrap(true)
  f.make = EUI.Button(f, "Make shopping list", function()
    if W.inAH then W.buyMaterials() else W.makeList() end
  end, 170, "accent")
  -- Check prices: plain, right before the gold button (check, then buy)
  f.check = EUI.Button(f, "Check prices", function() W.checkPrices() end, CHECK_W)
  f.check:HookScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText("Check prices", 1, 1, 1)
    GameTooltip:AddLine("The profits above are estimates from the last scan. This looks at the auction house right now for the queued recipes' materials and what they make, and says for each: good, thin, or not worth it (those come out of the queue; Undo puts them back). Needs the auction house open.", nil, nil, nil, true)
    GameTooltip:Show()
  end)
  f.check:HookScript("OnLeave", function() GameTooltip:Hide() end)
  f.undo = EUI.Button(f, "Undo", function() W.undoCheck() end, 70)
  f.undo:Hide()
  f.status = text(f, T.font - 1, T.muted)
  f.status:SetWordWrap(true)

  EUI.CloseOnEscape(f)
  local pos = settings().pos
  if pos then f:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4]) else f:SetPoint("CENTER", 0, 40) end
  f:Hide()
  W.frame = f
  W.fillBoxes()
  W.chrome(f)
  return f
end

-- The headings: the sorted one bright with its arrow (down: high to low).
function W.paintHeads()
  local f = W.frame
  if not f or not f.heads then return end
  local key, desc = W.sortState()
  for k, h in pairs(f.heads) do
    local on = k == key
    h.label:SetTextColor(rgba(on and T.text or T.muted))
    h.arrow:SetShown(on)
    if on then
      h.arrow:SetVertexColor(rgba(T.accent))
      if h.arrow.SetRotation then h.arrow:SetRotation(desc and 0 or math.pi) end
    end
    if on then h.desc = desc else h.desc = nil end
  end
end

-- The selection line under the list: how many crafts are planned, what they cost and make.
function W.footer()
  local f = W.frame
  if not f then return end
  local q = queueAPI()
  f.clear:SetText(W.clearArmed and "Click again" or (q and "Clear queue" or "Clear crafts"))
  if f.heads and f.heads.crafts then f.heads.crafts.label:SetText(q and "QUEUE" or "CRAFTS") end
  if q then return W.queueFooter(q) end
  local picks = {}
  for _, r in ipairs(W.rows or {}) do
    if W.crafts[r.id] then picks[#picks + 1] = { row = r, crafts = W.crafts[r.id] } end
  end
  W.picks = picks
  local cost, profit, crafts, approx = Pr.totals(picks)
  local paid = false
  for _, p in ipairs(picks) do paid = paid or (p.row.paid and true) or false end
  if crafts == 0 then
    f.sum:SetText("Type how many crafts you plan in a recipe's box, then make a shopping list.")
    f.sum:SetTextColor(rgba(T.muted))
  else
    f.sum:SetText(("Planned: %d %s, %d %s.  Gold in %s%s,  profit %s%s%s"):format(#picks, #picks == 1 and "recipe" or "recipes",
      crafts, crafts == 1 and "craft" or "crafts", approx and "≈ " or "", ns.money(cost), approx and "≈ " or "",
      (profit < 0 and "-" or "") .. ns.money(math.abs(profit)), paid and (" |cff" .. hex(PAID) .. "at what you paid|r") or "")
      .. W.nudge(picks))
    f.sum:SetTextColor(rgba(T.text))
  end
  W.paintButtons(crafts)
end

-- "Check prices before you buy." while a planned recipe hasn't been checked in the last half hour.
function W.nudge(picks)
  local now = time()
  for _, p in ipairs(picks or {}) do
    local id = p.row and p.row.id
    local lv = id and W.live[id]
    if not (lv and now - (lv.at or 0) < LIVE_FOR) then
      return "  |cff" .. hex(T.muted) .. "Check prices before you buy.|r"
    end
  end
  return ""
end

-- The gold button, and Check prices right before it (both usable with something planned; Make shopping list never
-- waits for a check).
function W.paintButtons(crafts)
  local f = W.frame
  f.make:SetText(W.inAH and "Buy materials" or "Make shopping list")
  f.make:SetUsable(crafts > 0)
  local c = W.check
  f.check:SetText(c and ("Checking %d/%d"):format(math.min(c.i, #c.order), #c.order) or "Check prices")
  f.check:SetUsable(crafts > 0 or c ~= nil)
end

-- The line under the list with the crafting queue: what is queued (all of it, also what the filters hide), its profit
-- where each recipe's is known, and what Buy materials will buy.
function W.queueFooter(q)
  local f = W.frame
  local list = try(q.queue) or {}
  local recipes, crafts, profit, cost, unknown, paid = 0, 0, 0, 0, 0, false
  -- every queued recipe, also those the filters hide, at the page's prices (what you paid, where you did)
  local byRid = {}
  for _, p in ipairs(W.ctx and W.queuePicks(W.ctx) or {}) do byRid[p.spell] = p.row end
  for _, r in ipairs(W.rows or {}) do if r.rid and not byRid[r.rid] then byRid[r.rid] = r end end
  local seen = {}
  for _, e in ipairs(list) do
    local n = tonumber(e.n) or 0
    if n > 0 then
      recipes, crafts = recipes + 1, crafts + n
      local row = byRid[e.spell]
      local each = (row and not row.approx and row.profit) or e.profit
      if each then profit = profit + each * n else unknown = unknown + 1 end
      if row and not row.approx and row.profit then
        cost = cost + (row.cost or 0) * n
        paid = paid or (row.paid and true) or false
      end
      seen[#seen + 1] = { row = row or { id = e.creates } }
    end
  end
  W.picks = {}
  if crafts == 0 then
    f.sum:SetText("Click a recipe to queue 5, or type how many in its box. The queue is shared with EverlookDB Crafting.")
    f.sum:SetTextColor(rgba(T.muted))
  else
    local a = unknown > 0 and "≈ " or ""
    f.sum:SetText(("Crafting queue: %d %s, %d %s.  Cost %s%s, profit %s%s%s%s"):format(recipes, recipes == 1 and "recipe" or "recipes",
      crafts, crafts == 1 and "craft" or "crafts", a, ns.money(cost), a, (profit < 0 and "-" or "+") .. ns.money(math.abs(profit)),
      paid and (" |cff" .. hex(PAID) .. "at what you paid|r") or "",
      unknown > 0 and (" (%d without a price)"):format(unknown) or "") .. W.nudge(seen))
    f.sum:SetTextColor(rgba(T.text))
  end
  W.paintButtons(crafts)
end

-- The queued recipes, each worked out with ctx (all of them, whatever the filters): { { row, n, spell } }; without the
-- crafting queue, the crafts planned here.
function W.queuePicks(ctx)
  local out = {}
  local recipes = ctx and ctx.recipes or {}
  local q = queueAPI()
  if q then
    for _, e in ipairs(try(q.queue) or {}) do
      local n = tonumber(e.n) or 0
      local r = e.creates and recipes[e.creates]
      if n > 0 and r then
        local row = Pr.row(ctx, e.creates, r)
        row.rid = row.rid or e.spell
        out[#out + 1] = { row = row, n = n, spell = e.spell }
      end
    end
  else
    for id, n in pairs(W.crafts or {}) do
      local r = recipes[id]
      if r and (tonumber(n) or 0) > 0 then out[#out + 1] = { row = Pr.row(ctx, id, r), n = n } end
    end
  end
  return out
end

-- Clear crafts (here) or Clear queue (EverlookDB Crafting's, for both addons: a second click within 4 seconds).
function W.clearPlanned()
  local q = queueAPI()
  if q then
    local now = GetTime and GetTime() or 0
    if not W.clearArmed or now - W.clearArmed > 4 then
      W.clearArmed = now
      W.footer()
      if C_Timer and C_Timer.After then C_Timer.After(4, function() W.clearArmed = nil; if W.frame then W.footer() end end) end
      return
    end
    W.clearArmed = nil
    try(q.queueClear)
  else
    wipe(W.crafts)
  end
  W.status, W.undo = nil, nil
  W.render()
end

-- Draws the window. keep: only scrolled, so the rows aren't worked out again.
function W.render(keep)
  local f = W.frame
  if not (f and f:IsShown()) then return end
  local d = db() or {}
  local s = settings()
  if not keep or not W.rows or not W.ctx then
    local ctx, rows, counts, sources = compute()
    W.ctx = ctx
    local key, desc = W.sortState()
    Pr.sort(rows, key, desc, { nameOf = rowName, crafts = W.plannedMap() })
    W.rows, W.counts = rows, counts
    W.multi = #sources > 1
  end
  local rows, counts = W.rows, W.counts
  W.paintHeads()
  W.paintScopes()
  if f.alts then
    f.alts:SetShown(craftAPI() ~= nil and W.scope() == "known")
    f.altsText:SetText(altsLabel())
  end
  f.clearFilters:SetShown(Pr.filtered(s) or s.sort ~= nil or (W.scope() ~= "known" and W.charSettings().recipeMax ~= nil))
  local h = d.houses and d.houses[houseKey()]
  local nPrices = 0
  if h and h.items then for _ in pairs(h.items) do nPrices = nPrices + 1 end end
  -- other players' scan (shared prices) counts too, and says so when it is the newer one
  local sh = ns.shared and ns.shared.house(houseKey())
  if sh then for _ in pairs(sh.items) do nPrices = nPrices + 1 end end
  local pricesAt, shared = nil, false
  if ns.pricesAt then pricesAt, shared = ns.pricesAt(houseKey():match("%-(%a+)$")) end
  local _, side = houseKey():match("^(.*)%-(%a+)$")
  local where = side and (side .. " AH") or "your AH"
  local scope = W.scope()
  local whose = W.multi and "you and your alts know" or "you know"
  local from = ("From the %d recipes %s"):format(counts.known, whose)
  if scope == "easy" then
    from = ("%d recipes you can learn easily (a trainer, vendor or the AH, up to %d over your skill)"):format(counts.known, Pr.EASY)
  elseif scope == "all" then
    from = ("Every recipe you don't know yet (%d)"):format(counts.known)
  end
  if nPrices == 0 then
    f.sub:SetText(("%s. No prices yet for the %s."):format(from, where))
    f.sub:SetTextColor(rgba(T.danger))
  else
    local when = shared and ("other players', " .. ns.ago(pricesAt))
      or (h and h.scanned) and ns.ago(h.scanned) or "no full update yet"
    f.sub:SetText(("%s: estimates from the %s's last scan (%s), after its %d%% cut. Check prices before you buy."):format(from, where,
      when, math.floor((ns.ahCut and ns.ahCut() or 0.05) * 100 + 0.5)))
    f.sub:SetTextColor(rgba((not pricesAt or time() - pricesAt >= Pr.STALE) and T.danger or T.muted))
  end

  local n = W.rowsShown()
  local maxOff = math.max(0, #rows - n)
  W.offset = math.max(0, math.min(W.offset or 0, maxOff))
  local shown = 0
  for i = 1, ROWS do
    local r = i <= n and rows[W.offset + i]
    local row = f.rows[i]
    if r then paintRow(row, r); row:Show(); shown = i else row:Hide(); row.data = nil end
  end
  f.empty:SetShown(#rows == 0)
  if #rows == 0 then
    if scope ~= "known" and not recipesAPI() then
      f.empty:SetText("Recipes you don't know yet come from EverlookDB Crafting: it knows every recipe and where to learn it. Get it on CurseForge or with the EverlookDB App.")
    elseif scope == "easy" and counts.known == 0 and not next(W.ranks()) then
      f.empty:SetText("Open each of your profession windows once, so the addon knows your skill; recipes easy to learn show here after that.")
    elseif scope == "easy" and counts.known == 0 then
      f.empty:SetText("Nothing easy to learn right now: no trainer, vendor or AH recipe near your skill. Try All recipes.")
    elseif counts.known == 0 then
      f.empty:SetText("No recipes yet. Open each of your profession windows once, so the addon learns your recipes; they show here after that.")
    elseif Pr.filtered(s) and counts.noSale < counts.known then
      f.empty:SetText("No recipe matches these filters. Loosen one, or click Clear filters to see them all.")
    elseif nPrices == 0 then
      f.empty:SetText("No auction prices yet. Open the auction house: prices update by themselves while it is open (or type /eah scan there).")
    else
      f.empty:SetText("No recipe has an auction price for what it makes yet.")
    end
  end

  local y = -32 - math.max(shown, #rows == 0 and 2 or 0) * ROW - 8
  f.foot:ClearAllPoints()
  f.foot:SetPoint("TOPLEFT", PAD, y)
  f.foot:SetPoint("TOPRIGHT", -PAD, y)
  local notes = {}
  if counts.approx > 0 then
    notes[#notes + 1] = ("≈ %d %s a material with no AH price: the cost shown is too low."):format(counts.approx,
      counts.approx == 1 and "recipe has" or "recipes have")
  end
  local paidRows = 0
  for _, r in ipairs(rows) do if r.paid then paidRows = paidRows + 1 end end
  if paidRows > 0 then
    notes[#notes + 1] = ("|cff%sBlue cost: what you paid in the last %d days.|r"):format(hex(PAID), Pr.PAID_DAYS)
  end
  if counts.noSale > 0 then
    notes[#notes + 1] = ("%d %s left out: no AH price for what %s."):format(counts.noSale,
      counts.noSale == 1 and "recipe" or "recipes", counts.noSale == 1 and "it makes" or "they make")
  end
  f.note:SetText(#notes > 0 and table.concat(notes, "  ") or W.inAH
    and "Prices over a day old are grey. Hover a recipe for its materials; right-click one you've made to sell it."
    or "Prices over a day old are grey. Hover a recipe for its materials.")
  f.note:ClearAllPoints()
  f.note:SetPoint("TOPLEFT", PAD, y - 8)
  f.note:SetPoint("RIGHT", f.pos, "LEFT", -12, 0)
  f.pos:ClearAllPoints()
  f.pos:SetPoint("TOPRIGHT", -PAD, y - 8)
  f.pos:SetWidth(90)
  if #rows > n then
    f.pos:SetText(("%d-%d of %d"):format(W.offset + 1, W.offset + shown, #rows))
  else
    f.pos:SetText(#rows > 0 and ("%d %s"):format(#rows, #rows == 1 and "recipe" or "recipes") or "")
  end
  local listH = -(y - 8 - 16 - 10)
  f.list:SetHeight(listH)

  local by = W.listTop() - listH - 14
  f.make:ClearAllPoints()
  f.make:SetPoint("TOPRIGHT", -16, by)
  f.check:ClearAllPoints()
  f.check:SetPoint("RIGHT", f.make, "LEFT", -8, 0)
  f.sum:ClearAllPoints()
  f.sum:SetPoint("TOPLEFT", 20, by + 1)
  f.sum:SetPoint("RIGHT", f.check, "LEFT", -12, 0)
  f.sum:SetHeight(28)
  if f.sum.SetJustifyV then f.sum:SetJustifyV("MIDDLE") end
  local st = W.status
  local undo = W.undo ~= nil and st ~= nil and st.undo == true
  f.undo:ClearAllPoints()
  f.undo:SetPoint("TOPRIGHT", -16, by - 34)
  f.undo:SetShown(undo)
  f.status:ClearAllPoints()
  f.status:SetPoint("TOPLEFT", 20, by - 38)
  if undo then f.status:SetPoint("RIGHT", f.undo, "LEFT", -12, 0) else f.status:SetPoint("RIGHT", -20, 0) end
  f.status:SetText(st and st[1] or "")
  if not (st and W.fading == st) then f.status:SetAlpha(1) end
  if st then f.status:SetTextColor(rgba(st[2] or T.muted)) end
  local stH = st and math.max(30, (f.status:GetStringHeight() or 14) + 10) or 4
  W.statusH = st and stH or nil
  if not W.inAH then f:SetHeight(-(by - 34 - stH - 10)) end   -- at the auction house: its content area
  W.footer()
end

-- A short "done" note (a list was saved): shown for a few seconds after the click, then it fades away.
local FLASH_SECS, FADE_SECS = 6, 1
function W.flash(msg, color)
  local st = { msg, color or T.ok, flash = true }
  W.status = st
  if not (C_Timer and C_Timer.After) then return end
  C_Timer.After(FLASH_SECS, function()
    if W.status ~= st then return end
    local f, steps = W.frame, 10
    W.fading = st
    for i = 1, steps do
      C_Timer.After(FADE_SECS * i / steps, function()
        if W.status ~= st then return end
        if i < steps then
          if f and f.status then f.status:SetAlpha(1 - i / steps) end
        else
          W.status = nil
          if f and f.status then f.status:SetAlpha(1) end
          W.render(true)
        end
      end)
    end
  end)
end

-- Make shopping list: what the planned crafts need, as one list in the Shopping tab.
-- With the crafting queue: what the whole queue still misses (EverlookDB Crafting works it out, after what you have on
-- every character, materials you can make broken down), vendor goods left out; saved as the list "Crafting queue".
function W.makeQueueList(q)
  local d = db()
  if not d then return end
  local items, leftOut = {}, {}
  for _, m in ipairs(try(q.queueMissing) or {}) do
    local id, n = m[1], tonumber(m[2]) or 0
    if id and n > 0 then
      if m.vendor then leftOut[#leftOut + 1] = itemName(id) or ("item " .. id)
      else items[#items + 1] = { id, n } end
    end
  end
  if #items == 0 then
    W.status = { #leftOut > 0 and ("Nothing to buy at the auction house; vendors sell the rest: " .. table.concat(leftOut, ", ") .. ".")
      or "You have everything your crafting queue needs.", T.ok }
    W.render(true)
    return
  end
  d.lists = d.lists or {}
  local l, new, i = R.saveCounts(d.lists, "Crafting queue", items, itemName)
  if not l then
    W.status = { new == "loading" and "Item names are still loading. Try again in a moment." or "Couldn't make the list.", T.danger }
  else
    d.listSel = i
    local msg = ("%s \"%s\" in the auction house's Shopping tab: %d %s for the whole queue."):format(new and "Saved as" or "Updated",
      l.name, #l.queries, #l.queries == 1 and "item" or "items")
    if #leftOut > 0 then msg = msg .. " Left out, vendors sell them: " .. table.concat(leftOut, ", ") .. "." end
    W.flash(msg, T.ok)
    if ns.shoppingRefresh then pcall(ns.shoppingRefresh) end
  end
  W.render(true)
  return l
end

function W.makeList()
  local q = queueAPI()
  if q then return W.makeQueueList(q) end
  local d = db()
  if not d or not W.picks or #W.picks == 0 then return end
  local ctx = compute()
  local need = Pr.shopping(ctx, W.picks, haveOf)
  local items, leftOut = {}, {}
  for _, m in ipairs(need) do
    if m.buy > 0 then
      local vendorOnly = not priceOf(m.id) and ns.ITEMDATA and ns.ITEMDATA[m.id] and (ns.ITEMDATA[m.id][1] or 0) % 2 == 1
      if vendorOnly then leftOut[#leftOut + 1] = itemName(m.id) or ("item " .. m.id)
      else items[#items + 1] = { m.id, m.buy } end
    end
  end
  -- a recipe you don't know yet, cheapest on the auction house: the recipe itself goes on the list too
  for _, p in ipairs(W.picks) do
    local st = p.row.start
    if st and st.how == "ah" and st.item then items[#items + 1] = { st.item, 1 } end
  end
  if #items == 0 then
    W.status = { #leftOut > 0 and ("Nothing to buy at the auction house; vendors sell the rest: " .. table.concat(leftOut, ", ") .. ".")
      or "You have everything these crafts need.", T.ok }
    W.render(true)
    return
  end
  local name = #W.picks == 1 and (W.picks[1].row.name or "Crafting profit") or "Crafting profit"
  d.lists = d.lists or {}
  local l, new, i = R.saveCounts(d.lists, name, items, itemName)
  if not l then
    W.status = { new == "loading" and "Item names are still loading. Try again in a moment." or "Couldn't make the list.", T.danger }
  else
    d.listSel = i
    local msg = ("%s \"%s\" in the auction house's Shopping tab: %d %s."):format(new and "Saved as" or "Updated", l.name,
      #l.queries, #l.queries == 1 and "item" or "items")
    if #leftOut > 0 then msg = msg .. " Left out, vendors sell them: " .. table.concat(leftOut, ", ") .. "." end
    W.flash(msg, T.ok)
    if ns.shoppingRefresh then pcall(ns.shoppingRefresh) end
  end
  W.render(true)
  return l
end

-- A page of the main window (Hub.lua); a window of its own only when that window couldn't be made.
function W.open()
  W.status = nil
  if ns.hub and ns.hub.open("crafts") then return end
  local f = makeFrame()
  if not f then return end
  f:Show()
  W.render()
end
function W.toggle()
  if W.ahOpen() then W.openTab(); return end   -- /eah profit at the auction house: its Crafting tab
  if ns.hub and ns.hub.ready then
    if ns.hub.isOpen("crafts") then ns.hub.close() else W.open() end
    return
  end
  local f = makeFrame()
  if f and f:IsShown() then f:Hide() else W.open() end
end

-- Into the main window's page, as wide as the page; out of sight when another page takes its place.
function W.dock(holder)
  local f = makeFrame()
  if not f or not ns.hub then return end
  if W.inAH then W.closeTab() end   -- the auction house's Crafting tab had it: it moves here
  ns.hub.dock(f, holder)
  W.docked = holder
  W.chrome(f)
  f:SetWidth(math.max(WIDTH, math.floor((holder:GetWidth() or WIDTH) + 0.5)))
  f:Show()
  W.render()
end
function W.undock() if W.frame and not W.inAH then W.frame:Hide() end end   -- never the auction house's tab
function W.refresh() if W.frame and W.frame:IsShown() then W.render() end end

---------------------------------------------------------------------------------------------------------------------
-- The auction house's Crafting tab: the same view in the window's content area (above the price bar and the tabs),
-- like the Upgrades tab (UpgradesTab.lua). It opens only when clicked or with /eah profit there, never by itself
-- when the auction house opens, and isn't remembered as the last tab. The main window's page takes the view back.
-- At the auction house the one gold button is Buy materials (the shopping list, then Buy this list on it), and a
-- right-click on a recipe sells what it makes in Quick sell.

local AH_TOP = 14   -- how much higher the filters and the list sit there: the auction house's title row is the title
local PLACE = ns.T and ns.T.places and ns.T.places.crafts
local tab

function W.ahOpen() return _G.AuctionHouseFrame ~= nil and AuctionHouseFrame:IsShown() and true or false end
function W.listTop() return LIST_TOP + (W.inAH and AH_TOP or 0) end

-- How many recipe rows fit: all of them in a window or the main window, fewer in the auction house's content area.
function W.rowsShown()
  if not W.inAH then return ROWS end
  local f = W.frame
  local h = f and f:GetHeight() or 0
  if h < 100 then
    local ah = _G.AuctionHouseFrame
    h = ((ah and ah:GetHeight()) or 0) - 24 - (ns.BAR_H or 0) - 2
  end
  -- above the list, the list's heading and foot, the gold button's row and the status line under it
  return math.max(4, math.min(ROWS, math.floor((h + W.listTop() - 74 - 14 - 34 - math.max(30, W.statusH or 30) - 10) / ROW)))
end

-- The title row and the filters: the window's own title at its top, or (at the auction house) no title of its own
-- and everything higher.
function W.chrome(f)
  f = f or W.frame
  if not f then return end
  local up = W.inAH and AH_TOP or 0
  f.icon:SetShown(not W.inAH)
  f.title:SetShown(not W.inAH)
  if rawget(f, "ahBg") then f.ahBg:SetShown(W.inAH and true or false) end
  if rawget(f, "ahEdge") then for _, t in ipairs(f.ahEdge) do t:SetShown(W.inAH and true or false) end end
  -- the scope buttons: beside the title, or (at the auction house) in its place
  local first = f.scopes and f.scopes[1]
  if first then
    first:ClearAllPoints()
    if W.inAH then first:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -6) else first:SetPoint("LEFT", f.title, "RIGHT", 20, 0) end
  end
  f.sub:ClearAllPoints()
  f.sub:SetPoint("TOPLEFT", 20, -48 + up)
  f.sub:SetPoint("RIGHT", -20, 0)
  f.search:ClearAllPoints()
  f.search:SetPoint("TOPLEFT", 20, -70 + up)
  f.clear:ClearAllPoints()
  f.clear:SetPoint("TOPRIGHT", -20, -70 + up)
  f.pl:ClearAllPoints()
  f.pl:SetPoint("TOPLEFT", 20, -106 + up)
  f.clearFilters:ClearAllPoints()
  f.clearFilters:SetPoint("TOPRIGHT", -20, -100 + up)
  f.list:ClearAllPoints()
  f.list:SetPoint("TOPLEFT", 16, W.listTop())
  f.list:SetPoint("RIGHT", -16, 0)
  f.gear:ClearAllPoints()
  if W.inAH then f.gear:SetPoint("TOPRIGHT", -14, -6) else f.gear:SetPoint("TOPRIGHT", W.docked and -14 or -38, -10) end
end

local function closeTab()
  local f = W.frame
  if not W.inAH then return end
  W.inAH = nil
  if f and f:GetParent() == _G.AuctionHouseFrame then f:Hide() end
  if tab then pcall(PanelTemplates_DeselectTab, tab) end
  if ns.blizzardTabs then ns.blizzardTabs(true) end
  if ns.ahTitle then ns.ahTitle(nil) end
end
W.closeTab = closeTab

local function makeTab()
  if not tab and ns.makeTab then tab = ns.makeTab("EverlookAuctionsCraftingTab", "Crafting", W.openTab, closeTab, "crafts") end
  W.tab = tab
  return tab
end

-- Into the auction house's content area: no window edge, close button, dragging or keys of its own; opaque, so
-- Blizzard's view under it doesn't show through.
local function placeInAH(f, ah)
  if f:GetParent() ~= ah then f:SetParent(ah) end
  f:ClearAllPoints()
  f:SetPoint("TOPLEFT", ah, "TOPLEFT", 2, -24)
  f:SetPoint("BOTTOMRIGHT", ah, "BOTTOMRIGHT", -2, (ns.BAR_H or 0) + 2)   -- the price bar and the tabs stay visible
  if f.SetMovable then f:SetMovable(false) end
  if f.RegisterForDrag then f:RegisterForDrag() end
  f:SetScript("OnDragStart", nil)
  f:SetScript("OnDragStop", nil)
  f:SetScript("OnKeyDown", nil)
  if f.EnableKeyboard then f:EnableKeyboard(false) end
  if f.SetToplevel then f:SetToplevel(false) end
  f:SetFrameStrata(ah:GetFrameStrata())
  f:SetFrameLevel((ah:GetFrameLevel() or 1) + 150)
  f.edbDocked = ah
  for _, k in ipairs({ "bgFill", "bgEdge", "accentLine", "closeButton", "grip" }) do
    local part = rawget(f, k)
    if type(part) == "table" and part.Hide then part:Hide() end
  end
  if not rawget(f, "ahBg") then
    f.ahBg = f:CreateTexture(nil, "BACKGROUND", nil, -8)
    f.ahBg:SetAllPoints()
    f.ahBg:SetColorTexture(T.bg[1], T.bg[2], T.bg[3], 1)
    if PLACE and UI and UI.placeEdge then f.ahEdge = UI.placeEdge(f, PLACE) end
  end
end

function W.openTab()
  local ah = _G.AuctionHouseFrame
  if not ah then return end
  local f = makeFrame()
  if not f then return end
  makeTab()
  W.inAH, W.docked = true, nil
  placeInAH(f, ah)
  W.chrome(f)
  if ns.closeSearch then ns.closeSearch() end
  if ns.closeSelling then ns.closeSelling() end
  if ns.closeOthers then ns.closeOthers("crafts") end
  if ns.blizzardTabs then ns.blizzardTabs(false) end
  if tab then pcall(PanelTemplates_SelectTab, tab) end
  if ns.raise then ns.raise(f) end
  f:Show()
  if ns.ahTitle then ns.ahTitle("Crafting profit", PLACE) end
  -- not remembered as the last tab: the auction house never opens on Crafting by itself
  if PlaySound and SOUNDKIT and SOUNDKIT.IG_CHARACTER_INFO_TAB then pcall(PlaySound, SOUNDKIT.IG_CHARACTER_INFO_TAB) end
  W.render()
  if ns.hub and ns.hub.away then ns.hub.away() end   -- the main window's page, if it is open, says where it went
end

-- The gold button at the auction house: the shopping list of the planned crafts, then Buy this list on it.
function W.buyMaterials()
  local l = W.makeList()
  if not (l and W.inAH and ns.buyList and ns.buyList.begin) then return end
  if ns.buyList.begin(l) then
    W.status = { ("Buying \"%s\" item by item, in the panel beside the auction house."):format(l.name), T.ok }
    W.render(true)
  end
end

---------------------------------------------------------------------------------------------------------------------
-- Check prices: the queued recipes at the auction house's listings right now. One item at a time through the search
-- queue (AHQuery.lua), as Buy this list searches: a browse by name (the lowest price and how many are listed), and
-- for a material sold as a stack the listings themselves, walked up for the whole queue's amount (BuyList's plan).
-- Searching takes no click; nothing is bought.

local function okv(v)
  if ns.ok then return ns.ok(v) end
  return v
end

local function isCommodity(key)
  local AH = C_AuctionHouse
  local info = AH and AH.GetItemKeyInfo and try(AH.GetItemKeyInfo, key)
  if info then return okv(info.isCommodity) and true or false end
  return false
end

local function commodityRows(id)
  local AH = C_AuctionHouse or {}
  local rows = {}
  for i = 1, (try(AH.GetNumCommoditySearchResults, id) or 0) do
    local x = try(AH.GetCommoditySearchResultInfo, id, i)
    if x then
      local q = okv(x.quantity) or 0
      rows[#rows + 1] = { unit = okv(x.unitPrice), qty = q, others = q - (okv(x.numOwnerItems) or 0) }
    end
  end
  return rows
end

local function checkSay(msg, color)
  W.status = { msg, color or T.muted }
  if W.frame and W.frame:IsShown() then W.render(true) end
end

-- What was seen of an item: the page prices it from this for half an hour (also "checked" for the nudge).
function W.noteChecked(id, g)
  W.live[id] = { avg = g.avg or g.low, low = g.low, listed = g.listed, at = time() }
end

function W.checkPrices()
  if W.check then return end
  if not W.ahOpen() then
    checkSay("Check prices needs the auction house open: it looks at what is listed right now.", T.danger)
    return
  end
  if not (ns.ahq and ns.ahq.browse) then checkSay("This client can't search the auction house.", T.danger); return end
  local ctx = compute()
  local picks = W.queuePicks(ctx)
  if #picks == 0 then checkSay("Queue some crafts first, then check their prices.", T.muted); return end
  -- the materials (for the whole queue), then what the recipes make
  local order, want = {}, {}
  local function add(id) if want[id] == nil then want[id] = 0; order[#order + 1] = id end end
  for _, p in ipairs(picks) do
    for _, m in ipairs(p.row.mats) do
      add(m.id)
      want[m.id] = want[m.id] + m.need * p.n
    end
  end
  local before = {}
  for _, p in ipairs(picks) do
    add(p.row.id)
    before[p.row.id] = { low = p.row.low, cost = (not p.row.approx) and p.row.cost or nil, profit = p.row.profit }
  end
  local c = { picks = picks, order = order, want = want, before = before, i = 1, got = {} }
  W.check, W.undo = c, nil
  checkSay(("Checking prices at the auction house: %d items..."):format(#order), T.muted)
  W.checkStep(c)
end

function W.checkStep(c)
  if W.check ~= c then return end
  local id = c.order[c.i]
  if not id then return W.checkDone(c) end
  if W.frame and W.frame:IsShown() then W.footer() end
  local function nextOne()
    if W.check ~= c then return end
    c.i = c.i + 1
    W.checkStep(c)
  end
  local name = itemName(id)
  if not name then c.got[id] = { noname = true }; return nextOne() end
  ns.ahq.browse(name, id, { owner = "craftcheck", front = true, confirmEmpty = true }, function(answer)
    if W.check ~= c then return end
    if not answer.ok then c.got[id] = { noanswer = true }; return nextOne() end
    local entries = answer.entries or {}
    local low, listed = nil, 0
    for _, e in ipairs(entries) do
      if e.minPrice and e.minPrice > 0 and (not low or e.minPrice < low) then low = e.minPrice end
      listed = listed + (e.totalQuantity or 0)
    end
    local need = c.want[id] or 0
    if need > 0 and #entries > 0 and isCommodity(entries[1].itemKey) and ns.ahq.items and ns.buyList and ns.buyList.plan then
      local function plain()
        if W.check ~= c then return end
        c.got[id] = { low = low, listed = listed }
        W.noteChecked(id, c.got[id])
        nextOne()
      end
      ns.ahq.items(entries[1].itemKey, { owner = "craftcheck", front = true, commodity = true, onFail = plain },
        function(_, _, final)
          if not final or W.check ~= c then return end
          local rows = commodityRows(id)
          local plan = ns.buyList.plan(rows, need, true)
          if ns.noteLivePrice and #rows > 0 then pcall(ns.noteLivePrice, id, rows) end
          c.got[id] = { low = low, listed = listed, avg = plan.avg, got = plan.got, need = need }
          W.noteChecked(id, c.got[id])
          nextOne()
        end)
      return
    end
    if ns.noteLivePrice and low then pcall(ns.noteLivePrice, id, { { unit = low, qty = listed } }) end
    c.got[id] = { low = low, listed = listed }
    W.noteChecked(id, c.got[id])
    nextOne()
  end)
end

-- Every item seen: a verdict for each queued recipe; the ones not worth it come out of the queue (Undo puts them back).
function W.checkDone(c)
  W.check = nil
  local ctx = compute()
  local items, undo = {}, {}
  for _, p in ipairs(c.picks) do
    local r = ctx.recipes[p.row.id]
    local now = r and Pr.row(ctx, p.row.id, r) or p.row
    local b = c.before[p.row.id]
    local verdict = Pr.verdict(b, now)
    local short
    for _, m in ipairs(now.mats or {}) do
      local g = c.got[m.id]
      if g and g.need and g.got and g.got < g.need and not m.paid then short = itemName(m.id) or ("item " .. m.id) end
    end
    local out = c.got[p.row.id]
    -- the result's 30-day median (3 days of history at least): a price far above it may not hold
    local median
    local d = ns.historyDays and ns.historyDays(now.id)
    if type(d) == "table" then
      local list = {}
      for _, v in pairs(d) do if type(v) == "number" then list[#list + 1] = v end end
      table.sort(list)
      if #list >= 3 then median = list[math.floor((#list + 1) / 2)] end
    end
    items[#items + 1] = { name = rowName(now) or ("item " .. now.id), n = p.n,
      made = math.floor(p.n * (now.makes or 1) + 0.5), verdict = verdict, was = b and b.low, now = now.low,
      profit = now.profit and now.profit * p.n, margin = (not now.approx) and now.margin or nil,
      costNow = (not now.approx) and now.cost * p.n or nil, costWas = b and b.cost and b.cost * p.n or nil,
      listed = out and out.listed, short = short, median = median }
    if verdict then
      local key = { rid = p.spell or now.rid, id = now.id }
      undo[#undo + 1] = { rid = key.rid, id = key.id, n = p.n }
      W.setPlanned(key, 0)
    end
  end
  local lines = Pr.checkLines(items, Pr.short)
  table.insert(lines, 1, ("Checked %d %s at the auction house just now."):format(#c.order, #c.order == 1 and "item" or "items"))
  W.undo = #undo > 0 and undo or nil
  W.status = { table.concat(lines, "\n"), T.text, undo = #undo > 0 }
  W.offset = 0
  if W.frame and W.frame:IsShown() then W.render() end
  return items
end

-- Undo: what Check prices took out goes back in the queue.
function W.undoCheck()
  local u = W.undo
  if not u then return end
  W.undo = nil
  for _, e in ipairs(u) do W.setPlanned({ rid = e.rid, id = e.id }, e.n) end
  W.status = { ("Put back in the queue: %d %s."):format(#u, #u == 1 and "recipe" or "recipes"), T.muted }
  W.render()
end

-- The auction house closed, or the game blocked a search: the check stops, the queue as it was.
function W.checkStopped(why)
  local c = W.check
  if not c then return end
  W.check = nil
  if ns.ahq and ns.ahq.cancel then ns.ahq.cancel("craftcheck") end
  checkSay(why == "blocked" and "The game blocked the price check. Click Check prices to try again; the queue is as it was."
    or "The auction house closed before the check finished. The queue is as it was.", T.muted)
end

-- Right-click on a recipe: what it makes, picked in Quick sell (only at the auction house, when it is in your bags).
function W.sell(r)
  if not r then return end
  if r.start then W.buyRecipe(r); return end
  local name = rowName(r) or ("item " .. r.id)
  if not W.ahOpen() then
    W.status = { "Open the auction house to sell " .. name .. ".", T.muted }
  elseif bagCount(r.id) <= 0 then
    W.status = { "No " .. name .. " in your bags yet: craft it, then right-click it here to sell it.", T.muted }
  elseif ns.sellItemID and ns.sellItemID(r.id) then
    return
  else
    W.status = { "The auction house won't take " .. name .. " (is it soulbound?).", T.danger }
  end
  W.render(true)
end

-- Right-click on a recipe you don't know: its recipe item in Advanced search on the Buy tab, with its live auctions.
function W.buyRecipe(r)
  local st = r and r.start
  if not st then return end
  if not st.item then
    W.status = { (rowName(r) or "This recipe") .. (st.how == "trainer" and " is taught by a trainer." or " has no recipe item to buy."), T.muted }
  elseif not W.ahOpen() then
    W.status = { "Open the auction house to buy the recipe.", T.muted }
  else
    local n = itemName(st.item)
    if not n then
      W.status = { "The recipe's name is still loading. Try again in a moment.", T.muted }
    else
      if ns.openSearch then ns.openSearch() end
      if ns.query and R then ns.query(R.query(n)) end
      return
    end
  end
  W.render(true)
end

-- The other tabs close this one (Shopping.lua's closeOthers is the shared hook).
local prevClose = ns.closeOthers
function ns.closeOthers(except)
  if prevClose then prevClose(except) end
  if except ~= "crafts" then closeTab() end
end

if CreateFrame then
  local ahEv = CreateFrame("Frame")
  ahEv:RegisterEvent("AUCTION_HOUSE_SHOW")
  ahEv:RegisterEvent("AUCTION_HOUSE_CLOSED")
  pcall(ahEv.RegisterEvent, ahEv, "ADDON_ACTION_BLOCKED")
  ahEv:SetScript("OnEvent", function(_, e, a1)
    if e == "ADDON_ACTION_BLOCKED" then
      -- this client may name the call "UNKNOWN()": any block of ours during a check stops it
      if a1 == ADDON and W.check then W.checkStopped("blocked") end
      return
    end
    if e == "AUCTION_HOUSE_CLOSED" then
      W.checkStopped("closed")
      closeTab()
      return
    end
    -- after the Upgrades tab (0.4 s after the auction house opens); never opened here
    C_Timer.After(0.45, function()
      if W.ahOpen() then makeTab() end
    end)
  end)
end

---------------------------------------------------------------------------------------------------------------------
-- The command and the settings page, added to the /eah app once Options.lua has made it.

local FILTER_WORDS = { "profit", "crafting", "filter", "search", "recipes", "sort", "column", "skill", "margin", "percent",
  "cost", "maximum", "gold", "silver", "copper", "money", "coins", "can make", "bags", "materials", "alts", "alt",
  "characters", "professions", "clear filters" }
local function words(extra)
  local out = {}
  for _, w in ipairs(extra) do out[#out + 1] = w end
  for _, w in ipairs(FILTER_WORDS) do out[#out + 1] = w end
  return out
end

local function addToApp(app)
  if not app or W.added then return end
  W.added = true
  app:Setting({
    key = "profitcraft", type = "bool", label = "Count making a material yourself when that is cheaper than buying it (bars, bolts)",
    chatLabel = "Profit: craft materials", keywords = { "profit", "crafting", "materials", "intermediate", "bars", "bolts", "buy" },
    get = function() return not settings().noCraft end,
    set = function(v) settings().noCraft = not v or nil end,
    after = W.refresh,
  })
  app:Setting({
    key = "profitpaid", type = "bool", label = ("Use what you paid for materials bought in the last %d days"):format(Pr.PAID_DAYS),
    chatLabel = "Profit: what you paid", keywords = { "profit", "crafting", "paid", "bought", "cost", "materials", "purchases" },
    get = function() return not settings().noPaid end,
    set = function(v) settings().noPaid = not v or nil end,
    after = W.refresh,
  })
  -- silver, as it always was (the page's box takes gold and copper too; both write the same copper amount)
  app:Setting({
    key = "profitmin", type = "number", label = "Show recipes making at least this much profit (silver)", min = 0, max = 1000, step = 5,
    chatLabel = "Profit: minimum", keywords = words({ "minimum", "least", "at least" }),
    get = function() return math.floor((settings().min or 0) / 100) end,
    set = function(v)
      v = math.max(0, math.floor(tonumber(v) or 0))
      settings().min = v > 0 and v * 100 or nil
      if W.frame then W.frame.min:SetText(v > 0 and Pr.moneyText(v * 100) or "") end
    end,
    after = W.refresh,
  })
  app:Command("profit", "profit", "the recipes you know that sell for more than their materials cost (works anywhere)",
    function() W.toggle() end, { "profits", "craftprofit", "flip" })
  app:Section("profit", "Crafting", function(stack)
    local EU = EUI
    EU.Header(stack, "Crafting", "The crafting cost box beside your profession window, and Crafting profit: the recipes you know whose result sells for more than its materials cost, after the cut (/eah profit).")
    if app:GetSetting("crafting") then app:Widget(stack, "crafting") end
    EU.Header(stack, "Crafting profit")
    EU.ButtonRow(stack, {
      { label = "Open Crafting profit", width = 170, onClick = function() W.open() end,
        desc = "The list of your profitable recipes, with a shopping list for the crafts you plan. Sort by any column; filter by name, skill, profit, margin, cost, what you can make now and your alts' recipes.",
        keywords = words({ "finder", "open", "flip" }) },
      { label = "Clear filters", width = 120, onClick = function() W.clearFilters() end,
        desc = "Puts Crafting profit's filters and sort back: every recipe, best profit first.",
        keywords = words({ "reset" }) },
    })
    app:Widget(stack, "profitcraft")
    app:Widget(stack, "profitpaid")
    app:Widget(stack, "profitmin")
    EU.Note(stack, "Prices are your last scan of the auction house; nothing is guessed. A material without an AH price shows ≈ (the real profit is lower), and a recipe whose result has no price is left out. Open each profession window once so the addon knows your recipes; with EverlookDB Crafting, your alts' recipes can be added too (Alts, on the page).")
  end, { icon = "wrench" })
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("BAG_UPDATE_DELAYED")
ev:RegisterEvent("PLAYER_LOGIN")
ev:SetScript("OnEvent", function(_, event, name)
  if event == "PLAYER_LOGIN" then
    -- the crafting queue changes (a craft, an add from the profession window): the boxes and the line follow
    local q = queueAPI()
    if q and q.onQueue and not W.listening then
      W.listening = true
      try(q.onQueue, function() if W.frame and W.frame:IsShown() then W.render(true) end end)
    end
    return
  end
  if event == "BAG_UPDATE_DELAYED" then
    -- "Only what I can make now" follows your bags
    if settings().canMake then W.refresh() end
    return
  end
  if name ~= ADDON then return end
  ev:UnregisterEvent("ADDON_LOADED")
  -- Options.lua makes the app on this same event, and loads first
  if ns.app then addToApp(ns.app) else C_Timer.After(0, function() addToApp(ns.app) end) end
end)

-- /eah profit also works when the settings window couldn't be built
local prevSlash = ns.slash
function ns.slash(msg)
  if msg == "profit" or msg == "profits" then W.toggle(); return true end
  return prevSlash and prevSlash(msg) or false
end
