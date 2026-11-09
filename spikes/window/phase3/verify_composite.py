#!/usr/bin/env python3 -I
"""Offline check of WindowChromeRenderer: Finder-alone (88 pt reference) + our shadow + our body,
compared with a real single window of the combined height (reference capture). Usage:
verify_composite.py <render_dir> <H>   (needs ref/<variant>-<88+H>/shadow.png)"""
import sys, os
from PIL import Image
HERE = os.path.dirname(os.path.abspath(__file__))
rd, H = sys.argv[1], int(sys.argv[2]); BAND = 24
def over(dst, src, x, y):
    dst.alpha_composite(src, (x, y))
def load(p): return Image.open(p).convert('RGBA')
for v in ['dark-nokey', 'dark-key', 'light-nokey', 'light-key']:
    ref88 = load(f'{HERE}/ref/{v}/shadow.png'); refT = load(f'{HERE}/ref/{v}-{88 + H}/shadow.png')
    px = ref88.load(); W0, H0 = ref88.size
    ox = min(x for x in range(W0) if px[x, H0 // 2][3] == 255); oy = min(y for y in range(H0) if px[W0 // 2, y][3] == 255)
    bg = px[ox + 200, oy + 60][:3]
    canvas = Image.new('RGBA', refT.size, (0, 0, 0, 0)); over(canvas, ref88, 0, 0)
    sh = load(f'{rd}/{v}-shadow.png'); padX = (sh.size[0] - 404) // 2
    finder_bottom = oy + 88
    over(canvas, sh, ox - padX, finder_bottom - BAND)
    mask = load(f'{rd}/{v}-mask.png').split()[3]; ovl = load(f'{rd}/{v}-overlay.png')
    fill = Image.new('RGBA', mask.size, bg + (255,)); fill.putalpha(mask)
    over(canvas, fill, ox, finder_bottom - BAND); over(canvas, ovl, ox, finder_bottom - BAND)
    # Compare over two backgrounds (grey + orange) in the region our windows touch.
    worst = 0; worst_at = None; hist = [0] * 256
    for back in [(128, 128, 128, 255), (220, 140, 60, 255)]:
        a = Image.new('RGBA', refT.size, back); a.alpha_composite(canvas)
        b = Image.new('RGBA', refT.size, back); b.alpha_composite(refT)
        pa, pb = a.load(), b.load()
        for y in range(finder_bottom - BAND, refT.size[1]):
            for x in range(refT.size[0]):
                d = max(abs(pa[x, y][i] - pb[x, y][i]) for i in range(3))
                hist[d] += 1
                if d > worst: worst, worst_at = d, (x - ox, y - finder_bottom)
        if back[0] == 128:
            a.crop((0, finder_bottom - 40, 130, refT.size[1])).resize((520, (refT.size[1] - finder_bottom + 40) * 4), Image.NEAREST).save(f'{rd}/{v}-ours-zoom.png')
            b.crop((0, finder_bottom - 40, 130, refT.size[1])).resize((520, (refT.size[1] - finder_bottom + 40) * 4), Image.NEAREST).save(f'{rd}/{v}-ref-zoom.png')
    n = sum(hist); le2 = sum(hist[:3])
    print(f'{v}: max |diff| {worst} at (x,yb)={worst_at}; pixels within ±2: {le2}/{n} ({100 * le2 / n:.2f}%); >5: {sum(hist[6:])}')
