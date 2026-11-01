"""Tradies: cash only, no receipts. A tin shed after hours with the door half up, foil on the window
and the extractor going flat out, the ute across the drive with a ladder on the rack and a very large
sword strapped alongside it. He's licensed. He sprayed it on the door himself."""
import numpy as np

from scenekit import SCRAWL, SS, Scene, bez, fbm, foil_window, gauss, gum_tree, lettering, lit_rim

COLD = "#58f0cc"
COLD_HOT = "#c8fff0"


def shed(s, x, base, w, h, door_x0, door_x1, door_top, gap_y):
    rise = w * 0.09
    apex = x + w / 2
    # body
    m = s.mask()
    body = [(x, base), (x, base - h), (apex, base - h - rise), (x + w, base - h), (x + w, base)]
    m.spoly(body)
    a = m.array()
    s.paint(m, "#1b1226", bottom="#100a17", top_y=base - h - rise - 20)
    # corrugations: vertical ribs that catch the cold light lower down, and the sunset up high
    c = s.mask()
    for xx in np.arange(x + 2.5, x + w, 3.2):
        t = 1 - abs(xx - apex) / (w / 2)
        c.line([(xx, base), (xx, base - h - rise * t + 0.8)], 0.34)
    ribs = c.array() * a
    s.rgb += (ribs * 0.07)[..., None] * s.colour("#ff9a50")
    fall = np.clip(1 - np.abs(s.X / SS - (door_x0 + door_x1) / 2) / (w * 0.7), 0, 1) * np.clip((s.Y / SS - gap_y + 8) / 30, 0, 1)
    s.rgb += (ribs * 0.26 * fall)[..., None] * s.colour(COLD)

    # the mouth of the shed: hottest low and back, where nobody's asking what's on
    d = s.mask()
    d.rect(door_x0, gap_y, door_x1, base)
    da = d.array()
    xs, ys = s.X / SS, s.Y / SS
    dx = (xs - (door_x0 + (door_x1 - door_x0) * 0.42)) / ((door_x1 - door_x0) * 0.62)
    dy = (ys - (gap_y + (base - gap_y) * 0.55)) / ((base - gap_y) * 0.95)
    heat = np.exp(-(dx * dx + dy * dy) * 1.2)[..., None]
    col = s.colour("#041a1e")[None, None, :] * (1 - heat) + s.colour("#1a7a74")[None, None, :] * heat
    s.rgb = s.rgb * (1 - da[..., None]) + col * da[..., None]

    # the door, down to where it's stuck, with the roller drum over it
    p = s.mask()
    p.rect(door_x0, door_top, door_x1, gap_y)
    s.paint(p, "#2a1e2c", bottom="#1c1320", top_y=door_top - 20, rim=0.0)
    sl = s.mask()
    for yy in np.arange(door_top + 3, gap_y, 3.2):
        sl.line([(door_x0, yy), (door_x1, yy)], 0.32)
    s.rgb = s.rgb * (1 - sl.array()[..., None] * 0.45)
    f = s.mask()
    f.rect(door_x0 - 1.6, door_top - 3, door_x1 + 1.6, door_top + 0.6)
    f.rect(door_x0 - 2, door_top, door_x0 + 0.4, base)
    f.rect(door_x1 - 0.4, door_top, door_x1 + 2, base)
    s.paint(f, "#0a0710")
    e = s.mask()
    e.rect(door_x0, gap_y - 1.3, door_x1, gap_y)
    s.paint(e, "#0a0710", rim=0.9, rim_dx=0, rim_dy=0.9, rim_colour=COLD)

    # roof: dark, a heavy edge, its rim catching the sky
    r = s.mask()
    r.spoly([(x - 3, base - h + 1.2), (apex, base - h - rise - 1.4), (x + w + 3, base - h + 1.2),
             (x + w + 3, base - h + 3.2), (apex, base - h - rise + 1), (x - 3, base - h + 3.2)])
    s.paint(r, "#0a0710", rim=0.5, rim_dx=-0.5, rim_dy=-0.8)


