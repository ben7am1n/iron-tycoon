## CongestionOverlayController — the overlay/bridge Node for placement
## rejection feedback + drag dimming (Story CFO-004).
##
## Story: production/epics/congestion-flow-overlay/story-004-rejection-tooltip-layer-priority.md
## Req:   TR-CFO-006 (rejection tooltip: 400ms hold, 2-bucket messages),
##        TR-CFO-007 (layer priority), TR-CFO-008 (heatmap drag-dim ≤20%)
## ADR:   ADR-0005 §5 (Input Bridge Pattern — bridge/overlay Node owns
##        timer creation; RefCounted cannot create timers)
##
## RESPONSIBILITIES (three, per the story):
##   1. REJECTION TOOLTIP (Core Rule 6, AC4/AC5). Subscribes to
##      PlacementSystem.placement_rejected (S4, typed connection) and arms
##      the RejectionTooltip logic model. The 400 ms hold TIMER is
##      UI-layer state owned HERE via get_tree().create_timer() (ADR-0005
##      §5) — the tooltip only appears after the cursor holds ~400 ms over
##      the invalid cell (flicker protection while sweeping). The tooltip
##      text is drawn in _draw() via CanvasItem.draw_string (4.7.1
##      signature: Font first, font_size before color; ThemeDB.fallback_font
##      guarded under headless).
##   2. DRAG DIMMING (Core Rule 7 / AC3). Polls PlacementSystem.is_dragging()
##      per frame (a cheap bool read — the story's sanctioned observation
##      mechanism; there is no drag-start signal in the ADR-0005 catalog)
##      and drives HeatmapLayer.set_drag_active() on the edges: drag begins
##      → heatmap tweens to ≤20%; drag ends → restores to the toggled state.
##      This is NOT the TR-PS-012 pattern (which forbids _process POLLING
##      of can_place/world_to_grid for mouse-move preview) — is_dragging()
##      is a pure O(1) state query, the exact query TR-PS-010 exists for.
##   3. LAYER PRIORITY (Core Rule 7). The drag path touches ONLY the
##      heatmap. The access-blocked layer is never dimmed: it has no
##      drag-dim API at all (its set_heatmap_enabled is an intentional
##      no-op — AC12), and this controller never calls any opacity/dim
##      method on it. Priority holds by construction:
##      access-blocked (full) > ghost (full, PlacementSystem's own) >
##      glyph (visible, Story 002) > heatmap (≤20%).
##
## NO SOUND (Pillar 2): rejection is silence — this file deliberately
## contains no audio machinery (structural test asserts it).
##
## TESTABILITY: the RejectionTooltip logic model is fully headless-testable
## (bucket mapping + hold state). The controller's timer path is exercised
## by driving _on_hold_elapsed() directly; _process() drag observation is
## driven by calling _poll_drag_state() directly in tests (the established
## headless pattern for Node callbacks).
class_name CongestionOverlayController
extends Control

## Cross-script class aliases (pinned caveat: class_name is NOT globally
## registered under headless load — reference via preload aliases).
const PlacementSystemScript := preload("res://src/systems/placement_system.gd")
const HeatmapLayerScript := preload("res://src/presentation/heatmap_layer.gd")
const AccessBlockedLayerScript := preload("res://src/presentation/access_blocked_layer.gd")
const RejectionTooltipScript := preload("res://src/ui/rejection_tooltip.gd")
const GridSystemScript := preload("res://src/systems/grid_system.gd")

## Tooltip draw offset above the anchor cell center (cursor-adjacent,
## GDD Core Rule 6). Fixed UI-layer scale (does not shrink with zoom).
const TOOLTIP_OFFSET := Vector2(8.0, -20.0)

## Tooltip text style — calm, information not alarm (Pillar 2): Soft
## Charcoal outline feel, near-white text, small fixed size.
const TOOLTIP_FONT_SIZE := 14
const TOOLTIP_TEXT_COLOR := Color(0.9, 0.9, 0.9, 1.0)
const TOOLTIP_BG_COLOR := Color(0.12, 0.12, 0.14, 0.85)

