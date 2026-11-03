"""Resident file: your own front gate at dusk. The letterbox has given up, the final notices are all
over the lawn, the bloke on the couch won't be answering it, and the dog's the only one here who answers
to anybody. It's what you'd expect."""
import numpy as np

from scenekit import SS, STENCIL, Scene, bez, foil_window, glass_pipe, gum_tree, lettering, light_windows

# Home has the orange end of the evening; your place gets the bruise that comes after it.
BRUISE = {"sky": [(0.00, "#070814"), (0.34, "#12122e"), (0.56, "#2a1f4c"), (0.72, "#552f66"),
                  (0.84, "#8f3f6e"), (0.93, "#c95a6c"), (1.00, "#ee8a72")],
          "far": "#3a2c5c", "mid": "#1e1a3e", "near": "#0a0a18", "rim": "#f08a7a", "haze": "#b05a78"}


def envelope(s, cx, cy, w, h, angle=0.0, stamp=True, tone="#ece0ca"):
    """A window-faced bill on the skew, with the red stamp that means they've stopped asking nicely."""
    ca, sa = np.cos(np.radians(angle)), np.sin(np.radians(angle))

    def P(u, v):  # u, v from the envelope's centre
        return (cx + u * ca - v * sa, cy + u * sa + v * ca)

    m = s.mask()
    m.spoly([P(-w / 2, -h / 2), P(w / 2, -h / 2), P(w / 2, h / 2), P(-w / 2, h / 2)])
    s.paint(m, tone, rim=0.2, rim_dx=0.4, rim_dy=-0.4, rim_colour="#ffd9b0")
    if stamp:
        r = s.mask()
        r.spoly([P(w * 0.2, -h * 0.40), P(w * 0.44, -h * 0.40), P(w * 0.44, -h * 0.08), P(w * 0.2, -h * 0.08)])
        s.paint(r, "#d52a22")


def rotated(cx, cy, pts, angle):
    """Points turned about (cx, cy), for anything hanging off a single screw."""
    ca, sa = np.cos(np.radians(angle)), np.sin(np.radians(angle))
    return [(cx + (px - cx) * ca - (py - cy) * sa, cy + (px - cx) * sa + (py - cy) * ca) for px, py in pts]


