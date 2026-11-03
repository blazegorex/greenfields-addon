"""Settings: somebody's been tweaking the neighbourhood. A back yard at the quiet end of the night,
a pair of jumper leads clamped straight on to the power line, taped side by side and sagging across
the yard over a clothes prop to a garden shed, and in through the foil. It's only tomatoes."""
import numpy as np

from scenekit import SCRAWL, SS, Scene, bez, foil_window, gauss, gum_tree, lettering, power_pole, wires

BLUE = "#6fb4ff"


def shed(s, x, base, w, h):
    """Garden shed: a gable of corrugated iron on a slab, cover strips on the corners. Bigger than it was,
    and doing better."""
    rise = w * 0.2
    m = s.mask()
    m.spoly([(x, base), (x, base - h), (x + w / 2, base - h - rise), (x + w, base - h), (x + w, base)])
    s.paint(m, "#14302e", rim=0.3, rim_dx=-0.5, rim_dy=-0.8)
    # the corrugations, wide enough to see, catching a touch of moon
    c = s.mask()
    for k in range(1, int(w / 3.4)):
        xx = x + k * 3.4
        c.line([(xx, base), (xx, base - h - rise * (1 - abs(xx - x - w / 2) / (w / 2)) + 1.5)], 0.9)
    s.paint(c, "#0b201f")
    # corner strips and a wall plate under the eave
    t = s.mask()
    t.rect(x, base - h, x + 1.6, base)
    t.rect(x + w - 1.6, base - h, x + w, base)
    s.paint(t, "#06110f", rim=0.16, rim_dx=-0.3, rim_dy=0)
    # roof: barge boards over the gable, with a cap on the ridge
    r = s.mask()
    r.spoly([(x - 3.5, base - h + 2), (x + w / 2, base - h - rise - 1.4), (x + w + 3.5, base - h + 2),
             (x + w + 3.5, base - h + 4.2), (x + w / 2, base - h - rise + 1.2), (x - 3.5, base - h + 4.2)])
    r.spoly([(x + w / 2 - 3, base - h - rise - 0.2), (x + w / 2, base - h - rise - 2.2), (x + w / 2 + 3, base - h - rise - 0.2)])
    s.paint(r, "#061312", rim=0.5, rim_dx=-0.3, rim_dy=-0.9)


def shed_door(s, x0, x1, y0, y1):
    """The door, shut, with a line of blue under it and up the crack that no veggie patch ever made."""
    d = s.mask()
    d.rect(x0, y0, x1, y1)
    s.paint(d, "#071715", rim=0.14, rim_dx=-0.4, rim_dy=-0.5)
    # ledged and braced, the only way anybody's ever built a shed door: planks, two rails and a brace
    b = s.mask()
    for k in (1, 2, 3):
        xx = x0 + (x1 - x0) * k / 4
        b.line([(xx, y0), (xx, y1)], 0.7)
    s.paint(b, "#030a09")
    b = s.mask()
    b.rect(x0, y0 + 1.5, x1, y0 + 4)
    b.rect(x0, y1 - 5.5, x1, y1 - 3)
    b.spoly([(x0, y1 - 4), (x0 + 3, y1 - 4), (x1, y0 + 3), (x1 - 3, y0 + 3)])
    s.paint(b, "#132b28", rim=0.14, rim_dx=0, rim_dy=-0.5)
    f = s.mask()
    f.rect(x0 - 1.2, y0 - 1.2, x1 + 1.2, y0)
    f.rect(x0 - 1.2, y0, x0, y1)
    f.rect(x1, y0, x1 + 1.2, y1)
    s.paint(f, "#030a09")
    g = s.mask()
    g.rect(x0 - 0.8, y1 - 1.5, x1 + 0.8, y1)
    a = g.array()
    s.rgb = s.rgb * (1 - a[..., None]) + s.colour("#bfe3ff") * a[..., None]
    s.rgb += gauss(a, 1.4 * SS)[..., None] * s.colour(BLUE) * 0.75
    s.rgb += gauss(a, 6.0 * SS)[..., None] * s.colour(BLUE) * 0.5
    # and a thread of it up the hinge side, where the door's dropped
    c = s.mask()
    c.rect(x1 - 0.45, y0 + 5, x1, y1)
    ca = c.array()
    s.rgb += ca[..., None] * s.colour(BLUE) * 0.55
    # a brass padlock through a hasp on the door's edge, because there's a lot of tomatoes in there
    my = (y0 + y1) / 2 - 2
    p = s.mask()
    p.rect(x0 - 1.2, my - 1.3, x0 + 7.4, my + 0.7)
    s.paint(p, "#59645f")
    p = s.mask()
    p.stroke(np.array(bez((x0 + 1.5, my + 3), (x0 + 1.5, my - 3.6), (x0 + 5.5, my - 3.6), (x0 + 5.5, my + 3), n=12)), 1.0, 1.0)
    s.paint(p, "#c3cdc8")
    p = s.mask()
    p.rrect(x0 + 0.2, my + 2, x0 + 6.8, my + 7.4, 0.8)
    s.paint(p, "#d2a23c", rim=0.3, rim_dx=-0.3, rim_dy=-0.4, rim_colour="#fff0c0")
    p = s.mask()
    p.ellipse(x0 + 3.5, my + 4.2, 0.8, 0.8)
    p.rect(x0 + 3.2, my + 4.2, x0 + 3.8, my + 6.2)
    s.paint(p, "#1b1206")


