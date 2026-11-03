"""Buff Check: camp duty, out the back of the shops. The drum's lit, the crew's warming up, and someone's
laid out the raid's consumables on a milk crate, in order, with the other one on the end. One of them's
warming his hands. The other one's having a go on the glass, and his mate's seen it all before. Warmest
picture in the set."""
import numpy as np

from scenekit import SS, Scene, bez, gauss, glass_pipe, gum_tree, lighter, lit_rim, razor_wire, smooth

CAMP = {
    "sky": [(0.00, "#0a0a0e"), (0.34, "#16161a"), (0.56, "#2a2622"), (0.72, "#55422c"),
            (0.86, "#a06a38"), (0.95, "#de9147"), (1.00, "#f8b860")],
    "far": "#2c3a32", "mid": "#172420", "near": "#070c0a", "rim": "#ffbc70", "haze": "#a86f47",
}
FX, FY = 656, 112  # the fire, out the top of the drum: all the light in the foreground comes from here


def firelit(s, m, base, reach=120, fill=0.5, rim=1.4, colour="#ff9a48"):
    """Paint a silhouette lit by the fire: warm fill close in, bright on edges that face it."""
    a = m.array()
    dx, dy = FX * SS - s.X, (FY - 8) * SS - s.Y
    d = np.maximum(1.0, np.sqrt(dx * dx + dy * dy))
    fall = np.exp(-(d / (reach * SS)) ** 2) * (0.22 + 0.78 * np.clip((s.Y / SS - 50) / 80, 0, 1) ** 1.6)
    col = s.colour(base)[None, None, :] + fall[..., None] * s.colour(colour) * fill
    s.rgb = s.rgb * (1 - a[..., None]) + col * a[..., None]
    if rim > 0:
        b = gauss(a, 0.45 * SS)
        gy, gx = np.gradient(b)
        facing = np.clip(-(gx * dx + gy * dy) / d, 0, None) * (0.45 * SS * 2.5)
        s.rgb += (facing * fall * a * rim)[..., None] * s.colour(colour)


def tongue(m, x, base, w, h, lean=0.0):
    pts = bez((x - w, base), (x - w * 1.25, base - h * 0.40), (x + lean - w * 0.35, base - h * 0.62), (x + lean, base - h), n=20).tolist()
    pts += bez((x + lean, base - h), (x + lean * 0.3 + w * 0.5, base - h * 0.60), (x + w * 1.25, base - h * 0.36), (x + w, base), n=20).tolist()
    m.spoly(pts)


def fire(s, x, base):
    """Flames up out of the open top of a 44, and sparks. The drum's front goes on afterwards, so the rim
    cuts across the bottom of them."""
    # the pool of light on the bitumen, and the air around it
    s.rgb += (np.exp(-(((s.X / SS - x) / 118) ** 2)) * np.exp(-((s.Y / SS - 141) / 6.5) ** 2) * 0.62)[..., None] * s.colour("#ff8a3c")
    s.glow(x, base - 8, 72, colour="#ff7a2e", strength=0.30)
    s.glow(x, base - 8, 24, colour="#ffb45e", strength=0.30)
    for (col, scale, gain) in (("#d43f10", 1.0, 1.0), ("#ff8a1e", 0.72, 1.05), ("#ffcf55", 0.46, 1.25), ("#fff4c8", 0.22, 1.6)):
        m = s.mask()
        # a crown of uneven tongues as wide as the drum's mouth, not one triangle
        tongue(m, x - 1.5 * scale, base + 3, 6.2 * scale, 31 * scale, lean=2.5 * scale)
        tongue(m, x - 6.6 * scale, base + 3, 3.6 * scale, 17 * scale, lean=-2.5 * scale)
        tongue(m, x + 4.6 * scale, base + 3, 4.6 * scale, 23 * scale, lean=3.5 * scale)
        tongue(m, x + 8.0 * scale, base + 3, 2.4 * scale, 11 * scale, lean=1.5 * scale)
        tongue(m, x - 3.6 * scale, base + 3, 3.0 * scale, 22 * scale, lean=-3.5 * scale)
        a = gauss(m.array(), 0.14 * SS)
        s.rgb = s.rgb * (1 - a[..., None]) + s.colour(col) * gain * a[..., None]
    # sparks: fewer and smaller as they climb
    rng = np.random.default_rng(14)
    m = s.mask()
    for _ in range(26):
        t = rng.random() ** 1.9
        y = base - 26 - t * 62
        spread = 2 + t * 13
        ex = x + 2 + t * 12 + rng.normal(0, spread)
        r = 0.62 - t * 0.34 + rng.random() * 0.18
        m.ellipse(ex, y, r, r)
    a = m.array()
    s.rgb += a[..., None] * s.colour("#ffc35e") * 1.8
    s.rgb += gauss(a, 1.3 * SS)[..., None] * s.colour("#ff7a2e") * 2.0


