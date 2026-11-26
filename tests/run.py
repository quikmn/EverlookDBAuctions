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
    if str(name) == "Search.lua":
        # Formula.lua comes right before it in the TOC: the price formulas the search compiles
        text = "(function(...) " + (ROOT / "Formula.lua").read_text(encoding="utf-8") + chr(10) + "end)(...);" + chr(10) + text
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
    check(keys == ["items", "name", "queries", "want"], f"saved fields: {keys}")
    check(l["items"]['name is "Copper Bar"'] == 2840, "the item ID is kept for Buy this list")
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
    failures += price_formulas()
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
    failures += ledger()
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
    failures += profit_tab()
    failures += profit_scopes()
    failures += profit_queue()
    failures += profit_paid_check()
    failures += upgrades_alts()
    failures += item_tip()
    failures += health()
    failures += hub()
    failures += disenchanting()
    failures += list_import()
    failures += buy_list()
    failures += reload_nudge()
    failures += sell_all()
    failures += deals_list()
    failures += no_freeze()
    failures += deals_buy()
    failures += gold()
    failures += results_alerts_market()
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from inventory import inventory
    failures += inventory(source_of, VENDOR_SETUP)

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

    # enchants on gear up for sale (from the last full scan): enchant is / like, has enchant
    lua.eval("""function(ns)
      ns.ENCHANTS = { [803] = 'Fiery Weapon', [1900] = 'Crusader' }
      ns.enchantName = function(e) return ns.ENCHANTS[e] or ('Enchant ' .. e) end
      ns.enchantsFor = function(key)
        if key == '3000:0' then return { { id = 803, name = 'Fiery Weapon', low = 900, n = 1 }, { id = 1900, name = 'Crusader', low = 5000, n = 2 } } end
        if key == '7001:0' then return { { id = 1900, name = 'Crusader', low = 4000, n = 1 } } end
      end
      local db, copy = ns.db(), {}
      for k, v in pairs(db.scans[1]) do copy[k] = v end
      db.scans[1] = copy   -- a new scan: the search reads its rows again
    end""")(ns)
    got, _, _ = names('enchant is "Fiery Weapon"')
    check(got == ["Old Sword"], f"enchant is: {got}")
    got, _, _ = names('enchant like "*crusader*" | sort by name')
    check(got == ["Lesser Magic Wand", "Old Sword"], f"enchant like, any case: {got}")
    got, _, _ = names("has enchant | sort by name")
    check(got == ["Lesser Magic Wand", "Old Sword"], f"has enchant: {got}")
    got, _, _ = names('not has enchant and slot is wand | sort by name')
    check(got == ["Greater Magic Wand", "Sort Wand"], f"not has enchant: {got}")
    got, _, _ = names('enchant is fire')
    check(got == [], f"is compares whole names: {got}")
    rows, *_ = ns.queryRun('enchant is crusader and slot is onehand')
    w = rows[1].wantEnchants
    check(len(rows) == 1 and w and len(w) == 1 and w[1].id == 1900, "a result keeps the enchant it was found by")
    rows, *_ = ns.queryRun('enchant is "fiery weapon" or enchant is crusader')
    sword = [rows[i] for i in range(1, len(rows) + 1) if rows[i].name == "Old Sword"][0]
    check(len(sword.wantEnchants) == 2, "both asked-for enchants kept")
    rows, *_ = ns.queryRun('has enchant and slot is onehand')
    check(rows[1].wantEnchants is None, "has enchant names none: no pick")
    check(P("has enchant")[1].e.col == "enchant", "has enchant is the enchant column")
    check(P('has "fire damage"')[1].e.col == "text", "has with a word still searches the tooltip")

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


