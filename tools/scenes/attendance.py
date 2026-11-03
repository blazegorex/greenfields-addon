"""Roll Call: the line-up at the cop shop, under a fluoro that's been dying since the nineties. For once
everyone's turned up, and yes, it was him, there, number four."""
import numpy as np

from scenekit import SCRAWL, SS, STENCIL, Scene, bez, gauss, gum_tree, lettering, razor_wire, smooth

FLOOR = 139
WALL_TOP = 45
# 40 left of where the kit says, because Roll Call's dropdown starts at x 650 and the gnome's board is the gag
WALL_X0, WALL_X1 = 560, 962
LINES = ((150, 94), (170, 78), (190, 62))
WALLC = "#66794f"
FLUORO = "#d9ffd0"
CLOTH = "#0a0d0d"


def limb(m, pts, widths):
    """A jointed limb: straight bones and round joints, thickness given at each joint."""
    pts = [np.array(p, float) for p in pts]
    for a, b, wa, wb in zip(pts[:-1], pts[1:], widths[:-1], widths[1:]):
        d = (b - a) / max(1e-6, np.linalg.norm(b - a))
        n = np.array([-d[1], d[0]])
        m.spoly([tuple(a + n * wa / 2), tuple(b + n * wb / 2), tuple(b - n * wb / 2), tuple(a - n * wa / 2)])
    for p, w in zip(pts, widths):
        m.ellipse(p[0], p[1], w / 2, w / 2)


def board(boards, digits, x, y, n, w=18, h=15, tilt=0.0):
    """The number board: a bit of white plastic and a marker. Same size for everyone, whatever they are."""
    c, sn = np.cos(np.radians(tilt)), np.sin(np.radians(tilt))
    boards.spoly([(x + u * c - v * sn, y + u * sn + v * c) for u, v in ((-w / 2, -h / 2), (w / 2, -h / 2), (w / 2, h / 2), (-w / 2, h / 2))])
    lettering(digits, str(n), x, y + 0.2, 11.5, font=STENCIL, angle=-tilt)


def suspect(x, base, h, bulk=1.0, lean=0.0):
    """Where a person's bits go, front on: u across, v up, both as a fraction of h, the top half leaning a bit."""
    return lambda u, v: (x + (u * bulk + lean * max(0.0, v - 0.45)) * h, base - v * h)


def legs(m, P, h, weight=1, thin=1.0):
    """Trackies, feet turned out. All the weight's on one straight leg; the other's bent and wandered off."""
    for sd in (-1, 1):
        if sd == weight:
            knee, ankle = (sd * 0.06, 0.27), sd * 0.05
        else:
            knee, ankle = (sd * 0.115, 0.28), sd * 0.135
        limb(m, [P(sd * 0.055, 0.49), P(*knee), P(ankle, 0.05)], [h * 0.105 * thin, h * 0.072 * thin, h * 0.054 * thin])
        a = ankle
        m.spoly([P(a - sd * 0.035, 0.0), P(a - sd * 0.032, 0.05), P(a + sd * 0.03, 0.055), P(a + sd * 0.125, 0.018), P(a + sd * 0.125, 0.0)])


def torso(m, P):
    """The jumper, baggy, hem past the hips."""
    pts = bez(P(-0.06, 0.84), P(-0.16, 0.83), P(-0.16, 0.66), P(-0.128, 0.44), n=10).tolist()
    pts += bez(P(0.128, 0.44), P(0.16, 0.66), P(0.16, 0.83), P(0.06, 0.84), n=10).tolist()
    m.spoly(pts)


def hood(m, P):
    """Hood up, a bit of a peak on it."""
    pts = bez(P(-0.075, 0.8), P(-0.115, 0.9), P(-0.08, 1.0), P(0.0, 1.015), n=12).tolist()
    pts += bez(P(0.0, 1.015), P(0.08, 1.0), P(0.115, 0.9), P(0.075, 0.8), n=12).tolist()
    m.spoly(pts)


def holding_arms(sleeves, P, h, v, thin=1.0):
    """Both elbows out and both hands up under the bottom corners of the board, with daylight past the ribs."""
    for sd in (-1, 1):
        limb(sleeves, [P(sd * 0.15, 0.785), P(sd * 0.25, 0.595), P(sd * 0.125, v - 0.1)], [h * 0.078 * thin, h * 0.066 * thin, h * 0.056 * thin])


