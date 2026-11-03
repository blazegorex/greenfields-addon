"""Residents: the street, seen along its length, shrinking toward a keep on the far hill. One house has
every light on and a queue down the kerb at 3am, and further along there's a heap of pushbikes, none of
them his. It's meant to feel like people live here, and some of them even do."""
import math

import numpy as np

from scenekit import SCRAWL, SS, Scene, bez, boards, gum_tree, hoodie, house, lettering, light_windows, power_pole, wires

VX, VY = 510, 104  # where the street disappears to
KERB = 0.15
HOUSE_AT = 100  # the popular one: far enough up the road to be in the clear of the search box


def ground_at(d, k=0.11):
    return VY + d * k


def keep(m, cx, base, u):
    """Far-off fortress on the hill at the end of the road: Azeroth is just past the servo."""
    m.rect(cx - 12 * u, base - 14 * u, cx + 13 * u, base)
    for dx, hw, ht in ((-13, 3.2, 26), (14, 3.0, 22), (-3, 4.2, 38), (6, 2.4, 30)):
        m.rect(cx + dx * u - hw * u, base - ht * u, cx + dx * u + hw * u, base)
        m.spoly([(cx + dx * u - hw * u - 0.5, base - ht * u), (cx + dx * u, base - ht * u - hw * u * 2.3), (cx + dx * u + hw * u + 0.5, base - ht * u)])
    # a pennant, hardly there
    m.line([(cx - 3 * u, base - 47 * u), (cx - 3 * u, base - 54 * u)], 0.35)
    m.spoly([(cx - 3 * u, base - 54 * u), (cx + 3 * u, base - 52.5 * u), (cx - 3 * u, base - 50.5 * u)])


def bike(m, cx, cy, r, tilt=0.0, facing=1, width=0.8):
    """Pushbike, centred on (cx, cy) and tilted any way up: two wheels, a frame, handlebars, a seat.
    Wheels are drawn as rings so a heap of them stays see-through."""
    f = facing
    a = math.radians(tilt)
    ca, sa = math.cos(a), math.sin(a)

    def P(u, v):
        return (cx + (u * f) * r * ca - (-v) * r * sa, cy + (u * f) * r * sa + (-v) * r * ca)

    back, front = P(-1.4, -1), P(1.4, -1)
    for c in (back, front):
        m.d.ellipse(((c[0] - r) * SS, (c[1] - r) * SS, (c[0] + r) * SS, (c[1] + r) * SS), outline=255, width=max(1, int(width * SS)))
    crank, seat, head = P(-0.2, -0.82), P(-0.62, 0.05), P(0.9, 0.05)
    for p, q in ((back, crank), (back, seat), (seat, crank), (crank, head), (seat, head), (head, front)):
        m.line([p, q], width)
    m.line([P(-0.95, 0.12), P(-0.25, 0.12)], width * 1.5)
    m.line([head, P(0.8, 0.62), P(1.5, 0.74)], width)


def letterbox(m, x, base, h, kind=0):
    w = h * 0.34
    if kind == 0:  # box on a post
        m.rect(x - h * 0.05, base - h * 0.72, x + h * 0.05, base)
        m.rrect(x - w, base - h, x + w, base - h * 0.62, h * 0.07)
        m.spoly([(x - w * 1.15, base - h * 0.96), (x, base - h * 1.14), (x + w * 1.15, base - h * 0.96)])
    elif kind == 1:  # brick pillar, with the cap
        m.rect(x - w * 0.8, base - h * 0.92, x + w * 0.8, base)
        m.rect(x - w, base - h, x + w, base - h * 0.92)
    else:  # round-top on a pole
        m.rect(x - h * 0.05, base - h * 0.6, x + h * 0.05, base)
        m.rrect(x - w * 0.9, base - h, x + w * 0.9, base - h * 0.52, h * 0.2)


