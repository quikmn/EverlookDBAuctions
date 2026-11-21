r"""Builds UpgradesData.lua, the built-in data of the gear upgrades (Upgrades.lua): stat weights per class, spec and
level bracket, talent effects, item procs and rating conversions.

Sources (all MIT licensed; credited in README.md and on the Gear upgrades settings page):
  - Our own simulations, the primary source: ForeverSims (--ours, D:\Dev\ForeverSims), wowsims/forever with a level
    parameter and a levelling scenario added. Read from its result JSONs (results/levels/*/*.json and results/60/*.json,
    the ones its export export/EverlookStatWeights.lua v2 is written from). Per spec or build (OURS below, "ours" in
    builds.json): levels 10, 15, ... 55 from the levelling scenario (play setting "solo") and the dungeon scenario
    ("group"), base variant; level 60 from the raid_boss solo and group5 buff sets (builds without a level-60 key:
    levelling/dungeon 60); healers from their analytical model (one bracket per level, an estimate). Each weight keeps
    its standard error; the result's estimate flag and reason, its mana-dependent stats (manaLimited) and, for tanks
    at 60, the survival (TMI) weights with the threat (TPS) weights beside them come through. The legacy and enchants
    variants are not used: the addon has no setting for them.
  - Forever Leveling BiS v0.12.0-beta (MIT, Copyright (c) 2026 Thunder), Data/ModelWeights.lua only: the fallback
    where ours has no result (some specs below 60, tanks' survival below 60), met at 60 to our level-60 result (else to
    wowsims' preset), always an estimate. Read from the release zip; nothing else from that addon is used.
  - wowsims/forever (https://github.com/wowsims/forever, MIT; --wowsims: its ui/specs and sim/core): rating constants
    (sim/core/base_stats_auto_gen.go), the presets the fallback meets at 60 for specs ours lacks, talent effects and
    item procs read from its Go sources (tools/upgrades/talents.json, tools/upgrades/procs.json).

The data file's contract (Upgrades.lua reads only this): per class and spec, brackets = { { upTo = <level>,
src = nil (simulated) | "estimate", scenario = "solo" | "group" | nil, lo = 10 (the first simulated level: below it the
bracket is an estimate), why = <index into UP_DATA.why: the reason it's an estimate>, metric = "tmi" | "tps" (tanks),
w = "<packed weights>", mana = { stat = true }, tps = "<packed threat weights>" } }. Packed: "agi=1.61/.076,ap=1/.001"
= weight / standard error per stat, in units of the result's reference stat (U.unpack). Weights are rounded to 2
decimals (2 significant digits below 0.1), errors to 2 significant digits; weights at 0 or below are left out.

Levelling builds (a BM hunter with a melee two-hander, spell-power Protection paladin, ...) are specs too, with
build = true and a note: tools/upgrades/builds.json lists them.

Drop-in sims still work: tools/upgrades/sims/*.json, one per class, spec, bracket and scenario: { "class": "WARRIOR",
"spec": "fury", "upTo": 60, "scenario": "solo", "reference": "AttackPower", "stats": { "Strength": { "weight": 2.4,
"stderr": 0.03 }, ... } } (proto stat names, as wowsims'). Each replaces the bracket of that spec, level and scenario.

Usage: python -P tools/gen_upgrades.py --wowsims <wowsims/forever sources> [--wowsims-commit <sha>]
       --model <ForeverLevelingBiS zip> [--ours D:\Dev\ForeverSims] [--report <file>]
  e.g. the upstream sources at d0ba78b without touching the ForeverSims clone:
       git -C D:\Dev\ForeverSims\wowsims archive d0ba78b ui/specs sim/core/base_stats_auto_gen.go | tar -x -C <dir>
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


def round_w(v):
    """A weight to 2 decimals (2 significant digits below 0.1, so Armor's small weights keep their size)."""
    if abs(v) >= 0.1:
        return round(v, 2)
    if v == 0:
        return 0.0
    return float(f"{v:.2g}")


def weights_out(w):
    """Weights as written: rounded, zeros left out, by name."""
    out = {k: round_w(v) for k, v in sorted(w.items())}
    return {k: v for k, v in out.items() if v > 0}


def errors_out(se, w):
    """Standard errors of the weights written: 2 significant digits, never rounded down to 0 (a real error stays
    one), only for stats with a weight."""
    out = {}
    for k in sorted(se):
        v = se[k]
        if k not in w or not v or v <= 0:
            continue
        out[k] = float(f"{v:.2g}")
    return out


def num_text(v):
    """A number as short as Lua reads it back: 0.076 -> .076."""
    t = f"{v:g}"
    return t[1:] if t.startswith("0.") else t


def packed(w, se=None):
    """Weights and their standard errors in one string, "agi=1.61/.076,ap=1/.001,sta=.27" (Upgrades.lua's
    U.unpack reads it the first time a spec is used): a third of the size of two tables, and only the player's
    class is ever unpacked."""
    w = weights_out(w)
    se = errors_out(se or {}, w)
    return '"' + ",".join(k + "=" + num_text(v) + ("/" + num_text(se[k]) if k in se else "") for k, v in w.items()) + '"'


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


# Our own simulations (ForeverSims: wowsims/forever with a level parameter and a levelling scenario added; see
# EverlookHQ/plans/stat-weight-sims-2026-11-21.md). Per spec of the addon: "60" = the key of its level-60 results
# (scenario raid_boss, buff sets solo/group5), "lvl" = the build key of its levelling and dungeon results (levels
# 10-60), "from" = the first level those fit the spec (lower levels fall back), "heal" = the healer's analytical
# model, "alt60" = the level-60 key of a talent the addon switches weights for (Holy Shock), "threat" = for tanks,
# the build whose dungeon threat (TPS) is shown beside the survival verdict below 60.
OURS = {
    ("WARRIOR", "arms"): {"60": "warrior_arms", "lvl": "warrior_arms_2h"},
    ("WARRIOR", "fury"): {"60": "warrior_fury", "lvl": "warrior_fury_dw"},
    ("WARRIOR", "protection"): {"60": "warrior_protection", "threat": "warrior_protection"},
    ("PALADIN", "holy"): {"heal": "paladin_holy"},
    ("PALADIN", "protection"): {"60": "paladin_protection", "threat": "paladin_protection"},
    ("PALADIN", "retribution"): {"60": "paladin_retribution", "lvl": "paladin_retribution", "alt60": "paladin_retribution_holyshock"},
    ("HUNTER", "beastmastery"): {"60": "hunter_bm", "lvl": "hunter_bm_ranged"},
    ("HUNTER", "marksmanship"): {"60": "hunter_mm"},
    ("HUNTER", "survival"): {"60": "hunter_sv"},
    ("ROGUE", "assassination"): {"60": "rogue_assassination"},
    ("ROGUE", "combat"): {"60": "rogue_combat", "lvl": "rogue_combat"},
    ("ROGUE", "subtlety"): {"60": "rogue_subtlety", "lvl": "rogue_subtlety"},
    ("PRIEST", "discipline"): {"heal": "priest_discipline"},
    ("PRIEST", "holy"): {"heal": "priest_holy"},
    ("PRIEST", "shadow"): {"60": "priest_shadow", "lvl": "priest_shadow"},
    ("SHAMAN", "elemental"): {"60": "shaman_elemental", "lvl": "shaman_elemental"},
    ("SHAMAN", "enhancement"): {"60": "shaman_enhancement", "lvl": "shaman_enhancement"},
    ("SHAMAN", "restoration"): {"heal": "shaman_restoration"},
    ("MAGE", "arcane"): {"60": "mage_arcane", "lvl": "mage_arcane"},
    ("MAGE", "fire"): {"60": "mage_fire", "lvl": "mage_fire"},
    ("MAGE", "frost"): {"60": "mage_frost", "lvl": "mage_frost"},
    ("WARLOCK", "affliction"): {"60": "warlock_affliction", "lvl": "warlock_affliction"},
    ("WARLOCK", "demonology"): {"60": "warlock_demonology_shadow", "lvl": "warlock_demonology"},
    ("WARLOCK", "destruction"): {"60": "warlock_destruction"},
    ("DRUID", "balance"): {"60": "druid_balance", "lvl": "druid_balance"},
    ("DRUID", "feral"): {"60": "druid_feral_cat", "lvl": "druid_feral_cat"},
    ("DRUID", "bear"): {"60": "druid_feral_bear"},
    ("DRUID", "restoration"): {"heal": "druid_restoration"},
}
SIM_LEVELS = (10, 15, 20, 25, 30, 35, 40, 45, 50, 55, 60)
# the addon's play setting -> (levelling scenario, level-60 buff set)
PLAY = (("solo", "levelling", "solo"), ("group", "dungeon", "group5"))
# raid_boss fights of mana users were cut before running out of mana: these stats' value there depends on mana
MANA_STATS = ("Intellect", "Spirit", "MP5", "HasteRating")
METRIC = {"mobs_per_hour": "mph", "dps": "dps", "tps": "tps", "tmi": "tmi", "dungeon_pulls_per_hour": "pulls"}
BELOW_10 = "no simulation below level 10: the level 10 weights"


def up_to_of(level):
    """The bracket a sim level stands for: 10 covers 10-14, ..., 55 covers 55-59, 60 is 60."""
    return 60 if level >= 60 else level + 4


def read_ours(root):
    """ForeverSims' results (the JSONs its export, export/EverlookStatWeights.lua, is written from) and the export's
    header: { key: doc } with keys ("60", spec key, buffs) and (scenario, build key, variant, level)."""
    root = Path(root)
    head = (root / "export" / "EverlookStatWeights.lua").read_text(encoding="utf-8")[:2000]
    version = re.search(r"version = (\d+)", head)
    if not version or int(version.group(1)) != 2:
        raise SystemExit("EverlookStatWeights.lua: expected version 2")
    meta = {k: (re.search(k + r' = "([^"]*)"', head) or [None, "?"])[1] for k in ("generated", "wowsimsCommit", "forkCommit")}
    docs = {}
    files = sorted((root / "results" / "levels").glob("*/*.json")) + sorted((root / "results" / "60").glob("*.json"))
    for f in files:
        if f.name.endswith(".job.json"):
            continue
        d = json.loads(f.read_text(encoding="utf-8"))
        if d["scenario"] == "raid_boss":
            docs[("60", d["key"], d["buffs"])] = d
        else:
            docs[(d["scenario"], d["build"], d.get("variant"), int(d["level"]))] = d
    return docs, meta


def ours_w(weights, ratings):
    """A result's weights as our stat keys: { key: EP } and { key: EP standard error }. CritPercent (healers) becomes
    crit rating; weights at 0 or below are left out (a stat that doesn't help scores nothing, as before)."""
    w, se = {}, {}
    for stat, v in weights.items():
        ep, es = v.get("ep"), v.get("epStderr") or 0
        if ep is None:
            continue
        if stat == "CritPercent":
            k, ep, es = "crit", ep / ratings["crit"], es / ratings["crit"]
        else:
            k = WS_SHORT.get(stat)
        if not k or k in w or ep <= 0:
            continue
        w[k], se[k] = float(ep), float(es)
    return w, se


def our_bracket(d, up_to, scen, ratings, lo=None):
    w, se = ours_w(d["weights"], ratings)
    b = {"upTo": up_to, "scenario": scen, "src": "estimate" if d.get("estimate") else "simulated",
         "metric": METRIC.get(d["metric"], d["metric"]), "w": w, "se": se, "ours": True}
    if d.get("estimateReasons"):
        b["why"] = "; ".join(d["estimateReasons"])
    if d.get("manaLimited"):
        b["mana"] = sorted(WS_SHORT[s] for s in MANA_STATS if s in d["weights"])
    if lo:
        b["lo"] = lo
    tps = (d.get("otherMetrics") or {}).get("tps")
    if tps and d["metric"] != "tps":
        b["tps"], b["tpsSe"] = ours_w(tps, ratings)
    return b


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--wowsims", required=True, help="wowsims/forever sources (ui/specs, sim/core): presets for the fallbacks, rating constants")
    ap.add_argument("--wowsims-commit", help="its commit, when --wowsims is not a git clone")
    ap.add_argument("--model", required=True)
    ap.add_argument("--ours", default=r"D:\Dev\ForeverSims", help="ForeverSims (results/ and export/EverlookStatWeights.lua)")
    ap.add_argument("--report")
    a = ap.parse_args()
    ws = Path(a.wowsims)
    specs_dir = ws / "ui" / "specs"
    commit = a.wowsims_commit or subprocess.run(["git", "-C", str(ws), "rev-parse", "--short", "HEAD"], capture_output=True, text=True).stdout.strip()
    model, _license = read_model(a.model)
    sims = json.loads((INPUTS / "sim_weights.json").read_text(encoding="utf-8")) if (INPUTS / "sim_weights.json").exists() else {"specs": {}}
    talents = json.loads((INPUTS / "talents.json").read_text(encoding="utf-8")) if (INPUTS / "talents.json").exists() else {}
    procs = json.loads((INPUTS / "procs.json").read_text(encoding="utf-8")) if (INPUTS / "procs.json").exists() else {}
    rates = ratings(ws)
    docs, ours_meta = read_ours(a.ours)
    used = set()

    classes, report, coverage = {}, [], []
    builds = json.loads((INPUTS / "builds.json").read_text(encoding="utf-8")).get("builds", []) if (INPUTS / "builds.json").exists() else []
    rows = [(c, k, n, r, s_, m, None, OURS.get((c, k))) for c, k, n, r, s_, m in SPECS]
    for b in builds:
        ws_src = b.get("wowsims") or {}
        src_ = ("preset", ws_src["preset"][0], ws_src["preset"][1]) if "preset" in ws_src else (("sim", ws_src["sim"]) if "sim" in ws_src else None)
        rows.append((b["class"], b["key"], b["name"], b["role"], src_, b["model"], b.get("note") or "", b.get("ours")))
    for cls, key, name, role, src, mkey, build_note, o in rows:
        o = o or {}
        ref = "sta" if role == "tank" else ref_of(role, cls)

        # 1. ours: every level bracket and play setting our sims have
        ours = []
        frm = o.get("from", 10)
        for lvl in SIM_LEVELS:
            lo = 10 if lvl == 10 else None
            if "heal" in o:
                d = docs.get(("healing", o["heal"], "model", lvl))
                if d:
                    used.add(id(d))
                    ours.append(our_bracket(d, up_to_of(lvl), None, rates, lo))
                continue
            if lvl < frm:
                continue
            for scen, sc, buffs in PLAY:
                d = None
                if lvl == 60 and o.get("60"):
                    d = docs.get(("60", o["60"], buffs))
                elif o.get("lvl"):
                    d = docs.get((sc, o["lvl"], "base", lvl))
                if d:
                    used.add(id(d))
                    ours.append(our_bracket(d, up_to_of(lvl), scen, rates, lo))
        covered = {b["upTo"] for b in ours}
        if 14 in covered:
            covered.add(9)   # levels 1-9 use the level-10 weights (as an estimate, said in the game)

        # 2. the fallback for levels ours doesn't cover: Forever Leveling BiS' model, met at 60 to our level-60
        # result (else to wowsims' preset or stat-weight sim, as before). Always an estimate.
        ws_w, ws_from = None, None
        if src and src[0] == "preset":
            ws_w = read_frommap((specs_dir / src[1]).read_text(encoding="utf-8"), src[2])
            ws_from = f"wowsims {src[1]} {src[2]}"
        elif src and src[0] == "sim" and src[1] in sims.get("specs", {}):
            s = sims["specs"][src[1]]
            ws_w = {}
            for part in ("weights", "pseudo"):
                for k, v in (s.get(part) or {}).items():
                    if WS_SHORT.get(k) and v:
                        ws_w[WS_SHORT[k]] = max(0.0, float(v))
            ws_from = f"wowsims stat weight sim ({src[1]})"
        our60 = next((b for b in ours if b["upTo"] == 60 and b["scenario"] in ("solo", None)), None)
        anchor = (our60["w"], "our level-60 simulation") if our60 and ref in our60["w"] else ((ws_w, ws_from) if ws_w else (None, None))
        mb = model.get(cls, {}).get(mkey)
        if not mb:
            raise SystemExit(f"model has no {cls} {mkey}")
        m60 = norm(mb[-1][1], ref)
        top = norm(anchor[0], ref) if anchor[0] and anchor[0].get(ref) else None
        fallback = []
        for up_to, mw in mb:
            if up_to in covered:
                continue
            mn = norm(mw, ref)
            if top is None:
                out = mn
            else:
                # x(level) = anchor60 * model(level) / model60 for the stats the anchor weighs (the model's own
                # value where its 60 value is too small to divide by); the model's value for the rest
                out = {}
                for k in set(top) | set(mn):
                    lv, m6 = mn.get(k, 0), m60.get(k, 0)
                    if k not in top:
                        out[k] = lv
                    elif up_to >= 60 or top[k] == 0:
                        out[k] = top[k]
                    elif m6 and abs(m6) >= 0.05 * max(abs(top[k]), 0.05):
                        out[k] = top[k] * lv / m6
                    else:
                        out[k] = lv
            out = {k: v for k, v in out.items() if v > 0}
            why = ("no simulation of ours for this level: Forever Leveling BiS' model (MIT)"
                   + (f", met to {anchor[1]}" if top else "")) if up_to < 60 else f"no simulation of ours: {anchor[1] or 'the model'}"
            if role == "tank" and up_to < 60:
                why = "no survival simulation below 60: Forever Leveling BiS' model (MIT)" + (", met to our level-60 survival weights" if our60 else "")
            fb = {"upTo": up_to, "scenario": None, "src": "estimate", "w": out, "se": {}, "why": why}
            if o.get("threat"):
                lvl = 10 if up_to < 10 else (up_to - 4 if up_to < 60 else 60)
                d = docs.get(("dungeon", o["threat"], "base", lvl))
                if d:
                    used.add(id(d))
                    fb["tps"], fb["tpsSe"] = ours_w(d["weights"], rates)
            fallback.append(fb)
        if ws_w and top is not None and anchor[1] == ws_from:
            for k in sorted(set(top) | set(m60)):
                t, m = top.get(k, 0), m60.get(k, 0)
                big = max(abs(t), abs(m))
                if big >= 0.1 and (min(abs(t), abs(m)) == 0 or big / max(min(abs(t), abs(m)), 1e-9) >= 2):
                    report.append(f"{cls} {name}: {k} wowsims {t:.2f} vs model {m:.2f} (per {ref})")
        brackets = sorted(ours + fallback, key=lambda b: (b["upTo"], b["scenario"] or ""))

        # 3. drop-in sims (tools/upgrades/sims/*.json) replace a bracket of that level and scenario
        for f in sorted((INPUTS / "sims").glob("*.json")) if (INPUTS / "sims").exists() else []:
            j = json.loads(f.read_text(encoding="utf-8"))
            if str(j.get("class", "")).upper() != cls or j.get("spec") != key:
                continue
            refk = WS_SHORT.get(j.get("reference", "")) or ref
            raw = {WS_SHORT[k]: v for k, v in (j.get("stats") or {}).items() if WS_SHORT.get(k)}
            r0 = (raw.get(refk) or {}).get("weight") or 1
            w = {k: float(v.get("weight") or 0) / r0 for k, v in raw.items() if float(v.get("weight") or 0) > 0}
            se = {k: float(v.get("stderr") or 0) / r0 for k, v in raw.items() if v.get("stderr") is not None and k in w}
            item = {"upTo": int(j["upTo"]), "scenario": j.get("scenario"), "src": "simulated", "w": w, "se": se, "ours": True}
            brackets = [b for b in brackets if not (b["upTo"] == item["upTo"] and b["scenario"] in (None, item["scenario"]))] + [item]
            brackets.sort(key=lambda b: (b["upTo"], b["scenario"] or ""))

        n_ours = sum(1 for b in brackets if b.get("ours"))
        n_est = sum(1 for b in brackets if b.get("ours") and b["src"] == "estimate")
        fb_levels = sorted({b["upTo"] for b in brackets if not b.get("ours")})
        coverage.append((cls, key, name, n_ours, n_est, fb_levels))
        spec = {"key": key, "name": name, "role": role,
                "src": "our simulations (wowsims/forever, MIT)" if n_ours else (ws_from or "Forever Leveling BiS model (MIT)"),
                "brackets": brackets, "build": build_note}
        # a talent wowsims picks other weights for (Holy Shock): ours at 60 per play setting, else wowsims' preset
        alt = ALT.get((cls, key))
        if alt:
            t = next((t for t in talents.get("presetSwitches", []) if t.get("field") == alt[0]), None)
            pos = t and (t.get("tab"), t.get("row"), t.get("col") or t.get("column"))
            if not pos or None in pos:
                raise SystemExit(f"no talent position for {alt[0]} in talents.json")
            spec["alt"] = []
            for scen, _sc, buffs in PLAY:
                d = o.get("alt60") and docs.get(("60", o["alt60"], buffs))
                if d:
                    used.add(id(d))
                    b = our_bracket(d, 60, scen, rates)
                    spec["alt"].append({"tab": pos[0], "tier": pos[1], "col": pos[2], "name": alt[3], "scenario": scen,
                                        "w": b["w"], "se": b["se"], "mana": b.get("mana")})
            if not spec["alt"]:
                aw = norm(read_frommap((specs_dir / alt[1]).read_text(encoding="utf-8"), alt[2]), ref)
                spec["alt"].append({"tab": pos[0], "tier": pos[1], "col": pos[2], "name": alt[3], "w": aw})
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

    whys = []

    def why_ref(text):
        if text not in whys:
            whys.append(text)
        return whys.index(text) + 1

    def lua_str(s):
        return '"' + str(s).replace("\\", "\\\\").replace('"', "'") + '"'

    def bracket_lua(b):
        # src is left out for "simulated" (the addon's default); w = the packed weights and their errors
        parts = [f'upTo = {b["upTo"]}']
        if b["src"] != "simulated":
            parts.append(f'src = "{b["src"]}"')
        if b.get("scenario"):
            parts.append(f'scenario = "{b["scenario"]}"')
        if b.get("lo"):
            parts.append(f'lo = {b["lo"]}')
        if b.get("metric") in ("tmi", "tps"):
            parts.append(f'metric = "{b["metric"]}"')
        if b.get("why"):
            parts.append(f'why = {why_ref(b["why"])}')
        parts.append("w = " + packed(b["w"], b.get("se")))
        if b.get("mana"):
            parts.append("mana = { " + ", ".join(f"{k} = true" for k in b["mana"]) + " }")
        if b.get("tps"):
            parts.append("tps = " + packed(b["tps"], b.get("tpsSe")))
        return "{ " + ", ".join(parts) + " }"

    out = ["-- Generated by tools/gen_upgrades.py. Do not edit; run it again.",
           f"-- Stat weights: our own simulations (ForeverSims {ours_meta['generated']}: wowsims/forever {ours_meta['wowsimsCommit'][:7]},",
           "-- https://github.com/wowsims/forever, MIT, with a level parameter and a levelling scenario added; fork",
           f"-- {ours_meta['forkCommit'][:10]}), per spec and build, level bracket and play setting (solo = levelling, group =",
           "-- dungeon; level 60: the solo and group5 buff sets). se = standard errors of the weights; mana = stats whose",
           "-- value depends on mana; tps = threat weights (tanks, beside their survival weights); why = the reason a",
           "-- bracket is an estimate (UP_DATA.why). Where ours has no result: Forever Leveling BiS v0.12.0-beta's",
           "-- Data/ModelWeights.lua (MIT, Copyright (c) 2026 Thunder), met to our level-60 result (or wowsims' preset",
           f"-- at {commit}), always src = \"estimate\". Talent effects, item procs and rating conversions: wowsims/forever.",
           "--",
           "-- Forever Leveling BiS license (for the model's numbers):",
           ]
    out += ["--   " + l if l else "--" for l in _license.strip().splitlines()]
    body = []
    for cls, c in classes.items():
        body.append(f"    {cls} = {{ specs = {{")
        for s in c["specs"]:
            bn = (', build = true, note = ' + lua_str(s["build"])) if s.get("build") is not None else ""
            body.append(f'      {{ key = "{s["key"]}", name = "{s["name"]}", role = "{s["role"]}", src = "{s["src"]}"{bn}, brackets = {{')
            for b in s["brackets"]:
                body.append("        " + bracket_lua(b) + ",")
            body.append("      },")
            if s.get("alt"):
                body.append("      alt = {")
                for al in s["alt"]:
                    head = f'tab = {al["tab"]}, tier = {al["tier"]}, col = {al["col"]}, name = "{al["name"]}"'
                    if al.get("scenario"):
                        head += f', scenario = "{al["scenario"]}"'
                    head += ", w = " + packed(al["w"], al.get("se"))
                    if al.get("mana"):
                        head += ", mana = { " + ", ".join(f"{k} = true" for k in al["mana"]) + " }"
                    body.append("        { " + head + " },")
                body.append("      },")
            body.append("      },")
        body.append("    }, talents = {")
        for t in c["talents"]:
            parts = [f'tab = {t["tab"]}', f'tier = {t["tier"]}', f'col = {t["col"]}', f'pct = {t["pct"]:g}',
                     f'name = "{t["name"]}"']
            if "pcts" in t:
                parts.append("pcts = { " + ", ".join(f"{x:g}" for x in t["pcts"]) + " }")
            parts += [f'stat = "{t["stat"]}"'] if "stat" in t else [f'from = "{t["from"]}"', f'to = "{t["to"]}"']
            body.append("      { " + ", ".join(parts) + " },")
        body.append("    } },")
    body.append("  },")
    body.append("  procs = {")
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
            body.append(f"    [{int(iid)}] = {{ " + ", ".join(rows) + " },")
    body.append("  },")
    body.append("}")
    out += ["local _, ns = ...", "ns.UP_DATA = {",
            f'  source = "our simulations (ForeverSims {ours_meta["generated"]}, wowsims/forever {ours_meta["wowsimsCommit"][:7]}, MIT); fallback: Forever Leveling BiS v0.12.0-beta model (MIT)",',
            "  ratings = " + lua_table(rates) + ",",
            "  belowLo = " + lua_str(BELOW_10) + ",",
            "  why = {"] + ["    " + lua_str(t) + "," for t in whys] + ["  },", "  classes = {"] + body
    (ROOT / "UpgradesData.lua").write_text("\n".join(out) + "\n", encoding="utf-8", newline="\n")
    print(f"UpgradesData.lua: {sum(len(c['specs']) for c in classes.values())} specs, "
          f"{sum(len(c['talents']) for c in classes.values())} talents, {len(procs.get('items') or {})} proc items")
    print(f"our results: {len(docs)} read, {len(used)} used")
    for cls, key, name, n_ours, n_est, fb in coverage:
        print(f"  {cls:8} {key:22} ours {n_ours:2} brackets ({n_est} of them estimates)"
              + (f"; fallback (estimate) brackets up to {fb}" if fb else ""))
    if a.report:
        Path(a.report).write_text("\n".join(report) + "\n", encoding="utf-8")
        print(f"{len(report)} big disagreements written to {a.report}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
