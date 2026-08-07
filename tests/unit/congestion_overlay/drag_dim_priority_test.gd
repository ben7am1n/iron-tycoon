# tests/unit/congestion_overlay/drag_dim_priority_test.gd
# Story CFO-004: Drag Dimming (AC3) + Layer Priority (Core Rule 7)
# (production/epics/congestion-flow-overlay/story-004-rejection-tooltip-layer-priority.md)
#
# BLOCKING ACs covered:
#   AC3  placement drag begins (is_dragging true) -> heatmap tweens to
#        ≤20% effective opacity; drag end -> restores (ON -> prior
#        opacity, OFF -> hidden)
#   Core Rule 7 edge  toggling mid-drag: toggle sets the target opacity;
#        the drag-dim still overrides to ≤20% until drag end, then the
#        toggled state applies (ON -> full after drag; OFF -> hidden)
#   Core Rule 7  layering priority: access-blocked (full opacity, never
#        dimmed) > ghost (full) > glyph (visible) > heatmap (≤20%). The
#        drag path touches ONLY the heatmap — the access-blocked layer
#        exposes NO drag-dim API (structural check) and the controller
#        never calls one on it.
#   Config knob  drag_dim_opacity default 0.2 (≤20%), data-driven
#
# Rig: real HeatmapLayer (off-tree -> synchronous opacity application) +
# real AccessBlockedLayer (walled rig) + real PlacementSystem (spy-able
# is_dragging via the white-box _test_set_dragging seam) + real
# CongestionOverlayController.
#
# Run standalone: godot --headless --script tests/unit/congestion_overlay/drag_dim_priority_test.gd
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"

const GRID_W := 10
const GRID_H := 8
const R0 := 0
const ENTRANCE := Vector2i(0, 0)
const CELL_SIZE := 32
const EPS := 1e-6

# FailCode mirror.
const OUT_OF_BOUNDS := 1

var _pass := 0
var _fail := 0

## Every controller Node / heatmap layer created by this test file that is
## NOT part of the SceneTree root (direct-constructed Controls/ColorRects) —
## freed in _free_test_nodes() so the process exits with zero leaks (both
## extend Node, not RefCounted).
var _nodes_to_free: Array = []


func _init() -> void:
	if Engine.has_meta(RUNNER_META):
		return
	var result := run_all()
	quit(1 if int(result["fail"]) > 0 else 0)


func run_all() -> Dictionary:
	print("=".repeat(48))
	print("  UNIT TEST: Congestion Overlay — Drag Dim + Layer Priority (Story CFO-004)")
	print("=".repeat(48))

	_test_ac3_drag_dims_heatmap()
	_test_ac3_drag_end_restores_on()
	_test_ac3_off_at_drag_start_stays_hidden()
	_test_ac3_toggle_off_mid_drag()
	_test_ac3_toggle_on_mid_drag()
	_test_drag_dim_config_knob()
	_test_core_rule7_access_never_dimmed_structural()
	_test_core_rule7_controller_drag_touches_only_heatmap()
	_test_controller_wiring_rejection_to_tooltip()
	_test_controller_wiring_drag_poll_drives_heatmap()

	_free_test_nodes()

	print("\n=== DRAG DIM + PRIORITY TEST: %d passed, %d failed ===\n" % [_pass, _fail])
	return {"pass": _pass, "fail": _fail}


func _free_test_nodes() -> void:
	for n in _nodes_to_free:
		if is_instance_valid(n):
			n.free()
	_nodes_to_free.clear()


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


# === Test double: a fake Congestion read surface for the heatmap ===
class FakeCongestion:
	extends RefCounted

	signal congestion_updated

	var field: Dictionary = {}

	func per_cell_density(cell: Vector2i) -> float:
		return float(field.get(cell, 0.0))


# === Helpers ===

func _GS() -> Script:
	return load("res://src/systems/grid_system.gd") as Script


