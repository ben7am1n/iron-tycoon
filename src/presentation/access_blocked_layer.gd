## src/presentation/access_blocked_layer.gd
## Story CFO-003: Access-Blocked Layer (Default-Visible)
## (production/epics/congestion-flow-overlay/story-003-access-blocked-layer.md)
## Req:   TR-CFO-001 (access-blocked part), TR-CFO-005, TR-CFO-011 (access-blocked part)
## ADR:   ADR-0005 (Signal Bus — S1 grid_changed subscriber, S8 congestion_updated
##        subscriber; typed signal connections only, never string-based)
##
## THE ALWAYS-ON LAYER (GDD Core Rule 1/5, AC2/AC12): renders the barricade /
## broken-link glyph for every equipment whose `access_reachable` flag is
## present-and-false in Congestion. It is NEVER gated by the heatmap toggle
## (`set_heatmap_enabled()` is a deliberate no-op consumed by the story-001/004
## toggle wiring) and NEVER dimmed by drag state. This is the concrete
## fulfillment of GridSystem's OQ#9 — the ONLY channel through which the player
## learns a machine is walled off.
##
## CORE RULE 5 (load-bearing, default-visible): `configure()` reads the CURRENT
## `access_reachable` set and materializes icons for every false entry up front
## — no event gate, no intervening "fade-in on false" trigger. A machine walled
## off in a prior session is visible the instant the scene appears, not only
## after the next grid_changed.
##
## DATA SOURCE (flag-presence semantics): the layer reads Congestion's public
## `access_reachable` Dictionary directly (exposed for white-box tests) and
## only ever shows an icon when the flag is PRESENT and false. Flag ABSENCE
## means "reachability machinery not live / id unknown" — never a barricade.
## This prevents the overlay from misreporting every machine as walled off when
## Congestion has no Navigation/entrance wired (is_access_reachable() alone
## would read false for unknown ids).
##
## EVENT-DRIVEN REFRESH (flicker protection, GDD Edge Case): the icon set is
## reconciled only on S1 grid_changed (immediate same-frame removal of icons
## whose equipment is gone — GDD Edge Case "icon removed the same frame") and
## on S8 congestion_updated (reachability flips, which Congestion recomputes at
## the next tick boundary after a grid change — never per tick). No per-frame
## data polling: `_process` exists ONLY to advance in-flight fade-ins and is
## disabled when every icon is static (zero steady-state cost).
##
## DYNAMICS:
##   - access_reachable → true, or equipment removed → icon removed (same frame)
##   - multiple machines walled off → each shows its own icon; never merge or
##     stack-count; no aggregate "N blocked" alarm (Pillar 2)
##   - fade-in once on a post-entry false transition, then holds STATIC — no
##     pulse, no loop, no failure sound (AC8); on-entry materialization is
##     static immediately (no fade, Core Rule 5)
##
## FIXED UI-LAYER SCALE (GDD Edge Case): the glyph is drawn at a constant
## pixel size regardless of camera zoom — `set_camera_zoom()` inverse-scales
## the draw size so the icon never shrinks with the world. The ANCHOR point is
## the equipment's FIRST access cell's world center, offset half a cell above
## it (config `anchor_offset_px`).
##
## HOVER TOOLTIP: one-line "Can't be reached — check for a blocked path" —
## never "ERROR" or exclamation iconography. The scene host forwards the
## pointer's WORLD position via `notify_pointer_world_position()`; the layer
## hit-tests glyph rects (no input plumbing inside). Text is drawn with
## CanvasItem.draw_string(font, pos, text, align, width, font_size, color) —
## first arg Font, font_size BEFORE color (4.7.1 signature); guarded by
## ThemeDB.fallback_font != null under headless.
##
## 4.7.1 PITFALLS APPLIED:
##   - class_name follows extends immediately
##   - `var x := expr` NEVER used on Variant-returning reads — explicit
##     `: Type` on every local fed from _grid/_congestion lookups
##   - typed signal connections only (control manifest Presentation rules)
##   - gameplay values data-driven via the [config] Dictionary (defaults =
##     art-bible / GDD anchors)
class_name AccessBlockedLayer extends Node2D

## V3 §2 世界缩放（描边宽度补偿 —— 亚像素描边消失 pitfall，见 world_scale.gd）。
const WorldScale := preload("res://src/presentation/world_scale.gd")

