#!/usr/bin/env python3
"""V3.1 返工 2 UI — PIL 独立像素采样证据：HUD 负面约束第二轮（无等宽边框 /
无重复虚线纹理 / 无纯色大块，jitter 显著加大）。

注意：本文件是「返工 2 UI 卡」证据（命名 v31_r2_ui_* 与既有 R2 sprite 卡
v31_r2_pil_sample.py 区分 —— 后者是 P2 人物/器械 sprite 证据，勿混用）。

采样 tests/evidence/v31-r2-ui.png（window 模式渲染帧，同 v31_r1_capture 方法），
独立于 v31_r2_ui_capture.gd 的 Godot 侧断言（不同参数、不同采样步长）：

  A. 顶栏边缘非完美直线：顶缘行「世界色透出」缺口数量 > 2（锯齿边缘）。
  B. 顶栏无等宽实心 Butter 描边：顶缘 3px 行带 Butter 覆盖率 < 0.30
     （旧 CSS 边框 = 整行实心 Butter）。
  C. 无重复虚线纹理（warning stripe）：顶栏 y 2..50 内任意单行 Butter
     连续段最大长度 < 60px；且整条 accent 带 Butter 覆盖率 < 0.20。
  D. 无纯色大块：条带内部区域量化颜色数 >= 24；tile 内部量化颜色数 >= 10。
  E. tile 外缘无 CSS 卡片边框：tile 顶缘 2px 行带 Butter 覆盖率 < 0.30。
  F. 边框抖动幅度（jitter）：顶缘锯齿行颜色方差显著（边缘参差 2-3px 级）。

退出码：0 = 全部通过；1 = 有失败。
用法：python3 tests/evidence/v31_r2_ui_pil_sample.py
"""
import os
import sys

from PIL import Image

EVIDENCE_DIR = os.path.dirname(os.path.abspath(__file__))
PNG = os.path.join(EVIDENCE_DIR, "v31-r2-ui.png")

BUTTER = (0xF5 / 255.0, 0xD9 / 255.0, 0x7B / 255.0)

# HUD 顶栏条带（hud.gd _draw）：strip_rect = (12, 2, 1256, 48)
STRIP = (12, 2, 1256, 48)  # x, y, w, h
# 底部建造条第一条 tile：x 0..88, y 632..720
TILE0 = (2, 634, 84, 84)
# tile 左上角材质采样区（避开图标/文字）
TILE_CLUSTER = (6, 640, 32, 32)
# 条带内部采样区（避开顶部 accent 带与文字区）
STRIP_INTERIOR = (40, 16, 860, 28)


def _near(a, b, tol=0.12):
    return sum((a[i] - b[i]) ** 2 for i in range(3)) ** 0.5 <= tol


def _quantize(c, levels=16):
    return tuple(int(c[i] * levels) for i in range(3))


def _quant_colors(img, box, levels=16, step=2):
    """box = (x, y, w, h) 区域内量化颜色集合。"""
    colors = set()
    x0, y0, w, h = box
    for y in range(y0, y0 + h, step):
        for x in range(x0, x0 + w, step):
            px = img.getpixel((x, y))
            if len(px) >= 4 and px[3] < 10:
                continue
            colors.add(_quantize(tuple(c / 255.0 for c in px[:3]), levels))
    return colors


def _butter_coverage(img, box, tol=0.12):
    """box 区域内 Butter 色像素占比。"""
    x0, y0, w, h = box
    total = 0
    butter = 0
    for y in range(y0, y0 + h):
        for x in range(x0, x0 + w, 2):
            total += 1
            px = img.getpixel((x, y))
            c = tuple(v / 255.0 for v in px[:3])
            if _near(c, BUTTER, tol):
                butter += 1
    return (butter / total) if total else 0.0


def _edge_gap_count(img, y, x0, x1, panel_thresh=0.32):
    """顶缘行中「非面板色」像素数（透明缺口露出世界 = 锯齿边缘）。"""
    gaps = 0
    for x in range(x0, x1, 2):
        px = img.getpixel((x, y))
        r, g = px[0] / 255.0, px[1] / 255.0
        if r > panel_thresh and g > panel_thresh - 0.02:
            gaps += 1
    return gaps


