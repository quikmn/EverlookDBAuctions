"""Builds UpgradesData.lua, the built-in data of the gear upgrades (Upgrades.lua): stat weights per class, spec and
level bracket, talent effects, item procs and rating conversions.

Sources (both MIT licensed; credited in README.md and on the Gear upgrades settings page):
  - wowsims/forever (https://github.com/wowsims/forever, MIT): the level-60 stat weights. Its UI's EP presets
    (ui/specs/*/presets.ts, druid/feral_ep.ts), its own stat-weight sims for the specs that have no preset
    (tools/upgrades/sim_weights.json, run with its test harness), its rating constants (sim/core/base_stats_auto_gen.go),
    talent effects and item procs read from its Go sources (tools/upgrades/talents.json, tools/upgrades/procs.json).
  - Forever Leveling BiS v0.12.0-beta (MIT, Copyright (c) 2026 Thunder), Data/ModelWeights.lua only: its per-level
    model, for the brackets below 60 (wowsims sims level 60 only) and for specs wowsims has no weights for. Read from
    the release zip; nothing else from that addon is used.

Each spec gets brackets { upTo = 9, 14, ..., 59, 60 }: 60 from wowsims where it has the spec, the levels below from
the model rescaled so that its level-60 values meet wowsims' (per stat; where the model's 60 value is tiny the
model's own shape is used as it is). Brackets that aren't a wowsims number are marked src = "model" (estimates).

The data file's contract (Upgrades.lua reads only this, so other weights can replace these later): per class and
spec, brackets = { { upTo = <level>, src = "simulated" | "estimate", scenario = "raid" | "solo" | "dungeon" | nil,
w = { stat = weight }, se = { stat = standard error }, est = { stat = true } } } (est: stats of a simulated bracket
that are still estimates), weights in units of the spec's reference stat. A spec may
have several brackets with the same upTo, one per scenario. "simulated" brackets come from a sim (se where the sim
gave one); "estimate" brackets are the model's and say so in the game.

Levelling builds (a BM hunter with a melee two-hander, spell-power Protection paladin, ...) are specs too, with
build = true and a note: tools/upgrades/builds.json lists them with the weights they use until sims cover them.

Our own sims (plans/stat-weight-sims-2026-11-21.md) drop in as tools/upgrades/sims/*.json, one per class, spec,
bracket and scenario: { "class": "WARRIOR", "spec": "fury", "upTo": 60, "scenario": "raid", "reference":
"AttackPower", "stats": { "Strength": { "weight": 2.4, "stderr": 0.03 }, ... } } (proto stat names, as wowsims').
Each replaces the bracket of that spec, level and scenario (or adds it).

Usage: python -P tools/gen_upgrades.py --wowsims <clone of wowsims/forever> --model <ForeverLevelingBiS zip>
       [--report <file>]   (where the two disagree a lot at level 60)
"""
import argparse
import json
import re
import subprocess
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
INPUTS = ROOT / "tools" / "upgrades"

WS_STAT = {
    "StatStrength": "str", "StatAgility": "agi", "StatStamina": "sta", "StatIntellect": "int", "StatSpirit": "spi",
    "StatAttackPower": "ap", "StatRangedAttackPower": "rap", "StatFeralAttackPower": "fap",
    "StatSpellDamage": "sp", "StatArcaneDamage": "sp_arcane", "StatFireDamage": "sp_fire", "StatFrostDamage": "sp_frost",
    "StatHolyDamage": "sp_holy", "StatNatureDamage": "sp_nature", "StatShadowDamage": "sp_shadow",
    "StatHealingPower": "heal", "StatHitRating": "hit", "StatCritRating": "crit", "StatHasteRating": "haste",
    "StatExpertiseRating": "exp", "StatArmorPenetration": "arp", "StatSpellPiercing": "spen",
    "StatDefenseRating": "def", "StatDodgeRating": "dodge", "StatParryRating": "parry", "StatBlockRating": "block",
    "StatBlockValue": "bv", "StatArmor": "armor", "StatHealth": "health", "StatMana": "mana", "StatMP5": "mp5",
    "PseudoStatMainHandDps": "mhdps", "PseudoStatOffHandDps": "ohdps", "PseudoStatRangedDps": "rdps",
}
# the sims' JSON uses the proto names without the Stat prefix
WS_SHORT = {k.replace("PseudoStat", "").replace("Stat", "", 1): v for k, v in WS_STAT.items()}

