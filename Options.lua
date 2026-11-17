-- EverlookDB Auctions: the settings window (/eah), on the shared EverlookUI look (the same as Lattice and the other
-- EverlookDB addons), with its entry in the game's Settings under AddOns.
--   Selling   undercut, default duration
--   Tooltips  auction price, 30-day low and median, disenchant value, vendor price, full-stack price with Shift
--   General   automatic price updates, the EverlookDB look for Blizzard's auction house, crafting cost
-- Every setting is also a command: /eah <setting> <value> sets it, says so in chat and updates the open window;
-- /eah settings lists them. The core (EverlookDBAuctions.lua) routes /eah here.
local ADDON, ns = ...
local UI = LibStub and LibStub("EverlookUI-1", true)

local O = {}

local FEEDBACK_URL = "https://everlookdb.com/auctions-addon.html#feedback"

local TIP_LINES = {
  { "tipprice", "auction", "Auction price, how many are up and how old the price is" },
  { "tiphistory", "history", "30-day low and median" },
  { "tipdisenchant", "disenchant", "What disenchanting it is worth (an estimate from material prices)" },
  { "tipvendor", "vendor", "Vendor price" },
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

  -- general
  app:Setting({
    key = "auto", type = "bool", label = "Update prices by themselves while the auction house is open (every 15 minutes)",
    chatLabel = "Automatic price updates", keywords = { "scan", "automatic", "refresh", "auto" },
    get = function() return db().auto ~= false end,
    set = function(v) db().auto = v end,
  })
  app:Setting({
    key = "skin", type = "bool", label = "EverlookDB look for Blizzard's auction house (after /reload)", keywords = { "skin", "theme", "style" },
    get = function() return db().skin ~= false end,
    set = function(v) db().skin = v end,
  })
  app:Setting({
    key = "crafting", type = "bool", label = "Crafting cost beside the profession window", keywords = { "reagents", "materials", "profit", "tradeskill" },
    get = function() return db().craft ~= false end,
    set = function(v) db().craft = v end,
    after = function() if ns.craftRefresh then ns.craftRefresh() end end,
  })

  app:Section("selling", "Selling", function(stack)
    UI.Header(stack, "Selling", "Quick sell's price is the cheapest live auction minus your undercut. Blizzard's own Sell tab gets the same undercut when you pick an auction in its list.")
    app:Widget(stack, "undercut")
    app:Widget(stack, "duration")
  end)
  app:Section("tooltips", "Tooltips", function(stack)
    UI.Header(stack, "Tooltips", "Lines added to item tooltips. Every price says how old it is; prices over a day old are grey.")
    for _, t in ipairs(TIP_LINES) do app:Widget(stack, t[1]) end
  end)
  app:Section("general", "General", function(stack)
    UI.Header(stack, "General")
    app:Widget(stack, "auto")
    app:Widget(stack, "skin")
    app:Widget(stack, "crafting")
    UI.Header(stack, "Chat commands")
    UI.Note(stack, "/eah  this window\n/eah help  every command in chat\n/eah status  which auction houses have prices, and how old\n/eah scan  update prices now (auction house open)\n/eah sell, /eah shop  open Quick sell or Shopping\n/eah run <list>  run a shopping list\n/eah settings  every setting with its value\n/eah undercut 1s  change one setting")
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
