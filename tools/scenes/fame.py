"""Hall of Fame: the town's hero in the park, up on a plinth under two floodlights, holding a glass
pipe to the heavens like it's a holy sword. There's a cone on his head and someone's tagged the plinth,
which is about as close as this suburb comes to a blue plaque."""
import cv2
import numpy as np
from PIL import ImageFilter

from scenekit import SCRAWL, SS, Scene, bez, gauss, glass_pipe, gum_tree, lettering

# polished bronze under floodlights: dark metal, hard bright planes where the lamps catch it
BRONZE_DARK = "#17100c"
BRONZE = "#3d2b1e"
BRONZE_DEEP = "#271a12"
BRONZE_MID = "#8a6136"
BRONZE_LIT = "#c8904e"
BRONZE_HOT = "#f6d596"
MOONLIT = "#7f9fb4"


class Caster:
    """Paints the statue part by part in flat tones: a base, a hard band of lamp light on the edges facing
    the lamps down low, a thinner one for the weaker lamp, a thread of moon along the top, and a dark seam
    where it sits on the part behind. Hard edges all round, so the armour reads as planes."""

    def __init__(self, s, cx, by, k):
        self.s, self.cx, self.by, self.k = s, cx, by, k
        self.done = np.zeros((s.h, s.w), np.float32)

    def f(self, x, y):
        return (self.cx + x * self.k, self.by - y * self.k)

    def fs(self, pts):
        return [self.f(*p) for p in pts]

    def _band(self, a, dx, dy):
        return np.clip(a - np.roll(np.roll(a, int(round(dy * SS)), axis=0), int(round(dx * SS)), axis=1), 0, 1)

    def part(self, draw, base=BRONZE, lit=1.5, far=0.7, moon=0.55, litc=BRONZE_LIT, seam=0.5):
        s = self.s
        m = s.mask()
        draw(m)
        a = m.array()
        r = max(1, int(round(seam * SS)))
        grown = cv2.dilate(a, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (2 * r + 1, 2 * r + 1)))
        sm = np.clip(grown - a, 0, 1) * self.done
        s.rgb = s.rgb * (1 - sm[..., None]) + s.colour(BRONZE_DARK) * sm[..., None]
        s.rgb = s.rgb * (1 - a[..., None]) + s.colour(base) * a[..., None]
        if moon > 0:
            b = self._band(a, 0, moon)[..., None]
            s.rgb = s.rgb * (1 - b) + s.colour(MOONLIT) * b
        if far > 0:  # the weaker lamp, low on the right
            b = self._band(a, -far * 0.85, -far * 0.5)[..., None]
            s.rgb = s.rgb * (1 - b) + s.colour(BRONZE_LIT) * 0.62 * b
        if lit > 0:  # the main lamp, low on the left
            b = self._band(a, lit * 0.85, -lit * 0.5)[..., None]
            s.rgb = s.rgb * (1 - b) + s.colour(litc) * b
        self.done = np.maximum(self.done, a)

    def flat(self, draw, colour):
        """A plane or a line laid over what's there, no bands."""
        m = self.s.mask()
        draw(m)
        a = m.array()[..., None]
        self.s.rgb = self.s.rgb * (1 - a) + self.s.colour(colour) * a


