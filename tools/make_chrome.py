"""Generates the Warcraft-style chrome textures in Greenfields/Media (no AI, all procedural).

    python tools/make_chrome.py

    stone.tga       256  tileable dark slate (window + card backgrounds, tinted in game)
    leather.tga     256  tileable dark tooled leather (header + sidebar)
    parchment.tga   256  tileable aged parchment
    frame_gold.tga   64  9-slice bevelled gold frame, rivets in the corners (margins 16)
    frame_bronze.tga 32  9-slice thin bronze frame with corner ticks (margins 8)
    corner_gold.tga  64  ornate corner bracket with a green gem (top-left; mirror for others)
    divider_gold.tga 256x16  gold rule fading out at both ends, gem in the middle
    btn_green / btn_dark / btn_red / btn_gold .tga  64x32 9-slice buttons (margins 10)
    icon_frame.tga   64  gold square frame for game icons (open centre, margins 10)
    shine.tga        64  soft diagonal light streak (additive)
    gem_green.tga    32  faceted green gem
All sizes are powers of two; drawn at 4x and downsampled for clean edges.
"""
import math
import os
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from make_media import OUT, save_tga  # noqa: E402

SS = 4
GOLD_HI = (255, 236, 170)
GOLD = (222, 174, 70)
GOLD_MID = (176, 128, 44)
GOLD_LO = (92, 60, 18)
BRONZE = (150, 108, 58)
BRONZE_LO = (70, 48, 24)
DARK = (12, 10, 8)


