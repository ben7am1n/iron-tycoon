## SelectionToolbar — the contextual Inspect / Upgrade / Move / Sell toolbar
## (selection-system epic, Story 004; TR-SEL-002; GDD Core Rule 3; UX spec
## design/ux/selection-ui.md — Zone B Contextual Toolbar).
##
## Renders four actions near the selected piece — NOT a blocking modal:
##   - Inspect — always available; opens the Equipment Info Panel (#17 — the
##     panel itself is out of scope; this story ships the button + the open
##     hook, emitted as inspect_requested)
##   - Move — hands off to PlacementSystem's relocate flow
##     (begin_relocate(instance_id)); SelectionSystem clears its own
##     selection the INSTANT Move is pressed (GDD Core Rule 3 — no
##     dual-ownership ambiguity); DISABLED during any active placement drag
##     (PlacementSystem.is_dragging() via the bridge's is_move_blocked())
##   - Sell — opens the bridge's 2s soft-confirm window (request_sell_confirm);
##     the button morphs to "Confirm sell +$X" (Butter) while pending, driven
##     by the bridge's sell_confirm_started/reverted signals (Story 003 state
##     machine rendered here); second click confirms (confirm_sell)
##   - Upgrade — A2 immediate deterministic purchase. Label shows next level
##     and cost; disabled when unaffordable or at max level.
##
## BRIDGE-DRIVEN (ADR-0005 decision summary): the SelectionInputBridge owns
## the sell-confirm window state and the Move-during-drag guard; this
## Control subscribes to the bridge's signals and calls its methods. It is
## pure presentation — selection state lives in SelectionSystem, drag state
## in PlacementSystem; the toolbar owns NO simulation state.
##
## SIGNAL CONSUMER CONTRACT (ADR-0005 S7 / SelectionSystem class doc):
##   select:   selection_changed.emit(instance_id, def, anchor, rotation)
##             — EXACTLY FOUR arguments
##   deselect: selection_changed.emit(null) — EXACTLY ONE argument
## The handler below declares 1..4 OPTIONAL params so it accepts both
## arities, and treats a null instance_id as deselect. NEVER tests
## truthiness of instance_id — 0 is a legal selected instance.
##
## ANCHORING (UX spec): anchored near the selection, offset to the nearest
## free side (never covering the piece; adapts at screen edges). This
## Control is a plain anchored Control, NOT container-packed (story Engine
## Note: toolbar is anchored, never inside a Container — no layout
## breaking, no 4.7 offset-transform need).
##
## ANIMATIONS (UX spec Transitions): enter fade/slide ~150ms, exit ~120ms
## fade; swap moves directly (~150ms, no intermediate deselect animation).
## Reduced-motion (config["reduced_motion"]): no animation, instant.
##
## HEADLESS TESTABILITY: buttons are real Button children built in _init();
## state is queryable (is_visible / is_move_disabled / get_sell_label /
## is_sell_pending / get_anchor_position). Tests drive pressed via the
## public on_*_pressed() methods and assert state, never pixels.
class_name SelectionToolbar extends PanelContainer

## preload aliases for cross-script references — the story's documented
## headless pattern (global class cache is editor-generated; preload works
## regardless).
const SelectionSystemScript := preload("res://src/systems/selection_system.gd")
const SelectionInputBridgeScript := preload("res://src/systems/selection_input_bridge.gd")
const PlacementSystemScript := preload("res://src/systems/placement_system.gd")
const GridSystemScript := preload("res://src/systems/grid_system.gd")

## Data-driven config seams (Control Manifest: gameplay values never
## hardcoded).
const CONFIG_REDUCED_MOTION := "reduced_motion"
const CONFIG_TOOLBAR_ENTER_DURATION := "toolbar_enter_duration"
const CONFIG_TOOLBAR_EXIT_DURATION := "toolbar_exit_duration"

## Enter/exit animation timings (UX spec Transitions): enter fade/slide in
## ~150 ms; exit ~120 ms fade. Data-driven, clamped to sane ranges.
const DEFAULT_ENTER_DURATION := 0.15
const DEFAULT_EXIT_DURATION := 0.12
const DURATION_MIN := 0.05
const DURATION_MAX := 0.5

