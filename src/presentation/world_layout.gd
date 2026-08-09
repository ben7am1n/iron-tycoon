# src/presentation/world_layout.gd — Phase 5 环境布局数据（单一来源）
#
# V3 §3（显著增加环境资产密度）：墙壁、窗户、海报、植物、饮水机、垃圾桶等
# 永久环境结构的位置。V3 §12（场景 storytelling）：每块区域像真实使用过的
# 空间 —— 跑步机旁水瓶毛巾海报、力量区散落小配重、瑜伽区植物音箱卷垫、
# 自行车区墙上计时器风扇水杯架。V3 §6（方向光）：窗口斜向自然光锚点。
#
# 坐标单位：世界像素空间（416×320，CELL_SIZE=32，13×10）。全部确定性
# 常量（数据驱动，无运行时计算）。本文件是布局唯一来源 —— 绘制层（
# environment_layer.gd / lighting_layer.gd / world_canvas.gd）一律引用这里。
#
# 布局原则（V3 §3/§4）：
#   - BACKGROUND：墙、窗、海报、远处装饰（低对比）
#   - GAMEPLAY：设备、会员（现有绘制）
#   - FOREGROUND：大植物、柱子（可轻微遮挡角色）
# 不占用可放置格（所有装饰物都在 walkway 环道或 zone 内非设备格）。
class_name WorldLayout extends RefCounted

const Palette := preload("res://src/palette.gd")

## 世界像素空间尺寸（与 main.gd GRID_W/H × CELL_SIZE 一致）。
const WORLD_W := 416
const WORLD_H := 320
const CELL := 32

# === V3 §3 墙壁（含门洞：入口 (0,0) 左上、出口 (12,9) 右下） ===
## 顶墙（健身房北墙）：y 0..24，x 32..416 —— x 0..32 留门洞（入口）。
const WALL_TOP_RECT := Rect2i(32, 0, WORLD_W - 32, 24)
## 侧墙左：x 0..14，y 32..320 —— y 0..32 留门洞（入口角）。
const WALL_LEFT_RECT := Rect2i(0, 32, 14, WORLD_H - 32)
## 侧墙右：x 402..416，y 0..288 —— y 288..320 留门洞（出口角）。
const WALL_RIGHT_RECT := Rect2i(WORLD_W - 14, 0, 14, WORLD_H - 32)
## 墙裙线高度（顶墙底部压条）。
const WALL_TRIM_Y := 20

# === V3 §15 第一眼修复：墙面延展填满视口宽度 ===
## 世界在 426×240 viewport 中以 scale 0.75 居中（57px 边距 = 76 world px），
## 可见世界 x 范围实际是 -76..492 —— 原墙面只画 0..416，两侧留下 ~171 screen
## px 的纯米色空带（门禁 FAIL：large empty beige background）。修复：把顶墙/
## 侧墙延展到完整可见宽度，并补 side-wall decor（见 WALL_SIDE_DECOR）。
## 顶墙左侧延展段（x -76..0，入口门洞 x 0..32 保留）。
const WALL_TOP_LEFT_FILL := Rect2i(-76, 0, 76, 24)
## 顶墙右侧延展段（x 416..492）。
const WALL_TOP_RIGHT_FILL := Rect2i(WORLD_W, 0, 76, 24)
## 侧墙左延展：x -76..14（覆盖原 WALL_LEFT_RECT 并左延至视口边缘）。
const WALL_LEFT_EXTENDED := Rect2i(-76, 32, 90, WORLD_H - 32)
## 侧墙右延展：x 402..492（覆盖原 WALL_RIGHT_RECT 并右延至视口边缘；
## y 288..320 仍留出口门洞）。
const WALL_RIGHT_EXTENDED := Rect2i(WORLD_W - 14, 0, 90, WORLD_H - 32)