def gnome(g, sleeves, beard, skin, x, base, h):
    """Gnome, in a hoodie bought for a gnome, all head and boots. Doesn't reach the first line, and the
    board's the same as everyone's, so it's over his head at the full stretch of both arms or it's all of
    him they get a photo of. Returns where the board goes."""
    def P(u, v):
        return (x + u * h, base - v * h)
    # boots the size of the legs, and little legs
    for sd in (-1, 1):
        limb(g, [P(sd * 0.09, 0.34), P(sd * 0.11, 0.08)], [h * 0.13, h * 0.1])
        g.spoly([P(sd * 0.04, 0.0), P(sd * 0.05, 0.11), P(sd * 0.17, 0.11), P(sd * 0.31, 0.03), P(sd * 0.31, 0.0)])
    # jumper, too big, hanging off him
    g.spoly([P(-0.25, 0.27), P(0.25, 0.27), P(0.21, 0.64), P(-0.21, 0.64)])
    # the great big hood, and a peak on it like the hat he had to leave at the desk
    g.ellipse(*P(0, 0.76), h * 0.23, h * 0.2)
    g.spoly(bez(P(-0.17, 0.86), P(-0.07, 0.94), P(0.0, 1.13), n=8).tolist() + bez(P(0.0, 1.13), P(0.07, 0.94), P(0.17, 0.86), n=8).tolist())
    # arms: out at the elbows, up to the corners of the board
    for sd in (-1, 1):
        limb(sleeves, [P(sd * 0.2, 0.58), P(sd * 0.47, 0.74), P(sd * 0.27, 1.12)], [h * 0.105, h * 0.095, h * 0.085])
    # the ears, out the side of the hood: nothing else that size has ears like that
    for sd in (-1, 1):
        skin.spoly([P(sd * 0.2, 0.83), P(sd * 0.38, 0.9), P(sd * 0.2, 0.72)])
    # the beard, poking out the front, and the nose over it
    beard.ellipse(*P(0, 0.67), h * 0.15, h * 0.1)
    beard.spoly([P(-0.14, 0.67), P(0.14, 0.67), P(0.0, 0.34)])
    skin.ellipse(*P(0, 0.765), h * 0.07, h * 0.06)
    return P(0, 1.12 + 7.5 / h)


