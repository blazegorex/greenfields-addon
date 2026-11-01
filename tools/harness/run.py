"""Headless multi-client test harness for the Greenfields addon (WoW Forever 1.60.1 / TOC 16001).

Runs N simulated clients, each in its own real Lua 5.1 (lupa.lua51) runtime that loads the
WoW mock (tools/harness/wow_mock*.lua) and then the addon files in TOC order with
("Greenfields", ns). A virtual clock drives every client in 0.05 s ticks; an addon-message
bus and a chat router carry traffic between clients ("next tick" delivery).

    tools\\.venv\\Scripts\\python.exe tools\\harness\\run.py --scenario all --render OUT --json OUT\\report.json

Scenarios: boot, pages, raid, secrets, misc (comma-separated, or "all").
Exit code is non-zero when any Lua error was recorded (addon-captured or harness-caught)
or the harness itself failed. See README.md.
"""
import argparse
import base64
import calendar
import hashlib
import importlib.util
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import traceback
import urllib.parse
import zlib

import lupa.lua51 as lua51

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
ADDON_DIR = os.path.join(ROOT, "Greenfields")
ADDON = "Greenfields"
MOCK_FILES = ["wow_mock.lua", "wow_mock_data.lua", "wow_mock_widgets.lua", "wow_mock_anim.lua",
              "wow_mock_api.lua", "wow_mock_game.lua", "wow_mock_scene.lua"]
SYSTEM_PYTHON = r"C:\Python313\python.exe"
TICK = 0.05
REALM = "Arugal"
EPOCH0 = 1796814000          # Wed 9 Dec 2026 19:00 AWST (raids unlock day)
UPTIME0 = 1000.0
MAIN_FRAME = "GreenfieldsMainFrame"

VERBOSE = False


def log(*a):
    print(*a, flush=True)


def vlog(*a):
    if VERBOSE:
        print("   ", *a, flush=True)


def u8(s):
    """Lua string (latin-1 decoded by lupa) -> proper Python text."""
    if s is None:
        return None
    if isinstance(s, bytes):
        return s.decode("utf-8", "replace")
    return s.encode("latin-1", "replace").decode("utf-8", "replace")


# ---------------------------------------------------------------------------
# Python -> Lua literal
# ---------------------------------------------------------------------------
def _lua_str(s):
    if isinstance(s, str):
        s = s.encode("utf-8")
    out = ['"']
    for b in s:
        c = chr(b)
        if c == '"' or c == "\\":
            out.append("\\" + c)
        elif 32 <= b < 127:
            out.append(c)
        else:
            out.append("\\%d" % b)
    out.append('"')
    return "".join(out)


def to_lua(v):
    if v is None:
        return "nil"
    if v is True:
        return "true"
    if v is False:
        return "false"
    if isinstance(v, int):
        return str(v)
    if isinstance(v, float):
        if v != v or v in (float("inf"), float("-inf")):
            return "0"
        return repr(v)
    if isinstance(v, (str, bytes)):
        return _lua_str(v)
    if isinstance(v, (list, tuple)):
        return "{" + ",".join(to_lua(x) for x in v) + "}"
    if isinstance(v, dict):
        parts = []
        for k, x in v.items():
            if isinstance(k, int):
                parts.append("[%d]=%s" % (k, to_lua(x)))
            else:
                parts.append("[%s]=%s" % (_lua_str(str(k)), to_lua(x)))
        return "{" + ",".join(parts) + "}"
    raise TypeError("cannot convert %r to Lua" % (v,))


# ---------------------------------------------------------------------------
# Addon metadata
# ---------------------------------------------------------------------------
def read_toc():
    files, meta = [], {}
    with open(os.path.join(ADDON_DIR, ADDON + ".toc"), encoding="utf-8-sig") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            if line.startswith("##"):
                m = re.match(r"##\s*([^:]+):\s*(.*)$", line)
                if m:
                    meta[m.group(1).strip()] = m.group(2).strip()
                continue
            if line.startswith("#"):
                continue
            files.append(line.replace("/", "\\"))
    return files, meta


_MEDIA = None


def addon_media():
    """every file under the addon folder as the client would address it (lower case, no extension)"""
    global _MEDIA
    if _MEDIA is None:
        out = []
        for dirpath, _, names in os.walk(ADDON_DIR):
            for n in names:
                rel = os.path.relpath(os.path.join(dirpath, n), ADDON_DIR)
                base = os.path.splitext(rel)[0].replace("/", "\\")
                out.append(("interface\\addons\\" + ADDON + "\\" + base).lower())
        _MEDIA = sorted(out)
    return _MEDIA


def load_font_metrics():
    p = os.path.join(HERE, "font_metrics.json")
    if not os.path.exists(p):
        return None
    with open(p, encoding="utf-8") as fh:
        data = json.load(fh)
    out = {}
    for key, m in data.items():
        adv = {}
        for k, v in m["adv"].items():
            adv[int(k) if k.isdigit() else k] = v
        out[key] = {"adv": adv}
    return out


def scan_buff_data():
    """Spell/item IDs used by Data/Buffs.lua (+ profession cooldown recipes), by running
    the data file in a scratch Lua with a stub namespace."""
    rt = lua51.LuaRuntime(unpack_returned_tuples=True, encoding="latin-1")
    src = open(os.path.join(ADDON_DIR, "Data", "Buffs.lua"), "rb").read()
    fn = rt.eval("function(src) local f, e = loadstring(src, '@Buffs.lua') if not f then error(e) end return f end")(src)
    ns = rt.eval("{ API = { SpellName = function() return nil end } }")
    fn(ADDON, ns)
    D = ns.BuffData
    spells, items = {}, {}

    def lua_list(t):
        return [t[i] for i in range(1, len(t) + 1)] if t is not None else []

    for i in range(1, len(D.categories) + 1):
        c = D.categories[i]
        for sid in lua_list(c.ids) + lua_list(c.probe):
            spells.setdefault(int(sid), u8(c.long))
    for i in range(1, len(D.camp) + 1):
        o = D.camp[i]
        name = u8(o.name)
        for sid in lua_list(o.recipes):
            spells.setdefault(int(sid), name)
        if o.aura:
            spells.setdefault(int(o.aura), name + " (Camp)")
        if o.useSpell:
            spells.setdefault(int(o.useSpell), name)
        for j, iid in enumerate(lua_list(o["items"])):
            items.setdefault(int(iid), "%s%s" % (name, "" if j == 0 else " (Tier %d)" % (j + 1)))
    for i in range(1, len(D.campfires) + 1):
        f = D.campfires[i]
        spells.setdefault(int(f.recipe), u8(f.name))
        items.setdefault(int(f.item), u8(f.name) + " Kit")
        for sid in lua_list(f.useSpells):
            spells.setdefault(int(sid), u8(f.name))
    for k, name in (("CAMP_BENEFITS", "Camp Benefits"), ("WELCOMING_CAMPFIRE", "Welcoming Campfire"),
                    ("CAMPFIRE_NEARBY", "Campfire Nearby")):
        if D[k]:
            spells.setdefault(int(D[k]), name)
    for sid in lua_list(D.CAMP_PLACE_SPELLS):
        spells.setdefault(int(sid), "Camp placement")
    prof_src = open(os.path.join(ADDON_DIR, "Modules", "Professions.lua"), encoding="utf-8", errors="replace").read()
    for m in re.finditer(r"\{\s*id\s*=\s*(\d+),\s*cd\s*=\s*\d+[^}]*\}\s*,?\s*--\s*([^\n]+)", prof_src):
        spells.setdefault(int(m.group(1)), m.group(2).strip())
    for m in re.finditer(r"\{\s*id\s*=\s*(\d+),\s*cd\s*=", prof_src):
        spells.setdefault(int(m.group(1)), "Profession cooldown %s" % m.group(1))
    return spells, items


# ---------------------------------------------------------------------------
# The simulated world: characters, guild, clients
# ---------------------------------------------------------------------------
def guid_for(name):
    return "Player-1-" + hashlib.md5(name.encode()).hexdigest()[:8].upper()


PROF = {  # skillLine -> (name, icon fileID)
    164: ("Blacksmithing", 136241), 165: ("Leatherworking", 133611), 171: ("Alchemy", 136240),
    182: ("Herbalism", 136246), 186: ("Mining", 136248), 197: ("Tailoring", 136249), 202: ("Engineering", 136243),
    333: ("Enchanting", 136244), 393: ("Skinning", 134366), 129: ("First Aid", 135966), 185: ("Cooking", 133971),
    356: ("Fishing", 136245),
}


def prof(line, rank, mx=300):
    return {"skillLine": line, "name": PROF[line][0], "rank": rank, "max": mx, "icon": PROF[line][1]}


BASE_CLIENTS = [
    dict(name="Spencer", cls="WARRIOR", race="Human", level=60, rank=0, money=12345678, zone="Stormwind City",
         profs={"prof1": prof(164, 300), "prof2": prof(186, 300), "firstAid": prof(129, 225), "fishing": prof(356, 75),
                "cooking": prof(185, 150)},
         known=[6673, 25289, 78, 2457, 2018, 2657, 3304, 16153, 2660, 1230171, 2575, 2580, 2656, 3273, 3275, 18630,
                1230117, 2550, 8604, 2538, 2540, 1229737, 7620],
         bags=[(6948, 1), (279981, 2), (12404, 10), (12359, 20), (13446, 5), (4471, 1), (4470, 10)],
         pvp=(412, 3, 7)),
    dict(name="Bazza", cls="PRIEST", race="Dwarf", level=60, rank=1, money=5678901, zone="Ironforge",
         profs={"prof1": prof(197, 300), "prof2": prof(333, 280), "firstAid": prof(129, 300), "cooking": prof(185, 300)},
         known=[1243, 10938, 21562, 21564, 14752, 27841, 27681, 976, 10958, 27683, 2050, 588, 2006, 3908, 3914, 2387,
                18560, 1229504, 7411, 7418, 14293, 1230643, 3273, 3275, 18630, 1230117, 2550, 1229737, 1283400, 1291341],
         bags=[(6948, 1), (14047, 20), (14047, 20), (14342, 2), (279961, 1), (14530, 10), (21023, 5), (4470, 5)],
         pvp=(37, 0, 2)),
    dict(name="Shazza", cls="MAGE", race="Gnome", level=60, rank=3, money=890123, zone="Stormwind City",
         profs={"prof1": prof(171, 300), "prof2": prof(182, 300), "fishing": prof(356, 150), "cooking": prof(185, 75)},
         known=[1459, 10157, 23028, 133, 118, 168, 2259, 2330, 2331, 17187, 11479, 1230564, 2366, 2383, 1229705,
                7620, 1229745, 2550, 1229737],
         bags=[(6948, 1), (12360, 1), (13444, 5), (13512, 1), (17056, 20), (20748, 2)],
         pvp=(5, 0, 0)),
]
EXTRA_CLIENTS = [
    dict(name="Kev", cls="PALADIN", race="Human", level=60, rank=2, money=2000000, zone="Ironforge",
         profs={"prof1": prof(165, 300), "prof2": prof(393, 300)}, known=[20217, 25898, 19740, 19742, 465, 1038, 1229432, 1229517],
         bags=[(6948, 1)], pvp=(0, 0, 0)),
    dict(name="Trish", cls="DRUID", race="NightElf", level=60, rank=3, money=300000, zone="Darnassus",
         profs={"prof1": prof(182, 250), "prof2": prof(171, 220)}, known=[1126, 9885, 21849, 24858, 24907, 17007],
         bags=[(6948, 1)], pvp=(0, 0, 0)),
    dict(name="Mick", cls="HUNTER", race="Dwarf", level=60, rank=3, money=100000, zone="Ironforge",
         profs={"prof1": prof(202, 300), "prof2": prof(186, 280)}, known=[19506, 20043], bags=[(6948, 1)], pvp=(0, 0, 0)),
    dict(name="Wayne", cls="SHAMAN", race="Dwarf", level=60, rank=3, money=100000, zone="Ironforge",
         profs={"prof1": prof(393, 300), "prof2": prof(165, 300)}, known=[8075, 8835, 8512, 5675], bags=[(6948, 1)], pvp=(0, 0, 0)),
    dict(name="Gaz", cls="WARLOCK", race="Gnome", level=60, rank=3, money=100000, zone="Stormwind City",
         profs={"prof1": prof(197, 300), "prof2": prof(333, 300)}, known=[688, 6307], bags=[(6948, 1)], pvp=(0, 0, 0)),
    dict(name="Deb", cls="ROGUE", race="Human", level=60, rank=3, money=100000, zone="Stormwind City",
         profs={"prof1": prof(186, 300), "prof2": prof(164, 300)}, known=[], bags=[(6948, 1)], pvp=(0, 0, 0)),
]

# name, class, race, level, rankIndex, zone, public note, officer note, online
FAKE_MEMBERS = [
    ("Davo", "WARRIOR", "Dwarf", 60, 2, "Ironforge", "Main tank. Brings the snags.", "", True),
    ("Kylie", "PALADIN", "Human", 60, 2, "Ironforge", "Holy pally", "", True),
    ("Macca", "HUNTER", "NightElf", 60, 3, "Tanaris", "", "", True),
    ("Robbo", "ROGUE", "Human", 58, 3, "Stranglethorn Vale", "", "", False),
    ("Sheila", "DRUID", "NightElf", 60, 3, "Moonglade", "resto", "", True),
    ("Gazza", "SHAMAN", "Dwarf", 60, 3, "Ironforge", "", "", True),
    ("Tazza", "WARLOCK", "Gnome", 60, 3, "Stormwind City", "", "", True),
    ("Wazza", "WARRIOR", "Human", 45, 4, "Arathi Highlands", "alt of Davo", "", False),
    ("Dazza", "PRIEST", "Human", 60, 3, "Winterspring", "", "reliable, ask before benching", False),
    ("Kezza", "MAGE", "Gnome", 60, 3, "Stormwind City", "Shazza's alt", "", False),
    ("Jacko", "HUNTER", "Dwarf", 52, 4, "Feralas", "", "", True),
    ("Smithy", "ROGUE", "Gnome", 60, 3, "Ironforge", "", "", False),
    ("Bluey", "SHAMAN", "Dwarf", 38, 4, "Wetlands", "alt: Gazza", "", False),
    ("Bingo", "DRUID", "NightElf", 60, 3, "Felwood", "", "", True),
    ("Chook", "WARLOCK", "Human", 60, 3, "Burning Steppes", "", "", False),
    ("Stevo", "PALADIN", "Dwarf", 60, 2, "Ironforge", "", "raid lead backup", True),
    ("Muzza", "PRIEST", "Dwarf", 27, 4, "Duskwood", "alt of Bazza", "", False),
    ("Noddy", "WARRIOR", "Gnome", 10, 4, "Dun Morogh", "", "", True),
    ("Jono", "MAGE", "Human", 60, 3, "Stormwind City", "", "", True),
    ("Tommo", "HUNTER", "NightElf", 60, 3, "Moonglade", "", "", False),
    ("Fitzy", "ROGUE", "Human", 60, 4, "Booty Bay", "", "", False),
    ("Spenny", "DRUID", "NightElf", 33, 4, "Ashenvale", "alt of Spencer", "", False),
]
PUG = dict(name="Randy", cls="ROGUE", race="Human", level=60, realm="Yojamba")
RAID_FAKES = ["Davo", "Kylie", "Macca", "Sheila", "Gazza", "Tazza", "Randy"]
GUILD_RANKS = ["Guild Master", "Officer", "Veteran", "Member", "Initiate"]
HYJAL = {"name": "Hyjal Summit", "type": "raid", "difficultyID": 1, "difficultyName": "Normal", "maxPlayers": 20,
         "instanceID": 2400, "groupSize": 20}
LOOT_ITEMS = [281001, 281002, 281003]

BAZZA_TAILORING = {
    "skillLine": 197, "child": 2942, "name": "Tailoring", "rank": 300, "max": 300,
    "recipes": [
        {"recipeID": 3914, "name": "Brown Linen Pants", "learned": True, "item": 4343, "difficulty": 3, "skillUps": 0},
        {"recipeID": 2387, "name": "Linen Cloak", "learned": True, "item": 2570, "difficulty": 3, "skillUps": 0},
        {"recipeID": 18560, "name": "Mooncloth", "learned": True, "item": 14342, "difficulty": 0, "skillUps": 1},
        {"recipeID": 1229504, "name": "Faction Banner", "learned": True, "item": 279972, "difficulty": 2, "skillUps": 1},
        {"recipeID": 1263032, "name": "Spinning Wheel", "learned": False, "item": 279943, "difficulty": 1, "skillUps": 1},
        {"recipeID": 18451, "name": "Felcloth Robe", "learned": True, "item": 14106, "difficulty": 1, "skillUps": 1},
        {"recipeID": 18453, "name": "Felcloth Shoulders", "learned": False, "item": 14112, "difficulty": 1, "skillUps": 1},
    ],
}


def build_world(n_clients):
    defs = (BASE_CLIENTS + EXTRA_CLIENTS)[:n_clients]
    while len(defs) < n_clients:
        i = len(defs) + 1
        defs.append(dict(name="Client%d" % i, cls="WARRIOR", race="Human", level=60, rank=3, money=1000, zone="Stormwind City",
                         profs={}, known=[], bags=[(6948, 1)], pvp=(0, 0, 0)))
    world = []
    for d in defs:
        world.append({"name": d["name"], "realm": REALM, "class": d["cls"], "race": d["race"], "faction": "Alliance",
                      "level": d["level"], "guid": guid_for(d["name"]), "sex": 2, "client": True})
    for (name, cls, race, level, *_rest) in FAKE_MEMBERS:
        world.append({"name": name, "realm": REALM, "class": cls, "race": race, "faction": "Alliance", "level": level,
                      "guid": guid_for(name), "sex": 2, "client": False})
    world.append({"name": PUG["name"], "realm": PUG["realm"], "class": PUG["cls"], "race": PUG["race"],
                  "faction": "Alliance", "level": PUG["level"], "guid": guid_for(PUG["name"] + "-" + PUG["realm"]),
                  "sex": 2, "client": False})
    members = []
    for d in defs:
        members.append({"name": d["name"], "rankIndex": d["rank"], "note": "", "officerNote": "", "online": False,
                        "mobile": False, "zone": d["zone"], "ap": 0})
    for (name, cls, race, level, rank, zone, note, onote, online) in FAKE_MEMBERS:
        members.append({"name": name, "rankIndex": rank, "note": note, "officerNote": onote, "online": online,
                        "mobile": False, "zone": zone, "ap": 0})
    members.sort(key=lambda m: m["name"])
    return defs, world, members


# ---------------------------------------------------------------------------
# Wire decoding (comm stats per op)
# ---------------------------------------------------------------------------
OP_RE = re.compile(r"^\^\{\^N1;\^S(\d+):")


def wire_op(full):
    """Greenfields wire: enc char ('r' serialized | 'z' base64(deflate)) + Serialize({op, payload, proto})."""
    if not full:
        return "?"
    enc, data = full[0], full[1:]
    if enc == "z":
        try:
            raw = base64.b64decode(data + "=" * (-len(data) % 4))
            try:
                data = zlib.decompress(raw, -15).decode("latin-1")
            except Exception:
                data = raw.decode("latin-1")   # the mock's CompressString is the identity
        except Exception:
            return "?z"
    m = OP_RE.match(data)
    if not m:
        return "?"
    n = int(m.group(1))
    return data[m.end():m.end() + n]


# ---------------------------------------------------------------------------
# One client
# ---------------------------------------------------------------------------
class Client:
    def __init__(self, sim, d, world, members, toc_files, toc_meta, metrics, spells, items, seed):
        self.sim = sim
        self.name = d["name"]
        self.d = d
        self.online = False
        self.pending = []           # deliveries for the next tick: (kind, args)
        self.reasm = {}             # (sender, channel) -> parts   (comm stats)
        rt = lua51.LuaRuntime(unpack_returned_tuples=True, encoding="latin-1")
        self.rt = rt
        loader = rt.eval("function(src, name) local f, e = loadstring(src, name) if not f then error(e, 0) end return f end")
        guild_members = []
        for m in members:
            mm = dict(m)
            if mm["name"] == self.name:
                mm["online"] = True
            guild_members.append(mm)
        cfg = {
            "name": self.name, "realm": REALM, "seed": seed, "epoch": EPOCH0, "uptime": UPTIME0,
            "world": world, "guild": {"name": "Greenfields", "ranks": GUILD_RANKS, "members": guild_members},
            "money": d["money"], "zone": d["zone"],
            "professions": d.get("profs", {}), "known": d.get("known", []),
            "bags": {0: [[i, c] for (i, c) in d.get("bags", [])]},
            "pvp": {"hk": d["pvp"][0], "dk": d["pvp"][1], "rank": d["pvp"][2]},
            "addonName": ADDON, "toc": toc_meta, "fontMetrics": metrics, "addonMedia": addon_media(),
            "continent": "Eastern Kingdoms", "continentID": 0,
        }
        cfg_tbl = rt.execute("return " + to_lua(cfg))
        self.MOCK = rt.eval("{}")
        for f in MOCK_FILES:
            src = open(os.path.join(HERE, f), "rb").read()
            loader(src, "@mock/" + f)(self.MOCK, cfg_tbl)
        M = self.MOCK
        for sid, name in sorted(spells.items()):
            M.AddSpell(sid, name)
        for iid, name in sorted(items.items()):
            if not M["items"][iid]:
                M.AddItem(iid, name, 1, 30, 20, "Miscellaneous", "Other", 1, "", 134400 + iid % 900, 100, 15, 4, 0, None)
        M.AddItem(2570, "Linen Cloak", 1, 10, 5, "Armor", "Cloth", 1, "INVTYPE_CLOAK", 133762, 30, 4, 1, 2, None)
        M.AddItem(14106, "Felcloth Robe", 3, 61, 56, "Armor", "Cloth", 1, "INVTYPE_ROBE", 132683, 9000, 4, 1, 2, None)
        M.AddItem(14112, "Felcloth Shoulders", 3, 62, 57, "Armor", "Cloth", 1, "INVTYPE_SHOULDER", 135056, 8000, 4, 1, 2, None)
        M.AddSpell(18451, "Felcloth Robe")
        M.AddSpell(18453, "Felcloth Shoulders")
        M.Setup()
        self.G = rt.globals()
        self.Game = M.Game
        self.json_of = rt.eval("function(M, v) return M.JSON(v) end")
        # addon
        self.ns = rt.eval("{}")
        self.load_ok = True
        for rel in toc_files:
            path = os.path.join(ADDON_DIR, rel)
            if not os.path.exists(path):
                self.harness_error("TOC lists a missing file: %s" % rel)
                continue
            src = open(path, "rb").read()
            if src.startswith(b"\xef\xbb\xbf"):
                src = src[3:]
            chunk = "@" + ADDON + "/" + rel.replace("\\", "/")
            ok = M.LoadAddonFile(src, chunk, ADDON, self.ns)
            if not ok:
                self.load_ok = False
        self.harness_errors = []

    # --- helpers -------------------------------------------------------------
    def harness_error(self, msg):
        if not hasattr(self, "harness_errors"):
            self.harness_errors = []
        self.harness_errors.append(msg)
        log("  !! [%s] harness: %s" % (self.name, msg))

    def lua(self, code, *args):
        """Runs a Lua snippet (as harness code) with ... = args; errors recorded, never raised."""
        fn = self.rt.eval("function(M, code, ...) local f, e = loadstring(code, '=harness') if not f then error(e) end "
                          "return M.HarnessCall('harness snippet', f, ...) end")
        return fn(self.MOCK, code, *args)

    def lua_hw(self, code, *args):
        """Like lua() but as a hardware event (the user clicked the button that does this)."""
        fn = self.rt.eval("function(M, code, ...) local f, e = loadstring(code, '=harness') if not f then error(e) end "
                          "return M.HardwareCall('harness snippet', f, ...) end")
        return fn(self.MOCK, code, *args)

    def fire(self, event, *args):
        try:
            return self.MOCK.FireEvent(event, *args)
        except lua51.LuaError as e:
            self.harness_error("FireEvent(%s): %s" % (event, u8(str(e))))
            return 0

    def call(self, label, fn, *args):
        return self.MOCK.HarnessCall(label, fn, *args)

    def jsonv(self, v):
        return json.loads(u8(self.json_of(self.MOCK, v)))

    def eval_json(self, expr):
        s = self.rt.eval("function(M) local ok, v = pcall(function() return %s end) if not ok then return M.JSON({__error = tostring(v)}) end return M.JSON(v) end" % expr)(self.MOCK)
        return json.loads(u8(s))

    def set_scenario(self, label):
        self.MOCK.scenario = label

    @property
    def GF(self):
        return self.G.Greenfields

    @property
    def UI(self):
        gf = self.GF
        return gf.UI if gf is not None else None


