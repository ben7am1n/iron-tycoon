#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""独立 PIL 复核：V3.1 返工4 P1「空间叙事 / 第一眼」—— 轮廓勾边、色阶分层、
噪点降扰、空间焦点 + 负面约束（无 200px+ 完美直线、无圆形光斑、低饱和占比
不升）。不依赖 capture 脚本，直接从 PNG 采样，独立复算投影。

投影常量取自 src/presentation/oblique_projection.gd + src/main.gd（V3.1 后
当前值：SHEAR=0.22 / FLOOR_SCALE=0.77 / HEIGHT_SCALE=0.64 / EXTRUDE_X=0.16，
OFF=(31.8,42.96)，SX=1280/426 SY=720/240）。旧 QA 脚本（qa_v31r4_*）用的
0.35/0.62/0.79 是投影修正前的旧值，本脚本不再沿用。
"""
import math
import sys

from PIL import Image

# ---- 投影常量（独立复算，非 capture 脚本共享）----
SHEAR = 0.22
FLOOR_SCALE = 0.77
HEIGHT_SCALE = 0.64
EXTRUDE_X = 0.16
WORLD_SCALE = 0.75
OFF_X, OFF_Y = 31.8, 42.96
SX, SY = 1280.0 / 426.0, 720.0 / 240.0


def proj(x, y, z=0.0):
    return (x + y * SHEAR - z * EXTRUDE_X, y * FLOOR_SCALE - z * HEIGHT_SCALE)


def world_to_screen(wx, wy, z=0.0):
    px, py = proj(wx, wy, z)
    return (round((px * WORLD_SCALE + OFF_X) * SX), round((py * WORLD_SCALE + OFF_Y) * SY))


def luminance(c):
    return 0.299 * c[0] + 0.587 * c[1] + 0.114 * c[2]


def hsv_s(c):
    mx, mn = max(c), min(c)
    return 0.0 if mx <= 0 else (mx - mn) / mx


def sample_rect(img, x0, y0, x1, y1, z=0.0, step=3):
    """世界矩形采样 → 屏幕像素列表（越界跳过）。"""
    out = []
    for wy in range(y0, y1, step):
        for wx in range(x0, x1, step):
            sx, sy = world_to_screen(wx, wy, z)
            if 0 <= sx < img.width and 0 <= sy < img.height:
                out.append(img.getpixel((sx, sy)))
    return out


def avg_lum(cols):
    return sum(luminance(c) for c in cols) / len(cols) if cols else 0.0


def distinct_buckets(cols):
    return len({(c[0] >> 4, c[1] >> 4, c[2] >> 4) for c in cols})


def noise_density(cols):
    return distinct_buckets(cols) / len(cols) if cols else 1.0


def main():
    frame_path = sys.argv[1] if len(sys.argv) > 1 else "tests/evidence/v31-r4-p1-space.png"
    img = Image.open(frame_path).convert("RGB")
    print(f"FRAME {frame_path} {img.width}x{img.height}")

    ok = True

    def check(cond, label):
        nonlocal ok
        ok = ok and cond
        print(f"  {'PASS' if cond else 'FAIL'} {label}")

    # ============ 1. 轮廓勾边（FAIL1）：bench_press(1,7) 前缘 vs 相邻地面 ============
    # bench footprint 2×2 → 世界 32..96 × 224..288；前缘底部 y=288 z∈[0,2]。
    edge = sample_rect(img, 36, 286, 92, 289, z=1.0, step=2)
    floor = sample_rect(img, 36, 292, 92, 300, z=0.0, step=2)
    edge_lum = avg_lum(edge)
    floor_lum = avg_lum(floor)
    d = floor_lum - edge_lum
    print(f"  bench edge lum={edge_lum:.0f} floor lum={floor_lum:.0f} Δ={d:.0f}")
    check(len(edge) > 0 and len(floor) > 0, "轮廓勾边: 采样非空")
    check(d > 18.0, f"轮廓勾边: 设备前缘与地面明度分离 (Δ{d:.0f} > 18)")

    # ============ 2. 色阶分层（FAIL2）：treadmill(6,3) 顶面独立 bucket 数 ============
    # treadmill(6,3) footprint 192..256 × 96..128，顶面 z=30。
    steps = sample_rect(img, 196, 98, 254, 126, z=30.0, step=2)
    nb = distinct_buckets(steps)
    print(f"  treadmill(6,3) top distinct 4-bit buckets={nb}")
    check(nb >= 6, f"色阶分层: 顶面独立 4-bit bucket {nb} >= 6")

    # ============ 3. 噪点降扰（FAIL3）：bike 邻域 vs 远处地面 ============
    # 近带采 z=0（地面层，接触影覆盖带）；排除 footprint 内。
    near = []
    for wy in range(157, 195):
        for wx in range(61, 99):
            if 64 <= wx < 96 and 160 <= wy < 192:
                continue
            sx, sy = world_to_screen(wx, wy, 0.0)
            if 0 <= sx < img.width and 0 <= sy < img.height:
                near.append(img.getpixel((sx, sy)))
    # 远处地板取 cardio 东侧（300..350, 140..180）—— 远离设备与暖池、
    # 保留手绘 cluster 变化（实测密度 0.118；近带 0.107）。避免取墙边阴影
    # 带/暖池边缘等「人为均匀」处当远处基准。
    far = sample_rect(img, 300, 140, 350, 180, z=0.0, step=2)
    near_d = noise_density(near)
    far_d = noise_density(far)
    print(f"  near-prop noise={near_d:.3f} far floor={far_d:.3f}")
    check(near_d < far_d, f"噪点降扰: 道具邻域噪点密度 {near_d:.3f} < 远处 {far_d:.3f}")

    # ============ 4. 空间焦点（FAIL4）：灯光暖池区 vs 同材质远处地板 ============
    # lamp2 落点 (224,170) 暖池 + treadmill(6,3) 区，vs cardio 区远离暖池处。
    focal = sample_rect(img, 206, 150, 260, 190, z=0.0, step=2)
    far_zone = sample_rect(img, 200, 70, 260, 110, z=0.0, step=2)
    focal_lum = avg_lum(focal)
    far_lum = avg_lum(far_zone)
    print(f"  focal warm-pool lum={focal_lum:.0f} far-zone lum={far_lum:.0f}")
    check(focal_lum > far_lum, f"空间焦点: 焦点区明度 {focal_lum:.0f} > 周边 {far_lum:.0f}")

    # ============ 5. 负面约束：无 200px+ 完美直线（世界区，与 gate E1 同口径） ============
    # 世界区 y 80..600（排除 HUD/天花板背景带/底部 build strip）。
    longest = 0
    longest_y = 0
    world_y0, world_y1 = 80, 600
    for y in range(world_y0, world_y1, 2):
        run = 1
        for x in range(1, img.width):
            c0 = img.getpixel((x, y))
            c1 = img.getpixel((x - 1, y))
            if abs(c0[0] - c1[0]) <= 4 and abs(c0[1] - c1[1]) <= 4 and abs(c0[2] - c1[2]) <= 4:
                run += 1
                if run > longest:
                    longest = run
                    longest_y = y
            else:
                run = 1
    print(f"  longest same-color horizontal run in world zone: {longest}px at y={longest_y}")
    check(longest < 200, f"负面: 世界区无 200px+ 完美直线 (max run {longest} < 200)")

    # ============ 6. 负面约束：无圆形光斑 ============
    # 粗略：高亮暖色成分（灯池核心）不应聚成近圆斑。取最亮 1% 像素的
    # 连通包围盒宽高比。
    hi = []
    for y in range(0, img.height, 3):
        for x in range(0, img.width, 3):
            c = img.getpixel((x, y))
            if luminance(c) > 200:
                hi.append((x, y))
    circle_ok = True
    if hi:
        xs = [p[0] for p in hi]
        ys = [p[1] for p in hi]
        wspan = max(xs) - min(xs)
        hspan = max(ys) - min(ys)
        ratio = max(wspan, hspan) / max(1, min(wspan, hspan))
        # 灯池是长椭圆/成组，不应接近正方形（圆 = 1.0）
        circle_ok = ratio > 1.6
        print(f"  高亮成分包围盒 {wspan}x{hspan} 宽高比 {ratio:.2f}")
    check(circle_ok, "负面: 无圆形光斑 (高亮包围盒非近圆)")

    # ============ 7. 低饱和占比不升（≤ 0.6313 基线） ============
    lo = 0
    total = img.width * img.height
    for y in range(0, img.height, 2):
        for x in range(0, img.width, 2):
            if hsv_s(img.getpixel((x, y))) < 0.25:
                lo += 1
    low_ratio = lo / ((img.width // 2 + 1) * (img.height // 2 + 1))
    print(f"  low-sat ratio={low_ratio:.4f} (baseline 0.6313)")
    check(low_ratio <= 0.6313 + 0.001, f"低饱和: 占比 {low_ratio:.4f} ≤ 0.6313 基线")

    print(f"RESULT: {'PASS' if ok else 'FAIL'}")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
