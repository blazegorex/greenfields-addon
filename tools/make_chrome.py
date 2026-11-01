"""Generates the Warcraft-style chrome textures in Greenfields/Media (no AI, all procedural).

    python -P tools/make_chrome.py            # everything
    python -P tools/make_chrome.py buttons    # one group (see GROUPS at the bottom)

Metal, enamel and stone are lit from a height field (tools/artkit.py), so all of it shares one
light from the top-left. Most art here is double density: 2 texels per UI unit. Theme.lua's
T.nine lists how each sliced texture is cut. Sizes are powers of two.

    frame_window   256  forged window rail, gold lips and a dark channel (margin 64)
    frame_corners  512  four gum-leaf corner pieces in one atlas, each lit the same way
    panel_card     128  default raised panel: soft shadow, fine bronze edge (margin 40)
    panel_inset     64  carved well for inputs and inner tiles (margin 16)
    panel_gold     256  feature panel: slim gold rim with leaf tips (margin 64)
    btn_*           64  buttons: lit bezel over a painted face (margin 16); btn_hl is the hover
    tag             64  pill, a tinted fill with a brighter rim, white so it takes any colour
    pill            64  solid white stadium (margin 16)
    toggle_*        64  switch track and knob
    bar_track, bar_fill  progress bar parts
    ring_metal      64  avatar ring, grey so class colour tints it
    icon_frame, icon_frame_gold, icon_frame_white  64  bezels drawn over game icons
    paper_edge      64  the darkened edge on a sheet of parchment (margin 16)
    parchment      256  aged paper, the one light material
    shine           64  soft light sweep (additive)
    window_bg      512  the night behind everything (low detail: it stretches)
    leather        256  faint tiling material
"""
import math
import os
import sys

import cv2
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from artkit import (  # noqa: E402
    BRONZE, DARKBRONZE, GOLD, IRON, Canvas, Layer, bevel, bezier, blur, drop_shadow, enamel, fbm_noise, hexc,
    leaf_outline, ramp, ribbon, sdf, shade)
from make_media import OUT, save_tga  # noqa: E402
from scipy import ndimage as ndi  # noqa: E402

SS = 4
EMERALD = ramp((0, "#021a0e"), (0.28, "#07452a"), (0.50, "#0f8a53"), (0.72, "#37c784"), (0.90, "#a8f0cb"), (1, "#eafff4"))


def rrect(N, x0, y0, x1, y1, r):
    return Canvas(N, N).rrect(x0, y0, x1, y1, r).array()


def rrect2(w, h, x0, y0, x1, y1, r):
    return Canvas(w, h).rrect(x0, y0, x1, y1, r).array()


# --------------------------------------------------------------------------- window frame
def make_frame_window():
    """Forged rail: outer gold lip, recessed dark channel, inner hairline lip, then a soft shadow
    falling on whatever sits inside. Centre is empty."""
    px = 256
    N = px * SS
    U = N / 128.0  # big pixels per UI unit (2 texels per UI unit)
    edge = lambda a: rrect(N, a * U, a * U, N - a * U, N - a * U, max(0.4, 3.2 - a * 0.22) * U)
    o0, o1, o2, o3 = edge(0.4), edge(2.6), edge(8.0), edge(9.4)
    lip_out = o0 * (1 - o1)
    channel = o1 * (1 - o2)
    lip_in = o2 * (1 - o3)
    gold = np.maximum(lip_out, lip_in)
    h_gold = np.maximum(bevel(lip_out, 1.05 * U, 1.8 * U), bevel(lip_in, 0.65 * U, 1.1 * U))
    h_chan = bevel(channel, 0.8 * U, 0.55 * U)
    c_gold = shade(blur(h_gold, 0.1 * U), GOLD, strength=1.15, base=0.58, gain=1.25, spec=0.55, shininess=34,
                   grain=0.16, seed=5, wear=0.4)
    c_chan = shade(h_chan, DARKBRONZE, strength=1.1, base=0.34, gain=1.0, spec=0.22, grain=1.0, seed=9, sheen=0.05)
    L = Layer(N, N)
    # shadow from the rail onto the page, heavier on top where the light comes from
    inner = o3
    d = np.clip(sdf(inner) / (10 * U), 0, 1)
    fall = (1 - d) ** 2.2
    L.over((3, 4, 7), fall * inner * 0.62)
    L.over(c_chan, channel)
    L.over(c_gold, gold)
    save_tga(L.image(px, px), "frame_window")