RIM_RY = 2.5  # how far down you can see into the mouth of the drum


def rim_arc(x, y, rx, a0, a1, n=24):
    """Part of the drum's round mouth. 0 degrees is the right edge, 90 the near side."""
    t = np.radians(np.linspace(a0, a1, n))
    return np.stack((x + rx * np.cos(t), y + RIM_RY * np.sin(t)), axis=1)


def drum_back(s, x, top, w):
    """The inside of the drum and the far side of its rim. Goes on before the flames."""
    m = s.mask()
    m.ellipse(x, top, w + 0.7, RIM_RY)
    s.paint(m, "#7a2c0c")
    c = s.mask()
    c.stroke(rim_arc(x, top, w + 0.2, 180, 360), 0.9, 0.9)
    s.paint(c, "#2c1208")


def punched(m, x, y, r, seed):
    """A hole knocked in with whatever was handy: no two the same, and not round."""
    rng = np.random.default_rng(seed)
    n = int(rng.integers(5, 8))
    ang = np.sort(rng.uniform(0, 2 * np.pi, n))
    m.spoly([(x + np.cos(t) * r * rng.uniform(0.6, 1.25), y + np.sin(t) * r * rng.uniform(0.55, 1.15)) for t in ang])


def drum(s, x, top, base, w):
    """The front of the 44: rust-dark, two ribs, its near rim across the flames, and a few holes knocked
    in it for the draught, wherever the crowbar went."""
    m = s.mask()
    m.spoly(rim_arc(x, top, w, 180, 0).tolist() + [(x + w, base), (x - w, base)])
    firelit(s, m, "#1a0d08", reach=60, fill=0.10, rim=0.8, colour="#ff8a3c")
    r = s.mask()
    for k in (0.36, 0.68):
        y = top + (base - top) * k
        r.stroke(rim_arc(x, y, w, 180, 0), 1.0, 1.0)
    s.paint(r, "#080403")
    h, hot = s.mask(), s.mask()
    for i, (dx, dy, rr) in enumerate(((-6.6, 6.2, 1.5), (-2.4, 7.6, 0.6), (4.4, 7.4, 1.0), (-1.2, 15.8, 1.9), (7.2, 15.0, 0.8),
                                      (-7.6, 16.4, 0.6), (4.4, 24.4, 1.4), (-5.2, 25.4, 0.9))):
        punched(h, x + dx, top + dy, rr, 40 + i)
        if rr > 1.2:
            punched(hot, x + dx + 0.1, top + dy + 0.2, rr * 0.5, 60 + i)
    ha = h.array()
    s.rgb = s.rgb * (1 - ha[..., None]) + s.colour("#e8701f") * ha[..., None]
    s.rgb += gauss(ha, 0.9 * SS)[..., None] * s.colour("#ff8a3c") * 0.35
    hb = hot.array()
    s.rgb = s.rgb * (1 - hb[..., None]) + s.colour("#ffc35e") * 1.1 * hb[..., None]
    # the near rim, a rolled steel lip, in front of the fire and lit from above
    lip = s.mask()
    lip.stroke(rim_arc(x, top + 0.2, w + 0.3, 180, 0), 1.5, 1.5)
    s.paint(lip, "#d98a45")


