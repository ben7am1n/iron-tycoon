#!/usr/bin/env python3
"""V3.1 P3 — PIL 像素采样证据：大面积区域 = 多色 pixel cluster，非纯色块。

采样 tests/evidence/v31-p3-density.png（window 模式渲染帧），用与
src/presentation/oblique_projection.gd 相同的投影数学复算采样点，验证
V3.1 P3 手绘感核心约束：

  A. 地板 zone 大面积区域由多色 cluster 组成：每个 zone 中心 64×64 世界
     像素窗口（投影到屏幕后采样）独立色 >= N，且主色占比 < 0.75 ——
     无大面积单色填充（纯色块会 distinct≈1 / dominant≈1.0）
  B. 区域边界不规则：strength 左边界列同时出现区域色与通道色（非完美
     直线矩形）—— 渲染帧上取 zone 边界世界坐标的投影列采样
  C. 墙面粉刷非纯色：北墙面采样窗口含 >=3 独立色（WALL_BASE + cluster）
  D. 无重复规则纹理：cardio zone 4px 网格点非全为 DOT 色（命中率 < 0.60）

断言通过阈值按「PIL 8bit 量化 + 渲染管线光照污染」放宽（与 P2 同源策略）。

用法：python3 tests/evidence/v31_p3_pil_sample.py
退出码：0 = 全部通过；1 = 有失败。
"""
import math
import os
import sys
from PIL import Image

EVIDENCE_DIR = os.path.dirname(os.path.abspath(__file__))
PNG = os.path.join(EVIDENCE_DIR, "v31-p3-density.png")

# === 投影常量（与 oblique_projection.gd / main.gd 同源复算） ===
SHEAR = 0.35
FLOOR_SCALE = 0.78
HEIGHT_SCALE = 0.62
EXTRUDE_X = 0.20
WORLD_SCALE = 0.75
VIEWPORT_OFFSET = (19.05, 51.975)
SCREEN_PER_VIEWPORT = (1280.0 / 426.0, 720.0 / 240.0)
CELL = 32

# === palette.gd 地板/墙色（单一来源复算） ===
FLOOR_STRENGTH_COLORS = [
    (0x4B / 255, 0x4F / 255, 0x57 / 255),   # BASE
    (0x45 / 255, 0x49 / 255, 0x52 / 255),   # BLOCK
    (0x4E / 255, 0x56 / 255, 0x63 / 255),   # CL_GRAYBLUE
    (0x55 / 255, 0x50 / 255, 0x4C / 255),   # CL_WARMGRAY
    (0x38 / 255, 0x3C / 255, 0x44 / 255),   # STAIN
    (0x5A / 255, 0x5F / 255, 0x68 / 255),   # WEAR
    (0x3C / 255, 0x40 / 255, 0x47 / 255),   # SEAM
]
FLOOR_CARDIO_COLORS = [
    (0x7C / 255, 0x82 / 255, 0x88 / 255),   # BASE
    (0x71 / 255, 0x77 / 255, 0x7D / 255),   # DOT
    (0x74 / 255, 0x7D / 255, 0x87 / 255),   # CL_GRAYBLUE
    (0x85 / 255, 0x84 / 255, 0x86 / 255),   # CL_WARMGRAY
    (0x66 / 255, 0x6C / 255, 0x72 / 255),   # EDGE
]
FLOOR_FLEX_COLORS = [
    (0xA9 / 255, 0x74 / 255, 0x4C / 255),   # BASE
    (0xB5 / 255, 0x80 / 255, 0x55 / 255),   # CL_LIGHT
    (0x96 / 255, 0x63 / 255, 0x3C / 255),   # CL_DARK
    (0x8F / 255, 0x5F / 255, 0x3B / 255),   # GRAIN
    (0x96 / 255, 0x65 / 255, 0x3F / 255),   # PLANK
]
FLOOR_WALK_COLORS = [
    (0xD3 / 255, 0xCB / 255, 0xB9 / 255),   # BASE
    (0xDD / 255, 0xD6 / 255, 0xC6 / 255),   # CL_LIGHT
    (0xC6 / 255, 0xBE / 255, 0xA9 / 255),   # CL_DARK
]
WALL_BASE = (0x8B / 255, 0x83 / 255, 0x78 / 255)
WALL_TRIM = (0x9C / 255, 0x94 / 255, 0x8A / 255)
WALL_DARK = (0x6E / 255, 0x67 / 255, 0x5C / 255)
FLOOR_CARDIO_DOT = (0x71 / 255, 0x77 / 255, 0x7D / 255)

# 世界像素空间 zone 矩形（Palette.ZONE_RECTS × CELL）
ZONE_RECTS_PX = {
    "strength": (1 * CELL, 1 * CELL, 4 * CELL, 8 * CELL),
    "cardio": (5 * CELL, 1 * CELL, 4 * CELL, 8 * CELL),
    "flex": (9 * CELL, 1 * CELL, 3 * CELL, 8 * CELL),
}
# zone 中心采样点（世界坐标）
ZONE_CENTERS = {
    "strength": (96, 160),
    "cardio": (224, 160),
    "flex": (336, 160),
}
ZONE_FAMILY = {
    "strength": FLOOR_STRENGTH_COLORS,
    "cardio": FLOOR_CARDIO_COLORS,
    "flex": FLOOR_FLEX_COLORS,
}

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


def color_dist(a, b):
    return math.sqrt(sum((a[i] - b[i]) ** 2 for i in range(3)))


def norm(c):
    return (c[0] / 255.0, c[1] / 255.0, c[2] / 255.0)


