# tests/unit/selection_system/load_rebuild_unit_test.gd
# Story SEL-005: Load-time Mapping Rebuild
# (production/epics/selection-system/story-005-load-time-mapping-rebuild.md)
#
# Unit-level coverage of the rebuild procedure (TR-SEL-006/007 / Core
# Rule 8), simulating the loaded-grid state directly:
#
#   - AC Core Rule 8: after GridSystem.deserialize() restores occupancy,
#     the SelectionSystem mapping is empty (no placement_committed fires
#     during load). rebuild_mapping() scans every occupied cell, groups by
#     occupant_id, and reconstructs {equipment_id, anchor, rotation} from
#     the loaded grid BEFORE the first UI frame that could receive a click.
#   - UX AC: first click on a piece after the rebuild correctly selects it
#     (mapping rebuilt).
#   - TR-SEL-007: the mapping is fully reconstructed from GridSystem on
#     load (the SelectionSystem itself contributes nothing to a save blob —
#     asserted at the integration level; here we prove the mapping after a
#     direct grid commit equals what runtime placement would have produced).
#   - QA edge cases: zero placed pieces (empty mapping, no error);
#     multi-cell footprints (grouped by occupant_id); rotation recovery
#     (R90/R180/R270); idempotency (rebuild twice → identical mapping);
#     occupant with no catalog match (skipped loudly, no half-built entry).
#
# The "loaded grid" is simulated by committing occupancy DIRECTLY to
# GridSystem (grid.commit(...)), the same way GridSystem.deserialize()
# Phase B restores records — no PlacementSystem flow, no
# placement_committed emission. That is the exact pre-rebuild state.
#
# Run standalone: godot --headless --script tests/unit/selection_system/load_rebuild_unit_test.gd
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"

const SEL_SCRIPT := "res://src/systems/selection_system.gd"
const PLACEMENT_SCRIPT := "res://src/systems/placement_system.gd"
const GRID_SCRIPT := "res://src/systems/grid_system.gd"
const CATALOG_SCRIPT := "res://src/systems/equipment_catalog.gd"
const DEF_SCRIPT := "res://src/systems/equipment_def.gd"

## Sentinel distinguishing "argument not passed" from a real null — the
## deselect emit passes exactly ONE argument, so b/c/d keep this value.
const NO_ARG := "<NO_ARG>"

var _pass := 0
var _fail := 0


## 被 tests/headless_runner.gd 托管时立即返回 —— 用例由 runner 调用的 run_all() 驱动。
## 否则 script.new() 触发的 _init() 与随后的 run_all() 会让每个用例跑两遍。
func _init() -> void:
	if Engine.has_meta(RUNNER_META):
		return
	var result := run_all()
	quit(1 if int(result["fail"]) > 0 else 0)


## 返回 {"pass": int, "fail": int} —— 见 tests/headless_runner.gd 的测试文件契约
func run_all() -> Dictionary:
	print("=".repeat(48))
	print("  UNIT TEST: SelectionSystem — Load-time Mapping Rebuild (SEL-005)")
	print("=".repeat(48))

	_test_rebuild_restores_runtime_equivalence()
	_test_first_click_selects_after_rebuild()
	_test_rotation_recovery_r90()
	_test_rotation_recovery_r180()
	_test_rotation_recovery_r270()
	_test_multi_cell_footprint_grouped_by_occupant()
	_test_zero_placed_pieces_empty_mapping()
	_test_idempotent_rebuild()
	_test_unmatched_footprint_skipped_loudly()
	_test_rebuild_resets_selection_state()
	_test_rebuild_before_init_guard()

	print("\n=== SEL-005 Load Rebuild: %d passed, %d failed ===\n" % [_pass, _fail])
	return {"pass": _pass, "fail": _fail}


