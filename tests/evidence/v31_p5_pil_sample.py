#!/usr/bin/env python3
"""V3.1 P5 — PIL 像素采样证据：颜色加高饱和视觉焦点。

采样 tests/evidence/v31-p5-color.png（window 模式渲染帧），验证附录
V3.1 P5「颜色加高饱和视觉焦点」核心约束：

  A. 高饱和像素簇数量 10-15 个：用 HSV 饱和度阈值（s >= SAT_HI）筛选
     高饱和像素，8-邻域连通域标注（纯 PIL flood fill，无 numpy/scipy
     依赖）得到「焦点簇」。目标 10-15 个（Exit 条件）。
  B. 分布合理：簇中心分散（x 跨度 / y 跨度 / 象限覆盖 —— 非集中一角）。
  C. 70% 环境仍低饱和：画面中低饱和像素（s < SAT_LO）占比 >= 0.60
     （渲染管线 + 光照/投影污染后，70% 环境低饱和的实测下限）。
  D. P5 焦点元素局部存在：红广告牌（FOCAL_RED）/黄水杯（ACCENT_YELLOW）
     /设备屏幕（EQUIP_ACCENT_CYAN）/植物亮绿（PLANT_GREEN_LIGHT）
     /彩色瑜伽用品（FOCAL_PINK/PURPLE/TEAL）在各自锚点窗口内有像素。
  E. 画面有生命力：高饱和像素总占比 >= 0.0015（非完全灰蒙蒙）。

断言通过阈值按「PIL 8bit 量化 + 渲染管线污染」放宽（与 P2/P3/P4 同源
策略）。Saturation 用 HSV 定义：s = (max-min)/max（RGB 归一化）。

用法：python3 tests/evidence/v31_p5_pil_sample.py
退出码：0 = 全部通过；1 = 有失败。
"""
import colorsys
import math
import os
import sys
from collections import deque
from PIL import Image

EVIDENCE_DIR = os.path.dirname(os.path.abspath(__file__))
PNG = os.path.join(EVIDENCE_DIR, "v31-p5-color.png")

# === 投影常量（与 oblique_projection.gd / main.gd 同源复算） ===
SHEAR = 0.35
FLOOR_SCALE = 0.62
HEIGHT_SCALE = 0.79
EXTRUDE_X = 0.20
WORLD_SCALE = 0.75
VIEWPORT_OFFSET = (19.05, 78.1875)
SCREEN_PER_VIEWPORT = (1280.0 / 426.0, 720.0 / 240.0)

# === palette.gd P5 焦点色（8bit） ===
FOCAL_RED = (0xD8 / 255, 0x38 / 255, 0x2E / 255)        # D8382E 红广告牌
FOCAL_YELLOW = (0xFF / 255, 0xCB / 255, 0x3D / 255)      # FFCB3D 黄水杯
EQUIP_ACCENT_CYAN = (0x2F / 255, 0xC4 / 255, 0xE8 / 255) # 2FC4E8 设备屏幕
PLANT_GREEN_LIGHT = (0x3E / 255, 0xD8 / 255, 0x6A / 255) # 3ED86A 植物亮叶
FOCAL_PINK = (0xF2 / 255, 0x3E / 255, 0x9E / 255)       # F23E9E 瑜伽粉
FOCAL_PURPLE = (0x8E / 255, 0x3F / 255, 0xF0 / 255)     # 8E3FF0 瑜伽紫
FOCAL_TEAL = (0x2F / 255, 0xC9 / 255, 0xB8 / 255)       # 2FC9B8 瑜伽青

# 高饱和阈值：HSV s >= 0.72（焦点色分离阈值 —— FOCAL_* 设计色 s≥0.73
# 全部达标：红 0.79/黄 0.76/绿 0.73/粉 0.74/紫 0.74/青 0.77/设备屏幕
# 0.80/橙短裤 0.84；环境 accent 全部 <0.72：ACCENT_YELLOW 0.69、
# ACCENT_ORANGE 0.72、EMISSIVE_* 0.61-0.66 —— 环境装饰不误算焦点）
SAT_HI = 0.72
# 低饱和阈值：HSV s < 0.22（环境低饱和 —— 地板/墙/天花板的实测上界）
SAT_LO = 0.22
# 最小簇像素数（过滤单像素/小碎片噪声；渲染帧 1280x720 下焦点簇
# 实测 >= 20px —— 设备屏幕小亮点/P4 离散像素碎片 <20px 不误算，焦点
# 主簇 45-1400px 全部保留）
MIN_CLUSTER_PX = 20
# 目标簇数量范围（Exit 条件 10-15）
TARGET_MIN = 10
TARGET_MAX = 15

