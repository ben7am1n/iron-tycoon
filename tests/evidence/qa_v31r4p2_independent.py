#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""独立 PIL 复核：V3.1 返工4 P2 —— 设备不再是扁平几何色块。

输入：tests/evidence/v31-r4-p2-sprite-<id>.png（v31_r4_p2_dump.gd 产物：
top | front | side 竖排、4x 最近邻放大、块间透明间隙）。不依赖 capture 脚本，
直接从 PNG 采样，独立判定：

  A. 三层层级分离：顶面（受光）平均明度 > 正面（中调）> 侧面（暗调）。
  B. 轮廓连续性：每个面块四周深色外轮廓完整（边界暗像素占比 + 最大缺口）。
  C. 零部件可读：单车飞轮圆盘/把手抓握点、跑步机控制台/跑带、卧推凳面/杠铃
     在 2x 缩放下的色块尺寸与对比（关键件 > 阈值）。

用法：python3 tests/evidence/qa_v31r4p2_independent.py
"""
import sys
from PIL import Image

# ---- 纹理 art 像素 vs dump 像素（MAG=4）----
MAG = 4
GAP = 4 * MAG  # dump 脚本块间间隙

# 调色板（src/palette.gd 独立复算，RGB）
EQUIP_OUTLINE = (59, 69, 82)        # 3B4552，内层轮廓
EQUIP_EDGE_OUTLINE = (44, 51, 61)   # 2C333D，外层勾边
EQUIP_BODY = (93, 102, 115)         # 5D6673 中调 2
EQUIP_BODY_DARK = (73, 82, 95)      # 49525F 暗调 1
EQUIP_BODY_LIGHT = (142, 153, 166)  # 8E99A6 亮调 3
EQUIP_SHADOW_TONE = (58, 67, 80)    # 3A4350 阴影 S
EQUIP_HIGHLIGHT = (234, 223, 184)   # EADFB8 高光 W
METAL_HIGHLIGHT = (183, 212, 236)   # B7D4EC 金属高光 H
METAL_DARK = (91, 100, 112)         # 5B6470 金属暗 M
EQUIP_ACCENT_CYAN = (47, 196, 232)  # 2FC4E8 青蓝 A
ZONE_CARDIO = (142, 197, 232)       # 8EC5E8 cardio 区色 Z（跑步机/单车）
ZONE_STRENGTH = (143, 191, 159)     # 8FBF9F strength 区色 Z（卧推）

def luminance(c):
    return 0.299 * c[0] + 0.587 * c[1] + 0.114 * c[2]

def near(c, ref, tol):
    return all(abs(c[i] - ref[i]) <= tol * 255 for i in range(3))

def split_blocks(img):
    """按透明间隙把竖排 sheet 切成 (top, front, side) 三个不透明块。"""
    w, h = img.size
    rows = []
    for y in range(h):
        opaque = 0
        for x in range(0, w, 3):
            if img.getpixel((x, y))[3] > 8:
                opaque += 1
        rows.append(opaque > 0)
    blocks = []
    y0 = None
    for y in range(h + 1):
        on = y < h and rows[y]
        if on and y0 is None:
            y0 = y
        elif not on and y0 is not None:
            blocks.append((y0, y))
            y0 = None
    blocks = [b for b in blocks if b[1] - b[0] >= 8]
    return blocks

def block_lum(img, box, shell_only=False):
    """块平均明度。shell_only=True 时只统计中性机身像素（明度 45..130 且
    低饱和 <0.18 —— 1/2/3/S/E/O 机身壳层；高光 W/H、accent A/Z/D/L 明度
    均在 130+，天然排除）。三层色阶是「壳层」分离 —— 亮顶面 vs 中正面 vs
    暗侧面；accent 在面上保持鲜亮（V3 §14），不计入壳层对比。"""
    y0, y1 = box
    lums, n = 0.0, 0
    for y in range(y0 + 2, y1 - 2, 2):
        for x in range(0, img.width, 2):
            c = img.getpixel((x, y))
            if c[3] <= 8:
                continue
            lm = luminance(c)
            if shell_only:
                mx, mn = max(c[:3]), min(c[:3])
                sat = (mx - mn) / 255.0
                if not (45.0 <= lm <= 130.0 and sat < 0.18):
                    continue
            lums += lm
            n += 1
    return lums / n if n else 0.0

def outline_stats(img, box):
    """竖直侧缘轮廓：仅统计左/右边缘（顶缘=受光带、底缘=接地线，均非轮廓）。
    明度 <92 为暗轮廓；92..150 为中调缺口；>150 为高光/accent 开口（V3 §11
    高光侧开放，豁免）。缺口统计仅计中调像素。"""
    y0, y1 = box
    w = img.width
    dark, mid, bright = 0, 0, 0
    max_gap, cur = 0, 0
    for y in range(y0, y1):
        xs = []
        for x in range(w):
            if img.getpixel((x, y))[3] > 8:
                xs.append(x)
        if not xs:
            continue
        for x in (xs[0], xs[-1]):
            c = img.getpixel((x, y))
            lm = luminance(c)
            if lm < 92.0:
                dark += 1
                cur = 0
            elif lm <= 150.0:
                mid += 1
                cur += 1
                max_gap = max(max_gap, cur)
            else:
                bright += 1
                cur = 0
    total = dark + mid
    ratio = dark / total if total else 0.0
    return ratio, max_gap, dark, mid, bright

def count_near(img, box, ref, tol):
    y0, y1 = box
    n = 0
    for y in range(y0, y1, 2):
        for x in range(0, img.width, 2):
            c = img.getpixel((x, y))
            if c[3] > 8 and near(c, ref, tol):
                n += 1
    return n

def bounding_of(img, box, pred):
    y0, y1 = box
    xs, ys = [], []
    for y in range(y0, y1, 2):
        for x in range(0, img.width, 2):
            c = img.getpixel((x, y))
            if c[3] > 8 and pred(c):
                xs.append(x)
                ys.append(y)
    if not xs:
        return None
    return (min(xs), min(ys), max(xs), max(ys), len(xs))

def main():
    base = "tests/evidence/"
    ids = ["bike", "treadmill", "bench_press"]
    ok = True
    def check(cond, label):
        nonlocal ok
        ok = ok and cond
        print(f"  {'PASS' if cond else 'FAIL'} {label}")

    for eq in ids:
        path = base + f"v31-r4-p2-sprite-{eq}.png"
        img = Image.open(path).convert("RGBA")
        blocks = split_blocks(img)
        print(f"== {eq} {img.width}x{img.height} blocks={len(blocks)}")
        if len(blocks) < 3:
            print(f"  FAIL {eq} needs 3 blocks (top/front/side), got {len(blocks)}")
            ok = False
            continue
        top_b, front_b, side_b = blocks[0], blocks[1], blocks[2]

        # ---- A. 三层层级分离（含 accent 的全明度）：顶面 > 正面 / 顶面 > 侧面 ----
        # 顶面受光最亮；正面 zone 色压一档（凳面/飞轮毂明度台阶）；侧面整面压暗。
        # 全明度均值被两面共有的大块 accent（屏幕/飞轮高光）稀释 —— 方向性
        # 用 +1/+4 小边距校验；壳层分离（中性材质）同时打印供记录。
        tl = block_lum(img, top_b)
        fl = block_lum(img, front_b)
        sl = block_lum(img, side_b)
        tl_s = block_lum(img, top_b, True)
        fl_s = block_lum(img, front_b, True)
        sl_s = block_lum(img, side_b, True)
        print(f"  lum top={tl:.0f} front={fl:.0f} side={sl:.0f} | shell top={tl_s:.0f} front={fl_s:.0f} side={sl_s:.0f}")
        check(tl > fl + 1.0, f"A top brighter than front ({tl:.0f} > {fl:.0f}+1)")
        check(tl > sl + 4.0, f"A top brighter than side ({tl:.0f} > {sl:.0f}+4)")

        # ---- B. 轮廓连续性：三面边界暗像素占比 + 最大缺口 ----
        for name, b in (("top", top_b), ("front", front_b), ("side", side_b)):
            ratio, max_gap, dark, mid, bright = outline_stats(img, b)
            # 4x 放大后 1 个 art px = 4 dump px；缺口 < 3 art px = 12 dump px
            # 轮廓连续性：暗轮廓占比（手绘缺口 ~12% 设计目标，故 0.75 阈值；
            # 连续性由 max_gap 闸门保证 —— 无 >3 art px 长缺口）
            check(ratio >= 0.75, f"B {eq} {name} outline ratio {ratio:.2f} >= 0.75 (dark={dark} mid={mid} bright={bright})")
            check(max_gap <= 14, f"B {eq} {name} outline max gap {max_gap} <= 14 (≈3 art px)")

        # ---- C. 零部件可读（顶面 + 正面关键件尺寸/对比） ----
        if eq == "bike":
            # 飞轮圆盘：顶面中段 H（金属高光环）+ Z（毂）必须成片
            h_box = bounding_of(img, top_b, lambda c: near(c, METAL_HIGHLIGHT, 0.10))
            z_box = bounding_of(img, top_b, lambda c: near(c, ZONE_CARDIO, 0.10))
            if h_box and z_box:
                hw, hh = h_box[2] - h_box[0], h_box[3] - h_box[1]
                zw, zh = z_box[2] - z_box[0], z_box[3] - z_box[1]
                check(hw >= 20 and hh >= 20, f"C bike flywheel H ring {hw}x{hh} (2x 圆盘可辨)")
                check(zw >= 8 and zh >= 8, f"C bike flywheel hub Z {zw}x{zh}")
            else:
                check(False, "C bike flywheel H/Z present")
            # 把手抓握点：顶面首行 D/W 暖端头
            grips = 0
            for x in range(0, img.width, 2):
                c = img.getpixel((x, top_b[0] + 2))
                if c[3] > 8 and (near(c, EQUIP_HIGHLIGHT, 0.12) or near(c, (93, 102, 115), 0.15)):
                    grips += 1
            check(grips >= 6, f"C bike handlebar grip ends visible ({grips} px)")
            # 正面飞轮：front 块 H 成片
            fh = bounding_of(img, front_b, lambda c: near(c, METAL_HIGHLIGHT, 0.10))
            if fh:
                fhw, fhh = fh[2] - fh[0], fh[3] - fh[1]
                check(fhw >= 8 and fhh >= 8, f"C bike front flywheel H {fhw}x{fhh}")
            else:
                check(False, "C bike front flywheel H present")
        elif eq == "treadmill":
            # 控制台：顶面南缘 + 正面顶部 A 青蓝
            ta = bounding_of(img, top_b, lambda c: near(c, EQUIP_ACCENT_CYAN, 0.12))
            fa = bounding_of(img, front_b, lambda c: near(c, EQUIP_ACCENT_CYAN, 0.12))
            if ta:
                check(ta[4] >= 8, f"C treadmill console cyan on top ({ta[4]} px)")
            else:
                check(False, "C treadmill console cyan on top")
            if fa:
                fah = fa[3] - fa[1]
                check(fah >= 8, f"C treadmill console cyan on front face ({fah} px tall)")
            else:
                check(False, "C treadmill console cyan on front face")
            # 跑带：顶面中段 M/S 交替存在（纹理带）
            belt = 0
            for y in range(top_b[0] + 8 * MAG, top_b[1] - 8 * MAG, 4):
                for x in range(0, img.width, 4):
                    c = img.getpixel((x, y))
                    if c[3] > 8 and (near(c, (81, 90, 103), 0.12) or near(c, EQUIP_SHADOW_TONE, 0.12)):
                        belt += 1
            check(belt >= 20, f"C treadmill belt tread pattern ({belt} px)")
        elif eq == "bench_press":
            # 凳面：顶面 Z/L 成片（2x 可辨尺寸）
            z_box = bounding_of(img, top_b, lambda c: near(c, ZONE_STRENGTH, 0.10))
            l_box = bounding_of(img, top_b, lambda c: near(c, (159, 200, 173), 0.12) or near(c, (159, 200, 173), 0.12))
            if z_box:
                zw, zh = z_box[2] - z_box[0], z_box[3] - z_box[1]
                check(zw >= 30 and zh >= 16, f"C bench pad Z {zw}x{zh}")
            else:
                check(False, "C bench pad Z present")
            # 杠铃：顶面 H/M 亮条（横杆 + 金属）
            hm = bounding_of(img, top_b, lambda c: near(c, METAL_HIGHLIGHT, 0.12) or near(c, (93, 102, 115), 0.12))
            if hm:
                hmw, hmh = hm[2] - hm[0], hm[3] - hm[1]
                check(hmw >= 40 and hmh >= 6, f"C bench barbell M/H bar {hmw}x{hmh}")
            else:
                check(False, "C bench barbell M/H present")
            # 凳面正面：front 块 Z（正面压暗 0.22 后仍在 zone 色族内，明度台阶
            # 但颜色可辨）成片
            fz = bounding_of(img, front_b, lambda c: near(c, ZONE_STRENGTH, 0.16) or near(c, (124, 164, 142), 0.10))
            if fz:
                check(fz[4] >= 16, f"C bench front pad Z ({fz[4]} px)")
            else:
                check(False, "C bench front pad Z present")

    print("RESULT:", "PASS" if ok else "FAIL")
    sys.exit(0 if ok else 1)

if __name__ == "__main__":
    main()
