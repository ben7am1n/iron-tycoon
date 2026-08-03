# tests/unit/congestion/serialization_test.gd
# Story CG-004: Determinism and Serialization
# (production/epics/congestion/story-004-determinism-serialization.md)
#
# BLOCKING ACs covered (TR-CONG-008 / GDD Core Rule 7):
#   AC14 GIVEN a save at tick t with prev + per-cell smoothed, WHEN loaded
#        and MemberSim runs at t+1, THEN MemberSim's read matches pre-save
#        prev bit-for-bit, and access_reachable is recomputed from the
#        loaded grid (not deserialized).
#        Edge cases (QA): float precision — smoothed values round-trip
#        bit-exact through JSON.full_precision; load at tick boundary only.
#
# Plus (story contract surface):
#   - serialize() shape: {counter, rng_state, prev, smoothed_cells} ONLY —
#     next / access_reachable / raw_cells / density_cells are NOT in the
#     payload (Core Rule 7: next transient, access_reachable grid-derived,
#     density derived from smoothed)
#   - two-phase deserialize: Phase A validates zero-mutation, Phase B
#     commits; validate_only=true never mutates
#   - JSON-safe shapes: keys may be int|float|numeric string (JSON.parse
#     stringifies Dictionary keys), values int|float — normalized to int
#     keys + float values on commit
#   - corrupt payloads fail Phase A loudly (missing/wrong-type fields)
#   - serialize() is side-effect free and deterministic (two calls -> equal)
#
# Run standalone: godot --headless --script tests/unit/congestion/serialization_test.gd
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"

const GRID_W := 10
const GRID_H := 8
const R0 := 0
const ENTRANCE := Vector2i(0, 0)

var _pass := 0
var _fail := 0


func _init() -> void:
	if Engine.has_meta(RUNNER_META):
		return
	var result := run_all()
	quit(1 if int(result["fail"]) > 0 else 0)


func run_all() -> Dictionary:
	print("=".repeat(48))
	print("  UNIT TEST: Congestion — Serialization (Story CG-004)")
	print("=".repeat(48))

	_test_ac14_roundtrip_prev_and_smoothed_bit_exact()
	_test_ac14_member_sim_reads_prev_after_load()
	_test_ac14_access_reachable_recomputed_not_deserialized()
	_test_ac14_json_full_precision_roundtrip()
	_test_hex_float_encoding_roundtrip()
	_test_serialize_shape_excludes_transient_and_grid_state()
	_test_serialize_side_effect_free_deterministic()
	_test_two_phase_validate_only_no_mutation()
	_test_corrupt_payloads_fail_phase_a()
	_test_prewiring_contract_shape_preserved()

	print("\n=== SERIALIZATION TEST: %d passed, %d failed ===\n" % [_pass, _fail])
	return {"pass": _pass, "fail": _fail}


