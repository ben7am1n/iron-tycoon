# tests/unit/zone_rules/preview_commit_test.gd
# Story 004: Preview == Commit Equivalence (AC2)
#
# The single most important acceptance criterion of the zone-rules epic:
# evaluating a SPECULATIVE snapshot (a GridSnapshot with hypothetical piece X
# at a stable provisional instance_id P) MUST equal evaluating the REAL
# snapshot after X is committed, for the same resulting instance set — every
# shared instance_id's {comfort, zone_synergy, spaciousness, total} are
# bit-identical.
#
# Why this holds: evaluate() is typed to the abstract GridStateReader
# (TR-GS-025) and reads ONLY get_placed_instances() + EquipmentCatalog
# (AC13). A GridSnapshot built over a base reader with _commit_in_place(P,
# fp, ac, equipment_id) reports the SAME instance set a committed grid
# reports (base instances + X), so the pure function scores both
# identically — no special-casing anywhere (Core Rule 2).
#
# Fixture model (white-box, per the story's fake-reader requirement):
#   - the SPECULATIVE side is a REAL GridSnapshot over a fake base reader,
#     with X added via _commit_in_place (provisional instance_id P and its
#     equipment_id carried through the snapshot);
#   - the COMMITTED side is a fake reader holding the same instance set with
#     X committed (same instance_id P, same cells, same equipment_id) and
#     matching solid_cells so spaciousness reads the same static solidity.
#   - evaluate() both and diff per instance_id.
#
# QA edge cases covered: X adjacent to existing same-zone equipment (synergy
# changes propagate identically on BOTH X and its neighbor) and X isolated.
# Run standalone: godot --headless --script tests/unit/zone_rules/preview_commit_test.gd
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"

const TOL := 1e-6

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
	print("  UNIT TEST: ZoneRules — Preview == Commit Equivalence (Story 004)")
	print("=".repeat(48))

	_test_ac2_adjacent_same_zone_synergy_propagates()
	_test_ac2_isolated_piece()
	_test_ac2_multi_add_snapshot()
	_test_ac2_speculative_carries_equipment_id()

	print("\n=== PREVIEW COMMIT TEST: %d passed, %d failed ===" % [_pass, _fail])
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


func _GS() -> Script:
	return load("res://src/systems/grid_snapshot.gd") as Script


