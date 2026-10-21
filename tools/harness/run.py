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
import hashlib
import json
import os
import re
import subprocess
import sys
import time
import traceback
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
        self.ticks = 0

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

    def comm_note(self, sender, channel, text):
        # reassemble to count logical messages per op
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

    def route_addon(self, sender, prefix, text, chat_type, target, logged):
        self.comm_note(sender, chat_type, text)
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
            t = (target or "").split("-")[0]
            c = self.by_name.get(t)
            if c and c.online:
                recips.append(c)
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
                t = (target or "").split("-")[0]
                tc = self.by_name.get(t)
                if tc and tc.online:
                    self.chat_to([tc], "CHAT_MSG_WHISPER", text, c.name)
                    self.chat_to([c], "CHAT_MSG_WHISPER_INFORM", text, t)
                elif t in self.world and t not in self.by_name:
                    self.chat_to([c], "CHAT_MSG_WHISPER_INFORM", text, t)
                else:
                    self.chat_to([c], "CHAT_MSG_SYSTEM", "No player named '%s' is currently playing." % t, "")
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
            self.invites.append({"from": c.name, "target": u8(r.target)})
            t = self.by_name.get((u8(r.target) or "").split("-")[0])
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
        for cat in ("names", "guids", "roster", "auras", "chat", "encounter", "spell"):
            c.Game.SetSecret(cat, True)
    raid_sequence(sim, res, "secrets")
    scenario_pages(sim, res, None, sizes=False, name="secrets-ui", clients=sim.clients[:1], combat=True, arg_key="Shazza")
    sc = res.scenario("secrets")
    sc["time"] = round(time.time() - t0, 1)
    sc["categories"] = ["names", "guids", "roster", "auras", "chat", "encounter", "spell"]
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


def reload_client(sim, res, c):
    """Serializes the client's SavedVariables, logs it out (PLAYER_LOGOUT), builds a fresh
    runtime for the same character, restores the SV and logs back in."""
    c.fire("PLAYER_LOGOUT")
    sv = {}
    for n in ("GreenfieldsDB", "GreenfieldsCharDB"):
        s = c.rt.eval("function(M, n) local s, p = M.SerializeSV(n, rawget(_G, n)) return s end")(c.MOCK, n)
        sv[n] = s
    rep = collect_client_report(c)
    res.clients["%s/%s(before reload)" % (sim.label, c.name)] = rep
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
    "UnitPVPRank", "GetHonorInfo", "IsAddOnLoaded", "LoadAddOn", "GetClassColor", "GetMouseFocus",
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
    ap.add_argument("--scenario", default="all", help="all | selftest,boot,pages,raid,secrets,misc")
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
        wanted = ["selftest", "boot", "pages", "raid", "misc", "secrets"]
    valid = {"selftest", "boot", "pages", "raid", "secrets", "misc"}
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
        comm[sim.label] = {"total": sim.comm, "byClient": sim.comm_by_client, "invites": sim.invites}
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
