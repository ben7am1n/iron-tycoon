## HeatmapLayer — the congestion/flow heatmap layer (Story CFO-001, presentation epic).
##
## Consumes Congestion's per-cell density field + S8 `congestion_updated`
## (10 Hz) and renders it as a soft bilinear fog over the grid floor.
##
## RENDERING (GDD Core Rule 2): the grid-sized (13×10 in the GDD example)
## density field is written into an Image/ImageTexture and sampled by a
## CanvasItem shader over a grid-covering ColorRect (this node). The shader
## forces BILINEAR sampling on THIS sampler only (`filter_linear` hint),
## independent of the project's global Nearest filter — the deliberate,
## isolated exception that makes the heatmap read as soft fog, not a
## per-cell spreadsheet. `DrawableTexture2D` (4.7 NEW) is explicitly
## BYPASSED for MVP (GDD Core Rule 2 + OQ1 + TR-CFO-010): unverified against
## the local 4.7.1, zero benefit at 130 texels. `ImageTexture.update()` is
## the correct refresh call (Core Rule 3).
##
## UPDATE CADENCE (GDD Core Rule 3 / AC9): the Image is rewritten and
## `ImageTexture.update()` called ONLY from the `congestion_updated` signal
## handler — never in `_process`. This script deliberately defines NO
## `_process` method (the cadence test asserts its absence); the shader
## re-renders every frame from the currently-bound texture for free.
##
## TOGGLE + ONE-TIME TIP (GDD Core Rule 8 / AC1 / AC7): heatmap default OFF.
## `toggle_flow_overlay()` is the toggle entry point (H key / HUD utility
## button live in the HUD epic — Story 002+; this layer owns the state and
## the one-time-tip contract). The FIRST toggle ON in a session emits
## `one_time_tip_requested` exactly once, then never again (per-instance
## lifetime flag); auto-dismiss (~4 s) is handled display-side by the HUD
## (OQ4 copy also lives there) — this layer guarantees the "never recurs"
## half of the contract.
##
## CELL→WORLD MAPPING: uses GridSystem.grid_world_conversion
## (grid_to_world_corner); cell_size is injected via init, NEVER hardcoded
## (architecture pinned value).
##
## 4.7.1 PITFALLS respected (GDD Pinned Engine Caveats):
##   - class_name follows extends immediately (same line).
##   - `var x := expr` avoided on Variant returns — explicit `: float`
##     when reading per_cell_density through the duck-typed surface.
##   - The Congestion read surface is duck-typed (`Object`), mirroring
##     Congestion's own duck-typed MemberSim seam, so unit tests can inject
##     a fake emitter. The GRID stays typed `GridStateReader` (ADR-0003:
##     never duck-type the grid read surface).
class_name HeatmapLayer extends ColorRect

## Presentation-internal signal (layer → HUD): emitted the FIRST time the
## heatmap is toggled ON in a session. The receiver (HUD epic) displays the
## contextual tip for ~4 s / until next click. This is an intra-Presentation
## signal, not a simulation-system signal — it is deliberately NOT in the
## ADR-0005 Signal Catalog (mirrors the ADR's "internal to a single
## system" exclusion).
signal one_time_tip_requested(tip_text: String)

## Presentation-internal signal (layer → sibling layers): emitted on EVERY
## toggle with the new enabled state. The congestion-glyph layer (Story
## CFO-002, GDD Core Rule 1) subscribes to this so ALL per-equipment glyphs
## show/hide with the heatmap — ONE shared toggle state, the heatmap is the
## single owner. Also intra-Presentation, deliberately NOT in the ADR-0005
## Signal Catalog.
signal flow_overlay_toggled(enabled: bool)

## Config keys (data-driven per Control Manifest — defaults = GDD anchors).
const CONFIG_LOW_CUT := "low_cut"
const CONFIG_HIGH_CUT := "high_cut"
const CONFIG_LAYER_OPACITY := "heatmap_layer_opacity"
const CONFIG_DRAG_DIM_OPACITY := "drag_dim_opacity"
const CONFIG_TIP_DURATION_S := "onetime_tip_duration_s"

## GDD Formula: output color = Dusty Rose #E0A0A0 (soft, never harsh red —
## Pillar 2). RGB is fixed; only alpha varies with density.
const DUSTY_ROSE := Color("e0a0a0")