## One-line hover tooltip — the fixed copy (GDD Core Rule 5). Never "ERROR" or
## exclamation iconography. Public so tests and future localization tooling can
## reference the exact string.
const TOOLTIP_TEXT := "Can't be reached — check for a blocked path"

## Config keys (data-driven per Control Manifest — defaults = art-bible/GDD).
const CONFIG_GLYPH_SIZE := "glyph_size_px"       # barricade glyph width/height at zoom 1
const CONFIG_FADE_DURATION := "fade_duration_s"  # one-time fade-in length (0 = instant)
const CONFIG_ANCHOR_OFFSET := "anchor_offset_px" # y offset above access-cell center (world px)
const CONFIG_FILL_ALPHA := "fill_alpha"          # Dusty Rose fill opacity (secondary channel)
const CONFIG_OUTLINE_WIDTH := "outline_width_px" # Soft Charcoal outline width at zoom 1
const CONFIG_OUTLINE_COLOR := "outline_color"    # Soft Charcoal #3C3A42 (art bible)
const CONFIG_FILL_COLOR := "fill_color"          # Dusty Rose #E0A0A0 (art bible)
const CONFIG_TOOLTIP_COLOR := "tooltip_color"    # Soft Charcoal (art bible)
const CONFIG_TOOLTIP_FONT_SIZE := "tooltip_font_size_px"

## Icon state machine — terminal by construction. "fading_in" advances once to
## "static" and NO code path returns an icon to "fading_in" (AC8: no loop
## pulse; a loop would read as an alarm, Pillar 2).
const STATE_FADING_IN := "fading_in"
const STATE_STATIC := "static"

## Hard upstream dependency (typed read surface, ADR-0003 — never duck-typed):
## supplies placed instances + access cells + grid->world conversion.
var _grid: GridStateReader = null

## Hard upstream dependency: the Congestion instance whose public
## `access_reachable` Dictionary this layer consumes (flag-presence semantics,
## see class header). RefCounted — owned by the SimulationOrchestrator for the
## session lifetime (ADR-0005), so the signal connections never dangle.
var _congestion: Congestion = null

## The overlay's anchor unit — grid cell size in world pixels. NEVER hardcoded
## (architecture pinned value; GDD D.4). Passed in at configure().
var _cell_size: int = 32

# === Tuning values (GDD/art-bible anchors; see class header) ===
var _glyph_size_px: float = 14.0
var _fade_duration_s: float = 0.25
var _anchor_offset_px: float = 0.0
var _fill_alpha: float = 0.35
var _outline_width_px: float = 1.5
var _outline_color: Color = Color("#3C3A42")
var _fill_color: Color = Color("#E0A0A0")
var _tooltip_color: Color = Color("#3C3A42")
var _tooltip_font_size_px: int = 11

## Camera zoom last reported by the scene host; the glyph draw size is
## inverse-scaled so icons render at fixed UI-layer scale (GDD Edge Case:
## camera zoom changes must not shrink the icon).
var _camera_zoom: float = 1.0

## Icon registry — the observable state the white-box tests assert on.
## Keyed by equipment instance_id -> entry Dictionary:
##   "cell"  : Vector2i  — the equipment's FIRST access cell (anchor)
##   "pos"   : Vector2   — world position of the glyph (access cell center,
##                         offset `_anchor_offset_px` above)
##   "state" : String    — STATE_STATIC | STATE_FADING_IN
##   "alpha" : float     — current fade alpha in [0,1]
## Each walled-off machine gets its OWN entry — never merged, never
## stack-counted, no aggregate alarm (Pillar 2).
var icons: Dictionary = {}

## Monotonic mutation stamp: bumped ONLY when the icon set actually changes
## (add/remove). A quiet tick that reconciles to the same set leaves it
## untouched — the white-box AC8/no-strobe assertion.
var set_version: int = 0

## Hover tooltip state (GDD Core Rule 5 one-line tooltip). True while the
## pointer rests on a glyph rect.
var tooltip_visible: bool = false

## The instance id whose glyph the tooltip currently describes; -1 when no
## tooltip is showing.
var tooltip_instance_id: int = -1

## True once configure() has completed its initial materialization. Drives the
## fade rule: icons added BEFORE this flag (on-entry, Core Rule 5) materialize
## STATIC immediately; icons added AFTER (post-entry false transitions) fade
## in once (GDD Edge-Case row).
var _entered: bool = false


