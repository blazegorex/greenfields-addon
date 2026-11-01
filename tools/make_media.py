"""Generates the road signs, crest, line icons and small utility textures in Greenfields/Media.
tools/make_chrome.py owns the metal, panels and pills; don't add those here.

WoW wants uncompressed 32-bit TGA (image type 2, descriptor 0x08, bottom-left origin)
with power-of-two sizes, which is exactly what Forever-era addons ship. Everything is
drawn big and downsampled so edges are antialiased.

    python -P tools/make_media.py            # everything
    python -P tools/make_media.py signs      # one group: signs, crest, utility, icons
"""
import math
import os
import random
import struct
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import artkit as ak  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "Greenfields", "Media")
FONTS = r"C:\Windows\Fonts"
SS = 4  # supersample factor

WHITE = (255, 255, 255)
HAZARD = (255, 204, 0)


def save_tga(img, name):
    img = img.convert("RGBA")
    w, h = img.size
    assert w & (w - 1) == 0 and h & (h - 1) == 0, f"{name}: {w}x{h} is not power-of-two"
    header = struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, w, h, 32, 0x08)
    rows = []
    px = img.tobytes("raw", "BGRA")
    stride = w * 4
    for y in range(h - 1, -1, -1):  # bottom-left origin
        rows.append(px[y * stride:(y + 1) * stride])
    with open(os.path.join(OUT, name + ".tga"), "wb") as f:
        f.write(header)
        f.write(b"".join(rows))


def font(file, size, variation=None):
    f = ImageFont.truetype(os.path.join(FONTS, file), size)
    if variation:
        try:
            f.set_variation_by_name(variation)
        except Exception:
            pass
    return f


def rounded_mask(size, box, radius):
    m = Image.new("L", size, 0)
    ImageDraw.Draw(m).rounded_rectangle(box, radius=radius, fill=255)
    return m


# --------------------------------------------------------------------------------------
# Road signs: pressed aluminium, matte enamel, embossed lettering. Built as a height field by
# artkit so they share the window's top-left light. Layouts are in "design units" of the old
# 512-wide sign; everything is drawn at 4x that and shrunk to the size the file ships at.
# --------------------------------------------------------------------------------------
U = 4  # big pixels per design unit

FACE_GREEN = ak.ramp((0, "#02180d"), (0.30, "#06482a"), (0.50, "#0c6b3e"), (0.70, "#158a52"), (0.88, "#43b582"), (1, "#b9ecd2"))
FACE_YELLOW = ak.ramp((0, "#3f2d02"), (0.28, "#b98a04"), (0.50, "#efbb0c"), (0.70, "#fbd02e"), (0.88, "#ffe579"), (1, "#fff7cf"))
FACE_RED = ak.ramp((0, "#220304"), (0.30, "#7c1216"), (0.50, "#ae1f22"), (0.70, "#cd3a38"), (0.88, "#e77f76"), (1, "#f9d3cc"))
FACE_BLUE = ak.ramp((0, "#030a1d"), (0.30, "#0d2a63"), (0.50, "#143c8a"), (0.70, "#2256ab"), (0.88, "#6b92d0"), (1, "#cfdcf3"))
INK_WHITE = ak.ramp((0, "#5b625d"), (0.28, "#aeb5ad"), (0.50, "#eceee5"), (0.72, "#fafbf4"), (1, "#ffffff"))
INK_SOFT = ak.ramp((0, "#4d5a52"), (0.28, "#9eaea4"), (0.50, "#dae6dd"), (0.72, "#f0f7f1"), (1, "#ffffff"))
INK_BLACK = ak.ramp((0, "#000000"), (0.50, "#15140f"), (0.72, "#34322a"), (0.90, "#77735f"), (1, "#c9c4a8"))
ALUMINIUM = ak.ramp((0, "#17191a"), (0.25, "#55595b"), (0.50, "#8f9496"), (0.72, "#c3c7c8"), (0.90, "#e8eaea"), (1, "#ffffff"))


def text_mask(canvas):
    return ImageDraw.Draw(canvas.img)


