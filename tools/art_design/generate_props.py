#!/usr/bin/env python3
"""Generate pixel art environment and prop sprites for Gym Adventure.

Props:
1. sign_neon_lin.png (48x20): Master Lin's retro illuminated neon sign with cyan/gold glow.
2. front_desk.png (48x24): Reception counter with wood grain, banker's lamp, clipboard.
3. water_towel_station.png (24x32): Water cooler with inverted cyan jug & stacked gym towels.
4. dumbbell_rack.png (32x24): Two-tier matte-black steel rack with graduated hex dumbbells.

Follows Cozy Pixel, nearest-neighbor integer scaling specifications.
"""

from __future__ import annotations

import os
from pathlib import Path
from PIL import Image, ImageDraw

Color = tuple[int, int, int, int]
TRANSPARENT: Color = (0, 0, 0, 0)
OUTPUT_DIR = Path("assets/sprites/props")


def hex_to_rgba(hex_code: str, alpha: int = 255) -> Color:
    """Convert hex string (e.g. '#2E7D6B') to RGBA tuple."""
    hex_code = hex_code.lstrip("#")
    r = int(hex_code[0:2], 16)
    g = int(hex_code[2:4], 16)
    b = int(hex_code[4:6], 16)
    return (r, g, b, alpha)


def generate_sign_neon_lin() -> Image.Image:
    """Master Lin's retro neon sign (48x20)."""
    img = Image.new("RGBA", (48, 20), TRANSPARENT)
    draw = ImageDraw.Draw(img)

    # Frame & Backing (Dark industrial metal)
    c_metal_dark = hex_to_rgba("#111827")
    c_metal_mid = hex_to_rgba("#1F2937")
    c_metal_light = hex_to_rgba("#374151")
    c_screw = hex_to_rgba("#94A3B8")
    
    # Outer neon border (Vibrant Cyan / Teal)
    c_cyan_glow_far = hex_to_rgba("#06B6D4", 45)
    c_cyan_glow_near = hex_to_rgba("#22EEFF", 120)
    c_cyan_tube = hex_to_rgba("#38BDF8")
    c_cyan_core = hex_to_rgba("#E0F2FE")
    
    # Inner neon motif & letters (Warm Gold / Amber)
    c_gold_glow_far = hex_to_rgba("#F59E0B", 45)
    c_gold_glow_near = hex_to_rgba("#FBBF24", 120)
    c_gold_tube = hex_to_rgba("#FCD34D")
    c_gold_core = hex_to_rgba("#FFFBEB")

    # 1. Dark Metal Backplate
    draw.rectangle([2, 1, 45, 18], fill=c_metal_dark)
    draw.rectangle([3, 2, 44, 17], fill=c_metal_mid)
    # Bevel edge
    draw.line([(3, 2), (44, 2)], fill=c_metal_light)
    draw.line([(3, 2), (3, 17)], fill=c_metal_light)
    # Corner mounting screws
    for sx, sy in [(4, 3), (43, 3), (4, 16), (43, 16)]:
        draw.point([(sx, sy)], fill=c_screw)

    # 2. Outer Cyan Neon Tube Border
    # Far glow
    draw.rectangle([5, 3, 42, 15], outline=c_cyan_glow_far, width=2)
    # Near glow
    draw.rectangle([6, 4, 41, 14], outline=c_cyan_glow_near, width=1)
    # Tube line & hot core
    draw.rectangle([6, 4, 41, 14], outline=c_cyan_tube, width=1)
    draw.line([(7, 4), (40, 4)], fill=c_cyan_core)
    draw.line([(7, 14), (40, 14)], fill=c_cyan_core)
    draw.line([(6, 5), (6, 13)], fill=c_cyan_core)
    draw.line([(41, 5), (41, 13)], fill=c_cyan_core)

    # 3. Inner Stylized Barbell / Dumbbell Neon Graphic (Center-Left)
    # Barbell left weight plate
    draw.rectangle([10, 7, 12, 11], outline=c_gold_glow_near, fill=c_gold_tube)
    draw.point([(11, 8), (11, 9), (11, 10)], fill=c_gold_core)
    # Barbell bar
    draw.line([(12, 9), (20, 9)], fill=c_gold_glow_far, width=2)
    draw.line([(13, 9), (19, 9)], fill=c_gold_tube, width=1)
    draw.point([(15, 9), (16, 9), (17, 9)], fill=c_gold_core)
    # Barbell right weight plate
    draw.rectangle([20, 7, 22, 11], outline=c_gold_glow_near, fill=c_gold_tube)
    draw.point([(21, 8), (21, 9), (21, 10)], fill=c_gold_core)

    # 4. Retro Neon Lettering "GYM" / "铁" (Center-Right)
    # Letter G (x: 25-28)
    draw.line([(25, 7), (28, 7)], fill=c_gold_tube)
    draw.line([(25, 7), (25, 11)], fill=c_gold_tube)
    draw.line([(25, 11), (28, 11)], fill=c_gold_tube)
    draw.line([(28, 9), (28, 11)], fill=c_gold_tube)
    draw.point([(27, 9)], fill=c_gold_tube)
    draw.point([(26, 7), (25, 8), (25, 10), (27, 11)], fill=c_gold_core)

    # Letter Y (x: 30-33)
    draw.line([(30, 7), (31, 9)], fill=c_gold_tube)
    draw.line([(33, 7), (32, 9)], fill=c_gold_tube)
    draw.line([(31, 9), (32, 9)], fill=c_gold_tube)
    draw.line([(31, 9), (31, 11)], fill=c_gold_tube)
    draw.point([(30, 7), (33, 7), (31, 10)], fill=c_gold_core)

    # Letter M (x: 35-39)
    draw.line([(35, 7), (35, 11)], fill=c_gold_tube)
    draw.line([(39, 7), (39, 11)], fill=c_gold_tube)
    draw.point([(36, 8), (37, 9), (38, 8)], fill=c_gold_tube)
    draw.point([(35, 8), (35, 9), (39, 8), (39, 9), (37, 9)], fill=c_gold_core)

    return img


