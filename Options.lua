-- EverlookDB Auctions: the settings window (/eah), on the shared EverlookUI look (the same as Lattice and the other
-- EverlookDB addons), with its entry in the game's Settings under AddOns.
--   Selling   undercut, default duration
--   Tooltips  auction price, 30-day low and median, disenchant value, vendor price, full-stack price with Shift
--   General   automatic price updates, the EverlookDB look for Blizzard's auction house, crafting cost
-- Every setting is also a command: /eah <setting> <value> sets it, says so in chat and updates the open window;
-- /eah get lists them. The core (EverlookDBAuctions.lua) routes /eah to this app, which follows the chat-command
-- pattern every EverlookDB addon shares (EverlookUI): help, get/set, search, status, version, suggestions.
local ADDON, ns = ...
local UI = LibStub and LibStub("EverlookUI-1", true)

local O = {}

local FEEDBACK_URL = "https://everlookdb.com/auctions-addon.html#feedback"

local TIP_LINES = {
  { "tipprice", "auction", "Auction price, how many are up and how old the price is" },
  { "tiphistory", "history", "30-day low and median" },
  { "tipdisenchant", "disenchant", "What disenchanting it is worth (an estimate from material prices)" },
  { "tipcraft", "craft", "What crafting one costs, for items you can craft (materials at the latest AH prices)" },
  { "tipvendor", "vendor", "Vendor price, where the game doesn’t show one (quest rewards, loot, links)" },
  { "tipstack", "stack", "Hold Shift for the price of a full stack" },
}

local HOURS = { 12, 24, 48 }   -- the auction house's durations 1, 2, 3

local function db() return ns.db() or {} end

