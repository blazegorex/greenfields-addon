"""Scene renderer: scene JSON (MOCK.ExportScene, written by run.py) -> PNG.

Runs on the SYSTEM Python with PIL (the venv has no PIL):

    C:\\Python313\\python.exe -I tools\\harness\\render.py scene.json out.png [--crop x,y,w,h] [--ss 2]
    C:\\Python313\\python.exe -I tools\\harness\\render.py --batch jobs.json
    C:\\Python313\\python.exe -I tools\\harness\\render.py --metrics [font_metrics.json]

Scene coordinates are screen pixels with the origin at the top-left and y down (see
wow_mock_scene.lua). Items arrive already sorted back-to-front (strata, frame level, draw
layer, sublevel, creation order); HIGHLIGHT layers are never exported.

Textures: Interface\\AddOns\\Greenfields\\Media\\x -> Greenfields\\Media\\x.tga; WHITE8X8 is a
solid white; game icons, atlases and fileIDs become placeholders (a dark square tinted by a
hash of the path with a 1px border). Vertex colour * alpha, texcoord crops (any quad),
rotation, gradients, 9-slice (SetTextureSliceMargins), tiling (SetHoriz/VertTile, REPEAT
wrap), ADD blending, desaturation and masks (circle masks / media alpha masks) are applied.
FontStrings use fonts.py's stand-ins with |c colour runs, |T|t / |A|a inline icons, |H|h
links, justify H/V, word wrap within the width, ellipsis truncation, OUTLINE and a 1px
shadow. Clip rects (SetClipsChildren / ScrollFrame) are honoured. Everything is drawn at
2x (supersampling) and downscaled with LANCZOS.
"""
import hashlib
import json
import math
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

try:
    from PIL import Image, ImageChops, ImageDraw, ImageFont  # noqa: F401
except ImportError:  # -I drops the user site; PIL lives there on this machine
    import site
    sys.path.append(site.getusersitepackages())
    from PIL import Image, ImageChops, ImageDraw, ImageFont  # noqa: F401

import fonts  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(HERE))
DEFAULT_MEDIA = os.path.join(ROOT, "Greenfields", "Media")
MEDIA_PREFIX = "interface\\addons\\greenfields\\media\\"
WHITE_FILES = {"interface\\buttons\\white8x8", "interface\\buttons\\white8x8.blp", "interface\\buttons\\white8x8.tga"}
CIRCLE_MASKS = {"interface\\characterframe\\tempportraitalphamask", "interface\\masks\\circlemaskscalable",
                "interface\\characterframe\\tempportraitalphamasksmall"}
BG_TOP = (24, 30, 27)
BG_BOTTOM = (9, 11, 10)


def norm_path(p):
    return str(p).replace("/", "\\").lower()


def clamp(v, lo, hi):
    return lo if v < lo else hi if v > hi else v


def hash_color(key):
    h = hashlib.md5(str(key).encode("utf-8", "replace")).digest()
    # dark, slightly saturated tint
    r, g, b = h[0], h[1], h[2]
    m = max(r, g, b) or 1
    s = 70.0 / m
    return (int(28 + r * s * 0.6), int(30 + g * s * 0.6), int(32 + b * s * 0.6))


