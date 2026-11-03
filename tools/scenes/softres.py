"""Soft Res: the servo at 4am, and the big freezer of ICE, limit two per customer. The queue goes halfway
up the street, half of it is bags of ice, and every bag's got a place in the line because someone's reserved."""
import numpy as np

from scenekit import STENCIL, SS, Scene, bez, gauss, gum_tree, lettering, lit_rim, neon, smooth

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


def limb(m, pts, widths, cap=True):
    """A sleeve or a leg through its joints, tapered, one clean outline with a proper corner at the bend."""
    pts = [np.array(p, float) for p in pts]
    left, right = [], []
    for i, p in enumerate(pts):
        d0 = pts[i] - pts[i - 1] if i else pts[1] - pts[0]
        d1 = pts[i + 1] - pts[i] if i < len(pts) - 1 else d0
        d0, d1 = d0 / np.linalg.norm(d0), d1 / np.linalg.norm(d1)
        t = d0 + d1
        t /= max(1e-6, np.linalg.norm(t))
        n = np.array([-t[1], t[0]])
        k = min(1.45, 1 / max(0.3, float(np.dot(n, np.array([-d0[1], d0[0]])))))
        left.append(tuple(p + n * widths[i] / 2 * k))
        right.append(tuple(p - n * widths[i] / 2 * k))
    m.spoly(left + right[::-1])
    if cap:
        m.ellipse(pts[0][0], pts[0][1], widths[0] / 2, widths[0] / 2)


def ice_bag(s, x, base, w, h, seed=1, shadow=True):
    """A bag of servo ice holding its owner's spot, sat exactly where a person would stand. That's the
    reservation. Clear plastic gone square and slumped under the weight, twisted off at the top, the cubes
    showing through it. w and h are the whole bag, frill and all; it's cold, so it doesn't glow."""
    hw = w / 2
    bh = h * 0.72  # the body; the rest is the neck and the frill
    if shadow:
        sh = s.mask()
        sh.ellipse(x - hw * 0.28, base + 0.3, hw * 1.42, max(1.0, h * 0.075))
        s.rgb *= (1 - sh.array() * 0.72)[..., None]
    top = base - bh
    pts = bez((x - hw * 0.86, base), (x - hw * 1.1, base - bh * 0.3), (x - hw * 1.06, base - bh * 0.8), (x - hw * 0.82, top + bh * 0.07), n=12).tolist()
    pts += bez((x - hw * 0.82, top + bh * 0.07), (x - hw * 0.55, top - bh * 0.02), (x - hw * 0.22, top - bh * 0.02), (x - hw * 0.13, top - bh * 0.1), n=8).tolist()
    pts += bez((x + hw * 0.13, top - bh * 0.1), (x + hw * 0.24, top - bh * 0.02), (x + hw * 0.6, top + bh * 0.0), (x + hw * 0.88, top + bh * 0.12), n=8).tolist()
    pts += bez((x + hw * 0.88, top + bh * 0.12), (x + hw * 1.1, base - bh * 0.7), (x + hw * 1.1, base - bh * 0.26), (x + hw * 0.88, base), n=12).tolist()
    pts += bez((x + hw * 0.88, base), (x + hw * 0.3, base + 0.5), (x - hw * 0.3, base + 0.5), (x - hw * 0.86, base), n=8).tolist()
    body = s.mask()
    body.spoly(pts)
    ba = body.array()
    al = (ba * 0.8)[..., None]
    s.rgb = s.rgb * (1 - al) + s.colour("#4a6272") * al
    # the cubes, in a settled heap: full to the shoulder, some paler, none of them lined up
    rng = np.random.default_rng(seed)
    cube = w * 0.17
    dark, pale = s.mask(), s.mask()
    y = base - cube * 0.62
    row = 0
    while y > top + bh * 0.26:
        cx = x - hw * 0.92 + (cube * 0.55 if row % 2 else 0) + rng.uniform(-0.2, 0.2) * cube
        while cx < x + hw * 0.98:
            r = cube * 0.5 * rng.uniform(0.86, 1.06)
            a = rng.uniform(-0.5, 0.5)
            c, sn = np.cos(a), np.sin(a)
            yy = y + rng.uniform(-0.14, 0.14) * cube
            quad = [(cx + u * c - v * sn, yy + u * sn + v * c) for u, v in ((-r, -r), (r, -r), (r, r), (-r, r))]
            (pale if rng.random() < 0.55 else dark).spoly(quad)
            cx += cube * 1.2
        y -= cube * 1.1
        row += 1
    for mask, col in ((dark, "#7e97a6"), (pale, "#a9bec9")):
        a = (mask.array() * ba)[..., None]
        s.rgb = s.rgb * (1 - a) + s.colour(col) * a
    # the plastic over them: one hard shine down the near shoulder
    g = s.mask()
    g.stroke(bez((x + hw * 0.62, top + bh * 0.2), (x + hw * 0.86, top + bh * 0.42), (x + hw * 0.84, top + bh * 0.72), n=8), max(0.5, w * 0.05), max(0.3, w * 0.02))
    a = (g.array() * ba * 0.85)[..., None]
    s.rgb = s.rgb * (1 - a) + s.colour("#dfe9ee") * a
    # the neck, a twist of tie, and the frill sticking up out of it
    n = s.mask()
    ny = top - bh * 0.1
    ft = base - h
    n.spoly([(x - hw * 0.14, ny + 0.4), (x + hw * 0.14, ny + 0.4), (x + hw * 0.09, ny - 1.0), (x + hw * 0.42, ft + 0.5), (x + hw * 0.2, ft + 1.3),
             (x + hw * 0.05, ft), (x - hw * 0.14, ft + 1.2), (x - hw * 0.44, ft + 0.3), (x - hw * 0.09, ny - 1.0)])
    s.paint(n, "#8aa2b0")
    k = s.mask()
    k.rect(x - hw * 0.17, ny - 1.1, x + hw * 0.17, ny + 0.2)
    s.paint(k, "#2a4a68")
    # a catch of the servo's light down the side that faces it, and that's the lot
    lit_rim(s, body, 790, 85, 340, LIGHT, 0.5, soft=0.25)