def road_sign(w, h, dw, dh, face, ink=INK_WHITE, soft=INK_SOFT, seed=1, paint=None, radius=14, inset=5, border_w=4,
              bolts=(), stickers=(), name=None, wear_band=16):
    """w x h is what ships, dw x dh the layout space. paint(main, sub, box) draws lettering in big
    pixels onto two masks: main takes `ink`, sub takes the softer `soft` used for small print."""
    W, H = dw * U, dh * U
    box = (inset * U, inset * U, W - inset * U, H - (inset + 3) * U)
    plate = ak.Canvas(W, H).rrect(*box, radius * U).array()
    b = 4 * U
    bw = border_w * U
    ring = (ak.Canvas(W, H).rrect(box[0] + b, box[1] + b, box[2] - b, box[3] - b, (radius - 4) * U).array()
            * (1 - ak.Canvas(W, H).rrect(box[0] + b + bw, box[1] + b + bw, box[2] - b - bw, box[3] - b - bw,
                                         max(1, radius - 4 - border_w) * U).array()))
    main, sub = ak.Canvas(W, H), ak.Canvas(W, H)
    if paint:
        paint(main, sub, box)
    main_a, sub_a = np.maximum(main.array(), ring), sub.array()
    raised = np.maximum(main_a, sub_a)

    # the sheet: rolled edge, a little waviness from being pressed, then the raised lettering
    wobble = ak.fbm_noise(H, W, seed, cells=3, octaves=3) * 2.6 * U
    rolled = ak.bevel(plate, 1.6 * U, 1.3 * U)
    emboss = ak.blur(ak.bevel(raised, 0.95 * U, 0.85 * U), 0.14 * U)
    height = rolled + wobble + emboss

    ys, xs = np.mgrid[0:H, 0:W].astype(np.float32)
    # gentle falloff away from the light, not a gloss band
    drift = (0.5 - (xs / W * 0.6 + ys / H * 0.4)) * 0.10

    def lit(material, amount=1.0):
        return ak.shade(height, lambda v: material(np.clip(v + drift * amount, 0, 1)), strength=1.0, base=0.5, gain=0.72,
                        spec=0.10, shininess=14, grain=0.5, seed=seed + 1, sheen=0.035)

    L = ak.Layer(W, H)
    L.over((0, 0, 0), ak.drop_shadow(plate, 0, 1.4 * U, 2.4 * U, 0.60) * (1 - plate))
    L.over(lit(face), plate)
    L.over((0, 0, 0), ak.drop_shadow(raised, 0.45 * U, 0.65 * U, 0.55 * U, 0.34) * (1 - raised) * plate)
    L.over(lit(ink, 0.6), main_a * plate)
    L.over(lit(soft, 0.6), sub_a * (1 - main_a) * plate)

    # honest wear, out by the edges where text never goes
    rng = np.random.default_rng(seed + 2)
    edge_dist = ak.sdf(plate) / U
    band = np.clip(1 - edge_dist / wear_band, 0, 1) * plate
    weather = np.clip(ak.fbm_noise(H, W, seed + 4, cells=5, octaves=4) - 0.52, 0, 1) * 2.2
    L.over((238, 236, 222), weather * band * 0.10)
    chips = ak.Canvas(W, H)
    for _ in range(14):
        a = rng.random() * 2 * math.pi
        x = rng.random() * W
        y = rng.random() * H
        if rng.random() < 0.5:
            y = box[1] + rng.random() * 9 * U if rng.random() < 0.5 else box[3] - rng.random() * 9 * U
        else:
            x = box[0] + rng.random() * 9 * U if rng.random() < 0.5 else box[2] - rng.random() * 9 * U
        r = (0.3 + rng.random() * 0.7) * U
        chips.poly([(x + math.cos(a + i * 1.26) * r * (0.7 + rng.random() * 0.6),
                     y + math.sin(a + i * 1.26) * r * (0.7 + rng.random() * 0.6)) for i in range(5)])
    chip_a = ak.blur(chips.array(), 0.1 * U) * plate
    L.over((150, 154, 154), chip_a * 0.55)
    L.over((0, 0, 0), ak.drop_shadow(chip_a, 0, 0.3 * U, 0.2 * U, 0.3) * (1 - chip_a) * plate)

    # raw metal showing along the cut edge
    edge = plate * (1 - ak.Canvas(W, H).rrect(box[0] + 0.75 * U, box[1] + 0.75 * U, box[2] - 0.75 * U, box[3] - 0.75 * U,
                                              (radius - 0.75) * U).array())
    L.over(lit(ALUMINIUM), edge * 0.9)

    for (bx, by, br) in bolts:
        draw_bolt(L, W, H, bx * U, by * U, br * U, plate)
    for st in stickers:
        draw_sticker(L, W, H, *st)
    img = L.image(w, h)
    if name:
        save_tga(img, name)
    return img


def draw_bolt(L, W, H, cx, cy, r, plate):
    washer = ak.Canvas(W, H).circle(cx, cy, r * 1.35).array()
    head = ak.Canvas(W, H).circle(cx, cy, r).array()
    # a thin rust weep running down from the bolt
    ys, xs = np.mgrid[0:H, 0:W].astype(np.float32)
    weep = np.exp(-((xs - cx) / (r * 0.55)) ** 2) * np.clip((ys - cy) / (r * 7), 0, 1) ** 0.4 * np.clip(1 - (ys - cy) / (r * 7), 0, 1)
    L.over((60, 34, 14), weep * plate * 0.16)
    L.over((0, 0, 0), ak.drop_shadow(washer, 0.25 * U, 0.4 * U, 0.35 * U, 0.55) * (1 - washer) * plate)
    h_washer = ak.bevel(washer, r * 0.4, r * 0.25)
    L.over(ak.shade(h_washer, ALUMINIUM, strength=1.0, base=0.40, gain=0.9, spec=0.2), washer)
    h_head = ak.bevel(head, r, r * 0.85)
    L.over(ak.shade(h_head, ALUMINIUM, strength=0.9, base=0.52, gain=0.85, spec=0.55, shininess=30), head)


def draw_sticker(L, W, H, cx, cy, text, angle, fill=HAZARD, ink=(20, 20, 20)):
    """A vinyl sticker slapped on crooked. cx, cy in design units."""
    f = font("bahnschrift.ttf", 13 * U, "Bold")
    tmp = Image.new("RGBA", (160 * U, 40 * U), (0, 0, 0, 0))
    d = ImageDraw.Draw(tmp)
    tw = d.textlength(text, font=f)
    pad = 6 * U
    bx = (0, 0, tw + pad * 2, 22 * U)
    d.rounded_rectangle(bx, radius=3 * U, fill=fill + (255,))
    d.text((pad, 2.5 * U), text, font=f, fill=ink + (255,))
    tmp = tmp.crop((0, 0, int(bx[2]) + 1, int(bx[3]) + 1)).rotate(angle, resample=Image.BICUBIC, expand=True)
    full = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    full.alpha_composite(tmp, (int(cx * U - tmp.width / 2), int(cy * U - tmp.height / 2)))
    arr = np.asarray(full, dtype=np.float32)
    a = arr[..., 3] / 255.0
    L.over((0, 0, 0), ak.drop_shadow(a, 0.3 * U, 0.6 * U, 0.6 * U, 0.5) * (1 - a))
    ys, xs = np.mgrid[0:H, 0:W].astype(np.float32)
    lift = 1.04 - (ys - cy * U) / (22 * U) * 0.07
    L.over(np.clip(arr[..., :3] * lift[..., None], 0, 255), a)


