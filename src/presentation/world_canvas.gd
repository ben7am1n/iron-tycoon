## src/presentation/world_canvas.gd — 低分辨率世界渲染画布（V3 §2 管线核心）
##
## V3 visual remaster Phase 1：WORLD 层统一 pixel space。本节点是 SubViewport
## 内的世界绘制画布，替代旧 main.gd 的 1280×720 高清 draw_rect 世界路径。
## 所有绘制都在「世界像素空间」（CELL_SIZE=32，13×10 → 416×320）进行，由
## main.gd 的 WorldRoot（scale 0.75）换算到 SubViewport（426×240），再经
## TextureRect nearest 放大到窗口 —— 世界元素（地板/网格/设备/会员/幽灵）全部
## 属于同一个低分辨率 pixel space（V3 §2：WORLD 统一低分辨率，UI 高分辨率）。
##
## 绘制顺序（2.5D 空间层级，art-bible-25d §1 + V3 §4 三层空间 + Phase 4 双层会员）：
##   地板材质（FloorArt 烘焙贴图，V3 §1）→ 环境背景（墙/窗/海报/装饰，V3 §3/
##   §12 BACKGROUND 低对比）→ 结构层 BACKGROUND（储物柜/镜子/空调/墙钟/
##   通风口/门/踢脚线/电线槽/管道，V3 §3/§4 低对比，画在墙面上方）→ 网格线 →
##   结构层 GAMEPLAY（前台）→ 会员中景（walk/idle/tired/satisfied）→ 设备前景 →
##   使用中的会员（叠加在设备上 —— V3 §8 与设备互动姿态）→ 结构层 FOREGROUND
##   （立柱/吊灯，V3 §4 可轻微遮挡）→ 环境前景（大植物，V3 §4 FOREGROUND 可
##   轻微遮挡）→ 放置幽灵（活动决策预览优先级最高）。
## Phase 4（V3 §8）：会员是画面视觉主体 —— sprite 48×48（>cell 32），脚底
## 锚定 cell 底部、头部向上越出 cell；USING 成员锚定到设备 footprint 上
## （跑带/卧推凳/车座/垫面），叠加在设备之上（先画设备、后画使用会员）。
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
## 不直接依赖 orchestrator 类型。floor_art / env_art 为 Phase 5 可选注入
## （null 时回退到旧色块地板 / 不画环境装饰 —— 保持既有测试构造兼容）。
class_name WorldCanvas extends Node2D

const Palette := preload("res://src/palette.gd")
const WorldScale := preload("res://src/presentation/world_scale.gd")
const WorldLayout := preload("res://src/presentation/world_layout.gd")
const StructureArt := preload("res://src/presentation/structure_art.gd")
const Proj2D := preload("res://src/presentation/oblique_projection.gd")

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
var _floor_art = null         # FloorArt：V3 §1 地板材质烘焙贴图（Phase 5，可空）
var _env_art = null           # EnvironmentArt：V3 §12 环境装饰精灵工厂（Phase 5，可空）
var _structure_art = null     # StructureArt：V3 §3/§4/§13 结构层（Phase 2，可空）

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
## [floor_art] FloorArt（V3 §1 地板材质，Phase 5；null 时回退旧色块地板）。
## [env_art] EnvironmentArt（V3 §12 环境装饰，Phase 5；null 时不画装饰）。
## [structure_art] StructureArt（V3 §3/§4/§13 结构层，Phase 2；null 时不画结构）。
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
	cell_size: int,
	floor_art = null,
	env_art = null,
	structure_art = null
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
	_floor_art = floor_art
	_env_art = env_art
	_structure_art = structure_art
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


# === 渲染（投影后世界空间；headless 下引擎不调用 _draw，防御性 null 检查） ===

## V3.1 P1：2.5D 斜俯视绘制顺序（oblique projection，见 oblique_projection.gd）：
##   画布背景（天花板）→ 地板 pass（floor transform 包裹全部贴地内容：
##   地板材质/地面装饰/结构 BACKGROUND/网格）→ 体积墙（北墙/东西墙面 +
##   墙上装饰，画在地板之上 —— 墙脚被地板压住，墙身立起）→ 结构 GAMEPLAY
##   （前台，挤出）→ 会员中景（billboard 站立，脚底贴地）→ 设备（顶面+
##   正面+侧面 3 面挤出，有体积）→ USING 会员前景（叠加在设备上）→
##   结构 FOREGROUND（立柱挤出/吊灯挂高处/小道具贴地）→ 环境前景（大植物）
##   → 放置幽灵（贴地预览）。
func _draw() -> void:
	if _grid == null:
		return
	_draw_canvas_background()
	_draw_floor_pass()
	_draw_2_5d_walls()
	if _structure_art != null:
		_draw_structure_gameplay()
	_draw_members(false)
	_draw_equipment()
	_draw_members(true)
	_draw_structure_foreground()
	_draw_environment_foreground()
	_draw_placement_ghost()


## 画布背景（V3.1 P1）：投影后画布边界外的天花板/背景色 —— 填满 SubViewport，
## 墙顶/角落不留空洞。颜色取暖灰（WALL_DARK 亮一档，比墙暗、比地板暗，
## 视觉上是「房间上方」）。
func _draw_canvas_background() -> void:
	var b := Proj2D.bounds()
	draw_rect(Rect2(b.position - Vector2(8, 8), b.size + Vector2(16, 16)),
		Palette.WALL_BASE.darkened(0.28), true)


## 地板 pass：全部贴地内容经 floor_transform 一次性投影（V3.1 P1 ——
## 扁平坐标绘制代码原样保留，包一层 draw_set_transform_matrix）。
func _draw_floor_pass() -> void:
	_draw_with_floor_transform(func() -> void:
		_draw_floor_zones()
		_draw_floor_decor()
		if _structure_art != null:
			_draw_structure_layer(StructureArt.LAYER_BACKGROUND)
		if _grid_visible:
			_draw_grid_lines()
	)


