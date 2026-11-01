"""The Street: the whole neighbourhood after dark, under Azeroth's two moons. The only thing the council
lights up is a burnt-out Commodore on bricks, and someone's runners have been on the wire since before it got there.
And on a milk crate under the light, 2am, a bloke having a quiet one and looking at it."""
import math

import numpy as np

from scenekit import SS, Scene, bez, fbm, foil_window, gauss, glass_pipe, gum_tree, house, light_windows, lit_rim, power_pole, wires, wreck


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


def sitter(s, x, base):
    """Someone in a hoodie on an upturned milk crate, knees up, elbow on his knee, pipe at his face.
    (x, base) is the middle of the crate on the kerb. Same scale as the car."""
    LAMP = (676, 74)
    # the crate, a bit paler than he is
    c = s.mask()
    c.rect(x - 6.5, base - 9, x + 6.5, base)
    for i in range(3):
        c.rect(x - 5.2 + i * 3.8, base - 7, x - 3 + i * 3.8, base - 1.4, fill=0)
    s.paint(c, "#2a3050")
    lit_rim(s, c, *LAMP, 80, "#ffd9a0", 0.8)
    hip, knee, ankle = (x + 0.5, base - 11), (x + 12, base - 15), (x + 14, base - 1.5)
    shoulder, mouth = (x + 5.5, base - 26), (x + 13.2, base - 29.5)
    m = s.mask()
    m.stroke(np.array([hip, knee]), 6.0, 4.4)
    m.stroke(np.array([knee, ankle]), 4.2, 3.0)
    m.spoly([(ankle[0] - 2, base - 3), (ankle[0] + 2, base - 3), (ankle[0] + 5.5, base - 1), (ankle[0] + 5.5, base), (ankle[0] - 2, base)])
    m.stroke(bez((x - 1, base - 9), (x - 4, base - 18), (x - 1, base - 26), shoulder, n=12), 8.0, 8.0)
    m.spoly([(x - 4, base - 9), (x + 5, base - 9), (x + 9, base - 24), (x + 3, base - 29), (x - 4, base - 22)])
    # hood, pushed forward over the pipe
    m.spoly(bez((x + 2.5, base - 25), (x + 1, base - 33), (x + 7, base - 36.5), (x + 11, base - 35), n=12).tolist()
            + bez((x + 11, base - 35), (x + 14.5, base - 33), (x + 14.5, base - 29), (x + 12, base - 26), n=8).tolist())
    # elbow on the knee, hand up to the stem
    elbow = (knee[0] + 0.5, knee[1] - 1)
    m.stroke(np.array([shoulder, elbow]), 3.8, 3.2)
    hand = (mouth[0] + 3.5, mouth[1] + 2.2)
    m.stroke(np.array([elbow, hand]), 3.2, 2.5)
    s.paint(m, "#0b0c1c")
    lit_rim(s, m, *LAMP, 85, "#ffd9a0", 1.3)
    glass_pipe(s, mouth[0], mouth[1], 13, angle=12, bulb=1.95, width=1.1, smoke=0, ember=0.0, lit="#e8f0ff")
    ax, ay = mouth[0] + 13 * math.cos(math.radians(12)), mouth[1] + 13 * math.sin(math.radians(12))
    # the ember: all you'd see of him if the council ever fixed the light
    s.glow(ax, ay, 7, colour="#ff7a2e", strength=0.40)
    s.glow(ax, ay + 0.3, 2.2, colour="#ffb45e", strength=1.3)
    e = s.mask()
    e.ellipse(ax, ay + 0.3, 1.25, 1.25)
    ea = e.array()
    s.rgb = s.rgb * (1 - ea[..., None]) + s.colour("#ffd08a") * 1.6 * ea[..., None]
    lit_rim(s, m, ax, ay, 12, "#ff9a48", 1.4)
    # and a thin curl going up past the lamp pole
    w = s.mask()
    t = np.linspace(0, 1, 50)
    pts = np.stack((ax + np.sin(t * 8.5) * (0.8 + 2.6 * t) + 5 * t, ay - 2 - 30 * t), axis=1)
    w.stroke(pts, 0.8, 1.7)
    fade = np.clip((s.Y / SS - (ay - 32)) / 24, 0, 1)
    s.rgb += (gauss(w.array(), 0.25 * SS) * fade * 0.55)[..., None] * s.colour("#dfe4ea")


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
    house(m, 540, 138, 112, 26, tank=True)
    house(m, 792, 139, 106, 27)
    m.rect(0, 134, 1040, 148)
    s.paint(m, "#0d0f26", rim=0.2)
    # the left cottage has done its windows in foil, and the right one's still got someone up with the lamp on
    foil_window(s, 556, 119.5, 16, 12, seed=3)
    foil_window(s, 611, 119.5, 16, 12, seed=4)
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
    pole = bez((659, 148), (659, 92), (661, 74), (676, 72), n=20)
    m.stroke(pole, 2.1, 1.1)
    m.rrect(670, 70, 684, 73.6, 1)
    m.spoly([(0, 141), (240, 140), (520, 142), (800, 140), (1040, 141), (1040, 148), (0, 148)])
    s.paint(m, "#04050e", rim=0.34, rim_dx=-0.9, rim_dy=-0.8, rim_colour="#ffd9a0")
    s.glow(722, 142, 34, colour="#ffd9a0", strength=0.10)
    # the Commodore, parked for good and lit like it's in a showroom: door panels rusted through, roof sagged
    m = s.mask()
    wreck(m, 722, 141.5, 110, facing=1)
    # proper stack of bricks under the back axle, wide enough to read as bricks and not a stalk
    m.rect(680, 137.2, 698, 141.5)
    m.rect(683, 133.6, 695, 137.2)
    for hole in ([(694, 120), (703, 119), (705, 125), (697, 127)],):
        m.spoly(hole, fill=0)
    m.spoly([(692, 104), (714, 104), (710, 107.2), (698, 107.4)], fill=0)
    charred(s, m)
    lit_rim(s, m, 676, 74, 70, "#ffd9a0", 0.6)
    # a thread of smoke still coming off it, days later
    w = s.mask()
    w.stroke(bez((746, 118), (740, 104), (756, 96), (748, 76), n=30), 1.0, 3.0)
    fade = np.clip((s.Y / SS - 72) / 46, 0, 1)
    s.rgb += (gauss(w.array(), 0.8 * SS) * fade * 0.32)[..., None] * s.colour("#dfd7d0")
    # the only other soul on the street: a bit of the lamp's spill so you can see him, and him
    s.glow(650, 132, 24, colour="#ffd9a0", strength=0.10)
    sitter(s, 640, 141.5)
    # big dark gums framing the scene, and giving the title something dark to sit on
    m = s.mask()
    gum_tree(m, 1012, 170, 178, seed=7, lean=-0.1, spread=1.1)
    gum_tree(m, 236, 176, 170, seed=12, lean=0.06)
    s.paint(m, "#03040a")
    return s.finish()