def letterbox(s, cx, y, w, h, base):
    """Sheet-steel letterbox on a bit of old fence post, front on with its right side showing: a lid, a
    slot up top with the backlog jammed through it like toast, and the door below hanging by the one
    screw. (cx, y) is the middle of the front face at the top; base is where the post goes in the dirt."""
    x0, x1 = cx - w / 2, cx + w / 2
    dep = w * 0.24  # how much of the side we see
    rise = 2.6
    # the post, a touch off plumb, with a pale edge so it isn't a bar of nothing
    m = s.mask()
    m.spoly([(cx - 3.2, y + h - 1), (cx + 3.6, y + h - 1), (cx + 4.4, base), (cx - 2.8, base)])
    s.paint(m, "#2a2238", rim=0.9, rim_dx=1.0, rim_dy=0, rim_colour="#ffa58a")
    # side of the box, in shade, then the back of the mail behind the front
    m = s.mask()
    m.spoly([(x1, y), (x1 + dep, y - rise), (x1 + dep, y + h - rise), (x1, y + h)])
    s.paint(m, "#17132b", rim=0.8, rim_dx=0.9, rim_dy=0, rim_colour="#ffb09a")
    front = s.mask()
    front.rect(x0, y, x1, y + h)
    s.paint(front, "#3a3052", rim=0.3, rim_dx=-0.6, rim_dy=0, rim_colour="#ffb09a")
    # the lid: a shallow steel hood with a bit of overhang
    m = s.mask()
    m.spoly([(x0 - 2.2, y + 0.6), (x0 + 1, y - 3.6), (x1 + dep + 0.6, y - 3.6 - rise), (x1 + dep + 2.0, y + 0.4 - rise), (x1 + 2.2, y + 0.6)])
    s.paint(m, "#120f24", rim=0.85, rim_dx=0, rim_dy=-0.8, rim_colour="#ffb09a")
    # the slot
    slot_top, slot_bot = y + 3.2, y + 8.0
    m = s.mask()
    m.rect(x0 + 3, slot_top, x1 - 3, slot_bot)
    s.paint(m, "#04030a")

    # the backlog, wedged through the slot, fanned out, worst of it in front
    for ex, ey, ew, eh, ang in ((cx + 15, y - 1.5, 22, 13, 17), (cx + 9, y - 7, 24, 14, 8), (cx - 16, y - 1, 20, 12, -24)):
        envelope(s, ex, ey, ew, eh, ang)
    envelope(s, cx - 5, y - 9, 46, 28, -8, stamp=False)
    m = s.mask()
    lettering(m, "FINAL", cx - 6, y - 15, 8.8, font=STENCIL, angle=-8)
    lettering(m, "NOTICE", cx - 4.4, y - 4.5, 8.8, font=STENCIL, angle=-8)
    s.paint(m, "#d52a22")

    # the front again from the slot down, so the mail goes in rather than sitting on top
    m = s.mask()
    m.rect(x0, slot_bot, x1, y + h)
    s.paint(m, "#3a3052", rim=0.3, rim_dx=-0.6, rim_dy=0, rim_colour="#ffb09a")
    m = s.mask()
    m.rect(x0, slot_bot - 1.0, x1, slot_bot + 0.2)
    s.paint(m, "#5a4c72")

    # the hole where the door was, full, and the door hanging off its top left corner
    hx0, hx1, hy0, hy1 = x0 + 3.5, x1 - 3.5, slot_bot + 2.6, y + h - 2.6
    m = s.mask()
    m.rect(hx0, hy0, hx1, hy1)
    s.paint(m, "#04030a")
    for ey, shade in ((hy1 - 1.8, "#a89a84"), (hy1 - 4.8, "#ece0ca"), (hy1 - 7.8, "#c9bca4"), (hy1 - 10.8, "#ece0ca")):
        m = s.mask()
        m.rect(hx0 + 1.0, ey - 1.2, hx1 - 1.0, ey + 1.2)
        s.paint(m, shade)
    door = rotated(hx0 + 1.2, hy0 + 1.2, [(hx0, hy0), (hx1, hy0), (hx1, hy1), (hx0, hy1)], 11)
    m = s.mask()
    m.spoly(door)
    s.paint(m, "#2a2240", rim=0.75, rim_dx=0.4, rim_dy=-0.7, rim_colour="#ffb09a")
    # the screw, and the lock that was never the problem
    m = s.mask()
    m.ellipse(hx0 + 1.2, hy0 + 1.2, 0.8, 0.8)
    lx, ly = rotated(hx0 + 1.2, hy0 + 1.2, [(hx1 - 3.4, (hy0 + hy1) / 2)], 11)[0]
    m.ellipse(lx, ly, 1.1, 1.1)
    s.paint(m, "#c9c2cc")


