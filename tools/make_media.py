"""Generates every texture in Greenfields/Media.

WoW wants uncompressed 32-bit TGA (image type 2, descriptor 0x08, bottom-left origin)
with power-of-two sizes, which is exactly what Forever-era addons ship. Everything is
drawn at 4x and downsampled so edges are antialiased.

    python tools/make_media.py
"""
import math
import os
import random
import struct

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "Greenfields", "Media")
FONTS = r"C:\Windows\Fonts"
SS = 4  # supersample factor

SIGN_GREEN_TOP = (16, 128, 72)
SIGN_GREEN_BOT = (6, 88, 48)
WHITE = (255, 255, 255)
HAZARD = (255, 204, 0)


def save_tga(img, name):
    img = img.convert("RGBA")
    w, h = img.size
    assert w & (w - 1) == 0 and h & (h - 1) == 0, f"{name}: {w}x{h} is not power-of-two"
    header = struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, w, h, 32, 0x08)
    rows = []
    px = img.tobytes("raw", "BGRA")
    stride = w * 4
    for y in range(h - 1, -1, -1):  # bottom-left origin
        rows.append(px[y * stride:(y + 1) * stride])
    with open(os.path.join(OUT, name + ".tga"), "wb") as f:
        f.write(header)
        f.write(b"".join(rows))


def font(file, size, variation=None):
    f = ImageFont.truetype(os.path.join(FONTS, file), size)
    if variation:
        try:
            f.set_variation_by_name(variation)
        except Exception:
            pass
    return f


def vgradient(size, top, bot):
    w, h = size
    g = Image.new("RGBA", (1, h))
    for y in range(h):
        t = y / max(1, h - 1)
        g.putpixel((0, y), tuple(int(top[i] + (bot[i] - top[i]) * t) for i in range(3)) + (255,))
    return g.resize((w, h))


def rounded_mask(size, box, radius):
    m = Image.new("L", size, 0)
    ImageDraw.Draw(m).rounded_rectangle(box, radius=radius, fill=255)
    return m