func _MS() -> Script:
	return load("res://src/systems/member_sim.gd") as Script


func _SRG() -> Script:
	return load("res://src/systems/seeded_rng.gd") as Script


func _NAV() -> Script:
	return load("res://src/systems/navigation.gd") as Script


func _HL() -> Script:
	return load("res://src/presentation/heatmap_layer.gd") as Script


func _ABL() -> Script:
	return load("res://src/presentation/access_blocked_layer.gd") as Script


func _RT() -> Script:
	return load("res://src/ui/rejection_tooltip.gd") as Script


func _CTRL() -> Script:
	return load("res://src/ui/congestion_overlay_controller.gd") as Script


func _make_orchestrator() -> Node:
	var orch: Node = load("res://src/systems/simulation_orchestrator.gd").new()
	root.add_child(orch)
	orch.call("_ready")
	return orch


## Real GridSystem: 10x8 all buildable, frozen, with the given equipment
## committed. Each entry: {id, fp: Vector2i, ac: Vector2i}.
func _make_grid(equipment: Array) -> RefCounted:
	var gs: RefCounted = _GS().new()
	gs.call("init", GRID_W, GRID_H)
	for y in GRID_H:
		for x in GRID_W:
			gs.call("set_buildable", Vector2i(x, y), true)
	gs.call("freeze_buildable")
	for eq in equipment:
		var fp_arr: Array[Vector2i] = [eq["fp"]]
		var ac_arr: Array[Vector2i] = [eq["ac"]]
		gs.call("commit", int(eq["id"]), fp_arr, ac_arr, R0)
	return gs


func _commit(gs: RefCounted, id: int, fp: Vector2i, ac: Vector2i) -> void:
	var fp_arr: Array[Vector2i] = [fp]
	var ac_arr: Array[Vector2i] = [ac]
	gs.call("commit", id, fp_arr, ac_arr, R0)


func _clear(gs: RefCounted, id: int) -> void:
	gs.call("clear", id)


## Full-width wall across row y=1 — severs every path from entrance (0,0)
## to row y>=2. The wall's OWN access cell sits at (9,0) so the wall stays
## reachable and never acquires a barricade icon.
func _commit_wall(gs: RefCounted, id: int) -> void:
	var fp: Array[Vector2i] = []
	for x in GRID_W:
		fp.append(Vector2i(x, 1))
	var ac: Array[Vector2i] = [Vector2i(9, 0)]
	gs.call("commit", id, fp, ac, R0)


func _make_member_sim() -> RefCounted:
	return _MS().new()


func _make_real_navigation(gs: RefCounted) -> RefCounted:
	var nav: RefCounted = _NAV().new()
	nav.call("init", gs)
	nav.call("_post_init")
	return nav


func _make_congestion(
	gs: RefCounted,
	ms: RefCounted,
	nav: RefCounted = null,
	entrance: Vector2i = ENTRANCE
) -> Dictionary:
	var srg: RefCounted = _SRG().new()
	srg.call("init", 0xCF0004)
	var orch := _make_orchestrator()
	var cong: RefCounted = (load("res://src/systems/congestion.gd") as Script).new()
	cong.call("init", orch, srg, gs, ms, {}, nav, entrance)
	if gs != null:
		cong.call("_post_init")
	return {"congestion": cong, "seeded_rng": srg, "orchestrator": orch}


## Real HeatmapLayer wired to a fake congestion — off-tree so _apply_visibility
## applies endpoints synchronously (tweens only run in-tree). Tracked for
## teardown (ColorRect is a Node, not RefCounted).
func _make_heatmap(grid: RefCounted, config: Dictionary = {}) -> Object:
	var fake := FakeCongestion.new()
	var layer: Object = _HL().new()
	layer.call("init", fake, grid, CELL_SIZE, config)
	_nodes_to_free.append(layer)
	return layer


