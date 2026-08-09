#!/usr/bin/env python3
# tests/evidence/qa_v31r2r2_independent.py — V3.1 返工2 R2 独立 PIL 采样
#
# 对证据帧做第三方量化（不经过 Godot / 不读测试断言）：
#   F1 会员头身比：walk 会员纹理（48×48）头部像素带 vs 躯干像素带高度比
#      （头 0..13 行 ≈ 29%，非大头棋子感）
#   F2 单车飞轮金属高光存在性：bike closeup 帧中 METAL_HIGHLIGHT 亮色像素
#   F3 跑步机屏幕亮色存在性：treadmill closeup 帧中 cyan 显示屏像素 +
#      暖高光 + 金属暗纹（跑带纹理）
# 输入：tests/evidence/v31-r2-r2-*.png（由 v31_r2_r2_capture.tscn 生成）
# 用法：python3 tests/evidence/qa_v31r2r2_independent.py
import os
import sys

try:
    from PIL import Image
except ImportError:
    print("FATAL: PIL not available")
    sys.exit(2)

BASE = os.path.dirname(os.path.abspath(__file__))

# 关键色（palette.gd 同源值 —— 独立复算，避免引用引擎）
COLORS = {
    "SKY": (0x8E, 0xC5, 0xE8),              # 衬衫（walking）
    "MEMBER_SKIN": (0xF2, 0xC0, 0x9A),      # 肤色
    "MEMBER_HAIR": (0x4A, 0x33, 0x2A),      # 发色 v0
    "METAL_HIGHLIGHT": (0xC9, 0xD4, 0xDE),  # 金属高光
    "EQUIP_ACCENT_CYAN": (0x6E, 0xD3, 0xD9),  # 青蓝显示屏
    "EQUIP_HIGHLIGHT": (0xF2, 0xE3, 0xC0),  # 暖高光
    "METAL_DARK": (0x5B, 0x64, 0x70),        # 金属暗
    "ZONE_CARDIO": (0x8E, 0xC5, 0xE8),       # 单车区语义色（Sky）
}

PASS = 0
FAIL = 0


def near(c, ref, tol=0.10):
    return all(abs(c[i] - ref[i]) <= tol * 255 for i in range(3))


def count_color(img, ref, tol=0.08):
    px = img.convert("RGBA")
    w, h = px.size
    n = 0
    for y in range(0, h, 2):  # 隔行采样（大帧加速）
        for x in range(0, w, 2):
            r, g, b, a = px.getpixel((x, y))
            if a < 16:
                continue
            if near((r, g, b), ref, tol):
                n += 1
    return n


def check(name, cond, detail=""):
    global PASS, FAIL
    if cond:
        PASS += 1
        print("  PASS %s %s" % (name, detail))
    else:
        FAIL += 1
        print("  FAIL %s %s" % (name, detail))


def cyan_count(img):
    px = img.convert("RGBA")
    w, h = px.size
    n = 0
    for y in range(0, h, 2):
        for x in range(0, w, 2):
            r, g, b, a = px.getpixel((x, y))
            if a < 16:
                continue
            # 青蓝主导（显示灯）：g > r + 40 且 b > r + 20 且 g > 120
            if g > r + 40 and b > r + 20 and g > 120:
                n += 1
    return n


