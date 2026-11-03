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


def limb(m, P, h, pts, widths):
    """A jointed limb in local coordinates: straight bones and round joints, widths in fractions of h."""
    q = [np.array(P(*p), float) for p in pts]
    w = [k * h for k in widths]
    for a, b, wa, wb in zip(q[:-1], q[1:], w[:-1], w[1:]):
        d = (b - a) / max(1e-6, np.linalg.norm(b - a))
        n = np.array([-d[1], d[0]])
        m.spoly([tuple(a + n * wa / 2), tuple(b + n * wb / 2), tuple(b - n * wb / 2), tuple(a - n * wa / 2)])
    for c, r in zip(q, w):
        m.ellipse(c[0], c[1], r / 2, r / 2)


def boot(m, P, u, size=1.0):
    """A boot flat on the ground under an ankle at u, toe forward."""
    s = size
    m.spoly([P(u - 0.06 * s, 0.0), P(u - 0.055 * s, 0.085 * s), P(u + 0.05 * s, 0.085 * s), P(u + 0.14 * s, 0.035 * s), P(u + 0.14 * s, 0.0)])


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


def tank(m, near, x, base, h):
    """Biggest of the lot and the only one who read the plan: spikes, horns, the back end of the ram, and
    leaning into it from the back foot. The near arm goes in its own mask, over the ram."""
    P = figure(x, base, h)
    # back leg driving, front knee bent
    limb(m, P, h, [(-0.06, 0.48), (-0.2, 0.27), (-0.34, 0.06)], [0.19, 0.13, 0.1])
    boot(m, P, -0.34, 1.15)
    limb(m, P, h, [(0.07, 0.48), (0.26, 0.31), (0.2, 0.06)], [0.19, 0.13, 0.1])
    boot(m, P, 0.2, 1.15)
    # the barrel of him, tipped forward, and plate skirts
    m.spoly([P(-0.19, 0.44), P(-0.2, 0.62), P(-0.1, 0.86), P(0.2, 0.88), P(0.25, 0.66), P(0.18, 0.44)])
    m.spoly([P(-0.2, 0.5), P(0.19, 0.5), P(0.25, 0.33), P(0.03, 0.38), P(-0.27, 0.32)])
    # helm sunk between the shoulders, and two horns you could hang a coat on
    m.ellipse(*P(0.2, 0.97), h * 0.1, h * 0.105)
    m.spoly([P(0.25, 0.94), P(0.36, 0.9), P(0.27, 0.87)])
    m.stroke(bez(P(0.13, 1.03), P(-0.04, 1.06), P(-0.02, 1.25), n=10), h * 0.06, h * 0.012)
    m.stroke(bez(P(0.25, 1.05), P(0.38, 1.1), P(0.33, 1.27), n=10), h * 0.06, h * 0.012)
    # the far arm, out front of the chest, and its hand on the wood
    limb(m, P, h, [(0.2, 0.78), (0.4, 0.62), (0.46, 0.44)], [0.1, 0.09, 0.08])
    # the near arm and the great spiked shoulder it hangs off
    limb(near, P, h, [(0.05, 0.78), (0.2, 0.6), (0.3, 0.42)], [0.12, 0.1, 0.085])
    near.ellipse(*P(0.31, 0.415), h * 0.062, h * 0.062)
    near.ellipse(*P(0.46, 0.415), h * 0.056, h * 0.056)
    pauldron(near, P, h, 0.03, 0.84, 0.17)


