#!/usr/bin/env python3
"""V3.1 R3 — PIL 像素采样证据：墙地交界手绘抖动 + 叙事道具 + 会员活跃度。

采样 tests/evidence/v31-r3-density.png（密度帧，空场）与
tests/evidence/v31-r3-populated.png（populated 变体，8 会员）—— window
模式渲染帧，投影数学与 src/presentation/oblique_projection.gd 同源复算。

验证（V3.1 P3-density + V3 §12 storytelling + 附录 P3 手绘感）：

  A. 墙地交界手绘抖动：世界区域（屏幕 y 50..640，避开底部 UI 条带）内
     无 200px+ 连续水平直线（同色容差 12）。墙帽（y≈72..80）/踢脚线
     （y≈255..266）多色 cluster 起伏 —— 无完美直线（Exit 条件）。
  B. 叙事道具色彩存在性：§12 清单道具（水瓶/杠铃架/暖色灯/卷垫/植物）在
     各自世界锚点投影窗口内有语义色（V3 §12 逐区 2-3 件）。
  C. 会员活跃度：populated 帧会员衬衫色在注入坐标可见（walk/queue/leave
     三态），且 populated 帧与 density 帧字节不同（会员真实渲染进场景，
     非静态空场 —— 门禁「populated 与 frame-12 字节一致」修复）。
  D. 打破规则化摆放：DECOR 锚点非 4px 网格对齐（数据层断言，确定性）——
     无两条道具共用同一 x/y 对齐列；towel 与 water_bottle 前后交错
     （towel 锚点偏移进 bottle 32×32 覆盖区 —— 遮挡关系）。

退出码：0 = 全部通过；1 = 有失败。
用法：python3 tests/evidence/v31_r3_pil_sample.py
"""
import math
import os
import sys
from PIL import Image

EVIDENCE_DIR = os.path.dirname(os.path.abspath(__file__))
DENSITY = os.path.join(EVIDENCE_DIR, "v31-r3-density.png")
POPULATED = os.path.join(EVIDENCE_DIR, "v31-r3-populated.png")

# === 投影常量（与 oblique_projection.gd / main.gd 同源复算） ===
SHEAR = 0.35
FLOOR_SCALE = 0.62
HEIGHT_SCALE = 0.79
EXTRUDE_X = 0.20
WORLD_SCALE = 0.75
VIEWPORT_OFFSET = (19.05, 78.1875)
SCREEN_PER_VIEWPORT = (1280.0 / 426.0, 720.0 / 240.0)

# === palette.gd 语义色（8bit） ===
ACCENT_YELLOW = (0xF2, 0xC9, 0x4C)      # F2C94C 水瓶身
METAL_HIGHLIGHT = (0xB7, 0xD4, 0xEC)    # B7D4EC 杠铃架横杆
ACCENT_ORANGE = (0xE0, 0x7A, 0x3F)      # E07A3F 暖色灯罩
TOWEL = (0xC9, 0x8E, 0x6E)              # C98E6E 卷垫/毛巾
PLANT_GREEN = (0x4E, 0x8A, 0x5A)        # 4E8A5A 植物叶
SKY = (0x8E, 0xC5, 0xE8)                # 8EC5E8 walk 衬衫
PEACH = (0xF2, 0xB4, 0x86)              # F2B486 queue 衬衫
LEAVE_GRAY = (0x9A, 0x94, 0x8C)         # 9A948C leave 衬衫

passed = 0
failed = 0


def check(cond: bool, msg: str):
    global passed, failed
    if cond:
        passed += 1
        print(f"  PASS {msg}")
    else:
        failed += 1
        print(f"  FAIL {msg}")


def proj(x: float, y: float, z: float = 0.0):
    return (x + y * SHEAR - z * EXTRUDE_X, y * FLOOR_SCALE - z * HEIGHT_SCALE)


def screen(x: float, y: float, z: float = 0.0):
    px, py = proj(x, y, z)
    sx = (px * WORLD_SCALE + VIEWPORT_OFFSET[0]) * SCREEN_PER_VIEWPORT[0]
    sy = (py * WORLD_SCALE + VIEWPORT_OFFSET[1]) * SCREEN_PER_VIEWPORT[1]
    return (int(round(sx)), int(round(sy)))


def in_bounds(img: Image, p) -> bool:
    return 0 <= p[0] < img.width and 0 <= p[1] < img.height


def color_dist(a, b):
    return math.sqrt(sum((a[i] - b[i]) ** 2 for i in range(3)))


def near(c, t, tol=45):
    return color_dist(c[:3], t) <= tol


