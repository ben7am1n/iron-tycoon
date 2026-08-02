# tests/integration/save_load/roundtrip_determinism_test.gd
# Story SL-003: Round-Trip Determinism and Resume-Paused Enforcement
# (production/epics/save-load/story-003-roundtrip-determinism-resume-paused.md)
#
# THE DETERMINISM CANARY. save→load→run N→save2 must be byte-identical to
# save→run N→save_control (AC2). This is the CANARY for the three determinism
# conditions: (a) RNG stream state restored exactly (rng.state = hex_to_int64,
# never re-derived from master_seed), (b) tick order identical (fixed dispatch,
# no mid-tick yield), (c) Navigation AStarGrid2D tie-break bit-identical across
# rebuild (ADR-0007 gate PASSED 2026-07-21 — covered in CI by
# tests/integration/grid_system/grid_navigation_solidity_test.gd).
#
# Covers the BLOCKING ACs:
#   - AC2  save→load→run N→save2 == save→run N→save_control, byte-identical
#         JSON.stringify output (full blob, structural — not top-level keys)
#   - AC5  load() ALWAYS resumes paused: TimeSystem.is_paused()==true AND
#         speed_multiplier==0 after EVERY load, regardless of saved speed/paused;
#         _last_speed preserved so resume() restores the saved speed
#   - AC7  per-system RNG streams restored EXACTLY: after load, the next
#         randf() draws from every registered system equal the original
#         session's next draws (float equality, not approximate) — restored via
#         rng.state =, never re-derived from master_seed
#
# STUB PLAN (story QA): all 6 coordinated systems are the REAL Core-layer
# stubs from src/ (member_sim.gd / congestion.gd / satisfaction.gd /
# economy.gd) + real TimeSystem + real GridSystem; the 4 tick systems are
# wired into the orchestrator's _tick_systems in FIXED_TICK_ORDER so
# _fast_forward_ticks() dispatches on_tick() to them (advancing each stub's
# counter + RNG draw per tick). PlacementSystem/SelectionSystem/Navigation do
# NOT exist in src/ yet — the rig installs inert derivation stand-ins so the
# full load path runs; Navigation rebuild determinism itself is the ADR-0007
# gate (CI), not re-tested here.
#
# DOCUMENTED DEVIATIONS FROM THE STORY SKETCH (not silent):
#   D1 (AC2 sim state): the sketch's Path A never resumes while Path B does —
#     the full blob includes TimeSystem {paused, speed_multiplier, _last_speed},
#     so a paused control vs a resumed restored path can never be byte-identical.
#     _build_orchestrator() therefore starts the sim RUNNING at 1x (a normal
#     session state); Path B's load forces paused (asserted — AC5 inside the
#     round-trip), then resume() brings it back to the same 1x UI state. Both
#     paths then save from identical TimeSystem state.
#   D2 (AC7 draw capture): the sketch captures 20 draws BEFORE saving. Each
#     randf() advances the RNG, so the blob would serialize the POST-capture
#     state and the restored instance's draws would be off-by-20 vs the
#     captured list. QA text says "next 20 draws match continuing the original
#     (no load)" — that requires capturing AFTER the save point. This test
#     saves first, then captures expected draws from the ORIGINAL (which is
#     exactly "continuing the original"), then loads and compares.
#   D3 (get_rng location): the sketch calls orchestrator.time_system.get_rng().
#     TimeSystem has no such method; the RNG registry is SeededRNG (ADR-0004),
#     so tests draw via seeded_rng.get_rng(name).
#   D4 (JSON options): the sketch's snippet passes sort_keys=false, but the
#     Control Manifest guardrail (story line 26 / QA line 149) mandates
#     sort_keys=true + full_precision=true for byte-identical output. Used here.
#   D5 (seed literal): the sketch's 0xDEADBEEF_CAFE1234 has bit 63 set.
#     Verified engine fact (seeded_rng.gd header): hex literals above INT64_MAX
#     do NOT wrap — they are rejected at parse and silently clamp to INT64_MAX.
#     Tests use positive int64-safe seeds (0x5EEDCAFE12345678 etc.).
#   D6 (members mid-walk): the MemberSim stub carries a static member roster
#     (no positions yet — real story owns those). The round-trip covers
#     member-list payload fidelity; position-state determinism is a
#     real-MemberSim concern when it lands.
#
# Run standalone: godot --headless --script tests/integration/save_load/roundtrip_determinism_test.gd
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"

