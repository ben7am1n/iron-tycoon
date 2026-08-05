# tests/unit/time_system/time_serialization_test.gd
# Story TS-004: Serialization, Deserialization, and Resume Behavior
# (production/epics/time-system/story-004-serialization-deserialization.md)
#
# Covers the BLOCKING ACs:
#   - AC8   serialize() -> deserialize() into a fresh TimeSystem: tick_count,
#           master_seed, speed_multiplier, paused, and the next 100 RNG draws
#           per system are bit-identical to continuing the original instance
#   - AC9   identical master_seed to tick 1000; pause 5s vs 300s at the same
#           tick; both bit-identical through tick 2000 (pause duration is NOT
#           part of the determinism contract)
#   - AC10  save with speed_multiplier=3 / paused=false: deserialize -> paused,
#           no ticks on first _process, _last_speed preserved, resume at 3x
#   - AC16  missing one system's per_system_rng_states entry -> whole load
#           fails, nothing mutated, no re-derive-from-seed fallback
#   - AC17  missing master_seed / tick_count / per_system_rng_states -> loud
#           failure, no invented defaults
# plus:
#   - hex-boundary pin: int64_to_hex/hex_to_int64 round-trip the full range
#     (0, ±1, ±(2^62), ±(2^63-1), INT64_MIN, arbitrary negative states) — the
#     ADR-0002 "GUT test must verify round-trip for boundary values"
#   - JSON smoke: full serialize() dict survives
#     JSON.stringify(_, "\t", true, true) [sort_keys + full_precision] and
#     JSON.parse_string bit-identically (hex strings are JSON-safe)
#
# ENGINE FACTS VERIFIED BEFORE WRITING (probe run — see SeededRNG class header):
#   - "%x" % negative_int64 formats the minus AFTER the prefix ("0x-405f...")
#     and hex_to_int() REJECTS that string — the story sketch's "0x%x" would
#     corrupt any save with a high-bit RNG state. Implementation serializes
#     the UNSIGNED bit pattern via String.num_uint64(v, 16).lpad(16, "0").
#   - hex_to_int() on 4.7.1 does NOT wrap high-bit values — it errors and
#     clamps to INT64_MAX. ADR-0002's "bits preserved" claim is false; the
#     implementation parses in two halves (hi << 32) | lo.
#   - String.pad_zeros() pads DECIMAL digits (float-formatting API) — the
#     correct left-pad is String.lpad(16, "0").
#   - is_valid_hex_number(true) requires the 0x prefix and valid hex digits.
#
# Run standalone: godot --headless --script tests/unit/time_system/time_serialization_test.gd
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"

var _pass := 0
var _fail := 0

# Four tick systems registered per AC8 ("all 4 tick systems registered").
const SYSTEMS_4: Array[String] = ["MemberSim", "Congestion", "Satisfaction", "Economy"]


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
	print("  UNIT TEST: TimeSystem — Serialization / Deserialization / Resume (Story TS-004)")
	print("=".repeat(48))

	# Hex boundary pin FIRST — the canary for the whole int64 encoding pipeline.
	_test_hex_boundary_roundtrip()
	_test_hex_format_shape()
	_test_ac8_roundtrip_fidelity()
	_test_ac8_zero_ticks()
	_test_ac8_single_system()
	_test_ac8_max_safe_tick_count()
	_test_ac9_pause_duration_irrelevant()
	_test_ac9_pause_at_different_ticks()
	_test_ac9_multiple_pause_resume_cycles()
	_test_ac9_speed_change_while_paused()
	_test_ac10_load_always_paused()
	_test_ac10_blob_without_last_speed()
	_test_ac10_edges()
	_test_ac16_missing_system_rng_state()
	_test_ac16_empty_states_dict()
	_test_ac16_extra_unknown_entry_ignored()
	_test_ac17_missing_required_fields()
	_test_ac17_bad_types()
	_test_json_smoke_roundtrip()
	_test_serialize_key_contract()

	print("\n=== TIME SERIALIZATION TEST: %d passed, %d failed ===\n" % [_pass, _fail])
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


func _O() -> Script:
	return load("res://src/systems/simulation_orchestrator.gd") as Script


## Creates an initialized SimulationOrchestrator in the scene tree (delivers
## _ready() synchronously — same pattern as tick_accumulator_test.gd).
func _make_orchestrator() -> Node:
	var orch: Node = _O().new()
	root.add_child(orch)
	orch.call("_ready")
	return orch


