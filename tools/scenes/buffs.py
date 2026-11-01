"""Buff Check: camp duty, out the back of the shops. The drum's lit, the crew's warming up, and someone's
laid out the raid's consumables on a milk crate, in order, with the other one on the end. One of them's
warming his hands. The other one's having a go on the glass, and his mate's seen it all before. Warmest
picture in the set."""
import numpy as np

from scenekit import SS, Scene, bez, gauss, glass_pipe, gum_tree, hoodie, lighter, lit_rim, razor_wire, smooth

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
    """Flames out of the top of a 44, and sparks. The drum itself goes on afterwards, in front."""
    # the pool of light on the bitumen, and the air around it
    s.rgb += (np.exp(-(((s.X / SS - x) / 118) ** 2)) * np.exp(-((s.Y / SS - 141) / 6.5) ** 2) * 0.62)[..., None] * s.colour("#ff8a3c")
    s.glow(x, base - 8, 72, colour="#ff7a2e", strength=0.30)
    s.glow(x, base - 8, 26, colour="#ffb45e", strength=0.42)
    for (col, scale, gain) in (("#d43f10", 1.0, 1.0), ("#ff8a1e", 0.72, 1.05), ("#ffcf55", 0.46, 1.25), ("#fff4c8", 0.22, 1.6)):
        m = s.mask()
        tongue(m, x, base + 2, 10 * scale, 30 * scale, lean=2.0 * scale)
        tongue(m, x - 6 * scale, base + 2, 5.5 * scale, 19 * scale, lean=-3 * scale)
        tongue(m, x + 6.5 * scale, base + 2, 5 * scale, 22 * scale, lean=2.5 * scale)
        a = gauss(m.array(), 0.35 * SS)
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


def drum(s, x, top, base, w):
    """The 44 itself: rust-dark, two ribs, a lip, and a few holes knocked in it for the draught."""
    m = s.mask()
    m.rect(x - w, top, x + w, base)
    m.rrect(x - w - 0.7, top - 1.2, x + w + 0.7, top + 1.2, 0.5)
    firelit(s, m, "#1a0d08", reach=60, fill=0.10, rim=0.8, colour="#ff8a3c")
    r = s.mask()
    for y in (top + (base - top) * 0.36, top + (base - top) * 0.68):
        r.rect(x - w, y, x + w, y + 1.0)
    s.paint(r, "#080403")
    lip = s.mask()
    lip.rect(x - w - 0.7, top - 1.2, x + w + 0.7, top + 0.2)
    s.paint(lip, "#ffb45e")
    h = s.mask()
    for dx, dy in ((-5.5, 8), (4.5, 7), (-1, 14), (6, 15.5), (-6, 19), (1.5, 21.5)):
        h.ellipse(x + dx, top + dy, 1.5, 1.5)
    ha = h.array()
    s.rgb = s.rgb * (1 - ha[..., None]) + s.colour("#ffd070") * 1.25 * ha[..., None]
    s.rgb += gauss(ha, 1.5 * SS)[..., None] * s.colour("#ff8a3c") * 0.9


def warmer(s, x, base, h, facing, hand):
    """Someone in a hoodie with their hands out over the drum. Doesn't matter who."""
    m = s.mask()
    hoodie(m, x, base, h, facing=facing, slouch=0.1, hands="free")
    sh = (x + facing * h * 0.1, base - h * 0.77)
    m.stroke(bez(sh, (sh[0] + facing * h * 0.13, sh[1] + h * 0.08), (hand[0] - facing * h * 0.1, hand[1] + h * 0.04), hand, n=12), h * 0.075, h * 0.055)
    m.stroke(bez((sh[0] - facing * 1, sh[1] + 2.5), (sh[0] + facing * h * 0.12, sh[1] + h * 0.15), (hand[0] - facing * h * 0.1, hand[1] + h * 0.1), (hand[0], hand[1] + 2.5), n=12), h * 0.075, h * 0.055)
    firelit(s, m, "#07050a", reach=90, fill=0.05, rim=2.6, colour="#ff9a48")


def lighter_flame(s, x, base, h):
    """The little flame off a disposable, base at (x, base), going straight up."""
    s.glow(x, base - h * 0.5, h * 3.2, colour="#ff9a48", strength=0.34)
    for col, k, gain in (("#ff8a1e", 1.0, 1.1), ("#ffd766", 0.72, 1.3), ("#fff6d2", 0.42, 1.7)):
        m = s.mask()
        tongue(m, x, base, h * 0.30 * k, h * k, lean=0.0)
        a = gauss(m.array(), 0.12 * SS)
        s.rgb = s.rgb * (1 - a[..., None]) + s.colour(col) * gain * a[..., None]


def plume(s, x, y, top, drift, seed=5, strength=0.82):
    """Smoke off the bulb: starts as a thread, opens into a slow fat cloud, gone by the top."""
    rng = np.random.default_rng(seed)
    m = s.mask()
    for t in np.linspace(0, 1, 90):
        px = x + drift * t + np.sin(t * 6.2 + 0.4) * (1.0 + 5.5 * t)
        py = y - (y - top) * t
        r = 0.55 + 7.0 * t ** 1.5
        m.ellipse(px, py, r, r * 0.9)
    for _ in range(9):  # lumps, so it's a cloud rather than a sausage
        t = rng.uniform(0.45, 1.0)
        px = x + drift * t + np.sin(t * 6.2 + 0.4) * (1.0 + 5.5 * t) + rng.normal(0, 3.2)
        r = 2 + 5 * t
        m.ellipse(px, y - (y - top) * t, r, r * 0.8)
    a = gauss(m.array(), 0.9 * SS)
    fade = np.clip((s.Y / SS - top + 4) / ((y - top) * 0.62), 0, 1) ** 0.8
    warm = np.clip((s.Y / SS - top) / (y - top), 0, 1)[..., None]
    col = s.colour("#ece8e4") * (1 - warm) + s.colour("#ffd2a0") * warm
    al = (a * fade * strength)[..., None]
    s.rgb = s.rgb * (1 - al) + col * al


