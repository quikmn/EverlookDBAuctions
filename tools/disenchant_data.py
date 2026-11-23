"""Write Disenchant.lua: which items can be disenchanted, and what each kind of item gives.

    python -I tools/disenchant_data.py --tables <ForeverMiner out/tables> --enchantrix <DisenchantList.lua>
        --classicdb <classicdb.sqlite or ClassicDB_*.sql.gz> [--vmangos <mangos.sqlite>] [--site <Quarry dir>]
        [--addon <addon dir>]

Sources, in this order of trust (players' own disenchants, from the Price Feed, come before all of them in game):
  - The WoW Forever client (ForeverMiner's ItemDisenchantLoot, Item and ItemSparse): which (item class, quality,
    item level) brackets exist, each one's loot ID, and which items fall in one. An item flagged 0x8000 in
    ItemSparse Flags[0] can't be disenchanted (of the 5,118 items Enchantrix measured, one carries the flag).
    Shields and off-hands are armor, as the client says and as the measurements show.
  - Enchantrix 3.9.0 (Norganna's AddOns, GPL-2.0-or-later) DisenchantList.lua: disenchants its players counted in
    vanilla, per item. Read as data. Cleaned: only items whose quality and item-level bracket are the same in
    classic-db (1.12) as in WoW Forever count; a material outside what classic-db gives for that bracket is
    dropped, except Greater Magic Essence from uncommon weapons of item level 21-30 (measured, classic-db says
    Astral); epics of item level 56 and up are left out (measured before the Nexus Crystal change).
  - classic-db (CMaNGOS, GPL-3.0): a bracket's chances where Enchantrix has too few disenchants.
  - VMaNGOS (GPL-2.0-or-later), optional: printed where it disagrees with classic-db on a bracket that uses
    classic-db's chances. Only a check, nothing of it is written.
  - Disenchantry 1.3.0 (x_Raven_x, MIT, based on Disenchant Helper by Rakuga, MIT;
    https://www.curseforge.com/wow/addons/disenchantry; licence in THIRD-PARTY-NOTICES.md): its rough estimate for the
    rare brackets WoW Forever added (item level 5-15 and 16-20), which nothing above has odds for. The lowest source:
    source "d", "a rough estimate". Only those brackets are taken from it.
The count ranges (min-max) of measured materials are classic-db's for that bracket (else the material's most common
range in classic-db at that quality) when the measured average falls inside it; the average still gives the value.

Writes Disenchant.lua into the addon, and with --site the site's web/disenchant.js (brackets) and
web/data/disenchant.json (brackets, items, per-item odds; game data, not committed).
"""
import argparse
import csv
import gzip
import json
import re
import sqlite3
import sys
from collections import Counter, defaultdict
from pathlib import Path

ap = argparse.ArgumentParser()
ap.add_argument("--tables", required=True, type=Path)
ap.add_argument("--enchantrix", required=True, type=Path)
ap.add_argument("--classicdb", required=True, type=Path)
ap.add_argument("--vmangos", type=Path)
ap.add_argument("--site", type=Path)
ap.add_argument("--addon", type=Path, default=Path(__file__).resolve().parents[1])
args = ap.parse_args()

NO_DISENCHANT = 0x8000          # ItemSparse Flags[0]
NEW_IN_FOREVER = {335, 336, 337, 338}   # loot IDs Classic Era's client doesn't have: no classic odds fit them
BRACKET_MIN_N = 200             # Enchantrix disenchants a bracket needs, over at least BRACKET_MIN_ITEMS items
BRACKET_MIN_ITEMS = 3
ITEM_MIN_N = 200                # an item's own Enchantrix disenchants needed to list it on its own
ITEM_MAX_DROPPED = 0.10         # an item with more of its disenchants dropped as strays is left out
ITEM_DIFF = 0.15                # list an item on its own when its chances differ from its bracket's by this much
ITEM_COUNT_DIFF = 0.30          # or a main material's average count by this share
GME, ASTRAL = 10939, (10998, 11082)