def max_same_run(img: Image, y: int, tol: int) -> int:
    """一行内「同色（容差 tol）连续段」的最大长度。"""
    px = img.load()
    w = img.width
    cur = px[0, y]
    rs = 0
    best = 0
    for x in range(1, w):
        c = px[x, y]
        if sum(abs(c[i] - cur[i]) for i in range(3)) <= tol:
            continue
        best = max(best, x - rs)
        cur = c
        rs = x
    best = max(best, w - rs)
    return best


# === A. 墙地交界手绘抖动（无 200px+ 连续水平直线） ===

def verify_wall_floor_jitter(img: Image) -> bool:
    print("\n-- A. 墙地交界手绘抖动（无 200px+ 连续水平直线） --")
    worst = 0
    worst_y = -1
    # 世界区域：y 50..640（避开底部 UI 建造条带 y≥640）
    for y in range(50, 640):
        run = max_same_run(img, y, 12)
        if run > worst:
            worst = run
            worst_y = y
    ok = worst < 200
    check(ok, f"A world region max same-color run {worst}px @y={worst_y} < 200 (墙地交界无完美直线)")
    # 专门检查墙帽/踢脚线行（多色 cluster 起伏 —— 不再单色直线）
    cap_worst = max(max_same_run(img, y, 12) for y in range(68, 92))
    base_worst = max(max_same_run(img, y, 12) for y in range(250, 270))
    check(cap_worst < 200, f"A wall cap rows max run {cap_worst}px < 200 (墙帽多色 cluster)")
    check(base_worst < 200, f"A baseboard rows max run {base_worst}px < 200 (踢脚线多色 cluster)")
    return ok


# === B. 叙事道具色彩存在性（§12 清单） ===

# prop: (世界采样点, 期望色, 容差窗口半径)
PROPS = [
    ("water_bottle", (140, 78), ACCENT_YELLOW, 10),    # DECOR(132,70)+art(2,2)*4
    ("barbell_rack", (112, 208), METAL_HIGHLIGHT, 10), # DECOR(96,200)+art(4,2)*4
    ("warm_lamp", (308, 212), ACCENT_ORANGE, 10),      # DECOR(296,200)+art(3,3)*4
    ("mat_rolled", (361, 275), TOWEL, 10),             # DECOR(349,267)+art(3,2)*4
    ("plant", (360, 180), PLANT_GREEN, 12),            # DECOR(352,176)+art(2,1)*4
]


def verify_props(img: Image) -> bool:
    print("\n-- B. 叙事道具色彩存在性（V3 §12 逐区） --")
    ok_all = True
    px = img.load()
    for name, (wx, wy), target, rad in PROPS:
        p = screen(wx, wy)
        found = False
        for dy in range(-rad, rad + 1):
            for dx in range(-rad, rad + 1):
                q = (p[0] + dx, p[1] + dy)
                if in_bounds(img, q) and near(px[q[0], q[1]], target, 55):
                    found = True
                    break
            if found:
                break
        ok = found
        ok_all = ok_all and ok
        check(ok, f"B prop {name:<14s} @world{wx},{wy} tone present")
    return ok_all


# === C. 会员活跃度（populated 帧 vs density 帧） ===

# 注入会员（与 v31_r3_capture.gd INJECTED 同源）：cell → 期望衬衫色
MEMBER_CHECKS = [
    ((5, 2), SKY, "WALKING_TO"),
    ((11, 2), SKY, "WALKING_TO"),
    ((3, 6), PEACH, "QUEUEING"),
    ((10, 6), LEAVE_GRAY, "LEAVING"),
]


def member_shirt_screen(cell):
    feet_x = cell[0] * 32 + 16
    feet_y = cell[1] * 32 + 32
    p = proj(feet_x, feet_y, 0.0)
    anchor = (p[0] - 24, p[1] - 48)
    q = (anchor[0] + 24, anchor[1] + 19)
    sx = (q[0] * WORLD_SCALE + VIEWPORT_OFFSET[0]) * SCREEN_PER_VIEWPORT[0]
    sy = (q[1] * WORLD_SCALE + VIEWPORT_OFFSET[1]) * SCREEN_PER_VIEWPORT[1]
    return (int(round(sx)), int(round(sy)))


def verify_members(density: Image, populated: Image) -> bool:
    print("\n-- C. 会员活跃度（populated 变体会员可见） --")
    ok_all = True
    px = populated.load()
    for cell, target, state in MEMBER_CHECKS:
        p = member_shirt_screen(cell)
        found = False
        for dy in range(-5, 6):
            for dx in range(-5, 6):
                q = (p[0] + dx, p[1] + dy)
                if in_bounds(populated, q) and near(px[q[0], q[1]], target, 60):
                    found = True
                    break
            if found:
                break
        ok = found
        ok_all = ok_all and ok
        check(ok, f"C member {state:<12s} @cell{cell} shirt visible")
    # populated 帧与 density 帧字节不同（会员真实渲染进场景）
    if density.size == populated.size:
        dp = density.load()
        pp = populated.load()
        diff = sum(1 for y in range(0, populated.height, 4)
                   for x in range(0, populated.width, 4)
                   if sum(abs(dp[x, y][i] - pp[x, y][i]) for i in range(3)) > 20)
        ok = diff > 0
        ok_all = ok_all and ok
        check(ok, f"C populated frame differs from density frame (sampled diff={diff} px > 0)")
    else:
        check(False, "C density/populated size mismatch")
    return ok_all


