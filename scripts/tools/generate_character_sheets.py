#!/usr/bin/env python3
"""
generate_character_sheets.py
Generates 32x40 pixel art sprite sheets for Coach Cheng, Singer Aluo,
and Generic Members, plus 3 dialogue expressions (neutral, tired, smile) for Aluo.
"""

import os
from PIL import Image, ImageDraw

def hex_to_rgba(hex_str, alpha=255):
    h = hex_str.lstrip('#')
    return tuple(int(h[i:i+2], 16) for i in (0, 2, 4)) + (alpha,)

# Color Constants
C_TRANS = (0, 0, 0, 0)
C_OUTLINE = hex_to_rgba("15181e")

# Cheng Palette
CHENG_TEAL = hex_to_rgba("2e7d6b")
CHENG_TEAL_DARK = hex_to_rgba("1f594c")
CHENG_TEAL_LIGHT = hex_to_rgba("48ad95")
CHENG_ZIPPER = hex_to_rgba("e2e8f0")
CHENG_PANTS = hex_to_rgba("1c2026")
CHENG_SHOE = hex_to_rgba("26282e")
CHENG_SOLE = hex_to_rgba("f1f5f9")
CHENG_HAIR = hex_to_rgba("221a18")
CHENG_SILVER = hex_to_rgba("f1f5f9")
SKIN = hex_to_rgba("dfa77e")
SKIN_DARK = hex_to_rgba("be8662")
SKIN_FLUSH = hex_to_rgba("e88d8d")

# Aluo Palette
ALUO_RED = hex_to_rgba("b84a39")
ALUO_RED_DARK = hex_to_rgba("8f3527")
ALUO_RED_LIGHT = hex_to_rgba("d4604e")
ALUO_CYAN = hex_to_rgba("38bdf8")
ALUO_CYAN_GLOW = hex_to_rgba("7dd3fc")
ALUO_HAIR = hex_to_rgba("2b2220")
ALUO_PANTS = hex_to_rgba("232730")
ALUO_SHOE = hex_to_rgba("3e4452")

GOLD = hex_to_rgba("f6c344")
WHITE = hex_to_rgba("ffffff")


def create_frame_canvas():
    return Image.new("RGBA", (32, 40), C_TRANS)


