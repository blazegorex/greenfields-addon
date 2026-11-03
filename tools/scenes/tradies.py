"""Tradies: cash only, no receipts. A tin shed after hours with the door half up, foil on the window
and the extractor going flat out, the ute across the drive with a ladder on the rack and a very large
sword strapped alongside it. He's licensed. He sprayed it on the door himself."""
import numpy as np

from scenekit import SCRAWL, SS, Scene, bez, foil_window, gauss, gum_tree, lettering, lit_rim

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
    """What the fan's moving: one thin thread curling off over the roof, widening a little as it goes and
    thinning out in hard flat steps, gone before the moons. Steam, officer."""
    t = np.linspace(0, 1, 90)
    path = bez((x - 1, y - 7), (x - 18, y - 16), (x - 32, y - 6), (x - 66, y - 30), n=90)
    d = np.gradient(path, axis=0)
    d /= np.maximum(1e-6, np.linalg.norm(d, axis=1, keepdims=True))
    nrm = np.stack((-d[:, 1], d[:, 0]), axis=1)
    path = path + nrm * (np.sin(t * 13.0) * (0.3 + 4.2 * t))[:, None]
    wide = 0.75 + 1.25 * t
    for lo, hi, alpha in ((0, 42, 0.55), (42, 68, 0.30), (68, 90, 0.14)):
        m = s.mask()
        m.stroke(path[lo:hi], wide[lo], wide[hi - 1])
        a = m.array() * alpha
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


def bone(m, pts, widths):
    """An arm or a leg as one outline, tapering, with a corner at the bend. A sleeve folds at the elbow;
    it doesn't have a ball in it."""
    pts = [np.array(p, float) for p in pts]
    left, right = [], []
    for i, (p, w) in enumerate(zip(pts, widths)):
        d0 = pts[i] - pts[i - 1] if i else pts[1] - pts[0]
        d1 = pts[i + 1] - pts[i] if i < len(pts) - 1 else d0
        n0 = np.array([-d0[1], d0[0]]) / max(1e-6, np.linalg.norm(d0))
        n1 = np.array([-d1[1], d1[0]]) / max(1e-6, np.linalg.norm(d1))
        mit = n0 + n1
        mit /= max(1e-6, np.linalg.norm(mit))
        off = mit * (w / 2) / max(0.72, float(mit @ n0))
        left.append(tuple(p + off))
        right.append(tuple(p - off))
    m.spoly(left + right[::-1])


