#!/usr/bin/env python3
"""Render the hand-authored 64x64 yoga mat sprite with a rolled far edge."""

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


DEFAULT_OUTPUT = Path("assets/sprites/mat_v1.png")


def draw_mat(draw: ImageDraw.ImageDraw, p: EquipmentPalette) -> None:
    """Draw a low oblique mat with a raised curl only at the far edge."""
    # Thin lower-right thickness preserves the贴地 read.
    poly(draw, [(11, 30), (42, 22), (57, 43), (24, 53), (9, 48)], p.outline)
    poly(draw, [(12, 32), (41, 25), (54, 43), (23, 50), (11, 47)], p.cool_shadow)
    poly(draw, [(23, 50), (54, 43), (57, 45), (24, 53), (10, 49), (11, 47)], p.deep_shadow)
    poly(draw, [(51, 40), (54, 43), (23, 50), (11, 47), (10, 44)], p.cool_shadow)

    # Main top plane uses broad teal value zones and a warm left edge.
    poly(draw, [(14, 31), (40, 25), (52, 42), (23, 48), (12, 45)], p.body_base)
    poly(draw, [(14, 31), (21, 30), (29, 46), (23, 48), (12, 45)], p.body_light)
    poly(draw, [(40, 25), (52, 42), (45, 43), (34, 27)], p.body_dark)
    poly(draw, [(15, 32), (17, 31), (24, 46), (22, 47), (14, 44)], p.warm_highlight)

    # Long seams keep the wide surface from becoming a featureless color field.
    poly(draw, [(23, 30), (25, 29), (37, 45), (35, 46)], p.cool_shadow)
    poly(draw, [(31, 28), (33, 27), (45, 42), (43, 43)], p.body_light)
    poly(draw, [(19, 39), (45, 33), (46, 35), (20, 41)], p.body_dark)
    rect(draw, (26, 45, 34, 46), p.metal_dark)
    rect(draw, (36, 42, 42, 43), p.cool_shadow)


def draw_roll(draw: ImageDraw.ImageDraw, p: EquipmentPalette) -> None:
    """Draw a stepped cylinder at the far edge with a visible spiral end."""
    # Rolled lip crosses the rear plane and casts a crisp one-pixel occlusion.
    poly(draw, [(8, 25), (38, 18), (46, 22), (44, 29), (14, 36), (7, 32)], p.outline)
    poly(draw, [(11, 26), (37, 20), (43, 23), (41, 27), (15, 33), (10, 31)], p.body_base)
    poly(draw, [(11, 26), (37, 20), (40, 21), (14, 28), (10, 30)], p.warm_highlight)
    poly(draw, [(15, 31), (41, 25), (41, 28), (15, 34), (10, 31)], p.body_dark)
    poly(draw, [(36, 20), (43, 21), (46, 24), (44, 29), (39, 30), (36, 27)], p.outline)
    poly(draw, [(38, 21), (42, 22), (44, 24), (42, 27), (39, 27), (37, 25)], p.body_light)
    rect(draw, (39, 23, 42, 25), p.deep_shadow)
    rect(draw, (40, 23, 42, 23), p.metal_base)
    rect(draw, (39, 26, 41, 26), p.deep_shadow)

    # A narrow fastening band adds scale and a deliberate material break.
    poly(draw, [(25, 22), (29, 21), (34, 29), (30, 30)], p.body_dark)
    poly(draw, [(26, 22), (28, 22), (33, 28), (31, 29)], p.metal_base)
    rect(draw, (27, 22, 28, 22), p.warm_highlight)


def draw_finish(draw: ImageDraw.ImageDraw, p: EquipmentPalette) -> None:
    rect(draw, (12, 42, 13, 45), p.warm_highlight)
    rect(draw, (22, 49, 30, 49), p.metal_dark)
    rect(draw, (48, 42, 52, 43), p.deep_shadow)
    rect(draw, (24, 52, 33, 52), p.cool_shadow)


def render_mat(palette: EquipmentPalette = DEFAULT_PALETTE) -> Image.Image:
    image = Image.new("RGBA", (SPRITE_SIZE, SPRITE_SIZE), TRANSPARENT)
    draw = ImageDraw.Draw(image)
    # Flatter and narrower shadow than the machines: the object hugs the floor.
    contact_shadow(draw, palette, left=7, right=58, top=45, bottom=53)
    draw_mat(draw, palette)
    draw_roll(draw, palette)
    draw_finish(draw, palette)
    return image


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()
    sprite = render_mat()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    sprite.save(args.output, format="PNG", optimize=False)
    print(f"wrote {args.output} ({sprite.width}x{sprite.height}, {sprite.mode})")


if __name__ == "__main__":
    main()
