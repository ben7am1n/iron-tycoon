#!/usr/bin/env python3
"""V3.1 R1 — PIL 像素采样证据：空间层级 / 物体-背景分离量化。

采样 tests/evidence/v31-r1-layer.png（window 模式渲染帧，主场景），用与
src/presentation/oblique_projection.gd 相同的投影数学复算采样点：

  proj(x, y, z) = (x + y*SHEAR - z*EXTRUDE_X, y*FLOOR_SCALE - z*HEIGHT_SCALE)

量化 R1 核心目标（「设备作为前景物体从深色地面分离」—— 3D diorama 空间层级）：

  A. 贴地 contact shadow：设备贴身带中位亮度 < 所在区域干净地板参照中位
     亮度（物体「坐」在地面，不漂浮）。median 对少量高亮装饰像素鲁棒。
     -- 采样带按设备取最可见侧（南侧默认；bike 南侧被 bench 顶面正确遮挡
        （diorama 深度），取西侧；bench 南侧需贴边 y+1..+3 以避开合并后
        的底部 UI 条带）。远处基线用区域干净地板窗口（bench 南侧更远在
        世界边界外 y>320 —— 不能用 footprint 南侧远窗）。
  B. 设备顶面 vs 地面分离：顶面（区域语义色/机身亮部）与所在区域地板在
     亮度上 |ΔL| >= 0.05（silhouette 从背景托起）。
  C. 设备脚下暖色亮池（HIGHLIGHT_WARM）：设备周边地面 R-B 比远处同区
     地面更暖（R1 新增暖白光，至少 3/5 台设备可测 —— 暖池在深色橡胶
     地面上的 R-B 提升，量级小但稳定）。

退出码：0 = 全部通过；1 = 有失败。
用法：python3 tests/evidence/v31_r1_layer_pil_sample.py
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
# contact shadow 采样带（side）：
#   south      —— 默认：footprint 南侧贴身带 y0+hh+2..+6
#   west       —— bike：南侧被 bench 顶面（z=26 挤出，屏幕四边形
#                 294..489 × 501..590）正确遮挡 —— diorama 深度，取西侧
#                 x0-3..x0+1 贴身带
#   south_tight —— bench：南侧贴身带 y0+hh+1..+3（合并 V3.1 返工 UI 后
#                 屏幕 y>=640 是底部 UI 条带，shadow 带必须贴边）；
#                 bench 西侧是前景盆栽、东侧是 medicine_ball 装饰。
EQUIP = [
    {"name": "treadmill_a", "fp": (64, 64, 64, 32), "h": 30.0, "check_b": True, "zone": "strength", "side": "south"},
    {"name": "bike",        "fp": (64, 160, 32, 32), "h": 36.0, "check_b": True, "zone": "strength", "side": "west"},
    {"name": "treadmill_b", "fp": (192, 96, 64, 32), "h": 30.0, "check_b": True, "zone": "cardio", "side": "south"},
    {"name": "bench",       "fp": (32, 224, 64, 64), "h": 26.0, "check_b": True, "zone": "strength", "side": "south_tight"},
    {"name": "yoga_mat",    "fp": (312, 64, 16, 32), "h": 6.0, "check_b": False, "zone": "flex", "side": "south"},
]

# === 区域干净地板参照（世界 px 窗口，经验证中屏、世界边界内、UI 条带之上） ===
# contact shadow 的「远处地面」基线：bench 南侧在世界边界外（y0+hh+ry+16≈348 > 320），
# footprint 南侧更远窗口会采到画布外/UI 像素；改用区域参照窗口（median 同法）。
ZONE_FLOOR_REF = {
    "strength": (120, 120, 24, 24),
    "cardio":   (240, 160, 24, 24),
    "flex":     (368, 200, 16, 16),
}


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


def _shadow_band(img: Image, eq) -> tuple:
    """设备 contact shadow 贴身带 → (亮度列表)。[side] 见 EQUIP 注释。"""
    x0, y0, w, hh = eq["fp"]
    side = eq["side"]
    if side == "south":
        return _collect(img, x0 + 6, y0 + hh + 2, w - 12, 5, 0.0, step=2)
    if side == "west":
        return _collect(img, x0 - 3, y0 + hh // 3, 5, hh // 2, 0.0, step=3)
    if side == "south_tight":
        return _collect(img, x0 + 4, y0 + hh + 1, w - 8, 3, 0.0, step=2)
    raise ValueError("unknown side %r" % side)


def verify_contact_shadow(img: Image) -> bool:
    print("\n-- A. 贴地 contact shadow（设备坐在地面，空间层级） --")
    ok_all = True
    for eq in EQUIP:
        sh_ls, _, _ = _shadow_band(img, eq)
        ref = ZONE_FLOOR_REF[eq["zone"]]
        far_ls, _, _ = _collect(img, ref[0], ref[1], ref[2], ref[3], 0.0, step=3)
        sh_l, far_l = _med(sh_ls), _med(far_ls)
        ok = sh_l < far_l
        ok_all = ok_all and ok
        print("  %s %s shadow=%.3f zoneRef=%.3f (grounding %.3f)"
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
            for xx in range(int(cx + rx + 12), int(cx + rx + 20), 2):
                p = screen(xx, yy, 0.0)
                if in_bounds(img, p):
                    far.append(r_minus_b(img.getpixel(p)))
        pool_rb, far_rb = _med(pool), _med(far)
        ok = pool_rb > far_rb
        ok_count += 1 if ok else 0
        print("  %s %s poolRB=%+d farRB=%+d (warmer %+d)"
              % ("PASS" if ok else "FAIL", eq["name"], int(pool_rb), int(far_rb),
                 int(pool_rb - far_rb)))
    ok = ok_count >= 3
    print("  RESULT C: %s (%d/5)" % ("PASS" if ok else "FAIL", ok_count))
    return ok


def main() -> int:
    if not os.path.exists(PNG):
        print("missing PNG: %s" % PNG)
        return 1
    img = Image.open(PNG).convert("RGB")
    ok_a = verify_contact_shadow(img)
    ok_b = verify_top_floor_separation(img)
    ok_c = verify_warm_pool(img)
    ok = ok_a and ok_b and ok_c
    print("\n======================================================================")
    print("  PIL SAMPLING RESULT: %s (%d passed, %d failed)" % (
        "PASS" if ok else "FAIL", sum([ok_a, ok_b, ok_c]), 3 - sum([ok_a, ok_b, ok_c])))
    print("======================================================================")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
