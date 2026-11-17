"""Offline tests in Lua 5.1 (WoW's version) via lupa: the shopping list from a recipe (RecipeList.lua), then the
crafting box and the shopping list panel (Crafting.lua) against a fake profession window (tests/mock.lua), the scroll
bars, and below vendor price (Vendor.lua and its search words in Search.lua) over a fake full scan.

Usage: python -P tests/run.py
"""
import sys
from pathlib import Path

from lupa import lua51

ROOT = Path(__file__).resolve().parents[1]


def main() -> int:
    lua = lua51.LuaRuntime(unpack_returned_tuples=True)
    ns = lua.table()
    run = lua.eval("function(src, name, ...) local f = assert(loadstring(src, name)); return f(...) end")
    run((ROOT / "RecipeList.lua").read_text(encoding="utf-8"), "RecipeList.lua", "EverlookDBAuctions", ns)
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
    failures += deals()
    failures += core_and_lists()
    failures += audit_search()
    failures += buy_panel()
    failures += buy_decisions()

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
    lua.execute((ROOT / "tests/mock.lua").read_text(encoding="utf-8"))
    ns = lua.table()
    run = lua.eval("function(src, name, ...) local f = assert(loadstring(src, name)); return f(...) end")
    db = run(CRAFT_SETUP, "setup", ns)
    for name in ["RecipeList.lua", "Crafting.lua"]:
        run((ROOT / name).read_text(encoding="utf-8"), name, "EverlookDBAuctions", ns)
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
    lua.execute((ROOT / "tests/mock.lua").read_text(encoding="utf-8"))
    ns = lua.table()
    run = lua.eval("function(src, name, ...) local f = assert(loadstring(src, name)); return f(...) end")
    run(CRAFT_SETUP, "setup", ns)
    run((ROOT / "Skin.lua").read_text(encoding="utf-8"), "Skin.lua", "EverlookDBAuctions", ns)
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
    lua.execute((ROOT / "tests/mock.lua").read_text(encoding="utf-8"))
    ns = lua.table()
    run = lua.eval("function(src, name, ...) local f = assert(loadstring(src, name)); return f(...) end")
    run(VENDOR_SETUP, "setup", ns)
    for name in ["Skin.lua", "Vendor.lua", "Search.lua"]:
        run((ROOT / name).read_text(encoding="utf-8"), name, "EverlookDBAuctions", ns)
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
    lua.execute((ROOT / "tests/mock.lua").read_text(encoding="utf-8"))
    ns = lua.table()
    run = lua.eval("function(src, name, ...) local f = assert(loadstring(src, name)); return f(...) end")
    run(VENDOR_SETUP, "setup", ns)
    for name in ["Skin.lua", "Vendor.lua", "Search.lua"]:
        run((ROOT / name).read_text(encoding="utf-8"), name, "EverlookDBAuctions", ns)
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
    lua.execute((ROOT / "tests/mock.lua").read_text(encoding="utf-8"))
    lua.execute(QUEUE_SETUP)
    ns = lua.table()
    run = lua.eval("function(src, name, ...) local f = assert(loadstring(src, name)); return f(...) end")
    run((ROOT / "AHQuery.lua").read_text(encoding="utf-8"), "AHQuery.lua", "EverlookDBAuctions", ns)
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
    keys, all_ = Q.pickKeys(es, "Dwarven Magestaff of the Bear", Q.nameOf)
    check(len(keys) == 1 and keys[1].itemSuffix == 5 and all_ is False, "the Bear version's key")
    keys, all_ = Q.pickKeys(es, "Dwarven Magestaff of the Owl", Q.nameOf)
    check(len(keys) == 2 and all_ is True, "no match: every version, shown with names")
    G.KEYNAMES = lua.eval('{ [0] = "Linen Cloth" }')
    keys, all_ = Q.pickKeys(results(entry(key(2589), 10, 20)), "Linen Cloth", Q.nameOf)
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
        lua.execute((ROOT / "tests/mock.lua").read_text(encoding="utf-8"))
        lua.execute("C_AuctionHouse = { SupportsCopperValues = function() return %s end }" % ("true" if copper else "false"))
        ns = lua.table()
        run = lua.eval("function(src, name, ...) local f = assert(loadstring(src, name)); return f(...) end")
        run(CRAFT_SETUP, "setup", ns)
        said = []
        ns.say = lambda m: said.append(m)
        for name in ["Skin.lua", "Sell.lua"]:
            run((ROOT / name).read_text(encoding="utf-8"), name, "EverlookDBAuctions", ns)
        check(ns.setUndercut("1c") is True, "1c is accepted")
        item = 44 * 100 + 14     # an item auction at 44s 14c
        goods = 5 * 100 + 50     # a stackable good at 5s 50c each
        if copper:
            check(ns.undercutPrice(item) == item - 1, f"item: 1c under 44s14c is 44s13c, got {ns.undercutPrice(item)}")
            check(ns.undercutPrice(goods) == goods - 1, "stackable good: 1c under too")
            check(ns.undercutPrice(1) == 1, "never below 1c")
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
    lua.execute((ROOT / "tests/mock.lua").read_text(encoding="utf-8"))
    ns = lua.table()
    run = lua.eval("function(src, name, ...) local f = assert(loadstring(src, name)); return f(...) end")
    run(VENDOR_SETUP, "setup", ns)
    for name in ["Skin.lua", "Vendor.lua", "Search.lua"]:
        run((ROOT / name).read_text(encoding="utf-8"), name, "EverlookDBAuctions", ns)
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
        lua.execute((ROOT / "tests/mock.lua").read_text(encoding="utf-8"))
        run = lua.eval("function(src, name, ...) local f = assert(loadstring(src, name)); return f(...) end")
        return lua, run

    def load(run, ns, *names):
        for name in names:
            run((ROOT / name).read_text(encoding="utf-8"), name, "EverlookDBAuctions", ns)

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
    left, price, fresh = line("AH", "", lua.table(None, 4, 2, now), None, now - 3600, now, now)
    check(price is None and "bids only" in left and "4 up" in left, f"bid-only auctions aren't 'none up': {left}")
    left, price, fresh = line("AH", "", None, None, now - 7200, now, now)
    check(price is None and "none up" in left and "2 h ago" in left, f"'none up' says how old the scan is: {left}")
    left, price, fresh = line("AH", "", lua.table(500, 3, 1, now - 2 * 86400), None, None, now, now)
    check(price == 500 and fresh is False and "2 days ago" in left, f"an old price is marked old: {left}")
    row = lua.table(low=900, qty=2, at=now - 60)
    left, price, fresh = line("AH", " x20", lua.table(500, 3, 1, now), row, None, now, now)
    check(price == 900 and fresh and "this version" in left and " x20" in left, f"random-stat version priced: {left}")
    left, price, fresh = line("AH", "", lua.table(500, 3, 1, now), False, None, now, now)
    check(price == 500 and "any version" in left, f"a version missing from the scan says it's any version's: {left}")
    check(line("AH", " x20", None, None, None, now, now) is None, "nothing known: no line")

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
    lua.execute((ROOT / "tests/mock.lua").read_text(encoding="utf-8"))
    ns = lua.table()
    run = lua.eval("function(src, name, ...) local f = assert(loadstring(src, name)); return f(...) end")
    run(VENDOR_SETUP, "setup", ns)
    lua.execute(QUEUE_SETUP)
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
        run((ROOT / name).read_text(encoding="utf-8"), name, "EverlookDBAuctions", ns)
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
    lua.execute((ROOT / "tests/mock.lua").read_text(encoding="utf-8"))
    ns = lua.table()
    run = lua.eval("function(src, name, ...) local f = assert(loadstring(src, name)); return f(...) end")
    run(VENDOR_SETUP, "setup", ns)
    lua.execute(BUY_SETUP)
    run(AHQ_FAKE, "ahq", ns)
    for name in ["Skin.lua", "Vendor.lua", "Buy.lua"]:
        run((ROOT / name).read_text(encoding="utf-8"), name, "EverlookDBAuctions", ns)
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
    G.ITEMS = tbl(auction(1, 300, 3), auction(2, 600))
    deal_list = tbl(lua.table(header=True), lua.table(id=3000, name="Old Sword", quality="uncommon"))
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
    lua.execute((ROOT / "tests/mock.lua").read_text(encoding="utf-8"))
    ns = lua.table()
    run = lua.eval("function(src, name, ...) local f = assert(loadstring(src, name)); return f(...) end")
    run(VENDOR_SETUP, "setup", ns)
    lua.execute(BUY_SETUP)
    run(AHQ_FAKE, "ahq", ns)
    for name in ["Skin.lua", "Vendor.lua", "Buy.lua"]:
        run((ROOT / name).read_text(encoding="utf-8"), name, "EverlookDBAuctions", ns)
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
    rows = tbl(lua.table(unit=100, buyout=100, qty=1), lua.table(unit=100, buyout=300, qty=3))
    pick = V.nextDeal(rows, 500, False, V.MIN_DEAL)
    check(pick is not None and pick.qty == 3, "an item: the first auction making 10s, not one making 4s")
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


if __name__ == "__main__":
    sys.exit(main())