MODEL_STAT = {
    "str": "str", "agi": "agi", "sta": "sta", "int": "int", "spi": "spi", "atkpwr": "ap", "rgdatkpwr": "rap",
    "feratkpwr": "fap", "spldmg": "sp", "splheal": "heal", "arcsplpwr": "sp_arcane", "firsplpwr": "sp_fire",
    "frosplpwr": "sp_frost", "holsplpwr": "sp_holy", "natsplpwr": "sp_nature", "shasplpwr": "sp_shadow",
    "hitrtng": "hit", "critstrkrtng": "crit", "hastertng": "haste", "exprtng": "exp", "defrtng": "def",
    "dodgertng": "dodge", "parryrtng": "parry", "blockrtng": "block", "block": "bv", "armor": "armor",
    "manargn": "mp5", "dps": "mhdps", "rangedDps": "rdps",
}
DUAL_WIELD = {"WARRIOR", "ROGUE", "HUNTER"}

# class, our key, name, role, wowsims source, model spec. A wowsims source is ("preset", file, variable),
# ("sim", key in sim_weights.json) or None (the model alone).
SPECS = [
    ("WARRIOR", "arms", "Arms", "melee", ("preset", "warrior/dps/presets.ts", "PreBiSArmsEpWeights"), "arms"),
    ("WARRIOR", "fury", "Fury", "melee", ("preset", "warrior/dps/presets.ts", "PreBiSFuryEpWeights"), "fury"),
    ("WARRIOR", "protection", "Protection", "tank", ("preset", "warrior/protection/presets.ts", "PreBiSBalancedEpWeights"), "protection"),
    ("PALADIN", "holy", "Holy", "healer", None, "holy"),
    # wowsims' prot paladin sim (tools/upgrades/sim_weights.json) weighs damage only: Defense, Dodge and Parry come
    # out negative there. A tank shopping for gear wants them, so the model is used for every level.
    ("PALADIN", "protection", "Protection", "tank", None, "protection"),
    ("PALADIN", "retribution", "Retribution", "melee", ("preset", "paladin/retribution/presets.ts", "UnsealedWrathEpWeights"), "retribution"),
    ("HUNTER", "beastmastery", "Beast Mastery", "ranged", ("preset", "hunter/dps/presets.ts", "TurretEpWeights"), "beastmastery"),
    ("HUNTER", "marksmanship", "Marksmanship", "ranged", ("preset", "hunter/dps/presets.ts", "TurretEpWeights"), "marksmanship"),
    ("HUNTER", "survival", "Survival", "ranged", ("preset", "hunter/dps/presets.ts", "WeaveEpWeights"), "survival"),
    ("HUNTER", "survivalmelee", "Survival (melee)", "melee", ("preset", "hunter/dps/presets.ts", "MeleeEpWeights"), "survivalmelee"),
    ("ROGUE", "assassination", "Assassination", "melee", ("preset", "rogue/dps/presets.ts", "EP_PRESET_ASSASSINATION"), "assassination"),
    ("ROGUE", "combat", "Combat", "melee", ("preset", "rogue/dps/presets.ts", "EP_PRESET_COMBAT_SINISTER"), "combat"),
    ("ROGUE", "subtlety", "Subtlety", "melee", ("preset", "rogue/dps/presets.ts", "EP_PRESET_SUBTLETY"), "subtlety"),
    ("PRIEST", "discipline", "Discipline", "healer", ("preset", "priest/healer/presets.ts", "DiscRaidHealingEpWeights"), "discipline"),
    ("PRIEST", "holy", "Holy", "healer", ("preset", "priest/healer/presets.ts", "HolyRaidHealingEpWeights"), "holy"),
    ("PRIEST", "shadow", "Shadow", "caster", ("preset", "priest/dps/presets.ts", "ShadowEpWeights"), "shadow"),
    ("SHAMAN", "elemental", "Elemental", "caster", ("preset", "shaman/elemental/presets.ts", "DefaultEpWeights"), "elemental"),
    ("SHAMAN", "enhancement", "Enhancement", "melee", ("preset", "shaman/enhancement/presets.ts", "PreBiSEpWeights"), "enhancement"),
    ("SHAMAN", "restoration", "Restoration", "healer", None, "restoration"),
    ("MAGE", "arcane", "Arcane", "caster", ("sim", "mage_arcane"), "arcane"),
    ("MAGE", "fire", "Fire", "caster", ("sim", "mage_fire"), "fire"),
    ("MAGE", "frost", "Frost", "caster", ("sim", "mage_frost"), "frost"),
    ("WARLOCK", "affliction", "Affliction", "caster", ("sim", "warlock_affliction"), "affliction"),
    ("WARLOCK", "demonology", "Demonology", "caster", ("sim", "warlock_demonology"), "demonology"),
    ("WARLOCK", "destruction", "Destruction", "caster", ("sim", "warlock_destruction"), "destruction"),
    ("DRUID", "balance", "Balance", "caster", ("preset", "druid/balance/presets.ts", "P1EpWeights"), "balance"),
    ("DRUID", "feral", "Feral (cat)", "melee", ("preset", "druid/feral_ep.ts", "CatEp"), "feral"),
    ("DRUID", "bear", "Feral (bear)", "tank", ("preset", "druid/feral_ep.ts", "BearEp"), "bear"),
    ("DRUID", "restoration", "Restoration", "healer", None, "restoration"),
]
# A talent wowsims picks other weights for (ui/specs/paladin/retribution/spec.ts: player.getTalents().holyShock)
ALT = {("PALADIN", "retribution"): ("holyShock", "paladin/retribution/presets.ts", "HolyShockEpWeights", "Holy Shock")}

