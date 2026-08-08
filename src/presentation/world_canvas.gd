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


# === 渲染（世界像素空间；headless 下引擎不调用 _draw，防御性 null 检查） ===

func _draw() -> void:
	if _grid == null:
		return
	_draw_floor_zones()
	# Phase 5 环境背景（墙/窗/海报/装饰，V3 §3/§12）先画 —— 结构层 BACKGROUND
	# （储物柜/镜子/空调/墙钟/通风口/门/踢脚线/电线槽/管道）画在墙面上方。
	_draw_environment_background()
	if _structure_art != null:
		_draw_structure_layer(StructureArt.LAYER_BACKGROUND)
	if _grid_visible:
		_draw_grid_lines()
	# 2.5D 空间层级（art-bible-25d §1 + V3 §4 三层 + Phase 4 双层会员）：
	# 环境背景 → 结构层 GAMEPLAY（前台，Phase 2）→ 会员中景
	# （walk/idle/tired/satisfied）→ 设备前景 → 使用中的会员叠加在设备上
	# （V3 §8 与设备互动姿态）→ 结构层 FOREGROUND（立柱/吊灯，Phase 2，
	# V3 §4 可轻微遮挡）→ 环境前景（大植物可轻微遮挡）→ 幽灵（活动决策
	# 预览，Core Rule 7 优先级最高）。
	if _structure_art != null:
		_draw_structure_layer(StructureArt.LAYER_GAMEPLAY)
	_draw_members(false)
	_draw_equipment()
	_draw_members(true)
	if _structure_art != null:
		_draw_structure_layer(StructureArt.LAYER_FOREGROUND)
	_draw_environment_foreground()
	_draw_placement_ghost()


## 地板：Phase 5 使用 FloorArt 烘焙的材质贴图（V3 §1 区域地面材质 ——
## 力量区深灰橡胶、有氧区暖灰、瑜伽区木地板、通道瓷砖；单次 draw_texture_rect，
## 替代旧色块 + 描边）。floor_art 未注入时回退旧色块（保持既有测试兼容）。
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


## 环境背景（V3 §3 永久环境结构 + §12 场景 storytelling，BACKGROUND 低对比）：
## 顶墙 + 侧墙（V3 §3 墙壁/窗户）→ 墙上挂饰（海报/计时器/招牌）→ 地面装饰
## （水瓶/毛巾/配重/粉笔盒/植物/音箱/卷垫/风扇/水杯架/饮水机/垃圾桶/消防栓）。
## 画在网格线/会员/设备之前 —— 属于空间 BACKGROUND 层（V3 §4）。
func _draw_environment_background() -> void:
	_draw_walls()
	_draw_wall_decor()
	_draw_floor_decor()


## 结构层（V3 §3/§4/§13，Phase 2 StructureArt）：单次 draw_texture_rect 烘焙
## 贴图。BACKGROUND 低对比（降对比降饱和）、GAMEPLAY 前台原色鲜艳、FOREGROUND
## 立柱/吊灯允许轻微遮挡 —— 顺序由 _draw() 控制（见文件头注释）。
func _draw_structure_layer(layer: String) -> void:
	var tex: ImageTexture = _structure_art.layer_texture(layer)
	if tex == null:
		return
	draw_texture_rect(tex, Rect2(Vector2.ZERO, Vector2(
		WorldLayout.WORLD_W, WorldLayout.WORLD_H)), false)


