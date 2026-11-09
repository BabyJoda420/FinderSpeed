#!/usr/bin/env python3 -I
"""Generates Sources/FinderSpeed/Window/WindowChromeData.swift from reference window captures.

Inputs: ref/<variant>-320/{shadow,noshadow}.png (a 404x320 titled window) and ref/<variant>/shadow.png
(404x88, the same chrome as Finder's progress window: verified max alpha diff 1 against Finder's own
capture). Variants: dark|light x key|nokey. Made by refwin.swift (screencapture -l / -o).

Per variant it stores, in window-relative points (1x):
  padX, padBelow     shadow extent at the sides / below the window
  steady[d]          outside alpha at distance d+1 left of the edge, far from corners (ring = d 0)
  tall[db][dx]       total alpha A of the window+decoration+shadow near the BOTTOM of a tall window,
                     db in [-K, padBelow) rows relative to the bottom edge, dx in [-padX, Cx)
  short[db][dx]      the same for an 88 pt window (= Finder's progress window alone), db in [-48, padBelow)
  cov[db][dx]        window content coverage in the bottom-left corner, db in [-CR, 0), dx in [0, CR)
  ovl[db][dx]        decoration overlay on the fill in that corner: >0 white alpha, <0 black alpha
  ovlSide[i]         overlay for columns dx = i (left edge, i < 3), straight part
  ovlBottom[i]       overlay for rows db = -1 - i (bottom edge, i < 3), straight part
Columns dx >= Cx repeat column Cx-1. The right side mirrors the left (measured asymmetry <= 2).
"""
import base64, os, sys
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, '..', '..', '..', 'Sources', 'FinderSpeed', 'Window', 'WindowChromeData.swift')
CR = 24   # corner block size
SHORT_ABOVE = 48   # rows of Finder's own (88 pt) chrome stored above its bottom edge
TOL = 2

