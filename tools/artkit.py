"""Procedural art kit: shapes -> height field -> lit metal, enamel, stone and leather.

Everything in Greenfields/Media that isn't a painted banner comes through here. Shapes are
drawn big as masks, turned into a height field with a signed distance transform, then lit
from the top-left the way the game's own UI art is. Run with the system Python (python -P):
it needs numpy, Pillow, scipy and cv2.
"""
import math

import cv2
import numpy as np
from PIL import Image, ImageDraw
from scipy import ndimage as ndi

LIGHT = np.array([-0.52, -0.70, 0.60], np.float32)
LIGHT = LIGHT / np.linalg.norm(LIGHT)
VIEW = np.array([0.0, 0.0, 1.0], np.float32)


# --------------------------------------------------------------------------- colour ramps
def hexc(s):
    s = s.lstrip("#")
    return tuple(int(s[i:i + 2], 16) for i in (0, 2, 4))


def ramp(*stops):
    """ramp((0.0,'#000'),(1.0,'#fff')) -> fn(values in 0..1) -> float32 rgb array in 0..255."""
    xs = np.array([s[0] for s in stops], np.float32)
    cs = np.array([hexc(s[1]) for s in stops], np.float32)

    def fn(v):
        v = np.clip(v, 0, 1)
        return np.dstack([np.interp(v, xs, cs[:, i]) for i in range(3)]).astype(np.float32)
    return fn


# Stylised metals: dark recess, body colour, a warm highlight and a near-white glint. The
# body sits at about 0.5, so a flat surface reads as the metal's own colour.
GOLD = ramp((0.00, "#140c04"), (0.18, "#3c2709"), (0.36, "#7c5a1e"), (0.52, "#b78d3a"),
            (0.70, "#dcb765"), (0.86, "#f6e3a6"), (1.00, "#fffbea"))
BRONZE = ramp((0.00, "#0d0906"), (0.20, "#2a1c10"), (0.38, "#513a20"), (0.54, "#7d5f37"),
              (0.72, "#a98655"), (0.88, "#d8bf8f"), (1.00, "#f6ead0"))
IRON = ramp((0.00, "#060707"), (0.22, "#14181a"), (0.42, "#262c2e"), (0.56, "#3b4346"),
            (0.74, "#5e696c"), (0.90, "#98a4a6"), (1.00, "#e2ebec"))
DARKBRONZE = ramp((0.00, "#080605"), (0.24, "#1a130c"), (0.44, "#31241a"), (0.58, "#4b3a28"),
                  (0.76, "#7a6243"), (0.90, "#b09a70"), (1.00, "#e8dcb8"))


# --------------------------------------------------------------------------- noise
def fbm_noise(h, w, seed, cells=4, octaves=5, tile=False):
    """Smooth fractal noise in 0..1. tile=True wraps at the edges."""
    rng = np.random.default_rng(seed)
    acc = np.zeros((h, w), np.float32)
    amp, tot = 1.0, 0.0
    for o in range(octaves):
        c = cells * (2 ** o)
        cy = max(2, int(round(c * h / max(h, w))))
        cx = max(2, int(round(c * w / max(h, w))))
        lat = rng.random((cy, cx), dtype=np.float32)
        if tile:
            lat = np.pad(lat, ((1, 2), (1, 2)), mode="wrap")
            big = cv2.resize(lat, None, fx=w / cx, fy=h / cy, interpolation=cv2.INTER_CUBIC)
            ox, oy = int(round(w / cx)), int(round(h / cy))
            big = big[oy:oy + h, ox:ox + w]
        else:
            big = cv2.resize(lat, (w, h), interpolation=cv2.INTER_CUBIC)
        acc += big * amp
        tot += amp
        amp *= 0.55
    acc /= tot
    lo, hi = acc.min(), acc.max()
    return (acc - lo) / max(1e-6, hi - lo)


# --------------------------------------------------------------------------- shapes
class Canvas:
    """A big single-channel drawing surface."""

    def __init__(self, w, h):
        self.w, self.h = int(w), int(h)
        self.img = Image.new("L", (self.w, self.h), 0)
        self.d = ImageDraw.Draw(self.img)

    def array(self):
        return np.asarray(self.img, dtype=np.float32) / 255.0

    def rrect(self, x0, y0, x1, y1, r, fill=255):
        self.d.rounded_rectangle((x0, y0, x1, y1), radius=max(0, r), fill=fill)
        return self

    def poly(self, pts, fill=255):
        self.d.polygon([(float(p[0]), float(p[1])) for p in pts], fill=fill)
        return self

    def circle(self, cx, cy, r, fill=255):
        self.d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=fill)
        return self


