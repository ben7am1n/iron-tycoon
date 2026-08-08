# src/main.gd — Playable Build 组装 glue（main scene 脚本）
#
# Story: Playable Build 组装（main_scene + composition root 串联 5 层系统）
# ADR:   ADR-0001（composition root 拓扑初始化）、ADR-0005（信号桥接）
#
# 职责（只做组装，不做玩法逻辑）：
#   1. 构造数据源（GridSystem / EquipmentCatalog / SeededRNG / Navigation）
#   2. 构造 SimulationOrchestrator 并预注入依赖（grid / catalog / economy），
#      add_child 触发 _ready() → init() → 拓扑构造 time_system / placement /
#      selection / 两个输入 bridge（ADR-0001 §4/§5）
#   3. 构造 4 个 tick 系统（MemberSim/Congestion/Satisfaction/Economy）并注入
#      orchestrator 字段 + 按 FIXED_TICK_ORDER 填入 _tick_systems（TR-TS-003）
#   4. 构造 presentation 层（HeatmapLayer / AccessBlockedLayer /
#      CongestionGlyphLayer）与 UI 层（Hud / BuildShopPalette / Shop /
#      ModeArbitration / SelectionToolbar / SelectionCue / 拖拽反馈控制器）
#   5. 初始布局：预置 3 台设备让 playtest 开箱即有内容可看
#   6. --smoke 模式：headless 下跑 N 帧验证组装无崩溃，打印状态后退出
#
# headless 注意：class_name 在 headless 项目加载下不保证全局注册
# （4.7.1 已验证，项目内脚本统一使用 preload const alias —— 本文件遵循
# 同一约定，所有跨脚本引用走 preload）。ZoneRules.evaluate 是实例方法，
# 需要 new 后调用。

extends Node2D

# === 跨脚本引用（preload alias —— headless 可靠，项目约定） ===
const SimulationOrchestratorScript := preload("res://src/systems/simulation_orchestrator.gd")
const GridSystemScript := preload("res://src/systems/grid_system.gd")
const EquipmentCatalogLoaderScript := preload("res://src/systems/equipment_catalog_loader.gd")
const SeededRGNScript := preload("res://src/systems/seeded_rng.gd")
const NavigationScript := preload("res://src/systems/navigation.gd")
const MemberSimScript := preload("res://src/systems/member_sim.gd")
const CongestionScript := preload("res://src/systems/congestion.gd")
const SatisfactionScript := preload("res://src/systems/satisfaction.gd")
const EconomyScript := preload("res://src/systems/economy.gd")
const ZoneRulesScript := preload("res://src/systems/zone_rules.gd")
const HudScript := preload("res://src/ui/hud.gd")
const BuildShopPaletteScript := preload("res://src/ui/build_shop_palette.gd")
const ShopScript := preload("res://src/ui/shop.gd")
const ModeArbitrationScript := preload("res://src/ui/mode_arbitration.gd")
const HeatmapLayerScript := preload("res://src/presentation/heatmap_layer.gd")
const AccessBlockedLayerScript := preload("res://src/presentation/access_blocked_layer.gd")
const CongestionGlyphLayerScript := preload("res://src/presentation/congestion_glyph_layer.gd")
const RejectionTooltipScript := preload("res://src/ui/rejection_tooltip.gd")
const CongestionOverlayControllerScript := preload("res://src/ui/congestion_overlay_controller.gd")
const SelectionToolbarScript := preload("res://src/ui/selection_toolbar.gd")
const SelectionCueScript := preload("res://src/ui/selection_cue.gd")
const MemberSpriteScript := preload("res://src/presentation/member_sprite.gd")
const EquipmentArtScript := preload("res://src/presentation/equipment_art.gd")
const SnapPulseScript := preload("res://src/presentation/snap_pulse.gd")
const Palette := preload("res://src/palette.gd")