def statue(s, cx, by, k):
    """One cast figure, not a kit of parts: legs, pelvis, torso, neck and the raised arm are a single
    silhouette, with the planes laid on it afterwards. Only the things that really are separate pieces in
    a bronze get a seam: helm, pauldrons, cape, shield arm, shield."""
    c = Caster(s, cx, by, k)
    f, fs = c.f, c.fs

    def groove(x0, y0, x1, y1, colour=BRONZE_DARK, w=0.8):
        c.flat(lambda m: m.stroke(np.array(fs([(x0, y0), (x1, y1)])), w * k, w * k), colour)

    def plane(pts, colour=BRONZE_MID):
        c.flat(lambda m: m.spoly(fs(pts)), colour)

    # ---- the cape: off both shoulders, behind him, swept out to the side and down onto the plinth
    def cape(m):
        pts = bez(f(5, 58), f(-6, 59.5), f(-13, 58), f(-16, 53), n=10).tolist()
        pts += bez(f(-16, 53), f(-23, 38), f(-27, 18), f(-34, 0), n=18).tolist()
        pts += [f(-15, 0), f(-14, 10), f(-10, 28), f(-7, 40), f(0, 50)]
        m.spoly(pts)
    c.part(cape, base=BRONZE_DEEP, lit=1.3, far=0, moon=0.4)
    for p0, p1, p2 in (((-15, 48), (-21, 28), (-29, 2)), ((-12, 40), (-16, 22), (-21, 2))):
        p = bez(f(*p0), f(*p1), f(*p2), n=14)
        c.flat(lambda m, p=p: m.stroke(p, 1.2 * k, 0.8 * k), BRONZE_LIT)
        c.flat(lambda m, p=p: m.stroke(p + np.array([1.1 * k, 0]), 1.1 * k, 1.0 * k), BRONZE_DARK)

    # ---- the shield arm goes in first: upper arm down, a hard bend, forearm level and in behind the shield
    def shield_arm(m):
        m.spoly(fs([(10.5, 49), (18, 53), (23, 44.5), (30, 45.5), (30, 39.5), (17, 37)]))
    c.part(shield_arm, lit=1.3, far=0.7)

    # ---- the body in one pour
    def body(m):
        # the leg he's stepped out on, knee bent, boot turned out
        m.spoly(fs([(-9, 39), (-11, 29), (-14.5, 20), (-17.3, 13), (-16.8, 6.4), (-24, 2.2), (-24.6, 0), (-13.3, 0),
                    (-13.6, 5.6), (-12.6, 12.5), (-10.6, 18.5), (-5.6, 27), (-0.3, 35)]))
        # the leg he's standing on, straight down
        m.spoly(fs([(0.3, 35), (2.8, 27), (3.9, 19), (3.5, 13), (4.4, 6), (3.6, 0), (14.4, 0), (14, 2.2), (8.6, 6.2),
                    (9.4, 13), (8.7, 19), (10, 29), (9.2, 39)]))
        # skirt of plates over the hips, then waist, chest, traps, and a neck narrower than the head
        m.spoly(fs([(-9.4, 39), (9.4, 39), (10.8, 33), (3.4, 30.6), (0, 32.8), (-3.4, 30.6), (-10.8, 33)]))
        pts = bez(f(-7, 38), f(-7.4, 43), f(-11, 47), f(-13, 54), n=10).tolist()
        pts += [f(-8.5, 57.4), f(-2.8, 59), f(-2.8, 63), f(2.8, 63), f(2.8, 59), f(8.5, 57.4)]
        pts += bez(f(13, 54), f(11, 47), f(7.4, 43), f(7, 38), n=10).tolist()
        m.spoly(pts)
        # the arm with the pipe: shoulder out and up, a hard bend, forearm dead straight to the sky
        m.spoly(fs([(-10.5, 58), (-21.8, 62.3), (-23.4, 70.5), (-28, 70.5), (-27, 57.6), (-20.5, 52.6), (-11, 46.5)]))
    c.part(body, lit=1.6, far=0.8)

    # the planes of the casting: lamp side bright, the rest left dark
    plane([(-9.4, 37), (-10.6, 29), (-13.9, 20.3), (-11.8, 19.2), (-7.8, 27), (-5.2, 33)])  # thigh
    plane([(-16.8, 13.4), (-16.6, 7), (-15.2, 6.8), (-14.4, 13)])  # shin
    plane([(3.6, 27), (4.6, 19.4), (5.9, 19.4), (6, 29), (4, 32)])  # standing thigh
    plane([(4, 13), (4.9, 6.8), (6.1, 6.8), (6, 13)])  # standing shin
    plane([(-21.7, 60.8), (-23.2, 69.8), (-26.2, 69.8), (-25.2, 58.6)])  # raised forearm
    plane([(-12, 49), (-20.4, 54.4), (-18.5, 57), (-12, 54)])  # raised upper arm
    groove(-23.4, 67, -28, 67, w=0.7)  # the cuff

    # the skirt's plates
    plane([(-9.2, 38), (-1, 38), (-1, 33), (-3.4, 31.4), (-10.3, 33.4)], "#6e4c2a")
    groove(0, 38.5, 0, 33)
    groove(-5.2, 38.5, -5.8, 32.4)
    groove(5.2, 38.5, 5.8, 32.4)

    # the breastplate's two faces meeting on a keel, bright side to the big lamp
    plane([(0, 40), (0, 56.5), (-8.5, 56.2), (-11, 50), (-8.2, 44.5), (-6.4, 40)])
    plane([(0, 40), (0, 56.5), (-3.8, 56.3), (-4.1, 50), (-2.8, 44.5), (-2, 40)], BRONZE_LIT)
    groove(0, 40, 0, 56.5, colour=BRONZE_HOT, w=0.7)
    # the plate's lower edge over the belly, and the belt
    c.flat(lambda m: m.stroke(bez(f(-8.6, 46), f(-4, 43.6), f(4, 43.6), f(8.6, 46), n=12), 0.8 * k, 0.8 * k), BRONZE_DARK)
    c.part(lambda m: m.spoly(fs([(-7.2, 37.2), (7.2, 37.2), (7.5, 40.6), (-7.5, 40.6)])), base=BRONZE_DARK, lit=0.8, far=0.5, moon=0.4)
    c.part(lambda m: m.rrect(*f(-2.4, 41.2), *f(2.4, 36.6), 0.5), lit=0.8, far=0.7, litc=BRONZE_HOT, moon=0)

    # ---- the helm: wider than the neck, a dome, cheek plates, a visor slit
    def helm(m):
        pts = bez(f(-3.4, 60.2), f(-5.8, 62), f(-6, 69.8), f(0, 70), n=10).tolist()
        pts += bez(f(0, 70), f(6, 69.8), f(5.8, 62), f(3.4, 60.2), n=10).tolist()
        m.spoly(pts)
    c.part(helm, lit=1.2, far=0.8, moon=0)
    c.flat(lambda m: m.rect(*f(-5.1, 65.6), *f(5.1, 64.1)), BRONZE_DARK)
    groove(0, 60.6, 0, 64.1, colour=BRONZE_HOT, w=0.7)

    # ---- pauldrons: one big swept plate on each shoulder, its top edge flaring up to a blunt peak
    def pauldron(sx):
        def draw(m):
            pts = bez(f(sx * 6.5, 57.4), f(sx * 10, 59.4), f(sx * 14, 59.8), f(sx * 17.5, 59.6), n=10).tolist()
            pts += bez(f(sx * 17.5, 59.6), f(sx * 19.6, 55.5), f(sx * 19, 51), f(sx * 16.5, 48.4), n=10).tolist()
            pts += bez(f(sx * 16.5, 48.4), f(sx * 13.5, 50.4), f(sx * 10, 52), f(sx * 6.5, 57.4), n=8).tolist()
            m.spoly(pts)
        return draw
    for sx in (-1, 1):
        c.part(pauldron(sx), lit=1.3, far=0.8)
        c.flat(lambda m, sx=sx: m.stroke(bez(f(sx * 9, 54.6), f(sx * 12.5, 55.4), f(sx * 15.5, 55.2), f(sx * 18.8, 54.2), n=10), 0.8 * k, 0.8 * k), BRONZE_DARK)

    # ---- the shield, strapped on that forearm: elbow out one side of it, fist out the other
    def shield(m):
        pts = [f(22, 49.5), f(37, 49.5)]
        pts += bez(f(37, 49.5), f(38, 36), f(34, 26), f(29.5, 18), n=12).tolist()
        pts += bez(f(29.5, 18), f(25, 26), f(21, 36), f(22, 49.5), n=12).tolist()
        m.spoly(pts)
    c.part(shield, base=BRONZE_LIT, lit=0, far=0, moon=0.5, seam=0.7)

    def shield_face(m):
        pts = [f(23.7, 48), f(35.3, 48)]
        pts += bez(f(35.3, 48), f(36.1, 36), f(32.5, 27), f(29.5, 21.6), n=12).tolist()
        pts += bez(f(29.5, 21.6), f(26.5, 27), f(22.9, 36), f(23.7, 48), n=12).tolist()
        m.spoly(pts)
    c.part(shield_face, base=BRONZE_DEEP, lit=0, far=0, moon=0, seam=0.3)
    c.flat(lambda m: m.spoly(bez(f(29.5, 21.6), f(26.5, 27), f(22.9, 36), f(23.7, 48), n=12).tolist() + [f(29.5, 48)]), "#6e4c2a")
    c.flat(lambda m: m.spoly(fs([(23.8, 42), (29.5, 34), (35.4, 42), (35.4, 38.2), (29.5, 30.2), (23.6, 38.2)])), BRONZE_LIT)
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


