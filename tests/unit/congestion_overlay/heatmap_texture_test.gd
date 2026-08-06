# tests/unit/congestion_overlay/heatmap_texture_test.gd
# Story CFO-001: Heatmap Layer (ImageTexture + Shader, 10Hz)
# (production/epics/congestion-flow-overlay/story-001-heatmap-layer.md)
#
# BLOCKING ACs covered:
#   AC9  texels match per_cell_density per-cell; refresh ONLY on the
#        congestion_updated signal (10 Hz cadence, never per-frame);
#        two signals in one frame both applied; zero frames without a
#        signal produce no redundant writes
#   AC1  fresh boot -> heatmap OFF, hidden, no legend node created
#   AC7  first toggle ON in a session -> one_time_tip_requested exactly
#        once; never recurs on later toggles
#   Formula  density_to_heat = smoothstep(0.2, 0.8, density) mapped to
#        Dusty Rose #E0A0A0 at alpha = heat_alpha x layer_opacity (0.6);
#        below low_cut transparent; above high_cut full Dusty Rose
#
# Plus (story contract surface):
#   - grid dims + cell_size drive the texture/rect (grid_world_conversion),
#     NOT a hardcoded 13x10
#   - data-driven knobs via init config (low_cut/high_cut/opacity)
#   - degenerate cutoff config (high <= low) falls back to GDD anchors
#   - no DrawableTexture2D anywhere in the production layer (GDD OQ1
#     BYPASS) — structural source check
#   - 4.7.1 pitfalls honored: duck-typed congestion seam for fake emitters
#     (grid stays typed), explicit `: float` reads, RefCounted counter for
#     signal counting (lambda closures can't write outer locals)
#
# Run standalone: godot --headless --script tests/unit/congestion_overlay/heatmap_texture_test.gd
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"

const GRID_W := 13
const GRID_H := 10
const CELL_SIZE := 32
const R0 := 0
const EPS := 1e-6
## Image.FORMAT_RGBA8 quantizes each channel to 1/255 — texel-vs-formula
## comparisons must tolerate up to 0.5/255 quantization (+ float noise).
const TEXEL_EPS := 1.0 / 255.0

var _pass := 0
var _fail := 0


func _init() -> void:
	if Engine.has_meta(RUNNER_META):
		return
	var result := run_all()
	quit(1 if int(result["fail"]) > 0 else 0)


func run_all() -> Dictionary:
	print("=".repeat(48))
	print("  UNIT TEST: Congestion Overlay — Heatmap Layer (Story CFO-001)")
	print("=".repeat(48))

	_test_ac1_default_off()
	_test_density_to_heat_formula()
	_test_density_to_heat_config_knobs()
	_test_ac9_texel_match_real_field()
	_test_ac9_cadence_fake_emitter()
	_test_ac9_two_signals_same_frame()
	_test_ac9_no_per_frame_refresh()
	_test_ac7_one_time_tip_once()
	_test_layout_grid_conversion()
	_test_no_drawable_texture2d()

	print("\n=== HEATMAP TEXTURE TEST: %d passed, %d failed ===\n" % [_pass, _fail])
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


func _check_color(actual: Color, expected: Color, msg: String) -> void:
	if absf(actual.r - expected.r) < EPS and absf(actual.g - expected.g) < EPS \
			and absf(actual.b - expected.b) < EPS and absf(actual.a - expected.a) < EPS:
		_pass += 1
		print("  PASS: %s (got %s)" % [msg, str(actual)])
	else:
		_fail += 1
		print("  FAIL: %s (got %s, expected %s)" % [msg, str(actual), str(expected)])


## 8-bit texture comparison: RGBA8 texels are quantized to 1/255, so use
## TEXEL_EPS (0.5/255 max quantization + noise) instead of full-precision
## EPS. Use for every texel-vs-formula comparison in this file.
func _check_texel(actual: Color, expected: Color, msg: String) -> void:
	if absf(actual.r - expected.r) < TEXEL_EPS and absf(actual.g - expected.g) < TEXEL_EPS \
			and absf(actual.b - expected.b) < TEXEL_EPS and absf(actual.a - expected.a) < TEXEL_EPS:
		_pass += 1
		print("  PASS: %s (got %s)" % [msg, str(actual)])
	else:
		_fail += 1
		print("  FAIL: %s (got %s, expected %s)" % [msg, str(actual), str(expected)])