## Button labels (UX spec Component Inventory; localization-ready).
const LABEL_INSPECT := "Inspect"
const LABEL_MOVE := "Move"
const LABEL_SELL := "Sell"
const LABEL_UPGRADE := "Upgrade"
const UPGRADE_PREFIX := "Upgrade L"
const UPGRADE_MAX_PREFIX := "Max L"
const SELL_CONFIRM_PREFIX := "Confirm sell +$"

## Art-bible palette (design/art/art-bible.md §4): Butter = money/highlight
## (the sell-confirm morph — GDD Core Rule 4: warm Butter, never alarm-red);
## Soft Charcoal = text/outline; Warm Cream = light text on dark panels.
const COLOR_BUTTER := Color("f5d97b")
const COLOR_WARM_CREAM := Color("f4e9d8")

# Phase D v2 现代 UI 皮肤（art-bible-25d-style §1/§2）—— 工具栏面板 =
# 深色半透明 + Butter 亮色描边 + 粗字体按钮。
# V3.1 返工 UI：面板改为 PixelPanel 手绘木纹像素平板（不规则边缘 + 材质
# cluster + 非等宽 Butter 断续描边）；按钮走 UiTheme 像素芯片主题。
const UiTheme := preload("res://src/ui/ui_theme.gd")
const PixelPanel := preload("res://src/ui/pixel_panel.gd")

## Gap (px) between the piece's footprint edge and the toolbar.
const ANCHOR_GAP_PX := 12

## Emitted when the player presses Inspect — the open hook for the
## Equipment Info Panel (#17, Vertical Slice — out of scope here; the button
## + this hook are the Story 004 deliverable). Arity 4, mirrors the S7
## select payload.
signal inspect_requested(instance_id: int, equipment_def: EquipmentDef, cell: Vector2i, rotation: int)

var _selection: SelectionSystemScript
var _bridge: SelectionInputBridgeScript
var _placement: PlacementSystemScript
var _grid: GridSystemScript
## 屏幕空间 cell 尺寸（V3 §2：世界已进 SubViewport + nearest 放大，UI 层
## 锚定用的 cell_size 是「世界 cell 的屏幕像素尺寸」；V3.1 P1 起为 Vector2
## （x 不压缩 / y 经 oblique FLOOR_SCALE 压缩 ≈72.11×56.16px）。兼容 float
## 注入（旧调用/单测注入 32 → 视作方形 (32,32)）。
var _cell_size: Vector2 = Vector2(32, 32)
var _grid_origin: Vector2 = Vector2.ZERO
var _viewport_size: Vector2 = Vector2(1280, 720)
## V3.1 P1：可选 world→screen 投影 Callable（oblique 剪切/压缩换算）。注入
## 后 footprint 矩形按投影后的 4 角 AABB 计算（与世界上屏位置精确对齐）；
## 未注入（旧调用/单测）回退 origin + cell*cell_size 均匀换算。
var _world_to_screen: Callable = Callable()
var _upgrade_system: Variant = null
var _economy: Variant = null
var _reduced_motion: bool = false
var _enter_duration: float = DEFAULT_ENTER_DURATION
var _exit_duration: float = DEFAULT_EXIT_DURATION

# === Selection payload (stored from selection_changed for Move/Inspect) ===
var _selected_instance_id: int = -1
var _selected_def: EquipmentDef = null
var _selected_cell: Vector2i = Vector2i.ZERO
var _selected_rotation: int = 0

## True while a piece is selected and the toolbar is shown.
var _active: bool = false

## Footprint pixel rect of the selection (grid space, pre grid_origin).
var _footprint_rect: Rect2 = Rect2()

## The active enter/exit tween (null when static).
var _anim_tween: Tween = null

## V3.1 返工 UI — 像素平板纹理状态（_draw 懒生成；尺寸变化时重建）。
## 工具栏尺寸由按钮行内容驱动（sell-confirm 变长会改变尺寸）。
const PLATE_TEXEL := 4
const PLATE_SEED := 0x71E_B4A
var _plate_texture_tex: ImageTexture = null
var _plate_texel_size: Vector2i = Vector2i.ZERO

