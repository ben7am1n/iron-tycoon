# tests/integration/save_load/load_orchestration_test.gd
# Story SL-002: Load Orchestration — Phase A/B and Load Order
# (production/epics/save-load/story-002-load-orchestration-phase-ab.md)
#
# Covers the BLOCKING ACs:
#   - AC3  all-or-nothing: any Phase A validation failure -> load() returns
#         ok=false with errors AND the session is left completely unmutated
#         (tick_count, grid occupancy, member count, balance — all unchanged);
#         a failure in a later system never leaves earlier systems committed
#   - AC4  load order enforced programmatically: spy on every system's
#         deserialize/rebuild method, assert the Phase B commit sequence is
#         exactly [TimeSystem, GridSystem, Placement.rederive,
#         Selection.rebuild, Navigation.rebuild, MemberSim, Congestion,
#         Satisfaction, Economy]; a reorder in load() fails this assertion
#   - AC9  member referencing an equipment_instance_id absent from the
#         validated grid -> the whole load fails, no silent orphan, no
#         partial load
# plus the QA edge cases: corrupt grid data, TimeSystem abort-before-grid,
# GridSystem abort-before-member, economy-only failure (commit never reached),
# buildable mismatch (LEVEL_GEOMETRY_MISMATCH), zero-member MemberSim, Phase B
# FATAL path (injected commit failure -> fatal-to-menu), blob key gate.
#
# STUB PLAN (story QA): MemberSim/Congestion/Satisfaction/Economy are the
# real Core-layer integration stubs from src/systems/ (member_sim.gd etc.).
# PlacementSystem/SelectionSystem/Navigation do NOT exist in src/ yet, so the
# test injects derivation spy stubs for them (same pattern as SL-001's
# SerializeSpy) so the full 9-step load order is observable.
#
# Run standalone: godot --headless --script tests/integration/save_load/load_orchestration_test.gd
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"

const GRID_W := 4
const GRID_H := 4

# The documented Phase B (commit) sequence — TR-SL-003 / GDD Core Rule 3.
# AC4 asserts the recorded spy sequence equals this EXACTLY; if load() is ever
# reordered, this assertion fails.
const EXPECTED_COMMIT_SEQUENCE := [
	"TimeSystem.deserialize:commit",
	"GridSystem.deserialize:commit",
	"PlacementSystem.rederive_counter",
	"SelectionSystem.rebuild_mapping",
	"Navigation.rebuild",
	"MemberSim.deserialize:commit",
	"Congestion.deserialize:commit",
	"Satisfaction.deserialize:commit",
	"Economy.deserialize:commit",
]

# The Phase A (validate) sequence — same order, validate-only mode.
const EXPECTED_VALIDATE_SEQUENCE := [
	"TimeSystem.deserialize:validate",
	"GridSystem.deserialize:validate",
	"MemberSim.deserialize:validate",
	"Congestion.deserialize:validate",
	"Satisfaction.deserialize:validate",
	"Economy.deserialize:validate",
]


# === Test spies ===
# Each spy records its call into a shared log array, then delegates to super.
# (Return types match the parent signatures — GDScript 4.7.1 rejects an
# override whose signature differs from the parent.)

class TimeSpy:
	extends TimeSystem

	var call_log: Array = []

	func deserialize(data: Dictionary, validate_only: bool = false) -> TimeSystemDeserializeResult:
		call_log.append("TimeSystem.deserialize:" + ("validate" if validate_only else "commit"))
		return super.deserialize(data, validate_only)


class GridSpy:
	extends GridSystem

	var call_log: Array = []

	func deserialize(data: Dictionary, buildable_snapshot: PackedByteArray, mode: String) -> DeserializeResult:
		call_log.append("GridSystem.deserialize:" + mode)
		return super.deserialize(data, buildable_snapshot, mode)


class MemberSpy:
	extends MemberSim

	var call_log: Array = []

	func deserialize(data: Dictionary, validate_only: bool = false, known_instance_ids: Array = []) -> StubDeserializeResult:
		call_log.append("MemberSim.deserialize:" + ("validate" if validate_only else "commit"))
		return super.deserialize(data, validate_only, known_instance_ids)


