# tests/unit/zone_rules/zone_synergy_test.gd
# Story 002: zone_synergy with Perimeter Normalization
# Covers the 6 BLOCKING ACs scoped to this story: AC3 (diagonal NOT
# adjacent), AC4 (1×1 synergy values incl. r=1.0 < S_max strictly), AC4b
# (perimeter normalization — footprint size does not advantage synergy),
# AC5 (distinct neighbor count, N_max_A=8 for 2×2), AC9 (multi-zone OR-match),
# AC10 (cross-zone neutral, never negative). Plus Core Rule 5 (empty
# zone_membership never earns synergy) and the S_max/k config override seam.
# Uses fake GridStateReader / frozen EquipmentCatalog stubs per the story
# requirement — constructing a real grid+placement stack is too heavy for a
# pure-function unit test.
#
# Formula under test (TR-ZR-004): zone_synergy_i = S_max × (1 − e^(−k × r_i)),
# r_i = n_same_i / N_max_i, with S_max=1.0, k=2.4 (GDD provisional anchors).
# Reference values (verified against the formula):
#   r=0      → 0.0
#   r=0.125  → ≈0.2592   (1/8)
#   r=0.25   → ≈0.4512   (1/4 and 2/8 — AC4b identical)
#   r=0.5    → ≈0.6988   (2/4 and 4/8)
#   r=0.75   → ≈0.8347   (3/4 — story text rounds to ≈0.835)
#   r=1.0    → ≈0.9093   (4/4 — strictly < S_max)
# Run standalone: godot --headless --script tests/unit/zone_rules/zone_synergy_test.gd
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"

const TOL := 1e-4

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
	print("  UNIT TEST: ZoneRules — zone_synergy with Perimeter Normalization (Story 002)")
	print("=".repeat(48))

	_test_ac3_diagonal_not_adjacent()
	_test_ac4_one_by_one_synergy_values()
	_test_ac4b_perimeter_normalization()
	_test_ac5_neighbor_dedup_and_n_max()
	_test_ac9_multi_zone_or_match()
	_test_ac10_cross_zone_neutral()
	_test_core_rule5_empty_zone_membership_never_earns()
	_test_config_override_seam()

	print("\n=== ZONE SYNERGY TEST: %d passed, %d failed ===" % [_pass, _fail])
	return {"pass": _pass, "fail": _fail}


