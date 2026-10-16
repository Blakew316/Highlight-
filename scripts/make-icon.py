#!/usr/bin/env python3
"""Draws the Highlight app icon and writes every size the Mac app and website need.

Outputs:
  mac/Resources/AppIcon.png    1024 px master, shaped to Apple's macOS icon grid.
                               mac/scripts/build-app.sh turns it into AppIcon.icns.
  site/apple-touch-icon.png    180 px full-bleed version for the iPhone Home Screen

Run: python3 scripts/make-icon.py   (needs Pillow)
"""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
S = 2048            # draw at 2x, then downsample for clean edges
U = S / 1024        # one unit on Apple's 1024 grid

BLUE_TOP, BLUE_BOTTOM = (64, 140, 255), (10, 84, 214)
PAPER = (255, 255, 255)
INK = (196, 207, 226)
INK_DARK = (52, 64, 92)
YELLOW = (255, 214, 10)


def u(v):
    return int(round(v * U))


def gradient(size, top, bottom):
    w, h = size
    g = Image.new("RGB", (1, h))
    for y in range(h):
        t = y / (h - 1)
        g.putpixel((0, y), tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)))
    return g.resize((w, h))


def artwork(full_bleed=False):
    """The icon. full_bleed=True fills the square (iOS masks the corners itself)."""
    # Apple's macOS grid: an 824 pt rounded square centred on a 1024 canvas.
    box, radius = ((0, 0, S, S), 0) if full_bleed else ((u(100), u(100), u(924), u(924)), u(185))

    # Everything is drawn on `art`, then clipped to the rounded square.
    art = gradient((S, S), BLUE_TOP, BLUE_BOTTOM).convert("RGBA")

    # A sheet of paper with a folded corner, softly shadowed.
    px0, py0, px1, py1, fold = 268, 214, 690, 782, 92
    sheet = [(u(px0), u(py0)), (u(px1 - fold), u(py0)), (u(px1), u(py0 + fold)), (u(px1), u(py1)), (u(px0), u(py1))]
    sh = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(sh).polygon([(x, y + u(12)) for x, y in sheet], fill=(0, 20, 70, 110))
    art.alpha_composite(sh.filter(ImageFilter.GaussianBlur(u(16))))
    d = ImageDraw.Draw(art)
    d.polygon(sheet, fill=PAPER)
    d.polygon([(u(px1 - fold), u(py0)), (u(px1 - fold), u(py0 + fold)), (u(px1), u(py0 + fold))], fill=(214, 224, 240))

    # Lines of text; the middle one is highlighted.
    lines = [(320, 322, 530), (320, 402, 610), (320, 482, 600), (320, 562, 620), (320, 642, 490)]
    hl = 2
    for i, (x, y, x1) in enumerate(lines):
        if i == hl:
            d.rounded_rectangle((u(x - 22), u(y - 26), u(x1 + 24), u(y + 50)), u(10), fill=YELLOW)
        d.rounded_rectangle((u(x), u(y), u(x1), u(y + 24)), u(12), fill=INK_DARK if i == hl else INK)

    # A yellow highlighter resting across the lower-right corner of the page.
    pen = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    p = ImageDraw.Draw(pen)
    cx, cy = S // 2, S // 2
    w = u(58)
    p.rounded_rectangle((cx - w, cy - u(210), cx + w, cy + u(110)), u(30), fill=YELLOW)                    # barrel
    p.rounded_rectangle((cx - w, cy - u(210), cx + w, cy - u(120)), u(30), fill=(255, 168, 0))             # cap end
    p.rectangle((cx - w, cy - u(140), cx + w, cy - u(120)), fill=(255, 168, 0))
    p.rectangle((cx - w, cy + u(64), cx + w, cy + u(110)), fill=(255, 255, 255))                            # collar
    p.polygon([(cx - u(48), cy + u(110)), (cx + u(48), cy + u(110)), (cx + u(28), cy + u(178)), (cx - u(28), cy + u(178))], fill=(40, 46, 60))
    p.polygon([(cx - u(28), cy + u(178)), (cx + u(28), cy + u(178)), (cx + u(28), cy + u(212)), (cx - u(28), cy + u(198))], fill=YELLOW)  # chisel tip
    pen = pen.rotate(-36, resample=Image.BICUBIC, center=(cx, cy))
    pen_shadow = Image.new("RGBA", (S, S), (0, 20, 70, 0))
    pen_shadow.putalpha(pen.getchannel("A").point(lambda a: int(a * 0.38)))
    pen_shadow = pen_shadow.filter(ImageFilter.GaussianBlur(u(14)))
    off = (u(188), u(178))
    art.alpha_composite(pen_shadow, (off[0] + u(6), off[1] + u(18)))
    art.alpha_composite(pen, off)

    clip = Image.new("L", (S, S), 0)
    ImageDraw.Draw(clip).rounded_rectangle(box, radius, fill=255)
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    if not full_bleed:   # the icon's own soft drop shadow, outside the rounded square
        ImageDraw.Draw(img).rounded_rectangle((box[0], box[1] + u(14), box[2], box[3] + u(14)), radius, fill=(0, 0, 0, 90))
        img = img.filter(ImageFilter.GaussianBlur(u(18)))
    shape = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    shape.paste(art, (0, 0), clip)
    img.alpha_composite(shape)
    return img.resize((1024, 1024), Image.LANCZOS)


def main():
    res = ROOT / "mac" / "Resources"
    res.mkdir(parents=True, exist_ok=True)
    icon = artwork()
    icon.save(res / "AppIcon.png", optimize=True)
    artwork(full_bleed=True).convert("RGB").resize((180, 180), Image.LANCZOS).save(ROOT / "site" / "apple-touch-icon.png", optimize=True)
    print("Wrote mac/Resources/AppIcon.png and site/apple-touch-icon.png")


if __name__ == "__main__":
    main()