def dark_window(s, x, y, w, h, frame, sheen="#6a5a86"):
    """Nobody home, or nobody admitting it: dark glass with a hard slant of sky on it, frame and sill."""
    m = s.mask()
    m.rect(x - 0.9, y - 0.9, x + w + 0.9, y + h + 0.9)
    s.paint(m, frame)
    m = s.mask()
    m.rect(x, y, x + w, y + h)
    s.paint(m, "#05061a")
    lean = h * 0.55
    c = s.mask()
    c.rect(x, y, x + w, y + h)
    g = s.mask()
    g.spoly([(x + w * 0.22 + lean, y), (x + w * 0.42 + lean, y), (x + w * 0.42, y + h), (x + w * 0.22, y + h)])
    a = g.array() * c.array()
    s.rgb = s.rgb * (1 - a[..., None] * 0.4) + s.colour(sheen) * (a * 0.4)[..., None]
    m = s.mask()
    m.rect(x + w / 2 - 0.4, y, x + w / 2 + 0.4, y + h)
    s.paint(m, frame)
    m = s.mask()
    m.rect(x - 1.8, y + h + 0.5, x + w + 1.8, y + h + 1.7)
    s.paint(m, frame)


def street_house(s, x, base, w, h, tone, kind="boards", lit=(), boarded=(), seed=1):
    """A front-on fibro or weatherboard place, dark but built: a tin roof with its ribs and capping, a gutter
    that's let go at one end, cladding, windows, a door, and a paling fence with teeth missing. Stays low in
    contrast, it's only here so the queue and the signs have a street to be in. Returns the window slots."""
    tone = np.asarray(tone, np.float32)
    wall = tone * 0.70 + s.colour("#35325e") * 0.30
    line = wall * 0.68
    pale = wall * 1.45 + 0.02
    rise = h * 0.52
    over = w * 0.05
    eave = base - h
    ridge = eave - rise
    rx0, rx1 = x + w * 0.22, x + w * 0.78

    m = s.mask()
    m.rect(x, eave, x + w, base)
    s.paint(m, wall)
    # cladding
    c = s.mask()
    if kind == "boards":
        for yy in np.arange(eave + 3, base, max(2.7, h * 0.075)):
            c.line([(x, yy), (x + w, yy)], 0.7)
    else:  # fibro sheets and their cover strips
        for xx in np.arange(x + w / 9, x + w - 1, w / 9):
            c.line([(xx, eave), (xx, base)], 0.8)
        c.line([(x, base - h * 0.28), (x + w, base - h * 0.28)], 0.8)
    s.paint(c, line)

    # chimney, roof, ribs, ridge capping
    m = s.mask()
    cx = x + w * 0.70
    m.rect(cx, ridge - h * 0.22, cx + w * 0.05, ridge + rise * 0.5)
    m.rect(cx - 0.8, ridge - h * 0.22 - 0.8, cx + w * 0.05 + 0.8, ridge - h * 0.22 + 0.6)
    s.paint(m, tone * 1.2, rim=0.4, rim_dx=-0.6, rim_dy=-0.6)
    m = s.mask()
    m.spoly([(x - over, eave), (rx0, ridge), (rx1, ridge), (x + w + over, eave)])
    s.paint(m, tone * 0.82, rim=0.5, rim_dx=-0.7, rim_dy=-0.8)
    c = s.mask()
    n = int(w / 4.5)
    for k in range(1, n):
        q = k / n
        c.line([(rx0 + (rx1 - rx0) * q, ridge + 0.8), (x - over + (w + 2 * over) * q, eave)], 0.7)
    s.paint(c, tone * 1.22 + 0.012)

    # the gutter: straight, until it isn't
    drop = max(1.6, h * 0.05)
    gh = max(1.4, h * 0.035)
    g = s.mask()
    g.rect(x - over - 0.6, eave - 0.4, x + w * 0.74, eave + gh)
    g.spoly([(x + w * 0.74, eave - 0.4), (x + w + over + 0.6, eave - 0.4 + drop), (x + w + over + 0.6, eave + gh + drop), (x + w * 0.74, eave + gh)])
    g.rect(x + w * 0.015, eave + gh, x + w * 0.015 + 1.3, base)  # downpipe
    s.paint(g, pale * 0.9)

    # windows and the door
    ww, wh = h * 0.56, h * 0.36
    wy = base - h * 0.68
    slots = [(x + w * 0.12, wy, ww, wh), (x + w * 0.88 - ww, wy, ww, wh)]
    for i, (a, b, c_, d) in enumerate(slots):
        if i in lit:
            m = s.mask()
            m.rect(a - 0.9, b - 0.9, a + c_ + 0.9, b + d + 0.9)
            s.paint(m, pale)
        else:
            dark_window(s, a, b, c_, d, pale)
        if i in boarded:
            m = s.mask()
            boards(m, a, b, c_, d, n=3, seed=seed)
            s.paint(m, pale * 0.95, rim=0.2, rim_dx=0, rim_dy=-0.5)
    dw = h * 0.27
    dx = x + w * 0.5 - dw / 2
    dt = base - h * 0.80
    m = s.mask()
    m.rect(dx - 0.9, dt - 0.9, dx + dw + 0.9, base)
    s.paint(m, pale)
    m = s.mask()
    m.rect(dx, dt, dx + dw, base)
    s.paint(m, "#05061a")

    # the fence, close in front; a hole at the door, the gate went years ago
    rng = np.random.default_rng(seed + 50)
    fh = h * 0.27
    fb = base + 2.2
    gap = (dx - dw * 0.5, dx + dw * 1.5)
    f = s.mask()
    pal = 3.2
    for a, b in ((x - 4, gap[0]), (gap[1], x + w + 4)):
        f.rect(a, fb - fh * 0.82, b, fb - fh * 0.74)
        f.rect(a, fb - fh * 0.30, b, fb - fh * 0.22)
        for xx in np.arange(a, b - pal * 0.5, pal):
            if rng.random() < 0.12:
                continue  # gone for firewood
            top = fh * rng.uniform(0.94, 1.03)
            f.spoly([(xx, fb), (xx, fb - top + 0.8), (xx + (pal - 0.9) / 2, fb - top), (xx + pal - 0.9, fb - top + 0.8), (xx + pal - 0.9, fb)])
    s.paint(f, wall * 0.78, rim=0.35, rim_dx=-0.3, rim_dy=-0.6)
    return slots


