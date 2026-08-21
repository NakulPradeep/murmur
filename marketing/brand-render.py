#!/usr/bin/env python3
"""Channel and repo brand assets, in the palette established by the launch ad.

Sizes and safe areas per YouTube's published specs:
  avatar     800x800    displayed as a circle
  banner     2560x1440  only the centred 1235x338 shows on every device
  watermark  150x150    transparent, sits over video
  social     1280x640   GitHub repo link preview
"""
import math, os
from PIL import Image, ImageDraw, ImageFont, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
OUT  = os.path.join(HERE, "brand")

SF   = "/System/Library/Fonts/SFNS.ttf"
MONO = "/System/Library/Fonts/SFNSMono.ttf"

BG    = (8, 9, 11)
INK   = (243, 244, 246)
DIM   = (128, 134, 145)
GREEN = (61, 220, 151)

HANDLE  = "pradeepzen"
TAGLINE = "Free, open-source tools for macOS"
REPO    = "github.com/NakulPradeep"

_fc = {}
def font(path, size, weight=None):
    key = (path, size, weight)
    if key in _fc: return _fc[key]
    f = ImageFont.truetype(path, size)
    if weight:
        try:
            vals = []
            for a in f.get_variation_axes():
                nm = a["name"].decode() if isinstance(a["name"], bytes) else a["name"]
                if nm == "Weight":         vals.append(weight)
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

def tracked(d, xy, text, fnt, fill, track=0, anchor="mm"):
    x, y = xy
    total = measure(d, text, fnt, track)
    if anchor[0] == "m": x -= total / 2
    elif anchor[0] == "r": x -= total
    for ch in text:
        d.text((x, y), ch, font=fnt, fill=fill, anchor="l" + anchor[1])
        x += d.textlength(ch, font=fnt) + track

