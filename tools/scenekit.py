"""Procedural night-time scenes for the page banners: "Greenfields after dark".

A scene is painted back to front: sky, moons, far hills, mid-ground, foreground. Each layer
is a silhouette with a little haze and a rim of light from the horizon, the way a poster
artist would do it. It stays low in detail on purpose, so gold text reads over the top.

Coordinates are UI units at the window's default size: 1040 wide, 148 tall. It's stored as a
2048 x 256 texture, about 2 texels per UI unit like the rest of the art.

Who covers what, at the default window:
    y under 148   the page's cards start here, and the last few units fade out
    x under 233, y over 76   the sidebar
    x under 350, y under 76  the crest and road sign
    x over 800, y under 50   the online pill and the window's buttons
    x 250 to 530, y 86 to 132  the page title sits here: keep that area dark and quiet
    x 815 to 1015, y 92 to 116  page buttons on many pages: don't put the best bit behind them
So the subject lives in x 530 to 1020, y 40 to 148, standing on ground near y 140. Run with python -P.
"""
import math
import os

import cv2
import numpy as np
from PIL import Image, ImageDraw, ImageFont

W, H = 1040, 148
OUT_W, OUT_H = 2048, 256
SS = 4  # painted at this multiple, then area-averaged down for clean edges


def hexrgb(s):
    s = s.lstrip("#")
    return np.array([int(s[i:i + 2], 16) for i in (0, 2, 4)], np.float32) / 255.0


def smooth(a, b, x):
    t = np.clip((x - a) / max(1e-6, b - a), 0, 1)
    return t * t * (3 - 2 * t)


def gauss(a, sigma):
    return cv2.GaussianBlur(a, (0, 0), sigma) if sigma > 0 else a


def fbm(h, w, seed, cells=4, octaves=5, gain=0.55, stretch=1.0):
    """Fractal noise in 0..1; stretch > 1 makes long horizontal wisps."""
    rng = np.random.default_rng(seed)
    acc = np.zeros((h, w), np.float32)
    amp, tot = 1.0, 0.0
    for o in range(octaves):
        cy = max(2, int(cells * 2 ** o))
        cx = max(2, int(cells * 2 ** o * (w / h) / stretch))
        lat = rng.random((cy, cx), dtype=np.float32)
        acc += cv2.resize(lat, (w, h), interpolation=cv2.INTER_CUBIC) * amp
        tot += amp
        amp *= gain
    acc /= tot
    return (acc - acc.min()) / max(1e-6, acc.max() - acc.min())


# Colour moods. Top of sky is always dark so gold text reads; the horizon carries the colour.
MOODS = {
    # stops run from the top of the sky (0) to the horizon (1)
    "dusk": {"sky": [(0.00, "#060a18"), (0.34, "#0c1730"), (0.56, "#1b2a50"), (0.72, "#463d6c"),
                     (0.84, "#8e566d"), (0.93, "#d27c5f"), (1.00, "#f6b06f")],
             "far": "#3a3a60", "mid": "#1c2040", "near": "#090c18", "rim": "#f0a56a", "haze": "#c9786a"},
    "night": {"sky": [(0.00, "#050a18"), (0.36, "#0a1730"), (0.58, "#11274a"), (0.74, "#1d3d63"),
                      (0.88, "#37617e"), (1.00, "#6a97a4")],
              "far": "#1e3a55", "mid": "#10233c", "near": "#060b16", "rim": "#8fc6d4", "haze": "#3f6f88"},
    "ember": {"sky": [(0.00, "#090912"), (0.36, "#151228"), (0.58, "#2a1b37"), (0.74, "#5a2a3b"),
                      (0.88, "#a8483c"), (1.00, "#ef8f49")],
              "far": "#40243f", "mid": "#231429", "near": "#0b0810", "rim": "#ff9a50", "haze": "#a8483c"},
    "gum": {"sky": [(0.00, "#06100f"), (0.36, "#0b1e22"), (0.58, "#113137"), (0.74, "#234e4f"),
                    (0.88, "#5b886f"), (1.00, "#c8c58a")],
            "far": "#234a4a", "mid": "#12302f", "near": "#061110", "rim": "#d9cf8f", "haze": "#5d8a70"},
}


