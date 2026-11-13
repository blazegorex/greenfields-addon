"""The Most Wanted art: mugshots for every Alliance race, class and sex, plus the poster's lettering
and its rubber stamps. Writes Greenfields/Media/art/wanted_*.tga and Greenfields/Data/WantedArt.lua.

    python -P tools/wanted_art.py                 build the game files from tools/art/wanted/
    python -P tools/wanted_art.py --cut <dir>     cut fresh sheets (<dir>/<sheet>.png) into portraits first

The mugshots were painted with Scenario (GPT Image 2.5) in Nov 2026 as 2x2 sheets of 1024 px, laid out
as SHEETS says, then cut, shrunk to 128 px and held to a 64-colour palette here so they sit with the
pixel-art portraits. tools/art/wanted/portraits/ is the source of truth from then on; the raw sheets
aren't kept in the repo.
"""
import os
import sys

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import make_media  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "tools", "art", "wanted")
PORTRAITS = os.path.join(SRC, "portraits")
MEDIA = os.path.join(ROOT, "Greenfields", "Media")
LUA = os.path.join(ROOT, "Greenfields", "Data", "WantedArt.lua")
GAME = "Interface\\\\AddOns\\\\Greenfields\\\\Media\\\\art\\\\"
FONTS = r"C:\Windows\Fonts"

CELL = 128      # one mugshot, in texels
ATLAS = 512     # 4 x 4 mugshots a sheet

# Each sheet is a 2x2 grid: top-left, top-right, bottom-left, bottom-right. Keys are race_class_sex.
SHEETS = [
    ("human_a", ["human_warrior_m", "human_warrior_f", "human_paladin_m", "human_paladin_f"]),
    ("human_b", ["human_rogue_m", "human_rogue_f", "human_priest_m", "human_priest_f"]),
    ("human_c", ["human_mage_m", "human_mage_f", "human_warlock_m", "human_warlock_f"]),
    ("mix_a", ["human_hunter_m", "human_hunter_f", "dwarf_warrior_m", "dwarf_warrior_f"]),
    ("dwarf_a", ["dwarf_paladin_m", "dwarf_paladin_f", "dwarf_hunter_m", "dwarf_hunter_f"]),
    ("dwarf_b", ["dwarf_rogue_m", "dwarf_rogue_f", "dwarf_priest_m", "dwarf_priest_f"]),
    ("mix_b", ["dwarf_shaman_m", "dwarf_shaman_f", "nightelf_warrior_m", "nightelf_warrior_f"]),
    ("nelf_a", ["nightelf_hunter_m", "nightelf_hunter_f", "nightelf_rogue_m", "nightelf_rogue_f"]),
    ("nelf_b", ["nightelf_priest_m", "nightelf_priest_f", "nightelf_druid_m", "nightelf_druid_f"]),
    ("gnome_a", ["gnome_warrior_m", "gnome_warrior_f", "gnome_rogue_m", "gnome_rogue_f"]),
    ("gnome_b", ["gnome_mage_m", "gnome_mage_f", "gnome_warlock_m", "gnome_warlock_f"]),
    ("mix_c", ["gnome_priest_m", "gnome_priest_f", "skyborne_warrior_m", "skyborne_warrior_f"]),
    ("sky_a", ["skyborne_hunter_m", "skyborne_hunter_f", "skyborne_rogue_m", "skyborne_rogue_f"]),
    ("sky_b", ["skyborne_druid_m", "skyborne_druid_f", "skyborne_mage_m", "skyborne_mage_f"]),
    ("unknown", ["unknown_m", "unknown_f", "unknown_sack", "unknown_mask"]),
]

# which atlas each race lives on (at most 16 mugshots a sheet)
ATLASES = ["human", "dwarf", "nightelf", "gnome", "skyborne", "unknown"]


def save(img, name):
    old = make_media.OUT
    make_media.OUT = MEDIA
    try:
        make_media.save_tga(img, name)
    finally:
        make_media.OUT = old


# ---------------------------------------------------------------------------------------------
# Cutting the sheets
# ---------------------------------------------------------------------------------------------
def dark_runs(values, limit):
    """[(start, end)] runs of indices whose value is under limit."""
    runs, start = [], None
    for i, v in enumerate(values):
        if v < limit and start is None:
            start = i
        elif v >= limit and start is not None:
            runs.append((start, i))
            start = None
    if start is not None:
        runs.append((start, len(values)))
    return runs


def gutter(im, axis):
    """(end of the first panel, start of the second) along x (axis 0) or y (axis 1): the darkest band
    near the middle of the sheet."""
    g = im.convert("L")
    w, h = g.size
    n = w if axis == 0 else h
    px = g.load()
    means = []
    for i in range(n):
        if axis == 0:
            s = sum(px[i, y] for y in range(0, h, 4)) / len(range(0, h, 4))
        else:
            s = sum(px[x, i] for x in range(0, w, 4)) / len(range(0, w, 4))
        means.append(s)
    mid = n // 2
    best = None
    for a, b in dark_runs(means, 40):
        if a < mid + n * 0.12 and b > mid - n * 0.12:
            if best is None or (b - a) > (best[1] - best[0]):
                best = (a, b)
    if best is None:
        return mid - 2, mid + 2
    return best


