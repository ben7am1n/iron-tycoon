## CongestionGlyphLayer — per-equipment congestion glyphs (Story CFO-002).
##
## GDD Core Rule 1/4: one small shape-filling icon per placed equipment,
## toggle-gated WITH the heatmap (ONE shared toggle state — the heatmap
## owns the state; this layer subscribes to HeatmapLayer.flow_overlay_toggled
## and mirrors visibility). Glyphs are the SECONDARY readout per the
## 2026-07-18 playtest note — heatmap clarity and dissipation-on-rearrange
## carry the crowding signal; this layer stays deliberately minimal.
##
## UPDATE CADENCE (GDD Core Rule 3 / ADR-0005 S8): fills are applied ONLY
## from the congestion_updated signal handler (10 Hz) — never in _process.
## This script deliberately defines NO _process/_physics_process (the
## cadence test asserts their absence).
##
## EQUIPMENT REMOVAL (GDD Edge Case): this layer subscribes to the SAME
## grid_changed signal Congestion uses (typed connection, ADR-0005) and
## reconciles its glyph set against GridStateReader.get_placed_instances()
## — a removed equipment's glyph is dropped the SAME FRAME the grid change
## is processed. No orphan icon over an empty cell, and removal during a
## congestion_updated refresh is handled (reconcile is idempotent).
##
## SHAPE-FIRST (TR-CFO-004): each glyph's outline-to-filled shape is the
## primary channel; Dusty Rose tint is secondary. High-contrast mode
## (TR-CFO-011) thickens outlines via set_high_contrast() — the shape
## channel never depends on color.
##
## ANCHORING: glyphs are world-space Node2D children (consistent with the
## heatmap's grid-covering ColorRect), positioned via GridSystem
## grid_world_conversion (grid_to_world_corner(anchor, cell_size)); cell
## size and glyph size are injected/data-driven, never hardcoded. Camera
## zoom-fixed rendering is deferred presentation polish (no camera exists
## yet in src/) — see evidence doc; playtest note says don't over-invest
## in glyph detail.
##
## 4.7.1 pitfalls respected: class_name follows extends immediately;
## cross-script refs use a preload const alias (class_name NOT globally
## registered headless); explicit `: float` on Variant returns through the
## duck-typed congestion/heatmap seams (grid stays typed GridStateReader,
## ADR-0003); typed signal connections only.
class_name CongestionGlyphLayer extends Node2D

## Cross-script class reference — preload alias (headless: class_name is
## not globally registered; GDD Pinned Engine Caveats).
const CongGlyphScript := preload("res://src/presentation/congestion_glyph.gd")

## Config keys (data-driven per Control Manifest — defaults = MVP anchors).
const CONFIG_GLYPH_WIDTH := "glyph_width"
const CONFIG_GLYPH_HEIGHT := "glyph_height"
const CONFIG_OUTLINE_WIDTH := "outline_width"
const CONFIG_HIGH_CONTRAST_OUTLINE := "high_contrast_outline_width"

## Presentation-only lift above the machine (px) — the glyph floats above
## the anchor cell so the machine stays visible. Analogous to the heatmap's
## hardcoded tween duration: presentation polish, not a gameplay value.
const GLYPH_LIFT := 2.0

# === Injected dependencies ===
## Duck-typed HeatmapLayer surface: `flow_overlay_toggled(enabled)` signal +
## `is_heatmap_on() -> bool`. Typed as Object so tests can inject a fake
## (same duck-typing seam the heatmap uses for Congestion).
var _heatmap: Object = null
## Duck-typed Congestion read surface: `per_equipment_congestion(instance_id)
## -> float` + the `congestion_updated` signal. Object for the same reason.
var _congestion: Object = null
## Typed grid read surface (ADR-0003 — never duck-type the grid): supplies
## get_placed_instances(), get_dimensions(), grid_to_world_conversion, and
## the S1 grid_changed signal (declared on GridSystem; same access pattern
## as Congestion._post_init).
var _grid: GridStateReader = null
## Presentation cell size, injected — never hardcoded.
var _cell_size: int = 32

# === Tuning values (config overrides; defaults = MVP anchors) ===
var _glyph_size: Vector2 = Vector2(16, 20)
var _outline_width: float = 1.0
var _high_contrast_outline: float = 2.0

# === State ===
var _enabled: bool = false
var _initialized: bool = false

## High-contrast mode (TR-CFO-011): when true the active outline width is
## _high_contrast_outline. Exposed for white-box tests (observable-state
## convention — Congestion exposes prev/next/access_reachable).
var high_contrast: bool = false

# === Observable glyph state (white-box tests, codebase convention) ===
## instance_id -> CongestionGlyph for every currently placed equipment.
## Reconcile keeps this EXACTLY in sync with the grid's placed set.
var glyphs: Dictionary = {}

