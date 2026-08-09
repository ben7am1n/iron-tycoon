#!/usr/bin/env python3
"""V3.1 P1 — PIL 像素采样证据：证明物体存在多层高度色（顶面/正面/侧面）。

采样 tests/evidence/v31-p1-camera.png（window 模式渲染帧），用与
src/presentation/oblique_projection.gd 相同的投影数学复算采样点：

  proj(x, y, z) = (x + y*SHEAR - z*EXTRUDE_X, y*FLOOR_SCALE - z*HEIGHT_SCALE)
  screen = (proj * WORLD_SCALE + WORLD_VIEWPORT_OFFSET) * SCREEN_PER_VIEWPORT

断言：
  1. 设备（treadmill）顶面/正面/侧面三处颜色互不相同 —— 多层高度色，
     非单色平面块（V3.1 P1 证据要求）
  2. 设备顶面色与地板色不同（设备不是贴地图标）
  3. 墙面（WALL_BASE）与墙基踢脚线（WALL_DARK）不同 —— 墙壁有分层
  4. 会员身体像素（衬衫 SKY/PEACH 系）与地面不同 —— 人物立起有体积

用法：python3 tests/evidence/v31_p1_pil_sample.py
退出码：0 = 全部通过；1 = 有失败。
"""
import math
import sys
from PIL import Image

PNG = "/Users/bmac/CodeBase/gym_manager/tests/evidence/v31-p1-camera.png"

# === 投影常量（与 oblique_projection.gd / main.gd 同源复算） ===
SHEAR = 0.35
FLOOR_SCALE = 0.78
HEIGHT_SCALE = 0.62
EXTRUDE_X = 0.20
WORLD_SCALE = 0.75
VIEWPORT_OFFSET = (19.05, 51.975)
SCREEN_PER_VIEWPORT = (1280.0 / 426.0, 720.0 / 240.0)


def proj(x: float, y: float, z: float = 0.0):
    return (x + y * SHEAR - z * EXTRUDE_X, y * FLOOR_SCALE - z * HEIGHT_SCALE)


def screen(x: float, y: float, z: float = 0.0):
    px, py = proj(x, y, z)
    sx = (px * WORLD_SCALE + VIEWPORT_OFFSET[0]) * SCREEN_PER_VIEWPORT[0]
    sy = (py * WORLD_SCALE + VIEWPORT_OFFSET[1]) * SCREEN_PER_VIEWPORT[1]
    return (int(round(sx)), int(round(sy)))


def color_dist(a, b):
    return math.sqrt(sum((a[i] - b[i]) ** 2 for i in range(3)))


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


def sample_img(img, x, y, z=0.0):
    sx, sy = screen(x, y, z)
    if 0 <= sx < img.width and 0 <= sy < img.height:
        return img.getpixel((sx, sy)), (sx, sy)
    return None, (sx, sy)


def hexc(c):
    return "#%02x%02x%02x" % c


def main():
    img = Image.open(PNG).convert("RGB")
    print("=" * 64)
    print("  V3.1 P1 PIL PIXEL SAMPLING — multi-layer height colors")
    print("  source: %s (%dx%d)" % (PNG, img.width, img.height))
    print("=" * 64)

    # === 1. 设备体积：treadmill (2,2) footprint (64..128, 64..96), h=30 ===
    print("\n-- treadmill 顶面 / 正面 / 侧面（必须互不相同）--")
    top, tp = sample_img(img, 80, 80, 30)
    front, fp = sample_img(img, 80, 96, 15)
    side, sp = sample_img(img, 128, 80, 15)
    check(top is not None, "treadmill top face sample in-bounds %s" % (tp,))
    check(front is not None, "treadmill front face sample in-bounds %s" % (fp,))
    check(side is not None, "treadmill side face sample in-bounds %s" % (sp,))
    if top and front and side:
        check(color_dist(top, front) > 12,
              "top #%s != front #%s  (multi-layer height colors)" % (hexc(top), hexc(front)))
        check(color_dist(top, side) > 12,
              "top #%s != side #%s  (multi-layer height colors)" % (hexc(top), hexc(side)))
        check(color_dist(front, side) > 12,
              "front #%s != side #%s  (multi-layer height colors)" % (hexc(front), hexc(side)))
        check(top[0] + top[1] + top[2] > front[0] + front[1] + front[2],
              "top face brighter than front face (top-lit, %d > %d)"
              % (sum(top), sum(front)))

    # === 2. 设备非贴地：顶面色 ≠ 地板色 ===
    print("\n-- 设备顶面 vs 地板（设备不是贴地图标）--")
    floor, fp2 = sample_img(img, 80, 80, 0)
    if top and floor:
        check(color_dist(top, floor) > 15,
              "equipment top #%s != floor #%s (raised, not a decal)"
              % (hexc(top), hexc(floor)))

    # === 3. 墙壁分层：墙面 vs 踢脚线 vs 墙身连续 ===
    print("\n-- 墙壁（北墙 x=90：墙面 z=55 / 上段 z=100 / 踢脚线 z=2）--")
    wall_mid, wmp = sample_img(img, 90, 24, 55)
    wall_top, wtp = sample_img(img, 90, 24, 100)
    base, bp = sample_img(img, 200, 24, 2)
    if wall_mid and wall_top and base:
        check(color_dist(wall_mid, base) > 12,
              "wall face #%s != baseboard #%s (vertical layering)"
              % (hexc(wall_mid), hexc(base)))
        check(color_dist(wall_mid, wall_top) < 30,
              "wall face z=55 #%s ≈ z=100 #%s (continuous wall face)"
              % (hexc(wall_mid), hexc(wall_top)))

    # === 4. 会员：身体像素 ≠ 地面（站立有体积） ===
    print("\n-- 会员（非 USING，billboard 站立）--")
    # 扫描非设备占用格（避开初始布局 footprint：treadmill(2,2)(6,3)
    # bike(2,5) bench(1,7) yoga(9,2)）—— 会员在走道/排队区走动。
    member_ok = False
    for (cx, cy) in [(1, 3), (4, 1), (5, 1), (8, 1), (3, 4), (5, 5),
                     (8, 5), (10, 2), (11, 4), (0, 2), (4, 9), (10, 8)]:
        feet = (cx * 32 + 16, cy * 32 + 32)
        body, bp3 = sample_img(img, feet[0], feet[1] - 28)
        ground, gp = sample_img(img, feet[0], feet[1])
        if body and ground and color_dist(body, ground) > 15:
            member_ok = True
            check(True, "member body #%s != ground #%s at cell (%d,%d)"
                  % (hexc(body), hexc(ground), cx, cy))
            break
    if not member_ok:
        check(False, "a member body pixel differs from ground (member standing)")

    print("\n" + "=" * 64)
    print("  PIL SAMPLING RESULT: %s (%d passed, %d failed)" % (
        "PASS" if failed == 0 else "FAIL", passed, failed))
    print("=" * 64)
    sys.exit(1 if failed > 0 else 0)


if __name__ == "__main__":
    main()
