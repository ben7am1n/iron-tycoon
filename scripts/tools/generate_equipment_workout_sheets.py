#!/usr/bin/env python3
"""
generate_equipment_workout_sheets.py
Generates native 32x40 pixel art frames for equipment workouts:
- Stationary Bike (cycling, alternating pedals, forward lean)
- Bench Press (horizontal lying, barbell lowering & pressing)
- Yoga Mat (seated stretch / lotus pose)
For Singer Aluo and 4 Generic Member variants.
Saved to assets/sprites/characters/member_equipment_workout_sheet.png
"""

import os
from PIL import Image, ImageDraw

def hex_to_rgba(hex_str, alpha=255):
    h = hex_str.lstrip('#')
    return tuple(int(h[i:i+2], 16) for i in (0, 2, 4)) + (alpha,)

C_TRANS = (0, 0, 0, 0)
C_OUTLINE = hex_to_rgba("15181e")
WHITE = hex_to_rgba("ffffff")
SKIN = hex_to_rgba("dfa77e")
SKIN_DARK = hex_to_rgba("be8662")

# Aluo
ALUO_RED = hex_to_rgba("b84a39")
ALUO_RED_DARK = hex_to_rgba("8f3527")
ALUO_HAIR = hex_to_rgba("2b2220")
ALUO_PANTS = hex_to_rgba("232730")

# Barbells and Equipment Accents
BAR_METAL = hex_to_rgba("cbd5e1")
BAR_METAL_DARK = hex_to_rgba("64748b")
PLATE_OUTLINE = hex_to_rgba("0f172a")
PLATE_BODY = hex_to_rgba("334155")
PLATE_HIGHLIGHT = hex_to_rgba("64748b")

# Generic Member Colors
SHIRT_COLORS = [
    hex_to_rgba("3b82f6"), # 0: Blue
    hex_to_rgba("f97316"), # 1: Orange (tank)
    hex_to_rgba("10b981"), # 2: Green
    hex_to_rgba("8b5cf6"), # 3: Purple
]


def create_canvas():
    return Image.new("RGBA", (32, 40), C_TRANS)


def draw_bike_frame(is_aluo=False, variant=0, phase=0):
    img = create_canvas()
    d = ImageDraw.Draw(img)

    shirt = ALUO_RED if is_aluo else SHIRT_COLORS[variant % 4]
    shirt_dark = ALUO_RED_DARK if is_aluo else (int(shirt[0]*0.7), int(shirt[1]*0.7), int(shirt[2]*0.7), 255)
    pants = ALUO_PANTS if is_aluo else hex_to_rgba("232730")
    hair = ALUO_HAIR if is_aluo else hex_to_rgba("221a18")

    bob_y = 1 if phase == 1 else 0

    # Bike Riding: Body leans forward to the right (towards handlebars at x ≈ 22, y ≈ 20)
    # 1. Legs & Pedals (alternating cadence)
    # Phase 0: Left leg extended down (foot at x=14, y=34), Right leg up (x=18, y=28)
    # Phase 1: Left leg up (x=14, y=28), Right leg extended down (x=18, y=34)
    foot_l_y = 34 if phase == 0 else 28
    foot_r_y = 28 if phase == 0 else 34

    # Left leg
    d.rectangle([12, 24, 15, foot_l_y], fill=C_OUTLINE)
    d.rectangle([13, 25, 14, foot_l_y - 1], fill=pants)
    d.rectangle([12, foot_l_y, 16, foot_l_y + 1], fill=WHITE)

    # Right leg
    d.rectangle([17, 24, 20, foot_r_y], fill=C_OUTLINE)
    d.rectangle([18, 25, 19, foot_r_y - 1], fill=pants)
    d.rectangle([17, foot_r_y, 21, foot_r_y + 1], fill=WHITE)

    # 2. Torso (Leaning forward 15°)
    tx, ty = 12, 16 + bob_y
    d.rectangle([tx - 1, ty - 1, tx + 10, ty + 9], fill=C_OUTLINE)
    d.rectangle([tx, ty, tx + 9, ty + 8], fill=shirt)
    d.rectangle([tx, ty, tx + 2, ty + 8], fill=shirt_dark)

    # 3. Arms reaching to handlebars (x=21..24, y=19..22)
    d.line([(tx + 7, ty + 3), (22, 20 + bob_y)], fill=C_OUTLINE, width=3)
    d.line([(tx + 7, ty + 3), (22, 20 + bob_y)], fill=shirt if (not is_aluo and variant != 1) else SKIN, width=1)
    # Hand grip
    d.rectangle([21, 19 + bob_y, 23, 21 + bob_y], fill=SKIN)

    # 4. Head (leaning forward)
    hx, hy = 15, 8 + bob_y
    d.rectangle([hx - 1, hy - 1, hx + 8, hy + 8], fill=C_OUTLINE)
    d.rectangle([hx, hy, hx + 7, hy + 7], fill=SKIN)
    d.rectangle([hx, hy, hx + 7, hy + 3], fill=hair)
    # Eye looking forward
    d.point([(hx + 5, hy + 5)], fill=C_OUTLINE)
    d.point([(hx + 5, hy + 6)], fill=SKIN_DARK)

    return img