def on_the_nod(s, x0, x1, b):
    """Whoever the bills were for, out cold along the couch: head tipped back over the arm with his face to
    the sky, gut up, one knee cocked with the foot on the far arm, the other leg slid off the front, and one
    arm hanging dead to the boards with the pipe gone out of the fingers. Solid black, so he reads against
    the lit window and the faded couch."""
    m = s.mask()
    # the gut, the highest thing on him
    top = bez((x0 + 8, b - 19.5), (x0 + 17, b - 24.5), (x0 + 29, b - 25.5), (x0 + 38, b - 18.5), n=16).tolist()
    m.spoly(top + [(x0 + 37.5, b - 11.2), (x0 + 9, b - 12.2)])
    # the neck going over the arm, and the head hanging back off it, nose and chin up
    head = (x0 + 1.5, b - 20.5)
    m.stroke(np.array([(x0 + 10, b - 18), (head[0] + 2.5, head[1] + 0.8)]), 6.0, 3.6)
    m.ellipse(head[0], head[1], 4.5, 4.0)
    m.spoly([(head[0] - 2.4, head[1] - 3.2), (head[0] - 1.2, head[1] - 5.6), (head[0] + 0.2, head[1] - 3.8)])  # nose
    m.ellipse(head[0] + 3.4, head[1] - 3.0, 1.9, 1.6)  # chin, mouth hanging open between
    # far leg: knee up, foot on the far arm
    hip = (x0 + 35, b - 17)
    knee = (x0 + 45.5, b - 29)
    ankle = (x0 + 51, b - 18.5)
    m.stroke(np.array([hip, knee]), 7.0, 4.6)
    m.ellipse(knee[0], knee[1], 2.4, 2.4)
    m.stroke(np.array([knee, ankle]), 4.6, 2.9)
    m.spoly([(ankle[0] - 1.6, ankle[1] - 1.4), (ankle[0] + 1.8, ankle[1] - 1.2), (ankle[0] + 6.6, ankle[1] + 1.6), (ankle[0] + 6.4, ankle[1] + 3.0), (ankle[0] - 1.4, ankle[1] + 2.8)])
    # near leg: slid off the front of the seat, heel on the boards
    hip2 = (x0 + 34, b - 13.5)
    knee2 = (x0 + 44, b - 12)
    ankle2 = (x0 + 44.6, b - 2.4)
    m.stroke(np.array([hip2, knee2]), 7.0, 4.8)
    m.ellipse(knee2[0], knee2[1], 2.4, 2.4)
    m.stroke(np.array([knee2, ankle2]), 4.6, 2.9)
    m.spoly([(ankle2[0] - 1.6, ankle2[1] - 1.0), (ankle2[0] + 1.6, ankle2[1] - 1.0), (ankle2[0] + 6.6, ankle2[1] + 1.2), (ankle2[0] + 6.6, ankle2[1] + 2.4), (ankle2[0] - 1.8, ankle2[1] + 2.4)])
    # the arm, dead weight, shoulder to knuckles
    sh = (x0 + 13.5, b - 16)
    el = (x0 + 14.5, b - 8.6)
    wr = (x0 + 13.5, b - 3.4)
    m.stroke(np.array([sh, el]), 4.4, 3.5)
    m.ellipse(el[0], el[1], 1.8, 1.8)
    m.stroke(np.array([el, wr]), 3.5, 2.5)
    m.ellipse(wr[0], wr[1] + 0.5, 2.0, 2.0)
    s.paint(m, "#050410", rim=0.55, rim_dx=0, rim_dy=-0.7, rim_colour="#ffcf8a")
    glass_pipe(s, wr[0] + 1.2, wr[1] + 1.4, 18, angle=-3, bulb=2.6, width=1.3, smoke=0, lit="#f0f8ff")


def cottage(s, x, base, w, h):
    """Close-up of a fibro cottage: big roof, veranda on posts. One room with the lamp on, one done in foil.
    The couch and the veranda boards go on later, over the lawn."""
    rise = h * 0.6
    m = s.mask()
    m.rect(x, base - h, x + w, base)
    s.paint(m, "#262542", bottom="#17162c", top_y=base - h - 30)
    # weatherboards, barely there
    c = s.mask()
    for yy in np.arange(base - h + 3, base, 3.2):
        c.line([(x, yy), (x + w, yy)], 0.32)
    s.paint(c, "#1a1933")
    roof = s.mask()
    over = w * 0.045
    roof.spoly([(x - over, base - h + 0.5), (x + w * 0.2, base - h - rise), (x + w * 0.82, base - h - rise), (x + w + over, base - h + 0.5)])
    cx = x + w * 0.70
    roof.rect(cx, base - h - rise - 8, cx + 6.5, base - h - rise + 3)
    roof.rect(cx - 0.8, base - h - rise - 9, cx + 7.3, base - h - rise - 7.5)
    s.paint(roof, "#10102a", rim=0.5, rim_dx=-0.6, rim_dy=-0.8, rim_colour="#f08a7a")

    # door and foil sit left of centre: the right-hand end of the place is under the page buttons
    door = (x + w * 0.38, base - h * 0.8, w * 0.085, h * 0.8)
    light_windows(s, [(x + w * 0.03, base - h * 0.72, w * 0.31, h * 0.44)], strength=0.8)
    foil_window(s, x + w * 0.50, base - h * 0.72, w * 0.21, h * 0.44, seed=6)
    d = s.mask()
    d.rect(door[0] - 1, door[1] - 1, door[0] + door[2] + 1, base)
    s.paint(d, "#0c0b1c", rim=0.22, rim_dx=-0.3, rim_dy=-0.4, rim_colour="#ffcf8a")

    # veranda roof and posts, dark against the lit window; the post that would go through the couch has gone
    v = s.mask()
    vy = base - h * 0.94
    v.spoly([(x - w * 0.06, vy + 2.4), (x + w * 1.06, vy + 2.4), (x + w * 0.98, vy - 3), (x + w * 0.02, vy - 3)])
    for k in (0, 2, 3, 4, 5):
        px = x - w * 0.045 + k * (w * 1.09) / 5
        v.rect(px, vy, px + 1.3, base)
    s.paint(v, "#0d0c20", rim=0.32, rim_dx=-0.4, rim_dy=-0.8, rim_colour="#ffa58a")


