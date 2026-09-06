#!/usr/bin/env python3
"""Generate 48x48 pixel art portraits for Gym Adventure characters.

Characters:
1. 程教练 (Coach Cheng) - Steady mentor, broad jaw, teal collar, black hair with silver temple streak.
2. 阿洛 (Singer Aluo) - Energetic indie singer, brick-red hoodie, wavy hair, ear-hook earpiece.
3. 老邱 (Boxer Qiu) - Veteran boxer, weathered square jaw, stubble, deep wine tank top, towel over shoulder.
4. 林师傅 (Mechanic Lin) - Warm veteran craftsman, yellow hardhat, goggles on forehead, cobalt overalls, sweat towel.

Follows the art bible visual constraints: Cozy Pixel, 48x48 RGBA, Nearest-filter friendly.
"""

from __future__ import annotations

import os
from pathlib import Path
from PIL import Image, ImageDraw

Color = tuple[int, int, int, int]
TRANSPARENT: Color = (0, 0, 0, 0)
PORTRAIT_SIZE = 48

OUTPUT_DIR = Path("assets/sprites/portraits")


def hex_to_rgba(hex_code: str, alpha: int = 255) -> Color:
    """Convert hex string (e.g. '#2E7D6B') to RGBA tuple."""
    hex_code = hex_code.lstrip("#")
    r = int(hex_code[0:2], 16)
    g = int(hex_code[2:4], 16)
    b = int(hex_code[4:6], 16)
    return (r, g, b, alpha)


def draw_circular_badge(draw: ImageDraw.ImageDraw, cx: int, cy: int, radius: int,
                        bg_color: Color, border_color: Color, shadow_color: Color) -> None:
    """Draw a cozy circular badge backdrop for the portrait."""
    # Subtle drop shadow
    draw.ellipse([cx - radius, cy - radius + 2, cx + radius, cy + radius + 2], fill=shadow_color)
    # Border
    draw.ellipse([cx - radius, cy - radius, cx + radius, cy + radius], fill=border_color)
    # Inner background
    draw.ellipse([cx - radius + 2, cy - radius + 2, cx + radius - 2, cy + radius - 2], fill=bg_color)


