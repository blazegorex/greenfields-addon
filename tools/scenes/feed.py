"""Neighbourhood Watch: 2am, and the street's got its best seat out. The police chopper has found a
bloke halfway over the back fence with someone's telly under his arm, and the one lit window has a
telescope trained on him. Someone's been through the Watch sign already, with a gun and a can."""
import cv2
import numpy as np

from scenekit import SS, Scene, bez, gauss, gum_tree, house

MAN_X, FENCE_Y = 778, 104   # where he's got to: on the capping rail, right of the house
SIGN_TOP, SIGN_BOTTOM = "#a97a0c", "#865d07"   # the page's own road sign, as it looks under the page's light
TAG = "#6b0620"
TAG_EDGE = "#120306"


def lit_edges(s, a, lx, ly, reach, colour, strength):
    """Rim light on the edges of a silhouette that face a lamp at (lx, ly), fading with distance."""
    b = gauss(a, 0.5 * SS)
    gy, gx = np.gradient(b)
    dx, dy = lx * SS - s.X, ly * SS - s.Y
    d = np.maximum(1.0, np.sqrt(dx * dx + dy * dy))
    facing = np.clip(-(gx * dx + gy * dy) / d, 0, None) * (0.5 * SS * 2.5)
    fall = np.exp(-(d / (reach * SS)) ** 2)
    s.rgb += (facing * fall * a * strength)[..., None] * s.colour(colour)


def cat(m, x, base, h):
    """Sitting cat, seen side on, looking left; the tail hangs over the fence."""
    # back and chest, as one pear
    body = bez((x - h * 0.17, base), (x - h * 0.30, base - h * 0.32), (x - h * 0.14, base - h * 0.70), n=16).tolist()
    body += bez((x - h * 0.14, base - h * 0.70), (x + h * 0.14, base - h * 0.74), (x + h * 0.29, base - h * 0.28), (x + h * 0.24, base), n=20).tolist()
    m.spoly(body)
    hx, hy = x - h * 0.13, base - h * 0.80
    m.ellipse(hx, hy, h * 0.155, h * 0.135)
    # ears: the shape everyone knows
    m.spoly([(hx - h * 0.15, hy - h * 0.03), (hx - h * 0.14, hy - h * 0.25), (hx - h * 0.02, hy - h * 0.12)])
    m.spoly([(hx + h * 0.02, hy - h * 0.12), (hx + h * 0.13, hy - h * 0.25), (hx + h * 0.15, hy - h * 0.03)])
    tail = bez((x + h * 0.20, base - h * 0.05), (x + h * 0.48, base - h * 0.02), (x + h * 0.44, base + h * 0.42), (x + h * 0.56, base + h * 0.62), n=18)
    m.stroke(tail, h * 0.075, h * 0.05)