## Drag-dim effective layer opacity (GDD Core Rule 7 / AC3): the heatmap
## yields to the placement ghost during a drag by dropping to ≤20% opacity
## (knob 0.1–0.3, default 0.2). The modulate target is derived as
## drag_dim_opacity / heatmap_layer_opacity because the layer opacity is
## BAKED into the texel alpha (density_to_heat) — the modulate multiplier
## must be the ratio so the EFFECTIVE rendered alpha lands at
## heat_alpha × drag_dim_opacity (the GDD's "≤0.2 during drag" variable).
const DEFAULT_DRAG_DIM_OPACITY := 0.2

## MVP placeholder copy for the one-time contextual tip (final wording is
## OQ4 / /ux-design; shape kept localization-ready).
const ONE_TIME_TIP_TEXT := "Flow overlay on: soft pink = crowding. Toggle with H."

## CanvasItem shader — samples the heatmap texture with per-sampler
## BILINEAR (`filter_linear`), the isolated exception to the global Nearest
## filter (GDD Core Rule 2 / engine notes). Zero DrawableTexture2D usage.
const HEATMAP_SHADER_CODE := """
shader_type canvas_item;
uniform sampler2D heatmap_tex : filter_linear;
void fragment() {
	COLOR = texture(heatmap_tex, UV);
}
"""

# === Injected dependencies ===
## Duck-typed Congestion read surface: `per_cell_density(cell: Vector2i) ->
## float` + the `congestion_updated` signal. Typed as Object so tests can
## inject a fake emitter (same seam Congestion uses for MemberSim).
var _congestion: Object = null
## Typed grid read surface (ADR-0003 — never duck-type the grid): supplies
## get_dimensions() + grid_to_world_conversion.
var _grid: GridStateReader = null
## Presentation cell size, injected — never hardcoded (GDD D.4 handoff).
var _cell_size: int = 32

# === Tuning values (GDD Tuning Knobs anchors; _apply_config overrides) ===
var _low_cut: float = 0.2
var _high_cut: float = 0.8
var _layer_opacity: float = 0.6
var _drag_dim_opacity: float = DEFAULT_DRAG_DIM_OPACITY
var _tip_duration_s: float = 4.0

# === State ===
var _enabled: bool = false
var _one_time_tip_emitted: bool = false
var _initialized: bool = false

## Drag-dim state (GDD Core Rule 7 / AC3). True while a placement drag is
## active (observed by the overlay controller via PlacementSystem.is_dragging).
## While true, the effective layer opacity yields to ≤20% (the placement
## ghost reads clearly — Core Rule 7: ambient context yields to active
## decisions). Exposed as a white-box observable so tests can assert the
## dim/restore contract.
var _drag_active: bool = false

## Whether the heatmap was in its ON state when the drag began (Core Rule 7
## edge: "toggling mid-drag sets target opacity; drag-dim still overrides
## to ≤20% until drag end"). Captured at set_drag_active(true). While a
## drag is active the layer shows at the drag target iff it was ON at drag
## start OR the player toggles it ON mid-drag — toggling OFF mid-drag does
## NOT hide it immediately (drag-dim overrides until drag end, then the
## toggled state applies). An OFF-at-drag-start layer with no mid-drag
## toggle stays hidden (the GDD states table defines no Hidden→Dimmed
## transition).
var _drag_visible_base: bool = false

# === Texture state (exposed for white-box tests, matching the codebase's
# observable-state convention — Congestion exposes prev/next/density_cells) ===
## The 13×10 (grid-sized) RGBA8 Image, rewritten per congestion_updated.
var heatmap_image: Image = null
## The ImageTexture bound to the shader; refresh() calls update() on it.
var heatmap_texture: ImageTexture = null

## How many times the Image has been rewritten + uploaded. Incremented ONLY
## by refresh(), which runs ONLY on congestion_updated — the observable
## half of AC9's "10 Hz cadence, never per-frame" contract.
var refresh_count: int = 0


