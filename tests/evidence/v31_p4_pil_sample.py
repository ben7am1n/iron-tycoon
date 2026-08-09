#!/usr/bin/env python3
"""V3.1 P4 — PIL 像素采样证据：pixel-based lighting（无圆形光斑）。

采样 tests/evidence/v31-p4-lighting.png（window 模式渲染帧）+ 
tests/evidence/v31-p4-lightmap.png（LightingLayer 静态 light map），验证
附录 V3.1 P4 pixel-based lighting 核心约束：

  A. 无大面积圆形半透明光斑：light map 灯池为 hash 散射 cluster ——
     以灯池中心为圆心采样多个同心环，环上 alpha 覆盖率 < 0.95 且
     环内 alpha 非均匀（实心半透明圆会 ~100% 均匀覆盖）
  B. 墙边像素 vs 灯下像素明暗差异：light map 墙边带含冷暗像素
     （alpha > 0，蓝 > 红），灯池中心含暖亮像素（alpha > 0，红 > 蓝），
     且灯池平均 alpha > 墙边平均 alpha（灯下亮于墙边）
  C. 渲染帧受光面变暖/变亮：力量区灯下区域亮度/暖度 > 同材质远离灯区域
     （V3 §7 受光面颜色变暖/变亮）
  D. 设备高光/屏幕亮色局部存在：treadmill 顶面存在 EQUIP_HIGHLIGHT 暖高光
     像素；控制台存在青蓝屏幕像素（EQUIP_ACCENT_CYAN / EMISSIVE_CYAN）

断言通过阈值按「PIL 8bit 量化 + 渲染管线污染」放宽（与 P2/P3 同源策略）。

用法：python3 tests/evidence/v31_p4_pil_sample.py
退出码：0 = 全部通过；1 = 有失败。
"""
import math
import os
import sys
from PIL import Image

EVIDENCE_DIR = os.path.dirname(os.path.abspath(__file__))
PNG = os.path.join(EVIDENCE_DIR, "v31-p4-lighting.png")
LIGHTMAP = os.path.join(EVIDENCE_DIR, "v31-p4-lightmap.png")

# === 投影常量（与 oblique_projection.gd / main.gd 同源复算） ===
SHEAR = 0.35
FLOOR_SCALE = 0.62
HEIGHT_SCALE = 0.79
EXTRUDE_X = 0.20
WORLD_SCALE = 0.75
VIEWPORT_OFFSET = (19.05, 78.1875)
SCREEN_PER_VIEWPORT = (1280.0 / 426.0, 720.0 / 240.0)

# === palette.gd 设备高光/屏幕色 ===
EQUIP_HIGHLIGHT = (0xEA / 255, 0xDF / 255, 0xB8 / 255)   # EADFB8
EQUIP_ACCENT_CYAN = (0x5E / 255, 0xD4 / 255, 0xE8 / 255) # 5ED4E8
EMISSIVE_CYAN = (0x4F / 255, 0xD8 / 255, 0xE8 / 255)     # 4FD8E8

# 灯池中心（WorldLayout.LIGHT_POOLS[0]）与半径
LAMP_CENTER = (86, 170)
LAMP_RADIUS = 46
# 墙边暗角带内采样（左侧墙 x=10）
WALL_EDGE_SAMPLE = (10, 170)
# treadmill(2,2) footprint = (64,64,64,32)，顶面 z=30
TM_RECT = (64, 64, 64, 32)
TM_HEIGHT = 30.0
# 同材质远离灯区域候选点（strength zone 内部，远离灯池与窗光锥；取亮度
# 最小者作「未受光地板」参考 —— 会员/装饰只会变亮，min 对动态干扰稳健）
FAR_SAME_ZONE_CANDIDATES = [(120, 90), (60, 130), (130, 140), (60, 200)]

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


def lum(c):
    n = norm(c)
    return 0.299 * n[0] + 0.587 * n[1] + 0.114 * n[2]


def warmness(c):
    n = norm(c)
    return n[0] - n[2]


def in_bounds(img, p):
    return 0 <= p[0] < img.width and 0 <= p[1] < img.height


