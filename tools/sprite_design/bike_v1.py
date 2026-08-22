#!/usr/bin/env python3
"""Render the hand-authored 64x64 stationary bike sprite.

The side-facing flywheel is the primary read; saddle, crank, pedals, frame,
and cyan console are separated around it in a compact three-quarter view.
"""

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


DEFAULT_OUTPUT = Path("assets/sprites/bike_v1.png")


def draw_ground_frame(draw: ImageDraw.ImageDraw, p: EquipmentPalette) -> None:
    """Draw floor bars and the load-bearing lower frame."""
    poly(draw, [(11, 51), (46, 48), (57, 52), (55, 56), (18, 59), (8, 55)], p.outline)
    poly(draw, [(14, 52), (45, 50), (53, 52), (51, 54), (18, 57), (11, 55)], p.body_dark)
    poly(draw, [(14, 52), (45, 50), (48, 51), (18, 54), (12, 54)], p.metal_base)
    rect(draw, (8, 54, 18, 57), p.outline)
    rect(draw, (11, 54, 20, 55), p.metal_dark)
    rect(draw, (49, 51, 58, 55), p.outline)
    rect(draw, (49, 51, 55, 52), p.cool_shadow)

    # Main triangle. Broad facets keep the frame legible behind the wheel.
    poly(draw, [(20, 26), (25, 24), (38, 45), (34, 49), (18, 52), (14, 49)], p.outline)
    poly(draw, [(21, 28), (24, 27), (35, 45), (32, 47), (19, 49), (17, 48)], p.metal_dark)
    poly(draw, [(21, 28), (23, 28), (31, 44), (28, 45)], p.metal_base)
    rect(draw, (21, 29, 21, 37), p.warm_highlight)


def draw_flywheel(draw: ImageDraw.ImageDraw, p: EquipmentPalette) -> None:
    """Draw a chunky, slightly oblique flywheel with concentric value rings."""
    # Rear half is cooler and shifted right to imply thickness.
    poly(draw, [(35, 28), (45, 27), (52, 33), (54, 45), (49, 52), (38, 53),
                (30, 47), (29, 36)], p.outline)
    poly(draw, [(38, 29), (46, 29), (50, 34), (52, 44), (48, 49), (39, 51),
                (33, 46), (32, 36)], p.cool_shadow)
    rect(draw, (46, 33, 51, 45), p.deep_shadow)

    # Front disc: stepped octagon, clean at native resolution.
    poly(draw, [(33, 29), (42, 28), (49, 33), (51, 41), (48, 48), (41, 52),
                (33, 49), (29, 43), (29, 35)], p.outline)
    poly(draw, [(35, 31), (41, 30), (46, 34), (48, 41), (45, 46), (40, 49),
                (35, 47), (32, 42), (32, 35)], p.body_dark)
    poly(draw, [(35, 32), (40, 31), (44, 34), (45, 41), (42, 45), (37, 46),
                (33, 42), (33, 36)], p.metal_dark)
    # Warm upper-left crescent and cool lower-right crescent define the dish.
    rect(draw, (35, 32, 40, 33), p.metal_base)
    rect(draw, (33, 35, 34, 40), p.metal_base)
    rect(draw, (34, 34, 34, 36), p.warm_highlight)
    rect(draw, (42, 35, 44, 42), p.deep_shadow)
    rect(draw, (38, 44, 42, 46), p.cool_shadow)

    # Crank hub and two separated pedal silhouettes.
    rect(draw, (36, 37, 43, 44), p.outline)
    rect(draw, (38, 38, 42, 42), p.metal_base)
    rect(draw, (39, 39, 41, 41), p.warm_highlight)
    poly(draw, [(40, 40), (48, 36), (49, 38), (42, 42)], p.outline)
    rect(draw, (47, 35, 54, 38), p.outline)
    rect(draw, (48, 35, 52, 36), p.metal_base)
    poly(draw, [(39, 42), (33, 47), (31, 46), (37, 40)], p.outline)
    rect(draw, (27, 46, 34, 49), p.outline)
    rect(draw, (29, 46, 33, 47), p.cool_shadow)