class Punter:
    """Someone in the line, side on, facing the freezer, in a hoodie and trackies: the top half hanging
    forward, the head further still, a neck going into the shoulders, one leg doing all the work."""

    def __init__(self, x, base, h, lean=0.075):
        self.x, self.base, self.h, self.lean = x, base, h, lean

    def P(self, u, v):
        return (self.x + (u + self.lean * max(0.0, v - 0.45) * 2.0) * self.h, self.base - v * self.h)

    def shape(self, m):
        P, h = self.P, self.h
        limb(m, [P(-0.02, 0.47), P(-0.07, 0.265), P(-0.095, 0.05)], [h * 0.105, h * 0.08, h * 0.055], cap=False)
        m.spoly([P(-0.13, 0.0), P(-0.13, 0.045), P(-0.07, 0.06), P(-0.05, 0.04), P(0.005, 0.016), P(0.005, 0.0)])
        limb(m, [P(0.03, 0.47), P(0.05, 0.265), P(0.045, 0.05)], [h * 0.11, h * 0.082, h * 0.055], cap=False)
        m.spoly([P(0.01, 0.0), P(0.01, 0.05), P(0.07, 0.06), P(0.09, 0.04), P(0.15, 0.016), P(0.15, 0.0)])
        pts = bez(P(-0.04, 0.815), P(-0.1, 0.8), P(-0.13, 0.76), P(-0.13, 0.66), n=10).tolist()
        pts += bez(P(-0.13, 0.66), P(-0.13, 0.56), P(-0.115, 0.5), P(-0.105, 0.43), n=8).tolist()
        pts += [P(0.1, 0.43), P(0.122, 0.5), P(0.118, 0.56)]
        pts += bez(P(0.118, 0.56), P(0.095, 0.62), P(0.1, 0.72), P(0.045, 0.815), n=10).tolist()
        m.spoly(pts)
        pts = bez(P(-0.035, 0.805), P(-0.09, 0.85), P(-0.11, 0.93), P(-0.06, 0.975), n=12).tolist()
        pts += bez(P(-0.06, 0.975), P(0.0, 1.015), P(0.1, 1.0), P(0.15, 0.935), n=10).tolist()
        pts += bez(P(0.15, 0.935), P(0.135, 0.89), P(0.115, 0.835), P(0.06, 0.795), n=8).tolist()
        m.spoly(pts)

    def face(self, m):
        P = self.P
        pts = bez(P(0.135, 0.925), P(0.085, 0.935), P(0.05, 0.905), P(0.055, 0.865), n=8).tolist()
        pts += bez(P(0.055, 0.865), P(0.065, 0.835), P(0.09, 0.83), P(0.11, 0.85), n=6).tolist()
        pts += bez(P(0.11, 0.85), P(0.125, 0.875), P(0.135, 0.9), P(0.135, 0.925), n=6).tolist()
        m.spoly(pts)

    def arm(self, m, pose):
        """pouch: hand gone in the front pocket, elbow out the back. hang: the arm just left there.
        carry: arm dead straight with the weight on it. Returns where the hand ends up."""
        P, h = self.P, self.h
        if pose == "pouch":
            limb(m, [P(-0.03, 0.75), P(-0.175, 0.595), P(0.035, 0.5)], [h * 0.082, h * 0.07, h * 0.05])
            return P(0.035, 0.5)
        if pose == "carry":
            limb(m, [P(-0.02, 0.75), P(0.01, 0.57), P(0.03, 0.395)], [h * 0.082, h * 0.068, h * 0.048])
            hand = P(0.03, 0.375)
        else:
            limb(m, [P(0.0, 0.75), P(0.125, 0.585), P(0.17, 0.43)], [h * 0.082, h * 0.068, h * 0.048])
            hand = P(0.17, 0.41)
        m.ellipse(hand[0], hand[1], h * 0.032, h * 0.04)
        return hand