def generate_cheng() -> Image.Image:
    """Coach Cheng (程教练) portrait: 48x48."""
    img = Image.new("RGBA", (PORTRAIT_SIZE, PORTRAIT_SIZE), TRANSPARENT)
    draw = ImageDraw.Draw(img)

    # Colors
    c_frame = hex_to_rgba("#2B2A2F")
    c_bg = hex_to_rgba("#E8F1EC")       # Subtle cool sage cream
    c_bg_shadow = hex_to_rgba("#1F2421", 80)
    c_outline = hex_to_rgba("#221D24")
    
    # Skin tones
    c_skin_base = hex_to_rgba("#F6D2B2")
    c_skin_shadow = hex_to_rgba("#DFAB8B")
    c_skin_dark = hex_to_rgba("#BA7E62")
    
    # Hair
    c_hair = hex_to_rgba("#1E1A22")
    c_hair_mid = hex_to_rgba("#352F3B")
    c_hair_silver = hex_to_rgba("#F1F5F9")
    c_hair_silver_mid = hex_to_rgba("#CBD5E1")
    
    # Clothes (Teal jacket & dark vest)
    c_jacket = hex_to_rgba("#2E7D6B")
    c_jacket_light = hex_to_rgba("#439E88")
    c_jacket_shadow = hex_to_rgba("#1C5246")
    c_vest = hex_to_rgba("#262E35")
    c_vest_light = hex_to_rgba("#38424B")
    c_zipper = hex_to_rgba("#E2E8F0")

    # 1. Circular Badge Frame
    draw_circular_badge(draw, 24, 24, 22, c_bg, c_frame, c_bg_shadow)

    # 2. Shoulders & Torso (Teal athletic jacket + dark inner shirt)
    draw.polygon([(10, 48), (14, 37), (18, 33), (30, 33), (34, 37), (38, 48)], fill=c_outline)
    draw.polygon([(11, 47), (15, 38), (19, 34), (29, 34), (33, 38), (37, 47)], fill=c_jacket)
    
    # Shading and highlights on jacket
    draw.rectangle([11, 40, 15, 47], fill=c_jacket_light)
    draw.rectangle([33, 40, 36, 47], fill=c_jacket_shadow)
    
    # Inner dark vest
    draw.polygon([(20, 37), (24, 43), (28, 37)], fill=c_vest)
    draw.line([(24, 39), (24, 47)], fill=c_zipper, width=1)
    
    # Neck
    draw.rectangle([21, 29, 27, 35], fill=c_skin_shadow)
    draw.rectangle([22, 29, 26, 33], fill=c_skin_base)

    # 3. Head & Jaw (Broad, square, athletic jawline)
    draw.rectangle([15, 14, 33, 29], fill=c_outline)
    draw.rectangle([16, 15, 32, 28], fill=c_skin_base)
    draw.point([(15, 28), (15, 29), (33, 28), (33, 29)], fill=c_frame)
    draw.rectangle([16, 26, 32, 28], fill=c_skin_base)
    draw.line([(16, 28), (32, 28)], fill=c_skin_shadow)
    draw.rectangle([22, 27, 26, 28], fill=c_skin_base)
    draw.line([(16, 21), (16, 27)], fill=c_skin_shadow)
    draw.line([(32, 21), (32, 27)], fill=c_skin_dark)

    # Ears
    draw.rectangle([14, 20, 15, 24], fill=c_skin_shadow)
    draw.rectangle([33, 20, 34, 24], fill=c_skin_dark)

    # 4. Facial Features (Calm, confident, focused)
    draw.line([(18, 18), (22, 18)], fill=c_hair, width=1)
    draw.line([(26, 18), (30, 18)], fill=c_hair, width=1)
    draw.point([(19, 20), (20, 20), (21, 20)], fill=c_outline)
    draw.point([(27, 20), (28, 20), (29, 20)], fill=c_outline)
    draw.point([(20, 20)], fill=hex_to_rgba("#FFFFFF"))
    draw.point([(28, 20)], fill=hex_to_rgba("#FFFFFF"))
    draw.line([(24, 20), (24, 23)], fill=c_skin_shadow)
    draw.point([(23, 23), (24, 23)], fill=c_skin_dark)
    draw.line([(22, 26), (26, 26)], fill=c_skin_dark)
    draw.point([(24, 26)], fill=hex_to_rgba("#9C5F4B"))

    # 5. Hair & Signature Silver Streak
    draw.polygon([(14, 15), (17, 9), (27, 8), (33, 10), (35, 16), (34, 20), (14, 20)], fill=c_outline)
    draw.polygon([(15, 14), (18, 10), (26, 9), (32, 11), (34, 15), (33, 18), (15, 18)], fill=c_hair)
    draw.rectangle([18, 11, 25, 14], fill=c_hair_mid)
    
    # Left temple iconic silver streak
    draw.line([(16, 14), (18, 11)], fill=c_hair_silver, width=1)
    draw.line([(15, 15), (17, 12)], fill=c_hair_silver_mid, width=1)
    draw.point([(18, 12), (19, 11)], fill=c_hair_silver)
    draw.point([(15, 16), (16, 17)], fill=c_hair_silver_mid)

    return img