NEAR, MIDTONE, FAR = "#07050a", "#0d090b", "#23150f"  # far limbs a shade up, so a limb behind a limb still reads


def limb(m, pts, widths, cap=True):
    """A sleeve or a trouser leg through its joints, tapered, one clean outline with a proper corner at
    the bend. No round joints: nobody's got a ball for an elbow. cap rounds off the top end, for where a
    sleeve lies over the body."""
    pts = [np.array(p, float) for p in pts]
    left, right = [], []
    for i, p in enumerate(pts):
        d0 = pts[i] - pts[i - 1] if i else pts[1] - pts[0]
        d1 = pts[i + 1] - pts[i] if i < len(pts) - 1 else d0
        d0, d1 = d0 / np.linalg.norm(d0), d1 / np.linalg.norm(d1)
        t = d0 + d1
        t /= max(1e-6, np.linalg.norm(t))
        n = np.array([-t[1], t[0]])
        k = min(1.45, 1 / max(0.3, float(np.dot(n, np.array([-d0[1], d0[0]])))))
        left.append(tuple(p + n * widths[i] / 2 * k))
        right.append(tuple(p - n * widths[i] / 2 * k))
    m.spoly(left + right[::-1])
    if cap:
        m.ellipse(pts[0][0], pts[0][1], widths[0] / 2, widths[0] / 2)


class Crew:
    """A bloke side on in a baggy hoodie, hood up, and trackies: weight on the front leg, a real head in
    the hood, and a notch front and back where the neck goes into the shoulders. The arms are the caller's."""

    def __init__(self, x, base, h, facing=1, lean=0.03):
        self.x, self.base, self.h, self.f, self.lean = x, base, h, facing, lean

    def P(self, u, v):
        return (self.x + (u + self.lean * max(0.0, v - 0.45) * 2.0) * self.h * self.f, self.base - v * self.h)

    def far_leg(self, m):
        P, h = self.P, self.h
        limb(m, [P(-0.015, 0.47), P(-0.065, 0.265), P(-0.115, 0.05)], [h * 0.112, h * 0.086, h * 0.058])
        m.spoly([P(-0.15, 0.0), P(-0.15, 0.045), P(-0.09, 0.06), P(-0.07, 0.04), P(-0.02, 0.018), P(-0.02, 0.0)])

    def body(self, m):
        P, h = self.P, self.h
        # the front leg, knee just off straight
        limb(m, [P(0.02, 0.47), P(0.055, 0.265), P(0.035, 0.05)], [h * 0.118, h * 0.09, h * 0.06], cap=False)
        m.spoly([P(0.0, 0.0), P(0.0, 0.05), P(0.06, 0.06), P(0.08, 0.04), P(0.145, 0.018), P(0.145, 0.0)])
        # the jumper: sloped shoulders, baggy, hem past the hips, the pouch hanging out the front
        pts = bez(P(-0.04, 0.815), P(-0.1, 0.8), P(-0.135, 0.76), P(-0.135, 0.66), n=10).tolist()
        pts += bez(P(-0.135, 0.66), P(-0.135, 0.56), P(-0.12, 0.5), P(-0.11, 0.43), n=8).tolist()
        pts += [P(0.1, 0.43), P(0.128, 0.5), P(0.125, 0.56)]
        pts += bez(P(0.125, 0.56), P(0.1, 0.62), P(0.11, 0.72), P(0.05, 0.815), n=10).tolist()
        m.spoly(pts)
        # the hood: round at the back, a soft peak out the front, and it comes in hard to the neck
        pts = bez(P(-0.045, 0.805), P(-0.105, 0.85), P(-0.128, 0.93), P(-0.08, 0.985), n=12).tolist()
        pts += bez(P(-0.08, 0.985), P(-0.02, 1.022), P(0.085, 1.018), P(0.14, 0.952), n=10).tolist()
        pts += bez(P(0.14, 0.952), P(0.128, 0.91), P(0.105, 0.85), P(0.055, 0.805), n=8).tolist()
        m.spoly(pts)

    def face(self, m):
        """The opening of the hood, side on: a sliver of whoever's in there, under the peak."""
        P = self.P
        pts = bez(P(0.124, 0.942), P(0.07, 0.95), P(0.035, 0.92), P(0.042, 0.875), n=8).tolist()
        pts += bez(P(0.042, 0.875), P(0.05, 0.848), P(0.08, 0.84), P(0.098, 0.858), n=6).tolist()
        pts += bez(P(0.098, 0.858), P(0.115, 0.885), P(0.122, 0.915), P(0.124, 0.942), n=6).tolist()
        m.spoly(pts)