def raider(s, x, base, h):
    """One bloke in full plate, standing in line for ice in the car park like it's a perfectly normal
    thing to wear at four in the morning. Which, round here, it nearly is. Square on, feet apart, one hand
    on his hip like he's been told the wait's another twenty minutes. All one dark shape: the outline's
    the armour, and the servo's light only catches the side of him that faces it."""
    def P(u, v):
        return (x + u * h, base - v * h)

    m = s.mask()
    # the big sword across his back: only the hilt shows, up over the shoulder
    m.stroke(np.array([P(0.17, 0.9), P(0.255, 1.12)]), h * 0.036, h * 0.036)
    m.stroke(np.array([P(0.155, 1.015), P(0.3, 0.965)]), h * 0.042, h * 0.042)
    m.spoly([P(0.235, 1.125), P(0.28, 1.14), P(0.275, 1.185), P(0.235, 1.17)])
    # legs, a clear gap between, an armoured wedge at each knee and the toes turned out
    for sd, hip, knee, ankle, toe in ((-1, -0.065, -0.115, -0.13, -0.26), (1, 0.065, 0.095, 0.11, 0.24)):
        limb(m, [P(hip, 0.5), P(knee, 0.27), P(ankle, 0.075)], [h * 0.13, h * 0.09, h * 0.075], cap=False)
        m.spoly([P(knee - 0.065, 0.285), P(knee, 0.335), P(knee + 0.065, 0.285), P(knee + 0.04, 0.215), P(knee - 0.04, 0.215)])
        m.spoly([P(ankle - 0.06, 0.1), P(ankle + 0.06, 0.1), P(ankle + 0.05, 0.05), P(ankle - 0.05, 0.05)])
        far = ankle - sd * 0.055
        m.spoly([P(ankle - 0.05, 0.06), P(ankle + 0.05, 0.06), P(toe if sd > 0 else far, 0.0), P(far if sd > 0 else toe, 0.0)])
    # plate skirt, waist, big chest
    m.spoly([P(-0.115, 0.54), P(0.115, 0.54), P(0.185, 0.355), P(0.06, 0.325), P(0.0, 0.385), P(-0.06, 0.325), P(-0.185, 0.355)])
    m.spoly([P(-0.17, 0.86), P(0.17, 0.86), P(0.2, 0.72), P(0.105, 0.52), P(-0.105, 0.52), P(-0.2, 0.72)])
    # one arm hanging, jointed, a flared gauntlet and a fist on the end of it
    limb(m, [P(-0.29, 0.76), P(-0.355, 0.56), P(-0.325, 0.41)], [h * 0.1, h * 0.082, h * 0.07], cap=False)
    m.spoly([P(-0.365, 0.595), P(-0.415, 0.545), P(-0.34, 0.51)])
    m.spoly([P(-0.385, 0.44), P(-0.265, 0.44), P(-0.272, 0.375), P(-0.378, 0.375)])
    m.rrect(P(-0.378, 0)[0], P(0, 0.385)[1], P(-0.272, 0)[0], P(0, 0.285)[1], h * 0.028)
    # the other on his hip, the elbow out: that gap under the arm is what makes him a person
    limb(m, [P(0.29, 0.76), P(0.4, 0.59), P(0.185, 0.525)], [h * 0.1, h * 0.08, h * 0.066], cap=False)
    m.spoly([P(0.385, 0.625), P(0.465, 0.58), P(0.39, 0.54)])
    m.spoly([P(0.215, 0.57), P(0.14, 0.545), P(0.14, 0.49), P(0.215, 0.49)])
    # a raised collar, and the helm sat down in it: flat-sided, narrow at the jaw, horns off the temples
    m.spoly([P(-0.11, 0.86), P(0.11, 0.86), P(0.085, 0.91), P(-0.085, 0.91)])
    pts = bez(P(-0.092, 0.95), P(-0.09, 1.045), P(0.09, 1.045), P(0.092, 0.95), n=12).tolist()
    pts += [P(0.082, 0.885), P(0.03, 0.845), P(-0.03, 0.845), P(-0.082, 0.885)]
    m.spoly(pts)
    for sx in (-1, 1):
        m.stroke(bez(P(sx * 0.07, 0.985), P(sx * 0.17, 0.985), P(sx * 0.19, 1.09), P(sx * 0.115, 1.215), n=12), h * 0.06, h * 0.012)
    # the spikes on the pauldrons go on behind them
    for sx in (-1, 1):
        m.spoly([P(sx * 0.33, 0.88), P(sx * 0.51, 0.99), P(sx * 0.42, 0.8)])
    m.spoly([P(-0.33, 0.92), P(-0.33, 1.13), P(-0.2, 0.93)])
    # the belt and its buckle
    s.paint(m, "#060a10", rim=0.55, rim_dx=0.45, rim_dy=-0.35, rim_colour=LIGHT)
    # the pauldrons, wider than the man, sat over his chest a shade up so you can see where they stop
    pa = s.mask()
    for sx in (-1, 1):
        pts = bez(P(sx * 0.125, 0.8), P(sx * 0.13, 0.975), P(sx * 0.4, 0.985), P(sx * 0.425, 0.765), n=16).tolist()
        pts += [P(sx * 0.37, 0.715), P(sx * 0.2, 0.725)]
        pa.spoly(pts)
    s.paint(pa, "#0d1520", rim=0.6, rim_dx=0.45, rim_dy=-0.35, rim_colour=LIGHT)
    b = s.mask()
    b.rect(P(-0.112, 0)[0], P(0, 0.56)[1], P(0.112, 0)[0], P(0, 0.525)[1])
    s.paint(b, "#1e2c3c")
    b = s.mask()
    b.rect(P(-0.026, 0)[0], P(0, 0.572)[1], P(0.026, 0)[0], P(0, 0.513)[1])
    s.paint(b, "#6f8ca4")
    # the slit in the helm: he's looking at the freezer
    v = s.mask()
    v.spoly([P(-0.025, 0.968), P(0.08, 0.968), P(0.075, 0.948), P(-0.02, 0.948)])
    s.paint(v, "#5f8fa8")