def window_scene(s, x, y, w, h):
    """The lit window: warm room, curtains drawn back at the middle, a nosy head between them, nose
    pointed at the fence like everything else in this house."""
    wall = s.mask()
    wall.rect(x, y, x + w, y + h)
    a = wall.array()[..., None]
    room = s.tone("#ffc873", "#ff9d4a", np.clip((s.Y / SS - y) / h, 0, 1)[..., None])
    s.rgb = s.rgb * (1 - a) + room * 1.08 * a
    # the sticky-beak in profile, nose first, hair in a bun: no doubt who this is
    p = s.mask()
    cx = x + w * 0.46
    head_r = h * 0.20
    hy = y + h * 0.46
    p.ellipse(cx, hy, head_r * 0.95, head_r)
    p.spoly([(cx + head_r * 0.80, hy - head_r * 0.35), (cx + head_r * 1.32, hy + head_r * 0.20), (cx + head_r * 0.70, hy + head_r * 0.42)])
    p.ellipse(cx - head_r * 0.72, hy - head_r * 0.98, head_r * 0.42, head_r * 0.42)
    p.spoly(bez((cx + head_r * 1.3, y + h), (cx + head_r * 1.1, hy + head_r * 1.1), (cx + head_r * 0.2, hy + head_r * 0.8), n=10).tolist()
            + bez((cx - head_r * 0.5, hy + head_r * 0.8), (cx - head_r * 2.0, hy + head_r * 1.1), (cx - head_r * 2.3, y + h), n=10).tolist())
    # curtains: two heavy drapes gathered back, leaving a lens of light
    c = s.mask()
    left = bez((x + w * 0.26, y), (x + w * 0.24, y + h * 0.42), (x + w * 0.10, y + h * 0.62), (x + w * 0.14, y + h), n=20)
    c.spoly([(x, y)] + left.tolist() + [(x, y + h)])
    right = bez((x + w * 0.58, y), (x + w * 0.60, y + h * 0.42), (x + w * 0.82, y + h * 0.62), (x + w * 0.80, y + h), n=20)
    c.spoly([(x + w, y)] + right.tolist() + [(x + w, y + h)])
    s.paint(p, "#2a1409")
    ca = c.array()
    s.rgb = s.rgb * (1 - ca[..., None]) + s.colour("#6e2f20") * ca[..., None]
    # pleats, so they read as cloth rather than two dark wedges
    fold = np.sin((s.X / SS - x) * 1.7) * 0.5 + 0.5
    s.rgb -= (ca * fold * 0.14)[..., None] * s.colour("#ffffff")
    # frame
    f = s.mask()
    f.rect(x - 1.6, y - 1.6, x + w + 1.6, y)
    f.rect(x - 1.6, y + h, x + w + 1.6, y + h + 2.0)
    f.rect(x - 1.6, y, x, y + h)
    f.rect(x + w, y, x + w + 1.6, y + h)
    s.paint(f, "#050812")
    light = np.clip(wall.array() * 1.0, 0, 1)
    col = s.colour("#ffb45e")
    s.rgb += gauss(light, 4 * SS)[..., None] * col * 0.22
    s.rgb += gauss(light, 15 * SS)[..., None] * col * 0.34


def telescope(m, x, base, h, aim):
    """On a tripod, the fat objective end trained on (aim) rather than up at the stars."""
    top = np.array((x, base - h))
    for dx in (-h * 0.30, h * 0.04, h * 0.32):
        m.line([tuple(top), (x + dx, base)], max(0.7, h * 0.05))
    d = np.array(aim, float) - top
    d /= np.linalg.norm(d)
    # tube tapers from the fat objective end back to the eyepiece
    a, b = top - d * h * 0.62, top + d * h * 0.72
    m.stroke(np.array([a + (b - a) * t for t in np.linspace(0, 1, 8)]), h * 0.10, h * 0.20)
    m.line([tuple(a - d * h * 0.16), tuple(a)], h * 0.06)


def spray_dogs(m, x, y, h, lean=-0.07):
    """DOGS in a spray can's block capitals, drawn stroke by stroke because every handwriting font
    turned the D into a p. Centred on (x, y), h tall, leaning up to the right, with a couple of runs."""
    w = h * 0.60        # a letter's width
    gap = h * 0.17
    pen = h * 0.21
    x0 = x - (4 * w + 3 * gap) / 2

    def P(i, u, v):
        lx = x0 + i * (w + gap) + u * w
        return (lx, y + (v - 0.5) * h + (lx - x) * lean)

    def pull(*pts):
        m.stroke(np.array(pts), pen, pen * 0.92)

    # D: a straight back, a fat bowl, and it closes
    pull(P(0, 0.08, -0.04), P(0, 0.08, 1.04))
    m.stroke(bez(P(0, 0.02, 0.02), P(0, 1.22, 0.0), P(0, 1.22, 1.0), P(0, 0.02, 0.98), n=24), pen, pen)
    # O
    m.stroke(bez(P(1, 0.5, 0.0), P(1, 1.16, 0.02), P(1, 1.16, 0.98), P(1, 0.5, 1.0), n=20), pen, pen)
    m.stroke(bez(P(1, 0.5, 1.0), P(1, -0.16, 0.98), P(1, -0.16, 0.02), P(1, 0.5, 0.0), n=20), pen, pen)
    # G: the O with a gate cut in it and a bar going back in
    m.stroke(bez(P(2, 0.96, 0.16), P(2, 0.60, -0.08), P(2, -0.14, -0.04), P(2, -0.02, 0.5), n=20), pen, pen)
    m.stroke(bez(P(2, -0.02, 0.5), P(2, 0.06, 1.08), P(2, 0.84, 1.10), P(2, 0.94, 0.56), n=20), pen, pen)
    pull(P(2, 0.48, 0.54), P(2, 1.02, 0.54))
    # S
    m.stroke(bez(P(3, 0.96, 0.14), P(3, 0.62, -0.08), P(3, 0.02, -0.04), P(3, 0.06, 0.24), n=16), pen, pen)
    m.stroke(bez(P(3, 0.06, 0.24), P(3, 0.10, 0.52), P(3, 0.94, 0.46), P(3, 0.94, 0.74), n=16), pen, pen)
    m.stroke(bez(P(3, 0.94, 0.74), P(3, 0.96, 1.06), P(3, 0.30, 1.10), P(3, 0.02, 0.86), n=16), pen, pen)
    # the runs, off the bottom of the D and the G
    for i, u, run in ((0, 0.10, 0.34), (2, 0.56, 0.22)):
        m.stroke(np.array([P(i, u, 1.0), P(i, u, 1.0 + run)]), pen * 0.34, pen * 0.22)


