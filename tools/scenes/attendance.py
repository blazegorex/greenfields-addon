"""Roll Call: the line-up at the cop shop, under a fluoro that's been dying since the nineties. For once
everyone's turned up, and yes, it was him, there, number four."""
import numpy as np

from scenekit import SCRAWL, SS, STENCIL, Scene, bez, fbm, gauss, gum_tree, hoodie, lettering, razor_wire, smooth

FLOOR = 139
WALL_TOP = 45
WALL_X0, WALL_X1 = 600, 1002
LINES = ((150, 94), (170, 78), (190, 62))
WALLC = "#66794f"
FLUORO = "#d9ffd0"
CLOTH = "#0a0d0d"


def board(boards, digits, x, y, n, w=18, h=15):
    """The number board: a bit of white plastic and a marker. Same size for everyone, whatever they are."""
    boards.rect(x - w / 2, y - h / 2, x + w / 2, y + h / 2)
    lettering(digits, str(n), x, y + 0.2, 11.5, font=STENCIL)


def arms_to_board(m, x, base, h, bx, by, f=1):
    """Both arms hanging forward to hold the board at chest height."""
    u = h * 0.14
    for side in (-1, 1):
        m.stroke(np.array([(x + side * u, base - h * 0.78), (x + side * u * 1.05, base - h * 0.6), (bx + side * 7, by + 4)]), h * 0.065, h * 0.052)


def gnome(s, m, beard, x, base, h):
    """Gnome, in a hoodie bought for a gnome, all head and boots. Doesn't reach the first line."""
    def P(u, v):
        return (x + u * h, base - v * h)
    # boots and little legs
    m.rrect(x - h * 0.22, base - h * 0.09, x - h * 0.02, base, 0.8)
    m.rrect(x + h * 0.02, base - h * 0.09, x + h * 0.24, base, 0.8)
    m.rect(x - h * 0.16, base - h * 0.34, x - h * 0.05, base - h * 0.05)
    m.rect(x + h * 0.05, base - h * 0.34, x + h * 0.16, base - h * 0.05)
    # jumper
    m.spoly([P(-0.27, 0.3), P(0.27, 0.3), P(0.24, 0.66), P(-0.24, 0.66)])
    # the great big hood, and a peak on it like the hat he had to leave at the desk
    m.ellipse(*P(0, 0.8), h * 0.28, h * 0.25)
    m.spoly(bez(P(-0.2, 0.92), P(-0.08, 1.0), P(0.02, 1.16), n=8).tolist() + bez(P(0.02, 1.16), P(0.08, 1.04), P(0.18, 0.92), n=8).tolist())
    # ears out the side of it: nothing else that size has ears like that
    m.spoly([P(-0.24, 0.82), P(-0.52, 0.92), P(-0.24, 0.72)])
    m.spoly([P(0.24, 0.82), P(0.52, 0.92), P(0.24, 0.72)])
    # the beard, poking out the front
    beard.ellipse(*P(0, 0.7), h * 0.15, h * 0.1)
    beard.spoly([P(-0.13, 0.7), P(0.13, 0.7), P(0.0, 0.46)])