## Builds a valid canonical-0° fixture def. TYPED arrays are required —
## Godot's typed-array parameter boundary rejects untyped literals through
## Object.call() (tech-debt register, Story 005).
func _make_def(id: String, zones: Array, effects: Array[Dictionary]) -> RefCounted:
	var footprint: Array[Vector2i] = [Vector2i(0, 0)]
	var access: Array[Vector2i] = [Vector2i(0, 1)]
	var def: RefCounted = _ED().new(
		id,
		"Test %s" % id,
		zones,
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
## and solid cells (static solidity: walls + placed footprints).
func _make_reader(instances: Array[PlacedInstance], dims: Vector2i, solid: Array[Vector2i]) -> RefCounted:
	var reader: RefCounted = (load("res://tests/unit/zone_rules/fake_grid_state_reader.gd") as Script).new()
	reader.placed_instances = instances
	reader.grid_dimensions = dims
	var solid_dict: Dictionary = {}
	for c in solid:
		solid_dict[c] = true
	reader.solid_cells = solid_dict
	return reader


## Builds a REAL GridSnapshot (the speculative preview machinery) over
## [base_reader], adding hypothetical piece X: provisional instance_id P,
## footprint [fp], access [ac], equipment_id [equipment_id] carried through
## the snapshot (AC2 — the speculative instance must be structurally
## identical to a committed one).
func _make_speculative(base_reader: RefCounted, P: int, fp: Array[Vector2i], ac: Array[Vector2i], equipment_id: String) -> RefCounted:
	var snap: RefCounted = _GS().new()
	snap.call("init", base_reader)
	snap.call("_commit_in_place", P, fp, ac, equipment_id)
	return snap


## Convenience: a fresh ZoneRules instance evaluating [reader] against
## [catalog] (default config — no strict_mode, no callback).
func _evaluate(reader: RefCounted, catalog: RefCounted) -> Dictionary:
	var zr: RefCounted = _ZR().new()
	return zr.call("evaluate", reader, catalog)


## Asserts the AC2 contract: [speculative_result] and [committed_result]
## contain the same instance_ids, and every shared instance_id's four fields
## are identical (exact float equality — same pure function, same inputs).
func _assert_preview_equals_commit(speculative_result: Dictionary, committed_result: Dictionary, label: String) -> void:
	var same_keys := true
	for id in speculative_result:
		if not committed_result.has(id):
			same_keys = false
	for id in committed_result:
		if not speculative_result.has(id):
			same_keys = false
	_check(same_keys, "%s: speculative and committed results have the same instance_id key set" % label)

	var all_identical := true
	var first_mismatch := ""
	for id in speculative_result:
		var spec_row: Dictionary = speculative_result[id]
		var commit_row: Dictionary = committed_result[id]
		for field in ["comfort", "zone_synergy", "spaciousness", "total"]:
			if abs(float(spec_row[field]) - float(commit_row[field])) > 0.0:
				all_identical = false
				first_mismatch = "instance_id=%d field=%s spec=%.9f commit=%.9f" % [id, field, float(spec_row[field]), float(commit_row[field])]
				break
		if not all_identical:
			break
	_check(all_identical, "%s: every shared instance_id's {comfort, zone_synergy, spaciousness, total} identical (%s)" % [label, first_mismatch])


# === AC2: 预览==提交 ===

func _test_ac2_adjacent_same_zone_synergy_propagates() -> void:
	print("\n[AC2] X adjacent to existing same-zone equipment — synergy changes propagate identically")

	var catalog := _make_catalog([
		_make_def("barbell", ["strength"], [{"tag": "comfort", "magnitude": 0.85}]),
		_make_def("treadmill", ["cardio"], [{"tag": "comfort", "magnitude": 0.4}]),
	])
	var dims := Vector2i(10, 10)

	# Committed state: barbell (id 1) at (5,5), treadmill (id 2) at (2,2).
	var base_instances: Array[PlacedInstance] = [
		_make_instance(1, "barbell", [Vector2i(5, 5)], [Vector2i(5, 6)]) as PlacedInstance,
		_make_instance(2, "treadmill", [Vector2i(2, 2)], [Vector2i(2, 3)]) as PlacedInstance,
	]
	var base_solid: Array[Vector2i] = [Vector2i(5, 5), Vector2i(2, 2)]

	# Hypothetical piece X: a barbell (strength) placed orthogonally adjacent
	# to the existing barbell — (6,5) shares an edge with (5,5). Provisional
	# instance_id P=99.
	var P := 99
	var fp_x: Array[Vector2i] = [Vector2i(6, 5)]
	var ac_x: Array[Vector2i] = [Vector2i(6, 6)]

	# Speculative side: REAL GridSnapshot over the pre-commit base.
	var base_reader := _make_reader(base_instances, dims, base_solid)
	var speculative := _make_speculative(base_reader, P, fp_x, ac_x, "barbell")
	var spec_result := _evaluate(speculative, catalog)

	# Committed side: fake reader with the same resulting instance set.
	var committed_instances: Array[PlacedInstance] = []
	committed_instances.assign(base_instances)
	committed_instances.append(_make_instance(P, "barbell", fp_x, ac_x) as PlacedInstance)
	var committed_solid: Array[Vector2i] = base_solid.duplicate()
	committed_solid.append(Vector2i(6, 5))
	var committed := _make_reader(committed_instances, dims, committed_solid)
	var commit_result := _evaluate(committed, catalog)

	_assert_preview_equals_commit(spec_result, commit_result, "adjacent same-zone X")

	# The diff is meaningful: X's own synergy AND the neighbor's synergy both
	# CHANGED (X adjacent to a strength barbell → r=0.25 on both), and the
	# speculative view shows the same propagation as the committed view.
	_check(spec_result.has(P), "speculative result contains hypothetical piece X (instance_id %d)" % P)
	_check(spec_result[P]["zone_synergy"] > 0.0, "speculative X earns zone_synergy > 0 (adjacent same-zone): %.4f" % spec_result[P]["zone_synergy"])
	_check(
		abs(spec_result[1]["zone_synergy"] - commit_result[1]["zone_synergy"]) <= 0.0,
		"neighbor barbell's zone_synergy identical between speculative and committed (%.9f)" % spec_result[1]["zone_synergy"]
	)
	_check(spec_result[1]["zone_synergy"] > 0.0, "neighbor barbell's zone_synergy > 0 (X propagated): %.4f" % spec_result[1]["zone_synergy"])
	_check(
		abs(spec_result[2]["zone_synergy"] - commit_result[2]["zone_synergy"]) <= 0.0,
		"unaffected treadmill's zone_synergy identical too (%.9f)" % spec_result[2]["zone_synergy"]
	)


func _test_ac2_isolated_piece() -> void:
	print("\n[AC2] X isolated (no neighbors) — preview equals commit")

	var catalog := _make_catalog([
		_make_def("barbell", ["strength"], [{"tag": "comfort", "magnitude": 0.85}]),
	])
	var dims := Vector2i(10, 10)

	var base_instances: Array[PlacedInstance] = [
		_make_instance(1, "barbell", [Vector2i(5, 5)], [Vector2i(5, 6)]) as PlacedInstance,
	]
	var base_solid: Array[Vector2i] = [Vector2i(5, 5)]

	# X far away at (9,9) — no adjacency, wide open spaciousness.
	var P := 77
	var fp_x: Array[Vector2i] = [Vector2i(9, 9)]
	var ac_x: Array[Vector2i] = [Vector2i(9, 8)]

	var base_reader := _make_reader(base_instances, dims, base_solid)
	var speculative := _make_speculative(base_reader, P, fp_x, ac_x, "barbell")
	var spec_result := _evaluate(speculative, catalog)

	var committed_instances: Array[PlacedInstance] = []
	committed_instances.assign(base_instances)
	committed_instances.append(_make_instance(P, "barbell", fp_x, ac_x) as PlacedInstance)
	var committed_solid: Array[Vector2i] = base_solid.duplicate()
	committed_solid.append(Vector2i(9, 9))
	var committed := _make_reader(committed_instances, dims, committed_solid)
	var commit_result := _evaluate(committed, catalog)

	_assert_preview_equals_commit(spec_result, commit_result, "isolated X")
	_check(spec_result[P]["zone_synergy"] == 0.0, "isolated X zone_synergy == 0.0 in speculative view")
	_check(
		abs(spec_result[P]["spaciousness"] - commit_result[P]["spaciousness"]) <= 0.0,
		"isolated X spaciousness identical (%.9f)" % spec_result[P]["spaciousness"]
	)


func _test_ac2_multi_add_snapshot() -> void:
	print("\n[AC2] snapshot with TWO hypothetical pieces — full result diff")

	var catalog := _make_catalog([
		_make_def("barbell", ["strength"], [{"tag": "comfort", "magnitude": 0.85}]),
		_make_def("bench", ["strength"], [{"tag": "comfort", "magnitude": 0.7}]),
	])
	var dims := Vector2i(10, 10)

	var base_instances: Array[PlacedInstance] = [
		_make_instance(1, "barbell", [Vector2i(5, 5)], [Vector2i(5, 6)]) as PlacedInstance,
	]
	var base_solid: Array[Vector2i] = [Vector2i(5, 5)]

	# Two hypothetical pieces: X1 (bench, strength) adjacent to barbell at
	# (6,5); X2 (barbell, strength) isolated at (8,8).
	var fp1: Array[Vector2i] = [Vector2i(6, 5)]
	var ac1: Array[Vector2i] = [Vector2i(6, 6)]
	var fp2: Array[Vector2i] = [Vector2i(8, 8)]
	var ac2: Array[Vector2i] = [Vector2i(8, 7)]

	var base_reader := _make_reader(base_instances, dims, base_solid)
	var snap: RefCounted = _GS().new()
	snap.call("init", base_reader)
	snap.call("_commit_in_place", 201, fp1, ac1, "bench")
	snap.call("_commit_in_place", 202, fp2, ac2, "barbell")
	var spec_result := _evaluate(snap, catalog)

	var committed_instances: Array[PlacedInstance] = []
	committed_instances.assign(base_instances)
	committed_instances.append(_make_instance(201, "bench", fp1, ac1) as PlacedInstance)
	committed_instances.append(_make_instance(202, "barbell", fp2, ac2) as PlacedInstance)
	var committed_solid: Array[Vector2i] = base_solid.duplicate()
	committed_solid.append(Vector2i(6, 5))
	committed_solid.append(Vector2i(8, 8))
	var committed := _make_reader(committed_instances, dims, committed_solid)
	var commit_result := _evaluate(committed, catalog)

	_assert_preview_equals_commit(spec_result, commit_result, "two hypothetical pieces")
	_check(spec_result[201]["zone_synergy"] > 0.0, "X1 (bench) synergy > 0 adjacent to barbell: %.4f" % spec_result[201]["zone_synergy"])
	_check(spec_result[202]["zone_synergy"] == 0.0, "X2 (barbell) isolated synergy == 0.0")


func _test_ac2_speculative_carries_equipment_id() -> void:
	print("\n[AC2] speculative snapshot carries X's equipment_id (structural identity)")

	var catalog := _make_catalog([
		_make_def("barbell", ["strength"], [{"tag": "comfort", "magnitude": 0.85}]),
	])
	var dims := Vector2i(10, 10)
	var base_instances: Array[PlacedInstance] = [
		_make_instance(1, "barbell", [Vector2i(5, 5)], [Vector2i(5, 6)]) as PlacedInstance,
	]
	var base_reader := _make_reader(base_instances, dims, [Vector2i(5, 5)])
	var P := 55
	var fp_x: Array[Vector2i] = [Vector2i(7, 7)]
	var ac_x: Array[Vector2i] = [Vector2i(7, 8)]

	var speculative := _make_speculative(base_reader, P, fp_x, ac_x, "barbell")

	# The speculative instance set is structurally identical to a committed
	# one: X present with provisional instance_id P AND its equipment_id.
	var spec_instances: Array = speculative.call("get_placed_instances")
	var found_x := false
	for pi in spec_instances:
		if pi.instance_id == P:
			found_x = true
			_check(pi.equipment_id == "barbell", "speculative X carries equipment_id 'barbell' (got '%s')" % pi.equipment_id)
			_check(pi.footprint_cells == fp_x, "speculative X footprint cells match committed X")
			_check(pi.access_cells == ac_x, "speculative X access cells match committed X")
	_check(found_x, "speculative snapshot contains X with provisional instance_id %d" % P)
	_check(spec_instances.size() == 2, "speculative instance set = 1 base + 1 hypothetical")

	# And scoring it proves preview==commit for X's own row.
	var spec_result := _evaluate(speculative, catalog)
	_check(spec_result.has(P), "evaluate(speculative) includes X's row")
	_check(spec_result[P]["total"] == spec_result[P]["comfort"] + spec_result[P]["zone_synergy"] + spec_result[P]["spaciousness"], "X row total = pure sum")