def _max_butter_run_per_row(img, y0, y1, tol=0.20):
    """y0..y1 范围内任意行的最大 Butter 连续段长度（px）。"""
    w, _ = img.size
    max_run = 0
    max_run_y = -1
    for y in range(y0, y1):
        run = 0
        for x in range(w):
            px = img.getpixel((x, y))
            c = tuple(v / 255.0 for v in px[:3])
            if _near(c, BUTTER, tol):
                run += 1
                if run > max_run:
                    max_run = run
                    max_run_y = y
            else:
                run = 0
    return max_run, max_run_y


def _row_color_variance(img, y, x0, x1):
    """一行内颜色方差（边缘参差检查：抖动行应显著异于面板纯色行）。"""
    vals = []
    for x in range(x0, x1, 2):
        px = img.getpixel((x, y))
        vals.append(px[0] / 255.0 + px[1] / 255.0 + px[2] / 255.0)
    mean = sum(vals) / len(vals)
    var = sum((v - mean) ** 2 for v in vals) / len(vals)
    return var


def main():
    img = Image.open(PNG).convert("RGBA")
    w, h = img.size
    print("image %dx%d" % (w, h))
    ok = True

    def check(cond, msg):
        nonlocal ok
        if not cond:
            ok = False
        print("  %s %s" % ("PASS" if cond else "FAIL", msg))

    # A. 顶栏边缘锯齿（缺口露出世界）
    gaps = _edge_gap_count(img, STRIP[1], STRIP[0], STRIP[0] + STRIP[2])
    check(gaps > 2, "A top strip edge is jagged (gaps=%d > 2, 非完美直线)" % gaps)

    # B. 顶栏顶部 3px 行带无实心 Butter 描边（排除右上 transport 按钮区）
    butter_top = _butter_coverage(img, (STRIP[0], STRIP[1], 980, 3), 0.12)
    check(butter_top < 0.30, "B top strip edge has no solid Butter border (coverage %.3f)" % butter_top)

    # C. 无重复虚线纹理（warning stripe）：任意行 Butter 连续段 < 60px
    max_run, max_run_y = _max_butter_run_per_row(img, STRIP[1], 52, 0.20)
    check(max_run < 60, "C no warning-stripe dashed band (max Butter run %dpx < 60px, at y=%d)" % (max_run, max_run_y))

    # C2. accent 带覆盖率 < 0.20（散点墨迹，非全宽虚线）
    accent_box = (STRIP[0], 6, STRIP[2], 4)
    accent_cov = _butter_coverage(img, accent_box, 0.25)
    check(accent_cov < 0.20, "C2 accent band is sparse flecks (coverage %.3f < 0.20)" % accent_cov)

    # D. 无纯色大块：条带内部 / tile 内部量化颜色数
    strip_colors = _quant_colors(img, STRIP_INTERIOR)
    check(len(strip_colors) >= 24, "D strip interior multi-color cluster (%d quantized colors >= 24)" % len(strip_colors))
    tile_colors = _quant_colors(img, TILE_CLUSTER)
    check(len(tile_colors) >= 10, "D2 tile plate multi-color cluster (%d quantized colors >= 10)" % len(tile_colors))

    # E. tile 外缘无 CSS 卡片边框
    edge_box = (TILE0[0], TILE0[1], TILE0[2], 2)
    tile_edge_butter = _butter_coverage(img, edge_box, 0.12)
    check(tile_edge_butter < 0.30, "E tile outer edge no CSS card border (Butter coverage %.3f)" % tile_edge_butter)

    # F. 边框抖动幅度：顶缘锯齿行颜色方差显著（边缘参差 2-3px 级）
    edge_var = _row_color_variance(img, STRIP[1], STRIP[0], STRIP[0] + 800)
    check(edge_var > 0.002, "F top-edge jitter present (edge row var %.4f > 0.002)" % edge_var)

    print("\nR2 UI PIL RESULT: %s" % ("PASS" if ok else "CHECK"))
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