# === 场景级常量（组装参数，非玩法数值） ===
const GRID_W := 13
const GRID_H := 10
const ENTRANCE := Vector2i(0, 0)
const EXIT := Vector2i(12, 9)
const CELL_SIZE := 32          # SimulationOrchestrator.PLACEMENT_CELL_SIZE
const CATALOG_PATH := "res://data/equipment_catalog.json"
const MASTER_SEED := 20260807
const SMOKE_FRAMES := 600      # --smoke 运行帧数（headless 帧率不定，600 帧 ≈ 数秒 sim）

## UI 显式停靠（BUILD-01/02 修复）：Main 是 Node2D root，Control 直接子节点
## 的锚点 preset 会解析到零尺寸父矩形（palette 曾落在 (0,-64)、HUD 0×0）。
## 改为按 viewport 显式定位/定尺 —— 与 playtest 会话 probe 验证的修复方向一致。
const UI_VIEWPORT_W := 1280
const UI_VIEWPORT_H := 720
## 底部建造商店条带高度 = PaletteTile 最小尺寸 96×96（整块 tile 可见，
## 不会被 64px 理论条带裁切）。
const PALETTE_STRIP_H := 96

# === 系统引用（供 UI/presentation 注入，orchestrator 持有所有权） ===
var _orch
var _grid
var _catalog
var _srg
var _nav
var _member
var _cong
var _sat
var _econ
var _zone_rules

# === UI / presentation 引用 ===
var _hud
var _palette
var _shop
var _arbitration
var _heatmap
var _access_blocked
var _glyph_layer
var _tooltip
var _overlay_ctrl
var _toolbar
var _cue
var _member_sprites
var _equip_art
var _snap_pulse

# === 组装状态 ===
var _instance_defs: Dictionary = {}  # instance_id -> equipment_id（resolver 数据源）
var _smoke := false
var _smoke_frame := 0
## Phase C v2：会员朝向（presentation 层状态，非玩法逻辑 —— 由 cell 移动
## 推断 facing，纯绘制用）。member_id -> bool（true = 朝左）。
var _member_facing: Dictionary = {}
var _member_last_cell: Dictionary = {}

## 吸附「咔哒」去重：记录最近一次脉冲的 anchor cell，防止同一格反复触发
## preview_validity_changed(true) 时脉冲重放（视觉噪声，art-bible §9 无闪烁）。
var _last_snap_cell := Vector2i(-999, -999)


func _ready() -> void:
	_parse_args()
	_assemble_systems()
	_assemble_presentation()
	_assemble_ui()
	_initial_layout()
	if _smoke:
		_orch.time_system.resume()  # 让 tick 循环跑起来以便 smoke 观察


## --smoke 解析：headless 冒烟验证模式。
func _parse_args() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg == "--smoke":
			_smoke = true


# === 第 1 层：模拟系统（数据源 + orchestrator composition root + tick 系统） ===

func _assemble_systems() -> void:
	_srg = SeededRGNScript.new()
	_srg.init(MASTER_SEED)

	_grid = GridSystemScript.new()
	_grid.init(GRID_W, GRID_H)
	for y in GRID_H:
		for x in GRID_W:
			_grid.set_buildable(Vector2i(x, y), true)
	_grid.freeze_buildable()

	var load_result = EquipmentCatalogLoaderScript.load_from_file(CATALOG_PATH, true)
	if not load_result.ok:
		push_error("main.gd: catalog load failed — %s" % [str(load_result.errors)])
	_catalog = load_result.catalog

	_nav = NavigationScript.new()
	_nav.init(_grid)
	_nav._post_init()

	# --- composition root：预注入依赖后 add_child 触发 init() ---
	_orch = SimulationOrchestratorScript.new()
	_orch.equipment_catalog = _catalog
	_orch.grid_system = _grid
	_orch.navigation = _nav

	# 4 个 tick 系统需要 orchestrator 引用，故在 add_child 前构造；
	# Congestion 先 new 未 init 的 MemberSim 引用（core_loop 集成测试同序）。
	_member = MemberSimScript.new()
	_cong = CongestionScript.new()
	_cong.init(_orch, _srg, _grid, _member, {}, _nav, ENTRANCE)
	_member.init(_orch, _srg, _grid, _nav, _catalog, ENTRANCE, EXIT,
		_member_config(), _cong, _resolver())
	_sat = SatisfactionScript.new()
	_sat.init(_orch, _srg, _member, _cong, _zone_reader(), {})
	_econ = EconomyScript.new()
	_econ.init(_orch, _srg, {})

	_orch.member_sim = _member
	_orch.congestion = _cong
	_orch.satisfaction = _sat
	_orch.economy = _econ

	# 挂树 → _ready() → init() → 拓扑构造 time_system / placement / selection /
	# PlacementInputBridge / SelectionInputBridge（ADR-0001 §4-5）。
	add_child(_orch)

	# Phase 2 接线：S1 grid_changed（Congestion/Navigation 已接）+ S5
	# member_completed_visit（Economy）。
	_cong._post_init()
	_econ._post_init()

	# 固定 tick 顺序（TR-TS-003）——数组顺序即派发顺序。
	_orch.set("_tick_systems", [_member, _cong, _sat, _econ])

	# ZoneRules 纯函数对象（实例方法 evaluate，见类头）。
	_zone_rules = ZoneRulesScript.new()