def alchemist(s, x, base, h, hand):
    """Gumboots planted, long stiff apron, gas mask with two round filters on it. One fist on his hip, the
    other holding up the good one by its neck, to the light, to see if it's done. hand is that fist."""
    def P(u, v):  # u toward the street (left), v up, as fractions of h
        return (x - u * h, base - v * h)

    def limb(pts, *widths):
        bone(m, pts, [h * w for w in widths])

    m = s.mask()
    # legs apart with daylight between them, boots with a heel and a toe
    limb([P(0.06, 0.5), P(0.085, 0.26), P(0.115, 0.06)], 0.105, 0.08, 0.07)
    limb([P(-0.05, 0.5), P(-0.075, 0.26), P(-0.105, 0.06)], 0.105, 0.08, 0.07)
    for a in (0.12, -0.11):
        m.spoly([P(a - 0.055, 0.2), P(a + 0.05, 0.2), P(a + 0.055, 0.07), P(a + 0.135, 0.035), P(a + 0.135, 0.0), P(a - 0.06, 0.0)])
    # the body, shoulders sloping off a proper neck, so the head's on something
    m.spoly([P(0.045, 0.77), P(0.13, 0.735), P(0.135, 0.68), P(0.105, 0.48), P(-0.095, 0.48), P(-0.115, 0.68), P(-0.105, 0.735), P(-0.03, 0.77)])
    m.spoly([P(0.05, 0.84), P(0.045, 0.75), P(-0.03, 0.75), P(-0.035, 0.84)])
    # fist on the hip, elbow out behind him, with a gap you can see the shelves through
    limb([P(-0.085, 0.715), P(-0.27, 0.585), P(-0.095, 0.5)], 0.08, 0.068, 0.056)
    # the working arm: down from the shoulder, a bend at the elbow, the forearm back up to the flask
    elbow = (hand[0] + 13, hand[1] + 13)
    limb([P(0.1, 0.715), elbow, (hand[0] + 3.4, hand[1] + 1.8)], 0.08, 0.068, 0.05)
    s.paint(m, "#030a0a")
    lit_rim(s, m, x - h * 0.5, base - h * 0.7, h * 1.2, COLD, 0.9, soft=0.3)

    # the apron, stiff, hem well above the boots so the legs still show
    a = s.mask()
    a.spoly([P(0.0, 0.69), P(0.125, 0.69), P(0.13, 0.5), P(0.2, 0.25), P(-0.07, 0.25), P(-0.03, 0.5)])
    s.paint(a, "#0c2624", rim=0.5, rim_dx=0.5, rim_dy=0, rim_colour=COLD)
    st = s.mask()
    st.line([P(0.01, 0.69), P(0.0, 0.76)], 0.9)
    s.paint(st, "#0c2624")

    # the head, a rubber snout on the front of it, and the two filters hanging off the snout: one out in
    # front past the outline, one on the near cheek, well below the eyes so they're not a pair of glasses
    far, near = P(0.155, 0.825), P(0.035, 0.825)
    cr = h * 0.05
    g = s.mask()
    g.ellipse(*P(0.015, 0.915), h * 0.098, h * 0.104)
    g.spoly([P(0.09, 0.90), P(0.14, 0.865), P(0.145, 0.80), P(0.02, 0.80)])
    g.ellipse(*far, cr, cr)
    g.ellipse(*near, cr, cr)
    s.paint(g, "#030a0a")
    lit_rim(s, g, x - h * 0.6, base - h * 0.7, h * 1.0, COLD_HOT, 0.8, soft=0.3)
    # the filters' faces: flat pale discs in a dark ring
    r = s.mask()
    r.ellipse(*far, cr * 0.62, cr * 0.62)
    r.ellipse(*near, cr * 0.62, cr * 0.62)
    s.paint(r, "#4b9184")
    # one flat visor across the eyes, the glass picking up the flask
    e = s.mask()
    e.rrect(P(0.115, 0)[0], P(0, 0.95)[1], P(0.0, 0)[0], P(0, 0.915)[1], 0.7)
    s.paint(e, "#a8f5e2")

    # the good one, no bigger than the ones on the shelf, and his fist round the neck of it
    r_flask = 5.0
    s.glow(hand[0], hand[1] + 6, 26, colour=COLD, strength=0.26)
    flask(s, hand[0], hand[1] + 1.225 * r_flask + r_flask, r_flask, colour="#7cffdc", glow=1.2)
    f = s.mask()
    f.rrect(hand[0] - 2.0, hand[1] - 1.4, hand[0] + 2.6, hand[1] + 1.4, 0.8)
    s.paint(f, "#030a0a")
    lit_rim(s, f, hand[0] - 8, hand[1], 20, COLD_HOT, 1.0, soft=0.25)


