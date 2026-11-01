"""Loot Log: closing time at the pawnbroker, and someone's wheeled a dragon's hoard down in a stolen
trolley to see what they'll give him for it. Receipts weren't kept."""
import numpy as np

from scenekit import SS, STENCIL, Scene, bez, boards, gauss, gum_tree, hoodie, lettering, lit_rim, neon, smooth, trolley

# night, with the bottom of the sky stained pink by the sign
NIGHT = {"sky": [(0.00, "#04081a"), (0.34, "#0a1230"), (0.56, "#1a1c4a"), (0.72, "#2e2052"),
                 (0.86, "#57285f"), (1.00, "#8a3a6c")],
         "far": "#2a2450", "mid": "#10233c", "near": "#060b16", "rim": "#ff8fc0", "haze": "#7a3a78"}
PINK = "#ff3b8f"
WARM = "#ffb27a"
GOLD = "#ffb648"


def shopfront(s, x0, x1, top, base):
    """Brick-and-render strip of shops, flat-roofed, with the parapet stepping down at the dead one."""
    m = s.mask()
    m.spoly([(x0, base), (x0, top + 3), (x0 + 4, top), (904, top), (904, top + 5), (x1, top + 5), (x1, base)])
    s.paint(m, "#17122a", bottom="#0b0916", top_y=top - 10, rim=0.3, rim_dx=0, rim_dy=-0.8, rim_colour="#ff8fc0")
    # the awning's shadow line, and the footing
    b = s.mask()
    b.rect(x0, 84, x1, 86.4)
    b.rect(x0, 132, 803, 140)
    s.paint(b, "#07060e")


def window_stock(s, x0, y0, x1, y1):
    """The barred window. Everything in it is someone's: guitar, telly, sword and shield, all in black
    against a sour pink shop light."""
    w = s.mask()
    w.rect(x0, y0, x1, y1)
    s.paint(w, "#4c2044", bottom="#240e2a", top_y=y0 - 40)
    a = w.array()
    t = s.mask()
    # guitar on a lean: two-lobed body, neck, a headstock, and the hole in it
    gx, gy = x0 + 21, y1 - 11
    t.ellipse(gx, gy, 10, 8.5)
    t.ellipse(gx + 2, gy - 11, 7, 6.2)
    t.stroke(np.array([(gx + 2, gy - 14), (gx + 6.5, y0 + 5)]), 2.8, 2.2)
    t.stroke(np.array([(gx + 6.5, y0 + 6), (gx + 7.4, y0 + 0.5)]), 4.2, 3.8)
    t.ellipse(gx + 1, gy - 5.5, 2.6, 2.6, fill=0)
    # a real telly, with a back on it, and rabbit ears
    tv0, tv1 = x0 + 41, x0 + 72
    t.rrect(tv0, y1 - 25, tv1, y1, 2)
    t.rrect(tv0 + 3, y1 - 22, tv1 - 8, y1 - 3, 2.5, fill=0)
    t.ellipse(tv1 - 4, y1 - 18, 1.6, 1.6, fill=0)
    t.ellipse(tv1 - 4, y1 - 11, 1.6, 1.6, fill=0)
    t.line([((tv0 + tv1) / 2, y1 - 25), (tv0 + 5, y0 + 2)], 0.9)
    t.line([((tv0 + tv1) / 2, y1 - 25), (tv1 - 5, y0 + 3)], 0.9)
    # the sword, priced to move
    sx = x0 + 83
    t.spoly([(sx - 2.4, y0 + 13), (sx + 2.4, y0 + 13), (sx + 2.2, y1 - 6), (sx, y1 - 1), (sx - 2.2, y1 - 6)])
    t.rrect(sx - 8.5, y0 + 10.4, sx + 8.5, y0 + 13.4, 1)
    t.rect(sx - 1.3, y0 + 3.4, sx + 1.3, y0 + 11)
    t.ellipse(sx, y0 + 3.2, 2.6, 2.6)
    # and the shield that came with it
    hx = x0 + 105
    pts = [(hx - 11, y0 + 11), (hx + 11, y0 + 11)]
    pts += bez((hx + 11, y0 + 11), (hx + 11.5, y1 - 14), (hx + 6, y1 - 6), (hx, y1 - 1), n=10).tolist()
    pts += bez((hx, y1 - 1), (hx - 6, y1 - 6), (hx - 11.5, y1 - 14), (hx - 11, y0 + 11), n=10).tolist()
    t.spoly(pts)
    t.ellipse(hx, y0 + 20, 3.4, 3.4, fill=0)
    ta = t.array() * a
    s.rgb = s.rgb * (1 - ta[..., None]) + s.colour("#0b0612") * ta[..., None]
    # bars, wide apart so the stock reads through them
    b = s.mask()
    b.rect(x0 - 1.6, y0 - 1.6, x1 + 1.6, y0 + 0.8)
    b.rect(x0 - 1.6, y1 - 0.8, x1 + 1.6, y1 + 1.6)
    b.rect(x0 - 1.6, y0, x0 + 0.4, y1)
    b.rect(x1 - 0.4, y0, x1 + 1.6, y1)
    for xx in np.arange(x0 + 11, x1 - 2, 15.0):
        b.rect(xx - 0.45, y0, xx + 0.45, y1)
    s.paint(b, "#05040a")
    s.rgb += gauss(a, 6 * SS)[..., None] * s.colour(PINK) * 0.10


