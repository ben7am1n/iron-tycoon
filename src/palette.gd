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

# === 会员角色工具色（Phase C v2 派生：2.5D 像素小人，art-bible-25d §2） ===
#
# 供 src/presentation/member_sprite.gd 使用。全部从 art-bible §4 主色域
# 派生（暖调、低饱和），状态双通道的“颜色通道”直接引用 SKY / PEACH /
# MEMBER_LEAVE_GRAY —— 绘制处不得另写色值。

## 肤色：暖调浅肤色（Warm Cream 亮化暖化，不抢状态色）。
const MEMBER_SKIN := Color("EACBA6")
## 发色：暖深棕（Charcoal 暖化，非纯黑 —— art-bible §3 禁纯黑描边）。
const MEMBER_HAIR := Color("5E4638")
## 裤色：暖灰褐（Charcoal 暖化中调，腿/裤块面）。
const MEMBER_PANTS := Color("6E5F53")
## 鞋色：暖深灰（Charcoal 暖化，鞋底块面）。
const MEMBER_SHOE := Color("4A413B")
## 离场灰：低饱和暖灰（LEAVING 状态通道 —— 脱出饱和区，与
## walking≈Sky / queue≈Peach 三态区分；非 art-bible 主色，状态专用）。
const MEMBER_LEAVE_GRAY := Color("9A948C")
## 脚底阴影：Soft Charcoal 低透明（art-bible-25d §2 “大块阴影”）。
const MEMBER_SHADOW := Color(0.235, 0.227, 0.259, 0.28)

# === Phase B v2 设备像素美术（art-bible-25d-style §2 材质概括 + art-bible §7 拖放反馈） ===
# 设备 = 2.5D 场景的「前景像素主体」：粗颗粒 2D 像素 sprite（32×32 整数倍，Nearest）。
# 色值仍以本文件为单一来源；设备精灵程序化绘制（src/presentation/equipment_art.gd）只引用这里。

## 金属暗面（器械金属框架/滚轮/杠铃片主体色）：冷灰，非纯黑（25d §3 禁纯黑粗边）。
const METAL_DARK := Color("5B6470")
## 金属冷色高光（25d §2 材质概括：金属 = 少量冷色高光）：Sky 系提亮，非纯白大面积。
const METAL_HIGHLIGHT := Color("B7D4EC")
## 设备脚下大暗面（25d §2 阴影：大块明暗色块，不追求物理写实）：半透明深色块，替代旧纯灰。
## V3 §6/§7：阴影偏冷、偏蓝灰 —— EQUIP_SHADOW 改为冷蓝灰（0.05,0.09,0.14）。
const EQUIP_SHADOW := Color(0.05, 0.09, 0.14, 0.38)
## 放置预览合法：柔和高亮（art-bible §7）—— 半透明白/Sage tint，绝不刺眼。
const PLACEMENT_OK_TINT := Color(0.96, 0.98, 0.94, 0.30)
## 放置预览非法：Dusty Rose #E0A0A0 柔和警示（art-bible §7，绝不刺眼红）——复用 ROSE 但显式声明 alpha。
const PLACEMENT_BAD_TINT := Color("E0A0A0", 0.35)
## 吸附「咔哒」视觉反馈（art-bible §7 动效手感）：Butter 脉冲环。
const SNAP_PULSE_COLOR := BUTTER

# === V3 §7 色彩体系（Phase 5：暖环境 + 冷阴影 + 高饱和重点色） ===
#
# V3 视觉重制 Phase 5 新增色域（visual-remaster-spec-v3.md §7）：
#   背景基底：暖灰、奶油灰、低饱和棕
#   阴影：深蓝灰、青灰
#   器械：炭灰、深蓝灰、浅灰金属
#   木材：暖橙棕
#   植物：中等饱和绿
#   Accent：黄、橙、青蓝（只用于设备屏幕/互动提示/重要道具/小型装饰）
# 色值单一来源（项目约定）：绘制层一律引用本文件，禁止硬编码。

