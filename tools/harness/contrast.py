"""Legibility check: how readable is every piece of text against what's actually behind it?

    python -P tools/harness/contrast.py OUT\\scenes\\Spencer-home.json [more scenes...] [--min 4.5] [--all]

Renders each scene without its text, samples the pixels under each string, and works out the WCAG
contrast ratio of the text colour against the worst and the typical background there. Reports strings
under the limit: 4.5 for normal text, 3 for large text (18 and over, or 14 and over when bold-ish).
A ratio under 3 at normal size means players will actually struggle, not just that a rule was broken.
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
os.environ.pop("GF_RENDER_SCALE", None)
import json  # noqa: E402

import numpy as np  # noqa: E402
import render  # noqa: E402

COLOR_RUN = re.compile(r"\|c([0-9a-fA-F]{8})(.*?)(?=\|c[0-9a-fA-F]{8}|\|r|$)", re.S)
STRIP = re.compile(r"\|c[0-9a-fA-F]{8}|\|r|\|H.*?\|h|\|h|\|T.*?\|t|\|A.*?\|a")


def lin(c):
    c = c / 255.0
    return np.where(c <= 0.03928, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def lum(rgb):
    return 0.2126 * lin(rgb[..., 0]) + 0.7152 * lin(rgb[..., 1]) + 0.0722 * lin(rgb[..., 2])


def ratio(a, b):
    hi, lo = max(a, b), min(a, b)
    return (hi + 0.05) / (lo + 0.05)


def text_colours(it):
    """-> list of (rgb 0..255, text) runs for a font item."""
    fnt = it.get("font") or {}
    base = fnt.get("color") or [1, 1, 1, 1]
    alpha = (base[3] if len(base) > 3 else 1) * it.get("alpha", 1)
    text = fnt.get("text") or ""
    runs = []
    plain = COLOR_RUN.sub("", text)
    plain = STRIP.sub("", plain).strip()
    if plain:
        runs.append((np.array(base[:3], float) * 255, plain, alpha))
    for m in COLOR_RUN.finditer(text):
        run = STRIP.sub("", m.group(2)).strip()
        if run:
            h = m.group(1)
            runs.append((np.array([int(h[2:4], 16), int(h[4:6], 16), int(h[6:8], 16)], float), run, alpha))
    return runs


def check(path, limit):
    scene = json.load(open(path, encoding="utf-8"))
    r = render.Renderer()
    r.draw_font = lambda canvas, it: None  # background only
    img = r.render(scene)
    bg = np.asarray(img.convert("RGB"), dtype=np.float32)
    H, W = bg.shape[:2]
    out = []
    for it in scene.get("items", []):
        if it.get("kind") != "font":
            continue
        x, y, w, h = it["rect"]
        # the rect can be much wider than the words: only what's behind the words matters
        fnt0 = it.get("font") or {}
        if not fnt0.get("wrap"):
            try:
                ink = r.font(fnt0.get("file"), fnt0.get("size") or 12)[0].getlength(STRIP.sub("", fnt0.get("text") or ""))
                if ink < w:
                    jh = fnt0.get("justifyH")
                    x = x + (w - ink) / 2 if jh == "CENTER" else (x + w - ink if jh == "RIGHT" else x)
                    w = ink
            except Exception:
                pass
        x0, y0, x1, y1 = int(max(0, x)), int(max(0, y)), int(min(W, x + w)), int(min(H, y + h))
        clip = it.get("clip")
        if clip:
            cx, cy, cw, ch = clip
            x0, y0, x1, y1 = int(max(x0, cx)), int(max(y0, cy)), int(min(x1, cx + cw)), int(min(y1, cy + ch))
        if x1 - x0 < 2 or y1 - y0 < 2:
            continue
        fnt = it.get("font") or {}
        size = fnt.get("size") or 12
        need = 3.0 if size >= 18 else limit
        patch = bg[y0:y1, x0:x1]
        L = lum(patch)
        for rgb, run, alpha in text_colours(it):
            # text alpha blends it toward the background
            seen = rgb * alpha + patch.mean(axis=(0, 1)) * (1 - alpha)
            tl = float(lum(seen[None, None, :])[0, 0])
            typical = ratio(tl, float(np.median(L)))
            worst = min(ratio(tl, float(np.percentile(L, 95))), ratio(tl, float(np.percentile(L, 5))))
            out.append((worst, typical, size, need, run[:60], str(fnt.get("file", ""))[-12:], [int(x), int(y)]))
    return out


def main(argv):
    limit, show_all, files = 4.5, False, []
    i = 0
    while i < len(argv):
        if argv[i] == "--min":
            limit = float(argv[i + 1])
            i += 2
        elif argv[i] == "--all":
            show_all = True
            i += 1
        else:
            files.append(argv[i])
            i += 1
    bad = 0
    for f in files:
        rows = check(f, limit)
        flagged = [r for r in rows if r[0] < r[3]]
        flagged.sort()
        print("%s: %d strings, %d under the limit" % (os.path.basename(f), len(rows), len(flagged)))
        for w, t, size, need, run, font, pos in (rows if show_all else flagged)[:60]:
            print("  %4.1f worst %4.1f typical  size %2d  at %-11s %s" % (w, t, size, tuple(pos), run))
        bad += len(flagged)
    return bad


if __name__ == "__main__":
    main(sys.argv[1:])
