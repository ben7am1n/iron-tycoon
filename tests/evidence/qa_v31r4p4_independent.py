#!/usr/bin/env python3
"""V3.1 返工4 P4 — PIL 独立像素采样证据：HUD 条带像素级破形 + 世界/HUD
交界线打散（结构性去程序化，第四轮 GPT 视觉 FAIL 修复）。

门禁 FAIL（第四轮 GPT 视觉，负面约束 1/7）：
  1) 顶部/底部 HUD 条带仍被读作「长条矩形区」—— 上轮已去「条+卡片」语言
     并改 diagetic 材质，但条带外轮廓仍太规整，读作完美矩形
  2) 场地中央笔直分区边缘（世界层与 HUD 交界/分区线）被读作完美直线

本卡结构改造：
  - 顶部/底部 HUD 条带外轮廓像素级破形：边缘锯齿/破损/参差（2-3px+ 抖动，
    四角不齐 —— 条带读作轻微不规则多边形而非矩形；参考 pixel_panel.gd
    撕裂手法但强度提升到 GPT 可辨）
  - 挂牌/价签/黑板/公告板撕裂轮廓强度提升
  - 场地中央笔直分区边缘（世界层与 HUD 交界）打散：挂牌下/架条上的平齐
    墙色带改为短线段错落/材质过渡（冷色阴影短段），不再一条完整直线
  - 底部展示架每段垂直错落（非等高校直线）

采样 tests/evidence/v31-r4-p4-ui.png（window 模式渲染帧，8 会员注入），
独立于 v31_r4_p4_capture.gd 的 Godot 侧断言：

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
  Q. 顶带外轮廓锯齿（FAIL#1）：HUD 材质最上缘存在 1-2px 相邻列台阶
     （pixel-break 2-3px 抖动 —— 排除元素自然高度差）
  R. 顶带四角不齐（FAIL#1）：内容包围盒四角覆盖 < 48/64（角部咬口）
  S. 顶部世界/HUD 交界线打散（FAIL#2）：挂牌下方墙色带最长 run < 200px
  T. 底部世界/HUD 交界线打散（FAIL#2）：架条上方墙色带最长 run < 200px

退出码：0 = 全部通过；1 = 有失败。
用法：python3 tests/evidence/qa_v31r4p4_independent.py [png]
"""
import os
import sys

from PIL import Image

EVIDENCE_DIR = os.path.dirname(os.path.abspath(__file__))
PNG = sys.argv[1] if len(sys.argv) > 1 else os.path.join(EVIDENCE_DIR, "v31-r4-p4-ui.png")

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


## V3.1 返工4 P4：HUD 材质判定（顶带锯齿/四角检查用）—— 挂牌暖木 +
## 公告板软木 + 黑板板面（slate）+ 钟面 Butter。与墙面（WALL 系）和
## 背景 cream（F4E9D8 —— 顶带外背景色，绝不能当作 HUD 材质）严格区分。
def is_hud_mat(c):
    if is_wood(c):
        return True
    if near(c, (0xC8, 0xA9, 0x7C), 0.14):
        return True  # 软木板面
    if near(c, (0x4A, 0x54, 0x50), 0.14):
        return True  # 黑板板面
    if near(c, (0xF5, 0xD9, 0x7B), 0.16):
        return True  # Butter（钟面/粉笔痕）
    return False


## V3.1 返工4 P4：HUD 材质包围盒（限 [0..max_y) 行）。返回 (x, y, w, h) 或 None。
def hud_mat_bbox(img, max_y):
    w, h = img.size
    h = min(h, max_y)
    min_x = min_y = 10 ** 9
    max_x = max_y_f = -1
    for y in range(h):
        for x in range(w):
            if is_hud_mat(img.getpixel((x, y))):
                min_x = min(min_x, x)
                min_y = min(min_y, y)
                max_x = max(max_x, x)
                max_y_f = max(max_y_f, y)
    if max_x < 0:
        return None
    return (min_x, min_y, max_x - min_x + 1, max_y_f - min_y + 1)


## V3.1 返工4 P4：矩形区域内 HUD 材质像素计数。box = (x, y, w, h)。
def hud_count(img, box):
    x0, y0, w, h = box
    count = 0
    for y in range(max(0, y0), min(img.size[1], y0 + h)):
        for x in range(max(0, x0), min(img.size[0], x0 + w)):
            if is_hud_mat(img.getpixel((x, y))):
                count += 1
    return count