## 顶墙基底：暖灰奶油灰（V3 §3 墙壁）。
const WALL_BASE := Color("8B8378")
## 顶墙踢脚/明暗块：低饱和棕（比墙基底深一档）。
const WALL_DARK := Color("6E675C")
## 墙裙线：暖灰更亮一档（装饰压条）。
const WALL_TRIM := Color("9C948A")
## 窗玻璃：冷青灰蓝（V3 §7 阴影系青灰；窗户斜向自然光的载体）。
const WINDOW_GLASS := Color("9FB4C8")
## 窗框：炭灰暖调（非纯黑，25d §3）。
const WINDOW_FRAME := Color("57534A")

## 地板材质 —— 力量区深灰橡胶地垫（V3 §1/§7 炭灰深蓝灰系）。
const FLOOR_STRENGTH_BASE := Color("4B4F57")
const FLOOR_STRENGTH_BLOCK := Color("454952")   # 略有色差的橡胶块
const FLOOR_STRENGTH_SEAM := Color("3C4047")    # 接缝
const FLOOR_STRENGTH_WEAR := Color("5A5F68")    # 磨损/高光
const FLOOR_STRENGTH_STAIN := Color("383C44")   # 汗渍
## 地板材质 —— 有氧区偏暖灰/蓝灰地面。
const FLOOR_CARDIO_BASE := Color("7C8288")
const FLOOR_CARDIO_DOT := Color("71777D")       # 细小重复纹理
const FLOOR_CARDIO_EDGE := Color("666C72")      # 边缘压条
## 地板材质 —— 瑜伽区暖色木地板（V3 §7 木材暖橙棕）。
const FLOOR_FLEX_BASE := Color("A9744C")
const FLOOR_FLEX_PLANK := Color("96653F")       # 木板分隔
const FLOOR_FLEX_GRAIN := Color("8F5F3B")       # 像素化木纹
## 地板材质 —— 公共通道浅灰/暖灰瓷砖（比训练区亮，有砖缝）。
const FLOOR_WALK_BASE := Color("D3CBB9")
const FLOOR_WALK_GROUT := Color("BDB4A0")

## 植物叶色：中等饱和绿（V3 §7；比旧 Sage 更深更实，脱离 pastel）。
const PLANT_GREEN := Color("4E8A5A")
const PLANT_GREEN_DARK := Color("3E7048")
const PLANT_GREEN_LIGHT := Color("6BA575")
## 陶盆：低饱和暖棕。
const PLANT_POT := Color("9C5A3C")

## Accent 高饱和色（V3 §7 —— 只用于设备屏幕/小型装饰/UI 提示）。
const ACCENT_YELLOW := Color("F2C94C")
const ACCENT_ORANGE := Color("E07A3F")
const ACCENT_CYAN := Color("45C4D8")
## 设备屏幕 emissive（V3 §6：青蓝/绿局部 emissive pixels）。
const EMISSIVE_CYAN := Color("4FD8E8")
const EMISSIVE_GREEN := Color("58E08A")
## 高光：暖黄/奶白（V3 §6 高光暖黄色/奶白色；金属高光仍用 METAL_HIGHLIGHT）。
const HIGHLIGHT_WARM := Color("F5E6C8")

## 顶部暖白主光（V3 §6 统一室内主光）：暖白，低 alpha 叠加在世界上层。
const LIGHT_TOP_WARM := Color(1.0, 0.95, 0.83, 0.06)
## 窗口斜向自然光（V3 §6）：暖白偏暖，比顶部主光略强。
const LIGHT_WINDOW := Color(1.0, 0.92, 0.75, 0.10)
## 墙边暗角（V3 §6 墙边比中心区域稍暗）：冷蓝灰，低 alpha。
const LIGHT_EDGE_SHADOW := Color(0.10, 0.14, 0.22, 0.16)
## 中心暗角加强（空间纵深：中心比墙边略亮 → 墙边深、中心亮）。
const LIGHT_CORNER_SHADOW := Color(0.10, 0.14, 0.22, 0.10)