PIPE_LEN = 37


def relic_glory(s, cx, cy):
    """A hush of dark sky round the bulb and a few short rays off it, because it's a sacred relic."""
    d2 = ((s.X / SS - cx) ** 2 + (s.Y / SS - cy) ** 2) / (24.0 * 24.0)
    s.rgb *= (1 - 0.55 * np.exp(-d2))[..., None]
    for deg in range(0, 360, 45):
        if deg != 90:  # none straight down the stem
            s.beam(cx, cy, deg + 22.5, 2.6, 8, colour="#ffe9c0", strength=0.2, soft=0.4)


def wisp(s, pts, strength=0.8):
    """Smoke: one thin thread that fades as it goes, painted by hand so it stays in the frame."""
    pts = np.asarray(pts)
    w = s.mask()
    w.stroke(pts, 0.8, 1.1)
    a = gauss(w.array(), 0.16 * SS)
    fade = np.clip(1 - (pts[0][0] - s.X / SS) / abs(pts[-1][0] - pts[0][0]), 0, 1)
    s.rgb += (a * fade * strength)[..., None] * s.colour("#e6edf2")


def gauntlet(s, c, x, y, k):
    """His fist round the stem: a closed hand with knuckles on it, and the flared cuff under it."""
    m = s.mask()
    m.spoly([(x - 2.7 * k, y + 6.2 * k), (x + 3.0 * k, y + 6.2 * k), (x + 3.8 * k, y + 2.4 * k), (x - 3.6 * k, y + 2.4 * k)])
    m.rrect(x - 3.6 * k, y - 3.2 * k, x + 3.7 * k, y + 3 * k, 1.4 * k)
    a = m.array()
    s.rgb = s.rgb * (1 - a[..., None]) + s.colour(BRONZE) * a[..., None]
    b = np.clip(a - np.roll(np.roll(a, int(-0.6 * SS), axis=0), int(1.1 * SS), axis=1), 0, 1)[..., None]
    s.rgb = s.rgb * (1 - b) + s.colour(BRONZE_LIT) * b
    # the fingers wrapped round, and the cuff's edge
    ln = s.mask()
    for dy in (-1.3, 0.3, 1.9):
        ln.rect(x - 2.9 * k, y + (dy - 0.3) * k, x + 3.0 * k, y + (dy + 0.3) * k)
    ln.rect(x - 3.6 * k, y + 3 * k, x + 3.8 * k, y + 3.6 * k)
    la = ln.array()[..., None]
    s.rgb = s.rgb * (1 - la) + s.colour(BRONZE_DARK) * la