def price_formulas():
    """Price formulas (Formula.lua and Search.lua) against the fixture EverlookDB.com's tests use too
    (tests/formula_fixture.json, a copy of Quarry's crates/core/src/formula_fixture.json): the same values, the same
    rows kept, the same order, the same refusals."""
    import json
    fx = json.loads((ROOT / "tests" / "formula_fixture.json").read_text(encoding="utf-8"))
    lua = lua51.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(source_of("tests/mock.lua"))
    ns = lua.table()
    run = lua.eval("function(src, name, ...) local f = assert(loadstring(src, name)); return f(...) end")
    run(VENDOR_SETUP, "setup", ns)
    for name in ["Skin.lua", "Vendor.lua", "Search.lua"]:
        run(source_of(name), name, "EverlookDBAuctions", ns)
    failures = []

    def check(cond, what):
        if not cond:
            failures.append("price formulas: " + what)

    my = chr(10).join(f"{n} = {f}" for n, f in fx["my"])
    lua.globals().MY_TEXT = my
    lua.execute("")
    run("local ns = ...; ns.myPricesText = function() return MY_TEXT end", "my", ns)
    rows = []
    for r in fx["rows"]:
        t = lua.table(id=r["id"], name=r["name"], key=f'{r["id"]}:0', stack=r["stack"], pcRun=True,
                      sell=r["vendor"], price=r["price"], median=r["median"], low30=r["low30"],
                      median30=r["median30"], craftcost=r["craftcost"], devalue=r["devalue"])
        rows.append(t)
    lrows = lua.table(*rows)

    def ids(q):
        out, err = ns.queryRows(q, lrows)
        if out is None:
            return "error: " + str(err)
        return [out[i].id for i in range(1, len(out) + 1)]

    value = lua.eval("""function(ns, text, row)
      local f = ns.formula.parse(text)
      local ok, fn = pcall(ns.formula.compile, f, function(name)
        local l = name:lower()
        local my = ns.myPriceNames()[l]
        if my then return my end
        local col = ({ now = "price", typical = "median", vendor = "sell" })[l] or l
        return function(r)
          local v = r[col]
          if v == nil or (col ~= "stack" and v <= 0) then return nil end
          return v
        end
      end)
      if not ok then error(fn) end
      return fn(row)
    end""")
    for case in fx["values"]:
        got = [value(ns, case["f"], r) for r in rows]
        same = all((a is None and b is None) or (a is not None and b is not None and abs(a - b) < 1e-9)
                   for a, b in zip(got, case["want"]))
        check(same, f'{case["f"]}: {got}, want {case["want"]}')
    for case in fx["where"]:
        got = ids(case["q"])
        check(got == case["want"], f'where {case["q"]}: {got}, want {case["want"]}')
    for case in fx["sort"]:
        got = ids(case["q"])
        check(got == case["want"], f'{case["q"]}: {got}, want {case["want"]}')
    for q in fx["errors"]:
        got = ids(q)
        check(isinstance(got, str) and got.startswith("error: "), f"{q} must be refused, got {got}")
    # the refusals say what to do, in plain words
    check("60% of what?" in ids("price lt 60% median"), "a % without of says so")
    check("min, max or first" in ids("price lt avg(price)"), "an unknown function names the ones there are")
    check("uses itself" in ids("price lt loop1"), "My prices that use each other in a circle say so")
    check("missing after -" in ids("price lt (median - )"), "a sum with a side missing says so")
    # the plain ways keep working beside formulas
    check(ids("name has cloth sort by price") == [1, 2], "a name search with a sort")
    got = ids("price lt 60% of median sort by median - price desc")
    check(got == [5, 1], f"the Guide's example: a formula, then a sort by one: {got}")
    got = ids("price lt devalue - 50s and avgbuy gt 0")
    check(got == [], f"avgbuy unknown in the fixture: {got}")
    check(ids("price lt vendor sort by -price") == [5], "price lt vendor with sort by -price")
    # My prices: checked before they are saved
    okSet, why = ns.formula.parseMy("myfloor = max(vendor, ", None)
    check(okSet is None and "myfloor:" in why, f"a broken My price is refused: {why}")
    okSet, why = ns.formula.parseMy("max = 5g", None)
    check(okSet is None and "word of the query language" in why, f"a My price can't be called max: {why}")
    two = lua.eval("function(ns) local t, why = ns.formula.parseMy('a = 1g; b = a * 2'); return t and #t or why end")(ns)
    check(two == 2, f"two My prices separated by ;: {two}")
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
        # Create Auction left grey after a price scan: checked again once the auction house is free, never during one
        lua.execute("""
          RECHECKS, POST_ON, SCANNING = 0, false, true
          local function shown() return { IsShown = function() return true end, IsVisible = function() return true end } end
          AuctionHouseFrame = shown()
          local fr = shown()
          fr.GetItem = function() return { bagID = 0, slotIndex = 1 } end
          fr.PostButton = { IsEnabled = function() return POST_ON end }
          fr.UpdatePostState = function() RECHECKS = RECHECKS + 1 end
          AuctionHouseFrame.CommoditiesSellFrame = fr
        """)
        ns.scanning = lua.eval("function() return SCANNING end")
        ns.recheckPost()
        check(lua.eval("RECHECKS") == 0, "no recheck while a scan runs")
        lua.execute("SCANNING = false")
        ns.recheckPost()
        check(lua.eval("RECHECKS") == 1, f"grey button rechecked after the scan: {lua.eval('RECHECKS')}")
        lua.execute("POST_ON = true")
        ns.recheckPost()
        check(lua.eval("RECHECKS") == 1, "a working button is left alone")
        # Your bags read during a price update (the game refuses most items then) is read again once it's free
        lua.execute("REFRESHES = 0")
        st = ns.sellState
        st.refreshBags = lua.eval("function() REFRESHES = REFRESHES + 1 end")
        st.readWhileBusy = True
        lua.execute("SCANNING = true")
        ns.recheckPost()
        check(lua.eval("REFRESHES") == 0, "bags not read again while the scan runs")
        lua.execute("SCANNING = false")
        ns.recheckPost()
        check(lua.eval("REFRESHES") == 1, f"bags read again once the auction house is free: {lua.eval('REFRESHES')}")
        st.readWhileBusy = False
        ns.recheckPost()
        check(lua.eval("REFRESHES") == 1, "bags read while free: not read again")
        lua.execute("AuctionHouseFrame = nil")
        # an item put on Blizzard's Sell tab starts at the undercut under the cheapest auction, once
        if copper:
            lua.execute("""
              C_Item = C_Item or {}
              C_Item.GetItemID = function() return 4370 end
              C_Item.GetItemGUID = function() return GUID end
              GUID, PRICE = "g1", 1991
              ROW = { unitPrice = 1991, quantity = 14, numOwnerItems = 2, containsOwnerItem = true }
              C_AuctionHouse.GetNumCommoditySearchResults = function() return 1 end
              C_AuctionHouse.GetCommoditySearchResultInfo = function() return ROW end
              SF = { PriceInput = { GetAmount = function() return PRICE end, SetAmount = function(_, v) PRICE = v end },
                     GetItem = function() return { IsValid = function() return true end } end,
                     GetDefaultPrice = function() return 0 end }
            """)
            ns.sellStartUndercut(lua.eval("SF"), True)
            check(lua.eval("PRICE") == 1990, f"shared cheapest row (you + others): undercut to 19s90c, got {lua.eval('PRICE')}")
            lua.execute("PRICE = 1500")
            ns.sellStartUndercut(lua.eval("SF"), True)
            check(lua.eval("PRICE") == 1500, "once per item: a typed price is left alone")
            lua.execute("GUID, PRICE = 'g2', 1991; ROW.numOwnerItems = 14")
            ns.sellStartUndercut(lua.eval("SF"), True)
            check(lua.eval("PRICE") == 1991, f"cheapest row only yours: matched, got {lua.eval('PRICE')}")
            lua.execute("GUID, PRICE = 'g3', 1700")
            ns.sellStartUndercut(lua.eval("SF"), True)
            check(lua.eval("PRICE") == 1700, "a price that isn't Blizzard's pick is left alone")
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
    check(price is None and "bids only" in note and note.startswith("4 ") and word == "no buyout",
          f"bid-only auctions aren't 'none listed': {note} / {word}")
    left, note, price, fresh, word = line("Auction house", "", None, None, now - 7200, now, now)
    check(price is None and word == "none" and "2h" in note, f"'none listed' says how old the scan is: {note}")
    left, note, price, fresh, word = line("Auction house", "", lua.table(500, 3, 1, now - 2 * 86400), None, None, now, now)
    check(price == 500 and fresh is False and "2d" in note, f"an old price is marked old: {note}")
    row = lua.table(low=900, qty=2, at=now - 60)
    left, note, price, fresh, word = line("Auction house", " x20", lua.table(500, 3, 1, now), row, None, now, now)
    check(price == 900 and fresh and "this roll" in note and left == "Auction house x20", f"random-stat version priced: {left} {note}")
    left, note, price, fresh, word = line("Auction house", "", lua.table(500, 3, 1, now), False, None, now, now)
    check(price == 500 and "any roll" in note, f"a version missing from the scan says it's any version's: {note}")
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
            "container, disenchant, class")
    for q in ["source is trainer", "source has recipe", "source in (vendor, spell)", "source ne item"]:
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
  IsThrottledMessageSystemReady = function() return AH_READY ~= false end,
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
    for name in ("DisenchantOdds.lua", "DisenchantLog.lua"):
        run(source_of(name), name, "EverlookDBAuctions", ns)
    run(source_of("Options.lua"), "Options.lua", "EverlookDBAuctions", ns)
    fire = lua.eval("function(e, a) for _, f in ipairs(MOCK_FRAMES) do if f.scripts.OnEvent then pcall(f.scripts.OnEvent, f, e, a) end end end")
    fire("ADDON_LOADED", "EverlookDBAuctions")
    check(ns.optionsError is None, f"the settings window builds: {ns.optionsError}")
    # the Disenchanting settings and page (DisenchantLog.lua)
    check(ns.app.GetSetting(ns.app, "debreakdown") is not None and ns.app.sections.disenchanting is not None,
          "the Disenchanting settings page")
    check(ns.slash("debreakdown always") is True and ns.db().de.breakdown == "always", "/eah debreakdown always")
    ns.slash("debreakdown never")
    ns.deLog.page(ns.app, lua.eval('(LibStub("EverlookUI-1"))'))
    check(ns.app.sections.disenchant is not None and ns.app.sections.disenchant.group == "main", "the Disenchanting page, with the main pages")
    # the bag preview on that page builds (DisenchantPreview.lua)
    run(source_of("DisenchantPreview.lua"), "DisenchantPreview.lua", "EverlookDBAuctions", ns)
    built = lua.eval("""function(ns)
      local UI = LibStub("EverlookUI-1")
      local parent = CreateFrame("Frame", nil, UIParent)
      local stack = UI.Stack(parent, 600, ns.app.T, { cards = true })
      local okB, err = pcall(ns.dePreview.build, stack, ns.app, UI)
      if okB then okB, err = pcall(ns.dePreview.refresh) end
      return okB, tostring(err)
    end""")(ns)
    check(built[0], f"the bag preview builds: {built[1]}")
    G = lua.globals()
    check(ns.slash("duration 8") is True and sell.duration == 2, f"/eah duration 8: {sell.duration}")
    check("8" in (G.CHAT[len(G.CHAT)] or ""), "the change is said in chat")
    check(ns.slash("tipvendor on") is True and ns.db().tip.vendor is True, "/eah tipvendor on")
    check(ns.slash("duration 30") is True and sell.duration == 2 and "Example" in G.CHAT[len(G.CHAT)],
          "a wrong value is refused with an example")
    check(ns.slash("skin off") is True and ns.db().skin is False, "/eah skin off")
    check(ns.slash("reloadhint off") is True and ns.db().reloadNudge is False, "/eah reloadhint off")
    check(ns.slash("reloadhint on") is True and ns.db().reloadNudge is None, "/eah reloadhint on")
    check(ns.slash("reloadafter 120") is True and ns.db().reloadAfter == 120, f"/eah reloadafter 120: {ns.db().reloadAfter}")
    check(ns.slash("reloadafter 45") is True and ns.db().reloadAfter == 120 and "Example" in G.CHAT[len(G.CHAT)],
          "/eah reloadafter 45 is refused with an example")
    hits = lua.eval('''function(app)
      local out = {}
      for _, key in ipairs({ "reloadhint", "reloadafter" }) do
        local d = app:GetSetting(key)
        local words = table.concat(d.keywords or {}, " ") .. " " .. d.label
        out[#out + 1] = words:lower():find("reload", 1, true) and words:lower():find("newer", 1, true) and key or nil
      end
      return #out
    end''')(ns.app)
    check(hits == 2, "both reload settings can be found by searching reload or newer")
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
    app.HandleSlash(app, "set duration 24")
    check(sell.duration == 3, f"/eah set duration 24: {sell.duration}")
    app.HandleSlash(app, "get duration")
    check("24 hours" in G.CHAT[len(G.CHAT)], f"/eah get duration: {G.CHAT[len(G.CHAT)]}")
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
    ns.deMaterials = lua.eval("function(id) if id == 2589 then return { { 10940, 100, 1, 1, 1, 12345, 12345 } }, 12345, 600, 'estimate' end end")
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
    # enchants on gear: read from the link for weapons and armor only, packed per item version, read back by name
    lua.execute("""C_Item.GetItemInfoInstant = function(id) return id, '', '', '', 1, ({ [2244] = 2, [2589] = 7 })[id] end
      ns_ENCH = { [803] = 'Fiery Weapon', [1900] = 'Crusader' }""")
    ns.ENCHANTS = G.ns_ENCH
    check(ns.enchantOf(2244, "|cff1eff00|Hitem:2244:803::::::::60:::::|h[Krol Blade]|h|r") == 803, "enchant read from the link")
    check(ns.enchantOf(2244, "|Hitem:2244::::::::::60:::::|h[Krol Blade]|h") is None, "no enchant: nothing")
    check(ns.enchantOf(2589, "|Hitem:2589:803:::|h[Linen Cloth]|h") is None, "only weapons and armor count")
    check(ns.enchantOf(2244, None) is None, "no link: nothing")
    packed = ns.packEnchants(lua.eval("{ [1900] = { 90000, 1 }, [803] = { 1200, 2 }, [7777] = { nil, 1 } }"))
    check(packed == "803:1200:2;1900:90000:1;7777::1", f"packed enchants: {packed}")
    lua.execute("EverlookAuctionsDB.houses['Test-Alliance'].ench = { ['2244:0'] = '1900:90000:1;803:1200:2;7777::1' }")
    en = ns.enchantsFor("2244:0", "Alliance")
    got = [(en[i].name, en[i].low, en[i].n) for i in range(1, len(en) + 1)] if en else None
    check(got == [("Fiery Weapon", 1200, 2), ("Crusader", 90000, 1), ("Enchant 7777", None, 1)],
          f"enchants read back, cheapest first, unnamed by number: {got}")
    check(ns.enchantsFor("2589:0", "Alliance") is None, "no enchants: nil")
    lines = show(2589)
    got = [lines[i] for i in range(1, len(lines) + 1)]
    want = [" ",
            "Sell to vendor = 13c",   # first of all, in large print
            "Most profit: Auction = +77c",
            "AH  3,365 · 76m = 95c",
            "    30d low = 93c",
            "    30d median = 95c",
            "Disenchant  estimate · 10m = 1g 23s"]
    check(got == want, f"lines and order: {got}")
    # "Most profit" in the winner's colour all along the line (label and value), and 7% bigger
    raw = lua.eval("""function(id)
      local fs = {}
      local tip = { n = 0 }
      function tip:GetOwner() return nil end
      function tip:GetName() return "RawTip" end
      function tip:NumLines() return self.n end
      function tip:AddLine() self.n = self.n + 1 end
      function tip:AddDoubleLine(l, r, lr, lg, lb, rr, rg, rb)
        self.n = self.n + 1
        if l:find("Most profit", 1, true) then self.l, self.rr, self.rg, self.rb = l, rr, rg, rb end
        for _, side in ipairs({ "TextLeft", "TextRight" }) do
          local f = { size = 12 }
          function f:SetFontObject() end
          function f:GetFontObject() return nil end
          function f:GetFont() return "F", self.size, "" end
          function f:SetFont(_, s) self.size = s end
          _G["RawTip" .. side .. self.n] = f
          if l:find("Most profit", 1, true) then self.size = f end
        end
      end
      HOOKS[0](tip, { id = id })
      return tip
    end""")
    t = raw(2589)
    check(t.l is not None and t.l.startswith("|cff5be06f") or (t.l or "").lower().startswith("|cff5ce070"),
          f"Most profit label in the Auction green: {t.l}")
    check(abs(t.rr - 0.36) < 0.01 and abs(t.rg - 0.88) < 0.01, f"value in the same green: {t.rr},{t.rg},{t.rb}")
    check(t.size is not None and abs(t.size.size - 12 * 1.07) < 0.01, f"7% bigger: {t.size and t.size.size}")
    # the tooltip reuses its line font strings: shown again (refreshed, or after a clear) the line never grows past 7%,
    # and a clear gives each line its own size back (0.36.1 grew a reused line on every hover)
    reuse = lua.eval("""function(id, clearBetween)
      local fonts, tip = {}, { n = 0, hooks = {} }
      function tip:GetOwner() return nil end
      function tip:GetName() return "ReuseTip" end
      function tip:NumLines() return self.n end
      function tip:HookScript(ev, f) self.hooks[ev] = f end
      function tip:AddLine() self.n = self.n + 1 end
      function tip:AddDoubleLine(l)
        self.n = self.n + 1
        for _, side in ipairs({ "TextLeft", "TextRight" }) do
          local key = side .. self.n
          local f = fonts[key]
          if not f then
            f = { size = 12 }
            function f:SetFontObject(o) self.size = 12 end
            function f:GetFontObject() return nil end
            function f:GetFont() return "F", self.size, "" end
            function f:SetFont(_, s) self.size = s end
            fonts[key] = f
          end
          _G["ReuseTip" .. key] = f
        end
      end
      local max = 0
      for i = 1, 5 do
        tip.n = 0
        HOOKS[0](tip, { id = id })
        for _, f in pairs(fonts) do if f.size > max then max = f.size end end
        if clearBetween and tip.hooks.OnTooltipCleared then tip.hooks.OnTooltipCleared(tip) end
      end
      local after = 0
      for _, f in pairs(fonts) do if f.size > after then after = f.size end end
      return max, after
    end""")
    mx, _ = reuse(2589, False)
    check(abs(mx - 12 * 1.07) < 0.01, f"shown 5 times without a clear: still 7% bigger, not more: {mx}")
    mx, after = reuse(2589, True)
    check(abs(mx - 12 * 1.07) < 0.01 and abs(after - 12) < 0.01, f"with clears: 7% while shown, normal after: {mx} {after}")
    G.SHIFT = True
    lines = show(2589)
    check(lines[2].endswith("= 2s 60c") and "x20" in lines[2], f"Shift: a full stack's vendor price: {lines[2]}")
    check(lines[3].endswith("= +15s 40c"), f"Shift: a full stack's profit: {lines[3]}")
    G.SHIFT = False
    # Ctrl: the stack under the mouse (a bag button showing 14), over Shift's full stack
    lua.execute("MOCK_OWNER = { Count = { GetText = function() return '14' end } }; IsControlKeyDown = function() return true end")
    lines = show(2589)
    check("x14" in lines[2] and lines[2].endswith("= 1s 82c"), f"Ctrl: the hovered stack's price: {lines[2]}")
    lua.execute("MOCK_OWNER = nil")
    lines = show(2589)
    check("x14" not in lines[2], f"Ctrl with no stack under the mouse: one: {lines[2]}")
    lua.execute("IsControlKeyDown = nil")
    # what a vendor sells it for, under what a vendor pays; "AH pays more" when the AH's lowest after its cut beats it
    ns.VENDORBUY = lua.eval("{ [2589] = 20 }")
    lines = show(2589)
    check(lines[3] == "Buy from vendor  AH pays more = 20c", f"buy from vendor: {lines[3]}")
    ns.VENDORBUY = lua.eval("{ [2589] = 90 }")
    lines = show(2589)
    check(lines[3] == "Buy from vendor = 90c", f"buy from vendor, the AH no better: {lines[3]}")
    ns.VENDORBUY = None
    # item level: weapons and armor only, the tooltip's own version first
    lua.execute("""C_Item.GetItemInfo = function(id)
        if id == 2589 then return "Linen Cloth", nil, 1, 5, 1, "Trade Goods", "", 200, "", 0, 13, 7 end
        if id == 2244 then return "Krol Blade", nil, 4, 61, 56, "Weapon", "", 1, "", 0, 50000, 2 end end
      C_Item.GetDetailedItemLevelInfo = function(link) return 63 end""")
    lines = show(2244)
    got = [lines[i] for i in range(1, len(lines) + 1)]
    check("Item level = 61" in got, f"item level of a weapon: {got}")
    check(not any("Item level" in x for x in [show(2589)[i] for i in range(1, len(show(2589)) + 1)]), "no item level on cloth")
    G.EverlookAuctionsDB.tip.ilvl = False
    lines = show(2244)
    check(not any("Item level" in lines[i] for i in range(1, len(lines) + 1)), "item level off")
    G.EverlookAuctionsDB.tip.ilvl = None
    lua.execute("""C_Item.GetItemInfo = function(id) if id == 2589 then return "Linen Cloth", nil, 1, 5, 1, "Trade Goods", "", 200, "", 0, 13 end end""")
    ns.tipDetail("shift")
    lines = show(2589)
    check(len(lines) == 5 and "30d" not in "".join(lines[i] for i in range(1, len(lines) + 1)),
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
    # close prices: the vendor wins (sure, instant money); the AH only when clearly worth it (20% and 50c more)
    keepItem = ns.itemFor
    for ah, want in ((60, "vendor"), (16, "vendor"), (2000, "auction")):
        ns.itemFor = lua.eval(f"function() return {{ {ah}, 5, 1, time() }} end")
        which, diff, stale, cut = ns.sellVerdict(2589)
        check(which == want, f"AH {ah}c vs vendor 13c... at {ah}: {which} {diff}")
    ns.itemFor = lua.eval("function() return { 14, 5, 1, time() } end")
    lines = show(2589)
    check(any("Most profit: Vendor" in lines[i] and "AH not worth it" in lines[i] for i in range(1, len(lines) + 1)),
          f"AH a hair above vendor: 'Most profit: Vendor', AH not worth it: {list(lines.values())}")
    ns.itemFor = keepItem
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
    check("AH  shared · 4,002 · 12m = 80c" in tip, f"the tooltip says whose and how old: {tip}")
    check("30d low = 88c" in tip and "30d median = 93c" in tip, f"the 30-day lines use the shared daily lows too: {tip}")
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
        check("AH  " in show(2589), f"{broken}: the tooltip still works")
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
    return failures + price_feed_behind(start, said)


def price_feed_behind(start, said):
    """Prices that were already hours old when the game read them say so, and why (SharedPrices.lua S.behind): the
    EverlookDB App isn't running, or everlookdb.com has no newer scan of that auction house. 2026-11-26: Neutral
    prices sat 7 hours old beside 20-minute Alliance ones and nothing said a word."""
    failures = []

    def check(cond, what):
        if not cond:
            failures.append("price feed, behind: " + what)

    OWN_OLD = """
    local h = EverlookAuctionsDB.houses["Test-Alliance"]
    h.scanned = MOCK_TIME - 10 * 3600
    h.items[2589][4] = MOCK_TIME - 10 * 3600
    EverlookAuctionsDB.scans[1].at = MOCK_TIME - 10 * 3600
    """
    NEUTRAL = """
    EverlookDBAuctionsShared.houses["EU-4-Neutral"] = { region = "EU", realm = "Test", realmID = 4, side = "Neutral",
      at = MOCK_TIME - 7 * 3600, auctions = 5, firstDay = 95, rows = { ["2589:0"] = "70,70,70,10,1,0,0,0,0,0,1," }, lows = {} }
    """

    # fresh prices: nothing is said anywhere
    lua, ns, show = start(OWN_OLD)
    G, S = lua.globals(), ns.shared
    check(S.behind("Test-Alliance") is None and S.behindText("Test-Alliance") is None, "fresh prices aren't behind")
    check(S.sayBehind() == 0 and not said(G), "fresh prices: no chat line")
    check(S.afterLogin() is True and not said(G), "fresh prices: nothing at login")
    # they grow old while playing: that is the reload offer's (FeedNudge.lua), not this
    G.MOCK_TIME = G.MOCK_TIME + 5 * 3600
    check(S.behind("Test-Alliance") is None, "prices that were fresh at login and aged in the session aren't called behind")

    # the app isn't running: everything is 9 hours old, and so is the last time the app heard from the site
    lua, ns, show = start(OWN_OLD + """
    EverlookDBAuctionsShared.written = MOCK_TIME - 9 * 3600
    EverlookDBAuctionsShared.checked = MOCK_TIME - 9 * 3600
    EverlookDBAuctionsShared.houses["EU-4-Alliance"].at = MOCK_TIME - 9 * 3600
    """ + NEUTRAL.replace("7 * 3600", "9 * 3600"))
    G, S = lua.globals(), ns.shared
    b = S.behind("Test-Alliance")
    check(b is not None and b.why == "app" and b.side == "Alliance", f"the app isn't running: {b and b.why}")
    line = S.feedLine("Test-Alliance", "Alliance")
    check(line == "Price Feed: Alliance · other players' scan, 9 h old · is the EverlookDB App running?", f"the bar's line: {line}")
    line = S.feedLine("Test-Alliance", "Alliance", True)
    check(line == "Price Feed: Alliance, 9 h old · is the app running?", f"the bar's short line: {line}")
    check(any("is the EverlookDB App running?" in l for l in ns.statusLines().values()), "/eah status says it too")
    tip = show(2589)
    check("Old prices: is the EverlookDB App running?" in tip, f"the tooltip says why the price is old: {tip}")
    check(not said(G), "nothing is said before the login")
    lua.eval("function(e) for _, f in ipairs(MOCK_FRAMES) do if f.scripts.OnEvent then f.scripts.OnEvent(f, e) end end end")("PLAYER_LOGIN")
    lines = said(G)
    check(len(lines) == 1 and lines[0].endswith("Price Feed: the prices are 9 h old. The EverlookDB App brings newer ones: check that it is running, then /reload."),
          f"one chat line for both houses: {lines}")
    check(S.sayBehind() == 0 and len(said(G)) == 1, "not again at the next reload")
    check(S.sayBehind(G.MOCK_TIME + 13 * 3600) == 1 and len(said(G)) == 2, "again half a day later")
    check(len(G.ERRORS) == 0, f"no errors: {list(G.ERRORS.values())}")

    # the app is running (it heard from the site a minute before the game loaded), but the site has no newer Neutral scan
    lua, ns, show = start(OWN_OLD + NEUTRAL + """
    EverlookDBAuctionsShared.written = MOCK_TIME - 20 * 60
    EverlookDBAuctionsShared.checked = MOCK_TIME - 60
    EverlookDBAuctionsShared.houses["EU-4-Alliance"].at = MOCK_TIME - 20 * 60
    """)
    G, S = lua.globals(), ns.shared
    check(S.behind("Test-Alliance") is None, "the fresh house isn't behind")
    b = S.behind("Test-Neutral")
    check(b is not None and b.why == "site", f"the old house: the site has nothing newer: {b and b.why}")
    text = S.behindText("Test-Neutral")
    check(text == "Neutral prices are 7 h old. everlookdb.com has no newer scan of this auction house yet.", f"in words: {text}")
    line = S.feedLine("Test-Neutral", "Neutral")
    check(line == "Price Feed: Neutral · other players' scan, 7 h old · no newer scan on everlookdb.com yet", f"the bar's line: {line}")
    check(S.feedLine("Test-Neutral", "Neutral", True) == "Price Feed: Neutral, 7 h old · none newer yet", "the bar's short line")
    check(S.feedLine("Test-Alliance", "Alliance") == "Price Feed: Alliance · other players' scan, 20 min old", "the fresh house's line is as ever")
    status = [l for l in ns.statusLines().values() if "Price Feed" in l]
    check(len(status) == 2 and status[0].count("no newer scan") == 0 and status[1].endswith("no newer scan on everlookdb.com yet"),
          f"/eah status: {status}")
    n = S.sayBehind()
    check(n == 1, f"one chat line: {n} {said(G)}")
    lines = said(G)
    check(len(lines) == 1 and lines[0].endswith("Price Feed: " + text), f"the chat line: {lines}")
    check(S.sayBehind() == 0, "once")
    check(G.EverlookAuctionsDB.feedBehindSaid["Test-Neutral"] == G.MOCK_TIME and G.EverlookAuctionsDB.feedBehindSaid["Test-Alliance"] is None,
          "remembered per auction house")

    # an older app has no `checked`: when it last wrote a price says the same
    lua, ns, show = start(OWN_OLD + NEUTRAL + """
    EverlookDBAuctionsShared.written = MOCK_TIME - 20 * 60
    EverlookDBAuctionsShared.houses["EU-4-Alliance"].at = MOCK_TIME - 20 * 60
    """)
    b = ns.shared.behind("Test-Neutral")
    check(b is not None and b.why == "site", "without `checked`: the last write counts")
    # odd values in the file are ignored, never an error
    lua, ns, show = start(OWN_OLD + NEUTRAL + "EverlookDBAuctionsShared.checked = 'soon'; EverlookDBAuctionsShared.written = -5")
    b = ns.shared.behind("Test-Neutral")
    check(b is not None and b.why == "app" and len(lua.globals().ERRORS) == 0, "a broken check time is the same as none")

    # a scan of your own that is newer is what the addon shows: nothing to say
    lua, ns, show = start("""
    EverlookDBAuctionsShared.written = MOCK_TIME - 9 * 3600
    EverlookDBAuctionsShared.houses["EU-4-Alliance"].at = MOCK_TIME - 9 * 3600
    """)
    G, S = lua.globals(), ns.shared
    check(S.behind("Test-Alliance") is None and S.sayBehind() == 0 and not said(G), "your own newer scan: nothing said")
    check("Old prices" not in " ".join(show(2589)), "your own newer scan: nothing in the tooltip")

    # turned off in the settings: nothing
    lua, ns, show = start(OWN_OLD + NEUTRAL + "EverlookAuctionsDB.ignoreShared = true")
    check(ns.shared.behind("Test-Neutral") is None and ns.shared.sayBehind() == 0, "ignored: nothing said")
    return failures


NUDGE_SETUP = """
COMBAT, LOCKDOWN, INSTANCE, RESTING, TAXI, CASTING, TYPING, DEAD = false, false, false, false, false, false, false, false
GROUP, PARTY_FIGHT = false, false
function InCombatLockdown() return LOCKDOWN end
function UnitAffectingCombat(u) if u == "player" then return COMBAT end return PARTY_FIGHT and u == "party2" end
function IsInInstance() return INSTANCE, INSTANCE and "pvp" or "none" end
function IsResting() return RESTING end
function UnitOnTaxi() return TAXI end
function UnitIsDeadOrGhost() return DEAD end
function UnitCastingInfo() if CASTING then return "Hearthstone" end end
function UnitChannelInfo() end
function GetCurrentKeyBoardFocus() if TYPING then return {} end end
function IsInGroup() return GROUP end
function IsInRaid() return false end
function GetNumGroupMembers() return GROUP and 4 or 0 end
RELOADS = 0
function ReloadUI() RELOADS = RELOADS + 1 end
-- our own scan is old; the feed's copy (and its scan) is 30 minutes old when the game loads it
EverlookAuctionsDB.houses["Test-Alliance"].scanned = MOCK_TIME - 10 * 3600
EverlookDBAuctionsShared.written = MOCK_TIME - 30 * 60
EverlookDBAuctionsShared.houses["EU-4-Alliance"].at = MOCK_TIME - 30 * 60
"""


def reload_nudge():
    """The offer to reload for newer Price Feed prices (FeedNudge.lua): only when the feed's prices shown are older than
    the setting and the app looks like it is writing, only at a calm moment (resting, or just after a mailbox, vendor,
    landing or loading screen; never in a fight, an instance, a group fight, while typing, casting or flying), at most
    once an hour, the x keeps it away 2 hours, a fight hides it, a reload that brought nothing new keeps it quiet; the
    minimap dot and the Shift-only tooltip hint."""
    failures = []

    def check(cond, what):
        if not cond:
            failures.append("reload nudge: " + what)

    def start(extra=""):
        lua = lua51.LuaRuntime(unpack_returned_tuples=True)
        lua.execute(source_of("tests/mock.lua"))
        run = lua.eval("function(src, name, ...) local f = assert(loadstring(src, name)); return f(...) end")
        lua.execute(CORE_SETUP)
        lua.execute(SHARED_SETUP)
        lua.execute(NUDGE_SETUP)
        lua.execute(extra)
        for lib in ("Libs/LibStub/LibStub.lua", "Libs/EverlookUI/EverlookTooltip.lua"):
            run(source_of(lib), lib)
        ns = lua.table()
        for name in ("EverlookDBAuctions.lua", "SharedPrices.lua", "FeedNudge.lua"):
            run(source_of(name), name, "EverlookDBAuctions", ns)
        fire = lua.eval("function(e, ...) for _, f in ipairs(MOCK_FRAMES) do if f.scripts.OnEvent then pcall(f.scripts.OnEvent, f, e, ...) end end end")
        fire("ADDON_LOADED", "EverlookDBAuctions")
        lua.execute("BADGE = nil")
        ns.minimapButton = lua.eval("{ badge = function(on) BADGE = on end }")
        return lua, ns, fire

    def reason(N):
        r = N.stale()
        return r[1] if isinstance(r, tuple) else r

    MIN = 60
    lua, ns, fire = start()
    G = lua.globals()
    N = ns.feedNudge
    T0 = G.MOCK_TIME
    check(N is not None and N.loaded == T0, "loaded with the feed")

    def at(minutes):
        G.MOCK_TIME = T0 + int(minutes * MIN)

    # the copy is 30 min old at login; 20 min later it's 50: fresh
    at(20)
    check(reason(N) == "fresh", f"50 min old: fresh: {reason(N)}")
    check(N.check() is False and not N.shown(), "nothing while fresh")
    check(G.BADGE is False, "no minimap dot while fresh")
    # an hour in: 91 min old, but out in the world (not resting, no moment): no line, but the dot
    at(61)
    age = N.stale()
    check(age == 91 * MIN, f"91 min old: stale: {age}")
    check(N.calm()[1] == "place", f"out in the world: not a calm place: {N.calm()}")
    check(N.check() is False and not N.shown(), "no line out in the world")
    check(G.BADGE is True, "the minimap dot shows (no rate limit, no calm moment needed)")

    # each thing that isn't calm, while resting
    G.RESTING = True
    for flag, why in (("COMBAT", "combat"), ("LOCKDOWN", "combat"), ("INSTANCE", "instance"), ("TAXI", "flying"),
                      ("CASTING", "casting"), ("TYPING", "typing"), ("DEAD", "dead")):
        G[flag] = True
        c = N.calm()
        check(c[0] is False and c[1] == why, f"{flag}: not calm ({why}): {c}")
        check(N.check() is False and not N.shown(), f"{flag}: no line")
        G[flag] = False
    G.GROUP, G.PARTY_FIGHT = True, True
    check(N.calm()[1] == "group", "a group member fighting: not calm")
    G.PARTY_FIGHT = False
    check(N.calm() is True, f"in a quiet group, resting: calm: {N.calm()}")
    G.GROUP = False
    keep = ns.house
    ns.house = lua.eval("function() return 'Test-Alliance' end")
    check(N.calm()[1] == "auctionhouse", "at the auction house its bar offers it instead")
    ns.house = keep

    # resting and calm: the line, once
    check(N.check() is True and N.shown(), "resting in a city: the line shows")
    text = N.frame.text.text
    check(text.startswith("Prices: 2 h old") and "Reload" in text and "(1 s)" in text, f"the line's text: {text}")
    check(N.check() is False and N.shown(), "shown once, not again on top")
    # a fight hides it at once
    fire("PLAYER_REGEN_DISABLED")
    check(not N.shown(), "a fight hides it")
    # never more than once an hour
    check(N.check() is False and N.allowed()[1] == "hourly", "not again within the hour")
    at(61 + 59)
    check(N.check() is False, "59 minutes later: still not")
    at(61 + 61)
    check(N.check() is True and N.shown(), "an hour later: again")
    # it goes by itself after a minute
    G.MOCK_TIME = G.MOCK_TIME + N.SHOW_FOR
    N.check()
    check(not N.shown(), "gone by itself after a minute")
    # the x: quiet for 2 hours
    at(200)
    check(N.check() is True, "shown at 200 min")
    N.dismiss()
    check(not N.shown() and N.allowed()[1] == "dismissed", "dismissed")
    at(200 + 119)
    check(N.check() is False, "dismissed: quiet for 2 hours")
    at(200 + 121)
    check(N.check() is True, "after 2 hours: again")
    # right-click on the line is the x too; a click reloads
    f = N.frame
    f.scripts.OnClick(f, "RightButton")
    check(not N.shown() and ns.db().nudge.quietTill == G.MOCK_TIME + N.QUIET, "right-click: not now")
    f.scripts.OnClick(f, "LeftButton")
    check(G.RELOADS == 1, "a click reloads")
    G.RELOADS = 0

    # a calm moment away from a city: a mailbox, a loading screen (not the login one), a landing
    lua, ns, fire = start()
    G, N = lua.globals(), ns.feedNudge
    G.MOCK_TIME = T0 + 61 * MIN
    check(N.check() is False, "not resting: no line")
    fire("MAIL_SHOW")
    check(N.shown(), "at a mailbox: the line")
    lua, ns, fire = start()
    G, N = lua.globals(), ns.feedNudge
    G.MOCK_TIME = T0 + 61 * MIN
    fire("PLAYER_ENTERING_WORLD", True, False)
    check(not N.shown(), "the login's own loading screen is no moment")
    fire("PLAYER_ENTERING_WORLD", False, False)
    check(N.shown(), "after a loading screen: the line")
    lua, ns, fire = start()
    G, N = lua.globals(), ns.feedNudge
    G.MOCK_TIME = T0 + 61 * MIN
    G.COMBAT = True
    fire("PLAYER_CONTROL_GAINED")
    check(not N.shown(), "a moment in a fight: nothing")
    G.COMBAT = False
    N.check()
    check(N.shown(), "the moment lasts a little while: once the fight is over, the line")
    N.hide()
    ns.db().nudge.shown = None
    G.MOCK_TIME = G.MOCK_TIME + 5 * MIN
    check(N.check() is False, "the moment is over after 90 seconds")

    # the reload remembers which copy was loaded; never in combat
    check(N.reload() is True and G.RELOADS == 1 and ns.db().nudge.reloadFrom == T0 - 30 * MIN, "the reload")
    G.LOCKDOWN = True
    check(N.reload() is False and G.RELOADS == 1, "never a reload in combat")
    G.LOCKDOWN = False
    # after that reload the same copy came back (the app isn't writing): one chat line, quiet for 2 hours
    lua, ns, fire = start("EverlookAuctionsDB.nudge = { reloadFrom = MOCK_TIME - 30 * 60 }")
    G, N = lua.globals(), ns.feedNudge
    fire("PLAYER_LOGIN")
    check(ns.db().nudge.reloadFrom is None and ns.db().nudge.nothingTill == T0 + N.QUIET, "same copy: quiet 2 hours")
    check(any("no newer prices" in p for p in G.PRINTED.values()), f"says so once: {list(G.PRINTED.values())}")
    G.RESTING = True
    G.MOCK_TIME = T0 + 61 * MIN
    check(reason(N) == "nothingnew", "quiet while nothing new")
    G.MOCK_TIME = T0 + 121 * MIN
    check(N.check() is True, "after 2 hours, again")
    # a newer copy came: nothing said
    lua, ns, fire = start("EverlookAuctionsDB.nudge = { reloadFrom = MOCK_TIME - 90 * 60 }")
    G = lua.globals()
    fire("PLAYER_LOGIN")
    check(ns.db().nudge.nothingTill is None and not any("no newer" in p for p in G.PRINTED.values()),
          "a newer copy: quiet about it")

    # when it never fires
    cases = (
        ("EverlookAuctionsDB.reloadNudge = false", "off"),
        ("EverlookAuctionsDB.ignoreShared = true", "nofeed"),
        ("EverlookDBAuctionsShared = nil", "nofeed"),
        ("EverlookDBAuctionsShared = { version = 1, written = 0, houses = {} }", "nofeed"),
        ("EverlookDBAuctionsShared.houses['EU-4-Alliance'].realm = 'Other'", "nohouse"),
        ("EverlookAuctionsDB.houses['Test-Alliance'].scanned = MOCK_TIME + 50 * 60", "own"),
        ("EverlookDBAuctionsShared.written = MOCK_TIME - 7 * 3600; EverlookDBAuctionsShared.houses['EU-4-Alliance'].at = MOCK_TIME - 7 * 3600", "appidle"),
        ("EverlookAuctionsDB.reloadAfter = 120", "fresh"),
    )
    for extra, why in cases:
        lua, ns, fire = start(extra)
        G, N = lua.globals(), ns.feedNudge
        G.RESTING = True
        G.MOCK_TIME = T0 + 61 * MIN
        got = reason(N)
        check(got == why, f"{extra}: {why}: {got}")
        check(N.check() is False and not N.shown() and G.BADGE is False, f"{extra}: no line, no dot")
    # just reloaded: nothing in the first 15 minutes, even with an old copy
    lua, ns, fire = start("EverlookDBAuctionsShared.written = MOCK_TIME - 3 * 3600; EverlookDBAuctionsShared.houses['EU-4-Alliance'].at = MOCK_TIME - 3 * 3600")
    G, N = lua.globals(), ns.feedNudge
    G.RESTING = True
    G.MOCK_TIME = T0 + 10 * MIN
    check(reason(N) == "justloaded", "just loaded: quiet")
    G.MOCK_TIME = T0 + 16 * MIN
    check(N.check() is True and "3 h old" in N.frame.text.text, f"then 'Prices: 3 h old': {N.frame.text.text}")
    check(N.minutes() == 90, "the default age is 90 minutes")
    lua.execute("EverlookAuctionsDB.reloadAfter = 45")
    check(N.minutes() == 90, "an age that isn't a choice falls back to 90")

    # the tooltip: "/reload for newer prices" only while Shift is held
    lua, ns, fire = start()
    G = lua.globals()
    G.MOCK_TIME = T0 + 61 * MIN
    show = lua.eval("""function(id)
      local tip = { lines = {} }
      function tip:GetOwner() return nil end
      function tip:AddLine(l) self.lines[#self.lines + 1] = l end
      function tip:AddDoubleLine(l, r) self.lines[#self.lines + 1] = l .. " = " .. r end
      HOOKS[0](tip, { id = id })
      return table.concat(tip.lines, " ;; ")
    end""")
    tip = show(2589)
    check("/reload" not in tip, f"no hint without Shift: {tip}")
    G.SHIFT = True
    tip = show(2589)
    check(tip.count("/reload for newer prices") == 1, f"the hint with Shift, once: {tip}")
    G.MOCK_TIME = T0 + 20 * MIN
    check("/reload" not in show(2589), "no hint while fresh, even with Shift")
    check(len(G.ERRORS) == 0, f"no errors: {list(G.ERRORS.values())}")

    # the auction house's bar: a quiet Reload button beside Update prices, and the feed line says newer may be ready
    lua, ns, fire = scan_lua(SHARED_SETUP + NUDGE_SETUP)
    run = lua.eval("function(src, name, ...) local f = assert(loadstring(src, name)); return f(...) end")
    for name in ("SharedPrices.lua", "FeedNudge.lua"):
        run(source_of(name), name, "EverlookDBAuctions", ns)
    G = lua.globals()
    bar = G.EverlookAuctionsBar
    check(bar is not None and bar.reload is not None, "the bar has a Reload button")
    if bar is not None and bar.reload is not None:
        ns.shared.reset()
        ns.feedNudge.loaded = T0
        ns.db().houses["Test-Alliance"].scanned = T0 - 10 * 3600
        G.MOCK_TIME = T0 + 20 * MIN
        bar.scripts.OnUpdate(bar, 2)
        check(not bar.reload.shown and "newer" not in bar.feed.text, f"fresh: no Reload: {bar.feed.text}")
        G.MOCK_TIME = T0 + 61 * MIN
        bar.scripts.OnUpdate(bar, 2)
        check(bar.reload.shown and bar.feed.text.endswith("newer may be ready"), f"old: Reload shows: {bar.feed.text}")
        bar.reload.scripts.OnClick(bar.reload)
        check(G.RELOADS == 1, "the bar's Reload reloads")
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
      ns.UI = setmetatable({ hex = function() return "|cffffffff" end, own = function(f) return f end },
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
    for name in ["Libs/LibStub/LibStub.lua", "Libs/EverlookUI/EverlookUI.lua", "MailClassify.lua", "PurchaseLog.lua", "Ledger.lua",
                 "LedgerWatch.lua", "Purchases.lua", "LootCards.lua"]:
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

    # income: an auction sold (the mail pays 950 + 30 deposit back), gold from a player, the same mail reached twice
    lua.execute("""
      GetTime = function() return MOCK_TIME end
      MOCK_MAIL = {
        { 'Auction House', 'Auction successful: Runed Copper Rod (2)', 980, 'seller', 'Runed Copper Rod', 1000, 2, 30, 50, false },
        { 'Somebody', 'hi', 500, nil, nil, nil, nil, nil, nil, true },
      }
      function GetInboxNumItems() return #MOCK_MAIL, #MOCK_MAIL end
      function GetInboxHeaderInfo(i) local m = MOCK_MAIL[i]
        if m then return nil, nil, m[1], m[2], m[3], 0, 29, 0, false, false, false, m[10], false end end
      function GetInboxInvoiceInfo(i) local m = MOCK_MAIL[i]
        if m and m[4] then return m[4], m[5], 'Buyer', m[6], 0, m[8], m[9], 0, 0, 0, m[7] end end
      C_Item.GetItemInfoInstant = function(name) for id, n in pairs(MOCK_ITEMS) do if n == name then return id end end end
      UnitGUID = function() return 'Player-1-00000001' end
      UnitName = function() return 'Me' end
    """)
    B = ns.purchases
    LG = ns.ledger
    LG.watch.login()
    # a sale the game told us about waits as "sold, money waiting" until its money is taken
    B.noteSold("Runed Copper Rod", 1800, 2)
    B.noteSold("Copper Bar", None, None)
    sl = LG.get()
    check(len(sl.auctions) == 2 and sl.auctions[1].st == "sold" and sl.auctions[1].est == 1710, f"two sales waiting: {sl.auctions[1].est}")
    B.takeMail(1)
    check(sl.auctions[1].done is not None and sl.auctions[2].done is None, "taking the rod's money settles the rod only")
    B.takeMail(1)
    B.takeMail(2)
    inc = sl.money
    check(len(inc) == 2, f"two mails, one logged once: {len(inc)}")
    check(inc[1].cat == "sale" and inc[1].c == 950 and inc[1].q == 2 and inc[1].gross == 1000 and inc[1].dep == 30 and inc[1].cut == 50,
          f"a sale: net of the cut and the deposit back, count, what the buyer paid: {inc[1].c}")
    check(inc[2].cat == "player" and inc[2].c == 500 and inc[2].name is None, "gold from a player: not income, no sender kept")
    for e in (inc[1], inc[2]):
        for k in e.keys():
            check(k not in ("sender", "subject", "buyer"), f"no names in the account file: {k}")
    check(G.EverlookAuctionsCharDB.buyers[sl.auctions[1].id] == "Buyer", "the buyer is kept per character")
    sm = LG.summary(sl, None, DB.bought)
    check(sm.income == 950 and sm.other == 500, f"income is the sale only: {sm.income}, not income {sm.other}")

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
        check("7 days: income 950c" in f.sum.text, f"the income view sums the week: {f.sum.text}")
        check("1 sold, money waiting" in f.ledger.note1.text, f"the waiting sale is counted: {f.ledger.note1.text}")
        rawget = lua.eval("rawget")
        tags = [f.rows[i].craft.text for i in range(1, len(f.rows) + 1) if rawget(f.rows[i], "entry")]
        check(tags[:1] == ["Sold, money on its way"] and "AH sale" in tags and "From player" in tags, f"rows tagged: {tags}")
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
        check(LG.openCounts(sl).sold == 2, "the ledger has the rod sold again (the bar still waits too)")
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
          MOCK_MAIL = {}
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
        shownLoot = [rawget(f.rows[i], "entry") for i in range(1, len(f.rows) + 1) if rawget(f.rows[i], "entry")]
        check(len(shownLoot) == 2 and all(e.got is None for e in shownLoot), f"the Looted list shows loot only: {[(e.name, e.got) for e in shownLoot]}")
        check(LG.summary(sl, None).loot == 250, f"looted coins are income: {LG.summary(sl, None).loot}")
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


def hub():
    """The main window (Hub.lua): the start page, income sums, ages, the minimap button's place on round and square
    minimaps, opening and toggling pages, and the sale card's link into the AH log's Income."""
    lua = lua51.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(source_of("tests/mock.lua"))
    lua.execute("MOCK_DB = {}; time = time or os.time; date = date or os.date")
    ns = lua.table()
    ns.db = lua.eval("function() return MOCK_DB end")
    run = lua.eval("function(src, name, ...) local f = assert(loadstring(src, name)); return f(...) end")
    run(source_of("Hub.lua"), "Hub.lua", "EverlookDBAuctions", ns)
    H = ns.hub
    failures = []

    def check(cond, what):
        if not cond:
            failures.append("hub: " + what)

    known = lua.eval("{ home = true, log = true, gear = true, general = true }")
    check(H.startPage(None, known) == "home", "nothing used yet: Home")
    check(H.startPage("log", known) == "log", "the page used last")
    check(H.startPage("gear", known) == "home", "never Gear upgrades by itself")
    check(H.startPage("gone", known) == "home", "a page that no longer exists: Home")
    check(H.startPage("general", known) == "general", "a settings page is remembered too")

    now = lua.eval("time({ year = 2026, month = 11, day = 21, hour = 15, min = 0, sec = 0 })")
    income = lua.eval("function(now) return { { t = now - 3600, c = 500 }, { t = now - 20 * 3600, c = 300 }, "
                      "{ t = now - 6 * 86400, c = 200 }, { t = now - 9 * 86400, c = 1000 } } end")(now)
    pending = lua.eval("{ { est = 120 }, { est = nil }, { est = 80 } }")
    today, week, waiting, est = H.income(income, pending, now)
    check(today == 500, f"today's income: {today}")
    check(week == 1000, f"the last 7 days: {week}")
    check(waiting == 3 and est == 200, f"waiting in the mail: {waiting}, ~{est}")
    check(H.income(None, None, now) == (0, 0, 0, 0), "no log yet: all zero")

    check(H.age(now - 30, now) == "just now", "age: just now")
    check(H.age(now - 12 * 60, now) == "12 min old", "age: minutes")
    check(H.age(now - 5 * 3600, now) == "5 h old", "age: hours")
    check(H.age(now - 3 * 86400, now) == "3 days old", "age: days")

    def near(a, b):
        return abs(a - b) < 0.01

    x, y = H.minimapOffset(0, "ROUND", 80)
    check(near(x, 80) and near(y, 0), f"round, angle 0: right edge ({x}, {y})")
    x, y = H.minimapOffset(225, "ROUND", 80)
    check(near(x * x + y * y, 6400), "round: always on the circle")
    x, y = H.minimapOffset(225, "SQUARE", 80)
    check(x < -56.6 and y < -56.6 and x >= -80 and y >= -80, f"square, bottom left: out in the corner ({x}, {y})")
    # LibDBIcon's shapes: CORNER-TOPRIGHT is round only in the top right quarter
    x, y = H.minimapOffset(45, "CORNER-TOPRIGHT", 80)
    check(near(x * x + y * y, 6400), "CORNER-TOPRIGHT, top right: on the circle")
    x, y = H.minimapOffset(225, "CORNER-TOPRIGHT", 80)
    check(x * x + y * y > 6400 + 1, "CORNER-TOPRIGHT, bottom left: out towards the square corner")

    # opening: a stand-in for the EverlookUI app with its sections
    lua.execute("""
      HUB_APP = { sections = { home = {}, log = {}, gear = {}, general = {} }, shown = false, opened = {} }
      function HUB_APP:Open(id) self.shown = true; self.current = id or self.current or "home"; table.insert(self.opened, self.current) end
      function HUB_APP:Close() self.shown = false end
      function HUB_APP:IsShown() return self.shown end
    """)
    G = lua.globals()
    check(H.open("log") is False, "no window yet: open says so (callers fall back to their own window)")
    ns.app = G.HUB_APP
    H.ready = True
    check(H.open("log") is True and G.HUB_APP.current == "log", "open on a page")
    check(H.isOpen("log") and not H.isOpen("home"), "which page is open")
    H.toggle("log")
    check(not G.HUB_APP.shown, "toggle on the open page closes the window")
    H.toggle("log")
    check(G.HUB_APP.shown and G.HUB_APP.current == "log", "toggle again opens it")
    H.open("nope")
    check(G.HUB_APP.current == "log", "an unknown page: the page used last")
    H.onPage(None, "general")
    check(G.MOCK_DB.hubPage == "general", "the page is remembered")
    G.EverlookDBAuctions_ToggleMain()
    check(not G.HUB_APP.shown, "the key binding toggles the window")

    # the sale card's link: into the AH log's Income page
    lua.execute("""
      ERR_AUCTION_SOLD_S = 'A buyer has been found for your auction of %s.'
      GetTime = function() return 100 end
      C_Item.GetItemInfoInstant = function(name) for id, n in pairs(MOCK_ITEMS) do if n == name then return id end end end
    """)
    ns.purchases = lua.table()
    ns.money = lua.eval("function(c) return tostring(c) .. 'c' end")
    ns.sellSettings = lua.eval("function() return { memory = {} } end")
    run(source_of("Celebrate.lua"), "Celebrate.lua", "EverlookDBAuctions", ns)
    fire = lua.eval("function(e, a) for _, f in ipairs(MOCK_FRAMES) do if f.scripts.OnEvent then f.scripts.OnEvent(f, e, a) end end end")
    fire("CHAT_MSG_SYSTEM", "A buyer has been found for your auction of Runed Copper Rod.")
    card = G.EverlookAuctionsCheer
    check(card is not None and card.more is not None, "the sale card has its Income link")
    if card is not None and card.more is not None:
        card.more.scripts.OnClick(card.more)
        check(G.HUB_APP.shown and G.HUB_APP.current == "log" and ns.purchases.mode == "income",
              f"the link opens the AH log on Income ({G.HUB_APP.current}, {ns.purchases.mode})")
    return failures


DE_SETUP = """
SHIFT = false
function IsShiftKeyDown() return SHIFT end
ERRORS = {}
function geterrorhandler() return function(e) ERRORS[#ERRORS + 1] = e end end
Enum = { TooltipDataType = { Item = 0, Unit = 2 } }
HOOKS = {}
TooltipDataProcessor = { AddTooltipPostCall = function(t, fn) HOOKS[t] = fn end }
date = os.date
-- 727: an uncommon armor item of item level 20 (the test gives its bracket 16-20 classic-db's 80% 1-2 Lesser Magic Essence, 20% 1-2 Strange Dust)
SWORD = "|cff1eff00|Hitem:727::::::::20:::::|h[Test Sword]|h|r"
ITEMS = {
  [727] = { "Test Sword", SWORD, 2, 20, 15, "Armor", "Cloth", 1, "INVTYPE_CHEST", 0, 0, 4, 1 },
  [10938] = { "Lesser Magic Essence" }, [10939] = { "Greater Magic Essence" }, [10940] = { "Strange Dust" },
}
C_Item.GetItemInfo = function(x)
  local id = type(x) == "number" and x or tonumber(tostring(x):match("item:(%d+)"))
  local it = id and ITEMS[id]
  if it then return unpack(it) end
end
C_Item.GetItemInfoInstant = function(x)
  local id = type(x) == "number" and x or tonumber(tostring(x):match("item:(%d+)"))
  local it = id and ITEMS[id]
  return id, nil, nil, nil, nil, it and it[12]
end
C_Item.GetDetailedItemLevelInfo = function() return 20 end
C_Item.GetItemMaxStackSizeByID = function() return 1 end
C_Container = {
  UseContainerItem = function() end,
  GetContainerItemLink = function(bag, slot) if bag == 0 and slot == 1 then return SWORD end end,
  GetContainerNumSlots = function() return 4 end,
}
TARGETING = false
SpellIsTargeting = function() return TARGETING end
C_Spell = { GetSpellName = function(id) if id == 13262 then return "Disenchant" end return "Other" end }
LOOT = {}
GetNumLootItems = function() return #LOOT end
GetLootSlotLink = function(i) return "|Hitem:" .. LOOT[i][1] .. "|h" end
GetLootSlotInfo = function(i) return nil, nil, LOOT[i][2] end
local h = EverlookAuctionsDB.houses["Test-Alliance"]
h.items[10938] = { 3000, 5, 1, MOCK_TIME - 600 }
h.items[10939] = { 6000, 5, 1, MOCK_TIME - 600 }
h.items[10940] = { 1000, 5, 1, MOCK_TIME - 600 }
"""


def disenchanting():
    """Disenchanting (Disenchant.lua, DisenchantOdds.lua, DisenchantLog.lua, ns.disenchantValue): the generated data
    (the client's brackets, a shield as armor, the new rare brackets not measured), the sources of the odds (this
    item's players' disenchants, its kind's summed over its item-level bracket, vanilla's measured ones for the item
    and its bracket, classic-db's; a bracket nobody measured), the lesser essence
    cap, logging a disenchant in the fixed log format, taking over DisenchantValue's log once without names, the cap,
    the tooltip lines (where the odds come from, your results, the Shift breakdown), an older DisenchantValue still
    loaded, the page's search and /dv."""
    failures = []

    def check(cond, what):
        if not cond:
            failures.append("disenchanting: " + what)

    lua = lua51.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(source_of("tests/mock.lua"))
    lua.execute(CORE_SETUP)
    lua.execute(DE_SETUP)
    run = lua.eval("function(src, name, ...) local f = assert(loadstring(src, name)); return f(...) end")
    for lib in ("Libs/LibStub/LibStub.lua", "Libs/EverlookUI/EverlookTooltip.lua"):
        run(source_of(lib), lib)
    ns = lua.table()
    G = lua.globals()
    for name in ("EverlookDBAuctions.lua", "Disenchant.lua", "DisenchantOdds.lua"):
        run(source_of(name), name, "EverlookDBAuctions", ns)
    before = len(G.MOCK_FRAMES)
    run(source_of("DisenchantLog.lua"), "DisenchantLog.lua", "EverlookDBAuctions", ns)
    de_frame = G.MOCK_FRAMES[before + 1]
    G.DEFRAME = de_frame
    fire = lua.eval("function(f, ...) f.scripts.OnEvent(f, ...) end")
    core = lua.eval("function(e, a) for _, f in ipairs(MOCK_FRAMES) do if f.scripts.OnEvent and f ~= DEFRAME then pcall(f.scripts.OnEvent, f, e, a) end end end")
    core("ADDON_LOADED", "EverlookDBAuctions")

    # the generated data (Disenchant.lua): the client's brackets and items, vanilla's measured odds, classic-db's
    K, I = ns.DE_KINDS, ns.DE_ITEMS
    n_items = lua.eval("function(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end")
    check(n_items(I) > 8000 and n_items(K) == 54, f"data: {n_items(I)} items, {n_items(K)} brackets")
    shield = K[I[9764]] if I[9764] else None   # Cadet Shield, uncommon, item level 11
    check(shield is not None and shield[1] == 4 and shield[3] == 5 and shield[5] == "m" and shield[6][1] == 10940,
          "a shield disenchants as armor: Strange Dust first, measured")
    w21 = K[7]
    check(w21[1] == 2 and w21[2] == 2 and w21[3] == 21 and w21[6][1] == 10939
          and all(w21[i][1] not in (10998, 11082) for i in range(6, len(w21) + 1)),
          "uncommon weapons 21-25: Greater Magic Essence, no Astral")
    check(all(K[k][5] == "d" for k in (335, 336, 337, 338)), "the new rare brackets: Disenchantry's rough estimate")
    r336 = K[336]
    check(r336[1] == 4 and r336[6][1] == 10940 and r336[6][2] == 75 and r336[6][3] == 3 and r336[6][4] == 4,
          "rare armor 16-20: Strange Dust 3-4 at 75%")
    check(K[337][6][1] == 10939 and K[337][6][2] == 75, "rare weapons 16-20: Greater Magic Essence first")
    # measured brackets keep the average and get classic-db's range: uncommon armor 16-20, Strange Dust 2-3
    s5 = K[5][6]
    check(s5[1] == 10940 and s5[3] == 2 and s5[4] == 3 and 2.4 < s5[5] < 2.6, f"measured: range 2-3, average {s5[5]}")
    check(any(v == 336 for v in I.values()), "items in a new rare bracket can be disenchanted")
    check(K[54][5] == "e" and K[54][6][1] == 20725, "epic 61-99: classic-db's Nexus Crystal (vanilla's era left out)")
    check(I[9764] and not I[6948], "the hearthstone can't be disenchanted")

    # from here, small brackets of our own: 727 (armor, uncommon, item level 20) in 16-20 with classic-db's odds
    ns.DE_KINDS = lua.eval("""{
      [5] = { 4, 2, 16, 20, "e", { 10938, 80, 1, 2 }, { 10940, 20, 1, 2 } },
      [8] = { 4, 2, 21, 25, "m", { 10938, 100, 9, 9 } },
      [6] = { 2, 2, 16, 20, "m", { 10938, 100, 9, 9 } },
      [336] = { 4, 3, 16, 20, false },
    }""")
    ns.DE_ITEMS = lua.eval("{ [727] = 5, [900] = 336, [901] = 5 }")
    ns.DE_ITEM_ODDS = lua.eval("{}")
    lua.execute("""
      ITEMS[900] = { "Low Rare", "|cff0070dd|Hitem:900::::::::18:::::|h[Low Rare]|h|r", 3, 18, 15, "Armor", "Cloth", 1, "INVTYPE_CHEST", 0, 0, 4, 1 }
      ITEMS[901] = { "Test Shield", "|cff1eff00|Hitem:901::::::::20:::::|h[Test Shield]|h|r", 2, 20, 15, "Armor", "Shields", 1, "INVTYPE_SHIELD", 0, 0, 4, 6 }
    """)
    lo, hi, lid = ns.deBracket(4, 2, 20)
    check(lo == 16 and hi == 20 and lid == 5, f"the bracket of armor, uncommon, 20: {lo}-{hi} ({lid})")

    # the old addon's saved log: names, realms and links that must not come over
    lua.execute("""
      DisenchantValueDB = { version = 2,
        items = { [727] = { name = "Test Sword", ilvl = 20, quality = 2, classID = 4, count = 3, mats = {} },
                  [5000] = { name = "Crate", quality = 1, classID = 15, count = 1, mats = {} } },
        log = {
          { t = 1000, char = "Alice-Realm", realmID = 6946, itemID = 727, link = SWORD, ilvl = 20, mats = { [10938] = 2 } },
          { t = 2000, char = "Bob-Realm", itemID = 727, link = SWORD, ilvl = 20, mats = { [10940] = 1 } },
          { t = 2002, char = "Bob-Realm", itemID = 727, link = SWORD, ilvl = 20, mats = { [10940] = 1 } },
          { t = 3000, char = "Bob-Realm", itemID = 5000, ilvl = 1, mats = { [123] = 1 } },
          { t = 4000, char = "Bob-Realm", itemID = 727, ilvl = 20, mats = { [10938] = "x" } },
        } }
    """)
    fire(de_frame, "PLAYER_LOGIN")
    log = G.EverlookDBAuctionsDB.deLog
    check(len(log) == 2, f"two disenchants taken over (a duplicate, a crate and a broken one left out): {len(log)}")
    if len(log) == 2:
        e = log[1]
        keys = sorted(k for k in e.keys())
        check(keys == ["cls", "ilvl", "item", "mats", "q", "t"], f"exactly the log's fields: {keys}")
        check(e.t == 1000 and e.item == 727 and e.ilvl == 20 and e.q == 2 and e.cls == 4 and e.mats[10938] == 2,
              "the first one as it was")
        check(log[2].t == 2000, "oldest first")
    check(G.SlashCmdList.EVERLOOKDBDV is not None and G.SLASH_EVERLOOKDBDV1 == "/dv", "/dv is ours")
    fire(de_frame, "PLAYER_LOGIN")
    check(len(G.EverlookDBAuctionsDB.deLog) == 2, "taken over only once")
    lua.execute("table.insert(DisenchantValueDB.log, { t = 5000, char = 'Bob', itemID = 727, ilvl = 20, mats = { [10940] = 3 } })")
    ns.deLog["import"]()
    check(len(G.EverlookDBAuctionsDB.deLog) == 3, "a newer one in the old log comes over too")

    # logging a disenchant: the cursor on the bag slot, the cast, the loot window
    G.TARGETING = True
    G.C_Container.UseContainerItem(0, 1)
    G.TARGETING = False
    fire(de_frame, "UNIT_SPELLCAST_SUCCEEDED", "player", "cast-1", 13262)
    lua.execute("LOOT = { { 10938, 1 }, { 10940, 2 } }")
    fire(de_frame, "LOOT_READY")
    fire(de_frame, "LOOT_OPENED")
    log = G.EverlookDBAuctionsDB.deLog
    check(len(log) == 4, f"the disenchant is logged once: {len(log)}")
    e = log[len(log)]
    check(e.item == 727 and e.q == 2 and e.cls == 4 and e.ilvl == 20 and e.mats[10938] == 1 and e.mats[10940] == 2
          and e.char is None and e.link is None, "in the log's format, without names or links")
    # another spell's loot is no disenchant
    fire(de_frame, "UNIT_SPELLCAST_SUCCEEDED", "player", "cast-2", 999)
    fire(de_frame, "LOOT_READY")
    check(len(G.EverlookDBAuctionsDB.deLog) == 4, "loot after another spell isn't logged")

    # the cap: the newest 5000
    lua.execute("""
      local log = EverlookDBAuctionsDB.deLog
      for i = 1, 5100 do log[#log + 1] = { t = 10000 + i, item = 727, ilvl = 20, q = 2, cls = 4, mats = { [10940] = 1 } } end
    """)
    ns.deLog.trim()
    log = G.EverlookDBAuctionsDB.deLog
    check(len(log) == 5000 and log[len(log)].t == 15100 and log[1].t == 10101, "capped at the newest 5000")
    lua.execute("local log = EverlookDBAuctionsDB.deLog; for i = #log, 1, -1 do log[i] = nil end")
    ns.deLog.changed()

    # 1. classic-db: 80% x 1.5 x 20s (lesser essence capped at a third of 60s) + 20% x 1.5 x 10s
    value, age, out, source, n = ns.disenchantValue(727)
    check(value == 2400 + 300 and source == "estimate" and n is None, f"classic-db: {value} {source}")
    G.EverlookAuctionsDB.de.essenceCap = False
    value = ns.disenchantValue(727)[0]
    check(value == 3600 + 300, f"cap off: the lesser essence's own price: {value}")
    G.EverlookAuctionsDB.de.essenceCap = True
    lua.execute("EverlookAuctionsDB.houses['Test-Alliance'].items[10938][1] = 1500")
    check(ns.disenchantValue(727)[0] == 1800 + 300, "a lesser essence under a third keeps its price")

    # 2. this item's players' disenchants (10 or more)
    lua.execute("""
      EverlookDB_DEOdds = { v = 1, updated = MOCK_TIME, items = {
        [727] = { n = 12, mats = { [10940] = { p = 1, c = 2 } } } }, kinds = {} }
    """)
    value, age, out, source, n = ns.disenchantValue(727)
    check(value == 2000 and source == "item" and n == 12, f"players' item odds: {value} {source} {n}")
    lua.execute("EverlookDB_DEOdds.items[727].n = 9")
    value, _, _, source, _ = ns.disenchantValue(727)
    check(source == "estimate" and value == 2100, f"9 of the item: not enough, classic-db: {value} {source}")

    # 3. its kind: armor, uncommon, item level 16-20 (its bracket), summed; 30 or more
    lua.execute("""
      EverlookDB_DEOdds.kinds = {
        ["4:2:18"] = { n = 20, mats = { [10940] = { p = 1, c = 1 } } },
        ["4:2:20"] = { n = 10, mats = { [10940] = { p = 0.5, c = 2 }, [10938] = { p = 0.5, c = 1 } } },
        ["4:2:21"] = { n = 500, mats = { [10938] = { p = 1, c = 9 } } },
        ["2:2:20"] = { n = 500, mats = { [10938] = { p = 1, c = 9 } } },
      }
    """)
    value, _, out, source, n = ns.disenchantValue(727)
    want = (20 * 1 + 10 * 0.5 * 2) / 30 * 1000 + (10 * 0.5 * 1) / 30 * 1500
    check(source == "kind" and n == 30 and value == int(want + 0.5),
          f"kind odds summed over the bracket (not the next bracket, not weapons): {value} vs {want}, {source} {n}")
    lua.execute('EverlookDB_DEOdds.kinds["4:2:18"].n = 19')
    check(ns.disenchantValue(727)[3] == "estimate", "29 of the kind: not enough, classic-db")
    lua.execute('EverlookDB_DEOdds.kinds["4:2:18"].n = 20')
    lua.execute('EverlookDB_DEOdds.v = 2')
    check(ns.disenchantValue(727)[3] == "estimate", "an odds table of another version is not read")
    lua.execute('EverlookDB_DEOdds.v = 1')
    api_ns = ns
    run(source_of("API.lua"), "API.lua", "EverlookDBAuctions", api_ns)
    check(G.EverlookDBAuctionsAPI.disenchant(727)[2] == "players", "the API says the odds are players'")

    # the tooltip
    show = lua.eval("""function(id, link)
      local tip = { lines = {} }
      function tip:GetOwner() return nil end
      local function s(x) return (x:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|T[^|]-UI%-(%a)%a+Icon[^|]*|t", function(c) return c:lower() end)) end
      function tip:AddLine(l) self.lines[#self.lines + 1] = s(l) end
      function tip:AddDoubleLine(l, r) self.lines[#self.lines + 1] = s(l) .. " = " .. s(r) end
      HOOKS[0](tip, { id = id, hyperlink = link })
      return table.concat(tip.lines, "\\n")
    end""")
    G.EverlookAuctionsDB.tip = lua.eval("{ verdict = false, vendor = false }")
    text = show(727, G.SWORD)
    check("Disenchants into  players' disenchants" in text, f"the line says where the odds are from: {text}")
    check("Strange Dust  1-2 (83%) = 10s" in text and "Disenchant value  10m = 12s 50c" in text,
          f"players' odds: the material, its count range from the bracket, its worth, the value: {text}")
    check("Your disenchants" not in text, f"no results logged: no line: {text}")
    lua.execute("EverlookDB_DEOdds = nil")
    text = show(727, G.SWORD)
    check("Disenchants into  estimate" in text, f"classic-db: estimate: {text}")
    check("Lesser Magic Essence  1-2 (80%) = 18s" in text and "Strange Dust  1-2 (20%) = 3s" in text,
          f"each material: count range, chance, worth (chance x average count x price): {text}")
    check("Disenchant value  10m = 21s" in text, f"then the value: {text}")
    check(text.index("Disenchants into") < text.index("Lesser Magic Essence") < text.index("Disenchant value"),
          f"in that order: {text}")
    # the old default (behind Shift) becomes the new one once; a choice made after that stays
    G.EverlookAuctionsDB.de.matsShown = None
    G.EverlookAuctionsDB.de.breakdown = "shift"
    ns.deLog.settings()
    check(G.EverlookAuctionsDB.de.breakdown == "always", "the saved old default moves to always")
    G.EverlookAuctionsDB.de.breakdown = "shift"
    ns.deLog.settings()
    check(G.EverlookAuctionsDB.de.breakdown == "shift", "a choice made later stays")
    text = show(727, G.SWORD)
    check("Lesser Magic Essence" not in text and "Disenchant  estimate · 10m = 21s" in text,
          f"behind Shift: one line without it: {text}")
    G.SHIFT = True
    text = show(727, G.SWORD)
    check("Lesser Magic Essence  1-2 (80%) = 18s" in text, f"Shift: the materials: {text}")
    G.SHIFT = False
    G.EverlookAuctionsDB.de.breakdown = "always"
    # a material without a price: its line has no worth, the value none either
    lua.execute("EverlookAuctionsDB.houses['Test-Alliance'].items[10940] = nil")
    text = show(727, G.SWORD)
    check("Strange Dust  1-2 (20%)\n" in text + "\n" and "Strange Dust  1-2 (20%) =" not in text,
          f"no price: nothing right: {text}")
    check("Disenchant value\n" in text + "\n" and "Disenchant value  " not in text, f"no value without every price: {text}")
    check(ns.disenchantValue(727) is None, "and no value for the rest of the addon")
    lua.execute("EverlookAuctionsDB.houses['Test-Alliance'].items[10940] = { 1000, 5, 1, MOCK_TIME - 600 }")
    # green when disenchanting pays more than selling, red when less
    lua.execute("ITEMS[727][11] = 5000")
    check("Disenchant value  10m = 21s" in show(727, G.SWORD), "vendor 50s: the value still shows")
    lua.execute("ITEMS[727][11] = 0")

    # 4. measured in vanilla: the bracket's, then the item's own; players' still come first
    ns.DE_KINDS[5] = lua.eval('{ 4, 2, 16, 20, "m", { 10940, 100, 2, 2 } }')
    value, _, out, source, n = ns.disenchantValue(727)
    check(value == 2000 and source == "measured" and n is None, f"the bracket measured in vanilla: {value} {source} {n}")
    check("Disenchants into  measured in vanilla" in show(727, G.SWORD), "the tooltip says measured in vanilla")
    check(G.EverlookDBAuctionsAPI.disenchant(727)[2] == "measured", "the API says measured")
    ns.DE_ITEM_ODDS[727] = lua.eval("{ 500, 10940, 50, 2, 10938, 50, 1 }")
    value, _, out, source, n = ns.disenchantValue(727)
    check(value == 1000 + 750 and source == "measured" and n == 500, f"the item's own measured odds: {value} {source} {n}")
    text = show(727, G.SWORD)
    check("Strange Dust  2 (50%) = 10s" in text and "Lesser Magic Essence  1 (50%) = 7s 50c" in text,
          f"measured: counts and worths: {text}")
    # an average outside the bracket's range: "~" and the average
    ns.DE_ITEM_ODDS[727] = lua.eval("{ 500, 10940, 100, 2.5 }")
    ns.DE_KINDS[5] = lua.eval('{ 4, 2, 16, 20, "m", { 10940, 100, 1, 2, 1.5 } }')
    text = show(727, G.SWORD)
    check("Strange Dust  ~2.5 (100%) = 25s" in text, f"an average outside the range: {text}")
    ns.DE_KINDS[5] = lua.eval('{ 4, 2, 16, 20, "m", { 10940, 100, 2, 3, 2.5 } }')
    text = show(727, G.SWORD)
    check("Strange Dust  2-3 (100%) = 25s" in text, f"inside it: the range: {text}")
    check(ns.disenchantValue(727)[0] == 2500, "the value from the average")
    ns.DE_ITEM_ODDS[727] = lua.eval("{ 500, 10940, 50, 2, 10938, 50, 1 }")
    ns.DE_KINDS[5] = lua.eval('{ 4, 2, 16, 20, "m", { 10940, 100, 2, 2 } }')
    lua.execute("""
      EverlookDB_DEOdds = { v = 1, items = { [727] = { n = 10, mats = { [10940] = { p = 1, c = 1 } } } }, kinds = {
        ["4:2:20"] = { n = 40, mats = { [10938] = { p = 1, c = 1 } } },
        ["2:2:20"] = { n = 500, mats = { [10940] = { p = 1, c = 9 } } } } }
    """)
    value, _, _, source, n = ns.disenchantValue(727)
    check(value == 1000 and source == "item" and n == 10, f"players' item odds win over vanilla's: {value} {source}")
    # a shield is armor: its players' kind is armor's, not the weapons'
    value, _, _, source, n = ns.disenchantValue(901)
    check(value == 1500 and source == "kind" and n == 40, f"a shield: armor's players' odds: {value} {source} {n}")
    lua.execute("EverlookDB_DEOdds = nil")
    value, _, _, source, _ = ns.disenchantValue(901)
    check(value == 2000 and source == "measured", f"a shield: armor's bracket: {value} {source}")
    lo, hi, lid = ns.deBracket(4, 2, 20, 6, "INVTYPE_SHIELD")
    check(lid == 5, "a shield's bracket is armor's")
    # 5. a bracket nobody measured: it can be disenchanted, but no value
    value, _, _, source = ns.disenchantValue(900)
    check(value is None and source == "unmeasured", f"a new rare bracket: not measured: {value} {source}")
    text = show(900, G.ITEMS[900][2])
    check("Disenchant = not measured yet" in text, f"the tooltip says so: {text}")
    check(G.EverlookDBAuctionsAPI.disenchant(900) is None, "the API has no value for it")
    check(ns.disenchantValue(5000) is None, "an item that can't be disenchanted: nothing")
    ns.DE_ITEM_ODDS[727] = None
    ns.DE_KINDS[5] = lua.eval('{ 4, 2, 16, 20, "e", { 10938, 80, 1, 2 }, { 10940, 20, 1, 2 } }')

    lua.execute("""
      local log = EverlookDBAuctionsDB.deLog
      log[#log + 1] = { t = 1, item = 727, ilvl = 20, q = 2, cls = 4, mats = { [10940] = 2 } }
      log[#log + 1] = { t = 2, item = 999, ilvl = 17, q = 2, cls = 4, mats = { [10938] = 2 } }
      log[#log + 1] = { t = 3, item = 998, ilvl = 21, q = 2, cls = 4, mats = { [10938] = 5 } }
    """)
    ns.deLog.changed()
    text = show(727, G.SWORD)
    check("Your disenchants  this item · 1 disenchant = ~20s" in text, f"your results for this item: {text}")
    check("Your disenchants  item level 16-20 · 2 disenchants = ~25s" in text, f"and for its bracket: {text}")
    G.EverlookAuctionsDB.de.observed = False
    check("Your disenchants" not in show(727, G.SWORD), "your results can be turned off")
    G.EverlookAuctionsDB.de.observed = True
    # an older DisenchantValue still loaded draws these itself
    lua.execute("DisenchantValue = { ObservedFor = function() end }")
    G.SHIFT = True
    text = show(727, G.SWORD)
    check("Disenchant  estimate" in text and "Your disenchants" not in text and "Lesser Magic Essence" not in text,
          f"old DisenchantValue: only our value line: {text}")
    check("Disenchants into" not in text, "and not our materials")
    G.SHIFT = False
    lua.execute("DisenchantValue = { merged = true, ObservedFor = function() end }")
    check("Your disenchants" in show(727, G.SWORD), "DisenchantValue 0.3.0 (merged): ours again")
    lua.execute("DisenchantValue = nil")

    # a rough estimate: a new rare bracket with Disenchantry's odds
    ns.DE_KINDS[336] = lua.eval('{ 4, 3, 16, 20, "d", { 10940, 75, 3, 4 }, { 10939, 20, 2, 3 }, { 10978, 5, 2, 2 } }')
    check(ns.disenchantValue(900) is None, "rough: a material without a price, no value")
    lua.execute("EverlookAuctionsDB.houses['Test-Alliance'].items[10978] = { 400, 5, 1, MOCK_TIME - 600 }")
    value, _, _, source, _ = ns.disenchantValue(900)
    want = int(0.75 * 3.5 * 1000 + 0.2 * 2.5 * 6000 + 0.05 * 2 * 400 + 0.5)
    check(value == want and source == "rough", f"rough: {value} vs {want} {source}")
    text = show(900, G.ITEMS[900][2])
    check("Disenchants into  rough estimate" in text and "Strange Dust  3-4 (75%)" in text, f"rough on the tooltip: {text}")
    check(G.EverlookDBAuctionsAPI.disenchant(900)[2] == "estimate", "the API calls it an estimate")
    ns.DE_KINDS[336] = lua.eval("{ 4, 3, 16, 20, false }")

    # the bag preview (DisenchantPreview.lua): bag 0 slot 1 holds 727
    run(source_of("DisenchantPreview.lua"), "DisenchantPreview.lua", "EverlookDBAuctions", ns)
    P = ns.dePreview
    items = P.bagItems()
    check(len(items) == 1 and items[1].id == 727 and items[1].bag == 0 and items[1].slot == 1 and items[1].value == 2100,
          f"the bags: one item that can be disenchanted, with its value: {[(items[i].id, items[i].value) for i in range(1, len(items) + 1)]}")
    lua.execute("ITEMS[727][11] = 3000")
    e = P.bagItems()[1]
    check(e.best == 3000 and not e.beats and "selling pays more" in P.summary(e), f"vendor 30s beats 21s: {P.summary(e)}")
    lua.execute("ITEMS[727][11] = 1000")
    e = P.bagItems()[1]
    check(e.beats and "beats selling" in P.summary(e), f"vendor 10s: disenchanting wins: {P.summary(e)}")
    lua.execute("ITEMS[727][11] = 0")
    check(P.macroFor(0, 1) == "/cast Disenchant\n/use 0 1", f"the button's macro: {P.macroFor(0, 1)}")
    P.select(e)
    check(P.current() is not None and P.current().id == 727, "selected: previewed")
    lua.execute("C_Container.GetContainerItemLink = function() return nil end")
    check(P.current() is None, "gone from the bag: no preview")
    P.refresh()
    check(P.selected is None, "and the selection moves on (nothing left)")
    lua.execute("C_Container.GetContainerItemLink = function(bag, slot) if bag == 0 and slot == 1 then return SWORD end end")
    lua.execute("issecretvalue = function(v) return v == SWORD end")
    check(len(P.bagItems()) == 0, "a secret link is left alone")
    lua.execute("issecretvalue = nil")

    # the page's list and search, /dv
    rec = ns.deLog.recent(10, "strange")
    check(len(rec) == 1 and rec[1].item == 727, f"search by material: {len(rec)}")
    check(len(ns.deLog.recent(10, "")) == 3, "no words: all")
    check(len(ns.deLog.recent(10, "test sword")) == 1, "search by item name")
    ns.hub = lua.eval("{ open = function(p) HUBOPEN = p end }")
    ns.app = lua.eval("{ HandleSlash = function(self, m) SLASHED = m end }")
    G.SlashCmdList.EVERLOOKDBDV("")
    check(G.HUBOPEN == "disenchant", "bare /dv opens the Disenchanting page")
    G.SlashCmdList.EVERLOOKDBDV("announce off")
    check(G.SLASHED == "deannounce off", f"/dv announce off: our setting: {G.SLASHED}")
    G.SlashCmdList.EVERLOOKDBDV("off breakdown")
    check(G.SLASHED == "off debreakdown", f"/dv off breakdown: {G.SLASHED}")
    G.SlashCmdList.EVERLOOKDBDV("quiet")
    check(G.EverlookAuctionsDB.de.announce is True, "/dv quiet switches the chat line")
    check(len(G.ERRORS) == 0, f"no errors: {list(G.ERRORS.values()) if G.ERRORS else ''}")
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

    failures += profit_columns(lua, Pr, ctxOf, seq)
    failures += profit_api()
    failures += profit_window()
    return failures


def profit_columns(lua, Pr, ctxOf, seq):
    """Crafting profit's columns (Profit.lua, no frames): money as gold/silver/copper cells that line up, the money
    boxes' parsing, sorting by each column, the filters (name, margin, cost, can make now, crafters) and the saved
    settings' migration."""
    failures = []

    def check(cond, what):
        if not cond:
            failures.append("profit columns: " + what)

    G_, S_, C_ = Pr.COIN[1], Pr.COIN[2], Pr.COIN[3]

    def cells(c, opt=None):
        t = Pr.coinCells(c, lua.table_from(opt or {}))
        return [t[1], t[2], t[3]]

    # the parts
    g, s, c, neg = Pr.coinParts(123456)
    check((g, s, c, neg) == (12, 34, 56, False), f"coin parts: {(g, s, c, neg)}")
    g, s, c, neg = Pr.coinParts(-350)
    check((g, s, c, neg) == (0, 3, 50, True), f"negative parts: {(g, s, c, neg)}")
    check(Pr.coinParts(0)[3] is False, "0 isn't negative")
    # cells: every part in its own column (gold, silver, copper), parts that are 0 left empty
    check(cells(123456) == ["12" + G_, "34" + S_, "56" + C_], f"gold, silver, copper: {cells(123456)}")
    check(cells(350, {"sign": True}) == ["", "+3" + S_, "50" + C_], f"+ on the biggest part: {cells(350, {'sign': True})}")
    check(cells(-350, {"sign": True}) == ["", "-3" + S_, "50" + C_], f"negative: {cells(-350, {'sign': True})}")
    check(cells(-350) == ["", "-3" + S_, "50" + C_], "a minus even without sign")
    check(cells(0, {"sign": True}) == ["", "", "0" + C_], f"zero: one copper cell, no sign: {cells(0, {'sign': True})}")
    check(cells(10000, {"sign": True}) == ["+1" + G_, "", ""], f"1g: silver and copper dropped: {cells(10000, {'sign': True})}")
    check(cells(10005) == ["1" + G_, "", "5" + C_], f"1g 5c: the silver cell stays empty, copper stays in its column: {cells(10005)}")
    check(cells(12345678901) == ["1,234,567" + G_, "89" + S_, "1" + C_], f"large: grouped gold: {cells(12345678901)}")
    check(cells(520, {"prefix": "≈ "}) == ["", "≈ 5" + S_, "20" + C_], f"approx: ≈ in front: {cells(520, {'prefix': '≈ '})}")
    check(cells(None) == ["", "", "?"], "no amount: ?")
    check(cells(99.6) == ["", "1" + S_, ""], "rounded to whole copper")
    # alignment: cell i only ever holds coin i, for any amount
    icons = [G_, S_, C_]
    for amount in [1, 99, 100, 101, 9999, 10000, 10099, 999999, -1, -10101, 123456789]:
        cs = cells(amount, {"sign": True})
        for i in range(3):
            check(cs[i] == "" or cs[i].endswith(icons[i]) and sum(cs[i].count(x) for x in icons) == 1,
                  f"{amount}: cell {i + 1} holds only its own coin: {cs}")

    # box text and parsing
    check(Pr.moneyText(12050) == "1g 20s 50c" and Pr.moneyText(300) == "3s" and Pr.moneyText(0) == "0c"
          and Pr.moneyText(-5) == "-5c" and Pr.moneyText(None) == "", "money text for the boxes")
    for text, want in [("1g 20s", 12000), ("120s", 12000), ("1.2g", 12000), ("3", 300), ("1g20s5c", 12005), ("50c", 50),
                       ("1,000g", 10000000), (" 2.5 ", 250), ("1G 5S", 10500), ("0.5s", 50)]:
        got = Pr.parseMoney(text)
        check(got == (want, True), f"parse {text!r}: {got}")
    for text in ["abc", "1g 2", "1g 1g", "g", "-5s"]:
        check(Pr.parseMoney(text) == (None, False), f"not money: {text!r}: {Pr.parseMoney(text)}")
    check(Pr.parseMoney("") == (None, True) and Pr.parseMoney("  ") == (None, True), "empty: cleared")
    for amount in [1, 300, 12050, 10000000, 105]:
        check(Pr.parseMoney(Pr.moneyText(amount))[0] == amount, f"round trip {amount}")

    # sorting by each column
    lua.execute("""
      SROWS = function() return {
        { id = 1, name = "Bravo", skill = 50, cost = 300, sale = 900, profit = 600, margin = 2 },
        { id = 2, name = "alpha", skill = 10, cost = 100, sale = 200, profit = 100, margin = 1 },
        { id = 3, name = "Charlie", skill = nil, cost = 50, sale = 1000, profit = 950, margin = 19, approx = true },
        { id = 4, name = "Delta", skill = 30, cost = 200, sale = 150, profit = -50, margin = -0.25 },
      } end
    """)
    G = lua.globals()

    def order(key, desc, crafts=None):
        rows = G.SROWS()
        opt = lua.table_from({"crafts": lua.table_from(crafts or {})})
        Pr.sort(rows, key, desc, opt)
        return [r.id for r in seq(rows)]

    check(order("profit", True) == [3, 1, 2, 4], f"profit high first: {order('profit', True)}")
    check(order("profit", False) == [4, 2, 1, 3], f"profit low first: {order('profit', False)}")
    check(order("name", False) == [2, 1, 3, 4], f"name A-Z, any case: {order('name', False)}")
    check(order("name", True) == [4, 3, 1, 2], f"name Z-A: {order('name', True)}")
    check(order("skill", False) == [2, 4, 1, 3], f"skill low first, unknown last: {order('skill', False)}")
    check(order("skill", True) == [1, 4, 2, 3], f"skill high first, unknown still last: {order('skill', True)}")
    check(order("cost", False) == [3, 2, 4, 1], f"cost cheapest first: {order('cost', False)}")
    check(order("cost", True) == [1, 4, 2, 3], f"cost dearest first: {order('cost', True)}")
    check(order("sale", True) == [3, 1, 2, 4], f"sells for, high first: {order('sale', True)}")
    check(order("sale", False) == [4, 2, 1, 3], f"sells for, low first: {order('sale', False)}")
    check(order("margin", True) == [1, 2, 4, 3], f"margin high first; ≈ has none, so last: {order('margin', True)}")
    check(order("margin", False) == [4, 2, 1, 3], f"margin low first, ≈ last: {order('margin', False)}")
    check(order("crafts", True, {4: 5, 2: 1}) == [4, 2, 3, 1], f"planned crafts first, then by profit: {order('crafts', True, {4: 5, 2: 1})}")
    check(order("bogus", False) == [4, 2, 1, 3] and order("bogus", True) == [3, 1, 2, 4], "an unknown column sorts by profit")
    check(Pr.SORTS.name is False and Pr.SORTS.cost is False and Pr.SORTS.profit is True and Pr.SORTS.margin is True,
          "first click: names A-Z, cost cheapest first, profit and margin high first")

    # the filters (over the Linen recipes of profit())
    def names(flt):
        rows, _ = Pr.list(ctxOf(Pr), lua.table_from(flt))
        return sorted(r.name for r in seq(rows))

    check(names({"q": "linen"}) == ["Bolt of Linen Cloth", "Linen Bag", "Linen Shirt"], f"search: {names({'q': 'linen'})}")
    check(names({"q": "  SHIRT "}) == ["Linen Shirt"], "search: any case, spaces trimmed")
    check(names({"q": "nothing like it"}) == [], "search: no match")
    # margins: bag 350/144 = 243%, shirt 85/48 = 177%, bolt 54/36 = 150%; the wand is ≈ (no real margin)
    check(names({"minMargin": 177}) == ["Linen Bag", "Linen Shirt", "Two at a time"], f"margin at least: {names({'minMargin': 177})}")
    check("Lesser Magic Wand" not in names({"minMargin": 0}), "margin filter leaves ≈ rows out")
    check(names({"maxCost": 48}) == ["Bolt of Linen Cloth", "Linen Shirt"], f"cost at most 48c: {names({'maxCost': 48})}")
    check(names({"maxCost": 48, "q": "bolt"}) == ["Bolt of Linen Cloth"], "filters add up")
    # can make now: you have 2 cloth (a bolt), and the bag needs 3 bolts and 3 thread
    bags = {2589: 2}
    can_me = lambda c, r: Pr.canMake(r, lambda i: bags.get(i, 0))
    _cm = names({"canMake": can_me})
    check(_cm == ["Bolt of Linen Cloth"], f"only what you can make now: {_cm}")
    check(Pr.canMake(G.RECIPES[2996], lambda i: 2) is True and Pr.canMake(G.RECIPES[2996], lambda i: 1) is False, "canMake counts")
    # crafters: Bob knows the bag and has its materials; you know everything and have cloth
    G.PRMERGE = Pr.merge
    lua.execute("""
      ME = { me = true, name = "Me", recipes = RECIPES }
      BOB = { key = "Player-1-Bob", name = "Bob", recipes = { [4238] = RECIPES[4238], [77] = { mats = { { 2589, 1 } }, makes = 1, name = "Bob's own" } },
        bags = { [2996] = 3, [2320] = 3 } }
      MRECIPES, MWHO = PRMERGE({ ME, BOB })
    """)
    check(G.MRECIPES[77] is not None and lua.eval("function(a, b) return a == b end")(G.MRECIPES[4238], G.RECIPES[4238]), "merge: every crafter's recipes")
    check([c.name for c in seq(G.MWHO[4238])] == ["Me", "Bob"] and [c.name for c in seq(G.MWHO[77])] == ["Bob"],
          "merge: who knows each, you first")
    mctx = Pr.context(lua.table_from({"recipes": G.MRECIPES, "price": G.PRICE, "cut": 0.05, "info": G.INFO}))
    G.PRICES[77] = 500
    per = lua.eval("""function(Pr, ctx, who, canOn)
      local can = canOn and function(c, r)
        local bags = c.bags or { [2589] = 2 }
        return Pr.canMake(r, function(id) return bags[id] or 0 end)
      end or nil
      local rows = Pr.list(ctx, { who = who, canMake = can })
      local out = {}
      for _, r in ipairs(rows) do
        local w = {}
        for _, c in ipairs(r.who or {}) do w[#w + 1] = c.name end
        out[r.name] = table.concat(w, "+")
      end
      return out
    end""")
    allw = per(Pr, mctx, G.MWHO, False)
    check(allw["Linen Bag"] == "Me+Bob" and allw["Bob's own"] == "Bob" and allw["Linen Shirt"] == "Me", f"rows say who: {dict(allw.items())}")
    mctx = Pr.context(lua.table_from({"recipes": G.MRECIPES, "price": G.PRICE, "cut": 0.05, "info": G.INFO}))
    noww = per(Pr, mctx, G.MWHO, True)
    check(dict(noww.items()) == {"Linen Bag": "Bob", "Bolt of Linen Cloth": "Me"},
          f"can make now, per crafter (Bob has the bag's materials, you only cloth): {dict(noww.items())}")
    G.PRICES[77] = None

    # settings: migration of v1 (from, to, min in copper from the silver box / profitmin) and Clear filters
    old = lua.eval("{ from = '40', to = 500, min = 300, noCraft = true, pos = { 'CENTER', 'CENTER', 0, 0 } }")
    Pr.migrate(old)
    check(old.v == 2 and old['from'] == 40 and old.to is None and old.min == 300 and old.noCraft is True and old.pos is not None,
          "migrate v1: numbers kept (min stays copper), a skill out of range dropped, the rest untouched")
    bad = lua.eval("{ min = -5, from = 'x', sort = 'bogus', desc = true, q = '', canMake = 'yes' }")
    Pr.migrate(bad)
    check(bad.min is None and bad['from'] is None and bad.sort is None and bad.desc is None and bad.q is None and bad.canMake is None,
          "migrate: nonsense dropped")
    cur = lua.eval("{ v = 2, min = -5, sort = 'cost', desc = false }")
    Pr.migrate(cur)
    check(cur.min == -5 and cur.sort == "cost", "already v2: left alone")
    s = lua.eval("{ v = 2, from = 10, to = 200, min = 100, maxCost = 5000, minMargin = 20, q = 'bag', canMake = true, sort = 'name', desc = false, noCraft = true }")
    check(Pr.filtered(s) is True, "filtered")
    Pr.clearFilters(s)
    check(all(s[k] is None for k in ["from", "to", "min", "maxCost", "minMargin", "q", "canMake", "sort", "desc"]) and s.noCraft is True,
          "Clear filters: every filter and the sort go, other settings stay")
    check(Pr.filtered(s) is False and Pr.filtered(lua.eval("{ from = 1, to = 300 }")) is False, "the whole range isn't a filter")
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

    check(api.version == 7, "version 7")
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


def profit_window_setup(profit=None, char_db=None, craft_api=False):
    """A fresh game with the Linen recipes, prices, and the window loaded; profit = db.profit as saved (Lua source),
    char_db = EverlookAuctionsCharDB (Lua source), craft_api = a fake EverlookDB Crafting API v6 with an alt, Bob.
    Returns lua, ns, W, DB and the settings the window registered (by key)."""
    lua = lua51.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(source_of("tests/mock.lua"))
    lua.execute("""
      MOCK_TIME = 100000; function time() return MOCK_TIME end
      UISpecialFrames = UISpecialFrames or {}; tinsert = tinsert or table.insert
      function IsShiftKeyDown() return false end
      wipe = wipe or function(t) for k in pairs(t) do t[k] = nil end return t end
      GetRealmName = GetRealmName or function() return "Realm" end
      UnitFactionGroup = UnitFactionGroup or function() return "Alliance" end
      RAID_CLASS_COLORS = { MAGE = { r = 0.25, g = 0.78, b = 0.92 } }
      MOCK_ITEMS[2589], MOCK_ITEMS[2996], MOCK_ITEMS[2320] = "Linen Cloth", "Bolt of Linen Cloth", "Coarse Thread"
      MOCK_ITEMS[4238], MOCK_ITEMS[2570], MOCK_ITEMS[4307] = "Linen Bag", "Linen Shirt", "Heavy Linen Gloves"
      MOCK_BAGS = {}
    """)
    if char_db:
        lua.execute("EverlookAuctionsCharDB = " + char_db)
    if craft_api:
        lua.execute("""
          CRAFT_CHARS = {
            { key = "Player-1-Me", name = "Me", class = "WARRIOR", me = true, profs = { { skill = 197, name = "Tailoring", rank = 75, known = 3 } } },
            { key = "Player-1-Bob", name = "Bob", class = "MAGE", profs = { { skill = 197, name = "Tailoring", rank = 210, known = 2 },
              { skill = 333, name = "Enchanting", rank = 150, known = 1 } } },
          }
          CRAFT_RECIPES = { ["Player-1-Me"] = {},
            ["Player-1-Bob"] = { { spell = 3755, name = "Linen Bag", skill = 197, creates = 4238, yield = 1, mats = { { 2996, 3 }, { 2320, 3 } } },
              { spell = 3843, name = "Heavy Linen Gloves", skill = 197, creates = 4307, yield = 1, mats = { { 2996, 2 } } } } }
          CRAFT_BAGS = { ["Player-1-Bob"] = { [2996] = 2 } }
          EverlookCraftAPI = { version = 6, characters = function() return CRAFT_CHARS end,
            recipesOf = function(k) return CRAFT_RECIPES[k] end, bagsOf = function(k) return CRAFT_BAGS[k] or {} end }
        """)
    ns = lua.table()
    realm = lua.eval("GetRealmName()") + "-" + lua.eval("UnitFactionGroup('player')")
    lua.globals().MOCK_HOUSE = realm
    DB = lua.eval("""{ houses = { [MOCK_HOUSE] = { scanned = 99000, items = {
        [2589] = { 18, 1, 1, 99000 }, [2996] = { 95, 1, 1, 99000 }, [2320] = { 12, 1, 1, 99000 }, [4238] = { 520, 1, 1, 99000 },
        [2570] = { 140, 1, 1, 99000 }, [4307] = { 400, 1, 1, 99000 } } } },
      crafts = {
        [2996] = { mats = { { 2589, 2 } }, makes = 1, rid = 1, name = "Bolt of Linen Cloth" },
        [4238] = { mats = { { 2996, 3 }, { 2320, 3 } }, makes = 1, rid = 2, name = "Linen Bag" },
        [2570] = { mats = { { 2996, 1 }, { 2320, 1 } }, makes = 1, rid = 3, name = "Linen Shirt" },
      } }""")
    if profit:
        DB.profit = lua.eval(profit)
    lua.globals().MOCK_DB = DB
    ns.db = lua.eval("function() return MOCK_DB end")
    ns.money = lua.eval("function(c) return tostring(c) .. 'c' end")
    ns.ago = lua.eval("function() return '17 min ago' end")
    ns.itemFor = lua.eval("function(id) return MOCK_DB.houses[MOCK_HOUSE].items[id] end")
    # a fake /eah app that keeps what the window registers
    lua.execute("""
      APP_SETTINGS = {}
      FAKE_APP = { Setting = function(self, def) APP_SETTINGS[def.key] = def end, Command = function() end,
        Section = function(self, id, title, build) APP_SECTION = build end, GetSetting = function() end, Widget = function() end }
    """)
    run = lua.eval("function(src, name, ...) local f = assert(loadstring(src, name)); return f(...) end")
    run(source_of("Skin.lua"), "Skin.lua", "EverlookDBAuctions", ns)
    for name in ["Libs/EverlookUI/EverlookUI.lua", "RecipeList.lua", "Profit.lua", "ProfitWindow.lua"]:
        run(source_of(name), name, "EverlookDBAuctions", ns)
    ns.app = lua.globals().FAKE_APP
    # ADDON_LOADED: the window adds its settings to the app
    lua.execute("""
      for _, f in ipairs(MOCK_FRAMES) do
        local h = f.scripts and f.scripts.OnEvent
        if h then pcall(h, f, "ADDON_LOADED", "EverlookDBAuctions") end
      end
    """)
    return lua, ns, ns.profitWindow, DB, lua.globals().APP_SETTINGS


def profit_window():
    """The window over a few recipes: rows best first, money in coin columns, planned crafts, Make shopping list, the
    filter boxes, sorting by the headings, Clear filters, saved filters and sort, the old minimum profit, alts."""
    failures = []

    def check(cond, what):
        if not cond:
            failures.append("profit window: " + what)

    lua, ns, W, DB, settings = profit_window_setup()
    Pr = ns.profit
    G_, S_, C_ = Pr.COIN[1], Pr.COIN[2], Pr.COIN[3]
    W.open()
    f = W.frame
    check(f is not None and f.shown, "the window opens")
    if not f or not f.shown:
        return failures

    def shown_names():
        return [f.rows[i].data.name for i in range(1, len(f.rows) + 1) if f.rows[i].shown]

    def cells(cell):
        return [cell.p[1].text, cell.p[2].text, cell.p[3].text]

    def typed(box, text):
        box.SetText(box, text)
        box.scripts.OnTextChanged(box, True)

    check(shown_names() == ["Linen Bag", "Linen Shirt", "Bolt of Linen Cloth"], f"best profit first: {shown_names()}")
    # money in coin columns: gold, silver, copper each in its own cell, right-aligned at fixed places
    check(cells(f.rows[1].profit) == ["", "+3" + S_, "50" + C_], f"bag profit cells: {cells(f.rows[1].profit)}")
    check(cells(f.rows[1].cost) == ["", "1" + S_, "44" + C_], f"bag cost cells: {cells(f.rows[1].cost)}")
    check(cells(f.rows[1].sale) == ["", "4" + S_, "94" + C_], f"bag sale cells: {cells(f.rows[1].sale)}")
    check(cells(f.rows[3].profit) == ["", "", "+54" + C_], f"bolt profit: only copper, in the copper column: {cells(f.rows[3].profit)}")
    pts = [f.rows[1].profit.p[i].point for i in (1, 2, 3)]
    check([p[4] for p in pts] == [-60, -30, 0] and all(p[1] == "RIGHT" for p in pts),
          f"coin cells right-aligned 30 px apart: {[(p[1], p[4]) for p in pts]}")
    check(f.rows[1].profit.p[3].color[2] > 0.7, "profit is green")
    check(f.rows[1].margin.text == "+243%", f"bag margin: {f.rows[1].margin.text}")
    check(f.pos.text == "3 recipes", f"the count under the list: {f.pos.text}")
    check(f.heads.profit.arrow.shown and f.heads.profit.desc is True and not f.heads.name.arrow.shown,
          "the profit heading has the arrow, high to low")
    check(f.heads.name.label.text == "RECIPE", f"the recipe heading: {f.heads.name.label.text}")
    check(not f.alts.shown, "no Alts list without EverlookDB Crafting")
    check(not f.clearFilters.shown, "no Clear filters while nothing is filtered")

    W.crafts[4238] = 4
    W.footer()
    check("4 crafts" in f.sum.text, f"the plan line: {f.sum.text}")
    lua.execute("REAL_AFTER = C_Timer.After; LATER = {}; C_Timer.After = function(_, fn) LATER[#LATER + 1] = fn end")
    W.makeList()
    lists = DB.lists
    check(lists is not None and len(lists) == 1 and lists[1].name == "Linen Bag", "one recipe: the list is named after it")
    if lists is not None and len(lists) == 1:
        want = lists[1].want
        check(want['name is "Linen Cloth"'] == 24 and want['name is "Coarse Thread"'] == 12 and want['name is "Bolt of Linen Cloth"'] is None,
              f"bolts broken down into cloth: {[(k, want[k]) for k in want]}")
    check(W.status is not None and "Saved as" in W.status[1], "says it was saved")
    lua.execute("C_Timer.After = REAL_AFTER; for _, fn in ipairs(LATER) do fn() end")
    check(W.status is None, "the saved note fades away after a few seconds")
    W.crafts[4238] = None

    # sorting: click a heading, again for the other way; remembered
    def click(key):
        h = f.heads[key]
        h.scripts.OnClick(h)

    click("name")
    check(shown_names() == ["Bolt of Linen Cloth", "Linen Bag", "Linen Shirt"], f"by name A-Z: {shown_names()}")
    check(DB.profit.sort == "name" and DB.profit.desc is False, "the sort is saved")
    check(f.heads.name.arrow.shown and f.heads.name.desc is False and not f.heads.profit.arrow.shown, "the arrow moves to Recipe")
    click("name")
    check(shown_names() == ["Linen Shirt", "Linen Bag", "Bolt of Linen Cloth"], f"again: Z-A: {shown_names()}")
    click("cost")
    check(shown_names() == ["Bolt of Linen Cloth", "Linen Shirt", "Linen Bag"], f"by cost, cheapest first: {shown_names()}")
    click("sale")
    check(shown_names() == ["Linen Bag", "Linen Shirt", "Bolt of Linen Cloth"], f"by sells for, high first: {shown_names()}")
    click("sale")
    check(shown_names() == ["Bolt of Linen Cloth", "Linen Shirt", "Linen Bag"], f"sells for, low first: {shown_names()}")
    click("margin")
    check(shown_names() == ["Linen Bag", "Linen Shirt", "Bolt of Linen Cloth"], f"by margin: {shown_names()}")
    click("skill")
    check(shown_names() == ["Linen Bag", "Linen Shirt", "Bolt of Linen Cloth"], f"by skill (none known: by profit): {shown_names()}")
    W.crafts[2996] = 2
    click("crafts")
    check(shown_names()[0] == "Bolt of Linen Cloth", f"by planned crafts: {shown_names()}")
    W.crafts[2996] = None
    click("profit")
    check(shown_names() == ["Linen Bag", "Linen Shirt", "Bolt of Linen Cloth"], f"back to profit: {shown_names()}")
    check(DB.profit.sort is None and DB.profit.desc is None, "profit high to low is the default: nothing saved")
    click("profit")
    check(shown_names() == ["Bolt of Linen Cloth", "Linen Shirt", "Linen Bag"] and DB.profit.sort == "profit" and DB.profit.desc is False,
          f"profit low to high: {shown_names()}")
    check(f.clearFilters.shown, "a sort other than the default can be cleared")
    click("profit")

    # filters
    typed(f.search, "shirt")
    check(shown_names() == ["Linen Shirt"] and DB.profit.q == "shirt", f"search: {shown_names()}")
    check(f.pos.text == "1 recipe", f"the count follows the filters: {f.pos.text}")
    check(f.clearFilters.shown, "Clear filters shows")
    typed(f.search, "")
    check(len(shown_names()) == 3 and DB.profit.q is None, "search cleared")
    typed(f.margin, "160")
    check(shown_names() == ["Linen Bag", "Linen Shirt"] and DB.profit.minMargin == 160, f"margin at least 160%: {shown_names()}")
    typed(f.margin, "")
    typed(f.maxCost, "1s")
    check(shown_names() == ["Linen Shirt", "Bolt of Linen Cloth"] and DB.profit.maxCost == 100, f"cost at most 1s: {shown_names()}")
    typed(f.maxCost, "1g 2")
    check(DB.profit.maxCost == 100 and shown_names() == ["Linen Shirt", "Bolt of Linen Cloth"], "not money: the filter stays")
    f.maxCost.scripts.OnEditFocusLost(f.maxCost)
    check(f.maxCost.text == "1s", f"leaving the box writes the amount back: {f.maxCost.text}")
    typed(f.maxCost, "")
    typed(f.min, "85c")
    check(shown_names() == ["Linen Bag", "Linen Shirt"] and DB.profit.min == 85, f"profit at least 85c: {shown_names()}")
    typed(f.min, "")
    typed(f['from'], "50")
    check(shown_names() == [], "a narrowed skill range leaves out recipes whose skill isn't known")
    check("filters" in f.empty.text, f"the empty list says why: {f.empty.text}")
    typed(f['from'], "1")
    lua.execute("MOCK_BAGS = { [2589] = 2 }")
    f.canMake.scripts.OnClick(f.canMake)
    check(shown_names() == ["Bolt of Linen Cloth"] and DB.profit.canMake is True and f.canMake.on, f"only what I can make now: {shown_names()}")
    lua.execute("MOCK_BAGS = { [2589] = 2, [2996] = 3, [2320] = 3 }")
    W.refresh()
    check(len(shown_names()) == 3, f"follows the bags: {shown_names()}")

    # Clear filters
    typed(f.search, "linen")
    typed(f.margin, "10")
    click("cost")
    f.clearFilters.scripts.OnClick(f.clearFilters)
    p = DB.profit
    check(all(p[k] is None for k in ["q", "minMargin", "maxCost", "min", "canMake", "sort", "desc", "from", "to"]), "Clear filters clears them")
    check(f.search.text == "" and f.margin.text == "" and f['from'].text == "1" and f.to.text == "300" and not f.canMake.on,
          "and empties the boxes")
    check(shown_names() == ["Linen Bag", "Linen Shirt", "Bolt of Linen Cloth"], f"every recipe, best profit first: {shown_names()}")

    # the old minimum profit box: a plain number is silver
    typed(f.min, "3")
    check(shown_names() == ["Linen Bag"], f"profit at least 3 silver: {shown_names()}")
    check(DB.profit.min == 300, "the minimum is kept in copper")

    # the settings: profitmin is still silver, and the settings search finds the new filters
    pm = settings["profitmin"]
    check(pm is not None and pm.get() == 3, "profitmin reads the box's minimum in silver")
    pm.set(5)
    check(DB.profit.min == 500 and f.min.text == "5s", f"profitmin 5 is 5 silver, and the box says so: {f.min.text}")
    kw = [pm.keywords[i] for i in range(1, len(pm.keywords) + 1)]
    for word in ["margin", "cost", "search", "sort", "alts", "can make", "gold"]:
        check(word in kw, f"settings search word {word!r}")

    # saved filters and sort come back in a new session; the old v1 settings are migrated
    lua2, ns2, W2, DB2, settings2 = profit_window_setup(
        "{ v = 2, sort = 'cost', desc = false, q = 'linen', minMargin = 160, maxCost = 20000, pos = { 'CENTER', 'CENTER', 1, 2 } }")
    W2.open()
    f2 = W2.frame
    names2 = [f2.rows[i].data.name for i in range(1, len(f2.rows) + 1) if f2.rows[i].shown]
    check(names2 == ["Linen Shirt", "Linen Bag"], f"saved sort and filters: {names2}")
    check(f2.search.text == "linen" and f2.margin.text == "160" and f2.maxCost.text == "2g", "saved filters in their boxes")
    check(f2.heads.cost.arrow.shown and f2.heads.cost.desc is False, "the saved sort's arrow")
    lua3, ns3, W3, DB3, settings3 = profit_window_setup("{ from = 1, to = 300, min = 300 }")
    W3.open()
    f3 = W3.frame
    names3 = [f3.rows[i].data.name for i in range(1, len(f3.rows) + 1) if f3.rows[i].shown]
    check(DB3.profit.v == 2 and DB3.profit.min == 300, "v1 settings migrated, the minimum kept")
    check(names3 == ["Linen Bag"] and f3.min.text == "3s", f"the old 3 silver minimum still filters, as money: {names3} {f3.min.text}")
    check(settings3["profitmin"].get() == 3, "and profitmin still says 3")

    # alts (EverlookDB Crafting API v6), ticked per character
    lua4, ns4, W4, DB4, _ = profit_window_setup(craft_api=True)
    W4.open()
    f4 = W4.frame

    def names4():
        return [f4.rows[i].data.name for i in range(1, len(f4.rows) + 1) if f4.rows[i].shown]

    check(f4.alts.shown and f4.altsText.text == "Alts: none", f"the Alts list with Crafting: {f4.altsText.text}")
    check(names4() == ["Linen Bag", "Linen Shirt", "Bolt of Linen Cloth"], f"without alts: your recipes (Crafting has none for you: this addon's) {names4()}")
    check(all(f4.rows[i].tag.text == "" for i in (1, 2, 3)), "no name tags without alts")
    W4.toggleAlt("Player-1-Bob")
    G4 = lua4.globals()
    check(G4.EverlookAuctionsCharDB.profitAlts["Player-1-Bob"] is True, "the tick is saved per character")
    check(f4.altsText.text == "Alts: Bob", f"the list says who: {f4.altsText.text}")
    check(names4() == ["Linen Bag", "Heavy Linen Gloves", "Linen Shirt", "Bolt of Linen Cloth"],
          f"Bob's recipes join: {names4()}")
    tags = {f4.rows[i].data.name: f4.rows[i].tag.text for i in range(1, len(f4.rows) + 1) if f4.rows[i].shown}
    check("you" in tags["Linen Bag"] and "+ 1" in tags["Linen Bag"], f"both know the bag: you + 1: {tags['Linen Bag']}")
    check("Bob" in tags["Heavy Linen Gloves"] and "you" not in tags["Heavy Linen Gloves"], f"only Bob: {tags['Heavy Linen Gloves']}")
    check("you" in tags["Linen Shirt"] and "+" not in tags["Linen Shirt"], f"only you: {tags['Linen Shirt']}")
    check(W4.profText(G4.CRAFT_CHARS[2].profs) == "Tailoring 210, Enchanting 150", "an alt's professions with skill")
    # can make now, per crafter: Bob has 2 bolts (the gloves), you have nothing
    f4.canMake.scripts.OnClick(f4.canMake)
    check(names4() == ["Heavy Linen Gloves"], f"only Bob can make the gloves now: {names4()}")
    W4.toggleAlt("Player-1-Bob")
    check(G4.EverlookAuctionsCharDB.profitAlts["Player-1-Bob"] is None and f4.altsText.text == "Alts: none", "untick")
    # remembered: a new session on this character has Bob ticked
    lua5, ns5, W5, DB5, _ = profit_window_setup(char_db="{ profitAlts = { ['Player-1-Bob'] = true } }", craft_api=True)
    W5.open()
    check(W5.frame.altsText.text == "Alts: Bob" and W5.multi, "the ticked alts come back")
    # the alts popup lists you (always in) and Bob with a tick box
    W5.openAlts(W5.frame.alts)
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


def profit_tab():
    """The auction house's Crafting tab (ProfitWindow.lua), like the Upgrades tab: made when the auction house opens
    but never opened by itself; opened by its tab or /eah profit there (else the main window's page); closed by the
    other tabs and when the auction house closes; the main window's page takes the view back, and leaving that page
    doesn't hide the tab's view. At the auction house the gold button is Buy materials (Buy this list on the plan)."""
    failures = []

    def check(cond, what):
        if not cond:
            failures.append("crafting tab: " + what)

    lua, ns, W, DB, _ = profit_window_setup(craft_api=True)
    lua.execute("""
      AuctionHouseFrame = CreateFrame("Frame", "AuctionHouseFrame")
      TABS, TITLES, CLOSED, HUB, BEGUN, BLIZZ = {}, {}, {}, {}, {}, {}
    """)
    G = lua.globals()
    ns.makeTab = lua.eval("""function(name, text, onClick, onBlizzard, place)
      local t = CreateFrame("Button", name)
      TABS[#TABS + 1] = { name = name, text = text, onClick = onClick, place = place }
      return t
    end""")
    ns.ahTitle = lua.eval("function(t) TITLES[#TITLES + 1] = t or false end")
    ns.blizzardTabs = lua.eval("function(on) BLIZZ[#BLIZZ + 1] = on end")
    ns.buyList = lua.eval("{ begin = function(l) BEGUN[#BEGUN + 1] = l.name; return true end }")
    inner = ns.closeOthers
    ns.closeOthers = lua.eval("function(inner) return function(e) CLOSED[#CLOSED + 1] = e; inner(e) end end")(inner)
    ns.hub = lua.eval("""{ ready = true,
      open = function(page) HUB[#HUB + 1] = page; return true end,
      isOpen = function() return false end, close = function() end,
      dock = function(f, holder) f:SetParent(holder) end }""")
    fire = lua.eval("function(e) for _, f in ipairs(MOCK_FRAMES) do if f.scripts.OnEvent then f.scripts.OnEvent(f, e) end end end")
    ah = G.AuctionHouseFrame
    same = lua.eval("rawequal")

    def seq(t):
        return [t[i] for i in range(1, len(t) + 1)]

    fire("AUCTION_HOUSE_SHOW")
    tabs = seq(G.TABS)
    check(len(tabs) == 1 and tabs[0].text == "Crafting" and tabs[0].place == "crafts",
          f"the auction house opening makes the Crafting tab: {[(t.text, t.place) for t in tabs]}")
    check(not W.inAH and not (W.frame and W.frame.shown and same(W.frame.parent, ah)),
          "the auction house opening never opens the Crafting tab")
    check('noteTab("crafts")' not in source_of("ProfitWindow.lua"), "the Crafting tab isn't noted as the last tab")
    fire("AUCTION_HOUSE_SHOW")
    check(len(G.TABS) == 1, "the tab is made once")

    # its tab, or /eah profit at the auction house
    tabs[0].onClick()
    f = W.frame
    check(W.inAH and f.shown and same(f.parent, ah), "clicking the tab shows the view in the auction house")
    check("crafts" in seq(G.CLOSED), f"opening it closes the other tabs: {seq(G.CLOSED)}")
    check(seq(G.TITLES)[-1] == "Crafting profit", f"the window's title: {seq(G.TITLES)}")
    check(f.point is not None and f.point[1] == "BOTTOMRIGHT" and f.point[5] == (ns.BAR_H or 0) + 2,
          f"it fills the content area above the price bar: {f.point}")
    check(4 <= W.rowsShown() <= 12, f"rows that fit the auction house: {W.rowsShown()}")
    check(not f.title.shown and not f.icon.shown, "no title of its own there (the auction house's title says it)")
    check(f.make.label.text == "Buy materials", f"the gold button at the auction house: {f.make.label.text}")

    # another tab closes it
    ns.closeOthers("shopping")
    check(not W.inAH and not f.shown, "another tab closes it")
    check(seq(G.TITLES)[-1] is False and seq(G.BLIZZ)[-1] is True, "Blizzard's title and tabs come back")
    ns.slash("profit")
    check(W.inAH and f.shown and same(f.parent, ah), "/eah profit at the auction house opens the tab")
    check(seq(G.HUB) == [], f"not the main window: {seq(G.HUB)}")

    # Buy materials: the shopping list, then Buy this list on it
    W.crafts[4238] = 2
    W.footer()
    f.make.scripts.OnClick(f.make)
    check(seq(G.BEGUN) == ["Linen Bag"], f"Buy materials starts Buy this list on the plan: {seq(G.BEGUN)}")
    W.crafts[4238] = None

    # leaving the main window's page doesn't hide the tab's view; the page takes it back
    W.undock()
    check(f.shown and W.inAH, "leaving the main window's page leaves the tab alone")
    holder = lua.eval("CreateFrame('Frame')")
    W.dock(holder)
    check(not W.inAH and same(f.parent, holder) and f.shown, "the main window's page takes the view back")
    check(f.title.shown and f.make.label.text == "Make shopping list", "with its own title and the usual button there")
    check(W.rowsShown() == 12, f"every row in the main window: {W.rowsShown()}")
    tabs[0].onClick()
    check(W.inAH and same(f.parent, ah), "the tab takes it again")

    # the auction house closes
    fire("AUCTION_HOUSE_CLOSED")
    check(not W.inAH and not f.shown, "closing the auction house closes the tab")
    ah.shown = False
    ns.slash("profit")
    check(seq(G.HUB) == ["crafts"] and not W.inAH, f"/eah profit away from it: the main window's page: {seq(G.HUB)}")
    return failures


def profit_queue():
    """Crafting profit with EverlookDB Crafting's crafting queue (API v8): the planned crafts are that queue. A row's
    box shows and sets its queued count, a click on a row with nothing queued queues 5, the line under the list sums the
    whole queue, Make shopping list / Buy materials buy what the whole queue misses (vendor goods left out) as the list
    "Crafting queue", Clear queue takes two clicks, and a change in the queue repaints the boxes."""
    failures = []

    def check(cond, what):
        if not cond:
            failures.append("profit queue: " + what)

    lua, ns, W, DB, _ = profit_window_setup(craft_api=True)
    lua.execute("""
      C_Timer = { After = function() end }
      QUEUE, LISTENERS = {}, {}
      local function find(spell) for i, e in ipairs(QUEUE) do if e.spell == spell then return e, i end end end
      local function changed() for _, fn in ipairs(LISTENERS) do fn() end end
      local CREATES = { [1] = 2996, [2] = 4238, [3] = 2570 }
      EverlookCraftAPI.version = 8
      EverlookCraftAPI.queue = function()
        local out = {}
        for _, e in ipairs(QUEUE) do out[#out + 1] = { spell = e.spell, n = e.n, creates = CREATES[e.spell], profit = 100 } end
        return out
      end
      EverlookCraftAPI.queueCount = function(spell) local e = find(spell); return e and e.n or 0 end
      EverlookCraftAPI.queueSet = function(spell, n)
        local e, i = find(spell)
        if n <= 0 then if i then table.remove(QUEUE, i) end
        elseif e then e.n = n else QUEUE[#QUEUE + 1] = { spell = spell, n = n } end
        changed()
        return true
      end
      EverlookCraftAPI.queueClear = function() QUEUE = {}; changed() end
      EverlookCraftAPI.queueMissing = function() return { { 2589, 12, vendor = false }, { 2320, 9, vendor = true } } end
      EverlookCraftAPI.onQueue = function(fn) LISTENERS[#LISTENERS + 1] = fn end
    """)
    G = lua.globals()
    for f_ in lua.eval("MOCK_FRAMES").values():
        h = f_.scripts and f_.scripts.OnEvent
        if h:
            h(f_, "PLAYER_LOGIN")
    check(len(G.LISTENERS) == 1, "listens to the queue once logged in")
    W.open()
    f = W.frame
    check(f.heads.crafts.label.text == "QUEUE", f"the column says QUEUE: {f.heads.crafts.label.text}")
    check(f.clear.label.text == "Clear queue", f"Clear queue: {f.clear.label.text}")
    check("shared with EverlookDB Crafting" in f.sum.text, f"empty queue line: {f.sum.text}")

    def row_of(name):
        for i in range(1, len(f.rows) + 1):
            r = f.rows[i]
            if r.shown and r.data and r.data.name == name:
                return r
    bag = row_of("Linen Bag")
    bag.scripts.OnClick(bag, "LeftButton")
    check(G.QUEUE[1] is not None and G.QUEUE[1].spell == 2 and G.QUEUE[1].n == 5, "a click queues 5 of the bag")
    check(bag.crafts.text == "5", f"the box says 5: {bag.crafts.text}")
    bag.scripts.OnClick(bag, "LeftButton")
    check(G.QUEUE[1].n == 5, "a second click doesn't add more")
    bag.crafts.SetText(bag.crafts, "8")
    bag.crafts.scripts.OnTextChanged(bag.crafts, True)
    check(G.QUEUE[1].n == 8, f"typing sets the queue: {G.QUEUE[1].n}")
    check("Crafting queue: 1 recipe, 8 crafts" in f.sum.text, f"the queue line: {f.sum.text}")
    # another addon (Crafting's window, a craft) changes the queue: the box follows
    lua.execute("EverlookCraftAPI.queueSet(2, 3)")
    check(bag.crafts.text == "3", f"the box follows the queue: {bag.crafts.text}")
    shirt = row_of("Linen Shirt")
    check(shirt.crafts.text == "", "nothing queued: an empty box")
    check(f.make.usable is not False, "the button can be used")

    W.makeList()
    lists = DB.lists
    l = lists and lists[len(lists)]
    check(l is not None and l.name == "Crafting queue", f"the list is named Crafting queue: {l.name if l else None}")
    if l is not None:
        check(l.want['name is "Linen Cloth"'] == 12 and l.want['name is "Coarse Thread"'] is None,
              f"what the whole queue misses, vendor goods left out: {[(k, l.want[k]) for k in l.want]}")
    check(W.status and "whole queue" in W.status[1] and "Coarse Thread" in W.status[1], f"says so: {W.status and W.status[1]}")

    # Clear queue: the first click asks, the second empties it
    f.clear.scripts.OnClick(f.clear)
    check(len(G.QUEUE) == 1 and f.clear.label.text == "Click again", "the first click only asks")
    f.clear.scripts.OnClick(f.clear)
    check(len(G.QUEUE) == 0, "the second click clears the queue")
    check(f.clear.label.text == "Clear queue", "back to Clear queue")
    return failures


def profit_paid_check():
    """Crafting profit with what you paid and Check prices (Profit.lua, ProfitWindow.lua): a material bought at this
    auction house in the last 3 days costs what you paid (blue, a "paid" tag, the tooltip's paid vs market), the queue
    line says so and nudges to check prices; Check prices needs the auction house open, looks at the queue's
    materials and results one by one, prices a stack material at the listings for the whole queue's amount, takes a
    recipe whose result sells far lower out of the queue (Undo puts it back) and says good / thin for the rest, with the
    mats' real cost when it differs from the table and how many of the result are listed."""
    failures = []

    def check(cond, what):
        if not cond:
            failures.append("profit paid/check: " + what)

    lua, ns, W, DB, settings = profit_window_setup(craft_api=True)
    Pr = ns.profit
    G = lua.globals()
    tbl = lua.eval("function(...) return { ... } end")
    ns.house = lua.eval("function() return MOCK_HOUSE end")
    ns.itemTipOwner = lua.eval("function() end")

    # what you paid: this house, the last 3 days, the average over the purchases
    bought = lua.eval("""{
      { t = 100000 - 86400, id = 2320, q = 20, c = 200, h = "A-Alliance" },
      { t = 100000 - 3600, id = 2320, q = 10, c = 130, h = "A-Alliance" },
      { t = 100000 - 5 * 86400, id = 2320, q = 10, c = 900, h = "A-Alliance" },
      { t = 100000 - 60, id = 2320, q = 10, c = 9000, h = "B-Horde" },
      { t = 100000 - 60, id = 2589, q = 0, c = 10, h = "A-Alliance" },
    }""")
    paid = Pr.paidPrices(bought, "A-Alliance", 100000)
    p = paid[2320]
    check(p is not None and p.q == 30 and p.c == 330 and abs(p.unit - 11) < 1e-9 and p.t == 100000 - 3600,
          f"thread: 30 for 330, 11 each, newest an hour ago: {p and (p.q, p.c, p.unit, p.t)}")
    check(paid[2589] is None, "a purchase of nothing doesn't count")
    check(Pr.paidPrices(bought, "A-Alliance", 100000, 10)[2320].q == 40, "a longer window takes the older one too")

    # verdicts and the message
    check(Pr.verdict(tbl(), lua.eval("{ low = 100, profit = 5 }")) is None, "profit, no earlier price: still good")
    check(Pr.verdict(lua.eval("{ low = 440 }"), lua.eval("{ low = 200, profit = 50 }")) == "drop", "sells 55% lower: drop")
    check(Pr.verdict(lua.eval("{ low = 440 }"), lua.eval("{ low = 400, profit = 0 }")) == "loss", "no profit: loss")
    check(Pr.verdict(lua.eval("{ low = 440 }"), lua.eval("{ profit = -5 }")) is None, "no price now: can't tell")
    items = lua.eval("""{
      { name = "Rough Copper Vest", n = 10, verdict = "drop", was = 4400, now = 2000, profit = -300 },
      { name = "Small Bronze Bomb", n = 100, made = 100, profit = 320000, margin = 0.6, costNow = 480000, costWas = 310000, listed = 12 },
      { name = "Linen Shirt", n = 5, made = 5, profit = 50, margin = 0.05, costNow = 1000, costWas = 990, listed = 40 },
    }""")
    lines, gone = Pr.checkLines(items)
    lines = [lines[i] for i in range(1, len(lines) + 1)]
    check(len(lines) == 3, f"three lines: {lines}")
    check(lines[0] == "Not worth it, taken out of the queue: Rough Copper Vest: sells for 20s now (was 44s).", f"taken out: {lines[0]}")
    check(lines[1].startswith("Good: Small Bronze Bomb, +32g profit at today's prices."), f"good: {lines[1]}")
    check("Mats for 100: 48g at today's listings (the table said 31g)." in lines[1], f"the real cost: {lines[1]}")
    check("100 vs 12 listed: selling them all may take a while or lower the price." in lines[1], f"the sell side: {lines[1]}")
    check(lines[2] == "Thin: Linen Shirt, +50c profit (5% margin) at today's prices.", f"thin, cost about the same: {lines[2]}")
    check(gone[1] == "Rough Copper Vest" and len(gone) == 1, "the names taken out")
    # listed far above its 30-day median: the asking price may not hold
    items = lua.eval("""{ { name = "Small Bronze Bomb", n = 75, made = 150, now = 1998, median = 230, profit = 200000, margin = 2.5 } }""")
    lines, _ = Pr.checkLines(items)
    check("It sells for 19s 98c now, but its 30-day median is 2s 30c: that price may not hold." in lines[1], f"far above the median: {lines[1]}")
    items = lua.eval("""{ { name = "Small Bronze Bomb", n = 75, made = 150, now = 300, median = 230, profit = 200000, margin = 2.5 } }""")
    lines, _ = Pr.checkLines(items)
    check("median" not in lines[1], f"close to the median: no warning: {lines[1]}")

    # the page: the crafting queue with 10 Linen Bags and 5 Linen Shirts, thread bought lately for 10c (market 12c)
    lua.execute("""
      C_Timer = { After = function() end }
      QUEUE = { { spell = 2, n = 10 }, { spell = 3, n = 5 } }
      local CREATES = { [1] = 2996, [2] = 4238, [3] = 2570 }
      local function find(spell) for i, e in ipairs(QUEUE) do if e.spell == spell then return e, i end end end
      EverlookCraftAPI.version = 8
      EverlookCraftAPI.queue = function()
        local out = {}
        for _, e in ipairs(QUEUE) do out[#out + 1] = { spell = e.spell, n = e.n, creates = CREATES[e.spell] } end
        return out
      end
      EverlookCraftAPI.queueCount = function(spell) local e = find(spell); return e and e.n or 0 end
      EverlookCraftAPI.queueSet = function(spell, n)
        local e, i = find(spell)
        if n <= 0 then if i then table.remove(QUEUE, i) end
        elseif e then e.n = n else QUEUE[#QUEUE + 1] = { spell = spell, n = n } end
        return true
      end
      EverlookCraftAPI.queueMissing = function() return {} end
      MOCK_DB.bought = { { t = MOCK_TIME - 7200, id = 2320, q = 40, c = 400, h = MOCK_HOUSE } }
    """)
    W.open()
    f = W.frame
    bag = None
    for i in range(1, len(W.rows) + 1):
        if W.rows[i].id == 4238:
            bag = W.rows[i]
    check(bag is not None and bag.paid is True, "the bag's cost uses what you paid")
    if bag is not None:
        check(bag.cost == 3 * 36 + 3 * 10, f"3 bolts (crafted, 36c) and 3 thread at 10c paid: {bag.cost}")
        th = [bag.mats[i] for i in range(1, len(bag.mats) + 1) if bag.mats[i].id == 2320][0]
        check(th.paid.unit == 10 and th.market == 12, f"thread: paid 10c, market 12c: {th.paid.unit}, {th.market}")
    shown = [f.rows[i] for i in range(1, len(f.rows) + 1) if f.rows[i].shown and f.rows[i].data]
    bag_row = [r for r in shown if r.data.id == 4238]
    check(bag_row and "paid" in bag_row[0].tag.text, f"the row's tag says paid: {bag_row and bag_row[0].tag.text}")
    check("at what you paid" in f.sum.text and "Cost " in f.sum.text, f"the queue line: {f.sum.text}")
    check("Check prices before you buy." in f.sum.text, f"the nudge: {f.sum.text}")
    check("estimates from" in f.sub.text and "Check prices before you buy." in f.sub.text, f"the subtitle: {f.sub.text}")
    check(f.check.label.text == "Check prices" and f.make.label.text == "Make shopping list", "both buttons")
    check(f.make.usable is not False, "Make shopping list isn't blocked before a check")
    check("Blue cost" in f.note.text, f"the note explains blue: {f.note.text}")
    # the tooltip: paid vs market
    lines_ = []
    G.GameTooltip.AddDoubleLine = lambda self, l, r, *a: lines_.append(str(l) + " | " + str(r))
    G.GameTooltip.AddLine = lambda self, t, *a: lines_.append(str(t))
    if bag_row:
        bag_row[0].scripts.OnEnter(bag_row[0])
    tip = chr(10).join(lines_)
    check("paid 10c each" in tip and "market 12c each" in tip and "craft it, 36c each" in tip, f"tooltip: {tip}")

    # Check prices with the auction house closed: said plainly
    W.checkPrices()
    check(W.status and "auction house open" in W.status[1], f"closed: {W.status and W.status[1]}")

    # the auction house open, a fake search queue answering at once
    src = source_of("BuyList.lua")
    a = src.index("function W.plan(")
    b = src.index(chr(10) + "end" + chr(10), a) + 4
    lua.execute("local W = {}; " + src[a:b] + chr(10) + "PLAN = W.plan")
    ns.buyList = lua.eval("{ plan = PLAN }")
    lua.execute("""
      AuctionHouseFrame = { IsShown = function() return true end }
      MOCK_DB.bought = {}
      LISTED = { [2996] = { { 95, 5 }, { 200, 100 } }, [2320] = { { 12, 5 }, { 40, 100 } },
        [4238] = { { 300, 30 } }, [2570] = { { 140, 2 } } }
      COMMODITY = { [2996] = true, [2320] = true }
      SEARCHED = {}
      C_AuctionHouse = {
        GetItemKeyInfo = function(key) return { isCommodity = COMMODITY[key.itemID] or false } end,
        GetNumCommoditySearchResults = function(id) return #(LISTED[id] or {}) end,
        GetCommoditySearchResultInfo = function(id, i) local l = LISTED[id][i]; return { unitPrice = l[1], quantity = l[2], numOwnerItems = 0 } end,
      }
    """)
    ns.ahq = lua.eval("""{
      browse = function(name, id, opts, cb)
        SEARCHED[#SEARCHED + 1] = id
        local entries = {}
        local low, qty
        for _, l in ipairs(LISTED[id] or {}) do
          if not low or l[1] < low then low = l[1] end
          qty = (qty or 0) + l[2]
        end
        if low then entries[1] = { itemKey = { itemID = id }, minPrice = low, totalQuantity = qty } end
        cb({ ok = true, full = true, entries = entries })
      end,
      items = function(key, opts, cb) cb(key, true, true) end,
      cancel = function() end,
    }""")
    ns.noteLivePrice = lua.eval("""function(id, rows)
      local low, qty
      for _, r in ipairs(rows) do if r.unit and (not low or r.unit < low) then low = r.unit end; qty = (qty or 0) + (r.qty or 0) end
      MOCK_DB.houses[MOCK_HOUSE].items[id] = { low, qty, nil, MOCK_TIME }
    end""")
    W.render()
    W.checkPrices()
    searched = sorted(G.SEARCHED[i] for i in range(1, len(G.SEARCHED) + 1))
    check(searched == [2320, 2570, 2996, 4238], f"the queue's materials and results, once each: {searched}")
    check(W.check is None, "the check is done")
    lv = W.live[2320]
    check(lv is not None and lv.avg == 36 and lv.low == 12, f"thread for 35: 5 at 12c and 30 at 40c, 36c each: {lv and (lv.avg, lv.low)}")
    queue = [(G.QUEUE[i].spell, G.QUEUE[i].n) for i in range(1, len(G.QUEUE) + 1)]
    check(queue == [(3, 5)], f"the bag (sells for 3s now, was 5s 20c) is taken out: {queue}")
    st = W.status and W.status[1] or ""
    check("Checked 4 items at the auction house just now." in st, f"the message: {st}")
    check("Linen Bag: sells for 3s now (was 5s 20c)" in st, f"names the bag and why: {st}")
    check("Good: Linen Shirt" in st and "Mats for 5: 3s 60c at today's listings (the table said 2s 40c)." in st, f"the shirt: {st}")
    check("5 vs 2 listed" in st, f"the sell side: {st}")
    check(f.undo.shown, "Undo shows")
    check(DB.houses[G.MOCK_HOUSE]["items"][4238][1] == 300, "the bag's fresh price replaces the scan's")
    check("Check prices before you buy." not in f.sum.text, f"checked: no nudge: {f.sum.text}")
    W.undoCheck()
    queue = sorted((G.QUEUE[i].spell, G.QUEUE[i].n) for i in range(1, len(G.QUEUE) + 1))
    check(queue == [(2, 10), (3, 5)], f"Undo puts the bag back: {queue}")
    check(not f.undo.shown, "Undo is gone after use")

    # a block in the middle stops the check, the queue as it was
    ns.ahq.browse = lua.eval("function() end")
    W.checkPrices()
    check(W.check is not None and "Checking" in f.check.label.text, f"checking: {f.check.label.text}")
    fire = lua.eval("function(h, f, e, a) return pcall(h, f, e, a) end")
    for f_ in lua.eval("MOCK_FRAMES").values():
        h = f_.scripts and f_.scripts.OnEvent
        if h:
            fire(h, f_, "ADDON_ACTION_BLOCKED", "EverlookDBAuctions")
    check(W.check is None and W.status and "blocked" in W.status[1], f"a block stops it: {W.status and W.status[1]}")
    check(len(G.QUEUE) == 2, "the queue is as it was")
    return failures


def profit_scopes():
    """Crafting profit's scopes (Profit.lua, ProfitWindow.lua): the recipes you know, the ones easy to get (a trainer,
    vendor or the AH, near your skill) and every recipe, from EverlookDB Crafting's api.allRecipes (v7): how to
    start and what it costs, the skill it needs against yours, after how many crafts it pays back, the "on the AH
    now" filter, margin first, "source unknown" kept, and the recipe on the shopping list."""
    failures = []

    def check(cond, what):
        if not cond:
            failures.append("profit scopes: " + what)

    lua, ns, W, DB, _ = profit_window_setup(craft_api=True)
    Pr = ns.profit
    check(Pr.payback(300, 100) == 3 and Pr.payback(301, 100) == 4 and Pr.payback(0, 100) is None and Pr.payback(300, -5) is None,
          "pays back after cost / profit crafts, rounded up")
    check(Pr.paybackText(lua.eval("{ cost = 400 }"), 120) == "Learning 4s, profit 1s 20c per craft: pays back after 4 crafts.",
          f"the payback line: {Pr.paybackText(lua.eval('{ cost = 400 }'), 120)}")

    W.open()
    f = W.frame
    W.setScope("easy")
    check("EverlookDB Crafting" in f.empty.text and f.empty.shown, f"without Crafting v7: says what it needs: {f.empty.text}")

    lua.execute("""
      MOCK_ITEMS[2580], MOCK_ITEMS[2598], MOCK_ITEMS[9999], MOCK_ITEMS[11082] = "Reinforced Linen Cape", "Pattern: Reinforced Linen Cape", "Fancy Robe", "Greater Magic Wand"
      local items = MOCK_DB.houses[MOCK_HOUSE].items
      items[2580] = { 900, 1, 1, 99000 }; items[2598] = { 300, 1, 1, 99000 }; items[9999] = { 5000, 1, 1, 99000 }
      items[11082] = { 3000, 1, 1, 99000 }
      EverlookCraftAPI.version = 7
      EverlookCraftAPI.allRecipes = function() return {
        { spell = 3755, name = "Linen Bag", skill = 197, prof = "Tailoring", learn = 45, creates = 4238, yield = 1, mats = { { 2996, 3 }, { 2320, 3 } }, tier = 0, why = "", trained = true },
        { spell = 3843, name = "Heavy Linen Gloves", skill = 197, prof = "Tailoring", learn = 85, creates = 4307, yield = 1, mats = { { 2996, 2 } }, fee = 500, tier = 0, why = "", trained = true },
        { spell = 3862, name = "Reinforced Linen Cape", skill = 197, prof = "Tailoring", learn = 60, creates = 2580, yield = 1, mats = { { 2996, 2 }, { 2320, 3 } }, item = 2598, tier = 3, why = "drop" },
        { spell = 9001, name = "Fancy Robe", skill = 197, prof = "Tailoring", learn = 250, creates = 9999, yield = 1, mats = { { 2996, 4 } }, tier = 3, why = "" },
        { spell = 14807, name = "Greater Magic Wand", skill = 333, prof = "Enchanting", learn = 70, creates = 11082, yield = 1, mats = { { 2589, 1 } }, tier = 0, why = "", trained = true },
      } end
    """)
    W.forgetAll()
    W.setScope("easy")

    def shown():
        return [f.rows[i].data for i in range(1, len(f.rows) + 1) if f.rows[i].shown]

    rows = shown()
    names = [r.name for r in rows]
    check(sorted(names) == ["Heavy Linen Gloves", "Reinforced Linen Cape"],
          f"easy to get: a trainer and an AH recipe near your Tailoring 75, not what you know, not too high: {names}")
    check(W.sortState() == ("margin", True), f"easy to get: margin first: {W.sortState()}")
    by = {r.name: r for r in rows}
    cape, gloves = by.get("Reinforced Linen Cape"), by.get("Heavy Linen Gloves")
    check(cape is not None and gloves is not None, "the cape and the gloves are rows")
    if cape and gloves:
        check(cape.start.how == "ah" and cape.start.cost == 300 and Pr.startText(cape.start) == "AH 3s",
              f"the cape: its pattern on the AH: {cape.start.how} {cape.start.cost}")
        check(gloves.start.how == "trainer" and Pr.startText(gloves.start) == "trainer 5s", f"the gloves: a trainer: {Pr.startText(gloves.start)}")
        check(gloves.skill == 85 and Pr.skillText(gloves.start) == "Needs 85 Tailoring, you're 75.",
              f"the skill it needs against yours: {Pr.skillText(gloves.start)}")
        check(cape.payback == Pr.payback(300, cape.profit), f"the cape's payback: {cape.payback}")
        rowtag = [f.rows[i].tag.text for i in range(1, len(f.rows) + 1) if f.rows[i].shown]
        check(any("AH 3s" in t for t in rowtag), f"the row says how to start: {rowtag}")
        # on the AH now
        f.onAH.scripts.OnClick(f.onAH)
        check([r.name for r in shown()] == ["Reinforced Linen Cape"], f"only recipes on the AH now: {[r.name for r in shown()]}")
        f.onAH.scripts.OnClick(f.onAH)
        # Recipe under: the cheapest way to learn costs at most this (kept per character)
        check(f.recipeMax.shown and not f.alts.shown, "Recipe under shows for recipes you don't know, in place of Alts")
        f.recipeMax.SetText(f.recipeMax, "4s")
        f.recipeMax.scripts.OnTextChanged(f.recipeMax, True)
        check(lua.eval("EverlookAuctionsCharDB.profit.recipeMax") == 400, "kept for this character, in copper")
        check([r.name for r in shown()] == ["Reinforced Linen Cape"], f"recipe under 4s: the 5s trainer recipe goes: {[r.name for r in shown()]}")
        f.recipeMax.SetText(f.recipeMax, "2g50s")
        f.recipeMax.scripts.OnTextChanged(f.recipeMax, True)
        check(lua.eval("EverlookAuctionsCharDB.profit.recipeMax") == 25000 and len(shown()) == 2, "2g50s: both again")
        f.recipeMax.SetText(f.recipeMax, "")
        f.recipeMax.scripts.OnTextChanged(f.recipeMax, True)
        check(lua.eval("EverlookAuctionsCharDB.profit.recipeMax") is None, "empty: any price")
        # the plan's shopping list has the pattern too
        W.crafts[2580] = 1
        W.render()
        W.makeList()
        l = DB.lists and DB.lists[len(DB.lists)]
        check(l is not None and l.want['name is "Pattern: Reinforced Linen Cape"'] == 1,
              f"the pattern on the shopping list: {[(k, l.want[k]) for k in l.want] if l else None}")
        W.crafts[2580] = None

    W.setScope("all")
    names = [r.name for r in shown()]
    check("Fancy Robe" in names and "Greater Magic Wand" in names and "Linen Bag" not in names,
          f"all recipes: every profession, too high ones too, not what you know: {names}")
    robe = [r for r in shown() if r.name == "Fancy Robe"]
    if robe:
        check(Pr.startText(robe[0].start) == "source unknown", f"a recipe without a known source says so: {Pr.startText(robe[0].start)}")
    wand = [r for r in shown() if r.name == "Greater Magic Wand"]
    check(len(robe) == 1 and len(wand) == 1, "the robe and the wand are rows")
    if wand:
        check(Pr.skillText(wand[0].start) == "You don't have Enchanting; it needs 70.", f"another profession: {Pr.skillText(wand[0].start)}")
    check(f.scopes[3].line.shown and not f.scopes[1].line.shown, "the scope shown is marked")
    W.setScope("known")
    check(sorted(r.name for r in shown()) == ["Bolt of Linen Cloth", "Linen Bag", "Linen Shirt"] and W.sortState()[0] == "profit",
          "back to the recipes you know, best profit first")
    check(f.canMake.shown and not f.onAH.shown, "the recipes you know: Only what I can make now")
    return failures


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
    # school damage: from the item's own Equip line, and from a stat key we don't name (Mordresh's Lifeless Skull)
    lua.execute("""
      SAVED_TIP = C_TooltipInfo
      C_TooltipInfo = { GetHyperlink = function(link)
        if link == "item:777" then return { lines = { { leftText = "Mordresh's Lifeless Skull" },
          { leftText = "Equip: Increases damage done by Shadow spells and effects by up to 16." } } } end
      end }
      SAVED_GIS2 = C_Item.GetItemStats
      C_Item.GetItemStats = function(link)
        if link == "item:778" then return { ITEM_MOD_SHADOW_DAMAGE_SHORT = 16, ITEM_MOD_SPIRIT_SHORT = 5 } end
        return SAVED_GIS2(link)
      end
    """)
    skull = U.stats("item:777", 777)
    check(skull.sp_shadow == 16, f"Shadow damage from the Equip line: {skull.sp_shadow}")
    skull2 = U.stats("item:778", 778)
    check(skull2.sp_shadow == 16 and skull2.spi == 5, "Shadow damage from an unnamed stat key")
    lua.execute("C_TooltipInfo = SAVED_TIP; C_Item.GetItemStats = SAVED_GIS2")
    check(U.slotText(T({"slotPct": 12803, "delta": 4, "group": "offhand"})) is None, "no absurd % over a worn item that barely scores")
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
    check(meta.src == "estimate" and "healing per mana" in (meta.why or ""), f"Holy paladin: an estimate: {meta.why}")
    gear(311, "INVTYPE_HEAD", 4, 4, T({"ITEM_MOD_INTELLECT_SHORT": 3}), "Old Helm")
    gear(312, "INVTYPE_HEAD", 4, 4, T({"ITEM_MOD_INTELLECT_SHORT": 12, "ITEM_MOD_SPIRIT_SHORT": 8}), "Helm of Light")
    worn(T({1: 311}))
    lines = X.tipLines("item:312", 312)
    check(lines and lines[1].left == "Upgrade for Holy" and (lines[1].why or "").endswith("(estimate)"),
          f"healer tooltip says estimate: {lines and lines[1].why}")
    check("An estimate: worked out from healing per mana" in O.weightsText(holy), "the weights text says why it's an estimate")

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


def upgrades_alts():
    """Gear upgrades for an alt (UpgradesChars.lua, UpgradesTab.lua): every character of the account is saved at login
    (class, level, the links of its gear, talents) with the values the game hides skipped; the character dropdown
    lists you first and your alts of this realm and faction, with a hint for alts not seen yet; a level-34 priest alt
    viewed from a level-60 warrior gets cloth upgrades (never plate) against its own saved gear, its own specs as
    buttons, its spec remembered, "Gear as of" in the status line and its name in the shopping list; and an alt can
    be forgotten (never you)."""
    failures = []

    def check(cond, what):
        if not cond:
            failures.append("upgrades alts: " + what)

    lua = lua51.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(source_of("tests/mock.lua"))
    lua.execute(UPGRADES_SETUP)
    lua.execute(r"""
      SECRET = {}
      function issecretvalue(v) return SECRET[v] == true end
      MOCK_NAME, MOCK_RACE, MOCK_FACTION, MOCK_INV = "Prayer", "Human", "Alliance", {}
      function UnitName() return MOCK_NAME end
      function UnitRace() return MOCK_RACE, MOCK_RACE end
      function UnitFactionGroup() return MOCK_FACTION end
      function UnitClass() return MOCK_CLASS, MOCK_CLASS, MOCK_CLASS == "PRIEST" and 5 or 1 end
      function GetInventoryItemLink(_, slot) return MOCK_INV[slot] end
      RAID_CLASS_COLORS = { PRIEST = { r = 1, g = 1, b = 1 }, WARRIOR = { r = 0.78, g = 0.61, b = 0.43 } }
      UPDATA.classes.PRIEST = { specs = {
        { key = "discipline", name = "Discipline", role = "healer", brackets = { { upTo = 60, w = { int = 1, spi = 1, heal = 0.5, sta = 0.2 } } } },
        { key = "holy", name = "Holy", role = "healer", brackets = { { upTo = 60, w = { int = 1, heal = 1 } } } },
        { key = "shadow", name = "Shadow", role = "caster", brackets = { { upTo = 60, w = { int = 0.5, sp = 1, sp_shadow = 1 } } } },
        { key = "priest_disc_leveling", name = "Discipline (levelling 1-40, then Shadow)", role = "caster", build = true,
          brackets = { { upTo = 60, w = { int = 1 } } } },
      } }
    """)
    run = lua.eval("function(src, name, ...) local f = assert(loadstring(src, name)); return f(...) end")
    ns = lua.table()
    run(UPGRADES_NS, "ns", ns)
    ns.realmInfo = lua.eval("function() return 'Test', 1234 end")
    ns.ago = lua.eval("function() return '2 h ago' end")
    run(source_of("Skin.lua"), "Skin.lua", "EverlookDBAuctions", ns)
    for name in ("Upgrades.lua", "UpgradesChars.lua", "UpgradesTab.lua", "UpgradesExtras.lua"):
        run(source_of(name), name, "EverlookDBAuctions", ns)
    lua.eval("""function(UI) UI.list = function(parent)
      local L = CreateFrame("Frame", nil, parent)
      L.empty = CreateFrame("FontString")
      L.SetItems = function(self, items) self.items = items end
      return L
    end end""")(ns.UI)
    G = lua.globals()
    U, V, C = ns.up, ns.upgradesView, ns.upChars
    T = lua.table_from
    gear = lua.eval("""function(id, loc, cls, sub, stats, name, req)
      MOCK_GEAR[id] = { loc, cls, sub, stats, name or ("Item " .. id), 2, req or 30 }
    end""")
    gear(201, "INVTYPE_HEAD", 4, 1, T({"ITEM_MOD_INTELLECT_SHORT": 5, "ITEM_MOD_SPIRIT_SHORT": 4}), "Worn Hood")
    gear(202, "INVTYPE_ROBE", 4, 1, T({"ITEM_MOD_INTELLECT_SHORT": 6, "ITEM_MOD_STAMINA_SHORT": 4}), "Worn Robe")
    gear(211, "INVTYPE_HEAD", 4, 1, T({"ITEM_MOD_INTELLECT_SHORT": 12, "ITEM_MOD_SPIRIT_SHORT": 10}), "Silk Hood")
    gear(212, "INVTYPE_ROBE", 4, 1, T({"ITEM_MOD_INTELLECT_SHORT": 3}), "Thin Robe")            # worse than worn
    gear(213, "INVTYPE_HEAD", 4, 4, T({"ITEM_MOD_STRENGTH_SHORT": 20}), "Plate Helm")
    gear(214, "INVTYPE_HAND", 4, 1, T({"ITEM_MOD_INTELLECT_SHORT": 30}), "Gloves of Later", 40)
    gear(215, "INVTYPE_2HWEAPON", 2, 1, T({"ITEM_MOD_STRENGTH_SHORT": 15, "ITEM_MOD_DAMAGE_PER_SECOND_SHORT": 20}), "Great Axe")

    # --- recording: the priest alt logs in (level 34), one slot hidden by the game
    G.MOCK_CLASS, G.MOCK_LEVEL = "PRIEST", 34
    G.EverlookAuctionsCharDB = lua.eval("{ up = { specs = { discipline = true }, shown = 'discipline', asked = true, profile = {} } }")
    lua.execute('MOCK_INV = { [1] = "item:201", [5] = "item:202", [6] = "SECRET_BELT" }; SECRET.SECRET_BELT = true')
    lua.execute("ns_tal = { ['1:1:1'] = 3, ['name:Meditation'] = 2, ['1:2:1'] = 0 }")
    U.readTalents = lua.eval("function() return ns_tal end")
    rec = C.record()
    key = "Prayer-1234"
    check(rec is not None and C.meKey() == key, f"the key is name and realm ID: {C.meKey()}")
    check(rec["class"] == "PRIEST" and rec.classID == 5 and rec.level == 34 and rec.race == "Human" and rec.faction == "Alliance",
          "class, level, race and faction saved")
    check(rec["items"][1] == "item:201" and rec["items"][5] == "item:202" and rec["items"][6] is None,
          "the gear's links saved; the hidden one skipped")
    check(rec.talents["name:Meditation"] == 2 and rec.talents["1:2:1"] is None, "talents: only the ranks taken")
    check(rec.shown == "discipline", "this character's spec on the page is saved with it")
    rec["items"][6] = "item:999"
    C.record()
    check(rec["items"][6] == "item:999", "a slot the game hides keeps what was saved")
    lua.execute('MOCK_INV[6] = nil')
    C.record()
    check(rec["items"][6] is None, "an empty slot is empty")
    G.MOCK_NAME = "SECRET_NAME"
    G.SECRET.SECRET_NAME = True
    before = len(list(C.all().keys()))
    check(C.record() is None and len(list(C.all().keys())) == before, "no record while the game hides the name")
    G.MOCK_NAME = "Prayer"
    C.record(35)
    check(rec.level == 35, "PLAYER_LEVEL_UP's new level")
    C.record(34)
    check(G.DB.up.chars[key].level == 34 and G.DB.up.chars[key].name == "Prayer", "saved per account (db.up.chars)")

    # an alt on another realm and one of the other faction: never listed
    lua.execute("""
      DB.up.chars["Far-999"] = { name = "Far", realmID = 999, class = "MAGE", level = 60, faction = "Alliance", items = {} }
      DB.up.chars["Red-1234"] = { name = "Red", realmID = 1234, class = "ROGUE", level = 50, faction = "Horde", items = {} }
    """)

    # --- now playing the warrior (level 60), nothing worn
    G.MOCK_CLASS, G.MOCK_LEVEL, G.MOCK_NAME = "WARRIOR", 60, "Grom"
    G.MOCK_INV = lua.table()
    G.EverlookAuctionsCharDB = lua.eval("{ up = { specs = { fury = true }, shown = 'fury', asked = true, profile = {} } }")
    U.readTalents = lua.eval("function() return {} end")
    C.record()
    U.changed()
    names = [c.name for c in C.list().values()]
    check(names == ["Grom", "Prayer"], f"you first, then alts of this realm and faction: {names}")
    items = V.charItems()
    texts = [items[i].text for i in range(1, len(items) + 1)]
    check("Grom" in texts[0] and "(you)" in texts[0] and "60" in texts[0] and items[1].value == "", f"you, with level and (you): {texts[0]}")
    check("Prayer" in texts[1] and "34" in texts[1] and "(you)" not in texts[1] and items[2].value == key, f"the alt: {texts[1]}")
    check(texts[1].startswith("|cffffffff"), f"class-coloured: {texts[1]}")
    check(items[3].title and "Log in once on an alt to add it" in texts[2], "the hint for alts not seen yet")
    check("Forget a character" in texts[3], "forget is in the list")

    # --- the scan
    lua.execute("""DB.scans = { { realm = "Test", side = "Alliance", at = 1699990000, rows = {
      ["211:0"] = "5000,5000,5000,1,1,,,,,,,",
      ["212:0"] = "100,100,100,1,1,,,,,,,",
      ["213:0"] = "900,900,900,1,1,,,,,,,",
      ["214:0"] = "700,700,700,1,1,,,,,,,",
      ["215:0"] = "3000,3000,3000,1,1,,,,,,,",
    } } }""")
    V.openWindow()
    F = G.EverlookAuctionsUpgrades
    r = U.result
    check(V.kind == "ready" and r.whoKey is None and r.spec.key == "fury", f"you by default: {V.kind}")
    check(r.slots.head.best and r.slots.head.best.id == 213, "the warrior's plate helm")
    check(r.slots.mainhand.best and r.slots.mainhand.best.id == 215, "and the axe")
    check("Gear as of" not in F.head.text, "no gear age for you")
    shown_specs = [F.specs[i].spec.key for i in range(1, len(F.specs) + 1) if F.specs[i].shown]
    check(shown_specs == ["fury", "protection"], f"your class's specs as buttons: {shown_specs}")

    # --- the priest alt
    V.pickChar(key)
    r = U.result
    check(V.who == key and r.whoKey == key and r.whoName == "Prayer" and V.kind == "ready", f"the alt's upgrades: {r.whoKey}")
    check(r.spec.key == "discipline", f"its saved spec: {r.spec.key}")
    check(r.slots.head.best and r.slots.head.best.id == 211, "a cloth hood for the priest")
    heads = [r.slots.head.list[i].id for i in range(1, len(r.slots.head.list) + 1)]
    check(213 not in heads, f"never the plate helm: {heads}")
    check(r.slots.mainhand.best is None, "never the warrior's axe")
    check(r.slots.chest.best is None, "the robe worse than its saved robe isn't an upgrade (its own gear is the baseline)")
    check(r.slots.head.best.cmp.vs and r.slots.head.best.cmp.vs.id == 201, "measured against the hood it wears")
    check(r.slots.hands.best is None and r.slots.hands.nextLevel == 40, "level 34: gloves of level 40 are the next upgrade")
    shown_specs = [F.specs[i].spec.key for i in range(1, len(F.specs) + 1) if F.specs[i].shown]
    check(shown_specs == ["discipline", "holy", "shadow"], f"the alt's class's specs as buttons: {shown_specs}")
    check("Prayer" in F.charText.text and "34" in F.charText.text, f"the dropdown shows the alt: {F.charText.text}")
    check(F.head.text.startswith("Gear as of 2 h ago"), f"the gear's age in the status line: {F.head.text}")
    check(U.ctx is None and U["class"]() == "WARRIOR" and U.level() == 60, "outside the page you're still yourself")
    tl = ns.upExtras.tipLines("item:213", 213)
    check(tl and "Upgrade for Fury" in (tl[1].left or ""), "tooltips stay yours")

    # spec memory, per character
    V.showSpec("shadow")
    check(rec.shown == "shadow" and U.result.spec.key == "shadow", "picking Shadow for the alt")
    check(G.EverlookAuctionsCharDB.up.shown == "fury", "your own spec untouched")
    V.pickChar("")
    check(U.result.whoKey is None and U.result.spec.key == "fury", "back to you: Fury")
    V.pickChar(key)
    check(U.result.spec.key == "shadow", "the alt's spec remembered")

    # "Other...": the levelling build of the alt's class
    oi, cur, _p = V.otherItems()
    vals = [oi[i].value for i in range(1, len(oi) + 1)]
    check("s:priest_disc_leveling" in vals and cur == "s:shadow", f"Other: the alt's levelling build: {vals}")
    check("edit" not in vals, "weights of your own are made on a character of that class")

    # the shopping list has the alt's name
    V.showSpec("discipline")
    G.DB.lists = lua.table()
    ns.recipeList = lua.eval("""{ save = function(lists, name, rows) local l = { name = name, rows = rows }; lists[#lists + 1] = l; return l, true end }""")
    V.makeList()
    check(len(G.DB.lists) == 1 and G.DB.lists[1].name == "Gear upgrades: Prayer, Discipline", f"the list: {G.DB.lists[1].name if len(G.DB.lists) else None}")

    # forget: never you; the alt goes, the page goes back to you
    check(C.forget(C.meKey()) is False, "you can't be forgotten")
    fi = V.forgetItems()
    check(any(fi[i].value == key for i in range(1, len(fi) + 1)) and not any(fi[i].value == "Grom-1234" for i in range(1, len(fi) + 1)),
          "the forget list has only alts")
    check(V.forgetChar(key) is True and G.DB.up.chars[key] is None and V.who is None, "forgotten")
    check(U.result.whoKey is None and [c.name for c in C.list().values()] == ["Grom"], "the page is back to you")
    items = V.charItems()
    check(not any("Forget" in (items[i].text or "") for i in range(1, len(items) + 1)), "no forget without alts")
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
    # Blizzard's own auction list: a row inside the auction house window gets the tooltip next to the mouse and the
    # comparison only with Shift; a tooltip elsewhere keeps the game's anchor and comparison
    G.DB.compareShift = None
    lua.execute("""
        function GameTooltip:SetAnchorType(a, x, y) self.anchor = { a, x, y } end
        AuctionHouseFrame = CreateFrame("Frame")
        AH_LIST = CreateFrame("Frame", nil, AuctionHouseFrame)
        AH_ROW = CreateFrame("Button", nil, AH_LIST)
    """)
    ns.itemTip.hookBlizzard()
    gt.SetOwner(gt, G.AH_ROW, "ANCHOR_RIGHT")
    check(gt.anchor[1] == "ANCHOR_CURSOR_RIGHT", f"Blizzard's auction row: next to the mouse: {gt.anchor[1]}")
    check(gt.suppressAutomaticCompareItem is True, "Blizzard's auction row: comparison only with Shift")
    gt.Hide(gt)
    check(gt.suppressAutomaticCompareItem == "game", "Blizzard's auction row: put back on hide")
    elsewhere = lua.eval('CreateFrame("Button")')
    gt.SetOwner(gt, elsewhere, "ANCHOR_RIGHT")
    check(gt.anchor[1] == "ANCHOR_RIGHT" and gt.suppressAutomaticCompareItem == "game", "outside the auction house: the game's way")
    gt.Hide(gt)
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


def ledger():
    """The income ledger (MailClassify.lua, Ledger.lua, LedgerWatch.lua): every auction's lifecycle from its post to
    one outcome, the mail tied to it, money sorted into income / not income / costs, nothing counted twice, the old AH
    log migrated, and the API door for EverlookDB Mail."""
    failures = []

    def check(cond, what):
        if not cond:
            failures.append("ledger: " + what)

    lua = lua51.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(source_of("tests/mock.lua"))
    lua.execute("""
      MOCK_TIME = 100000; function time(t) if t then return os.time(t) end return MOCK_TIME end
      date = os.date
      GetTime = function() return MOCK_TIME end
      MOCK_MONEY = 100000; GetMoney = function() return MOCK_MONEY end
      UnitGUID = function() return 'Player-1-0000AAAA' end
      UnitName = function() return 'Mainchar' end
      AUCTION_SOLD_MAIL_SUBJECT = 'Auction successful: %s'
      AUCTION_EXPIRED_MAIL_SUBJECT = 'Auction expired: %s'
      AUCTION_REMOVED_MAIL_SUBJECT = 'Auction canceled: %s'
      AUCTION_WON_MAIL_SUBJECT = 'Auction won: %s'
      AUCTION_OUTBID_MAIL_SUBJECT = 'Outbid on %s'
      AUCTION_INVOICE_MAIL_SUBJECT = 'Sale Pending: %s'
      MOCK_ITEMS[4306] = 'Silk Cloth'
      C_Item.GetItemInfoInstant = function(name) for id, n in pairs(MOCK_ITEMS) do if n == name then return id end end end
      C_Item.GetItemID = function(loc) return loc.id end
      C_Item.GetItemLink = function(loc) return '|cffffffff|Hitem:' .. loc.id .. '::::::::|h[' .. MOCK_ITEMS[loc.id] .. ']|h|r' end
      C_Item.GetItemName = function(loc) return MOCK_ITEMS[loc.id] end
      C_AuctionHouse = {
        PostItem = function() return false end, ConfirmPostItem = function() end,
        PostCommodity = function() return false end, ConfirmPostCommodity = function() end,
        CancelAuction = function() end,
        CalculateItemDeposit = function(loc, dur, qty) return 60 * qty end,
        CalculateCommodityDeposit = function(id, dur, qty) return 3 * qty end,
      }
      -- the mailbox: { sender, subject, money, cod, items = { { name, id, count } }, invoice = { ... }, canReply, days }
      MOCK_MAIL = {}
      function GetInboxNumItems() return #MOCK_MAIL, #MOCK_MAIL end
      function GetInboxHeaderInfo(i) local m = MOCK_MAIL[i]; if not m then return nil end
        return nil, nil, m.sender, m.subject, m.money or 0, m.cod or 0, m.days or 29, m.items and #m.items or 0, false,
          false, false, m.canReply or false, false end
      function GetInboxItem(i, a) local m = MOCK_MAIL[i]; local it = m and m.items and m.items[a]
        if it then return it[1], it[2], 134400, it[3] or 1, 1, true, false end end
      function GetInboxItemLink() return nil end
      function GetInboxInvoiceInfo(i) local v = MOCK_MAIL[i] and MOCK_MAIL[i].invoice
        if v then return v[1], v[2], v[3], v[4], v[5] or 0, v[6] or 0, v[7] or 0, 0, 0, 0, v[8] end end
    """)
    ns = lua.table()
    DB = lua.table()
    G = lua.globals()
    G.MOCK_DB = DB
    ns.db = lua.eval("function() return MOCK_DB end")
    ns.money = lua.eval("function(c) return tostring(c) .. 'c' end")
    ns.num = lua.eval("function(n) return tostring(n) end")
    ns.house = lua.eval("function() return 'Realm-Alliance' end")
    run = lua.eval("function(src, name, ...) local f = assert(loadstring(src, name)); return f(...) end")
    for name in ["Libs/LibStub/LibStub.lua", "MailClassify.lua", "Ledger.lua", "LedgerWatch.lua", "API.lua"]:
        run(source_of(name), name, "EverlookDBAuctions", ns)
    fire = lua.eval("function(e, a, b, c) for _, f in ipairs(MOCK_FRAMES) do if f.scripts.OnEvent then f.scripts.OnEvent(f, e, a, b, c) end end end")
    L = ns.ledger
    W = L.watch
    C = G.LibStub("EverlookMailClassify-1")[0]
    mail = lua.eval("function(t) MOCK_MAIL = t end")

    # --- the classifier -------------------------------------------------------------------------------------------
    k, name, n, _ = C.parseSubject("Auction expired: Silk Cloth (20)")
    check(k == "ah_expired" and name == "Silk Cloth" and n == 20, f"expired subject with a count: {k} {name} {n}")
    k, name, n, _ = C.parseSubject("Auction canceled: Copper Bar")
    check(k == "ah_cancelled" and name == "Copper Bar" and n is None, f"the game says canceled: {k}")
    k, name, n, pend = C.parseSubject("Sale Pending: Copper Bar")
    check(k == "ah_sold" and pend is True, "sale pending")
    check(C.parseSubject("Hello there") is None, "a letter isn't an auction mail")
    # the English fallback when the global is missing
    G.AUCTION_OUTBID_MAIL_SUBJECT = None
    check(C.parseSubject("Outbid on Copper Bar")[0] == "ah_outbid", "the fallback string")
    G.AUCTION_OUTBID_MAIL_SUBJECT = "Outbid on %s"
    isAlt = lua.eval("function(n) return n == 'Bankalt' end")
    cases = [
        ("{ subject = 'x', cod = 500, sender = 'Trader', canReply = true }", "cod"),
        ("{ subject = 'Auction successful: Copper Bar', invoice = { type = 'seller', item = 'Copper Bar', bid = 100 } }", "ah_sold"),
        ("{ subject = 'Auction won: Copper Bar', invoice = { type = 'buyer', item = 'Copper Bar', bid = 100 } }", "ah_won"),
        ("{ subject = 'Outbid on Copper Bar', money = 90 }", "ah_outbid"),
        ("{ subject = 'Auction expired: Copper Bar' }", "ah_expired"),
        ("{ subject = 'Auction canceled: Copper Bar' }", "ah_cancelled"),
        ("{ subject = 'Your reward', sender = 'Innkeeper Allison', canReply = false }", "npc"),
        ("{ subject = 'gold', sender = 'Bankalt', canReply = true, money = 5 }", "alt"),
        ("{ subject = 'gold', sender = 'Bankalt-OtherRealm', canReply = true }", "alt"),
        ("{ subject = 'hi', sender = 'Stranger', canReply = true }", "player"),
        ("{ subject = 'hi' , canReply = true }", "other"),
    ]
    for src, want in cases:
        m = lua.eval(src)
        got = C.classify(m, isAlt)
        check(got == want, f"classify {src}: {got}, want {want}")
    check(C.key(lua.eval("{ subject = 'a', sender = 'X', cod = 0 }")) == C.key(lua.eval("{ subject = 'a', sender = 'x', cod = 0 }")),
          "the key doesn't care about the sender's case")
    mail(lua.eval("""{ { sender = 'Auction House', subject = 'Auction expired: Silk Cloth (20)', items = { { 'Silk Cloth', 4306, 20 } } },
      { sender = 'Stranger', subject = 'hi', money = 77, canReply = true } }"""))
    lst = C.scan(isAlt)
    check(len(lst) == 2 and lst[1].cat == "ah_expired" and lst[1]['items'][1].id == 4306 and lst[1].count == 20 and lst[1].exp == 100000 + 29 * 86400,
          "a scan reads every mail with its attachments and expiry")
    tot = C.totals(lst)
    check(tot.player.money == 77 and tot.ah_expired['items'] == 1, "totals per category")
    # a throwing API never escapes
    lua.execute("_G.SAVED_HDR = GetInboxHeaderInfo; GetInboxHeaderInfo = function() error('boom') end")
    check(C.read(1) is None and len(C.scan()) == 0, "a throwing API: nothing, no error")
    lua.execute("GetInboxHeaderInfo = _G.SAVED_HDR")

    # --- posting, cancelling, selling -------------------------------------------------------------------------------
    W.login()
    s = L.get()
    check(s is not None and s.alts[C.hash("Mainchar")] is True, "this character's name is kept only as a fingerprint")
    for k2 in s.alts.keys():
        check(k2 != "Mainchar", "no plain name in the alt list")
    AH = G.C_AuctionHouse
    # an item: 2 auctions of 1 at 900 each, 8 h; the deposit 60 each
    AH.PostItem(lua.eval("{ id = 6218 }"), 2, 2, None, 900)
    fire("AUCTION_HOUSE_AUCTION_CREATED", 501)
    fire("AUCTION_HOUSE_AUCTION_CREATED", 502)
    fire("AUCTION_HOUSE_AUCTION_CREATED", 503)   # a third event with nothing posted: no record
    check(len(s.auctions) == 2, f"one record per auction created: {len(s.auctions)}")
    r1, r2 = s.auctions[1], s.auctions[2]
    check(r1.aid == 501 and r1.item == 6218 and r1.name == "Runed Copper Rod" and r1.q == 1 and r1.buy == 900 and r1.dep == 60
          and r1.dur == 2 and r1.ends == 100000 + 8 * 3600 and r1.st == "listed", "posted: item, stack, buyout, deposit, duration, end")
    # a commodity: 20 Silk Cloth at 50 each, deposit 3 each
    AH.PostCommodity(lua.eval("{ id = 4306 }"), 1, 20, 50)
    fire("AUCTION_HOUSE_AUCTION_CREATED", 600)
    r3 = s.auctions[3]
    check(r3.q == 20 and r3.unit == 50 and r3.buy == 1000 and r3.dep == 60, f"a commodity auction: {r3.q} {r3.buy} {r3.dep}")
    # a post the auction house refused: nothing
    AH.PostCommodity(lua.eval("{ id = 4306 }"), 1, 5, 50)
    fire("AUCTION_HOUSE_POST_ERROR")
    fire("AUCTION_HOUSE_AUCTION_CREATED", 601)
    check(len(s.auctions) == 3, "a refused post makes no record")
    # cancel the second rod: cancelled, its deposit lost (one cost entry, also when told twice)
    AH.CancelAuction(502)
    fire("AUCTION_CANCELED", 0)
    fire("AUCTION_CANCELED", 502)
    check(r2.st == "cancelled" and not r2.done, "cancelled, the item on its way back")
    deps = [e for e in s.money.values() if e.cat == "deposit"]
    check(len(deps) == 1 and deps[0].c == 60 and deps[0].rec == r2.id, "the lost deposit is a cost, once")
    # the first rod sells: by name from the chat line, then the notification with its id
    W.sold("Runed Copper Rod", None, None, None)
    W.sold("Runed Copper Rod", None, None, 501)
    check(r1.st == "sold" and r1.est == 855 and not r1.done, f"sold, money waiting (about 900 after the 5% cut): {r1.est}")
    # the cloth's owned row says sold too
    W.owned(lua.eval("{ { id = 600, itemID = 4306, name = 'Silk Cloth', qty = 20, unit = 50, sold = true } }"))
    check(r3.st == "sold", "the owned list marks the cloth sold")
    # an auction posted elsewhere shows up in the owned list: adopted
    W.owned(lua.eval("{ { id = 600, itemID = 4306, name = 'Silk Cloth', qty = 20, unit = 50, sold = true }, { id = 700, itemID = 2840, name = 'Copper Bar', qty = 5, unit = 30, left = 3600 } }"))
    r4 = s.auctions[4]
    check(r4 and r4.aid == 700 and r4.st == "listed" and r4.why is not None and r4.buy == 150, "adopted from the owned list")
    # the cancelled rod (502) and the sold rod (501) aren't listed: they keep their outcomes; a listed one gone is "ended"
    W.owned(lua.eval("{ { id = 600, itemID = 4306, name = 'Silk Cloth', qty = 20, unit = 50, sold = true } }"))
    check(r4.st == "ended" and r1.st == "sold" and r2.st == "cancelled", f"gone from the list: ended ({r4.st})")
    c = L.openCounts(s, L.ch())
    check(c.sold == 2 and c.back == 1 and c.ended == 1 and c.listed == 0, f"open: {c.sold} sold, {c.back} back, {c.ended} ended")

    # --- the mail ---------------------------------------------------------------------------------------------------
    mail(lua.eval("""{
      { sender = 'Auction House', subject = 'Auction successful: Runed Copper Rod', money = 915,
        invoice = { 'seller', 'Runed Copper Rod', 'Buyerguy', 900, 900, 60, 45, 1 } },
      { sender = 'Auction House', subject = 'Auction canceled: Runed Copper Rod', items = { { 'Runed Copper Rod', 6218, 1 } } },
      { sender = 'Auction House', subject = 'Auction successful: Silk Cloth (20)', money = 1010,
        invoice = { 'seller', 'Silk Cloth', nil, 1000, 1000, 60, 50, 20 } },
      { sender = 'Auction House', subject = 'Auction expired: Copper Bar (5)', items = { { 'Copper Bar', 2840, 5 } } },
      { sender = 'Auction House', subject = 'Outbid on Copper Bar', money = 400 },
      { sender = 'Auction House', subject = 'Auction won: Silk Cloth', items = { { 'Silk Cloth', 4306, 10 } },
        invoice = { 'buyer', 'Silk Cloth', 'Seller', 300, 300, 0, 0, 10 } },
      { sender = 'Bankalt', subject = 'gold', money = 50000, canReply = true },
      { sender = 'Stranger', subject = 'for the boots', money = 2000, canReply = true },
      { sender = 'Innkeeper', subject = 'Your winnings', money = 700, canReply = false },
      { sender = 'Trader', subject = 'boots', cod = 1500, items = { { 'Copper Bar', 2840, 1 } }, canReply = true },
    }"""))
    # Bankalt logs in once on the account: then it is an alt
    s.alts[C.hash("Bankalt")] = True
    W.scan()
    check(r1.mailAt is not None and r1.net == 855 and r1.gross == 900 and r1.cut == 45, f"the sale's mail: net {r1.net}")
    check(r2.mailAt is not None and r3.mailAt is not None and r4.st == "expired", "every auction mail tied to its record")
    check(r4.st == "expired" and not r4.depLost, "expired without a known deposit: no cost")
    before = len(s.money)
    W.scan()
    W.scan()
    check(len(s.money) == before and len(s.auctions) == 4, "scanning again changes nothing")
    # take everything, as Open All would; then the same takes reported again (another hook, EverlookDB Mail's API)
    hook_all = W.takeHook("all")
    for i in range(1, 11):
        if i != 10:
            hook_all(i)
    for i in range(1, 10):
        hook_all(i)
        G.EverlookDBAuctionsAPI.mail.taken(C.read(i, L.isAlt), "all")
    money = {e.cat: e.c for e in s.money.values()}
    cats = [e.cat for e in s.money.values()]
    check(cats.count("sale") == 2, f"two sales, each once: {cats}")
    sales = [e for e in s.money.values() if e.cat == "sale"]
    check(sales[0].c == 855 and sales[1].c == 950, f"sales net of the cut, the deposit back left out: {[e.c for e in sales]}")
    check(money.get("refund") == 400 and money.get("alt") == 50000 and money.get("player") == 2000 and money.get("npc") == 700,
          f"refund, alt, player and NPC money in their places: {money}")
    check(r1.done and r2.done and r3.done and r4.done, "money taken and items back: every record ticked off")
    check(len(L.openList(s, L.ch())) == 0, "nothing open")
    # the C.O.D. mail: paying is a cost
    W.takeHook("item")(10, 1)
    W.takeHook("item")(10, 1)
    cods = [e for e in s.money.values() if e.cat == "cod"]
    check(len(cods) == 1 and cods[0].c == 1500, "C.O.D. paid once")
    sm = L.summary(s, None, None)
    check(sm.income == 855 + 950 + 700 and sm.other == 400 + 50000 + 2000 and sm.cost == 60 + 1500,
          f"income {sm.income}, not income {sm.other}, costs {sm.cost}")
    check(sm.net == sm.income - sm.cost and sm.back == 2, f"net and items back: {sm.net} {sm.back}")
    check(G.EverlookAuctionsCharDB.buyers[r1.id] == "Buyerguy" and r1.buyer is None, "the buyer per character, not in the account file")

    # --- other money ------------------------------------------------------------------------------------------------
    fire("MERCHANT_SHOW")
    lua.execute("MOCK_MONEY = MOCK_MONEY + 345")
    fire("PLAYER_MONEY")
    lua.execute("MOCK_MONEY = MOCK_MONEY - 100")   # money spent at the merchant: a cost (a vendor buy), not income
    fire("PLAYER_MONEY")
    fire("MERCHANT_CLOSED")
    lua.execute("MOCK_MONEY = MOCK_MONEY + 999")    # no merchant open: not a vendor sale
    fire("PLAYER_MONEY")
    fire("QUEST_TURNED_IN", 123, 450, 1200)
    L.note("loot", 77)
    sm = L.summary(s, None, None)
    check(sm.vendor == 345 and sm.quest == 1200 and sm.loot == 77, f"vendor {sm.vendor}, quest {sm.quest}, loot {sm.loot}")
    check(sm.vendorbuy == 100, f"the vendor buy is a cost: {sm.vendorbuy}")
    # a period: only what is in it
    lua.execute("MOCK_TIME = MOCK_TIME + 10 * 86400")
    L.note("vendor", 5)
    check(L.summary(s, L.since("week"), None).income == 5, "the last 7 days only")
    check(L.summary(s, L.since("all"), None).income > 5, "all time")

    # --- an unsorted entry is put right by hand ---------------------------------------------------------------------
    e = L.addMoney(s, "unsorted", 300, lua.eval("{ why = 'test' }"))
    check(e.cat == "unsorted" and L.summary(s, None, None).unsorted == 300, "unsorted is its own sum")
    L.setCategory(e, "alt")
    check(e.cat == "alt" and e.fixed and e.why is None and e.wasWhy == "test", "picked by hand, the reason kept")

    # --- the AH API door ----------------------------------------------------------------------------------------------
    api = G.EverlookDBAuctionsAPI
    check(api.version == 7 and api.mail.version == 1 and lua.eval("rawequal")(api.mail.classifier(), C), "API version 7 with mail")
    check(api.mail.scanned(lua.eval("{ { cat = 'player', subject = 'x', sender = 'y', exp = 1 } }")) is True, "scanned answers")
    check(api.mail.taken(lua.eval("{ }"), "money") is True, "taken ignores a mail without a category quietly")
    okW = lua.eval("function(a) return (pcall(function() a.mail.version = 2 end)) end")(api)
    check(okW is False, "the mail API is read-only")
    # ledger off: the door says false, nothing written
    DB.logIncome = False
    n = len(s.money)
    check(api.mail.taken(lua.eval("{ cat = 'player', money = 10, subject = 'z', sender = 'q', exp = 5 }"), "money") in (False, True)
          and len(s.money) == n, "with the ledger off nothing is written")
    DB.logIncome = None

    # --- migration from the old AH log ------------------------------------------------------------------------------
    old = lua.eval("""{
      income = { { t = 50, kind = 'sale', name = 'Copper Bar', q = 5, c = 140, gross = 150, h = 'Realm-Alliance' },
        { t = 60, kind = 'ah', c = 90 }, { t = 70, kind = 'mail', c = 500 } },
      soldPending = { { t = 80, name = 'Silk Cloth', q = 20, est = 900 } } }""")
    G.EverlookAuctionsCharDB.forSale = lua.eval("{ at = 90, list = { { id = 2840, name = 'Copper Bar', q = 5, c = 150, ends = 9999999 } } }")
    G.MOCK_DB = old
    s2 = L.get()
    W.login()
    cats = [e.cat for e in s2.money.values()]
    check(cats == ["sale", "refund", "unsorted"], f"old income sorted: {cats}")
    check(s2.money[1].why is not None and s2.money[3].why is not None and "sender" in s2.money[3].why, "each says why")
    check(len(s2.auctions) == 2 and s2.auctions[1].st == "sold" and s2.auctions[1].est == 900 and s2.auctions[2].st == "listed",
          "old waiting sales and for-sale auctions become records")
    check(len(old.income) == 3 and len(old.soldPending) == 1, "the old tables are kept")
    check(s2.migrated.income == 3 and s2.migrated.pending == 1, "what was moved is noted")
    W.login()
    check(len(s2.money) == 3 and len(s2.auctions) == 2, "migrated once")
    # looted coins from the loot log become "Looted money", once per character; mail entries are left out
    s3 = lua.eval("{ v = 1, seq = 0, auctions = {}, money = {}, mails = {}, alts = {} }")
    looted = lua.eval("{ { t = 10, copper = 120, loot = true, zone = 'Tanaris' }, { t = 11, copper = 99, got = 'mail' }, { t = 12, id = 2770, q = 1, loot = true } }")
    check(L.migrateLoot(s3, looted, "c1", 20) == 1 and s3.money[1].cat == "loot" and s3.money[1].c == 120 and s3.money[1].t == 10, "looted coins migrated")
    check(L.migrateLoot(s3, looted, "c1", 20) == 0 and len(s3.money) == 1, "looted coins migrated once")
    s3.auctions[1] = lua.eval("{ name = 'Copper Bar', item = 2840 }")
    check(L.itemByName(s3, "Copper Bar") == 2840 and L.itemByName(s3, "Nope") is None, "item by name")
    # the hub's numbers come from the ledger
    t, w, waiting, est = L.hubNumbers(s2, None, 100)
    check(t == 140 and waiting == 1 and est == 900, f"hub: today {t}, waiting {waiting} ~{est}")
    return failures

def list_import():
    """Pasting a list of items (ListImport.lua): every common form of a line, item links and IDs, max prices,
    amounts added up, lines it can't use returned (never dropped), searches kept, merging into a list, Export read
    back, and the Shopping tab's Import leaving the lines to fix in the box."""
    lua = lua51.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(source_of("tests/mock.lua"))
    ns = lua.table()
    run = lua.eval("function(src, name, ...) local f = assert(loadstring(src, name)); return f(...) end")
    run(VENDOR_SETUP, "setup", ns)
    G = lua.globals()
    G.NS = ns
    lua.execute("""
      local ns = NS
      MOCK_ITEMS[2318] = "Light Leather"; MOCK_ITEMS[2320] = "Coarse Thread"
      local db = ns.db()
      db.itemInfo[2318] = "1^10^0^Trade Goods^Leather^^134400^15^20^Light Leather"
      db.itemInfo[2320] = { "Coarse Thread", 1, 10, 0, "Trade Goods", "Parts", "", 1, 2, 20 }
      ns.itemInfo = function(id) local c = db.itemInfo[id]; if type(c) == "string" then return { c:match("([^^]*)$") } end return c end
    """)
    run(source_of("Formula.lua"), "Formula.lua", "EverlookDBAuctions", ns)
    run("local ns = ...; ns.myPriceNames = function() return { myfloor = {} } end", "my", ns)
    run(source_of("ListImport.lua"), "ListImport.lua", "EverlookDBAuctions", ns)
    I = ns.listImport
    failures = []

    def check(cond, what):
        if not cond:
            failures.append("list import: " + what)

    def parsed(line):
        e = I.parseLine(line)
        return None if e is None else {k: e[k] for k in e.keys() if k != "line"}

    forms = {
        "60 Light Leather": {"name": "Light Leather", "n": 60},
        "60x Light Leather": {"name": "Light Leather", "n": 60},
        "60 x Light Leather": {"name": "Light Leather", "n": 60},
        "Light Leather x60": {"name": "Light Leather", "n": 60},
        "Light Leather x 60": {"name": "Light Leather", "n": 60},
        "Light Leather, 60": {"name": "Light Leather", "n": 60},
        "Light Leather: 60": {"name": "Light Leather", "n": 60},
        "Light Leather - 60": {"name": "Light Leather", "n": 60},
        "Light Leather (60)": {"name": "Light Leather", "n": 60},
        "Light Leather\t60": {"name": "Light Leather", "n": 60},
        "  - 60 Light Leather  ": {"name": "Light Leather", "n": 60},
        "☐ 90x Rough Stone": {"name": "Rough Stone", "n": 90},           # a guide's table, check box copied along
        "10x Green Dye (vendor)": {"name": "Green Dye", "n": 10, "vendor": True},
        "Material": None,
        "Material	Amount": None,
        "1. 20 Light Leather": {"name": "Light Leather", "n": 20},
        "[ ] 5 Light Leather": {"name": "Light Leather", "n": 5},
        "[Light Leather] x60": {"name": "Light Leather", "n": 60},
        "60 [Light Leather]": {"name": "Light Leather", "n": 60},
        "|cffffffff|Hitem:2318::::::::|h[Light Leather]|h|r x60": {"id": 2318, "name": "Light Leather", "n": 60},
        "2318 60": {"id": 2318, "n": 60},
        "2318": {"id": 2318},
        "item:2318 x5": {"id": 2318, "n": 5},
        "60 Light Leather #2318": {"id": 2318, "name": "Light Leather", "n": 60},
        'name is "Light Leather" buy 60': {"name": "Light Leather", "n": 60},
        "60 Light Leather max 25s": {"name": "Light Leather", "n": 60, "max": 2500},
        "12 Coarse Thread (max 1g 50s)": {"name": "Coarse Thread", "n": 12, "max": 15000},
        "Light Leather x60 under 30s": {"name": "Light Leather", "n": 60, "max": 3000},
        "60 Light Leather max 25": {"name": "Light Leather", "n": 60, "maxBad": True},
        "60 Light Leather max 80% of median": {"name": "Light Leather", "n": 60, "max": "80% of median"},
        "60 Light Leather max myfloor": {"name": "Light Leather", "n": 60, "max": "myfloor"},
        "Box 60": {"name": "Box", "n": 60},
        "Light Leather": {"name": "Light Leather"},
        "# Bags": {"header": "Bags"},
        "slot is trinket and price lt 5g": {"search": "slot is trinket and price lt 5g"},
    }
    for line, want in forms.items():
        got = parsed(line)
        check(got == want, f"{line!r} -> {got}, expected {want}")
    check(parsed("") is None and parsed("   ") is None and parsed("// note") is None, "empty lines and comments")
    check(parsed("60×Light Leather") == {"name": "Light Leather", "n": 60}, "the times sign")
    check(I.money("1g 50s") == 15000 and I.money("25s") == 2500 and I.money("2.5g") == 25000 and I.money("75") is None,
          "money in g, s and c")
    check(I.moneyText(15000) == "1g50s" and I.moneyText(2505) == "25s5c", "money as typed text")
    unpacked = I.unpack('Bags^"Light Leather";;0;0;0;0;0;0;0;0;;#;;60^"Coarse Thread";;0;0;0;0;0;0;0;0;;#;;12')
    check(unpacked.split("\n") == ["# Bags", "60 Light Leather", "12 Coarse Thread"], f"another addon's export: {unpacked!r}")

    # a whole paste: amounts added up, IDs and names, a name nobody knows, an ID still loading, searches
    text = "\n".join([
        "60 Light Leather", "Light Leather x10 max 20s", "2318 5", "12 Coarse Thread max 30s", "Coarse Thread, 3 max 10s",
        "40 Light Leathr", "[Mystery Thing] x2", "999999 4", "slot is trinket", "Silk Clot",
        "# Second", "2 Coarse Thread"])
    res = I.read(text, I.lookup, "Leatherworking")
    names = [res.lists[k].name for k in range(1, len(res.lists) + 1)]
    check(names == ["Leatherworking", "Second"], f"lists: {names}")
    first = res.lists[1]
    items = {first["items"][k].id: (first["items"][k].n, first["items"][k].max) for k in range(1, len(first["items"]) + 1)}
    check(items == {2318: (75, 2000), 2320: (15, 1000)}, f"amounts added up, the lowest max kept: {items}")
    bad = {res.bad[k].line: res.bad[k].why for k in range(1, len(res.bad) + 1)}
    check(bad == {"40 Light Leathr": "unknown", "[Mystery Thing] x2": "unknown", "999999 4": "loading"},
          f"lines it couldn't use are returned with why: {bad}")
    check(list(res.loading.values()) == [999999], "the ID still loading is asked for")
    check([first.searches[k] for k in range(1, len(first.searches) + 1)] == ["slot is trinket", "Silk Clot"],
          "a search stays a search; a bare unknown name is kept as one")
    check(res.asSearch is not None and res.asSearch[1] == "Silk Clot", "and that is said")
    check(I.idOf("light leathers") == 2318, "names are found whatever the case, plural too")

    # saving: a new list, then the same name again adds up
    lists = lua.table()
    done = I.save(lists, res, True)
    l = lists[1]
    check(len(lists) == 2 and l.name == "Leatherworking" and done[1].new is True, "saved as named lists")
    q = 'name is "Light Leather"'
    check(l.want[q] == 75 and l["items"][q] == 2318 and l.max[q] == 2000 and l.countHave is True,
          "amount, item ID, max price and count-what-you-have saved")
    check([l.queries[k] for k in range(1, len(l.queries) + 1)] ==
          [q, 'name is "Coarse Thread"', "slot is trinket", "Silk Clot"], "items first, then the searches, in order")
    again = I.read("5 Light Leather", I.lookup, "Leatherworking")
    I.save(lists, again, True)
    check(len(lists) == 2 and lists[1].want[q] == 80, "importing into the same list adds up")

    # Export reads back the same
    out = I.export(l, I.moneyText)
    check(out.split("\n")[1] == "80 Light Leather #2318 max 20s", f"export line: {out.split(chr(10))[1]!r}")
    back = I.read(out, I.lookup)
    bl = back.lists[1]
    check(bl.name == "Leatherworking" and bl["items"][1].n == 80 and bl["items"][1].max == 2000 and len(back.bad) == 0,
          "Export imports back the same")

    # the Shopping tab: Import saves, says what it did, and leaves the lines to fix in the box
    run(source_of("Skin.lua"), "Skin.lua", "EverlookDBAuctions", ns)
    run(source_of("BuyList.lua"), "BuyList.lua", "EverlookDBAuctions", ns)
    run(source_of("Shopping.lua"), "Shopping.lua", "EverlookDBAuctions", ns)
    lua.execute("AuctionHouseFrame = CreateFrame('Frame', 'AuctionHouseFrame'); C_Timer = { After = function() end }")
    fire = lua.eval("function(e, a) for _, f in ipairs(MOCK_FRAMES) do if f.scripts.OnEvent then f.scripts.OnEvent(f, e, a) end end end")
    db = ns.db()
    db.lists = lua.table()
    lua.execute("C_Timer = { After = function(_, fn) fn() end }")
    fire("AUCTION_HOUSE_SHOW")
    f = G.EverlookAuctionsShopping
    lua.eval("function(f) f.lists.SetItems = function() end; f.queries.SetItems = function() end end")(f)
    f.Show(f)
    ns.shopping.openImport()
    io = f.io
    check(io.shown and io.go.shown, "/eah import opens the import box")
    io.box.text = "60 Light Leather\n40 Light Leathr"
    io.saveAs.text = "Bags"
    io.go.scripts.OnClick(io.go)
    check(len(db.lists) == 1 and db.lists[1].name == "Bags" and db.lists[1].want[q] == 60, "saved as Bags")
    check(io.shown and io.box.text == "40 Light Leathr" and io.saveAs.text == "Bags",
          f"the line to fix stays in the box, for the same list: {io.box.text!r}")
    check("1 item in the new list Bags" in io.report.text and "Light Leathr: no item by that name" in io.report.text,
          f"the report: {io.report.text!r}")
    io.box.text = "40 Light Leather"
    io.go.scripts.OnClick(io.go)
    check(db.lists[1].want[q] == 100 and not io.shown, f"fixed and imported again: added up, box closed")
    check(f.buyBtn.shown and not f.runPrimary.shown, "a list with amounts: Buy this list is the one gold button")
    return failures


BUYLIST_SETUP = """
local ns = ...
AuctionHouseFrame = CreateFrame("Frame", "AuctionHouseFrame")
ns.itemInfo = function(id) return ns.db().itemInfo[id] end
MOCK_ITEMS[2589] = "Linen Cloth"; MOCK_ITEMS[2592] = "Wool Cloth"; MOCK_ITEMS[3000] = "Old Sword"
SAID = {}
ns.say = function(m) SAID[#SAID + 1] = m end
USUAL = {}
ns.scanRowFor = function(key) local id = tonumber(key:match("^(%d+)")); return USUAL[id] and { med = USUAL[id] } end
"""


def buy_list():
    """Buy this list (BuyList.lua) against a fake auction house: it asks about each item, shows the cheapest way to
    get the amount still needed (what you have and what was bought before count), asks for the exact price without
    buying, buys only on the Buy click, counts what was bought, handles fewer listed than wanted, a max price, a price
    far above the usual one, a refused or failed purchase, a price that is gone, Skip, the auction house closing,
    and ends with what was bought, skipped and spent."""
    lua = lua51.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(source_of("tests/mock.lua"))
    ns = lua.table()
    run = lua.eval("function(src, name, ...) local f = assert(loadstring(src, name)); return f(...) end")
    run(VENDOR_SETUP, "setup", ns)
    lua.execute(BUY_SETUP)
    run(AHQ_FAKE, "ahq", ns)
    run(BUYLIST_SETUP, "buylist", ns)
    for name in ["Skin.lua", "ListImport.lua", "BuyList.lua"]:
        run(source_of(name), name, "EverlookDBAuctions", ns)
    G = lua.globals()
    W = ns.buyList
    # most of these tests use a client that allows the automatic price ask; WoW Forever needs a click (see below)
    ns.db().quoteByClick = False
    I = ns.listImport
    tbl = lua.eval("function(...) return { ... } end")
    browse_answer = lua.eval("function(id) return { ok = true, full = true, entries = { { itemKey = { itemID = id } } } } end")
    failures = []

    def check(cond, what):
        if not cond:
            failures.append("buy list: " + what)

    def fire(e, *args):
        W.events[e](*args)

    def calls(name):
        return [G.CALLS[i] for i in range(1, len(G.CALLS) + 1) if G.CALLS[i][1] == name]

    def answer(item_id):
        G.AHQ.browse(browse_answer(item_id))
        G.AHQ["items"](G.AHQ.key, True, True)

    def click(b):
        b.scripts.OnClick(b)

    def auction(aid, buyout, qty=1):
        return lua.table(auctionID=aid, buyoutAmount=buyout, quantity=qty, containsOwnerItem=False, timeLeft=3)

    def comm(unit, qty, mine=0):
        return lua.table(unitPrice=unit, quantity=qty, numOwnerItems=mine)

    # the pure parts: what is still needed
    l0 = lua.eval('{ want = { a = 30 }, got = { a = { n = 25, base = 5 } }, countHave = true }')
    check(W.need(l0, "a", 5)[0] == 0, "bought 25 with 5 in the bags: nothing more")
    check(W.need(l0, "a", 30)[0] == 0, "and none once the mail is collected")
    check(W.need(l0, "a", 2)[0] == 0, "nor after using some of what you had")
    l1 = lua.eval('{ want = { a = 30 }, got = { a = { n = 10 } } }')
    check(W.need(l1, "a", 99)[0] == 20, "a list of what to buy: what you have doesn't count, what was bought does")
    rows = tbl(lua.table(unit=10, others=20), lua.table(unit=12, others=10), lua.table(unit=40, others=50))
    p = W.plan(rows, 25, True, 15)
    check(p.got == 25 and p.cost == 260 and p.overMax == 50 and p.avg == 10, f"plan under the max: {p.got} {p.cost} {p.overMax}")
    w = W.warnings(W.plan(rows, 100, True, 15), 100, None, 15)
    check(w[1] == "Only 30 under your max of 15c (you want 100).", f"short under the max: {w[1]}")
    w = W.warnings(W.plan(rows, 100, True, None), 100, None, None)
    check(w[1] == "Only 80 listed (you want 100).", f"short: {w[1]}")

    # a list: 30 Linen Cloth (5 in the bags, max 15c), 2 Old Swords, 5 Wool Cloth; a search is left out
    G.MOCK_BAGS[2589] = 5
    res = I.read("30 Linen Cloth max 15c\n2 Old Sword\n5 Wool Cloth\nslot is trinket", I.lookup, "Mats")
    lists = ns.db().lists = lua.table()
    I.save(lists, res, True)
    l = lists[1]
    check(len(W.entries(l)) == 3, "three items to buy, the search left out")
    G.USUAL[2589] = 12
    est = W.estimate(l)
    check(est.each['name is "Linen Cloth"'].cost == 25 * 12, f"Linen Cloth: 25 still needed at 12c: {est.each['name is \"Linen Cloth\"'].cost}")
    check(est.total >= 300 and est.priced >= 1, f"the whole list's estimate: {est.total}")
    check("26% over the usual price" in W.vsUsual(126, 100) and "under the usual" in W.vsUsual(90, 100), "how a price compares with the usual one")
    G.AuctionHouseFrame.IsShown = lua.eval("function() return false end")
    W.begin(l)
    check("open the auction house first" in (G.SAID[len(G.SAID)] or ""), "the auction house must be open")
    G.AuctionHouseFrame.IsShown = lua.eval("function() return true end")
    # a row's Buy button: only that item (Wool Cloth), straight to its question
    check(W.begin(l, 'name is "Wool Cloth"') is True, "one row's Buy starts")
    check(W.frame.head.text == "5 Wool Cloth", f"only that item, looking at once (no Yes): {W.frame.head.text}")
    W.stop()
    check(W.begin(l) is True, "it starts")
    f = W.frame
    check(f is not None and f.shown, "the panel shows beside the auction house")
    check(f.head.text == "Buy 25 Linen Cloth?" and f.go.text == "Yes", f"first question: {f.head.text} / {f.go.text}")
    check("wants 30, you have 5" in f.sub.text, f"have and want: {f.sub.text}")
    check(f.max.text == "15c" and f.max.shown, f"the max price from the import: {f.max.text}")

    # Yes: it looks, plans the cheapest 25 under 15c each, and asks for the exact price (buying nothing)
    G.IS_COMMODITY = True
    G.COMMS = tbl(comm(10, 20), comm(12, 10), comm(40, 50))
    click(f.go)
    check(f.go.text == "Looking...", f"while looking: {f.go.text}")
    # the auction house is still busy after the search: the price is asked for once it says it's ready
    G.AH_READY = False
    answer(2589)
    check(not calls("Start"), "no price asked while the auction house is busy")
    check(f.go.text == "Waiting for the auction house...", f"while it's busy: {f.go.text}")
    click(f.go)
    check(not calls("Start"), "a click while waiting sends nothing")
    G.AH_READY = True
    fire("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
    check(calls("Start") and calls("Start")[0][2] == 2589 and calls("Start")[0][3] == 25, "the price of 25 is asked for")
    check(len(calls("Confirm")) == 0, "nothing bought without the Buy click")
    check("20 at 10c each" in f.body.text and "5 at 12c each" in f.body.text and "Total 260c" in f.body.text,
          f"how many from which price: {f.body.text!r}")
    check(f.go.text == "Getting the price...", f.go.text)
    fire("COMMODITY_PRICE_UPDATED", 10, 260)
    check(f.go.text == "Buy for 260c", f"the exact price on the button: {f.go.text}")
    G.MONEY = 100
    ns.buyList.render()
    check("Not enough money" in f.warn.text, f"too little money: {f.warn.text}")
    click(f.go)
    check(len(calls("Confirm")) == 0, "not bought without the money")
    G.MONEY = 100000
    ns.buyList.render()
    click(f.go)
    conf = calls("Confirm")
    check(len(conf) == 1 and conf[0][2] == 2589 and conf[0][3] == 25, "one click on Buy buys the 25")
    check(f.go.text == "Buying...", f.go.text)
    click(f.go)
    check(len(calls("Confirm")) == 1, "a second click while it buys does nothing")
    fire("COMMODITY_PURCHASE_SUCCEEDED")
    q = 'name is "Linen Cloth"'
    check(l.got[q].n == 25 and l.got[q].base == 5, "the 25 are ticked off the list")
    check("Bought 25 Linen Cloth for 260c" in f.status.text, f"said: {f.status.text}")

    # Old Sword: one auction at a time, far above the usual price, one refused
    check(f.head.text == "Buy 2 Old Sword?", f"next: {f.head.text}")
    G.USUAL[3000] = 150
    G.IS_COMMODITY = False
    G.ITEMS = tbl(auction(1, 300), auction(2, 600))
    G.CALLS = lua.table()
    click(f.go)
    answer(3000)
    check(len(calls("Start")) == 0, "single items need no price quote")
    check(f.go.text == "Buy 1 for 300c", f.go.text)
    check("Far above the usual price" in f.warn.text and "150c" in f.warn.text, f"price warning: {f.warn.text!r}")
    click(f.go)
    bids = calls("PlaceBid")
    check(len(bids) == 1 and bids[0][2] == 1 and bids[0][3] == 300, "Buy buys the cheapest one")
    fire("AUCTION_HOUSE_PURCHASE_COMPLETED", 1)
    check(f.go.text == "Buy 1 for 600c" and l.got['name is "Old Sword"'].n == 1, f"then the next one: {f.go.text}")
    click(f.go)
    fire("AUCTION_HOUSE_SHOW_ERROR", 1)
    check("refused" in f.status.text and "Nothing was paid" in f.status.text, f"refused: {f.status.text}")
    G.ITEMS = tbl()
    G.advance(1)           # it looks again
    answer(3000)
    check("None for sale" in f.warn.text and f.go.text == "Next item", f"gone: {f.warn.text} / {f.go.text}")
    click(f.go)

    # Wool Cloth: only 3 listed; the price is gone once, then Skip
    check(f.head.text == "Buy 5 Wool Cloth?", f.head.text)
    G.IS_COMMODITY = True
    G.COMMS = tbl(comm(50, 3))
    G.CALLS = lua.table()
    click(f.go)
    answer(2592)
    check("Only 3 listed (you want 5)." in f.warn.text, f"partly available: {f.warn.text!r}")
    check(calls("Start")[0][3] == 3, "the price of the 3 listed is asked for")
    fire("COMMODITY_PRICE_UNAVAILABLE")
    check("aren't for sale any more" in f.status.text, f.status.text)
    answer(2592)
    check(len(calls("Start")) == 2, "it looks and asks again")
    fire("COMMODITY_PRICE_UPDATED", 50, 150)
    G.advance(25)          # the price runs out before the click
    check(f.go.text == "Get the price" and "ran out" in f.status.text, f"the price ran out: {f.go.text} / {f.status.text}")
    click(f.go)
    check(len(calls("Start")) == 3 and len(calls("Confirm")) == 0, "Get the price asks again and buys nothing")
    fire("COMMODITY_PRICE_UPDATED", 50, 150)
    click(f.go)
    fire("COMMODITY_PURCHASE_FAILED")
    check("didn't go through" in f.status.text, f.status.text)
    G.advance(1)
    answer(2592)
    click(f.skip)

    # the end: what was bought, skipped and spent
    check(f.head.text == "Done" and f.go.text == "Close", f"done: {f.head.text}")
    check("Bought 2 items for 560c." in f.body.text, f"summary: {f.body.text!r}")
    check("1 Old Sword (of 2)" in f.body.text and "Skipped: Wool Cloth" in f.body.text, f"summary lines: {f.body.text!r}")
    check(ns.listBuying is None, "background searches may run again")
    click(f.go)
    check(not f.shown, "Close shuts the panel")

    # again: what was bought isn't bought twice; the auction house closing stops it and says what was bought
    W.begin(l)
    check(f.head.text == "Buy 1 Old Sword?", f"only what is still needed: {f.head.text}")
    G.ITEMS = tbl(auction(7, 300))
    G.IS_COMMODITY = False
    G.CALLS = lua.table()
    click(f.go)
    answer(3000)
    click(f.go)
    fire("AUCTION_HOUSE_PURCHASE_COMPLETED", 7)
    fire("AUCTION_HOUSE_CLOSED")
    check(not f.shown and "auction house closed" in G.SAID[len(G.SAID)], f"closed: {G.SAID[len(G.SAID)]}")
    check(W.state() is None, "the walk is over")

    # /eah buy with a list name that isn't there
    ns.slash("buy nothing here")
    check("no list called" in G.SAID[len(G.SAID)] and "mats" in G.SAID[len(G.SAID)], G.SAID[len(G.SAID)])
    # the game blocks the automatic price ask while the call runs and names it only "UNKNOWN()": a click from then on
    G.MOCK_BAGS[2589] = 0
    l.got = None
    real_start = G.C_AuctionHouse.StartCommoditiesPurchase
    G.C_AuctionHouse.StartCommoditiesPurchase = lambda *a: fire("ADDON_ACTION_BLOCKED", "EverlookDBAuctions", "UNKNOWN()")
    G.IS_COMMODITY = True
    G.COMMS = tbl(comm(10, 40))
    W.begin(l)
    click(f.go)
    answer(2589)
    check(ns.db().quoteByClick is True, "a block named UNKNOWN() during the price ask is remembered")
    check(f.go.text == "Get the price", f"it waits for a click: {f.go.text}")
    G.C_AuctionHouse.StartCommoditiesPurchase = real_start
    ns.db().quoteByClick = False
    W.stop()
    W.stop()
    # another addon's or another call's block is not ours to read
    fire("ADDON_ACTION_BLOCKED", "EverlookDBAuctions", "UNKNOWN()")
    check(ns.db().quoteByClick is False, "a block outside the price ask changes nothing")
    # a client that wants a click for the price: Get the price from then on
    G.MOCK_BAGS[2589] = 0
    l.got = None
    W.begin(l)
    fire("ADDON_ACTION_BLOCKED", "EverlookDBAuctions", "C_AuctionHouse.StartCommoditiesPurchase()")
    check(ns.db().quoteByClick is True, "remembered")
    G.IS_COMMODITY = True
    G.COMMS = tbl(comm(10, 40))
    G.CALLS = lua.table()
    click(f.go)
    answer(2589)
    check(len(calls("Start")) == 0 and f.go.text == "Get the price", f"asks for a click: {f.go.text}")
    # the default (nothing learned yet) is a click too: WoW Forever blocks the ask from code, and when the auction
    # house was busy at the click, its "ready" event (no click) never asks by itself (2026-11-27 BugSack error)
    W.stop()
    ns.db().quoteByClick = None
    G.MOCK_BAGS[2589] = 0
    l.got = None
    W.begin(l)
    G.CALLS = lua.table()
    click(f.go)
    answer(2589)
    check(len(calls("Start")) == 0 and f.go.text == "Get the price", f"default: the price waits for a click: {f.go.text}")
    busy = [True]
    real_ready = G.C_AuctionHouse.IsThrottledMessageSystemReady
    G.C_AuctionHouse.IsThrottledMessageSystemReady = lambda *a: not busy[0]
    click(f.go)
    check(len(calls("Start")) == 0, "busy at the click: waits")
    busy[0] = False
    fire("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
    check(len(calls("Start")) == 0, "ready again: never asks without a click")
    check(f.go.text == "Get the price", f"the button asks again: {f.go.text}")
    click(f.go)
    check(len(calls("Start")) == 1, f"the next click asks: {len(calls('Start'))}")
    G.C_AuctionHouse.IsThrottledMessageSystemReady = real_ready
    W.stop()
    W.stop()
    check(not f.shown, "Stop, then Close")
    return failures


def sell_all():
    """Sell all (SellRules.lua, SellAll.lua): rules in order, floor / normal / undercut with formulas, never under the
    floor, keep N, at most N up, the queue from the bags, which undercut auctions to cancel, and one auction house
    call per click."""
    lua = lua51.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(source_of("tests/mock.lua"))
    lua.execute("wipe = function(t) for k in pairs(t) do t[k] = nil end return t end")
    ns = lua.table()
    run = lua.eval("function(src, name, ...) local f = assert(loadstring(src, name)); return f(...) end")
    db = run(VENDOR_SETUP, "setup", ns)
    for name in ["Skin.lua", "Vendor.lua", "Search.lua", "SellRules.lua"]:
        run(source_of(name), name, "EverlookDBAuctions", ns)
    R = ns.sellRules
    tbl = lua.eval("function(...) return { ... } end")
    failures = []

    def check(cond, what):
        if not cond:
            failures.append("sell all: " + what)

    # rules and their order: the first one that is on and matches wins; Everything comes last
    rules = R.all(db)
    check(len(rules) == 1 and rules[1].base is True and rules[1].name == "Everything", "a default rule with no setup")
    check(rules[1].floor == "max(vendor + deposit, deposit)" and rules[1].below == "skip", "the default floor never posts at a loss")
    _cloth, _i = R.add(db, lua.table(name="Cloth", query="name has cloth"))
    wool, _i = R.add(db, lua.table(name="Wool", query='name is "Wool Cloth"', keep=5))
    linen, wool_row, sword = ns.queryItemRow(2589), ns.queryItemRow(2592), ns.queryItemRow(3000)
    rules = R.all(db)
    check(len(rules) == 3 and rules[3].base is True, "new rules go above Everything")
    r, i = R.ruleFor(rules, linen)
    check(r.name == "Cloth" and i == 1, f"Linen Cloth: the Cloth rule ({r.name})")
    r, i = R.ruleFor(rules, wool_row)
    check(r.name == "Cloth", "Wool Cloth matches both: the first one wins")
    check(R.move(db, 2, -1) is True, "move Wool up")
    r, i = R.ruleFor(R.all(db), wool_row)
    check(r.name == "Wool" and i == 1, f"after moving it up, Wool wins ({r.name})")
    check(R.move(db, 1, -1) is False and R.move(db, 2, 1) is False, "nothing moves past the ends (Everything stays last)")
    wool.on = False
    r, _i = R.ruleFor(R.all(db), wool_row)
    check(r.name == "Cloth", "a rule that is off is passed over")
    wool.on = True
    r, _i = R.ruleFor(R.all(db), sword)
    check(r.name == "Everything", "what no rule covers falls to Everything")
    R.add(db, lua.table(name="Bad", query="price lt"))
    r, _i = R.ruleFor(R.all(db), linen)
    check(r.name != "Bad", "a rule whose search can't be read matches nothing")
    check(R.checkQuery("price lt") is not None and R.checkQuery("name has cloth") is None, "searches are checked before they are saved")
    check(R.checkFormula("max(vendor + deposit, deposit)") is None, "deposit is a price in a rule's formula")
    check(R.checkFormula("max(vendor,") is not None and R.checkFormula("bogus * 2") is not None, "a bad formula is refused")
    check(R.remove(db, 3) is True and len(R.all(db)) == 3, "remove a rule")
    check(R.remove(db, 9) is False, "removing one that isn't there does nothing")
    # an older saved rule gets what it lacks
    old = R.norm(lua.table(name="  Old ", keep="7", below="nonsense", duration=9))
    check(old.name == "Old" and old.keep == 7 and old.below == "skip" and old.duration == 3 and old.floor == R.DEFAULT_FLOOR,
          "an old rule is filled in and tidied")

    # undercut
    check(R.parseUndercut("") is None, "empty: the Undercut by setting")
    check(R.parseUndercut("1c").copper == 1 and R.parseUndercut("1g50s").copper == 15000 and R.parseUndercut("5%").pct == 5,
          "1c, 1g50s and 5%")
    check(R.parseUndercut("0").copper == 0, "0 matches")
    okU, why = R.parseUndercut("1.5s")
    check(okU is False and "isn't an undercut" in why, "1.5s is refused")
    check(R.undercutBy(1000, lua.table(copper=1), 1) == 999, "1c under 10s")
    check(R.undercutBy(80, lua.table(copper=100), 1) == 79, "1s under 80c is 79c (never more than 5% off)")
    check(R.undercutBy(10000, lua.table(pct=5), 1) == 9500, "5% under 1g")
    check(R.undercutBy(250, lua.table(copper=1), 100) == 200, "whole silver only: 1c under 2s50c is 2s")
    check(R.undercutBy(500, lua.table(copper=0), 1) == 500, "0 matches the cheapest")

    # prices: floor, normal, undercut, with formulas; never under the floor
    rule = R.newRule("T")
    rule.undercut = "1c"
    row = lua.table(id=2589, name="Linen Cloth", sell=13, median=100, pcRun=True, median30=False, low30=False)

    def price(live=None, deposit=5, step=1, last=None, r=None, u=None):
        c = lua.table(row=row, step=step, deposit=deposit, live=live, last=last, undercut=u)
        return R.price(r or rule, c)
    res = price(lua.table(lowestOther=30))
    check(res.action == "post" and res.price == 29 and res.floor == 18, f"1c under 30c, floor vendor 13c + deposit 5c: {res.price} {res.floor}")
    check(res.why[1] == "1c under the cheapest, 30c.", res.why[1])
    res = price(lua.table(lowestOther=15))
    check(res.action == "skip" and res.short == "under the floor" and "under your floor, 18c: not posted" in res.why[1],
          f"14c is under the 18c floor: not posted ({res.why[1]})")
    rule.below = "floor"
    res = price(lua.table(lowestOther=15))
    check(res.action == "post" and res.price == 18, f"below = floor: posted at the floor ({res.price})")
    rule.below = "vendor"
    res = price(lua.table(lowestOther=15))
    check(res.action == "vendor" and "sell it to a vendor" in res.why[1], "below = vendor: left for a vendor")
    rule.below = "skip"
    res = price(lua.table(full=True))
    check(res.action == "post" and res.price == 100 and "normal price" in res.why[1], f"nobody selling: the normal price, the scan median ({res.price})")
    rule.normal = "120% of median"
    res = price(lua.table(full=True))
    check(res.price == 120, f"a formula as the normal price: {res.price}")
    rule.normal = "10c"
    rule.below = "floor"
    res = price(lua.table(full=True))
    check(res.price == 18, f"a normal price under the floor is raised to it: {res.price}")
    rule.below = "skip"
    rule.normal = R.DEFAULT_NORMAL
    rule.floor = "80% of median"
    res = price(lua.table(lowestOther=79))
    check(res.floor == 80 and res.action == "skip", f"a formula floor: 80% of a 1s median is 80c ({res.floor})")
    rule.floor = "max(vendor + deposit, deposit)"
    res = price(lua.table(lowestOther=10, lone=True, second=40))
    check(res.price == 39 and "skipped a lone one" in res.why[1], f"a lone cheap one is passed over: {res.price}")
    res = price(lua.table(lowestOther=50, lowestMine=40))
    check(res.price == 40 and "your own" in res.why[1], "your own cheaper auction is matched, never undercut")
    res = price(lua.table(lowestOther=250), step=100)
    check(res.price == 200 and res.floor == 100, f"whole silver: price 2s, floor rounded up to 1s ({res.price} {res.floor})")
    row.median = None
    res = price(lua.table(full=True))
    check(res.action == "skip" and res.short == "no price", "nobody selling and no normal price: not posted")
    res = price(lua.table(full=True), last=77)
    check(res.action == "post" and res.price == 77, "your last price when there is no normal one")
    res = price(None)
    check(res.action == "skip", "no live answer: nothing is posted")
    row.median = 100
    rule.undercut = ""
    res = price(lua.table(lowestOther=10000), u=lua.table(pct=10))
    check(res.price == 9000, f"an empty undercut uses the setting (10%): {res.price}")
    rule.undercut = "0"
    res = price(lua.table(lowestOther=300))
    check(res.price == 300 and res.why[1].startswith("Matches the cheapest"), res.why[1])
    rule.undercut = "1c"
    # never under the floor, whatever the numbers
    worst = []
    for below in ("skip", "floor", "vendor"):
        rule.below = below
        for cheapest in (1, 7, 17, 18, 19, 40, 101, 999):
            for step in (1, 100):
                for dep in (0, 5, 33):
                    res = price(lua.table(lowestOther=cheapest), deposit=dep, step=step)
                    if res.action == "post" and res.floor is not None and res.price < res.floor:
                        worst.append((below, cheapest, step, dep, res.price, res.floor))
    check(not worst, f"a posted price is never under the floor: {worst[:3]}")
    rule.below = "skip"
    ex = R.explain(rule, price(lua.table(lowestOther=30)))
    check("Rule T" in ex and "floor 18c" in ex and "undercut 1c" in ex, ex)

    # how many
    check(R.quantity(lua.table(keep=20, maxUp=0, stack=0), 50, 0) == 30, "keep 20 of 50: post 30")
    n, why = R.quantity(lua.table(keep=60, maxUp=0, stack=0), 50, 0)
    check(n == 0 and why == "keeping 60 in your bags", f"keep more than you have: {why}")
    check(R.quantity(lua.table(keep=0, maxUp=40, stack=0), 50, 30) == 10, "at most 40 up, 30 up: post 10")
    n, why = R.quantity(lua.table(keep=0, maxUp=40, stack=0), 50, 40)
    check(n == 0 and "at most 40" in why, f"at most 40 up and 40 are: {why}")
    check(R.quantity(lua.table(keep=0, maxUp=0, stack=20), 50, 0) == 20, "posts of at most 20")
    check(R.quantity(lua.table(keep=10, maxUp=100, stack=20), 15, 0) == 5, "keep, max up and stack together")

    # the queue from the bags
    groups = tbl(lua.table(key="2589:0", id=2589, count=40, name="Linen Cloth"),
                 lua.table(key="2592:0", id=2592, count=3, name="Wool Cloth"),
                 lua.table(key="3000:0", id=3000, count=1, name="Old Sword"),
                 lua.table(key="7001:0", id=7001, count=1, name="Lesser Magic Wand"))
    o = lua.table(rules=R.all(db),
                  rowOf=lambda g: ns.queryItemRow(g.id),
                  upOf=lambda g: 0,
                  hidden=lambda g: g.id == 7001)
    entries = R.queue(groups, o)
    names = [entries[k].g.name for k in range(1, len(entries) + 1)]
    check(names == ["Linen Cloth", "Wool Cloth", "Old Sword"], f"in bag order, hidden ones left out: {names}")
    check(entries[1].rule.name == "Cloth" and entries[1].qty == 40, "Linen: Cloth rule, all 40")
    check(entries[2].rule.name == "Wool" and entries[2].qty == 0 and entries[2].why == "keeping 5 in your bags", "Wool: keeps 5, has 3")
    check(entries[3].rule.name == "Everything", "the sword: Everything")
    check(R.nextOpen(entries, 1) == 1 and R.nextOpen(entries, 2) == 3, "the next open entry passes over kept ones")
    entries[3].skipped = "you"
    check(R.nextOpen(entries, 2) == 1, "and skipped ones, wrapping round")
    entries[1].done = True
    check(R.nextOpen(entries, 1) is None, "nothing open: none")

    # cancel undercut: which of your auctions
    lives = {
        1: lua.table(at=1000, lowestOther=95),            # undercut by 5
        2: lua.table(at=1000, lowestOther=60),            # you're the cheapest
        3: lua.table(at=1000, lowestOther=10),            # undercut, but a repost would go under the floor
        4: lua.table(at=900, lowestOther=50),             # undercut by 50, old answer
        5: lua.table(at=1000, lowestOther=80),            # has a bid
        6: lua.table(at=1000, lowestOther=5, lone=True, second=200),   # only a lone bait one is cheaper
        7: lua.table(at=1000, lowestOther=10),            # a stackable good whose own price isn't sure yet
    }
    ow = lambda **kw: lua.table(**kw)
    own = tbl(ow(id=1, itemID=2589, unit=100, qty=1, name="A"), ow(id=2, itemID=2589, unit=50, qty=1, name="B"),
              ow(id=3, itemID=2589, unit=100, qty=1, name="C"), ow(id=4, itemID=2589, unit=100, qty=1, name="D"),
              ow(id=5, itemID=2589, unit=100, qty=1, name="E", hasBid=True), ow(id=6, itemID=2589, unit=100, qty=1, name="F"),
              ow(id=7, itemID=2589, unit=100, qty=1, name="G", commodity=True), ow(id=8, itemID=2589, unit=100, sold=True, name="H"))
    rowC = lua.table(id=2589, sell=13, pcRun=True)
    cl = R.cancelQueue(own, lua.table(live=lambda a: lives.get(a.id), rule=lambda a: R.newRule("Everything"),
                                      row=lambda a: rowC, step=1, undercut=lua.table(copper=1), now=1000,
                                      deposit=lambda a: 5, sure=lambda a: not a.commodity))
    got = [(cl[k].a.name, bool(cl[k].ok)) for k in range(1, len(cl) + 1)]
    check(got == [("D", True), ("A", True), ("C", False), ("E", False)], f"most undercut first, kept ones after: {got}")
    check(cl[2].repost == 94 and cl[2].by == 5 and cl[2].fresh is True, f"A: repost 94c, undercut by 5c ({cl[2].repost})")
    check(cl[1].fresh is False, "D's live price is 100 s old: checked again first")
    check("under your floor, 18c" in cl[3].why, cl[3].why)
    check("bid" in cl[4].why, cl[4].why)
    check(R.cancelLabel(cl[2], 1, 4) == "Cancel A · undercut by 5c (1 of 4)", R.cancelLabel(cl[2], 1, 4))

    # one auction house call per click
    def st(**kw):
        return R.state(lua.table(**kw), 1000)
    fresh, old = lua.table(at=990), lua.table(at=900)
    post_res, skip_res = lua.table(action="post", price=29), lua.table(action="skip")
    check(st() == "check", "no live price: Check price")
    check(st(job=True) == "checking", "a search is out: wait")
    check(st(live=old) == "check" and st(live=old, job=True) == "checking", "a price over a minute old is checked again")
    check(st(live=fresh, result=post_res) == "post", "a fresh price: Post")
    check(st(live=fresh, result=post_res, held=True) == "wait", "the button rests a moment after the queue moved")
    check(st(live=fresh, result=skip_res) == "skip", "the rule doesn't post it")
    check(st(posting=True, live=fresh, result=post_res) == "posting" and st(warned=True) == "confirm" and st(done=True) == "done",
          "posting, confirm, done")
    calls = {s_: R.clickCall(s_) for s_ in ("check", "checking", "post", "wait", "skip", "posting", "confirm", "done")}
    check(calls == {"check": "search", "checking": None, "post": "post", "wait": None, "skip": None, "posting": None,
                    "confirm": "confirm", "done": None}, f"each click makes at most one call: {calls}")
    check(R.clickCall("post", True) == "cancel", "in Cancel undercut the click cancels")
    label = R.postLabel(lua.table(qty=20, g=lua.table(name="Linen Cloth")), 1200, 3, 14)
    check(label == "Post 20 Linen Cloth · 1200c each (3 of 14)", label)

    # the view's click, over a fake Quick sell: check price, then post, never both in one click
    lua.execute("""
      MOCK_CALLS = { search = 0, post = 0 }
      C_AuctionHouse = { CalculateCommodityDeposit = function(_, _, q) return 20 * q end }
      function C_Timer.After(_, fn) end
    """)
    G = lua.globals()
    core = lua.eval("""function(ns)
      local S = { owned = {}, ownedLoaded = true, groups = { { key = "2589:0", id = 2589, count = 40, name = "Linen Cloth" } } }
      local Live = { cache = {}, byId = {}, jobs = {}, failed = {} }
      local s = { memory = {}, hidden = {}, fav = {} }
      ns.sellCore = {
        S = S, Live = Live, collect = function() end, sdb = function() return s end,
        prepare = function(g) g.itemKey = { itemID = g.id }; g.ckey = g.id .. ":0:0"; g.commodity = true end,
        liveFor = function(c) return c and Live.cache[c] or nil end,
        request = function(k) MOCK_CALLS.search = MOCK_CALLS.search + 1; Live.jobs[k.itemID .. ":0:0"] = true end,
        priceStep = function() return 1 end, undercut = function() return { copper = 1 } end,
        locate = function() return "loc" end, available = function(g) return g.count end,
        postJob = function(g, loc, qty, unit, dur, extra)
          MOCK_CALLS.post = MOCK_CALLS.post + 1
          MOCK_CALLS.last = { qty = qty, unit = unit }
          S.posting = { entry = extra.entry, qty = qty, unit = unit }
          return S.posting
        end,
        setStatus = function() end, qualityHex = function() return "" end, queryOwned = function() end,
      }
      return S, Live
    end""")
    S, Live = core(ns)
    run(source_of("SellAll.lua"), "SellAll.lua", "EverlookDBAuctions", ns)
    A = ns.sellAll
    R.store(db).list[1].keep = 0
    A.build()
    check(A.current() is not None and A.current().g.name == "Linen Cloth", "the queue starts at Linen Cloth")
    check(A.click() == "search" and G.MOCK_CALLS.search == 1 and G.MOCK_CALLS.post == 0, "first click: one price check, no post")
    check(A.click() is None and G.MOCK_CALLS.search == 1, "while it is out a click does nothing")
    Live.jobs["2589:0:0"] = None
    Live.cache["2589:0:0"] = lua.table(at=1000, lowestOther=40)
    check(A.click() == "post" and G.MOCK_CALLS.post == 1 and G.MOCK_CALLS.search == 1, "next click: one post, no search")
    check(G.MOCK_CALLS.last is not None and G.MOCK_CALLS.last.unit == 39 and G.MOCK_CALLS.last.qty == 40,
          f"posted 40 at 39c: {G.MOCK_CALLS.last and G.MOCK_CALLS.last.unit}")
    check(A.click() is None and G.MOCK_CALLS.post == 1, "while the post is out a click does nothing")
    S.posting = None
    Live.cache["2589:0:0"] = lua.table(at=1000, lowestOther=15)
    A.build()
    st_, _res = A.stateOf(A.current())
    check(st_ == "skip", f"14c would be under the 33c floor (13c vendor + 20c deposit): the rule skips it ({st_})")
    Live.cache["2589:0:0"] = lua.table(at=900, lowestOther=40)
    check(A.click() == "search" and G.MOCK_CALLS.post == 1, "a stale price: the click checks, it doesn't post")

    # the Sell rules page in the settings window, and its settings as commands
    lua = lua51.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(source_of("tests/mock.lua"))
    lua.execute("""
        CHAT = {}
        DEFAULT_CHAT_FRAME = { AddMessage = function(_, m) CHAT[#CHAT + 1] = m end }
        STANDARD_TEXT_FONT = "font"
        wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
    """)
    run = lua.eval("function(src, name, ...) local f = assert(loadstring(src, name)); return f(...) end")
    for lib in ("Libs/LibStub/LibStub.lua", "Libs/EverlookUI/EverlookUI.lua"):
        run(source_of(lib), lib)
    ns = lua.table()
    db = run(VENDOR_SETUP, "setup", ns)
    for name in ["Skin.lua", "Vendor.lua", "Search.lua", "SellRules.lua", "SellAll.lua"]:
        run(source_of(name), name, "EverlookDBAuctions", ns)
    ns.sellSettings = lua.eval("function() local t = {}; return function() return t end end")()
    ns.undercutShort = lua.eval("function() return '1s' end")
    ns.setUndercut = lua.eval("function() return true end")
    ns.tipOn = lua.eval("function() return true end")
    run(source_of("Options.lua"), "Options.lua", "EverlookDBAuctions", ns)
    fire = lua.eval("function(e, a) for _, f in ipairs(MOCK_FRAMES) do if f.scripts.OnEvent then pcall(f.scripts.OnEvent, f, e, a) end end end")
    fire("ADDON_LOADED", "EverlookDBAuctions")
    check(ns.optionsError is None, f"the settings window builds: {ns.optionsError}")
    app = ns.app
    check(app.sections.sellrules is not None, "a Sell rules page")
    built = lua.eval("""function(app)
      local okB, err = pcall(app.BuildSection, app, "sellrules")
      return okB, tostring(err)
    end""")(app)
    check(built[0], f"the Sell rules page builds: {built[1]}")
    base = ns.sellRules.all(db)[1]
    check(ns.slash("rulefloor 80% of median") is True and base.floor == "80% of median", f"/eah rulefloor sets the edited rule's floor: {base.floor}")
    ns.slash("rulefloor max(vendor,")
    check(base.floor == "80% of median", "a floor that can't be read isn't saved")
    ns.slash("rulesearch name has cloth")
    check(base.query == "", "Everything keeps covering every item")
    ns.slash("rulekeep 20")
    check(base.keep == 20, f"keep 20: {base.keep}")
    ns.slash("rulebelow floor")
    check(base.below == "floor", f"under the floor: post at the floor ({base.below})")
    return failures


def deals_list():
    """Deals (Deals.lua): each kind of deal (under a share of the usual price, below vendor, below disenchant value, a
    shopping list's max, the player's own Deal searches with formulas), the order by profit times how sure, the
    unsure filter, the Look again state machine, and deals bought or gone dropping off until a newer scan."""
    lua = lua51.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(source_of("tests/mock.lua"))
    ns = lua.table()
    run = lua.eval("function(src, name, ...) local f = assert(loadstring(src, name)); return f(...) end")
    run(VENDOR_SETUP, "setup", ns)
    for name in ["Skin.lua", "Vendor.lua", "Search.lua", "Deals.lua"]:
        run(source_of(name), name, "EverlookDBAuctions", ns)
    D = ns.deals
    failures = []

    def check(cond, what):
        if not cond:
            failures.append("deals list: " + what)

    def days(*prices):
        return lua.table_from({100 - i: p for i, p in enumerate(prices)})

    steady = days(*([100] * 30))
    hist = {}
    rows = []

    def row(**kw):
        t = lua.table(**kw)
        rows.append(t)
        return t

    # cheap: 40c with a steady usual 100c over 30 days (5 auctions up): 40% of usual, sure
    row(key="1:0", id=1, name="Cheap Cloth", price=40, median=90, qty=5, auctions=5, stack=1, sell=0)
    hist[1] = steady
    # not cheap: 70c against 100c
    row(key="2:0", id=2, name="Fair Cloth", price=70, median=100, qty=5, auctions=5, stack=1, sell=0)
    hist[2] = steady
    # no history: the scan's own middle price only, so unsure (left out unless shown)
    row(key="3:0", id=3, name="New Thing", price=30, median=100, qty=1, auctions=1, stack=1, sell=0)
    # below vendor from the scan's single auctions: 3 at 100c, vendor 500c: 1200c
    row(key="4:0", id=4, name="Old Sword", price=100, median=150, qty=3, auctions=1, stack=1, sell=500, dealText="100:3")
    # below disenchant value: gear at 2000c that disenchants for 5000c: 5000 * 0.95 - 2000
    row(key="5:0", id=5, name="Green Ring", quality="uncommon", price=2000, median=2600, qty=1, auctions=1, stack=1, sell=0)
    # a shopping list's max: 200c each against a max of 300c, 5 still wanted
    row(key="6:0", id=6, name="Peacebloom", price=200, median=210, qty=10, auctions=4, stack=20, sell=0)
    # a jumpy history: never sure
    row(key="7:0", id=7, name="Jumpy Gem", price=300, median=900, qty=2, auctions=2, stack=1, sell=0)
    hist[7] = days(100, 2000, 300, 1500, 900, 1200)
    # a quest item and a bids-only row never count
    row(key="8:0", id=8, name="Quest Thing", price=1, median=100, qty=1, auctions=1, stack=1, sell=50, quest=True)
    row(key="9:0", id=9, name="Bids Only", median=100, qty=1, auctions=1, stack=1, sell=50)
    hist[8] = steady
    hist[9] = steady
    lrows = lua.table_from(rows)
    shop = lua.table_from([lua.table(name="Herbs", rows=lua.table_from({"6:0": lua.table(max=300, need=5)}))])
    searches = lua.table_from([lua.table(name='"rings"', keys=lua.table_from({"5:0": True}))])
    base = dict(pct=60, min=10, cut=0.05, today=100, days=lambda _id: hist.get(_id),
                devalue=lambda _id: 5000 if _id == 5 else None, shop=shop, searches=searches)

    def build(**over):
        o = dict(base)
        o.update(over)
        lst, hidden = D.build(lrows, lua.table(**o))
        return [lst[i] for i in range(1, len(lst) + 1)], hidden

    def kinds(d):
        return [d.reasons[i].kind for i in range(1, len(d.reasons) + 1)]

    lst, hidden = build()
    by = {d.key: d for d in lst}
    c1 = by.get("1:0")
    check(c1 is not None and kinds(c1) == ["cheap"] and c1.reasons[1].text == "40% of usual", "cheap: 40% of usual")
    check(c1 is not None and c1.sure == "sure" and c1.profit == 55 and c1.limit == 60,
          f"cheap: sure, 100 * 0.95 - 40 profit, at most 60c to still count: {c1 and (c1.sure, c1.profit, c1.limit)}")
    check("2:0" not in by, "70% of usual is no deal at 60%")
    check("3:0" not in by and hidden >= 1, f"no history: unsure, left out ({hidden} hidden)")
    d4 = by.get("4:0")
    check(d4 is not None and kinds(d4) == ["vendor"] and d4.profit == 1200 and d4.reasons[1].text == "vendor pays 400c more",
          f"below vendor: {d4 and d4.reasons[1].text}")
    d5 = by.get("5:0")
    check(d5 is not None and "de" in kinds(d5) and d5.profit == 2750, f"below disenchant value: {d5 and (kinds(d5), d5.profit)}")
    check(d5 is not None and any(d5.reasons[i].text == "disenchants for 5000c" for i in range(1, len(d5.reasons) + 1)),
          "why: disenchants for 5000c")
    check(d5 is not None and "search" in kinds(d5), "your own search found it too: both reasons kept")
    d6 = by.get("6:0")
    check(d6 is not None and kinds(d6) == ["shop"] and d6.profit == 500 and d6.reasons[1].text == "under your max of 300c (Herbs)",
          f"shopping list max: {d6 and (kinds(d6), d6.profit, d6.reasons[1].text)}")
    check("7:0" not in by or by["7:0"].sure != "sure", "a jumpy usual price is never sure")
    check("8:0" not in by and "9:0" not in by, "quest items and bids-only rows never count")
    # the order: profit times how sure (disenchant 2750 * 0.6 = 1650, vendor 1200 * 1, herbs 500 * 1)
    order = [d.key for d in lst]
    check(order[:3] == ["5:0", "4:0", "6:0"], f"best first: {order}")
    check(d5 is not None and D.whyText(d5).count(" · ") == 1, f"why joins the reasons: {d5 and D.whyText(d5)}")

    # unsure deals on request; the share; the smallest profit; gone ones; kinds off; your own auctions up
    lst, hidden = build(unsure=True)
    keys = [d.key for d in lst]
    check("3:0" in keys and hidden == 0, f"unsure shown on request: {keys}")
    check(any(d.key == "3:0" and d.sure == "unsure" for d in lst), "and marked unsure")
    lst, _ = build(pct=30)
    check("1:0" not in [d.key for d in lst], "at 30% the 40% cloth is no deal")
    lst, _ = build(min=60)
    check("1:0" not in [d.key for d in lst], "a 55c profit is under a 60c minimum")
    lst, _ = build(gone=lua.table_from({"4:0": True}))
    check("4:0" not in [d.key for d in lst], "a deal bought or gone is left out")
    lst, _ = build(vendor=False, de=False, shop=False, searches=lua.table())
    check([d.key for d in lst] == ["1:0"], f"kinds switched off: {[d.key for d in lst]}")
    lst, _ = build(listed=lambda _id: 2 if _id == 1 else 0, unsure=True)
    mine = [d for d in lst if d.key == "1:0"]
    check(mine and mine[0].sure != "sure" and mine[0].yours, f"yours up too: less sure ({mine and mine[0].sure})")

    # how sure: days, steadiness, auctions
    check(D.sureText(D.confidence(30, 1, 5)) == "sure", "30 steady days, 5 up: sure")
    check(D.sureText(D.confidence(3, 0.3, 1)) == "unsure", "3 jumpy days, 1 up: unsure")
    check(D.sureText(D.confidence(0, 0, 50)) == "unsure", "no history: never more than unsure")
    usual, n, _st = D.usualOf(days(10, 20, 30, 40, 50), 100)
    check(usual == 30 and n == 5, f"usual: the middle daily low: {usual}, {n}")
    check(D.usualOf(days(10, 20), 100)[0] is None, "two days: no usual price")
    check(D.countText(0) is None and D.countText(1) == "1 deal" and D.countText(4) == "4 deals", "the quiet line")

    # Deal searches: names, formulas, mistakes refused
    s = D.searchesOf("wands = type has wand and price lt 90% of median; name has cloth")
    check(len(s) == 2 and s[1].name == "wands" and s[2].name == "name has cloth", "named and unnamed searches")
    okC, why = D.checkSearches("bad = price lt 60% median")
    check(okC is False and "bad:" in why and "of what" in why, f"a broken search is refused in plain words: {why}")
    check(D.checkSearches("cheap = price lt 50% of median30 and quality ge rare") is True, "a formula search is fine")

    # over the scan (VENDOR_SETUP): a saved search with a formula; Advanced search's own state is left alone
    db = ns.db()
    db.dealSearches = "wands = type has wand and price lt 90% of median"
    ns.queryRun("belowvendor")
    before = ns.queryOrdered()
    D.compute()
    got = sorted(D.list[i].name for i in range(1, len(D.list) + 1))
    check(got == ["Lesser Magic Wand", "Sort Wand"], f"wands at 86% and 80% of median, not the one at 90%: {got}")
    check(all(D.list[i].reasons[1].kind == "search" and D.list[i].reasons[1].text == 'your search "wands"'
              for i in range(1, len(D.list) + 1)), "why: your search")
    check(ns.queryOrdered() == before, "Advanced search's state is untouched")

    # a shopping list with a formula max, over the scan: Linen 10c, a max of 90% of median (12c): 10c still counts
    q = 'name is "Linen Cloth"'
    db.lists = lua.table_from([lua.table(name="Cloth", queries=lua.table_from([q]), want=lua.table_from({q: 40}),
                                         max=lua.table_from({q: "90% of median"}))])
    D.compute()
    lin = [D.list[i] for i in range(1, len(D.list) + 1) if D.list[i].name == "Linen Cloth"]
    check(lin and lin[0].reasons[1].kind == "shop" and lin[0].limit == 10, f"a formula max from a list: {lin and lin[0].limit}")
    db.lists = None

    # Look again: one search per click, then found / gone / no answer
    sent = []
    holder = {}

    def look(row, cb):
        sent.append(row.key)
        holder["cb"] = cb
        return True
    D.lookFn = look
    ah = {"open": True}
    D.ahOpen = lambda: ah["open"]

    def deal(key, name, price, limit):
        return lua.table(key=key, id=1, name=name, price=price, limit=limit, reasons=lua.table(), row=lua.table(key=key))
    D.list = lua.table_from([deal("a", "Silk", 100, 150), deal("b", "Wool", 50, 60)])
    D.look = lua.table(state="idle")
    label, usable = D.buttonState()
    check(label == "Look again: Silk" and usable, f"the button names the top deal: {label}")
    check(D.click() is True and sent == ["a"] and D.look.state == "looking", "one click: one search for the top deal")
    check(D.click() is False and sent == ["a"], "clicks while it looks send nothing more")
    label, usable = D.buttonState()
    check(label.startswith("Looking") and not usable, f"button while looking: {label}")
    check(D.onLive("b", lua.table(), True, False) is None, "an answer for another deal is ignored")
    live = lua.table_from([lua.table(unit=90, buyout=90, qty=1, mine=True), lua.table(unit=120, buyout=120, qty=1),
                           lua.table(unit=140, buyout=140, qty=1)])
    pick = holder["cb"](live, True, False)
    check(pick is not None and pick.unit == 120 and D.look.state == "found", "found: the cheapest from someone else, not yours")
    check("Still there at 120c" in (D.look.text or ""), f"says so: {D.look.text}")
    check(len(D.list) == 2 and D.list[1].checkedAt is not None, "a found deal stays, marked checked")
    D.onBuyClosed()
    check(D.look.state == "idle", "the buy panel closed: ready for the next click")
    # gone: nothing at most at its price: dropped, the next one is the top now
    D.click()
    r = holder["cb"](lua.table_from([lua.table(unit=400, buyout=400, qty=1)]), True, False)
    check(r == "gone" and D.look.state == "gone" and len(D.list) == 1 and D.list[1].key == "b", "gone: dropped from the list")
    check("cheapest is 400c now" in (D.look.text or ""), f"gone says the price now: {D.look.text}")
    check(D.gone["a"] is not None, "kept as gone")
    check(D.buttonState() == ("Look again: Wool", True), "the next deal is up")
    # no answer: nothing dropped, the next click asks again
    D.click()
    check(holder["cb"](None, False, False) == "noanswer" and len(D.list) == 1 and D.look.state == "noanswer", "no answer: kept")
    check(D.click() is True and sent == ["a", "a", "b", "b"], f"asks again on the next click: {sent}")
    # stackable goods: how many from others at most at the deal's price
    goods = lua.table_from([lua.table(unit=55, qty=10, others=4), lua.table(unit=58, qty=3, others=3),
                            lua.table(unit=70, qty=9, others=9)])
    pick = holder["cb"](goods, True, True)
    check(pick.qty == 7 and pick.cost == 4 * 55 + 3 * 58 and pick.unit == 55, f"goods under the price: {pick.qty}")
    D.onBought("b")
    check(len(D.list) == 0 and D.look.state == "bought" and "Bought Wool" in D.look.text, "bought: dropped")
    check(D.buttonState()[1] is False, "nothing left: the button can't be clicked")
    # away from the auction house: nothing is sent
    D.list = lua.table_from([deal("c", "Thing", 1, 2), deal("d", "Other", 1, 2)])
    D.look = lua.table(state="idle")
    ah["open"] = False
    n = len(sent)
    check(D.click() is False and len(sent) == n, "away: nothing sent")
    ah["open"] = True
    # a clicked row is the one Look again checks
    D.look = lua.table(state="idle")
    D.sel = "d"
    D.click()
    check(sent[-1] == "d", "a picked row is checked first")
    D.sel = None
    D.look = lua.table(state="idle")

    # gone ones stay off over a recompute of the same scan, and come back with a newer one
    D.compute()
    check(len(D.list) >= 1, "the wands again")
    first = D.list[1].key
    D.drop(first)
    D.compute()
    check(first not in [D.list[i].key for i in range(1, len(D.list) + 1)], "dropped stays off for this scan")
    check(db.dealsGone[first] is not None, "and is saved over a reload")
    db.scans[1].at = 5
    ns.queryFresh()
    D.compute()
    check(first in [D.list[i].key for i in range(1, len(D.list) + 1)], "a newer scan brings it back")
    db.dealSearches = None

    # the Deals settings page and the Deals page of the main window build, and the settings work as commands
    lua = lua51.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(source_of("tests/mock.lua"))
    lua.execute("""
        CHAT = {}
        DEFAULT_CHAT_FRAME = { AddMessage = function(_, m) CHAT[#CHAT + 1] = m end }
        STANDARD_TEXT_FONT = "font"
        wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
    """)
    run = lua.eval("function(src, name, ...) local f = assert(loadstring(src, name)); return f(...) end")
    for lib in ("Libs/LibStub/LibStub.lua", "Libs/EverlookUI/EverlookUI.lua"):
        run(source_of(lib), lib)
    ns = lua.table()
    db = run(VENDOR_SETUP, "setup", ns)
    for name in ["Skin.lua", "Vendor.lua", "Search.lua", "Deals.lua"]:
        run(source_of(name), name, "EverlookDBAuctions", ns)
    ns.parseMoney = lua.eval("""function(text)
      local total, any = 0, false
      for n, unit in text:gmatch("(%d+)%s*([gsc])") do
        total = total + tonumber(n) * (unit == "g" and 10000 or unit == "s" and 100 or 1); any = true
      end
      return any and total or nil
    end""")
    ns.sellSettings = lua.eval("function() local t = {}; return function() return t end end")()
    ns.undercutShort = lua.eval("function() return '1s' end")
    ns.setUndercut = lua.eval("function() return true end")
    ns.tipOn = lua.eval("function() return true end")
    run(source_of("Options.lua"), "Options.lua", "EverlookDBAuctions", ns)
    fire = lua.eval("function(e, a) for _, f in ipairs(MOCK_FRAMES) do if f.scripts.OnEvent then pcall(f.scripts.OnEvent, f, e, a) end end end")
    fire("ADDON_LOADED", "EverlookDBAuctions")
    check(ns.optionsError is None, f"the settings window builds: {ns.optionsError}")
    app = ns.app
    ns.deals.page(app, lua.eval('LibStub("EverlookUI-1")'))
    build_page = lua.eval("""function(app, id)
      local okB, err = pcall(app.BuildSection, app, id)
      return okB, tostring(err)
    end""")
    for page_id in ("dealsettings", "deals"):
        built = build_page(app, page_id)
        check(built[0], f"the {page_id} page builds: {built[1]}")
    ns.slash("dealpct 50")
    check(db.dealPct == 50 and ns.deals.settings().pct == 50, f"/eah dealpct 50: {db.dealPct}")
    ns.slash("dealmin 1g")
    check(db.dealMin == 10000, f"/eah dealmin 1g: {db.dealMin}")
    ns.slash("dealsearches cheap = price lt 60% median")
    check(db.dealSearches is None, "a broken deal search isn't saved")
    ns.slash("dealsearches cheap = price lt 50% of median30 and quality ge rare")
    check(db.dealSearches == "cheap = price lt 50% of median30 and quality ge rare", f"a deal search is saved: {db.dealSearches}")
    check(ns.deals.settings().sound is False, "no sound by default")
    return failures


def no_freeze():
    """Work that goes through a whole scan runs a slice per frame instead of stopping the game: the scan's rows for
    Deals (kept while items still load, and only those tried again), the Deals list (a newer round replaces a running
    one), and the end of a price update (the auctions without a link, the rows, the packing of the older scan), also
    when the auction house closes during it. Sliced or in one go, the result is the same."""
    failures = []

    def check(cond, what):
        if not cond:
            failures.append("no freeze: " + what)

    QUEUE = """
        QUEUE, FRAMES = {}, 0
        C_Timer = { After = function(_, fn) QUEUE[#QUEUE + 1] = fn end }
        function FRAME()   -- one frame: every timer waiting now
          local q = QUEUE
          QUEUE = {}
          for _, fn in ipairs(q) do fn() end
          if #q > 0 then FRAMES = FRAMES + 1 end
          return #QUEUE
        end
        function DRAIN() while FRAME() > 0 do end end
    """

    def start(*names):
        lua = lua51.LuaRuntime(unpack_returned_tuples=True)
        lua.execute(source_of("tests/mock.lua"))
        ns = lua.table()
        run = lua.eval("function(src, name, ...) local f = assert(loadstring(src, name)); return f(...) end")
        db = run(VENDOR_SETUP, "setup", ns)
        for name in names:
            run(source_of(name), name, "EverlookDBAuctions", ns)
        return lua, ns, db

    # the scan's rows stay kept while an item is still loading; only that item is tried again
    lua, ns, db = start("Skin.lua", "Vendor.lua", "Search.lua")
    G = lua.globals()
    same = lua.eval("rawequal")
    db.scans[1].rows["424242:0"] = "7,7,7,1,1"
    lua.execute("ASKED = 0; C_Item.GetItemInfo = function(id) ASKED = ASKED + 1; return nil end")
    rows, sc, missing = ns.queryDataset()
    check(len(rows) == 9 and missing == 1, f"9 rows, one item still loading: {len(rows)}, {missing}")
    asked = G.ASKED
    rows2, _sc, missing2 = ns.queryDataset()
    check(same(rows, rows2) and missing2 == 1, "the rows are kept while an item is loading")
    check(G.ASKED - asked == 1, f"only the missing item is asked for again: {G.ASKED - asked}")
    lua.execute("C_Item.GetItemInfo = function(id) if id == 424242 then return 'Late Thing', nil, 1, 5, 0, 'Trade Goods', 'Cloth', 20, '', 9, 3 end end")
    rows3, _sc, missing3 = ns.queryDataset()
    names = [rows3[i].name for i in range(1, len(rows3) + 1)]
    check(same(rows, rows3) and missing3 == 0 and len(rows3) == 10 and names[-1] == "Late Thing",
          f"once it loads it joins the rows: {missing3}, {names}")
    found = ns.queryRun('name is "Late Thing"')[0]
    check(found is not None and len(found) == 1 and found[1].price == 7, "and searches find it")

    # the rows read a slice per frame: the same rows as in one go, kept for the next search
    lua, ns, db = start("Skin.lua", "Vendor.lua", "Search.lua")
    G = lua.globals()
    lua.execute(QUEUE)
    ns.querySliceRows(2)
    got = {}
    ns.queryDatasetSliced(lambda rows, sc, missing: got.update(rows=rows, sc=sc, missing=missing))
    check("rows" not in got and len(G.QUEUE) == 1, "9 rows at 2 a frame: not done in the first frame")
    G.DRAIN()
    check("rows" in got and len(got["rows"]) == 9 and got["missing"] == 0, "done some frames later")
    check(G.FRAMES == 4, f"5 slices: the first at once, then 4 frames ({G.FRAMES})")
    whole = ns.queryDataset()
    check(lua.eval("rawequal")(whole[0], got["rows"]), "kept: a search reads the same rows")
    keys = sorted(got["rows"][i].key for i in range(1, 10))
    check(keys == sorted(db.scans[1].rows.keys()), f"every row once: {keys}")
    # a search in the middle reads them in one go; the sliced read hands over those rows
    lua, ns, db = start("Skin.lua", "Vendor.lua", "Search.lua")
    lua.execute(QUEUE)
    ns.querySliceRows(2)
    got = {}
    ns.queryDatasetSliced(lambda rows, sc, missing: got.update(rows=rows))
    whole = ns.queryDataset()
    lua.globals().DRAIN()
    check(lua.eval("rawequal")(whole[0], got.get("rows")), "a search meanwhile: both have the same rows")
    # nothing to read: done at once with nothing
    db.scans = lua.table()
    got = {}
    ns.queryDatasetSliced(lambda rows=None, *a: got.update(rows=rows))
    check("rows" in got and got["rows"] is None, "no scan: done at once, no rows")

    # Deals: the list worked out a slice per frame is the list worked out in one go
    lua, ns, db = start("Skin.lua", "Vendor.lua", "Search.lua", "Deals.lua")
    G = lua.globals()
    D = ns.deals
    SEARCH = "wands = type has wand and price lt 90% of median; cloth = name has cloth"
    db.dealSearches = SEARCH
    D.compute()   # in one go (the game's timers run at once here)
    want = [(D.list[i].key, D.list[i].profit, D.list[i].sure) for i in range(1, len(D.list) + 1)]
    check(len(want) > 0, "the scan has deals")
    lua, ns, db = start("Skin.lua", "Vendor.lua", "Search.lua", "Deals.lua")
    G = lua.globals()
    lua.execute(QUEUE)
    D = ns.deals
    db.dealSearches = SEARCH
    D.SLICE_ROWS = 2
    ns.querySliceRows(2)
    lua.execute("CHANGED = 0")
    D.onChange(lua.eval("function() CHANGED = CHANGED + 1 end"))
    D.compute()
    check(len(D.list) == 0 and G.CHANGED == 0 and len(G.QUEUE) == 1, "nothing shows until every row is looked at")
    G.FRAME()
    D.compute()   # a newer round while the first still runs
    G.DRAIN()
    got = [(D.list[i].key, D.list[i].profit, D.list[i].sure) for i in range(1, len(D.list) + 1)]
    check(got == want, f"the same deals, sliced: {got} vs {want}")
    check(G.CHANGED == 1, f"the round that was replaced never shows: {G.CHANGED}")
    check(G.FRAMES >= 5, f"over several frames: {G.FRAMES}")
    # the builder: a step looks at no more rows than asked, and stops when the frame's time is used up
    rows = ns.queryDataset()[0]
    step = D.builder(rows, lua.table())
    check(step(4) is False, "4 of 9 rows: not done")
    check(step(4) is False, "8 of 9 rows: not done")
    done, lst, hidden = step(4)
    check(done is True and lst is not None, "the last row: done, with the list")
    one, _hid = D.build(rows, lua.table())
    check([lst[i].key for i in range(1, len(lst) + 1)] == [one[i].key for i in range(1, len(one) + 1)], "the same list as D.build")
    step = D.builder(rows, lua.table())
    lua.execute("LOOKS = 0")
    over = lua.eval("function() LOOKS = LOOKS + 1; return true end")
    check(step(None, over) is False and G.LOOKS == 1, "time used up after 8 rows: the step ends there")
    check(step(None, over)[0] is True, "and the next step finishes")

    # a price update with a clock that says every slice's time is used up: more frames, the same scan
    def scan_rows(extra, close):
        lua, ns, fire = scan_lua(extra + """
            -- the house's previous scan, to be packed when this one is stored
            EverlookAuctionsDB.scans = { { realm = "Test", side = "Alliance", at = MOCK_TIME - 3600,
              rows = { ["1:0"] = "1,1,1,1,1,0,0,0,0,0,1,", ["2:0"] = "2,2,2,1,1,0,0,0,0,0,1," } } }
            STEPS = 0
            local After = C_Timer.After
            C_Timer.After = function(secs, fn) After(secs, function() STEPS = STEPS + 1; fn() end) end
        """)
        G = lua.globals()
        G.ADVANCE(1)
        G.SlashCmdList.EVERLOOKAUCTIONS("scan")
        fire("REPLICATE_ITEM_LIST_UPDATE")
        G.ADVANCE(1)
        scanning = None
        if close:
            fire("AUCTION_HOUSE_CLOSED")
            scanning = ns.scanning()
        G.ADVANCE(30)
        db = G.EverlookAuctionsDB
        new = db.scans[len(db.scans)]
        rows = {k: v for k, v in new.rows.items()} if new.rows else None
        return rows, new.noLink, db.scans[1], G.STEPS, ns.scanning(), scanning, db.houses["Test-Alliance"]

    CLOCK = "local t = 0; debugprofilestop = function() t = t + 100; return t end\n"
    for close in (False, True):
        plain = scan_rows("", close)
        timed = scan_rows(CLOCK, close)
        tag = "closed during it" if close else "open all along"
        check(plain[0] is not None and timed[0] == plain[0] and timed[1] == plain[1],
              f"{tag}: the same rows with a clock ({timed[1]} vs {plain[1]} without a link)")
        check(timed[3] > plain[3] + 20, f"{tag}: the clock ends slices early, so more frames ({timed[3]} vs {plain[3]})")
        check(not timed[4] and not plain[4], f"{tag}: both finish")
        for which, r in (("without", plain), ("with", timed)):
            old = r[2]
            check(old.rows is None and old.packed == "1:0=1,1,1,1,1,0,0,0,0,0,1,\n2:0=2,2,2,1,1,0,0,0,0,0,1," and old.nrows == 2,
                  f"{tag}, {which} a clock: the older scan is packed as before")
            check(r[6].scanned is not None and r[6]["items"][1] is not None, f"{tag}, {which} a clock: tooltip prices saved")
    check(timed[5] is True, "closing the auction house doesn't finish the update inside the event: it goes on a slice per frame")
    return failures


def deals_buy():
    """Look again through the buy panel (Buy.lua): one search per click, the auction still there is picked, Buy then
    Confirm buys it once, the deal drops off and the panel goes back to the Deals without searching again; a gone one
    closes the panel at once."""
    lua = lua51.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(source_of("tests/mock.lua"))
    ns = lua.table()
    run = lua.eval("function(src, name, ...) local f = assert(loadstring(src, name)); return f(...) end")
    run(VENDOR_SETUP, "setup", ns)
    lua.execute(BUY_SETUP)
    run(AHQ_FAKE, "ahq", ns)
    for name in ["Skin.lua", "Vendor.lua", "Buy.lua"]:
        run(source_of(name), name, "EverlookDBAuctions", ns)
    G = lua.globals()
    ev = G.MOCK_FRAMES[len(G.MOCK_FRAMES)]   # Buy.lua's event frame
    run(source_of("Deals.lua"), "Deals.lua", "EverlookDBAuctions", ns)
    ns.calmSecs = 0
    D = ns.deals
    D.ahOpen = lua.eval("function() return true end")
    tbl = lua.eval("function(...) return { ... } end")
    browse_answer = lua.eval("function(id) return { ok = true, full = true, entries = { { itemKey = { itemID = id } } } } end")
    failures = []

    def check(cond, what):
        if not cond:
            failures.append("deals buy: " + what)

    browses = {"n": 0}
    orig = ns.ahq.browse

    def counted(*a):
        browses["n"] += 1
        return orig(*a)
    ns.ahq.browse = counted

    def answer(item_id):
        G.AHQ.browse(browse_answer(item_id))
        G.AHQ["items"](G.AHQ.key, True, True)

    def calls(name):
        return [G.CALLS[i] for i in range(1, len(G.CALLS) + 1) if G.CALLS[i][1] == name]

    def click(button):
        button.scripts.OnClick(button)

    sword = lua.table(key="3000:0", id=3000, suffix=0, name="Old Sword", quality="uncommon")

    def sword_deal():
        reason = lua.table(kind="vendor", text="vendor pays 200c more", profit=200, conf=1, limit=400)
        return tbl(lua.table(key="3000:0", id=3000, name="Old Sword", price=300, limit=400, reasons=tbl(reason), row=sword))
    D.list = sword_deal()
    D.look = lua.table(state="idle")
    G.ITEMS = tbl(lua.table(auctionID=1, buyoutAmount=350, quantity=1, containsOwnerItem=False, timeLeft=3),
                  lua.table(auctionID=2, buyoutAmount=900, quantity=1, containsOwnerItem=False, timeLeft=3))
    check(D.click() is True and browses["n"] == 1, "one click, one search")
    f = G.EverlookAuctionsQueryResults.children[1]
    answer(3000)
    check(D.look.state == "found", f"still there: {D.look.state}")
    check("Still there" in f.status.text, f"the panel says so: {f.status.text}")
    click(f.buy)
    check(len(calls("PlaceBid")) == 0 and f.buy.text.startswith("Confirm"), f"Buy arms Confirm; nothing bought yet ({f.buy.text})")
    click(f.buy)
    bids = calls("PlaceBid")
    check(len(bids) == 1 and bids[0][2] == 1 and bids[0][3] == 350, f"Confirm buys the picked auction once: {len(bids)}")
    ev.scripts.OnEvent(ev, "AUCTION_HOUSE_PURCHASE_COMPLETED", 1)
    G.advance(2)
    check(len(D.list) == 0 and D.look.state == "bought", f"bought: off the Deals list ({D.look.state})")
    check(not f.shown and browses["n"] == 1, f"back to the Deals, no search by itself ({browses['n']})")

    # gone: the panel closes at once and the deal drops
    D.list = sword_deal()
    D.look = lua.table(state="idle")
    G.ITEMS = tbl(lua.table(auctionID=3, buyoutAmount=800, quantity=1, containsOwnerItem=False, timeLeft=3))
    D.click()
    answer(3000)
    check(D.look.state == "gone" and len(D.list) == 0 and not f.shown, f"gone: dropped and closed ({D.look.state})")
    check(browses["n"] == 2, "still one search per click")
    return failures


def gold():
    """The Gold page (Gold.lua): one gold point per character per day, the chart's series (carried forward, totals,
    ranges, thinning), this week and last week from the ledger (sales before the cut, the cut a cost), best sellers,
    biggest buys, flips, the listings' worth, CSV, the new merchant and trainer costs (LedgerWatch.lua), and the page
    building in the main window."""
    failures = []

    def check(cond, what):
        if not cond:
            failures.append("gold: " + what)

    lua = lua51.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(source_of("tests/mock.lua"))
    lua.execute("""
      date = os.date
      NOW = os.time({ year = 2026, month = 11, day = 25, hour = 15, min = 0, sec = 0 })   -- a Wednesday
      function time(t) if t then return os.time(t) end return NOW end
      GetTime = function() return NOW end
      SECRET = {}
      issecretvalue = function(v) return v == SECRET end
      MOCK_MONEY = 123456; GetMoney = function() return MOCK_MONEY end
      UnitName = function() return 'Mara' end
      UnitGUID = function() return 'Player-1-0000AAAA' end
      INV = { chars = {
        ['Mara-1'] = { name = 'Mara', realmID = 1, faction = 'Alliance', class = 'MAGE' },
        ['Tok-1'] = { name = 'Tok', realmID = 1, faction = 'Alliance', class = 'WARRIOR' },
        ['Far-2'] = { name = 'Far', realmID = 2, faction = 'Horde' } } }
    """)
    ns = lua.table()
    G_ = lua.globals()
    G_.MOCK_DB = lua.table()
    DB = G_.MOCK_DB
    ns.db = lua.eval("function() return MOCK_DB end")
    ns.money = lua.eval("function(c) return tostring(c) .. 'c' end")
    ns.num = lua.eval("function(n) return tostring(n) end")
    ns.house = lua.eval("function() return 'Realm-Alliance' end")
    ns.ahCut = lua.eval("function() return 0.05 end")
    ns.inventory = lua.eval("""{
      store = function() return INV end,
      meKey = function() return 'Mara-1' end,
      sameHouse = function(rec, me) if not me then return true end
        return rec.realmID == me.realmID and (not rec.faction or rec.faction == me.faction) end,
    }""")
    run = lua.eval("function(src, name, ...) local f = assert(loadstring(src, name)); return f(...) end")
    for name in ["Libs/LibStub/LibStub.lua", "MailClassify.lua", "Ledger.lua", "LedgerWatch.lua", "Gold.lua"]:
        run(source_of(name), name, "EverlookDBAuctions", ns)
    Gd = ns.gold
    L = ns.ledger
    now = G_.NOW
    day = 86400
    me = lua.eval("INV.chars['Mara-1']")

    # --- one point per character per day ---------------------------------------------------------------------------
    check(Gd.dayKey(now) == 20261125, f"day key: {Gd.dayKey(now)}")
    check(Gd.addDays(20261125, 7) == 20261202 and Gd.addDays(20260301, -1) == 20260228, "days over a month's end")
    check(Gd.sample() is True, "a sample is written")
    s = DB.goldDays
    check(s.chars["Mara-1"].d[20261125] == 123456 and s.chars["Mara-1"]["class"] == "MAGE", "today's point, with the class")
    G_.MOCK_MONEY = 200000
    Gd.sample()
    check(s.chars["Mara-1"].d[20261125] == 200000 and len(list(s.chars["Mara-1"].d.keys())) == 1, "the newest of the day wins: one point")
    G_.MOCK_MONEY = G_.SECRET
    check(Gd.sample() is False and s.chars["Mara-1"].d[20261125] == 200000, "a secret value is never written")
    G_.MOCK_MONEY = 200000
    check(Gd.note(s, "Mara-1", None, -5) is None and Gd.note(s, None, None, 5) is None, "no negative gold, no key")
    # Tok: 10 days ago and 3 days ago; Mara: 5 days ago too; Far is on another realm
    Gd.note(s, "Tok-1", lua.eval("INV.chars['Tok-1']"), 50000, now - 10 * day)
    Gd.note(s, "Tok-1", None, 80000, now - 3 * day)
    Gd.note(s, "Mara-1", None, 100000, now - 5 * day)
    Gd.note(s, "Far-2", lua.eval("INV.chars['Far-2']"), 999999, now - 2 * day)
    chars = Gd.chars(s, me, "Mara-1")
    names = [chars[i].name for i in range(1, len(chars) + 1)]
    check(names == ["Mara", "Tok"], f"this house's characters, you first: {names}")

    ser = Gd.series(chars, 7, now)
    check(ser.n == 7 and ser.days[1] == 20261119 and ser.days[7] == 20261125, f"7 days: {ser.days[1]}..{ser.days[ser.n]}")
    tok = [ser.per["Tok-1"][i] for i in range(1, 8)]
    check(tok == [50000, 50000, 50000, 80000, 80000, 80000, 80000], f"Tok's gold carried forward: {tok}")
    mara = [ser.per["Mara-1"][i] for i in range(1, 8)]
    check(mara[0] is None and mara[1] == 100000 and mara[6] == 200000, f"Mara before her first point: none ({mara})")
    check(ser.total[1] == 50000 and ser.total[7] == 280000, f"total: {ser.total[1]}, {ser.total[7]}")
    diff, a, b = Gd.change(ser.total, ser.n)
    check(diff == 230000 and a == 50000 and b == 280000, f"change over the range: {diff}")
    allser = Gd.series(chars, None, now)
    check(allser.days[1] == 20261115 and allser.n == 11, f"all: from the first point ({allser.days[1]}, {allser.n})")
    Gd.note(s, "Tok-1", None, 1000, now - 400 * day)
    longser = Gd.series(Gd.chars(s, me, "Mara-1"), None, now)
    check(longser.n <= Gd.MAX_POINTS and longser.days[longser.n] == 20261125, f"a long range is thinned, today kept: {longser.n}")
    check(Gd.series(lua.table(), None, now) is None, "no points: no series")

    # --- weeks ------------------------------------------------------------------------------------------------------
    ws = Gd.weekStart(now)
    check(lua.eval("function(t) return os.date('%Y-%m-%d %H:%M', t) end")(ws) == "2026-11-23 00:00", "the week starts on Monday")
    led = L.store(DB)

    def money_entry(cat, c, t, **kw):
        return L.addMoney(led, cat, c, lua.table(**kw), t)
    money_entry("sale", 950, now - 3600, cut=50, gross=1000)
    money_entry("vendor", 200, now - 7200)
    money_entry("loot", 30, now - 7200)
    money_entry("quest", 400, now - 7200)
    money_entry("player", 1000, now - 7200)
    money_entry("alt", 5000, now - 7200)        # between your own characters: not income
    money_entry("repair", 120, now - 7200)
    money_entry("vendorbuy", 80, now - 7200)
    money_entry("training", 300, now - 7200)
    money_entry("deposit", 15, now - 7200)
    money_entry("unsorted", 7, now - 7200)
    money_entry("sale", 475, ws - day, cut=25, gross=500)   # last Sunday: last week
    money_entry("vendor", 99, ws - 8 * day)                   # the week before: in neither
    DB.bought = lua.table()
    DB.bought[1] = lua.table(t=now - 600, id=2589, q=20, c=400)
    DB.bought[2] = lua.table(t=ws - 2 * day, id=2589, q=10, c=150)
    this, last, _, _ = Gd.weeks(led, DB.bought, now)
    check(this.sale == 1000 and this.cut == 50, f"AH sales before the cut, the cut a cost: {this.sale}, {this.cut}")
    check(this.income == 1000 + 200 + 30 + 400 + 1000, f"this week's income: {this.income}")
    check(this.cost == 400 + 50 + 15 + 120 + 80 + 300, f"this week's costs: {this.cost}")
    check(this.net == this.income - this.cost and this.unsorted == 7 and this.n == 1, f"net and unsorted: {this.net} {this.unsorted}")
    check(last.sale == 500 and last.cut == 25 and last.bought == 150 and last.vendor == 0, f"last week: {last.sale} {last.bought} {last.vendor}")
    check(this.player == 1000 and this.alt is None, "mail from others counts, your alts don't")

    # --- items ------------------------------------------------------------------------------------------------------
    G_.MOCK_ITEMS[2589] = "Linen Cloth"
    G_.MOCK_ITEMS[4306] = "Silk Cloth"

    def auction(**kw):
        p = {k: v for k, v in kw.items() if k not in ("st", "gross", "net", "at")}
        r = L.post(led, lua.table(**p), now - 3 * day)
        r.st, r.at = kw.get("st", "listed"), kw.get("at", now - day)
        if "gross" in kw:
            r.gross = kw["gross"]
        if "net" in kw:
            r.net = kw["net"]
        return r
    auction(item=2589, name="Linen Cloth", q=20, buy=1000, st="sold", gross=1000, net=950)
    auction(item=2589, name="Linen Cloth", q=20, buy=1100, st="sold", gross=1100, net=1045)
    auction(item=2589, name="Linen Cloth", q=20, buy=1200, st="expired")
    auction(item=4306, name="Silk Cloth", q=1, buy=5000, st="sold", gross=5000, net=4750)
    auction(item=4306, name="Silk Cloth", q=1, buy=5000, st="sold", gross=5000, net=4750, at=now - 40 * day)
    auction(item=4306, name="Silk Cloth", q=5, buy=9000)                  # still up
    auction(item=2589, name="Linen Cloth", q=2, unit=60)                  # up, priced per item
    avg = Gd.averages(DB, led, "Realm-Alliance")
    check(avg.buy[2589] == 18 and avg.sell[2589] == 53, f"averages: buy {avg.buy[2589]}, sell {avg.sell[2589]}")
    byProfit, byCount = Gd.sellers(led, avg, now - 30 * day)
    check(len(byProfit) == 2 and byProfit[1].name == "Silk Cloth" and byProfit[1].n == 1, "by profit: Silk first, the old sale left out")
    linen = byProfit[2]
    check(linen.sold == 40 and linen.n == 2 and linen.expired == 1 and linen.money == 1995, f"Linen: {linen.sold} sold, {linen.expired} expired")
    check(linen.bought and linen.cost == 18 * 40 and linen.profit == 1995 - 720 and linen.avg == 53, f"Linen's profit after what you paid: {linen.profit}")
    check(byCount[1].name == "Linen Cloth", "by count: Linen first")
    allTime, _ = Gd.sellers(led, avg, None)
    check(allTime[1].n == 2, "all time: both Silk sales")
    buys = Gd.biggestBuys(DB.bought, None)
    check(buys[1].c == 400 and buys[2].c == 150, "biggest buys, most first")
    check(len(Gd.biggestBuys(DB.bought, now - day)) == 1, "biggest buys in the range only")
    flips = Gd.flips(avg, 0.05)
    check(len(flips) == 1 and flips[1].id == 2589 and flips[1].margin == round(53 * 0.95 - 18),
          f"flips: {[flips[i].margin for i in range(1, len(flips) + 1)]}")
    c, n = Gd.listed(led)
    check(c == 9000 + 120 and n == 2, f"money on the auction house: {c} in {n}")

    # --- CSV and words ----------------------------------------------------------------------------------------------
    check(Gd.goldNumber(123456) == "12.3456" and Gd.goldNumber(10000) == "1" and Gd.goldNumber(5) == "0.0005", "gold with copper as decimals")
    check(Gd.csvRow(lua.table_from(['a,b', 'say "hi"', 3])) == '"a,b","say ""hi""",3', "CSV quoting")
    csv = Gd.csvDays(ser, chars).split("\n")
    check(csv[0] == "date,total_gold,Mara,Tok" and csv[-1] == "2026-11-25,28,20,8" and csv[1] == "2026-11-19,5,,5",
          f"gold per day CSV: {csv[0]} / {csv[1]} / {csv[-1]}")
    wk = Gd.csvWeeks(this, last).split("\n")
    check(wk[1].startswith("AH sales,income,0.1,0.05") and wk[-1].startswith("Net,total,"), f"weeks CSV: {wk[1]}")
    check(Gd.csvSellers(byProfit).split("\n")[1].startswith("Silk Cloth,4306,1,1,0,0.5,"), "best sellers CSV")
    check(Gd.signed(-500) == "-500c" and Gd.signed(20) == "+20c", "signed money")
    check(Gd.short(123456) == "12g", "axis gold")
    check(Gd.brief(118642) == "12g" and Gd.brief(4205) == "4205c" and Gd.briefSigned(-47905) == "-5g" and Gd.briefSigned(70737) == "+7g",
          "Home's week line: whole gold from 1g up")
    l1, l2 = Gd.homeLines(now)
    check(l1 is not None and l1.startswith("All characters 280000c") and "in 7 days" in l1, f"Home's gold line: {l1}")
    check(l2 is not None and l2.startswith("This week: income 2630c"), f"Home's week line: {l2}")

    # --- merchant and trainer costs (LedgerWatch.lua) ---------------------------------------------------------------
    fire = lua.eval("function(e, a, b, c) for _, f in ipairs(MOCK_FRAMES) do if f.scripts.OnEvent then f.scripts.OnEvent(f, e, a, b, c) end end end")
    before = len(led.money)
    G_.MOCK_MONEY = 100000
    fire("MERCHANT_SHOW")
    G_.MOCK_MONEY = 99000
    fire("PLAYER_MONEY")
    lua.execute("InRepairMode = function() return true end")
    G_.MOCK_MONEY = 98500
    fire("PLAYER_MONEY")
    lua.execute("InRepairMode = nil")
    G_.MOCK_MONEY = 99500
    fire("PLAYER_MONEY")
    fire("MERCHANT_CLOSED")
    fire("TRAINER_SHOW")
    G_.MOCK_MONEY = 97500
    fire("PLAYER_MONEY")
    fire("TRAINER_CLOSED")
    G_.MOCK_MONEY = 90000
    fire("PLAYER_MONEY")
    got = [(led.money[i].cat, led.money[i].c) for i in range(before + 1, len(led.money) + 1)]
    check(got == [("vendorbuy", 1000), ("repair", 500), ("vendor", 1000), ("training", 2000)],
          f"a vendor buy, a repair, a sale, training; nothing away from them: {got}")

    # --- the page builds in the main window -------------------------------------------------------------------------
    lua = lua51.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(source_of("tests/mock.lua"))
    lua.execute("""
        CHAT = {}
        DEFAULT_CHAT_FRAME = { AddMessage = function(_, m) CHAT[#CHAT + 1] = m end }
        STANDARD_TEXT_FONT = "font"
        wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
        date = os.date
    """)
    run = lua.eval("function(src, name, ...) local f = assert(loadstring(src, name)); return f(...) end")
    for lib in ("Libs/LibStub/LibStub.lua", "Libs/EverlookUI/EverlookUI.lua"):
        run(source_of(lib), lib)
    ns = lua.table()
    run(VENDOR_SETUP, "setup", ns)
    lua.execute("function time(t) if t then return os.time(t) end return os.time({ year = 2026, month = 11, day = 25, hour = 15 }) end")
    for name in ["Skin.lua", "Ledger.lua", "Gold.lua"]:
        run(source_of(name), name, "EverlookDBAuctions", ns)
    ns.sellSettings = lua.eval("function() local t = {}; return function() return t end end")()
    ns.undercutShort = lua.eval("function() return '1s' end")
    ns.setUndercut = lua.eval("function() return true end")
    ns.tipOn = lua.eval("function() return true end")
    ns.ledger.get = lua.eval("function() return nil end")
    run(source_of("Options.lua"), "Options.lua", "EverlookDBAuctions", ns)
    fire = lua.eval("function(e, a) for _, f in ipairs(MOCK_FRAMES) do if f.scripts.OnEvent then pcall(f.scripts.OnEvent, f, e, a) end end end")
    fire("ADDON_LOADED", "EverlookDBAuctions")
    check(ns.optionsError is None, f"the settings window builds: {ns.optionsError}")
    app = ns.app
    ns.gold.page(app, lua.eval('(LibStub("EverlookUI-1"))'))
    gs = ns.gold.store()
    gs.chars["Mara-1"] = lua.table(name="Mara", d=lua.table())
    for k, v in ((20261120, 50000), (20261123, 70000), (20261125, 65000)):
        gs.chars["Mara-1"].d[k] = v
    built = lua.eval("""function(app)
      local UI = LibStub("EverlookUI-1")
      local parent = CreateFrame("Frame", nil, UIParent)
      local stack = UI.Stack(parent, 700, app.T, { cards = true })
      local sec = app.sections.gold
      local okB, err = pcall(sec.build, stack, app, sec)
      return okB, tostring(err)
    end""")(app)
    check(built[0], f"the Gold page builds: {built[1]}")
    # Shopping lists, a page of the main window: a leveling guide's table pastes and saves away from the auction house
    run(source_of("ListImport.lua"), "ListImport.lua", "EverlookDBAuctions", ns)
    run(source_of("Shopping.lua"), "Shopping.lua", "EverlookDBAuctions", ns)
    ns.shopping.page(app, lua.eval('(LibStub("EverlookUI-1"))'))
    built_s = lua.eval("""function(app)
      local UI = LibStub("EverlookUI-1")
      local parent = CreateFrame("Frame", nil, UIParent)
      local stack = UI.Stack(parent, 700, app.T, { cards = true })
      local sec = app.sections.shopping
      local okB, err = pcall(sec.build, stack, app, sec)
      return okB, tostring(err)
    end""")(app)
    check(built_s[0], f"the Shopping lists page builds: {built_s[1]}")
    ids = {"Rough Stone": 2835, "Bronze Bar": 2841, "Green Dye": 2605}
    ns.listImport.idOf = lambda n: ids.get(n)
    ns.listImport.nameOf = lambda i: {v: k for k, v in ids.items()}.get(i)
    got = []
    ns.shopping["import"]("Material\n90x Rough Stone\n300x Bronze Bar\n10x Green Dye (vendor)", "BS 1-150", False, 0, lambda lines, left: got.append(list(dict(lines).values())))
    saved = [l for l in ns.db().lists.values() if l.name == "BS 1-150"] if ns.db() and ns.db().lists else []
    check(len(saved) == 1 and len(list(saved[0].queries.values())) == 2, f"the guide's list is saved with 2 items: {got}")
    check(got and any("vendor" in x for x in got[0]), f"the vendor item is said: {got}")
    check(got and any(x.endswith("vendor: 10 Green Dye") for x in got[0]), f"the vendor item reads as its amount and name: {got}")
    src = source_of("Shopping.lua")
    check('label = "Import", style = "accent"' in src, "Import is the page's one gold button (EverlookUI's style is accent)")
    P = ns.gold.pageState
    check(P.series is not None and P.series.n == 30, f"30 days by default: {P.series and P.series.n}")
    check(P.chart is not None and P.chart.drawError is False, f"the chart draws without an error: {P.chart and P.chart.drawError}")
    drawn = P.chart.drawn if P.chart is not None and P.chart.drawError is False else None
    check(drawn is not None and drawn.points == 30 and drawn.dots >= 6, f"the chart draws: {drawn and drawn.dots}")
    status = P.status.text.GetText(P.status.text) if P.status is not None else ""
    check("All 1 character: 65000c" in status, f"the status line: {status}")
    P.range = "7"
    okC = lua.eval("function(g) local ok, e = pcall(g.compute); return ok, tostring(e) end")(ns.gold)
    check(okC[0], f"compute: {okC[1]}")
    ns.gold.refreshPage()
    check(P.series is not None and P.series.n == 7 and P.chart is not None and P.chart.drawError is False and P.chart.drawn.points == 7, "7 days")
    P.mode = "per"
    P.export = "days"
    ns.gold.refreshPage()
    box = P.exportBox.area.box.GetText(P.exportBox.area.box)
    check(box.startswith("date,total_gold,Mara") and "2026-11-25,6.5,6.5" in box, f"the export box: {box[:60]}")
    check(app.sections.gold is not None and app.sections.gold.group == "main", "Gold is one of the main pages")
    return failures


def results_alerts_market():
    """Your results (Results.lua) per item from the ledger, with advice and Quick sell's line; price alerts (Watch.lua):
    once per item and price level, from a scan or a quick search, marked in Deals; market hints (Market.lua): a week's
    trend and many more listed than usual, only with enough days. And the AH log's Results view draws."""
    failures = []

    def check(cond, what):
        if not cond:
            failures.append("results/alerts/market: " + what)

    lua = lua51.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(source_of("tests/mock.lua"))
    lua.execute("""
      MOCK_TIME = 1000000; function time(t) if t then return os.time(t) end return MOCK_TIME end
      date = os.date
      GetTime = function() return MOCK_TIME end
      UISpecialFrames = {}; tinsert = table.insert
      function IsShiftKeyDown() return false end
      SAID = {}
      C_Item.GetItemInfo = function(id) return MOCK_ITEMS[id], '|cffffffff|Hitem:' .. id .. '::|h[' .. tostring(MOCK_ITEMS[id]) .. ']|h|r' end
      MOCK_ITEMS[2772] = 'Iron Ore'; MOCK_ITEMS[4306] = 'Silk Cloth'; MOCK_ITEMS[2589] = 'Linen Cloth'
    """)
    ns = lua.table()
    DB = lua.table()
    G = lua.globals()
    G.MOCK_DB = DB
    ns.db = lua.eval("function() return MOCK_DB end")
    ns.money = lua.eval("function(c) return tostring(c) .. 'c' end")
    ns.num = lua.eval("function(n) return tostring(n) end")
    ns.say = lua.eval("function(m) SAID[#SAID + 1] = m end")
    ns.house = lua.eval("function() return 'Realm-Alliance' end")
    run = lua.eval("function(src, name, ...) local f = assert(loadstring(src, name)); return f(...) end")
    for name in ["Ledger.lua", "Results.lua"]:
        run(source_of(name), name, "EverlookDBAuctions", ns)
    R = ns.results
    now = 1000000
    H = 3600

    # --- Your results -------------------------------------------------------------------------------------------
    recs = lua.table()
    seq = [0]

    def rec(item, name, st, t, at=None, dur=2, net=None, dep=None, depLost=None, h="Realm-Alliance", q=1):
        seq[0] += 1
        r = lua.table(id=seq[0], item=item, name=name, st=st, t=t, at=at if at is not None else t, dur=dur, net=net, dep=dep,
                      depLost=depLost, h=h, q=q)
        recs[len(recs) + 1] = r
        return r

    # Iron Ore: 5 sold within 1-3 h of 5 ended (8 h auctions)
    for i, hrs in enumerate([1, 2, 3, 0.5, 2.5]):
        t = now - (i + 1) * 86400
        rec(2772, "Iron Ore", "sold", t, t + hrs * H, net=950, q=10)
    # Silk Cloth: 2 sold, 6 expired (2 h auctions), deposits lost
    for i in range(2):
        t = now - (i + 1) * 86400
        rec(4306, "Silk Cloth", "sold", t, t + H, dur=1, net=400)
    for i in range(6):
        t = now - (i + 3) * 86400
        rec(4306, "Silk Cloth", "expired", t, t + 2 * H, dur=1, dep=30, depLost=True)
    rec(4306, "Silk Cloth", "cancelled", now - 86400, now - 86000, dur=1, dep=30, depLost=True)
    # Linen: 1 sold a day after posting (seen in its mail only), 1 still up
    rec(2589, "Linen Cloth", "sold", now - 5 * 86400, now - 4 * 86400, net=50)
    rec(2589, "Linen Cloth", "listed", now - H)
    # old (outside 30 days) and another house: left out
    rec(2772, "Iron Ore", "expired", now - 40 * 86400, now - 40 * 86400 + 8 * H)
    rec(2772, "Iron Ore", "expired", now - 2 * 86400, now - 2 * 86400 + 8 * H, h="Realm-Neutral")
    s = lua.table(auctions=recs, money=lua.table(), seq=seq[0])
    lst = R.summary(s, now - 30 * 86400, lua.table(h="Realm-Alliance"))
    by = {lst[i].name: lst[i] for i in range(1, len(lst) + 1)}
    ore, silk, linen = by.get("Iron Ore"), by.get("Silk Cloth"), by.get("Linen Cloth")
    check(ore is not None and ore.posted == 5 and ore.sold == 5 and ore.ended == 5 and ore.expired == 0,
          f"Iron Ore: 5 posted, 5 sold (old and other house left out): {ore and (ore.posted, ore.sold, ore.expired)}")
    check(ore is not None and ore.money == 5 * 950 and abs(ore.avgSecs - 1.8 * H) < 1, f"Iron Ore money and average time: {ore and (ore.money, ore.avgSecs)}")
    check(ore is not None and ore.short == "Sells fast" and ore.advice == "Sells fast: 5 of 5 sold within 3 hours.", f"fast advice: {ore and ore.advice}")
    check(silk is not None and silk.sold == 2 and silk.expired == 6 and silk.cancelled == 1 and silk.ended == 8 and silk.posted == 9,
          f"Silk: 2 sold, 6 expired, 1 cancelled: {silk and (silk.sold, silk.expired, silk.cancelled)}")
    check(silk is not None and silk.money == 800 - 7 * 30, f"Silk: sales after the cut minus 7 deposits lost: {silk and silk.money}")
    check(silk is not None and silk.advice == "Keeps expiring: 6 of 8 expired. Try a lower price or a longer duration.",
          f"expiring advice: {silk and silk.advice}")
    check(linen is not None and linen.avgSecs is None and linen.open == 1 and linen.short == "Too few yet",
          f"Linen: a sale seen a day late has no time; too few to tell: {linen and (linen.avgSecs, linen.short)}")
    # 24 h auctions that keep expiring: a lower price only
    e24 = lua.table(ended=4, sold=1, expired=3, shortest=3)
    check(R.advice(e24)[0] == "Keeps expiring: 3 of 4 expired. Try a lower price.", f"24 h: {R.advice(e24)[0]}")
    check(R.advice(lua.table(ended=5, sold=4, expired=1, avgSecs=5 * H))[0] == "Sells well: 4 of 5 sold, usually within 5 hours.",
          "sells well, with the usual time")
    check(R.sellSecs(lua.table(st="sold", t=0, at=3 * H, dur=1)) is None, "a 2 h auction sold 'after 3 h': not a real time")
    check(R.sellSecs(lua.table(st="sold", t=0, at=int(2.2 * H), dur=1)) == 2 * H, "within the slack: capped at the duration")
    # sorting
    R.sort(lst, "money")
    check(lst[1].name == "Iron Ore", "by money: Iron Ore first")
    R.sort(lst, "advice")
    check(lst[1].name == "Silk Cloth", "by expired share: Silk first")
    R.sort(lst, "name", False)
    check([lst[i].name for i in range(1, 4)] == ["Iron Ore", "Linen Cloth", "Silk Cloth"], "by name")
    tot = R.totals(lst)
    check(tot.posted == 16 and tot.sold == 8 and tot.ended == 14, f"totals: {tot.posted} {tot.sold} {tot.ended}")
    # Quick sell's line
    line, tone = R.quickLine(s, 2772, "Realm-Alliance", now)
    check(line == "Sold 5 of 5 here, within 2 h" and tone == "ok", f"Quick sell line: {line} {tone}")
    line, tone = R.quickLine(s, 4306, "Realm-Alliance", now)
    check(line == "Sold 2 of 8 here, within 1 h" and tone == "danger", f"Quick sell line, mostly expired: {line} {tone}")
    check(R.quickLine(s, 2589, "Realm-Alliance", now)[0] == "Sold 1 of 1 here", "no time known: no 'within'")
    check(R.quickLine(s, 12345, "Realm-Alliance", now) is None, "never posted: no line")

    # --- Price alerts --------------------------------------------------------------------------------------------
    lua.execute("HIST = {}; PRICES = {}")
    ns.today = lua.eval("function() return math.floor(MOCK_TIME / 86400) end")
    ns.historyDays = lua.eval("function(id) return HIST[id] end")
    ns.itemFor = lua.eval("function(id) return PRICES[id] end")
    ns.listImport = lua.eval("{ idOf = function(n) for id, x in pairs(MOCK_ITEMS) do if x == n then return id end end end }")
    for name in ["Deals.lua", "Watch.lua", "Market.lua"]:
        run(source_of(name), name, "EverlookDBAuctions", ns)
    W, D = ns.watch, ns.deals
    day = now // 86400
    hist = lua.table()
    for k in range(10):
        hist[day - k] = 1000
    G.HIST[4306] = hist
    check(W.level(620, 1000, 80) == 6 and W.level(800, 1000, 80) is None and W.level(799, 1000, 80) == 7, "levels in 10% steps under 80%")
    check(W.check(4306, 600) is None, "not watched: no alert")
    check(W.toggle(4306, None, True) is True and W.has(4306), "watched")
    check(any("watching" in str(x) and "Silk Cloth" in str(x) for x in G.SAID.values()), "it says so in chat")
    t1 = W.check(4306, 750)
    check(t1 is not None and "75% of its usual 1000c" in t1 and "750c" in t1, f"under 80%: one alert: {t1}")
    check(W.check(4306, 740) is None, "the same level: no second alert")
    check(W.check(4306, 600) is not None, "a lower level: one more")
    check(W.check(4306, 750) is None, "back up a level: nothing")
    check(W.check(4306, 1000) is None and DB.watch[4306].lvl is None, "back at its usual price: starts over")
    check(W.check(4306, 700) is not None, "the next dip alerts again")
    # a quick search: the cheapest that isn't yours
    W.check(4306, 1000)
    rows = lua.eval("{ { unit = 300, qty = 5, mine = true }, { unit = 650, qty = 2 } }")
    before = len(G.SAID)
    ns.noteLivePrice(4306, rows)
    check(len(G.SAID) == before + 1 and "650c" in G.SAID[len(G.SAID)], f"a quick search alerts (not on your own auction): {G.SAID[len(G.SAID)]}")
    # a price update: fresh prices only
    W.check(4306, 1000)
    G.PRICES[4306] = lua.table(600, 20, 4, now - 5 * 3600)
    before = len(G.SAID)
    W.checkAll(now)
    check(len(G.SAID) == before, "a price over 3 hours old: no alert")
    G.PRICES[4306] = lua.table(600, 20, 4, now - 600)
    W.checkAll(now)
    check(len(G.SAID) == before + 1, "a fresh price update alerts")
    # off
    DB.watchOff = True
    W.check(4306, 1000)
    check(W.check(4306, 500) is None, "alerts off: nothing")
    DB.watchOff = None
    # no history: no usual price, no alert
    W.toggle(2589)
    check(W.check(2589, 1) is None, "no usual price yet: no alert")
    # the crafting queue's materials
    G.EverlookCraftAPI = lua.eval("{ version = 8, queueSet = function() end, queueCount = function() end, queue = function() end, queueMissing = function() return { { 2772, 40 }, { 2880, 5, vendor = true } } end }")
    G.HIST[2772] = hist
    W.forgetQueue()
    t2 = W.check(2772, 500)
    check(t2 is not None and "Your crafting queue needs 40" in t2, f"a queue material alerts: {t2}")
    check(W.check(2772, 500) is None and DB.watchSeen[2772].lvl == 5, "once per level for queue materials too")
    DB.watchQueue = False
    W.forgetQueue()
    check(W.check(2772, 100) is None, "queue setting off: nothing")
    DB.watchQueue = None
    W.forgetQueue()
    # resolve: link, ID, name
    check(W.resolve("|cffffffff|Hitem:4306::|h[Silk Cloth]|h|r")[0] == 4306, "a link")
    check(W.resolve("2589")[0] == 2589, "an ID")
    check(W.resolve("Iron Ore")[0] == 2772, "a name")
    check(W.resolve("Nothing Like It")[0] is None, "an unknown name")
    W.command("Linen Cloth", True)
    check(not W.has(2589), "/eah unwatch")
    wl = W.list()
    check(len(wl) == 1 and wl[1].id == 4306, "the list")
    # the Deals mark: a watched item under 80% is a deal marked "watched", whatever its profit
    G.EverlookCraftAPI = None
    W.forgetQueue()
    rowsD = lua.eval("{ { key = '4306:0', id = 4306, name = 'Silk Cloth', price = 750, qty = 3, auctions = 1 }, { key = '2589:0', id = 2589, name = 'Linen Cloth', price = 750, qty = 3, auctions = 1 } }")
    G.HIST[2589] = hist
    filt, pct = W.dealsFilter()
    o = lua.table(watch=filt, watchPct=pct, today=day, days=ns.historyDays, min=100000, unsure=True)
    out, _hidden = D.build(rowsD, o)
    check(len(out) == 1 and out[1].id == 4306 and "watched, 75% of usual" in D.whyText(out[1]),
          f"Deals marks the watched one: {[D.whyText(out[i]) for i in range(1, len(out) + 1)]}")

    # --- Market hints --------------------------------------------------------------------------------------------
    M = ns.market
    up = lua.table()
    for k in range(13):
        up[day - k] = 1400 if k <= 2 else 1000
    check(abs(M.trend(up, day) - 0.4) < 0.001, f"up 40% this week: {M.trend(up, day)}")
    down = lua.table()
    for k in range(13):
        down[day - k] = 700 if k <= 2 else 1000
    lbl, val, _ = M.hint(down, day, None, None, now)
    check(lbl == "Falling" and val == "down 30% this week", f"falling: {lbl} {val}")
    flat = lua.table()
    for k in range(13):
        flat[day - k] = 1100 if k <= 2 else 1000
    check(M.trend(flat, day) is None, "10% is not notable")
    few = lua.table()
    for k in (0, 1, 6, 7):
        few[day - k] = 2000 if k <= 2 else 1000
    check(M.trend(few, day) is None, "4 days of lows: too few")
    # counts: a running average per day, today's newest count apart
    h = lua.table()
    for k in range(6):
        M.noteQty(h, 4306, 100, day - 5 + k)
        M.noteQty(h, 4306, 120, day - 5 + k)   # a second update the same day: the newest counts
    e = h.qty[4306]
    check(e[2] == 5 and abs(e[1] - 120) < 0.01 and e[4] == 120, f"5 days folded in, today's kept apart: {e[1]} {e[2]} {e[4]}")
    lbl, val, _ = M.hint(None, day, e, lua.table(1, 400, 9, now - 600), now)
    check(lbl == "Many listed" and val == "400, about 3x the usual", f"many listed: {lbl} {val}")
    check(M.hint(None, day, e, lua.table(1, 300, 9, now - 600), now) is None, "2.5x the usual: quiet")
    check(M.hint(None, day, e, lua.table(1, 400, 9, now - 2 * 86400), now) is None, "an old count: quiet")
    check(M.many(lua.table(3, 9, day, 3), 15) is None, "a handful (under 20): quiet")
    check(M.many(lua.table(10, 2, day, 10), 100) is None, "2 days of counts: too few")
    lbl, _, _ = M.hint(up, day, e, lua.table(1, 400, 9, now - 600), now)
    check(lbl == "Many listed", "one line at most: many listed wins over the trend")
    h.qty[999] = lua.table(1, 1, day - 40, 1)
    h.qtyPruned = None
    M.prune(h, day)
    check(h.qty[999] is None and h.qty[4306] is not None, "counts not seen for 30 days go")
    # the tooltip line: one Line, only with the setting on
    ns.tipOn = lua.eval("function(k) return not (MOCK_DB.tip and MOCK_DB.tip[k] == false) end")
    ns.houseData = lua.eval("function() return MOCK_HOUSE end")
    G.MOCK_HOUSE = lua.table(qty=lua.table())
    G.HIST[5000] = up
    lines = lua.eval("function(M, id) local out = {}; local t = { Line = function(_, l, v) out[#out + 1] = l .. ': ' .. tostring(v) end }; M.forget(); M.tooltip(t, id); return out end")
    got = lines(M, 5000)
    check(len(got) == 1 and got[1] == "Rising: up 40% this week", f"tooltip line: {list(got.values())}")
    DB.tip = lua.table(market=False)
    check(len(lines(M, 5000)) == 0, "setting off: no line")
    DB.tip = None
    check(len(lines(M, 4306)) == 0, "nothing notable: no line")
    src = source_of("Options.lua")
    check('"tipmarket", "market"' in src, "the tooltip setting is in TIP_LINES")
    check('ns.watch.settingsFor(app, UI)' in src, "the Price alerts page is built with the settings")
    check("COMBAT_LOG_EVENT_UNFILTERED" not in source_of("Watch.lua") + source_of("Market.lua") + source_of("Results.lua"), "no combat log")

    # --- the AH log's Results view draws ---------------------------------------------------------------------------
    lua2 = lua51.LuaRuntime(unpack_returned_tuples=True)
    lua2.execute(source_of("tests/mock.lua"))
    lua2.execute("""
      MOCK_TIME = 1000000; function time() return MOCK_TIME end
      function date(fmt, t) return 'd' .. tostring(t) end
      UISpecialFrames = {}; tinsert = table.insert
      function IsShiftKeyDown() return false end
      C_AuctionHouse = { PlaceBid = function() end, StartCommoditiesPurchase = function() end, ConfirmCommoditiesPurchase = function() end }
      MOCK_ITEMS[4306] = 'Silk Cloth'
    """)
    ns2 = lua2.table()
    DB2 = lua2.table()
    lua2.globals().MOCK_DB = DB2
    ns2.db = lua2.eval("function() return MOCK_DB end")
    ns2.money = lua2.eval("function(c) return tostring(c) .. 'c' end")
    ns2.num = lua2.eval("function(n) return tostring(n) end")
    ns2.house = lua2.eval("function() return 'Realm-Alliance' end")
    ns2.itemFor = lua2.eval("function() return nil end")
    run2 = lua2.eval("function(src, name, ...) local f = assert(loadstring(src, name)); return f(...) end")
    run2(source_of("Skin.lua"), "Skin.lua", "EverlookDBAuctions", ns2)
    for name in ["Libs/LibStub/LibStub.lua", "Libs/EverlookUI/EverlookUI.lua", "MailClassify.lua", "PurchaseLog.lua", "Ledger.lua",
                 "LedgerWatch.lua", "Results.lua", "Purchases.lua"]:
        run2(source_of(name), name, "EverlookDBAuctions", ns2)
    try:
        led = ns2.ledger.store(DB2)
        led.migrated = lua2.table(at=1)
        ns2.ledger.get = lua2.eval("function() return MOCK_DB.ledger end")
        post = lua2.eval("function() return { item = 4306, name = 'Silk Cloth', q = 20, unit = 10, dur = 2, dep = 30, h = 'Realm-Alliance' } end")
        for i in range(3):
            ns2.ledger.post(led, post(), 1000000 - 86400 * (i + 1))
        for r in (led.auctions[1], led.auctions[2]):
            r.st, r.at, r.net = "sold", r.t + 3600, 190
        led.auctions[3].st, led.auctions[3].at, led.auctions[3].depLost = "expired", led.auctions[3].t + 9 * 3600, True
        B = ns2.purchases
        B.mode = "results"
        B.open()
        f = lua2.globals().EverlookAuctionsPurchases
        check(f is not None, "the window is made")
        B.render()
        check("3 posted, 2 of 3 sold (67%), 1 expired, 350c" in f.sum.text, f"the Results sum: {f.sum.text}")
        rawget = lua2.eval("rawget")
        shown = [f.rows[i] for i in range(1, len(f.rows) + 1) if rawget(f.rows[i], "entry")]
        check(len(shown) == 1 and shown[0].date.text == "2 of 3" and shown[0].qty.text == "3" and shown[0].each.text == "1h 00m",
              f"the Silk Cloth row: {shown and (shown[0].date.text, shown[0].qty.text, shown[0].each.text)}")
        check(f.headWhen.text == "SOLD" and f.totalHead.text == "MADE", "the column heads say what they show")
        B.resSort, B.resDesc = "name", False
        B.render()
        B.mode = "income"
        B.render()
        check(f.totalHead.text == "TOTAL", "back to Income: the heads come back")
    except Exception as ex:
        failures.append(f"results/alerts/market: Results view error {ex}")
    return failures


if __name__ == "__main__":
    sys.exit(main())