# the stat each spec's weights are compared in (so the two sources meet on one scale)
def ref_of(role, cls):
    if cls == "HUNTER" and role == "ranged":
        return "agi"
    return {"melee": "ap", "tank": "ap", "caster": "sp", "healer": "heal", "ranged": "agi"}[role]


def read_frommap(text, var):
    """The two maps of `var`'s Stats.fromMap({...}, {...}) in a TypeScript file: { our key: value }."""
    m = re.search(r"export const " + re.escape(var) + r"\b[^=]*=", text)
    if not m:
        raise SystemExit(f"no {var}")
    start = text.index("Stats.fromMap(", m.end())
    i, depth = start + len("Stats.fromMap("), 1
    while depth:
        c = text[i]
        depth += c == "("
        depth -= c == ")"
        i += 1
    body = text[start:i]
    out = {}
    for name, expr in re.findall(r"\[(?:Pseudo)?Stat\.(\w+)\]\s*:\s*([^,\n}]+)", body):
        key = WS_STAT.get(name)
        if not key:
            continue
        expr = expr.strip().replace("Mechanics.HIT_RATING_PER_HIT_PERCENT", "10")
        if not re.fullmatch(r"[\d.\s*+/-]+", expr):
            continue
        out[key] = float(eval(expr))  # numbers and * only (checked above)
    return out