## 在 floor_transform 下执行绘制（V3.1 P1）。draw_set_transform_matrix 设置
## 画布仿射变换（含剪切）—— 后续 draw_* 全部经地板投影；结束时恢复单位阵。
## [draw_fn] Callable（闭包绘制体，扁平世界坐标）。
func _draw_with_floor_transform(draw_fn: Callable) -> void:
	draw_set_transform_matrix(Proj2D.floor_transform())
	draw_fn.call()
	draw_set_transform_matrix(Transform2D.IDENTITY)


## 地板：Phase 5 使用 FloorArt 烘焙的材质贴图（V3 §1 区域地面材质 ——
## 力量区深灰橡胶、有氧区暖灰、瑜伽区木地板、通道瓷砖；单次 draw_texture_rect，
## 替代旧色块 + 描边）。floor_art 未注入时回退旧色块（保持既有测试兼容）。
## 在 floor pass 内调用（扁平坐标，经 floor transform 投影）。
func _draw_floor_zones() -> void:
	if _floor_art != null:
		var tex: ImageTexture = _floor_art.texture()
		if tex != null:
			draw_texture_rect(tex, Rect2(Vector2.ZERO, Vector2(
				WorldLayout.WORLD_W, WorldLayout.WORLD_H)), false)
			return
	for zone: String in Palette.ZONE_RECTS:
		var rect: Rect2i = Palette.ZONE_RECTS[zone]
		var px_rect := Rect2i(rect.position * _cell_size, rect.size * _cell_size)
		draw_rect(px_rect, Palette.ZONE_COLORS[zone], true)
		draw_rect(px_rect, Palette.ZONE_BORDER, false, 1.0 * WorldScale.STROKE_COMPENSATION)


## 结构层（V3 §3/§4/§13，Phase 2 StructureArt）：单次 draw_texture_rect 烘焙
## 贴图。BACKGROUND 低对比（降对比降饱和）、GAMEPLAY 前台原色鲜艳、FOREGROUND
## 立柱/吊灯允许轻微遮挡 —— 顺序由 _draw() 控制（见文件头注释）。
## V3.1 P1：BACKGROUND 在 floor pass 内经地板投影 —— 墙上挂饰（镜子/空调/
## 挂钟/通风口）落在墙基附近会被随后绘制的墙面盖住（隐藏），地面结构
## （踢脚线/电线槽/门垫/管道/出口招牌）正确落在墙面上可见。
func _draw_structure_layer(layer: String) -> void:
	var tex: ImageTexture = _structure_art.layer_texture(layer)
	if tex == null:
		return
	draw_texture_rect(tex, Rect2(Vector2.ZERO, Vector2(
		WorldLayout.WORLD_W, WorldLayout.WORLD_H)), false)


# === V3.1 P1 结构层体积（前台/立柱/吊灯 —— 不再扁平贴图） ===

## 前台高度（世界 px）。
const STRUCT_FRONT_DESK_H := 22.0
## 吊灯悬挂高度（世界 px，接近墙帽 —— 从天花板挂下）。
const STRUCT_LAMP_H := 95.0

## V3.1 P1 结构 GAMEPLAY：前台（主要交互对象）—— 体积挤出（顶面+正面+侧面）。
func _draw_structure_gameplay() -> void:
	if _structure_art == null:
		return
	var rect: Rect2i = _structure_art.structure_rect("front_desk")
	var tex: ImageTexture = _structure_art.structure_texture("front_desk")
	if rect.size.x <= 0 or tex == null:
		return
	_draw_extruded_box(tex, rect, STRUCT_FRONT_DESK_H,
		Palette.DESK_WOOD.darkened(0.22), Palette.DESK_WOOD.darkened(0.4))


## V3.1 P1 结构 FOREGROUND：立柱（体积挤出，近景可遮挡）+ 吊灯（挂在
## 高处）+ 小道具（贴地）。替代旧的整层贴图绘制 —— 立柱/吊灯不再扁平。
func _draw_structure_foreground() -> void:
	if _structure_art == null:
		return
	# 立柱 1/2：体积挤出（柱身到墙高）
	for id in ["column_1", "column_2"]:
		var rect: Rect2i = _structure_art.structure_rect(id)
		var tex: ImageTexture = _structure_art.structure_texture(id)
		if rect.size.x <= 0 or tex == null:
			continue
		_draw_extruded_box(tex, rect, Proj2D.WALL_HEIGHT - 10.0,
			Palette.COLUMN_DARK, Palette.COLUMN_DARK.darkened(0.18))
	# 吊灯 1/2/3：挂在墙高处（billboard，不挤出）
	for id in ["hanging_lamp_1", "hanging_lamp_2", "hanging_lamp_3"]:
		var rect: Rect2i = _structure_art.structure_rect(id)
		var tex: ImageTexture = _structure_art.structure_texture(id)
		if rect.size.x <= 0 or tex == null:
			continue
		var pos := Proj2D.proj(rect.position.x, rect.position.y, STRUCT_LAMP_H)
		draw_texture_rect(tex, Rect2(pos, Vector2(rect.size)), false)
	# 小道具（壶铃/配重片/纸杯/毛巾 —— 贴地，floor transform）
	_draw_with_floor_transform(func() -> void:
		for id in ["kettlebell_prop", "plate_prop_1", "plate_prop_2",
				"paper_cup_1", "paper_cup_2", "towels_1", "towels_2"]:
			var rect: Rect2i = _structure_art.structure_rect(id)
			var tex: ImageTexture = _structure_art.structure_texture(id)
			if rect.size.x <= 0 or tex == null:
				continue
			draw_texture_rect(tex, Rect2(rect.position, rect.size), false)
	)