def orc(s, x, base, h, shadow):
    """Number four: an orc who's come as he is, front on, shoulders up round his ears. The hood's down
    because nothing that wide goes through it. Green, tusks, topknot, and he's already past the top line.
    Returns where the board goes."""
    def P(u, v):
        return (x + u * h, base - v * h)

    m = s.mask()
    # big trackie legs, wide apart with the wall showing between, and runners that had to be ordered in
    for sd in (-1, 1):
        limb(m, [P(sd * 0.13, 0.46), P(sd * 0.2, 0.26), P(sd * 0.19, 0.06)], [h * 0.22, h * 0.165, h * 0.125])
        m.spoly([P(sd * 0.11, 0.0), P(sd * 0.11, 0.075), P(sd * 0.27, 0.08), P(sd * 0.4, 0.025), P(sd * 0.4, 0.0)])
    # the jumper: wide at the lats, in at the hem, and traps up to his ears either side of a neck he hasn't got
    pts = bez(P(-0.24, 0.4), P(-0.27, 0.62), P(-0.33, 0.84), n=10).tolist()
    pts += bez(P(-0.33, 0.84), P(-0.3, 0.93), P(-0.13, 0.98), n=8).tolist()
    pts += bez(P(0.13, 0.98), P(0.3, 0.93), P(0.33, 0.84), n=8).tolist()
    pts += bez(P(0.33, 0.84), P(0.27, 0.62), P(0.24, 0.4), n=10).tolist()
    m.spoly(pts)
    # the hood, down in a lump behind his neck
    m.ellipse(*P(0, 0.93), h * 0.22, h * 0.07)
    # arms like thighs: shoulder out, elbow out, forearm back in, and a hole you could post a dog through
    sl = s.mask()
    for sd in (-1, 1):
        limb(sl, [P(sd * 0.385, 0.83), P(sd * 0.51, 0.6), P(sd * 0.215, 0.6)], [h * 0.16, h * 0.12, h * 0.095])
    shadow.append(m.array())
    shadow.append(sl.array())
    s.paint(m, "#121713", rim=0.9, rim_dx=0, rim_dy=-0.9, rim_colour=FLUORO)
    s.paint(sl, "#121713", rim=0.9, rim_dx=0, rim_dy=-0.9, rim_colour=FLUORO)

    skin = s.mask()
    # ears out wide, then the head: narrow up top, a jaw like a bread box
    skin.spoly([P(-0.16, 1.03), P(-0.34, 1.11), P(-0.16, 0.95)])
    skin.spoly([P(0.16, 1.03), P(0.34, 1.11), P(0.16, 0.95)])
    skin.spoly([P(-0.13, 1.16), P(0.13, 1.16), P(0.17, 1.0), P(0.2, 0.9), P(0.15, 0.82), P(-0.15, 0.82), P(-0.2, 0.9), P(-0.17, 1.0)])
    s.paint(skin, "#5f9a3c", rim=0.55, rim_dx=0, rim_dy=-0.9, rim_colour="#e4ffb8")

    hair = s.mask()
    # the brow, the mouth, and the knot of hair on top
    hair.spoly([P(-0.15, 1.06), P(0.15, 1.06), P(0.13, 1.1), P(0.02, 1.04), P(-0.02, 1.04), P(-0.13, 1.1)])
    hair.line([P(-0.13, 0.885), P(0.13, 0.885)], max(0.8, h * 0.016))
    hair.spoly([P(-0.06, 1.15), P(0.06, 1.15), P(0.035, 1.2), P(-0.035, 1.2)])
    hair.ellipse(*P(0, 1.235), h * 0.055, h * 0.05)
    hair.stroke(bez(P(-0.02, 1.26), P(-0.04, 1.31), P(-0.11, 1.32), P(-0.13, 1.26), n=10), h * 0.04, h * 0.012)
    s.paint(hair, "#080a08", rim=0.4, rim_dx=0, rim_dy=-0.9, rim_colour=FLUORO)
    eye = s.mask()
    eye.ellipse(*P(-0.075, 1.015), h * 0.018, h * 0.012)
    eye.ellipse(*P(0.075, 1.015), h * 0.018, h * 0.012)
    s.paint(eye, "#ffe060")
    # tusks, up out of the bottom lip
    t = s.mask()
    t.spoly([P(-0.13, 0.88), P(-0.07, 0.88), P(-0.125, 1.0)])
    t.spoly([P(0.13, 0.88), P(0.07, 0.88), P(0.125, 1.0)])
    s.paint(t, "#f6f0d6")
    return P(0, 0.71)


def skeleton_head(s, x, base, h, f=-1):
    """A skull looking out of the hood. He's the only one who didn't have to take his face off for the photo."""
    cx, cy = x + f * h * 0.012, base - h * 0.91
    sk = s.mask()
    sk.ellipse(cx, cy - h * 0.005, h * 0.062, h * 0.06)
    sk.rect(cx - h * 0.034, cy + h * 0.03, cx + h * 0.034, cy + h * 0.078)
    s.paint(sk, "#e7e4c8")
    holes = s.mask()
    holes.ellipse(cx + f * h * 0.024, cy - h * 0.002, h * 0.019, h * 0.021)
    holes.ellipse(cx - f * h * 0.021, cy - h * 0.002, h * 0.016, h * 0.019)
    holes.rect(cx - h * 0.024, cy + h * 0.046, cx - h * 0.018, cy + h * 0.075)
    holes.rect(cx - h * 0.003, cy + h * 0.046, cx + h * 0.003, cy + h * 0.075)
    holes.rect(cx + h * 0.018, cy + h * 0.046, cx + h * 0.024, cy + h * 0.075)
    s.paint(holes, "#090b09")