# --------------------------------------------------------------------------- noise
def tile_noise(size, cells, seed):
    """Tileable value noise in [0,1]: bicubic upsample of a wrapped random lattice."""
    rng = np.random.default_rng(seed)
    lat = rng.random((cells, cells))
    lat = np.concatenate([lat, lat[:, :1]], axis=1)
    lat = np.concatenate([lat, lat[:1, :]], axis=0)
    img = Image.fromarray((lat * 255).astype(np.uint8), "L").resize((size + size // cells, size + size // cells), Image.BICUBIC)
    a = np.asarray(img, dtype=np.float32)[:size, :size] / 255.0
    return a


def fbm(size, seed, octaves=((4, 1.0), (8, 0.5), (16, 0.25), (32, 0.125), (64, 0.07))):
    acc = np.zeros((size, size), np.float32)
    tot = 0.0
    for i, (cells, amp) in enumerate(octaves):
        acc += tile_noise(size, cells, seed + i * 101) * amp
        tot += amp
    acc /= tot
    acc -= acc.min()
    acc /= max(1e-6, acc.max())
    return acc


def colorize(v, lo, hi):
    lo, hi = np.array(lo, np.float32), np.array(hi, np.float32)
    rgb = lo + (hi - lo) * v[..., None]
    return np.clip(rgb, 0, 255).astype(np.uint8)


def make_stone():
    n = 256
    base = fbm(n, 11)
    veins = np.abs(fbm(n, 77, ((6, 1.0), (12, 0.6), (24, 0.3))) - 0.5) * 2  # ridges
    cracks = np.clip(1.0 - veins * 6.0, 0, 1) ** 3
    v = 0.55 * base + 0.25 * fbm(n, 5, ((32, 1.0), (64, 0.6))) - 0.35 * cracks
    v = np.clip((v - v.min()) / (v.max() - v.min()), 0, 1)
    rgb = colorize(v, (22, 25, 24), (58, 64, 60))
    save_tga(Image.fromarray(rgb, "RGB").convert("RGBA"), "stone")


def make_leather():
    n = 256
    base = fbm(n, 21, ((8, 1.0), (16, 0.5), (32, 0.3)))
    grain = fbm(n, 99, ((64, 1.0), (128, 0.8)))
    pores = (grain > 0.78).astype(np.float32) * 0.35
    v = np.clip(0.75 * base + 0.25 * grain - pores, 0, 1)
    rgb = colorize(v, (26, 18, 12), (70, 48, 30))
    save_tga(Image.fromarray(rgb, "RGB").convert("RGBA"), "leather")


def make_parchment():
    n = 256
    base = fbm(n, 31)
    blot = fbm(n, 41, ((3, 1.0), (6, 0.5)))
    fib = fbm(n, 51, ((64, 1.0), (128, 0.7)))
    v = np.clip(0.55 * base + 0.25 * blot + 0.2 * fib, 0, 1)
    rgb = colorize(v, (176, 146, 98), (236, 214, 164))
    save_tga(Image.fromarray(rgb, "RGB").convert("RGBA"), "parchment")


# --------------------------------------------------------------------------- metal helpers
def metal_fill(w, h, hi, mid, lo, angle=-0.9):
    """Diagonal metal gradient with a little brushed noise."""
    ys, xs = np.mgrid[0:h, 0:w].astype(np.float32)
    t = (xs * math.cos(angle) + ys * math.sin(angle))
    t = (t - t.min()) / max(1e-6, (t.max() - t.min()))
    t = 1.0 - t
    # sharp specular band
    spec = np.exp(-((t - 0.28) ** 2) / 0.004) * 0.6
    base = np.where(t < 0.5, t * 2, (t - 0.5) * 2)
    col = np.zeros((h, w, 3), np.float32)
    lo_, mid_, hi_ = (np.array(c, np.float32) for c in (lo, mid, hi))
    for i in range(3):
        a = np.where(t < 0.5, lo_[i] + (mid_[i] - lo_[i]) * base, mid_[i] + (hi_[i] - mid_[i]) * base)
        col[..., i] = a + spec * 120
    rng = np.random.default_rng(3)
    col += rng.normal(0, 6, (h, w, 1))
    return Image.fromarray(np.clip(col, 0, 255).astype(np.uint8), "RGB")


def ring_mask(W, H, outer, inner, radius):
    m = Image.new("L", (W, H), 0)
    d = ImageDraw.Draw(m)
    d.rounded_rectangle(outer, radius=radius, fill=255)
    d.rounded_rectangle(inner, radius=max(0, radius - (inner[0] - outer[0])), fill=0)
    return m


def rivet(img, cx, cy, r):
    d = ImageDraw.Draw(img)
    d.ellipse((cx - r * 1.25, cy - r * 1.25, cx + r * 1.25, cy + r * 1.25), fill=DARK + (230,))
    grad = metal_fill(int(r * 2), int(r * 2), GOLD_HI, GOLD, GOLD_LO).convert("RGBA")
    m = Image.new("L", grad.size, 0)
    ImageDraw.Draw(m).ellipse((0, 0, grad.size[0] - 1, grad.size[1] - 1), fill=255)
    grad.putalpha(m)
    img.alpha_composite(grad, (int(cx - r), int(cy - r)))
    d.ellipse((cx - r * 0.45, cy - r * 0.6, cx - r * 0.05, cy - r * 0.2), fill=(255, 250, 225, 200))


def bevel_frame(size, band, radius, hi, mid, lo, rivets=False):
    W = size * SS
    img = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    b = band * SS
    # dark outline
    outline = ring_mask(W, W, (0, 0, W - 1, W - 1), (b + 2 * SS, b + 2 * SS, W - 1 - b - 2 * SS, W - 1 - b - 2 * SS), radius * SS)
    dark = Image.new("RGBA", (W, W), DARK + (255,))
    img.paste(dark, (0, 0), outline)
    # metal band
    m = ring_mask(W, W, (SS, SS, W - 1 - SS, W - 1 - SS), (b + SS, b + SS, W - 1 - b - SS, W - 1 - b - SS), max(0, radius - 1) * SS)
    metal = metal_fill(W, W, hi, mid, lo).convert("RGBA")
    img.paste(metal, (0, 0), m)
    # inner highlight line
    d = ImageDraw.Draw(img)
    d.rounded_rectangle((b + SS, b + SS, W - 1 - b - SS, W - 1 - b - SS), radius=max(0, radius - band) * SS, outline=hi + (90,), width=SS)
    if rivets:
        for (cx, cy) in ((b * 0.55, b * 0.55), (W - b * 0.55, b * 0.55), (b * 0.55, W - b * 0.55), (W - b * 0.55, W - b * 0.55)):
            rivet(img, cx, cy, b * 0.42)
    return img.resize((size, size), Image.LANCZOS)


def make_frames():
    save_tga(bevel_frame(64, 6, 4, GOLD_HI, GOLD, GOLD_LO, rivets=True), "frame_gold")
    # thin bronze frame with little corner ticks
    W = 32 * SS
    img = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rectangle((0, 0, W - 1, W - 1), outline=DARK + (220,), width=SS)
    d.rectangle((SS, SS, W - 1 - SS, W - 1 - SS), outline=BRONZE + (255,), width=SS)
    d.rectangle((2 * SS, 2 * SS, W - 1 - 2 * SS, W - 1 - 2 * SS), outline=BRONZE_LO + (200,), width=SS)
    for (x, y, sx, sy) in ((0, 0, 1, 1), (W - 1, 0, -1, 1), (0, W - 1, 1, -1), (W - 1, W - 1, -1, -1)):
        pts = [(x, y), (x + sx * 7 * SS, y), (x + sx * 7 * SS, y + sy * 2 * SS), (x + sy * 0 + sx * 2 * SS, y + sy * 2 * SS),
               (x + sx * 2 * SS, y + sy * 7 * SS), (x, y + sy * 7 * SS)]
        d.polygon(pts, fill=GOLD + (255,))
    save_tga(img.resize((32, 32), Image.LANCZOS), "frame_bronze")


def gem(size, col_hi, col, col_lo):
    W = size * SS
    img = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    c = W / 2
    r = W * 0.42
    pts = [(c + r * math.cos(a), c + r * math.sin(a)) for a in [i * math.pi / 4 + math.pi / 8 for i in range(8)]]
    d.polygon([(p[0] + SS, p[1] + SS) for p in pts], fill=DARK + (200,))
    d.polygon(pts, fill=col + (255,))
    # facets
    inner = [(c + r * 0.55 * math.cos(a), c + r * 0.55 * math.sin(a)) for a in [i * math.pi / 4 + math.pi / 8 for i in range(8)]]
    for i in range(8):
        shade = col_hi if i in (5, 6) else (col_lo if i in (1, 2) else col)
        d.polygon([pts[i], pts[(i + 1) % 8], inner[(i + 1) % 8], inner[i]], fill=shade + (255,))
    d.polygon(inner, fill=col + (255,))
    d.ellipse((c - r * 0.35, c - r * 0.42, c - r * 0.05, c - r * 0.15), fill=(255, 255, 255, 210))
    d.polygon(pts, outline=GOLD + (255,), width=SS)
    return img.resize((size, size), Image.LANCZOS)


def make_gem_and_corner():
    save_tga(gem(32, (150, 255, 180), (40, 190, 100), (10, 90, 50)), "gem_green")
    # ornate corner: L bracket with scalloped inner edge and a gem
    W = 64 * SS
    mask = Image.new("L", (W, W), 0)
    d = ImageDraw.Draw(mask)
    t = 10 * SS
    d.rectangle((0, 0, W - 6 * SS, t), fill=255)
    d.rectangle((0, 0, t, W - 6 * SS), fill=255)
    d.pieslice((-t, -t, 34 * SS, 34 * SS), 0, 90, fill=255)  # rounded inner fill near the corner
    d.polygon([(W - 6 * SS, 0), (W, t / 2), (W - 6 * SS, t)], fill=255)  # arrow tips
    d.polygon([(0, W - 6 * SS), (t / 2, W), (t, W - 6 * SS)], fill=255)
    for k in range(3):  # scallops along the arms
        x = 18 * SS + k * 12 * SS
        d.ellipse((x - 3 * SS, t - 2 * SS, x + 3 * SS, t + 4 * SS), fill=255)
        d.ellipse((t - 2 * SS, x - 3 * SS, t + 4 * SS, x + 3 * SS), fill=255)
    metal = metal_fill(W, W, GOLD_HI, GOLD, GOLD_LO).convert("RGBA")
    out = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    shadow = Image.new("RGBA", (W, W), DARK + (255,))
    sm = mask.filter(ImageFilter.MaxFilter(5)).filter(ImageFilter.GaussianBlur(SS))
    out.paste(shadow, (0, 0), sm)
    out.paste(metal, (0, 0), mask)
    edge = mask.filter(ImageFilter.FIND_EDGES)
    hl = Image.new("RGBA", (W, W), GOLD_HI + (140,))
    out.paste(hl, (0, 0), edge)
    g = gem(18, (150, 255, 180), (40, 190, 100), (10, 90, 50)).resize((18 * SS, 18 * SS), Image.LANCZOS)
    out.alpha_composite(g, (int(9 * SS), int(9 * SS)))
    save_tga(out.resize((64, 64), Image.LANCZOS), "corner_gold")


def make_divider():
    W, H = 256 * SS, 16 * SS
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    xs = np.linspace(0, 1, W)
    fade = np.clip(np.minimum(xs, 1 - xs) * 5, 0, 1)
    line = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    px = np.zeros((H, W, 4), np.uint8)
    cy = H // 2
    for dy, col, a in ((-SS, GOLD_HI, 200), (0, GOLD, 255), (SS, GOLD_LO, 220)):
        px[cy + dy:cy + dy + SS, :, :3] = col
        px[cy + dy:cy + dy + SS, :, 3] = (fade * a).astype(np.uint8)
    line = Image.fromarray(px, "RGBA")
    img.alpha_composite(line)
    d = ImageDraw.Draw(img)
    c = W / 2
    d.polygon([(c - 22 * SS, cy), (c, cy - 6.5 * SS), (c + 22 * SS, cy), (c, cy + 6.5 * SS)], fill=DARK + (255,))
    d.polygon([(c - 19 * SS, cy), (c, cy - 5 * SS), (c + 19 * SS, cy), (c, cy + 5 * SS)], fill=GOLD + (255,))
    g = gem(8, (150, 255, 180), (40, 190, 100), (10, 90, 50)).resize((8 * SS, 8 * SS), Image.LANCZOS)
    img.alpha_composite(g, (int(c - 4 * SS), int(cy - 4 * SS)))
    save_tga(img.resize((256, 16), Image.LANCZOS), "divider_gold")


def make_buttons():
    variants = {
        "btn_green": ((70, 200, 120), (22, 130, 70), (8, 70, 38)),
        "btn_dark": ((70, 76, 72), (40, 44, 42), (20, 22, 21)),
        "btn_red": ((210, 70, 60), (150, 30, 26), (80, 14, 12)),
        "btn_gold": ((255, 220, 120), (200, 150, 50), (110, 72, 18)),
    }
    for name, (hi, mid, lo) in variants.items():
        W, H = 64 * SS, 32 * SS
        img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        d = ImageDraw.Draw(img)
        d.rounded_rectangle((0, 0, W - 1, H - 1), radius=6 * SS, fill=DARK + (255,))
        rim = metal_fill(W, H, GOLD_HI, GOLD_MID, GOLD_LO).convert("RGBA")
        m = Image.new("L", (W, H), 0)
        ImageDraw.Draw(m).rounded_rectangle((SS, SS, W - 1 - SS, H - 1 - SS), radius=5 * SS, fill=255)
        img.paste(rim, (0, 0), m)
        # face: vertical gradient
        ys = np.linspace(0, 1, H)[:, None, None]
        hi_, mid_, lo_ = (np.array(c, np.float32) for c in (hi, mid, lo))
        face = np.where(ys < 0.5, hi_ + (mid_ - hi_) * (ys * 2), mid_ + (lo_ - mid_) * ((ys - 0.5) * 2))
        face = np.broadcast_to(face, (H, W, 3))
        fimg = Image.fromarray(np.clip(face, 0, 255).astype(np.uint8), "RGB").convert("RGBA")
        fm = Image.new("L", (W, H), 0)
        ImageDraw.Draw(fm).rounded_rectangle((3 * SS, 3 * SS, W - 1 - 3 * SS, H - 1 - 3 * SS), radius=3 * SS, fill=255)
        img.paste(fimg, (0, 0), fm)
        # gloss on the upper half
        gloss = Image.new("RGBA", (W, H), (255, 255, 255, 0))
        ImageDraw.Draw(gloss).rounded_rectangle((4 * SS, 4 * SS, W - 1 - 4 * SS, H // 2), radius=3 * SS, fill=(255, 255, 255, 38))
        img.alpha_composite(gloss)
        save_tga(img.resize((64, 32), Image.LANCZOS), name)


def make_icon_frame():
    W = 64 * SS
    img = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    b = 5 * SS
    outline = ring_mask(W, W, (0, 0, W - 1, W - 1), (b + SS, b + SS, W - 1 - b - SS, W - 1 - b - SS), 3 * SS)
    img.paste(Image.new("RGBA", (W, W), DARK + (255,)), (0, 0), outline)
    m = ring_mask(W, W, (SS, SS, W - 1 - SS, W - 1 - SS), (b, b, W - 1 - b, W - 1 - b), 2 * SS)
    img.paste(metal_fill(W, W, GOLD_HI, GOLD, GOLD_LO).convert("RGBA"), (0, 0), m)
    d = ImageDraw.Draw(img)
    d.rectangle((b, b, W - 1 - b, W - 1 - b), outline=(0, 0, 0, 200), width=SS)
    save_tga(img.resize((64, 64), Image.LANCZOS), "icon_frame")


def make_shine():
    W = 64 * SS
    img = Image.new("L", (W, W), 0)
    d = ImageDraw.Draw(img)
    d.polygon([(W * 0.35, 0), (W * 0.55, 0), (W * 0.35, W), (W * 0.15, W)], fill=255)
    img = img.filter(ImageFilter.GaussianBlur(5 * SS))
    rgba = Image.new("RGBA", (W, W), (255, 255, 255, 0))
    rgba.putalpha(img.point(lambda v: int(v * 0.75)))
    save_tga(rgba.resize((64, 64), Image.LANCZOS), "shine")


def preview():
    names = ["stone", "leather", "parchment", "frame_gold", "frame_bronze", "corner_gold", "gem_green",
             "btn_green", "btn_dark", "btn_red", "btn_gold", "icon_frame", "shine", "divider_gold"]
    sheet = Image.new("RGBA", (900, 420), (30, 32, 30, 255))
    x, y = 10, 10
    for n in names:
        im = Image.open(os.path.join(OUT, n + ".tga")).convert("RGBA")
        if im.size[0] >= 256:
            im = im.resize((im.size[0] // 2, max(8, im.size[1] // 2))) if n != "divider_gold" else im
        if x + im.size[0] > 890:
            x, y = 10, y + 140
        sheet.alpha_composite(im, (x, y))
        x += im.size[0] + 14
    # mock window corner + frame assembled
    out = os.path.join(os.path.dirname(OUT), "..", "tools", "chrome_preview.png")
    sheet.save(os.path.abspath(out))
    print("preview:", os.path.abspath(out))


if __name__ == "__main__":
    make_stone()
    make_leather()
    make_parchment()
    make_frames()
    make_gem_and_corner()
    make_divider()
    make_buttons()
    make_icon_frame()
    make_shine()
    preview()
