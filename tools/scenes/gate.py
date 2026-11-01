"""The gate: what you get if you're not in the guild. Razor wire, a brass padlock and a sheet of ply
that says NO RANDOMS, with a staffy in the gap to answer any questions. The alley carries on behind
it, and nobody back there is expecting you. Only the middle 550 units show, because the window's
narrower than a page, and a panel covers it from y 126 down."""
import numpy as np

from scenekit import SCRAWL, Scene, bez, foil_window, gauss, gum_tree, house, lettering, power_pole, razor_wire, SS, trolley, wires, wreck

VX, VY = 520, 100           # where the alley disappears to
POST_L, POST_R = 396, 644   # gate posts
GAP_L, GAP_R = 495, 545     # the leaves don't quite meet, and the chain only goes so far
TOP, BASE = 54, 127         # gate top rail and the ground under it
FENCE = TOP + 8             # top of the fence either side


def mesh(m, x0, y0, x1, y1, step=7.0, width=0.5):
    """Chain wire: two sets of diagonals, cut off square at the panel's edges."""
    span = (x1 - x0) + (y1 - y0)
    for sign in (1, -1):
        c = -(y1 - y0)
        while c < span:
            pts = []
            for t in (0.0, y1 - y0):
                x = x0 + c + (t if sign > 0 else (y1 - y0) - t)
                pts.append((x, y0 + t))
            (ax, ay), (bx, by) = pts
            # clip the line to the sides of the panel
            dx, dy = bx - ax, by - ay
            lo, hi = 0.0, 1.0
            if dx != 0:
                t0, t1 = (x0 - ax) / dx, (x1 - ax) / dx
                lo, hi = max(lo, min(t0, t1)), min(hi, max(t0, t1))
            if lo < hi:
                m.line([(ax + dx * lo, ay + dy * lo), (ax + dx * hi, ay + dy * hi)], width)
            c += step


def leaf(m, x0, x1):
    """One side of the gate: a pipe frame with a rail through the middle."""
    w = 2.0
    m.rect(x0, TOP, x0 + w, BASE - 2)
    m.rect(x1 - w, TOP, x1, BASE - 2)
    m.rect(x0, TOP, x1, TOP + w)
    m.rect(x0, BASE - 2 - w, x1, BASE - 2)
    m.rect(x0, 112, x1, 113.4)


def post(m, x, top):
    m.rect(x - 2.6, top, x + 2.6, BASE + 2)
    m.rrect(x - 3.4, top - 1.8, x + 3.4, top + 1.0, 0.8)


def chain(m, a, b, sag, link=1.25):
    """A loose run of chain: little alternating links along a sagging curve."""
    length = np.hypot(b[0] - a[0], b[1] - a[1])
    pts = bez(a, ((a[0] + b[0]) / 2, (a[1] + b[1]) / 2 + sag), b, n=max(4, int(length / (link * 1.25))))
    for i, (x, y) in enumerate(pts):
        if i % 2:
            m.ellipse(x, y, link, link * 0.66)
        else:
            m.ellipse(x, y, link * 0.66, link)


def padlock(s, x, y):
    """The one bright thing on the gate: a brass padlock hanging off the chain."""
    m = s.mask()
    m.stroke(bez((x - 3.4, y + 1), (x - 3.6, y - 7.5), (x + 3.6, y - 7.5), (x + 3.4, y + 1), n=18), 1.5, 1.5)
    s.paint(m, "#aab2b6", rim=0.5, rim_dx=0.4, rim_dy=-0.5, rim_colour="#ffffff")
    m = s.mask()
    m.rrect(x - 6, y, x + 6, y + 11.5, 1.5)
    s.paint(m, "#e0ad48", bottom="#7a5620", top_y=y - 60, rim=0.8, rim_dx=0.5, rim_dy=-0.7, rim_colour="#ffe9b0")
    k = s.mask()
    k.ellipse(x, y + 4.8, 1.25, 1.25)
    k.rect(x - 0.55, y + 4.8, x + 0.55, y + 8.4)
    s.paint(k, "#23180a")