local function build()
  local T = ns.T
  local app = UI:NewApp({
    name = "EverlookDB Auctions",
    addon = ADDON,
    slash = "/eah",
    tagline = "Prices, Quick sell and shopping lists for the auction house. Sellers and bidders are never saved.",
    accent = { T.accent[1], T.accent[2], T.accent[3] },   -- EverlookDB gold
    position = function() return ns.db() end,
    feedbackURL = FEEDBACK_URL,
  })
  O.app = app

  -- selling
  app:Setting({
    key = "undercut", type = "string", label = "Undercut by", keywords = { "price", "cheaper", "under", "posting" }, width = 120, placeholder = "1s or 5%",
    desc = "How far under the cheapest auction Quick sell and Blizzard's Sell tab price: 1s, 50c, 1g, 5%, or 0 to match it.",
    example = "1s",
    get = function() return ns.undercutShort() end,
    set = function(v)
      local okSet, why = ns.setUndercut(v)
      if not okSet then app:Print(why) end
    end,
    after = function() if ns.undercutChanged then ns.undercutChanged() end end,
  })
  app:Setting({
    key = "duration", type = "choice", label = "Default duration", keywords = { "time", "hours", "length", "posting" }, width = 160,
    desc = "For items you haven't posted before; the others keep the duration you used last.",
    choices = { { value = 12, text = "12 hours" }, { value = 24, text = "24 hours" }, { value = 48, text = "48 hours" } },
    get = function() return HOURS[(ns.sellSettings() or {}).duration or 1] or 12 end,
    set = function(v)
      v = tonumber(v)
      for d, h in ipairs(HOURS) do if h == v then ns.sellSettings().duration = d end end
    end,
  })

  -- tooltips
  for _, t in ipairs(TIP_LINES) do
    app:Setting({
      key = t[1], type = "bool", label = t[3], chatLabel = "Tooltip line: " .. t[3]:lower(), keywords = { "tooltip", t[2] },
      get = function() return ns.tipOn(t[2]) end,
      set = function(v)
        local d = db()
        d.tip = d.tip or {}
        d.tip[t[2]] = v
      end,
    })
  end

  app:Setting({
    key = "tipdetail", type = "choice", label = "Tooltip details (30-day low and median)", width = 200,
    chatLabel = "Tooltip details", keywords = { "tooltip", "shift", "detail", "history", "median" },
    desc = "Show the finer print under a price always, or only while you hold Shift. The other EverlookDB addons' tooltip details follow it too.",
    choices = { { value = "always", text = "Always" }, { value = "shift", text = "While Shift is held" } },
    get = function() return ns.tipDetail() end,
    set = function(v) ns.tipDetail(v) end,
  })

  -- general
  app:Setting({
    key = "auto", type = "bool", label = "Update prices by themselves while the auction house is open (every 30 minutes)",
    chatLabel = "Automatic price updates", keywords = { "scan", "automatic", "refresh", "auto" },
    get = function() return db().auto ~= false end,
    set = function(v) db().auto = v end,
  })
  app:Setting({
    key = "openon", type = "choice", label = "Open the auction house on", width = 180,
    keywords = { "tab", "start", "first", "default", "remember", "browse", "quick sell", "opens" },
    desc = "Which tab you see when you open the auction house: Blizzard's Browse, Quick sell, or the tab you used last.",
    choices = { { value = "browse", text = "Browse" }, { value = "sell", text = "Quick sell" }, { value = "last", text = "Last tab used" } },
    get = function() return db().openOn or "last" end,
    set = function(v)
      if v == "browse" or v == "sell" or v == "last" then db().openOn = v end
    end,
  })
  app:Setting({
    key = "skin", type = "bool", label = "EverlookDB look for Blizzard's auction house (after /reload)", keywords = { "skin", "theme", "style" },
    get = function() return db().skin ~= false end,
    set = function(v) db().skin = v end,
  })
  -- the AH log (Purchases.lua)
  local function logRefresh() if ns.purchases and ns.purchases.refresh then ns.purchases.refresh() end end
  app:Setting({
    key = "logopacity", type = "number", label = "Window opacity", min = 30, max = 100, step = 5,
    chatLabel = "AH log opacity", keywords = { "transparency", "alpha", "see through", "background", "log" },
    desc = "How solid the AH log window is, in percent.",
    get = function() return math.floor((tonumber(db().logAlpha) or 0.97) * 100 + 0.5) end,
    set = function(v) db().logAlpha = math.max(30, math.min(100, tonumber(v) or 97)) / 100 end,
    after = logRefresh,
  })
  app:Setting({
    key = "logrows", type = "number", label = "Rows shown", min = 3, max = 40, step = 1,
    chatLabel = "AH log rows", keywords = { "lines", "height", "size", "log" },
    desc = "How many rows the list shows before you scroll. Or drag the window's bottom right corner: taller for more rows, narrower for only the essentials.",
    get = function() return tonumber(db().logRows) or 12 end,
    set = function(v) db().logRows = math.max(3, math.min(40, math.floor(tonumber(v) or 12))) end,
    after = logRefresh,
  })
  app:Setting({
    key = "logbuys", type = "bool", label = "Log what you buy at the auction house",
    chatLabel = "Logging purchases", keywords = { "bought", "purchases", "log", "record" },
    get = function() return db().logBuys ~= false end,
    set = function(v) db().logBuys = v end,
  })
  app:Setting({
    key = "logincome", type = "bool", label = "Log money you take from the mail (auctions sold and other gold)",
    chatLabel = "Logging income", keywords = { "sold", "sales", "income", "mail", "gold", "log", "record" },
    get = function() return db().logIncome ~= false end,
    set = function(v) db().logIncome = v end,
  })
  app:Setting({
    key = "cheer", type = "bool", label = "Celebrate when an auction sells (Hurray! and fireworks at the top of the screen)",
    chatLabel = "Sale celebration", keywords = { "sold", "sale", "hurray", "fireworks", "banner", "celebrate" },
    get = function() return db().cheer ~= false end,
    set = function(v) db().cheer = v end,
  })
  app:Setting({
    key = "logloot", type = "bool", label = "Log everything you loot (the Looted tab, /eah loot)",
    chatLabel = "Logging loot", keywords = { "loot", "looted", "log", "history", "pickup", "drops" },
    get = function() return db().logLoot ~= false end,
    set = function(v) db().logLoot = v end,
  })
  app:Setting({
    key = "lootcards", type = "bool", label = "A card at the top of the screen for everything you loot (5 seconds, with what it's worth)",
    chatLabel = "Loot cards", keywords = { "loot", "looted", "pickup", "toast", "card", "notification" },
    get = function() return db().lootCards ~= false end,
    set = function(v) db().lootCards = v end,
  })
  app:Setting({
    key = "lootmoney", type = "bool", label = "Loot cards for money too",
    chatLabel = "Loot cards for money", keywords = { "loot", "money", "gold", "coins" },
    get = function() return db().lootMoney ~= false end,
    set = function(v) db().lootMoney = v end,
  })
  app:Setting({
    key = "lootmin", type = "choice", label = "Loot cards from this quality up", chatLabel = "Loot card quality",
    keywords = { "loot", "quality", "grey", "gray", "junk", "rarity" },
    choices = { { value = 0, text = "Poor (everything)" }, { value = 1, text = "Common" }, { value = 2, text = "Uncommon" },
      { value = 3, text = "Rare" }, { value = 4, text = "Epic" } }, width = 180,
    get = function() return db().lootMin or 0 end,
    set = function(v) db().lootMin = tonumber(v) or 0 end,
  })
  app:Setting({
    key = "crafting", type = "bool", label = "Crafting cost beside the profession window", keywords = { "reagents", "materials", "profit", "tradeskill" },
    get = function() return db().craft ~= false end,
    set = function(v) db().craft = v end,
    after = function() if ns.craftRefresh then ns.craftRefresh() end end,
  })

  -- the addon's own commands; the shared ones (help, get, set, search, status, version, feedback) come with the app
  app:StatusLines(function() return ns.statusLines and ns.statusLines() or {} end)
  app:Command("scan", "scan", "update prices now (auction house open)", function() if ns.startScan then ns.startScan() end end)
  app:Command("sell", "sell", "open Quick sell (auction house open)", function() ns.slash("sell") end, { "selling", "quicksell", "quick" })
  app:Command("shop", "shop", "open Shopping (auction house open)", function() ns.slash("shop") end, { "shopping", "lists" })
  app:Command("bought", "bought", "your auction house purchases, and a recipe's cost from what you paid (works anywhere)", function()
    if ns.purchases then ns.purchases.toggle() end
  end, { "purchases", "buys", "log" })
  app:Command("loot", "loot", "everything you looted, with when and where (works anywhere; also on Everlook Bar)", function()
    if ns.purchases then ns.purchases.toggle("looted") end
  end, { "looted", "loots", "drops" })
  app:Command("forsale", "forsale", "your auctions up for sale, as the auction house last showed them (works anywhere)", function()
    if ns.purchases then ns.purchases.toggle("forsale") end
  end, { "listed", "posted", "up" })
  app:Command("income", "income", "what you sold and other gold from the mail, with what crafting a sold item again costs", function()
    if ns.purchases then ns.purchases.toggle("income") end
  end, { "sales", "sold", "earned" })
  app:Command("run", "run <list>", "run a shopping list (auction house open)", function(rest)
    ns.slash(rest == "" and "run" or ("run " .. rest))
  end)
  -- "/eah undercut 1s" keeps its own reply (it names the step); "/eah set undercut 1s" works as for any setting
  app:Command("undercut", "undercut", "", function(rest) ns.slash("undercut " .. rest) end).hidden = true
  -- for bug reports and testing: they work, but help doesn't list them
  app:Command("test", "test", "reload after every full scan, so it is saved at once", function()
    if ns.toggleTestMode then ns.toggleTestMode() end
  end).hidden = true
  app:Command("lootmove", "lootmove", "move the loot cards: drag the green box, right-click it when done (lootmove reset puts them back)", function(rest)
    if not ns.lootCards then return end
    if (rest or ""):lower():match("reset") then ns.lootCards.resetPos() else ns.lootCards.move() end
  end, { "lootpos", "movecards" })
  app:Command("loottest", "loottest", "show a few loot cards once", function()
    if not ns.lootCards then return end
    local d = db()
    local was = d.lootCards
    d.lootCards = nil
    ns.lootCards.show({ id = 4306, name = "Silk Cloth", count = 4, quality = 1, icon = 132905 })
    ns.lootCards.show({ id = 7909, name = "Aquamarine", count = 1, quality = 2, icon = 134132 })
    ns.lootCards.show({ copper = 1234 })
    d.lootCards = was
  end)
  app:Command("cheertest", "cheertest", "show the sale celebration once", function()
    if ns.cheer then
      local d = ns.db()
      local was = d.cheer
      d.cheer = nil
      ns.cheer.show("Black Silk Pack", 1020 * 100, 1)
      d.cheer = was
    end
  end).hidden = true
  app:Command("debug", "debug", "the technical details: auction API, update log, scans kept, what is shown where", function()
    if ns.debugReport then ns.debugReport() end
  end).hidden = true

  app:Section("selling", "Selling", function(stack)
    UI.Header(stack, "Selling", "Quick sell's price is the cheapest live auction minus your undercut. Blizzard's own Sell tab gets the same undercut when you pick an auction in its list.")
    app:Widget(stack, "undercut")
    app:Widget(stack, "duration")
  end)
  app:Section("tooltips", "Tooltips", function(stack)
    UI.Header(stack, "Tooltips", "Lines added to item tooltips. Every price says how old it is; prices over a day old are grey.")
    for _, t in ipairs(TIP_LINES) do app:Widget(stack, t[1]) end
    app:Widget(stack, "tipdetail")
  end)
  app:Section("ahlog", "AH log", function(stack)
    UI.Header(stack, "AH log", "What you bought and what you sold, with what a craft cost you. Open it anywhere with /eah bought, /eah forsale, /eah income or /eah loot, or from its Loot plugin on Everlook Bar.")
    UI.ButtonRow(stack, {
      { label = "Purchases", width = 124, style = "accent", onClick = function() if ns.purchases then ns.purchases.open() end end,
        desc = "Everything you bought, and a recipe's cost per craft from what you paid.", keywords = { "bought", "log", "open" } },
      { label = "For sale", width = 124, onClick = function() if ns.purchases then ns.purchases.toggle("forsale") end end,
        desc = "Your auctions up for sale, as the auction house last showed them.", keywords = { "for sale", "listed", "posted", "auctions", "open" } },
      { label = "Income", width = 124, onClick = function() if ns.purchases then ns.purchases.toggle("income") end end,
        desc = "Money you took from the mail: auctions sold and other gold.", keywords = { "income", "sold", "open" } },
      { label = "Loot log", width = 124, onClick = function() if ns.purchases then ns.purchases.toggle("looted") end end,
        desc = "Everything you looted, with when and where.", keywords = { "loot", "looted", "drops", "open" } },
    })
    UI.Header(stack, "Window")
    app:Widget(stack, "logopacity")
    app:Widget(stack, "logrows")
    UI.Header(stack, "Logging")
    app:Widget(stack, "logbuys")
    app:Widget(stack, "logincome")
    app:Widget(stack, "logloot")
    app:Widget(stack, "cheer")
    UI.Header(stack, "Loot cards")
    app:Widget(stack, "lootcards")
    app:Widget(stack, "lootmoney")
    app:Widget(stack, "lootmin")
    UI.ButtonRow(stack, {
      { label = "Move cards", width = 124, onClick = function() if ns.lootCards then ns.lootCards.move() end end,
        desc = "Drag the green box where the loot cards should appear; right-click it when done.", keywords = { "move", "position", "loot", "cards" } },
      { label = "Reset spot", width = 124, onClick = function() if ns.lootCards then ns.lootCards.resetPos() end end,
        desc = "Back to the right side, under your buffs.", keywords = { "reset", "position", "loot" } },
    })
    UI.Note(stack, "Sales show up when you take their money from the mail. Bids aren't logged. Nothing about other players is saved: no sellers, buyers or senders.")
  end, { icon = "coins" })
  app:Section("general", "General", function(stack)
    UI.Header(stack, "General")
    app:Widget(stack, "openon")
    app:Widget(stack, "auto")
    app:Widget(stack, "skin")
    app:Widget(stack, "crafting")
    UI.Header(stack, "Chat commands")
    UI.Note(stack, "/eah  this window\n/eah help  every command in chat\n/eah status  which auction houses have prices, and how old\n/eah scan  update prices now (auction house open)\n/eah sell, /eah shop  open Quick sell or Shopping\n/eah bought  what you bought, and a recipe's cost from what you paid\n/eah forsale  your auctions up for sale, with time left\n/eah income  what you sold (from the mail), with what crafting it again costs\n/eah run <list>  run a shopping list\n/eah undercut 1s  change a setting (/eah get lists them)\n/eah search <words>  find a setting")
  end)
