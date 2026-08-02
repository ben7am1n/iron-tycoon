# tests/integration/save_load/saveblob_composition_test.gd
# Story SL-001: SaveBlob Composition and Tick-Boundary Hook
# (production/epics/save-load/story-001-saveblob-tick-boundary.md)
#
# Covers the BLOCKING ACs:
#   - AC1        serialize() on every coordinated system is called ONLY inside
#                the tick_completed handler — never inside request_save()
#                (running), never mid-tick (spy observes 0 during on_tick),
#                exactly once per save request; paused saves execute
#                immediately at the frozen boundary; the 8-tick clamp frame
#                saves once after all 8 ticks
#   - AC-BLOB-1  blob has exactly 8 keys
#                {version, master_seed, time_system, grid_system, member_sim,
#                 congestion, satisfaction, economy} — no extra, none missing
#   - AC-BLOB-2  top-level master_seed == blob.time_system.master_seed
#                (redundancy, not divergence)
#   - AC-BLOB-3  no key for navigation / placement_system / selection_system /
#                zone_rules — the 4 non-contributing systems are absent
# plus the story QA edge cases (empty-state save, a system returning an empty
# dict, save→save without a tick between) and the _validate_blob_keys gate
# (missing key / extra key / excluded key / diverged master_seed).
#
# The 5 non-TimeSystem coordinated systems do not exist in src/ yet, so the
# test injects SerializeSpy stubs for grid_system/member_sim/congestion/
# satisfaction/economy (each system's own serialize() contract is tested in
# its own story — SaveLoad only calls methods that exist). TimeSystem is
# subclassed (TimeSpy) so its serialize() call count is observable too.
#
# Run standalone: godot --headless --script tests/integration/save_load/saveblob_composition_test.gd
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"

# The fixed 8-key blob contract (TR-SL-002) — also mirrored in
# SaveLoad.CONTRIBUTING_KEYS; asserting the exact ordered list pins both the
# set AND the stable serialize order (for diff/migration tooling, GDD Core Rule 2).
const EXPECTED_KEYS := [
	"version", "master_seed",
	"time_system", "grid_system",
	"member_sim", "congestion", "satisfaction", "economy",
]

const EXCLUDED_KEYS := [
	"navigation", "placement_system", "selection_system", "zone_rules",
]

# The four tick systems registered into SeededRNG (AC8's "all 4 registered").
const SYSTEMS_4: Array[String] = ["MemberSim", "Congestion", "Satisfaction", "Economy"]

# Orchestrator field name -> blob key name for the 5 spy-coordinated systems.
const SPY_FIELDS: Array[String] = [
	"grid_system", "member_sim", "congestion", "satisfaction", "economy",
]


## Spy coordinated system: counts serialize() calls, returns a configurable
## payload, and can simulate a mid-tick save request from within on_tick()
## (the "UI callback mid-tick" scenario) while recording whether any
## serialize() had run by that moment.
class SerializeSpy:
	extends RefCounted

	var serialize_call_count: int = 0
	var payload: Dictionary = {}
	var request_on_tick: bool = false
	var save_load: Object = null
	var on_tick_observed_count: int = -1  # serialize_call_count seen inside on_tick
	var on_tick_calls: int = 0

	func serialize() -> Dictionary:
		serialize_call_count += 1
		return payload

	func on_tick(tick_count: int) -> void:
		on_tick_observed_count = serialize_call_count
		on_tick_calls += 1
		if request_on_tick and save_load != null:
			save_load.call("request_save")


## TimeSystem subclass so its serialize() call count is observable (AC1 spies
## on EVERY coordinated system, including TimeSystem). Everything else —
## accumulator, pause/resume, serialization internals — is the real engine.
class TimeSpy:
	extends TimeSystem

	var serialize_call_count: int = 0

	func serialize() -> Dictionary:
		serialize_call_count += 1
		return super.serialize()


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
	print("  INTEGRATION TEST: SaveLoad — Blob Composition & Tick Boundary (Story SL-001)")
	print("=".repeat(48))

	_test_ac1_running_save_defers_to_tick_boundary()
	_test_ac1_save_save_without_tick_collapses()
	_test_ac1_paused_save_executes_immediately()
	_test_ac1_paused_after_running_save_immediate()
	_test_ac1_eight_tick_clamp_saves_once()
	_test_ac1_mid_tick_request_defers_to_boundary()
	_test_blob_exactly_eight_keys()
	_test_blob_master_seed_redundancy()
	_test_blob_excluded_systems_absent()
	_test_blob_empty_state_save()
	_test_blob_partial_empty_system()
	_test_validate_blob_keys_gate()

	print("\n=== SAVEBLOB COMPOSITION TEST: %d passed, %d failed ===\n" % [_pass, _fail])
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


