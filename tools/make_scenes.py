"""Paints the page banners in Greenfields/Media/art.

    python -P tools/make_scenes.py               # all of them
    python -P tools/make_scenes.py home raids    # just these

Since Nov 2026 the banners that ship are pixel art built by tools/pixel_art.py from these: running this
paints the poster versions back over them, so run tools/pixel_art.py afterwards to put them back.

Each banner is tools/scenes/<page>.py, with a paint() that returns the finished image. A PNG copy
goes to tools/art/scenes/ for looking at (it isn't shipped). The list the addon reads is
Greenfields/Data/Art.lua, written by tools/import_art.py.
"""
import importlib
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "scenes"))
import make_media  # noqa: E402

PREVIEW = os.path.join(HERE, "art", "scenes")
MEDIA_ART = os.path.join(os.path.dirname(HERE), "Greenfields", "Media", "art")


def all_scenes():
    return sorted(f[:-3] for f in os.listdir(os.path.join(HERE, "scenes"))
                  if f.endswith(".py") and not f.startswith("_"))


def main(names):
    os.makedirs(PREVIEW, exist_ok=True)
    make_media.OUT = MEDIA_ART
    for name in names or all_scenes():
        mod = importlib.import_module(name)
        img = mod.paint()
        img.save(os.path.join(PREVIEW, name + ".png"))
        make_media.save_tga(img.convert("RGBA"), "hero_" + name)
        print("painted", name, img.size)


if __name__ == "__main__":
    main(sys.argv[1:])