def step(s, x0, x1, y0, y1, face="#2a3340", lip=0.9):
    """One course of the plinth: a flat face, a lit top edge, the lamp-side end caught."""
    m = s.mask()
    m.rect(x0, y0, x1, y1)
    s.paint(m, face)
    t = s.mask()
    t.rect(x0, y0, x1, y0 + lip)
    s.paint(t, "#b9ad96")
    e = s.mask()
    e.rect(x0, y0 + lip, x0 + 1.4, y1)
    s.paint(e, "#6d6a68")
    b = s.mask()
    b.rect(x0, y1 - 0.8, x1, y1)
    s.paint(b, "#0d1119")


FLOOD = 1.35


def flood_frame(x, base, ang):
    a = np.radians(ang)
    d = np.array([np.cos(a), np.sin(a)])
    return d, np.array([-d[1], d[0]]), np.array([x, base - 6.5])


def floodlight(s, x, base, ang):
    """A park floodlight, bolted to a slab on the grass: a box on a stub, tipped up at him, lens blazing."""
    d, n, c = flood_frame(x, base, ang)

    def box(u0, u1, v0, v1):
        return [tuple(c + d * u * FLOOD + n * v * FLOOD) for u, v in ((u0, v0), (u1, v0), (u1, v1), (u0, v1))]

    m = s.mask()
    m.rect(x - 1.3, base - 6.5, x + 1.3, base)
    m.rect(x - 6, base - 1.6, x + 6, base)
    m.spoly(box(-4, 3.2, -3.6, 3.6))
    s.paint(m, "#04070e", rim=0.5, rim_dx=0, rim_dy=-0.6, rim_colour="#ffd9a0")
    g = s.mask()
    g.spoly(box(3.2, 4.4, -3.6, 3.6))
    a2 = g.array()[..., None]
    s.rgb = s.rgb * (1 - a2) + s.colour("#fff3d2") * 1.2 * a2


def flood_beam(s, x, base, ang, top, bot, strength):
    """The beam: a flat hard-edged wedge from the lens to the statue, stopping behind him. Laid down before
    the plinth and the bronze, so they cut it off and it's plain what it's pointed at."""
    d, n, c = flood_frame(x, base, ang)
    lens = c + d * 4.4 * FLOOD
    # which lens corner goes with which far corner depends on the side the lamp's on
    e0, e1 = lens + n * 3.6 * FLOOD, lens - n * 3.6 * FLOOD
    if e0[1] > e1[1]:
        e0, e1 = e1, e0
    m = s.mask()
    m.spoly([tuple(e0), top, bot, tuple(e1)])
    along = (s.X / SS - lens[0]) * d[0] + (s.Y / SS - lens[1]) * d[1]
    fall = 1 - 0.45 * np.clip(along / 85.0, 0, 1)
    s.rgb += (m.array() * fall * strength)[..., None] * s.colour("#ffe2b4")