def open_hand(m, wrist, f, k=1.0, tip=0.0):
    """A hand held up to the fire, palm out, with the fingers spread so it's a hand and not a mitten."""
    x, y = wrist
    cx, cy = x + f * 1.2 * k + tip * 0.3, y - 1.8 * k
    m.ellipse(cx, cy, 1.9 * k, 2.3 * k)
    for dx, top in ((-0.9, 4.2), (0.2, 4.5), (1.3, 4.1)):
        m.stroke(np.array([(cx + f * dx * 0.8, cy - 1.2 * k), (cx + f * (dx * 1.25 + 0.4) + tip, cy - top * k)]), 1.0 * k, 0.8 * k)
    m.stroke(np.array([(cx + f * 1.3 * k, cy + 0.2 * k), (cx + f * 3.2 * k, cy - 0.9 * k)]), 1.0 * k, 0.8 * k)


def warmer(s, x, base, h, facing):
    """Someone in a hoodie with their hands out over the drum, palms to it, the way everyone does.
    Doesn't matter who."""
    b = Crew(x, base, h, facing, lean=0.03)
    f = facing
    sh = b.P(0.015, 0.755)
    far, near = s.mask(), s.mask()
    b.far_leg(far)
    # the far arm, higher and further out
    elbow, wrist = (sh[0] + f * h * 0.17, sh[1] + h * 0.055), (sh[0] + f * h * 0.31, sh[1] - h * 0.06)
    limb(far, [sh, elbow, wrist], [h * 0.082, h * 0.072, h * 0.05])
    open_hand(far, wrist, f, 0.85)
    firelit(s, far, FAR, reach=90, fill=0.04, rim=2.2, colour="#ff9a48")
    body = s.mask()
    b.body(body)
    firelit(s, body, MIDTONE, reach=90, fill=0.04, rim=2.4, colour="#ff9a48")
    fc = s.mask()
    b.face(fc)
    s.paint(fc, "#9c4a1a")
    # the near arm, the elbow dropped, the forearm coming back up
    sh2 = (sh[0] - f * h * 0.03, sh[1] + h * 0.01)
    elbow, wrist = (sh2[0] + f * h * 0.14, sh2[1] + h * 0.17), (sh2[0] + f * h * 0.3, sh2[1] + h * 0.075)
    limb(near, [sh2, elbow, wrist], [h * 0.09, h * 0.076, h * 0.052])
    open_hand(near, wrist, f, 0.85)
    firelit(s, near, NEAR, reach=90, fill=0.03, rim=1.6, colour="#ff9a48")


