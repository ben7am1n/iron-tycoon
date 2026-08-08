## src/presentation/world_canvas.gd — 低分辨率世界渲染画布（V3 §2 管线核心）
##
## V3 visual remaster Phase 1：WORLD 层统一 pixel space。本节点是 SubViewport
## 内的世界绘制画布，替代旧 main.gd 的 1280×720 高清 draw_rect 世界路径。
## 所有绘制都在「世界像素空间」（CELL_SIZE=32，13×10 → 416×320）进行，由
## main.gd 的 WorldRoot（scale 0.75）换算到 SubViewport（426×240），再经
## TextureRect nearest 放大到窗口 —— 世界元素（地板/网格/设备/会员/幽灵）全部
## 属于同一个低分辨率 pixel space（V3 §2：WORLD 统一低分辨率，UI 高分辨率）。
##
## 绘制顺序（2.5D 空间层级，art-bible-25d §1）：地板 → 网格线 → 会员中景 →
## 设备前景 → 放置幽灵（活动决策预览，Core Rule 7 优先级最高）。
##
## GRID 可见性（V3 §14 可读性）：正常经营模式完全隐藏 tile grid；仅 placement
## mode（PlacementSystem.is_dragging()）显示。默认隐藏；_process 轮询
## is_dragging()（O(1) 状态读，与 CongestionOverlayController._poll_drag_state
## 同一模式），拖拽开始/结束切换可见性并 queue_redraw。
##
## 本节点不持有玩法状态：instance_id→equipment_id 经 resolver Callable 读取
## （数据源仍由 main.gd 的 _instance_defs 维护，MemberSim 同源）；会员朝向缓存
## （_member_facing/_member_last_cell）是 presentation 层状态（纯绘制用）。
##
## headless 可靠性：class_name 仅作编辑器便利，跨脚本引用一律 preload alias
## （项目约定，见 src/main.gd 头部注释）；tick 经 tick_provider Callable 注入，
## 不直接依赖 orchestrator 类型。
class_name WorldCanvas extends Node2D

const Palette := preload("res://src/palette.gd")
const WorldScale := preload("res://src/presentation/world_scale.gd")

## 默认网格可见性（V3 §14）：正常经营模式完全隐藏 grid。
const DEFAULT_GRID_VISIBLE := false

## Hover 上移量（世界 px）：V3 §14「hover 黄色像素轮廓 + 轻微上移」。
## 精灵本体向上偏移 2 世界 px（≈1.5 viewport px，nearest 放大后 ~4.5 屏 px），
## contact shadow 留在原地 —— 视觉上设备「轻轻抬起」。
const HOVER_LIFT_PX := 2.0

# === 注入依赖（ADR-0001 两阶段 init 形态） ===
var _grid = null              # GridStateReader：placed instances / conversions
var _catalog = null           # EquipmentCatalog：equipment_id → def（zone/语义色）
var _member = null            # MemberSim：members 数组（位置/状态）
var _member_sprites = null    # MemberSprite：2.5D 像素小人纹理工厂
var _equip_art = null         # EquipmentArt：设备像素精灵纹理工厂
var _placement = null         # PlacementSystem：is_dragging / 幽灵数据
var _arbitration = null       # ModeArbitration：is_ghost_suppressed（Core Rule 4）
var _resolver: Callable = Callable()      # instance_id -> equipment_id
var _tick_provider: Callable = Callable() # -> int（会员动画 tick）
var _cell_size: int = 32

## V3 §14 hover：当前被鼠标悬停的设备 instance_id（-1 = 无）。
## presentation 层状态（纯绘制用），由 _hover_provider 轮询维护 —— 与
## _poll_placement_mode 同一模式（O(1) 状态读，headless 测试直接驱动 setter）。
var _hovered_instance_id: int = -1
## hover 数据源：返回当前悬停的 instance_id（-1 = 无）。由 main.gd 注入
## （根 viewport 鼠标 → _screen_to_world → grid.world_to_grid → occupant）。
var _hover_provider: Callable = Callable()

## 当前网格可见性（V3 §14）。默认 false；仅 placement mode 为 true。
var _grid_visible: bool = DEFAULT_GRID_VISIBLE