## 顶墙 + 左右侧墙（V3 §3 墙壁）：暖灰基底 + 墙裙压条 + 窗户。
## V3 §15 第一眼修复：墙面延展到完整视口宽度（world x -76..492），消除
## 两侧 ~171 screen px 纯米色空带（门禁 FAIL：large empty beige background）。
## 顶墙保留入口门洞（x 0..32），侧墙保留出口门洞（y 288..320）。
func _draw_walls() -> void:
	# 顶墙：主段 + 左右延展段（延展段用同色，画在门洞之外）
	draw_rect(WorldLayout.WALL_TOP_RECT, Palette.WALL_BASE, true)
	draw_rect(WorldLayout.WALL_TOP_LEFT_FILL, Palette.WALL_BASE, true)
	draw_rect(WorldLayout.WALL_TOP_RIGHT_FILL, Palette.WALL_BASE, true)
	draw_rect(Rect2i(-76, WorldLayout.WALL_TRIM_Y, WorldLayout.WORLD_W + 152, 4), Palette.WALL_DARK, true)
	# 侧墙：延展段（覆盖原 WALL_LEFT/RIGHT_RECT 并填满视口边缘）
	draw_rect(WorldLayout.WALL_LEFT_EXTENDED, Palette.WALL_BASE, true)
	draw_rect(WorldLayout.WALL_RIGHT_EXTENDED, Palette.WALL_BASE, true)
	# 延展墙面的结构装饰（V3 §3/§12：管道/镜子/海报/置物架/空调/挂钟/通风口）
	_draw_side_wall_decor()
	# 窗户（V3 §6 窗口斜向自然光载体）：窗框 + 冷青灰玻璃
	for window_rect in WorldLayout.WINDOWS:
		draw_rect(window_rect, Palette.WINDOW_FRAME, true)
		var glass: Rect2i = (window_rect as Rect2i).grow(-2)
		draw_rect(glass, Palette.WINDOW_GLASS, true)
		# 玻璃高光斜线（冷色高光，V3 §6）
		draw_line(
			Vector2(glass.position.x + 4, glass.position.y + 2),
			Vector2(glass.position.x + 14, glass.position.y + glass.size.y - 2),
			Palette.METAL_HIGHLIGHT, 2.0 * WorldScale.STROKE_COMPENSATION)


## 延展墙面结构装饰（V3 §3/§12，V3 §15 第一眼）：左右两侧延展墙不再是
## 纯米色空带，而是有管道/镜子/海报/置物架/空调/挂钟/通风口/毛巾架的结构
## 墙。全部简单像素块（结构装饰，低对比 BACKGROUND 语汇 —— 不抢设备主体）。
func _draw_side_wall_decor() -> void:
	for decor_id: String in WorldLayout.WALL_SIDE_DECOR:
		var pos: Vector2i = WorldLayout.WALL_SIDE_DECOR[decor_id]
		if decor_id.begins_with("pipe"):
			# 竖向管道：中暖灰 + 法兰接头（2px 宽）
			draw_rect(Rect2i(pos, Vector2i(2, 240)), Palette.PIPE_COLOR, true)
			draw_rect(Rect2i(pos + Vector2i(0, 60), Vector2i(3, 2)), Palette.PIPE_DARK, true)
			draw_rect(Rect2i(pos + Vector2i(0, 140), Vector2i(3, 2)), Palette.PIPE_DARK, true)
		elif decor_id.begins_with("mirror"):
			# 长镜：冷蓝灰镜面 + 斜向高光 + 边框（V3 §6 冷调）
			draw_rect(Rect2i(pos, Vector2i(14, 80)), Palette.WALL_DARK, true)
			draw_rect(Rect2i(pos + Vector2i(2, 2), Vector2i(10, 76)), Palette.MIRROR_COLOR, true)
			for i in 10:
				draw_rect(Rect2i(pos + Vector2i(2 + i, 2 + i), Vector2i(1, 1)), Palette.MIRROR_HI, true)
		elif decor_id.begins_with("poster"):
			# 海报：边框 + 暖色 accent 主色（小面积高饱和，V3 §7）
			draw_rect(Rect2i(pos, Vector2i(14, 18)), Palette.WALL_DARK, true)
			var accent := Palette.ACCENT_CYAN if decor_id.ends_with("1") else Palette.ACCENT_ORANGE
			draw_rect(Rect2i(pos + Vector2i(2, 2), Vector2i(10, 14)), accent, true)
			draw_rect(Rect2i(pos + Vector2i(2, 11), Vector2i(10, 5)), accent.darkened(0.35), true)
		elif decor_id.begins_with("shelf"):
			# 置物架：隔板 + 小物件
			draw_rect(Rect2i(pos, Vector2i(14, 2)), Palette.WALL_TRIM, true)
			draw_rect(Rect2i(pos + Vector2i(2, 2), Vector2i(3, 5)), Palette.ACCENT_CYAN, true)
			draw_rect(Rect2i(pos + Vector2i(8, 2), Vector2i(3, 4)), Palette.ACCENT_YELLOW, true)
		elif decor_id.begins_with("clock"):
			# 挂钟：表盘 + 指针
			draw_rect(Rect2i(pos, Vector2i(12, 12)), Palette.CLOCK_FACE, true)
			var cx := pos.x + 6
			var cy := pos.y + 6
			draw_rect(Rect2i(cx, pos.y + 1, 1, 5), Palette.CLOCK_HAND, true)
			draw_rect(Rect2i(cx, cy, 5, 1), Palette.CLOCK_HAND, true)
		elif decor_id.begins_with("ac"):
			# 空调：暖白机身 + 出风栅 + 显示灯
			draw_rect(Rect2i(pos, Vector2i(24, 10)), Palette.AC_BODY, true)
			for i in 3:
				draw_rect(Rect2i(pos + Vector2i(2, 2 + i * 3), Vector2i(20, 1)), Palette.AC_VENT, true)
			draw_rect(Rect2i(pos + Vector2i(20, 1), Vector2i(2, 2)), Palette.ACCENT_YELLOW, true)
		elif decor_id.begins_with("vent"):
			# 通风口：边框 + 栅条
			draw_rect(Rect2i(pos, Vector2i(12, 8)), Palette.AC_VENT.darkened(0.2), true)
			for i in 5:
				draw_rect(Rect2i(pos + Vector2i(2 + i * 2, 2), Vector2i(1, 4)), Palette.AC_BODY, true)
		elif decor_id.begins_with("towel_rack"):
			# 毛巾架：横杆 + 暖橙毛巾
			draw_rect(Rect2i(pos, Vector2i(12, 1)), Palette.METAL_HIGHLIGHT, true)
			draw_rect(Rect2i(pos + Vector2i(2, 1), Vector2i(3, 8)), Palette.TOWEL, true)
			draw_rect(Rect2i(pos + Vector2i(7, 1), Vector2i(3, 8)), Palette.TOWEL.darkened(0.15), true)


