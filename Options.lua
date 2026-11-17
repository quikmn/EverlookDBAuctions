-- EverlookDB Auctions: options, in the game's Settings under AddOns (or /eah options).
--   Selling   undercut, default duration
--   Tooltips  auction price, 30-day low and median, vendor price, full-stack price with Shift
--   General   automatic full scan, the EverlookDB look for Blizzard's auction house, crafting cost
local ADDON, ns = ...
local UI, T = ns.UI, ns.T

local O = {}

local TIP_LINES = {
  { "auction", "Auction price, how many are up and how old the price is" },
  { "history", "30-day low and median" },
  { "disenchant", "What disenchanting it is worth (an estimate from material prices)" },
  { "vendor", "Vendor price" },
  { "stack", "Hold Shift for the price of a full stack" },
}

-- Feedback link. Addons can't open a browser, so show the link selected in a box to copy.
local FEEDBACK_URL = "https://everlookdb.com/auctions-addon.html#feedback"
StaticPopupDialogs["EVERLOOKDBAUCTIONS_FEEDBACK"] = {
  text = "Report a bug or suggest an idea.\nPress Ctrl+C to copy the link, then paste it in your browser.",
  button1 = CLOSE or "Close",
  hasEditBox = true,
  editBoxWidth = 320,
  OnShow = function(self)
    local eb = self.EditBox or self.editBox
    if not eb then return end
    eb:SetText(FEEDBACK_URL)
    eb:SetFocus()
    eb:HighlightText()
  end,
  EditBoxOnTextChanged = function(eb)
    if eb:GetText() ~= FEEDBACK_URL then
      eb:SetText(FEEDBACK_URL)
      eb:HighlightText()
    end
  end,
  EditBoxOnEnterPressed = function() StaticPopup_Hide("EVERLOOKDBAUCTIONS_FEEDBACK") end,
  EditBoxOnEscapePressed = function() StaticPopup_Hide("EVERLOOKDBAUCTIONS_FEEDBACK") end,
  timeout = 0,
  whileDead = true,
  hideOnEscape = true,
  preferredIndex = 3,
}

local function feedback() StaticPopup_Show("EVERLOOKDBAUCTIONS_FEEDBACK") end
ns.feedback = feedback

local function section(parent, text, y)
  local h = UI.text(parent, "title")
  h:SetPoint("TOPLEFT", 16, y)
  h:SetText(text)
  local line = UI.line(parent, true)
  line:SetPoint("TOPLEFT", 16, y - 20)
  line:SetPoint("RIGHT", parent, "RIGHT", -16, 0)
  return h
end

local function refresh()
  local p = O.panel
  local db = ns.db()
  if not p or not db then return end
  p.cut:SetText(ns.undercutShort())
  local s = ns.sellSettings()
  for _, b in ipairs(p.durs) do b:EdbActive(b.dur == (s.duration or 1)) end
  for _, c in ipairs(p.tips) do c:EdbChecked(ns.tipOn(c.key)) end
  p.auto:EdbChecked(db.auto ~= false)
  p.skin:EdbChecked(db.skin ~= false)
  p.craft:EdbChecked(db.craft ~= false)
end