class Scene:
    def __init__(self, mood="dusk", seed=1, horizon=112):
        self.m = MOODS[mood] if isinstance(mood, str) else mood
        self.seed = seed
        self.hz = horizon
        self.w, self.h = W * SS, H * SS
        self.rgb = np.zeros((self.h, self.w, 3), np.float32)
        self.rng = np.random.default_rng(seed)
        ys = np.arange(self.h, dtype=np.float32)[:, None]
        self.Y = np.broadcast_to(ys, (self.h, self.w))
        xs = np.arange(self.w, dtype=np.float32)[None, :]
        self.X = np.broadcast_to(xs, (self.h, self.w))

    # ---------------------------------------------------------------- helpers
    def P(self, x, y):
        return (x * SS, y * SS)

    def mask(self):
        return Mask(self.w, self.h)

    def colour(self, c):
        return hexrgb(c) if isinstance(c, str) else np.asarray(c, np.float32)

    def tone(self, a, b, t):
        return self.colour(a) * (1 - t) + self.colour(b) * t

    # ---------------------------------------------------------------- sky
    def sky(self, clouds=0.5, stars=1.0, glow_x=0.68, glow_w=0.26):
        stops = self.m["sky"]
        ts = np.array([s[0] for s in stops], np.float32)
        cs = np.array([hexrgb(s[1]) for s in stops], np.float32)
        v = np.clip(self.Y / (self.hz * SS), 0, 1)
        # the horizon glow pools under one spot, right of the title, rather than running the width
        dx = (self.X / self.w - glow_x)
        pool = np.exp(-(dx * dx) / (2 * glow_w ** 2))
        v = v * (0.70 + 0.30 * pool)
        for i in range(3):
            self.rgb[..., i] = np.interp(v, ts, cs[:, i])
        if clouds > 0:
            n = fbm(self.h, self.w, self.seed + 11, cells=3, octaves=6, stretch=5.0)
            n2 = fbm(self.h, self.w, self.seed + 12, cells=5, octaves=5, stretch=7.0)
            c = smooth(0.50, 0.82, n * 0.7 + n2 * 0.3) * smooth(0.10, 0.50, self.Y / (self.hz * SS))
            c *= (1 - smooth(self.hz * SS * 0.96, self.hz * SS, self.Y))
            lit = self.colour(self.m["haze"]) * (0.25 + 0.75 * smooth(0.3, 1.0, self.Y / (self.hz * SS)))[..., None]
            a = (c * clouds)[..., None]
            self.rgb = self.rgb * (1 - a) + lit * a
        if stars > 0:
            self.stars(stars)

    def stars(self, amount=1.0):
        rng = np.random.default_rng(self.seed + 21)
        layer = np.zeros((self.h, self.w), np.float32)
        count = int(300 * amount)
        for _ in range(count):
            x = rng.integers(0, self.w)
            y = int(rng.random() ** 1.5 * self.hz * SS * 0.85)
            b = rng.random() ** 3.4
            layer[y, x] = max(layer[y, x], 0.22 + b * 1.7)
        soft = gauss(layer, 1.5) * 9.0
        fade = (1 - smooth(self.hz * SS * 0.30, self.hz * SS * 0.80, self.Y))
        tint = np.array([0.92, 0.95, 1.0], np.float32)
        self.rgb += (soft * fade)[..., None] * tint

    def moon(self, x, y, r, tint="#f4efe0", phase=0.0, glow=0.55, seed=3):
        """Moon disc with limb shading, faint seas, and a halo. phase>0 shades a crescent side."""
        cx, cy, R = x * SS, y * SS, r * SS
        d = np.sqrt((self.X - cx) ** 2 + (self.Y - cy) ** 2)
        disc = 1 - smooth(R - 1.2, R + 1.2, d)
        limb = np.sqrt(np.clip(1 - (d / max(1, R)) ** 2, 0, 1))
        n = fbm(self.h, self.w, seed, cells=30, octaves=4)
        seas = smooth(0.42, 0.7, n)
        lit = 0.74 + 0.26 * limb - seas * 0.16
        if phase > 0:
            sx = np.clip(((self.X - cx) / max(1, R) + phase * 1.2), -1, 1)
            lit *= 0.12 + 0.88 * smooth(-0.15, 0.25, sx)
        col = self.colour(tint)
        halo = np.exp(-(d / (R * 2.2)) ** 2) * glow * 0.55 + np.exp(-(d / (R * 6.0)) ** 2) * glow * 0.18
        self.rgb += (halo * (1 - disc))[..., None] * col
        self.rgb = self.rgb * (1 - disc[..., None]) + (lit * disc)[..., None] * col

    def glow(self, x, y, r, colour="#ffcf8a", strength=0.6):
        cx, cy, R = x * SS, y * SS, r * SS
        d2 = ((self.X - cx) ** 2 + (self.Y - cy) ** 2) / (R * R)
        self.rgb += (np.exp(-d2) * strength)[..., None] * self.colour(colour)

    def beam(self, x, y, angle, spread, length, colour="#ffd9a0", strength=0.3, soft=2.5):
        """Cone of light from a lamp at (x,y). angle in degrees, 90 points straight down."""
        cx, cy = x * SS, y * SS
        a = math.radians(angle)
        dx, dy = self.X - cx, self.Y - cy
        along = dx * math.cos(a) + dy * math.sin(a)
        across = -dx * math.sin(a) + dy * math.cos(a)
        width = np.maximum(1.0, along) * math.tan(math.radians(spread))
        cone = (1 - smooth(0.55, 1.0, np.abs(across) / width)) * (along > 0)
        fall = np.exp(-np.maximum(0, along) / (length * SS))
        out = gauss(cone * fall, soft * SS)
        self.rgb += (out * strength)[..., None] * self.colour(colour)

    def fog(self, y0, y1, colour=None, strength=0.5, seed=5, stretch=6.0):
        """Band of mist that thins toward its top and bottom edges."""
        c = self.colour(colour or self.m["haze"])
        n = fbm(self.h, self.w, self.seed + seed, cells=4, octaves=5, stretch=stretch)
        band = smooth(y0 * SS, (y0 + (y1 - y0) * 0.45) * SS, self.Y) * (1 - smooth((y0 + (y1 - y0) * 0.55) * SS, y1 * SS, self.Y))
        a = (band * (0.35 + 0.65 * n) * strength)[..., None]
        self.rgb = self.rgb * (1 - a) + c * a

    # ---------------------------------------------------------------- layers
    def paint(self, m, colour, bottom=None, rim=0.0, rim_dx=-1.0, rim_dy=-1.0, rim_colour=None, top_y=None):
        """Composites a silhouette. bottom: colour lower down. rim: light on the edge facing the sky."""
        a = m.array()
        top = self.colour(colour)
        if bottom is not None:
            bot = self.colour(bottom)
            y0 = (top_y if top_y is not None else self.hz - 40) * SS
            t = smooth(y0, y0 + 90 * SS, self.Y)[..., None]
            col = top * (1 - t) + bot * t
        else:
            col = top
        self.rgb = self.rgb * (1 - a[..., None]) + col * a[..., None]
        if rim > 0:
            shift = np.roll(np.roll(a, int(round(-rim_dy * SS)), axis=0), int(round(-rim_dx * SS)), axis=1)
            edge = np.clip(a - shift, 0, 1)
            edge = gauss(edge, 0.35 * SS) * a
            self.rgb += (edge * rim)[..., None] * self.colour(rim_colour or self.m["rim"])

    def ridge(self, base_y, amp, seed, colour, roughness=5, bottom=None, rim=0.0):
        """Far hills: a fractal ridge line."""
        n = fbm(4, self.w, seed, cells=2, octaves=roughness, stretch=0.2)[0]
        n = cv2.GaussianBlur(n[None, :], (0, 0), SS)[0]
        line = (base_y * SS - (n - 0.35) * amp * SS)
        m = self.mask()
        pts = [(0, self.h)] + [(x, float(line[x])) for x in range(0, self.w, 2)] + [(self.w, self.h)]
        m.poly(pts)
        self.paint(m, colour, bottom=bottom, rim=rim)

    # ---------------------------------------------------------------- finish
    def finish(self, path=None, bloom=0.35, grade=True, vignette=0.30):
        rgb = np.clip(self.rgb, 0, 4)
        if bloom > 0:
            br = np.clip(rgb - 0.62, 0, None)
            b = gauss(br, 6 * SS) * 0.7 + gauss(br, 18 * SS) * 0.6
            rgb = rgb + b * bloom
        if vignette > 0:
            xx = (self.X / self.w - 0.5) * 2
            v = 1 - vignette * np.clip(np.abs(xx) ** 2.4, 0, 1)
            rgb = rgb * v[..., None]
        if grade:
            # filmic-ish shoulder keeps glows from clipping into flat white
            rgb = rgb * (1 + rgb / 6.0) / (1 + rgb)
            rgb = rgb * 1.72
            lum = rgb.mean(axis=2, keepdims=True)
            rgb = lum + (rgb - lum) * 1.08
        small = cv2.resize(np.clip(rgb, 0, 1), (OUT_W, OUT_H), interpolation=cv2.INTER_AREA)
        rng = np.random.default_rng(self.seed + 99)
        small = small + (rng.random(small.shape, dtype=np.float32) - 0.5) * (1.6 / 255.0)
        img = Image.fromarray((np.clip(small, 0, 1) * 255 + 0.5).astype(np.uint8), "RGB")
        if path:
            img.save(path)
        return img


