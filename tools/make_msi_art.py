"""Paints the Greenfields installer's art into installer/art/ (committed, so building the MSI
never needs Pillow):

    crest.ico           the pixel crest at every icon size (Add/Remove Programs, Start menu, dialogs)
    hero_*.bmp          full-dialog night scenes for Welcome / Done / Something went wrong
    page_*.bmp          the inner pages: a strip of a night-street banner on top, midnight navy below

    python -P tools/make_msi_art.py            (system Python with Pillow; -P, not -I, so PIL imports)

Everything comes from tools/art/pixel/ (crest.png, banners/*.png). The pixel art is used at 1:1
so it stays crisp at 100% display scaling; Windows stretches it on bigger scaling like any installer.
Positions here match the dialog layout in installer/UI.wxs (370 x 270 dialog units).
"""
import os
import random

from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PIXEL = os.path.join(ROOT, "tools", "art", "pixel")
OUT = os.path.join(ROOT, "installer", "art")

# A 370 x 270 dialog-unit dialog in Segoe UI 8 is this many pixels at 100% scaling
# (measured from a screenshot of the built installer: see installer/README.md).
DU_X = 493 / 370
DU_Y = 360 / 270
W = round(370 * DU_X)
H = round(270 * DU_Y)
BAR_Y = round(234 * DU_Y)       # top of the button bar
HEAD_H = round(57 * DU_Y)       # inner-page header strip

# addon palette (Greenfields/UI/Theme.lua)
BG0 = (9, 12, 19)
BG1 = (11, 14, 21)
BG2 = (18, 23, 32)
BRONZE = (65, 55, 41)


def banner(name):
    return Image.open(os.path.join(PIXEL, "banners", name + ".png")).convert("RGB")


def mix(a, b, t):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))


BAYER4 = [[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]]


def dithered(c, x, y, step=4):
    """Ordered dither to a coarse step, so painted gradients have the banners' pixel-art texture."""
    t = (BAYER4[y % 4][x % 4] + 0.5) / 16.0
    return tuple(max(0, min(255, int((v / step) + t) * step)) for v in c)


def stars(img, top, bottom, count, seed, left=0, right=None):
    rnd = random.Random(seed)
    px = img.load()
    right = img.width if right is None else right
    for _ in range(count):
        x = rnd.randrange(left, right)
        y = rnd.randrange(top, bottom)
        depth = 1.0 - (y - top) / max(1, bottom - top)     # brighter higher up
        b = rnd.random() * 0.6 * (0.4 + 0.6 * depth)
        base = px[x, y]
        tint = rnd.choice([(255, 250, 235), (220, 230, 255), (255, 235, 200)])
        px[x, y] = mix(base, tint, min(1.0, 0.25 + b))
        if rnd.random() < 0.06:                              # the odd brighter star with a cross
            for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                if left <= x + dx < right and top <= y + dy < bottom:
                    px[x + dx, y + dy] = mix(px[x + dx, y + dy], tint, 0.35)


def sky_above(strip, height, top_color):
    """Continues a banner's sky upwards, dithered. Right at the seam each column carries on from
    the banner's own top edge; higher up it settles to the edge's average colour, so a moon's
    glow doesn't shoot a light pillar up behind the text; the very top fades to top_color."""
    w = strip.width
    edge_img = strip.crop((0, 0, w, 6)).resize((w, 1), Image.BOX).filter(ImageFilter.BoxBlur(18))
    edge = edge_img.load()
    mean = edge_img.resize((1, 1), Image.BOX).getpixel((0, 0))
    sky = Image.new("RGB", (w, height))
    px = sky.load()
    for y in range(height):
        f = y / max(1, height - 1)
        t = f ** 1.6                                         # hold the dark top longer
        local = f ** 10                                      # per-column colour only near the seam
        for x in range(w):
            target = mix(mean, edge[x, 0], local)
            px[x, y] = dithered(mix(top_color, target, t), x, y)
    return sky