func _check(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
		print("  PASS: " + msg)
	else:
		_fail += 1
		print("  FAIL: " + msg)


func _almost_eq(a: float, b: float, tol: float) -> bool:
	return abs(a - b) <= tol


# === Helpers ===

func _ED() -> Script:
	return load("res://src/systems/equipment_def.gd") as Script


func _EC() -> Script:
	return load("res://src/systems/equipment_catalog.gd") as Script


func _PI() -> Script:
	return load("res://src/systems/placed_instance.gd") as Script


func _ZR() -> Script:
	return load("res://src/systems/zone_rules.gd") as Script


## Builds a valid canonical-0° fixture def with the given zone membership and
## effects container. TYPED arrays are required — Godot's typed-array
## parameter boundary rejects untyped literals through Object.call()
## (tech-debt register, Story 005); direct .new() with typed locals is safe.
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


## Loads a frozen catalog holding the given defs (via the internal loader API
## the way Story 002's JSON loader will — _add_definition()..._freeze()).
func _make_catalog(defs: Array) -> RefCounted:
	var cat: RefCounted = _EC().new()
	for d in defs:
		cat.call("_add_definition", d)
	cat.call("_freeze")
	return cat


## Builds a PlacedInstance DTO (Story 006 / ADR-0003 shape: instance_id,
## equipment_id, anchor, rotation, transformed footprint + access cells).
func _make_instance(id: int, equipment_id: String, footprint: Array[Vector2i], access: Array[Vector2i]) -> RefCounted:
	return _PI().new(id, equipment_id, Vector2i(0, 0), 0, footprint, access)


## Builds a fake GridStateReader stub returning the given placed instances.
func _make_reader(instances: Array[PlacedInstance]) -> RefCounted:
	var reader: RefCounted = (load("res://tests/unit/zone_rules/fake_grid_state_reader.gd") as Script).new()
	reader.placed_instances = instances
	return reader


## Convenience: a fresh ZoneRules instance evaluating [reader] against
## [catalog] with the default (GDD anchor) config.
func _evaluate(reader: RefCounted, catalog: RefCounted) -> Dictionary:
	var zr: RefCounted = _ZR().new()
	return zr.call("evaluate", reader, catalog)


## Convenience: same, with an explicit tuning config Dictionary.
func _evaluate_with_config(reader: RefCounted, catalog: RefCounted, config: Dictionary) -> Dictionary:
	var zr: RefCounted = _ZR().new()
	return zr.call("evaluate", reader, catalog, config)


# === AC3: 对角不邻接 ===

func _test_ac3_diagonal_not_adjacent() -> void:
	print("\n[AC3] diagonal (corner-only) touching is NOT adjacency — zone_synergy unaffected")

	var catalog := _make_catalog([
		_make_def("s", ["strength"], [{"tag": "comfort", "magnitude": 0.5}]),
	])

	# Two 1×1 same-zone instances at (1,1) and (2,2): corner-only contact
	# (cell Manhattan distance 2) → not adjacent.
	var reader := _make_reader([
		_make_instance(1, "s", [Vector2i(1, 1)], [Vector2i(1, 2)]),
		_make_instance(2, "s", [Vector2i(2, 2)], [Vector2i(2, 3)]),
	])
	var result := _evaluate(reader, catalog)
	_check(result[1]["zone_synergy"] == 0.0, "1×1 pair touching only diagonally: neither counts the other — A zone_synergy == 0.0")
	_check(result[2]["zone_synergy"] == 0.0, "1×1 pair touching only diagonally: B zone_synergy == 0.0 (reverse direction unaffected)")

	# Edge: diagonal at the corner of a 2×2 instance — 1×1 at (2,2) touches
	# only the 2×2's corner cell (1,1).
	var reader2 := _make_reader([
		_make_instance(3, "s", [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)], [Vector2i(0, 2)]),
		_make_instance(4, "s", [Vector2i(2, 2)], [Vector2i(2, 3)]),
	])
	var result2 := _evaluate(reader2, catalog)
	_check(result2[3]["zone_synergy"] == 0.0, "2×2 vs corner-diagonal 1×1: 2×2 earns zone_synergy 0.0")
	_check(result2[4]["zone_synergy"] == 0.0, "2×2 vs corner-diagonal 1×1: the 1×1 earns zone_synergy 0.0")

	# Positive control: the SAME 2×2 with a 1×1 sharing a real orthogonal edge
	# MUST count — proves the diagonal exclusions above are not a "everything
	# is 0" artifact.
	var reader3 := _make_reader([
		_make_instance(5, "s", [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)], [Vector2i(0, 2)]),
		_make_instance(6, "s", [Vector2i(2, 1)], [Vector2i(2, 2)]),
	])
	var result3 := _evaluate(reader3, catalog)
	_check(result3[5]["zone_synergy"] > 0.0, "positive control: edge-adjacent 1×1 DOES count (2×2 synergy > 0)")
	_check(result3[6]["zone_synergy"] > 0.0, "positive control: the 1×1 also counts the 2×2 (synergy > 0)")


# === AC4: 1×1 协同值 ===