## 通用体积挤出（V3.1 P1）：东侧面 + 正面 + 顶面。结构/设备共用数学。
## [tex] 顶面纹理（footprint 尺寸，扁平坐标）；[rect] 扁平 footprint；
## [height] 世界高；[front_color]/[side_color] 正面/侧面实色。
func _draw_extruded_box(tex: ImageTexture, rect: Rect2i, height: float,
		front_color: Color, side_color: Color) -> void:
	var x0 := float(rect.position.x)
	var y0 := float(rect.position.y)
	var x1 := x0 + float(rect.size.x)
	var y1 := y0 + float(rect.size.y)
	# 东侧面（x=x1，y∈[y0,y1]，z∈[0,h]）—— 阴影侧
	draw_colored_polygon(PackedVector2Array([
		Proj2D.proj(x1, y0, 0.0), Proj2D.proj(x1, y1, 0.0),
		Proj2D.proj(x1, y1, height), Proj2D.proj(x1, y0, height),
	]), side_color)
	# 正面（y=y1，x∈[x0,x1]，z∈[0,h]）—— 面向相机
	draw_colored_polygon(PackedVector2Array([
		Proj2D.proj(x0, y1, 0.0), Proj2D.proj(x1, y1, 0.0),
		Proj2D.proj(x1, y1, height), Proj2D.proj(x0, y1, height),
	]), front_color)
	# 顶面（z=height）：纹理提升（floor transform + 高度平移）
	draw_set_transform_matrix(_top_face_transform(height))
	draw_texture_rect(tex, Rect2(rect.position, rect.size), false)
	draw_set_transform_matrix(Transform2D.IDENTITY)


## 顶面仿射变换：扁平坐标 (x,y) → 投影后坐标（z=height）：floor transform
## 后再平移 (-EX*h, -H*h)（顶面相对底面左移上移 —— 东侧面/正面因此可见）。
func _top_face_transform(height: float) -> Transform2D:
	var f := Proj2D.floor_transform()
	return Transform2D(f.x, f.y,
		f.origin + Vector2(-height * Proj2D.EXTRUDE_X, -height * Proj2D.HEIGHT_SCALE))


# === V3.1 P1 体积墙（diorama 房间盒） ===

## 体积墙：北墙 + 东西墙面。墙基 = 扁平墙条（WALL_TOP_RECT / 侧墙条），
## 墙面 = 从墙基提升到 z=WALL_HEIGHT 的平行四边形（含墙帽顶面 + 踢脚线）。
## 画在地板 pass 之后 —— 墙脚被地板压住，墙身立起（V3.1 P1 墙壁有体积：
## 正面（墙面）+ 顶面（墙帽）+ 侧面（墙端/门洞）。
func _draw_2_5d_walls() -> void:
	_draw_north_wall()
	_draw_side_wall(true)    # 西墙
	_draw_side_wall(false)   # 东墙


## 北墙（入口 x 0..32 保留门洞）：墙面从墙基 y=24（墙与地板交界）提升到
## z=WALL_HEIGHT；墙帽（WALL_TRIM 顶面压条）+ 踢脚线（WALL_DARK 墙基压条）。
func _draw_north_wall() -> void:
	var w0 := 32.0   # 入口门洞 x 0..32
	var w1 := float(Proj2D.WORLD_W)
	var base_y := 24.0  # WALL_TOP_RECT 底边（墙与地板交界）
	var z := Proj2D.WALL_HEIGHT
	draw_colored_polygon(PackedVector2Array([
		Proj2D.proj(w0, base_y, 0.0), Proj2D.proj(w1, base_y, 0.0),
		Proj2D.proj(w1, base_y, z), Proj2D.proj(w0, base_y, z),
	]), Palette.WALL_BASE)
	# 顶面墙帽（4px 压条，V3.1 P1 顶面证据：墙面亮一档）
	draw_colored_polygon(PackedVector2Array([
		Proj2D.proj(w0, base_y, z), Proj2D.proj(w1, base_y, z),
		Proj2D.proj(w1, base_y, z - 4.0), Proj2D.proj(w0, base_y, z - 4.0),
	]), Palette.WALL_TRIM)
	# 踢脚线（墙基 5px 压条）
	draw_colored_polygon(PackedVector2Array([
		Proj2D.proj(w0, base_y, 0.0), Proj2D.proj(w1, base_y, 0.0),
		Proj2D.proj(w1, base_y, 5.0), Proj2D.proj(w0, base_y, 5.0),
	]), Palette.WALL_DARK)
	_draw_north_wall_decor()


## 北墙本地变换：扁平墙条坐标 (fx, fy∈[0,24]) → 墙面屏幕坐标（fy 线性映射
## 到墙高：fy=24（墙基）→ z=0，fy=0（墙顶）→ z=WALL_HEIGHT）。墙饰按扁平
## 坐标绘制即自动贴在斜墙面上。
func _north_wall_transform() -> Transform2D:
	var kex := Proj2D.WALL_HEIGHT * Proj2D.EXTRUDE_X / 24.0
	var khe := Proj2D.WALL_HEIGHT * Proj2D.HEIGHT_SCALE / 24.0
	return Transform2D(Vector2(1, 0), Vector2(kex, khe),
		Vector2(24.0 * Proj2D.SHEAR - 24.0 * kex,
			24.0 * Proj2D.FLOOR_SCALE - 24.0 * khe))


