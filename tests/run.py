"""Offline tests in Lua 5.1 (WoW's version) via lupa: the shopping list from a recipe (RecipeList.lua), then the
crafting box and the shopping list panel (Crafting.lua) against a fake profession window (tests/mock.lua), the scroll
bars, and below vendor price (Vendor.lua and its search words in Search.lua) over a fake full scan.

Usage: python -P tests/run.py
"""
import re
import sys
from pathlib import Path

from lupa import lua51

ROOT = Path(__file__).resolve().parents[1]



def source_of(name):
    """A file's source. Skin.lua comes with LibStub and EverlookUI ahead of it, as the TOC loads them, so the rounded
    look (EverlookUI's U.Round and U.RoundOutline) is what the tests draw."""
    text = (ROOT / name).read_text(encoding="utf-8")
    if str(name) == "Skin.lua":
        libs = ""
        for lib in ("Libs/LibStub/LibStub.lua", "Libs/EverlookUI/EverlookUI.lua"):
            libs += "(function(...) " + (ROOT / lib).read_text(encoding="utf-8") + chr(10) + "end)(...);" + chr(10)
        text = libs + text
    return text


def main() -> int:
    lua = lua51.LuaRuntime(unpack_returned_tuples=True)
    ns = lua.table()
    run = lua.eval("function(src, name, ...) local f = assert(loadstring(src, name)); return f(...) end")
    run(source_of("RecipeList.lua"), "RecipeList.lua", "EverlookDBAuctions", ns)
    R = ns.recipeList
    failures = []

    def check(cond, what):
        if not cond:
            failures.append(what)

    # amount to buy
    check(R.toBuy(4, 1) == 3, "need 4, have 1: buy 3")
    check(R.toBuy(4, 9) == 0, "have more than needed: buy 0")
    check(R.toBuy(2, 1, 5) == 9, "2 each for 5 crafts, have 1: buy 9")
    check(R.toBuy(2, 0, 0) == 2, "crafts below 1 count as 1")
    check(R.toBuy(2, None) == 2, "no count owned counts as 0")

    # the search for an item
    check(R.query("Copper Bar") == 'name is "Copper Bar"', "query: exact name in quotes")
    check(R.query("Elixir of Giant's Growth") == 'name is "Elixir of Giant\'s Growth"', "query keeps an apostrophe")
    check(R.query('Odd "Name"') == 'name is "Odd Name"', "query drops double quotes")

    # rows and default ticks: Copper Rod (have 1, need 1), Copper Bar (have 1, need 4), Weak Flux (none, no price)
    names = {2880: "Weak Flux", 2840: "Copper Bar", 6217: "Copper Rod"}
    have = {2840: 1, 6217: 1}
    mats = lua.eval("{ { 6217, 1, 120 }, { 2840, 4, 35 }, { 2880, 1, nil } }")
    rows = R.rows(mats, 1, lambda _id: have.get(_id, 0), lambda _id: names[_id])
    check(len(rows) == 3, "three rows")
    check(rows[1].tick is False and rows[1].buy == 0, "enough Copper Rods: unticked, buy 0")
    check(rows[2].tick is True and rows[2].buy == 3 and rows[2].need == 4 and rows[2].have == 1, "Copper Bar: ticked, buy 3")
    check(rows[3].tick is True and rows[3].buy == 1 and rows[3].price is None, "Weak Flux: ticked, no price")

    rows3 = R.rows(mats, 3, lambda _id: have.get(_id, 0), lambda _id: names[_id])
    check(rows3[1].tick is True and rows3[1].buy == 2, "3 crafts: Copper Rod now short by 2")
    check(rows3[2].buy == 11 and rows3[2].need == 12, "3 crafts: 12 Copper Bars, buy 11")

    total, unpriced = R.total(rows)
    check(total == 3 * 35 and unpriced == 1, f"total of ticked rows: {total}, {unpriced} unpriced")

    # list creation and the saved-variable shape
    lists = lua.table()
    l, new, i = R.save(lists, "  Runed Copper Rod ", rows)
    check(new is True and i == 1 and len(lists) == 1, "a new list")
    check(l.name == "Runed Copper Rod", "named after the recipe, trimmed")
    qs = [l.queries[k] for k in range(1, len(l.queries) + 1)]
    check(qs == ['name is "Copper Bar"', 'name is "Weak Flux"'], f"ticked items only: {qs}")
    check(l.want['name is "Copper Bar"'] == 3 and l.want['name is "Weak Flux"'] == 1, "how many to buy of each")
    keys = sorted(k for k in l.keys())
    check(keys == ["name", "queries", "want"], f"saved fields: {keys}")
    for k in l.keys():
        v = l[k]
        check(isinstance(v, str) or lua.eval("type")(v) == "table", f"field {k} is text or a table")

    # untick one, edit an amount, save again: the same list is updated, not doubled
    rows[2].buy = 10
    rows[3].tick = False
    l2, new2, i2 = R.save(lists, "Runed Copper Rod", rows)
    check(new2 is False and i2 == 1 and len(lists) == 1, "same recipe updates its list")
    check(len(l2.queries) == 1 and l2.want['name is "Copper Bar"'] == 10 and l2.want['name is "Weak Flux"'] is None,
          "updated contents")

    # nothing ticked: no list
    rows[2].tick = False
    check(R.save(lists, "Something", rows) is None and len(lists) == 1, "nothing ticked makes no list")

    # an existing list from the Shopping tab is left alone
    other = lua.eval('{ name = "Trinkets", queries = { "slot is trinket" } }')
    lists2 = lua.table_from([other])
    rows[2].tick = True
    R.save(lists2, "Runed Copper Rod", rows)
    check(len(lists2) == 2 and lists2[1].name == "Trinkets" and lists2[1].want is None, "other lists untouched")

    failures += crafting_box()
    failures += scroll_bars()
    failures += below_vendor()
    failures += query_language()
    failures += search_queue()
    failures += undercut()
    failures += quick_sell()
    failures += places()
    failures += deals()
    failures += core_and_lists()
    failures += audit_search()
    failures += buy_panel()
    failures += buy_decisions()
    failures += ux_flows()
    failures += tooltip_text()
    failures += tooltip_reads_last()
    failures += shared_tooltip()
    failures += reload_logged()
    failures += scan_storage()
    failures += commodity_note()
    failures += purchases()
    failures += cheer()
    failures += buy_sort()
    failures += item_cache()
    failures += full_scan()
    failures += realm_repair()
    failures += profit()
    failures += shared_prices()
    failures += upgrades()
    failures += upgrades_ours()
    failures += start_tab()
    failures += upgrades_tab()
    failures += item_tip()
    failures += health()

    if failures:
        for f in failures:
            print("FAIL", f)
        return 1
    print("all tests passed")
    return 0


CRAFT_SETUP = """
local ns = ...
local db = {}
ns.UI = { own = function(f) return f end, fontObject = function() return {} end }
ns.db = function() return db end
ns.ok = function(v) return v end
ns.money = function(c) return GetMoneyString(c) end
ns.itemFor = function(id) local p = MOCK_PRICES[id]; return p and { p } end
ns.say = function() end
return db
"""


def crafting_box():
    lua = lua51.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(source_of("tests/mock.lua"))
    ns = lua.table()
    run = lua.eval("function(src, name, ...) local f = assert(loadstring(src, name)); return f(...) end")
    db = run(CRAFT_SETUP, "setup", ns)
    for name in ["RecipeList.lua", "Crafting.lua"]:
        run(source_of(name), name, "EverlookDBAuctions", ns)
    fire = lua.eval("function(e, a) for _, f in ipairs(MOCK_FRAMES) do if f.scripts.OnEvent then f.scripts.OnEvent(f, e, a) end end end")
    fire("ADDON_LOADED", "Blizzard_Professions")
    fire("TRADE_SKILL_SHOW")
    G = lua.globals()
    failures = []

    def check(cond, what):
        if not cond:
            failures.append("crafting: " + what)

    box = G.EverlookAuctionsCrafting
    check(box is not None and box.shown, "the box shows for the picked recipe")
    if not box or not box.shown:
        return failures
    p = box.point
    check(p[1] == "TOPLEFT" and p[3] == "TOPRIGHT" and p[4] == 38, f"box clear of the 34 px tabs: {p[4]}")
    rows = [box.rows[i] for i in range(1, len(box.rows) + 1)]
    check([r.name.text for r in rows] == ["Copper Rod", "Copper Bar", "Weak Flux"], "material names")
    check([r.count.text for r in rows] == ["x1", "x4", "x1"], "material counts")
    prices = [r.price.text for r in rows]
    check(prices == ["120c", "140c", "no AH price"], f"line prices (count x lowest), quiet when missing: {prices}")
    lines = [box.lines[i] for i in range(1, len(box.lines) + 1) if box.lines[i].shown]
    labels = [l.label.text for l in lines]
    check(labels == ["Materials", "Sells for"], f"no profit line while a material has no price: {labels}")
    check(box.note.shown and "1 material has no AH price" in box.note.text, "a quiet note says what is missing")

    # all priced: profit after the cut
    G.MOCK_PRICES[2880] = 10
    lua.eval("function(ns) ns.craftRefresh() end")(ns)
    lines = [box.lines[i] for i in range(1, len(box.lines) + 1) if box.lines[i].shown]
    labels = [l.label.text for l in lines]
    check(labels == ["Materials", "Sells for", "Profit after the 5% AH cut"], f"profit line: {labels}")
    check(lines[0].value.text == "270c" and lines[2].value.text == "585c", f"materials {lines[0].value.text}, profit {lines[2].value.text}")
    check(not box.note.shown, "no note when everything has a price")

    # the shopping list panel
    box.shop.scripts.OnClick(box.shop)
    L = G.EverlookAuctionsRecipeList
    check(L is not None and L.shown, "Shopping list opens the panel")
    lrows = [L.rows[i] for i in range(1, len(L.rows) + 1)]
    check([r.check.checked for r in lrows] == [False, True, True], "ticked when you have too few")
    check([r.buy.text for r in lrows] == ["0", "3", "1"], "amounts to buy")
    check([r.have.text for r in lrows] == ["1/1", "1/4", "0/1"], "have / need")
    check(L.recipe.text == "Runed Copper Rod", "recipe name")
    # 3 crafts
    L.crafts.text = "3"
    L.crafts.scripts.OnTextChanged(L.crafts, True)
    check([r.buy.text for r in lrows] == ["2", "11", "3"] and lrows[0].check.checked, "3 crafts")
    L.crafts.text = "1"
    L.crafts.scripts.OnTextChanged(L.crafts, True)
    # edit an amount and untick one
    lrows[1].buy.text = "5"
    lrows[1].buy.scripts.OnTextChanged(lrows[1].buy, True)
    lrows[2].check.checked = False
    lrows[2].check.scripts.OnClick(lrows[2].check)
    L.create.scripts.OnClick(L.create)
    lists = db.lists
    check(lists is not None and len(lists) == 1, "Create list saves one list")
    if lists and len(lists) == 1:
        l = lists[1]
        check(l.name == "Runed Copper Rod", "named after the recipe")
        check(len(l.queries) == 1 and l.queries[1] == 'name is "Copper Bar"' and l.want['name is "Copper Bar"'] == 5,
              "the ticked item with the edited amount")
        check(db.listSel == 1, "the new list is picked in the Shopping tab")
    check("Saved as" in L.status.text, f"status: {L.status.text}")
    L.create.scripts.OnClick(L.create)
    check(len(db.lists) == 1 and "Updated" in L.status.text, "pressing again updates the same list")
    keys = sorted(k for k in db.keys())
    check(keys == ["listSel", "lists"], f"nothing else saved: {keys}")
    return failures


def scroll_bars():
    """The scroll bar kit in Skin.lua: drag math, thumb size, and a list scrolled by its bar and the wheel."""
    lua = lua51.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(source_of("tests/mock.lua"))
    ns = lua.table()
    run = lua.eval("function(src, name, ...) local f = assert(loadstring(src, name)); return f(...) end")
    run(CRAFT_SETUP, "setup", ns)
    run(source_of("Skin.lua"), "Skin.lua", "EverlookDBAuctions", ns)
    UI = ns.UI
    failures = []

    def check(cond, what):
        if not cond:
            failures.append("scroll: " + what)

    check(UI.BAR_W >= 12, f"the bar is wide enough to grab: {UI.BAR_W}")
    # dragging: 100 px of room for a range of 50 rows; 30 px down from row 10 is row 25
    check(UI.scrollDrag(10, 30, 100, 50) == 25, "drag maps cursor travel to the range")
    check(UI.scrollDrag(0, 33.3, 100, 1000) == 333, "pixel scrolling lands on whole pixels")
    check(UI.scrollDrag(10, 500, 100, 50) == 50, "never past the end")
    check(UI.scrollDrag(10, -500, 100, 50) == 0, "never above the top")
    check(UI.scrollDrag(5, 10, 0, 50) == 0, "no room: no movement math")
    h, y = UI.scrollThumb(200, 0.05, 0, 100)
    check(h == 30 and y == 0, f"thumb never smaller than 30 px: {h}")
    h, y = UI.scrollThumb(200, 0.5, 100, 100)
    check(h == 100 and y == 100, f"thumb at the bottom at the end: {h}, {y}")
    h, _ = UI.scrollThumb(20, 0.1, 0, 10)
    check(h == 20, "thumb never taller than its track")

    # a list: 10 rows visible of 25 items; the wheel and the bar both scroll it, in whole rows
    L = lua.eval("""function(UI)
      local L = UI.list(UIParent, 20, function() return CreateFrame("Button") end, function() end)
      L.count = 10
      local items = {}
      for i = 1, 25 do items[i] = i end
      L:SetItems(items)
      return L
    end""")(UI)
    L.scripts.OnMouseWheel(L, -1)
    check(L.offset == 3, f"one wheel notch down scrolls 3 rows: {L.offset}")
    L.scripts.OnMouseWheel(L, -10)
    check(L.offset == 15, f"wheel stops at the last page: {L.offset}")
    L.bar.scripts.OnMouseWheel(L.bar, 2)
    check(L.offset == 9, f"the wheel over the bar scrolls too: {L.offset}")
    L.bar.thumb.b = 50
    G = lua.globals()
    G.GetCursorPosition = lua.eval("function() return 0, 10 end")
    L.bar.scripts.OnMouseDown(L.bar, "LeftButton")
    check(L.offset == 15, f"a click below the thumb jumps a page: {L.offset}")
    G.GetCursorPosition = lua.eval("function() return 0, 90 end")
    L.bar.scripts.OnMouseDown(L.bar, "LeftButton")
    check(L.offset == 6, f"a click above the thumb jumps a page back: {L.offset}")
    L.bar.scripts.OnMouseDown(L.bar, "RightButton")
    check(L.offset == 6, "only the left button pages")
    L.bar.thumb.scripts.OnMouseDown(L.bar.thumb, "RightButton")
    check(lua.eval("function(t) return rawget(t, 'drag') end")(L.bar.thumb) is None, "only the left button starts a drag")
    return failures


VENDOR_SETUP = """
local ns = ...
local db = {
  scans = { { realm = "Test", side = "Alliance", at = 0, rows = {
    ["2589:0"] = "10,10,12,400,9",   -- Linen Cloth: 10c each, vendor 13c, stacks of 20
    ["2592:0"] = "50,50,60,200,5",   -- Wool Cloth: 50c, vendor 33c
    ["1000:0"] = "1,1,1,5,1",        -- vendors don't buy it (sell price 0)
    ["5000:0"] = "5,5,5,3,1",        -- a quest item with a sell price
    ["3000:0"] = "100,100,150,1,1",  -- gear: 1s, vendor 5s
    ["4000:0"] = ",,,2,1",           -- bids only
    ["7001:0"] = "3000,3000,3500,2,2",  -- wands for the query language tests: 30s, req 20
    ["7002:0"] = "2000,2000,2500,1,1",  -- 20s, req 25
    ["7003:0"] = "900,900,1000,1,1",    -- 9s, req 35
  } } },
  itemInfo = {
    [2589] = { "Linen Cloth", 1, 5, 0, "Trade Goods", "Cloth", "", 1, 13, 20 },
    [2592] = { "Wool Cloth", 1, 15, 0, "Trade Goods", "Cloth", "", 1, 33, 20 },
    [1000] = { "Gift", 1, 1, 0, "Miscellaneous", "Junk", "", 1, 0, 1 },
    [5000] = { "Quest Thing", 1, 1, 0, "Quest", "Quest", "", 1, 50, 1 },
    [3000] = { "Old Sword", 2, 20, 15, "Weapon", "Swords", "INVTYPE_WEAPON", 1, 500, 1 },
    [4000] = { "Bid Only", 1, 1, 0, "Trade Goods", "Cloth", "", 1, 100, 1 },
    [7001] = { "Lesser Magic Wand", 2, 23, 20, "Weapon", "Wands", "INVTYPE_RANGEDRIGHT", 1, 200, 1 },
    [7002] = { "Sort Wand", 2, 30, 25, "Weapon", "Wands", "INVTYPE_RANGEDRIGHT", 1, 300, 1 },
    [7003] = { "Greater Magic Wand", 2, 40, 35, "Weapon", "Wands", "INVTYPE_RANGEDRIGHT", 1, 400, 1 },
  },
  itemStats = {},
}
ns.db = function() return db end
ns.house = function() return "Test-Alliance" end
ns.money = function(c) return tostring(c) .. "c" end
ns.num = function(n) return tostring(n) end
ns.ago = function() return "just now" end
ns.ok = function(v) return v end
ns.say = function() end
function GetRealmName() return "Test" end
function time() return 1000 end
function GetTime() return MOCK_NOW end
MOCK_NOW = 100
function strsplit(sep, s)
  local out, i = {}, 1
  while true do
    local j = s:find(sep, i, true)
    if not j then out[#out + 1] = s:sub(i); break end
    out[#out + 1] = s:sub(i, j - 1)
    i = j + 1
  end
  return unpack(out)
end
MOCK_CLASS = { [5000] = 12, [2589] = 7, [2592] = 7, [1000] = 15, [3000] = 2, [4000] = 7 }
C_Item.GetItemInfoInstant = function(id) return id, "", "", "", 1, MOCK_CLASS[id] end
C_Item.GetItemInfo = function(id) return nil end   -- nothing else is loaded
MOCK_LOADS = 0
C_Item.RequestLoadItemDataByID = function() MOCK_LOADS = MOCK_LOADS + 1 end
return db
"""


def below_vendor():
    """Below vendor price: the profit math, the search words, results over a fake scan, and loading item details."""
    lua = lua51.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(source_of("tests/mock.lua"))
    ns = lua.table()
    run = lua.eval("function(src, name, ...) local f = assert(loadstring(src, name)); return f(...) end")
    run(VENDOR_SETUP, "setup", ns)
    for name in ["Skin.lua", "Vendor.lua", "Search.lua"]:
        run(source_of(name), name, "EverlookDBAuctions", ns)
    V = ns.vendor
    G = lua.globals()
    failures = []

    def check(cond, what):
        if not cond:
            failures.append("vendor: " + what)

    # the price comparison and the profit math (vendors take no cut)
    check(V.profit(10, 13) == 3, "profit each: vendor price minus buyout")
    check(V.profit(50, 33) == -17, "negative when the auction costs more")
    check(V.below(10, 13) is True and V.below(13, 13) is False and V.below(50, 33) is False, "below means strictly cheaper")
    check(V.profit(10, 0) is None and V.below(1, 0) is False, "sell price 0: nothing to compare")
    check(V.profit(None, 13) is None and V.profit(0, 13) is None, "no buyout: nothing to compare")
    check(V.stackProfit(10, 13, 20) == 60, "a stack of 20 at 3c profit each is 60c")
    check(V.stackProfit(100, 500, 1) == 400 and V.stackProfit(100, 500, None) == 400, "gear: a stack of one")
    check(V.isQuest(5000) is True and V.isQuest(2589) is False, "quest items by item class")

    # search words
    P = ns.queryParse
    st = P("belowvendor")
    check(st.vendor is True and st[1].k == "where" and st[1].e.k == "below", "belowvendor on its own")
    check(P("undervendor").vendor is True, "undervendor means the same")
    st = P("price lt vendor")
    check(st.vendor is True and st[1].e.col == "price" and st[1].e["values"][1] == "vendor", "price lt vendor")
    check(P("price lt sell").vendor is True, "price lt sell")
    check(P("belowvendor and profit ge 1s | sort by stackprofit desc").vendor is True, "with profit and a sort")
    check(P("slot is trinket and price lt 5g").vendor is None, "a normal search is not a vendor search")
    check(P("name has belowvendor")[1].e.col == "name", "as a value it stays a name search")
    starters = ns.priceStarters
    for i in range(1, len(starters) + 1):
        okp, err = lua.eval("function(P, q) return pcall(P, q) end")(P, starters[i])
        check(okp is True, f"the Prices window's starting search parses: {starters[i]} ({err})")

    def names(text):
        rows, head, _missing, vendor = ns.queryRun(text)
        return [rows[i].name for i in range(1, len(rows) + 1)], head, vendor

    got, head, vendor = names("belowvendor")
    check(got == ["Old Sword", "Linen Cloth"], f"below vendor, biggest profit first: {got}")
    check(vendor is True, "results say they are a vendor search")
    check("Gift" not in got and "Quest Thing" not in got and "Bid Only" not in got,
          "no sell price, quest items and bids-only never count")
    got, _, _ = names("price lt vendor")
    check(got == ["Old Sword", "Linen Cloth"], f"price lt vendor: the same, by profit: {got}")
    got, _, _ = names("belowvendor | sort by price")
    check(got == ["Linen Cloth", "Old Sword"], f"its own sort wins: {got}")
    got, _, _ = names("belowvendor and profit lt 1s")
    check(got == ["Linen Cloth"], f"profit as a column: {got}")
    got, _, _ = names("belowvendor | sort by stackprofit desc")
    check(got == ["Old Sword", "Linen Cloth"], f"stack profit 400c vs 60c: {got}")
    got, _, _ = names("not belowvendor and category is \"Trade Goods\" | sort by name")
    check(got == ["Bid Only", "Wool Cloth"], f"not belowvendor: {got}")
    _, _, vendor = names("slot is onehand")
    check(vendor is False, "a normal search has the normal columns")

    # an item whose details aren't loaded: not marked, asked for once, not again within 30 s
    check(V.flip(6000, 1) is None and G.MOCK_LOADS == 1, "unknown item: asked for its details once")
    V.flip(6000, 1)
    V.sellOf(6000)
    check(G.MOCK_LOADS == 1, "not asked again right away")
    G.MOCK_NOW = 200
    V.sellOf(6000)
    check(G.MOCK_LOADS == 2, "asked again after 30 seconds")
    check(V.flip(2589, 10) == 3 and V.flip(2589, 13) is None, "flip: profit when below, nothing when not")
    check(V.flip(1000, 0) is None and V.flip(1000, 1) is None, "flip: sell price 0 never counts")
    check(V.flip(5000, 5) is None, "flip: quest items never count")
    return failures


def query_language():
    """The query language: steps without |, sort without a column, aliases, errors that say what's missing, and the
    query box's line breaks."""
    lua = lua51.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(source_of("tests/mock.lua"))
    ns = lua.table()
    run = lua.eval("function(src, name, ...) local f = assert(loadstring(src, name)); return f(...) end")
    run(VENDOR_SETUP, "setup", ns)
    for name in ["Skin.lua", "Vendor.lua", "Search.lua"]:
        run(source_of(name), name, "EverlookDBAuctions", ns)
    P = ns.queryParse
    perr = lua.eval("function(P, t) local ok, e = pcall(P, t); if ok then return nil end; "
                    "return type(e) == 'table' and e.query or tostring(e) end")
    failures = []

    def check(cond, what):
        if not cond:
            failures.append("query: " + what)

    def kinds(text):
        st = P(text)
        return [st[i].k for i in range(1, len(st) + 1)]

    def names(text):
        rows, head, _m, _v = ns.queryRun(text)
        if rows is None:
            return head
        return [rows[i].name for i in range(1, len(rows) + 1)]

    # steps without a |
    check(kinds("type has wand and reqlevel le 29 sort by price") == ["where", "sort"], "sort without |")
    check(kinds("type has wand sort by price desc top 2 by ilvl count") == ["where", "sort", "top", "count"],
          "several steps without |")
    check(kinds("type has wand and sort by price") == ["where", "sort"], "and leading into a step")
    check(kinds("type has wand | sort by price | top 2") == ["where", "sort", "top"], "| still works")
    check(kinds("items | where type has wand | sort by price") == ["where", "sort"], "items | where still works")
    check(kinds("where type has wand sort by price") == ["where", "sort"], "a where in front")
    check(kinds("sort by price") == ["sort"], "a sort on its own")
    check(kinds("top 5 by ilvl") == ["top"], "a top on its own")
    got = names("type has wand and reqlevel le 29 sort by price")
    check(got == ["Sort Wand", "Lesser Magic Wand"], f"wands up to 29, cheapest first: {got}")
    check(names("type has wand sort by ilvl desc top 2") == ["Greater Magic Wand", "Sort Wand"], "sort then top")
    check(names("type has wand count") == [], "count gives no rows")

    # step words as values or columns stay what they were
    st = P("name has sort")
    check(len(st) == 1 and st[1].e.col == "name" and st[1].e["values"][1] == "sort", "name has sort is a comparison")
    check(names("name has sort") == ["Sort Wand"], "name has sort finds the Sort Wand")
    st = P("name has sort sort by price")
    check([st[i].k for i in range(1, len(st) + 1)] == ["where", "sort"] and st[1].e["values"][1] == "sort",
          "name has sort, then a sort step")
    st = P("type has wand and count gt 1")
    check(len(st) == 1 and st[1].e.b.col == "qty", "count gt 1 is a comparison on qty")
    check(P("type has wand sort by count")[2]["keys"][1].col == "qty", "sort by count sorts by qty")
    st = P("spinning top")
    check(len(st) == 1 and st[1].e.k == "and", "top without a number is a name word")

    # sort without a column: by price
    for q, desc in [("type has wand sort", False), ("type has wand sort asc", False), ("type has wand sort desc", True),
                    ("type has wand sort by asc", False), ("type has wand sort by desc", True),
                    ("type has wand | sort desc", True), ("type has wand sort by", False)]:
        k = P(q)[2]["keys"][1]
        check(k.col == "price" and k.desc is desc, f"{q}: by price, desc={desc}")
    check(P("type has wand sort desc top 1")[3].k == "top", "sort desc, then top")
    check(P("type has wand top 2")[2]["keys"] is None, "top without by stays unsorted")

    # the owner's query: parses and runs
    owner = "type has wand and reqlvl le 29 sort asc"
    check(names(owner) == ["Sort Wand", "Lesser Magic Wand"], f"{owner}: {names(owner)}")
    check(names("type has wand and reqlvl le 29 sort desc") == ["Lesser Magic Wand", "Sort Wand"], "sort desc")

    # aliases
    for a in ["lvlreq", "levelreq", "reqlvl", "lvl"]:
        check(P(f"{a} le 29")[1].e.col == "reqlevel", f"{a} means reqlevel")
    check(names("wand and lvlreq le 29 sort by price") == ["Sort Wand", "Lesser Magic Wand"], "lvlreq runs")

    # errors say what is missing, with an example
    for q, want in [("reqlvl le", "reqlvl le what? e.g. reqlvl le 29"),
                    ("price lt", "price lt what? e.g. price lt 5g"),
                    ("slot is", "slot is what? e.g. slot is trinket"),
                    ("reqlvl", None),   # a lone column word searches names
                    ("ilvl between", "ilvl between what? e.g. ilvl between (20 .. 30)"),
                    ("type has wand sort by price,", "sort by which column?"),
                    ("type has wand sort by flavour", "can't sort by flavour"),
                    ("type has wand top 2 by", "top 2 by which column? e.g. top 2 by sta"),
                    ("type has wand and", "something is missing after and; e.g."),
                    ("(type has wand", "a ) is missing; e.g."),
                    ("type has wand )", "not sure what ) means here; e.g."),
                    ("type has wand |", "a step is missing after |; e.g. | sort by price")]:
        got = perr(P, q)
        if want is None:
            check(got is None, f"{q!r} parses: {got}")
        else:
            check(got is not None and want in got, f"{q!r}: {got}")
    for q in ["reqlvl le", "type has wand sort by price,", "type has wand and", "price lt", "slot in"]:
        got = perr(P, q) or ""
        check("e.g." in got and "a value is missing" not in got, f"{q!r} gives an example: {got}")

    # the query box: line breaks become spaces; Enter does not break the line
    one = ns.UI.oneLine
    check(one("type has wand\nand reqlevel le 29\r\nsort by price") == "type has wand and reqlevel le 29 sort by price",
          "pasted line breaks become spaces")
    check(one("type has wand\n") == "type has wand" and one("wand") == "wand", "a break at the end goes")
    check(names("type has wand\nand reqlevel le 29\nsort by price") == ["Sort Wand", "Lesser Magic Wand"],
          "a search with line breaks runs")
    opts = lua.eval("{ lines = 2, onEnter = function(e) ENTERED = (ENTERED or 0) + 1 end }")
    box = ns.UI.input(lua.globals().UIParent, 100, 40, opts)
    same = lua.eval("rawequal")
    check(box.edbWell is not None and not same(box.edbWell, box), "a two-line box has its own well to anchor")
    single = ns.UI.input(lua.globals().UIParent, 100, 24)
    check(same(single.edbWell, single), "a one-line box is its own well")
    return failures


QUEUE_SETUP = """
NOW = 0
TIMERS = {}
C_Timer = { After = function(s, fn) TIMERS[#TIMERS + 1] = { at = NOW + s, fn = fn } end }
function GetTime() return NOW end
function advance(s)
  local stop = NOW + s
  while true do
    local best
    for i, t in ipairs(TIMERS) do if t.at <= stop and (not best or t.at < TIMERS[best].at) then best = i end end
    if not best then break end
    local t = table.remove(TIMERS, best)
    if t.at > NOW then NOW = t.at end
    t.fn()
  end
  NOW = stop
end
SENT = {}
READY = true
BROWSE = { results = {}, full = true }
KEYNAMES = {}
ITEMFULL = true
local function key(id, suffix) return { itemID = id, itemLevel = 22, itemSuffix = suffix or 0, battlePetSpeciesID = 0 } end
KEY = key
C_AuctionHouse = {
  IsThrottledMessageSystemReady = function() return READY end,
  SendBrowseQuery = function(q) SENT[#SENT + 1] = { kind = "browse", text = q.searchString } end,
  SendSearchQuery = function(k) SENT[#SENT + 1] = { kind = "items", key = k } end,
  GetBrowseResults = function() return BROWSE.results end,
  HasFullBrowseResults = function() return BROWSE.full end,
  RequestMoreBrowseResults = function() SENT[#SENT + 1] = { kind = "more" } end,
  HasFullItemSearchResults = function() return ITEMFULL end,
  RequestMoreItemSearchResults = function() SENT[#SENT + 1] = { kind = "moreitems" } end,
  GetItemKeyInfo = function(k) local n = KEYNAMES[k.itemSuffix or 0]; return n and { itemName = n } or nil end,
}
"""