## 墙上挂饰（V3 §12 海报/计时器/招牌）：EnvironmentArt 精灵（0.5x 缩放
## 贴合 24px 顶墙 —— 墙不是 cell 空间，挂饰按墙高缩放）。
## 电视屏幕内容按 tick 切换（V3 §9 电视画面变化）：在挂饰上叠 3 帧画面色。
func _draw_wall_decor() -> void:
	if _env_art == null:
		return
	var tick: int = 0
	if _tick_provider.is_valid():
		tick = _tick_provider.call()
	for prop_id: String in WorldLayout.WALL_DECOR:
		var pos: Vector2i = WorldLayout.WALL_DECOR[prop_id]
		_draw_decor_prop(prop_id, pos, 0.5)
		if prop_id == "tv":
			_draw_tv_screen(pos, tick)


## 电视画面变化（V3 §9）：屏幕区域叠 3 帧（青蓝/绿/黄轮换，确定性 tick 驱动）。
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
## V3 §15 修复（P0-4 纵深）：遍历所有 plant_fore_* 装饰（不只硬编码 2 个），
## 前景元素真实压住 GAMEPLAY 层（前后遮挡强化纵深，门禁 FAIL：遮挡有限）。
func _draw_environment_foreground() -> void:
	if _env_art == null:
		return
	var tick: int = 0
	if _tick_provider.is_valid():
		tick = _tick_provider.call()
	for prop_id: String in WorldLayout.DECOR:
		if not prop_id.begins_with("plant_fore"):
			continue
		var pos: Vector2i = WorldLayout.DECOR[prop_id]
		var sway := Vector2(round(sin(tick * 0.08 + float(prop_id.hash() % 100) * 0.13)), 0)
		_draw_decor_prop(prop_id, pos + Vector2i(sway))


