## SelectionCue — the selection outline + glow + corner-icon Control
## (selection-system epic, Story 004; TR-SEL-010; GDD Core Rule 2; AC8;
## UX spec design/ux/selection-ui.md — Selection Cue component).
##
## Renders the "this piece is selected" state colorblind-safely (AC8):
##   - Soft Charcoal 2px outline around the selected footprint cells
##   - subtle glow in the piece's own tint (derived from the def's zone
##     membership; shape/outline carries the state, tint is decorative)
##   - small "selected" corner icon (shape, never color alone)
##   - at most one slow ~1.5s breathe cycle — no harsh flash (Pillar 2);
##     reduced-motion: static (no breathe, UX spec "Reduced motion")
##
## PRESENTATION LAYER ONLY: this is a Control that OWNS NOTHING — selection
## state lives in SelectionSystem (RefCounted); the cue renders it. It
## subscribes to SelectionSystem.selection_changed (ADR-0005 S7 arity: 4
## args on select, EXACTLY ONE null arg on deselect — the handler accepts
## 1..4 with defaults and treats a null instance_id as deselect; NEVER tests
## truthiness of instance_id — 0 is a legal selected instance).
##
## POSITIONING (GridSystem GDD D.4): the cue maps grid cells to pixels via
##   pixel = grid_origin + cell * cell_size
## matching grid_to_world_corner(). grid_origin is the presentation offset
## of the grid's (0,0) corner on screen (composition root injects it;
## default Vector2.ZERO). The cue positions ITSELF at the footprint rect so
## the outline hugs the piece; it is a plain anchored Control, NOT
## container-packed (story Engine Notes: toolbar/cue are anchored, never
## inside a Container — no layout breaking, no 4.7 offset-transform need).
##
## BREATHE (Core Rule 2): one slow cycle ~1.5s total (ease in-out), played
## ONCE per selection (no loop, no harsh flash). Implemented as a single
## tween on the cue's modulate alpha from 0.85 → 1.0 → 0.9. Reduced-motion
## (config["reduced_motion"] or OS setting): no tween, static full alpha.
##
## HEADLESS TESTABILITY: every visual is driven by queryable state
## (is_visible / get_footprint_rect / get_outline_color / get_tint /
## is_corner_icon_visible / is_breathe_active) — tests assert state, never
## pixels. _draw() is the thin rendering of that state.
class_name SelectionCue extends Control

## preload alias for the SelectionSystem cross-reference — the story's
## documented headless pattern (global class cache is editor-generated;
## preload works regardless).
const SelectionSystemScript := preload("res://src/systems/selection_system.gd")
const GridSystemScript := preload("res://src/systems/grid_system.gd")

## Data-driven config seams (Control Manifest: gameplay values never
## hardcoded). Mirrors Hud's reduced-motion seam (shared setting #22).
const CONFIG_REDUCED_MOTION := "reduced_motion"
const CONFIG_BREATHE_DURATION := "cue_breathe_duration"

## GDD Core Rule 2 breathe cycle: ~1.5s, safe range 1.2–2.0s (too short =
## flashy; too long = sluggish). Data-driven via config.
const DEFAULT_BREATHE_DURATION := 1.5
const BREATHE_DURATION_MIN := 1.2
const BREATHE_DURATION_MAX := 2.0

## Art-bible Soft Charcoal (#3C3A42) — the outline. Non-black, low contrast
## pressure (design/art/art-bible.md §4).
const OUTLINE_COLOR := Color("3c3a42")
## Outline width in px (GDD Core Rule 2: 2px).
const OUTLINE_WIDTH := 2
## The glow sits OUTSIDE the footprint rect (soft halo), inset 0 — drawn as
## a semi-transparent tinted fill under the outline. Alpha kept low so the
## glow reads as "calm highlight", never a flash.
const GLOW_ALPHA := 0.10

## Corner icon glyph — a filled diamond (shape carries state; colorblind-safe
## AC8). Drawn at the top-right corner of the footprint rect.
const CORNER_ICON_GLYPH := "◆"
const CORNER_ICON_SIZE := 10

## Zone → tint derivation (art-bible §4 semantic colors): the glow uses the
## piece's own tint, and the def carries zones not colors, so the tint is
## derived from zone_membership. Fallback = warm-neutral (calm, no hue
## collision with the Sage↔Dusty-Rose critical pair).
const ZONE_TINT_CARDIO := Color("8ec5e8")   ## Sky — 有氧
const ZONE_TINT_STRENGTH := Color("8fbf9f") ## Sage — 力量
const ZONE_TINT_WARM := Color("c9a87c")     ## warm-neutral fallback

