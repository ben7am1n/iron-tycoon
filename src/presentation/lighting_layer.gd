# src/presentation/lighting_layer.gd — Phase 5 方向光与氛围层（V3 §6）
#
# V3 §6（器械和人物有明显方向光）：统一室内主光顶部暖白；阴影偏冷偏蓝灰；
# 墙边比中心区域稍暗；窗口附近斜向自然光；设备屏幕/饮水机/招牌局部辉光。
# IMPORTANT：不做真实 3D PBR 灯光，最终仍必须像 pixel art —— 本层全部用
# 确定性、低 alpha 的半透明像素块（draw_rect / draw_colored_polygon）在
# 世界像素空间叠加，视觉是「体积氛围」，不是 Unity 光照。
#
# 层级：本节点是 WorldRoot 的子节点（z_index=1，画在 WorldCanvas 之上，
# 但仍在同一低分辨率 pixel space，经 WorldRoot scale 0.75 进 SubViewport）。
# 叠加在成员/设备之上：暖光池让画面偏暖，墙边暗角让边缘偏冷 —— 氛围
# 效果，不遮挡信息（alpha ≤ 0.16）。
#
# 确定性：所有发光/闪烁都由 tick（注入的 tick_provider）驱动 —— headless
# 测试可断言（同 tick 同输出），渲染也稳定。闪烁用 sin(tick) 相位，缓慢
# 呼吸而非刺眼闪烁（art-bible §9 无闪烁）。
#
# headless 可靠性：跨脚本引用一律 preload alias（项目约定）；grid / resolver
# 鸭子类型注入（presentation seam 约定）。
class_name LightingLayer extends Node2D

const Palette := preload("res://src/palette.gd")
const WorldLayout := preload("res://src/presentation/world_layout.gd")
const WorldScale := preload("res://src/presentation/world_scale.gd")
const Proj2D := preload("res://src/presentation/oblique_projection.gd")

## 发光体类型（emissive 载体，V3 §6）：设备屏幕青蓝/绿 + 饮水机/招牌。
const GLOW_CYAN := "cyan"
const GLOW_GREEN := "green"
const GLOW_WARM := "warm"

var _grid = null        # GridStateReader（placed instances）
var _resolver: Callable = Callable()   # instance_id -> equipment_id
var _tick_provider: Callable = Callable()  # -> int（闪烁相位）

## 发光体配置：equipment_id -> 发光类型 + 屏幕位置偏移（世界 px，相对 footprint 左上）。
const EQUIPMENT_GLOWS := {
	"treadmill": {"type": GLOW_CYAN, "offset": Vector2(12, 4)},
	"bike": {"type": GLOW_GREEN, "offset": Vector2(6, 8)},
}

var _initialized: bool = false


## 两阶段 init（ADR-0001 形态）：注入 grid / resolver / tick_provider。
func init(grid, resolver: Callable, tick_provider: Callable) -> void:
	if _initialized:
		push_error("LightingLayer.init(): called twice")
		return
	_initialized = true
	_grid = grid
	_resolver = resolver
	_tick_provider = tick_provider


# === 渲染（世界像素空间；headless 下引擎不调用 _draw，防御性检查） ===
# V3.1 P1：光照是贴地氛围（光池/暗角/光锥/辉光都在地面上）—— 全部经
# floor_transform 投影（光池随地板压缩成椭圆、暗角沿地板边缘）。

func _draw() -> void:
	draw_set_transform_matrix(Proj2D.floor_transform())
	_draw_edge_shadows()
	_draw_light_pools()
	_draw_window_light()
	_draw_emissive_glows()
	draw_set_transform_matrix(Transform2D.IDENTITY)


## 墙边暗角（V3 §6）：四周冷蓝灰半透明带 —— 墙边比中心区域稍暗。
func _draw_edge_shadows() -> void:
	var w := WorldLayout.WORLD_W
	var h := WorldLayout.WORLD_H
	var edge := WorldLayout.EDGE_SHADOW_WIDTH
	# 上
	draw_rect(Rect2i(0, 0, w, edge), Palette.LIGHT_EDGE_SHADOW, true)
	# 下
	draw_rect(Rect2i(0, h - edge, w, edge), Palette.LIGHT_EDGE_SHADOW, true)
	# 左
	draw_rect(Rect2i(0, edge, edge, h - edge * 2), Palette.LIGHT_EDGE_SHADOW, true)
	# 右
	draw_rect(Rect2i(w - edge, edge, edge, h - edge * 2), Palette.LIGHT_EDGE_SHADOW, true)
	# 角落再压一层（空间纵深，V3 §4/§6）
	for corner in [Vector2i(0, 0), Vector2i(w - edge, 0), Vector2i(0, h - edge), Vector2i(w - edge, h - edge)]:
		draw_rect(Rect2i(corner, Vector2i(edge, edge)), Palette.LIGHT_CORNER_SHADOW, true)