def fan(s, x, y, r):
    """Extractor in the gable, flat out, in the sort of shed that doesn't usually need one."""
    m = s.mask()
    m.rrect(x - r - 1.6, y - r - 1.6, x + r + 1.6, y + r + 1.6, 1)
    s.paint(m, "#0a0710", rim=0.35, rim_dx=0, rim_dy=-0.7)
    g = s.mask()
    g.ellipse(x, y, r, r)
    s.paint(g, "#2e7f74")
    b = s.mask()
    for a in (0.5, 2.6, 4.7):
        c, sn = np.cos(a), np.sin(a)
        b.spoly([(x, y), (x + c * r - sn * r * 0.42, y + sn * r + c * r * 0.42), (x + c * r + sn * r * 0.1, y + sn * r - c * r * 0.1)])
    b.ellipse(x, y, r * 0.2, r * 0.2)
    s.paint(b, "#07050b")


def steam(s, x, y):
    """What the fan's moving: fat soft puffs leaning off to the left, thinning out before the moons.
    Steam, officer."""
    m = s.mask()
    path = bez((x, y), (x - 16, y - 1), (x - 34, y - 8), (x - 74, y - 24), n=9)
    for i, (px, py) in enumerate(path):
        r = 3.5 + i * 1.5
        m.ellipse(px, py + (i % 2) * 1.5, r * 1.15, r * 0.85)
    n = fbm(s.h, s.w, 77, cells=14, octaves=3)
    fade = np.clip((s.X / SS - (x - 84)) / 74, 0, 1)
    a = gauss(m.array(), 2.2 * SS) * (0.45 + 0.55 * n) * fade * 0.62
    s.rgb = s.rgb * (1 - a[..., None]) + s.colour("#b4ece0") * a[..., None]


def drum(s, x, base, w, h):
    """A plain 44 out the back with nothing written on it. Round top, two ribs, lit by the last of the day."""
    m = s.mask()
    m.rect(x, base - h, x + w, base)
    m.ellipse(x + w / 2, base - h, w / 2, 2.1)
    s.paint(m, "#2a1c2c", bottom="#150e18", top_y=base - h - 40, rim=0.7, rim_dx=-0.7, rim_dy=-0.6)
    r = s.mask()
    for t in (0.34, 0.67):
        r.rect(x, base - h * t, x + w, base - h * t + 1.0)
    s.paint(r, "#0a0610")
    lid = s.mask()
    lid.ellipse(x + w / 2, base - h, w / 2 - 0.9, 1.4)
    s.paint(lid, "#0d0812")


def flask(s, x, base, r, colour=COLD, glow=1.0):
    """Warcraft potion: round belly, long neck, a cork, and something in it you can read by."""
    cy = base - r
    m = s.mask()
    m.ellipse(x, cy, r, r)
    m.rect(x - r * 0.28, cy - r * 1.75, x + r * 0.28, cy - r * 0.7)
    m.rrect(x - r * 0.42, cy - r * 1.9, x + r * 0.42, cy - r * 1.62, 0.3)
    s.paint(m, "#0d2428")
    lq = s.mask()
    lq.ellipse(x, cy, r * 0.84, r * 0.84)
    lq.rect(x - r, cy - r, x + r, cy - r * 0.22, fill=0)
    la = lq.array()
    s.rgb += gauss(la, r * 1.5 * SS)[..., None] * s.colour(colour) * 0.55 * glow
    s.rgb = s.rgb * (1 - la[..., None]) + s.colour(colour) * 1.2 * la[..., None]
    # bubbles and the shine that says glass
    rng = np.random.default_rng(int(x))
    b = s.mask()
    for _ in range(4):
        b.ellipse(x + rng.uniform(-0.45, 0.45) * r, cy + rng.uniform(0.0, 0.55) * r, r * 0.09, r * 0.09)
    b.ellipse(x - r * 0.42, cy - r * 0.42, r * 0.17, r * 0.12)
    ba = b.array()
    s.rgb = s.rgb * (1 - ba[..., None]) + s.colour("#f4fff8") * ba[..., None]
    k = s.mask()
    k.rrect(x - r * 0.24, cy - r * 2.18, x + r * 0.24, cy - r * 1.86, 0.2)
    s.paint(k, "#7a5a3a")
    # the edge of the glass
    lit_rim(s, m, x - r, cy - r, r * 6, COLD_HOT, 0.8, soft=0.2)


def rack(s, x0, x1, base, levels):
    """Steel shelving at the back of the shed, in silhouette, and row on row of the stuff."""
    m = s.mask()
    for xx in (x0, x1, (x0 + x1) / 2):
        m.rect(xx - 0.6, min(levels) - 18, xx + 0.6, base)
    for y in levels:
        m.rect(x0 - 1, y, x1 + 1, y + 1.1)
    s.paint(m, "#06201f")
    rng = np.random.default_rng(6)
    for y in levels:
        for xx in np.arange(x0 + 8, x1 - 3, 15.5):
            flask(s, xx + rng.uniform(-1, 1), y, rng.uniform(3.6, 4.6), colour=COLD, glow=0.35)