## Builds a full serialization rig: initialized orchestrator + SeededRNG
## (master_seed set, systems registered) + a TimeSystem wired to both via
## init(orchestrator, seeded_rng) — the Story-004 DI path.
func _make_rig(master_seed: int, system_names: Array[String]) -> Dictionary:
	var orch := _make_orchestrator()
	var srg: RefCounted = _SRG().new()
	srg.call("init", master_seed)
	for name in system_names:
		srg.call("register_system", name)
	var ts: RefCounted = _TS().new()
	ts.call("init", orch, srg)
	return {"orchestrator": orch, "seeded_rng": srg, "time_system": ts}


## Advances the rig's TimeSystem by exactly `ticks` ticks at 1x using
## process(0.1) frames (each fires exactly 1 tick, accumulator returns to
## 0.0 — verified by TS-002 AC1). While at it, consumes one draw per
## registered system per tick, mimicking real on_tick() RNG usage.
func _advance_with_draws(rig: Dictionary, ticks: int) -> void:
	var ts: RefCounted = rig["time_system"]
	var srg: RefCounted = rig["seeded_rng"]
	var names := _registered_names(srg)
	for i in ticks:
		ts.call("process", 0.1)
		for name in names:
			(srg.call("get_rng", name) as RandomNumberGenerator).randi()


## Captures the next `count` draws from every registered system.
func _draws(rig: Dictionary, count: int) -> Dictionary:
	var srg: RefCounted = rig["seeded_rng"]
	var out := {}
	for name in _registered_names(srg):
		var seq: Array[int] = []
		for i in count:
			seq.append((srg.call("get_rng", name) as RandomNumberGenerator).randi())
		out[name] = seq
	return out


## Names actually registered in the rig's SeededRNG (reads the private
## _streams dict directly — calling get_rng() for an unregistered name would
## push_error, polluting the test log in single-system rigs).
func _registered_names(srg: RefCounted) -> Array:
	return (srg.get("_streams") as Dictionary).keys()


## True iff any deserialize error message contains `fragment`.
## NOTE: str(Array[String]) escapes quotes (' -> \'), so whole-array string
## search for quoted fragments FAILS — iterate elements (raw strings) instead.
func _has_error(res: RefCounted, fragment: String) -> bool:
	for err in (res.get("errors") as Array):
		if str(err).find(fragment) != -1:
			return true
	return false


# === Hex boundary pin (canary — runs FIRST) ===

func _test_hex_boundary_roundtrip() -> void:
	print("\n[hex boundary] int64_to_hex/hex_to_int64 round-trip the full int64 range")
	var values: Array[int] = [
		0, 1, -1, 12345, -12345,
		1 << 62, -(1 << 62),
		(1 << 63) - 1,  # INT64_MAX
		-(1 << 63),     # INT64_MIN
		-4638512521074034849,  # arbitrary high-bit negative (probe-verified state)
	]
	for v in values:
		var hx: String = _SRG().int64_to_hex(v)
		var back: int = _SRG().hex_to_int64(hx)
		_check(back == v, "int64_to_hex(%d) -> '%s' -> hex_to_int64 -> %d (round-trip)" % [v, hx, back])


func _test_hex_format_shape() -> void:
	print("\n[hex format] every serialized int64 is '0x' + exactly 16 lowercase hex digits, no sign char")
	for v in [0, -1, 12345, -4638512521074034849]:
		var hx: String = _SRG().int64_to_hex(v)
		_check(hx.begins_with("0x"), "prefix '0x' present for %d (got '%s')" % [v, hx])
		_check(hx.length() == 18, "length == 18 ('0x' + 16 digits) for %d (got '%s' len %d)" % [v, hx, hx.length()])
		_check(hx.find("-") == -1, "no minus sign in '%s'" % hx)
		_check(hx.is_valid_hex_number(true), "'%s' is a valid 0x-prefixed hex number" % hx)


# === AC8: round-trip fidelity ===