## MemberSim 组装配置（到达率/容量；use_duration 由 catalog def 提供，
## 此处仅兜底）。数据驱动，非硬编码。
func _member_config() -> Dictionary:
	return {
		"base_arrival_rate_per_min": 60.0,
		"max_concurrent_members": 20,
		"use_duration_mean_ticks": 40,
		"use_duration_stddev_ticks": 8,
		"use_duration_min_ticks": 20,
		"use_duration_max_ticks": 80,
		"leaving_timeout_ticks": 300,
		"exercises_mean": 1.0,
		"exercises_stddev": 0.0,
		"exercises_min": 1,
		"exercises_max": 1,
		"patience_min_ticks": 30,
		"patience_max_ticks": 80,
		"k_congestion": 5.0,
		"k_proximity": 0.2,
		"D_max": 16,
		"top_k": 4,
	}


## instance_id -> equipment_id 解析器（TR-MS-009）。数据源是 main.gd 的
## _instance_defs，由 placement_committed 信号增量维护（见 _on_placed）。
func _resolver() -> Callable:
	return func(instance_id: int) -> String:
		return str(_instance_defs.get(instance_id, ""))


## zone_total_reader（Satisfaction 依赖）：经 ZoneRules 纯函数评分当前
## 布局，返回该 instance 的 total 分量。GridStateReader 即 _grid。
func _zone_reader() -> Callable:
	return func(instance_id: int) -> float:
		var scores: Dictionary = _zone_rules.evaluate(_grid, _catalog)
		var entry: Dictionary = scores.get(instance_id, {})
		return float(entry.get("total", 0.0))


# === 第 2 层：presentation（heatmap / access-blocked / glyph overlay） ===

func _assemble_presentation() -> void:
	_member_sprites = MemberSpriteScript.new()

	_heatmap = HeatmapLayerScript.new()
	_heatmap.init(_cong, _grid, CELL_SIZE)
	add_child(_heatmap)

	_access_blocked = AccessBlockedLayerScript.new()
	_access_blocked.configure(_cong, _grid, CELL_SIZE)
	add_child(_access_blocked)

	_glyph_layer = CongestionGlyphLayerScript.new()
	_glyph_layer.init(_heatmap, _cong, _grid, CELL_SIZE)
	add_child(_glyph_layer)

	_tooltip = RejectionTooltipScript.new()
	_tooltip.init()

	_overlay_ctrl = CongestionOverlayControllerScript.new()
	_overlay_ctrl.init(_orch.placement_system, _heatmap, _access_blocked,
		_tooltip, _grid, CELL_SIZE)
	_overlay_ctrl._post_init()
	add_child(_overlay_ctrl)

	# Phase B v2：设备像素精灵工厂（前景主体）+ 吸附「咔哒」脉冲节点。
	_equip_art = EquipmentArtScript.new()
	_snap_pulse = SnapPulseScript.new()
	add_child(_snap_pulse)


