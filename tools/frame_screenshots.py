#!/usr/bin/env python3
"""Frame raw App Store screenshots with a caption.

Reads fastlane/raw_screenshots/<locale>/*.png (fastlane snapshot output), puts
each one in a phone frame on PassPony's orange icon gradient under a headline
and a subline from fastlane/captions.json, and writes the result at the same
pixel size to fastlane/screenshots/<locale>/, which is what deliver uploads.

captions.json holds one block per App Store locale ("en-US", "de-DE", ...);
a screenshot is matched to its caption by the snapshot name at the end of its
file name ("iPhone 17 Pro Max-01Store.png" -> "01Store"). A locale without a
caption for a screenshot falls back to en-US, with a warning.

Usage: python3 tools/frame_screenshots.py   (needs Pillow: pip3 install pillow)
Fonts: Inter Display if installed, else the system fonts; Simplified Chinese
needs a CJK font (Hiragino Sans GB, STHeiti or PingFang). Override with
FRAME_FONT_BOLD / FRAME_FONT_REGULAR (and FRAME_FONT_CJK_BOLD /
FRAME_FONT_CJK_REGULAR for zh-Hans).
"""

import json
import os
import re
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parent.parent
RAW = ROOT / "fastlane" / "raw_screenshots"
OUT = ROOT / "fastlane" / "screenshots"
CAPTIONS = ROOT / "fastlane" / "captions.json"

# PassPony's icon: amber top-left, orange, red-orange bottom-right.
AMBER = (0xFD, 0xA1, 0x32)
ORANGE = (0xFD, 0x7E, 0x29)
EMBER = (0xF4, 0x5A, 0x1C)
INK = (0x6B, 0x26, 0x08)

BOLD_FONTS = [
    os.environ.get("FRAME_FONT_BOLD", ""),
    "/usr/share/fonts/opentype/inter/InterDisplay-Bold.otf",
    "/Library/Fonts/InterDisplay-Bold.otf",
    os.path.expanduser("~/Library/Fonts/InterDisplay-Bold.otf"),
    "/System/Library/Fonts/SFNSRounded.ttf",
    "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
]
REGULAR_FONTS = [
    os.environ.get("FRAME_FONT_REGULAR", ""),
    "/usr/share/fonts/opentype/inter/InterDisplay-Medium.otf",
    "/Library/Fonts/InterDisplay-Medium.otf",
    os.path.expanduser("~/Library/Fonts/InterDisplay-Medium.otf"),
    "/System/Library/Fonts/SFNS.ttf",
    "/System/Library/Fonts/Supplemental/Arial.ttf",
]
# Font collections (.ttc) are searched for a Simplified Chinese face in the
# wanted weight, so the order of faces inside the file doesn't matter.
CJK_BOLD_FONTS = [
    os.environ.get("FRAME_FONT_CJK_BOLD", ""),
    "/System/Library/Fonts/PingFang.ttc",
    "/System/Library/Fonts/Hiragino Sans GB.ttc",
    "/System/Library/Fonts/STHeiti Medium.ttc",
    "/usr/share/fonts/opentype/noto/NotoSansCJK-Bold.ttc",
]
CJK_REGULAR_FONTS = [
    os.environ.get("FRAME_FONT_CJK_REGULAR", ""),
    "/System/Library/Fonts/PingFang.ttc",
    "/System/Library/Fonts/Hiragino Sans GB.ttc",
    "/System/Library/Fonts/STHeiti Light.ttc",
    "/usr/share/fonts/opentype/noto/NotoSansCJK-Medium.ttc",
]
CJK_FAMILY_HINTS = ("SC", "GB", "STHeiti", "Heiti")
BOLD_STYLES = ("Semibold", "SemiBold", "Bold", "W6", "Medium")
REGULAR_STYLES = ("Medium", "Regular", "W3", "Light")