def dwarf(m, near, x, base, h):
    """Half the height, same width, beard to the belt. Takes the front of the ram because he's already low."""
    P = figure(x, base, h)
    # stumps, wide apart, a clear gap between them
    limb(m, P, h, [(-0.12, 0.42), (-0.2, 0.22), (-0.2, 0.08)], [0.25, 0.2, 0.18])
    boot(m, P, -0.2, 1.5)
    limb(m, P, h, [(0.14, 0.42), (0.22, 0.22), (0.2, 0.08)], [0.25, 0.2, 0.18])
    boot(m, P, 0.2, 1.5)
    # a keg with arms
    m.ellipse(*P(0, 0.58), h * 0.33, h * 0.27)
    m.ellipse(*P(0.04, 0.73), h * 0.3, h * 0.13)
    # helm: a dome, a nasal, and stub horns either side
    m.ellipse(*P(0.1, 0.91), h * 0.16, h * 0.15)
    m.stroke(bez(P(0.0, 0.98), P(-0.2, 1.0), P(-0.22, 1.2), n=10), h * 0.085, h * 0.015)
    m.stroke(bez(P(0.2, 1.0), P(0.36, 1.04), P(0.34, 1.22), n=10), h * 0.085, h * 0.015)
    # the near arm over the ram, and the beard over the arm, blown out front because he's going forward
    limb(near, P, h, [(-0.08, 0.74), (0.04, 0.58), (0.16, 0.56)], [0.15, 0.13, 0.11])
    near.ellipse(*P(0.18, 0.555), h * 0.095, h * 0.095)
    near.ellipse(*P(0.27, 0.53), h * 0.075, h * 0.075)
    near.spoly(bez(P(0.08, 0.87), P(0.14, 0.72), P(0.26, 0.64), n=10).tolist() + bez(P(0.26, 0.64), P(0.42, 0.74), P(0.27, 0.88), n=10).tolist())
    pauldron(near, P, h, -0.14, 0.76, 0.14, spikes=2)


def paladin(m, cape, hammer, bands, haft, fists, x, base, h):
    """Plate, a cape, and a hammer the size of a bar fridge, carried across the chest in both fists. The
    hammer, the haft and the fists each go in their own mask, so the fists sit over the haft."""
    P = figure(x, base, h)
    # cape first, streaming back and clear of the back leg, in its own mask so it isn't more armour
    cape.spoly(bez(P(-0.05, 0.86), P(-0.3, 0.72), P(-0.38, 0.4), P(-0.47, 0.06), n=12).tolist()
               + [P(-0.36, 0.11), P(-0.31, 0.03), P(-0.23, 0.12), P(-0.17, 0.3), P(-0.1, 0.55)])
    # striding: back leg long, front foot flat
    limb(m, P, h, [(-0.04, 0.48), (-0.09, 0.27), (-0.17, 0.06)], [0.15, 0.1, 0.08])
    boot(m, P, -0.17)
    limb(m, P, h, [(0.05, 0.48), (0.16, 0.28), (0.16, 0.06)], [0.15, 0.1, 0.08])
    boot(m, P, 0.16)
    # breastplate, chest out, wasp waist, skirt of plates
    m.spoly([P(-0.15, 0.84), P(0.16, 0.84), P(0.2, 0.7), P(0.11, 0.5), P(-0.11, 0.5), P(-0.14, 0.66)])
    m.spoly([P(-0.14, 0.53), P(0.13, 0.53), P(0.2, 0.36), P(-0.2, 0.36)])
    # the helm, and the crest off the back of it
    m.ellipse(*P(0.03, 0.96), h * 0.085, h * 0.095)
    m.spoly([P(0.08, 0.95), P(0.15, 0.93), P(0.09, 0.89)])
    m.stroke(bez(P(0.03, 1.05), P(-0.07, 1.12), P(-0.16, 1.03), n=10), h * 0.05, h * 0.012)
    # big smooth dome on the shoulder, the holy kind, and an arm down to each fist
    limb(m, P, h, [(0.1, 0.8), (0.23, 0.5), (0.31, 0.58)], [0.09, 0.08, 0.07])
    limb(m, P, h, [(0.0, 0.8), (0.03, 0.6), (0.13, 0.68)], [0.1, 0.09, 0.075])
    m.ellipse(*P(-0.01, 0.83), h * 0.135, h * 0.115)
    # the haft, from below the front fist, across the chest and out past the back shoulder
    lo, hi = np.array(P(0.42, 0.51), float), np.array(P(-0.4, 1.02), float)
    haft.stroke(np.array([lo, hi]), h * 0.05, h * 0.05)
    u = hi - lo
    for t in (0.135, 0.355):
        c = lo + u * t
        fists.ellipse(c[0], c[1], h * 0.058, h * 0.062)
    # the head: a proper maul, square across the end of the haft, flat faces and two iron bands
    d = (hi - lo) / np.linalg.norm(hi - lo)
    n = np.array([-d[1], d[0]])
    hw, hl = h * 0.22, h * 0.1
    hammer.spoly([tuple(hi + n * hw + d * hl), tuple(hi + n * hw - d * hl), tuple(hi - n * hw - d * hl), tuple(hi - n * hw + d * hl)])
    for k in (-0.62, 0.62):
        c = hi + n * hw * k
        bands.spoly([tuple(c + n * h * 0.016 + d * hl), tuple(c - n * h * 0.016 + d * hl), tuple(c - n * h * 0.016 - d * hl), tuple(c + n * h * 0.016 - d * hl)])