def lighter_flame(s, x, base, h):
    """The little flame off a disposable, base at (x, base), going straight up. A hard little leaf of fire."""
    s.glow(x, base - h * 0.5, h * 1.5, colour="#ff9a48", strength=0.22)
    for col, k, gain in (("#ff8a1e", 1.0, 1.15), ("#ffd766", 0.72, 1.35), ("#fff6d2", 0.40, 1.7)):
        m = s.mask()
        tongue(m, x, base, h * 0.27 * k, h * k, lean=0.0)
        a = m.array()
        s.rgb = s.rgb * (1 - a[..., None]) + s.colour(col) * gain * a[..., None]


def wisp(s, x, y, top, drift=4.0):
    """The smoke: one thin hard thread off the bulb that curls as it climbs, getting finer until there's
    nothing left of it. It's a pipe, not a chimney."""
    t = np.linspace(0, 1, 120)
    pts = np.stack((x + drift * t ** 1.3 + np.sin(t * 10.5 + 0.5) * (0.35 + 3.0 * t), y - (y - top) * t), axis=1)
    m = s.mask()
    m.stroke(pts, 1.0, 0.34)
    fade = np.clip((s.Y / SS - top) / ((y - top) * 0.55), 0, 1)
    al = (m.array() * fade * 0.78)[..., None]
    s.rgb = s.rgb * (1 - al) + s.colour("#d8d0c6") * al


def smoker(s, x, base, h):
    """The other one, back to the fire, having a go. Pipe at the hood, the stem pinched near his face with
    the elbow dropped; the far arm out under the bulb, the lighter stood up in the fist. The fire's behind
    him, so the glass catches it."""
    b = Crew(x, base, h, 1, lean=0.04)
    mouth = b.P(0.075, 0.888)
    length, angle = 22, 5
    a = np.radians(angle)
    bx, by = mouth[0] + np.cos(a) * length, mouth[1] + np.sin(a) * length
    bulb = 3.2
    grip = (mouth[0] + np.cos(a) * 8.0, mouth[1] + np.sin(a) * 8.0)
    fl_h = 4.6
    fl_base = by + bulb + fl_h - 0.6  # the tip just licking the bottom of the glass
    lh = (bx - 0.2, fl_base + 4.9)  # the far fist, round the lighter
    sh = b.P(0.03, 0.755)
    # far leg and far arm first, a shade lighter, so they sit behind him
    far = s.mask()
    b.far_leg(far)
    sh_far = (sh[0] + h * 0.04, sh[1])
    elbow_far = (sh_far[0] + h * 0.19, sh_far[1] + h * 0.15)
    limb(far, [sh_far, elbow_far, (lh[0] - 2.0, lh[1] + 0.8)], [h * 0.082, h * 0.072, h * 0.05])
    firelit(s, far, FAR, reach=90, fill=0.04, rim=2.0, colour="#ff9a48")
    body = s.mask()
    b.body(body)
    firelit(s, body, MIDTONE, reach=90, fill=0.04, rim=2.4, colour="#ff9a48")
    fc = s.mask()
    b.face(fc)
    s.paint(fc, "#4a2410")
    # near arm over the chest: elbow hanging, forearm back up to the stem
    near = s.mask()
    elbow = (sh[0] + h * 0.1, sh[1] + h * 0.2)
    limb(near, [(sh[0] - h * 0.02, sh[1] + 0.8), elbow, (grip[0] - 0.3, grip[1] + 2.0)], [h * 0.09, h * 0.076, h * 0.05])
    firelit(s, near, NEAR, reach=70, fill=0.03, rim=1.0, colour="#ff9a48")
    glass_pipe(s, mouth[0], mouth[1], length, angle=angle, bulb=bulb, width=1.3, smoke=0, ember=0.22, lit="#ffeeda")
    lighter(s, bx - 0.2, fl_base + 8.4, length=8.0, standing=True)
    lighter_flame(s, bx - 0.2, fl_base + 0.3, fl_h)
    # the fists go over the glass and the plastic: fingers round the stem, thumb on top
    fist = s.mask()
    fist.rrect(grip[0] - 1.7, grip[1] - 0.9, grip[0] + 1.7, grip[1] + 2.4, 1.1)
    fist.stroke(np.array([(grip[0] - 1.4, grip[1] + 0.1), (grip[0] + 1.2, grip[1] - 1.5)]), 1.1, 0.9)
    fist.rrect(lh[0] - 2.3, lh[1] - 1.9, lh[0] + 2.2, lh[1] + 2.3, 1.1)
    s.paint(fist, "#120b0a")
    lit_rim(s, near, bx, fl_base - 2, 22, "#ffb868", 0.35)
    lit_rim(s, fist, bx, fl_base - 2, 18, "#ffc880", 2.2)
    return bx, by - bulb