def watch_sign(s, x, y, w, h, base):
    """A Neighbourhood Watch sign, same yellow and same black eye as the one bolted up on the page below
    it. It's copped a few rounds, and someone with a can has put in their opinion of people who watch."""
    tilt = -0.035       # on the lean, from whoever backed into it

    def Q(px, py):
        return (px, py + (px - x) * tilt)

    def slab(x0, y0, x1, y1, c=1.2):
        return [Q(x0 + c, y0), Q(x1 - c, y0), Q(x1, y0 + c), Q(x1, y1 - c), Q(x1 - c, y1), Q(x0 + c, y1), Q(x0, y1 - c), Q(x0, y0 + c)]

    x0, x1 = x - w / 2, x + w / 2
    y1 = y + h
    m = s.mask()
    m.stroke(np.array([(x, base), (x, y + h * 0.5)]), 2.4, 2.2)
    s.paint(m, "#04060e", rim=0.14, rim_dx=-0.7, rim_dy=0)
    panel = s.mask()
    panel.spoly(slab(x0, y, x1, y1))
    a = panel.array()
    t = np.clip((s.Y / SS - y) / h, 0, 1)[..., None]
    col = s.tone(SIGN_TOP, SIGN_BOTTOM, t)
    s.rgb = s.rgb * (1 - a[..., None]) + col * a[..., None]

    # the black line round the edge and the eye, drawn the way the real one's drawn
    k = s.mask()
    k.spoly(slab(x0 + 1.5, y + 1.5, x1 - 1.5, y1 - 1.5))
    k.spoly(slab(x0 + 2.9, y + 2.9, x1 - 2.9, y1 - 2.9), fill=0)
    ex, ey = x0 + 14.5, y + h * 0.5
    ew, eh = 8.8, 7.8
    outer = bez((ex - ew, ey), (ex - ew * 0.3, ey - eh * 1.2), (ex + ew * 0.3, ey - eh * 1.2), (ex + ew, ey), n=20).tolist()
    outer += bez((ex + ew, ey), (ex + ew * 0.3, ey + eh * 1.2), (ex - ew * 0.3, ey + eh * 1.2), (ex - ew, ey), n=20).tolist()
    k.spoly([Q(*q) for q in outer])
    iw, ih = ew - 2.6, eh - 2.2
    inner = bez((ex - iw, ey), (ex - iw * 0.3, ey - ih * 1.2), (ex + iw * 0.3, ey - ih * 1.2), (ex + iw, ey), n=20).tolist()
    inner += bez((ex + iw, ey), (ex + iw * 0.3, ey + ih * 1.2), (ex - iw * 0.3, ey + ih * 1.2), (ex - iw, ey), n=20).tolist()
    k.spoly([Q(*q) for q in inner], fill=0)
    k.ellipse(*Q(ex, ey), 3.7, 3.7)
    k.ellipse(*Q(ex + 1.4, ey - 1.4), 0.9, 0.9, fill=0)
    s.paint(k, "#0a0a08")

    # the holes: wherever he happened to be pointing, none of it near a corner on purpose
    holes = ((-0.20, -0.33, 1.4), (0.13, -0.32, 1.7), (0.27, -0.33, 1.1), (0.04, 0.33, 1.2), (0.36, 0.30, 1.4))
    r = s.mask()
    for u, v, rad in holes:
        r.ellipse(*Q(x + u * w, y + h * 0.5 + v * h), rad + 0.7, rad + 0.7)
    s.paint(r, "#efe7cf")
    d = s.mask()
    for u, v, rad in holes:
        d.ellipse(*Q(x + u * w, y + h * 0.5 + v * h), rad, rad)
    s.paint(d, "#050a18")

    # the opinion, over the top of all of it
    t = s.mask()
    spray_dogs(t, x + 13, y + h * 0.5, 12)
    # a thin dark edge, where the can's gone over the yellow, so the red holds on it
    ta = t.array()
    e = cv2.dilate(ta, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (5, 5)))
    s.rgb = s.rgb * (1 - e[..., None]) + s.colour(TAG_EDGE) * e[..., None]
    s.paint(t, TAG)


