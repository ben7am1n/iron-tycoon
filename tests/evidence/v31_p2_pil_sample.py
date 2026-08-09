#!/usr/bin/env python3
"""V3.1 P2 — PIL 像素采样证据：每台设备 3 方向面 + 5 色层 + 立体体积。

采样两类图像：
  1. 原始面纹理表 tests/evidence/v31-p2-faces-<eq>.png（capture 脚本导出，
     top | front | side 三面并排，未变暗/未受光照层污染）—— 精确验证
     5 色层（base/shadow/outline/highlight/accent）在每台设备每个方向面
     sprite 像素中都可找到（V3.1 P2 最低要求）。
  2. 渲染帧 tests/evidence/v31-p2-equipment.png（window 模式主场景）——
     世界采样验证设备是立体物件：footprint 区域多色、顶面亮于正面、
     接触影贴地（设备离开地面、非贴地图标）。

断言（与 tests/evidence/v31_p1_pil_sample.py 同源复算，投影数学来自
src/presentation/oblique_projection.gd）：
  A. 每台设备 × 每面（top/front/side）5 色层全存在
  B. 渲染帧：treadmill(2,2) 顶面亮于正面（三面分层）
  C. 渲染帧：treadmill 前端 console 青蓝显示可辨（真控制台）

用法：python3 tests/evidence/v31_p2_pil_sample.py
退出码：0 = 全部通过；1 = 有失败。
"""
import math
import os
import sys
from PIL import Image

EVIDENCE_DIR = os.path.dirname(os.path.abspath(__file__))
PNG = os.path.join(EVIDENCE_DIR, "v31-p2-equipment.png")
FACES_PATTERN = os.path.join(EVIDENCE_DIR, "v31-p2-faces-%s.png")

# === 投影常量（与 oblique_projection.gd / main.gd 同源复算） ===
SHEAR = 0.35
FLOOR_SCALE = 0.62
HEIGHT_SCALE = 0.79
EXTRUDE_X = 0.20
WORLD_SCALE = 0.75
VIEWPORT_OFFSET = (19.05, 78.1875)
SCREEN_PER_VIEWPORT = (1280.0 / 426.0, 720.0 / 240.0)

# === palette.gd 层色（单一来源复算；容差按渲染光照污染放宽） ===
EQUIP_BODY_DARK = (0x49 / 255, 0x52 / 255, 0x5F / 255)
EQUIP_BODY = (0x5D / 255, 0x66 / 255, 0x73 / 255)
EQUIP_BODY_LIGHT = (0x8E / 255, 0x99 / 255, 0xA6 / 255)
METAL_DARK = (0x5B / 255, 0x64 / 255, 0x70 / 255)
EQUIP_SHADOW_TONE = (0x3A / 255, 0x43 / 255, 0x50 / 255)
EQUIP_OUTLINE = (0x3B / 255, 0x45 / 255, 0x52 / 255)
EQUIP_HIGHLIGHT = (0xEA / 255, 0xDF / 255, 0xB8 / 255)
METAL_HIGHLIGHT = (0xB7 / 255, 0xD4 / 255, 0xEC / 255)
EQUIP_ACCENT_CYAN = (0x2F / 255, 0xC4 / 255, 0xE8 / 255)  # 2FC4E8（P5 提高饱和后的 palette 单一来源）
EMISSIVE_CYAN = (0x4F / 255, 0xD8 / 255, 0xE8 / 255)
ZONE_COLORS = {
    "cardio": (0x8E / 255, 0xC5 / 255, 0xE8 / 255),     # SKY
    "strength": (0x8F / 255, 0xBF / 255, 0x9F / 255),   # SAGE
}

EQUIP_HEIGHTS = {"treadmill": 30.0, "bike": 36.0, "bench_press": 26.0}
EQUIP_RECTS = {
    "treadmill": (64, 64, 64, 32),     # x, y, w, h (world px)
    "bike": (64, 160, 32, 32),
    "bench_press": (32, 224, 64, 64),
}
ZONE_OF = {"treadmill": "cardio", "bike": "cardio", "bench_press": "strength"}