def generate_front_desk() -> Image.Image:
    """Reception Water Bar & Front Desk (48x24)."""
    img = Image.new("RGBA", (48, 24), TRANSPARENT)
    draw = ImageDraw.Draw(img)

    # Colors
    c_shadow = hex_to_rgba("#1F2421", 100)
    c_wood_top = hex_to_rgba("#E5B889")
    c_wood_base = hex_to_rgba("#D4A373")
    c_wood_shadow = hex_to_rgba("#B07D4F")
    c_wood_grain = hex_to_rgba("#9C683B")
    
    c_steel_body = hex_to_rgba("#374151")
    c_steel_dark = hex_to_rgba("#1F2937")
    c_steel_edge = hex_to_rgba("#4B5563")
    c_brass_trim = hex_to_rgba("#F59E0B")
    c_brass_hi = hex_to_rgba("#FDE68A")
    
    # Banker's lamp (Emerald green + brass)
    c_lamp_shade = hex_to_rgba("#10B981")
    c_lamp_shade_hi = hex_to_rgba("#34D399")
    c_lamp_glow = hex_to_rgba("#FEF08A", 160)
    c_lamp_brass = hex_to_rgba("#D97706")
    
    # Sign-in clipboard & pen
    c_clipboard = hex_to_rgba("#92400E")
    c_paper = hex_to_rgba("#F8FAFC")
    c_pen = hex_to_rgba("#3B82F6")

    # 1. Ground Contact Shadow
    draw.ellipse([4, 21, 46, 23], fill=c_shadow)

    # 2. Main Desk Body (Steel front panel)
    draw.rectangle([6, 8, 44, 21], fill=c_steel_dark)
    draw.rectangle([7, 9, 43, 20], fill=c_steel_body)
    # Vertical panel slat lines
    for px in [14, 22, 30, 38]:
        draw.line([(px, 9), (px, 20)], fill=c_steel_dark)
        draw.line([(px + 1, 9), (px + 1, 20)], fill=c_steel_edge)
    
    # Brass base kickplate
    draw.rectangle([6, 20, 44, 21], fill=c_brass_trim)
    draw.line([(7, 20), (43, 20)], fill=c_brass_hi)

    # 3. Wood Countertop (Thick beveled top surface)
    # Perspective top edge
    draw.polygon([(4, 5), (46, 5), (45, 8), (5, 8)], fill=c_wood_top)
    draw.line([(4, 5), (46, 5)], fill=hex_to_rgba("#FDE8CD"))
    # Wood grain lines
    draw.line([(8, 6), (20, 6)], fill=c_wood_grain)
    draw.line([(26, 6), (40, 6)], fill=c_wood_grain)
    draw.line([(12, 7), (32, 7)], fill=c_wood_shadow)
    # Countertop front edge rim
    draw.rectangle([4, 8, 46, 9], fill=c_wood_base)
    draw.line([(5, 9), (45, 9)], fill=c_wood_shadow)

    # 4. Banker's Desk Lamp (Right side)
    # Warm desk illumination glow
    draw.ellipse([31, 5, 41, 10], fill=c_lamp_glow)
    # Lamp brass stem & round base
    draw.line([(36, 6), (36, 8)], fill=c_lamp_brass, width=1)
    draw.point([(35, 8), (36, 8), (37, 8)], fill=c_lamp_brass)
    # Emerald green curved glass shade
    draw.polygon([(33, 4), (39, 4), (40, 6), (32, 6)], fill=c_lamp_shade)
    draw.line([(34, 4), (38, 4)], fill=c_lamp_shade_hi)
    draw.line([(33, 6), (39, 6)], fill=hex_to_rgba("#FEF08A"))

    # 5. Sign-in Clipboard & Pen (Left side)
    # Clipboard wood
    draw.polygon([(10, 4), (16, 4), (17, 8), (11, 8)], fill=c_clipboard)
    # White paper sheet
    draw.polygon([(11, 5), (15, 5), (16, 7), (12, 7)], fill=c_paper)
    # Paper text lines
    draw.line([(12, 6), (14, 6)], fill=hex_to_rgba("#64748B"))
    # Silver clip
    draw.point([(13, 4)], fill=hex_to_rgba("#E2E8F0"))
    # Blue ballpoint pen lying next to clipboard
    draw.line([(18, 5), (19, 7)], fill=c_pen)

    return img