def orc(s, x, base, h):
    """Number four: an orc who's come as he is, front on, shoulders up round his ears. The hood's down
    because nothing that wide goes through it. Green, tusks, topknot, and he's already past the top line.
    Returns where the board goes."""
    def P(u, v):
        return (x + u * h, base - v * h)

    m = s.mask()
    # big trackie legs, wide apart, and runners that had to be ordered in
    for sd in (-1, 1):
        m.spoly([P(sd * 0.02, 0.48), P(sd * 0.3, 0.48), P(sd * 0.26, 0.03), P(sd * 0.08, 0.03)])
        m.spoly([P(sd * 0.05, 0.05), P(sd * 0.27, 0.05), P(sd * 0.33, 0.0), P(sd * 0.03, 0.0)])
    # the jumper: a hill of it, shoulders higher than his chin
    pts = bez(P(-0.34, 0.42), P(-0.5, 0.62), P(-0.5, 0.86), P(-0.2, 0.9), n=14).tolist()
    pts += bez(P(0.2, 0.9), P(0.5, 0.86), P(0.5, 0.62), P(0.34, 0.42), n=14).tolist()
    m.spoly(pts)
    # sleeves down to the elbows, the elbows out
    m.stroke(np.array([P(-0.42, 0.8), P(-0.5, 0.6)]), h * 0.17, h * 0.14)
    m.stroke(np.array([P(0.42, 0.8), P(0.5, 0.6)]), h * 0.17, h * 0.14)
    # the hood, down in a lump behind his neck
    m.ellipse(*P(0, 0.87), h * 0.2, h * 0.07)
    s.paint(m, "#121713", rim=0.9, rim_dx=0, rim_dy=-0.9, rim_colour=FLUORO)

    skin = s.mask()
    # two hands that could palm a keg, coming in to a board that's far too small. Just the hands: the
    # sleeves have the rest of him, and bare green arms that long are the loudest thing on the page
    skin.stroke(np.array([P(-0.3, 0.66), P(-0.17, 0.7)]), h * 0.085, h * 0.08)
    skin.stroke(np.array([P(0.3, 0.66), P(0.17, 0.7)]), h * 0.085, h * 0.08)
    skin.ellipse(*P(-0.16, 0.71), h * 0.075, h * 0.07)
    skin.ellipse(*P(0.16, 0.71), h * 0.075, h * 0.07)
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
    cx, cy = x + f * h * 0.03, base - h * 0.91
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
    """Painted besser block, hit from above: a soft pool from each tube, and it dies off toward both ends."""
    wall = s.mask()
    wall.rect(WALL_X0, WALL_TOP, WALL_X1, FLOOR + 1)
    a = wall.array()
    X, Y = s.X / SS, s.Y / SS
    down = 0.30 + 0.70 * np.exp(-((Y - WALL_TOP) / 48) ** 2)
    across = 0.30 + 0.70 * np.exp(-((X - 770) / 210) ** 2)
    stain = 0.86 + 0.28 * fbm(s.h, s.w, 311, cells=6, octaves=4, stretch=2.0)
    col = s.colour(WALLC)
    s.rgb = s.rgb * (1 - a[..., None]) + col[None, None, :] * (a * down * across * stain)[..., None]
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
    """The fluoro batten, on a bracket, the hum of it practically visible."""
    b = s.mask()
    b.rect(x0 - 3, y - 2.6, x1 + 3, y - 0.3)
    for x in (x0 + 6, x1 - 6):
        b.rect(x - 0.6, y - 5, x + 0.6, y - 1)
    s.paint(b, "#0c0f0c")
    t = s.mask()
    t.rrect(x0, y - 0.4, x1, y + 1.5, 0.8)
    a = t.array()
    s.rgb = s.rgb * (1 - a[..., None]) + s.colour("#f5fff0") * 1.25 * a[..., None]
    s.rgb += gauss(a, 2.5 * SS)[..., None] * s.colour(FLUORO) * 0.45
    s.rgb += gauss(a, 14 * SS)[..., None] * s.colour("#c6f0b0") * 0.26