def brick_wall(s):
    """Painted besser block, hit from above: a pool from the tube, and it dies off toward both ends."""
    wall = s.mask()
    wall.rect(WALL_X0, WALL_TOP, WALL_X1, FLOOR + 1)
    a = wall.array()
    X, Y = s.X / SS, s.Y / SS
    down = 0.30 + 0.70 * np.exp(-((Y - WALL_TOP) / 48) ** 2)
    across = 0.30 + 0.70 * np.exp(-((X - 730) / 210) ** 2)
    col = s.colour(WALLC)
    s.rgb = s.rgb * (1 - a[..., None]) + col[None, None, :] * (a * down * across)[..., None]
    # the mortar, faint, one course in two off by half a block
    mort = s.mask()
    y = WALL_TOP + 1
    row = 0
    while y < FLOOR:
        mort.rect(WALL_X0, y, WALL_X1, y + 0.32)
        for x in np.arange(WALL_X0 + (9 if row % 2 else 0), WALL_X1, 18):
            mort.rect(x, y, x + 0.32, y + 5.2)
        y += 5.2
        row += 1
    s.rgb *= (1 - mort.array() * a * 0.32)[..., None]
    return a


def tubes(s, x0, x1, y):
    """The fluoro batten: a tin box bolted to the block with a tube slung under it, black at both ends the
    way they go, and the last hand's width of it given up altogether."""
    b = s.mask()
    b.rect(x0 - 2.5, y - 3.2, x1 + 2.5, y)
    b.rect(x0 - 2.5, y, x0 - 0.6, y + 2.6)
    b.rect(x1 + 0.6, y, x1 + 2.5, y + 2.6)
    s.paint(b, "#0c0f0c", rim=0.5, rim_dx=0, rim_dy=-0.5, rim_colour="#8aa084")
    t = s.mask()
    t.rect(x0 + 3.5, y + 0.4, x1 - 11, y + 2.3)
    a = t.array()
    s.rgb = s.rgb * (1 - a[..., None]) + s.colour("#eefbe0") * 0.95 * a[..., None]
    s.rgb += gauss(a, 14 * SS)[..., None] * s.colour("#c6f0b0") * 0.3
    dead = s.mask()
    dead.rect(x0 - 0.6, y + 0.4, x0 + 3.5, y + 2.3)
    dead.rect(x1 - 11, y + 0.4, x1 + 0.6, y + 2.3)
    s.paint(dead, "#39402f")