def centered(d, box, y, text, fnt, fill, spacing=0):
    """Text centred across box. y is the top of the line, all in big pixels."""
    if spacing:
        widths = [d.textlength(ch, font=fnt) for ch in text]
        total = sum(widths) + spacing * (len(text) - 1)
        x = box[0] + (box[2] - box[0] - total) / 2
        for ch, cw in zip(text, widths):
            d.text((x, y), ch, font=fnt, fill=fill)
            x += cw + spacing
    else:
        tw = d.textlength(text, font=fnt)
        d.text((box[0] + (box[2] - box[0] - tw) / 2, y), text, font=fnt, fill=fill)


def make_logo():
    def text(main, sub, box):
        big = font("bahnschrift.ttf", 62 * U, "Bold")
        small = font("bahnschrift.ttf", 16 * U, "SemiBold")
        centered(text_mask(main), box, box[1] + 10 * U, "GREENFIELDS", big, 255, spacing=2 * U)
        centered(text_mask(sub), box, box[1] + 82 * U, "MANDURAH  •  WA 6210", small, 255, spacing=3 * U)
    road_sign(512, 128, 512, 128, FACE_GREEN, seed=6210, paint=text, name="logo",
              bolts=((35, 27, 2.6), (512 - 45, 128 - 26, 2.6)),
              stickers=((512 - 57, 15, "EST. 2026", -9),))


def make_signs():
    # toasts stretch the middle fifth of these when they grow a line (UI/Toast.lua), so the bolts
    # sit clear of it, one up top and one down low
    bolts = ((22, 37, 2.6), (512 - 22, 128 - 3 - 37, 2.6))
    road_sign(1024, 256, 512, 128, FACE_GREEN, seed=11, bolts=bolts, name="sign_green", wear_band=13)
    road_sign(1024, 256, 512, 128, FACE_YELLOW, ink=INK_BLACK, soft=INK_BLACK, seed=12, bolts=bolts, name="sign_yellow", wear_band=13)
    road_sign(1024, 256, 512, 128, FACE_RED, seed=13, bolts=bolts, name="sign_red", wear_band=13)
    road_sign(1024, 256, 512, 128, FACE_BLUE, seed=14, bolts=bolts, name="sign_blue", wear_band=13)

    def welcome(main, sub, box):
        # this shows at about 0.43 of its design size, so the small print has to be big or it's not there
        a = font("bahnschrift.ttf", 24 * U, "SemiBold")
        b = font("bahnschrift.ttf", 64 * U, "Bold")
        c = font("bahnschrift.ttf", 31 * U, "SemiBold")
        centered(text_mask(main), box, box[1] + 16 * U, "WELCOME TO", a, 255, spacing=6 * U)
        centered(text_mask(main), box, box[1] + 42 * U, "GREENFIELDS", b, 255, spacing=2 * U)
        y = box[1] + 124 * U
        main.rrect(box[0] + 60 * U, y - U, box[2] - 60 * U, y + U, U)
        centered(text_mask(sub), box, box[1] + 134 * U, "POP. 40 RAIDERS", c, 255, spacing=U)
        centered(text_mask(sub), box, box[1] + 174 * U, "1 SERVO. NO QUESTIONS.", c, 255, spacing=U)
    road_sign(512, 256, 512, 256, FACE_GREEN, seed=99, paint=welcome, radius=20, name="welcome",
              bolts=((512 - 34, 32, 3), (34, 256 - 38, 3)))

    def watch(main, sub, box):
        # the eye: an almond outline, a solid iris, one catch-light
        cx, cy, hw, hh = 76 * U, 62 * U, 44 * U, 27 * U
        top = ak.bezier((cx - hw, cy), (cx, cy - hh * 1.9), (cx + hw, cy), n=48)
        bot = ak.bezier((cx + hw, cy), (cx, cy + hh * 1.9), (cx - hw, cy), n=48)
        almond = np.concatenate((top, bot))
        main.poly(almond)
        k = 0.80
        main.poly([(cx + (x - cx) * k, cy + (y - cy) * k) for (x, y) in almond], fill=0)
        main.circle(cx, cy, 17.5 * U)
        main.circle(cx - 5.5 * U, cy - 6 * U, 4.6 * U, fill=0)
        f = font("bahnschrift.ttf", 43 * U, "Bold")
        d = text_mask(main)
        x0, x1 = 132 * U, (512 - 22) * U
        for text, base in (("NEIGHBOURHOOD", 56), ("WATCH AREA", 100)):
            total = d.textlength(text, font=f)
            d.text((x0 + (x1 - x0 - total) / 2, base * U), text, font=f, fill=255, anchor="ls")
    road_sign(512, 128, 512, 128, FACE_YELLOW, ink=INK_BLACK, soft=INK_BLACK, seed=77, paint=watch, name="sign_watch",
              bolts=((22, 37, 2.4), (512 - 22, 128 - 3 - 37, 2.4)))


