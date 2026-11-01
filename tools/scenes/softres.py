"""Soft Res: the servo at 4am, and the big freezer of ICE, limit two per customer. The queue goes halfway
up the street, half of it is shopping bags, and every bag's got a place in the line because someone's reserved."""
import numpy as np

from scenekit import STENCIL, SS, Scene, bez, gauss, gum_tree, hoodie, lettering, lit_rim, neon, smooth

GROUND = 140
LIGHT = "#d8eeff"
ICE = "#7fe0ff"
# the whole line stands in the gap between the page subtitle and the page buttons, where you can see it
QUEUE_TAIL, QUEUE_HEAD = 494, 622


def queue_y(x):
    """The line's footing: it starts at the freezer and wanders off up the forecourt."""
    t = np.clip((x - QUEUE_TAIL) / (QUEUE_HEAD - QUEUE_TAIL), 0, 1)
    return 127.5 + (GROUND - 127.5) * t + 1.2 * np.sin((x - 505) / 18)


def canopy(s, x0, x1):
    """The roof: a slab on two legs, a strip of lights under it, the word along the front."""
    m = s.mask()
    m.rect(x0, 54, x1, 78)
    m.rect(x0 + 34, 78, x0 + 41, GROUND)
    m.rect(x1 - 28, 78, x1 - 21, GROUND)
    s.paint(m, "#101826", rim=0.5, rim_dx=0, rim_dy=-0.8, rim_colour="#8fb4cc")
    fascia = s.mask()
    fascia.rect(x0 + 1, 56, x1 - 1, 74)
    s.paint(fascia, "#22344c")
    # strip lights along the underside
    t = s.mask()
    t.rect(x0 + 4, 77, x1 - 4, 79)
    a = t.array()
    s.rgb = s.rgb * (1 - a[..., None]) + s.colour("#f4fbff") * 1.2 * a[..., None]
    w = s.mask()
    lettering(w, "SERVO", (x0 + x1) / 2 + 8, 65, 13, font=STENCIL, spacing=4)
    s.paint(w, "#e6f2ff")
    s.rgb += gauss(w.array(), 2.2 * SS)[..., None] * s.colour("#9fd0ff") * 0.25


def pumps(s, xs):
    """Bowser, a hose, a lit little screen."""
    m = s.mask()
    for x in xs:
        m.rrect(x - 7, 104, x + 7, 136, 1.0)
        m.rect(x - 11, 136, x + 11, 140)
        m.stroke(bez((x + 7, 112), (x + 16, 118), (x + 8, 128), n=8), 0.8, 0.8)
    s.paint(m, "#121a26", rim=0.5, rim_dx=0, rim_dy=-0.8, rim_colour=LIGHT)
    g = s.mask()
    for x in xs:
        g.rect(x - 4.5, 108, x + 4.5, 114)
    s.paint(g, "#c8e8ff")


def freezer(s, x0, x1, top, base):
    """The point of the picture. A box the size of a Commodore stood on its end, its header lit up in
    letters as tall as a wheelie bin, the sign under it trying to keep things civil."""
    cx = (x0 + x1) / 2
    m = s.mask()
    m.rrect(x0, top, x1, base, 1.6)
    s.paint(m, "#0e1420", rim=0.7, rim_dx=0, rim_dy=-0.8, rim_colour=LIGHT)
    # the glass doors, cold, with the bags stacked up behind them
    g = s.mask()
    g.rect(x0 + 3, top + 54, x1 - 3, base - 2)
    s.paint(g, "#1d4258")
    b = s.mask()
    for row, y in enumerate((base - 3, base - 9)):
        for k in range(6):
            bx = x0 + 9 + k * (x1 - x0 - 18) / 5 + (3 if row else 0)
            if bx < x1 - 6:
                b.rrect(bx - 5.4, y - 6, bx + 5.4, y, 2)
    s.rgb += (b.array() * g.array())[..., None] * s.colour("#9fd8ee") * 0.32
    j = s.mask()
    j.rect(cx - 0.6, top + 54, cx + 0.6, base - 2)
    s.paint(j, "#0e1420")
    # the lights go on first, so their bloom doesn't wash out the fine print
    neon(s, "ICE", cx, top + 15, 25, colour=ICE, strength=1.15, spacing=1.2)
    # the sign, up on the roof of the thing where the page buttons can't get it
    p = s.mask()
    p.rect(x0 + 2, top - 13.5, x1 - 2, top - 1)
    p.rect(x0 + 8, top - 1.2, x0 + 10, top + 0.4)
    p.rect(x1 - 10, top - 1.2, x1 - 8, top + 0.4)
    s.paint(p, "#f4e24a")
    t = s.mask()
    lettering(t, "LIMIT 2 PER CUSTOMER", cx, top - 7.2, 6.6, font=STENCIL, spacing=0.0)
    s.paint(t, "#141006")