## Phase C v2：会员朝向（presentation 层状态，非玩法逻辑 —— 由 cell 移动
## 推断 facing，纯绘制用）。member_id -> bool（true = 朝左）。
var _member_facing: Dictionary = {}
var _member_last_cell: Dictionary = {}

var _initialized: bool = false


## 两阶段 init：注入世界绘制依赖并订阅重绘信号（grid_changed S1 /
## tick_completed S2 / preview_validity_changed —— 与旧 main.gd 的 BUILD-03/04
## 信号驱动重绘约定一致；queue_redraw 幂等合并，headless 下调用无害）。
## [resolver] instance_id -> equipment_id；[tick_provider] -> int（动画 tick）。
func init(
	grid,
	catalog,
	member,
	member_sprites,
	equip_art,
	placement,
	arbitration,
	resolver: Callable,
	tick_provider: Callable,
	cell_size: int
) -> void:
	if _initialized:
		push_error("WorldCanvas.init(): called twice")
		return
	_initialized = true
	# V3 §2 低分辨率世界统一 pixel space：WorldRoot scale 0.75 下设备纹理
	# （Phase 3 16×16 art，ART_SCALE=2 → 每 art px = 1.5 viewport px，非整数）
	# 必须 NEAREST 采样 —— 否则线性过滤在 art px 边界混色（旧 8×8 art 恰好
	# 3 viewport px/art px 整数对齐，掩盖了此问题）。证据脚本 stair-step
	# 断言依赖此硬边（无 bilinear blend）。
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_grid = grid
	_catalog = catalog
	_member = member
	_member_sprites = member_sprites
	_equip_art = equip_art
	_placement = placement
	_arbitration = arbitration
	_resolver = resolver
	_tick_provider = tick_provider
	_cell_size = maxi(cell_size, 1)
	_grid_visible = DEFAULT_GRID_VISIBLE

	# 信号驱动重绘（typed connections only，Control Manifest Presentation 规则）：
	#   - grid_changed（place=commit / remove=sell）→ 设备上屏/下屏
	# tick_completed（S2，10Hz → 会员移动）与 preview_validity_changed（幽灵
	# tint）由 composition root（main.gd）接向 _on_world_changed —— 这两个信号
	# 分别挂在 orchestrator / placement 上，不在此处强依赖类型。
	if _grid != null and not _grid.grid_changed.is_connected(_on_world_changed):
		_grid.grid_changed.connect(_on_world_changed)


## S1/S2/preview 统一重绘入口。queue_redraw() 幂等合并（一帧内多次调用只重绘
## 一次），headless 下不渲染、调用无害（同旧 main.gd 约定）。
func _on_world_changed(_a = null, _b = null, _c = null, _d = null) -> void:
	if not _initialized:
		return
	queue_redraw()


## 轮询 placement mode（V3 §14）：placement drag 进行中 → 显示 grid，否则隐藏。
## 与 CongestionOverlayController._poll_drag_state 同一模式（O(1) 状态读，无
## 预览/寻路工作 —— 不违反 TR-PS-012）。headless 测试直接驱动本方法。
func _process(_delta: float) -> void:
	_poll_placement_mode()
	_poll_hover()


## 轮询 hover 状态（V3 §14）：_hover_provider 返回当前悬停 instance_id，
## 边沿变化 → queue_redraw。幂等 —— 状态未变时零开销。O(1) 状态读。
func _poll_hover() -> void:
	if not _initialized or not _hover_provider.is_valid():
		return
	var id := int(_hover_provider.call())
	if id == _hovered_instance_id:
		return
	_hovered_instance_id = id
	queue_redraw()


## 注入 hover 数据源（composition root 调用；headless 测试可注入 Fake）。
func set_hover_provider(provider: Callable) -> void:
	_hover_provider = provider


## 查询：当前悬停的设备 instance_id（-1 = 无）。测试/调试入口。
func get_hovered_instance_id() -> int:
	return _hovered_instance_id


## 显式设置 hover（测试/调试入口；正常流程由 _poll_hover 驱动）。
func set_hovered_instance_id(id: int) -> void:
	if _hovered_instance_id == id:
		return
	_hovered_instance_id = id
	queue_redraw()


## Placement-mode 轮询体：is_dragging() 边沿 → 切换网格可见性并重绘。幂等 ——
## 状态未变时零开销。
func _poll_placement_mode() -> void:
	if not _initialized or _placement == null:
		return
	var dragging: bool = _placement.is_dragging()
	if dragging == _grid_visible:
		return
	_grid_visible = dragging
	queue_redraw()