# Disenchantry 1.3.0, ForecastPolicy.lua (Copyright (c) 2026 x_Raven_x, Copyright (c) 2026 Rakuga, MIT): its estimate
# for WoW Forever's new rare brackets. Weapons give the essence where armor gives the dust. (material, chance %, min, max)
def disenchantry_estimate(cls, lo):
    weapon = cls == 2
    if lo <= 15:
        return [(10940, 20 if weapon else 80, 2, 3), (10938, 80 if weapon else 20, 2, 3)]
    return [(10940, 20 if weapon else 75, 3, 4), (10939, 75 if weapon else 20, 2, 3), (10978, 5, 2, 2)]


def rows(path):
    with path.open(encoding="utf-8") as f:
        yield from csv.DictReader(f)


# ------------------------------------------------------------------ the client
brackets = {}   # loot ID -> (cls, q, lo, hi)
for r in rows(args.tables / "ItemDisenchantLoot.csv"):
    brackets[int(r["ID"])] = (int(r["Class"]), int(r["Quality"]), int(r["MinLevel"]), int(r["MaxLevel"]))
by_cq = defaultdict(list)
for lid, (cls, q, lo, hi) in brackets.items():
    by_cq[cls, q].append((lo, hi, lid))


def bracket_of(cls, q, ilvl):
    for lo, hi, lid in by_cq.get((cls, q), ()):
        if lo <= ilvl <= hi:
            return lid
    return None


item_class = {int(r["ID"]): int(r["ClassID"]) for r in rows(args.tables / "Item.csv")}
sparse = {int(r["ID"]): (int(r["ItemLevel"]), int(r["OverallQualityID"]), int(r["Flags[0]"])) for r in rows(args.tables / "ItemSparse.csv")}
items = {}      # item -> loot ID: every item WoW Forever lets you disenchant
for i, (ilvl, q, flags) in sparse.items():
    cls = item_class.get(i)
    if cls in (2, 4) and 2 <= q <= 4 and not flags & NO_DISENCHANT:
        lid = bracket_of(cls, q, ilvl)
        if lid:
            items[i] = lid


# ------------------------------------------------------------------ classic-db
def sql_tuples(line):
    """The value tuples of one INSERT INTO ... VALUES (...),(...); line of a dump, as lists of strings."""
    i, n = line.index("VALUES") + 6, len(line)
    while i < n:
        while i < n and line[i] != "(":
            i += 1
        if i >= n:
            return
        i += 1
        vals, cur, quoted = [], [], False
        while i < n:
            c = line[i]
            if quoted:
                if c == "\\":
                    cur.append(line[i + 1])
                    i += 2
                    continue
                if c == "'":
                    quoted = False
                else:
                    cur.append(c)
            elif c == "'":
                quoted = True
            elif c == ",":
                vals.append("".join(cur))
                cur = []
            elif c == ")":
                vals.append("".join(cur))
                i += 1
                break
            else:
                cur.append(c)
            i += 1
        yield vals


def classic_db(path):
    """classic-db's items {entry: (quality, item level, DisenchantID)} and loot rows {DisenchantID: [(item, chance,
    group, min, max)]}, from Quarry's SQLite import or the Full_DB dump."""
    if path.suffix == ".sqlite":
        c = sqlite3.connect(path)
        it = {e: (q, il, d) for e, q, il, d in c.execute("select entry, Quality, ItemLevel, DisenchantID from item_template")}
        loot = defaultdict(list)
        for e, m, ch, g, lo, hi in c.execute("select entry, item, ChanceOrQuestChance, groupid, mincountOrRef, maxcount from disenchant_loot_template"):
            loot[e].append((m, ch, g, lo, hi))
        return it, loot
    with gzip.open(path, "rt", encoding="utf-8", errors="replace") as f:
        lines = f.readlines()

    def columns(table):
        cols, inside = [], False
        for line in lines:
            if line.startswith(f"CREATE TABLE `{table}`"):
                inside = True
            elif inside:
                s = line.strip()
                if not s.startswith("`"):
                    return cols
                cols.append(s.split("`")[1])
        return cols
    ic, dc = columns("item_template"), columns("disenchant_loot_template")
    I = [ic.index(c) for c in ("entry", "Quality", "ItemLevel", "DisenchantID")]
    D = [dc.index(c) for c in ("entry", "item", "ChanceOrQuestChance", "groupid", "mincountOrRef", "maxcount")]
    it, loot = {}, defaultdict(list)
    for line in lines:
        if line.startswith("INSERT INTO `item_template`"):
            for v in sql_tuples(line):
                it[int(v[I[0]])] = (int(v[I[1]]), int(v[I[2]]), int(v[I[3]]))
        elif line.startswith("INSERT INTO `disenchant_loot_template`"):
            for v in sql_tuples(line):
                loot[int(v[D[0]])].append((int(v[D[1]]), float(v[D[2]]), int(v[D[3]]), int(v[D[4]]), int(v[D[5]])))
    return it, loot