def veranda_front(s, x, w, b):
    """The boards, the couch out the front where the good chair used to be, and the man himself."""
    d = s.mask()
    d.rect(x - w * 0.06, b - 4.5, x + w * 1.06, b + 1.4)
    s.paint(d, "#191630", rim=0.5, rim_dx=0, rim_dy=-0.6, rim_colour="#ffb890")
    x0, x1 = x + w * 0.03, x + w * 0.365
    # feet, then the back, then the seat, then the arms
    c = s.mask()
    c.rect(x0 + 2, b - 3.4, x0 + 4.4, b)
    c.rect(x1 - 4.4, b - 3.4, x1 - 2, b)
    s.paint(c, "#0a0914")
    c = s.mask()
    c.rrect(x0 + 1, b - 18.5, x1 - 1, b - 8, 2.6)
    s.paint(c, "#54466c", rim=0.65, rim_dx=0, rim_dy=-0.8, rim_colour="#ffcf8a")
    c = s.mask()
    c.rect(x0 + 2, b - 6.4, x1 - 2, b - 3.2)
    s.paint(c, "#2a2340")
    n = 3
    cw = (x1 - x0 - 12) / n
    for k in range(n):
        sag = 0.9 if k == 1 else 0.0  # the middle one's had it
        c = s.mask()
        c.rrect(x0 + 6 + k * cw + 0.35, b - 11.6 + sag, x0 + 6 + (k + 1) * cw - 0.35, b - 5.2, 1.3)
        s.paint(c, "#6d5e82", rim=0.3, rim_dx=0, rim_dy=-0.6, rim_colour="#ffcf8a")
    c = s.mask()
    c.rrect(x0 - 3, b - 15.6, x0 + 6, b - 3.2, 3.2)
    c.rrect(x1 - 6, b - 15.6, x1 + 3, b - 3.2, 3.2)
    s.paint(c, "#4c3f64", rim=0.65, rim_dx=0, rim_dy=-0.8, rim_colour="#ffcf8a")
    on_the_nod(s, x0, x1, b)