# === Buttons (built in _init(), named for tests) ===
var _inspect_button: Button
var _move_button: Button
var _sell_button: Button
var _upgrade_button: Button

var _initialized: bool = false


## Two-phase init (ADR-0001 shape). Stores injected systems, applies the
## data-driven config, builds the button row, and subscribes with TYPED
## connections only (Control Manifest: string-based connects forbidden):
##   - SelectionSystem.selection_changed      → show/hide + re-anchor
##   - SelectionInputBridge.sell_confirm_started  → Sell button morphs
##   - SelectionInputBridge.sell_confirm_reverted → Sell button reverts
## Double-init is a loud no-op.
func init(
	selection: SelectionSystemScript,
	bridge: SelectionInputBridgeScript,
	placement: PlacementSystemScript,
	grid: GridSystemScript,
	cell_size: Variant,
	config: Dictionary = {},
	grid_origin: Vector2 = Vector2.ZERO,
	viewport_size: Vector2 = Vector2(1280, 720),
	world_to_screen: Callable = Callable(),
	upgrade_system: Variant = null,
	economy: Variant = null
) -> void:
	if _initialized:
		push_error("SelectionToolbar.init() called twice")
		return
	_initialized = true
	_selection = selection
	_bridge = bridge
	_placement = placement
	_grid = grid
	_cell_size = _as_cell_size(cell_size)
	_grid_origin = grid_origin
	_viewport_size = viewport_size
	_world_to_screen = world_to_screen
	_upgrade_system = upgrade_system
	_economy = economy
	_apply_config(config)
	_build_buttons()
	visible = false
	_active = false
	if selection != null and not selection.selection_changed.is_connected(_on_selection_changed):
		selection.selection_changed.connect(_on_selection_changed)
	if bridge != null:
		if not bridge.sell_confirm_started.is_connected(_on_sell_confirm_started):
			bridge.sell_confirm_started.connect(_on_sell_confirm_started)
		if not bridge.sell_confirm_reverted.is_connected(_on_sell_confirm_reverted):
			bridge.sell_confirm_reverted.connect(_on_sell_confirm_reverted)
	if _upgrade_system != null and not _upgrade_system.equipment_upgraded.is_connected(_on_equipment_upgraded):
		_upgrade_system.equipment_upgraded.connect(_on_equipment_upgraded)
	if _economy != null and not _economy.balance_changed.is_connected(_on_balance_changed):
		_economy.balance_changed.connect(_on_balance_changed)
	# Drag-state refresh is a lightweight per-frame poll (see _process),
	# NOT a placement signal subscription: placement_committed fires BEFORE
	# PlacementSystem's _clear_drag() returns, so a signal handler would
	# re-query is_dragging() while the drag is still technically active and
	# leave Move disabled until the next event. Polling the boolean query
	# each frame is cheap, ordering-independent, and matches the BSUI-004
	# palette's documented per-frame drag-resolution poll precedent.


## Applies data-driven config values; missing keys keep the GDD anchors.
func _apply_config(config: Dictionary) -> void:
	if config.has(CONFIG_REDUCED_MOTION):
		_reduced_motion = bool(config[CONFIG_REDUCED_MOTION])
	if config.has(CONFIG_TOOLBAR_ENTER_DURATION):
		_enter_duration = clampf(float(config[CONFIG_TOOLBAR_ENTER_DURATION]), DURATION_MIN, DURATION_MAX)
	if config.has(CONFIG_TOOLBAR_EXIT_DURATION):
		_exit_duration = clampf(float(config[CONFIG_TOOLBAR_EXIT_DURATION]), DURATION_MIN, DURATION_MAX)