class Mask:
    """Big anti-aliased silhouette surface (S units per banner pixel)."""

    def __init__(self, w, h):
        self.w, self.h = w, h
        self.img = Image.new("L", (w, h), 0)
        self.d = ImageDraw.Draw(self.img)

    def array(self):
        return np.asarray(self.img, dtype=np.float32) / 255.0

    def poly(self, pts, fill=255):
        self.d.polygon([(float(p[0]), float(p[1])) for p in pts], fill=fill)

    def spoly(self, pts, fill=255):
        """Polygon in banner pixels."""
        self.poly([(p[0] * SS, p[1] * SS) for p in pts], fill)

    def rect(self, x0, y0, x1, y1, fill=255):
        self.d.rectangle((x0 * SS, y0 * SS, x1 * SS, y1 * SS), fill=fill)

    def rrect(self, x0, y0, x1, y1, r, fill=255):
        self.d.rounded_rectangle((x0 * SS, y0 * SS, x1 * SS, y1 * SS), radius=r * SS, fill=fill)

    def ellipse(self, cx, cy, rx, ry, fill=255):
        self.d.ellipse(((cx - rx) * SS, (cy - ry) * SS, (cx + rx) * SS, (cy + ry) * SS), fill=fill)

    def line(self, pts, width, fill=255):
        ps = [(p[0] * SS, p[1] * SS) for p in pts]
        self.d.line(ps, fill=fill, width=max(1, int(round(width * SS))), joint="curve")

    def stroke(self, pts, w0, w1=None, fill=255):
        """Tapered stroke along banner-pixel points."""
        pts = np.asarray(pts, float)
        w1 = w0 if w1 is None else w1
        widths = np.linspace(w0, w1, len(pts))
        d = np.gradient(pts, axis=0)
        d /= np.maximum(1e-6, np.linalg.norm(d, axis=1, keepdims=True))
        nrm = np.stack((-d[:, 1], d[:, 0]), axis=1)
        a = pts + nrm * widths[:, None] / 2
        b = pts - nrm * widths[:, None] / 2
        self.spoly(np.concatenate((a, b[::-1])), fill)


def lit_rim(s, m, lx, ly, reach, colour, strength, soft=0.45):
    """Light catching only the edges of silhouette m that face a point, fading with distance from it."""
    a = m.array()
    b = gauss(a, soft * SS)
    gx = cv2.Sobel(b, cv2.CV_32F, 1, 0, ksize=3)
    gy = cv2.Sobel(b, cv2.CV_32F, 0, 1, ksize=3)
    dx, dy = lx * SS - s.X, ly * SS - s.Y
    dist = np.sqrt(dx * dx + dy * dy) + 1
    facing = np.clip(-(gx * dx + gy * dy) / dist * 2.2, 0, 1) * a
    s.rgb += (facing * np.exp(-(dist / (reach * SS)) ** 2) * strength)[..., None] * s.colour(colour)


def bez(p0, p1, p2, p3=None, n=24):
    t = np.linspace(0, 1, n)[:, None]
    p0, p1, p2 = np.array(p0, float), np.array(p1, float), np.array(p2, float)
    if p3 is None:
        return (1 - t) ** 2 * p0 + 2 * (1 - t) * t * p1 + t ** 2 * p2
    p3 = np.array(p3, float)
    return (1 - t) ** 3 * p0 + 3 * (1 - t) ** 2 * t * p1 + 3 * (1 - t) * t ** 2 * p2 + t ** 3 * p3