## Real PlacementSystem — init'd with a real grid + catalog; drag state is
## flipped via the white-box _test_set_dragging seam (PL-006) so tests can
## construct DRAGGING deterministically.
func _make_placement(grid: RefCounted) -> RefCounted:
	var EC: Script = load("res://src/systems/equipment_catalog.gd") as Script
	var ED: Script = load("res://src/systems/equipment_def.gd") as Script
	var zone: Array = ["cardio"]
	var footprint: Array[Vector2i] = [Vector2i(0, 0)]
	var access: Array[Vector2i] = [Vector2i(0, 1)]
	var effects: Array[Dictionary] = []
	var def: RefCounted = ED.new(
		"dumbbell_01", "Dumbbell", zone, footprint, access, 200, "", effects,
		200, 30, 100, 300
	)
	var cat: RefCounted = EC.new()
	cat.call("_add_definition", def)
	cat.call("_freeze")
	var ps: RefCounted = (load("res://src/systems/placement_system.gd") as Script).new()
	ps.call("init", grid, cat)
	return ps


func _make_tooltip(config: Dictionary = {}) -> RefCounted:
	var tooltip: RefCounted = _RT().new()
	tooltip.call("init", config)
	return tooltip


## Real CongestionOverlayController wired to the real placement + heatmap +
## access layer + tooltip. NOT added to the tree (off-tree timer creation is
## skipped; tests drive _on_hold_elapsed directly). Returns Object — the
## controller is a Control (Node), not a RefCounted.
func _make_controller(ps: RefCounted, heatmap: Object, abl: Node2D, tooltip: RefCounted, grid: RefCounted) -> Object:
	var ctrl: Object = _CTRL().new()
	ctrl.call("init", ps, heatmap, abl, tooltip, grid, CELL_SIZE)
	ctrl.call("_post_init")
	_nodes_to_free.append(ctrl)
	return ctrl


## The standard walled rig: E (id 1) boxed in by a full-width wall (id 2)
## committed BEFORE congestion init — E is unreachable from scene entry.
func _walled_rig() -> Dictionary:
	var eq: Array = [{"id": 1, "fp": Vector2i(2, 2), "ac": Vector2i(3, 2)}]
	var gs := _make_grid(eq)
	_commit_wall(gs, 2)
	var ms := _make_member_sim()
	var nav := _make_real_navigation(gs)
	var cong_rig := _make_congestion(gs, ms, nav)
	var abl: Node2D = _ABL().new()
	abl.call("configure", cong_rig["congestion"], gs, CELL_SIZE)
	_nodes_to_free.append(abl)
	return {"grid": gs, "congestion": cong_rig["congestion"], "access_blocked": abl, "nav": nav}


# === AC3: drag dims the heatmap ===

func _test_ac3_drag_dims_heatmap() -> void:
	print("\n[AC3] drag begins -> heatmap tweens to ≤20% effective opacity")
	var gs := _make_grid([])
	var heatmap := _make_heatmap(gs)
	heatmap.call("toggle_flow_overlay")  # ON

	_check(heatmap.call("is_heatmap_on"), "AC3: precondition — heatmap ON")
	_check_float(float(heatmap.get("modulate").a), 1.0, "AC3: precondition — modulate.a == 1.0 (full)")
	_check(not heatmap.call("is_drag_active"), "AC3: precondition — no drag active")

	heatmap.call("set_drag_active", true)
	_check(heatmap.call("is_drag_active"), "AC3: drag_active flag set")
	# The modulate target that yields EFFECTIVE ≤0.2: 0.2 / 0.6 (baked
	# layer opacity) = 0.3333. Effective = modulate.a × layer_opacity.
	var target: float = heatmap.call("drag_dim_target")
	_check_float(target, 0.2 / 0.6, "AC3: drag_dim_target == 0.2/0.6 (ratio over baked layer opacity)")
	var effective: float = float(heatmap.get("modulate").a) * 0.6
	_check(effective <= 0.2 + EPS, "AC3: effective opacity ≤ 20%% during drag (got %s)" % str(effective))
	_check(heatmap.get("visible") == true, "AC3: layer stays visible while dimmed")