## 查询：当前网格是否可见（V3 §14 —— 正常经营模式完全隐藏）。
func is_grid_visible() -> bool:
	return _grid_visible


## 显式设置网格可见性（测试/调试入口）。正常流程由 _poll_placement_mode 驱动。
func set_grid_visible(visible: bool) -> void:
	if _grid_visible == visible:
		return
	_grid_visible = visible
	queue_redraw()


# === 渲染（世界像素空间；headless 下引擎不调用 _draw，防御性 null 检查） ===

func _draw() -> void:
	if _grid == null:
		return
	_draw_floor_zones()
	if _grid_visible:
		_draw_grid_lines()
	# 2.5D 空间层级（art-bible-25d §1）：会员中景 / 设备前景 —— 设备画在会员
	# 之后（前景层），幽灵画在最上（活动决策预览，Core Rule 7 优先级最高）。
	_draw_members()
	_draw_equipment()
	_draw_placement_ghost()


## 地板三区域色块（art-bible §6：功能区用色块 + 柔和描边区分，分区一眼可读）。
## 数据源：palette.gd ZONE_RECTS / ZONE_COLORS（单一来源）。画在最底层（先于
## 网格线/设备/会员），不遮挡任何上层元素。V3 后续 Phase（环境材质）将替换为
## 分区地面材质；本 Phase 只做低分辨率管线迁移，色块语义不变。
## 描边宽度乘 STROKE_COMPENSATION：WorldRoot scale 0.75 下 1px 描边会消失
## （4.7.1 pitfall，见 world_scale.gd）。
func _draw_floor_zones() -> void:
	for zone: String in Palette.ZONE_RECTS:
		var rect: Rect2i = Palette.ZONE_RECTS[zone]
		var px_rect := Rect2i(rect.position * _cell_size, rect.size * _cell_size)
		draw_rect(px_rect, Palette.ZONE_COLORS[zone], true)
		draw_rect(px_rect, Palette.ZONE_BORDER, false, 1.0 * WorldScale.STROKE_COMPENSATION)


## 网格线（V3 §14：仅 placement mode 显示，正常经营模式完全隐藏）。
## 尺寸来自 GridStateReader.get_dimensions()（架构 pinned，不硬编码）。
## 线宽 1.0 × STROKE_COMPENSATION = 1.0 viewport px（world_scale.gd pitfall）。
func _draw_grid_lines() -> void:
	var dims: Vector2i = _grid.get_dimensions()
	for x in dims.x + 1:
		draw_line(Vector2(x * _cell_size, 0), Vector2(x * _cell_size, dims.y * _cell_size),
			Palette.GRID_LINE, 1.0 * WorldScale.STROKE_COMPENSATION)
	for y in dims.y + 1:
		draw_line(Vector2(0, y * _cell_size), Vector2(dims.x * _cell_size, y * _cell_size),
			Palette.GRID_LINE, 1.0 * WorldScale.STROKE_COMPENSATION)


