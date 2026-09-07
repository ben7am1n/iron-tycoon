#!/usr/bin/env python3
"""
generate_npc_sheets.py
Generates native 32x40 pixel art sprite sheets for Gym Adventure key NPCs:
1. Boxer Qiu (老邱) - assets/sprites/characters/npc_qiu_sheet.png (192x120 RGBA)
2. Mechanic Lin (林师傅) - assets/sprites/characters/npc_lin_sheet.png (192x120 RGBA)

Follows the cozy pixel aesthetic, 32x40 frame size, 2-pixel dark outlines,
warm palette matching the 48x48 dialogue portraits.
"""

import os
from PIL import Image, ImageDraw

def hex_to_rgba(hex_str, alpha=255):
    h = hex_str.lstrip('#')
    return tuple(int(h[i:i+2], 16) for i in (0, 2, 4)) + (alpha,)

C_TRANS = (0, 0, 0, 0)
C_OUTLINE = hex_to_rgba("15181e")
WHITE = hex_to_rgba("ffffff")
WHITE_SHADOW = hex_to_rgba("cbd5e1")

# Lao Qiu Colors
QIU_SKIN = hex_to_rgba("d49a70")
QIU_SKIN_SHADOW = hex_to_rgba("af724a")
QIU_HAIR = hex_to_rgba("e2e8f0")
QIU_HAIR_SHADOW = hex_to_rgba("94a3b8")
QIU_WINE = hex_to_rgba("722f37")
QIU_WINE_DARK = hex_to_rgba("4a1d22")
QIU_WINE_LIGHT = hex_to_rgba("933845")
QIU_SHORTS = hex_to_rgba("1e293b")
QIU_TOWEL = hex_to_rgba("f8fafc")

# Lin Colors
LIN_SKIN = hex_to_rgba("e2aa82")
LIN_SKIN_SHADOW = hex_to_rgba("ba7d56")
LIN_HAT = hex_to_rgba("eab308")
LIN_HAT_DARK = hex_to_rgba("ca8a04")
LIN_GOGGLE_FRAME = hex_to_rgba("475569")
LIN_GOGGLE_CYAN = hex_to_rgba("38bdf8")
LIN_BLUE = hex_to_rgba("2563eb")
LIN_BLUE_DARK = hex_to_rgba("1d4ed8")
LIN_INNER_SHIRT = hex_to_rgba("f1f5f9")
LIN_BELT = hex_to_rgba("78350f")
LIN_BUCKLE = hex_to_rgba("f59e0b")
LIN_TOOL_METAL = hex_to_rgba("94a3b8")

def canvas():
    return Image.new("RGBA", (32, 40), C_TRANS)

# ==========================================
# 1. BOXER QIU (老邱) FRAMES
# ==========================================