func _test_ac4_one_by_one_synergy_values() -> void:
	print("\n[AC4] 1×1 instance (N_max=4): r=0/0.25/0.75 → 0.0/≈0.451/≈0.835; r=1.0 strictly < S_max")

	var catalog := _make_catalog([
		_make_def("s", ["strength"], [{"tag": "comfort", "magnitude": 0.5}]),
	])

	# r = 0 (0/4): a lone 1×1.
	var lone := _make_reader([
		_make_instance(1, "s", [Vector2i(0, 0)], [Vector2i(0, 1)]),
	])
	_check(_evaluate(lone, catalog)[1]["zone_synergy"] == 0.0, "AC4 r=0 (0/4, no neighbors): zone_synergy == 0.0 exactly")

	# r = 0.25 (1/4): one same-zone neighbor on the east edge.
	var r25 := _make_reader([
		_make_instance(1, "s", [Vector2i(0, 0)], [Vector2i(0, 1)]),
		_make_instance(2, "s", [Vector2i(1, 0)], [Vector2i(1, 1)]),
	])
	var v25: float = _evaluate(r25, catalog)[1]["zone_synergy"]
	_check(_almost_eq(v25, 0.4512, TOL), "AC4 r=0.25 (1/4): zone_synergy ≈ 0.451 (got %.6f)" % v25)

	# r = 0.5 (2/4) — QA edge case.
	var r50 := _make_reader([
		_make_instance(1, "s", [Vector2i(2, 2)], [Vector2i(2, 3)]),
		_make_instance(2, "s", [Vector2i(3, 2)], [Vector2i(3, 3)]),
		_make_instance(3, "s", [Vector2i(2, 3)], [Vector2i(2, 4)]),
	])
	var v50: float = _evaluate(r50, catalog)[1]["zone_synergy"]
	_check(_almost_eq(v50, 0.6988, TOL), "AC4 edge r=0.5 (2/4): zone_synergy ≈ 0.699 (got %.6f)" % v50)

	# r = 0.75 (3/4): three same-zone neighbors (east, north, west).
	var r75 := _make_reader([
		_make_instance(1, "s", [Vector2i(1, 1)], [Vector2i(1, 2)]),
		_make_instance(2, "s", [Vector2i(2, 1)], [Vector2i(2, 2)]),
		_make_instance(3, "s", [Vector2i(1, 2)], [Vector2i(1, 3)]),
		_make_instance(4, "s", [Vector2i(0, 1)], [Vector2i(0, 2)]),
	])
	var v75: float = _evaluate(r75, catalog)[1]["zone_synergy"]
	_check(_almost_eq(v75, 0.8347, TOL), "AC4 r=0.75 (3/4): zone_synergy ≈ 0.835 (exact 0.8347; got %.6f)" % v75)

	# r = 1.0 (4/4): fully surrounded → strictly < S_max (never reaches 1.0).
	var r100 := _make_reader([
		_make_instance(1, "s", [Vector2i(1, 1)], [Vector2i(1, 2)]),
		_make_instance(2, "s", [Vector2i(2, 1)], [Vector2i(2, 2)]),
		_make_instance(3, "s", [Vector2i(1, 2)], [Vector2i(1, 3)]),
		_make_instance(4, "s", [Vector2i(0, 1)], [Vector2i(0, 2)]),
		_make_instance(5, "s", [Vector2i(1, 0)], [Vector2i(1, 1)]),
	])
	var v100: float = _evaluate(r100, catalog)[1]["zone_synergy"]
	_check(v100 < 1.0, "AC4 r=1.0 (fully surrounded 4/4): zone_synergy strictly < S_max=1.0 (got %.6f)" % v100)
	_check(_almost_eq(v100, 0.9093, TOL), "AC4 r=1.0: zone_synergy ≈ 0.909 (exact 0.90928; got %.6f)" % v100)


# === AC4b: 周长归一化 ===