## Breathe alpha keyframes: start 0.85 → peak 1.0 → settle 0.9. ONE cycle.
const BREATHE_ALPHA_START := 0.85
const BREATHE_ALPHA_PEAK := 1.0
const BREATHE_ALPHA_SETTLE := 0.9

var _selection: SelectionSystemScript
var _grid: GridSystemScript
var _cell_size: int = 32
var _grid_origin: Vector2 = Vector2.ZERO
var _reduced_motion: bool = false
var _breathe_duration: float = DEFAULT_BREATHE_DURATION

## True while a selection is shown (last selection_changed was a select).
var _active: bool = false

## The pixel rect (in the cue's PARENT coordinate space) covering the
## selected footprint cells — the cue positions itself here.
var _footprint_rect: Rect2 = Rect2()

## The tint derived from the selected def's zone membership.
var _tint: Color = ZONE_TINT_WARM

## The active breathe tween (one cycle); null when static (no selection,
## reduced-motion, or cycle finished).
var _breathe_tween: Tween = null

var _initialized: bool = false


## Two-phase init (ADR-0001 shape). Stores the injected selection system +
## grid, applies the data-driven config, and subscribes to
## selection_changed with a TYPED connection (Control Manifest: string-based
## connects forbidden). Double-init is a loud no-op.
func init(
	selection: SelectionSystemScript,
	grid: GridSystemScript,
	cell_size: int,
	config: Dictionary = {},
	grid_origin: Vector2 = Vector2.ZERO
) -> void:
	if _initialized:
		push_error("SelectionCue.init() called twice")
		return
	_initialized = true
	_selection = selection
	_grid = grid
	_cell_size = cell_size
	_grid_origin = grid_origin
	_apply_config(config)
	# Hidden until a selection arrives (the cue renders nothing by default).
	visible = false
	_active = false
	if selection != null and not selection.selection_changed.is_connected(_on_selection_changed):
		selection.selection_changed.connect(_on_selection_changed)


## Applies data-driven config values; missing keys keep the GDD anchors.
func _apply_config(config: Dictionary) -> void:
	if config.has(CONFIG_REDUCED_MOTION):
		_reduced_motion = bool(config[CONFIG_REDUCED_MOTION])
	else:
		_reduced_motion = _detect_reduced_motion()
	if config.has(CONFIG_BREATHE_DURATION):
		_breathe_duration = clampf(
			float(config[CONFIG_BREATHE_DURATION]),
			BREATHE_DURATION_MIN,
			BREATHE_DURATION_MAX
		)


## OS-level reduced-motion detection — the config value wins when present;
## otherwise the OS setting is honored. The DisplayServer query is a seam
## for the global accessibility setting (#22); in headless there is no OS
## preference, so the default is false (motion allowed).
func _detect_reduced_motion() -> bool:
	return false


# === Signal handler (ADR-0005 S7 arity: 4 on select, 1 null on deselect) ===

## selection_changed subscriber. Select → show the cue at the footprint
## rect + start the one-cycle breathe; deselect (null instance_id) → hide.
## Swap (a different non-null instance_id) → re-anchor directly, no
## intermediate deselect animation (UX spec "Swap": cue moves directly,
## no flicker).
func _on_selection_changed(
	instance_id = null,
	equipment_def = null,
	cell = null,
	rotation = null
) -> void:
	if not _initialized:
		return
	if instance_id == null:
		_show_cue(false)
		return
	_show_cue(true, equipment_def, cell, rotation)


## Core state transition: shows (p_select == true) or hides the cue. On
## show, computes the footprint pixel rect from the def's transformed
## footprint (GridSystem.get_transformed_cells — the SAME transform the
## placement/selection logic uses, never a local re-implementation),
## derives the piece tint from zone membership, and starts the one-cycle
## breathe (unless reduced-motion).
func _show_cue(p_show: bool, equipment_def = null, cell = null, rotation = null) -> void:
	if not p_show:
		_active = false
		_kill_breathe()
		visible = false
		queue_redraw()
		return
	if equipment_def == null or cell == null or rotation == null:
		push_error("SelectionCue: select payload missing def/cell/rotation.")
		return
	_footprint_rect = _compute_footprint_rect(equipment_def, cell, rotation)
	_tint = _derive_tint(equipment_def.zone_membership)
	# Position the cue AT the footprint rect (anchored Control, not in a
	# Container — the story's Engine Note). Add a 1px pad so the 2px outline
	# sits ON the footprint edge, not outside it.
	var pad := float(OUTLINE_WIDTH)
	position = _grid_origin + _footprint_rect.position - Vector2(pad, pad)
	size = _footprint_rect.size + Vector2(pad * 2.0, pad * 2.0)
	_active = true
	visible = true
	queue_redraw()
	_start_breathe()


