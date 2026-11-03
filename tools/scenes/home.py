"""The Street: the whole neighbourhood after dark, under Azeroth's two moons. The only thing the council
lights up is a burnt-out Commodore on bricks, and someone's runners have been on the wire since before it got there.
And on a milk crate under the light, 2am, a bloke having a quiet one and looking at it."""
import math

import numpy as np

from scenekit import SS, Scene, bez, fbm, foil_window, gauss, glass_pipe, gum_tree, house, lighter, light_windows, lit_rim, power_pole, wires, wreck


def runners(s, x, y, h):
    """The kit's runners, side on with a pale sole and tipped less, because at this size the sole is
    what tells you it's a shoe and not a pair of bags."""
    upper, sole, lace = s.mask(), s.mask(), s.mask()
    for side, drop, tip in ((-1, h * 0.60, 52), (1, h * 0.86, 40)):
        px, py = x + side * h * 0.50, y + drop
        lace.line([(x, y), (px, py)], 0.55)
        k = h * 0.56

        def P(u, w):
            # toe out along u, w up from the sole, hung by the collar and rotated toe-down
            uu, vv = side * (u - 0.2) * k, -(w - 0.62) * k
            a = math.radians(side * tip)
            return (px + uu * math.cos(a) - vv * math.sin(a), py + uu * math.sin(a) + vv * math.cos(a))

        upper.spoly([P(*p) for p in ((0.0, 0.1), (1.0, 0.1), (1.02, 0.24), (0.86, 0.34), (0.58, 0.42), (0.42, 0.62), (0.04, 0.62), (0.0, 0.42))])
        sole.spoly([P(*p) for p in ((-0.03, 0.0), (0.98, 0.0), (1.08, 0.08), (1.05, 0.16), (-0.03, 0.16))])
    s.paint(lace, "#070916")
    s.paint(upper, "#0c0e22", rim=0.4, rim_dx=0.2, rim_dy=-0.6, rim_colour="#ffd9a0")
    s.paint(sole, "#d6d0cc")


def charred(s, m):
    """Paints a silhouette as burnt panel: soot and a dull rust coming through, no shine left on it.
    It's a big soft wash: any sharper and it goes to leopard print at true size."""
    a = m.array()[..., None]
    n = fbm(s.h, s.w, 77, cells=11, octaves=2)
    rust = np.clip((n - 0.50) * 2.2, 0, 1)[..., None]
    ash = np.clip((0.40 - n) * 2.2, 0, 1)[..., None]
    col = s.colour("#0b0808") * (1 - rust) + s.colour("#35190e") * rust
    col = col * (1 - ash) + s.colour("#25242b") * ash
    s.rgb = s.rgb * (1 - a) + col * a


def limb(m, P, joints, widths):
    """An arm or a leg: straight bones, tapering, with a round joint at each bend."""
    for i in range(len(joints) - 1):
        m.stroke(np.array([P(*joints[i]), P(*joints[i + 1])]), widths[i], widths[i + 1])
    for j, w in zip(joints, widths):
        m.ellipse(*P(*j), w / 2, w / 2)