def chances(loot):
    """Per loot entry [(material, chance %, min, max)], as the core rolls them: group 0 rolls every row on its own; in
    another group one row drops, the ones with a chance first and the ones without sharing what is left equally. An
    entry whose chances don't add up to 100% is missing rows and left out."""
    out = {}
    for e, rs in loot.items():
        if any(r[3] < 0 for r in rs):
            sys.exit("references in disenchant_loot_template are not handled")
        mats, whole = [], True
        for g in sorted({r[2] for r in rs}):
            part = [r for r in rs if r[2] == g]
            if g == 0:
                mats += [(r[0], r[1], r[3], r[4]) for r in part]
                continue
            fixed = sum(r[1] for r in part if r[1] > 0)
            rest = [r for r in part if r[1] == 0]
            share = max(0.0, 100.0 - fixed) / len(rest) if rest else 0
            mats += [(r[0], r[1] if r[1] > 0 else share, r[3], r[4]) for r in part]
            whole = whole and fixed + share * len(rest) >= 99.9
        if whole:
            out[e] = sorted(mats, key=lambda m: (-m[1], m[0]))
    return out


def family(table):
    """classic-db's disenchant entries by quality: 1-31 uncommon, 41-50 rare, 61-65 epic."""
    return 2 if table < 40 else 3 if table < 60 else 4


cdb_items, cdb_loot = classic_db(args.classicdb)
cdb_groups = chances(cdb_loot)
# a bracket's classic-db entry: the one most of its items have in classic-db (same quality there, an entry of that
# quality); every entry its items use, for which materials are real
votes = defaultdict(Counter)
for i, lid in items.items():
    ci = cdb_items.get(i)
    if ci and ci[2] in cdb_groups and ci[0] == brackets[lid][1] and family(ci[2]) == ci[0]:
        votes[lid][ci[2]] += 1
classic = {lid: v.most_common(1)[0][0] for lid, v in votes.items() if lid not in NEW_IN_FOREVER}
allowed = {}
for lid, v in votes.items():
    cls, q, lo, hi = brackets[lid]
    mats = {m for t in v for m in (x[0] for x in cdb_groups[t])}
    if cls == 2 and q == 2 and lo >= 21 and hi <= 30:
        mats = (mats - set(ASTRAL)) | {GME}
    allowed[lid] = mats


# ------------------------------------------------------------------ Enchantrix
text = args.enchantrix.read_text(encoding="utf-8")
enx = {}
for m in re.finditer(r'\[(\d+)\] = "([^"]*)"', text):
    d = {}
    for part in filter(None, m.group(2).split(";")):
        mat, n_de, n_qty, _ = part.split(":")
        d[int(mat)] = (int(n_de), int(n_qty))
    enx[int(m.group(1))] = d
print(f"Enchantrix: {len(enx)} items, {sum(n for d in enx.values() for n, _ in d.values())} disenchants")

usable, why = {}, Counter()   # item -> {mat: (n_de, n_qty)}, cleaned
for i, d in enx.items():
    lid = items.get(i)
    ci = cdb_items.get(i)
    if not lid:
        why["not disenchantable in WoW Forever"] += 1
        continue
    cls, q, lo, hi = brackets[lid]
    if lid in NEW_IN_FOREVER or (q == 4 and lo >= 56):
        why["a new bracket, or an epic of item level 56+"] += 1
        continue
    if not ci or ci[0] != q or bracket_of(cls, ci[0], ci[1]) != lid:
        why["quality or item level changed since 1.12"] += 1
        continue
    keep = {m: v for m, v in d.items() if m in allowed.get(lid, ())}
    total, kept = sum(v[0] for v in d.values()), sum(v[0] for v in keep.values())
    if not kept or (total - kept) / total > ITEM_MAX_DROPPED:
        why["too many strays"] += 1
        continue
    usable[i] = keep