def draw_qiu_idle(phase=0):
    img = canvas()
    d = ImageDraw.Draw(img)
    bob = 1 if phase == 1 else 0

    # 1. Broad grounded legs
    d.rectangle([9, 26, 14, 36], fill=C_OUTLINE)
    d.rectangle([10, 26, 13, 33], fill=QIU_SHORTS)
    d.rectangle([9, 34, 14, 36], fill=WHITE) # Left shoe

    d.rectangle([17, 26, 22, 36], fill=C_OUTLINE)
    d.rectangle([18, 26, 21, 33], fill=QIU_SHORTS)
    d.rectangle([17, 34, 22, 36], fill=WHITE) # Right shoe

    # 2. Broad Torso (14px wide)
    tx, ty = 8, 14 + bob
    d.rectangle([tx, ty, tx + 15, ty + 12], fill=C_OUTLINE)
    d.rectangle([tx + 1, ty + 1, tx + 14, ty + 11], fill=QIU_WINE)
    d.rectangle([tx + 1, ty + 7, tx + 14, ty + 11], fill=QIU_WINE_DARK)
    # Muscle tone lines
    d.line([(tx + 7, ty + 3), (tx + 8, ty + 3)], fill=QIU_WINE_LIGHT)

    # 3. Towel around neck / over left shoulder
    d.rectangle([tx + 2, ty + 1, tx + 5, ty + 10], fill=C_OUTLINE)
    d.rectangle([tx + 3, ty + 1, tx + 4, ty + 9], fill=QIU_TOWEL)

    # 4. Muscular arms at sides
    d.rectangle([tx - 2, ty + 2, tx, ty + 11], fill=C_OUTLINE)
    d.rectangle([tx - 1, ty + 3, tx, ty + 10], fill=QIU_SKIN)

    d.rectangle([tx + 15, ty + 2, tx + 17, ty + 11], fill=C_OUTLINE)
    d.rectangle([tx + 15, ty + 3, tx + 16, ty + 10], fill=QIU_SKIN)

    # 5. Head (Square jaw, white buzzcut)
    hx, hy = 11, 6 + bob
    d.rectangle([hx, hy, hx + 9, hy + 8], fill=C_OUTLINE)
    d.rectangle([hx + 1, hy + 1, hx + 8, hy + 7], fill=QIU_SKIN)
    # White buzzcut top & temples
    d.rectangle([hx + 1, hy, hx + 8, hy + 2], fill=QIU_HAIR)
    d.rectangle([hx, hy + 1, hx + 1, hy + 3], fill=QIU_HAIR)
    d.rectangle([hx + 8, hy + 1, hx + 9, hy + 3], fill=QIU_HAIR)
    # Weathered eyes & stubble
    d.point([(hx + 3, hy + 4), (hx + 6, hy + 4)], fill=C_OUTLINE)
    d.point([(hx + 3, hy + 6), (hx + 4, hy + 6), (hx + 5, hy + 6), (hx + 6, hy + 6)], fill=QIU_SKIN_SHADOW)

    return img

def draw_qiu_towel(phase=0):
    img = draw_qiu_idle(0)
    d = ImageDraw.Draw(img)
    # Right arm lifted to dab towel at temple
    if phase == 0:
        d.rectangle([21, 10, 25, 18], fill=C_OUTLINE)
        d.rectangle([22, 11, 24, 17], fill=QIU_SKIN)
        d.rectangle([20, 8, 24, 12], fill=QIU_TOWEL)
    else:
        d.rectangle([22, 8, 26, 16], fill=C_OUTLINE)
        d.rectangle([23, 9, 25, 15], fill=QIU_SKIN)
        d.rectangle([21, 6, 25, 10], fill=QIU_TOWEL)
    return img

def draw_qiu_counter_lean(phase=0):
    img = draw_qiu_idle(phase)
    d = ImageDraw.Draw(img)
    # Both arms folded forward resting on desk
    d.rectangle([9, 20, 22, 24], fill=C_OUTLINE)
    d.rectangle([10, 21, 21, 23], fill=QIU_SKIN)
    d.rectangle([12, 21, 14, 23], fill=QIU_SKIN_SHADOW)
    return img