# === Test double: a fake Congestion read surface for cadence/toggle tests ===
# Mirrors the duck-typed seam: per_cell_density(cell) -> float plus the
# congestion_updated signal. The production layer must treat this exactly
# like the real Congestion (it cannot tell them apart by type).
class FakeCongestion:
	extends RefCounted

	signal congestion_updated

	var field: Dictionary = {}

	func per_cell_density(cell: Vector2i) -> float:
		return float(field.get(cell, 0.0))


## RefCounted counter — lambda closures do NOT write back outer-scope
## locals (4.7.1 pitfall), so signal-counting spies must mutate a
## RefCounted object instead.
class TipCounter:
	extends RefCounted

	var count: int = 0
	var texts: Array = []

	func on_tip(text: String) -> void:
		count += 1
		texts.append(text)


# === Helpers ===

func _GS() -> Script:
	return load("res://src/systems/grid_system.gd") as Script


func _MS() -> Script:
	return load("res://src/systems/member_sim.gd") as Script


func _SRG() -> Script:
	return load("res://src/systems/seeded_rng.gd") as Script


func _HL() -> Script:
	return load("res://src/presentation/heatmap_layer.gd") as Script


func _make_orchestrator() -> Node:
	var orch: Node = load("res://src/systems/simulation_orchestrator.gd").new()
	root.add_child(orch)
	orch.call("_ready")
	return orch


## Real GridSystem: GRID_W x GRID_H all buildable, frozen. Equipment list
## may be empty — the per-cell field only needs dims + member positions.
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
	srg.call("init", 0xCF0001)
	var orch := _make_orchestrator()
	var cong: RefCounted = (load("res://src/systems/congestion.gd") as Script).new()
	cong.call("init", orch, srg, gs, ms)
	return {"congestion": cong, "seeded_rng": srg, "orchestrator": orch}


## A HeatmapLayer wired to [congestion] + [grid]. NOT added to the tree —
## off-tree _apply_visibility() applies endpoints synchronously so the
## toggle/visibility assertions are deterministic (tweens only run in-tree).
func _make_layer(congestion: Object, grid: RefCounted, config: Dictionary = {}) -> Object:
	var layer: Object = _HL().new()
	layer.call("init", congestion, grid, CELL_SIZE, config)
	return layer


func _member(member_id: int, state: String, cell: Vector2i) -> Dictionary:
	return {"member_id": member_id, "state": state, "cell": cell}


## Flat row-major cell index — MUST match GridSystem.flat_index.
func _fi(cell: Vector2i) -> int:
	return cell.y * GRID_W + cell.x


func _texel(layer: Object, cell: Vector2i) -> Color:
	return (layer.get("heatmap_image") as Image).get_pixel(cell.x, cell.y)


func _refresh_count(layer: Object) -> int:
	return int(layer.get("refresh_count"))


# === AC1: default OFF ===

func _test_ac1_default_off() -> void:
	print("\n[AC1] fresh boot -> heatmap OFF, hidden, no legend on-screen")
	var gs := _make_grid([])
	var ms := _make_member_sim()
	ms.set("members", [])
	var rig := _make_congestion(gs, ms)
	var layer := _make_layer(rig["congestion"], gs)

	_check(not layer.call("is_heatmap_on"), "AC1: heatmap toggle state OFF at boot")
	_check(layer.get("visible") == false, "AC1: layer hidden at boot")
	_check(layer.get("modulate") is Color and (layer.get("modulate") as Color).a == 0.0,
		"AC1: modulate alpha 0 at boot")
	_check(layer.get("heatmap_texture") != null, "AC1: texture exists (ready to render when toggled)")
	_check(layer.get_child_count() == 0, "AC1: no legend/child nodes created (legend lives on HUD hover only)")
	_check(_refresh_count(layer) == 0, "AC1: no refresh at boot (AC9: only signal-driven)")

	# Toggle ON -> visible and enabled.
	layer.call("toggle_flow_overlay")
	_check(layer.call("is_heatmap_on"), "AC1: after toggle -> ON")
	_check(layer.get("visible") == true, "AC1: after toggle -> visible")
	# Toggle OFF -> hidden again.
	layer.call("toggle_flow_overlay")
	_check(not layer.call("is_heatmap_on"), "AC1: second toggle -> OFF")
	_check(layer.get("visible") == false, "AC1: second toggle -> hidden")
	layer.free()