func _test_ac4b_perimeter_normalization() -> void:
	print("\n[AC4b] perimeter normalization: 2×2(2/8) vs 1×1(1/4) → identical synergy at r=0.25")

	var catalog := _make_catalog([
		_make_def("s", ["strength"], [{"tag": "comfort", "magnitude": 0.5}]),
	])

	# 2×2 at (0,0)-(1,1) with two same-zone 1×1 neighbors on its east side:
	# N_max = 8 → r = 2/8 = 0.25. 1×1 with one same-zone neighbor: r = 1/4.
	var big := _make_reader([
		_make_instance(1, "s", [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)], [Vector2i(0, 2)]),
		_make_instance(2, "s", [Vector2i(2, 0)], [Vector2i(2, 1)]),
		_make_instance(3, "s", [Vector2i(2, 1)], [Vector2i(2, 2)]),
	])
	var big_row: Dictionary = _evaluate(big, catalog)[1]
	var small := _make_reader([
		_make_instance(10, "s", [Vector2i(0, 0)], [Vector2i(0, 1)]),
		_make_instance(11, "s", [Vector2i(1, 0)], [Vector2i(1, 1)]),
	])
	var small_row: Dictionary = _evaluate(small, catalog)[10]

	_check(_almost_eq(big_row["zone_synergy"], 0.4512, TOL), "AC4b 2×2 (n_same=2, N_max=8 → r=0.25): zone_synergy ≈ 0.451 (got %.6f)" % big_row["zone_synergy"])
	_check(_almost_eq(small_row["zone_synergy"], 0.4512, TOL), "AC4b 1×1 (n_same=1, N_max=4 → r=0.25): zone_synergy ≈ 0.451 (got %.6f)" % small_row["zone_synergy"])
	_check(abs(big_row["zone_synergy"] - small_row["zone_synergy"]) < TOL, "AC4b: 2×2(2/8) and 1×1(1/4) produce IDENTICAL synergy — footprint size does not advantage synergy")

	# QA edge: 2×2 with 4/8 vs 1×1 with 2/4 — same r=0.5 → same synergy.
	var big2 := _make_reader([
		_make_instance(20, "s", [Vector2i(4, 4), Vector2i(5, 4), Vector2i(4, 5), Vector2i(5, 5)], [Vector2i(4, 6)]),
		_make_instance(21, "s", [Vector2i(6, 4)], [Vector2i(6, 5)]),
		_make_instance(22, "s", [Vector2i(6, 5)], [Vector2i(6, 6)]),
		_make_instance(23, "s", [Vector2i(3, 4)], [Vector2i(3, 5)]),
		_make_instance(24, "s", [Vector2i(3, 5)], [Vector2i(3, 6)]),
	])
	var big2_row: Dictionary = _evaluate(big2, catalog)[20]
	var small2 := _make_reader([
		_make_instance(30, "s", [Vector2i(10, 10)], [Vector2i(10, 11)]),
		_make_instance(31, "s", [Vector2i(11, 10)], [Vector2i(11, 11)]),
		_make_instance(32, "s", [Vector2i(10, 11)], [Vector2i(10, 12)]),
	])
	var small2_row: Dictionary = _evaluate(small2, catalog)[30]

	_check(_almost_eq(big2_row["zone_synergy"], 0.6988, TOL), "AC4b edge 2×2 (4/8 → r=0.5): zone_synergy ≈ 0.699 (got %.6f)" % big2_row["zone_synergy"])
	_check(_almost_eq(small2_row["zone_synergy"], 0.6988, TOL), "AC4b edge 1×1 (2/4 → r=0.5): zone_synergy ≈ 0.699 (got %.6f)" % small2_row["zone_synergy"])
	_check(abs(big2_row["zone_synergy"] - small2_row["zone_synergy"]) < TOL, "AC4b edge: 2×2(4/8) and 1×1(2/4) produce IDENTICAL synergy")


# === AC5: 邻居去重 + N_max ===

