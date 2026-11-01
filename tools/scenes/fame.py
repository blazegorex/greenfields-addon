"""Hall of Fame: the town's hero in the park, up on a plinth under two spotlights, holding a glass
pipe to the heavens like it's a holy sword. There's a cone on his head and someone's tagged the plinth,
which is about as close as this suburb comes to a blue plaque."""
import numpy as np

from scenekit import SCRAWL, SS, Scene, bez, gauss, glass_pipe, gum_tree, lettering, pine

STONE_LIT = "#d4bf98"
STONE_MID = "#5d6673"
STONE_DARK = "#1a2230"


class Carver:
    """Paints the statue part by part, each with a soft bevel lit from the two lamps below and a
    little contact shadow on what's behind it, so it reads as carved stone rather than cut paper."""

    def __init__(self, s, cx, by, k):
        self.s, self.cx, self.by, self.k = s, cx, by, k
        self.done = np.zeros((s.h, s.w), np.float32)

    def f(self, x, y):
        return (self.cx + x * self.k, self.by - y * self.k)

    def fs(self, pts):
        return [self.f(*p) for p in pts]

    def part(self, draw, sigma=1.3, ambient=0.2, gain=1.0, light=STONE_LIT, dark=STONE_DARK):
        s = self.s
        m = s.mask()
        draw(m)
        a = m.array()
        h = gauss(a, sigma * SS)
        gy, gx = np.gradient(h)
        norm = sigma * SS * 2.5
        # two lamps low on either side, and a whisper of moon from up top so the head doesn't die
        l = np.zeros_like(a)
        for lx, ly, w in ((-0.8, 0.6, 0.72), (0.8, 0.6, 0.34), (0.0, -1.0, 0.16)):
            l += np.clip(-(gx * lx + gy * ly) * norm, 0, 1) * w
        v = np.clip(ambient + l * gain, 0, 1)[..., None]
        lit, drk = s.colour(light), s.colour(dark)
        mid = s.colour(STONE_MID)
        col = np.where(v < 0.45, drk + (mid - drk) * (v / 0.45), mid + (lit - mid) * ((v - 0.45) / 0.55))
        # contact shadow, only where it lands on stone already carved
        ao = (gauss(a, 1.3 * SS) * (1 - a) * self.done * 0.55)[..., None]
        s.rgb = s.rgb * (1 - ao)
        s.rgb = s.rgb * (1 - a[..., None]) + col * a[..., None]
        self.done = np.maximum(self.done, a)


def statue(s, cx, by, k):
    c = Carver(s, cx, by, k)
    f, fs = c.f, c.fs

    def cape(m):
        pts = bez(f(-7, 50), f(-17, 38), f(-27, 20), f(-30, 3), n=16).tolist()
        pts += bez(f(-30, 3), f(-20, 7), f(-12, 2), f(-4, 8), n=12).tolist()
        pts += [f(6, 40), f(6, 50)]
        m.spoly(pts)
    c.part(cape, sigma=2.6, ambient=0.08)

    def legs(m):
        m.stroke(np.array(fs([(-5, 28), (-7, 16), (-10, 3)])), 10 * k, 7 * k)
        m.stroke(np.array(fs([(5, 28), (7, 16), (11, 3)])), 10 * k, 7 * k)
        for x0, x1 in ((-16, -5), (6, 17)):
            m.spoly(fs([(x0, 0), (x0 + 1.5, 4), (x1 - 2, 6), (x1, 0)]))
    c.part(legs, sigma=1.5)

    def knees(m):
        m.ellipse(*f(-7.5, 15), 3.6 * k, 3.4 * k)
        m.ellipse(*f(7.5, 15), 3.6 * k, 3.4 * k)
    c.part(knees, sigma=0.9)

    def skirt(m):
        m.spoly(fs([(-7, 34), (7, 34), (11, 20), (5, 17), (0, 20), (-5, 17), (-11, 20)]))
    c.part(skirt, sigma=1.3)

    def torso(m):
        pts = bez(f(-7, 32), f(-12, 39), f(-11, 49), f(-7, 53), n=10).tolist()
        pts += bez(f(7, 53), f(11, 49), f(12, 39), f(7, 32), n=10).tolist()
        m.spoly(pts)
    c.part(torso, sigma=2.4, gain=1.1)

    def belt(m):
        m.spoly(fs([(-7.5, 31), (7.5, 31), (8, 35), (-8, 35)]))
    c.part(belt, sigma=0.6, ambient=0.1)

    def left_arm(m):  # the off arm, its hand on the shield
        m.stroke(np.array(fs([(13, 49), (17, 39), (16, 30)])), 7 * k, 5.5 * k)
    c.part(left_arm, sigma=1.2)

    def shield(m):
        pts = [f(9, 31), f(25, 31)]
        pts += bez(f(25, 31), f(26, 18), f(21, 8), f(17, 2), n=10).tolist()
        pts += bez(f(17, 2), f(13, 8), f(8, 18), f(9, 31), n=10).tolist()
        m.spoly(pts)
    c.part(shield, sigma=2.0, gain=1.15)

    def boss(m):
        m.ellipse(*f(17, 20), 3.2 * k, 3.2 * k)
    c.part(boss, sigma=0.8)

    def raised_arm(m):
        m.stroke(np.array(fs([(-12, 50), (-21, 52), (-29, 58)])), 8 * k, 6 * k)
        m.ellipse(*f(-30, 59), 3.4 * k, 3.4 * k)
    c.part(raised_arm, sigma=1.2)

    def neck_and_helm(m):
        m.rect(f(-3, 0)[0], f(0, 58)[1], f(3, 0)[0], f(0, 51)[1])
        pts = bez(f(-5, 55), f(-6, 62), f(-3, 65), f(0, 65), n=8).tolist()
        pts += bez(f(0, 65), f(3, 65), f(6, 62), f(5, 55), n=8).tolist()
        pts += [f(2.5, 52), f(-2.5, 52)]
        m.spoly(pts)
    c.part(neck_and_helm, sigma=1.3, ambient=0.2)

    def pauldrons(m):
        for sx in (-1, 1):
            m.ellipse(*f(sx * 12, 51), 8 * k, 6.4 * k)
            # the spikes that make it Warcraft rather than Roman
            m.spoly(fs([(sx * 9, 55), (sx * 11, 63), (sx * 13, 56)]))
            m.spoly(fs([(sx * 14, 55), (sx * 19, 61), (sx * 18, 52)]))
    c.part(pauldrons, sigma=1.5, gain=1.15)
    return c