def plastic_bag(m, stripe, x, base, h):
    """A shopping bag holding its owner's spot, handles up, sat exactly where a person would stand.
    That's the reservation."""
    w = h * 0.46
    body = base - h * 0.68
    m.spoly([(x - w * 1.08, base), (x - w, body), (x + w, body), (x + w * 1.08, base)])
    # one handle, a proper loop, so it can't be anything else
    m.stroke(bez((x - w * 0.5, body + 0.5), (x - w * 0.5, base - h * 1.08), (x + w * 0.5, base - h * 1.08), (x + w * 0.5, body + 0.5), n=14), max(1.0, h * 0.06), max(1.0, h * 0.06))
    # the band round its belly, and the sag in one side
    stripe.rect(x - w * 1.1, base - h * 0.34, x + w * 1.1, base - h * 0.2)
    stripe.stroke(np.array([(x + w * 0.42, body), (x + w * 0.56, base - h * 0.36)]), h * 0.03, h * 0.02)


def plate_bloke(m, x, base, h):
    """One bloke in full plate, standing in line for ice in the car park like it's a perfectly normal
    thing to wear at four in the morning. Which, round here, it nearly is."""
    def P(u, v):
        return (x + u * h, base - v * h)
    for u0, u1 in ((-0.05, -0.12), (0.05, 0.12)):
        m.stroke(np.array([P(u0, 0.5), P(u1, 0.03)]), h * 0.13, h * 0.11)
        m.spoly([P(u1 - 0.07, 0), P(u1 - 0.06, 0.07), P(u1 + 0.07, 0.07), P(u1 + 0.12, 0)])
    m.spoly([P(-0.17, 0.84), P(0.18, 0.84), P(0.14, 0.45), P(-0.14, 0.45)])
    m.spoly([P(-0.16, 0.5), P(0.16, 0.5), P(0.2, 0.3), P(-0.2, 0.3)])
    for u, r in ((-0.2, 0.15), (0.2, 0.135)):
        cx, cy = P(u, 0.84)
        m.ellipse(cx, cy, r * h, r * h * 0.82)
        for ang in (-0.6, 0.0, 0.6):
            d = np.array([np.sin(ang), -np.cos(ang)])
            n = np.array([d[1], -d[0]])
            c = np.array([cx, cy]) + d * r * h * 0.6
            m.spoly([tuple(c + n * r * h * 0.3), tuple(np.array([cx, cy]) + d * r * h * 1.8), tuple(c - n * r * h * 0.3)])
    m.ellipse(*P(0.02, 0.94), h * 0.09, h * 0.1)
    m.stroke(bez(P(-0.04, 0.99), P(-0.14, 1.02), P(-0.13, 1.14), n=8), h * 0.05, h * 0.012)
    m.stroke(bez(P(0.08, 0.99), P(0.18, 1.02), P(0.17, 1.14), n=8), h * 0.05, h * 0.012)
    m.stroke(np.array([P(-0.21, 0.78), P(-0.23, 0.5)]), h * 0.09, h * 0.08)
    m.stroke(np.array([P(0.2, 0.78), P(0.22, 0.5)]), h * 0.09, h * 0.08)
    # a sword on his back, because you never know
    m.stroke(np.array([P(-0.34, 0.2), P(0.06, 1.2)]), h * 0.036, h * 0.022)
    m.stroke(np.array([P(-0.16, 0.86), P(-0.05, 0.8)]), h * 0.06, h * 0.06)