# ---- F1 会员头身比 ----
def f1_member_ratio():
    print("--- F1 会员头身比（非大头棋子感） ---")
    # 从全场景帧提取一个 walking 会员（Sky 衬衫像素簇），度量其纹理区。
    # 简化：直接从 member_sprite 独立渲染不现实 —— 用 walk 会员在帧中的
    # 衬衫带高度 vs 头部带高度作代理（头部 = 衬衫带上方同 x 列的深色像素带）。
    full = os.path.join(BASE, "v31-r2-r2-sprite.png")
    if not os.path.exists(full):
        check("F1 证据帧存在", False, "missing " + full)
        return
    img = Image.open(full).convert("RGBA")
    w, h = img.size
    # 找 Sky 衬衫像素的 y 范围（任一 x 列上的连续带）
    sky_rows = []
    for y in range(h):
        cnt = 0
        for x in range(0, w, 2):
            r, g, b, a = img.getpixel((x, y))
            if a > 16 and near((r, g, b), COLORS["SKY"], 0.10):
                cnt += 1
        if cnt >= 3:
            sky_rows.append(y)
    if not sky_rows:
        check("F1 帧内找到 walking 衬衫（Sky）", False, "no sky rows")
        return
    y0, y1 = min(sky_rows), max(sky_rows)
    torso_h = y1 - y0 + 1
    # 头部带：衬衫带上方与衬衫同一 x 列、含发色/肤色的连续像素
    head_h = 0
    if y0 > 0:
        y_top = y0
        while y_top > 0:
            cnt = 0
            for x in range(0, w, 2):
                r, g, b, a = img.getpixel((x, y_top - 1))
                if a > 16 and (near((r, g, b), COLORS["MEMBER_HAIR"], 0.14)
                               or near((r, g, b), COLORS["MEMBER_SKIN"], 0.14)):
                    cnt += 1
            if cnt < 2:
                break
            head_h += 1
            y_top -= 1
    total = torso_h + head_h
    ratio = (head_h / total) if total > 0 else 0.0
    # 非大头：头部带占比 < 40%（旧版 18/48=37.5% 仍是棋子感；修正后 14/48≈29%）
    check("F1 头部带占比 < 0.40（修正头身比）",
          ratio < 0.40, "head=%d torso=%d ratio=%.3f" % (head_h, torso_h, ratio))
    check("F1 躯干带高度 > 头部带高度（躯干非矩形短块）",
          torso_h > head_h, "head=%d torso=%d" % (head_h, torso_h))


# ---- F2 单车飞轮金属高光 ----
def f2_bike_flywheel():
    print("--- F2 单车飞轮金属高光存在性 ---")
    p = os.path.join(BASE, "v31-r2-r2-bike.png")
    if not os.path.exists(p):
        check("F2 单车特写帧存在", False, "missing " + p)
        return
    img = Image.open(p).convert("RGBA")
    n = count_color(img, COLORS["METAL_HIGHLIGHT"], 0.09)
    check("F2 飞轮金属高光像素存在（H/METAL_HIGHLIGHT）", n > 0, "n=%d" % n)
    nz = count_color(img, COLORS["ZONE_CARDIO"], 0.10)
    check("F2 座垫区域色存在（Z）", nz > 0, "n=%d" % nz)
    nc = cyan_count(img)
    check("F2 车把/显示青蓝存在（A 青蓝主导）", nc > 0, "n=%d" % nc)


# ---- F3 跑步机屏幕/纹理 ----
def f3_treadmill():
    print("--- F3 跑步机控制台屏幕亮色 + 跑带纹理 ---")
    p = os.path.join(BASE, "v31-r2-r2-treadmill.png")
    if not os.path.exists(p):
        check("F3 跑步机特写帧存在", False, "missing " + p)
        return
    img = Image.open(p).convert("RGBA")
    nc = count_color(img, COLORS["EQUIP_ACCENT_CYAN"], 0.09)
    check("F3 控制台屏幕青蓝像素存在（A 带内容/发光）", nc > 0, "n=%d" % nc)
    nw = count_color(img, COLORS["EQUIP_HIGHLIGHT"], 0.09)
    check("F3 屏幕/面板暖高光存在（W）", nw > 0, "n=%d" % nw)
    nm = count_color(img, COLORS["METAL_DARK"], 0.09)
    check("F3 跑带金属暗纹存在（M 纹理）", nm > 0, "n=%d" % nm)
    nh = count_color(img, COLORS["METAL_HIGHLIGHT"], 0.10)
    check("F3 金属立柱高光存在（H）", nh > 0, "n=%d" % nh)


def main():
    print("V3.1 返工2 R2 独立 PIL 采样（qa_v31r2r2_independent.py）")
    f1_member_ratio()
    f2_bike_flywheel()
    f3_treadmill()
    print("RESULT: %s (%d passed, %d failed)" % ("PASS" if FAIL == 0 else "FAIL", PASS, FAIL))
    sys.exit(0 if FAIL == 0 else 1)


if __name__ == "__main__":
    main()