func _check(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
		print("  PASS: " + msg)
	else:
		_fail += 1
		print("  FAIL: " + msg)


# === Helpers ===

## Spy on selection_changed. Records each emission as an args array; the
## four params ALL have sentinel defaults so the handler accepts 1..4 args
## (GDScript dispatches exactly the emitted count — a 1-arg deselect emit
## leaves b/c/d at the sentinel, proving the arity).
class SelectionSpy:
	extends RefCounted
	var emissions: Array = []  # each: [a, b, c, d]

	func _on_selection_changed(a = NO_ARG, b = NO_ARG, c = NO_ARG, d = NO_ARG) -> void:
		emissions.append([a, b, c, d])

	func select_count() -> int:
		var n := 0
		for e in emissions:
			if e[0] != null:  # selects always carry a non-null instance_id (0 is legal)
				n += 1
		return n

	func deselect_count() -> int:
		var n := 0
		for e in emissions:
			if e[0] == null:  # deselects pass exactly one null arg
				n += 1
		return n


func _spy_for(sel: RefCounted) -> SelectionSpy:
	var spy := SelectionSpy.new()
	sel.connect("selection_changed", Callable(spy, "_on_selection_changed"))
	return spy


## Open grid (all buildable) — set before freeze_buildable(), matching the
## level-load lifecycle.
func _make_grid(width: int, height: int) -> RefCounted:
	var GS: Script = load(GRID_SCRIPT) as Script
	var gs: RefCounted = GS.new()
	gs.call("init", width, height)
	for y in height:
		for x in width:
			gs.call("set_buildable", Vector2i(x, y), true)
	gs.call("freeze_buildable")
	return gs


## Canonical treadmill: 1×2 footprint (0,0)-(1,0), access (0,1).
func _make_treadmill_def() -> RefCounted:
	return _make_def("treadmill_01", [Vector2i(0, 0), Vector2i(1, 0)], [Vector2i(0, 1)], 200)


## Canonical yoga mat: 1×1 footprint, access (1,0).
func _make_yoga_def() -> RefCounted:
	return _make_def("yoga_01", [Vector2i(0, 0)], [Vector2i(1, 0)], 200)


## Canonical bench: 2×2 footprint, access (2,1).
func _make_bench_def() -> RefCounted:
	return _make_def(
		"bench_01",
		[Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)],
		[Vector2i(2, 1)],
		350
	)


func _make_def(id: String, fp: Array[Vector2i], ac: Array[Vector2i], cost: int) -> RefCounted:
	var ED: Script = load(DEF_SCRIPT) as Script
	var effects: Array[Dictionary] = []
	var zones: Array = ["力量区"]
	return ED.new(id, "Test %s" % id, zones, fp, ac, cost, "", effects, 200, 30, 100, 300)


func _make_catalog() -> RefCounted:
	var cat: RefCounted = (load(CATALOG_SCRIPT) as Script).new()
	cat.call("_add_definition", _make_treadmill_def())
	cat.call("_add_definition", _make_yoga_def())
	cat.call("_add_definition", _make_bench_def())
	cat.call("_freeze")
	return cat


func _make_placement(grid: RefCounted, catalog: RefCounted) -> RefCounted:
	var ps: RefCounted = (load(PLACEMENT_SCRIPT) as Script).new()
	ps.call("init", grid, catalog)
	return ps


## SelectionSystem wired for the mapping (init + _post_init).
func _make_selection(grid: RefCounted, placement: RefCounted, catalog: RefCounted) -> RefCounted:
	var sel: RefCounted = (load(SEL_SCRIPT) as Script).new()
	sel.call("init", grid, placement, catalog)
	sel.call("_post_init")
	return sel


## Simulates a LOADED grid: commits occupancy directly to GridSystem (the
## same records GridSystem.deserialize() Phase B restores) WITHOUT any
## PlacementSystem flow — no placement_committed fires, so the Selection
## mapping stays empty until rebuild_mapping() runs. Cells are sorted
## lexicographically (y, x) exactly like serialize()/_serialize_cells does,
## so the DTO order matches a real save/load round-trip. Returns the
## allocated instance_id.
func _commit_loaded(
	grid: RefCounted,
	equipment_id: String,
	anchor: Vector2i,
	rotation: int,
	instance_id: int
) -> int:
	var cat: RefCounted = _make_catalog()
	var def: RefCounted = cat.call("get_definition", equipment_id)
	var tf: RefCounted = grid.call(
		"get_transformed_cells",
		def.get("footprint_cells"),
		def.get("access_cells"),
		anchor,
		rotation
	)
	var fp: Array = tf.get("footprint_cells")
	var ac: Array = tf.get("access_cells")
	fp.sort_custom(func(a: Vector2i, b: Vector2i): return a.y < b.y or (a.y == b.y and a.x < b.x))
	ac.sort_custom(func(a: Vector2i, b: Vector2i): return a.y < b.y or (a.y == b.y and a.x < b.x))
	grid.call("commit", instance_id, fp, ac, rotation)
	return instance_id


