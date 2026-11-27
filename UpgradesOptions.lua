-- EverlookDB Auctions: the "Gear upgrades" settings page and the /eah up commands.
-- Options.lua calls ns.upgradesSettings(app, UI) while it builds the window.
local ADDON, ns = ...
local U = ns.up

local O = {}
ns.upOptions = O

local function say(msg) if ns.say then ns.say(msg) end end
local function money(c) return ns.money and ns.money(c) or tostring(c) end
local function plain(t) return ns.plain and ns.plain(t) or tostring(t or "") end

-- The spec the page (and /eah up weights) is about: the one shown on the Upgrades tab, else the first ticked one.
function O.spec()
  local c = U.char()
  return (c.page and U.spec(c.page)) or (c.shown and U.spec(c.shown)) or U.ticked()[1]
end

local function fmt(v)
  local s = ("%.3f"):format(v):gsub("0+$", ""):gsub("%.$", "")
  return s
end

-- "Strength 2.2*, Agility 1.7, ..." for a spec's weights in use (biggest first; * = a talent changed it).
function O.weightsText(spec)
  if not spec then return "No specs for your class." end
  local w, why, from, label, meta = U.weights(spec)
  local rows = {}
  for k, v in pairs(w) do if v ~= 0 and U.NAME[k] then rows[#rows + 1] = { k, v } end end
  table.sort(rows, function(a, b) return a[2] > b[2] end)
  local parts = {}
  for _, r in ipairs(rows) do parts[#parts + 1] = U.NAME[r[1]] .. " " .. fmt(r[2]) .. (why[r[1]] and "*" or "") end
  local head = ("%s: %s"):format(spec.name, from == "profile" and ("your profile \"" .. label .. "\"")
    or from == "pawn" and ("Pawn's scale \"" .. label .. "\"") or (label or "built-in"))
  local talents = {}
  for k, t in pairs(why) do talents[t] = true end
  local tnames = {}
  for t in pairs(talents) do tnames[#tnames + 1] = t end
  table.sort(tnames)
  local tail = #tnames > 0 and ("\n* changed by your talents: " .. table.concat(tnames, ", ")) or ""
  local notes = ""
  if from == "built-in" and meta then
    if meta.src == "estimate" then notes = notes .. "\nAn estimate" .. (meta.why and (": " .. meta.why) or "") .. "." end
    local mana = {}
    for k in pairs(meta.mana or {}) do if w[k] then mana[#mana + 1] = U.NAME[k] or k end end
    table.sort(mana)
    if #mana > 0 then notes = notes .. "\nDepends on your mana: " .. table.concat(mana, ", ") .. " (the fight ends before you run out; never counted against an item)." end
    if not meta.fb then notes = notes .. "\nSimulated weights already include your build's talents."
    elseif U.get("talents") then
      -- say it when the talents aren't known, instead of quietly adjusting to none
      if U.ctx then
        if (tonumber(U.ctx.level) or 0) >= 10 and not next(U.ctx.talents or {}) then notes = notes .. "\nNo talents saved for " .. tostring(U.ctx.name or "this character") .. " yet, so these weights aren't adjusted to them. They're read when it logs in." end
      elseif not U.testTalents and not U.talentsReadable() then
        notes = notes .. "\nYour talents can't be read on this client, so these weights aren't adjusted to them."
      end
    end
    if spec.role == "tank" then notes = notes .. "\nTanks: the weights are for survival; threat is shown beside it in tooltips." end
  end
  return head .. "\n" .. (#parts > 0 and table.concat(parts, ", ") or "no stats") .. tail .. notes
end

-- An item from what was typed: a link, an item ID, or a name the game has loaded. Returns link, id.
function O.itemFrom(text)
  text = tostring(text or ""):match("^%s*(.-)%s*$")
  if text == "" then return nil end
  local link = text:match("|H(item:[^|]+)|h")
  if link then return link, tonumber(link:match("item:(%d+)")) end
  if text:match("^%d+$") then return "item:" .. text, tonumber(text) end
  local okI, _, l = pcall(C_Item.GetItemInfo, text)
  if okI and l then return l, tonumber(l:match("item:(%d+)")) end
  return nil
end

---------------------------------------------------------------------------------------------------------------------
-- Commands: /eah up ...

local HELP = {
  { "", "the Upgrades tab at the auction house, else its window (from the last scan, anywhere)" },
  { "help", "this list" },
  { "spec <name>", "the spec(s) you gear for: /eah up spec fury, /eah up spec fury arms, /eah up spec all" },
  { "weights", "the weights in use for your spec, * where a talent changed one" },
  { "reset", "back to the built-in weights for your spec" },
  { "set <stat> <value>", "change one weight in your own profile (0 removes the stat): /eah up set hit 1.4" },
  { "export", "your weights as a string to share" },
  { "import <string>", "weights from a string, ours or Pawn's ( Pawn: v1: ... )" },
  { "max <price>", "the most an upgrade may cost: 25g, 5s, 1g 50s; /eah up max off" },
  { "min <percent>", "the smallest upgrade shown, in % of your gear: /eah up min 1" },
  { "rich on|off", "on: the biggest upgrade within the max price; off: the most upgrade per gold" },
  { "solo|group", "weights for solo levelling (the default) or for groups and dungeons" },
  { "check", "check every worn item's stats were read" },
  { "stats <item>", "an item's stats and score (a link, an item ID or a name)" },
  { "price <item>", "an item's lowest price now and over 30 days" },
  { "junk", "sell your grey items (a vendor open)" },
  { "mem", "memory used and items held" },
}

function O.help()
  say("gear upgrades commands:")
  for _, h in ipairs(HELP) do
    print(("  |cffffd200/eah up%s|r  %s"):format(h[1] ~= "" and (" " .. h[1]) or "", h[2]))
  end
end

local function cmdSpec(rest)
  rest = rest:lower()
  if rest == "" then
    local names = {}
    for _, s in ipairs(U.ticked()) do names[#names + 1] = s.name end
    local all = {}
    for _, s in ipairs(U.specs()) do all[#all + 1] = s.key end
    say(("you gear for %s. Change it: /eah up spec <%s> (several allowed, or all)."):format(table.concat(names, ", "), table.concat(all, "|")))
    return
  end
  local keys = {}
  if rest == "all" then
    for _, s in ipairs(U.specs()) do keys[#keys + 1] = s.key end
  else
    for word in rest:gmatch("[^%s,]+") do
      local s = U.findSpec(word)
      if not s then say(("no spec '%s' for your class."):format(word)); return end
      keys[#keys + 1] = s.key
    end
  end
  U.setSpecs(keys)
  local names = {}
  for _, s in ipairs(U.ticked()) do names[#names + 1] = s.name end
  say("gear upgrades for " .. table.concat(names, ", ") .. ".")
end

function O.check()
  U.forgetStats()
  local worn = U.readWorn()
  local missing, empty, n = {}, {}, 0
  for slot, it in pairs(worn) do
    n = n + 1
    if not it.stats then
      missing[#missing + 1] = it.link
    elseif not next(it.stats) and slot ~= 4 and slot ~= 19 then
      -- nothing from the game: read the tooltip's lines (crit, hit and dodge in % become rating)
      local tip = C_TooltipInfo and C_TooltipInfo.GetInventoryItem and function() return C_TooltipInfo.GetInventoryItem("player", slot) end
      if tip and U.readTooltipLines(it.stats, tip) and next(it.stats) then
        empty[#empty + 1] = it.link .. " (read from its tooltip; % chances guessed as rating)"
      else
        empty[#empty + 1] = it.link .. " (no stats found)"
      end
    end
  end
  if n == 0 then say("you wear nothing the check could read."); return end
  if #missing > 0 then
    say(("%d of %d worn items aren't loaded yet: %s. Their stats are read again in a moment; try again then."):format(#missing, n, table.concat(missing, " ")))
  else
    say(("all %d worn items' stats were read."):format(n))
  end
  for _, l in ipairs(empty) do print("  " .. l) end
  U.wornChanged()
end

function O.stats(rest)
  local link, id = O.itemFrom(rest)
  if not id then say("/eah up stats <item>: a link (Shift-click it), an item ID, or a name you've seen this session."); return end
  local st = U.stats(link, id)
  if not st then say("that item isn't loaded yet; try again in a moment."); return end
  local parts = {}
  for _, s in ipairs(U.STATS) do
    if st[s[1]] and st[s[1]] ~= 0 then parts[#parts + 1] = s[2] .. " " .. fmt(st[s[1]]) end
  end
  say((select(2, pcall(C_Item.GetItemInfo, link)) or link) .. ": " .. (#parts > 0 and table.concat(parts, ", ") or "no stats"))
  local X = ns.upExtras
  for _, spec in ipairs(U.ticked()) do
    local r, why = X and X.forSpec(link, id, spec)
    local w = U.weights(spec)
    local okI, _, _, _, equipLoc = pcall(C_Item.GetItemInfoInstant, id)
    local g = okI and U.GROUP_OF[equipLoc or ""]
    local score = g and U.score(st, w, g, id, spec.role) or 0
    local verdict = why == "class" and "your class can't use this" or why == "armor" and "not your armor type"
      or (r and r.note == "twohand") and "you wear a two-handed weapon"
      or (r and U.isUpgrade(r, 0)) and (U.pctText(r) .. (r.pct and " of your gear" or "") .. (r.vs and r.note ~= "empty" and (" vs " .. r.vs.link) or "")
        .. (U.whyText(r) and (": " .. U.whyText(r)) or ""))
      or (r and r.same) and ("about the same (within the weights' margin): " .. (U.whyText(r) or ""))
      or "not an upgrade"
    print(("  %s: score %s, %s"):format(spec.name, fmt(score), verdict))
  end
end

function O.price(rest)
  local link, id = O.itemFrom(rest)
  if not id then say("/eah up price <item>: a link (Shift-click it), an item ID, or a name you've seen this session."); return end
  local it = ns.itemFor and ns.itemFor(id)
  local name = (select(2, pcall(C_Item.GetItemInfo, link)) or link)
  if not it or not it[1] then say(name .. ": no price saved for it yet."); return end
  local age = ns.ago and ns.ago(time() - (it[4] or time())) or ""
  local h = ns.historyFor and ns.historyFor(id) or {}
  local lo, sorted = nil, {}
  for _, d in ipairs(h) do
    sorted[#sorted + 1] = d[2]
    if not lo or d[2] < lo then lo = d[2] end
  end
  table.sort(sorted)
  local med = #sorted > 0 and sorted[math.floor((#sorted + 1) / 2)] or nil
  say(("%s: lowest %s (%s%s)%s"):format(name, money(it[1]), age, it.shared and ", other players' scan" or "",
    lo and (("; 30 days: low %s, median %s over %d days"):format(money(lo), money(med), #sorted)) or ""))
end

function O.mem()
  if UpdateAddOnMemoryUsage then pcall(UpdateAddOnMemoryUsage) end
  local okM, kb = pcall(GetAddOnMemoryUsage, ADDON)
  local r = U.result
  say(("memory %s, %d item stats held this session, last read %s gear items (%d upgrades)."):format(
    okM and kb and (kb >= 1024 and ("%.1f MB"):format(kb / 1024) or ("%d KB"):format(kb)) or "?",
    U.cacheSize(), r and r.gear or 0, r and r.upgrades or 0))
end

function O.slash(rest)
  rest = tostring(rest or ""):match("^%s*(.-)%s*$")
  local word, arg = rest:match("^(%S+)%s*(.*)$")
  word = word and word:lower() or ""
  local spec = O.spec()
  if word == "" then
    if ns.upgradesView then ns.upgradesView.open() end
  elseif word == "help" or word == "?" then
    O.help()
  elseif word == "spec" or word == "specs" then
    cmdSpec(arg)
  elseif word == "weights" or word == "weight" then
    if arg ~= "" then local s = U.findSpec(arg); spec = s or spec end
    say(O.weightsText(spec))
  elseif word == "reset" then
    if spec then U.char().profile[spec.key] = nil; U.changed(); say(spec.name .. ": back to the built-in weights.") end
  elseif word == "set" then
    local stat, v = arg:match("^(%S+)%s+(%-?[%d%.]+)$")
    stat = stat and stat:lower()
    if not stat or not U.NAME[stat] then
      local keys = {}
      for _, s in ipairs(U.STATS) do keys[#keys + 1] = s[1] end
      say("/eah up set <stat> <value>; stats: " .. table.concat(keys, ", "))
      return
    end
    local p = U.setWeight(spec.key, stat, v)
    say(("%s is now %s in your profile \"%s\"."):format(U.NAME[stat], tonumber(v) == 0 and "removed" or v, p.name))
  elseif word == "export" then
    local w, _, _, label = U.weights(spec)
    local s = U.export(w, spec.key, label)
    say("your weights (open the Gear upgrades page of /eah to copy them): " .. s)
    O.lastExport = s
  elseif word == "import" then
    local p, why = U.import(arg)
    if not p then say("couldn't import: " .. why); return end
    local target = (p.spec and p.class == U.class() and U.spec(p.spec)) or spec
    local saved = U.saveProfile(target.key, p.name, p.w)
    say(("imported \"%s\" as a profile for %s; it is in use now."):format(saved.name, target.name))
  elseif word == "max" then
    if arg == "" or arg:lower() == "off" or arg:lower() == "any" then
      U.set("max", nil); say("no max price for upgrades.")
    else
      local c = U.parseMoney(arg)
      if not c then say("max price: like 25g, 5s or 1g 50s."); return end
      U.set("max", c); say("upgrades up to " .. money(c) .. " per item.")
    end
  elseif word == "min" then
    local n = tonumber((arg:gsub("%%", "")))
    if not n or n < 0 then say("/eah up min <percent>, like /eah up min 1."); return end
    U.set("min", n); say(("upgrades of %s%% of your gear or more."):format(fmt(n)))
  elseif word == "rich" then
    local on = arg:lower()
    if on == "" then on = U.get("rich") and "off" or "on" end
    if on ~= "on" and on ~= "off" then say("/eah up rich on|off"); return end
    U.set("rich", on == "on")
    say(on == "on" and "rich mode: the biggest upgrade within your max price." or "the most upgrade per gold.")
  elseif word == "solo" or word == "group" then
    U.set("scenario", word)
    say("stat weights for " .. U.SCENARIOS[word]:lower() .. ".")
  elseif word == "check" then
    O.check()
  elseif word == "stats" or word == "stat" then
    O.stats(arg)
  elseif word == "price" or word == "prices" then
    O.price(arg)
  elseif word == "junk" or word == "grey" or word == "gray" then
    if ns.upExtras then ns.upExtras.sellJunk(true) end
  elseif word == "mem" or word == "memory" then
    O.mem()
  else
    say(("no gear upgrades command '%s'."):format(plain(word)))
    O.help()
  end
end

---------------------------------------------------------------------------------------------------------------------
-- The settings page

local SETTINGS = {
  { "tip", "Upgrades on item tooltips", "On gear: how big an upgrade it is for each spec you gear for, or why it isn't one (your class can't use it, not your armor type). With Tooltip details on, also what it's worth in your main stat.", { "tooltip", "upgrade", "percent" } },
  { "bags", "Upgrade badges on bag slots", "A small +23% on bag slots holding an upgrade (Blizzard's bags and Bagnon).", { "bag", "badge", "bagnon", "bagbrother" } },
  { "chat", "Say new upgrades in chat", "One chat line when new gear in your bags (a drop, a quest reward, the mail) is an upgrade. Once per item.", { "chat", "new", "loot", "drop" } },
  { "quest", "Mark the best quest reward", "In the quest reward window: the upgrade on each choice, a star on the best, and a chat line. When none is an upgrade, the one that sells for the most.", { "quest", "reward", "star", "choice" } },
  { "junk", "Sell grey items at vendors", "When a vendor opens, sell every grey (poor quality) item in your bags. Only greys, never anything else. /eah up junk does it once.", { "junk", "grey", "gray", "vendor", "sell", "trash" } },
  { "procs", "Count the average value of procs and Use: effects", "Weapon and trinket procs and Use: effects count as their average stats or damage over a fight (from wowsims' item data).", { "proc", "use", "trinket", "effect", "chance" } },
  { "armor", "Only suggest the best armor type for my class", "For example only plate for a warrior from level 40, mail for a hunter. Casters and healers see every armor type they can wear.", { "armor", "plate", "mail", "leather", "cloth" } },
  { "talents", "Adjust weights to my talents", "Talents that raise a stat (or turn one stat into another) change the estimated weights; the changed weights get a *. Simulated weights already include your build's talents.", { "talent", "weights", "star" } },
  { "pawn", "Use Pawn's scale for my spec", "When Pawn is installed: its scale named like your spec instead of the built-in weights. A profile of your own comes first.", { "pawn", "scale", "weights" } },
  { "rich", "Rich mode", "On: the biggest upgrade within your max price. Off: the most upgrade per gold. /eah up rich on|off.", { "rich", "gold", "biggest", "cheap", "per gold" } },
}

function ns.upgradesSettings(app, UI)
  O.app = app
  for _, s in ipairs(SETTINGS) do
    app:Setting({ key = "up" .. s[1], type = "bool", label = s[2], desc = s[3], keywords = s[4], chatLabel = "Gear upgrades: " .. s[2]:lower(),
      get = function() return U.get(s[1]) and true or false end,
      set = function(v) U.set(s[1], v and true or false) end })
  end
  app:Setting({ key = "upmax", type = "string", label = "Max price per upgrade", width = 120, placeholder = "any",
    desc = "Upgrades that cost more aren't suggested: 25g, 5s, 1g 50s; empty for any price. /eah up max 25g.",
    keywords = { "max", "price", "budget", "gold", "ceiling" },
    get = function() return U.get("max") and U.moneyShort(U.get("max")) or "" end,
    set = function(v)
      v = tostring(v or ""):match("^%s*(.-)%s*$")
      if v == "" or v:lower() == "any" or v:lower() == "off" then U.set("max", nil); return end
      local c = U.parseMoney(v)
      if c then U.set("max", c) else app:Print("max price: like 25g, 5s or 1g 50s.") end
    end })
  app:Setting({ key = "upmin", type = "number", label = "Smallest upgrade (% of your gear)", min = 0, max = 10, step = 0.5,
    desc = "Upgrades smaller than this aren't shown. /eah up min 1.", keywords = { "min", "percent", "smallest", "threshold" },
    get = function() return tonumber(U.get("min")) or 0 end, set = function(v) U.set("min", tonumber(v) or 0) end })
  -- the specs of this class, one switch each
  local specs = U.specs()
  for _, s in ipairs(specs) do
    app:Setting({ key = "upspec" .. s.key, type = "bool", label = "I gear for " .. s.name,
      desc = "Upgrades, tooltips, badges and quest rewards for " .. s.name .. ". Tick more than one if you're not sure yet; none ticked counts every spec.",
      keywords = { "spec", "specialization", "role", s.key, s.name:lower() }, chatLabel = "Gear upgrades: " .. s.name,
      get = function() return U.char().specs[s.key] and true or false end,
      set = function(v)
        local c = U.char()
        c.specs[s.key] = v and true or nil
        c.asked = true
        U.changed()
      end })
  end
  app:Setting({ key = "upscenario", type = "choice", label = "Weights for", width = 170,
    choices = { { value = "solo", text = U.SCENARIOS.solo }, { value = "group", text = U.SCENARIOS.group } },
    desc = "Solo levelling: what kills mobs fastest, rest included. Groups and dungeons: longer fights in a group (at 60: the 5-man buffs). /eah up solo, /eah up group.",
    keywords = { "solo", "group", "dungeon", "levelling", "leveling", "scenario", "party" },
    get = function() return U.get("scenario") end, set = function(v) U.set("scenario", v) end })
  local specChoices = {}
  for _, s in ipairs(specs) do specChoices[#specChoices + 1] = { value = s.key, text = s.name } end
  if #specChoices > 0 then
    app:Setting({ key = "upweightspec", type = "choice", label = "Weights of", width = 170, choices = specChoices,
      desc = "The spec whose weights and profiles the buttons below change.", keywords = { "weights", "profile", "spec" },
      get = function() local s = O.spec(); return s and s.key end,
      set = function(v) U.char().page = v; U.changed() end })
  end

  app:Section("upgrades", "Specs and weights", function(stack)
    UI.Header(stack, "Specs and weights", "What Gear upgrades scores gear with: your specs, the price limits and the stat weights. Gear upgrades is a page of this window, and the Upgrades tab at the auction house.")
    UI.ButtonRow(stack, {
      { label = "Open Gear upgrades", width = 160, onClick = function() if ns.upgradesView then ns.upgradesView.open() end end,
        desc = "The best upgrade per slot from the last scan: the tab at the auction house, else a window of its own.", keywords = { "open", "upgrades", "window", "tab" } },
    })
    UI.Header(stack, "Your specs")
    for _, s in ipairs(specs) do app:Widget(stack, "upspec" .. s.key) end
    UI.Header(stack, "Shopping")
    app:Widget(stack, "upmax")
    app:Widget(stack, "upmin")
    app:Widget(stack, "uprich")
    app:Widget(stack, "uparmor")
    app:Widget(stack, "upprocs")
    UI.Header(stack, "Around the game")
    app:Widget(stack, "uptip")
    app:Widget(stack, "upbags")
    app:Widget(stack, "upchat")
    app:Widget(stack, "upquest")
    app:Widget(stack, "upjunk")
    UI.Header(stack, "Stat weights", "What one point of each stat is worth. Built in per spec and level; copy them into a profile of your own to change any value.")
    app:Widget(stack, "upscenario")
    if #specChoices > 0 then app:Widget(stack, "upweightspec") end
    app:Widget(stack, "uptalents")
    app:Widget(stack, "uppawn")
    local note = UI.Note(stack, function() return O.weightsText(O.spec()) end)
    local function refresh() if note.Refresh then note:Refresh() end end
    U.onChange(refresh)
    UI.ButtonRow(stack, {
      { label = "< Previous", width = 100, onClick = function() local s = O.spec(); if s then say(s.name .. ": " .. U.stepProfile(s.key, -1)) end; refresh() end,
        desc = "The previous profile of this spec (built-in, then yours).", keywords = { "profile", "previous" } },
      { label = "Next >", width = 100, onClick = function() local s = O.spec(); if s then say(s.name .. ": " .. U.stepProfile(s.key, 1)) end; refresh() end,
        desc = "The next profile of this spec.", keywords = { "profile", "next" } },
      { label = "Copy", width = 90, onClick = function()
          local s = O.spec()
          if s then local w = U.weights(s); local p = U.saveProfile(s.key, s.name .. " (mine)", w); say("made the profile \"" .. p.name .. "\"; change values below.") end
          refresh()
        end, desc = "Copy the weights in use into a profile of your own, to change.", keywords = { "profile", "copy", "new", "edit" } },
      { label = "Reset", width = 90, onClick = function()
          local s = O.spec()
          if s then U.char().profile[s.key] = nil; U.changed(); say(s.name .. ": back to the built-in weights.") end
          refresh()
        end, desc = "Back to the built-in weights (your profiles are kept).", keywords = { "reset", "built-in", "default" } },
      { label = "Delete", width = 90, confirm = true, onClick = function()
          local s = O.spec()
          local okD, name = U.deleteProfile(s and s.key)
          say(okD and ("deleted the profile \"" .. name .. "\".") or "the built-in weights can't be deleted.")
          refresh()
        end, desc = "Delete the profile in use. The built-in weights can't be deleted.", keywords = { "delete", "remove", "profile" } },
    })
    UI.Input(stack, { label = "Change a weight", width = 150, placeholder = "hit 1.4",
      desc = "A stat and its value, in your own profile (made from the weights in use when you have none). 0 removes the stat.",
      keywords = { "edit", "weight", "value", "change" }, searchKey = "upsetweight",
      button = { label = "Set", width = 60, onClick = function(text, box)
        local s = O.spec()
        if s then O.slash("set " .. tostring(text or "")) end
        box:SetText("")
        refresh()
      end } })
    UI.Input(stack, { label = "Import weights", width = 220, placeholder = "EAH-UP:1:... or ( Pawn: v1: ... )",
      desc = "Paste a string from /eah up export, or Pawn's export text. It becomes a profile of yours and is used at once.",
      keywords = { "import", "pawn", "paste", "share" }, searchKey = "upimport",
      button = { label = "Import", width = 70, onClick = function(text, box) O.slash("import " .. tostring(text or "")); box:SetText(""); refresh() end } })
    UI.CopyBox(stack, "Export (click, then Ctrl+C)", function()
      local s = O.spec()
      if not s then return "" end
      local w, _, _, label = U.weights(s)
      return U.export(w, s.key, label)
    end)
    UI.Header(stack, "Chat commands")
    local lines = {}
    for _, h in ipairs(HELP) do lines[#lines + 1] = "/eah up" .. (h[1] ~= "" and (" " .. h[1]) or "") .. "  " .. h[2] end
    UI.Note(stack, table.concat(lines, "\n"))
    UI.Header(stack, "Where the numbers come from")
    UI.Note(stack, "Stat weights: our own simulations (wowsims/forever, MIT, with levelling added), estimates marked. "
      .. "Where we have no simulation yet (some specs below 60, tanks' survival below 60): the per-level model of Forever Leveling BiS v0.12.0-beta, MIT license, Copyright (c) 2026 Thunder, marked as estimates. "
      .. "Talent effects, item procs and rating conversions: wowsims/forever (github.com/wowsims/forever), MIT license. Item names and prices: EverlookDB and your own scans.")
  end, { icon = "sliders" })

  app:Command("up", "up", "gear upgrades: the Upgrades tab or window (/eah up help for its commands)", function(rest) O.slash(rest) end, { "upgrades", "upgrade", "gear" })
end