## Two-phase-style configuration (the layer is a scene Node, not a SimSystem —
## no init()/_post_init() contract, but the same spirit): stores typed
## dependencies, connects typed signals, and — the load-bearing clause —
## materializes icons for the CURRENT access_reachable set immediately, with no
## event gate and no intervening fade-in-on-false trigger (Core Rule 5).
##
## [config] carries the data-driven tuning values (CONFIG_* keys); missing
## keys fall back to the art-bible / GDD anchors. Idempotent: re-configuring
## (e.g. a save load rebinding the scene) disconnects nothing, re-materializes
## from scratch, and never double-connects (is_connected guards).
func configure(
	congestion: Congestion,
	grid: GridStateReader,
	cell_size: int,
	config: Dictionary = {}
) -> void:
	_congestion = congestion
	_grid = grid
	_cell_size = maxi(cell_size, 1)
	_anchor_offset_px = float(_cell_size) * 0.5  # base default: half cell above center
	_apply_config(config)

	# Typed signal connections ONLY (control manifest Presentation rules).
	# S1: grid_changed — same-frame icon removal when equipment is cleared.
	# S8: congestion_updated — reconcile reachability flips once per tick.
	if _grid != null and not _grid.grid_changed.is_connected(_on_grid_changed):
		_grid.grid_changed.connect(_on_grid_changed)
	if _congestion != null and not _congestion.congestion_updated.is_connected(_on_congestion_updated):
		_congestion.congestion_updated.connect(_on_congestion_updated)

	# Core Rule 5: read the CURRENT set up front. `_entered = false` makes the
	# materialization static (no fade) — default-visible is mandatory.
	var had_icons: bool = not icons.is_empty()
	icons.clear()
	_entered = false
	if had_icons:
		set_version += 1
	_refresh()
	_entered = true
	set_process(false)
	queue_redraw()


## The heatmap-toggle hook consumed by the overlay's toggle wiring (story
## 001/004). Deliberately INERT: the access-blocked layer is always-on and is
## never gated by the heatmap toggle or any drag dim (GDD Core Rule 1, AC2,
## AC12 — the icon appears regardless of toggle state). This method exists so
## the toggle can address all three render layers uniformly; the access-blocked
## layer's contract is to ignore it.
func set_heatmap_enabled(_enabled: bool) -> void:
	pass


## Fixed UI-layer scale: reports the factor applied to the glyph's pixel size
## so it stays constant on screen under camera zoom. 1/zoom — zooming in 2x
## halves the world-space draw size, keeping the on-screen size identical.
func glyph_scale() -> float:
	return 1.0 / maxf(_camera_zoom, 0.001)


## The scene host reports camera zoom changes here. Icon ANCHOR positions are
## world-space (access cells) and never move; only the glyph's draw size is
## inverse-scaled (GDD Edge Case: fixed UI scale, no shrink with zoom).
func set_camera_zoom(zoom: float) -> void:
	if zoom <= 0.0:
		return
	_camera_zoom = zoom
	queue_redraw()


## Hover tooltip input: the scene host forwards the pointer's WORLD position
## (it owns the camera/screen->world conversion — the layer never sees screen
## pixels, mirroring the bridge pattern of ADR-0005). Hit-tests each glyph
## rect; updates tooltip_visible / tooltip_instance_id.
func notify_pointer_world_position(pos: Vector2) -> void:
	var hovered_id := -1
	var s: float = _glyph_size_px * glyph_scale()
	var half := s * 0.5
	for id in icons.keys():
		var entry: Dictionary = icons[id]
		var ipos: Vector2 = entry["pos"]
		var rect := Rect2(ipos - Vector2(half, half), Vector2(s, s))
		if rect.grow(4.0).has_point(pos):
			hovered_id = int(id)
			break
	if hovered_id != tooltip_instance_id:
		tooltip_instance_id = hovered_id
		tooltip_visible = hovered_id != -1
		queue_redraw()


## Fade driver — the ONLY per-frame path in the layer. Exists solely to
## advance in-flight one-time fade-ins; it is disabled (set_process(false))
## whenever every icon is static, so the steady state costs zero per frame
## (no _process polling of game state — refresh is signal-driven).
func _process(delta: float) -> void:
	_advance_fade(delta)