def corner_masks(N, U):
    """One corner (top-left) as parts: boss plate, gum-leaf sprays, ribs, gem, socket, rivets."""
    def spray(flip):
        def P(x, y):
            return (y * U, x * U) if flip else (x * U, y * U)
        c = Canvas(N, N)
        ribs = []
        stem = bezier(P(21, 5.6), P(44, 2.6), P(86, 5.2), n=80)
        c.poly(ribbon(stem, np.linspace(1.9 * U, 0.45 * U, 80)))
        # gum leaves: long sickles, two drooping past the rail, two lying along it
        for (x0, y0, cx, cy, x1, y1, w) in (
                (28.5, 5.0, 40.0, 16.5, 56.0, 13.5, 6.0),
                (37.0, 4.2, 48.0, 0.2, 61.0, 2.8, 4.2),
                (47.0, 4.0, 59.0, 12.5, 73.0, 10.2, 4.9),
                (58.0, 4.4, 68.0, 1.4, 82.0, 3.2, 3.5)):
            mid, poly = leaf_outline(P(x0, y0), P(cx, cy), P(x1, y1), w * U, n=64)
            c.poly(poly)
            ribs.append(mid)
        # gumnuts near the boss
        nuts = Canvas(N, N)
        for (x, y, r) in ((25.6, 11.0, 2.1), (29.6, 14.0, 1.75)):
            nuts.circle(*P(x, y), r * U)
        return c.array(), ribs, nuts.array()

    a, ra, na = spray(False)
    b, rb, nb = spray(True)
    leaves = np.maximum(a, b)
    nuts = np.maximum(na, nb)
    boss = Canvas(N, N).rrect(0.5 * U, 0.5 * U, 23.5 * U, 23.5 * U, 4.2 * U).array()
    # spurs: the plate tapers away along the rail on both arms
    sp = Canvas(N, N)
    sp.poly([(20 * U, 0.5 * U), (41 * U, 2.8 * U), (20 * U, 8.6 * U)])
    sp.poly([(0.5 * U, 20 * U), (2.8 * U, 41 * U), (8.6 * U, 20 * U)])
    boss = np.maximum(boss, sp.array())
    scoop = Canvas(N, N).circle(32.5 * U, 32.5 * U, 12.8 * U).array()
    boss = boss * (1 - scoop)
    socket = Canvas(N, N).circle(12.2 * U, 12.2 * U, 7.7 * U).array()
    ring = Canvas(N, N).circle(12.2 * U, 12.2 * U, 9.3 * U).array() * (1 - socket)
    pts = []
    for i in range(8):
        ang = math.pi / 8 + i * math.pi / 4
        pts.append((12.2 * U + 6.5 * U * math.cos(ang), 12.2 * U + 6.5 * U * math.sin(ang)))
    gem = Canvas(N, N).poly(pts).array()
    table = Canvas(N, N).poly([(12.2 * U + (p[0] - 12.2 * U) * 0.56, 12.2 * U + (p[1] - 12.2 * U) * 0.56) for p in pts]).array()
    rib = Canvas(N, N)
    for m in ra + rb:
        rib.poly(ribbon(m[6:-8], 0.34 * U))
    return leaves, nuts, boss, ring, socket, gem, table, rib.array()


def facets(N, U, cx, cy, r):
    """Hand-lit emerald: each facet gets its own tone from its facing, so it stays jewel-clear."""
    img = np.zeros((N, N, 3), np.float32)
    alpha = Canvas(N, N)
    base = [(cx + r * math.cos(math.pi / 8 + i * math.pi / 4), cy + r * math.sin(math.pi / 8 + i * math.pi / 4)) for i in range(8)]
    tab = [(cx + (x - cx) * 0.56, cy + (y - cy) * 0.56) for (x, y) in base]
    lx, ly = -0.55, -0.74
    for i in range(8):
        j = (i + 1) % 8
        m = Canvas(N, N).poly([base[i], base[j], tab[j], tab[i]]).array()
        mx = (base[i][0] + base[j][0]) / 2 - cx
        my = (base[i][1] + base[j][1]) / 2 - cy
        ln = math.hypot(mx, my)
        facing = (mx / ln * lx + my / ln * ly)
        v = 0.47 + facing * 0.34
        c = EMERALD(np.array([[v]], np.float32))[0, 0]
        img = img * (1 - m[..., None]) + c * m[..., None]
        alpha.poly([base[i], base[j], tab[j], tab[i]])
    # table: deep centre, lighter toward the far edge where light passes through
    ys, xs = np.mgrid[0:N, 0:N].astype(np.float32)
    t = ((xs - cx) * 0.55 + (ys - cy) * 0.74) / (r * 0.56)
    tv = 0.40 + np.clip(t, -1, 1) * 0.20
    tc = EMERALD(tv)
    tm = Canvas(N, N).poly(tab).array()
    img = img * (1 - tm[..., None]) + tc * tm[..., None]
    alpha.poly(tab)
    return img, alpha.array()