## 设备渲染（V3 Phase 3）—— 前景小型场景物件（§5，非图标）。
##   1. 脚下柔和 contact shadow（§6：设备下方明显但柔和的 contact shadow）：
##      双层半透明冷蓝灰块（宽软外层 + 贴身内层），替代旧单层大暗面
##   2. 像素精灵纹理（EquipmentArt 程序化 ImageTexture，32×32/cell，Nearest 全局）
##   3. Hover（§14）：黄色像素轮廓（EQUIP_HOVER_OUTLINE）+ 精灵轻微上移
##      （HOVER_LIFT_PX，contact shadow 留原地 —— 设备「抬起」感）
##   4. access cell 用 Butter 高亮（art-bible §7 拖放反馈；§4 Butter 锚点 ~10%）
func _draw_equipment() -> void:
	if _grid == null or _equip_art == null:
		return
	for inst in _grid.get_placed_instances():
		var fp_rect := _footprint_rect(inst.footprint_cells)
		if fp_rect.size.x <= 0 or fp_rect.size.y <= 0:
			continue
		var is_hovered: bool = inst.instance_id == _hovered_instance_id
		# V3 §6 contact shadow：宽软外层（柔和，扩散感）+ 贴身内层（明显接触）。
		var soft_rect := fp_rect.grow(5)
		soft_rect.position.y += 3
		var soft := Palette.EQUIP_SHADOW
		soft.a = 0.22
		draw_rect(soft_rect, soft, true)
		var core_rect := fp_rect.grow(2)
		core_rect.position.y += 2
		var core := Palette.EQUIP_SHADOW
		core.a = 0.40
		draw_rect(core_rect, core, true)

		var eq_id := ""
		if _resolver.is_valid():
			eq_id = str(_resolver.call(inst.instance_id))
		var zone: String = _zone_of(eq_id)
		var tex: ImageTexture = _equip_art.texture_for(eq_id, zone, inst.rotation)
		if tex != null:
			var draw_rect := Rect2(fp_rect)
			if is_hovered:
				# V3 §14 轻微上移：精灵本体向上抬 HOVER_LIFT_PX，contact shadow
				# 留在原地 —— 设备「抬起」。
				draw_rect.position.y -= HOVER_LIFT_PX
			draw_texture_rect(tex, draw_rect, false)
		else:
			# 兜底（未知 equipment_id）：画 Soft Charcoal 剪影块，绝不崩溃。
			draw_rect(fp_rect, Palette.CHARCOAL, false, 2.0 * WorldScale.STROKE_COMPENSATION)

		if is_hovered:
			# V3 §14 hover 黄色像素轮廓（BUTTER）：围绕 footprint 的像素描边。
			# 描边宽度乘 STROKE_COMPENSATION：WorldRoot scale 0.75 下 1px 会消失
			# （4.7.1 pitfall，见 world_scale.gd）。
			var hover := Palette.EQUIP_HOVER_OUTLINE
			hover.a = 0.95
			draw_rect(fp_rect.grow(2), hover, false, 2.0 * WorldScale.STROKE_COMPENSATION)

		for c in inst.access_cells:
			_draw_access_cell(c)


## access cell 高亮：半透明 Butter 填充 + Butter 描边 + 中央实心 Butter 菱形
## （图标+颜色双通道的色盲安全形状；柔和，不刺眼，无闪烁 —— art-bible §7）。
func _draw_access_cell(c: Vector2i) -> void:
	var rect := Rect2i(c * _cell_size, Vector2i(_cell_size, _cell_size))
	var fill := Palette.BUTTER
	fill.a = 0.25
	draw_rect(rect, fill, true)
	var border := Palette.BUTTER
	border.a = 0.85
	draw_rect(rect, border, false, 1.0 * WorldScale.STROKE_COMPENSATION)
	var diamond := Palette.BUTTER
	diamond.a = 0.95
	var cx := rect.position.x + _cell_size / 2.0
	var cy := rect.position.y + _cell_size / 2.0
	var r := 5.0
	var pts := PackedVector2Array([
		Vector2(cx, cy - r),
		Vector2(cx + r, cy),
		Vector2(cx, cy + r),
		Vector2(cx - r, cy),
	])
	draw_colored_polygon(pts, diamond)


## 放置预览幽灵（art-bible §7 拖放反馈）：合法 → 柔和高亮 + Butter 网格吸附
## 描边；非法 → Dusty Rose 柔和警示。画在最上（活动决策预览，Core Rule 7）；
## 无 drag 时无开销（is_dragging O(1)）。
func _draw_placement_ghost() -> void:
	if _placement == null:
		return
	if not _placement.is_dragging():
		return
	# 双幽灵抑制（GDD Core Rule 4 / ModeArbitration）：有选中物时不画新放置幽灵。
	if _arbitration != null and _arbitration.is_ghost_suppressed():
		return
	if not _placement.get_drag_has_previewed():
		return  # 尚未进入任何格 —— 不画 ZERO 幽灵
	var eq_id: String = _placement.get_drag_equipment_id()
	if eq_id == "":
		return
	var def = _catalog.get_definition(eq_id)
	if def == null:
		return
	var anchor: Vector2i = _placement.get_drag_anchor()
	var rotation: int = _placement.get_drag_rotation()
	var tf = _grid.get_transformed_cells(def.footprint_cells, def.access_cells, anchor, rotation)
	var rect := _cells_rect(tf.footprint_cells)
	if rect.size.x <= 0 or rect.size.y <= 0:
		return
	var valid: bool = _placement.get_drag_preview_valid()
	var tint: Color = Palette.PLACEMENT_OK_TINT if valid else Palette.PLACEMENT_BAD_TINT
	draw_rect(rect, tint, true)
	# 精灵本体（半透明幽灵，让玩家看清要放什么）——先于描边，描边永远可读。
	var zone: String = _zone_of(eq_id)
	var tex: ImageTexture = _equip_art.texture_for(eq_id, zone, rotation)
	if tex != null:
		var ghost_col := Color(1, 1, 1, 0.65)
		draw_texture_rect(tex, Rect2(rect), false, ghost_col)
	# 网格吸附描边（画在最上，覆盖幽灵本体）：合法 → Butter；非法 → Dusty Rose。
	var edge: Color = Palette.BUTTER if valid else Palette.ROSE
	edge.a = 0.9
	draw_rect(rect, edge, false, 2.0 * WorldScale.STROKE_COMPENSATION)
	for c in tf.access_cells:
		_draw_access_cell(c)