# --------------------------------------------------------------------------------------
# The crest: a heater shield in sign-green enamel, gold rim, and the glass pipe, borne upright
# --------------------------------------------------------------------------------------
def shield_outline(cx, top, half, bottom, shoulder, inset=0.0):
    """Heater shield outline in big pixels: flat top, straight shoulders, curving to a point."""
    x0, x1 = cx - half + inset, cx + half - inset
    t, b = top + inset, bottom - inset * 1.5
    s = shoulder
    left = ak.bezier((x0, s), (x0, s + (b - s) * 0.50), (cx - (half - inset) * 0.42, s + (b - s) * 0.80), (cx, b), n=60)
    right = left.copy()
    right[:, 0] = 2 * cx - right[:, 0]
    return [(x0, t), (x1, t)] + [tuple(p) for p in right] + [tuple(p) for p in left[::-1]]


def pipe_masks(N, P, w, wisp_w=2.6):
    """The charge on the shield, borne upright the way another family would carry a sword: a straight
    stem up the middle from the point of the shield, a blown bulb, a curl of smoke. As masks: the
    white glass lines, the see-through inside of it, the burn low in the bulb, the ember, and the
    smoke. The hollow stem and the ember are what stop it being a magnifying glass. P maps (x, y) in
    a 128-wide layout to big pixels, w scales a width."""
    glass, body, soot, ember, wisp = ak.Canvas(N, N), ak.Canvas(N, N), ak.Canvas(N, N), ak.Canvas(N, N), ak.Canvas(N, N)
    cx, cy, r = 64, 56, 16.5
    # the bulb: a ring of glass round a clear middle
    glass.circle(*P(cx, cy), w(r))
    glass.circle(*P(cx, cy), w(r - 3.5), fill=0)
    body.circle(*P(cx, cy), w(r - 3.5))
    soot.circle(*P(cx - 1.0, cy + 6.0), w(r - 6.5))
    soot.circle(*P(cx + 2.0, cy + 0.5), w(r - 5.5), fill=0)
    # the stem, a touch wider where it's blown out of the bulb
    stem = ak.bezier(P(cx, cy + r - 2.0), P(cx, cy + 30), P(cx, 105), n=40)
    glass.poly(ak.ribbon(stem, np.linspace(w(9.0), w(7.0), 40)))
    hollow = ak.bezier(P(cx, cy + r - 3.6), P(cx, cy + 30), P(cx, 106), n=40)
    glass.poly(ak.ribbon(hollow, np.linspace(w(4.0), w(2.6), 40)), fill=0)
    body.poly(ak.ribbon(hollow, np.linspace(w(4.0), w(2.6), 40)))
    ember.circle(*P(cx, cy + 8.0), w(4.2))
    # the glints, and the little hole in the top
    glass.circle(*P(cx + 5.2, cy - 5.6), w(2.7))
    glass.circle(*P(cx - 6.4, cy - 3.2), w(1.2))
    # the smoke, curling up toward the top of the shield
    curl = ak.bezier(P(cx, cy - r + 1), P(cx + 11, cy - r - 6), P(cx - 9, cy - r - 8), P(cx + 2, 28), n=50)
    wisp.poly(ak.ribbon(curl, np.linspace(w(wisp_w), w(wisp_w * 1.5), 50)))
    return glass.array(), body.array(), soot.array(), ember.array(), wisp.array()


def make_crest():
    px = 128
    N = px * 8
    u = N / 128.0

    def P(x, y):
        return (x * u, y * u)

    def w(x):
        return x * u
    cx = 64 * u
    top, half, bottom, shoulder = 21 * u, 36 * u, 121 * u, 58 * u
    outer = ak.Canvas(N, N).poly(shield_outline(cx, top, half, bottom, shoulder)).array()
    inner = ak.Canvas(N, N).poly(shield_outline(cx, top, half, bottom, shoulder, inset=4.6 * u)).array()
    rim = outer * (1 - inner)

    # two gum leaves crossed behind the shield, tips and stems showing either side
    leaves, ribs = ak.Canvas(N, N), ak.Canvas(N, N)
    for (p0, c, p1, wd) in (((9, 104), (58, 96), (117, 7), 24), ((119, 104), (70, 96), (11, 7), 24)):
        mid = ak.bezier(P(*p0), P(*c), P(*p1), n=80)
        # fat all along, or the bits that show past the shield come out as spikes
        leaves.poly(ak.ribbon(mid, w(wd) * np.sin(np.linspace(0, 1, 80) * math.pi) ** 0.62))
        ribs.poly(ak.ribbon(mid[3:-5], w(0.9)))
    leaves_a = leaves.array()
    h_leaf = ak.blur(ak.bevel(leaves_a, 3.0 * u, 3.6 * u) - ak.blur(ribs.array(), 0.25 * u) * 1.3 * u, 0.2 * u)
    gold_leaf = ak.shade(h_leaf, ak.GOLD, strength=1.15, base=0.50, gain=1.15, spec=0.45, shininess=28, grain=0.5, seed=3, wear=0.5, sheen=0.06)

    # the shield itself
    h_rim = ak.blur(ak.bevel(rim, 1.9 * u, 3.0 * u), 0.2 * u)
    gold_rim = ak.shade(h_rim, ak.GOLD, strength=1.2, base=0.56, gain=1.25, spec=0.55, shininess=30, grain=0.5, seed=5, wear=0.7, sheen=0.05)
    ys, xs = np.mgrid[0:N, 0:N].astype(np.float32)
    drift = (0.5 - (xs + ys) / (2.0 * N)) * 0.30
    dome = ak.blur(ak.bevel(inner, 26 * u, 5.0 * u, profile="smooth"), 9 * u)
    face = ak.shade(dome, lambda v: FACE_GREEN(np.clip(v + drift, 0, 1)), strength=1.0, base=0.47, gain=0.8, spec=0.12, shininess=12)

    glass, body, soot, ember, wisp = pipe_masks(N, P, w)
    h_glass = ak.blur(ak.bevel(glass, 1.7 * u, 2.2 * u), 0.2 * u)
    c_glass = ak.shade(h_glass, INK_WHITE, strength=1.0, base=0.56, gain=0.8, spec=0.2)
    pipe = np.maximum(glass, body)

    L = ak.Layer(N, N)
    solid = np.maximum(outer, leaves_a)
    L.over((3, 3, 4), ak.drop_shadow(solid, 0.6 * u, 1.2 * u, 1.5 * u, 0.7) * (1 - solid))
    L.over(gold_leaf, leaves_a)
    L.over((4, 3, 2), ak.drop_shadow(outer, 0.9 * u, 1.4 * u, 1.3 * u, 0.72) * (1 - outer) * leaves_a)
    L.over(gold_rim, rim)
    L.over(face, inner)
    L.over((0, 0, 0), np.clip(1 - ak.sdf(inner) / (3.4 * u), 0, 1) ** 2 * inner * 0.55)
    L.over((0, 0, 0), ak.drop_shadow(pipe, 0.5 * u, 0.8 * u, 0.7 * u, 0.5) * (1 - pipe) * inner)
    L.over((226, 240, 232), body * 0.20)
    L.over((9, 20, 15), ak.blur(soot, 1.1 * u) * body * 0.62)
    L.over((255, 118, 36), ak.blur(ember, 2.4 * u) * body * 0.92)
    L.add((255, 196, 120), ak.blur(ember, 0.8 * u) * body * 0.42)
    L.over((236, 241, 238), wisp * inner * 0.82)
    L.over(c_glass, glass)
    out = L.image(px, px)
    save_tga(out, os.path.join("art", "crest"))