## How many times fills were applied. Incremented ONLY by refresh(), which
## runs ONLY on congestion_updated — the observable half of the "10 Hz
## cadence, never per-frame" contract. Grid-changed reconciliation does NOT
## bump it (removal is not a refresh).
var refresh_count: int = 0


## Two-phase setup (mirrors the sim-system/layer init pattern): stores the
## injected dependencies, applies the data-driven config, subscribes to the
## shared toggle (heatmap), S8 (congestion), and S1 (grid). Default state is
## OFF and hidden, mirroring the heatmap (AC1: no glyphs on-screen at boot).
## [heatmap] is duck-typed (flow_overlay_toggled + is_heatmap_on); if the
## heatmap is already ON at init (scene assembled mid-session), this layer
## adopts that state immediately — one shared toggle, the heatmap owns it.
## [congestion] is duck-typed (per_equipment_congestion + congestion_updated);
## [grid] is the typed GridStateReader; [cell_size] is the pinned value.
func init(heatmap: Object, congestion: Object, grid: GridStateReader, cell_size: int, config: Dictionary = {}) -> void:
	if _initialized:
		push_error("CongestionGlyphLayer.init(): called twice")
		return
	_initialized = true
	_heatmap = heatmap
	_congestion = congestion
	_grid = grid
	_cell_size = cell_size
	_apply_config(config)
	# AC1: fresh boot → hidden, nothing on-screen (matches heatmap).
	_enabled = false
	visible = false
	modulate.a = 0.0
	# Shared toggle: follow the heatmap's state (Core Rule 1). Typed
	# connection only (ADR-0005 / Control Manifest Presentation rules).
	if _heatmap != null:
		_heatmap.flow_overlay_toggled.connect(_on_flow_overlay_toggled)
		if _heatmap.has_method("is_heatmap_on") and _heatmap.is_heatmap_on():
			_enabled = true
			_apply_visibility()
	# S8 (10 Hz fill refresh) — the ONLY fill path; no _process anywhere.
	if _congestion != null:
		_congestion.congestion_updated.connect(_on_congestion_updated)
	# S1 (same-frame removal + on-placement glyph creation).
	if _grid != null:
		_grid.grid_changed.connect(_on_grid_changed)


## Reads the [config] Dictionary into the tuning fields. Missing keys keep
## the MVP anchors (same convention as Congestion/HeatmapLayer).
## Guardrails: sizes floored at 1px; outline widths floored at 0.
func _apply_config(config: Dictionary) -> void:
	var w := maxf(float(config.get(CONFIG_GLYPH_WIDTH, _glyph_size.x)), 1.0)
	var h := maxf(float(config.get(CONFIG_GLYPH_HEIGHT, _glyph_size.y)), 1.0)
	_glyph_size = Vector2(w, h)
	_outline_width = maxf(float(config.get(CONFIG_OUTLINE_WIDTH, _outline_width)), 0.0)
	_high_contrast_outline = maxf(float(config.get(CONFIG_HIGH_CONTRAST_OUTLINE, _high_contrast_outline)), 0.0)


## S1 handler (grid_changed): reconcile the glyph set with the placed set.
## Same-frame removal — a removed equipment's glyph is dropped HERE,
## immediately (never an orphan over an empty cell, GDD Edge Case), and a
## newly placed equipment gets its glyph (fill 0 until the next S8).
func _on_grid_changed(_footprint_cells_changed: Array, _access_cells_changed: Array) -> void:
	if not _assert_initialized():
		return
	_reconcile_glyphs()


## S8 handler (10 Hz): the ONLY fill refresh path. Zero payload — reads
## per_equipment_congestion directly from Congestion (ADR-0005 catalog S8).
func _on_congestion_updated() -> void:
	refresh()


## Applies the current congestion values to every glyph (Core Rule 4 /
## AC10): fill_fraction = clamp(per_equipment_congestion, 0, 1). Also
## reconciles the glyph set first so a removal that raced into the same
## tick never leaves an orphan (idempotent). Called ONLY from
## _on_congestion_updated (10 Hz cadence, never per-frame).
func refresh() -> void:
	if not _assert_initialized() or _grid == null or _congestion == null:
		return
	_reconcile_glyphs()
	for inst in _grid.get_placed_instances():
		var id := int(inst.instance_id)
		var g: Node2D = glyphs.get(id)
		if g == null:
			continue
		# Explicit `: float` — per_equipment_congestion returns Variant
		# through the duck-typed surface; `:=` inference would fail
		# (4.7.1 pitfall).
		var c: float = _congestion.per_equipment_congestion(id)
		g.call("set_fill", congestion_glyph_fill(c))
	refresh_count += 1