def roller_door(s, x0, x1, y0, gap_y, base):
    """Half up: the slats stop at gap_y and there's warm light under them. Someone's still in there."""
    li = s.mask()
    li.rect(x0, gap_y, x1, base)
    s.paint(li, "#1c0e0a", bottom="#40281a", top_y=gap_y - 74)
    d = s.mask()
    d.rect(x0 - 2, y0 - 2, x1 + 2, y0 + 3)
    d.rect(x0, y0, x1, gap_y)
    d.rect(x0 - 2, y0, x0, base)
    d.rect(x1, y0, x1 + 2, base)
    s.paint(d, "#120f1e", bottom="#0a0914", top_y=y0 - 40)
    r = s.mask()
    for yy in np.arange(y0 + 5, gap_y, 3.4):
        r.line([(x0, yy), (x1, yy)], 0.4)
    s.rgb += r.array()[..., None] * s.colour("#6a4a70") * 0.5
    edge = s.mask()
    edge.rect(x0, gap_y - 1.2, x1, gap_y)
    s.paint(edge, "#04030a", rim=0.8, rim_dx=0, rim_dy=0.8, rim_colour=WARM)
    # it falls out across the footpath and reaches back along the road
    s.glow((x0 + x1) / 2, base - 8, 44, colour=WARM, strength=0.04)
    pool = np.exp(-(((s.X / SS - (x0 + x1) / 2) / 62) ** 2 + ((s.Y / SS - 141) / 3.2) ** 2))
    s.rgb += (pool * 0.14)[..., None] * s.colour(WARM)


def mound(s, x0, x1, top, y):
    """Heap of gold: a soft hill with a slightly lumpy top. Returns its mask."""
    m = s.mask()
    pts = [(x0, y)]
    n = 44
    rng = np.random.default_rng(11)
    for i in range(n + 1):
        t = i / n
        x = x0 + (x1 - x0) * t
        h = (y - top) * (np.sin(np.pi * t) ** 0.62)
        pts.append((x, y - h + rng.uniform(-0.45, 0.45)))
    pts.append((x1, y))
    m.spoly(pts)
    return m


def swords(s, pts):
    """Swords shoved in point-down, hilts sticking out of the pile at whatever angle they landed."""
    m = s.mask()
    for (x, y, ang, L) in pts:
        c, sn = np.cos(ang), np.sin(ang)
        d = np.array([c, sn])
        n = np.array([-sn, c])
        p = np.array([x, y], float)
        hilt = p + d * L
        m.spoly([p - n * 1.5, p + n * 1.5, hilt + n * 1.3, hilt - n * 1.3])
        m.stroke(np.array([hilt - n * 5.4, hilt + n * 5.4]), 2.0, 2.0)
        m.stroke(np.array([hilt, hilt + d * 6.0]), 1.6, 1.6)
        m.ellipse(*(hilt + d * 7), 1.7, 1.7)
    s.paint(m, "#6b5a50", rim=1.1, rim_dx=0.2, rim_dy=-0.9, rim_colour="#ffe0a0")
    return m


