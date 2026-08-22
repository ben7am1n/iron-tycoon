#!/usr/bin/env python3
"""Hand-authored 64x64 treadmill sprite pilot.

The artwork is intentionally built at final resolution from hard-edged pixel
clusters.  No vector supersampling, antialiasing, blur, or procedural noise is
used: every silhouette break, highlight, and belt mark is placed deliberately.

Run from the repository root:
    python3 tools/sprite_design/treadmill_v1.py
"""

from __future__ import annotations

import argparse
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


# Compact material palette: warm light from upper-left, cool shade at lower-right.
TRANSPARENT = (0, 0, 0, 0)
CONTACT_SHADOW = (15, 24, 35, 104)
OUTLINE = (20, 29, 40, 255)
DEEP_SHADOW = (31, 43, 56, 255)
COOL_SHADOW = (48, 64, 78, 255)
BODY_DARK = (57, 68, 79, 255)
BODY_BASE = (76, 88, 98, 255)
BELT_DARK = (35, 43, 51, 255)
BELT_BASE = (48, 58, 66, 255)
BELT_RIDGE = (67, 80, 89, 255)
METAL_DARK = (91, 108, 119, 255)
METAL_BASE = (151, 166, 171, 255)
WARM_HIGHLIGHT = (225, 218, 194, 255)
SCREEN_DARK = (17, 58, 69, 255)
SCREEN_CYAN = (43, 210, 224, 255)
SCREEN_GLOW = (153, 248, 238, 255)

SPRITE_SIZE = 64
DEFAULT_OUTPUT = Path("assets/sprites/treadmill_v1.png")
DEFAULT_COMPARE = Path("assets/sprites/treadmill_compare.png")
DEFAULT_OLD_SOURCE = Path("tests/evidence/v31-r4-p2-sprite-treadmill.png")


def rect(draw: ImageDraw.ImageDraw, box: tuple[int, int, int, int], color: tuple[int, ...]) -> None:
    """Inclusive-coordinate rectangle shorthand."""
    draw.rectangle(box, fill=color)


def poly(draw: ImageDraw.ImageDraw, points: list[tuple[int, int]], color: tuple[int, ...]) -> None:
    draw.polygon(points, fill=color)


def draw_contact_shadow(draw: ImageDraw.ImageDraw) -> None:
    """A stepped translucent ellipse anchored slightly down-right."""
    rect(draw, (18, 52, 54, 59), CONTACT_SHADOW)
    rect(draw, (13, 54, 59, 57), CONTACT_SHADOW)
    rect(draw, (22, 50, 48, 60), CONTACT_SHADOW)
    # Feathered edge pixels without antialiasing.
    edge = (15, 24, 35, 58)
    rect(draw, (10, 55, 12, 56), edge)
    rect(draw, (60, 55, 61, 56), edge)
    rect(draw, (25, 61, 48, 61), edge)


def draw_base_and_deck(draw: ImageDraw.ImageDraw) -> None:
    """Grounded chassis, belt sidewall, rollers, and the inclined running deck."""
    # Feet and frame sit behind the deck but remain visible at the silhouette.
    rect(draw, (18, 49, 23, 56), OUTLINE)
    rect(draw, (19, 49, 24, 54), BODY_DARK)
    rect(draw, (18, 55, 27, 57), OUTLINE)
    rect(draw, (20, 54, 27, 55), METAL_DARK)

    rect(draw, (49, 50, 54, 57), OUTLINE)
    rect(draw, (49, 50, 53, 55), DEEP_SHADOW)
    rect(draw, (47, 56, 57, 58), OUTLINE)
    rect(draw, (48, 55, 56, 56), COOL_SHADOW)

    # Chassis side face: darkest on the right/lower side of the oblique form.
    poly(draw, [(15, 28), (43, 25), (59, 48), (56, 55), (26, 57), (20, 51)], OUTLINE)
    poly(draw, [(18, 31), (42, 28), (56, 48), (53, 52), (27, 54), (22, 49)], BODY_DARK)
    poly(draw, [(42, 28), (56, 48), (53, 52), (49, 49), (39, 31)], DEEP_SHADOW)
    # Small chassis glints describe the hard shell without tracing every edge.
    rect(draw, (22, 50, 27, 51), COOL_SHADOW)
    rect(draw, (28, 53, 40, 54), COOL_SHADOW)
    rect(draw, (50, 48, 54, 49), METAL_DARK)

    # Belt top plane: narrow at the console, wide and shifted right at the rear.
    poly(draw, [(17, 27), (41, 24), (55, 46), (50, 50), (25, 52), (20, 48)], OUTLINE)
    poly(draw, [(20, 29), (40, 27), (52, 46), (48, 48), (27, 50), (23, 47)], BELT_BASE)
    # Left-up light band and right-down cool falloff create a readable incline.
    poly(draw, [(20, 29), (23, 29), (31, 49), (27, 50), (23, 47)], BELT_RIDGE)
    poly(draw, [(40, 27), (52, 46), (48, 48), (45, 46), (36, 28)], BELT_DARK)

    # Transverse belt ridges follow the trapezoid and vary in length/spacing.
    poly(draw, [(23, 33), (40, 31), (41, 33), (24, 35)], BELT_DARK)
    poly(draw, [(25, 38), (44, 36), (46, 38), (26, 40)], BELT_RIDGE)
    poly(draw, [(28, 43), (47, 41), (49, 43), (29, 45)], BELT_DARK)
    poly(draw, [(31, 47), (49, 45), (50, 46), (32, 49)], BELT_RIDGE)
    # Break up the regularity with a few worn, one-pixel highlights.
    rect(draw, (23, 36, 25, 36), COOL_SHADOW)
    rect(draw, (38, 34, 41, 34), COOL_SHADOW)
    rect(draw, (33, 41, 36, 41), COOL_SHADOW)
    rect(draw, (43, 45, 46, 45), COOL_SHADOW)

    # Rear roller cap, deliberately asymmetric to avoid an icon-like frame.
    poly(draw, [(25, 50), (50, 48), (55, 50), (51, 54), (28, 56), (24, 54)], OUTLINE)
    poly(draw, [(28, 51), (49, 49), (52, 50), (49, 52), (29, 54), (26, 53)], COOL_SHADOW)
    rect(draw, (30, 52, 42, 52), METAL_DARK)
    rect(draw, (31, 52, 37, 52), METAL_BASE)
    rect(draw, (50, 50, 53, 51), DEEP_SHADOW)