class CongSpy:
	extends Congestion

	var call_log: Array = []

	func deserialize(data: Dictionary, validate_only: bool = false) -> StubDeserializeResult:
		call_log.append("Congestion.deserialize:" + ("validate" if validate_only else "commit"))
		return super.deserialize(data, validate_only)


class SatSpy:
	extends Satisfaction

	var call_log: Array = []

	func deserialize(data: Dictionary, validate_only: bool = false) -> StubDeserializeResult:
		call_log.append("Satisfaction.deserialize:" + ("validate" if validate_only else "commit"))
		return super.deserialize(data, validate_only)


class EcoSpy:
	extends Economy

	var call_log: Array = []

	func deserialize(data: Dictionary, validate_only: bool = false) -> StubDeserializeResult:
		call_log.append("Economy.deserialize:" + ("validate" if validate_only else "commit"))
		return super.deserialize(data, validate_only)


## Derivation spies — PlacementSystem/SelectionSystem/Navigation do not exist
## in src/ yet, so the test injects these stand-ins so the load order is
## observable (AC4). They record the call and do nothing else.
class PlacementSpy:
	extends RefCounted

	var call_log: Array = []

	func rederive_counter() -> void:
		call_log.append("PlacementSystem.rederive_counter")


class SelectionSpy:
	extends RefCounted

	var call_log: Array = []

	func rebuild_mapping() -> void:
		call_log.append("SelectionSystem.rebuild_mapping")


class NavigationSpy:
	extends RefCounted

	var call_log: Array = []

	func rebuild(grid) -> void:
		call_log.append("Navigation.rebuild")


## Economy stub variant whose Phase A (validate-only) passes but Phase B
## (commit) fails — used to exercise the FATAL path (should be impossible
## after a clean Phase A; the story says treat it as fatal-to-menu).
class FailOnCommitEco:
	extends Economy

	var fail_commit: bool = false

	func deserialize(data: Dictionary, validate_only: bool = false) -> StubDeserializeResult:
		if validate_only:
			return super.deserialize(data, true)
		if fail_commit:
			return StubDeserializeResult.fail("Economy: injected commit failure")
		return super.deserialize(data, false)


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
	print("  INTEGRATION TEST: SaveLoad — Load Orchestration Phase A/B (Story SL-002)")
	print("=".repeat(48))

	_test_ac3_time_failure_aborts_before_grid()
	_test_ac3_grid_failure_aborts_before_member()
	_test_ac3_economy_only_failure_commit_never_reaches()
	_test_ac3_member_failure_leaves_systems_1_4_uncommitted()
	_test_ac3_buildable_mismatch_zero_mutation()
	_test_ac4_commit_order_exact()
	_test_ac4_prerequisites()
	_test_ac9_unknown_equipment_fails_whole_load()
	_test_ac9_member_id_exists_but_not_in_grid()
	_test_ac9_zero_members_passes()
	_test_valid_load_restores_state()
	_test_phase_b_fatal_to_menu()
	_test_blob_key_gate_blocks_before_systems()

	print("\n=== LOAD ORCHESTRATION TEST: %d passed, %d failed ===\n" % [_pass, _fail])
	return {"pass": _pass, "fail": _fail}


