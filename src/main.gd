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
#   4. 构造 presentation 层（WorldCanvas / HeatmapLayer / AccessBlockedLayer /
#      CongestionGlyphLayer）与 UI 层（Hud / BuildShopPalette / Shop /
#      ModeArbitration / SelectionToolbar / SelectionCue / 拖拽反馈控制器）
#   5. 渲染架构（V3 §2 低分辨率世界管线）：世界画在 SubViewport 426×240
#      （WorldRoot scale 0.75，世界像素空间 416×320），TextureRect
#      nearest 放大到 1280×720；UI 挂独立 CanvasLayer（UICanvas，高分辨率），
#      世界与 UI 分辨率分离（V3 §2 禁止：UI 可更高分辨率，游戏世界不能）。
#   6. 初始布局：预置 3 台设备让 playtest 开箱即有内容可看
#   7. --smoke 模式：headless 下跑 N 帧验证组装无崩溃，打印状态后退出
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
const WorldCanvasScript := preload("res://src/presentation/world_canvas.gd")
const WorldScale := preload("res://src/presentation/world_scale.gd")
const Proj2D := preload("res://src/presentation/oblique_projection.gd")
const FloorArtScript := preload("res://src/presentation/floor_art.gd")
const EnvironmentArtScript := preload("res://src/presentation/environment_art.gd")
const StructureArtScript := preload("res://src/presentation/structure_art.gd")
const LightingLayerScript := preload("res://src/presentation/lighting_layer.gd")
const AmbientFxScript := preload("res://src/presentation/ambient_fx.gd")
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
## 底部建造商店条带高度 = PaletteTile 最小尺寸 88×88（整块 tile 可见，
## 不会被 88px 条带裁切）。V3 §15（P0-2 UI 降权）：96→88 —— 减小常驻 UI
## 占幅，底部多露出 8px 世界内容（门禁 FAIL：底部购买栏 + 顶部状态栏组合
## 像 Web dashboard）。
const PALETTE_STRIP_H := 88

# === V3 §2 低分辨率世界管线（SubViewport → nearest 放大） ===
## 世界逻辑画布（viewport 像素空间）：426×240（V3 §2 建议值之一）。
## 426→1280 水平放大 ≈3.0047，240→720 垂直放大 = 3.0 —— 近乎方形像素，
## nearest 采样下 stair-step 真实（非高清抗锯齿）。
const WORLD_VIEWPORT_W := 426
const WORLD_VIEWPORT_H := 240
## 世界像素空间（416×320，CELL_SIZE=32）→ viewport 空间的统一缩放。
## 32px cell → 24 viewport px（整数倍）；投影后画布（V3.1 P1 oblique
## bounds ≈ -10.8..528 × -86.9..198.4，R1 修正投影后总高 285.3）经 scale
## 0.75 恰好适配 426×240。单一来源：src/presentation/world_scale.gd
## （含描边宽度补偿常量）。
const WORLD_SCALE := WorldScale.WORLD_SCALE
## 世界原点在 viewport 中的偏移（V3.1 P1：由 oblique 投影 bounds 计算 ——
## 墙顶在 y<0，bounds.position 为负，偏移必须把这些部分拉回屏幕内）：
##   offset = (viewport - bounds.size*0.75)/2 - bounds.position*0.75
##         = ((426,240) - (538.8,285.3)*0.75)/2 + (8.1, 65.175)
##         = (10.95, 13.0125) + (8.1, 65.175) = (19.05, 78.1875)
## V3.1 R1：HEIGHT_SCALE 0.62→0.79 使墙顶更高（min_y -68.2→-86.9），
## FLOOR_SCALE 0.78→0.62 使地板更压缩（max_y 249.6→198.4）—— 画布总高
## 317.8→285.3，偏移 y 由 51.975 重算为 78.1875。
## 与 Proj2D.viewport_offset() 同源（main._ready 冒烟断言复核）。
const WORLD_VIEWPORT_OFFSET := Vector2(19.05, 78.1875)
## viewport → 屏幕（1280×720）的非等比放大系数。
const SCREEN_PER_VIEWPORT_X := 1280.0 / 426.0
const SCREEN_PER_VIEWPORT_Y := 720.0 / 240.0
## 世界→屏幕的 UI 锚定参数（供 SelectionCue/SelectionToolbar 注入；V3.1 P1
## 起 world→screen 走 oblique 投影，以下为「无投影注入」的兜底换算）：
##   世界 (0,0) 的屏幕坐标 ≈ (57.2, 234.6)；一个 world cell 的屏幕尺寸
##   ≈ (72.1, 44.6)（x 不压缩，y 经 FLOOR_SCALE 0.62 压缩）。
const GRID_SCREEN_ORIGIN := Vector2(
	WORLD_VIEWPORT_OFFSET.x * SCREEN_PER_VIEWPORT_X,
	WORLD_VIEWPORT_OFFSET.y * SCREEN_PER_VIEWPORT_Y)