def draw_uprights_and_handrails(draw: ImageDraw.ImageDraw) -> None:
    """Raised frame with open negative space above the belt."""
    # Rear-leaning support columns. Black under-pixels read as depth/occlusion.
    poly(draw, [(13, 19), (17, 18), (24, 37), (22, 42), (19, 39)], OUTLINE)
    poly(draw, [(15, 20), (17, 20), (22, 36), (21, 38), (20, 36)], METAL_DARK)
    rect(draw, (15, 21, 15, 28), METAL_BASE)
    rect(draw, (16, 21, 16, 24), WARM_HIGHLIGHT)

    poly(draw, [(39, 17), (43, 17), (50, 37), (48, 42), (45, 38)], OUTLINE)
    poly(draw, [(40, 19), (42, 19), (48, 36), (47, 38), (46, 36)], METAL_DARK)
    rect(draw, (40, 20, 40, 27), METAL_BASE)

    # Handrails: two chunky, slightly irregular strips instead of perfect lines.
    poly(draw, [(14, 20), (18, 20), (27, 35), (25, 39), (22, 36)], OUTLINE)
    poly(draw, [(16, 21), (18, 22), (25, 34), (24, 36), (23, 34)], METAL_BASE)
    rect(draw, (17, 21, 18, 23), WARM_HIGHLIGHT)
    rect(draw, (22, 30, 23, 32), WARM_HIGHLIGHT)

    poly(draw, [(38, 18), (43, 18), (50, 33), (48, 38), (45, 35)], OUTLINE)
    poly(draw, [(40, 20), (42, 20), (48, 33), (47, 35), (46, 33)], METAL_DARK)
    rect(draw, (40, 20, 41, 22), METAL_BASE)
    rect(draw, (46, 31, 47, 33), COOL_SHADOW)

    # Grip caps visually terminate the rails.
    poly(draw, [(22, 35), (26, 34), (28, 36), (25, 40), (22, 39)], OUTLINE)
    rect(draw, (24, 35, 26, 37), COOL_SHADOW)
    rect(draw, (24, 35, 25, 35), METAL_BASE)
    poly(draw, [(46, 33), (50, 32), (52, 34), (49, 38), (46, 37)], OUTLINE)
    rect(draw, (48, 33, 50, 35), DEEP_SHADOW)


def draw_console(draw: ImageDraw.ImageDraw) -> None:
    """Three-faced control console with a cyan emissive focal point."""
    # Stem hidden behind the control pod.
    poly(draw, [(25, 15), (30, 14), (31, 24), (28, 27), (25, 24)], OUTLINE)
    poly(draw, [(27, 16), (29, 16), (29, 24), (27, 24)], METAL_DARK)

    # Top plane catches the warm key light; right face stays cool and dark.
    poly(draw, [(10, 11), (34, 8), (43, 13), (42, 17), (17, 21), (9, 16)], OUTLINE)
    poly(draw, [(12, 12), (33, 10), (40, 13), (39, 15), (18, 18), (11, 15)], BODY_BASE)
    poly(draw, [(12, 12), (33, 10), (35, 11), (17, 14), (12, 15)], COOL_SHADOW)
    rect(draw, (15, 11, 26, 11), METAL_DARK)
    rect(draw, (16, 11, 23, 11), WARM_HIGHLIGHT)

    # Front face, deliberately stepped at both lower corners.
    poly(draw, [(17, 19), (42, 15), (43, 22), (39, 26), (19, 28), (15, 24)], OUTLINE)
    poly(draw, [(18, 20), (40, 17), (41, 21), (38, 24), (20, 26), (17, 23)], BODY_DARK)
    poly(draw, [(38, 18), (40, 17), (41, 21), (38, 24), (36, 23)], DEEP_SHADOW)
    rect(draw, (19, 25, 26, 26), COOL_SHADOW)

    # Screen and UI marks use tiny clusters, not readable text at this scale.
    poly(draw, [(21, 18), (34, 16), (37, 18), (35, 22), (22, 24), (19, 22)], SCREEN_DARK)
    poly(draw, [(22, 19), (33, 18), (35, 19), (34, 21), (23, 22), (21, 21)], SCREEN_CYAN)
    rect(draw, (23, 19, 29, 19), SCREEN_GLOW)
    rect(draw, (22, 20, 23, 20), SCREEN_GLOW)
    rect(draw, (31, 20, 33, 20), (29, 150, 171, 255))
    rect(draw, (25, 22, 27, 22), SCREEN_DARK)

    # Controls and a warm lip highlight balance the cyan display.
    rect(draw, (18, 23, 19, 23), WARM_HIGHLIGHT)
    rect(draw, (37, 20, 38, 21), METAL_DARK)
    rect(draw, (38, 20, 38, 20), SCREEN_GLOW)
    rect(draw, (22, 25, 31, 25), METAL_DARK)
    rect(draw, (22, 25, 26, 25), WARM_HIGHLIGHT)


