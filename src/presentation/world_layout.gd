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
const DECOR := {
	# 跑步机旁：水瓶、毛巾（V3 §12；treadmill(2,2) 右侧空闲格）
	"water_bottle_t1": Vector2i(132, 70),
	"towel_t1": Vector2i(132, 100),
	# 力量区：散落小配重、粉笔盒（V3 §12；bench(1,7) 右侧 strength 区）
	"dumbbell_s1": Vector2i(128, 232),
	"dumbbell_s2": Vector2i(136, 246),
	"chalk_box": Vector2i(118, 262),
	# 力量区（V3 §15 第一眼密度）：散落壶铃/配重片/药球，填满 strength 区空闲格
	"kettlebell_s1": Vector2i(36, 100),
	"kettlebell_s2": Vector2i(44, 112),
	"plate_s1": Vector2i(132, 218),
	"plate_s2": Vector2i(144, 218),
	"medicine_ball_s1": Vector2i(100, 236),
	"dumbbell_s3": Vector2i(108, 240),
	# 瑜伽区：植物、小音箱、卷起的备用瑜伽垫（V3 §12；flex 区空闲格）
	# V3.1 P5：plant_f1 换亮叶变体（绿色植物焦点之一，分布瑜伽区）
	"plant_bright_f1": Vector2i(352, 176),
	"speaker_f1": Vector2i(336, 96),
	"mat_rolled_f1": Vector2i(348, 268),
	# 瑜伽区（V3 §15 密度）：瑜伽砖 + 第二盆植物
	"yoga_block_f1": Vector2i(312, 236),
	"yoga_block_f2": Vector2i(320, 246),
	"plant_f2": Vector2i(368, 120),
	# 自行车区：风扇、水杯架（V3 §12；bike(2,5) 左侧 walkway）
	"fan_b1": Vector2i(24, 160),
	"cup_holder_b1": Vector2i(24, 180),
	# 有氧区（V3 §15 密度）：第二台 treadmill 旁毛巾/水瓶 + 中间空闲格水杯
	"towel_t2": Vector2i(200, 140),
	"water_bottle_t2": Vector2i(200, 152),
	"cup_holder_c1": Vector2i(232, 200),
	# 公共空间：饮水机（V3 §3）、垃圾桶、消防栓
	"fountain": Vector2i(20, 40),
	"trash": Vector2i(386, 30),
	"hydrant": Vector2i(12, 120),
	# V3.1 P5 高饱和焦点（附录 V3.1 P5：10-15 个高饱和视觉焦点）——
	# 新增地面焦点：黄色水杯（前台南侧 walkway）+ 彩色瑜伽用品（瑜伽区）。
	# 位置避让既有设备/装饰/access 格（水杯 (88,108) 在前台 (56..160,
	# 24..48) 之南、treadmill(2,2) footprint (64..128,64..96) 之南、水瓶
	# (132,70) 之西 —— 贴地装饰，无设备盖住；瑜伽球/瑜伽带在 flex 区左侧
	# 空闲竖条）。
	"cup_yellow_f1": Vector2i(88, 108),
	"yoga_ball_f1": Vector2i(288, 96),
	"yoga_strap_f1": Vector2i(288, 136),
	# 中央通道（walkway 环道，V3 §15 第一眼：消除空荡通道）—— 长椅/盆栽/垫子
	# 沿顶部通道：前台右侧等待长椅 + 通道盆栽（cell row 1 空闲格，避开前台
	# (56,24,104,24) 与入口门洞 x 0..32）
	"bench_b1": Vector2i(170, 32),
	"bench_b2": Vector2i(210, 32),
	# V3.1 P5：plant_b1 换亮叶变体（绿色植物焦点之二，分布中央通道）
	"plant_bright_b1": Vector2i(244, 32),
	"plant_b2": Vector2i(300, 32),
	"mat_rolled_b1": Vector2i(340, 32),
	# 左侧 walkway 长椅（x 0..32 通道，避开 bench_press (1,7)(2,7) 与 bike(2,5)）
	"bench_b3": Vector2i(16, 186),
	# 前景：大植物（V3 §4 FOREGROUND，可轻微遮挡）—— 位置须落在 UI 建造条带
	# 之上（world y ≤ 277，屏幕 y ≤ 624；实测 y≥292 会被 96px 条带盖住）。
	# V3.1 P5：plant_fore_1 换亮叶变体（绿色植物焦点之三，分布前景左下）
	"plant_bright_fore_1": Vector2i(0, 244),
	"plant_fore_2": Vector2i(384, 244),
	# V3 §15（P0-4 纵深）：前景遮挡增强 —— 底部通道/设备前多两棵大植物，
	# 真实压住 GAMEPLAY 层（纵深三层的"前景"层更明显）。y 控制在 277 之上
	# （底部通道 y 288..320 会被 88px 建造条带盖住，放 y≈250 保证可见）。
	"plant_fore_3": Vector2i(224, 244),
	"plant_fore_4": Vector2i(0, 252),
	"plant_fore_5": Vector2i(384, 252),
}

## 顶墙挂饰（海报/计时器/招牌/电视）：prop_id -> 墙上锚点（24px 精灵，贴墙）。
const WALL_DECOR := {
	"poster_run": Vector2i(168, 1),
	"poster_yoga": Vector2i(220, 1),
	"timer_bike": Vector2i(52, 1),
	"sign_entrance": Vector2i(36, 1),
	"tv": Vector2i(320, 1),
	# V3.1 P5 高饱和焦点：红色广告牌挂墙（两海报之间，x≈192 空闲墙段）。
	"ad_red": Vector2i(192, 1),
}

# === V3 §6 灯光锚点 ===
## 顶部主光池（3 个：力量/有氧/瑜伽区中心）：中心点（世界像素空间）。
## V3 §15 修复（P0-4 光照逻辑）：光池中心对齐吊灯位置（hanging_lamp_1/2/3
## 位于 structure FOREGROUND x=80/196/356，灯罩底部 y≈30）—— 光池不再是
## "透明圆形蒙版"，而是每盏吊灯照到地面的光斑（可归属来源，门禁 FAIL：
## 光池像透明圆形蒙版而非灯具逻辑照明）。
const LIGHT_POOLS := [
	Vector2(86, 170),
	Vector2(202, 170),
	Vector2(362, 170),
]
## 灯光池半径。
const LIGHT_POOL_RADIUS := 46.0
## 吊灯光锥：从灯罩底部（y≈30）斜向地面（y≈180）的四边形 —— 光池的
## "来源"可见（V3 §6 顶部暖白灯 + §4 纵深）。键 = 灯 id，值 = 光锥多边形
## （世界像素空间，由 LightingLayer 绘制）。
const LAMP_CONES := [
	[Vector2(74, 30), Vector2(98, 30), Vector2(108, 180), Vector2(64, 180)],
	[Vector2(190, 30), Vector2(214, 30), Vector2(224, 180), Vector2(180, 180)],
	[Vector2(350, 30), Vector2(374, 30), Vector2(384, 180), Vector2(340, 180)],
]
## 墙边暗角带（四周，宽度 20px）。
const EDGE_SHADOW_WIDTH := 20

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