def generate_water_towel_station() -> Image.Image:
    """Gym Water Cooler & Clean Towel Station (24x32)."""
    img = Image.new("RGBA", (24, 32), TRANSPARENT)
    draw = ImageDraw.Draw(img)

    # Colors
    c_shadow = hex_to_rgba("#1F2421", 100)
    c_steel = hex_to_rgba("#E2E8F0")
    c_steel_mid = hex_to_rgba("#94A3B8")
    c_steel_dark = hex_to_rgba("#475569")
    c_steel_frame = hex_to_rgba("#334155")
    
    # Inverted Water Jug
    c_jug_body = hex_to_rgba("#38BDF8")
    c_jug_deep = hex_to_rgba("#0284C7")
    c_jug_hi = hex_to_rgba("#BAE6FD")
    c_jug_cap = hex_to_rgba("#0369A1")
    
    # Faucets
    c_hot = hex_to_rgba("#EF4444")
    c_cold = hex_to_rgba("#3B82F6")
    
    # Towels
    c_towel_top = hex_to_rgba("#FFFFFF")
    c_towel_body = hex_to_rgba("#F1F5F9")
    c_towel_shadow = hex_to_rgba("#CBD5E1")
    c_towel_dark = hex_to_rgba("#94A3B8")
    
    # Bottom hamper
    c_hamper = hex_to_rgba("#334155")
    c_hamper_rim = hex_to_rgba("#64748B")

    # 1. Floor Shadow
    draw.ellipse([3, 29, 21, 31], fill=c_shadow)

    # 2. Outer Steel Frame (Rack legs & shelves)
    draw.line([(4, 12), (4, 30)], fill=c_steel_frame, width=1)
    draw.line([(19, 12), (19, 30)], fill=c_steel_frame, width=1)
    # Shelf 1 (Towel shelf)
    draw.line([(4, 18), (19, 18)], fill=c_steel_mid, width=1)
    # Shelf 2 (Hamper shelf)
    draw.line([(4, 29), (19, 29)], fill=c_steel_mid, width=1)

    # 3. Top Water Dispenser Body & Inverted 5-Gallon Bottle
    # Inverted bottle neck & body
    draw.rectangle([7, 3, 16, 10], fill=c_jug_body)
    draw.rectangle([8, 1, 15, 2], fill=c_jug_body)
    draw.line([(8, 3), (8, 9)], fill=c_jug_hi)
    draw.line([(15, 3), (15, 9)], fill=c_jug_deep)
    # Air water level line
    draw.line([(9, 3), (14, 3)], fill=c_jug_hi)
    # Bottle neck ring
    draw.rectangle([9, 10, 14, 11], fill=c_jug_cap)

    # Dispenser unit housing (White/metallic)
    draw.rectangle([5, 11, 18, 17], fill=c_steel)
    draw.line([(5, 11), (18, 11)], fill=hex_to_rgba("#FFFFFF"))
    draw.line([(18, 11), (18, 17)], fill=c_steel_mid)
    
    # Dispensing recess cavity
    draw.rectangle([7, 13, 16, 16], fill=c_steel_dark)
    # Hot & Cold taps
    draw.point([(9, 13)], fill=c_hot)
    draw.point([(14, 13)], fill=c_cold)
    # Drip tray
    draw.line([(7, 16), (16, 16)], fill=c_steel_mid)

    # 4. Middle Shelf: Stack of Clean White Gym Towels
    # Towel 1 (bottom of stack)
    draw.rectangle([6, 20, 17, 21], fill=c_towel_shadow)
    draw.line([(6, 20), (17, 20)], fill=c_towel_body)
    # Towel 2 (middle of stack)
    draw.rectangle([6, 18, 17, 19], fill=c_towel_shadow)
    draw.line([(6, 18), (17, 18)], fill=c_towel_top)
    # Towel edges
    draw.point([(6, 19), (6, 21), (17, 19), (17, 21)], fill=c_towel_dark)

    # 5. Bottom Hamper / Towel Recycling Bin
    draw.rectangle([6, 23, 17, 28], fill=c_hamper)
    draw.line([(5, 23), (18, 23)], fill=c_hamper_rim)
    # Used towel peeking over rim
    draw.polygon([(8, 22), (12, 22), (11, 24), (7, 24)], fill=c_towel_body)

    return img