def paint():
    s = Scene("night", seed=29, horizon=120)
    s.sky(clouds=0.25, stars=0.9, glow_x=0.62, glow_w=0.2)
    s.moon(590, 22, 14, tint="#f6efdc", glow=0.45, seed=3)
    s.moon(636, 14, 6.5, tint="#a9c6ff", glow=0.45, seed=9)
    s.ridge(112, 12, 53, "#132a44", roughness=4)
    s.fog(98, 120, strength=0.24)
    # a low treeline for the wall to stand in front of
    m = s.mask()
    for i, x in enumerate((246, 300, 372, 440, 504, 540)):
        gum_tree(m, x, 124, 28 + (i * 29) % 20, seed=90 + i, leaves=0.95)
    m.rect(0, 122, 1040, 148)
    s.paint(m, "#0a1a2e", rim=0.10)

    # concrete out the front
    m = s.mask()
    m.rect(0, FLOOR - 1, 1040, 148)
    s.paint(m, "#10130f")

    a = brick_wall(s)

    # razor wire along the top, so you know whose wall it is
    m = s.mask()
    razor_wire(m, WALL_X0 + 3, WALL_X1 - 3, WALL_TOP - 2, r=2.2)
    s.paint(m, "#0a0f14", rim=0.5, rim_dx=0, rim_dy=-0.5, rim_colour="#b6c9c2")

    # the height lines, edge to edge of the wall, with the stencilled numbers sitting on them at the far end
    m = s.mask()
    for cm, y in LINES:
        m.rect(WALL_X0, y, WALL_X1, y + 1.0)
        # the 150 would only sit half under the page buttons, so that line goes unnumbered
        if cm > 150:
            lettering(m, str(cm), 946, y - 5.8, 10, font=STENCIL)
    s.rgb *= (1 - m.array() * a * 0.72)[..., None]

    # the line-up, every one a different shape, and there's room to stand now
    h1, h3, h5, h6, oh, gh = 83, 70, 79, 80, 80, 31
    x1, x2, x3, ox, x5, x6 = 580, 611, 643, 705, 767, 803
    P1 = suspect(x1, FLOOR, h1, bulk=0.92, lean=-0.03)
    P3 = suspect(x3, FLOOR, h3, bulk=1.18, lean=0.02)
    P5 = suspect(x5, FLOOR, h5, bulk=0.82, lean=-0.015)
    P6 = suspect(x6, FLOOR, h6, bulk=0.95, lean=0.075)

    people, sleeves, faces, bones, cap = s.mask(), s.mask(), s.mask(), s.mask(), s.mask()
    # number one: a long streak of nothing, hood up, hip out
    legs(people, P1, h1, weight=-1, thin=0.9)
    torso(people, P1)
    hood(people, P1)
    faces.ellipse(*P1(0, 0.91), h1 * 0.05, h1 * 0.062)
    holding_arms(sleeves, P1, h1, 0.71, thin=0.92)
    # number three: short and wide, no hood, cap on sideways and a neck like a fence post
    legs(people, P3, h3, weight=1, thin=1.12)
    torso(people, P3)
    limb(people, [P3(0, 0.8), P3(0, 0.88)], [h3 * 0.1, h3 * 0.1])
    faces.ellipse(*P3(0, 0.915), h3 * 0.072, h3 * 0.085)
    holding_arms(sleeves, P3, h3, 0.71, thin=1.08)
    cap.spoly(bez(P3(-0.075, 0.945), P3(-0.08, 1.04), P3(0.075, 1.04), P3(0.075, 0.945), n=12).tolist())
    cap.spoly([P3(-0.078, 0.965), P3(-0.078, 0.94), P3(0.078, 0.94), P3(0.19, 0.925), P3(0.17, 0.96), P3(0.078, 0.975)])
    # number five: nothing on the bones, so the trackies stop at the shin and the sleeves at the elbow
    legs(people, P5, h5, weight=-1, thin=0.82)
    for u in (-0.05, 0.135):
        limb(bones, [P5(u, 0.2), P5(u, 0.05)], [h5 * 0.024, h5 * 0.024])
    torso(people, P5)
    hood(people, P5)
    for sd in (-1, 1):
        limb(sleeves, [P5(sd * 0.15, 0.785), P5(sd * 0.25, 0.6)], [h5 * 0.075, h5 * 0.065])
        limb(bones, [P5(sd * 0.25, 0.6), P5(sd * 0.14, 0.615)], [h5 * 0.026, h5 * 0.024])
    # number six has lost interest: head turned off down the line, one hand in the pocket, and the board's
    # gone down with the other arm
    legs(people, P6, h6, weight=1, thin=0.95)
    torso(people, P6)
    hood(people, P6)
    faces.spoly([P6(0.02, 0.97), P6(0.085, 0.95), P6(0.095, 0.87), P6(0.05, 0.84), P6(0.02, 0.86)])
    limb(sleeves, [P6(-0.155, 0.785), P6(-0.25, 0.67), P6(-0.125, 0.55)], [h6 * 0.074, h6 * 0.064, h6 * 0.056])
    limb(sleeves, [P6(0.155, 0.785), P6(0.235, 0.63), P6(0.17, 0.585)], [h6 * 0.074, h6 * 0.064, h6 * 0.056])

    shadow = [people.array(), sleeves.array(), cap.array()]
    s.paint(people, CLOTH, rim=0.85, rim_dx=0, rim_dy=-0.9, rim_colour=FLUORO)
    s.paint(faces, "#8d7a58")
    s.paint(cap, CLOTH, rim=0.85, rim_dx=0, rim_dy=-0.9, rim_colour=FLUORO)
    s.paint(sleeves, CLOTH, rim=0.85, rim_dx=0, rim_dy=-0.9, rim_colour=FLUORO)
    s.paint(bones, "#e7e4c8")
    skeleton_head(s, x5, FLOOR, h5)

    # the gnome: same board as everyone else, which is most of him
    g, gs, beard, gskin = s.mask(), s.mask(), s.mask(), s.mask()
    centre2 = gnome(g, gs, beard, gskin, x2, FLOOR, gh)
    shadow += [g.array(), gs.array()]
    s.paint(g, CLOTH, rim=0.85, rim_dx=0, rim_dy=-0.9, rim_colour=FLUORO)
    s.paint(gs, CLOTH, rim=0.85, rim_dx=0, rim_dy=-0.9, rim_colour=FLUORO)
    s.paint(gskin, "#d98a6a")
    s.paint(beard, "#dfe6d6")

    # number four
    centre4 = orc(s, ox, FLOOR, oh, shadow)

    # everyone's shadow on the block, hard, down and to the right, only where the wall's still showing
    sh = np.zeros_like(shadow[0])
    for layer in shadow:
        sh = np.maximum(sh, layer)
    off = np.roll(np.roll(sh, int(2.5 * SS), axis=1), int(1 * SS), axis=0)
    s.rgb *= (1 - off * (1 - sh) * a * 0.34)[..., None]

    boards, digits = s.mask(), s.mask()
    c1, c3, c5 = P1(0, 0.71), P3(0, 0.71), P5(0, 0.71)
    c6 = P6(-0.015, 0.615)
    board(boards, digits, *c1, 1)
    board(boards, digits, *centre2, 2)
    board(boards, digits, *c3, 3)
    board(boards, digits, *centre4, 4)
    board(boards, digits, *c5, 5)
    board(boards, digits, *c6, 6, tilt=-16)
    s.paint(boards, "#eef4e6")
    s.paint(digits, "#0a0d0a")
    # and a hand on each one, so they're holding it and it isn't just stuck to them
    hands = s.mask()
    for sd in (-1, 1):
        for c in (c1, c3):
            hands.ellipse(c[0] + sd * 7.2, c[1] + 6.9, 2.5, 2.2)
        hands.ellipse(centre2[0] + sd * 7.5, centre2[1] + 7, 1.7, 1.5)
    # number six's hand comes in under the low corner
    hands.ellipse(*P6(-0.125, 0.55), 2.5, 2.2)
    s.paint(hands, "#8d7a58")
    ohands = s.mask()
    for sd in (-1, 1):
        ohands.ellipse(centre4[0] + sd * 8.5, centre4[1] + 7, 5.5, 4.6)
    s.paint(ohands, "#5f9a3c", rim=0.55, rim_dx=0, rim_dy=-0.9, rim_colour="#e4ffb8")
    # bony fingers round number five's board
    bone = s.mask()
    bxc, by = c5
    for sd in (-1, 1):
        for k in range(3):
            bone.line([(bxc + sd * (5 + k * 1.9), by + 8.2), (bxc + sd * (5 + k * 1.9), by + 3.6)], 1.0)
    s.paint(bone, "#e7e4c8")

    # someone's been at the wall with a marker, and they're not wrong
    t = s.mask()
    lettering(t, "THATS HIM", 872, 56, 12, font=SCRAWL, angle=-3, wobble=0.5, seed=4, spacing=0.4)
    pts = bez((820, 53), (790, 45), (760, 47), (742, 56), n=16)
    t.stroke(pts, 1.5, 1.1)
    t.stroke(np.array([(742, 56), (751, 55.5)]), 1.4, 1.0)
    t.stroke(np.array([(742, 56), (744, 47.5)]), 1.4, 1.0)
    s.paint(t, "#120f0a")

    # the one tube, doing what it can
    tubes(s, 582, 652, WALL_TOP + 5)

    # a touch of sick green on the concrete out front
    pool = np.exp(-(((s.X / SS - 660) / 170) ** 2)) * smooth(FLOOR * SS, (FLOOR + 3) * SS, s.Y)
    s.rgb += pool[..., None] * s.colour("#7fa86c") * 0.22

    # framing gums, and the left one keeps the title dark
    m = s.mask()
    gum_tree(m, 218, 180, 176, seed=12, lean=0.04)
    gum_tree(m, 1056, 176, 150, seed=33, lean=-0.05, spread=0.9)
    s.paint(m, "#02040a")
    s.rgb *= (0.44 + 0.56 * smooth(400 * SS, 560 * SS, s.X))[..., None]
    return s.finish(bloom=0.34, vignette=0.12)