## 北墙装饰（V3 §3/§6/§12）：窗户（玻璃 + 斜高光）+ 海报/计时器/招牌/电视
## （0.5x 贴墙）。全部在北墙本地空间绘制。
func _draw_north_wall_decor() -> void:
	draw_set_transform_matrix(_north_wall_transform())
	# 窗户（V3 §6 窗口斜向自然光载体）：窗框 + 冷青灰玻璃 + 斜高光
	for window_rect in WorldLayout.WINDOWS:
		var wr: Rect2i = window_rect
		draw_rect(wr, Palette.WINDOW_FRAME, true)
		var glass: Rect2i = wr.grow(-2)
		draw_rect(glass, Palette.WINDOW_GLASS, true)
		draw_line(
			Vector2(glass.position.x + 4, glass.position.y + 2),
			Vector2(glass.position.x + 14, glass.position.y + glass.size.y - 2),
			Palette.METAL_HIGHLIGHT, 2.0 * WorldScale.STROKE_COMPENSATION)
	# 墙上挂饰（海报/计时器/招牌/电视）：0.5x 贴墙（同旧 _draw_wall_decor）
	if _env_art != null:
		var tick: int = 0
		if _tick_provider.is_valid():
			tick = _tick_provider.call()
		for prop_id: String in WorldLayout.WALL_DECOR:
			var pos: Vector2i = WorldLayout.WALL_DECOR[prop_id]
			var tex: ImageTexture = _env_art.texture_for(prop_id)
			if tex == null:
				continue
			var size: Vector2i = _env_art.texture_size(prop_id)
			draw_texture_rect(tex, Rect2(pos, Vector2(size) * 0.5), false)
			if prop_id == "tv":
				_draw_tv_screen(pos, tick)
	# 结构元素（挂钟/空调/通风口/喷淋 —— V3 §3/§4 墙面结构，简单像素块）
	_draw_north_wall_structure_decor()
	draw_set_transform_matrix(Transform2D.IDENTITY)


## 北墙结构装饰（简单像素块，替代旧 _draw_side_wall_decor 的延展墙面元素）：
## 挂钟/空调/通风口/喷淋头。位置（扁平墙条坐标）固定，低对比 BACKGROUND
## 语汇 —— 不抢设备主体（V3 §14）。
func _draw_north_wall_structure_decor() -> void:
	# 挂钟（x 200..212，高挂 fy≈3）
	draw_rect(Rect2i(200, 3, 12, 10), Palette.CLOCK_FACE, true)
	draw_rect(Rect2i(205, 5, 1, 5), Palette.CLOCK_HAND, true)
	draw_rect(Rect2i(205, 8, 4, 1), Palette.CLOCK_HAND, true)
	# 空调（x 244..272）
	draw_rect(Rect2i(244, 2, 28, 12), Palette.AC_BODY, true)
	for i in 3:
		draw_rect(Rect2i(246, 4 + i * 3, 24, 1), Palette.AC_VENT, true)
	draw_rect(Rect2i(266, 3, 2, 2), Palette.ACCENT_YELLOW, true)
	# 通风口（x 156..168 / 248..260）
	for vx in [156, 248]:
		draw_rect(Rect2i(vx, 4, 12, 8), Palette.AC_VENT.darkened(0.2), true)
		for i in 5:
			draw_rect(Rect2i(vx + 2 + i * 2, 6, 1, 4), Palette.AC_BODY, true)
	# 喷淋头（3 个）
	for sx in [80, 194, 348]:
		draw_rect(Rect2i(sx, 2, 4, 4), Palette.AC_VENT.darkened(0.3), true)


## 侧墙（西/东）：墙面 = 墙内表面（x=14 / x=402）从墙基（y0..y1）提升到
## z=WALL_HEIGHT 的平行四边形。西墙 y∈[32..320]（入口门洞 y<32）；东墙
## y∈[0..288]（出口门洞 y 288..320）。
func _draw_side_wall(is_west: bool) -> void:
	var x_in := 14.0 if is_west else float(Proj2D.WORLD_W - 14)
	var y0 := 32.0
	var y1 := float(Proj2D.WORLD_H)
	if not is_west:
		y0 = 0.0
		y1 = 288.0
	var z := Proj2D.WALL_HEIGHT
	draw_colored_polygon(PackedVector2Array([
		Proj2D.proj(x_in, y0, 0.0), Proj2D.proj(x_in, y1, 0.0),
		Proj2D.proj(x_in, y1, z), Proj2D.proj(x_in, y0, z),
	]), Palette.WALL_BASE)
	# 顶面墙帽
	draw_colored_polygon(PackedVector2Array([
		Proj2D.proj(x_in, y0, z), Proj2D.proj(x_in, y1, z),
		Proj2D.proj(x_in, y1, z - 4.0), Proj2D.proj(x_in, y0, z - 4.0),
	]), Palette.WALL_TRIM)
	# 踢脚线
	draw_colored_polygon(PackedVector2Array([
		Proj2D.proj(x_in, y0, 0.0), Proj2D.proj(x_in, y1, 0.0),
		Proj2D.proj(x_in, y1, 5.0), Proj2D.proj(x_in, y0, 5.0),
	]), Palette.WALL_DARK)
	# 侧墙装饰（管道/镜子/海报 —— 墙本地空间 u=沿墙扁平 y，v=墙高 z）
	draw_set_transform_matrix(_side_wall_transform(x_in))
	if is_west:
		# 长镜（冷蓝灰，V3 §6 冷调）：沿墙 u 40..160，墙高 v 18..92
		draw_rect(Rect2(40, 18, 120, 74), Palette.MIRROR_COLOR, true)
		draw_rect(Rect2(40, 18, 120, 74), Palette.WALL_DARK, false, 1.0 * WorldScale.STROKE_COMPENSATION)
		for i in 8:
			draw_rect(Rect2(42 + i * 2, 20 + i * 2, 1, 1), Palette.MIRROR_HI, true)
		# 毛巾架 + 暖橙毛巾
		draw_rect(Rect2(180, 40, 30, 2), Palette.METAL_HIGHLIGHT, true)
		draw_rect(Rect2(184, 42, 6, 12), Palette.TOWEL, true)
		draw_rect(Rect2(196, 42, 6, 12), Palette.TOWEL.darkened(0.15), true)
	else:
		# 竖向管道（中暖灰 + 法兰）：沿墙 u 40..320
		draw_rect(Rect2(60, 20, 3, 300), Palette.PIPE_COLOR, true)
		draw_rect(Rect2(60, 90, 4, 3), Palette.PIPE_DARK, true)
		draw_rect(Rect2(60, 200, 4, 3), Palette.PIPE_DARK, true)
		# 海报（暖色 accent 小面积）
		draw_rect(Rect2(180, 30, 14, 18), Palette.WALL_DARK, true)
		draw_rect(Rect2(182, 32, 10, 14), Palette.ACCENT_ORANGE, true)
		draw_rect(Rect2(182, 41, 10, 5), Palette.ACCENT_ORANGE.darkened(0.35), true)
	draw_set_transform_matrix(Transform2D.IDENTITY)