## 会员渲染（Phase C v2）：2.5D 像素小人（32×32，1:1 绘制，状态双通道）。
func _draw_members() -> void:
	if _member == null or _member_sprites == null:
		return
	var tick: int = 0
	if _tick_provider.is_valid():
		tick = _tick_provider.call()
	var alive: Dictionary = {}
	for m in _member.members:
		if not (m is Dictionary) or not m.has("cell") or not m.has("state"):
			continue
		var member_id := int(m.get("member_id", -1))
		if member_id >= 0:
			alive[member_id] = true
		var state := str(m["state"])
		if _member_sprites.state_channel(state) == "":
			continue  # GONE / 被动成员 —— 不渲染
		var cell: Vector2i = m["cell"]
		var facing_left := _update_facing(member_id, cell)
		var tex: ImageTexture = _member_sprites.texture_for(state, tick, facing_left)
		draw_texture(tex, Vector2(cell.x * _cell_size, cell.y * _cell_size))
	# 清理已离场成员的朝向缓存（防止字典无限增长）
	for member_id in _member_facing.keys():
		if not alive.has(member_id):
			_member_facing.erase(member_id)
			_member_last_cell.erase(member_id)


## 由 cell 移动推断朝向（presentation 层，纯绘制用；横向位移为 0 时保持上次
## 朝向 —— QUEUEING/USING 成员静止，姿态已表达状态，朝向仅跟随入场方向）。
func _update_facing(member_id: int, cell: Vector2i) -> bool:
	var facing_left := bool(_member_facing.get(member_id, false))
	if _member_last_cell.has(member_id):
		var prev: Vector2i = _member_last_cell[member_id]
		if cell.x < prev.x:
			facing_left = true
		elif cell.x > prev.x:
			facing_left = false
	_member_last_cell[member_id] = cell
	_member_facing[member_id] = facing_left
	return facing_left


## footprint 单元格集合 → 像素 Rect2i（min cell × CELL_SIZE，size = bbox）。
func _footprint_rect(cells: Array) -> Rect2i:
	return _cells_rect(cells)


## 任意网格 cell 集合 → 像素 Rect2i（空集合返回零尺寸）。
func _cells_rect(cells: Array) -> Rect2i:
	if cells.is_empty():
		return Rect2i()
	var min_c := Vector2i(cells[0])
	var max_c := Vector2i(cells[0])
	for c in cells:
		min_c.x = min(min_c.x, c.x)
		min_c.y = min(min_c.y, c.y)
		max_c.x = max(max_c.x, c.x)
		max_c.y = max(max_c.y, c.y)
	var size := (max_c - min_c + Vector2i.ONE) * _cell_size
	return Rect2i(min_c * _cell_size, size)


## equipment_id → zone_membership[0]（语义色键，与 palette.ZONE_COLORS 对齐）。
## 未知 id 返回 ""（EquipmentArt 兜底 FALLBACK_ZONE）。
func _zone_of(eq_id: String) -> String:
	if eq_id == "" or _catalog == null:
		return ""
	var def = _catalog.get_definition(eq_id)
	if def == null or def.zone_membership.is_empty():
		return ""
	return str(def.zone_membership[0])
