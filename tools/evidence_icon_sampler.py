#!/usr/bin/env python3
"""Locate and sample the 4 HUD/palette semantic icons in phase-d-v2-ui.png.

Tight regions derived from the HUD layout (1280x720, ui_scale 1.0):
  - top bar strip: y in [0, 64]
  - CoinIcon: MoneyGroup first element, x in [16, 90]
  - FaceIcon: SatisfactionGroup center, x in [430, 590]
  - TimeOfDay: TimeGroup before transport cluster, x in [900, 1180]
  - Shop icon: first palette tile, x in [0, 120], y in [656, 720]
"""
import sys
from collections import Counter

from PIL import Image

PATH = sys.argv[1] if len(sys.argv) > 1 else "tests/evidence/phase-d-v2-ui.png"
img = Image.open(PATH).convert("RGB")
W, H = img.size
print(f"image={PATH} size={W}x{H}")


def dominant_cluster(region, pred, label):
    x0, y0, x1, y1 = region
    pts = []
    for y in range(y0, y1):
        for x in range(x0, x1):
            c = img.getpixel((x, y))
            if pred(c):
                pts.append((x, y, c))
    if not pts:
        print(f"{label}: NO MATCHING PIXELS in region {region}")
        return None
    buckets = Counter((c[0] // 16, c[1] // 16, c[2] // 16) for _, _, c in pts)
    top_bucket = buckets.most_common(1)[0][0]
    bucket_px = [c for _, _, c in pts if (c[0] // 16, c[1] // 16, c[2] // 16) == top_bucket]
    n = len(bucket_px)
    avg = tuple(round(sum(p[i] for p in bucket_px) / n) for i in range(3))
    bx0 = min(x for x, _, _ in pts); bx1 = max(x for x, _, _ in pts)
    by0 = min(y for _, y, _ in pts); by1 = max(y for _, y, _ in pts)
    print(
        f"{label}: bbox=({bx0},{by0})-({bx1},{by1}) matches={len(pts)} "
        f"dominant={avg} (#{avg[0]:02X}{avg[1]:02X}{avg[2]:02X})"
    )
    return avg


# --- CoinIcon: emoji 🪙 renders silver-gray; fixed ● renders Butter ---
def is_silver(c):
    r, g, b = c
    return abs(r - g) < 35 and abs(g - b) < 35 and r > 150


def is_butter(c):
    r, g, b = c
    return abs(r - 245) < 30 and abs(g - 217) < 30 and abs(b - 123) < 35


COIN = (16, 4, 90, 60)
print("--- CoinIcon ---")
b = dominant_cluster(COIN, is_butter, "CoinIcon(butter)")
s = dominant_cluster(COIN, is_silver, "CoinIcon(silver)")
print("CoinIcon verdict:", "BUTTER (fixed)" if b else ("SILVER-GRAY (emoji bug)" if s else "UNKNOWN"))

# --- FaceIcon: emoji 🙂 yellow; fixed :) Sage ---
def is_emoji_yellow(c):
    r, g, b = c
    return r > 220 and g > 150 and b < 120


def is_sage(c):
    r, g, b = c
    return abs(r - 143) < 35 and abs(g - 191) < 35 and abs(b - 159) < 35


FACE = (430, 4, 590, 60)
print("--- FaceIcon ---")
f = dominant_cluster(FACE, is_emoji_yellow, "FaceIcon(emoji-yellow)")
g_ = dominant_cluster(FACE, is_sage, "FaceIcon(sage)")
print("FaceIcon verdict:", "EMOJI-YELLOW (bug)" if f else ("SAGE (fixed)" if g_ else "UNKNOWN"))

# --- TimeOfDay: emoji 🕛 white face; fixed "HH:MM" Sky text ---
def is_white(c):
    r, g, b = c
    return r > 235 and g > 235 and b > 235


def is_sky(c):
    r, g, b = c
    return abs(r - 142) < 35 and abs(g - 197) < 35 and abs(b - 232) < 35


TIME = (900, 4, 1180, 60)
print("--- TimeOfDay ---")
t = dominant_cluster(TIME, is_white, "TimeOfDay(white)")
sk = dominant_cluster(TIME, is_sky, "TimeOfDay(sky)")
print("TimeOfDay verdict:", "WHITE-EMOJI (bug)" if t else ("SKY (fixed)" if sk else "UNKNOWN"))

# --- ShopIcon: Peach "T" (correct before and after) ---
def is_peach(c):
    r, g, b = c
    return abs(r - 242) < 25 and abs(g - 180) < 25 and abs(b - 134) < 25


SHOP = (0, 624, 120, 720)
print("--- ShopIcon ---")
p = dominant_cluster(SHOP, is_peach, "ShopIcon(peach)")
print("ShopIcon verdict:", "PEACH" if p else "UNKNOWN")