def read_model(zpath):
    """Forever Leveling BiS' Data/ModelWeights.lua: { CLASS: { spec: [ (upTo, {our key: value}) ] } }."""
    with zipfile.ZipFile(zpath) as z:
        name = next(n for n in z.namelist() if n.endswith("Data/ModelWeights.lua"))
        text = z.read(name).decode("utf-8")
        lic = next(n for n in z.namelist() if n.endswith("/LICENSE"))
        license_text = z.read(lic).decode("utf-8")
    out, cls, spec, setups = {}, None, None, False
    for line in text.splitlines():
        m = re.match(r"^    ([A-Z]+) = \{", line)
        if m:
            cls = m.group(1)
            out[cls] = {}
            continue
        m = re.match(r"^        (\w+) = \{ source", line)
        if m:
            spec, setups = m.group(1), False
            out[cls][spec] = []
            continue
        if "setups = {" in line:
            setups = True
            continue
        m = re.search(r"\{ upTo = (\d+),.*?stats = \{(.*?)\} \}", line)
        if m and spec and not setups:
            raw = dict((k, float(v)) for k, v in re.findall(r"(\w+) = (-?[\d.]+)", m.group(2)))
            w = {}
            for k, v in raw.items():
                if k in MODEL_STAT and v:
                    w[MODEL_STAT[k]] = v
            # spell power (damage and healing) counts as damage where no damage-only weight is given
            if "sp" not in w and raw.get("splpwr") and raw.get("splpwr", 0) - raw.get("splheal", 0) > 0.005:
                w["sp"] = raw["splpwr"] - raw.get("splheal", 0)
            if "heal" not in w and raw.get("splpwr") and "sp" not in w:
                w["heal"] = raw["splpwr"]
            if cls in DUAL_WIELD and "mhdps" in w:
                w["ohdps"] = w["mhdps"] * 0.5   # the model counts an off-hand's DPS at half
            out[cls][spec].append((int(m.group(1)), w))
    return out, license_text


def norm(w, ref):
    r = w.get(ref) or 0
    if r <= 0:
        return dict(w)
    return {k: v / r for k, v in w.items()}


def rounded(w):
    return {k: round(v, 3) for k, v in sorted(w.items()) if abs(v) >= 0.0005}


def lua_table(w):
    return "{ " + ", ".join(f"{k} = {v:g}" for k, v in w.items()) + " }"