## Builds the Inspect / Move / Sell button row. Buttons are named for tests;
## focus_mode FOCUS_ALL keeps the dual-focus (4.6+) keyboard path reachable
## (Tab → grid focus → toolbar). Typed signal connections to the button
## handlers (Control Manifest).
func _build_buttons() -> void:
	var row := HBoxContainer.new()
	row.name = "ToolbarRow"
	row.add_theme_constant_override("separation", 6)
	add_child(row)

	_inspect_button = Button.new()
	_inspect_button.name = "InspectButton"
	_inspect_button.text = LABEL_INSPECT
	_inspect_button.focus_mode = Control.FOCUS_ALL
	# Phase D v2: 粗字体 + 浅色文字 + 深色半透明按钮皮肤（主题级）。
	UiTheme.style_button(_inspect_button)
	_inspect_button.add_theme_color_override("font_color", COLOR_WARM_CREAM)
	_inspect_button.pressed.connect(_on_inspect_pressed)
	row.add_child(_inspect_button)

	_upgrade_button = Button.new()
	_upgrade_button.name = "UpgradeButton"
	_upgrade_button.text = LABEL_UPGRADE
	_upgrade_button.focus_mode = Control.FOCUS_ALL
	UiTheme.style_button(_upgrade_button)
	_upgrade_button.add_theme_color_override("font_color", COLOR_BUTTER)
	_upgrade_button.pressed.connect(_on_upgrade_pressed)
	row.add_child(_upgrade_button)

	_move_button = Button.new()
	_move_button.name = "MoveButton"
	_move_button.text = LABEL_MOVE
	_move_button.focus_mode = Control.FOCUS_ALL
	UiTheme.style_button(_move_button)
	_move_button.add_theme_color_override("font_color", COLOR_WARM_CREAM)
	_move_button.pressed.connect(_on_move_pressed)
	row.add_child(_move_button)

	_sell_button = Button.new()
	_sell_button.name = "SellButton"
	_sell_button.text = LABEL_SELL
	_sell_button.focus_mode = Control.FOCUS_ALL
	UiTheme.style_button(_sell_button)
	_sell_button.add_theme_color_override("font_color", COLOR_WARM_CREAM)
	_sell_button.pressed.connect(_on_sell_pressed)
	row.add_child(_sell_button)

	# Background: Phase D v2 深色半透明面板 + Butter 亮色描边 —— 工具栏
	# 读作贴近器械的现代信息面板（art-bible-25d §1 UI 行），非暖色木框。
	add_theme_stylebox_override("panel", _make_background_style())
	# Size the panel to its content (the button row) so anchoring math works
	# even headless / before a layout pass.
	reset_size()


func _make_background_style() -> StyleBoxFlat:
	# V3.1 返工 UI：面板 stylebox 透明（保留 content margins 供按钮行布局），
	# 手绘像素平板由 _draw() 绘制（PixelPanel 木纹：不规则边缘 + 材质 cluster
	# + 非等宽 Butter 断续描边）。
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.0, 0.0, 0.0, 0.0)
	sb.border_width_left = 0
	sb.border_width_top = 0
	sb.border_width_right = 0
	sb.border_width_bottom = 0
	sb.content_margin_left = 8.0
	sb.content_margin_right = 8.0
	sb.content_margin_top = 6.0
	sb.content_margin_bottom = 6.0
	return sb


## V3.1 返工 UI：工具栏平板绘制 —— PixelPanel 手绘木纹像素平板铺满整个
## 面板（PanelContainer 的透明 stylebox 先画，本 _draw 在其上绘制纹理；
## 子按钮行绘制在两者之上）。尺寸变化（sell-confirm 变长）时重建纹理。
func _draw() -> void:
	var tex := _plate_texture()
	if tex == null:
		return
	draw_texture_rect(tex, Rect2(Vector2.ZERO, size), false)


## 懒生成/按需重建工具栏像素平板纹理。底色 = panel_bg() 深灰（alpha
## PANEL_ALPHA，半透明让场景透出）、accent = Butter、材质 = WOOD（与顶栏
## 同语言，贴近器械的木质信息板）。
func _plate_texture() -> ImageTexture:
	var want := Vector2i(
		maxi(1, ceili(size.x / PLATE_TEXEL)),
		maxi(1, ceili(size.y / PLATE_TEXEL))
	)
	if _plate_texture_tex == null or _plate_texel_size != want:
		_plate_texture_tex = PixelPanel.plate_texture(
			PLATE_SEED,
			want,
			UiTheme.panel_bg(),
			UiTheme.panel_border(),
			PixelPanel.Style.WOOD,
			UiTheme.PANEL_ALPHA
		)
		_plate_texel_size = want
	return _plate_texture_tex


