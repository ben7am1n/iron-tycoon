#!/usr/bin/env python3
"""V3.1 R1 — PIL 像素采样证据：空间层级 / 物体-背景分离量化。

采样 tests/evidence/v31-r1-layer.png（window 模式渲染帧，主场景），用与
src/presentation/oblique_projection.gd 相同的投影数学复算采样点：

  proj(x, y, z) = (x + y*SHEAR - z*EXTRUDE_X, y*FLOOR_SCALE - z*HEIGHT_SCALE)
  screen = (proj * WORLD_SCALE + WORLD_VIEWPORT_OFFSET) * SCREEN_PER_VIEWPORT

R1 目标（视觉规格附录 V3.1 R1）：画面读出 3D diorama —— 设备作为前景物体
从深色地面分离，不是贴地图标。量化断言：

  A. 贴地 contact shadow（空间层级）：每台设备底边南侧 2..5px 平均亮度
     低于同 x 远处地板（y 再往南 24px+）平均亮度 —— 物体「坐」在地面上，
     不漂浮。5/5 设备必须成立。
  B. 设备顶面与所在区域地板分离（silhouette 托起）：顶面中心窗口平均亮度
     与远处地板平均亮度之差 >= 0.05（对力量区深色地板设备；瑜伽垫低矮且
     西半被前景柱正确遮挡，取其东半可见部分）。4/5 设备成立即可（瑜伽垫
     扁平低对比例外，B 只对 4 台立体设备断言）。
  C. 暖色亮池（R1 新增）：设备脚下地面（footprint 东侧池内）比远处同区
     地板更暖（R-B 差更高）。至少 3/5 设备成立（flex 木地板本身暖 +89，
     池效果被背景色淹没，为已知例外）。

用法：python3 tests/evidence/v31_r1_layer_pil_sample.py
退出码：0 = 全部通过；1 = 有失败。
"""
import math
import os
import statistics
import sys
from PIL import Image

EVIDENCE_DIR = os.path.dirname(os.path.abspath(__file__))
PNG = os.path.join(EVIDENCE_DIR, "v31-r1-layer.png")

# === 投影常量（与 oblique_projection.gd / main.gd 同源复算） ===
SHEAR = 0.35
FLOOR_SCALE = 0.62
HEIGHT_SCALE = 0.79
EXTRUDE_X = 0.20
WORLD_SCALE = 0.75
VIEWPORT_OFFSET = (19.05, 78.1875)
SCREEN_PER_VIEWPORT = (1280.0 / 426.0, 720.0 / 240.0)


def proj(x: float, y: float, z: float = 0.0):
    return (x + y * SHEAR - z * EXTRUDE_X, y * FLOOR_SCALE - z * HEIGHT_SCALE)


def screen(x: float, y: float, z: float = 0.0):
    px, py = proj(x, y, z)
    sx = (px * WORLD_SCALE + VIEWPORT_OFFSET[0]) * SCREEN_PER_VIEWPORT[0]
    sy = (py * WORLD_SCALE + VIEWPORT_OFFSET[1]) * SCREEN_PER_VIEWPORT[1]
    return (int(math.floor(sx + 0.5)), int(math.floor(sy + 0.5)))


def in_bounds(img: Image, p) -> bool:
    return 0 <= p[0] < img.width and 0 <= p[1] < img.height


def luminance(c) -> float:
    return (0.299 * c[0] + 0.587 * c[1] + 0.114 * c[2]) / 255.0


def saturation(c) -> float:
    mx = max(c) / 255.0
    mn = min(c) / 255.0
    return (mx - mn) / mx if mx > 0 else 0.0


def r_minus_b(c) -> float:
    return float(c[0] - c[2])


# === 初始布局设备（footprint 世界 px + 顶面高度，与 main.gd 同源） ===
# V3.1 R1：yoga_mat(9,2) 西半被前景 column_2 正确遮挡（diorama 深度），
# 顶面采样取东半 (312..328, 64..96) 可见部分。
EQUIP = [
    {"name": "treadmill_a", "fp": (64, 64, 64, 32), "h": 30.0, "check_b": True},
    {"name": "bike",        "fp": (64, 160, 32, 32), "h": 36.0, "check_b": True},
    {"name": "treadmill_b", "fp": (192, 96, 64, 32), "h": 30.0, "check_b": True},
    {"name": "bench",       "fp": (32, 224, 64, 64), "h": 26.0, "check_b": True},
    {"name": "yoga_mat",    "fp": (312, 64, 16, 32), "h": 6.0, "check_b": False},
]