def collection_face(path, size, styles):
    """The best face in a .ttc: a Simplified Chinese family in the first
    style of `styles` that the collection has."""
    faces = []
    for index in range(64):
        try:
            f = ImageFont.truetype(path, size, index=index)
        except OSError:
            break
        family, style = f.getname()
        faces.append((family or "", style or "", f))
    if not faces:
        return None
    sc = [x for x in faces if any(h in x[0] for h in CJK_FAMILY_HINTS)] or faces
    for want in styles:
        for family, style, f in sc:
            if style.replace(" ", "") == want:
                return f
    return sc[0][2]


def font(candidates, size):
    """The first candidate that exists. macOS's SF fonts are variable fonts
    that load at their Regular weight, so the bold list asks for Bold and
    the regular list for Medium when the font has those named instances."""
    bold = candidates in (BOLD_FONTS, CJK_BOLD_FONTS)
    for path in candidates:
        if path and Path(path).exists():
            if path.lower().endswith(".ttc"):
                f = collection_face(path, size, BOLD_STYLES if bold else REGULAR_STYLES)
                if f is None:
                    continue
                return f
            f = ImageFont.truetype(path, size)
            for name in (["Bold", "Semibold"] if bold else ["Medium", "Regular"]):
                try:
                    f.set_variation_by_name(name)
                    break
                except Exception:
                    continue
            return f
    sys.exit("No usable font found; set FRAME_FONT_BOLD and FRAME_FONT_REGULAR")


def fonts_for(locale):
    """(bold, regular) candidate lists for a locale."""
    if locale.startswith("zh"):
        return CJK_BOLD_FONTS, CJK_REGULAR_FONTS
    return BOLD_FONTS, REGULAR_FONTS


def gradient(w, h):
    """Diagonal three-stop gradient, top-left to bottom-right."""
    small_w, small_h = 66, 144  # computed small, then smoothly scaled up
    img = Image.new("RGB", (small_w, small_h))
    px = img.load()
    for y in range(small_h):
        for x in range(small_w):
            t = (x / (small_w - 1) + y / (small_h - 1)) / 2
            a, b, u = (AMBER, ORANGE, t / 0.5) if t < 0.5 else (ORANGE, EMBER, (t - 0.5) / 0.5)
            px[x, y] = tuple(round(a[i] + (b[i] - a[i]) * u) for i in range(3))
    return img.resize((w, h), Image.BICUBIC)


def tokens(text):
    """Words to wrap between. Chinese can break between any two characters,
    so CJK text is split into characters, keeping Latin runs ("git",
    "PassPony") whole and their spaces attached."""
    if any(ord(c) >= 0x2E80 for c in text):
        return [t for t in re.findall(r" ?[A-Za-z0-9@.:/_+-]+ ?| ?[^\sA-Za-z0-9@.:/_+-]", text) if t.strip()], ""
    return text.split(), " "


def wrap(draw, text, fnt, max_width):
    """Fewest lines that fit, with the words spread evenly across them, so a
    two-line headline never leaves one word on its own."""
    words, sep = tokens(text)
    if not words:
        return []
    if len(words) > 40:  # long runs of characters: greedy is plenty
        lines, line = [], ""
        for w in words:
            trial = line + (sep if line else "") + w
            if draw.textlength(trial, font=fnt) <= max_width or not line:
                line = trial
            else:
                lines.append(line)
                line = w
        return [l.strip() for l in lines + ([line] if line else [])]
    for count in range(1, len(words) + 1):
        best = None

        def cuts(start, left):
            if left == 1:
                yield [words[start:]]
                return
            for end in range(start + 1, len(words) - left + 2):
                for rest in cuts(end, left - 1):
                    yield [words[start:end]] + rest

        for split in cuts(0, count):
            lines = [sep.join(ws).strip() for ws in split]
            widths = [draw.textlength(l, font=fnt) for l in lines]
            if max(widths) <= max_width and (best is None or max(widths) < best[0]):
                best = (max(widths), lines)
        if best:
            return best[1]
    return words


def rounded(img, radius):
    mask = Image.new("L", img.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, img.width - 1, img.height - 1], radius=radius, fill=255)
    out = Image.new("RGBA", img.size, (0, 0, 0, 0))
    out.paste(img, (0, 0), mask)
    return out


