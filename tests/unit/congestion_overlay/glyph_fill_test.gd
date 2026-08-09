# tests/unit/congestion_overlay/glyph_fill_test.gd
# Story CFO-002: Per-Equipment Congestion Glyph
# (production/epics/congestion-flow-overlay/story-002-per-equipment-congestion-glyph.md)
#
# BLOCKING ACs covered:
#   AC10  fill_fraction = clamp(per_equipment_congestion, 0, 1) — pure
#        mapping + setter clamp; edges 0 / 1.0 / -0.1 / 1.5; integration
#        with the REAL Congestion rig (glyph fill == per_equipment_congestion)
#   Core Rule 4  shape/fill is the PRIMARY signal — fill rect height is a
#        pure function of fill_fraction (battery icon fills bottom-up);
#        Dusty Rose tint secondary; fill readable with color removed
#   AC6  colorblind/high-contrast: high_contrast thickens glyph outlines
#        (config-driven widths); shape channel unchanged
#   Core Rule 1  toggle-gated WITH the heatmap — ONE shared toggle state:
#        glyph layer mirrors the real HeatmapLayer.toggle_flow_overlay()
#        via flow_overlay_toggled; hidden at boot like the heatmap
#   Core Rule 3  fills applied ONLY on congestion_updated (10 Hz), never
#        _process; structural no-_process check; typed signal connections
#        (no string-based connect anywhere in the production layer)
#   Edge Case    equipment removed -> glyph dropped the SAME frame (S1
#        grid_changed reconcile, no orphan); removal during a refresh;
#        re-placement -> glyph recreated (fill 0 until next S8)
#
# Plus (story contract surface):
#   - glyphs anchored via grid_world_conversion (grid_to_world_corner),
#     cell_size injected, never hardcoded
#   - data-driven knobs via init config (glyph_width/height, outline
#     widths)
#   - shape-based rendering: production glyph uses draw_rect, never
#     draw_string (story engine note: glyphs are shape-based)
#   - 4.7.1 pitfalls honored: duck-typed congestion/heatmap seams for fake
#     emitters (grid stays typed), explicit `: float` reads, RefCounted
#     counter for signal counting (lambda closures can't write outer locals)
#
# Run standalone: godot --headless --script tests/unit/congestion_overlay/glyph_fill_test.gd
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"

const GRID_W := 13
const GRID_H := 10
const CELL_SIZE := 32
const R0 := 0
const EPS := 1e-6

var _pass := 0
var _fail := 0


func _init() -> void:
	if Engine.has_meta(RUNNER_META):
		return
	var result := run_all()
	quit(1 if int(result["fail"]) > 0 else 0)


func run_all() -> Dictionary:
	print("=".repeat(48))
	print("  UNIT TEST: Congestion Overlay — Per-Equipment Glyph (Story CFO-002)")
	print("=".repeat(48))

	_test_ac10_fill_mapping()
	_test_ac10_glyph_set_fill_clamps()
	_test_core_rule4_shape_first()
	_test_ac6_high_contrast()
	_test_shared_toggle_real_heatmap()
	_test_shared_toggle_fake_heatmap()
	_test_cadence_10hz()
	_test_no_per_frame_path()
	_test_placement_creates_glyph()
	_test_same_frame_removal()
	_test_removal_during_refresh()
	_test_readd_after_removal()
	_test_real_congestion_equivalence()
	_test_anchor_position_formula()

	print("\n=== GLYPH FILL TEST: %d passed, %d failed ===\n" % [_pass, _fail])
	return {"pass": _pass, "fail": _fail}