func _check(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
		print("  PASS: " + msg)
	else:
		_fail += 1
		print("  FAIL: " + msg)


# === Helpers ===

func _SRG() -> Script:
	return load("res://src/systems/seeded_rng.gd") as Script


func _SL() -> Script:
	return load("res://src/systems/save_load.gd") as Script


func _make_orchestrator() -> Node:
	var orch: Node = load("res://src/systems/simulation_orchestrator.gd").new()
	root.add_child(orch)
	orch.call("_ready")
	return orch


## Builds the SL-002 rig: real orchestrator + SeededRNG + TimeSpy + GridSpy +
## the 4 Core-layer stub systems + derivation spies + SaveLoad. Every spy
## shares the rig's call_log so AC4 can assert the exact sequence.
## [econ_override] swaps the economy slot (used by the FATAL-path test to
## inject a fail-on-commit economy) — must be passed BEFORE init so it is the
## single registered "Economy" sub-stream.
func _make_rig(master_seed: int, econ_override: RefCounted = null) -> Dictionary:
	var orch: Node = _make_orchestrator()
	var srg: RefCounted = _SRG().new()
	srg.call("init", master_seed)

	var ts: RefCounted = TimeSpy.new()
	ts.call("init", orch, srg)
	orch.set("time_system", ts)

	var gs: RefCounted = GridSpy.new()
	gs.call("init", GRID_W, GRID_H)
	for y in GRID_H:
		for x in GRID_W:
			gs.call("set_buildable", Vector2i(x, y), true)
	gs.call("freeze_buildable")
	orch.set("grid_system", gs)

	var member: RefCounted = MemberSpy.new()
	member.call("init", orch, srg)
	orch.set("member_sim", member)

	var cong: RefCounted = CongSpy.new()
	cong.call("init", orch, srg)
	orch.set("congestion", cong)

	var sat: RefCounted = SatSpy.new()
	sat.call("init", orch, srg)
	orch.set("satisfaction", sat)

	var econ: RefCounted = econ_override if econ_override != null else EcoSpy.new()
	econ.call("init", orch, srg)
	orch.set("economy", econ)

	var placement: RefCounted = PlacementSpy.new()
	orch.set("placement_system", placement)
	var selection: RefCounted = SelectionSpy.new()
	orch.set("selection_system", selection)
	var navigation: RefCounted = NavigationSpy.new()
	orch.set("navigation", navigation)

	var sl: RefCounted = _SL().new()
	sl.call("init", orch)
	sl.call("_post_init")

	var rig := {
		"orchestrator": orch,
		"seeded_rng": srg,
		"time_system": ts,
		"grid_system": gs,
		"member_sim": member,
		"congestion": cong,
		"satisfaction": sat,
		"economy": econ,
		"placement": placement,
		"selection": selection,
		"navigation": navigation,
		"save_load": sl,
		"log": [],
	}
	for spy in [ts, gs, member, cong, sat, econ, placement, selection, navigation]:
		if "call_log" in spy:
			spy.set("call_log", rig["log"])
	return rig


## The all-open buildable snapshot matching the 4x4 rig grid (all cells 1).
func _open_snapshot() -> PackedByteArray:
	var snap := PackedByteArray()
	snap.resize(GRID_W * GRID_H)
	snap.fill(1)
	return snap


## Commits two pieces of equipment into the rig grid: instance ids 1 and 2.
## GridSystem.commit expects TYPED Array[Vector2i] params — a plain Array
## literal passed via call() is rejected ("does not have the same element
## type as the expected typed array argument"), so build typed arrays.
func _commit_equipment(rig: Dictionary) -> void:
	var fp1: Array[Vector2i] = [Vector2i(0, 0)]
	var ac1: Array[Vector2i] = [Vector2i(1, 0)]
	var fp2: Array[Vector2i] = [Vector2i(2, 0)]
	var ac2: Array[Vector2i] = [Vector2i(3, 0)]
	rig["grid_system"].call("commit", 1, fp1, ac1, 0)
	rig["grid_system"].call("commit", 2, fp2, ac2, 0)


## Sets a realistic pre-load session state on the rig: some ticks, grid
## equipment (ids 1,2), two members referencing them, congestion/satisfaction
## counters, and an economy balance.
func _set_preload_state(rig: Dictionary) -> void:
	rig["time_system"].call("resume")
	for i in 3:
		rig["time_system"].call("process", 0.1)  # tick_count -> 3
	rig["time_system"].call("pause")
	_commit_equipment(rig)
	rig["member_sim"].set("members", [
		{"member_id": 10, "equipment_instance_id": 1},
		{"member_id": 11, "equipment_instance_id": 2},
	])
	rig["congestion"].set("counter", 5)
	rig["satisfaction"].set("counter", 7)
	rig["economy"].set("balance", 500)


## Full observable state snapshot of the session (all 6 coordinated systems).
func _snapshot(rig: Dictionary) -> Dictionary:
	return {
		"tick_count": int(rig["orchestrator"].call("get_tick_count")),
		"grid": rig["grid_system"].call("serialize"),
		"members": rig["member_sim"].get("members"),
		"cong_counter": int(rig["congestion"].get("counter")),
		"sat_counter": int(rig["satisfaction"].get("counter")),
		"balance": int(rig["economy"].get("balance")),
	}


func _states_equal(a: Dictionary, b: Dictionary) -> bool:
	return str(a) == str(b)


## Deep-copies the blob and corrupts one payload sub-dict via the mutator.
func _corrupt_blob(blob: Dictionary, key: String, mutator: Callable) -> Dictionary:
	var copy: Dictionary = blob.duplicate(true)
	copy[key] = (blob[key] as Dictionary).duplicate(true)
	mutator.call(copy[key])
	return copy


# === AC3: all-or-nothing, zero mutation ===

func _test_ac3_time_failure_aborts_before_grid() -> void:
	print("\n[AC3] TimeSystem Phase A failure -> abort BEFORE GridSystem is called; session untouched")
	var src := _make_rig(111)
	_set_preload_state(src)
	var blob: Dictionary = src["save_load"].call("_perform_save")

	var rig := _make_rig(222)
	_set_preload_state(rig)
	var before := _snapshot(rig)
	rig["log"].clear()

	var corrupt := _corrupt_blob(blob, "time_system", func(d: Dictionary) -> void:
		d.erase("tick_count"))
	var result: RefCounted = rig["save_load"].call("load", corrupt, _open_snapshot())

	_check(not bool(result.get("ok")), "AC3: load fails when TimeSystem validation fails")
	_check(not (result.get("errors") as Array).is_empty(), "AC3: errors non-empty")
	_check(str(result.get("errors")).find("tick_count") != -1, "AC3: error mentions missing tick_count")
	_check(not rig["log"].has("GridSystem.deserialize:validate"), "AC3: GridSystem was NEVER called (abort before grid)")
	_check(not rig["log"].has("GridSystem.deserialize:commit"), "AC3: no grid commit")
	_check(not rig["log"].has("MemberSim.deserialize:validate"), "AC3: MemberSim was never called")
	_check(_states_equal(_snapshot(rig), before), "AC3: session fully unmutated (tick/grid/members/balance)")


func _test_ac3_grid_failure_aborts_before_member() -> void:
	print("\n[AC3] GridSystem Phase A failure -> abort BEFORE MemberSim is called; session untouched")
	var src := _make_rig(333)
	_set_preload_state(src)
	var blob: Dictionary = src["save_load"].call("_perform_save")

	var rig := _make_rig(444)
	_set_preload_state(rig)
	var before := _snapshot(rig)
	rig["log"].clear()

	# Corrupt grid data: a record on a non-buildable cell -> LEVEL_GEOMETRY_MISMATCH.
	var corrupt := _corrupt_blob(blob, "grid_system", func(d: Dictionary) -> void:
		# Flip the first record's footprint to a cell that is solid in the
		# snapshot... simplest structural corruption: wrong schema version.
		d["schema_version"] = 999)
	var result: RefCounted = rig["save_load"].call("load", corrupt, _open_snapshot())

	_check(not bool(result.get("ok")), "AC3: load fails when GridSystem validation fails")
	_check(str(result.get("errors")).find("GridSystem") != -1, "AC3: errors mention GridSystem (got %s)" % str(result.get("errors")))
	_check(not rig["log"].has("MemberSim.deserialize:validate"), "AC3: MemberSim was never called (abort before member)")
	_check(not rig["log"].has("MemberSim.deserialize:commit"), "AC3: no member commit")
	_check(_states_equal(_snapshot(rig), before), "AC3: session fully unmutated")


func _test_ac3_economy_only_failure_commit_never_reaches() -> void:
	print("\n[AC3] only Economy fails Phase A -> all prior systems validate OK, but commit NEVER reaches them")
	var src := _make_rig(555)
	_set_preload_state(src)
	var blob: Dictionary = src["save_load"].call("_perform_save")

	var rig := _make_rig(666)
	_set_preload_state(rig)
	var before := _snapshot(rig)
	rig["log"].clear()

	var corrupt := _corrupt_blob(blob, "economy", func(d: Dictionary) -> void:
		d.erase("balance"))
	var result: RefCounted = rig["save_load"].call("load", corrupt, _open_snapshot())

	_check(not bool(result.get("ok")), "AC3: load fails when Economy validation fails")
	_check(str(result.get("errors")).find("Economy") != -1, "AC3: errors mention Economy (got %s)" % str(result.get("errors")))
	# All 6 systems' validate-only calls ran (TimeSystem + GridSystem gates passed).
	for entry in EXPECTED_VALIDATE_SEQUENCE:
		_check(rig["log"].has(entry), "AC3: %s ran in Phase A" % entry)
	# But ZERO commit calls — the failure aborts before Phase B.
	for entry in EXPECTED_COMMIT_SEQUENCE:
		_check(not rig["log"].has(entry), "AC3: %s NEVER committed" % entry)
	_check(_states_equal(_snapshot(rig), before), "AC3: session fully unmutated (commit never reached)")


func _test_ac3_member_failure_leaves_systems_1_4_uncommitted() -> void:
	print("\n[AC3] MemberSim (system 5) Phase A failure -> systems 1-4 are NOT partially committed")
	var src := _make_rig(777)
	_set_preload_state(src)
	var blob: Dictionary = src["save_load"].call("_perform_save")

	var rig := _make_rig(888)
	_set_preload_state(rig)
	var before := _snapshot(rig)
	rig["log"].clear()

	# Member referencing equipment_instance_id 99 (absent from the grid).
	var corrupt := _corrupt_blob(blob, "member_sim", func(d: Dictionary) -> void:
		d["members"] = [{"member_id": 42, "equipment_instance_id": 99}])
	var result: RefCounted = rig["save_load"].call("load", corrupt, _open_snapshot())

	_check(not bool(result.get("ok")), "AC3/AC9: load fails on orphan member reference")
	_check(str(result.get("errors")).find("unknown equipment_instance_id 99") != -1, "AC9: error names the unknown id (got %s)" % str(result.get("errors")))
	# No commit call of ANY kind — systems 1-4 (TimeSystem..Navigation) untouched.
	for entry in EXPECTED_COMMIT_SEQUENCE:
		_check(not rig["log"].has(entry), "AC3: %s NEVER committed (no partial state)" % entry)
	_check(_states_equal(_snapshot(rig), before), "AC3: systems 1-4 retain pre-load state")


func _test_ac3_buildable_mismatch_zero_mutation() -> void:
	print("\n[AC3] buildable_snapshot mismatch (LEVEL_GEOMETRY_MISMATCH) -> zero mutation")
	var src := _make_rig(999)
	_set_preload_state(src)
	var blob: Dictionary = src["save_load"].call("_perform_save")

	var rig := _make_rig(1000)
	_set_preload_state(rig)
	var before := _snapshot(rig)
	rig["log"].clear()

	# Snapshot with a wall where the save's equipment sits (footprint (0,0)).
	var walled := _open_snapshot()
	walled[0] = 0  # cell (0,0) non-buildable
	var result: RefCounted = rig["save_load"].call("load", blob, walled)

	_check(not bool(result.get("ok")), "AC3: load fails on buildable mismatch")
	_check(str(result.get("errors")).find("LEVEL_GEOMETRY_MISMATCH") != -1, "AC3: error is LEVEL_GEOMETRY_MISMATCH (got %s)" % str(result.get("errors")))
	_check(not rig["log"].has("MemberSim.deserialize:validate"), "AC3: aborted before MemberSim (grid gate)")
	_check(_states_equal(_snapshot(rig), before), "AC3: session fully unmutated")


# === AC4: load order enforced programmatically ===

func _test_ac4_commit_order_exact() -> void:
	print("\n[AC4] Phase B commit sequence exactly matches the documented load order")
	var src := _make_rig(1212)
	_set_preload_state(src)
	var blob: Dictionary = src["save_load"].call("_perform_save")

	var rig := _make_rig(1313)
	rig["log"].clear()
	var result: RefCounted = rig["save_load"].call("load", blob, _open_snapshot())

	_check(bool(result.get("ok")), "AC4: valid blob loads ok")
	# The full log: Phase A validates (6) then Phase B commits (6) + derivations (3).
	var full: Array = rig["log"]
	_check(full.size() == EXPECTED_VALIDATE_SEQUENCE.size() + EXPECTED_COMMIT_SEQUENCE.size(),
		"AC4: exactly %d calls recorded (got %d)" % [EXPECTED_VALIDATE_SEQUENCE.size() + EXPECTED_COMMIT_SEQUENCE.size(), full.size()])
	_check(full.slice(0, EXPECTED_VALIDATE_SEQUENCE.size()) == EXPECTED_VALIDATE_SEQUENCE,
		"AC4: Phase A validate sequence exact (got %s)" % str(full.slice(0, EXPECTED_VALIDATE_SEQUENCE.size())))
	_check(full.slice(EXPECTED_VALIDATE_SEQUENCE.size()) == EXPECTED_COMMIT_SEQUENCE,
		"AC4: Phase B commit sequence exact — REORDERING load() WOULD FAIL HERE (got %s)" % str(full.slice(EXPECTED_VALIDATE_SEQUENCE.size())))


func _test_ac4_prerequisites() -> void:
	print("\n[AC4] no dependent system executes before its prerequisite")
	var src := _make_rig(1414)
	_set_preload_state(src)
	var blob: Dictionary = src["save_load"].call("_perform_save")

	var rig := _make_rig(1515)
	rig["log"].clear()
	rig["save_load"].call("load", blob, _open_snapshot())
	var log: Array = rig["log"]

	var grid_commit_index := log.find("GridSystem.deserialize:commit")
	_check(grid_commit_index >= 0, "AC4: GridSystem commit present")
	_check(log.find("PlacementSystem.rederive_counter") > grid_commit_index, "AC4: Placement.rederive AFTER GridSystem.deserialize")
	_check(log.find("SelectionSystem.rebuild_mapping") > grid_commit_index, "AC4: Selection.rebuild AFTER GridSystem.deserialize")
	_check(log.find("Navigation.rebuild") > grid_commit_index, "AC4: Navigation.rebuild AFTER GridSystem.deserialize")
	_check(log.find("MemberSim.deserialize:commit") > log.find("Navigation.rebuild"), "AC4: MemberSim commit AFTER Navigation.rebuild")
	_check(log.find("Congestion.deserialize:commit") > log.find("MemberSim.deserialize:commit"), "AC4: Congestion AFTER MemberSim")
	_check(log.find("Satisfaction.deserialize:commit") > log.find("Congestion.deserialize:commit"), "AC4: Satisfaction AFTER Congestion")
	_check(log.find("Economy.deserialize:commit") > log.find("Satisfaction.deserialize:commit"), "AC4: Economy AFTER Satisfaction")


# === AC9: no silent orphan members ===

func _test_ac9_unknown_equipment_fails_whole_load() -> void:
	print("\n[AC9] member references equipment_instance_id absent from grid -> WHOLE load fails, no mutation")
	var src := _make_rig(1616)
	_set_preload_state(src)
	var blob: Dictionary = src["save_load"].call("_perform_save")

	var rig := _make_rig(1717)
	_set_preload_state(rig)
	var before := _snapshot(rig)
	rig["log"].clear()

	var corrupt := _corrupt_blob(blob, "member_sim", func(d: Dictionary) -> void:
		d["members"] = [{"member_id": 7, "equipment_instance_id": 99}])
	var result: RefCounted = rig["save_load"].call("load", corrupt, _open_snapshot())

	_check(not bool(result.get("ok")), "AC9: load fails")
	_check(str(result.get("errors")).find("member 7 references unknown equipment_instance_id 99") != -1,
		"AC9: MemberSim names member + unknown id (got %s)" % str(result.get("errors")))
	for entry in EXPECTED_COMMIT_SEQUENCE:
		_check(not rig["log"].has(entry), "AC9: %s NEVER committed (no partial load)" % entry)
	_check(_states_equal(_snapshot(rig), before), "AC9: session unmutated")


func _test_ac9_member_id_exists_but_not_in_grid() -> void:
	print("\n[AC9] member references instance_id that exists in the save but is NOT in the grid -> fails (grid is source of truth)")
	var src := _make_rig(1818)
	_set_preload_state(src)
	var blob: Dictionary = src["save_load"].call("_perform_save")

	var rig := _make_rig(1919)
	rig["log"].clear()
	# Member data carries id 3 — the grid's records only have 1 and 2.
	var corrupt := _corrupt_blob(blob, "member_sim", func(d: Dictionary) -> void:
		d["members"] = [{"member_id": 9, "equipment_instance_id": 3}])
	var result: RefCounted = rig["save_load"].call("load", corrupt, _open_snapshot())
	_check(not bool(result.get("ok")), "AC9: member referencing id 3 (not on grid) fails the load")
	_check(str(result.get("errors")).find("unknown equipment_instance_id 3") != -1, "AC9: error names id 3 (got %s)" % str(result.get("errors")))


func _test_ac9_zero_members_passes() -> void:
	print("\n[AC9] zero members -> MemberSim validates fine, load succeeds")
	var src := _make_rig(2020)
	_set_preload_state(src)
	var blob: Dictionary = src["save_load"].call("_perform_save")

	var rig := _make_rig(2121)
	var empty := _corrupt_blob(blob, "member_sim", func(d: Dictionary) -> void:
		d["members"] = [])
	var result: RefCounted = rig["save_load"].call("load", empty, _open_snapshot())
	_check(bool(result.get("ok")), "AC9: empty member list loads ok (got %s)" % str(result.get("errors")))


# === Valid load ===

func _test_valid_load_restores_state() -> void:
	print("\n[valid] clean load commits every system and restores session state")
	var src := _make_rig(2222)
	_set_preload_state(src)
	var blob: Dictionary = src["save_load"].call("_perform_save")

	var rig := _make_rig(2323)  # fresh session, no state
	var result: RefCounted = rig["save_load"].call("load", blob, _open_snapshot())
	_check(bool(result.get("ok")), "valid: load ok (got %s)" % str(result.get("errors")))

	_check(int(rig["orchestrator"].call("get_tick_count")) == 3, "valid: tick_count restored to 3 (got %d)" % int(rig["orchestrator"].call("get_tick_count")))
	_check(bool(rig["time_system"].call("is_paused")), "valid: resumes PAUSED (Core Rule 9)")
	var gs_data: Dictionary = rig["grid_system"].call("serialize")
	_check((gs_data["records"] as Array).size() == 2, "valid: grid has the 2 saved equipment records (got %d)" % (gs_data["records"] as Array).size())
	var member_ids: Array = []
	for m in (rig["member_sim"].get("members") as Array):
		member_ids.append(int(m["equipment_instance_id"]))
	_check(member_ids == [1, 2], "valid: member equipment references restored (got %s)" % str(member_ids))
	_check(int(rig["congestion"].get("counter")) == 5, "valid: congestion counter restored (got %d)" % int(rig["congestion"].get("counter")))
	_check(int(rig["satisfaction"].get("counter")) == 7, "valid: satisfaction counter restored (got %d)" % int(rig["satisfaction"].get("counter")))
	_check(int(rig["economy"].get("balance")) == 500, "valid: economy balance restored (got %d)" % int(rig["economy"].get("balance")))


# === Phase B FATAL path ===

func _test_phase_b_fatal_to_menu() -> void:
	print("\n[edge] Phase B commit failure (impossible after clean Phase A) -> FATAL, no silent partial")
	var src := _make_rig(2424)
	_set_preload_state(src)
	var blob: Dictionary = src["save_load"].call("_perform_save")

	# The fail-on-commit economy is wired BEFORE init so it is the single
	# registered "Economy" sub-stream (register_system asserts on duplicate).
	var fail_econ: RefCounted = FailOnCommitEco.new()
	fail_econ.set("fail_commit", true)
	var rig := _make_rig(2525, fail_econ)

	var result: RefCounted = rig["save_load"].call("load", blob, _open_snapshot())
	_check(not bool(result.get("ok")), "FATAL: load fails")
	var errors: Array = result.get("errors")
	_check(errors.size() == 1 and str(errors[0]).begins_with("FATAL:"), "FATAL: exactly one FATAL error (got %s)" % str(errors))
	_check(str(errors[0]).find("Economy") != -1, "FATAL: names Economy (got %s)" % str(errors[0]))


# === Blob key gate ===

func _test_blob_key_gate_blocks_before_systems() -> void:
	print("\n[edge] blob key gate: missing required key -> load rejected before ANY system is called")
	var src := _make_rig(2626)
	_set_preload_state(src)
	var blob: Dictionary = src["save_load"].call("_perform_save")

	var rig := _make_rig(2727)
	rig["log"].clear()
	var missing: Dictionary = blob.duplicate(true)
	missing.erase("economy")
	var result: RefCounted = rig["save_load"].call("load", missing, _open_snapshot())

	_check(not bool(result.get("ok")), "gate: load fails on missing key")
	var gate_errors: Array = result.get("errors")
	_check(gate_errors.size() == 1 and str(gate_errors[0]).find("missing required key 'economy'") != -1, "gate: error names the missing key (got %s)" % str(gate_errors))
	_check(rig["log"].is_empty(), "gate: NO system was called (blob gate is first)")