func _test_ac3_drag_end_restores_on() -> void:
	print("\n[AC3] drag ends -> restores to the toggled state (ON -> prior opacity)")
	var gs := _make_grid([])
	var heatmap := _make_heatmap(gs)
	heatmap.call("toggle_flow_overlay")

	heatmap.call("set_drag_active", true)
	heatmap.call("set_drag_active", false)
	_check(not heatmap.call("is_drag_active"), "AC3: drag_active cleared on drag end")
	_check_float(float(heatmap.get("modulate").a), 1.0, "AC3: ON heatmap restored to full opacity (modulate.a == 1.0)")
	_check(heatmap.get("visible") == true, "AC3: ON heatmap stays visible after restore")


func _test_ac3_off_at_drag_start_stays_hidden() -> void:
	print("\n[AC3 edge] heatmap OFF at drag start -> stays hidden (GDD states table: no Hidden→Dimmed transition)")
	var gs := _make_grid([])
	var heatmap := _make_heatmap(gs)
	# Heatmap default OFF — no toggle.
	heatmap.call("set_drag_active", true)
	_check(heatmap.call("is_drag_active"), "AC3-edge: drag_active set even when heatmap was OFF")
	_check_float(float(heatmap.get("modulate").a), 0.0, "AC3-edge: OFF heatmap stays at alpha 0 during drag")
	_check(heatmap.get("visible") == false, "AC3-edge: OFF heatmap stays hidden during drag")
	heatmap.call("set_drag_active", false)
	_check(heatmap.get("visible") == false, "AC3-edge: still hidden after drag end (OFF state)")

	# Toggling ON mid-drag IS the exception: the player's explicit choice
	# shows the layer dimmed (drag override holds until drag end).
	var heatmap2 := _make_heatmap(gs)
	heatmap2.call("set_drag_active", true)
	heatmap2.call("toggle_flow_overlay")  # toggle ON mid-drag
	var effective2: float = float(heatmap2.get("modulate").a) * 0.6
	_check(effective2 <= 0.2 + EPS and heatmap2.get("visible") == true,
		"AC3-edge: toggle ON mid-drag -> dimmed ≤20%, visible (override wins)")


# === Core Rule 7 edge: toggling mid-drag ===

func _test_ac3_toggle_off_mid_drag() -> void:
	print("\n[CR7 edge] toggle OFF mid-drag -> drag-dim overrides to ≤20% until drag end, then hidden")
	var gs := _make_grid([])
	var heatmap := _make_heatmap(gs)
	heatmap.call("toggle_flow_overlay")  # ON
	heatmap.call("set_drag_active", true)

	heatmap.call("toggle_flow_overlay")  # toggle OFF mid-drag
	var effective: float = float(heatmap.get("modulate").a) * 0.6
	_check(not heatmap.call("is_heatmap_on"), "CR7-edge: toggle state is now OFF")
	_check(effective <= 0.2 + EPS and heatmap.get("visible") == true,
		"CR7-edge: during drag, layer STILL shows at ≤20% (drag-dim overrides the toggle)")

	heatmap.call("set_drag_active", false)  # drag ends
	_check_float(float(heatmap.get("modulate").a), 0.0, "CR7-edge: after drag end -> hidden (OFF state applies)")
	_check(heatmap.get("visible") == false, "CR7-edge: after drag end -> not visible")


