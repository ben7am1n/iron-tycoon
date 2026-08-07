# src/palette.gd — art-bible §4 Color Palette（全项目单一色彩数据源）
#
# 后续所有视觉阶段（Phase B 设备 / Phase C 会员 / UI 迁移）一律引用本文件，
# 不得各写各的色值。访问方式：
#   const Palette := preload("res://src/palette.gd")
#   draw_rect(rect, Palette.SAGE)
#
# 无 class_name：headless 下 class_name 不保证全局注册（项目约定，
# 见 src/main.gd 头部注释），跨脚本一律 preload const alias。
#
# 色值来源：design/art/art-bible.md §4（Warm Cream 暖底 + 柔和功能点缀色），
# 风格禁区：无高饱和撞色、无刺眼红、无快速闪烁。

# === art-bible §4 Primary Palette（7 色全量） ===

## Warm Cream #F4E9D8 — 地板/背景底色，营造温暖留白。
const CREAM_BG := Color("F4E9D8")
## Soft Charcoal #3C3A42 — 描边/文字/像素轮廓（非纯黑，降低对比压力）。
const CHARCOAL := Color("3C3A42")
## Sage #8FBF9F — 力量区 / 正向满意度 / “好”的语义。
const SAGE := Color("8FBF9F")
## Sky #8EC5E8 — 有氧区 / 平静 / 信息类语义。
const SKY := Color("8EC5E8")
## Peach #F2B486 — 团课/社交区 / 温暖强调。
const PEACH := Color("F2B486")
## Butter #F5D97B — 金钱/奖励/里程碑高光。
const BUTTER := Color("F5D97B")
## Dusty Rose #E0A0A0 — 拥挤/需注意（柔和版“警示”，绝不刺眼）。
const ROSE := Color("E0A0A0")

# === 工具色（art-bible 派生，供绘制层使用） ===

## 网格线：Soft Charcoal（非纯黑，1px，替代旧灰 Color(0.25,0.25,0.3)）。
const GRID_LINE := CHARCOAL
## 区域色块描边：Soft Charcoal，1px（art-bible §6 “地板色块 + 柔和描边”）。
const ZONE_BORDER := CHARCOAL

# === 地板区域划分（art-bible §6：功能区用色块 + 柔和描边区分，分区一眼可读） ===
#
# 单元：网格 cell 坐标（13×10，CELL_SIZE=32，见 src/main.gd）。
# 划分：左力量 / 中有氧 / 右团课 —— 按任务建议 + ENTRANCE(0,0) 左上、
# EXIT(12,9) 右下的动线排布。色块内缩 1 cell 形成奶油色环场走道
# （art-bible 留白优先；走道连通入口→出口），区域边界与网格线对齐。
# 单一来源，main.gd _draw_floor_zones() 与后续阶段均读取这里，不得在绘制处硬编码。
const ZONE_RECTS := {
	"strength": Rect2i(1, 1, 4, 8),
	"cardio": Rect2i(5, 1, 4, 8),
	"flex": Rect2i(9, 1, 3, 8),
}
## 区域语义色（与 equipment_catalog.json 的 zone_membership 标签一致：
## strength→Sage、cardio→Sky、flex→Peach）。
const ZONE_COLORS := {
	"strength": SAGE,
	"cardio": SKY,
	"flex": PEACH,
}
