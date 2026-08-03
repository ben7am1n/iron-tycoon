# tests/unit/zone_rules/spaciousness_test.gd
# Story 003: spaciousness Formula
# Covers the 3 BLOCKING ACs scoped to this story: AC6 (exact 0.25 value),
# AC7 (total_adj == 0 guard → 0.0, no exception), AC17 (out-of-bounds
# boundary cells excluded from total_adj). Also verifies the static-only
# read (walls + placed footprints via the fake's solid_cells — zero member
# data), output range [0, C_max], dedupe of shared neighbor cells, and that
# the ZR-001 evaluate entry keeps its shape.
# Uses the fake GridStateReader / frozen EquipmentCatalog stubs per the
# story requirement — constructing a real grid+placement stack is too heavy
# for a pure-function unit test.
# Run standalone: godot --headless --script tests/unit/zone_rules/spaciousness_test.gd
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"

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
	print("  UNIT TEST: ZoneRules — spaciousness Formula (Story 003)")
	print("=".repeat(48))

	_test_ac6_exact_quarter()
	_test_ac6_edge_open_zero()
	_test_ac6_edge_all_open_cmax()
	_test_ac7_zero_adjacency_guard()
	_test_ac7_fully_walled_in_no_crash()
	_test_ac17_corner_excludes_out_of_bounds()
	_test_ac17_edge_aligned_access_cells()
	_test_dedupe_shared_neighbor_cell()
	_test_placed_footprint_counts_solid()
	_test_static_only_no_member_data()
	_test_range_and_non_negative()
	_test_inherited_entry_shape_preserved()

	print("\n=== SPACIOUSNESS TEST: %d passed, %d failed ===" % [_pass, _fail])
	return {"pass": _pass, "fail": _fail}


