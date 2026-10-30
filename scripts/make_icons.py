#!/usr/bin/env python3
"""Draws the XRay VPN launcher icons (tick dial + bolt). Output goes to assets/icon/."""
import math
from PIL import Image, ImageDraw, ImageFilter

S = 1024
SS = 2  # supersample
TURQ = (91, 184, 174)

def lerp(a, b, t): return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))

def gradient_bg(size):
    im = Image.new("RGB", (size, size))
    px = im.load()
    top, bot = (38, 56, 80), (5, 8, 13)
    for y in range(size):
        for x in range(size):
            t = min(1, max(0, (y / size) * 0.8 + (x / size) * 0.2))
            px[x, y] = lerp(top, bot, t)
    return im

def bolt_points(cx, cy, h):
    # lightning bolt scaled to height h, centred on (cx, cy)
    pts = [(0.58, 0.0), (0.12, 0.56), (0.45, 0.56), (0.34, 1.0), (0.88, 0.40), (0.54, 0.40), (0.72, 0.0)]
    return [(cx + (x - 0.5) * h * 0.95, cy + (y - 0.5) * h) for x, y in pts]

def draw_foreground(size, mono=False, scale=1.0):
    """Dial + bolt on transparent. scale<1 keeps it inside the adaptive-icon safe zone."""
    W = size * SS
    im = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    c = W / 2
    R = W * 0.46 * scale
    # ticks
    n = 60
    for i in range(n):
        a = i / n * 2 * math.pi - math.pi / 2
        major = i % 5 == 0
        r1, r2 = R * (0.80 if major else 0.85), R * 0.96
        lit = 1 - (i / n) * 0.75
        col = (255, 255, 255, 255) if mono else (*TURQ, int(255 * (0.35 + 0.65 * lit)))
        d.line([(c + math.cos(a) * r1, c + math.sin(a) * r1), (c + math.cos(a) * r2, c + math.sin(a) * r2)],
               fill=col, width=int(W * (0.016 if major else 0.010) * scale))
    # core lens
    cr = R * 0.62
    if mono:
        d.ellipse([c - cr, c - cr, c + cr, c + cr], outline=(255, 255, 255, 255), width=int(W * 0.012 * scale))
    else:
        core = Image.new("RGBA", (W, W), (0, 0, 0, 0))
        cd = ImageDraw.Draw(core)
        steps = 60
        for k in range(steps):
            t = k / steps
            rr = cr * (1 - t)
            col = lerp((120, 205, 195), (44, 120, 116), t)
            cd.ellipse([c - rr - t * cr * 0.18, c - rr - t * cr * 0.22, c + rr - t * cr * 0.18, c + rr - t * cr * 0.22], fill=(*col, 255))
        mask = Image.new("L", (W, W), 0)
        ImageDraw.Draw(mask).ellipse([c - cr, c - cr, c + cr, c + cr], fill=255)
        im.paste(core, (0, 0), mask)
        glow = im.filter(ImageFilter.GaussianBlur(W * 0.02))
        im = Image.alpha_composite(glow, im)
        d = ImageDraw.Draw(im)
    # bolt
    pts = bolt_points(c, c, cr * 1.15)
    if mono:
        d.polygon(pts, fill=(255, 255, 255, 255))
    else:
        d.polygon(pts, fill=(8, 14, 20, 255))
    return im.resize((size, size), Image.LANCZOS)

def rounded(im, radius):
    mask = Image.new("L", im.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, im.size[0], im.size[1]], radius=radius, fill=255)
    out = im.convert("RGBA")
    out.putalpha(mask)
    return out

out = "assets/icon/"
bg = gradient_bg(S)
fg_full = draw_foreground(S, scale=1.0)
# 1) Full icon (iOS / legacy): flat square, no alpha
full = bg.convert("RGBA")
full.alpha_composite(fg_full)
full.convert("RGB").save(out + "icon.png")
# 2) Adaptive layers (Android 8+): background + foreground inside the 66% safe zone
bg.save(out + "icon_bg.png")
draw_foreground(S, scale=0.66).save(out + "icon_fg.png")
# 3) Monochrome layer for Android 13 themed icons
draw_foreground(S, mono=True, scale=0.66).save(out + "icon_mono.png")
# 4) Rounded preview (for the README / store listing)
rounded(full, int(S * 0.22)).resize((512, 512), Image.LANCZOS).save(out + "preview.png")
print("icons written to", out)
