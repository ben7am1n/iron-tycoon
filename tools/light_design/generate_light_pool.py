#!/usr/bin/env python3
"""Generate the single-hue smooth light-pool asset for 撸铁大亨.

The texture matches the 52x36 half-size used by the three hanging lamps. Every
non-transparent pixel has the same #F5D97B RGB; only alpha changes, following a
smoothstep radial falloff from the center to the elliptical edge.

Run from the repository root:
    python3 tools/light_design/generate_light_pool.py
"""

from __future__ import annotations

from math import hypot
from pathlib import Path

from PIL import Image


OUTPUT = Path("assets/tiles/light_pool.png")
SIZE = (104, 72)
WARM_RGB = (245, 217, 123)
MAX_ALPHA = 96


def smoothstep01(value: float) -> float:
    value = max(0.0, min(1.0, value))
    return value * value * (3.0 - 2.0 * value)


def render() -> Image.Image:
    width, height = SIZE
    image = Image.new("RGBA", SIZE, (*WARM_RGB, 0))
    pixels = image.load()
    cx = width / 2.0
    cy = height / 2.0
    rx = width / 2.0
    ry = height / 2.0
    for y in range(height):
        for x in range(width):
            radius = hypot((x + 0.5 - cx) / rx, (y + 0.5 - cy) / ry)
            if radius >= 1.0:
                alpha = 0
            else:
                alpha = round(MAX_ALPHA * (1.0 - smoothstep01(radius)))
            pixels[x, y] = (*WARM_RGB, alpha)
    return image


def validate(image: Image.Image) -> None:
    colors = {pixel[:3] for pixel in image.getdata() if pixel[3] > 0}
    if colors != {WARM_RGB}:
        raise ValueError(f"expected one non-transparent hue, got {colors}")
    alpha = image.getchannel("A")
    lo, hi = alpha.getextrema()
    if lo != 0 or hi != MAX_ALPHA:
        raise ValueError(f"unexpected alpha range {lo}..{hi}")
    center = alpha.getpixel((SIZE[0] // 2, SIZE[1] // 2))
    middle = alpha.getpixel((SIZE[0] * 3 // 4, SIZE[1] // 2))
    edge = alpha.getpixel((SIZE[0] - 1, SIZE[1] // 2))
    if not center > middle > edge:
        raise ValueError(f"falloff is not monotonic: {center}, {middle}, {edge}")


def main() -> None:
    image = render()
    validate(image)
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    image.save(OUTPUT, optimize=False)
    print(f"{OUTPUT}: {SIZE[0]}x{SIZE[1]}, hue=#F5D97B, alpha=0..{MAX_ALPHA}")


if __name__ == "__main__":
    main()