func _test_ac5_neighbor_dedup_and_n_max() -> void:
	print("\n[AC5] 2×2 A + 1×2 B sharing 2 edges: B counted ONCE, N_max_A = 8")

	var catalog := _make_catalog([
		_make_def("s", ["strength"], [{"tag": "comfort", "magnitude": 0.5}]),
	])

	# 2×2 A at (0,0)-(1,1); B is a horizontal 1×2 at (2,0)-(2,1) sharing TWO
	# separate edges with A (against A's cells (1,0) and (1,1)). B must count
	# exactly once → r = 1/8 = 0.125 → ≈0.259. (Counting per shared edge
	# would give 2/8 = 0.25 → ≈0.451 — the value pins the dedup.)
	var reader := _make_reader([
		_make_instance(1, "s", [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)], [Vector2i(0, 2)]),
		_make_instance(2, "s", [Vector2i(2, 0), Vector2i(2, 1)], [Vector2i(2, 2)]),
	])
	var row: Dictionary = _evaluate(reader, catalog)[1]
	_check(_almost_eq(row["zone_synergy"], 0.2592, TOL), "AC5: B sharing 2 edges counted once → r=1/8 → ≈0.259 (got %.6f)" % row["zone_synergy"])
	# Exact pin of N_max_A = 8: r must be n_same/8, not n_same/4.
	_check(_almost_eq(row["zone_synergy"], 1.0 - exp(-2.4 * 1.0 / 8.0), 1e-9), "AC5: synergy equals S_max × (1 − e^(−k × 1/8)) — N_max_A = 8 exactly (the 2×2 perimeter cell count)")

	# QA edge: TWO separate 1×2 neighbors, each sharing 2 edges with the 2×2 —
	# each counted once → n_same=2, N_max=8 → r=0.25 → ≈0.451.
	var reader2 := _make_reader([
		_make_instance(10, "s", [Vector2i(4, 4), Vector2i(5, 4), Vector2i(4, 5), Vector2i(5, 5)], [Vector2i(4, 6)]),
		_make_instance(11, "s", [Vector2i(6, 4), Vector2i(6, 5)], [Vector2i(6, 6)]),
		_make_instance(12, "s", [Vector2i(3, 4), Vector2i(3, 5)], [Vector2i(3, 6)]),
	])
	var row2: Dictionary = _evaluate(reader2, catalog)[10]
	_check(_almost_eq(row2["zone_synergy"], 0.4512, TOL), "AC5 edge: two 1×2 neighbors (2 shared edges each) counted once each → r=2/8=0.25 → ≈0.451 (got %.6f)" % row2["zone_synergy"])


# === AC9: 多区 OR 匹配 ===

