#!/usr/bin/env python3
"""Generates Murmur.icns. Matches the launch film: dark ground, green voice."""
import math, os, subprocess, sys
from PIL import Image, ImageDraw, ImageFilter

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Resources")
S = 1024

def squircle(size, radius_ratio=0.2237):
    """macOS icon silhouette. Apple's shape is a superellipse, not a rounded
    rectangle — a plain rounded rect reads subtly wrong next to system icons."""
    n = 5.0
    m = Image.new("L", (size * 4, size * 4), 0)
    d = ImageDraw.Draw(m)
    cx = cy = size * 2
    r = size * 2 * 0.98
    pts = []
    for i in range(720):
        th = i / 720.0 * 2 * math.pi
        ct, st = math.cos(th), math.sin(th)
        x = cx + r * (abs(ct) ** (2 / n)) * (1 if ct >= 0 else -1)
        y = cy + r * (abs(st) ** (2 / n)) * (1 if st >= 0 else -1)
        pts.append((x, y))
    d.polygon(pts, fill=255)
    return m.resize((size, size), Image.LANCZOS)

def render(size):
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))

    # Ground: a soft vertical gradient so it does not read as flat black.
    grad = Image.new("RGB", (1, size))
    gd = ImageDraw.Draw(grad)
    for y in range(size):
        t = y / max(size - 1, 1)
        gd.point((0, y), fill=(
            int(26 + (10 - 26) * t),
            int(30 + (11 - 30) * t),
            int(34 + (13 - 34) * t)))
    body = grad.resize((size, size)).convert("RGBA")

    # A quiet green bloom behind the mark.
    glow = Image.new("L", (size, size), 0)
    g = ImageDraw.Draw(glow)
    r = int(size * 0.42)
    for k in range(r, 0, -max(1, r // 60)):
        g.ellipse([size/2 - k, size/2 - k*0.75, size/2 + k, size/2 + k*0.75],
                  fill=int(46 * (1 - k / r) ** 2))
    glow = glow.filter(ImageFilter.GaussianBlur(size * 0.05))
    body = Image.composite(Image.new("RGBA", (size, size), (30, 74, 58, 255)), body, glow)

    # Voice mark: symmetric bars, tallest at the centre.
    d = ImageDraw.Draw(body)
    bars, unit = 9, size / 24.0
    heights = [0.16, 0.30, 0.52, 0.78, 1.0, 0.78, 0.52, 0.30, 0.16]
    bw = unit * 0.62
    gap = unit * 0.52
    total = bars * bw + (bars - 1) * gap
    x = size / 2 - total / 2
    for h in heights:
        hh = h * size * 0.235
        d.rounded_rectangle([x, size/2 - hh, x + bw, size/2 + hh],
                            radius=bw / 2, fill=(61, 220, 151, 255))
        x += bw + gap

    body.putalpha(squircle(size))

    # Subtle top edge light, the way macOS icons catch the light.
    sheen = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    sd = ImageDraw.Draw(sheen)
    sd.ellipse([-size*0.2, -size*0.62, size*1.2, size*0.34], fill=(255, 255, 255, 16))
    sheen.putalpha(Image.composite(sheen.split()[3], Image.new("L", (size, size), 0),
                                   squircle(size)))
    return Image.alpha_composite(body, sheen)

def main():
    os.makedirs(OUT, exist_ok=True)
    iconset = os.path.join(OUT, "Murmur.iconset")
    os.makedirs(iconset, exist_ok=True)
    base = render(S)
    for px, names in [(16, ["16x16"]), (32, ["16x16@2x", "32x32"]),
                      (64, ["32x32@2x"]), (128, ["128x128"]),
                      (256, ["128x128@2x", "256x256"]),
                      (512, ["256x256@2x", "512x512"]),
                      (1024, ["512x512@2x"])]:
        # Re-render rather than downscale: the bars stay crisp at small sizes.
        im = render(px) if px >= 128 else base.resize((px, px), Image.LANCZOS)
        for n in names:
            im.save(os.path.join(iconset, f"icon_{n}.png"))
    subprocess.run(["iconutil", "-c", "icns", iconset,
                    "-o", os.path.join(OUT, "Murmur.icns")], check=True)
    base.save(os.path.join(OUT, "icon-preview.png"))
    print("wrote", os.path.join(OUT, "Murmur.icns"))

if __name__ == "__main__":
    main()