def chopper(s, x, y, k):
    """Police helicopter, side on, nose to the right and down a bit because it's found what it wants.
    Returns where the searchlight hangs off the belly."""
    def P(u, v):
        return (x + u * k, y + v * k)

    m = s.mask()
    # pod, boom, fin: nothing else in the sky has this outline
    pod = bez(P(-13, -7), P(-2, -11), P(13, -9), P(21, 1), n=14).tolist()
    pod += bez(P(21, 1), P(19, 8), P(6, 11), P(-9, 7), n=12).tolist()
    pod += [P(-15, 2)]
    m.spoly(pod)
    m.spoly([P(-13, -5), P(-49, -3), P(-49, 0), P(-13, 3)])
    m.spoly([P(-47, -2), P(-54, -13), P(-50.5, -13), P(-42, -2)])
    m.spoly([P(-47, -1), P(-54, 4), P(-50, 4), P(-43, 0)])
    # mast and skids
    m.rect(*P(-1.3, -14), *P(1.3, -9))
    m.line([P(-16, 15.5), P(16, 15.5), P(20, 13)], 1.5 * k)
    m.line([P(-8, 8), P(-10, 15.5)], 1.0 * k)
    m.line([P(8, 9), P(10, 15.5)], 1.0 * k)
    s.paint(m, "#04070f", rim=0.5, rim_dx=0.3, rim_dy=-0.8, rim_colour="#9dbfd8")
    # the rotor, a long smear, and the tail rotor as a little disc
    b = s.mask()
    b.ellipse(*P(0, -14.5), 44 * k, 1.5 * k)
    b.ellipse(*P(-52, -5), 6.5 * k, 6.5 * k)
    a = b.array()
    s.rgb = s.rgb * (1 - a[..., None] * 0.55) + s.colour("#7e97ab") * (a * 0.2)[..., None]
    # cabin glass, faint
    g = s.mask()
    g.spoly(bez(P(4, -6), P(11, -6), P(18, 1), n=8).tolist() + [P(5, 1)])
    s.paint(g, "#1f3650")
    # a red strobe under the tail and a blue on the nose, the only colours it has
    for u, v, c in ((-30, 2.2, "#ff4040"), (14, 9.6, "#5aa0ff")):
        s.glow(*P(u, v), 3.2 * k, colour=c, strength=0.8)
    return P(7, 11)


def bone(m, pts, widths):
    """An arm or a leg as one outline, tapering, with a corner at the bend. A sleeve folds at the elbow;
    it doesn't have a ball in it."""
    pts = [np.array(p, float) for p in pts]
    left, right = [], []
    for i, (p, w) in enumerate(zip(pts, widths)):
        d0 = pts[i] - pts[i - 1] if i else pts[1] - pts[0]
        d1 = pts[i + 1] - pts[i] if i < len(pts) - 1 else d0
        n0 = np.array([-d0[1], d0[0]]) / max(1e-6, np.linalg.norm(d0))
        n1 = np.array([-d1[1], d1[0]]) / max(1e-6, np.linalg.norm(d1))
        mit = n0 + n1
        mit /= max(1e-6, np.linalg.norm(mit))
        off = mit * (w / 2) / max(0.72, float(mit @ n0))
        left.append(tuple(p + off))
        right.append(tuple(p - off))
    m.spoly(left + right[::-1])