## 侧墙本地变换：墙本地坐标 (u=沿墙扁平 y，v=墙高 z) → 屏幕。
func _side_wall_transform(x_in: float) -> Transform2D:
	return Transform2D(
		Vector2(Proj2D.SHEAR, Proj2D.FLOOR_SCALE),
		Vector2(-Proj2D.EXTRUDE_X, -Proj2D.HEIGHT_SCALE),
		Vector2(x_in, 0.0))


## 电视画面变化（V3 §9）：屏幕区域叠 3 帧（青蓝/绿/黄轮换，确定性 tick 驱动）。
## 在北墙本地空间调用（pos 为扁平墙条坐标）。
func _draw_tv_screen(pos: Vector2i, tick: int) -> void:
	var screen_rect := Rect2(pos + Vector2i(3, 3), Vector2i(10, 6))
	var frame := (tick / 20) % 3
	var col: Color
	match frame:
		0:
			col = Palette.EMISSIVE_CYAN
		1:
			col = Palette.EMISSIVE_GREEN
		_:
			col = Palette.ACCENT_YELLOW
	col.a = 0.95
	draw_rect(screen_rect, col, true)


## 地面装饰（V3 §12 场景 storytelling）：水瓶/毛巾/配重/粉笔盒/植物/音箱/
## 卷垫/风扇/水杯架/饮水机/垃圾桶/消防栓。植物轻微摆动（V3 §9）。
## 在 floor pass 内调用（扁平坐标）。
func _draw_floor_decor() -> void:
	if _env_art == null:
		return
	var tick: int = 0
	if _tick_provider.is_valid():
		tick = _tick_provider.call()
	for prop_id: String in WorldLayout.DECOR:
		var pos: Vector2i = WorldLayout.DECOR[prop_id]
		var sway := Vector2.ZERO
		if prop_id.begins_with("plant"):
			# 植物轻微摆动（V3 §9）：±1px 确定性正弦。
			var phase := float(prop_id.hash() % 100) * 0.13
			sway.x = round(sin(tick * 0.08 + phase))
		_draw_decor_prop(prop_id, pos + Vector2i(sway))


## 环境前景（V3 §4 FOREGROUND：大型植物，可轻微遮挡角色）—— 画在设备之后。
## V3.1 P1：前景植物贴地（floor transform 内扁平绘制，billboard 植物）。
func _draw_environment_foreground() -> void:
	if _env_art == null:
		return
	var tick: int = 0
	if _tick_provider.is_valid():
		tick = _tick_provider.call()
	_draw_with_floor_transform(func() -> void:
		for prop_id: String in WorldLayout.DECOR:
			if not prop_id.begins_with("plant_fore"):
				continue
			var pos: Vector2i = WorldLayout.DECOR[prop_id]
			var sway := Vector2(round(sin(tick * 0.08 + float(prop_id.hash() % 100) * 0.13)), 0)
			_draw_decor_prop(prop_id, pos + Vector2i(sway))
	)


## 绘制单个装饰精灵（纹理存在才画；未知 prop 兜底不画，绝不崩溃）。
## [scale] 可选缩放（墙挂饰用 0.5 贴合墙高；地面装饰默认 1.0）。
## 在调用方设定的画布变换（floor transform / 墙本地变换）下绘制。
func _draw_decor_prop(prop_id: String, pos: Vector2i, scale: float = 1.0) -> void:
	if _env_art == null:
		return
	var tex: ImageTexture = _env_art.texture_for(prop_id)
	if tex == null:
		return
	var size: Vector2i = _env_art.texture_size(prop_id)
	draw_texture_rect(tex, Rect2(pos, Vector2(size) * scale), false)


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