def rogue(m, blades, x, base, h):
    """Skinny, crouched, hood to a point, one knife forward and one behind. Here for whatever's not bolted down."""
    P = figure(x, base, h)
    # low on bent legs, tiptoeing up a lawn with five blokes and a tree trunk
    limb(m, P, h, [(-0.04, 0.45), (-0.2, 0.26), (-0.32, 0.05)], [0.13, 0.08, 0.06])
    boot(m, P, -0.32, 0.85)
    limb(m, P, h, [(0.03, 0.45), (0.25, 0.34), (0.2, 0.05)], [0.13, 0.08, 0.06])
    boot(m, P, 0.2, 0.85)
    # back bent right over
    limb(m, P, h, [(-0.01, 0.45), (0.13, 0.72)], [0.17, 0.2])
    # the hood, its point out the back
    m.spoly(bez(P(0.12, 0.72), P(0.04, 0.8), P(-0.1, 1.02), n=8).tolist() + bez(P(-0.1, 1.02), P(0.14, 1.02), P(0.3, 0.9), n=10).tolist() + [P(0.31, 0.83), P(0.24, 0.72)])
    # knife arm out front
    limb(m, P, h, [(0.15, 0.7), (0.31, 0.54), (0.46, 0.6)], [0.085, 0.07, 0.06])
    m.ellipse(*P(0.47, 0.6), h * 0.048, h * 0.048)
    blades.spoly([P(0.5, 0.64), P(0.8, 0.7), P(0.5, 0.57)])
    # and the other one up behind him
    limb(m, P, h, [(0.08, 0.7), (-0.13, 0.62), (-0.26, 0.72)], [0.085, 0.07, 0.06])
    m.ellipse(*P(-0.27, 0.73), h * 0.048, h * 0.048)
    blades.spoly([P(-0.3, 0.75), P(-0.42, 1.03), P(-0.24, 0.77)])


def mage(m, staff, fist, x, base, h):
    """Dress, pointy hat, stick. Stands at the back and won't be going through any doors. The staff and the
    hand on it get their own masks. Returns where the light sits, in the claw on top of the staff."""
    P = figure(x, base, h)
    # the robe, flared to the ground with the back of the hem dragging
    m.spoly(bez(P(-0.08, 0.82), P(-0.14, 0.45), P(-0.36, 0.0), n=10).tolist() + bez(P(0.24, 0.0), P(0.12, 0.45), P(0.1, 0.82), n=10).tolist())
    m.ellipse(*P(0.0, 0.79), h * 0.115, h * 0.08)
    # head poked forward, a beard off it, brim and a hat with a bend in it
    m.ellipse(*P(0.05, 0.89), h * 0.07, h * 0.075)
    m.spoly([P(0.05, 0.85), P(0.13, 0.86), P(0.15, 0.68), P(0.07, 0.76)])
    m.stroke(bez(P(-0.24, 0.92), P(0.03, 0.98), P(0.3, 0.9), n=10), h * 0.04, h * 0.03)
    m.spoly([P(-0.09, 0.94), P(0.15, 0.94)] + bez(P(0.15, 0.94), P(0.07, 1.14), P(-0.15, 1.3), n=10).tolist() + bez(P(-0.15, 1.3), P(-0.07, 1.1), P(-0.09, 0.94), n=8).tolist())
    # staff planted out front, a claw on top to hold the light
    sx = 0.42
    staff.stroke(np.array([P(sx, 0.0), P(sx, 1.0)]), h * 0.05, h * 0.045)
    staff.stroke(bez(P(sx, 0.98), P(sx - 0.14, 1.03), P(sx - 0.1, 1.17), n=10), h * 0.042, h * 0.016)
    staff.stroke(bez(P(sx, 0.98), P(sx + 0.14, 1.03), P(sx + 0.1, 1.17), n=10), h * 0.042, h * 0.016)
    # the arm out to it, and the sleeve hanging off the arm
    limb(m, P, h, [(0.03, 0.76), (0.22, 0.62), (sx, 0.68)], [0.085, 0.07, 0.055])
    m.spoly([P(0.2, 0.66), P(sx - 0.05, 0.7), P(sx - 0.1, 0.46), P(0.27, 0.49)])
    fist.ellipse(*P(sx, 0.68), h * 0.06, h * 0.07)
    return P(sx, 1.09)