print(f"Enchantrix items used: {len(usable)}; left out: {dict(why)}")


def odds(d):
    """{mat: (n_de, n_qty)} -> n, [(mat, chance 0-1, average count)], most likely first."""
    n = sum(v[0] for v in d.values())
    return n, sorted(((m, v[0] / n, v[1] / v[0]) for m, v in d.items() if v[0] > 0), key=lambda x: (-x[1], x[0]))


pooled, pooled_items = defaultdict(lambda: defaultdict(lambda: [0, 0])), Counter()
for i, d in usable.items():
    lid = items[i]
    pooled_items[lid] += 1
    for m, (n, c) in d.items():
        pooled[lid][m][0] += n
        pooled[lid][m][1] += c

# ------------------------------------------------------------------ brackets: measured, estimate or nothing
# a material's usual count range in classic-db at each quality: the range it has most often there
usual_range = defaultdict(Counter)
for t, mats in cdb_groups.items():
    for m, _, lo, hi in mats:
        usual_range[family(t), m][lo, hi] += 1


def count_range(lid, m, avg):
    """classic-db's min and max count of a material in this bracket (else its usual one at this quality), when the
    measured average falls inside it; else the average as both."""
    rng = next(((lo, hi) for mm, _, lo, hi in cdb_groups.get(classic.get(lid), ()) if mm == m), None)
    if not rng and usual_range.get((brackets[lid][1], m)):
        rng = usual_range[brackets[lid][1], m].most_common(1)[0][0]
    if rng and rng[0] - 0.05 <= avg <= rng[1] + 0.05:
        return rng
    return round(avg, 2), round(avg, 2)


kinds = {}      # loot ID -> (source "m" / "e" / "d" / "", n, [(mat, chance %, min, max, average count)])
for lid in sorted(brackets):
    n, o = odds(pooled[lid]) if lid in pooled else (0, [])
    if n >= BRACKET_MIN_N and pooled_items[lid] >= BRACKET_MIN_ITEMS:
        kinds[lid] = ("m", n, [(m, round(p * 100, 1), *count_range(lid, m, c), round(c, 2)) for m, p, c in o if round(p * 100, 1) > 0])
    elif lid in classic:
        kinds[lid] = ("e", 0, [(m, round(p, 3), lo, hi, (lo + hi) / 2) for m, p, lo, hi in cdb_groups[classic[lid]]])
    elif lid in NEW_IN_FOREVER and brackets[lid][1] == 3:
        cls, _, lo, _ = brackets[lid]
        kinds[lid] = ("d", 0, sorted(((m, p, a, b, (a + b) / 2) for m, p, a, b in disenchantry_estimate(cls, lo)), key=lambda x: (-x[1], x[0])))
    else:
        kinds[lid] = ("", 0, [])

# per item: enough disenchants, and different from its bracket
item_odds = {}
for i, d in usable.items():
    n, o = odds(d)
    src, _, base = kinds[items[i]]
    if n < ITEM_MIN_N or src != "m":
        continue
    bp = {m: p / 100 for m, p, _, _, _ in base}
    bc = {m: c for m, _, _, _, c in base}
    ip = {m: p for m, p, _ in o}
    diff = sum(abs(ip.get(m, 0) - bp.get(m, 0)) for m in set(ip) | set(bp)) / 2
    count_diff = max((abs(c - bc[m]) / bc[m] for m, p, c in o if p >= 0.1 and m in bc), default=0)
    if diff >= ITEM_DIFF or count_diff >= ITEM_COUNT_DIFF:
        item_odds[i] = (n, [(m, round(p * 100, 1), round(c, 2)) for m, p, c in o if round(p * 100, 1) > 0])

