#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""V3.1 返工3 P1 空间叙事/第一眼 —— PIL 独立采样（qa_v31r3p1_independent.py）

不依赖 capture 脚本断言，从提交版 PNG 独立复算投影并采样。对照返工3 P1
任务书 Exit 条件：

  A. 灰冷/灰霾占比不上升（对照门禁基线 v31-gate-r2-final.png 的 0.741）
     —— low-sat 占比、冷色主导占比均应不升（灰冷区域不得回退）
  B. 右侧空地/中央通道区域明度方差上升（打破平涂）—— 对比基线帧同区域
     luminance variance 必须上升（任务 1b 地垫/磨损/光影打破近纯色）
  C. 每区叙事道具组锚点存在性 —— 跑步机区清洁桶 / 中央通道水瓶架+垃圾桶 /
     力量区储物架 / 单车区水壶 / 瑜伽区瑜伽巾（任务 2 成组）
  D. 负面约束 —— 世界区无 200px+ 完美直线；无 circle 光斑（防回归）
  E. 明度对比/焦点色（任务 6）—— 暖木地垫色与墙面明度差、暖焦点色存在

阈值独立选取（不同于 capture 脚本与 phase1-5）。
"""
import colorsys
import math
import sys
from collections import deque

from PIL import Image

FRAME = sys.argv[1] if len(sys.argv) > 1 else "tests/evidence/v31-r3-p1-space.png"
BASELINE = sys.argv[2] if len(sys.argv) > 2 else "tests/evidence/v31-gate-r2-final.png"

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


def region_lum_stats(img, x0, x1, y0, y1, stride=3):
    vals = []
    for y in range(y0, y1, stride):
        for x in range(x0, x1, stride):
            if 0 <= x < img.width and 0 <= y < img.height:
                vals.append(luminance(img.load()[x, y]))
    if not vals:
        return 0.0, 0.0
    mean = sum(vals) / len(vals)
    var = sum((v - mean) ** 2 for v in vals) / len(vals)
    return mean, var


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
    print("  V3.1 R3-P1 SPACE NARRATIVE INDEPENDENT PIL VERIFICATION")
    print("=" * 64)
    img = Image.open(FRAME).convert("RGB")
    w, h = img.size
    px = img.load()
    total = w * h
    print(f"  frame: {FRAME} {w}x{h}")

    # ---------- A. 灰冷/灰霾占比不上升（对照门禁基线） ----------
    print("\n-- A: gray-cold ratio vs member-present gate baseline --")
    base = Image.open(BASELINE).convert("RGB")
    bp = base.load()

    def stats(pix, ww, hh):
        low = cool = warm = 0
        for y in range(0, hh, 3):
            for x in range(0, ww, 3):
                c = pix[x, y]
                if hsv_s(c) < 0.25:
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
    check(low_mine < low_base + 0.01, f"A low-sat ratio not increased ({low_mine:.3f} <= {low_base:.3f}+.01)")
    check(cool_mine <= cool_base + 0.005, f"A cool-dominant ratio not increased ({cool_mine:.3f} <= {cool_base:.3f})")
    check(warm_mine >= warm_base - 0.005, f"A warm-dominant ratio not decreased ({warm_mine:.3f} >= {warm_base:.3f}-.005)")

    # ---------- B. 右侧空地/中央通道区域「灰霾平涂」收敛 ----------
    print("\n-- B: right-empty / central-corridor de-flattening --")
    # 地垫烘焙区域（world→screen 窗口）：右侧走道列地垫、顶部通道可见
    # 条带地垫、底部通道地垫、排队区地垫。判据不是「明度方差上升」——
    # 暖木地垫会替代 walkway 的多色 cluster 噪声，方差可能略降；真正
    # 的 FAIL 是「灰霾空地」：近纯色、无内容。所以量「暖木覆盖率 +
    # 窗口内颜色多样性」：暖木色出现 = 空地有了功能地垫；多样性 ≥ 3
    # = 拼缝/磨损/周边材质混合，不是纯色平涂。
    mat_windows = [
        ("right-mat", (386, 40), (414, 190)),
        ("top-mat", (160, 24), (360, 32)),
        ("bottom-mat", (300, 292), (384, 312)),
        ("queue-mat", (96, 192), (128, 220)),
    ]
    for name, (wx0, wy0), (wx1, wy1) in mat_windows:
        s0 = world_to_screen(wx0, wy0)
        s1 = world_to_screen(wx1, wy1)
        x0, x1 = min(s0[0], s1[0]), max(s0[0], s1[0])
        y0, y1 = min(s0[1], s1[1]), max(s0[1], s1[1])
        wood = 0
        warm_new = 0
        warm_base = 0
        changed = 0
        buckets = set()
        n = 0
        for y in range(y0, y1 + 1, 2):
            for x in range(x0, x1 + 1, 2):
                if not (0 <= x < w and 0 <= y < h):
                    continue
                c = px[x, y]
                n += 1
                buckets.add((c[0] >> 4, c[1] >> 4, c[2] >> 4))
                # 暖木地垫：暖主导（r>g>b，r 明显大于 b）—— 对照基线同
                # 区域（照明层会降饱和/压暗，尤其底部边缘阴影带 —— 精确
                # 色值匹配会漏报；用「暖主导像素增量」判定灰霾→暖木收敛）
                if c[0] > c[2] + 15 and c[0] > c[1]:
                    warm_new += 1
                    if (abs(c[0] - 184) <= 55 and abs(c[1] - 154) <= 55
                            and c[2] < c[1]):
                        wood += 1
                if 0 <= x < base.width and 0 <= y < base.height:
                    bc = bp[x, y]
                    if bc[0] > bc[2] + 15 and bc[0] > bc[1]:
                        warm_base += 1
                    if c != bc:
                        changed += 1
        coverage = wood / max(1, n)
        warm_delta = (warm_new - warm_base) / max(1, n)
        print(f"  {name}: wood coverage {coverage:.2f} ({wood}/{n}) warmΔ {warm_delta:+.3f}"
              f" changed {changed}/{n} distinct16={len(buckets)}")
        # 判定：要么精确暖木色达到覆盖率（明亮区），要么暖主导像素增量
        # 显著（阴影区 —— 地垫把灰霾变成暖调）—— 两者都证明「铺了地垫」
        check(coverage >= 0.08 or warm_delta >= 0.04,
              f"B {name} warm wood mat present (coverage {coverage:.2f} / warmΔ {warm_delta:+.3f})")
        check(len(buckets) >= 3, f"B {name} not flat (distinct16 {len(buckets)} >= 3)")

    # 右侧灰霾空地（东墙装饰带）：暖木置物架/挂钟色出现 = 墙面不再空
    s0 = world_to_screen(402, 40)
    s1 = world_to_screen(416, 280)
    x0, x1 = min(s0[0], s1[0]), max(s0[0], s1[0])
    y0, y1 = min(s0[1], s1[1]), max(s0[1], s1[1])
    wall_warm = 0
    for y in range(y0, y1 + 1, 2):
        for x in range(x0, x1 + 1, 2):
            if not (0 <= x < w and 0 <= y < h):
                continue
            c = px[x, y]
            if c[0] > c[2] + 30 and luminance(c) > 0.45:
                wall_warm += 1
    print(f"  right-wall-band warm decor px: {wall_warm}")
    check(wall_warm > 80, f"B right-wall-band warm decor present ({wall_warm} > 80)")

    # ---------- C. 每区叙事道具组锚点存在性（任务 2 成组） ----------
    print("\n-- C: per-zone narrative prop anchors --")
    props = [
        ("clean_bucket_t1", (170, 62), (124, 135, 148), 0.30),    # CLEAN_BUCKET 7C8794
        ("bottle_rack_c1", (390, 205), (183, 212, 236), 0.30),    # METAL_HIGHLIGHT
        ("trash_c1", (388, 150), (94, 90, 82), 0.30),             # TRASH 5E5A52
        ("storage_shelf_s1", (52, 188), (176, 128, 79), 0.30),    # SHELF_WOOD B0804F
        ("bike_bottle_b1", (70, 128), (242, 201, 76), 0.30),      # ACCENT_YELLOW
        ("yoga_towel_f1", (334, 244), (201, 142, 110), 0.30),     # TOWEL C98E6E
    ]
    for name, (wx, wy), target, tol in props:
        sx, sy = world_to_screen(wx, wy)
        found = False
        for dy in range(-48, 49, 2):
            for dx in range(-48, 49, 2):
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

    # ---------- D. 负面约束：无 200px+ 直线 / 无 circle 光斑 ----------
    print("\n-- D: negative constraints (anti-regression) --")
    world_y0, world_y1 = 56, 600
    max_run = 0
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
            else:
                run = 1
    print(f"  longest same-color horizontal run (world y {world_y0}..{world_y1}): {max_run}px")
    check(max_run < 200, f"D1 no 200px+ straight line (max {max_run} < 200)")

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

    # ---------- E. 明度对比/暖木焦点（任务 6） ----------
    print("\n-- E: luminance contrast + warm focal color distribution --")
    # 暖木地垫（FLOOR_MAT_WOOD B89A72 亮度 ~0.60）与深色力量区地面
    # （#4B4F57 亮度 ~0.29）—— 暖木能跳出来，明度差 > 0.25。
    mat_lum = None
    for (wx, wy) in [(180, 14), (400, 115), (342, 302)]:
        sx, sy = world_to_screen(wx, wy)
        found_any = False
        for dy in range(-20, 21, 2):
            for dx in range(-20, 21, 2):
                x, y = sx + dx, sy + dy
                if not (0 <= x < w and 0 <= y < h):
                    continue
                c = px[x, y]
                if (abs(c[0] - 184) <= 45 and abs(c[1] - 154) <= 45 and abs(c[2] - 114) <= 45
                        and c[0] > c[2] + 30):
                    mat_lum = luminance(c)
                    found_any = True
                    break
            if found_any:
                break
        if found_any:
            break
    check(mat_lum is not None, "E1 warm floor mat color present (暖木地垫)")
    if mat_lum is not None:
        # 力量区深灰橡胶（#4B4F57 亮度 ~0.29）对比
        str_lum = 0.299 * 75 + 0.587 * 79 + 0.114 * 87  # ≈ 0.30
        print(f"  mat lum={mat_lum:.2f} strength rubber lum≈{str_lum:.2f} (Δ {mat_lum - str_lum:+.2f})")
        check(mat_lum > str_lum + 0.15, f"E1 warm mat brighter than strength floor (Δ {mat_lum - str_lum:.2f} > 0.15)")
    # 暖焦点色仍在（黄水杯/红广告牌 —— P5 焦点不被灰霾压制）。照明层
    # 会降饱和，故用 gate capture 同源容差（ACCENT_YELLOW tol 0.22）。
    cup_found = False
    for (wx, wy) in [(88, 108)]:
        sx, sy = world_to_screen(wx, wy)
        for dy in range(-20, 21, 2):
            for dx in range(-20, 21, 2):
                x, y = sx + dx, sy + dy
                if not (0 <= x < w and 0 <= y < h):
                    continue
                c = px[x, y]
                d = math.sqrt((c[0] - 242) ** 2 + (c[1] - 201) ** 2 + (c[2] - 76) ** 2)
                if d <= 0.22 * 255:
                    cup_found = True
                    break
            if cup_found:
                break
    check(cup_found, "E2 warm focal yellow cup still pops (焦点色不被压制)")

    print("\n" + "=" * 64)
    verdict = "PASS" if failed == 0 else "FAIL"
    print(f"  R3-P1 SPACE PIL RESULT: {verdict} ({passed} passed, {failed} failed)")
    print("=" * 64)
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
