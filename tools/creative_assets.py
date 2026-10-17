#!/usr/bin/env python3
"""Product page Header and Search Results creative assets.

App Store Connect's Header and Search Results creative assets aren't uploaded
by deliver, so these are made here and added by hand in App Store Connect
(Product Page Information > Header and Search Results), one set per locale.
Built from the same raw screenshots and orange gradient as the framed
screenshots:

  header_21x9.png        3840 x 1646  Header, 21:9
  search_3x2.png         3840 x 2560  Search Results, 3:2
  universal_16x9.png     5244 x 2950  accepted by both placements

No transparency, no URLs, no other platforms; artwork kept to the middle so
nothing important is lost where Apple crops. The tagline comes from
fastlane/captions.json ("tagline" in each locale's block, two lines split by
"\\n"). Output: fastlane/creative_assets/<locale>/.

Usage: python3 tools/creative_assets.py   (needs Pillow)
"""

import json
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

sys.path.insert(0, str(Path(__file__).resolve().parent))
from frame_screenshots import BOLD_FONTS, INK, font, fonts_for, gradient, rounded, wrap  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
RAW = ROOT / "fastlane" / "raw_screenshots"
ICON = ROOT / "Sources" / "App" / "Assets.xcassets" / "AppIcon.appiconset" / "icon-1024.png"
OUT = ROOT / "fastlane" / "creative_assets"
CAPTIONS = ROOT / "fastlane" / "captions.json"

TITLE = "PassPony"


class Locale:
    def __init__(self, code, tagline):
        self.code = code
        self.tagline = tagline
        self.bold, self.regular = fonts_for(code)

    def shot(self, name):
        return Image.open(next((RAW / self.code).glob(f"*-{name}.png"))).convert("RGB")


def phone(img, height):
    """A screenshot in a dark bezel, `height` px tall, RGBA."""
    bezel = max(1, round(height * 0.0195))
    screen_h = height - 2 * bezel
    screen_w = round(screen_h * img.width / img.height)
    screen = rounded(img.resize((screen_w, screen_h), Image.LANCZOS), round(screen_w * 0.09))
    body = Image.new("RGBA", (screen_w + 2 * bezel, height), (0, 0, 0, 0))
    ImageDraw.Draw(body).rounded_rectangle([0, 0, body.width - 1, body.height - 1],
                                           radius=round(body.width * 0.105), fill=(24, 20, 18, 255))
    body.alpha_composite(screen, (bezel, bezel))
    return body


