# Generates AppIcon.icns: a speedometer on a blue gradient squircle (macOS icon grid). Owner: zeus.
import math, os, subprocess
from PIL import Image, ImageDraw, ImageFilter
S = 1024
def squircle_mask(size, inset, radius):
    m = Image.new("L", (size, size), 0)
    ImageDraw.Draw(m).rounded_rectangle([inset, inset, size - inset, size - inset], radius=radius, fill=255)
    return m
def icon():
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    # Full-bleed square: macOS 26 masks it to its own squircle. (A pre-shaped icon with
    # transparent padding gets shrunk into a grey frame.)
    # gradient body
    body = Image.new("RGBA", (S, S))
    d = ImageDraw.Draw(body)
    top, bot = (64, 156, 255), (18, 66, 170)
    for y in range(S):
        t = y / (S - 1); d.line([(0, y), (S, y)], fill=tuple(int(top[i] + (bot[i] - top[i]) * t) for i in range(3)) + (255,))
    img.paste(body, (0, 0))
    d = ImageDraw.Draw(img)
    cx, cy, R = S // 2, 570, 360
    # gauge track and filled arc (from 150° to 30°, i.e. a 240° sweep)
    box = [cx - R, cy - R, cx + R, cy + R]
    d.arc(box, start=150, end=390, fill=(255, 255, 255, 70), width=56)
    d.arc(box, start=150, end=330, fill=(255, 255, 255, 255), width=56)
    # ticks
    for k in range(9):
        a = math.radians(150 + k * 30)
        r1, r2 = R - 60, R - 95 if k % 2 == 0 else R - 80
        d.line([(cx + r1 * math.cos(a), cy + r1 * math.sin(a)), (cx + r2 * math.cos(a), cy + r2 * math.sin(a))],
               fill=(255, 255, 255, 200), width=12)
    # needle pointing at ~70% (300°)
    a = math.radians(300); L = R - 70
    tip = (cx + L * math.cos(a), cy + L * math.sin(a))
    perp = (math.cos(a + math.pi / 2) * 22, math.sin(a + math.pi / 2) * 22)
    d.polygon([tip, (cx + perp[0], cy + perp[1]), (cx - perp[0], cy - perp[1])], fill=(255, 200, 60, 255))
    d.ellipse([cx - 46, cy - 46, cx + 46, cy + 46], fill=(255, 255, 255, 255))
    d.ellipse([cx - 20, cy - 20, cx + 20, cy + 20], fill=(18, 66, 170, 255))
    return img
base = icon()
os.makedirs("AppIcon.iconset", exist_ok=True)
for pt in (16, 32, 128, 256, 512):
    for sc in (1, 2):
        px = pt * sc
        name = f"icon_{pt}x{pt}{'@2x' if sc == 2 else ''}.png"
        base.resize((px, px), Image.LANCZOS).save(f"AppIcon.iconset/{name}")
base.save("AppIcon-1024.png")
subprocess.run(["iconutil", "-c", "icns", "AppIcon.iconset", "-o", "AppIcon.icns"], check=True)
print("ok")
