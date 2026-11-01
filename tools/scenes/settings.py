"""Settings: somebody's been tweaking the neighbourhood. A back yard at the quiet end of the night,
a pair of jumper leads clamped straight on to the power line, and a fat cable sagging across the
yard on bits of timber to a garden shed with foil on the window. It's only tomatoes."""
import numpy as np

from scenekit import SCRAWL, SS, Scene, bez, foil_window, gauss, gum_tree, lettering, power_pole, wires

BLUE = "#6fb4ff"


def shed(s, x, base, w, h):
    """Garden shed: a gable, corrugated, door shut. Bigger than it was, and doing better."""
    m = s.mask()
    m.spoly([(x, base), (x, base - h), (x + w / 2, base - h - w * 0.2), (x + w, base - h), (x + w, base)])
    s.paint(m, "#0a1c1b", rim=0.3, rim_dx=-0.5, rim_dy=-0.8)
    # corrugations catch a touch of moon
    c = s.mask()
    for k in range(1, int(w / 3)):
        xx = x + k * 3
        c.line([(xx, base), (xx, base - h - (w * 0.2) * (1 - abs(xx - x - w / 2) / (w / 2)) + 0.8)], 0.3)
    s.paint(c, "#142b29")
    r = s.mask()
    r.spoly([(x - 2.5, base - h + 1.4), (x + w / 2, base - h - w * 0.2 - 1.2), (x + w + 2.5, base - h + 1.4),
             (x + w + 2.5, base - h + 3), (x + w / 2, base - h - w * 0.2 + 0.6), (x - 2.5, base - h + 3)])
    s.paint(r, "#061312", rim=0.42, rim_dx=-0.3, rim_dy=-0.9)


def shed_door(s, x0, x1, y0, y1):
    """The door, shut, with a line of blue under it and up the crack that no veggie patch ever made."""
    d = s.mask()
    d.rect(x0, y0, x1, y1)
    s.paint(d, "#051110", rim=0.14, rim_dx=-0.4, rim_dy=-0.5)
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
    # a padlock on the door, because there's a lot of tomatoes in there
    p = s.mask()
    p.rrect(x0 + 2, (y0 + y1) / 2, x0 + 5.6, (y0 + y1) / 2 + 4.4, 0.7)
    s.paint(p, "#7f8c8a")


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
    s.glow(x, y - 1, size * 0.5, colour="#fff0c0", strength=0.95)
    s.glow(x, y - 1, size * 2.0, colour="#ffc058", strength=0.2)


def clamp(s, x, y, colour):
    """A jumper-lead clamp biting the wire from underneath: two big jaws and a handle. Its colour's
    the only thing saying which is which, not that it was consulted."""
    m = s.mask()
    # jaws over the wire, handles splayed below
    m.spoly([(x - 4.2, y - 2.2), (x + 4.2, y - 2.2), (x + 1.8, y + 3), (x - 1.8, y + 3)])
    m.spoly([(x - 1.8, y + 2.4), (x - 5.2, y + 9.2), (x - 2.6, y + 9.8), (x, y + 3.2)])
    m.spoly([(x + 1.8, y + 2.4), (x + 5.2, y + 9.2), (x + 2.6, y + 9.8), (x, y + 3.2)])
    s.paint(m, colour, rim=0.5, rim_dx=0.2, rim_dy=-0.7, rim_colour="#ffffff")


def prop(m, x, base, top, lean, seed=1):
    """A bit of old fence paling stuck in the lawn on a lean, with a notch for the cable."""
    d = lean
    m.spoly([(x - 1.6, base), (x + 1.6, base), (x + d + 1.3, top), (x + d - 1.3, top)])
    # the cross-piece nailed on, skew, that the cable lies in
    m.line([(x + d - 6, top + 2.8), (x + d + 6, top + 0.6)], 1.8)
    # brace, because it fell over the first time
    m.line([(x + d * 0.5, (base + top) / 2), (x - lean * 3 - 9, base)], 1.1)


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
    wires(m, heads[0], heads2[0], sag=9, width=0.6)
    wires(m, heads[1], heads2[1], sag=9, width=0.6)
    wires(m, heads[3], heads2[3], sag=9, width=0.6)
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

    # the props the cable lies on
    p1 = (668, 106)
    p2 = (712, 112)
    m = s.mask()
    prop(m, p1[0] - 2, 139, p1[1], 2)
    prop(m, p2[0] + 1, 139, p2[1], -1)
    s.paint(m, "#2a2c1f", rim=0.34, rim_dx=-0.5, rim_dy=-0.7, rim_colour="#d9cf8f")

    # the cable: thick as your wrist, and not rated for any of this. It joins up with the leads just
    # off the line, wrapped in about a roll of tape, and goes into the shed through a hole in the foil
    join = (c1[0] + 7, c1[1] + 30)
    run = np.vstack((bez(join, (join[0] + 1, join[1] + 26), (p1[0], p1[1] - 1), n=16),
                     bez((p1[0], p1[1] - 1), (p1[0] + 22, p1[1] + 16), (p2[0], p2[1] - 1), n=14),
                     bez((p2[0], p2[1] - 1), (p2[0] + 14, p2[1] + 10), (sx0 + 16, sbase - 22), n=14)))
    m = s.mask()
    m.stroke(run, 3.0, 3.0)
    s.paint(m, "#020605", rim=0.5, rim_dx=-0.3, rim_dy=-0.8, rim_colour="#e8dfa6")

    # the leads themselves, red and black, down from the clamps to the join
    m = s.mask()
    m.stroke(bez((c1[0], c1[1] + 9), (c1[0] - 3, c1[1] + 20), join, n=14), 1.5, 1.5)
    s.paint(m, "#e23028")
    m = s.mask()
    m.stroke(bez((c2[0], c2[1] + 9), (c2[0] - 2, c2[1] + 22), join, n=14), 1.5, 1.5)
    s.paint(m, "#101412", rim=0.3, rim_dx=0.3, rim_dy=-0.3, rim_colour="#ffffff")
    # the tape, and a good lot of it
    m = s.mask()
    m.rrect(join[0] - 3.8, join[1] - 3, join[0] + 3.8, join[1] + 5.5, 1.5)
    s.paint(m, "#3c3f2e", rim=0.4, rim_dx=-0.3, rim_dy=-0.6, rim_colour="#d9cf8f")

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
    gum_tree(m, 234, 176, 170, seed=31, lean=0.05)
    gum_tree(m, 1024, 176, 150, seed=33, lean=-0.12, spread=1.0)
    m.rect(0, 144, 1040, 148)
    s.paint(m, "#020706")
    return s.finish()