def _collect(img: Image, x0, y0, w, h, z, step=3):
    """世界窗口内采样 → (亮度列表, 饱和度列表, R-B 列表)。"""
    ls, ss, rbs = [], [], []
    for yy in range(int(y0), int(y0) + int(h), int(step)):
        for xx in range(int(x0), int(x0) + int(w), int(step)):
            p = screen(xx, yy, z)
            if in_bounds(img, p):
                c = img.getpixel(p)
                ls.append(luminance(c))
                ss.append(saturation(c))
                rbs.append(r_minus_b(c))
    return ls, ss, rbs


def _med(v):
    return statistics.median(v) if v else 0.0


def verify_contact_shadow(img: Image) -> bool:
    print("\n-- A. 贴地 contact shadow（设备坐在地面，空间层级） --")
    ok_all = True
    for eq in EQUIP:
        x0, y0, w, hh = eq["fp"]
        ry = hh * 0.62 + 4.0
        sh_ls, _, _ = _collect(img, x0 + 6, y0 + hh + 2, w - 12, 5, 0.0, step=2)
        far_ls, _, _ = _collect(img, x0 + 6, y0 + hh + ry + 16, w - 12, 10, 0.0, step=3)
        sh_l, far_l = _med(sh_ls), _med(far_ls)
        ok = sh_l < far_l
        ok_all = ok_all and ok
        print("  %s %s shadow=%.3f far=%.3f (grounding %.3f)"
              % ("PASS" if ok else "FAIL", eq["name"], sh_l, far_l, far_l - sh_l))
    print("  RESULT A: %s" % ("PASS" if ok_all else "FAIL"))
    return ok_all


def verify_top_floor_separation(img: Image) -> bool:
    print("\n-- B. 设备顶面 vs 地面分离（silhouette 托起，|ΔL| >= 0.05） --")
    ok_all = True
    for eq in EQUIP:
        if not eq["check_b"]:
            continue
        x0, y0, w, hh = eq["fp"]
        ry = hh * 0.62 + 4.0
        top_ls, _, _ = _collect(img, x0 + 3, y0 + 3, w - 6, hh - 6, eq["h"])
        far_ls, _, _ = _collect(img, x0 + 6, y0 + hh + ry + 16, w - 12, 10, 0.0, step=3)
        top_l, far_l = _med(top_ls), _med(far_ls)
        ok = abs(top_l - far_l) >= 0.05
        ok_all = ok_all and ok
        print("  %s %s top=%.3f far=%.3f |ΔL|=%.3f"
              % ("PASS" if ok else "FAIL", eq["name"], top_l, far_l, abs(top_l - far_l)))
    print("  RESULT B: %s" % ("PASS" if ok_all else "FAIL"))
    return ok_all


def verify_warm_pool(img: Image) -> bool:
    print("\n-- C. 设备脚下暖色亮池（R-B 更暖 >= 3/5） --")
    ok_count = 0
    for eq in EQUIP:
        x0, y0, w, hh = eq["fp"]
        ry = hh * 0.62 + 4.0
        rx = w * 0.72 + 4.0
        cx, cy = x0 + w / 2.0, y0 + hh / 2.0
        pool, far = [], []
        for yy in range(int(cy - 6), int(cy) + 7, 3):
            for xx in range(int(cx + rx - 8), int(cx + rx), 2):
                dx, dy = xx - cx, yy - cy
                if (dx / rx) ** 2 + (dy / ry) ** 2 <= 1.0:
                    p = screen(xx, yy, 0.0)
                    if in_bounds(img, p):
                        pool.append(r_minus_b(img.getpixel(p)))
        for yy in range(int(cy - 6), int(cy) + 7, 3):
            for xx in range(int(cx + rx + 12), int(cx + rx + 20), 3):
                p = screen(xx, yy, 0.0)
                if in_bounds(img, p):
                    far.append(r_minus_b(img.getpixel(p)))
        pool_rb = _med(pool)
        far_rb = _med(far)
        ok = pool_rb > far_rb
        ok_count += 1 if ok else 0
        print("  %s %s poolRB=%+.0f farRB=%+.0f (warmer %.0f)"
              % ("PASS" if ok else "FAIL", eq["name"], pool_rb, far_rb, pool_rb - far_rb))
    ok_all = ok_count >= 3
    print("  RESULT C: %s (%d/5)" % ("PASS" if ok_all else "FAIL", ok_count))
    return ok_all


def main() -> int:
    img = Image.open(PNG).convert("RGB")
    results = [
        verify_contact_shadow(img),
        verify_top_floor_separation(img),
        verify_warm_pool(img),
    ]
    passed = sum(1 for r in results if r)
    print("\n======================================================================")
    print("  PIL SAMPLING RESULT: %s (%d passed, %d failed)"
          % ("PASS" if all(results) else "FAIL", passed, len(results) - passed))
    print("======================================================================")
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
