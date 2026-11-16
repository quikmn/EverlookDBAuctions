"""Offline tests in Lua 5.1 (WoW's version) via lupa: the shopping list from a recipe (RecipeList.lua), then the
crafting box and the shopping list panel (Crafting.lua) against a fake profession window (tests/mock.lua).

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


if __name__ == "__main__":
    sys.exit(main())