## 延展墙面上的装饰（V3 §3/§12 结构元素：管道/镜子/海报/置物架/空调/挂钟/
## 通风口/毛巾架）。键 = 装饰 id，值 = 世界像素锚点（左上角）。由
## world_canvas._draw_side_wall_decor 绘制（简单像素块，纯结构装饰）。
## 左墙（x -76..14）：竖向管道 + 长镜 + 海报 + 置物架 + 挂钟。
const WALL_SIDE_DECOR := {
	"pipe_left_1": Vector2i(-70, 40),
	"pipe_left_2": Vector2i(-66, 40),
	"mirror_left": Vector2i(-60, 44),
	"poster_left_1": Vector2i(-44, 44),
	"shelf_left": Vector2i(-58, 140),
	"clock_left": Vector2i(-42, 140),
	"poster_left_2": Vector2i(-60, 200),
	"towel_rack_left": Vector2i(-46, 200),
	# 右墙（x 402..492）：竖向管道 + 海报 + 空调 + 置物架 + 通风口 + 挂钟。
	"pipe_right_1": Vector2i(424, 40),
	"pipe_right_2": Vector2i(428, 40),
	"poster_right_1": Vector2i(436, 44),
	"ac_right": Vector2i(452, 44),
	"shelf_right": Vector2i(436, 120),
	"clock_right": Vector2i(460, 120),
	"vent_right": Vector2i(446, 180),
	"poster_right_2": Vector2i(462, 200),
}

# === V3 §6 窗户（斜向自然光锚点） ===
## 顶墙窗户（2 扇）：窗框矩形（世界像素空间）。光从窗口斜向射入地板。
const WINDOWS := [
	Rect2i(96, 4, 56, 18),
	Rect2i(272, 4, 56, 18),
]