# --------------------------------------------------------------------------- props
def gum_tree(m, x, base, height, seed=1, lean=0.0, spread=1.0, leaves=1.0, trunk=None):
    """Scraggly eucalypt: pale forked trunk, open crown of drooping leaf clumps."""
    rng = np.random.default_rng(seed)
    tw = trunk if trunk is not None else max(1.6, height * 0.05)

    def branch(p, angle, length, width, depth):
        steps = 6
        pts = [p]
        a = angle
        q = np.array(p, float)
        for _ in range(steps):
            a += rng.normal(0, 0.13)
            q = q + np.array([math.cos(a), math.sin(a)]) * length / steps
            pts.append(q.copy())
        m.stroke(np.array(pts), width, width * 0.62)
        end = pts[-1]
        if depth <= 0 or length < height * 0.09:
            clump(end, length)
            return
        kids = 2 + (rng.random() < 0.35)
        for k in range(kids):
            off = (k - (kids - 1) / 2) * rng.uniform(0.45, 0.8) * spread + rng.normal(0, 0.12)
            branch(end, a + off, length * rng.uniform(0.62, 0.8), width * 0.62, depth - 1)
        if rng.random() < 0.5:
            clump(pts[len(pts) // 2], length * 0.6)

    def clump(c, size):
        n = int(rng.integers(16, 26) * leaves)
        r = max(3.0, height * 0.075) * rng.uniform(0.8, 1.2)
        for _ in range(n):
            a = rng.uniform(0, 2 * math.pi)
            d = rng.random() ** 0.6 * r
            px = c[0] + math.cos(a) * d * 1.25
            py = c[1] + math.sin(a) * d * 0.75
            # drooping sickle leaf
            ll = rng.uniform(height * 0.018, height * 0.038) + 1.2
            drop = rng.uniform(0.9, 1.9)
            lean_l = rng.choice((-1, 1)) * rng.uniform(0.15, 0.8)
            q0 = (px, py)
            q1 = (px + lean_l * ll * 0.5, py + drop * ll * 0.45)
            q2 = (px + lean_l * ll * 0.8, py + drop * ll)
            m.stroke(bez(q0, q1, q2, n=6), max(0.6, ll * 0.2), 0.25)

    branch((x, base), -math.pi / 2 + lean, height * 0.40, tw, 4)


def pine(m, x, base, height, seed=1):
    rng = np.random.default_rng(seed)
    w = height * 0.26
    tiers = int(max(5, height / 7))
    for i in range(tiers):
        t = i / tiers
        y = base - height * 0.12 - t * height * 0.86
        hw = w * (1 - t) ** 0.85 + 0.6
        jag = rng.uniform(-0.8, 0.8)
        m.spoly([(x - hw, y + jag), (x + hw, y - jag), (x, y - height * 0.2)])
    m.rect(x - height * 0.015, base - height * 0.2, x + height * 0.015, base)


def power_pole(m, x, base, height):
    w = max(1.0, height * 0.016)
    m.spoly([(x - w, base), (x - w * 0.6, base - height), (x + w * 0.6, base - height), (x + w, base)])
    arm = height * 0.14
    m.rect(x - arm, base - height * 0.94, x + arm, base - height * 0.94 + max(0.9, height * 0.012))
    m.rect(x - arm * 0.75, base - height * 0.84, x + arm * 0.75, base - height * 0.84 + max(0.8, height * 0.01))
    for dx in (-arm, -arm * 0.4, arm * 0.4, arm):
        m.rect(x + dx - 0.35, base - height * 0.97, x + dx + 0.35, base - height * 0.94)
    # brace
    m.line([(x - arm * 0.5, base - height * 0.93), (x, base - height * 0.86), (x + arm * 0.5, base - height * 0.93)], 0.5)
    return [(x + dx, base - height * 0.97) for dx in (-arm, -arm * 0.4, arm * 0.4, arm)]


def wires(m, a, b, sag=7.0, width=0.5):
    """Sagging power line between two points."""
    a, b = np.array(a, float), np.array(b, float)
    t = np.linspace(0, 1, 30)
    pts = a[None, :] * (1 - t[:, None]) + b[None, :] * t[:, None]
    pts[:, 1] += sag * 4 * t * (1 - t)
    m.line([tuple(p) for p in pts], width)


def house(m, x, base, w, h, roof=None, pitch=0.42, veranda=True, chimney=True, antenna=True, tank=False):
    """Low fibro cottage. Returns window rects so they can be lit afterwards."""
    roof = roof if roof is not None else h * 0.62
    m.rect(x, base - h, x + w, base)
    over = w * 0.05
    m.spoly([(x - over, base - h), (x + w * 0.22, base - h - roof * pitch * 2), (x + w * 0.78, base - h - roof * pitch * 2), (x + w + over, base - h)])
    if chimney:
        cx = x + w * 0.72
        m.rect(cx, base - h - roof * pitch * 2 - h * 0.28, cx + w * 0.05, base - h - roof * pitch * 0.8)
    if antenna:
        ax = x + w * 0.34
        top = base - h - roof * pitch * 2
        m.line([(ax, top), (ax, top - h * 0.65)], 0.5)
        for k in range(4):
            yy = top - h * 0.65 + k * h * 0.09
            hw = h * (0.2 - k * 0.03)
            m.line([(ax - hw, yy), (ax + hw, yy)], 0.4)
    if veranda:
        vy = base - h * 0.72
        m.spoly([(x - w * 0.09, vy), (x + w * 1.09, vy), (x + w * 1.0, vy - h * 0.15), (x, vy - h * 0.15)])
        for k in range(5):
            px = x - w * 0.07 + k * (w * 1.14) / 4
            m.rect(px, vy, px + 0.8, base)
        m.rect(x - w * 0.08, base - h * 0.2, x + w * 1.08, base - h * 0.17)
    if tank:
        m.rrect(x + w * 1.1, base - h * 0.85, x + w * 1.1 + h * 0.6, base, 1.2)
    return x, base, w, h


def light_windows(s, rects, colour="#ffb45e", strength=1.0, bars=True):
    """Warm windows with a soft glow and dark glazing bars. rects: (x, y, w, h) in UI units."""
    m = s.mask()
    bar = s.mask()
    for (x, y, w, h) in rects:
        m.rect(x, y, x + w, y + h)
        if bars:
            bar.rect(x + w / 2 - 0.3, y, x + w / 2 + 0.3, y + h)
            bar.rect(x, y + h * 0.42 - 0.25, x + w, y + h * 0.42 + 0.25)
    a = m.array()
    col = s.colour(colour)
    s.rgb = s.rgb * (1 - a[..., None]) + (col * 1.05)[None, None, :] * (a * strength)[..., None]
    b = bar.array() * a
    s.rgb = s.rgb * (1 - b[..., None] * 0.86)
    s.rgb += gauss(a, 3 * SS)[..., None] * col * 0.42 * strength
    s.rgb += gauss(a, 12 * SS)[..., None] * col * 0.34 * strength


# --------------------------------------------------------------------------- what the street's left out
FONTS = r"C:\Windows\Fonts"
STENCIL = "impact.ttf"      # shop signs, hand-cut stencils
SCRAWL = "segoeprb.ttf"     # spray can and marker pen


def lettering(m, text, x, y, size, font=STENCIL, angle=0.0, wobble=0.0, seed=1, spacing=0.0):
    """Words in a mask, centred on (x, y). Size is roughly the height of the capitals in UI units.
    wobble knocks each letter about, for anything done by hand. The game never sees the font: it
    only sees the finished picture."""
    f = ImageFont.truetype(os.path.join(FONTS, font), max(4, int(round(size * 1.36 * SS))))
    rng = np.random.default_rng(seed)
    advances = [f.getlength(c) + spacing * SS for c in text]
    total = sum(advances)
    pad = int(size * SS * 2.5)
    tile = Image.new("L", (int(total) + pad * 2, pad * 2), 0)
    cur = pad
    for c, adv in zip(text, advances):
        ch = Image.new("L", tile.size, 0)
        ImageDraw.Draw(ch).text((cur, pad + (rng.normal(0, wobble) * size * SS * 0.08 if wobble else 0)), c, font=f, fill=255, anchor="lm")
        if wobble:
            ch = ch.rotate(float(rng.normal(0, wobble) * 7), resample=Image.BICUBIC, center=(cur + adv / 2, pad))
        tile.paste(255, (0, 0), ch)
        cur += adv
    if angle:
        tile = tile.rotate(-angle, resample=Image.BICUBIC, expand=True)
    m.img.paste(255, (int(x * SS - tile.width / 2), int(y * SS - tile.height / 2)), tile)


def neon(s, text, x, y, size, colour="#ff3b6b", font=STENCIL, strength=1.0, spacing=0.0, core=0.75):
    """A lit sign: hot core, coloured bloom on the wall behind it."""
    m = s.mask()
    lettering(m, text, x, y, size, font=font, spacing=spacing)
    a = m.array()
    col = s.colour(colour)
    white = np.array([1.0, 1.0, 1.0], np.float32)
    hot = col * (1 - core) + white * core
    s.rgb = s.rgb * (1 - a[..., None]) + hot * (a * (0.72 + 0.28 * strength))[..., None]
    s.rgb += gauss(a, 1.2 * SS)[..., None] * col * 0.75 * strength
    s.rgb += gauss(a, 6.0 * SS)[..., None] * col * 0.55 * strength
    s.rgb += gauss(a, 18.0 * SS)[..., None] * col * 0.42 * strength


def glass_pipe(s, x, y, length, angle=-80.0, bulb=None, width=None, smoke=0.8, ember=0.0, seed=2, lit="#d9f2ff"):
    """The neighbourhood's coat of arms: a long thin straight tube from the mouth end at (x, y), going
    off at angle degrees (-90 is straight up), ending in a small round blown bulb with a hole in the top
    and soot in the bottom half. Glass has no silhouette, only edges and glints, so you see the
    background through it. It wants to be long: length 40 or more, bulb radius about length / 8, or
    it stops being a pipe and turns into a key or a lollipop. So a bulb past length * 0.15, or a stem
    past 2.6 units and half the bulb, is pulled back to that whatever the caller asked for."""
    bulb = min(bulb if bulb is not None else length * 0.125, length * 0.15)
    width = min(width if width is not None else max(2.0, bulb * 0.42), 2.6, bulb * 0.5)
    a = math.radians(angle)
    d = np.array([math.cos(a), math.sin(a)])
    n = np.array([-d[1], d[0]])
    p0 = np.array([x, y], float)
    c = p0 + d * length
    up = np.array([0.0, -1.0])
    # one clean piece of glass: the stem, flaring into the bulb the way it does when it's blown
    m = s.mask()
    m.stroke(np.array([p0, c - d * bulb * 1.2]), width, width)
    m.stroke(np.array([c - d * bulb * 1.8, c - d * bulb * 0.6]), width, width * 1.9)
    m.ellipse(c[0], c[1], bulb, bulb)
    glass = m.array()
    kernel = lambda t: cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (2 * t + 1, 2 * t + 1))
    edge_t = max(2, int(round(0.52 * SS)))
    inner = cv2.erode(glass, kernel(edge_t))
    halo = np.clip(cv2.dilate(glass, kernel(max(1, int(round(0.34 * SS))))) - glass, 0, 1)
    tint = s.colour(lit)
    # a dark hairline outside, so it still holds across a moon or a bright wall
    s.rgb = s.rgb * (1 - halo[..., None] * 0.8)
    # inside's nearly clear; only a breath of light, so it's got a body and the soot has something to sit against
    s.rgb = s.rgb * (1 - inner[..., None] * 0.10) + tint * (inner * 0.06)[..., None]
    b = s.mask()
    b.ellipse(c[0], c[1], bulb, bulb)
    ba = cv2.erode(b.array(), kernel(edge_t))
    s.rgb = s.rgb * (1 - ba[..., None] * 0.10) + tint * (ba * 0.20)[..., None]
    # soot: burnt on, heaviest at the very bottom and smudging out unevenly up the sides. Not a level
    # line across, or it's a flask with something in it
    rng = np.random.default_rng(seed + 31)
    soot = s.mask()
    soot.ellipse(c[0], c[1] + bulb * 0.66, bulb * 0.90, bulb * 0.50)
    for _ in range(3):
        sx = rng.uniform(-0.62, 0.62) * bulb
        soot.ellipse(c[0] + sx, c[1] + rng.uniform(0.18, 0.36) * bulb, bulb * rng.uniform(0.18, 0.28), bulb * rng.uniform(0.14, 0.24))
    sa = gauss(soot.array(), bulb * 0.11 * SS) * ba
    s.rgb = s.rgb * (1 - sa[..., None] * 0.93) + s.colour("#0a0807") * (sa * 0.93)[..., None]
    # the outline: thin and bright. No bands, no notches, nothing across the stem
    edge_a = np.clip(glass - inner, 0, 1)
    s.rgb = s.rgb * (1 - edge_a[..., None] * 0.96) + tint * (edge_a * 0.96)[..., None]
    # the specular: one long streak up the stem, stopping short of both ends, and a crescent on the bulb
    g = s.mask()
    g.stroke(np.array([p0 + d * length * 0.34 + n * width * 0.10, p0 + d * length * 0.66 + n * width * 0.10]), width * 0.24, width * 0.24)
    arc = [c + bulb * 0.62 * np.array([math.cos(t), math.sin(t)]) for t in np.linspace(math.radians(195), math.radians(262), 10)]
    g.stroke(np.array(arc), bulb * 0.17, bulb * 0.17)
    ga = gauss(g.array(), 0.10 * SS)
    s.rgb = s.rgb * (1 - ga[..., None]) + np.array([1.0, 1.0, 1.0], np.float32) * ga[..., None]
    s.rgb += gauss(ga, 1.3 * SS)[..., None] * tint * 0.22
    # the hole in the top of the bulb: a small dark oval just under the crown, ringed bright, so it's a
    # hole in the glass and not a bead sitting on it
    tip = c + up * bulb * 0.97
    hc = c + up * bulb * 0.70
    hr = max(0.8, bulb * 0.21)
    lip = s.mask()
    lip.ellipse(hc[0], hc[1], hr * 1.45, hr * 0.98)
    la = lip.array()
    s.rgb = s.rgb * (1 - la[..., None]) + tint * la[..., None]
    h = s.mask()
    h.ellipse(hc[0], hc[1], hr, hr * 0.55)
    ha = h.array()
    s.rgb = s.rgb * (1 - ha[..., None]) + s.colour("#05070c") * ha[..., None]
    if ember > 0:
        s.glow(c[0], c[1] + bulb * 0.1, bulb * 1.4, colour="#ff8a3c", strength=0.55 * ember)
        s.glow(c[0], c[1] + bulb * 0.45, bulb * 0.5, colour="#ffd08a", strength=0.75 * ember)
    if smoke > 0:
        # a single thin thread that curls as it climbs, out of the hole and gone
        rng = np.random.default_rng(seed)
        rise = max(14.0, bulb * 5.2) * max(0.5, smoke)
        side = rng.choice((-1.0, 1.0))
        amp = bulb * rng.uniform(0.55, 0.8)
        t = np.linspace(0, 1, 60)
        pts = np.stack((tip[0] + side * amp * (t ** 0.8) * np.sin(t * 7.4), tip[1] + bulb * 0.2 - rise * t), axis=1)
        w = s.mask()
        w.stroke(pts, 0.72, 1.05)
        wa = gauss(w.array(), 0.16 * SS)
        fade = np.clip((s.Y - (tip[1] - rise) * SS) / (rise * 0.8 * SS), 0, 1)
        s.rgb = s.rgb + (wa * fade * 0.62 * smoke)[..., None] * s.colour("#e6edf2")


def lighter(t, x, y, length=15.0, standing=False, facing=1, tilt=0.0, colour="#e2472f", hood="#aeb4ba", dark="#1a1c20"):
    """A cheap disposable lighter, no name on it: flat plastic body, a tin hood with the wheel
    on top, the kind that's in every pocket and never the one you bought. t is a Scene, which paints it
    in flat colours, or a Mask, which just takes its shape. (x, y) is where it meets the ground: the
    foot of the body when lying down (it runs off along facing, hood at the far end), the middle of
    its base when standing. Beside a pipe it should be about a third of the pipe's length, 13 to 18."""
    wd = length * 0.34
    a = math.radians(-90.0 + tilt if standing else (tilt if facing > 0 else 180.0 - tilt))
    u = np.array([math.cos(a), math.sin(a)])
    v = np.array([-u[1], u[0]])
    if v[0] < -1e-6 if standing else v[1] > 0:
        v = -v  # v points up the lying lighter's side, or to the right of a standing one
    o = np.array([x, y], float) + (np.zeros(2) if standing else np.array([0.0, -wd / 2]))

    def box(u0, u1, v0, v1):
        return [tuple(o + u * (p * length) + v * (q * wd)) for p, q in ((u0, v0), (u1, v0), (u1, v1), (u0, v1))]

    body = box(0.0, 0.70, -0.5, 0.5)
    tin = box(0.70, 1.0, -0.44, 0.44)
    if isinstance(t, Mask):
        t.spoly(body)
        t.spoly(tin)
        return
    m = t.mask()
    m.spoly(body)
    m.spoly(tin)
    edge = cv2.dilate(m.array(), np.ones((3, 3), np.uint8), iterations=max(1, int(0.3 * SS))) - m.array()
    t.rgb = t.rgb * (1 - np.clip(edge, 0, 1)[..., None] * 0.6)
    m = t.mask()
    m.spoly(body)
    t.paint(m, colour)
    # light down one side of the plastic
    m = t.mask()
    m.spoly(box(0.06, 0.64, 0.14, 0.30))
    la = m.array()
    t.rgb = t.rgb * (1 - la[..., None] * 0.45) + np.array([1.0, 1.0, 1.0], np.float32) * (la * 0.45)[..., None]
    # the tin hood, with the dark slot the wheel sits in
    m = t.mask()
    m.spoly(tin)
    t.paint(m, hood)
    m = t.mask()
    m.spoly(box(0.70, 0.735, -0.44, 0.44))
    m.spoly(box(0.80, 0.95, -0.20, 0.20))
    t.paint(m, dark)


def trolley(m, x, base, h, facing=1, tip=0.0, width=None):
    """Shopping trolley, side on, h tall at the push bar. tip tilts it about the front wheels, in degrees;
    90 is on its side, where they all end up. Wire basket, low chassis, four little castors."""
    lw = width if width is not None else max(0.35, h * 0.024)
    t = math.radians(tip) * facing
    ca, sa = math.cos(t), math.sin(t)

    def P(u, v):
        # u runs from the front wheels back toward the push bar; v is up
        px, py = -u * h * facing, -v * h
        return (x + px * ca - py * sa, base + px * sa + py * ca)

    # basket: wider at the top, deep at the back
    rim = [(0.06, 0.74), (1.02, 0.86)]
    floor = [(0.18, 0.34), (0.92, 0.34)]
    for k in np.linspace(0, 1, 7):
        top = (rim[0][0] + (rim[1][0] - rim[0][0]) * k, rim[0][1] + (rim[1][1] - rim[0][1]) * k)
        bot = (floor[0][0] + (floor[1][0] - floor[0][0]) * k, floor[0][1])
        m.line([P(*top), P(*bot)], lw * 0.7)
    for k in np.linspace(0, 1, 4):
        a = (floor[0][0] + (rim[0][0] - floor[0][0]) * k, floor[0][1] + (rim[0][1] - floor[0][1]) * k)
        b = (floor[1][0] + (rim[1][0] - floor[1][0]) * k, floor[1][1] + (rim[1][1] - floor[1][1]) * k)
        m.line([P(*a), P(*b)], lw * (1.5 if k == 1 else 0.7))
    m.line([P(*floor[0]), P(*floor[1])], lw * 1.3)
    # push bar, chassis and legs
    m.line([P(1.02, 0.86), P(1.16, 1.0)], lw * 1.4)
    m.line([P(1.10, 1.0), P(1.20, 1.0)], lw * 2.2)
    m.line([P(0.10, 0.08), P(1.0, 0.13)], lw * 1.5)
    m.line([P(0.18, 0.34), P(0.12, 0.08)], lw * 1.2)
    m.line([P(0.92, 0.34), P(0.98, 0.13)], lw * 1.2)
    for u, v in ((0.12, 0.035), (0.98, 0.05)):
        cx, cy = P(u, v)
        m.ellipse(cx, cy, h * 0.045, h * 0.045)


def wreck(m, x, base, length, facing=1, bonnet=True, bricks=True):
    """A burnt-out Commodore: three boxes on bare rims, the glass long gone, so you see straight
    through it. Nothing else on the street has this outline. Draws solid, then cuts the holes."""
    L = length
    f = facing

    def P(u, v):  # u forward from the tail, v up from the road
        return (x + (u - 0.5) * L * f, base - v * L)

    sill = 0.085
    body = [(0.0, sill + 0.01), (0.0, 0.205), (0.03, 0.215), (0.205, 0.225), (0.285, 0.325), (0.555, 0.33), (0.665, 0.225),
            (0.96, 0.205), (1.0, 0.185), (1.0, sill)]
    m.spoly([P(*p) for p in body])
    # bare rims sitting on the road or on bricks, and the arches burnt out over them
    wheels = (0.2, 0.79)
    for u in wheels:
        cx, cy = P(u, 0.082)
        m.ellipse(cx, cy, L * 0.082, L * 0.082, fill=0)
    if bricks:
        bx, by = P(wheels[0], 0.0)
        m.rect(bx - L * 0.045, by - L * 0.05, bx + L * 0.045, by)
    cx, cy = P(wheels[1], 0.056)
    m.ellipse(cx, cy, L * 0.056, L * 0.056)
    m.ellipse(cx, cy, L * 0.032, L * 0.032, fill=0)
    m.ellipse(cx, cy, L * 0.012, L * 0.012)
    if bricks:
        cx, cy = P(wheels[0], 0.05 + 0.046)
        m.ellipse(cx, cy, L * 0.05, L * 0.05)
        m.ellipse(cx, cy, L * 0.028, L * 0.028, fill=0)
    # no glass left: windows are holes
    for win in ([(0.235, 0.232), (0.298, 0.308), (0.405, 0.31), (0.405, 0.232)],
                [(0.425, 0.232), (0.425, 0.31), (0.548, 0.312), (0.63, 0.232)]):
        m.spoly([P(*p) for p in win], fill=0)
    if bonnet:
        # bonnet hanging open, hinged at the windscreen
        m.spoly([P(0.665, 0.225), P(0.675, 0.232), P(0.885, 0.355), P(0.875, 0.34)])
        m.line([P(0.665, 0.226), P(0.88, 0.348)], L * 0.012)


def hoodie(m, x, base, h, facing=1, slouch=0.05, hands="pockets"):
    """Someone in a hoodie and trackies who's got nowhere to be. Solid silhouette, h tall, stands on
    (x, base), hood up, shoulders down. hands: pockets, or free if you're drawing the arms yourself."""
    f = facing

    def P(u, v):  # u forward, v up, both as a fraction of h; the top half hangs forward a bit
        return (x + (u + slouch * max(0.0, v - 0.45) * 2.0) * h * f, base - v * h)

    # skinny trackies, one foot out
    m.spoly([P(-0.1, 0.5), P(0.0, 0.5), P(-0.018, 0.03), P(-0.078, 0.03), P(-0.098, 0.26)])
    m.spoly([P(-0.012, 0.5), P(0.1, 0.5), P(0.098, 0.26), P(0.09, 0.03), P(0.03, 0.03), P(0.016, 0.26)])
    # runners
    m.spoly([P(-0.086, 0.05), P(-0.016, 0.05), P(0.038, 0.016), P(0.038, 0.0), P(-0.088, 0.0)])
    m.spoly([P(0.03, 0.05), P(0.095, 0.05), P(0.15, 0.016), P(0.15, 0.0), P(0.028, 0.0)])
    # the jumper, baggy, hem down past the hips
    body = bez(P(-0.055, 0.83), P(-0.135, 0.8), P(-0.135, 0.62), P(-0.112, 0.45), n=10).tolist()
    body += [P(0.112, 0.45)]
    body += bez(P(0.112, 0.45), P(0.135, 0.62), P(0.135, 0.8), P(0.055, 0.83), n=10).tolist()
    m.spoly(body)
    if hands == "pockets":
        # one arm hanging, the elbow out a touch and the hand gone in the front pocket
        arm = bez(P(0.09, 0.79), P(0.158, 0.7), P(0.14, 0.58), P(0.055, 0.53), n=10)
        m.stroke(np.array(arm), h * 0.058, h * 0.05)
    # hood: narrow, a bit of a peak, pushed forward; no face to see
    hood = bez(P(-0.07, 0.81), P(-0.098, 0.92), P(-0.05, 1.0), P(0.02, 1.0), n=12).tolist()
    hood += bez(P(0.02, 1.0), P(0.078, 0.985), P(0.104, 0.93), P(0.088, 0.875), n=8).tolist()
    hood += [P(0.07, 0.81)]
    m.spoly(hood)


def staffy(m, x, base, h, facing=1):
    """Staffy, side on, standing square: all chest and head on four short legs. Solid silhouette, h tall
    at the ear, about 1.4 h long."""
    f = facing

    def P(u, v):
        return (x + u * h * f, base - v * h)

    # barrel chest, narrow waist, solid rump
    body = bez(P(-0.62, 0.62), P(-0.3, 0.72), P(-0.02, 0.72), P(0.22, 0.8), n=10).tolist()
    body += bez(P(0.22, 0.8), P(0.42, 0.68), P(0.38, 0.36), P(0.16, 0.26), n=10).tolist()
    body += bez(P(0.16, 0.26), P(-0.06, 0.26), P(-0.3, 0.42), P(-0.48, 0.34), n=8).tolist()
    body += bez(P(-0.48, 0.34), P(-0.68, 0.34), P(-0.74, 0.5), P(-0.62, 0.62), n=8).tolist()
    m.spoly(body)
    # front legs straight and thick, back legs with a hock
    for x0, x1, w in ((0.24, 0.25, 0.115), (0.07, 0.07, 0.105)):
        m.stroke(np.array([P(x0, 0.4), P(x1, 0.03)]), h * w, h * w * 0.9)
        m.rrect(min(P(x1 - 0.06, 0)[0], P(x1 + 0.09, 0)[0]), base - h * 0.05, max(P(x1 - 0.06, 0)[0], P(x1 + 0.09, 0)[0]), base, h * 0.02)
    for x0 in (-0.5, -0.63):
        m.stroke(np.array(bez(P(x0, 0.46), P(x0 - 0.12, 0.28), P(x0 + 0.02, 0.16), P(x0 - 0.02, 0.03), n=8)), h * 0.125, h * 0.08)
        m.rrect(min(P(x0 - 0.08, 0)[0], P(x0 + 0.07, 0)[0]), base - h * 0.05, max(P(x0 - 0.08, 0)[0], P(x0 + 0.07, 0)[0]), base, h * 0.02)
    # short whip of a tail
    m.stroke(np.array(bez(P(-0.66, 0.58), P(-0.78, 0.6), P(-0.86, 0.72), n=8)), h * 0.055, h * 0.02)
    # the head is the point: wide skull, cheeks, short square muzzle, ears folded back
    m.ellipse(*P(0.4, 0.8), h * 0.19, h * 0.17)
    m.spoly([P(0.42, 0.88), P(0.72, 0.8), P(0.74, 0.62), P(0.62, 0.56), P(0.36, 0.6)])
    m.spoly([P(0.3, 0.9), P(0.22, 1.0), P(0.42, 0.96)])


def razor_wire(m, x0, x1, y, r=5.0, step=None, width=0.42):
    """Coil along the top of a fence, one long spiral with barbs on it."""
    step = step if step is not None else r * 1.15
    turns = (x1 - x0) / step
    th = np.linspace(0, turns * 2 * math.pi, int(turns * 28) + 2)
    xs = x0 + th / (2 * math.pi) * step + r * np.cos(th) * 0.92
    ys = y + r * np.sin(th)
    m.line(list(zip(xs.tolist(), ys.tolist())), width)
    for i in range(0, len(th), 9):
        c, sn = math.cos(th[i] + 0.8), math.sin(th[i] + 0.8)
        m.line([(xs[i] - c * 1.15, ys[i] - sn * 1.15), (xs[i] + c * 1.15, ys[i] + sn * 1.15)], width * 1.15)


def foil_window(s, x, y, w, h, seed=1, strength=1.0):
    """A window done from the inside with kitchen foil. At about 33 by 22 pixels the only thing that says
    foil is how it shines, so it's a few soft wavy bands of silver with a little crumple on top, behind
    a dark frame and a middle bar so it's plainly still a window. Fine crumple goes to noise at this size,
    blotches to camouflage, and hard facets to a missing-image icon. Under about 20 units wide it can't
    say foil at all, so it stays a quiet dull silver: the job there is not looking like a graphics bug."""
    rng = np.random.default_rng(seed + 400)
    x0, y0 = int(x * SS), int(y * SS)
    pw, ph = max(1, int(w * SS)), max(1, int(h * SS))

    def soft(sigma):
        n = gauss(rng.random((ph, pw)).astype(np.float32), sigma * SS)
        return (n - n.mean()) / (n.std() + 1e-6)

    yy, xx = np.mgrid[0:ph, 0:pw].astype(np.float32) / SS
    phase = (xx * 0.8 + yy * 0.6) / 8.0 * 2 * np.pi + soft(2.4) * 1.5 + rng.uniform(0, 6.28)
    big = float(np.clip((w - 16) / 8, 0, 1))
    v = (0.46 + 0.14 * big) + (0.11 + 0.19 * big) * np.sin(phase) + (0.03 + 0.10 * big) * soft(0.8)
    v = v + np.clip(v - 0.82, 0, 1) * 1.4 * big
    v = np.clip(v, 0.22, 1.25) * np.linspace(1.05, 0.88, ph, dtype=np.float32)[:, None]
    col = np.array([0.80, 0.84, 0.90], np.float32)
    s.rgb[y0:y0 + ph, x0:x0 + pw] = col * (v * strength)[..., None]
    m = s.mask()
    m.rect(x, y, x + w, y + h)
    s.rgb += gauss(m.array(), 2.2 * SS)[..., None] * col * 0.06 * strength
    f = s.mask()
    f.rect(x, y, x + w, y + 0.7)
    f.rect(x, y + h - 0.7, x + w, y + h)
    f.rect(x, y, x + 0.7, y + h)
    f.rect(x + w - 0.7, y, x + w, y + h)
    f.rect(x + w / 2 - 0.35, y, x + w / 2 + 0.35, y + h)
    s.paint(f, "#07080f")


def boards(m, x, y, w, h, n=3, seed=1):
    """Planks nailed across a window on the skew. Paint it darker than the wall."""
    rng = np.random.default_rng(seed)
    for k in range(n):
        yy = y + h * (k + 0.5) / n
        tilt = rng.uniform(-0.09, 0.09) * h
        m.stroke(np.array([(x - w * 0.08, yy - tilt), (x + w * 1.08, yy + tilt)]), h * 0.2, h * 0.19)