def make_corners():
    px = 256
    N = px * SS
    U = N / 96.0
    leaves, nuts, boss, ring, socket, gem, table, ribs = corner_masks(N, U)
    h_boss = bevel(boss, 1.9 * U, 3.4 * U)
    h_ring = bevel(ring, 0.8 * U, 1.3 * U)
    h_leaf = bevel(leaves, 1.25 * U, 2.9 * U) - blur(ribs, 0.09 * U) * 0.85 * U
    h_nuts = bevel(nuts, 1.0 * U, 2.0 * U)
    # rivets on the plate's outer corners
    riv = Canvas(N, N)
    for (x, y) in ((3.7, 3.7), (20.6, 3.3), (3.3, 20.6)):
        riv.circle(x * U, y * U, 0.85 * U)
    h_riv = bevel(riv.array(), 0.7 * U, 0.8 * U)
    height = np.maximum.reduce([h_leaf, h_boss, h_nuts])
    height = np.where(ring > 0.5, h_boss + h_ring * 0.7, height)
    height = height + h_riv * (boss > 0.5)
    height = blur(height, 0.13 * U)
    solid = np.maximum.reduce([leaves, nuts, boss])
    atlas = np.zeros((px * 2, px * 2, 4), np.uint8)
    for qx, qy, fx, fy in ((0, 0, False, False), (1, 0, True, False), (0, 1, False, True), (1, 1, True, True)):
        def F(a):
            if fx:
                a = a[:, ::-1]
            if fy:
                a = a[::-1, :]
            return a.copy()
        H, A, S = F(height), F(solid), F(socket)
        G, T, = F(gem), F(table)
        ys, xs = np.mgrid[0:N, 0:N].astype(np.float32)
        # broad light across the piece so the plate isn't one flat tone
        drift = (0.5 - (xs + ys) / (2.0 * N)) * 0.13
        col = shade(H, lambda v: GOLD(np.clip(v + drift, 0, 1)), strength=1.2, base=0.55, gain=1.2, spec=0.5, shininess=30,
                    grain=0.45, seed=3 + qx + qy * 2, ao_radius=1.6 * U, ao=0.05, wear=0.8, sheen=0.08)
        L = Layer(N, N)
        L.over((5, 4, 3), drop_shadow(A, 0.65 * U, 0.95 * U, 1.3 * U, 0.72) * (1 - A))
        L.over(col, A)
        # socket and gem
        L.over((6, 5, 4), S)
        scx = (N - 12.2 * U) if fx else 12.2 * U
        scy = (N - 12.2 * U) if fy else 12.2 * U
        L.over((0, 0, 0), np.clip(1 - sdf(S) / (1.6 * U), 0, 1) * S * 0.75)
        gi, ga = facets(N, U, scx, scy, 6.5 * U)
        L.over(gi, ga)
        # small sharp glint up-left of the table, a touch of glow low-right
        gl = Canvas(N, N).circle(scx - 1.9 * U, scy - 2.2 * U, 0.62 * U).array()
        L.add((255, 255, 255), blur(gl, 0.16 * U) * 0.92)
        im = np.asarray(L.image(px, px))
        atlas[qy * px:(qy + 1) * px, qx * px:(qx + 1) * px] = im
    from PIL import Image
    save_tga(Image.fromarray(atlas, "RGBA"), "frame_corners")


# --------------------------------------------------------------------------- panels
def panel(px, margin_ui, radius, shadow_ui, fill_top, fill_mid, fill_bottom, fill_alpha, rim_ramp, rim_w, top_glow=0.0, name=None):
    """Raised panel at 2 texels per UI unit: optional soft shadow outside, a lit edge, a fill that
    catches a little light along the top. Everything inside the margins stays flat."""
    N = px * SS
    U = N / (px / 2.0)
    s = shadow_ui * U
    outer = rrect(N, s, s, N - s, N - s, radius * U)
    inner = rrect(N, s + rim_w * U, s + rim_w * U, N - s - rim_w * U, N - s - rim_w * U, max(0, radius - rim_w) * U)
    rim = outer * (1 - inner)
    ys = np.arange(N, dtype=np.float32) / N
    # the fill's light lives in the top margin only, so it doesn't stretch with the panel
    margin = (margin_ui * U) / N
    t1 = np.clip((ys - shadow_ui * U / N) / max(1e-6, margin - shadow_ui * U / N), 0, 1)
    b1 = np.clip((ys - (1 - margin)) / margin, 0, 1)
    top, mid, bot = (np.array(hexc(c), np.float32) for c in (fill_top, fill_mid, fill_bottom))
    fill = np.zeros((N, 3), np.float32)
    for i in range(3):
        fill[:, i] = top[i] + (mid[i] - top[i]) * (t1 ** 0.8)
        fill[:, i] = fill[:, i] + (bot[i] - fill[:, i]) * b1
    fill = np.broadcast_to(fill[:, None, :], (N, N, 3))
    L = Layer(N, N)
    if shadow_ui > 0:
        sh = blur(outer, shadow_ui * 0.55 * U)
        L.over((2, 3, 6), sh * 0.55 * (1 - outer))
    L.over(fill, inner * fill_alpha)
    if top_glow > 0:
        hl = rrect(N, s + rim_w * U, s + rim_w * U, N - s - rim_w * U, s + (rim_w + 0.9) * U, max(0, radius - rim_w) * U)
        L.over((255, 232, 190), hl * inner * top_glow)
    if rim_ramp is not None:
        h = bevel(rim, rim_w * 0.5 * U, rim_w * U, profile="round")
        col = shade(h, rim_ramp, strength=1.0, base=0.52, gain=1.45, spec=0.2, shininess=18)
        L.over(col, rim)
    img = L.image(px, px)
    if name:
        save_tga(img, name)
    return img