# === Formula: density_to_heat ===

func _test_density_to_heat_formula() -> void:
	print("\n[FORMULA] density_to_heat = smoothstep(0.2, 0.8, d) x Dusty Rose #E0A0A0 x 0.6")
	var gs := _make_grid([])
	var ms := _make_member_sim()
	ms.set("members", [])
	var rig := _make_congestion(gs, ms)
	var layer := _make_layer(rig["congestion"], gs)

	# density 0.5 -> heat_alpha = smoothstep(0.2,0.8,0.5) = 0.5 exactly;
	# at layer opacity 0.6 -> effective alpha 0.3 (story QA example).
	var c05: Color = layer.call("density_to_heat", 0.5)
	_check_float(c05.a, 0.3, "FORMULA: density 0.5 -> alpha 0.5 x 0.6 = 0.3")
	_check_color(c05, Color(Color("e0a0a0").r, Color("e0a0a0").g, Color("e0a0a0").b, 0.3),
		"FORMULA: density 0.5 -> Dusty Rose RGB with alpha 0.3")

	# Below low_cut (0.2) -> fully transparent (calm).
	var c01: Color = layer.call("density_to_heat", 0.1)
	_check_float(c01.a, 0.0, "FORMULA: density 0.1 (below low_cut) -> transparent")
	var c02: Color = layer.call("density_to_heat", 0.2)
	_check_float(c02.a, 0.0, "FORMULA: density == low_cut 0.2 -> transparent (smoothstep edge)")

	# At/above high_cut (0.8) -> full Dusty Rose at layer opacity.
	var c08: Color = layer.call("density_to_heat", 0.8)
	_check_float(c08.a, 0.6, "FORMULA: density 0.8 (high_cut) -> full alpha 0.6")
	var c10: Color = layer.call("density_to_heat", 1.0)
	_check_float(c10.a, 0.6, "FORMULA: density 1.0 -> full alpha 0.6")
	_check_color(c10, Color(Color("e0a0a0").r, Color("e0a0a0").g, Color("e0a0a0").b, 0.6),
		"FORMULA: density 1.0 -> full Dusty Rose #E0A0A0")

	# Defensive clamp keeps out-of-range densities inside [0,1].
	var cneg: Color = layer.call("density_to_heat", -0.5)
	_check_float(cneg.a, 0.0, "FORMULA: density -0.5 -> clamped -> transparent")
	var cov: Color = layer.call("density_to_heat", 1.5)
	_check_float(cov.a, 0.6, "FORMULA: density 1.5 -> clamped -> full alpha")

	# Empty gym edge case: density ~0 everywhere -> fully transparent even
	# when rendered (GDD edge case "no members / empty gym").
	var all_transparent := true
	for y in GRID_H:
		for x in GRID_W:
			if _texel(layer, Vector2i(x, y)).a != 0.0:
				all_transparent = false
	# No signal has fired yet — nothing was written. The refresh() call is
	# driven explicitly here to exercise the empty-field render path.
	layer.call("refresh")
	for y in GRID_H:
		for x in GRID_W:
			if _texel(layer, Vector2i(x, y)).a != 0.0:
				all_transparent = false
	_check(all_transparent, "FORMULA/EDGE: empty field renders fully transparent")
	layer.free()


# === Formula: config knobs + degenerate guard ===

func _test_density_to_heat_config_knobs() -> void:
	print("\n[CONFIG] low_cut/high_cut/heatmap_layer_opacity data-driven; degenerate guard")
	var gs := _make_grid([])
	var ms := _make_member_sim()
	ms.set("members", [])
	var rig := _make_congestion(gs, ms)

	var layer := _make_layer(rig["congestion"], gs, {
		"low_cut": 0.5, "high_cut": 1.0, "heatmap_layer_opacity": 0.5,
	})
	_check_float((layer.call("density_to_heat", 0.4) as Color).a, 0.0,
		"CONFIG: low_cut=0.5 -> density 0.4 transparent")
	_check_float((layer.call("density_to_heat", 0.75) as Color).a, 0.25,
		"CONFIG: high_cut=1.0, opacity=0.5 -> density 0.75 alpha 0.5 x 0.5 = 0.25")
	_check_float((layer.call("density_to_heat", 1.0) as Color).a, 0.5,
		"CONFIG: density 1.0 -> full at opacity 0.5")

	# Degenerate config (high_cut <= low_cut) must not produce a broken
	# smoothstep band — guard falls back to the GDD anchors (0.2 / 0.8).
	var bad := _make_layer(rig["congestion"], gs, {"low_cut": 0.9, "high_cut": 0.2})
	_check_float((bad.call("density_to_heat", 0.5) as Color).a, 0.3,
		"CONFIG: high<=low fallback -> density 0.5 alpha back to 0.3 (anchors)")
	layer.free()
	bad.free()