## 设备渲染（V3.1 P1 2.5D）：contact shadow 贴地（floor transform）+ 3 面
## 挤出（顶面 = 原 art 提升到 z=height；正面 = 南边条带变暗；侧面 = 东边
## 条带变暗）。物体有体积（顶面+正面+侧面同时可见），不再是贴地图标
## （V3.1 P1 负面约束：禁止设备贴地图）。
##   - hover（§14）：黄色像素轮廓（EQUIP_HOVER_OUTLINE）+ 精灵轻微上移
##     （HOVER_LIFT_PX，contact shadow 留原地 —— 设备「抬起」感）
##   - access cell 用 Butter 高亮（art-bible §7 拖放反馈；§4 Butter 锚点 ~10%）
func _draw_equipment() -> void:
	if _grid == null or _equip_art == null:
		return
	for inst in _grid.get_placed_instances():
		var fp_rect := _footprint_rect(inst.footprint_cells)
		if fp_rect.size.x <= 0 or fp_rect.size.y <= 0:
			continue
		var is_hovered: bool = inst.instance_id == _hovered_instance_id
		var eq_id := ""
		if _resolver.is_valid():
			eq_id = str(_resolver.call(inst.instance_id))
		var zone: String = _zone_of(eq_id)
		var height: float = _equip_art.height_for(eq_id)
		var tex: ImageTexture = _equip_art.texture_for(eq_id, zone, inst.rotation)
		# 1. 贴地 contact shadow（V3 §6：双层冷蓝灰 —— 宽软外层 + 贴身内层）
		_draw_with_floor_transform(func() -> void:
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
		)
		# 2. 3 面体积（顶面 + 正面 + 侧面）
		if tex != null:
			_draw_equipment_volume(eq_id, zone, inst.rotation, fp_rect, height)
		else:
			# 兜底（未知 equipment_id）：投影后的剪影盒（侧面+正面+纯色顶），
			# 绝不崩溃。
			var x0 := float(fp_rect.position.x)
			var y0 := float(fp_rect.position.y)
			var x1 := x0 + float(fp_rect.size.x)
			var y1 := y0 + float(fp_rect.size.y)
			draw_colored_polygon(PackedVector2Array([
				Proj2D.proj(x1, y0, 0.0), Proj2D.proj(x1, y1, 0.0),
				Proj2D.proj(x1, y1, height), Proj2D.proj(x1, y0, height),
			]), Palette.CHARCOAL.darkened(0.2))
			draw_colored_polygon(PackedVector2Array([
				Proj2D.proj(x0, y1, 0.0), Proj2D.proj(x1, y1, 0.0),
				Proj2D.proj(x1, y1, height), Proj2D.proj(x0, y1, height),
			]), Palette.CHARCOAL)
			draw_set_transform_matrix(_top_face_transform(height))
			draw_rect(Rect2(fp_rect.position, fp_rect.size), Palette.CHARCOAL, true)
			draw_set_transform_matrix(Transform2D.IDENTITY)
		# 3. hover 黄色像素轮廓（沿投影后的 footprint 平行四边形）
		if is_hovered:
			_draw_equipment_hover(fp_rect, height)
		# 4. access cell 标记（贴地，floor transform；仅 placement/hover 显示）
		if _grid_visible or is_hovered:
			_draw_with_floor_transform(func() -> void:
				for c in inst.access_cells:
					_draw_access_cell(c)
			)


## 设备体积（V3.1 P1）：东侧面 + 正面 + 顶面。正面/侧面用 EquipmentArt
## 挤出面纹理（南边/东边条带变暗 —— 顶面亮、正面中、侧面暗，三层分层）。
func _draw_equipment_volume(eq_id: String, zone: String, rotation: int,
		fp: Rect2i, height: float) -> void:
	var faces: Dictionary = _equip_art.extrusion_faces_for(eq_id, zone, rotation, height)
	var x0 := float(fp.position.x)
	var y0 := float(fp.position.y)
	var x1 := x0 + float(fp.size.x)
	var y1 := y0 + float(fp.size.y)
	var face_h := _face_h(height)
	# 东侧面（x=x1）：先画（被正面/顶面压住的部分自然遮挡）
	var side_tex: ImageTexture = faces.get("side")
	if side_tex != null:
		draw_set_transform_matrix(_side_face_transform(x1, y0, height))
		draw_texture_rect(side_tex, Rect2(0, 0, float(fp.size.y), face_h), false)
		draw_set_transform_matrix(Transform2D.IDENTITY)
	else:
		draw_colored_polygon(PackedVector2Array([
			Proj2D.proj(x1, y0, 0.0), Proj2D.proj(x1, y1, 0.0),
			Proj2D.proj(x1, y1, height), Proj2D.proj(x1, y0, height),
		]), Palette.EQUIP_SHADOW_TONE)
	# 正面（y=y1）
	var front_tex: ImageTexture = faces.get("front")
	if front_tex != null:
		draw_set_transform_matrix(_front_face_transform(x0, y1, height))
		draw_texture_rect(front_tex, Rect2(0, 0, float(fp.size.x), face_h), false)
		draw_set_transform_matrix(Transform2D.IDENTITY)
	else:
		draw_colored_polygon(PackedVector2Array([
			Proj2D.proj(x0, y1, 0.0), Proj2D.proj(x1, y1, 0.0),
			Proj2D.proj(x1, y1, height), Proj2D.proj(x0, y1, height),
		]), Palette.EQUIP_BODY_DARK)
	# 顶面（z=height）：原 art 提升
	var top_tex: ImageTexture = _equip_art.texture_for(eq_id, zone, rotation)
	if top_tex != null:
		draw_set_transform_matrix(_top_face_transform(height))
		draw_texture_rect(top_tex, Rect2(fp.position, fp.size), false)
		draw_set_transform_matrix(Transform2D.IDENTITY)


## 挤出面高度（屏幕 px）：height × HEIGHT_SCALE（与 EquipmentArt 同值）。
func _face_h(height: float) -> float:
	return height * Proj2D.HEIGHT_SCALE


## 正面（南边）仿射变换：纹理坐标 (u∈[0,w], v∈[0,face_h]) → 投影后屏幕。
## v 对应 z（v = z*HEIGHT_SCALE）—— 正面平行四边形贴合顶面南边。
func _front_face_transform(x0: float, y1: float, height: float) -> Transform2D:
	var kx := Proj2D.EXTRUDE_X / Proj2D.HEIGHT_SCALE
	return Transform2D(Vector2(1, 0), Vector2(-kx, -1.0),
		Vector2(x0 + y1 * Proj2D.SHEAR, y1 * Proj2D.FLOOR_SCALE))


## 东侧面仿射变换：纹理坐标 (u∈[0,d], v∈[0,face_h]) → 投影后屏幕。
## u 对应沿墙深度（y 方向）—— 侧面平行四边形贴合顶面东边。
func _side_face_transform(x1: float, y0: float, height: float) -> Transform2D:
	var kx := Proj2D.EXTRUDE_X / Proj2D.HEIGHT_SCALE
	return Transform2D(Vector2(Proj2D.SHEAR, Proj2D.FLOOR_SCALE),
		Vector2(-kx, -1.0),
		Vector2(x1 + y0 * Proj2D.SHEAR, y0 * Proj2D.FLOOR_SCALE))


