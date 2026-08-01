# tests/unit/grid_system/grid_system_guardrail_test.gd
# Story 008: Signals, Integration, and Performance
# Covers the negative boundary ACs — the "不归 GridSystem 管" guardrails:
#   - AC-X.4  (SelectionSystem only sees pure int ids — GridSystem never
#              resolves/validates what an occupant_id maps to)
#   - AC-NEG.1 (access contention never makes is_solid true)
#   - AC-NEG.2 (NO public API surface leaks reachability information —
#              enumerated exhaustively across the 8 surfaces)
#
# AC-NEG.2's "commit succeeds normally, no push_error()" and "clear succeeds
# normally" literal push_error-free clauses are verified via the subprocess
# probe grid_guardrail_error_probe.gd (see _test_ac_neg_2_commit_clear_probe)
# — GDScript has no in-process push_error capture, same subprocess-isolation
# pattern as Story 003/005/006.
# Run standalone: godot --headless --script tests/unit/grid_system/grid_system_guardrail_test.gd
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"

# Rotation values mirror GridSystem.Rotation (degree-valued).
const R0 := 0

# Subprocess probe path — keep in sync with grid_guardrail_error_probe.gd.
const PROBE_SCRIPT_PATH := "res://tests/unit/grid_system/grid_guardrail_error_probe.gd"

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
	print("  UNIT TEST: GridSystem — Negative Guardrails (Story 008)")
	print("=".repeat(48))

	_test_ac_x_4_pure_int_ids()
	_test_ac_x_4_id_zero()
	_test_ac_x_4_cleared_id()
	_test_ac_neg_1_shared_access_not_solid()
	_test_ac_neg_1_three_sharers()
	_test_ac_neg_1_five_sharers()
	_test_ac_neg_2_can_place()
	_test_ac_neg_2_is_solid()
	_test_ac_neg_2_get_occupant_id()
	_test_ac_neg_2_get_access_cells()
	_test_ac_neg_2_snapshots()
	_test_ac_neg_2_serialize()
	_test_ac_neg_2_commit_clear_probe()

	print("\n=== GRID SYSTEM GUARDRAIL TEST: %d passed, %d failed ===\n" % [_pass, _fail])
	return {"pass": _pass, "fail": _fail}


