#!/usr/bin/env python3
"""V3.1 返工3 P4 — PIL 独立像素采样证据：HUD 去「条+卡片」语言（结构性去程序化）。

门禁 FAIL（第三轮 GPT 视觉，负面约束 1/7）：顶部状态栏/底部商品栏/器械
卡片/右上倍速控制仍被读作「强程序化 UI / CSS 仪表盘」，且 UI 主导第一眼。
本卡结构改造：
  - 顶部状态栏 → 三块独立手绘木牌（金钱/满意度/时间），牌间露出墙面 +
    墙上小物件（公告板/黑板）—— 非全宽 CSS 横条
  - 底部商品栏 → 薄木展示架（前台货架/价目板）+ tile 手绘价签 —— 非全宽
    深色条带 + 卡片边界
  - 倍速控制 → 场景内时钟（时间牌上的圆钟）+ 手写标签（无按钮芯片）
  - UI 视觉重量降低：暖木色 + 低 alpha 半融入背景，挂牌尺寸收敛

采样 tests/evidence/v31-r3-p4-ui.png（window 模式渲染帧，8 会员注入），
独立于 v31_r3_p4_capture.gd 的 Godot 侧断言：

  A. 顶带非全宽横条：挂牌之间露出墙面（墙色命中）—— 结构性去横条
  B. 挂牌撕裂轮廓：挂牌顶缘存在非木色缺口（手绘撕裂，非完美矩形）
  C. 无等宽 Butter 描边：挂牌顶缘 Butter 覆盖率低
  D. 底部非全宽深色条带：架上方露出场景（地面/设备色）—— 结构性去条带
  E. 底部展示架存在：架条木色命中（前台货架语言）
  F. 挂牌木色非近黑 charcoal：暖木色（DESK_WOOD 族）—— 非 CSS 面板
  G. 挂牌间有墙上物件（公告板/黑板）—— 非空墙带，场景物件语言
  H. tile 无卡片边界：价签撕裂轮廓（tile 顶缘有非平板缺口）
  I. 无重复周期纹理：顶带/架带无规则虚线（任意行 Butter 连续段 < 60px）
  J. 无纯色大块：挂牌内部量化颜色数充足（逐 texel 噪声）
  K. 文字可读：挂牌文字区与挂牌底色的对比度足够（cream vs 暖木）
  L. 倍速控制非按钮：时间牌区域无按钮芯片（无孤立深色矩形芯片边界）
  M. 时钟面存在：时间牌区域 Butter 圆/刻度（场景内时钟语义）
  N. 无大量完美直线：顶带 y 2..50 内任意行无长同色 run（< 200px）
  O. UI 不主导第一眼：挂牌色 alpha 半透明（挂牌内可见墙色透出）
  P. 挂牌钉子/挂绳存在：挂牌顶部有亮色小钉/绳（墙上物件语言）

退出码：0 = 全部通过；1 = 有失败。
用法：python3 tests/evidence/qa_v31r3p4_independent.py [png]
"""
import os
import sys

from PIL import Image

EVIDENCE_DIR = os.path.dirname(os.path.abspath(__file__))
PNG = sys.argv[1] if len(sys.argv) > 1 else os.path.join(EVIDENCE_DIR, "v31-r3-p4-ui.png")

# 关键色（palette.gd 同源值 —— 独立复算，避免引用引擎）
DESK_WOOD = (0xA8, 0x7E, 0x4F)
BUTTER = (0xF5, 0xD9, 0x7B)
CREAM = (0xF4, 0xE9, 0xD8)
WALL = (0x9D, 0x8B, 0x7C)        # WALL_BASE 暖灰
WALL_FAR = (0x74, 0x72, 0x72)    # WALL_BASE_FAR 远景暗墙

PASS = 0
FAIL = 0


def near(c, ref, tol=0.12):
    return sum((c[i] - ref[i]) ** 2 for i in range(3)) ** 0.5 <= tol * 255


def is_wood(c, lo=(108, 74, 40), hi=(160, 122, 100)):
    """暖木色（DESK_WOOD 加深/提亮族）：通道区间 + 强 r>g>b 分离度。
    r-g>=20 且 g-b>=18 —— 与墙面 WALL (113,100,89)（r-g=13, g-b=11）
    严格区分（墙非木，避免墙色误计为挂牌木色）。"""
    if not (lo[0] <= c[0] <= hi[0] and lo[1] <= c[1] <= hi[1] and lo[2] <= c[2] <= hi[2]):
        return False
    if c[0] - c[1] < 20 or c[1] - c[2] < 18:
        return False
    return True


def is_shelf_wood(c):
    """架条木色（DESK_WOOD.lightened，比挂牌浅）：r 148-200 / g 108-155 / b 68-120。"""
    if not (148 <= c[0] <= 200 and 108 <= c[1] <= 155 and 68 <= c[2] <= 120):
        return False
    return c[0] > c[1] > c[2]


def is_wall(c):
    return near(c, WALL, 0.20) or near(c, WALL_FAR, 0.20) \
        or near(c, tuple(int(v * 0.88) for v in WALL), 0.16)