## Creates an initialized SimulationOrchestrator in the scene tree (delivers
## _ready() synchronously — same pattern as the time-system tests).
func _make_orchestrator() -> Node:
	var orch: Node = load("res://src/systems/simulation_orchestrator.gd").new()
	root.add_child(orch)
	orch.call("_ready")
	return orch


## Builds the SL-001 rig:
##   - real SimulationOrchestrator (its own unwired TimeSystem is REPLACED by
##     the wired TimeSpy — SaveLoad reads orchestrator.time_system at init)
##   - SeededRNG with master_seed + the 4 tick systems registered
##   - TimeSpy wired via init(orchestrator, seeded_rng)
##   - 5 SerializeSpy stubs installed on the orchestrator's coordinated fields
##   - SaveLoad initialized + _post_init (subscribed to tick_completed)
## Returns the assembled rig for the test to drive.
func _make_rig(master_seed: int) -> Dictionary:
	var orch: Node = _make_orchestrator()
	var srg: RefCounted = _SRG().new()
	srg.call("init", master_seed)
	for name in SYSTEMS_4:
		srg.call("register_system", name)
	var ts: RefCounted = TimeSpy.new()
	ts.call("init", orch, srg)
	orch.set("time_system", ts)

	var spies: Dictionary = {}
	for field in SPY_FIELDS:
		var spy := SerializeSpy.new()
		spy.payload = {"_spy": field, "value": 42}
		orch.set(field, spy)
		spies[field] = spy

	var sl: RefCounted = _SL().new()
	sl.call("init", orch)
	sl.call("_post_init")
	return {"orchestrator": orch, "seeded_rng": srg, "time_system": ts, "spies": spies, "save_load": sl}


## Total serialize() calls across TimeSpy + all 5 spy systems.
func _total_serialize_calls(rig: Dictionary) -> int:
	var total := int(rig["time_system"].get("serialize_call_count"))
	for field in SPY_FIELDS:
		total += int(rig["spies"][field].serialize_call_count)
	return total


func _assert_all_counts(rig: Dictionary, expected: int, label: String) -> void:
	var ts: RefCounted = rig["time_system"]
	_check(int(ts.get("serialize_call_count")) == expected, "%s: TimeSystem.serialize() called %d times (got %d)" % [label, expected, int(ts.get("serialize_call_count"))])
	for field in SPY_FIELDS:
		var spy: RefCounted = rig["spies"][field]
		_check(int(spy.get("serialize_call_count")) == expected, "%s: %s.serialize() called %d times (got %d)" % [label, field, expected, int(spy.get("serialize_call_count"))])


# === AC1: saves fire only at tick boundaries ===

func _test_ac1_running_save_defers_to_tick_boundary() -> void:
	print("\n[AC1] request_save() while running -> NO serialize; tick fires -> exactly once")
	var rig := _make_rig(12345)
	rig["time_system"].call("resume")

	rig["save_load"].call("request_save")
	# serialize() must NOT be called inside request_save() — the flag only.
	_assert_all_counts(rig, 0, "after request_save (running)")
	_check(_total_serialize_calls(rig) == 0, "AC1: zero serialize() calls inside request_save() while running")

	# Fire exactly one tick (process(0.1) at 1x -> 1 tick, accumulator back to 0.0).
	rig["time_system"].call("process", 0.1)
	_check(int(rig["orchestrator"].call("get_tick_count")) == 1, "one tick fired (tick_count == 1, got %d)" % int(rig["orchestrator"].call("get_tick_count")))
	# Exactly once per save request, all 6 systems, at the boundary.
	_assert_all_counts(rig, 1, "after one tick")
	_check(_total_serialize_calls(rig) == 6, "AC1: exactly 6 serialize() calls total (1 per coordinated system)")


func _test_ac1_save_save_without_tick_collapses() -> void:
	print("\n[AC1] save -> save without a tick between: one save at the next boundary")
	var rig := _make_rig(77)
	rig["time_system"].call("resume")

	rig["save_load"].call("request_save")
	rig["save_load"].call("request_save")  # second request, no tick between
	_assert_all_counts(rig, 0, "after double request_save (no tick)")

	rig["time_system"].call("process", 0.1)  # 1 tick
	_assert_all_counts(rig, 1, "after tick (both requests collapsed into one save)")

	# A second tick with NO pending request must not serialize anything.
	rig["time_system"].call("process", 0.1)
	_assert_all_counts(rig, 1, "after second tick (no pending request)")
	_check(int(rig["orchestrator"].call("get_tick_count")) == 2, "two ticks fired total")