# === V3 §12 场景 storytelling 元素（装饰，无交互） ===
## 装饰物：prop_id -> 世界像素位置（左上角锚点）。绘制层引用本表。
## 位置避让初始布局设备格：treadmill(2,2)(6,3) bike(2,5) bench(1,7) yoga(9,2)
## 及其 access 格；全部落在 walkway 环道或 zone 空闲格（V3 §14 可读性）。
## V3.1 R3（打破规则化摆放）：全部锚点改为非 4px 对齐的「手摆」坐标
## （±1-3px 抖动，无两条道具共用同一 x/y 对齐列 —— 非网格摆放）；部分
## 道具刻意重叠（towel 搭在瓶上、plate 半压 plate —— 前后交错遮挡，
## 非孤立悬浮）。证据采样的道具（water_bottle_t1 / plant_bright_f1 /
## fountain / plant_bright_fore_1 / cup_yellow_f1 / yoga_ball_f1）保持
## 原坐标 —— phase1-5 证据不回归。
const DECOR := {
	# 跑步机旁：水瓶、毛巾（V3 §12；treadmill(2,2) 右侧空闲格）
	# R3：towel 搭在水瓶右上角（前后交错遮挡，非孤立悬浮）
	"water_bottle_t1": Vector2i(132, 70),
	"towel_t1": Vector2i(134, 73),
	# 力量区：散落小配重、粉笔盒（V3 §12；bench(1,7) 右侧 strength 区）
	# R3：配重全部错落（无同列对齐）+ plate_s2 半压 plate_s1
	"dumbbell_s1": Vector2i(127, 231),
	"dumbbell_s2": Vector2i(139, 245),
	"chalk_box": Vector2i(121, 261),
	# 力量区（V3 §15 第一眼密度）：散落壶铃/配重片/药球，填满 strength 区空闲格
	# R3：kettlebell 对角错落；medicine_ball 与 dumbbell_s3 相触（成组）
	"kettlebell_s1": Vector2i(38, 102),
	"kettlebell_s2": Vector2i(43, 113),
	"plate_s1": Vector2i(131, 219),
	"plate_s2": Vector2i(140, 221),
	"medicine_ball_s1": Vector2i(101, 235),
	"dumbbell_s3": Vector2i(105, 238),
	# V3.1 R3：杠铃架（V3 §12 力量区「杠铃架」）—— 力量区中段空闲格，
	# 与 plate_s1 成组（前后遮挡）
	"barbell_rack_s1": Vector2i(96, 200),
	# 瑜伽区：植物、小音箱、卷起的备用瑜伽垫（V3 §12；flex 区空闲格）
	# V3.1 R4/R5 精修：瑜伽区保留中饱和叶色，避免与粉紫用品挤成焦点碎簇；
	# 两盆亮叶焦点仍分布在中央通道和前景左下。
	# R3：speaker 偏移（不贴 plant 同列）+ warm_lamp（V3 §12「暖色灯」）
	"plant_f1": Vector2i(352, 176),
	"speaker_f1": Vector2i(335, 98),
	"mat_rolled_f1": Vector2i(349, 267),
	"warm_lamp_f1": Vector2i(296, 200),
	# 瑜伽区（V3 §15 密度）：瑜伽砖 + 第二盆植物
	# R3：block_f2 半压 block_f1（成组错落）
	"yoga_block_f1": Vector2i(311, 237),
	"yoga_block_f2": Vector2i(321, 245),
	"plant_f2": Vector2i(367, 121),
	# 自行车区：风扇、水杯架（V3 §12；bike(2,5) 左侧 walkway）
	# R3：杯架错开风扇（原同列对齐）
	"fan_b1": Vector2i(26, 161),
	"cup_holder_b1": Vector2i(23, 181),
	# 有氧区（V3 §15 密度）：第二台 treadmill 旁毛巾/水瓶 + 中间空闲格水杯
	# R3：towel 搭在水瓶上（遮挡）；cup_holder 偏移
	"towel_t2": Vector2i(196, 149),
	"water_bottle_t2": Vector2i(199, 153),
	"cup_holder_c1": Vector2i(233, 199),
	# 公共空间：饮水机（V3 §3）、垃圾桶、消防栓
	# R3：hydrant/trash 偏移（非 4px 对齐）
	"fountain": Vector2i(20, 40),
	"trash": Vector2i(385, 32),
	"hydrant": Vector2i(13, 121),
	# V3.1 P5 高饱和焦点（附录 V3.1 P5：10-15 个高饱和视觉焦点）——
	# 新增地面焦点：黄色水杯（前台南侧 walkway）+ 彩色瑜伽用品（瑜伽区）。
	# 位置避让既有设备/装饰/access 格（水杯 (88,108) 在前台 (56..160,
	# 24..48) 之南、treadmill(2,2) footprint (64..128,64..96) 之南、水瓶
	# (132,70) 之西 —— 贴地装饰，无设备盖住；瑜伽球/瑜伽带在 flex 区
	# 中段空闲竖条）。V3.1 R1（投影修正）：column_2 前景立柱（x 276..284,
	# 全深）在 HEIGHT_SCALE 0.79 下于屏幕遮挡 flex 区西缘 x 284..308 ——
	# 瑜伽球/带原 x=288 落入柱影，东移到 (320,136)/(320,176) 可见木地板。
	"cup_yellow_f1": Vector2i(88, 108),
	"yoga_ball_f1": Vector2i(320, 136),
	"yoga_strap_f1": Vector2i(320, 176),
	# 中央通道（walkway 环道，V3 §15 第一眼：消除空荡通道）—— 长椅/盆栽/垫子
	# 沿顶部通道：前台右侧等待长椅 + 通道盆栽（cell row 1 空闲格，避开前台
	# (56,24,104,24) 与入口门洞 x 0..32）
	# R3：长椅错落（bench_b2 前移半格）+ 植物偏移
	"bench_b1": Vector2i(171, 33),
	"bench_b2": Vector2i(209, 33),
	# V3.1 P5：plant_b1 换亮叶变体（绿色植物焦点之二，分布中央通道）
	"plant_bright_b1": Vector2i(243, 33),
	"plant_b2": Vector2i(301, 31),
	"mat_rolled_b1": Vector2i(339, 33),
	# 左侧 walkway 长椅（x 0..32 通道，避开 bench_press (1,7)(2,7) 与 bike(2,5)）
	"bench_b3": Vector2i(17, 187),
	# 前景：大植物（V3 §4 FOREGROUND，可轻微遮挡）—— 位置须落在 UI 建造条带
	# 之上（world y ≤ 277，屏幕 y ≤ 624；实测 y≥292 会被 96px 条带盖住）。
	# V3.1 P5：plant_fore_1 换亮叶变体（绿色植物焦点之三，分布前景左下）
	# R3：前景植物成对错落（fore_4 压 fore_1 右下角 —— 前后交错）
	"plant_bright_fore_1": Vector2i(0, 244),
	"plant_fore_2": Vector2i(385, 243),
	# V3 §15（P0-4 纵深）：前景遮挡增强 —— 底部通道/设备前多两棵大植物，
	# 真实压住 GAMEPLAY 层（纵深三层的"前景"层更明显）。y 控制在 277 之上
	# （底部通道 y 288..320 会被 88px 建造条带盖住，放 y≈250 保证可见）。
	"plant_fore_3": Vector2i(225, 243),
	"plant_fore_4": Vector2i(1, 251),
	"plant_fore_5": Vector2i(383, 253),
}

