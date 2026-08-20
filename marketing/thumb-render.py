#!/usr/bin/env python3
"""Renders Shorts thumbnail options: 1080x1920, same palette as the launch ad.

A Shorts thumbnail is read in a channel-tab grid at roughly 180px wide, so the
only real test is legibility at that size — everything here is sized for the
grid, not for the full-resolution file.
"""
import math, os
from PIL import Image, ImageDraw, ImageFont, ImageFilter

W, H = 1080, 1920
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "thumb")

SF   = "/System/Library/Fonts/SFNS.ttf"
MONO = "/System/Library/Fonts/SFNSMono.ttf"

BG    = (8, 9, 11)
INK   = (243, 244, 246)
DIM   = (128, 134, 145)
GREEN = (61, 220, 151)
WARM  = (248, 145, 110)

_fc = {}
def font(path, size, weight=None, width=None):
    key = (path, size, weight, width)
    if key in _fc: return _fc[key]
    f = ImageFont.truetype(path, size)
    if weight or width:
        try:
            axes = f.get_variation_axes()
            vals = []
            for a in axes:
                nm = a["name"].decode() if isinstance(a["name"], bytes) else a["name"]
                if nm == "Weight":         vals.append(weight or a["default"])
                elif nm == "Width":        vals.append(width or a["default"])
                elif nm == "Optical Size": vals.append(min(a["maximum"], max(a["minimum"], size)))
                else:                      vals.append(a["default"])
            f.set_variation_by_axes(vals)
        except Exception:
            pass
    _fc[key] = f
    return f

def measure(d, text, fnt, track=0):
    if not text: return 0
    return sum(d.textlength(ch, font=fnt) for ch in text) + track * (len(text) - 1)

def tracked(d, xy, text, fnt, fill, track=0, anchor="lt"):
    x, y = xy
    total = measure(d, text, fnt, track)
    if anchor[0] == "m": x -= total / 2
    elif anchor[0] == "r": x -= total
    for ch in text:
        d.text((x, y), ch, font=fnt, fill=fill, anchor="l" + anchor[1])
        x += d.textlength(ch, font=fnt) + track

def make_bg():
    base = Image.new("RGB", (W, H), BG)
    glow = Image.new("L", (W // 4, H // 4), 0)
    gd = ImageDraw.Draw(glow)
    cx, cy = W // 8, int(H * 0.44) // 4
    for r in range(260, 0, -6):
        v = int(30 * (1 - r / 260.0) ** 2)
        gd.ellipse([cx - r, cy - r * 1.25, cx + r, cy + r * 1.25], fill=v)
    glow = glow.filter(ImageFilter.GaussianBlur(30)).resize((W, H), Image.LANCZOS)
    tint = Image.new("RGB", (W, H), (24, 40, 34))
    return Image.composite(tint, base, glow)

def waveform(d, cx, cy, amp, bars=27, spread=17, col=GREEN):
    for i in range(bars):
        rel = (i - (bars - 1) / 2.0) / ((bars - 1) / 2.0)
        env = math.cos(rel * 1.35) ** 2
        h = max(3.0, (0.30 + 0.70 * (0.5 + 0.5 * math.sin(i * 0.55))) * env * amp)
        x = cx + (i - (bars - 1) / 2.0) * spread
        d.rounded_rectangle([x - 4, cy - h, x + 4, cy + h], radius=4, fill=col)

def base():
    img = make_bg().convert("RGB")
    return img, ImageDraw.Draw(img)

# ---------------------------------------------------------------- A: price
def variant_price():
    img, d = base()
    tracked(d, (W//2, 430), "MAC DICTATION", font(MONO, 50, 500), DIM, 14, "mm")

    f15 = font(SF, 150, 600)
    t15 = "$15/mo"
    w15 = measure(d, t15, f15)
    d.text((W//2, 700), t15, font=f15, fill=WARM, anchor="mm")
    d.line([W//2 - w15/2 - 18, 700, W//2 + w15/2 + 18, 700], fill=WARM, width=9)

    d.text((W//2, 1010), "$0", font=font(SF, 430, 800), fill=GREEN, anchor="mm")
    waveform(d, W//2, 1270, 62)
    tracked(d, (W//2, 1430), "FREE · OFFLINE", font(MONO, 60, 600), INK, 8, "mm")
    tracked(d, (W//2, 1520), "OPEN SOURCE",    font(MONO, 60, 600), INK, 8, "mm")
    return img

# ---------------------------------------------------------------- B: speed
def variant_speed():
    img, d = base()
    tracked(d, (W//2, 520), "11 SECONDS OF SPEECH", font(MONO, 48, 500), DIM, 10, "mm")
    d.text((W//2, 850), "0.25s", font=font(MONO, 300, 700), fill=GREEN, anchor="mm")
    tracked(d, (W//2, 1070), "TRANSCRIBED OFFLINE", font(MONO, 52, 500), DIM, 10, "mm")
    waveform(d, W//2, 1280, 62)
    d.text((W//2, 1470), "Free. No sign-in.", font=font(SF, 82, 600), fill=INK, anchor="mm")
    return img

# ------------------------------------------------------------ C: statement
def variant_voice():
    img, d = base()
    f = font(SF, 155, 800)
    for i, line in enumerate(["YOUR VOICE", "NEVER LEAVES", "YOUR MAC"]):
        col = GREEN if i == 1 else INK
        d.text((W//2, 690 + i * 185), line, font=f, fill=col, anchor="mm")
    waveform(d, W//2, 1330, 58)
    d.text((W//2, 1500), "Murmur", font=font(SF, 105, 300), fill=INK, anchor="mm")
    tracked(d, (W//2, 1600), "FREE · OPEN SOURCE", font(MONO, 46, 500), GREEN, 8, "mm")
    return img

os.makedirs(OUT, exist_ok=True)
for name, fn in (("a-price", variant_price), ("b-speed", variant_speed),
                 ("c-voice", variant_voice)):
    p = os.path.join(OUT, f"{name}.png")
    fn().save(p)
    print("wrote", p)