# === 第 3 层：UI（HUD / 建造商店 / 选择工具） ===

func _assemble_ui() -> void:
	var placement = _orch.placement_system
	var selection = _orch.selection_system
	var sel_bridge = _orch.get_node("SelectionInputBridge")

	_shop = ShopScript.new()
	_shop.init(_catalog, _econ, placement)

	_arbitration = ModeArbitrationScript.new()
	_arbitration.init(selection)

	_palette = BuildShopPaletteScript.new()
	_palette.init(_catalog, _econ, _shop, placement, _arbitration)
	# BUILD-01 修复：Main 是 Node2D root，BOTTOM_WIDE 锚点 preset 在零尺寸父
	# 矩形下解析失败（rect 曾为 (0,-64)-(407,32)，屏幕外）。显式停靠到底部：
	# y = 视口高 - 条带高，铺满全宽。tile 可点击性/拖拽判定走 get_global_rect()，
	# 与布局无关。
	_palette.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_palette.set_position(Vector2(0, UI_VIEWPORT_H - PALETTE_STRIP_H))
	_palette.set_size(Vector2(UI_VIEWPORT_W, PALETTE_STRIP_H))
	add_child(_palette)

	_hud = HudScript.new()
	_hud.init(_econ, _sat, _orch.time_system, _orch)
	# BUILD-02 修复：同 BUILD-01 —— FULL_RECT 锚点在 Node2D 父级下解析为零尺寸
	# （HUD root rect 曾为 (0,0,0,0)）。显式铺满视口：HUD 自身 MOUSE_FILTER_IGNORE
	# 不挡玩法区，其内部 TopBar 按自身 rect 锚定，全宽顶栏由此成立。
	_hud.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_hud.set_position(Vector2.ZERO)
	_hud.set_size(Vector2(UI_VIEWPORT_W, UI_VIEWPORT_H))
	add_child(_hud)

	_toolbar = SelectionToolbarScript.new()
	_toolbar.init(selection, sel_bridge, placement, _grid, CELL_SIZE)
	add_child(_toolbar)

	_cue = SelectionCueScript.new()
	_cue.init(selection, _grid, CELL_SIZE)
	add_child(_cue)

	# BUILD-03/04 修复：main._draw() 是设备/会员的唯一渲染路径，但此前只在
	# _initial_layout() 调用过一次 queue_redraw()，放置/出售/会员移动后画面
	# 永不刷新。信号驱动重绘：
	#   - grid_changed（place=commit / remove=sell 都会 emit，见 grid_system）
	#     → 设备上屏/下屏
	#   - tick_completed（S2，10Hz）→ 会员位置/状态随 tick 移动
	# queue_redraw() 是幂等合并的（一帧内多次调用只重绘一次），headless 下
	# 不渲染、调用无害。
	_grid.grid_changed.connect(func(_fp: Array, _ac: Array) -> void: queue_redraw())
	_orch.tick_completed.connect(func(_tick: int) -> void: queue_redraw())

	# Phase B v2：吸附「咔哒」触发 + 幽灵/脉冲重绘。
	# preview_validity_changed(valid=true) 且 anchor 变化 → 合法格吸附脉冲。
	# 同 anchor 重复触发不重放（_last_snap_cell 去重，art-bible §9 无闪烁）。
	placement.preview_validity_changed.connect(_on_preview_validity_changed)


# === 初始布局：预置设备（clumped，让 congestion 开场即有表现） ===

func _initial_layout() -> void:
	var placement = _orch.placement_system
	placement.placement_committed.connect(_on_placed)
	_drag_drop(placement, "treadmill", Vector2i(2, 2))
	_drag_drop(placement, "bike", Vector2i(2, 5))
	_drag_drop(placement, "treadmill", Vector2i(6, 3))
	_drag_drop(placement, "bench_press", Vector2i(1, 7))
	_drag_drop(placement, "yoga_mat", Vector2i(9, 2))
	queue_redraw()


