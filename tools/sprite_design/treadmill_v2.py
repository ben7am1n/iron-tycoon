#!/usr/bin/env python3
"""Render the hand-authored 64x64 treadmill v2 sprite and v2/v1 sheet.

The v2 belt is deliberately split into hard value bands.  Its one-pixel
transverse ribs keep a stable cadence through the middle of the deck, fixing
the soft, low-contrast read of the v1 pilot without adding antialiasing.

Run from the repository root:
    python3 tools/sprite_design/treadmill_v2.py
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


Color = tuple[int, int, int, int]
TRANSPARENT: Color = (0, 0, 0, 0)
SPRITE_SIZE = 64
DEFAULT_OUTPUT = Path("assets/sprites/treadmill_v2.png")
DEFAULT_COMPARE = Path("assets/sprites/treadmill_compare.png")
DEFAULT_V1 = Path("assets/sprites/treadmill_v1.png")


@dataclass(frozen=True)
class EquipmentPalette:
    """Shared suite palette: warm upper-left light, cool lower-right shade."""

    contact_shadow: Color = (15, 24, 35, 104)
    contact_edge: Color = (15, 24, 35, 56)
    outline: Color = (20, 29, 40, 255)
    deep_shadow: Color = (31, 43, 56, 255)
    cool_shadow: Color = (48, 64, 78, 255)
    body_dark: Color = (57, 68, 79, 255)
    body_base: Color = (76, 88, 98, 255)
    body_light: Color = (112, 127, 134, 255)
    belt_dark: Color = (31, 39, 47, 255)
    belt_base: Color = (49, 61, 70, 255)
    belt_light: Color = (76, 92, 101, 255)
    metal_dark: Color = (91, 108, 119, 255)
    metal_base: Color = (151, 166, 171, 255)
    warm_highlight: Color = (225, 218, 194, 255)
    screen_dark: Color = (17, 58, 69, 255)
    screen_mid: Color = (29, 150, 171, 255)
    screen_cyan: Color = (43, 210, 224, 255)
    screen_glow: Color = (153, 248, 238, 255)


DEFAULT_PALETTE = EquipmentPalette()


def rect(draw: ImageDraw.ImageDraw, box: tuple[int, int, int, int], color: Color) -> None:
    """Draw an inclusive, hard-edged rectangle."""
    draw.rectangle(box, fill=color)


def poly(draw: ImageDraw.ImageDraw, points: list[tuple[int, int]], color: Color) -> None:
    """Draw a hard-edged pixel polygon."""
    draw.polygon(points, fill=color)


def contact_shadow(
    draw: ImageDraw.ImageDraw,
    palette: EquipmentPalette = DEFAULT_PALETTE,
    *,
    left: int = 11,
    right: int = 60,
    top: int = 52,
    bottom: int = 59,
) -> None:
    """Paint a stepped shadow with sparse edge pixels and no blur."""
    rect(draw, (left + 6, top, right - 6, bottom), palette.contact_shadow)
    rect(draw, (left + 2, top + 2, right - 2, bottom - 2), palette.contact_shadow)
    rect(draw, (left, top + 3, left + 1, bottom - 3), palette.contact_edge)
    rect(draw, (right - 1, top + 3, right, bottom - 3), palette.contact_edge)
    rect(draw, (left + 15, bottom + 1, right - 10, bottom + 1), palette.contact_edge)


def draw_deck(draw: ImageDraw.ImageDraw, p: EquipmentPalette) -> None:
    """Draw the chassis, crisp deck planes, belt ribs, rollers, and feet."""
    # Feet establish four clean ground contacts before the larger chassis.
    rect(draw, (17, 51, 23, 57), p.outline)
    rect(draw, (19, 51, 24, 55), p.metal_dark)
    rect(draw, (16, 56, 27, 58), p.outline)
    rect(draw, (19, 55, 27, 56), p.metal_base)
    rect(draw, (49, 51, 55, 57), p.outline)
    rect(draw, (49, 51, 53, 55), p.deep_shadow)
    rect(draw, (47, 56, 59, 58), p.outline)
    rect(draw, (49, 55, 57, 56), p.cool_shadow)

    # Chassis side plane, shaded continuously toward the lower-right.
    poly(draw, [(14, 29), (42, 25), (59, 47), (57, 54), (27, 58), (19, 52)], p.outline)
    poly(draw, [(17, 32), (41, 28), (56, 48), (53, 52), (28, 55), (22, 50)], p.body_dark)
    poly(draw, [(41, 28), (56, 48), (53, 52), (49, 49), (37, 30)], p.deep_shadow)
    poly(draw, [(22, 50), (53, 48), (53, 52), (28, 55)], p.cool_shadow)
    rect(draw, (29, 54, 40, 55), p.body_light)

    # Two-pixel outline/guard rails make the top plane read at native size.
    poly(draw, [(15, 27), (41, 24), (57, 46), (51, 52), (25, 55), (18, 49)], p.outline)
    poly(draw, [(18, 29), (40, 26), (54, 46), (49, 49), (27, 52), (21, 48)], p.belt_base)
    poly(draw, [(18, 29), (22, 29), (28, 51), (27, 52), (21, 48)], p.belt_light)
    poly(draw, [(40, 26), (54, 46), (49, 49), (46, 47), (36, 27)], p.belt_dark)

    # Stable 1px transverse cadence. Alternating light/dark ribs survive 1x.
    poly(draw, [(21, 32), (41, 29), (42, 30), (22, 34)], p.belt_dark)
    poly(draw, [(22, 35), (43, 32), (44, 33), (23, 37)], p.belt_light)
    poly(draw, [(24, 38), (45, 35), (46, 36), (25, 40)], p.belt_dark)
    poly(draw, [(26, 42), (48, 39), (49, 40), (27, 44)], p.belt_light)
    poly(draw, [(28, 46), (50, 43), (51, 44), (29, 48)], p.belt_dark)
    poly(draw, [(30, 49), (51, 46), (52, 47), (31, 51)], p.belt_light)
    # Small clipped highlights reinforce travel direction without visual noise.
    rect(draw, (24, 35, 31, 35), p.body_light)
    rect(draw, (31, 42, 39, 42), p.body_light)
    rect(draw, (38, 48, 45, 48), p.body_light)

    # Front and rear roller caps are strong endpoints for the belt hierarchy.
    poly(draw, [(15, 27), (41, 24), (43, 27), (19, 31)], p.outline)
    poly(draw, [(19, 28), (39, 26), (40, 27), (20, 29)], p.metal_dark)
    rect(draw, (21, 28, 29, 28), p.metal_base)
    poly(draw, [(25, 52), (51, 49), (57, 51), (52, 55), (29, 57), (24, 55)], p.outline)
    poly(draw, [(29, 53), (50, 51), (54, 52), (50, 53), (30, 55), (27, 54)], p.cool_shadow)
    rect(draw, (31, 53, 43, 53), p.metal_dark)
    rect(draw, (32, 53, 39, 53), p.metal_base)


def draw_frame(draw: ImageDraw.ImageDraw, p: EquipmentPalette) -> None:
    """Draw separated uprights and rails with clean negative space."""
    poly(draw, [(12, 19), (17, 18), (24, 37), (22, 42), (19, 39)], p.outline)
    poly(draw, [(15, 20), (17, 20), (22, 36), (21, 38), (20, 36)], p.metal_dark)
    rect(draw, (15, 21, 15, 29), p.metal_base)
    rect(draw, (16, 21, 16, 25), p.warm_highlight)

    poly(draw, [(39, 17), (44, 17), (51, 36), (48, 42), (45, 38)], p.outline)
    poly(draw, [(41, 19), (43, 19), (49, 36), (47, 38), (46, 36)], p.metal_dark)
    rect(draw, (41, 20, 41, 27), p.metal_base)

    # Handrails use stepped facets, never semi-transparent antialias pixels.
    poly(draw, [(14, 19), (19, 20), (28, 35), (25, 40), (21, 36)], p.outline)
    poly(draw, [(16, 21), (18, 22), (26, 35), (24, 37), (23, 34)], p.metal_base)
    rect(draw, (17, 21, 18, 23), p.warm_highlight)
    rect(draw, (23, 31, 24, 33), p.warm_highlight)
    poly(draw, [(39, 18), (44, 18), (51, 33), (48, 39), (45, 35)], p.outline)
    poly(draw, [(41, 20), (43, 20), (49, 33), (47, 36), (46, 33)], p.metal_dark)
    rect(draw, (41, 20, 42, 22), p.metal_base)

    # Thick grip caps visually terminate both diagonals.
    poly(draw, [(22, 35), (27, 34), (29, 36), (26, 40), (22, 39)], p.outline)
    rect(draw, (24, 35, 27, 37), p.cool_shadow)
    rect(draw, (24, 35, 26, 35), p.metal_base)
    poly(draw, [(46, 33), (51, 32), (53, 34), (49, 39), (46, 37)], p.outline)
    rect(draw, (48, 33, 51, 35), p.deep_shadow)


def draw_console(draw: ImageDraw.ImageDraw, p: EquipmentPalette) -> None:
    """Draw the warm-lit console shell and cyan screen focal point."""
    poly(draw, [(25, 14), (31, 14), (32, 24), (28, 27), (25, 24)], p.outline)
    poly(draw, [(27, 16), (30, 16), (30, 24), (27, 24)], p.metal_dark)

    poly(draw, [(9, 10), (34, 7), (44, 12), (43, 17), (17, 21), (8, 16)], p.outline)
    poly(draw, [(12, 12), (33, 9), (41, 13), (39, 15), (18, 18), (11, 15)], p.body_base)
    poly(draw, [(12, 12), (33, 9), (36, 11), (17, 14), (12, 15)], p.cool_shadow)
    rect(draw, (15, 10, 27, 10), p.metal_dark)
    rect(draw, (17, 10, 24, 10), p.warm_highlight)

    poly(draw, [(16, 18), (42, 14), (44, 22), (39, 27), (19, 29), (14, 24)], p.outline)
    poly(draw, [(18, 20), (40, 17), (41, 21), (38, 24), (20, 27), (17, 23)], p.body_dark)
    poly(draw, [(38, 18), (40, 17), (41, 21), (38, 24), (36, 23)], p.deep_shadow)
    rect(draw, (20, 26, 28, 27), p.cool_shadow)

    poly(draw, [(20, 17), (34, 15), (38, 18), (35, 23), (22, 25), (18, 22)], p.screen_dark)
    poly(draw, [(22, 18), (33, 17), (36, 19), (34, 21), (23, 23), (20, 21)], p.screen_cyan)
    rect(draw, (23, 18, 30, 18), p.screen_glow)
    rect(draw, (22, 19, 24, 19), p.screen_glow)
    rect(draw, (31, 19, 34, 20), p.screen_mid)
    rect(draw, (25, 22, 28, 22), p.screen_dark)
    rect(draw, (18, 23, 19, 23), p.warm_highlight)
    rect(draw, (37, 20, 38, 21), p.metal_dark)
    rect(draw, (38, 20, 38, 20), p.screen_glow)
    rect(draw, (22, 25, 32, 25), p.metal_dark)
    rect(draw, (22, 25, 27, 25), p.warm_highlight)


def draw_finish(draw: ImageDraw.ImageDraw, p: EquipmentPalette) -> None:
    """Place sparse finish pixels at silhouette turns only."""
    rect(draw, (10, 16, 11, 17), p.metal_dark)
    rect(draw, (16, 27, 18, 27), p.warm_highlight)
    rect(draw, (19, 42, 20, 45), p.deep_shadow)
    rect(draw, (56, 46, 57, 48), p.outline)
    rect(draw, (28, 56, 32, 56), p.metal_base)
    rect(draw, (54, 53, 55, 54), p.cool_shadow)


def render_treadmill(palette: EquipmentPalette = DEFAULT_PALETTE) -> Image.Image:
    image = Image.new("RGBA", (SPRITE_SIZE, SPRITE_SIZE), TRANSPARENT)
    draw = ImageDraw.Draw(image)
    contact_shadow(draw, palette)
    draw_deck(draw, palette)
    draw_frame(draw, palette)
    draw_console(draw, palette)
    draw_finish(draw, palette)
    return image


def render_comparison(v2: Image.Image, v1_path: Path, p: EquipmentPalette) -> Image.Image:
    """Render a transparent-backed v2/v1 native-resolution review strip."""
    sheet = Image.new("RGBA", (148, 82), TRANSPARENT)
    draw = ImageDraw.Draw(sheet)
    # Opaque checker panels make alpha and silhouette edges inspectable.
    for panel_x in (4, 76):
        for y in range(14, 78, 8):
            for x in range(panel_x, panel_x + 68, 8):
                color = (38, 47, 58, 255) if ((x // 8 + y // 8) % 2) else (45, 55, 66, 255)
                rect(draw, (x, y, min(x + 7, panel_x + 67), min(y + 7, 77)), color)
    font = ImageFont.load_default()
    draw.text((6, 3), "V2 / CRISP", font=font, fill=p.warm_highlight)
    draw.text((80, 3), "V1 / PILOT", font=font, fill=p.metal_base)
    sheet.alpha_composite(v2, (6, 14))
    if v1_path.is_file():
        v1 = Image.open(v1_path).convert("RGBA")
        sheet.alpha_composite(v1, (78, 14))
    else:
        draw.text((91, 40), "NO V1", font=font, fill=p.metal_base)
    rect(draw, (73, 4, 74, 79), p.outline)
    rect(draw, (74, 15, 74, 77), p.cool_shadow)
    return sheet


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--compare", type=Path, default=DEFAULT_COMPARE)
    parser.add_argument("--v1", type=Path, default=DEFAULT_V1)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    sprite = render_treadmill()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    sprite.save(args.output, format="PNG", optimize=False)
    comparison = render_comparison(sprite, args.v1, DEFAULT_PALETTE)
    args.compare.parent.mkdir(parents=True, exist_ok=True)
    comparison.save(args.compare, format="PNG", optimize=False)
    print(f"wrote {args.output} ({sprite.width}x{sprite.height}, {sprite.mode})")
    print(f"wrote {args.compare} ({comparison.width}x{comparison.height}, {comparison.mode})")


if __name__ == "__main__":
    main()
