#!/usr/bin/env python3
"""Renders the Murmur launch ad: 1080x1920, 30fps, 15s."""
import math, os, sys
from PIL import Image, ImageDraw, ImageFont, ImageFilter

W, H, FPS, DUR = 1080, 1920, 30, 16.85
N = int(FPS * DUR)
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "frames")

SF   = "/System/Library/Fonts/SFNS.ttf"
MONO = "/System/Library/Fonts/SFNSMono.ttf"

BG        = (8, 9, 11)
INK       = (243, 244, 246)
DIM       = (128, 134, 145)
FAINT     = (58, 62, 70)
GREEN     = (61, 220, 151)
WARM      = (248, 145, 110)

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
                if nm == "Weight":        vals.append(weight or a["default"])
                elif nm == "Width":       vals.append(width or a["default"])
                elif nm == "Optical Size":vals.append(min(a["maximum"], max(a["minimum"], size)))
                else:                     vals.append(a["default"])
            f.set_variation_by_axes(vals)
        except Exception:
            pass
    _fc[key] = f
    return f

# ---------- easing ----------
def clamp(x, a=0.0, b=1.0): return max(a, min(b, x))
def ease_out(t):  t = clamp(t); return 1 - (1 - t) ** 3
def ease_in_out(t):
    t = clamp(t)
    return 4*t*t*t if t < 0.5 else 1 - pow(-2*t + 2, 3) / 2
def ease_out_back(t):
    t = clamp(t); c1 = 1.70158; c3 = c1 + 1
    return 1 + c3 * pow(t - 1, 3) + c1 * pow(t - 1, 2)

# Phrase boundaries measured from the recorded voiceover with silencedetect.
# Every cue below is expressed in seconds so the edit stays readable against
# the script rather than against frame numbers.
VO = {
    "problem":  (0.00, 2.88),   # Every dictation app sends your voice away.
    "price":    (3.58, 5.04),   # Fifteen dollars a month.
    "turn":     (5.97, 6.91),   # Murmur doesn't.
    "stays":    (7.43, 9.17),   # It never leaves your Mac.
    "quarter":  (9.83, 11.05),  # Quarter of a second.
    "nothing":  (11.69, 12.69), # Nothing uploaded.
    "name":     (13.76, 14.25), # Murmur.
    "free":     (14.85, 16.39), # Free and open source.
}

def F(sec):
    """Seconds -> frame index."""
    return sec * FPS

def fs(f, a, b, c, d):
    """fade() in seconds."""
    return fade(f, F(a), F(b), F(c), F(d))

def sg(f, a, b):
    """seg() in seconds."""
    return seg(f, F(a), F(b))

def seg(f, a, b):
    """Normalized progress through frame window [a,b)."""
    if f < a: return 0.0
    if f >= b: return 1.0
    return (f - a) / float(b - a)

def fade(f, a, b, c, d):
    """Fade in over a..b, hold b..c, fade out over c..d."""
    if f < a or f >= d: return 0.0
    if f < b: return ease_out(seg(f, a, b))
    if f < c: return 1.0
    return 1 - ease_in_out(seg(f, c, d))

def mix(c1, c2, t):
    t = clamp(t)
    return tuple(int(round(c1[i] + (c2[i] - c1[i]) * t)) for i in range(3))

def alpha(c, a):
    return (c[0], c[1], c[2], int(round(255 * clamp(a))))

# ---------- text ----------
def measure(d, text, fnt, track=0):
    if not text: return 0
    w = sum(d.textlength(ch, font=fnt) for ch in text)
    return w + track * (len(text) - 1)

def draw_tracked(d, xy, text, fnt, fill, track=0, anchor="lt"):
    """PIL has no letter-spacing; draw glyph by glyph."""
    x, y = xy
    total = measure(d, text, fnt, track)
    if anchor[0] == "m": x -= total / 2
    elif anchor[0] == "r": x -= total
    for ch in text:
        d.text((x, y), ch, font=fnt, fill=fill, anchor="l" + anchor[1])
        x += d.textlength(ch, font=fnt) + track

def layer():
    return Image.new("RGBA", (W, H), (0, 0, 0, 0))