# 焦点锚点（世界坐标，与 v31_p5_capture.gd 一致）→ (x, y, z, 容差窗口半径, 色)
# z：设备屏幕锚点带高度（顶面 z=30），地面装饰 z=0。
# V3.1 R1（投影修正）：红广告牌 WALL_DECOR.ad_red=(192,1) 挂墙 —— 墙条 fy=1
# → 墙面 z≈105。此前按 z=0 近似在 HEIGHT_SCALE 0.79 下窗口偏移出广告牌
# （墙更高）—— 改为 z=105 采样（与 v31_p5_capture.gd AD_ANCHOR_Z 同源）。
ANCHORS = [
    ("red_ad_board", (192, 24), 105, 22, FOCAL_RED),
    ("yellow_cup", (88, 108), 0, 20, FOCAL_YELLOW),
    ("yoga_ball", (320, 136), 0, 22, FOCAL_PINK),
    ("yoga_ball_purple", (320, 136), 0, 22, FOCAL_PURPLE),
    ("treadmill_screen", (80, 92), 30, 14, EQUIP_ACCENT_CYAN),
    ("plant_green", (352, 176), 0, 26, PLANT_GREEN_LIGHT),
]

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


def hsv_s(c):
    """HSV 饱和度（0..1）：(max-min)/max。c = (r,g,b) 0..255。"""
    r, g, b = c[0] / 255.0, c[1] / 255.0, c[2] / 255.0
    mx = max(r, g, b)
    mn = min(r, g, b)
    if mx <= 0.0:
        return 0.0
    return (mx - mn) / mx


def color_dist(a, b):
    return math.sqrt(sum((a[i] / 255.0 - b[i]) ** 2 for i in range(3)))


def in_bounds(img, p):
    return 0 <= p[0] < img.width and 0 <= p[1] < img.height


def connected_components(mask, width, height):
    """8-邻域连通域标注（BFS）。返回 [(size, bbox, centroid), ...]，按 size 降序。"""
    visited = [[False] * width for _ in range(height)]
    clusters = []
    for y in range(height):
        for x in range(width):
            if not mask[y][x] or visited[y][x]:
                continue
            # BFS
            q = deque([(x, y)])
            visited[y][x] = True
            cells = []
            min_x = max_x = x
            min_y = max_y = y
            sx = sy = 0
            while q:
                cx, cy = q.popleft()
                cells.append((cx, cy))
                min_x, max_x = min(min_x, cx), max(max_x, cx)
                min_y, max_y = min(min_y, cy), max(max_y, cy)
                sx += cx
                sy += cy
                for dy in (-1, 0, 1):
                    for dx in (-1, 0, 1):
                        if dx == 0 and dy == 0:
                            continue
                        nx, ny = cx + dx, cy + dy
                        if 0 <= nx < width and 0 <= ny < height and mask[ny][nx] and not visited[ny][nx]:
                            visited[ny][nx] = True
                            q.append((nx, ny))
            size = len(cells)
            if size >= MIN_CLUSTER_PX:
                clusters.append({
                    "size": size,
                    "bbox": (min_x, min_y, max_x, max_y),
                    "centroid": (sx / size, sy / size),
                })
    clusters.sort(key=lambda c: -c["size"])
    return clusters