func _check(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
		print("  PASS: " + msg)
	else:
		_fail += 1
		print("  FAIL: " + msg)


# === Helpers ===

func _ED() -> Script:
	return load("res://src/systems/equipment_def.gd") as Script


func _EC() -> Script:
	return load("res://src/systems/equipment_catalog.gd") as Script


func _PI() -> Script:
	return load("res://src/systems/placed_instance.gd") as Script


func _ZR() -> Script:
	return load("res://src/systems/zone_rules.gd") as Script


## Builds a valid canonical-0° fixture def with the given effects container.
func _make_def(id: String, effects: Array[Dictionary]) -> RefCounted:
	var footprint: Array[Vector2i] = [Vector2i(0, 0)]
	var access: Array[Vector2i] = [Vector2i(0, 1)]
	var def: RefCounted = _ED().new(
		id,
		"Test %s" % id,
		["strength"],
		footprint,
		access,
		100,
		"",
		effects,
		200,
		30,
		100,
		300,
	)
	return def


## Loads a frozen catalog holding the given defs.
func _make_catalog(defs: Array) -> RefCounted:
	var cat: RefCounted = _EC().new()
	for d in defs:
		cat.call("_add_definition", d)
	cat.call("_freeze")
	return cat


## Builds a PlacedInstance DTO (instance_id, equipment_id, anchor, rotation,
## transformed footprint + access cells).
func _make_instance(id: int, equipment_id: String, footprint: Array[Vector2i], access: Array[Vector2i]) -> RefCounted:
	return _PI().new(id, equipment_id, Vector2i(0, 0), 0, footprint, access)


## Builds a fake GridStateReader with the given placed instances, grid size
## and solid cells (walls + placed footprints — static solidity only).
func _make_reader(instances: Array[PlacedInstance], dims: Vector2i, solid: Array[Vector2i]) -> RefCounted:
	var reader: RefCounted = (load("res://tests/unit/zone_rules/fake_grid_state_reader.gd") as Script).new()
	reader.placed_instances = instances
	reader.grid_dimensions = dims
	var solid_dict: Dictionary = {}
	for c in solid:
		solid_dict[c] = true
	reader.solid_cells = solid_dict
	return reader


## Convenience: a fresh ZoneRules instance evaluating [reader] against
## [catalog].
func _evaluate(reader: RefCounted, catalog: RefCounted) -> Dictionary:
	var zr: RefCounted = _ZR().new()
	return zr.call("evaluate", reader, catalog)


# === AC6: 精确值 ===

func _test_ac6_exact_quarter() -> void:
	print("\n[AC6] total_adj=4, open_adj=2 -> spaciousness == 0.25 exactly (0.5 x 2/4)")

	var catalog := _make_catalog([
		_make_def("machine", [{"tag": "comfort", "magnitude": 0.4}]),
	])
	# 1x1 footprint at (5,5) on a 10x10 grid, no access cells -> exactly 4
	# in-bounds orthogonal neighbors: (4,5),(6,5),(5,4),(5,6). Mark (4,5)
	# and (6,5) solid (walls) -> open_adj=2, total_adj=4.
	var reader := _make_reader(
		[_make_instance(1, "machine", [Vector2i(5, 5)], [])],
		Vector2i(10, 10),
		[Vector2i(4, 5), Vector2i(6, 5)],
	)

	var result := _evaluate(reader, catalog)
	var row: Dictionary = result[1]
	_check(row["spaciousness"] == 0.25, "spaciousness_i == 0.25 exactly (0.5 x 2/4)")


func _test_ac6_edge_open_zero() -> void:
	print("\n[AC6 edge] open_adj = 0 -> spaciousness == 0.0")

	var catalog := _make_catalog([
		_make_def("machine", [{"tag": "comfort", "magnitude": 0.4}]),
	])
	# All 4 neighbors solid -> open_adj=0, total_adj=4 -> 0.5 x 0/4 = 0.0.
	var reader := _make_reader(
		[_make_instance(1, "machine", [Vector2i(5, 5)], [])],
		Vector2i(10, 10),
		[Vector2i(4, 5), Vector2i(6, 5), Vector2i(5, 4), Vector2i(5, 6)],
	)

	var result := _evaluate(reader, catalog)
	_check(result[1]["spaciousness"] == 0.0, "spaciousness_i == 0.0 when open_adj == 0")


func _test_ac6_edge_all_open_cmax() -> void:
	print("\n[AC6 edge] open_adj = total_adj -> spaciousness == C_max (0.5)")

	var catalog := _make_catalog([
		_make_def("machine", [{"tag": "comfort", "magnitude": 0.4}]),
	])
	# No solid cells -> all 4 neighbors open -> 0.5 x 4/4 = 0.5 = C_max.
	var reader := _make_reader(
		[_make_instance(1, "machine", [Vector2i(5, 5)], [])],
		Vector2i(10, 10),
		[],
	)

	var result := _evaluate(reader, catalog)
	_check(result[1]["spaciousness"] == 0.5, "spaciousness_i == C_max (0.5) when all adjacent cells are open")


# === AC7: 零邻接守卫 ===

func _test_ac7_zero_adjacency_guard() -> void:
	print("\n[AC7] total_adj == 0 -> spaciousness == 0.0, no exception")

	var catalog := _make_catalog([
		_make_def("machine", [{"tag": "comfort", "magnitude": 0.4}]),
	])
	# 1x1 footprint on a 1x1 grid: all 4 orthogonal neighbors are out of
	# bounds -> total_adj == 0. Must not divide by zero, must not crash.
	var reader := _make_reader(
		[_make_instance(1, "machine", [Vector2i(0, 0)], [])],
		Vector2i(1, 1),
		[],
	)

	var result := _evaluate(reader, catalog)
	_check(result[1]["spaciousness"] == 0.0, "spaciousness_i == 0.0 when total_adj == 0 (no divide-by-zero)")
	_check(result.has(1), "evaluate() returned a normal result — no exception on zero adjacency")


func _test_ac7_fully_walled_in_no_crash() -> void:
	print("\n[AC7 edge] fully walled-in instance (should not occur under placement rules, must not crash)")

	var catalog := _make_catalog([
		_make_def("machine", [{"tag": "comfort", "magnitude": 0.4}]),
	])
	# Footprint (5,5) + access (5,6); every in-bounds orthogonal neighbor of
	# the union is solid -> open_adj == 0 -> 0.0, no crash.
	var reader := _make_reader(
		[_make_instance(1, "machine", [Vector2i(5, 5)], [Vector2i(5, 6)])],
		Vector2i(10, 10),
		[Vector2i(4, 5), Vector2i(6, 5), Vector2i(5, 4), Vector2i(4, 6), Vector2i(6, 6), Vector2i(5, 7)],
	)

	var result := _evaluate(reader, catalog)
	_check(result[1]["spaciousness"] == 0.0, "fully walled-in instance -> spaciousness == 0.0, no exception")


# === AC17: 边界排除 ===

func _test_ac17_corner_excludes_out_of_bounds() -> void:
	print("\n[AC17] instance at grid corner -> out-of-bounds cells excluded from total_adj")

	var catalog := _make_catalog([
		_make_def("machine", [{"tag": "comfort", "magnitude": 0.4}]),
	])
	# 1x1 footprint at corner (0,0) on a 5x5 grid. In-bounds neighbors:
	# (1,0) and (0,1) only — (-1,0) and (0,-1) are out of bounds and must be
	# excluded entirely (not counted as solid or open). No solid cells ->
	# total_adj=2, open_adj=2 -> 0.5 x 2/2 = 0.5. If OOB cells were counted
	# as solid, this would be 0.5 x 2/4 = 0.25; if counted as open, 0.5.
	var reader := _make_reader(
		[_make_instance(1, "machine", [Vector2i(0, 0)], [])],
		Vector2i(5, 5),
		[],
	)

	var result := _evaluate(reader, catalog)
	_check(result[1]["spaciousness"] == 0.5, "corner instance: total_adj == 2 (OOB excluded), spaciousness == 0.5")


func _test_ac17_edge_aligned_access_cells() -> void:
	print("\n[AC17 edge] access cells aligned along the grid edge")

	var catalog := _make_catalog([
		_make_def("machine", [{"tag": "comfort", "magnitude": 0.4}]),
	])
	# Footprint (0,0) + access (0,1), both on the left grid edge of a 5x5
	# grid. Own cells: {(0,0),(0,1)}. In-bounds orthogonal neighbors of the
	# union, excluding own:
	#   from (0,0): (1,0) — (-1,0),(0,-1) OOB
	#   from (0,1): (1,1),(0,2) — (-1,1) OOB
	# -> total_adj = 3, all open -> 0.5 x 3/3 = 0.5.
	var reader := _make_reader(
		[_make_instance(1, "machine", [Vector2i(0, 0)], [Vector2i(0, 1)])],
		Vector2i(5, 5),
		[],
	)

	var result := _evaluate(reader, catalog)
	_check(result[1]["spaciousness"] == 0.5, "edge-aligned access: total_adj == 3 (OOB excluded), spaciousness == 0.5")


# === 实现正确性 ===

func _test_dedupe_shared_neighbor_cell() -> void:
	print("\n[dedupe] a neighbor cell shared by two own cells counts once in total_adj")

	var catalog := _make_catalog([
		_make_def("machine", [{"tag": "comfort", "magnitude": 0.4}]),
	])
	# Own cells: footprint (1,0) and (1,2) — cell (1,1) is adjacent to BOTH.
	# Grid 5x5. Distinct in-bounds neighbors, excluding own:
	#   from (1,0): (0,0),(2,0),(1,1)  [(1,-1) OOB]
	#   from (1,2): (0,2),(2,2),(1,1),(1,3)
	# -> { (0,0),(2,0),(1,1),(0,2),(2,2),(1,3) } = 6 distinct (1,1 counted
	# once). Mark (1,1) solid -> open_adj=5, total_adj=6 -> 0.5 x 5/6.
	var reader := _make_reader(
		[_make_instance(1, "machine", [Vector2i(1, 0), Vector2i(1, 2)], [])],
		Vector2i(5, 5),
		[Vector2i(1, 1)],
	)

	var result := _evaluate(reader, catalog)
	var expected: float = 0.5 * (5.0 / 6.0)
	_check(is_equal_approx(result[1]["spaciousness"], expected), "shared neighbor counted once: spaciousness == 0.5 x 5/6 (approx)")
	_check(absf(result[1]["spaciousness"] - expected) < 1e-9, "dedupe precision within 1e-9")


func _test_placed_footprint_counts_solid() -> void:
	print("\n[static] a placed footprint is solid for the neighbor's spaciousness")

	var catalog := _make_catalog([
		_make_def("machine", [{"tag": "comfort", "magnitude": 0.4}]),
	])
	# Instance 1 at (5,5); instance 2's placed footprint occupies (6,5).
	# The fake's solid_cells carries instance 2's footprint (static solidity:
	# walls + placed footprints). For instance 1: neighbors (4,5),(6,5),
	# (5,4),(5,6); (6,5) solid -> open_adj=3, total_adj=4 -> 0.375.
	var reader := _make_reader(
		[
			_make_instance(1, "machine", [Vector2i(5, 5)], []),
			_make_instance(2, "machine", [Vector2i(6, 5)], []),
		],
		Vector2i(10, 10),
		[Vector2i(6, 5)],
	)

	var result := _evaluate(reader, catalog)
	_check(result[1]["spaciousness"] == 0.375, "instance 1 sees the placed footprint as solid: 0.5 x 3/4 == 0.375")


func _test_static_only_no_member_data() -> void:
	print("\n[static] spaciousness reads ONLY static solidity — no dynamic member data")

	# The AC13 static guarantee is enforced by evaluate_purity_test's source
	# scan (forbidden tokens: get_occupant_id / get_access_cells /
	# get_member_position / get_queue_length / get_position / dynamic
	# systems). This fixture re-checks the observable behavior: the fake
	# reader exposes ONLY placed_instances + is_solid + get_dimensions —
	# there is no member-position or queue-length surface for ZoneRules to
	# read, so the computation is a pure function of static geometry.
	var source: String = FileAccess.get_file_as_string("res://src/systems/zone_rules.gd")
	var forbidden := ["get_occupant_id", "get_access_cells", "get_member_position", "get_queue_length", "get_position"]
	var clean := true
	for token in forbidden:
		if source.contains(token):
			clean = false
			print("    found forbidden token: %s" % token)
	_check(clean, "zone_rules.gd still references no member-data / single-cell occupancy API (AC13 holds after ZR-003)")


func _test_range_and_non_negative() -> void:
	print("\n[range] spaciousness_i in [0, C_max] and total non-negative for mixed fixtures")

	var catalog := _make_catalog([
		_make_def("machine", [{"tag": "comfort", "magnitude": 0.4}]),
	])
	# Mixed fixture: one open instance, one walled-in instance, one at the
	# corner — every spaciousness value must lie in [0, 0.5].
	var reader := _make_reader(
		[
			_make_instance(1, "machine", [Vector2i(5, 5)], []),
			_make_instance(2, "machine", [Vector2i(2, 2)], []),
			_make_instance(3, "machine", [Vector2i(0, 0)], []),
		],
		Vector2i(10, 10),
		[Vector2i(1, 2), Vector2i(3, 2), Vector2i(2, 1), Vector2i(2, 3)],
	)

	var result := _evaluate(reader, catalog)
	var in_range := true
	for row in result.values():
		var d: Dictionary = row
		var s: float = float(d["spaciousness"])
		if s < 0.0 or s > 0.5:
			in_range = false
		if float(d["total"]) < 0.0:
			in_range = false
	_check(in_range, "every spaciousness value in [0, 0.5] and every total >= 0 (AC8 still holds)")


func _test_inherited_entry_shape_preserved() -> void:
	print("\n[inherited] ZR-001 entry preserved: exact 4 keys, ascending ids, total == sum")

	var catalog := _make_catalog([
		_make_def("machine", [{"tag": "comfort", "magnitude": 0.4}]),
	])
	var reader := _make_reader(
		[
			_make_instance(7, "machine", [Vector2i(5, 5)], []),
			_make_instance(2, "machine", [Vector2i(1, 1)], []),
		],
		Vector2i(10, 10),
		[],
	)

	var result := _evaluate(reader, catalog)
	_check(result.keys() == [2, 7], "result keys in ascending instance_id order (2, 7) despite shuffled input")
	var shape_ok := true
	for row in result.values():
		var d: Dictionary = row
		if d.size() != 4:
			shape_ok = false
		for key in ["comfort", "zone_synergy", "spaciousness", "total"]:
			if not d.has(key):
				shape_ok = false
	_check(shape_ok, "every row has EXACTLY {comfort, zone_synergy, spaciousness, total} (AC14 holds)")
	_check(result[7]["total"] == result[7]["comfort"] + result[7]["zone_synergy"] + result[7]["spaciousness"], "total == comfort + zone_synergy + spaciousness (structural)")
	_check(result[7]["spaciousness"] == 0.5, "open instance (no solids) at center: spaciousness == 0.5 == C_max")
	_check(result[2]["spaciousness"] == 0.5, "second open instance: spaciousness == 0.5")