func _test_ac9_multi_zone_or_match() -> void:
	print("\n[AC9] multi-zone OR-match: A=[Strength,Cardio] adjacent B=[Cardio,Social] counts via shared Cardio")

	var catalog := _make_catalog([
		_make_def("combo_ac", ["strength", "cardio"], [{"tag": "comfort", "magnitude": 0.5}]),
		_make_def("combo_cs", ["cardio", "social"], [{"tag": "comfort", "magnitude": 0.5}]),
		_make_def("cardio", ["cardio"], [{"tag": "comfort", "magnitude": 0.5}]),
		_make_def("strength", ["strength"], [{"tag": "comfort", "magnitude": 0.5}]),
	])

	# A=[Strength,Cardio] at (0,0), B=[Cardio,Social] at (1,0): adjacent and
	# share "cardio" → both count each other (r=1/4 → ≈0.451).
	var reader := _make_reader([
		_make_instance(1, "combo_ac", [Vector2i(0, 0)], [Vector2i(0, 1)]),
		_make_instance(2, "combo_cs", [Vector2i(1, 0)], [Vector2i(1, 1)]),
	])
	var result := _evaluate(reader, catalog)
	_check(_almost_eq(result[1]["zone_synergy"], 0.4512, TOL), "AC9: A=[Strength,Cardio] counts B=[Cardio,Social] (share Cardio) → ≈0.451 (got %.6f)" % result[1]["zone_synergy"])
	_check(_almost_eq(result[2]["zone_synergy"], 0.4512, TOL), "AC9: B=[Cardio,Social] counts A=[Strength,Cardio] (share Cardio) → ≈0.451 (got %.6f)" % result[2]["zone_synergy"])

	# QA edge 1: A=[Strength,Cardio] vs B=[Cardio] — share Cardio → count.
	var reader_edge1 := _make_reader([
		_make_instance(10, "combo_ac", [Vector2i(5, 5)], [Vector2i(5, 6)]),
		_make_instance(11, "cardio", [Vector2i(6, 5)], [Vector2i(6, 6)]),
	])
	var result_edge1 := _evaluate(reader_edge1, catalog)
	_check(result_edge1[10]["zone_synergy"] > 0.0, "AC9 edge: A=[Strength,Cardio] vs B=[Cardio] — OR-match counts (synergy > 0)")
	_check(result_edge1[11]["zone_synergy"] > 0.0, "AC9 edge: B=[Cardio] vs A=[Strength,Cardio] — OR-match counts (synergy > 0)")

	# QA edge 2: A=[Strength] vs B=[Cardio,Social] — no shared zone → no count.
	var reader_edge2 := _make_reader([
		_make_instance(20, "strength", [Vector2i(0, 0)], [Vector2i(0, 1)]),
		_make_instance(21, "combo_cs", [Vector2i(1, 0)], [Vector2i(1, 1)]),
	])
	var result_edge2 := _evaluate(reader_edge2, catalog)
	_check(result_edge2[20]["zone_synergy"] == 0.0, "AC9 edge: A=[Strength] vs B=[Cardio,Social] — no shared zone → 0.0")
	_check(result_edge2[21]["zone_synergy"] == 0.0, "AC9 edge: B=[Cardio,Social] vs A=[Strength] — no shared zone → 0.0")


# === AC10: 跨区中性 ===

func _test_ac10_cross_zone_neutral() -> void:
	print("\n[AC10] cross-zone adjacency is neutral: contributes 0, never negative")

	var catalog := _make_catalog([
		_make_def("strength", ["strength"], [{"tag": "comfort", "magnitude": 0.5}]),
		_make_def("cardio", ["cardio"], [{"tag": "comfort", "magnitude": 0.5}]),
		_make_def("social", ["social"], [{"tag": "comfort", "magnitude": 0.5}]),
	])

	# A=[Strength] at (0,0) adjacent to B=[Social] at (1,0) — no shared zone.
	var reader := _make_reader([
		_make_instance(1, "strength", [Vector2i(0, 0)], [Vector2i(0, 1)]),
		_make_instance(2, "social", [Vector2i(1, 0)], [Vector2i(1, 1)]),
	])
	var result := _evaluate(reader, catalog)
	_check(result[1]["zone_synergy"] == 0.0, "AC10: A=[Strength] adjacent B=[Social] — A does not count B (0.0)")
	_check(result[2]["zone_synergy"] == 0.0, "AC10: B=[Social] adjacent A=[Strength] — B does not count A (0.0)")
	_check(result[1]["zone_synergy"] >= 0.0 and result[2]["zone_synergy"] >= 0.0, "AC10: the cross-zone pair contributes 0 — never negative")

	# QA edge: many cross-zone pairs — three zones in a row, every adjacency
	# cross-zone, all neutral.
	var reader2 := _make_reader([
		_make_instance(10, "strength", [Vector2i(0, 0)], [Vector2i(0, 1)]),
		_make_instance(11, "cardio", [Vector2i(1, 0)], [Vector2i(1, 1)]),
		_make_instance(12, "social", [Vector2i(2, 0)], [Vector2i(2, 1)]),
	])
	var result2 := _evaluate(reader2, catalog)
	var all_zero := true
	for row in result2.values():
		if float(row["zone_synergy"]) != 0.0:
			all_zero = false
	_check(all_zero, "AC10 edge: three adjacent cross-zone instances — ALL zone_synergy == 0.0 (mixing zones is never punished)")


# === Core Rule 5: 空 zone_membership ===