# ------------------------------------------------------------------ checks
print("\nbrackets (loot ID, class, quality, item levels: source, disenchants, materials):")
for lid, (src, n, mats) in sorted(kinds.items(), key=lambda kv: (brackets[kv[0]][1], brackets[kv[0]][0], brackets[kv[0]][2])):
    cls, q, lo, hi = brackets[lid]
    print(f"  {lid:3} {cls} {q} {lo:2}-{hi:<2} {src or '-'} {n:7}  " + ", ".join(f"{m} {p}% x{a}" + ("" if a == b else f"-{b}") + (f" (avg {c})" if src == "m" else "") for m, p, a, b, c in mats))
if args.vmangos:
    v = sqlite3.connect(args.vmangos)
    vit = {e: d for e, d in v.execute("select entry, disenchant_id from item_template where disenchant_id > 0 group by entry having patch = max(patch)")}
    vloot = defaultdict(list)
    for e, m, ch, g, lo, hi, pmin, pmax in v.execute("select entry, item, ChanceOrQuestChance, groupid, mincountOrRef, maxcount, patch_min, patch_max from disenchant_loot_template"):
        if pmax >= 10:
            vloot[e].append((m, ch, g, lo, hi))
    vgroups = chances(vloot)
    print("\nVMaNGOS against classic-db, brackets on classic-db's chances:")
    for lid, (src, _, mats) in sorted(kinds.items()):
        if src != "e":
            continue
        vv = Counter(vit[i] for i in items if items[i] == lid and i in vit)
        vt = vv.most_common(1)[0][0] if vv else None
        got = sorted((m, round(p, 3), lo, hi) for m, p, lo, hi in vgroups.get(vt, []))
        if got != sorted(tuple(m[:4]) for m in mats):
            print(f"  {lid} {brackets[lid]}: classic-db {sorted(mats)}  VMaNGOS {got}")
print(f"\n{len(items)} items, {len(item_odds)} with their own measured odds")

# ------------------------------------------------------------------ the addon
def b36(n):
    s = ""
    while True:
        n, r = divmod(n, 36)
        s = "0123456789abcdefghijklmnopqrstuvwxyz"[r] + s
        if not n:
            return s


def num(x):
    return "%g" % x


by_kind = defaultdict(list)
for i, lid in items.items():
    by_kind[lid].append(i)
packed = []
for lid in sorted(by_kind):
    ids, prev, gaps = sorted(by_kind[lid]), 0, []
    for i in ids:
        gaps.append(b36(i - prev))
        prev = i
    packed.append(f'[{lid}]="' + ",".join(gaps) + '",')
kind_lines = []
for lid in sorted(kinds):
    cls, q, lo, hi = brackets[lid]
    src, _, mats = kinds[lid]
    # a measured material carries its average count as a fifth number (min and max are the range it comes in)
    kind_lines.append(f"[{lid}]={{{cls},{q},{lo},{hi},{json.dumps(src) if src else 'false'}" + "".join(
        f",{{{m},{num(p)},{num(a)},{num(b)}" + (f",{num(c)}" if src == "m" else "") + "}" for m, p, a, b, c in mats) + "},")
odds_lines = [f"[{i}]={{{n}" + "".join(f",{m},{num(p)},{num(c)}" for m, p, c in mats) + "}," for i, (n, mats) in sorted(item_odds.items())]
out = args.addon / "Disenchant.lua"
out.write_text(
    "-- Generated by tools/disenchant_data.py. Do not edit. Brackets and items from the WoW Forever client (build "
    + (args.tables / "build.txt").read_text().strip() + ");\n"
    "-- odds from Enchantrix (Norganna's AddOns, GPL-2.0-or-later), disenchants counted in vanilla, and from\n"
    "-- classic-db (CMaNGOS, GPL-3.0, https://github.com/cmangos/classic-db) where Enchantrix has too few; for the rare\n"
    "-- brackets new in WoW Forever, Disenchantry 1.3.0's rough estimate (x_Raven_x, based on Disenchant Helper by\n"
    "-- Rakuga; both MIT, see THIRD-PARTY-NOTICES.md).\n"
    "local _, ns = ...\n"
    "-- [loot ID] = { item class, quality, low, high, source, { material, chance %, min, max[, average] }, ... }: per\n"
    "-- bracket of the client. source \"m\": measured (Enchantrix; min-max is classic-db's range, the fifth number the\n"
    "-- measured average count), \"e\": estimate (classic-db), \"d\": a rough estimate (Disenchantry), false: not\n"
    "-- measured yet (no odds anywhere).\n"
    "ns.DE_KINDS = {\n" + "\n".join(kind_lines) + "\n}\n"
    "-- [item] = { disenchants, material, chance %, average count, ... }: items Enchantrix measured often enough whose\n"
    "-- odds differ from their bracket's.\n"
    "ns.DE_ITEM_ODDS = {\n" + "\n".join(odds_lines) + "\n}\n"
    "-- the items that can be disenchanted, per loot ID: item IDs in base 36, each as the gap from the one before\n"
    "local packed = {\n" + "\n".join(packed) + "\n}\n"
    "local items = {}\n"
    "for kind, s in pairs(packed) do\n"
    "  local id = 0\n"
    '  for gap in s:gmatch("[^,]+") do\n'
    "    id = id + tonumber(gap, 36)\n"
    "    items[id] = kind\n"
    "  end\n"
    "end\n"
    "ns.DE_ITEMS = items -- item -> loot ID\n",
    encoding="utf-8", newline="\n")