def thief(s, x, y, k, lamp):
    """The bloke on the fence: arse on the capping rail, near leg dangling down our side looking for
    the ground, back foot still planted on the rail behind him. Telly carried under his right arm on the
    forearm, hood turned back to the chopper and the other hand up at it, palm out: not me, officer.
    Dark hoodie, lit only down the side facing the light. Sits on (x, y)."""
    def P(u, v):
        return (x + u * k, y - v * k)

    def arm(mask, pts, widths):
        bone(mask, [P(*q) for q in pts], [w * k for w in widths])

    # up and to the left, where the light is
    rim = dict(rim=0.8, rim_dx=-1.05, rim_dy=-0.6, rim_colour="#e4f2ff")
    m = s.mask()
    # the back leg: knee up, runner planted on the capping rail, the weight still on it
    arm(m, [(-4, 7), (-19, 18), (-22.5, 4)], [9.5, 6.0, 4.0])
    m.spoly([P(-25.2, 5), P(-20.6, 5), P(-16.2, 2.4), P(-15.6, 1.0), P(-25.6, 1.0)])
    # the near leg, hanging over our side of the fence
    arm(m, [(4, 7), (12.5, -10), (8, -25)], [9.5, 6.0, 4.0])
    m.spoly([P(5.8, -24), P(10, -24), P(16, -27), P(16.6, -30), P(5.6, -30)])
    # the free arm, up at the light
    arm(m, [(-7, 31), (-20, 26), (-23, 41.5)], [6.4, 4.6, 3.4])
    # and the hand: a flat palm, four fingers near enough together, thumb out. Not me, officer
    m.spoly([P(-26.1, 41), P(-21.1, 41), P(-20.5, 46.6), P(-26.7, 46.6)])
    for b0, b1 in ((-26.0, (-27.6, 51.2)), (-24.3, (-25.0, 52.6)), (-22.6, (-22.4, 52.6)), (-21.0, (-19.9, 51.0))):
        m.stroke(np.array([P(b0, 46), P(*b1)]), 1.4 * k, 1.1 * k)
    m.stroke(np.array([P(-21, 42.4), P(-17.4, 46.2)]), 1.6 * k, 1.1 * k)
    # the body in its jumper, sat square on the rail, shoulders dropping away from the neck
    body = bez(P(-10, 1), P(-12, 14), P(-12.5, 26), P(-9.5, 32.5), n=12).tolist()
    body += [P(-3.5, 35.5), P(5.5, 35.5)]
    body += bez(P(5.5, 35.5), P(11, 34.5), P(13.5, 28), P(12.5, 18), n=10).tolist()
    body += [P(11, 1)]
    m.spoly(body)
    # the hood, narrower than the shoulders so there's a notch either side of the neck, the front of it
    # hanging out past where his face is and a bit of a point at the back
    hood = bez(P(-3.5, 35), P(-7.2, 38), P(-8.6, 44), P(-8.6, 49.5), n=10).tolist()
    hood += bez(P(-8.6, 49.5), P(-7.4, 54), P(-1, 56.8), P(4.5, 56.6), n=10).tolist()
    hood += [P(9.8, 56.2)]
    hood += bez(P(9.8, 56.2), P(11, 50), P(10.4, 42), P(5.5, 35), n=10).tolist()
    m.spoly(hood)
    s.paint(m, "#0f1827", bottom="#090f1b", top_y=y - 70, **rim)
    # the runners' pale soles: they're what says shoe at this size
    f = s.mask()
    f.spoly([P(-25.8, 1.4), P(-15.4, 1.4), P(-15.4, 0.1), P(-25.8, 0.1)])
    f.spoly([P(5.4, -30.2), P(16.8, -30.2), P(16.7, -28.8), P(5.4, -28.8)])
    s.paint(f, "#b9c6d2")
    # inside the hood: the far wall of it takes the light, and in front of that, where a face would be
    # if he had any intention of showing it, nothing
    f = s.mask()
    f.spoly(bez(P(-6.8, 51), P(0.5, 52.5), P(3.6, 44), P(-0.8, 37.2), n=12).tolist() + [P(-3.4, 38.2), P(-6.8, 45)])
    s.paint(f, "#50708f")
    f = s.mask()
    f.spoly(bez(P(-6.8, 50.6), P(-1.2, 51.6), P(1.6, 44), P(-2, 38), n=12).tolist() + [P(-3.8, 38.6), P(-6.8, 45)])
    s.paint(f, "#03060b")

    # the telly: a proper old tube one, rabbit ears still on it, jammed against his ribs
    tv = (10, 13, 35, 33)   # left, bottom, right, top
    w = s.mask()
    w.line([P(21, tv[3]), P(15, tv[3] + 11)], 0.9)
    w.line([P(23, tv[3]), P(32, tv[3] + 10)], 0.9)
    s.paint(w, "#d7e3ea")
    m = s.mask()
    m.rrect(P(tv[0], 0)[0], P(0, tv[3])[1], P(tv[2], 0)[0], P(0, tv[1])[1], 2.2 * k)
    s.paint(m, "#8d8f8c", bottom="#55595c", top_y=y - 80, rim=0.55, rim_dx=-0.6, rim_dy=-0.7, rim_colour="#ffffff")
    # the screen, curved and blank, taking the searchlight across one corner
    g = s.mask()
    g.rrect(P(tv[0] + 5, 0)[0], P(0, tv[3] - 2.6)[1], P(tv[2] - 6.5, 0)[0], P(0, tv[1] + 2.6)[1], 2.8 * k)
    s.paint(g, "#0c1520", bottom="#16263a", top_y=y - 60)
    l = s.mask()
    l.spoly([P(tv[0] + 7, tv[3] - 4.4), P(tv[0] + 13, tv[3] - 4.4), P(tv[0] + 7, tv[3] - 11)])
    s.paint(l, "#a9c6dc")
    # two knobs
    n = s.mask()
    for v in (tv[3] - 4.5, tv[3] - 9.5):
        n.ellipse(*P(tv[2] - 3.2, v), 1.3 * k, 1.3 * k)
    s.paint(n, "#17202a")

    # his arm: down his ribs in the same dark as the rest of him, a hard bend at the elbow, the forearm
    # taking the set's weight along underneath, the hand under the far corner and three fat fingers curled
    # up over the front of it
    m = s.mask()
    arm(m, [(7, 24), (7, 9), (29, 10.6)], [5.6, 5.6, 4.4])
    m.spoly([P(28.5, 8.2), P(34.6, 7.9), P(36.8, 10.4), P(36.8, 13.6), P(28.5, 13.0)])
    for fx, top in ((35.4, 18), (32.9, 18), (30.4, 17)):
        m.stroke(np.array([P(fx, 11.5), P(fx, top)]), 2.0 * k, 1.8 * k)
    s.paint(m, "#0d1625")