def ratings(ws):
    text = (ws / "sim/core/base_stats_auto_gen.go").read_text(encoding="utf-8")
    def c(name):
        return float(re.search(name + r"\s*=\s*([\d.]+)", text).group(1))
    return {"hit": c("HitRatingPerHitPercent"), "crit": c("CritRatingPerCritPercent"),
            "haste": c("HasteRatingPerHastePercent"), "exp": c("ExpertiseRatingPerExpertisePercent"),
            "dodge": c("DodgeRatingPerDodgePercent"), "parry": c("ParryRatingPerParryPercent"),
            "block": c("BlockRatingPerBlockPercent"), "def": c("DefenseRatingPerDefenseLevel")}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--wowsims", required=True)
    ap.add_argument("--model", required=True)
    ap.add_argument("--report")
    a = ap.parse_args()
    ws = Path(a.wowsims)
    specs_dir = ws / "ui" / "specs"
    commit = subprocess.run(["git", "-C", str(ws), "rev-parse", "--short", "HEAD"], capture_output=True, text=True).stdout.strip()
    model, _license = read_model(a.model)
    sims = json.loads((INPUTS / "sim_weights.json").read_text(encoding="utf-8")) if (INPUTS / "sim_weights.json").exists() else {"specs": {}}
    talents = json.loads((INPUTS / "talents.json").read_text(encoding="utf-8")) if (INPUTS / "talents.json").exists() else {}
    procs = json.loads((INPUTS / "procs.json").read_text(encoding="utf-8")) if (INPUTS / "procs.json").exists() else {}

    classes, report = {}, []
    builds = json.loads((INPUTS / "builds.json").read_text(encoding="utf-8")).get("builds", []) if (INPUTS / "builds.json").exists() else []
    rows = [(c, k, n, r, s_, m, None) for c, k, n, r, s_, m in SPECS]
    for b in builds:
        ws_src = b.get("wowsims") or {}
        src_ = ("preset", ws_src["preset"][0], ws_src["preset"][1]) if "preset" in ws_src else (("sim", ws_src["sim"]) if "sim" in ws_src else None)
        rows.append((b["class"], b["key"], b["name"], b["role"], src_, b["model"], b.get("note") or ""))
    for cls, key, name, role, src, mkey, build_note in rows:
        ref = ref_of(role, cls)
        ws_w, ws_from, ws_se = None, None, {}
        if src and src[0] == "preset":
            ws_w = read_frommap((specs_dir / src[1]).read_text(encoding="utf-8"), src[2])
            ws_from = f"wowsims {src[1]} {src[2]}"
        elif src and src[0] == "sim" and src[1] in sims.get("specs", {}):
            s = sims["specs"][src[1]]
            ws_w = {}
            for part in ("weights", "pseudo"):
                for k, v in (s.get(part) or {}).items():
                    # a negative weight (haste for Arcane and Fire in these sims: rotation quirks) counts as 0
                    if WS_SHORT.get(k) and v:
                        ws_w[WS_SHORT[k]] = max(0.0, float(v))
            for k, v in (s.get("stderr") or {}).items():
                if WS_SHORT.get(k) and v is not None:
                    ws_se[WS_SHORT[k]] = float(v)
            ws_from = f"wowsims stat weight sim ({src[1]})"
        mb = model.get(cls, {}).get(mkey)
        if not mb:
            raise SystemExit(f"model has no {cls} {mkey}")
        m60 = norm(mb[-1][1], ref)
        brackets = []
        top = norm(ws_w, ref) if ws_w else None
        if top and not top.get(ref):
            top = None if ref not in (ws_w or {}) else top
        for up_to, mw in mb:
            mn = norm(mw, ref)
            if top is None:
                brackets.append((up_to, mn, "estimate", {}, None))
                continue
            # Stats wowsims weighed: its level-60 value, and below 60 the model's level shape met to it,
            #   x(level) = wowsims60 * model(level) / model60
            # (where the model's 60 value is too small to divide by, e.g. hit at its hit cap, the model's own value;
            # a stat wowsims sets to 0, like an Arms off-hand, stays 0). Stats wowsims didn't weigh (Stamina and
            # Spirit for damage specs) come from the model at every level, 60 too.
            out = {}
            for k in set(top) | set(mn):
                lv, m6 = mn.get(k, 0), m60.get(k, 0)
                if k not in top:
                    out[k] = lv
                    continue
                t = top[k]
                if up_to >= 60 or t == 0:
                    out[k] = t
                elif m6 and abs(m6) >= 0.05 * max(abs(t), 0.05):
                    out[k] = t * lv / m6
                else:
                    out[k] = lv
            if up_to >= 60:
                se = {k: v / (ws_w.get(ref) or 1) for k, v in ws_se.items() if k in out}
                # the model's stats in a simulated bracket (ones wowsims didn't weigh) keep an estimate's error
                for k in out:
                    if k not in top:
                        se.setdefault("est_" + k, 1)
                brackets.append((up_to, out, "simulated", se, "raid"))
                continue
            brackets.append((up_to, out, "estimate", {}, None))
        if top:
            for k in sorted(set(top) | set(m60)):
                t, m = top.get(k, 0), m60.get(k, 0)
                big = max(abs(t), abs(m))
                if big >= 0.1 and (min(abs(t), abs(m)) == 0 or big / max(min(abs(t), abs(m)), 1e-9) >= 2):
                    report.append(f"{cls} {name}: {k} wowsims {t:.2f} vs model {m:.2f} (per {ref})")
        for f in sorted((INPUTS / "sims").glob("*.json")) if (INPUTS / "sims").exists() else []:
            j = json.loads(f.read_text(encoding="utf-8"))
            if str(j.get("class", "")).upper() != cls or j.get("spec") != key:
                continue
            refk = WS_SHORT.get(j.get("reference", "")) or ref
            raw = {WS_SHORT[k]: v for k, v in (j.get("stats") or {}).items() if WS_SHORT.get(k)}
            r0 = (raw.get(refk) or {}).get("weight") or 1
            w = {k: max(0.0, float(v.get("weight") or 0)) / r0 for k, v in raw.items()}
            se = {k: float(v.get("stderr") or 0) / r0 for k, v in raw.items() if v.get("stderr") is not None}
            item = (int(j["upTo"]), w, "simulated", se, j.get("scenario"))
            brackets = [b for b in brackets if not (b[0] == item[0] and b[4] in (None, item[4]))] + [item]
            brackets.sort(key=lambda b: (b[0], b[4] or ""))
        spec = {"key": key, "name": name, "role": role, "src": ws_from or "Forever Leveling BiS model (MIT)",
                "brackets": brackets, "build": build_note}
        alt = ALT.get((cls, key))
        if alt:
            aw = norm(read_frommap((specs_dir / alt[1]).read_text(encoding="utf-8"), alt[2]), ref)
            t = next((t for t in talents.get("presetSwitches", []) if t.get("field") == alt[0]), None)
            pos = t and (t.get("tab"), t.get("row"), t.get("col") or t.get("column"))
            if not pos or None in pos:
                raise SystemExit(f"no talent position for {alt[0]} in talents.json")
            spec["alt"] = {"tab": pos[0], "tier": pos[1], "col": pos[2], "w": aw, "name": alt[3]}
        classes.setdefault(cls, {"specs": [], "talents": []})["specs"].append(spec)

    # talent effects: a stat +x% per rank, or x% of one stat counting as another. Effects only in a form (Heart of
    # the Wild), on pseudo-stats (Spirit regen while casting) or flat per level are left out.
    for t in talents.get("talents", []):
        cls = str(t.get("class", "")).upper()
        if cls not in classes:
            continue
        for e in t.get("effects") or []:
            if e.get("condition") or e.get("ratioByRank"):
                continue
            row = {"tab": t.get("tab"), "tier": t.get("row"), "col": t.get("column") or t.get("col"),
                   "name": t.get("talent") or t.get("name"), "pct": e.get("pctPerRank")}
            if None in (row["tab"], row["tier"], row["col"], row["pct"]):
                continue
            if e.get("linear") is False and e.get("pctByRank"):
                row["pcts"] = e["pctByRank"]
            stat = WS_SHORT.get(e.get("stat", ""))
            frm, to = WS_SHORT.get(e.get("from", "")), WS_SHORT.get(e.get("to", ""))
            if stat and not e.get("from"):
                row["stat"] = stat
            elif frm and to:
                row["from"], row["to"] = frm, to
            else:
                continue
            classes[cls]["talents"].append(row)

    out = ["-- Generated by tools/gen_upgrades.py. Do not edit; run it again.",
           f"-- Stat weights: wowsims/forever {commit} (https://github.com/wowsims/forever, MIT) at level 60; the brackets",
           "-- below 60, and specs wowsims has no weights for, from Forever Leveling BiS v0.12.0-beta's Data/ModelWeights.lua",
           "-- (MIT, Copyright (c) 2026 Thunder), met to wowsims at 60 (src = \"estimate\"). Talent effects, item",
           "-- procs and rating conversions: wowsims/forever.",
           "--",
           "-- Forever Leveling BiS license (for the model's numbers):",
           ]
    out += ["--   " + l if l else "--" for l in _license.strip().splitlines()]
    out += ["local _, ns = ...", "ns.UP_DATA = {",
            f'  source = "wowsims/forever {commit}; Forever Leveling BiS v0.12.0-beta model (MIT)",',
            "  ratings = " + lua_table(ratings(ws)) + ",", "  classes = {"]
    for cls, c in classes.items():
        out.append(f"    {cls} = {{ specs = {{")
        for s in c["specs"]:
            bn = (', build = true, note = "' + s["build"].replace('"', "'") + '"') if s.get("build") is not None else ""
            out.append(f'      {{ key = "{s["key"]}", name = "{s["name"]}", role = "{s["role"]}", src = "{s["src"]}"{bn}, brackets = {{')
            for up_to, w, src, se, scen in s["brackets"]:
                est = sorted(k[4:] for k in se if k.startswith("est_"))
                se = {k: v for k, v in se.items() if not k.startswith("est_")}
                extra = (f', scenario = "{scen}"' if scen else "") + (f", se = {lua_table(rounded(se))}" if se else "")
                if est:
                    extra += ", est = { " + ", ".join(f"{k} = true" for k in est) + " }"
                out.append(f'        {{ upTo = {up_to}, src = "{src}"{extra}, w = {lua_table(rounded(w))} }},')
            out.append("      },")
            if "alt" in s:
                al = s["alt"]
                out.append(f'      alt = {{ {{ tab = {al["tab"]}, tier = {al["tier"]}, col = {al["col"]}, name = "{al["name"]}", w = {lua_table(rounded(al["w"]))} }} }},')
            out.append("      },")
        out.append("    }, talents = {")
        for t in c["talents"]:
            parts = [f'tab = {t["tab"]}', f'tier = {t["tier"]}', f'col = {t["col"]}', f'pct = {t["pct"]:g}',
                     f'name = "{t["name"]}"']
            if "pcts" in t:
                parts.append("pcts = { " + ", ".join(f"{x:g}" for x in t["pcts"]) + " }")
            parts += [f'stat = "{t["stat"]}"'] if "stat" in t else [f'from = "{t["from"]}"', f'to = "{t["to"]}"']
            out.append("      { " + ", ".join(parts) + " },")
        out.append("    } },")
    out.append("  },")
    out.append("  procs = {")
    for iid, item in sorted((procs.get("items") or {}).items(), key=lambda x: int(x[0])):
        rows = []
        for e in item.get("effects", []):
            if e.get("unresolved"):
                continue
            kind = {"stat": "stat", "damage": "dmg", "heal": "heal", "extraattack": "extra"}.get(e.get("kind"))
            if not kind:
                continue
            p = [f'k = "{kind}"']
            if kind == "stat":
                st = {WS_SHORT.get(k): v for k, v in (e.get("stats") or {}).items() if WS_SHORT.get(k)}
                if not st:
                    continue
                p.append("s = " + lua_table(rounded(st)))
                if e.get("duration"):
                    p.append(f'd = {float(e["duration"]):g}')
            elif kind in ("dmg", "heal"):
                lo, hi = e.get("min"), e.get("max")
                if lo is None and hi is None:
                    continue
                avg = ((lo or hi) + (hi or lo)) / 2
                p.append(f"avg = {avg:g}")
            else:
                p.append(f'n = {e.get("count") or 1}')
            if e.get("countdown") or e.get("stacking") or e.get("versus") or e.get("onTarget") and kind == "stat":
                continue   # stacks, creature-type limits and debuffs: no fair average
            trig = {"melee+ranged": "melee", "spell+heal": "spell"}.get(e.get("trigger") or "melee", e.get("trigger") or "melee")
            if trig not in ("melee", "ranged", "spell", "heal", "any", "use"):
                continue   # equip, struck, kill, combat start: not a damage proc
            if trig == "use":
                if not e.get("cooldown"):
                    continue
                p.append(f'cd = {float(e["cooldown"]):g}')
            else:
                p.append(f't = "{trig}"')
                if e.get("ppm"):
                    p.append(f'ppm = {float(e["ppm"]):g}')
                elif e.get("chance"):
                    p.append(f'ch = {float(e["chance"]):g}')
                else:
                    continue
                if e.get("icd"):
                    p.append(f'icd = {float(e["icd"]):g}')
            rows.append("{ " + ", ".join(p) + " }")
        if rows:
            out.append(f"    [{int(iid)}] = {{ " + ", ".join(rows) + " },")
    out.append("  },")
    out.append("}")
    (ROOT / "UpgradesData.lua").write_text("\n".join(out) + "\n", encoding="utf-8", newline="\n")
    print(f"UpgradesData.lua: {sum(len(c['specs']) for c in classes.values())} specs, "
          f"{sum(len(c['talents']) for c in classes.values())} talents, {len(procs.get('items') or {})} proc items")
    if a.report:
        Path(a.report).write_text("\n".join(report) + "\n", encoding="utf-8")
        print(f"{len(report)} big disagreements written to {a.report}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