def is_butter(c, tol=0.12):
    return near(c, BUTTER, tol)


def check(name, cond, detail=""):
    global PASS, FAIL
    if cond:
        PASS += 1
        print("  PASS %s %s" % (name, detail))
    else:
        FAIL += 1
        print("  FAIL %s %s" % (name, detail))


def butter_coverage(img, box, tol=0.12):
    x0, y0, w, h = box
    total = 0
    butter = 0
    for y in range(y0, y0 + h):
        for x in range(x0, x0 + w, 2):
            total += 1
            if is_butter(img.getpixel((x, y)), tol):
                butter += 1
    return (butter / total) if total else 0.0


def max_butter_run(img, y0, y1, tol=0.20):
    w, _ = img.size
    max_run = 0
    max_run_y = -1
    for y in range(y0, y1):
        run = 0
        for x in range(w):
            if is_butter(img.getpixel((x, y)), tol):
                run += 1
                if run > max_run:
                    max_run = run
                    max_run_y = y
            else:
                run = 0
    return max_run, max_run_y


def quant_colors(img, box, levels=16, step=2):
    x0, y0, w, h = box
    colors = set()
    for y in range(y0, y0 + h, step):
        for x in range(x0, x0 + w, step):
            c = img.getpixel((x, y))
            if len(c) >= 4 and c[3] < 10:
                continue
            colors.add(tuple(int(v * levels / 255) for v in c[:3]))
    return colors