def ram(m, steel, x0, y0, x1, y1, w):
    """A tree trunk with a lump of iron on the end, blunt, because it's a door and not a dragon. The iron
    goes in its own mask, so it can catch the light."""
    a, b = np.array([x0, y0], float), np.array([x1, y1], float)
    d = (b - a) / np.linalg.norm(b - a)
    n = np.array([-d[1], d[0]])
    m.spoly([tuple(a + n * w / 2), tuple(b + n * w / 2), tuple(b - n * w / 2), tuple(a - n * w / 2)])
    m.ellipse(a[0], a[1], w / 2, w / 2)
    # a lopped branch, so it's come off a tree
    c = a + d * w * 1.5
    m.spoly([tuple(c + n * w * 0.3), tuple(c - d * 2.6 - n * w * 0.8), tuple(c - d * 4.4 - n * w * 0.8), tuple(c - d * 2.6 + n * w * 0.3)])
    head = b - d * w * 1.1
    steel.spoly([tuple(head + n * w * 0.62), tuple(head + n * w * 0.9 + d * w * 0.5), tuple(b + n * w * 0.9), tuple(b + n * w * 0.62 + d * w * 0.3),
                 tuple(b - n * w * 0.62 + d * w * 0.3), tuple(b - n * w * 0.9), tuple(head - n * w * 0.9 + d * w * 0.5), tuple(head - n * w * 0.62)])
    c = a + (b - a) * 0.42
    steel.spoly([tuple(c + n * w * 0.58 - d * 0.9), tuple(c + n * w * 0.58 + d * 0.9), tuple(c - n * w * 0.58 + d * 0.9), tuple(c - n * w * 0.58 - d * 0.9)])