# === Signal handlers ===

## selection_changed subscriber (S7 arity contract). Select → show + anchor
## near the piece; deselect (null instance_id) → hide. Swap (a different
## non-null id) → move directly to the new piece, no intermediate deselect
## animation (UX spec "Swap").
func _on_selection_changed(
	instance_id = null,
	equipment_def = null,
	cell = null,
	rotation = null
) -> void:
	if not _initialized:
		return
	if instance_id == null:
		_hide_toolbar()
		return
	_show_toolbar(instance_id, equipment_def, cell, rotation)


## Bridge sell_confirm_started — the Sell button morphs to
## "Confirm sell +$X" in Butter (Story 003's state machine rendered here).
## The refund label comes from SelectionSystem.get_sell_refund() — the
## formula's single source.
func _on_sell_confirm_started() -> void:
	if not _initialized or _selected_def == null:
		return
	var refund: int = _selection.get_sell_refund(_selected_def)
	_sell_button.text = SELL_CONFIRM_PREFIX + str(refund)
	_sell_button.add_theme_color_override("font_color", COLOR_BUTTER)


## Bridge sell_confirm_reverted (2s timeout / Esc / click-away) — the button
## returns to the normal Sell label. No sale happened (the bridge's own
## guarantee, "no destructive default").
func _on_sell_confirm_reverted() -> void:
	if not _initialized:
		return
	_sell_button.text = LABEL_SELL
	_sell_button.remove_theme_color_override("font_color")


func _on_equipment_upgraded(instance_id: int, _old_level: int, _new_level: int, _cost: int) -> void:
	if instance_id == _selected_instance_id:
		_refresh_upgrade_button()


func _on_balance_changed(_new_balance: int, _delta: int) -> void:
	if _active:
		_refresh_upgrade_button()


## Per-frame Move-disabled refresh (UX AC: Move disabled during an active
## placement drag). PlacementSystem has no drag-START/END signals that
## bracket a drag cleanly (placement_committed fires BEFORE _clear_drag
## returns), so the toolbar polls the bridge's is_move_blocked() boolean
## each frame — a cheap read, ordering-independent, and consistent with the
## BSUI-004 palette's per-frame drag-resolution poll. Only runs while the
## toolbar is active (a selection exists).
func _process(_delta: float) -> void:
	if not _initialized or not _active:
		return
	_refresh_move_disabled()
	_refresh_upgrade_button()


## Inspect pressed — always available; emits the open hook (Equipment Info
## Panel #17 is out of scope; the button + hook live here).
func _on_inspect_pressed() -> void:
	if not _initialized:
		return
	if _selected_instance_id == -1:
		return
	inspect_requested.emit(_selected_instance_id, _selected_def, _selected_cell, _selected_rotation)


## A2 upgrade pressed — a single click performs the deterministic paid
## transaction. Affordability/max-level are reflected in disabled state and
## rechecked by EquipmentUpgradeSystem for defense in depth.
func _on_upgrade_pressed() -> void:
	if not _initialized or _selected_instance_id == -1 or _selected_def == null:
		return
	if _upgrade_system == null or _economy == null:
		return
	_upgrade_system.try_upgrade(_selected_instance_id, _selected_def.cost, _economy)
	_refresh_upgrade_button()