def cone(s, x, y, k, tilt=0.14):
    """Road cone, in its real colours: the one loud thing in the picture, and the joke."""
    def P(u, v):  # u across, v up from the base, leaning by tilt
        return (x + (u + v * tilt) * k, y - v * k)
    m = s.mask()
    m.spoly([P(-8.5, -1), P(8.5, -1), P(8.5, 1.1), P(-8.5, 1.1)])
    m.spoly([P(-6, 1), P(6, 1), P(1.5, 20), P(-1.5, 20)])
    s.paint(m, "#ff6a1c", rim=0.55, rim_dx=-0.6, rim_dy=0.5, rim_colour="#ffd29a")
    b = s.mask()
    b.spoly([P(-4.3, 7), P(4.3, 7), P(3.1, 12.5), P(-3.1, 12.5)])
    s.paint(b, "#f4efe4")
    s.glow(x, y - 9 * k, 11, colour="#ff7a2c", strength=0.12)


PIPE_LEN = 44


def relic_glory(s, cx, cy):
    """A hush of dark sky round the bulb, and soft rays coming off it, because it's a sacred relic."""
    d2 = ((s.X / SS - cx) ** 2 + (s.Y / SS - cy) ** 2) / (30.0 * 30.0)
    s.rgb *= (1 - 0.55 * np.exp(-d2))[..., None]
    for deg in range(0, 360, 45):
        if deg != 90:  # none straight down the stem
            s.beam(cx, cy, deg + 22.5, 3.0, 13, colour="#ffe9c0", strength=0.26, soft=0.45)


def wisp(s, pts, strength=0.8):
    """Smoke: one thin thread that fades as it goes, painted by hand so it stays in the frame."""
    pts = np.asarray(pts)
    w = s.mask()
    w.stroke(pts, 0.8, 1.1)
    a = gauss(w.array(), 0.16 * SS)
    fade = np.clip(1 - (pts[0][0] - s.X / SS) / abs(pts[-1][0] - pts[0][0]), 0, 1)
    s.rgb += (a * fade * strength)[..., None] * s.colour("#e6edf2")