def paint():
    s = Scene("night", seed=17)
    s.sky(clouds=0.4, stars=1.0, glow_x=0.60, glow_w=0.2)
    # both moons off to the side: the sky behind the pipe has to stay dark or the glass disappears
    s.moon(596, 28, 17, tint="#f6efdc", glow=0.4, seed=3)
    s.moon(552, 20, 7.5, tint="#a9c6ff", glow=0.4, seed=9)
    s.ridge(106, 18, 44, "#20405c", roughness=4)
    s.fog(90, 118, strength=0.28)

    # the far side of the park: round gums
    m = s.mask()
    for i, x in enumerate((330, 402, 468, 590, 800, 965)):
        gum_tree(m, x, 126, 36 + (i * 37) % 20, seed=70 + i, leaves=0.9)
    m.rect(0, 122, 1040, 148)
    s.paint(m, "#10233c", rim=0.12)
    s.fog(106, 130, strength=0.22, seed=8)

    # lawn, with the pools of lamplight on it
    m = s.mask()
    pts = bez((0, 138), (300, 133), (620, 137), (760, 136), n=30).tolist()
    pts += bez((760, 136), (860, 136), (960, 137), (1040, 134), n=20).tolist()
    m.spoly(pts + [(1040, 148), (0, 148)])
    s.paint(m, "#070e1a", rim=0.16, rim_colour="#8fc6d4")
    s.glow(632, 141, 14, colour="#ffd9a0", strength=0.10)
    s.glow(768, 141, 14, colour="#ffd9a0", strength=0.08)

    # two ground floodlights, both on him
    LAMPS = ((626, -38), (774, -142))
    flood_beam(s, 626, 141, -38, (700, 53), (700, 118), 0.13)
    flood_beam(s, 774, 141, -142, (700.25, 53), (700.25, 118), 0.10)

    # plinth: two steps, a tall die with room to write on, and a cap
    cx, top = 700, 117
    step(s, cx - 52, cx + 52, 138, 142, face="#222a35")
    step(s, cx - 45, cx + 45, 134, 138.2, face="#262e3a")
    step(s, cx - 37, cx + 37, 120.5, 134.2, face="#2e3845")
    step(s, cx - 41, cx + 41, top, 121, face="#39434f")
    # the blank bronze plaque: nobody could agree what to put on it
    m = s.mask()
    m.rect(cx - 13, 123.2, cx + 13, 131.8)
    s.paint(m, "#5a4427")
    m = s.mask()
    m.rect(cx - 12, 124.2, cx + 12, 130.8)
    s.paint(m, "#2c2114")

    k = 0.88
    c = statue(s, cx, top, k)
    cone(s, cx - 0.3, top - 69.6 * k, 0.9)

    # the pipe, stem in his fist, held up like a torch
    hand_x, hand_y = cx - 25.7 * k, top - 72.5 * k
    bx, by = hand_x, hand_y + 4 - PIPE_LEN
    relic_glory(s, bx, by)
    glass_pipe(s, hand_x, hand_y + 4, PIPE_LEN, angle=-90, bulb=PIPE_LEN * 0.14, width=2.2, smoke=0, ember=0.4, seed=5)
    tip = by - PIPE_LEN * 0.14 + 1
    wisp(s, bez((bx, tip), (bx - 3, tip - 5), (bx - 10, tip - 2), (bx - 16, tip - 8), n=40))
    # his fist closes over the stem
    gauntlet(s, c, hand_x, hand_y, k)

    # the plinth's been tagged in hot pink, all on the one face: the closest thing he'll get to an inscription
    m = s.mask()
    lettering(m, "LEGEND", cx, 126.6, 9.5, font=SCRAWL, angle=-2, wobble=0.16, seed=3, spacing=0.7)
    m.img = m.img.filter(ImageFilter.MaxFilter(5))  # the fat cap
    s.paint(m, "#ff4f93")

    # lamp housings and a bench, so it's a park and not a plaza
    for x, ang in LAMPS:
        floodlight(s, x, 141, ang)
    m = s.mask()
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