def place(canvas, item, x, y, angle=0.0, shadow=True):
    """Paste `item` centred on (x, y), rotated by `angle` degrees, with a soft shadow."""
    if angle:
        item = item.rotate(angle, resample=Image.BICUBIC, expand=True)
    left, top = round(x - item.width / 2), round(y - item.height / 2)
    if shadow:
        blur = max(8, item.width // 18)
        sh = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
        alpha = item.split()[-1].point(lambda a: min(a, 150))
        tint = Image.new("RGBA", item.size, (*INK, 255))
        tint.putalpha(alpha)
        sh.alpha_composite(tint, (left, top + blur // 2))
        canvas.alpha_composite(sh.filter(ImageFilter.GaussianBlur(blur)))
    canvas.alpha_composite(item, (left, top))


def icon(size):
    return rounded(Image.open(ICON).convert("RGB").resize((size, size), Image.LANCZOS), round(size * 0.225))


def centered_text(draw, text, fnt, cx, y, fill, max_width, step):
    lines = [l for part in text.split("\n") for l in wrap(draw, part, fnt, max_width)]
    for line in lines:
        w = draw.textlength(line, font=fnt)
        draw.text((cx - w / 2, y), line, font=fnt, fill=fill)
        y += step
    return y


def brand_block(canvas, loc, cx, top, scale, max_width):
    """Icon, name and tagline stacked and centred on cx; returns the bottom y."""
    draw = ImageDraw.Draw(canvas)
    ic = icon(round(300 * scale))
    place(canvas, ic, cx, top + ic.height / 2, shadow=True)
    y = top + ic.height + round(50 * scale)
    y = centered_text(draw, TITLE, font(BOLD_FONTS, round(190 * scale)), cx, y, "white", max_width, round(220 * scale))
    y += round(10 * scale)
    return centered_text(draw, loc.tagline, font(loc.regular, round(84 * scale)), cx, y,
                         (255, 255, 255, 235), max_width, round(104 * scale))


def header(loc, W=3840, H=1646):
    """21:9. Brand in the middle, phones to either side, cut by the bottom edge."""
    c = gradient(W, H).convert("RGBA")
    ph = round(H * 1.02)
    place(c, phone(loc.shot("02Entry"), ph), W * 0.165, H * 0.62, angle=8)
    place(c, phone(loc.shot("01Store"), ph), W * 0.835, H * 0.62, angle=-8)
    s = H / 1646
    block_h = round((300 + 50 + 220 + 10 + 2 * 104) * s)
    brand_block(c, loc, W / 2, (H - block_h) / 2, s, W * 0.42)
    return c.convert("RGB")


def search(loc, W=3840, H=2560):
    """3:2. Name and tagline on top, three phones across the middle."""
    c = gradient(W, H).convert("RGBA")
    s = H / 2560
    draw = ImageDraw.Draw(c)
    ic = icon(round(230 * s))
    head_font = font(BOLD_FONTS, round(150 * s))  # the name is always Latin
    title_w = draw.textlength(TITLE, font=head_font)
    gap = round(50 * s)
    x0 = (W - (ic.width + gap + title_w)) / 2
    place(c, ic, x0 + ic.width / 2, round(150 * s) + ic.height / 2)
    draw.text((x0 + ic.width + gap, round(150 * s) + (ic.height - 180 * s) / 2), TITLE, font=head_font, fill="white")
    centered_text(draw, loc.tagline.replace("\n", " "), font(loc.regular, round(92 * s)), W / 2, round(440 * s),
                  (255, 255, 255, 235), W * 0.8, round(110 * s))
    ph = round(H * 0.72)
    y = H - ph / 2 + round(110 * s)
    place(c, phone(loc.shot("01Store"), ph), W * 0.25, y + round(60 * s), angle=4)
    place(c, phone(loc.shot("03Sync"), ph), W * 0.75, y + round(60 * s), angle=-4)
    place(c, phone(loc.shot("02Entry"), ph), W * 0.5, y)
    return c.convert("RGB")


def universal(loc, W=5244, H=2950):
    """16:9, accepted by both placements: brand in the middle, a phone each side."""
    c = gradient(W, H).convert("RGBA")
    ph = round(H * 0.86)
    place(c, phone(loc.shot("02Entry"), ph), W * 0.2, H * 0.56, angle=6)
    place(c, phone(loc.shot("01Store"), ph), W * 0.8, H * 0.56, angle=-6)
    s = H / 1646 * 0.62
    block_h = round((300 + 50 + 220 + 10 + 2 * 104) * s)
    brand_block(c, loc, W / 2, (H - block_h) / 2, s, W * 0.4)
    return c.convert("RGB")


def main():
    captions = json.loads(CAPTIONS.read_text())
    if not RAW.exists():
        sys.exit(f"No raw screenshots at {RAW}; run `bundle exec fastlane ios screenshots` first")
    for locale_dir in sorted(p for p in RAW.iterdir() if p.is_dir()):
        code = locale_dir.name
        tagline = captions.get(code, {}).get("tagline") or captions["en-US"]["tagline"]
        loc = Locale(code, tagline)
        out = OUT / code
        out.mkdir(parents=True, exist_ok=True)
        for name, make in [("header_21x9.png", header), ("search_3x2.png", search), ("universal_16x9.png", universal)]:
            img = make(loc)
            img.save(out / name, optimize=True)
            print(f"{code}/{name}: {img.size[0]} x {img.size[1]}")


if __name__ == "__main__":
    main()
