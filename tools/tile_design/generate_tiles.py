#!/usr/bin/env python3
"""Render the clean 32x32 floor and wall tile suite for 撸铁大亨.

The tiles are intentionally restrained: one dominant material color, structural
lines only where they explain the surface, and at most two tiny wear accents.
Every tile is hard-edged RGBA pixel art and stays below the 15% detail budget.

Run from the repository root:
    python3 tools/tile_design/generate_tiles.py
"""

from __future__ import annotations

from collections import Counter
from pathlib import Path

from PIL import Image, ImageDraw


Color = tuple[int, int, int, int]
SIZE = 32
OUTPUT_DIR = Path("assets/tiles")


def canvas(color: Color) -> tuple[Image.Image, ImageDraw.ImageDraw]:
    image = Image.new("RGBA", (SIZE, SIZE), color)
    return image, ImageDraw.Draw(image)


def floor_strength() -> Image.Image:
    image, draw = canvas((68, 73, 81, 255))
    seam = (59, 64, 72, 255)
    wear = (76, 80, 87, 255)
    # One shared top/left edge becomes a single-pixel mat seam when repeated.
    draw.line((0, 0, 31, 0), fill=seam)
    draw.line((0, 1, 0, 31), fill=seam)
    # Two tiny deliberate scuffs: readable only at close range.
    draw.line((11, 9, 14, 9), fill=wear)
    draw.line((23, 24, 25, 24), fill=wear)
    return image


def floor_cardio() -> Image.Image:
    image, draw = canvas((132, 119, 103, 255))
    quiet_light = (136, 123, 107, 255)
    quiet_dark = (127, 114, 99, 255)
    # Seamless sheet flooring: only two short manufacturing marks.
    draw.line((7, 11, 10, 11), fill=quiet_light)
    draw.line((24, 26, 27, 26), fill=quiet_dark)
    return image


def floor_flex() -> Image.Image:
    image, draw = canvas((139, 94, 61, 255))
    seam = (117, 75, 46, 255)
    grain = (151, 103, 67, 255)
    # Two long planks per tile. End joints stagger by half a tile.
    draw.line((0, 0, 31, 0), fill=seam)
    draw.line((0, 16, 31, 16), fill=seam)
    draw.line((0, 1, 0, 15), fill=seam)
    draw.line((16, 17, 16, 31), fill=seam)
    # One short grain dash per board, aligned with the plank direction.
    draw.line((8, 7, 12, 7), fill=grain)
    draw.line((22, 24, 26, 24), fill=grain)
    return image


def floor_walkway() -> Image.Image:
    image, draw = canvas((178, 174, 164, 255))
    grout = (154, 151, 143, 255)
    # Regular, clean ceramic grout. No chips, stains, or color noise.
    draw.line((0, 0, 31, 0), fill=grout)
    draw.line((0, 1, 0, 31), fill=grout)
    return image


def wall_north() -> Image.Image:
    image, draw = canvas((122, 113, 111, 255))
    baseboard_hi = (111, 101, 94, 255)
    baseboard = (87, 78, 71, 255)
    # A quiet face and a crisp two-tone kickboard at the bottom.
    draw.line((0, 30, 31, 30), fill=baseboard_hi)
    draw.line((0, 31, 31, 31), fill=baseboard)
    return image


def wall_side() -> Image.Image:
    image, draw = canvas((112, 107, 108, 255))
    baseboard_hi = (101, 94, 91, 255)
    baseboard = (77, 72, 70, 255)
    draw.line((0, 30, 31, 30), fill=baseboard_hi)
    draw.line((0, 31, 31, 31), fill=baseboard)
    return image


TILES = {
    "floor_strength.png": floor_strength,
    "floor_cardio.png": floor_cardio,
    "floor_flex.png": floor_flex,
    "floor_walkway.png": floor_walkway,
    "wall_north.png": wall_north,
    "wall_side.png": wall_side,
}


def detail_ratio(image: Image.Image) -> float:
    counts = Counter(image.getdata())
    dominant = counts.most_common(1)[0][1]
    return 1.0 - dominant / float(SIZE * SIZE)


def main() -> None:
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    for filename, renderer in TILES.items():
        image = renderer()
        ratio = detail_ratio(image)
        if ratio > 0.15:
            raise ValueError(f"{filename}: detail ratio {ratio:.1%} exceeds 15%")
        output = OUTPUT_DIR / filename
        image.save(output, optimize=False)
        print(f"{output}: {image.size[0]}x{image.size[1]}, detail={ratio:.1%}")


if __name__ == "__main__":
    main()
