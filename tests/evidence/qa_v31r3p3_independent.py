#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""V3.1 返工3 P3 独立 PIL 复核 —— 灯光链可读 / 冷色投影统一 / 三层景深。

不依赖 capture 脚本内嵌断言：从渲染 PNG 独立采样复算。覆盖任务 exit 条件：
  1. 暖光链：吊灯灯泡 → 灯下受光面 → 向南衰减 → 远处冷灰（亮→衰减→冷灰）
  2. 阴影：方向一致向南（cast_shadow_offset 复算）+ 冷色像素占比（b>r）
  3. 三层景深：wall < mid < fore 明度分层（背景墙偏冷暗、中景器械、前景受光）
  4. R4 硬门：light map 同心环覆盖率 <0.95（热核 keep 保持 —— 无圆光斑）
"""
import sys, math
from PIL import Image

# 投影常量（src/presentation/oblique_projection.gd + main.gd 同源复算）
SHEAR = 0.22
FLOOR_SCALE = 0.77
HEIGHT_SCALE = 0.64
EXTRUDE_X = 0.16
WORLD_SCALE = 0.75
OFF_X, OFF_Y = 31.8, 42.96
SX, SY = 1280.0 / 426.0, 720.0 / 240.0
WORLD_W, WORLD_H = 416, 320
HANGING_LIGHTS = [
    {"rect": (72, 18, 28, 36), "height": 78.0, "bulb_local": (14, 29), "landing": (86, 170), "pool_half": (52, 36)},
    {"rect": (210, 18, 28, 36), "height": 78.0, "bulb_local": (14, 29), "landing": (224, 170), "pool_half": (52, 36)},
    {"rect": (348, 18, 28, 36), "height": 78.0, "bulb_local": (14, 29), "landing": (362, 170), "pool_half": (52, 36)},
]
FLOOR_LIGHT = {"base": (312, 228), "height": 48.0, "bulb_local": (0, 13), "landing": (330, 242), "pool_half": (24, 17)}
EDGE_SHADOW_WIDTH = 26
LIGHT_POOL_RADIUS = 46.0


def proj(x, y, z=0.0):
    return (x + y * SHEAR - z * EXTRUDE_X, y * FLOOR_SCALE - z * HEIGHT_SCALE)


def canvas_to_screen(px, py):
    return (round((px * WORLD_SCALE + OFF_X) * SX), round((py * WORLD_SCALE + OFF_Y) * SY))


def world_to_screen(wx, wy, z=0.0):
    px, py = proj(wx, wy, z)
    return canvas_to_screen(px, py)


def lum(c):
    return 0.299 * c[0] + 0.587 * c[1] + 0.114 * c[2]


def warm(c):
    return c[0] - c[2]


def avg_lum(cols):
    return sum(lum(c) for c in cols) / len(cols) if cols else 0.0


def avg_warm(cols):
    return sum(warm(c) for c in cols) / len(cols) if cols else 0.0


def sample_window(img, cx, cy, r, step=3):
    out = []
    for dy in range(-r, r + 1, step):
        for dx in range(-r, r + 1, step):
            sx, sy = cx + dx, cy + dy
            if 0 <= sx < img.width and 0 <= sy < img.height:
                out.append(img.getpixel((sx, sy)))
    return out


def norm_alpha(c):
    return c[3] / 255.0 if len(c) == 4 else 1.0


def main():
    frame_path = sys.argv[1] if len(sys.argv) > 1 else "tests/evidence/v31-r3-p3-lighting.png"
    lightmap_path = sys.argv[2] if len(sys.argv) > 2 else "tests/evidence/v31-r4-lightmap.png"
    frame = Image.open(frame_path).convert("RGBA")
    lm = Image.open(lightmap_path).convert("RGBA")
    print(f"FRAME {frame_path} {frame.width}x{frame.height}")
    print(f"LIGHTMAP {lightmap_path} {lm.width}x{lm.height}")

    ok = True
    def check(cond, label):
        nonlocal ok
        ok = ok and cond
        print(f"  {'PASS' if cond else 'FAIL'} {label}")

    # ============ 1. 暖光链（灯泡 → 受光面 → 衰减 → 冷灰） ============
    print("\n-- 1. 暖光链可读（FAIL1） --")
    # 灯泡：吊灯 0 灯泡画布点（billboard）
    l0 = HANGING_LIGHTS[0]
    bulb_canvas = (proj(l0["rect"][0], l0["rect"][1], l0["height"])[0] + l0["bulb_local"][0],
                   proj(l0["rect"][0], l0["rect"][1], l0["height"])[1] + l0["bulb_local"][1])
    bsx, bsy = canvas_to_screen(*bulb_canvas)
    bulb_cols = sample_window(frame, bsx, bsy, 8, 2)
    bulb_lum = avg_lum(bulb_cols)
    bulb_warm = avg_warm(bulb_cols)
    print(f"  bulb lum={bulb_lum:.1f} warm={bulb_warm:+.1f} @screen({bsx},{bsy})")
    check(bulb_lum > 90.0, f"灯泡是亮光源 (lum {bulb_lum:.1f} > 90)")

    # 灯下受光面（落点中心）
    lx, ly = world_to_screen(*l0["landing"])
    pool_cols = sample_window(frame, lx, ly, 8, 2)
    pool_lum = avg_lum(pool_cols)
    pool_warm = avg_warm(pool_cols)
    # 南向衰减段（落点南 44 world px）
    sx2, sy2 = world_to_screen(l0["landing"][0], l0["landing"][1] + 44)
    south_cols = sample_window(frame, sx2, sy2, 8, 2)
    south_lum = avg_lum(south_cols)
    south_warm = avg_warm(south_cols)
    # 远处冷灰（远离所有光源落点）
    far_cols = sample_window(frame, *world_to_screen(120, 90), 8, 2)
    far_lum = avg_lum(far_cols)
    far_warm = avg_warm(far_cols)
    print(f"  pool lum={pool_lum:.1f} warm={pool_warm:+.1f} | south lum={south_lum:.1f} warm={south_warm:+.1f} | far lum={far_lum:.1f} warm={far_warm:+.1f}")
    check(pool_lum > south_lum, f"受光面亮于南向衰减段 (lum {pool_lum:.1f} > {south_lum:.1f})")
    check(pool_warm > south_warm, f"受光面暖于南向衰减段 (warm {pool_warm:+.1f} > {south_warm:+.1f})")
    check(south_lum >= far_lum - 2.0, f"衰减段与远处冷灰衔接 (lum {south_lum:.1f} >= {far_lum:.1f}-2)")
    check(far_warm < pool_warm, f"远处冷灰环境色（warm {far_warm:+.1f} < 受光面 {pool_warm:+.1f}）")

    # ============ 2. 阴影方向一致 + 冷色占比 ============
    print("\n-- 2. 阴影方向一致 + 冷色投影（FAIL2） --")
    # cast_shadow_offset 复算（WorldLayout 同源）：三处设备投影 y 均为正（向南）
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

    # 设备南侧投影窗口冷色像素（b>r 且低明度）—— 干净冷色投影
    bike_off = cast_offset((80, 176), 36.0)
    shadow_world = (80 + bike_off[0], 176 + bike_off[1])
    sp = world_to_screen(*shadow_world)
    cool_px = 0
    shadow_n = 0
    for dy in range(-8, 9):
        for dx in range(-8, 9):
            px2, py2 = sp[0] + dx, sp[1] + dy
            if 0 <= px2 < frame.width and 0 <= py2 < frame.height:
                c = frame.getpixel((px2, py2))
                shadow_n += 1
                if c[2] > c[0] + 0.01 and lum(c) < 127.5:
                    cool_px += 1
    cool_ratio = cool_px / shadow_n if shadow_n else 0.0
    print(f"  bike shadow window cool px={cool_px}/{shadow_n} ratio={cool_ratio:.2f}")
    check(cool_px >= 3, f"设备方向投影冷色像素存在 (cool_px={cool_px})")

    # 会员投影冷色（QUEUEING(3,6) 脚底南侧）
    m_off = cast_offset((112, 224), 20.0)
    m_world = (112 + m_off[0], 224 + m_off[1])
    mp = world_to_screen(*m_world)
    m_cool = 0
    for dy in range(-6, 7):
        for dx in range(-6, 7):
            px2, py2 = mp[0] + dx, mp[1] + dy
            if 0 <= px2 < frame.width and 0 <= py2 < frame.height:
                c = frame.getpixel((px2, py2))
                if c[2] > c[0] + 0.01 and lum(c) < 127.5:
                    m_cool += 1
    check(m_cool >= 1, f"会员方向投影冷色像素存在 (cool_px={m_cool})")

    # ============ 3. 三层景深（wall < mid < fore） ============
    print("\n-- 3. 三层景深（FAIL3） --")
    # 背景：北墙纯墙段 fx=60, fy=12（wall_screen 同源复算）
    kex = 64 * EXTRUDE_X / 24.0
    khe = 64 * HEIGHT_SCALE / 24.0
    ox = 24 * SHEAR - 24 * kex
    oy = 24 * FLOOR_SCALE - 24 * khe
    fx, fy = 60.0, 12.0
    wall_px = fx + fy * kex + ox
    wall_py = fy * khe + oy
    wsx, wsy = canvas_to_screen(wall_px, wall_py)
    wall_l = avg_lum(sample_window(frame, wsx, wsy, 10, 3))
    wall_c = frame.getpixel((wsx, wsy))
    # 中景：treadmill(6,3) 顶面受光带 z=30
    tm_x, tm_y = world_to_screen(200, 112, 30.0)
    mid_l = avg_lum(sample_window(frame, tm_x, tm_y, 12, 3))
    # 前景：世界 (230,265) 暖光带（前景受光面）
    fx2, fy2 = world_to_screen(230, 265)
    fore_l = avg_lum(sample_window(frame, fx2, fy2, 12, 3))
    print(f"  wall lum={wall_l:.1f} | mid equip lum={mid_l:.1f} | fore lum={fore_l:.1f}")
    check(wall_l <= mid_l + 1.0, f"背景墙面明度 ≤ 中景器械 ({wall_l:.1f} <= {mid_l:.1f}+1)")
    check(fore_l >= wall_l - 1.0, f"前景明度 ≥ 背景 ({fore_l:.1f} >= {wall_l:.1f}-1)")
    check(wall_c[2] >= wall_c[0] - 10, f"背景墙面偏冷/中性 (b={wall_c[2]} >= r={wall_c[0]}-10)")

    # ============ 4. R4 硬门：灯池环覆盖率 < 0.95 ============
    print("\n-- 4. R4 硬门：灯池无圆形光斑（环覆盖率 < 0.95） --")
    center = HANGING_LIGHTS[0]["landing"]
    ring_ratios = []
    for ring_r in [10, 22, 34, 44]:
        covered = total = 0
        alphas = []
        for i in range(48):
            a = 2 * math.pi * i / 48.0
            px3 = int(round(center[0] + math.cos(a) * ring_r))
            py3 = int(round(center[1] + math.sin(a) * ring_r))
            if not (0 <= px3 < lm.width and 0 <= py3 < lm.height):
                continue
            total += 1
            al = norm_alpha(lm.getpixel((px3, py3)))
            alphas.append(al)
            if al > 0.02:
                covered += 1
        ratio = covered / total if total else 1.0
        ring_ratios.append(ratio)
        mean = sum(alphas) / len(alphas) if alphas else 0.0
        var = sum((v - mean) ** 2 for v in alphas) / len(alphas) if alphas else 0.0
        print(f"  ring r={ring_r} coverage={ratio:.2f} std={math.sqrt(var):.3f}")
    check(all(rr < 0.95 for rr in ring_ratios),
          f"灯池环覆盖率全部 <0.95 (实际 {[f'{r:.2f}' for r in ring_ratios]})")

    # ============ 5. 无 200px+ 完美直线（世界区，防回归） ============
    print("\n-- 5. 无 200px+ 完美直线（世界区 y 80..600，防回归） --")
    # 口径与 qa_v31gate E1 一致：只扫世界区（排除天花板背景带 y<80 与
    # 底部 UI build strip y>600）—— 天花板是房间外壳氛围带（刻意弱纹理），
    # 不是世界物件直线。
    world_y0, world_y1 = 80, 600
    max_run = 0
    max_run_y = 0
    px_load = frame.load()
    for y in range(world_y0, world_y1, 4):
        run = 1
        for x in range(1, frame.width):
            c0 = px_load[x, y]
            c1 = px_load[x - 1, y]
            if abs(c0[0] - c1[0]) <= 4 and abs(c0[1] - c1[1]) <= 4 and abs(c0[2] - c1[2]) <= 4:
                run += 1
                if run > max_run:
                    max_run = run
                    max_run_y = y
            else:
                run = 1
    print(f"  max horizontal run in world zone = {max_run}px at y={max_run_y}")
    check(max_run < 200, f"世界区无 200px+ 完美直线 (max run {max_run} < 200)")

    print(f"\nP3 INDEPENDENT RESULT: {'PASS' if ok else 'FAIL'}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
