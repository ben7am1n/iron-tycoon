# src/presentation/ambient_fx.gd — Phase 5 微型动态元素层（V3 §9）
#
# V3 §9（微型动态元素，画面不能静止，但要克制不搞全屏粒子）：
#   - 窗户光尘（少量暖白小点缓慢漂移）
#   - 角色汗滴（USING 状态会员头顶偶尔出现 1px 小点）
#   - 跑步机传送带动画（跑带区域滚动暗纹）
#   - 自行车飞轮转动（飞轮中心旋转辐条）
#   - 水杯闪光（杯沿亮点周期性闪烁）
# 另：设备显示灯闪烁在 lighting_layer（emissive 呼吸光）；植物轻微摆动与
# 电视画面变化由 WorldCanvas 环境绘制负责（见 world_canvas.gd 注释）。
#
# 层级：本节点是 WorldRoot 的子节点（z_index=2，画在 LightingLayer 之上，
# 全部世界元素之上）。动态元素是「空气感」点缀，alpha 低、体量小，不遮挡
# 信息（V3 §14 可读性）。
#
# 确定性：所有位置/相位都由 tick（注入的 tick_provider）驱动，同 tick 同
# 输出 —— headless 测试可断言（同 tick 同位置），渲染稳定不闪烁。无 RNG
# 状态，无全局计时器。
#
# headless 可靠性：跨脚本引用一律 preload alias（项目约定）；member / grid /
# resolver 鸭子类型注入（presentation seam 约定）。
class_name AmbientFx extends Node2D

const Palette := preload("res://src/palette.gd")
const WorldLayout := preload("res://src/presentation/world_layout.gd")

## 光尘数量（克制：8 个，不铺满）。
const DUST_COUNT := 8
## 光尘最大漂移半径（px）。
const DUST_DRIFT := 14.0
## 传送带滚动速度（tick 步进）。
const BELT_SPEED := 2

var _member = null       # MemberSim（USING 会员 → 汗滴）
var _grid = null         # GridStateReader（placed instances → 传送带/飞轮）
var _resolver: Callable = Callable()  # instance_id -> equipment_id
var _tick_provider: Callable = Callable()  # -> int

var _initialized: bool = false


## 两阶段 init（ADR-0001 形态）：注入 member / grid / resolver / tick_provider。
func init(member, grid, resolver: Callable, tick_provider: Callable) -> void:
	if _initialized:
		push_error("AmbientFx.init(): called twice")
		return
	_initialized = true
	_member = member
	_grid = grid
	_resolver = resolver
	_tick_provider = tick_provider


# === 渲染（世界像素空间；headless 下引擎不调用 _draw） ===

func _draw() -> void:
	var tick: int = 0
	if _tick_provider.is_valid():
		tick = _tick_provider.call()
	_draw_dust(tick)
	_draw_sweat(tick)
	_draw_belt(tick)
	_draw_flywheel(tick)
	_draw_glint(tick)


## 窗户光尘：每扇窗 2-4 个暖白小点，沿窗口下方缓慢漂移（确定性相位）。
func _draw_dust(tick: int) -> void:
	var window_origins: Array[Vector2] = []
	for window_rect in WorldLayout.WINDOWS:
		var wr: Rect2i = window_rect
		window_origins.append(Vector2(
			wr.position.x + wr.size.x / 2.0,
			wr.position.y + wr.size.y + 8.0
		))
	if window_origins.is_empty():
		return
	for i in DUST_COUNT:
		var origin := window_origins[i % window_origins.size()]
		var phase := float(i) * 1.7
		var x := origin.x + sin(tick * 0.07 + phase) * DUST_DRIFT
		var y := origin.y + 20.0 + cos(tick * 0.05 + phase * 0.7) * (DUST_DRIFT * 0.6)
		var c := Palette.HIGHLIGHT_WARM
		c.a = 0.35 + 0.25 * (0.5 + 0.5 * sin(tick * 0.11 + phase))
		draw_rect(Rect2(x, y, 2, 2), c, true)


## 角色汗滴（V3 §9）：USING 会员头顶 1px 小点，周期性出现（每 3 tick 一次，
## 且按 member_id 错相 —— 确定性，不闪烁）。
func _draw_sweat(tick: int) -> void:
	if _member == null:
		return
	for m in _member.members:
		if not (m is Dictionary) or not m.has("cell") or not m.has("state"):
			continue
		if str(m["state"]) != "USING":
			continue
		var member_id := int(m.get("member_id", 0))
		var cell: Vector2i = m["cell"]
		if (tick + member_id) % 3 != 0:
			continue
		var drop := Palette.ACCENT_CYAN
		drop.a = 0.7
		var head_x := cell.x * 32 + 12 + (member_id % 5)
		var head_y := cell.y * 32 - 2
		draw_rect(Rect2(head_x, head_y, 2, 2), drop, true)


## 跑步机传送带动画（V3 §9）：跑带区域滚动暗纹（2 条，向下滚动）。
func _draw_belt(tick: int) -> void:
	if _grid == null:
		return
	for inst in _grid.get_placed_instances():
		var eq_id := ""
		if _resolver.is_valid():
			eq_id = str(_resolver.call(inst.instance_id))
		if eq_id != "treadmill":
			continue
		var fp := _footprint_rect(inst.footprint_cells)
		# 跑带区域：footprint 下半部（deck 行）
		var belt_rect := Rect2(
			fp.position.x + 6.0,
			fp.position.y + fp.size.y * 0.55,
			fp.size.x - 12.0,
			fp.size.y * 0.3
		)
		var stripe := Palette.CHARCOAL
		stripe.a = 0.30
		for i in 2:
			var y := belt_rect.position.y + float((tick * BELT_SPEED + i * 6) % int(belt_rect.size.y))
			draw_rect(Rect2(belt_rect.position.x, y, belt_rect.size.x, 2), stripe, true)


## 自行车飞轮转动（V3 §9）：飞轮中心 3 条旋转辐条（短横线）。
func _draw_flywheel(tick: int) -> void:
	if _grid == null:
		return
	for inst in _grid.get_placed_instances():
		var eq_id := ""
		if _resolver.is_valid():
			eq_id = str(_resolver.call(inst.instance_id))
		if eq_id != "bike":
			continue
		var fp := _footprint_rect(inst.footprint_cells)
		var center: Vector2 = Vector2(fp.position) + Vector2(fp.size.x / 2.0, fp.size.y * 0.45)
		var spoke := Palette.METAL_HIGHLIGHT
		spoke.a = 0.8
		for i in 3:
			var ang := tick * 0.12 + i * TAU / 3.0
			var r := 6.0
			var from: Vector2 = center + Vector2(cos(ang), sin(ang)) * (r - 2)
			var to: Vector2 = center + Vector2(cos(ang), sin(ang)) * (r + 2)
			draw_line(from, to, spoke, 2.0)


## 水杯闪光（V3 §9）：杯沿亮点周期性闪烁（确定性相位）。
func _draw_glint(tick: int) -> void:
	var cup_pos: Vector2i = WorldLayout.DECOR.get("cup_holder_b1", Vector2i(-100, -100))
	if cup_pos.x < 0:
		return
	if (tick / 3) % 4 != 0:
		return
	var glint := Palette.HIGHLIGHT_WARM
	glint.a = 0.9
	draw_rect(Rect2(cup_pos + Vector2i(6, 4), Vector2i(2, 2)), glint, true)


## footprint 单元格集合 → 像素 Rect2i（与 LightingLayer 同构，32px cell）。
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