def frame(shot, caption, locale):
    W, H = shot.size
    s = W / 1320  # every measure below is for a 1320 px wide canvas
    canvas = gradient(W, H).convert("RGBA")
    draw = ImageDraw.Draw(canvas)
    bold, regular = fonts_for(locale)

    # Caption block, centred in a fixed band (room for two headline lines and
    # a subline), so the phone sits at the same place on every screenshot.
    head_font = font(bold, round(96 * s))
    sub_font = font(regular, round(50 * s))
    margin = round(90 * s)
    head_step, sub_step, gap = round(112 * s), round(64 * s), round(18 * s)
    head = wrap(draw, caption["headline"], head_font, W - 2 * margin)
    sub = wrap(draw, caption.get("subline", ""), sub_font, W - 2 * margin)
    band_top, band_h = round(130 * s), 2 * head_step + gap + 2 * sub_step
    block_h = len(head) * head_step + (gap + len(sub) * sub_step if sub else 0)
    y = band_top + (band_h - block_h) // 2
    for line in head:
        lw = draw.textlength(line, font=head_font)
        draw.text(((W - lw) / 2, y), line, font=head_font, fill="white")
        y += head_step
    y += gap
    for line in sub:
        lw = draw.textlength(line, font=sub_font)
        draw.text(((W - lw) / 2, y), line, font=sub_font, fill=(255, 255, 255, 235))
        y += sub_step
    y = band_top + band_h

    # Phone: the screenshot inside a dark bezel, with a soft shadow.
    top = y + round(40 * s)
    bezel = round(26 * s)
    screen_h = H - top - round(90 * s) - 2 * bezel
    screen_w = round(screen_h * W / H)
    max_w = W - 2 * round(110 * s)
    if screen_w > max_w:
        screen_w = max_w
        screen_h = round(screen_w * H / W)
    screen = rounded(shot.convert("RGB").resize((screen_w, screen_h), Image.LANCZOS), round(118 * s))
    body_w, body_h = screen_w + 2 * bezel, screen_h + 2 * bezel
    body = Image.new("RGBA", (body_w, body_h), (0, 0, 0, 0))
    ImageDraw.Draw(body).rounded_rectangle([0, 0, body_w - 1, body_h - 1], radius=round(140 * s), fill=(24, 20, 18, 255))
    body.alpha_composite(screen, (bezel, bezel))

    x = (W - body_w) // 2
    shadow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(
        [x, top + round(24 * s), x + body_w, top + round(24 * s) + body_h], radius=round(140 * s), fill=(*INK, 150))
    shadow = shadow.filter(ImageFilter.GaussianBlur(round(40 * s)))
    canvas.alpha_composite(shadow)
    canvas.alpha_composite(body, (x, top))
    return canvas.convert("RGB")


def caption_for(captions, locale, key):
    block = captions.get(locale, {})
    if key in block:
        return block[key]
    if key in captions.get("en-US", {}):
        print(f"warning: no {locale} caption for {key!r}, using en-US")
        return captions["en-US"][key]
    return None


def main():
    captions = json.loads(CAPTIONS.read_text())
    if not RAW.exists():
        sys.exit(f"No raw screenshots at {RAW}; run `bundle exec fastlane ios screenshots` first")
    made = 0
    for locale_dir in sorted(p for p in RAW.iterdir() if p.is_dir()):
        out_dir = OUT / locale_dir.name
        out_dir.mkdir(parents=True, exist_ok=True)
        for png in sorted(locale_dir.glob("*.png")):
            key = png.stem.rsplit("-", 1)[-1]
            caption = caption_for(captions, locale_dir.name, key)
            if caption is None:
                print(f"skip {png.name}: no caption for {key!r}")
                continue
            framed = frame(Image.open(png), caption, locale_dir.name)
            framed.save(out_dir / png.name, optimize=True)
            made += 1
            print(f"framed {locale_dir.name}/{png.name}")
    print(f"{made} screenshots framed into {OUT}")


if __name__ == "__main__":
    main()