## hover 黄色轮廓：沿投影后的 footprint 平行四边形描边（V3 §14）。画在
## 设备体积之上 —— 顶面 + 侧面 + 正面的外轮廓。
func _draw_equipment_hover(fp: Rect2i, height: float) -> void:
	var hover := Palette.EQUIP_HOVER_OUTLINE
	hover.a = 0.95
	var pts := PackedVector2Array([
		Proj2D.proj(fp.position.x, fp.position.y, height),
		Proj2D.proj(fp.position.x + fp.size.x, fp.position.y, height),
		Proj2D.proj(fp.position.x + fp.size.x, fp.position.y + fp.size.y, 0.0),
		Proj2D.proj(fp.position.x, fp.position.y + fp.size.y, 0.0),
	])
	pts.append(pts[0])
	draw_polyline(pts, hover, 2.0 * WorldScale.STROKE_COMPENSATION, true)


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
## V3.1 P1：幽灵是贴地预览（floor transform 内绘制 —— tint 块/精灵/描边/
## access cell 全部经地板投影）。
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
	var zone: String = _zone_of(eq_id)
	_draw_with_floor_transform(func() -> void:
		draw_rect(rect, tint, true)
		# 精灵本体（半透明幽灵，让玩家看清要放什么）——先于描边，描边永远可读。
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
	)


## 会员渲染（Phase 4 / V3 §8）：2.5D 像素小人（48×48，>cell 32 —— 画面视觉
## 主体），状态双通道（颜色通道衬衫色 + 形状通道姿态）。
## V3 §15 修复（P0-3 人物视觉权重）：sprite 纹理尺寸保持 48×48（unit 测试
## 像素断言 pin 住），在绘制层增加「地面亮池 + 加宽接触影」—— 深色轮廓
## （CHARCOAL）在深灰橡胶力量区（#4B4F57）上会融入背景（门禁 FAIL：轮廓
## 弱），脚底亮池把人物从深色地面「托起」，远景远读性增强（V3 §6 接触
## 阴影 + §11 轮廓可读性；不改变纹理像素，不破坏 unit 断言）。
##
## [foreground] 双层绘制：
##   false = 中景：walk/idle/tired/satisfied 会员，脚底锚定自身 cell 底部
##           （sprite 头部向上越出 cell —— 2.5D 人物高于占用格）。
##   true  = 前景：USING 会员叠加在目标设备 footprint 上（跑带/卧推凳/车座/
##           垫面 —— V3 §8 与设备互动姿态），由 _equipment_anchor 计算锚点。
## 设备上下文（equipment_id / leaving_reason / use_ticks_remaining / member_id）
## 经 ctx 传入 texture_for —— 使用姿态与外观变体据此解析。
func _draw_members(foreground: bool) -> void:
	if _member == null or _member_sprites == null:
		return
	var tick: int = 0
	if _tick_provider.is_valid():
		tick = _tick_provider.call()
	var alive: Dictionary = {}
	# USING 成员 → 设备 footprint 锚点查找表（本帧构建一次，O(placed)）。
	var equip_anchors: Dictionary = {}
	if foreground:
		equip_anchors = _build_equipment_anchors()
	for m in _member.members:
		if not (m is Dictionary) or not m.has("cell") or not m.has("state"):
			continue
		var member_id := int(m.get("member_id", -1))
		if member_id >= 0:
			alive[member_id] = true
		var state := str(m["state"])
		if _member_sprites.state_channel(state) == "":
			continue  # GONE / 被动成员 —— 不渲染
		var is_using := state == "USING"
		if is_using != foreground:
			continue  # 双层各画一半
		var cell: Vector2i = m["cell"]
		var facing_left := _update_facing(member_id, cell)
		var ctx := _member_ctx(m, state)
		var tex: ImageTexture = _member_sprites.texture_for(state, tick, facing_left, ctx)
		var draw_pos: Vector2
		if is_using:
			# 前景：锚定设备 footprint（V3 §8 使用姿态叠加在设备上）。
			var anchor: Vector2 = equip_anchors.get(
				int(m.get("target_equipment_instance_id", -1)), Vector2.INF)
			if anchor == Vector2.INF:
				anchor = _cell_anchor(cell)  # 设备丢失兜底：锚定自身 cell
			draw_pos = anchor
		else:
			draw_pos = _cell_anchor(cell)
		# V3 §15（P0-3 人物视觉权重）：脚底亮池 —— 半透明暖白椭圆垫在脚下，
		# 把深色轮廓人物从深灰力量区地面「托起」（远景轮廓可读性）。亮池只
		# 在中景成员绘制（非 USING 叠加在设备上时会被设备盖住，不额外画）。
		# V3.1 P1：亮池贴地（floor transform 内椭圆，随地板压缩）。
		if not is_using:
			_draw_member_ground_glow(_flat_feet(cell))
		draw_texture(tex, draw_pos)
	# 清理已离场成员的朝向缓存（防止字典无限增长）
	for member_id in _member_facing.keys():
		if not alive.has(member_id):
			_member_facing.erase(member_id)
			_member_last_cell.erase(member_id)


## 构建 instance_id → 设备使用锚点（USING 前景层）。footprint 左上角 +
## 设备类型偏移：跑带居中、卧推凳在凳面、车座居中、垫面居中。锚点是
## 48×48 sprite 的左上角（脚底/接触点对齐设备）。
## [footprint_rect] 世界像素 Rect2i；返回 sprite 左上角 Vector2。
func _build_equipment_anchors() -> Dictionary:
	var anchors: Dictionary = {}
	if _grid == null or _equip_art == null:
		return anchors
	for inst in _grid.get_placed_instances():
		var rect := _footprint_rect(inst.footprint_cells)
		if rect.size.x <= 0 or rect.size.y <= 0:
			continue
		var eq_id := ""
		if _resolver.is_valid():
			eq_id = str(_resolver.call(inst.instance_id))
		anchors[inst.instance_id] = _equipment_anchor(eq_id, rect)
	return anchors


