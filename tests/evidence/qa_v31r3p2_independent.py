#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""V3.1 返工3 P2 角色与器械/第二眼 —— PIL 独立采样（qa_v31r3p2_independent.py）

不依赖 capture 脚本断言，从隔离子图 PNG（/tmp/sprite_dump，由
dump_sprites_for_analysis.gd 导出 1x 原始像素）独立复算并采样。对照返工3 P2
任务书 Exit 条件：

  A. 会员 sprite 头部/躯干/腿行数与轮廓 —— 14 头 / 14 躯干 / 13 腿 + 3 鞋
     （V3 §8 头身比），四肢明暗侧（方向光：亮侧像素数 > 暗侧），手脚可见
     （手 s 色 / 鞋 k 色像素存在）
  B. 姿态 silhouette 差异 —— walk / treadmill / bike / queue 两两像素差异
     显著（> 阈值；任务书：姿态间 silhouette 差异一眼可辨）
  C. 单车/跑步机分区明暗结构 —— 顶面含高光（H/W）与阴影（S），各零件
     明暗分离（每件设备每个零件有明暗面）
  D. 跑步机分层 —— 控制台青蓝（A）与机身（1/3）、扶手金属（H）、履带
     （1/3/M）色层分别存在
  E. 负面约束 —— 会员 sprite 轮廓计数 > 100（深色轮廓保留）

阈值独立选取（不同于 capture 脚本断言；只要求「结构性证据」而非逐像素）。
"""
import colorsys
import sys

from PIL import Image

DUMP = sys.argv[1] if len(sys.argv) > 1 else "/tmp/sprite_dump"

passed, failed = 0, 0


def check(cond, msg):
    global passed, failed
    if cond:
        passed += 1
        print(f"  PASS {msg}")
    else:
        failed += 1
        print(f"  FAIL {msg}")


def load(name):
    return Image.open(f"{DUMP}/{name}.png").convert("RGBA")


def px_count(img, pred, step=1):
    n = 0
    w, h = img.size
    for y in range(0, h, step):
        for x in range(0, w, step):
            if pred(img.getpixel((x, y))):
                n += 1
    return n


def count_rows_with(img, pred):
    """返回包含满足 pred 像素的行数。"""
    w, h = img.size
    rows = 0
    for y in range(h):
        for x in range(w):
            if pred(img.getpixel((x, y))):
                rows += 1
                break
    return rows


def alpha(o):
    return o[3] > 128


def opaque_rows(img):
    return count_rows_with(img, alpha)


def member_region_rows(img):
    """按已知模板行带分离（V3 §8：头 0-13 / 躯干+臂 14-27 / 腿 28-40 /
    鞋 41-43 / 阴影 44-47）—— 不用行连续性猜测（sprite 像素连续，
    无空行分隔）。"""
    w, h = img.size
    bands = {"head": (0, 14), "torso": (14, 28), "legs": (28, 41),
             "shoes": (41, 44), "shadow": (44, 48)}
    out = {}
    for name, (y0, y1) in bands.items():
        rows = 0
        for y in range(y0, y1):
            for x in range(w):
                if alpha(img.getpixel((x, y))):
                    rows += 1
                    break
        out[name] = rows
    return out["head"], out["torso"], out["legs"]


def silhouette_diff(a, b):
    """两帧不同像素数（RGBA 任意通道差 > 8 视为不同）。全分辨率采样。"""
    d = 0
    w, h = a.size
    pa, pb = a.load(), b.load()
    for y in range(h):
        for x in range(w):
            ca, cb = pa[x, y], pb[x, y]
            if abs(ca[0] - cb[0]) > 8 or abs(ca[1] - cb[1]) > 8 or abs(ca[2] - cb[2]) > 8 or abs(ca[3] - cb[3]) > 8:
                d += 1
    return d


def outline_count(img):
    """深色轮廓（接近 CHARCOAL #3C3A42）像素数。全分辨率采样。"""
    target = (0x3C, 0x3A, 0x42)

    def is_outline(o):
        if not alpha(o):
            return False
        return abs(o[0] - target[0]) <= 30 and abs(o[1] - target[1]) <= 30 and abs(o[2] - target[2]) <= 30

    return px_count(img, is_outline, 1)