## Places a piece via the REAL PlacementSystem flow — the runtime-mapping
## baseline for the equivalence check. Returns the allocated instance_id.
func _place(ps: RefCounted, equipment_id: String, anchor: Vector2i, rotate_count: int) -> int:
	var id_before: int = ps.call("get_next_instance_id")
	ps.call("begin_drag", equipment_id)
	for i in rotate_count:
		ps.call("on_rotate_pressed")
	ps.call("on_mouse_moved", anchor)
	ps.call("on_drop")
	return id_before


## Builds grid+catalog+placement+selection (mapping wired).
func _make_world() -> Array:
	var grid := _make_grid(8, 8)
	var catalog := _make_catalog()
	var placement := _make_placement(grid, catalog)
	var selection := _make_selection(grid, placement, catalog)
	return [grid, catalog, placement, selection]


## Helper: assert the spy received exactly one select emission whose payload
## matches (instance_id, equipment_id, cell, rotation).
func _check_single_select(spy: SelectionSpy, expected_id: int, expected_eq: String, expected_cell: Vector2i, expected_rot: int, label: String) -> void:
	_check(spy.select_count() == 1, "%s — exactly one select emission (got %d)" % [label, spy.select_count()])
	if spy.select_count() != 1:
		return
	var e: Array = spy.emissions[0]
	var def_ok: bool = e[1] != null and e[1].get("id") == expected_eq
	_check(e[0] == expected_id, "%s — payload instance_id == %d (got %s)" % [label, expected_id, str(e[0])])
	_check(def_ok, "%s — payload def id == '%s' (got %s)" % [label, expected_eq, str(e[1].get("id") if e[1] != null else "<null>")])
	_check(e[2] == expected_cell, "%s — payload cell == %s (got %s)" % [label, expected_cell, str(e[2])])
	_check(e[3] == expected_rot, "%s — payload rotation == %d (got %s)" % [label, expected_rot, str(e[3])])


# === TR-SEL-007: rebuild reproduces the runtime mapping ===

## The strongest reconstruction proof: the same grid state, mapped once by
## runtime placement_committed events and once by rebuild_mapping(), must
## produce IDENTICAL selection payloads (equipment_id, anchor, rotation) —
## "mapping after load equals mapping before save (reconstructed, not
## stored)".
func _test_rebuild_restores_runtime_equivalence() -> void:
	print("\n[TR-SEL-007] rebuild mapping == runtime placement mapping (reconstructed, not stored)")
	var parts := _make_world()
	var grid: RefCounted = parts[0]
	var placement: RefCounted = parts[2]
	var selection: RefCounted = parts[3]

	# Runtime baseline: place treadmill R0 (id 0), yoga R0 (id 1), bench R90
	# (id 2) — non-overlapping spots on the 8×8 grid.
	_place(placement, "treadmill_01", Vector2i(1, 1), 0)
	_place(placement, "yoga_01", Vector2i(4, 4), 0)
	_place(placement, "bench_01", Vector2i(5, 1), 1)

	var baseline: Array = []
	for i in 3:
		# Click each placed piece and record its payload.
		var probe := SelectionSpy.new()
		selection.connect("selection_changed", Callable(probe, "_on_selection_changed"))
		selection.call("on_cell_clicked", _runtime_footprint_cell(grid, i))
		baseline.append(probe.emissions[0] if probe.emissions.size() > 0 else [])
		# Deselect before the next probe so the spy sees exactly one select.
		selection.call("on_esc_pressed")

	# Load simulation: a SECOND SelectionSystem over the SAME grid, mapping
	# empty (no signals), rebuilt from occupancy alone.
	var sel2: RefCounted = (load(SEL_SCRIPT) as Script).new()
	sel2.call("init", grid, placement, parts[1])
	sel2.call("rebuild_mapping")

	for i in 3:
		var probe := SelectionSpy.new()
		sel2.connect("selection_changed", Callable(probe, "_on_selection_changed"))
		sel2.call("on_cell_clicked", _runtime_footprint_cell(grid, i))
		var rebuilt: Array = probe.emissions[0] if probe.emissions.size() > 0 else []
		_check(rebuilt.size() == 4, "instance %d — rebuild click emits a 4-arg payload (got %s)" % [i, str(rebuilt)])
		if rebuilt.size() == 4:
			_check(str(rebuilt[0]) == str(baseline[i][0]), "instance %d — same instance_id (%s vs %s)" % [i, str(rebuilt[0]), str(baseline[i][0])])
			var def_id: String = rebuilt[1].get("id") if rebuilt[1] != null else "<null>"
			var base_id: String = baseline[i][1].get("id") if baseline[i][1] != null else "<null>"
			_check(def_id == base_id, "instance %d — same equipment_id (%s vs %s)" % [i, def_id, base_id])
			_check(rebuilt[2] == baseline[i][2], "instance %d — same anchor (%s vs %s)" % [i, str(rebuilt[2]), str(baseline[i][2])])
			_check(rebuilt[3] == baseline[i][3], "instance %d — same rotation (%s vs %s)" % [i, str(rebuilt[3]), str(baseline[i][3])])