func _test_ac8_roundtrip_fidelity() -> void:
	print("\n[AC8] sim at tick 500, 4 systems, draws consumed -> serialize -> fresh rig -> deserialize -> next 100 draws identical")
	var orig := _make_rig(12345, SYSTEMS_4)
	var ts_orig: RefCounted = orig["time_system"]
	ts_orig.call("resume")
	_advance_with_draws(orig, 500)   # 500 ticks at 1x (each process(0.1) fires exactly 1)
	ts_orig.call("set_speed", 3)     # run at 3x so the save carries speed=3 (no ticks fired by set_speed)

	var data: Dictionary = ts_orig.call("serialize")
	_check(int(data["tick_count"]) == 500, "serialized tick_count == 500 (got %d)" % int(data["tick_count"]))
	_check(str(data["master_seed"]) == _SRG().int64_to_hex(12345), "serialized master_seed hex matches seed 12345")
	var states: Dictionary = data["per_system_rng_states"]
	_check(states.size() == 4, "per_system_rng_states has all 4 systems (got %d)" % states.size())
	for name in SYSTEMS_4:
		_check(states.has(name) and str(states[name]).is_valid_hex_number(true), "state entry for '%s' is a hex string" % name)
	_check(int(data["speed_multiplier"]) == 3, "serialized speed_multiplier == 3 (got %d)" % int(data["speed_multiplier"]))
	_check(bool(data["paused"]) == false, "serialized paused == false while running (got %s)" % data["paused"])

	# Fresh rig with SAME registered systems, deserialize.
	var fresh := _make_rig(999, SYSTEMS_4)  # arbitrary master_seed — deserialize must overwrite
	var ts_fresh: RefCounted = fresh["time_system"]
	var res: RefCounted = ts_fresh.call("deserialize", data)
	_check(bool(res.get("ok")) == true, "deserialize returned ok (errors: %s)" % str(res.get("errors")))

	_check(int(ts_fresh.call("get_tick_count")) == 500, "restored tick_count == 500 (got %d)" % int(ts_fresh.call("get_tick_count")))
	_check(int(fresh["seeded_rng"].get("master_seed")) == 12345, "restored master_seed == 12345 (got %d)" % int(fresh["seeded_rng"].get("master_seed")))
	_check(bool(ts_fresh.call("is_paused")) == true, "load always resumes PAUSED (Core Rule 9)")
	_check(int(ts_fresh.call("get_speed_multiplier")) == 0, "speed_multiplier == 0 after load (got %d)" % int(ts_fresh.call("get_speed_multiplier")))
	_check(int(ts_fresh.get("_last_speed")) == 3, "_last_speed preserved as 3 (got %d)" % int(ts_fresh.get("_last_speed")))

	# Next 100 draws per system: continuing the ORIGINAL vs the RESTORED.
	var orig_draws := _draws(orig, 100)
	var fresh_draws := _draws(fresh, 100)
	for name in SYSTEMS_4:
		var a: Array = orig_draws[name]
		var b: Array = fresh_draws[name]
		_check(a == b, "next 100 draws for '%s' bit-identical (orig==restored)" % name)

	# Draw-count-agnostic direct check: one more immediate draw per system.
	for name in SYSTEMS_4:
		var srg_orig: RefCounted = orig["seeded_rng"]
		var srg_fresh: RefCounted = fresh["seeded_rng"]
		_check(srg_orig.get_rng(name).randi() == srg_fresh.get_rng(name).randi(), "immediate next draw for '%s' identical" % name)


func _test_ac8_zero_ticks() -> void:
	print("\n[AC8 edge] fresh sim (0 ticks, no draws) round-trips")
	var orig := _make_rig(777, SYSTEMS_4)
	var data: Dictionary = orig["time_system"].call("serialize")
	_check(int(data["tick_count"]) == 0, "serialized tick_count == 0")
	var fresh := _make_rig(1, SYSTEMS_4)
	var res: RefCounted = fresh["time_system"].call("deserialize", data)
	_check(bool(res.get("ok")) == true, "deserialize ok")
	_check(int(fresh["time_system"].call("get_tick_count")) == 0, "restored tick_count == 0")
	var o: Array = _draws(orig, 10)["MemberSim"]
	var f: Array = _draws(fresh, 10)["MemberSim"]
	_check(o == f, "10 draws after 0-tick round-trip identical")


func _test_ac8_single_system() -> void:
	print("\n[AC8 edge] only 1 registered system round-trips")
	var orig := _make_rig(4242, ["Economy"])
	orig["time_system"].call("resume")
	_advance_with_draws(orig, 100)
	var data: Dictionary = orig["time_system"].call("serialize")
	_check((data["per_system_rng_states"] as Dictionary).size() == 1, "exactly 1 state entry")
	var fresh := _make_rig(7, ["Economy"])
	var res: RefCounted = fresh["time_system"].call("deserialize", data)
	_check(bool(res.get("ok")) == true, "deserialize ok with single system")
	_check(_draws(orig, 50)["Economy"] == _draws(fresh, 50)["Economy"], "50 draws identical with single system")


func _test_ac8_max_safe_tick_count() -> void:
	print("\n[AC8 edge] tick_count at max JSON-safe int (2^53 - 1) round-trips")
	var orig := _make_rig(5, SYSTEMS_4)
	var data: Dictionary = orig["time_system"].call("serialize")
	data["tick_count"] = (1 << 53) - 1  # 9007199254740991 — max safe JSON number
	var fresh := _make_rig(5, SYSTEMS_4)
	var res: RefCounted = fresh["time_system"].call("deserialize", data)
	_check(bool(res.get("ok")) == true, "deserialize ok at max safe tick_count")
	_check(int(fresh["time_system"].call("get_tick_count")) == (1 << 53) - 1, "restored tick_count == 2^53-1 (got %d)" % int(fresh["time_system"].call("get_tick_count")))