def draw_cheng_frame(pose="idle", phase=0, direction="down"):
    img = create_frame_canvas()
    d = ImageDraw.Draw(img)

    # Bobbing
    bob_y = 1 if (pose == "walk" and phase in (1, 3)) or (pose == "idle" and phase == 1) else 0

    # 1. Legs & Shoes
    leg_l_x, leg_r_x = 11, 17
    leg_l_y, leg_r_y = 27 + bob_y, 27 + bob_y
    shoe_l_y, shoe_r_y = 35 + bob_y, 35 + bob_y

    if pose == "walk":
        if phase == 0:
            leg_l_y -= 1
            shoe_l_y -= 1
        elif phase == 2:
            leg_r_y -= 1
            shoe_r_y -= 1

    # Left leg
    d.rectangle([leg_l_x - 1, leg_l_y, leg_l_x + 3, shoe_l_y + 2], fill=C_OUTLINE)
    d.rectangle([leg_l_x, leg_l_y, leg_l_x + 2, shoe_l_y - 1], fill=CHENG_PANTS)
    d.rectangle([leg_l_x, shoe_l_y, leg_l_x + 3, shoe_l_y + 1], fill=CHENG_SHOE)
    d.rectangle([leg_l_x, shoe_l_y + 2, leg_l_x + 3, shoe_l_y + 2], fill=CHENG_SOLE)

    # Right leg
    d.rectangle([leg_r_x - 1, leg_r_y, leg_r_x + 3, shoe_r_y + 2], fill=C_OUTLINE)
    d.rectangle([leg_r_x, leg_r_y, leg_r_x + 2, shoe_r_y - 1], fill=CHENG_PANTS)
    d.rectangle([leg_r_x - 1, shoe_r_y, leg_r_x + 2, shoe_r_y + 1], fill=CHENG_SHOE)
    d.rectangle([leg_r_x - 1, shoe_r_y + 2, leg_r_x + 2, shoe_r_y + 2], fill=CHENG_SOLE)

    # 2. Torso (Broad shoulders: 14px width: x 9..22)
    t_top = 16 + bob_y
    t_bot = 27 + bob_y
    sw = 14
    tx = 16 - sw // 2

    # Outline
    d.rectangle([tx - 1, t_top - 1, tx + sw, t_bot], fill=C_OUTLINE)
    # Body
    d.rectangle([tx, t_top, tx + sw - 1, t_bot - 1], fill=CHENG_TEAL)
    # Shading
    d.rectangle([tx, t_top, tx + 1, t_bot - 1], fill=CHENG_TEAL_DARK)
    d.rectangle([tx + sw - 2, t_top, tx + sw - 1, t_bot - 1], fill=CHENG_TEAL_DARK)

    # Details by direction
    if direction == "down":
        # Center zipper & collar
        d.line([(16, t_top + 1), (16, t_bot - 1)], fill=CHENG_ZIPPER, width=1)
        d.rectangle([14, t_top, 17, t_top + 1], fill=CHENG_TEAL_DARK)
    elif direction == "up":
        # Back muscular seam
        d.line([(16, t_top + 2), (16, t_bot - 2)], fill=CHENG_TEAL_DARK, width=1)
    elif direction in ("left", "right"):
        front_x = tx + 1 if direction == "left" else tx + sw - 2
        d.line([(front_x, t_top + 1), (front_x, t_bot - 1)], fill=CHENG_TEAL_LIGHT, width=1)

    # 3. Arms
    arm_l_y = t_top + 1
    arm_r_y = t_top + 1
    if pose == "walk":
        if phase in (0, 1):
            arm_l_y -= 2
            arm_r_y += 2
        else:
            arm_l_y += 2
            arm_r_y -= 2
    elif pose == "guidance":
        # Clapping hands together at chest
        arm_l_y -= 4
        arm_r_y -= 4
    elif pose == "success":
        # Thumbs up / fist pump high
        arm_l_y -= 6
        arm_r_y -= 6

    if pose == "guidance":
        # Clapping hands in front
        clap_x = 15 if phase == 0 else 14
        d.rectangle([clap_x - 2, t_top + 3, clap_x + 4, t_top + 8], fill=C_OUTLINE)
        d.rectangle([clap_x - 1, t_top + 4, clap_x + 3, t_top + 7], fill=SKIN)
        # Motion sparks
        if phase == 1:
            d.point([(clap_x - 3, t_top + 2), (clap_x + 5, t_top + 2)], fill=GOLD)
    elif pose == "success":
        # Right arm high celebration
        d.rectangle([tx + sw, t_top - 6, tx + sw + 3, t_top + 3], fill=C_OUTLINE)
        d.rectangle([tx + sw + 1, t_top - 5, tx + sw + 2, t_top + 2], fill=CHENG_TEAL)
        d.rectangle([tx + sw, t_top - 8, tx + sw + 3, t_top - 6], fill=SKIN)
        # Left arm on hip
        d.rectangle([tx - 4, t_top + 1, tx - 1, t_top + 7], fill=C_OUTLINE)
        d.rectangle([tx - 3, t_top + 2, tx - 2, t_top + 6], fill=CHENG_TEAL)
        d.rectangle([tx - 3, t_top + 7, tx - 2, t_top + 8], fill=SKIN)
        # Celebration star
        d.point([(tx + sw + 1, t_top - 10), (tx + sw + 4, t_top - 8)], fill=GOLD)
    else:
        # Normal arms at sides
        d.rectangle([tx - 4, arm_l_y, tx - 1, arm_l_y + 8], fill=C_OUTLINE)
        d.rectangle([tx - 3, arm_l_y + 1, tx - 2, arm_l_y + 6], fill=CHENG_TEAL)
        d.rectangle([tx - 3, arm_l_y + 7, tx - 2, arm_l_y + 8], fill=SKIN)

        d.rectangle([tx + sw, arm_r_y, tx + sw + 3, arm_r_y + 8], fill=C_OUTLINE)
        d.rectangle([tx + sw + 1, arm_r_y + 1, tx + sw + 2, arm_r_y + 6], fill=CHENG_TEAL)
        d.rectangle([tx + sw + 1, arm_r_y + 7, tx + sw + 2, arm_r_y + 8], fill=SKIN)

    # 4. Head (8x8 canvas centered at x=16, y=6..14)
    hx = 12
    hy = 6 + bob_y
    # Head outline
    d.rectangle([hx - 1, hy - 1, hx + 8, hy + 8], fill=C_OUTLINE)
    # Face skin
    d.rectangle([hx, hy, hx + 7, hy + 7], fill=SKIN)

    if direction == "up":
        # Back of head: full hair
        d.rectangle([hx, hy, hx + 7, hy + 6], fill=CHENG_HAIR)
        # Silver streak on right side
        d.rectangle([hx + 5, hy + 1, hx + 7, hy + 3], fill=CHENG_SILVER)
    else:
        # Hair top & sides
        d.rectangle([hx, hy, hx + 7, hy + 2], fill=CHENG_HAIR)
        d.rectangle([hx, hy + 2, hx + 1, hy + 5], fill=CHENG_HAIR)
        d.rectangle([hx + 6, hy + 2, hx + 7, hy + 5], fill=CHENG_HAIR)

        # Distinctive Silver Streak (right temple / forehead)
        d.rectangle([hx + 4, hy, hx + 6, hy + 1], fill=CHENG_SILVER)
        d.rectangle([hx + 5, hy + 2, hx + 6, hy + 3], fill=CHENG_SILVER)

        # Eyes & mouth
        if direction == "down":
            if pose == "success":
                # Happy closed crescent eyes & smile
                d.point([(hx + 2, hy + 4), (hx + 5, hy + 4)], fill=C_OUTLINE)
                d.line([(hx + 3, hy + 6), (hx + 4, hy + 6)], fill=WHITE, width=1)
            else:
                d.rectangle([hx + 2, hy + 4, hx + 2, hy + 4], fill=C_OUTLINE)
                d.rectangle([hx + 5, hy + 4, hx + 5, hy + 4], fill=C_OUTLINE)
                d.point([(hx + 3, hy + 6)], fill=SKIN_DARK)
        elif direction == "left":
            d.point([(hx + 2, hy + 4)], fill=C_OUTLINE)
        elif direction == "right":
            d.point([(hx + 5, hy + 4)], fill=C_OUTLINE)

    return img