def crest_image(scale):
    c = Image.open(os.path.join(PIXEL, "crest.png")).convert("RGBA")
    c = c.crop(c.getbbox())
    return c.resize((c.width * scale, c.height * scale), Image.NEAREST)


def soft_shadow(img, art, at, radius=6, alpha=150):
    mask = Image.new("L", img.size, 0)
    a = art.split()[3].point(lambda v: alpha if v > 0 else 0)
    mask.paste(a, (at[0] + 3, at[1] + 4))
    mask = mask.filter(ImageFilter.GaussianBlur(radius))
    img.paste(Image.new("RGB", img.size, (0, 0, 0)), (0, 0), mask)


def hero(name, crop_x, seed):
    """Night sky with the crest on the left, a street scene along the bottom, dark ground under
    the buttons. Text sits on the sky to the right of the crest (UI.wxs: X 122+ DU)."""
    b = banner(name)
    strip = b.crop((crop_x, 0, crop_x + W, b.height))
    strip_y = BAR_Y - strip.height + 6                      # ground runs just past the bar line
    img = Image.new("RGB", (W, H), BG0)
    sky = sky_above(strip, strip_y, (5, 7, 14))
    img.paste(sky, (0, 0))
    stars(img, 0, strip_y, 260, seed)
    img.paste(strip, (0, strip_y))
    # ground under the button bar: the strip's bottom row, darkened toward the window colour
    ground = strip.crop((0, strip.height - 1, W, strip.height)).resize((W, 1)).load()
    px = img.load()
    for y in range(strip_y + strip.height, H):
        t = min(1.0, (y - (strip_y + strip.height)) / 18.0)
        for x in range(W):
            px[x, y] = dithered(mix(ground[x, 0], BG0, 0.35 + 0.65 * t), x, y)
    # crest, 2x pixel scale, with a soft shadow so it lifts off the sky
    crest = crest_image(2)
    at = (round(14 * DU_X), round(18 * DU_Y))
    soft_shadow(img, crest, at)
    img.paste(crest, at, crest)
    return img


def page(name, crop_x, crop_y, seed):
    """Header strip from a banner (darkened on the left so the gold title reads), a bronze
    hairline, midnight navy body, and a slightly darker button bar."""
    b = banner(name)
    head = b.crop((crop_x, crop_y, crop_x + W, crop_y + HEAD_H)).convert("RGB")
    px = head.load()
    sub_top, sub_bottom = round(33 * DU_Y), round(50 * DU_Y)   # the subtitle line (UI.wxs Y 34, 14 high)
    for y in range(HEAD_H):
        # a dim band right across behind the subtitle, feathered, so it reads over lit windows
        if y < sub_top:
            band = max(0.0, 1.0 - (sub_top - y) / 6.0)
        elif y > sub_bottom:
            band = max(0.0, 1.0 - (y - sub_bottom) / 6.0)
        else:
            band = 1.0
        for x in range(W):
            shade = max(0.0, 1.0 - x / (W * 0.62)) ** 1.3 * 0.72   # left side darker, for the title
            v = shade + band * 0.62 * (1 - shade)
            v += max(0.0, (y - HEAD_H * 0.55) / (HEAD_H * 0.45)) * 0.25 * (1 - v)
            px[x, y] = dithered(mix(px[x, y], BG1, min(1.0, v)), x, y, 2)
    img = Image.new("RGB", (W, H), BG1)
    img.paste(head, (0, 0))
    d = ImageDraw.Draw(img)
    d.line([(0, HEAD_H), (W, HEAD_H)], fill=BRONZE)
    body = img.load()
    for y in range(HEAD_H + 1, BAR_Y):                          # a faint lift toward the middle
        t = (y - HEAD_H) / (BAR_Y - HEAD_H)
        c = mix(BG2, BG1, min(1.0, t * 1.4))
        for x in range(W):
            body[x, y] = dithered(c, x, y, 2)
    d.rectangle([(0, BAR_Y), (W, H)], fill=BG0)
    d.line([(0, BAR_Y), (W, BAR_Y)], fill=BRONZE)
    return img