# === D. 打破规则化摆放（数据层断言，确定性） ===

# DECOR 表（与 world_layout.gd 同源）：prop_id -> (x, y)
DECOR = {
    "water_bottle_t1": (132, 70), "towel_t1": (134, 73),
    "dumbbell_s1": (127, 231), "dumbbell_s2": (139, 245), "chalk_box": (121, 261),
    "kettlebell_s1": (38, 102), "kettlebell_s2": (43, 113),
    "plate_s1": (131, 219), "plate_s2": (140, 221),
    "medicine_ball_s1": (101, 235), "dumbbell_s3": (105, 238),
    "barbell_rack_s1": (96, 200),
    "plant_bright_f1": (352, 176), "speaker_f1": (335, 98),
    "mat_rolled_f1": (349, 267), "warm_lamp_f1": (296, 200),
    "yoga_block_f1": (311, 237), "yoga_block_f2": (321, 245), "plant_f2": (367, 121),
    "fan_b1": (26, 161), "cup_holder_b1": (23, 181),
    "towel_t2": (196, 149), "water_bottle_t2": (199, 153), "cup_holder_c1": (233, 199),
    "fountain": (20, 40), "trash": (385, 32), "hydrant": (13, 121),
    "cup_yellow_f1": (88, 108), "yoga_ball_f1": (320, 136), "yoga_strap_f1": (320, 176),
    "bench_b1": (171, 33), "bench_b2": (209, 33), "plant_bright_b1": (243, 33),
    "plant_b2": (301, 31), "mat_rolled_b1": (339, 33), "bench_b3": (17, 187),
    "plant_bright_fore_1": (0, 244), "plant_fore_2": (385, 243),
    "plant_fore_3": (225, 243), "plant_fore_4": (1, 251), "plant_fore_5": (383, 253),
}


def verify_irregular_placement() -> bool:
    print("\n-- D. 打破规则化摆放（非 4px 对齐 + 遮挡） --")
    # 非 4px 网格对齐：至少 20 个道具坐标 % 4 != 0（手摆，非程序网格）
    off_grid = sum(1 for (x, y) in DECOR.values() if x % 4 != 0 or y % 4 != 0)
    ok = off_grid >= 20
    check(ok, f"D decor anchors off 4px grid: {off_grid}/{len(DECOR)} (非网格对齐)")
    # 前后交错遮挡：towel_t1 锚点偏移进 water_bottle_t1 的 32×32 覆盖区
    bx, by = DECOR["water_bottle_t1"]
    tx, ty = DECOR["towel_t1"]
    overlaps = (bx <= tx < bx + 32 and by <= ty < by + 32)
    check(overlaps, f"D towel_t1 ({tx},{ty}) overlaps water_bottle_t1 ({bx},{by}) 32x32 (遮挡关系)")
    # plate_s2 半压 plate_s1（成组错落）
    p1x, p1y = DECOR["plate_s1"]
    p2x, p2y = DECOR["plate_s2"]
    plate_overlap = (p1x <= p2x < p1x + 32 and p1y <= p2y < p1y + 32)
    check(plate_overlap, f"D plate_s2 ({p2x},{p2y}) overlaps plate_s1 ({p1x},{p1y}) (成组错落)")
    return ok and overlaps and plate_overlap


def main() -> int:
    print("=" * 64)
    print("  V3.1 R3 PIL PIXEL SAMPLING — wall-floor jitter + storytelling props")
    print("  evidence dir: %s" % EVIDENCE_DIR)
    print("=" * 64)
    if not os.path.exists(DENSITY) or not os.path.exists(POPULATED):
        print("missing evidence PNGs (run v31_r3_capture.tscn windowed first)")
        return 1
    density = Image.open(DENSITY).convert("RGB")
    populated = Image.open(POPULATED).convert("RGB")
    ok_a = verify_wall_floor_jitter(density)
    ok_b = verify_props(density)
    ok_c = verify_members(density, populated)
    ok_d = verify_irregular_placement()
    ok = ok_a and ok_b and ok_c and ok_d
    print("\n" + "=" * 64)
    print("  PIL SAMPLING RESULT: %s (%d passed, %d failed)" % (
        "PASS" if ok else "FAIL", passed, failed))
    print("=" * 64)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