## preview_validity_changed handler（S 扩展，Phase B v2）：
##   - valid=true 且 anchor 是新的 → 吸附「咔哒」脉冲（视觉，无音频）
##   - 任意 validity 变化 → queue_redraw（幽灵合法/非法 tint 跟随拖拽）
func _on_preview_validity_changed(valid: bool) -> void:
	queue_redraw()
	if not valid:
		return
	var placement = _orch.placement_system
	if placement == null or not placement.is_dragging():
		return
	var anchor: Vector2i = placement.get_drag_anchor()
	if anchor == _last_snap_cell:
		return
	_last_snap_cell = anchor
	if _snap_pulse != null:
		_snap_pulse.pulse_at(_grid.grid_to_world_center(anchor, CELL_SIZE))


## 通过 PlacementSystem 完整拖放流程放置一台设备（走真实信号链：
## placement_committed → SelectionSystem 映射重建 / Shop 扣款路径）。
func _drag_drop(placement, equipment_id: String, anchor: Vector2i) -> void:
	placement.begin_drag(equipment_id)
	placement.on_mouse_moved(anchor)
	placement.on_drop()


## S3 placement_committed → 维护 resolver 数据源（instance_id -> equipment_id）。
func _on_placed(instance_id: int, equipment_id: String, _footprint_cells: Array) -> void:
	_instance_defs[instance_id] = equipment_id


# === 渲染（窗口模式；headless 下引擎不调用，防御性 null 检查） ===

func _process(delta: float) -> void:
	if _smoke:
		_smoke_frame += 1
		if _smoke_frame >= SMOKE_FRAMES:
			_smoke_report()
			get_tree().quit(0)


func _draw() -> void:
	if _grid == null or _cong == null:
		return
	_draw_floor_zones()
	_draw_grid_lines()
	# 2.5D 空间层级（art-bible-25d §1）：会员中景 / 设备前景 —— 设备画在会员
	# 之后（前景层），幽灵画在最上（活动决策预览，Core Rule 7 优先级最高）。
	_draw_members()
	_draw_equipment()
	_draw_placement_ghost()


## 地板三区域色块（art-bible §6：功能区用色块 + 柔和描边区分，分区一眼可读）。
## 数据源：palette.gd ZONE_RECTS / ZONE_COLORS（单一来源，Phase B/C 复用）。
## 画在最底层（先于网格线/设备/会员），不遮挡任何上层元素。
func _draw_floor_zones() -> void:
	for zone: String in Palette.ZONE_RECTS:
		var rect: Rect2i = Palette.ZONE_RECTS[zone]
		var px_rect := Rect2i(rect.position * CELL_SIZE, rect.size * CELL_SIZE)
		draw_rect(px_rect, Palette.ZONE_COLORS[zone], true)
		draw_rect(px_rect, Palette.ZONE_BORDER, false, 1.0)


func _draw_grid_lines() -> void:
	for x in GRID_W + 1:
		draw_line(Vector2(x * CELL_SIZE, 0), Vector2(x * CELL_SIZE, GRID_H * CELL_SIZE),
			Palette.GRID_LINE, 1.0)
	for y in GRID_H + 1:
		draw_line(Vector2(0, y * CELL_SIZE), Vector2(GRID_W * CELL_SIZE, y * CELL_SIZE),
			Palette.GRID_LINE, 1.0)