def glow_bg(w, h, cy_frac=0.5, strength=34):
    base = Image.new("RGB", (w, h), BG)
    g = Image.new("L", (w // 4, h // 4), 0)
    gd = ImageDraw.Draw(g)
    cx, cy = w // 8, int(h * cy_frac) // 4
    r0 = max(w, h) // 9
    for r in range(r0, 0, -3):
        gd.ellipse([cx - r, cy - r * 1.2, cx + r, cy + r * 1.2],
                   fill=int(strength * (1 - r / r0) ** 2))
    g = g.filter(ImageFilter.GaussianBlur(28)).resize((w, h), Image.LANCZOS)
    return Image.composite(Image.new("RGB", (w, h), (24, 40, 34)), base, g)

def wave(d, cx, cy, amp, bars=27, spread=17, col=GREEN, wbar=4):
    for i in range(bars):
        rel = (i - (bars - 1) / 2.0) / ((bars - 1) / 2.0)
        env = math.cos(rel * 1.35) ** 2
        h = max(2.5, (0.30 + 0.70 * (0.5 + 0.5 * math.sin(i * 0.55))) * env * amp)
        x = cx + (i - (bars - 1) / 2.0) * spread
        d.rounded_rectangle([x - wbar, cy - h, x + wbar, cy + h], radius=wbar, fill=col)

# ------------------------------------------------------------------ avatars
def avatar_monogram():
    S = 800
    img = glow_bg(S, S, 0.5, 44); d = ImageDraw.Draw(img)
    d.ellipse([46, 46, S - 46, S - 46], outline=(38, 74, 60), width=7)
    d.text((S//2, S//2 + 16), "P", font=font(SF, 470, 800), fill=GREEN, anchor="mm")
    return img

def avatar_wave():
    S = 800
    img = glow_bg(S, S, 0.5, 44); d = ImageDraw.Draw(img)
    d.ellipse([46, 46, S - 46, S - 46], outline=(38, 74, 60), width=7)
    # few, fat bars so it survives a 48px comment avatar
    wave(d, S//2, S//2, 168, bars=7, spread=74, wbar=22)
    return img

# ------------------------------------------------------------------- banner
def banner(guides=False):
    W, H = 2560, 1440
    SW, SH = 1235, 338                       # the only region every device shows
    img = glow_bg(W, H, 0.5, 30); d = ImageDraw.Draw(img)
    cx, cy = W // 2, H // 2

    # decorative, lives outside the safe area on purpose
    wave(d, cx, cy - 300, 46, bars=41, spread=30, col=(30, 62, 51), wbar=5)
    wave(d, cx, cy + 322, 46, bars=41, spread=30, col=(30, 62, 51), wbar=5)

    d.text((cx, cy - 78), HANDLE, font=font(SF, 148, 700), fill=INK, anchor="mm")
    d.text((cx, cy + 44), TAGLINE, font=font(SF, 60, 400), fill=DIM, anchor="mm")
    tracked(d, (cx, cy + 132), REPO, font(MONO, 44, 500), GREEN, 5, "mm")

    if guides:
        d.rectangle([cx - SW//2, cy - SH//2, cx + SW//2, cy + SH//2],
                    outline=(255, 90, 90), width=4)
        d.text((cx - SW//2 + 12, cy - SH//2 + 10), "safe area 1235x338",
               font=font(MONO, 34, 500), fill=(255, 90, 90))
    return img

# ---------------------------------------------------------------- watermark
def watermark():
    S = 150
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0)); d = ImageDraw.Draw(img)
    wave(d, S//2, S//2, 42, bars=5, spread=26, col=GREEN + (255,), wbar=8)
    return img

# ------------------------------------------------------- github social card
def social():
    W, H = 1280, 640
    img = glow_bg(W, H, 0.5, 34); d = ImageDraw.Draw(img)
    d.text((W//2, 232), "Murmur", font=font(SF, 132, 300), fill=INK, anchor="mm")
    d.text((W//2, 330), "Offline dictation for macOS",
           font=font(SF, 54, 400), fill=DIM, anchor="mm")
    wave(d, W//2, 420, 34, bars=27, spread=15, wbar=3)
    tracked(d, (W//2, 505), "FREE · NO SIGN-IN · OPEN SOURCE",
            font(MONO, 40, 600), GREEN, 6, "mm")
    return img


# ------------------------------------------------- murmur banner (2560x1440)
def banner_murmur(guides=False):
    """The Murmur card, recomposed for YouTube's banner crop.

    Same design as the social card, but every element sits inside the centred
    1235x338 safe area so phones do not slice the wordmark in half."""
    W, H = 2560, 1440
    SW, SH = 1235, 338
    img = glow_bg(W, H, 0.5, 30); d = ImageDraw.Draw(img)
    cx, cy = W // 2, H // 2

    # decorative only; lives outside the safe area
    wave(d, cx, cy - 330, 44, bars=41, spread=30, col=(30, 62, 51), wbar=5)
    wave(d, cx, cy + 352, 44, bars=41, spread=30, col=(30, 62, 51), wbar=5)

    d.text((cx, cy - 96), "Murmur", font=font(SF, 132, 300), fill=INK, anchor="mm")
    d.text((cx, cy - 6), "Offline dictation for macOS",
           font=font(SF, 52, 400), fill=DIM, anchor="mm")
    wave(d, cx, cy + 52, 26, bars=27, spread=13, wbar=3)
    tracked(d, (cx, cy + 116), "FREE · NO SIGN-IN · OPEN SOURCE",
            font(MONO, 38, 600), GREEN, 6, "mm")

    if guides:
        d.rectangle([cx - SW//2, cy - SH//2, cx + SW//2, cy + SH//2],
                    outline=(255, 90, 90), width=4)
    return img


# --------------------------------------------- avatar from the shipped app icon
def avatar_appicon():
    """The app icon, recomposed for a circular crop.

    Loads the real icon generator and neutralises its squircle mask so the
    artwork runs edge to edge. YouTube crops avatars to a circle, and the
    squircle's transparent corners would otherwise clip raggedly against it —
    reusing the generator keeps the mark pixel-identical to the shipped icon
    instead of a redrawn lookalike that drifts."""
    import importlib.util
    path = os.path.join(HERE, "..", "scripts", "make-icon.py")
    spec = importlib.util.spec_from_file_location("makeicon", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)                     # main() is __main__-guarded
    mod.squircle = lambda size, radius_ratio=0.2237: Image.new("L", (size, size), 255)
    return mod.render(1024).convert("RGB").resize((800, 800), Image.LANCZOS)

os.makedirs(OUT, exist_ok=True)
jobs = [
    ("avatar-appicon.png",  avatar_appicon()),
    ("avatar-monogram.png", avatar_monogram()),
    ("avatar-wave.png",     avatar_wave()),
    ("banner.png",          banner(False)),
    ("banner-murmur.png",   banner_murmur(False)),
    ("banner-murmur-guides.png", banner_murmur(True)),
    ("banner-guides.png",   banner(True)),
    ("watermark.png",       watermark()),
    ("github-social.png",   social()),
]
for name, im in jobs:
    p = os.path.join(OUT, name)
    im.save(p)
    print(f"  {name:22} {im.size[0]}x{im.size[1]}  {os.path.getsize(p)//1024} KB")
