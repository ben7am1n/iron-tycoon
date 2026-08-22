#!/usr/bin/env python3
"""Render the hand-authored 64x64 three-quarter bench press sprite."""

from __future__ import annotations

import argparse
from pathlib import Path

from PIL import Image, ImageDraw

from treadmill_v2 import (
    DEFAULT_PALETTE,
    SPRITE_SIZE,
    TRANSPARENT,
    EquipmentPalette,
    contact_shadow,
    poly,
    rect,
)


DEFAULT_OUTPUT = Path("assets/sprites/bench_v1.png")


def draw_rack(draw: ImageDraw.ImageDraw, p: EquipmentPalette) -> None:
    """Draw two open uprights, catches, and grounded rack feet."""
    # Rear upright is cooler; front upright carries the warm key edge.
    poly(draw, [(45, 16), (50, 15), (50, 45), (46, 49), (44, 46)], p.outline)
    poly(draw, [(47, 18), (49, 18), (49, 44), (47, 46)], p.metal_dark)
    rect(draw, (47, 19, 47, 32), p.metal_base)
    poly(draw, [(47, 44), (59, 48), (58, 52), (45, 48)], p.outline)
    poly(draw, [(48, 45), (56, 48), (55, 49), (47, 47)], p.cool_shadow)

    poly(draw, [(13, 20), (18, 19), (20, 48), (16, 52), (13, 49)], p.outline)
    poly(draw, [(15, 21), (17, 21), (18, 47), (16, 49)], p.metal_dark)
    rect(draw, (15, 22, 15, 39), p.metal_base)
    rect(draw, (16, 22, 16, 30), p.warm_highlight)
    poly(draw, [(15, 48), (29, 52), (28, 56), (12, 52)], p.outline)
    poly(draw, [(17, 49), (26, 52), (25, 53), (15, 51)], p.metal_base)

    # J-hooks break the vertical silhouettes at bar height.
    rect(draw, (12, 20, 21, 25), p.outline)
    rect(draw, (15, 21, 20, 22), p.metal_base)
    rect(draw, (18, 23, 20, 24), p.cool_shadow)
    rect(draw, (43, 15, 53, 20), p.outline)
    rect(draw, (46, 16, 51, 17), p.metal_dark)
    rect(draw, (44, 18, 48, 19), p.cool_shadow)


def draw_barbell(draw: ImageDraw.ImageDraw, p: EquipmentPalette) -> None:
    """Draw a gently rising bar with clearly separated weight plates."""
    # Bar follows the suite's left-front to right-back oblique direction.
    poly(draw, [(6, 17), (56, 11), (58, 13), (8, 20)], p.outline)
    poly(draw, [(9, 17), (55, 12), (56, 13), (10, 19)], p.metal_base)
    poly(draw, [(12, 17), (38, 14), (39, 15), (13, 18)], p.warm_highlight)
    rect(draw, (26, 16, 34, 16), p.body_light)

    # Plate stacks are asymmetric in perspective: larger near-left, tighter rear-right.
    poly(draw, [(4, 12), (10, 11), (14, 14), (14, 23), (10, 27), (4, 25), (2, 21), (2, 15)], p.outline)
    poly(draw, [(5, 14), (9, 13), (11, 15), (11, 22), (9, 24), (5, 23), (4, 20), (4, 16)], p.body_dark)
    rect(draw, (5, 14, 7, 22), p.cool_shadow)
    rect(draw, (8, 15, 10, 20), p.metal_dark)
    rect(draw, (10, 18, 13, 20), p.outline)
    rect(draw, (11, 18, 12, 18), p.metal_base)

    poly(draw, [(54, 8), (59, 8), (62, 11), (62, 17), (59, 20), (54, 19), (52, 16), (52, 11)], p.outline)
    poly(draw, [(55, 10), (58, 10), (60, 12), (60, 16), (58, 18), (55, 17), (54, 15), (54, 12)], p.deep_shadow)
    rect(draw, (55, 10, 56, 16), p.cool_shadow)
    rect(draw, (51, 13, 55, 15), p.outline)
    rect(draw, (52, 13, 54, 13), p.metal_base)


def draw_bench(draw: ImageDraw.ImageDraw, p: EquipmentPalette) -> None:
    """Draw the padded bench as a long readable three-plane form."""
    # Frame and feet sit beneath the pad.
    poly(draw, [(22, 37), (27, 36), (29, 53), (25, 56), (23, 53)], p.outline)
    poly(draw, [(24, 38), (26, 38), (27, 52), (25, 53)], p.metal_dark)
    rect(draw, (24, 39, 24, 47), p.metal_base)
    poly(draw, [(25, 52), (38, 54), (38, 57), (23, 56)], p.outline)
    rect(draw, (27, 53, 36, 54), p.cool_shadow)

    poly(draw, [(42, 31), (46, 31), (48, 45), (44, 49), (42, 46)], p.outline)
    poly(draw, [(44, 33), (45, 33), (46, 44), (44, 46)], p.deep_shadow)
    poly(draw, [(44, 44), (55, 47), (54, 50), (42, 47)], p.outline)
    rect(draw, (46, 46, 53, 47), p.cool_shadow)

    # Pad: warm top, cool right face, dark underside. A seam separates headrest.
    poly(draw, [(17, 30), (42, 27), (50, 33), (26, 38), (15, 35)], p.outline)
    poly(draw, [(19, 31), (41, 29), (47, 32), (25, 36), (17, 34)], p.body_base)
    poly(draw, [(17, 34), (25, 36), (47, 32), (48, 36), (26, 41), (16, 37)], p.deep_shadow)
    poly(draw, [(19, 31), (29, 30), (31, 34), (23, 35), (17, 34)], p.body_light)
    poly(draw, [(19, 31), (28, 30), (29, 31), (20, 33)], p.warm_highlight)
    poly(draw, [(31, 29), (33, 29), (36, 34), (34, 34)], p.outline)
    rect(draw, (25, 38, 35, 39), p.cool_shadow)


def draw_finish(draw: ImageDraw.ImageDraw, p: EquipmentPalette) -> None:
    rect(draw, (14, 31, 15, 37), p.outline)
    rect(draw, (17, 45, 18, 48), p.warm_highlight)
    rect(draw, (47, 25, 49, 26), p.cool_shadow)
    rect(draw, (13, 51, 17, 52), p.metal_base)
    rect(draw, (54, 48, 57, 49), p.deep_shadow)


def render_bench(palette: EquipmentPalette = DEFAULT_PALETTE) -> Image.Image:
    image = Image.new("RGBA", (SPRITE_SIZE, SPRITE_SIZE), TRANSPARENT)
    draw = ImageDraw.Draw(image)
    contact_shadow(draw, palette, left=4, right=61, top=49, bottom=57)
    draw_rack(draw, palette)
    draw_bench(draw, palette)
    draw_barbell(draw, palette)
    draw_finish(draw, palette)
    return image


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()
    sprite = render_bench()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    sprite.save(args.output, format="PNG", optimize=False)
    print(f"wrote {args.output} ({sprite.width}x{sprite.height}, {sprite.mode})")


if __name__ == "__main__":
    main()
