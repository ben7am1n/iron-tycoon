#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""独立 PIL 复核：R4 暖色灯光源/投光关系 + 负面约束（无圆形 gradient 光斑、无半透明白圆）。
不依赖 capture 脚本，直接从 PNG 采样，独立复算投影。
"""
import sys, math
from PIL import Image

# ---- 投影常量（src/presentation/oblique_projection.gd + main.gd 独立复算）----
SHEAR = 0.35
FLOOR_SCALE = 0.62
HEIGHT_SCALE = 0.79
EXTRUDE_X = 0.20
WORLD_SCALE = 0.75
OFF_X, OFF_Y = 19.05, 78.1875
SX, SY = 1280.0 / 426.0, 720.0 / 240.0
WORLD_W, WORLD_H = 416, 320

def proj(x, y, z=0.0):
    return (x + y * SHEAR - z * EXTRUDE_X, y * FLOOR_SCALE - z * HEIGHT_SCALE)

def world_to_screen(wx, wy, z=0.0):
    px, py = proj(wx, wy, z)
    return (round((px * WORLD_SCALE + OFF_X) * SX), round((py * WORLD_SCALE + OFF_Y) * SY))

def canvas_to_screen(px, py):
    return (round((px * WORLD_SCALE + OFF_X) * SX), round((py * WORLD_SCALE + OFF_Y) * SY))

def luminance(c):
    return 0.299 * c[0] + 0.587 * c[1] + 0.114 * c[2]

def warmness(c):
    return c[0] - c[2]

def avg_lum(cols):
    return sum(luminance(c) for c in cols) / len(cols) if cols else 0.0

def avg_warm(cols):
    return sum(warmness(c) for c in cols) / len(cols) if cols else 0.0

def sample_window(img, cx, cy, r, step=3):
    out = []
    for dy in range(-r, r + 1, step):
        for dx in range(-r, r + 1, step):
            sx, sy = world_to_screen(cx + dx, cy + dy)
            if 0 <= sx < img.width and 0 <= sy < img.height:
                out.append(img.getpixel((sx, sy)))
    return out

def norm_alpha(c):
    return c[3] / 255.0 if len(c) == 4 else 1.0

def results():
    return []

def main():
    frame_path = sys.argv[1] if len(sys.argv) > 1 else "tests/evidence/v31-r4-lighting.png"
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

    # ============ A. 渲染帧：灯下 vs 远处（投光关系 + 色温对比） ============
    # 灯池 0 中心 (86,170)，同材质远处候选（capture 脚本同锚点）
    lamp = sample_window(frame, 86, 170, 10, 3)
    far_cands = [(120, 90), (60, 130), (130, 140), (60, 200)]
    far_lums, far_warm = [], []
    for fx, fy in far_cands:
        cols = sample_window(frame, fx, fy, 10, 3)
        far_lums.append(avg_lum(cols))
        far_warm.append(avg_warm(cols))
    far_min_lum = min(far_lums)
    far_min_warm = min(far_warm)
    lamp_lum = avg_lum(lamp)
    lamp_warm = avg_warm(lamp)
    print(f"  lamp lum={lamp_lum:.3f} warm={lamp_warm:+.3f} | far min lum={far_min_lum:.3f} warm={far_min_warm:+.3f}")
    check(lamp_lum > far_min_lum + 0.005, f"投光关系: 灯下亮于远处 (lum {lamp_lum:.3f} > {far_min_lum:.3f})")
    check(lamp_warm > far_min_warm + 0.002, f"灯下暖于远处 (warm {lamp_warm:+.3f} > {far_min_warm:+.3f})")

    # ============ B. 渲染帧：光源物件可辨识（吊灯灯罩附近暖橙/暖白） ============
    # 吊灯 hanging_lamp_1: rect(72,0,28,36) height 78, bulb_local (14,29)
    # canvas = proj(rect.pos, height) + bulb_local
    rect_x, rect_y = 72.0, 0.0
    h = 78.0
    bulb_canvas = proj(rect_x, rect_y, h)
    bulb_canvas = (bulb_canvas[0] + 14.0, bulb_canvas[1] + 29.0)
    bsx, bsy = canvas_to_screen(*bulb_canvas)
    # 灯罩暖橙金 LAMP_SHADE_LIT 附近：扫描 24px 窗口找 warm bright 像素
    shade_hits = 0
    warm_core_hits = 0
    for dy in range(-24, 25):
        for dx in range(-24, 25):
            sx, sy = bsx + dx, bsy + dy
            if not (0 <= sx < frame.width and 0 <= sy < frame.height):
                continue
            c = frame.getpixel((sx, sy))
            if c[0] > c[2] + 0.02 and luminance(c) > 0.25:
                warm_core_hits += 1
            if c[0] > 150 and 90 < c[1] < 200 and c[2] < 130 and luminance(c) > 0.3:
                shade_hits += 1
    print(f"  lamp fixture @screen({bsx},{bsy}) shade_hits={shade_hits} warm_core_hits={warm_core_hits}")
    check(shade_hits > 0 or warm_core_hits > 5, "光源物件可辨识: 吊灯灯罩/暖白核心在帧中可见")

    # ============ C. 渲染帧：冷色阴影（墙边暗角冷蓝灰 b>r） ============
    cool = 0
    for dy in range(-6, 7):
        for dx in range(0, 8):
            sx, sy = world_to_screen(10 + dx, 170 + dy)
            if 0 <= sx < frame.width and 0 <= sy < frame.height:
                c = frame.getpixel((sx, sy))
                if c[2] > c[0] + 0.02 and luminance(c) > 0.05:
                    cool += 1
    check(cool > 0, f"冷色阴影: 墙边暗角冷蓝灰像素存在 (cool={cool})")

    # ============ D. lightmap：灯池中心 vs 墙边 alpha（灯下亮、远处暗） ============
    def lm_window_alpha(cx, cy, r):
        vals = []
        for y in range(max(0, cy - r), min(lm.height, cy + r + 1)):
            for x in range(max(0, cx - r), min(lm.width, cx + r + 1)):
                vals.append(norm_alpha(lm.getpixel((x, y))))
        return sum(vals) / len(vals) if vals else 0.0

    lamp_a = lm_window_alpha(86, 170, 6)
    edge_a = lm_window_alpha(10, 170, 6)
    print(f"  lightmap lamp avg alpha={lamp_a:.3f} edge avg alpha={edge_a:.3f}")
    check(lamp_a > edge_a, f"lightmap 灯下亮于墙边 (alpha {lamp_a:.3f} > {edge_a:.3f})")

    # ============ E. 负面约束：无圆形 gradient 光斑 / 无半透明白圆 ============
    # 独立同心环采样（世界像素半径，与 capture 脚本一致的锚点与阈值，但独立实现）
    center = (86.0, 170.0)
    ring_ratios = []
    for ring_r in [10, 22, 34, 44]:
        covered = total = 0
        alphas = []
        for i in range(48):
            a = 2 * math.pi * i / 48.0
            px = int(round(center[0] + math.cos(a) * ring_r))
            py = int(round(center[1] + math.sin(a) * ring_r))
            if not (0 <= px < lm.width and 0 <= py < lm.height):
                continue
            total += 1
            al = norm_alpha(lm.getpixel((px, py)))
            alphas.append(al)
            if al > 0.02:
                covered += 1
        ratio = covered / total if total else 1.0
        ring_ratios.append(ratio)
        mean = sum(alphas) / len(alphas) if alphas else 0.0
        var = sum((v - mean) ** 2 for v in alphas) / len(alphas) if alphas else 0.0
        print(f"  ring r={ring_r} coverage={ratio:.2f} std={math.sqrt(var):.3f}")
    check(all(rr < 0.95 for rr in ring_ratios), f"负约束: 灯池环覆盖率全部 <0.95 (实际 {[f'{r:.2f}' for r in ring_ratios]})")

    # 额外：热核区（metric<0.25 → keep=0.98）的视觉范围 —— 计算 r=10 环上落入
    # 热核（keep=0.98 区）的比例，量化「实心核心」半径
    hx, hy = 44.0, 30.0
    hot_count = 0
    for i in range(48):
        a = 2 * math.pi * i / 48.0
        px = 86.0 + math.cos(a) * 10
        py = 170.0 + math.sin(a) * 10
        nx = abs(px - 86.0) / hx
        ny = abs(py - 170.0) / hy
        metric = max(nx, ny) * 0.62 + (nx + ny) * 0.22
        if metric < 0.25:
            hot_count += 1
    print(f"  r=10 环落入热核(keep=0.98)比例: {hot_count}/48")

    # ============ F. 落地灯暖池 ============
    fp = world_to_screen(330, 242)
    floor_found = 0
    for dy in range(-6, 7):
        for dx in range(-6, 7):
            sx, sy = fp[0] + dx, fp[1] + dy
            if 0 <= sx < frame.width and 0 <= sy < frame.height:
                c = frame.getpixel((sx, sy))
                if c[0] > c[2] + 0.02 and luminance(c) > 0.30:
                    floor_found += 1
    check(floor_found > 0, f"落地灯投光: 灯下暖池可见 (hits={floor_found})")

    # 落地灯灯体发光（暖橙罩）@screen
    fb = proj(312.0, 228.0, 48.0)
    fbx, fby = canvas_to_screen(fb[0] + 0.0, fb[1] + 13.0)
    body_hits = 0
    for dy in range(-18, 19):
        for dx in range(-18, 19):
            sx, sy = fbx + dx, fby + dy
            if 0 <= sx < frame.width and 0 <= sy < frame.height:
                c = frame.getpixel((sx, sy))
                if c[0] > 150 and 90 < c[1] < 210 and c[2] < 140 and luminance(c) > 0.25:
                    body_hits += 1
    check(body_hits > 4, f"落地灯灯体发光可见 (hits={body_hits})")

    print(f"\nINDEPENDENT RESULT: {'PASS' if ok else 'FAIL'}")
    return 0 if ok else 1

if __name__ == "__main__":
    sys.exit(main())