def sitter(s, x, base):
    """Someone in a hoodie on an upturned milk crate, knees up and hunched right over it: one hand up
    holding the pipe to his mouth, the other out at arm's length with a lighter under the bulb.
    (x, base) is the middle of the crate on the kerb. Same scale as the car."""
    LAMP = (676, 74)

    def P(u, v):
        return (x + u, base - v)

    # the crate, a bit paler than he is, with the slots you can see through
    c = s.mask()
    c.rect(*P(-7, 10), *P(7, 0))
    for i in range(3):
        c.rect(*P(-5.6 + i * 4.1, 7.8), *P(-2.8 + i * 4.1, 1.6), fill=0)
    s.paint(c, "#2f3660")
    lit_rim(s, c, *LAMP, 80, "#ffd9a0", 0.8)

    def foot(m, a):
        m.spoly([P(a - 2.2, 4), P(a + 2.2, 4), P(a + 6.5, 1.8), P(a + 7, 0), P(a - 2.4, 0)])

    # the far side of him first, a shade darker: far leg, far arm with the lighter on the end
    m = s.mask()
    limb(m, P, [(1, 13), (16, 19.5), (19, 2.5)], [7.4, 5.4, 3.8])
    foot(m, 19)
    limb(m, P, [(3, 33), (16, 26.5), (26, 20)], [5.0, 4.2, 3.0])
    s.paint(m, "#05060f")
    lit_rim(s, m, *LAMP, 85, "#ffd9a0", 0.9)
    # near leg, back bent right over, hood pushed forward
    m = s.mask()
    limb(m, P, [(-1, 13), (12, 20.5), (8, 2.5)], [7.8, 5.6, 4.0])
    foot(m, 8)
    body = bez(P(-6, 10), P(-10, 20), P(-9, 30), P(-2, 35.5), n=14).tolist()
    body += bez(P(-2, 35.5), P(6, 37), P(9, 28), P(4, 11), n=12).tolist()
    m.spoly(body)
    # with a notch at the nape, so there's a head on those shoulders and not one big lump
    hood = [(P(2.6, 34))] + bez(P(2.6, 36), P(0.4, 41), P(0.6, 46), P(3, 50.5), n=10).tolist()
    hood += bez(P(3, 50.5), P(9, 51.5), P(16, 49), P(17.4, 43.5), n=10).tolist()
    hood += bez(P(17.4, 43.5), P(17.6, 38), P(14.5, 33), P(9, 31.5), n=10).tolist()
    m.spoly(hood)
    s.paint(m, "#0b0c1c")
    lit_rim(s, m, *LAMP, 85, "#ffd9a0", 1.3)
    # pale soles, the same as the ones on the wire
    f = s.mask()
    for a in (8, 19):
        f.rect(*P(a - 2.4, 1.0), *P(a + 7, 0))
    s.paint(f, "#a8a3a2")
    # where the face would be: nothing, just dark, with the stem going in
    f = s.mask()
    f.spoly(bez(P(16.2, 46), P(10.5, 46), P(10, 37.5), P(14.4, 34.2), n=12).tolist() + bez(P(14.4, 34.2), P(16.8, 37), P(17.2, 42), P(16.2, 46), n=8).tolist())
    s.paint(f, "#02030a")
    # the near arm: elbow down near the knee, forearm back up to the stem
    m = s.mask()
    limb(m, P, [(0, 33), (11, 25), (18, 34)], [5.6, 4.4, 3.2])
    s.paint(m, "#0f1124")
    lit_rim(s, m, *LAMP, 85, "#ffd9a0", 1.2)
    # the pipe, stem in the hood, bulb out in front over the flame
    mx, my = x + 13, base - 38
    length, ang = 15.5, 8
    glass_pipe(s, mx, my, length, angle=ang, bulb=2.3, width=1.1, smoke=0, ember=0.0, lit="#e8f0ff")
    ax, ay = mx + length * math.cos(math.radians(ang)), my + length * math.sin(math.radians(ang))
    # the fingers go over the stem, or it's floating past him
    g = s.mask()
    g.ellipse(*P(18.8, 36.6), 2.2, 2.4)
    s.paint(g, "#14162c")
    lit_rim(s, g, *LAMP, 85, "#ffd9a0", 1.0)
    # the lighter, and the flame licking the bottom of the bulb
    lx = ax - 0.6
    ltop = ay + 2.3 + 4.6
    lighter(s, lx, ltop + 9.5, length=9.5, standing=True)
    h = s.mask()
    h.ellipse(lx - 0.6, ltop + 7.4, 2.9, 3.1)
    h.stroke(np.array([(lx + 1.2, ltop + 7.2), (lx + 1.3, ltop + 2.4)]), 1.5, 1.2)
    s.paint(h, "#0a0b1a")
    s.glow(ax, ay + 3.4, 8, colour="#ff7a2e", strength=0.34)
    fl = s.mask()
    fl.spoly(bez((lx, ltop + 0.2), (lx - 2.1, ltop - 1.4), (ax, ay + 2.2), n=10).tolist() + bez((ax, ay + 2.2), (lx + 2.1, ltop - 1.4), (lx, ltop + 0.2), n=10).tolist())
    fa = fl.array()
    s.rgb = s.rgb * (1 - fa[..., None]) + s.colour("#ffc768") * 1.5 * fa[..., None]
    # the flame's all the light he's got on his front
    lit_rim(s, m, ax, ay + 3, 14, "#ff9a48", 1.2)
    lit_rim(s, h, ax, ay + 3, 14, "#ff9a48", 1.6)
    lit_rim(s, g, ax, ay + 3, 16, "#ff9a48", 1.2)
    # and a thin curl going up off the bulb
    w = s.mask()
    t = np.linspace(0, 1, 50)
    pts = np.stack((ax + np.sin(t * 8.5) * (0.6 + 2.2 * t), ay - 2.6 - 28 * t), axis=1)
    w.stroke(pts, 0.8, 1.6)
    fade = np.clip((s.Y / SS - (ay - 30)) / 22, 0, 1)
    s.rgb += (gauss(w.array(), 0.2 * SS) * fade * 0.55)[..., None] * s.colour("#dfe4ea")