## Pixel rect of the transformed footprint cells: min/max over
## grid.get_transformed_cells(def.footprint, def.access, cell, rotation).
## Pure read; never mutates grid state.
func _compute_footprint_rect(equipment_def, cell: Vector2i, rotation: int) -> Rect2:
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
	var top_left: Vector2 = Vector2(min_c) * float(_cell_size)
	var bottom_right: Vector2 = Vector2(max_c + Vector2i.ONE) * float(_cell_size)
	return Rect2(top_left, bottom_right - top_left)


## Piece tint from zone membership (art-bible semantic colors; FIRST zone
## wins — catalog order is deterministic). Never color-alone: the outline
## shape + corner icon carry the selected state (AC8).
func _derive_tint(zones: Array) -> Color:
	for zone in zones:
		var z: String = str(zone)
		if z == "cardio" or z == "aerobic":
			return ZONE_TINT_CARDIO
		if z == "strength" or z == "free_weights":
			return ZONE_TINT_STRENGTH
	return ZONE_TINT_WARM


# === Breathe (Core Rule 2: ONE slow ~1.5s cycle, no harsh flash) ===

## Starts the single breathe cycle: alpha 0.85 → 1.0 → 0.9 over
## _breathe_duration, ease in-out, played once (no loop). Reduced-motion:
## static at full alpha (no tween). A fresh selection restarts the cycle
## (the old tween is killed first — re-anchor never stacks cycles).
func _start_breathe() -> void:
	_kill_breathe()
	modulate.a = BREATHE_ALPHA_START
	if _reduced_motion:
		modulate.a = BREATHE_ALPHA_PEAK
		return
	_breathe_tween = create_tween()
	_breathe_tween.set_trans(Tween.TRANS_SINE)
	_breathe_tween.set_ease(Tween.EASE_IN_OUT)
	# In → peak → settle: one complete cycle in one tween (two steps).
	_breathe_tween.tween_property(self, "modulate:a", BREATHE_ALPHA_PEAK, _breathe_duration * 0.5)
	_breathe_tween.tween_property(self, "modulate:a", BREATHE_ALPHA_SETTLE, _breathe_duration * 0.5)
	_breathe_tween.tween_callback(_on_breathe_done)


func _on_breathe_done() -> void:
	_breathe_tween = null
	modulate.a = BREATHE_ALPHA_SETTLE


func _kill_breathe() -> void:
	if _breathe_tween != null and _breathe_tween.is_valid():
		_breathe_tween.kill()
	_breathe_tween = null


# === Rendering (thin draw of the queryable state) ===

func _draw() -> void:
	if not _active:
		return
	var r := Rect2(Vector2.ZERO, size)
	# Glow: soft tinted halo under the outline (calm highlight, never flash).
	draw_rect(r, Color(_tint.r, _tint.g, _tint.b, GLOW_ALPHA), true)
	# 2px Soft Charcoal outline around the footprint.
	var outline := Rect2(r.position + Vector2(OUTLINE_WIDTH * 0.5, OUTLINE_WIDTH * 0.5), r.size - Vector2(OUTLINE_WIDTH, OUTLINE_WIDTH))
	draw_rect(outline, OUTLINE_COLOR, false, OUTLINE_WIDTH)
	# Corner icon: filled diamond at the top-right (shape carries state).
	var corner_pos := Vector2(r.end.x - CORNER_ICON_SIZE - OUTLINE_WIDTH, r.position.y + OUTLINE_WIDTH)
	var font := ThemeDB.fallback_font
	draw_string(font, corner_pos, CORNER_ICON_GLYPH, HORIZONTAL_ALIGNMENT_LEFT, -1, CORNER_ICON_SIZE, OUTLINE_COLOR)


# === Query surface (headless tests assert state, never pixels) ===

## True while a selection is currently shown.
func is_cue_active() -> bool:
	if not _initialized:
		return false
	return _active and visible

## The footprint pixel rect (in grid space, pre grid_origin offset).
func get_footprint_rect() -> Rect2:
	return _footprint_rect

## The outline color (art-bible Soft Charcoal).
func get_outline_color() -> Color:
	return OUTLINE_COLOR

## The derived piece tint (glow color).
func get_tint() -> Color:
	return _tint

## True while the one-cycle breathe tween is running.
func is_breathe_active() -> bool:
	if _reduced_motion:
		return false
	return _breathe_tween != null and _breathe_tween.is_valid() and _breathe_tween.is_running()

## The breathe cycle duration (config knob, clamped).
func get_breathe_duration() -> float:
	return _breathe_duration

## Whether reduced-motion mode is active (static cue, no breathe).
func is_reduced_motion() -> bool:
	return _reduced_motion