# ---------- background ----------
def make_bg():
    base = Image.new("RGB", (W, H), BG)
    # Soft radial lift behind the centre so flat black never reads as dead.
    glow = Image.new("L", (W // 4, H // 4), 0)
    gd = ImageDraw.Draw(glow)
    cx, cy = W // 8, int(H * 0.42) // 4
    for r in range(260, 0, -6):
        v = int(26 * (1 - r / 260.0) ** 2)
        gd.ellipse([cx - r, cy - r * 1.25, cx + r, cy + r * 1.25], fill=v)
    glow = glow.filter(ImageFilter.GaussianBlur(30)).resize((W, H), Image.LANCZOS)
    tint = Image.new("RGB", (W, H), (24, 40, 34))
    return Image.composite(tint, base, glow).filter(ImageFilter.GaussianBlur(0.4))

BG_IMG = make_bg()

# ---------- waveform ----------
def waveform(d, cx, cy, t, amp, bars=27, spread=17, col=GREEN, a=1.0, seedoff=0.0):
    """Symmetric bar meter. Bars breathe on independent phases so it reads as a
    voice rather than an equalizer."""
    for i in range(bars):
        rel = (i - (bars - 1) / 2.0) / ((bars - 1) / 2.0)
        env = math.cos(rel * 1.35) ** 2
        ph = t * 5.2 + i * 0.55 + seedoff
        h = (0.30 + 0.70 * (0.5 + 0.5 * math.sin(ph))) * env * amp
        h = max(3.0, h)
        x = cx + (i - (bars - 1) / 2.0) * spread
        d.rounded_rectangle([x - 4, cy - h, x + 4, cy + h], radius=4,
                            fill=alpha(col, a))

# ---------- scenes ----------
def scene_problem(img, d, f):
    """Under "Every dictation app sends your voice away." (0.00-2.88)."""
    a = fs(f, 0.0, 0.45, 2.95, 3.30)
    if a <= 0: return
    t = f / FPS

    h1 = fs(f, 0.10, 0.60, 2.95, 3.25)
    if h1 > 0:
        fnt = font(SF, 74, weight=300)
        draw_tracked(d, (W/2, 640), "Every dictation app", fnt,
                     alpha(DIM, h1 * 0.95), track=-0.5, anchor="mm")
    h2 = fs(f, 0.45, 0.95, 2.95, 3.25)
    if h2 > 0:
        fnt = font(SF, 86, weight=600)
        draw_tracked(d, (W/2, 752), "sends your voice away.", fnt,
                     alpha(INK, h2), track=-1.2, anchor="mm")

    # The lift-off lands on the word "away" (~2.4-2.88s).
    lift = ease_in_out(sg(f, 1.55, 2.90))
    cy = 1210 - lift * 700
    amp = (1 - lift) * 128 + 6
    op = (1 - lift ** 1.6) * a
    waveform(d, W/2, cy, t, amp, col=mix(GREEN, WARM, lift), a=op)

    if lift > 0.12:
        for k in range(9):
            yy = 1210 - (k + 1) * 68 * lift
            if yy < cy + 40: continue
            o = (1 - k / 9.0) * 0.30 * a
            d.rounded_rectangle([W/2 - 2, yy, W/2 + 2, yy + 22], radius=2,
                                fill=alpha(FAINT, o))

def scene_cost(img, d, f):
    """Under "Fifteen dollars a month." (3.58-5.04)."""
    a = fs(f, 3.35, 3.55, 5.35, 5.68)
    if a <= 0: return

    la = fs(f, 3.38, 3.62, 5.35, 5.62)
    if la > 0:
        fnt = font(MONO, 40, weight=500)
        draw_tracked(d, (W/2, 700), "WISPR FLOW", fnt, alpha(DIM, la * 0.85),
                     track=6, anchor="mm")
        wl = measure(d, "WISPR FLOW", fnt, 6)
        d.rounded_rectangle([W/2 - wl/2, 736, W/2 + wl/2, 737], radius=1,
                            fill=alpha(FAINT, la))

    # "$15" hits exactly on the word "Fifteen"; "Needs internet" fills the
    # pause after the line, where the voice says nothing.
    cues = [(3.58, "$15", "/month"), (4.35, "Needs", "internet")]
    for i, (cue, big, small) in enumerate(cues):
        ra = fs(f, cue, cue + 0.30, 5.35, 5.62)
        if ra <= 0: continue
        y = 860 + i * 180
        dx = (1 - ease_out(sg(f, cue, cue + 0.45))) * 44
        fb = font(SF, 116, weight=700)
        fsm = font(SF, 58, weight=400)
        wb = measure(d, big, fb, -2)
        ws = measure(d, small, fsm, 0)
        x0 = W/2 - (wb + 22 + ws) / 2 + dx
        draw_tracked(d, (x0, y), big, fb, alpha(WARM, ra), track=-2, anchor="lm")
        draw_tracked(d, (x0 + wb + 22, y + 10), small, fsm, alpha(DIM, ra * 0.9),
                     anchor="lm")

    ca = fs(f, 4.80, 5.05, 5.35, 5.60)
    if ca > 0:
        fnt = font(SF, 42, weight=400)
        draw_tracked(d, (W/2, 1245), "Your voice goes to their servers.", fnt,
                     alpha(FAINT, ca), track=0, anchor="mm")

def scene_turn(img, d, f):
    """Under "Murmur doesn't." (5.97) and "It never leaves your Mac." (7.43-9.17)."""
    a = fs(f, 5.72, 5.95, 9.30, 9.55)
    if a <= 0: return
    t = f / FPS

    # The wordmark lands on "Murmur".
    na = fs(f, 5.95, 6.35, 9.30, 9.52)
    if na > 0:
        sc = 0.94 + 0.06 * ease_out_back(sg(f, 5.95, 6.55))
        fnt = font(SF, int(150 * sc), weight=250)
        draw_tracked(d, (W/2, 700), "Murmur", fnt, alpha(INK, na),
                     track=6, anchor="mm")

    wa = fs(f, 6.45, 6.80, 9.30, 9.52)
    if wa > 0:
        settle = ease_out(sg(f, 6.45, 7.35))
        cy = 690 + settle * 300
        waveform(d, W/2, cy, t, 96 * wa, col=GREEN, a=wa)

    # The line types out across the spoken words, finishing as the voice does.
    line = "It never leaves your Mac."
    ta = fs(f, 7.35, 7.50, 9.30, 9.52)
    if ta > 0:
        shown = int(len(line) * ease_in_out(sg(f, 7.43, 9.05)))
        fnt = font(SF, 64, weight=400)
        txt = line[:shown]
        draw_tracked(d, (W/2, 1185), txt, fnt, alpha(INK, ta), track=-0.4,
                     anchor="mm")
        if shown < len(line) and (f // 4) % 2 == 0:
            wtxt = measure(d, txt, fnt, -0.4)
            d.rounded_rectangle([W/2 + wtxt/2 + 8, 1155, W/2 + wtxt/2 + 12, 1217],
                                radius=2, fill=alpha(GREEN, ta))

def scene_proof(img, d, f):
    """Under "Quarter of a second." (9.83) and "Nothing uploaded." (11.69)."""
    a = fs(f, 9.62, 9.80, 13.15, 13.45)
    if a <= 0: return

    # Each stat lands on the phrase that names it; $0 fills the gap between,
    # where the voice is silent.
    rows = [(9.83, "0.25s", "to transcribe 11 seconds"),
            (10.80, "$0",   "free, and open source"),
            (11.69, "0 KB", "uploaded, ever")]
    for i, (cue, stat, label) in enumerate(rows):
        ra = fs(f, cue, cue + 0.32, 13.15, 13.42)
        if ra <= 0: continue
        y = 700 + i * 210
        dx = (1 - ease_out(sg(f, cue, cue + 0.48))) * 36

        fst = font(MONO, 104, weight=600)
        draw_tracked(d, (168 + dx, y), stat, fst, alpha(GREEN, ra), track=0,
                     anchor="lm")
        fl = font(SF, 46, weight=400)
        draw_tracked(d, (168 + dx, y + 84), label, fl, alpha(DIM, ra * 0.95),
                     anchor="lm")
        d.rounded_rectangle([168 + dx, y + 128, 912, y + 129], radius=1,
                            fill=alpha(FAINT, ra * 0.5))

def scene_close(img, d, f):
    """Under "Murmur." (13.76) and "Free and open source." (14.85-16.39)."""
    a = fs(f, 13.52, 13.74, 16.55, 16.85)
    if a <= 0: return
    t = f / FPS

    fnt = font(SF, 168, weight=250)
    draw_tracked(d, (W/2, 840), "Murmur", fnt, alpha(INK, a), track=7,
                 anchor="mm")

    wa = fs(f, 14.10, 14.40, 16.55, 16.82)
    if wa > 0:
        waveform(d, W/2, 1000, t, 34 * wa, bars=21, spread=15, col=GREEN,
                 a=wa * 0.85)

    sa = fs(f, 14.40, 14.70, 16.55, 16.82)
    if sa > 0:
        f2 = font(SF, 56, weight=400)
        draw_tracked(d, (W/2, 1130), "Your voice never leaves your Mac.", f2,
                     alpha(DIM, sa), track=-0.3, anchor="mm")
    # Lands on "Free and open source."
    ma = fs(f, 14.85, 15.15, 16.55, 16.82)
    if ma > 0:
        f3 = font(MONO, 36, weight=500)
        draw_tracked(d, (W/2, 1250), "FREE  \u00b7  NO SIGN-IN  \u00b7  OPEN SOURCE", f3,
                     alpha(GREEN, ma * 0.9), track=4, anchor="mm")

SCENES = [scene_problem, scene_cost, scene_turn, scene_proof, scene_close]

def render(f):
    img = BG_IMG.copy().convert("RGBA")
    ov = layer()
    d = ImageDraw.Draw(ov)
    for s in SCENES:
        s(img, d, f)
    img = Image.alpha_composite(img, ov)

    # Global film-in / film-out.
    fin = ease_out(sg(f, 0.0, 0.30))
    fout = 1 - ease_in_out(sg(f, 16.60, 16.85))
    k = fin * fout
    if k < 1:
        black = Image.new("RGBA", (W, H), (0, 0, 0, 255))
        img = Image.blend(black, img, k)
    return img.convert("RGB")

if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    only = [int(x) for x in sys.argv[1:]] if len(sys.argv) > 1 else range(N)
    for f in only:
        render(f).save(os.path.join(OUT, "f%04d.png" % f))
    print("rendered", len(list(only)), "frames")