class Renderer:
    def __init__(self, media_dir=DEFAULT_MEDIA, ss=2):
        self.media = media_dir
        self.ss = ss
        self.tex_cache = {}
        self.font_cache = {}
        self.adv_cache = {}
        self.missing = set()

    # ------------------------------------------------------------------ textures
    def texture(self, path):
        """-> ('white', None) | ('image', Image) | ('placeholder', key)"""
        key = norm_path(path)
        if key in self.tex_cache:
            return self.tex_cache[key]
        res = ("placeholder", key)
        if key in WHITE_FILES:
            res = ("white", None)
        elif key.startswith(MEDIA_PREFIX):
            name = key[len(MEDIA_PREFIX):]
            name = re.sub(r"\.(tga|blp|png)$", "", name)
            p = os.path.join(self.media, name.replace("\\", os.sep) + ".tga")
            if os.path.exists(p):
                try:
                    res = ("image", Image.open(p).convert("RGBA"))
                except Exception:
                    self.missing.add(key)
            else:
                self.missing.add(key)
        self.tex_cache[key] = res
        return res

    def placeholder(self, key, w, h):
        c = hash_color(key)
        img = Image.new("RGBA", (w, h), c + (255,))
        if w >= 3 and h >= 3:
            d = ImageDraw.Draw(img)
            edge = tuple(min(255, int(v * 1.9) + 18) for v in c) + (255,)
            d.rectangle([0, 0, w - 1, h - 1], outline=edge, width=1)
            if w >= 12 and h >= 12:
                # a soft inner glyph so icons read as icons
                inset = max(3, min(w, h) // 4)
                hi = tuple(min(255, int(v * 1.5) + 10) for v in c) + (255,)
                d.ellipse([inset, inset, w - 1 - inset, h - 1 - inset], outline=hi, width=max(1, min(w, h) // 16))
        return img

    # ------------------------------------------------------------------ fonts
    def font(self, path, size_px):
        key = fonts.font_key(path)
        size_px = max(4, int(round(size_px)))
        ck = (key, size_px)
        f = self.font_cache.get(ck)
        if f is None:
            ttf, tracking = fonts.font_file(key)
            f = (ImageFont.truetype(ttf, size_px), tracking)
            self.font_cache[ck] = f
        return f

    def adv(self, fobj, ch):
        f, tracking = fobj
        k = (id(f), ch)
        v = self.adv_cache.get(k)
        if v is None:
            v = f.getlength(ch) * tracking
            self.adv_cache[k] = v
        return v

    # ------------------------------------------------------------------ helpers
    def tinted(self, img, rgba):
        r, g, b, a = rgba
        if r >= 0.999 and g >= 0.999 and b >= 0.999 and a >= 0.999:
            return img
        bands = img.split()
        out = []
        for band, m in zip(bands, (r, g, b, a)):
            m = clamp(m, 0.0, 1.0)
            out.append(band.point(lambda v, m=m: int(v * m + 0.5)))
        return Image.merge("RGBA", out)

    def sample(self, src, coords, w, h, wrapH=None, wrapV=None, htile=False, vtile=False, scale=1.0):
        """Maps the texcoord quad of src onto a w x h image."""
        sw, sh = src.size
        if coords is None:
            coords = [0, 0, 0, 1, 1, 0, 1, 1]
        ulx, uly, llx, lly, urx, ury, lrx, lry = coords
        us = [ulx, llx, urx, lrx]
        vs = [uly, lly, ury, lry]
        axis = abs(ulx - llx) < 1e-6 and abs(urx - lrx) < 1e-6 and abs(uly - ury) < 1e-6 and abs(lly - lry) < 1e-6
        if htile or vtile:
            # tile at the texture's native size (times the region scale)
            tw = max(1, int(round(sw * self.ss * scale))) if htile else w
            th = max(1, int(round(sh * self.ss * scale))) if vtile else h
            cell = self.sample(src, coords, tw, th)
            out = Image.new("RGBA", (w, h), (0, 0, 0, 0))
            for yy in range(0, h, th):
                for xx in range(0, w, tw):
                    out.paste(cell, (xx, yy))
            return out
        if axis:
            u0, u1, v0, v1 = ulx, urx, uly, lly
            repeat = (min(us) < -1e-6 or max(us) > 1 + 1e-6 or min(vs) < -1e-6 or max(vs) > 1 + 1e-6)
            if repeat:
                fx0, fx1 = math.floor(min(u0, u1)), math.ceil(max(u0, u1))
                fy0, fy1 = math.floor(min(v0, v1)), math.ceil(max(v0, v1))
                nx, ny = max(1, min(64, fx1 - fx0)), max(1, min(64, fy1 - fy0))
                big = Image.new("RGBA", (sw * nx, sh * ny))
                for iy in range(ny):
                    for ix in range(nx):
                        big.paste(src, (ix * sw, iy * sh))
                src2 = big
                u0, u1 = u0 - fx0, u1 - fx0
                v0, v1 = v0 - fy0, v1 - fy0
                sw2, sh2 = sw * nx, sh * ny
                box = (min(u0, u1) * sw, min(v0, v1) * sh, max(u0, u1) * sw, max(v0, v1) * sh)
            else:
                src2 = src
                sw2, sh2 = sw, sh
                box = (clamp(min(u0, u1), 0, 1) * sw, clamp(min(v0, v1), 0, 1) * sh,
                       clamp(max(u0, u1), 0, 1) * sw, clamp(max(v0, v1), 0, 1) * sh)
            bx0, by0, bx1, by1 = box
            if bx1 - bx0 < 0.01:
                bx1 = bx0 + 0.01
            if by1 - by0 < 0.01:
                by1 = by0 + 0.01
            img = src2.resize((w, h), Image.BILINEAR, box=(bx0, by0, bx1, by1))
            if u0 > u1:
                img = img.transpose(Image.FLIP_LEFT_RIGHT)
            if v0 > v1:
                img = img.transpose(Image.FLIP_TOP_BOTTOM)
            return img
        # general quad: (upper-left, lower-left, lower-right, upper-right) in source pixels
        quad = (ulx * sw, uly * sh, llx * sw, lly * sh, lrx * sw, lry * sh, urx * sw, ury * sh)
        return src.transform((w, h), Image.QUAD, quad, Image.BILINEAR)

    def nine_slice(self, src, margins, scale, w, h):
        sw, sh = src.size
        l, t, r, b = margins
        k = self.ss * scale
        L, T, Rr, B = int(round(l * k)), int(round(t * k)), int(round(r * k)), int(round(b * k))
        if L + Rr > w:
            f = w / float(max(1, L + Rr))
            L, Rr = int(L * f), int(Rr * f)
        if T + B > h:
            f = h / float(max(1, T + B))
            T, B = int(T * f), int(B * f)
        out = Image.new("RGBA", (w, h), (0, 0, 0, 0))
        xs_src = [0, l, sw - r, sw]
        ys_src = [0, t, sh - b, sh]
        xs_dst = [0, L, w - Rr, w]
        ys_dst = [0, T, h - B, h]
        for iy in range(3):
            for ix in range(3):
                sx0, sx1 = xs_src[ix], xs_src[ix + 1]
                sy0, sy1 = ys_src[iy], ys_src[iy + 1]
                dx0, dx1 = xs_dst[ix], xs_dst[ix + 1]
                dy0, dy1 = ys_dst[iy], ys_dst[iy + 1]
                if sx1 - sx0 <= 0 or sy1 - sy0 <= 0 or dx1 - dx0 <= 0 or dy1 - dy0 <= 0:
                    continue
                piece = src.resize((dx1 - dx0, dy1 - dy0), Image.BILINEAR, box=(sx0, sy0, sx1, sy1))
                out.paste(piece, (dx0, dy0))
        return out

    def gradient(self, orient, cmin, cmax, w, h):
        n = w if orient == "HORIZONTAL" else h
        n = max(1, n)
        line = Image.new("RGBA", (n, 1) if orient == "HORIZONTAL" else (1, n))
        px = line.load()
        for i in range(n):
            t = i / float(max(1, n - 1))
            if orient != "HORIZONTAL":
                t = 1.0 - t      # VERTICAL: minColor at the bottom, maxColor at the top
            c = tuple(int(255 * clamp(cmin[j] + (cmax[j] - cmin[j]) * t, 0, 1) + 0.5) for j in range(4))
            if orient == "HORIZONTAL":
                px[i, 0] = c
            else:
                px[0, i] = c
        return line.resize((w, h), Image.BILINEAR)

    # ------------------------------------------------------------------ main
    def render(self, scene, crop=None, out_path=None):
        ss = self.ss
        sw, sh = scene["screen"]["w"], scene["screen"]["h"]
        if crop:
            cx, cy, cw, ch = crop
            cx, cy = max(0, cx), max(0, cy)
            cw, ch = min(cw, sw - cx), min(ch, sh - cy)
        else:
            cx, cy, cw, ch = 0, 0, sw, sh
        W, H = int(round(cw * ss)), int(round(ch * ss))
        canvas = self.gradient("VERTICAL", tuple(v / 255.0 for v in BG_BOTTOM) + (1,), tuple(v / 255.0 for v in BG_TOP) + (1,), 2, max(2, H))
        canvas = canvas.resize((W, H))
        self.ox, self.oy = cx, cy
        self.W, self.H = W, H
        # client chrome the mock does not draw: a placeholder minimap disc for orientation
        for f in scene.get("frames", []):
            if f.get("name") == "Minimap":
                x, y, w, h = self.to_px(f["rect"])
                if x + w > 0 and y + h > 0 and x < W and y < H:
                    d = ImageDraw.Draw(canvas)
                    d.ellipse([x, y, x + w, y + h], fill=(22, 30, 26, 255), outline=(70, 78, 72, 255), width=max(1, ss * 2))
        for it in scene.get("items", []):
            try:
                k = it.get("kind")
                if k == "texture":
                    self.draw_texture(canvas, it)
                elif k == "font":
                    self.draw_font(canvas, it)
                elif k == "line":
                    self.draw_line(canvas, it)
            except Exception as e:  # never let one item kill the image
                sys.stderr.write("render: item %s failed: %s\n" % (it.get("id"), e))
        out = canvas.resize((max(1, int(round(cw))), max(1, int(round(ch)))), Image.LANCZOS).convert("RGB")
        if out_path:
            out.save(out_path)
        return out

    def to_px(self, rect):
        x, y, w, h = rect
        return ((x - self.ox) * self.ss, (y - self.oy) * self.ss, w * self.ss, h * self.ss)

    def clip_box(self, it, x0, y0, x1, y1):
        """intersect a pixel box with the item's clip rect and the canvas"""
        bx0, by0, bx1, by1 = max(0, x0), max(0, y0), min(self.W, x1), min(self.H, y1)
        clip = it.get("clip")
        if clip:
            px, py, pw, ph = self.to_px(clip)
            bx0, by0 = max(bx0, px), max(by0, py)
            bx1, by1 = min(bx1, px + pw), min(by1, py + ph)
        return int(math.floor(bx0)), int(math.floor(by0)), int(math.ceil(bx1)), int(math.ceil(by1))

    def composite(self, canvas, img, x, y, it, blend=None):
        """paste img (top-left at pixel x, y) honouring the clip"""
        iw, ih = img.size
        bx0, by0, bx1, by1 = self.clip_box(it, x, y, x + iw, y + ih)
        if bx1 <= bx0 or by1 <= by0:
            return
        sx0, sy0 = bx0 - x, by0 - y
        piece = img.crop((sx0, sy0, sx0 + (bx1 - bx0), sy0 + (by1 - by0)))
        if blend == "ADD":
            region = canvas.crop((bx0, by0, bx1, by1))
            r, g, b, a = piece.split()
            pm = Image.merge("RGB", [ImageChops.multiply(ch, a) for ch in (r, g, b)])
            added = ImageChops.add(region.convert("RGB"), pm)
            canvas.paste(added.convert("RGBA"), (bx0, by0))
        else:
            canvas.alpha_composite(piece, (bx0, by0))

    def draw_texture(self, canvas, it):
        t = it.get("tex") or {}
        x, y, w, h = self.to_px(it["rect"])
        ix, iy = int(math.floor(x)), int(math.floor(y))
        iw, ih = max(1, int(round(x + w)) - ix), max(1, int(round(y + h)) - iy)
        bx0, by0, bx1, by1 = self.clip_box(it, ix, iy, ix + iw, iy + ih)
        if bx1 <= bx0 or by1 <= by0:
            return
        if iw * ih > 6000 * 6000:
            return
        alpha = it.get("alpha", 1.0)
        vc = t.get("vc") or [1, 1, 1, 1]
        img = None
        if t.get("color") and not t.get("file") and t.get("fileID") is None and not t.get("atlas"):
            c = t["color"]
            rgba = (c[0] * vc[0], c[1] * vc[1], c[2] * vc[2], (c[3] if len(c) > 3 else 1) * (vc[3] if len(vc) > 3 else 1) * alpha)
            if not t.get("gradient") and not t.get("masks") and not t.get("rotation"):
                col = tuple(int(255 * clamp(v, 0, 1) + 0.5) for v in rgba)
                if col[3] == 0:
                    return
                img = Image.new("RGBA", (iw, ih), col)
                self.composite(canvas, img, ix, iy, it, t.get("blend"))
                return
            img = Image.new("RGBA", (iw, ih), (255, 255, 255, 255))
            tint = rgba
        else:
            kind, src = ("placeholder", None)
            path = t.get("file")
            if t.get("atlas"):
                path = t.get("atlasFile") or ("atlas:" + t["atlas"])
            if path is not None:
                kind, src = self.texture(path)
            elif t.get("fileID") is not None:
                kind, src = ("placeholder", "fileid:%s" % t["fileID"])
            if kind == "white":
                img = Image.new("RGBA", (iw, ih), (255, 255, 255, 255))
            elif kind == "image":
                coords = t.get("coords")
                if t.get("atlasCoords") and not coords:
                    l, r, tp, b = t["atlasCoords"]
                    coords = [l, tp, l, b, r, tp, r, b]
                if t.get("slice"):
                    img = self.nine_slice(src, t["slice"], t.get("sliceScale", 1.0), iw, ih)
                else:
                    img = self.sample(src, coords, iw, ih, t.get("wrapH"), t.get("wrapV"), t.get("htile"), t.get("vtile"))
            else:
                img = self.placeholder(src or path, iw, ih)
            tint = (vc[0], vc[1], vc[2], (vc[3] if len(vc) > 3 else 1) * alpha)
        if t.get("desat"):
            gray = img.convert("LA").convert("RGBA")
            img = Image.blend(img, gray, clamp(float(t["desat"]), 0, 1))
        if t.get("gradient"):
            g = t["gradient"]
            img = ImageChops.multiply(img, self.gradient(g.get("orientation", "HORIZONTAL"), g["min"], g["max"], iw, ih))
        img = self.tinted(img, tint)
        if t.get("rotation"):
            img = img.rotate(math.degrees(t["rotation"]), resample=Image.BICUBIC, expand=False)
        if t.get("masks"):
            mask = Image.new("L", (iw, ih), 0)
            for m in t["masks"]:
                mx, my, mw, mh = self.to_px(m["rect"])
                key = norm_path(m.get("file") or "")
                layer = Image.new("L", (iw, ih), 0)
                if key in CIRCLE_MASKS or key.endswith("circle") or "circle" in key:
                    d = ImageDraw.Draw(layer)
                    d.ellipse([mx - ix, my - iy, mx - ix + mw - 1, my - iy + mh - 1], fill=255)
                else:
                    kind, src = self.texture(m.get("file") or "")
                    if kind == "image":
                        a = src.split()[3].resize((max(1, int(mw)), max(1, int(mh))), Image.BILINEAR)
                        layer.paste(a, (int(mx - ix), int(my - iy)))
                    else:
                        d = ImageDraw.Draw(layer)
                        d.rectangle([mx - ix, my - iy, mx - ix + mw, my - iy + mh], fill=255)
                mask = ImageChops.lighter(mask, layer)
            r, g, b, a = img.split()
            img = Image.merge("RGBA", (r, g, b, ImageChops.multiply(a, mask)))
        self.composite(canvas, img, ix, iy, it, t.get("blend"))

    def draw_line(self, canvas, it):
        (x1, y1), (x2, y2) = it["p1"], it["p2"]
        s = self.ss
        x1, y1, x2, y2 = (x1 - self.ox) * s, (y1 - self.oy) * s, (x2 - self.ox) * s, (y2 - self.oy) * s
        th = max(1, int(round(it.get("thickness", 1) * s)))
        c = it.get("color") or [1, 1, 1, 1]
        a = c[3] * it.get("alpha", 1)
        x0, y0 = int(min(x1, x2)) - th, int(min(y1, y2)) - th
        w, h = int(abs(x2 - x1)) + 2 * th + 2, int(abs(y2 - y1)) + 2 * th + 2
        layer = Image.new("RGBA", (w, h), (0, 0, 0, 0))
        d = ImageDraw.Draw(layer)
        d.line([x1 - x0, y1 - y0, x2 - x0, y2 - y0], fill=tuple(int(255 * clamp(v, 0, 1)) for v in (c[0], c[1], c[2], a)), width=th)
        self.composite(canvas, layer, x0, y0, it)

    # ------------------------------------------------------------------ text
    TOKEN = re.compile(r"\|\||\|c([0-9a-fA-F]{8})|\|cn[^:]*:|\|r|\|T([^|]*)\|t|\|A([^|]*)\|a|\|H[^|]*\|h|\|h|\|K[^|]*\|k|\|n|\n")

    def parse(self, text, base):
        """-> list of (char, rgba) where char '\x02' is an inline icon (payload in a side list)"""
        out, icons = [], []
        stack = [base]
        pos = 0
        for m in self.TOKEN.finditer(text):
            for ch in text[pos:m.start()]:
                out.append((ch, stack[-1]))
            tok = m.group(0)
            if tok == "||":
                out.append(("|", stack[-1]))
            elif m.group(1):
                hx = m.group(1)
                a, r, g, b = (int(hx[i:i + 2], 16) / 255.0 for i in (0, 2, 4, 6))
                stack.append((r, g, b, base[3]))
            elif tok.startswith("|cn"):
                stack.append(stack[-1])
            elif tok == "|r":
                if len(stack) > 1:
                    stack.pop()
            elif m.group(2) is not None or m.group(3) is not None:
                payload = m.group(2) if m.group(2) is not None else "atlas:" + m.group(3)
                icons.append(payload)
                out.append(("\x02", stack[-1]))
            elif tok in ("|n", "\n"):
                out.append(("\n", stack[-1]))
            # |H...|h and |h and |K..|k: drop the markup, keep the display text
            pos = m.end()
        for ch in text[pos:]:
            out.append((ch, stack[-1]))
        return out, icons

    def draw_font(self, canvas, it):
        f = it["font"]
        ss = self.ss
        size = f.get("size", 12) * ss
        fobj = self.font(f.get("file"), size)
        font, tracking = fobj
        x, y, w, h = self.to_px(it["rect"])
        base = f.get("color") or [1, 1, 1, 1]
        alpha = it.get("alpha", 1.0)
        chars, icons = self.parse(f.get("text", ""), tuple(base))
        icon_w = size
        spacing = f.get("spacing", 0) * ss

        def cw(ch):
            if ch == "\x02":
                return icon_w
            return self.adv(fobj, ch)

        # split into hard lines, then wrap
        lines, cur = [], []
        for c in chars:
            if c[0] == "\n":
                lines.append(cur)
                cur = []
            else:
                cur.append(c)
        lines.append(cur)
        width_limit = w if (f.get("constrained") and w > 0) else None
        wrapped = []
        for line in lines:
            if f.get("wrap") and width_limit and sum(cw(c[0]) for c in line) > width_limit + ss * 0.5:
                words, word = [], []
                for c in line:
                    if c[0] == " ":
                        if word:
                            words.append(word)
                        word = []
                    else:
                        word.append(c)
                if word:
                    words.append(word)
                curl, curw = [], 0.0
                space = cw(" ")
                for word in words:
                    ww = sum(cw(c[0]) for c in word)
                    if curl and curw + space + ww > width_limit + ss * 0.5:
                        wrapped.append(curl)
                        curl, curw = list(word), ww
                    else:
                        if curl:
                            curl.append((" ", word[0][1]))
                            curw += space
                        curl.extend(word)
                        curw += ww
                wrapped.append(curl)
            else:
                wrapped.append(line)
        lines = wrapped
        line_h = size
        max_lines = f.get("maxLines")
        if h > 0 and f.get("wrap"):
            fit = max(1, int((h + spacing + 0.5 * ss) // (line_h + spacing)))
            max_lines = min(max_lines or fit, fit)
        truncated_last = False
        if max_lines and len(lines) > max_lines:
            lines = lines[:max_lines]
            truncated_last = True
        # ellipsis for lines that do not fit
        if width_limit:
            dots = cw(".") * 3
            for i, line in enumerate(lines):
                lw = sum(cw(c[0]) for c in line)
                if lw > width_limit + ss * 0.5 or (truncated_last and i == len(lines) - 1):
                    acc, keep = 0.0, []
                    for c in line:
                        if acc + cw(c[0]) + dots > width_limit:
                            break
                        keep.append(c)
                        acc += cw(c[0])
                    col = line[len(keep) - 1][1] if keep else (line[0][1] if line else tuple(base))
                    lines[i] = keep + [(".", col), (".", col), (".", col)]
        total_h = len(lines) * line_h + max(0, len(lines) - 1) * spacing
        jv = f.get("justifyV", "MIDDLE")
        if jv == "TOP":
            ty = y
        elif jv == "BOTTOM":
            ty = y + h - total_h
        else:
            ty = y + (h - total_h) / 2.0
        jh = f.get("justifyH", "CENTER")
        asc, desc = font.getmetrics()
        baseline_off = (line_h - (asc + desc)) / 2.0 + asc
        pad = int(size)
        box_x0 = int(math.floor(min(x, x + w) - pad))
        box_y0 = int(math.floor(ty - pad))
        maxw = max([sum(cw(c[0]) for c in ln) for ln in lines] + [w])
        box_w = int(maxw + 2 * pad + (w if jh != "LEFT" else 0))
        box_h = int(total_h + 2 * pad)
        if box_w <= 0 or box_h <= 0 or box_w * box_h > 9000 * 4000:
            return
        layer = Image.new("RGBA", (box_w, box_h), (0, 0, 0, 0))
        d = ImageDraw.Draw(layer)
        flags = (f.get("flags") or "").upper()
        stroke = 0
        if "THICKOUTLINE" in flags:
            stroke = 2 * ss
        elif "OUTLINE" in flags:
            stroke = 1 * ss
        shadow = f.get("shadow")
        icon_i = 0
        for li, line in enumerate(lines):
            lw = sum(cw(c[0]) for c in line)
            if jh == "LEFT":
                lx = x
            elif jh == "RIGHT":
                lx = x + w - lw
            else:
                lx = x + (w - lw) / 2.0
            by = ty + li * (line_h + spacing) + baseline_off
            # group same-colour runs
            runs, run, rc = [], [], None
            for ch, col in line:
                if ch == "\x02":
                    if run:
                        runs.append(("".join(run), rc))
                    runs.append(("\x02", col))
                    run, rc = [], None
                    continue
                if rc is None or col != rc:
                    if run:
                        runs.append(("".join(run), rc))
                    run, rc = [ch], col
                else:
                    run.append(ch)
            if run:
                runs.append(("".join(run), rc))
            px = lx
            for text, col in runs:
                if text == "\x02":
                    payload = icons[icon_i] if icon_i < len(icons) else ""
                    icon_i += 1
                    self.draw_inline_icon(layer, payload, px - box_x0, by - asc - box_y0 + (asc + desc - icon_w) / 2.0, icon_w, alpha)
                    px += icon_w
                    continue
                a = clamp(col[3] * alpha, 0, 1)
                fill = tuple(int(255 * clamp(v, 0, 1) + 0.5) for v in (col[0], col[1], col[2])) + (int(255 * a + 0.5),)
                tw = sum(self.adv(fobj, ch) for ch in text)
                if shadow and not stroke:
                    sc = shadow.get("color") or [0, 0, 0, 1]
                    so = shadow.get("offset") or [1, -1]
                    sa = clamp(sc[3] * a, 0, 1)
                    sfill = tuple(int(255 * clamp(v, 0, 1)) for v in sc[:3]) + (int(255 * sa),)
                    self.text_run(d, (px - box_x0 + so[0] * ss, by - box_y0 - so[1] * ss), text, font, sfill, tracking, fobj)
                self.text_run(d, (px - box_x0, by - box_y0), text, font, fill, tracking, fobj, stroke)
                px += tw
        self.composite(canvas, layer, box_x0, box_y0, it)

    def text_run(self, d, pos, text, font, fill, tracking, fobj, stroke=0):
        if tracking >= 0.999:
            kw = {"anchor": "ls", "fill": fill}
            if stroke:
                kw["stroke_width"] = stroke
                kw["stroke_fill"] = (0, 0, 0, fill[3])
            d.text(pos, text, font=font, **kw)
            return
        x, y = pos
        for ch in text:
            kw = {"anchor": "ls", "fill": fill}
            if stroke:
                kw["stroke_width"] = stroke
                kw["stroke_fill"] = (0, 0, 0, fill[3])
            d.text((x, y), ch, font=font, **kw)
            x += self.adv(fobj, ch)

    def draw_inline_icon(self, layer, payload, x, y, size, alpha):
        parts = payload.split(":")
        path = parts[0]
        s = max(2, int(size))
        kind, src = self.texture(path) if path and not path.startswith("atlas") else ("placeholder", path)
        if kind == "image":
            img = src.resize((s, s), Image.BILINEAR)
        elif kind == "white":
            img = Image.new("RGBA", (s, s), (255, 255, 255, 255))
        else:
            low = norm_path(path)
            if "goldicon" in low:
                img = self.coin(s, (232, 190, 70))
            elif "silvericon" in low:
                img = self.coin(s, (190, 195, 205))
            elif "coppericon" in low:
                img = self.coin(s, (196, 120, 70))
            else:
                img = self.placeholder(src or path, s, s)
        if alpha < 0.999:
            img = self.tinted(img, (1, 1, 1, alpha))
        layer.alpha_composite(img, (max(0, int(x)), max(0, int(y))))

    def coin(self, s, rgb):
        img = Image.new("RGBA", (s, s), (0, 0, 0, 0))
        d = ImageDraw.Draw(img)
        d.ellipse([s * 0.15, s * 0.15, s * 0.85, s * 0.85], fill=rgb + (255,), outline=(40, 30, 10, 255))
        return img


# ---------------------------------------------------------------------------
# metrics (consumed by the mock through run.py)
# ---------------------------------------------------------------------------
def write_metrics(out_path):
    data = {}
    for key in fonts.FONT_KEYS:
        path, tracking = fonts.font_file(key)
        f = ImageFont.truetype(path, 100)
        adv = {}
        for code in range(32, 127):
            adv[str(code)] = round(f.getlength(chr(code)) * tracking, 2)
        adv["other"] = round(f.getlength("e") * tracking, 2)
        asc, desc = f.getmetrics()
        data[key] = {"file": os.path.basename(path), "tracking": tracking, "adv": adv, "ascent": asc, "descent": desc}
    with open(out_path, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=1, sort_keys=True)
    print("wrote", out_path)


def run_batch(manifest):
    with open(manifest, encoding="utf-8") as fh:
        spec = json.load(fh)
    r = Renderer(spec.get("media") or DEFAULT_MEDIA, spec.get("ss", 2))
    scenes = {}
    ok = 0
    for job in spec["jobs"]:
        sp = job["scene"]
        if sp not in scenes:
            with open(sp, encoding="utf-8") as fh:
                scenes = {sp: json.load(fh)}      # keep one scene in memory at a time
        try:
            r.render(scenes[sp], job.get("crop"), job["out"])
            ok += 1
            print("rendered", job["out"])
        except Exception as e:
            print("FAILED", job["out"], e)
    if r.missing:
        print("missing media:", ", ".join(sorted(r.missing)))
    print("%d/%d images" % (ok, len(spec["jobs"])))
    return 0 if ok == len(spec["jobs"]) else 1


def main(argv):
    if argv and argv[0] == "--metrics":
        write_metrics(argv[1] if len(argv) > 1 else fonts.METRICS_PATH)
        return 0
    if argv and argv[0] == "--batch":
        return run_batch(argv[1])
    if len(argv) < 2:
        print(__doc__)
        return 2
    crop, ss = None, 2
    rest = argv[2:]
    i = 0
    while i < len(rest):
        if rest[i] == "--crop":
            crop = [float(v) for v in rest[i + 1].split(",")]
            i += 2
        elif rest[i] == "--ss":
            ss = int(rest[i + 1])
            i += 2
        else:
            i += 1
    with open(argv[0], encoding="utf-8") as fh:
        scene = json.load(fh)
    Renderer(DEFAULT_MEDIA, ss).render(scene, crop, argv[1])
    print("wrote", argv[1])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
