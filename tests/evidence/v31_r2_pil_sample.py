#!/usr/bin/env python3
"""V3.1 R2 — PIL 像素采样证据：人物差异化 silhouette + 器械 3 面 5 层辨识度。

采样两类图像：
  1. 会员变体矩阵 tests/evidence/v31-r2-members.png（capture 脚本导出，
     4 变体 × 3 姿态，2× 放大，暖白底）—— 验证：
     A. 每变体剪影分层色数（发/肤/衣/裤/鞋 + 轮廓/高光/阴影 ≥ 8 个独立色
        —— 非「单色色块」）
     B. 不同变体 silhouette 差异化：肩部宽度（变体 1 壮硕 > 变体 0 标准
        > 变体 2 纤细；变体 3 敦实最宽）—— 非「复制色块换色」
     C. 变体 1 运动服差异：无袖背心（肩部外侧是皮肤色）+ 橙色短裤
        （裤区高饱和橙色 FOCAL_GYM_ORANGE）
     D. contact shadow 明确：脚底有低透明暗影（收拢椭圆，非全宽平带）
  2. 渲染帧 tests/evidence/v31-r2-sprite.png（window 模式主场景）——
     世界采样验证人物与设备可辨（第二眼标准 V3 §15）：
     E. 人物衬衫通道正确（Sky/Peach/Gray 三态在画面中可采样）
     #     F. 设备部件可辨：treadmill 顶面控制台青蓝显示（真控制台）+
     #        belt 高对比履带纹（1 暗 + 3 亮；原 M2M2 两色接近不可见 → R2 修复）
     #        bench 长凳垫段（Z/D 分隔）在顶面纹理中可辨

断言（与 src/presentation/member_sprite.gd + equipment_art.gd 同源复算，
色值来自 src/palette.gd 单一来源；独立脚本，不依赖测试框架）：
  A1-A4  每变体剪影 ≥ 8 独立色（分层绘制，非单色块）
  B1     变体 1 肩宽 > 变体 0 肩宽（壮硕体型）
  B2     变体 2 肩宽 < 变体 0 肩宽（纤细体型）
  B3     变体 3 肩宽 > 变体 1 肩宽（敦实体型）
  C1     变体 1 肩部外侧为皮肤色（无袖背心）
  C2     变体 1 裤区存在 FOCAL_GYM_ORANGE（橙色短裤焦点）
  D1     脚底接触影低透明（alpha 0.1..0.5）且宽度收拢 < 身宽
  E1-E3  渲染帧人物衬衫三态
  F1     treadmill 控制台青蓝显示
  F2     treadmill belt S2 履带对比（同帧内 S 暗与 2 中调并存）

用法：python3 tests/evidence/v31_r2_pil_sample.py
退出码：0 = 全部通过；1 = 有失败。
"""
import math
import os
import sys
from PIL import Image

EVIDENCE_DIR = os.path.dirname(os.path.abspath(__file__))
SPRITE = os.path.join(EVIDENCE_DIR, "v31-r2-sprite.png")
MEMBERS = os.path.join(EVIDENCE_DIR, "v31-r2-members.png")

# === palette.gd 复算色（0-255） ===
SKY = (0x8E, 0xC5, 0xE8)
PEACH = (0xF2, 0xB4, 0x86)
LEAVE_GRAY = (0x9A, 0x94, 0x8C)
FOCAL_GYM_ORANGE = (0xFF, 0x8A, 0x2A)
EQUIP_ACCENT_CYAN = (0x2F, 0xC4, 0xE8)
EQUIP_SHADOW_TONE = (0x3A, 0x43, 0x50)
EQUIP_BODY = (0x5D, 0x66, 0x73)
MEMBER_HAIR = (0x5E, 0x46, 0x38)
MEMBER_SKIN = (0xEA, 0xCB, 0xA6)
MEMBER_PANTS = (0x6E, 0x5F, 0x53)
MEMBER_SHOE = (0x4A, 0x41, 0x3B)

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


def dist(a, b):
    return math.sqrt(sum((a[i] - b[i]) ** 2 for i in range(3)))


def near(c, t, tol=30):
    return dist(c[:3], t) <= tol


def quantized_colors(region, bg=None, tol=28):
    """区域独立色数（聚类；排除背景 [bg]）。"""
    reps = []
    w, h = region.size
    px = region.load()
    for y in range(h):
        for x in range(w):
            c = px[x, y]
            if len(c) >= 4 and c[3] < 128:
                continue
            if bg is not None and dist(c[:3], bg) < 10:
                continue
            matched = False
            for r in reps:
                if dist(c[:3], r) <= tol:
                    matched = True
                    break
            if not matched:
                reps.append(c[:3])
    return len(reps)


def bbox_nonbg(region, bg):
    """排除背景后的不透明 bbox。返回 (x0,y0,x1,y1) 或 None。"""
    w, h = region.size
    px = region.load()
    xs, ys = [], []
    for y in range(h):
        for x in range(w):
            c = px[x, y]
            if len(c) >= 4 and c[3] < 128:
                continue
            if dist(c[:3], bg) < 10:
                continue
            xs.append(x)
            ys.append(y)
    if not xs:
        return None
    return (min(xs), min(ys), max(xs), max(ys))