def fence(s, y, x0=0, x1=1040):
    """Paling fence, each paling a slightly different height, the way they go after twenty winters."""
    rng = np.random.default_rng(9)
    m = s.mask()
    x = x0
    while x < x1:
        pw = rng.uniform(4.4, 5.4)
        top = y + rng.uniform(-0.8, 0.8)
        m.spoly([(x, 150), (x, top + 1.1), (x + pw / 2, top), (x + pw - 0.5, top + 1.1), (x + pw - 0.5, 150)])
        x += pw
    m.rect(x0, y + 4, x1, y + 5.2)
    s.paint(m, "#0a1a1a", rim=0.20, rim_dx=0, rim_dy=-0.8)


def spark(s, x, y, size, seed=1):
    """A clamp arcing: a hot point, a few spits flying off it, some falling."""
    rng = np.random.default_rng(seed)
    m = s.mask()
    for k in range(9):
        a = rng.uniform(-0.2, 1.0) * np.pi + rng.normal(0, 0.1)
        L = size * rng.uniform(0.55, 1.5)
        q = (x + np.cos(a) * L, y + np.sin(a) * L * 1.15)
        m.stroke(np.array([(x, y), ((x + q[0]) / 2, (y + q[1]) / 2 + 0.3), q]), 0.7, 0.2)
    for k in range(7):
        m.ellipse(x + rng.uniform(-1, 1) * size * 1.1, y + rng.uniform(0.2, 2.1) * size, 0.42, 0.42)
    a = m.array()
    s.rgb += a[..., None] * s.colour("#fff4c8") * 1.8
    s.rgb += gauss(a, 0.9 * SS)[..., None] * s.colour("#ffd070") * 0.9
    s.glow(x, y - 1, size * 0.28, colour="#fff0c0", strength=0.85)
    s.glow(x, y - 1, size * 1.5, colour="#ffc058", strength=0.14)


def clamp(s, x, y, colour):
    """A jumper-lead clamp biting the wire: two pointed jaws closing on it from above and below, a pivot
    and two handles splayed apart, and the lead out the bottom. Its colour's the only thing saying which
    is which, not that it was consulted."""
    m = s.mask()
    # jaws, a mouth you can see the wire go through
    m.spoly([(x - 2.8, y - 3.2), (x - 0.5, y - 0.5), (x + 1.2, y + 5.5), (x - 1.2, y + 5.5)])
    m.spoly([(x + 2.8, y - 3.2), (x + 0.5, y - 0.5), (x + 1.2, y + 5.5), (x - 1.2, y + 5.5)])
    # handles
    m.spoly([(x - 1.2, y + 4.6), (x + 0.2, y + 5.8), (x - 3.2, y + 12.5), (x - 5.4, y + 11.6)])
    m.spoly([(x + 1.2, y + 4.6), (x - 0.2, y + 5.8), (x + 3.2, y + 12.5), (x + 5.4, y + 11.6)])
    s.paint(m, colour, rim=0.5, rim_dx=0.2, rim_dy=-0.7, rim_colour="#ffffff")
    p = s.mask()
    p.ellipse(x, y + 5.2, 1.5, 1.5)
    s.paint(p, "#c9c6b0")