const GRID_W := 4
const GRID_H := 4

# The four tick systems in FIXED_TICK_ORDER (simulation_orchestrator.gd) —
# the textual pin for determinism condition (b).
const SYSTEMS_4: Array[String] = ["MemberSim", "Congestion", "Satisfaction", "Economy"]

# The 8 blob keys (TR-SL-002) — used for the structural per-payload compare.
const BLOB_KEYS: Array[String] = [
	"version", "master_seed",
	"time_system", "grid_system",
	"member_sim", "congestion", "satisfaction", "economy",
]

## Inert derivation stand-ins. PlacementSystem/SelectionSystem/Navigation do
## not exist in src/ yet; load()'s derivation steps are null-guarded (SL-002
## DEVIATION #4), and installing these stand-ins makes the full 9-step load
## path run end-to-end. They record nothing — SL-003 asserts determinism, not
## call order (SL-002's test owns the order assertions).
class DerivationSpy:
	extends RefCounted

	func rederive_counter() -> void:
		pass

	func rebuild_mapping() -> void:
		pass

	func rebuild(grid) -> void:
		pass


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
	print("  INTEGRATION TEST: SaveLoad — Round-Trip Determinism (Story SL-003)")
	print("=".repeat(48))

	_test_ac2_roundtrip_byte_identical()
	_test_ac2_roundtrip_tick_zero()
	_test_ac2_roundtrip_multiple_tick_counts()
	_test_ac2_paused_archive_roundtrip()
	_test_ac5_resume_always_paused()
	_test_ac5_last_speed_preserved()
	_test_ac7_rng_state_restored_exactly()
	_test_ac7_zero_draws_consumed()
	_test_ac7_uneven_draw_counts()
	_test_ac7_streams_independent()
	_test_determinism_probe()

	print("\n=== ROUND-TRIP DETERMINISM TEST: %d passed, %d failed ===\n" % [_pass, _fail])
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


func _TS() -> Script:
	return load("res://src/systems/time_system.gd") as Script


func _GS() -> Script:
	return load("res://src/systems/grid_system.gd") as Script


func _MS() -> Script:
	return load("res://src/systems/member_sim.gd") as Script


func _CG() -> Script:
	return load("res://src/systems/congestion.gd") as Script


func _ST() -> Script:
	return load("res://src/systems/satisfaction.gd") as Script


func _EC() -> Script:
	return load("res://src/systems/economy.gd") as Script


func _SL() -> Script:
	return load("res://src/systems/save_load.gd") as Script


func _make_orchestrator() -> Node:
	var orch: Node = load("res://src/systems/simulation_orchestrator.gd").new()
	root.add_child(orch)
	orch.call("_ready")
	return orch


## Builds the SL-003 rig: real orchestrator + SeededRNG + real TimeSystem +
## real GridSystem + the 4 real Core-layer stub systems + derivation
## stand-ins + SaveLoad. The 4 tick systems are wired into
## _tick_systems in FIXED_TICK_ORDER so _advance_tick() dispatches on_tick()
## to them (condition b). Returns the rig for the test to drive.
func _make_rig(master_seed: int) -> Dictionary:
	var orch: Node = _make_orchestrator()
	var srg: RefCounted = _SRG().new()
	srg.call("init", master_seed)

	var ts: RefCounted = _TS().new()
	ts.call("init", orch, srg)
	orch.set("time_system", ts)

	var gs: RefCounted = _GS().new()
	gs.call("init", GRID_W, GRID_H)
	for y in GRID_H:
		for x in GRID_W:
			gs.call("set_buildable", Vector2i(x, y), true)
	gs.call("freeze_buildable")
	orch.set("grid_system", gs)

	var member: RefCounted = _MS().new()
	member.call("init", orch, srg)
	orch.set("member_sim", member)

	var cong: RefCounted = _CG().new()
	cong.call("init", orch, srg)
	orch.set("congestion", cong)

	var sat: RefCounted = _ST().new()
	sat.call("init", orch, srg)
	orch.set("satisfaction", sat)

	var econ: RefCounted = _EC().new()
	econ.call("init", orch, srg)
	orch.set("economy", econ)

	# Derivation stand-ins (DEVIATION: see class header — full load path runs)
	var placement: RefCounted = DerivationSpy.new()
	orch.set("placement_system", placement)
	var selection: RefCounted = DerivationSpy.new()
	orch.set("selection_system", selection)
	var navigation: RefCounted = DerivationSpy.new()
	orch.set("navigation", navigation)

	# Lock the tick dispatch order (condition b — FIXED_TICK_ORDER).
	orch.set("_tick_systems", [member, cong, sat, econ])

	var sl: RefCounted = _SL().new()
	sl.call("init", orch)
	sl.call("_post_init")

	return {
		"orchestrator": orch,
		"seeded_rng": srg,
		"time_system": ts,
		"grid_system": gs,
		"member_sim": member,
		"congestion": cong,
		"satisfaction": sat,
		"economy": econ,
		"save_load": sl,
	}


