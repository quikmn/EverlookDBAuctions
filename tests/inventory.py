"""Inventory across your characters (Inventory.lua, Where.lua, the inventory words of Search.lua and API v7): bags,
bank only while it is open, hidden values kept, mail with what is on its way from another of your characters, your
auctions (ended and sold ones drop), the guild bank, gold, only this realm and faction counted, the seed from
EverlookDB Crafting, the tooltip line, the query language over what you own and the API's copies.

Called from tests/run.py (inventory(source_of, VENDOR_SETUP))."""
from lupa import lua51

SETUP = """
ME = "Anna"
function UnitName() return ME end
function UnitGUID() return "Player-6946-0001" end
function UnitFactionGroup() return "Alliance" end
function UnitClass() return "Mage", "MAGE" end
SECRET = {}
function issecretvalue(v) return SECRET[v] == true end
-- containers: BAGS[bag] = { { id, n }, ... }
BAGS = { [0] = { { 2589, 20 }, { 2589, 8 }, false }, [1] = { { 7001, 1 } }, [-1] = { { 2592, 5 } } }
C_Container = {
  GetContainerNumSlots = function(bag) return BAGS[bag] and #BAGS[bag] or 0 end,
  GetContainerItemInfo = function(bag, slot)
    local s = BAGS[bag] and BAGS[bag][slot]
    if not s then return nil end
    return { itemID = s[1], stackCount = s[2] }
  end,
}
WORN = { [16] = 3000 }
function GetInventoryItemID(_, slot) return WORN[slot] end
MONEY = 12345
function GetMoney() return MONEY end
MAILS = {}
local classifier = LibStub:NewLibrary("EverlookMailClassify-1", 99)
classifier.scan = function() return MAILS end
SEND = {}
function GetSendMailItem(i) local s = SEND[i]; if s then return "x", s[1], 1, s[2] end end
function GetSendMailMoney() return SEND.money or 0 end
function GetSendMailCOD() return 0 end
GUILDTAB = 1
GUILD = { [1] = { 2589, 30 } }
function GetGuildInfo() return "Dusk" end
function GetCurrentGuildBankTab() return GUILDTAB end
function GetGuildBankItemLink(tab, slot) local s = GUILD[slot]; if s then return "|Hitem:" .. s[1] .. "|h" end end
function GetGuildBankItemInfo(tab, slot) local s = GUILD[slot]; if s then return 1, s[2] end end
MAX_GUILDBANK_SLOTS_PER_TAB = 3
local hsf = hooksecurefunc
function hooksecurefunc(t, k, fn)
  if type(t) == "string" then
    local old = _G[t]
    _G[t] = function(...) local r = old(...); k(...); return r end
    return
  end
  return hsf(t, k, fn)
end
function SendMail() end
local ns = ...
ns.upChars = { who = function() return ME, "Test", 6946 end, forget = function() return true end }
ns.purchases = { noteOwned = function() end }
"""