## 顶墙挂饰（海报/计时器/招牌/电视）：prop_id -> 墙上锚点（24px 精灵，贴墙）。
const WALL_DECOR := {
	"poster_run": Vector2i(140, 1),
	"poster_yoga": Vector2i(260, 1),
	"timer_bike": Vector2i(52, 1),
	"sign_entrance": Vector2i(36, 1),
	"tv": Vector2i(320, 1),
	# V3.1 R4/R5 精修：红色促销横幅占据顶墙中部，成为墙面主焦点。
	"ad_red": Vector2i(164, 1),
}

# === V3 §6 / V3.1 R4 灯光锚点 ===
## 吊灯完整投光规格（单一来源）：结构物件 rect、悬挂高度、纹理内灯泡位置与
## 地面落点必须成套出现。LightingLayer 用同一数据把高处灯泡连到地面落点，
## WorldCanvas 用同一 height 绘制灯具，避免上一版「灯在墙顶、锥在地板」的
## 屏幕空间断裂。rect 与 StructureArt.STRUCTURES 中对应条目由测试交叉验证。
const HANGING_LIGHTS := [
	{
		"id": "hanging_lamp_1", "rect": Rect2i(72, 0, 28, 36),
		"height": 78.0, "bulb_local": Vector2(14, 29),
		"landing": Vector2(86, 170), "pool_half": Vector2(44, 30),
	},
	{
		"id": "hanging_lamp_2", "rect": Rect2i(188, 0, 28, 36),
		"height": 78.0, "bulb_local": Vector2(14, 29),
		"landing": Vector2(202, 170), "pool_half": Vector2(44, 30),
	},
	{
		"id": "hanging_lamp_3", "rect": Rect2i(348, 0, 28, 36),
		"height": 78.0, "bulb_local": Vector2(14, 29),
		"landing": Vector2(362, 170), "pool_half": Vector2(44, 30),
	},
]

## 瑜伽区落地灯：base 是灯脚触地点；灯体由 WorldCanvas 作为竖直 billboard
## 绘制，bulb_local 是相对灯体顶点的灯泡像素位置。短斜投光落到东南侧地面，
## 使「灯罩亮 → 地面暖」而非原先孤立橙块。
const FLOOR_LIGHT := {
	"decor_id": "warm_lamp_f1",
	"base": Vector2(312, 228),
	"height": 48.0,
	"bulb_local": Vector2(0, 13),
	"landing": Vector2(330, 242),
	"pool_half": Vector2(24, 17),
}

## 顶部主光池（3 个：力量/有氧/瑜伽区中心）：与 HANGING_LIGHTS.landing
## 保持一致，兼容既有测试/证据读取。
const LIGHT_POOLS := [
	Vector2(86, 170),
	Vector2(202, 170),
	Vector2(362, 170),
]
## 灯光池半径。
const LIGHT_POOL_RADIUS := 46.0
## 墙边冷暗带（四周，宽度 26px）：比 R4 更明确地切开中心暖光。
const EDGE_SHADOW_WIDTH := 26

## 判断世界坐标是否在墙边暗角带内（距离墙 ≤ EDGE_SHADOW_WIDTH）。
static func in_edge_shadow(pos: Vector2) -> bool:
	return pos.x <= EDGE_SHADOW_WIDTH or pos.y <= EDGE_SHADOW_WIDTH \
		or pos.x >= WORLD_W - EDGE_SHADOW_WIDTH or pos.y >= WORLD_H - EDGE_SHADOW_WIDTH


## 窗口斜向自然光：从窗口底部射向地板的光锥多边形。
## 返回 PackedVector2Array（世界像素空间）；窗口矩形来自 WINDOWS。
static func window_light_cone(window_rect: Rect2i) -> PackedVector2Array:
	var bottom := window_rect.position.y + window_rect.size.y
	var spread := 44
	var depth := 88
	return PackedVector2Array([
		Vector2(window_rect.position.x, bottom),
		Vector2(window_rect.position.x + window_rect.size.x, bottom),
		Vector2(window_rect.position.x + window_rect.size.x + spread, bottom + depth),
		Vector2(window_rect.position.x - spread, bottom + depth),
	])