# === AC9: pause duration is NOT part of the determinism contract ===

func _test_ac9_pause_duration_irrelevant() -> void:
	print("\n[AC9] same seed to tick 1000; pause 5s (A) vs 300s (B); both to tick 2000 — bit-identical")
	var a := _make_rig(2024, SYSTEMS_4)
	var b := _make_rig(2024, SYSTEMS_4)
	for rig in [a, b]:
		rig["time_system"].call("resume")
	_advance_with_draws(a, 1000)
	_advance_with_draws(b, 1000)

	a["time_system"].call("pause")
	a["time_system"].call("process", 5.0)   # 5 real seconds paused (early return, no ticks)
	a["time_system"].call("resume")
	b["time_system"].call("pause")
	b["time_system"].call("process", 300.0)  # 300 real seconds paused
	b["time_system"].call("resume")

	_advance_with_draws(a, 1000)  # ticks 1001..2000
	_advance_with_draws(b, 1000)

	var sa: Dictionary = a["time_system"].call("serialize")
	var sb: Dictionary = b["time_system"].call("serialize")
	_check(int(sa["tick_count"]) == 2000 and int(sb["tick_count"]) == 2000, "both at tick 2000 (A=%d B=%d)" % [int(sa["tick_count"]), int(sb["tick_count"])])
	_check(sa["per_system_rng_states"] == sb["per_system_rng_states"], "per-system RNG states bit-identical after 5s vs 300s pause")
	_check(str(sa["master_seed"]) == str(sb["master_seed"]), "master_seed identical")
	_check(float(sa["tick_accumulator"]) == float(sb["tick_accumulator"]), "accumulator values identical")


func _test_ac9_pause_at_different_ticks() -> void:
	print("\n[AC9 edge] pause at different tick counts (A: 500, B: 1500) — still identical at 2000")
	var a := _make_rig(31337, SYSTEMS_4)
	var b := _make_rig(31337, SYSTEMS_4)
	for rig in [a, b]:
		rig["time_system"].call("resume")
	_advance_with_draws(a, 500)
	_advance_with_draws(b, 1500)
	a["time_system"].call("pause")
	a["time_system"].call("process", 5.0)
	a["time_system"].call("resume")
	b["time_system"].call("pause")
	b["time_system"].call("process", 300.0)
	b["time_system"].call("resume")
	_advance_with_draws(a, 1500)
	_advance_with_draws(b, 500)
	var sa: Dictionary = a["time_system"].call("serialize")
	var sb: Dictionary = b["time_system"].call("serialize")
	_check(int(sa["tick_count"]) == 2000 and int(sb["tick_count"]) == 2000, "both at tick 2000")
	_check(sa["per_system_rng_states"] == sb["per_system_rng_states"], "RNG states identical (pause at different ticks)")
	_check(float(sa["tick_accumulator"]) == float(sb["tick_accumulator"]), "accumulator identical")


func _test_ac9_multiple_pause_resume_cycles() -> void:
	print("\n[AC9 edge] multiple pause/resume cycles vs no pause — identical at 2000")
	var a := _make_rig(99991, SYSTEMS_4)  # never pauses
	var b := _make_rig(99991, SYSTEMS_4)  # pauses/resumes 4 times
	for rig in [a, b]:
		rig["time_system"].call("resume")
	var pause_points: Array[int] = [100, 400, 700, 1200]
	var ticks_done := 0
	for pp in pause_points:
		_advance_with_draws(b, pp - ticks_done)
		ticks_done = pp
		b["time_system"].call("pause")
		b["time_system"].call("process", 2.0)
		b["time_system"].call("resume")
	_advance_with_draws(b, 2000 - ticks_done)
	_advance_with_draws(a, 2000)
	var sa: Dictionary = a["time_system"].call("serialize")
	var sb: Dictionary = b["time_system"].call("serialize")
	_check(sa["per_system_rng_states"] == sb["per_system_rng_states"], "RNG states identical after 4 pause/resume cycles")
	_check(float(sa["tick_accumulator"]) == float(sb["tick_accumulator"]), "accumulator identical")


