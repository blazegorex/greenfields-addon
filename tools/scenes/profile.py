"""Resident file: your own front gate at dusk. The letterbox has given up, the final notices are all
over the lawn, the bloke on the couch won't be answering it, and the dog's the only one here who answers
to anybody. It's what you'd expect."""
import numpy as np

from scenekit import SS, STENCIL, Scene, bez, fbm, foil_window, gauss, glass_pipe, gum_tree, lettering, light_windows, lit_rim, staffy

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


def letterbox(s, x, y, w, h, base):
    """Tunnel letterbox on a post, side on, its door dropped open at the street end and its mouth full.
    (x, y) is the top-left of the box; it has a round top."""
    r = h * 0.5
    # post, with a little fall-off down its length
    m = s.mask()
    px = x + w * 0.52
    m.spoly([(px - 4, y + h - 1), (px + 4, y + h - 1), (px + 4.6, base + 3), (px - 4.6, base + 3)])
    s.paint(m, "#1b1730", rim=0.5, rim_dx=0.9, rim_dy=0, rim_colour="#ffa58a")
    # bracket under the box
    m = s.mask()
    m.spoly([(px - 15, y + h - 0.6), (px + 15, y + h - 0.6), (px + 4, y + h + 7), (px - 4, y + h + 7)])
    s.paint(m, "#14112a", rim=0.25, rim_dx=0.6, rim_dy=0.2, rim_colour="#ffa58a")
    # the barrel of the box: lit along its right and top from the house and the last of the sky
    m = s.mask()
    pts = [(x, y + h)]
    pts += bez((x, y + r), (x, y + r * 0.2), (x + r * 0.8, y), n=10).tolist()
    pts += bez((x + w - r * 0.8, y), (x + w, y + r * 0.2), (x + w, y + r), n=10).tolist()
    pts += [(x + w, y + h)]
    m.spoly(pts)
    a = m.array()
    s.paint(m, "#2a2545", bottom="#141128", top_y=y - 46, rim=0.75, rim_dx=0.9, rim_dy=-0.7, rim_colour="#ffb09a")
    # soft round-over on the barrel, a band of sheen along the crown
    ys = np.clip((s.Y / SS - y) / h, 0, 1)
    sheen = np.exp(-((ys - 0.2) / 0.16) ** 2) * a
    s.rgb += sheen[..., None] * s.colour("#d9708a") * 0.17

    # the mouth: seen a little from the street end, so there's somewhere for it all to come out of
    m = s.mask()
    mouth = [(x + 7, y + h)]
    mouth += bez((x + 7, y + h), (x - 9, y + h * 0.85), (x - 9, y + h * 0.1), (x + 7, y + 0.5), n=14).tolist()
    mouth += bez((x + 7, y + 0.5), (x + 11, y + h * 0.3), (x + 11, y + h * 0.7), (x + 7, y + h), n=10).tolist()
    m.spoly(mouth)
    s.paint(m, "#05040e")

    # the door, dropped on its hinge and hanging by the one screw
    m = s.mask()
    m.spoly([(x - 3, y + h - 1), (x + 10, y + h), (x + 13, y + h + 24), (x, y + h + 22)])
    s.paint(m, "#2a2545", rim=0.6, rim_dx=-0.7, rim_dy=-0.2, rim_colour="#ffb09a")


def on_the_nod(s, cx0, cx1, base):
    """Whoever it was the bills were for, out cold on the couch: gone over sideways along the seat, head
    lolled back on the arm, one knee up, and one arm hanging straight off the front with the pipe still in
    the hand. Solid black, so he reads against the lit window up top and the faded couch below."""
    head, shoulder, hip = (cx0 + 8.5, base - 15.5), (cx0 + 16, base - 14), (cx0 + 34, base - 13)
    knee, foot = (cx0 + 43, base - 21), (cx0 + 50.5, base - 14)
    hand = (cx0 + 14.5, base - 5.5)
    m = s.mask()
    # the body along the seat, gut up
    m.stroke(bez(shoulder, (shoulder[0] + 6, shoulder[1] - 2.5), (hip[0] - 6, hip[1] - 2.5), hip, n=14), 9.5, 9.0)
    # the knee up, and the foot over the far arm
    m.stroke(np.array([hip, knee]), 7.0, 4.8)
    m.stroke(np.array([knee, foot]), 4.6, 3.2)
    m.spoly([(foot[0] - 2, foot[1] - 2.2), (foot[0] + 1, foot[1] - 2.4), (foot[0] + 4.5, foot[1] + 0.2), (foot[0] + 4.5, foot[1] + 1.8), (foot[0] - 2, foot[1] + 1.8)])
    # the neck giving up, and the head hanging off it
    m.stroke(np.array([shoulder, head]), 4.6, 3.8)
    m.ellipse(head[0], head[1], 4.6, 4.3)
    # the arm, dead weight
    m.stroke(np.array([(shoulder[0] + 1.5, shoulder[1] + 2), hand]), 4.8, 3.2)
    m.ellipse(hand[0], hand[1] + 0.3, 2.3, 2.3)
    s.paint(m, "#050410")
    glass_pipe(s, hand[0] - 0.5, hand[1] + 0.3, 17, angle=180, bulb=2.5, width=1.3, smoke=0, lit="#f0f8ff")