def draw_qiu_walk(phase=0):
    img = canvas()
    d = ImageDraw.Draw(img)

    # Leg cycle
    if phase == 0:
        fl_y, fr_y = 36, 33
    elif phase == 1:
        fl_y, fr_y = 35, 35
    elif phase == 2:
        fl_y, fr_y = 33, 36
    else:
        fl_y, fr_y = 35, 35

    d.rectangle([9, 25, 14, fl_y], fill=C_OUTLINE)
    d.rectangle([10, 26, 13, fl_y - 2], fill=QIU_SHORTS)
    d.rectangle([9, fl_y - 1, 14, fl_y], fill=WHITE)

    d.rectangle([17, 25, 22, fr_y], fill=C_OUTLINE)
    d.rectangle([18, 26, 21, fr_y - 2], fill=QIU_SHORTS)
    d.rectangle([17, fr_y - 1, 22, fr_y], fill=WHITE)

    # Torso & Head
    tx, ty = 8, 14 + (1 if phase in [1, 3] else 0)
    d.rectangle([tx, ty, tx + 15, ty + 11], fill=C_OUTLINE)
    d.rectangle([tx + 1, ty + 1, tx + 14, ty + 10], fill=QIU_WINE)

    # Towel
    d.rectangle([tx + 2, ty + 1, tx + 5, ty + 9], fill=C_OUTLINE)
    d.rectangle([tx + 3, ty + 1, tx + 4, ty + 8], fill=QIU_TOWEL)

    # Arm swing
    arm_l_y = ty + (4 if phase < 2 else 1)
    arm_r_y = ty + (1 if phase < 2 else 4)
    d.rectangle([tx - 2, arm_l_y, tx, arm_l_y + 8], fill=C_OUTLINE)
    d.rectangle([tx - 1, arm_l_y + 1, tx, arm_l_y + 7], fill=QIU_SKIN)

    d.rectangle([tx + 15, arm_r_y, tx + 17, arm_r_y + 8], fill=C_OUTLINE)
    d.rectangle([tx + 15, arm_r_y + 1, tx + 16, arm_r_y + 7], fill=QIU_SKIN)

    # Head
    hx, hy = 11, ty - 8
    d.rectangle([hx, hy, hx + 9, hy + 8], fill=C_OUTLINE)
    d.rectangle([hx + 1, hy + 1, hx + 8, hy + 7], fill=QIU_SKIN)
    d.rectangle([hx + 1, hy, hx + 8, hy + 2], fill=QIU_HAIR)
    d.point([(hx + 3, hy + 4), (hx + 6, hy + 4)], fill=C_OUTLINE)

    return img

def draw_qiu_nod(phase=0):
    img = draw_qiu_idle(0)
    d = ImageDraw.Draw(img)
    # Nod motion: head dips, big warm smile, thumbs up / fist
    hx, hy = 11, 7 + phase
    d.rectangle([hx, hy, hx + 9, hy + 8], fill=C_OUTLINE)
    d.rectangle([hx + 1, hy + 1, hx + 8, hy + 7], fill=QIU_SKIN)
    d.rectangle([hx + 1, hy, hx + 8, hy + 2], fill=QIU_HAIR)
    # Closed eyes in approval
    d.line([(hx + 2, hy + 4), (hx + 4, hy + 4)], fill=C_OUTLINE)
    d.line([(hx + 5, hy + 4), (hx + 7, hy + 4)], fill=C_OUTLINE)
    # Smile
    d.line([(hx + 3, hy + 6), (hx + 6, hy + 6)], fill=C_OUTLINE)

    # Right hand raised with thumbs up / fist pump
    d.rectangle([23, 10, 27, 16], fill=C_OUTLINE)
    d.rectangle([24, 11, 26, 15], fill=QIU_SKIN)
    d.point([(25, 9)], fill=QIU_SKIN) # Thumb

    return img

def draw_qiu_assist(phase=0):
    img = draw_qiu_idle(0)
    d = ImageDraw.Draw(img)
    # Pointing forward / spotter coaching stance
    d.rectangle([22, 14, 29, 18], fill=C_OUTLINE)
    d.rectangle([23, 15, 28, 17], fill=QIU_SKIN)
    d.point([(29, 16)], fill=QIU_SKIN)
    return img

def draw_qiu_arms_crossed(phase=0):
    img = draw_qiu_idle(0)
    d = ImageDraw.Draw(img)
    # Both arms crossed over chest
    d.rectangle([8, 18, 23, 23], fill=C_OUTLINE)
    d.rectangle([9, 19, 22, 22], fill=QIU_SKIN)
    d.rectangle([13, 19, 18, 22], fill=QIU_WINE) # Folded sleeve overlap
    return img


# ==========================================
# 2. MECHANIC LIN (林师傅) FRAMES
# ==========================================