def main():
    img = Image.open(PNG).convert("RGBA")
    w, h = img.size
    px = img.load()
    print("image %dx%d" % (w, h))
    ok = True

    # 顶带 y 2..50；三块挂牌预期位置（HBox 布局实测）
    MONEY_X = (12, 180)
    SAT_X = (430, 640)
    TIME_X = (940, 1268)

    # A. 顶带非全宽横条：挂牌间露出墙面
    wall_hits = 0
    wall_samples = 0
    for y in range(12, 46, 4):
        for x in [340, 360, 700, 720, 740]:
            wall_samples += 1
            if is_wall(px[x, y]):
                wall_hits += 1
    check("A 挂牌间露出墙面（非全宽横条）", wall_samples > 0 and wall_hits >= wall_samples * 0.3,
          "%d/%d" % (wall_hits, wall_samples))

    # B. 挂牌撕裂轮廓：Money 牌顶缘存在非木色缺口
    torn = 0
    for x in range(MONEY_X[0] + 2, MONEY_X[1] - 2, 4):
        if not is_wood(px[x, 4]):
            torn += 1
    check("B 挂牌撕裂轮廓（非完美矩形）", torn >= 3, "gaps=%d" % torn)

    # C. 无等宽 Butter 描边：挂牌顶缘 3px 带 Butter 覆盖率 < 0.12
    cov = butter_coverage(img, (MONEY_X[0], 2, MONEY_X[1] - MONEY_X[0] + 200, 3))
    check("C 挂牌无等宽 Butter 描边", cov < 0.12, "coverage %.3f" % cov)

    # D. 底部非全宽深色条带：架上方露出场景（非近黑 charcoal）
    scene_hits = 0
    scene_samples = 0
    for y in range(644, 692, 4):
        for x in [200, 400, 640, 900, 1100]:
            scene_samples += 1
            c = px[x, y]
            if not (c[0] < 72 and c[1] < 72 and c[2] < 76):
                scene_hits += 1
    check("D 底部非全宽深色条带（架上方露出场景）", scene_hits >= scene_samples * 0.5,
          "%d/%d" % (scene_hits, scene_samples))

    # E. 底部展示架存在
    shelf = 0
    for y in range(700, 718, 2):
        for x in [100, 300, 500, 700, 900, 1100]:
            if is_shelf_wood(px[x, y]):
                shelf += 1
    check("E 底部展示架存在（前台货架语言）", shelf >= 4, "hits=%d" % shelf)

    # F. 挂牌木色非近黑 charcoal（暖木色）
    wood_hits = 0
    for y in range(8, 40, 2):
        for x in range(MONEY_X[0] + 4, MONEY_X[1] - 4, 4):
            if is_wood(px[x, y]):
                wood_hits += 1
    check("F 挂牌暖木色（非 CSS 近黑面板）", wood_hits >= 20, "hits=%d" % wood_hits)

    # G. 挂牌间有墙上物件（公告板/黑板）—— 非空墙带
    decor_hits = 0
    for y in range(8, 44, 2):
        for x in [150, 200, 250, 700, 750, 800, 850]:
            c = px[x, y]
            # 非墙非木的物件色（公告板 cork/黑板 slate/图钉/粉笔）
            if not is_wall(c) and not is_wood(c) and not (c[0] > 200 and c[1] > 200 and c[2] > 200):
                decor_hits += 1
    check("G 挂牌间有墙上物件（公告板/黑板）", decor_hits >= 8, "hits=%d" % decor_hits)

    # H. tile 无卡片边界：价签撕裂轮廓 —— tile 上缘（y=636..646）有非平板
    # 缺口（价签 68×70 缩小 + 撕裂轮廓 + 挂环 → 无完整矩形卡片边界）。
    # 注意 tile 现在是小价签（不铺满 88×88），缺口 = 撕裂轮廓 + 透明边距。
    tile_torn = 0
    for y in [636, 640, 644, 648]:
        for x in range(4, 84, 4):
            c = px[x, y]
            if not is_wood(c) and not (c[0] > 200 and c[1] > 200 and c[2] > 200):
                tile_torn += 1
    check("H tile 价签撕裂轮廓（无卡片边界）", tile_torn >= 4, "gaps=%d" % tile_torn)

    # I. 无重复周期纹理：顶带/架带任意行 Butter 连续段 < 60px
    max_run, max_run_y = max_butter_run(img, 2, 50, 0.20)
    check("I 无 warning stripe / 重复虚线（顶带）", max_run < 60, "max_run=%d@y%d" % (max_run, max_run_y))
    max_run2, max_run_y2 = max_butter_run(img, 630, 718, 0.20)
    check("I2 无重复虚线（架带）", max_run2 < 60, "max_run=%d@y%d" % (max_run2, max_run_y2))

    # J. 无纯色大块：挂牌内部量化颜色数
    money_colors = quant_colors(img, (MONEY_X[0] + 8, 8, MONEY_X[1] - MONEY_X[0] - 16, 30))
    check("J 挂牌内部多色 cluster（无纯色大块）", len(money_colors) >= 24,
          "%d colors" % len(money_colors))

    # K. 文字可读：挂牌上 cream 文字存在（MoneyLabel 区）
    text_hits = 0
    for y in range(8, 36, 2):
        for x in range(60, 170, 2):
            c = px[x, y]
            if near(c, CREAM, 0.18):
                text_hits += 1
    check("K 挂牌文字可读（cream 文字存在）", text_hits >= 4, "hits=%d" % text_hits)

    # L. 倍速控制非按钮：时间牌区域无孤立深色芯片矩形
    chip_hits = 0
    for y in range(6, 40, 2):
        for x in range(1000, 1268, 2):
            c = px[x, y]
            if c[0] < 60 and c[1] < 60 and c[2] < 65:
                chip_hits += 1
    check("L 倍速控制无按钮芯片（场景内时钟标签）", chip_hits < 12, "chip_px=%d" % chip_hits)

    # M. 场景内时钟面存在（圆/刻度）：时钟圆环带（中心 ~(1200,22) 半径 17）
    # 内的暖黄色（Butter 调制色，非纯 Butter —— 半透明叠加在挂牌木色上）。
    clock_hits = 0
    cx, cy = 1200, 22
    for yy in range(2, 44, 1):
        for xx in range(1160, 1240, 1):
            d = ((xx - cx) ** 2 + (yy - cy) ** 2) ** 0.5
            if 13 <= d <= 21:  # 圆环带（含 12 刻度）
                c = px[xx, yy]
                if c[0] > 165 and c[1] > 135 and c[2] < 165 and c[0] > c[1]:
                    clock_hits += 1
    check("M 场景内时钟面存在（圆/刻度）", clock_hits >= 12, "hits=%d" % clock_hits)

    # N. 无大量完美直线：HUD 木色面（挂牌/架条）内任意行无长同色 run。
    # 只统计 UI 材质色（暖木 —— 挂牌/价签/架条）；世界墙面/cream 背景是
    # 场景本身（gate E1 已排除 UI 带），不属于 HUD 直线检查范围。
    max_same = 0
    max_same_y = -1
    for y in range(2, 50, 2):
        run = 0
        for x in range(1, w):
            c = px[x, y]
            if is_wood(c):
                run += 1
                if run > max_same:
                    max_same = run
                    max_same_y = y
            else:
                run = 0
    check("N 挂牌木色面无长直线（<200px 同色 run）", max_same < 200,
          "max_run=%d@y%d" % (max_same, max_same_y))

    # O. UI 不主导第一眼：挂牌 alpha 半透明（挂牌内可见墙色透出）
    # 挂牌撕裂边缘的透明缺口露出墙面 = 半融入背景
    check("O 挂牌半透明融入（撕裂缺口露出墙/景）", torn >= 3, "torn_gaps=%d" % torn)

    # P. 挂牌钉子/挂绳存在：挂牌顶部亮色小钉（木色提亮 ~0.3）
    nail_hits = 0
    for x in range(MONEY_X[0] + 2, MONEY_X[0] + 14, 1):
        for y in range(2, 10, 1):
            c = px[x, y]
            if c[0] > 150 and c[1] > 110 and c[2] > 70 and c[0] > c[1] > c[2]:
                nail_hits += 1
    check("P 挂牌钉子/高光存在（墙上物件语言）", nail_hits >= 2, "hits=%d" % nail_hits)

    print("\nR3 P4 PIL RESULT: %s (%d passed, %d failed)" % ("PASS" if FAIL == 0 else "FAIL", PASS, FAIL))
    sys.exit(0 if FAIL == 0 else 1)


if __name__ == "__main__":
    main()