func _test_ac3_toggle_on_mid_drag() -> void:
	print("\n[CR7 edge] toggle ON mid-drag -> drag-dim overrides to ≤20% until drag end, then full ON")
	var gs := _make_grid([])
	var heatmap := _make_heatmap(gs)
	# OFF at start.
	heatmap.call("set_drag_active", true)
	heatmap.call("toggle_flow_overlay")  # toggle ON mid-drag
	var effective: float = float(heatmap.get("modulate").a) * 0.6
	_check(heatmap.call("is_heatmap_on"), "CR7-edge: toggle state is now ON")
	_check(effective <= 0.2 + EPS, "CR7-edge: during drag — dimmed ≤20%")

	heatmap.call("set_drag_active", false)
	_check_float(float(heatmap.get("modulate").a), 1.0, "CR7-edge: after drag end -> full ON opacity")
	_check(heatmap.get("visible") == true, "CR7-edge: after drag end -> visible")


# === Config knob ===

func _test_drag_dim_config_knob() -> void:
	print("\n[CONFIG] drag_dim_opacity data-driven (default 0.2)")
	var gs := _make_grid([])
	var heatmap := _make_heatmap(gs)
	heatmap.call("toggle_flow_overlay")
	heatmap.call("set_drag_active", true)
	_check_float(float(heatmap.call("drag_dim_target")), 0.2 / 0.6,
		"CONFIG: default drag_dim_opacity 0.2 -> target 0.2/0.6")

	var heatmap2 := _make_heatmap(gs, {"drag_dim_opacity": 0.1})
	heatmap2.call("toggle_flow_overlay")
	heatmap2.call("set_drag_active", true)
	_check_float(float(heatmap2.call("drag_dim_target")), 0.1 / 0.6,
		"CONFIG: drag_dim_opacity 0.1 -> target 0.1/0.6")


# === Core Rule 7: access-blocked never dimmed ===

func _test_core_rule7_access_never_dimmed_structural() -> void:
	print("\n[CR7 structural] access-blocked layer exposes NO drag-dim API — priority by construction")
	var f := FileAccess.open("res://src/presentation/access_blocked_layer.gd", FileAccess.READ)
	_check(f != null, "CR7: access layer source readable")
	if f == null:
		return
	var src := f.get_as_text()
	_check(not src.contains("func set_drag_active"), "CR7: no set_drag_active on the access layer")
	# The icon record legitimately carries per-icon "opacity" for its own
	# fade-in lifecycle (AC2 single fade-in). What must NOT exist is a
	# DRAG-dim surface: no modulate, no drag-opacity knob, no drag state.
	_check(not src.contains("modulate"), "CR7: no modulate/dim surface on the access layer")
	_check(not src.contains("set_drag") and not src.contains("drag_dim") and not src.contains("_drag"),
		"CR7: no drag-related state on the access layer (icons never read drag state)")
	_check(src.contains("set_heatmap_enabled"), "CR7: only the heatmap-toggle symmetry method exists (AC12 no-op)")

	# Behavioral: a walled rig's icon stays STATIC at full opacity while the
	# controller processes a drag. Main's merged CFO-003 layer materializes
	# on configure() (Core Rule 5 — default-visible, no event gate), so no
	# scene-enter call is needed; icons live in the public `icons` dict
	# keyed by instance_id, with state "static" and an `alpha` field.
	var rig := _walled_rig()
	var abl: Node2D = rig["access_blocked"]
	var icons: Dictionary = abl.get("icons")
	_check(icons.has(1), "CR7: walled E has a barricade icon after configure()")
	var icon: Dictionary = icons.get(1, {})
	_check(str(icon.get("state")) == "static" and absf(float(icon.get("alpha", 0.0)) - 1.0) < 1e-9,
		"CR7: walled E icon is STATIC at full opacity before the drag")
	var ps := _make_placement(rig["grid"])
	var heatmap := _make_heatmap(rig["grid"])
	var tooltip := _make_tooltip()
	var ctrl := _make_controller(ps, heatmap, abl, tooltip, rig["grid"])
	ps.call("_test_set_dragging", true)
	ctrl.call("_poll_drag_state")
	icon = (abl.get("icons") as Dictionary).get(1, {})
	_check(str(icon.get("state")) == "static" and absf(float(icon.get("alpha", 0.0)) - 1.0) < 1e-9,
		"CR7: after drag begins — access icon STILL STATIC at full opacity (never dimmed)")
	_check(int((abl.get("icons") as Dictionary).size()) == 1, "CR7: icon count unchanged during drag")