def grime(size, seed, amount=0.05, dark=True):
    """Speckle + scratch layer (RGBA) so signs look like they've lived on a Greenfields corner."""
    rnd = random.Random(seed)
    w, h = size
    layer = Image.new("RGBA", size, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    col = (0, 0, 0) if dark else (255, 255, 255)
    for _ in range(int(w * h * amount / 400)):
        x, y = rnd.uniform(0, w), rnd.uniform(0, h)
        r = rnd.uniform(0.5, 2.2) * SS
        d.ellipse((x - r, y - r, x + r, y + r), fill=col + (rnd.randint(18, 60),))
    for _ in range(6):
        x, y = rnd.uniform(0, w), rnd.uniform(0, h)
        ang = rnd.uniform(-0.5, 0.5)
        ln = rnd.uniform(20, 70) * SS
        d.line((x, y, x + math.cos(ang) * ln, y + math.sin(ang) * ln), fill=(255, 255, 255, 28), width=SS)
    return layer


def sign(w, h, top, bot, border, seed, text_fn=None, radius=14, inset=5, border_w=4):
    """A rounded Australian guide sign: coloured face, white inset border, soft drop shadow."""
    W, H = w * SS, h * SS
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    face_box = (inset * SS, inset * SS, W - inset * SS, H - inset * SS - 3 * SS)
    # shadow
    sh = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(sh).rounded_rectangle(
        (face_box[0], face_box[1] + 3 * SS, face_box[2], face_box[3] + 3 * SS), radius=radius * SS, fill=(0, 0, 0, 150))
    sh = sh.filter(ImageFilter.GaussianBlur(3 * SS))
    img.alpha_composite(sh)
    # face
    face = vgradient((W, H), top, bot)
    mask = rounded_mask((W, H), face_box, radius * SS)
    img.paste(face, (0, 0), mask)
    # border
    b = (face_box[0] + 4 * SS, face_box[1] + 4 * SS, face_box[2] - 4 * SS, face_box[3] - 4 * SS)
    ImageDraw.Draw(img).rounded_rectangle(b, radius=(radius - 4) * SS, outline=border + (255,), width=border_w * SS)
    if text_fn:
        text_fn(img, ImageDraw.Draw(img), face_box)
    # grime only on the face
    g = grime((W, H), seed)
    g.putalpha(ImageChops.multiply(g.getchannel("A"), mask))
    img.alpha_composite(g)
    # top sheen
    sheen = Image.new("RGBA", (W, H), (255, 255, 255, 0))
    ImageDraw.Draw(sheen).rectangle((0, 0, W, face_box[1] + (face_box[3] - face_box[1]) * 0.45), fill=(255, 255, 255, 18))
    sheen.putalpha(ImageChops.multiply(sheen.getchannel("A"), mask))
    img.alpha_composite(sheen)
    return img.resize((w, h), Image.LANCZOS)


def centered(draw, box, y, text, fnt, fill, spacing=0):
    if spacing:
        widths = [draw.textlength(ch, font=fnt) for ch in text]
        total = sum(widths) + spacing * (len(text) - 1)
        x = box[0] + (box[2] - box[0] - total) / 2
        for ch, cw in zip(text, widths):
            draw.text((x, y), ch, font=fnt, fill=fill)
            x += cw + spacing
    else:
        tw = draw.textlength(text, font=fnt)
        draw.text((box[0] + (box[2] - box[0] - tw) / 2, y), text, font=fnt, fill=fill)


def sticker(img, cx, cy, text, angle, fill=HAZARD, ink=(20, 20, 20)):
    f = font("bahnschrift.ttf", 13 * SS, "Bold")
    tmp = Image.new("RGBA", (120 * SS, 30 * SS), (0, 0, 0, 0))
    d = ImageDraw.Draw(tmp)
    tw = d.textlength(text, font=f)
    pad = 6 * SS
    box = (0, 0, tw + pad * 2, 22 * SS)
    d.rounded_rectangle(box, radius=3 * SS, fill=fill + (255,))
    d.text((pad, 2.5 * SS), text, font=f, fill=ink + (255,))
    tmp = tmp.crop((0, 0, int(box[2]) + 1, int(box[3]) + 1)).rotate(angle, resample=Image.BICUBIC, expand=True)
    img.alpha_composite(tmp, (int(cx - tmp.width / 2), int(cy - tmp.height / 2)))


def bullet_hole(img, cx, cy, r):
    d = ImageDraw.Draw(img)
    for i in range(7):
        a = i * 2 * math.pi / 7 + 0.3
        d.line((cx, cy, cx + math.cos(a) * r * 2.6, cy + math.sin(a) * r * 2.6), fill=(255, 255, 255, 70), width=SS)
    d.ellipse((cx - r * 1.35, cy - r * 1.35, cx + r * 1.35, cy + r * 1.35), fill=(210, 210, 210, 200))
    d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=(15, 15, 15, 255))


def make_logo():
    def text(img, d, box):
        big = font("bahnschrift.ttf", 62 * SS, "Bold")
        small = font("bahnschrift.ttf", 16 * SS, "SemiBold")
        centered(d, box, box[1] + 10 * SS, "GREENFIELDS", big, WHITE + (255,), spacing=2 * SS)
        centered(d, box, box[1] + 82 * SS, "MANDURAH  \u2022  WA 6210", small, (220, 240, 228, 255), spacing=3 * SS)
        bullet_hole(img, box[2] - 40 * SS, box[3] - 18 * SS, 3.2 * SS)
        bullet_hole(img, box[0] + 30 * SS, box[1] + 22 * SS, 2.4 * SS)
        sticker(img, box[2] - 52 * SS, box[1] + 10 * SS, "EST. 2026", -9)
    save_tga(sign(512, 128, SIGN_GREEN_TOP, SIGN_GREEN_BOT, WHITE, 6210, text), "logo")