end

-- Opens the window, or says why it can't.
local function open()
  if not O.app then
    ns.say("the options couldn't be built" .. (ns.optionsError and (": " .. ns.plain(ns.optionsError)) or "")
      .. ". Settings still work as commands: /eah help lists them, for example /eah auto off.")
    return
  end
  O.app:Open()
end

local function feedback()
  if O.app then O.app:ShowFeedback() else ns.say("report bugs and ideas at " .. FEEDBACK_URL) end
end
ns.feedback = feedback

-- A setting changed by a command (/eah auto off, /eah undercut 5%) shows at once if the window is open.
function ns.optionsRefresh()
  if O.app and O.app:IsShown() then O.app:Refresh() end
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:SetScript("OnEvent", function(_, _, name)
  if name ~= ADDON then return end
  ev:UnregisterEvent("ADDON_LOADED")
  -- the core sets up the saved data on this same event, first (it loads first)
  if not UI then ns.optionsError = "the EverlookUI library is missing"; return end
  local okBuild, err = pcall(build)
  if not okBuild then ns.optionsError = err; O.app = nil end
  ns.app = O.app -- /eah goes through it (EverlookDBAuctions.lua)
end)

local prevSlash, prevHelp = ns.slash, ns.help
function ns.slash(msg)
  if msg == "options" or msg == "config" then
    open()
    return true
  end
  if msg == "settings" then
    if O.app then O.app:PrintSettings() else open() end
    return true
  end
  if msg == "feedback" or msg == "bug" then
    feedback()
    return true
  end
  if prevSlash and prevSlash(msg) then return true end
  -- "/eah <setting> <value>": sets it, says so in chat and updates the open window
  return O.app ~= nil and O.app:TrySetting(msg) or false
end
function ns.help()
  if prevHelp then prevHelp() end
  print("  /eah settings  every setting with its value;  /eah <setting> <value>  change one, for example /eah duration 24")
  print("  /eah feedback  a link for reporting bugs and ideas")
end