## Builds a rig in NORMAL SESSION STATE — running at 1x (see DEVIATION D1:
## both round-trip paths must save from identical TimeSystem UI state).
func _build_orchestrator(master_seed: int) -> Dictionary:
	var rig := _make_rig(master_seed)
	rig["time_system"].call("resume")
	return rig


## Direct tick loop — bypasses _process/accumulator for test speed (story
## mandate). Each _advance_tick() dispatches synchronously to the 4 tick
## systems in FIXED_TICK_ORDER (counter+1 and one RNG draw each) then
## increments tick_count and emits tick_completed.
func _fast_forward_ticks(rig: Dictionary, n: int) -> void:
	for _i in range(n):
		rig["orchestrator"].call("_advance_tick")


## The all-open buildable snapshot matching the 4x4 rig grid (all cells 1).
func _open_snapshot() -> PackedByteArray:
	var snap := PackedByteArray()
	snap.resize(GRID_W * GRID_H)
	snap.fill(1)
	return snap


## Commits two pieces of equipment into the rig grid: instance ids 1 and 2.
## GridSystem.commit expects TYPED Array[Vector2i] params — a plain Array
## literal passed via call() is rejected, so build typed arrays.
func _commit_equipment(rig: Dictionary) -> void:
	var fp1: Array[Vector2i] = [Vector2i(0, 0)]
	var ac1: Array[Vector2i] = [Vector2i(1, 0)]
	var fp2: Array[Vector2i] = [Vector2i(2, 0)]
	var ac2: Array[Vector2i] = [Vector2i(3, 0)]
	rig["grid_system"].call("commit", 1, fp1, ac1, 0)
	rig["grid_system"].call("commit", 2, fp2, ac2, 0)


## Two members referencing the committed equipment ids (AC9-valid roster).
func _set_members(rig: Dictionary) -> void:
	rig["member_sim"].set("members", [
		{"member_id": 10, "equipment_instance_id": 1},
		{"member_id": 11, "equipment_instance_id": 2},
	])


## Byte-identical comparison per the Control Manifest guardrail:
## JSON.stringify with full_precision=true AND sort_keys=true — full blob,
## structural (nested payloads included), float-exact.
func _json(blob: Dictionary) -> String:
	return JSON.stringify(blob, "  ", true, true)


## Loads [blob] into a fresh rig (not resumed) and returns the rig + result.
func _load_fresh(master_seed: int, blob: Dictionary) -> Dictionary:
	var rig := _make_rig(master_seed)
	var result: RefCounted = rig["save_load"].call("load", blob, _open_snapshot())
	return {"rig": rig, "result": result}


# === AC2: round-trip byte-identical ===