# === Injected dependencies (ADR-0001 two-phase init shape) ===
var _placement: PlacementSystemScript = null
var _heatmap: HeatmapLayerScript = null
var _access_blocked: AccessBlockedLayerScript = null
var _tooltip: RejectionTooltipScript = null
var _grid: GridSystemScript = null
var _cell_size: int = 32

## White-box observable for the drag-dim contract: the last drag state this
## controller observed from PlacementSystem.is_dragging(). Tests drive
## _poll_drag_state() and assert the transitions.
var _last_dragging: bool = false

## The in-flight hold timer (SceneTreeTimer via get_tree().create_timer —
## ADR-0005 §5). Null when no rejection hold is pending.
var _hold_timer: SceneTreeTimer = null

## Generation guard for the hold timer: each placement_rejected increments
## it; a stale timer that fires after a newer rejection is a no-op (the new
## rejection owns its own 400 ms window).
var _hold_generation: int = 0

var _initialized: bool = false


## Two-phase init (Phase 1 — stores references only, no side effects).
## [placement] / [heatmap] / [access_blocked] / [tooltip] / [grid] are
## hard typed dependencies; [cell_size] is the grid→world conversion scale
## (never hardcoded). [tooltip] is the logic model the controller drives
## (already init()'d by the caller with its config).
func init(
	placement: PlacementSystemScript,
	heatmap: HeatmapLayerScript,
	access_blocked: AccessBlockedLayerScript,
	tooltip: RejectionTooltipScript,
	grid: GridSystemScript,
	cell_size: int
) -> void:
	if not _mark_initialized():
		return
	_placement = placement
	_heatmap = heatmap
	_access_blocked = access_blocked
	_tooltip = tooltip
	_grid = grid
	_cell_size = cell_size


## Cross-system wiring phase (Phase 2). Subscribes to S4
## placement_rejected and preview_validity_changed — typed connections only
## (Control Manifest Presentation rule). Idempotent via is_connected.
func _post_init() -> void:
	assert(_initialized, "CongestionOverlayController._post_init() called before init()")
	if _placement != null:
		if not _placement.placement_rejected.is_connected(_on_placement_rejected):
			_placement.placement_rejected.connect(_on_placement_rejected)
		if not _placement.preview_validity_changed.is_connected(_on_preview_validity_changed):
			_placement.preview_validity_changed.connect(_on_preview_validity_changed)


## Per-frame drag observation (AC3 / Core Rule 7): polls
## PlacementSystem.is_dragging() — the story-mandated mechanism, a pure
## O(1) state read (TR-PS-010), NOT the TR-PS-012 no-polling rule (which
## forbids per-frame can_place/world_to_grid preview work). On edges:
##   drag begins  → heatmap dims to ≤20%; tooltip dismissed (cursor moving
##                  again — sweep flicker protection)
##   drag ends    → heatmap restores to toggled state; tooltip dismissed
##                  (GDD States table: "cursor moves to valid cell / drag
##                  ends" hides the tooltip)
func _process(_delta: float) -> void:
	_poll_drag_state()


## The drag-edge poll, exposed for headless tests (call directly instead of
## driving _process). Idempotent — no work when the state has not changed.
func _poll_drag_state() -> void:
	if _placement == null or _heatmap == null:
		return
	var dragging: bool = _placement.is_dragging()
	if dragging == _last_dragging:
		return
	_last_dragging = dragging
	if dragging:
		_heatmap.set_drag_active(true)
		if _tooltip != null:
			_tooltip.dismiss()  # new drag = cursor moving — hide any tooltip
	else:
		_heatmap.set_drag_active(false)
		if _tooltip != null:
			_tooltip.dismiss()  # drag ended — hide


## S4 handler (placement_rejected — arity 4, ADR-0005 catalog). Arms the
## RejectionTooltip (bucket message + anchor) and starts the 400 ms hold
## timer. The tooltip does NOT show yet — only after the cursor holds
## (flicker protection). A second rejection while one is pending replaces
## it (single calm tooltip, never stacked).
func _on_placement_rejected(equipment_id: String, anchor: Vector2i, rotation: int, fail_code: int) -> void:
	if _tooltip == null:
		return
	_tooltip.on_placement_rejected(equipment_id, anchor, rotation, fail_code)
	_start_hold_timer()