func _test_ac9_speed_change_while_paused() -> void:
	print("\n[AC9 edge] speed change WHILE paused — tick sequence + RNG states identical at equal tick counts")
	var a := _make_rig(555, SYSTEMS_4)  # pause, change speed to 3, resume
	var b := _make_rig(555, SYSTEMS_4)  # plain resume at 1x
	for rig in [a, b]:
		rig["time_system"].call("resume")
	_advance_with_draws(a, 1000)
	_advance_with_draws(b, 1000)
	a["time_system"].call("pause")
	a["time_system"].call("set_speed", 3)  # selection recorded; stays paused (GDD state machine)
	a["time_system"].call("resume")
	b["time_system"].call("resume")
	# A now runs at 3x (each process(0.1) fires exactly 3 ticks — 0.1*3/0.1=3,
	# remainder exactly 0.0), B at 1x (1 tick per frame). Drive both to the
	# SAME tick count (334 frames for A = 1002 ticks from 1000; 1002 frames
	# for B = 1002 ticks), drawing once PER TICK per system so the draw-per-
	# tick alignment matches between runs. Speed changes wall-clock cadence,
	# never the tick sequence — at any equal tick count the RNG states must
	# be identical.
	var target_ticks := 2002
	for i in 334:
		a["time_system"].call("process", 0.1)  # fires exactly 3 ticks
		for _t in 3:
			for name in SYSTEMS_4:
				a["seeded_rng"].call("get_rng", name).randi()
	for i in 1002:
		b["time_system"].call("process", 0.1)  # fires exactly 1 tick
		for name in SYSTEMS_4:
			b["seeded_rng"].call("get_rng", name).randi()
	var sa: Dictionary = a["time_system"].call("serialize")
	var sb: Dictionary = b["time_system"].call("serialize")
	_check(int(sa["tick_count"]) == target_ticks and int(sb["tick_count"]) == target_ticks, "both at tick %d (A=%d B=%d)" % [target_ticks, int(sa["tick_count"]), int(sb["tick_count"])])
	_check(sa["per_system_rng_states"] == sb["per_system_rng_states"], "RNG states identical (speed change while paused)")
	_check(int(a["time_system"].get("_last_speed")) == 3, "A's _last_speed == 3 (speed selection recorded while paused)")


# === AC10: load always resumes PAUSED ===

func _test_ac10_load_always_paused() -> void:
	print("\n[AC10] save with speed_multiplier=3, paused=false -> load -> paused, 0 ticks, resume at 3x")
	var orig := _make_rig(7777, SYSTEMS_4)
	orig["time_system"].call("set_speed", 3)
	orig["time_system"].call("resume")
	_advance_with_draws(orig, 50)
	var data: Dictionary = orig["time_system"].call("serialize")
	# Blob deliberately says RUNNING at 3x — the load must ignore both.
	_check(int(data["speed_multiplier"]) == 3, "save blob carries speed_multiplier=3")
	_check(bool(data["paused"]) == false, "save blob carries paused=false")

	var fresh := _make_rig(1, SYSTEMS_4)
	var res: RefCounted = fresh["time_system"].call("deserialize", data)
	_check(bool(res.get("ok")) == true, "deserialize ok")
	var ts: RefCounted = fresh["time_system"]
	_check(bool(ts.call("is_paused")) == true, "paused == true immediately after deserialize")
	_check(int(ts.call("get_speed_multiplier")) == 0, "speed_multiplier == 0 after load")
	_check(int(ts.get("_last_speed")) == 3, "_last_speed == 3 preserved")

	# First _process frame: 0 ticks fire.
	var before: int = int(ts.call("get_tick_count"))
	ts.call("process", 1.0)
	_check(int(ts.call("get_tick_count")) == before, "no ticks fire during first _process (Core Rule 9)")

	# Resume -> proceeds at speed 3.
	ts.call("resume")
	var resumed_at: int = int(ts.call("get_speed_multiplier"))
	_check(resumed_at == 3, "resume() restores speed 3 (got %d)" % resumed_at)


func _test_ac10_blob_without_last_speed() -> void:
	print("\n[AC10 edge] hand-crafted blob with speed_multiplier=3, paused=false, NO _last_speed key -> _last_speed falls back to 3")
	var data: Dictionary = {
		"tick_count": 42,
		"tick_accumulator": 0.0,
		"speed_multiplier": 3,
		"paused": false,
		# NOTE: '_last_speed' deliberately omitted — the QA AC10 blob is
		# specified as "save blob with speed_multiplier=3, paused=false";
		# deserialize must derive _last_speed from the saved speed.
		"master_seed": _SRG().int64_to_hex(777),
		"per_system_rng_states": _serialized_states_for(777),
	}
	var fresh := _make_rig(1, SYSTEMS_4)
	var res: RefCounted = fresh["time_system"].call("deserialize", data)
	_check(bool(res.get("ok")) == true, "deserialize ok (errors: %s)" % str(res.get("errors")))
	var ts: RefCounted = fresh["time_system"]
	_check(bool(ts.call("is_paused")) == true, "paused == true immediately after deserialize")
	_check(int(ts.call("get_speed_multiplier")) == 0, "speed_multiplier == 0 after load")
	_check(int(ts.get("_last_speed")) == 3, "_last_speed falls back to saved speed 3 (got %d)" % int(ts.get("_last_speed")))
	ts.call("resume")
	_check(int(ts.call("get_speed_multiplier")) == 3, "resume() proceeds at speed 3 (got %d)" % int(ts.call("get_speed_multiplier")))