## Move pressed — the AC4 handoff. Sequence (GDD Core Rule 3):
##   1. Guard: never hand off while PlacementSystem is dragging (AC27; the
##      button is disabled during a drag, this is defense-in-depth).
##   2. Read the selected instance id BEFORE clearing.
##   3. SelectionSystem.clear_selection() — the cue clears the INSTANT Move
##      is pressed (selection released; selection_changed(null) fires).
##   4. PlacementSystem.begin_relocate(instance_id) — the relocate-ghost
##      appears at that instance's position within one frame (begin_relocate
##      is synchronous: it picks up the piece and enters DRAGGING in the
##      same call).
## Once handed off, the flow is PlacementSystem's (its relocate can be
## cancelled per its own rules; SelectionSystem is already deselected).
func _on_move_pressed() -> void:
	if not _initialized:
		return
	if _bridge != null and _bridge.is_move_blocked():
		return  # AC27: no handoff while a drag is in flight (defensive)
	if _selected_instance_id == -1:
		return
	var instance_id: int = _selected_instance_id
	# Release the selection FIRST — no dual-ownership ambiguity (Core Rule 3).
	_selection.clear_selection()
	# Hand off to PlacementSystem's relocate flow (ghost appears within one
	# frame — begin_relocate is synchronous).
	if _placement != null:
		_placement.begin_relocate(instance_id)


## Sell pressed — drives the bridge's soft-confirm window (Story 003 state
## machine). No pending window → request_sell_confirm() opens it (button
## morphs via sell_confirm_started). Window already pending → the second
## click confirms (confirm_sell → sell_confirm_confirmed → the composition
## root's sale logic).
func _on_sell_pressed() -> void:
	if not _initialized:
		return
	if _bridge == null:
		return
	if _bridge.is_sell_confirm_pending():
		_bridge.confirm_sell()
	else:
		_bridge.request_sell_confirm()


# === Show / hide / anchor ===

## Shows the toolbar for the selected piece: computes the footprint pixel
## rect, positions the toolbar offset to the nearest free side (never
## covering the piece), sets the Sell label back to "Sell" (a fresh
## selection starts a fresh confirm state), and fades/slides in.
func _show_toolbar(instance_id: int, equipment_def, cell: Vector2i, rotation: int) -> void:
	_selected_instance_id = instance_id
	_selected_def = equipment_def
	_selected_cell = cell
	_selected_rotation = rotation
	_footprint_rect = _compute_footprint_rect(equipment_def, cell, rotation)
	_active = true
	# Fresh selection → Sell button back to its normal label (a previous
	# selection's confirm state never leaks into the new one).
	_sell_button.text = LABEL_SELL
	_sell_button.remove_theme_color_override("font_color")
	# Move disabled during an active placement drag (UX AC).
	_refresh_move_disabled()
	_refresh_upgrade_button()
	_anchor_to_footprint()
	visible = true
	queue_redraw()
	_animate_enter()


## Hides the toolbar: 120ms fade out, then invisible. Swap does NOT call
## this (it goes straight to _show_toolbar with the new piece — no
## intermediate deselect animation). Reduced-motion: instant hide.
func _hide_toolbar() -> void:
	_selected_instance_id = -1
	_selected_def = null
	_active = false
	_kill_anim()
	if _reduced_motion:
		visible = false
		return
	_anim_tween = create_tween()
	_anim_tween.tween_property(self, "modulate:a", 0.0, _exit_duration)
	_anim_tween.tween_callback(func() -> void:
		if not _active:
			visible = false
	)


## Enter animation: fade/slide in ~150ms. The toolbar slides from a small
## offset toward its final anchored position while fading in. Reduced-motion:
## instant, already visible.
func _animate_enter() -> void:
	_kill_anim()
	modulate.a = 0.0
	if _reduced_motion:
		modulate.a = 1.0
		return
	var from_offset := Vector2(0, 6)
	var start_pos := position + from_offset
	position = start_pos
	_anim_tween = create_tween()
	_anim_tween.set_trans(Tween.TRANS_QUAD)
	_anim_tween.set_ease(Tween.EASE_OUT)
	_anim_tween.parallel().tween_property(self, "position", start_pos - from_offset, _enter_duration)
	_anim_tween.parallel().tween_property(self, "modulate:a", 1.0, _enter_duration)


func _kill_anim() -> void:
	if _anim_tween != null and _anim_tween.is_valid():
		_anim_tween.kill()
	_anim_tween = null