def flask(s, x, base, r, colour):
    """A Warcraft potion: round belly, long neck, a cork. Brought from home, or thereabouts."""
    cy = base - r
    m = s.mask()
    m.ellipse(x, cy, r, r)
    m.rect(x - r * 0.3, cy - r * 1.7, x + r * 0.3, cy - r * 0.7)
    m.rrect(x - r * 0.44, cy - r * 1.82, x + r * 0.44, cy - r * 1.56, 0.3)
    s.paint(m, "#120c0a")
    lq = s.mask()
    lq.ellipse(x, cy, r * 0.84, r * 0.84)
    lq.rect(x - r, cy - r, x + r, cy - r * 0.32, fill=0)
    la = lq.array()
    s.rgb += gauss(la, r * 1.0 * SS)[..., None] * s.colour(colour) * 0.65
    s.rgb = s.rgb * (1 - la[..., None]) + s.colour(colour) * 1.25 * la[..., None]
    g = s.mask()
    g.ellipse(x - r * 0.42, cy - r * 0.4, r * 0.18, r * 0.13)
    ga = g.array()
    s.rgb = s.rgb * (1 - ga[..., None]) + s.colour("#fff8f0") * ga[..., None]
    k = s.mask()
    k.rrect(x - r * 0.26, cy - r * 2.08, x + r * 0.26, cy - r * 1.76, 0.2)
    s.paint(k, "#a07a4c")


def crate(s, x0, x1, top, base):
    """Milk crate, upside down, doing the job of an apothecary's table. Moulded plastic, solid, with the
    slots cut through it and a hand-hole up top, and the only thing out here anyone's kept clean."""
    m = s.mask()
    m.rrect(x0, top, x1, base, 1.0)
    firelit(s, m, "#100f18", reach=125, fill=0.2, rim=0.7, colour="#ff8a48")
    # the thick top band and the skirt at the bottom, a step lighter, because it's all one moulding
    t = s.mask()
    t.rrect(x0 - 0.5, top - 0.7, x1 + 0.5, top + 4.6, 0.7)
    t.rect(x0, base - 3.0, x1, base)
    firelit(s, t, "#191722", reach=125, fill=0.28, rim=0.5, colour="#ff9a58")
    # the slots: a few tall ones, dark right through, plenty of plastic between them, and the hand-hole up top
    n = 4
    pad, gap = 3.2, 3.6
    sw = (x1 - x0 - 2 * pad - (n - 1) * gap) / n
    v = s.mask()
    for i in range(n):
        sx = x0 + pad + i * (sw + gap)
        v.rrect(sx, top + 7.2, sx + sw, base - 5.2, 1.1)
    cx = (x0 + x1) / 2
    v.rrect(cx - 6, top + 1.2, cx + 6, top + 3.0, 0.8)
    s.paint(v, "#060508")