def no_entry(s, x, y, r):
    """Red disc, white bar, white edge: nobody needs that one explained."""
    m = s.mask()
    m.ellipse(x, y, r + 1.1, r + 1.1)
    s.paint(m, "#d8d6cb", rim=0.25, rim_dx=0.4, rim_dy=-0.5, rim_colour="#ffffff")
    m = s.mask()
    m.ellipse(x, y, r, r)
    s.paint(m, "#c9352a", bottom="#7d1c16", top_y=y - 70)
    m = s.mask()
    m.rrect(x - r * 0.72, y - r * 0.2, x + r * 0.72, y + r * 0.2, 0.5)
    s.paint(m, "#efece0")
    # wired on at the top and bottom
    m = s.mask()
    for yy in (y - r - 1.6, y + r + 1.6):
        m.rect(x - 1.0, yy - 0.4, x + 1.0, yy + 0.4)
    s.paint(m, "#8c9499")


def staffy_front(s, x, y):
    """A staffy square on, head first: a wide skull on no neck at all, cheeks, a white blaze and a
    look that says he's already decided. The kit's dog is side on and can't look at you. (x, y) is
    the middle of the skull."""
    # chest and shoulders, forelegs planted wide, running down behind the panel
    m = s.mask()
    m.spoly(bez((x - 21, y + 12), (x - 28, y + 22), (x - 23, y + 32), (x - 14, y + 37), n=10).tolist()
            + bez((x + 14, y + 37), (x + 23, y + 32), (x + 28, y + 22), (x + 21, y + 12), n=10).tolist())
    s.paint(m, "#2c3641", bottom="#141b24", top_y=y - 50, rim=0.55, rim_dx=0, rim_dy=-0.8, rim_colour="#ffc98c")
    # the white chest, all staffies come with one
    m = s.mask()
    m.spoly(bez((x - 9, y + 17), (x - 10, y + 24), (x - 4, y + 34), (x, y + 38), n=10).tolist()
            + bez((x, y + 38), (x + 4, y + 34), (x + 10, y + 24), (x + 9, y + 17), n=10).tolist())
    s.paint(m, "#aeb6ba")
    # ears, folded back and a bit chewed
    m = s.mask()
    m.spoly([(x - 13, y - 11), (x - 24, y - 15), (x - 23.5, y - 5), (x - 17, y - 3)])
    m.spoly([(x + 13, y - 11), (x + 24, y - 15), (x + 23.5, y - 5), (x + 17, y - 3)])
    s.paint(m, "#1b232c", rim=0.6, rim_dx=0, rim_dy=-0.8, rim_colour="#ffc98c")
    # the head, about as wide as it is high, cheeks wider than the skull
    m = s.mask()
    pts = bez((x - 11, y - 13.5), (x - 18, y - 12), (x - 20.5, y + 1), (x - 15, y + 9), n=12).tolist()
    pts += bez((x - 15, y + 9), (x - 11, y + 15), (x + 11, y + 15), (x + 15, y + 9), n=10).tolist()
    pts += bez((x + 15, y + 9), (x + 20.5, y + 1), (x + 18, y - 12), (x + 11, y - 13.5), n=12).tolist()
    m.spoly(pts)
    s.paint(m, "#3b4753", bottom="#222b35", top_y=y - 62, rim=0.65, rim_dx=0, rim_dy=-0.8, rim_colour="#ffc98c")
    # blaze down the forehead, opening into the muzzle
    m = s.mask()
    m.spoly([(x - 2.2, y - 13.5), (x + 2.2, y - 13.5), (x + 3, y - 2), (x - 3, y - 2)])
    m.rrect(x - 11, y + 0.5, x + 11, y + 14.3, 5.5)
    m.rrect(x - 3.2, y - 3, x + 3.2, y + 3, 1.5)
    s.paint(m, "#c9cfd0", bottom="#9aa3a7", top_y=y - 60)
    # brows, drawn down hard, then the eyes under them catching the alley's light
    m = s.mask()
    m.ellipse(x - 9, y - 3, 4.2, 3)
    m.ellipse(x + 9, y - 3, 4.2, 3)
    s.paint(m, "#0a0d11")
    m = s.mask()
    m.stroke(np.array([(x - 14.5, y - 8), (x - 3, y - 4)]), 2.2, 1.8)
    m.stroke(np.array([(x + 14.5, y - 8), (x + 3, y - 4)]), 2.2, 1.8)
    s.paint(m, "#3b4753")
    e = s.mask()
    e.ellipse(x - 8.6, y - 2.4, 1.5, 1.4)
    e.ellipse(x + 8.6, y - 2.4, 1.5, 1.4)
    a = e.array()
    s.rgb = s.rgb * (1 - a[..., None]) + s.colour("#ffd98a") * a[..., None]
    s.rgb += gauss(a, 1.1 * SS)[..., None] * s.colour("#ffb050") * 0.7
    # nose and the flat line of the mouth: he isn't smiling, he just has that head
    m = s.mask()
    m.spoly([(x - 5.2, y + 1.7), (x + 5.2, y + 1.7), (x + 3.6, y + 6), (x, y + 7.2), (x - 3.6, y + 6)])
    m.line([(x, y + 7), (x, y + 9.6)], 0.8)
    m.stroke(bez((x - 9.4, y + 9), (x - 5, y + 11.2), (x, y + 9.6), n=8), 0.8, 0.9)
    m.stroke(bez((x, y + 9.6), (x + 5, y + 11.2), (x + 9.4, y + 9), n=8), 0.9, 0.8)
    s.paint(m, "#0a0c10")
    # a collar you could tow a car with, and the chain running off it into the dark
    m = s.mask()
    m.stroke(bez((x - 17, y + 14), (x, y + 21), (x + 17, y + 14), n=12), 3.6, 3.6)
    s.paint(m, "#1a0e0c", rim=0.45, rim_dx=0, rim_dy=-0.5, rim_colour="#d5c4a6")
    m = s.mask()
    for k in (-11, -5.5, 5.5, 11):
        m.ellipse(x + k, y + 17.5 - abs(k) * 0.13 + (0 if abs(k) > 6 else 0.5), 0.9, 0.9)
    s.paint(m, "#d9dee0")
    m = s.mask()
    chain(m, (x, y + 19.5), (x + 3, y + 25), 0, link=1.5)
    chain(m, (x + 3, y + 25), (x + 34, y + 25), 6, link=1.5)
    s.paint(m, "#6e7a82", rim=0.3, rim_dx=0.3, rim_dy=-0.4, rim_colour="#d7e0e4")