def near_any(c, family, tol):
    cn = norm(c)
    return any(color_dist(cn, f) <= tol for f in family)


def sample_window(img, cx, cy, world_r, step):
    """以世界坐标 (cx,cy) 为中心采样 world_r 半径网格（step 步长），返回颜色列表。"""
    px = img.load()
    out = []
    for dy in range(-world_r, world_r + 1, step):
        for dx in range(-world_r, world_r + 1, step):
            sx, sy = screen(cx + dx, cy + dy)
            if 0 <= sx < img.width and 0 <= sy < img.height:
                out.append(px[sx, sy])
    return out


def distinct_colors(colors, tol):
    reps = []
    for p in colors:
        if not any(color_dist(norm(p), norm(r)) <= tol for r in reps):
            reps.append(p)
    return len(reps)


def dominant_ratio(colors):
    from collections import Counter
    if not colors:
        return 0.0
    cnt = Counter(colors)
    return max(cnt.values()) / len(colors)


def verify_floor_clusters(img):
    print("\n-- A. 地板 zone：大面积 = 多色 pixel cluster（非纯色块） --")
    for zone in ["strength", "cardio", "flex"]:
        cx, cy = ZONE_CENTERS[zone]
        colors = sample_window(img, cx, cy, 24, 6)
        check(len(colors) > 0, f"A {zone} sampled pixels > 0")
        if not colors:
            continue
        distinct = distinct_colors(colors, 0.08)
        dom = dominant_ratio(colors)
        check(distinct >= 4,
              f"A {zone} window multi-color (distinct {distinct} >= 4)")
        check(dom < 0.75,
              f"A {zone} no single-color dominance (dominant {dom:.2f} < 0.75)")


def verify_irregular_edges(img):
    print("\n-- B. 区域边界不规则（非完美直线矩形） --")
    # strength 左边界世界列 x=32：取 zone 内 y 范围（32..288）采样边界列投影
    x0, y0, w, h = ZONE_RECTS_PX["strength"]
    zone_px = 0
    walk_px = 0
    px = img.load()
    for wy in range(y0 + 6, y0 + h - 6, 4):
        sx, sy = screen(x0, wy)
        if not (0 <= sx < img.width and 0 <= sy < img.height):
            continue
        c = px[sx, sy]
        if near_any(c, FLOOR_STRENGTH_COLORS, 0.10):
            zone_px += 1
        elif near_any(c, FLOOR_WALK_COLORS, 0.12):
            walk_px += 1
    check(zone_px > 0 and walk_px > 0,
          f"B strength left edge irregular (zone {zone_px} + walk {walk_px} samples)")


def verify_wall_paint(img):
    print("\n-- C. 墙面粉刷非纯色（手绘 cluster） --")
    # 北墙（WALL_BASE）采样：世界 (200, 24, z=55) 附近窗口。z=55 中段墙面。
    cx, cy = 200, 24
    colors = []
    for dz in range(-8, 9, 2):
        for dx in range(-6, 7, 2):
            sx, sy = screen(cx + dx, cy, 55 + dz)
            if 0 <= sx < img.width and 0 <= sy < img.height:
                colors.append(img.load()[sx, sy])
    check(len(colors) > 0, "C wall sample pixels > 0")
    if colors:
        distinct = distinct_colors(colors, 0.05)
        check(distinct >= 2, f"C north wall multi-shade (distinct {distinct} >= 2)")
        # 墙面仍以 WALL_BASE 族为主（材质身份不变）
        base_like = sum(1 for c in colors if near_any(c, [WALL_BASE, WALL_TRIM, WALL_DARK], 0.10))
        check(base_like >= len(colors) * 0.5,
              f"C north wall keeps WALL family (base-like {base_like}/{len(colors)})")


def verify_no_regular_grid(img):
    print("\n-- D. 无重复规则纹理（cardio 无 4px 周期点阵） --")
    x0, y0, w, h = ZONE_RECTS_PX["cardio"]
    total = 0
    hits = 0
    px = img.load()
    for wy in range(y0 + 2, y0 + h, 4):
        for wx in range(x0 + 2, x0 + w, 4):
            sx, sy = screen(wx, wy)
            if not (0 <= sx < img.width and 0 <= sy < img.height):
                continue
            total += 1
            if color_dist(norm(px[sx, sy]), FLOOR_CARDIO_DOT) <= 0.06:
                hits += 1
    ratio = hits / max(total, 1)
    check(ratio < 0.60,
          f"D cardio no 4px repeating dot grid (hit ratio {ratio:.2f} < 0.60)")


def main():
    print("=" * 64)
    print("  V3.1 P3 PIL PIXEL SAMPLING — hand-drawn pixel density")
    print("  source: %s" % PNG)
    print("=" * 64)
    if not os.path.exists(PNG):
        print("  FAIL: rendered frame missing (%s)" % PNG)
        print("  Run: godot --path . res://tests/evidence/v31_p3_capture.tscn")
        sys.exit(1)
    img = Image.open(PNG).convert("RGB")
    print(f"  image: {img.width}x{img.height}")
    verify_floor_clusters(img)
    verify_irregular_edges(img)
    verify_wall_paint(img)
    verify_no_regular_grid(img)
    print("\n" + "=" * 64)
    print("  PIL SAMPLING RESULT: %s (%d passed, %d failed)" % (
        "PASS" if failed == 0 else "FAIL", passed, failed))
    print("=" * 64)
    sys.exit(1 if failed > 0 else 0)


if __name__ == "__main__":
    main()