def paint():
    s = Scene("dusk", seed=4)
    s.sky(clouds=0.5, stars=1.0, glow_x=0.64)
    s.moon(704, 30, 17, tint="#f6efdc", glow=0.55, seed=3)
    s.moon(660, 20, 8.5, tint="#a9c6ff", glow=0.5, seed=9)
    s.ridge(101, 24, 31, "#38385e", roughness=4)
    s.fog(84, 112, strength=0.30)
    s.ridge(109, 12, 37, "#28294b", roughness=5)
    # far gums over the rooftops
    m = s.mask()
    for i, x in enumerate((300, 352, 476, 560, 610, 668, 800, 868, 926, 990)):
        gum_tree(m, x, 124, 44 + (i * 37) % 24, seed=50 + i, leaves=0.9)
    m.rect(0, 121, 1040, 148)
    s.paint(m, "#17193a", rim=0.12)
    s.fog(100, 128, strength=0.20, seed=8)
    # cottages, the far ones small and dim; nothing lit behind the page title
    m = s.mask()
    house(m, 262, 137, 84, 21, veranda=False)
    house(m, 518, 138, 104, 26)
    house(m, 792, 139, 106, 27)
    m.rect(0, 134, 1040, 148)
    s.paint(m, "#0d0f26", rim=0.2)
    # the left cottage has done its windows in foil, and the right one's still got someone up with the lamp on
    foil_window(s, 534, 119.5, 16, 12, seed=3)
    foil_window(s, 585, 119.5, 16, 12, seed=4)
    light_windows(s, [(810, 121, 13, 10), (862, 121, 13, 10)], strength=0.95)
    # the power line marching across
    m = s.mask()
    tops = [power_pole(m, x, 150, 112) for x in (420, 628, 958)]
    for a, b in zip(tops[:-1], tops[1:]):
        for k in range(4):
            wires(m, a[k], b[k], sag=8.0, width=0.42)
    wires(m, (150, 58), tops[0][0], sag=5, width=0.42)
    wires(m, tops[-1][3], (1040, 52), sag=3, width=0.42)
    # runners over the bottom wire, hanging down into the streetlight's glow
    s.paint(m, "#070916")
    runners(s, 716, 48.3, 30)
    # streetlight, its pool of light, and the kerb
    s.beam(676, 74, 80, 24, 46, strength=0.26)
    s.glow(676, 74, 7, strength=0.95)
    s.glow(676, 74, 26, strength=0.16)
    m = s.mask()
    pole = bez((669, 148), (669, 96), (668, 76), (674, 72), n=20)
    m.stroke(pole, 2.1, 1.1)
    m.rrect(670, 70, 684, 73.6, 1)
    m.spoly([(0, 141), (240, 140), (520, 142), (800, 140), (1040, 141), (1040, 148), (0, 148)])
    s.paint(m, "#04050e", rim=0.34, rim_dx=-0.9, rim_dy=-0.8, rim_colour="#ffd9a0")
    s.glow(722, 142, 34, colour="#ffd9a0", strength=0.10)
    # the Commodore, parked for good and lit like it's in a showroom: door panels rusted through, roof sagged
    m = s.mask()
    wreck(m, 722, 141.5, 110, facing=1)
    for hole in ([(694, 120), (703, 119), (705, 125), (697, 127)],):
        m.spoly(hole, fill=0)
    m.spoly([(692, 104), (714, 104), (710, 107.2), (698, 107.4)], fill=0)
    charred(s, m)
    lit_rim(s, m, 676, 74, 70, "#ffd9a0", 0.6)
    # the stack under the back axle: actual bricks, two courses, with the joints showing
    b = s.mask()
    b.rect(680, 138.4, 688.6, 141.6)
    b.rect(689.4, 138.4, 698, 141.6)
    b.rect(684.4, 134.8, 693.8, 137.6)
    s.paint(b, "#6e3a2a", rim=0.5, rim_dx=-0.5, rim_dy=-0.6, rim_colour="#ffd9a0")
    # a thread of smoke still coming off it, days later
    w = s.mask()
    w.stroke(bez((746, 118), (740, 104), (756, 96), (748, 76), n=30), 1.0, 3.0)
    fade = np.clip((s.Y / SS - 72) / 46, 0, 1)
    s.rgb += (gauss(w.array(), 0.8 * SS) * fade * 0.32)[..., None] * s.colour("#dfd7d0")
    # the only other soul on the street: a bit of the lamp's spill so you can see him, and him
    s.glow(648, 128, 26, colour="#ffd9a0", strength=0.14)
    sitter(s, 635, 141.5)
    # big dark gums framing the scene, and giving the title something dark to sit on
    m = s.mask()
    gum_tree(m, 1012, 170, 178, seed=7, lean=-0.1, spread=1.1)
    gum_tree(m, 236, 176, 170, seed=12, lean=0.06)
    s.paint(m, "#03040a")
    return s.finish()