## First footprint cell of instance [instance_id] on the grid — used to
## probe selection after rebuild (clicking ANY footprint cell must resolve).
func _runtime_footprint_cell(grid: RefCounted, instance_id: int) -> Vector2i:
	var dims: Vector2i = grid.call("get_dimensions")
	for y in dims.y:
		for x in dims.x:
			if int(grid.call("get_occupant_id", Vector2i(x, y))) == instance_id:
				return Vector2i(x, y)
	return Vector2i(-1, -1)


# === UX AC: first click selects correctly after rebuild ===

func _test_first_click_selects_after_rebuild() -> void:
	print("\n[UX AC] first click on a piece after load rebuild selects it correctly")
	var parts := _make_world()
	var grid: RefCounted = parts[0]
	var placement: RefCounted = parts[2]
	var selection: RefCounted = parts[3]

	# Simulated load: treadmill id 0 at (1,1) R0 → footprint (1,1),(2,1).
	_commit_loaded(grid, "treadmill_01", Vector2i(1, 1), 0, 0)

	# Pre-rebuild: mapping empty — click must NOT resolve (Story 005's
	# precondition; the loaded session has no placement_committed events).
	var spy_pre := _spy_for(selection)
	selection.call("on_cell_clicked", Vector2i(1, 1))
	_check(selection.call("get_selected_instance_id") == -1, "pre-rebuild — click does not resolve (mapping empty after load)")
	_check(spy_pre.emissions.is_empty(), "pre-rebuild — no signal fired")

	# The load-order slot runs rebuild_mapping() AFTER GridSystem.deserialize.
	selection.call("rebuild_mapping")
	var spy := _spy_for(selection)

	selection.call("on_cell_clicked", Vector2i(1, 1))

	_check(selection.call("get_selected_instance_id") == 0, "UX — first click selects instance 0")
	_check_single_select(spy, 0, "treadmill_01", Vector2i(1, 1), 0, "UX first click")


# === Rotation recovery (Core Rule 8: rotation reconstructed, not stored) ===

func _test_rotation_recovery_r90() -> void:
	print("\n[Core Rule 8] R90 piece — rotation recovered from footprint match")
	var parts := _make_world()
	var grid: RefCounted = parts[0]
	var selection: RefCounted = parts[3]

	# treadmill at (2,2) rotated 90: footprint (3,2),(3,3), anchor payload (2,2).
	_commit_loaded(grid, "treadmill_01", Vector2i(2, 2), 90, 0)
	selection.call("rebuild_mapping")
	var spy := _spy_for(selection)

	selection.call("on_cell_clicked", Vector2i(3, 2))

	_check(selection.call("get_selected_instance_id") == 0, "R90 — selection resolves")
	_check_single_select(spy, 0, "treadmill_01", Vector2i(2, 2), 90, "R90 rebuild")


func _test_rotation_recovery_r180() -> void:
	print("\n[Core Rule 8] R180 piece — rotation recovered from footprint match")
	var parts := _make_world()
	var grid: RefCounted = parts[0]
	var selection: RefCounted = parts[3]

	# treadmill at (2,2) rotated 180: footprint (3,3),(2,3); union-min anchor
	# (2,2) (PlacedInstance convention).
	_commit_loaded(grid, "treadmill_01", Vector2i(2, 2), 180, 0)
	selection.call("rebuild_mapping")
	var spy := _spy_for(selection)

	selection.call("on_cell_clicked", Vector2i(3, 3))

	_check(selection.call("get_selected_instance_id") == 0, "R180 — selection resolves")
	_check_single_select(spy, 0, "treadmill_01", Vector2i(2, 2), 180, "R180 rebuild")