def runner(m, x, base, h):
    """Hoodie, flat out, heading left. He heard them come up the drive about ten minutes ago."""
    P = figure(x, base, h, f=-1)
    # back leg long behind him, just leaving the ground off the toe
    limb(m, P, h, [(0.0, 0.5), (-0.17, 0.3), (-0.4, 0.14)], [0.13, 0.09, 0.06])
    m.spoly([P(-0.44, 0.17), P(-0.37, 0.1), P(-0.31, 0.0), P(-0.4, 0.0), P(-0.48, 0.1)])
    # front knee up at the hip, shin hanging, foot out ahead of it
    limb(m, P, h, [(0.03, 0.5), (0.31, 0.5), (0.25, 0.24)], [0.13, 0.09, 0.06])
    m.spoly([P(0.21, 0.27), P(0.28, 0.28), P(0.42, 0.2), P(0.42, 0.16), P(0.21, 0.17)])
    # jumper, tipped right over, hem flapping out behind
    m.spoly([P(-0.08, 0.45), P(-0.2, 0.47), P(-0.08, 0.56), P(0.04, 0.84), P(0.25, 0.8), P(0.13, 0.44)])
    # far arm punched out ahead, near arm driving back with the elbow high, daylight round both
    limb(m, P, h, [(0.22, 0.78), (0.42, 0.63), (0.54, 0.8)], [0.085, 0.07, 0.06])
    m.ellipse(*P(0.55, 0.81), h * 0.045, h * 0.045)
    limb(m, P, h, [(0.08, 0.78), (-0.2, 0.76), (-0.22, 0.56)], [0.085, 0.07, 0.06])
    m.ellipse(*P(-0.22, 0.545), h * 0.045, h * 0.045)
    # hood, head down into it, the peak of it blown off the back
    m.spoly(bez(P(0.1, 0.82), P(0.04, 0.9), P(-0.03, 0.96), n=8).tolist() + bez(P(-0.03, 0.96), P(0.14, 1.06), P(0.3, 1.0), n=10).tolist()
            + bez(P(0.3, 1.0), P(0.36, 0.92), P(0.31, 0.83), n=8).tolist() + [P(0.2, 0.78)])


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
    # glass
    g = s.mask()
    g.spoly([P(38, 33), P(51, 47), P(62, 47), P(62, 33)])
    s.paint(g, "#2c3d66", bottom="#121a30", top_y=base - 60)
    # the back window: dark, with a steel frame and diamond mesh over it, so you can't get out or spit through
    gx0, gy0, gx1, gy1 = P(72, 52) + P(138, 35)
    pane = s.mask()
    pane.rect(gx0, gy0, gx1, gy1)
    s.paint(pane, "#060912")
    mesh = s.mask()
    span, gap = gy1 - gy0, 4.2
    for d0 in np.arange(gx0 - span, gx1 + span, gap):
        mesh.line([(d0, gy0), (d0 + span, gy1)], 0.5)
        mesh.line([(d0 + span, gy0), (d0, gy1)], 0.5)
    ma = mesh.array() * pane.array()
    s.rgb = s.rgb * (1 - ma[..., None]) + s.colour("#7f8dab") * ma[..., None]
    fr = s.mask()
    fr.rect(gx0 - 1, gy0 - 1, gx1 + 1, gy0)
    fr.rect(gx0 - 1, gy1, gx1 + 1, gy1 + 1)
    fr.rect(gx0 - 1, gy0, gx0, gy1)
    fr.rect(gx1, gy0, gx1 + 1, gy1)
    s.paint(fr, "#6e7c9a")
    # the chequers: two rows of squares down the flank, nose to tail and cut off by the body's own ends
    white, blue = s.mask(), s.mask()
    sq = 3.3
    y0 = base - 31.6
    for r in range(2):
        for c, xx in enumerate(np.arange(x0 - sq, x0 + wide + sq, sq)):
            (white if (r + c) % 2 == 0 else blue).rect(xx, y0 + r * sq, xx + sq, y0 + (r + 1) * sq)
    ba = m.array()
    wa, bl = white.array() * ba, blue.array() * ba
    s.rgb = s.rgb * (1 - bl[..., None]) + s.colour("#1d3a8c") * bl[..., None]
    s.rgb = s.rgb * (1 - wa[..., None]) + s.colour("#dfe7f2") * wa[..., None]
    # the wheels
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
    s.rgb = s.rgb * (1 - da[..., None]) + s.colour(HOT) * 0.62 * da[..., None]
    s.rgb += gauss(da, 3.5 * SS)[..., None] * s.colour(HOT) * 0.28
    s.rgb += gauss(da, 12 * SS)[..., None] * s.colour("#fff0d0") * 0.13
    d2 = s.mask()
    d2.rect(788, 97, 802, 113)
    d2.rect(788, 118, 802, 135)
    d2.ellipse(787, 118, 1.2, 1.2)
    s.rgb *= (1 - d2.array() * 0.24)[..., None]
    fr = s.mask()
    fr.rect(782, 90, 784, 140)
    fr.rect(806, 90, 808, 140)
    fr.rect(782, 89.5, 808, 92)
    s.paint(fr, "#06050b")

    # where it's hit: the door's lost, the panels are splitting from the iron outward
    crack = s.mask()
    ix, iy = 784.5, 125.5
    for pts in ([(ix, iy), (789, 122), (792, 123), (797, 116), (799, 117), (804, 110)],
                [(ix, iy), (790, 127), (794, 126), (800, 131), (805, 130)],
                [(ix, iy), (788, 130), (790, 134), (789, 139)],
                [(ix, iy), (787, 118), (790, 114), (789, 106)]):
        crack.line(pts, 0.95)
    s.paint(crack, "#20130d")

    # the stack, by rank, each with room to be what they are: the short bloke on the iron end, the bloke
    # with the plan at the back of it, and the useless ones strung out behind
    bb = 140

    def party_paint(m):
        s.paint(m, ARMOUR)
        lit_rim(s, m, 795, 116, 90, HOT, 1.5, soft=0.35)
        lit_rim(s, m, 880, 80, 240, "#6c98ff", 1.0, soft=0.35)
        lit_rim(s, m, 600, 100, 130, "#ff4656", 1.35, soft=0.35)

    mg, ro, pa, ca, ta, tn, dw, dn = (s.mask() for _ in range(8))
    head, bands, blades, haft, fists, staff, mfist = (s.mask() for _ in range(7))
    orb = mage(mg, staff, mfist, 627, bb, 40)
    rogue(ro, blades, 661, bb, 36)
    paladin(pa, ca, head, bands, haft, fists, 695, bb, 44)
    tank(ta, tn, 727, bb, 50)
    dwarf(dw, dn, 767, bb, 32)
    wood, steel = s.mask(), s.mask()
    ram(wood, steel, 732, 115.4, 784, 125.5, 8.5)
    # a hard shadow behind them on the fibro, thrown left by the bar
    union = np.zeros_like(a)
    for m in (mg, ro, pa, ca, ta, tn, dw, dn):
        union = np.maximum(union, m.array())
    sh = np.roll(union, -int(3 * SS), axis=1) * wall.array() * (1 - union)
    s.rgb *= (1 - sh * 0.3)[..., None]
    for m in (mg, ro):
        party_paint(m)
    # the stick: plain timber, so you can see it from the ground up to the claw, and his hand round it
    s.paint(staff, "#8a6a48", rim=0.7, rim_dx=0.5, rim_dy=-0.3, rim_colour="#ffd0b0")
    party_paint(mfist)
    s.paint(blades, "#d8e0ea", rim=0.5, rim_dx=0, rim_dy=-0.5, rim_colour="#ffffff")
    s.paint(ca, "#2a0a16")
    lit_rim(s, ca, 600, 100, 130, "#ff4656", 1.0, soft=0.35)
    party_paint(pa)
    # the hammer: dark steel like the rest of him, with a thread of gold on the edge, for all the good the
    # Light'll do; bright haft across his chest, and his fists on it
    s.paint(haft, "#6f7686", rim=0.5, rim_dx=0, rim_dy=-0.4, rim_colour="#ffffff")
    s.paint(head, "#14141e", rim=1.0, rim_dx=0.5, rim_dy=-0.6, rim_colour="#e8b84e")
    lit_rim(s, head, 600, 100, 130, "#ff4656", 0.9, soft=0.35)
    s.paint(bands, "#343544")
    party_paint(fists)
    party_paint(ta)
    party_paint(dw)
    # the ram goes over the top of them, the only pale thing in the stack, so it's plain what it is
    s.paint(wood, "#7a5a3c", bottom="#4a3322", top_y=60, rim=0.9, rim_dx=0, rim_dy=-0.8, rim_colour="#ffc0a0")
    s.paint(steel, "#59616f", rim=0.9, rim_dx=0, rim_dy=-0.7, rim_colour="#ffffff")
    lit_rim(s, steel, 795, 116, 40, HOT, 2.2, soft=0.3)
    # and the hands and near arms over the ram, so they've actually got hold of it
    party_paint(tn)
    party_paint(dn)
    # and the light in the claw on the mage's stick: a hard little ball of it, then the glow
    mx, my = orb
    s.glow(mx, my, 8, "#55d8ff", 0.4)
    o = s.mask()
    o.ellipse(mx, my, 3.1, 3.1)
    s.paint(o, "#c9f6ff")

    # out the window and over the verge
    m = s.mask()
    runner(m, 554, 139, 40)
    s.paint(m, "#05050b")
    lit_rim(s, m, 610, 110, 80, "#ffb060", 1.3, soft=0.3)
    lit_rim(s, m, 620, 80, 150, "#ff4656", 0.9, soft=0.3)

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
    gum_tree(m, 1106, 172, 140, seed=8, lean=0.1, spread=0.7)
    gum_tree(m, 236, 176, 170, seed=12, lean=0.06)
    s.paint(m, "#040308")
    # keep the left of the sky low so the page title has a calm dark bed
    s.rgb *= (0.42 + 0.58 * smooth(430 * SS, 640 * SS, s.X))[..., None]
    return s.finish(bloom=0.22)