func _test_core_rule5_empty_zone_membership_never_earns() -> void:
	print("\n[Core Rule 5] equipment with empty zone_membership never earns zone_synergy")

	var catalog := _make_catalog([
		_make_def("zoned", ["strength"], [{"tag": "comfort", "magnitude": 0.5}]),
		_make_def("unzoned", [], [{"tag": "comfort", "magnitude": 0.5}]),
	])

	# An unzoned piece adjacent to a zoned piece: the unzoned piece earns 0
	# for itself, and (with no zones to share) is NOT counted by its zoned
	# neighbor either.
	var reader := _make_reader([
		_make_instance(1, "unzoned", [Vector2i(0, 0)], [Vector2i(0, 1)]),
		_make_instance(2, "zoned", [Vector2i(1, 0)], [Vector2i(1, 1)]),
	])
	var result := _evaluate(reader, catalog)
	_check(result[1]["zone_synergy"] == 0.0, "empty zone_membership piece earns zone_synergy 0.0 (never earns synergy)")
	_check(result[2]["zone_synergy"] == 0.0, "the zoned neighbor does not count the empty-membership piece (n_same unaffected)")
	_check(result[2]["total"] == result[2]["comfort"], "zoned neighbor total == its comfort (no synergy earned from the unzoned neighbor)")

	# Two unzoned pieces adjacent: both 0 (empty membership never shares).
	var reader2 := _make_reader([
		_make_instance(10, "unzoned", [Vector2i(0, 0)], [Vector2i(0, 1)]),
		_make_instance(11, "unzoned", [Vector2i(1, 0)], [Vector2i(1, 1)]),
	])
	var result2 := _evaluate(reader2, catalog)
	_check(result2[10]["zone_synergy"] == 0.0 and result2[11]["zone_synergy"] == 0.0, "unzoned-unzoned adjacency: both earn 0.0")


# === Config seam ===

func _test_config_override_seam() -> void:
	print("\n[config seam] optional S_max / k overrides (data-driven tuning, ECON-001 pattern)")

	var catalog := _make_catalog([
		_make_def("s", ["strength"], [{"tag": "comfort", "magnitude": 0.5}]),
	])
	# A fully surrounded 1×1: default S_max=1.0 → ≈0.909.
	var reader := _make_reader([
		_make_instance(1, "s", [Vector2i(1, 1)], [Vector2i(1, 2)]),
		_make_instance(2, "s", [Vector2i(2, 1)], [Vector2i(2, 2)]),
		_make_instance(3, "s", [Vector2i(1, 2)], [Vector2i(1, 3)]),
		_make_instance(4, "s", [Vector2i(0, 1)], [Vector2i(0, 2)]),
		_make_instance(5, "s", [Vector2i(1, 0)], [Vector2i(1, 1)]),
	])
	var default_row: Dictionary = _evaluate(reader, catalog)[1]
	var capped_row: Dictionary = _evaluate_with_config(reader, catalog, {"zone_synergy_s_max": 0.5})[1]
	var slow_row: Dictionary = _evaluate_with_config(reader, catalog, {"zone_synergy_k": 1.2})[1]

	_check(_almost_eq(capped_row["zone_synergy"], 0.5 * (1.0 - exp(-2.4)), TOL), "config zone_synergy_s_max=0.5 scales the ceiling (≈0.455; got %.6f)" % capped_row["zone_synergy"])
	_check(capped_row["zone_synergy"] < 0.5, "capped ceiling is still strictly < the configured S_max")
	_check(_almost_eq(slow_row["zone_synergy"], 1.0 - exp(-1.2), TOL), "config zone_synergy_k=1.2 halves the exponent (≈0.699; got %.6f)" % slow_row["zone_synergy"])
	_check(default_row["zone_synergy"] > capped_row["zone_synergy"], "absent config keys fall back to the GDD anchors (default ≈0.909 > capped ≈0.455)")