def draw_bench_press_frame(is_aluo=False, variant=0, phase=0):
    img = create_canvas()
    d = ImageDraw.Draw(img)

    shirt = ALUO_RED if is_aluo else SHIRT_COLORS[variant % 4]
    shirt_dark = ALUO_RED_DARK if is_aluo else (int(shirt[0]*0.7), int(shirt[1]*0.7), int(shirt[2]*0.7), 255)
    pants = ALUO_PANTS if is_aluo else hex_to_rgba("232730")
    hair = ALUO_HAIR if is_aluo else hex_to_rgba("221a18")

    # Bench Press: Lying horizontally on bench
    # Head at left (x ≈ 8, y ≈ 25)
    # Torso horizontal (x ≈ 12..22, y ≈ 25..29)
    # Bent legs on right (x ≈ 23..27, y ≈ 28..36), feet planted on floor

    # 1. Legs planted
    d.rectangle([22, 27, 26, 35], fill=C_OUTLINE)
    d.rectangle([23, 28, 25, 33], fill=pants)
    d.rectangle([23, 34, 27, 35], fill=WHITE) # Shoe

    # 2. Torso on bench
    d.rectangle([11, 24, 22, 29], fill=C_OUTLINE)
    d.rectangle([12, 25, 21, 28], fill=shirt)
    d.rectangle([12, 27, 21, 28], fill=shirt_dark)

    # 3. Head resting on bench
    d.rectangle([5, 23, 11, 29], fill=C_OUTLINE)
    d.rectangle([6, 24, 10, 28], fill=SKIN)
    d.rectangle([5, 23, 8, 28], fill=hair)
    d.point([(9, 25)], fill=C_OUTLINE)

    # 4. Barbell + Arms
    # Phase 0: Lowered near chest (bar_y = 20)
    # Phase 1: Pressed high (bar_y = 12)
    bar_y = 20 if phase == 0 else 12

    # Arms pressing up
    arm_x1, arm_x2 = 14, 19
    d.line([(arm_x1, 25), (arm_x1, bar_y + 1)], fill=C_OUTLINE, width=3)
    d.line([(arm_x1, 25), (arm_x1, bar_y + 1)], fill=SKIN, width=1)

    d.line([(arm_x2, 25), (arm_x2, bar_y + 1)], fill=C_OUTLINE, width=3)
    d.line([(arm_x2, 25), (arm_x2, bar_y + 1)], fill=SKIN, width=1)

    # Hands gripping bar
    d.rectangle([arm_x1 - 1, bar_y, arm_x1 + 1, bar_y + 2], fill=SKIN)
    d.rectangle([arm_x2 - 1, bar_y, arm_x2 + 1, bar_y + 2], fill=SKIN)

    # Barbell shaft
    d.line([(2, bar_y), (29, bar_y)], fill=C_OUTLINE, width=3)
    d.line([(3, bar_y), (28, bar_y)], fill=BAR_METAL, width=1)

    # Barbell weight plates on both ends
    # Left plate
    d.rectangle([1, bar_y - 4, 4, bar_y + 4], fill=PLATE_OUTLINE)
    d.rectangle([2, bar_y - 3, 3, bar_y + 3], fill=PLATE_BODY)
    d.line([(2, bar_y - 3), (3, bar_y - 3)], fill=PLATE_HIGHLIGHT)

    # Right plate
    d.rectangle([27, bar_y - 4, 30, bar_y + 4], fill=PLATE_OUTLINE)
    d.rectangle([28, bar_y - 3, 29, bar_y + 3], fill=PLATE_BODY)
    d.line([(28, bar_y - 3), (29, bar_y - 3)], fill=PLATE_HIGHLIGHT)

    return img