def make_signs():
    save_tga(sign(512, 128, SIGN_GREEN_TOP, SIGN_GREEN_BOT, WHITE, 11), "sign_green")
    save_tga(sign(512, 128, (255, 214, 10), (236, 178, 0), (20, 20, 20), 12), "sign_yellow")
    save_tga(sign(512, 128, (214, 40, 40), (160, 20, 24), WHITE, 13), "sign_red")
    save_tga(sign(512, 128, (24, 70, 160), (14, 46, 112), WHITE, 14), "sign_blue")

    def welcome(img, d, box):
        a = font("bahnschrift.ttf", 22 * SS, "SemiBold")
        b = font("bahnschrift.ttf", 64 * SS, "Bold")
        c = font("bahnschrift.ttf", 17 * SS, "SemiBold")
        centered(d, box, box[1] + 26 * SS, "WELCOME TO", a, WHITE + (255,), spacing=6 * SS)
        centered(d, box, box[1] + 56 * SS, "GREENFIELDS", b, WHITE + (255,), spacing=2 * SS)
        d.line((box[0] + 60 * SS, box[1] + 140 * SS, box[2] - 60 * SS, box[1] + 140 * SS), fill=(255, 255, 255, 160), width=2 * SS)
        centered(d, box, box[1] + 152 * SS, "PLEASE DRIVE CAREFULLY.  OR DON'T.", c, (220, 240, 228, 255), spacing=2 * SS)
        centered(d, box, box[1] + 178 * SS, "POP. 40 RAIDERS  \u2022  1 SERVO", c, (220, 240, 228, 255), spacing=2 * SS)
        bullet_hole(img, box[2] - 60 * SS, box[1] + 40 * SS, 3.5 * SS)
        bullet_hole(img, box[0] + 46 * SS, box[3] - 40 * SS, 2.8 * SS)
        sticker(img, box[0] + 70 * SS, box[3] - 16 * SS, "NAH YEAH", 7, fill=(255, 62, 138), ink=WHITE)
    save_tga(sign(512, 256, SIGN_GREEN_TOP, SIGN_GREEN_BOT, WHITE, 99, welcome, radius=20), "welcome")


def make_minimap():
    W = 64 * SS
    img = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    disc = vgradient((W, W), SIGN_GREEN_TOP, SIGN_GREEN_BOT)
    m = Image.new("L", (W, W), 0)
    ImageDraw.Draw(m).ellipse((2 * SS, 2 * SS, W - 2 * SS, W - 2 * SS), fill=255)
    img.paste(disc, (0, 0), m)
    d = ImageDraw.Draw(img)
    d.ellipse((6 * SS, 6 * SS, W - 6 * SS, W - 6 * SS), outline=WHITE + (255,), width=3 * SS)
    f = font("bahnschrift.ttf", 40 * SS, "Bold")
    tw = d.textlength("G", font=f)
    d.text(((W - tw) / 2, 9 * SS), "G", font=f, fill=WHITE + (255,))
    save_tga(img.resize((64, 64), Image.LANCZOS), "minimap")