def draw_aluo_frame(pose="idle", phase=0, direction="down"):
    img = create_frame_canvas()
    d = ImageDraw.Draw(img)

    bob_y = 1 if (pose in ("walk", "treadmill") and phase in (1, 3)) else 0

    # 1. Legs & Shoes
    leg_l_x, leg_r_x = 12, 16
    leg_l_y, leg_r_y = 27 + bob_y, 27 + bob_y
    shoe_l_y, shoe_r_y = 35 + bob_y, 35 + bob_y

    if pose == "treadmill":
        # Running leg cycle
        if phase in (0, 1):
            leg_l_y -= 2
            shoe_l_y -= 2
            shoe_r_y += 1
        else:
            leg_r_y -= 2
            shoe_r_y -= 2
            shoe_l_y += 1
    elif pose == "yoga":
        # Seated lotus on mat
        d.rectangle([9, 32, 22, 37], fill=C_OUTLINE)
        d.rectangle([10, 33, 21, 36], fill=ALUO_PANTS)
        d.rectangle([11, 34, 13, 36], fill=ALUO_SHOE)
        d.rectangle([18, 34, 20, 36], fill=ALUO_SHOE)
    elif pose == "walk":
        if phase == 0:
            leg_l_y -= 1
            shoe_l_y -= 1
        elif phase == 2:
            leg_r_y -= 1
            shoe_r_y -= 1

    if pose != "yoga":
        # Left leg
        d.rectangle([leg_l_x - 1, leg_l_y, leg_l_x + 2, shoe_l_y + 1], fill=C_OUTLINE)
        d.rectangle([leg_l_x, leg_l_y, leg_l_x + 1, shoe_l_y - 1], fill=ALUO_PANTS)
        d.rectangle([leg_l_x, shoe_l_y, leg_l_x + 2, shoe_l_y + 1], fill=ALUO_SHOE)

        # Right leg
        d.rectangle([leg_r_x - 1, leg_r_y, leg_r_x + 2, shoe_r_y + 1], fill=C_OUTLINE)
        d.rectangle([leg_r_x, leg_r_y, leg_r_x + 1, shoe_r_y - 1], fill=ALUO_PANTS)
        d.rectangle([leg_r_x - 1, shoe_r_y, leg_r_x + 1, shoe_r_y + 1], fill=ALUO_SHOE)

    # 2. Torso (Aluo is leaner: shoulder width 11px: x 10..20)
    t_top = (17 if pose != "yoga" else 20) + bob_y
    t_bot = (27 if pose != "yoga" else 33) + bob_y
    sw = 11
    tx = 16 - sw // 2

    # Outline
    d.rectangle([tx - 1, t_top - 1, tx + sw, t_bot], fill=C_OUTLINE)
    # Hoodie
    d.rectangle([tx, t_top, tx + sw - 1, t_bot - 1], fill=ALUO_RED)
    # Shading
    d.rectangle([tx, t_top, tx + 1, t_bot - 1], fill=ALUO_RED_DARK)
    d.rectangle([tx + sw - 2, t_top, tx + sw - 1, t_bot - 1], fill=ALUO_RED_DARK)
    # Hoodie strings / pouch pocket
    d.line([(tx + 3, t_top + 2), (tx + 3, t_top + 5)], fill=WHITE, width=1)
    d.line([(tx + sw - 4, t_top + 2), (tx + sw - 4, t_top + 5)], fill=WHITE, width=1)
    d.rectangle([tx + 2, t_bot - 4, tx + sw - 3, t_bot - 2], fill=ALUO_RED_LIGHT)

    # 3. Arms
    arm_l_y = t_top + 1
    arm_r_y = t_top + 1
    if pose == "treadmill":
        # Pumping running arms
        arm_l_y = t_top - 2 if phase in (0, 1) else t_top + 2
        arm_r_y = t_top + 2 if phase in (0, 1) else t_top - 2
        d.rectangle([tx - 3, arm_l_y, tx - 1, arm_l_y + 6], fill=C_OUTLINE)
        d.rectangle([tx - 2, arm_l_y + 1, tx - 1, arm_l_y + 5], fill=ALUO_RED)
        d.rectangle([tx + sw, arm_r_y, tx + sw + 2, arm_r_y + 6], fill=C_OUTLINE)
        d.rectangle([tx + sw, arm_r_y + 1, tx + sw + 1, arm_r_y + 5], fill=ALUO_RED)
    elif pose == "yoga":
        # Extending arms out gently
        d.rectangle([tx - 4, t_top + 2, tx - 1, t_top + 5], fill=C_OUTLINE)
        d.rectangle([tx - 3, t_top + 3, tx - 1, t_top + 4], fill=ALUO_RED)
        d.rectangle([tx + sw, t_top + 2, tx + sw + 3, t_top + 5], fill=C_OUTLINE)
        d.rectangle([tx + sw, t_top + 3, tx + sw + 2, t_top + 4], fill=ALUO_RED)
    elif pose == "tired":
        # Hands resting on knees / waist
        d.rectangle([tx - 3, t_top + 3, tx - 1, t_top + 9], fill=C_OUTLINE)
        d.rectangle([tx - 2, t_top + 4, tx - 1, t_top + 8], fill=ALUO_RED)
        d.rectangle([tx + sw, t_top + 3, tx + sw + 2, t_top + 9], fill=C_OUTLINE)
        d.rectangle([tx + sw, t_top + 4, tx + sw + 1, t_top + 8], fill=ALUO_RED)
    else:
        # Normal relaxed arms
        d.rectangle([tx - 3, arm_l_y, tx - 1, arm_l_y + 7], fill=C_OUTLINE)
        d.rectangle([tx - 2, arm_l_y + 1, tx - 1, arm_l_y + 6], fill=ALUO_RED)
        d.rectangle([tx + sw, arm_r_y, tx + sw + 2, arm_r_y + 7], fill=C_OUTLINE)
        d.rectangle([tx + sw, arm_r_y + 1, tx + sw + 1, arm_r_y + 6], fill=ALUO_RED)

    # 4. Head
    hx = 12
    hy = (7 if pose != "yoga" else 10) + bob_y
    d.rectangle([hx - 1, hy - 1, hx + 8, hy + 8], fill=C_OUTLINE)
    d.rectangle([hx, hy, hx + 7, hy + 7], fill=SKIN)

    # Shaggy hair with bangs
    d.rectangle([hx, hy, hx + 7, hy + 3], fill=ALUO_HAIR)
    d.rectangle([hx, hy + 3, hx + 1, hy + 5], fill=ALUO_HAIR)
    d.rectangle([hx + 6, hy + 3, hx + 7, hy + 5], fill=ALUO_HAIR)
    d.point([(hx + 2, hy + 3), (hx + 4, hy + 3)], fill=ALUO_HAIR)

    # Signature Cyan Earpiece Indicator LED on left/right ear
    d.point([(hx, hy + 4)], fill=ALUO_CYAN)
    d.point([(hx, hy + 3)], fill=ALUO_CYAN_GLOW)

    # Face expression
    if pose == "tired":
        # Panting squinted eyes + sweat droplet
        d.point([(hx + 2, hy + 5), (hx + 5, hy + 5)], fill=C_OUTLINE)
        d.point([(hx + 3, hy + 7), (hx + 4, hy + 7)], fill=ALUO_RED_DARK) # open panting mouth
        d.point([(hx + 1, hy + 2)], fill=ALUO_CYAN_GLOW) # sweat drop
        d.point([(hx + 2, hy + 6), (hx + 5, hy + 6)], fill=SKIN_FLUSH) # flushed cheeks
    elif pose == "success":
        # Happy smile
        d.point([(hx + 2, hy + 4), (hx + 5, hy + 4)], fill=C_OUTLINE)
        d.point([(hx + 3, hy + 6), (hx + 4, hy + 6)], fill=WHITE)
        d.point([(hx + 2, hy + 5), (hx + 5, hy + 5)], fill=SKIN_FLUSH)
    else:
        # Determined / attentive look
        d.point([(hx + 2, hy + 5), (hx + 5, hy + 5)], fill=C_OUTLINE)
        d.point([(hx + 3, hy + 7)], fill=SKIN_DARK)

    return img