def draw_finish_pixels(draw: ImageDraw.ImageDraw) -> None:
    """Sparse material chips that keep the silhouette hand-authored."""
    rect(draw, (11, 16, 11, 17), METAL_DARK)
    rect(draw, (16, 27, 17, 27), WARM_HIGHLIGHT)
    rect(draw, (20, 42, 20, 44), DEEP_SHADOW)
    rect(draw, (55, 47, 56, 48), OUTLINE)
    rect(draw, (27, 56, 30, 56), METAL_BASE)
    rect(draw, (54, 53, 54, 54), COOL_SHADOW)


def render_treadmill() -> Image.Image:
    image = Image.new("RGBA", (SPRITE_SIZE, SPRITE_SIZE), TRANSPARENT)
    draw = ImageDraw.Draw(image)
    draw_contact_shadow(draw)
    draw_base_and_deck(draw)
    draw_uprights_and_handrails(draw)
    draw_console(draw)
    draw_finish_pixels(draw)
    return image


def pixel_font() -> ImageFont.ImageFont:
    # Pillow's built-in bitmap font keeps the comparison artifact self-contained.
    return ImageFont.load_default()


def fitted_old_sprite(path: Path, max_size: tuple[int, int] = (60, 60)) -> Image.Image | None:
    if not path.is_file():
        return None
    old = Image.open(path).convert("RGBA")
    alpha_box = old.getchannel("A").getbbox()
    if alpha_box:
        old = old.crop(alpha_box)
    old.thumbnail(max_size, Image.Resampling.NEAREST)
    return old


def render_comparison(new_sprite: Image.Image, old_source: Path) -> Image.Image:
    """Create a compact checker-backed NEW/OLD review sheet."""
    width, height = 152, 82
    sheet = Image.new("RGBA", (width, height), (25, 32, 41, 255))
    draw = ImageDraw.Draw(sheet)
    checker_a = (38, 47, 58, 255)
    checker_b = (45, 55, 66, 255)
    for x0, x1 in ((5, 73), (79, 147)):
        for y in range(14, 78, 8):
            for x in range(x0, x1, 8):
                draw.rectangle((x, y, min(x + 7, x1 - 1), min(y + 7, 77)),
                               fill=checker_a if ((x // 8 + y // 8) % 2) else checker_b)

    draw.text((7, 3), "NEW / PIL", font=pixel_font(), fill=WARM_HIGHLIGHT)
    draw.text((84, 3), "OLD / CODE", font=pixel_font(), fill=METAL_BASE)
    sheet.alpha_composite(new_sprite, (7, 14))

    old = fitted_old_sprite(old_source)
    if old is None:
        draw.text((91, 41), "NO OLD\nSOURCE", font=pixel_font(), fill=METAL_BASE)
    else:
        ox = 79 + (68 - old.width) // 2
        oy = 16 + (60 - old.height) // 2
        sheet.alpha_composite(old, (ox, oy))

    rect(draw, (75, 3, 76, 79), OUTLINE)
    rect(draw, (76, 15, 76, 77), COOL_SHADOW)
    return sheet


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT,
                        help="64x64 RGBA sprite path")
    parser.add_argument("--compare", type=Path, default=DEFAULT_COMPARE,
                        help="NEW/OLD comparison sheet path")
    parser.add_argument("--old-source", type=Path, default=DEFAULT_OLD_SOURCE,
                        help="existing old program-art PNG used in comparison")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    sprite = render_treadmill()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    sprite.save(args.output, format="PNG", optimize=False)

    comparison = render_comparison(sprite, args.old_source)
    args.compare.parent.mkdir(parents=True, exist_ok=True)
    comparison.save(args.compare, format="PNG", optimize=False)
    print(f"wrote {args.output} ({sprite.width}x{sprite.height}, {sprite.mode})")
    print(f"wrote {args.compare} ({comparison.width}x{comparison.height}, {comparison.mode})")


if __name__ == "__main__":
    main()