def make_panels():
    # default card: fine lit bronze edge, a soft drop, faint warm light along the top
    panel(128, 20, 3.0, 6, "#1e2636", "#121823", "#0e131c", 0.93, DARKBRONZE, 1.0, top_glow=0.055, name="panel_card")

    # carved well: no rim of its own, dark, inner shadow on top, faint catch-light along the bottom
    N = 64 * SS
    U = N / 32.0
    o = rrect(N, 0.5 * U, 0.5 * U, N - 0.5 * U, N - 0.5 * U, 2.4 * U)
    L = Layer(N, N)
    L.over((7, 9, 13), o * 0.93)
    d = np.clip(sdf(o) / (3.2 * U), 0, 1)
    ys, xs = np.mgrid[0:N, 0:N].astype(np.float32)
    topness = np.clip(1 - ys / (N * 0.5), 0, 1)
    L.over((0, 0, 0), (1 - d) ** 2 * o * (0.30 + topness * 0.45))
    edge = o * (1 - rrect(N, 1.1 * U, 1.1 * U, N - 1.1 * U, N - 1.1 * U, 1.8 * U))
    # light catches the lower lip, the upper lip stays in shadow: reads as carved in
    lo = np.clip((ys / N - 0.55) * 4.0, 0, 1)
    L.over((176, 150, 110), edge * lo * 0.34)
    L.over((0, 0, 0), edge * (1 - lo) * 0.55)
    save_tga(L.image(64, 64), "panel_inset")

    make_panel_gold()


def make_panel_gold():
    """Feature panel: slim gold rim, dark fill, a small gum-leaf tip on each corner. All four corners
    share the texture, so the light stays consistent."""
    px = 256
    N = px * SS
    U = N / 128.0
    s = 7.0  # UI units of soft shadow outside
    outer = rrect(N, s * U, s * U, N - s * U, N - s * U, 3.6 * U)
    inner = rrect(N, (s + 2.4) * U, (s + 2.4) * U, N - (s + 2.4) * U, N - (s + 2.4) * U, 1.6 * U)
    rim = outer * (1 - inner)
    # corner tips: two leaves each way, mirrored around all four corners
    tips = Canvas(N, N)
    ribs = Canvas(N, N)
    for (fx, fy) in ((1, 1), (-1, 1), (1, -1), (-1, -1)):
        def P(x, y, swap=False):
            if swap:
                x, y = y, x
            return (N / 2 + fx * (x * U - N / 2), N / 2 + fy * (y * U - N / 2))
        for swap in (False, True):
            for (x0, y0, cx, cy, x1, y1, w) in ((s + 2.0, s + 1.0, s + 9.0, s + 8.0, s + 20.0, s + 6.0, 3.2),
                                                (s + 6.0, s + 1.2, s + 13.0, s - 1.6, s + 24.0, s + 0.8, 2.5)):
                mid, poly = leaf_outline(P(x0, y0, swap), P(cx, cy, swap), P(x1, y1, swap), w * U, n=44)
                tips.poly(poly)
                ribs.poly(ribbon(mid[4:-5], 0.24 * U))
        tips.circle(*P(s + 1.6, s + 1.6), 3.0 * U)
    tips_a, ribs_a = tips.array(), ribs.array()
    h = np.maximum(bevel(rim, 1.1 * U, 2.0 * U), bevel(tips_a, 0.85 * U, 2.1 * U) - blur(ribs_a, 0.08 * U) * 0.55 * U)
    h = blur(h, 0.09 * U)
    solid = np.maximum(rim, tips_a)
    col = shade(h, GOLD, strength=1.2, base=0.56, gain=1.25, spec=0.5, shininess=30, grain=0.3, seed=12, wear=0.5, sheen=0.06)
    ys = np.arange(N, dtype=np.float32) / N
    margin = 32 * U / N
    t1 = np.clip((ys - s * U / N) / max(1e-6, margin - s * U / N), 0, 1)
    top, mid = np.array(hexc("#2a2c32"), np.float32), np.array(hexc("#151a24"), np.float32)
    fill = np.zeros((N, 3), np.float32)
    for i in range(3):
        fill[:, i] = top[i] + (mid[i] - top[i]) * (t1 ** 0.8)
    fill = np.broadcast_to(fill[:, None, :], (N, N, 3))
    L = Layer(N, N)
    L.over((2, 3, 6), blur(outer, s * 0.55 * U) * 0.65 * (1 - outer))
    L.over(fill, outer * 0.95)
    L.over((4, 3, 2), drop_shadow(solid, 0.4 * U, 0.6 * U, 0.8 * U, 0.6) * (1 - solid) * outer)
    L.over(col, solid)
    save_tga(L.image(px, px), "panel_gold")