def draw_generic_member_frame(variant=0, pose="idle", phase=0, direction="down"):
    # Builds: 0=Standard, 1=Strength (tank top), 2=Cardio (lean), 3=Flex
    img = create_frame_canvas()
    d = ImageDraw.Draw(img)

    bob_y = 1 if (pose in ("walk", "treadmill") and phase in (1, 3)) else 0

    shirt_colors = [
        hex_to_rgba("3b82f6"), # Blue
        hex_to_rgba("f97316"), # Orange
        hex_to_rgba("10b981"), # Green
        hex_to_rgba("8b5cf6"), # Purple
    ]
    shirt = shirt_colors[variant % 4]
    shirt_dark = (int(shirt[0] * 0.7), int(shirt[1] * 0.7), int(shirt[2] * 0.7), 255)

    sw = 14 if variant == 1 else (10 if variant == 2 else 12)
    tx = 16 - sw // 2

    # Legs
    leg_l_x, leg_r_x = 12, 16
    shoe_l_y, shoe_r_y = 35 + bob_y, 35 + bob_y
    if pose == "treadmill":
        if phase in (0, 1): shoe_l_y -= 2
        else: shoe_r_y -= 2

    d.rectangle([leg_l_x - 1, 27 + bob_y, leg_l_x + 2, shoe_l_y + 1], fill=C_OUTLINE)
    d.rectangle([leg_l_x, 27 + bob_y, leg_l_x + 1, shoe_l_y - 1], fill=hex_to_rgba("232730"))
    d.rectangle([leg_l_x, shoe_l_y, leg_l_x + 2, shoe_l_y + 1], fill=WHITE)

    d.rectangle([leg_r_x - 1, 27 + bob_y, leg_r_x + 2, shoe_r_y + 1], fill=C_OUTLINE)
    d.rectangle([leg_r_x, 27 + bob_y, leg_r_x + 1, shoe_r_y - 1], fill=hex_to_rgba("232730"))
    d.rectangle([leg_r_x - 1, shoe_r_y, leg_r_x + 1, shoe_r_y + 1], fill=WHITE)

    # Torso
    t_top = 17 + bob_y
    t_bot = 27 + bob_y
    d.rectangle([tx - 1, t_top - 1, tx + sw, t_bot], fill=C_OUTLINE)
    d.rectangle([tx, t_top, tx + sw - 1, t_bot - 1], fill=shirt)
    d.rectangle([tx, t_top, tx + 1, t_bot - 1], fill=shirt_dark)
    d.rectangle([tx + sw - 2, t_top, tx + sw - 1, t_bot - 1], fill=shirt_dark)

    # Arms
    d.rectangle([tx - 3, t_top + 1, tx - 1, t_top + 7], fill=C_OUTLINE)
    d.rectangle([tx - 2, t_top + 2, tx - 1, t_top + 6], fill=shirt if variant != 1 else SKIN)
    d.rectangle([tx + sw, t_top + 1, tx + sw + 2, t_top + 7], fill=C_OUTLINE)
    d.rectangle([tx + sw, t_top + 2, tx + sw + 1, t_top + 6], fill=shirt if variant != 1 else SKIN)

    # Head
    hx = 12
    hy = 7 + bob_y
    d.rectangle([hx - 1, hy - 1, hx + 8, hy + 8], fill=C_OUTLINE)
    d.rectangle([hx, hy, hx + 7, hy + 7], fill=SKIN)
    d.rectangle([hx, hy, hx + 7, hy + 3], fill=hex_to_rgba("221a18"))
    d.point([(hx + 2, hy + 5), (hx + 5, hy + 5)], fill=C_OUTLINE)

    return img