def bezier(p0, p1, p2, p3=None, n=48):
    """Quadratic or cubic bezier sampled to an array of points."""
    t = np.linspace(0, 1, n)[:, None]
    p0, p1, p2 = np.array(p0, float), np.array(p1, float), np.array(p2, float)
    if p3 is None:
        return (1 - t) ** 2 * p0 + 2 * (1 - t) * t * p1 + t ** 2 * p2
    p3 = np.array(p3, float)
    return (1 - t) ** 3 * p0 + 3 * (1 - t) ** 2 * t * p1 + 3 * (1 - t) * t ** 2 * p2 + t ** 3 * p3


def ribbon(pts, widths):
    """Polygon around a polyline with a width per point (a tapered stroke)."""
    pts = np.asarray(pts, float)
    widths = np.broadcast_to(np.asarray(widths, float), (len(pts),))
    d = np.gradient(pts, axis=0)
    d /= np.maximum(1e-6, np.linalg.norm(d, axis=1, keepdims=True))
    nrm = np.stack((-d[:, 1], d[:, 0]), axis=1)
    a = pts + nrm * widths[:, None] / 2
    b = pts - nrm * widths[:, None] / 2
    return np.concatenate((a, b[::-1]))


def leaf_outline(p0, ctrl, p1, width, n=40, belly=0.42):
    """Sickle gum leaf between p0 (stem) and p1 (tip): pointed both ends, fattest near the stem."""
    c = bezier(p0, ctrl, p1, n=n)
    t = np.linspace(0, 1, n)
    prof = np.power(np.sin(np.pi * np.power(t, belly / 0.5 * 0.72)), 0.82)
    return c, ribbon(c, width * prof)


def spiral(cx, cy, r0, r1, a0, turns, n=90):
    """Scroll curl: radius shrinks from r0 to r1 over `turns` turns."""
    t = np.linspace(0, 1, n)
    a = a0 + t * turns * 2 * math.pi
    r = r0 + (r1 - r0) * t
    return np.stack((cx + r * np.cos(a), cy + r * np.sin(a)), axis=1)


# --------------------------------------------------------------------------- height fields
def sdf(mask):
    """Signed distance in pixels: positive inside the mask."""
    m = mask > 0.5
    return ndi.distance_transform_edt(m).astype(np.float32) - ndi.distance_transform_edt(~m).astype(np.float32)


def bevel(mask, width, height=1.0, profile="round", plateau=1.0):
    """Raised shape: rises over `width` px from the edge to `height`."""
    d = np.clip(sdf(mask) / max(1e-6, width), 0, 1)
    if profile == "round":
        h = np.sqrt(np.maximum(0, 1 - (1 - d) ** 2))
    elif profile == "chamfer":
        h = d
    elif profile == "smooth":
        h = d * d * (3 - 2 * d)
    else:
        raise ValueError(profile)
    return h * height * plateau


def blur(a, sigma):
    if sigma <= 0:
        return a
    return cv2.GaussianBlur(a, (0, 0), sigma)


def normals(h, strength=1.0):
    gx = cv2.Sobel(h, cv2.CV_32F, 1, 0, ksize=3) / 8.0
    gy = cv2.Sobel(h, cv2.CV_32F, 0, 1, ksize=3) / 8.0
    n = np.dstack((-gx * strength, -gy * strength, np.ones_like(h)))
    n /= np.maximum(1e-6, np.linalg.norm(n, axis=2, keepdims=True))
    return n