## 设备使用锚点（V3.1 P1 投影后）：sprite 左上角（48×48），使成员"落在"
## 设备上。基准：脚底接触点 = 设备 footprint 底边中点（+ 设备类型微调），
## 投影到设备高度（站立在机器上，billboard 不压缩）。
func _equipment_anchor(eq_id: String, rect: Rect2i) -> Vector2:
	var center_x := rect.position.x + rect.size.x / 2.0
	var feet_y := rect.position.y + rect.size.y
	var sprite_w := float(_member_sprites.SIZE) if _member_sprites != null else 48.0
	var flat_anchor: Vector2
	match eq_id:
		"treadmill":
			# 跑带居中：脚在 footprint 底边（跑带下沿），身体微前倾已由姿态表达
			flat_anchor = Vector2(center_x - sprite_w / 2.0, feet_y - sprite_w)
		"bench_press":
			# 卧推凳：身体横躺 —— 头在左、躯干向右，锚在 footprint 左上角 +
			# 下移 26px 让横躺身体（纹理 18..33 行）落在凳面（pad 中段）
			flat_anchor = Vector2(rect.position.x + 2, rect.position.y + 26)
		"bike":
			# 车座居中：脚在车架中部（略高于底边），身体坐姿
			flat_anchor = Vector2(center_x - sprite_w / 2.0, rect.position.y + rect.size.y - 16 - sprite_w * 0.5)
		"yoga_mat":
			# 垫面居中：脚在垫面底边（盘坐）
			flat_anchor = Vector2(center_x - sprite_w / 2.0, feet_y - sprite_w * 0.62)
		_:
			# 未知设备兜底：锚定 footprint 底边居中
			flat_anchor = Vector2(center_x - sprite_w / 2.0, feet_y - sprite_w)
	# 投影：sprite 脚底（flat anchor 底边中心）→ 设备高度（站立在机器上）
	var flat_feet := flat_anchor + Vector2(sprite_w * 0.5, sprite_w)
	var stand_z: float = 16.0
	if _equip_art != null:
		stand_z = _equip_art.height_for(eq_id) * 0.75
	var p := Proj2D.proj(flat_feet.x, flat_feet.y, stand_z)
	return p - Vector2(sprite_w * 0.5, sprite_w)


## 普通（非 USING）会员的 cell 锚点（V3.1 P1 投影后）：sprite 左上角 =
## 脚底（cell 底部中心）投影后 - (sprite_w/2, sprite_h)。billboard 站立，
## 头部向上越出 cell（2.5D 人物高于占用格）。
func _cell_anchor(cell: Vector2i) -> Vector2:
	var sprite_w := float(_member_sprites.SIZE) if _member_sprites != null else 48.0
	var feet := _flat_feet(cell)
	var p := Proj2D.proj(feet.x, feet.y, 0.0)
	return p - Vector2(sprite_w * 0.5, sprite_w)


## 扁平脚底点（世界坐标）：cell 底部中心。供投影锚点与贴地亮池使用。
func _flat_feet(cell: Vector2i) -> Vector2:
	return Vector2(cell.x * _cell_size + _cell_size * 0.5,
		cell.y * _cell_size + _cell_size)


## V3 §15（P0-3 人物视觉权重）：会员脚底亮池 —— 半透明暖白椭圆垫在脚下，
## 把深色轮廓（CHARCOAL）人物从深灰橡胶力量区（#4B4F57）地面「托起」。
## 亮池用低 alpha 暖白（V3 §6 顶部暖白光），宽度略大于 sprite，视觉上
## 像"人物站在灯光下"，远景远读性增强。纯 presentation 层效果 —— 不改
## 纹理像素、不破坏 unit 像素断言；画在 sprite 之下（先画亮池后画人物）。
## 4.7.1 注意：draw_ellipse 签名是 (position, radius: float, ...) 无 Vector2
## 尺寸 —— 用 draw_colored_polygon 画椭圆多边形（16 段，确定性，低 alpha）。
## V3.1 P1：亮池贴地 —— 扁平脚底坐标 + floor transform（椭圆随地板压缩）。
func _draw_member_ground_glow(flat_feet: Vector2) -> void:
	var glow := Palette.HIGHLIGHT_WARM
	glow.a = 0.10
	var size := float(_member_sprites.SIZE) if _member_sprites != null else 48.0
	var rx := size * 0.62
	var ry := size * 0.16
	_draw_with_floor_transform(func() -> void:
		var pts := PackedVector2Array()
		for i in 16:
			var a := TAU * float(i) / 16.0
			pts.append(flat_feet + Vector2(cos(a) * rx, sin(a) * ry))
		draw_colored_polygon(pts, glow)
	)


## 会员绘制上下文（V3 §8 设备互动 + §9 微型动态 + 每人外观）：
##   equipment_id       USING 成员的目标设备（经 resolver）
##   leaving_reason     LEAVING 成员的离场原因（quota_met → satisfied 满意）
##   use_ticks_remaining  USING 剩余 tick（bench 结束坐起窗口）
##   member_id          外观变体（每人清晰发型/皮肤色块）
func _member_ctx(m: Dictionary, state: String) -> Dictionary:
	var ctx := {
		"member_id": int(m.get("member_id", -1)),
	}
	if state == "USING":
		var target := int(m.get("target_equipment_instance_id", -1))
		if target >= 0 and _resolver.is_valid():
			ctx["equipment_id"] = str(_resolver.call(target))
		if m.has("use_ticks_remaining"):
			ctx["use_ticks_remaining"] = int(m["use_ticks_remaining"])
	if state == "LEAVING":
		ctx["leaving_reason"] = str(m.get("leaving_reason", ""))
	return ctx


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