## Returns a valid per_system_rng_states dict for a fresh rig of the given
## seed (each system's RNG at its initial, pre-draw state). Used by the
## hand-crafted-blob tests that must NOT depend on a prior serialize().
func _serialized_states_for(master_seed: int) -> Dictionary:
	var srg: RefCounted = _SRG().new()
	srg.call("init", master_seed)
	for name in SYSTEMS_4:
		srg.call("register_system", name)
	var states := {}
	for name in SYSTEMS_4:
		states[name] = _SRG().int64_to_hex(int((srg.call("get_rng", name) as RandomNumberGenerator).state))
	return states


func _test_ac10_edges() -> void:
	print("\n[AC10 edge] saved speed=0 paused=true stays paused; saved speed=1 paused=true -> last_speed=1")
	# speed=0 / paused=true blob
	var rig0 := _make_rig(11, SYSTEMS_4)
	rig0["time_system"].call("pause")  # paused, speed=0
	var data0: Dictionary = rig0["time_system"].call("serialize")
	var f0 := _make_rig(2, SYSTEMS_4)
	var r0: RefCounted = f0["time_system"].call("deserialize", data0)
	_check(bool(r0.get("ok")) == true, "deserialize ok for paused save")
	_check(bool(f0["time_system"].call("is_paused")) == true, "stays paused after load of paused save")
	_check(int(f0["time_system"].call("get_speed_multiplier")) == 0, "speed_multiplier == 0")
	f0["time_system"].call("resume")
	# _last_speed was 0 (never set >0) -> resume defaults to 1x
	_check(int(f0["time_system"].call("get_speed_multiplier")) == 1, "resume from paused-save defaults to 1x")

	# speed=1 / paused=true blob -> _last_speed == 1
	var rig1 := _make_rig(13, SYSTEMS_4)
	rig1["time_system"].call("set_speed", 1)
	rig1["time_system"].call("resume")
	_advance_with_draws(rig1, 5)
	rig1["time_system"].call("pause")
	var data1: Dictionary = rig1["time_system"].call("serialize")
	var f1 := _make_rig(3, SYSTEMS_4)
	var r1: RefCounted = f1["time_system"].call("deserialize", data1)
	_check(bool(r1.get("ok")) == true, "deserialize ok for speed=1 paused save")
	_check(int(f1["time_system"].get("_last_speed")) == 1, "last_speed == 1 (got %d)" % int(f1["time_system"].get("_last_speed")))
	_check(bool(f1["time_system"].call("is_paused")) == true, "still paused")


# === AC16: missing per-system RNG state -> whole load fails ===

func _test_ac16_missing_system_rng_state() -> void:
	print("\n[AC16] blob missing 'Economy' state (Economy registered) -> whole load fails, nothing mutated")
	var orig := _make_rig(8080, SYSTEMS_4)
	orig["time_system"].call("resume")
	_advance_with_draws(orig, 200)
	var data: Dictionary = orig["time_system"].call("serialize")
	(data["per_system_rng_states"] as Dictionary).erase("Economy")

	var fresh := _make_rig(1, SYSTEMS_4)  # registers all 4 including Economy
	# Snapshot state BEFORE the failed load.
	var pre_tick: int = int(fresh["time_system"].call("get_tick_count"))
	var pre_states := {}
	for name in SYSTEMS_4:
		pre_states[name] = int((fresh["seeded_rng"].call("get_rng", name) as RandomNumberGenerator).state)

	var res: RefCounted = fresh["time_system"].call("deserialize", data)
	_check(bool(res.get("ok")) == false, "deserialize failed (ok == false)")
	_check(_has_error(res, "missing RNG state for system 'Economy'"), "errors include missing-Economy message (got %s)" % str(res.get("errors")))
	_check(int(fresh["time_system"].call("get_tick_count")) == pre_tick, "tick_count unchanged after failed load")
	_check(int(fresh["seeded_rng"].get("master_seed")) == 1, "master_seed unchanged (no re-derive, no commit)")
	for name in SYSTEMS_4:
		var after: int = int((fresh["seeded_rng"].call("get_rng", name) as RandomNumberGenerator).state)
		_check(after == pre_states[name], "RNG state for '%s' untouched after failed load" % name)