def cottage(s, x, base, w, h):
    """Close-up of a fibro cottage: big roof, veranda on posts. One room with the lamp on, one
    done in foil, and the couch out the front where the good chair used to be."""
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
    light_windows(s, [(x + w * 0.08, base - h * 0.72, w * 0.25, h * 0.44)], strength=0.8)
    foil_window(s, x + w * 0.50, base - h * 0.72, w * 0.21, h * 0.44, seed=6)
    d = s.mask()
    d.rect(door[0] - 1, door[1] - 1, door[0] + door[2] + 1, base)
    s.paint(d, "#0c0b1c", rim=0.22, rim_dx=-0.3, rim_dy=-0.4, rim_colour="#ffcf8a")

    # veranda roof and posts, dark against the lit window
    v = s.mask()
    vy = base - h * 0.94
    v.spoly([(x - w * 0.06, vy + 2.4), (x + w * 1.06, vy + 2.4), (x + w * 0.98, vy - 3), (x + w * 0.02, vy - 3)])
    for k in range(6):
        px = x - w * 0.045 + k * (w * 1.09) / 5
        v.rect(px, vy, px + 1.3, base)
    s.paint(v, "#0d0c20", rim=0.32, rim_dx=-0.4, rim_dy=-0.8, rim_colour="#ffa58a")

    # the couch, under the lit window, seen better by the light behind it
    c = s.mask()
    cx0, cx1, cy = x + w * 0.05, x + w * 0.35, base
    c.rrect(cx0, cy - 15, cx1, cy - 4, 2.2)
    c.rect(cx0 + 1, cy - 3, cx0 + 3, cy)
    c.rect(cx1 - 3, cy - 3, cx1 - 1, cy)
    s.paint(c, "#3d3454", rim=0.5, rim_dx=0, rim_dy=-0.8, rim_colour="#ffcf8a")
    c = s.mask()  # the seat, then fat arms either end, so it's a couch and not a box
    c.rect(cx0 + 3, cy - 8.5, cx1 - 3, cy - 8)
    s.paint(c, "#1e1a30")
    c = s.mask()
    c.rrect(cx0 - 3, cy - 12, cx0 + 5, cy - 2, 2)
    c.rrect(cx1 - 5, cy - 12, cx1 + 3, cy - 2, 2)
    s.paint(c, "#4a3f62", rim=0.5, rim_dx=0, rim_dy=-0.8, rim_colour="#ffcf8a")
    on_the_nod(s, cx0, cx1, cy)


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

    letterbox(s, 594, 62, 66, 34, 141)

    # the backlog, tumbling out of its mouth and all over the verge
    for cx, cy, w, h, ang in ((589, 74, 26, 15, -28), (586, 84, 26, 15, 16), (576, 132, 18, 10, 12),
                              (601, 139, 20, 11, -9), (626, 140, 16, 9, 7), (553, 139, 16, 9, -16)):
        envelope(s, cx, cy, w, h, ang)
    # and the one that matters, the size it feels
    envelope(s, 563, 96, 54, 34, -9, stamp=False)
    m = s.mask()
    lettering(m, "FINAL", 563, 89.5, 10.5, font=STENCIL, angle=-9)
    lettering(m, "NOTICE", 565, 102, 10.5, font=STENCIL, angle=-9)
    s.paint(m, "#d52a22")

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
    # brindle rather than black, with the last of the sky along his back, so he stands off the dark yard
    m = s.mask()
    staffy(m, 902, 143.5, 25, facing=-1)
    s.paint(m, "#2e2636", rim=1.0, rim_dx=0.5, rim_dy=-1.0, rim_colour="#ffc4a0")
    # the chain, collar to sign, which is mostly for show
    m = s.mask()
    m.stroke(bez((893, 125.5), (906, 137), (920, 136), (930, 130), n=20), 1.1, 1.1)
    s.paint(m, "#c4c0ce")

    # dark gums framing the picture, and giving the title something dark to sit on
    m = s.mask()
    gum_tree(m, 236, 176, 170, seed=44, lean=0.06)
    gum_tree(m, 1020, 176, 160, seed=46, lean=-0.1, spread=1.05)
    s.paint(m, "#03040a")
    return s.finish()