# === AC9: texel-vs-field equivalence (real Congestion rig) ===

func _test_ac9_texel_match_real_field() -> void:
	print("\n[AC9] real Congestion field -> texels match per_cell_density per-cell")
	var gs := _make_grid([])
	var ms := _make_member_sim()
	# Dense pile: 8 members on one interior cell -> density clamps to 1.0 at
	# the pile, 0.8/3 at the 4-neighbors, 0.0 everywhere untouched.
	var members: Array = []
	for i in 8:
		members.append(_member(100 + i, "WALKING_TO", Vector2i(5, 4)))
	ms.set("members", members)
	var rig := _make_congestion(gs, ms)
	var cong: RefCounted = rig["congestion"]
	var layer := _make_layer(rig["congestion"], gs)

	cong.call("on_tick", 0)

	# Sanity: the field itself reads the expected values (pile 1.0, neighbor
	# 0.8/3, far 0.0) — the layer's oracle input is the same surface.
	_check_float(cong.call("per_cell_density", Vector2i(5, 4)), 1.0,
		"AC9: field pile density == 1.0")
	_check_float(cong.call("per_cell_density", Vector2i(6, 4)), 0.8 / 3.0,
		"AC9: field neighbor density == 0.8/3")
	_check_float(cong.call("per_cell_density", Vector2i(0, 0)), 0.0,
		"AC9: field untouched cell == 0.0")

	# Hand-computed spot checks (break the self-reference of the sweep).
	var pile := _texel(layer, Vector2i(5, 4))
	_check_texel(pile, Color(Color("e0a0a0").r, Color("e0a0a0").g, Color("e0a0a0").b, 0.6),
		"AC9: pile texel == full Dusty Rose at alpha 0.6 (density 1.0 x opacity)")
	_check_texel(_texel(layer, Vector2i(0, 0)), Color(Color("e0a0a0").r, Color("e0a0a0").g, Color("e0a0a0").b, 0.0),
		"AC9: untouched texel alpha == 0.0 (transparent, calm)")
	_check(_texel(layer, Vector2i(6, 4)).a > 0.0 and _texel(layer, Vector2i(6, 4)).a < 0.6,
		"AC9: neighbor texel alpha strictly between 0 and 0.6 (%s)"
		% str(_texel(layer, Vector2i(6, 4)).a))

	# Full sweep: every texel equals density_to_heat(field value) — the
	# pipeline copies the field faithfully, per-cell, in ascending row-major
	# order (the field is keyed by flat index; the texture by (x, y)).
	# Comparison tolerance is TEXEL_EPS (8-bit texture quantization).
	var mismatch: int = 0
	for y in GRID_H:
		for x in GRID_W:
			var cell := Vector2i(x, y)
			var expected: Color = layer.call("density_to_heat", cong.call("per_cell_density", cell))
			var actual := _texel(layer, cell)
			if absf(actual.r - expected.r) > TEXEL_EPS or absf(actual.g - expected.g) > TEXEL_EPS \
					or absf(actual.b - expected.b) > TEXEL_EPS or absf(actual.a - expected.a) > TEXEL_EPS:
				mismatch += 1
	_check(mismatch == 0, "AC9: all %d texels match per_cell_density (0 mismatches)" % (GRID_W * GRID_H))
	_check(_refresh_count(layer) == 1, "AC9: exactly one refresh for one signal (got %d)" % _refresh_count(layer))
	layer.free()


# === AC9: 10 Hz cadence — signal-driven only ===