func _check(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
		print("  PASS: " + msg)
	else:
		_fail += 1
		print("  FAIL: " + msg)


# === Helpers ===

func _GS() -> Script:
	return load("res://src/systems/grid_system.gd") as Script


func _MS() -> Script:
	return load("res://src/systems/member_sim.gd") as Script


func _SRG() -> Script:
	return load("res://src/systems/seeded_rng.gd") as Script


func _NAV() -> Script:
	return load("res://src/systems/navigation.gd") as Script


func _make_orchestrator() -> Node:
	var orch: Node = load("res://src/systems/simulation_orchestrator.gd").new()
	root.add_child(orch)
	orch.call("_ready")
	return orch


## Real GridSystem: GRID_W x GRID_H all buildable, frozen, with the given
## equipment committed. Each entry: {id, fp: Vector2i, ac: Vector2i}.
func _make_grid(equipment: Array) -> RefCounted:
	var gs: RefCounted = _GS().new()
	gs.call("init", GRID_W, GRID_H)
	for y in GRID_H:
		for x in GRID_W:
			gs.call("set_buildable", Vector2i(x, y), true)
	gs.call("freeze_buildable")
	for eq in equipment:
		_commit(gs, int(eq["id"]), eq["fp"], eq["ac"])
	return gs


func _commit(gs: RefCounted, id: int, fp: Vector2i, ac: Vector2i) -> void:
	var fp_arr: Array[Vector2i] = [fp]
	var ac_arr: Array[Vector2i] = [ac]
	gs.call("commit", id, fp_arr, ac_arr, R0)


func _clear(gs: RefCounted, id: int) -> void:
	gs.call("clear", id)


func _make_member_sim() -> RefCounted:
	return _MS().new()


func _make_real_navigation(gs: RefCounted) -> RefCounted:
	var nav: RefCounted = _NAV().new()
	nav.call("init", gs)
	nav.call("_post_init")
	return nav


## Fully configured rig (grid + member_sim + navigation + entrance +
## _post_init) — the REAL orchestrator wiring story-004 targets.
func _make_congestion(gs: RefCounted, ms: RefCounted, nav: RefCounted) -> Dictionary:
	var srg: RefCounted = _SRG().new()
	srg.call("init", 0x5E4A14CE)
	var orch := _make_orchestrator()
	var cong: RefCounted = (load("res://src/systems/congestion.gd") as Script).new()
	cong.call("init", orch, srg, gs, ms, {}, nav, ENTRANCE)
	cong.call("_post_init")
	return {"congestion": cong, "seeded_rng": srg, "orchestrator": orch, "member_sim": ms, "grid_system": gs}


func _member(member_id: int, state: String, cell: Vector2i) -> Dictionary:
	return {"member_id": member_id, "state": state, "cell": cell}


## Drives a fixed 4-tick member-state sequence so prev + smoothed_cells
## populate with non-trivial values. Returns the rig.
func _populate(gs: RefCounted, ms: RefCounted, nav: RefCounted) -> Dictionary:
	var rig := _make_congestion(gs, ms, nav)
	var cong: RefCounted = rig["congestion"]
	ms.set("members", [_member(10, "USING", Vector2i(3, 2)), _member(11, "WALKING_TO", Vector2i(4, 3))])
	ms.set("reservations", {1: {"occupant": 10}})
	cong.call("on_tick", 0)
	ms.set("members", [_member(10, "USING", Vector2i(3, 2)), _member(11, "QUEUEING", Vector2i(6, 2)),
		_member(12, "USING", Vector2i(3, 2))])
	ms.set("reservations", {1: {"occupant": 10, "next_claimant": 11}})
	cong.call("on_tick", 1)
	ms.set("members", [_member(10, "USING", Vector2i(6, 2)), _member(11, "WALKING_TO", Vector2i(5, 2)),
		_member(12, "USING", Vector2i(3, 2))])
	ms.set("reservations", {2: {"occupant": 10}, 1: {"occupant": 12}})
	cong.call("on_tick", 2)
	ms.set("members", [_member(10, "WALKING_TO", Vector2i(7, 2)), _member(12, "USING", Vector2i(3, 2)),
		_member(13, "WALKING_TO", Vector2i(3, 5))])
	ms.set("reservations", {1: {"occupant": 12}})
	cong.call("on_tick", 3)
	return rig


## The exact blob-level JSON encoding SaveLoad writes (ADR-0002 §6):
## indent 2, sort_keys, full_precision=true — bit-exact float round-trip.
func _blob_json(blob: Dictionary) -> String:
	return JSON.stringify(blob, "  ", true, true)


# === AC14: round-trip prev + smoothed bit-exact ===

func _test_ac14_roundtrip_prev_and_smoothed_bit_exact() -> void:
	print("\n[AC14] serialize(prev+smoothed) -> JSON full_precision -> deserialize into fresh rig -> bit-identical")
	var equipment: Array = [
		{"id": 1, "fp": Vector2i(2, 2), "ac": Vector2i(3, 2)},
		{"id": 2, "fp": Vector2i(5, 2), "ac": Vector2i(6, 2)},
	]
	var gs := _make_grid(equipment)
	var ms := _make_member_sim()
	var nav := _make_real_navigation(gs)
	var rig := _populate(gs, ms, nav)
	var cong: RefCounted = rig["congestion"]

	var blob: Dictionary = cong.call("serialize")
	_check(blob.has("prev") and (blob["prev"] is Dictionary) and not (blob["prev"] as Dictionary).is_empty(),
		"AC14: serialize() carries a populated prev (%d entries)" % (blob["prev"] as Dictionary).size())
	_check(blob.has("smoothed_cells") and (blob["smoothed_cells"] is Dictionary) and not (blob["smoothed_cells"] as Dictionary).is_empty(),
		"AC14: serialize() carries populated smoothed_cells (%d entries)" % (blob["smoothed_cells"] as Dictionary).size())
	_check(int(cong.get("counter")) > 0, "AC14: counter advanced (got %d)" % int(cong.get("counter")))

	# Snapshot pre-save prev (what MemberSim reads next tick) — the LIVE
	# in-memory floats, not the hex payload.
	var prev_before: Dictionary = (cong.get("prev") as Dictionary).duplicate(true)
	var smoothed_before: Dictionary = (cong.get("smoothed_cells") as Dictionary).duplicate(true)

	# Fresh rig with the SAME grid/nav (the load path: grid restored from the
	# blob's grid payload, then Congestion.deserialize commits).
	var gs_b := _make_grid(equipment)
	var ms_b := _make_member_sim()
	var nav_b := _make_real_navigation(gs_b)
	var rig_b := _make_congestion(gs_b, ms_b, nav_b)
	var cong_b: RefCounted = rig_b["congestion"]

	var result: RefCounted = cong_b.call("deserialize", blob)
	_check(bool(result.get("ok")), "AC14: deserialize(commit) ok (errors: %s)" % str(result.get("errors")))

	# prev restored bit-for-bit: every pre-save id -> identical float.
	var prev_after: Dictionary = cong_b.get("prev")
	_check(prev_after.size() == prev_before.size(),
		"AC14: restored prev has %d entries (pre-save %d)" % [prev_after.size(), prev_before.size()])
	var prev_equal := true
	for k in prev_before.keys():
		if not prev_after.has(k) or float(prev_after[k]) != float(prev_before[k]):
			prev_equal = false
			print("    DIVERGENCE prev[%s]: %s vs %s" % [str(k), str(prev_after.get(k)), str(prev_before[k])])
	_check(prev_equal, "AC14: prev floats bit-identical after deserialize")

	# smoothed_cells restored bit-for-bit.
	var smoothed_after: Dictionary = cong_b.get("smoothed_cells")
	var smoothed_equal := true
	for k in smoothed_before.keys():
		if not smoothed_after.has(k) or float(smoothed_after[k]) != float(smoothed_before[k]):
			smoothed_equal = false
			print("    DIVERGENCE smoothed[%s]: %s vs %s" % [str(k), str(smoothed_after.get(k)), str(smoothed_before[k])])
	_check(smoothed_equal, "AC14: smoothed_cells floats bit-identical after deserialize (%d cells)" % smoothed_after.size())

	# counter + rng_state restored too (stub contract preserved).
	_check(int(cong_b.get("counter")) == int(cong.get("counter")), "AC14: counter restored (%d)" % int(cong_b.get("counter")))
	var rng_a: int = int((rig["seeded_rng"].call("get_rng", "Congestion") as RandomNumberGenerator).state)
	var rng_b: int = int((rig_b["seeded_rng"].call("get_rng", "Congestion") as RandomNumberGenerator).state)
	_check(rng_a == rng_b, "AC14: rng_state restored exactly")

	# density_cells rebuilt from restored smoothed (derived, not serialized).
	var d: float = cong_b.call("per_cell_density", Vector2i(3, 2))
	_check(d > 0.0, "AC14: per_cell_density serves the restored field immediately (got %s)" % str(d))


func _test_ac14_member_sim_reads_prev_after_load() -> void:
	print("\n[AC14] MemberSim's read (per_equipment_congestion) at t+1 == pre-save prev bit-for-bit")
	var equipment: Array = [
		{"id": 1, "fp": Vector2i(2, 2), "ac": Vector2i(3, 2)},
		{"id": 2, "fp": Vector2i(5, 2), "ac": Vector2i(6, 2)},
	]
	var gs := _make_grid(equipment)
	var ms := _make_member_sim()
	var nav := _make_real_navigation(gs)
	var rig := _populate(gs, ms, nav)
	var cong: RefCounted = rig["congestion"]
	var blob: Dictionary = cong.call("serialize")

	# Pre-save: what MemberSim WOULD read at tick t+1.
	var expected: Dictionary = {}
	for id in [1, 2]:
		expected[id] = cong.call("per_equipment_congestion", id)

	# Load into a fresh rig; MemberSim (the real consumer) then reads prev.
	var gs_b := _make_grid(equipment)
	var ms_b := _make_member_sim()
	var nav_b := _make_real_navigation(gs_b)
	var rig_b := _make_congestion(gs_b, ms_b, nav_b)
	var cong_b: RefCounted = rig_b["congestion"]
	var result: RefCounted = cong_b.call("deserialize", blob)
	_check(bool(result.get("ok")), "AC14[read]: load ok")

	for id in [1, 2]:
		var got: float = cong_b.call("per_equipment_congestion", id)
		var want: float = expected[id]
		_check(got == want, "AC14[read]: MemberSim read for id %d matches pre-save prev bit-for-bit (%s)" % [id, str(got)])
	_check(float(cong_b.call("per_equipment_congestion", 1)) > 0.0,
		"AC14[read]: restored read is non-trivial (id 1 = %s)" % str(cong_b.call("per_equipment_congestion", 1)))


func _test_ac14_access_reachable_recomputed_not_deserialized() -> void:
	print("\n[AC14] access_reachable recomputed from grid after load — NOT carried in the payload")
	var equipment: Array = [
		{"id": 1, "fp": Vector2i(2, 2), "ac": Vector2i(3, 2)},
	]
	var gs := _make_grid(equipment)
	var ms := _make_member_sim()
	var nav := _make_real_navigation(gs)
	var rig := _populate(gs, ms, nav)
	var cong: RefCounted = rig["congestion"]
	var blob: Dictionary = cong.call("serialize")

	# The payload must NOT contain access_reachable (Core Rule 7).
	_check(not blob.has("access_reachable"), "AC14: serialize() payload has NO access_reachable key")
	_check(not blob.has("next"), "AC14: serialize() payload has NO next key (transient)")
	_check(not blob.has("raw_cells"), "AC14: serialize() payload has NO raw_cells key (transient)")
	_check(not blob.has("density_cells"), "AC14: serialize() payload has NO density_cells key (derived)")

	# Load into a fresh rig with a DIFFERENT grid: equipment 1's access cell
	# (3,2) is now completely walled off. Neighbors of (3,2): (2,2) is
	# already solid (equipment 1's own footprint), so committing blockers on
	# (4,2), (3,1), (3,3) seals every remaining approach — the established
	# AC13 blocking pattern. The loaded instance must recompute
	# access_reachable from THIS grid, not from any pre-save value.
	var gs_b := _make_grid(equipment)
	var block_fp: Array[Vector2i] = [Vector2i(4, 2)]
	var block_ac: Array[Vector2i] = [Vector2i(8, 7)]
	gs_b.call("commit", 50, block_fp, block_ac, R0)
	var block2_fp: Array[Vector2i] = [Vector2i(3, 1)]
	var block2_ac: Array[Vector2i] = [Vector2i(8, 6)]
	gs_b.call("commit", 51, block2_fp, block2_ac, R0)
	var block3_fp: Array[Vector2i] = [Vector2i(3, 3)]
	var block3_ac: Array[Vector2i] = [Vector2i(9, 7)]
	gs_b.call("commit", 52, block3_fp, block3_ac, R0)
	var nav_b := _make_real_navigation(gs_b)
	var ms_b := _make_member_sim()
	var rig_b := _make_congestion(gs_b, ms_b, nav_b)
	var cong_b: RefCounted = rig_b["congestion"]

	# Phase A validate + Phase B commit the SAME blob (the load path).
	var result: RefCounted = cong_b.call("deserialize", blob)
	_check(bool(result.get("ok")), "AC14[reach]: load ok")

	# access_reachable on the loaded instance reflects the LOADED grid
	# (recomputed via Navigation.get_path against the walled-off layout) —
	# NOT any deserialized value (the payload has no such field).
	var reachable: bool = cong_b.call("is_access_reachable", 1)
	_check(not reachable, "AC14[reach]: access_reachable recomputed from the loaded grid (walled-off -> false)")

	# Control: on the ORIGINAL open grid the same id was reachable.
	var reachable_before: bool = cong.call("is_access_reachable", 1)
	_check(reachable_before, "AC14[reach]: pre-save instance had id 1 reachable on its open grid")


func _test_ac14_json_full_precision_roundtrip() -> void:
	print("\n[AC14] blob-level JSON round-trip preserves floats bit-exact via hex float encoding (story-004 deviation)")
	var equipment: Array = [
		{"id": 1, "fp": Vector2i(2, 2), "ac": Vector2i(3, 2)},
		{"id": 2, "fp": Vector2i(5, 2), "ac": Vector2i(6, 2)},
	]
	var gs := _make_grid(equipment)
	var ms := _make_member_sim()
	var nav := _make_real_navigation(gs)
	var rig := _populate(gs, ms, nav)
	var cong: RefCounted = rig["congestion"]

	var blob: Dictionary = cong.call("serialize")
	var json_str := _blob_json(blob)
	var parsed: Variant = JSON.parse_string(json_str)
	_check(parsed is Dictionary, "AC14[json]: full blob parses back to a Dictionary")

	var parsed_prev: Dictionary = (parsed as Dictionary)["prev"]
	var parsed_smoothed: Dictionary = (parsed as Dictionary)["smoothed_cells"]
	var prev_equal := true
	for k in (blob["prev"] as Dictionary).keys():
		var pk: Variant = str(k)  # JSON.parse stringifies keys
		if not parsed_prev.has(pk) or str(parsed_prev[pk]) != str((blob["prev"] as Dictionary)[k]):
			prev_equal = false
			print("    DIVERGENCE prev[%s]: %s vs %s" % [str(k), str(parsed_prev.get(pk)), str((blob["prev"] as Dictionary)[k])])
	_check(prev_equal, "AC14[json]: prev hex floats survive JSON stringify(parse) bit-exact (hex is exact by construction)")

	var smoothed_equal := true
	for k in (blob["smoothed_cells"] as Dictionary).keys():
		var pk: Variant = str(k)
		if not parsed_smoothed.has(pk) or str(parsed_smoothed[pk]) != str((blob["smoothed_cells"] as Dictionary)[k]):
			smoothed_equal = false
			print("    DIVERGENCE smoothed[%s]: %s vs %s" % [str(k), str(parsed_smoothed.get(pk)), str((blob["smoothed_cells"] as Dictionary)[k])])
	_check(smoothed_equal, "AC14[json]: smoothed hex floats survive JSON stringify(parse) bit-exact (hex is exact by construction)")

	# Deserialize from the PARSED blob (the actual load path) still works.
	var gs_b := _make_grid(equipment)
	var ms_b := _make_member_sim()
	var nav_b := _make_real_navigation(gs_b)
	var rig_b := _make_congestion(gs_b, ms_b, nav_b)
	var cong_b: RefCounted = rig_b["congestion"]
	var result: RefCounted = cong_b.call("deserialize", parsed)
	_check(bool(result.get("ok")), "AC14[json]: deserialize from the JSON-parsed blob ok")
	_check(int(cong_b.get("counter")) == int(cong.get("counter")), "AC14[json]: counter restored through the JSON path")

	# The DECODED floats are bit-identical to the live pre-save floats
	# (this is the AC14 assertion the raw-float encoding would have failed:
	# 4.7.1's JSON.parse_string is not correctly rounded ~12% of the time).
	var live_smoothed: Dictionary = cong.get("smoothed_cells")
	var decoded_smoothed: Dictionary = cong_b.get("smoothed_cells")
	var decoded_equal := true
	for k in live_smoothed.keys():
		if float(decoded_smoothed.get(k, -1.0)) != float(live_smoothed[k]):
			decoded_equal = false
			print("    DECODE DIVERGENCE smoothed[%s]: %s vs %s" % [str(k), str(decoded_smoothed.get(k)), str(live_smoothed[k])])
	_check(decoded_equal, "AC14[json]: decoded smoothed floats bit-identical to live (hex round-trip defeats the 4.7.1 parse bug)")


func _test_hex_float_encoding_roundtrip() -> void:
	print("\n[HEX-FLOAT] bit-exact hex encoding round-trips tricky doubles (0.021599999999999998 etc.)")
	var cong_script: Script = load("res://src/systems/congestion.gd") as Script
	# The specific value that FAILED raw full_precision JSON round-trip in
	# 4.7.1 (bytes differ from the literal 0.0216).
	var tricky := 0.021599999999999998
	var hex: String = cong_script._float_to_hex(tricky)
	var back: float = cong_script._hex_to_float(hex)
	_check(hex.begins_with("0x") and hex.length() == 18, "HEX-FLOAT: encoded as 0x + 16 hex digits (%s)" % hex)
	_check(back == tricky, "HEX-FLOAT: tricky double round-trips bit-exact through hex (raw JSON does NOT in 4.7.1)")

	# A battery of tricky doubles: subnormal-adjacent, negative zero, 1-ulp
	# separations, huge/small magnitudes.
	var battery: Array = [
		0.021599999999999998, 0.0216, -0.0, 0.0, 1.0, -1.0, 3.2,
		0.30000000000000004, 1.7976931348623157e308, 5e-324,
		2.9938862323760986, 1.4703807830810547, 0.026252849027514458,
	]
	var all_exact := true
	for v in battery:
		var h: String = cong_script._float_to_hex(v)
		var r: float = cong_script._hex_to_float(h)
		if r != v:
			all_exact = false
			print("    HEX FAIL: %s -> %s -> %s" % [str(v), h, str(r)])
	_check(all_exact, "HEX-FLOAT: %d battery doubles all bit-exact through hex encoding" % battery.size())


# === serialize() shape + purity ===

func _test_serialize_shape_excludes_transient_and_grid_state() -> void:
	print("\n[SERIALIZE-SHAPE] payload carries exactly the 4 contract fields")
	var equipment: Array = [{"id": 1, "fp": Vector2i(2, 2), "ac": Vector2i(3, 2)}]
	var gs := _make_grid(equipment)
	var ms := _make_member_sim()
	var nav := _make_real_navigation(gs)
	var rig := _populate(gs, ms, nav)
	var cong: RefCounted = rig["congestion"]

	var blob: Dictionary = cong.call("serialize")
	var keys: Array = blob.keys()
	keys.sort()
	_check(keys == ["counter", "prev", "rng_state", "smoothed_cells"],
		"SERIALIZE-SHAPE: exactly {counter, prev, rng_state, smoothed_cells} (got %s)" % str(keys))

	# next IS populated in-memory after a tick — proving it is deliberately
	# excluded from the payload (transient).
	_check((cong.get("next") as Dictionary).is_empty(), "SERIALIZE-SHAPE: next is cleared after swap (transient)")
	_check((cong.get("access_reachable") as Dictionary).size() == 1, "SERIALIZE-SHAPE: access_reachable lives in-memory (1 entry)")


func _test_serialize_side_effect_free_deterministic() -> void:
	print("\n[SERIALIZE-PURE] two serialize() calls -> identical payload; no state mutation")
	var equipment: Array = [{"id": 1, "fp": Vector2i(2, 2), "ac": Vector2i(3, 2)}]
	var gs := _make_grid(equipment)
	var ms := _make_member_sim()
	var nav := _make_real_navigation(gs)
	var rig := _populate(gs, ms, nav)
	var cong: RefCounted = rig["congestion"]
	var rng_before: int = int((rig["seeded_rng"].call("get_rng", "Congestion") as RandomNumberGenerator).state)

	var a: Dictionary = cong.call("serialize")
	var counter_after_a: int = int(cong.get("counter"))
	var b: Dictionary = cong.call("serialize")

	_check(_blob_json(a) == _blob_json(b), "SERIALIZE-PURE: two serialize() calls produce identical JSON")
	_check(int(cong.get("counter")) == counter_after_a, "SERIALIZE-PURE: serialize() does not advance the counter")
	var rng_after: int = int((rig["seeded_rng"].call("get_rng", "Congestion") as RandomNumberGenerator).state)
	_check(rng_after == rng_before, "SERIALIZE-PURE: serialize() never draws the RNG sub-stream")


# === two-phase deserialize ===

func _test_two_phase_validate_only_no_mutation() -> void:
	print("\n[TWO-PHASE] validate_only=true runs Phase A and commits NOTHING")
	var equipment: Array = [
		{"id": 1, "fp": Vector2i(2, 2), "ac": Vector2i(3, 2)},
		{"id": 2, "fp": Vector2i(5, 2), "ac": Vector2i(6, 2)},
	]
	var gs := _make_grid(equipment)
	var ms := _make_member_sim()
	var nav := _make_real_navigation(gs)
	var rig := _populate(gs, ms, nav)
	var cong: RefCounted = rig["congestion"]
	var blob: Dictionary = cong.call("serialize")

	# Fresh rig, then Phase A only.
	var gs_b := _make_grid(equipment)
	var ms_b := _make_member_sim()
	var nav_b := _make_real_navigation(gs_b)
	var rig_b := _make_congestion(gs_b, ms_b, nav_b)
	var cong_b: RefCounted = rig_b["congestion"]

	var result: RefCounted = cong_b.call("deserialize", blob, true)
	_check(bool(result.get("ok")), "TWO-PHASE: validate_only=true -> ok")
	_check((cong_b.get("prev") as Dictionary).is_empty(), "TWO-PHASE: prev NOT committed by Phase A")
	_check((cong_b.get("smoothed_cells") as Dictionary).is_empty(), "TWO-PHASE: smoothed_cells NOT committed by Phase A")
	_check(int(cong_b.get("counter")) == 0, "TWO-PHASE: counter NOT committed by Phase A")

	# Same blob, full commit now.
	var commit: RefCounted = cong_b.call("deserialize", blob)
	_check(bool(commit.get("ok")), "TWO-PHASE: commit after validate ok")
	_check(not (cong_b.get("prev") as Dictionary).is_empty(), "TWO-PHASE: prev committed in Phase B")


func _test_corrupt_payloads_fail_phase_a() -> void:
	print("\n[CORRUPT] missing / wrong-type / non-numeric payload fields fail Phase A without mutation")
	var equipment: Array = [{"id": 1, "fp": Vector2i(2, 2), "ac": Vector2i(3, 2)}]
	var gs := _make_grid(equipment)
	var ms := _make_member_sim()
	var nav := _make_real_navigation(gs)
	var rig := _populate(gs, ms, nav)
	var cong: RefCounted = rig["congestion"]
	var good: Dictionary = cong.call("serialize")

	var cases: Array = [
		{"name": "missing prev", "mutate": func(d: Dictionary) -> void: d.erase("prev")},
		{"name": "prev wrong type", "mutate": func(d: Dictionary) -> void: d["prev"] = "not a dict"},
		{"name": "prev non-numeric key", "mutate": func(d: Dictionary) -> void: (d["prev"] as Dictionary)["bogus"] = 0.5},
		{"name": "prev non-numeric value", "mutate": func(d: Dictionary) -> void: (d["prev"] as Dictionary)[99] = "x"},
		{"name": "prev invalid float hex", "mutate": func(d: Dictionary) -> void: (d["prev"] as Dictionary)[99] = "0xZZ"},
		{"name": "prev short float hex", "mutate": func(d: Dictionary) -> void: (d["prev"] as Dictionary)[99] = "0x3fe"},
		{"name": "missing smoothed_cells", "mutate": func(d: Dictionary) -> void: d.erase("smoothed_cells")},
		{"name": "smoothed non-numeric value", "mutate": func(d: Dictionary) -> void: (d["smoothed_cells"] as Dictionary)[1] = true},
		{"name": "counter wrong type", "mutate": func(d: Dictionary) -> void: d["counter"] = "5"},
		{"name": "rng_state missing", "mutate": func(d: Dictionary) -> void: d.erase("rng_state")},
		{"name": "rng_state not hex", "mutate": func(d: Dictionary) -> void: d["rng_state"] = "0xZZZ"},
	]
	for c in cases:
		var bad: Dictionary = good.duplicate(true)
		c["mutate"].call(bad)
		# Fresh instance per case (each corrupt payload must fail and leave
		# the target untouched).
		var gs_x := _make_grid(equipment)
		var ms_x := _make_member_sim()
		var nav_x := _make_real_navigation(gs_x)
		var rig_x := _make_congestion(gs_x, ms_x, nav_x)
		var cong_x: RefCounted = rig_x["congestion"]
		var result: RefCounted = cong_x.call("deserialize", bad)
		_check(not bool(result.get("ok")) and not (result.get("errors") as Array).is_empty(),
			"CORRUPT[%s]: load fails with errors" % c["name"])
		_check((cong_x.get("prev") as Dictionary).is_empty() and int(cong_x.get("counter")) == 0,
			"CORRUPT[%s]: nothing committed (zero mutation)" % c["name"])


# === pre-wiring path (SL-002-era contract) ===

func _test_prewiring_contract_shape_preserved() -> void:
	print("\n[PREWIRING] unconfigured instance still serialize()s the 4-field shape with empty buffers")
	var srg: RefCounted = _SRG().new()
	srg.call("init", 0xBEEF004)
	var orch := _make_orchestrator()
	var cong: RefCounted = (load("res://src/systems/congestion.gd") as Script).new()
	cong.call("init", orch, srg)  # pre-wiring: no grid/member_sim

	var blob: Dictionary = cong.call("serialize")
	_check(blob.has("counter") and blob.has("rng_state"), "PREWIRING: counter + rng_state preserved")
	_check((blob["prev"] as Dictionary).is_empty() and (blob["smoothed_cells"] as Dictionary).is_empty(),
		"PREWIRING: prev + smoothed_cells present and empty (no compute state)")

	# Round-trips back (the save-load integration path).
	var result: RefCounted = cong.call("deserialize", blob)
	_check(bool(result.get("ok")), "PREWIRING: empty-buffer blob deserializes ok")
	_check(int(cong.get("counter")) == 0, "PREWIRING: counter still 0 (nothing to restore)")