func _test_core_rule7_controller_drag_touches_only_heatmap() -> void:
	print("\n[CR7] controller drag path touches ONLY the heatmap (access layer has no drag call sites)")
	var f := FileAccess.open("res://src/ui/congestion_overlay_controller.gd", FileAccess.READ)
	_check(f != null, "CR7: controller source readable")
	if f == null:
		return
	var src := f.get_as_text()
	# The only set_drag_active call sites must target the heatmap.
	_check(src.contains("_heatmap.set_drag_active"), "CR7: controller dims the heatmap")
	_check(not src.contains("_access_blocked.set_drag_active"),
		"CR7: controller NEVER calls set_drag_active on the access layer")


# === Controller wiring ===

func _test_controller_wiring_rejection_to_tooltip() -> void:
	print("\n[WIRE] placement_rejected -> tooltip armed (bucket message, hold window open)")
	var gs := _make_grid([])
	var ps := _make_placement(gs)
	var heatmap := _make_heatmap(gs)
	var tooltip := _make_tooltip()
	var ctrl := _make_controller(ps, heatmap, null, tooltip, gs)

	# Fire the real S4 signal through the typed connection.
	ps.placement_rejected.emit("dumbbell_01", Vector2i(3, 3), 0, OUT_OF_BOUNDS)
	_check(tooltip.call("is_pending"), "WIRE: rejection -> tooltip pending (hold window open)")
	_check(not tooltip.call("is_visible"), "WIRE: not visible yet (hold delay)")
	_check(tooltip.call("get_message") == "Won't fit here", "WIRE: bucket message from the real signal")

	# The controller's hold timer path resolves to visible.
	ctrl.call("_on_hold_timeout", ctrl.get("_hold_generation"))
	_check(tooltip.call("is_visible"), "WIRE: after hold timeout -> tooltip visible")

	# Preview validity: cursor on a valid cell dismisses (GDD States table).
	tooltip.call("dismiss")
	ctrl.call("_on_preview_validity_changed", true)
	_check(not tooltip.call("is_visible"), "WIRE: valid-cell preview keeps tooltip hidden after dismiss")


func _test_controller_wiring_drag_poll_drives_heatmap() -> void:
	print("\n[WIRE] _poll_drag_state drives heatmap.set_drag_active on is_dragging edges")
	var gs := _make_grid([])
	var ps := _make_placement(gs)
	var heatmap := _make_heatmap(gs)
	heatmap.call("toggle_flow_overlay")
	var tooltip := _make_tooltip()
	var ctrl := _make_controller(ps, heatmap, null, tooltip, gs)

	# IDLE -> no transition on first poll (baseline recorded).
	ctrl.call("_poll_drag_state")
	_check(not heatmap.call("is_drag_active"), "WIRE: baseline — no drag, heatmap not dimmed")

	ps.call("_test_set_dragging", true)
	ctrl.call("_poll_drag_state")
	_check(heatmap.call("is_drag_active"), "WIRE: drag begins -> heatmap dimming active")
	var effective: float = float(heatmap.get("modulate").a) * 0.6
	_check(effective <= 0.2 + EPS, "WIRE: dimmed to ≤20% effective via the controller")

	ps.call("_test_set_dragging", false)
	ctrl.call("_poll_drag_state")
	_check(not heatmap.call("is_drag_active"), "WIRE: drag ends -> heatmap dimming cleared")
	_check_float(float(heatmap.get("modulate").a), 1.0, "WIRE: restored to full opacity")

	# No-op on a quiet poll (state unchanged).
	var before: float = float(heatmap.get("modulate").a)
	ctrl.call("_poll_drag_state")
	_check_float(float(heatmap.get("modulate").a), before, "WIRE: quiet poll is a no-op (idempotent)")