func _test_ac9_cadence_fake_emitter() -> void:
	print("\n[AC9] cadence: refresh ONLY on congestion_updated; no frames without a signal")
	var gs := _make_grid([])
	var fake := FakeCongestion.new()
	var layer := _make_layer(fake, gs)

	# No signal ever fired -> no refresh, no writes.
	_check(_refresh_count(layer) == 0, "AC9: zero signals -> zero refreshes")

	# One signal -> exactly one refresh, texel written from the field.
	fake.field[Vector2i(2, 2)] = 0.5
	fake.congestion_updated.emit()
	_check(_refresh_count(layer) == 1, "AC9: one signal -> one refresh")
	_check_texel(_texel(layer, Vector2i(2, 2)),
		Color(Color("e0a0a0").r, Color("e0a0a0").g, Color("e0a0a0").b, 0.3),
		"AC9: texel (2,2) == density_to_heat(0.5) == alpha 0.3 (8-bit)")

	# Field changes WITHOUT a signal -> no refresh, texel stays stale
	# (the layer must not poll the field on its own).
	fake.field[Vector2i(2, 2)] = 1.0
	_check(_refresh_count(layer) == 1, "AC9: field change without signal -> no refresh (no polling)")
	_check_texel(_texel(layer, Vector2i(2, 2)),
		Color(Color("e0a0a0").r, Color("e0a0a0").g, Color("e0a0a0").b, 0.3),
		"AC9: texel still reflects the last signal's field (stale until next emit)")

	# Next signal -> refresh applies the new field.
	fake.congestion_updated.emit()
	_check(_refresh_count(layer) == 2, "AC9: second signal -> second refresh")
	_check_texel(_texel(layer, Vector2i(2, 2)),
		Color(Color("e0a0a0").r, Color("e0a0a0").g, Color("e0a0a0").b, 0.6),
		"AC9: texel now reflects the updated field (alpha 0.6)")
	layer.free()


# === AC9: two signals in one frame, both applied ===

func _test_ac9_two_signals_same_frame() -> void:
	print("\n[AC9] two signals in one frame -> both applied, texels match the latest field")
	var gs := _make_grid([])
	var fake := FakeCongestion.new()
	var layer := _make_layer(fake, gs)

	fake.field[Vector2i(1, 1)] = 0.5
	fake.congestion_updated.emit()
	fake.field[Vector2i(1, 1)] = 0.9
	fake.congestion_updated.emit()
	_check(_refresh_count(layer) == 2, "AC9: two back-to-back signals -> two refreshes")
	_check_float(_texel(layer, Vector2i(1, 1)).a, 0.6,
		"AC9: latest field applied (0.9 -> alpha 0.6)")

	# Real-rig double-tick: two on_tick calls in immediate succession with a
	# changed member set — both refreshes happen, texels match the SECOND
	# field.
	var ms := _make_member_sim()
	var members_a: Array = []
	for i in 8:
		members_a.append(_member(200 + i, "WALKING_TO", Vector2i(5, 4)))
	ms.set("members", members_a)
	var rig := _make_congestion(gs, ms)
	var cong: RefCounted = rig["congestion"]
	var real_layer := _make_layer(rig["congestion"], gs)

	cong.call("on_tick", 0)
	ms.set("members", [])  # members leave -> field decays toward 0
	cong.call("on_tick", 1)
	_check(_refresh_count(real_layer) == 2, "AC9: two ticks -> two refreshes")
	var expected2: Color = real_layer.call("density_to_heat", cong.call("per_cell_density", Vector2i(5, 4)))
	var actual2 := _texel(real_layer, Vector2i(5, 4))
	_check_texel(actual2, expected2,
		"AC9: after second tick texel matches the latest field (%s)" % str(actual2))
	_check(actual2.a < 0.6, "AC9: empty-gym tick decayed the texel (alpha %s < 0.6)" % str(actual2.a))
	layer.free()
	real_layer.free()


# === AC9: structurally no per-frame refresh path ===

func _test_ac9_no_per_frame_refresh() -> void:
	print("\n[AC9] no _process/_physics_process on the layer — refresh cannot run per-frame")
	var gs := _make_grid([])
	var fake := FakeCongestion.new()
	var layer := _make_layer(fake, gs)

	var method_names: Array = []
	for m in layer.get_script().get_script_method_list():
		method_names.append(m["name"])
	_check(not method_names.has("_process"),
		"AC9: layer script defines no _process (per-frame refresh impossible)")
	_check(not method_names.has("_physics_process"),
		"AC9: layer script defines no _physics_process")

	# Non-refreshing interactions between signals must never touch the image.
	var before := _texel(layer, Vector2i(7, 7))
	layer.call("is_heatmap_on")
	layer.call("density_to_heat", 0.5)
	layer.call("toggle_flow_overlay")
	layer.call("toggle_flow_overlay")
	var after := _texel(layer, Vector2i(7, 7))
	_check(_refresh_count(layer) == 0 and before == after,
		"AC9: toggle/query calls write nothing (zero redundant writes)")
	layer.free()