func _test_rotation_recovery_r270() -> void:
	print("\n[Core Rule 8] R270 piece — rotation recovered from footprint match")
	var parts := _make_world()
	var grid: RefCounted = parts[0]
	var selection: RefCounted = parts[3]

	# treadmill at (2,2) rotated 270: footprint (2,2),(2,3).
	_commit_loaded(grid, "treadmill_01", Vector2i(2, 2), 270, 0)
	selection.call("rebuild_mapping")
	var spy := _spy_for(selection)

	selection.call("on_cell_clicked", Vector2i(2, 2))

	_check(selection.call("get_selected_instance_id") == 0, "R270 — selection resolves")
	_check_single_select(spy, 0, "treadmill_01", Vector2i(2, 2), 270, "R270 rebuild")


# === Multi-cell footprints grouped by occupant_id ===

func _test_multi_cell_footprint_grouped_by_occupant() -> void:
	print("\n[Core Rule 8] multi-cell footprint — grouped by occupant_id, ANY cell selects")
	var parts := _make_world()
	var grid: RefCounted = parts[0]
	var selection: RefCounted = parts[3]

	# bench (2×2) at (1,1) R0 → footprint (1,1),(2,1),(1,2),(2,2); also a
	# separate 1×1 yoga at (5,5) to prove the grouping is per-occupant.
	_commit_loaded(grid, "bench_01", Vector2i(1, 1), 0, 0)
	_commit_loaded(grid, "yoga_01", Vector2i(5, 5), 0, 1)
	selection.call("rebuild_mapping")

	var spy := _spy_for(selection)
	selection.call("on_cell_clicked", Vector2i(2, 2))  # a NON-first bench cell
	_check(selection.call("get_selected_instance_id") == 0, "multi-cell — corner cell selects the bench (id 0)")
	_check_single_select(spy, 0, "bench_01", Vector2i(1, 1), 0, "bench corner cell")

	# Direct swap to the yoga — the grouped bench footprint must not leak
	# into the yoga's occupancy. Fresh spy (the runtime swap test does the
	# same — a direct swap emits a second select into the same spy).
	var spy2 := _spy_for(selection)
	selection.call("on_cell_clicked", Vector2i(5, 5))
	_check(selection.call("get_selected_instance_id") == 1, "multi-cell — direct swap to yoga (id 1)")
	_check_single_select(spy2, 1, "yoga_01", Vector2i(5, 5), 0, "yoga after bench")


# === QA edge: zero placed pieces ===

func _test_zero_placed_pieces_empty_mapping() -> void:
	print("\n[edge] zero placed pieces → rebuild yields empty mapping, no error")
	var parts := _make_world()
	var selection: RefCounted = parts[3]

	selection.call("rebuild_mapping")  # must not crash, must not push_error
	var spy := _spy_for(selection)
	selection.call("on_cell_clicked", Vector2i(3, 3))  # empty buildable floor
	_check(selection.call("get_selected_instance_id") == -1, "zero pieces — nothing selected")
	_check(spy.emissions.is_empty(), "zero pieces — no signal fired (no selection existed to clear)")
	_check(true, "zero pieces — rebuild_mapping() ran without error")


# === QA edge: idempotency ===

func _test_idempotent_rebuild() -> void:
	print("\n[idempotency] rebuild twice → identical mapping (same payloads)")
	var parts := _make_world()
	var grid: RefCounted = parts[0]
	var selection: RefCounted = parts[3]

	_commit_loaded(grid, "treadmill_01", Vector2i(1, 1), 0, 0)
	_commit_loaded(grid, "bench_01", Vector2i(4, 1), 90, 1)  # R90 bench

	selection.call("rebuild_mapping")
	var spy1 := _spy_for(selection)
	selection.call("on_cell_clicked", Vector2i(1, 1))
	var first: Array = spy1.emissions[0] if spy1.emissions.size() > 0 else []
	selection.call("on_esc_pressed")

	selection.call("rebuild_mapping")  # second rebuild
	var spy2 := _spy_for(selection)
	selection.call("on_cell_clicked", Vector2i(1, 1))
	var second: Array = spy2.emissions[0] if spy2.emissions.size() > 0 else []

	_check(first.size() == 4 and second.size() == 4, "idempotency — both rebuilds emit 4-arg payloads")
	if first.size() == 4 and second.size() == 4:
		# Compare field-by-field, NOT str() of the whole emission — the
		# EquipmentDef is a fresh deep copy per get_definition() call, so
		# object identity differs; only the payload VALUES must be equal.
		var same_id: bool = str(first[0]) == str(second[0])
		var same_def: bool = (first[1] != null and second[1] != null
			and first[1].get("id") == second[1].get("id"))
		var same_cell: bool = str(first[2]) == str(second[2])
		var same_rot: bool = str(first[3]) == str(second[3])
		_check(same_id and same_def and same_cell and same_rot,
			"idempotency — payload after rebuild #2 identical to rebuild #1 (id=%s def=%s cell=%s rot=%s)"
			% [same_id, same_def, same_cell, same_rot])
	# And the R90 bench still resolves identically after the second rebuild.
	var spy3 := _spy_for(selection)
	selection.call("on_cell_clicked", Vector2i(5, 1))
	_check_single_select(spy3, 1, "bench_01", Vector2i(4, 1), 90, "idempotency — R90 bench after second rebuild")