def alchemist(s, x, base, h, flask_at):
    """Long apron, gumboots, gas mask with a snout on it. He's facing out the door, holding one up to
    the light to see if it's done."""
    def P(u, v):  # u toward the street (left), v up, as fractions of h
        return (x - u * h, base - v * h)
    m = s.mask()
    # gumboots and legs under the apron
    m.spoly([P(-0.13, 0.42), P(0.04, 0.42), P(0.03, 0.0), P(-0.11, 0.0)])
    m.spoly([P(0.0, 0.42), P(0.16, 0.42), P(0.15, 0.0), P(0.01, 0.0)])
    m.rect(*P(0.03, 0.03)[:1], P(0, 0.03)[1], P(-0.13, 0)[0], base)
    m.rect(P(0.2, 0.03)[0], P(0, 0.03)[1], P(0.01, 0)[0], base)
    # the back of him, shoulders hunched
    pts = bez(P(-0.1, 0.8), P(-0.2, 0.75), P(-0.19, 0.55), P(-0.16, 0.4), n=10).tolist()
    pts += [P(0.15, 0.4)]
    pts += bez(P(0.15, 0.4), P(0.17, 0.6), P(0.17, 0.74), P(0.08, 0.8), n=10).tolist()
    m.spoly(pts)
    # far arm hanging
    m.stroke(bez(P(-0.12, 0.74), P(-0.21, 0.6), P(-0.2, 0.5), n=10), h * 0.075, h * 0.06)
    # the arm with the flask, up at eye level
    sh = P(0.08, 0.74)
    m.stroke(bez(sh, P(0.12, 0.5), P(0.3, 0.42), flask_at, n=14), h * 0.085, h * 0.06)
    m.ellipse(flask_at[0], flask_at[1], h * 0.06, h * 0.05)
    s.paint(m, "#030a0a")
    lit_rim(s, m, x - h * 0.5, base - h * 0.7, h * 1.2, COLD, 0.9, soft=0.3)

    # the apron, long and stiff, so it reads as an apron and not a dress
    a = s.mask()
    a.spoly([P(-0.05, 0.76), P(0.13, 0.76), P(0.16, 0.56), P(0.21, 0.11), P(-0.11, 0.11), P(-0.09, 0.56)])
    s.paint(a, "#12211f", bottom="#091514", top_y=base - h - 40)
    lit_rim(s, a, x - h * 0.5, base - h * 0.7, h * 1.2, COLD, 0.7, soft=0.3)
    st = s.mask()
    st.line([P(-0.05, 0.76), P(0.0, 0.84)], 0.8)
    st.line([P(0.13, 0.76), P(0.06, 0.84)], 0.8)
    s.paint(st, "#04100f")

    # hood and mask, big enough to see from the road
    g = s.mask()
    g.ellipse(*P(0.01, 0.89), h * 0.125, h * 0.125)
    # snout and the can on the end of it
    g.spoly([P(0.06, 0.95), P(0.21, 0.88), P(0.22, 0.79), P(0.05, 0.8)])
    g.ellipse(*P(0.25, 0.83), h * 0.075, h * 0.09)
    s.paint(g, "#030a0a")
    lit_rim(s, g, x - h * 0.6, base - h * 0.7, h * 1.0, COLD_HOT, 1.1, soft=0.3)
    # one big round eyepiece, glass picking up the flask
    e = s.mask()
    e.ellipse(*P(0.1, 0.92), h * 0.05, h * 0.05)
    ea = e.array()
    s.rgb = s.rgb * (1 - ea[..., None]) + s.colour(COLD_HOT) * ea[..., None]
    s.rgb += gauss(ea, 1.2 * SS)[..., None] * s.colour(COLD) * 0.8
    # the can's ribs
    r = s.mask()
    cc = P(0.25, 0.83)
    r.line([(cc[0] + h * 0.02, cc[1] - h * 0.07), (cc[0] + h * 0.02, cc[1] + h * 0.07)], 0.5)
    s.paint(r, "#2c5a54")