## GDD Formula (congestion_glyph_fill): fill_fraction = clamp(per_equipment_congestion,
## 0, 1). Pure mapping — the glyph's outline fills 0 → full as this rises.
## Negative values and >1 values clamp (defensive: Congestion already
## clamps, but the presentation layer never trusts out-of-range input).
func congestion_glyph_fill(congestion_value: float) -> float:
	return clampf(congestion_value, 0.0, 1.0)


## High-contrast mode (TR-CFO-011): thickens every glyph's outline to the
## configured high-contrast width. The shape/fill channel is untouched —
## color was never the carrier, so nothing else changes.
func set_high_contrast(enabled: bool) -> void:
	high_contrast = enabled
	var w: float = _high_contrast_outline if enabled else _outline_width
	for id in glyphs.keys():
		var g: Node2D = glyphs[id]
		if g != null:
			g.call("set_outline_width", w)


## True when the glyph layer is toggled on — mirrors the heatmap's shared
## toggle state (this layer never toggles on its own).
func is_overlay_on() -> bool:
	return _enabled


## The world position a glyph sits at for [anchor] (the equipment's anchor
## cell): grid_to_world_corner(anchor, cell_size) + horizontal centering
## over the cell, lifted GLYPH_LIFT px above it. Exposed as a pure method
## so the anchoring formula is headless-testable (cell size injected,
## never hardcoded).
func glyph_anchor_position(anchor: Vector2i) -> Vector2:
	var pos: Vector2 = _grid.grid_to_world_corner(anchor, _cell_size)
	pos.x += (float(_cell_size) - _glyph_size.x) / 2.0
	pos.y -= _glyph_size.y + GLYPH_LIFT
	return pos


## Shared-toggle follower: the heatmap toggled (via toggle_flow_overlay) —
## glyphs show/hide with it. Visibility only; fills still come exclusively
## from S8.
func _on_flow_overlay_toggled(enabled: bool) -> void:
	_enabled = enabled
	_apply_visibility()


## Applies the enabled state: ON → visible + fade in; OFF → fade out then
## hide. Off-tree (headless tests) applies endpoints synchronously so the
## toggle/visibility assertions are deterministic (tweens only run in-tree).
func _apply_visibility() -> void:
	if _enabled:
		visible = true
		_fade_modulate_to(1.0)
	else:
		_fade_modulate_to(0.0)


## Tweens modulate:a to [target] when in the tree; outside the tree sets it
## immediately (and hides when fading to 0). Tween duration is presentation
## polish — not part of any AC (same convention as HeatmapLayer).
func _fade_modulate_to(target: float) -> void:
	if not is_inside_tree():
		modulate.a = target
		if target <= 0.0:
			visible = false
		return
	var tw := create_tween()
	tw.tween_property(self, "modulate:a", target, 0.2)
	if target <= 0.0:
		tw.tween_callback(func() -> void: visible = false)


## Syncs the glyph Dictionary to the grid's placed set: creates glyphs for
## new instances (anchored at the equipment anchor cell, fill 0), drops
## glyphs for removed instances the same frame. Idempotent — safe to call
## from both S1 and S8 in the same tick.
func _reconcile_glyphs() -> void:
	if _grid == null:
		return
	var present: Dictionary = {}
	for inst in _grid.get_placed_instances():
		var id := int(inst.instance_id)
		present[id] = true
		if not glyphs.has(id):
			glyphs[id] = _create_glyph(inst)
	for id in glyphs.keys():
		if not present.has(int(id)):
			_remove_glyph(int(id))


## Creates + anchors ONE glyph node for [inst]. Position comes from the
## grid_world_conversion anchor formula; size/outline come from config.
func _create_glyph(inst: PlacedInstance) -> Node2D:
	# Variant-typed so the script-specific calls stay dynamic (duck-typed
	# surface convention — same seam Congestion uses for MemberSim).
	var g: Variant = CongGlyphScript.new(_glyph_size, _outline_width)
	g.set_fill(0.0)
	g.position = glyph_anchor_position(inst.anchor)
	add_child(g)
	return g as Node2D


## Drops ONE glyph node. In-tree it is queue_freed (deferred deletion, safe
## during signal processing); off-tree (headless tests) it is freed
## immediately so assertions are deterministic.
func _remove_glyph(id: int) -> void:
	var g: Node2D = glyphs.get(id)
	glyphs.erase(id)
	if g == null:
		return
	if g.is_inside_tree():
		g.queue_free()
	else:
		g.free()


func _assert_initialized() -> bool:
	if _initialized:
		return true
	push_error("CongestionGlyphLayer method called before init()")
	return false