def generate_dumbbell_rack() -> Image.Image:
    """Two-tier Heavy Matte-Black Steel Dumbbell Rack (32x24)."""
    img = Image.new("RGBA", (32, 24), TRANSPARENT)
    draw = ImageDraw.Draw(img)

    # Colors
    c_shadow = hex_to_rgba("#1F2421", 100)
    c_frame_dark = hex_to_rgba("#111827")
    c_frame_mid = hex_to_rgba("#1F2937")
    c_frame_hi = hex_to_rgba("#374151")
    
    # Chrome knurled handles
    c_chrome = hex_to_rgba("#E2E8F0")
    c_chrome_shadow = hex_to_rgba("#94A3B8")
    
    # Dumbbell hex heads
    c_hex_dark = hex_to_rgba("#18181B")
    c_hex_mid = hex_to_rgba("#27272A")
    c_hex_hi = hex_to_rgba("#3F3F46")
    c_hex_stamp = hex_to_rgba("#CBD5E1")

    # 1. Floor Contact Shadow
    draw.ellipse([3, 21, 29, 23], fill=c_shadow)

    # 2. Steel Rack Frame
    # A-frame legs
    draw.polygon([(4, 6), (6, 6), (3, 22), (1, 22)], fill=c_frame_dark)
    draw.polygon([(26, 6), (28, 6), (31, 22), (29, 22)], fill=c_frame_dark)
    draw.line([(5, 6), (2, 22)], fill=c_frame_hi)
    draw.line([(27, 6), (30, 22)], fill=c_frame_hi)
    
    # Upper angled shelf rail
    draw.rectangle([4, 6, 28, 8], fill=c_frame_dark)
    draw.line([(4, 6), (28, 6)], fill=c_frame_hi)
    
    # Lower angled shelf rail
    draw.rectangle([2, 14, 30, 16], fill=c_frame_dark)
    draw.line([(2, 14), (30, 14)], fill=c_frame_hi)

    # 3. Top Tier Dumbbells (4 pairs: lighter weights)
    # Dumbbell positions: x = 6, 12, 18, 24
    for dx in [6, 12, 18, 24]:
        # Left hex head
        draw.rectangle([dx, 4, dx + 2, 9], fill=c_hex_dark)
        draw.point([(dx + 1, 5)], fill=c_hex_hi)
        # Chrome handle
        draw.line([(dx + 2, 6), (dx + 4, 6)], fill=c_chrome)
        # Right hex head
        draw.rectangle([dx + 4, 4, dx + 6, 9], fill=c_hex_dark)
        draw.point([(dx + 5, 5)], fill=c_hex_hi)

    # 4. Bottom Tier Dumbbells (3 pairs: heavy weights)
    # Dumbbell positions: x = 4, 13, 22
    for dx in [4, 13, 22]:
        # Left large hex head
        draw.polygon([(dx, 13), (dx + 3, 11), (dx + 3, 18), (dx, 17)], fill=c_hex_dark)
        draw.line([(dx + 1, 13), (dx + 2, 12)], fill=c_hex_hi)
        draw.point([(dx + 1, 15)], fill=c_hex_stamp) # Weight stamp dot
        # Center thick knurled handle
        draw.line([(dx + 3, 14), (dx + 6, 14)], fill=c_chrome, width=1)
        draw.line([(dx + 3, 15), (dx + 6, 15)], fill=c_chrome_shadow, width=1)
        # Right large hex head
        draw.polygon([(dx + 6, 11), (dx + 9, 13), (dx + 9, 17), (dx + 6, 18)], fill=c_hex_dark)
        draw.line([(dx + 7, 12), (dx + 8, 13)], fill=c_hex_hi)
        draw.point([(dx + 8, 15)], fill=c_hex_stamp)

    return img


def main() -> None:
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    props = {
        "sign_neon_lin.png": generate_sign_neon_lin(),
        "front_desk.png": generate_front_desk(),
        "water_towel_station.png": generate_water_towel_station(),
        "dumbbell_rack.png": generate_dumbbell_rack(),
    }

    for name, img in props.items():
        out_path = OUTPUT_DIR / name
        img.save(out_path, format="PNG")
        print(f"Generated {out_path} ({img.width}x{img.height})")


if __name__ == "__main__":
    main()