def build_sheet(frames, cols, frame_w=32, frame_h=40):
    rows = (len(frames) + cols - 1) // cols
    sheet = Image.new("RGBA", (cols * frame_w, rows * frame_h), C_TRANS)
    for idx, f in enumerate(frames):
        c = idx % cols
        r = idx // cols
        sheet.paste(f, (c * frame_w, r * frame_h))
    return sheet


def generate_aluo_portraits():
    """Generates 3 dialogue expression portraits for Aluo (48x48 RGBA):
       - neutral: focused, determined
       - tired: breathless, panting, sweat drop, blushing
       - smile: cheerful, happy, grateful
    """
    base_dir = "assets/sprites/portraits"
    os.makedirs(base_dir, exist_ok=True)

    expressions = ["neutral", "tired", "smile"]
    for exp in expressions:
        img = Image.new("RGBA", (48, 48), C_TRANS)
        d = ImageDraw.Draw(img)

        # Background collar / hoodie shoulders
        d.rectangle([8, 30, 39, 47], fill=C_OUTLINE)
        d.rectangle([9, 31, 38, 47], fill=ALUO_RED)
        d.rectangle([9, 31, 13, 47], fill=ALUO_RED_DARK)
        d.rectangle([34, 31, 38, 47], fill=ALUO_RED_DARK)
        # Zipper / hoodie strings
        d.line([(24, 34), (24, 47)], fill=ALUO_RED_DARK, width=2)
        d.line([(18, 35), (18, 43)], fill=WHITE, width=1)
        d.line([(29, 35), (29, 43)], fill=WHITE, width=1)

        # Head & Face
        d.rectangle([13, 8, 34, 32], fill=C_OUTLINE)
        d.rectangle([14, 9, 33, 31], fill=SKIN)
        # Neck
        d.rectangle([20, 30, 27, 34], fill=SKIN_DARK)

        # Hair (Shaggy messy bangs)
        d.rectangle([14, 9, 33, 16], fill=ALUO_HAIR)
        d.rectangle([12, 13, 15, 26], fill=ALUO_HAIR)
        d.rectangle([32, 13, 35, 26], fill=ALUO_HAIR)
        d.rectangle([17, 16, 19, 20], fill=ALUO_HAIR)
        d.rectangle([23, 16, 25, 21], fill=ALUO_HAIR)
        d.rectangle([28, 16, 30, 19], fill=ALUO_HAIR)

        # Cyan earpiece indicator
        d.rectangle([11, 19, 13, 23], fill=ALUO_CYAN)
        d.point([(12, 20), (12, 21)], fill=ALUO_CYAN_GLOW)

        # Expression-specific features
        if exp == "neutral":
            # Focused determined eyes
            d.rectangle([17, 21, 20, 23], fill=C_OUTLINE)
            d.rectangle([27, 21, 30, 23], fill=C_OUTLINE)
            d.point([(18, 22), (28, 22)], fill=WHITE)
            # Eyebrows
            d.line([(17, 19), (21, 20)], fill=ALUO_HAIR, width=1)
            d.line([(27, 20), (31, 19)], fill=ALUO_HAIR, width=1)
            # Nose & small mouth
            d.point([(24, 25)], fill=SKIN_DARK)
            d.line([(22, 28), (25, 28)], fill=hex_to_rgba("aa5e5e"), width=1)
        elif exp == "tired":
            # Panting squinted eyes + sweat droplets + heavy flush
            d.line([(17, 22), (21, 23)], fill=C_OUTLINE, width=1)
            d.line([(27, 23), (31, 22)], fill=C_OUTLINE, width=1)
            # Cheeks flushed
            d.rectangle([16, 24, 20, 26], fill=SKIN_FLUSH)
            d.rectangle([27, 24, 31, 26], fill=SKIN_FLUSH)
            # Open panting mouth
            d.rectangle([22, 27, 26, 29], fill=hex_to_rgba("702828"))
            d.point([(23, 28), (24, 28)], fill=hex_to_rgba("e87a7a"))
            # Sweat drop on temple
            d.rectangle([32, 17, 33, 20], fill=ALUO_CYAN_GLOW)
            d.point([(32, 21)], fill=ALUO_CYAN)
        elif exp == "smile":
            # Happy smiling crescent eyes + beaming teeth + soft blush
            d.line([(17, 22), (19, 21), (21, 22)], fill=C_OUTLINE, width=1)
            d.line([(27, 22), (29, 21), (31, 22)], fill=C_OUTLINE, width=1)
            # Cheeks blush
            d.rectangle([16, 24, 19, 25], fill=SKIN_FLUSH)
            d.rectangle([28, 24, 31, 25], fill=SKIN_FLUSH)
            # Wide smile with white teeth
            d.rectangle([21, 27, 26, 29], fill=hex_to_rgba("8a3535"))
            d.line([(22, 27), (25, 27)], fill=WHITE, width=1)

        filename = "portrait_aluo.png" if exp == "neutral" else f"portrait_aluo_{exp}.png"
        path = os.path.join(base_dir, filename)
        img.save(path)
        print(f"Saved {path}")