def paint():
    s = Scene("night", seed=23, horizon=118)
    s.sky(clouds=0.3, stars=0.9, glow_x=0.64, glow_w=0.2)
    s.moon(628, 30, 19, tint="#f0ecdc", glow=0.45, seed=3)
    s.moon(682, 17, 8, tint="#a9c6ff", glow=0.42, seed=9)

    # the suburb, asleep or pretending
    s.ridge(113, 10, 41, "#12283f", roughness=4)
    m = s.mask()
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
    kinds = ("carry", "bag", "plate", "bag", "pouch", "bag", "hang")
    # shadows first: the line throws them back along itself, away from the light
    sh = s.mask()
    for x, k in zip(qx, kinds):
        if k != "bag":
            by = float(queue_y(x))
            sh.spoly([(x - 8, by + 0.2), (x + 8, by + 0.2), (x - 7, by + 2.2), (x - 24, by + 2.2)])
    s.rgb *= (1 - gauss(sh.array(), 0.25 * SS) * 0.5)[..., None]

    def scale_at(by):
        return 0.72 + 0.28 * (by - 127.5) / (GROUND - 127.5)

    for x, k in reversed(list(zip(qx, kinds))):
        by = float(queue_y(x))
        scale = scale_at(by)
        if k == "bag":
            ice_bag(s, x, by, 18 * scale, 23 * scale, seed=int(x))
        elif k == "plate":
            raider(s, x, by, 56 * scale)
        else:
            who = Punter(x, by, 56 * scale)
            m, arm, fc = s.mask(), s.mask(), s.mask()
            who.shape(m)
            who.face(fc)
            hand = who.arm(arm, k)
            s.paint(m, "#070b12")
            lit_rim(s, m, 790, 85, 340, LIGHT, 0.42, soft=0.3)
            s.paint(fc, "#2f4456")
            s.paint(arm, "#0c131e", rim=0.4, rim_dx=0.4, rim_dy=-0.3, rim_colour=LIGHT)
            if k == "carry":
                # one he's actually bought: he's got it by the twist, and it's dragging his shoulder down
                bh = 15.5 * scale
                ice_bag(s, hand[0] + 0.4, hand[1] + bh - 0.4, 12.5 * scale, bh, seed=8, shadow=False)
                g = s.mask()
                g.ellipse(hand[0], hand[1], 56 * scale * 0.032, 56 * scale * 0.04)
                s.paint(g, "#0c131e")

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