local function build()
  local p = UI.own(CreateFrame("Frame", "EverlookAuctionsOptions"))
  p.name = "EverlookDB Auctions"
  UI.panel(p, T.bg, T.edge)
  O.panel = p

  local title = UI.text(p, "big")
  title:SetPoint("TOPLEFT", 16, -16)
  title:SetText("EverlookDB Auctions")
  local fb = UI.button(p, "Feedback / report a bug", 170, 24, "small")
  fb:SetPoint("TOPRIGHT", -16, -16)
  fb:SetScript("OnClick", feedback)
  local sub = UI.text(p, "dim")
  sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
  sub:SetText("Prices, selling and shopping lists for the auction house. Sellers and bidders are never saved.")

  -- selling
  section(p, "Selling", -64)
  local cl = UI.label(p, "UNDERCUT BY", "mute")
  cl:SetPoint("TOPLEFT", 16, -96)
  p.cut = UI.input(p, 90, 24, { hint = "1s or 5%", max = 10 })
  p.cut:SetPoint("TOPLEFT", 16, -112)
  p.note = UI.text(p, "mute")
  p.note:SetPoint("LEFT", p.cut, "RIGHT", 10, 0)
  p.note:SetPoint("RIGHT", p, "RIGHT", -16, 0)   -- a long error wraps inside the window instead of running off it
  p.note:SetWordWrap(true)
  p.note:SetText("1s, 50c, 1g, 5%, or 0 to match the cheapest. Press Enter.")
  p.cut:SetScript("OnEnterPressed", function(self)
    local okSet, why = ns.setUndercut(self:GetText())
    p.note:SetText(okSet and "Saved." or why)
    p.note:SetTextColor(unpack(okSet and T.good or T.bad))
    self:ClearFocus()
  end)
  p.cut:HookScript("OnEditFocusLost", function(self) self:SetText(ns.undercutShort()) end)

  local dl = UI.label(p, "DEFAULT DURATION", "mute")
  dl:SetPoint("TOPLEFT", 16, -148)
  p.durs = {}
  for k, d in ipairs({ { 1, "12 hours" }, { 2, "24 hours" }, { 3, "48 hours" } }) do
    local b = UI.button(p, d[2], 76, 24, "small")
    b:SetPoint("TOPLEFT", 16 + (k - 1) * 80, -164)
    b.dur = d[1]
    b:SetScript("OnClick", function()
      ns.sellSettings().duration = d[1]
      refresh()
    end)
    p.durs[k] = b
  end
  local dn = UI.text(p, "mute")
  dn:SetPoint("LEFT", p.durs[3], "RIGHT", 10, 0)
  dn:SetText("Items you've posted before keep their own duration.")

  -- tooltips
  section(p, "Tooltips", -208)
  p.tips = {}
  for k, t in ipairs(TIP_LINES) do
    local c = UI.check(p, t[2], function(_, on)
      local db = ns.db()
      db.tip = db.tip or {}
      db.tip[t[1]] = on
    end)
    c:SetPoint("TOPLEFT", 16, -240 - (k - 1) * 24)
    c.key = t[1]
    p.tips[k] = c
  end

  -- general
  section(p, "General", -374)
  p.auto = UI.check(p, "Update prices by themselves while the auction house is open (every 15 minutes)", function(_, on)
    ns.db().auto = on
  end)
  p.auto:SetPoint("TOPLEFT", 16, -406)
  p.skin = UI.check(p, "EverlookDB look for Blizzard's auction house (after /reload)", function(_, on)
    ns.db().skin = on
  end)
  p.skin:SetPoint("TOPLEFT", 16, -430)
  p.craft = UI.check(p, "Crafting cost beside the profession window", function(_, on)
    ns.db().craft = on
    if ns.craftRefresh then ns.craftRefresh() end
  end)
  p.craft:SetPoint("TOPLEFT", 16, -454)

  p:SetScript("OnShow", refresh)

  if Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory then
    local okReg, cat = pcall(Settings.RegisterCanvasLayoutCategory, p, p.name)
    if okReg and cat then
      pcall(Settings.RegisterAddOnCategory, cat)
      O.category = cat
    end
  elseif InterfaceOptions_AddCategory then
    pcall(InterfaceOptions_AddCategory, p)
  end
end

-- Opens the options and says so in chat, or says why they didn't open.
local function open()
  if not O.panel then
    ns.say("the options couldn't be built" .. (ns.optionsError and (": " .. ns.plain(ns.optionsError)) or "")
      .. ". Settings still work as commands: /eah help lists them, for example /eah auto off.")
    return
  end
  local cat = O.category
  if cat and Settings and Settings.OpenToCategory then
    local id = (cat.GetID and cat:GetID()) or cat.ID
    if pcall(Settings.OpenToCategory, id) then ns.say("options opened. /eah help lists the commands."); return end
  end
  if InterfaceOptionsFrame_OpenToCategory and pcall(InterfaceOptionsFrame_OpenToCategory, O.panel) then
    ns.say("options opened. /eah help lists the commands.")
    return
  end
  ns.say("couldn't open the options; find EverlookDB Auctions in the game's Settings under AddOns.")
end

-- A setting changed by a command (/eah auto off, /eah undercut 5%) shows at once if the options are open.
function ns.optionsRefresh()
  if O.panel and O.panel:IsShown() then refresh() end
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:SetScript("OnEvent", function(_, _, name)
  if name ~= ADDON then return end
  ev:UnregisterEvent("ADDON_LOADED")
  -- the core sets up the saved data on this same event, first (it loads first)
  local okBuild, err = pcall(build)
  if not okBuild then ns.optionsError = err end
end)

local prevSlash, prevHelp = ns.slash, ns.help
function ns.slash(msg)
  if msg == "options" or msg == "config" or msg == "settings" then
    open()
    return true
  end
  if msg == "feedback" or msg == "bug" then
    feedback()
    return true
  end
  return prevSlash and prevSlash(msg) or false
end
function ns.help()
  if prevHelp then prevHelp() end
  print("  /eah options  open the options")
  print("  /eah feedback  a link for reporting bugs and ideas")
end