def draw_lin_idle(phase=0):
    img = canvas()
    d = ImageDraw.Draw(img)
    bob = 1 if phase == 1 else 0

    # 1. Legs in Cobalt Overalls
    d.rectangle([10, 26, 14, 36], fill=C_OUTLINE)
    d.rectangle([11, 26, 13, 34], fill=LIN_BLUE)
    d.rectangle([10, 35, 14, 36], fill=LIN_BELT) # Workboot

    d.rectangle([17, 26, 21, 36], fill=C_OUTLINE)
    d.rectangle([18, 26, 20, 34], fill=LIN_BLUE)
    d.rectangle([17, 35, 21, 36], fill=LIN_BELT)

    # 2. Torso (Overalls with brass buckles & inner shirt)
    tx, ty = 10, 15 + bob
    d.rectangle([tx, ty, tx + 11, ty + 11], fill=C_OUTLINE)
    d.rectangle([tx + 1, ty + 1, tx + 10, ty + 10], fill=LIN_INNER_SHIRT)
    # Overalls front bib & straps
    d.rectangle([tx + 2, ty + 4, tx + 9, ty + 10], fill=LIN_BLUE)
    d.rectangle([tx + 2, ty + 1, tx + 4, ty + 4], fill=LIN_BLUE)
    d.rectangle([tx + 7, ty + 1, tx + 9, ty + 4], fill=LIN_BLUE)
    # Buckles
    d.point([(tx + 3, ty + 4), (tx + 8, ty + 4)], fill=LIN_BUCKLE)

    # Toolbelt
    d.rectangle([tx, ty + 9, tx + 11, ty + 10], fill=LIN_BELT)

    # 3. Arms (One hand on hip, one holding wrench)
    # Left arm on hip
    d.line([(tx - 1, ty + 3), (tx - 1, ty + 9)], fill=C_OUTLINE, width=2)
    d.point([(tx - 1, ty + 8)], fill=LIN_SKIN)

    # Right arm holding wrench
    d.line([(tx + 12, ty + 3), (tx + 13, ty + 9)], fill=C_OUTLINE, width=2)
    d.point([(tx + 13, ty + 9)], fill=LIN_SKIN)
    # Wrench
    d.line([(tx + 13, ty + 6), (tx + 13, ty + 12)], fill=LIN_TOOL_METAL, width=2)
    d.rectangle([tx + 12, ty + 5, tx + 14, ty + 7], fill=LIN_TOOL_METAL)

    # 4. Head & Yellow Hardhat with Goggles
    hx, hy = 11, 7 + bob
    d.rectangle([hx, hy, hx + 9, hy + 8], fill=C_OUTLINE)
    d.rectangle([hx + 1, hy + 1, hx + 8, hy + 7], fill=LIN_SKIN)
    # Goggles on forehead
    d.rectangle([hx + 1, hy + 1, hx + 8, hy + 3], fill=LIN_GOGGLE_FRAME)
    d.point([(hx + 3, hy + 2), (hx + 6, hy + 2)], fill=LIN_GOGGLE_CYAN)
    # Yellow Hardhat on top
    d.rectangle([hx - 1, hy - 2, hx + 10, hy + 1], fill=C_OUTLINE)
    d.rectangle([hx, hy - 1, hx + 9, hy], fill=LIN_HAT)
    d.rectangle([hx + 2, hy - 2, hx + 7, hy - 1], fill=LIN_HAT)

    # Friendly eyes & mustache
    d.point([(hx + 3, hy + 4), (hx + 6, hy + 4)], fill=C_OUTLINE)
    d.line([(hx + 3, hy + 6), (hx + 6, hy + 6)], fill=C_OUTLINE)

    return img

def draw_lin_scratch_head(phase=0):
    img = draw_lin_idle(phase)
    d = ImageDraw.Draw(img)
    # Left hand reaching up to tip hardhat
    d.rectangle([8, 6, 11, 14], fill=C_OUTLINE)
    d.rectangle([9, 7, 10, 13], fill=LIN_SKIN)
    return img

def draw_lin_wipe_brow(phase=0):
    img = draw_lin_idle(phase)
    d = ImageDraw.Draw(img)
    # White cloth dabbing brow
    d.rectangle([13, 8, 17, 12], fill=WHITE)
    d.rectangle([14, 9, 16, 11], fill=WHITE_SHADOW)
    return img