def searchlight(s, x, y, tx, ty, spread, reach, colour, strength, soft):
    """A hard cone from (x, y) through (tx, ty) that stops where it lands, rather than the kit's beam,
    which fades away and carries on across the whole street."""
    ang = np.arctan2(ty - y, tx - x)
    dx, dy = s.X - x * SS, s.Y - y * SS
    along = dx * np.cos(ang) + dy * np.sin(ang)
    across = -dx * np.sin(ang) + dy * np.cos(ang)
    width = np.maximum(1.0, along) * np.tan(np.radians(spread))
    dist = np.hypot(tx - x, ty - y) * SS
    cone = (1 - np.clip((np.abs(across) / width - 0.8) / 0.2, 0, 1)) * (along > 0)
    cone = cone * (1 - np.clip((along - dist * 0.95) / (dist * reach), 0, 1))
    s.rgb += gauss(cone.astype(np.float32), soft * SS)[..., None] * s.colour(colour) * strength


def paint():
    s = Scene("night", seed=17, horizon=114)
    s.sky(clouds=0.34, stars=1.15, glow_x=0.62, glow_w=0.20)
    s.moon(600, 40, 25, tint="#f6efdc", glow=0.5, seed=3)
    s.moon(540, 22, 8.5, tint="#a9c6ff", glow=0.5, seed=9)
    s.ridge(106, 18, 41, "#1a3350", roughness=4)
    s.fog(92, 118, strength=0.30)
    # the neighbours, all asleep, or saying they are
    m = s.mask()
    for i, x in enumerate((262, 330, 410, 470, 945, 990)):
        gum_tree(m, x, 124, 40 + (i * 41) % 26, seed=70 + i, leaves=0.9)
    house(m, 330, 134, 120, 24, veranda=False, antenna=True)
    m.rect(0, 124, 1040, 148)
    s.paint(m, "#0d1d33", rim=0.10)
    s.fog(106, 130, strength=0.14, seed=9)

    # the house with the light on
    m = s.mask()
    house(m, 536, 138, 172, 44, veranda=False, antenna=True, chimney=True)
    # a deep eave along the front, drawn here so the window stays clear
    m.spoly([(526, 106), (718, 106), (708, 98), (536, 98)])
    m.rect(0, 136, 1040, 148)
    s.paint(m, "#0a1426", bottom="#060c1a", top_y=70, rim=0.26, rim_colour="#a3cfe0")
    # a dark window for rhythm; only one person on this street admits to being awake
    d = s.mask()
    d.rect(558, 110, 588, 130)
    s.paint(d, "#040811")
    window_scene(s, 620, 108, 42, 26)

    # Colorbond: ribbed panels with posts and a capping rail, caught by the moon along the top
    fx0, fy = 720, FENCE_Y
    m = s.mask()
    m.rect(fx0, fy, 1040, 148)
    s.paint(m, "#101d33", bottom="#070d1b", top_y=fy - 8, rim=0.6, rim_dx=0, rim_dy=-0.7, rim_colour="#b9d6e6")
    ribs = (np.sin((s.X / SS) * 2 * np.pi / 7.0) > 0.35).astype(np.float32)
    body = m.array() * smooth_down(s.Y / SS, fy + 1.5)
    s.rgb += gauss(ribs * body, 0.25 * SS)[..., None] * s.colour("#7f9fb8") * 0.075
    m = s.mask()
    for px in range(int(fx0) + 30, 1040, 98):
        m.rect(px, fy - 1.0, px + 3, 148)
    m.rect(fx0, fy - 1.0, fx0 + 3, 148)
    s.paint(m, "#060c18", rim=0.22, rim_dx=-0.6, rim_dy=-0.6, rim_colour="#b9d6e6")

    # the chopper and its light: a hard edge, because it's meant to hurt
    lamp = chopper(s, 700, 27, 0.92)
    target = (MAN_X + 2, FENCE_Y - 26)
    searchlight(s, lamp[0], lamp[1], target[0], target[1], 17.5, 0.75, "#dcecfb", 0.6, 0.45)
    s.glow(lamp[0], lamp[1], 4.5, colour="#ffffff", strength=1.3)
    # where it lands on the fence, soft-edged, so it's light and not a cut-out
    pool = s.mask()
    pool.ellipse(target[0] + 2, FENCE_Y + 15, 40, 22)
    pa = gauss(pool.array(), 4.0 * SS) * smooth_down(s.Y / SS, FENCE_Y)
    s.rgb += pa[..., None] * s.colour("#cfe6f8") * 0.2

    # the telescope, caught by the window light and aimed at the show
    m = s.mask()
    telescope(m, 688, 137, 19, target)
    a = m.array()
    s.paint(m, "#04070f")
    lit_edges(s, a, 641, 120, 60, "#ffb868", 1.5)

    thief(s, MAN_X, FENCE_Y - 0.5, 1.0, lamp)

    # the cat, a few palings along with its back to the lot of it: it's seen this one
    m = s.mask()
    cat(m, 731, FENCE_Y - 0.6, 20)
    s.paint(m, "#02040a")

    # the road, then the big gums that frame it all. Two small eyes in the right one, for later.
    m = s.mask()
    m.spoly([(0, 142), (300, 141), (620, 143), (1040, 142), (1040, 148), (0, 148)])
    s.paint(m, "#02040a")
    m = s.mask()
    gum_tree(m, 1046, 172, 180, seed=23, lean=-0.14, spread=1.05)
    gum_tree(m, 232, 176, 166, seed=12, lean=0.08)
    s.paint(m, "#02040b")
    # the sign goes on after the gum, so no branch runs through the tag
    watch_sign(s, 862, 52, 76, 35, 142)
    eyes = s.mask()
    for ex in (1006.6, 1011.4):
        eyes.ellipse(ex, 74.5, 1.05, 0.65)
    ea = eyes.array()
    s.rgb += ea[..., None] * s.colour("#9dffe6") * 1.6
    s.rgb += gauss(ea, 1.6 * SS)[..., None] * s.colour("#6df0d0") * 0.9
    return s.finish(vignette=0.22)


def smooth_down(y, y0):
    return np.clip((y - y0) / 1.0, 0, 1)