func _check(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
		print("  PASS: " + msg)
	else:
		_fail += 1
		print("  FAIL: " + msg)


func _check_float(actual: float, expected: float, msg: String) -> void:
	if absf(actual - expected) < EPS:
		_pass += 1
		print("  PASS: %s (got %s)" % [msg, str(actual)])
	else:
		_fail += 1
		print("  FAIL: %s (got %s, expected %s)" % [msg, str(actual), str(expected)])


# === Test doubles ===

## Fake Congestion read surface: both per_equipment_congestion and
## per_cell_density (the real Congestion exposes both; the duck-typed seam
## must treat fakes exactly like the real system) + congestion_updated.
class FakeCongestion:
	extends RefCounted

	signal congestion_updated

	var values: Dictionary = {}
	var field: Dictionary = {}

	func per_equipment_congestion(instance_id: int) -> float:
		return float(values.get(instance_id, 0.0))

	func per_cell_density(cell: Vector2i) -> float:
		return float(field.get(cell, 0.0))


## Fake HeatmapLayer: the shared-toggle seam (flow_overlay_toggled signal +
## is_heatmap_on()). For tests that must NOT depend on the real layer.
class FakeHeatmap:
	extends RefCounted

	signal flow_overlay_toggled(enabled: bool)

	var _on: bool = false

	func is_heatmap_on() -> bool:
		return _on

	func toggle() -> void:
		_on = not _on
		flow_overlay_toggled.emit(_on)


# === Helpers ===

func _GS() -> Script:
	return load("res://src/systems/grid_system.gd") as Script


func _MS() -> Script:
	return load("res://src/systems/member_sim.gd") as Script


func _SRG() -> Script:
	return load("res://src/systems/seeded_rng.gd") as Script


func _HL() -> Script:
	return load("res://src/presentation/heatmap_layer.gd") as Script


func _GLL() -> Script:
	return load("res://src/presentation/congestion_glyph_layer.gd") as Script


func _PROJ() -> Script:
	return load("res://src/presentation/oblique_projection.gd") as Script


func _make_orchestrator() -> Node:
	var orch: Node = load("res://src/systems/simulation_orchestrator.gd").new()
	root.add_child(orch)
	orch.call("_ready")
	return orch


## Real GridSystem: GRID_W x GRID_H all buildable, frozen, with [equipment]
## committed (each entry {id, fp, ac} — 1-cell footprint + 1-cell access).
func _make_grid(equipment: Array) -> RefCounted:
	var gs: RefCounted = _GS().new()
	gs.call("init", GRID_W, GRID_H)
	for y in GRID_H:
		for x in GRID_W:
			gs.call("set_buildable", Vector2i(x, y), true)
	gs.call("freeze_buildable")
	for eq in equipment:
		var fp: Array[Vector2i] = [eq["fp"]]
		var ac: Array[Vector2i] = [eq["ac"]]
		gs.call("commit", int(eq["id"]), fp, ac, R0)
	return gs


func _make_member_sim() -> RefCounted:
	return _MS().new()


## Real Congestion, configured with the real grid + member_sim.
func _make_congestion(gs: RefCounted, ms: RefCounted) -> Dictionary:
	var srg: RefCounted = _SRG().new()
	srg.call("init", 0xCF0002)
	var orch := _make_orchestrator()
	var cong: RefCounted = (load("res://src/systems/congestion.gd") as Script).new()
	cong.call("init", orch, srg, gs, ms)
	return {"congestion": cong, "seeded_rng": srg, "orchestrator": orch}


## A CongestionGlyphLayer wired to [heatmap] + [congestion] + [grid]. NOT
## added to the tree — off-tree _apply_visibility() applies endpoints
## synchronously so toggle/visibility assertions are deterministic.
func _make_layer(heatmap: Object, congestion: Object, grid: RefCounted, config: Dictionary = {}) -> Object:
	var layer: Object = _GLL().new()
	layer.call("init", heatmap, congestion, grid, CELL_SIZE, config)
	return layer


func _member(member_id: int, state: String, cell: Vector2i) -> Dictionary:
	return {"member_id": member_id, "state": state, "cell": cell}


## Typed commit helper — GridSystem.commit expects Array[Vector2i]; plain
## Array literals passed through .call() fail the typed-array check. Same
## convention as the heatmap test's _make_grid.
func _commit(gs: RefCounted, id: int, fp: Vector2i, ac: Vector2i) -> void:
	var footprint: Array[Vector2i] = [fp]
	var access: Array[Vector2i] = [ac]
	gs.call("commit", id, footprint, access, R0)


func _glyph(layer: Object, instance_id: int) -> Object:
	var glyphs: Dictionary = layer.get("glyphs")
	return glyphs.get(instance_id, null)


func _glyph_count(layer: Object) -> int:
	return int((layer.get("glyphs") as Dictionary).size())


func _refresh_count(layer: Object) -> int:
	return int(layer.get("refresh_count"))


# === AC10: fill_fraction = clamp(per_equipment_congestion, 0, 1) ===

func _test_ac10_fill_mapping() -> void:
	print("\n[AC10] congestion_glyph_fill = clamp(per_equipment_congestion, 0, 1)")
	var gs := _make_grid([])
	var fake := FakeCongestion.new()
	var layer := _make_layer(FakeHeatmap.new(), fake, gs)

	# Story QA example: per_equipment_congestion = 0.69 -> fill_fraction 0.69.
	_check_float(layer.call("congestion_glyph_fill", 0.69), 0.69,
		"AC10: congestion 0.69 -> fill_fraction 0.69 (story QA example)")
	_check_float(layer.call("congestion_glyph_fill", 0.0), 0.0,
		"AC10: congestion 0 -> fill_fraction 0 (empty outline)")
	_check_float(layer.call("congestion_glyph_fill", 1.0), 1.0,
		"AC10: congestion 1.0 -> fill_fraction 1.0 (fully filled)")
	_check_float(layer.call("congestion_glyph_fill", -0.1), 0.0,
		"AC10: congestion -0.1 -> clamped to 0.0")
	_check_float(layer.call("congestion_glyph_fill", 1.5), 1.0,
		"AC10: congestion 1.5 -> clamped to 1.0")
	# Presentation layer never trusts out-of-range input even though
	# Congestion already clamps.
	_check_float(layer.call("congestion_glyph_fill", 0.0 - 1e-9), 0.0,
		"AC10: tiny negative -> clamped to 0.0")
	layer.free()


func _test_ac10_glyph_set_fill_clamps() -> void:
	print("\n[AC10] glyph.set_fill clamps the same range")
	var fake := FakeCongestion.new()
	fake.values[7] = 0.69
	var gs2 := _make_grid([])
	# Place equipment AFTER layer init so the grid_changed from commit
	# creates the glyph via reconcile (same-frame placement).
	_commit(gs2, 7, Vector2i(2, 2), Vector2i(3, 2))

	var layer2 := _make_layer(FakeHeatmap.new(), fake, gs2)
	fake.congestion_updated.emit()
	var g: Object = _glyph(layer2, 7)
	_check(g != null, "AC10: glyph exists for placed equipment")
	if g == null:
		layer2.free()
		return
	_check_float(float(g.get("fill_fraction")), 0.69,
		"AC10: fake congestion 0.69 -> glyph fill_fraction 0.69")
	g.call("set_fill", -0.1)
	_check_float(float(g.get("fill_fraction")), 0.0,
		"AC10: set_fill(-0.1) -> clamped to 0.0")
	g.call("set_fill", 1.5)
	_check_float(float(g.get("fill_fraction")), 1.0,
		"AC10: set_fill(1.5) -> clamped to 1.0")
	layer2.free()


# === Core Rule 4: shape/fill is the primary signal ===

func _test_core_rule4_shape_first() -> void:
	print("\n[CORE RULE 4] fill rect height is a pure function of fill_fraction (battery icon)")
	var gs := _make_grid([])
	var fake := FakeCongestion.new()
	var layer := _make_layer(FakeHeatmap.new(), fake, gs)
	var g: Object = load("res://src/presentation/congestion_glyph.gd").new(Vector2(16, 20), 1.0)

	# Inner box: margin = outline + 1 = 2 -> 12 x 16.
	g.call("set_fill", 0.0)
	var fr0: Rect2 = g.call("fill_rect")
	_check_float(fr0.size.y, 0.0, "CR4: fill 0 -> zero-height fill rect (empty outline)")

	g.call("set_fill", 1.0)
	var fr1: Rect2 = g.call("fill_rect")
	_check_float(fr1.size.y, 16.0, "CR4: fill 1.0 -> full inner height (fully filled)")
	_check_float(fr1.position.y, 2.0, "CR4: full fill starts at the inner top margin")

	g.call("set_fill", 0.69)
	var fr069: Rect2 = g.call("fill_rect")
	_check_float(fr069.size.y, 16.0 * 0.69, "CR4: fill 0.69 -> 69%% of inner height (readable by fill alone)")
	_check_float(fr069.position.y, 2.0 + 16.0 * (1.0 - 0.69), "CR4: 0.69 fill starts 31%% down (bottom-up)")

	# Progressive: 0.25 / 0.5 / 0.75 heights strictly increase and are
	# proportional — the outline fills up as congestion rises.
	var prev_h := -1.0
	for f in [0.25, 0.5, 0.75]:
		g.call("set_fill", f)
		var fr: Rect2 = g.call("fill_rect")
		_check_float(fr.size.y, 16.0 * float(f), "CR4: fill %s -> %s%% height" % [str(f), str(f * 100.0)])
		_check(fr.size.y > prev_h, "CR4: fill rises monotonically (%s > %s)" % [str(fr.size.y), str(prev_h)])
		prev_h = fr.size.y

	# The fill rect does not depend on any color channel: the shape IS the
	# signal (colorblind-safe by construction — AC6). The fill color's alpha
	# ramps with fill, but the height formula never consults it.
	g.call("set_fill", 0.5)
	var fr_a: Rect2 = g.call("fill_rect")
	var fr_b: Rect2 = g.call("fill_rect")
	_check(fr_a == fr_b, "CR4: shape is deterministic (no color dependency)")
	layer.free()
	g.free()


# === AC6: colorblind / high-contrast ===

func _test_ac6_high_contrast() -> void:
	print("\n[AC6] high-contrast thickens glyph outlines; shape channel unchanged")
	var gs := _make_grid([])
	_commit(gs, 21, Vector2i(4, 4), Vector2i(5, 4))
	var fake := FakeCongestion.new()
	var layer := _make_layer(FakeHeatmap.new(), fake, gs)
	fake.values[21] = 0.5
	fake.congestion_updated.emit()

	var g: Object = _glyph(layer, 21)
	_check(g != null, "AC6: glyph exists for placed equipment")
	if g == null:
		layer.free()
		return
	_check_float(float(g.get("outline_width")), 1.0,
		"AC6: default outline width 1.0 (normal mode)")

	layer.call("set_high_contrast", true)
	_check(layer.get("high_contrast") == true, "AC6: high_contrast flag on")
	_check_float(float(g.get("outline_width")), 2.0,
		"AC6: high-contrast outline thickened to 2.0 (TR-CFO-011)")
	# The fill SHAPE channel is untouched by the contrast switch — the fill
	# ratio (height / inner height) stays exactly fill_fraction. The inner
	# box itself shrinks because a thicker outline takes more margin; the
	# relative fill — the colorblind-readable signal — is preserved.
	var fr_after: Rect2 = g.call("fill_rect")
	var inner_h_after := 20.0 - 2.0 * (2.0 + 1.0)
	_check_float(fr_after.size.y, inner_h_after * 0.5,
		"AC6: fill ratio unchanged in high contrast (%s of inner height)" % str(fr_after.size.y / inner_h_after))

	layer.call("set_high_contrast", false)
	_check_float(float(g.get("outline_width")), 1.0,
		"AC6: toggle back -> outline returns to 1.0")

	# Config-driven widths (data-driven per Control Manifest).
	var layer_cfg := _make_layer(FakeHeatmap.new(), fake, gs, {
		"outline_width": 1.5, "high_contrast_outline_width": 3.0,
	})
	fake.congestion_updated.emit()
	var g2: Object = _glyph(layer_cfg, 21)
	_check(g2 != null and float(g2.get("outline_width")) == 1.5,
		"AC6: config outline_width=1.5 applied")
	layer_cfg.call("set_high_contrast", true)
	_check(g2 != null and float(g2.get("outline_width")) == 3.0,
		"AC6: config high_contrast_outline_width=3.0 applied")
	layer.free()
	layer_cfg.free()


# === Core Rule 1: toggle-gated with the heatmap (shared state) ===

func _test_shared_toggle_real_heatmap() -> void:
	print("\n[TOGGLE] glyphs show/hide with the REAL HeatmapLayer (one shared toggle)")
	var gs := _make_grid([])
	var fake := FakeCongestion.new()
	var heatmap: Object = _HL().new()
	heatmap.call("init", fake, gs, CELL_SIZE, {})
	var layer := _make_layer(heatmap, fake, gs)

	# Boot: glyph layer OFF + hidden, mirroring the heatmap (AC1).
	_check(not layer.call("is_overlay_on"), "TOGGLE: glyph layer OFF at boot")
	_check(layer.get("visible") == false, "TOGGLE: glyph layer hidden at boot")

	# Heatmap toggles ON -> glyph layer follows (same call, same state).
	heatmap.call("toggle_flow_overlay")
	_check(heatmap.call("is_heatmap_on"), "TOGGLE: heatmap ON after toggle")
	_check(layer.call("is_overlay_on"), "TOGGLE: glyph layer mirrors heatmap ON")
	_check(layer.get("visible") == true, "TOGGLE: glyph layer visible when heatmap on")

	# Heatmap toggles OFF -> glyph layer hides again.
	heatmap.call("toggle_flow_overlay")
	_check(not heatmap.call("is_heatmap_on"), "TOGGLE: heatmap OFF after second toggle")
	_check(not layer.call("is_overlay_on"), "TOGGLE: glyph layer mirrors heatmap OFF")
	_check(layer.get("visible") == false, "TOGGLE: glyph layer hidden when heatmap off")
	heatmap.free()
	layer.free()


func _test_shared_toggle_fake_heatmap() -> void:
	print("\n[TOGGLE] duck-typed heatmap seam (fake emitter) drives the same visibility")
	var gs := _make_grid([])
	var fake := FakeCongestion.new()
	var heat := FakeHeatmap.new()
	var layer := _make_layer(heat, fake, gs)

	_check(not layer.call("is_overlay_on"), "TOGGLE-FAKE: OFF at boot")
	heat.toggle()
	_check(layer.call("is_overlay_on"), "TOGGLE-FAKE: ON follows fake heatmap")
	_check(layer.get("visible") == true, "TOGGLE-FAKE: visible follows")
	heat.toggle()
	_check(not layer.call("is_overlay_on"), "TOGGLE-FAKE: OFF follows again")

	# Layer created while the heatmap is ALREADY on adopts that state
	# (scene assembled mid-session).
	var heat2 := FakeHeatmap.new()
	heat2.toggle()
	var layer2 := _make_layer(heat2, fake, gs)
	_check(layer2.call("is_overlay_on"), "TOGGLE-FAKE: layer created under an ON heatmap adopts ON")
	_check(layer2.get("visible") == true, "TOGGLE-FAKE: visible when created under ON heatmap")
	layer.free()
	layer2.free()


# === Core Rule 3: 10 Hz cadence — signal-driven only ===

func _test_cadence_10hz() -> void:
	print("\n[CADENCE] fills applied ONLY on congestion_updated; no frames without a signal")
	var gs := _make_grid([])
	_commit(gs, 31, Vector2i(1, 1), Vector2i(2, 1))
	_commit(gs, 32, Vector2i(7, 7), Vector2i(8, 7))
	var fake := FakeCongestion.new()
	var layer := _make_layer(FakeHeatmap.new(), fake, gs)

	# No signal ever fired -> no refresh (glyphs exist only if a grid_changed
	# arrived — here commits happened before init, so none).
	_check(_refresh_count(layer) == 0, "CADENCE: zero signals -> zero refreshes")
	_check(_glyph_count(layer) == 0, "CADENCE: no glyphs before any signal (nothing to draw yet)")

	# One signal -> exactly one refresh; both glyphs exist, fills applied.
	fake.values[31] = 0.25
	fake.values[32] = 0.9
	fake.congestion_updated.emit()
	_check(_refresh_count(layer) == 1, "CADENCE: one signal -> one refresh")
	_check(_glyph_count(layer) == 2, "CADENCE: both equipment got glyphs after one signal")
	var g31: Object = _glyph(layer, 31)
	var g32: Object = _glyph(layer, 32)
	_check(g31 != null and float(g31.get("fill_fraction")) == 0.25, "CADENCE: glyph 31 fill 0.25")
	_check(g32 != null and float(g32.get("fill_fraction")) == 0.9, "CADENCE: glyph 32 fill 0.9")

	# Congestion value changes WITHOUT a signal -> no refresh, fills stay
	# stale (the layer must not poll on its own).
	fake.values[31] = 1.0
	_check(_refresh_count(layer) == 1, "CADENCE: value change without signal -> no refresh (no polling)")
	_check(g31 != null and float(g31.get("fill_fraction")) == 0.25,
		"CADENCE: fill still reflects the last signal's value (stale until next emit)")

	# Next signal -> refresh applies the new field.
	fake.congestion_updated.emit()
	_check(_refresh_count(layer) == 2, "CADENCE: second signal -> second refresh")
	_check(g31 != null and float(g31.get("fill_fraction")) == 1.0,
		"CADENCE: fill now reflects the updated value")
	layer.free()


# === Core Rule 3: structurally no per-frame path ===

func _test_no_per_frame_path() -> void:
	print("\n[CADENCE] no _process/_physics_process; typed connections; shape-based (no draw_string)")
	var gs := _make_grid([])
	var fake := FakeCongestion.new()
	var layer := _make_layer(FakeHeatmap.new(), fake, gs)

	var method_names: Array = []
	for m in layer.get_script().get_script_method_list():
		method_names.append(m["name"])
	_check(not method_names.has("_process"),
		"CADENCE: layer script defines no _process (per-frame refresh impossible)")
	_check(not method_names.has("_physics_process"),
		"CADENCE: layer script defines no _physics_process")

	# Typed signal connections only (Control Manifest Presentation rules) —
	# no string-based connect anywhere in the two production files.
	for path in [
		"res://src/presentation/congestion_glyph_layer.gd",
		"res://src/presentation/congestion_glyph.gd",
	]:
		var f := FileAccess.open(path, FileAccess.READ)
		_check(f != null, "STRUCT: production file readable: %s" % path)
		if f == null:
			continue
		var src := f.get_as_text()
		_check(not src.contains("connect(\""),
			"STRUCT: no string-based signal connect in %s" % path.get_file())
	_check((FileAccess.open("res://src/presentation/congestion_glyph_layer.gd", FileAccess.READ) as FileAccess) != null
		and (FileAccess.open("res://src/presentation/congestion_glyph_layer.gd", FileAccess.READ) as FileAccess).get_as_text().contains(".connect("),
		"STRUCT: layer uses typed signal.connect() (flow_overlay_toggled / congestion_updated / grid_changed)")

	# Shape-based rendering: the glyph draws with draw_rect and NEVER calls
	# draw_string (story engine note — text would need a Font, null under
	# headless; glyphs are shape-based). Doc comments may NAME the API
	# (mirrors the heatmap's DrawableTexture2D bypass note); the check
	# targets the call pattern only.
	var glyph_src := (FileAccess.open("res://src/presentation/congestion_glyph.gd", FileAccess.READ) as FileAccess).get_as_text()
	_check(glyph_src.contains("draw_rect"), "STRUCT: glyph renders with draw_rect (shape-first)")
	_check(not glyph_src.contains("draw_string("), "STRUCT: glyph never calls draw_string (shape-based only)")

	# Non-refreshing interactions never touch fill state.
	var before := _refresh_count(layer)
	layer.call("is_overlay_on")
	layer.call("congestion_glyph_fill", 0.5)
	layer.call("set_high_contrast", true)
	layer.call("set_high_contrast", false)
	_check(_refresh_count(layer) == before,
		"CADENCE: toggle/query/config calls write nothing (zero redundant work)")
	layer.free()


# === Placement: glyph created same frame via S1 ===

func _test_placement_creates_glyph() -> void:
	print("\n[PLACEMENT] new equipment -> glyph appears same frame (S1 reconcile), fill 0 until S8")
	var gs := _make_grid([])
	var fake := FakeCongestion.new()
	var layer := _make_layer(FakeHeatmap.new(), fake, gs)

	# No equipment yet.
	_check(_glyph_count(layer) == 0, "PLACEMENT: no glyphs on empty gym")

	# Commit AFTER layer init -> grid_changed -> reconcile creates the glyph
	# with fill 0.0 immediately (same frame, not waiting for S8).
	_commit(gs, 41, Vector2i(3, 3), Vector2i(4, 3))
	_check(_glyph_count(layer) == 1, "PLACEMENT: glyph created same frame as commit")
	var g: Object = _glyph(layer, 41)
	_check(g != null and float(g.get("fill_fraction")) == 0.0,
		"PLACEMENT: fresh glyph fill 0.0 (idle until congestion arrives)")
	_check(_refresh_count(layer) == 0, "PLACEMENT: placement itself is not a fill refresh (10 Hz contract intact)")

	# Next S8 fills it.
	fake.values[41] = 0.8
	fake.congestion_updated.emit()
	_check(float(g.get("fill_fraction")) == 0.8, "PLACEMENT: next signal fills the new glyph")
	layer.free()


# === Edge Case: same-frame removal ===

func _test_same_frame_removal() -> void:
	print("\n[REMOVAL] equipment removed -> glyph dropped the SAME frame (no orphan icon)")
	var gs := _make_grid([])
	_commit(gs, 51, Vector2i(1, 1), Vector2i(2, 1))
	_commit(gs, 52, Vector2i(7, 7), Vector2i(8, 7))
	var fake := FakeCongestion.new()
	var layer := _make_layer(FakeHeatmap.new(), fake, gs)
	fake.congestion_updated.emit()
	_check(_glyph_count(layer) == 2, "REMOVAL: two glyphs before removal")

	# clear() emits grid_changed -> reconcile drops glyph 51 immediately.
	gs.call("clear", 51)
	_check(_glyph_count(layer) == 1, "REMOVAL: glyph count 1 after clear (same frame)")
	_check(_glyph(layer, 51) == null, "REMOVAL: removed equipment's glyph is gone")
	_check(_glyph(layer, 52) != null, "REMOVAL: surviving equipment's glyph remains")
	_check(_refresh_count(layer) == 1, "REMOVAL: removal is not a fill refresh (10 Hz counter intact)")

	# Clearing the second one empties the layer entirely.
	gs.call("clear", 52)
	_check(_glyph_count(layer) == 0, "REMOVAL: zero glyphs after both cleared (never an orphan over an empty cell)")
	layer.free()


# === Edge Case: removal racing into a congestion_updated refresh ===

func _test_removal_during_refresh() -> void:
	print("\n[REMOVAL] removal during a congestion_updated refresh -> still no orphan")
	var gs := _make_grid([])
	_commit(gs, 61, Vector2i(1, 1), Vector2i(2, 1))
	_commit(gs, 62, Vector2i(7, 7), Vector2i(8, 7))
	var fake := FakeCongestion.new()
	var layer := _make_layer(FakeHeatmap.new(), fake, gs)
	fake.congestion_updated.emit()
	_check(_glyph_count(layer) == 2, "REMOVAL-RACE: two glyphs before the race")

	# clear() (grid_changed) THEN the S8 signal in the same frame: refresh()
	# reconciles first, so the orphan never survives the tick.
	gs.call("clear", 61)
	fake.congestion_updated.emit()
	_check(_glyph_count(layer) == 1, "REMOVAL-RACE: after clear+signal -> 1 glyph (no orphan)")
	_check(_glyph(layer, 61) == null, "REMOVAL-RACE: cleared glyph gone")
	_check(_glyph(layer, 62) != null, "REMOVAL-RACE: surviving glyph still present")
	_check(_refresh_count(layer) == 2, "REMOVAL-RACE: the signal still refreshed (fills applied to survivors)")
	layer.free()


# === Re-add after removal ===

func _test_readd_after_removal() -> void:
	print("\n[REMOVAL] removed-and-re-added id gets a fresh glyph (same-frame reconcile)")
	var gs := _make_grid([])
	_commit(gs, 71, Vector2i(1, 1), Vector2i(2, 1))
	var fake := FakeCongestion.new()
	var layer := _make_layer(FakeHeatmap.new(), fake, gs)
	fake.congestion_updated.emit()
	_check(_glyph_count(layer) == 1, "RE-ADD: one glyph before removal")

	gs.call("clear", 71)
	_check(_glyph_count(layer) == 0, "RE-ADD: glyph removed")

	# Same id committed again -> fresh glyph, fill 0 (stale fill never
	# survives the removal).
	_commit(gs, 71, Vector2i(1, 1), Vector2i(2, 1))
	var g: Object = _glyph(layer, 71)
	_check(g != null and _glyph_count(layer) == 1, "RE-ADD: fresh glyph for re-added id")
	_check(g != null and float(g.get("fill_fraction")) == 0.0,
		"RE-ADD: fresh glyph starts at fill 0.0 (no stale congestion)")
	layer.free()


# === AC10 integration: real Congestion rig ===

func _test_real_congestion_equivalence() -> void:
	print("\n[AC10] REAL Congestion rig: glyph fill_fraction == per_equipment_congestion (clamped)")
	var gs := _make_grid([{"id": 81, "fp": Vector2i(5, 4), "ac": Vector2i(6, 4)}])
	var ms := _make_member_sim()
	# 8 members piled at the access cell -> per-equipment congestion > 0
	# (dense term maxes, EMA eases in).
	var members: Array = []
	for i in 8:
		members.append(_member(300 + i, "WALKING_TO", Vector2i(6, 4)))
	ms.set("members", members)
	var rig := _make_congestion(gs, ms)
	var cong: RefCounted = rig["congestion"]
	var layer := _make_layer(FakeHeatmap.new(), rig["congestion"], gs)

	# One tick: Congestion recomputes, emits S8, layer refreshes.
	cong.call("on_tick", 0)

	var g: Object = _glyph(layer, 81)
	_check(g != null, "AC10: glyph exists for the real rig's equipment")
	if g == null:
		layer.free()
		return
	var c: float = cong.call("per_equipment_congestion", 81)
	_check(c > 0.0 and c <= 1.0, "AC10: congestion value in (0,1] after one tick (got %s)" % str(c))
	_check_float(float(g.get("fill_fraction")), c,
		"AC10: glyph fill_fraction == per_equipment_congestion (%s)" % str(c))
	_check_float(float(g.get("fill_fraction")), layer.call("congestion_glyph_fill", c),
		"AC10: fill == congestion_glyph_fill(per_equipment_congestion) (clamped mapping)")

	# Second tick with members gone -> congestion EMA decays; fill follows.
	ms.set("members", [])
	cong.call("on_tick", 1)
	var c2: float = cong.call("per_equipment_congestion", 81)
	_check(c2 < c, "AC10: congestion decays after members leave (%s < %s)" % [str(c2), str(c)])
	_check_float(float(g.get("fill_fraction")), c2,
		"AC10: fill follows the decayed value exactly")
	layer.free()


# === Anchoring via grid_world_conversion ===

func _test_anchor_position_formula() -> void:
	print("\n[ANCHOR] glyphs anchored via grid_to_world_corner (cell_size injected, never hardcoded)")
	var gs := _make_grid([{"id": 91, "fp": Vector2i(2, 3), "ac": Vector2i(3, 3)}])
	var fake := FakeCongestion.new()
	var layer := _make_layer(FakeHeatmap.new(), fake, gs)
	fake.congestion_updated.emit()

	# anchor = min-offset of footprint U access = (2,3).
	var anchor: Vector2i = Vector2i(2, 3)
	var expected: Vector2 = gs.call("grid_to_world_corner", anchor, CELL_SIZE)
	expected.x += (float(CELL_SIZE) - 16.0) / 2.0
	expected.y -= 20.0 + 2.0
	# V3.1 P1：glyph 层挂在投影后世界空间 —— 锚点经 oblique 投影。
	expected = _PROJ().proj(expected.x, expected.y, 0.0)
	var pos: Vector2 = layer.call("glyph_anchor_position", anchor)
	_check(pos == expected,
		"ANCHOR: glyph_anchor_position == grid_to_world_corner + centering/lift (%s)" % str(pos))
	var g: Object = _glyph(layer, 91)
	_check(g != null and (g.get("position") as Vector2) == expected,
		"ANCHOR: glyph node positioned at the formula's result")

	# cell_size is injected: a 16px grid scales the anchor accordingly.
	var layer16: Object = _GLL().new()
	layer16.call("init", FakeHeatmap.new(), fake, gs, 16, {})
	fake.congestion_updated.emit()
	var expected16: Vector2 = gs.call("grid_to_world_corner", anchor, 16)
	expected16.x += (float(16) - 16.0) / 2.0
	expected16.y -= 20.0 + 2.0
	# V3.1 P1：锚点经 oblique 投影。
	expected16 = _PROJ().proj(expected16.x, expected16.y, 0.0)
	var g16: Object = _glyph(layer16, 91)
	_check(g16 != null and (g16.get("position") as Vector2) == expected16,
		"ANCHOR: cell_size 16 repositions the glyph (%s)" % str(g16.get("position") if g16 != null else "null"))
	layer.free()
	layer16.free()