func _test_ac1_paused_save_executes_immediately() -> void:
	print("\n[AC1] paused: request_save() executes immediately (sim frozen at a boundary)")
	var rig := _make_rig(9)
	# Fresh TimeSystem starts paused (Core Rule 9 / TS-002 default).
	_check(bool(rig["time_system"].call("is_paused")) == true, "rig starts paused")

	rig["save_load"].call("request_save")
	_assert_all_counts(rig, 1, "paused request_save (immediate)")
	_check(int(rig["orchestrator"].call("get_tick_count")) == 0, "no tick fired by the paused save (tick_count == 0)")

	# Even after more paused frames, nothing changes — no ticks, no re-saves.
	rig["time_system"].call("process", 0.5)
	_assert_all_counts(rig, 1, "paused frames after immediate save")
	_check(int(rig["orchestrator"].call("get_tick_count")) == 0, "paused frames fire no ticks")


func _test_ac1_paused_after_running_save_immediate() -> void:
	print("\n[AC1] run some ticks, pause, then request_save() -> immediate (still at a boundary)")
	var rig := _make_rig(4242)
	rig["time_system"].call("resume")
	# Each process(0.1) fires exactly 1 tick (TS-002 AC1) — a single 0.3 delta
	# would floor to 2 ticks (0.3/0.1 == 2.999... in IEEE754), so loop instead.
	for i in 3:
		rig["time_system"].call("process", 0.1)
	rig["time_system"].call("pause")
	_check(int(rig["orchestrator"].call("get_tick_count")) == 3, "3 ticks ran before pause (got %d)" % int(rig["orchestrator"].call("get_tick_count")))

	rig["save_load"].call("request_save")
	_assert_all_counts(rig, 1, "paused-after-running request_save (immediate)")
	_check(int(rig["orchestrator"].call("get_tick_count")) == 3, "save did not advance tick_count")


func _test_ac1_eight_tick_clamp_saves_once() -> void:
	print("\n[AC1] 8-tick clamp frame: one save after ALL 8 ticks complete")
	var rig := _make_rig(2024)
	rig["time_system"].call("resume")
	rig["save_load"].call("request_save")

	rig["time_system"].call("process", 2.0)  # 2.0s at 1x = 20 ticks worth -> clamped to 8
	_check(int(rig["orchestrator"].call("get_tick_count")) == 8, "8 ticks fired in the clamp frame (got %d)" % int(rig["orchestrator"].call("get_tick_count")))
	_assert_all_counts(rig, 1, "clamp frame (saved once, after all 8 ticks)")
	_check(_total_serialize_calls(rig) == 6, "AC1: clamp frame produced exactly one save (6 serialize calls)")


func _test_ac1_mid_tick_request_defers_to_boundary() -> void:
	print("\n[AC1] request_save() issued from INSIDE on_tick() -> serialize still only at the boundary")
	var rig := _make_rig(555)
	var member_spy: RefCounted = rig["spies"]["member_sim"]
	member_spy.set("request_on_tick", true)     # on_tick calls save_load.request_save()
	member_spy.set("save_load", rig["save_load"])
	(rig["orchestrator"].get("_tick_systems") as Array).append(member_spy)  # becomes a tick system

	rig["time_system"].call("resume")
	rig["time_system"].call("process", 0.1)  # 1 tick; on_tick requests save mid-tick
	_check(int(member_spy.get("on_tick_calls")) == 1, "spy's on_tick ran once")
	_check(int(member_spy.get("on_tick_observed_count")) == 0, "no serialize() observed DURING on_tick (mid-tick clean)")
	_assert_all_counts(rig, 1, "after mid-tick request (save fired at the boundary)")
	_check(int(rig["orchestrator"].call("get_tick_count")) == 1, "tick_count == 1 after mid-tick request tick")

	# Break the TEST-FIXTURE reference cycle (spy -> SaveLoad -> spy via
	# SaveLoad._member_sim). RefCounted cycles are never collected in Godot
	# (no cycle collector), so without this the spy and SaveLoad would leak at
	# exit. Production wiring has no such back-reference — SaveLoad holds
	# MemberSim, never the reverse; this is purely the spy's request hook.
	member_spy.set("save_load", null)


# === AC-BLOB-1/2/3: blob composition ===

func _test_blob_exactly_eight_keys() -> void:
	print("\n[AC-BLOB-1] composed blob has exactly the 8 required keys, no more no less")
	var rig := _make_rig(31337)
	rig["time_system"].call("resume")
	rig["time_system"].call("process", 0.1)  # one real tick so TimeSystem has state
	rig["save_load"].call("request_save")
	rig["time_system"].call("process", 0.1)  # boundary save
	var blob: Dictionary = rig["save_load"].call("_perform_save")  # re-run: pure read

	_check(blob.size() == 8, "AC-BLOB-1: blob has exactly 8 keys (got %d)" % blob.size())
	_check(blob.keys() == EXPECTED_KEYS, "AC-BLOB-1: blob keys match the fixed set in stable order (got %s)" % str(blob.keys()))
	for key in EXPECTED_KEYS:
		_check(blob.has(key), "AC-BLOB-1: key '%s' present" % key)
	_check(int(blob["version"]) == 1, "blob version == SAVE_FORMAT_VERSION (1)")
	_check(blob["time_system"] is Dictionary and int(blob["time_system"]["tick_count"]) >= 1, "time_system payload is TimeSystem.serialize() output")
	_check(blob["grid_system"] == rig["spies"]["grid_system"].get("payload"), "grid_system payload is its serialize() output")