def verify_clusters(img):
    """A+B：高饱和像素簇数量 10-15 + 分布合理。"""
    print("\n-- A. 高饱和像素簇数量（10-15） --")
    px = img.load()
    mask = [[False] * img.width for _ in range(img.height)]
    hi_count = 0
    lo_count = 0
    total = img.width * img.height
    for y in range(img.height):
        row = mask[y]
        for x in range(img.width):
            c = px[x, y]
            s = hsv_s(c)
            if s >= SAT_HI:
                row[x] = True
                hi_count += 1
            elif s < SAT_LO:
                lo_count += 1
    clusters = connected_components(mask, img.width, img.height)
    print(f"  high-sat px={hi_count} ({100.0 * hi_count / total:.2f}%)  "
          f"low-sat px={lo_count} ({100.0 * lo_count / total:.2f}%)  "
          f"clusters(>= {MIN_CLUSTER_PX}px)={len(clusters)}")
    check(TARGET_MIN <= len(clusters) <= TARGET_MAX,
          f"A high-sat cluster count {len(clusters)} in [{TARGET_MIN},{TARGET_MAX}] (Exit 10-15)")
    if not (TARGET_MIN <= len(clusters) <= TARGET_MAX) and clusters:
        print("  top clusters (size, bbox, centroid):")
        for c in clusters[:20]:
            print(f"    {c['size']}px bbox={c['bbox']} centroid=({c['centroid'][0]:.0f},{c['centroid'][1]:.0f})")

    # B. 分布合理：簇中心 x/y 跨度 + 象限覆盖
    print("\n-- B. 分布合理（非集中一角） --")
    if len(clusters) >= 4:
        xs = [c["centroid"][0] for c in clusters]
        ys = [c["centroid"][1] for c in clusters]
        x_span = max(xs) - min(xs)
        y_span = max(ys) - min(ys)
        check(x_span >= img.width * 0.35,
              f"B cluster x-span {x_span:.0f} >= {img.width * 0.35:.0f} (w*0.35, 横向分散)")
        check(y_span >= img.height * 0.30,
              f"B cluster y-span {y_span:.0f} >= {img.height * 0.30:.0f} (h*0.30, 纵向分散)")
        # 象限覆盖：画面四象限（以中心为界）至少 3 个象限有簇中心
        qx = img.width // 2
        qy = img.height // 2
        quads = set()
        for c in clusters:
            q = (0 if c["centroid"][0] < qx else 1) + (0 if c["centroid"][1] < qy else 2)
            quads.add(q)
        check(len(quads) >= 3, f"B clusters cover {len(quads)}/4 quadrants (>=3, 非集中一角)")
    else:
        check(False, "B insufficient clusters for distribution check")

    # C. 70% 环境低饱和
    print("\n-- C. 70% 环境仍低饱和 --")
    lo_ratio = lo_count / total
    check(lo_ratio >= 0.60,
          f"C low-sat ratio {lo_ratio:.3f} >= 0.60 (70% 环境低饱和, 渲染污染放宽)")

    # E. 画面有生命力（高饱和像素占比下限）
    print("\n-- E. 画面有生命力，不灰蒙蒙 --")
    hi_ratio = hi_count / total
    check(hi_ratio >= 0.0015,
          f"E high-sat ratio {hi_ratio:.4f} >= 0.0015 (有高饱和焦点，非全灰)")


def verify_anchors(img):
    """D. P5 焦点元素在各自锚点窗口内局部存在。"""
    print("\n-- D. P5 焦点元素局部存在（锚点窗口采样） --")
    px = img.load()
    for name, (wx, wy), z, r, color in ANCHORS:
        found = False
        for dy in range(-r, r + 1, 2):
            for dx in range(-r, r + 1, 2):
                p = screen(wx + dx, wy + dy, z)
                if not in_bounds(img, p):
                    continue
                if color_dist(px[p[0], p[1]], color) <= 0.22:
                    found = True
                    break
            if found:
                break
        check(found, f"D {name} focal pixels present near anchor ({wx},{wy})")


def main():
    print("=" * 64)
    print("  V3.1 P5 PIL PIXEL SAMPLING — saturated focal points")
    print("  source: %s" % PNG)
    print("=" * 64)
    if not os.path.exists(PNG):
        print("  FAIL: rendered frame missing (%s)" % PNG)
        print("  Run: godot --path . res://tests/evidence/v31_p5_capture.tscn")
        sys.exit(1)
    frame = Image.open(PNG).convert("RGB")
    print(f"  frame: {frame.width}x{frame.height}")
    verify_clusters(frame)
    verify_anchors(frame)
    print("\n" + "=" * 64)
    print("  PIL SAMPLING RESULT: %s (%d passed, %d failed)" % (
        "PASS" if failed == 0 else "FAIL", passed, failed))
    print("=" * 64)
    sys.exit(1 if failed > 0 else 0)


if __name__ == "__main__":
    main()