def verify_lightmap_no_circle(img):
    print("\n-- A. light map 无大面积半透明圆形光斑（灯池=散射 cluster） --")
    cx, cy = LAMP_CENTER
    px = img.load()
    # 同心环：alpha 覆盖率 < 0.95 且非均匀（std > 0.01）
    for ring_r in (10, 22, 34, 44):
        alphas = []
        total = 0
        for i in range(48):
            a = math.tau * i / 48.0
            sx, sy = int(round(cx + math.cos(a) * ring_r)), int(round(cy + math.sin(a) * ring_r))
            if not in_bounds(img, (sx, sy)):
                continue
            total += 1
            p = px[sx, sy]
            alphas.append(p[3] / 255.0)
        if total < 24:
            check(False, f"A ring r={ring_r} insufficient samples ({total})")
            continue
        coverage = sum(1 for a in alphas if a > 0.02) / len(alphas)
        mean = sum(alphas) / len(alphas)
        var = sum((a - mean) ** 2 for a in alphas) / len(alphas)
        check(coverage < 0.95,
              f"A ring r={ring_r} coverage {coverage:.2f} < 0.95 (not solid circle)")
        check(math.sqrt(var) > 0.01,
              f"A ring r={ring_r} alpha std {math.sqrt(var):.3f} > 0.01 (scattered cluster)")
    # 灯池内非空（中心窗口有暖亮像素）
    warm = 0
    for dy in range(-6, 7):
        for dx in range(-6, 7):
            sx, sy = cx + dx, cy + dy
            p = px[sx, sy]
            if p[3] / 255.0 > 0.03 and p[0] > p[2]:
                warm += 1
    check(warm > 0, f"A lamp center warm pixels exist ({warm})")


def verify_lightmap_edge_vs_lamp(img):
    print("\n-- B. 墙边像素 vs 灯下像素明暗差异（light map） --")
    px = img.load()
    # 墙边带：冷暗像素存在（alpha>0，蓝>红）
    edge_cool = 0
    edge_sum = 0.0
    edge_n = 0
    wx, wy = WALL_EDGE_SAMPLE
    for dy in range(-6, 7):
        for dx in range(0, 8):
            sx, sy = wx + dx, wy + dy
            p = px[sx, sy]
            a = p[3] / 255.0
            edge_n += 1
            edge_sum += a
            if a > 0.03 and p[2] > p[0]:
                edge_cool += 1
    check(edge_cool > 0, f"B wall-edge cool-dark pixels exist (cool {edge_cool})")
    # 灯池中心：暖亮像素 + 平均 alpha 高于墙边
    lamp_sum = 0.0
    lamp_n = 0
    lamp_warm = 0
    cx, cy = LAMP_CENTER
    for dy in range(-6, 7):
        for dx in range(-6, 7):
            p = px[cx + dx, cy + dy]
            a = p[3] / 255.0
            lamp_n += 1
            lamp_sum += a
            if a > 0.03 and p[0] > p[2]:
                lamp_warm += 1
    lamp_avg = lamp_sum / max(lamp_n, 1)
    edge_avg = edge_sum / max(edge_n, 1)
    check(lamp_warm > 0, f"B under-lamp warm pixels exist (warm {lamp_warm})")
    check(lamp_avg > edge_avg,
          f"B lamp avg alpha {lamp_avg:.3f} > wall-edge avg alpha {edge_avg:.3f} (灯下亮于墙边)")