def paint():
    s = Scene("night", seed=29, horizon=120)
    s.sky(clouds=0.25, stars=0.9, glow_x=0.62, glow_w=0.2)
    s.moon(622, 22, 14, tint="#f6efdc", glow=0.45, seed=3)
    s.moon(668, 14, 6.5, tint="#a9c6ff", glow=0.45, seed=9)
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

    # the height lines and their stencilled numbers, once at each end
    m = s.mask()
    for cm, y in LINES:
        m.rect(WALL_X0 + 2, y, WALL_X1 - 2, y + 0.75)
        # the 150 would only sit half under the page buttons, so that line goes unnumbered
        if cm > 150:
            lettering(m, str(cm), 976, y - 6.2, 10, font=STENCIL)
    s.rgb *= (1 - m.array() * 0.76)[..., None]

    # the line-up. Everyone's shadow goes on the block first, hard and straight down-right
    people = s.mask()
    bx = [(612, 80), (636, 0), (668, 78), (0, 0), (788, 79), (822, 80)]
    fac = (-1, 0, -1, 0, -1, 1)
    for (x, h), f in zip(bx, fac):
        if h:
            hoodie(people, x, FLOOR, h, facing=f, slouch=0.04, hands="free")
    sleeves = s.mask()
    boards, digits = s.mask(), s.mask()
    centres = {}
    for i, ((x, h), f) in enumerate(zip(bx, fac)):
        if h:
            # chest height, up under the chin, so the page buttons get the legs and nothing else
            y = 82
            # number six has lost interest, and his board's gone with him
            bxc = x + f * h * (0.1 if i == 5 else 0.04)
            arms_to_board(sleeves, x, FLOOR, h, bxc, y, f)
            centres[i] = (bxc, y)
    glow_shadow = people.array()
    sh = np.roll(np.roll(glow_shadow, int(3 * SS), axis=1), int(1.5 * SS), axis=0)
    s.rgb *= (1 - gauss(sh, 0.5 * SS) * a * 0.42)[..., None]

    for m in (people, sleeves):
        s.paint(m, CLOTH, rim=0.85, rim_dx=0, rim_dy=-0.9, rim_colour=FLUORO)

    # number five's the only one who came with his face out
    skeleton_head(s, 788, FLOOR, 79)
    # the gnome: same board as everyone else, which is most of him
    g, beard = s.mask(), s.mask()
    gnome(s, g, beard, 636, FLOOR, 26)
    sh = np.roll(np.roll(g.array(), int(2 * SS), axis=1), int(1 * SS), axis=0)
    s.rgb *= (1 - gauss(sh, 0.4 * SS) * a * 0.42)[..., None]
    s.paint(g, CLOTH, rim=0.85, rim_dx=0, rim_dy=-0.9, rim_colour=FLUORO)
    s.paint(beard, "#dfe6d6")
    # and the one thing on him that isn't hood or beard
    nose = s.mask()
    nose.ellipse(636, FLOOR - 26 * 0.795, 26 * 0.075, 26 * 0.065)
    s.paint(nose, "#d98a6a")
    centres[1] = (636, FLOOR - 7.2)

    # number four
    oh = 80
    ox = 728
    om = s.mask()
    om.ellipse(ox, FLOOR - oh * 0.62, oh * 0.5, oh * 0.5)
    sh = np.roll(np.roll(om.array(), int(5 * SS), axis=1), int(2 * SS), axis=0)
    s.rgb *= (1 - gauss(sh, 1.0 * SS) * a * 0.42)[..., None]
    hx, hy = orc(s, ox, FLOOR, oh)
    centres[3] = (hx, hy)

    for i, (cx, cy) in sorted(centres.items()):
        board(boards, digits, cx, cy, i + 1)
    s.paint(boards, "#eef4e6")
    s.paint(digits, "#0a0d0a")
    # bony fingers round number five's board
    bone = s.mask()
    bxc, by = centres[4]
    bone.line([(bxc - 8, by + 7), (bxc - 8, by + 2)], 0.9)
    bone.line([(bxc + 8, by + 7), (bxc + 8, by + 2)], 0.9)
    s.paint(bone, "#e7e4c8")

    # someone's been at the wall with a marker, and they're not wrong
    t = s.mask()
    lettering(t, "THATS HIM", 900, 56, 12, font=SCRAWL, angle=-3, wobble=0.5, seed=4, spacing=0.4)
    pts = bez((846, 54), (812, 46), (770, 49), (758, 58), n=16)
    t.stroke(pts, 1.5, 1.1)
    t.stroke(np.array([(758, 58), (767, 57)]), 1.4, 1.0)
    t.stroke(np.array([(758, 58), (759, 49.5)]), 1.4, 1.0)
    s.paint(t, "#120f0a")

    # two tubes over the lot of them
    tubes(s, 612, 690, WALL_TOP + 4)

    # a touch of sick green on the concrete out front
    pool = np.exp(-(((s.X / SS - 700) / 170) ** 2)) * smooth(FLOOR * SS, (FLOOR + 3) * SS, s.Y)
    s.rgb += pool[..., None] * s.colour("#7fa86c") * 0.22

    # framing gums, and the left one keeps the title dark
    m = s.mask()
    gum_tree(m, 218, 180, 176, seed=12, lean=0.04)
    gum_tree(m, 1034, 176, 150, seed=33, lean=-0.05, spread=0.9)
    s.paint(m, "#02040a")
    s.rgb *= (0.44 + 0.56 * smooth(430 * SS, 600 * SS, s.X))[..., None]
    return s.finish(bloom=0.34, vignette=0.12)