func _test_ac2_roundtrip_byte_identical() -> void:
	print("\n[AC2] save(200) -> load -> run 100 -> save2 == save(200) -> run 100 -> save_control (byte-identical)")
	var master_seed := 0x5EEDCAFE12345678
	var rig := _build_orchestrator(master_seed)
	_commit_equipment(rig)
	_set_members(rig)
	rig["economy"].set("balance", 500)
	_fast_forward_ticks(rig, 200)

	var blob_a: Dictionary = rig["save_load"].call("_perform_save")

	# Path A (control): continue to tick 300, save
	_fast_forward_ticks(rig, 100)
	var blob_control: Dictionary = rig["save_load"].call("_perform_save")

	# Path B (load): fresh rig, restore from blob_a, run to tick 300, save
	var fresh := _load_fresh(master_seed, blob_a)
	var rig_b: Dictionary = fresh["rig"]
	var load_result: RefCounted = fresh["result"]
	_check(bool(load_result.get("ok")), "AC2: load(blob_a) ok (errors: %s)" % str(load_result.get("errors")))
	_check(bool(rig_b["time_system"].call("is_paused")), "AC2: load resumes PAUSED (asserted before resume)")
	_check(int(rig_b["orchestrator"].call("get_tick_count")) == 200,
		"AC2: tick_count restored to 200 (got %d)" % int(rig_b["orchestrator"].call("get_tick_count")))
	rig_b["time_system"].call("resume")
	_fast_forward_ticks(rig_b, 100)
	var blob_restored: Dictionary = rig_b["save_load"].call("_perform_save")

	var control_json := _json(blob_control)
	var restored_json := _json(blob_restored)
	_check(control_json == restored_json,
		"AC2: round-trip blob byte-identical to control (JSON.stringify full_precision + sort_keys)")

	# Structural compare — every payload, not just top-level key count.
	for key in BLOB_KEYS:
		var sub_control: Variant = blob_control[key]
		var sub_restored: Variant = blob_restored[key]
		if sub_control is Dictionary:
			_check(_json(sub_control) == _json(sub_restored),
				"AC2: payload '%s' byte-identical (JSON full precision)" % key)
		else:
			_check(str(sub_control) == str(sub_restored),
				"AC2: payload '%s' equal" % key)

	# Direct state spot-checks on the restored session (diagnostics).
	var gs_data: Dictionary = rig_b["grid_system"].call("serialize")
	_check((gs_data["records"] as Array).size() == 2, "AC2: restored grid has the 2 saved equipment records")
	_check((rig_b["member_sim"].get("members") as Array).size() == 2, "AC2: restored member roster (2 members)")
	_check(int(rig_b["economy"].get("balance")) == 500, "AC2: restored economy balance 500")


func _test_ac2_roundtrip_tick_zero() -> void:
	print("\n[AC2] edge: save at tick_count=0 (fresh sim, no ticks) -> load -> run 50 -> byte-identical")
	var master_seed := 0x1234ABCD
	var rig := _build_orchestrator(master_seed)
	var blob_a: Dictionary = rig["save_load"].call("_perform_save")  # tick 0

	_fast_forward_ticks(rig, 50)
	var blob_control: Dictionary = rig["save_load"].call("_perform_save")

	var fresh := _load_fresh(master_seed, blob_a)
	var rig_b: Dictionary = fresh["rig"]
	var load_result: RefCounted = fresh["result"]
	_check(bool(load_result.get("ok")), "AC2[tick0]: load ok (errors: %s)" % str(load_result.get("errors")))
	_check(int(rig_b["orchestrator"].call("get_tick_count")) == 0, "AC2[tick0]: restored tick_count 0")
	rig_b["time_system"].call("resume")
	_fast_forward_ticks(rig_b, 50)
	var blob_restored: Dictionary = rig_b["save_load"].call("_perform_save")
	_check(_json(blob_control) == _json(blob_restored), "AC2[tick0]: round-trip byte-identical (fresh sim at tick 0)")


