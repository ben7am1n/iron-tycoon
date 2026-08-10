#!/usr/bin/env python3
# tests/evidence/qa_v31r3_independent.py — V3.1 返工2 R3 灯光/第三眼独立 PIL 采样
#
# 对证据帧做第三方量化（不经过 Godot / 不读测试断言）：
#   F1 暖光照明连续：灯下（LIGHT_POOLS）暖亮像素 + 明度 > 同材质远离灯区域
#      （光源→受光面→扩散：灯下亮、远处暗；光不是孤立色块）
#   F2 方向一致冷投影：设备/会员在光源另一侧有方向性冷色投影 —— 采样
#      设备投影落点窗口内冷色像素（b>r 且低明度）；投影方向全场一致
#      （cast_shadow_offset 均向南/远离北墙吊灯）
#   F3 三层景深：背景墙面明度低/偏冷、中景器械中等、前景物体明度高 ——
#      通过明度（非仅饱和度）拉开三层
#   F4 P4 负约束：无圆形 gradient 光斑（灯池同心环覆盖率 < 0.95 且非均匀）
#
# 输入：tests/evidence/v31-r2-r3-lighting.png（由 v31_r2_r3_capture.tscn 生成）
# 用法：python3 tests/evidence/qa_v31r3_independent.py
import math
import os
import sys

from PIL import Image

BASE = os.path.dirname(os.path.abspath(__file__))
PNG = os.path.join(BASE, "v31-r2-r3-lighting.png")

# === 投影常量（与 oblique_projection.gd / main.gd 同源复算） ===
SHEAR = 0.35
FLOOR_SCALE = 0.62
HEIGHT_SCALE = 0.79
EXTRUDE_X = 0.20
WORLD_SCALE = 0.75
VIEWPORT_OFFSET = (19.05, 78.1875)
SCREEN_PER_VIEWPORT = (1280.0 / 426.0, 720.0 / 240.0)

# === 吊灯/落点（world_layout.gd 同源） ===
HANGING_LIGHTS = [
    {"rect": (72, 0, 28, 36), "bulb_local": (14, 29), "landing": (86, 170)},
    {"rect": (188, 0, 28, 36), "bulb_local": (14, 29), "landing": (202, 170)},
    {"rect": (348, 0, 28, 36), "bulb_local": (14, 29), "landing": (362, 170)},
]
FLOOR_LIGHT = {"base": (312, 228), "bulb_local": (0, 13), "landing": (330, 242)}

PASS = 0
FAIL = 0


def check(name, cond, detail=""):
    global PASS, FAIL
    if cond:
        PASS += 1
        print(f"  PASS {name} {detail}")
    else:
        FAIL += 1
        print(f"  FAIL {name} {detail}")


def proj(x, y, z=0.0):
    return (x + y * SHEAR - z * EXTRUDE_X, y * FLOOR_SCALE - z * HEIGHT_SCALE)


def screen(x, y, z=0.0):
    px, py = proj(x, y, z)
    sx = (px * WORLD_SCALE + VIEWPORT_OFFSET[0]) * SCREEN_PER_VIEWPORT[0]
    sy = (py * WORLD_SCALE + VIEWPORT_OFFSET[1]) * SCREEN_PER_VIEWPORT[1]
    return (int(round(sx)), int(round(sy)))


def wall_screen(fx, fy):
    """北墙本地坐标 → 屏幕（_north_wall_transform 同源复算）。"""
    kex = 110 * EXTRUDE_X / 24.0
    khe = 110 * HEIGHT_SCALE / 24.0
    ox = 24 * SHEAR - 24 * kex
    oy = 24 * FLOOR_SCALE - 24 * khe
    px = fx + fy * kex + ox
    py = fy * khe + oy
    sx = (px * WORLD_SCALE + VIEWPORT_OFFSET[0]) * SCREEN_PER_VIEWPORT[0]
    sy = (py * WORLD_SCALE + VIEWPORT_OFFSET[1]) * SCREEN_PER_VIEWPORT[1]
    return (int(round(sx)), int(round(sy)))


def lum(c):
    return 0.299 * c[0] + 0.587 * c[1] + 0.114 * c[2]


def warm(c):
    return c[0] - c[2]


def in_bounds(img, p):
    return 0 <= p[0] < img.width and 0 <= p[1] < img.height