def treasure(s, x0, x1, floor_y, rim_y):
    """The chest on its hill of gold, lid thrown back: the one gold thing in the picture, and it glows."""
    tcx = (x0 + x1) / 2
    top = rim_y - 11
    s.glow(tcx, rim_y - 6, 40, "#ff9d2e", 0.12)
    s.glow(tcx, rim_y - 6, 22, "#ffb648", 0.22)
    swords(s, [(tcx - 16, rim_y - 3, np.radians(-120), 19), (tcx + 18, rim_y - 3, np.radians(-58), 25)])
    heap = mound(s, x0, x1, top, floor_y)
    s.paint(heap, "#e09a2c", bottom="#a4661a", top_y=rim_y - 90)

    cw, ch = 30, 13
    cx0, cy1 = tcx - cw / 2, rim_y - 3
    box_top = cy1 - ch
    # the lid stands open behind the box: a domed slab, dark inside
    lid = s.mask()
    lid.spoly([(cx0 + 1, box_top + 1)] + [tuple(q) for q in bez((cx0 + 1, box_top + 1), (cx0 + 0.5, box_top - 13), (cx0 + 8, box_top - 13.5), n=12)]
              + [tuple(q) for q in bez((cx0 + cw - 8, box_top - 13.5), (cx0 + cw - 0.5, box_top - 13), (cx0 + cw - 1, box_top + 1), n=12)])
    s.paint(lid, "#2a170c", bottom="#3a2210", top_y=box_top - 90)
    lit_rim(s, lid, tcx, box_top + 6, 34, "#ffd070", 1.0, soft=0.3)

    # the brimming gold, in behind the front wall
    inner = s.mask()
    pts = [(cx0 + 0.6, box_top + 1)]
    for t in np.linspace(0, 1, 30):
        x = cx0 + 0.6 + (cw - 1.2) * t
        pts.append((x, box_top - 7 * np.sin(np.pi * t) ** 0.7 + 0.4 * np.sin(t * 37)))
    pts.append((cx0 + cw - 0.6, box_top + 1))
    inner.spoly(pts)
    s.paint(inner, "#ffd058", bottom="#f09a24", top_y=box_top - 85)

    # coins before the chest's front goes on, so they only land on gold
    rng = np.random.default_rng(17)
    coins, hot = s.mask(), s.mask()
    heap_a, in_a = heap.array(), inner.array()
    placed = 0
    while placed < 130:
        x = rng.uniform(x0, x1)
        y = rng.uniform(box_top - 9, floor_y)
        px, py = int(x * SS), int(y * SS)
        if heap_a[py, px] > 0.5 or in_a[py, px] > 0.5:
            r = rng.uniform(0.7, 1.25)
            coins.ellipse(x, y, r, r * 0.62)
            if rng.random() < 0.12:
                hot.ellipse(x, y - 0.2, r * 0.45, r * 0.3)
            placed += 1
    ca = coins.array()
    s.rgb = s.rgb * (1 - 0.30 * ca[..., None]) + ca[..., None] * s.colour("#ffdc78") * 0.5
    ha = hot.array()
    s.rgb += ha[..., None] * s.colour("#fff4c8") * 0.8 + gauss(ha, 0.6 * SS)[..., None] * s.colour("#ffdc90") * 0.6

    chest = s.mask()
    chest.rrect(cx0, box_top, cx0 + cw, cy1, 0.8)
    s.paint(chest, "#4a2c16", bottom="#2a170c", top_y=cy1 - 80)
    bands = s.mask()
    for bx in (cx0 + 5, cx0 + cw - 7):
        bands.rect(bx, box_top, bx + 2, cy1)
    bands.rect(cx0, box_top, cx0 + cw, box_top + 1.5)
    bands.rect(tcx - 2.2, box_top + 1.2, tcx + 2.2, box_top + 6.2)
    s.paint(bands, "#e0a22e")
    s.glow(tcx, box_top - 4, 12, "#ffd070", 0.20)