def ply_board(s, cx, cy, w, h, tilt):
    """A sheet of formply off some job, wired on crooked, with the house rules done in one go by
    someone who was shaking the can with the other hand. This is the joke, so it's the palest thing."""
    t = np.radians(tilt)
    ca, sa = np.cos(t), np.sin(t)

    def P(u, v):
        return (cx + u * ca - v * sa, cy + u * sa + v * ca)

    corners = [P(-w / 2, -h / 2), P(w / 2, -h / 2 + 1), P(w / 2 - 0.8, h / 2), P(-w / 2 + 0.6, h / 2 - 0.6)]
    # a little shadow on the mesh behind it
    m = s.mask()
    m.spoly([(x + 1.5, y + 2) for x, y in corners])
    a = gauss(m.array(), 1.2 * SS)
    s.rgb = s.rgb * (1 - a[..., None] * 0.6)
    m = s.mask()
    m.spoly(corners)
    s.paint(m, "#b49c72", bottom="#7d6a4a", top_y=cy - 75, rim=0.3, rim_dx=0, rim_dy=-0.7, rim_colour="#f0e0bc")
    # grain and a damp stain, just enough that it's wood
    g = s.mask()
    rng = np.random.default_rng(6)
    for k in range(9):
        v = -h / 2 + (k + 0.6) * h / 9
        g.line([P(-w / 2 + 1, v + rng.uniform(-0.5, 0.5)), P(w / 2 - 1, v + rng.uniform(-0.5, 0.5))], 0.3)
    s.paint(g, "#6d5b3e")
    # the words
    m = s.mask()
    lettering(m, "NO", cx - 1, cy - h * 0.235, 13.5, font=SCRAWL, angle=tilt - 1, wobble=0.5, seed=2, spacing=1.2)
    lettering(m, "RANDOMS", cx + 0.5, cy + h * 0.23, 11.5, font=SCRAWL, angle=tilt + 0.8, wobble=0.42, seed=8, spacing=-0.3)
    s.paint(m, "#100a0a")
    # wire ties at the corners
    m = s.mask()
    for u, v in ((-w / 2 + 2.5, -h / 2 + 2.5), (w / 2 - 2.5, -h / 2 + 2.5), (-w / 2 + 2.5, h / 2 - 2.5), (w / 2 - 2.5, h / 2 - 2.5)):
        px, py = P(u, v)
        m.line([(px - 1.5, py - 1.5), (px + 1.5, py + 1.5)], 0.7)
        m.line([(px - 1.5, py + 1.5), (px + 1.5, py - 1.5)], 0.7)
    s.paint(m, "#3e4950")