def load(path):
    im = Image.open(path).convert('RGBA'); px = im.load(); W, H = im.size
    xs = [x for x in range(W) if px[x, H // 2][3] == 255]
    ys = [y for y in range(H) if px[W // 2, y][3] == 255]
    return px, min(xs), min(ys), max(xs) - min(xs) + 1, max(ys) - min(ys) + 1, (W, H)

def lum(c): return (c[0] + c[1] + c[2]) / 3.0

variants = []
for v in ['dark-key', 'dark-nokey', 'light-key', 'light-nokey']:
    tp, tox, toy, tw, th, tsize = load(os.path.join(HERE, 'ref', v + '-320', 'shadow.png'))
    sp, sox, soy, sw, sh, ssize = load(os.path.join(HERE, 'ref', v, 'shadow.png'))
    nim = Image.open(os.path.join(HERE, 'ref', v + '-320', 'noshadow.png')).convert('RGBA'); npx = nim.load()
    assert tw == 404 and th == 320 and sw == 404 and sh == 88, (v, tw, th, sw, sh)
    padX = tox; padB = tsize[1] - toy - th
    assert sox == padX and ssize[1] - soy - sh == padB
    bottom = toy + th
    mid = toy + th // 2
    steady = [tp[tox - 1 - d, mid][3] for d in range(padX)]
    # K: rows above the bottom edge that differ from the steady side profile.
    K = 0
    for k in range(1, th // 2):
        row = bottom - k
        if any(abs(tp[tox - 1 - d, row][3] - steady[d]) > TOL for d in range(padX)):
            K = k
    K += 2
    # Cx: first column from which all block rows are constant to the right (centre profile).
    Cx = None
    for c in range(CR, 250):
        if all(abs(tp[tox + cc, y][3] - tp[tox + c, y][3]) <= TOL
               for y in range(bottom - K, bottom + padB) for cc in range(c, 300, 3)):
            Cx = c + 1; break
    assert Cx is not None
    def block(px, ox, bot, rows):
        out = bytearray()
        for db in rows:
            for dx in range(-padX, Cx):
                out.append(px[ox + dx, bot + db][3])
        return out
    tall = block(tp, tox, bottom, range(-K, padB))
    short = block(sp, sox, soy + sh, range(-SHORT_ABOVE, padB))
    # Corner coverage + overlay. Reference fill = interior colour of the with-shadow capture.
    bg = lum(tp[tox + 200, bottom - 60])
    cov = bytearray(); ovl = bytearray()
    def overlay(P, A, c):
        if c <= 0.0: return 0.0
        target = A * lum(P) / c          # colour the body must show at this pixel (unpremultiplied)
        if target >= bg:
            return 0.0 if bg >= 254.5 else min(1.0, (target - bg) / (255.0 - bg))
        return -min(1.0, 1.0 - target / bg) if bg > 0 else 0.0
    for db in range(-CR, 0):
        for dx in range(0, CR):
            c = npx[dx, th + db][3] / 255.0
            P = tp[tox + dx, bottom + db]; A = P[3] / 255.0
            # The with-shadow capture can carry more content than the -o coverage suggests (its own
            # anti-aliasing). If the content would have to be brighter than white, raise the coverage.
            if c > 0 and A * lum(P) / c > 255.0:
                c = min(A, A * lum(P) / 255.0)
            elif c == 0 and A * lum(P) > 2.0:
                c = min(A, A * lum(P) / max(bg, 1.0))
            cov.append(round(c * 255))
            ovl.append(round(overlay(P, A, c) * 127) + 128)
    side = []; bot = []
    for i in range(3):
        P = tp[tox + i, mid]; side.append(round(overlay(P, P[3] / 255.0, 1.0) * 127) + 128)
        P = tp[tox + 200, bottom - 1 - i]; bot.append(round(overlay(P, P[3] / 255.0, 1.0) * 127) + 128)
    print(f'{v}: padX={padX} padBelow={padB} K={K} Cx={Cx} bg={bg:.1f} steady[:3]={steady[:3]} '
          f'side={[s - 128 for s in side]} bottom={[b - 128 for b in bot]} bytes={len(tall) + len(short)}')
    variants.append(dict(name=v, padX=padX, padB=padB, K=K, Cx=Cx, steady=bytes(steady), tall=bytes(tall),
                         short=bytes(short), cov=bytes(cov), ovl=bytes(ovl), side=bytes(side), bot=bytes(bot)))

def b64(b): return base64.b64encode(b).decode()
lines = ['// Window/WindowChromeData.swift (owner: apollo). GENERATED by spikes/window/phase3/gen_profile.py, do not edit.',
         '// Measured chrome (outline, rim, shadow) of a standard titled window, which is identical to Finder\'s',
         '// progress window (max alpha difference 1 against a capture of Finder\'s window). See WindowChrome.swift.',
         '', 'import Foundation', '', 'extension WindowChromeProfile {',
         '    static let measured: [Key: WindowChromeProfile] = [']
for v in variants:
    dark = v['name'].startswith('dark'); key = v['name'].endswith('-key')
    lines.append(f'        Key(dark: {str(dark).lower()}, active: {str(key).lower()}): WindowChromeProfile(')
    lines.append(f'            padX: {v["padX"]}, padBelow: {v["padB"]}, rowsAbove: {v["K"]}, shortRowsAbove: {SHORT_ABOVE}, columns: {v["Cx"]}, cornerSize: {CR},')
    for k, name in [('steady', 'steady'), ('tall', 'tall'), ('short', 'short'), ('cov', 'coverage'), ('ovl', 'overlay'),
                    ('side', 'overlaySide'), ('bot', 'overlayBottom')]:
        sep = ')' if name == 'overlayBottom' else ','
        lines.append(f'            {name}: "{b64(v[k])}"{sep}')
    lines[-1] = lines[-1]  # keep
    lines.append('')
lines[-1] = '    ]'
lines.append('}')
src = '\n'.join(lines).replace(')\n\n        Key', '),\n        Key') + '\n'
open(OUT, 'w').write(src)
print('wrote', os.path.normpath(OUT), len(src), 'bytes')