def prop(m, foot, crotch):
    """A clothes prop off the line out the back: one long sapling, foot in the lawn, on a lean, with a
    little notch at the top. The lead lies in the notch, because the clothes line was already holding up
    the other thing."""
    fx, fy = foot
    cx, cy = crotch
    m.spoly([(fx - 1.0, fy), (fx + 1.0, fy), (cx + 0.7, cy + 0.6), (cx - 0.7, cy + 0.6)])
    m.stroke(np.array([(cx, cy + 1), (cx - 2.3, cy - 3.2)]), 1.2, 0.9)
    m.stroke(np.array([(cx, cy + 1), (cx + 2.3, cy - 3.2)]), 1.2, 0.9)


def side(path, off):
    """The same run, moved off to one side: two leads taped together lie next to each other."""
    d = np.gradient(path, axis=0)
    d /= np.maximum(1e-6, np.linalg.norm(d, axis=1, keepdims=True))
    return path + np.stack((-d[:, 1], d[:, 0]), axis=1) * off


def paint():
    s = Scene("gum", seed=26)
    s.sky(clouds=0.45, stars=0.8, glow_x=0.62, glow_w=0.22)
    # the big moon's where the clamps are, so they've got something to bite against
    s.moon(648, 50, 33, tint="#f6efd6", glow=0.6, seed=3)
    s.moon(748, 19, 8, tint="#a9c6ff", glow=0.45, seed=9)
    s.ridge(108, 14, 52, "#234a4a", roughness=4)
    s.fog(92, 116, strength=0.24)

    # the neighbours' gums, well back
    m = s.mask()
    for i, x in enumerate((316, 384, 470, 760, 900, 985)):
        gum_tree(m, x, 124, 40 + (i * 29) % 22, seed=80 + i, leaves=0.9)
    m.rect(0, 120, 1040, 148)
    s.paint(m, "#12302f", rim=0.1)
    s.fog(104, 124, strength=0.16, seed=8)

    fence(s, 111)

    # the street's power line, pole to pole across the moon, minding its own business
    m = s.mask()
    heads = power_pole(m, 566, 142, 114)
    heads2 = power_pole(m, 884, 142, 114)
    wires(m, heads[0], heads2[0], sag=9, width=0.9)
    wires(m, heads[1], heads2[1], sag=9, width=0.9)
    wires(m, heads[3], heads2[3], sag=9, width=0.9)
    s.paint(m, "#03090a", rim=0.12, rim_dx=0.4, rim_dy=-0.6)

    def on_line(h0, h1, t, sag=9.0):
        a, b = np.array(h0, float), np.array(h1, float)
        p = a * (1 - t) + b * t
        p[1] += sag * 4 * t * (1 - t)
        return p

    # where the leads bite: on two of the three wires, right in front of the moon
    c1 = on_line(heads[0], heads2[0], 0.205)
    c2 = on_line(heads[1], heads2[1], 0.275)

    sx0, sbase, sw, sh = 730, 138, 85, 42
    shed(s, sx0, sbase, sw, sh)
    foil_window(s, sx0 + 8, sbase - 27, 25, 17, seed=3, strength=0.9)
    f = s.mask()
    f.rect(sx0 + 6.6, sbase - 28.4, sx0 + 34.4, sbase - 27)
    f.rect(sx0 + 6.6, sbase - 10, sx0 + 34.4, sbase - 8.6)
    f.rect(sx0 + 6.6, sbase - 27, sx0 + 8, sbase - 10)
    f.rect(sx0 + 33, sbase - 27, sx0 + 34.4, sbase - 10)
    s.paint(f, "#030a09")

    # lawn, gone to seed, and going a bit blue by the door
    m = s.mask()
    pts = bez((0, 136), (340, 139), (700, 133), (1040, 137), n=40).tolist()
    m.spoly(pts + [(1040, 148), (0, 148)])
    rng = np.random.default_rng(4)
    for x in rng.uniform(520, 1040, 150):
        y = 136 + rng.uniform(-1, 1)
        m.line([(x, y + 1.5), (x + rng.uniform(-1.2, 1.2), y - rng.uniform(0.8, 3))], 0.35)
    s.paint(m, "#051110", rim=0.14, rim_dx=0, rim_dy=-0.8)
    s.glow(648, 138, 50, colour="#d9cf8f", strength=0.035)
    # the door goes on after the lawn, so the light under the door lands on the grass
    shed_door(s, sx0 + 55, sx0 + 79, sbase - 31, 134.8)
    s.glow(sx0 + 67, 139, 16, colour=BLUE, strength=0.18)

    # the bypass. Clamps on the street wires, the two leads down off them and taped together, then the pair
    # sagging across the yard, over the clothes prop, and in through a hole in the foil
    join = np.array((652.0, 88.0))
    crotch = np.array((696.0, 96.0))
    entry = np.array((sx0 + 11.5, sbase - 24.0))
    m = s.mask()
    prop(m, (688, 139.5), crotch)
    s.paint(m, "#5e5c3e", rim=0.4, rim_dx=-0.5, rim_dy=-0.3, rim_colour="#efe6b0")
    # the grass the foot's standing in
    m = s.mask()
    for dx, lean in ((-2.4, -0.8), (-0.9, 0.5), (1.0, -0.4), (2.5, 0.9)):
        m.line([(688 + dx, 140), (688 + dx + lean, 136.6)], 0.5)
    s.paint(m, "#051110")
    # the hole, punched through the foil with a screwdriver
    m = s.mask()
    m.ellipse(entry[0], entry[1], 2.0, 1.7)
    s.paint(m, "#020605")
    run = np.vstack((bez(join, join + (17, 12), crotch + (-17, 6), crotch, n=20),
                     bez(crotch, crotch + (12, 14), entry + (-16, 4), entry, n=20)[1:]))
    red_run, black_run = side(run, -0.72), side(run, 0.72)
    # the leads down from the clamps, into the top of the pair
    red = np.vstack((bez((c1[0], c1[1] + 6), (c1[0] + 1, c1[1] + 30), (join[0] - 22, join[1] - 6), red_run[0], n=20), red_run[1:]))
    black = np.vstack((bez((c2[0], c2[1] + 6), (c2[0] - 1, c2[1] + 24), (join[0] - 6, join[1] - 8), black_run[0], n=20), black_run[1:]))
    m = s.mask()
    m.stroke(black, 1.35, 1.35)
    s.paint(m, "#070b0a", rim=0.4, rim_dx=-0.2, rim_dy=-0.5, rim_colour="#efe6b0")
    m = s.mask()
    m.stroke(red, 1.35, 1.35)
    s.paint(m, "#d62c24")
    # the tape: two wraps of it, one where they meet and one short of the prop
    m = s.mask()
    for i in (0, 12):
        u = run[i + 1] - run[i]
        u = u / np.linalg.norm(u)
        n = np.array((-u[1], u[0]))
        m.stroke(np.array((run[i] - n * 1.9, run[i] + n * 1.9)), 2.2, 2.2)
    s.paint(m, "#5d6049")

    clamp(s, c1[0], c1[1], "#e23028")
    clamp(s, c2[0], c2[1], "#141816")
    spark(s, c1[0], c1[1] - 0.5, 6.5, seed=3)
    spark(s, c2[0], c2[1] - 0.5, 5.2, seed=8)

    # what's written on the shed, in case the inspector's wondering
    m = s.mask()
    lettering(m, "TOMATOES", sx0 + 42.5, sbase - sh + 5.5, 8.8, font=SCRAWL, angle=-1.5, wobble=0.4, seed=4, spacing=-0.4)
    s.paint(m, "#e4e0c4")

    # dark gum and a hint of branch to frame it, and to give the title something to sit on
    m = s.mask()
    gum_tree(m, 234, 176, 170, seed=37, lean=0.05)
    gum_tree(m, 1024, 176, 150, seed=33, lean=-0.12, spread=1.0)
    m.rect(0, 144, 1040, 148)
    s.paint(m, "#020706")
    return s.finish()