def generate_aluo() -> Image.Image:
    """Singer Aluo (阿洛) portrait: 48x48."""
    img = Image.new("RGBA", (PORTRAIT_SIZE, PORTRAIT_SIZE), TRANSPARENT)
    draw = ImageDraw.Draw(img)

    # Colors
    c_frame = hex_to_rgba("#2B2A2F")
    c_bg = hex_to_rgba("#FDEEE4")       # Warm peach tone
    c_bg_shadow = hex_to_rgba("#291E19", 80)
    c_outline = hex_to_rgba("#221D24")
    
    # Skin
    c_skin_base = hex_to_rgba("#FBE3D3")
    c_skin_shadow = hex_to_rgba("#EBBFA8")
    c_skin_dark = hex_to_rgba("#D2977B")
    
    # Hair (Fluffy, wavy dark)
    c_hair = hex_to_rgba("#1C1824")
    c_hair_mid = hex_to_rgba("#352E40")
    c_hair_hi = hex_to_rgba("#50465E")
    
    # Clothes (Brick-red hoodie + white tee)
    c_hoodie = hex_to_rgba("#B84A39")
    c_hoodie_hi = hex_to_rgba("#D75C48")
    c_hoodie_shadow = hex_to_rgba("#883124")
    c_inner = hex_to_rgba("#F8FAFC")
    c_inner_shadow = hex_to_rgba("#CBD5E1")
    
    # Earpiece (Cyan/Indigo)
    c_earpiece = hex_to_rgba("#6366F1")
    c_earpiece_led = hex_to_rgba("#38BDF8")

    # 1. Circular Badge Frame
    draw_circular_badge(draw, 24, 24, 22, c_bg, c_frame, c_bg_shadow)

    # 2. Torso & Hoodie
    draw.polygon([(11, 48), (14, 38), (19, 34), (29, 34), (34, 38), (37, 48)], fill=c_outline)
    draw.polygon([(12, 47), (15, 39), (20, 35), (28, 35), (33, 39), (36, 47)], fill=c_hoodie)
    draw.polygon([(15, 39), (19, 47), (21, 47), (20, 36)], fill=c_hoodie_hi)
    draw.polygon([(33, 39), (29, 47), (27, 47), (28, 36)], fill=c_hoodie_shadow)
    
    # Inner white t-shirt collar
    draw.polygon([(21, 37), (24, 42), (27, 37)], fill=c_inner)
    draw.line([(22, 38), (24, 42)], fill=c_inner_shadow)
    
    # Slender neck
    draw.rectangle([22, 29, 26, 35], fill=c_skin_shadow)
    draw.rectangle([23, 29, 25, 33], fill=c_skin_base)

    # 3. Head (Lean, slightly angular, expressive chin)
    draw.rectangle([16, 15, 32, 28], fill=c_outline)
    draw.rectangle([17, 16, 31, 27], fill=c_skin_base)
    draw.point([(16, 27), (17, 28), (31, 28), (32, 27)], fill=c_skin_shadow)
    draw.rectangle([22, 28, 26, 29], fill=c_skin_base)
    draw.line([(21, 29), (27, 29)], fill=c_skin_shadow)
    draw.line([(31, 21), (31, 27)], fill=c_skin_dark)

    # Ears & Ear-hook earpiece on left
    draw.rectangle([14, 20, 15, 24], fill=c_skin_shadow)
    draw.rectangle([32, 20, 33, 24], fill=c_skin_dark)
    draw.line([(14, 21), (15, 20)], fill=c_earpiece, width=1)
    draw.point([(15, 21)], fill=c_earpiece_led)

    # 4. Facial Features (Earnest, bright, slightly wide eyes)
    draw.line([(18, 17), (22, 17)], fill=c_hair, width=1)
    draw.line([(26, 17), (30, 17)], fill=c_hair, width=1)
    draw.rectangle([18, 19, 22, 21], fill=c_outline)
    draw.rectangle([26, 19, 30, 21], fill=c_outline)
    draw.point([(19, 19), (27, 19)], fill=hex_to_rgba("#FFFFFF"))
    draw.point([(20, 20), (28, 20)], fill=hex_to_rgba("#38BDF8"))
    draw.point([(24, 22), (24, 23), (25, 23)], fill=c_skin_shadow)
    draw.line([(22, 26), (26, 26)], fill=c_skin_dark)
    draw.point([(26, 25)], fill=c_skin_dark)

    # 5. Hair (Fluffy, wavy silhouette with wild fringe)
    draw.polygon([(13, 14), (16, 7), (24, 6), (32, 7), (36, 13), (35, 19), (13, 19)], fill=c_outline)
    draw.polygon([(14, 13), (17, 8), (24, 7), (31, 8), (35, 13), (34, 17), (14, 17)], fill=c_hair)
    draw.line([(18, 11), (23, 9)], fill=c_hair_mid, width=2)
    draw.line([(25, 9), (30, 11)], fill=c_hair_hi, width=1)
    draw.line([(17, 15), (19, 18)], fill=c_hair, width=1)
    draw.line([(23, 13), (24, 16)], fill=c_hair, width=1)
    draw.line([(27, 14), (29, 17)], fill=c_hair, width=1)
    draw.point([(20, 17), (25, 15)], fill=c_hair_mid)

    return img