print(f"-> {out} ({out.stat().st_size / 1e3:.1f} KB)")

# ------------------------------------------------------------------ the site
if args.site:
    de = defaultdict(lambda: defaultdict(list))
    for lid in sorted(kinds, key=lambda k: brackets[k][2]):
        cls, q, lo, hi = brackets[lid]
        src, _, mats = kinds[lid]
        if src == "d":   # the site keeps "not measured yet" for these
            src, mats = "", []
        de[str(cls)][str(q)].append([lo, hi, [[round(p / 100, 4), round(c, 2), m] for m, p, a, b, c in mats], src])
    js = args.site / "web" / "disenchant.js"
    js.write_text(
        "// Generated by EverlookDB Auctions' tools/disenchant_data.py. Do not edit.\n"
        "// Disenchanting outcomes by item class (2 weapon, 4 armor: shields and off-hands are armor), quality (2 uncommon,\n"
        "// 3 rare, 4 epic) and item level, in the WoW Forever client's brackets: [lo, hi, [[chance, average count, item]...],\n"
        "// source]. source 'm': measured in vanilla (Enchantrix, Norganna's AddOns, GPL-2.0-or-later), 'e': estimate\n"
        "// (classic-db, CMaNGOS, GPL-3.0), '': can be disenchanted, not measured yet (no materials).\n"
        "export const DE = " + json.dumps(de, separators=(",", ":")) + ";\n\n"
        "/** Expected disenchant materials for an item: [[item, expected count]...], or null when it can't be disenchanted\n"
        " * or nobody has measured what it gives. */\n"
        "export function deMats(cls, quality, ilvl) {\n"
        "  const row = (DE[cls]?.[quality] || []).find(([lo, hi]) => ilvl >= lo && ilvl <= hi);\n"
        "  return row && row[2].length ? row[2].map(([p, n, id]) => [id, p * n]) : null;\n"
        "}\n",
        encoding="utf-8", newline="\n")
    data = {
        "v": 1,
        "build": (args.tables / "build.txt").read_text().strip(),
        "kinds": {str(lid): {"cls": brackets[lid][0], "q": brackets[lid][1], "lo": brackets[lid][2], "hi": brackets[lid][3],
                             "src": "" if src == "d" else src, "n": n,
                             "mats": [] if src == "d" else [[m, p, c, c] if src == "m" else [m, p, a, b] for m, p, a, b, c in mats]}
                  for lid, (src, n, mats) in sorted(kinds.items())},
        "items": {str(i): lid for i, lid in sorted(items.items())},
        "item_odds": {str(i): {"n": n, "mats": [[m, p, c] for m, p, c in mats]} for i, (n, mats) in sorted(item_odds.items())},
    }
    dj = args.site / "web" / "data" / "disenchant.json"
    dj.write_text(json.dumps(data, separators=(",", ":")), encoding="utf-8", newline="\n")
    print(f"-> {js} ({js.stat().st_size / 1e3:.1f} KB), {dj} ({dj.stat().st_size / 1e3:.1f} KB)")