def draw_lin_walk(phase=0):
    img = canvas()
    d = ImageDraw.Draw(img)

    fl_y = 36 if phase == 0 else (33 if phase == 2 else 35)
    fr_y = 33 if phase == 0 else (36 if phase == 2 else 35)

    d.rectangle([10, 25, 14, fl_y], fill=C_OUTLINE)
    d.rectangle([11, 26, 13, fl_y - 2], fill=LIN_BLUE)
    d.rectangle([10, fl_y - 1, 14, fl_y], fill=LIN_BELT)

    d.rectangle([17, 25, 21, fr_y], fill=C_OUTLINE)
    d.rectangle([18, 26, 20, fr_y - 2], fill=LIN_BLUE)
    d.rectangle([17, fr_y - 1, 21, fr_y], fill=LIN_BELT)

    tx, ty = 10, 15 + (1 if phase in [1, 3] else 0)
    d.rectangle([tx, ty, tx + 11, ty + 10], fill=C_OUTLINE)
    d.rectangle([tx + 1, ty + 1, tx + 10, ty + 9], fill=LIN_BLUE)

    # Swing arms & toolbox
    arm_l_y = ty + (4 if phase < 2 else 1)
    d.rectangle([tx - 2, arm_l_y, tx, arm_l_y + 7], fill=C_OUTLINE)
    d.rectangle([tx - 1, arm_l_y + 1, tx, arm_l_y + 6], fill=LIN_SKIN)

    # Right hand carrying small red toolbox
    arm_r_y = ty + (1 if phase < 2 else 4)
    d.rectangle([tx + 11, arm_r_y, tx + 13, arm_r_y + 7], fill=C_OUTLINE)
    d.rectangle([tx + 12, arm_r_y + 5, tx + 17, arm_r_y + 10], fill=hex_to_rgba("b91c1c")) # Toolbox

    # Head & Hardhat
    hx, hy = 11, ty - 8
    d.rectangle([hx, hy, hx + 9, hy + 8], fill=C_OUTLINE)
    d.rectangle([hx + 1, hy + 1, hx + 8, hy + 7], fill=LIN_SKIN)
    d.rectangle([hx - 1, hy - 2, hx + 10, hy], fill=LIN_HAT)
    d.point([(hx + 3, hy + 4), (hx + 6, hy + 4)], fill=C_OUTLINE)

    return img

def draw_lin_repair(phase=0):
    img = canvas()
    d = ImageDraw.Draw(img)

    # Kneeling posture (lowered to y=20..36)
    # Legs folded
    d.rectangle([8, 30, 22, 36], fill=C_OUTLINE)
    d.rectangle([9, 31, 21, 35], fill=LIN_BLUE)
    d.rectangle([7, 34, 11, 36], fill=LIN_BELT)

    # Leaning forward torso
    tx, ty = 11, 21
    d.rectangle([tx, ty, tx + 12, ty + 9], fill=C_OUTLINE)
    d.rectangle([tx + 1, ty + 1, tx + 11, ty + 8], fill=LIN_BLUE)

    # Arm with wrench working on machinery at right (x=24..28, y=20..26)
    w_y = 23 + (1 if phase == 1 else 0)
    d.line([(tx + 10, ty + 3), (24, w_y)], fill=C_OUTLINE, width=3)
    d.line([(tx + 10, ty + 3), (24, w_y)], fill=LIN_SKIN, width=1)
    # Wrench tightening
    d.rectangle([24, w_y - 2, 28, w_y + 2], fill=LIN_TOOL_METAL)
    # Sparks / contact highlight
    if phase == 1:
        d.point([(28, w_y - 3), (29, w_y - 1)], fill=hex_to_rgba("fef08a"))

    # Head looking down at machine
    hx, hy = 14, 13
    d.rectangle([hx, hy, hx + 8, hy + 8], fill=C_OUTLINE)
    d.rectangle([hx + 1, hy + 1, hx + 7, hy + 7], fill=LIN_SKIN)
    d.rectangle([hx - 1, hy - 2, hx + 9, hy], fill=LIN_HAT)
    d.point([(hx + 5, hy + 5)], fill=C_OUTLINE) # Eye looking down

    return img