def generate_qiu() -> Image.Image:
    """Boxer Qiu (老邱) portrait: 48x48."""
    img = Image.new("RGBA", (PORTRAIT_SIZE, PORTRAIT_SIZE), TRANSPARENT)
    draw = ImageDraw.Draw(img)

    # Colors
    c_frame = hex_to_rgba("#2B2A2F")
    c_bg = hex_to_rgba("#E8E5E2")       # Muted warm stone grey
    c_bg_shadow = hex_to_rgba("#211F24", 80)
    c_outline = hex_to_rgba("#221D24")
    
    # Skin (Sun-weathered veteran tan)
    c_skin_base = hex_to_rgba("#DFAB8B")
    c_skin_shadow = hex_to_rgba("#C58F6D")
    c_skin_dark = hex_to_rgba("#A26E4E")
    c_stubble = hex_to_rgba("#5C463D")
    
    # Hair (Close buzzed dark)
    c_hair = hex_to_rgba("#242129")
    c_hair_fade = hex_to_rgba("#3C3742")
    
    # Clothes (Burgundy tank top + white gym towel on shoulder)
    c_tank = hex_to_rgba("#7A2E38")
    c_tank_hi = hex_to_rgba("#963B48")
    c_tank_shadow = hex_to_rgba("#541C24")
    c_towel = hex_to_rgba("#F1F5F9")
    c_towel_shadow = hex_to_rgba("#94A3B8")

    # 1. Circular Badge Frame
    draw_circular_badge(draw, 24, 24, 22, c_bg, c_frame, c_bg_shadow)

    # 2. Broad Shoulders & Muscular Neck
    draw.polygon([(8, 48), (12, 35), (17, 31), (31, 31), (36, 35), (40, 48)], fill=c_outline)
    draw.polygon([(9, 47), (13, 36), (18, 32), (30, 32), (35, 36), (39, 47)], fill=c_tank)
    draw.rectangle([13, 40, 18, 47], fill=c_tank_hi)
    draw.rectangle([32, 40, 37, 47], fill=c_tank_shadow)
    
    # Gym towel draped over left shoulder
    draw.polygon([(9, 48), (11, 38), (16, 34), (18, 48)], fill=c_towel)
    draw.line([(14, 37), (14, 47)], fill=c_towel_shadow, width=1)
    
    # Massive trapezoid neck
    draw.rectangle([19, 27, 29, 34], fill=c_skin_shadow)
    draw.rectangle([21, 28, 27, 33], fill=c_skin_base)
    draw.line([(20, 33), (28, 33)], fill=c_skin_dark)

    # 3. Head & Heavy Boxer Jaw
    draw.rectangle([15, 14, 33, 28], fill=c_outline)
    draw.rectangle([16, 15, 32, 27], fill=c_skin_base)
    draw.rectangle([17, 25, 31, 28], fill=c_skin_base)
    draw.line([(16, 28), (32, 28)], fill=c_skin_dark)
    
    # 5 o'clock stubble shadow
    for x in range(17, 32, 2):
        draw.point([(x, 26), (x + 1, 27)], fill=c_stubble)
    draw.line([(20, 28), (28, 28)], fill=c_stubble)

    # Veteran ears
    draw.rectangle([14, 19, 15, 23], fill=c_skin_shadow)
    draw.rectangle([33, 19, 34, 23], fill=c_skin_dark)

    # 4. Facial Features (Steely, calm veteran boxer gaze)
    draw.line([(17, 17), (22, 18)], fill=c_outline, width=2)
    draw.line([(26, 18), (31, 17)], fill=c_outline, width=2)
    draw.rectangle([18, 19, 21, 20], fill=c_outline)
    draw.rectangle([27, 19, 30, 20], fill=c_outline)
    draw.point([(20, 19), (28, 19)], fill=hex_to_rgba("#FFFFFF"))
    draw.line([(23, 18), (23, 23)], fill=c_skin_shadow, width=2)
    draw.point([(22, 23), (23, 23), (24, 23), (25, 23)], fill=c_skin_dark)
    draw.line([(21, 25), (27, 25)], fill=c_skin_dark, width=1)

    # 5. Buzz Cut Hair
    draw.polygon([(15, 15), (17, 10), (24, 9), (31, 10), (33, 15)], fill=c_hair)
    draw.line([(17, 11), (31, 11)], fill=c_hair_fade)
    draw.line([(15, 14), (16, 16)], fill=c_hair_fade)
    draw.line([(32, 14), (33, 16)], fill=c_hair_fade)

    return img