## 设备渲染（Phase B v2）—— 前景像素主体（art-bible-25d §2）。
##
## 每台设备：
##   1. 脚下大暗面（EQUIP_SHADOW 半透明深色块，替代旧纯灰 footprint；25d §2 阴影）
##   2. 像素精灵纹理（EquipmentArt 程序化 ImageTexture，32×32/cell，Nearest 全局）
##   3. access cell 用 Butter 高亮（art-bible §7 拖放反馈；§4 Butter 锚点 ~10%）
##
## 语义色：equipment_id → def.zone_membership → ZONE_COLORS（cardio→Sky /
## strength→Sage / flex→Peach），描边 Soft Charcoal（art-bible §4）。纹理按
## (id, zone, rotation) 全量缓存，运行时零重建。
func _draw_equipment() -> void:
	for inst in _grid.get_placed_instances():
		var fp_rect := _footprint_rect(inst.footprint_cells)
		if fp_rect.size.x <= 0 or fp_rect.size.y <= 0:
			continue
		# 1) 脚下大暗面（半透明深色块；偏移 2px 向下，读作地板阴影而非轮廓）。
		var shadow_rect := fp_rect.grow(3)
		shadow_rect.position.y += 2
		draw_rect(shadow_rect, Palette.EQUIP_SHADOW, true)

		# 2) 像素精灵（前景主体）。
		var eq_id: String = str(_instance_defs.get(inst.instance_id, ""))
		var zone: String = _zone_of(eq_id)
		var tex: ImageTexture = _equip_art.texture_for(eq_id, zone, inst.rotation)
		if tex != null:
			draw_texture_rect(tex, Rect2(fp_rect), false)
		else:
			# 兜底（未知 equipment_id）：画 Soft Charcoal 剪影块，绝不崩溃。
			draw_rect(fp_rect, Palette.CHARCOAL, false, 2.0)

		# 3) access cell：Butter 高亮（柔和填充 + 描边，非刺眼）。
		for c in inst.access_cells:
			_draw_access_cell(c)


## access cell 高亮：半透明 Butter 填充 + Butter 描边 + 中央实心 Butter 菱形。
## art-bible §7「合法位置柔和高亮」的静态版本 —— 柔和，不刺眼，无闪烁；
## 菱形是「图标+颜色双通道」的色盲安全形状（accessibility 通道，不单靠颜色）。
func _draw_access_cell(c: Vector2i) -> void:
	var rect := Rect2i(c * CELL_SIZE, Vector2i(CELL_SIZE, CELL_SIZE))
	var fill := Palette.BUTTER
	fill.a = 0.25
	draw_rect(rect, fill, true)
	var border := Palette.BUTTER
	border.a = 0.85
	draw_rect(rect, border, false, 1.0)
	# 实心菱形（Butter，半径 ~5px）：采样点稳定命中，读作「可用」锚点。
	var diamond := Palette.BUTTER
	diamond.a = 0.95
	var cx := rect.position.x + CELL_SIZE / 2.0
	var cy := rect.position.y + CELL_SIZE / 2.0
	var r := 5.0
	var pts := PackedVector2Array([
		Vector2(cx, cy - r),
		Vector2(cx + r, cy),
		Vector2(cx, cy + r),
		Vector2(cx - r, cy),
	])
	draw_colored_polygon(pts, diamond)


## 放置预览幽灵（art-bible §7 拖放反馈）：
##   - 合法位置：柔和高亮（PLACEMENT_OK_TINT 半透明白/Sage）+ Butter 网格吸附描边
##   - 非法位置：Dusty Rose #E0A0A0 柔和警示（PLACEMENT_BAD_TINT，绝不刺眼红）
## 画在最上（活动决策预览，Core Rule 7）；无 drag 时无开销（is_dragging O(1)）。
func _draw_placement_ghost() -> void:
	if _orch == null or _orch.placement_system == null:
		return
	var placement = _orch.placement_system
	if not placement.is_dragging():
		return
	# 双幽灵抑制（GDD Core Rule 4 / ModeArbitration）：有选中物时不画新放置幽灵。
	if _arbitration != null and _arbitration.is_ghost_suppressed():
		return
	if not placement.get_drag_has_previewed():
		return  # 尚未进入任何格 —— 不画 ZERO 幽灵
	var eq_id: String = placement.get_drag_equipment_id()
	if eq_id == "":
		return
	var def = _catalog.get_definition(eq_id)
	if def == null:
		return
	var anchor: Vector2i = placement.get_drag_anchor()
	var rotation: int = placement.get_drag_rotation()
	var tf = _grid.get_transformed_cells(def.footprint_cells, def.access_cells, anchor, rotation)
	var rect := _cells_rect(tf.footprint_cells)
	if rect.size.x <= 0 or rect.size.y <= 0:
		return
	var valid: bool = placement.get_drag_preview_valid()
	var tint: Color = Palette.PLACEMENT_OK_TINT if valid else Palette.PLACEMENT_BAD_TINT
	draw_rect(rect, tint, true)
	# 精灵本体（半透明幽灵，让玩家看清要放什么）——先于描边，描边永远可读。
	var zone: String = _zone_of(eq_id)
	var tex: ImageTexture = _equip_art.texture_for(eq_id, zone, rotation)
	if tex != null:
		var ghost_col := Color(1, 1, 1, 0.65)
		draw_texture_rect(tex, Rect2(rect), false, ghost_col)
	# 网格吸附描边（画在最上，覆盖幽灵本体）：合法 → Butter（锚点高亮）；
	# 非法 → Dusty Rose（柔和警示，绝不刺眼红）。
	var edge: Color = Palette.BUTTER if valid else Palette.ROSE
	edge.a = 0.9
	draw_rect(rect, edge, false, 2.0)
	for c in tf.access_cells:
		_draw_access_cell(c)


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
	var size := (max_c - min_c + Vector2i.ONE) * CELL_SIZE
	return Rect2i(min_c * CELL_SIZE, size)