def ico():
    """crest.ico: the 88 px pixel crest. Big sizes are whole-number pixel scales on a square
    canvas (crisp); small ones are smooth reductions, where single pixels would be mush anyway."""
    c = Image.open(os.path.join(PIXEL, "crest.png")).convert("RGBA")
    c = c.crop(c.getbbox())
    side = max(c.size)
    sq = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    sq.paste(c, ((side - c.width) // 2, (side - c.height) // 2), c)
    big = sq.resize((side * 3, side * 3), Image.NEAREST)        # 219 px of crisp pixels
    frames = {}
    canvas = Image.new("RGBA", (256, 256), (0, 0, 0, 0))
    canvas.paste(big, ((256 - big.width) // 2, (256 - big.height) // 2), big)
    frames[256] = canvas
    for s in (128, 96, 64, 48, 40, 32, 24, 20, 16):
        inner = round(s * 0.94)
        small = sq.resize((inner, inner), Image.LANCZOS)
        f = Image.new("RGBA", (s, s), (0, 0, 0, 0))
        f.paste(small, ((s - inner) // 2, (s - inner) // 2), small)
        frames[s] = f
    path = os.path.join(OUT, "crest.ico")
    write_ico(path, [frames[s] for s in sorted(frames)])
    return path


def write_ico(path, images):
    """An .ico with classic 32-bit bitmap frames, plus PNG only for 256 px. Pillow writes every
    frame as PNG, and Windows Installer's icon loader only reads bitmap frames (it fell back to
    the 256 px one and logged error 2863)."""
    import io
    import struct
    blobs = []
    for im in images:
        w, h = im.size
        if w >= 256:
            buf = io.BytesIO()
            im.save(buf, format="PNG")
            blobs.append(buf.getvalue())
            continue
        header = struct.pack("<IiiHHIIiiII", 40, w, h * 2, 1, 32, 0, 0, 0, 0, 0, 0)
        px = im.load()
        rows = []
        for y in range(h - 1, -1, -1):                                  # bottom-up BGRA
            rows.append(b"".join(struct.pack("BBBB", px[x, y][2], px[x, y][1], px[x, y][0], px[x, y][3]) for x in range(w)))
        stride = ((w + 31) // 32) * 4
        mask = []
        for y in range(h - 1, -1, -1):                                  # AND mask: 1 = transparent
            bits = bytearray(stride)
            for x in range(w):
                if px[x, y][3] == 0:
                    bits[x // 8] |= 0x80 >> (x % 8)
            mask.append(bytes(bits))
        blobs.append(header + b"".join(rows) + b"".join(mask))
    out = struct.pack("<HHH", 0, 1, len(images))
    offset = 6 + 16 * len(images)
    for im, blob in zip(images, blobs):
        w, h = im.size
        out += struct.pack("<BBBBHHII", w % 256, h % 256, 0, 0, 1, 32, len(blob), offset)
        offset += len(blob)
    with open(path, "wb") as f:
        f.write(out + b"".join(blobs))


def main():
    os.makedirs(OUT, exist_ok=True)
    made = [ico()]
    heroes = {"hero_welcome": ("gate", 150, 11), "hero_finish": ("home", 222, 12), "hero_oops": ("raids", 260, 13)}
    for out, (name, x, seed) in heroes.items():
        path = os.path.join(OUT, out + ".bmp")
        hero(name, min(x, 800 - W), seed).save(path)
        made.append(path)
    pages = {"page_setup": ("feed", 280, 26, 21), "page_inuse": ("raids", 260, 30, 22),
             "page_progress": ("tradies", 250, 30, 23), "page_maint": ("roster", 230, 30, 24)}
    for out, (name, x, y, seed) in pages.items():
        path = os.path.join(OUT, out + ".bmp")
        page(name, min(x, 800 - W), min(y, 112 - HEAD_H), seed).save(path)
        made.append(path)
    for p in made:
        print("  %s  (%d KB)" % (os.path.relpath(p, ROOT), os.path.getsize(p) // 1024))


if __name__ == "__main__":
    main()