def proj(x: float, y: float, z: float = 0.0):
    return (x + y * SHEAR - z * EXTRUDE_X, y * FLOOR_SCALE - z * HEIGHT_SCALE)


def screen(x: float, y: float, z: float = 0.0):
    px, py = proj(x, y, z)
    sx = (px * WORLD_SCALE + VIEWPORT_OFFSET[0]) * SCREEN_PER_VIEWPORT[0]
    sy = (py * WORLD_SCALE + VIEWPORT_OFFSET[1]) * SCREEN_PER_VIEWPORT[1]
    return (int(round(sx)), int(round(sy)))


def color_dist(a, b):
    return math.sqrt(sum((a[i] - b[i]) ** 2 for i in range(3)))


def hexc(c):
    return "#%02x%02x%02x" % tuple(int(round(v * 255)) for v in c[:3])


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


def layer_colors_for(zone: str):
    return {
        "base": [EQUIP_BODY_DARK, EQUIP_BODY, EQUIP_BODY_LIGHT, METAL_DARK],
        "shadow": [EQUIP_SHADOW_TONE],
        "outline": [EQUIP_OUTLINE],
        "highlight": [EQUIP_HIGHLIGHT, METAL_HIGHLIGHT],
        "accent": [EQUIP_ACCENT_CYAN, ZONE_COLORS[zone]],
    }


def img_contains(img, color, tol):
    """True if any opaque pixel within tol (0-1 normalized) of color."""
    w, h = img.size
    px = img.load()
    for y in range(h):
        for x in range(w):
            c = px[x, y]
            if len(c) >= 4 and c[3] < 128:
                continue
            # PIL 返回 0-255 int；color 是 0-1 float —— 归一化后比较
            cn = (c[0] / 255.0, c[1] / 255.0, c[2] / 255.0)
            if color_dist(cn, color) <= tol:
                return True
    return False


def verify_face_sheets():
    print("\n-- A. 原始面纹理表：每台设备 × 每面 5 色层 --")
    for eq in ["treadmill", "bike", "bench_press"]:
        path = FACES_PATTERN % eq
        check(os.path.exists(path), f"{eq} face sheet exists ({os.path.basename(path)})")
        if not os.path.exists(path):
            continue
        sheet = Image.open(path).convert("RGBA")
        zone = ZONE_OF[eq]
        layers = layer_colors_for(zone)
        # 从表尺寸反推三面宽度：top 宽 = 顶面纹理宽 = rect w × 2? 不 —
        # capture 直接用 Image 尺寸。用固定规则：top | front | side 并排。
        # 由 capture 导出，三面并排；这里按区域切分：top 宽 = rect_w*2 像素？
        # 实际 ART_SCALE=2 → top 宽 = rect_w * 2 / CELL * ART_PER_CELL… 简化：
        # 直接扫描全表即可 —— 5 层在任一面上存在即可，且每面分别验证：
        # 我们按宽度比例切三份（top=rect.w*2, front=rect.w*2, side=rect.h*2）
        rect = EQUIP_RECTS[eq]
        # 纹理像素宽度 = art px × ART_SCALE；art px = 世界 px（footprint 直接
        # 1:1 画入 Rect2(fp.position, fp.size)）。capture 的 sheet 三面并排：
        # top 宽 = rect.w（世界 px = 纹理 px），front 宽 = rect.w，
        # side 宽 = rect.h（footprint 深度）。
        top_w = rect[2]
        front_w = rect[2]
        side_w = rect[3]
        # 容差：纹理未变暗 → 精确（0.02）；但 PIL 的 RGB 8bit 量化 → 0.03
        tol = 0.03
        # top 面
        top_region = sheet.crop((0, 0, top_w, sheet.height))
        # front 面（top 之后 + 2px 空隙）
        front_x = top_w + 2
        front_region = sheet.crop((front_x, 0, front_x + front_w, sheet.height))
        # side 面
        side_x = front_x + front_w + 2
        side_region = sheet.crop((side_x, 0, side_x + side_w, sheet.height))
        for fname, region in [("top", top_region), ("front", front_region), ("side", side_region)]:
            for layer, colors in layers.items():
                found = any(img_contains(region, c, tol) for c in colors)
                check(found, f"A {eq}.{fname} has {layer} (5 layers)")
        print(f"  -- {eq} sheet done (top w={top_w}, front w={front_w}, side w={side_w})")