def old_dog(s, x, base, facing=1):
    """What the sign's on about: a rack of ribs on four knobbly legs, head hung lower than his back, tail
    tucked, grey in the muzzle. About 22 tall at the shoulder, with (x, base) on the ground under his middle."""
    f = facing

    def P(u, v):
        # everything over the elbows is lifted, which stretches the legs: all shank, nothing on them
        return (x + u * f, base - (v * 1.42 if v < 10 else v + 4.2))

    far = s.mask()

    def leg(m, top, knee, low, paw, w0):
        m.stroke(np.array([P(*top), P(*knee)]), w0, w0 * 0.42)
        m.ellipse(*P(*knee), w0 * 0.27, w0 * 0.27)
        m.stroke(np.array([P(*knee), P(*low)]), w0 * 0.42, w0 * 0.34)
        m.ellipse(*P(*low), w0 * 0.24, w0 * 0.24)
        m.stroke(np.array([P(*low), P(*paw)]), w0 * 0.34, w0 * 0.3)
        px, py = P(*paw)
        m.spoly([(px - 1.2 * f, py - 1.4), (px + 1.3 * f, py - 1.4), (px + 3.1 * f, py + 0.1), (px + 3.1 * f, py + 0.4), (px - 1.3 * f, py + 0.4)])

    leg(far, (13, 15), (13.5, 10), (14.5, 5), (14.5, 0.4), 4.8)
    leg(far, (-9, 18), (-3.5, 11.5), (-11, 6), (-8.5, 0.4), 6.2)
    s.paint(far, "#3f3438")

    # the frame: spine sagging between bony shoulders and a hip you could hang a coat on; chest deep, gut gone
    top = bez((-19.5, 18), (-17, 20.5), (-15, 22.8), (-12.5, 22.6), n=8).tolist()
    top += bez((-12.5, 22.6), (-6, 20.2), (3, 20), (10.5, 22.4), n=12).tolist()
    top += bez((10.5, 22.4), (13, 22.4), (15, 21.6), (19, 19.6), n=8).tolist()
    low = [(21, 15.4), (15, 13.2)]
    low += bez((15, 13.2), (11, 9.6), (6, 10.2), (0, 13.2), n=10).tolist()
    low += bez((0, 13.2), (-5, 15.4), (-8, 16.2), (-12, 15), n=8).tolist()
    low += [(-18, 15)]
    body = s.mask()
    body.spoly([P(*p) for p in top + low])
    # the head hung forward and down: long skull, long thin snout
    body.ellipse(*P(22.5, 16.8), 4.1, 3.6)
    body.spoly([P(23.5, 19.6), P(31.2, 13.8), P(31.4, 11.6), P(29.4, 11.1), P(21.5, 13.4)])
    # tail clamped down behind him
    body.stroke(np.array([P(*q) for q in bez((-18.5, 17.5), (-22.5, 13.5), (-22.2, 8), (-18.8, 5), n=10)]), 2.2, 0.9)
    leg(body, (-13, 19), (-7.5, 12), (-15, 6.2), (-12.5, 0.4), 6.8)
    leg(body, (10, 15), (9.5, 10.2), (10.3, 5), (10.3, 0.4), 5.0)
    s.paint(body, "#8a7468", rim=0.85, rim_dx=0.1, rim_dy=-0.8, rim_colour="#ffd8b8")

    # the ribs, which are the joke: dark gaps following the barrel round
    r = s.mask()
    for k, rx in enumerate((8.0, 5.3, 2.6, -0.1, -2.8)):
        low_y = 11.6 + k * 0.72
        r.stroke(np.array([P(*q) for q in bez((rx + 1.6, 18.6), (rx - 1.0, 17), (rx - 1.2, low_y + 2.5), (rx + 1.0, low_y), n=9)]), 0.85, 0.7)
    # the hollow behind the hip, and the one in front of the shoulder
    r.stroke(np.array([P(*q) for q in bez((-9.5, 20.4), (-11, 18.4), (-9, 16.8), n=7)]), 1.0, 0.7)
    s.paint(r, "#4e3f3a")
    # grey muzzle, floppy ear, collar
    m = s.mask()
    m.spoly([P(27, 15.9), P(31.2, 13.8), P(31.4, 11.6), P(29.4, 11.1), P(26.4, 12.0)])
    s.paint(m, "#d0c6bc")
    m = s.mask()
    m.ellipse(*P(30.8, 12.9), 0.9, 0.9)
    s.paint(m, "#0a0810")
    m = s.mask()
    m.stroke(np.array([P(*q) for q in bez((21.5, 20), (19, 18.8), (18.8, 15), (19.8, 12.6), n=9)]), 3.2, 2.0)
    s.paint(m, "#3d302f")
    m = s.mask()
    m.stroke(np.array([P(18.0, 20.9), P(16.4, 14.2)]), 1.5, 1.5)
    s.paint(m, "#d52a22")
    return P(16.6, 15.2)  # where the chain clips on


def chain(s, pts):
    """Links, not a line: alternating flat and edge-on, spaced along the curve."""
    d = np.linalg.norm(np.diff(pts, axis=0), axis=1)
    run = np.concatenate(([0], np.cumsum(d)))
    m = s.mask()
    for k, t in enumerate(np.arange(0.6, run[-1], 1.75)):
        px, py = np.interp(t, run, pts[:, 0]), np.interp(t, run, pts[:, 1])
        if k % 2:
            m.ellipse(px, py, 0.95, 0.55)
        else:
            m.ellipse(px, py, 0.6, 0.6)
    s.paint(m, "#aaa6b6")