## Positions the toolbar offset to the NEAREST FREE SIDE of the footprint
## (never covering the piece; adapts at screen edges). Candidate sides are
## tried in free-space order: the side with the most room wins.
func _anchor_to_footprint() -> void:
	var toolbar_size := size
	var footprint := _footprint_rect
	var origin := _grid_origin
	var viewport := _viewport_size

	var right_room := viewport.x - (origin.x + footprint.end.x) - ANCHOR_GAP_PX
	var left_room := origin.x + footprint.position.x - ANCHOR_GAP_PX
	var bottom_room := viewport.y - (origin.y + footprint.end.y) - ANCHOR_GAP_PX
	var top_room := origin.y + footprint.position.y - ANCHOR_GAP_PX

	var best_pos := Vector2(origin.x + footprint.end.x + ANCHOR_GAP_PX, origin.y + footprint.position.y)
	var best_room := right_room
	# Order: right, left, bottom, top — the free side with the most room.
	if left_room > best_room:
		best_room = left_room
		best_pos = Vector2(origin.x + footprint.position.x - ANCHOR_GAP_PX - toolbar_size.x, origin.y + footprint.position.y)
	if bottom_room > best_room:
		best_room = bottom_room
		best_pos = Vector2(origin.x + footprint.position.x, origin.y + footprint.end.y + ANCHOR_GAP_PX)
	if top_room > best_room:
		best_room = top_room
		best_pos = Vector2(origin.x + footprint.position.x, origin.y + footprint.position.y - ANCHOR_GAP_PX - toolbar_size.y)
	# Clamp inside the viewport (screen-edge adaptation).
	best_pos.x = clampf(best_pos.x, 0.0, maxf(0.0, viewport.x - toolbar_size.x))
	best_pos.y = clampf(best_pos.y, 0.0, maxf(0.0, viewport.y - toolbar_size.y))
	position = best_pos


## Re-queries the Move-disabled state from the bridge (PlacementSystem
## is_dragging()). Called on every selection_changed; also exposed so the
## composition root can refresh on drag-state changes.
func refresh_move_disabled() -> void:
	if not _initialized:
		return
	_refresh_move_disabled()


func _refresh_move_disabled() -> void:
	if _bridge == null:
		_move_button.disabled = false
		return
	_move_button.disabled = _bridge.is_move_blocked()


func _refresh_upgrade_button() -> void:
	if _upgrade_button == null:
		return
	if _selected_instance_id == -1 or _selected_def == null \
		or _upgrade_system == null or _economy == null:
		_upgrade_button.text = LABEL_UPGRADE
		_upgrade_button.disabled = true
		return
	var level := int(_upgrade_system.get_level(_selected_instance_id))
	var max_level := int(_upgrade_system.get_max_level())
	if level >= max_level:
		_upgrade_button.text = UPGRADE_MAX_PREFIX + str(max_level)
		_upgrade_button.disabled = true
		return
	var cost := int(_upgrade_system.get_upgrade_cost(_selected_instance_id, _selected_def.cost))
	_upgrade_button.text = UPGRADE_PREFIX + str(level + 1) + " $" + str(cost)
	_upgrade_button.disabled = cost <= 0 or not bool(_economy.can_afford(cost))