def draw_yoga_frame(is_aluo=False, variant=0, phase=0):
    img = create_canvas()
    d = ImageDraw.Draw(img)

    shirt = ALUO_RED if is_aluo else SHIRT_COLORS[variant % 4]
    shirt_dark = ALUO_RED_DARK if is_aluo else (int(shirt[0]*0.7), int(shirt[1]*0.7), int(shirt[2]*0.7), 255)
    pants = ALUO_PANTS if is_aluo else hex_to_rgba("232730")
    hair = ALUO_HAIR if is_aluo else hex_to_rgba("221a18")

    breath_y = 1 if phase == 1 else 0

    # Seated lotus stretch
    # Crossed legs flat on floor (x ≈ 8..24, y ≈ 33..37)
    d.rectangle([7, 32, 25, 37], fill=C_OUTLINE)
    d.rectangle([8, 33, 24, 36], fill=pants)
    # Bare feet / ankles
    d.point([(8, 34), (24, 34)], fill=SKIN)

    # Upright spine torso
    tx, ty = 10, 21 - breath_y
    d.rectangle([tx - 1, ty - 1, tx + 12, ty + 12], fill=C_OUTLINE)
    d.rectangle([tx, ty, tx + 11, ty + 11], fill=shirt)
    d.rectangle([tx, ty, tx + 2, ty + 11], fill=shirt_dark)
    d.rectangle([tx + 9, ty, tx + 11, ty + 11], fill=shirt_dark)

    # Hands in namaste or resting on knees
    if phase == 0:
        # Resting on knees
        d.line([(tx, ty + 3), (9, 32)], fill=C_OUTLINE, width=3)
        d.line([(tx, ty + 3), (9, 32)], fill=SKIN, width=1)
        d.line([(tx + 11, ty + 3), (23, 32)], fill=C_OUTLINE, width=3)
        d.line([(tx + 11, ty + 3), (23, 32)], fill=SKIN, width=1)
    else:
        # Hands together in namaste at heart center
        d.line([(tx, ty + 4), (16, ty + 6)], fill=C_OUTLINE, width=3)
        d.line([(tx, ty + 4), (16, ty + 6)], fill=SKIN, width=1)
        d.line([(tx + 11, ty + 4), (16, ty + 6)], fill=C_OUTLINE, width=3)
        d.line([(tx + 11, ty + 4), (16, ty + 6)], fill=SKIN, width=1)
        d.rectangle([15, ty + 5, 17, ty + 8], fill=SKIN)

    # Head (peaceful closed eyes)
    hx, hy = 12, 11 - breath_y
    d.rectangle([hx - 1, hy - 1, hx + 8, hy + 8], fill=C_OUTLINE)
    d.rectangle([hx, hy, hx + 7, hy + 7], fill=SKIN)
    d.rectangle([hx, hy, hx + 7, hy + 3], fill=hair)
    # Serene closed crescent eyes
    d.line([(hx + 2, hy + 5), (hx + 3, hy + 5)], fill=C_OUTLINE, width=1)
    d.line([(hx + 5, hy + 5), (hx + 6, hy + 5)], fill=C_OUTLINE, width=1)

    return img


def main():
    sprites_dir = "assets/sprites/characters"
    os.makedirs(sprites_dir, exist_ok=True)

    # Layout:
    # 5 rows (Row 0 = Aluo, Row 1..4 = Generic Member Variants 0..3)
    # 6 columns:
    # Col 0..1: Bike 0..1
    # Col 2..3: Bench Press 0..1
    # Col 4..5: Yoga 0..1
    all_frames = []

    # Row 0: Aluo
    all_frames.extend([
        draw_bike_frame(is_aluo=True, variant=0, phase=0),
        draw_bike_frame(is_aluo=True, variant=0, phase=1),
        draw_bench_press_frame(is_aluo=True, variant=0, phase=0),
        draw_bench_press_frame(is_aluo=True, variant=0, phase=1),
        draw_yoga_frame(is_aluo=True, variant=0, phase=0),
        draw_yoga_frame(is_aluo=True, variant=0, phase=1),
    ])

    # Rows 1..4: Generic Members 0..3
    for v in range(4):
        all_frames.extend([
            draw_bike_frame(is_aluo=False, variant=v, phase=0),
            draw_bike_frame(is_aluo=False, variant=v, phase=1),
            draw_bench_press_frame(is_aluo=False, variant=v, phase=0),
            draw_bench_press_frame(is_aluo=False, variant=v, phase=1),
            draw_yoga_frame(is_aluo=False, variant=v, phase=0),
            draw_yoga_frame(is_aluo=False, variant=v, phase=1),
        ])

    sheet = Image.new("RGBA", (6 * 32, 5 * 40), C_TRANS)
    for idx, f in enumerate(all_frames):
        c = idx % 6
        r = idx // 6
        sheet.paste(f, (c * 32, r * 40))

    out_path = os.path.join(sprites_dir, "member_equipment_workout_sheet.png")
    sheet.save(out_path)
    print(f"Saved {out_path} ({sheet.size})")

if __name__ == "__main__":
    main()