## 顶部暖白主光（V3 §6）：3 盏吊灯的光锥 + 地面光斑 —— 光池「可归属来源」
## （P0-4：不再是无来源的透明圆形蒙版）。灯位 = WorldLayout.LAMP_CONES
## （从灯罩底部到地面的四边形，与 FOREGROUND 吊灯结构对齐）。
func _draw_light_pools() -> void:
	for i in WorldLayout.LAMP_CONES.size():
		var pts := PackedVector2Array()
		for p: Vector2 in WorldLayout.LAMP_CONES[i]:
			pts.append(p)
		var c := Palette.LIGHT_TOP_WARM
		c.a = 0.05
		draw_colored_polygon(pts, c)
		# 光斑：灯正下方地面亮池（中心 = 光锥底部中点），暖白，略强于光锥
		var center: Vector2 = WorldLayout.LIGHT_POOLS[i]
		var pool := Palette.LIGHT_TOP_WARM
		pool.a = 0.10
		draw_circle(center, WorldLayout.LIGHT_POOL_RADIUS, pool)
		var inner := Palette.LIGHT_TOP_WARM
		inner.a = 0.16
		draw_circle(center, WorldLayout.LIGHT_POOL_RADIUS * 0.5, inner)


## 窗口斜向自然光（V3 §6）：每扇窗一个暖白光锥，从窗底射向地板。
func _draw_window_light() -> void:
	for window_rect in WorldLayout.WINDOWS:
		var cone := WorldLayout.window_light_cone(window_rect)
		draw_colored_polygon(cone, Palette.LIGHT_WINDOW)


## 设备屏幕 / 饮水机 / 招牌局部辉光（V3 §6）：青蓝/绿低 alpha 呼吸光。
## 闪烁 = sin(tick) 相位 —— 缓慢呼吸（art-bible §9 无快速闪烁）。
func _draw_emissive_glows() -> void:
	var tick: int = 0
	if _tick_provider.is_valid():
		tick = _tick_provider.call()
	var phase := 0.5 + 0.5 * sin(tick * 0.25)
	# 设备屏幕（已放置的 treadmill / bike）
	if _grid != null:
		for inst in _grid.get_placed_instances():
			var eq_id := ""
			if _resolver.is_valid():
				eq_id = str(_resolver.call(inst.instance_id))
			if not EQUIPMENT_GLOWS.has(eq_id):
				continue
			var cfg: Dictionary = EQUIPMENT_GLOWS[eq_id]
			var fp := _footprint_rect(inst.footprint_cells)
			var glow_pos: Vector2 = Vector2(fp.position) + (cfg["offset"] as Vector2)
			_draw_glow(glow_pos, cfg["type"] as String, phase)
	# 饮水机 / 招牌（V3 §6 饮水机/售货机/招牌少量局部辉光）
	var fountain_pos: Vector2i = WorldLayout.DECOR.get("fountain", Vector2i(-100, -100))
	if fountain_pos.x >= 0:
		_draw_glow(fountain_pos + Vector2i(12, 16), GLOW_CYAN, phase)
	var sign_pos: Vector2i = WorldLayout.WALL_DECOR.get("sign_entrance", Vector2i(-100, -100))
	if sign_pos.x >= 0:
		_draw_glow(sign_pos + Vector2i(8, 8), GLOW_WARM, phase)


## 单个辉光：中心亮点 + 低 alpha 外圈（2 层，克制）。
func _draw_glow(pos: Vector2, glow_type: String, phase: float) -> void:
	var core := _glow_color(glow_type)
	core.a = 0.35 + 0.25 * phase
	draw_circle(pos, 5.0, core)
	var halo := _glow_color(glow_type)
	halo.a = 0.12 + 0.08 * phase
	draw_circle(pos, 11.0, halo)


## 发光类型 → 基色（V3 §7：青蓝/绿 emissive；招牌暖黄）。
func _glow_color(glow_type: String) -> Color:
	match glow_type:
		GLOW_CYAN:
			return Palette.EMISSIVE_CYAN
		GLOW_GREEN:
			return Palette.EMISSIVE_GREEN
		GLOW_WARM:
			return Palette.ACCENT_YELLOW
		_:
			return Palette.EMISSIVE_CYAN


## footprint 单元格集合 → 像素 Rect2i（min cell × CELL_SIZE）。
func _footprint_rect(cells: Array) -> Rect2i:
	if cells.is_empty():
		return Rect2i()
	var min_c := Vector2i(cells[0])
	var max_c := Vector2i(cells[0])
	for c in cells:
		min_c.x = min(min_c.x, c.x)
		min_c.y = min(min_c.y, c.y)
		max_c.x = max(max_c.x, c.x)
		max_c.y = max(max_c.y, c.y)
	var cell := 32
	var size := (max_c - min_c + Vector2i.ONE) * cell
	return Rect2i(min_c * cell, size)