func _test_ac2_roundtrip_multiple_tick_counts() -> void:
	print("\n[AC2] edge: save at 50 / 500 / 1000 ticks -> load -> run -> byte-identical")
	var cases := [
		{"save_at": 50, "run_after": 100},
		{"save_at": 500, "run_after": 250},
		{"save_at": 1000, "run_after": 500},
	]
	for c in cases:
		var save_at := int(c["save_at"])
		var run_after := int(c["run_after"])
		var master_seed := 0x1000 + save_at
		var rig := _build_orchestrator(master_seed)
		_commit_equipment(rig)
		_set_members(rig)
		_fast_forward_ticks(rig, save_at)
		var blob_a: Dictionary = rig["save_load"].call("_perform_save")

		_fast_forward_ticks(rig, run_after)
		var blob_control: Dictionary = rig["save_load"].call("_perform_save")

		var fresh := _load_fresh(master_seed, blob_a)
		var rig_b: Dictionary = fresh["rig"]
		var load_result: RefCounted = fresh["result"]
		_check(bool(load_result.get("ok")), "AC2[save_at=%d]: load ok (errors: %s)" % [save_at, str(load_result.get("errors"))])
		_check(int(rig_b["orchestrator"].call("get_tick_count")) == save_at, "AC2[save_at=%d]: restored tick_count" % save_at)
		rig_b["time_system"].call("resume")
		_fast_forward_ticks(rig_b, run_after)
		var blob_restored: Dictionary = rig_b["save_load"].call("_perform_save")
		_check(_json(blob_control) == _json(blob_restored),
			"AC2[save_at=%d, run_after=%d]: round-trip byte-identical" % [save_at, run_after])


func _test_ac2_paused_archive_roundtrip() -> void:
	print("\n[AC2] edge: save taken WHILE PAUSED -> load -> resume -> run -> byte-identical")
	var master_seed := 0x424242
	var rig := _build_orchestrator(master_seed)
	_commit_equipment(rig)
	_set_members(rig)
	_fast_forward_ticks(rig, 100)
	rig["time_system"].call("pause")  # paused archive: paused=true, speed=0, _last_speed preserved
	rig["time_system"].call("set_speed", 3)
	var blob_a: Dictionary = rig["save_load"].call("_perform_save")
	_check(bool(rig["time_system"].call("is_paused")), "AC2[paused]: blob taken while paused")

	# Path A (control): resume at saved 3x, run 50, save
	rig["time_system"].call("resume")
	_fast_forward_ticks(rig, 50)
	var blob_control: Dictionary = rig["save_load"].call("_perform_save")

	# Path B (load): load forces paused, resume restores 3x, run 50, save
	var fresh := _load_fresh(master_seed, blob_a)
	var rig_b: Dictionary = fresh["rig"]
	var load_result: RefCounted = fresh["result"]
	_check(bool(load_result.get("ok")), "AC2[paused]: load ok (errors: %s)" % str(load_result.get("errors")))
	_check(bool(rig_b["time_system"].call("is_paused")), "AC2[paused]: load of a paused archive resumes PAUSED")
	rig_b["time_system"].call("resume")
	_fast_forward_ticks(rig_b, 50)
	var blob_restored: Dictionary = rig_b["save_load"].call("_perform_save")
	_check(_json(blob_control) == _json(blob_restored), "AC2[paused]: paused-archive round-trip byte-identical")


# === AC5: load always resumes paused ===

func _test_ac5_resume_always_paused() -> void:
	print("\n[AC5] load() -> is_paused()==true AND speed_multiplier==0 for EVERY saved speed/paused combination")
	var test_cases := [
		{"speed": 1, "paused": false},
		{"speed": 2, "paused": false},
		{"speed": 3, "paused": false},
		{"speed": 0, "paused": true},
		{"speed": 1, "paused": true},
	]
	for tc in test_cases:
		var speed := int(tc["speed"])
		var paused_state := bool(tc["paused"])
		var master_seed := 9000 + speed
		var blob := _make_save_with_speed(master_seed, speed, paused_state)
		var rig := _make_rig(master_seed)
		var result: RefCounted = rig["save_load"].call("load", blob, _open_snapshot())
		_check(bool(result.get("ok")), "AC5[speed=%d paused=%s]: load ok (errors: %s)" % [speed, str(paused_state), str(result.get("errors"))])
		_check(bool(rig["time_system"].call("is_paused")),
			"AC5[speed=%d paused=%s]: is_paused()==true after load" % [speed, str(paused_state)])
		_check(int(rig["time_system"].call("get_speed_multiplier")) == 0,
			"AC5[speed=%d paused=%s]: speed_multiplier==0 after load" % [speed, str(paused_state)])