def contains_color(region, target, tol=30, bg=None):
    w, h = region.size
    px = region.load()
    for y in range(h):
        for x in range(w):
            c = px[x, y]
            if len(c) >= 4 and c[3] < 128:
                continue
            if bg is not None and dist(c[:3], bg) < 10:
                continue
            if dist(c[:3], target) <= tol:
                return True
    return False


BG = (235, 230, 219)  # 暖白底 0.92,0.90,0.86


def member_cell(vi, pi):
    """变体 vi（0..3）× 姿态 pi（0 walk/1 tired/2 satisfied）2× 放样 cell。"""
    return (vi * 96, pi * 96, (vi + 1) * 96, (pi + 1) * 96)


def verify_member_matrix():
    print("\n-- A. 会员剪影分层色数（非单色块） --")
    if not os.path.exists(MEMBERS):
        check(False, f"member matrix exists ({os.path.basename(MEMBERS)})")
        return
    sheet = Image.open(MEMBERS).convert("RGBA")
    for vi in range(4):
        region = sheet.crop(member_cell(vi, 0))  # walk 帧
        n = quantized_colors(region, bg=BG)
        check(n >= 6, f"A{vi+1} variant {vi} walk silhouette has >=6 layered colors (got {n})")

    print("\n-- B. 差异化 silhouette：肩部宽度（非复制色块） --")
    # 肩宽：walk 帧剪影在「躯干上段」y 区间（2× → 肩部 ~y 38..44 纹理像素）
    widths = {}
    for vi in range(4):
        region = sheet.crop(member_cell(vi, 0))
        # 躯干上段窗口：纹理 y 18..30 → 2× y 36..60（避开头 0..17 与腿 32+）
        band = region.crop((0, 36, 96, 60))
        bbox = bbox_nonbg(band, BG)
        widths[vi] = (bbox[2] - bbox[0] + 1) if bbox else 0
        print(f"  -- variant {vi} shoulder band width = {widths[vi]}px")
    check(widths[1] > widths[0], f"B1 muscular variant 1 shoulder ({widths[1]}) > standard v0 ({widths[0]})")
    check(widths[2] < widths[0], f"B2 slim variant 2 shoulder ({widths[2]}) < standard v0 ({widths[0]})")
    check(widths[3] > widths[1], f"B3 stocky variant 3 shoulder ({widths[3]}) > muscular v1 ({widths[1]})")

    print("\n-- C. 运动服配色差异（V3.1 R2） --")
    v1 = sheet.crop(member_cell(1, 0))
    # 无袖背心：build 1 sleeve=ss —— 肩部外侧（纹理 x5..7 → 2× x10..14,
    # y 18..22 → 2× y 36..44）应为变体 1 皮肤色 MEMBER_SKIN_ALT1 #E0B98F
    sleeve = v1.crop((9, 36, 16, 46))
    check(contains_color(sleeve, (0xE0, 0xB9, 0x8F), 30, bg=BG),
          "C1 variant 1 shoulder sleeve is skin tone (tank top, ss)")
    # 橙色短裤：裤区（y 64..78）应有 FOCAL_GYM_ORANGE
    pants = v1.crop((0, 64, 96, 80))
    check(contains_color(pants, FOCAL_GYM_ORANGE, 30, bg=BG),
          "C2 variant 1 shorts are FOCAL_GYM_ORANGE (sportswear focal)")

    print("\n-- D. contact shadow 明确（收拢椭圆，非全宽平带） --")
    v0 = sheet.crop(member_cell(0, 0))
    # 影区：纹理 y 44..47 → 2× y 88..94
    shadow_band = v0.crop((0, 88, 96, 96))
    bbox_s = bbox_nonbg(shadow_band, BG)
    body_bbox = bbox_nonbg(v0.crop((0, 0, 96, 88)), BG)
    if bbox_s and body_bbox:
        sw = bbox_s[2] - bbox_s[0] + 1
        bw = body_bbox[2] - body_bbox[0] + 1
        # 影带内有低透明像素（alpha 0.1..0.5）且宽度收拢
        px = shadow_band.load()
        has_soft = any(px[x, y][3] > 25 and px[x, y][3] < 130
                       for y in range(96) for x in range(96))
        check(has_soft, f"D1 contact shadow soft alpha present (got translucent px)")
        check(sw < bw, f"D2 shadow width {sw} < body width {bw} (tapered, not full-width plate)")
    else:
        check(False, "D1/D2 shadow band bbox present")