def generate_lin() -> Image.Image:
    """Mechanic Lin (林师傅) portrait: 48x48."""
    img = Image.new("RGBA", (PORTRAIT_SIZE, PORTRAIT_SIZE), TRANSPARENT)
    draw = ImageDraw.Draw(img)

    # Colors
    c_frame = hex_to_rgba("#2B2A2F")
    c_bg = hex_to_rgba("#FFF5E0")       # Warm amber workshop glow
    c_bg_shadow = hex_to_rgba("#292215", 80)
    c_outline = hex_to_rgba("#221D24")
    
    # Skin (Warm artisan skin with smile lines)
    c_skin_base = hex_to_rgba("#E8BA97")
    c_skin_shadow = hex_to_rgba("#CE9C77")
    c_skin_dark = hex_to_rgba("#AC7A54")
    
    # Clothes (Cobalt blue overalls + neck sweat towel)
    c_overalls = hex_to_rgba("#2D4F8A")
    c_overalls_hi = hex_to_rgba("#3B6AB8")
    c_overalls_shadow = hex_to_rgba("#1C3663")
    c_towel = hex_to_rgba("#F1F5F9")
    c_towel_shadow = hex_to_rgba("#CBD5E1")
    
    # Hardhat & Goggles
    c_hat = hex_to_rgba("#F2C94C")
    c_hat_hi = hex_to_rgba("#FCE38A")
    c_hat_shadow = hex_to_rgba("#C99A1C")
    c_goggle_strap = hex_to_rgba("#334155")
    c_goggle_frame = hex_to_rgba("#1E293B")
    c_goggle_lens = hex_to_rgba("#7DD3FC")
    c_goggle_glint = hex_to_rgba("#FFFFFF")

    # 1. Circular Badge Frame
    draw_circular_badge(draw, 24, 24, 22, c_bg, c_frame, c_bg_shadow)

    # 2. Torso & Overalls
    draw.polygon([(10, 48), (13, 37), (18, 33), (30, 33), (35, 37), (38, 48)], fill=c_outline)
    draw.polygon([(11, 47), (14, 38), (19, 34), (29, 34), (34, 38), (37, 47)], fill=c_overalls)
    draw.rectangle([12, 41, 16, 47], fill=c_overalls_hi)
    draw.rectangle([32, 41, 36, 47], fill=c_overalls_shadow)
    
    draw.rectangle([18, 37, 21, 47], fill=c_overalls_shadow)
    draw.rectangle([27, 37, 30, 47], fill=c_overalls_shadow)
    draw.point([(19, 39), (28, 39)], fill=hex_to_rgba("#F59E0B"))
    
    # White cotton towel wrapped around neck
    draw.polygon([(16, 33), (20, 41), (28, 41), (32, 33), (28, 35), (20, 35)], fill=c_towel)
    draw.line([(19, 37), (20, 40)], fill=c_towel_shadow, width=1)
    draw.line([(28, 37), (28, 40)], fill=c_towel_shadow, width=1)

    # Neck
    draw.rectangle([21, 29, 27, 34], fill=c_skin_shadow)

    # 3. Head & Warm Weathered Face
    draw.rectangle([16, 17, 32, 29], fill=c_outline)
    draw.rectangle([17, 18, 31, 28], fill=c_skin_base)
    draw.point([(16, 28), (17, 29), (31, 29), (32, 28)], fill=c_skin_shadow)
    draw.line([(18, 29), (30, 29)], fill=c_skin_dark)
    draw.line([(31, 22), (31, 28)], fill=c_skin_dark)

    # Ears
    draw.rectangle([14, 21, 15, 25], fill=c_skin_shadow)
    draw.rectangle([32, 21, 33, 25], fill=c_skin_dark)

    # 4. Facial Features (Smiling, shrewd, warm eyes with crow's feet)
    draw.line([(18, 19), (22, 19)], fill=hex_to_rgba("#38322B"), width=1)
    draw.line([(26, 19), (30, 19)], fill=hex_to_rgba("#38322B"), width=1)
    draw.line([(18, 21), (22, 21)], fill=c_outline, width=1)
    draw.point([(17, 20), (22, 22)], fill=c_skin_dark)
    draw.line([(26, 21), (30, 21)], fill=c_outline, width=1)
    draw.point([(31, 20), (26, 22)], fill=c_skin_dark)
    draw.rectangle([23, 22, 25, 24], fill=c_skin_shadow)
    draw.point([(23, 24), (25, 24)], fill=c_skin_dark)
    draw.line([(21, 26), (27, 26)], fill=c_skin_dark, width=1)
    draw.point([(20, 25), (28, 25)], fill=c_skin_dark)

    # 5. Hardhat & Goggles
    draw.line([(14, 15), (34, 15)], fill=c_goggle_strap, width=1)
    draw.polygon([(12, 15), (15, 8), (24, 6), (33, 8), (36, 15)], fill=c_outline)
    draw.polygon([(13, 14), (16, 9), (24, 7), (32, 9), (35, 14)], fill=c_hat)
    draw.line([(17, 9), (24, 8)], fill=c_hat_hi, width=1)
    draw.line([(28, 11), (34, 13)], fill=c_hat_shadow, width=1)
    draw.line([(11, 16), (37, 16)], fill=c_outline, width=1)
    draw.line([(12, 15), (36, 15)], fill=c_hat_hi, width=1)

    # Goggles
    draw.rectangle([18, 12, 22, 15], fill=c_goggle_frame)
    draw.rectangle([19, 13, 21, 14], fill=c_goggle_lens)
    draw.point([(19, 13)], fill=c_goggle_glint)
    draw.line([(23, 13), (24, 13)], fill=c_goggle_frame)
    draw.rectangle([25, 12, 29, 15], fill=c_goggle_frame)
    draw.rectangle([26, 13, 28, 14], fill=c_goggle_lens)
    draw.point([(26, 13)], fill=c_goggle_glint)

    return img


def main() -> None:
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    portraits = {
        "portrait_cheng.png": generate_cheng(),
        "portrait_aluo.png": generate_aluo(),
        "portrait_qiu.png": generate_qiu(),
        "portrait_lin.png": generate_lin(),
    }

    for name, img in portraits.items():
        out_path = OUTPUT_DIR / name
        img.save(out_path, format="PNG")
        print(f"Generated {out_path} ({img.width}x{img.height})")


if __name__ == "__main__":
    main()