def sample_px(img, x, y, z=0.0):
    sx, sy = screen(x, y, z)
    if 0 <= sx < img.width and 0 <= sy < img.height:
        return img.getpixel((sx, sy)), (sx, sy)
    return None, (sx, sy)


def verify_rendered_scene():
    print("\n-- B. 渲染帧：设备是立体物件（非贴地图标） --")
    check(os.path.exists(PNG), f"rendered frame exists ({os.path.basename(PNG)})")
    if not os.path.exists(PNG):
        return
    img = Image.open(PNG).convert("RGB")
    # B1. 三台设备 footprint 区域多色（顶面+正面+侧面+阴影 → ≥4 独立色）
    for eq in ["treadmill", "bike", "bench_press"]:
        x0, y0, w, h = EQUIP_RECTS[eq]
        colors = set()
        px = img.load()
        for wy in range(y0, y0 + h, 8):
            for wx in range(x0, x0 + w, 8):
                sx, sy = screen(wx, wy, 0)
                if 0 <= sx < img.width and 0 <= sy < img.height:
                    colors.add(px[sx, sy])
        distinct = len(colors)
        check(distinct >= 4, f"B {eq} footprint region has >=4 distinct colors (got {distinct})")
    # B2. treadmill(2,2)：顶面亮于正面（三面分层：顶亮/正中/侧暗）
    tm_rect = EQUIP_RECTS["treadmill"]
    top_c, tp = sample_px(img, tm_rect[0] + 16, tm_rect[1] + 16, EQUIP_HEIGHTS["treadmill"])
    front_c, fp = sample_px(img, tm_rect[0] + 16, tm_rect[1] + tm_rect[3], EQUIP_HEIGHTS["treadmill"] * 0.5)
    if top_c and front_c:
        def lum(c):
            return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]
        check(lum(top_c) > lum(front_c) + 0.03,
              f"B treadmill top lum {lum(top_c):.3f} > front lum {lum(front_c):.3f} (lit top)")
    else:
        check(False, "B treadmill top/front sample in bounds")
    # B3. treadmill 顶面南端 console 青蓝显示可辨（真控制台）
    found_cyan = False
    for dy in range(-4, 5):
        for dx in range(-4, 5):
            c, p = sample_px(img, tm_rect[0] + 16, tm_rect[1] + 28,
                             EQUIP_HEIGHTS["treadmill"])
            if not c:
                continue
            sx, sy = p
            sx += dx
            sy += dy
            if 0 <= sx < img.width and 0 <= sy < img.height:
                raw = img.getpixel((sx, sy))
                cc = (raw[0] / 255.0, raw[1] / 255.0, raw[2] / 255.0)
                if color_dist(cc, EQUIP_ACCENT_CYAN) <= 0.18 or color_dist(cc, EMISSIVE_CYAN) <= 0.18:
                    found_cyan = True
                    break
        if found_cyan:
            break
    check(found_cyan, "B treadmill console shows cyan display (real console)")


def main():
    print("=" * 64)
    print("  V3.1 P2 PIL PIXEL SAMPLING — equipment real objects (3 faces + 5 layers)")
    print("  evidence dir: %s" % EVIDENCE_DIR)
    print("=" * 64)
    verify_face_sheets()
    verify_rendered_scene()
    print("\n" + "=" * 64)
    print("  PIL SAMPLING RESULT: %s (%d passed, %d failed)" % (
        "PASS" if failed == 0 else "FAIL", passed, failed))
    print("=" * 64)
    sys.exit(1 if failed > 0 else 0)


if __name__ == "__main__":
    main()