## preview_validity_changed handler (valid=true = cursor on a VALID cell).
## Per the GDD States table the tooltip hides when the cursor moves to a
## valid cell. (Invalid-cell previews leave the pending tooltip alone — the
## hold timer decides whether it shows.)
func _on_preview_validity_changed(valid: bool) -> void:
	if _tooltip == null:
		return
	if valid:
		_tooltip.dismiss()
		queue_redraw()


## Starts the 400 ms hold timer (SceneTreeTimer via get_tree().create_timer
## — ADR-0005 §5; RefCounted cannot create timers). Generation-guarded: a
## stale timer from a previous rejection is a no-op if a newer rejection
## arrived. Off-tree (headless unit tests) no timer is created — tests
## drive _on_hold_elapsed() directly.
func _start_hold_timer() -> void:
	_hold_generation += 1
	var gen := _hold_generation
	if not is_inside_tree():
		return
	var hold_s: float = _tooltip.get_hold_ms() / 1000.0
	var timer := get_tree().create_timer(hold_s)
	timer.timeout.connect(_on_hold_timeout.bind(gen))
	_hold_timer = timer


## SceneTreeTimer timeout — resolves the hold for [gen]. If a newer
## rejection superseded it, this is a no-op (the newer one owns the
## window).
func _on_hold_timeout(gen: int) -> void:
	if gen != _hold_generation:
		return
	_hold_timer = null
	if _tooltip == null:
		return
	_tooltip.on_hold_elapsed()
	queue_redraw()


## Toggle broadcast (interface symmetry — AccessBlockedLayer.set_heatmap_enabled
## is a deliberate no-op, AC12): routes the heatmap toggle to every layer.
## Returns the new heatmap state. Input wiring (H key / HUD button) lives
## in the HUD epic; this is the controller-side entry.
func set_heatmap_enabled(enabled: bool) -> bool:
	if _heatmap == null:
		return false
	if _heatmap.is_heatmap_on() != enabled:
		_heatmap.toggle_flow_overlay()
	if _access_blocked != null:
		_access_blocked.set_heatmap_enabled(enabled)
	return _heatmap.is_heatmap_on()


## The world position the tooltip is drawn at — anchor cell center + fixed
## offset (cursor-adjacent, GDD Core Rule 6). Exposed for tests; _draw
## uses it.
func tooltip_draw_position() -> Vector2:
	if _grid == null:
		return Vector2.ZERO
	return _grid.grid_to_world_center(_tooltip.get_anchor(), _cell_size) + TOOLTIP_OFFSET


## Draws the rejection tooltip (CanvasItem.draw_string — 4.7.1 signature:
## FIRST arg is Font; font_size PRECEDES color). Guarded against a null
## fallback font under headless. A calm dark chip + near-white text (Pillar
## 2 — information, never alarm).
func _draw() -> void:
	if _tooltip == null or not _tooltip.is_visible():
		return
	var font := ThemeDB.fallback_font
	if font == null:
		return  # headless — no font available
	var msg: String = _tooltip.get_message()
	if msg.is_empty():
		return
	var pos := tooltip_draw_position()
	var text_size: Vector2 = font.get_string_size(msg, HORIZONTAL_ALIGNMENT_LEFT, -1, TOOLTIP_FONT_SIZE)
	var bg_rect := Rect2(pos + Vector2(-4.0, -2.0), text_size + Vector2(8.0, 4.0))
	draw_rect(bg_rect, TOOLTIP_BG_COLOR, true)
	draw_string(font, pos, msg, HORIZONTAL_ALIGNMENT_LEFT, -1, TOOLTIP_FONT_SIZE, TOOLTIP_TEXT_COLOR)


func _mark_initialized() -> bool:
	if _initialized:
		push_error("CongestionOverlayController: init() called twice.")
		return false
	_initialized = true
	return true