def shop_backs(s):
    """The back wall of the strip, parapets out of step, and a coil of wire to keep out whoever it's
    keeping out. Nobody's climbed it since they cut the fence round the side."""
    m = s.mask()
    m.spoly([(0, 148), (0, 92), (470, 92), (470, 84), (736, 84), (736, 90), (872, 90), (872, 84), (1040, 84), (1040, 148)])
    firelit(s, m, "#120d0b", reach=130, fill=0.22, rim=0.25, colour="#e8783a")
    # block courses, just enough to say it's a wall
    r = s.mask()
    for y in np.arange(92, 140, 6.0):
        r.line([(460, y), (1040, y)], 0.3)
    s.rgb = s.rgb * (1 - r.array()[..., None] * 0.22)
    w = s.mask()
    razor_wire(w, 482, 730, 80, r=4.0, step=5.2, width=0.42)
    firelit(s, w, "#0c0807", reach=120, fill=0.18, rim=0.9, colour="#ffb070")


def banner(s, x, base, top, bottom):
    """Guild banner on a broom handle, head still on: long cloth, swallowtail hem, a gum leaf where a crest goes."""
    m = s.mask()
    m.stroke(np.array([(x, base), (x, top)]), 1.8, 1.5)
    m.rrect(x - 7, top - 3.4, x + 7, top - 0.6, 0.5)
    for dx in np.arange(-6.2, 6.6, 1.55):
        m.line([(x + dx, top - 3), (x + dx * 1.1, top - 9)], 0.75)
    m.rrect(x - 20, top + 3.5, x + 22, top + 6, 0.9)
    m.ellipse(x - 20, top + 4.7, 1.9, 1.9)
    m.ellipse(x + 22, top + 4.7, 1.9, 1.9)
    firelit(s, m, "#120a06", reach=160, fill=0.16, rim=1.2, colour="#ffc070")
    cx0, cx1, cy0, cy1 = x - 16, x + 18, top + 6, bottom
    cloth = s.mask()
    leftedge = bez((cx0, cy0), (cx0 + 1.8, cy0 + (cy1 - cy0) * 0.4), (cx0 - 1.5, cy0 + (cy1 - cy0) * 0.7), (cx0 + 0.5, cy1), n=20).tolist()
    rightedge = bez((cx1 - 0.5, cy1), (cx1 + 1.5, cy0 + (cy1 - cy0) * 0.7), (cx1 - 1.8, cy0 + (cy1 - cy0) * 0.4), (cx1, cy0), n=20).tolist()
    mid = ((cx0 + cx1) / 2, cy1 - 8)
    cloth.spoly(leftedge + [mid] + rightedge)
    a = cloth.array()
    dx = (FX * SS - s.X) / SS
    fall = np.exp(-(dx / 180) ** 2)
    # soft vertical folds; the side nearest the fire catches it
    folds = 0.85 + 0.15 * np.sin((s.X / SS - cx0) * 0.55)
    side = 0.52 + 0.48 * np.clip((FX + 180 - s.X / SS) / 180, 0, 1) * np.clip((s.Y / SS - cy0 + 8) / (cy1 - cy0), 0, 1)
    col = s.colour("#8d1f1a")[None, None, :] * (folds * side * (0.45 + 0.75 * fall))[..., None]
    s.rgb = s.rgb * (1 - a[..., None]) + col * a[..., None]
    # gold edge and a single gum leaf
    t = s.mask()
    t.stroke(np.array(leftedge), 1.1, 1.1)
    t.stroke(np.array(rightedge), 1.1, 1.1)
    t.line([(cx0, cy0 + 0.6), (cx1, cy0 + 0.6)], 1.1)
    t.stroke(np.array([(cx0 + 0.5, cy1), mid]), 1.0, 1.0)
    t.stroke(np.array([mid, (cx1 - 0.5, cy1)]), 1.0, 1.0)
    lx, ly = (cx0 + cx1) / 2, (cy0 + cy1) / 2 - 3
    t.spoly(bez((lx + 3.5, ly - 8.5), (lx - 5.5, ly - 4), (lx - 5.5, ly + 5.5), (lx - 4, ly + 8.5), n=16).tolist()
            + bez((lx - 4, ly + 8.5), (lx + 5.5, ly + 4.5), (lx + 6, ly - 4), (lx + 3.5, ly - 8.5), n=16).tolist())
    ta = t.array()
    s.rgb = s.rgb * (1 - ta[..., None]) + s.colour("#d6a64a") * (0.55 + 0.5 * fall)[..., None] * ta[..., None]
    # the leaf's midrib, so it isn't a blob
    r = s.mask()
    r.stroke(bez((lx - 3.5, ly + 7.5), (lx - 1, ly + 1.5), (lx + 3, ly - 7), n=10), 0.8, 0.5)
    s.paint(r, "#58160f")