# ---------------------------------------------------------------------------
# The simulation: clock, bus, chat router, group server
# ---------------------------------------------------------------------------
class Sim:
    made = []   # every Sim this run built, for the run-wide guards

    def __init__(self, n_clients, label):
        self.label = label
        self.epoch = float(EPOCH0)
        self.uptime = UPTIME0
        toc_files, toc_meta = read_toc()
        self.toc_files = toc_files
        metrics = load_font_metrics()
        spells, items = scan_buff_data()
        defs, world, members = build_world(n_clients)
        self.world = {w["name"]: w for w in world}
        self.defs = {d["name"]: d for d in defs}
        self.clients = []
        t0 = time.time()
        for i, d in enumerate(defs):
            seed = (zlib.crc32(d["name"].encode()) & 0x7fffffff) or 1
            self.clients.append(Client(self, d, world, members, toc_files, toc_meta, metrics, spells, items, seed))
        self.by_name = {c.name: c for c in self.clients}
        vlog("built %d clients in %.1fs" % (len(self.clients), time.time() - t0))
        self.group = None          # {"kind", "members": [ {...} ]}
        self.scheduled = []        # (due uptime, seq, fn)
        self.seq = 0
        self.comm = {}             # op -> {"count", "bytes", "chunks"}
        self.comm_by_client = {}   # client -> op -> {...}
        self.chat_routed = []
        self.invites = []
        self.whispered = {}        # op -> addon whispers that actually arrived
        self.bounced = []          # whispers the "server" refused: {from, target, op, bare}
        self.bare_on_purpose = False   # a test sending a bare name itself: the run-wide guard leaves it alone
        self.ticks = 0
        Sim.made.append(self)

    # --- time ----------------------------------------------------------------
    def schedule(self, delay, fn):
        self.seq += 1
        self.scheduled.append((self.uptime + delay, self.seq, fn))
        self.scheduled.sort()

    def tick(self):
        self.ticks += 1
        self.uptime = round(self.uptime + TICK, 4)
        self.epoch = self.epoch + TICK
        while self.scheduled and self.scheduled[0][0] <= self.uptime + 1e-9:
            _, _, fn = self.scheduled.pop(0)
            fn()
        self.route()
        for c in self.clients:
            if not c.online:
                continue
            pend, c.pending = c.pending, []
            for kind, args in pend:
                try:
                    if kind == "addon":
                        c.Game.DeliverAddon(*args)
                    elif kind == "chat":
                        c.Game.DeliverChat(*args)
                    elif kind == "call":
                        args[0]()
                except lua51.LuaError as e:
                    c.harness_error("delivery %s: %s" % (kind, u8(str(e))))
            try:
                c.MOCK.Tick(int(self.epoch), self.uptime, TICK)
            except lua51.LuaError as e:
                c.harness_error("Tick: %s" % u8(str(e)))

    def advance(self, sec):
        n = int(round(sec / TICK))
        for _ in range(n):
            self.tick()
        self.route()

    def online_clients(self):
        return [c for c in self.clients if c.online]

    # --- routing --------------------------------------------------------------
    def group_names(self):
        return [m["name"] for m in self.group["members"]] if self.group else []

    def route(self):
        for c in self.online_clients():
            out = c.Game.TakeOutbox()
            for i in range(1, len(out) + 1):
                m = out[i]
                self.route_addon(c, u8(m.prefix), m.text, u8(m.chatType), u8(m.target) if m.target else None, bool(m.logged))
            reqs = c.Game.TakeRequests()
            for i in range(1, len(reqs) + 1):
                self.handle_request(c, reqs[i])

    def reach(self, target):
        """Who a whisper to `target` gets to, the way the real client works it out: Forever wants the
        full "Name Surname" the guild roster shows, and looks the person up by the first word. Returns
        (client or None, bounced, bare). No client and no bounce: someone online without the addon."""
        t = target or ""
        bare = " " not in t and "-" not in t       # "Randy-Yojamba" is what the raid list hands over
        first = re.split(r"[ -]", t)[0]
        if bare:
            return None, True, True
        c = self.by_name.get(first)
        if c:
            return (c, False, False) if c.online else (None, True, False)
        return None, first not in self.world, False

    def bounce(self, c, target, op):
        self.bounced.append({"from": c.name, "target": target, "op": op, "bare": " " not in (target or "") and "-" not in (target or ""),
                             "onPurpose": self.bare_on_purpose})
        self.chat_to([c], "CHAT_MSG_SYSTEM", u8(c.G.ERR_CHAT_PLAYER_NOT_FOUND_S) % target, "")

    def comm_note(self, sender, channel, text):
        # reassemble to count logical messages per op; returns the op once a message is whole
        stats = self.comm_by_client.setdefault(sender.name, {})
        h, body = text[:1], text[1:]
        key = (channel,)
        full = None
        if h == "1":
            full = body
        elif h == "2":
            sender.reasm[key] = [body]
        elif h == "3":
            sender.reasm.setdefault(key, []).append(body)
        elif h == "4":
            parts = sender.reasm.pop(key, [])
            parts.append(body)
            full = "".join(parts)
        op = None
        nparts = 0
        if full is not None:
            op = wire_op(full)
            nparts = 1 if h == "1" else len(full) // 250 + 1
        for table in (self.comm, stats):
            if op is not None:
                e = table.setdefault(op, {"count": 0, "bytes": 0, "parts": 0})
                e["count"] += 1
                e["parts"] += nparts
            e2 = table.setdefault("_all", {"count": 0, "bytes": 0, "parts": 0})
            e2["parts"] += 1
            e2["bytes"] += len(text)
            if op is not None:
                e2["count"] += 1
        if op is not None:
            size = len(full) + (len(text) - len(body))
            for table in (self.comm, stats):
                table[op]["bytes"] += size
        return op

    def route_addon(self, sender, prefix, text, chat_type, target, logged):
        op = self.comm_note(sender, chat_type, text)
        sender_full = sender.name + "-" + REALM
        recips = []
        if chat_type in ("GUILD", "OFFICER"):
            for c in self.online_clients():
                if chat_type == "OFFICER" and self.defs[c.name]["rank"] > 1:
                    continue
                recips.append(c)
        elif chat_type in ("RAID", "PARTY", "INSTANCE_CHAT"):
            names = self.group_names()
            for c in self.online_clients():
                if c.name in names:
                    recips.append(c)
        elif chat_type == "WHISPER":
            c, bounced, _ = self.reach(target)
            if c:
                recips.append(c)
                if op:
                    self.whispered[op] = self.whispered.get(op, 0) + 1
            elif bounced:
                self.bounce(sender, target, op or "part")
        for c in recips:
            c.pending.append(("addon", (prefix, text, chat_type, sender_full, target or "", logged)))

    def chat_to(self, clients, event, text, sender, opts=None):
        for c in clients:
            if opts:
                c.pending.append(("call", (lambda c=c: c.Game.DeliverChat(event, text, sender, c.rt.execute("return " + to_lua(opts))),)))
            else:
                c.pending.append(("chat", (event, text, sender)))

    def group_clients(self):
        names = self.group_names()
        return [c for c in self.online_clients() if c.name in names]

    def handle_request(self, c, r):
        kind = u8(r.kind)
        if kind == "chat":
            ct, text, target = u8(r.chatType), r.text, u8(r.target) if r.target else None
            self.chat_routed.append({"from": c.name, "chatType": ct, "text": u8(text), "target": target})
            leader = self.group_leader()
            if ct in ("GUILD", "OFFICER"):
                self.chat_to(self.online_clients(), "CHAT_MSG_" + ct, text, c.name)
            elif ct in ("RAID", "RAID_WARNING", "PARTY", "INSTANCE_CHAT"):
                ev = "CHAT_MSG_" + ct
                if ct in ("RAID", "PARTY", "INSTANCE_CHAT") and leader == c.name:
                    ev += "_LEADER"
                self.chat_to(self.group_clients(), ev, text, c.name)
            elif ct == "WHISPER":
                tc, bounced, _ = self.reach(target)
                if bounced:
                    self.bounce(c, target, "chat")
                else:
                    if tc:
                        self.chat_to([tc], "CHAT_MSG_WHISPER", text, c.name)
                    self.chat_to([c], "CHAT_MSG_WHISPER_INFORM", text, target)
            elif ct in ("SAY", "YELL", "EMOTE"):
                self.chat_to([c], "CHAT_MSG_" + ct, text, c.name)
        elif kind == "roll":
            fmt = u8(c.G.RANDOM_ROLL_RESULT) or "%s rolls %d (%d-%d)"
            text = fmt % (u8(r.name), int(r.roll), int(r.lo), int(r.hi))
            targets = self.group_clients() if self.group and c.name in self.group_names() else [c]
            self.chat_to(targets, "CHAT_MSG_SYSTEM", text, "")
        elif kind == "lootline":
            link = u8(c.MOCK.ItemLink(int(r.item)))
            text = "%s receives loot: %s." % (c.name, link)
            self.chat_to([x for x in self.group_clients() if x is not c], "CHAT_MSG_LOOT", text, c.name)
        elif kind == "invite":
            self.invites.append({"from": c.name, "target": u8(r.target), "onPurpose": self.bare_on_purpose})
            # nobody's proven whether invites need the full name, so the sim takes either
            t = self.by_name.get(re.split(r"[ -]", u8(r.target) or "")[0])
            if t and t.online:
                t.pending.append(("call", (lambda t=t, n=c.name: t.fire("PARTY_INVITE_REQUEST", n, False, False, False, False, False, None, False, None),)))
        elif kind == "convert":
            if self.group and self.group["kind"] == "party" and self.group_leader() == c.name:
                self.group["kind"] = "raid"
                self.push_group()
                self.chat_to(self.group_clients(), "CHAT_MSG_SYSTEM", "Party converted to Raid", "")
        elif kind in ("subgroup", "swap"):
            g = self.group
            if g and g["kind"] == "raid":
                if kind == "subgroup":
                    i, sg = int(r.index), int(r.subgroup)
                    if 1 <= i <= len(g["members"]):
                        if sum(1 for m in g["members"] if m["subgroup"] == sg) < 5:
                            g["members"][i - 1]["subgroup"] = sg
                else:
                    a, b = int(r.a), int(r.b)
                    if 1 <= a <= len(g["members"]) and 1 <= b <= len(g["members"]):
                        ma, mb = g["members"][a - 1], g["members"][b - 1]
                        ma["subgroup"], mb["subgroup"] = mb["subgroup"], ma["subgroup"]
                self.schedule(0.2, self.push_group)
        elif kind == "readycheck":
            for x in self.group_clients():
                x.pending.append(("call", (lambda x=x, n=c.name: x.Game.ReadyCheck(n, 35),)))
        elif kind == "opentradeskill":
            line = int(r.line)
            spec = BAZZA_TAILORING if (c.name == "Bazza" and line == 197) else self.tradeskill_spec(c, line)
            c.pending.append(("call", (lambda c=c, s=spec: c.Game.OpenTradeSkill(c.rt.execute("return " + to_lua(s))),)))
        # emote / typed / rollonloot / readyconfirm / lead / assist / leave: logged only
        else:
            vlog("[%s] request %s" % (c.name, kind))

    def tradeskill_spec(self, c, line):
        d = self.defs[c.name]
        p = None
        for slot, pr in d.get("profs", {}).items():
            if pr["skillLine"] == line:
                p = pr
        recipes = [{"recipeID": sid, "name": "", "learned": True, "difficulty": 2, "skillUps": 1} for sid in d.get("known", [])[:6]]
        return {"skillLine": line, "name": (p or {}).get("name", "?"), "rank": (p or {}).get("rank", 1),
                "max": (p or {}).get("max", 300), "recipes": recipes}

    # --- group server ----------------------------------------------------------
    def group_leader(self):
        if not self.group:
            return None
        for m in self.group["members"]:
            if m.get("rank") == 2:
                return m["name"]
        return None

    def push_group(self):
        for c in self.online_clients():
            spec = None
            if self.group:
                spec = c.rt.execute("return " + to_lua(self.group))
            try:
                c.Game.SetGroup(spec)
            except lua51.LuaError as e:
                c.harness_error("SetGroup: %s" % u8(str(e)))

    def set_group(self, kind, names, leader, assists=(), subgroups=None):
        members = []
        for i, n in enumerate(names):
            w = self.world[n]
            sg = subgroups[i] if subgroups else (i // 5) + 1
            role = {"WARRIOR": "TANK", "PRIEST": "HEALER", "PALADIN": "HEALER", "DRUID": "HEALER", "SHAMAN": "HEALER"}.get(w["class"], "DAMAGER")
            if n == "Spencer":
                role = "TANK"
            members.append({"name": n, "realm": w["realm"], "subgroup": sg,
                            "rank": 2 if n == leader else (1 if n in assists else 0),
                            "combatRole": role, "role": "MAINTANK" if n == leader and w["class"] == "WARRIOR" else None,
                            "isML": False, "online": True, "dead": False, "zone": None, "level": w["level"]})
        self.group = {"kind": kind, "category": 1, "members": members}
        self.push_group()

    def clear_group(self):
        self.group = None
        self.push_group()

    def set_member(self, name, **kw):
        if not self.group:
            return
        for m in self.group["members"]:
            if m["name"] == name:
                m.update(kw)
        for c in self.online_clients():
            for k, v in kw.items():
                c.Game.SetMemberState(name, k, v)

    # --- login -------------------------------------------------------------------
    def login(self, c):
        c.online = True
        c.set_scenario("boot")
        for ev, args in (("ADDON_LOADED", (ADDON,)), ("SPELLS_CHANGED", ()), ("PLAYER_LOGIN", ()),
                         ("PLAYER_ENTERING_WORLD", (True, False)), ("ZONE_CHANGED_NEW_AREA", ()), ("BAG_UPDATE_DELAYED", ())):
            c.fire(ev, *args)

        def roster():
            c.Game.RosterLoaded()
            c.fire("PLAYER_GUILD_UPDATE", "player")
            c.fire("GUILD_ROSTER_UPDATE", False)
        self.schedule(1.0, roster)
        for o in self.online_clients():
            if o is c:
                continue
            o.Game.SetMemberOnline(c.name, True, c.d["zone"])
            c.Game.SetMemberOnline(o.name, True, o.d["zone"])
            self.chat_to([o], "CHAT_MSG_SYSTEM", "|Hplayer:%s|h[%s]|h has come online." % (c.name, c.name), "")
            o.pending.append(("call", (lambda o=o: o.fire("GUILD_ROSTER_UPDATE", False),)))

    def boot(self, stagger=7.0, settle=120.0):
        for i, c in enumerate(self.clients):
            self.login(c)
            if i < len(self.clients) - 1:
                self.advance(stagger)
        self.advance(settle)

    # --- data views ----------------------------------------------------------------
    def store_of(self, c):
        return c.eval_json("(function() local GF = rawget(_G, 'Greenfields') local db = rawget(_G, 'GreenfieldsDB') "
                           "if not (GF and db and db.guilds) then return {} end return db.guilds[GF.gdbKey] and db.guilds[GF.gdbKey].store or {} end)()")


# ---------------------------------------------------------------------------
# Results collection
# ---------------------------------------------------------------------------
class Results:
    def __init__(self):
        self.scenarios = {}
        self.clients = {}       # "<sim>/<client>" -> report
        self.renders = []
        self.harness_failures = []

    def scenario(self, name):
        return self.scenarios.setdefault(name, {"status": "ok", "notes": [], "checks": []})


def compare_datasets(sim, names=None):
    stores = {c.name: sim.store_of(c) for c in sim.online_clients()}
    mismatches = []
    datasets = set()
    for s in stores.values():
        datasets.update(s.keys())
    if names:
        datasets = [d for d in datasets if d in names] + [d for d in names if d not in datasets]
    summary = {}
    for ds in sorted(datasets):
        ids = set()
        for s in stores.values():
            ids.update((s.get(ds) or {}).keys())
        summary[ds] = {"docs": len(ids)}
        for doc_id in sorted(ids):
            seen = {}
            for cname, s in stores.items():
                rec = (s.get(ds) or {}).get(doc_id)
                seen[cname] = None if rec is None else json.dumps([rec.get("r"), rec.get("a"), rec.get("x"), rec.get("d")], sort_keys=True)
            if len(set(seen.values())) > 1:
                detail = {}
                for cname, v in seen.items():
                    if v is None:
                        detail[cname] = "missing"
                    else:
                        r = json.loads(v)
                        detail[cname] = "rev %s by %s%s" % (r[0], r[1], " (deleted)" if r[2] else "")
                mismatches.append({"dataset": ds, "id": doc_id, "clients": detail})
        if not ids:
            summary[ds]["note"] = "no documents on any client"
    return mismatches, summary


# ---------------------------------------------------------------------------
# Scenarios
# ---------------------------------------------------------------------------
def scenario_boot(sim, res, verify=True):
    t0 = time.time()
    sim.boot()
    sc = res.scenario("boot")
    sc["time"] = round(time.time() - t0, 1)
    for c in sim.clients:
        gk = c.eval_json("rawget(_G, 'Greenfields') and Greenfields.gdbKey")
        sc["checks"].append({"client": c.name, "guildKey": gk, "addonLoaded": c.load_ok})
    if verify:
        mism, summary = compare_datasets(sim, ["profile", "stats"])
        sc["datasets"] = summary
        sc["mismatches"] = mism
        if mism:
            sc["status"] = "mismatch"
            sc["notes"].append("%d profile/stats docs differ between clients after 120 s" % len(mism))
        for ds in ("profile", "stats"):
            n = summary.get(ds, {}).get("docs", 0)
            if n < len(sim.clients):
                sc["notes"].append("%s: only %d docs for %d clients" % (ds, n, len(sim.clients)))
                if sc["status"] == "ok":
                    sc["status"] = "incomplete"


def page_list(c):
    pl = c.UI.pageList
    out = []
    for i in range(1, len(pl) + 1):
        d = pl[i]
        hidden = False
        if d.hidden:
            try:
                hidden = bool(c.call("page hidden()", d.hidden))
            except lua51.LuaError:
                hidden = True
        out.append((u8(d.key), hidden))
    return out


CANCEL_RE = re.compile(r"\b(cancel|nah|close|no|done|back|ok|okay)\b", re.I)


def main_frame(c):
    return c.G[MAIN_FRAME]


def ensure_page(sim, c, key, arg):
    mf = main_frame(c)
    if mf is None:
        return False
    UI = c.UI
    if not c.MOCK.IsVisible(mf) or u8(UI.CurrentPage(UI) or "") != key:
        c.MOCK.HideSpecials(MAIN_FRAME)
        c.call("ShowPage " + key, UI.ShowPage, UI, key, arg)
        c.MOCK.Flush()
        return True
    return False


def dismiss(sim, c, budget):
    """After a click: answer popups once (type + primary for prompts, cancel otherwise), then
    Escape everything except the main window."""
    M = c.MOCK
    if M.focus is not None:
        M.UserKey(M.focus, "ESCAPE")
        if M.focus is not None:
            M.ClearFocus(M.focus)
    specials = M.VisibleSpecials(MAIN_FRAME)
    if len(specials) > 0 and budget["popups"] > 0:
        budget["popups"] -= 1
        f = specials[1]
        boxes = M.CollectVisible(f, "EditBox")
        buttons = M.CollectVisible(f, "Button,CheckButton")
        typed = False
        for i in range(1, len(boxes) + 1):
            type_text(sim, c, boxes[i], "Fuzzy 123")
            typed = True
        choice = None
        cancels, others = [], []
        for i in range(1, len(buttons) + 1):
            b = buttons[i]
            t = u8(M.ButtonText(b) or "")
            (cancels if CANCEL_RE.search(t) else others).append(b)
        if typed and others:
            choice = others[-1]
        elif cancels:
            choice = cancels[0]
        elif others:
            choice = others[0]
        if choice is not None and M.IsVisible(choice):
            c.Game.CursorTo(choice)
            M.UserClick(choice, "LeftButton")
        sim.tick()
    M.HideSpecials(MAIN_FRAME)
    tt = c.G.GameTooltip
    if tt is not None and tt.IsShown(tt):
        tt.Hide(tt)


def type_text(sim, c, box, text):
    """Types like a fast typist: clear, then one character per tick (20 chars/s), so
    debounced handlers see realistic timing."""
    M = c.MOCK
    M.UserType(box, "", True)
    for ch in text:
        if not M.IsVisible(box):
            break
        M.UserType(box, ch, False)
        sim.tick()


def click_button(sim, c, key, arg, b, stats, budget, button="LeftButton"):
    M = c.MOCK
    ensure_page(sim, c, key, arg)
    if not M.IsVisible(b):
        stats["skipped"] = stats.get("skipped", 0) + 1
        return False
    c.Game.CursorTo(b)
    M.UserEnter(b)
    M.UserLeave(b)
    if not M.IsVisible(b):
        return False
    M.UserClick(b, button)
    stats["clicks"] = stats.get("clicks", 0) + 1
    sim.tick()
    if button == "LeftButton" and M.IsVisible(b) and M.RegisteredFor(b, "RightButton"):
        ensure_page(sim, c, key, arg)
        if M.IsVisible(b):
            M.UserClick(b, "RightButton")
            stats["clicks"] += 1
            sim.tick()
    dismiss(sim, c, budget)
    return True


def fuzz_root(sim, c, key, arg, root, stats, label, max_buttons=400, shift_pass=40):
    """Hover + click every visible Button/CheckButton under root (a second pass picks up
    buttons the first pass revealed), a shift-click pass, hover every mouse-aware frame,
    type into every EditBox (+ Enter), and wheel every scrollable frame."""
    M = c.MOCK
    budget = {"popups": 16}
    done = set()
    for pass_no in (1, 2):
        ensure_page(sim, c, key, arg)
        targets = M.CollectVisible(root, "Button,CheckButton,DropdownButton")
        n = len(targets)
        buttons = []
        for i in range(1, n + 1):
            oid = int(M.ObjId(targets[i]))
            if oid not in done:
                done.add(oid)
                buttons.append(targets[i])
        if len(buttons) > max_buttons:
            stats.setdefault("notes", []).append("%s pass %d: %d buttons, fuzzed first %d" % (label, pass_no, len(buttons), max_buttons))
            buttons = buttons[:max_buttons]
        stats["buttons"] = stats.get("buttons", 0) + len(buttons)
        for b in buttons:
            click_button(sim, c, key, arg, b, stats, budget)
    if shift_pass:
        ensure_page(sim, c, key, arg)
        targets = M.CollectVisible(root, "Button,CheckButton")
        c.Game.SetModifiers(True, False, False)
        for i in range(1, min(len(targets), shift_pass) + 1):
            click_button(sim, c, key, arg, targets[i], stats, budget)
            stats["shiftClicks"] = stats.get("shiftClicks", 0) + 1
        c.Game.SetModifiers(False, False, False)
        dismiss(sim, c, budget)
    ensure_page(sim, c, key, arg)
    hov = M.CollectHoverables(root)
    for i in range(1, min(len(hov), 300) + 1):
        f = hov[i]
        if not M.IsVisible(f):
            continue
        c.Game.CursorTo(f)
        M.UserEnter(f)
        M.UserLeave(f)
        stats["hovers"] = stats.get("hovers", 0) + 1
    ensure_page(sim, c, key, arg)
    boxes = M.CollectVisible(root, "EditBox")
    for i in range(1, len(boxes) + 1):
        box = boxes[i]
        for text in ("Bazza", "12345 the quick brown fox", ""):
            ensure_page(sim, c, key, arg)
            if not M.IsVisible(box):
                break
            type_text(sim, c, box, text)
            M.UserKey(box, "ENTER")
            sim.tick()
            stats["typed"] = stats.get("typed", 0) + 1
            if M.IsVisible(box):
                M.UserKey(box, "ESCAPE")
            dismiss(sim, c, budget)
    ensure_page(sim, c, key, arg)
    wheels = M.CollectWheel(root)
    for i in range(1, len(wheels) + 1):
        w = wheels[i]
        for delta in (-1, -1, -1, -1, 1, 1, 1, 1):
            if M.IsVisible(w):
                M.UserWheel(w, delta)
                stats["wheels"] = stats.get("wheels", 0) + 1
    sim.tick()


def export_scene(c, path):
    s = c.json_of(c.MOCK, c.MOCK.ExportScene(None))
    data = u8(s)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(data)
    return json.loads(data)


def queue_render(res, c, scene, scene_path, out_png, crop_frame=MAIN_FRAME, pad=30):
    crop = None
    frames = scene.get("frames", [])
    for f in frames:
        if f.get("name") == crop_frame:
            x, y, w, h = f["rect"]
            crop = [max(0, x - pad), max(0, y - pad), w + 2 * pad, h + 2 * pad]
    res.renders.append({"scene": scene_path, "out": out_png, "crop": crop})
    toast = any(f.get("type") == "Button" and "UI/Toast.lua" in (f.get("where") or "") for f in frames)
    if toast:
        res.renders.append({"scene": scene_path, "out": out_png.replace(".png", "-screen.png"), "crop": None})
    return toast


def error_count(c):
    n1 = c.rt.eval("function(M) return #M.errors end")(c.MOCK)
    n2 = c.rt.eval("function() local GF = rawget(_G, 'Greenfields') return GF and GF.errors and #GF.errors or 0 end")()
    return int(n1), int(n2)


def scenario_pages(sim, res, render_dir, sizes=True, name="pages", clients=None, combat=False, arg_key="Bazza",
                   render_clients=None, suffix=""):
    sc = res.scenario(name)
    t0 = time.time()
    sc.setdefault("pages", {})
    scene_dir = None
    if render_dir:
        scene_dir = os.path.join(render_dir, "scenes")
        os.makedirs(scene_dir, exist_ok=True)
    for c in (clients or sim.clients):
        UI = c.UI
        if UI is None:
            c.harness_error("Greenfields.UI missing; pages skipped")
            continue
        c.set_scenario(name + ":open")
        c.call("UI:OpenMain", UI.OpenMain, UI)
        sim.advance(1.0)
        if combat:
            c.Game.SetCombat(True)
            sim.advance(0.5)
        pages = page_list(c)
        for key, hidden in pages:
            label = name + ":" + key
            c.set_scenario(label)
            e0 = error_count(c)
            arg = arg_key if key == "profile" else None
            stats = {"hidden": hidden}
            c.MOCK.HideSpecials(MAIN_FRAME)
            c.call("ShowPage " + key, UI.ShowPage, UI, key, arg)
            sim.advance(1.0)
            c.MOCK.CheckLayout()
            if scene_dir and (render_clients is None or c.name in render_clients):
                sp = os.path.join(scene_dir, "%s-%s%s.json" % (c.name, key, suffix))
                scene = export_scene(c, sp)
                png = os.path.join(render_dir, "%s-%s%s.png" % (c.name, key, suffix))
                stats["toast"] = queue_render(res, c, scene, sp, png)
                stats["items"] = len(scene.get("items", []))
            page = UI.pages[key]
            pf = page.frame if page is not None else None
            if pf is not None:
                try:
                    fuzz_root(sim, c, key, arg, pf, stats, label)
                except Exception:
                    tb = traceback.format_exc()
                    res.harness_failures.append("fuzz %s/%s: %s" % (c.name, key, tb))
                    log(tb)
                    stats["harnessFailure"] = tb.strip().splitlines()[-1]
            if sizes:
                mf = main_frame(c)
                for (w, h) in ((900, 580), (1400, 900)):
                    c.set_scenario("%s@%dx%d" % (label, w, h))
                    mf.SetSize(mf, w, h)
                    c.MOCK.Flush()
                    c.call("ShowPage " + key, UI.ShowPage, UI, key, arg)
                    sim.advance(0.5)
                    c.MOCK.CheckLayout()
                    if scene_dir and key == "home":
                        sp = os.path.join(scene_dir, "%s-%s-%dx%d.json" % (c.name, key, w, h))
                        scene = export_scene(c, sp)
                        queue_render(res, c, scene, sp, os.path.join(render_dir, "%s-%s-%dx%d.png" % (c.name, key, w, h)))
                mf.SetSize(mf, 1040, 680)
                c.MOCK.Flush()
                c.set_scenario(label)
            e1 = error_count(c)
            stats["newErrors"] = {"harness": e1[0] - e0[0], "addon": e1[1] - e0[1]}
            sc["pages"]["%s/%s" % (c.name, key)] = stats
            vlog("[%s] %s %-12s buttons=%s clicks=%s new errors=%s" % (c.name, name, key, stats.get("buttons"), stats.get("clicks"), stats["newErrors"]))
        # main window chrome (header buttons, nav, me card, grip)
        c.set_scenario(name + ":chrome")
        e0 = error_count(c)
        c.call("ShowPage home", UI.ShowPage, UI, "home", None)
        sim.advance(0.5)
        mf = main_frame(c)
        stats = {}
        content = mf.content
        chrome = c.MOCK.CollectVisible(mf, "Button,CheckButton")
        lst = [chrome[i] for i in range(1, len(chrome) + 1) if not c.MOCK.IsDescendant(chrome[i], content)]
        budget = {"popups": 6}
        for b in lst:
            click_button(sim, c, "home", None, b, stats, budget)
        e1 = error_count(c)
        stats["newErrors"] = {"harness": e1[0] - e0[0], "addon": e1[1] - e0[1]}
        sc["pages"]["%s/(chrome)" % c.name] = stats
        # the changelog popup: long wrapped notes must size the dialog (rendered for the first client)
        if scene_dir and c is (clients or sim.clients)[0]:
            c.set_scenario(name + ":changelog")
            c.lua_hw("SlashCmdList.GREENFIELDS('changelog')")
            sim.advance(0.5)
            c.MOCK.CheckLayout()
            sp = os.path.join(scene_dir, "%s-changelog%s.json" % (c.name, suffix))
            queue_render(res, c, export_scene(c, sp), sp, os.path.join(render_dir, "%s-changelog%s.png" % (c.name, suffix)),
                         crop_frame="GreenfieldsModal")
            c.lua_hw("Greenfields.UI:CloseModal()")
            sim.advance(0.2)
        if combat:
            c.Game.SetCombat(False)
        c.MOCK.HideSpecials(None)
        sim.advance(1.0)
    sc["time"] = round(sc.get("time", 0) + time.time() - t0, 1)
    bad = [k for k, v in sc["pages"].items() if (v.get("newErrors") or {}).get("harness") or (v.get("newErrors") or {}).get("addon")]
    sc["pagesWithErrors"] = bad
    if bad:
        sc["status"] = "errors"


def raid_sequence(sim, res, sc_name):
    sc = res.scenario(sc_name)
    clients = sim.clients
    names = [c.name for c in clients]
    sp, bz, sh = (sim.by_name.get(n) for n in ("Spencer", "Bazza", "Shazza"))
    host = sp or clients[0]
    for c in clients:
        c.set_scenario(sc_name)
    # raid-night prep through the addon's own public APIs (what the officer/raiders would
    # click): an event starting in 10 minutes, sign-ups, an SR session and two reserves
    prep = sc.setdefault("prep", {})
    r = host.lua_hw("local R = Greenfields.Raids if not (R and R.CreateEvent) then return false, 'no GF.Raids' end "
                    "local ok, ids = R:CreateEvent({ title = 'Hyjal Wednesday', instance = 'Hyjal Summit', "
                    "time = GetServerTime() + 600, duration = 10800, srLimit = 2, notes = 'Bring flasks.' }, 1) "
                    "return ok, type(ids) == 'table' and ids[1] or ids")
    event_id = None
    if isinstance(r, tuple) and len(r) >= 3 and r[1]:
        event_id = u8(r[2])
    prep["event"] = event_id or u8(str(r[2] if isinstance(r, tuple) and len(r) > 2 else r))
    sim.advance(5)
    if event_id:
        for c in clients:
            status = "late" if c.name == "Shazza" else "yes"
            c.lua_hw("local R = Greenfields.Raids return R:SetSignup(..., '%s', nil, 'keen as')" % status, event_id)
        sim.advance(5)
    r = host.lua_hw("local SR = Greenfields.SR if not (SR and SR.Start) then return false, 'no GF.SR' end "
                    "return SR:Start({ title = 'Hyjal SR', instance = 'Hyjal Summit', eventId = ..., limit = 2 })", event_id)
    prep["srSession"] = [u8(x) if isinstance(x, (str, bytes)) else x for x in (r if isinstance(r, tuple) else (r,))]
    sim.advance(5)
    for c, item in ((bz, LOOT_ITEMS[0]), (sh, LOOT_ITEMS[1])):
        if c is not None:
            c.lua_hw("local SR = Greenfields.SR return SR and SR.AddReserve and SR:AddReserve(...)", item)
    sim.advance(10)
    # form the group: party first, then convert to raid and fill up
    party = names[:min(5, len(names))]
    while len(party) < 5:
        party.append(RAID_FAKES[len(party) - len(names)])
    sim.set_group("party", party[:5], host.name)
    sim.advance(2)
    raid = names + [n for n in RAID_FAKES][:max(0, 10 - len(names))]
    sim.set_group("raid", raid, host.name, assists=("Bazza",) if "Bazza" in names else ())
    sim.chat_to(sim.group_clients(), "CHAT_MSG_SYSTEM", "Party converted to Raid", "")
    for n in raid:
        if n != host.name:
            sim.chat_to([host], "CHAT_MSG_SYSTEM", "%s has joined the raid group." % n, "")
    sim.advance(5)
    # buffs on everyone (as each client would see them)
    auras = {
        "Spencer": [{"spellId": 25289, "duration": 180, "remaining": 150}, {"spellId": 10938, "duration": 3600, "remaining": 3000},
                    {"spellId": 10157, "duration": 3600, "remaining": 2900}],
        "Bazza": [{"spellId": 10938, "duration": 3600, "remaining": 3000}, {"spellId": 27841, "duration": 3600, "remaining": 3100},
                  {"spellId": 10157, "duration": 3600, "remaining": 2900}],
        "Shazza": [{"spellId": 10938, "duration": 3600, "remaining": 3000}, {"spellId": 10157, "duration": 3600, "remaining": 2900},
                   {"spellId": 1229741, "duration": 3600, "remaining": 1800}, {"spellId": 1229513, "duration": 3600, "remaining": 1800, "hidden": True}],
        "Davo": [{"spellId": 25289, "duration": 180, "remaining": 150}],
        "Kylie": [{"spellId": 25898, "duration": 3600, "remaining": 3000}],
    }
    for c in sim.online_clients():
        for who, lst in auras.items():
            c.Game.SetAuras(who, c.rt.execute("return " + to_lua(lst)))
    sim.advance(1)
    # enter Hyjal Summit
    for c in sim.group_clients():
        c.Game.EnterInstance(c.rt.execute("return " + to_lua(HYJAL)))
    sim.advance(5)
    # ready check
    rc = sim.group_clients()
    for c in rc:
        c.Game.ReadyCheck(host.name, 35)
    sim.advance(1)
    for n in raid:
        for c in rc:
            c.Game.ReadyConfirm(n, n != "Randy")
    sim.advance(1)
    for c in rc:
        c.Game.ReadyFinished()
    sim.advance(2)

    def all_fire(ev, *args):
        for c in sim.group_clients():
            c.fire(ev, *args)

    # pull 1: wipe (Shazza dies first)
    for c in sim.group_clients():
        c.Game.SetCombat(True)
    all_fire("ENCOUNTER_START", 3001, "Bandalar", 1, 20)
    sim.advance(8)
    if sh:
        sh.Game.Die()
        sim.set_member("Shazza", dead=True)
    sim.advance(10)
    for n in raid:
        sim.set_member(n, dead=True)
    all_fire("ENCOUNTER_END", 3001, "Bandalar", 1, 20, 0)
    for c in sim.group_clients():
        c.Game.SetCombat(False)
    sim.advance(3)
    if sh:
        sh.Game.Release()
        sim.advance(2)
        sh.Game.Resurrect()
    for n in raid:
        sim.set_member(n, dead=False)
    sim.advance(20)
    # pull 2: kill
    for c in sim.group_clients():
        c.Game.SetCombat(True)
    all_fire("ENCOUNTER_START", 3001, "Bandalar", 1, 20)
    sim.advance(30)
    all_fire("ENCOUNTER_END", 3001, "Bandalar", 1, 20, 1)
    all_fire("BOSS_KILL", 3001, "Bandalar")
    for c in sim.group_clients():
        c.Game.SetCombat(False)
    sim.advance(3)
    # loot on the host: 3 rare/epic items + coin + a common
    slots = [{"kind": "item", "id": i, "count": 1} for i in LOOT_ITEMS] + \
            [{"kind": "money", "copper": 352718}, {"kind": "item", "id": 14047, "count": 3}]
    host.Game.OpenLoot(host.rt.execute("return " + to_lua(slots)), None)
    sim.advance(1)
    for idx, item in enumerate(LOOT_ITEMS):
        for c in sim.group_clients():
            c.Game.StartRoll(101 + idx, item, 60000, 1)
    sim.advance(2)
    winners = [n for n in ("Spencer", "Bazza", "Shazza") if n in sim.by_name] or [host.name]
    for idx, item in enumerate(LOOT_ITEMS):
        roll_fmt = u8(host.G.RANDOM_ROLL_RESULT) or "%s rolls %d (%d-%d)"
        for j, n in enumerate(raid):
            roll = (37 * (idx + 3) + 53 * (j + 1)) % 100 + 1
            sim.chat_to(sim.group_clients(), "CHAT_MSG_SYSTEM", roll_fmt % (n, roll, 1, 100), "")
        sim.advance(1)
    for idx, item in enumerate(LOOT_ITEMS):
        winner = winners[idx % len(winners)]
        wc = sim.by_name[winner]
        link = u8(wc.MOCK.ItemLink(item))
        for c in sim.group_clients():
            c.Game.EndRoll(101 + idx)
            if c.name == winner:
                c.Game.AddItem(item, 1)
                c.Game.DeliverChat("CHAT_MSG_LOOT", "You receive loot: %s." % link, winner)
            else:
                c.Game.DeliverChat("CHAT_MSG_LOOT", "%s receives loot: %s." % (winner, link), winner)
            cls = sim.world[winner]["class"]
            c.fire("ENCOUNTER_LOOT_RECEIVED", 3001, item, link, 1, winner, cls)
        sim.advance(1)
    for i in range(4, 6):
        host.lua("LootSlot(...)", i)
    sim.advance(1)
    host.Game.CloseLoot()
    sim.advance(5)
    # whispers to the host
    host.Game.DeliverChat("CHAT_MSG_WHISPER", "!sr 12345", "Kylie")
    host.Game.DeliverChat("CHAT_MSG_WHISPER", "!sr [Bark of Bandalar]", "Randy-Yojamba")
    host.Game.DeliverChat("CHAT_MSG_WHISPER", "!sr", "Davo")
    sim.advance(3)
    # leave the instance; camp + hearth back in the world
    for c in sim.group_clients():
        c.Game.LeaveInstance("Mount Hyjal")
    sim.advance(3)
    camp_caster = bz or host
    camp_caster.Game.Cast(1307227, camp_caster.rt.execute("return " + to_lua({"cooldown": 300, "itemCooldown": 300, "item": 279981})))
    sim.advance(2)
    for c in sim.online_clients():
        for n in raid[:5]:
            c.Game.SetAuras(n, c.rt.execute("return " + to_lua([{"spellId": 1289723, "duration": 60, "remaining": 60}])))
    sim.advance(5)
    for c in sim.online_clients():
        for n in raid[:5]:
            c.Game.SetAuras(n, c.rt.execute("return " + to_lua([{"spellId": 1229741, "duration": 3600, "remaining": 3600},
                                                                 {"spellId": 1230172, "duration": 3600, "remaining": 3600, "hidden": True}])))
    sim.advance(3)
    host.Game.Cast(8690, host.rt.execute("return " + to_lua({"cooldown": 1800, "itemCooldown": 1800, "item": 6948})))
    sim.advance(2)
    # trade skill window on Bazza
    if bz:
        bz.Game.OpenTradeSkill(bz.rt.execute("return " + to_lua(BAZZA_TAILORING)))
        sim.advance(2)
        bz.fire("TRADE_SKILL_LIST_UPDATE")
        sim.advance(1)
        bz.Game.LearnRecipe(18453)
        sim.advance(1)
        bz.Game.CloseTradeSkill()
        sim.advance(1)
    # money, level, merchant, quest
    for c in sim.online_clients():
        c.Game.SetMoney(c.d["money"] + 352718 // max(1, len(clients)))
    sim.advance(1)
    if sh:
        sh.Game.SetLevel(60)
    sim.advance(1)
    host.Game.OpenMerchant(host.rt.execute("return " + to_lua({"canRepair": True, "repairCost": 45120})))
    sim.advance(1)
    host.Game.SetMoney(host.d["money"] - 45120)
    host.Game.RemoveItem(14047, 3)
    sim.advance(1)
    host.Game.CloseMerchant()
    sim.advance(1)
    (bz or host).fire("QUEST_TURNED_IN", 96101, 4200, 1500)
    (bz or host).Game.SetMoney((bz or host).d["money"] + 9999)
    sim.advance(1)
    # let everything replicate (the lazy datasets flush every 60 s / 300 s: stats is lazy = 300)
    sim.advance(360)
    mism, summary = compare_datasets(sim)
    sc["datasets"] = summary
    sc["mismatches"] = mism
    if mism:
        sc["status"] = "mismatch"
        sc["notes"].append("%d dataset docs differ between clients after the raid" % len(mism))
    sc["chatSent"] = [x for x in sim.chat_routed]
    sim.clear_group()
    sim.advance(2)


def scenario_raid(sim, res):
    t0 = time.time()
    raid_sequence(sim, res, "raid")
    res.scenario("raid")["time"] = round(time.time() - t0, 1)


def scenario_secrets(res, n_clients):
    sim = Sim(n_clients, "secrets")
    t0 = time.time()
    sim.boot()
    for c in sim.clients:
        for cat in ("names", "guids", "roster", "rosterfields", "auras", "chat", "encounter", "spell"):
            c.Game.SetSecret(cat, True)
    raid_sequence(sim, res, "secrets")
    scenario_pages(sim, res, None, sizes=False, name="secrets-ui", clients=sim.clients[:1], combat=True, arg_key="Shazza")
    sc = res.scenario("secrets")
    sc["time"] = round(time.time() - t0, 1)
    sc["categories"] = ["names", "guids", "roster", "rosterfields", "auras", "chat", "encounter", "spell"]
    return sim


def scenario_gate(res, render_dir):
    """The guild lock (Core/Gate.lua): who it shuts out, and that it never shuts out a guildie. Only a
    failed check fails the run, so everything here is written as what should be true."""
    sc = res.scenario("gate")
    t0 = time.time()
    sim = Sim(7, "gate")
    spencer, bazza, shazza, kev, trish, mick, wayne = sim.clients[:7]     # the last two log in late
    for c in sim.clients:
        c.set_scenario("gate")
    if render_dir:
        scene_dir = os.path.join(render_dir, "scenes")
        os.makedirs(scene_dir, exist_ok=True)

    def check(name, ok, got=None):
        sc["checks"].append({"name": name, "ok": bool(ok), "got": got})
        if not ok:
            sc["status"] = "fail"
            sc["notes"].append(name)
            res.harness_failures.append("gate: %s (got %r)" % (name, got))

    def why(c):
        return c.eval_json("Greenfields.Gate:Why()")

    def shown(c, name):
        return c.eval_json("(rawget(_G, '%s') and %s:IsShown()) and true or false" % (name, name))

    def main_up(c):
        return shown(c, MAIN_FRAME)

    def gate_up(c):
        return shown(c, "GreenfieldsGate")

    def heading(c):
        return c.eval_json("rawget(_G, 'GreenfieldsGate') and GreenfieldsGate.heading:GetText()")

    def stats(c):
        return c.eval_json("{ sent = Greenfields.Comm.stats.sent, recv = Greenfields.Comm.stats.recv, queued = Greenfields.Comm:QueueSize() }")

    def prints(c, text):
        return sum(1 for l in c.jsonv(c.MOCK.printLog) if text in str(l))

    def toast_up(c):
        scene = json.loads(u8(c.json_of(c.MOCK, c.MOCK.ExportScene(None))))
        return any(f.get("type") == "Button" and "UI/Toast.lua" in (f.get("where") or "") for f in scene.get("frames", []))

    def slash(c, msg):
        c.lua("SlashCmdList.GREENFIELDS(...)", msg)
        sim.advance(0.2)

    def render(c, label):
        if not render_dir:
            return
        sp = os.path.join(scene_dir, "gate-%s.json" % label)
        scene = export_scene(c, sp)
        queue_render(res, c, scene, sp, os.path.join(render_dir, "gate-%s.png" % label), crop_frame="GreenfieldsGate")

    # --- logging in -------------------------------------------------------------------
    bazza.Game.SetGuild("Greenfields", True)     # a guildie whose guild name is slow to turn up
    shazza.Game.SetGuild(None)                   # a guildie the client says has no guild, at first
    kev.Game.SetGuild("Gooner Gang", True)       # in someone else's guild, name not through yet
    trish.Game.SetGuild(None)                    # in no guild at all
    for c in sim.clients[:5]:
        sim.login(c)
    sim.advance(0.5)
    check("guildie is open at login", why(spencer) is None, why(spencer))
    check("slow guild name doesn't shut anything", why(bazza) is None, why(bazza))
    check("no guild starts out as checking", why(trish) == "checking", why(trish))
    check("another guild reads as open until its name is known", why(kev) is None, why(kev))
    sim.advance(2)
    kev.Game.SetGuild("Gooner Gang")
    kev.fire("PLAYER_GUILD_UPDATE", "player")
    check("another guild shuts as soon as its name is known", why(kev) == "other", why(kev))
    check("the gate knows who they're with", kev.eval_json("Greenfields.Gate:Guild()") == "Gooner Gang")

    kev.lua("Greenfields.UI:ToggleMain()")
    check("other guild: toggling gets the gate, not the window", gate_up(kev) and not main_up(kev))
    render(kev, "other")
    kev.lua("Greenfields.UI:ToggleMain()")
    check("other guild: toggling closes the gate again", not gate_up(kev))

    trish.lua("Greenfields.UI:ToggleMain()")
    check("checking: the window says so", gate_up(trish) and heading(trish) == "Hang on a sec", heading(trish))
    render(trish, "checking")
    slash(trish, "update")
    check("a how-to box can open while checking", shown(trish, "GreenfieldsModal"))

    sim.advance(10)
    shazza.Game.SetGuild("Greenfields")
    shazza.fire("PLAYER_GUILD_UPDATE", "player")
    check("late guild turns up: open again", why(shazza) is None, why(shazza))
    check("a guildie who was only checking never hears residents only", prints(shazza, "Residents only") == 0)
    check("nor gets the welcome", not toast_up(shazza))

    sim.advance(15)
    check("no guild is still only checking at 27 s", why(trish) == "checking", why(trish))
    sim.advance(9)
    check("no guild shuts after the grace", why(trish) == "noguild", why(trish))
    check("the open gate changes its words by itself", heading(trish) == "Residents only", heading(trish))
    check("checking turning into shut leaves that box alone", shown(trish, "GreenfieldsModal"))
    trish.lua("Greenfields.UI:CloseModal()")
    check("it's not in chat yet, in case it fixes itself", prints(trish, "Residents only") == 0)
    sim.advance(6)
    check("then it's said once in chat", prints(trish, "Residents only") == 1)
    sim.advance(30)
    check("and only once", prints(trish, "Residents only") == 1)
    render(trish, "noguild")
    check("slow guild name still hasn't shut anything", why(bazza) is None, why(bazza))
    bazza.Game.SetGuild("Greenfields")
    bazza.fire("PLAYER_GUILD_UPDATE", "player")
    check("slow guild name arrives: open", why(bazza) is None, why(bazza))

    # --- what shut means --------------------------------------------------------------
    sim.advance(90)
    for c, label in ((kev, "other guild"), (trish, "no guild")):
        st = stats(c)
        check(label + ": nothing sent, nothing heard, nothing queued", st["sent"] == 0 and st["recv"] == 0 and st["queued"] == 0, st)
        check(label + ": sends are refused", c.eval_json("Greenfields.Comm:Guild('HI', {})") is False)
        got = c.eval_json("(function() local ok, w = Greenfields.API.SendChat('oi', 'SAY') return { ok = ok, why = w } end)()")
        check(label + ": chat is refused", got.get("ok") is False and got.get("why") == "gate", got)
    st = stats(spencer)
    check("guildies talk among themselves meanwhile", st["sent"] > 0 and st["recv"] > 0, st)
    check("guildies never hear of them", spencer.eval_json("Greenfields.Comm:HasAddon('Trish') == nil and Greenfields.Comm:HasAddon('Kev') == nil") is True)

    for msg in ("raids", "", "toast", "nonsense"):
        trish.lua("GreenfieldsGate:Hide()")
        slash(trish, msg)
        check("/gf %s gets the gate" % msg, gate_up(trish) and not main_up(trish))
    trish.lua("GreenfieldsGate:Hide()")
    trish.lua("Greenfields.UI:ShowPage('raids')")
    check("ShowPage gets the gate", gate_up(trish) and not main_up(trish))
    trish.lua("GreenfieldsGate:Hide()")
    trish.lua("Greenfields.UI:OpenMain('settings')")
    check("OpenMain gets the gate", gate_up(trish) and not main_up(trish))
    trish.lua("GreenfieldsGate:Hide()")
    n = len(trish.jsonv(trish.MOCK.printLog))
    slash(trish, "version")
    check("/gf version still answers", len(trish.jsonv(trish.MOCK.printLog)) > n and not gate_up(trish))
    slash(trish, "doctor")
    check("/gf doctor still answers", prints(trish, "Guild lock: Shut") == 1 and not gate_up(trish))
    n = prints(trish, "not in a guild")
    slash(trish, "gate")
    check("/gf gate says why", prints(trish, "not in a guild") == n + 1 and not gate_up(trish))
    for msg in ("update", "changelog"):
        slash(trish, msg)
        check("/gf %s opens its box, not the gate" % msg, shown(trish, "GreenfieldsModal") and not gate_up(trish) and not main_up(trish))
        if msg == "update":
            check("/gf update owns up that it can't hear about new versions",
                  trish.eval_json("Greenfields.UI ~= nil") is True and "Updating" in str(trish.eval_json("GreenfieldsModal.dialog and GreenfieldsModal.dialog.title:GetText()")))
        trish.lua("Greenfields.UI:CloseModal()")
    slash(trish, "report")
    check("/gf report opens its box, not the gate", shown(trish, "GreenfieldsModal") and not gate_up(trish) and not main_up(trish))
    check("/gf report says why", "not in a guild" in str(trish.eval_json("GreenfieldsModal.dialog.edit:GetText()")))
    trish.lua("Greenfields.UI:CloseModal()")
    slash(trish, "mic")
    check("/gf mic gets the gate", gate_up(trish) and not main_up(trish))
    trish.lua("GreenfieldsGate:Hide()")
    for msg in ("errors", "debug", "debug", "comm"):
        n = len(trish.jsonv(trish.MOCK.printLog))
        slash(trish, msg)
        check("/gf %s still answers" % msg, len(trish.jsonv(trish.MOCK.printLog)) > n and not gate_up(trish))

    trish.lua("Greenfields.UI:Toast({ title = 'oi', text = 'oi', force = true })")
    sim.advance(0.5)
    check("no signs", not toast_up(trish))
    trish.lua("Greenfields.gateTipRan = false; Greenfields.API.TooltipPostCall('Item', function() Greenfields.gateTipRan = true end)")
    trish.lua("GameTooltip:SetOwner(UIParent, 'ANCHOR_NONE'); GameTooltip:SetItemByID(6948)")
    check("no tooltip lines", trish.eval_json("Greenfields.gateTipRan") is False)
    spencer.lua("Greenfields.gateTipRan = false; Greenfields.API.TooltipPostCall('Item', function() Greenfields.gateTipRan = true end)")
    spencer.lua("GameTooltip:SetOwner(UIParent, 'ANCHOR_NONE'); GameTooltip:SetItemByID(6948)")
    check("guildies still get them", spencer.eval_json("Greenfields.gateTipRan") is True)
    btn = "GreenfieldsMinimapButton"
    trish.MOCK.UserClick(trish.G[btn], "RightButton")
    check("minimap right-click gets the gate, not the menu", gate_up(trish))
    trish.MOCK.UserClick(trish.G[btn], "LeftButton")
    check("minimap left-click closes it", not gate_up(trish))

    # --- joining while the game's running ---------------------------------------------
    trish.lua("Greenfields.UI:ShowGate()")
    trish.Game.SetGuild("Greenfields")
    trish.fire("PLAYER_GUILD_UPDATE", "player")
    trish.fire("GUILD_ROSTER_UPDATE", False)
    check("join: open straight away", why(trish) is None, why(trish))
    check("join: the gate turns into the window", main_up(trish) and not gate_up(trish))
    sim.advance(0.5)
    check("join: a welcome sign", toast_up(trish))
    check("join: and a chat line", prints(trish, "You're on the street") == 1)
    trish.lua("Greenfields.UI:HideMain()")
    sim.advance(170)
    check("join: on the guild's partition", trish.eval_json("Greenfields.gdbKey") == "Greenfields|Alliance", trish.eval_json("Greenfields.gdbKey"))
    check("join: guildies hear hello", spencer.eval_json("Greenfields.Comm:HasAddon('Trish') ~= nil") is True)
    check("join: caught up on the street's data", trish.eval_json("Greenfields.Store:Count('profile')") >= 4, trish.eval_json("Greenfields.Store:Count('profile')"))
    check("join: guildies get theirs", spencer.eval_json("Greenfields.Store:Get('profile', 'Trish') ~= nil") is True)
    kev.Game.SetGuild("Greenfields")
    kev.fire("PLAYER_GUILD_UPDATE", "player")
    check("swapping to our guild opens too", why(kev) is None, why(kev))
    sim.advance(170)

    # --- leaving -----------------------------------------------------------------------
    bazza.lua("Greenfields.UI:OpenMain('raids')")
    bazza.Game.SetGuild(None)
    bazza.fire("PLAYER_GUILD_UPDATE", "player")
    sim.advance(10)
    check("kicked: a blip doesn't slam the window shut", main_up(bazza) and why(bazza) is None, why(bazza))
    sim.advance(26)
    check("kicked: shut after the grace", why(bazza) == "noguild", why(bazza))
    check("kicked: the gate takes the window's place", gate_up(bazza) and not main_up(bazza))
    st1 = stats(bazza)
    sim.advance(60)
    st2 = stats(bazza)
    check("kicked: gone quiet", st2["sent"] == st1["sent"] and st2["recv"] == st1["recv"] and st2["queued"] == 0, [st1, st2])
    check("kicked: their saved data's still there", bazza.eval_json("GreenfieldsDB.guilds['Greenfields|Alliance'] ~= nil") is True)
    bazza.Game.SetGuild("Greenfields")
    bazza.fire("PLAYER_GUILD_UPDATE", "player")
    check("reinvited: back in", why(bazza) is None and main_up(bazza) and not gate_up(bazza))
    got = bazza.eval_json("(function() local ok, w = Greenfields.Attendance:Start(true) return tostring(w) end)()")
    check("reinvited: roll call isn't stuck loading", got != "loading", got)
    bazza.lua("Greenfields.UI:HideMain()")
    sim.advance(5)
    # a member who drops for a blip and comes back inside the grace never notices
    spencer.lua("Greenfields.UI:OpenMain('home')")
    spencer.Game.SetGuild(None)
    spencer.fire("PLAYER_GUILD_UPDATE", "player")
    sim.advance(6)
    spencer.Game.SetGuild("Greenfields")
    spencer.fire("PLAYER_GUILD_UPDATE", "player")
    sim.advance(40)
    check("guildie blip: never shut", why(spencer) is None and main_up(spencer) and prints(spencer, "Residents only") == 0)
    spencer.lua("Greenfields.UI:HideMain()")

    # --- false alarms ------------------------------------------------------------------
    # the client gives a wrong guild for a moment, then the right one: nobody ever hears about it
    n = prints(spencer, "Residents only")
    spencer.Game.SetGuild("Someone Else")
    spencer.lua("Greenfields.Gate:Check()")
    check("false alarm: shuts on the evidence", why(spencer) == "other", why(spencer))
    sim.advance(2)
    spencer.Game.SetGuild("Greenfields")
    spencer.lua("Greenfields.Gate:Check()")
    sim.advance(0.5)
    check("false alarm: open again, no chat", why(spencer) is None and prints(spencer, "Residents only") == n and prints(spencer, "You're on the street") == 0)
    check("false alarm: no welcome sign", not toast_up(spencer))
    # time spent on a loading screen doesn't count against the grace
    kev.Game.SetGuild(None)
    kev.fire("PLAYER_GUILD_UPDATE", "player")
    sim.advance(25)
    check("zoning: not shut at 25 s", why(kev) is None, why(kev))
    kev.fire("PLAYER_ENTERING_WORLD", False, False)
    sim.advance(25)
    check("zoning: the clock started again", why(kev) is None, why(kev))
    sim.advance(15)
    check("zoning: still shuts once it's had its grace", why(kev) == "noguild", why(kev))
    # invited, but the guild's name won't come through: it has to open eventually
    kev.lua("GreenfieldsGate:Hide()")
    kev.Game.SetGuild("Greenfields", True)
    kev.fire("PLAYER_GUILD_UPDATE", "player")
    sim.advance(10)
    check("invited, name not through: stays shut for now", why(kev) == "noguild", why(kev))
    sim.advance(25)
    check("invited, name never through: opens", why(kev) is None, why(kev))
    kev.Game.SetGuild("Greenfields")
    kev.fire("PLAYER_GUILD_UPDATE", "player")
    check("name turns up: still open", why(kev) is None, why(kev))
    sim.advance(5)

    # --- which names count ------------------------------------------------------------
    for name, ok in (("Greenfields", True), ("GREENFIELDS", True), ("greenfields", True), ("The Greenfields", True),
                     ("Green Fields WA", True), ("Greenfields Mandurah", True), ("Greenfield", True), ("Green Field WA", True),
                     ("Evergreen", False), ("Green Acres", False), ("Fields Of Green", False)):
        trish.Game.SetGuild(name)
        trish.lua("Greenfields.Gate:Check()")
        check("guild named %r %s" % (name, "opens" if ok else "stays shut"), (why(trish) is None) == ok, why(trish))
    trish.Game.SetGuild("Greenfields")
    trish.lua("Greenfields.Gate:Check()")

    # --- before launch, everyone's in ------------------------------------------------
    trish.Game.SetGuild("Gooner Gang")
    trish.lua("Greenfields.Gate:Check()")
    check("other guild is shut after launch", why(trish) == "other")
    trish.MOCK.SetClock(1793833200 - 1, sim.uptime)
    trish.lua("Greenfields.Gate:Check()")
    check("anyone's open the second before launch", why(trish) is None, why(trish))
    check("and it says so", "until Forever goes live" in str(trish.eval_json("Greenfields.Gate:Status()")))
    trish.MOCK.SetClock(1793833200, sim.uptime)
    trish.lua("Greenfields.Gate:Check()")
    check("the second it's live the lock's on", why(trish) == "other", why(trish))
    sim.advance(6)

    # --- a guild name we can't read --------------------------------------------------
    trish.Game.SetGuild("Greenfields")
    trish.lua("Greenfields.Gate:Check()")
    trish.Game.SetSecret("guildname", True)
    sim.advance(10)
    check("guildie with a secret guild name stays open", why(trish) is None, why(trish))
    trish.Game.SetGuild("Gooner Gang")
    sim.advance(40)
    check("a name we can't read never shuts it", why(trish) is None, why(trish))
    trish.Game.SetGuild(None)
    sim.advance(40)
    check("a no-guild we can't read never shuts it", why(trish) is None, why(trish))
    trish.Game.SetGuild("Gooner Gang")
    trish.Game.SetSecret("guildname", False)
    sim.advance(6)
    check("readable again: it's a straight answer", why(trish) == "other", why(trish))
    trish.Game.SetGuild("Greenfields")
    sim.advance(6)
    trish.Game.SetGuild("")
    trish.fire("PLAYER_GUILD_UPDATE", "player")
    sim.advance(6)
    check("a blank guild name isn't another guild", why(trish) is None, why(trish))
    check("nor does it make a guild called nothing", trish.eval_json("GreenfieldsDB.guilds['|Alliance'] == nil") is True)
    trish.Game.SetGuild("Greenfields")
    trish.fire("GUILD_ROSTER_UPDATE", False)
    sim.advance(6)
    check("the real name brings the guild's data back", trish.eval_json("Greenfields.gdbKey") == "Greenfields|Alliance", trish.eval_json("Greenfields.gdbKey"))

    # --- the test switch --------------------------------------------------------------
    spencer.lua("Greenfields.UI:OpenMain('home')")
    n = prints(spencer, "You're on the street")
    slash(spencer, "gate test")
    check("test: shuts it for a guildie", why(spencer) == "noguild" and spencer.eval_json("Greenfields.gateShut") is True)
    check("test: shows the gate", gate_up(spencer) and not main_up(spencer))
    check("test: says how to get out", "gate test" in str(spencer.eval_json("GreenfieldsGate.note:GetText()")))
    sim.advance(10)
    check("test: holds", why(spencer) == "noguild")
    slash(spencer, "gate test")
    check("test over: open", why(spencer) is None and main_up(spencer) and not gate_up(spencer))
    sim.advance(0.5)
    check("test over: no welcome", not toast_up(spencer) and prints(spencer, "You're on the street") == n)
    spencer.lua("Greenfields.UI:HideMain()")

    # --- guild data only goes to the guild -------------------------------------------
    spencer.lua("Greenfields.gateSent = {}; local C = Greenfields.Comm; local w = C.Whisper; Greenfields.gateRealWhisper = w; "
                "C.Whisper = function(self, target, op, ...) table.insert(Greenfields.gateSent, target .. ':' .. op) return w(self, target, op, ...) end")

    def asks(op, sender, payload, in_group=False):
        spencer.lua("Greenfields.gateSent = {}; local R = Greenfields.Roster; local ig = R.InGroup; "
                    "if %s then R.InGroup = function() return true end end; "
                    "Greenfields.Comm.handlers.%s.fn(%s, %r, 'WHISPER'); R.InGroup = ig" % (("true" if in_group else "false"), op, payload, sender))
        return spencer.eval_json("Greenfields.gateSent")

    code = spencer.eval_json("Greenfields.Store.defs.profile.code")
    sq = "{ c = { '%s' } }" % code
    sg = "{ c = '%s', i = { 'Spencer' } }" % code
    sx = "{ c = '%s', x = {} }" % code
    for op, payload in (("SQ", sq), ("SG", sg), ("SX", sx)):
        check("%s from a stranger: nothing back" % op, not asks(op, "Randy", payload))
        check("%s from a stranger in my party: nothing back" % op, not asks(op, "Randy", payload, True))
        check("%s from a guildie: answered" % op, len(asks(op, "Shazza", payload)) > 0)
    spencer.lua("Greenfields.Comm.Whisper = Greenfields.gateRealWhisper")
    check("refusals show in the doctor's list", spencer.eval_json("(Greenfields.Store.rejected.Randy or 0) >= 6") is True)

    # --- only guildies get listened to ------------------------------------------------
    # someone with an edited copy, in a party with Spencer, forging a config doc "by" the GM
    def forged(c, sender, channel, officer_rank=9):
        c.lua("local S = Greenfields.Serialize; local G = Greenfields; "
              "local text = '1r' .. S.Encode({ 'SU', { c = G.Store.defs.config.code, l = { { 'guild', 99999999999, 'Spencer', GetServerTime(), "
              "{ officerRank = %d } } } }, 1 }); Greenfields.gateText = text" % officer_rank)
        text = c.eval_json("Greenfields.gateText")
        c.Game.DeliverAddon("GRNFLDS", text, channel, sender, "", False)
        sim.advance(0.1)

    def rank(c):
        return c.eval_json("Greenfields.Roster:Config().officerRank")

    def ignored(c, who):
        return c.eval_json("Greenfields.Comm.ignored.%s or 0" % who)

    before = rank(shazza)
    forged(shazza, "Randy-Yojamba", "PARTY")
    check("stranger in a party can't forge guild data", rank(shazza) == before, rank(shazza))
    check("and it's counted for the doctor", ignored(shazza, "Randy") == 1, ignored(shazza, "Randy"))
    forged(shazza, "Randy-Yojamba", "WHISPER")
    check("nor by whisper", rank(shazza) == before and ignored(shazza, "Randy") == 2, rank(shazza))
    hello = ("local S = Greenfields.Serialize; Greenfields.gateText = '1r' .. S.Encode({ 'HI', { v = '9.9.9', p = 1 }, 1 })")
    shazza.lua(hello)
    shazza.Game.DeliverAddon("GRNFLDS", shazza.eval_json("Greenfields.gateText"), "WHISPER", "Randy-Yojamba", "", False)
    sim.advance(5)
    check("nor fake an update nag", shazza.eval_json("Greenfields.Update:Newest() == nil") is True)
    n = shazza.eval_json("Greenfields.Comm.stats.recv")
    shazza.Game.DeliverAddon("GRNFLDS", shazza.eval_json("Greenfields.gateText"), "RAID", "Bazza-" + REALM, "", False)
    sim.advance(0.1)
    check("guildies are heard on the raid channel", shazza.eval_json("Greenfields.Comm.stats.recv") == n + 1)
    shazza.Game.DeliverAddon("GRNFLDS", shazza.eval_json("Greenfields.gateText"), "RAID", "Shazza-" + REALM, "", False)
    sim.advance(0.1)
    check("and so is your own echo", ignored(shazza, "Shazza") == 0)
    # Bazza's row drops out of the roster mid-raid, the way hidden fields would drop it
    shazza.lua("local R = Greenfields.Roster; local get = R.IsMember; R.IsMember = function() return false end; Greenfields.gateIsMember = get")
    n = shazza.eval_json("Greenfields.Comm.stats.recv")
    shazza.Game.DeliverAddon("GRNFLDS", shazza.eval_json("Greenfields.gateText"), "RAID", "Bazza-" + REALM, "", False)
    sim.advance(0.1)
    check("a guildie whose roster row went missing is still heard", shazza.eval_json("Greenfields.Comm.stats.recv") == n + 1)
    shazza.lua("Greenfields.Roster.IsMember = Greenfields.gateIsMember")
    # before the whole roster's been read, or before launch, the rule doesn't apply
    shazza.lua("local R = Greenfields.Roster; local c = R.ReadAll; R.ReadAll = function() return false end; Greenfields.gateReadAll = c")
    n = ignored(shazza, "Randy")
    shazza.Game.DeliverAddon("GRNFLDS", shazza.eval_json("Greenfields.gateText"), "RAID", "Randy-Yojamba", "", False)
    sim.advance(0.1)
    check("roster not read yet: nobody's turned away", ignored(shazza, "Randy") == n)
    shazza.lua("Greenfields.Roster.ReadAll = Greenfields.gateReadAll")
    n = ignored(shazza, "Randy")
    shazza.MOCK.SetClock(1793833200 - 1, sim.uptime)
    shazza.Game.DeliverAddon("GRNFLDS", shazza.eval_json("Greenfields.gateText"), "RAID", "Randy-Yojamba", "", False)
    check("the second before launch: nobody's turned away", ignored(shazza, "Randy") == n)
    shazza.MOCK.SetClock(1793833200, sim.uptime)
    shazza.Game.DeliverAddon("GRNFLDS", shazza.eval_json("Greenfields.gateText"), "RAID", "Randy-Yojamba", "", False)
    check("the second it's live: they are", ignored(shazza, "Randy") == n + 1)
    sim.advance(1)

    # a first scan that can't read every row: nobody can be ruled out yet
    mick.Game.HideRosterRow("Spencer", True)
    mick.MOCK.SetClock(int(sim.epoch), sim.uptime)
    sim.login(mick)
    sim.advance(5)
    check("partial roster: read some, not all", mick.eval_json("Greenfields.Roster:Count() > 0 and not Greenfields.Roster:ReadAll()") is True)
    mick.lua(hello)
    text = mick.eval_json("Greenfields.gateText")
    n = mick.eval_json("Greenfields.Comm.stats.recv")
    mick.Game.DeliverAddon("GRNFLDS", text, "RAID", "Spencer-" + REALM, "", False)
    check("partial roster: the guildie whose row's hidden is heard", mick.eval_json("Greenfields.Comm.stats.recv") == n + 1 and ignored(mick, "Spencer") == 0)
    mick.Game.DeliverAddon("GRNFLDS", text, "RAID", "Randy-Yojamba", "", False)
    check("partial roster: nobody's ruled out yet", ignored(mick, "Randy") == 0)
    mick.Game.HideRosterRow("Spencer", False)
    mick.fire("GUILD_ROSTER_UPDATE", False)
    sim.advance(1)
    mick.Game.DeliverAddon("GRNFLDS", text, "RAID", "Randy-Yojamba", "", False)
    check("full roster: now strangers are turned away", mick.eval_json("Greenfields.Roster:ReadAll()") is True and ignored(mick, "Randy") == 1)
    mick.Game.HideRosterRow("Spencer", True)
    mick.fire("GUILD_ROSTER_UPDATE", False)
    sim.advance(1)
    n = mick.eval_json("Greenfields.Comm.stats.recv")
    mick.Game.DeliverAddon("GRNFLDS", text, "RAID", "Spencer-" + REALM, "", False)
    check("a row hidden after a full read is still heard", mick.eval_json("Greenfields.Comm.stats.recv") == n + 1)
    check("and the doctor can count it", mick.eval_json("Greenfields.Roster:HiddenRows()") == 1)
    mick.Game.HideRosterRow("Spencer", False)

    # asked for data before the roster was in: the answers were refused, so it has to ask again
    wayne.Game.SetSecret("roster", True)
    wayne.MOCK.SetClock(int(sim.epoch), sim.uptime)
    sim.login(wayne)
    sim.advance(3)
    spencer.lua("Greenfields.Store:SyncNow()")
    sim.advance(60)
    check("blind: only what's been broadcast has come through", wayne.eval_json("Greenfields.Roster:Count() == 0 and Greenfields.Store:Count('profile') <= 3") is True,
          wayne.eval_json("Greenfields.Store:Count('profile')"))
    wayne.Game.SetSecret("roster", False)
    wayne.fire("GUILD_ROSTER_UPDATE", False)
    sim.advance(25)
    check("blind: catches up as soon as the roster's in", wayne.eval_json("Greenfields.Store:Count('profile')") >= 6, wayne.eval_json("Greenfields.Store:Count('profile')"))

    # --- leaving test mode, from outside the guild --------------------------------------
    trish.Game.SetGuild("Gooner Gang")
    trish.lua("Greenfields.Gate:Check()")
    trish.lua("Greenfields.gateFlips = 0; Greenfields:On('GF_GATE_CHANGED', function(shut) if not shut then Greenfields.gateFlips = Greenfields.gateFlips + 1 end end)")
    n = prints(trish, "Residents only")
    slash(trish, "gate test")
    slash(trish, "gate test")
    check("outsider ending a test: it never opens along the way", trish.eval_json("Greenfields.gateFlips") == 0, trish.eval_json("Greenfields.gateFlips"))
    check("outsider ending a test: still shut, real reason back", why(trish) == "other" and not main_up(trish) and gate_up(trish), why(trish))
    check("outsider ending a test: the test note's gone", "gate test" not in str(trish.eval_json("GreenfieldsGate.note:GetText()")))
    check("outsider ending a test: no second residents-only line", prints(trish, "Residents only") == n)
    trish.lua("GreenfieldsGate:Hide()")
    trish.Game.SetGuild(None)
    sim.advance(36)
    trish.lua("Greenfields.gateFlips = 0")
    slash(trish, "gate test")
    slash(trish, "gate test")
    check("no guild ending a test: same again", trish.eval_json("Greenfields.gateFlips") == 0 and why(trish) == "noguild" and gate_up(trish), why(trish))
    check("no guild ending a test: test note gone", "gate test" not in str(trish.eval_json("GreenfieldsGate.note:GetText()")))

    # invited while the test's on: leaving it is a normal welcome
    n = prints(trish, "You're on the street")
    sent = stats(trish)["sent"]
    slash(trish, "gate test")
    trish.Game.SetGuild("Greenfields")
    trish.fire("PLAYER_GUILD_UPDATE", "player")
    check("invite during a test: the test holds", why(trish) == "noguild", why(trish))
    slash(trish, "gate test")
    check("invite during a test: open once it's over", why(trish) is None and main_up(trish), why(trish))
    check("invite during a test: told they're in", prints(trish, "You're on the street") == n + 1)
    sim.advance(0.5)
    check("invite during a test: and the sign", toast_up(trish))
    sim.advance(25)
    check("invite during a test: hello and sync go out", stats(trish)["sent"] > sent)
    trish.lua("Greenfields.UI:HideMain()")

    # a guildie ending a test when the guild's name can't be read just then: nothing to report
    spencer.Game.SetGuild("Greenfields", True)
    n = prints(spencer, "Residents only")
    slash(spencer, "gate test")
    sim.advance(6)
    slash(spencer, "gate test")
    check("guildie ending a test, name unreadable: straight back open", why(spencer) is None, why(spencer))
    sim.advance(6)
    check("and no false residents-only line", prints(spencer, "Residents only") == n and prints(spencer, "You're on the street") == 0)
    spencer.Game.SetGuild("Greenfields")
    spencer.lua("Greenfields.Gate:Check(); Greenfields.UI:HideMain()")
    sc["time"] = round(time.time() - t0, 1)
    return sim


def scenario_whispers(res):
    """Whispers the way the real client does them: the full name gets there, a bare first name or someone
    who's gone gets the 'No player named' line, and catching up on sync really runs over them. On its own
    clients, because it bounces whispers on purpose, so it checks for its own Lua errors."""
    sc = res.scenario("whispers")
    t0 = time.time()
    sim = Sim(3, "whispers")
    spencer, bazza, shazza = sim.clients

    def check(name, ok, got=None):
        sc["checks"].append({"name": name, "ok": bool(ok), "got": got})
        if not ok:
            sc["status"] = "fail"
            sc["notes"].append(name)
            res.harness_failures.append("whispers: %s (got %r)" % (name, got))

    def heard(c, sender):
        return c.eval_json("(Greenfields.Comm.peers.%s or {}).version" % sender) == "7.7.7"

    def lines(c):
        return [str(l) for l in c.jsonv(c.G.Greenfields.sysLines)]

    def whisper(c, target):
        c.lua("Greenfields.API.SendAddon('GRNFLDS', Greenfields.helloText, 'WHISPER', %s)" % to_lua(target))
        sim.advance(0.2)

    # --- catching up: someone who logs in late pulls what they missed over whispers -----
    sim.login(spencer)
    sim.login(bazza)
    sim.advance(60)
    sim.login(shazza)
    sim.advance(120)
    for op in ("SQ", "SX", "SG"):
        check("catching up: %s arrives" % op, sim.whispered.get(op, 0) > 0, sim.whispered)
    check("catching up: the data got there", shazza.eval_json("Greenfields.Store:Get('profile', 'Spencer') ~= nil") is True)
    check("catching up: both ways", spencer.eval_json("Greenfields.Store:Get('profile', 'Shazza') ~= nil") is True)
    # every whisper the addon sends itself has to be one the real client would deliver
    check("nothing bounced in a normal sync", not sim.bounced, sim.bounced)
    check("a hello gets answered over a whisper", sim.whispered.get("HI", 0) > 0, sim.whispered)
    check("so someone new learns who has the addon without waiting on the half-hourly hello",
          shazza.eval_json("Greenfields.Comm.peers.Spencer.version ~= nil and Greenfields.Comm.peers.Bazza.version ~= nil") is True)

    # --- what the server does with a target ----------------------------------------------
    for c in sim.clients:
        c.lua("local G = Greenfields; G.sysLines = {}; G:RegisterEvent('CHAT_MSG_SYSTEM', function(_, m) table.insert(G.sysLines, m) end); "
              "G.helloText = '1r' .. G.Serialize.Encode({ 'HI', { v = '7.7.7', p = 1, r = 1 }, 1 })")
    sim.bare_on_purpose = True
    whisper(spencer, "Bazza")
    sim.bare_on_purpose = False
    sim.advance(0.2)
    check("a bare first name doesn't arrive", not heard(bazza, "Spencer"))
    check("a bare first name bounces", "No player named 'Bazza' is currently playing." in lines(spencer), lines(spencer))
    whisper(spencer, "Bazza Greenfield")
    sim.advance(0.2)
    check("the full name arrives", heard(bazza, "Spencer"))
    check("and doesn't bounce", len(lines(spencer)) == 1, lines(spencer))
    whisper(spencer, "Davo Greenfield")
    sim.advance(0.2)
    check("someone online without the addon doesn't bounce", len(lines(spencer)) == 1, lines(spencer))
    whisper(spencer, "Nobody Greenfield")
    sim.advance(0.2)
    check("someone who doesn't exist bounces", "No player named 'Nobody Greenfield' is currently playing." in lines(spencer), lines(spencer))
    shazza.online = False
    whisper(spencer, "Shazza Greenfield")
    sim.advance(0.2)
    shazza.online = True
    check("someone who's logged off bounces", "No player named 'Shazza Greenfield' is currently playing." in lines(spencer), lines(spencer))

    # the same for whispers typed out as chat
    bazza.lua("local G = Greenfields; G.tells = {}; G:RegisterEvent('CHAT_MSG_WHISPER', function(_, m) table.insert(G.tells, m) end)")
    sim.bare_on_purpose = True
    spencer.lua_hw("C_ChatInfo.SendChatMessage('oi', 'WHISPER', nil, 'Bazza')")
    sim.advance(0.2)
    sim.bare_on_purpose = False
    check("chat to a bare name doesn't arrive", bazza.eval_json("#Greenfields.tells") == 0)
    check("chat to a bare name bounces", lines(spencer).count("No player named 'Bazza' is currently playing.") == 2, lines(spencer))
    spencer.lua_hw("Greenfields.API.SendChat('oi', 'WHISPER', 'Bazza')")
    sim.advance(0.2)
    check("the addon's own chat whispers use the full name", bazza.eval_json("#Greenfields.tells") == 1)

    # --- the addon's side of it ---------------------------------------------------------
    n = len(sim.bounced)
    spencer.lua("Greenfields.Comm:Whisper('Bazza', 'HI', { v = Greenfields.VERSION, p = 1, r = 1 })")
    sim.advance(0.5)
    check("Comm:Whisper sends the full name", len(sim.bounced) == n, sim.bounced[n:])
    # the chat frame hides the bounce for a name we just whispered, and nothing else
    spencer.lua("Greenfields.Comm:NoteWhisper('Bazza Greenfield')")
    filt = spencer.MOCK.chatFilters.CHAT_MSG_SYSTEM[1]
    check("a bounce from our own whisper is hidden", filt(None, "CHAT_MSG_SYSTEM", "No player named 'Bazza Greenfield' is currently playing.") is True)
    check("anyone else's isn't", filt(None, "CHAT_MSG_SYSTEM", "No player named 'Gary' is currently playing.") is False
          and filt(None, "CHAT_MSG_SYSTEM", "Bazza has come online.") is False)
    spencer.lua("Greenfields.Comm:NoteWhisper('Kaghul Doomskull')")
    check("bounce filter: the line with the full name is hidden", filt(None, "CHAT_MSG_SYSTEM", "No player named 'Kaghul Doomskull' is currently playing.") is True)
    check("bounce filter: so is the line with just the first name", filt(None, "CHAT_MSG_SYSTEM", "No player named 'Kaghul' is currently playing.") is True)
    check("bounce filter: the surname on its own isn't ours", filt(None, "CHAT_MSG_SYSTEM", "No player named 'Doomskull' is currently playing.") is False)
    spencer.lua("Greenfields.Comm:NoteWhisper('Trish Harbour-Realm')")
    check("bounce filter: a realm on what we sent still hides the name without it",
          filt(None, "CHAT_MSG_SYSTEM", "No player named 'Trish Harbour' is currently playing.") is True
          and filt(None, "CHAT_MSG_SYSTEM", "No player named 'Trish' is currently playing.") is True)
    sim.advance(16)
    check("bounce filter: both forms wear off", filt(None, "CHAT_MSG_SYSTEM", "No player named 'Kaghul Doomskull' is currently playing.") is False
          and filt(None, "CHAT_MSG_SYSTEM", "No player named 'Kaghul' is currently playing.") is False)
    # someone the roster can't name in full yet: a bare name would only bounce, so it isn't sent
    n = len(sim.bounced)
    got = spencer.eval_json("Greenfields.Comm:Whisper('Stranger', 'HI', { v = Greenfields.VERSION, p = 1, r = 1 })")
    sim.advance(0.5)
    check("no full name known: nothing sent", got is False and len(sim.bounced) == n, [got, sim.bounced[n:]])

    # --- how many answer a hello -----------------------------------------------------------
    # a watch on Comm:Whisper that still really calls it
    bazza.lua("local C = Greenfields.Comm; C.ownWhisper = C.Whisper; C.tried = {}; "
              "C.Whisper = function(self, target, op, p, prio) "
              "local ok = C.ownWhisper(self, target, op, p, prio) "
              "table.insert(C.tried, { target = target, op = op, r = p and p.r, sent = ok and true or false }) return ok end")

    def hellos(users, n, payload="{ v = '1.0.0', p = 1 }", channel="GUILD"):
        bazza.lua("local G = Greenfields; G.Comm.tried = {}; G.Comm.ownUsers = G.Comm.OnlineUsers; "
                  "G.Comm.OnlineUsers = function() return %d end; "
                  "for i = 1, %d do G.Comm.handlers.HI.fn(%s, 'Spencer', '%s') end; "
                  "G.Comm.OnlineUsers = G.Comm.ownUsers" % (users, n, payload, channel))
        sim.advance(8)
        return bazza.eval_json("Greenfields.Comm.tried")

    tried = hellos(20, 50)
    check("20 addon users online: everyone answers every hello", len(tried) == 50 and all(t["op"] == "HI" and t["r"] == 1 for t in tried), len(tried))
    tried = hellos(3, 50)
    check("a small guild: everyone answers every hello", len(tried) == 50, len(tried))
    tried = hellos(40, 400)
    check("40 addon users online: about 3 in 39 answer", 12 <= len(tried) <= 55, len(tried))
    tried = hellos(21, 400)
    check("just over the line: about 3 in 20 answer", 30 <= len(tried) <= 95, len(tried))
    check("an answer doesn't get answered", not hellos(3, 5, "{ v = '1.0.0', p = 1, r = 1 }"))
    check("a whispered hello doesn't get answered", not hellos(3, 5, channel="WHISPER"))
    # launch morning: 40 online, only a few with the addon. It's the addon users that get counted
    bazza.lua("local R = Greenfields.Roster; R.ownOnline = R.OnlineCount; R.OnlineCount = function() return 40 end; "
              "R.ownAll = R.All; R.All = function() local t = {} for i = 1, 40 do t['Extra' .. i] = { online = true } end "
              "for i = 1, 10 do Greenfields.Comm.peers['Extra' .. i] = { version = '1.0.0' } end "
              "t.Gone = { online = false }; Greenfields.Comm.peers.Gone = { version = '1.0.0' } return t end")
    check("the count is online people with the addon, nobody else", bazza.eval_json("Greenfields.Comm:OnlineUsers()") == 10,
          bazza.eval_json("Greenfields.Comm:OnlineUsers()"))
    bazza.lua("local G = Greenfields; G.Comm.tried = {}; for i = 1, 50 do G.Comm.handlers.HI.fn({ v = '1.0.0', p = 1 }, 'Spencer', 'GUILD') end")
    sim.advance(8)
    tried = bazza.eval_json("Greenfields.Comm.tried")
    check("40 online, 10 with the addon: everyone answers every hello", len(tried) == 50, len(tried))
    bazza.lua("local R, C = Greenfields.Roster, Greenfields.Comm; R.OnlineCount = R.ownOnline; R.All = R.ownAll; R.ownOnline = nil; R.ownAll = nil; "
              "for i = 1, 10 do C.peers['Extra' .. i] = nil end; C.peers.Gone = nil")

    # a hello from someone who isn't on our roster yet: nothing to whisper, so it tries once more
    def roster_changed(c):
        c.fire("GUILD_ROSTER_UPDATE", False)
        sim.advance(1)

    bazza.Game.RemoveMember("Davo", None)
    roster_changed(bazza)
    bazza.lua("local G = Greenfields; G.Comm.tried = {}; G.Comm.handlers.HI.fn({ v = '1.0.0', p = 1 }, 'Davo', 'GUILD')")
    sim.advance(8)
    tried = bazza.eval_json("Greenfields.Comm.tried")
    check("a hello from someone not on the roster: can't answer yet", len(tried) == 1 and tried[0]["sent"] is False, tried)
    bazza.Game.AddMember("Davo", None, 2, True)
    roster_changed(bazza)
    sim.advance(21)
    tried = bazza.eval_json("Greenfields.Comm.tried")
    check("and answers once they're on it", len(tried) == 2 and tried[1]["sent"] is True, tried)
    sim.advance(30)
    check("and only tries the once", len(bazza.eval_json("Greenfields.Comm.tried")) == 2)
    bazza.lua("local G = Greenfields; G.Comm.tried = {}; G.Comm.handlers.HI.fn({ v = '1.0.0', p = 1 }, 'Stranger', 'GUILD')")
    sim.advance(90)
    tried = bazza.eval_json("Greenfields.Comm.tried")
    check("someone who never turns up gets two tries and nothing sent", len(tried) == 2 and not tried[0]["sent"] and not tried[1]["sent"], tried)
    bazza.lua("local C = Greenfields.Comm; C.Whisper = C.ownWhisper; C.ownWhisper = nil")

    # --- invites use the full name ---------------------------------------------------------------
    n = len(sim.invites)
    spencer.lua_hw("Greenfields.API.Invite('Bazza')")
    sim.advance(0.5)
    check("an invite goes to the full name", [i["target"] for i in sim.invites[n:]] == ["Bazza Greenfield"], sim.invites[n:])
    spencer.lua("Greenfields.gateShut = true")
    got = spencer.lua_hw("return Greenfields.API.Invite('Bazza') and true or false")
    spencer.lua("Greenfields.gateShut = nil")
    sim.advance(0.5)
    check("no invites with the gate shut", len(sim.invites) == n + 1, sim.invites[n:])

    for c in sim.clients:
        rep = collect_client_report(c)
        check("no Lua errors on " + c.name, not rep["errors"] and not rep["addonErrors"], rep["errors"] + rep["addonErrors"])

    # --- a roster that hasn't caught up ---------------------------------------------------------
    # Sim.login tells everyone straight away, and nothing says the real client does. The rows here stay
    # offline, so a hello or a digest is the only sign the newcomer's turned up.
    stale = Sim(3, "stale roster")
    first, second, late = stale.clients
    stale.login(first)
    stale.login(second)
    stale.advance(60)
    for c in (first, second):
        c.Game.SetMemberOnline(late.name, False)
        c.fire("GUILD_ROSTER_UPDATE", False)
    stale.advance(2)
    check("stale roster: nobody whispers someone offline they haven't heard from",
          first.eval_json("Greenfields.Comm:Whisper('Shazza', 'HI', { v = Greenfields.VERSION, p = 1, r = 1 })") is False)
    stale.login(late)
    for c in (first, second):
        c.Game.SetMemberOnline(late.name, False)
    stale.advance(25)
    check("stale roster: the rows really do say offline", first.eval_json("Greenfields.Roster:IsOnline('Shazza')") is False
          and second.eval_json("Greenfields.Roster:IsOnline('Shazza')") is False)
    check("stale roster: the hello still gets answered", stale.whispered.get("HI", 0) >= 2, stale.whispered)
    check("stale roster: the newcomer learns who has the addon",
          late.eval_json("Greenfields.Comm.peers.Spencer.version ~= nil and Greenfields.Comm.peers.Bazza.version ~= nil") is True)
    senders = late.eval_json("Greenfields.Comm.senders")
    check("stale roster: the doctor can see the whisper came in", "WHISPER" in (senders.get("Spencer-Arugal") or {}).get("channel", ""), senders)
    stale.advance(35)
    for op in ("SQ", "SX"):
        check("stale roster: catching up still runs: %s" % op, stale.whispered.get(op, 0) > 0, stale.whispered)
    second.lua("Greenfields.Comm.senders = {}")
    first.lua("Greenfields.Comm:Guild('HI', { v = Greenfields.VERSION, p = 1, r = 1 }, 'ALERT')")
    stale.advance(1)
    first.lua("Greenfields.Comm:Whisper('Bazza', 'HI', { v = Greenfields.VERSION, p = 1, r = 1 }, 'ALERT')")
    stale.advance(1)
    senders = second.eval_json("Greenfields.Comm.senders")
    check("stale roster: a whisper from someone heard on the guild channel shows too",
          (senders.get("Spencer-Arugal") or {}).get("channel") == "GUILD+WHISPER", senders)
    check("stale roster: the data got there", late.eval_json("Greenfields.Store:Get('profile', 'Spencer') ~= nil") is True)
    check("stale roster: nothing bounced", not stale.bounced, stale.bounced)
    first.lua("Greenfields.Comm.peers.Shazza.seen = Greenfields.API.ServerTime() - 61")
    check("stale roster: not heard from in a minute, the row wins again",
          first.eval_json("Greenfields.Comm:Whisper('Shazza', 'HI', { v = Greenfields.VERSION, p = 1, r = 1 })") is False)
    for c in stale.clients:
        rep = collect_client_report(c)
        check("stale roster: no Lua errors on " + c.name, not rep["errors"] and not rep["addonErrors"], rep["errors"] + rep["addonErrors"])

    # --- a guild-switcher: read another guild's roster, leave, join ours, no /reload ----------
    switch = Sim(2, "whispers-switcher")
    mover = switch.clients[1]
    mover.Game.SetGuild("Gooner Gang")
    mover.Game.AddMember("Oldmate", "Gooner", 3, False)
    switch.login(mover)
    switch.advance(10)
    mover.Game.HideRosterRow("Davo", True)
    mover.fire("GUILD_ROSTER_UPDATE", False)
    switch.advance(1)
    check("guild-switcher: the old guild's been read in full",
          mover.eval_json("Greenfields.Roster:ReadAll() and Greenfields.Roster:WasMember('Oldmate') and Greenfields.Roster:HiddenRows() == 1") is True)
    mover.Game.HideRosterRow("Davo", False)
    mover.lua("Greenfields.realIsInGuild = IsInGuild; IsInGuild = function() return MOCK.Secret(false) end")
    mover.fire("GUILD_ROSTER_UPDATE", False)
    switch.advance(2)
    check("guild-switcher: a no-guild we can't read keeps the roster", mover.eval_json("Greenfields.Roster:Count() > 0 and Greenfields.Roster:ReadAll()") is True)
    mover.lua("IsInGuild = Greenfields.realIsInGuild; Greenfields.realIsInGuild = nil")
    mover.Game.SetGuild(None)
    mover.fire("PLAYER_GUILD_UPDATE", "player")
    switch.advance(2)
    check("guild-switcher: leaving forgets the roster was read", mover.eval_json("Greenfields.Roster:ReadAll()") is False)
    check("guild-switcher: and who was on it", mover.eval_json("Greenfields.Roster:WasMember('Oldmate')") is False)
    check("guild-switcher: and the hidden row count", mover.eval_json("Greenfields.Roster:HiddenRows()") == 0)
    mover.Game.SetGuild("Greenfields")
    mover.Game.RemoveMember("Oldmate", "Gooner")
    mover.Game.AddMember("Newmate", "Greenfield", 3, True)
    mover.fire("PLAYER_GUILD_UPDATE", "player")     # the scan's still on its way
    check("guild-switcher: the gate's open and the roster isn't read yet",
          mover.eval_json("not Greenfields.gateShut and Greenfields.Roster:Count() == 0") is True)
    mover.lua("Greenfields.gateText = '1r' .. Greenfields.Serialize.Encode({ 'HI', { v = Greenfields.VERSION, p = 1, r = 1 }, 1 })")
    text = mover.eval_json("Greenfields.gateText")
    n = mover.eval_json("Greenfields.Comm.stats.recv")
    mover.Game.DeliverAddon("GRNFLDS", text, "WHISPER", "Newmate-" + REALM, "", False)
    check("guild-switcher: a whispered hello reply is heard before the first new scan",
          mover.eval_json("Greenfields.Comm.stats.recv") == n + 1 and mover.eval_json("Greenfields.Comm.ignored.Newmate or 0") == 0,
          mover.eval_json("Greenfields.Comm.ignored"))
    switch.advance(3)
    mover.Game.DeliverAddon("GRNFLDS", text, "WHISPER", "Randy-Yojamba", "", False)
    check("guild-switcher: once the new roster's read, strangers are turned away again",
          mover.eval_json("Greenfields.Roster:ReadAll()") is True and mover.eval_json("Greenfields.Comm.ignored.Randy or 0") == 1)
    rep = collect_client_report(mover)
    check("guild-switcher: no Lua errors", not rep["errors"] and not rep["addonErrors"], rep["errors"] + rep["addonErrors"])
    sc["time"] = round(time.time() - t0, 1)
    return sim


def scenario_clash(res):
    """Two guildies with one first name (Core/Roster.lua). Blizzard lets first names repeat and keys are
    first names, so the addon can't tell them apart: nobody on that name gets rights, a whisper or an
    invite, and everyone else carries on as normal. Only the GM's side can be a real client here: the
    sim's clients go by first name, so the namesake is a roster row, and their sends are Spencer's."""
    sc = res.scenario("clash")
    t0 = time.time()
    sim = Sim(3, "clash")
    spencer, bazza, shazza = sim.clients

    def check(name, ok, got=None):
        sc["checks"].append({"name": name, "ok": bool(ok), "got": got})
        if not ok:
            sc["status"] = "fail"
            sc["notes"].append(name)
            res.harness_failures.append("clash: %s (got %r)" % (name, got))

    def roster(*clients):
        for c in clients:
            if c.online:
                c.fire("GUILD_ROSTER_UPDATE", False)
        sim.advance(1)

    def add(name, surname, rank, online=True):
        for c in sim.clients:
            c.Game.AddMember(name, surname, rank, online)
        roster(*sim.clients)

    def remove(name, surname):
        for c in sim.clients:
            c.Game.RemoveMember(name, surname)
        roster(*sim.clients)

    def prints(c, text):
        return sum(1 for l in c.jsonv(c.MOCK.printLog) if text in str(l))

    def doctor_line(c):
        c.MOCK.HardwareCall("/gf doctor", c.G.SlashCmdList.GREENFIELDS, "doctor")
        sim.advance(0.2)
        return next(str(l) for l in c.eval_json("GreenfieldsDB.doctor.lines") if str(l).startswith("Repeated first names"))

    def motd(c):
        return c.eval_json("Greenfields.Roster:Config().motd")

    def is_gm(c, key="Spencer"):
        return c.eval_json("Greenfields.Roster:IsGM('%s')" % key)

    # the guild lock is live for all of this, so hears() and the gate are really being asked
    for c in sim.clients:
        c.lua("Greenfields.Gate.IsLive = function() return true end")
    sim.login(spencer)
    sim.login(bazza)
    sim.advance(60)
    count, online = bazza.eval_json("Greenfields.Roster:Count()"), bazza.eval_json("Greenfields.Roster:OnlineCount()")

    # --- nobody's sharing yet: the GM's edits go through ----------------------------------------
    check("no clash: the GM's the GM", is_gm(bazza) is True and is_gm(spencer) is True)
    check("no clash: nothing flagged", bazza.eval_json("Greenfields.Roster:Clash('Spencer')") is None)
    check("no clash: the doctor says none", "Repeated first names: none in" in doctor_line(bazza))
    check("no clash: nobody told", prints(spencer, "answer to") == 0)
    check("the GM's edit is allowed", spencer.eval_json("Greenfields.Store:Put('config', 'guild', { motd = 'before' })") is True)
    sim.advance(5)
    check("the GM's edit lands", motd(bazza) == "before", motd(bazza))

    # --- a recruit with the GM's first name, while Shazza's offline --------------------------------
    joined = "Greenfields:On('GF_MEMBER_JOINED', function(k) Greenfields.movers[#Greenfields.movers + 1] = 'in ' .. k end); " \
             "Greenfields:On('GF_MEMBER_LEFT', function(k) Greenfields.movers[#Greenfields.movers + 1] = 'out ' .. k end); Greenfields.movers = {}"
    bazza.lua(joined)
    add("Spencer", "Smith", 4)
    names = ["Spencer Greenfield", "Spencer Smith"]
    check("the clash is seen", bazza.eval_json("Greenfields.Roster:Clash('Spencer')") == names, bazza.eval_json("Greenfields.Roster:Clash('Spencer')"))
    check("and by the namesake's own client", spencer.eval_json("Greenfields.Roster:Clash('Spencer')") == names)
    check("the roster counts them as two people", bazza.eval_json("Greenfields.Roster:Count()") == count + 1)
    check("and both online", bazza.eval_json("Greenfields.Roster:OnlineCount()") == online + 1)
    check("nobody's mistaken for a new face", bazza.eval_json("#Greenfields.movers") == 0, bazza.eval_json("Greenfields.movers"))
    for c, who in ((bazza, "someone else's client"), (spencer, "their own client")):
        check("no GM rights on " + who, is_gm(c) is False)
        check("no officer rights on " + who, c.eval_json("Greenfields.Roster:IsOfficer('Spencer')") is False)
        check("no rank on " + who, c.eval_json("Greenfields.Roster:RankIndex('Spencer')") == 99)
    check("no raid tool rights", bazza.eval_json("Greenfields.Roster:CanManage('Spencer')") is False)
    sim.set_group("party", ["Spencer", "Bazza"], "Spencer")
    sim.advance(1)
    check("not even for leading the group", bazza.eval_json("Greenfields.Roster:CanManage('Spencer')") is False)
    check("someone else leading a group still counts", spencer.eval_json("Greenfields.Roster:CanManage('Bazza')") is True)
    sim.clear_group()
    sim.advance(1)
    check("someone else's rights are untouched", bazza.eval_json("Greenfields.Roster:IsOfficer('Bazza')") is True and is_gm(bazza, "Bazza") is False)

    # the GM is told, once, and nobody else
    check("the GM gets told", prints(spencer, "2 residents answer to Spencer (Spencer Greenfield, Spencer Smith)") == 1)
    check("nobody else does", prints(bazza, "answer to") == 0)
    roster(spencer)
    roster(spencer)
    check("once, however many scans", prints(spencer, "answer to") == 1)
    check("the doctor warns", "Spencer x2 (Spencer Greenfield, Spencer Smith)" in doctor_line(bazza) and "WARNING" in doctor_line(bazza), doctor_line(bazza))

    # the GM edit: refused at home, and refused on everyone else if it's forged
    check("the GM's edit is refused while it's a clash", spencer.eval_json("Greenfields.Store:Put('config', 'guild', { motd = 'during' })") is False)
    forged = "'1r' .. Greenfields.Serialize.Encode({ 'SU', { c = 'cf', l = { { 'guild', 2000000000, 'Spencer', 1, { motd = 'forged' } } } }, 1 })"
    spencer.lua("Greenfields.API.SendAddon('GRNFLDS', %s, 'GUILD')" % forged)
    sim.advance(1)
    check("a namesake's edit doesn't land on anyone", motd(bazza) == "before", motd(bazza))

    # --- no whispers, no invites ---------------------------------------------------------------------
    n, b, w = len(sim.invites), len(sim.bounced), sim.whispered.get("HI", 0)
    check("no addon whisper", bazza.eval_json("Greenfields.Comm:Whisper('Spencer', 'HI', { v = Greenfields.VERSION, p = 1, r = 1 })") is False)
    check("no whisper name", bazza.eval_json("Greenfields.API.WhisperName('Spencer')") is None)
    bazza.lua_hw("Greenfields.chatWent = { Greenfields.API.SendChat('oi', 'WHISPER', 'Spencer') }")
    check("no chat whisper", bazza.eval_json("Greenfields.chatWent") == [False, "clash"], bazza.eval_json("Greenfields.chatWent"))
    bazza.lua_hw("Greenfields.inviteWent = { Greenfields.API.Invite('Spencer') }")
    check("no invite", bazza.eval_json("Greenfields.inviteWent") == [False, "clash"], bazza.eval_json("Greenfields.inviteWent"))
    bazza.lua_hw("Greenfields.UI:Whisper('Spencer')")
    check("a Whisper button says why", prints(bazza, "won't guess") == 1)
    sim.advance(1)
    check("none of it reached anyone", len(sim.invites) == n and len(sim.bounced) == b and sim.whispered.get("HI", 0) == w,
          [sim.invites[n:], sim.bounced[b:]])

    # --- everyone else carries on: nobody's locked out, and sync still runs ---------------------------
    for c in (spencer, bazza):
        check("the gate stays open for " + c.name, c.eval_json("Greenfields.Gate:Why()") is None and not c.eval_json("Greenfields.gateShut"))
    check("the name's still a guildie", bazza.eval_json("Greenfields.Roster:IsMember('Spencer')") is True and bazza.eval_json("Greenfields.Roster:WasMember('Spencer')") is True)
    sim.bounced.clear()
    sim.whispered.clear()
    sim.login(shazza)
    sim.advance(120)
    check("the gate opens for someone logging in", shazza.eval_json("Greenfields.Gate:Why()") is None and not shazza.eval_json("Greenfields.gateShut"))
    check("they see the clash from their first scan", shazza.eval_json("Greenfields.Roster:Clash('Spencer')") == names and is_gm(shazza) is False)
    for op in ("SQ", "SX", "SG"):
        check("someone outside the clash still catches up: %s" % op, sim.whispered.get(op, 0) > 0, sim.whispered)
    check("Bazza's data reaches them", shazza.eval_json("Greenfields.Store:Get('profile', 'Bazza') ~= nil") is True)
    check("and the other way", bazza.eval_json("Greenfields.Store:Get('profile', 'Shazza') ~= nil") is True)
    # what the GM wrote before the clash has no rights behind it while it lasts, so someone catching up
    # gets it after: the 'they leave' checks below. Slow, not lost.
    check("the GM's old edit waits for the clash to end", motd(shazza) is None, motd(shazza))
    check("hello answers still go out", sim.whispered.get("HI", 0) > 0, sim.whispered)
    check("nothing bounced", not sim.bounced, sim.bounced)
    # the clash doesn't stop the namesake's guild traffic being heard, or them whispering out
    for c in (bazza, shazza):
        check("nobody's ignored on " + c.name, c.eval_json("next(Greenfields.Comm.ignored) == nil") is True, c.eval_json("Greenfields.Comm.ignored"))
    spencer.lua("Greenfields.Comm:Guild('HI', { v = '8.8.8', p = 1 })")
    sim.advance(1)
    check("the name's still heard", bazza.eval_json("Greenfields.Comm.peers.Spencer.version") == "8.8.8")
    check("the namesake can still whisper out", spencer.eval_json("Greenfields.Comm:Whisper('Bazza', 'HI', { v = '8.8.9', p = 1, r = 1 })") is True)
    sim.advance(1)
    check("and it's heard", bazza.eval_json("Greenfields.Comm.peers.Spencer.version") == "8.8.9")

    # a raid's invite list leaves the name out, and the sign says what really happened
    n = len(sim.invites)
    r = bazza.lua_hw("local ok, ids = Greenfields.Raids:CreateEvent({ title = 'Clash night', instance = 'Hyjal Summit', "
                     "time = GetServerTime() + 600, duration = 10800, srLimit = 2 }, 1) return type(ids) == 'table' and ids[1] or ids")
    id_ = u8(r[1])
    sim.advance(5)
    for c in (spencer, shazza):
        c.lua_hw("Greenfields.Raids:SetSignup(..., 'yes', nil, 'keen as')", id_)
    sim.advance(5)
    got = bazza.eval_json("Greenfields.Raids:InviteCandidates(%s)" % to_lua(id_))
    check("the invite list skips the name", got == ["Shazza"], got)
    bazza.lua_hw("local G = Greenfields; G.UI:ShowPage('raids', ...); "
                 "local own = G.UI.OpenMenu; G.UI.OpenMenu = function(_, _, items) G.menuItems = items end; "
                 "local function find(f) if f.toolsBtn then return f end "
                 "for _, k in ipairs({ f:GetChildren() }) do local r = find(k) if r then return r end end end; "
                 "local page = find(%s); page.toolsBtn:GetScript('OnClick')(page.toolsBtn, 'LeftButton'); G.UI.OpenMenu = own; "
                 "G.ownToast = G.UI.Toast; G.UI.Toast = function(self, o) G.toasted = o; return G.ownToast(self, o) end; "
                 "for _, it in ipairs(G.menuItems or {}) do if it.text and it.text:find('Invite the signed', 1, true) then it.func() end end; "
                 "G.UI.Toast = G.ownToast" % MAIN_FRAME, id_)
    toasted = bazza.eval_json("Greenfields.toasted and Greenfields.toasted.text")
    check("Invite signed says they're sent, not that anyone's in",
          toasted is not None and "1 invite on the way" in str(toasted) and "Nobody's in" in str(toasted), toasted)
    sim.advance(1)
    check("and the one invite goes to the full name", [i["target"] for i in sim.invites[n:]] == ["Shazza Greenfield"], sim.invites[n:])

    # the pages that show ranks and names cope with a row that has neither
    for page, arg in (("roster", None), ("settings", None), ("home", None)):
        spencer.lua("Greenfields.UI:ShowPage(...)", page, arg)
        bazza.lua("Greenfields.UI:ShowPage(...)", page, arg)
        sim.advance(0.5)
    bazza.lua("Greenfields.UI:OpenProfile('Spencer')")
    sim.advance(0.5)
    bazza.lua_hw("local G = Greenfields; G.ownToast = G.UI.Toast; G.toasted = nil; G.UI.Toast = function(self, o) G.toasted = o; return G.ownToast(self, o) end; "
                 "local function find(f) if f.invite and f.whisper then return f end "
                 "for _, k in ipairs({ f:GetChildren() }) do local r = find(k) if r then return r end end end; "
                 "local h = find(%s); h.invite:GetScript('OnClick')(h.invite, 'LeftButton'); G.UI.Toast = G.ownToast" % MAIN_FRAME)
    toasted = bazza.eval_json("Greenfields.toasted and Greenfields.toasted.text")
    check("the Invite button says why, not 'try again in a sec'", toasted is not None and "won't guess" in str(toasted), toasted)

    # --- half the pair goes out of sight: the rights don't come back ---------------------------------
    bazza.Game.HideRosterRow("Spencer Smith", True)
    roster(bazza)
    check("a hidden row: still a clash", bazza.eval_json("Greenfields.Roster:Clash('Spencer')") == names)
    check("a hidden row: still no GM", is_gm(bazza) is False)
    check("a hidden row: the doctor still warns", "from an earlier scan" in doctor_line(bazza) and "WARNING" in doctor_line(bazza), doctor_line(bazza))
    bazza.Game.HideRosterRow("Spencer Smith", False)
    bazza.Game.HideRosterRow("Spencer", True)
    roster(bazza)
    check("the other row hidden: still no GM on what's left", is_gm(bazza) is False and bazza.eval_json("Greenfields.Roster:Clash('Spencer')") == names)
    bazza.Game.HideRosterRow("Spencer", False)
    bazza.lua("local A = Greenfields.API; A.ownMembers = A.GuildMembers; A.GuildMembers = function() local all, h = A.ownMembers(); local out = {} "
              "for _, m in ipairs(all) do if m.name == 'Spencer Greenfield' then out[1] = m end end return out, h end")
    roster(bazza)
    check("a partial roster: still no GM", is_gm(bazza) is False and bazza.eval_json("Greenfields.Roster:Clash('Spencer')") == names)
    bazza.lua("local A = Greenfields.API; A.GuildMembers = A.ownMembers; A.ownMembers = nil")
    roster(bazza)
    check("back to normal: still the clash", is_gm(bazza) is False)

    # the same full name twice is a stutter in the roster, not two people
    bazza.lua("local A = Greenfields.API; A.ownMembers = A.GuildMembers; A.GuildMembers = function() local all, h = A.ownMembers(); "
              "for _, m in ipairs(all) do if m.name == 'Shazza Greenfield' then all[#all + 1] = m; break end end return all, h end")
    roster(bazza)
    check("one name read twice isn't a clash", bazza.eval_json("Greenfields.Roster:Clash('Shazza')") is None)
    check("or two people", bazza.eval_json("Greenfields.Roster:Count()") == count + 1)   # that's Spencer Smith
    check("and the doctor agrees", "Shazza x" not in doctor_line(bazza), doctor_line(bazza))
    bazza.lua("local A = Greenfields.API; A.GuildMembers = A.ownMembers; A.ownMembers = nil")
    roster(bazza)

    # --- the gate's shut: the GM hears about it when it opens, not before ------------------------------
    spencer.lua("Greenfields.gateShut = true")
    spencer.Game.AddMember("Shazza", "Jones", 4, True)
    roster(spencer)
    check("gate shut: the GM's not told", prints(spencer, "answer to Shazza") == 0)
    spencer.lua("Greenfields.gateShut = false")
    roster(spencer)
    check("gate open: now they are", prints(spencer, "answer to Shazza") == 1)
    spencer.Game.RemoveMember("Shazza", "Jones")
    roster(spencer)

    # --- the recruit leaves: the next scan puts it all back --------------------------------------------
    n = len(sim.invites)
    bazza.lua("Greenfields.movers = {}")
    remove("Spencer", "Smith")
    check("they leave: the clash clears", bazza.eval_json("Greenfields.Roster:Clash('Spencer')") is None)
    check("they leave: the GM's the GM again", is_gm(bazza) is True and is_gm(spencer) is True and is_gm(shazza) is True)
    check("they leave: the count's right", bazza.eval_json("Greenfields.Roster:Count()") == count, bazza.eval_json("Greenfields.Roster:Count()"))
    check("they leave: the real one didn't move out", bazza.eval_json("#Greenfields.movers") == 0, bazza.eval_json("Greenfields.movers"))
    check("they leave: the doctor's clear", "Repeated first names: none in" in doctor_line(bazza))
    check("they leave: the GM's edit is allowed again", spencer.eval_json("Greenfields.Store:Put('config', 'guild', { motd = 'after' })") is True)
    sim.advance(5)
    check("they leave: the GM's edit lands", motd(bazza) == "after" and motd(shazza) == "after", [motd(bazza), motd(shazza)])
    check("they leave: whispers are back", bazza.eval_json("Greenfields.API.WhisperName('Spencer')") == "Spencer Greenfield")
    bazza.lua_hw("Greenfields.API.Invite('Spencer')")
    sim.advance(0.5)
    check("they leave: invites are back", [i["target"] for i in sim.invites[n:]] == ["Spencer Greenfield"], sim.invites[n:])
    # and if it happens again the GM hears again
    add("Spencer", "Jones", 4)
    check("another one: the GM's told again", prints(spencer, "answer to Spencer") == 2)
    remove("Spencer", "Jones")

    for inv in sim.invites:
        check("no bare-name invites", " " in inv["target"], inv)
    for c in sim.clients:
        rep = collect_client_report(c)
        check("no Lua errors on " + c.name, not rep["errors"] and not rep["addonErrors"], rep["errors"] + rep["addonErrors"])
    sc["time"] = round(time.time() - t0, 1)
    return sim


def scenario_forever(res):
    """Telling Forever from anything else if the client changes on us: the 'Camelot' name is due to be
    renamed. The mock defines every signal, so this loads Core/Compat.lua on its own against made-up
    ones, then runs a whole client with both name checks gone."""
    sc = res.scenario("forever")
    t0 = time.time()

    def check(name, ok, got=None):
        sc["checks"].append({"name": name, "ok": bool(ok), "got": got})
        if not ok:
            sc["status"] = "fail"
            sc["notes"].append(name)
            res.harness_failures.append("forever: %s (got %r)" % (name, got))

    sim = Sim(3, "forever")
    spencer, bazza = sim.clients[:2]
    src = open(os.path.join(ADDON_DIR, "Core", "Compat.lua"), "rb").read().decode("latin-1")
    probe = spencer.rt.eval("""function(src, pid, camelot, toc, regional, tocFails, tocSecret)
        local fake = { WOW_PROJECT_ID = pid, WOW_PROJECT_CAMELOT = camelot }
        if toc then fake.GetBuildInfo = function() if tocFails then error('nope') end return '1.60.1', '70425', 'Oct 16 2026', toc end end
        if tocSecret then fake.issecretvalue = function(v) return v == toc end end
        if regional ~= nil then fake.RegionalUniqueNamesEnabled = function() return regional end end
        local f = assert(loadstring(src, '=compat'))
        setfenv(f, setmetatable({ _G = fake }, { __index = _G }))
        local ns = {}
        f('Greenfields', ns)
        return ns.API.IsForever(), ns.API.UniqueNames(), ns.API.Key('Kaghul Doomskull')
    end""")
    #       label                                 pid   camelot toc    regional fails  secret forever unique
    for label, pid, camelot, toc, regional, fails, secret, forever, unique in (
        ("the names as they are",                  18,  18,     16001, True,    False, False, True,   True),
        ("Camelot renamed, TOC 16001",             99,  None,   16001, None,    False, False, True,   True),
        ("no project at all, TOC 16002",           None, None,  16002, None,    False, False, True,   True),
        ("bottom of the range",                    99,  None,   16000, None,    False, False, True,   True),
        ("top of the range",                       99,  None,   19999, None,    False, False, True,   True),
        ("just under the range",                   99,  None,   15999, None,    False, False, False,  False),
        ("just over the range",                    99,  None,   20000, None,    False, False, False,  False),
        ("classic era",                            2,   None,   11508, None,    False, False, False,  False),
        ("retail",                                 1,   None,   120000, None,   False, False, False,  False),
        ("no build info at all",                   99,  None,   None,  None,    False, False, False,  False),
        ("build info that throws",                 99,  None,   16001, None,    True,  False, False,  False),
        ("a secret TOC number",                    99,  None,   16001, None,    False, True,  False,  False),
        ("project mismatch, in range",             1,   18,     16001, None,    False, False, True,   True),
        ("regional names alone",                   99,  None,   11508, True,    False, False, False,  True),
    ):
        got = probe(src, pid, camelot, toc, regional, fails, secret)
        got = (got[0], got[1], u8(got[2]))
        key = "Kaghul" if unique else "Kaghul Doomskull"
        check(label, got == (forever, unique, key), got)

    # a whole client with both name checks gone: keys stay bare, so sync and whispers still work
    for c in (spencer, bazza):
        c.lua("WOW_PROJECT_CAMELOT = nil; RegionalUniqueNamesEnabled = nil; WOW_PROJECT_ID = 99")
    sim.login(spencer)
    sim.login(bazza)
    sim.advance(60)
    check("whole client: still Forever", spencer.eval_json("Greenfields.API.IsForever()") is True)
    check("whole client: roster keys have no surnames", spencer.eval_json("Greenfields.Roster:IsMember('Bazza')") is True
          and spencer.eval_json("Greenfields.Roster:IsMember('Bazza Greenfield')") is False)
    check("whole client: data syncs", bazza.eval_json("Greenfields.Store:Get('profile', 'Spencer') ~= nil") is True)
    check("whole client: nothing bounced", not sim.bounced, sim.bounced)

    # the TOC line, and release.py still reading it
    _, meta = read_toc()
    check("the TOC lists both builds", meta.get("Interface") == "16001, 16002", meta.get("Interface"))
    spec = importlib.util.spec_from_file_location("gf_release", os.path.join(ROOT, "tools", "release.py"))
    release = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(release)
    check("release.py reads the first build", release.read_toc_interface() == 16001, release.read_toc_interface())
    for c in (spencer, bazza):
        rep = collect_client_report(c)
        check("no Lua errors on " + c.name, not rep["errors"] and not rep["addonErrors"], rep["errors"] + rep["addonErrors"])
    sc["time"] = round(time.time() - t0, 1)
    return sim


def scenario_rules(res):
    """Launch-week rules on their own clients: stats that can't be redone later (world map emotes, double
    deaths, one week for everyone), crowns that don't flood the guild, parties that aren't failed, the
    rough wealth score and the first-login lines. A failed check fails the run."""
    sc = res.scenario("rules")
    t0 = time.time()

    def check(name, ok, got=None):
        sc["checks"].append({"name": name, "ok": bool(ok), "got": got})
        if not ok:
            sc["status"] = "fail"
            sc["notes"].append(name)
            res.harness_failures.append("rules: %s (got %r)" % (name, got))

    sim = Sim(3, "rules")
    spencer, bazza, shazza = sim.clients[:3]
    for c in sim.clients:
        sim.login(c)
    sim.advance(120)

    def stat(c, key):
        return c.eval_json("Greenfields.cdb.stats[%s] or 0" % to_lua(key))

    def slash(c, msg):
        c.MOCK.HardwareCall("/gf " + msg, c.G.SlashCmdList.GREENFIELDS, msg)
        sim.advance(0.2)

    def emote_line(c):
        slash(c, "doctor")
        lines = [str(l) for l in c.eval_json("GreenfieldsDB.doctor.lines")]
        return str(next((l for l in lines if l.startswith("Emote hook")), None))

    def errors(c):
        rep = collect_client_report(c)
        return rep["errors"] + rep["addonErrors"]

    # --- one week for everyone --------------------------------------------------------
    def utc(*a):
        return calendar.timegm(a + (0,) * (6 - len(a)))

    week = spencer.rt.eval("function(ts) return Greenfields.Util.WeekKey(ts), Greenfields.Util.WeekStart(ts) end")
    for tz in (8, 11, -8, 0):        # Mandurah, Sydney in summer, the west coast of America, London
        spencer.MOCK.SetTZ(tz)
        for label, ts, key in (
            ("a second before the flip",      utc(2026, 11, 3, 15, 59, 59), 20261028),
            ("the flip, Tue 16:00 UTC",       utc(2026, 11, 3, 16),         20261104),
            ("launch morning",                utc(2026, 11, 4, 23),         20261104),
            ("the end of that week",          utc(2026, 11, 10, 15, 59, 59), 20261104),
            ("the week that spans new year",  utc(2026, 12, 29, 16),        20261230),
            ("new year's day, that week",     utc(2027, 1, 1, 5),           20261230),
            ("still that week in January",    utc(2027, 1, 5, 15, 59, 59),  20261230),
            ("first week of 2027",            utc(2027, 1, 5, 16),          20270106),
            ("the flip lands on 1 January",   utc(2024, 12, 31, 16),        20250101),
            ("just before that one",          utc(2024, 12, 31, 15, 59, 59), 20241225),
            ("over a leap day",               utc(2028, 2, 29, 16),         20280301),
        ):
            got = week(ts)
            check("week key at UTC%+d: %s" % (tz, label), got[0] == key, got[0])
    start = week(utc(2026, 11, 7, 3))[1]
    check("WeekStart is the Tuesday 16:00 UTC before", start == utc(2026, 11, 3, 16), start)
    keys = {week(utc(2026, 1, 7, 16) + i * 604800)[0] for i in range(104)}
    check("two years of weeks, 104 different keys", len(keys) == 104, len(keys))
    spencer.MOCK.SetTZ(8)

    # --- world map emotes -------------------------------------------------------------
    before = stat(spencer, "emotes")
    check("doctor: says when the hook hasn't fired", "hasn't fired" in emote_line(spencer), emote_line(spencer))
    spencer.lua("DoEmote('DANCE')")
    sim.advance(0.2)
    check("a real emote counts", stat(spencer, "emotes") == before + 1, stat(spencer, "emotes"))
    check("doctor: shows the arguments", "last DoEmote(DANCE, nil, nil), counted 1, ignored 0" in emote_line(spencer), emote_line(spencer))
    spencer.lua("DoEmote('READ', nil, true)")
    sim.advance(0.2)
    check("the world map's emote doesn't", stat(spencer, "emotes") == before + 1, stat(spencer, "emotes"))
    spencer.lua("C_ChatInfo.PerformEmote('READ', nil, true)")
    sim.advance(0.2)
    check("nor through the other door", stat(spencer, "emotes") == before + 1, stat(spencer, "emotes"))
    check("doctor: shows what it ignored", "last PerformEmote(READ, nil, true), counted 1, ignored 2" in emote_line(spencer), emote_line(spencer))
    spencer.lua("DoEmote('FLEX', nil, false)")
    sim.advance(0.2)
    check("false still counts", stat(spencer, "emotes") == before + 2, stat(spencer, "emotes"))
    spencer.rt.eval("function(M) DoEmote('WAVE', nil, M.Secret(true)) end")(spencer.MOCK)
    sim.advance(0.2)
    check("a secret third argument counts, and doesn't throw", stat(spencer, "emotes") == before + 3, stat(spencer, "emotes"))
    check("doctor: a secret argument only says hidden", ", hidden)" in emote_line(spencer), emote_line(spencer))

    # --- double deaths ----------------------------------------------------------------
    before = stat(spencer, "deaths_total")
    spencer.Game.Die()
    sim.advance(1)
    spencer.Game.Die()
    sim.advance(0.5)
    check("a repeat death inside 2 s is one death", stat(spencer, "deaths_total") == before + 1, stat(spencer, "deaths_total"))
    sim.advance(3)
    spencer.Game.Die()
    sim.advance(0.5)
    check("the next death still counts", stat(spencer, "deaths_total") == before + 2, stat(spencer, "deaths_total"))

    # --- the wealth score -------------------------------------------------------------
    score = spencer.rt.eval("function(v) return Greenfields.WealthScore(v) end")
    for label, copper, want in (("nothing", 0, 0), ("under a gold", 9999, 0), ("1g", 10000, 6), ("just under 3g", 29999, 6),
                                ("3g", 30000, 12), ("7g", 70000, 18), ("15g", 150000, 24), ("31g", 310000, 30),
                                ("63g", 630000, 36), ("1,023g", 10230000, 60), ("a million gold", 10000000000, 114),
                                ("in debt", -5, 0), ("junk", "abc", 0), ("nil", None, 0)):
        check("wealth score: " + label, score(copper) == want, score(copper))
    check("wealth score: an absurd number stops and stays sane", 0 <= score(1e300) <= 400, score(1e300))
    check("wealth score: infinity stops and stays sane", 0 <= spencer.eval_json("Greenfields.WealthScore(1/0)") <= 400)
    check("wealth score: not-a-number reads as nothing", spencer.eval_json("Greenfields.WealthScore(0/0)") == 0)
    # the promise in Settings: two amounts sharing a score are never more than double apart
    bands = {}
    for g in range(1, 200000, 7):
        bands.setdefault(score(g * 10000), []).append(g)
    worst = max((max(v) + 1) / (min(v) + 1) for v in bands.values())
    check("wealth score: a band is never wider than double", worst <= 2.0, worst)
    check("wealth score: 1g to 200,000g fits in 18 bands", len(bands) <= 18, len(bands))
    for rel in (("UI", "Settings.lua"), ("Data", "Titles.lua"), ("Modules", "Stats.lua"), ("Modules", "Fun.lua")):
        text = open(os.path.join(ADDON_DIR, *rel), encoding="utf-8").read()
        check("wealth wording is honest in " + rel[1], "within about double" in text and "12%" not in text)

    # --- crowns -----------------------------------------------------------------------
    def leader(c, key, scope="all"):
        return c.eval_json("(Greenfields.Stats:Leader(%s, %s))" % (to_lua(key), to_lua(scope)))

    def top(c, key):
        return [r["key"] for r in c.eval_json("Greenfields.Stats:Board(%s)" % to_lua(key))]

    def held(c):
        return [t["key"] for t in c.eval_json("Greenfields.Stats:TitlesOf(%s)" % to_lua(c.name))]

    def signs(c):
        return c.eval_json("rawget(_G, 'Greenfields_ToastLog')") or []

    def rows(c, kind):
        return [r["text"] for r in c.eval_json("Greenfields.Feed:Recent(50)") if r["kind"] == kind]

    for c in sim.clients:
        c.lua("local n = {} rawset(_G, 'Greenfields_ToastLog', n) local UI = Greenfields.UI local o = UI.Toast "
              "UI.Toast = function(s, t) n[#n + 1] = t.title return o(s, t) end")
    sim.advance(100)      # past the login settle time, so crowns announce
    d = stat(spencer, "deaths_total")
    check("deaths: under the minimum to start with", 0 < d < 5, d)
    check("deaths: on the board, but no crown yet", top(spencer, "deaths_total")[:1] == ["Spencer"] and leader(spencer, "deaths_total") is None,
          (top(spencer, "deaths_total"), leader(spencer, "deaths_total")))
    check("deaths: TitlesOf doesn't hand it out either", "deaths_total" not in held(spencer), held(spencer))
    check("deaths: no feed row for it yet", not any("Spirit Healer" in t for t in rows(spencer, "title")), rows(spencer, "title"))
    while stat(spencer, "deaths_total") < 5:
        spencer.Game.Die()
        sim.advance(3)
    sim.advance(20)
    check("deaths: the minimum claims it", leader(spencer, "deaths_total") == "Spencer", leader(spencer, "deaths_total"))
    check("deaths: TitlesOf has it now", "deaths_total" in held(spencer), held(spencer))
    check("the new crown is a feed row", any("Spirit Healer" in t for t in rows(spencer, "title")), rows(spencer, "title"))
    check("and no sign for the one who took it", "New crown in town" not in signs(spencer), signs(spencer))
    sim.advance(5)
    check("the others get the feed row", any("Spirit Healer" in t for t in rows(bazza, "title")), rows(bazza, "title"))
    check("and no sign either", "New crown in town" not in signs(bazza), signs(bazza))
    # an old copy of the addon still flags crowns; dings, badges and joins keep their signs
    spencer.lua("Greenfields.Comm:Guild('FD', { k = 'title', x = 'An old copy took a crown.', o = 1 })")
    sim.advance(1)
    check("an old copy can't make a crown sign", any("old copy" in t for t in rows(bazza, "title")) and "New crown in town" not in signs(bazza), signs(bazza))
    for kind, headline in (("level", "Ding on the street"), ("badge", "Badge earned"), ("join", "New neighbour")):
        spencer.lua("Greenfields.Feed:Post(%s, %s)" % (to_lua(kind), to_lua("Testing the %s sign." % kind)))
        sim.advance(2)
        check(kind + " keeps its sign", headline in signs(bazza), signs(bazza))

    # what the pages make of a crown nobody's claimed: emotes are on the board, under their minimum
    home = "Greenfields.UI.pages.home.frame"
    fame = "Greenfields.UI.pages.fame.frame"
    spencer.lua("Greenfields.UI:ShowPage('fame', 'shame')")
    sim.advance(1)
    card = spencer.eval_json("(function() for _, c in ipairs(%s.views.grid.cards) do if c.def and c.def.key == 'emotes' then "
                             "return { claimed = c.claimed, held = c.held, name = c.name:GetText() } end end end)()" % fame)
    check("Hall: on the board under the minimum is up for grabs", top(spencer, "emotes")[:1] == ["Spencer"] and card
          and card["claimed"] is False and "Up for grabs" in str(card["name"]), card)
    spencer.lua("Greenfields.UI:ShowPage('fame', 'emotes')")
    sim.advance(1)
    check("Leaderboard: no crown on the top row yet", spencer.eval_json("%s.crownKey" % fame) is None, spencer.eval_json("%s.crownKey" % fame))
    spencer.lua("Greenfields.UI:ShowPage('fame', 'deaths_total')")
    sim.advance(1)
    check("Leaderboard: the holder wears it", spencer.eval_json("%s.crownKey" % fame) == "Spencer", spencer.eval_json("%s.crownKey" % fame))

    # the wealth pair: nobody's crowned until somebody's got something, and ties settle the same everywhere
    def money(s, b, m):
        spencer.Game.SetMoney(s * 10000)
        bazza.Game.SetMoney(b * 10000)
        shazza.Game.SetMoney(m * 10000)
        sim.advance(330)      # the stats doc waits up to five minutes to go out

    def home_tile(c, key):
        c.lua("Greenfields.UI:ShowPage('home')")
        sim.advance(1)
        return c.eval_json("(function() for _, t in ipairs(%s.crowns.tiles) do if t.def and t.def.key == %s then "
                           "return t.name:GetText() end end end)()" % (home, to_lua(key)))

    money(20, 40, 5)
    for c in sim.clients:
        check("everyone under 63g: no richest on " + c.name, leader(c, "wealth") is None, leader(c, "wealth"))
        check("everyone under 63g: no poorest on " + c.name, leader(c, "wealth_low") is None, leader(c, "wealth_low"))
        check("the board still shows the order on " + c.name, top(c, "wealth") == ["Bazza", "Spencer", "Shazza"], top(c, "wealth"))
    check("Home: the richest crown's up for grabs", "Up for grabs" in str(home_tile(spencer, "wealth")), home_tile(spencer, "wealth"))
    money(1200, 40, 5)
    for c in sim.clients:
        check("someone clears the bar: richest on " + c.name, leader(c, "wealth") == "Spencer", leader(c, "wealth"))
        check("and the poorest can be crowned on " + c.name, leader(c, "wealth_low") == "Shazza", leader(c, "wealth_low"))
        board = c.eval_json("Greenfields.Stats:Board('wealth')")
        check("rank stats still hide the score on " + c.name, all("value" not in r and "score" not in r for r in board), board)
    check("Home: the richest crown's claimed", "Spencer" in str(home_tile(spencer, "wealth")), home_tile(spencer, "wealth"))
    money(100, 110, 90)
    for c in sim.clients:
        check("a three-way tie goes by name on " + c.name, top(c, "wealth") == ["Bazza", "Shazza", "Spencer"], top(c, "wealth"))
        check("the richest of a tie agrees on " + c.name, leader(c, "wealth") == "Bazza", leader(c, "wealth"))
        check("the poorest of a tie isn't the same person on " + c.name, leader(c, "wealth_low") == "Spencer", leader(c, "wealth_low"))
    bazza.lua("Greenfields.db.settings.shareWealth = false")
    sim.advance(340)
    check("opting out takes you off the board", top(spencer, "wealth") == ["Shazza", "Spencer"], top(spencer, "wealth"))
    bazza.lua("Greenfields.db.settings.shareWealth = true")

    # --- parties aren't failures ------------------------------------------------------
    def analyze(members):
        return spencer.eval_json("(function() local r = Greenfields.Buffs:Analyze(%s) local out = { score = r.score, missing = r.missing, "
                                 "under60 = r.under60, covered = r.covered, applicable = r.applicable, cats = {} } "
                                 "for k, e in pairs(r.cats) do out.cats[k] = { status = e.status, tooLow = e.tooLow } end return out end)()" % to_lua(members))

    low = [{"key": "Davo", "class": "WARRIOR", "level": 14}, {"key": "Kylie", "class": "PALADIN", "level": 14},
           {"key": "Macca", "class": "HUNTER", "level": 14}, {"key": "Sheila", "class": "PRIEST", "level": 14},
           {"key": "Tazza", "class": "WARLOCK", "level": 14}]
    rep = analyze(low)
    for k in ("kings", "spirit", "crit"):
        check("level 14: %s, which nobody can learn, isn't missing" % k, rep["cats"][k]["status"] == "na" and rep["cats"][k].get("tooLow") is True, rep["cats"][k])
        check("level 14: nor on the missing list: " + k, k not in (rep["missing"] or []), rep["missing"])
    check("level 14: what they can learn still counts", rep["cats"]["wisdom"]["status"] != "na" and rep["cats"]["stamina"]["status"] != "na", rep["cats"])
    check("level 14: flagged under 60", rep["under60"] is True)
    check("level 14: the count adds up", rep["applicable"] == 6 and 0 <= rep["covered"] <= 6, (rep["covered"], rep["applicable"]))
    edge = analyze([{"key": "Kylie", "class": "PALADIN", "level": 19}, {"key": "Macca", "class": "HUNTER", "level": 19}])
    check("level 19: Kings still too low", edge["cats"]["kings"]["status"] == "na", edge["cats"]["kings"])
    edge = analyze([{"key": "Kylie", "class": "PALADIN", "level": 20}, {"key": "Macca", "class": "HUNTER", "level": 19}])
    check("level 20: Kings is in play", edge["cats"]["kings"]["status"] != "na" and not edge["cats"]["kings"].get("tooLow"), edge["cats"]["kings"])
    edge = analyze([{"key": "Macca", "class": "HUNTER", "level": 20}, {"key": "Davo", "class": "WARRIOR", "level": 19}])
    check("level 20 with no paladin: Kings really is missing", edge["cats"]["kings"]["status"] == "missing", edge["cats"]["kings"])
    one = analyze(low + [{"key": "Kev", "class": "ROGUE", "level": 60}])
    check("one 60 in the group: everything's in play", all(not e.get("tooLow") for e in one["cats"].values()), one["cats"])
    full = analyze([dict(m, level=60) for m in low])
    check("all 60: nothing's too low", all(not e.get("tooLow") for e in full["cats"].values()), full["cats"])
    check("all 60: not flagged", full["under60"] is False)
    strangers = [{"key": "Stranger%d" % i, "class": m["class"]} for i, m in enumerate(low)]
    blank = analyze(strangers)
    known = analyze([dict(m, level=60) for m in strangers])
    check("a level nobody can read counts as 60, as it always has", blank["score"] == known["score"] and blank["under60"] is False
          and blank["cats"]["kings"]["status"] != "na", (blank["score"], known["score"], blank["cats"]["kings"]))
    # someone whose profile proves they've got the spell isn't told it's not yet
    spencer.lua("local P = Greenfields.Profile P.__get = P.Get P.Get = function(s, k) if k == 'Kylie' then return { class = 'PALADIN', level = 14, caps = { 'kings' } } end return s.__get(s, k) end")
    proven = analyze(low)
    spencer.lua("local P = Greenfields.Profile P.Get = P.__get P.__get = nil")
    check("a proven caster under the learn level still counts", proven["cats"]["kings"]["status"] == "class", proven["cats"]["kings"])

    def party(names, level, kind="party"):
        for n in names:
            sim.world[n]["level"] = level
        if spencer.eval_json("UnitLevel('player')") != level:
            spencer.Game.SetLevel(level)
        sim.set_group(kind, names, names[0])
        sim.advance(2)

    def camp_card():
        spencer.lua("Greenfields.UI:ShowPage('home')")
        sim.advance(1)
        return spencer.eval_json("(function() local c = %s.camp local r, g, b = c.score:GetTextColor() local red = Greenfields.UI.col('red') "
                                 "return { score = c.score:GetText(), label = c.scoreLabel:GetText(), summary = c.summary:GetText(), "
                                 "red = (r == red[1] and g == red[2] and b == red[3]) } end)()" % home)

    def header():
        spencer.lua("Greenfields.UI:ShowPage('buffs', 'group')")
        sim.advance(1)
        return spencer.eval_json("Greenfields.UI.pages.buffs.frame.score:IsShown() and true or false")

    names = ["Spencer", "Davo", "Kylie", "Macca", "Sheila"]
    party(names, 14)
    got = camp_card()
    check("level 14 party, Home: no mark out of 100", re.fullmatch(r"\d+/\d+", str(got["score"])) is not None, got)
    check("level 14 party, Home: not red", got["red"] is False, got)
    check("level 14 party, Home: says why", "till 60" in str(got["summary"]) or "Sorted" in str(got["summary"]), got)
    check("level 14 party, Home: labelled for what it is", got["label"] == "covered", got)
    check("level 14 party, Buff Check: no score", header() is False)
    tile = spencer.eval_json("(function() for _, t in ipairs(Greenfields.UI.pages.buffs.frame.tiles) do if t.cat.key == 'kings' then "
                             "return { status = t.status, who = t.who:GetText() } end end end)()")
    check("level 14 party, Buff Check: Kings says not yet", tile and tile["status"] == "na" and "not yet" in str(tile["who"]), tile)

    # a booked lineup always gets its mark, even with the same people
    spencer.lua("local R = Greenfields.Raids R.__up, R.__lu = R.Upcoming, R.Lineup "
                "R.Upcoming = function() return { { id = 'fake', title = 'Test run', time = GetServerTime() + 3600, instance = 'Other' } } end "
                "R.Lineup = function() return { groups = { { 'Davo', 'Kylie', 'Macca', 'Sheila', 'Spencer' } } } end "
                "local Ro = Greenfields.Roster Ro.__lvl = Ro.Level Ro.Level = function() return 14 end")
    spencer.lua("Greenfields.UI:ShowPage('buffs', 'fake')")
    sim.advance(1)
    buffs = "Greenfields.UI.pages.buffs.frame"
    check("a booked lineup under 60 keeps its mark", spencer.eval_json("%s.view.kind" % buffs) == "event" and spencer.eval_json("%s.rep.under60" % buffs) is True
          and spencer.eval_json("%s.score:IsShown() and true or false" % buffs) is True, spencer.eval_json("%s.view.kind" % buffs))
    spencer.lua("local R = Greenfields.Raids R.Upcoming, R.Lineup = R.__up, R.__lu R.__up, R.__lu = nil, nil "
                "local Ro = Greenfields.Roster Ro.Level = Ro.__lvl Ro.__lvl = nil")

    party(names, 60)
    got = camp_card()
    check("level 60 party, Home: back to the number", re.fullmatch(r"\d+", str(got["score"])) is not None and got["label"] == "score", got)
    check("level 60 party, Buff Check: score shows", header() is True)
    party(names, 14, "raid")
    got = camp_card()
    check("raid under 60, Home: the raid maths stay", re.fullmatch(r"\d+", str(got["score"])) is not None and got["label"] == "score", got)
    check("raid under 60, Buff Check: score shows", header() is True)
    sim.clear_group()
    sim.advance(1)

    for c in sim.clients:
        check("no Lua errors on " + c.name, not errors(c), errors(c))

    # --- first login ------------------------------------------------------------------
    sim2 = Sim(5, "rules2")
    a, b, m, k, t = sim2.clients[:5]
    TELL = ["profession windows", "/gf main", "within about double"]

    def told(c):
        lines = [str(l) for l in c.jsonv(c.MOCK.printLog)]
        return [sum(1 for l in lines if text in l) for text in TELL]

    def gate_test(c):
        c.MOCK.HardwareCall("/gf gate test", c.G.SlashCmdList.GREENFIELDS, "gate test")

    m.Game.SetGuild(None)                # invited later
    k.Game.SetGuild("Gooner Gang")       # someone else's guild, then ours
    for c in sim2.clients:
        sim2.login(c)
    sim2.advance(1)
    gate_test(t)
    sim2.advance(5)
    check("first login: not straight away", told(a) == [0, 0, 0], told(a))
    sim2.advance(15)
    check("first login: three lines, once", told(a) == [1, 1, 1], told(a))
    check("first login: on every character", told(b) == [1, 1, 1], told(b))
    check("first login: and it's saved on the character", a.eval_json("GreenfieldsCharDB.toldNew") is True)
    sim2.advance(120)
    check("first login: the gate test holds it back", told(t) == [0, 0, 0], told(t))
    check("first login: no guild, nothing said", told(m) == [0, 0, 0], told(m))
    check("first login: another guild, nothing said", told(k) == [0, 0, 0], told(k))
    check("first login: and it's not marked as told", m.eval_json("GreenfieldsCharDB.toldNew") is None and k.eval_json("GreenfieldsCharDB.toldNew") is None)
    gate_test(t)
    sim2.advance(20)
    check("first login: told once the test's over", told(t) == [1, 1, 1], told(t))
    m.Game.SetGuild("Greenfields")
    m.fire("PLAYER_GUILD_UPDATE", "player")
    k.Game.SetGuild("Greenfields")
    k.fire("PLAYER_GUILD_UPDATE", "player")
    sim2.advance(5)
    check("first login: not the moment the gate opens", told(m) == [0, 0, 0], told(m))
    sim2.advance(15)
    check("first login: a late joiner gets it", told(m) == [1, 1, 1], told(m))
    check("first login: so does someone leaving another guild", told(k) == [1, 1, 1], told(k))
    m.Game.SetGuild(None)
    m.fire("PLAYER_GUILD_UPDATE", "player")
    sim2.advance(45)
    m.Game.SetGuild("Greenfields")
    m.fire("PLAYER_GUILD_UPDATE", "player")
    sim2.advance(30)
    check("first login: leaving and coming back doesn't repeat it", told(m) == [1, 1, 1], told(m))
    a.fire("PLAYER_ENTERING_WORLD", False, True)
    sim2.advance(20)
    check("first login: a loading screen doesn't repeat it", told(a) == [1, 1, 1], told(a))
    back = reload_client(sim2, res, a, report=False)
    fresh = sim2.by_name[back["client"]]
    sim2.advance(20)
    check("first login: nor does logging back in", told(fresh) == [0, 0, 0], told(fresh))
    for c in sim2.clients:
        check("no Lua errors on " + c.name, not errors(c), errors(c))
    sc["time"] = round(time.time() - t0, 1)
    return sim


def scenario_doctor(res):
    """The Black Box, /gf report, /gf doctor and /gf mic. On its own clients, because it breaks things on
    purpose to see them reported. A failed check fails the run."""
    sc = res.scenario("doctor")
    t0 = time.time()
    sim = Sim(3, "doctor")
    spencer, bazza, shazza = sim.clients

    def check(name, ok, got=None):
        sc["checks"].append({"name": name, "ok": bool(ok), "got": got})
        if not ok:
            sc["status"] = "fail"
            sc["notes"].append(name)
            res.harness_failures.append("doctor: %s (got %r)" % (name, got))

    def slash(c, msg):
        # typed in the chat box, so it's a keypress, and the keypress is over when the handler returns
        c.MOCK.HardwareCall("/gf " + msg, c.G.SlashCmdList.GREENFIELDS, msg)
        sim.advance(0.2)

    def prints(c):
        return [str(l) for l in c.jsonv(c.MOCK.printLog)]

    def said(c, text):
        return sum(1 for l in prints(c) if text in l)

    def box_text(c):
        return str(c.eval_json("GreenfieldsModal.dialog.edit:GetText()"))

    def box_up(c):
        return c.eval_json("(rawget(_G, 'GreenfieldsModal') and GreenfieldsModal:IsShown()) and true or false") is True

    def report(c):
        slash(c, "report")
        text = box_text(c)
        c.lua("Greenfields.UI:CloseModal()")
        return text

    def doctor(c):
        slash(c, "doctor")
        return [str(l) for l in c.eval_json("GreenfieldsDB.doctor.lines")]

    def line(lines, start):
        return next((l for l in lines if l.startswith(start)), None)

    def errors(c):
        return c.eval_json("#Greenfields.errors")

    def boom(c, label, msg):
        return c.eval_json("Greenfields:Safe(%s, function() error(%s) end)" % (to_lua(label), to_lua(msg)))

    def tool_errors(c):
        # /gf report, /gf doctor and /gf mic going wrong themselves, as opposed to what they were handed
        return c.eval_json("(function() local n = 0 for _, e in ipairs(Greenfields.errors) do "
                           "if e.label == 'report' or e.label == 'doctor' or e.label == 'mic' or e.label == 'slash mic' then n = n + 1 end end return n end)()")

    def party_lines(c):
        return [m for m in sim.chat_routed if m["from"] == c.name and m["chatType"] in ("PARTY", "RAID", "INSTANCE_CHAT")]

    def stray_errors(c):
        # anything caught besides the booms this scenario sets off itself: a chat listener throwing runs under the
        # event's name, so going by the tools' own labels alone would miss it
        return [e for e in c.eval_json("(function() local t = {} for _, e in ipairs(Greenfields.errors) do "
                                       "t[#t + 1] = { label = e.label, err = e.err } end return t end)()") or []
                if e.get("label") not in ("too early", "fight", "pile", "junk", "nodb")]

    # --- the Black Box ------------------------------------------------------------------
    # broken before the saved variables are even loaded
    spencer.lua("Greenfields:Safe('too early', function() error('before the saved variables') end)")
    sim.login(spencer)
    sim.login(bazza)
    sim.login(shazza)
    sim.advance(60)
    check("no saved variables: starts empty and doesn't throw", "Errors this session: 0. In the Black Box: 0." in report(bazza), report(bazza))
    check("an error from before the saved variables loaded still lands", "before the saved variables" in report(spencer))
    boom(spencer, "fight", "wheels fell off")
    boom(spencer, "fight", "wheels fell off")
    text = report(spencer)
    check("an error shows in the report", "wheels fell off" in text, text)
    check("with what it was doing", "] fight" in text, text)
    check("once, however often it happens in a session", text.count("wheels fell off") == 1, text)
    check("event that wouldn't register: nothing yet", "wouldn't register: none" in text, text)
    spencer.lua("Greenfields:RegisterEvent('NOT_A_REAL_EVENT', function() end); Greenfields:RegisterUnitEvent('ALSO_NOT_REAL', 'player', function() end)")
    text = report(spencer)
    check("events that wouldn't register are listed", "NOT_A_REAL_EVENT" in text and "ALSO_NOT_REAL:player" in text, text)
    slash(spencer, "errors")
    check("/gf errors points at the Black Box", said(spencer, "in the Black Box") == 1, prints(spencer)[-3:])
    doctor(spencer)
    text = report(spencer)
    check("the report carries the doctor's lines", "Addon senders seen" in text and "Guild lock:" in text, text)
    check("the report is plain text", "|c" not in text and "|r" not in text, text)

    # a /reload: Lua starts again, the saved variables don't
    check("nothing else threw before the reload", not stray_errors(spencer), stray_errors(spencer))
    r = reload_client(sim, res, spencer, report=False)
    spencer = next(c for c in sim.clients if c.name == "Spencer")
    check("a reload wipes this session's list", errors(spencer) == 0, errors(spencer))
    text = report(spencer)
    check("but the error survives it", "wheels fell off" in text, [r, text])
    check("and the report says which is which", "Errors this session: 0. In the Black Box: 2." in text, text)
    boom(spencer, "fight", "wheels fell off")
    text = report(spencer)
    check("the same one next session is counted, not repeated", text.count("wheels fell off") == 1 and "2 sessions" in text, text)

    for i in range(45):
        boom(spencer, "pile", "error number %d" % i)
    kept = spencer.eval_json("#GreenfieldsDB.blackBox")
    check("keeps the last 30", kept == 30, kept)
    text = report(spencer)
    check("the newest stay, the oldest go", "error number 44" in text and "error number 0\n" not in text and "wheels fell off" not in text, text[:300])
    check("the saved text stays small", spencer.eval_json("(function() local m = 0 for _, b in ipairs(GreenfieldsDB.blackBox) do m = math.max(m, #b.err) end return m end)()") <= 900)

    # saved data from an older version, or something that's been at it with a hex editor
    for junk in ("'junk'", "7", "{ 1, 'two', { label = 5 }, { err = 9 }, { label = 'ok', err = 'old one' } }", "nil"):
        spencer.lua("GreenfieldsDB.blackBox = %s; GreenfieldsDB.doctor = %s; GreenfieldsDB.mic = %s" % (junk, junk, junk))
        text = report(spencer)
        check("bad saved data %s: the report still opens" % junk, "Greenfields" in text and "Black Box" in text, text)
        check("bad saved data %s: it just reads as not there" % junk, "Mic check: not run" in text and "Doctor: not run" in text and "untested" not in text, text)
        if "old one" in junk:
            check("bad saved data: the good entries still show", "old one" in text and "] ok" in text, text)
        check("bad saved data %s: errors still land" % junk, boom(spencer, "junk", "after " + junk) is False and spencer.eval_json("type(GreenfieldsDB.blackBox)") == "table")
        slash(spencer, "errors")
    spencer.lua("GreenfieldsDB.mic = { lines = { 1, {} } }; GreenfieldsDB.doctor = { lines = 'x' }")
    check("half-written saved data doesn't throw", "Mic check" in report(spencer))
    spencer.lua("GreenfieldsDB.mic = nil; GreenfieldsDB.doctor = nil")
    check("nothing the report did went wrong", tool_errors(spencer) == 0, tool_errors(spencer))
    spencer.lua("Greenfields.dbWas = Greenfields.db; Greenfields.db = nil")
    boom(spencer, "nodb", "no database at all")
    slash(spencer, "report")
    check("no saved variables at all: the report still opens", "no database at all" in box_text(spencer), box_text(spencer))
    spencer.lua("Greenfields.UI:CloseModal()")
    slash(spencer, "doctor")
    check("and so does the doctor", said(spencer, "Doctor's report") >= 1 and tool_errors(spencer) == 0, tool_errors(spencer))
    spencer.lua("Greenfields.db = Greenfields.dbWas; Greenfields.dbWas = nil")
    # the copy box is broken: the text still comes out, in chat
    spencer.lua("Greenfields.boxWas = Greenfields.UI.CopyBox; Greenfields.UI.CopyBox = function() error('no box') end")
    slash(spencer, "report")
    check("no copy box: it prints instead", said(spencer, "Errors this session") >= 1)
    spencer.lua("Greenfields.UI.CopyBox = Greenfields.boxWas")
    # one part of the report dying doesn't take the rest with it
    spencer.lua("Greenfields.failedWas = Greenfields.failedEvents; Greenfields.failedEvents = nil")
    text = report(spencer)
    check("a dead part of the report says untested", "Events: untested (" in text and "Errors this session" in text and "Guild lock:" in text, text)
    spencer.lua("Greenfields.failedEvents = Greenfields.failedWas; Greenfields.failedWas = nil")
    slash(spencer, "report clear")
    check("/gf report clear empties it", "In the Black Box: 0." in report(spencer))

    # --- the doctor ---------------------------------------------------------------------
    lines = doctor(bazza)
    bounces = line(lines, "Whisper bounces:") or ""
    check("doctor: says the not-found pattern got built", "pattern built" in bounces and "No player named" in bounces, bounces)
    bazza.lua("Greenfields.bounceWas = Greenfields.Comm.BouncePattern; Greenfields.Comm.BouncePattern = function() end")
    bounces = line(doctor(bazza), "Whisper bounces:") or ""
    check("doctor: says so when the pattern didn't get built", "no not-found pattern" in bounces, bounces)
    bazza.lua("Greenfields.Comm.BouncePattern = function() error('boom') end")
    bounces = line(doctor(bazza), "Whisper bounces:") or ""
    check("doctor: the whisper bounces line says untested if it dies", bounces.startswith("Whisper bounces: untested ("), bounces)
    bazza.lua("Greenfields.Comm.BouncePattern = Greenfields.bounceWas; Greenfields.bounceWas = nil")
    for start in ("Client", "Guild lock: Open", "Addon senders seen", "Sender naming: ", "Repeated first names: none in", "Loot methods the client lists: ",
                  "Restrictions: Chat=off Combat=off Encounter=off Map=off PvPMatch=off ChallengeMode=off", "Meter API: C_DamageMeter has 3", "Loot history API: C_LootHistory has 2",
                  "Guild location (loaded", "Guild location, can change", "Errors captured"):
        check("doctor says: " + start, line(lines, start) is not None, lines)
    check("doctor reads how senders are named", "as Name-Suffix" in line(lines, "Sender naming"), line(lines, "Sender naming"))
    check("doctor reads the loot methods", "Group" in line(lines, "Loot methods") and "Masterlooter" in line(lines, "Loot methods") and "Now: solo" in line(lines, "Loot methods"), line(lines, "Loot methods"))
    check("doctor reads the guild's location", line(lines, "Guild location (loaded").endswith("): true, 0, 3, 0, 0, 30"), line(lines, "Guild location (loaded"))
    check("and who can change it", line(lines, "Guild location, can change").endswith("): false, true"), line(lines, "Guild location, can change"))
    check("the meter answers with both its returns", 'IsDamageMeterAvailable says true, ""' in line(lines, "Meter API"), line(lines, "Meter API"))
    check("the doctor lists the meter's reset but never calls it", "ResetAllCombatSessions" in line(lines, "Meter API") and "must never call" not in line(lines, "Meter API"), line(lines, "Meter API"))
    bazza.lua("Enum.AddOnRestrictionType.Housing = 6")
    got = line(doctor(bazza), "Restrictions")
    check("a restriction type we didn't know about gets asked too", "ChallengeMode=off Housing=off" in got, got)
    bazza.lua("Enum.AddOnRestrictionType.Housing = nil")
    bazza.Game.SetCombat(True)
    lines = doctor(bazza)
    check("doctor sees a restriction come on", "Combat=on" in line(lines, "Restrictions"), line(lines, "Restrictions"))
    bazza.Game.SetCombat(False)
    # a probe that dies says so, and the rest carry on
    n = errors(bazza)
    bazza.lua("local C = Greenfields.Comm; C.peersWas = C.OnlinePeers; C.OnlinePeers = function() error('kaboom') end")
    lines = doctor(bazza)
    check("a dead probe says untested", (line(lines, "Comm") or "").startswith("Comm: untested (") and "kaboom" in line(lines, "Comm"), line(lines, "Comm"))
    check("and the rest still run", line(lines, "Errors captured") is not None and line(lines, "Guild lock") is not None, lines)
    check("and nothing's recorded as an error", errors(bazza) == n)
    bazza.lua("local C = Greenfields.Comm; C.OnlinePeers = C.peersWas; C.peersWas = nil")
    # every probe dying at once
    bazza.lua("Greenfields.apiWas = Greenfields.API.GuildMembers; Greenfields.API.GuildMembers = function() error('no roster') end; "
              "Greenfields.rosterWas = Greenfields.Roster; Greenfields.Roster = nil; Greenfields.storeWas = Greenfields.Store; Greenfields.Store = nil")
    lines = doctor(bazza)
    check("with the roster and store gone: still a full report", line(lines, "Errors captured") is not None
          and "untested" in line(lines, "Roster:") and "untested" in line(lines, "Repeated first names") and errors(bazza) == n, lines)
    bazza.lua("Greenfields.API.GuildMembers = Greenfields.apiWas; Greenfields.Roster = Greenfields.rosterWas; Greenfields.Store = Greenfields.storeWas")
    # things that can't be told apart from "no" unless they say so
    bazza.lua("local R = C_RestrictedActions; R.realCheck = R.IsAddOnRestrictionActive; "
              "R.IsAddOnRestrictionActive = function(k) if k == Enum.AddOnRestrictionType.Map then error('nope') end return R.realCheck(k) end; "
              "Enum.AddOnRestrictionType.PvPMatch = nil")
    got = line(doctor(bazza), "Restrictions")
    check("a restriction that won't answer is untested, not off", "Map=untested" in got and "PvPMatch=untested" in got and "Chat=off" in got, got)
    bazza.lua("local R = C_RestrictedActions; R.IsAddOnRestrictionActive = R.realCheck; R.realCheck = nil; Enum.AddOnRestrictionType.PvPMatch = 4")
    bazza.lua("C_DamageMeter.IsDamageMeterAvailable = function() error('meter says no') end; C_DamageMeter.GetAvailableCombatSessions = function() return { MOCK_NOTHING = 1 } end; C_LootHistory.GetAllEncounterInfos = nil; C_LootHistory.GetLootHistoryTime = nil; C_LootHistory.SomethingElse = function() end")
    lines = doctor(bazza)
    check("a meter call that fails is untested", "IsDamageMeterAvailable untested (" in line(lines, "Meter API") and "meter says no" in line(lines, "Meter API"), line(lines, "Meter API"))
    check("and the others still answer", "GetAvailableCombatSessions says {MOCK_NOTHING=1}" in line(lines, "Meter API"), line(lines, "Meter API"))
    check("no call we know is untested", "SomethingElse" in line(lines, "Loot history API") and "untested" in line(lines, "Loot history API"), line(lines, "Loot history API"))
    bazza.lua("C_DamageMeter = nil; C_LootHistory = nil; C_GuildInfo.GetPreferredPlaySettings = nil")
    lines = doctor(bazza)
    check("no meter table says so", "isn't on this client" in line(lines, "Meter API"), line(lines, "Meter API"))
    check("no location setting says so", "no such setting" in line(lines, "Guild location"), line(lines, "Guild location"))
    bazza.lua("C_GuildInfo.GetPreferredPlaySettings = function() error('not your guild') end")
    got = line(doctor(bazza), "Guild location")
    check("a location call that fails is untested", got.startswith("Guild location: untested") and "not your guild" in got, got)
    bazza.lua("Greenfields.API.ownMembers = Greenfields.API.GuildMembers; Greenfields.API.GuildMembers = function() return "
              "{ { name = 'Davo Smith', key = 'Davo' }, { name = 'Davo Jones', key = 'Davo' }, { name = 'Kylie Ng', key = 'Kylie' } }, 2 end")
    got = line(doctor(bazza), "Repeated first names")
    check("repeated first names get named", "Davo x2 (Davo Smith, Davo Jones)" in got and "Kylie" not in got and "2 rows were hidden" in got, got)
    bazza.lua("Greenfields.API.GuildMembers = function() return {}, 0 end")
    got = line(doctor(bazza), "Repeated first names")
    check("no rows read is untested, not none", got.startswith("Repeated first names: untested"), got)
    bazza.lua("Greenfields.API.GuildMembers = Greenfields.API.ownMembers; Greenfields.API.ownMembers = nil")
    # nobody else heard from: a fresh look at the senders
    bazza.lua("local C = Greenfields.Comm; C.sendersWas = C.senders; C.senders = {}")
    got = line(doctor(bazza), "Sender naming")
    check("no senders seen is untested", got.startswith("Sender naming: untested"), got)
    bazza.lua("local C = Greenfields.Comm; C.senders = C.sendersWas; C.sendersWas = nil")
    bazza.Game.SetSecret("chat", True)
    bazza.Game.SetSecret("names", True)
    bazza.Game.SetSecret("roster", True)
    lines = doctor(bazza)
    check("with names and chat hidden the doctor still finishes", line(lines, "Errors captured") is not None, lines)
    for cat in ("chat", "names", "roster"):
        bazza.Game.SetSecret(cat, False)

    # --- /gf mic ------------------------------------------------------------------------
    slash(bazza, "mic")
    check("mic, solo: says so and sends nothing", said(bazza, "Nobody to test on") == 1 and not party_lines(bazza))
    sim.set_group("party", ["Spencer", "Bazza", "Shazza"], "Spencer")
    sim.advance(1)
    before = spencer.eval_json("Greenfields.Store:Count('loot')")
    slash(bazza, "mic")
    sim.advance(0.2)
    check("mic: one line to the party", len(party_lines(bazza)) == 1 and party_lines(bazza)[0]["chatType"] == "PARTY", party_lines(bazza))
    check("mic: sent in the keypress, not a tick later", bazza.jsonv(bazza.MOCK.chatLog)[-1].get("hw") is True, bazza.jsonv(bazza.MOCK.chatLog)[-1])
    slash(bazza, "mic")
    check("mic: asking again while it's listening sends nothing", len(party_lines(bazza)) == 1 and said(bazza, "Still listening") == 1)
    shazza.lua_hw("RandomRoll(1, 100)")
    sim.advance(0.5)
    got = [str(l) for l in bazza.eval_json("GreenfieldsDB.mic.lines")]
    check("mic: it saw its own line come back, and from whom", "came back" in got[0] and "Bazza-" in got[0] and "key as Bazza" in got[0], got)
    check("mic: it read the roll", got[1].startswith("/roll: read") and "Shazza rolled" in got[1] and "in the group: true" in got[1], got)
    check("mic: the results go to chat", said(bazza, "/roll: read") == 1)
    check("mic: the results go in the report", "/roll: read" in report(bazza))
    # it's done: later rolls and a long wait do nothing more
    n = said(bazza, "Mic check:")
    shazza.lua_hw("RandomRoll(1, 100)")
    sim.advance(65)
    check("mic: it's stopped listening", said(bazza, "Mic check:") == n and len(party_lines(bazza)) == 1)
    check("mic: the group got one line and no rolls from it", not any(m for m in sim.chat_routed if m["from"] == "Bazza" and m["chatType"] != "PARTY"))
    check("mic: the Loot Desk didn't hear about it", bazza.eval_json("Greenfields.Loot:CurrentRoll() == nil") is True and spencer.eval_json("Greenfields.Store:Count('loot')") == before)
    check("mic: not saved anywhere the desk reads", bazza.eval_json("GreenfieldsDB.guilds[Greenfields.gdbKey].mic == nil and GreenfieldsCharDB.mic == nil") is True)
    # nobody rolls
    slash(spencer, "mic")
    sim.advance(61)
    got = [str(l) for l in spencer.eval_json("GreenfieldsDB.mic.lines")]
    check("mic: no roll is untested, not no", got[1].startswith("/roll: untested") and "Nobody rolled" in got[1], got)
    check("mic: the line still came back", "came back" in got[0], got)
    # the game hides the system channel and the group chat
    shazza.Game.SetSecret("chat", True)
    slash(shazza, "mic")
    bazza.lua_hw("RandomRoll(1, 100)")
    sim.advance(61)
    shazza.Game.SetSecret("chat", False)
    got = [str(l) for l in shazza.eval_json("GreenfieldsDB.mic.lines")]
    check("mic: a hidden line can't be claimed", "hid the text" in got[0], got)
    check("mic: a hidden roll is untested", got[1].startswith("/roll: untested") and "hid" in got[1], got)
    # locked down in a boss fight
    n = len(party_lines(bazza))
    bazza.Game.SetChatLockdown(True)
    slash(bazza, "mic")
    sim.advance(61)
    bazza.Game.SetChatLockdown(False)
    got = [str(l) for l in bazza.eval_json("GreenfieldsDB.mic.lines")]
    check("mic: chat lockdown is untested", "not posted (lockdown), so untested" in got[0] and len(party_lines(bazza)) == n, got)
    check("mic: the mock didn't catch it sending anyway", not any("lockdown" in str(f) for f in collect_client_report(bazza)["forbidden"]))
    # the game refuses the send after all
    slash(bazza, "mic")
    bazza.fire("ADDON_ACTION_BLOCKED", "Greenfields", "SendChatMessage()")
    sim.advance(61)
    got = [str(l) for l in bazza.eval_json("GreenfieldsDB.mic.lines")]
    check("mic: a blocked send says so", "blocked" in got[0] and "SendChatMessage" in got[0], got)
    # a roll on at the desk: this would feed it
    bazza.lua("local L = Greenfields.Loot; L.rollWas = L.CurrentRoll; L.CurrentRoll = function() return { done = false } end")
    n = len(party_lines(bazza))
    slash(bazza, "mic")
    check("mic: stays out of a live desk roll", len(party_lines(bazza)) == n and said(bazza, "roll on at the Loot Desk") == 1)
    bazza.lua("local L = Greenfields.Loot; L.CurrentRoll = L.rollWas; L.rollWas = nil")
    # the guild lock
    n = len(party_lines(bazza))
    slash(bazza, "gate test")
    slash(bazza, "mic")
    sim.advance(0.5)
    check("mic, gate shut: nothing goes out", len(party_lines(bazza)) == n)
    check("mic, gate shut: gets the gate", bazza.eval_json("GreenfieldsGate:IsShown()") is True)
    bazza.lua("GreenfieldsGate:Hide()")
    slash(bazza, "report")
    check("/gf report opens with the gate shut", box_up(bazza) and bazza.eval_json("GreenfieldsGate:IsShown()") is False)
    check("and says the gate's shut", "Test mode" in box_text(bazza), box_text(bazza))
    bazza.lua("Greenfields.UI:CloseModal()")
    slash(bazza, "gate test")
    # started, then shut out part way through: it stops hearing things
    slash(bazza, "mic")
    n = len(party_lines(bazza))
    slash(bazza, "gate test")
    shazza.lua_hw("RandomRoll(1, 100)")
    sim.advance(0.5)
    slash(bazza, "gate test")
    bazza.lua("if rawget(_G, 'GreenfieldsGate') then GreenfieldsGate:Hide() end")
    check("mic: shut part way through, it hears nothing", said(bazza, "/roll: read") == 1, said(bazza, "/roll: read"))
    sim.advance(61)
    check("mic: and nothing more goes out", len(party_lines(bazza)) == n)
    for c in sim.clients:
        check("/gf report, doctor and mic never threw on " + c.name, tool_errors(c) == 0, tool_errors(c))
        check("and nothing else was caught throwing on " + c.name, not stray_errors(c), stray_errors(c))
        rep = collect_client_report(c)
        check("no uncaught Lua errors on " + c.name, not rep["errors"], rep["errors"])
        check("no taint on " + c.name, not rep["taint"], rep["taint"])
    sc["time"] = round(time.time() - t0, 1)
    return sim


def scenario_release(res):
    """tools/release.py with every git call and network call faked: the version guard, the stable zip, the
    upload order and the commit message. Nothing here can touch git or GitHub, because the module's own
    subprocess and opener are swapped out before anything runs. A failed check fails the run."""
    sc = res.scenario("release")
    t0 = time.time()

    def check(name, ok, got=None):
        sc["checks"].append({"name": name, "ok": bool(ok), "got": got})
        if not ok:
            sc["status"] = "fail"
            sc["notes"].append(name)
            res.harness_failures.append("release: %s (got %r)" % (name, got))

    path = os.path.join(ROOT, "tools", "release.py")
    spec = importlib.util.spec_from_file_location("gf_release_under_test", path)
    rel = importlib.util.module_from_spec(spec)
    was_dont_write = sys.dont_write_bytecode
    sys.dont_write_bytecode = True
    try:
        spec.loader.exec_module(rel)
    finally:
        sys.dont_write_bytecode = was_dont_write

    class Done:
        def __init__(self, stdout=""):
            self.returncode, self.stdout, self.stderr = 0, stdout, ""

    git_calls = []
    local, remote = [], []
    # the fakes below are the whole safety of this test, so a call that gets past them is stopped dead here
    real_calls = []
    real_run, real_popen = subprocess.run, subprocess.Popen

    def no_real_process(cmd, *a, **k):
        real_calls.append(cmd)
        raise AssertionError("the release test tried to run a real process: %r" % (cmd,))

    subprocess.run, subprocess.Popen = no_real_process, no_real_process

    def fake_run(cmd, **kw):
        git_calls.append(list(cmd))
        if cmd[:2] == ["git", "tag"] and "--list" in cmd:
            return Done("\n".join(local))
        if cmd[:2] == ["git", "ls-remote"]:
            wanted = [c for c in cmd[3:] if c != "origin"]
            lines = ["%040d\trefs/tags/%s" % (i, t) for i, t in enumerate(remote)
                     if not wanted or "refs/tags/" + t in wanted]
            return Done("\n".join(lines))
        if cmd[:2] == ["git", "symbolic-ref"]:
            return Done("main")
        if cmd[:2] == ["git", "rev-parse"] and "--is-inside-work-tree" in cmd:
            return Done("true")
        if cmd[:2] == ["git", "rev-parse"] and "refs/tags/" in " ".join(cmd):
            r = Done()
            r.returncode = 1
            return r
        return Done("")

    class FakeSubprocess:
        run = staticmethod(fake_run)

    class Refused:
        def open(self, *a, **k):
            raise AssertionError("the release test tried to use the network")

    gh = []

    def fake_gh(method, url, token, body=None, data=None, content_type="application/json"):
        gh.append((method, url))
        if method == "GET" and "/releases?" in url:
            return []
        if method == "POST" and url.endswith("/releases"):
            return {"id": 7, "upload_url": rel.UPLOADS + "repos/x/y/releases/7/assets{?name,label}", "assets": []}
        if method == "PATCH":
            return {"html_url": "https://example.invalid/fake"}
        if method == "GET":
            return {"permissions": {"push": True}}
        return {}

    rel.subprocess = FakeSubprocess
    rel._opener = Refused()
    rel.gh_api = fake_gh
    rel.github_token = lambda: "fake-token"

    def stopped(fn, *a):
        """True when `fn` refused (release.py's die() exits with 1)."""
        out, sys.stdout = sys.stdout, open(os.devnull, "w", encoding="utf-8")
        try:
            fn(*a)
            return False
        except SystemExit:
            return True
        finally:
            sys.stdout.close()
            sys.stdout = out

    # --- never at or below the highest tag --------------------------------------------
    tags = ["v1.0.3", "v1.1.0", "v1.1.2", "v1.0.10", "v1.2.0-beta", "oddball"]
    check("the highest tag ignores betas and strays", rel.highest_tag(tags) == (1, 1, 2), rel.highest_tag(tags))
    check("no tags, no objection", not stopped(rel.check_against_tags, "0.0.1", []))
    check("the highest tag compares numbers, not text", rel.highest_tag(["v1.0.9", "v1.0.10"]) == (1, 0, 10), rel.highest_tag(["v1.0.9", "v1.0.10"]))
    for version, rebuild, refuse, why in (
        ("1.1.3", False, False, "a higher patch goes"),
        ("1.2.0", False, False, "a higher minor goes"),
        ("1.1.2", False, True, "the same version is refused"),
        ("1.1.1", False, True, "a lower patch is refused"),
        ("1.0.99", False, True, "a lower minor is refused, whatever the digits look like"),
        ("1.1.2", True, False, "--rebuild can finish the highest tag"),
        ("1.1.1", True, True, "--rebuild can't go below it"),
        ("1.1.3", True, False, "--rebuild above it is fine"),
    ):
        check("tags: " + why, stopped(rel.check_against_tags, version, tags, rebuild) == refuse, (version, rebuild))
    check("numbers compare as numbers: 1.0.10 beats 1.0.9",
          stopped(rel.check_against_tags, "1.0.9", ["v1.0.10"]))

    # main() from the top. Everything past the guard is booby-trapped, so a broken guard can't write a file.
    class Reached(Exception):
        pass

    def trap(*a, **k):
        raise Reached()

    for name in ("release_changelog", "write_changelog_lua", "write_toc_version", "run_checks", "package", "publish"):
        setattr(rel, name, trap)
    argv = sys.argv

    def main_with(*args):
        sys.argv = ["release.py"] + list(args)
        out, sys.stdout = sys.stdout, open(os.devnull, "w", encoding="utf-8")
        try:
            rel.main()
            return "finished"
        except SystemExit:
            return "refused"
        except Reached:
            return "past the guard"
        finally:
            sys.stdout.close()
            sys.stdout = out
            sys.argv = argv

    current = rel.read_toc_version()
    a, b, c = rel.vkey(current)
    above = "%d.%d.%d" % (a + 1, 0, 0)
    far = "%d.0.0" % (a + 5)
    local[:] = ["v" + current]
    got = main_with(above)
    check("main: a version above every tag gets through", got == "past the guard", got)
    local[:] = ["v" + current, "v" + far]
    got = main_with(above)
    check("main: refuses below a local tag, even when it's above the TOC", got == "refused", got)
    got = main_with("--rebuild")
    check("main: --rebuild refuses below a local tag too", got == "refused", got)
    local[:] = ["v" + current]
    got = main_with(far)
    check("main: a far higher version still gets through", got == "past the guard", got)
    check("main: the check reads the local tags", ["git", "tag", "--list"] in git_calls, git_calls[-3:])

    # origin can be ahead of this PC, which is only a publish's business
    remote[:] = ["v" + current, "v" + far]
    check("preflight: refuses below a tag that's only on origin",
          stopped(rel.preflight, above, "owner/repo", False))
    remote[:] = ["v" + current]
    check("preflight: fine once it's above origin's too", not stopped(rel.preflight, above, "owner/repo", False))

    # --- the package ------------------------------------------------------------------
    tmp = tempfile.mkdtemp(prefix="gf_release_")
    source = importlib.util.module_from_spec(spec)
    was_dont_write = sys.dont_write_bytecode
    sys.dont_write_bytecode = True
    try:
        spec.loader.exec_module(source)
    finally:
        sys.dont_write_bytecode = was_dont_write
    # the real package() and publish(), still with this test's fakes around them
    source.subprocess = FakeSubprocess
    source._opener = Refused()
    source.gh_api = fake_gh
    source.github_token = rel.github_token
    source.ROOT = tmp
    try:
        out, sys.stdout = sys.stdout, open(os.devnull, "w", encoding="utf-8")
        try:
            folder, manifest = source.package(current, ["A note."], "owner/repo", None)
        finally:
            sys.stdout.close()
            sys.stdout = out
        versioned = os.path.join(folder, "Greenfields-%s.zip" % current)
        stable = os.path.join(folder, "Greenfields.zip")
        check("package: the stable zip is there", os.path.exists(stable))
        check("package: and it's the same bytes", os.path.exists(stable) and source.read_bytes(stable) == source.read_bytes(versioned))
        check("package: it passes the updater's own rules", not stopped(source.check_addon_zip, stable, current))
        with open(os.path.join(folder, "release.json"), encoding="utf-8") as f:
            flavors = [m["flavor"] for m in json.load(f)["releases"][0]["metadata"]]
        check("release.json: a Forever install and a retail-typed one both match the versioned zip", sorted(flavors) == ["forever", "mainline"], flavors)
        check("the manifest still names the versioned zip", manifest["url"].endswith("Greenfields-%s.zip" % current), manifest["url"])

        # --- publishing, with the network and git faked -----------------------------------
        del gh[:]
        del git_calls[:]
        st = {"token": "fake-token", "branch": "main", "tag": "v" + current, "tag_exists": False, "release": None}
        fake_staged = FakeSubprocess

        class StagedSubprocess(fake_staged):
            @staticmethod
            def run(cmd, **kw):
                if cmd[:3] == ["git", "diff", "--cached"]:
                    git_calls.append(list(cmd))
                    return Done("Greenfields/Greenfields.toc\n")
                return fake_run(cmd, **kw)

        source.subprocess = StagedSubprocess
        out, sys.stdout = sys.stdout, open(os.devnull, "w", encoding="utf-8")
        try:
            source.publish(current, folder, ["A note."], "owner/repo", st, {"staged": False, "committed": False})
        finally:
            sys.stdout.close()
            sys.stdout = out
        uploads = [urllib.parse.parse_qs(urllib.parse.urlparse(u).query)["name"][0] for m, u in gh if m == "POST" and "?name=" in u]
        check("publish: uploads the stable zip", "Greenfields.zip" in uploads, uploads)
        check("publish: and still the versioned one", "Greenfields-%s.zip" % current in uploads, uploads)
        check("publish: the manifest goes up last", uploads and uploads[-1] == "latest.json", uploads)
        check("publish: every file once", len(uploads) == len(set(uploads)) and len(uploads) == 6, uploads)
        order = [m for m, u in gh]
        check("publish: the release only goes live after the uploads", order and order[-1] == "PATCH", order)
        commit = next((c for c in git_calls if c[:2] == ["git", "commit"]), None)
        check("publish: it commits", commit is not None, git_calls)
        if commit:
            parts = [commit[i + 1] for i, x in enumerate(commit) if x == "-m"]
            check("commit: starts with the release line", parts[:1] == ["Release v" + current], parts)
            check("commit: ends with the attribution, in its own paragraph",
                  parts[-1:] == ["Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"] and len(parts) == 2, parts)
        # --- origin moved while we were busy: the push gets refused ------------------------------
        pushes = []

        class RefusedPush(StagedSubprocess):
            @staticmethod
            def run(cmd, **kw):
                if cmd[:2] == ["git", "push"]:
                    pushes.append(list(cmd))
                    # what a real server does: without --atomic the branch fails and the tag still lands
                    if "--atomic" not in cmd:
                        remote.append(st["tag"])
                    r = Done()
                    r.returncode, r.stderr = 1, "! [rejected] main -> main (non-fast-forward)"
                    return r
                return StagedSubprocess.run(cmd, **kw)

        source.subprocess = RefusedPush
        del git_calls[:], gh[:], remote[:]
        st["tag"] = "v" + above
        said = io.StringIO()
        out, sys.stdout = sys.stdout, said
        try:
            source.publish(above, folder, ["A note."], "owner/repo", st, {"staged": False, "committed": False})
            refused = False
        except SystemExit:
            refused = True
        finally:
            sys.stdout = out
        check("push refused: the release stops", refused, said.getvalue())
        check("push refused: nothing's half up on origin", pushes and "--atomic" in pushes[0] and not remote, [pushes, remote])
        check("push refused: nothing goes to GitHub", not gh, gh)
        check("push refused: the local tag's taken back", ["git", "tag", "-d", st["tag"]] in git_calls, git_calls)
        check("push refused: it says what to do next", "Nothing was published" in said.getvalue() and "--rebuild --publish" in said.getvalue(), said.getvalue())
        check("push refused: and doing that gets through", not stopped(rel.preflight, above, "owner/repo", True), remote)
        source.subprocess = FakeSubprocess
        st["tag"] = "v" + current
        remote[:] = ["v" + current]
        # a half-finished release gets its stable zip replaced, not doubled
        del gh[:]
        st["release"] = {"id": 7, "upload_url": rel.UPLOADS + "repos/x/y/releases/7/assets{?name,label}",
                         "assets": [{"name": "Greenfields.zip", "id": 41}, {"name": "latest.json", "id": 42}]}
        st["tag_exists"] = True
        source.subprocess = FakeSubprocess
        out, sys.stdout = sys.stdout, open(os.devnull, "w", encoding="utf-8")
        try:
            source.publish(current, folder, ["A note."], "owner/repo", st, {"staged": False, "committed": False})
        finally:
            sys.stdout.close()
            sys.stdout = out
        deleted = [u.rsplit("/", 1)[-1] for m, u in gh if m == "DELETE"]
        check("resuming replaces the stable zip", "41" in deleted and "42" in deleted, deleted)
        check("resuming pulls the manifest first", gh and gh[0][0] == "DELETE" and gh[0][1].endswith("/42"), gh[:2])
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
        subprocess.run, subprocess.Popen = real_run, real_popen
    check("nothing got past the fake to a real git", not real_calls, real_calls)

    # --- the docs say what the script does --------------------------------------------
    with open(os.path.join(ROOT, "docs", "RELEASING.md"), encoding="utf-8") as f:
        doc = f.read()
    check("RELEASING: never delete", "Never delete a release" in doc)
    check("RELEASING: no advice to delete one", "delete it on GitHub" not in doc)
    check("RELEASING: -Force is the rollback", "-Force" in doc)
    # What's new only shows so many notes per version, and anything past that never reaches a player
    with open(os.path.join(ROOT, "CHANGELOG.md"), encoding="utf-8") as f:
        unreleased = f.read().split("## Unreleased", 1)[1].split("\n## ", 1)[0]
    notes = [l for l in unreleased.splitlines() if l.startswith("- ")]
    check("CHANGELOG: the Unreleased notes all fit in What's new (merge some if not)", len(notes) <= rel.WHATS_NEW_NOTES, len(notes))
    sc["time"] = round(time.time() - t0, 1)


def scenario_upgrades(res):
    """The launch-week small upgrades: /gf install, the books, Your Mob and no repeat jokes. On their own
    clients. A failed check fails the run."""
    sc = res.scenario("upgrades")
    t0 = time.time()

    def check(name, ok, got=None):
        sc["checks"].append({"name": name, "ok": bool(ok), "got": got})
        if not ok:
            sc["status"] = "fail"
            sc["notes"].append(name)
            res.harness_failures.append("upgrades: %s (got %r)" % (name, got))

    sim = Sim(5, "upgrades")
    spencer, bazza, shazza, kev, trish = sim.clients[:5]
    kev.Game.SetGuild("Gooner Gang")
    trish.Game.SetGuild("Greenfields", True)   # a guild name that's slow to turn up, so the gate stays open
    bazza.Game.SetLevel(14)                    # before login: the level the books start watching from
    for c in sim.clients:
        sim.login(c)
    sim.advance(120)

    def slash(c, msg):
        c.lua("SlashCmdList.GREENFIELDS(...)", msg)
        sim.advance(0.2)

    def sent(c):
        return c.eval_json("Greenfields.Comm.stats.sent or 0")

    def modal_up(c):
        return c.eval_json("GreenfieldsModal ~= nil and GreenfieldsModal:IsShown() and true or false")

    def modal_text(c):
        return str(c.eval_json("GreenfieldsModal.dialog.edit:GetText()"))

    def errors(c):
        rep = collect_client_report(c)
        return rep["errors"] + rep["addonErrors"]

    def rescan(c):
        c.fire("GUILD_ROSTER_UPDATE", False)
        sim.advance(1)

    # --- /gf install ------------------------------------------------------------------
    with open(os.path.join(ROOT, "tools", "release_config.json"), encoding="utf-8") as f:
        repo = json.load(f)["repo"]
    base = "https://github.com/%s/releases/latest/download/" % repo
    before = sent(spencer)
    slash(spencer, "install")
    check("install: the box opens", modal_up(spencer))
    post = modal_text(spencer) if modal_up(spencer) else ""
    check("install: the addon link matches the repo release.py publishes to", base + "Greenfields.zip" in post, post)
    check("install: so does the updater's", base + "GreenfieldsUpdater.zip" in post, post)
    check("install: it tells a Mac what to do", "_forever_/Interface/AddOns" in post, post)
    check("install: nothing WoW would read as a code", "|" not in post, post)
    check("install: nothing goes out", sent(spencer) == before, sent(spencer) - before)
    spencer.lua("GreenfieldsModal:Hide()")
    before = sent(kev)
    check("install: this character really is shut", kev.eval_json("Greenfields.gateShut") is True)
    slash(kev, "install")
    check("install: open with the gate shut", modal_up(kev) and base + "Greenfields.zip" in modal_text(kev))
    check("install: not the gate instead", not kev.eval_json("GreenfieldsGate ~= nil and GreenfieldsGate:IsShown() and true or false"))
    check("install: a shut gate sends nothing either", sent(kev) == before, sent(kev) - before)
    kev.lua("GreenfieldsModal:Hide()")
    ui = spencer.UI
    box = ui.CopyBox
    ui.CopyBox = spencer.rt.eval("function() error('box is broken') end")
    prints = len(spencer.jsonv(spencer.MOCK.printLog))
    slash(spencer, "install")
    ui.CopyBox = box
    printed = [str(l) for l in spencer.jsonv(spencer.MOCK.printLog)[prints:]]
    check("install: a broken box still gets the link out", any(base + "Greenfields.zip" in l for l in printed), printed)
    steps = spencer.eval_json("(function() local UI = Greenfields.UI local o, got = UI.Modal UI.Modal = function(_, opts) got = opts end "
                              "Greenfields.Update:ShowHowTo() UI.Modal = o local out = {} for _, b in ipairs(got.blocks) do out[#out + 1] = b.text end return out end)()")
    how = " ".join(str(s) for s in steps)
    check("how-to: manual steps a Mac can use", "/gf install" in how and "_forever_/Interface/AddOns" in how, how)
    with open(os.path.join(ADDON_DIR, "README.md"), encoding="utf-8") as f:
        readme = f.read()
    check("README: the same steps", base + "Greenfields.zip" in readme and "_forever_/Interface/AddOns" in readme)
    check("README: lists the command", "`/gf install`" in readme)

    # --- words that have to stay true ---------------------------------------------------
    unnamed = spencer.eval_json("(function() local out = {} for kind, list in pairs(Greenfields.Flavor.deaths) do for _, l in ipairs(list) do "
                                "if not l:find('{name}', 1, true) then out[#out + 1] = kind .. ': ' .. l end end end return out end)()") or []
    check("roasts: every death line has a {name}, or /gf roast never shows it", not unnamed, unnamed)
    signs = spencer.eval_json("(function() local out = {} for kind, m in pairs(Greenfields.Feed.KINDS) do if m.toast then out[#out + 1] = kind end end "
                              "table.sort(out) return out end)()")
    check("toasts: the setting's list of what pops a sign is still the true one", signs == ["badge", "join", "kill", "level", "prof"], signs)

    # --- the books: dings -------------------------------------------------------------
    def dings(c):
        return c.eval_json("(function() local out = {} for l, t in pairs(Greenfields.cdb.books.dings) do out[tostring(l)] = t end return out end)()")

    def now(c):
        return c.eval_json("Greenfields.API.ServerTime()")

    floor_row = bazza.eval_json("Greenfields.cdb.books.floor")
    check("books: login notes the level we started watching from", floor_row.get("l") == 14 and floor_row.get("t", 0) > 0, floor_row)
    check("books: no invented history", dings(bazza) == {}, dings(bazza))
    t = now(bazza)
    prints = len(bazza.jsonv(bazza.MOCK.printLog))
    bazza.Game.SetLevel(15)
    sim.advance(5)
    check("books: a ding is stamped", dings(bazza).get("15") == t, dings(bazza))
    printed = [str(l) for l in bazza.jsonv(bazza.MOCK.printLog)[prints:]]
    check("books: and nothing's said about it", not printed, printed)
    bazza.fire("PLAYER_LEVEL_UP", 15)
    sim.advance(1)
    check("books: the first time stays", dings(bazza).get("15") == t, dings(bazza))
    t = now(bazza)
    bazza.Game.SetLevel(16, True)
    check("books: a secret level waits for the client to say", "16" not in dings(bazza), dings(bazza))
    sim.advance(5)
    check("books: a secret level's stamped with the moment it happened", dings(bazza).get("16") == t, dings(bazza))
    for odd in (500, 0, 1, -3, 20.5):
        bazza.fire("PLAYER_LEVEL_UP", odd)
    sim.advance(1)
    check("books: nonsense levels aren't rows", sorted(dings(bazza)) == ["15", "16"], dings(bazza))
    check("books: floor doesn't move", bazza.eval_json("Greenfields.cdb.books.floor.l") == 14)
    for lvl in range(2, 110):
        bazza.fire("PLAYER_LEVEL_UP", lvl)
    sim.advance(1)
    check("books: rows are capped", len(dings(bazza)) <= 100 and len(dings(bazza)) >= 59, len(dings(bazza)))
    size = len(bazza.rt.eval("function(M) local s = M.SerializeSV('books', Greenfields.cdb.books) return s end")(bazza.MOCK))
    check("books: a full set of dings stays small", size < 4000, size)
    # a shut gate keeps counting, since dings from before the charter go in are the ones you can't get back
    t = now(kev)
    kev.Game.SetLevel(61)
    sim.advance(1)
    check("books: a ding counts with the gate shut", dings(kev).get("61") == t, dings(kev))
    # junk saved data
    shazza.lua("Greenfields.cdb.books = 'junk'")
    shazza.Game.SetLevel(61)
    sim.advance(1)
    check("books: junk saved data starts over", "61" in dings(shazza), shazza.eval_json("Greenfields.cdb.books"))
    shazza.lua("Greenfields.cdb.books = { dings = 7 }")
    shazza.fire("PLAYER_LEVEL_UP", 62)
    sim.advance(1)
    check("books: junk rows too", "62" in dings(shazza), shazza.eval_json("Greenfields.cdb.books"))

    # --- the books: first seen --------------------------------------------------------
    def seen(c):
        return c.eval_json("(Greenfields.gdb['local'].books or {}).seen or {}")

    def all_seen(c):
        return c.eval_json("(function() local n = 0 for k, g in pairs(GreenfieldsDB.guilds) do "
                           "if type(g['local']) == 'table' and g['local'].books then n = n + 1 end end return n end)()")

    def roster_names(c):
        return [str(n) for n in c.eval_json("(function() local out = {} for _, m in pairs(Greenfields.Roster:All()) do out[#out + 1] = m.name end return out end)()")]

    names = roster_names(spencer)
    got = seen(spencer)
    check("seen: everyone on the roster's noted", names and all(n in got for n in names), [n for n in names if n not in got])
    check("seen: by full name", "Spencer Greenfield" in got, sorted(got)[:3])
    stamped = got.get("Davo Greenfield")
    sim.advance(100)
    rescan(spencer)
    check("seen: the first time stays", seen(spencer).get("Davo Greenfield") == stamped, seen(spencer).get("Davo Greenfield"))
    check("seen: says when the note started", spencer.eval_json("Greenfields.gdb['local'].books.since") == stamped)
    check("seen: another guild's roster isn't written down", all_seen(kev) == 0, kev.eval_json("GreenfieldsDB.guilds"))
    # a name we can't read yet: the gate's open, but it isn't known to be our roster
    check("seen: the slow name really has the gate open", trish.eval_json("Greenfields.gateShut") in (False, None), trish.eval_json("Greenfields.gateShut"))
    rescan(trish)
    check("seen: nothing noted till the guild's name is known", all_seen(trish) == 0, trish.eval_json("GreenfieldsDB.guilds"))
    trish.Game.SetGuild("Greenfields")
    trish.fire("PLAYER_GUILD_UPDATE", "player")
    sim.advance(35)
    rescan(trish)
    check("seen: noted once it is", "Spencer Greenfield" in seen(trish) and all_seen(trish) == 1, all_seen(trish))
    # mid guild change: the partition in use is still the last guild's, so its note can't take this roster
    trish.lua("Greenfields.DB:UseGuild('Stale|Alliance') Greenfields:Fire('GF_ROSTER_UPDATED')")
    check("seen: never into another guild's partition",
          not trish.eval_json("GreenfieldsDB.guilds['Stale|Alliance']['local'].books"), trish.eval_json("GreenfieldsDB.guilds['Stale|Alliance']['local']"))
    trish.lua("Greenfields.DB:UseGuild(Greenfields.DB:GuildKey())")
    # no join events: five at once is a swing the roster won't call joins
    joined = spencer.eval_json("(function() local n = 0 Greenfields:On('GF_MEMBER_JOINED', function() n = n + 1 end) "
                               "Greenfields.harnessJoins = function() return n end return n end)()")
    for i in range(5):
        spencer.Game.AddMember("Recruit%d" % i, "Greenfield", 4, True)
    rescan(spencer)
    check("seen: the roster called none of those joins", spencer.eval_json("Greenfields.harnessJoins()") == joined)
    check("seen: a big swing's still noted", all("Recruit%d Greenfield" % i in seen(spencer) for i in range(5)), len(seen(spencer)))
    # namesakes share a row, and each still gets noted
    spencer.Game.AddMember("Davo", "Larrikin", 4, True)
    rescan(spencer)
    got = seen(spencer)
    check("seen: a namesake gets their own note", "Davo Larrikin" in got and "Davo Greenfield" in got, sorted(got)[:6])
    check("seen: and the first one's time stays", got.get("Davo Greenfield") == stamped, got.get("Davo Greenfield"))
    spencer.lua("local l = Greenfields.gdb['local'].books l.seen, l.count = {}, 0")
    rescan(spencer)
    got = seen(spencer)
    check("seen: a roster that already has both notes both", "Davo Larrikin" in got and "Davo Greenfield" in got, sorted(got)[:6])
    spencer.Game.RemoveMember("Davo", "Larrikin")
    rescan(spencer)
    # the lock: a test gate writes nothing, and it catches up when it opens
    slash(spencer, "gate test")
    spencer.Game.AddMember("Lockedout", "Greenfield", 4, True)
    rescan(spencer)
    check("seen: nothing while the gate's shut", "Lockedout Greenfield" not in seen(spencer))
    slash(spencer, "gate test")
    rescan(spencer)
    check("seen: caught up when it opens", "Lockedout Greenfield" in seen(spencer))
    # the cap
    spencer.lua("Greenfields.gdb['local'].books.count = 1000")
    spencer.Game.AddMember("Overflow", "Greenfield", 4, True)
    rescan(spencer)
    check("seen: capped", "Overflow Greenfield" not in seen(spencer))
    spencer.lua("Greenfields.gdb['local'].books.count = 'junk'; Greenfields.gdb['local'].books.seen = 'junk'")
    rescan(spencer)
    check("seen: junk saved data starts over", "Overflow Greenfield" in seen(spencer), len(seen(spencer)))
    # someone leaves a guild we don't write down and joins ours: the note starts then, under ours
    kev.Game.SetGuild("Greenfields")
    kev.fire("PLAYER_GUILD_UPDATE", "player")
    sim.advance(40)
    rescan(kev)
    check("seen: joining the guild opens the gate", kev.eval_json("Greenfields.gateShut") is False)
    check("seen: starts in our partition", "Spencer Greenfield" in seen(kev) and str(kev.eval_json("Greenfields.gdbKey")).startswith("Greenfields|"),
          kev.eval_json("Greenfields.gdbKey"))
    check("seen: and only there", all_seen(kev) == 1, all_seen(kev))
    # nobody else hears about any of it
    src = open(os.path.join(ADDON_DIR, "Core", "Books.lua"), encoding="utf-8").read()
    code = re.sub(r"--\[\[.*?\]\]|--[^\n]*", "", src, flags=re.S)
    for word in ("Comm", "Store", "Feed", "Print", "Toast", "UI", "SendAddon", "SendChat"):
        check("books: no %s in the code, so nothing's sent or shown" % word, not re.search(r"\b%s\b" % word, code))
    # it all comes back after a reload
    before_dings, before_seen = dings(bazza), seen(spencer)
    back = reload_client(sim, res, bazza, report=False)
    bazza = sim.by_name[back["client"]]
    sim.advance(10)
    check("books: dings survive a reload", dings(bazza) == before_dings, dings(bazza))
    check("books: the floor too", bazza.eval_json("Greenfields.cdb.books.floor.l") == 14)
    back = reload_client(sim, res, spencer, report=False)
    spencer = sim.by_name[back["client"]]
    sim.advance(10)
    got = seen(spencer)
    check("seen: survives a reload", got.get("Davo Greenfield") == before_seen.get("Davo Greenfield") and len(got) >= len(before_seen) - 8, len(got))
    sim.advance(60)

    # --- Your Mob ---------------------------------------------------------------------
    home = "Greenfields.UI.pages.home.frame"

    def who(c):
        c.fire("GUILD_ROSTER_UPDATE", False)
        sim.advance(1)
        c.lua("Greenfields.UI:OpenMain('home')")
        c.lua("Greenfields.UI:ShowPage('home')")
        sim.advance(0.5)
        return [str(k) for k in c.eval_json("(function() local out = {} for _, p in ipairs(%s.people.cells) do if p:IsShown() and p.key then out[#out + 1] = p.key end end return out end)()" % home)]

    m = spencer
    m.Game.SetLevel(14)
    m.Game.SetZone("Elwynn Forest")
    field = m.Game.SetMemberField
    for name, level, zone in (("Tazza", 16, "Elwynn Forest"), ("Jono", 12, "Duskwood"), ("Noddy", 10, "Dun Morogh"),
                              ("Davo", 60, "Elwynn Forest"), ("Jacko", 52, "Feralas"), ("Macca", 19, "Tanaris"),
                              ("Stevo", 15, "Elwynn Forest")):
        field(name, "level", level)
        field(name, "zone", zone)
    field("Stevo", "onApp", True)      # at your level and in your zone on paper, but on the phone
    order = who(m)
    # the sim's other clients and the rest of the 60s are behind these
    want = ["Tazza", "Jono", "Noddy", "Macca", "Davo", "Jacko"]
    check("mob: near your level, then your zone, then closest", order[:6] == want, order)
    check("mob: covers mates without the addon", "Noddy" in order[:3] and not m.eval_json("Greenfields.Comm and Greenfields.Comm.Peers and Greenfields.Comm:Peers()['Noddy'] and true or false"), order[:3])
    check("mob: someone on the app goes last", order[-1] == "Stevo" or "Stevo" not in order, order)
    check("mob: you're not on your own list", "Spencer" not in order, order)
    # a bare-handed fight: levels and zones go secret, and the list holds still
    m.Game.SetSecret("rosterfields", True)
    held = who(m)
    check("mob: secret levels and zones don't reshuffle it", held == order, held)
    check("mob: and they really were secret", m.eval_json("Greenfields.Roster:Get('Tazza').level") == 0, m.eval_json("Greenfields.Roster:Get('Tazza').level"))
    tip = m.eval_json("(function() local p = %s.people.cells[1] p:GetScript('OnEnter')(p) p:GetScript('OnLeave')(p) return 1 end)()" % home)
    check("mob: the tooltip copes", tip == 1, tip)
    m.Game.SetSecret("rosterfields", False)
    # someone who's never seen a level or a zone: no errors, and a sensible order
    sh = shazza
    sh.Game.SetSecret("rosterfields", True)
    sh.lua("Greenfields.UI:OpenMain('home')")
    blind = who(sh)
    check("mob: nothing known still lists people", len(blind) > 3, blind)
    sh.Game.SetSecret("rosterfields", False)
    # your own level hidden: your zone still sorts it
    k = kev
    field2 = k.Game.SetMemberField
    k.Game.SetZone("Wetlands")
    field2("Gazza", "zone", "Wetlands")
    k.rt.eval("function(M) local real = UnitLevel UnitLevel = function(u) if u == 'player' then return M.Secret(14) end return real(u) end end")(k.MOCK)
    hidden = who(k)
    check("mob: your own level hidden, your zone still counts", hidden[:1] == ["Gazza"], hidden[:3])
    # the menu
    cell = "(function() for _, p in ipairs(%s.people.cells) do if p.key == 'Noddy' then return p end end end)()" % home
    m.lua("local p = %s p:GetScript('OnClick')(p, 'RightButton')" % cell)
    sim.advance(0.1)
    items = [str(i) for i in m.eval_json("(function() local out = {} for _, it in ipairs(GreenfieldsMenu.items) do out[#out + 1] = it.text end return out end)()")]
    check("mob: right-click opens the menu", m.eval_json("GreenfieldsMenu:IsShown() and true or false"))
    check("mob: with the whole lot on it", any("Invite" in i for i in items) and any("Whisper" == i for i in items) and any("profile" in i for i in items), items)
    before = len(sim.invites)
    m.lua_hw("for _, it in ipairs(GreenfieldsMenu.items) do if it.text == 'Invite to group' then it.func(it) end end")
    sim.advance(0.5)
    check("mob: invite reaches a mate without the addon, by full name",
          [i["target"] for i in sim.invites[before:]] == ["Noddy Greenfield"], sim.invites[before:])
    m.lua("Greenfields.UI:CloseMenu()")
    m.lua("local p = %s p:GetScript('OnClick')(p, 'LeftButton')" % cell)
    sim.advance(0.1)
    check("mob: left-click still goes to the file, no menu", not m.eval_json("GreenfieldsMenu:IsShown() and true or false"))
    m.lua("Greenfields.UI:ShowPage('home')")
    sim.advance(0.1)

    # --- no repeat jokes --------------------------------------------------------------
    j = bazza
    pick = j.rt.eval("function(list, seed) return Greenfields.Util.Pick(list, seed) end")
    table = j.rt.eval("function(...) return { ... } end")
    lines = ["Joke number %d, which goes on a bit." % i for i in range(1, 8)]
    pile = table(*lines)
    picks = [pick(pile) for _ in range(7 * 40)]
    rounds = [picks[i:i + 7] for i in range(0, len(picks), 7)]
    check("jokes: the whole pile before a repeat", all(sorted(r) == sorted(lines) for r in rounds), rounds[0])
    check("jokes: no same line twice over the join", all(a != b for a, b in zip(picks, picks[1:])))
    check("jokes: each round's in a different order", len({tuple(r) for r in rounds}) > 30, len({tuple(r) for r in rounds}))
    check("jokes: not always the same one first", len({r[0] for r in rounds}) >= 4, len({r[0] for r in rounds}))
    two = table("One of two, mate.", "Two of two, mate.")
    got = [pick(two) for _ in range(40)]
    check("jokes: a pile of two just takes turns", all(a != b for a, b in zip(got, got[1:])), got[:6])
    check("jokes: a pile of one", pick(table("Only joke in town.")) == "Only joke in town.")
    check("jokes: an empty pile's nil", pick(table()) is None and pick(None) is None)
    # the seeded form is arithmetic, and leaves the piles alone
    size = j.eval_json("Greenfields.Util.Count(GreenfieldsDB.piles)")
    place = [j.eval_json("(function() local v = 0 for k, p in pairs(GreenfieldsDB.piles) do v = v + (p.at or 0) + (p.seed or 0) end return v end)()")]
    ok = True
    for seed in list(range(0, 50)) + [3.7, 1000000, 20261104]:
        want = lines[int(seed) % 7]
        ok = ok and pick(pile, seed) == want and pick(pile, seed) == want
    check("jokes: seeded stays predictable", ok)
    fresh_seeded = pick(table("Seeded one.", "Seeded two.", "Seeded three."), 1)
    check("jokes: seeded from a list it's never seen", fresh_seeded == "Seeded two.", fresh_seeded)
    check("jokes: seeded leaves no pile behind", j.eval_json("Greenfields.Util.Count(GreenfieldsDB.piles)") == size)
    place.append(j.eval_json("(function() local v = 0 for k, p in pairs(GreenfieldsDB.piles) do v = v + (p.at or 0) + (p.seed or 0) end return v end)()"))
    check("jokes: seeded doesn't move anyone's place", place[0] == place[1], place)
    # the same lines in a new table are the same pile
    a = [pick(table(*lines)) for _ in range(7)]
    check("jokes: a rebuilt list keeps its place", sorted(a) == sorted(lines), a)
    # lists of tables get through their pile, for the session
    verdicts = j.rt.eval("function() return { {1, 'a'}, {2, 'b'}, {3, 'c'}, {4, 'd'} } end")()
    got = [pick(verdicts)[1] for _ in range(4)]
    check("jokes: a list of tables too", sorted(got) == [1, 2, 3, 4], got)
    # across a reload, which is where the login greeting lives
    r = table(*["Reload joke %d." % i for i in range(1, 8)])
    first = [pick(r) for _ in range(3)]
    back = reload_client(sim, res, j, report=False)
    j = sim.by_name[back["client"]]
    sim.advance(5)
    pick = j.rt.eval("function(list, seed) return Greenfields.Util.Pick(list, seed) end")
    table = j.rt.eval("function(...) return { ... } end")
    rest = [pick(table(*["Reload joke %d." % i for i in range(1, 8)])) for _ in range(4)]
    check("jokes: a reload doesn't start the pile again", sorted(first + rest) == sorted("Reload joke %d." % i for i in range(1, 8)), (first, rest))
    # before the saved data's up, and with junk in it
    j.lua("local db = Greenfields.db Greenfields.db = nil Greenfields.harnessDb = db")
    early = table("Early one.", "Early two.", "Early three.")
    got = [pick(early) for _ in range(3)]
    j.lua("Greenfields.db = Greenfields.harnessDb Greenfields.harnessDb = nil")
    check("jokes: works before the saved data's up", sorted(got) == ["Early one.", "Early three.", "Early two."], got)
    for junk in ("'junk'", "{ ['3:Junk one.'] = 'junk' }"):
        j.lua("GreenfieldsDB.piles = %s" % junk)
        got = pick(table("Junk one.", "Junk two.", "Junk three."))
        check("jokes: junk saved piles: " + junk, got in ("Junk one.", "Junk two.", "Junk three."), got)
    for junk in ("seed = 1.5, at = 1", "seed = 77, at = 0.5"):
        j.lua("GreenfieldsDB.piles = { ['3:Bad one.'] = { %s } }" % junk)
        got = [pick(table("Bad one.", "Bad two.", "Bad three.")) or "nil" for _ in range(3)]
        check("jokes: junk numbers in a pile: " + junk, sorted(got) == ["Bad one.", "Bad three.", "Bad two."], got)
    j.lua("GreenfieldsDB.piles = { ['3:Far one.'] = { seed = 77, at = 900 } }")
    check("jokes: a place past the end starts over", pick(table("Far one.", "Far two.", "Far three.")) is not None)
    # old piles don't pile up
    for i in range(100):
        pick(table("Old pile %d." % i, "Other line."))
    check("jokes: saved piles are capped", j.eval_json("Greenfields.Util.Count(GreenfieldsDB.piles)") <= 64, j.eval_json("Greenfields.Util.Count(GreenfieldsDB.piles)"))

    # the Watch's single-line reports each have a few, and they go through the same pile
    def feed(c, kind):
        return [str(e["text"]) for e in c.eval_json("Greenfields.Feed:Recent(200)") if e["kind"] == kind]

    def lootline(c, item, quality):
        c.MOCK.AddItem(item, "Hot Thing %d" % item, quality, 60, 60, "Armor", "Cloth", 1, "INVTYPE_CLOAK", 133762, 9000, 4, 1, 2, None)
        link = c.MOCK.ItemLink(item)
        c.Game.DeliverChat("CHAT_MSG_LOOT", "You receive loot: %s." % link, c.name)
        sim.advance(1)

    def strip(line):
        return re.sub(r"\|c\w{8}|\|r|\|H[^|]*\|h|\|h", "", line)

    for i in range(4):
        lootline(j, 299100 + i, 4)
    sim.advance(10)
    lines_seen = feed(j, "loot")
    check("watch: epics come in variants", len(lines_seen) == 4 and len({re.sub(r"\[.*?\]", "", strip(l)) for l in lines_seen}) == 4, lines_seen)
    for i in range(3):
        lootline(j, 299200 + i, 5)
    sim.advance(10)
    legends = [l for l in feed(j, "loot") if "LEGENDARY" in l]
    check("watch: legendaries come in variants", len(legends) == 3 and len({re.sub(r"\[.*?\]", "", strip(l)) for l in legends}) == 3, legends)
    # joins and leaves, from whoever's announcing them (the first officer by name, here)
    g = j
    feed_start = {kind: len(feed(g, kind)) for kind in ("join", "leave")}
    for i in range(3):
        g.Game.AddMember("Newbie%d" % i, "Greenfield", 4, True)
        rescan(g)
        sim.advance(60)
    joins = feed(g, "join")
    check("watch: joins come in variants", len(joins) - feed_start["join"] == 3 and len({re.sub(r"Newbie\d", "", strip(l)) for l in joins[:3]}) == 3, joins[:3])
    for i in range(3):
        g.Game.RemoveMember("Newbie%d" % i, "Greenfield")
        rescan(g)
        sim.advance(60)
    leaves = feed(g, "leave")
    check("watch: leaves too", len(leaves) - feed_start["leave"] == 3 and len({re.sub(r"Newbie\d", "", strip(l)) for l in leaves[:3]}) == 3, leaves[:3])
    src = open(os.path.join(ADDON_DIR, "Modules", "Feed.lua"), encoding="utf-8").read()
    for name, mention in (("EPIC_LINES", "{item}"), ("LEGENDARY_LINES", "{item}"), ("JOIN_LINES", "{name}"), ("LEAVE_LINES", "{name}")):
        block = re.search(r"local %s = \{(.*?)\n\}" % name, src, re.S)
        rows = re.findall(r'^\s*"(.*)",\s*$', block.group(1), re.M) if block else []
        check("watch: %s has a few" % name, len(rows) >= 3, len(rows))
        check("watch: %s all name the thing" % name, all(mention in r and "{name}" in r for r in rows), rows)
        check("watch: %s is short" % name, all(len(r) <= 110 for r in rows), [len(r) for r in rows])
        check("watch: %s leaves the old gags out" % name, not re.search(r"(?i)bin chicken|snag|bunnings|drop bear", " ".join(rows)), rows)
    for c in sim.clients:
        check("no Lua errors on " + c.name, not errors(c), errors(c))
        taint = collect_client_report(c)["taint"]
        check("no secret value misused on " + c.name, not taint, taint)
    sc["time"] = round(time.time() - t0, 1)
    return sim


def scenario_misc(sim, res):
    sc = res.scenario("misc")
    t0 = time.time()
    clients = sim.online_clients()
    a = clients[0]
    b = clients[1] if len(clients) > 1 else clients[0]
    for c in clients:
        c.set_scenario("misc")
    # duel
    a.fire("DUEL_REQUESTED", b.name)
    sim.advance(2)
    for c in (a, b):
        c.Game.SystemMessage("%s has defeated %s in a duel" % (a.name, b.name))
        c.fire("DUEL_FINISHED")
    sim.advance(2)
    # AFK flag, falling, swimming, mirror timers, honor, party kill
    a.Game.SetFlag("afk", True)
    a.Game.SystemMessage("You are now AFK: Away from Keyboard")
    sim.advance(5)
    a.Game.SetFlag("afk", False)
    a.Game.SystemMessage("You are no longer AFK.")
    b.fire("MIRROR_TIMER_START", "BREATH", 30000, 60000, -1, False, "Breath")
    sim.advance(2)
    b.fire("MIRROR_TIMER_STOP", "BREATH")
    a.Game.DeliverChat("CHAT_MSG_COMBAT_HONOR_GAIN", "Gazrog dies, honorable kill Rank: Grunt (Estimated Honor Points: 42)", "")
    a.fire("PLAYER_PVP_KILLS_CHANGED")
    a.fire("PARTY_KILL", a.MOCK.world.byName[a.name].guid, "Creature-0-4170-0-12-1748-0000ABCDEF")
    sim.advance(1)
    # fishing loot
    b.Game.OpenLoot(b.rt.execute("return " + to_lua([{"kind": "item", "id": 2589, "count": 2}])),
                    b.rt.execute("return " + to_lua({"fishing": True})))
    sim.advance(1)
    b.lua("LootSlot(1)")
    sim.advance(1)
    b.Game.CloseLoot()
    # falling death
    a.Game.SetFlag("falling", True)
    sim.advance(1)
    a.Game.Die()
    a.Game.SetFlag("falling", False)
    sim.advance(2)
    a.Game.Release()
    sim.advance(1)
    a.Game.Resurrect()
    sim.advance(2)
    # drunk / emote / jump hooks
    a.Game.SystemMessage("You feel tipsy.  Whee!")
    a.MOCK.HardwareCall("DoEmote", a.G.DoEmote, "DANCE")
    a.MOCK.HardwareCall("JumpOrAscendStart", a.G.JumpOrAscendStart)
    sim.advance(1)
    # slash commands
    gf = a.GF
    slash = gf.slash if gf is not None else None
    cmds = []
    if slash is not None:
        cmds = sorted(u8(k) for k in slash.keys())
    handler = a.G.SlashCmdList.GREENFIELDS if a.G.SlashCmdList is not None else None
    ran = []
    # every registered /gf command bare, plus a few with arguments (typed in chat = hardware event)
    extra = ["show loot", "show tradies", "main Spencer", "main", "sr 12345", "help", "bogus-command"]
    for cmd in [""] + cmds + extra:
        if handler is not None:
            a.MOCK.HardwareCall("/gf " + cmd, handler, cmd, a.G.DEFAULT_CHAT_FRAME.editBox)
            ran.append(cmd)
            sim.advance(0.2)
            a.MOCK.HideSpecials(None)
    sc["slash"] = ran
    # compartment + minimap + settings
    for fname, args in (("Greenfields_OnCompartmentClick", (ADDON, "LeftButton")),
                        ("Greenfields_OnCompartmentEnter", (ADDON, a.G.Minimap)),
                        ("Greenfields_OnCompartmentLeave", (ADDON,)),
                        ("Greenfields_OnCompartmentClick", (ADDON, "RightButton"))):
        fn = a.G[fname]
        if fn is None:
            sc["notes"].append("TOC names %s but the global is missing" % fname)
            continue
        a.MOCK.HardwareCall(fname, fn, *args)
        sim.advance(0.3)
    a.MOCK.HideSpecials(None)
    mb = a.G.GreenfieldsMinimapButton
    if mb is not None:
        a.Game.CursorTo(mb)
        a.MOCK.UserEnter(mb)
        a.MOCK.UserLeave(mb)
        a.MOCK.UserClick(mb, "LeftButton")
        sim.advance(0.3)
        a.MOCK.UserClick(mb, "RightButton")
        sim.advance(0.3)
        a.MOCK.HideSpecials(None)
        # drag around the minimap
        a.MOCK.RunScript(mb, "OnDragStart", "LeftButton")
        for (x, y) in ((1800, 900), (1700, 1000), (1650, 950)):
            a.Game.SetCursor(x, y)
            sim.tick()
        a.MOCK.RunScript(mb, "OnDragStop")
    else:
        sc["notes"].append("no GreenfieldsMinimapButton")
    cats = a.MOCK.settingsCategories
    if len(cats) > 0:
        cat = cats[1]
        a.MOCK.HardwareCall("Settings.OpenToCategory", a.G.Settings.OpenToCategory, cat.GetID(cat))
        sim.advance(0.5)
        sp = a.G.SettingsPanel
        if sp is not None:
            boxes = a.MOCK.CollectVisible(sp, "Button,CheckButton")
            for i in range(1, len(boxes) + 1):
                if a.MOCK.IsVisible(boxes[i]):
                    a.MOCK.UserClick(boxes[i], "LeftButton")
                    sim.tick()
                    a.MOCK.HideSpecials(MAIN_FRAME)
            sp.Hide(sp)
    else:
        sc["notes"].append("no Settings category registered")
    # item tooltips (TooltipDataProcessor post-calls) and unit tooltips
    tt = a.G.GameTooltip
    for item in (281001, 279981, 14342):
        tt.SetOwner(tt, a.G.UIParent, "ANCHOR_CURSOR")
        a.MOCK.HarnessCall("SetItemByID", tt.SetItemByID, tt, item)
        tt.Show(tt)
        sim.tick()
        tt.Hide(tt)
    tt.SetOwner(tt, a.G.UIParent, "ANCHOR_CURSOR")
    a.MOCK.HarnessCall("SetUnit", tt.SetUnit, tt, "player")
    tt.Show(tt)
    tt.Hide(tt)
    # combat lockdown while the window is open, then a chat lockdown period
    ui = a.UI
    a.call("OpenMain", ui.OpenMain, ui, "home")
    a.Game.SetCombat(True)
    sim.advance(2)
    a.call("ToggleMain", ui.ToggleMain, ui)
    a.call("ToggleMain", ui.ToggleMain, ui)
    a.Game.SetCombat(False)
    a.Game.SetChatLockdown(True)
    sim.advance(5)
    a.Game.SetChatLockdown(False)
    a.call("ToggleMain", ui.ToggleMain, ui)
    sim.advance(5)
    # a client logs out and back in (SavedVariables round trip)
    sc["reload"] = reload_client(sim, res, clients[-1])
    sc["time"] = round(time.time() - t0, 1)


SELFTEST_SRC = r'''
local ADDON, GF = ...
local f = CreateFrame("Button", nil, UIParent)
f:SetSize(40, 20)
f:SetPoint("CENTER")
f:SetScript("OnClick", function() local t = nil; return t.boom end)              -- handler error
GF:Safe("selftest", function() error("selftest boom") end)                       -- GF:Safe-captured error
local _ = UndefinedSelfTestGlobal                                                -- undefined global read
SelfTestLeak = 1                                                                 -- global leak
pcall(f.RegisterEvent, f, "NOT_A_REAL_EVENT")                                    -- unknown event
pcall(f.RegisterEvent, f, "COMBAT_LOG_EVENT_UNFILTERED")                         -- restricted event
local ok1 = pcall(UnitName)                                                      -- C API type check
local ok2 = pcall(function() f:SetBackdrop({}) end)                             -- method absent without BackdropTemplate
local fs = f:CreateFontString(nil, "OVERLAY")
local ok3 = pcall(fs.SetText, fs, "no font")                                     -- SetText before SetFont
local tex = f:CreateTexture()
tex:SetTexture("Interface\\AddOns\\Greenfields\\Media\\does_not_exist")          -- missing addon media
local label = f:CreateFontString(nil, "OVERLAY")
label:SetFont("Fonts\\FRIZQT__.TTF", 12)
label:SetPoint("TOPLEFT", f, "BOTTOMLEFT", 0, -4)
label:SetPoint("RIGHT", f, "RIGHT")                                              -- inverted rect
label:SetText("x")
GF._selftest = { ok1 = ok1, ok2 = ok2, ok3 = ok3, button = f }
'''


def scenario_selftest(res):
    """Proves the detectors work: loads deliberately broken addon code into a fresh client
    and checks that every problem category is reported."""
    sc = res.scenario("selftest")
    sim = Sim(1, "selftest")
    c = sim.clients[0]
    sim.boot(stagger=0, settle=5)
    c.set_scenario("selftest")
    secret_probe = ("local s = MOCK_SECRET; local ok = pcall(function() return s .. 'x' end); "
                    "local ok2 = pcall(string.find, s, 'a'); return ok, ok2")
    c.MOCK.LoadAddonFile(SELFTEST_SRC, "@Greenfields/__selftest__.lua", ADDON, c.ns)
    st = c.G.Greenfields._selftest
    c.MOCK.UserClick(st.button, "LeftButton")
    c.MOCK.CheckLayout()
    c.G.MOCK_SECRET = c.MOCK.Secret("Bazza")
    taint_before = len(c.MOCK.taint)
    c.MOCK.LoadAddonFile(secret_probe.replace("return ok, ok2", "GF_SECRET_RESULT = { ok, ok2 }"),
                         "@Greenfields/__selftest_secret__.lua", ADDON, c.ns)
    sim.advance(1)
    rep = collect_client_report(c)
    checks = {
        "handler error caught with traceback": any("selftest" in (e.get("label") or "") or "__selftest__" in (e.get("msg") or "") for e in rep["errors"]),
        "GF:Safe error captured": any("selftest boom" in (e.get("err") or "") for e in rep["addonErrors"]),
        "undefined global read": any(g["name"] == "UndefinedSelfTestGlobal" for g in rep["globalReads"]),
        "global leak": any(g["name"] == "SelfTestLeak" for g in rep["leaks"]),
        "unknown event": any(g["name"] == "NOT_A_REAL_EVENT" for g in rep["unknownEvents"]),
        "restricted event": any("COMBAT_LOG_EVENT_UNFILTERED" in (f.get("what") or "") for f in rep["forbidden"]),
        "C API argument check raises": st.ok1 is False,
        "absent widget method raises": st.ok2 is False,
        "SetText before SetFont raises": st.ok3 is False,
        "missing addon texture warned": any("does_not_exist" in (w.get("msg") or "") for w in rep["warnings"]),
        "inverted rect flagged": any("__selftest__" in (l.get("anchoredAt") or "") for l in rep["layoutIssues"]),
        "secret misuse logged": len(c.MOCK.taint) > taint_before,
    }
    sc["checks"] = [{"check": k, "ok": bool(v)} for k, v in checks.items()]
    failed = [k for k, v in checks.items() if not v]
    if failed:
        sc["status"] = "FAILED"
        sc["notes"].append("detectors that did not fire: " + ", ".join(failed))
        res.harness_failures.append("selftest: " + ", ".join(failed))
    return sim


def reload_client(sim, res, c, report=True):
    """Serializes the client's SavedVariables, logs it out (PLAYER_LOGOUT), builds a fresh
    runtime for the same character, restores the SV and logs back in."""
    c.fire("PLAYER_LOGOUT")
    sv = {}
    for n in ("GreenfieldsDB", "GreenfieldsCharDB"):
        s = c.rt.eval("function(M, n) local s, p = M.SerializeSV(n, rawget(_G, n)) return s end")(c.MOCK, n)
        sv[n] = s
    if report:
        res.clients["%s/%s(before reload)" % (sim.label, c.name)] = collect_client_report(c)
    idx = sim.clients.index(c)
    toc_files, toc_meta = read_toc()
    spells, items = scan_buff_data()
    defs, world, members = build_world(len(sim.clients))
    nc = Client(sim, c.d, world, members, toc_files, toc_meta, load_font_metrics(), spells, items,
                (zlib.crc32(c.name.encode()) & 0x7fffffff) or 1)
    nc.MOCK.SetClock(int(sim.epoch), sim.uptime)
    for n, s in sv.items():
        nc.lua(s)          # the client runs the SavedVariables file before ADDON_LOADED
    sim.clients[idx] = nc
    sim.by_name[nc.name] = nc
    for o in sim.online_clients():
        o.Game.SetMemberOnline(nc.name, True, nc.d["zone"])
    sim.login(nc)
    sim.advance(30)
    restored = nc.eval_json("{ guilds = (function() local n = 0 for _ in pairs(GreenfieldsDB.guilds or {}) do n = n + 1 end return n end)(),"
                            " lastPage = GreenfieldsDB.ui and GreenfieldsDB.ui.lastPage }")
    return {"client": nc.name, "svBytes": {k: len(v) for k, v in sv.items()}, "restored": restored}


# ---------------------------------------------------------------------------
# Report building
# ---------------------------------------------------------------------------
KNOWN_ABSENT = {  # real WoW globals that Forever does not have (FACTS R1 & friends): probing them is expected
    "GetItemInfo", "GetItemInfoInstant", "GetItemCount", "GetItemCooldown", "GetItemSpell", "GetSpellInfo",
    "GetSpellTexture", "GetSpellCooldown", "GetSpellLink", "UnitAura", "UnitBuff", "UnitDebuff", "GetTalentInfo",
    "GetNumTalentTabs", "GetTalentTabInfo", "GetNumSkillLines", "GetSkillLineInfo", "SendChatMessage",
    "SendAddonMessage", "RegisterAddonMessagePrefix", "GetAddOnMetadata", "InviteUnit", "ConvertToRaid",
    "GuildRoster", "CombatLogGetCurrentEventInfo", "GetLootMethod", "GiveMasterLoot", "GetMasterLootCandidate",
    "ChatFrame_SendTell", "ChatFrame_OpenChat", "ChatFrame_AddMessageEventFilter", "GetCoinTextureString",
    "UIDropDownMenu_Initialize", "EasyMenu", "GetGuildRosterMOTD", "CanEditOfficerNote", "IsEveryoneAssistant",
    "GetSavedInstanceInfo", "GetNumSavedInstances", "RequestRaidInfo", "UnitHonor", "GetPVPRankInfo",
    "UnitPVPRank", "GetHonorInfo", "SetLootMethod", "IsAddOnLoaded", "LoadAddOn", "GetClassColor", "GetMouseFocus",
    "InterfaceOptions_AddCategory", "GetNumTradeSkills", "GetTradeSkillInfo", "GetTradeSkillCooldown",
    "GetNumCrafts", "GetCraftInfo", "UnitIsTapDenied", "ProfessionsFrame", "TradeSkillFrame", "RaidWarningFrame",
}
NOT_DEFINED_BY_CLIENT = {"GetMinimapShape"}
KNOWN_WOW = {  # real retail-shaped globals the mock may lack (a hit means: extend the mock)
    "C_Map", "C_PvP", "C_Club", "C_Calendar", "C_TooltipInfo", "C_LootHistory", "C_ClassTalents", "C_Traits",
    "C_SpecializationInfo", "C_SkillInfo", "C_CurrencyInfo", "C_Housing", "C_DamageMeter", "MenuUtil",
    "CreateDataProvider", "ScrollUtil", "CreateScrollBoxListLinearView", "EventRegistry", "UIFrameFadeIn",
    "UIFrameFadeOut", "GetMouseFoci", "C_KeyBindings", "GetCVar", "SetCVar", "C_CVar", "UnitPosition",
    "C_Minimap", "GetPlayerFacing", "UnitThreatSituation", "GetTotemInfo", "C_StableInfo", "GetCompanionInfo",
    "C_MountJournal", "C_Reputation", "GetFactionInfo", "GetQuestLogTitle", "C_QuestLog", "C_GossipInfo",
    "C_FriendList", "BNGetInfo", "C_BattleNet", "C_PlayerInfo", "C_LFGList", "PlaySoundKitID",
}


SAVED_VARIABLES = {"GreenfieldsDB", "GreenfieldsCharDB"}
LOAD_ON_DEMAND = {"ProfessionsFrame", "TradeSkillFrame", "RaidWarningFrame"}


def classify_global(name):
    if name in SAVED_VARIABLES:
        return "SavedVariables (nil until first saved; expected)"
    if name in LOAD_ON_DEMAND:
        return "load-on-demand Blizzard frame (nil until loaded; expected)"
    if name in NOT_DEFINED_BY_CLIENT:
        return "not defined by the client (expected nil)"
    if name in KNOWN_ABSENT:
        return "absent on Forever (expected; probe is fine)"
    if name in KNOWN_WOW:
        return "real WoW API missing from the mock"
    if name.startswith("C_") or re.match(r"^(Get|Set|Is|Can|Has|Unit|Create|Enable|Disable)[A-Z]", name):
        return "WoW-API-shaped, not in mock (check)"
    if re.match(r"^[a-z_]", name):
        return "probable addon typo / missing local"
    return "unknown global (probable typo)"


def collect_client_report(c):
    rep = c.jsonv(c.MOCK.Report())
    rep["harnessErrors"] = list(getattr(c, "harness_errors", []))
    for g in rep.get("globalReads", []):
        g["class"] = classify_global(g["name"])
    for g in rep.get("rawgetMisses", []):
        g["class"] = classify_global(g["name"])
    rep["leaks"] = [w for w in rep.get("globalWrites", []) if not w.get("allowed")]
    rep["namedLeaks"] = [w for w in rep.get("namedGlobals", []) if not w.get("allowed")]
    return rep


def first_line(s):
    return (s or "").split("\n", 1)[0]


def dedupe_problems(results):
    probs = {}
    for key, rep in results.clients.items():
        cname = key
        for e in rep.get("errors", []):
            k = ("harness-caught", first_line(e.get("msg")))
            p = probs.setdefault(k, {"kind": "harness-caught handler error", "msg": first_line(e.get("msg")),
                                     "label": e.get("label"), "origin": e.get("origin"), "count": 0, "clients": [],
                                     "scenarios": [], "trace": e.get("trace")})
            p["count"] += e.get("count", 1)
            if cname not in p["clients"]:
                p["clients"].append(cname)
            sc = e.get("scenario")
            if sc and sc not in p["scenarios"]:
                p["scenarios"].append(sc)
        for e in rep.get("addonErrors", []):
            msg = first_line(e.get("err"))
            k = ("addon-captured", msg)
            p = probs.setdefault(k, {"kind": "addon-captured (GF:Safe)", "msg": msg, "label": e.get("label"),
                                     "count": 0, "clients": [], "trace": "\n".join((e.get("err") or "").split("\n")[1:8])})
            p["count"] += 1
            if cname not in p["clients"]:
                p["clients"].append(cname)
        for t in rep.get("taint", []):
            k = ("taint", t.get("op"), t.get("where"))
            p = probs.setdefault(k, {"kind": "secret-value misuse", "msg": "%s at %s" % (t.get("op"), t.get("where")),
                                     "severity": t.get("severity"), "count": 0, "clients": [], "trace": t.get("trace")})
            p["count"] += t.get("count", 1)
            if cname not in p["clients"]:
                p["clients"].append(cname)
        for w in rep.get("warnings", []):
            k = ("warning", w.get("kind"), w.get("msg"), w.get("where"))
            p = probs.setdefault(k, {"kind": "mock warning (%s)" % w.get("kind"), "msg": "%s at %s" % (w.get("msg"), w.get("where")),
                                     "count": 0, "clients": []})
            p["count"] += w.get("count", 1)
            if cname not in p["clients"]:
                p["clients"].append(cname)
        for f in rep.get("forbidden", []):
            k = ("forbidden", f.get("what"), f.get("where"))
            p = probs.setdefault(k, {"kind": "forbidden/protected action", "msg": "%s at %s" % (f.get("what"), f.get("where")),
                                     "count": 0, "clients": []})
            p["count"] += 1
            if cname not in p["clients"]:
                p["clients"].append(cname)
        for src, kindname in (("globalReads", "undefined global read"), ("rawgetMisses", "rawget(_G) probe miss")):
            for g in rep.get(src, []):
                if "expected" in (g.get("class") or ""):
                    continue
                k = ("global", g["name"])
                p = probs.setdefault(k, {"kind": kindname, "msg": "%s at %s [%s]" % (g["name"], g.get("where"), g.get("class")),
                                         "count": 0, "clients": []})
                p["count"] += g.get("count", 1)
                if cname not in p["clients"]:
                    p["clients"].append(cname)
        for li in rep.get("layoutIssues", []):
            k = ("layout", li.get("anchoredAt") or li.get("where"), li.get("anchors"))
            if li.get("overflow") is not None:
                kindname = "layout: text overflow"
                msg = "text spills %spx past its %spx parent: anchored at %s (created %s) text=%r" % (
                    li.get("overflow"), li.get("parentW"), li.get("anchoredAt"), li.get("where"), li.get("text"))
            else:
                kindname = "layout: inverted rect"
                msg = "%s anchored at %s (created %s), anchors %s -> size %sx%s%s" % (
                    li.get("otype"), li.get("anchoredAt"), li.get("where"), li.get("anchors"), li.get("w"), li.get("h"),
                    (" text=%r" % li["text"]) if li.get("text") else "")
            p = probs.setdefault(k, {"kind": kindname, "msg": msg,
                "count": 0, "clients": [], "scenarios": [li.get("scenario")]})
            p["count"] += li.get("count", 1)
            if cname not in p["clients"]:
                p["clients"].append(cname)
        for g in rep.get("leaks", []):
            k = ("leak", g["name"])
            p = probs.setdefault(k, {"kind": "global leak", "msg": "%s written at %s" % (g["name"], g.get("where")),
                                     "count": 0, "clients": []})
            p["count"] += g.get("count", 1)
            if cname not in p["clients"]:
                p["clients"].append(cname)
        for g in rep.get("namedLeaks", []):
            k = ("namedleak", g["name"])
            p = probs.setdefault(k, {"kind": "named frame outside the Greenfields prefix", "msg": "%s (%s) at %s" % (g["name"], g.get("type"), g.get("where")),
                                     "count": 0, "clients": []})
            p["count"] += 1
            if cname not in p["clients"]:
                p["clients"].append(cname)
        for g in rep.get("unknownEvents", []):
            k = ("event", g["name"])
            p = probs.setdefault(k, {"kind": "unknown event registered", "msg": "%s at %s" % (g["name"], g.get("where")),
                                     "count": 0, "clients": []})
            p["count"] += g.get("count", 1)
            if cname not in p["clients"]:
                p["clients"].append(cname)
        tm = rep.get("timers") or {}
        if (tm.get("max") or 0) > 50:
            top = ", ".join("%s x%d" % (t["where"], t["live"]) for t in (tm.get("peakBy") or [])[:6])
            k = ("timers",)
            p = probs.setdefault(k, {"kind": "timer budget (FACTS G18: <= 50 live C_Timer handles)",
                                     "msg": "peak %d live timers (%s); at peak: %s" % (tm.get("max"), tm.get("peakAt"), top),
                                     "count": 0, "clients": []})
            p["count"] += 1
            if cname not in p["clients"]:
                p["clients"].append(cname)
        for n, sv in (rep.get("sv") or {}).items():
            for pr in sv.get("problems", []):
                k = ("sv", n, pr)
                p = probs.setdefault(k, {"kind": "SavedVariables problem", "msg": "%s: %s" % (n, pr), "count": 0, "clients": []})
                p["count"] += 1
                if cname not in p["clients"]:
                    p["clients"].append(cname)
    order = {"harness-caught handler error": 0, "addon-captured (GF:Safe)": 1, "secret-value misuse": 2,
             "forbidden/protected action": 3, "undefined global read": 4, "rawget(_G) probe miss": 5, "global leak": 6,
             "named frame outside the Greenfields prefix": 7, "unknown event registered": 8, "SavedVariables problem": 9,
             "layout: inverted rect": 10}
    return sorted(probs.values(), key=lambda p: (order.get(p["kind"], 20), -p["count"], p["msg"]))


def run_renders(res, out_dir):
    if not res.renders:
        return []
    manifest = os.path.join(out_dir, "render_jobs.json")
    with open(manifest, "w", encoding="utf-8") as fh:
        json.dump({"jobs": res.renders, "media": os.path.join(ADDON_DIR, "Media"), "ss": 2}, fh, indent=1)
    py = SYSTEM_PYTHON if os.path.exists(SYSTEM_PYTHON) else "python"
    t0 = time.time()
    proc = subprocess.run([py, "-I", os.path.join(HERE, "render.py"), "--batch", manifest],
                          capture_output=True, text=True, encoding="utf-8", errors="replace")
    log("  render.py: %d jobs in %.1fs (exit %d)" % (len(res.renders), time.time() - t0, proc.returncode))
    out = (proc.stdout or "").strip().splitlines()
    for line in out[-5:]:
        vlog(line)
    if proc.returncode != 0:
        log(proc.stderr[-3000:])
        res.harness_failures.append("render.py failed (exit %d)" % proc.returncode)
    return out


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
def main(argv):
    global VERBOSE
    ap = argparse.ArgumentParser(description="Greenfields multi-client headless harness")
    ap.add_argument("--scenario", default="all", help="all | selftest,boot,pages,raid,secrets,misc,gate,whispers,clash,forever,doctor,rules,release,upgrades")
    ap.add_argument("--clients", type=int, default=3)
    ap.add_argument("--render", metavar="OUTDIR", default=None)
    ap.add_argument("--json", metavar="REPORT", default=None)
    ap.add_argument("--verbose", action="store_true")
    ap.add_argument("--no-sizes", action="store_true", help="skip the min/max window size passes")
    ap.add_argument("--addon", metavar="DIR", default=None, help="addon folder to load (default: <workspace>/Greenfields)")
    args = ap.parse_args(argv)
    VERBOSE = args.verbose
    if args.addon:
        global ADDON_DIR
        ADDON_DIR = os.path.abspath(args.addon)
    wanted = [s.strip() for s in args.scenario.split(",") if s.strip()]
    if "all" in wanted:
        wanted = ["selftest", "boot", "pages", "raid", "misc", "secrets", "gate", "whispers", "clash", "forever", "doctor", "rules", "release", "upgrades"]
    valid = {"selftest", "boot", "pages", "raid", "secrets", "misc", "gate", "whispers", "clash", "forever", "doctor", "rules", "release", "upgrades"}
    bad = [s for s in wanted if s not in valid]
    if bad:
        ap.error("unknown scenario(s): %s" % ", ".join(bad))
    if args.render:
        os.makedirs(args.render, exist_ok=True)
    n = max(1, args.clients)
    res = Results()
    t_start = time.time()
    sims = []
    try:
        if "selftest" in wanted:
            log("== selftest (detectors)")
            scenario_selftest(res)       # its deliberate errors stay out of the client reports
        main_needed = any(s in wanted for s in ("boot", "pages", "raid", "misc"))
        if main_needed:
            log("== building %d clients" % n)
            sim = Sim(n, "main")
            sims.append(sim)
            log("== boot")
            scenario_boot(sim, res, verify="boot" in wanted)
            if "boot" not in wanted:
                res.scenarios.pop("boot", None)
            if "pages" in wanted:
                log("== pages")
                scenario_pages(sim, res, args.render, sizes=not args.no_sizes)
            if "raid" in wanted:
                log("== raid")
                scenario_raid(sim, res)
                if "pages" in wanted:
                    log("== pages again, with raid data (host renders as <client>-<page>-data.png)")
                    scenario_pages(sim, res, args.render, sizes=False, name="pages-after-raid",
                                   render_clients=[sim.clients[0].name], suffix="-data")
            if "misc" in wanted:
                log("== misc")
                scenario_misc(sim, res)
        if "secrets" in wanted:
            log("== secrets (fresh clients, secret values on)")
            sims.append(scenario_secrets(res, n))
        if "gate" in wanted:
            log("== gate (the guild lock)")
            sims.append(scenario_gate(res, args.render))
        if "whispers" in wanted:
            log("== whispers")
            scenario_whispers(res)
        if "clash" in wanted:
            log("== clash (two people, one first name)")
            scenario_clash(res)
        if "forever" in wanted:
            log("== forever (telling the client apart)")
            scenario_forever(res)
        if "doctor" in wanted:
            log("== doctor (Black Box, /gf report, /gf doctor, /gf mic)")
            scenario_doctor(res)
        if "rules" in wanted:
            log("== rules (emotes, deaths, the week, crowns, parties, wealth, first login)")
            scenario_rules(res)
        if "release" in wanted:
            log("== release (tools/release.py, with git and the network faked)")
            scenario_release(res)
        if "upgrades" in wanted:
            log("== upgrades (/gf install, the books, Your Mob, no repeat jokes)")
            scenario_upgrades(res)
    except Exception:
        tb = traceback.format_exc()
        res.harness_failures.append(tb)
        log(tb)
    for sim in sims:
        for c in sim.clients:
            try:
                res.clients["%s/%s" % (sim.label, c.name)] = collect_client_report(c)
            except Exception:
                res.harness_failures.append("report %s/%s: %s" % (sim.label, c.name, traceback.format_exc()))
    # A whisper to a bare first name never arrives on the real client, so the addon must never send one.
    # Nobody's proven the same of invites, but bare ones have reached the wrong person. This goes over every
    # Sim any scenario built, not just the ones in the client reports.
    for sim in Sim.made:
        for b in sim.bounced:
            if b["bare"] and not b["onPurpose"]:
                res.harness_failures.append("%s: %s whispered a bare name: %r" % (sim.label, b["from"], b))
        for inv in sim.invites:
            if " " not in inv["target"] and not inv.get("onPurpose"):
                res.harness_failures.append("%s: %s invited a bare name: %r" % (sim.label, inv["from"], inv))
    # secrets: any Lua error there fails the scenario
    if "secrets" in res.scenarios:
        n_err = sum(len(r.get("errors", [])) + len(r.get("addonErrors", [])) for k, r in res.clients.items() if k.startswith("secrets/"))
        sc = res.scenarios["secrets"]
        sc["luaErrors"] = n_err
        if n_err:
            sc["status"] = "errors"
    if args.render and res.renders:
        log("== render (%d images)" % len(res.renders))
        run_renders(res, args.render)
    problems = dedupe_problems(res)
    comm = {}
    for sim in sims:
        comm[sim.label] = {"total": sim.comm, "byClient": sim.comm_by_client, "invites": sim.invites,
                           "whispered": sim.whispered, "bounced": sim.bounced}
    total_errors = sum(len(r.get("errors", [])) + len(r.get("addonErrors", [])) for r in res.clients.values())
    harness_errs = sum(len(r.get("harnessErrors", [])) for r in res.clients.values())
    mock_bugs = sum(1 for r in res.clients.values() for e in r.get("errors", []) if e.get("origin") == "mock")
    report = {
        "meta": {"clients": n, "scenarios": wanted, "seconds": round(time.time() - t_start, 1),
                 "luaErrors": total_errors, "harnessErrors": harness_errs, "mockOriginErrors": mock_bugs,
                 "coordinateSystem": "scene JSON: screen px, origin top-left, y down"},
        "scenarios": res.scenarios, "problems": problems, "comm": comm, "clients": res.clients,
        "renders": res.renders, "harnessFailures": res.harness_failures,
    }
    if args.json:
        os.makedirs(os.path.dirname(os.path.abspath(args.json)), exist_ok=True)
        with open(args.json, "w", encoding="utf-8") as fh:
            json.dump(report, fh, indent=1, sort_keys=False, default=str)
    # console summary
    log("")
    log("== summary (%.1fs)" % report["meta"]["seconds"])
    for name, sc in res.scenarios.items():
        notes = "; ".join(sc.get("notes", [])[:3])
        log("  %-8s %-10s %s" % (name, sc.get("status"), notes))
    for key, rep in res.clients.items():
        cs = rep.get("commStats") or {}
        log("  %-28s errors=%d addonErrors=%d taint=%d leaks=%d chat=%d sv=%dB/%dB sent=%s" % (
            key, len(rep.get("errors", [])), len(rep.get("addonErrors", [])), len(rep.get("taint", [])),
            len(rep.get("leaks", [])), len(rep.get("chatLog", [])),
            (rep.get("sv") or {}).get("GreenfieldsDB", {}).get("bytes", 0),
            (rep.get("sv") or {}).get("GreenfieldsCharDB", {}).get("bytes", 0), cs.get("sent")))
    log("  problems (deduplicated): %d" % len(problems))
    for p in problems[:40]:
        log("   - [%s] x%d %s" % (p["kind"], p["count"], p["msg"][:220]))
    if res.harness_failures:
        log("  HARNESS FAILURES: %d" % len(res.harness_failures))
    failed = total_errors > 0 or bool(res.harness_failures) or harness_errs > 0
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