def inventory(source_of, vendor_setup):
    lua = lua51.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(source_of("tests/mock.lua"))
    ns = lua.table()
    run = lua.eval("function(src, name, ...) local f = assert(loadstring(src, name)); return f(...) end")
    run(vendor_setup, "setup", ns)
    for name in ["Skin.lua", "Vendor.lua", "Search.lua"]:
        run(source_of(name), name, "EverlookDBAuctions", ns)
    run(SETUP, "inv setup", ns)
    for name in ["Inventory.lua", "Where.lua", "API.lua"]:
        run(source_of(name), name, "EverlookDBAuctions", ns)
    G = lua.globals()
    I = ns.inventory
    failures = []

    def check(cond, what):
        if not cond:
            failures.append("inventory: " + what)

    fire = lua.eval("function(e, a) for _, f in ipairs(MOCK_FRAMES) do if f.scripts.OnEvent then f.scripts.OnEvent(f, e, a) end end end")
    fire("PLAYER_LOGIN")
    s = ns.db().inv
    me = s.chars["Anna-6946"]
    check(me is not None, "this character is saved as Name-realm ID")
    check(me.bags[2589] == 28 and me.bags[7001] == 1, f"bags counted: {me.bags[2589]}")
    check(me.bank is None, "the bank isn't read while it is closed")
    check(me.worn[3000] == 1 and me.money == 12345, "gear and gold")
    check(me.faction == "Alliance" and me["class"] == "MAGE", "faction and class")

    fire("BANKFRAME_OPENED")
    check(me.bank[2592] == 5, "the bank, while it is open")
    fire("BANKFRAME_CLOSED")
    G.BAGS[-1] = lua.eval("{ { 2592, 99 } }")
    fire("BAG_UPDATE_DELAYED")
    check(me.bank[2592] == 5, "after the bank closed, its count stays as last seen")

    # a slot the game hides: the saved bags stay
    G.BAGS[1] = lua.eval("{ { 7001, 1 }, { 2589, 1 } }")
    lua.execute("SECRET[2589] = true")
    fire("BAG_UPDATE_DELAYED")
    check(me.bags[2589] == 28, "a secret value keeps what was saved")
    lua.execute("SECRET[2589] = nil")
    G.BAGS[1] = lua.eval("{ { 7001, 1 } }")
    fire("BAG_UPDATE_DELAYED")

    # alts: same realm and faction count; another realm and the other faction don't
    G.EverlookTestInv = s
    lua.execute("""
      local s = EverlookTestInv
      s.chars["Mara-6946"] = { name = "Mara", realmID = 6946, faction = "Alliance", class = "PRIEST", bank = { [2589] = 40 },
        money = 5000 }
      s.chars["Thorn-6946"] = { name = "Thorn", realmID = 6946, faction = "Alliance", class = "WARRIOR", mail = { [2589] = 12 },
        money = 100, mailMoney = 50 }
      s.chars["Far-1111"] = { name = "Far", realmID = 1111, faction = "Alliance", bags = { [2589] = 99 } }
      s.chars["Grim-6946"] = { name = "Grim", realmID = 6946, faction = "Horde", bags = { [2589] = 77 } }
    """)
    I.changed()
    r = I.count(2589)
    check(r.total == 80 and r.mine == 28 and r.alts == 52, f"you 28, Mara 40, Thorn 12: {r.total}/{r.mine}/{r.alts}")
    check(r.chars[1].me and r.chars[2].name == "Mara" and r.chars[3].name == "Thorn", "you first, then the most")
    check(lua.eval("rawequal")(I.count(2589), r), "cached until something changes")
    check(I.usable(2589) == 80 and I.usable(2589, False) == 28, "usable: with and without alts")

    tl = ns.where.tipLines(2589)
    check(tl.label == "You have 28", f"tooltip label: {tl.label}")
    check("Mara 40 (bank)" in tl.note and "Thorn 12 (mail)" in tl.note, f"tooltip note: {tl.note}")
    check(tl.value == "80", f"the total on the right: {tl.value}")
    check(len(tl.details) == 3 and tl.details[1].label == "You" and "28 bags" in tl.details[1].note, "Shift: per place")
    check(ns.where.tipLines(424242) is None, "nobody has it: no line")
    # the setting turns it off
    ns.tipOn = lua.eval("function(k) return k ~= 'have' end")
    sink = lua.eval("{ rows = {}, Line = function(self, ...) table.insert(self.rows, { ... }) end, Detail = function() end }")
    ns.where.tooltip(sink, 2589)
    check(len(sink.rows) == 0, "Tooltips setting off: no line")
    ns.tipOn = lua.eval("function() return true end")
    ns.where.tooltip(sink, 2589)
    check(len(sink.rows) == 1, "on: one line")

    # mail: the mailbox while it is open, money without C.O.D.
    G.MAILS = lua.eval("""{ { sender = "Bob", subject = "hi", money = 300, cod = 0, items = { { id = 2592, count = 4 } } },
      { sender = "Cod", subject = "pay", money = 0, cod = 900, items = { { id = 2592, count = 1 } } } }""")
    fire("MAIL_SHOW")
    check(me.mail[2592] == 5 and me.mailMoney == 300, f"mail items and money: {me.mail[2592]}, {me.mailMoney}")
    fire("MAIL_CLOSED")

    # sent to an alt: on its way (counted as its mail) until its mailbox shows it
    G.SEND = lua.eval("{ { 2592, 7 }, money = 250 }")
    G.SendMail("Mara-Test", "mats", "")
    fire("MAIL_SEND_SUCCESS")
    mara = s.chars["Mara-6946"]
    check(mara.incoming is not None and mara.incoming[1]["items"][2592] == 7, "sent to Mara: incoming")
    check(I.count(2592).chars[2].mail == 7 if I.count(2592).chars[2].name == "Mara" else False, "counted as Mara's mail")
    total, _ = I.gold()
    check(total == 12345 + 300 + 5000 + 250 + 100 + 50, f"gold with what waits in the mail: {total}")
    G.SendMail("Stranger", "x", "")
    fire("MAIL_SEND_SUCCESS")
    check(len(mara.incoming) == 1, "mail to someone else isn't tracked")
    G.SendMail("Thorn", "x", "")
    fire("MAIL_FAILED")
    fire("MAIL_SEND_SUCCESS")
    check(s.chars["Thorn-6946"].incoming is None, "a failed send isn't counted")
    # Mara opens her mailbox and it is there: incoming goes, the mail counts
    I.readMailList(mara, lua.eval('{ { sender = "Anna", subject = "mats", money = 250, cod = 0, items = { { id = 2592, count = 7 } } } }'), 1000)
    check(mara.incoming is None and mara.mail[2592] == 7, "arrived: counted once")
    # one still on its way stays; one an hour old and gone was taken
    mara.incoming = lua.eval("{ { t = 900, from = 'Anna', subj = 'a', items = { [2592] = 1 } }, { t = -5000, from = 'Anna', subj = 'b', items = { [2592] = 2 } } }")
    I.readMailList(mara, lua.eval("{}"), 1000)
    check(len(mara.incoming) == 1 and mara.incoming[1].subj == "a", "in transit kept, old ones dropped")

    # your auctions: listed, ended ones drop, a sale takes one off
    ns.purchases.noteOwned(lua.eval("{ { itemID = 7001, qty = 1, left = 3600 }, { itemID = 2589, qty = 20, left = 60 }, { itemID = 2592, qty = 1, sold = true } }"))
    check(len(me.listed) == 2 and I.count(7001).chars[1].listed == 1, "auctions as listed, the sold one left out")
    check(I.placeCount(me, "listed", 2589, 1000 + 61) == 0, "an ended auction no longer counts")
    lua.execute('MOCK_ITEMS[7001] = "Lesser Magic Wand"')
    fire("CHAT_MSG_SYSTEM", "A buyer has been found for your auction of Lesser Magic Wand.")
    check(len(me.listed) == 1 and me.listed[1].id == 2589, "a sale takes its auction off")

    # the guild bank: the tab on screen, per guild
    fire("GUILDBANKFRAME_OPENED")
    g = s.guilds["Dusk-6946"]
    check(g is not None and g.tabs[1][2589] == 30, "guild bank tab read")
    check(I.count(2589).guild == 30 and "Guild bank 30" in ns.where.tipLines(2589).note, "guild bank on the tooltip")
    fire("GUILDBANKFRAME_CLOSED")

    # gold changes
    G.MONEY = 99
    fire("PLAYER_MONEY")
    check(me.money == 99, "gold follows")
    l1, l2, _t, _l = ns.where.goldLines(3)
    check("on 3 characters" in l1, f"gold line: {l1}")

    # the query language over what you own
    def srch(q):
        res = ns.where.search(q)
        res = res if isinstance(res, tuple) else (res,)
        return res[0], (res[1] if len(res) > 1 else None)
    out, head = srch("have gt 50")
    names = [out[i].name for i in range(1, len(out) + 1)] if out else head
    check(names == ["Linen Cloth"], f"have gt 50: {names}")
    out, _ = srch("char is Mara")
    names = sorted(out[i].name for i in range(1, len(out) + 1))
    check(names == ["Linen Cloth", "Wool Cloth"], f"char is Mara: {names}")
    out, _ = srch("place is worn")
    check(len(out) == 1 and out[1].name == "Old Sword", "place is worn")
    out, _ = srch("cloth")
    check(len(out) == 2 and out[1].name == "Linen Cloth", "a word searches names, most first")
    out, head = srch("have gt 0 count")
    check(len(out) == 0 and "matching" in head, f"count: {head}")
    out, err = srch("have gt")
    check(out is None and err, "an error says what is missing")
    check(ns.queryParse("have gt 0 and name has cloth") is not None, "the scan search knows have too")
    holders = ns.where.holdersText(2589)
    check(holders.startswith("You ") and "Mara 40 (40 bank)" in holders, f"holders: {holders}")

    # Buy this list counts your mail and your alts' bags, bank and mail on top of the game's count
    lua.execute("MOCK_BAGS[2589] = 28")
    try:
        run(source_of("BuyList.lua"), "BuyList.lua", "EverlookDBAuctions", ns)
        have = ns.buyList.haveOf(2589)
        check(have == 28 + 100 - 28 - 20 + 0, f"Buy this list: bags 28 + Mara 40 + Thorn 12 = {have}")
        G.EverlookCraftDB = lua.eval("{ settings = { noAlts = true } }")
        check(ns.buyList.haveOf(2589) == 28, "Crafting's 'don't count my alts' is followed")
        G.EverlookCraftDB = None
    except Exception as e:  # noqa: BLE001
        failures.append(f"inventory: BuyList.lua didn't load here: {e}")

    # the seed from EverlookDB Crafting: characters this store hasn't seen
    cdb = lua.eval("""{ chars = { ["Player-6946-9"] = { name = "Old", realmID = 6946, side = "a", bags = { [2589] = 3 }, bank = { [2592] = 2 } },
      ["Player-6946-1"] = { name = "Mara", realmID = 6946, side = "a", bags = { [2589] = 1000 } } } }""")
    n = I.seed(cdb)
    check(n == 1 and s.chars["Old-6946"].bags[2589] == 3 and s.chars["Old-6946"].faction == "Alliance", "seeded once")
    check(s.chars["Mara-6946"].bags is None, "a character already here isn't overwritten")
    check(I.seed(cdb) == 0, "only once")

    # the API: copies, read-only
    api = G.EverlookDBAuctionsAPI
    check(api.version == 7 and api.inventory.version == 1, "API v7 with inventory")
    c = api.inventory.count(2589)
    c.total = -1
    check(I.count(2589).total != -1, "count is a copy")
    check(api.inventory.usable("item:2589") == I.usable(2589), "usable by link")
    bags = api.inventory.bagsOf("Old", 6946)
    check(bags[2589] == 3 and api.inventory.bagsOf("Nobody", 6946) is None, "bagsOf")
    chars = api.inventory.characters()
    check(chars[1].me and chars[1].name == "Anna", "characters, you first")
    lua.execute("INV_SEEN = 0")
    api.inventory.onChange(lua.eval("function() INV_SEEN = INV_SEEN + 1 end"))
    I.changed()
    check(G.INV_SEEN == 1, "onChange")
    okw = lua.eval("function(t) return (pcall(function() t.x = 1 end)) end")(api.inventory)
    check(okw is False, "read-only")

    # forgetting a character (Gear upgrades' Forget)
    ns.upChars.forget("Old-6946")
    check(s.chars["Old-6946"] is None, "forgotten with Gear upgrades' Forget")

    # logout: the game has often emptied the bags, the gear and the gold by then (2026-11-27: every alt saved with
    # nothing and 0 gold); an empty read at logout keeps what was read during play
    G.BAGS = lua.eval("{ [0] = { { 2589, 20 } }, [1] = { { 7001, 1 } } }")
    G.WORN = lua.eval("{ [16] = 3000 }")
    G.MONEY = 7896
    fire("BAG_UPDATE_DELAYED"); fire("PLAYER_MONEY"); fire("PLAYER_EQUIPMENT_CHANGED")
    check(me.bags[2589] == 20 and me.money == 7896 and me.worn[3000] == 1, "read during play")
    G.BAGS = lua.eval("{}")
    G.WORN = lua.eval("{}")
    G.MONEY = 0
    fire("PLAYER_LOGOUT")
    check(me.bags is not None and me.bags[2589] == 20, f"an empty read at logout keeps the bags: {me.bags}")
    check(me.worn is not None and me.worn[3000] == 1, "an empty read at logout keeps the gear")
    check(me.money == 7896, f"0 gold at logout keeps the gold: {me.money}")
    I.changed()
    mine = I.count(2589).chars[1]
    check(mine.me and mine.bags == 20, f"what you have still counts it (shopping lists): {mine.bags}")
    total, golds = I.gold()
    check(any(golds[i].name == "Anna" and golds[i].money == 7896 for i in range(1, len(golds) + 1)), "the gold line keeps it")
    # a real read at logout still counts (a sale or a trade in the last second)
    G.BAGS = lua.eval("{ [0] = { { 2589, 5 } } }")
    G.WORN = lua.eval("{ [16] = 3000, [1] = 3001 }")
    G.MONEY = 8000
    fire("PLAYER_LOGOUT")
    check(me.bags[2589] == 5 and me.money == 8000 and me.worn[3001] == 1, "a logout read that found things is saved")
    # during play, empty bags are empty (sold everything)
    G.BAGS = lua.eval("{}")
    fire("BAG_UPDATE_DELAYED")
    check(me.bags is None, "empty bags during play are saved as empty")

    # records already wiped by an older version: their 0 gold isn't real
    lua2 = lua51.LuaRuntime(unpack_returned_tuples=True)
    lua2.execute(source_of("tests/mock.lua"))
    ns2 = lua2.table()
    lua2.execute("""INVDB = { inv = { chars = {
      ["Fake-6946"] = { name = "Fake", realmID = 6946, money = 0, moneyAt = 5, bagsAt = 5 },
      ["Poor-6946"] = { name = "Poor", realmID = 6946, money = 0, bags = { [2589] = 1 } },
      ["Isa-6946"] = { name = "Isa", realmID = 6946, money = 315581, bags = { [2589] = 1 } } } } }""")
    ns2.db = lua2.eval("function() return INVDB end")
    run2 = lua2.eval("function(src, name, ...) local f = assert(loadstring(src, name)); return f(...) end")
    run2(source_of("Inventory.lua"), "Inventory.lua", "EverlookDBAuctions", ns2)
    s2 = ns2.inventory.store()
    fake = s2.chars["Fake-6946"]
    check(fake.money is None and fake.wiped is True, "a wiped record (nothing worn, no bags, 0 gold) loses its 0 gold")
    check(s2.chars["Poor-6946"].money == 0 and s2.chars["Isa-6946"].money == 315581, "other records keep their gold")
    fake.money = 0
    ns2.inventory.store()
    check(fake.money == 0, "only once")
    return failures