def edge(im, axis, far):
    """First column (or row) in from an outer edge that isn't the sheet's black border."""
    g = im.convert("L")
    w, h = g.size
    n = w if axis == 0 else h
    px = g.load()
    rng = range(n - 1, n // 2, -1) if far else range(0, n // 2)
    for i in rng:
        if axis == 0:
            s = sum(px[i, y] for y in range(0, h, 8)) / len(range(0, h, 8))
        else:
            s = sum(px[x, i] for x in range(0, w, 8)) / len(range(0, w, 8))
        if s >= 40:
            return i + (1 if far else 0)
    return n if far else 0


def pixelate(panel):
    """A panel shrunk to one mugshot cell and held to a small palette, so it reads as pixel art."""
    side = min(panel.size)
    panel = panel.crop(((panel.width - side) // 2, (panel.height - side) // 2,
                        (panel.width - side) // 2 + side, (panel.height - side) // 2 + side))
    small = panel.resize((CELL, CELL), Image.BOX)
    q = small.quantize(colors=64, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE)
    return q.convert("RGBA")


def cut(rawdir):
    os.makedirs(PORTRAITS, exist_ok=True)
    done = 0
    for sheet, keys in SHEETS:
        path = os.path.join(rawdir, sheet + ".png")
        if not os.path.exists(path):
            print("  missing sheet", sheet)
            continue
        im = Image.open(path).convert("RGB")
        x0, x3 = edge(im, 0, False), edge(im, 0, True)
        y0, y3 = edge(im, 1, False), edge(im, 1, True)
        x1, x2 = gutter(im, 0)
        y1, y2 = gutter(im, 1)
        boxes = [(x0, y0, x1, y1), (x2, y0, x3, y1), (x0, y2, x1, y3), (x2, y2, x3, y3)]
        for key, (a, b, c, d) in zip(keys, boxes):
            inset = 3
            panel = im.crop((a + inset, b + inset, c - inset, d - inset))
            pixelate(panel).save(os.path.join(PORTRAITS, key + ".png"))
            done += 1
    print("cut %d mugshots" % done)


# ---------------------------------------------------------------------------------------------
# Poster lettering and stamps
# ---------------------------------------------------------------------------------------------
INK = (44, 26, 12, 255)
STAMP_RED = (176, 26, 20, 255)


def font(name, size):
    return ImageFont.truetype(os.path.join(FONTS, name), size)


def grain(size, seed, density):
    """A speckle mask (L): where ink didn't take."""
    import random
    rnd = random.Random(seed)
    m = Image.new("L", size, 255)
    d = ImageDraw.Draw(m)
    w, h = size
    for _ in range(int(w * h * density)):
        x, y = rnd.randrange(w), rnd.randrange(h)
        r = rnd.choice((1, 1, 1, 2, 2, 3))
        d.ellipse((x, y, x + r, y + r), fill=rnd.randrange(0, 90))
    return m.filter(ImageFilter.GaussianBlur(0.6))


def lettering(text, fnt, w, h, colour, seed, spacing=0, rough=0.012):
    """Text centred on a w x h transparent texture, letterpress-rough."""
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    mask = Image.new("L", (w, h), 0)
    d = ImageDraw.Draw(mask)
    widths = [d.textlength(ch, font=fnt) for ch in text]
    total = sum(widths) + spacing * (len(text) - 1)
    asc, desc = fnt.getmetrics()
    x = (w - total) / 2
    y = (h - (asc + desc)) / 2
    for ch, cw in zip(text, widths):
        d.text((x, y), ch, font=fnt, fill=255)
        x += cw + spacing
    mask = ImageChops.multiply(mask, grain((w, h), seed, rough))
    img.paste(Image.new("RGBA", (w, h), colour), (0, 0), mask)
    return img


def stamp(text, w, h, seed, angle=-12):
    """A rubber stamp: a double-ruled box with the words in it, rotated and patchy."""
    big = Image.new("L", (w * 2, h * 2), 0)
    d = ImageDraw.Draw(big)
    fnt = font("impact.ttf", int(h * 0.62))
    tw = d.textlength(text, font=fnt)
    bw, bh = tw + h * 0.55, h * 0.95
    cx, cy = w, h
    box = (cx - bw / 2, cy - bh / 2, cx + bw / 2, cy + bh / 2)
    d.rounded_rectangle(box, radius=h * 0.08, outline=255, width=max(4, int(h * 0.07)))
    inner = (box[0] + h * 0.11, box[1] + h * 0.11, box[2] - h * 0.11, box[3] - h * 0.11)
    d.rounded_rectangle(inner, radius=h * 0.05, outline=255, width=max(2, int(h * 0.025)))
    asc, desc = fnt.getmetrics()
    d.text((cx - tw / 2, cy - (asc + desc) / 2 + h * 0.02), text, font=fnt, fill=255)
    big = big.rotate(angle, resample=Image.BICUBIC, expand=False)
    big = ImageChops.multiply(big, grain(big.size, seed, 0.03))
    mask = big.resize((w, h), Image.LANCZOS)
    # a stamp scaled to fit its texture: crop to what's inked, then fit the box with a margin
    bbox = mask.getbbox()
    out = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    if bbox:
        part = mask.crop(bbox)
        s = min((w - 8) / part.width, (h - 8) / part.height)
        part = part.resize((max(1, int(part.width * s)), max(1, int(part.height * s))), Image.LANCZOS)
        m2 = Image.new("L", (w, h), 0)
        m2.paste(part, ((w - part.width) // 2, (h - part.height) // 2))
        out.paste(Image.new("RGBA", (w, h), STAMP_RED), (0, 0), m2)
    return out


def poster_art():
    serif = "georgiab.ttf"
    head = lettering("WANTED", font(serif, 92), 512, 128, INK, 7, spacing=6)
    save(head, os.path.join("art", "wanted_head"))
    save(stamp("DEALT WITH", 512, 256, 11, -11), os.path.join("art", "wanted_stamp_dealt"))
    save(stamp("SQUARED UP", 512, 256, 13, 9), os.path.join("art", "wanted_stamp_square"))
    # the tack in each corner of a poster, and the pin through a mugshot
    pin = Image.new("RGBA", (32, 32), (0, 0, 0, 0))
    d = ImageDraw.Draw(pin)
    d.ellipse((7, 9, 25, 27), fill=(0, 0, 0, 90))
    d.ellipse((6, 5, 24, 23), fill=(150, 24, 18, 255))
    d.ellipse((9, 8, 17, 15), fill=(232, 96, 80, 255))
    save(pin, os.path.join("art", "wanted_pin"))


# ---------------------------------------------------------------------------------------------
# Atlases and the Lua index
# ---------------------------------------------------------------------------------------------
def atlas_of(key):
    race = key.split("_")[0]
    return race if race in ATLASES else "unknown"


def build():
    os.makedirs(os.path.join(MEDIA, "art"), exist_ok=True)
    files = sorted(f[:-4] for f in os.listdir(PORTRAITS) if f.endswith(".png"))
    sheets = {a: [] for a in ATLASES}
    for key in files:
        sheets[atlas_of(key)].append(key)
    index = {}
    per = ATLAS // CELL
    for a, keys in sheets.items():
        if not keys:
            continue
        assert len(keys) <= per * per, a + " has too many mugshots for one sheet"
        rows_used = (len(keys) + per - 1) // per
        h = 1 << max(4, (rows_used * CELL - 1).bit_length())   # only as tall as it needs, a power of two
        sheet = Image.new("RGBA", (ATLAS, h), (0, 0, 0, 0))
        for i, key in enumerate(keys):
            col, row = i % per, i // per
            im = Image.open(os.path.join(PORTRAITS, key + ".png")).convert("RGBA").resize((CELL, CELL), Image.NEAREST)
            sheet.paste(im, (col * CELL, row * CELL))
            index[key] = (a, col * CELL / ATLAS, (col + 1) * CELL / ATLAS, row * CELL / h, (row + 1) * CELL / h)
        save(sheet, os.path.join("art", "wanted_" + a))
    poster_art()

    def num(v):
        return ("%.6f" % v).rstrip("0").rstrip(".") if v else "0"

    rows = []
    for key in sorted(index):
        a, l, r, t, b = index[key]
        rows.append('        %s = { "%s", %s, %s, %s, %s },' % (key, a, num(l), num(r), num(t), num(b)))
    lua = """--[[ Greenfields - Data/WantedArt.lua
     GENERATED by tools/wanted_art.py - the Most Wanted mugshots and poster art.

       sheets[name]   texture path of a sheet of mugshots, 4 across
       mugs[key]      { sheet, left, right, top, bottom } for race_class_sex keys (human_warrior_m,
                      nightelf_druid_f ...), plus unknown_m / unknown_f / unknown_sack / unknown_mask for
                      faces nobody got a look at
       head, dealt, square, pin   the poster's WANTED lettering, its two stamps and a tack ]]

local _, GF = ...

GF.WantedArt = {
    sheets = {
%s
    },
    mugs = {
%s
    },
    head = "%swanted_head",
    dealt = "%swanted_stamp_dealt",
    square = "%swanted_stamp_square",
    pin = "%swanted_pin",
}
""" % ("\n".join('        %s = "%swanted_%s",' % (a, GAME, a) for a in ATLASES if sheets[a]),
       "\n".join(rows), GAME, GAME, GAME, GAME)
    open(LUA, "w", encoding="utf-8", newline="\n").write(lua)
    print("%d mugshots on %d sheets, poster lettering and stamps" % (len(index), sum(1 for a in ATLASES if sheets[a])))


if __name__ == "__main__":
    if len(sys.argv) >= 3 and sys.argv[1] == "--cut":
        cut(sys.argv[2])
    build()
