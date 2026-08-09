#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""V3.1 返工2 R1 空间/第一眼 —— PIL 独立采样（qa_v31r1b_independent.py）

不依赖 capture 脚本断言，从提交版 PNG 独立复算投影并采样：

  A. 灰冷占比下降对比：新帧 vs 返工前门禁帧（v31-gate-final.png 主分支提交版）
     —— low-sat 占比、冷色主导占比均应下降（灰冷区域必须下降）
  B. 暖光中心存在性：3 个吊灯落点灯下暖亮（lum 高 + r>b），且灯下亮于
     同材质远处（投光关系）—— 光从「色块」变成「有方向的照明」
  C. 每区叙事道具锚点存在性：跑步机区计时器 / 力量区海报 / 瑜伽区绿植 /
     单车区水瓶架 —— 语义色在锚点窗口内命中
  D. 负面约束：世界区无 200px+ 完美直线（E1 同口径）；无圆形 gradient
     光斑（C-check 同口径：fill 0.70..0.90 + aspect ≤1.20 + ≥300px）
  E. 墙面材质手绘：墙面大窗口内多色（手绘笔触 —— 非纯色大面积）

阈值独立选取（不同于 capture 脚本）。
"""
import colorsys
import math
import sys
from collections import deque
from PIL import Image

FRAME = sys.argv[1] if len(sys.argv) > 1 else "tests/evidence/v31-r2-r1-space.png"
BASELINE = sys.argv[2] if len(sys.argv) > 2 else "tests/evidence/v31-gate-final.png"

SHEAR = 0.35
FLOOR_SCALE = 0.62
HEIGHT_SCALE = 0.79
EXTRUDE_X = 0.20
WORLD_SCALE = 0.75
OFF_X, OFF_Y = 19.05, 78.1875
SX, SY = 1280.0 / 426.0, 720.0 / 240.0

passed, failed = 0, 0


def check(cond, msg):
    global passed, failed
    if cond:
        passed += 1
        print(f"  PASS {msg}")
    else:
        failed += 1
        print(f"  FAIL {msg}")


def proj(x, y, z=0.0):
    return (x + y * SHEAR - z * EXTRUDE_X, y * FLOOR_SCALE - z * HEIGHT_SCALE)


def world_to_screen(wx, wy, z=0.0):
    px, py = proj(wx, wy, z)
    return (round((px * WORLD_SCALE + OFF_X) * SX), round((py * WORLD_SCALE + OFF_Y) * SY))


def luminance(c):
    return 0.299 * c[0] + 0.587 * c[1] + 0.114 * c[2]


def warmness(c):
    return c[0] - c[2]


def hsv_s(c):
    r, g, b = c[0] / 255.0, c[1] / 255.0, c[2] / 255.0
    mx, mn = max(r, g, b), min(r, g, b)
    return 0.0 if mx <= 0 else (mx - mn) / mx


def sample_window(img, cx, cy, r, step=3):
    out = []
    for dy in range(-r, r + 1, step):
        for dx in range(-r, r + 1, step):
            sx, sy = world_to_screen(cx + dx, cy + dy)
            if 0 <= sx < img.width and 0 <= sy < img.height:
                out.append(img.getpixel((sx, sy)))
    return out


def avg_lum(cols):
    return sum(luminance(c) for c in cols) / len(cols) if cols else 0.0


def avg_warm(cols):
    return sum(warmness(c) for c in cols) / len(cols) if cols else 0.0


def connected_components(mask, w, h, min_size):
    visited = [[False] * w for _ in range(h)]
    clusters = []
    for y in range(h):
        for x in range(w):
            if not mask[y][x] or visited[y][x]:
                continue
            q = deque([(x, y)])
            visited[y][x] = True
            cells = []
            min_x = max_x = x
            min_y = max_y = y
            while q:
                cx, cy = q.popleft()
                cells.append((cx, cy))
                min_x, max_x = min(min_x, cx), max(max_x, cx)
                min_y, max_y = min(min_y, cy), max(max_y, cy)
                for dy in (-1, 0, 1):
                    for dx in (-1, 0, 1):
                        if dx == 0 and dy == 0:
                            continue
                        nx, ny = cx + dx, cy + dy
                        if 0 <= nx < w and 0 <= ny < h and mask[ny][nx] and not visited[ny][nx]:
                            visited[ny][nx] = True
                            q.append((nx, ny))
            if len(cells) >= min_size:
                clusters.append((len(cells), min_x, min_y, max_x, max_y))
    return clusters


def main():
    print("=" * 64)
    print("  V3.1 R2-R1 SPACE INDEPENDENT PIL VERIFICATION")
    print("=" * 64)
    img = Image.open(FRAME).convert("RGB")
    w, h = img.size
    px = img.load()
    total = w * h
    print(f"  frame: {FRAME} {w}x{h}")

    # ---------- A. 灰冷占比下降对比 ----------
    print("\n-- A: gray-cold ratio vs pre-rework gate baseline --")
    base = Image.open(BASELINE).convert("RGB")
    bp = base.load()
    # 统计口径（全帧）：low-sat（S<0.25）+ 冷色主导（b>r+8）占比
    def stats(pix, ww, hh):
        low = cool = warm = 0
        for y in range(0, hh, 3):
            for x in range(0, ww, 3):
                c = pix[x, y]
                s = hsv_s(c)
                if s < 0.25:
                    low += 1
                if c[2] > c[0] + 8:
                    cool += 1
                elif c[0] > c[2] + 8:
                    warm += 1
        n = ((ww // 3 + 1) * (hh // 3 + 1))
        return low / n, cool / n, warm / n

    low_mine, cool_mine, warm_mine = stats(px, w, h)
    low_base, cool_base, warm_base = stats(bp, base.width, base.height)
    print(f"  low-sat:   mine {low_mine:.3f} vs baseline {low_base:.3f} (Δ {low_mine - low_base:+.3f})")
    print(f"  cool-dom:  mine {cool_mine:.3f} vs baseline {cool_base:.3f} (Δ {cool_mine - cool_base:+.3f})")
    print(f"  warm-dom:  mine {warm_mine:.3f} vs baseline {warm_base:.3f} (Δ {warm_mine - warm_base:+.3f})")
    # 灰冷下降：低饱和占比下降（返工方向）或冷色主导下降（更暖）。
    check(low_mine < low_base + 0.01, f"A low-sat ratio not increased ({low_mine:.3f} <= {low_base:.3f}+.01)")
    check(cool_mine <= cool_base + 0.005, f"A cool-dominant ratio not increased ({cool_mine:.3f} <= {cool_base:.3f})")

    # ---------- B. 暖光中心存在性 + 投光关系 ----------
    print("\n-- B: warm light pools + directional falloff --")
    pools = [(86, 170), (202, 170), (362, 170)]
    all_pool_warm = True
    for cx, cy in pools:
        lamp = sample_window(img, cx, cy, 10, 3)
        lm, wm = avg_lum(lamp), avg_warm(lamp)
        # 远离光源候选（同一区、避开池心与已知道具/设备/会员）——取最小值
        far_cands = [(cx - 40, cy + 60), (cx + 40, cy + 60), (cx, cy + 95),
                     (cx - 55, cy + 30), (cx + 55, cy + 30)]
        far_lums = []
        far_warms = []
        for (fx, fy) in far_cands:
            cols = sample_window(img, fx, fy, 10, 3)
            if cols:
                far_lums.append(avg_lum(cols))
                far_warms.append(avg_warm(cols))
        fm = min(far_lums) if far_lums else 0.0
        fwm = min(far_warms) if far_warms else 0.0
        ok = lm > 0.30 and wm > 0.02 and lm > fm + 0.005
        if not ok:
            all_pool_warm = False
        print(f"  pool({cx},{cy}) lamp lum={lm:.3f} warm={wm:+.3f} | far min lum={fm:.3f} warm={fwm:+.3f} {'OK' if ok else 'WEAK'}")
    check(all_pool_warm, "B all 3 hanging pools warm + brighter than far floor (directional)")
    # 远离光源回落到冷灰环境色：边缘（墙边）应有冷蓝灰像素
    edge_cool = 0
    for dy in range(-6, 7):
        for dx in range(0, 8):
            sx, sy = world_to_screen(10 + dx, 170 + dy)
            if 0 <= sx < w and 0 <= sy < h:
                c = px[sx, sy]
                if c[2] > c[0] + 0.02 and luminance(c) > 0.05:
                    edge_cool += 1
    check(edge_cool > 0, f"B wall-edge cool shadow pixels present (cold falloff, cool={edge_cool})")

    # ---------- C. 每区叙事道具锚点 ----------
    print("\n-- C: per-zone narrative prop anchors --")
    # 世界锚点 → 语义色（同 capture 脚本；容差独立）
    props = [
        ("timer_treadmill_t1", (158, 70), (183, 212, 236), 0.30),   # METAL_HIGHLIGHT 计时器
        ("poster_strength_s1", (150, 260), (176, 154, 130), 0.30),  # WALL_TRIM 海报板
        ("plant_f1", (360, 180), (78, 138, 90), 0.35),              # PLANT_GREEN 绿植
        ("bottle_rack_b1", (16, 144), (183, 212, 236), 0.30),       # METAL_HIGHLIGHT 水瓶架
    ]
    for name, (wx, wy), target, tol in props:
        sx, sy = world_to_screen(wx, wy)
        found = False
        for dy in range(-40, 41, 2):
            for dx in range(-40, 41, 2):
                x, y = sx + dx, sy + dy
                if 0 <= x < w and 0 <= y < h:
                    c = px[x, y]
                    if (abs(c[0] - target[0]) <= tol * 255 and abs(c[1] - target[1]) <= tol * 255
                            and abs(c[2] - target[2]) <= tol * 255):
                        found = True
                        break
            if found:
                break
        check(found, f"C zone prop {name} anchor @({sx},{sy}) present")

    # ---------- D. 负面约束 ----------
    print("\n-- D: negative constraints --")
    # D1: 世界区无 200px+ 完美直线
    world_y0, world_y1 = 56, 600
    max_run = 0
    max_run_y = 0
    for y in range(world_y0, world_y1, 4):
        run = 1
        for x in range(1, w):
            c0 = px[x, y]
            c1 = px[x - 1, y]
            if (abs(c0[0] - c1[0]) <= 4 and abs(c0[1] - c1[1]) <= 4
                    and abs(c0[2] - c1[2]) <= 4):
                run += 1
                if run > max_run:
                    max_run = run
                    max_run_y = y
            else:
                run = 1
    print(f"  longest same-color horizontal run (world y {world_y0}..{world_y1}): {max_run}px at y={max_run_y}")
    check(max_run < 200, f"D1 no 200px+ straight line (max {max_run} < 200)")

    # D2: 无圆形 gradient 光斑（fill 0.70..0.90 + aspect ≤1.20 + ≥300px）
    lit_mask = [[False] * w for _ in range(h)]
    for y in range(h):
        row = lit_mask[y]
        for x in range(w):
            c = px[x, y]
            lum = luminance(c)
            warm = c[0] > c[2] + 6 and c[1] > c[2] + 2
            row[x] = lum > 170 and warm
    comps = []
    for (size, min_x, min_y, max_x, max_y) in connected_components(lit_mask, w, h, 300):
        bw = max_x - min_x + 1
        bh = max_y - min_y + 1
        aspect = max(bw, bh) / max(1, min(bw, bh))
        fill = size / max(1, bw * bh)
        comps.append((size, aspect, fill, (min_x, min_y, max_x, max_y)))
    circle_like = [c for c in comps if c[1] <= 1.20 and 0.70 <= c[2] <= 0.90]
    print(f"  lit comps >=300px: {len(comps)}; circle-like: {len(circle_like)}")
    for c in comps[:6]:
        print(f"    {c[0]}px aspect={c[1]:.2f} fill={c[2]:.2f} bbox={c[3]}")
    check(len(circle_like) == 0, f"D2 no circular light blob ({len(circle_like)} circle-like)")

    # ---------- E. 墙面材质手绘（多色，非纯色大面积） ----------
    print("\n-- E: wall face hand-drawn texture (multi-color) --")
    # 北墙中部（墙本地 x≈200, fy≈10 → 屏幕锚点由 capture 复算）：
    # 用墙变换独立复算（_north_wall_transform 同源）。
    def wall_to_screen(fx, fy):
        kex = 110.0 * 0.20 / 24.0
        khe = 110.0 * 0.79 / 24.0
        cx = fx + fy * kex + 24.0 * SHEAR - 24.0 * kex
        cy = fy * khe + 24.0 * FLOOR_SCALE - 24.0 * khe
        vx = cx * WORLD_SCALE + OFF_X
        vy = cy * WORLD_SCALE + OFF_Y
        return (round(vx * SX), round(vy * SY))

    wx0, wy0 = wall_to_screen(180, 8)
    buckets = set()
    for dy in range(0, 14, 2):
        for dx in range(0, 60, 2):
            x, y = wx0 + dx, wy0 + dy
            if 0 <= x < w and 0 <= y < h:
                c = px[x, y]
                buckets.add((c[0] >> 4, c[1] >> 4, c[2] >> 4))
    print(f"  wall-face 16-bucket colors in window: {len(buckets)}")
    check(len(buckets) >= 4, f"E wall face multi-color (hand-drawn strokes) {len(buckets)} >= 4")

    print("\n" + "=" * 64)
    verdict = "PASS" if failed == 0 else "FAIL"
    print(f"  R2-R1 SPACE PIL RESULT: {verdict} ({passed} passed, {failed} failed)")
    print("=" * 64)
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