## Advances all fading icons by [delta] seconds toward alpha 1.0, then flips
## each to STATE_STATIC — a TERMINAL transition (AC8: one-time fade-in, then
## static; no code path re-enters fading, so a stable layout cannot pulse).
## Public via _call in white-box tests (fade_duration_s = 0 makes the icon
## static immediately). No-op when nothing is fading.
func _advance_fade(delta: float) -> void:
	if icons.is_empty():
		return
	var any_fading := false
	for id in icons.keys():
		var entry: Dictionary = icons[id]
		if entry["state"] == STATE_FADING_IN:
			var duration := maxf(_fade_duration_s, 0.001)
			var alpha: float = float(entry["alpha"]) + delta / duration
			if alpha >= 1.0:
				entry["alpha"] = 1.0
				entry["state"] = STATE_STATIC
			else:
				entry["alpha"] = alpha
				any_fading = true
	if not any_fading:
		set_process(false)
	queue_redraw()


## S1 handler (grid_changed). Same-frame removal: icons whose equipment is no
## longer in the placed set vanish the same frame the equipment does (GDD Edge
## Case — never leave an orphan icon over an empty cell). Reachability flips
## are reconciled on S8 instead, because Congestion batch-recomputes
## access_reachable at the next tick boundary (its grid_changed handler only
## marks pending) — reading flags here would see a stale set.
func _on_grid_changed(_footprint_cells_changed: Array, _access_cells_changed: Array) -> void:
	_refresh()


## S8 handler (congestion_updated, once per tick after Congestion's recompute
## + swap). Full reconcile: add icons for flag-present-and-false, remove for
## flag-present-and-true / flag-absent. Idempotent — a quiet tick reconciles
## to the same set and bumps nothing (flicker protection).
func _on_congestion_updated() -> void:
	_refresh()


## The single reconcile routine. Reads the CURRENT placed set + the CURRENT
## access_reachable flags, and mutates the icon registry to match:
##   1. remove icons whose equipment is no longer placed (same frame);
##   2. add an icon for every placed equipment whose flag is present AND false
##      (fade-in once if post-entry, static if on-entry);
##   3. remove icons for placed equipment whose flag is present AND true, or
##      absent (machinery off / never evaluated — never a barricade).
## set_version bumps only when the set actually mutates. Iteration is over the
## grid's placed-instance array (stable per grid state), never hash order.
func _refresh() -> void:
	if _grid == null or _congestion == null:
		return
	var placed: Array = _grid.get_placed_instances()
	var current_ids: Dictionary = {}
	for inst in placed:
		current_ids[int(inst.instance_id)] = true

	var mutated := false
	# 1) same-frame removal for cleared equipment.
	for id in icons.keys():
		if not current_ids.has(id):
			icons.erase(id)
			mutated = true

	# 2+3) reachability reconcile — flag-presence semantics (class header).
	var ar: Dictionary = _congestion.access_reachable
	for inst in placed:
		var instance_id: int = int(inst.instance_id)
		var has_flag: bool = ar.has(instance_id)
		if has_flag and not bool(ar[instance_id]):
			if not icons.has(instance_id):
				_add_icon(instance_id, inst)
				mutated = true
		elif icons.has(instance_id):
			icons.erase(instance_id)
			mutated = true

	if mutated:
		set_version += 1
		queue_redraw()


## Creates one icon entry for [instance_id], anchored at the equipment's FIRST
## access cell (matching Congestion's and MemberSim's arrival semantics —
## access_cells[0]), offset `_anchor_offset_px` above the cell center.
## Fade rule (GDD): post-entry additions fade in once (`_entered` true);
## on-entry materialization (Core Rule 5) is STATIC immediately. Equipment with
## no access cells is never anchored and gets no icon.
func _add_icon(instance_id: int, inst: Variant) -> void:
	var access_cells: Array = inst.access_cells
	if access_cells.is_empty():
		return
	var cell: Vector2i = access_cells[0]
	var pos: Vector2 = _grid.grid_to_world_center(cell, _cell_size) + Vector2(0.0, -_anchor_offset_px)
	var fading: bool = _entered and _fade_duration_s > 0.0
	icons[instance_id] = {
		"cell": cell,
		"pos": pos,
		"state": STATE_FADING_IN if fading else STATE_STATIC,
		"alpha": 0.0 if fading else 1.0,
	}
	if fading:
		set_process(true)