## Pixel rect of the transformed footprint cells (grid space) — mirrors the
## cue's computation; both are thin presentation reads of the SAME
## GridSystem transform (never a local re-implementation of rotation math).
## V3.1 P1：注入 world_to_screen 时，4 角先经 oblique 投影再取 AABB
## （与世界上屏位置精确对齐；剪切使 footprint 在屏幕上是平行四边形）。
func _compute_footprint_rect(equipment_def, cell: Vector2i, rotation: int) -> Rect2:
	if _grid == null or equipment_def == null:
		return Rect2()
	var transformed: TransformedFootprint = _grid.get_transformed_cells(
		equipment_def.footprint_cells,
		equipment_def.access_cells,
		cell,
		rotation as GridSystemScript.Rotation
	)
	if transformed.footprint_cells.is_empty():
		return Rect2()
	var min_c: Vector2i = transformed.footprint_cells[0]
	var max_c: Vector2i = min_c
	for c in transformed.footprint_cells:
		min_c.x = min(min_c.x, c.x)
		min_c.y = min(min_c.y, c.y)
		max_c.x = max(max_c.x, c.x)
		max_c.y = max(max_c.y, c.y)
	if _world_to_screen.is_valid():
		# 投影路径：4 角（世界 px = cell × CELL_WORLD_PX）→ 屏幕 → 减去
		# origin 保持「grid space（pre-origin）」约定（调用方统一加 origin）。
		var corners := _projected_corners(min_c, max_c)
		if corners.size() >= 4:
			var aabb := Rect2(corners[0], Vector2.ZERO)
			for p in corners:
				aabb = aabb.expand(p)
			return Rect2(aabb.position - _grid_origin, aabb.size)
	# 兜底路径：origin + cell*cell_size 均匀换算（无投影注入 / 单测）。
	var top_left: Vector2 = Vector2(min_c) * _cell_size
	var bottom_right: Vector2 = Vector2(max_c + Vector2i.ONE) * _cell_size
	return Rect2(top_left, bottom_right - top_left)


## 世界 cell 尺寸（px）—— 投影 Callable 输入用（与 main.gd CELL_SIZE 一致）。
const CELL_WORLD_PX := 32

## footprint cell AABB 的 4 角（世界 px）经 world_to_screen 投影。
func _projected_corners(min_c: Vector2i, max_c: Vector2i) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for corner in [
		Vector2i(min_c.x, min_c.y),
		Vector2i(max_c.x + 1, min_c.y),
		Vector2i(max_c.x + 1, max_c.y + 1),
		Vector2i(min_c.x, max_c.y + 1),
	]:
		pts.append(_world_to_screen.call(Vector2(corner) * CELL_WORLD_PX))
	return pts


## 兼容 float / Vector2 的 cell_size 注入（float 视作方形）。
func _as_cell_size(v: Variant) -> Vector2:
	if v is Vector2:
		return v
	return Vector2(float(v), float(v))


# === Query surface (headless tests assert state, never pixels) ===

## True while a piece is selected and the toolbar is shown.
func is_toolbar_active() -> bool:
	if not _initialized:
		return false
	return _active and visible

## True when the Move button is currently disabled (a placement drag is
## active — PlacementSystem.is_dragging() via the bridge).
func is_move_disabled() -> bool:
	if not _initialized:
		return false
	return _move_button.disabled

## The current Sell button label ("Sell", or "Confirm sell +$X" while the
## soft-confirm window is open).
func get_sell_label() -> String:
	if not _initialized:
		return ""
	return _sell_button.text


## Current A2 upgrade label, including next level and cost or max-level state.
func get_upgrade_label() -> String:
	if not _initialized or _upgrade_button == null:
		return ""
	return _upgrade_button.text


## Whether the A2 upgrade action is unavailable (unwired, unaffordable, or max).
func is_upgrade_disabled() -> bool:
	if not _initialized or _upgrade_button == null:
		return true
	return _upgrade_button.disabled

## True while the sell soft-confirm window is open (button morphed).
func is_sell_pending() -> bool:
	if not _initialized:
		return false
	if _bridge == null:
		return false
	return _bridge.is_sell_confirm_pending()

## The currently selected instance id (-1 when none).
func get_selected_instance_id() -> int:
	if not _initialized:
		return -1
	return _selected_instance_id

## The anchored position of the toolbar (screen space) — tests assert the
## toolbar sits near the piece, offset to the free side.
func get_anchor_position() -> Vector2:
	return position

## The footprint pixel rect of the current selection (grid space, pre
## grid_origin offset).
func get_footprint_rect() -> Rect2:
	return _footprint_rect

## Whether reduced-motion mode is active (instant show/hide, no animation).
func is_reduced_motion() -> bool:
	return _reduced_motion

## The enter animation duration (config knob, clamped).
func get_enter_duration() -> float:
	return _enter_duration

## The exit animation duration (config knob, clamped).
func get_exit_duration() -> float:
	return _exit_duration