const GRID_SCREEN_CELL := Vector2(
	float(CELL_SIZE) * WORLD_SCALE * SCREEN_PER_VIEWPORT_X,
	float(CELL_SIZE) * Proj2D.FLOOR_SCALE * WORLD_SCALE * SCREEN_PER_VIEWPORT_Y)

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
var _floor_art
var _env_art
var _structure_art
var _lighting
var _ambient_fx

# === V3 §2 低分辨率世界管线引用 ===
var _world_viewport   # SubViewport：低分辨率世界画布（426×240）
var _world_root       # Node2D：世界像素空间 → viewport 空间（scale 0.75）
var _world_canvas     # WorldCanvas：世界绘制（地板/网格/会员/设备/幽灵）
var _world_display    # TextureRect：nearest 放大到窗口
var _ui_canvas        # CanvasLayer：高分辨率 UI 层（1280×720）

# === 组装状态 ===
var _instance_defs: Dictionary = {}  # instance_id -> equipment_id（resolver 数据源）
var _smoke := false
var _smoke_frame := 0

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


# === 第 2 层：presentation（V3 §2 低分辨率世界 + heatmap / access-blocked / glyph） ===

func _assemble_presentation() -> void:
	_member_sprites = MemberSpriteScript.new()
	_equip_art = EquipmentArtScript.new()
	# Phase 5：V3 §1 地板材质 + V3 §12 环境装饰（单一来源 world_layout.gd）。
	_floor_art = FloorArtScript.new()
	_floor_art.init(GRID_W, GRID_H, CELL_SIZE)
	_env_art = EnvironmentArtScript.new()
	# Phase 2：V3 §3/§4/§13 结构层（立柱/前台/储物柜/镜子/空调/墙钟/通风口/
	# 吊灯/管道/踢脚线/电线槽/毛巾架 —— 与 Phase 5 装饰并存，STRUCTURES 表
	# 提供 §13 密度分类）。
	_structure_art = StructureArtScript.new()

	# ModeArbitration（build/select 仲裁，GDD Core Rule 4）在 WorldCanvas 之前
	# 构造 —— WorldCanvas 的幽灵渲染需要 is_ghost_suppressed()（见 init 注入）。
	_arbitration = ModeArbitrationScript.new()
	_arbitration.init(_orch.selection_system)

	# --- V3 §2：低分辨率世界管线（SubViewport → nearest 放大） ---
	# WorldRoot 承载整个 WORLD 层（世界像素空间 416×320，CELL_SIZE=32），
	# scale 0.75 落到 426×240 viewport（32px cell → 24 viewport px，整数倍）。
	# 世界所有绘制（含 presentation 节点）都在 WORLD 层内 —— 统一 pixel space。
	_world_viewport = SubViewport.new()
	_world_viewport.name = "WorldViewport"
	_world_viewport.size = Vector2i(WORLD_VIEWPORT_W, WORLD_VIEWPORT_H)
	_world_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_world_viewport.handle_input_locally = false
	add_child(_world_viewport)

	_world_root = Node2D.new()
	_world_root.name = "WorldRoot"
	_world_root.position = WORLD_VIEWPORT_OFFSET
	_world_root.scale = Vector2(WORLD_SCALE, WORLD_SCALE)
	_world_viewport.add_child(_world_root)

	# WorldCanvas：世界绘制节点（旧 main.gd 高清 draw_rect 世界路径的迁移目标；
	# V3 §2 禁止在高清画布直接绘制世界）。会员动画 tick 经 tick_provider 注入。
	_world_canvas = WorldCanvasScript.new()
	_world_canvas.name = "WorldCanvas"
	_world_canvas.init(_grid, _catalog, _member, _member_sprites, _equip_art,
		_orch.placement_system, _arbitration, _resolver(),
		func() -> int: return _orch.get_tick_count(), CELL_SIZE,
		_floor_art, _env_art, _structure_art)
	# V3 §14 hover 数据源：根 viewport 鼠标 → 世界坐标 → 网格 cell → occupant。
	# presentation 层状态，O(1) 轮询（WorldCanvas._poll_hover），无寻路工作。
	_world_canvas.set_hover_provider(func() -> int:
		var cell: Vector2i = _grid.world_to_grid(_screen_to_world(get_viewport().get_mouse_position()), CELL_SIZE)
		if not _grid.is_in_bounds(cell):
			return -1
		return _grid.get_occupant_id(cell)
	)
	_world_root.add_child(_world_canvas)

	# Phase 5：V3 §6 方向光 + 氛围层（世界像素空间，画在 WorldCanvas 之上）。
	# 热光池 / 墙边暗角 / 窗口斜向光 / 设备屏幕 emissive 辉光 —— 确定性烘焙
	# 像素叠加，不做真实 3D PBR（V3 §6 IMPORTANT）。
	_lighting = LightingLayerScript.new()
	_lighting.name = "LightingLayer"
	_lighting.z_index = 1
	_lighting.init(_grid, _resolver(),
		func() -> int: return _orch.get_tick_count())
	_world_root.add_child(_lighting)

	# Phase 5：V3 §9 微型动态（光尘/汗滴/传送带/飞轮/杯闪）—— 克制数量。
	_ambient_fx = AmbientFxScript.new()
	_ambient_fx.name = "AmbientFx"
	_ambient_fx.z_index = 2
	_ambient_fx.init(_member, _grid, _resolver(),
		func() -> int: return _orch.get_tick_count())
	_world_root.add_child(_ambient_fx)

	# WORLD 层 presentation 节点（统一低分辨率 pixel space，随 WorldRoot 缩放）。
	_heatmap = HeatmapLayerScript.new()
	_heatmap.init(_cong, _grid, CELL_SIZE)
	_world_root.add_child(_heatmap)

	_access_blocked = AccessBlockedLayerScript.new()
	_access_blocked.configure(_cong, _grid, CELL_SIZE)
	_world_root.add_child(_access_blocked)

	_glyph_layer = CongestionGlyphLayerScript.new()
	_glyph_layer.init(_heatmap, _cong, _grid, CELL_SIZE)
	_world_root.add_child(_glyph_layer)

	_tooltip = RejectionTooltipScript.new()
	_tooltip.init()

	# 拖拽反馈控制器（UI 层 —— 在 _assemble_ui 中挂到 UICanvas；世界→屏幕
	# 映射随后注入，见 _assemble_ui）。
	_overlay_ctrl = CongestionOverlayControllerScript.new()
	_overlay_ctrl.init(_orch.placement_system, _heatmap, _access_blocked,
		_tooltip, _grid, CELL_SIZE)
	_overlay_ctrl._post_init()

	# Phase B v2：吸附「咔哒」脉冲节点（世界层 —— 脉冲坐标是世界空间）。
	_snap_pulse = SnapPulseScript.new()
	_world_root.add_child(_snap_pulse)

	# 世界显示：TextureRect 以 NEAREST 滤镜把 426×240 视口贴图放大到 1280×720。
	# 像素 stair-step 由此产生（真实低分辨率像素，非高清抗锯齿 —— V3 §2）。
	_world_display = TextureRect.new()
	_world_display.name = "WorldDisplay"
	_world_display.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_world_display.stretch_mode = TextureRect.STRETCH_SCALE
	_world_display.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_world_display.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_world_display.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_world_display.position = Vector2.ZERO
	_world_display.size = Vector2(UI_VIEWPORT_W, UI_VIEWPORT_H)
	# 显式类型：_world_viewport 是未类型化引用，get_texture() 返回 Variant，
	# `:=` 推断失败（4.7.1 项目 pitfall，显式 : Texture2D）。
	var viewport_tex: Texture2D = _world_viewport.get_texture()
	if viewport_tex != null:
		_world_display.texture = viewport_tex
	add_child(_world_display)