func _test_ac5_last_speed_preserved() -> void:
	print("\n[AC5] edge: _last_speed preserved across load — resume() restores the saved speed")
	var master_seed := 777
	var blob := _make_save_with_speed(master_seed, 3, false)
	var rig := _make_rig(master_seed)
	var result: RefCounted = rig["save_load"].call("load", blob, _open_snapshot())
	_check(bool(result.get("ok")), "AC5[last]: load ok (errors: %s)" % str(result.get("errors")))

	rig["time_system"].call("resume")
	_check(int(rig["time_system"].call("get_speed_multiplier")) == 3,
		"AC5[last]: resume() after load restores saved 3x (got %d)" % int(rig["time_system"].call("get_speed_multiplier")))
	_check(not bool(rig["time_system"].call("is_paused")), "AC5[last]: resumed (not paused)")

	# Ticks fire after resume (story mandate: direct _advance_tick, not real clock)
	_fast_forward_ticks(rig, 5)
	_check(int(rig["orchestrator"].call("get_tick_count")) == 5,
		"AC5[last]: 5 ticks fire after resume at restored 3x speed (got %d)" % int(rig["orchestrator"].call("get_tick_count")))


## Composes a save blob whose TimeSystem payload carries the requested
## (speed, paused) UI state — via the real set_speed/pause/resume API.
func _make_save_with_speed(master_seed: int, speed: int, paused_state: bool) -> Dictionary:
	var rig := _make_rig(master_seed)
	var ts: RefCounted = rig["time_system"]
	if paused_state:
		ts.call("pause")
		ts.call("set_speed", speed)  # records _last_speed while paused
	else:
		ts.call("set_speed", speed)
		ts.call("resume")  # paused=false, speed=_last_speed=speed
	return rig["save_load"].call("_perform_save")


# === AC7: per-system RNG state restored exactly ===

func _test_ac7_rng_state_restored_exactly() -> void:
	print("\n[AC7] post-load randf() draws == continuing the original, every system, exact float equality")
	var master_seed := 0x1234567890ABCDEF
	var rig := _build_orchestrator(master_seed)
	_commit_equipment(rig)
	_fast_forward_ticks(rig, 100)

	# SAVE FIRST (DEVIATION D2): the blob captures the post-tick-100 state.
	var blob: Dictionary = rig["save_load"].call("_perform_save")

	# "Continuing the original": the 20 draws the ORIGINAL produces after save.
	var expected_draws := {}
	for sys_name in SYSTEMS_4:
		var rng: RandomNumberGenerator = rig["seeded_rng"].call("get_rng", sys_name)
		expected_draws[sys_name] = []
		for _i in range(20):
			expected_draws[sys_name].append(rng.randf())

	# Load into a fresh rig — the restored RNGs must reproduce those draws.
	var fresh := _load_fresh(master_seed, blob)
	var rig2: Dictionary = fresh["rig"]
	var load_result: RefCounted = fresh["result"]
	_check(bool(load_result.get("ok")), "AC7: load ok (errors: %s)" % str(load_result.get("errors")))

	for sys_name in SYSTEMS_4:
		var rng2: RandomNumberGenerator = rig2["seeded_rng"].call("get_rng", sys_name)
		for i in range(expected_draws[sys_name].size()):
			var actual: float = rng2.randf()
			var expected: float = expected_draws[sys_name][i]
			_check(actual == expected,
				"AC7: %s[%d] exact draw match (expected %s, got %s)" % [sys_name, i, str(expected), str(actual)])


func _test_ac7_zero_draws_consumed() -> void:
	print("\n[AC7] edge: zero draws consumed (RNG at seeded initial state) — restore still exact")
	var master_seed := 99991
	var rig := _build_orchestrator(master_seed)  # 0 ticks — RNGs at initial seed state
	var blob: Dictionary = rig["save_load"].call("_perform_save")

	var expected := {}
	for sys_name in SYSTEMS_4:
		var rng: RandomNumberGenerator = rig["seeded_rng"].call("get_rng", sys_name)
		expected[sys_name] = rng.randf()

	var fresh := _load_fresh(master_seed, blob)
	var rig2: Dictionary = fresh["rig"]
	var load_result: RefCounted = fresh["result"]
	_check(bool(load_result.get("ok")), "AC7[zero]: load ok (errors: %s)" % str(load_result.get("errors")))

	for sys_name in SYSTEMS_4:
		var rng2: RandomNumberGenerator = rig2["seeded_rng"].call("get_rng", sys_name)
		var actual_zero: float = rng2.randf()
		_check(actual_zero == expected[sys_name],
			"AC7[zero]: %s first draw exact at seeded initial state (got %s)" % [sys_name, str(actual_zero)])