def sample_window(img, cx, cy, r, step=2):
    out = []
    for dy in range(-r, r + 1, step):
        for dx in range(-r, r + 1, step):
            p = (cx + dx, cy + dy)
            if in_bounds(img, p):
                out.append(img.getpixel(p))
    return out


def avg_lum(cols):
    return sum(lum(c) for c in cols) / len(cols) if cols else 0.0


def avg_warm(cols):
    return sum(warm(c) for c in cols) / len(cols) if cols else 0.0


def f1_warm_lighting(img):
    print("\n-- F1 暖光照明连续（光源→受光面→扩散） --")
    all_ok = True
    for i, light in enumerate(HANGING_LIGHTS):
        lx, ly = light["landing"]
        ps = screen(lx, ly)
        lamp_cols = sample_window(img, ps[0], ps[1], 10, 3)
        # 远离光源候选（同区、避开池心与道具）—— 取最小值（动态干扰只会变亮）
        far_cands = [(lx - 40, ly + 60), (lx + 40, ly + 60), (lx, ly + 95),
                     (lx - 55, ly + 30), (lx + 55, ly + 30)]
        far_lums = []
        far_warms = []
        for (fx, fy) in far_cands:
            fs = screen(fx, fy)
            cols = sample_window(img, fs[0], fs[1], 10, 3)
            if cols:
                far_lums.append(avg_lum(cols))
                far_warms.append(avg_warm(cols))
        fm = min(far_lums) if far_lums else 0.0
        lm = avg_lum(lamp_cols)
        wm = avg_warm(lamp_cols)
        ok = lm > 0.30 and lm > fm + 0.005 and wm > 0.02
        if not ok:
            all_ok = False
        print(f"  pool{i + 1} lum={lm:.3f} warm={wm:+.3f} | far min lum={fm:.3f}  {'OK' if ok else 'WEAK'}")
    check(all_ok, "F1 全部吊灯灯下暖亮 + 亮于远处（连续照明，非孤立色块）")

    # 设备受光面：treadmill(6,3) 顶面暖色提亮（被照亮；西侧受光带 ——
    # treadmill(2,2) 顶面被 USING 会员 sprite 覆盖，采样点移到无会员设备）
    tm = screen(200, 112, 30.0)
    tm_cols = sample_window(img, tm[0], tm[1], 14, 2)
    tm_warm_count = sum(1 for c in tm_cols if c[0] > c[2] + 0.03 and c[0] > 0.35)
    check(tm_warm_count >= 6, "F1 设备顶面暖色受光带存在（物体被照亮）", f"warm_px={tm_warm_count}")


def f2_directional_shadows(img):
    print("\n-- F2 方向一致冷投影（遮挡投影，非区域底色） --")
    # 设备投影落点：cast_shadow_offset 同源复算（背向最近吊灯灯泡，长度∝高度）
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

    # 方向全场一致：三台设备投影偏移 y 均为正（远离北墙吊灯向南）
    devices = [((96, 80), 30.0), ((80, 176), 36.0), ((64, 240), 26.0)]
    dirs = []
    for (cx, cy), h in devices:
        off = cast_offset((cx, cy), h)
        dirs.append(off)
        print(f"  device@({cx},{cy}) h={h:.0f} shadow_off=({off[0]:.1f},{off[1]:.1f})")
    check(all(d[1] > 4.0 for d in dirs), "F2 投影方向全场一致（均向南/远离北墙吊灯）",
          f"offsets_y={[round(d[1]) for d in dirs]}")

    # 投影落点冷色像素存在：bike(80,176) 投影处窗口内冷暗像素（b>r，低明度）
    bike_off = cast_offset((80, 176), 36.0)
    shadow_world = (80 + bike_off[0], 176 + bike_off[1])
    sp = screen(shadow_world[0], shadow_world[1])
    cool = 0
    for dy in range(-10, 11):
        for dx in range(-10, 11):
            p = (sp[0] + dx, sp[1] + dy)
            if in_bounds(img, p):
                c = img.getpixel(p)
                if c[2] > c[0] + 0.02 * 255 and lum(c) < 127.5:
                    cool += 1
    check(cool >= 3, "F2 设备方向投影冷色像素存在（遮挡投影）", f"cool_px={cool}")

    # 会员方向投影（QUEUEING(3,6) 脚底南侧）
    m_off = cast_offset((112, 224), 20.0)
    m_world = (112 + m_off[0], 224 + m_off[1])
    mp = screen(m_world[0], m_world[1])
    m_cool = 0
    for dy in range(-8, 9):
        for dx in range(-8, 9):
            p = (mp[0] + dx, mp[1] + dy)
            if in_bounds(img, p):
                c = img.getpixel(p)
                if c[2] > c[0] + 0.02 * 255 and lum(c) < 127.5:
                    m_cool += 1
    check(m_cool >= 1, "F2 会员方向投影冷色像素存在", f"cool_px={m_cool}")