def paint():
    s = Scene(NIGHT, seed=33, horizon=118)
    s.sky(clouds=0.5, stars=1.0, glow_x=0.68, glow_w=0.25)
    s.moon(640, 27, 16, tint="#f6efdc", glow=0.5, seed=3)
    s.moon(684, 15, 8, tint="#a9c6ff", glow=0.42, seed=9)
    s.ridge(108, 18, 51, "#2a2450", roughness=4)
    s.fog(92, 120, strength=0.26)

    # far gums, out the back of the shops
    m = s.mask()
    for i, x in enumerate((300, 360, 476, 530)):
        gum_tree(m, x, 126, 40 + (i * 37) % 22, seed=80 + i, leaves=0.9)
    m.rect(0, 122, 1040, 148)
    s.paint(m, "#0e1230", rim=0.08)

    # the road
    road = s.mask()
    road.spoly([(0, 138), (240, 137), (520, 138.5), (800, 138), (1040, 138), (1040, 148), (0, 148)])
    s.paint(road, "#05050e")

    top, base = 50, 140
    shopfront(s, 556, 1012, top, 138.5)
    window_stock(s, 566, 89, 692, 131)
    roller_door(s, 806, 902, 88, 119, 139)

    # next door shut for good
    m = s.mask()
    m.rect(916, 92, 1000, 132)
    s.paint(m, "#08070f")
    m = s.mask()
    boards(m, 916, 92, 84, 40, n=4, seed=4)
    s.paint(m, "#1d1626", rim=0.15, rim_dx=0, rim_dy=-0.5, rim_colour="#ff8fc0")

    # the sign, which is the only thing on this street that's never been broken
    neon(s, "CA$H 4 LOOT", 648, 68, 18, colour=PINK, strength=0.62, spacing=1.0, core=0.55)
    m = s.mask()
    lettering(m, "NO RECEIPTS", 904, 70, 13, font=STENCIL, spacing=0.8)
    s.paint(m, "#9c94a8")

    # ---- him: the trolley stays left of the door, clear of the buttons, and pointing at the light
    tx, h = 796, 45
    bar = (tx - 1.16 * h, base - 1.0 * h)
    treasure(s, tx - 1.0 * h + 1, tx - 0.1 * h, base - 0.36 * h, base - 0.78 * h)
    m = s.mask()
    trolley(m, tx, base, h, facing=1, width=1.05)
    s.paint(m, "#0a0a14")
    lit_rim(s, m, tx - 0.5 * h, base - 0.6 * h, 40, "#ffc060", 0.65, soft=0.25)

    hx = bar[0] - 21
    m = s.mask()
    hoodie(m, hx, base, 60, facing=1, slouch=0.13, hands="free")
    sh = (hx + 6.5, base - 60 * 0.79)
    for off in (0.0, 1.8):
        m.stroke(bez((sh[0] - off, sh[1] + off), (sh[0] + 7, sh[1] + 7), (bar[0] - 7, bar[1] + 5), (bar[0], bar[1] + off * 0.4), n=12), 4.4, 3.0)
    s.paint(m, "#05060e")
    lit_rim(s, m, tx - 0.5 * h, base - 0.8 * h, 56, "#ffb860", 0.65, soft=0.3)
    lit_rim(s, m, 648, 60, 90, PINK, 0.36, soft=0.3)

    # what's dropped off the back on the way down, which nobody's going back for
    c = s.mask()
    for cx, cy, r in ((bar[0] + 3, 126, 1.5), (bar[0] - 3, 134, 1.4), (bar[0] - 8, 141, 1.7), (hx - 18, 141.5, 1.6),
                      (hx - 40, 142, 1.5), (hx - 72, 141.6, 1.3)):
        c.ellipse(cx, cy, r, r * (0.55 if cy > 140 else 1.0))
    ca = c.array()
    s.rgb += ca[..., None] * s.colour("#ffd068") * 1.4 + gauss(ca, 1.0 * SS)[..., None] * s.colour(GOLD) * 1.1

    # the framing gums; the title's side stays dark
    m = s.mask()
    gum_tree(m, 1036, 176, 165, seed=21, lean=-0.04, spread=0.9)
    gum_tree(m, 236, 176, 170, seed=12, lean=0.06)
    s.paint(m, "#02040a")
    s.rgb *= (0.50 + 0.50 * smooth(430 * SS, 560 * SS, s.X))[..., None]
    return s.finish(bloom=0.16)