# === 第 3 层：UI（HUD / 建造商店 / 选择工具）—— 高分辨率 CanvasLayer ===

func _assemble_ui() -> void:
	var placement = _orch.placement_system
	var selection = _orch.selection_system
	var sel_bridge = _orch.get_node("SelectionInputBridge")

	# V3 §2：UI 与 WORLD 分辨率分离 —— 全部 UI 挂独立 CanvasLayer（1280×720
	# 高分辨率），不受 SubViewport 低分辨率影响（禁止：UI 更高分辨率可以，
	# 游戏世界不能）。CanvasLayer 的 transform 为单位阵，子 Control 锚点按
	# 根 viewport 解析 —— 与 BUILD-01/02 的显式停靠兼容。
	_ui_canvas = CanvasLayer.new()
	_ui_canvas.name = "UICanvas"
	_ui_canvas.layer = 10
	add_child(_ui_canvas)

	_shop = ShopScript.new()
	_shop.init(_catalog, _econ, placement)

	_palette = BuildShopPaletteScript.new()
	# V3 §10：底部购买栏显示设备 pixel sprite 缩略图（非图标/非占位符）——
	# 注入 EquipmentArt，tile 用设备精灵纹理做缩略图（NEAREST，场景物件同源）。
	_palette.init(_catalog, _econ, _shop, placement, _arbitration, _equip_art)
	# BUILD-01 修复：Main 是 Node2D root，BOTTOM_WIDE 锚点 preset 在零尺寸父
	# 矩形下解析失败（rect 曾为 (0,-64)-(407,32)，屏幕外）。显式停靠到底部：
	# y = 视口高 - 条带高，铺满全宽。tile 可点击性/拖拽判定走 get_global_rect()，
	# 与布局无关。
	_palette.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_palette.set_position(Vector2(0, UI_VIEWPORT_H - PALETTE_STRIP_H))
	_palette.set_size(Vector2(UI_VIEWPORT_W, PALETTE_STRIP_H))
	_ui_canvas.add_child(_palette)

	_hud = HudScript.new()
	_hud.init(_econ, _sat, _orch.time_system, _orch)
	# BUILD-02 修复：同 BUILD-01 —— FULL_RECT 锚点在 Node2D 父级下解析为零尺寸
	# （HUD root rect 曾为 (0,0,0,0)）。显式铺满视口：HUD 自身 MOUSE_FILTER_IGNORE
	# 不挡玩法区，其内部 TopBar 按自身 rect 锚定，全宽顶栏由此成立。
	_hud.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_hud.set_position(Vector2.ZERO)
	_hud.set_size(Vector2(UI_VIEWPORT_W, UI_VIEWPORT_H))
	_ui_canvas.add_child(_hud)

	# 世界锚定 UI 注入屏幕空间网格参数（V3 §2 世界→屏幕换算）：cell_size 改为
	# 屏幕空间 float（≈72.11px），grid_origin 为世界 (0,0) 的屏幕坐标 ——
	# toolbar/cue 的 footprint 矩形由此精确对齐低分辨率世界的像素格。
	_toolbar = SelectionToolbarScript.new()
	_toolbar.init(selection, sel_bridge, placement, _grid, GRID_SCREEN_CELL,
		{}, GRID_SCREEN_ORIGIN, Vector2(UI_VIEWPORT_W, UI_VIEWPORT_H),
		_world_to_screen)
	_ui_canvas.add_child(_toolbar)

	_cue = SelectionCueScript.new()
	_cue.init(selection, _grid, GRID_SCREEN_CELL, {}, GRID_SCREEN_ORIGIN,
		_world_to_screen)
	_ui_canvas.add_child(_cue)

	# 拖拽反馈控制器：tooltip 绘制在世界锚定位置 → 注入 world→screen 映射。
	_overlay_ctrl.set_world_to_screen(_world_to_screen)
	_ui_canvas.add_child(_overlay_ctrl)

	# BUILD-03/04 修复：世界绘制已迁至 WorldCanvas（V3 §2）。重绘信号：
	#   - grid_changed（place=commit / remove=sell）→ WorldCanvas 内部已接
	#   - tick_completed（S2，10Hz）→ 会员位置/状态随 tick 移动；Phase 5 的
	#     LightingLayer（发光闪烁）与 AmbientFx（光尘/传送带/飞轮/汗滴）也
	#     由 tick 驱动 —— 一并 queue_redraw（幂等合并，headless 下无害）。
	#   - preview_validity_changed → 幽灵合法/非法 tint 跟随拖拽
	_orch.tick_completed.connect(
		func(_tick: int) -> void: _world_canvas.queue_redraw())
	_orch.tick_completed.connect(
		func(_tick: int) -> void:
			if _lighting != null:
				_lighting.queue_redraw())
	_orch.tick_completed.connect(
		func(_tick: int) -> void:
			if _ambient_fx != null:
				_ambient_fx.queue_redraw())
	placement.preview_validity_changed.connect(
		func(_valid: bool) -> void: _world_canvas.queue_redraw())

	# Phase B v2：吸附「咔哒」触发 + 幽灵/脉冲重绘。
	# preview_validity_changed(valid=true) 且 anchor 变化 → 合法格吸附脉冲。
	# 同 anchor 重复触发不重放（_last_snap_cell 去重，art-bible §9 无闪烁）。
	placement.preview_validity_changed.connect(_on_preview_validity_changed)

	# 输入桥接（V3 §2）：世界已进 SubViewport + 缩放，屏幕坐标 ≠ 世界坐标。
	# 注入 screen→world 映射（世界坐标再经 grid.world_to_grid(cell_size=32)
	# 换算成 cell —— 数据层 GridSystem 保持不变）。
	_orch.get_node("PlacementInputBridge").set_screen_to_world(_screen_to_world)
	sel_bridge.set_screen_to_world(_screen_to_world)


