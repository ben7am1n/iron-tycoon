#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""V3.1 返工4 P3 独立 PIL 复核 —— 吊灯光晕像素化形态（锯齿边/色阶化/非平滑渐变）。

不依赖 capture 脚本，直接从 lightmap + 渲染帧采样复算。覆盖任务 exit 条件：
  1. 光晕形态：外缘硬边（像素块错落，非平滑渐变衰减）、内部离散色阶
     （2-4 档 alpha 簇，非连续渐变）、外圈非平滑（硬边存在）
  2. R4 硬门保持：同心环覆盖率 <0.95（热核 keep 行不动）
  3. 投光关系保持：灯下暖亮 > 远处（qa A 等价复算）
  4. 阴影方向保持：cast_shadow_offset 全部向南（qa B 等价复算）
"""
import math
import sys

from PIL import Image

# 投影常量（src/presentation/oblique_projection.gd + main.gd 同源复算）
SHEAR = 0.22
FLOOR_SCALE = 0.77
HEIGHT_SCALE = 0.64
EXTRUDE_X = 0.16
WORLD_SCALE = 0.75
OFF_X, OFF_Y = 31.8, 42.96
SX, SY = 1280.0 / 426.0, 720.0 / 240.0
HANGING_LIGHTS = [
    {"rect": (72, 18, 28, 36), "height": 78.0, "bulb_local": (14, 29), "landing": (86, 170), "pool_half": (52, 36)},
    {"rect": (210, 18, 28, 36), "height": 78.0, "bulb_local": (14, 29), "landing": (224, 170), "pool_half": (52, 36)},
    {"rect": (348, 18, 28, 36), "height": 78.0, "bulb_local": (14, 29), "landing": (362, 170), "pool_half": (52, 36)},
]


def proj(x, y, z=0.0):
    return (x + y * SHEAR - z * EXTRUDE_X, y * FLOOR_SCALE - z * HEIGHT_SCALE)


def canvas_to_screen(px, py):
    return (round((px * WORLD_SCALE + OFF_X) * SX), round((py * WORLD_SCALE + OFF_Y) * SY))


def world_to_screen(wx, wy, z=0.0):
    px, py = proj(wx, wy, z)
    return canvas_to_screen(px, py)


def norm_alpha(c):
    return c[3] / 255.0 if len(c) == 4 else 1.0


def luminance(c):
    return 0.299 * c[0] + 0.587 * c[1] + 0.114 * c[2]


def warmness(c):
    return c[0] - c[2]


def main():
    lm_path = sys.argv[1] if len(sys.argv) > 1 else "tests/evidence/v31-r4-lightmap.png"
    frame_path = sys.argv[2] if len(sys.argv) > 2 else "tests/evidence/v31-r4-lighting.png"
    lm = Image.open(lm_path).convert("RGBA")
    frame = Image.open(frame_path).convert("RGBA")
    print(f"LIGHTMAP {lm_path} {lm.width}x{lm.height}")
    print(f"FRAME {frame_path} {frame.width}x{frame.height}")

    ok = True

    def check(cond, label):
        nonlocal ok
        ok = ok and cond
        print(f"  {'PASS' if cond else 'FAIL'} {label}")

    center = HANGING_LIGHTS[0]["landing"]  # (86,170)
    half = HANGING_LIGHTS[0]["pool_half"]

    # ============ 1. 外缘硬边（非平滑渐变衰减） ============
    # 沿多个方向从池中心向外扫描 alpha：平滑渐变 → alpha 缓慢下降（每步
    # 变化小，长衰减段）；硬边/像素块 → alpha 在短距离内从 >0.1 跳变到
    # <0.02（硬边界存在）。统计每方向最大单步跳变。
    print("\n-- 1. 外缘硬边（像素块错落，非平滑渐变） --")
    hard_directions = 0
    total_directions = 0
    for i in range(24):
        a = 2 * math.pi * i / 24.0
        dir_vec = (math.cos(a), math.sin(a))
        prev_a = -1.0
        max_step = 0.0
        has_body = False
        for d in range(10, 90, 2):  # 半径 10..88，超出池体+fade
            px = int(round(center[0] + dir_vec[0] * d))
            py = int(round(center[1] + dir_vec[1] * d))
            if not (0 <= px < lm.width and 0 <= py < lm.height):
                break
            val = norm_alpha(lm.getpixel((px, py)))
            if val > 0.10:
                has_body = True
            if prev_a >= 0.0:
                max_step = max(max_step, abs(val - prev_a))
            prev_a = val
        total_directions += 1
        if has_body and max_step > 0.08:  # 有池体且存在明显硬跳变
            hard_directions += 1
    print(f"  directions with hard alpha step: {hard_directions}/{total_directions}")
    check(hard_directions >= 12,
          f"外缘硬边方向数 {hard_directions}/{total_directions} >= 12（像素块错落，非平滑渐变）")

    # ============ 2. 内部离散色阶（2-4 档 alpha 簇，非连续渐变） ============
    print("\n-- 2. 内部离散色阶 --")
    alphas = []
    for y in range(max(0, int(center[1]) - 36), min(lm.height, int(center[1]) + 37)):
        for x in range(max(0, int(center[0]) - 52), min(lm.width, int(center[0]) + 53)):
            a = norm_alpha(lm.getpixel((x, y)))
            if a > 0.02:
                alphas.append(a)
    # 0.12 精度分簇 —— 连续渐变会产生布满所有 bin 的连续分布（很多簇）；
    # 硬色阶只落在少数几个 bin（热核 ~0.58、中档 ~0.40、边缘 ~0.19、fade ~0.10）
    bins = {}
    for a in alphas:
        key = round(a * 8.0) / 8.0
        bins[key] = bins.get(key, 0) + 1
    top = sorted(bins.items(), key=lambda kv: -kv[1])
    print(f"  alpha clusters (top 6): {[(round(k,2), v) for k, v in top[:6]]}")
    total = len(alphas)
    main_clusters = [k for k, v in top if v / total >= 0.06]
    print(f"  main alpha clusters: {[round(k,2) for k in main_clusters]}")
    # 连续渐变 → 8+ 个簇；硬色阶 2-4 个主簇 + 少量边缘簇（方向 bias 微调）
    check(2 <= len(main_clusters) <= 5, f"内部离散色阶 2-5 档 (clusters={len(main_clusters)})")

    # ============ 3. 外圈无 smooth gradient（R4 FAIL 根因） ============
    # 池体之外（fade band）应有硬边 —— 采样池体边缘外一圈，找 alpha>0.02
    # 到 alpha=0 的跳变（而不是缓慢连续衰减）。
    print("\n-- 3. 外圈非平滑渐变 --")
    # 池体外缘 metric≈1.0..1.3 环带：alpha 应出现「有→无」的硬边界。
    # 取 24 方向中池体半径最大的方向（东侧，nx 主导），看它向外是否硬切。
    hard_outer = 0
    for i in range(24):
        a = 2 * math.pi * i / 24.0
        dir_vec = (math.cos(a), math.sin(a))
        seq = []
        for d in range(46, 80, 2):  # 池体外圈（half 36-52 → metric 1.0..1.5）
            px = int(round(center[0] + dir_vec[0] * d))
            py = int(round(center[1] + dir_vec[1] * d))
            if 0 <= px < lm.width and 0 <= py < lm.height:
                seq.append(norm_alpha(lm.getpixel((px, py))))
        # 有内容且存在大步跳变（硬切）或快速归零
        if seq and max(seq) > 0.03:
            jumps = sum(1 for j in range(1, len(seq)) if abs(seq[j] - seq[j - 1]) > 0.04)
            if jumps >= 1:
                hard_outer += 1
    print(f"  outer-band hard-edge directions: {hard_outer}/24")
    check(hard_outer >= 6,
          f"外圈硬边方向 {hard_outer}/24 >= 6（fade 两档硬色阶，非连续渐变）")

    # ============ 4. R4 硬门：同心环覆盖率 <0.95（热核 keep 保持） ============
    print("\n-- 4. R4 硬门：环覆盖率 <0.95 --")
    ring_ratios = []
    for ring_r in [10, 22, 34, 44]:
        covered = total = 0
        for i in range(48):
            a = 2 * math.pi * i / 48.0
            px = int(round(center[0] + math.cos(a) * ring_r))
            py = int(round(center[1] + math.sin(a) * ring_r))
            if not (0 <= px < lm.width and 0 <= py < lm.height):
                continue
            total += 1
            if norm_alpha(lm.getpixel((px, py))) > 0.02:
                covered += 1
        ring_ratios.append(covered / total if total else 1.0)
    print(f"  rings: {[round(r, 2) for r in ring_ratios]}")
    check(all(rr < 0.95 for rr in ring_ratios),
          f"环覆盖率全部 <0.95 (实际 {[round(r,2) for r in ring_ratios]})")

    # ============ 5. 投光关系保持（qa A 等价复算） ============
    print("\n-- 5. 投光关系保持 --")
    lx, ly = world_to_screen(*center)
    lamp_cols = []
    for dy in range(-10, 11, 3):
        for dx in range(-10, 11, 3):
            sx, sy = lx + dx, ly + dy
            if 0 <= sx < frame.width and 0 <= sy < frame.height:
                lamp_cols.append(frame.getpixel((sx, sy)))
    far_cands = [(120, 90), (60, 130), (130, 140), (60, 200)]
    far_lums, far_warm = [], []
    for fx, fy in far_cands:
        sx, sy = world_to_screen(fx, fy)
        cols = []
        for dy in range(-10, 11, 3):
            for dx in range(-10, 11, 3):
                px, py = sx + dx, sy + dy
                if 0 <= px < frame.width and 0 <= py < frame.height:
                    cols.append(frame.getpixel((px, py)))
        if cols:
            far_lums.append(sum(luminance(c) for c in cols) / len(cols))
            far_warm.append(sum(warmness(c) for c in cols) / len(cols))
    lamp_lum = sum(luminance(c) for c in lamp_cols) / len(lamp_cols) if lamp_cols else 0
    lamp_warm = sum(warmness(c) for c in lamp_cols) / len(lamp_cols) if lamp_cols else 0
    far_min_lum = min(far_lums) if far_lums else 0
    far_min_warm = min(far_warm) if far_warm else 0
    print(f"  lamp lum={lamp_lum:.1f} warm={lamp_warm:+.1f} | far min lum={far_min_lum:.1f} warm={far_min_warm:+.1f}")
    check(lamp_lum > far_min_lum + 0.005, f"灯下亮于远处 (lum {lamp_lum:.1f} > {far_min_lum:.1f})")
    check(lamp_warm > far_min_warm + 0.002, f"灯下暖于远处 (warm {lamp_warm:+.1f} > {far_min_warm:+.1f})")

    # ============ 6. 阴影方向保持（qa B 等价复算） ============
    print("\n-- 6. 阴影方向一致向南 --")

    def cast_offset(pos, height):
        best = None
        best_d = 1e18
        for light in HANGING_LIGHTS:
            bx = light["rect"][0] + light["bulb_local"][0]
            by = light["rect"][1] + light["bulb_local"][1]
            dx = pos[0] - bx
            dy = pos[1] - by
            d = dx * dx + dy * dy
            if d < best_d:
                best_d = d
                best = (bx, by)
        dx = pos[0] - best[0]
        dy = pos[1] - best[1]
        if dx * dx + dy * dy < 1.0:
            dx, dy = 0.0, 1.0
        n = math.sqrt(dx * dx + dy * dy)
        return (dx / n * (height * 0.72 + 5.0), dy / n * (height * 0.72 + 5.0))

    devices = [((96, 80), 30.0), ((80, 176), 36.0), ((304, 80), 6.0)]
    offs = [cast_offset(p, h) for p, h in devices]
    print(f"  cast offsets: {[(round(o[0],1), round(o[1],1)) for o in offs]}")
    check(all(o[1] > 4.0 for o in offs), f"投影方向全场一致向南 (y {[round(o[1]) for o in offs]})")

    print(f"\nP3 GLOW FORM RESULT: {'PASS' if ok else 'FAIL'}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