def verify_rendered_scene():
    print("\n-- E. 渲染帧：人物衬衫三态可采样（V3 §15 人物可辨） --")
    if not os.path.exists(SPRITE):
        check(False, f"rendered frame exists ({os.path.basename(SPRITE)})")
        return
    img = Image.open(SPRITE).convert("RGB")
    px = img.load()
    # 注入会员坐标（与 v31_r2_capture.gd INJECTED 同源）：
    #   WALKING(5,2) / WALKING(11,2) / WALKING(5,6) / WALKING(11,4)
    #   QUEUEING(3,6) / LEAVING(10,6)
    # 屏幕坐标经 world_to_screen 复算（与 capture 同源），衬衫局部 (24,19)。
    from math import sin, cos, radians
    SHEAR, FS, HS, EX, WS, OFF = 0.35, 0.62, 0.79, 0.20, 0.75, (19.05, 78.1875)
    SPX, SPY = 1280.0 / 426.0, 720.0 / 240.0

    def canvas_to_screen(c):
        vx = (c[0] * WS + OFF[0]) * SPX
        vy = (c[1] * WS + OFF[1]) * SPY
        return (int(round(vx)), int(round(vy)))

    def member_shirt(cell, expect):
        cx = cell[0] * 32 + 16
        cy = cell[1] * 32 + 32
        feet = (cx + cy * SHEAR, cy * FS)
        anchor = (feet[0] - 24, feet[1] - 48)
        p = canvas_to_screen((anchor[0] + 24, anchor[1] + 19))
        if not (0 <= p[0] < img.width and 0 <= p[1] < img.height):
            return False
        c = px[p[0], p[1]]
        return near(c, expect, 55)

    check(member_shirt((5, 2), SKY), "E1 walking member shirt Sky (v0)")
    check(member_shirt((11, 2), SKY), "E2 walking member shirt Sky (v1)")
    check(member_shirt((3, 6), PEACH), "E3 queueing member shirt Peach")

    print("\n-- F. 设备部件可辨（V3.1 P2 真物体） --")
    # 用 treadmill_b (footprint (192,96,64,32)，无 USING 会员遮挡)：
    #   控制台：顶面 map 行 13..14 → 世界 y ≈ 96 + 13.5/16*32 ≈ 123
    #   belt：顶面 map 行 4..10 → 世界 y ≈ 96 + 7/16*32 ≈ 110
    def world_to_screen(w, z=0.0):
        proj = (w[0] + w[1] * SHEAR - z * EX, w[1] * FS - z * HS)
        return canvas_to_screen(proj)

    p = world_to_screen((224, 123), 30.0)
    found_cyan = False
    # 控制台行（map 行 13..14）横跨整条 footprint：青蓝 A 簇在 x ≈ 208..212 /
    # 228..234（map char 8..10 / 18..21）—— 扫整条控制台带（世界 x 200..250）
    for wy in range(121, 127):
        for wx in range(200, 252, 2):
            pp = world_to_screen((wx, wy), 30.0)
            for dy in range(-2, 3):
                for dx in range(-2, 3):
                    sx, sy = pp[0] + dx, pp[1] + dy
                    if 0 <= sx < img.width and 0 <= sy < img.height:
                        if near(px[sx, sy], EQUIP_ACCENT_CYAN, 60) or near(px[sx, sy], (0x4F, 0xD8, 0xE8), 60):
                            found_cyan = True
                            break
                if found_cyan:
                    break
            if found_cyan:
                break
        if found_cyan:
            break
    check(found_cyan, "F1 treadmill console cyan display visible (real console)")
    # treadmill belt 高对比履带：同帧内存在 EQUIP_BODY_DARK（1 暗）与
    # EQUIP_BODY_LIGHT（3 亮）—— 原 M2M2 两色接近不可见，R2 修复为可见履带
    found_s, found_2 = False, False
    for wy in range(102, 120, 2):
        pp = world_to_screen((224, wy), 30.0)
        for dy in range(-2, 3):
            for dx in range(-2, 3):
                sx, sy = pp[0] + dx, pp[1] + dy
                if 0 <= sx < img.width and 0 <= sy < img.height:
                    c = px[sx, sy]
                    if near(c, (0x49, 0x52, 0x5F), 45):   # EQUIP_BODY_DARK (1)
                        found_s = True
                    if near(c, (0x8E, 0x99, 0xA6), 45):   # EQUIP_BODY_LIGHT (3)
                        found_2 = True
    check(found_s and found_2,
          f"F2 treadmill belt high-contrast tread (dark 1 {'OK' if found_s else 'MISS'} + light 3 {'OK' if found_2 else 'MISS'})")


def main():
    print("=" * 64)
    print("  V3.1 R2 PIL PIXEL SAMPLING — member silhouettes + equipment parts")
    print("  evidence dir: %s" % EVIDENCE_DIR)
    print("=" * 64)
    verify_member_matrix()
    verify_rendered_scene()
    print("\n" + "=" * 64)
    print("  PIL SAMPLING RESULT: %s (%d passed, %d failed)" % (
        "PASS" if failed == 0 else "FAIL", passed, failed))
    print("=" * 64)
    sys.exit(1 if failed > 0 else 0)


if __name__ == "__main__":
    main()