# --------------------------------------------------------------------------- buttons
BUTTONS = {
    "btn_green": ("#1c8f58", "#0f7244", "#095332", GOLD),
    "btn_dark": ("#2c3444", "#1a202c", "#121722", BRONZE),
    "btn_red": ("#b53a33", "#7f1f1c", "#5a1311", GOLD),
    "btn_gold": ("#e3b652", "#b98a2f", "#8a6119", BRONZE),
}


def make_buttons():
    px = 64
    N = px * SS
    U = N / 32.0
    outer = rrect(N, 0.25 * U, 0.25 * U, N - 0.25 * U, N - 0.25 * U, 3.2 * U)
    face = rrect(N, 1.75 * U, 1.75 * U, N - 1.75 * U, N - 1.75 * U, 1.8 * U)
    rim = outer * (1 - face)
    h_rim = blur(bevel(rim, 0.72 * U, 1.3 * U), 0.05 * U)
    ys = np.arange(N, dtype=np.float32) / N
    t = np.clip((ys - 0.06) / 0.88, 0, 1)
    for name, (hi, mid, lo, metal) in BUTTONS.items():
        a, b, c = (np.array(hexc(x), np.float32) for x in (hi, mid, lo))
        # slicing keeps the middle of this ramp, so the button stays lit top to bottom at any height
        col = np.zeros((N, 3), np.float32)
        for i in range(3):
            col[:, i] = np.where(t < 0.5, a[i] + (b[i] - a[i]) * (t / 0.5), b[i] + (c[i] - b[i]) * ((t - 0.5) / 0.5))
        col = np.broadcast_to(col[:, None, :], (N, N, 3))
        L = Layer(N, N)
        L.over((3, 3, 5), outer)
        L.over(col, face)
        # top catch-light and a low inner shade, so the face looks slightly domed
        d = np.clip(sdf(face) / (1.6 * U), 0, 1)
        yy = np.broadcast_to(ys[:, None], (N, N))
        L.over((255, 255, 255), (1 - d) ** 2 * face * np.clip(1 - yy * 2.6, 0, 1) * 0.42)
        L.over((0, 0, 0), (1 - d) ** 2 * face * np.clip((yy - 0.45) * 1.8, 0, 1) * 0.45)
        L.over(shade(h_rim, metal, strength=1.15, base=0.54, gain=1.25, spec=0.5, shininess=26, grain=0.2, seed=4), rim)
        save_tga(L.image(px, px), name)
    # hover: soft inner light, white so it can be added over any face
    L = Layer(N, N)
    d = np.clip(sdf(face) / (6.5 * U), 0, 1)
    L.over((255, 255, 255), (1 - d) ** 1.6 * face * 0.55 + face * 0.07)
    save_tga(L.image(px, px), "btn_hl")


# --------------------------------------------------------------------------- tags, pills, toggles, bars
def make_tags():
    px = 64
    N = px * SS
    U = N / 32.0
    o = rrect(N, 0.4 * U, 0.4 * U, N - 0.4 * U, N - 0.4 * U, 8 * U)
    i = rrect(N, 1.25 * U, 1.25 * U, N - 1.25 * U, N - 1.25 * U, 7.2 * U)
    L = Layer(N, N)
    # the fill is a dark grey: tinted, it's a deep shade of the colour, solid enough to read over a
    # moon. The rim is white, so it takes the colour at full strength.
    ys = np.broadcast_to((np.arange(N, dtype=np.float32) / N)[:, None], (N, N))
    L.over((62, 62, 62), i * 0.88)
    L.over((255, 255, 255), o * (1 - i) * (0.86 - ys * 0.3))
    save_tga(L.image(px, px), "tag")
    L = Layer(N, N)
    L.over((255, 255, 255), rrect(N, 0.25 * U, 0.25 * U, N - 0.25 * U, N - 0.25 * U, 8 * U))
    save_tga(L.image(px, px), "pill")