def main():
    sprites_dir = "assets/sprites/characters"
    os.makedirs(sprites_dir, exist_ok=True)

    # 1. Coach Cheng Sheet (Cols: 6, Rows: 3)
    # Row 0: Idle A, Idle B, Walk Down 0..3
    # Row 1: Walk Up 0..3, Walk Left 0..1
    # Row 2: Walk Right 0..1, Guidance A, Guidance B, Success A, Success B
    cheng_frames = [
        draw_cheng_frame("idle", 0, "down"),
        draw_cheng_frame("idle", 1, "down"),
        draw_cheng_frame("walk", 0, "down"),
        draw_cheng_frame("walk", 1, "down"),
        draw_cheng_frame("walk", 2, "down"),
        draw_cheng_frame("walk", 3, "down"),

        draw_cheng_frame("walk", 0, "up"),
        draw_cheng_frame("walk", 1, "up"),
        draw_cheng_frame("walk", 2, "up"),
        draw_cheng_frame("walk", 3, "up"),
        draw_cheng_frame("walk", 0, "left"),
        draw_cheng_frame("walk", 1, "left"),

        draw_cheng_frame("walk", 0, "right"),
        draw_cheng_frame("walk", 1, "right"),
        draw_cheng_frame("guidance", 0, "down"),
        draw_cheng_frame("guidance", 1, "down"),
        draw_cheng_frame("success", 0, "down"),
        draw_cheng_frame("success", 1, "down"),
    ]
    cheng_sheet = build_sheet(cheng_frames, 6)
    cheng_path = os.path.join(sprites_dir, "coach_cheng_sheet.png")
    cheng_sheet.save(cheng_path)
    print(f"Saved {cheng_path} ({cheng_sheet.size})")

    # 2. Singer Aluo Sheet (Cols: 6, Rows: 3)
    # Row 0: Idle A, Idle B, Walk 0..3
    # Row 1: Treadmill Run 0..3, Yoga A, Yoga B
    # Row 2: Tired A, Tired B, Success A, Success B, Wait A, Wait B
    aluo_frames = [
        draw_aluo_frame("idle", 0, "down"),
        draw_aluo_frame("idle", 1, "down"),
        draw_aluo_frame("walk", 0, "down"),
        draw_aluo_frame("walk", 1, "down"),
        draw_aluo_frame("walk", 2, "down"),
        draw_aluo_frame("walk", 3, "down"),

        draw_aluo_frame("treadmill", 0, "right"),
        draw_aluo_frame("treadmill", 1, "right"),
        draw_aluo_frame("treadmill", 2, "right"),
        draw_aluo_frame("treadmill", 3, "right"),
        draw_aluo_frame("yoga", 0, "down"),
        draw_aluo_frame("yoga", 1, "down"),

        draw_aluo_frame("tired", 0, "down"),
        draw_aluo_frame("tired", 1, "down"),
        draw_aluo_frame("success", 0, "down"),
        draw_aluo_frame("success", 1, "down"),
        draw_aluo_frame("idle", 0, "right"),
        draw_aluo_frame("idle", 1, "right"),
    ]
    aluo_sheet = build_sheet(aluo_frames, 6)
    aluo_path = os.path.join(sprites_dir, "member_aluo_sheet.png")
    aluo_sheet.save(aluo_path)
    print(f"Saved {aluo_path} ({aluo_sheet.size})")

    # 3. Generic Member Sheet (Cols: 6, Rows: 4)
    generic_frames = []
    for var in range(4):
        generic_frames.extend([
            draw_generic_member_frame(var, "idle", 0),
            draw_generic_member_frame(var, "idle", 1),
            draw_generic_member_frame(var, "walk", 0),
            draw_generic_member_frame(var, "walk", 1),
            draw_generic_member_frame(var, "treadmill", 0),
            draw_generic_member_frame(var, "treadmill", 1),
        ])
    generic_sheet = build_sheet(generic_frames, 6)
    generic_path = os.path.join(sprites_dir, "member_generic_sheet.png")
    generic_sheet.save(generic_path)
    print(f"Saved {generic_path} ({generic_sheet.size})")

    # 4. Generate Aluo Portraits
    generate_aluo_portraits()

if __name__ == "__main__":
    main()