func _test_ac16_empty_states_dict() -> void:
	print("\n[AC16 edge] empty per_system_rng_states {} -> fails (every registered system missing)")
	var orig := _make_rig(99, SYSTEMS_4)
	orig["time_system"].call("resume")
	_advance_with_draws(orig, 10)
	var data: Dictionary = orig["time_system"].call("serialize")
	data["per_system_rng_states"] = {}
	var fresh := _make_rig(1, SYSTEMS_4)
	var res: RefCounted = fresh["time_system"].call("deserialize", data)
	_check(bool(res.get("ok")) == false, "deserialize failed with empty states dict")
	var missing_count := 0
	for err in (res.get("errors") as Array):
		for name in SYSTEMS_4:
			if str(err).find("missing RNG state for system '%s'" % name) != -1:
				missing_count += 1
	_check(missing_count == 4, "all 4 registered systems reported missing (got %d)" % missing_count)


func _test_ac16_extra_unknown_entry_ignored() -> void:
	print("\n[AC16 edge] extra unknown system entry in states -> IGNORED, load succeeds (validates registered set, not dict keys)")
	var orig := _make_rig(5555, SYSTEMS_4)
	orig["time_system"].call("resume")
	_advance_with_draws(orig, 30)
	var data: Dictionary = orig["time_system"].call("serialize")
	(data["per_system_rng_states"] as Dictionary)["BogusSystem"] = "0x1234567890abcdef"
	var fresh := _make_rig(1, SYSTEMS_4)
	var res: RefCounted = fresh["time_system"].call("deserialize", data)
	_check(bool(res.get("ok")) == true, "deserialize ok with extra unknown entry (got errors %s)" % str(res.get("errors")))
	_check(_draws(orig, 20)["MemberSim"] == _draws(fresh, 20)["MemberSim"], "draws still identical (extra entry ignored)")


# === AC17: missing required fields -> loud failure, no invented defaults ===

func _test_ac17_missing_required_fields() -> void:
	print("\n[AC17] missing master_seed / tick_count / per_system_rng_states -> loud failure, no mutation")
	var base := _make_rig(31415, SYSTEMS_4)
	base["time_system"].call("resume")
	_advance_with_draws(base, 10)
	var data: Dictionary = base["time_system"].call("serialize")

	# missing master_seed
	var d1: Dictionary = data.duplicate(true)
	d1.erase("master_seed")
	var f1 := _make_rig(1, SYSTEMS_4)
	var r1: RefCounted = f1["time_system"].call("deserialize", d1)
	_check(bool(r1.get("ok")) == false, "missing master_seed -> fail")
	_check(_has_error(r1, "missing or invalid 'master_seed'"), "errors include master_seed message (got %s)" % str(r1.get("errors")))

	# missing tick_count
	var d2: Dictionary = data.duplicate(true)
	d2.erase("tick_count")
	var f2 := _make_rig(1, SYSTEMS_4)
	var r2: RefCounted = f2["time_system"].call("deserialize", d2)
	_check(bool(r2.get("ok")) == false, "missing tick_count -> fail")
	_check(_has_error(r2, "missing or invalid 'tick_count'"), "errors include tick_count message")

	# missing per_system_rng_states
	var d3: Dictionary = data.duplicate(true)
	d3.erase("per_system_rng_states")
	var f3 := _make_rig(1, SYSTEMS_4)
	var r3: RefCounted = f3["time_system"].call("deserialize", d3)
	_check(bool(r3.get("ok")) == false, "missing per_system_rng_states -> fail")
	_check(_has_error(r3, "missing or invalid 'per_system_rng_states'"), "errors include per_system_rng_states message")

	# nothing mutated on ANY of the failed loads
	for rig in [f1, f2, f3]:
		_check(int(rig["time_system"].call("get_tick_count")) == 0, "tick_count unchanged after failed load")
		_check(int(rig["seeded_rng"].get("master_seed")) == 1, "master_seed unchanged after failed load")