def paint():
    s = Scene(CAMP, seed=38, horizon=96)
    s.sky(clouds=0.26, stars=1.0, glow_x=0.64, glow_w=0.20)
    s.moon(592, 28, 14, tint="#f8ecd2", glow=0.42, seed=3)
    s.moon(551, 19, 6.5, tint="#a9c6ff", glow=0.40, seed=9)
    s.ridge(92, 12, 67, "#46352a", roughness=4)
    s.fog(74, 96, strength=0.3)

    # the suburb's gums, poking up over the back of the shops
    m = s.mask()
    for i, x in enumerate((540, 606, 700, 770, 925, 978)):
        gum_tree(m, x, 104, 46 + (i * 31) % 24, seed=120 + i, leaves=1.0)
    firelit(s, m, "#15100c", reach=120, fill=0.10, rim=0.3)

    shop_backs(s)

    # the bitumen, lit
    m = s.mask()
    m.spoly(bez((0, 141), (340, 139.5), (700, 139), (1040, 140), n=50).tolist() + [(1040, 148), (0, 148)])
    a = m.array()
    s.rgb = s.rgb * (1 - a[..., None]) + s.colour("#0f0a07") * a[..., None]

    drum_back(s, FX, FY, 11)
    fire(s, FX, FY)
    drum(s, FX, FY, 141, 11)
    # each of them throws a hard shadow on the bitumen, straight away from the drum
    sh = s.mask()
    sh.spoly([(FX - 41, 141), (FX - 20, 141), (FX - 62, 145), (FX - 90, 145)])
    sh.spoly([(FX + 18, 141), (FX + 38, 141), (FX + 92, 145), (FX + 62, 145)])
    a = sh.array()[..., None]
    s.rgb = s.rgb * (1 - a * 0.72)
    warmer(s, FX - 32, 141, 52, 1)
    tip = smoker(s, FX + 27, 141, 52)

    # ---- the point of it: laid out in a row by someone who cares. Red, blue, green, and the other one,
    # budged along to give the bloke's elbows some room; the crate's end runs under the dropdown, the row doesn't
    cx0, cx1, ct = 726, 812, 117
    s.glow((cx0 + cx1) / 2 - 12, ct - 8, 34, colour="#ffb070", strength=0.08)
    crate(s, cx0, (cx0 + cx1) / 2 - 0.6, ct, 141)
    crate(s, (cx0 + cx1) / 2 + 0.6, cx1, ct, 141)
    for x, c in ((732, "#ff3c34"), (743.5, "#3f9bff"), (755, "#3cf07a")):
        flask(s, x, ct - 0.6, 5.2, c)
    # and the spare pipe lying along the crate, bulb on the plastic
    wisp(s, tip[0], tip[1] + 0.8, 54)

    # the guild's colours, stuck in the dirt: the banner clears the dropdown and the handle runs behind it
    banner(s, 838, 140, 56, 90)

    # dark framing at the edges so the eye stays at the fire and the title stays readable
    m = s.mask()
    gum_tree(m, 232, 178, 170, seed=12, lean=0.08)
    gum_tree(m, 1024, 176, 170, seed=7, lean=-0.1, spread=1.1)
    s.paint(m, "#030403")
    # the title's side stays dark, whatever the sunset's doing
    s.rgb *= (0.45 + 0.55 * smooth(420 * SS, 556 * SS, s.X))[..., None]
    return s.finish(bloom=0.45, vignette=0.28)
