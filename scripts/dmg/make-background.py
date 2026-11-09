# Generates the DMG window background (1x and 2x). Owner: zeus.
# Layout: window 600x380 pt; app icon centre (160,190), Applications centre (440,190), icon size 128.
from PIL import Image, ImageDraw, ImageFont
def render(scale, path):
    W, H = 600 * scale, 380 * scale
    img = Image.new("RGB", (W, H))
    top, bottom = (246, 247, 250), (226, 229, 236)
    d = ImageDraw.Draw(img)
    for y in range(H):
        t = y / (H - 1)
        d.line([(0, y), (W, y)], fill=tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)))
    # arrow between the two icons
    y = 190 * scale; x0, x1 = 238 * scale, 362 * scale; col = (150, 158, 172)
    d.line([(x0, y), (x1 - 14 * scale, y)], fill=col, width=5 * scale)
    d.polygon([(x1, y), (x1 - 22 * scale, y - 14 * scale), (x1 - 22 * scale, y + 14 * scale)], fill=col)
    font = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", 17 * scale)
    small = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", 12 * scale)
    def centred(text, f, yy, fill):
        w = d.textlength(text, font=f); d.text(((W - w) / 2, yy), text, font=f, fill=fill)
    centred("Drag FinderSpeed to Applications", font, 52 * scale, (60, 64, 72))
    centred("Live transfer speed for Finder copies", small, 318 * scale, (120, 126, 138))
    img.save(path, dpi=(72 * scale, 72 * scale))
render(1, "background.png")
render(2, "background@2x.png")