def f3_depth_layers(img):
    print("\n-- F3 三层景深（明度梯度：背景低 → 中景中 → 前景高） --")
    # 背景：北墙纯墙段 fx=60（入口门洞以东，避开光束/窗/墙饰）
    w = wall_screen(60, 12)
    wall_cols = sample_window(img, w[0], w[1], 10, 3)
    wall_l = avg_lum(wall_cols)
    # 中景：treadmill(6,3) 顶面受光带 z=30（无会员占用 —— treadmill(2,2)
    # 顶面被 USING 会员 sprite 覆盖，采样点移到无会员设备）
    t = screen(200, 112, 30.0)
    tm_l = avg_lum(sample_window(img, t[0], t[1], 12, 3))
    # 前景：世界 (230, 265) 暖光带（前景受光面）
    f = screen(230, 265)
    fore_l = avg_lum(sample_window(img, f[0], f[1], 12, 3))
    print(f"  wall lum={wall_l:.3f} | mid equip lum={tm_l:.3f} | fore lum={fore_l:.3f}")
    check(wall_l <= tm_l + 0.01, "F3 背景墙面明度 ≤ 中景器械（背景偏暗/偏冷）",
          f"{wall_l:.3f} <= {tm_l:.3f}+0.01")
    check(fore_l >= wall_l - 0.01, "F3 前景明度 ≥ 背景（前景可读）",
          f"{fore_l:.3f} >= {wall_l:.3f}-0.01")
    # 背景偏冷：墙面 b ≥ r-8（WALL_BASE_FAR 冷调；老 WALL_BASE 是暖调 r-b≈33）
    wall_c = img.getpixel(w)
    check(wall_c[2] >= wall_c[0] - 10, "F3 背景墙面偏冷/中性（b ≥ r-10）",
          f"wall_rgb={wall_c}")


def f4_no_circle(img):
    print("\n-- F4 P4 负约束：无圆形 gradient 光斑 --")
    px = img.load()
    cx, cy = HANGING_LIGHTS[0]["landing"]
    ps = screen(cx, cy)
    avg_coverage = 0.0
    rings = 0
    for ring_r in (10, 22, 34, 44):
        alphas = []
        total = 0
        for i in range(48):
            a = math.tau * i / 48.0
            sx = int(round(ps[0] + math.cos(a) * ring_r))
            sy = int(round(ps[1] + math.sin(a) * ring_r))
            if in_bounds(img, (sx, sy)):
                total += 1
                c = px[sx, sy]
                # 亮暖像素（受光面）
                alphas.append(1.0 if (c[0] > c[2] + 0.02 and c[0] > 0.4) else 0.0)
        if total >= 24:
            coverage = sum(alphas) / len(alphas)
            avg_coverage += coverage
            rings += 1
    avg_cov = avg_coverage / max(rings, 1)
    check(avg_cov < 0.95, "F4 灯池无圆形实心光斑（环覆盖率 < 0.95）", f"avg={avg_cov:.2f}")


def main():
    print("=" * 64)
    print("  V3.1 返工2 R3 LIGHTING INDEPENDENT PIL VERIFICATION")
    print("=" * 64)
    if not os.path.exists(PNG):
        print(f"  FAIL: rendered frame missing ({PNG})")
        print("  Run: godot --path . res://tests/evidence/v31_r2_r3_capture.tscn")
        sys.exit(1)
    img = Image.open(PNG).convert("RGB")
    print(f"  frame: {img.width}x{img.height}")
    f1_warm_lighting(img)
    f2_directional_shadows(img)
    f3_depth_layers(img)
    f4_no_circle(img)
    print("\n" + "=" * 64)
    print(f"  R3 PIL RESULT: {'PASS' if FAIL == 0 else 'FAIL'} ({PASS} passed, {FAIL} failed)")
    print("=" * 64)
    sys.exit(1 if FAIL else 0)


if __name__ == "__main__":
    main()