# === 初始布局：预置设备（clumped，让 congestion 开场即有表现） ===

func _initial_layout() -> void:
	var placement = _orch.placement_system
	placement.placement_committed.connect(_on_placed)
	_drag_drop(placement, "treadmill", Vector2i(2, 2))
	_drag_drop(placement, "bike", Vector2i(2, 5))
	_drag_drop(placement, "treadmill", Vector2i(6, 3))
	_drag_drop(placement, "bench_press", Vector2i(1, 7))
	_drag_drop(placement, "yoga_mat", Vector2i(9, 2))
	# 世界绘制已迁至 WorldCanvas；grid_changed 信号驱动其重绘（见 _assemble_ui）。


## preview_validity_changed handler（S 扩展，Phase B v2）：
##   - valid=true 且 anchor 是新的 → 吸附「咔哒」脉冲（视觉，无音频）
## 幽灵合法/非法 tint 跟随拖拽的重绘由 WorldCanvas 自己的连接负责。
func _on_preview_validity_changed(valid: bool) -> void:
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


# === 世界 ↔ 屏幕映射（V3 §2 低分辨率管线 + V3.1 P1 oblique 投影） ===
#
# 扁平世界像素空间（CELL_SIZE=32，416×320）→ oblique 投影（V3.1 P1：
# 地板剪切+压缩、墙/设备高度挤出）→ WorldRoot scale 0.75 → SubViewport
# （426×240）→ TextureRect nearest 放大（1280×720）。
#   屏幕坐标 = (proj(世界坐标, z) × WORLD_SCALE + WORLD_VIEWPORT_OFFSET) × 屏幕放大
# 输入桥接（screen→world）与 UI 世界锚定（world→screen）都走这里；数据层
# GridSystem.world_to_grid() 保持原语义（世界坐标 + cell_size=32）不动。
# 换算核心在 src/presentation/oblique_projection.gd（单一来源）。