def search_queue():
    """The shared search queue (AHQuery.lua): one at a time, answers matched to the search, no answer is never zero,
    nobody selling only from a complete answer, and the right ItemKeys for random-stat versions."""
    lua = lua51.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(source_of("tests/mock.lua"))
    lua.execute(QUEUE_SETUP)
    ns = lua.table()
    run = lua.eval("function(src, name, ...) local f = assert(loadstring(src, name)); return f(...) end")
    run(source_of("AHQuery.lua"), "AHQuery.lua", "EverlookDBAuctions", ns)
    Q = ns.ahq
    G = lua.globals()
    failures = []

    def check(cond, what):
        if not cond:
            failures.append("queue: " + what)

    def sent():
        return [(G.SENT[i].kind, G.SENT[i].text) for i in range(1, len(G.SENT) + 1)]

    def reset():
        G.advance(0.5)   # let the queue settle
        G.SENT = lua.table()

    key = G.KEY
    results = lua.eval("function(...) return { ... } end")
    entry = lua.eval("function(k, p, q) return { itemKey = k, minPrice = p, totalQuantity = q } end")
    answers = []

    def cb(a):
        answers.append(a)

    # order: a front search goes before waiting background ones; one at a time
    reset()
    G.READY = False
    Q.browse("Background", 1, lua.table(owner="live", background=True), cb)
    Q.browse("Front", 2, lua.table(owner="buy", front=True), cb)
    check(sent() == [], "nothing sent while the auction house isn't ready")
    G.READY = True
    G.advance(0.5)
    check(sent() == [("browse", "Front")], f"front first, one at a time: {sent()}")
    G.BROWSE = lua.eval("{ results = {}, full = true }")
    G.BROWSE.results = results(entry(key(2), 100, 3))
    Q.onEvent("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
    check(len(answers) == 1 and answers[0].ok and len(answers[0].entries) == 1, "front answered")
    G.advance(0.2)
    check(sent()[-1] == ("browse", "Background"), f"then the background one: {sent()}")
    G.BROWSE.results = results(entry(key(1), 50, 1))
    Q.onEvent("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
    check(len(answers) == 2, "background answered")

    # background searches wait while the buy panel is open
    reset()
    answers.clear()
    ns.buyOpen = True
    Q.browse("Bg", 3, lua.table(owner="live", background=True), cb)
    G.advance(2)
    check(sent() == [], "no background search while buying")
    ns.buyOpen = False
    G.advance(1)
    check(sent() == [("browse", "Bg")], f"sent once the buy panel closes: {sent()}")
    G.BROWSE.results = results()
    Q.onEvent("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
    G.advance(1)

    # background searches wait while an item sits on Blizzard's Sell tab, and nothing is sent just after a post
    reset()
    answers.clear()
    lua.execute("""
      local function shown(on) return { IsShown = function() return on end, IsVisible = function() return on end } end
      SELL_ITEM = { bagID = 0, slotIndex = 1 }
      AuctionHouseFrame = shown(true)
      AuctionHouseFrame.ItemSellFrame = shown(true)
      AuctionHouseFrame.ItemSellFrame.GetItem = function() return SELL_ITEM end
    """)
    Q.browse("WhileSelling", 4, lua.table(owner="live", background=True), cb)
    G.advance(2)
    check(sent() == [], f"no background search while an item is on the Sell tab: {sent()}")
    lua.execute("SELL_ITEM = nil")
    G.advance(1)
    check(sent() == [("browse", "WhileSelling")], f"sent once the Sell tab is empty: {sent()}")
    G.BROWSE.results = results()
    Q.onEvent("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
    G.advance(1)
    reset()
    Q.holdForPost(4)
    Q.browse("AfterPost", 5, lua.table(owner="buy", front=True), cb)
    G.advance(2)
    check(sent() == [], f"nothing sent right after a post: {sent()}")
    G.advance(3)
    check(sent() == [("browse", "AfterPost")], f"sent once the post had its moment: {sent()}")
    G.BROWSE.results = results()
    Q.onEvent("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
    G.advance(1)
    lua.execute("AuctionHouseFrame = nil")

    # an answer for another ItemKey is ignored, not read as empty
    reset()
    got = []
    k1, k2 = key(10, 5), key(10, 6)
    Q["items"](k1, lua.table(owner="buy", front=True), lambda k, full, final: got.append((k.itemSuffix, full, final)))
    G.advance(0.1)
    check(sent() == [("items", None)] and G.SENT[1].key.itemSuffix == 5, "item search sent for its key")
    Q.onEvent("ITEM_SEARCH_RESULTS_UPDATED", k2)
    check(got == [] and Q.busy is not None, "results for another key ignored, still waiting")
    Q.onEvent("ITEM_SEARCH_RESULTS_UPDATED", key(10, 5))
    check(got == [(5, True, True)] and Q.busy is None, f"its own key's results taken: {got}")

    # no answer: asked again with a pause, and in the end "no answer", never an empty list
    reset()
    answers.clear()
    retries = []
    Q.browse("Silent", 4, lua.table(owner="buy", front=True, onRetry=lambda n: retries.append(n)), cb)
    G.advance(0.1)
    G.advance(5.1)
    check(retries == [1] and answers == [], f"first timeout: retry, no answer yet: {retries}")
    G.advance(30)
    check(len([x for x in sent() if x[0] == "browse"]) == 3, f"asked three times: {sent()}")
    check(len(answers) == 1 and answers[0].ok is False, "then told no answer")
    check(not any(a.ok for a in answers), "never an empty answer from a timeout")

    # nobody selling only from a complete answer; an empty one is asked once more first
    reset()
    answers.clear()
    G.BROWSE.results = results(entry(key(99), 5, 1))   # other items only
    G.BROWSE.full = False
    Q.browse("Partial", 5, lua.table(owner="buy", front=True, confirmEmpty=True), cb)
    G.advance(0.1)
    for _ in range(9):
        Q.onEvent("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
    check(len(answers) == 1 and answers[0].full is False and len(answers[0].entries) == 0, "incomplete: not full")
    check(len([x for x in sent() if x[0] == "more"]) == 8, f"asked for more pages: {sent()}")
    live = Q.liveFromBrowse(results(lua.table(name="Partial", suffix=0)), answers[0], Q.nameOf)
    check(live[1] is None, "incomplete and empty: not sold out")
    reset()
    answers.clear()
    G.BROWSE.full = True
    Q.browse("Gone", 6, lua.table(owner="buy", front=True, confirmEmpty=True), cb)
    G.advance(0.1)
    Q.onEvent("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
    check(answers == [], "complete and empty: asked once more first")
    G.advance(0.2)
    Q.onEvent("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
    check(len(answers) == 1 and answers[0].full is True and len(answers[0].entries) == 0, "then believed")
    live = Q.liveFromBrowse(results(lua.table(name="Gone", suffix=0)), answers[0], Q.nameOf)
    check(live[1].gone is True, "complete and empty: sold out")
    fail = Q.liveFromBrowse(results(lua.table(name="X", suffix=0)), lua.table(ok=False), Q.nameOf)
    check(fail[1] is None, "no answer: not sold out")

    # Blizzard's own search: our browse goes back in the queue, their answer isn't read as ours
    reset()
    answers.clear()
    G.BROWSE.results = results()
    Q.browse("Ours", 7, lua.table(owner="buy", front=True), cb)
    G.advance(0.1)
    Q.blizzardSearch(True)
    Q.onEvent("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")   # Blizzard's answer
    check(answers == [], "Blizzard's answer not taken as ours")
    G.advance(1)
    check([x for x in sent() if x[0] == "browse"] == [("browse", "Ours"), ("browse", "Ours")], f"ours sent again: {sent()}")
    G.BROWSE.results = results(entry(key(7), 10, 2))
    Q.onEvent("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
    check(len(answers) == 1 and len(answers[0].entries) == 1, "then ours answered")

    # waiting for idle (Blizzard's list): runs once nothing is out
    reset()
    ran = []
    Q["items"](key(20), lua.table(owner="buy", front=True), lambda *a: None)
    G.advance(0.1)
    Q.whenIdle(lambda: ran.append(G.NOW))
    G.advance(0.5)
    check(ran == [], "not while a search is out")
    Q.onEvent("ITEM_SEARCH_RESULTS_UPDATED", key(20))
    G.advance(0.5)
    check(len(ran) == 1, "runs when idle")

    # which ItemKeys to open: the version named like the result, else all of them
    G.KEYNAMES = lua.eval('{ [5] = "Dwarven Magestaff of the Bear", [6] = "Dwarven Magestaff of the Eagle" }')
    es = results(entry(key(30, 5), 4400, 7), entry(key(30, 6), 4400, 5))
    keys, all_, _every = Q.pickKeys(es, "Dwarven Magestaff of the Bear", Q.nameOf)
    check(len(keys) == 1 and keys[1].itemSuffix == 5 and all_ is False, "the Bear version's key")
    keys, all_, _every = Q.pickKeys(es, "Dwarven Magestaff of the Owl", Q.nameOf)
    check(len(keys) == 2 and all_ is True, "no match: every version, shown with names")
    # only one other version up: still named, never listed as the wanted one (audit 2026-11-19)
    r = Q.pickKeys(results(entry(key(30, 6), 4400, 5)), "Dwarven Magestaff of the Bear", Q.nameOf)
    r = r if isinstance(r, tuple) else (r,)
    check(len(r) > 1 and r[1] is True, "one other version: shown with its name")
    G.KEYNAMES = lua.eval('{ [0] = "Linen Cloth" }')
    keys, all_, _every = Q.pickKeys(results(entry(key(2589), 10, 20)), "Linen Cloth", Q.nameOf)
    check(len(keys) == 1 and all_ is False, "a plain item: its one key")

    # live prices for random-stat versions: by name; a version not in a complete answer is sold out, an unnamed
    # key makes it unknown
    G.KEYNAMES = lua.eval('{ [5] = "Dwarven Magestaff of the Bear", [6] = "Dwarven Magestaff of the Eagle" }')
    rows = results(lua.table(name="Dwarven Magestaff of the Bear", suffix=5),
                   lua.table(name="Dwarven Magestaff of the Owl", suffix=9))
    ans = lua.table(ok=True, full=True, entries=es)
    out = Q.liveFromBrowse(rows, ans, Q.nameOf)
    check(out[1].price == 4400 and out[1].qty == 7, "Bear: its own price and count")
    check(out[2].gone is True, "Owl: not in a complete answer, sold out")
    ans.full = False
    out = Q.liveFromBrowse(rows, ans, Q.nameOf)
    check(out[2] is None, "Owl with an incomplete answer: unknown")
    G.KEYNAMES = lua.eval('{ [5] = "Dwarven Magestaff of the Bear" }')
    ans.full = True
    out = Q.liveFromBrowse(rows, ans, Q.nameOf)
    check(out[1].price == 4400 and out[2] is None, "a key without a name yet: no sold out")
    return failures


def undercut():
    """The undercut: copper steps where the auction house takes copper (items and stackable goods alike), whole
    silver where it doesn't, and what /eah undercut says."""
    failures = []

    def check(cond, what):
        if not cond:
            failures.append("undercut: " + what)

    for copper in (True, False):
        lua = lua51.LuaRuntime(unpack_returned_tuples=True)
        lua.execute(source_of("tests/mock.lua"))
        lua.execute("C_AuctionHouse = { SupportsCopperValues = function() return %s end }" % ("true" if copper else "false"))
        ns = lua.table()
        run = lua.eval("function(src, name, ...) local f = assert(loadstring(src, name)); return f(...) end")
        run(CRAFT_SETUP, "setup", ns)
        said = []
        ns.say = lambda m: said.append(m)
        for name in ["Skin.lua", "Sell.lua"]:
            run(source_of(name), name, "EverlookDBAuctions", ns)
        check(ns.setUndercut("1c") is True, "1c is accepted")
        item = 44 * 100 + 14     # an item auction at 44s 14c
        goods = 5 * 100 + 50     # a stackable good at 5s 50c each
        if copper:
            check(ns.undercutPrice(item) == item - 1, f"item: 1c under 44s14c is 44s13c, got {ns.undercutPrice(item)}")
            check(ns.undercutPrice(goods) == goods - 1, "stackable good: 1c under too")
            check(ns.undercutPrice(1) == 1, "never below 1c")
            ns.setUndercut("1s")
            check(ns.undercutPrice(80) == 79, f"1s under 80c is 79c, not 1c: got {ns.undercutPrice(80)}")
            check(ns.undercutPrice(101) == 100, f"1s under 1s 1c is 1s: got {ns.undercutPrice(101)}")
            check(ns.undercutPrice(150) == 149, f"1s under 1s 50c is 1s 49c: got {ns.undercutPrice(150)}")
            check(ns.undercutPrice(100000) == 99900, f"1s under 10g is 9g 99s: got {ns.undercutPrice(100000)}")
            ns.setUndercut("5%")
            check(ns.undercutPrice(10000) == 9500, "5% of 1g")
        else:
            check(ns.undercutPrice(item) == 4400, f"whole silver only: 44s, got {ns.undercutPrice(item)}")
            check(ns.undercutPrice(4400) == 4300, "from a whole-silver price: a silver less")
        ns.setUndercut("1c")
        ns.slash("undercut 1c")
        check(said and said[-1].startswith("undercut set to 1c"), f"confirmed in chat with the new value: {said}")
        if copper:
            check("whole silver" not in said[-1], f"no rounding note where copper works: {said[-1]}")
        else:
            check("whole silver" in said[-1], f"says it rounds to silver: {said[-1]}")
        ns.slash("undercut banana")
        check("isn't an undercut" in said[-1] and "for example" in said[-1], f"a wrong value gets an example: {said[-1]}")
        printed = []
        lua.globals().print = lambda *a: printed.append(" ".join(str(x) for x in a))
        ns.help()
        for line in printed:
            bad = [i for i, ch in enumerate(line) if ch == "|" and not line[i + 1:i + 2] in ("c", "r", "|")]
            check(not bad, f"help line without a stray |: {line}")
    return failures


def deals():
    """Below vendor from the scan's single auctions: the list built when the scan finishes, the 10s threshold, and
    Start buying's order and running total."""
    lua = lua51.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(source_of("tests/mock.lua"))
    ns = lua.table()
    run = lua.eval("function(src, name, ...) local f = assert(loadstring(src, name)); return f(...) end")
    run(VENDOR_SETUP, "setup", ns)
    for name in ["Skin.lua", "Vendor.lua", "Search.lua"]:
        run(source_of(name), name, "EverlookDBAuctions", ns)
    V = ns.vendor
    tbl = lua.eval("function(...) return { ... } end")
    failures = []

    def check(cond, what):
        if not cond:
            failures.append("deals: " + what)

    # built at scan time: each auction under vendor price, kept per item version
    check(V.scanDeals(2589, tbl(10, 12, 13, 20), tbl(20, 5, 1, 1)) == "10:20,12:5", "Linen Cloth: the two under 13c")
    check(V.scanDeals(2592, tbl(50), tbl(1)) is None, "nothing under vendor price: nothing saved")
    check(V.scanDeals(5000, tbl(1), tbl(1)) is None, "quest items never count")
    check(V.scanDeals(1000, tbl(1), tbl(1)) is None, "sell price 0 never counts")
    pend = V.scanDeals(424242, tbl(9, 3, 7), tbl(1, 2, 3))
    check(pend == "?3:2,7:3,9:1", f"details not loaded: the cheapest kept to check later: {pend}")

    # the threshold: at least 10s for the whole auction, unless the search names profit
    lst = V.dealsOf("100:1,4000:2,9500:1", 10000, V.MIN_DEAL)
    got = [(lst[i].unit, lst[i].count, lst[i].profit) for i in range(1, len(lst) + 1)]
    check(got == [(4000, 2, 12000), (100, 1, 9900)], f"9500 makes 5s: dropped; biggest profit first: {got}")
    lst = V.dealsOf("100:1,4000:2,9500:1", 10000, 0)
    check(len(lst) == 3, "threshold 0 keeps every deal")
    check(len(V.dealsOf("?3:2,7:3", 10, 0)) == 2, "a pending list counts once the vendor price is known")
    n, total, best, _units = V.dealSummary(V.dealsOf("100:1,4000:2", 10000, 0))
    check(n == 2 and total == 9900 + 12000 and best == 100, "summary: count, total, cheapest")

    # the list over a scan with deals: no live check, biggest total first, threshold
    db = ns.db()
    sc = db.scans[1]
    sc.deals = lua.eval('{ ["3000:0"] = "100:3", ["2589:0"] = "10:20,12:5" }')
    # Old Sword 1s each vs 5s vendor, a stack of 3 in one auction: 12s; Linen 3c*20 + 1c*5 = 65c
    rows, head, _m, vendor = ns.queryRun("belowvendor")
    got = [rows[i].name for i in range(1, len(rows) + 1)]
    check(got == ["Old Sword"], f"only deals making 10s or more: {got}")
    check(vendor is True and "full scan" in head, "a below-vendor list from the scan")
    rows, *_ = ns.queryRun("belowvendor and profit ge 1c")
    got = [rows[i].name for i in range(1, len(rows) + 1)]
    check(got == ["Old Sword", "Linen Cloth"], f"with profit named: every deal, biggest total first: {got}")
    check(len(rows) == 2 and rows[1].dealN == 1 and rows[1].dealProfit == 1200, "Old Sword: one auction, 12s")
    check(len(rows) == 2 and rows[2].dealN == 2 and rows[2].dealProfit == 65, "Linen: two auctions, 65c")

    # Start buying: the next auction to buy, and the running total
    live = tbl(lua.table(unit=5, buyout=5, qty=1, mine=True), lua.table(unit=8, buyout=80, qty=10),
               lua.table(unit=9, buyout=9, qty=1), lua.table(unit=20, buyout=20, qty=1))
    pick = V.nextDeal(live, 13, False)
    check(pick is not None and pick.unit == 8, "the cheapest under vendor price that isn't yours")
    check(V.nextDeal(tbl(lua.table(unit=20, buyout=20, qty=1)), 13, False) is None, "none under vendor price: nothing")
    goods = tbl(lua.table(unit=10, qty=20, others=15), lua.table(unit=12, qty=5, others=5), lua.table(unit=30, qty=9, others=9))
    pick = V.nextDeal(goods, 13, True)
    check(pick.qty == 20 and pick.cost == 15 * 10 + 5 * 12, "stackable goods: how many under vendor price and the cost")
    t = V.tally(None, 10, 80, 13)
    t = V.tally(t, 1, 9, 13)
    check(t.n == 11 and t.cost == 89 and t.value == 143, "running total")
    txt = V.tallyText(t, ns.money)
    check(txt == "Bought 11 for 89c, vendor value 143c, profit 54c.", txt)
    return failures


def core_and_lists():
    """Helper 4's audit: the tooltip's auction line never passes an old or bid-only price off as current, day lows
    are cut at load, chat echoes escape |, Shopping's click-to-change edits in place, /eah run explains itself, tags
    widen to fit, idle scroll bars do no per-frame work, the crafting box ages its prices and follows bag changes,
    and /eah says when the options can't open."""
    failures = []

    def check(cond, what):
        if not cond:
            failures.append("core/lists: " + what)

    def fresh_lua():
        lua = lua51.LuaRuntime(unpack_returned_tuples=True)
        lua.execute(source_of("tests/mock.lua"))
        run = lua.eval("function(src, name, ...) local f = assert(loadstring(src, name)); return f(...) end")
        return lua, run

    def load(run, ns, *names):
        for name in names:
            run(source_of(name), name, "EverlookDBAuctions", ns)

    # --- the core: tooltip lines, pruning at load, the unknown-command echo
    lua, run = fresh_lua()
    lua.execute(CORE_SETUP)
    ns = lua.table()
    load(run, ns, "EverlookDBAuctions.lua")
    fire = lua.eval("function(e, a) for _, f in ipairs(MOCK_FRAMES) do if f.scripts.OnEvent then f.scripts.OnEvent(f, e, a) end end end")
    fire("ADDON_LOADED", "EverlookDBAuctions")
    G = lua.globals()
    days = G.EverlookAuctionsDB.houses["Test-Alliance"].days
    check(days[2592] is None, "day lows older than 30 days are cut at load")
    check(days[2589] is not None and days[2589][10] is None and days[2589][99] == 7, "a recent day low stays")

    now = 100 * 86400
    line = ns.auctionLine
    left, note, price, fresh, word = line("Auction house", "", lua.table(None, 4, 2, now), None, now - 3600, now, now)
    check(price is None and "bids only" in note and "4 listed" in note and word == "no buyout",
          f"bid-only auctions aren't 'none listed': {note} / {word}")
    left, note, price, fresh, word = line("Auction house", "", None, None, now - 7200, now, now)
    check(price is None and word == "none listed" and "2 h ago" in note, f"'none listed' says how old the scan is: {note}")
    left, note, price, fresh, word = line("Auction house", "", lua.table(500, 3, 1, now - 2 * 86400), None, None, now, now)
    check(price == 500 and fresh is False and "2 days ago" in note, f"an old price is marked old: {note}")
    row = lua.table(low=900, qty=2, at=now - 60)
    left, note, price, fresh, word = line("Auction house", " x20", lua.table(500, 3, 1, now), row, None, now, now)
    check(price == 900 and fresh and "this version" in note and left == "Auction house x20", f"random-stat version priced: {left} {note}")
    left, note, price, fresh, word = line("Auction house", "", lua.table(500, 3, 1, now), False, None, now, now)
    check(price == 500 and "any version" in note, f"a version missing from the scan says it's any version's: {note}")
    check("(" not in left + note, "no brackets in the auction line")
    check(line("Auction house", " x20", None, None, None, now, now) is None, "nothing known: no line")

    G.PRINTED = lua.table()
    G.SlashCmdList.EVERLOOKAUCTIONS("foo|bar")
    out = G.PRINTED[1] or ""
    check("foo||bar" in out, f"an unknown command is echoed with | escaped: {out}")

    # --- Skin: tags widen to fit, scroll bars idle without OnUpdate
    lua, run = fresh_lua()
    ns = lua.table()
    run(VENDOR_SETUP, "setup", ns)
    load(run, ns, "Skin.lua")
    UI = ns.UI
    badge = lua.eval("""function(UI)
      local b = UI.badge(UIParent, 60, 16)
      function b:SetWidth(w) self.w = w end
      return b
    end""")(UI)
    badge.EdbSet(badge, "Sold")
    check(badge.w == 60, f"a short text keeps the tag's width: {badge.w}")
    badge.text.GetStringWidth = lua.eval("function() return 101 end")
    badge.EdbSet(badge, "vendor +1g 23s 45c")
    check(badge.w == 111, f"a long text widens the tag to fit: {badge.w}")
    L = lua.eval("""function(UI)
      return UI.list(UIParent, 20, function() return CreateFrame("Button") end, function() end)
    end""")(UI)
    thumb = L.bar.thumb
    check(thumb.scripts.OnUpdate is None, "an idle scroll thumb has no OnUpdate")
    lua.globals().GetCursorPosition = lua.eval("function() return 0, 10 end")
    thumb.scripts.OnMouseDown(thumb, "LeftButton")
    check(thumb.scripts.OnUpdate is not None, "dragging follows the cursor")
    thumb.scripts.OnMouseUp(thumb)
    check(thumb.scripts.OnUpdate is None, "letting go stops the per-frame work")

    # --- Shopping: click-to-change edits in place, /eah run explains itself
    said = []
    ns.say = lambda m: said.append(m)
    load(run, ns, "Shopping.lua")
    store = ns.shoppingStore
    lst = lua.eval('{ name = "Mats", queries = { "a", "b" }, want = { b = 4 } }')
    check(store(lst, "c", None) == "added" and lst.queries[3] == "c", "a new search is added")
    check(store(lst, "a", None) == "same" and len(lst.queries) == 3, "a search already there isn't added twice")
    check(store(lst, "b2", lua.table(list=lst, query="b")) == "saved" and lst.queries[2] == "b2" and len(lst.queries) == 3,
          "a clicked search is changed in place, not added")
    check(lst.want["b2"] == 4 and lst.want["b"] is None, "its amount to buy moves with it")
    check(store(lst, "a", lua.table(list=lst, query="c")) == "same" and lst.queries[3] == "c",
          "changing a search into one already there leaves both alone")
    check(store(lst, "", None) is None, "nothing typed: nothing stored")
    db = ns.db()
    db.lists = lua.eval('{ { name = "Herbs", queries = { "x" } } }')
    lua.globals().AuctionHouseFrame = None
    ns.slash("run herbs")
    check(said and "open the auction house first" in said[-1], f"/eah run with the auction house closed: {said[-1:]}")
    lua.execute("AuctionHouseFrame = CreateFrame('Frame', 'AuctionHouseFrame')")
    ns.slash("run h|erbs")
    check("h||erbs" in said[-1] and "lists: herbs" in said[-1] and "for example" in said[-1].lower(),
          f"an unknown list names the lists, with an example, | escaped: {said[-1]}")

    # --- Crafting: price ages, bag changes
    lua, run = fresh_lua()
    lua.execute("MOCK_TIME = 10 * 86400; function time() return MOCK_TIME end; MOCK_SEEN = {}")
    ns = lua.table()
    run(CRAFT_SETUP, "setup", ns)
    ns.itemFor = lua.eval("function(id) local p = MOCK_PRICES[id]; return p and { p, 1, 1, MOCK_SEEN[id] or MOCK_TIME } end")
    ns.ago = lua.eval("function(t) return (MOCK_TIME - t) .. ' s ago' end")
    load(run, ns, "RecipeList.lua", "Crafting.lua")
    fire = lua.eval("function(e, a) for _, f in ipairs(MOCK_FRAMES) do if f.scripts.OnEvent then f.scripts.OnEvent(f, e, a) end end end")
    fire("ADDON_LOADED", "Blizzard_Professions")
    fire("TRADE_SKILL_SHOW")
    G = lua.globals()
    box = G.EverlookAuctionsCrafting
    check(box.sub.text == "AH prices, oldest 0 s ago", f"the box says how old its prices are: {box.sub.text}")
    G.MOCK_SEEN[2840] = 10 * 86400 - 2 * 86400
    lua.eval("function(ns) ns.craftRefresh() end")(ns)
    check(box.sub.text == "AH prices, oldest 172800 s ago", f"the oldest price used: {box.sub.text}")
    rows = [box.rows[i] for i in range(1, len(box.rows) + 1)]
    check(rows[1].price.color[1] == 0.5 and rows[0].price.color[1] == 1, "a price over a day old is grey, a new one white")
    box.shop.scripts.OnClick(box.shop)
    L = G.EverlookAuctionsRecipeList
    lrows = [L.rows[i] for i in range(1, len(L.rows) + 1)]
    check([r.buy.text for r in lrows] == ["0", "3", "1"], "amounts before the bags change")
    lrows[2].buy.text = "7"
    lrows[2].buy.scripts.OnTextChanged(lrows[2].buy, True)
    G.MOCK_BAGS[2840] = 3
    G.MOCK_BAGS[2880] = 1
    fire("BAG_UPDATE_DELAYED")
    check(lrows[1].have.text == "3/4" and lrows[1].buy.text == "1",
          f"bought 2 bars: have 3/4, buy 1 ({lrows[1].have.text}, {lrows[1].buy.text})")
    check(lrows[2].have.text == "1/1" and lrows[2].buy.text == "7", "an amount you typed stays")

    # --- Options: /eah says when the options can't open
    lua, run = fresh_lua()
    lua.execute("StaticPopupDialogs = {}")
    ns = lua.table()
    run(VENDOR_SETUP, "setup", ns)
    load(run, ns, "Skin.lua")
    said = []
    ns.say = lambda m: said.append(m)
    ns.plain = lua.eval("function(t) return (tostring(t):gsub('|', '||')) end")
    load(run, ns, "Options.lua")
    ns.optionsError = "boom|x"
    check(ns.slash("options") is True and said and "couldn't be built" in said[-1] and "boom||x" in said[-1]
          and "for example" in said[-1], f"the options failing to build is said, with what still works: {said[-1:]}")
    return failures


CORE_SETUP = """
SlashCmdList = {}
MOCK_TIME = 100 * 86400
function time() return MOCK_TIME end
function GetTime() return 1 end
function GetServerTime() return MOCK_TIME end
function GetRealmName() return "Test" end
function UnitFactionGroup() return "Alliance" end
function strsplit(sep, s)
  local out, i = {}, 1
  while true do
    local j = s:find(sep, i, true)
    if not j then out[#out + 1] = s:sub(i); break end
    out[#out + 1] = s:sub(i, j - 1)
    i = j + 1
  end
  return unpack(out)
end
PRINTED = {}
function print(...) PRINTED[#PRINTED + 1] = table.concat({ ... }, " ") end
EverlookAuctionsDB = { houses = { ["Test-Alliance"] = { items = {},
  days = { [2589] = { [10] = 5, [99] = 7 }, [2592] = { [1] = 3 } } } } }
"""


def audit_search():
    """Advanced search fixes: money typed with spaces or decimals, values that can't mean anything are errors with an
    example, everyday words for slots and qualities, a search's own order found from the parse (not the text), and the
    live check: no answer is never "none up", and rows are asked again instead of staying at "checking..."."""
    lua = lua51.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(source_of("tests/mock.lua"))
    ns = lua.table()
    run = lua.eval("function(src, name, ...) local f = assert(loadstring(src, name)); return f(...) end")
    run(VENDOR_SETUP, "setup", ns)
    lua.execute(QUEUE_SETUP)
    # every way to get an item (Data.lua's order) and items with several: source is a comma list ("vendor, drop")
    run("""
      local ns = ...
      bit = bit or { band = function(a, b)
        local r, p = 0, 1
        while a > 0 and b > 0 do
          if a % 2 == 1 and b % 2 == 1 then r = r + p end
          a, b, p = math.floor(a / 2), math.floor(b / 2), p * 2
        end
        return r
      end }
      ns.SOURCES = { "vendor", "crafted", "drop", "quest", "skinning", "pickpocket", "fishing", "herbalism", "mining",
        "object", "world drop", "container", "disenchant" }
      ns.PROFESSIONS = { "Alchemy", "Blacksmithing", "Cooking", "Enchanting" }
      ns.ITEMDATA = {
        [2589] = { 1 + 4 },        -- Linen Cloth: vendor, drop
        [2592] = { 1024 },         -- Wool Cloth: world drop
        [3000] = { 4 },            -- Old Sword: drop
        [7001] = { 2, 4, 50 },     -- Lesser Magic Wand: crafted (Enchanting)
        [7002] = { 4 + 1024 },     -- Sort Wand: drop, world drop
      }
    """, "sources", ns)
    lua.execute("""
      AUDIT_TIME = 1000
      function time() return AUDIT_TIME end
      local create = CreateFrame
      function CreateFrame(kind, name, parent)
        local f = create(kind, name, parent)
        f.GetHeight = function() return 400 end
        -- fields (lowercase) start out nil, as on a real frame; methods stay the mock's
        local mt = getmetatable(f)
        local index = mt.__index
        setmetatable(f, { __index = function(t, k)
          if type(k) == "string" and k:match("^%l") then return nil end
          return index(t, k)
        end })
        return f
      end
      AuctionHouseFrame = CreateFrame("Frame", "AuctionHouseFrame")
      AuctionHouseFrame.BrowseResultsFrame = CreateFrame("Frame", nil, AuctionHouseFrame)
      AuctionHouseFrame.SearchBar = CreateFrame("Frame", nil, AuctionHouseFrame)
    """)
    for name in ["Skin.lua", "Vendor.lua", "AHQuery.lua", "Search.lua"]:
        run(source_of(name), name, "EverlookDBAuctions", ns)
    P = ns.queryParse
    G = lua.globals()
    perr = lua.eval("function(P, t) local ok, e = pcall(P, t); if ok then return nil end; "
                    "return type(e) == 'table' and e.query or tostring(e) end")
    failures = []

    def check(cond, what):
        if not cond:
            failures.append("audit search: " + what)

    def names(text):
        rows, head, _m, _v = ns.queryRun(text)
        if rows is None:
            return head
        return [rows[i].name for i in range(1, len(rows) + 1)]

    # money: "1g 50s" is one amount, decimals work, nonsense is an error with an example
    st = P("price lt 1g 50s")
    check(len(st) == 1 and st[1].e.k == "cmp" and st[1].e["values"][1] == "1g50s",
          "price lt 1g 50s: one amount, not a name search for 50s")
    got = names("type has wand and price lt 0.25g sort by price")
    check(got == ["Greater Magic Wand", "Sort Wand"], f"0.25g is 25s: {got}")
    check(names("type has wand and price between (5s .. 0.25g) sort by price") == ["Greater Magic Wand", "Sort Wand"],
          "between with decimal gold")
    check(names("type has wand and price lt 1gold sort by price") == ["Greater Magic Wand", "Sort Wand", "Lesser Magic Wand"],
          "1gold: a word for the unit")
    got = perr(P, "price lt 5gx")
    check(got is not None and "isn't an amount of money" in got and "e.g." in got, f"5gx: {got}")
    got = perr(P, "reqlevel le abc")
    check(got is not None and "isn't a number" in got and "e.g. reqlevel le 29" in got, f"reqlevel le abc: {got}")
    check(perr(P, "price lt vendor") is None and perr(P, "profit ge 1s") is None, "columns and money still parse")
    check(perr(P, "name has 50s") is None and perr(P, "ilvl has 2") is None, "text comparisons aren't checked")

    # everyday words for slots and qualities; unknown ones are errors with an example
    check(names("slot is cloak") == names("slot is back"), "cloak means back")
    check(names("quality is green and type has wand sort by price") == ["Greater Magic Wand", "Sort Wand", "Lesser Magic Wand"],
          f"green means uncommon: {names('quality is green and type has wand sort by price')}")
    check(names("slot is 1h") == ["Old Sword"], "1h means onehand")
    got = perr(P, "slot is spaceship")
    check(got is not None and 'no slot called "spaceship"' in got and "e.g. slot is back" in got, f"unknown slot: {got}")
    got = perr(P, "quality ge shiny")
    check(got is not None and "e.g. quality ge rare" in got, f"unknown quality: {got}")

    # source is a list of ways: is, has, in, ne compare whole ways (as on EverlookDB.com)
    def srt(text):
        got = names(text)
        return sorted(got) if isinstance(got, list) else got
    check(srt("source is vendor") == ["Linen Cloth"], f"source is vendor finds vendor, drop: {srt('source is vendor')}")
    check(srt("source == Vendor") == ["Linen Cloth"] and srt("source eq vendor") == ["Linen Cloth"], "== and eq, any case")
    check(srt("source is drop") == ["Linen Cloth", "Old Sword", "Sort Wand"], f"source is drop: {srt('source is drop')}")
    check(srt("source has drop") == ["Linen Cloth", "Old Sword", "Sort Wand"],
          f"has drop doesn't find world drop: {srt('source has drop')}")
    check(srt('source is "world drop"') == ["Sort Wand", "Wool Cloth"], f"world drop: {srt('source is \"world drop\"')}")
    check(srt("source in (vendor, crafted)") == ["Lesser Magic Wand", "Linen Cloth"], "in compares each way")
    check(srt("source has any (vendor, crafted)") == ["Lesser Magic Wand", "Linen Cloth"], "has any")
    check(srt("source has all (vendor, drop)") == ["Linen Cloth"], "has all")
    check(srt("source has all (drop, worlddrop)") == ["Sort Wand"], "has all with a synonym")
    every = srt("name has a or name has e or name has i or name has o or name has u")
    no_drop = sorted(set(every) - {"Linen Cloth", "Old Sword", "Sort Wand"})
    check(srt("source ne drop") == no_drop and srt("source != drop") == no_drop and srt("source is not drop") == no_drop,
          f"ne is the opposite of an element match: {srt('source ne drop')}")
    check(srt("source not has drop") == no_drop and srt("not source has drop") == no_drop, "not has")
    check(srt("from is vendor") == ["Linen Cloth"], "from is source")
    check(srt("source startswith world") == ["Sort Wand", "Wool Cloth"], "startswith tests each way")
    check(srt("source endswith drop") == ["Linen Cloth", "Old Sword", "Sort Wand", "Wool Cloth"], "endswith tests each way")
    check(srt("source like v*") == ["Linen Cloth"], "like tests each way")
    no_source = sorted(set(every) - {"Linen Cloth", "Wool Cloth", "Old Sword", "Lesser Magic Wand", "Sort Wand"})
    check(srt('source is ""') == no_source, f"source is empty: no source at all: {srt('source is \"\"')}")
    for typed, means in [("profession", "crafted"), ("worlddrop", "world drop"), ("world_drop", "world drop"),
                         ("WorldDrop", "world drop")]:
        check(srt(f"source is {typed}") == srt(f'source is "{means}"'), f"{typed} means {means}")
    got = perr(P, "source is automatic")
    check(got is not None and 'no item comes from "automatic"' in got, f"automatic is auto, not an item way: {got}")
    ways = ("vendor, crafted, drop, quest, skinning, pickpocket, fishing, herbalism, mining, object, world drop, "
            "container, disenchant")
    for q in ["source is trainer", "source has recipe", "source in (vendor, class)", "source ne item"]:
        got = perr(P, q)
        check(got is not None and "no item comes from" in got and ways in got and "e.g. source is vendor" in got,
              f"{q}: {got}")
    got = perr(P, "from is trainer")
    check(got is not None and "e.g. from is vendor" in got, f"from: its own word in the example: {got}")
    got = perr(P, "source is tailoring")
    check(got is not None and "profession is tailoring" in got, f"a profession as a source: {got}")
    check(perr(P, "source is mining") is None and perr(P, "source like *drop") is None
          and perr(P, "source startswith wor") is None, "ways, like and startswith parse")

    # a search's own order comes from the parse: "topaz" and "stop" aren't a top step
    ns.queryRun("name has topaz")
    check(ns.queryOrdered() is False, "name has topaz has no order of its own")
    ns.queryRun("type has wand sort by price")
    check(ns.queryOrdered() is True, "a sort step orders")
    ns.queryRun("type has wand top 2 by ilvl")
    check(ns.queryOrdered() is True, "top n by a column orders")
    ns.queryRun("type has wand top 2")
    check(ns.queryOrdered() is False, "top n alone doesn't")

    # the live check: answers come from a fake queue
    calls = []
    Q = ns.ahq
    Q.browse = lambda text, id_, opts, cb: calls.append((text, id_, cb))
    Q.cancel = lambda owner: None
    ns.query("type has wand sort by price")
    f = G.EverlookAuctionsQueryResults
    check(f is not None and len(calls) == 1 and calls[0][0] == "Greater Magic Wand", f"first row checked first: {calls}")
    # no answer: the row says so (never "none up"), the next row is asked
    calls[0][2](lua.table(ok=False))
    G.advance(0.2)
    check(len(calls) == 2, "next row asked after a missed one")
    calls[1][2](lua.table(ok=True, full=True, entries=lua.table()))   # Sort Wand: complete and empty: none up
    G.advance(0.2)
    calls[2][2](lua.table(ok=True, full=True, entries=lua.eval("{ { itemKey = { itemID = 7001 }, minPrice = 2900, totalQuantity = 1 } }")))
    G.advance(0.2)
    head = f.head.text
    check("1 without an answer" in head and "none" not in head.split("live prices")[0], f"status line: {head}")
    # a minute later the missed row is asked again; five minutes later every row is
    n = len(calls)
    G.AUDIT_TIME = 1061
    ns.liveStep()
    check(len(calls) == n + 1 and calls[-1][1] == 7003, f"missed row asked again after a minute: {calls[n:]}")
    calls[-1][2](lua.table(ok=True, full=True, entries=lua.eval("{ { itemKey = { itemID = 7003 }, minPrice = 950, totalQuantity = 1 } }")))
    G.advance(0.2)
    n = len(calls)
    G.AUDIT_TIME = 1400
    ns.liveStep()
    check(len(calls) == n + 1, "after five minutes the rows are checked again instead of staying at checking...")
    # the auction house closed with a check in flight: it is forgotten, so checks go on after reopening
    G.AUDIT_TIME = 2000
    ns.query("type has wand sort by ilvl")
    n = len(calls)
    ev = [fr for fr in G.MOCK_FRAMES.values() if fr.scripts and fr.scripts["OnEvent"]]
    for fr in ev:
        fr.scripts["OnEvent"](fr, "AUCTION_HOUSE_CLOSED")
    ns.liveStep()
    check(len(calls) == n + 1, f"after the auction house closed, the live check isn't stuck: {len(calls) - n}")

    # Blizzard's favourites search is Blizzard's browse; Show in Blizzard search clears a picked category first
    lua.execute("""
      AuctionHouseSearchContext = { AllFavorites = 7, AllAuctions = 8 }
      local ah = AuctionHouseFrame
      ah.QueryAll = function() end
      ah.SendBrowseQuery = function() end
      ah.SetDisplayMode = function() end
      local cats = { sel = 3 }
      function cats:GetSelectedCategory() return self.sel end
      function cats:SetSelectedCategory(i) self.sel = i end
      CATS = cats
      ah.GetCategoriesList = function() return cats end
      local searched = 0
      ah.SearchBar.SetSearchText = function(_, t) SEARCH_TEXT = t end
      ah.SearchBar.StartSearch = function() SEARCHED = (SEARCHED or 0) + 1; SEARCHED_CAT = cats.sel end
      ah.IsShown = function() return true end
    """)
    for fr in ev:
        fr.scripts["OnEvent"](fr, "AUCTION_HOUSE_SHOW")
    G.advance(1)
    Q.blizzard = None
    G.AuctionHouseFrame.QueryAll(G.AuctionHouseFrame, 7)
    check(Q.blizzard is True, "the favourites search counts as Blizzard's browse")
    Q.blizzard = None
    G.AuctionHouseFrame.QueryAll(G.AuctionHouseFrame, 8)
    check(Q.blizzard is None, "its own auctions list isn't a browse")
    G.advance(10)
    Q.showInBlizzard("Sort Wand")
    G.advance(1)
    check(G.SEARCHED == 1 and G.SEARCH_TEXT == "Sort Wand", "Show in Blizzard search searches the name")
    check(G.SEARCHED_CAT is None, "with no category picked, so a picked one can't hide the item")
    return failures



BUY_SETUP = """
-- fields the code sets itself (lower case) read as nil until set; only methods (capitalized) fall back to a no-op
local plainCreate = CreateFrame
local function plain(f)
  local mt = getmetatable(f)
  local old = mt.__index
  mt.__index = function(t, k)
    if type(k) == "string" and k:match("^%l") then return nil end
    return old(t, k)
  end
  local tex, fs = f.CreateTexture, f.CreateFontString
  f.CreateTexture = function(self, ...) return plain(tex(self, ...)) end
  f.CreateFontString = function(self, ...) return plain(fs(self, ...)) end
  return f
end
function CreateFrame(...) return plain(plainCreate(...)) end
MOCK_TIMERS = {}
C_Timer = { After = function(secs, fn) MOCK_TIMERS[#MOCK_TIMERS + 1] = { at = MOCK_NOW + secs, fn = fn } end }
function advance(secs)
  MOCK_NOW = MOCK_NOW + secs
  local i = 1
  while i <= #MOCK_TIMERS do
    local t = MOCK_TIMERS[i]
    if t.at <= MOCK_NOW then table.remove(MOCK_TIMERS, i); t.fn() else i = i + 1 end
  end
end
MONEY = 100000
function GetMoney() return MONEY end
ITEMS, COMMS, CALLS = {}, {}, {}
IS_COMMODITY = false
local function log(name) return function(...) CALLS[#CALLS + 1] = { name, ... } end end
C_AuctionHouse = {
  GetNumItemSearchResults = function() return #ITEMS end,
  GetItemSearchResultInfo = function(_, i) return ITEMS[i] end,
  GetNumCommoditySearchResults = function() return #COMMS end,
  GetCommoditySearchResultInfo = function(_, i) return COMMS[i] end,
  GetItemKeyInfo = function() return { isCommodity = IS_COMMODITY } end,
  GetQuoteDurationRemaining = function() return 20 end,
  PlaceBid = log("PlaceBid"),
  StartCommoditiesPurchase = log("Start"),
  ConfirmCommoditiesPurchase = log("Confirm"),
  CancelCommoditiesPurchase = log("Cancel"),
}
EverlookAuctionsQueryResults = CreateFrame("Frame", "EverlookAuctionsQueryResults")
"""

AHQ_FAKE = """
local ns = ...
AHQ = {}
ns.ahq = {
  cancel = function() end,
  keyText = function(k) return tostring(k.itemID) .. ":" .. tostring(k.itemSuffix or 0) end,
  nameOf = function() return nil end,
  pickKeys = function(entries)
    local keys = {}
    for _, e in ipairs(entries) do keys[#keys + 1] = e.itemKey end
    return keys, AHQ.showAll or false
  end,
  browse = function(_, _, _, cb) AHQ.browse = cb end,
  items = function(key, _, cb) AHQ.items = cb; AHQ.key = key end,
}
ns.itemInfo = function(id) return ns.db().itemInfo[id] end
DROPPED = {}
ns.dropResult = function(row) DROPPED[#DROPPED + 1] = row end
"""


def buy_panel():
    """The buy panel (Buy.lua) against a fake auction house: Start buying buys only its own pick in one click, an
    unknown vendor price never drops an item, a quote that can't be read or has run out can't be paid, purchase
    errors and late answers are reported, the panel shuts when hidden, and versions are named by their own part."""
    lua = lua51.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(source_of("tests/mock.lua"))
    ns = lua.table()
    run = lua.eval("function(src, name, ...) local f = assert(loadstring(src, name)); return f(...) end")
    run(VENDOR_SETUP, "setup", ns)
    lua.execute(BUY_SETUP)
    run(AHQ_FAKE, "ahq", ns)
    for name in ["Skin.lua", "Vendor.lua", "Buy.lua"]:
        run(source_of(name), name, "EverlookDBAuctions", ns)
    ns.calmSecs = 0   # the half-second click lockout after Buy turns into Confirm: off for these click scripts
    G = lua.globals()
    ev = G.MOCK_FRAMES[len(G.MOCK_FRAMES)]   # Buy.lua's event frame, made last
    tbl = lua.eval("function(...) return { ... } end")
    browse_answer = lua.eval("function(id) return { ok = true, full = true, entries = { { itemKey = { itemID = id } } } } end")
    failures = []

    def check(cond, what):
        if not cond:
            failures.append("buy: " + what)

    def fire(e, *args):
        ev.scripts.OnEvent(ev, e, *args)

    def calls(name):
        return [G.CALLS[i] for i in range(1, len(G.CALLS) + 1) if G.CALLS[i][1] == name]

    def answer(item_id):
        G.AHQ.browse(browse_answer(item_id))
        G.AHQ["items"](G.AHQ.key, True, True)

    def click(button):
        button.scripts.OnClick(button)

    def auction(aid, buyout, qty=1):
        return lua.table(auctionID=aid, buyoutAmount=buyout, quantity=qty, containsOwnerItem=False, timeLeft=3)

    # Start buying on Old Sword (vendor 500c): its cheapest auction under vendor price is picked, one click buys it
    G.ITEMS = tbl(auction(1, 300, 3), auction(2, 600))   # 300c each, 3 up
    deal_list = tbl(lua.table(header=True), lua.table(id=3000, name="Old Sword", quality="uncommon"))
    last_query = ns.lastQuery
    ns.lastQuery = lua.eval('function() return "profit > 0" end')   # a 5s sword never clears the 10s bar
    ns.startDeals(deal_list)
    f = G.EverlookAuctionsQueryResults.children[1]
    check(ns.buyOpen is True and f.shown, "a header row is skipped and the item opens")
    answer(3000)
    click(f.buy)
    bids = calls("PlaceBid")
    check(len(bids) == 1 and bids[0][2] == 1 and bids[0][3] == 300, f"one click buys the picked deal: {len(bids)}")
    # an error from the auction house: said, and nothing left waiting
    fire("AUCTION_HOUSE_SHOW_ERROR", 1)
    check("refused" in f.status.text and "Nothing was paid" in f.status.text, f"refusal reported: {f.status.text}")

    # an auction you pick yourself during Start buying still takes Buy, then Confirm
    G.CALLS = lua.table()
    G.advance(1)          # the panel looks again
    answer(3000)
    row = f.list.build(f.list, 1)
    row.item = f.list["items"][2]
    click(row)
    click(f.buy)
    check(len(calls("PlaceBid")) == 0 and f.buy.text.startswith("Confirm"), "a manual pick is armed, not bought")
    click(f.buy)
    bids = calls("PlaceBid")
    check(len(bids) == 1 and bids[0][2] == 2, "Confirm buys the manual pick")
    # no answer in time: the status says so instead of "Buying..." forever, and a late answer still counts
    G.advance(6)
    check("No word" in f.status.text, f"no answer said: {f.status.text}")
    fire("AUCTION_HOUSE_PURCHASE_COMPLETED", 2)
    check(f.status.text.startswith("Bought."), f"a late answer still counts: {f.status.text}")

    # vendor price not loaded yet: the item waits instead of being dropped as having no deals
    G.advance(1)          # its look-again goes out first
    G.CALLS = lua.table()
    unknown = lua.table(id=424242, name="Mystery", quality="common")
    ns.startDeals(tbl(unknown))
    answer(424242)
    check(len(G.DROPPED) == 0, "not dropped while its vendor price is unknown")
    check("vendor price" in f.status.text, f"says it waits: {f.status.text}")
    ns.db().itemInfo[424242] = lua.eval('{ "Mystery", 1, 1, 0, "Trade Goods", "Cloth", "", 1, 5000, 1 }')
    G.advance(1)
    check(f.status.text.startswith("Picked"), f"picked once the price came: {f.status.text}")
    ns.lastQuery = last_query

    # the version's own part of its name in the row
    G.AHQ.showAll = True
    ns.variantOf = lua.eval('function() return nil, nil, "Old Sword of the Bear" end')
    ns.openBuy(lua.table(id=3000, name="Old Sword", quality="uncommon"))
    G.ITEMS = tbl(lua.table(auctionID=5, buyoutAmount=900, quantity=1, timeLeft=3, itemLink="x"))
    answer(3000)
    row = f.list.build(f.list, 1)
    f.list.fill(row, f.list["items"][1])
    check(row.tag.text == "of the Bear", f"version tag: {row.tag.text}")
    G.AHQ.showAll = False

    # stackable goods: an unreadable quote can't be paid; a good one runs out
    G.IS_COMMODITY = True
    G.ITEMS = tbl()
    G.COMMS = tbl(lua.table(unitPrice=10, quantity=20, numOwnerItems=0))
    G.CALLS = lua.table()
    ns.openBuy(lua.table(id=2589, name="Linen Cloth", quality="common"))
    answer(2589)

    def amount(text):
        f.qty.text = text
        f.qty.scripts.OnTextChanged(f.qty, True)

    amount("")
    check(f.summary.text == "Type how many to buy.", f"no amount: {f.summary.text}")
    amount("50")
    check(f.summary.text.startswith("Only 20"), f"more than are up: {f.summary.text}")
    amount("5")
    click(f.buy)
    check(len(calls("Start")) == 1, "Buy asks for the price")
    fire("COMMODITY_PRICE_UPDATED", 10, None)
    check(not f.buy.text.startswith("Confirm") and len(calls("Cancel")) == 1, "no readable price: nothing to confirm")
    click(f.buy)
    fire("COMMODITY_PRICE_UPDATED", 10, 50)
    check(f.buy.text == "Confirm 50c", f"quote: {f.buy.text}")
    G.advance(21)
    check(f.buy.text == "Buy" and "ran out" in f.status.text, f"the quote runs out: {f.buy.text} / {f.status.text}")
    # the game says the quote is gone before our timer does: Confirm pays nothing
    click(f.buy)
    fire("COMMODITY_PRICE_UPDATED", 10, 50)
    check(f.buy.text == "Confirm 50c", f"quote again: {f.buy.text}")
    lua.execute("C_AuctionHouse.GetQuoteDurationRemaining = function() return 0 end")
    click(f.buy)
    check(len(calls("Confirm")) == 0 and f.buy.text == "Buy" and "ran out" in f.status.text,
          f"an expired quote can't be confirmed: {f.buy.text} / {f.status.text}")
    lua.execute("C_AuctionHouse.GetQuoteDurationRemaining = function() return 20 end")
    click(f.buy)
    G.advance(9)
    check(f.buy.text == "Buy" and "didn't send a price" in f.status.text, f"no price in time: {f.status.text}")

    # hidden with Advanced search: it shuts, so it can't come back later with old auctions
    f.scripts.OnHide(f)
    check(not f.shown and ns.buyOpen is False, "hidden by its parent: closed")

    # Blizzard's lists: your own auctions are not marked
    V = ns.vendor
    check(V.rowPrice(lua.table(itemID=3000, auctionID=1, containsOwnerItem=True, buyoutAmount=100, quantity=1)) is None,
          "your own item auction: no mark")
    _id, unit = V.rowPrice(lua.table(itemID=2589, auctionID=1, unitPrice=5, quantity=10, numOwnerItems=3,
                                     containsOwnerItem=True))
    check(unit == 5, "a commodity price partly yours still counts")
    check(V.rowPrice(lua.table(itemID=2589, auctionID=1, unitPrice=5, quantity=3, numOwnerItems=3)) is None,
          "a commodity price all yours: no mark")
    G.C_Item.GetItemInfoInstant = lua.eval("function() return nil end")
    check(V.isQuest(999999, None) is False and V.isQuest(999999, "Quest") is True,
          "an item not known yet isn't remembered as no quest item")
    return failures


def buy_decisions():
    """Start buying uses the list's 10s bar, a commodity quote over 5% above the listed price is refused, and a
    complete live answer from the buy panel reaches Advanced search's row."""
    lua = lua51.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(source_of("tests/mock.lua"))
    ns = lua.table()
    run = lua.eval("function(src, name, ...) local f = assert(loadstring(src, name)); return f(...) end")
    run(VENDOR_SETUP, "setup", ns)
    lua.execute(BUY_SETUP)
    run(AHQ_FAKE, "ahq", ns)
    for name in ["Skin.lua", "Vendor.lua", "Buy.lua"]:
        run(source_of(name), name, "EverlookDBAuctions", ns)
    ns.calmSecs = 0   # the half-second click lockout after Buy turns into Confirm: off for these click scripts
    G = lua.globals()
    ev = G.MOCK_FRAMES[len(G.MOCK_FRAMES)]
    tbl = lua.eval("function(...) return { ... } end")
    browse_answer = lua.eval("function(id) return { ok = true, full = true, entries = { { itemKey = { itemID = id } } } } end")
    V = ns.vendor
    failures = []

    def check(cond, what):
        if not cond:
            failures.append("buy decisions: " + what)

    # the 10s bar: per auction for items, together for stackable goods
    # an item row is priced per item and one click buys one, so how many are up doesn't add to the profit
    rows = tbl(lua.table(unit=600, buyout=600, qty=5), lua.table(unit=400, buyout=400, qty=1))
    pick = V.nextDeal(rows, 1500, False, V.MIN_DEAL)
    check(pick is not None and pick.unit == 400, "an item: the first auction making 10s on its own, not 5 up making 9s each")
    check(V.nextDeal(tbl(lua.table(unit=100, buyout=100, qty=1)), 500, False, V.MIN_DEAL) is None, "4s: nothing")
    check(V.nextDeal(tbl(lua.table(unit=100, buyout=100, qty=1)), 500, False, 0) is not None, "no bar: taken")
    goods = tbl(lua.table(unit=10, qty=20, others=20))
    check(V.nextDeal(goods, 13, True, V.MIN_DEAL) is None, "goods making 60c together: nothing")
    check(V.nextDeal(goods, 13, True, 0).qty == 20, "goods with no bar: all of them")

    # a live answer reaches the search row
    got = {}
    ns.setLive = lambda key, entry: got.__setitem__(key, entry)
    G.IS_COMMODITY = True
    G.COMMS = tbl(lua.table(unitPrice=10, quantity=20, numOwnerItems=0), lua.table(unitPrice=12, quantity=5, numOwnerItems=0))
    ns.openBuy(lua.table(id=2589, key="2589:0", name="Linen Cloth", quality="common"))
    G.AHQ.browse(browse_answer(2589))
    G.AHQ["items"](G.AHQ.key, True, True)
    e = got.get("2589:0")
    check(e is not None and e.price == 10 and e.qty == 25, "the row gets the lowest price and how many are up")

    # a quote more than 5% over the listed price is refused
    f = G.EverlookAuctionsQueryResults.children[1]
    f.qty.text = "5"
    f.qty.scripts.OnTextChanged(f.qty, True)
    f.buy.scripts.OnClick(f.buy)
    ev.scripts.OnEvent(ev, "COMMODITY_PRICE_UPDATED", 11, 55)
    check(f.buy.text == "Buy" and "went up to 55c (from 50c)" in f.status.text, f"refused: {f.status.text}")
    f.buy.scripts.OnClick(f.buy)
    ev.scripts.OnEvent(ev, "COMMODITY_PRICE_UPDATED", 10, 52)
    check(f.buy.text == "Confirm 52c", f"within 5%: {f.buy.text}")
    return failures


def places():
    """Each place has its own colour, defined once in the theme (Skin.lua): every panel resolves its accent from it,
    and the bar's Update prices / Try again button is a quiet button in the price updates' colour, never gold."""
    import re
    failures = []

    def check(cond, what):
        if not cond:
            failures.append("places: " + what)

    lua = lua51.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(source_of("tests/mock.lua"))
    # the mock answers any unknown key with a function; the widgets' own fields (edb...) start out empty, as in game
    lua.execute("""
        local base = CreateFrame
        CreateFrame = function(...)
          local f = base(...)
          local old = getmetatable(f).__index
          setmetatable(f, { __index = function(t, k)
            if type(k) == "string" and k:match("^edb") then return nil end
            return old(t, k)
          end })
          return f
        end
    """)
    ns = lua.table()
    run = lua.eval("function(src, name, ...) local f = assert(loadstring(src, name)); return f(...) end")
    run(source_of("Skin.lua"), "Skin.lua", "EverlookDBAuctions", ns)
    T, UI = ns.T, ns.UI
    names = ["search", "sell", "shopping", "prices"]
    check(all(T.places[n] is not None for n in names), "every place has a colour")
    cols = [tuple(T.places[n][k] for k in (1, 2, 3)) for n in names] + [tuple(T.accent[k] for k in (1, 2, 3))]
    check(len(set(cols)) == len(cols), "the places differ from each other and from gold")

    # contrast against the window background, for text
    def lum(c):
        def lin(v):
            return v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4
        r, g, b = (lin(v) for v in c)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    bg = tuple(T.bg[k] for k in (1, 2, 3))
    for n, c in zip(names, cols):
        ratio = (lum(c) + 0.05) / (lum(bg) + 0.05)
        check(ratio >= 4.5, f"{n} reads on the background: {ratio:.2f}")

    # a frame inside a place takes its colour; outside any place it is gold
    make = lua.eval("CreateFrame")
    same = lua.eval("rawequal")
    first = lua.eval("function(UI, f) return (UI.accentOf(f)) end")   # the colour, without the place's name
    for n in names:
        panel = make("Frame", None, lua.eval("UIParent"))
        UI.place(panel, n)
        inner = make("Frame", None, make("Frame", None, panel))
        check(same(first(UI, inner), T.places[n]), f"{n}: a box inside the panel resolves its colour")
    check(same(first(UI, make("Frame")), T.accent), "outside a place: gold")

    # the bar's button: quiet, in the price updates' colour
    bar = make("Frame")
    UI.place(bar, "prices")
    b = UI.button(bar, "Update prices", 128, 18, "quiet")
    check(b.edbRole == "quiet", f"the bar button is quiet, not {b.edbRole}")
    check(same(first(UI, b), T.places.prices), "the bar button is in the price updates' colour")
    check(UI.button(bar, "Post", 10, 10, "primary").edbRole == "primary", "a primary button is still primary")

    # every panel marks its place, and its colour is never hard-coded outside the theme
    src = {n: source_of(n) for n in
           ["Search.lua", "Sell.lua", "Shopping.lua", "Buy.lua", "EverlookDBAuctions.lua"]}
    for file, place in [("Search.lua", "search"), ("Sell.lua", "sell"), ("Shopping.lua", "shopping"),
                        ("EverlookDBAuctions.lua", "prices")]:
        check(f'UI.place(f, "{place}")' in src[file], f"{file} marks its panel as {place}")
    m = re.search(r'f\.button = UI\.button\(f, "Update prices", \d+, (\d+), "([^"]*)"\)', src["EverlookDBAuctions.lua"])
    check(m is not None and m.group(2) == "quiet" and int(m.group(1)) <= 20,
          f"the bar button is small and quiet: {m and m.groups()}")
    check("T.bad" not in src["EverlookDBAuctions.lua"].split("elseif bad then")[1].split("else")[0],
          "a cut-off update is not shown in alarm red")
    for file, text in src.items():
        for n in names:
            c = T.places[n]
            hexc = "%02x%02x%02x" % tuple(round(c[k] * 255) for k in (1, 2, 3))
            check(hexc not in text.lower(), f"{file} hard-codes the {n} colour")
    return failures


def quick_sell():
    """Quick sell (Sell.lua): strict undercut values, the price and quantity lines, the deposit warning, forgetting
    old remembered prices, and a missing or empty answer from the auction house never read as "nobody is selling"."""
    failures = []

    def check(cond, what):
        if not cond:
            failures.append("quick sell: " + what)

    lua = lua51.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(source_of("tests/mock.lua"))
    lua.execute("""
        time = os.time
        wipe = wipe or function(t) for k in pairs(t) do t[k] = nil end return t end
        MOCK_AH = { n = 0, full = false, rows = {} }
        C_AuctionHouse = {
          SupportsCopperValues = function() return true end,
          GetNumItemSearchResults = function() return MOCK_AH.n end,
          HasFullItemSearchResults = function() return MOCK_AH.full end,
          GetItemSearchResultInfo = function(_, i) return MOCK_AH.rows[i] end,
        }
    """)
    ns = lua.table()
    run = lua.eval("function(src, name, ...) local f = assert(loadstring(src, name)); return f(...) end")
    db = run(CRAFT_SETUP, "setup", ns)
    ns.num = lua.eval("tostring")
    ns.ago = lua.eval("function() return 'a while ago' end")
    for name in ["Skin.lua", "Sell.lua"]:
        run(source_of(name), name, "EverlookDBAuctions", ns)

    # Blizzard's popups are never hidden or changed from our code (that taints the popup system)
    for name in ("Sell.lua", "Buy.lua", "Search.lua", "Shopping.lua", "EverlookDBAuctions.lua", "Options.lua"):
        src = source_of(name)
        check("StaticPopup_Hide(" not in src.replace("pcall(StaticPopup_Hide", "StaticPopup_Hide(")
              and "StaticPopup_Show(" not in src, f"{name} touches Blizzard's popups")

    # undercut values: only gold, silver and copper amounts, a percent, or 0
    for bad in ("1.5s", "1s banana", "50", "s"):
        okSet, why = ns.setUndercut(bad)
        check(okSet is False and "for example" in why, f"{bad!r} is refused with an example")
    check(ns.setUndercut("1g50s") is True and db.undercut.copper == 15000, "1g50s is 15000c")
    check(ns.setUndercut("1c") is True and ns.undercutPrice(121) == 120, "1c under 1s21c")

    # the price line says how far under and the cheapest's price
    check(ns.underText(121) == "1c under the cheapest auction, 121c.", ns.underText(121))
    ns.setUndercut("0")
    check(ns.underText(121) == "Matches the cheapest auction, 121c.", ns.underText(121))
    ns.setUndercut("5%")
    check(ns.underText(200, "the auction you picked") == "5% under the auction you picked, 200c.", ns.underText(200, "the auction you picked"))
    ns.setUndercut("1c")

    # the line under Quantity: only for commodities, short
    check(ns.sellQtyNote(True, 40) == "Buyers can buy any amount.", ns.sellQtyNote(True, 40))
    check(ns.sellQtyNote(False, 3) == "", "items: no line (the Post button says how many)")
    check(ns.sellQtyNote(True, 0) == "", "nothing to sell: no line")

    # a click on a row of Current auctions sets the price to your undercut under it (or matches your own auction)
    unit, src = ns.sellRowPrice(lua.table(unit=500, others=2))
    check(unit == 499 and src == "1c under the auction you picked, 500c.", f"row click undercuts it: {unit} {src}")
    unit, src = ns.sellRowPrice(lua.table(unit=500, others=0))
    check(unit == 500 and src == "Matches your auction, 500c.", f"row click on your own auction matches it: {unit} {src}")
    ns.setUndercut("5%")
    unit, _src = ns.sellRowPrice(lua.table(unit=10000, others=1))
    check(unit == 9500, f"row click with a 5% undercut: {unit}")
    ns.setUndercut("1c")

    # the deposit warning: 1s deposit on 3 at 24c
    w = ns.depositWarning(100, 72, 15)
    check(w == "The deposit (100c) is more than this sells for (72c). If it doesn't sell you lose 100c."
          " Selling more at once spreads the deposit.", f"deposit over the sale: {w}")
    w = ns.depositWarning(100, 72, 90)
    check(w is not None and w.endswith("A vendor pays 90c for them."), f"a vendor pays more than the sale: {w}")
    check(ns.depositWarning(50, 72, 0) is None, "a deposit under the sale: no warning")
    check(ns.depositWarning(72, 72, 0) is None, "a deposit equal to the sale: no warning")
    check(ns.depositWarning(0, 72, 0) is None and ns.depositWarning(100, 0, 0) is None, "no deposit or no price: no warning")

    # remembered prices older than 180 days are dropped
    now = 1_800_000_000
    mem = lua.eval("function(now) return { a = { p = 1, at = now - 10 }, b = { p = 2, at = now - 200 * 86400 }, c = { p = 3 } } end")(now)
    gone = ns.pruneSellMemory(mem, now)
    check(gone == 2 and mem.a is not None and mem.b is None and mem.c is None, f"old prices forgotten: {gone}")

    # a usable answer: complete, or with a price in it
    tbl = lua.eval("function(t) return t end")
    check(ns.sellUsable(lua.table(full=False)) is False, "an incomplete answer with no price says nothing")
    check(ns.sellUsable(lua.table(full=True)) is True, "a complete empty answer: nobody is selling")
    check(ns.sellUsable(lua.table(full=False, lowestOther=50)) is True, "an incomplete answer with a price (sorted by price)")
    check(ns.sellUsable(None) is False, "no answer")

    # through the shared queue: no answer, then an empty incomplete answer, then a real one
    jobs = []
    Q = lua.table(list=lua.table())

    def items(key, opts, cb):
        job = lua.table(opts=opts, cb=cb)
        jobs.append(job)
        return job
    Q.items = items
    ns.ahq = Q
    key = lua.table(itemID=4242, itemLevel=20, itemSuffix=0)
    owned = lua.table(ckey="4242:20:0", itemID=4242, commodity=False, unit=500)
    ns.sellRequest(key, False, True)
    check(len(jobs) == 1 and jobs[0].opts.owner == "sell", "the search goes through the shared queue")
    ns.sellRequest(key, False, True)
    check(len(jobs) == 1, "asked once while the first is out")
    check(ns.ownedState(owned)[0] == "Checking", f"waiting: {ns.ownedState(owned)[0]}")
    jobs[0].opts.onFail("noanswer")
    check(ns.ownedState(owned)[0] == "No answer", f"no answer is not Lowest: {ns.ownedState(owned)[0]}")
    ns.sellRequest(key, False, True)
    check(len(jobs) == 2, "asked again")
    jobs[1].cb(key, False, True)   # last page, incomplete, no rows
    check(ns.ownedState(owned)[0] == "No answer", f"an empty incomplete answer is not Lowest: {ns.ownedState(owned)[0]}")
    ns.sellRequest(key, False, True)
    lua.execute("MOCK_AH.n = 2; MOCK_AH.full = true; MOCK_AH.rows = { { quantity = 1, buyoutAmount = 450 }, { quantity = 1, buyoutAmount = 500, containsOwnerItem = true } }")
    jobs[2].cb(key, True, True)
    state, _c, lower, frm = ns.ownedState(owned)
    check(state == "Undercut" and lower == 450 and frm == "live", f"someone else at 450c: {state} {lower} {frm}")
    lua.execute("MOCK_AH.rows[1].buyoutAmount = 600")
    ns.sellLive.cache["4242:20:0"] = None
    ns.sellRequest(key, False, True)
    jobs[3].cb(key, True, True)
    check(ns.ownedState(owned)[0] == "Lowest", f"cheapest is yours: {ns.ownedState(owned)[0]}")
    return failures



def ux_flows():
    """The flow-by-flow audit: the bar says why an update didn't finish, a shopping list's name is kept when you click
    away (for the list it belongs to) and Escape puts it back, and the settings window on EverlookUI takes
    /eah <setting> <value>."""
    failures = []

    def check(cond, what):
        if not cond:
            failures.append("ux: " + what)

    def fresh_lua():
        lua = lua51.LuaRuntime(unpack_returned_tuples=True)
        lua.execute(source_of("tests/mock.lua"))
        run = lua.eval("function(src, name, ...) local f = assert(loadstring(src, name)); return f(...) end")
        return lua, run

    # --- the bar: why the last update didn't finish
    lua, run = fresh_lua()
    lua.execute(CORE_SETUP)
    ns = lua.table()
    run(source_of("EverlookDBAuctions.lua"), "EverlookDBAuctions.lua", "EverlookDBAuctions", ns)
    text = ns.unfinishedText
    check("reload" in text(lua.table()), "no reason known: a reload cut it off")
    check("no answer" in text(lua.table(why="noanswer")) and "reload" not in text(lua.table(why="noanswer")),
          "a server that didn't answer isn't called a reload")
    check("empty list" in text(lua.table(why="empty")), "an empty list says so")
    check("closed" in text(lua.table(why="closed")), "closing the auction house says so")
    check(all("unchanged" in text(lua.table(why=w)) for w in ("noanswer", "empty", "closed")), "prices are said to be unchanged")

    # --- Shopping: the list name
    lua, run = fresh_lua()
    ns = lua.table()
    run(VENDOR_SETUP, "setup", ns)
    run(source_of("Skin.lua"), "Skin.lua", "EverlookDBAuctions", ns)
    run(source_of("Shopping.lua"), "Shopping.lua", "EverlookDBAuctions", ns)
    lua.execute("AuctionHouseFrame = CreateFrame('Frame', 'AuctionHouseFrame')")
    fire = lua.eval("function(e, a) for _, f in ipairs(MOCK_FRAMES) do if f.scripts.OnEvent then f.scripts.OnEvent(f, e, a) end end end")
    db = ns.db()
    db.lists = lua.eval('{ { name = "Herbs", queries = { "x" } }, { name = "Ore", queries = {} } }')
    db.listSel = 1
    fire("AUCTION_HOUSE_SHOW")
    f = lua.globals().EverlookAuctionsShopping
    check(f is not None, "the Shopping panel is made")
    if f is not None:
        f.Show(f)
        # the scrolling lists need more of the game than the fake has; only the name box is tested here
        lua.eval("function(f) f.lists.SetItems = function() end; f.queries.SetItems = function() end end")(f)
        ns.shoppingRefresh()
        box = f.name
        check(box.text == "Herbs", f"the picked list's name is in the box: {box.text!r}")
        box.scripts.OnEditFocusGained(box)
        box.text = "Herbs and || flowers"
        box.scripts.OnEditFocusLost(box)   # clicked into Add a search
        check(db.lists[1].name == "Herbs and | flowers", f"the name is kept on clicking away: {db.lists[1].name!r}")
        box.scripts.OnEditFocusGained(box)
        box.text = "Typo"
        db.listSel = 2                     # another list picked while typing
        box.scripts.OnEditFocusLost(box)
        check(db.lists[1].name == "Typo" and db.lists[2].name == "Ore", "the typed name goes to the list it was typed for")
        db.listSel = 1
        box.scripts.OnEditFocusGained(box)
        box.text = "Nope"
        box.scripts.OnEscapePressed(box)
        box.scripts.OnEditFocusLost(box)
        check(db.lists[1].name == "Typo", "Escape puts the old name back")
        box.scripts.OnEditFocusGained(box)
        box.text = "   "
        box.scripts.OnEditFocusLost(box)
        check(db.lists[1].name == "Typo", "an empty name isn't saved")

    # --- the settings window on EverlookUI: /eah <setting> <value>
    lua, run = fresh_lua()
    lua.execute("""
        CHAT = {}
        DEFAULT_CHAT_FRAME = { AddMessage = function(_, m) CHAT[#CHAT + 1] = m end }
        STANDARD_TEXT_FONT = "font"
    """)
    for lib in ("Libs/LibStub/LibStub.lua", "Libs/EverlookUI/EverlookUI.lua"):
        run(source_of(lib), lib)
    ns = lua.table()
    run(VENDOR_SETUP, "setup", ns)
    run(source_of("Skin.lua"), "Skin.lua", "EverlookDBAuctions", ns)
    lua.execute("""
        local ns = ...
    """)
    sell = lua.table()
    ns.sellSettings = lua.eval("function(t) return function() return t end end")(sell)
    ns.tipOn = lua.eval("""function(ns) return function(k)
        local t = ns.db().tip
        if not t or t[k] == nil then return k ~= "vendor" end
        return t[k]
      end end""")(ns)
    ns.undercutShort = lua.eval("function() return '1s' end")
    ns.setUndercut = lua.eval("function() return true end")
    run(source_of("Options.lua"), "Options.lua", "EverlookDBAuctions", ns)
    fire = lua.eval("function(e, a) for _, f in ipairs(MOCK_FRAMES) do if f.scripts.OnEvent then f.scripts.OnEvent(f, e, a) end end end")
    fire("ADDON_LOADED", "EverlookDBAuctions")
    check(ns.optionsError is None, f"the settings window builds: {ns.optionsError}")
    G = lua.globals()
    check(ns.slash("duration 24") is True and sell.duration == 2, f"/eah duration 24: {sell.duration}")
    check("24" in (G.CHAT[len(G.CHAT)] or ""), "the change is said in chat")
    check(ns.slash("tipvendor on") is True and ns.db().tip.vendor is True, "/eah tipvendor on")
    check(ns.slash("duration 30") is True and sell.duration == 2 and "Example" in G.CHAT[len(G.CHAT)],
          "a wrong value is refused with an example")
    check(ns.slash("skin off") is True and ns.db().skin is False, "/eah skin off")
    check(ns.slash("scan") is False, "a command that isn't a setting is left to the core")

    # /eah goes through the shared EverlookUI command pattern once the options are built
    app = ns.app
    check(app is not None, "the app is ns.app, so the core routes /eah to it")
    started = []
    ns.startScan = lambda *a: started.append(1)
    app.HandleSlash(app, "scan")
    check(started == [1], "/eah scan starts a scan")
    G.CHAT = lua.table()
    app.HandleSlash(app, "help")
    out = "\n".join(str(G.CHAT[i]) for i in range(1, len(G.CHAT) + 1))
    for want in ("/eah scan", "/eah sell", "/eah run <list>", "/eah get [setting]", "/eah search <words>", "/eah status"):
        check(want in out, f"help lacks {want}: {out}")
    check("/eah undercut|r" not in out, "the old undercut command is not listed twice")
    check("/eah test" not in out and "/eah debug" not in out, f"help leaves out test and debug: {out}")
    app.HandleSlash(app, "set duration 48")
    check(sell.duration == 3, f"/eah set duration 48: {sell.duration}")
    app.HandleSlash(app, "get duration")
    check("48" in G.CHAT[len(G.CHAT)], f"/eah get duration: {G.CHAT[len(G.CHAT)]}")
    app.HandleSlash(app, "auto off")
    check(ns.db().auto is False, "/eah auto off still works")
    app.HandleSlash(app, "sacn")
    check("Did you mean /eah scan?" in G.CHAT[len(G.CHAT)], f"a typo suggests the nearest: {G.CHAT[len(G.CHAT)]}")
    app.HandleSlash(app, "tipvendr off")
    check("Did you mean /eah tipvendor off?" in G.CHAT[len(G.CHAT)], f"a setting typo keeps the value: {G.CHAT[len(G.CHAT)]}")
    # which tab the auction house opens on
    check(ns.db().openOn is None, "opens on the last tab used by default")
    app.HandleSlash(app, "set openon sell")
    check(ns.db().openOn == "sell", f"/eah set openon sell: {ns.db().openOn}")
    app.HandleSlash(app, "openon browse")
    check(ns.db().openOn == "browse", f"/eah openon browse: {ns.db().openOn}")
    # compare with what you wear only while holding Shift: on by default, a setting, found by the settings search
    check(ns.db().compareShift is None, "compare only with Shift is on by default (not saved)")
    app.HandleSlash(app, "compareshift off")
    check(ns.db().compareShift is False, "/eah compareshift off")
    for word in ("equipped", "comparison"):
        near = app.Suggest(app, word)[0]
        check(near == "compareshift", f"the settings search finds it by '{word}': {near}")
    return failures


TEXT_SETUP = """
local ns, locale = ...
local db = {
  scans = { { realm = "Test", side = "Alliance", at = 0, rows = {
    ["1:0"] = "100,100,100,1,1", ["2:0"] = "200,200,200,1,1", ["3:0"] = "300,300,300,1,1", ["4:0"] = "400,400,400,1,1",
    ["5:0"] = "500,500,500,1,1", ["6:0"] = "600,600,600,1,1", ["7:0"] = "700,700,700,1,1",
    ["8:0"] = "800,800,800,1,1", ["8:1200"] = "900,900,900,1,1",
  } } },
  -- { name, quality, ilvl, reqlevel, category, type, equipLoc, icon, sell, stack }
  itemInfo = {
    [1] = { "Copper Rod", 1, 5, 0, "Trade Goods", "Parts", "", 1, 0, 1 },
    [2] = { "Runed Copper Rod", 2, 10, 0, "Trade Goods", "Parts", "", 1, 0, 1 },
    [3] = { "Thunderfury", 5, 80, 60, "Weapon", "Swords", "INVTYPE_WEAPON", 1, 0, 1 },
    [4] = { "Lesser Magic Wand", 2, 13, 8, "Weapon", "Wands", "INVTYPE_RANGEDRIGHT", 1, 0, 1 },
    [5] = { "Recipe: Elixir", 1, 20, 0, "Recipe", "Alchemy", "", 1, 0, 1 },
    [6] = { "Slow Item", 1, 20, 0, "Armor", "Cloth", "INVTYPE_FEET", 1, 0, 1 },
    [7] = { "Cheese", 1, 5, 0, "Consumable", "Food", "", 1, 0, 1 },
    [8] = { "Bandit Cloak", 2, 20, 15, "Armor", "Cloth", "INVTYPE_CLOAK", 1, 0, 1 },
  },
  itemStats = {},
}
ns.db = function() return db end
ns.house = function() return "Test-Alliance" end
ns.money = function(c) return tostring(c) .. "c" end
ns.num = function(n) return tostring(n) end
ns.ago = function() return "just now" end
ns.ok = function(v) return v end
ns.say = function() end
function GetRealmName() return "Test" end
function time() return 1000 end
function GetTime() return 100 end
function GetLocale() return locale end
function strsplit(sep, s)
  local out, i = {}, 1
  while true do
    local j = s:find(sep, i, true)
    if not j then out[#out + 1] = s:sub(i); break end
    out[#out + 1] = s:sub(i, j - 1)
    i = j + 1
  end
  return unpack(out)
end
C_Item.GetItemInfoInstant = function(id) return id, "", "", "", 1, 0 end
C_Item.GetItemInfo = function() return nil end
-- Data.lua's effect lines: the Runed Copper Rod's run speed (as on the site)
ns.EFFECTLINES = { "Use: Increases run speed by 8%.", "Equip: Increases your fire damage." }
ns.EFFECT = { [2] = 1, [6] = { 1, 2 } }
-- the game's tooltips, by item id (and by link for a random-stat version)
TIPS = {
  [1] = { "Copper Rod" },
  [2] = { "Runed Copper Rod", "Use: Increases run speed by 8%." },
  [3] = { "Thunderfury", { "One-Hand", "Sword" }, "Speed 1.90", "Chance on hit: Blasts your enemy with lightning." },
  [4] = { "Lesser Magic Wand" },
  [5] = { "Recipe: Elixir", "\\nElixir", "Use: Drink to win.", "Use: Teaches you how to craft Elixir." },
  [6] = { "Slow Item", "Equip: Increases run speed by 8%.", "Equip: Increases your fire damage." },
  [7] = { "Cheese", "|cff00ff00Use: Restores 20 health. (1 |4Sec:Sec; Cooldown)|r", '"Smelly."' },
  [8] = { "Bandit Cloak", "+5 Stamina" },
  ["item:8::::::::::::1:1200"] = { "Bandit Cloak of the Bear", "+5 Strength", "+5 Stamina" },
}
TIPCALLS = 0
local function data(lines)
  if not lines then return nil end
  local out = { lines = {} }
  for _, l in ipairs(lines) do
    if type(l) == "table" then out.lines[#out.lines + 1] = { leftText = l[1], rightText = l[2] }
    else out.lines[#out.lines + 1] = { leftText = l } end
  end
  return out
end
C_TooltipInfo = {
  GetItemByID = function(id) TIPCALLS = TIPCALLS + 1; return data(TIPS[id]) end,
  GetHyperlink = function(link) TIPCALLS = TIPCALLS + 1; return data(TIPS[link]) end,
}
if locale == "deDE" then
  ITEM_SPELL_TRIGGER_ONEQUIP, ITEM_SPELL_TRIGGER_ONUSE, ITEM_SPELL_TRIGGER_ONPROC = "Anlegen:", "Benutzen:", "Trefferchance:"
  TIPS[2] = { "Runenverzierte Kupferrute", "Benutzen: Erhoeht das Lauftempo um 8%." }
end
"""


def tooltip_text():
    """The effect and text columns and has without a column, as on EverlookDB.com (Quarry's crates/core tests
    bare_has_searches_text and text_gets_name_effect_and_set_on_load, crates/build itemtext tests): Data.lua's effect
    lines, the game's tooltip read once per item version, and has on its own searching text."""
    failures = []

    def load(locale):
        lua = lua51.LuaRuntime(unpack_returned_tuples=True)
        lua.execute(source_of("tests/mock.lua"))
        ns = lua.table()
        run = lua.eval("function(src, name, ...) local f = assert(loadstring(src, name)); return f(...) end")
        run(TEXT_SETUP, "setup", ns, locale)
        for name in ["Skin.lua", "Vendor.lua", "Search.lua"]:
            run(source_of(name), name, "EverlookDBAuctions", ns)
        return lua, ns

    def check(cond, what):
        if not cond:
            failures.append("text: " + what)

    def ids_of(ns):
        def ids(text):
            rows, head, _m, _v = ns.queryRun(text + " | sort by price")
            if rows is None:
                return head
            return [rows[i].id * (1 if rows[i].suffix == 0 else 100) for i in range(1, len(rows) + 1)]
        return ids

    lua, ns = load("enUS")
    P = ns.queryParse
    G = lua.globals()
    ids = ids_of(ns)

    # parsing: has without a column is text has (the site's bare_has_searches_text)
    e = P("items has speed")[1].e
    check(e.k == "cmp" and e.col == "text" and e.op == "has" and e["values"][1] == "speed", "items has speed is text has")
    st = P('where has "fire damage" and slot is trinket')
    check(len(st) == 1 and st[1].e.k == "and" and st[1].e.a.col == "text" and st[1].e.a["values"][1] == "fire damage",
          "where has ... and ...")
    check(P("items | where has speed")[1].e.col == "text", "| where has")
    check(P("contains speed")[1].e.col == "text", "contains is has")
    e = P("slot is feet or has speed")[1].e
    check(e.k == "or" and e.b.col == "text", "has after or")
    e = P("not has speed")[1].e
    check(e.k == "not" and e.e.col == "text", "has after not")
    check(P("(has speed)")[1].e.col == "text", "has after (")
    e = P("has any (run, wand)")[1].e
    check(e.col == "text" and e["values"][2] == "wand" and not e.all, "has any (a, b)")
    check(P('"speed"')[1].e.col == "name", "a quoted word alone still searches names")
    check(P("has")[1].e.col == "name", "has alone stays a word")
    check(P("name has rod")[1].e.col == "name" and P("stats has spirit")[1].e.col == "stats", "a column has stays")
    check(P("effects has speed")[1].e.col == "effect" and P("tooltip has speed")[1].e.col == "text", "aliases")
    perr = lua.eval("function(P, t) local ok, e = pcall(P, t); if ok then return nil end; "
                    "return type(e) == 'table' and e.query or tostring(e) end")
    got = perr(P, "effect has") or ""
    check('effect has "run speed"' in got, f"effect has what? with an example: {got}")

    # the site's searches
    got = ids('items | where has "run speed"')
    check(got == [2, 6], f'has "run speed": {got}')
    check(ids("items | where has speed and ilvl gt 50") == [3], "has speed and ilvl gt 50")
    got = ids("items | where quality is uncommon and has any (run, wand)")
    check(got == [2, 4], f"uncommon and has any (run, wand): {got}")
    got = ids("items | where not has speed and ilvl lt 15")
    check(got == [1, 4, 7], f"not has speed: {got}")
    check(ids("items | where name has rod") == [1, 2], "name has rod")

    # effect: Data.lua's lines (as on the site), several joined with " / "
    check(ids("effect has fire") == [6], "effect from Data.lua")
    check(ids('effect has "8%. / Equip: Increases your fire"') == [6], "several lines joined with /")
    check(ids('slot is feet and effect has "speed"') == [6], "boots with a speed effect")
    # text: the name, the tooltip (left and right) and the effect lines, each line once
    check(ids('has "Thunderfury / One-Hand / Sword / Speed 1.90"') == [3], "name, tooltip left and right text, with /")
    check(ids('has "Slow Item / Equip: Increases run speed by 8%. / Equip: Increases your fire damage."') == [6],
          "each line once: the tooltip's effect lines aren't added twice")
    # an item Data.lua has no lines for: its tooltip's, once read
    check(ids('effect has "chance on hit"') == [3], "effect from the tooltip when Data.lua has none")
    check(ids('effect has "Use: Restores 20 health. (1 Sec Cooldown)"') == [7], "colour and |4 codes are tidied")
    check(ids("has smelly") == [7], "flavour text")
    # a recipe: the made item's effects aren't its own, its Teaches line is (itemtext captured_skips_the_crafted_item)
    check(ids("effect has teaches") == [5] and ids("effect has drink") == [], "recipe: its own lines only")
    check(ids("has drink") == [5], "text has everything")
    # a random-stat version reads its own tooltip
    got = ids("has strength")
    check(got == [800], f"the version's own tooltip: {got}")
    check(ids("has stamina") == [8, 800], "both versions")

    # tooltips are read once per item version, never per search
    before = G.TIPCALLS
    ids('has "fire damage"')
    ids("has speed and not has wand")
    check(G.TIPCALLS == before, f"no tooltip reads in later searches: {G.TIPCALLS - before}")

    # an item the game is still loading: its name and effect lines until the tooltip comes
    lua2, ns2 = load("enUS")
    ids2 = ids_of(ns2)
    G2 = lua2.globals()
    G2.TIPS[3] = lua2.eval('{ "Retrieving item information" }')
    check(ids2("has lightning") == [], "not known yet")
    check(ids2("has thunderfury") == [3], "the name is always in text")
    G2.TIPS[3] = lua2.eval('{ "Thunderfury", "Chance on hit: Blasts your enemy with lightning." }')
    check(ids2("has lightning") == [3], "found once the tooltip is there")
    # not in the game's memory: asked for, not read, and the search says items are still coming (it runs again)
    lua2, ns2 = load("enUS")
    ids2, G2 = ids_of(ns2), lua2.globals()
    G2.CACHED, G2.LOADS = False, 0
    lua2.execute("C_Item.IsItemDataCachedByID = function() return CACHED end; "
                 "C_Item.RequestLoadItemDataByID = function() LOADS = LOADS + 1 end; TIPS[4] = { 'Lesser Magic Wand', 'Sparkly' }")
    before = G2.TIPCALLS
    _rows, _h, missing, _v = ns2.queryRun("has sparkly")
    check(G2.TIPCALLS == before and G2.LOADS > 0 and missing > 0, f"uncached: asked to load, {missing} still coming")
    G2.CACHED = True
    check(ids2("has sparkly") == [4], "read once the game has it")

    # an English client needs no tooltip for Data.lua's effects
    lua3, ns3 = load("enGB")
    check(ids_of(ns3)('effect has "run speed"') == [2, 6] and lua3.globals().TIPCALLS == 0,
          "effect from Data.lua reads no tooltips")

    # another language: effect lines from the game's tooltip, in its words
    lua4, ns4 = load("deDE")
    ids4 = ids_of(ns4)
    check(ids4('effect has "Lauftempo"') == [2], "German client: effect from the tooltip")
    check(ids4('effect has "run speed"') == [], "German client: not Data.lua's English lines")
    return failures


def tooltip_reads_last():
    """A tooltip search with a cheap condition beside it reads only the tooltips the cheap side leaves open, whichever
    side of and/or it is written on: the first search over a whole scan reads no tooltip it doesn't need."""
    failures = []
    lua = lua51.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(source_of("tests/mock.lua"))
    ns = lua.table()
    run = lua.eval("function(src, name, ...) local f = assert(loadstring(src, name)); return f(...) end")
    run(TEXT_SETUP, "setup", ns, "enUS")
    for name in ["Skin.lua", "Vendor.lua", "Search.lua"]:
        run(source_of(name), name, "EverlookDBAuctions", ns)
    G = lua.globals()
    rows, head, _m, _v = ns.queryRun('has speed and name has rod')
    got = [rows[i].id for i in range(1, len(rows) + 1)] if rows is not None else head
    if got != [2]:
        failures.append(f"tooltip last: has speed and name has rod found {got}")
    if G.TIPCALLS != 2:
        failures.append(f"tooltip last: read {G.TIPCALLS} tooltips, only the two rods' were needed")
    rows, head, _m, _v = ns.queryRun('has lightning or quality is legendary')
    got = [rows[i].id for i in range(1, len(rows) + 1)] if rows is not None else head
    if got != [3]:
        failures.append(f"tooltip last: or found {got}")
    return failures


def shared_tooltip():
    """The tooltip lines go through the shared EverlookTooltip layout: auction house, its 30-day line, disenchant and
    vendor in that order, money with coin icons, details behind Shift when set so, and a secret item id adds nothing."""
    failures = []

    def check(cond, what):
        if not cond:
            failures.append("shared tooltip: " + what)

    lua = lua51.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(source_of("tests/mock.lua"))
    run = lua.eval("function(src, name, ...) local f = assert(loadstring(src, name)); return f(...) end")
    lua.execute(CORE_SETUP)
    lua.execute("""
        SHIFT = false
        function IsShiftKeyDown() return SHIFT end
        function issecretvalue(v) return type(v) == "table" and v.secret == true end
        ERRORS = {}
        function geterrorhandler() return function(e) ERRORS[#ERRORS + 1] = e end end
        Enum = { TooltipDataType = { Item = 0, Unit = 2 } }
        HOOKS = {}
        TooltipDataProcessor = { AddTooltipPostCall = function(t, fn) HOOKS[t] = fn end }
        C_Item.GetItemInfo = function(id) if id == 2589 then return "Linen Cloth", nil, 1, 5, 1, "Trade Goods", "", 200, "", 0, 13 end end
        C_Item.GetItemMaxStackSizeByID = function() return 20 end
        local h = EverlookAuctionsDB.houses["Test-Alliance"]
        h["items"][2589] = { 95, 3365, 40, MOCK_TIME - 76 * 60 }
        h.days[2589] = { [99] = 93, [98] = 95, [97] = 120 }
        h.scanned = MOCK_TIME - 76 * 60
        EverlookAuctionsDB.tip = { vendor = true }
    """)
    for lib in ("Libs/LibStub/LibStub.lua", "Libs/EverlookUI/EverlookTooltip.lua"):
        run(source_of(lib), lib)
    ns = lua.table()
    run(source_of("EverlookDBAuctions.lua"), "EverlookDBAuctions.lua", "EverlookDBAuctions", ns)
    ns.disenchantValue = lua.eval("function(id) if id == 2589 then return 12345, 600 end end")
    fire = lua.eval("function(e, a) for _, f in ipairs(MOCK_FRAMES) do if f.scripts.OnEvent then f.scripts.OnEvent(f, e, a) end end end")
    fire("ADDON_LOADED", "EverlookDBAuctions")
    show = lua.eval("""function(id)
      local tip = { lines = {} }
      function tip:GetOwner() return MOCK_OWNER end
      function tip:AddLine(l) self.lines[#self.lines + 1] = (l:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) end
      function tip:AddDoubleLine(l, r)
        local function s(x) return (x:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|T[^|]-UI%-(%a)%a+Icon[^|]*|t",function(c) return c:lower() end)) end
        self.lines[#self.lines + 1] = s(l) .. " = " .. s(r)
      end
      HOOKS[0](tip, { id = id })
      return tip.lines
    end""")
    G = lua.globals()
    lines = show(2589)
    got = [lines[i] for i in range(1, len(lines) + 1)]
    want = [" ",
            "Auction house  3,365 listed · 76 min ago = 95c",
            "    30-day low = 93c",
            "    30-day median = 95c",
            "Disenchant  estimate · prices 10 min ago = 1g 23s",
            "Vendor = 13c",
            "Auction beats vendor  after 5% cut = +77c"]
    check(got == want, f"lines and order: {got}")
    G.SHIFT = True
    lines = show(2589)
    check(lines[2].endswith("= 19s") and "x20" in lines[2], f"Shift: a full stack's price: {lines[2]}")
    G.SHIFT = False
    # Ctrl: the stack under the mouse (a bag button showing 14), over Shift's full stack
    lua.execute("MOCK_OWNER = { Count = { GetText = function() return '14' end } }; IsControlKeyDown = function() return true end")
    lines = show(2589)
    check("x14" in lines[2] and lines[2].endswith("= 13s 30c"), f"Ctrl: the hovered stack's price: {lines[2]}")
    lua.execute("MOCK_OWNER = nil")
    lines = show(2589)
    check("x14" not in lines[2], f"Ctrl with no stack under the mouse: one: {lines[2]}")
    lua.execute("IsControlKeyDown = nil")
    ns.tipDetail("shift")
    lines = show(2589)
    check(len(lines) == 5 and "30-day" not in "".join(lines[i] for i in range(1, len(lines) + 1)),
          "details hidden without Shift when set so")
    check(G.EverlookAuctionsDB.tip.detail == "shift", "the detail setting is saved")
    ns.tipDetail("always")
    lines = show(lua.eval("{ secret = true }"))
    check(len(lines) == 0, "a secret item id adds no lines")
    check(len(G.ERRORS) == 0, f"no errors: {list(G.ERRORS.values()) if G.ERRORS else ''}")
    # at a neutral auction house (Booty Bay, Gadgetzan, Everlook) the cut is 15%
    keep = ns.houseOrFaction
    ns.houseOrFaction = lua.eval("function() return 'Test-Neutral' end")
    which, diff, stale, cut = ns.sellVerdict(2589)
    check(which == "auction" and diff == 80 - 13 and cut == 15, f"neutral house: 15% cut: {which} {diff} {cut}")
    ns.houseOrFaction = keep
    which, diff, stale, cut = ns.sellVerdict(2589)
    check(diff == 90 - 13 and cut == 5, f"faction house: 5% cut: {diff} {cut}")
    return failures


SHARED_SETUP = """
SHIFT = false
function IsShiftKeyDown() return SHIFT end
ERRORS = {}
function geterrorhandler() return function(e) ERRORS[#ERRORS + 1] = e end end
Enum = { TooltipDataType = { Item = 0, Unit = 2 } }
HOOKS = {}
TooltipDataProcessor = { AddTooltipPostCall = function(t, fn) HOOKS[t] = fn end }
C_Item.GetItemInfo = function(id) if id == 2589 then return "Linen Cloth", nil, 1, 5, 1, "Trade Goods", "", 200, "", 0, 13 end end
C_Item.GetItemMaxStackSizeByID = function() return 20 end
local h = EverlookAuctionsDB.houses["Test-Alliance"]
h.items[2589] = { 95, 3365, 40, MOCK_TIME - 76 * 60 }
h.days[2589] = { [99] = 93, [98] = 95, [97] = 120 }
h.scanned = MOCK_TIME - 76 * 60
EverlookAuctionsDB.scans = { { realm = "Test", side = "Alliance", at = MOCK_TIME - 76 * 60,
  rows = { ["2589:0"] = "95,96,99,3365,40,0,0,0,0,0,40," , ["4000:7"] = "500,500,500,1,1,0,0,0,0,0,1,,of the Owl" } } }
EverlookDBAuctionsShared = { version = 1, written = MOCK_TIME, houses = {
  ["EU-4-Alliance"] = { region = "EU", realm = "Test", realmID = 4, side = "Alliance", at = MOCK_TIME - 12 * 60,
    auctions = 500, firstDay = 95,
    rows = {
      ["2589:0"] = "90,91,94,4000,50,0,0,0,0,0,50,",
      ["2589:5"] = "80,80,80,2,2,0,0,0,0,0,2,,of the Bear",
      ["777:0"] = { "not", "text" },
      ["778:0"] = "lots,of,words",
      ["oops"] = "1,1,1,1,1",
      ["779:0"] = "-5,1,1,1,1",
    },
    lows = { [2589] = "200,,88,,", [778] = { 1 }, [779] = "x,y" },
  },
  ["EU-4-Horde"] = { realm = "Test", side = "Horde", at = "soon", rows = {} },
  ["junk"] = "nope",
} }
"""


def shared_prices():
    """Shared prices (SharedPrices.lua, from the EverlookDB App's data addon): the newer of our own scan and other
    players' wins per item and version, says whose it is, merges the daily lows, never writes into our saved data,
    can be ignored, and a missing or broken file changes nothing."""
    failures = []

    def check(cond, what):
        if not cond:
            failures.append("shared prices: " + what)

    def start(extra=""):
        lua = lua51.LuaRuntime(unpack_returned_tuples=True)
        lua.execute(source_of("tests/mock.lua"))
        run = lua.eval("function(src, name, ...) local f = assert(loadstring(src, name)); return f(...) end")
        lua.execute(CORE_SETUP)
        lua.execute(SHARED_SETUP)
        lua.execute(extra)
        for lib in ("Libs/LibStub/LibStub.lua", "Libs/EverlookUI/EverlookTooltip.lua"):
            run(source_of(lib), lib)
        ns = lua.table()
        for name in ("EverlookDBAuctions.lua", "SharedPrices.lua", "API.lua"):
            run(source_of(name), name, "EverlookDBAuctions", ns)
        fire = lua.eval("function(e, a) for _, f in ipairs(MOCK_FRAMES) do if f.scripts.OnEvent then f.scripts.OnEvent(f, e, a) end end end")
        fire("ADDON_LOADED", "EverlookDBAuctions")
        show = lua.eval("""function(id)
          local tip = { lines = {} }
          function tip:GetOwner() return nil end
          function tip:AddLine(l) self.lines[#self.lines + 1] = (l:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) end
          function tip:AddDoubleLine(l, r)
            local function s(x) return (x:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|T[^|]-UI%-(%a)%a+Icon[^|]*|t",function(c) return c:lower() end)) end
            self.lines[#self.lines + 1] = s(l) .. " = " .. s(r)
          end
          HOOKS[0](tip, { id = id })
          local out = {}
          for _, l in ipairs(tip.lines) do out[#out + 1] = l end
          return table.concat(out, " ;; ")
        end""")
        return lua, ns, show

    lua, ns, show = start()
    G = lua.globals()
    it = ns.itemFor(2589)
    check(it is not None and it[1] == 80 and it.shared and it[2] == 4002 and it[3] == 52,
          f"the newer shared scan wins, all versions together: {it and (it[1], it[2], it[3])}")
    own = G.EverlookAuctionsDB.houses["Test-Alliance"]["items"][2589]
    check(own[1] == 95 and own.shared is None, "our own saved price is untouched")
    check(G.EverlookAuctionsDB.shared is None and G.EverlookAuctionsDB.houses["EU-4-Alliance"] is None,
          "nothing shared goes into the saved variables")
    tip = show(2589)
    check("Auction house  other players' scan · 4,002 listed · 12 min ago = 80c" in tip, f"the tooltip says whose and how old: {tip}")
    check("30-day low = 88c" in tip and "30-day median = 93c" in tip, f"the 30-day lines use the shared daily lows too: {tip}")
    row = ns.scanRowFor("2589:0")
    check(row is not None and row.low == 90 and row.shared and row.at == G.MOCK_TIME - 720, "a version's row from the shared scan")
    check(ns.scanRowFor("4000:7") is None, "a version the newer (shared) scan doesn't list isn't up")
    check(ns.scanRowFor("777:0") is None and ns.scanRowFor("778:0") is None and ns.scanRowFor("779:0") is None,
          "rows that aren't plain numbers are skipped")
    hist = ns.historyFor(2589)
    check([(hist[i][1], hist[i][2]) for i in range(1, len(hist) + 1)] == [(95, 200), (97, 88), (98, 95), (99, 93)],
          f"daily lows merged, the lower each day: {[(hist[i][1], hist[i][2]) for i in range(1, len(hist) + 1)]}")
    api = G.EverlookDBAuctionsAPI
    low, age, qty, n, src = api.price(2589)
    check(low == 80 and age == 720 and src == "shared", f"the API gives the shared price and says so: {low} {age} {src}")
    low, age, qty, n, src = api.price(2589, 5)
    check(low == 80 and src == "shared", "the API: a version from the shared scan")
    which, diff, stale, cut = ns.sellVerdict(2589)
    check(which == "auction" and diff == 76 - 13, f"More to auction uses the newer price: {which} {diff}")
    at, shared = ns.pricesAt()
    check(at == G.MOCK_TIME - 720 and shared is True, "how old the prices are: the shared scan")
    check(any("Price Feed, Test-Alliance" in l for l in ns.statusLines().values()), "/eah status lists the feed's house")
    check(len(G.ERRORS) == 0, f"no errors: {list(G.ERRORS.values())}")

    # the setting: only our own scans
    G.EverlookAuctionsDB.ignoreShared = True
    it = ns.itemFor(2589)
    check(it[1] == 95 and it.shared is None, "ignored: our own price")
    check("other players" not in show(2589), "ignored: the tooltip doesn't mention it")
    check(api.price(2589)[0] == 95 and api.price(2589)[4] == "own", "ignored: the API gives our own")
    G.EverlookAuctionsDB.ignoreShared = None

    # our own newer scan wins over an older shared one
    lua, ns, show = start("EverlookDBAuctionsShared.houses['EU-4-Alliance'].at = MOCK_TIME - 3 * 3600")
    it = ns.itemFor(2589)
    check(it[1] == 95 and it.shared is None, "an older shared scan loses to our own")
    row = ns.scanRowFor("4000:7")
    check(row is not None and row.low == 500 and not row.shared, "our newer scan's version rows")
    check("this version" not in show(2589) and "other players" not in show(2589), "the tooltip shows our own")

    # a missing or broken file is the same as none
    for broken in ("EverlookDBAuctionsShared = nil", "EverlookDBAuctionsShared = 'x'",
                   "EverlookDBAuctionsShared = { version = 2, houses = {} }",
                   "EverlookDBAuctionsShared = { version = 1, houses = 5 }",
                   "EverlookDBAuctionsShared.houses['EU-4-Alliance'].rows = 'x'",
                   "EverlookDBAuctionsShared.houses['EU-4-Alliance'].at = 0/0"):
        lua, ns, show = start(broken)
        it = ns.itemFor(2589)
        check(it is not None and it[1] == 95 and not it.shared, f"{broken}: our own price")
        check("Auction house" in show(2589), f"{broken}: the tooltip still works")
        check(len(lua.globals().ERRORS) == 0, f"{broken}: no errors")
    return failures + price_feed_lines(start)


def price_feed_lines(start):
    """The Price Feed's status line (the auction house's bar, the General page, /eah status, /eah feed) and its
    one-time hint, with the feed, without it, installed but empty, and turned off in the settings."""
    failures = []

    def check(cond, what):
        if not cond:
            failures.append("price feed: " + what)

    def said(G):
        return [p for p in G.PRINTED.values() if "Price Feed" in p]

    OFF = "Price Feed: off · the EverlookDB App brings other players' newest scans (everlookdb.com)"
    EMPTY = "Price Feed: no data yet · the EverlookDB App fills it (everlookdb.com)"

    # with the feed: the house, whose scan and how old
    lua, ns, _ = start()
    G = lua.globals()
    S = ns.shared
    check(S.state() == "on", f"state: {S.state()}")
    line = S.feedLine("Test-Alliance", "Alliance")
    check(line == "Price Feed: Alliance · other players' scan, 12 min old", f"the bar's line: {line}")
    line = S.feedLine()
    check(line == "Price Feed: Test Alliance · other players' scan, 12 min old", f"the settings page's line: {line}")
    line = S.feedLine("Test-Neutral", "Neutral")
    check(line.startswith("Price Feed: on · no one has uploaded"), f"a house the feed doesn't have: {line}")
    check(S.hintOnce() is False and not said(G) and G.EverlookAuctionsDB.feedHinted is None, "no hint with the feed")

    # without it (not installed): the line says where it comes from; one chat line, once per account
    lua, ns, _ = start("EverlookDBAuctionsShared = nil")
    G = lua.globals()
    S = ns.shared
    check(S.state() == "none", f"state without: {S.state()}")
    check(S.feedLine("Test-Alliance", "Alliance") == OFF, f"the bar without: {S.feedLine('Test-Alliance', 'Alliance')}")
    check(S.feedLine() == OFF, "the settings page without")
    check(list(ns.statusLines().values())[-1] == OFF, f"/eah status without: {list(ns.statusLines().values())}")
    check(S.hintOnce() is True and G.EverlookAuctionsDB.feedHinted is True, "the hint the first time")
    check(S.hintOnce() is False, "never again")
    check(len(said(G)) == 1 and said(G)[0].endswith(OFF), f"one chat line: {said(G)}")
    # the saved flag is account-wide: another session with it set says nothing
    lua, ns, _ = start("EverlookDBAuctionsShared = nil; EverlookAuctionsDB.feedHinted = true")
    check(ns.shared.hintOnce() is False and not said(lua.globals()), "not again after a reload")

    # installed from CurseForge but empty (the app isn't running yet)
    lua, ns, _ = start("EverlookDBAuctionsShared = { version = 1, written = 0, houses = {} }")
    G = lua.globals()
    S = ns.shared
    check(S.state() == "empty", f"state empty: {S.state()}")
    check(S.feedLine("Test-Alliance", "Alliance") == EMPTY, f"the bar, empty: {S.feedLine('Test-Alliance', 'Alliance')}")
    check(S.hintOnce() is True and len(said(G)) == 1 and said(G)[0].endswith(EMPTY), f"the hint, empty: {said(G)}")
    check(len(G.ERRORS) == 0, f"no errors: {list(G.ERRORS.values())}")

    # turned off in the settings: says so, no hint
    lua, ns, _ = start("EverlookAuctionsDB.ignoreShared = true")
    G = lua.globals()
    line = ns.shared.feedLine("Test-Alliance", "Alliance")
    check(line == "Price Feed: turned off in your settings (/eah, General)", f"ignored: {line}")
    check(ns.shared.hintOnce() is False and not said(G), "no hint when the player turned it off")
    return failures


def reload_logged():
    """An update cut off by a reload or logout shows in /eah status's update log once, as the bar already says."""
    failures = []
    lua = lua51.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(source_of("tests/mock.lua"))
    run = lua.eval("function(src, name, ...) local f = assert(loadstring(src, name)); return f(...) end")
    lua.execute(CORE_SETUP)
    lua.execute("local h = EverlookAuctionsDB.houses['Test-Alliance']; h.tried = MOCK_TIME - 50; h.scanned = MOCK_TIME - 5000; "
                "EverlookAuctionsDB.houses['Done-Horde'] = { items = {}, days = {}, tried = 10, scanned = 20 }")
    ns = lua.table()
    run(source_of("EverlookDBAuctions.lua"), "EverlookDBAuctions.lua", "EverlookDBAuctions", ns)
    fire = lua.eval("function(e, a) for _, f in ipairs(MOCK_FRAMES) do if f.scripts.OnEvent then f.scripts.OnEvent(f, e, a) end end end")
    fire("ADDON_LOADED", "EverlookDBAuctions")
    fire("ADDON_LOADED", "EverlookDBAuctions")
    G = lua.globals()
    h = G.EverlookAuctionsDB.houses["Test-Alliance"]
    log = h.log
    if h.why != "reload" or log is None or len(log) != 1 or "reload" not in log[1].how:
        failures.append(f"reload: an update cut off by a reload is logged once ({h.why}, {log and len(log)})")
    if G.EverlookAuctionsDB.houses["Done-Horde"].log is not None:
        failures.append("reload: a finished update is not logged as cut off")
    if "reload" not in ns.unfinishedText(h):
        failures.append("reload: the bar still says a reload cut it off")
    return failures


FAKE_ENCODING = """
Enum = Enum or {}
Enum.CompressionMethod = { Deflate = 0, Zlib = 1, Gzip = 2 }
ENCODE_BREAK = nil   -- "decompress" gives other text back, "throw" makes compressing fail
C_EncodingUtil = {
  CompressString = function(s, method)
    if ENCODE_BREAK == "throw" then error("no") end
    assert(method == 1)
    return "Z" .. s
  end,
  DecompressString = function(s, method)
    assert(method == 1)
    return ENCODE_BREAK == "decompress" and s:sub(2) .. "x" or s:sub(2)
  end,
  EncodeBase64 = function(s) return "B" .. s end,
  DecodeBase64 = function(s) return s:sub(2) end,
}
"""


def scan_storage():
    """Older full scans packed (zlib + base64 when the game round-trips it, else plain text), retention (7 days,
    same-hour thinning, the scan and size caps, the newest per house always kept), and the unsaved-scans note."""
    failures = []

    def check(cond, what):
        if not cond:
            failures.append("scan storage: " + what)

    def core(encoding):
        lua = lua51.LuaRuntime(unpack_returned_tuples=True)
        lua.execute(source_of("tests/mock.lua"))
        lua.execute(CORE_SETUP)
        if encoding:
            lua.execute(FAKE_ENCODING)
        run = lua.eval("function(src, name, ...) local f = assert(loadstring(src, name)); return f(...) end")
        ns = lua.table()
        run(source_of("EverlookDBAuctions.lua"), "EverlookDBAuctions.lua", "EverlookDBAuctions", ns)
        fire = lua.eval("function(e, a) for _, f in ipairs(MOCK_FRAMES) do if f.scripts.OnEvent then f.scripts.OnEvent(f, e, a) end end end")
        fire("ADDON_LOADED", "EverlookDBAuctions")
        return lua, ns

    make = """function(at, side)
      return { realm = "Test", realmID = 5, side = side or "Alliance", at = at, took = 30, build = "1", addon = "dev",
        auctions = 9, noLink = 1, linkRounds = { 1 }, noLinkItems = { "7:1" }, linkSamples = { "x" },
        rows = { ["2:0"] = "5,5,5,1,1,0,0,0,0,0,1,", ["10:3"] = "9,9,9,2,1,0,0,0,0,1,0,", ["10:-7"] = "8,8,8,1,1,0,0,0,1,0,0,,of the Bear" },
        deals = { ["2:0"] = "5:1" } }
    end"""
    packed = "10:-7=8,8,8,1,1,0,0,0,1,0,0,,of the Bear\n10:3=9,9,9,2,1,0,0,0,0,1,0,\n2:0=5,5,5,1,1,0,0,0,0,0,1,"

    # --- packing: compressed when the game round-trips it
    lua, ns = core(True)
    sc = lua.eval(make)(1000)
    ns.compactScan(sc)
    check(sc.zm == "zlib-b64" and sc.z == "BZ" + packed and sc.packed is None, f"compressed and base64: {sc.z!r}")
    check(sc.rows is None and sc.deals is None and sc.linkSamples is None, "rows, deals and link samples go")
    check(sc.nrows == 3, f"row count kept: {sc.nrows}")
    check(sc.realm == "Test" and sc.realmID == 5 and sc.side == "Alliance" and sc.at == 1000 and sc.took == 30
          and sc.auctions == 9 and sc.noLink == 1 and sc.linkRounds[1] == 1 and sc.noLinkItems[1] == "7:1"
          and sc.build == "1" and sc.addon == "dev", "every other field kept")
    ns.compactScan(sc)
    check(sc.z == "BZ" + packed, "packing twice changes nothing")

    # a round trip that gives other text back, or compressing that fails: plain packed text
    for brk in ["decompress", "throw"]:
        lua.globals().ENCODE_BREAK = brk
        sc = lua.eval(make)(1000)
        ns.compactScan(sc)
        check(sc.z is None and sc.zm is None and sc.packed == packed and sc.rows is None,
              f"{brk}: falls back to plain text ({sc.z!r})")
    lua.globals().ENCODE_BREAK = None

    # no C_EncodingUtil at all, or no CompressString: plain packed text
    lua2, ns2 = core(False)
    sc = lua2.eval(make)(1000)
    ns2.compactScan(sc)
    check(sc.packed == packed and sc.z is None and sc.nrows == 3, "no encoding API: plain packed text")
    lua2.execute(FAKE_ENCODING + "C_EncodingUtil.CompressString = nil")
    sc = lua2.eval(make)(1000)
    ns2.compactScan(sc)
    check(sc.packed == packed and sc.z is None, "no CompressString: plain packed text")

    # --- retention
    G = lua.globals()
    now = G.MOCK_TIME
    day = 86400
    mk = lua.eval(make)
    setp = lua.eval("function(sc, n) sc.rows, sc.deals = nil, nil; sc.packed = string.rep('x', n); sc.nrows = 1 end")
    tbl = lua.eval("function(...) return { ... } end")

    def ats(scans):
        return [scans[i].at for i in range(1, len(scans) + 1)]

    # past 7 days goes, unless it is the newest scan of its house; the house's previous scan is packed
    scans = tbl(mk(now - 8 * day), mk(now - 10 * day, "Horde"), mk(now - day), mk(now))
    dropped, _room = ns.trimScans(scans, now)
    check(dropped == 1 and ats(scans) == [now - 10 * day, now - day, now], f"8-day-old scan dropped: {ats(scans)}")
    check(scans[1].rows is not None and scans[3].rows is not None, "the newest scan per house keeps its rows")
    check(scans[2].rows is None and scans[2].z is not None, "the house's older scan is packed")

    # over 60 scans: a scan with a newer one of its house in the same server hour goes first, oldest first
    base = (now // 3600 - 20) * 3600
    scans = tbl(*[mk(base + k * 900) for k in range(64)])   # 4 per hour, 16 hours
    dropped, _room = ns.trimScans(scans, now)
    left = ats(scans)
    gone = sorted(set(base + k * 900 for k in range(64)) - set(left))
    check(dropped == 4 and len(left) == 60, f"64 scans trimmed to 60 ({dropped} dropped)")
    check(gone == [base, base + 900, base + 1800, base + 3600], f"same-hour duplicates, oldest first: {[(g - base) // 900 for g in gone]}")
    check(left[-1] == base + 63 * 900 and scans[60].rows is not None, "the newest is kept with its rows")

    # no same-hour duplicates: the oldest go
    scans = tbl(*[mk(base - 100 * 3600 + k * 7200) for k in range(62)])
    ns.trimScans(scans, now)
    left = ats(scans)
    check(len(left) == 60 and left[0] == base - 100 * 3600 + 2 * 7200, f"oldest dropped when none share an hour: {len(left)}")

    # the size cap: 1,000,000 bytes each, about 6 MB in all; drops for room are counted for /eah status
    scans = tbl(*[mk(base + k * 3600) for k in range(25)])
    for i in range(1, 25):
        setp(scans[i], 1000000)
    dropped, room = ns.trimScans(scans, now)
    check(len(scans) == 7 and scans[1].at == base + 18 * 3600, f"over 6 MB: oldest dropped ({len(scans)} left)")
    check(dropped == 18 and room == 18, f"all 18 went for room: {dropped}, {room}")
    ns.noteDropped(room, now)
    ns.noteDropped(0, now + 8 * day)
    check(ns.droppedText() is None, "drops older than 7 days are forgotten")
    ns.noteDropped(2, now)
    check("2 older scans were dropped in the last 7 days" in ns.droppedText(), ns.droppedText())
    lua.globals().EverlookAuctionsDB.dropped = None

    # the newest scan of each house is never dropped, even alone over the size cap
    big = mk(base - 5 * 3600, "Horde")
    setp(big, 30000000)
    big.packed = None
    big.rows = lua.eval("{}")
    big.nrows = 500000   # 500,000 rows x 72 bytes: 36 MB estimated
    scans = tbl(mk(base - 6 * 3600), big, mk(base - 3600), mk(base))
    ns.trimScans(scans, now)
    check(len(scans) == 2 and scans[1].side == "Horde" and scans[2].at == base, f"only the newest per house left: {ats(scans)}")

    # --- the unsaved-scans note
    db = G.EverlookAuctionsDB
    a, b, c = mk(now - 3000), mk(now - 1000), mk(now - 500)
    db.scans = tbl(a, b)
    ns.noteUnsaved(b, now - 1000)
    check(ns.unsavedText(now) is None, "under 30 minutes: no note")
    check(ns.unsavedText(now + 801) == "1 scan waiting to upload · saved at logout", f"one scan: {ns.unsavedText(now + 801)}")
    ns.noteUnsaved(c, now - 500)
    check(ns.unsavedText(now + 801) == "1 scan waiting to upload · saved at logout", "a scan no longer kept doesn't count")
    db.scans[3] = c
    check(ns.unsavedText(now) is None and ns.unsavedText(now + 1000) == "2 scans waiting to upload · saved at logout",
          f"two scans, timed by the oldest: {ns.unsavedText(now + 1000)}")
    G.PRINTED = lua.table()
    G.SlashCmdList.EVERLOOKAUCTIONS("status")
    out = "\n".join(G.PRINTED[i] for i in range(1, len(G.PRINTED) + 1))
    check("2 scans waiting to upload" in out, f"/eah status lists them: {out}")
    check("version" in out and "Alliance: 0 prices, no full update yet" in out, f"/eah status: version, one line a house: {out}")
    check("auction API" not in out and "kept for EverlookDB.com" not in out, f"technical lines are in /eah debug: {out}")
    G.PRINTED = lua.table()
    ns.debugReport()
    out = "\n".join(G.PRINTED[i] for i in range(1, len(G.PRINTED) + 1))
    check("full scans kept for EverlookDB.com: 3" in out and "auction API" in out and "2 scans from this session" in out,
          f"/eah debug has the technical lines: {out}")
    return failures


SCAN_SETUP = """
function GetBuildInfo() return "1.15", "1" end
TIMERS = {}
C_Timer = { After = function(secs, fn) TIMERS[#TIMERS + 1] = { at = MOCK_CLOCK + secs, fn = fn } end }
MOCK_CLOCK = 0
function GetTime() return MOCK_CLOCK end
-- runs every timer due within secs, in time order
function ADVANCE(secs)
  local stop = MOCK_CLOCK + secs
  while true do
    local best
    for i, t in ipairs(TIMERS) do if t.at <= stop and (not best or t.at < TIMERS[best].at) then best = i end end
    if not best then break end
    local t = table.remove(TIMERS, best)
    if t.at > MOCK_CLOCK then MOCK_CLOCK = t.at end
    t.fn()
  end
  MOCK_CLOCK = stop
end
-- the replicate list: 3000 auctions of 30 items; items 1..10 load only LOADS_AFTER seconds after they are asked for
AUCTIONS, LOADED, ASKED, CLEARED, REPLICATED = {}, {}, {}, false, 0
LOADS_AFTER = 1000
for i = 0, 2999 do AUCTIONS[i] = { id = 1 + i % 30, count = 2, buyout = 100 + i % 7 } end
for id = 11, 30 do LOADED[id] = true end
C_Item.RequestLoadItemDataByID = function(id) ASKED[id] = ASKED[id] or MOCK_CLOCK end
local function loaded(id)
  return LOADED[id] or (ASKED[id] and MOCK_CLOCK - ASKED[id] >= LOADS_AFTER)
end
C_AuctionHouse = {
  ReplicateItems = function() REPLICATED = REPLICATED + 1 end,
  GetNumReplicateItems = function() return 3000 end,
  GetReplicateItemInfo = function(i)
    local a = not CLEARED and AUCTIONS[i]
    if not a then return nil end
    return "x", 1, a.count, 1, false, 1, nil, 10, 1, a.buyout * a.count, 0, false, nil, nil, nil, false, a.id
  end,
  GetReplicateItemLink = function(i)
    local a = not CLEARED and AUCTIONS[i]
    if a and loaded(a.id) then return "|cffffffff|Hitem:" .. a.id .. "::::::::::::|h[Item " .. a.id .. "]|h|r" end
  end,
  GetReplicateItemTimeLeft = function() return 2 end,
}
"""


def scan_lua(extra=""):
    """The core with a fake replicate list, timers that run when ADVANCE says and a stand-in skin; the auction house
    is open. `extra` is Lua run before the addon loads (a different realm, saved data)."""
    lua = lua51.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(source_of("tests/mock.lua"))
    lua.execute(CORE_SETUP)
    lua.execute(SCAN_SETUP)
    if extra:
        lua.execute(extra)
    lua.execute("local h = EverlookAuctionsDB.houses['Test-Alliance']; if h then h.items[99] = { 5, 1, 1, 1 } end")
    run = lua.eval("function(src, name, ...) local f = assert(loadstring(src, name)); return f(...) end")
    ns = lua.table()
    run(source_of("EverlookDBAuctions.lua"), "EverlookDBAuctions.lua", "EverlookDBAuctions", ns)
    lua.eval("""function(ns)
      local mk = CreateFrame
      function CreateFrame(...) local f = mk(...); f.GetWidth = function() return 100 end; return f end
      local color = { 1, 1, 1 }
      ns.T = setmetatable({ places = setmetatable({}, { __index = function() return color end }) },
        { __index = function() return color end })
      ns.UI = setmetatable({ hex = function() return "|cffffffff" end },
        { __index = function() return function() return CreateFrame("Frame") end end })
    end""")(ns)
    fire = lua.eval("function(e, a) for _, f in ipairs(MOCK_FRAMES) do if f.scripts.OnEvent then f.scripts.OnEvent(f, e, a) end end end")
    fire("ADDON_LOADED", "EverlookDBAuctions")
    lua.execute("AuctionHouseFrame = CreateFrame('Frame', 'AuctionHouseFrame')")
    fire("AUCTION_HOUSE_SHOW")
    return lua, ns, fire


def printed(lua):
    P = lua.globals().PRINTED
    return "\n".join(P[i] for i in range(1, len(P) + 1))


def realm_repair():
    """The realm at scan time: an empty, missing or secret GetRealmName() and a GetRealmID() of 0 (a fresh install,
    report K46304) never save a scan with an empty realm when anything else names it (the character's GUID, the realm
    remembered from an earlier session); with nothing at all the scan is marked and put right at the next login, as
    are scans older versions saved with realm "" and ID 0, but only when the account names no other realm."""
    failures = []

    def check(cond, what):
        if not cond:
            failures.append("realm: " + what)

    def scan_now(lua, fire):
        G = lua.globals()
        G.LOADS_AFTER = 1
        G.ADVANCE(1)
        G.SlashCmdList.EVERLOOKAUCTIONS("scan")
        fire("REPLICATE_ITEM_LIST_UPDATE")
        G.ADVANCE(30)
        db = G.EverlookAuctionsDB
        return db, db.scans[len(db.scans)]

    def status(ns):
        lines = ns.statusLines()
        return [lines[i] for i in range(1, len(lines) + 1)]

    KNOWN = 'function GetRealmName() return "Test" end; function GetRealmID() return 6946 end'

    def login_with(saved_lua, setup):
        """A new session over saved data (Lua source of EverlookAuctionsDB), the realm as `setup` says."""
        lua, ns, fire = scan_lua(setup + "\nEverlookAuctionsDB = " + saved_lua)
        fire("PLAYER_LOGIN")
        fire("PLAYER_ENTERING_WORLD")
        return lua, ns, lua.globals().EverlookAuctionsDB

    # the game knows its realm: name and ID as it says
    lua, ns, fire = scan_lua(KNOWN)
    db, sc = scan_now(lua, fire)
    check(sc.realm == "Test" and sc.realmID == 6946 and sc.needsRealm is None, f"a known realm is saved: {sc.realm} {sc.realmID}")
    check(db.realms[6946].name == "Test", "the realm is remembered for the account")

    # realm ID 0, the GUID names it
    lua, ns, fire = scan_lua('function GetRealmName() return "Test" end; function GetRealmID() return 0 end;'
                             'function UnitGUID() return "Player-6946-07376D91" end')
    db, sc = scan_now(lua, fire)
    check(sc.realm == "Test" and sc.realmID == 6946 and sc.needsRealm is None, f"ID 0: taken from the GUID ({sc.realmID})")

    # empty name and ID 0 (what K46304 saved), but an earlier session remembered this realm: named from that
    lua, ns, fire = scan_lua('function GetRealmName() return "" end; function GetRealmID() return 0 end;'
                             'function UnitGUID() return "Player-6946-07376D91" end;'
                             'EverlookAuctionsDB.realms = { [6946] = { name = "Test", norm = "Test" } }')
    db, sc = scan_now(lua, fire)
    check(sc.realm == "Test" and sc.realmID == 6946 and sc.needsRealm is None, f"empty name: the remembered one ({sc.realm})")
    check(db.houses["Test-Alliance"].scanned is not None and db.houses["-Alliance"] is None, "prices go to the realm's house")

    # a secret name, ID 0, nothing else: no empty realm saved, the scan is marked; the house is "?-Alliance"
    NOTHING = ('SECRET = newproxy and newproxy() or {}; function issecretvalue(v) return v == SECRET end;'
               'function GetRealmName() return SECRET end; function GetRealmID() return 0 end')
    lua, ns, fire = scan_lua(NOTHING)
    db, sc = scan_now(lua, fire)
    check(sc.realm is None and sc.realmID is None and sc.needsRealm is True, f"secret name: marked ({sc.realm} {sc.realmID})")
    check(db.houses["?-Alliance"] is not None and db.houses["?-Alliance"].scanned is not None, "prices kept under ?-Alliance")
    check(any("without the realm" in l for l in status(ns)), f"/eah status says a scan waits for its realm: {status(ns)}")

    # nil name too
    lua, ns, fire = scan_lua('function GetRealmName() return nil end; function GetRealmID() return 0 end')
    db, sc = scan_now(lua, fire)
    check(sc.realm is None and sc.needsRealm is True, "nil name: marked")

    # the next login knows the realm: the scan K46304 saved (realm "", ID 0) and its house are put right
    OLD = """{ version = 2, houses = {
        ["-Alliance"] = { items = { [5] = { 100, 1, 1, 8639000 } }, days = { [2590] = { [5] = 100 } }, scanned = 8639000 } },
      scans = { { region = "EU", realm = "", realmID = 0, side = "Alliance", at = 8639000, auctions = 10, rows = {} } } }"""
    lua, ns, db = login_with(OLD, KNOWN)
    sc = db.scans[1]
    check(sc.realm == "Test" and sc.realmID == 6946 and sc.realmFixed is True, f"old scan repaired: {sc.realm} {sc.realmID}")
    check(db.houses["-Alliance"] is None and db.houses["Test-Alliance"] is not None
          and db.houses["Test-Alliance"]["items"][5] is not None, "its house moves to Test-Alliance with its prices")
    check(not any("without the realm" in l for l in status(ns)), "nothing left for /eah status")

    # a marked scan of this version, and a house already there: merged, the newer price wins
    MARKED = """{ version = 2, houses = {
        ["?-Alliance"] = { items = { [5] = { 90, 1, 1, 8639500 }, [6] = { 7, 1, 1, 8639500 } }, days = {}, scanned = 8639500 },
        ["Test-Alliance"] = { items = { [5] = { 100, 1, 1, 8639000 } }, days = {}, scanned = 8639000 } },
      scans = { { region = "EU", side = "Alliance", needsRealm = true, at = 8639500, auctions = 10, rows = {} } } }"""
    lua, ns, db = login_with(MARKED, KNOWN)
    h = db.houses["Test-Alliance"]
    check(db.scans[1].realm == "Test" and db.scans[1].needsRealm is None, "marked scan repaired")
    check(db.houses["?-Alliance"] is None and h["items"][5][1] == 90 and h["items"][6] is not None and h.scanned == 8639500,
          "houses merged, newer prices kept")

    # the realm still unknown at login: left as it is
    lua, ns, db = login_with(OLD, 'function GetRealmName() return "" end; function GetRealmID() return 0 end')
    check(db.scans[1].realmFixed is None and db.houses["-Alliance"] is not None, "realm unknown at login: nothing changed")

    # the name still unknown at login, but the character's GUID gives the ID: the scan gets the ID (the site names the
    # realm from it), the house keeps its key until a login knows the name
    lua, ns, db = login_with(OLD, 'function GetRealmName() return "" end; function GetRealmID() return 0 end;'
                             'function UnitGUID() return "Player-6946-07376D91" end')
    check(db.scans[1].realmID == 6946 and db.scans[1].realmFixed is True and db.houses["-Alliance"] is not None,
          f"ID from the GUID at login: {db.scans[1].realmID}")
    check(not any("without the realm" in l for l in status(ns)), "a scan with its ID isn't listed as unplaceable")

    # ambiguous: the account has played on another realm too: left alone, /eah status says so
    OTHER = """{ version = 2, houses = { ["Other-Alliance"] = { items = {}, days = {} },
        ["-Alliance"] = { items = {}, days = {} } },
      scans = { { region = "EU", realm = "", realmID = 0, side = "Alliance", at = 8639000, auctions = 10, rows = {} } } }"""
    lua, ns, db = login_with(OTHER, KNOWN)
    check(db.scans[1].realmFixed is None and db.scans[1].realm == "" and db.houses["-Alliance"] is not None,
          "another realm known: the scan is left alone")
    check(any("other realms" in l for l in status(ns)), f"/eah status says it can't be told which realm: {status(ns)}")

    # the other side's scan: left for a character of that side
    HORDE = OLD.replace('side = "Alliance"', 'side = "Horde"')
    lua, ns, db = login_with(HORDE, KNOWN)
    check(db.scans[1].realmFixed is None, "a Horde scan isn't given to an Alliance character's login")

    # a scan that names its realm ID: named when it is this realm's (other realms or not), left when it isn't
    BYID = OTHER.replace('realm = "", realmID = 0', 'realm = "", realmID = 6946')
    lua, ns, db = login_with(BYID, KNOWN)
    check(db.scans[1].realm == "Test" and db.scans[1].realmFixed is True, "its ID is this realm's: named")
    # client build 71037 (2026-11-21): GetRealmName() and GetNormalizedRealmName() say "", GetRealmID() the ID, and
    # UnitFullName's "realm" is part of the character's name: the name comes from our own older scans, never from that
    B71037 = ('function GetRealmName() return "" end; function GetNormalizedRealmName() return "" end;'
              'function GetRealmID() return 6946 end; function UnitFullName() return "Isa", "Insidejob" end;')
    lua, ns, fire = scan_lua(B71037 + 'EverlookAuctionsDB.scans = { { region = "EU", realm = "Test", realmID = 6946,'
                             ' side = "Alliance", at = 8630000, auctions = 5, packed = "" } }')
    db, sc = scan_now(lua, fire)
    check(sc.realm == "Test" and sc.realmID == 6946 and sc.realmNormalized == "Test" and sc.needsRealm is None,
          f"build 71037: named from an older scan ({sc.realm}, {sc.realmNormalized})")
    check(db.houses["Test-Alliance"].scanned is not None and db.houses["?-Alliance"] is None, "build 71037: the realm's own house")
    # ... or from the Price Feed's houses
    lua, ns, fire = scan_lua(B71037 + 'EverlookDBAuctionsShared = { version = 1, houses = { ["EU-6946-Alliance"] = {'
                             ' realm = "Test", realmID = 6946, side = "Alliance", at = 1, rows = {} } } }')
    db, sc = scan_now(lua, fire)
    check(sc.realm == "Test" and sc.needsRealm is None, f"build 71037: named from the Price Feed ({sc.realm})")

    # the user's own file after 0.16.0 on build 71037: good older scans, then one with the ID only (and a wrong
    # normalized name), prices under "-Alliance" and "?-Alliance": all put right at login, the game saying no name
    MINE = """{ version = 2, houses = {
        ["Test-Alliance"] = { items = { [5] = { 100, 1, 1, 8630000 } }, days = {}, scanned = 8630000 },
        ["-Alliance"] = { items = { [6] = { 50, 1, 1, 8638000 } }, days = {}, scanned = 8638000 },
        ["?-Alliance"] = { items = { [5] = { 90, 1, 1, 8639000 } }, days = {}, scanned = 8639000 } },
      scans = { { region = "EU", realm = "Test", realmID = 6946, side = "Alliance", at = 8630000, auctions = 5, packed = "" },
        { region = "EU", realmID = 6946, realmNormalized = "Insidejob", needsRealm = true, side = "Alliance", at = 8639000,
          auctions = 10, rows = {} } } }"""
    lua, ns, db = login_with(MINE, B71037)
    sc = db.scans[2]
    h = db.houses["Test-Alliance"]
    check(sc.realm == "Test" and sc.realmNormalized == "Test" and sc.needsRealm is None and sc.realmFixed is True,
          f"ID-only scan named at login: {sc.realm} {sc.realmNormalized}")
    check(db.houses["-Alliance"] is None and db.houses["?-Alliance"] is None and h["items"][5][1] == 90
          and h["items"][6] is not None and h.scanned == 8639000, "both nameless houses merged into the realm's")

    # trimming: a scan saved without its name is the same house as the named ones (one newest kept unpacked)
    lua, ns, fire = scan_lua(KNOWN)
    scans = lua.eval('''{ { realm = "Test", realmID = 6946, side = "Alliance", at = 8630000, rows = { ["1:0"] = "1,1,1,1,1,0,0,0,0,0,1," } },
      { realmID = 6946, side = "Alliance", at = 8639000, rows = { ["1:0"] = "1,1,1,1,1,0,0,0,0,0,1," } } }''')
    ns.trimScans(scans, 8640000)
    check(scans[1].rows is None and scans[2].rows is not None, "the older scan of the same realm ID is packed")

    BYID2 = OLD.replace('realmID = 0', 'realmID = 77')
    lua, ns, db = login_with(BYID2, KNOWN)
    check(db.scans[1].realmFixed is None and db.scans[1].realmID == 77, "another realm's ID: left for the site")
    return failures


def full_scan():
    """Price updates: once the auction list has arrived the update always finishes, also when the auction house
    closes while item details load (the retries are skipped, unlinked auctions count as their plain version); closed
    before any answer gives the wait back; automatic updates stay out of chat."""
    failures = []

    def check(cond, what):
        if not cond:
            failures.append("full scan: " + what)

    # automatic: waits 8 s after opening, runs quietly, and finishes after the AH closes during the item retries
    lua, ns, fire = scan_lua()
    G = lua.globals()
    G.ADVANCE(7)
    check(G.REPLICATED == 0, "no automatic update in the first seconds after opening")
    G.ADVANCE(2)
    check(G.REPLICATED == 1, f"automatic update 8 s after opening ({G.REPLICATED})")
    fire("REPLICATE_ITEM_LIST_UPDATE")
    G.ADVANCE(1)           # first read done, waiting 2 s before the first retry
    check(ns.scanning(), "still loading item details")
    G.CLEARED = True       # the list goes with the closed auction house
    fire("AUCTION_HOUSE_CLOSED")
    G.ADVANCE(1)
    db = G.EverlookAuctionsDB
    h = db.houses["Test-Alliance"]
    check(not ns.scanning(), "closing the auction house finishes the update")
    check(h.scanned is not None and h.why is None, f"the update counts as done ({h.why})")
    check(len(db.scans) == 1 and db.scans[1].auctions == 3000, "the scan is kept with every auction")
    sc = db.scans[1]
    check(sc.noLink == 1000, f"auctions without a link counted: {sc.noLink}")
    row = sc.rows["1:0"]
    check(row is not None and row.split(",")[3] == "200", f"an unlinked item counts as its plain version: {row}")
    check(h["items"][1] is not None and h["items"][1][2] == 200 and h["items"][99] is None, "tooltip prices from the new scan")
    check("done" in h.log[1].how and "closed" in h.log[1].how, f"the log says it finished after closing: {h.log[1].how}")
    check("full scan done" not in printed(lua), f"an automatic update says nothing in chat: {printed(lua)}")

    # by hand, AH open all along: the retries load the items, and chat says it is done
    lua, ns, fire = scan_lua()
    G = lua.globals()
    G.LOADS_AFTER = 1
    G.ADVANCE(1)
    G.SlashCmdList.EVERLOOKAUCTIONS("scan")
    fire("REPLICATE_ITEM_LIST_UPDATE")
    G.ADVANCE(30)
    db = G.EverlookAuctionsDB
    check(not ns.scanning() and len(db.scans) == 1, "a manual update finishes")
    check(db.scans[1].noLink == 0 and db.scans[1].rows["1:0"] is not None, f"items loaded by the retries: {db.scans[1].noLink}")
    check("full scan done: 3000 auctions" in printed(lua), f"a manual update says so in chat: {printed(lua)}")
    # the bar's item count: counted once, then kept up as prices come in
    h = db.houses["Test-Alliance"]
    check(ns.countItems(h) == 30, f"30 items priced: {ns.countItems(h)}")
    ns.noteLivePrice(500, lua.eval("{ { unit = 7, qty = 1 } }"))
    ns.noteLivePrice(1, lua.eval("{ { unit = 7, qty = 1 } }"))
    check(ns.countItems(h) == 31, f"a new item counts, a known one doesn't: {ns.countItems(h)}")

    # closed while the first read is under way and the list goes with it: thrown away, the old prices stay
    lua, ns, fire = scan_lua()
    G = lua.globals()
    G.SlashCmdList.EVERLOOKAUCTIONS("scan")
    fire("REPLICATE_ITEM_LIST_UPDATE")    # reads the first 1000; the next slice waits for the next frame
    G.CLEARED = True
    fire("AUCTION_HOUSE_CLOSED")
    G.ADVANCE(1)
    h = G.EverlookAuctionsDB.houses["Test-Alliance"]
    check(not ns.scanning() and h.why == "closed" and h["items"][99] is not None and len(G.EverlookAuctionsDB.scans) == 0,
          f"a half-read list is thrown away ({h.why})")

    # closed while the first read is under way but the list is still readable: it finishes
    lua, ns, fire = scan_lua()
    G = lua.globals()
    G.LOADS_AFTER = 0
    G.SlashCmdList.EVERLOOKAUCTIONS("scan")
    fire("REPLICATE_ITEM_LIST_UPDATE")
    fire("AUCTION_HOUSE_CLOSED")
    G.ADVANCE(1)
    check(not ns.scanning() and len(G.EverlookAuctionsDB.scans) == 1, "a list still readable after closing is finished")

    # closed before any answer: the wait is given back
    lua, ns, fire = scan_lua()
    G = lua.globals()
    G.SlashCmdList.EVERLOOKAUCTIONS("scan")
    h = G.EverlookAuctionsDB.houses["Test-Alliance"]
    check(h.tried is not None, "a request starts the wait")
    fire("AUCTION_HOUSE_CLOSED")
    check(h.tried is None and not ns.scanning(), "closed before an answer: the wait is given back")
    check(h.log[1].how == "AH closed while waiting", "and logged")

    # automatic, no answer: quiet in chat
    lua, ns, fire = scan_lua()
    G = lua.globals()
    G.ADVANCE(9)
    G.ADVANCE(100)
    check(not ns.scanning() and "didn't send" not in printed(lua), f"an automatic update with no answer is quiet: {printed(lua)}")

    # odd rows never fail the update: a count that isn't a number, a buyout that is a table, an item whose below-vendor
    # check throws; each is skipped and the rest is saved
    lua, ns, fire = scan_lua()
    G = lua.globals()
    G.LOADS_AFTER = 0
    lua.execute("AUCTIONS[5] = { id = 6, count = '2', buyout = 100 }; AUCTIONS[7] = { id = 8, count = 2, buyout = {} }")
    lua.execute("local get = C_AuctionHouse.GetReplicateItemInfo; C_AuctionHouse.GetReplicateItemInfo = function(i) "
                "local a = AUCTIONS[i]; if type(a.buyout) == 'table' then return 'x', 1, 2, 1, false, 1, nil, 10, 1, a.buyout, 0, "
                "false, nil, nil, nil, false, a.id end; return get(i) end")
    ns.vendor = lua.eval("{ scanDeals = function(id) if id == 3 then error('boom') end end }")
    G.SlashCmdList.EVERLOOKAUCTIONS("scan")
    fire("REPLICATE_ITEM_LIST_UPDATE")
    G.ADVANCE(30)
    db = G.EverlookAuctionsDB
    check(not ns.scanning() and len(db.scans) == 1, "an update with odd rows still finishes")
    sc = db.scans[1] if len(db.scans) else None
    check(sc is not None and sc.rows["3:0"] is not None and sc.rows["1:0"] is not None, "every item is still saved")
    h = db.houses["Test-Alliance"]
    check(h["items"][8] is not None and h["items"][3] is not None, "items with an odd auction keep their other auctions")

    # an update stopped by something unexpected doesn't block the next one until a /reload
    lua, ns, fire = scan_lua()
    G = lua.globals()
    G.SlashCmdList.EVERLOOKAUCTIONS("scan")
    fire("REPLICATE_ITEM_LIST_UPDATE")
    lua.execute("TIMERS = {}")     # the next slice never runs
    check(ns.scanning(), "running")
    G.ADVANCE(60)
    check(not ns.dropStalled() and ns.scanning(), "a minute without progress is not yet stalled")
    G.ADVANCE(70)
    check(ns.dropStalled() and not ns.scanning(), "two minutes without progress: let go")
    h = G.EverlookAuctionsDB.houses["Test-Alliance"]
    check(h.log[1].how == "stopped (no progress)" and h["items"][99] is not None, f"logged, prices kept: {h.log[1].how}")
    check("stopped partway" in ns.unfinishedText(h), "the bar says it stopped")
    return failures

def item_cache():
    """Item details are saved as one compact line per item (old tables are packed at first use) and read back the
    same."""
    failures = []

    def check(cond, what):
        if not cond:
            failures.append("item cache: " + what)

    lua = lua51.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(source_of("tests/mock.lua"))
    ns = lua.table()
    run = lua.eval("function(src, name, ...) local f = assert(loadstring(src, name)); return f(...) end")
    run(VENDOR_SETUP, "setup", ns)
    for name in ["Skin.lua", "Vendor.lua", "Search.lua"]:
        run(source_of(name), name, "EverlookDBAuctions", ns)
    db = ns.db()
    c = ns.itemInfo(3000)
    saved = db.itemInfo[3000]
    check(isinstance(saved, str) and saved == "2^20^15^Weapon^Swords^WEAPON^1^500^1^Old Sword",
          f"an old table is packed into one line: {saved!r}")
    got = [c[i] for i in range(1, 11)]
    check(got == ["Old Sword", 2, 20, 15, "Weapon", "Swords", "INVTYPE_WEAPON", 1, 500, 1], f"read back the same: {got}")
    c2 = ns.itemInfo(2589)
    check(c2[7] == "" and c2[1] == "Linen Cloth" and c2[10] == 20, "an item with no slot")
    check(lua.eval("rawequal")(ns.itemInfo(3000), c), "read once per session")
    odd = ns.unpackItem(ns.packItem(lua.eval('{ "Odd ^ Name: of the Bear", 3, 1, 0, "A", "B", "", 7, 0, 5 }')))
    check(odd[1] == "Odd  Name: of the Bear" and odd[2] == 3 and odd[10] == 5, f"a ^ in a name can't break the line: {odd[1]}")
    lua.execute("C_Item.GetItemInfo = function(id) if id == 555 then return 'New Thing', nil, 1, 5, 0, 'Trade Goods', 'Cloth', 20, '', 9, 3 end end")
    n = ns.itemInfo(555)
    check(n[1] == "New Thing" and db.itemInfo[555] == "1^5^0^Trade Goods^Cloth^^9^3^20^New Thing",
          f"a newly loaded item is saved packed: {db.itemInfo[555]!r}")
    return failures

def commodity_note():
    """Blizzard's commodity list: what a click there sets, and the line that says so."""
    lua = lua51.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(source_of("tests/mock.lua"))
    ns = lua.table()
    run = lua.eval("function(src, name, ...) local f = assert(loadstring(src, name)); return f(...) end")
    run(VENDOR_SETUP, "setup", ns)
    for name in ["Skin.lua", "Vendor.lua", "CommodityNote.lua"]:
        run(source_of(name), name, "EverlookDBAuctions", ns)
    N = ns.commodityNote
    failures = []

    def check(cond, what):
        if not cond:
            failures.append("commodity note: " + what)

    # the Bolt of Woolen Cloth list from the report: a click on 4s 99c set Quantity to 655
    res = lua.eval("""{ {quantity=27,unitPrice=476}, {quantity=37,unitPrice=477}, {quantity=21,unitPrice=478},
      {quantity=10,unitPrice=479}, {quantity=88,unitPrice=489}, {quantity=84,unitPrice=490}, {quantity=37,unitPrice=494},
      {quantity=58,unitPrice=497}, {quantity=293,unitPrice=499}, {quantity=3,unitPrice=500} }""")
    got, cost, top, rows = N.cost(res, 655)
    want = 27*476 + 37*477 + 21*478 + 10*479 + 88*489 + 84*490 + 37*494 + 58*497 + 293*499
    check(got == 655 and cost == want and top == 499 and rows == 9, f"655 cheapest first: {got} {cost} {top} {rows}")
    got, cost, top, rows = N.cost(res, 20)
    check(got == 20 and cost == 20*476 and rows == 1, "inside the first row: one row")
    got, _, _, _ = N.cost(res, 10000)
    check(got == 658, "more than for sale: only what is listed")
    t = N.text(655, want, 499, 9)
    check("655" in t and "9 rows" in t and "cheapest first" in t, f"the line: {t}")
    return failures

def purchases():
    """AH purchases: what is logged from the auction house's buy calls, the marks, and a recipe's cost per craft."""
    lua = lua51.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(source_of("tests/mock.lua"))
    lua.execute("""
      MOCK_TIME = 1000; function time() return MOCK_TIME end
      function date(fmt, t) return 'd' .. tostring(t) end
      UISpecialFrames = {}; tinsert = table.insert
      function IsShiftKeyDown() return false end
      MOCK_RESULTS = { { auctionID = 77, itemLink = '|cff1eff00|Hitem:6218::|h[Runed Copper Rod]|h|r', buyoutAmount = 900 } }
      C_AuctionHouse = {
        PlaceBid = function() end, StartCommoditiesPurchase = function() end, ConfirmCommoditiesPurchase = function() end,
        GetNumItemSearchResults = function() return #MOCK_RESULTS end,
        GetItemSearchResultInfo = function(_, i) return MOCK_RESULTS[i] end,
      }
    """)
    ns = lua.table()
    DB = lua.table()
    lua.globals().MOCK_DB = DB
    ns.db = lua.eval("function() return MOCK_DB end")
    ns.money = lua.eval("function(c) return tostring(c) .. 'c' end")
    ns.num = lua.eval("function(n) return tostring(n) end")
    ns.house = lua.eval("function() return 'Realm-Alliance' end")
    ns.itemFor = lua.eval("function(id) local p = MOCK_PRICES[id]; return p and { p, 1, 1, MOCK_TIME } end")
    run = lua.eval("function(src, name, ...) local f = assert(loadstring(src, name)); return f(...) end")
    run(source_of("Skin.lua"), "Skin.lua", "EverlookDBAuctions", ns)
    for name in ["Libs/LibStub/LibStub.lua", "Libs/EverlookUI/EverlookUI.lua", "PurchaseLog.lua", "Purchases.lua", "LootCards.lua"]:
        run(source_of(name), name, "EverlookDBAuctions", ns)
    P = ns.purchaseLog
    G = lua.globals()
    fire = lua.eval("function(e, a, b) for _, f in ipairs(MOCK_FRAMES) do if f.scripts.OnEvent then f.scripts.OnEvent(f, e, a, b) end end end")
    failures = []

    def check(cond, what):
        if not cond:
            failures.append("purchases: " + what)

    AH = G.C_AuctionHouse
    # an item: seen in the search results, bought out, then the auction house says it went through
    fire("ITEM_SEARCH_RESULTS_UPDATED", lua.eval("{ itemID = 6218 }"))
    AH.PlaceBid(77, 900)
    check(DB.bought is None or len(DB.bought) == 0, "nothing logged before the auction house answers")
    fire("AUCTION_HOUSE_PURCHASE_COMPLETED", 77)
    check(len(DB.bought) == 1 and DB.bought[1].id == 6218 and DB.bought[1].c == 900 and DB.bought[1].q == 1
          and DB.bought[1].h == "Realm-Alliance" and "Runed Copper Rod" in DB.bought[1].link, "an item buyout is logged")
    # a bid below the buyout is not
    AH.PlaceBid(77, 500)
    fire("AUCTION_HOUSE_PURCHASE_COMPLETED", 77)
    check(len(DB.bought) == 1, "a bid isn't logged")
    # a commodity: 20 Copper Bars for 700, quoted then confirmed
    AH.StartCommoditiesPurchase(2840, 20)
    fire("COMMODITY_PRICE_UPDATED", 35, 700)
    AH.ConfirmCommoditiesPurchase(2840, 20)
    fire("COMMODITY_PURCHASE_SUCCEEDED")
    check(len(DB.bought) == 2 and DB.bought[2].id == 2840 and DB.bought[2].q == 20 and DB.bought[2].c == 700,
          "a commodity purchase is logged with its quoted total")
    # a failed one is not
    AH.StartCommoditiesPurchase(2840, 5)
    fire("COMMODITY_PRICE_UPDATED", 40, 200)
    AH.ConfirmCommoditiesPurchase(2840, 5)
    fire("COMMODITY_PURCHASE_FAILED")
    fire("COMMODITY_PURCHASE_SUCCEEDED")
    check(len(DB.bought) == 2, "a failed commodity purchase isn't logged")
    # another lot of bars, dearer: 10 for 500
    AH.StartCommoditiesPurchase(2840, 10)
    fire("COMMODITY_PRICE_UPDATED", 50, 500)
    AH.ConfirmCommoditiesPurchase(2840, 10)
    fire("COMMODITY_PURCHASE_SUCCEEDED")
    check(len(DB.bought) == 3, "second lot logged")

    # the recipe: 4 Copper Bars + 1 Weak Flux (no purchase; AH price none) + 1 Copper Rod (AH 120)
    w = lua.eval("{ recipeID = 9, name = 'Runed Copper Rod', mats = { { 2840, 4, 35 }, { 6217, 1, 120 }, { 2880, 1 } }, out = 6218, makes = 1 }")
    ns.purchases.noteRecipe(w, True)
    check(len(DB.recipes) == 1 and DB.boughtRecipe == 9 and DB.recipes[1].mats[1][2] == 4, "the recipe is remembered")
    ns.purchases.noteRecipe(w, False)
    check(len(DB.recipes) == 1, "the same recipe once")
    priceOf = lua.eval("function(id) return MOCK_PRICES[id] end")
    c = P.cost(DB.bought, DB.recipes[1], priceOf)
    check(c.mats[1].src == "ah" and c.paidAll is False and c.crafts is None, "nothing marked: AH prices")
    # mark both bar lots: 30 bars for 1200 = 40 each
    DB.bought[2].m = True
    DB.bought[3].m = True
    c = P.cost(DB.bought, DB.recipes[1], priceOf)
    m1 = c.mats[1]
    check(m1.src == "paid" and m1.unit == 40 and m1.have == 30 and m1.lots == 2, f"marked bars average 40 each: {m1.unit}")
    check(c.mats[2].src == "ah" and c.mats[3].src is None and c.unpriced == 1, "rod from the AH, flux without a price")
    check(c.total == 4 * 40 + 120, f"cost per craft {c.total}")
    n, q, cc = P.markedTotal(DB.bought)
    check(n == 2 and q == 30 and cc == 1200, "marked totals")
    # a recipe of bars only: 30 bars cover 7 crafts
    only = lua.eval("{ id = 10, mats = { { 2840, 4 } } }")
    c = P.cost(DB.bought, only, priceOf)
    check(c.paidAll is True and c.crafts == 7 and c.total == 160, f"bars only: {c.crafts} crafts, {c.total}")

    # the view: newest first, filter, marked only
    nameOf = lua.eval("function(e) return MOCK_ITEMS[e.id] end")
    v = P.view(DB.bought, "", False, nameOf)
    check(len(v) == 3 and v[1].c == 500 and v[3].c == 900, "newest first")
    check(len(P.view(DB.bought, "rod", False, nameOf)) == 1, "filter by name")
    check(len(P.view(DB.bought, "", True, nameOf)) == 2, "marked only")

    # the window opens and draws (the mock has no real layout; this catches errors)
    try:
        ns.purchases.open()
        f = G.EverlookAuctionsPurchases
        check(f.shown and "Marked: 2" in f.sum.text, f"window shows the marked total: {f.sum.text}")
        rows = [f.rows[i] for i in range(1, len(f.rows) + 1)]
        rows[0].scripts.OnClick(rows[0])
        check(DB.bought[3].m is None, "a click unmarks")
        check("Marked: 1" in f.sum.text, "the total follows")
    except Exception as e:
        failures.append(f"purchases: window error {e}")

    # income: an auction sold (net 950 of 1000), another mail with gold, and the same mail reached twice
    lua.execute("""
      GetTime = function() return MOCK_TIME end
      MOCK_MAIL = {
        { 'Auction House', 'Auction successful: Runed Copper Rod', 950, 'seller', 'Runed Copper Rod', 1000, 2 },
        { 'Somebody', 'hi', 500 },
      }
      function GetInboxHeaderInfo(i) local m = MOCK_MAIL[i]; return nil, nil, m[1], m[2], m[3], 0, 29 end
      function GetInboxInvoiceInfo(i) local m = MOCK_MAIL[i]
        if m[4] then return m[4], m[5], nil, m[6], 0, 0, 0, 0, 0, 0, m[7] end end
      C_Item.GetItemInfoInstant = function(name) for id, n in pairs(MOCK_ITEMS) do if n == name then return id end end end
    """)
    B = ns.purchases
    # a sale the game told us about waits as "in your mail" until its money is taken
    B.noteSold("Runed Copper Rod", 1800, 2)
    B.noteSold("Copper Bar", None, None)
    check(len(DB.soldPending) == 2 and DB.soldPending[1].est == 1800, "two sales waiting in the mail")
    B.takeMail(1)
    check(len(DB.soldPending) == 1 and DB.soldPending[1].name == "Copper Bar", "taking the rod's money settles the rod only")
    B.takeMail(1)
    B.takeMail(2)
    inc = DB.income
    check(len(inc) == 2, f"two mails, one logged once: {len(inc)}")
    check(inc[1].kind == "sale" and inc[1].c == 950 and inc[1].q == 2 and inc[1].gross == 1000 and inc[1].id == 6218,
          "a sale: net, count, what the buyer paid, the item")
    check(inc[2].kind == "mail" and inc[2].c == 500 and inc[2].name is None, "other gold: the amount, no sender or subject")
    for k in inc[2].keys():
        check(k in ("c", "kind", "t", "h", "q"), f"no names kept in a mail entry: {k}")
    check(P.sum(inc) == 1450, "income sum")

    # the recipes you know, and what crafting one costs now: Runed Copper Rod = Copper Rod 120 + 4 bars 35 + flux (no price)
    lua.execute("""
      C_TradeSkillUI = {
        GetAllRecipeIDs = function() return { 9, 11 } end,
        GetRecipeInfo = function(id) return { name = id == 9 and 'Runed Copper Rod' or 'Copper Bar', learned = true } end,
        GetRecipeSchematic = function(id)
          if id == 9 then return { name = 'Runed Copper Rod', outputItemID = 6218, quantityMin = 1, quantityMax = 1,
            reagentSlotSchematics = { { quantityRequired = 1, reagents = { { itemID = 6217 } } },
              { quantityRequired = 4, reagents = { { itemID = 2840 } } } } } end
          return { name = 'Copper Bar', outputItemID = 2840, quantityMin = 1, quantityMax = 1,
            reagentSlotSchematics = { { quantityRequired = 1, reagents = { { itemID = 2770 } } } } }
        end,
      }
    """)
    B.readRecipes()
    cost, missing, _, _ = B.craftNow(6218)
    check(cost == 120 + 4 * 35 and missing == 0, f"crafting a rod now: {cost}")
    cost, missing, _, _ = B.craftNow(2840)
    check(cost is None and missing == 1, "a material without a price: no cost")
    check(B.craftNow(6217)[0] is None, "no recipe: nothing")

    # shift-clicking a recipe link or a craftable item picks it in the window
    B.mode = "income"
    B.linked("|cffffd000|Henchant:11|h[Smelting: Copper Bar]|h|r")
    check(DB.boughtRecipe == 11 and B.mode == "bought", "a recipe link picks that recipe")
    B.linked("|cff1eff00|Hitem:6218::::::::|h[Runed Copper Rod]|h|r")
    check(DB.boughtRecipe == 9, "an item you can craft picks its recipe")
    try:
        B.mode = "income"
        B.render()
        f = G.EverlookAuctionsPurchases
        check("Last 7 days" in f.sum.text, f"the income view sums the week: {f.sum.text}")
        check("1 sold, money waiting in your mail" in f.sub.text, f"the waiting sale is counted: {f.sub.text}")
        # For sale: what the auction house showed, sorted by time left; a sale takes its auction off
        owned = lua.eval("""{ { itemID = 6218, name = 'Runed Copper Rod', qty = 2, unit = 900, left = 7200 },
          { itemID = 2840, name = 'Copper Bar', qty = 20, unit = 35, left = 600 }, { itemID = 2840, name = 'Copper Bar', qty = 5, sold = true } }""")
        B.noteOwned(owned)
        fs = G.EverlookAuctionsCharDB.forSale
        check(len(fs.list) == 2 and fs.list[1].c == 1800, "two auctions up (the sold one isn't), buyout of the whole auction")
        B.mode = "forsale"
        B.render()
        check("Up for sale: 2 auctions" in f.sum.text, f"for sale sum: {f.sum.text}")
        check(B.leftText(fs.list[2]) in ("10m", "9m"), f"time left: {B.leftText(fs.list[2])}")
        B.noteSold("Runed Copper Rod", 1800, 2)
        check(len(fs.list) == 1 and fs.list[1].name == "Copper Bar", "the sold rod is off sale and waits in the mail")
        # Loot: a loot line is parsed, logged with time, and the Looted tab and today's sum show it
        link = "|cff1eff00|Hitem:7909::::::::20:::::|h[Aquamarine]|h|r"
        LC = ns.lootCards
        lk, n, pushed = LC.parseItem("You receive loot: " + link + "x3.")
        check(lk == link and n == 3 and not pushed, f"loot line parsed: {lk} {n}")
        lk, n, pushed = LC.parseItem("You receive item: " + link + ".")
        check(lk == link and n == 1 and pushed is True, "an item given to you is marked as pushed")
        check(LC.parseMoney("You loot 1 Gold, 5 Silver, 3 Copper") == 10503, "money parsed")
        lua.execute("GetRealZoneText = function() return 'Tanaris' end")
        e1 = LC.itemFrom(link, 3); e1["from"] = "Sandfury Shadowcaster"; e1.npc = 5648
        B.noteLoot(e1, link)
        B.noteLoot(lua.eval("{ copper = 250 }"))
        lt = G.EverlookAuctionsCharDB.looted
        check(lt[1].zone == "Tanaris", "the zone is logged")
        check(lt[1]["from"] == "Sandfury Shadowcaster" and lt[1].npc == 5648, "where it came from is logged")
        # a loot window: slot 1 money and slot 2 an item, both from the mob you had targeted
        lua.execute("""
          GetTime = function() return 100 end
          local guid = 'Creature-0-1-2-3-5648-0000ABCD'
          UnitGUID = function(u) if u == 'target' then return guid end end
          UnitName = function(u) if u == 'target' then return 'Sandfury Shadowcaster' end end
          GetNumLootItems = function() return 2 end
          GetLootSourceInfo = function() return guid, 1 end
          GetLootSlotType = function(s) return s == 1 and 2 or 1 end
          GetLootSlotLink = function(s) return s == 2 and '|cff1eff00|Hitem:7909::|h[Aquamarine]|h|r' or nil end
        """)
        fire("PLAYER_TARGET_CHANGED")
        fire("LOOT_OPENED")
        s1 = LC.sourceFor(lua.eval("{ id = 7909 }"))
        s2 = LC.sourceFor(lua.eval("{ copper = 55 }"))
        check(s1 is not None and s1["from"] == "Sandfury Shadowcaster" and s1.npc == 5648, "the item is matched to the mob")
        check(s2 is not None and s2["from"] == "Sandfury Shadowcaster", "the money is matched to the mob")
        check(len(lt) == 2 and lt[1].q == 3 and lt[1].name == "Aquamarine" and lt[2].copper == 250, "two loots logged")
        B.mode = "looted"
        B.render()
        check("Today: 3 items" in f.sum.text, f"loot sum: {f.sum.text}")
        # an expired auction taken from the mail: logged with where it came from, not counted as loot
        lua.execute("""
          GetInboxHeaderInfo = function(i) return nil, nil, 'Auction House', 'Auction expired: Black Silk Pack' end
        """)
        LC.noteMail(1)
        other = LC.notLoot(True)
        check(other is not None and other["from"] == "Expired auction" and other.got == "mail", f"mail item: {other and other['from']}")
        check(LC.notLoot(False) is None, "a real loot line is never taken for mail")
        e3 = LC.itemFrom(link, 5); e3["from"], e3.how, e3.got = other["from"], other.how, other.got
        B.noteLoot(e3, link)
        check(lt[3].got == "mail" and lt[3]["from"] == "Expired auction", "logged as from the mail")
        B.render()
        check("Today: 3 items" in f.sum.text, f"mail items don't count as loot: {f.sum.text}")
    except Exception as e:
        failures.append(f"purchases: income view error {e}")

    # the cap: the oldest go first
    lst = lua.table()
    for i in range(5):
        P.add(lst, lua.eval("function(i) return { id = 1, q = 1, c = i } end")(i + 1), 3)
    check(len(lst) == 3 and lst[1].c == 3, "keeps the newest")
    check(P.add(lst, lua.eval("{ id = 1, q = 0, c = 5 }")) is None, "nothing bought: not logged")
    return failures


def buy_sort():
    """The Buy panel's column sort: from the loaded rows, B.rows left cheapest first."""
    lua = lua51.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(source_of("tests/mock.lua"))
    ns = lua.table()
    run = lua.eval("function(src, name, ...) local f = assert(loadstring(src, name)); return f(...) end")
    run(VENDOR_SETUP, "setup", ns)
    for name in ["Skin.lua", "Vendor.lua", "Buy.lua"]:
        run(source_of(name), name, "EverlookDBAuctions", ns)
    B = ns.buyPanel or ns.buy
    failures = []

    def check(cond, what):
        if not cond:
            failures.append("buy sort: " + what)

    if B is None or B.shownRows is None:
        return ["buy sort: no Buy panel table (ns.buyPanel)"]
    B.rows = lua.eval("{ { unit = 10, qty = 5, left = 100 }, { unit = 20, qty = 1, left = 50 }, { unit = 30, qty = 9 } }")
    B.sortCol, B.sortDesc = "price", False
    check([r.unit for r in B.shownRows().values()] == [10, 20, 30], "cheapest first by default")
    B.sortDesc = True
    check([r.unit for r in B.shownRows().values()] == [30, 20, 10], "price, dearest first")
    B.sortCol, B.sortDesc = "avail", True
    check([r.qty for r in B.shownRows().values()] == [9, 5, 1], "most available first")
    B.sortCol, B.sortDesc = "left", False
    check([r.unit for r in B.shownRows().values()] == [20, 10, 30], "least time left first, unknown last")
    B.sortCol, B.sortDesc = "whole", True
    check([r.unit for r in B.shownRows().values()] == [30, 10, 20], "whole auction")
    check([r.unit for r in B.rows.values()] == [10, 20, 30], "the rows themselves stay cheapest first")
    return failures


def cheer():
    """The sale celebration: the game's message, what it likely sold for, and one banner for sales close together."""
    lua = lua51.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(source_of("tests/mock.lua"))
    lua.execute("""
      ERR_AUCTION_SOLD_S = 'A buyer has been found for your auction of %s.'
      GetTime = function() return 100 end
      MOCK_DB = {}
      MOCK_SELL = { memory = { ['6218:0'] = { p = 900, q = 2 } } }
      C_Item.GetItemInfoInstant = function(name) for id, n in pairs(MOCK_ITEMS) do if n == name then return id end end end
    """)
    ns = lua.table()
    ns.db = lua.eval("function() return MOCK_DB end")
    ns.sellSettings = lua.eval("function() return MOCK_SELL end")
    ns.money = lua.eval("function(c) return tostring(c) .. 'c' end")
    run = lua.eval("function(src, name, ...) local f = assert(loadstring(src, name)); return f(...) end")
    run(source_of("Celebrate.lua"), "Celebrate.lua", "EverlookDBAuctions", ns)
    fire = lua.eval("function(e, a) for _, f in ipairs(MOCK_FRAMES) do if f.scripts.OnEvent then f.scripts.OnEvent(f, e, a) end end end")
    G = lua.globals()
    failures = []

    def check(cond, what):
        if not cond:
            failures.append("cheer: " + what)

    fire("CHAT_MSG_SYSTEM", "You have learned something.")
    check(G.EverlookAuctionsCheer is None or not G.EverlookAuctionsCheer.shown, "another message: nothing")
    fire("CHAT_MSG_SYSTEM", "A buyer has been found for your auction of Runed Copper Rod.")
    f = G.EverlookAuctionsCheer
    check(f is not None and f.shown and f.line.text == "2x Runed Copper Rod" and f.money.text == "for about 1800c",
          f"card: {f and f.line.text} / {f and f.money.text}")
    fire("CHAT_MSG_SYSTEM", "A buyer has been found for your auction of Copper Bar.")
    check(f.line.text == "2 auctions" and f.money.text == "", f"two sales, one unpriced: {f.line.text} / {f.money.text}")
    # the auction house's own notification (Forever writes the chat line itself, without CHAT_MSG_SYSTEM), counted once
    # even when the chat line comes too
    f.shown = False
    G.GetTime = lua.eval("function() return 200 end")
    fire2 = lua.eval("function(e, a, b) for _, fr in ipairs(MOCK_FRAMES) do if fr.scripts.OnEvent then fr.scripts.OnEvent(fr, e, a, b) end end end")
    fire2("AUCTION_HOUSE_SHOW_FORMATTED_NOTIFICATION", 4, "Runed Copper Rod")
    check(f.shown and f.line.text == "2x Runed Copper Rod", f"from the notification: {f.line.text}")
    fire2("CHAT_MSG_SYSTEM", "A buyer has been found for your auction of Runed Copper Rod.")
    check(f.line.text == "2x Runed Copper Rod", f"the same sale's chat line doesn't count again: {f.line.text}")
    fire2("AUCTION_HOUSE_SHOW_FORMATTED_NOTIFICATION", 2, "Runed Copper Rod")
    check(f.line.text == "2x Runed Copper Rod", "another notification (won, outbid...) is no sale")
    f.shown = False
    G.MOCK_DB.cheer = False
    fire("CHAT_MSG_SYSTEM", "A buyer has been found for your auction of Copper Bar.")
    check(not f.shown, "turned off: no banner")
    return failures


def profit():
    """The profit finder (Profit.lua): the cost of a craft with the cheaper of buying and crafting each material, the
    auction house cut, loops (transmutes), unpriced materials, the filters, the shopping list it makes (RecipeList's
    saveCounts) and the API's addShoppingList; then the window over the same data."""
    lua = lua51.LuaRuntime(unpack_returned_tuples=True)
    run = lua.eval("function(src, name, ...) local f = assert(loadstring(src, name)); return f(...) end")
    ns = lua.table()
    run(source_of("RecipeList.lua"), "RecipeList.lua", "EverlookDBAuctions", ns)
    run(source_of("Profit.lua"), "Profit.lua", "EverlookDBAuctions", ns)
    Pr, R = ns.profit, ns.recipeList
    failures = []

    def check(cond, what):
        if not cond:
            failures.append("profit: " + what)

    def seq(t):
        return [t[i] for i in range(1, len(t) + 1)]

    # Linen: cloth 18c, bolt on the AH 95c (crafting one from 2 cloth is 36c), thread 12c; a bag of 3 bolts + 3 thread
    # sells for 520c. Fire and Earth: a transmute loop. Wood has no price.
    lua.execute("""
      PRICES = { [2589] = 18, [2996] = 95, [2320] = 12, [4238] = 520, [2570] = 140, [7068] = 400, [7067] = 300,
                 [9000] = 1000, [11287] = 3500, [10938] = 1450 }
      function PRICE(id) return PRICES[id], 1000 end
      RECIPES = {
        [2996] = { mats = { { 2589, 2 } }, makes = 1, rid = 1, name = "Bolt of Linen Cloth" },
        [4238] = { mats = { { 2996, 3 }, { 2320, 3 } }, makes = 1, rid = 2, name = "Linen Bag" },
        [2570] = { mats = { { 2996, 1 }, { 2320, 1 } }, makes = 1, rid = 3, name = "Linen Shirt" },
        [7068] = { mats = { { 7067, 1 } }, makes = 1, rid = 4, name = "Transmute Earth to Fire" },
        [7067] = { mats = { { 7068, 1 } }, makes = 1, rid = 5, name = "Transmute Fire to Earth" },
        [9000] = { mats = { { 2996, 2 } }, makes = 2, rid = 6, name = "Two at a time" },
        [11287] = { mats = { { 4470, 1 }, { 10938, 1 } }, makes = 1, rid = 7, name = "Lesser Magic Wand" },
        [5001] = { mats = { { 2589, 1 } }, makes = 1, rid = 8, name = "Nobody buys it" },
      }
      SKILL = { [4238] = 45, [2570] = 1, [2996] = 1, [7068] = 275, [7067] = 275, [9000] = 100, [11287] = 10 }
      function INFO(id) return SKILL[id] end
      function PICKS(...)
        local out, a = {}, { ... }
        for i = 1, #a, 2 do out[#out + 1] = { row = a[i], crafts = a[i + 1] } end
        return out
      end
    """)
    G = lua.globals()
    ctxOf = lua.eval("function(Pr, opts) opts = opts or {}; return Pr.context({ recipes = RECIPES, price = PRICE, "
                     "cut = opts.cut or 0.05, craftMats = opts.craftMats, info = INFO }) end")
    PICKS = G.PICKS

    ctx = ctxOf(Pr)
    bolt = Pr.unitCost(ctx, 2996)
    check(bolt.cost == 36 and bolt.how == "craft", f"a bolt: crafting (36c) beats buying (95c): {bolt.cost} {bolt.how}")
    cloth = Pr.unitCost(ctx, 2589)
    check(cloth.cost == 18 and cloth.how == "buy", "cloth is bought")
    bag = Pr.row(ctx, 4238, G.RECIPES[4238])
    check(bag.cost == 3 * 36 + 3 * 12, f"bag cost uses crafted bolts: {bag.cost}")
    check(bag.sale == 494, f"sale after the 5% cut: 520 x 0.95 = 494, got {bag.sale}")
    check(bag.profit == 494 - 144 and not bag.approx, f"bag profit {bag.profit}")
    check(abs(bag.margin - (350 / 144)) < 1e-9, "margin is profit over cost")
    check(bag.skill == 45, "skill from the item data")
    mats = [(m.id, m.how) for m in seq(bag.mats)]
    check(mats == [(2996, "craft"), (2320, "buy")], f"materials say how they are got: {mats}")

    # a neutral house: 15%
    nctx = ctxOf(Pr, lua.eval("{ cut = 0.15 }"))
    check(Pr.row(nctx, 4238, G.RECIPES[4238]).sale == 442, "15% cut at a neutral house: 520 x 0.85 = 442")

    # buy everything: no crafting of materials
    bctx = ctxOf(Pr, lua.eval("{ craftMats = false }"))
    check(Pr.unitCost(bctx, 2996).cost == 95, "craftMats off: the bolt is bought")
    check(Pr.row(bctx, 4238, G.RECIPES[4238]).cost == 3 * 95 + 36, "craftMats off: bag cost at bought bolts")

    # cheaper to buy than craft: buy wins
    G.PRICES[2996] = 30
    check(Pr.unitCost(ctxOf(Pr), 2996).how == "buy", "buying wins when it is cheaper")
    G.PRICES[2996] = 95

    # yield: a recipe that makes 2 sells 2 at a time
    two = Pr.row(ctxOf(Pr), 9000, G.RECIPES[9000])
    check(two.cost == 72 and two.sale == 1900, f"makes 2: cost {two.cost}, sale 2 x 1000 x 0.95 = {two.sale}")

    # loops: Fire <-> Earth are cut, not followed for ever; each keeps its bought price
    lctx = ctxOf(Pr)
    fire = Pr.row(lctx, 7068, G.RECIPES[7068])
    check(fire.cost == 300 and fire.mats[1].how == "buy", f"transmute loop cut: Fire costs one bought Earth: {fire.cost}")
    earth = Pr.unitCost(lctx, 7067)
    check(earth.cost == 300 and earth.how == "buy", "Earth stays bought (crafting it needs Fire, which needs Earth)")
    G.PRICES[7067] = None
    fire2 = Pr.row(ctxOf(Pr), 7068, G.RECIPES[7068])
    check(fire2.cost == 400 and fire2.mats[1].how == "craft" and not fire2.approx,
          f"Earth without a price is made from a bought Fire, and the walk ends: {fire2.cost}")
    G.PRICES[7067] = 300

    # unpriced material: approx, left out of the cost, named, never 0
    wand = Pr.row(ctxOf(Pr), 11287, G.RECIPES[11287])
    check(wand.approx and wand.unpriced == 1 and wand.cost == 1450, f"wand: wood has no price: approx, cost {wand.cost}")
    check(wand.missing[1] == 4470, "the unpriced material is named")
    check(wand.mats[1].each is None, "no price is nil, not 0")

    # the list: no sale price left out and counted, best profit first, filters
    rows, counts = Pr.list(ctxOf(Pr), lua.eval("{}"))
    names = [r.name for r in seq(rows)]
    check("Nobody buys it" not in names and counts.noSale == 1, f"a result without a price is left out and counted: {counts.noSale}")
    profits = [r.profit for r in seq(rows)]
    check(profits == sorted(profits, reverse=True), "best profit first")
    check(counts.known == 8, f"known recipes counted: {counts.known}")
    check(counts.approx == 1, f"rows with an unpriced material counted: {counts.approx}")
    rows2, _ = Pr.list(ctxOf(Pr), lua.eval("{ from = 40, to = 120 }"))
    check(sorted(r.name for r in seq(rows2)) == ["Linen Bag", "Two at a time"], "skill range filter")
    rows3, _ = Pr.list(ctxOf(Pr), lua.eval("{ min = 300 }"))
    check(len(rows3) >= 2 and all(r.profit >= 300 for r in seq(rows3)), "minimum profit filter")
    G.SKILL[9000] = None
    rows4, _ = Pr.list(ctxOf(Pr), lua.eval("{ from = 1, to = 300 }"))
    check(any(r.name == "Two at a time" for r in seq(rows4)), "unknown skill passes the whole range")
    rows5, _ = Pr.list(ctxOf(Pr), lua.eval("{ from = 50, to = 300 }"))
    check(not any(r.name == "Two at a time" for r in seq(rows5)), "unknown skill is out of a narrowed range")
    G.SKILL[9000] = 100

    # totals of a selection
    cost, prof, crafts, approx = Pr.totals(PICKS(bag, 4, wand, 0))
    check(cost == 4 * 144 and prof == 4 * 350 and crafts == 4 and not approx, f"totals: {cost} {prof} {crafts}")
    approx2 = Pr.totals(PICKS(wand, 1))[3]
    check(approx2, "a selection with an unpriced material is approx")

    # shopping: 4 bags = 12 bolts (1 in the bags, so 11 crafted: 22 cloth, 5 in the bags) and 12 thread
    have = {2589: 5, 2996: 1}
    need = Pr.shopping(ctxOf(Pr), PICKS(bag, 4), lambda i: have.get(i, 0))
    got = {m.id: (m.need, m.have, m.buy) for m in seq(need)}
    check(got.get(2589) == (22, 5, 17), f"cloth: 22 needed, have 5, buy 17: {got.get(2589)}")
    check(got.get(2320) == (12, 0, 12), f"thread: 12: {got.get(2320)}")
    check(2996 not in got, "the crafted bolt is broken down, not bought")
    need2 = Pr.shopping(ctxOf(Pr, lua.eval("{ craftMats = false }")), PICKS(bag, 4), None)
    got2 = {m.id: m.buy for m in seq(need2)}
    check(got2 == {2996: 12, 2320: 12}, f"craftMats off: bolts bought: {got2}")
    # a recipe making 2 needs half the crafts of its material's recipe... and a material making 2 is rounded up
    lua.execute("RECIPES[2996].makes = 2")
    need4 = Pr.shopping(ctxOf(Pr), PICKS(Pr.row(ctxOf(Pr), 2570, G.RECIPES[2570]), 3), None)
    got4 = {m.id: m.buy for m in seq(need4)}
    check(got4.get(2589) == 4, f"3 bolts at 2 a craft: 2 crafts, 4 cloth: {got4.get(2589)}")
    lua.execute("RECIPES[2996].makes = 1")
    # a loop in the shopping list ends
    fctx = ctxOf(Pr)
    fr = Pr.row(fctx, 7068, G.RECIPES[7068])
    need3 = Pr.shopping(fctx, PICKS(fr, 2), None)
    check(len(need3) == 1 and need3[1].id == 7067 and need3[1].buy == 2, "transmute: buys 2 Earth, no loop")

    # short money text for the columns
    check(Pr.short(123456) == "12g 34s" and Pr.short(520) == "5s 20c" and Pr.short(80) == "80c" and Pr.short(-350) == "-3s 50c"
          and Pr.short(None) == "?", "short money text")

    # the list from counts (what the window and the API save)
    lists = lua.table()
    nm = {2589: "Linen Cloth", 2320: "Coarse Thread"}
    l, new, i = R.saveCounts(lists, " Linen Bag ", lua.eval("{ { 2589, 17 }, { 2320, 12 }, { 2589, 3 }, { 99, 0 } }"), lambda i: nm.get(i))
    check(new is True and i == 1 and l.name == "Linen Bag", "saveCounts makes a list named as asked")
    check(l.want['name is "Linen Cloth"'] == 20 and l.want['name is "Coarse Thread"'] == 12 and len(l.queries) == 2,
          "the same item twice adds up; a count of 0 is skipped")
    l2, new2, _ = R.saveCounts(lists, "Linen Bag", lua.eval("{ { 2320, 2 } }"), lambda i: nm.get(i))
    check(new2 is False and len(lists) == 1 and l2.want['name is "Coarse Thread"'] == 2 and l2.want['name is "Linen Cloth"'] is None,
          "the same name replaces the list")
    r = R.saveCounts(lists, "X", lua.eval("{ { 777, 1 } }"), lambda i: None)
    check(r[0] is None and r[1] == "loading" and r[2][1] == 777, "an unloaded name: nothing saved, says loading")
    check(R.saveCounts(lists, "  ", lua.eval("{ { 2589, 1 } }"), lambda i: "x")[1] == "no name", "no name refused")
    check(R.saveCounts(lists, "Y", lua.eval("{}"), lambda i: "x")[1] == "no items", "no items refused")
    check(len(lists) == 1, "refused calls save nothing")

    failures += profit_api()
    failures += profit_window()
    return failures


def profit_api():
    """EverlookDBAuctionsAPI v2: addShoppingList writes a list; everything else stays read-only."""
    lua = lua51.LuaRuntime(unpack_returned_tuples=True)
    lua.execute("""
      NAMES = { [2589] = "Linen Cloth", [2320] = "Coarse Thread" }
      C_Item = { GetItemNameByID = function(id) return NAMES[id] end, RequestLoadItemDataByID = function() end }
      function GetServerTime() return 0 end
    """)
    ns = lua.table()
    DB = lua.table()
    lua.globals().MOCK_DB = DB
    ns.db = lua.eval("function() return MOCK_DB end")
    refreshed = []
    ns.shoppingRefresh = lambda: refreshed.append(1)
    run = lua.eval("function(src, name, ...) local f = assert(loadstring(src, name)); return f(...) end")
    run(source_of("RecipeList.lua"), "RecipeList.lua", "EverlookDBAuctions", ns)
    run(source_of("API.lua"), "API.lua", "EverlookDBAuctions", ns)
    api = lua.globals().EverlookDBAuctionsAPI
    failures = []

    def check(cond, what):
        if not cond:
            failures.append("profit api: " + what)

    check(api.version == 3, "version 3")
    ok_add, new = api.addShoppingList("Linen Bags", lua.eval("{ { 2589, 24 }, { 2320, 12 } }"))
    check(ok_add is True and new is True and len(DB.lists) == 1 and DB.lists[1].want['name is "Linen Cloth"'] == 24,
          "addShoppingList saves a list")
    check(refreshed, "the Shopping tab is told")
    ok2, new2 = api.addShoppingList("Linen Bags", lua.eval("{ { 2589, 2 } }"))
    check(ok2 is True and new2 is False and len(DB.lists) == 1, "again with the same name: replaced")
    bad, why = api.addShoppingList("Mystery", lua.eval("{ { 31337, 1 } }"))
    check(bad is False and why == "loading", f"unknown item name: false, loading ({why})")
    bad2, why2 = api.addShoppingList("", lua.eval("{ { 2589, 1 } }"))
    check(bad2 is False and why2 == "no name", "no name")
    bad3, why3 = api.addShoppingList("Z", "not a table")
    check(bad3 is False and why3 == "no items", "items not a table")
    setter = lua.eval("function(api) return (pcall(function() api.price = nil end)) end")
    check(setter(api) is False, "the API table is still read-only")
    return failures


def profit_window():
    """The window over a few recipes: rows best first, planned crafts, Make shopping list, the minimum profit box."""
    lua = lua51.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(source_of("tests/mock.lua"))
    lua.execute("""
      MOCK_TIME = 100000; function time() return MOCK_TIME end
      UISpecialFrames = UISpecialFrames or {}; tinsert = tinsert or table.insert
      function IsShiftKeyDown() return false end
      wipe = wipe or function(t) for k in pairs(t) do t[k] = nil end return t end
      GetRealmName = GetRealmName or function() return "Realm" end
      UnitFactionGroup = UnitFactionGroup or function() return "Alliance" end
      MOCK_ITEMS[2589], MOCK_ITEMS[2996], MOCK_ITEMS[2320] = "Linen Cloth", "Bolt of Linen Cloth", "Coarse Thread"
      MOCK_ITEMS[4238], MOCK_ITEMS[2570] = "Linen Bag", "Linen Shirt"
    """)
    ns = lua.table()
    realm = lua.eval("GetRealmName()") + "-" + lua.eval("UnitFactionGroup('player')")
    lua.globals().MOCK_HOUSE = realm
    DB = lua.eval("""{ houses = { [MOCK_HOUSE] = { scanned = 99000, items = {
        [2589] = { 18, 1, 1, 99000 }, [2996] = { 95, 1, 1, 99000 }, [2320] = { 12, 1, 1, 99000 }, [4238] = { 520, 1, 1, 99000 },
        [2570] = { 140, 1, 1, 99000 } } } },
      crafts = {
        [2996] = { mats = { { 2589, 2 } }, makes = 1, rid = 1, name = "Bolt of Linen Cloth" },
        [4238] = { mats = { { 2996, 3 }, { 2320, 3 } }, makes = 1, rid = 2, name = "Linen Bag" },
        [2570] = { mats = { { 2996, 1 }, { 2320, 1 } }, makes = 1, rid = 3, name = "Linen Shirt" },
      } }""")
    lua.globals().MOCK_DB = DB
    ns.db = lua.eval("function() return MOCK_DB end")
    ns.money = lua.eval("function(c) return tostring(c) .. 'c' end")
    ns.ago = lua.eval("function() return '17 min ago' end")
    ns.itemFor = lua.eval("function(id) return MOCK_DB.houses[MOCK_HOUSE].items[id] end")
    run = lua.eval("function(src, name, ...) local f = assert(loadstring(src, name)); return f(...) end")
    run(source_of("Skin.lua"), "Skin.lua", "EverlookDBAuctions", ns)
    for name in ["Libs/EverlookUI/EverlookUI.lua", "RecipeList.lua", "Profit.lua", "ProfitWindow.lua"]:
        run(source_of(name), name, "EverlookDBAuctions", ns)
    W = ns.profitWindow
    failures = []

    def check(cond, what):
        if not cond:
            failures.append("profit window: " + what)

    W.open()
    f = W.frame
    check(f is not None and f.shown, "the window opens")
    if not f or not f.shown:
        return failures

    def shown_names():
        return [f.rows[i].data.name for i in range(1, len(f.rows) + 1) if f.rows[i].shown]

    check(shown_names() == ["Linen Bag", "Linen Shirt", "Bolt of Linen Cloth"], f"best profit first: {shown_names()}")
    check(f.rows[1].profit.text == "+3s 50c", f"bag profit text: {f.rows[1].profit.text}")
    check(f.rows[1].margin.text == "+243%", f"bag margin: {f.rows[1].margin.text}")
    W.crafts[4238] = 4
    W.footer()
    check("4 crafts" in f.sum.text, f"the plan line: {f.sum.text}")
    W.makeList()
    lists = DB.lists
    check(lists is not None and len(lists) == 1 and lists[1].name == "Linen Bag", "one recipe: the list is named after it")
    if lists is not None and len(lists) == 1:
        want = lists[1].want
        check(want['name is "Linen Cloth"'] == 24 and want['name is "Coarse Thread"'] == 12 and want['name is "Bolt of Linen Cloth"'] is None,
              f"bolts broken down into cloth: {[(k, want[k]) for k in want]}")
    check(W.status is not None and "Saved as" in W.status[1], "says it was saved")
    f.min.SetText(f.min, "3")
    f.min.scripts.OnTextChanged(f.min, True)
    check(shown_names() == ["Linen Bag"], f"profit at least 3 silver: {shown_names()}")
    check(DB.profit.min == 300, "the minimum is kept in copper")
    return failures


UPGRADES_SETUP = r"""
-- a warrior at level 60 with a few worn items; gear and stats by item ID
MOCK_CLASS, MOCK_LEVEL = "WARRIOR", 60
function UnitClass() return "Warrior", MOCK_CLASS, 1 end
function UnitLevel() return MOCK_LEVEL end
function InCombatLockdown() return false end
function GetTime() return 1000 end
function debugprofilestop() return 0 end
function strsplit(sep, s)
  local out = {}
  for part in (s .. sep):gmatch("(.-)" .. sep) do out[#out + 1] = part end
  return unpack(out)
end
-- id -> { equipLoc, classID, subID, stats, name, quality, req, sell }
MOCK_GEAR = {}
C_Item.GetItemInfoInstant = function(id)
  local g = MOCK_GEAR[tonumber(id)]
  if not g then return nil end
  return id, "", "", g[1], 134400, g[2], g[3]
end
C_Item.GetItemStats = function(link)
  local id = tonumber(tostring(link):match("item:(%d+)"))
  local suffix = tonumber(tostring(link):match("::::::::::::1:(%d+)"))
  local g = MOCK_GEAR[id]
  local st = {}
  for k, v in pairs(g and g[4] or {}) do st[k] = v end
  if suffix == 5 then st.ITEM_MOD_STRENGTH_SHORT = (st.ITEM_MOD_STRENGTH_SHORT or 0) + 10 end
  return st
end
C_Item.IsItemDataCachedByID = function() return true end
C_Item.GetItemInfo = function(id)
  local n = tonumber(tostring(id):match("(%d+)"))
  local g = MOCK_GEAR[n]
  if not g then return nil end
  return g[5], "item:" .. n, g[6] or 2, 30, g[7] or 1, "", "", 1, g[1], 134400, g[8] or 0
end
UPDATA = {
  ratings = { hit = 10, crit = 14 },
  classes = {
    WARRIOR = { specs = {
      { key = "fury", name = "Fury", role = "melee", brackets = {
        { upTo = 29, src = "estimate", w = { str = 1, ap = 1 } },
        { upTo = 60, src = "wowsims", fb = true, w = { str = 2, ap = 1, crit = 1.5, sta = 0.5, mhdps = 10, ohdps = 5 } } } },
      { key = "protection", name = "Protection", role = "tank", brackets = {
        { upTo = 60, src = "wowsims", w = { sta = 2, def = 3, str = 1, ap = 0.5 } } } },
    }, talents = { { tab = 2, tier = 1, col = 1, pct = 2, name = "Cruelty", stat = "crit" } } },
  },
  procs = { [900] = { { k = "stat", s = { str = 100 }, d = 10, t = "melee", ppm = 1 } } },
}
"""

UPGRADES_NS = r"""
local ns = ...
DB = { scans = {} }
ns.db = function() return DB end
ns.ok = function(v) return v end
ns.money = function(c) return tostring(c) .. "c" end
ns.num = function(n) return tostring(n) end
SAID = {}
ns.say = function(m) SAID[#SAID + 1] = m end
ns.variantOf = function(id, link)
  local s = tostring(link):match("::::::::::::1:(%d+)")
  return id .. ":" .. (s or 0)
end
ns.houseOrFaction = function() return "Test-Alliance" end
ns.itemInfo = function(id)
  local g = MOCK_GEAR[id]
  if not g then return nil end
  return { g[5], g[6] or 2, 30, g[7] or 1, "", "", g[1], 134400, g[8] or 0, 1 }
end
ns.itemFor = function(id) local p = MOCK_PRICES[id]; return p and { p } end
ns.UI = { hex = function() return "|cff00ff00" end }
ns.T = { good = { 0, 1, 0 }, dim = { 1, 1, 1 }, mute = { 1, 1, 1 }, places = { upgrades = { 1, 1, 1 } } }
ns.UP_DATA = UPDATA
"""


def upgrades():
    """Gear upgrades (Upgrades.lua, UpgradesExtras.lua, UpgradesOptions.lua): item scores, the slot comparison (rings,
    trinkets, an off-hand against a two-hander, an empty slot), the armor-type rule, rich mode against most upgrade
    per gold, the max price and smallest-upgrade filters over a scan, level brackets and talents, Pawn import, the
    best quest reward, grey items only at vendors, and the generated data."""
    failures = []

    def check(cond, what):
        if not cond:
            failures.append("upgrades: " + what)

    lua = lua51.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(source_of("tests/mock.lua"))
    lua.execute(UPGRADES_SETUP)
    run = lua.eval("function(src, name, ...) local f = assert(loadstring(src, name)); return f(...) end")
    ns = lua.table()
    run(UPGRADES_NS, "ns", ns)
    for name in ("Upgrades.lua", "UpgradesExtras.lua", "UpgradesOptions.lua"):
        run(source_of(name), name, "EverlookDBAuctions", ns)
    G = lua.globals()
    U, X, O = ns.up, ns.upExtras, ns.upOptions
    gear = lua.eval("""function(id, loc, cls, sub, stats, name, quality, req, sell)
      MOCK_GEAR[id] = { loc, cls, sub, stats, name or ("Item " .. id), quality, req, sell }
    end""")
    T = lua.table_from
    gear(1, "INVTYPE_FINGER", 4, 0, T({"ITEM_MOD_STRENGTH_SHORT": 5}), "Ring A")        # score 10
    gear(2, "INVTYPE_FINGER", 4, 0, T({"ITEM_MOD_STRENGTH_SHORT": 10}), "Ring B")       # score 20
    gear(3, "INVTYPE_FINGER", 4, 0, T({"ITEM_MOD_STRENGTH_SHORT": 6, "ITEM_MOD_CRIT_RATING_SHORT": 2}), "Ring C")  # 15
    gear(4, "INVTYPE_TRINKET", 4, 0, T({"ITEM_MOD_ATTACK_POWER_SHORT": 20}), "Trinket A")
    gear(5, "INVTYPE_TRINKET", 4, 0, T({"ITEM_MOD_ATTACK_POWER_SHORT": 40}), "Trinket B")
    gear(6, "INVTYPE_TRINKET", 4, 0, T({"ITEM_MOD_ATTACK_POWER_SHORT": 30}), "Trinket C")
    gear(7, "INVTYPE_2HWEAPON", 2, 1, T({"ITEM_MOD_DAMAGE_PER_SECOND_SHORT": 40, "ITEM_MOD_STRENGTH_SHORT": 10}), "Big Axe")
    gear(8, "INVTYPE_WEAPON", 2, 7, T({"ITEM_MOD_DAMAGE_PER_SECOND_SHORT": 30}), "Sword")
    gear(9, "INVTYPE_HEAD", 4, 4, T({"ITEM_MOD_STRENGTH_SHORT": 10}), "Plate Helm")
    gear(10, "INVTYPE_CHEST", 4, 4, T({"ITEM_MOD_STRENGTH_SHORT": 10}), "Plate Chest")       # worn, 20
    gear(11, "INVTYPE_CHEST", 4, 2, T({"ITEM_MOD_STRENGTH_SHORT": 30}), "Leather Chest")
    gear(12, "INVTYPE_CHEST", 4, 4, T({"ITEM_MOD_STRENGTH_SHORT": 12}), "Cheap Chest")      # +4 = +20%
    gear(13, "INVTYPE_CHEST", 4, 4, T({"ITEM_MOD_STRENGTH_SHORT": 30}), "Dear Chest")       # +40 = +200%
    gear(14, "INVTYPE_CHEST", 4, 4, T({"ITEM_MOD_STRENGTH_SHORT": 10, "ITEM_MOD_STAMINA_SHORT": 1}), "Tiny Chest")  # +2.5%
    gear(16, "INVTYPE_SHIELD", 4, 6, T({"ITEM_MOD_STAMINA_SHORT": 10}), "Shield")
    gear(17, "INVTYPE_CHEST", 4, 4, T({"ITEM_MOD_STRENGTH_SHORT": 50}), "Future Chest", 4, 63)
    gear(18, "INVTYPE_RANGEDRIGHT", 2, 19, T({}), "Wand")
    gear(20, "INVTYPE_LEGS", 4, 4, T({"ITEM_MOD_STRENGTH_SHORT": 8}), "Legs of Might")
    gear(900, "INVTYPE_WEAPON", 2, 7, T({"ITEM_MOD_DAMAGE_PER_SECOND_SHORT": 30}), "Proc Sword")
    worn = lua.eval("""function(t)
      local out = {}
      for slot, id in pairs(t) do
        local link = "item:" .. id
        out[slot] = { link = link, id = id, key = id .. ":0", equipLoc = MOCK_GEAR[id][1], stats = ns_up.stats(link, id) }
      end
      ns_up.testWorn = out
      ns_up.wornChanged()
    end""")
    G.ns_up = U
    worn(T({11: 1, 12: 2, 13: 4, 14: 5, 16: 7, 5: 10}))

    # scores
    fury = U.spec("fury")
    w = U.weights(fury)[0]
    check(w.str == 2 and w.crit == 1.5, "level 60: the wowsims bracket")
    st = U.stats("item:3", 3)
    check(U.score(st, w, "finger") == 6 * 2 + 2 * 1.5, f"score of a ring: {U.score(st, w, 'finger')}")
    sword = U.stats("item:8", 8)
    check(U.score(sword, w, "mainhand") == 300 and U.score(sword, w, "offhand") == 150,
          "weapon DPS counts as main hand or off hand")
    suffixed = U.stats(U.linkOf(20, 5), 20)
    check(suffixed.str == 18 and U.stats("item:20", 20).str == 8, "a random suffix is scored on its own")
    procs_on = U.score(U.stats("item:900", 900), w, "mainhand", 900, "melee")
    U.set("procs", False)
    procs_off = U.score(U.stats("item:900", 900), w, "mainhand", 900, "melee")
    U.set("procs", True)
    check(procs_off == 300 and procs_on > 320, f"procs count their average value when on: {procs_on} / {procs_off}")

    # rings and trinkets against the weaker one
    r = U.compare(st, 3, "INVTYPE_FINGER", fury)
    check(r.vs.id == 1 and abs(r.slotPct - 50) < 0.01, f"a ring beats the weaker worn ring: {r.vs.id} {r.slotPct}")
    check(abs(r.pct - 5 / 530 * 100) < 0.01 and U.pctText(r) == "+0.9%", f"the gain is a share of the whole gear: {r.pct}")
    check(U.slotText(r) == "+50% over your worn weaker ring", f"ring in words: {U.slotText(r)}")
    r = U.compare(U.stats("item:6", 6), 6, "INVTYPE_TRINKET", fury)
    check(r.vs.id == 4 and abs(r.slotPct - 50) < 0.01 and U.slotText(r) == "+50% over your worn weaker trinket",
          "a trinket against the weaker trinket")
    check(U.worthText(r) == "worth about +5.0 Strength", f"worth text: {U.worthText(r)}")
    # an off-hand while a two-hander is worn
    r = U.compare(U.stats("item:16", 16), 16, "INVTYPE_SHIELD", fury)
    check(r.note == "twohand" and not U.isUpgrade(r, 0), "an off-hand against a worn two-hander")
    # a one-hander against the worn two-hander
    r = U.compare(U.stats("item:8", 8), 8, "INVTYPE_WEAPON", fury)
    check(r.vs.id == 7 and r.delta < 0, "a one-hander against a two-hander (main hand)")
    # an empty slot
    r = U.compare(U.stats("item:9", 9), 9, "INVTYPE_HEAD", fury)
    check(r.note == "empty" and U.isUpgrade(r, 0) and U.pctText(r) == "+3.8%" and r.slotPct is None and U.slotText(r) is None,
          f"an empty slot is filled, measured against the whole gear: {U.pctText(r)}")
    tl = X.tipLines("item:9", 9)
    check(tl[1].right == "+3.8% of your gear" and "fills an empty slot" in tl[1].note, f"tooltip: an empty slot: {tl[1].right} / {tl[1].note}")
    nothing = lua.eval("{}")
    r = U.compare(U.stats("item:9", 9), 9, "INVTYPE_HEAD", fury, nothing)
    check(r.pct is None and U.isUpgrade(r, 0) and U.pctText(r) == "fills an empty slot", "nothing worn at all: fills an empty slot")

    # the armor-type rule and class rules
    ok_, why = U.usable(11, fury, ns.itemInfo(11))[:2]
    check(ok_ is False and why == "armor", f"leather isn't a level-60 warrior's armor type: {why}")
    U.set("armor", False)
    check(U.usable(11, fury, ns.itemInfo(11))[0] is True, "with the rule off, leather is suggested")
    U.set("armor", True)
    ok_, why = U.usable(18, fury, ns.itemInfo(18))[:2]
    check(ok_ is False and why == "class", "a warrior can't use a wand")
    check(U.armorOK("PRIEST", 60, "healer", 4, 2, "INVTYPE_CHEST", True) and U.armorOK("DRUID", 60, "caster", 4, 1, "INVTYPE_CHEST", True),
          "casters and healers see every armor type they wear")
    check(U.armorOK("WARRIOR", 30, "melee", 4, 3, "INVTYPE_CHEST", True) and not U.armorOK("WARRIOR", 30, "melee", 4, 2, "INVTYPE_CHEST", True),
          "a level 30 warrior: mail, not leather")
    ok_, why, needs = U.usable(17, fury, ns.itemInfo(17))[:3]
    check(ok_ is False and why == "level" and needs == 63, "an item above your level: next upgrade needs level N")

    # brackets and talents
    G.MOCK_LEVEL = 25
    U.changed()
    w = U.weights(fury)[0]
    br = U.bracket(fury)[1]
    check(w.str == 1 and w.crit is None and U.bracketText(fury, br) == "1-29", "level 25: the 1-29 bracket")
    G.MOCK_LEVEL = 60
    U.testTalents = T({"name:Cruelty": 5})
    U.changed()
    w, why = U.weights(fury)[:2]
    check(abs(w.crit - 1.5 * 1.1) < 1e-9 and why.crit == "Cruelty", f"a talent raises a weight and marks it: {w.crit}")
    check("Crit Rating 1.65*" in O.weightsText(fury), f"* beside a talent's weight: {O.weightsText(fury)}")
    U.testTalents = None
    U.changed()

    # rich vs per gold, max and min, over a scan
    lua.execute("""
      DB.scans = { { realm = "Test", side = "Alliance", at = 1699990000, rows = {
        ["12:0"] = "1000,1000,1000,1,1,,,,,,,",
        ["13:0"] = "100000,100000,100000,1,1,,,,,,,",
        ["14:0"] = "500,500,500,1,1,,,,,,,",
        ["11:0"] = "10,10,10,1,1,,,,,,,",
        ["17:0"] = "10,10,10,1,1,,,,,,,",
        ["3:0"] = "500,500,500,1,1,,,,,,,",
        ["20:5"] = "700,700,700,1,1,,,,,,,,Legs of Might of Strength",
        ["16:0"] = "50,50,50,1,1,,,,,,,",
      } } }
    """)
    res = U.collect(fury, None, True)
    chest = res.slots.chest
    check(chest.best and chest.best.id == 12, f"most upgrade per gold first: {chest.best and chest.best.id}")
    check(chest.nextLevel == 63, "the chest above your level is the next upgrade")
    check(res.slots.legs.best and res.slots.legs.best.name == "Legs of Might of Strength", "a suffixed row is named by its suffix")
    check(res.slots.offhand.twohand, "the off-hand slot says you wear a two-hander")
    check(res.slots.head.best is None and res.slots.head.usable == 0, "nothing for the head on the AH")
    total = sum(res.slots[g].best.price for g in U.ORDER.values() if res.slots[g].best)
    check(res.count >= 3 and res.total == total, "the summary counts the best of each slot")
    U.set("rich", True)
    res = U.collect(fury, None, True)
    check(res.slots.chest.best.id == 13, "rich mode: the biggest upgrade first")
    U.set("max", 5000)
    res = U.collect(fury, None, True)
    check(res.slots.chest.best.id == 12 and res.slots.chest.overMax == 1, "the max price is a ceiling in rich mode too")
    U.set("max", None)
    U.set("rich", False)
    U.set("min", 0.5)
    res = U.collect(fury, None, True)
    ids = [res.slots.chest.list[i].id for i in range(1, len(res.slots.chest.list) + 1)]
    check(14 not in ids and 12 in ids, f"the smallest upgrade filter: {ids}")
    U.set("min", 0)
    check(U.parseMoney("25g") == 250000 and U.parseMoney("1g 50s") == 15000 and U.parseMoney("5s") == 500
          and U.parseMoney("abc") is None and U.moneyShort(15000) == "1g 50s", "money as typed")
    O.slash("max 1g 50s")
    check(U.get("max") == 15000, "/eah up max 1g 50s")
    O.slash("max off")
    check(U.get("max") is None, "/eah up max off")
    O.slash("rich on")
    check(U.get("rich") is True, "/eah up rich on")
    O.slash("rich off")
    O.slash("min 5")
    check(U.get("min") == 5, "/eah up min 5")
    O.slash("min 0")

    # Pawn import, our export round trip, profiles
    imp = lua.eval("function(s) local p, why = ns_up.import(s); return { p = p, why = why } end")
    res_ = imp('( Pawn: v1: "Warrior Fury": Strength=2.2, HitRating=1.5, Dps=3, Unknown=4 )')
    p, why = res_.p, res_.why
    check(p is not None and p.name == "Warrior Fury" and p.w.str == 2.2 and p.w.hit == 1.5 and p.w.mhdps == 3
          and p.w.ohdps == 3, f"a Pawn scale: {why}")
    s = U.export(lua.eval("{ str = 2.2, crit = 1.25 }"), "fury", "Mine")
    q = imp(s).p
    check(q.w.str == 2.2 and q.w.crit == 1.25 and q.spec == "fury" and q["class"] == "WARRIOR", f"our string round trip: {s}")
    check(imp("nonsense").p is None and imp("nonsense").why, "not a weights string")
    O.slash("import " + s)
    w, _, src, label, _meta = U.weights(fury)
    check(src == "profile" and w.str == 2.2, "an import becomes the profile in use")
    O.slash("set crit 0")
    check(U.weights(fury)[0].crit is None, "0 removes a stat")
    O.slash("reset")
    check(U.weights(fury)[2] == "built-in", "/eah up reset")
    check(U.stepProfile("fury", 1) == "Mine", "next profile")
    check(U.deleteProfile("fury")[0] is True and U.deleteProfile("fury") is False, "delete a profile; not the built-in")

    # specs
    O.slash("spec protection")
    ticked = U.ticked()[0]
    check(len(ticked) == 1 and ticked[1].key == "protection", "/eah up spec protection")
    O.slash("spec all")
    check(len(U.ticked()[0]) == 2, "/eah up spec all")
    O.slash("spec fury")
    lua.execute('table.insert(UPDATA.classes.WARRIOR.specs, { key = "warrior_prot_leveling", name = "Protection (levelling)", role = "melee", build = true, brackets = { { upTo = 60, w = { str = 1 } } } })')
    G.EverlookAuctionsCharDB.up.specs = lua.table()
    none, all_ = U.ticked()
    check(all(not none[i].build for i in range(1, len(none) + 1)) and len(none) == 2 and all_ is True, "none picked: the specs, not the builds")
    O.slash("spec warrior_prot_leveling")
    check(U.ticked()[0][1].key == "warrior_prot_leveling" and U.ticked()[1] is False, "a build is picked like a spec")
    O.slash("spec fury")

    # quest rewards
    choices = lua.eval("""{ { link = "item:12", id = 12 }, { link = "item:13", id = 13 }, { link = "item:11", id = 11 } }""")
    marks, best, lines = X.questPick(choices)
    check(best == 2 and marks[2].text == "+7.5%" and marks[1].text == "+0.8%", f"the best quest reward gets the star: {best} {marks[2].text}")
    check(lines[1].startswith("Best quest reward for Fury: item:13 +7.5% of your gear vs item:10"), f"chat line: {lines[1]}")
    G.MOCK_PRICES = T({14: 5000})
    gear(14, "INVTYPE_CHEST", 4, 4, T({"ITEM_MOD_STRENGTH_SHORT": 1}), "Tiny Chest", 2, 1, 300)
    U.forgetStats()
    marks, best, lines = X.questPick(lua.eval("""{ { link = "item:14", id = 14 }, { link = "item:11", id = 11 } }"""))
    check(best is None and lines[1].startswith("No quest reward is an upgrade for Fury. item:14 sells for the most (4750c on the AH)"),
          f"none is an upgrade: {lines[1]}")

    # grey items only
    items = lua.eval("""{ { quality = 0, sell = 5 }, { quality = 1, sell = 50 }, { quality = 0, sell = 0 },
      { quality = 0, sell = 3, noValue = true }, { quality = 4, sell = 999 }, { quality = 0, sell = 7, locked = true }, { quality = 0, sell = 9 } }""")
    junk = X.junkList(items)
    check(len(junk) == 2 and junk[1].sell == 5 and junk[2].sell == 9, "only grey items worth something are sold")

    # tooltip lines
    lines = X.tipLines("item:13", 13)
    check(lines and lines[1].right == "+7.5% of your gear" and lines[1].left == "Upgrade for Fury", f"tooltip: the upgrade for the spec: {lines[1].right}")
    check("(+200% over your worn chest)" in lines[1].why and "of your gear" not in lines[1].why, f"tooltip: the slot change only in words: {lines[1].why}")
    check(X.badgeText("item:13", 13) == "+7.5%", f"bag badge: the same measure as the tooltip: {X.badgeText('item:13', 13)}")
    lines = X.tipLines("item:11", 11)
    check(lines and lines[1].right == "Not your armor type", "tooltip: not your armor type")
    lines = X.tipLines("item:18", 18)
    check(lines and lines[1].right == "Your class can't use this", "tooltip: the class can't use it")
    check(X.tipLines("item:10", 10) is None, "tooltip: nothing on a worn item")

    # new upgrades in the bags
    new = X.newLinks(lua.eval('{ a = "item:1", b = "item:2" }'), lua.eval('{ c = "item:1", d = "item:2", e = "item:13" }'))
    check(len(new) == 1 and new[1] == "item:13", "only gear that wasn't there is new")
    line = X.newUpgradeLine("item:13", 13)
    check(line.startswith("New upgrade in your bags for Fury: item:13 +7.5% of your gear vs item:10 (+20 Strength"), f"new upgrade chat: {line}")

    # the error margin: a swap of Strength for Crit that the weights can't tell apart is "about the same"
    gear(21, "INVTYPE_CHEST", 4, 4, T({"ITEM_MOD_CRIT_RATING_SHORT": 14}), "Crit Chest")
    r = U.compare(U.stats("item:21", 21), 21, "INVTYPE_CHEST", fury)
    check(r.delta == 1 and r.same and not U.isUpgrade(r, 0) and r.err > 1, f"within the margin: {r.delta} {r.err}")
    lines = X.tipLines("item:21", 21)
    check(lines and lines[1].right == "About the same" and lines[1].why, "tooltip: about the same, and why")
    r = U.compare(U.stats("item:13", 13), 13, "INVTYPE_CHEST", fury)
    why = U.whyText(r)
    check(not r.same and why.startswith("+20 Strength") and "(+200% over your worn chest)" in why and "(estimate)" not in why,
          f"why it's better: {why}")
    G.MOCK_LEVEL = 25
    U.changed()
    r = U.compare(U.stats("item:13", 13), 13, "INVTYPE_CHEST", fury)
    check(r.est and U.whyText(r).endswith("(estimate)") and "estimate" in U.weights(fury)[3], "estimated weights say so")
    G.MOCK_LEVEL = 60
    U.changed()
    # play settings: the asked-for one, else solo (the default), else raid
    sc = lua.eval("""{ key = "x", brackets = { { upTo = 60, scenario = "raid", w = { a = 1 } }, { upTo = 60, scenario = "solo", w = { a = 2 } } } }""")
    check(U.bracket(sc, 60, "raid")[0].a == 1 and U.bracket(sc, 60)[0].a == 2 and U.bracket(sc, 60, "group")[0].a == 2,
          "a bracket per play setting")
    lines = X.tipLines("item:13", 13)
    check("Icon" not in (lines[1].note or "") and not re.search(r"\d+[gsc]\b", lines[1].note or ""),
          f"no money in the upgrade note (the price is the auction house line's): {lines[1].note}")

    # an item the game hasn't loaded: one line, whatever the number of specs, and read again when it arrives
    O.slash("spec all")
    G.EverlookAuctionsCharDB.up.specs = lua.table()
    lua.execute("UNCACHED = { [13] = true }; C_Item.IsItemDataCachedByID = function(id) return not UNCACHED[id] end")
    U.forgetStats()
    lines = X.tipLines("item:13", 13)
    check(len(lines) == 1 and lines[1].right == "reading the item\u2026" and X.waiting == 13,
          f"loading: one line for the item, not one per spec: {[lines[i].right for i in range(1, len(lines) + 1)]}")
    lua.execute("UNCACHED = {}")
    lines = X.tipLines("item:13", 13)
    check(X.waiting is None and all("reading" not in (lines[i].right or "") for i in range(1, len(lines) + 1)), "loaded: read again")
    # every spec counted: the best two and "+N more"
    lua.execute('''for _, k in ipairs({ "arms", "berserker" }) do
      table.insert(UPDATA.classes.WARRIOR.specs, { key = k, name = k, role = "melee", brackets = { { upTo = 60, w = { str = 1 } } } })
    end''')
    U.changed()
    check(len(U.ticked()[0]) == 4 and U.ticked()[1] is True, "four specs counted")
    lines = X.tipLines("item:13", 13)
    check(len(lines) == 3 and lines[1].good and lines[2].good and lines[1].rank >= lines[2].rank and lines[3].left == "+2 more specs",
          f"all specs: the best two and +N more: {[lines[i].left for i in range(1, len(lines) + 1)]}")
    # the same verdict for every spec is one line
    gear(22, "INVTYPE_CHEST", 4, 4, T({"ITEM_MOD_STRENGTH_SHORT": 1}), "Rag Chest")
    lines = X.tipLines("item:22", 22)
    check(len(lines) == 1 and lines[1].left == "All specs" and lines[1].right == "Not an upgrade", f"one line when all agree: {len(lines)}")
    # one ticked spec: no trimming
    O.slash("spec fury")
    lines = X.tipLines("item:13", 13)
    check(len(lines) == 1 and lines[1].left == "Upgrade for Fury", "a ticked spec: its own line")
    # a sandbox or client without GetItemStats still reads the item (no endless "reading the item")
    lua.execute("SAVED_GIS = C_Item.GetItemStats; C_Item.GetItemStats = nil")
    U.forgetStats()
    lines = X.tipLines("item:22", 22)
    check(lines and all("reading" not in (lines[i].right or "") for i in range(1, len(lines) + 1)), "no GetItemStats: still a verdict")
    lua.execute("C_Item.GetItemStats = SAVED_GIS")
    U.forgetStats()

    # the generated data
    lua2 = lua51.LuaRuntime(unpack_returned_tuples=True)
    ns2 = lua2.table()
    lua2.eval("function(src, ...) return assert(loadstring(src, 'UpgradesData.lua'))(...) end")(source_of("UpgradesData.lua"), "x", ns2)
    d = ns2.UP_DATA
    classes = sorted(d.classes.keys())
    check(classes == ["DRUID", "HUNTER", "MAGE", "PALADIN", "PRIEST", "ROGUE", "SHAMAN", "WARLOCK", "WARRIOR"], f"every class: {classes}")
    unpack_w = lua2.eval(r"""function(text)
      local w = {}
      for k, v in tostring(text):gmatch("([%w_]+)=([^/,]+)") do w[k] = tonumber(v) end
      return w
    end""")
    for c in classes:
        for i in range(1, len(d.classes[c].specs) + 1):
            sp = d.classes[c].specs[i]
            last = sp.brackets[len(sp.brackets)]
            check(last.upTo == 60 and len(sp.brackets) >= 10 and sp.brackets[1].upTo < 20, f"{c} {sp.key}: level brackets up to 60")
            bad = [k for b in sp.brackets.values() for k, v in unpack_w(b.w).items() if v < 0]
            check(not bad, f"{c} {sp.key}: no negative weights {bad}")
    builds = [d.classes[c].specs[i].key for c in classes for i in range(1, len(d.classes[c].specs) + 1) if d.classes[c].specs[i].build]
    check({"hunter_bm_melee", "paladin_prot_sp", "priest_disc_leveling"} <= set(builds), f"levelling builds: {builds}")
    return failures


def upgrades_ours():
    """Gear upgrades with our own simulated weights (the real UpgradesData.lua): known values come through from the
    ForeverSims export (Fury dual wield at 40, solo levelling), with their standard errors; the error margin of the
    verdict is twice the standard error from those; estimates (healers, early dual wield, below level 10) say so;
    mana-dependent stats are labelled and never negative; tanks are judged on survival, with threat beside it; the
    play setting picks the levelling or the dungeon weights."""
    failures = []

    def check(cond, what):
        if not cond:
            failures.append("upgrades (our sims): " + what)

    lua = lua51.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(source_of("tests/mock.lua"))
    lua.execute(UPGRADES_SETUP)
    run = lua.eval("function(src, name, ...) local f = assert(loadstring(src, name)); return f(...) end")
    ns = lua.table()
    run(UPGRADES_NS, "ns", ns)
    run(source_of("UpgradesData.lua"), "UpgradesData.lua", "EverlookDBAuctions", ns)
    for name in ("Upgrades.lua", "UpgradesExtras.lua", "UpgradesOptions.lua"):
        run(source_of(name), name, "EverlookDBAuctions", ns)
    G = lua.globals()
    U, X, O = ns.up, ns.upExtras, ns.upOptions
    G.ns_up = U
    T = lua.table_from
    U.set("talents", False)   # the sims' own talents; no adjustment on top
    gear = lua.eval("""function(id, loc, cls, sub, stats, name)
      MOCK_GEAR[id] = { loc, cls, sub, stats, name or ("Item " .. id), 2, 1 }
    end""")
    worn = lua.eval("""function(t)
      local out = {}
      for slot, id in pairs(t) do
        local link = "item:" .. id
        out[slot] = { link = link, id = id, key = id .. ":0", equipLoc = MOCK_GEAR[id][1], stats = ns_up.stats(link, id) }
      end
      ns_up.testWorn = out
      ns_up.wornChanged()
    end""")

    def as_char(cls, level, *specs):
        G.MOCK_CLASS, G.MOCK_LEVEL = cls, level
        G.EverlookAuctionsCharDB = lua.eval("{ up = { specs = {}, asked = true, profile = {} } }")
        for k in specs:
            G.EverlookAuctionsCharDB.up.specs[k] = True
        U.forgetStats()
        U.changed()

    # 1. a known value: Fury (warrior_fury_dw), level 40, levelling, base: Strength EP 2.002 +- 0.003 in the export
    want_str, want_se = 2.002, 0.003
    export = Path(r"D:\Dev\ForeverSims\export\EverlookStatWeights.lua")
    if export.exists():
        text = export.read_text(encoding="utf-8")
        i = text.index('["warrior_fury_dw"]')
        i = text.index('["levelling"]', i)
        i = text.index('["base"]', i)
        i = text.index("[40] = ", i)
        m = re.search(r"Strength = \{ ([\d.]+), ([\d.]+) \}", text[i:i + 2000])
        want_str, want_se = float(m.group(1)), float(m.group(2))
    as_char("WARRIOR", 40, "fury")
    fury = U.spec("fury")
    w, _, src, label, meta = U.weights(fury)
    check(src == "built-in" and meta.src == "simulated" and meta.scenario == "solo",
          f"Fury 40: our simulated solo bracket ({src}, {meta.src}, {meta.scenario})")
    check(abs(w.str - want_str) <= max(want_se, 0.005), f"Fury 40 Strength EP {w.str} within the export's {want_str} +- {want_se}")
    check(meta.se and abs(meta.se.str - want_se) <= 0.0005, f"Fury 40: Strength's standard error kept ({meta.se and meta.se.str} vs {want_se})")
    check((w.spi or 0) > 1 and (w.ohdps or 0) > 0, "Fury 40 levelling: Spirit (rest) and the off-hand count")
    check("solo levelling" in label, f"the label names the play setting: {label}")
    U.set("scenario", "group")
    wg, _, _, _, mg = U.weights(fury)
    check(mg.scenario == "group" and abs(wg.str - 2.2) < 0.05 and (wg.spi or 0) == 0, f"group: the dungeon weights ({mg.scenario}, str {wg.str})")
    O.slash("solo")
    check(U.get("scenario") == "solo", "/eah up solo")
    w, _, _, _, meta = U.weights(fury)

    # 2. the standard errors decide "about the same": 30 Agility + 1 Stamina against 31 Strength
    gear(301, "INVTYPE_CHEST", 4, 3, T({"ITEM_MOD_STRENGTH_SHORT": 31}), "Worn Chest")
    gear(302, "INVTYPE_CHEST", 4, 3, T({"ITEM_MOD_AGILITY_SHORT": 30, "ITEM_MOD_STAMINA_SHORT": 1}), "Agile Chest")
    gear(303, "INVTYPE_CHEST", 4, 3, T({"ITEM_MOD_STRENGTH_SHORT": 40}), "Strong Chest")
    worn(T({5: 301}))
    r = U.compare(U.stats("item:302", 302), 302, "INVTYPE_CHEST", fury)
    expect = 2 * ((30 * meta.se.agi) ** 2 + (1 * meta.se.sta) ** 2 + (31 * meta.se.str) ** 2) ** 0.5
    check(abs(r.err - expect) < 1e-6, f"the margin is twice the standard error from our se ({r.err} vs {expect})")
    check(r.delta > 0 and r.delta <= r.err and r.same and not U.isUpgrade(r, 0), f"inside the margin: about the same ({r.delta} <= {r.err})")
    r = U.compare(U.stats("item:303", 303), 303, "INVTYPE_CHEST", fury)
    check(r.delta > r.err and U.isUpgrade(r, 0) and not r.est, "beyond it: an upgrade, not an estimate")

    # 3. estimates say so: early dual wield, below level 10, healers
    as_char("WARRIOR", 15, "fury")
    _, _, _, label, meta = U.weights(fury)
    check(meta.src == "estimate" and "dual wield" in (meta.why or "") and "(estimate)" in label, f"Fury 15: an estimate, with why: {meta.why}")
    as_char("WARRIOR", 5, "fury")
    _, _, _, _, meta = U.weights(fury)
    check(meta.src == "estimate" and "below level 10" in (meta.why or ""), f"level 5: the level-10 weights, as an estimate: {meta.why}")
    as_char("PALADIN", 40, "holy")
    holy = U.spec("holy")
    _, _, _, label, meta = U.weights(holy)
    check(meta.src == "estimate" and "analytical mana model" in (meta.why or ""), f"Holy paladin: an estimate: {meta.why}")
    gear(311, "INVTYPE_HEAD", 4, 4, T({"ITEM_MOD_INTELLECT_SHORT": 3}), "Old Helm")
    gear(312, "INVTYPE_HEAD", 4, 4, T({"ITEM_MOD_INTELLECT_SHORT": 12, "ITEM_MOD_SPIRIT_SHORT": 8}), "Helm of Light")
    worn(T({1: 311}))
    lines = X.tipLines("item:312", 312)
    check(lines and lines[1].left == "Upgrade for Holy" and (lines[1].why or "").endswith("(estimate)"),
          f"healer tooltip says estimate: {lines and lines[1].why}")
    check("An estimate: analytical mana model" in O.weightsText(holy), "the weights text says why it's an estimate")

    # 4. mana-dependent stats: labelled, never negative
    d = ns.UP_DATA
    neg = []
    for c in d.classes.keys():
        specs = d.classes[c].specs
        for i in range(1, len(specs) + 1):
            for j in range(1, len(specs[i].brackets) + 1):
                b = U.ready(specs[i].brackets[j])
                for k in (b.mana or {}).keys():
                    if (b.w[k] or 0) < 0:
                        neg.append((c, specs[i].key, b.upTo, k))
    check(not neg, f"no negative mana-dependent weight: {neg}")
    as_char("PRIEST", 60, "shadow")
    shadow = U.spec("shadow")
    w, _, _, _, meta = U.weights(shadow)
    check(meta.mana and meta.mana.int and meta.mana.haste and (w.haste is None or w.haste >= 0) and (w.int or 0) > 0,
          f"Shadow 60 solo: Intellect and haste depend on mana; haste is never negative ({w.haste})")
    gear(321, "INVTYPE_HEAD", 4, 1, T({"ITEM_MOD_SPELL_POWER_SHORT": 5}), "Hood")
    gear(322, "INVTYPE_HEAD", 4, 1, T({"ITEM_MOD_SPELL_POWER_SHORT": 5, "ITEM_MOD_INTELLECT_SHORT": 20}), "Hood of Wits")
    worn(T({1: 321}))
    r = U.compare(U.stats("item:322", 322), 322, "INVTYPE_HEAD", shadow)
    check("Intellect (mana-dependent)" in (U.whyText(r) or ""), f"the tooltip labels a mana-dependent stat: {U.whyText(r)}")
    check("Depends on your mana: " in O.weightsText(shadow), "the weights text lists them")

    # 5. tanks: survival decides, threat beside it
    as_char("WARRIOR", 60, "protection")
    prot = U.spec("protection")
    w, _, _, _, meta = U.weights(prot)
    check(meta.metric == "tmi" and w.sta == 1 and (w["def"] or 0) > 0 and meta.tps and (meta.tps.str or 0) > 0,
          f"Protection 60: survival weights (TMI per Stamina), threat weights beside ({meta.metric})")
    gear(331, "INVTYPE_HEAD", 4, 4, T({"ITEM_MOD_STAMINA_SHORT": 12}), "Guard Helm")
    gear(332, "INVTYPE_HEAD", 4, 4, T({"ITEM_MOD_STRENGTH_SHORT": 25}), "Helm of Fury")
    gear(333, "INVTYPE_HEAD", 4, 4, T({"ITEM_MOD_STAMINA_SHORT": 25, "ITEM_MOD_DEFENSE_SKILL_RATING_SHORT": 8}), "Bulwark Helm")
    worn(T({1: 331}))
    r = U.compare(U.stats("item:332", 332), 332, "INVTYPE_HEAD", prot)
    check(not U.isUpgrade(r, 0) and r.threat and r.threat.delta > 0, "a Strength helm: more threat, but not a survival upgrade")
    lines = X.tipLines("item:332", 332)
    check(lines and lines[1].right == "Not an upgrade" and (lines[1].threat or "").startswith("threat +"),
          f"tank tooltip: the verdict is survival, threat beside it: {lines and lines[1].right} / {lines and lines[1].threat}")
    lines = X.tipLines("item:333", 333)
    check(lines and lines[1].good and lines[1].threat, f"a Stamina and Defense helm is the tank's upgrade: {lines and lines[1].right}")
    check("Tanks: the weights are for survival" in O.weightsText(prot), "the weights text says tanks are weighed for survival")
    as_char("WARRIOR", 30, "protection")
    _, _, _, _, meta = U.weights(prot)
    check(meta.src == "estimate" and "survival" in (meta.why or "") and meta.tps, f"tank below 60: estimated survival, our dungeon threat: {meta.why}")

    # 6. talents: simulated weights already include the build's talents; only fallback brackets are adjusted
    as_char("WARRIOR", 40, "fury")
    U.set("talents", True)
    U.testTalents = T({"name:Cruelty": 5})
    U.changed()
    w, why = U.weights(fury)[:2]
    check(abs(w.str - want_str) <= max(want_se, 0.005) and not why.crit, f"Fury 40 solo: talents don't move simulated weights (str {w.str})")
    check("already include your build's talents" in O.weightsText(fury), "the weights text says so")
    as_char("HUNTER", 30, "marksmanship")
    U.testTalents = T({"name:Lightning Reflexes": 5})
    U.set("talents", False)
    w0 = dict(U.weights(U.spec("marksmanship"))[0])
    U.set("talents", True)
    w1, why = U.weights(U.spec("marksmanship"))[:2]
    check(abs((w1.agi or 0) - w0.get("agi", 0) * 1.15) < 1e-6 and why.agi == "Lightning Reflexes", f"a fallback bracket still changes with talents: agi {w0.get('agi')} -> {w1.agi}")
    U.testTalents = None
    U.set("talents", False)

    # 7. Holy Shock Retribution: our level-60 sim of it, per play setting
    as_char("PALADIN", 60, "retribution")
    U.set("talents", True)
    U.testTalents = T({"name:Holy Shock": 1})
    U.changed()
    w, why, _, _, meta = U.weights(U.spec("retribution"))
    check((w.sp or 0) == 1 and why.int == "Holy Shock" and meta.mana and meta.mana.int, f"Holy Shock: its own weights (spell damage 1): {w.sp}")
    U.testTalents = None
    U.set("talents", False)
    return failures


def start_tab():
    """Which tab the auction house opens on (Sell.lua's openStartTab and noteTab): Buy, or the last core tab used
    (Buy, Sell, Auctions, Quick sell, Shopping). Gear upgrades is never remembered, and a lastTab of "upgrades" saved
    by 0.16.0 doesn't bring it back; the Upgrades tab doesn't open itself on AUCTION_HOUSE_SHOW, and its spec question
    doesn't switch to it."""
    failures = []

    def check(cond, what):
        if not cond:
            failures.append("start tab: " + what)

    lua = lua51.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(source_of("tests/mock.lua"))
    lua.execute("""
        time = os.time
        wipe = wipe or function(t) for k in pairs(t) do t[k] = nil end return t end
        C_AuctionHouse = { SupportsCopperValues = function() return true end }
        CLICKED = {}
        AuctionHouseFrame = CreateFrame("Frame", "AuctionHouseFrame")
        AuctionHouseFrame.Tabs = {}
        for i = 1, 4 do   -- Buy, Sell, Auctions, and another addon's tab
          local t = CreateFrame("Button", nil, AuctionHouseFrame)
          t.GetID = function() return i end
          t.Click = function() CLICKED[#CLICKED + 1] = i end
          AuctionHouseFrame.Tabs[i] = t
        end
    """)
    ns = lua.table()
    run = lua.eval("function(src, name, ...) local f = assert(loadstring(src, name)); return f(...) end")
    db = run(CRAFT_SETUP, "setup", ns)
    ns.num = lua.eval("tostring")
    ns.ago = lua.eval("function() return 'a while ago' end")
    for name in ["Skin.lua", "Sell.lua"]:
        run(source_of(name), name, "EverlookDBAuctions", ns)
    G = lua.globals()
    opened = []
    ns.openShopping = lambda *a: opened.append("shopping")

    def start(last, open_on=None):
        db.lastTab = last
        db.openOn = open_on
        G.CLICKED = lua.table()
        del opened[:]
        ns.openStartTab()
        return [G.CLICKED[i] for i in range(1, len(G.CLICKED) + 1)]

    clicked = start("upgrades")
    check(clicked == [] and opened == [] and db.lastTab is None,
          f"a saved lastTab of 'upgrades' opens Buy and is forgotten: {clicked} {opened} {db.lastTab}")
    clicked = start(4)
    check(clicked == [] and db.lastTab is None, f"another addon's tab isn't opened by itself: {clicked}")
    clicked = start(3)
    check(clicked == [3] and db.lastTab == 3, f"the Auctions tab used last opens again: {clicked}")
    clicked = start(1)
    check(clicked == [] and opened == [], "Buy: Blizzard's own start, nothing clicked")
    start("shopping")
    check(opened == ["shopping"], f"Shopping used last opens again: {opened}")
    start("shopping", "browse")
    check(opened == [], "open on Browse: nothing else opens")
    db.lastTab = 2
    ns.noteTab("upgrades")
    check(db.lastTab == 2, f"the Upgrades tab is never remembered as the last tab: {db.lastTab}")
    ns.noteTab("sell")
    check(db.lastTab == "sell", "Quick sell is remembered")

    # the Upgrades tab itself: AUCTION_HOUSE_SHOW makes its tab but never opens it, whatever lastTab says
    lua2 = lua51.LuaRuntime(unpack_returned_tuples=True)
    lua2.execute(source_of("tests/mock.lua"))
    lua2.execute(UPGRADES_SETUP)
    lua2.execute("AuctionHouseFrame = CreateFrame('Frame', 'AuctionHouseFrame')")
    ns2 = lua2.table()
    run2 = lua2.eval("function(src, name, ...) local f = assert(loadstring(src, name)); return f(...) end")
    run2(UPGRADES_NS, "ns", ns2)
    run2(source_of("Skin.lua"), "Skin.lua", "EverlookDBAuctions", ns2)
    for name in ("Upgrades.lua", "UpgradesTab.lua", "UpgradesExtras.lua"):
        run2(source_of(name), name, "EverlookDBAuctions", ns2)
    G2 = lua2.globals()
    G2.DB.lastTab = "upgrades"
    G2.DB.openOn = "last"
    calls = []
    V = ns2.upgradesView
    V.openTab = lambda *a: calls.append("openTab")
    V.open = lambda *a: calls.append("open")
    ns2.makeTab = lua2.eval("function() return CreateFrame('Button') end")
    fire = lua2.eval("function(e) for _, f in ipairs(MOCK_FRAMES) do if f.scripts.OnEvent then f.scripts.OnEvent(f, e) end end end")
    fire("AUCTION_HOUSE_SHOW")
    check(calls == [], f"the auction house opening never opens the Upgrades tab: {calls}")
    src = source_of("UpgradesExtras.lua")
    ask = src[src.index("function ns.upAsk()"):]
    ask = ask[:ask.index("\nend\n")]
    check("upgradesView.open" not in ask and "openTab" not in ask, "saving the spec question doesn't switch to the Upgrades tab")
    check('noteTab("upgrades")' not in source_of("UpgradesTab.lua"), "the Upgrades tab isn't noted as the last tab")
    return failures


def upgrades_tab():
    """The Upgrades tab's states (UpgradesTab.lua): one calm message while a price update runs or there is no scan
    yet (not a grid of empty slots), filled in by itself when the scan is done; quiet cards and one plain empty state
    once there is a scan; the "within your filters" footer only when a filter hides something, naming it; estimated
    weights said once in the status line; and a Discipline priest's cloth upgrades really found (weights and the
    armor rule)."""
    failures = []

    def check(cond, what):
        if not cond:
            failures.append("upgrades tab: " + what)

    lua = lua51.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(source_of("tests/mock.lua"))
    lua.execute(UPGRADES_SETUP)
    run = lua.eval("function(src, name, ...) local f = assert(loadstring(src, name)); return f(...) end")
    ns = lua.table()
    run(UPGRADES_NS, "ns", ns)
    run(source_of("Skin.lua"), "Skin.lua", "EverlookDBAuctions", ns)
    for name in ("Upgrades.lua", "UpgradesTab.lua", "UpgradesExtras.lua"):
        run(source_of(name), name, "EverlookDBAuctions", ns)
    # the real Discipline weights (UpgradesData.lua, as in game)
    lua2 = lua51.LuaRuntime(unpack_returned_tuples=True)
    data_ns = lua2.table()
    lua2.eval("function(src, ...) return assert(loadstring(src, 'UpgradesData.lua'))(...) end")(source_of("UpgradesData.lua"), "x", data_ns)
    lua.execute("UPDATA.classes.PRIEST = { specs = {} }")
    G = lua.globals()
    disc_w = data_ns.UP_DATA.classes.PRIEST.specs[1]
    check(disc_w.key == "discipline", "the first priest spec is Discipline")
    lua.execute("PRIEST_BRACKETS = {}")
    for i in range(1, len(disc_w.brackets) + 1):
        b = disc_w.brackets[i]
        lua.execute(f'table.insert(PRIEST_BRACKETS, {{ upTo = {b.upTo}, src = "{b.src or "simulated"}", w = "{b.w}" }})')
    lua.execute('UPDATA.classes.PRIEST.specs[1] = { key = "discipline", name = "Discipline", role = "healer", brackets = PRIEST_BRACKETS }')
    lua.execute("MOCK_CLASS, MOCK_LEVEL = 'PRIEST', 34")
    U, V = ns.up, ns.upgradesView
    # the scrolling list needs real frame fields the tiny mock doesn't have: a plain one that keeps its items
    lua.eval("""function(UI) UI.list = function(parent)
      local L = CreateFrame("Frame", nil, parent)
      L.empty = CreateFrame("FontString")
      L.SetItems = function(self, items) self.items = items end
      return L
    end end""")(ns.UI)
    G.EverlookAuctionsCharDB = lua.eval("{ up = { specs = { discipline = true }, shown = 'discipline', asked = true, profile = {} } }")
    U.changed()
    gear = lua.eval("""function(id, loc, cls, sub, stats, name, req)
      MOCK_GEAR[id] = { loc, cls, sub, stats, name or ("Item " .. id), 2, req or 30 }
    end""")
    T = lua.table_from
    gear(201, "INVTYPE_HEAD", 4, 1, T({"ITEM_MOD_INTELLECT_SHORT": 5, "ITEM_MOD_SPIRIT_SHORT": 4}), "Worn Hood")
    gear(202, "INVTYPE_ROBE", 4, 1, T({"ITEM_MOD_INTELLECT_SHORT": 6, "ITEM_MOD_STAMINA_SHORT": 4}), "Worn Robe")
    gear(211, "INVTYPE_HEAD", 4, 1, T({"ITEM_MOD_INTELLECT_SHORT": 12, "ITEM_MOD_SPIRIT_SHORT": 10, "ITEM_MOD_STAMINA_SHORT": 8}), "Silk Hood")
    gear(212, "INVTYPE_ROBE", 4, 1, T({"ITEM_MOD_INTELLECT_SHORT": 14, "ITEM_MOD_SPELL_HEALING_DONE_SHORT": 20}), "Robe of Mending")
    gear(213, "INVTYPE_HEAD", 4, 4, T({"ITEM_MOD_STRENGTH_SHORT": 20}), "Plate Helm")
    gear(214, "INVTYPE_HAND", 4, 1, T({"ITEM_MOD_INTELLECT_SHORT": 4}), "Cloth Gloves")
    worn = lua.eval("""function(t)
      local out = {}
      for slot, id in pairs(t) do
        local link = "item:" .. id
        out[slot] = { link = link, id = id, key = id .. ":0", equipLoc = MOCK_GEAR[id][1], stats = ns_up.stats(link, id) }
      end
      ns_up.testWorn = out
      ns_up.wornChanged()
    end""")
    G.ns_up = U
    worn(T({1: 201, 5: 202}))
    disc = U.spec("discipline")
    w = U.weights(disc)[0]
    check((w.int or 0) > 0 and (w.heal or 0) > 0 and (w.spi or 0) > 0, f"Discipline weights score Intellect, Spirit and Healing: {dict(w)}")
    check(U.usable(211, disc, ns.itemInfo(211))[0] is True, "cloth is usable by a priest")
    check(U.usable(213, disc, ns.itemInfo(213))[0] is False, "plate isn't")
    check(U.score(U.stats("item:211", 211), w, "head") > 0, "a cloth hood scores above zero for Discipline")

    # no scan, a price update running: one calm message, not a grid of "Nothing you can use"
    G.DB.scans = lua.table()
    G.SCANNING, G.SCAN_PCT = True, 0.99
    ns.scanning = lua.eval("function() return SCANNING end")
    ns.scanProgress = lua.eval("function() return SCAN_PCT end")
    V.openWindow()
    F = G.EverlookAuctionsUpgrades
    check(F is not None and F.shown, "the view opens")
    check(V.kind == "scanning" and F.msg.shown and not F.area.shown and not F.R.shown,
          f"while prices update and there's no scan: one message in place of the slots: {V.kind}")
    check(F.msgTitle.text == "Updating prices… upgrades show when it's done (99%)", f"the message: {F.msgTitle.text}")
    check(F.sum.text == "" and not F.make.shown, "no footer, no button while there's nothing to show")
    check("Nothing you can use" not in source_of("UpgradesTab.lua"), "no card says 'Nothing you can use'")

    # the scan finishes: the tab reads it by itself (the poll once a second)
    lua.execute("""DB.scans = { { realm = "Test", side = "Alliance", at = 1699990000, rows = {
      ["211:0"] = "5000,5000,5000,1,1,,,,,,,",
      ["212:0"] = "9000,9000,9000,1,1,,,,,,,",
      ["213:0"] = "100,100,100,1,1,,,,,,,",
    } } }""")
    G.SCANNING = False
    F.scripts.OnUpdate(F, 1.1)
    check(V.kind == "ready" and F.area.shown and not F.msg.shown, f"read again by itself when the scan is done: {V.kind}")
    r = U.result
    check(r.slots.head.best and r.slots.head.best.id == 211, "a Discipline priest's cloth hood upgrade is found")
    check(r.slots.chest.best and r.slots.chest.best.id == 212, "and the robe")
    check(not any(r.slots.head.list[i].id == 213 for i in range(1, len(r.slots.head.list) + 1)), "never the plate helm")
    check(F.sum.text.startswith("Best upgrade in every slot: 2 items"), f"the summary: {F.sum.text}")
    check("using estimated weights for Discipline at level 34" in F.head.text, f"estimated weights said once, at the top: {F.head.text}")
    check(F.cards.neck.name.text.endswith(V.QUIET + "|r"), f"an empty card is a quiet dash: {F.cards.neck.name.text}")
    V.sel = "neck"
    V.render()
    check(F.optNote.text.startswith("No upgrade on the AH right now."), f"the empty slot in plain words: {F.optNote.text}")
    V.sel = None

    # the footer about filters only when a filter hides something, naming it
    U.set("max", 1000)
    check(V.kind == "ready" and U.result.count == 0, "with a max price under every upgrade: none shown")
    check(F.sum.text.startswith("No upgrades within your filters: 2 over your max price. Raise MAX PRICE"), f"max price footer: {F.sum.text}")
    U.set("max", None)
    U.set("min", 500)
    check(U.result.count == 0 and "below your min %. Lower MIN %" in F.sum.text, f"min % footer: {F.sum.text}")
    U.set("min", 0)
    G.DB.scans[1].rows = lua.eval('{ ["213:0"] = "100,100,100,1,1,,,,,,," }')
    V.refresh()
    check(U.result.count == 0 and F.sum.text == "No upgrade on the AH right now for Discipline.",
          f"nothing better and no filter hiding any: the plain empty state, no filter footer: {F.sum.text}")
    check(V.footer(lua.eval("{ done = true, count = 0, overMax = 0, underMin = 0 }")) == "No upgrade on the AH right now.", "footer without a spec")

    # no scan at all, none running
    G.DB.scans = lua.table()
    V.refresh()
    check(V.kind == "none" and F.msgTitle.text == "No prices for this auction house yet", f"no scan yet: {F.msgTitle.text}")
    # a scan arrives some other way (the Price Feed, another update): read by itself
    lua.execute('DB.scans = { { realm = "Test", side = "Alliance", at = 1699990000, rows = { ["211:0"] = "5000,5000,5000,1,1,,,,,,," } } }')
    F.scripts.OnUpdate(F, 1.1)
    check(V.kind == "ready" and U.result.slots.head.best is not None, "a scan that turns up is read by itself")
    # an update with an older scan: the old upgrades stay, the status line says prices are updating
    G.SCANNING, G.SCAN_PCT = True, 0.45
    F.scripts.OnUpdate(F, 1.1)
    check(V.kind == "ready" and "updating prices 45%" in F.head.text, f"an older scan stays while prices update: {F.head.text}")
    G.SCANNING = False
    F.scripts.OnUpdate(F, 1.1)
    check(V.kind == "ready" and "updating" not in F.head.text, "read again when that update ends")
    # a realm the game doesn't name: the scan is found by its realm ID
    ns.houseOrFaction = lua.eval("function() return '?-Alliance' end")
    ns.realmInfo = lua.eval("function() return nil, 6946 end")
    G.DB.scans[1].realm, G.DB.scans[1].realmID = "", 6946
    check(U.newestScan() is not None, "a scan saved without its realm name is found by realm ID")
    return failures


def item_tip():
    """ItemTip.lua: our list rows' item tooltip opens next to the mouse and compares with what you wear only while
    Shift is held (GameTooltip.suppressAutomaticCompareItem, set while ours is up and put back after), Shift
    refreshes it, and the setting turns it off."""
    failures = []

    def check(cond, what):
        if not cond:
            failures.append("item tip: " + what)

    lua = lua51.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(source_of("tests/mock.lua"))
    lua.execute("""
        DB = {}
        OWNED = nil
        SET = {}
        GameTooltip.suppressAutomaticCompareItem = "game"
        function GameTooltip:SetOwner(owner, anchor, x, y) OWNED = owner; self.anchor = { anchor, x, y }; self.shown = false end
        function GameTooltip:IsOwned(o) return OWNED == o end
        function GameTooltip:SetHyperlink(l) SET[#SET + 1] = l end
        function GameTooltip:SetItemByID(id) SET[#SET + 1] = id end
        function GameTooltip:Hide() self.shown = false; if self.scripts.OnHide then self.scripts.OnHide(self) end end
    """)
    run = lua.eval("function(src, name, ...) local f = assert(loadstring(src, name)); return f(...) end")
    ns = lua.table()
    ns.db = lua.eval("function() return DB end")
    run(source_of("ItemTip.lua"), "ItemTip.lua", "EverlookDBAuctions", ns)
    G = lua.globals()
    gt = G.GameTooltip
    row = lua.eval('CreateFrame("Button")')
    lines = []
    fill = lambda tip, ok: lines.append(ok)
    ns.itemTooltip(row, "item:2244", fill)
    check(gt.anchor[1] == "ANCHOR_CURSOR_RIGHT", f"opens next to the mouse: {gt.anchor[1]}")
    check(gt.suppressAutomaticCompareItem is True, "no automatic comparison while ours is up")
    check(gt.shown and G.SET[1] == "item:2244" and lines == [True], "the item and the row's own lines are shown")
    # Shift pressed: filled again (the game then compares, as Shift is its compare key)
    ev = ns.itemTip.events
    ev.scripts.OnEvent(ev, "MODIFIER_STATE_CHANGED", "LSHIFT", 1)
    check(len(G.SET) == 2 and len(lines) == 2 and gt.shown, f"Shift refreshes the tooltip: {len(G.SET)}")
    check(gt.suppressAutomaticCompareItem is True, "still ours after the refresh")
    ev.scripts.OnEvent(ev, "MODIFIER_STATE_CHANGED", "LSHIFT", 0)
    check(len(G.SET) == 3, "letting go of Shift refreshes it too")
    # hidden: the game's value is back, and Shift no longer refreshes anything
    gt.Hide(gt)
    check(gt.suppressAutomaticCompareItem == "game", f"put back on hide: {gt.suppressAutomaticCompareItem}")
    ev.scripts.OnEvent(ev, "MODIFIER_STATE_CHANGED", "LSHIFT", 1)
    check(len(G.SET) == 3, "no refresh once hidden")
    # another frame taking the tooltip without a hide: the game's behaviour for it
    ns.itemTooltip(row, 2244)
    check(gt.suppressAutomaticCompareItem is True and G.SET[4] == 2244, "an item ID works too")
    other = lua.eval('CreateFrame("Button")')
    gt.SetOwner(gt, other, "ANCHOR_RIGHT")
    check(gt.suppressAutomaticCompareItem == "game", "put back when another frame takes the tooltip")
    # row to row: still the game's value underneath, never ours saved as the game's
    ns.itemTooltip(row, 1)
    ns.itemTooltip(other, 2)
    gt.Hide(gt)
    check(gt.suppressAutomaticCompareItem == "game", "row to row then hide: the game's value back")
    # itemTipOwner with the row's own lines: refresh is the row's OnEnter
    entered = []
    row.scripts.OnEnter = lambda self: (ns.itemTipOwner(self), gt.Show(gt), entered.append(1))
    row.scripts.OnEnter(row)
    ev.scripts.OnEvent(ev, "MODIFIER_STATE_CHANGED", "LCTRL", 1)
    check(len(entered) == 2, f"a row with its own lines: Shift/Ctrl runs its OnEnter again: {len(entered)}")
    gt.Hide(gt)
    # the setting off: the game decides (the flag is left as the game had it)
    G.DB.compareShift = False
    ns.itemTooltip(row, 3)
    check(gt.suppressAutomaticCompareItem == "game", "setting off: no change to the comparison")
    gt.Hide(gt)
    check(gt.suppressAutomaticCompareItem == "game", "setting off: still the game's after hide")
    return failures


def health():
    """Health.lua in a fresh Lua: words only, missing scan APIs named, nothing that throws escapes."""
    failures = []

    def check(cond, what):
        if not cond:
            failures.append("health: " + what)

    lua = lua51.LuaRuntime(unpack_returned_tuples=True)
    lua.execute("""
      GetBuildInfo = function() return "1.60.1", "71037" end
      GetServerTime = function() return 1795000000 end
      GetRealmName = function() return "" end
      date = os.date
      C_AuctionHouse = { ReplicateItems = function() end, GetNumReplicateItems = function() end,
        GetReplicateItemInfo = function() end, GetReplicateItemLink = function() end }
      local loaded = false
      C_Item = { GetItemInfo = function() if loaded then return "Linen Cloth" end end, RequestLoadItemDataByID = function() loaded = true end }
      timers = {}
      C_Timer = { After = function(_, f) timers[#timers + 1] = f end }
    """)
    ns = lua.table()
    run = lua.eval("function(src, ...) local f = assert(loadstring(src, 'Health.lua')); return f(...) end")
    run((ROOT / "Health.lua").read_text(encoding="utf-8"), "EverlookDBAuctions", ns)
    db = lua.table()
    h = ns.HealthCheck(db, "0.16.2")
    check(h.build == "1.60.1.71037" and h.addon == "0.16.2" and lua.eval("rawequal")(db.health, h), f"build and version: {h.build} {h.addon}")
    check(h.realm == "empty", f"blank realm API: {h.realm}")
    check(h.missing is not None and list(h.missing.values()) == ["C_AuctionHouse.GetReplicateItemTimeLeft"], "missing API named")
    check(h.item == "slow", f"item not loaded yet: {h.item}")
    lua.eval("timers[1]")()
    check(h.item == "ok", "item loads later: ok")
    # a throwing realm API and no item API: reported, never raised
    lua.execute("GetRealmName = function() error('boom') end; C_Item = nil; GetItemInfo = nil;"
                "C_AuctionHouse.GetReplicateItemTimeLeft = function() end")
    h = ns.HealthCheck(db, "0.16.2")
    check(h.realm == "empty" and h.item == "none" and h.missing is None, "throwing realm, no item API, nothing missing")
    return failures


if __name__ == "__main__":
    sys.exit(main())