def make_minimap():
    """Small version for the minimap: shield and pipe, heavier shapes, nothing fine. Masked to a
    circle in game, so it stays inside one."""
    px = 64
    N = px * 16
    u = N / 128.0

    def P(x, y):
        return (x * u, (y - 8) * u)

    def w(x):
        return x * u * 1.22
    cx = 64 * u
    top, half, bottom, shoulder = 12 * u, 46 * u, 124 * u, 58 * u
    outer = ak.Canvas(N, N).poly(shield_outline(cx, top, half, bottom, shoulder)).array()
    inner = ak.Canvas(N, N).poly(shield_outline(cx, top, half, bottom, shoulder, inset=7.0 * u)).array()
    rim = outer * (1 - inner)
    h_rim = ak.blur(ak.bevel(rim, 3.0 * u, 4.0 * u), 0.3 * u)
    gold_rim = ak.shade(h_rim, ak.GOLD, strength=1.1, base=0.58, gain=1.15, spec=0.5, shininess=26, seed=5)
    ys, xs = np.mgrid[0:N, 0:N].astype(np.float32)
    drift = (0.5 - (xs + ys) / (2.0 * N)) * 0.28
    dome = ak.blur(ak.bevel(inner, 30 * u, 5.0 * u, profile="smooth"), 10 * u)
    face = ak.shade(dome, lambda v: FACE_GREEN(np.clip(v + drift, 0, 1)), strength=1.0, base=0.50, gain=0.8, spec=0.1, shininess=12)
    glass, body, soot, ember, wisp = pipe_masks(N, P, w, wisp_w=3.2)
    c_glass = ak.shade(ak.blur(ak.bevel(glass, 3.0 * u, 2.2 * u), 0.3 * u), INK_WHITE, strength=1.0, base=0.58, gain=0.7, spec=0.1)
    L = ak.Layer(N, N)
    L.over(gold_rim, rim)
    L.over(face, inner)
    L.over((226, 240, 232), body * 0.20)
    L.over((9, 20, 15), ak.blur(soot, 1.5 * u) * body * 0.62)
    L.over((255, 118, 36), ak.blur(ember, 2.4 * u) * body * 0.95)
    L.add((255, 196, 120), ak.blur(ember, 1.0 * u) * body * 0.45)
    L.over((236, 241, 238), wisp * inner * 0.85)
    L.over(c_glass, glass)
    save_tga(L.image(px, px), "minimap")


