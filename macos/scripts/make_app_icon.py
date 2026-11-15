#!/usr/local/bin/python3
"""Builds the Dossiary Scan Helper app icon: Dossiary's icon style (dark ink rounded square, green frame, large green
monospace "D") with a glowing scan bar across the "D"; the part of the "D" the bar has not reached yet is dimmed.

Writes Resources/AppIcon.png (1024 px master) and Resources/AppIcon.icns (via iconset + iconutil). Both are committed, so
builds need neither Pillow nor this script. Run from anywhere:
    /usr/local/bin/python3 macos/scripts/make_app_icon.py
Use /usr/local/bin/python3: the python3 on PATH (/opt/homebrew/bin) may have a broken Pillow install. Needs Pillow and macOS.
Colors and frame follow Dossiary's own scripts/make_app_icon.py (ink #1b2426, green #4fe0a6, frame = green 55% on ink,
inset 72 of 1024, Menlo Bold); the "D" has the cap height (398 px) of Dossiary's iOS icon. Like Dossiary for Mac, the
artwork sits on a transparent canvas as the Mac shape: a rounded square of 824 px (corner radius 185 px) with a soft shadow."""
import os
import subprocess
import tempfile

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "Resources")
INK = (0x1B, 0x24, 0x26)
GREEN = (0x4F, 0xE0, 0xA6)
CORE = (225, 255, 244)                  # the near-white centre of the scan bar
FRAME = tuple(round(g * 0.55 + i * 0.45) for g, i in zip(GREEN, INK))
S = 1024            # artwork size, as in Dossiary's iOS icon
SS = 4              # supersampling factor for the artwork
CANVAS, BODY, RADIUS = 1024, 824, 185
SLOTS = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]

INSET = 72
SC = (S - 2 * INSET) / 52
D_CAP = 398                             # cap height of the "D" in Dossiary's iOS icon
BAR_Y, BAR_X0, BAR_X1, BAR_H = 512, 170, 854, 34
FONT = "/System/Library/Fonts/Menlo.ttc"


def font_size():
    f = ImageFont.truetype(FONT, 100, index=1)
    _, t, _, b = ImageDraw.Draw(Image.new("L", (9, 9))).textbbox((0, 0), "D", font=f, anchor="ls")
    return round(100 * D_CAP / (b - t))


def glow(im):
    """The scan bar with three halos around it, from wide and faint to tight and bright."""
    out = im
    for blur, pad, k in [(70, 40, .55), (34, 18, .8), (14, 6, 1.0)]:
        g = Image.new("L", im.size, 0)
        ImageDraw.Draw(g).rounded_rectangle(
            [BAR_X0 * SS, (BAR_Y - BAR_H / 2 - pad) * SS, BAR_X1 * SS, (BAR_Y + BAR_H / 2 + pad) * SS],
            radius=(BAR_H / 2 + pad) * SS, fill=255)
        a = g.filter(ImageFilter.GaussianBlur(blur * SS)).point(lambda v, k=k: min(255, int(v * k)))
        out = Image.composite(Image.new("RGB", im.size, GREEN), out, a)
    ImageDraw.Draw(out).rounded_rectangle(
        [BAR_X0 * SS, (BAR_Y - BAR_H / 2) * SS, BAR_X1 * SS, (BAR_Y + BAR_H / 2) * SS], radius=BAR_H * SS // 2, fill=CORE)
    return out


def artwork():
    im = Image.new("RGB", (S * SS, S * SS), INK)
    d = ImageDraw.Draw(im)
    d.rounded_rectangle([INSET * SS, INSET * SS, (S - INSET) * SS, (S - INSET) * SS], radius=round(11 * SC * SS),
                        outline=FRAME, width=round(2.4 * SC * SS))
    font = ImageFont.truetype(FONT, font_size() * SS, index=1)
    l, t, r, b = d.textbbox((0, 0), "D", font=font, anchor="ls")
    d.text((S * SS / 2 - (l + r) / 2, S * SS / 2 - (t + b) / 2), "D", font=font, fill=GREEN, anchor="ls")
    dim = Image.new("RGBA", im.size, (0, 0, 0, 0))              # the half the bar has not scanned yet
    ImageDraw.Draw(dim).rectangle([250 * SS, BAR_Y * SS, 780 * SS, 780 * SS], fill=INK + (150,))
    im = Image.alpha_composite(im.convert("RGBA"), dim).convert("RGB")
    return glow(im).resize((S, S), Image.LANCZOS)


def master(art):
    art = art.resize((BODY, BODY), Image.LANCZOS)
    mask = Image.new("L", (BODY * 4, BODY * 4), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, BODY * 4 - 1, BODY * 4 - 1], radius=RADIUS * 4, fill=255)
    mask = mask.resize((BODY, BODY), Image.LANCZOS)
    offset = (CANVAS - BODY) // 2
    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    shadow = Image.new("L", (CANVAS, CANVAS), 0)
    shadow.paste(mask, (offset, offset + 12))
    shadow = shadow.filter(ImageFilter.GaussianBlur(14)).point(lambda v: int(v * 0.35))
    canvas.paste(Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 255)), (0, 0), shadow)
    body = Image.new("RGBA", (BODY, BODY))
    body.paste(art, (0, 0))
    body.putalpha(mask)
    canvas.alpha_composite(body, (offset, offset))
    return canvas


def main():
    big = master(artwork())
    os.makedirs(OUT, exist_ok=True)
    big.save(os.path.join(OUT, "AppIcon.png"))
    with tempfile.TemporaryDirectory() as tmp:
        iconset = os.path.join(tmp, "AppIcon.iconset")
        os.makedirs(iconset)
        for size, scale in SLOTS:
            name = f"icon_{size}x{size}{'@2x' if scale == 2 else ''}.png"
            big.resize((size * scale, size * scale), Image.LANCZOS).save(os.path.join(iconset, name))
        subprocess.run(["iconutil", "-c", "icns", iconset, "-o", os.path.join(OUT, "AppIcon.icns")], check=True)
    print("wrote Resources/AppIcon.png and AppIcon.icns")


main()