# === AC7: one-time tip ===

func _test_ac7_one_time_tip_once() -> void:
	print("\n[AC7] first toggle ON -> one_time_tip_requested exactly once per session")
	var gs := _make_grid([])
	var fake := FakeCongestion.new()
	var layer := _make_layer(fake, gs)

	var counter := TipCounter.new()
	layer.one_time_tip_requested.connect(counter.on_tip)

	layer.call("toggle_flow_overlay")
	_check(counter.count == 1, "AC7: first toggle ON -> tip emitted once (got %d)" % counter.count)
	_check(counter.texts.size() == 1 and counter.texts[0] is String and str(counter.texts[0]).length() > 0,
		"AC7: tip carries non-empty contextual text")

	# OFF then ON again — the tip never recurs.
	layer.call("toggle_flow_overlay")
	layer.call("toggle_flow_overlay")
	_check(counter.count == 1, "AC7: OFF/ON cycle -> tip does NOT recur (got %d)" % counter.count)

	# A second independent layer instance starts a fresh session (per-session
	# semantics = per-instance lifetime).
	var layer2 := _make_layer(fake, gs)
	var counter2 := TipCounter.new()
	layer2.one_time_tip_requested.connect(counter2.on_tip)
	layer2.call("toggle_flow_overlay")
	_check(counter2.count == 1, "AC7: new session (new instance) -> tip fires again once")
	layer.free()
	layer2.free()


# === Cell->world layout via grid conversion ===

func _test_layout_grid_conversion() -> void:
	print("\n[LAYOUT] rect sized via grid_world_conversion, cell_size injected — never hardcoded")
	var gs := _make_grid([])
	var fake := FakeCongestion.new()

	var layer32 := _make_layer(fake, gs, {})
	var size32: Vector2 = layer32.get("size")
	_check(size32 == Vector2(GRID_W * CELL_SIZE, GRID_H * CELL_SIZE),
		"LAYOUT: 13x10 @ 32px -> size %s (no hardcoded 13x10)" % str(size32))
	_check(size32 == (gs.call("grid_to_world_corner", Vector2i(GRID_W, GRID_H), CELL_SIZE) as Vector2),
		"LAYOUT: size equals GridSystem.grid_to_world_corner(dims, cell_size)")

	var layer16: Object = _HL().new()
	layer16.call("init", fake, gs, 16)
	_check(layer16.get("size") == Vector2(GRID_W * 16, GRID_H * 16),
		"LAYOUT: cell_size 16 -> size scales to %s" % str(layer16.get("size")))

	# The texture dims also come from the grid, not a constant.
	var image_dims: Vector2i = (layer32.get("heatmap_image") as Image).get_size()
	_check(image_dims == Vector2i(GRID_W, GRID_H),
		"LAYOUT: Image is grid-sized (%s)" % str(image_dims))
	layer32.free()
	layer16.free()


# === DrawableTexture2D BYPASS (GDD OQ1 / TR-CFO-010) ===

func _test_no_drawable_texture2d() -> void:
	print("\n[BYPASS] DrawableTexture2D is NOT used (GDD Core Rule 2 + OQ1 + TR-CFO-010)")
	var f := FileAccess.open("res://src/presentation/heatmap_layer.gd", FileAccess.READ)
	_check(f != null, "BYPASS: production file readable")
	if f == null:
		return
	var src := f.get_as_text()
	# The class doc deliberately EXPLAINS the DrawableTexture2D bypass (GDD
	# Core Rule 2 + OQ1) — comments may name it. What must not exist is any
	# CODE usage: instantiation, inheritance, typing, or static call.
	_check(not src.contains("DrawableTexture2D.new")
		and not src.contains("extends DrawableTexture2D")
		and not src.contains(": DrawableTexture2D")
		and not src.contains("DrawableTexture2D("),
		"BYPASS: no DrawableTexture2D code usage in the production layer (doc comments only)")
	_check(src.contains("ImageTexture") and src.contains("Image.create"),
		"BYPASS: ImageTexture + Image path used instead")