def make_utility():
    # radial glow (tinted in game)
    W = 64 * SS
    g = Image.new("L", (W, W), 0)
    px = g.load()
    c = W / 2
    for y in range(W):
        for x in range(W):
            r = math.hypot(x - c + 0.5, y - c + 0.5) / c
            px[x, y] = int(255 * max(0.0, 1 - r) ** 2.2)
    img = Image.new("RGBA", (W, W), WHITE + (0,))
    img.putalpha(g)
    save_tga(img.resize((64, 64), Image.LANCZOS), "glow")

    # 9-slice soft shadow: a blurred rounded square, corners 16px
    W = 64 * SS
    m = Image.new("L", (W, W), 0)
    ImageDraw.Draw(m).rounded_rectangle((16 * SS, 16 * SS, W - 16 * SS, W - 16 * SS), radius=6 * SS, fill=255)
    m = m.filter(ImageFilter.GaussianBlur(6 * SS))
    img = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    img.putalpha(m)
    save_tga(img.resize((64, 64), Image.LANCZOS), "shadow")

    # tileable grain
    rnd = random.Random(42)
    img = Image.new("RGBA", (128, 128), (255, 255, 255, 0))
    px = img.load()
    for y in range(128):
        for x in range(128):
            v = rnd.random()
            px[x, y] = (255, 255, 255, int(v * v * 34))
    save_tga(img, "noise")

    # tileable hazard stripes (yellow/black, 45 degrees)
    W = 64
    img = Image.new("RGBA", (W, W))
    px = img.load()
    for y in range(W):
        for x in range(W):
            px[x, y] = HAZARD + (255,) if ((x + y) // 16) % 2 == 0 else (24, 24, 24, 255)
    save_tga(img, "hazard")

    # solid circle (status dots)
    W = 32 * SS
    m = Image.new("L", (W, W), 0)
    ImageDraw.Draw(m).ellipse((0, 0, W - 1, W - 1), fill=255)
    img = Image.new("RGBA", (W, W), WHITE + (0,))
    img.putalpha(m)
    save_tga(img.resize((32, 32), Image.LANCZOS), "circle")

    # rounded-rect fill for icon button hovers (corner radius 6 at 32px)
    W = 32 * SS
    m = rounded_mask((W, W), (0, 0, W - 1, W - 1), 6 * SS)
    img = Image.new("RGBA", (W, W), WHITE + (0,))
    img.putalpha(m)
    save_tga(img.resize((32, 32), Image.LANCZOS), "round6")


# --------------------------------------------------------------------------------------
# Line icon set (white, 32x32, tinted in game). Drawn on a 128 canvas, stroke 10.
# --------------------------------------------------------------------------------------
S = 128
STROKE = 11


def icon(name, fn):
    m = Image.new("L", (S, S), 0)
    d = ImageDraw.Draw(m)
    fn(d, m)
    img = Image.new("RGBA", (S, S), WHITE + (0,))
    img.putalpha(m)
    save_tga(img.resize((32, 32), Image.LANCZOS), "icon_" + name)


def arc(d, box, a0, a1, w=STROKE):
    d.arc(box, a0, a1, fill=255, width=w)


def line(d, pts, w=STROKE):
    d.line(pts, fill=255, width=w, joint="curve")
    for p in (pts[0], pts[-1]):
        d.ellipse((p[0] - w / 2 + 0.5, p[1] - w / 2 + 0.5, p[0] + w / 2 - 0.5, p[1] + w / 2 - 0.5), fill=255)


def i_roster(d, m):
    # back person
    d.ellipse((70, 14, 106, 50), fill=255)
    d.chord((56, 56, 122, 130), 180, 360, fill=255)
    # gap so the front person reads in front
    d.ellipse((22, 18, 72, 68), fill=0)
    d.chord((2, 62, 92, 152), 180, 360, fill=0)
    # front person
    d.ellipse((28, 24, 66, 62), fill=255)
    d.chord((8, 68, 86, 146), 180, 360, fill=255)


def i_calendar(d, m):
    d.rounded_rectangle((16, 26, 112, 112), radius=14, outline=255, width=STROKE)
    d.rectangle((16, 26, 112, 50), fill=255)
    for x in (42, 86):
        line(d, [(x, 12), (x, 34)])
    for (x, y) in ((40, 70), (64, 70), (88, 70), (40, 92), (64, 92)):
        d.ellipse((x - 6, y - 6, x + 6, y + 6), fill=255)


def i_dice(d, m):
    d.rounded_rectangle((18, 18, 110, 110), radius=20, outline=255, width=STROKE)
    for (x, y) in ((42, 42), (86, 42), (64, 64), (42, 86), (86, 86)):
        d.ellipse((x - 9, y - 9, x + 9, y + 9), fill=255)


def i_check(d, m):
    line(d, [(26, 66), (52, 92), (102, 36)], STROKE + 3)


def i_clipboard(d, m):
    d.rounded_rectangle((22, 22, 106, 116), radius=12, outline=255, width=STROKE)
    d.rounded_rectangle((44, 10, 84, 34), radius=8, fill=255)
    line(d, [(40, 72), (56, 88), (88, 56)])


def i_trophy(d, m):
    d.chord((30, 0, 98, 76), 0, 180, fill=255)
    d.rectangle((30, 14, 98, 38), fill=255)
    arc(d, (8, 18, 42, 58), 90, 270, STROKE - 2)
    arc(d, (86, 18, 120, 58), 270, 90, STROKE - 2)
    d.rectangle((56, 74, 72, 96), fill=255)
    d.rounded_rectangle((36, 96, 92, 114), radius=5, fill=255)


def i_hammer(d, m):
    d.polygon([(30, 22), (78, 22), (92, 36), (92, 50), (30, 50)], fill=255)
    line(d, [(60, 50), (60, 114)], STROKE + 3)


def i_flame(d, m):
    d.polygon([(64, 8), (88, 40), (98, 70), (92, 96), (64, 112), (36, 96), (30, 70), (42, 46), (52, 60)], fill=255)
    d.polygon([(64, 58), (76, 78), (72, 98), (56, 98), (52, 82)], fill=0)


def i_campfire(d, m):
    d.polygon([(64, 6), (84, 34), (90, 58), (80, 80), (64, 86), (48, 80), (38, 58), (48, 38), (56, 50)], fill=255)
    d.polygon([(64, 50), (72, 64), (70, 78), (58, 78), (56, 66)], fill=0)
    line(d, [(18, 116), (110, 94)], STROKE + 2)
    line(d, [(18, 94), (110, 116)], STROKE + 2)


def i_eye(d, m):
    d.chord((8, 30, 120, 126), 200, 340, fill=255)
    d.chord((8, 2, 120, 98), 20, 160, fill=255)
    d.chord((20, 40, 108, 116), 200, 340, fill=0)
    d.chord((20, 12, 108, 88), 20, 160, fill=0)
    d.ellipse((44, 44, 84, 84), fill=255)
    d.ellipse((58, 56, 70, 68), fill=0)


def i_gear(d, m):
    c = 64
    for i in range(8):
        a = i * math.pi / 4
        x, y = c + math.cos(a) * 46, c + math.sin(a) * 46
        d.regular_polygon((x, y, 13), 4, rotation=math.degrees(a) + 45, fill=255)
    d.ellipse((24, 24, 104, 104), fill=255)
    d.ellipse((46, 46, 82, 82), fill=0)


def i_close(d, m):
    line(d, [(32, 32), (96, 96)], STROKE + 2)
    line(d, [(96, 32), (32, 96)], STROKE + 2)


def i_search(d, m):
    d.ellipse((16, 16, 84, 84), outline=255, width=STROKE + 1)
    line(d, [(78, 78), (110, 110)], STROKE + 5)


def i_chev_down(d, m):
    line(d, [(32, 50), (64, 82), (96, 50)], STROKE + 2)


def i_chev_right(d, m):
    line(d, [(50, 32), (82, 64), (50, 96)], STROKE + 2)


def i_chev_left(d, m):
    line(d, [(78, 32), (46, 64), (78, 96)], STROKE + 2)


def i_plus(d, m):
    line(d, [(64, 24), (64, 104)], STROKE + 2)
    line(d, [(24, 64), (104, 64)], STROKE + 2)


def i_minus(d, m):
    line(d, [(24, 64), (104, 64)], STROKE + 2)


def star_pts(cx, cy, r1, r2):
    pts = []
    for i in range(10):
        a = -math.pi / 2 + i * math.pi / 5
        r = r1 if i % 2 == 0 else r2
        pts.append((cx + math.cos(a) * r, cy + math.sin(a) * r))
    return pts


def i_star(d, m):
    d.polygon(star_pts(64, 68, 56, 24), outline=255, width=STROKE - 2)


def i_star_fill(d, m):
    d.polygon(star_pts(64, 68, 56, 24), fill=255)


def i_crown(d, m):
    d.polygon([(14, 36), (40, 66), (64, 26), (88, 66), (114, 36), (104, 96), (24, 96)], fill=255)
    d.rounded_rectangle((24, 102, 104, 116), radius=4, fill=255)


def i_skull(d, m):
    d.ellipse((18, 10, 110, 96), fill=255)
    d.rounded_rectangle((38, 70, 90, 116), radius=10, fill=255)
    d.ellipse((34, 44, 58, 70), fill=0)
    d.ellipse((70, 44, 94, 70), fill=0)
    d.polygon([(64, 70), (56, 86), (72, 86)], fill=0)
    for x in (50, 64, 78):
        d.rectangle((x - 3, 100, x + 3, 116), fill=0)


def i_coin(d, m):
    d.ellipse((14, 14, 114, 114), outline=255, width=STROKE)
    d.ellipse((38, 38, 90, 90), fill=255)


def i_sync(d, m):
    arc(d, (20, 20, 108, 108), 200, 340)
    arc(d, (20, 20, 108, 108), 20, 160)
    d.polygon([(100, 26), (110, 60), (78, 50)], fill=255)
    d.polygon([(28, 102), (18, 68), (50, 78)], fill=255)


def i_bubble(d, m):
    d.rounded_rectangle((12, 18, 116, 88), radius=24, outline=255, width=STROKE)
    d.polygon([(34, 84), (34, 116), (64, 86)], fill=255)


def i_bell(d, m):
    d.chord((26, 14, 102, 90), 180, 360, fill=255)
    d.polygon([(26, 52), (102, 52), (114, 98), (14, 98)], fill=255)
    d.ellipse((52, 98, 76, 122), fill=255)


def i_warning(d, m):
    d.polygon([(64, 8), (122, 112), (6, 112)], fill=255)
    d.rounded_rectangle((57, 40, 71, 82), radius=5, fill=0)
    d.ellipse((56, 88, 72, 104), fill=0)


def i_shield(d, m):
    d.polygon([(64, 8), (112, 26), (106, 76), (64, 120), (22, 76), (16, 26)], fill=255)
    d.polygon([(64, 24), (96, 36), (92, 72), (64, 102)], fill=0)


def i_cross(d, m):
    d.rounded_rectangle((48, 12, 80, 116), radius=6, fill=255)
    d.rounded_rectangle((12, 48, 116, 80), radius=6, fill=255)


def i_sword(d, m):
    line(d, [(30, 98), (104, 24)], STROKE + 1)
    line(d, [(22, 74), (54, 106)], STROKE + 1)
    line(d, [(14, 114), (32, 96)], STROKE + 3)


def i_bow(d, m):
    arc(d, (-34, 6, 92, 122), 298, 62, STROKE)
    line(d, [(58, 12), (58, 116)], 5)
    line(d, [(12, 64), (104, 64)], STROKE - 3)
    d.polygon([(122, 64), (96, 48), (96, 80)], fill=255)
    d.polygon([(12, 64), (2, 52), (22, 52), (30, 64), (22, 76), (2, 76)], fill=255)


def i_home(d, m):
    d.polygon([(64, 12), (118, 60), (104, 60), (104, 114), (24, 114), (24, 60), (10, 60)], fill=255)
    d.rectangle((52, 78, 76, 114), fill=0)


def i_filter(d, m):
    d.polygon([(12, 18), (116, 18), (74, 66), (74, 112), (54, 100), (54, 66)], fill=255)


def i_trash(d, m):
    d.rounded_rectangle((26, 36, 102, 118), radius=8, fill=255)
    d.rectangle((14, 22, 114, 32), fill=255)
    d.rectangle((48, 10, 80, 22), fill=255)
    for x in (46, 64, 82):
        d.rectangle((x - 4, 50, x + 4, 104), fill=0)


def i_megaphone(d, m):
    d.polygon([(18, 48), (46, 48), (104, 16), (104, 112), (46, 80), (18, 80)], fill=255)
    d.rectangle((30, 80, 48, 112), fill=255)


def i_clock(d, m):
    d.ellipse((12, 12, 116, 116), outline=255, width=STROKE)
    line(d, [(64, 34), (64, 66), (88, 80)])


def i_lock(d, m):
    arc(d, (34, 10, 94, 76), 180, 360)
    d.rectangle((34, 42, 45, 56), fill=255)
    d.rectangle((83, 42, 94, 56), fill=255)
    d.rounded_rectangle((20, 54, 108, 118), radius=12, fill=255)
    d.ellipse((56, 72, 72, 88), fill=0)


def i_export(d, m):
    d.rounded_rectangle((16, 44, 112, 116), radius=10, outline=255, width=STROKE)
    d.rectangle((44, 38, 84, 52), fill=0)
    line(d, [(64, 82), (64, 14)])
    line(d, [(42, 36), (64, 14), (86, 36)])


def i_import(d, m):
    d.rounded_rectangle((16, 44, 112, 116), radius=10, outline=255, width=STROKE)
    d.rectangle((44, 38, 84, 52), fill=0)
    line(d, [(64, 14), (64, 82)])
    line(d, [(42, 60), (64, 82), (86, 60)])


def i_heart(d, m):
    d.ellipse((12, 18, 66, 72), fill=255)
    d.ellipse((62, 18, 116, 72), fill=255)
    d.polygon([(16, 56), (112, 56), (64, 114)], fill=255)


def i_bolt(d, m):
    d.polygon([(72, 6), (24, 72), (58, 72), (48, 122), (104, 50), (68, 50)], fill=255)


def i_dot(d, m):
    d.ellipse((34, 34, 94, 94), fill=255)


def i_ring(d, m):
    d.ellipse((30, 30, 98, 98), outline=255, width=STROKE)


def i_bag(d, m):
    arc(d, (40, 8, 88, 56), 180, 360)
    d.rounded_rectangle((18, 36, 110, 118), radius=16, fill=255)


def i_pin(d, m):
    d.ellipse((30, 8, 98, 76), fill=255)
    d.polygon([(34, 56), (94, 56), (64, 120)], fill=255)
    d.ellipse((52, 30, 76, 54), fill=0)


ICONS = {
    "roster": i_roster, "calendar": i_calendar, "dice": i_dice, "check": i_check,
    "clipboard": i_clipboard, "trophy": i_trophy, "hammer": i_hammer, "flame": i_flame,
    "campfire": i_campfire, "eye": i_eye, "gear": i_gear, "close": i_close, "search": i_search,
    "chevron_down": i_chev_down, "chevron_right": i_chev_right, "chevron_left": i_chev_left,
    "plus": i_plus, "minus": i_minus, "star": i_star, "star_fill": i_star_fill, "crown": i_crown,
    "skull": i_skull, "coin": i_coin, "sync": i_sync, "bubble": i_bubble, "bell": i_bell,
    "warning": i_warning, "shield": i_shield, "cross": i_cross, "sword": i_sword, "bow": i_bow,
    "home": i_home, "filter": i_filter, "trash": i_trash, "megaphone": i_megaphone,
    "clock": i_clock, "lock": i_lock, "export": i_export, "import": i_import, "heart": i_heart,
    "bolt": i_bolt, "dot": i_dot, "ring": i_ring, "bag": i_bag, "pin": i_pin,
}


def preview():
    """Contact sheet for eyeballing the set (not shipped)."""
    names = sorted(ICONS)
    cols = 12
    rows = (len(names) + cols - 1) // cols
    sheet = Image.new("RGBA", (cols * 48, rows * 48 + 400), (18, 24, 20, 255))
    for i, n in enumerate(names):
        ic = Image.open(os.path.join(OUT, "icon_" + n + ".tga"))
        sheet.alpha_composite(ic, ((i % cols) * 48 + 8, (i // cols) * 48 + 8))
    y = rows * 48 + 8
    for n in ("logo",):
        im = Image.open(os.path.join(OUT, n + ".tga"))
        sheet.alpha_composite(im, (8, y))
    sheet.alpha_composite(Image.open(os.path.join(OUT, "minimap.tga")), (530, y))
    sheet.alpha_composite(Image.open(os.path.join(OUT, "sign_yellow.tga")).resize((256, 64)), (300, y + 140))
    sheet.alpha_composite(Image.open(os.path.join(OUT, "welcome.tga")).resize((256, 128)), (8, y + 140))
    sheet.alpha_composite(Image.open(os.path.join(OUT, "hazard.tga")), (300, y + 220))
    return sheet


def make_icons():
    for n, fn in ICONS.items():
        icon(n, fn)


GROUPS = {
    "signs": [make_logo, make_signs],
    "crest": [make_crest, make_minimap],
    "utility": [make_utility],
    "icons": [make_icons],
}

if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    for group in sys.argv[1:] or list(GROUPS):
        for fn in GROUPS[group]:
            fn()
            print("made", fn.__name__)
    if not sys.argv[1:]:
        out = os.path.join(ROOT, "tools", "media_preview.png")
        preview().save(out)
        print("preview:", out)