def draw_saddle_and_post(draw: ImageDraw.ImageDraw, p: EquipmentPalette) -> None:
    """Draw the unmistakable seat silhouette above the flywheel."""
    poly(draw, [(18, 19), (25, 18), (30, 21), (28, 25), (20, 25), (16, 23)], p.outline)
    poly(draw, [(19, 20), (25, 20), (28, 21), (26, 23), (20, 23), (18, 22)], p.body_base)
    rect(draw, (20, 20, 25, 20), p.body_light)
    rect(draw, (26, 22, 28, 23), p.deep_shadow)

    poly(draw, [(21, 24), (27, 23), (31, 37), (27, 41), (24, 38)], p.outline)
    poly(draw, [(23, 25), (26, 25), (29, 36), (27, 38), (26, 36)], p.metal_dark)
    rect(draw, (23, 26, 23, 31), p.metal_base)
    rect(draw, (23, 26, 23, 28), p.warm_highlight)


def draw_handlebar_and_console(draw: ImageDraw.ImageDraw, p: EquipmentPalette) -> None:
    """Draw forward bars, grips, and a small cyan training display."""
    # Forward post leans toward the upper-right, away from the saddle.
    poly(draw, [(39, 28), (44, 27), (49, 15), (46, 13), (42, 19)], p.outline)
    poly(draw, [(41, 28), (43, 27), (47, 15), (46, 15), (43, 20)], p.metal_dark)
    rect(draw, (45, 16, 46, 22), p.metal_base)
    rect(draw, (46, 16, 46, 19), p.warm_highlight)

    # Split horns make the handlebar read independently from the console.
    poly(draw, [(43, 15), (45, 11), (49, 10), (51, 12), (48, 15)], p.outline)
    poly(draw, [(45, 14), (46, 12), (49, 12), (48, 13)], p.metal_base)
    poly(draw, [(47, 15), (52, 12), (56, 14), (55, 17), (50, 16)], p.outline)
    rect(draw, (51, 14, 55, 15), p.cool_shadow)
    rect(draw, (43, 10, 49, 12), p.outline)
    rect(draw, (45, 10, 49, 10), p.warm_highlight)
    rect(draw, (52, 13, 57, 16), p.outline)
    rect(draw, (53, 14, 56, 14), p.deep_shadow)

    # Cyan focal point mirrors the treadmill UI without overpowering the wheel.
    poly(draw, [(36, 10), (45, 8), (50, 11), (48, 16), (39, 17), (35, 14)], p.outline)
    poly(draw, [(38, 11), (44, 10), (47, 11), (46, 14), (39, 15), (37, 13)], p.screen_dark)
    rect(draw, (39, 11, 44, 12), p.screen_cyan)
    rect(draw, (40, 11, 43, 11), p.screen_glow)
    rect(draw, (45, 13, 46, 13), p.screen_mid)


def draw_finish(draw: ImageDraw.ImageDraw, p: EquipmentPalette) -> None:
    rect(draw, (17, 47, 19, 49), p.warm_highlight)
    rect(draw, (24, 56, 31, 56), p.body_light)
    rect(draw, (52, 52, 55, 53), p.deep_shadow)
    rect(draw, (30, 30, 31, 31), p.cool_shadow)


def render_bike(palette: EquipmentPalette = DEFAULT_PALETTE) -> Image.Image:
    image = Image.new("RGBA", (SPRITE_SIZE, SPRITE_SIZE), TRANSPARENT)
    draw = ImageDraw.Draw(image)
    contact_shadow(draw, palette, left=7, right=59, top=52, bottom=58)
    draw_ground_frame(draw, palette)
    draw_flywheel(draw, palette)
    draw_saddle_and_post(draw, palette)
    draw_handlebar_and_console(draw, palette)
    draw_finish(draw, palette)
    return image


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()
    sprite = render_bike()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    sprite.save(args.output, format="PNG", optimize=False)
    print(f"wrote {args.output} ({sprite.width}x{sprite.height}, {sprite.mode})")


if __name__ == "__main__":
    main()
