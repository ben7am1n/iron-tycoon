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

# === 组装状态 ===
var _instance_defs: Dictionary = {}  # instance_id -> equipment_id（resolver 数据源）
var _smoke := false
var _smoke_frame := 0


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


# === 初始布局：预置设备（clumped，让 congestion 开场即有表现） ===

func _initial_layout() -> void:
	var placement = _orch.placement_system
	placement.placement_committed.connect(_on_placed)
	_drag_drop(placement, "treadmill", Vector2i(2, 2))
	_drag_drop(placement, "bike", Vector2i(2, 5))
	_drag_drop(placement, "treadmill", Vector2i(6, 3))
	queue_redraw()


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
	_draw_grid_lines()
	_draw_equipment()
	_draw_members()


func _draw_grid_lines() -> void:
	for x in GRID_W + 1:
		draw_line(Vector2(x * CELL_SIZE, 0), Vector2(x * CELL_SIZE, GRID_H * CELL_SIZE),
			Color(0.25, 0.25, 0.3), 1.0)
	for y in GRID_H + 1:
		draw_line(Vector2(0, y * CELL_SIZE), Vector2(GRID_W * CELL_SIZE, y * CELL_SIZE),
			Color(0.25, 0.25, 0.3), 1.0)


func _draw_equipment() -> void:
	for inst in _grid.get_placed_instances():
		for c in inst.footprint_cells:
			draw_rect(Rect2i(c * CELL_SIZE, Vector2i(CELL_SIZE, CELL_SIZE)),
				Color(0.5, 0.5, 0.55))
		for c in inst.access_cells:
			draw_rect(Rect2i(c * CELL_SIZE, Vector2i(CELL_SIZE, CELL_SIZE)),
				Color(0.8, 0.6, 0.2))


func _draw_members() -> void:
	for m in _member.members:
		if not (m is Dictionary) or not m.has("cell"):
			continue
		var cell: Vector2 = m["cell"]
		var col := Color(0.3, 0.8, 0.9)
		if m.has("state") and (str(m["state"]) == "QUEUEING" or str(m["state"]) == "USING"):
			col = Color(0.9, 0.6, 0.3)
		draw_circle(Vector2(cell.x * CELL_SIZE + CELL_SIZE / 2.0,
			cell.y * CELL_SIZE + CELL_SIZE / 2.0), 8.0, col)


# === --smoke 报告 ===

func _smoke_report() -> void:
	var members := 0
	for m in _member.members:
		if m is Dictionary and m.has("member_id"):
			members += 1
	print("=".repeat(56))
	print("  PLAYABLE BUILD SMOKE: assembly verified")
	print("  tick_count=%d balance=%d members=%d placed=%d palette_tiles=%d" % [
		_orch.get_tick_count(),
		_econ.balance,
		members,
		_grid.get_placed_instances().size(),
		_palette.get_tile_count(),
	])
	print("  hud_initialized=%s shop_initialized=%s arbitration=%s toolbar=%s cue=%s" % [
		_hud != null, _shop != null, _arbitration != null, _toolbar != null, _cue != null,
	])
	print("  bridges=%s/%s" % [
		_orch.get_node_or_null("PlacementInputBridge") != null,
		_orch.get_node_or_null("SelectionInputBridge") != null,
	])
	print("  RESULT: PASS (no crash over %d frames)" % SMOKE_FRAMES)
	print("=".repeat(56))