def make_toggle():
    # TGA has no mipmaps, so art shouldn't go much past 2 texels per UI unit: shown at 36 x 18
    W, H = 64 * SS, 32 * SS
    U = W / 36.0
    o = rrect2(W, H, 0.3 * U, 0.3 * U, W - 0.3 * U, H - 0.3 * U, 8.7 * U)
    i = rrect2(W, H, 1.45 * U, 1.45 * U, W - 1.45 * U, H - 1.45 * U, 7.5 * U)
    rim = o * (1 - i)
    h = blur(bevel(rim, 0.65 * U, 1.0 * U), 0.05 * U)
    ys = np.broadcast_to((np.arange(H, dtype=np.float32) / H)[:, None], (H, W))
    for name, top, bot, metal, glow in (("toggle_on", "#0a4c2f", "#127a4a", GOLD, (82, 240, 150)),
                                        ("toggle_off", "#07090e", "#141923", DARKBRONZE, None)):
        a, b = np.array(hexc(top), np.float32), np.array(hexc(bot), np.float32)
        col = np.dstack([a[c] + (b[c] - a[c]) * ys for c in range(3)])
        L = Layer(W, H)
        L.over((3, 3, 5), o)
        L.over(col, i)
        d = np.clip(sdf(i) / (2.4 * U), 0, 1)
        L.over((0, 0, 0), (1 - d) ** 2 * i * np.clip(1.05 - ys * 1.4, 0, 1) * 0.72)
        if glow:
            L.over(glow, np.exp(-(((ys - 0.72) / 0.28) ** 2)) * i * 0.20)
        L.over(shade(h, metal, strength=1.1, base=0.52, gain=1.25, spec=0.45, shininess=26, grain=0.2, seed=8), rim)
        save_tga(L.image(64, 32), name)
    # knob: a small domed metal bead, shown at about 14 UI
    N = 32 * SS
    U2 = N / 14.0
    m = Canvas(N, N).circle(N / 2, N / 2, 6.7 * U2).array()
    h = bevel(m, 6.7 * U2, 6.0 * U2)
    for name, metal, base in (("toggle_knob_on", GOLD, 0.60), ("toggle_knob_off", IRON, 0.58)):
        L = Layer(N, N)
        L.over(shade(h, metal, strength=0.28, base=base, gain=0.85, spec=0.75, shininess=44), m)
        save_tga(L.image(32, 32), name)


def make_bars():
    # track: a shallow groove, sliced (texel margin 16, shown at 4 UI)
    N = 64 * SS
    U = N / 16.0
    o = rrect(N, 0.15 * U, 0.15 * U, N - 0.15 * U, N - 0.15 * U, 3.6 * U)
    ys, xs = np.mgrid[0:N, 0:N].astype(np.float32)
    L = Layer(N, N)
    L.over((5, 6, 10), o * 0.82)
    d = np.clip(sdf(o) / (1.6 * U), 0, 1)
    L.over((0, 0, 0), (1 - d) ** 2 * o * np.clip(1.1 - ys / N * 1.8, 0, 1) * 0.75)
    edge = o * (1 - rrect(N, 0.65 * U, 0.65 * U, N - 0.65 * U, N - 0.65 * U, 3.1 * U))
    L.over((168, 146, 110), edge * np.clip((ys / N - 0.55) * 4, 0, 1) * 0.30)
    save_tga(L.image(64, 64), "bar_track")
    # fill: white, tinted in game; a band of light on top and a darker foot make it read round
    px_w, px_h = 8, 32
    v = np.linspace(0, 1, px_h, dtype=np.float32)
    lum = 0.70 + 0.30 * np.exp(-((v - 0.22) / 0.16) ** 2) - 0.32 * np.clip((v - 0.55) / 0.45, 0, 1) ** 1.2
    arr = np.zeros((px_h, px_w, 4), np.uint8)
    arr[..., :3] = np.clip(lum[:, None, None] * 255, 0, 255).astype(np.uint8)
    arr[..., 3] = 255
    from PIL import Image
    save_tga(Image.fromarray(arr, "RGBA"), "bar_fill")


# --------------------------------------------------------------------------- rings, icon frames
def make_ring():
    N = 64 * SS
    U = N / 128.0
    c = N / 2
    o = Canvas(N, N).circle(c, c, 62.5 * U).array()
    i = Canvas(N, N).circle(c, c, 52.0 * U).array()
    ring = o * (1 - i)
    h = blur(bevel(ring, 5.2 * U, 7.5 * U), 0.5 * U)
    # neutral metal, so class colour shows through as coloured metal when tinted
    grey = ramp((0, "#0d0d0d"), (0.25, "#3d3d3d"), (0.5, "#8c8c8c"), (0.72, "#c8c8c8"), (0.9, "#f0f0f0"), (1, "#ffffff"))
    col = shade(h, grey, strength=1.1, base=0.60, gain=1.2, spec=0.6, shininess=30, grain=0.3, seed=3)
    L = Layer(N, N)
    # shadow falling inward over the portrait
    d = np.clip(sdf(i) / (15 * U), 0, 1)
    L.over((0, 0, 0), (1 - d) ** 2 * i * 0.6)
    L.over(col, ring)
    save_tga(L.image(64, 64), "ring_metal")