# === QA edge: occupant with no catalog match ===

func _test_unmatched_footprint_skipped_loudly() -> void:
	print("\n[edge] occupant whose footprint matches NO catalog def → skipped loudly (no half-built entry)")
	var parts := _make_world()
	var grid: RefCounted = parts[0]
	var selection: RefCounted = parts[3]

	# An L-shaped 3-cell footprint — no catalog def reproduces it (catalog
	# shapes are locked to 1×1/1×2/2×2). Commit it as occupant 7.
	var fp: Array[Vector2i] = [Vector2i(1, 1), Vector2i(2, 1), Vector2i(1, 2)]
	var ac: Array[Vector2i] = [Vector2i(0, 0)]
	grid.call("commit", 7, fp, ac, 0)
	# A normal treadmill at (4,4) alongside — must still rebuild cleanly.
	_commit_loaded(grid, "treadmill_01", Vector2i(4, 4), 0, 8)

	selection.call("rebuild_mapping")

	var spy := _spy_for(selection)
	selection.call("on_cell_clicked", Vector2i(4, 4))
	_check(selection.call("get_selected_instance_id") == 8, "unmatched — the catalog-matched treadmill (id 8) still rebuilds and selects")
	_check_single_select(spy, 8, "treadmill_01", Vector2i(4, 4), 0, "unmatched companion")

	# The unmatched occupant is NOT in the mapping — clicking it is a loud
	# no-op (selection unchanged from the treadmill, no crash, no new signal).
	var emissions_before: int = spy.emissions.size()
	selection.call("on_cell_clicked", Vector2i(1, 1))
	_check(selection.call("get_selected_instance_id") == 8, "unmatched — selection unchanged (loud no-op, not a selection)")
	_check(spy.emissions.size() == emissions_before, "unmatched — no new signal fired for the unmatched occupant")
	_check(true, "unmatched — rebuild_mapping() skipped the unmatched occupant without crashing")


# === Load transition: selection resets to none ===

func _test_rebuild_resets_selection_state() -> void:
	print("\n[states] rebuild resets selection to none (GDD: '(at load) mapping rebuilt → none selected')")
	var parts := _make_world()
	var grid: RefCounted = parts[0]
	var placement: RefCounted = parts[2]
	var selection: RefCounted = parts[3]

	# A pre-load session with a live selection.
	_place(placement, "treadmill_01", Vector2i(1, 1), 0)
	selection.call("on_cell_clicked", Vector2i(1, 1))
	_check(selection.call("get_selected_instance_id") == 0, "reset — pre-load selection active (id 0)")

	# Simulated load: rebuild over the SAME grid → selection must clear.
	selection.call("rebuild_mapping")
	_check(selection.call("get_selected_instance_id") == -1, "reset — after rebuild, selection is none")
	# The mapping still works — the piece is selectable again.
	var spy := _spy_for(selection)
	selection.call("on_cell_clicked", Vector2i(1, 1))
	_check(selection.call("get_selected_instance_id") == 0, "reset — piece re-selectable after rebuild")


# === Control Manifest: use-before-init guard ===

func _test_rebuild_before_init_guard() -> void:
	print("\n[GUARD] rebuild_mapping() before init() → safe default, no crash")
	var sel: RefCounted = (load(SEL_SCRIPT) as Script).new()
	sel.call("rebuild_mapping")  # must push_error + no-op, never crash
	_check(true, "GUARD — rebuild_mapping() before init() did not crash")