## Renders every barricade / broken-link glyph (GDD Core Rule 5 — Soft
## Charcoal outline, Dusty Rose fill secondary, shape-first / colorblind-safe
## by construction: the diagonal broken-link slash carries the state with
## color removed) plus the hover tooltip when active. All draw sizes are
## scaled by glyph_scale() for the fixed UI-layer contract. Draw is a pure
## function of the icon registry — no state mutation here.
func _draw() -> void:
	var s: float = _glyph_size_px * glyph_scale()
	if s < 1.0:
		return
	var half := s * 0.5
	# 描边宽度 × STROKE_COMPENSATION：WorldRoot scale 0.75 下亚像素描边消失
	# （4.7.1 pitfall，world_scale.gd）—— 1.5 数据值补偿后 ≈2.0 world px =
	# 1.5 viewport px，稳定渲染。
	var outline_w: float = maxf(_outline_width_px, 1.0) * WorldScale.STROKE_COMPENSATION * glyph_scale()
	for id in icons.keys():
		var entry: Dictionary = icons[id]
		var alpha: float = float(entry["alpha"])
		if alpha <= 0.0:
			continue
		var pos: Vector2 = entry["pos"]
		var rect := Rect2(pos - Vector2(half, half), Vector2(s, s))
		# Dusty Rose fill — secondary reinforcement only (shape carries state).
		draw_rect(rect, Color(_fill_color, _fill_alpha * alpha), true)
		# Soft Charcoal outline — the primary channel.
		var outline := Color(_outline_color, alpha)
		draw_rect(rect, outline, false, outline_w)
		# Broken-link diagonal slash — the shape-first cue (colorblind-safe).
		draw_line(
			rect.position + Vector2(s * 0.18, s * 0.82),
			rect.position + Vector2(s * 0.82, s * 0.18),
			outline,
			outline_w
		)
	_draw_tooltip()


## One-line hover tooltip, drawn with the 4.7.1 draw_string signature —
## draw_string(font, pos, text, alignment, width, font_size, color): FIRST arg
## Font, font_size BEFORE color. Guarded by ThemeDB.fallback_font != null so
## headless (no theme) runs never crash — the state machine (tooltip_visible)
## is correct even when the font cannot render.
func _draw_tooltip() -> void:
	if not tooltip_visible or not icons.has(tooltip_instance_id):
		return
	var font := ThemeDB.fallback_font
	if font == null:
		return
	var entry: Dictionary = icons[tooltip_instance_id]
	var pos: Vector2 = entry["pos"]
	var text_size: Vector2 = font.get_string_size(
		TOOLTIP_TEXT, HORIZONTAL_ALIGNMENT_LEFT, -1, _tooltip_font_size_px
	)
	var pad := 4.0
	var bg_pos := pos + Vector2(
		-text_size.x * 0.5 - pad,
		-_glyph_size_px * glyph_scale() - text_size.y - pad * 2.0
	)
	var bg_rect := Rect2(bg_pos, text_size + Vector2(pad * 2.0, pad * 2.0))
	draw_rect(bg_rect, Color(0.05, 0.05, 0.06, 0.85), true)
	draw_string(
		font,
		bg_rect.position + Vector2(pad, pad),
		TOOLTIP_TEXT,
		HORIZONTAL_ALIGNMENT_LEFT,
		-1,
		_tooltip_font_size_px,
		_tooltip_color
	)


## Reads the [config] Dictionary into the tuning fields. Missing keys keep the
## art-bible / GDD anchors. Colors accept either a Color or an html String.
## Guardrails: glyph size floored (a degenerate 0px icon is never drawable),
## fill alpha clamped to [0,1], outline width floored.
func _apply_config(config: Dictionary) -> void:
	_glyph_size_px = maxf(float(config.get(CONFIG_GLYPH_SIZE, _glyph_size_px)), 2.0)
	_fade_duration_s = maxf(float(config.get(CONFIG_FADE_DURATION, _fade_duration_s)), 0.0)
	_anchor_offset_px = float(config.get(CONFIG_ANCHOR_OFFSET, _anchor_offset_px))
	_fill_alpha = clampf(float(config.get(CONFIG_FILL_ALPHA, _fill_alpha)), 0.0, 1.0)
	_outline_width_px = maxf(float(config.get(CONFIG_OUTLINE_WIDTH, _outline_width_px)), 0.5)
	_outline_color = Color(config.get(CONFIG_OUTLINE_COLOR, _outline_color))
	_fill_color = Color(config.get(CONFIG_FILL_COLOR, _fill_color))
	_tooltip_color = Color(config.get(CONFIG_TOOLTIP_COLOR, _tooltip_color))
	_tooltip_font_size_px = maxi(int(config.get(CONFIG_TOOLTIP_FONT_SIZE, _tooltip_font_size_px)), 6)