def icon_frame(name, metal, base=0.5):
    N = 64 * SS
    U = N / 128.0
    o = rrect(N, 1.5 * U, 1.5 * U, N - 1.5 * U, N - 1.5 * U, 9 * U)
    i = rrect(N, 10.5 * U, 10.5 * U, N - 10.5 * U, N - 10.5 * U, 4 * U)
    rim = o * (1 - i)
    h = blur(bevel(rim, 4.2 * U, 7 * U), 0.4 * U)
    L = Layer(N, N)
    d = np.clip(sdf(i) / (13 * U), 0, 1)
    L.over((0, 0, 0), (1 - d) ** 2 * i * 0.72)
    L.over((4, 3, 2), rim)
    L.over(shade(h, metal, strength=1.1, base=base, gain=1.25, spec=0.45, shininess=26, grain=0.3, seed=6, wear=0.25), rim)
    save_tga(L.image(64, 64), name)


GREY = ramp((0, "#0d0d0d"), (0.25, "#3d3d3d"), (0.5, "#8c8c8c"), (0.72, "#c8c8c8"), (0.9, "#f0f0f0"), (1, "#ffffff"))


def make_icon_frames():
    icon_frame("icon_frame", BRONZE, 0.42)
    icon_frame("icon_frame_gold", GOLD, 0.56)
    icon_frame("icon_frame_white", GREY, 0.62)   # tinted by item quality in game


# --------------------------------------------------------------------------- gems
def make_shine():
    """The light sweep: a soft diagonal band with no edge to it, gentle enough to pass over text."""
    from PIL import Image
    S = 64
    ys, xs = np.mgrid[0:S, 0:S].astype(np.float32)
    d = (xs - S * 0.5) + (ys - S * 0.5) * 0.36
    a = np.exp(-(d / (S * 0.16)) ** 2) * 0.62
    # gone by the edges, so a clipped sweep never shows a line
    a *= np.clip(np.minimum(xs, S - 1 - xs) / 8.0, 0, 1)
    arr = np.dstack((np.full((S, S, 3), 255, np.float32), a * 255)).astype(np.uint8)
    save_tga(Image.fromarray(arr, "RGBA"), "shine")


def make_gem():
    N = 64 * SS
    U = N / 32.0
    c = N / 2
    L = Layer(N, N)
    ring = Canvas(N, N).circle(c, c, 15 * U).array()
    h = bevel(ring, 2.2 * U, 2.6 * U)
    L.over(shade(h, GOLD, strength=1.2, base=0.5, gain=1.25, spec=0.45), ring)
    gi, ga = facets(N, U, c, c, 12.2 * U)
    L.over(gi, ga)
    gl = Canvas(N, N).circle(c - 3.6 * U, c - 4.3 * U, 1.25 * U).array()
    L.add((255, 255, 255), blur(gl, 0.3 * U) * 0.9)
    save_tga(L.image(64, 64), "gem_green")


# --------------------------------------------------------------------------- materials
def make_window_bg():
    """The night behind the whole window: low-frequency colour pools and a vignette. It stretches,
    so there's no fine detail in it. Grain goes on top in game."""
    S = 512
    ys, xs = np.mgrid[0:S, 0:S].astype(np.float32) / S
    n = fbm_noise(S, S, 7, cells=2, octaves=3)
    base = np.array(hexc("#0a0f18"), np.float32)
    teal = np.array(hexc("#12222e"), np.float32)
    deep = np.array(hexc("#06080d"), np.float32)
    plum = np.array(hexc("#1a1626"), np.float32)
    rgb = np.ones((S, S, 3), np.float32) * base
    # light falls from the top and pools right of centre
    pool = np.exp(-(((xs - 0.62) / 0.55) ** 2 + ((ys - 0.05) / 0.62) ** 2))
    rgb = rgb + (teal - base) * (pool * 0.85)[..., None]
    rgb = rgb + (plum - base) * (n * np.clip(ys * 1.2, 0, 1) * 0.28)[..., None]
    fall = np.clip((ys - 0.35) / 0.65, 0, 1) ** 1.3
    rgb = rgb + (deep - rgb) * (fall * 0.7)[..., None]
    v = np.sqrt(((xs - 0.5) / 0.74) ** 2 + ((ys - 0.48) / 0.74) ** 2)
    rgb = rgb * (1 - np.clip(v - 0.42, 0, 1) ** 1.6 * 0.95)[..., None]
    from PIL import Image
    rng = np.random.default_rng(1)
    rgb = rgb + (rng.random((S, S, 3), dtype=np.float32) - 0.5) * 1.1
    arr = np.dstack((np.clip(rgb, 0, 255), np.full((S, S), 255, np.float32))).astype(np.uint8)
    save_tga(Image.fromarray(arr, "RGBA"), "window_bg")