def verify_render_warm_lit(img):
    print("\n-- C. 渲染帧受光面变暖/变亮（灯下 vs 同材质远离灯） --")
    px = img.load()
    lamp_cols = []
    lx, ly = LAMP_CENTER
    for dy in range(-10, 11, 3):
        for dx in range(-10, 11, 3):
            p1 = screen(lx + dx, ly + dy)
            if in_bounds(img, p1):
                lamp_cols.append(px[p1[0], p1[1]])
    if not lamp_cols:
        check(False, "C lamp sampled pixels > 0")
        return
    lamp_l = sum(lum(c) for c in lamp_cols) / len(lamp_cols)
    lamp_w = sum(warmness(c) for c in lamp_cols) / len(lamp_cols)
    # 多个候选点取最小亮度作「未受光地板」参考（会员/装饰只会变亮）
    far_min_l = 1e9
    far_min_w = 1e9
    for fx, fy in FAR_SAME_ZONE_CANDIDATES:
        cols = []
        for dy in range(-10, 11, 3):
            for dx in range(-10, 11, 3):
                p2 = screen(fx + dx, fy + dy)
                if in_bounds(img, p2):
                    cols.append(px[p2[0], p2[1]])
        if cols:
            far_min_l = min(far_min_l, sum(lum(c) for c in cols) / len(cols))
            far_min_w = min(far_min_w, sum(warmness(c) for c in cols) / len(cols))
    check(lamp_l > far_min_l + 0.005,
          f"C lamp lum {lamp_l:.3f} > far min lum {far_min_l:.3f} + 0.005 (受光面变亮)")
    check(lamp_w > far_min_w + 0.002,
          f"C lamp warm {lamp_w:.3f} > far min warm {far_min_w:.3f} + 0.002 (受光面变暖)")


def verify_render_equipment(img):
    print("\n-- D. 设备高光 / 屏幕亮色局部存在（渲染帧） --")
    px = img.load()
    # treadmill 顶面暖高光（扫描整个顶面网格，取暖亮像素：r>b 且亮度高）
    highlight_count = 0
    rx, ry, rw, rh = TM_RECT
    for wy in range(ry, ry + rh, 2):
        for wx in range(rx, rx + rw, 2):
            p = screen(wx, wy, TM_HEIGHT)
            if not in_bounds(img, p):
                continue
            c = norm(px[p[0], p[1]])
            if c[0] > c[2] + 0.05 and lum(px[p[0], p[1]]) > 0.42:
                highlight_count += 1
    check(highlight_count > 0, f"D treadmill top warm highlight pixels present (设备高光, {highlight_count} px)")
    # 控制台青蓝屏幕像素
    screen_found = False
    for dy in range(-3, 4):
        for dx in range(-3, 4):
            p = screen(rx + 16 + dx, ry + 28 + dy, TM_HEIGHT)
            if not in_bounds(img, p):
                continue
            c = norm(px[p[0], p[1]])
            if color_dist(c, EQUIP_ACCENT_CYAN) <= 0.16 or color_dist(c, EMISSIVE_CYAN) <= 0.16:
                screen_found = True
                break
        if screen_found:
            break
    check(screen_found, "D treadmill console cyan screen pixels present (屏幕亮色)")


def main():
    print("=" * 64)
    print("  V3.1 P4 PIL PIXEL SAMPLING — pixel-based lighting (no circle blobs)")
    print("  source: %s" % PNG)
    print("=" * 64)
    if not os.path.exists(PNG):
        print("  FAIL: rendered frame missing (%s)" % PNG)
        print("  Run: godot --path . res://tests/evidence/v31_p4_capture.tscn")
        sys.exit(1)
    if not os.path.exists(LIGHTMAP):
        print("  FAIL: light map missing (%s)" % LIGHTMAP)
        print("  Run: godot --path . res://tests/evidence/v31_p4_capture.tscn")
        sys.exit(1)
    frame = Image.open(PNG).convert("RGB")
    lightmap = Image.open(LIGHTMAP).convert("RGBA")
    print(f"  frame: {frame.width}x{frame.height}  lightmap: {lightmap.width}x{lightmap.height}")
    verify_lightmap_no_circle(lightmap)
    verify_lightmap_edge_vs_lamp(lightmap)
    verify_render_warm_lit(frame)
    verify_render_equipment(frame)
    print("\n" + "=" * 64)
    print("  PIL SAMPLING RESULT: %s (%d passed, %d failed)" % (
        "PASS" if failed == 0 else "FAIL", passed, failed))
    print("=" * 64)
    sys.exit(1 if failed > 0 else 0)


if __name__ == "__main__":
    main()