func _check(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
		print("  PASS: " + msg)
	else:
		_fail += 1
		print("  FAIL: " + msg)


# === Helpers ===

func _make_grid(width: int, height: int) -> RefCounted:
	var GS: Script = load("res://src/systems/grid_system.gd") as Script
	var gs: RefCounted = GS.new()
	gs.call("init", width, height)
	return gs


## Makes every cell buildable.
func _make_open_grid(width: int, height: int) -> RefCounted:
	var gs := _make_grid(width, height)
	for y in height:
		for x in width:
			gs.call("set_buildable", Vector2i(x, y), true)
	gs.call("freeze_buildable")
	return gs


func _commit(gs: RefCounted, id: int, fp: Array[Vector2i], ac: Array[Vector2i], rot: int) -> void:
	gs.call("commit", id, fp, ac, rot)


func _clear(gs: RefCounted, id: int) -> void:
	gs.call("clear", id)


## Builds the AC-NEG.2 fixture: an 8-cell ring of single-cell equipment
## footprints surrounds cell (3,3); target equipment T has footprint at
## (5,5) and its ONLY access cell at (3,3) — completely surrounded by
## other footprints, hence unreachable by any path.
func _build_surrounded_fixture() -> RefCounted:
	var gs := _make_open_grid(13, 10)
	# Ring of 8 single-cell footprints around (3,3).
	var ring: Array[Vector2i] = [
		Vector2i(2, 2), Vector2i(3, 2), Vector2i(4, 2),
		Vector2i(2, 3), Vector2i(4, 3),
		Vector2i(2, 4), Vector2i(3, 4), Vector2i(4, 4),
	]
	for i in ring.size():
		_commit(gs, 100 + i, [ring[i]], [], R0)
	# Target T: footprint at (5,5), access cell (3,3) — fully enclosed.
	_commit(gs, 7, [Vector2i(5, 5)], [Vector2i(3, 3)], R0)
	return gs


## Runs grid_guardrail_error_probe.gd in an ISOLATED subprocess (same
## pattern as Story 005/006 probes). The probe builds the surrounded
## fixture and commits/clears the unreachable equipment; if GridSystem
## wrongly added reachability logic that push_errors, "ERROR:" appears in
## the merged output and this assertion fails.
func _run_probe(mode: String) -> Dictionary:
	var exe := OS.get_executable_path()
	var project_root := ProjectSettings.globalize_path("res://")
	var probe_path := ProjectSettings.globalize_path(PROBE_SCRIPT_PATH)

	var args: Array[String] = ["--headless", "--path", project_root, "--script", probe_path, "--", mode]

	var output: Array = []
	var exit_code := OS.execute(exe, args, output, true)
	var output_text: String = "".join(output)

	return {"errored": output_text.find("ERROR:") != -1, "output": output_text, "exit_code": exit_code}


# === AC-X.4: SelectionSystem 只拿整数 id —— 负向 ===

func _test_ac_x_4_pure_int_ids() -> void:
	print("\n[AC-X.4] get_occupant_id() returns a pure int — GridSystem does not resolve EquipmentInstance")
	print("  fixture: commit(id=7, fp=[(2,2)], ac=[(2,3)])")

	var gs := _make_open_grid(10, 10)
	_commit(gs, 7, [Vector2i(2, 2)], [Vector2i(2, 3)], R0)

	var occ: Variant = gs.call("get_occupant_id", Vector2i(2, 2))
	_check(
		typeof(occ) == TYPE_INT,
		"get_occupant_id((2,2)) is TYPE_INT (got %s)" % type_string(typeof(occ))
	)
	_check(occ == 7, "get_occupant_id((2,2)) == 7")
	_check(
		not (occ is Object) and not (occ is RefCounted),
		"return value is NOT an Object — no EquipmentInstance wrapper"
	)


func _test_ac_x_4_id_zero() -> void:
	print("\n[AC-X.4 edge] id=0 (first piece) returns pure int 0 — not falsey, not an object")

	var gs := _make_open_grid(10, 10)
	_commit(gs, 0, [Vector2i(1, 1)], [Vector2i(1, 2)], R0)

	var occ: Variant = gs.call("get_occupant_id", Vector2i(1, 1))
	_check(typeof(occ) == TYPE_INT, "get_occupant_id((1,1)) is TYPE_INT (got %s)" % type_string(typeof(occ)))
	_check(occ == 0, "get_occupant_id((1,1)) == 0 — legal first-piece id")


func _test_ac_x_4_cleared_id() -> void:
	print("\n[AC-X.4 edge] cleared id returns plain -1 — same int sentinel as any empty cell")

	var gs := _make_open_grid(10, 10)
	_commit(gs, 7, [Vector2i(2, 2)], [Vector2i(2, 3)], R0)
	_clear(gs, 7)

	var occ: Variant = gs.call("get_occupant_id", Vector2i(2, 2))
	_check(typeof(occ) == TYPE_INT, "after clear: get_occupant_id is TYPE_INT (got %s)" % type_string(typeof(occ)))
	_check(occ == -1, "after clear: get_occupant_id((2,2)) == -1 — plain empty sentinel, no special marker")


# === AC-NEG.1: access 争用不改变 solidity ===

func _test_ac_neg_1_shared_access_not_solid() -> void:
	print("\n[AC-NEG.1] two ids share access cell (1,3) — is_solid stays false")

	var gs := _make_open_grid(10, 10)
	_commit(gs, 1, [Vector2i(1, 1)], [Vector2i(1, 3)], R0)
	_commit(gs, 2, [Vector2i(4, 4)], [Vector2i(1, 3)], R0)

	_check(
		(gs.call("get_access_ids", Vector2i(1, 3)) as Array) == [1, 2],
		"shared access cell (1,3) holds BOTH ids [1,2]"
	)
	_check(
		gs.call("is_solid", Vector2i(1, 3)) == false,
		"is_solid(shared access cell) == false — contention did NOT make it solid"
	)


func _test_ac_neg_1_three_sharers() -> void:
	print("\n[AC-NEG.1 edge] 3 ids share access cell — still non-solid")

	var gs := _make_open_grid(10, 10)
	for id in [1, 2, 3]:
		_commit(gs, id, [Vector2i(id, 1)], [Vector2i(5, 5)], R0)
	_check(
		(gs.call("get_access_ids", Vector2i(5, 5)) as Array).size() == 3,
		"3 ids registered on shared access cell"
	)
	_check(gs.call("is_solid", Vector2i(5, 5)) == false, "is_solid == false with 3 sharers")


func _test_ac_neg_1_five_sharers() -> void:
	print("\n[AC-NEG.1 edge] 5 ids share access cell — still non-solid")

	var gs := _make_open_grid(10, 10)
	for id in [1, 2, 3, 4, 5]:
		_commit(gs, id, [Vector2i(id, 1)], [Vector2i(6, 6)], R0)
	_check(
		(gs.call("get_access_ids", Vector2i(6, 6)) as Array).size() == 5,
		"5 ids registered on shared access cell"
	)
	_check(gs.call("is_solid", Vector2i(6, 6)) == false, "is_solid == false with 5 sharers")


# === AC-NEG.2: 可达性信息不出现在任何公开 API ===
#
# Fixture: target equipment T's ONLY access cell (3,3) is surrounded by an
# 8-cell ring of other equipment footprints → unreachable. Each test below
# exercises one public API surface and asserts no reachability leak.

func _test_ac_neg_2_can_place() -> void:
	print("\n[AC-NEG.2] can_place() — valid placement whose access would be unreachable returns valid:true")

	var gs := _build_surrounded_fixture()

	# A NEW piece whose access cell would also sit inside the ring.
	# can_place() takes CANONICAL (0-degree, min-offset (0,0)) cells plus an
	# anchor — the anchor convention (AC-D5.2) is enforced by a debug assert
	# in declared_bounds(), so canonical cells must be (0,0)-based and the
	# placement location goes in the anchor parameter.
	# NOTE: arrays must be TYPED (Array[Vector2i]) — gs.call() passes them
	# as Variants and Godot's typed-array parameter boundary rejects untyped
	# literals with a SCRIPT ERROR (same caveat as the Story 005 probe).
	var new_fp: Array[Vector2i] = [Vector2i(0, 0)]
	var new_ac: Array[Vector2i] = [Vector2i(0, 1)]
	var result: RefCounted = gs.call("can_place", new_fp, new_ac, Vector2i(6, 6), R0)
	_check(result.valid == true, "can_place returns valid=true — no FAIL for 'placement would be unusable'")
	_check(result.fail_code == 0, "fail_code == VALID (0)")
	# Guardrail: the result DTO must not have gained a warning field.
	_check(
		not result.has_method("get_warning") and result.get("warning") == null,
		"PlacementCheckResult has no warning field (result.get('warning') is null)"
	)
	# The full 8 surfaces must remain free of reachability even when the
	# placement's access is enclosed: can_place with footprint on empty
	# ground (3,0) and access at (3,3) — the enclosed ring center — stays
	# valid. Canonical cells are (0,0)-based; anchor (3,0) places fp at
	# (3,0) and ac at (3,3).
	var new2_fp: Array[Vector2i] = [Vector2i(0, 0)]
	var new2_ac: Array[Vector2i] = [Vector2i(0, 3)]
	var result2: RefCounted = gs.call("can_place", new2_fp, new2_ac, Vector2i(3, 0), R0)
	_check(result2.valid == true, "can_place with access in the ring still valid")


func _test_ac_neg_2_is_solid() -> void:
	print("\n[AC-NEG.2] is_solid() — determined ONLY by !buildable OR occupant_id != -1")

	var gs := _build_surrounded_fixture()

	_check(
		gs.call("is_solid", Vector2i(3, 3)) == false,
		"is_solid(access cell (3,3)) == false — buildable=true, occupant=-1, reachability irrelevant"
	)
	_check(
		gs.call("is_solid", Vector2i(2, 2)) == true,
		"is_solid(ring footprint (2,2)) == true — occupied by id 100"
	)
	_check(
		gs.call("is_solid", Vector2i(5, 5)) == true,
		"is_solid(T's footprint (5,5)) == true — occupied by id 7"
	)


func _test_ac_neg_2_get_occupant_id() -> void:
	print("\n[AC-NEG.2] get_occupant_id() — returns int, no 'unreachable' sentinel")

	var gs := _build_surrounded_fixture()

	var acc: Variant = gs.call("get_occupant_id", Vector2i(3, 3))
	_check(typeof(acc) == TYPE_INT and acc == -1, "get_occupant_id((3,3)) == -1 — same int sentinel as any empty cell")
	var ring: Variant = gs.call("get_occupant_id", Vector2i(2, 2))
	_check(typeof(ring) == TYPE_INT and ring == 100, "get_occupant_id((2,2)) == 100 (int)")


func _test_ac_neg_2_get_access_cells() -> void:
	print("\n[AC-NEG.2] get_access_cells() — returns ALL statically-owned access cells, no unreachable filtering")

	var gs := _build_surrounded_fixture()

	var cells: Array = gs.call("get_access_cells", 7)
	_check(
		cells == [Vector2i(3, 3)],
		"get_access_cells(7) returns the enclosed access cell (3,3) — NOT filtered out"
	)
	_check((cells as Array).size() == 1, "exactly 1 access cell returned")


func _test_ac_neg_2_snapshots() -> void:
	print("\n[AC-NEG.2] get_snapshot() / get_speculative_snapshot() — structures contain no reachability fields")

	var gs := _build_surrounded_fixture()

	var snap: RefCounted = gs.call("get_snapshot")
	_check(
		snap.call("get_access_cells", 7) == [Vector2i(3, 3)],
		"snapshot.get_access_cells(7) returns enclosed cell unfiltered"
	)
	_check(
		snap.call("is_solid", Vector2i(3, 3)) == false,
		"snapshot.is_solid((3,3)) == false — reachability not baked into snapshot reads"
	)
	# Snapshot structure is the GridStateReader contract only — enumerate
	# its public surface for any reachability-shaped member.
	var snap_surface: Array = snap.get_method_list()
	var has_reachability_method := false
	for m in snap_surface:
		if String(m["name"]).find("reach") != -1 or String(m["name"]).find("reachable") != -1:
			has_reachability_method = true
	_check(
		not has_reachability_method,
		"GridSnapshot exposes no reachability-named method"
	)

	# Speculative snapshot over the same grid: deltas that add a piece whose
	# access is enclosed — still no reachability surface. Access cell (3,3)
	# is the enclosed-but-empty ring center (legal access-on-access with
	# id 7's access cell — AC-C5.2), NOT a footprint, so the non-solid
	# assertion below is meaningful.
	var empty_cells: Array[Vector2i] = []
	var add_fp: Array[Vector2i] = [Vector2i(8, 8)]
	var add_ac: Array[Vector2i] = [Vector2i(3, 3)]
	var add := PlacementDelta.new(false, 50, add_fp, add_ac)
	var deltas: Array[PlacementDelta] = [add]
	var spec: RefCounted = gs.call("get_speculative_snapshot", deltas)
	_check(
		spec.call("get_access_cells", 50) == [Vector2i(3, 3)],
		"speculative snapshot: enclosed new access cell returned unfiltered"
	)
	_check(
		spec.call("is_solid", Vector2i(3, 3)) == false,
		"speculative snapshot: enclosed access cell non-solid — no reachability logic"
	)


func _test_ac_neg_2_serialize() -> void:
	print("\n[AC-NEG.2] serialize() — PlacementRecord output contains no reachability fields")

	var gs := _build_surrounded_fixture()

	var data: Dictionary = gs.call("serialize")
	var records: Array = data["records"]
	var target_record: Dictionary = {}
	for rec in records:
		if int(rec["instance_id"]) == 7:
			target_record = rec
			break
	_check(not target_record.is_empty(), "serialize() output contains record for id 7")
	_check(
		target_record.has("instance_id") and target_record.has("footprint_cells")
		and target_record.has("access_cells") and target_record.has("rotation"),
		"record has exactly the placement fields (instance_id/footprint/access/rotation)"
	)
	_check(
		target_record.size() == 4,
		"record has NO extra keys (size == 4) — no reachability field leaked into the save"
	)
	_check(
		target_record["access_cells"] == [[3, 3]],
		"serialized access_cells == [[3,3]] — enclosed cell present, unfiltered"
	)


func _test_ac_neg_2_commit_clear_probe() -> void:
	print("\n[AC-NEG.2] commit()/clear() on unreachable equipment — succeeds with NO push_error (subprocess probe)")

	var r := _run_probe("surrounded_commit_clear")
	_check(
		r["errored"] == false and r["exit_code"] == 0,
		"commit+clear of unreachable equipment: clean exit 0, zero ERROR lines (got errored=%s, exit=%d)" % [r["errored"], r["exit_code"]]
	)
	if r["errored"] or r["exit_code"] != 0:
		print("      probe output: %s" % r["output"])