func _test_blob_master_seed_redundancy() -> void:
	print("\n[AC-BLOB-2] top-level master_seed matches TimeSystem's copy exactly")
	var rig := _make_rig(987654321)
	var blob: Dictionary = rig["save_load"].call("_perform_save")
	_check(str(blob["master_seed"]) == str(blob["time_system"]["master_seed"]), "AC-BLOB-2: blob.master_seed == blob.time_system.master_seed (got %s vs %s)" % [str(blob["master_seed"]), str(blob["time_system"]["master_seed"])])
	_check(str(blob["master_seed"]) == _SRG().int64_to_hex(987654321), "AC-BLOB-2: master_seed is the seeded hex of the rig's master_seed (got %s)" % str(blob["master_seed"]))
	_check(blob["master_seed"] is String, "AC-BLOB-2: top-level master_seed is a string (JSON-safe introspection)")


func _test_blob_excluded_systems_absent() -> void:
	print("\n[AC-BLOB-3] navigation / placement_system / selection_system / zone_rules are ABSENT")
	var rig := _make_rig(6)
	var blob: Dictionary = rig["save_load"].call("_perform_save")
	for key in EXCLUDED_KEYS:
		_check(not blob.has(key), "AC-BLOB-3: no key '%s' in blob" % key)


func _test_blob_empty_state_save() -> void:
	print("\n[edge] empty-state save (all systems empty) still produces all 8 keys")
	var rig := _make_rig(1)
	for field in SPY_FIELDS:
		rig["spies"][field].set("payload", {})
	# Note: TimeSystem still serializes real state (it always has tick_count etc.).
	var blob: Dictionary = rig["save_load"].call("_perform_save")
	_check(blob.size() == 8, "empty-state save still has exactly 8 keys (got %d)" % blob.size())
	for field in SPY_FIELDS:
		_check(blob[field] is Dictionary and (blob[field] as Dictionary).is_empty(), "empty-state: key '%s' present with {} payload" % field)


func _test_blob_partial_empty_system() -> void:
	print("\n[edge] one system returning {} (partial empty) — key still exists, save still composes")
	var rig := _make_rig(3)
	rig["spies"]["economy"].set("payload", {})
	var blob: Dictionary = rig["save_load"].call("_perform_save")
	_check(blob.size() == 8, "partial-empty save still has exactly 8 keys (got %d)" % blob.size())
	_check(blob.has("economy") and (blob["economy"] as Dictionary).is_empty(), "economy key present with {} payload")
	_check(not (blob["congestion"] as Dictionary).is_empty(), "other systems' payloads untouched")


func _test_validate_blob_keys_gate() -> void:
	print("\n[gate] _validate_blob_keys() on a good blob -> zero errors; tampered blobs -> caught")
	var rig := _make_rig(42)
	var good: Dictionary = rig["save_load"].call("_perform_save")
	var errors: Array = rig["save_load"].call("_validate_blob_keys", good)
	_check(errors.is_empty(), "freshly composed blob validates with zero errors (got %s)" % str(errors))

	# Missing required key
	var missing: Dictionary = good.duplicate(true)
	missing.erase("economy")
	errors = rig["save_load"].call("_validate_blob_keys", missing)
	_check(errors.size() == 1 and str(errors[0]).find("missing required key 'economy'") != -1, "missing key flagged (got %s)" % str(errors))

	# Extra unknown key (forward-compat gate)
	var extra: Dictionary = good.duplicate(true)
	extra["future_system"] = {}
	errors = rig["save_load"].call("_validate_blob_keys", extra)
	_check(errors.size() == 1 and str(errors[0]).find("unexpected key 'future_system'") != -1, "extra unknown key flagged (got %s)" % str(errors))

	# Excluded system leaking into the blob
	var leaked: Dictionary = good.duplicate(true)
	leaked["navigation"] = {}
	errors = rig["save_load"].call("_validate_blob_keys", leaked)
	_check(errors.size() == 1 and str(errors[0]).find("this system should not serialize") != -1, "excluded system key flagged (got %s)" % str(errors))

	# Diverged top-level master_seed
	var diverged: Dictionary = good.duplicate(true)
	diverged["master_seed"] = "0x00000000000000ff"
	errors = rig["save_load"].call("_validate_blob_keys", diverged)
	_check(errors.size() == 1 and str(errors[0]).find("diverges") != -1, "diverged master_seed flagged (got %s)" % str(errors))