def paint():
    s = Scene("night", seed=23, horizon=118)
    s.sky(clouds=0.3, stars=0.9, glow_x=0.64, glow_w=0.2)
    s.moon(628, 30, 19, tint="#f0ecdc", glow=0.45, seed=3)
    s.moon(682, 17, 8, tint="#a9c6ff", glow=0.42, seed=9)

    # the suburb, asleep or pretending
    s.ridge(113, 10, 41, "#12283f", roughness=4)
    m = s.mask()
    for x, w, h in ((548, 42, 13), (600, 34, 11), (648, 48, 14), (706, 34, 11)):
        m.spoly([(x, 124), (x, 124 - h * 0.6), (x + w * 0.25, 124 - h), (x + w * 0.75, 124 - h), (x + w, 124 - h * 0.6), (x + w, 124)])
    for i, x in enumerate((330, 410, 480)):
        gum_tree(m, x, 124, 30 + (i * 31) % 18, seed=60 + i, leaves=0.9)
    m.rect(0, 121, 1040, 148)
    s.paint(m, "#0a1524", rim=0.10)
    s.fog(100, 124, strength=0.2, seed=6)

    # the forecourt: concrete, dark at the far end, blown out under the canopy
    ground = s.mask()
    ground.spoly([(0, 148)] + [(x, 123.5 + 0.4 * np.sin(x / 50)) for x in range(0, 1042, 10)] + [(1040, 148)])
    s.paint(ground, "#0a1018")
    ga = ground.array()
    X, Y = s.X / SS, s.Y / SS
    pool = np.exp(-(((X - 900) / 150) ** 2)) * smooth(120, 142, Y)
    s.rgb += (ga * pool)[..., None] * s.colour(LIGHT) * 0.58

    # the shop at the back, all window, no one in it that you can see
    m = s.mask()
    m.rect(844, 86, 1014, 130)
    s.paint(m, "#0d1420")
    w = s.mask()
    w.rect(866, 92, 950, 122)
    wa = w.array()
    s.rgb = s.rgb * (1 - wa[..., None]) + s.colour("#b9dcf2") * 0.72 * wa[..., None]
    s.rgb += gauss(wa, 8 * SS)[..., None] * s.colour("#b9dcf2") * 0.16
    b = s.mask()
    for x in (887, 908, 929):
        b.rect(x, 92, x + 0.9, 122)
    s.paint(b, "#0d1420")

    # the light coming down off the roof
    for x in (850, 905, 960):
        s.beam(x, 79, 90, 26, 60, colour=LIGHT, strength=0.15, soft=2.4)
    canopy(s, 826, 1022)
    pumps(s, (896, 962))

    # the queue, back to front so the near ones sit over the far ones
    qx = (622, 601, 575, 548, 530, 511, 494)
    kinds = ("hoodie", "bag", "plate", "bag", "hoodie", "bag", "hoodie")
    # shadows first: the line throws them back along itself, away from the light
    sh = s.mask()
    for x in qx:
        by = float(queue_y(x))
        sh.spoly([(x - 8, by + 0.2), (x + 8, by + 0.2), (x - 7, by + 2.2), (x - 24, by + 2.2)])
    s.rgb *= (1 - gauss(sh.array(), 0.5 * SS) * 0.5)[..., None]

    # the bags sit in their own little pool, so the eye goes to the hole in the line
    for x, k in zip(qx, kinds):
        if k == "bag":
            by = float(queue_y(x))
            pool = np.exp(-(((s.X / SS - x) / 15) ** 2 + ((s.Y / SS - by) / 3) ** 2))
            s.rgb += pool[..., None] * s.colour("#c4e4f8") * 0.13

    bags, bands = s.mask(), s.mask()
    folk = s.mask()
    for x, k in reversed(list(zip(qx, kinds))):
        by = float(queue_y(x))
        scale = 0.72 + 0.28 * (by - 127.5) / (GROUND - 127.5)
        if k == "hoodie":
            hoodie(folk, x, by, 56 * scale, facing=1)
        elif k == "plate":
            plate_bloke(folk, x, by, 52 * scale)
        else:
            plastic_bag(bags, bands, x, by, 25 * scale)
    s.paint(folk, "#070b12")
    lit_rim(s, folk, 790, 85, 340, LIGHT, 1.25, soft=0.3)
    s.paint(bags, "#b5c8d4", bottom="#6c8496", top_y=70, rim=0.45, rim_dx=0.7, rim_dy=-0.6, rim_colour="#ffffff")
    s.rgb = s.rgb * (1 - (bands.array() * bags.array())[..., None] * 0.72) + (bands.array() * bags.array())[..., None] * s.colour("#23405e") * 0.72

    # the freezer last, with the bloom on everything
    freezer(s, 724, 814, 64, GROUND)

    # the gums: one framing the canopy, and a dark one for the title
    m = s.mask()
    gum_tree(m, 1036, 176, 150, seed=21, lean=-0.04, spread=0.9)
    gum_tree(m, 236, 176, 170, seed=12, lean=0.06)
    s.paint(m, "#03040a")
    # the title's side of the picture stays low and calm
    s.rgb *= (0.44 + 0.56 * smooth(430 * SS, 540 * SS, s.X))[..., None]
    return s.finish(bloom=0.3, vignette=0.14)
