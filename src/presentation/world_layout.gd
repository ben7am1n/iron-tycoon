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
	# 瑜伽区：植物、小音箱、卷起的备用瑜伽垫（V3 §12；flex 区空闲格）
	"plant_f1": Vector2i(352, 176),
	"speaker_f1": Vector2i(336, 96),
	"mat_rolled_f1": Vector2i(348, 268),
	# 自行车区：风扇、水杯架（V3 §12；bike(2,5) 左侧 walkway）
	"fan_b1": Vector2i(24, 160),
	"cup_holder_b1": Vector2i(24, 180),
	# 公共空间：饮水机（V3 §3）、垃圾桶、消防栓
	"fountain": Vector2i(20, 40),
	"trash": Vector2i(386, 30),
	"hydrant": Vector2i(12, 120),
	# 前景：大植物（V3 §4 FOREGROUND，可轻微遮挡）—— 位置须落在 UI 建造条带
	# 之上（world y ≤ 277，屏幕 y ≤ 624；实测 y≥292 会被 96px 条带盖住）。
	"plant_fore_1": Vector2i(0, 244),
	"plant_fore_2": Vector2i(384, 244),
}

## 顶墙挂饰（海报/计时器/招牌/电视）：prop_id -> 墙上锚点（24px 精灵，贴墙）。
const WALL_DECOR := {
	"poster_run": Vector2i(168, 1),
	"poster_yoga": Vector2i(220, 1),
	"timer_bike": Vector2i(52, 1),
	"sign_entrance": Vector2i(36, 1),
	"tv": Vector2i(320, 1),
}

# === V3 §6 灯光锚点 ===
## 顶部主光池（3 个：力量/有氧/瑜伽区中心）：中心点（世界像素空间）。
const LIGHT_POOLS := [
	Vector2(96, 160),
	Vector2(224, 160),
	Vector2(336, 160),
]
## 灯光池半径。
const LIGHT_POOL_RADIUS := 64.0
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
