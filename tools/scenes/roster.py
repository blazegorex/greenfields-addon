"""Residents: the street, seen along its length, shrinking toward a keep on the far hill. One house has
every light on and a queue down the kerb at 3am, and further along there's a heap of pushbikes, none of
them his. It's meant to feel like people live here, and some of them even do."""
import math

import numpy as np

from scenekit import SCRAWL, SS, Scene, bez, gum_tree, hoodie, house, lettering, light_windows, power_pole, wires

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
    ds = [20, 30, 45, 67, HOUSE_AT, 150, 225, 340]
    near = s.colour("#0c0e27")
    hazed = s.colour("#5f4c72")
    for d in ds:
        t = ((d - ds[0]) / (ds[-1] - ds[0])) ** 0.55
        tone = hazed * (1 - t) + near * t
        base = ground_at(d)
        h = d * (0.24 if d == HOUSE_AT else 0.2)
        w = h * 2.6
        x0 = VX + d
        m = s.mask()
        house(m, x0, base, w, h, veranda=d >= 67, chimney=d >= 45, antenna=d == 150)
        s.paint(m, tone, rim=0.16 + 0.34 * t, rim_dx=-0.8, rim_dy=-0.8)
        wh, ww = h * 0.30, h * 0.42
        wy = base - h * 0.60
        slots = [(x0 + w * 0.14, wy, ww, wh), (x0 + w * 0.70, wy, ww, wh)]
        # not every room's on: a street, not a Christmas display
        lit = {20: [1], 30: [0], 45: [1], 67: [0], HOUSE_AT: [], 150: [1], 225: [], 340: []}[d]
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

    # house rules, on a bit of cardboard wired to a star picket, just behind the last of them
    m = s.mask()
    m.rect(664.5, 121, 666, 140)
    m.rect(714, 121, 715.5, 139)
    s.paint(m, "#2a2740")
    m = s.mask()
    m.spoly([(660, 121.4), (719, 120.8), (720, 133), (661, 133.8)])
    s.paint(m, "#8f7650")
    m = s.mask()
    lettering(m, "NO TICK", 690, 127.4, 9, font=SCRAWL, angle=-1, wobble=0.4, seed=2)
    s.paint(m, "#14101a")

    # the heap, on the lawn further along: few bikes, fat lines, each cut out of the one behind it
    for x, y, r, tilt, f, tone, w in ((848, 122.5, 6.6, 15, 1, "#6d6590", 1.3),
                                      (884, 123.5, 6.6, -11, -1, "#6d6590", 1.3),
                                      (826, 129, 7, -5, 1, "#c8c0dc", 1.5),
                                      (864, 129.5, 7, 6, -1, "#c8c0dc", 1.5)):
        m = s.mask()
        bike(m, x, y, r, tilt=tilt, facing=f, width=w + 1.6)
        s.paint(m, "#0a0a22")
        m = s.mask()
        bike(m, x, y, r, tilt=tilt, facing=f, width=w)
        s.paint(m, tone)
    # the price tag on the lot
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
