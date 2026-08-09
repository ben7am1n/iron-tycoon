#!/usr/bin/env python3
"""V3.1 返工 UI — PIL 像素采样证据：HUD 去 CSS 仪表盘化。

采样 tests/evidence/v31-r1-ui.png（window 模式渲染帧），验证 V3.1 门禁
（HUD 读作像素游戏界面，非网页仪表盘）：

  A. 顶栏边缘非完美直线：顶栏条带（y 2..50）顶部边缘行存在「缺口」
     —— 边缘行的像素颜色沿 x 变化（std 大 / 有世界色透出），而非
     完美直线边框的均匀行。
  B. 顶栏无等宽实心描边：条带顶部 3px 行带内 Butter 覆盖率低（旧 CSS
     边框 = 整行实心 Butter）。
  C. 顶栏材质 cluster：条带区域量化颜色数 >= 6（多色 cluster，非纯色）。
  D. 底部 tile 无 CSS 卡片边框：tile 外缘 2px 行带 Butter 覆盖率低。
  E. 底部 tile 平板材质：tile 角落区域量化颜色数 >= 4。
  F. 无全宽均匀直线：扫描 HUD 区域内是否存在「连续 >= 200px 的同一
     颜色行」（完美直线边框特征）—— 不应存在。

退出码：0 = 全部通过；1 = 有失败。
用法：python3 tests/evidence/v31_r1_pil_sample.py
"""
import colorsys
import os
import sys
from PIL import Image

EVIDENCE_DIR = os.path.dirname(os.path.abspath(__file__))
PNG = os.path.join(EVIDENCE_DIR, "v31-r1-ui.png")

BUTTER = (0xF5 / 255.0, 0xD9 / 255.0, 0x7B / 255.0)

# HUD 顶栏条带（hud.gd _draw）：strip_rect = (12, 2, 1256, 48)
STRIP = (12, 2, 1256, 48)  # x, y, w, h
# 底部建造条第一条 tile：x 0..88, y 632..720
TILE0 = (2, 634, 84, 84)
# tile 左上角材质采样区（避开图标/文字）
TILE_CLUSTER = (4, 636, 20, 20)


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


def _max_uniform_run(img, y, x0, x1, tol=0.06):
    """一行中「同色连续段」的最大长度（完美直线特征）。"""
    best = 0
    run = 0
    prev = None
    for x in range(x0, x1):
        px = img.getpixel((x, y))
        c = tuple(v / 255.0 for v in px[:3])
        if prev is not None and all(abs(c[i] - prev[i]) < tol for i in range(3)):
            run += 1
        else:
            run = 1
        prev = c
        best = max(best, run)
    return best


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

    # C. 顶栏材质 cluster（量化颜色数）
    strip_colors = _quant_colors(img, (STRIP[0], STRIP[1] + 6, STRIP[2] - 12, STRIP[3] - 12))
    check(len(strip_colors) >= 6, "C top strip has multi-color cluster (%d quantized colors, 非纯色)" % len(strip_colors))

    # D. 底部 tile 外缘无 CSS 卡片边框
    edge_box = (TILE0[0], TILE0[1], TILE0[2], 2)
    tile_edge_butter = _butter_coverage(img, edge_box, 0.12)
    check(tile_edge_butter < 0.30, "D tile outer edge no CSS card border (Butter coverage %.3f)" % tile_edge_butter)

    # E. 底部 tile 平板材质 cluster
    tile_colors = _quant_colors(img, TILE_CLUSTER)
    check(len(tile_colors) >= 4, "E tile plate has multi-color cluster (%d quantized colors)" % len(tile_colors))

    # F. HUD 边缘行带无全宽均匀直线（完美直线边框特征 —— 旧 CSS 边框会在
    #    边缘行形成 >= 200px 的同一颜色连续段，尤其 Butter 描边）。面板
    #    主体本就有大面积 base 色（4px texel 像素面板语言），只扫边缘 3px。
    max_run = 0
    for y in range(STRIP[1], STRIP[1] + 3):
        max_run = max(max_run, _max_uniform_run(img, y, STRIP[0], STRIP[0] + STRIP[2]))
    for y in range(TILE0[1], TILE0[1] + 3):
        max_run = max(max_run, _max_uniform_run(img, y, TILE0[0], TILE0[0] + TILE0[2]))
    check(max_run < 200, "F no full-width uniform straight line on HUD edges (max run %d px < 200)" % max_run)

    print("\nPIL RESULT: %s" % ("PASS" if ok else "CHECK"))
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
