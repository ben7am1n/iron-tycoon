#!/usr/bin/env python3
"""PHASED-F before/after pixel evidence: sample each semantic icon's label
rect and report the dominant color (independent PIL, no Godot).

BEFORE rects located from the buggy image itself (gray coin blob, yellow
emoji face at (499,17)-(512,31), white clock at (1098,18)-(1109,26)).
AFTER rects are the label rects the evidence capture reported:
  CoinIcon     (16,10)-(29,38)     TimeOfDayLabel (1071,12)-(1113,35)
  FaceIcon     (482,12)-(496,35)   ShopTileIcon   (10,632)-(86,671)
"""
import sys
from collections import Counter

from PIL import Image


def dominant(img, x0, y0, x1, y1, min_lum=0.45):
    buckets = Counter()
    sums = {}
    for y in range(y0, y1):
        for x in range(x0, x1):
            r, g, b = img.getpixel((x, y))[:3]
            if (r + g + b) / 3.0 < min_lum * 255.0:
                continue
            key = (r // 16, g // 16, b // 16)
            buckets[key] += 1
            sums.setdefault(key, [0, 0, 0])
            sums[key][0] += r
            sums[key][1] += g
            sums[key][2] += b
    if not buckets:
        return None, 0
    top = buckets.most_common(1)[0][0]
    n = buckets[top]
    s = sums[top]
    return tuple(round(v / n) for v in s), n


ICONS = [
    ("CoinIcon",     "BUTTER #F5D97B", (16, 10, 29, 38),      (17, 17, 26, 31)),
    ("FaceIcon",     "SAGE   #8FBF9F", (482, 12, 496, 35),    (499, 17, 512, 31)),
    ("TimeOfDay",    "SKY    #8EC5E8", (1071, 12, 1113, 35),  (1098, 18, 1109, 26)),
    ("ShopIcon",     "PEACH  #F2B486", (10, 632, 86, 671),    (10, 632, 86, 671)),
]

after = Image.open(sys.argv[1]).convert("RGB")
before = Image.open(sys.argv[2]).convert("RGB")

print(f"{'icon':<12} {'semantic':<16} {'BEFORE (emoji)':<26} {'AFTER (mono)':<26}")
print("-" * 82)
for name, want, a_rect, b_rect in ICONS:
    b_dom, b_px = dominant(before, *b_rect)
    a_dom, a_px = dominant(after, *a_rect)
    b_s = f"#{b_dom[0]:02X}{b_dom[1]:02X}{b_dom[2]:02X} px={b_px}" if b_dom else "none"
    a_s = f"#{a_dom[0]:02X}{a_dom[1]:02X}{a_dom[2]:02X} px={a_px}" if a_dom else "none"
    print(f"{name:<12} {want:<16} {b_s:<26} {a_s:<26}")