## Two-phase setup (mirrors the sim-system init pattern): stores injected
## dependencies, applies the data-driven config, builds the texture, sizes
## the rect to the grid, attaches the shader, and subscribes to S8.
## [congestion] is duck-typed (per_cell_density + congestion_updated);
## [grid] is the typed GridStateReader; [cell_size] is the architecture
## pinned value (e.g. SimulationOrchestrator.PLACEMENT_CELL_SIZE).
## Default state is OFF and hidden (AC1) — no legend is created here
## (Core Rule 8: legend lives on the HUD toggle button's hover popover).
func init(congestion: Object, grid: GridStateReader, cell_size: int, config: Dictionary = {}) -> void:
	if _initialized:
		push_error("HeatmapLayer.init(): called twice")
		return
	_initialized = true
	_congestion = congestion
	_grid = grid
	_cell_size = cell_size
	_apply_config(config)
	_setup_texture()
	_setup_layout()
	_setup_shader()
	# AC1: fresh boot → heatmap OFF, nothing on-screen.
	_enabled = false
	visible = false
	modulate.a = 0.0
	# S8 subscription (typed connection only — ADR-0005). This is the ONLY
	# refresh trigger; there is deliberately no _process path.
	if _congestion != null:
		_congestion.congestion_updated.connect(_on_congestion_updated)


## Reads the [config] Dictionary into the tuning fields. Missing keys keep
## the GDD-anchor defaults (same convention as Congestion._apply_config).
## Guardrails: cutoffs/opacity clamped to [0,1]; high_cut must exceed
## low_cut (a degenerate smoothstep band would misbehave — GDD safe ranges
## 0.15–0.30 / 0.6–0.85); tip duration floored at 0.1 s.
func _apply_config(config: Dictionary) -> void:
	var low := clampf(float(config.get(CONFIG_LOW_CUT, _low_cut)), 0.0, 1.0)
	var high := clampf(float(config.get(CONFIG_HIGH_CUT, _high_cut)), 0.0, 1.0)
	if high <= low:
		push_error("HeatmapLayer: high_cut (%s) must exceed low_cut (%s) — using GDD anchors." % [str(high), str(low)])
		low = 0.2
		high = 0.8
	_low_cut = low
	_high_cut = high
	_layer_opacity = clampf(float(config.get(CONFIG_LAYER_OPACITY, _layer_opacity)), 0.0, 1.0)
	_drag_dim_opacity = clampf(float(config.get(CONFIG_DRAG_DIM_OPACITY, _drag_dim_opacity)), 0.0, 1.0)
	_tip_duration_s = maxf(float(config.get(CONFIG_TIP_DURATION_S, _tip_duration_s)), 0.1)


## Builds the 13×10 (grid-sized) RGBA8 Image + ImageTexture. Dimensions come
## from the grid read surface — the GDD's 13×10 is an example, never a
## hardcode here.
func _setup_texture() -> void:
	var dims: Vector2i = _grid.get_dimensions()
	heatmap_image = Image.create(dims.x, dims.y, false, Image.FORMAT_RGBA8)
	heatmap_texture = ImageTexture.create_from_image(heatmap_image)


## Sizes this ColorRect to cover the whole grid via GridSystem's
## grid_world_conversion (grid_to_world_corner(dims, cell_size)) — cell
## size is injected, never hardcoded (architecture pinned value).
func _setup_layout() -> void:
	var dims: Vector2i = _grid.get_dimensions()
	size = _grid.grid_to_world_corner(dims, _cell_size)


## Attaches the CanvasItem shader (per-sampler BILINEAR) to this ColorRect
## and binds the heatmap texture to its sampler.
func _setup_shader() -> void:
	var shader := Shader.new()
	shader.code = HEATMAP_SHADER_CODE
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter("heatmap_tex", heatmap_texture)
	material = mat


## S8 handler (10 Hz): the ONLY refresh path. Zero payload — reads the
## current field directly from Congestion (ADR-0005 catalog S8).
func _on_congestion_updated() -> void:
	refresh()


## Rewrites every texel from per_cell_density(cell) and uploads via
## ImageTexture.update() — the correct 4.7 refresh call. Called ONLY from
## _on_congestion_updated (10 Hz cadence, never per-frame — AC9). A no-op
## until init() supplies a congestion + grid.
func refresh() -> void:
	if not _initialized or _grid == null or _congestion == null:
		return
	var dims: Vector2i = _grid.get_dimensions()
	for y in dims.y:
		for x in dims.x:
			# Explicit `: float` — per_cell_density returns Variant through
			# the duck-typed surface; `:=` inference would fail (4.7.1 pitfall).
			var d: float = _congestion.per_cell_density(Vector2i(x, y))
			heatmap_image.set_pixel(x, y, density_to_heat(d))
	heatmap_texture.update(heatmap_image)
	refresh_count += 1