def ute(s, x, base, k):
    """A work ute, the one every tradie's got: upright square cab, short snout, bull bar, and an alloy
    tray sat up on the chassis with drop sides. About 5 m long in these units (118 = 5 m), so a wheel's
    9 and the roof's 43. Rack over the tray and cab, ladder on the rack, sword on the ladder. x is its tail."""
    def P(u, v):
        return (x + u * k, base - v * k)

    def box(u0, v0, u1, v1):
        return (P(u0, 0)[0], P(0, v1)[1], P(u1, 0)[0], P(0, v0)[1])

    wheels = (26, 96)
    WR = 9.0
    # chassis rail, running the length under everything, and the bearers the tray sits on, with a gap of
    # sky-dark between them: that gap's what says tray and not a sedan's boot
    m = s.mask()
    m.rect(*box(0, 12.5, 110, 16.5))
    for u in (8, 22, 36, 50):
        m.rect(*box(u, 16, u + 2.2, 20))
    s.paint(m, "#06040a")

    # the rack goes on behind the tray and cab
    rk = s.mask()
    # its legs carry straight on up from the tray's end posts, each with a brace back down to the tray
    for u in (0, 54.6):
        rk.rect(*box(u, 24, u + 1.4, 51))
    rk.rect(*box(76, 43, 77.5, 51))
    rk.rect(*box(-1, 49.6, 82, 51.2))
    rk.stroke(np.array([P(1, 30), P(16, 50)]), 1.2 * k, 1.2 * k)
    rk.stroke(np.array([P(55, 30), P(40, 50)]), 1.2 * k, 1.2 * k)
    s.paint(rk, "#241a26", rim=0.5, rim_dx=-0.3, rim_dy=-0.7, rim_colour="#ffb46a")

    # alloy tray: deck edge and drop side, with the hinges and the latch posts on it
    m = s.mask()
    m.rect(*box(0, 20, 56, 30))
    s.paint(m, "#54454f", rim=0.55, rim_dx=0, rim_dy=-0.7, rim_colour="#ffb46a")
    m = s.mask()
    m.rect(*box(0, 20, 56, 22.6))
    for u in (0, 18.2, 36.8, 54.6):
        m.rect(*box(u, 22.6, u + 1.4, 30))
    s.paint(m, "#241a26")
    # the rack's feet, bolted on top of the drop side
    m = s.mask()
    for u in (-1.4, 53.2):
        m.rect(*box(u, 29.6, u + 4.2, 31.4))
    s.paint(m, "#241a26", rim=0.4, rim_dx=0, rim_dy=-0.7, rim_colour="#ffb46a")
    # the tail light on the end of the chassis, in its housing and on, and a square of mud flap behind the wheel
    m = s.mask()
    m.rect(*box(-1.4, 13.6, 5, 20))
    s.paint(m, "#06040a")
    m = s.mask()
    m.rect(*box(-1.4, 15, 3.6, 18.8))
    s.paint(m, "#e8402c")
    s.glow(*P(-1.4, 17), 5, colour="#ff4030", strength=0.32)
    m = s.mask()
    m.rect(*box(11.5, 5, 13.5, 13))
    s.paint(m, "#06040a")
    # headboard, standing proud of the tray behind the cab
    m = s.mask()
    m.rect(*box(55.5, 20, 58, 46))
    s.paint(m, "#2a1f2c", rim=0.45, rim_dx=-0.3, rim_dy=-0.7, rim_colour="#ffb46a")

    # the cab: back wall dead upright, a flat roof, a steep screen, then a short bonnet and a blunt nose
    m = s.mask()
    pts = [P(59, 12.5), P(59, 41.5), P(60.5, 43.5), P(79, 44), P(81.5, 43), P(90, 31), P(112, 29.5), P(115.5, 27.5), P(116, 12.5)]
    m.spoly(pts)
    s.paint(m, "#3b2c3a", rim=0.6, rim_dx=-0.4, rim_dy=-0.8, rim_colour="#ffa458")
    # the nose catches what's coming out of the door
    lit_rim(s, m, 800, 118, 70, COLD, 0.9, soft=0.3)
    # wheel arches cut dark round the tyres
    a = s.mask()
    a.ellipse(*P(wheels[1], WR), (WR + 2.6) * k, (WR + 2.6) * k)
    c = s.mask()
    c.rect(0, 0, 1040, P(0, 12.5)[1] + 0.01)
    arch = a.array() * c.array()
    s.rgb = s.rgb * (1 - arch[..., None]) + s.colour("#06040a") * arch[..., None]
    # glass: a side window, the far side of it going green toward the door
    g = s.mask()
    g.spoly([P(62, 30), P(62, 41), P(79, 41.4), P(86.2, 31), P(86.2, 30)])
    a = g.array()
    t = np.clip((s.X / SS - P(62, 0)[0]) / (24 * k), 0, 1)
    s.rgb = s.rgb * (1 - a[..., None]) + (s.colour("#3a2233") * (1 - t[..., None]) + s.colour("#3aa892") * t[..., None]) * a[..., None]
    # door: the shut lines, the handle and the mirror
    d = s.mask()
    d.rect(*box(61, 14, 61.8, 30))
    d.rect(*box(85.4, 14, 86.2, 30))
    d.rect(*box(61, 29.4, 91, 30))
    d.rect(*box(64, 25.4, 69, 26.8))
    d.rect(*box(76.4, 30, 77.4, 41.4))
    d.rrect(*box(86.2, 31.5, 89.4, 35.5), 0.5)
    s.paint(d, "#0d0912")
    # headlight
    m = s.mask()
    m.rect(*box(111.5, 21.5, 116, 26))
    s.paint(m, "#ffe0a8")
    # bull bar: a hoop stood off the nose, with air through it
    b = s.mask()
    b.rect(*box(113, 11.5, 120.5, 17))
    b.stroke(np.array([P(119.6, 15), P(119.6, 31)]), 1.7 * k, 1.7 * k)
    b.stroke(np.array([P(120.4, 30.4), P(112, 31.2)]), 1.7 * k, 1.7 * k)
    b.rect(*box(115.5, 21.5, 120, 23))
    s.paint(b, "#07050b", rim=0.5, rim_dx=0.4, rim_dy=-0.4, rim_colour=COLD)

    # wheels: proper tyre, plain steel rim, nut in the middle
    w = s.mask()
    for u in wheels:
        w.ellipse(*P(u, WR), WR * k, WR * k)
    s.paint(w, "#040307", rim=0.3, rim_dx=-0.3, rim_dy=-0.4, rim_colour="#ffa458")
    h = s.mask()
    for u in wheels:
        h.ellipse(*P(u, WR), WR * k * 0.52, WR * k * 0.52)
    s.paint(h, "#6b5b63", rim=0.5, rim_dx=-0.3, rim_dy=-0.3, rim_colour="#ffbf80")
    h = s.mask()
    for u in wheels:
        h.ellipse(*P(u, WR), WR * k * 0.2, WR * k * 0.2)
    s.paint(h, "#1c141c")

    # ladder on the rack, overhanging the bonnet: rails and rungs
    rk = s.mask()
    rk.rect(*box(-4, 51.2, 104, 52.6))
    rk.rect(*box(-4, 56, 104, 57.4))
    for u in np.arange(-1, 104, 7.3):
        rk.rect(*box(u, 52.6, u + 0.9, 56))
    s.paint(rk, "#1a1320", rim=0.5, rim_dx=-0.3, rim_dy=-0.7, rim_colour="#ffb46a")

    # and lashed along the top of it: a greatsword, the guard down over the near rail. Nobody asks.
    b = s.mask()
    b.spoly([P(17, 57.4), P(17, 63), P(98, 62), P(111, 59.8), P(98, 57.4)])
    s.paint(b, "#a39aa2", rim=0.8, rim_dx=0.2, rim_dy=-0.8, rim_colour="#ffe2bd")
    f = s.mask()
    f.rect(*box(18, 59.7, 92, 60.7))
    s.paint(f, "#4e4550")
    # the grip in dark leather, then a brass crossguard with flared ends and a brass pommel
    h = s.mask()
    h.rect(*box(5.5, 58.4, 15.6, 62))
    s.paint(h, "#17101a", rim=0.5, rim_dx=-0.3, rim_dy=-0.8, rim_colour="#ffc98a")
    h = s.mask()
    h.spoly([P(14.8, 52.0), P(19.4, 52.0), P(18.4, 54.5), P(18.4, 65.9), P(19.4, 68.4), P(14.8, 68.4), P(15.8, 65.9), P(15.8, 54.5)])
    h.ellipse(*P(4, 60.2), 3.3 * k, 3.3 * k)
    s.paint(h, "#c8962f", rim=0.8, rim_dx=-0.3, rim_dy=-0.8, rim_colour="#ffe9b0")
    # two ratchet straps, the only bit of it that's up to code
    r = s.mask()
    for u in (42, 78):
        r.rect(*box(u, 50.6, u + 2.2, 63.6))
    s.paint(r, "#a8392c")


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
    fan(s, 843, 50.5, 6.0)
    steam(s, 843, 50.5)
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
    rack(s, 818, 894, base, (113, 137))
    s.glow(790, 112, 62, colour=COLD, strength=0.13)
    fx, fy = 768, 101
    alchemist(s, 792, 139.5, 47, (fx, fy))

    ute(s, 572, 140, 1.34)

    # dark gums: the shed's mate on the right, and the title's backstop on the left
    m = s.mask()
    gum_tree(m, 1026, 170, 118, seed=52, lean=0.12, spread=0.8)
    gum_tree(m, 232, 176, 172, seed=48, lean=0.06)
    m.rect(0, 144, 1040, 148)
    s.paint(m, "#040308")
    return s.finish()