func _test_ac17_bad_types() -> void:
	print("\n[AC17 edge] master_seed=null / tick_count='string' / wrong types -> fail loudly")
	var base := _make_rig(2718, SYSTEMS_4)
	var data: Dictionary = base["time_system"].call("serialize")

	var d1: Dictionary = data.duplicate(true)
	d1["master_seed"] = null
	var f1 := _make_rig(1, SYSTEMS_4)
	var r1: RefCounted = f1["time_system"].call("deserialize", d1)
	_check(bool(r1.get("ok")) == false, "master_seed=null -> fail")
	_check(_has_error(r1, "missing or invalid 'master_seed'"), "master_seed=null reports missing-or-invalid")

	var d2: Dictionary = data.duplicate(true)
	d2["tick_count"] = "500"
	var f2 := _make_rig(1, SYSTEMS_4)
	var r2: RefCounted = f2["time_system"].call("deserialize", d2)
	_check(bool(r2.get("ok")) == false, "tick_count='string' -> fail")
	_check(_has_error(r2, "missing or invalid 'tick_count'"), "tick_count string reports missing-or-invalid")

	var d3: Dictionary = data.duplicate(true)
	d3["per_system_rng_states"] = "not-a-dict"
	var f3 := _make_rig(1, SYSTEMS_4)
	var r3: RefCounted = f3["time_system"].call("deserialize", d3)
	_check(bool(r3.get("ok")) == false, "per_system_rng_states=string -> fail")

	var d4: Dictionary = data.duplicate(true)
	d4["master_seed"] = "3039"  # no 0x prefix
	var f4 := _make_rig(1, SYSTEMS_4)
	var r4: RefCounted = f4["time_system"].call("deserialize", d4)
	_check(bool(r4.get("ok")) == false, "master_seed without 0x prefix -> fail")


# === JSON smoke: hex strings survive JSON.stringify(full_precision) + parse ===

func _test_json_smoke_roundtrip() -> void:
	print("\n[JSON smoke] serialize() dict -> JSON.stringify(_, '\\t', true, true) -> parse_string -> deserialize ok")
	var orig := _make_rig(86420, SYSTEMS_4)
	orig["time_system"].call("resume")
	_advance_with_draws(orig, 300)
	var data: Dictionary = orig["time_system"].call("serialize")
	var json_str: String = JSON.stringify(data, "	", true, true)  # sort_keys + full_precision
	var parsed: Variant = JSON.parse_string(json_str)
	_check(parsed is Dictionary, "JSON.parse_string returned a Dictionary")
	# ENGINE FACT: Godot's JSON parser returns ALL numbers as float (int 300 ->
	# 300.0), so Dictionary == would be false even though the hex strings and
	# semantics round-trip. This is the SaveLoad layer's normalization concern
	# (JSON encoding lives there per story Out of Scope); the smoke test below
	# proves the hex-string payload survives JSON byte-identically.
	var pd: Dictionary = parsed
	_check(str(pd["master_seed"]) == str(data["master_seed"]), "master_seed hex string survives JSON")
	_check(str(pd["per_system_rng_states"]["Economy"]) == str(data["per_system_rng_states"]["Economy"]), "RNG state hex string survives JSON")
	# Feed the JSON-parsed blob to deserialize: tick_count arrives as float
	# (300.0) — the strict TYPE_INT check would reject it. The story's
	# deserialize contract consumes native Dictionaries; SaveLoad normalizes
	# JSON floats back to ints. Emulate that normalization here:
	var normalized: Dictionary = pd.duplicate(true)
	normalized["tick_count"] = int(pd["tick_count"])
	normalized["speed_multiplier"] = int(pd["speed_multiplier"])
	normalized["_last_speed"] = int(pd["_last_speed"])
	var fresh := _make_rig(1, SYSTEMS_4)
	var res: RefCounted = fresh["time_system"].call("deserialize", normalized)
	_check(bool(res.get("ok")) == true, "deserialize from JSON-parsed blob ok")
	_check(_draws(orig, 50)["Economy"] == _draws(fresh, 50)["Economy"], "50 draws after JSON round-trip identical")


# === Serialize key contract (TR-TS-008) ===

func _test_serialize_key_contract() -> void:
	print("\n[TR-TS-008] serialize() output contains the full required key set")
	var rig := _make_rig(42, SYSTEMS_4)
	rig["time_system"].call("resume")
	_advance_with_draws(rig, 5)
	var data: Dictionary = rig["time_system"].call("serialize")
	for key in ["tick_count", "tick_accumulator", "speed_multiplier", "paused", "_last_speed", "master_seed", "per_system_rng_states"]:
		_check(data.has(key), "serialize() includes key '%s'" % key)
	_check(data.size() == 7, "serialize() has exactly the 7 documented keys (got %d: %s)" % [data.size(), data.keys()])
	# serialization must be pure: two calls produce identical output
	var again: Dictionary = rig["time_system"].call("serialize")
	_check(again == data, "serialize() is pure (two calls identical, no draws consumed)")