def make_utility():
    # radial glow (tinted in game)
    W = 64 * SS
    g = Image.new("L", (W, W), 0)
    px = g.load()
    c = W / 2
    for y in range(W):
        for x in range(W):
            r = math.hypot(x - c + 0.5, y - c + 0.5) / c
            px[x, y] = int(255 * max(0.0, 1 - r) ** 2.2)
    img = Image.new("RGBA", (W, W), WHITE + (0,))
    img.putalpha(g)
    save_tga(img.resize((64, 64), Image.LANCZOS), "glow")

    # 9-slice soft shadow: a blurred rounded square, corners 16px
    W = 64 * SS
    m = Image.new("L", (W, W), 0)
    ImageDraw.Draw(m).rounded_rectangle((16 * SS, 16 * SS, W - 16 * SS, W - 16 * SS), radius=6 * SS, fill=255)
    m = m.filter(ImageFilter.GaussianBlur(6 * SS))
    img = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    img.putalpha(m)
    save_tga(img.resize((64, 64), Image.LANCZOS), "shadow")

    # tileable grain
    rnd = random.Random(42)
    img = Image.new("RGBA", (128, 128), (255, 255, 255, 0))
    px = img.load()
    for y in range(128):
        for x in range(128):
            v = rnd.random()
            px[x, y] = (255, 255, 255, int(v * v * 34))
    save_tga(img, "noise")

    # tileable hazard stripes (yellow/black, 45 degrees)
    W = 64
    img = Image.new("RGBA", (W, W))
    px = img.load()
    for y in range(W):
        for x in range(W):
            px[x, y] = HAZARD + (255,) if ((x + y) // 16) % 2 == 0 else (24, 24, 24, 255)
    save_tga(img, "hazard")

    # status bar fill with a gentle gloss (white, tinted in game)
    W, H = 256, 32
    img = Image.new("RGBA", (W, H))
    px = img.load()
    for y in range(H):
        t = y / (H - 1)
        v = int(255 * (1.0 - 0.28 * t))
        a = 255
        for x in range(W):
            px[x, y] = (v, v, v, a)
    d = ImageDraw.Draw(img)
    d.rectangle((0, 0, W, 9), fill=(255, 255, 255, 255))
    save_tga(img, "bar")

    # solid circle + fully rounded pill (toggle tracks, status dots)
    W = 32 * SS
    m = Image.new("L", (W, W), 0)
    ImageDraw.Draw(m).ellipse((0, 0, W - 1, W - 1), fill=255)
    img = Image.new("RGBA", (W, W), WHITE + (0,))
    img.putalpha(m)
    save_tga(img.resize((32, 32), Image.LANCZOS), "circle")
    W, H = 64 * SS, 32 * SS
    m = Image.new("L", (W, H), 0)
    ImageDraw.Draw(m).rounded_rectangle((0, 0, W - 1, H - 1), radius=H // 2, fill=255)
    img = Image.new("RGBA", (W, H), WHITE + (0,))
    img.putalpha(m)
    save_tga(img.resize((64, 32), Image.LANCZOS), "pill")

    # rounded-rect fill + edge used for pills/chips (corner radius 6 at 32px)
    for r, name in ((6, "round6"), (10, "round10")):
        W = 32 * SS
        m = rounded_mask((W, W), (0, 0, W - 1, W - 1), r * SS)
        img = Image.new("RGBA", (W, W), WHITE + (0,))
        img.putalpha(m)
        save_tga(img.resize((32, 32), Image.LANCZOS), name)
        e = Image.new("L", (W, W), 0)
        ImageDraw.Draw(e).rounded_rectangle((0, 0, W - 1, W - 1), radius=r * SS, outline=255, width=SS * 1)
        img = Image.new("RGBA", (W, W), WHITE + (0,))
        img.putalpha(e)
        save_tga(img.resize((32, 32), Image.LANCZOS), name + "_edge")


# --------------------------------------------------------------------------------------
# Line icon set (white, 32x32, tinted in game). Drawn on a 128 canvas, stroke 10.
# --------------------------------------------------------------------------------------
S = 128
STROKE = 11


def icon(name, fn):
    m = Image.new("L", (S, S), 0)
    d = ImageDraw.Draw(m)
    fn(d, m)
    img = Image.new("RGBA", (S, S), WHITE + (0,))
    img.putalpha(m)
    save_tga(img.resize((32, 32), Image.LANCZOS), "icon_" + name)


def arc(d, box, a0, a1, w=STROKE):
    d.arc(box, a0, a1, fill=255, width=w)


def line(d, pts, w=STROKE):
    d.line(pts, fill=255, width=w, joint="curve")
    for p in (pts[0], pts[-1]):
        d.ellipse((p[0] - w / 2 + 0.5, p[1] - w / 2 + 0.5, p[0] + w / 2 - 0.5, p[1] + w / 2 - 0.5), fill=255)


def i_roster(d, m):
    # back person
    d.ellipse((70, 14, 106, 50), fill=255)
    d.chord((56, 56, 122, 130), 180, 360, fill=255)
    # gap so the front person reads in front
    d.ellipse((22, 18, 72, 68), fill=0)
    d.chord((2, 62, 92, 152), 180, 360, fill=0)
    # front person
    d.ellipse((28, 24, 66, 62), fill=255)
    d.chord((8, 68, 86, 146), 180, 360, fill=255)


def i_calendar(d, m):
    d.rounded_rectangle((16, 26, 112, 112), radius=14, outline=255, width=STROKE)
    d.rectangle((16, 26, 112, 50), fill=255)
    for x in (42, 86):
        line(d, [(x, 12), (x, 34)])
    for (x, y) in ((40, 70), (64, 70), (88, 70), (40, 92), (64, 92)):
        d.ellipse((x - 6, y - 6, x + 6, y + 6), fill=255)


def i_dice(d, m):
    d.rounded_rectangle((18, 18, 110, 110), radius=20, outline=255, width=STROKE)
    for (x, y) in ((42, 42), (86, 42), (64, 64), (42, 86), (86, 86)):
        d.ellipse((x - 9, y - 9, x + 9, y + 9), fill=255)


def i_check(d, m):
    line(d, [(26, 66), (52, 92), (102, 36)], STROKE + 3)


def i_clipboard(d, m):
    d.rounded_rectangle((22, 22, 106, 116), radius=12, outline=255, width=STROKE)
    d.rounded_rectangle((44, 10, 84, 34), radius=8, fill=255)
    line(d, [(40, 72), (56, 88), (88, 56)])


def i_trophy(d, m):
    d.chord((30, 0, 98, 76), 0, 180, fill=255)
    d.rectangle((30, 14, 98, 38), fill=255)
    arc(d, (8, 18, 42, 58), 90, 270, STROKE - 2)
    arc(d, (86, 18, 120, 58), 270, 90, STROKE - 2)
    d.rectangle((56, 74, 72, 96), fill=255)
    d.rounded_rectangle((36, 96, 92, 114), radius=5, fill=255)


def i_hammer(d, m):
    d.polygon([(30, 22), (78, 22), (92, 36), (92, 50), (30, 50)], fill=255)
    line(d, [(60, 50), (60, 114)], STROKE + 3)


def i_flame(d, m):
    d.polygon([(64, 8), (88, 40), (98, 70), (92, 96), (64, 112), (36, 96), (30, 70), (42, 46), (52, 60)], fill=255)
    d.polygon([(64, 58), (76, 78), (72, 98), (56, 98), (52, 82)], fill=0)


def i_campfire(d, m):
    d.polygon([(64, 6), (84, 34), (90, 58), (80, 80), (64, 86), (48, 80), (38, 58), (48, 38), (56, 50)], fill=255)
    d.polygon([(64, 50), (72, 64), (70, 78), (58, 78), (56, 66)], fill=0)
    line(d, [(18, 116), (110, 94)], STROKE + 2)
    line(d, [(18, 94), (110, 116)], STROKE + 2)


def i_eye(d, m):
    d.chord((8, 30, 120, 126), 200, 340, fill=255)
    d.chord((8, 2, 120, 98), 20, 160, fill=255)
    d.chord((20, 40, 108, 116), 200, 340, fill=0)
    d.chord((20, 12, 108, 88), 20, 160, fill=0)
    d.ellipse((44, 44, 84, 84), fill=255)
    d.ellipse((58, 56, 70, 68), fill=0)


def i_gear(d, m):
    c = 64
    for i in range(8):
        a = i * math.pi / 4
        x, y = c + math.cos(a) * 46, c + math.sin(a) * 46
        d.regular_polygon((x, y, 13), 4, rotation=math.degrees(a) + 45, fill=255)
    d.ellipse((24, 24, 104, 104), fill=255)
    d.ellipse((46, 46, 82, 82), fill=0)


def i_close(d, m):
    line(d, [(32, 32), (96, 96)], STROKE + 2)
    line(d, [(96, 32), (32, 96)], STROKE + 2)


def i_search(d, m):
    d.ellipse((16, 16, 84, 84), outline=255, width=STROKE + 1)
    line(d, [(78, 78), (110, 110)], STROKE + 5)


def i_chev_down(d, m):
    line(d, [(32, 50), (64, 82), (96, 50)], STROKE + 2)


def i_chev_right(d, m):
    line(d, [(50, 32), (82, 64), (50, 96)], STROKE + 2)


def i_chev_left(d, m):
    line(d, [(78, 32), (46, 64), (78, 96)], STROKE + 2)


def i_plus(d, m):
    line(d, [(64, 24), (64, 104)], STROKE + 2)
    line(d, [(24, 64), (104, 64)], STROKE + 2)


def i_minus(d, m):
    line(d, [(24, 64), (104, 64)], STROKE + 2)


def star_pts(cx, cy, r1, r2):
    pts = []
    for i in range(10):
        a = -math.pi / 2 + i * math.pi / 5
        r = r1 if i % 2 == 0 else r2
        pts.append((cx + math.cos(a) * r, cy + math.sin(a) * r))
    return pts


def i_star(d, m):
    d.polygon(star_pts(64, 68, 56, 24), outline=255, width=STROKE - 2)


def i_star_fill(d, m):
    d.polygon(star_pts(64, 68, 56, 24), fill=255)


def i_crown(d, m):
    d.polygon([(14, 36), (40, 66), (64, 26), (88, 66), (114, 36), (104, 96), (24, 96)], fill=255)
    d.rounded_rectangle((24, 102, 104, 116), radius=4, fill=255)


def i_skull(d, m):
    d.ellipse((18, 10, 110, 96), fill=255)
    d.rounded_rectangle((38, 70, 90, 116), radius=10, fill=255)
    d.ellipse((34, 44, 58, 70), fill=0)
    d.ellipse((70, 44, 94, 70), fill=0)
    d.polygon([(64, 70), (56, 86), (72, 86)], fill=0)
    for x in (50, 64, 78):
        d.rectangle((x - 3, 100, x + 3, 116), fill=0)


def i_coin(d, m):
    d.ellipse((14, 14, 114, 114), outline=255, width=STROKE)
    d.ellipse((38, 38, 90, 90), fill=255)


def i_sync(d, m):
    arc(d, (20, 20, 108, 108), 200, 340)
    arc(d, (20, 20, 108, 108), 20, 160)
    d.polygon([(100, 26), (110, 60), (78, 50)], fill=255)
    d.polygon([(28, 102), (18, 68), (50, 78)], fill=255)


def i_bubble(d, m):
    d.rounded_rectangle((12, 18, 116, 88), radius=24, outline=255, width=STROKE)
    d.polygon([(34, 84), (34, 116), (64, 86)], fill=255)


def i_bell(d, m):
    d.chord((26, 14, 102, 90), 180, 360, fill=255)
    d.polygon([(26, 52), (102, 52), (114, 98), (14, 98)], fill=255)
    d.ellipse((52, 98, 76, 122), fill=255)


def i_warning(d, m):
    d.polygon([(64, 8), (122, 112), (6, 112)], fill=255)
    d.rounded_rectangle((57, 40, 71, 82), radius=5, fill=0)
    d.ellipse((56, 88, 72, 104), fill=0)


def i_shield(d, m):
    d.polygon([(64, 8), (112, 26), (106, 76), (64, 120), (22, 76), (16, 26)], fill=255)
    d.polygon([(64, 24), (96, 36), (92, 72), (64, 102)], fill=0)


def i_cross(d, m):
    d.rounded_rectangle((48, 12, 80, 116), radius=6, fill=255)
    d.rounded_rectangle((12, 48, 116, 80), radius=6, fill=255)


def i_sword(d, m):
    line(d, [(30, 98), (104, 24)], STROKE + 1)
    line(d, [(22, 74), (54, 106)], STROKE + 1)
    line(d, [(14, 114), (32, 96)], STROKE + 3)


def i_bow(d, m):
    arc(d, (-34, 6, 92, 122), 298, 62, STROKE)
    line(d, [(58, 12), (58, 116)], 5)
    line(d, [(12, 64), (104, 64)], STROKE - 3)
    d.polygon([(122, 64), (96, 48), (96, 80)], fill=255)
    d.polygon([(12, 64), (2, 52), (22, 52), (30, 64), (22, 76), (2, 76)], fill=255)


def i_home(d, m):
    d.polygon([(64, 12), (118, 60), (104, 60), (104, 114), (24, 114), (24, 60), (10, 60)], fill=255)
    d.rectangle((52, 78, 76, 114), fill=0)


def i_filter(d, m):
    d.polygon([(12, 18), (116, 18), (74, 66), (74, 112), (54, 100), (54, 66)], fill=255)


def i_trash(d, m):
    d.rounded_rectangle((26, 36, 102, 118), radius=8, fill=255)
    d.rectangle((14, 22, 114, 32), fill=255)
    d.rectangle((48, 10, 80, 22), fill=255)
    for x in (46, 64, 82):
        d.rectangle((x - 4, 50, x + 4, 104), fill=0)


def i_megaphone(d, m):
    d.polygon([(18, 48), (46, 48), (104, 16), (104, 112), (46, 80), (18, 80)], fill=255)
    d.rectangle((30, 80, 48, 112), fill=255)


def i_clock(d, m):
    d.ellipse((12, 12, 116, 116), outline=255, width=STROKE)
    line(d, [(64, 34), (64, 66), (88, 80)])


def i_lock(d, m):
    arc(d, (34, 10, 94, 76), 180, 360)
    d.rectangle((34, 42, 45, 56), fill=255)
    d.rectangle((83, 42, 94, 56), fill=255)
    d.rounded_rectangle((20, 54, 108, 118), radius=12, fill=255)
    d.ellipse((56, 72, 72, 88), fill=0)


def i_export(d, m):
    d.rounded_rectangle((16, 44, 112, 116), radius=10, outline=255, width=STROKE)
    d.rectangle((44, 38, 84, 52), fill=0)
    line(d, [(64, 82), (64, 14)])
    line(d, [(42, 36), (64, 14), (86, 36)])


def i_import(d, m):
    d.rounded_rectangle((16, 44, 112, 116), radius=10, outline=255, width=STROKE)
    d.rectangle((44, 38, 84, 52), fill=0)
    line(d, [(64, 14), (64, 82)])
    line(d, [(42, 60), (64, 82), (86, 60)])


def i_heart(d, m):
    d.ellipse((12, 18, 66, 72), fill=255)
    d.ellipse((62, 18, 116, 72), fill=255)
    d.polygon([(16, 56), (112, 56), (64, 114)], fill=255)


def i_bolt(d, m):
    d.polygon([(72, 6), (24, 72), (58, 72), (48, 122), (104, 50), (68, 50)], fill=255)


def i_dot(d, m):
    d.ellipse((34, 34, 94, 94), fill=255)


def i_ring(d, m):
    d.ellipse((30, 30, 98, 98), outline=255, width=STROKE)


def i_bag(d, m):
    arc(d, (40, 8, 88, 56), 180, 360)
    d.rounded_rectangle((18, 36, 110, 118), radius=16, fill=255)


def i_pin(d, m):
    d.ellipse((30, 8, 98, 76), fill=255)
    d.polygon([(34, 56), (94, 56), (64, 120)], fill=255)
    d.ellipse((52, 30, 76, 54), fill=0)


ICONS = {
    "roster": i_roster, "calendar": i_calendar, "dice": i_dice, "check": i_check,
    "clipboard": i_clipboard, "trophy": i_trophy, "hammer": i_hammer, "flame": i_flame,
    "campfire": i_campfire, "eye": i_eye, "gear": i_gear, "close": i_close, "search": i_search,
    "chevron_down": i_chev_down, "chevron_right": i_chev_right, "chevron_left": i_chev_left,
    "plus": i_plus, "minus": i_minus, "star": i_star, "star_fill": i_star_fill, "crown": i_crown,
    "skull": i_skull, "coin": i_coin, "sync": i_sync, "bubble": i_bubble, "bell": i_bell,
    "warning": i_warning, "shield": i_shield, "cross": i_cross, "sword": i_sword, "bow": i_bow,
    "home": i_home, "filter": i_filter, "trash": i_trash, "megaphone": i_megaphone,
    "clock": i_clock, "lock": i_lock, "export": i_export, "import": i_import, "heart": i_heart,
    "bolt": i_bolt, "dot": i_dot, "ring": i_ring, "bag": i_bag, "pin": i_pin,
}


def preview():
    """Contact sheet for eyeballing the set (not shipped)."""
    names = sorted(ICONS)
    cols = 12
    rows = (len(names) + cols - 1) // cols
    sheet = Image.new("RGBA", (cols * 48, rows * 48 + 400), (18, 24, 20, 255))
    for i, n in enumerate(names):
        ic = Image.open(os.path.join(OUT, "icon_" + n + ".tga"))
        sheet.alpha_composite(ic, ((i % cols) * 48 + 8, (i // cols) * 48 + 8))
    y = rows * 48 + 8
    for n in ("logo",):
        im = Image.open(os.path.join(OUT, n + ".tga"))
        sheet.alpha_composite(im, (8, y))
    sheet.alpha_composite(Image.open(os.path.join(OUT, "minimap.tga")), (530, y))
    sheet.alpha_composite(Image.open(os.path.join(OUT, "sign_yellow.tga")).resize((256, 64)), (300, y + 140))
    sheet.alpha_composite(Image.open(os.path.join(OUT, "welcome.tga")).resize((256, 128)), (8, y + 140))
    sheet.alpha_composite(Image.open(os.path.join(OUT, "hazard.tga")), (300, y + 220))
    return sheet


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    make_logo()
    make_signs()
    make_minimap()
    make_utility()
    for n, fn in ICONS.items():
        icon(n, fn)
    out = os.path.join(ROOT, "tools", "media_preview.png")
    preview().save(out)
    print("wrote", len(os.listdir(OUT)), "files; preview:", out)