def draw_lin_hammer(phase=0):
    img = draw_lin_repair(0)
    d = ImageDraw.Draw(img)
    # Small mallet raised / striking
    ham_y = 16 if phase == 0 else 22
    d.rectangle([24, ham_y, 27, ham_y + 4], fill=LIN_TOOL_METAL)
    d.line([(22, 23), (25, ham_y + 2)], fill=LIN_BELT, width=2)
    return img

def draw_lin_thumbs_up(phase=0):
    img = draw_lin_idle(0)
    d = ImageDraw.Draw(img)
    # Broad smile + high thumbs up
    hx, hy = 11, 7
    d.rectangle([hx + 3, hy + 6, hx + 6, hy + 7], fill=WHITE) # Bright grin

    # Right arm high thumbs up
    d.rectangle([23, 8, 27, 15], fill=C_OUTLINE)
    d.rectangle([24, 9, 26, 14], fill=LIN_SKIN)
    d.point([(25, 7)], fill=LIN_SKIN) # Thumb pointing up
    return img


def build_sheet(frames, cols=6, rows=3):
    sheet = Image.new("RGBA", (cols * 32, rows * 40), C_TRANS)
    for idx, f in enumerate(frames):
        c = idx % cols
        r = idx // cols
        sheet.paste(f, (c * 32, r * 40))
    return sheet

def main():
    out_dir = "assets/sprites/characters"
    os.makedirs(out_dir, exist_ok=True)

    # 1. Boxer Qiu Sheet (192x120)
    # Row 0: Idle 0..1, Towel 0..1, Counter Lean 0..1
    # Row 1: Walk 0..3, Idle Look 0..1
    # Row 2: Nod / Thumbs 0..1, Assist 0..1, Arms Crossed 0..1
    qiu_frames = [
        draw_qiu_idle(0), draw_qiu_idle(1),
        draw_qiu_towel(0), draw_qiu_towel(1),
        draw_qiu_counter_lean(0), draw_qiu_counter_lean(1),

        draw_qiu_walk(0), draw_qiu_walk(1), draw_qiu_walk(2), draw_qiu_walk(3),
        draw_qiu_idle(0), draw_qiu_idle(1),

        draw_qiu_nod(0), draw_qiu_nod(1),
        draw_qiu_assist(0), draw_qiu_assist(1),
        draw_qiu_arms_crossed(0), draw_qiu_arms_crossed(1),
    ]
    sheet_qiu = build_sheet(qiu_frames)
    qiu_path = os.path.join(out_dir, "npc_qiu_sheet.png")
    sheet_qiu.save(qiu_path)
    print(f"Saved {qiu_path} ({sheet_qiu.size})")

    # 2. Mechanic Lin Sheet (192x120)
    # Row 0: Idle 0..1, Scratch Head 0..1, Wipe Brow 0..1
    # Row 1: Walk 0..3, Side Look 0..1
    # Row 2: Repair 0..1, Hammer 0..1, Thumbs Up 0..1
    lin_frames = [
        draw_lin_idle(0), draw_lin_idle(1),
        draw_lin_scratch_head(0), draw_lin_scratch_head(1),
        draw_lin_wipe_brow(0), draw_lin_wipe_brow(1),

        draw_lin_walk(0), draw_lin_walk(1), draw_lin_walk(2), draw_lin_walk(3),
        draw_lin_idle(0), draw_lin_idle(1),

        draw_lin_repair(0), draw_lin_repair(1),
        draw_lin_hammer(0), draw_lin_hammer(1),
        draw_lin_thumbs_up(0), draw_lin_thumbs_up(1),
    ]
    sheet_lin = build_sheet(lin_frames)
    lin_path = os.path.join(out_dir, "npc_lin_sheet.png")
    sheet_lin.save(lin_path)
    print(f"Saved {lin_path} ({sheet_lin.size})")

if __name__ == "__main__":
    main()