def paint():
    s = Scene(BRUISE, seed=33)
    s.sky(clouds=0.5, stars=0.9, glow_x=0.70, glow_w=0.24)
    s.moon(704, 32, 18, tint="#f6efdc", glow=0.55, seed=3)
    s.moon(654, 19, 8.5, tint="#a9c6ff", glow=0.5, seed=9)
    s.ridge(103, 20, 61, "#3a2c5c", roughness=4)
    s.fog(86, 112, strength=0.30)

    # the street going away behind: far roofs and a gum or two
    m = s.mask()
    for i, x in enumerate((318, 396, 470, 545, 650, 880, 945)):
        gum_tree(m, x, 122, 38 + (i * 23) % 22, seed=90 + i, leaves=0.9)
    m.rect(0, 118, 1040, 148)
    s.paint(m, "#1e1a3e", rim=0.12)
    s.fog(100, 122, strength=0.2, seed=8)

    cottage(s, 690, 133, 168, 40)

    # front lawn and the footpath: pale concrete slabs catching the sky
    m = s.mask()
    m.spoly(bez((0, 130), (300, 131), (700, 131), (1040, 130), n=20).tolist() + [(1040, 148), (0, 148)])
    s.paint(m, "#0b0d1e", rim=0.14, rim_dx=0, rim_dy=-0.8)
    path = s.mask()
    path.spoly([(0, 137.2), (1040, 137.2), (1040, 148), (0, 148)])
    a = path.array()
    xs = s.X / SS
    pool = np.exp(-((xs - 720) / 300.0) ** 2)
    col = s.colour("#191930")[None, None, :] + pool[..., None] * s.colour("#2c2436")[None, None, :]
    s.rgb = s.rgb * (1 - a[..., None]) + col * a[..., None]
    j = s.mask()
    for x in range(250, 1040, 62):
        j.line([(x, 137.2), (x - 6, 148)], 0.5)
    j.rect(0, 137.0, 1040, 137.6)
    s.paint(j, "#08091a")

    # grass tufts by the post
    t = s.mask()
    rng = np.random.default_rng(5)
    for x in np.concatenate((rng.uniform(575, 630, 40), rng.uniform(530, 1040, 60))):
        y = 137.4
        t.stroke(bez((x, y + 0.6), (x, y - 1.6), (x + rng.uniform(-2, 2), y - rng.uniform(2, 5.2)), n=6), 0.8, 0.2)
    s.paint(t, "#07081a")

    veranda_front(s, 690, 168, 134)

    letterbox(s, 598, 86, 44, 30, 138)

    # what's already come out of it, all over the verge
    for cx, cy, w, h, ang in ((571, 139.5, 18, 10, 12), (626, 141, 18, 10, -7), (647, 139, 15, 8.5, 9), (549, 141, 15, 8.5, -14)):
        envelope(s, cx, cy, w, h, ang)

    # the sign on the fence, low enough to clear the page buttons, and the reason for it
    m = s.mask()
    m.rect(940, 139, 943, 146)
    m.rect(979, 139, 982, 146)
    s.paint(m, "#0a0918", rim=0.3, rim_dx=-0.5, rim_dy=-0.4)
    m = s.mask()
    m.rect(930, 119.5, 992, 141)
    s.paint(m, "#e4d6a4", bottom="#a89668", top_y=90, rim=0.2)
    m = s.mask()
    lettering(m, "BEWARE OF", 961, 125.5, 8.6, font=STENCIL)
    lettering(m, "THE DOG", 961, 135.5, 8.6, font=STENCIL)
    s.paint(m, "#1a1420")
    # the dog, looking at his own sign, and the chain, collar to sign, which is mostly for show
    clip = old_dog(s, 892, 144.5)
    chain(s, bez(clip, (clip[0] + 3, 141), (923, 145), (931, 136), n=40))

    # dark gums framing the picture, and giving the title something dark to sit on
    m = s.mask()
    gum_tree(m, 236, 176, 170, seed=44, lean=0.06)
    gum_tree(m, 1020, 176, 160, seed=46, lean=-0.1, spread=1.05)
    s.paint(m, "#03040a")
    return s.finish()