def smoker(s, x, base, h):
    """The other one, back to the fire, having a go. Pipe at the hood, lighter under the bulb, one
    hand each. The fire's behind him, so the glass catches it."""
    mouth = (x + 0.175 * h, base - 0.855 * h)
    length, angle = 24, 9
    a = np.radians(angle)
    bx, by = mouth[0] + np.cos(a) * length, mouth[1] + np.sin(a) * length
    bulb = 3.9
    grip = (mouth[0] + np.cos(a) * 9, mouth[1] + np.sin(a) * 9)
    fl_h = 7.0
    fl_base = by + bulb + 7.5
    m = s.mask()
    hoodie(m, x, base, h, facing=1, slouch=0.1, hands="free")
    sh = (x + 0.15 * h, base - 0.76 * h)
    # the arm with the stem: elbow down, forearm up
    elbow = (sh[0] + 2.5, sh[1] + 11)
    m.stroke(np.array([sh, elbow]), h * 0.085, h * 0.075)
    m.stroke(np.array([elbow, (grip[0], grip[1] + 1.4)]), h * 0.09, h * 0.06)
    # the arm with the lighter: out under the bulb
    lh = (bx - 0.5, fl_base + 7.4)
    elbow2 = (sh[0] + 1.5, sh[1] + 17)
    m.stroke(np.array([(sh[0] - 1, sh[1] + 2.5), elbow2]), h * 0.085, h * 0.075)
    m.stroke(np.array([elbow2, lh]), h * 0.095, h * 0.065)
    firelit(s, m, "#07050a", reach=90, fill=0.05, rim=2.6, colour="#ff9a48")
    glass_pipe(s, mouth[0], mouth[1], length, angle=angle, bulb=bulb, width=2.0, smoke=0, ember=0.55, lit="#ffeeda")
    lighter(s, bx - 0.2, fl_base + 9.0, length=9, standing=True)
    lighter_flame(s, bx - 0.2, fl_base + 0.4, fl_h)
    f = s.mask()  # the fists go over the glass and the plastic
    f.ellipse(grip[0], grip[1] + 0.3, 2.1, 2.3)
    f.ellipse(lh[0], lh[1] + 0.3, 2.4, 2.4)
    s.paint(f, "#120b0a")
    lit_rim(s, m, bx, fl_base - 2, 22, "#ffb868", 0.9)
    lit_rim(s, f, bx, fl_base - 2, 18, "#ffc880", 2.2)
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
    """Milk crate, upside down, doing the job of an apothecary's table. Plastic lattice, and the only
    thing out here anyone's kept clean."""
    m = s.mask()
    m.rect(x0, top, x1, base)
    n = 4
    cw = (x1 - x0 - 3) / n
    rows = (base - top - 5) / 2
    for i in range(n):
        for j in range(2):
            cx = x0 + 1.5 + cw * i
            yy = top + 4 + j * rows
            m.rrect(cx + 1.1, yy + 0.9, cx + cw - 0.9, yy + rows - 0.9, 0.6, fill=0)
    firelit(s, m, "#1c2230", reach=110, fill=0.26, rim=1.0, colour="#ffb070")
    t = s.mask()
    t.rect(x0 - 0.6, top - 0.8, x1 + 0.6, top + 2.0)
    firelit(s, t, "#2a3040", reach=110, fill=0.34, rim=0.6, colour="#ffc080")


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
    for i, x in enumerate((540, 606, 700, 838, 925, 978)):
        gum_tree(m, x, 104, 46 + (i * 31) % 24, seed=120 + i, leaves=1.0)
    firelit(s, m, "#15100c", reach=120, fill=0.10, rim=0.3)

    shop_backs(s)

    # the bitumen, lit
    m = s.mask()
    m.spoly(bez((0, 141), (340, 139.5), (700, 139), (1040, 140), n=50).tolist() + [(1040, 148), (0, 148)])
    a = m.array()
    s.rgb = s.rgb * (1 - a[..., None]) + s.colour("#0f0a07") * a[..., None]

    fire(s, FX, FY)
    drum(s, FX, FY, 141, 11)
    warmer(s, FX - 28, 141, 50, 1, (FX - 13, 101))
    tip = smoker(s, FX + 28, 141, 50)

    # ---- the point of it: laid out in a row by someone who cares. Red, blue, green, and the other one,
    # budged along to give the bloke's elbows some room; the crate's end runs under the dropdown, the row doesn't
    cx0, cx1, ct = 726, 812, 117
    s.glow((cx0 + cx1) / 2 - 12, ct - 8, 34, colour="#ffb070", strength=0.08)
    crate(s, cx0, (cx0 + cx1) / 2 - 0.6, ct, 141)
    crate(s, (cx0 + cx1) / 2 + 0.6, cx1, ct, 141)
    for x, c in ((732, "#ff3c34"), (743.5, "#3f9bff"), (755, "#3cf07a")):
        flask(s, x, ct - 0.6, 5.2, c)
    # and the spare pipe lying along the crate, bulb on the plastic
    plume(s, tip[0], tip[1] + 0.5, 42, -6, strength=0.56)

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