def shade(h, material, strength=1.0, base=0.5, gain=0.95, spec=0.45, shininess=26, grain=0.0, seed=7,
          ao_radius=0.0, ao=0.0, wear=0.0, sheen=0.0, light=LIGHT):
    """Lights a height field and maps it through a material ramp -> float rgb 0..255."""
    hh, ww = h.shape
    hgt = h
    if grain > 0:
        rng = np.random.default_rng(seed)
        n1 = cv2.GaussianBlur(rng.random((hh, ww), dtype=np.float32), (0, 0), 1.1)
        hgt = h + (n1 - 0.5) * grain
    n = normals(hgt, strength)
    ndl = np.clip(n[..., 0] * light[0] + n[..., 1] * light[1] + n[..., 2] * light[2], -1, 1)
    half = light + VIEW
    half = half / np.linalg.norm(half)
    ndh = np.clip(n[..., 0] * half[0] + n[..., 1] * half[1] + n[..., 2] * half[2], 0, 1)
    v = base + (ndl - light[2]) * gain + (ndh ** shininess - float(half[2]) ** shininess) * spec
    if sheen > 0:
        v += (fbm_noise(hh, ww, seed + 3, cells=3, octaves=3) - 0.5) * sheen
    if ao > 0:
        v -= np.clip((blur(h, ao_radius) - h), 0, None) * ao
    if wear > 0:
        lap = cv2.Laplacian(blur(h, 1.0), cv2.CV_32F)
        v += np.clip(-lap, 0, None) * wear
    return material(v)


def enamel(mask, colour_hi, colour_lo, gloss=0.55, rim=0.0):
    """Painted glass fill: vertical gradient plus a soft top sheen. -> float rgb."""
    h, w = mask.shape
    ys = np.linspace(0, 1, h, dtype=np.float32)[:, None]
    hi, lo = np.array(hexc(colour_hi), np.float32), np.array(hexc(colour_lo), np.float32)
    rgb = np.ones((h, w, 3), np.float32)
    for i in range(3):
        rgb[..., i] = hi[i] + (lo[i] - hi[i]) * ys
    if gloss > 0:
        rgb += (255 - rgb) * (np.clip(1 - ys * 2.2, 0, 1) ** 2)[..., None] * gloss * 0.35
    return rgb


# --------------------------------------------------------------------------- compositing
class Layer:
    """Premultiplied float RGBA in 0..1, big, composited over each other, then downsampled."""

    def __init__(self, w, h):
        self.rgb = np.zeros((h, w, 3), np.float32)
        self.a = np.zeros((h, w), np.float32)

    def over(self, rgb255, alpha):
        """Composite straight rgb (0..255, or a 3-tuple) with alpha (0..1 array or float)."""
        alpha = np.clip(np.broadcast_to(np.asarray(alpha, np.float32), self.a.shape), 0, 1)
        if isinstance(rgb255, tuple):
            rgb255 = np.broadcast_to(np.array(rgb255, np.float32), self.rgb.shape)
        src = np.clip(rgb255 / 255.0, 0, 1) * alpha[..., None]
        self.rgb = src + self.rgb * (1 - alpha[..., None])
        self.a = alpha + self.a * (1 - alpha)
        return self

    def add(self, rgb255, alpha):
        """Additive light on top: only brightens what's already there."""
        alpha = np.clip(np.broadcast_to(np.asarray(alpha, np.float32), self.a.shape), 0, 1)
        if isinstance(rgb255, tuple):
            rgb255 = np.broadcast_to(np.array(rgb255, np.float32), self.rgb.shape)
        self.rgb = np.clip(self.rgb + rgb255 / 255.0 * (alpha * self.a)[..., None], 0, 1)
        return self

    def image(self, w=None, h=None):
        """-> PIL RGBA, straight alpha, resized with area averaging in premultiplied space."""
        rgb, a = self.rgb, self.a
        if w is not None and (w, h) != (a.shape[1], a.shape[0]):
            rgb = cv2.resize(rgb, (w, h), interpolation=cv2.INTER_AREA)
            a = cv2.resize(a, (w, h), interpolation=cv2.INTER_AREA)
        straight = rgb / np.maximum(a[..., None], 1e-4)
        # keep a sensible colour under fully transparent pixels: game filtering samples it
        out = np.dstack((np.clip(straight, 0, 1), np.clip(a, 0, 1)))
        return Image.fromarray((out * 255 + 0.5).astype(np.uint8), "RGBA")


def drop_shadow(mask, dx, dy, sigma, strength=0.8):
    """Shadow alpha from a mask, offset and blurred."""
    M = np.float32([[1, 0, dx], [0, 1, dy]])
    m = cv2.warpAffine(mask, M, (mask.shape[1], mask.shape[0]), flags=cv2.INTER_LINEAR, borderValue=0)
    return blur(m, sigma) * strength