func _test_ac7_uneven_draw_counts() -> void:
	print("\n[AC7] edge: one system's RNG consumed many more draws than another — each restored independently")
	var master_seed := 555001
	var rig := _build_orchestrator(master_seed)
	_fast_forward_ticks(rig, 50)
	# Economy's stream consumes 37 EXTRA draws (its real workload draws more
	# often — natural divergence between per-system draw counts).
	var econ_rng: RandomNumberGenerator = rig["seeded_rng"].call("get_rng", "Economy")
	for _i in range(37):
		econ_rng.randi()

	var blob: Dictionary = rig["save_load"].call("_perform_save")

	var expected := {}
	for sys_name in SYSTEMS_4:
		var rng: RandomNumberGenerator = rig["seeded_rng"].call("get_rng", sys_name)
		expected[sys_name] = rng.randf()

	var fresh := _load_fresh(master_seed, blob)
	var rig2: Dictionary = fresh["rig"]
	var load_result: RefCounted = fresh["result"]
	_check(bool(load_result.get("ok")), "AC7[uneven]: load ok (errors: %s)" % str(load_result.get("errors")))

	for sys_name in SYSTEMS_4:
		var rng2: RandomNumberGenerator = rig2["seeded_rng"].call("get_rng", sys_name)
		_check(rng2.randf() == expected[sys_name],
			"AC7[uneven]: %s next draw exact (Economy had +37 draws)" % sys_name)


func _test_ac7_streams_independent() -> void:
	print("\n[AC7] edge: each system's RNG is an independent sub-stream (not one master stream)")
	var rig := _build_orchestrator(0x5EEDCAFE12345678)
	_fast_forward_ticks(rig, 100)
	var states := {}
	for sys_name in SYSTEMS_4:
		var rng: RandomNumberGenerator = rig["seeded_rng"].call("get_rng", sys_name)
		states[sys_name] = int(rng.state)

	_check(states["MemberSim"] != states["Congestion"], "AC7[indep]: MemberSim != Congestion internal state")
	_check(states["MemberSim"] != states["Satisfaction"], "AC7[indep]: MemberSim != Satisfaction internal state")
	_check(states["MemberSim"] != states["Economy"], "AC7[indep]: MemberSim != Economy internal state")
	_check(states["Congestion"] != states["Satisfaction"], "AC7[indep]: Congestion != Satisfaction internal state")
	_check(states["Congestion"] != states["Economy"], "AC7[indep]: Congestion != Economy internal state")
	_check(states["Satisfaction"] != states["Economy"], "AC7[indep]: Satisfaction != Economy internal state")


# === Determinism probe ===

func _test_determinism_probe() -> void:
	print("\n[PROBE] two fresh rigs, same seed -> byte-identical blobs at every checkpoint (no hidden global state)")
	var master_seed := 0x5EEDCAFE12345678
	var rig_a := _build_orchestrator(master_seed)
	var rig_b := _build_orchestrator(master_seed)
	_commit_equipment(rig_a)
	_commit_equipment(rig_b)
	_set_members(rig_a)
	_set_members(rig_b)

	var prev_a := 0
	var prev_b := 0
	for cp in [0, 37, 200, 300]:
		_fast_forward_ticks(rig_a, cp - prev_a)
		_fast_forward_ticks(rig_b, cp - prev_b)
		prev_a = cp
		prev_b = cp
		var blob_a: Dictionary = rig_a["save_load"].call("_perform_save")
		var blob_b: Dictionary = rig_b["save_load"].call("_perform_save")
		_check(_json(blob_a) == _json(blob_b),
			"PROBE: byte-identical at tick %d (fresh rigs, same seed)" % cp)

	# Condition (b) textual pin: dispatch order is the locked FIXED_TICK_ORDER.
	var names: Array = []
	for sys in (rig_a["orchestrator"].get("_tick_systems") as Array):
		names.append(sys.call("system_name"))
	_check(names == SYSTEMS_4,
		"PROBE: tick dispatch order == FIXED_TICK_ORDER (got %s)" % str(names))
