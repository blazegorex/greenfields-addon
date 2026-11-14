"""The level 60 art and sound: the lookout scene behind the ceremony, the Sixty medal and the fanfare.
Writes Greenfields/Media/art/sixty_hero.tga, sixty_medal.tga and Media/sound/sixty_*.ogg (needs ffmpeg).

    python -P tools/sixty_art.py                  build the game files from tools/art/sixty/
    python -P tools/sixty_art.py --cut <dir>      take fresh raw images (<dir>/hero.png, <dir>/medal.png) first

Both were painted with Scenario (GPT Image 2.5) on 14 Nov 2026: the hero with the home and gate banners
as style references, the medal on a transparent background. --cut trims the white padding the model puts
round a wide picture and the medal's soft halo, then keeps them in tools/art/sixty/, which is the source
of truth from then on. The raw images stay in gitignored dist/art-src/sixty/.

The hero is shrunk by 3 and held to 64 colours, then doubled back up with hard edges, so its pixels sit
with the pixel-art banners. It fills the top HERO_H rows of a 1024 x 512 texture; Modules/SixtyUI.lua
crops the rest off with its texture coordinates.
"""
import os
import subprocess
import sys

from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import make_media  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "tools", "art", "sixty")
OUT = os.path.join(ROOT, "Greenfields", "Media", "art")

HERO_W = 1024   # the texture's width; the art is HERO_W x HERO_H at its top
HERO_H = 304    # keep in step with HERO_TC in Modules/SixtyUI.lua
MEDAL = 256


def cut(raw_dir):
    """Trims the raw picture and medal into tools/art/sixty/."""
    os.makedirs(SRC, exist_ok=True)
    hero = Image.open(os.path.join(raw_dir, "hero.png")).convert("RGB")
    w, h = hero.size
    px = hero.load()

    def white_row(y):
        n = sum(1 for x in range(0, w, 4) if min(px[x, y]) > 235)
        return n > (w // 4) * 0.5

    top = next(y for y in range(h) if not white_row(y))
    bottom = next(y for y in range(h - 1, -1, -1) if not white_row(y))
    # two rows in from each edge: the band's own edge is soft into the white
    hero.crop((0, top + 2, w, bottom - 1)).save(os.path.join(SRC, "hero.png"))

    medal = Image.open(os.path.join(raw_dir, "medal.png")).convert("RGBA")
    # the model paints a soft dark halo round it: only the solid medal stays
    r, g, b, a = medal.split()
    a = a.point(lambda v: 255 if v > 160 else 0)
    medal = Image.merge("RGBA", (r, g, b, a))
    box = medal.getbbox()
    side = max(box[2] - box[0], box[3] - box[1]) + 16
    cx, cy = (box[0] + box[2]) // 2, (box[1] + box[3]) // 2
    sq = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    sq.paste(medal.crop((cx - side // 2, cy - side // 2, cx - side // 2 + side, cy - side // 2 + side)), (0, 0))
    sq.save(os.path.join(SRC, "medal.png"))


def pixelate(img, small, colours=64):
    """Shrinks to `small` (w, h), holds the colours to a palette, and returns the small image."""
    rgb = img.convert("RGB").resize(small, Image.BOX)
    return rgb.quantize(colors=colours, method=Image.MEDIANCUT, dither=Image.NONE).convert("RGB")


def build():
    hero = Image.open(os.path.join(SRC, "hero.png")).convert("RGB")
    small = pixelate(hero, (HERO_W // 2, HERO_H // 2))
    canvas = Image.new("RGBA", (HERO_W, 512), (5, 7, 14, 255))
    canvas.paste(small.resize((HERO_W, HERO_H), Image.NEAREST), (0, 0))
    make_media.save_tga(canvas, os.path.join("art", "sixty_hero"))

    medal = Image.open(os.path.join(SRC, "medal.png")).convert("RGBA")
    half = MEDAL // 2
    alpha = medal.split()[3].resize((half, half), Image.BOX).point(lambda v: 255 if v > 128 else 0)
    rgb = pixelate(medal, (half, half), colours=48)
    small = rgb.convert("RGBA")
    small.putalpha(alpha)
    make_media.save_tga(small.resize((MEDAL, MEDAL), Image.NEAREST), os.path.join("art", "sixty_medal"))
    print("wrote sixty_hero.tga, sixty_medal.tga")
    sounds()


# The fanfare: ElevenLabs Music v2.5 through Scenario, 14 Nov 2026, 18 s, instrumental. It rings out at
# about 15 s. The ceremony gets all of it, quieter than it came; a guildie's banner gets the first bars.
SOUNDS = {
    "sixty_fanfare": "atrim=0:16,afade=t=out:st=15.2:d=0.8",
    "sixty_short": "atrim=0:5.5,afade=t=out:st=3.8:d=1.7",
}


def sounds():
    src = os.path.join(SRC, "fanfare.mp3")
    out = os.path.join(ROOT, "Greenfields", "Media", "sound")
    os.makedirs(out, exist_ok=True)
    for name, cut_filter in SOUNDS.items():
        subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", src,
                        "-af", cut_filter + ",loudnorm=I=-18:TP=-2:LRA=7", "-ar", "44100",
                        "-c:a", "libvorbis", "-q:a", "4", os.path.join(out, name + ".ogg")], check=True)
    print("wrote " + ", ".join(n + ".ogg" for n in SOUNDS))


if __name__ == "__main__":
    args = sys.argv[1:]
    if args[:1] == ["--cut"] and len(args) > 1:
        cut(args[1])
    build()