def paint():
    s = Scene("night", seed=17)
    s.sky(clouds=0.4, stars=1.0, glow_x=0.60, glow_w=0.2)
    # both moons off to the side: the sky behind the pipe has to stay dark or the glass disappears
    s.moon(596, 28, 17, tint="#f6efdc", glow=0.4, seed=3)
    s.moon(552, 20, 7.5, tint="#a9c6ff", glow=0.4, seed=9)
    s.ridge(106, 18, 44, "#20405c", roughness=4)
    s.fog(90, 118, strength=0.28)

    # the far side of the park: foreshore pines and round gums
    m = s.mask()
    for x, h in ((530, 58), (560, 42), (850, 62), (905, 46)):
        pine(m, x, 126, h, seed=x)
    for i, x in enumerate((330, 402, 468, 590, 800, 965)):
        gum_tree(m, x, 126, 36 + (i * 37) % 20, seed=70 + i, leaves=0.9)
    m.rect(0, 122, 1040, 148)
    s.paint(m, "#10233c", rim=0.12)
    s.fog(106, 130, strength=0.22, seed=8)

    # the two spotlights, reaching up through the haze behind him
    for x, ang, st in ((628, -58, 0.30), (778, -120, 0.24)):
        s.beam(x, 139, ang, 8.0, 62, colour="#ffe2b4", strength=st, soft=1.6)
        s.glow(x, 139, 8, colour="#ffe2b4", strength=0.34)

    # lawn, with the pools of lamplight on it
    m = s.mask()
    pts = bez((0, 138), (300, 133), (620, 137), (760, 136), n=30).tolist()
    pts += bez((760, 136), (860, 136), (960, 137), (1040, 134), n=20).tolist()
    m.spoly(pts + [(1040, 148), (0, 148)])
    s.paint(m, "#070e1a", rim=0.16, rim_colour="#8fc6d4")
    s.glow(628, 141, 16, colour="#ffd9a0", strength=0.13)
    s.glow(778, 141, 16, colour="#ffd9a0", strength=0.11)

    # plinth: three steps and a die, carved like the man on it
    cx, top = 700, 117
    plinth = Carver(s, cx, 142, 1.0)
    plinth.part(lambda m: m.rect(cx - 46, 136, cx + 46, 142), sigma=1.0, gain=0.6)
    plinth.part(lambda m: m.rect(cx - 39, 131, cx + 39, 137), sigma=1.0, gain=0.6)
    plinth.part(lambda m: m.spoly([(cx - 28, 119), (cx + 28, 119), (cx + 31, 132), (cx - 31, 132)]), sigma=2.0, ambient=0.26, gain=0.7)
    plinth.part(lambda m: m.rrect(cx - 34, top, cx + 34, 121, 1), sigma=0.9, gain=0.7)
    # the blank bronze plaque: nobody could agree what to put on it
    plinth.part(lambda m: m.rect(cx - 12, 122.5, cx + 12, 129), sigma=0.6, ambient=0.1, light="#c7a163", dark="#2a2115")

    k = 1.0
    statue(s, cx, top, k)
    cone(s, cx - 0.3, top - 64 * k, 0.95)

    # the pipe, stem in his fist, raised to the heavens like the sword out of the stone
    hand_x, hand_y = cx - 30 * k, top - 59 * k
    bx, by = hand_x, hand_y + 8 - PIPE_LEN
    relic_glory(s, bx, by)
    glass_pipe(s, hand_x, hand_y + 8, PIPE_LEN, angle=-90, bulb=PIPE_LEN * 0.15, width=2.4, smoke=0, ember=0.4, seed=5)
    tip = by - PIPE_LEN * 0.15 + 1
    wisp(s, bez((bx, tip), (bx - 3, tip - 8), (bx - 13, tip - 2), (bx - 20, tip - 10), n=40))
    # his fist closes over the stem
    m = s.mask()
    m.ellipse(hand_x, hand_y, 3.3 * k, 3.1 * k)
    s.paint(m, "#7e7f80", rim=0.45, rim_dx=-0.6, rim_dy=0.5, rim_colour=STONE_LIT)

    # the plinth's been tagged in hot pink: it's the closest thing he'll get to an inscription
    m = s.mask()
    lettering(m, "LEGEND", cx, 126, 10.5, font=SCRAWL, angle=-3, wobble=0.5, seed=3, spacing=0.3)
    s.paint(m, "#ff4f93")
    s.glow(cx, 126, 18, colour="#ff4f93", strength=0.05)

    # lamp housings and a bench, so it's a park and not a plaza
    m = s.mask()
    for x, lean in ((628, 1), (778, -1)):
        m.spoly([(x - 4.5, 141), (x + 4.5, 141), (x + 4 + lean * 2, 134.5), (x - 4 + lean * 2, 137.5 - lean * 3)])
    m.rrect(885, 128.5, 925, 130.5, 0.7)
    m.rrect(885, 123.5, 925, 125.5, 0.7)
    for x in (889, 921):
        m.rect(x - 0.9, 123.5, x + 0.9, 141)
    s.paint(m, "#03060d", rim=0.3, rim_dx=-0.8, rim_dy=-0.7, rim_colour="#ffd9a0")

    # big dark gums framing it all, and giving the title something dark to sit on
    m = s.mask()
    gum_tree(m, 1016, 172, 176, seed=23, lean=-0.1, spread=1.1)
    gum_tree(m, 232, 176, 172, seed=12, lean=0.06)
    m.rect(0, 144, 1040, 148)
    s.paint(m, "#03040a")
    return s.finish()
