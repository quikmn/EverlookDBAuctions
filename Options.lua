-- EverlookDB Auctions: the main window (/eah), on the shared EverlookUI look (the same as Lattice and the other
-- EverlookDB addons), with its entry in the game's Settings under AddOns. Hub.lua adds the addon's own pages on top
-- (Home, Advanced search, AH log, Crafting profit, Gear upgrades, Merchant's Favor); the settings pages are listed
-- under a Settings heading:
--   General   automatic price updates, the Price Feed, the minimap button, the EverlookDB look for Blizzard's auction
--             house, compare with what you wear only while holding Shift
--   Selling   undercut, default duration
--   Tooltips  auction price, 30-day low and median, disenchant value, vendor price, full-stack price with Shift, the hovered stack's with Ctrl,
--             how many your characters have (Where.lua)
--   Logging   what the AH log keeps, loot cards, the sale celebration
--   Disenchanting  the breakdown, your own results, the lesser essence cap, the chat line (DisenchantLog.lua)
--   Specs and weights (UpgradesOptions.lua), Crafting (ProfitWindow.lua)
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
  { "tipdisenchant", "disenchant", "What disenchanting it is worth, from material prices" },
  { "tipcraft", "craft", "What crafting one costs, for items you can craft (materials at the latest AH prices)" },
  { "tipvendor", "vendor", "Vendor price, where the game doesn’t show one (quest rewards, loot, links)" },
  { "tipverdict", "verdict", "Sell on AH / Sell to vendor: how much more the better one pays (after the AH cut: 5%, 15% at a neutral one)" },
  { "tipstack", "stack", "Hold Shift for the price of a full stack, Ctrl for the stack under the mouse" },
  { "tiphave", "have", "How many you and your alts have, and where (hold Shift for every place)" },
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
    subtitle = "Prices, gold and gear",
    accent = { T.accent[1], T.accent[2], T.accent[3] },   -- EverlookDB gold
    position = function() return ns.db() end,
    feedbackURL = FEEDBACK_URL,
    -- the main window: the addon's pages (Hub.lua), then the settings under their own heading, search box top centre
    searchTop = true, width = 1020, height = 580,
    groups = { { id = "main" }, { id = "settings", title = "Settings" } },
    windowDesc = "the main window: Home, the AH log, Advanced search and the rest, and the settings",
    onPage = function(a, id) if ns.hub then ns.hub.onPage(a, id) end end,
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
  -- My prices: price formulas under a name, for searches and shopping lists (Formula.lua, Search.lua)
  app:Setting({
    key = "myprices", type = "string", label = "My prices", keywords = { "formula", "price", "myfloor", "max price", "shopping", "search", "low30", "median" },
    width = 340, placeholder = "myfloor = max(vendor * 1.5, 80% of low30)",
    desc = "Price formulas under a name, separated by ; (myfloor = max(vendor * 1.5, 80% of low30); cheap = 60% of median). Use the name in Advanced search (price lt myfloor, sort by myfloor) or as a shopping list's most to pay.",
    example = "myfloor = max(vendor * 1.5, 80% of low30)",
    get = function() return ns.myPricesText and (ns.myPricesText() or ""):gsub("%s*\n%s*", "; ") or "" end,
    set = function(v)
      if not ns.setMyPrices then return end
      local okSet, why = ns.setMyPrices(v)
      if not okSet then app:Print("My prices not saved: " .. why) end
    end,
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
  -- the shared EverlookTooltip switch: an opaque tooltip background (kept in db.tip)
  local Tip = LibStub and LibStub("EverlookTooltip-1", true)
  if Tip and Tip.SolidSetting then
    Tip:SolidSetting(app, function() local d = db(); d.tip = d.tip or {}; return d.tip end)
  end

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
    key = "feed", type = "bool", label = "Use the Price Feed (other players' newest scans, from the EverlookDB App)",
    chatLabel = "Price Feed", keywords = { "price feed", "feed", "shared", "other players", "app", "everlookdb app", "server", "website", "prices", "ignore", "scan" },
    desc = "Where it is newer than your own scan, prices come from it and say \"other players' scan\". Your own saved scans are never changed. Off: only your own scans.",
    get = function() return not db().ignoreShared end,
    set = function(v) db().ignoreShared = (not v) or nil end,
  })
  app:Setting({
    key = "reloadhint", type = "bool", label = "Offer to reload for newer prices",
    chatLabel = "Offer to reload for newer prices",
    keywords = { "reload", "newer", "fresh", "old", "stale", "price feed", "feed", "app", "nudge", "hint", "remind", "minimap", "dot" },
    desc = "When the Price Feed's prices you see are old and the EverlookDB App has probably brought newer ones, a small line under the minimap offers a reload, only at a quiet moment (resting in a city or inn, or just after a mailbox, vendor or flight). At most once an hour, never in a fight; x keeps it away for 2 hours. The minimap button gets a small dot then too (Shift-click reloads).",
    get = function() return db().reloadNudge ~= false end,
    set = function(v) if v then db().reloadNudge = nil else db().reloadNudge = false end end,
    after = function() if ns.feedNudge then pcall(ns.feedNudge.check) end end,
  })
  app:Setting({
    key = "reloadafter", type = "choice", label = "Offer it when prices are older than", width = 160,
    chatLabel = "Offer a reload after", keywords = { "reload", "age", "old", "minutes", "hours", "newer", "price feed", "threshold" },
    choices = { { value = 60, text = "1 hour" }, { value = 90, text = "90 minutes" }, { value = 120, text = "2 hours" },
      { value = 180, text = "3 hours" }, { value = 360, text = "6 hours" } },
    get = function() return ns.feedNudge and ns.feedNudge.minutes() or tonumber(db().reloadAfter) or 90 end,
    set = function(v) db().reloadAfter = tonumber(v) end,   -- one of the choices (the chat parser checks)
  })
  app:Setting({
    key = "skin", type = "bool", label = "EverlookDB look for Blizzard's auction house (after /reload)", keywords = { "skin", "theme", "style" },
    get = function() return db().skin ~= false end,
    set = function(v) db().skin = v end,
  })
  app:Setting({
    key = "compareshift", type = "bool", label = "Compare with what I wear: only while holding Shift",
    chatLabel = "Compare with equipped only with Shift",
    keywords = { "compare", "comparison", "equipped", "wear", "worn", "shift", "tooltip", "gear", "side by side" },
    desc = "In our lists (Buy, Quick sell, Advanced search, Gear upgrades, Crafting, Profit, AH log) the hovered item's tooltip shows on its own; hold Shift to see what you wear beside it. Off: the game decides, as in its own windows.",
    get = function() return db().compareShift ~= false end,
    set = function(v) db().compareShift = v end,
  })
  -- the AH log (Purchases.lua): a page of the main window, as big as the page (no opacity or rows of its own)
  app:Setting({
    key = "minimap", type = "bool", label = "Minimap button (click: this window, right-click: settings, drag: move it)",
    chatLabel = "Minimap button", keywords = { "minimap", "button", "icon", "launcher", "map", "hide", "show" },
    desc = "Everlook Bar and other button collectors can hold it; Everlook Bar also has an EverlookDB Auctions launcher.",
    get = function() return not (db().minimapButton and db().minimapButton.hide) end,
    set = function(v)
      db().minimapButton = db().minimapButton or {}
      db().minimapButton.hide = (not v) or nil
    end,
    after = function() if ns.minimapButton then ns.minimapButton.refresh() end end,
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
  -- "/eah feed" says how the Price Feed is; "/eah feed off" (or the old "/eah shared off") switches it
  app:Command("feed", "feed [on|off]", "the Price Feed: other players' newest scans, from the EverlookDB App", function(rest, a)
    local def = a:GetSetting("feed")
    if def and (rest or ""):match("%S") then
      a:SetFromText(def, rest)
      return
    end
    local lines = ns.shared and ns.shared.statusLines() or { "Price Feed: not available" }
    for _, l in ipairs(lines) do ns.say(l) end
  end, { "shared", "pricefeed" })
  -- the main window on a page: /eah options (config) the settings, /eah home the Home page
  app:Command("options", "options", "the settings (General)", function() app:Open("general") end, { "config" }).hidden = true
  app:Command("home", "home", "the main window's Home page", function() if ns.hub then ns.hub.open("home") end end, { "hub", "main" }).hidden = true
  app:Command("minimap", "minimap [on|off]", "show or hide the minimap button (on its own: switches it)", function(rest, a)
    local def = a:GetSetting("minimap")
    if not def then return end
    if not (rest or ""):match("%S") then rest = def.get() and "off" or "on" end
    a:SetFromText(def, rest)
  end, { "minimapbutton", "icon" })
  app:Command("sell", "sell", "open Quick sell (auction house open)", function() ns.slash("sell") end, { "selling", "quicksell", "quick" })
  app:Command("shop", "shop", "open Shopping (auction house open)", function() ns.slash("shop") end, { "shopping", "lists" })
  app:Command("bought", "bought", "your auction house purchases, and a recipe's cost from what you paid (works anywhere)", function()
    if ns.purchases then ns.purchases.toggle() end
  end, { "purchases", "buys", "log" })
  app:Command("prices", "prices", "search everything in the last price update, anywhere (the same search as Advanced search)", function()
    if ns.openSearch then ns.openSearch() end
  end, { "price", "lookup", "search", "find", "db" })
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
  app:Command("buy", "buy [list]", "buy a shopping list item by item: it asks about each one, you press Buy (auction house open)", function(rest)
    ns.slash(rest == "" and "buy" or ("buy " .. rest))
  end, { "buylist" })
  app:Command("import", "import", "paste a list of items to buy into a shopping list (auction house open)", function()
    ns.slash("import")
  end, { "paste" })
  -- "/eah undercut 1s" keeps its own reply (it names the step); "/eah set undercut 1s" works as for any setting
  app:Command("undercut", "undercut", "", function(rest) ns.slash("undercut " .. rest) end).hidden = true
  app:Command("myprices", "myprices [name = formula; ...]", "your price formulas, like myfloor = max(vendor * 1.5, 80% of low30)", function(rest)
    rest = (rest or ""):match("^%s*(.-)%s*$")
    if rest ~= "" then
      local okSet, why = ns.setMyPrices(rest)
      if not okSet then app:Print("My prices not saved: " .. why) return end
    end
    local text = ns.myPricesText() or ""
    app:Print(text ~= "" and ("My prices: " .. text:gsub("%s*\n%s*", "; ")) or "No My prices yet. e.g. /eah myprices myfloor = max(vendor * 1.5, 80% of low30)")
  end, { "myprice", "formulas" })
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

  -- the settings pages (the "settings" group: the last one, so it needs no group = ...)
  local function logPage(mode)
    return function()
      if ns.purchases then ns.purchases.mode = mode end
      if ns.hub then ns.hub.open("log") end
    end
  end
  app:Section("general", "General", function(stack)
    UI.Header(stack, "General")
    app:Widget(stack, "openon")
    app:Widget(stack, "auto")
    app:Widget(stack, "feed")
    UI.Note(stack, function() return ns.shared and ns.shared.feedLine() or "" end)
    app:Widget(stack, "reloadhint")
    app:Widget(stack, "reloadafter")
    app:Widget(stack, "minimap")
    app:Widget(stack, "skin")
    app:Widget(stack, "compareshift")
    UI.Header(stack, "Chat commands")
    UI.Note(stack, "/eah  this window (Home, or the page you used last)\n/eah help  every command in chat\n/eah status  which auction houses have prices, and how old\n/eah feed  the Price Feed (/eah feed off turns it off)\n/eah scan  update prices now (auction house open)\n/eah sell, /eah shop  open Quick sell or Shopping\n/eah prices  Advanced search, anywhere\n/eah where <item>  which of your characters has it, and where\n/eah bought, /eah forsale, /eah income, /eah loot  the AH log\n/eah profit  Crafting profit\n/eah up  Gear upgrades (/eah up help for its commands)\n/eah minimap  show or hide the minimap button\n/eah run <list>  run a shopping list\n/eah myprices  your price formulas\n/eah undercut 1s  change a setting (/eah get lists them)\n/eah search <words>  find a setting\nKey Bindings, AddOns: a key for this window")
  end, { icon = "gear" })
  app:Section("selling", "Selling", function(stack)
    UI.Header(stack, "Selling", "Quick sell's price is the cheapest live auction minus your undercut. Blizzard's own Sell tab gets the same undercut when you pick an auction in its list.")
    app:Widget(stack, "undercut")
    app:Widget(stack, "duration")
    UI.Header(stack, "My prices", "Price formulas under a name: price lt myfloor in Advanced search, or myfloor as a shopping list's most to pay. Prices: price, median, low30, median30, vendor, craftcost, devalue (disenchanting), avgbuy and avgsell (your own purchases and sales); + - * /, min, max, first, 5g, 80% of median.")
    app:Widget(stack, "myprices")
  end, { icon = "share" })
  app:Section("tooltips", "Tooltips", function(stack)
    UI.Header(stack, "Tooltips", "Lines added to item tooltips: labels left, prices right with their coins in line. Every price says how old it is; prices over a day old are grey.")
    for _, t in ipairs(TIP_LINES) do app:Widget(stack, t[1]) end
    app:Widget(stack, "tipdetail")
    if app:GetSetting("tipsolid") then app:Widget(stack, "tipsolid") end
  end)
  app:Section("ahlog", "Logging", function(stack)
    UI.Header(stack, "Logging", "What the AH log keeps: what you bought, what you sold, your auctions and your loot. /eah bought, /eah forsale, /eah income and /eah loot open it, so does its Loot plugin on Everlook Bar.")
    UI.ButtonRow(stack, {
      { label = "Bought", width = 110, onClick = logPage("bought"),
        desc = "Everything you bought, and a recipe's cost per craft from what you paid.", keywords = { "bought", "purchases", "log", "open" } },
      { label = "For sale", width = 110, onClick = logPage("forsale"),
        desc = "Your auctions up for sale, as the auction house last showed them.", keywords = { "for sale", "listed", "posted", "auctions", "open" } },
      { label = "Income", width = 110, onClick = logPage("income"),
        desc = "Money you took from the mail: auctions sold and other gold.", keywords = { "income", "sold", "open" } },
      { label = "Looted", width = 110, onClick = logPage("looted"),
        desc = "Everything you looted, with when and where.", keywords = { "loot", "looted", "drops", "open" } },
    })
    UI.Header(stack, "What is logged")
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
  end, { icon = "clock" })
  if ns.deLog then ns.deLog.settingsFor(app, UI) end   -- the Disenchanting page (DisenchantLog.lua)
  if ns.upgradesSettings then ns.upgradesSettings(app, UI) end   -- the Gear upgrades page (UpgradesOptions.lua)
end

-- Opens the window, or says why it can't.
local function open()
  if not O.app then
    ns.say("the options couldn't be built" .. (ns.optionsError and (": " .. ns.plain(ns.optionsError)) or "")
      .. ". Settings still work as commands: /eah help lists them, for example /eah auto off.")
    return
  end
  O.app:Open("general")
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