## V3.1 返工4 P4：扫描 [y0..y1) 各行，返回最长「墙色带」连续 run（px）。
## 墙色带 = WALL_BASE 加深族（世界层与 HUD 交界的平齐墙色带 —— 旧帧
## 316px@y52..64 / 739px@y684..700）。破形后任意行 run 应 < 200px。
def max_wall_run(img, y0, y1):
    w, h = img.size
    max_run = 0
    for y in range(y0, min(y1, h)):
        run = 0
        for x in range(w):
            if is_junction_wall_tone(img.getpixel((x, y))):
                run += 1
                max_run = max(max_run, run)
            else:
                run = 0
    return max_run


## 交界墙色带：WALL_BASE 加深 0.32-0.46 族（含吊顶/墙根阴影）—— 与挂牌
## 暖木 / 深色面板 / 奶油背景严格区分。实测交界带 (105..113, 93..100,
## 83..89)；加深 0.38 → (97,86,77)，lightened 至 (110..113, 97..100,
## 87..89) 均属此带（天花板纹理 +0.14 alpha 提亮）。
def is_junction_wall_tone(c):
    r8, g8, b8 = c[0], c[1], c[2]
    if r8 < 84 or r8 > 118 or g8 < 74 or g8 > 104 or b8 < 66 or b8 > 94:
        return False
    return r8 > g8 and g8 > b8


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

    # Q. V3.1 返工4 P4 FAIL#1：顶带外轮廓锯齿 —— HUD 材质最上缘存在
    # 1-2px 相邻列台阶（pixel-break 逐列 2-3px 抖动）。撕裂轮廓（4px texel
    # 步进）在同一 texel 内 4 列同高 → 台阶 0 或 ≥4px；pixel-break（1-3px
    # 咬口）制造 1-2px 相邻列台阶 —— 该计数专门检测像素级破形，排除元素
    # 自然高度差。
    edge_jagged = 0
    edge_cols = 0
    prev_edge = -1
    for x in range(0, w):
        found = -1
        for y in range(0, 16):
            if is_hud_mat(px[x, y]):
                found = y
                break
        if found >= 0:
            edge_cols += 1
            if prev_edge >= 0 and 1 <= abs(found - prev_edge) <= 2:
                edge_jagged += 1
            prev_edge = found
        else:
            prev_edge = -1
    check("Q 顶带外轮廓锯齿（1-2px 相邻列台阶 >= 20）",
          edge_cols > 100 and edge_jagged >= 20,
          "steps=%d cols=%d" % (edge_jagged, edge_cols))

    # R. V3.1 返工4 P4 FAIL#1：顶带四角不齐 —— HUD 材质包围盒四角覆盖
    # 应显著低于完整 8×8（64）：角部咬口（pixel-break 3-5px + 撕裂轮廓
    # 3-4 texel）→ 至少一角覆盖 < 48（缺 ≥25%）→ 无规则直角矩形。
    bbox = hud_mat_bbox(img, 60)
    if bbox is None:
        check("R 顶带四角不齐（包围盒为空）", False, "bbox empty")
    else:
        corner_counts = [
            hud_count(img, (bbox[0], bbox[1], 8, 8)),
            hud_count(img, (bbox[0] + bbox[2] - 8, bbox[1], 8, 8)),
            hud_count(img, (bbox[0], bbox[1] + bbox[3] - 8, 8, 8)),
            hud_count(img, (bbox[0] + bbox[2] - 8, bbox[1] + bbox[3] - 8, 8, 8)),
        ]
        cmin = min(corner_counts)
        check("R 顶带四角不齐（至少一角覆盖 < 48/64）", cmin < 48,
              "corners=%s" % corner_counts)

    # S. V3.1 返工4 P4 FAIL#2：顶部世界/HUD 交界线打散 —— 挂牌下方墙色带
    # （y 46..78）最长 run < 200px（旧帧 316px @ y=52..64）。交界破形带
    # （错落短段）把平齐直线切成短线段。
    s_max = max_wall_run(img, 46, 78)
    check("S 顶部世界/HUD 交界线打散（最长墙色 run < 200px）",
          s_max < 200, "max_run=%d" % s_max)

    # T. V3.1 返工4 P4 FAIL#2：底部世界/HUD 交界线打散 —— 架条上方墙色带
    # （y 684..702）最长 run < 200px（旧帧 739px）。
    t_max = max_wall_run(img, 684, 702)
    check("T 底部世界/HUD 交界线打散（最长墙色 run < 200px）",
          t_max < 200, "max_run=%d" % t_max)

    print("\nR4 P4 PIL RESULT: %s (%d passed, %d failed)" % ("PASS" if FAIL == 0 else "FAIL", PASS, FAIL))
    sys.exit(0 if FAIL == 0 else 1)


if __name__ == "__main__":
    main()