## --smoke 运行驱动（headless 冒烟验证）：跑满 SMOKE_FRAMES 后打印报告退出。
func _process(_delta: float) -> void:
	if _smoke:
		_smoke_frame += 1
		if _smoke_frame >= SMOKE_FRAMES:
			_smoke_report()
			get_tree().quit(0)

## 屏幕坐标 → 扁平世界坐标（输入桥接：鼠标在根 viewport 的 1280×720
## 屏幕坐标；返回扁平世界坐标，供 grid.world_to_grid(cell_size=32)）。
func _screen_to_world(screen_pos: Vector2) -> Vector2:
	return Proj2D.screen_to_world(
		screen_pos, WORLD_VIEWPORT_OFFSET, WORLD_SCALE,
		Vector2(SCREEN_PER_VIEWPORT_X, SCREEN_PER_VIEWPORT_Y))

## 扁平世界坐标 → 屏幕坐标（世界锚定 UI：tooltip / cue / toolbar 的高分辨率
## 定位；可选 height_z —— 带高度的点（设备顶面/墙挂饰）投影到对应屏幕位）。
func _world_to_screen(world_pos: Vector2, height_z: float = 0.0) -> Vector2:
	return Proj2D.world_to_screen(
		world_pos, WORLD_VIEWPORT_OFFSET, WORLD_SCALE,
		Vector2(SCREEN_PER_VIEWPORT_X, SCREEN_PER_VIEWPORT_Y), height_z)


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
	print("  sprites_ready=%s floor_art=%s env_art=%s structure_art=%s" % [
		_member_sprites != null, _floor_art != null, _env_art != null, _structure_art != null,
	])
	print("  lighting=%s ambient_fx=%s" % [_lighting != null, _ambient_fx != null])
	print("  hud_initialized=%s shop_initialized=%s arbitration=%s toolbar=%s cue=%s" % [
		_hud != null, _shop != null, _arbitration != null, _toolbar != null, _cue != null,
	])
	print("  bridges=%s/%s" % [
		_orch.get_node_or_null("PlacementInputBridge") != null,
		_orch.get_node_or_null("SelectionInputBridge") != null,
	])
	print("  RESULT: PASS (no crash over %d frames)" % SMOKE_FRAMES)
	print("=".repeat(56))
