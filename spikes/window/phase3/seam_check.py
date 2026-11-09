#!/usr/bin/env python3 -I
"""Pixel checks of the Finder window + speed panel seam (apollo, phase 3).

Input dir (from seam_check.sh): shot.png (copy running), clean.png (same region, nothing there),
windows.json (CG frames). region.txt: the captured rect (CG coordinates).

Shadow/outline alpha is estimated per pixel as a = 1 - shot/clean (the chrome is black), and compared
with the reference profiles of a single window (ref/<variant>-320/shadow.png).
"""
import json, os, sys
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
d = sys.argv[1]
J = json.load(open(os.path.join(d, 'windows.json')))
shot = Image.open(os.path.join(d, 'shot.png')).convert('RGB'); S = shot.load()
clean = Image.open(os.path.join(d, 'clean.png')).convert('RGB'); C = clean.load()
f = J['finder']; FW, FH = int(f['w']), int(f['h'])
RX, RY = [int(v) for v in open(os.path.join(d, 'region.txt')).read().split(',')[:2]]
FX, FY = int(f['x']) - RX, int(f['y']) - RY
body = min(J['panel'], key=lambda w: w['w']); shw = max(J['panel'], key=lambda w: w['w'])
BAND = 24; H = int(body['h'])   # body window = content only (band lives in the chrome window)
active = shw['w'] - FW > 80
FB = FY + FH   # first row below Finder (image y)

def lum(c): return (c[0] + c[1] + c[2]) / 3
def alpha(x, y):
    c, b = lum(S[x, y]), lum(C[x, y])
    return None if b < 30 else max(0.0, 1 - c / b)
def mode(pixels):
    from collections import Counter
    return Counter(pixels).most_common(1)[0][0]

finder_bg = mode([S[FX + x, FY + y] for x in range(2, 16) for y in range(34, FH - 2)])
body_bg = mode([S[FX + x, FB + y] for x in range(4, FW - 4) for y in range(1, H - 2)])
dark = lum(finder_bg) < 128
variant = ('dark' if dark else 'light') + ('-key' if active else '-nokey')
out = []
def p(s): out.append(s); print(s)
p(f'variant {variant}; Finder {FW}x{FH} at CG ({f["x"]:.0f},{f["y"]:.0f}); body height {H}; '
  f'body window {body["w"]:.0f}x{body["h"]:.0f}, shadow window {shw["w"]:.0f}x{shw["h"]:.0f}')
p(f'1. background: Finder {finder_bg}  panel body {body_bg}  max channel diff '
  f'{max(abs(a - b) for a, b in zip(finder_bg, body_bg))}')

def dev(c): return max(abs(a - b) for a, b in zip(c, finder_bg))
# 2. Seam line: rows around Finder's bottom edge, inner columns (Finder's text ends 8 px above the edge).
worst = 0; rows = []
for yb in range(-7, 4):
    ds = [dev(S[FX + x, FB + yb]) for x in range(20, FW - 20)]
    rows.append((yb, max(ds), sum(1 for v in ds if v <= 2) / len(ds)))
    worst = max(worst, max(ds))
p('2. seam rows (yb: max dev, share within ±2): ' + ', '.join(f'{yb}:{m}/{s:.0%}' for yb, m, s in rows))
# 3. Corners: no wallpaper notch, only fill (and the 1 px rim column at the very edge).
notch = []
for yb in range(-24, 6):
    for x in list(range(1, 16)) + list(range(FW - 16, FW - 1)):
        v = dev(S[FX + x, FB + yb])
        if v > 2: notch.append((x, yb, S[FX + x, FB + yb]))
p(f'3. corner pixels (x 1-15 and {FW - 16}-{FW - 2}, yb -24..5) off the background by >2: {len(notch)} of {30 * 30}'
  + (f'; e.g. {notch[:4]}' if notch else ''))
# 4. Edge columns: ring (x=-1) alpha and rim (x=0) colour, Finder part vs band vs body.
def col_stats(x, ys, f):
    vals = [f(x, y) for y in ys]; vals = [v for v in vals if v is not None]
    return (min(vals), max(vals)) if vals else (None, None)
segs = {'finder': range(FY + 40, FB - 24), 'band': range(FB - 24, FB), 'body': range(FB, FB + H - 26)}
for side, xr, xi in (('left', FX - 1, FX), ('right', FX + FW, FX + FW - 1)):
    ring = {k: col_stats(xr, ys, alpha) for k, ys in segs.items()}
    rim = {k: col_stats(xi, ys, lambda x, y: round(lum(S[x, y]))) for k, ys in segs.items()}
    p(f'4. {side} ring alpha (min,max): ' + ', '.join(f'{k} {v[0]:.2f}-{v[1]:.2f}' for k, v in ring.items() if v[0] is not None)
      + ' | rim lum: ' + ', '.join(f'{k} {v[0]}-{v[1]}' for k, v in rim.items()))
# 5. Side shadow profile: Finder rows vs band vs body rows, columns -2..-30.
def profile(y, n=28, side=-1):
    xs = [FX - 2 - i for i in range(n)] if side < 0 else [FX + FW + 1 + i for i in range(n)]
    return [alpha(x, y) for x in xs]
ref = Image.open(os.path.join(HERE, 'ref', variant + '-320', 'shadow.png')).convert('RGBA').load()
rox = 56 if active else 23; roy = 38 if active else 16
ref_side = [ref[rox - 2 - i, roy + 160][3] / 255 for i in range(28)]
for name, y in (('finder row -40', FB - 40), ('band row -10', FB - 10), ('body row 5', FB + 5), (f'body row {H // 2}', FB + H // 2)):
    pr = profile(y)
    diffs = [abs(a - b) for a, b in zip(pr, ref_side) if a is not None]
    p(f'5. side shadow {name}: max |alpha - ref| = {max(diffs) * 255:.0f}/255 over {len(diffs)} px')
# 6. Bottom shadow below the body centre vs reference.
ref_below = [ref[rox + 200, roy + 320 + i][3] / 255 for i in range(min(40, (74 if active else 30)))]
below = [alpha(FX + 200, FB + H + i) for i in range(40)]
diffs = [abs(a - b) for a, b in zip(below, ref_below) if a is not None]
p(f'6. bottom shadow (centre column, 40 rows): max |alpha - ref| = {max(diffs) * 255:.0f}/255')
open(os.path.join(d, 'report.txt'), 'w').write('\n'.join(out) + '\n')
# Zoomed crops for eyeballing: left seam and right seam.
for name, x0 in (('seam-left', FX - 30), ('seam-right', FX + FW - 50)):
    shot.crop((x0, FB - 40, x0 + 80, FB + 30)).resize((480, 420), Image.NEAREST).save(os.path.join(d, name + '-zoom.png'))
