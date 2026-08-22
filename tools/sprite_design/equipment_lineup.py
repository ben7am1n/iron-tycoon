#!/usr/bin/env python3
"""Compose the four equipment renderers into a transparent review lineup."""

from __future__ import annotations

import argparse
from pathlib import Path

from PIL import Image

from bench_v1 import render_bench
from bike_v1 import render_bike
from mat_v1 import render_mat
from treadmill_v2 import TRANSPARENT, render_treadmill


DEFAULT_OUTPUT = Path("assets/sprites/equipment_lineup.png")


def render_lineup() -> Image.Image:
    sprites = (render_treadmill(), render_bike(), render_bench(), render_mat())
    # Four native-size cells, no resampling and a genuinely transparent canvas.
    lineup = Image.new("RGBA", (64 * len(sprites), 64), TRANSPARENT)
    for index, sprite in enumerate(sprites):
        lineup.alpha_composite(sprite, (index * 64, 0))
    return lineup


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()
    lineup = render_lineup()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    lineup.save(args.output, format="PNG", optimize=False)
    print(f"wrote {args.output} ({lineup.width}x{lineup.height}, {lineup.mode})")


if __name__ == "__main__":
    main()