def ute(s, x, base, k):
    """Old Aussie tray-back ute, facing the shed, lit from the door side. x is its tail."""
    def P(u, v):
        return (x + u * k, base - v * k)
    m = s.mask()
    wheels = [(22, 7.0), (92, 7.0)]
    # the tray (long, flat, with headboard), cab and bonnet as one sweep
    pts = [P(2, 8), P(2, 17), P(55, 17)]                         # tray deck
    pts += [P(55, 19), P(59, 19)]
    pts += bez(P(59, 19), P(61, 28), P(62, 33), P(65, 34), n=8).tolist()   # back of cab
    pts += bez(P(65, 34), P(72, 35.2), P(79, 35), P(84, 33.4), n=8).tolist()  # roof
    pts += bez(P(84, 33.4), P(89, 28), P(91, 25.6), P(93, 24.8), n=8).tolist()  # windscreen
    pts += bez(P(93, 24.8), P(101, 24), P(110, 22.5), P(114, 18), n=8).tolist()  # bonnet
    pts += bez(P(114, 18), P(116, 14), P(116, 11), P(115, 8), n=6).tolist()  # nose
    m.spoly(pts)
    # chassis and arches
    m.rrect(*P(0, 10)[:1], P(0, 10)[1], P(118, 6)[0], P(118, 6)[1], 1)
    s.paint(m, "#120c18", rim=0.55, rim_dx=-0.4, rim_dy=-0.8, rim_colour="#ffa458")
    # the nose catches what's coming out of the door
    lit_rim(s, m, 800, 118, 70, COLD, 0.9, soft=0.3)
    # glass, the far side of it going green
    g = s.mask()
    pts = [P(65.5, 22)]
    pts += [P(66, 31), P(72, 32.8), P(78, 32.8), P(83, 31.4), P(88.5, 25), P(88.5, 22)]
    g.spoly(pts)
    a = g.array()
    t = np.clip((s.X / SS - P(65, 0)[0]) / (24 * k), 0, 1)
    s.rgb = s.rgb * (1 - a[..., None]) + (s.colour("#3a2233") * (1 - t[..., None]) + s.colour("#3aa892") * t[..., None]) * a[..., None]
    post = s.mask()
    post.line([P(77, 22), P(77, 33)], 1.0 * k)
    s.paint(post, "#120c18")
    # tray side rail
    r = s.mask()
    r.rect(P(2, 0)[0], P(0, 17)[1], P(55, 0)[0], P(0, 15.6)[1])
    s.paint(r, "#1e141f", rim=0.25, rim_dx=0, rim_dy=-0.5, rim_colour="#ffa458")
    # wheels
    w = s.mask()
    for u, r_ in wheels:
        w.ellipse(*P(u, r_), r_ * k + 1.0, r_ * k + 1.0)
    s.paint(w, "#040307", rim=0.3, rim_dx=-0.3, rim_dy=-0.4, rim_colour="#ffa458")
    h = s.mask()
    for u, r_ in wheels:
        h.ellipse(*P(u, r_), r_ * k * 0.42, r_ * k * 0.42)
    s.paint(h, "#3a2d35", rim=0.5, rim_dx=-0.3, rim_dy=-0.3, rim_colour="#ffbf80")
    # the rack: uprights front and back of the tray, a crossbar running over the cab
    rk = s.mask()
    for u in (7, 54):
        rk.stroke(np.array([P(u, 17), P(u, 42)]), 1.25 * k, 1.1 * k)
    rk.stroke(np.array([P(5, 42), P(88, 42)]), 1.3 * k, 1.3 * k)
    rk.stroke(np.array([P(76, 42), P(76, 34)]), 1.2 * k, 1.2 * k)
    # ladder on the rack, overhanging the bonnet: rails and rungs
    rk.stroke(np.array([P(0, 44.0), P(104, 44.0)]), 1.0 * k)
    rk.stroke(np.array([P(0, 48.4), P(104, 48.4)]), 1.0 * k)
    for u in np.arange(3, 104, 7.3):
        rk.line([P(u, 44), P(u, 48.4)], 0.65 * k)
    s.paint(rk, "#0b0710", rim=0.38, rim_dx=-0.3, rim_dy=-0.7, rim_colour="#ffb46a")
    # and strapped along the top of it: a greatsword. Nobody asks.
    b = s.mask()
    b.spoly([P(20, 49.4), P(20, 54.6), P(100, 53.2), P(110, 51.6), P(100, 50.2)])
    b.stroke(np.array([P(19, 45.4), P(19, 58.6)]), 2.4 * k)
    b.stroke(np.array([P(7, 52), P(19, 52)]), 2.0 * k)
    b.ellipse(*P(5.6, 52), 2.4 * k, 2.4 * k)
    s.paint(b, "#0b0710", rim=0.55, rim_dx=0.3, rim_dy=-0.8, rim_colour="#ffc98a")


