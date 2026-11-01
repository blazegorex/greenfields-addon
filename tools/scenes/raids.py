"""Raid Nights: the other kind of raid. Paddy wagon on the lawn, lights going, and the stack on the
porch is five idiots from Azeroth with a battering ram, while the bloke they came for leaves by the window."""
import numpy as np

from scenekit import STENCIL, SS, Scene, bez, foil_window, gauss, gum_tree, lettering, lit_rim, smooth

MOOD = {"sky": [(0.00, "#05060f"), (0.34, "#0b0d22"), (0.58, "#171434"), (0.76, "#2c1a44"),
                (0.90, "#4a1f4c"), (1.00, "#6d2750")],
        "far": "#231a3c", "mid": "#140f26", "near": "#07060f", "rim": "#b45a8c", "haze": "#5a2a60"}

RED = "#ff2f3c"
BLUE = "#2f6dff"
HOT = "#fff4e2"
ARMOUR = "#07060c"


def curve(pts, n=120):
    """Smooth line through the given points (Catmull-Rom)."""
    p = np.asarray(pts, float)
    p = np.vstack((2 * p[0] - p[1], p, 2 * p[-1] - p[-2]))
    out = []
    per = max(2, n // (len(p) - 3))
    for i in range(1, len(p) - 2):
        for t in np.linspace(0, 1, per, endpoint=False):
            a, b, c, d = p[i - 1], p[i], p[i + 1], p[i + 2]
            out.append(0.5 * (2 * b + (c - a) * t + (2 * a - 5 * b + 4 * c - d) * t * t + (3 * b - a - 3 * c + d) * t ** 3))
    out.append(p[-2])
    return np.array(out)


def spine(m, pts, widths, n=160):
    """A limb whose thickness follows the given widths, one per control point."""
    c = curve(pts, n)
    w = np.interp(np.linspace(0, 1, len(c)), np.linspace(0, 1, len(widths)), widths)
    d = np.gradient(c, axis=0)
    d /= np.maximum(1e-6, np.linalg.norm(d, axis=1, keepdims=True))
    nrm = np.stack((-d[:, 1], d[:, 0]), axis=1)
    m.spoly(np.concatenate((c + nrm * w[:, None] / 2, (c - nrm * w[:, None] / 2)[::-1])))


def dragon_wing(m, sh, el, wr, tips, attach, f, cx, cy, k):
    """Bat wing, membrane scalloped between the finger tips. Small and far off, so no finger bones."""
    P = lambda p: (cx + f * p[0] * k, cy + p[1] * k)
    outline = [P(wr)]
    outline += [tuple(q) for q in bez(P(wr), P(((wr[0] + tips[0][0]) / 2 + 3, (wr[1] + tips[0][1]) / 2 - 5)), P(tips[0]), n=14)]
    chain = list(tips) + [attach]
    for a, b in zip(chain[:-1], chain[1:]):
        mid = ((a[0] + b[0]) / 2, (a[1] + b[1]) / 2)
        pull = (mid[0] + (wr[0] - mid[0]) * 0.20, mid[1] + (wr[1] - mid[1]) * 0.20)
        outline += [tuple(q) for q in bez(P(a), P(pull), P(b), n=14)]
    outline += [P(sh), P(el)]
    m.spoly(outline)


def dragon_body(m, cx, cy, k, f):
    P = lambda p: (cx + f * p[0] * k, cy + p[1] * k)
    # tail, body, neck and head as one sweep
    pts = [(-124, 2), (-100, 13), (-74, 11), (-46, 1), (-16, 1), (8, 2), (26, -5), (42, -18), (52, -29), (64, -33)]
    wid = [0.5, 1.4, 2.6, 5.2, 10.5, 12.5, 8.5, 5.4, 4.4, 4.0]
    spine(m, [P(p) for p in pts], [w * k for w in wid])
    m.spoly([P(p) for p in [(58, -37), (66, -39.5), (73, -37.5), (87, -33), (88, -30), (73, -27), (60, -27)]])
    spine(m, [P((64, -38)), P((54, -46)), P((42, -49))], [2.6 * k, 1.4 * k, 0.3 * k], n=20)


def dragon(s, cx, cy, k, f):
    """The old Raid Nights dragon, a long way off now and minding its own business."""
    m = s.mask()
    dragon_wing(m, (16, -4), (34, -22), (55, -42), [(36, -66), (15, -62), (7, -40), (10, -20)], (10, -6), f, cx, cy, k)
    dragon_wing(m, (8, -3), (-8, -26), (14, -50), [(-38, -67), (-73, -52), (-86, -27), (-66, -8)], (-30, -2), f, cx, cy, k)
    dragon_body(m, cx, cy, k, f)
    s.paint(m, "#05030a")


def figure(x, base, h, f=1):
    """Local coordinates for one party member: u forward, v up, as fractions of h."""
    return lambda u, v: (x + u * h * f, base - v * h)


def pauldron(m, P, h, u, v, r, spikes=3):
    """The thing that makes it Warcraft: a shoulder the size of a head, with spikes on it."""
    cx, cy = P(u, v)
    m.ellipse(cx, cy, r * h, r * h * 0.82)
    for k in range(spikes):
        t = (k - (spikes - 1) / 2) * 0.62
        d = np.array([np.sin(t), -np.cos(t)])
        n = np.array([d[1], -d[0]])
        c = np.array([cx, cy])
        base = c + d * r * h * 0.6
        m.spoly([tuple(base + n * r * h * 0.3), tuple(c + d * r * h * 1.8), tuple(base - n * r * h * 0.3)])


def legs(m, P, h, spread=0.13, thick=0.11):
    m.stroke(np.array([P(-0.04, 0.5), P(-spread, 0.03)]), h * thick * 1.2, h * thick)
    m.stroke(np.array([P(0.04, 0.5), P(spread, 0.03)]), h * thick * 1.2, h * thick)
    for u in (-spread, spread):
        m.spoly([P(u - 0.07, 0.0), P(u - 0.06, 0.07), P(u + 0.07, 0.07), P(u + 0.12, 0.0)])


def tank(m, x, base, h, hand):
    """Biggest of the lot and the only one who read the plan: spikes, horns, the back end of the ram."""
    P = figure(x, base, h)
    legs(m, P, h, spread=0.17, thick=0.14)
    m.spoly([P(-0.2, 0.84), P(0.22, 0.84), P(0.19, 0.46), P(-0.17, 0.46)])
    m.spoly([P(-0.2, 0.5), P(0.2, 0.5), P(0.25, 0.3), P(0.04, 0.34), P(-0.25, 0.3)])
    pauldron(m, P, h, -0.21, 0.82, 0.17)
    pauldron(m, P, h, 0.21, 0.82, 0.15)
    # horned helm, and the arms going down to the ram
    m.ellipse(*P(0.02, 0.93), h * 0.095, h * 0.105)
    m.stroke(bez(P(-0.06, 0.97), P(-0.2, 1.0), P(-0.17, 1.17), n=10), h * 0.055, h * 0.012)
    m.stroke(bez(P(0.09, 0.97), P(0.23, 1.0), P(0.2, 1.17), n=10), h * 0.055, h * 0.012)
    m.stroke(np.array([P(0.18, 0.76), hand]), h * 0.1, h * 0.085)
    m.stroke(np.array([P(-0.14, 0.72), P(0.02, 0.5), (hand[0] - h * 0.24, hand[1] + h * 0.02)]), h * 0.1, h * 0.085)


def dwarf(m, x, base, h, hand):
    """Half the height, same width, beard to the belt. Takes the front of the ram because he's already low."""
    P = figure(x, base, h)
    legs(m, P, h, spread=0.2, thick=0.2)
    m.spoly([P(-0.34, 0.78), P(0.34, 0.78), P(0.34, 0.34), P(-0.34, 0.34)])
    m.ellipse(*P(0, 0.56), h * 0.38, h * 0.3)
    pauldron(m, P, h, -0.34, 0.76, 0.2, spikes=2)
    pauldron(m, P, h, 0.3, 0.76, 0.17, spikes=2)
    # helm with proper horns, and the beard out the front of it
    m.ellipse(*P(0.06, 0.92), h * 0.17, h * 0.16)
    m.stroke(bez(P(-0.05, 1.0), P(-0.3, 1.04), P(-0.28, 1.3), n=10), h * 0.09, h * 0.015)
    m.stroke(bez(P(0.17, 1.0), P(0.42, 1.04), P(0.38, 1.3), n=10), h * 0.09, h * 0.015)
    m.spoly(bez(P(0.0, 0.88), P(0.14, 0.62), P(0.28, 0.4), n=10).tolist() + bez(P(0.28, 0.4), P(0.36, 0.66), P(0.24, 0.88), n=10).tolist())
    m.stroke(np.array([P(0.28, 0.68), hand]), h * 0.15, h * 0.13)
    m.stroke(np.array([P(-0.22, 0.64), (hand[0] - h * 0.56, hand[1] + h * 0.06)]), h * 0.15, h * 0.13)


def paladin(m, hammer, x, base, h):
    """Plate, a cape, and a hammer the size of a bar fridge over one shoulder. The hammer goes in its own mask."""
    P = figure(x, base, h)
    # cape first, streaming back
    m.spoly(bez(P(-0.12, 0.84), P(-0.34, 0.6), P(-0.4, 0.3), P(-0.44, 0.04), n=12).tolist() + [P(-0.1, 0.06), P(0.0, 0.5)])
    legs(m, P, h, spread=0.11, thick=0.12)
    m.spoly([P(-0.16, 0.82), P(0.18, 0.82), P(0.14, 0.46), P(-0.13, 0.46)])
    m.spoly([P(-0.15, 0.5), P(0.15, 0.5), P(0.19, 0.32), P(-0.19, 0.32)])
    # big smooth domes on the shoulders, the holy kind
    for u, r in ((-0.19, 0.145), (0.2, 0.13)):
        m.ellipse(*P(u, 0.83), r * h, r * h * 0.85)
    m.ellipse(*P(0.02, 0.92), h * 0.085, h * 0.095)
    m.spoly([P(-0.03, 1.0), P(0.03, 1.15), P(0.07, 0.99)])
    # the arm up to the haft
    m.stroke(np.array([P(0.18, 0.78), P(0.26, 0.6), P(0.2, 0.62)]), h * 0.09, h * 0.08)
    a, b = P(0.26, 0.48), P(-0.13, 1.42)
    m.stroke(np.array([a, b]), h * 0.045, h * 0.045)
    d = (np.array(b) - np.array(a))
    d = d / np.linalg.norm(d)
    n = np.array([-d[1], d[0]])
    c = np.array(b)
    # the head: a block with flared faces, so it's a hammer and not a plank
    hw, hl, fl = h * 0.25, h * 0.085, h * 0.135
    hammer.spoly([tuple(c + n * hw + d * fl), tuple(c + n * hw * 0.62 + d * hl), tuple(c - n * hw * 0.62 + d * hl), tuple(c - n * hw + d * fl),
                  tuple(c - n * hw - d * fl), tuple(c - n * hw * 0.62 - d * hl), tuple(c + n * hw * 0.62 - d * hl), tuple(c + n * hw - d * fl)])


def rogue(m, x, base, h):
    """Skinny, crouched, hood to a point, one knife forward and one behind. Here for whatever's not bolted down."""
    P = figure(x, base, h)
    m.stroke(np.array([P(-0.06, 0.5), P(-0.17, 0.27), P(-0.2, 0.03)]), h * 0.1, h * 0.075)
    m.stroke(np.array([P(0.03, 0.5), P(0.2, 0.33), P(0.14, 0.03)]), h * 0.1, h * 0.075)
    for u in (-0.2, 0.14):
        m.spoly([P(u - 0.06, 0.0), P(u - 0.05, 0.05), P(u + 0.05, 0.05), P(u + 0.1, 0.0)])
    # back bent forward, cloak hanging off it in tatters
    m.spoly(bez(P(-0.08, 0.46), P(-0.16, 0.66), P(0.06, 0.8), n=10).tolist() + [P(0.2, 0.72), P(0.12, 0.46)])
    m.spoly(bez(P(-0.03, 0.78), P(-0.22, 0.66), P(-0.34, 0.42), n=10).tolist() + [P(-0.24, 0.45), P(-0.25, 0.3), P(-0.14, 0.42), P(-0.1, 0.5)])
    # the hood
    m.spoly(bez(P(0.03, 0.74), P(0.0, 0.88), P(0.08, 0.98), n=8).tolist() + [P(-0.06, 1.1), P(0.2, 0.96), P(0.27, 0.84), P(0.2, 0.74)])
    # knives
    m.stroke(np.array([P(0.14, 0.7), P(0.36, 0.58)]), h * 0.065, h * 0.055)
    m.spoly([P(0.34, 0.63), P(0.72, 0.68), P(0.36, 0.54)])
    m.stroke(np.array([P(-0.04, 0.7), P(-0.25, 0.68)]), h * 0.065, h * 0.055)
    m.spoly([P(-0.22, 0.73), P(-0.54, 0.92), P(-0.27, 0.64)])


def mage(m, x, base, h):
    """Dress, pointy hat, stick. Stands at the back and won't be going through any doors. Returns the staff's top."""
    P = figure(x, base, h)
    m.spoly(bez(P(-0.1, 0.8), P(-0.16, 0.45), P(-0.3, 0.0), n=10).tolist() + bez(P(0.3, 0.0), P(0.14, 0.45), P(0.11, 0.8), n=10).tolist())
    m.ellipse(*P(-0.14, 0.78), h * 0.1, h * 0.08)
    m.ellipse(*P(0.14, 0.78), h * 0.1, h * 0.08)
    m.ellipse(*P(0.01, 0.89), h * 0.08, h * 0.085)
    # brim and a hat with a bend in it
    m.stroke(bez(P(-0.27, 0.93), P(0.01, 0.98), P(0.29, 0.9), n=10), h * 0.04, h * 0.03)
    m.spoly([P(-0.12, 0.94), P(0.15, 0.94)] + bez(P(0.15, 0.94), P(0.05, 1.12), P(-0.15, 1.28), n=10).tolist() + bez(P(-0.15, 1.28), P(-0.08, 1.1), P(-0.12, 0.94), n=8).tolist())
    # staff in the front hand, a claw on top to hold the light
    sx = 0.36
    m.stroke(np.array([P(sx, 0.0), P(sx, 1.25)]), h * 0.032, h * 0.028)
    m.stroke(np.array([P(0.14, 0.72), P(sx, 0.62)]), h * 0.085, h * 0.07)
    m.stroke(bez(P(sx, 1.2), P(sx - 0.12, 1.28), P(sx - 0.07, 1.41), n=10), h * 0.032, h * 0.012)
    m.stroke(bez(P(sx, 1.2), P(sx + 0.12, 1.28), P(sx + 0.07, 1.41), n=10), h * 0.032, h * 0.012)
    return P(sx, 1.32)


def ram(m, steel, x0, y0, x1, y1, w):
    """A tree trunk with a lump of iron on the end, blunt, because it's a door and not a dragon. The iron
    goes in its own mask, so it can catch the light."""
    a, b = np.array([x0, y0], float), np.array([x1, y1], float)
    d = (b - a) / np.linalg.norm(b - a)
    n = np.array([-d[1], d[0]])
    m.spoly([tuple(a + n * w / 2), tuple(b + n * w / 2), tuple(b - n * w / 2), tuple(a - n * w / 2)])
    head = b - d * w * 1.1
    steel.spoly([tuple(head + n * w * 0.62), tuple(head + n * w * 0.9 + d * w * 0.5), tuple(b + n * w * 0.9), tuple(b + n * w * 0.62 + d * w * 0.3),
                 tuple(b - n * w * 0.62 + d * w * 0.3), tuple(b - n * w * 0.9), tuple(head - n * w * 0.9 + d * w * 0.5), tuple(head - n * w * 0.62)])
    for t in (0.3, 0.62):
        c = a + (b - a) * t
        steel.spoly([tuple(c + n * w * 0.6 - d * 0.9), tuple(c + n * w * 0.6 + d * 0.9), tuple(c - n * w * 0.6 + d * 0.9), tuple(c - n * w * 0.6 - d * 0.9)])


def runner(m, x, base, h):
    """Hoodie, flat out, heading left. He heard them come up the drive about ten minutes ago."""
    P = figure(x, base, h, f=-1)
    # the back leg kicked out, the front knee up, one runner off the ground
    m.stroke(np.array([P(0.02, 0.5), P(-0.22, 0.34), P(-0.5, 0.26)]), h * 0.115, h * 0.075)
    m.spoly([P(-0.47, 0.34), P(-0.6, 0.34), P(-0.63, 0.2), P(-0.5, 0.2)])
    m.stroke(np.array([P(0.06, 0.5), P(0.34, 0.42), P(0.26, 0.1)]), h * 0.115, h * 0.075)
    m.spoly([P(0.2, 0.13), P(0.28, 0.13), P(0.44, 0.04), P(0.44, 0.0), P(0.2, 0.0)])
    # jumper leaning hard into it
    m.spoly(bez(P(-0.1, 0.46), P(-0.12, 0.72), P(0.1, 0.88), n=10).tolist() + bez(P(0.1, 0.88), P(0.3, 0.84), P(0.32, 0.64), n=8).tolist() + [P(0.14, 0.44)])
    # arms pumping
    m.stroke(np.array([P(0.2, 0.76), P(0.42, 0.56), P(0.56, 0.7)]), h * 0.085, h * 0.065)
    m.stroke(np.array([P(0.04, 0.76), P(-0.2, 0.6), P(-0.3, 0.74)]), h * 0.085, h * 0.065)
    # hood, pushed forward
    m.spoly(bez(P(0.06, 0.84), P(0.08, 0.98), P(0.22, 1.05), n=10).tolist() + bez(P(0.22, 1.05), P(0.4, 1.03), P(0.42, 0.88), n=8).tolist() + [P(0.32, 0.8)])


def wagon(s, x0, base, wide):
    """Paddy wagon, nose to the house: a ute with a steel box on the back and the word down its side,
    low enough to sit clear of the page buttons. Returns the light bar's two ends."""
    u = wide / 150.0

    def P(a, b):
        return (x0 + a * u, base - b)

    m = s.mask()
    body = [P(0, 11), P(1, 26), P(5, 30), P(33, 34), P(50, 50), P(66, 51), P(66, 56), P(150, 56), P(150, 11)]
    m.spoly(body)
    s.paint(m, "#1a2130", bottom="#0d1019", top_y=60, rim=0.5, rim_dx=-0.6, rim_dy=-0.7, rim_colour="#8fb0ff")
    # glass, and the steel cage down the box
    g = s.mask()
    g.spoly([P(38, 33), P(51, 47), P(62, 47), P(62, 33)])
    s.paint(g, "#2c3d66", bottom="#121a30", top_y=base - 60)
    cage = s.mask()
    for k in range(9):
        cage.rect(*P(72 + k * 8, 52), *P(73 + k * 8, 36))
    cage.rect(*P(72, 52), *P(136, 51))
    cage.rect(*P(72, 37), *P(136, 36))
    s.paint(cage, "#6e7c9a")
    # the checker strip and the wheels
    ch = s.mask()
    for k in range(18):
        ch.rect(*P(6 + k * 8, 11.5), *P(10 + k * 8, 8.5))
    s.paint(ch, "#d7e0ee")
    w = s.mask()
    for a in (26, 122):
        c = P(a, 8)
        w.ellipse(c[0], c[1], 9.5 * u, 9.5 * u, fill=255)
    s.paint(w, "#03040a")
    h = s.mask()
    for a in (26, 122):
        c = P(a, 8)
        h.ellipse(c[0], c[1], 3.8 * u, 3.8 * u)
    s.paint(h, "#5a6072")
    # POLICE, the one generic word on the picture, low between the wheels: New raid sits above y 117
    t = s.mask()
    lettering(t, "POLICE", x0 + 74 * u, base - 18.2, 11.5, font=STENCIL, spacing=0.8)
    s.paint(t, "#eef3ff")
    s.rgb += gauss(t.array(), 1.2 * SS)[..., None] * s.colour("#9fb8ff") * 0.18
    # bar on the cab roof
    ax, ay = P(47, 54)
    bx, by = P(66, 54)
    bar = s.mask()
    bar.rrect(ax, ay - 1, bx, ay + 3.4, 1)
    s.paint(bar, "#05060c")
    return (ax + 4, ay), (bx - 4, by)


def paint():
    s = Scene(MOOD, seed=14, horizon=118)
    s.sky(clouds=0.4, stars=0.6, glow_x=0.7, glow_w=0.22)
    s.moon(676, 27, 19, tint="#f7e6cb", glow=0.5, seed=3)
    s.moon(622, 15, 7.5, tint="#a9c6ff", glow=0.42, seed=9)
    # the dragon, on its way to somebody else's problem
    dragon(s, 676, 34, 0.2, -1)

    # the far side of the street: low rooves, nobody's lights on, nobody saw anything
    m = s.mask()
    for x, w, h in ((540, 40, 16), (830, 36, 22), (880, 44, 19), (940, 50, 22), (990, 40, 16)):
        m.spoly([(x, 125), (x, 125 - h * 0.6), (x + w * 0.25, 125 - h), (x + w * 0.75, 125 - h), (x + w, 125 - h * 0.6), (x + w, 125)])
    for i, x in enumerate((320, 420, 500, 840, 925, 1000)):
        gum_tree(m, x, 126, 32 + (i * 37) % 18, seed=70 + i, leaves=0.9)
    m.rect(0, 122, 1040, 148)
    s.paint(m, "#120e24", rim=0.10)
    s.fog(100, 128, strength=0.2, seed=6)

    # the lawn, gone purple under the lights
    ground = s.mask()
    g = [(0, 148)] + [(x, 136.5 + 0.8 * np.sin(x / 70)) for x in range(0, 1042, 8)] + [(1040, 148)]
    ground.spoly(g)
    s.paint(ground, "#0a0812")

    # the cottage: fibro, low pitch, one sagging veranda down the front
    hx0, hx1, wy, by = 584, 812, 84, 140
    wall = s.mask()
    wall.rect(hx0, wy, hx1, by)
    s.paint(wall, "#1e1c26")
    a = wall.array()
    # the two lights working across the fibro, red from the left of the bar, blue from the right
    X, Y = s.X / SS, s.Y / SS
    red = np.exp(-(((X - 668) / 62) ** 2))
    blue = np.exp(-(((X - 772) / 56) ** 2))
    s.rgb += (a * red)[..., None] * s.colour(RED) * 0.62
    s.rgb += (a * blue)[..., None] * s.colour(BLUE) * 0.62
    # the sheet joins
    j = s.mask()
    for x in range(hx0 + 14, hx1, 28):
        j.rect(x, wy, x + 0.5, by)
    s.rgb *= (1 - j.array() * 0.28)[..., None]
    roof = s.mask()
    roof.spoly([(hx0 - 10, wy), (hx0 + 36, 60), (hx1 - 36, 60), (hx1 + 10, wy)])
    roof.rect(hx1 - 62, 49, hx1 - 52, 64)
    roof.line([(hx0 + 62, 60), (hx0 + 62, 42)], 0.7)
    for k in range(4):
        roof.line([(hx0 + 62 - 8 + k * 1.3, 43 + k * 2.2), (hx0 + 62 + 8 - k * 1.3, 43 + k * 2.2)], 0.5)
    s.paint(roof, "#0c0a14", rim=0.7, rim_dx=-0.3, rim_dy=-0.8, rim_colour="#b98cc8")
    eave = s.mask()
    eave.spoly([(hx0 - 8, 84), (hx1 + 8, 84), (hx1 + 8, 88), (hx0 - 8, 88)])
    s.paint(eave, "#07060c")

    # the side window, wide open with a lamp still on, and foil on the one they haven't got to yet
    win = s.mask()
    win.rect(590, 101, 610, 123)
    wa = win.array()
    s.rgb = s.rgb * (1 - wa[..., None]) + s.colour("#ffc27a") * wa[..., None]
    s.rgb += gauss(wa, 5 * SS)[..., None] * s.colour("#ffb060") * 0.3
    frm = s.mask()
    frm.rect(587.5, 98.5, 612.5, 101)
    frm.rect(587.5, 123, 612.5, 125.5)
    frm.rect(587.5, 98.5, 590, 125.5)
    frm.rect(610, 98.5, 612.5, 125.5)
    frm.spoly([(590, 101), (599, 95), (599, 118), (590, 123)])
    s.paint(frm, "#08070e")
    foil_window(s, 620, 98, 22, 26, seed=4, strength=0.8)

    # the door: every light on the street's pointing at it, and it's about to have a very bad night
    door = s.mask()
    door.rect(784, 92, 806, 140)
    da = door.array()
    s.rgb = s.rgb * (1 - da[..., None]) + s.colour(HOT) * 0.8 * da[..., None]
    s.rgb += gauss(da, 3.5 * SS)[..., None] * s.colour(HOT) * 0.28
    s.rgb += gauss(da, 12 * SS)[..., None] * s.colour("#fff0d0") * 0.13
    d2 = s.mask()
    d2.rect(788, 97, 802, 113)
    d2.rect(788, 118, 802, 135)
    d2.ellipse(787, 118, 1.2, 1.2)
    s.rgb *= (1 - d2.array() * 0.16)[..., None]
    fr = s.mask()
    fr.rect(782, 90, 784, 140)
    fr.rect(806, 90, 808, 140)
    fr.rect(782, 89.5, 808, 92)
    s.paint(fr, "#06050b")

    # the stack, by rank: the short bloke on the iron end, the bloke with the plan at the back
    party, steel, gold = s.mask(), s.mask(), s.mask()
    bb = 140
    mage_top = mage(party, 642, bb, 40)
    rogue(party, 672, bb, 37)
    paladin(party, gold, 703, bb, 44)
    tank(party, 738, bb, 48, (748, 110))
    dwarf(party, 766, bb, 31, (771, 118))
    wood, steel = s.mask(), s.mask()
    ram(wood, steel, 714, 103, 783, 122, 8.5)
    # a hard shadow behind them on the fibro, thrown left by the bar
    sh = np.roll(party.array(), -int(5 * SS), axis=1)
    sh = gauss(sh, 0.6 * SS) * wall.array()
    s.rgb *= (1 - sh * 0.45)[..., None]
    s.paint(party, ARMOUR)
    lit_rim(s, party, 795, 116, 90, HOT, 1.5, soft=0.35)
    lit_rim(s, party, 880, 80, 240, "#6c98ff", 1.0, soft=0.35)
    lit_rim(s, party, 600, 100, 130, "#ff4656", 1.35, soft=0.35)
    # the ram goes over the top of them, the only pale thing in the stack, so it's plain what it is
    s.paint(wood, "#7a5a3c", bottom="#4a3322", top_y=60, rim=0.9, rim_dx=0, rim_dy=-0.8, rim_colour="#ffc0a0")
    s.paint(steel, "#59616f", rim=0.9, rim_dx=0, rim_dy=-0.7, rim_colour="#ffffff")
    lit_rim(s, steel, 795, 116, 40, HOT, 2.2, soft=0.3)
    # the one bit of gold: the Light, on a hammer, for all the good it'll do
    s.paint(gold, "#b98a2c", rim=0.8, rim_dx=0.6, rim_dy=-0.6, rim_colour="#fff0b8")
    s.rgb += gauss(gold.array(), 2.5 * SS)[..., None] * s.colour("#ffc65a") * 0.45
    # and the glow on the mage's stick
    mx, my = mage_top
    s.glow(mx, my, 9, "#55d8ff", 0.55)
    s.glow(mx, my, 2.6, "#e8fbff", 1.4)

    # out the window and over the verge
    m = s.mask()
    runner(m, 558, 139, 35)
    s.paint(m, "#05050b")
    lit_rim(s, m, 610, 110, 70, "#ffb060", 1.0, soft=0.3)
    lit_rim(s, m, 620, 80, 150, "#ff4656", 0.7, soft=0.3)

    # the wagon, and what it's doing to the night
    (rx, ry), (bx, byy) = wagon(s, 846, 141, 146)
    s.beam(rx, ry, 196, 11, 150, colour=RED, strength=0.25, soft=2.2)
    s.beam(rx, ry, 245, 7, 70, colour=RED, strength=0.25, soft=2.0)
    s.beam(bx, byy, 325, 8, 70, colour=BLUE, strength=0.31, soft=2.0)
    s.beam(bx, byy, 186, 9, 170, colour=BLUE, strength=0.24, soft=2.2)
    s.glow(rx, ry, 40, RED, 0.26)
    s.glow(bx, byy, 40, BLUE, 0.32)
    s.glow(rx, ry, 4, "#ff8a90", 1.3)
    s.glow(bx, byy, 4, "#9cc0ff", 1.5)
    # pools on the lawn
    ga = ground.array()
    s.rgb += (ga * np.exp(-(((s.X / SS - 700) / 95) ** 2)))[..., None] * s.colour(RED) * 0.22
    s.rgb += (ga * np.exp(-(((s.X / SS - 840) / 80) ** 2)))[..., None] * s.colour(BLUE) * 0.28

    # the gums frame it, and one for the title to sit against
    m = s.mask()
    gum_tree(m, 1084, 172, 140, seed=8, lean=0.1, spread=0.7)
    gum_tree(m, 236, 176, 170, seed=12, lean=0.06)
    s.paint(m, "#040308")
    # keep the left of the sky low so the page title has a calm dark bed
    s.rgb *= (0.42 + 0.58 * smooth(430 * SS, 640 * SS, s.X))[..., None]
    return s.finish(bloom=0.22)