## 绘制单个装饰精灵（纹理存在才画；未知 prop 兜底不画，绝不崩溃）。
## [scale] 可选缩放（墙挂饰用 0.5 贴合墙高；地面装饰默认 1.0）。
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

		# V3 §14 可读性：access cell 星形标记仅 placement mode（grid 可见）或
		# hover 时出现 —— 正常经营模式静态帧不常驻黄框/星形标记（门禁 FAIL：
		# 选择/任务标记有调试感）。幽灵的 access cell 在拖拽时由
		# _draw_placement_ghost 绘制（grid 可见时同路径）。
		if _grid_visible or is_hovered:
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
		if not is_using:
			_draw_member_ground_glow(draw_pos)
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


## 设备使用锚点：sprite 左上角（48×48），使成员"落在"设备上。
## 基准：脚底接触点 = 设备 footprint 底边中点（+ 设备类型微调）。
func _equipment_anchor(eq_id: String, rect: Rect2i) -> Vector2:
	var center_x := rect.position.x + rect.size.x / 2.0
	var feet_y := rect.position.y + rect.size.y
	var sprite_w := float(_member_sprites.SIZE) if _member_sprites != null else 48.0
	match eq_id:
		"treadmill":
			# 跑带居中：脚在 footprint 底边（跑带下沿），身体微前倾已由姿态表达
			return Vector2(center_x - sprite_w / 2.0, feet_y - sprite_w)
		"bench_press":
			# 卧推凳：身体横躺 —— 头在左、躯干向右，锚在 footprint 左上角 +
			# 下移 26px 让横躺身体（纹理 18..33 行）落在凳面（pad 中段）
			return Vector2(rect.position.x + 2, rect.position.y + 26)
		"bike":
			# 车座居中：脚在车架中部（略高于底边），身体坐姿
			return Vector2(center_x - sprite_w / 2.0, rect.position.y + rect.size.y - 16 - sprite_w * 0.5)
		"yoga_mat":
			# 垫面居中：脚在垫面底边（盘坐）
			return Vector2(center_x - sprite_w / 2.0, feet_y - sprite_w * 0.62)
		_:
			# 未知设备兜底：锚定 footprint 底边居中
			return Vector2(center_x - sprite_w / 2.0, feet_y - sprite_w)


## 普通（非 USING）会员的 cell 锚点：sprite 左上角 = cell 左上角 +
## 水平居中偏移 + 脚底对齐 cell 底部（头部越出 cell 上方 16px）。
func _cell_anchor(cell: Vector2i) -> Vector2:
	var sprite_w := float(_member_sprites.SIZE) if _member_sprites != null else 48.0
	var x := cell.x * _cell_size + (_cell_size - sprite_w) / 2.0
	var y := cell.y * _cell_size + _cell_size - sprite_w
	return Vector2(x, y)


## V3 §15（P0-3 人物视觉权重）：会员脚底亮池 —— 半透明暖白椭圆垫在脚下，
## 把深色轮廓（CHARCOAL）人物从深灰橡胶力量区（#4B4F57）地面「托起」。
## 亮池用低 alpha 暖白（V3 §6 顶部暖白光），宽度略大于 sprite，视觉上
## 像"人物站在灯光下"，远景远读性增强。纯 presentation 层效果 —— 不改
## 纹理像素、不破坏 unit 像素断言；画在 sprite 之下（先画亮池后画人物）。
## 4.7.1 注意：draw_ellipse 签名是 (position, radius: float, ...) 无 Vector2
## 尺寸 —— 用 draw_colored_polygon 画椭圆多边形（16 段，确定性，低 alpha）。
func _draw_member_ground_glow(sprite_anchor: Vector2) -> void:
	var glow := Palette.HIGHLIGHT_WARM
	glow.a = 0.10
	var size := float(_member_sprites.SIZE) if _member_sprites != null else 48.0
	var center := sprite_anchor + Vector2(size * 0.5, size)
	var rx := size * 0.62
	var ry := size * 0.16
	var pts := PackedVector2Array()
	for i in 16:
		var a := TAU * float(i) / 16.0
		pts.append(center + Vector2(cos(a) * rx, sin(a) * ry))
	draw_colored_polygon(pts, glow)


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