def paint():
    s = Scene("night", seed=41, horizon=VY)
    s.sky(clouds=0.42, stars=0.95, glow_x=0.5, glow_w=0.13)
    s.moon(690, 36, 25, tint="#f6efdc", glow=0.55, seed=3)
    s.moon(738, 19, 7.5, tint="#a9c6ff", glow=0.45, seed=9)
    s.ridge(VY - 4, 12, 83, "#1e3a55", roughness=4)
    s.fog(78, VY + 4, strength=0.26, seed=6)
    s.glow(VX, VY - 2, 70, colour="#ffb26a", strength=0.2)

    # the far hedge of gums, then the dirt coming down to the gate
    m = s.mask()
    for i, x in enumerate((262, 318, 372, 452, 590, 660, 712, 770)):
        gum_tree(m, x, VY + 4, 32 + (i * 19) % 18, seed=170 + i, leaves=0.9)
    m.rect(0, VY + 1, 1040, 148)
    s.paint(m, "#10233c", rim=0.1)
    m = s.mask()
    m.spoly([(VX, VY), (1040, VY + 24), (1040, 148), (0, 148), (0, VY + 24)])
    s.paint(m, "#17293f", bottom="#0a1626", top_y=VY - 10)

    # both sides of the alley, far to near. Not a light on anywhere, which is its own kind of worse
    near, hazed = s.colour("#081120"), s.colour("#274866")
    for side in (-1, 1):
        for d in (24, 44, 72, 112):
            t = ((d - 24) / 88.0) ** 0.6
            h = d * 0.2
            w = h * 2.8
            base = VY + d * 0.11
            x0 = VX + d if side > 0 else VX - d - w
            m = s.mask()
            house(m, x0, base, w, h, veranda=False, chimney=d >= 44, antenna=d == 72)
            s.paint(m, s.tone(hazed, near, t), rim=0.12 + 0.3 * t, rim_dx=0.7, rim_dy=-0.8)

    # the one place that's got its windows done: nearest on the right, foil and all, and something's
    # on in there, because it's the only house with power
    m = s.mask()
    house(m, 655, 121, 125, 40, veranda=False, chimney=True, antenna=False)
    s.paint(m, "#0a1524", rim=0.34, rim_dx=0.7, rim_dy=-0.8)
    foil_window(s, 684, 88, 46, 24, seed=7, strength=0.8)
    f = s.mask()
    f.rect(682.4, 86.4, 731.6, 88)
    f.rect(682.4, 112, 731.6, 113.8)
    f.rect(682.4, 88, 684, 112)
    f.rect(730, 88, 731.6, 112)
    s.paint(f, "#050a14")
    s.glow(707, 100, 26, colour="#9fc4e0", strength=0.09)

    # the road, running up from under the gate
    m = s.mask()
    m.spoly([(VX - 1.4, VY), (VX + 1.4, VY), (VX + 92, 148), (VX - 92, 148)])
    s.paint(m, "#0d1928", bottom="#121f30", top_y=VY)

    # what's left of someone's Commodore, up on bricks in the back-glow
    m = s.mask()
    wreck(m, 594, 118, 80, facing=1)
    s.glow(594, 104, 36, colour="#ffb26a", strength=0.12)
    s.paint(m, "#060b13", rim=0.62, rim_dx=-0.7, rim_dy=-0.7, rim_colour="#ffc48a")

    # power pole off to the side, the wires going away over the fence
    m = s.mask()
    heads = power_pole(m, 772, BASE + 2, 98)
    wires(m, heads[0], (300, 34), sag=9, width=0.5)
    wires(m, heads[3], (1040, 42), sag=8, width=0.5)
    s.paint(m, "#070e1a", rim=0.16, rim_dx=0.5, rim_dy=-0.6)

    # behind the gate, and in no hurry
    staffy_front(s, VX, 92)

    # the fence and the gate
    m = s.mask()
    mesh(m, 0, FENCE, POST_L - 3, BASE - 1)
    mesh(m, POST_R + 3, FENCE, 1040, BASE - 1)
    mesh(m, POST_L + 3, TOP + 1, GAP_L, BASE - 3)
    mesh(m, GAP_R, TOP + 1, POST_R - 3, BASE - 3)
    s.paint(m, "#5b7486")
    m = s.mask()
    m.rect(0, FENCE, POST_L, FENCE + 1.4)
    m.rect(POST_R, FENCE, 1040, FENCE + 1.4)
    for x in list(range(92, POST_L - 40, 80)) + list(range(POST_R + 80, 1040, 80)):
        m.rect(x - 1.1, FENCE - 2, x + 1.1, BASE + 2)
    leaf(m, POST_L + 3, GAP_L)
    leaf(m, GAP_R, POST_R - 3)
    post(m, POST_L, TOP - 6)
    post(m, POST_R, TOP - 6)
    for x in (POST_L + 3, POST_R - 5):        # hinges
        for y in (TOP + 6, BASE - 12):
            m.rect(x - 1, y, x + 3, y + 2.2)
    s.paint(m, "#0e1826", rim=0.42, rim_dx=0.6, rim_dy=-0.7, rim_colour="#a9c7d8")

    # razor wire the whole way along, a step up over the gate
    m = s.mask()
    razor_wire(m, 240, POST_L, FENCE - 5.5, r=5.6, width=0.5)
    razor_wire(m, POST_R, 800, FENCE - 5.5, r=5.6, width=0.5)
    razor_wire(m, POST_L, POST_R, TOP - 5.5, r=5.6, width=0.5)
    s.paint(m, "#a4bccb")

    # the sign, and the ply, and the chain across the gap with the lock hanging off it
    no_entry(s, 594, 70, 12.5)
    ply_board(s, 446, 86, 92, 45, -2.5)
    m = s.mask()
    chain(m, (GAP_L - 3, 62), (GAP_R + 3, 62), 3.5)
    s.paint(m, "#7b8790", rim=0.3, rim_dx=0.3, rim_dy=-0.4, rim_colour="#d7e0e4")
    padlock(s, VX, 69)
    s.glow(VX, 75, 13, colour="#ffcf8a", strength=0.08)

    # on this side of the gate: the ground gone to weeds, and someone's trolley rammed into the wire
    m = s.mask()
    pts = bez((0, 124), (340, 127), (700, 124), (1040, 126), n=40).tolist()
    m.spoly(pts + [(1040, 148), (0, 148)])
    rng = np.random.default_rng(14)
    for x in rng.uniform(240, 800, 170):
        y = 126 + rng.uniform(-1.5, 1)
        m.line([(x, y + 1.5), (x + rng.uniform(-1.2, 1.2), y - rng.uniform(0.8, 3.4))], 0.35)
    s.paint(m, "#04090f", rim=0.12, rim_dx=0, rim_dy=-0.8)
    m = s.mask()
    trolley(m, 386, 124, 44, facing=1, tip=-7, width=1.1)
    s.paint(m, "#a9c0cc", rim=0.3, rim_dx=0.4, rim_dy=-0.6, rim_colour="#e4f0f4")

    # a dark gum to close the left of the frame
    m = s.mask()
    gum_tree(m, 214, 176, 170, seed=44, lean=0.02, spread=0.9)
    m.rect(0, 144, 1040, 148)
    s.paint(m, "#02050a")
    return s.finish()