def paint():
    s = Scene("ember", seed=41)
    s.sky(clouds=0.55, stars=0.9, glow_x=0.72, glow_w=0.2)
    s.moon(636, 30, 16, tint="#f6e8d0", glow=0.45, seed=3)
    s.moon(680, 17, 8, tint="#a9c6ff", glow=0.4, seed=9)
    s.ridge(106, 20, 71, "#40243f", roughness=4)
    s.fog(90, 114, strength=0.26)

    m = s.mask()
    for i, x in enumerate((318, 402, 472, 545, 962, 1000)):
        gum_tree(m, x, 124, 40 + (i * 31) % 22, seed=110 + i, leaves=0.9)
    m.rect(0, 120, 1040, 148)
    s.paint(m, "#231429", rim=0.12)
    s.fog(106, 126, strength=0.18, seed=8)

    # back fence, running off behind the shed
    m = s.mask()
    x = 0.0
    rng = np.random.default_rng(3)
    while x < 1040:
        w = rng.uniform(4.2, 5.4)
        top = 117 + rng.uniform(-0.6, 0.6)
        m.spoly([(x, 148), (x, top + 1), (x + w * 0.45, top), (x + w - 0.5, top + 1), (x + w - 0.5, 148)])
        x += w
    s.paint(m, "#150d1c", rim=0.12, rim_dx=0, rim_dy=-0.7)

    door0, door1, door_top, gap, base = 756, 898, 61, 90, 139
    sx, sw = 748, 190
    # two 44s round the back, hard up against the fence
    drum(s, 947, base, 17, 26)
    drum(s, 967, base + 0.5, 17, 26)
    shed(s, sx, base, sw, 82, door0, door1, door_top, gap)
    fan(s, 804, 53.5, 4.8)
    steam(s, 798, 53)
    foil_window(s, 906, 72, 28, 18, seed=5, strength=0.8)
    m = s.mask()
    m.rect(904.6, 70.6, 935.4, 73)
    m.rect(904.6, 89, 935.4, 91.4)
    m.rect(904.6, 70.6, 906.4, 91.4)
    m.rect(933.6, 70.6, 935.4, 91.4)
    s.paint(m, "#0a0710")

    # his qualifications, done with a can in about four seconds
    m = s.mask()
    lettering(m, "MASTER", 812, 68.5, 11, font=SCRAWL, angle=-1.5, wobble=0.45, seed=7, spacing=0.3)
    lettering(m, "ALCHEMIST", 828, 81.5, 11, font=SCRAWL, angle=-1.5, wobble=0.45, seed=9, spacing=0.3)
    s.paint(m, "#f2ece0")

    # driveway; the door's light spills out over it, cold on warm
    m = s.mask()
    m.spoly(bez((0, 137), (300, 139), (700, 138.6), (1040, 137), n=20).tolist() + [(1040, 148), (0, 148)])
    s.paint(m, "#0b0810", rim=0.1, rim_dx=0, rim_dy=-0.7)
    spill = s.mask()
    spill.spoly([(door0, base), (door1, base), (door1 + 34, 148), (door0 - 54, 148)])
    a = gauss(spill.array(), 1.4 * SS)
    fade = np.clip(1 - (s.Y / SS - base) / 9.0, 0, 1)
    s.rgb += (a * fade)[..., None] * s.colour(COLD) * 0.5

    # the stock, then him stood in front of it with the good one
    rack(s, 806, 894, base, (113, 137))
    s.glow(790, 112, 62, colour=COLD, strength=0.13)
    fx, fbase = 768, 118
    alchemist(s, 797, 139.5, 47, (fx + 1, fbase + 1.2))
    s.glow(fx, fbase - 9, 34, colour=COLD, strength=0.34)
    flask(s, fx, fbase, 9.2, colour="#7cffdc", glow=1.4)

    ute(s, 572, 140, 1.34)

    # dark gums: the shed's mate on the right, and the title's backstop on the left
    m = s.mask()
    gum_tree(m, 1026, 170, 118, seed=52, lean=0.12, spread=0.8)
    gum_tree(m, 232, 176, 172, seed=48, lean=0.06)
    m.rect(0, 144, 1040, 148)
    s.paint(m, "#040308")
    return s.finish()