def paint():
    s = Scene("dusk", seed=11, horizon=104)
    s.sky(clouds=0.48, stars=0.85, glow_x=0.49, glow_w=0.20)
    s.moon(640, 30, 16, tint="#f6efdc", glow=0.5, seed=3)
    s.moon(690, 18, 8, tint="#a9c6ff", glow=0.45, seed=9)
    s.glow(VX + 8, VY - 2, 90, colour="#ffb26a", strength=0.28)
    # the keep and its hill, in the thickest of the haze
    s.ridge(102, 18, 83, "#6f4e68", roughness=3)
    m = s.mask()
    keep(m, VX + 2, 104, 0.82)
    s.paint(m, "#5e4664")
    s.fog(84, 108, strength=0.34, seed=6)
    s.ridge(104, 8, 89, "#3e3459", roughness=5)
    m = s.mask()
    for i, x in enumerate((252, 330, 410, 460)):
        gum_tree(m, x, 112, 34 + (i * 23) % 20, seed=140 + i, leaves=0.9)
    m.rect(0, 107, 1040, 148)
    s.paint(m, "#23244a", rim=0.12)

    # lawns: the dusk comes down them from the far end
    m = s.mask()
    m.spoly([(VX, VY), (1040, VY + 530 * 0.050), (1040, 148), (0, 148), (0, 138)])
    s.paint(m, "#4a4166", bottom="#16173a", top_y=108)

    # the houses, far to near; each a little bigger, nearer in tone, and sharper at the roofline
    ds = [20, 30, 45, 67, HOUSE_AT, 150, 210, 290]
    near = s.colour("#0c0e27")
    hazed = s.colour("#5f4c72")
    for d in ds:
        t = ((d - ds[0]) / (ds[-1] - ds[0])) ** 0.55
        tone = hazed * (1 - t) + near * t
        base = ground_at(d)
        h = d * (0.24 if d == HOUSE_AT else 0.2)
        w = h * 2.6
        x0 = VX + d
        if d >= 150:
            # the near ones are built, not cut out, and they're smaller and further down than they were
            slots = street_house(s, x0, base, w, h, tone, kind={150: "boards", 210: "fibro", 290: "boards"}[d],
                                 lit={150: (1,)}.get(d, ()), boarded={290: (0,)}.get(d, ()), seed=d)
            if d == 150:
                light_windows(s, [slots[1]], strength=0.42 + 0.58 * t)
            continue
        m = s.mask()
        house(m, x0, base, w, h, veranda=d >= 67, chimney=d >= 45, antenna=False)
        s.paint(m, tone, rim=0.16 + 0.34 * t, rim_dx=-0.8, rim_dy=-0.8)
        wh, ww = h * 0.30, h * 0.42
        wy = base - h * 0.60
        slots = [(x0 + w * 0.14, wy, ww, wh), (x0 + w * 0.70, wy, ww, wh)]
        # not every room's on: a street, not a Christmas display
        lit = {20: [1], 30: [0], 45: [1], 67: [0], HOUSE_AT: []}[d]
        light_windows(s, [slots[k] for k in lit], strength=0.42 + 0.58 * t, bars=d >= 67)

    # the popular house: everything on, front door included, and nobody's asleep
    base, h = ground_at(HOUSE_AT), HOUSE_AT * 0.24
    w = h * 2.6
    x0 = VX + HOUSE_AT
    wy = base - h * 0.84
    light_windows(s, [(x0 + w * 0.05, wy, 9, 7), (x0 + w * 0.25, wy, 9, 7), (x0 + w * 0.45, wy, 5, base - wy - 0.6), (x0 + w * 0.60, wy, 9, 7)], strength=1.0)
    s.glow(x0 + w * 0.5, base - 6, 40, colour="#ffb45e", strength=0.13)

    # the road, its kerb running out to the vanishing point
    corner = VX + (152 - VY) / KERB
    m = s.mask()
    m.spoly([(VX, VY), (corner, 152), (170, 152)])
    s.paint(m, "#14152f", bottom="#07081a", top_y=110)
    sheen = np.exp(-(((s.X / SS - VX - (s.Y / SS - VY) * 2.2) / (6 + (s.Y / SS - VY) * 2.2)) ** 2))
    s.rgb += (m.array() * sheen * 0.34)[..., None] * s.colour("#e08660")
    k = s.mask()
    k.stroke(np.array([(VX, VY), (corner, 152)]), 0.3, 1.3)
    s.paint(k, "#b58a86")

    # letterboxes on the nature strip, one per house, marching off down the kerb
    m = s.mask()
    for i, d in enumerate(ds[:-1]):
        if d == 150:
            continue  # the NO TICK picket stands here
        lx = VX + d * 1.15
        lb = VY + (lx - VX) * KERB - 0.6
        letterbox(m, lx, lb, max(3.5, d * 0.085), kind=(i * 2) % 3)
    s.paint(m, "#05061a", rim=0.5, rim_dx=-0.8, rim_dy=-0.7)

    # street lights down the kerb, the warm dots that make it somewhere you could walk home along
    for d in (36, 60, 88, 150, 210):
        lx = VX + d
        kerb = VY + d * KERB
        h = d * 0.33
        m = s.mask()
        pole = bez((lx, kerb + 1), (lx, kerb - h * 0.8), (lx, kerb - h), (lx - h * 0.16, kerb - h * 1.02), n=14)
        m.stroke(pole, max(0.5, h * 0.022), max(0.4, h * 0.014))
        s.paint(m, "#070922", rim=0.2)
        s.glow(lx - h * 0.16, kerb - h * 1.0, max(1.2, h * 0.05), strength=1.1)
        s.glow(lx - h * 0.16, kerb - h * 1.0, max(5, h * 0.26), strength=0.17)

    # the queue, patient as a pension day: down the kerb from the gate, all looking at the house
    m = s.mask()
    for d, slouch in ((101, 0.08), (108, 0.03), (115, 0.1), (122, 0.05), (130, 0.09), (138, 0.03)):
        x = VX + d
        hoodie(m, x, VY + d * KERB + 0.5, d * KERB * 0.95, facing=-1, slouch=slouch)
    s.paint(m, "#04051a", rim=0.7, rim_dx=-0.6, rim_dy=-0.6, rim_colour="#ffbe7a")

    # house rules, on a bit of cardboard wired to a star picket on the strip, just past the last of them,
    # and low: Residents' search box runs across y 92 to 116 from x 658
    m = s.mask()
    m.rect(713, 124, 714.8, 135)
    s.paint(m, "#0a0a20", rim=0.5, rim_dx=-0.5, rim_dy=0, rim_colour="#ffbe7a")
    m = s.mask()
    m.spoly([(686, 120.6), (742, 120), (743, 133), (687, 133.8)])
    s.paint(m, "#b89a68", rim=0.3, rim_dx=0, rim_dy=-0.5, rim_colour="#ffe0b0")
    m = s.mask()
    lettering(m, "NO TICK", 714.5, 126.8, 9, font=SCRAWL, angle=-1, wobble=0.4, seed=2)
    s.paint(m, "#14101a")

    # the heap, on the lawn further along: few bikes, fat lines, each cut out of the one behind it
    for x, y, r, tilt, f, tone, w in ((848, 125, 6.6, 15, 1, "#8e86ae", 1.3),
                                      (884, 126, 6.6, -11, -1, "#8e86ae", 1.3),
                                      (826, 130.5, 7, -5, 1, "#d6cee8", 1.5),
                                      (864, 131, 7, 6, -1, "#d6cee8", 1.5)):
        m = s.mask()
        bike(m, x, y, r, tilt=tilt, facing=f, width=w + 1.6)
        s.paint(m, "#0a0a22")
        m = s.mask()
        bike(m, x, y, r, tilt=tilt, facing=f, width=w)
        s.paint(m, tone)
    # the price tag on the lot, on its own stake
    m = s.mask()
    m.rect(932.5, 139, 934.5, 147)
    s.paint(m, "#0a0a20", rim=0.4, rim_dx=-0.5, rim_dy=0, rim_colour="#ffbe7a")
    m = s.mask()
    m.spoly([(906, 127), (961, 126), (962, 139), (907, 140)])
    s.paint(m, "#d6bd8a")
    m = s.mask()
    lettering(m, "$20 EA", 933.5, 133, 9, font=SCRAWL, angle=-1, wobble=0.4, seed=5)
    s.paint(m, "#14101a")

    # power poles on the far side of the road, the wires pulling the eye down the street
    m = s.mask()
    tops = []
    for z in (0.18, 0.27, 0.42, 0.72):
        px = VX - 14 / z * 0.32
        pb = VY + 2.0 / z * 1.6
        tops.append(power_pole(m, px, pb, 10.0 / z * 0.82))
    for a, b in zip(tops[:-1], tops[1:]):
        for k2 in (0, 3):
            wires(m, a[k2], b[k2], sag=2.0, width=0.4)
    s.paint(m, "#14132f")

    # the far verge drops into shadow behind the page title
    fade = np.clip((s.X / SS - 440) / 90, 0, 1)
    fade = 0.30 + 0.70 * fade * fade * (3 - 2 * fade)
    low = np.clip((s.Y / SS - 78) / 26, 0, 1)
    s.rgb = s.rgb * (1 - low * (1 - fade))[..., None]

    # dark left, so the title has a wall of night to sit on
    m = s.mask()
    gum_tree(m, 228, 178, 176, seed=19, lean=0.06)
    s.paint(m, "#03040b")
    return s.finish(bloom=0.4, vignette=0.24)