def tile_normal_lit(h, strength, material_lo, material_hi, ambient=0.65):
    """Tileable lit material: wraps while differentiating so seams don't show."""
    gx = (np.roll(h, -1, axis=1) - np.roll(h, 1, axis=1)) * 0.5
    gy = (np.roll(h, -1, axis=0) - np.roll(h, 1, axis=0)) * 0.5
    nx, ny = -gx * strength, -gy * strength
    nz = np.ones_like(h)
    ln = np.sqrt(nx * nx + ny * ny + nz * nz)
    ndl = (nx * -0.52 + ny * -0.70 + nz * 0.60) / ln
    v = np.clip(ambient * 0.5 + (ndl - 0.60) * 1.2 + h * 0.35, 0, 1)
    lo, hi = np.array(hexc(material_lo), np.float32), np.array(hexc(material_hi), np.float32)
    return lo + (hi - lo) * v[..., None]


def make_paper():
    from PIL import Image
    S = 256
    # paper: long soft fibres over slow blotches, warm but not bright, so it doesn't glare at night
    n = fbm_noise(S, S, 31, cells=3, octaves=5, tile=True)
    blot = fbm_noise(S, S, 41, cells=2, octaves=3, tile=True)
    fib = fbm_noise(S, S, 51, cells=24, octaves=3, tile=True)
    h = n * 0.9 + fib * 0.35
    col = tile_normal_lit(h * 2.2, 0.5, "#a98d62", "#e8d6a8", ambient=1.1)
    col = col * (0.90 + blot[..., None] * 0.14)
    save_tga(Image.fromarray(np.dstack((np.clip(col, 0, 255), np.full((S, S), 255, np.float32))).astype(np.uint8), "RGBA"), "parchment")
    # edge: scorched toward the outside, gone by the middle
    N = 64 * SS
    U = N / 32.0
    o = rrect(N, 0.25 * U, 0.25 * U, N - 0.25 * U, N - 0.25 * U, 1.5 * U)
    d = np.clip(sdf(o) / (6 * U), 0, 1)
    L = Layer(N, N)
    L.over((64, 38, 14), (1 - d) ** 2.2 * o * 0.62)
    edge = o * (1 - rrect(N, 1.0 * U, 1.0 * U, N - 1.0 * U, N - 1.0 * U, 1.0 * U))
    L.over((58, 40, 20), edge * 0.95)
    save_tga(L.image(64, 64), "paper_edge")


def make_materials():
    from PIL import Image
    S = 256
    # leather: a fine pebble grain and nothing broad. Lit from the side, anything big reads as a stain.
    rng = np.random.default_rng(21)
    seeds = np.ones((S * 3, S * 3), bool)
    cx, cy = rng.integers(0, S, 1500), rng.integers(0, S, 1500)
    for ox in range(3):
        for oy in range(3):
            seeds[cy + oy * S, cx + ox * S] = False
    d = ndi.distance_transform_edt(seeds).astype(np.float32)[S:2 * S, S:2 * S]
    peb = 1 - np.clip(d / 4.5, 0, 1) ** 1.5
    wrap = lambda a, sigma: cv2.GaussianBlur(np.tile(a, (3, 3)), (0, 0), sigma)[S:2 * S, S:2 * S]
    h = wrap(peb, 0.7)
    col = tile_normal_lit(h * 1.6, 0.6, "#0b0d12", "#34353c")
    save_tga(Image.fromarray(np.dstack((col, np.full((S, S), 255, np.float32))).astype(np.uint8), "RGBA"), "leather")


GROUPS = {
    "frame": [make_frame_window, make_corners],
    "panels": [make_panels],
    "buttons": [make_buttons],
    "tags": [make_tags],
    "toggle": [make_toggle],
    "bars": [make_bars],
    "ring": [make_ring],
    "icons": [make_icon_frames],
    "gem": [make_gem],
    "shine": [make_shine],
    "bg": [make_window_bg],
    "materials": [make_materials],
    "paper": [make_paper],
}

if __name__ == "__main__":
    names = sys.argv[1:] or list(GROUPS)
    for n in names:
        for fn in GROUPS[n]:
            fn()
            print("made", fn.__name__)
