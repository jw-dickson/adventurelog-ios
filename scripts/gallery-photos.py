#!/usr/bin/env python3
# AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.
"""Draws the plain landscapes the screenshot gallery seeds as item and trip photos.

They are drawn, not photographed, so the gallery shows thumbnails without any real pictures.

    python3 scripts/gallery-photos.py AppUITests/Photos
"""
import math, sys
from PIL import Image, ImageDraw, ImageFilter
W, H = 480, 360
def grad(d, top, bottom, y0, y1):
    for y in range(y0, y1):
        t = (y - y0) / max(1, y1 - y0 - 1)
        c = tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
        d.line([(0, y), (W, y)], fill=c)
def ridge(d, base, amp, freq, phase, color):
    pts = [(x, base - amp * (0.6 * math.sin(x * freq + phase) + 0.4 * math.sin(x * freq * 2.7 + phase * 1.9))) for x in range(0, W + 1, 4)]
    d.polygon(pts + [(W, H), (0, H)], fill=color)
def save(img, name):
    img.filter(ImageFilter.GaussianBlur(0.6)).save(f"{sys.argv[1]}/{name}.jpg", quality=72, optimize=True)

# Lookout: a curved bay between granite hills, midday.
img = Image.new("RGB", (W, H)); d = ImageDraw.Draw(img)
grad(d, (122, 176, 214), (198, 224, 236), 0, 170)
ridge(d, 150, 26, 0.012, 0.4, (96, 112, 104))
grad(d, (40, 120, 150), (70, 160, 170), 170, H)
d.ellipse([40, 200, 440, 420], fill=(232, 222, 196))
d.ellipse([60, 170, 420, 390], fill=(54, 140, 160))
ridge(d, 300, 40, 0.02, 2.0, (70, 92, 66))
save(img, "lookout")

# Cruise: sunset over water.
img = Image.new("RGB", (W, H)); d = ImageDraw.Draw(img)
grad(d, (64, 58, 110), (236, 150, 92), 0, 200)
d.ellipse([200, 150, 280, 230], fill=(250, 210, 140))
ridge(d, 200, 14, 0.01, 1.2, (60, 52, 74))
grad(d, (150, 96, 92), (40, 44, 70), 200, H)
for y in range(210, H, 12):
    d.line([(220 - (y - 200) // 3, y), (260 + (y - 200) // 3, y)], fill=(240, 180, 120), width=2)
save(img, "cruise")

# Campground: forest under a pale sky.
img = Image.new("RGB", (W, H)); d = ImageDraw.Draw(img)
grad(d, (176, 200, 214), (226, 232, 226), 0, 220)
ridge(d, 200, 20, 0.015, 3.0, (110, 128, 120))
grad(d, (88, 110, 72), (60, 82, 52), 220, H)
for i, x in enumerate(range(-10, W + 20, 34)):
    h = 90 + (i * 37) % 50
    d.polygon([(x, 250), (x + 18, 250 - h), (x + 36, 250)], fill=(38, 72, 52))
d.polygon([(250, 320), (290, 270), (330, 320)], fill=(196, 120, 64))
save(img, "campground")

# Cover: coastline and mountains for the whole trip.
img = Image.new("RGB", (W, H)); d = ImageDraw.Draw(img)
grad(d, (150, 190, 220), (230, 236, 232), 0, 200)
ridge(d, 170, 60, 0.008, 0.2, (120, 130, 140))
ridge(d, 200, 36, 0.013, 1.6, (82, 104, 92))
grad(d, (50, 120, 140), (30, 80, 110), 220, H)
ridge(d, 250, 18, 0.018, 4.0, (196, 182, 150))
save(img, "cover")