## GDD Formula: heat_alpha = smoothstep(low_cut, high_cut, density_cell);
## output = Dusty Rose #E0A0A0 at alpha = heat_alpha × heatmap_layer_opacity.
## Below low_cut the cell is fully transparent (calm); above high_cut it is
## full Dusty Rose at layer opacity. Input clamped to [0,1] defensively.
func density_to_heat(density_cell: float) -> Color:
	var d := clampf(density_cell, 0.0, 1.0)
	var heat_alpha := smoothstep(_low_cut, _high_cut, d)
	return Color(DUSTY_ROSE.r, DUSTY_ROSE.g, DUSTY_ROSE.b, heat_alpha * _layer_opacity)


## Toggle entry point (H key / HUD utility-cluster button — input wiring
## lives in the HUD epic). Returns the new enabled state. The FIRST toggle
## ON in a session emits one_time_tip_requested exactly once (AC7); later
## toggles never re-emit (flag is per-instance lifetime, never reset).
## Emits flow_overlay_toggled on EVERY toggle so the glyph layer (shared
## toggle, GDD Core Rule 1) follows the same state.
##
## Core Rule 7 edge ("toggling mid-drag"): while a drag is active the
## toggle changes the TARGET state but does NOT take effect visually — the
## drag-dim override keeps the layer at ≤20% until the drag ends, then the
## toggled state applies (set_drag_active(false) resolves it).
func toggle_flow_overlay() -> bool:
	_enabled = not _enabled
	if _enabled and not _one_time_tip_emitted:
		_one_time_tip_emitted = true
		one_time_tip_requested.emit(ONE_TIME_TIP_TEXT)
	_apply_visibility()
	flow_overlay_toggled.emit(_enabled)
	return _enabled


## True when the heatmap is toggled on. AC1's default-OFF contract is the
## init-time state (false).
func is_heatmap_on() -> bool:
	return _enabled


## AC3 / GDD Core Rule 7 — drag-dim entry point, called by the overlay
## controller on PlacementSystem drag-state transitions (is_dragging()).
##
## On drag begin ([active]=true): the heatmap tweens to ≤20% effective
## opacity (knob drag_dim_opacity, default 0.2) so the placement ghost
## reads clearly (Core Rule 7: ambient context yields to active decisions).
## On drag end ([active]=false): restores to the toggled state — ON → prior
## full opacity, OFF → hidden (AC3 "restores on drag end").
##
## Toggling mid-drag: the toggle sets the target opacity; the drag-dim
## still overrides to ≤20% until drag end, then the toggled state applies.
## An OFF-at-drag-start layer with no mid-drag toggle stays hidden (the GDD
## states table defines no Hidden→Dimmed transition).
func set_drag_active(active: bool) -> void:
	if _drag_active == active:
		return
	_drag_active = active
	if active:
		_drag_visible_base = _enabled
	_apply_visibility()


## True while a placement drag is dimming this layer (white-box observable
## for tests; the controller mirrors PlacementSystem.is_dragging()).
func is_drag_active() -> bool:
	return _drag_active


## Applies the enabled state: ON → visible + fade in; OFF → fade out then
## hide. The fade is a tween when the layer is in the scene tree; outside
## the tree (headless tests) the endpoint state is applied directly so
## assertions are synchronous.
##
## Drag override (Core Rule 7): while a drag is active the layer shows at
## the drag target iff it was ON at drag start OR was toggled ON mid-drag.
## Toggling OFF mid-drag keeps the drag target until drag end (the override
## wins), then the OFF state hides the layer.
func _apply_visibility() -> void:
	if _drag_active:
		if _enabled or _drag_visible_base:
			visible = true
			_fade_modulate_to(drag_dim_target())
		else:
			_fade_modulate_to(0.0)
		return
	if _enabled:
		visible = true
		_fade_modulate_to(1.0)
	else:
		_fade_modulate_to(0.0)


## The modulate.a target that yields the drag-dim EFFECTIVE opacity: the
## texel alpha already encodes heat_alpha × heatmap_layer_opacity (0.6 by
## default), so the modulate multiplier must be drag_dim_opacity /
## layer_opacity for the rendered alpha to land at heat_alpha ×
## drag_dim_opacity (the GDD's "≤0.2 during drag"). Guarded against a
## zero layer opacity (target 0.0 = invisible during drag).
func drag_dim_target() -> float:
	if _layer_opacity <= 0.0:
		return 0.0
	return clampf(_drag_dim_opacity / _layer_opacity, 0.0, 1.0)


## Tweens modulate:a to [target] when in the tree; outside the tree sets it
## immediately (and hides when fading to 0). Tween duration is presentation
## polish — not part of any AC.
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