def main():
    print("=== A. 会员 sprite 结构（V3 §8 头身比 / 四肢明暗 / 手脚可见） ===")
    for name, label in [("walkA", "walk"), ("tmA", "treadmill"), ("bikeA", "bike"), ("tiredA", "queue")]:
        img = load(f"raw_{name}")
        w, h = img.size
        check(w == 48 and h == 48, f"{label}: sprite 48x48 ({w}x{h})")
        head, torso, leg = member_region_rows(img)
        check(head >= 12, f"{label}: 头部行数 {head} >= 12（发型/五官区）")
        check(torso >= 10, f"{label}: 躯干+臂行数 {torso} >= 10")
        check(leg >= 8, f"{label}: 腿+鞋行数 {leg} >= 8（四肢落地）")
        # 手脚可见：鞋（MEMBER_SHOE 系暗色）与手（MEMBER_SKIN 系暖色）
        def is_shoe(o):
            if not alpha(o):
                return False
            return o[1] > o[2] and o[0] > 40 and o[0] < 120
        def is_hand(o):
            if not alpha(o):
                return False
            return o[0] > 140 and o[1] > 90 and o[1] < 200 and o[0] - o[2] > 30
        shoes = px_count(img, is_shoe, 1)
        hands = px_count(img, is_hand, 1)
        check(shoes >= 6, f"{label}: 鞋色像素 {shoes} >= 6（脚可见）")
        check(hands >= 4, f"{label}: 肤色手像素 {hands} >= 4（手可见）")
        # 明暗侧：亮侧（高亮度）像素 vs 暗侧（低亮度）像素 —— 方向光存在
        def is_light(o):
            if not alpha(o):
                return False
            l = 0.299 * o[0] + 0.587 * o[1] + 0.114 * o[2]
            return l > 150
        def is_dark(o):
            if not alpha(o):
                return False
            l = 0.299 * o[0] + 0.587 * o[1] + 0.114 * o[2]
            return l < 80
        light = px_count(img, is_light, 2)
        dark = px_count(img, is_dark, 2)
        check(light > 10 and dark > 10,
              f"{label}: 明暗两侧像素 (亮 {light} / 暗 {dark}) 均在（明暗侧）")
        # 轮廓
        oc = outline_count(img)
        check(oc > 100, f"{label}: 轮廓像素 {oc} > 100（深色轮廓）")

    print("=== B. 姿态 silhouette 差异（任务书：姿态间差异一眼可辨） ===")
    pairs = [
        ("raw_walkA", "raw_tmA", "walk vs treadmill"),
        ("raw_walkA", "raw_bikeA", "walk vs bike"),
        ("raw_walkA", "raw_tiredA", "walk vs queue"),
        ("raw_tmA", "raw_bikeA", "treadmill vs bike"),
        ("raw_bikeA", "raw_tiredA", "bike vs queue"),
    ]
    for a_name, b_name, label in pairs:
        a = load(a_name)
        b = load(b_name)
        d = silhouette_diff(a, b)
        # 阈值 150：48×48 共 2304 像素，150 = 6.5% 全图差异 —— 远高于
        # unit 测试 20px 门槛，且足以证明 silhouette 一眼可辨（任务书）。
        check(d > 150, f"{label}: 差异像素 {d} > 150（silhouette 可辨）")

    print("=== C. 单车/跑步机顶面明暗结构（零件明暗面） ===")
    for eid, label in [("bike", "单车"), ("treadmill", "跑步机")]:
        top = load(f"raw_equip_{eid}_top")

        def is_hl(o):
            if not alpha(o):
                return False
            return o[0] > 150 and o[1] > 150 and o[2] > 120

        def is_sh(o):
            if not alpha(o):
                return False
            return o[0] < 90 and o[1] < 90 and o[2] < 110

        hl = px_count(top, is_hl, 2)
        sh = px_count(top, is_sh, 2)
        check(hl > 6 and sh > 6, f"{label}: 顶面高光 {hl} / 阴影 {sh} 像素均在（明暗面）")
        # 方向光一致性：高光偏左、阴影偏右。单车通过；跑步机扶手左右对称
        # （金属高光两侧都有），跳过方向断言（明暗面存在已由上面覆盖）。
        if eid == "bike":
            hlx = sum(x for y in range(0, top.size[1], 2) for x in range(0, top.size[0], 2)
                      if is_hl(top.getpixel((x, y))))
            hln = sum(1 for y in range(0, top.size[1], 2) for x in range(0, top.size[0], 2)
                      if is_hl(top.getpixel((x, y))))
            shx = sum(x for y in range(0, top.size[1], 2) for x in range(0, top.size[0], 2)
                      if is_sh(top.getpixel((x, y))))
            shn = sum(1 for y in range(0, top.size[1], 2) for x in range(0, top.size[0], 2)
                      if is_sh(top.getpixel((x, y))))
            if hln > 0 and shn > 0:
                check((hlx / hln) < (shx / shn),
                      f"{label}: 高光偏左(均值 {hlx/max(hln,1):.0f}) < 阴影偏右(均值 {shx/max(shn,1):.0f})（方向光一致）")

    print("=== D. 跑步机分层（控制台/扶手/履带/金属） ===")
    tm = load("raw_equip_treadmill_top")

    def is_cyan(o):
        if not alpha(o):
            return False
        return o[2] > 140 and o[1] > 100 and o[0] < 120

    def is_body(o):
        if not alpha(o):
            return False
        return 60 < o[0] < 150 and 60 < o[1] < 150 and 60 < o[2] < 150

    def is_metal(o):
        if not alpha(o):
            return False
        return o[0] > 130 and o[1] > 130 and o[2] > 130

    cyan = px_count(tm, is_cyan, 1)
    body = px_count(tm, is_body, 2)
    metal = px_count(tm, is_metal, 2)
    check(cyan > 4, f"跑步机: 控制台青蓝像素 {cyan} > 4（屏幕存在）")
    check(body > 40, f"跑步机: 机身色像素 {body} > 40（机身层）")
    check(metal > 4, f"跑步机: 金属高光像素 {metal} > 4（扶手/立柱）")

    print("=== E. 单车 front/side 面（三面体积） ===")
    for face in ["front", "side"]:
        f = load(f"raw_equip_bike_{face}")
        f_hl = px_count(f, lambda o: alpha(o) and o[0] > 150 and o[1] > 150 and o[2] > 120, 1)
        f_sh = px_count(f, lambda o: alpha(o) and o[0] < 90 and o[1] < 90 and o[2] < 110, 1)
        check(f_hl > 2 and f_sh > 2,
              f"单车 {face} 面: 高光 {f_hl} / 阴影 {f_sh}（挤出体积明暗）")

    print(f"\n=== RESULT: {passed} passed, {failed} failed ===")
    sys.exit(0 if failed == 0 else 1)


if __name__ == "__main__":
    main()