## equipment_id → zone_membership[0]（语义色键，与 palette.ZONE_COLORS 对齐）。
## 未知 id 返回 ""（EquipmentArt 兜底 FALLBACK_ZONE）。
func _zone_of(eq_id: String) -> String:
	if eq_id == "":
		return ""
	var def = _catalog.get_definition(eq_id)
	if def == null or def.zone_membership.is_empty():
		return ""
	return str(def.zone_membership[0])


func _draw_members() -> void:
	if _member == null or _member_sprites == null:
		return
	# Phase C v2：2.5D 像素小人（32×32，1:1 绘制，状态双通道）。
	# 颜色通道：walking≈Sky / queue·using≈Peach / leaving≈灰（色盲安全，
	# 与形状/姿态通道叠加）；姿态通道：walk 摆臂迈步 / idle 站立微晃 /
	# use 用力泵（帧按 tick 奇偶交替，8-12fps 观感，见 member_sprite.gd）。
	var tick: int = _orch.get_tick_count()
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
		draw_texture(tex, Vector2(cell.x * CELL_SIZE, cell.y * CELL_SIZE))
	# 清理已离场成员的朝向缓存（防止字典无限增长）
	for member_id in _member_facing.keys():
		if not alive.has(member_id):
			_member_facing.erase(member_id)
			_member_last_cell.erase(member_id)


## 由 cell 移动推断朝向（presentation 层，纯绘制用；横向位移为 0 时保持
## 上次朝向 —— QUEUEING/USING 成员静止，姿态已表达状态，朝向仅跟随入场方向）。
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


# === --smoke 报告 ===

func _smoke_report() -> void:
	var members := 0
	var state_counts: Dictionary = {}
	for m in _member.members:
		if m is Dictionary and m.has("member_id"):
			members += 1
		if m is Dictionary and m.has("state"):
			var st := str(m["state"])
			state_counts[st] = int(state_counts.get(st, 0)) + 1
	print("=".repeat(56))
	print("  PLAYABLE BUILD SMOKE: assembly verified")
	print("  tick_count=%d balance=%d members=%d placed=%d palette_tiles=%d" % [
		_orch.get_tick_count(),
		_econ.balance,
		members,
		_grid.get_placed_instances().size(),
		_palette.get_tile_count(),
	])
	print("  member_states=%s" % [str(state_counts)])
	print("  sprites_ready=%s" % [_member_sprites != null])
	print("  hud_initialized=%s shop_initialized=%s arbitration=%s toolbar=%s cue=%s" % [
		_hud != null, _shop != null, _arbitration != null, _toolbar != null, _cue != null,
	])
	print("  bridges=%s/%s" % [
		_orch.get_node_or_null("PlacementInputBridge") != null,
		_orch.get_node_or_null("SelectionInputBridge") != null,
	])
	print("  RESULT: PASS (no crash over %d frames)" % SMOKE_FRAMES)
	print("=".repeat(56))
