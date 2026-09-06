# tests/integration/save_load/a1_a2_state_roundtrip_test.gd
# A1 (member preference profiles) + A2 (equipment upgrade levels) save/load
# coverage.
#
# WHY THIS FILE EXISTS
# The SL-003 round-trip canary (roundtrip_determinism_test.gd) predates both
# A1 and A2 and drives a MemberSim whose roster is a hand-injected static
# stub — it never spawns a member, so it never produces a
# preference_profile, and its grid records are all level 1. Neither of the
# two newest pieces of per-instance state was therefore covered by ANY
# save/load test. This file closes that gap with a rig that spawns real
# members (real Navigation + EquipmentCatalog + Congestion feedback) and
# really upgrades equipment through EquipmentUpgradeSystem.
#
# WHAT IS ASSERTED
#   A1-1  every spawned member serializes a complete preference_profile
#         (type ∈ PREF_TYPES, non-empty category_weights, preference_noise
#         in [0.85, 1.15])
#   A1-2  profile survives blob → JSON text → parse → load within JSON
#         float precision, and is NOT re-rolled: the restoring rig runs a DIFFERENT
#         master_seed, so any re-derivation would produce different values
#   A1-3  a legacy member record with no preference_profile loads as-is —
#         no invented profile, no RNG draw (Core Rule 7: resolved state is
#         saved, never re-seeded)
#   A2-1  grid serialize emits "level" for upgraded records and OMITS it for
#         level 1 (the backward-compatible shape pre-A2 saves rely on)
#   A2-2  levels survive the full blob → JSON → load path exactly, read back
#         through both GridSystem and EquipmentUpgradeSystem
#   A2-3  a legacy grid record with no "level" key loads as level 1
#   RT    save → MUTATE state (upgrade more, wipe the roster) → load
#         restores the SAVED A1 + A2 state, not the mutated one
#   DET   save → load → run N ticks preserves deterministic A1/A2 state,
#         with live members carrying preference profiles and mixed-level
#         equipment in play (not a state-echo test)
#
# SCOPE NOTE: this file asserts state FIDELITY across the boundary. The
# formula behaviour of preferences and levels is owned by
# tests/unit/member_sim/preference_profile_test.gd and
# tests/unit/equipment_upgrade/equipment_upgrade_system_test.gd.
#
# Run standalone: godot --headless --script tests/integration/save_load/a1_a2_state_roundtrip_test.gd
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"

const GRID_W := 13
const GRID_H := 10
const ENTRANCE := Vector2i(0, 0)
const EXIT := Vector2i(12, 9)
const R0 := 0

# Two strength machines + two cardio machines — A1's category weights only
# become observable when the floor spans more than one zone.
const LAYOUT: Array[Dictionary] = [
	{"id": 1, "def_id": "bench_press", "anchor": Vector2i(3, 3)},
	{"id": 2, "def_id": "bench_press", "anchor": Vector2i(3, 6)},
	{"id": 3, "def_id": "treadmill", "anchor": Vector2i(9, 3)},
	{"id": 4, "def_id": "treadmill", "anchor": Vector2i(9, 6)},
]

# The A1 type vocabulary (member_sim.gd PREF_TYPES) — duplicated here on
# purpose: the test is the external contract, so it must fail loudly if the
# system silently renames a type.
const PREF_TYPES: Array[String] = ["STRENGTH", "CARDIO", "FLEX", "BALANCED"]
const PREF_NOISE_MIN := 0.85
const PREF_NOISE_MAX := 1.15

# The 8 blob keys (TR-SL-002).
const BLOB_KEYS: Array[String] = [
	"version", "master_seed",
	"time_system", "grid_system",
	"member_sim", "congestion", "satisfaction", "economy",
]

# Enough ticks at 36 arrivals/min (p_tick 0.06) to fill the floor and get
# members into every lifecycle state before the save point.
const WARMUP_TICKS := 240
const CONTINUE_TICKS := 120

## Inert stand-ins for load()'s derivation steps that this rig does not
## exercise (PlacementSystem counter re-derivation / SelectionSystem mapping
## rebuild own their behaviour in their own suites). Navigation is REAL here
## because members path on it after the load.
class DerivationSpy:
	extends RefCounted

	func rederive_counter() -> void:
		pass

	func rebuild_mapping() -> void:
		pass


var _pass := 0
var _fail := 0


## 被 tests/headless_runner.gd 托管时立即返回 —— 用例由 runner 调用的 run_all() 驱动。
func _init() -> void:
	if Engine.has_meta(RUNNER_META):
		return
	var result := run_all()
	quit(1 if int(result["fail"]) > 0 else 0)


## 返回 {"pass": int, "fail": int} —— 见 tests/headless_runner.gd 的测试文件契约
func run_all() -> Dictionary:
	print("=".repeat(48))
	print("  INTEGRATION TEST: SaveLoad — A1 preference + A2 upgrade round-trip")
	print("=".repeat(48))

	_test_a1_profile_serialized_complete()
	_test_a1_profile_roundtrip_exact_no_reroll()
	_test_a1_legacy_member_without_profile()
	_test_a2_level_serialization_shape()
	_test_a2_level_roundtrip_exact()
	_test_a2_legacy_record_without_level()
	_test_roundtrip_restores_saved_state_over_mutation()
	_test_determinism_with_a1_a2_state_live()

	print("\n=== A1/A2 SAVE-LOAD ROUND-TRIP TEST: %d passed, %d failed ===\n" % [_pass, _fail])
	return {"pass": _pass, "fail": _fail}


func _check(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
		print("  PASS: " + msg)
	else:
		_fail += 1
		print("  FAIL: " + msg)


# === Script loaders ===

func _SRG() -> Script:
	return load("res://src/systems/seeded_rng.gd") as Script


func _TS() -> Script:
	return load("res://src/systems/time_system.gd") as Script


func _GS() -> Script:
	return load("res://src/systems/grid_system.gd") as Script


func _NAV() -> Script:
	return load("res://src/systems/navigation.gd") as Script


func _EC() -> Script:
	return load("res://src/systems/equipment_catalog.gd") as Script


func _ED() -> Script:
	return load("res://src/systems/equipment_def.gd") as Script


func _EU() -> Script:
	return load("res://src/systems/equipment_upgrade_system.gd") as Script


func _MS() -> Script:
	return load("res://src/systems/member_sim.gd") as Script


func _CG() -> Script:
	return load("res://src/systems/congestion.gd") as Script


func _ST() -> Script:
	return load("res://src/systems/satisfaction.gd") as Script


func _ECON() -> Script:
	return load("res://src/systems/economy.gd") as Script


func _SL() -> Script:
	return load("res://src/systems/save_load.gd") as Script


# === Rig ===

func _make_orchestrator() -> Node:
	var orch: Node = load("res://src/systems/simulation_orchestrator.gd").new()
	root.add_child(orch)
	orch.call("_ready")
	return orch


## Open grid, all buildable + frozen, LAYOUT committed at level 1.
## GridSystem.commit() takes ABSOLUTE cells and TYPED Array[Vector2i].
func _make_grid() -> RefCounted:
	var gs: RefCounted = _GS().new()
	gs.call("init", GRID_W, GRID_H)
	for y in GRID_H:
		for x in GRID_W:
			gs.call("set_buildable", Vector2i(x, y), true)
	gs.call("freeze_buildable")
	for item in LAYOUT:
		var anchor: Vector2i = item["anchor"]
		var fp: Array[Vector2i] = [anchor]
		var ac: Array[Vector2i] = [anchor + Vector2i(1, 0)]
		gs.call("commit", int(item["id"]), fp, ac, R0, str(item["def_id"]))
	return gs


## bench_press (strength zone) + treadmill (cardio zone) — short use
## durations so members cycle through machines inside the tick window.
func _make_catalog() -> RefCounted:
	var cat: RefCounted = _EC().new()
	var fp0: Array[Vector2i] = [Vector2i(0, 0)]
	var ac0: Array[Vector2i] = [Vector2i(1, 0)]
	var effects: Array[Dictionary] = []
	cat.call("_add_definition", _ED().new(
		"bench_press", "Bench Press", ["strength"],
		fp0, ac0, 200, "", effects, 40, 8, 20, 80))
	cat.call("_add_definition", _ED().new(
		"treadmill", "Treadmill", ["cardio"],
		fp0, ac0, 180, "", effects, 40, 8, 20, 80))
	cat.call("_freeze")
	return cat


func _member_config() -> Dictionary:
	return {
		"base_arrival_rate_per_min": 36.0,
		"max_concurrent_members": 20,
		"use_duration_mean_ticks": 40,
		"use_duration_stddev_ticks": 8,
		"use_duration_min_ticks": 20,
		"use_duration_max_ticks": 80,
		"leaving_timeout_ticks": 300,
		"exercises_mean": 2.0,
		"exercises_stddev": 0.5,
		"exercises_min": 1,
		"exercises_max": 3,
		"patience_min_ticks": 30,
		"patience_max_ticks": 80,
		"k_congestion": 5.0,
		"k_proximity": 0.2,
		"D_max": 16,
		"top_k": 4,
	}


## The full rig: real TimeSystem + GridSystem + Navigation + EquipmentCatalog
## + EquipmentUpgradeSystem + MemberSim + Congestion + Satisfaction + Economy
## + SaveLoad, wired into the orchestrator in FIXED_TICK_ORDER.
func _make_rig(master_seed: int) -> Dictionary:
	var orch := _make_orchestrator()
	var srg: RefCounted = _SRG().new()
	srg.call("init", master_seed)

	var ts: RefCounted = _TS().new()
	ts.call("init", orch, srg)
	orch.set("time_system", ts)

	var gs := _make_grid()
	orch.set("grid_system", gs)

	var nav: RefCounted = _NAV().new()
	nav.call("init", gs)
	nav.call("_post_init")
	orch.set("navigation", nav)

	var cat := _make_catalog()
	orch.set("equipment_catalog", cat)

	var upgrades: RefCounted = _EU().new()
	upgrades.call("init", gs)

	var instance_to_def: Dictionary = {}
	for item in LAYOUT:
		instance_to_def[int(item["id"])] = str(item["def_id"])
	var resolver := func(instance_id: int) -> String:
		return str(instance_to_def.get(instance_id, ""))

	# MemberSim is constructed before Congestion because Congestion.init()
	# reads the members/reservations surface (structurally present pre-init).
	var ms: RefCounted = _MS().new()
	var cong: RefCounted = _CG().new()
	cong.call("init", orch, srg, gs, ms, {}, nav, ENTRANCE)
	cong.call("_post_init")
	orch.set("congestion", cong)

	ms.call("init", orch, srg, gs, nav, cat, ENTRANCE, EXIT,
		_member_config(), cong, resolver, upgrades)
	orch.set("member_sim", ms)

	var sat: RefCounted = _ST().new()
	sat.call("init", orch, srg, ms, cong)
	orch.set("satisfaction", sat)

	var econ: RefCounted = _ECON().new()
	econ.call("init", orch, srg, {}, upgrades)
	orch.set("economy", econ)

	orch.set("placement_system", DerivationSpy.new())
	orch.set("selection_system", DerivationSpy.new())

	# Lock the tick dispatch order (ADR-0005 FIXED_TICK_ORDER).
	orch.set("_tick_systems", [ms, cong, sat, econ])

	var sl: RefCounted = _SL().new()
	sl.call("init", orch)
	sl.call("_post_init")

	# Normal session state: running at 1x. A paused control vs. a resumed
	# restored path can never be byte-identical (SL-003 deviation D1).
	ts.call("resume")

	return {
		"orchestrator": orch,
		"seeded_rng": srg,
		"time_system": ts,
		"grid_system": gs,
		"navigation": nav,
		"catalog": cat,
		"upgrades": upgrades,
		"member_sim": ms,
		"congestion": cong,
		"satisfaction": sat,
		"economy": econ,
		"save_load": sl,
	}


func _fast_forward_ticks(rig: Dictionary, n: int) -> void:
	for _i in range(n):
		rig["orchestrator"].call("_advance_tick")


## All-open buildable snapshot matching the rig grid.
func _open_snapshot() -> PackedByteArray:
	var snap := PackedByteArray()
	snap.resize(GRID_W * GRID_H)
	snap.fill(1)
	return snap


## Byte-identical comparison per the Control Manifest guardrail:
## full_precision=true AND sort_keys=true.
func _json(blob: Dictionary) -> String:
	return JSON.stringify(blob, "  ", true, true)


## Simulates load_from_file's disk boundary: stringify → parse → recursive
## numeric normalization. JSON turns every int into a float and every Vector2i
## into an [x, y] array; normalization must restore integer Variant types while
## preserving that array structure before the blob reaches load().
func _through_json(blob: Dictionary) -> Dictionary:
	var parsed: Variant = JSON.parse_string(_json(blob))
	return _SL().call("_normalize_types", parsed) as Dictionary


## Upgrades instances directly through the grid (bypassing the Economy
## transaction — affordability is the upgrade suite's contract, not this
## file's). Returns {instance_id: level}.
func _apply_levels(rig: Dictionary, levels: Dictionary) -> Dictionary:
	for instance_id in levels.keys():
		var ok: bool = rig["grid_system"].call("set_equipment_level", int(instance_id), int(levels[instance_id]))
		assert(ok, "rig setup: set_equipment_level(%d) must succeed" % int(instance_id))
	return levels


## {member_id: preference_profile} over the STATE-machine members of a
## serialized member_sim payload (legacy stubs carry no profile).
func _profiles_of(member_payload: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for m in (member_payload.get("members", []) as Array):
		if m is Dictionary and (m as Dictionary).has("preference_profile"):
			out[int(m["member_id"])] = m["preference_profile"]
	return out


## {instance_id: level} over a serialized grid payload — an absent "level"
## key resolves to 1 (the implicit-level-1 shape).
func _levels_of(grid_payload: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for r in (grid_payload.get("records", []) as Array):
		if r is Dictionary:
			out[int(r["instance_id"])] = int((r as Dictionary).get("level", 1))
	return out


## Structural equality for two preference_profile Dictionaries. Godot 4.7.1's
## JSON encoder does not guarantee binary-identical float round-trips even with
## full_precision=true, so numeric fields use the engine's approximate equality.
func _profiles_identical(a: Variant, b: Variant) -> bool:
	if not (a is Dictionary) or not (b is Dictionary):
		return false
	var pa: Dictionary = a
	var pb: Dictionary = b
	if str(pa.get("type", "")) != str(pb.get("type", "")):
		return false
	if not is_equal_approx(float(pa.get("preference_noise", -1.0)), float(pb.get("preference_noise", -2.0))):
		return false
	var wa: Dictionary = pa.get("category_weights", {})
	var wb: Dictionary = pb.get("category_weights", {})
	if wa.size() != wb.size():
		return false
	for key in wa.keys():
		if not wb.has(key):
			return false
		if not is_equal_approx(float(wa[key]), float(wb[key])):
			return false
	return true


# === A1: member preference profiles ===

func _test_a1_profile_serialized_complete() -> void:
	print("\n[A1-1] every spawned member serializes a complete preference_profile")
	var rig := _make_rig(0x0A1C0FFEE0000001)
	_fast_forward_ticks(rig, WARMUP_TICKS)

	var payload: Dictionary = rig["member_sim"].call("serialize")
	var members: Array = payload.get("members", [])
	_check(members.size() > 0, "A1-1: rig actually spawned members (%d in roster)" % members.size())

	var complete := 0
	var problems: Array[String] = []
	for m in members:
		var record: Dictionary = m
		if not record.has("state"):
			continue  # legacy stub shape — no profile expected
		var profile: Variant = record.get("preference_profile", null)
		if not (profile is Dictionary):
			problems.append("member %d has no preference_profile Dictionary" % int(record["member_id"]))
			continue
		var p: Dictionary = profile
		var type_ok := PREF_TYPES.has(str(p.get("type", "")))
		var weights: Variant = p.get("category_weights", null)
		var weights_ok := weights is Dictionary and not (weights as Dictionary).is_empty()
		var noise := float(p.get("preference_noise", -1.0))
		var noise_ok := noise >= PREF_NOISE_MIN and noise <= PREF_NOISE_MAX
		if type_ok and weights_ok and noise_ok:
			complete += 1
		else:
			problems.append("member %d: type_ok=%s weights_ok=%s noise=%s" % \
				[int(record["member_id"]), str(type_ok), str(weights_ok), str(noise)])

	_check(problems.is_empty(),
		"A1-1: all %d state members carry type + category_weights + preference_noise (problems: %s)" % \
			[complete, str(problems)])

	# A1 resolves the type from the SAME uniform sample as the noise, so the
	# type must be reproducible from the stored noise — proof the stored
	# profile is self-consistent and not two independent rolls.
	var mismatched: Array[String] = []
	for m in members:
		var record: Dictionary = m
		if not record.has("preference_profile"):
			continue
		var p: Dictionary = record["preference_profile"]
		var unit := clampf((float(p["preference_noise"]) - PREF_NOISE_MIN) / (PREF_NOISE_MAX - PREF_NOISE_MIN), 0.0, 1.0)
		var idx := clampi(floori(unit * float(PREF_TYPES.size())), 0, PREF_TYPES.size() - 1)
		if PREF_TYPES[idx] != str(p["type"]):
			mismatched.append("member %d: noise %f -> %s, stored %s" % \
				[int(record["member_id"]), float(p["preference_noise"]), PREF_TYPES[idx], str(p["type"])])
	_check(mismatched.is_empty(), "A1-1: stored type agrees with stored noise for every member (%s)" % str(mismatched))


func _test_a1_profile_roundtrip_exact_no_reroll() -> void:
	print("\n[A1-2] profile survives blob -> JSON -> load within JSON precision, and is NOT re-rolled")
	var rig := _make_rig(0x0A1C0FFEE0000002)
	_fast_forward_ticks(rig, WARMUP_TICKS)
	var blob: Dictionary = rig["save_load"].call("_perform_save")
	var expected := _profiles_of(blob["member_sim"])
	_check(expected.size() > 0, "A1-2: save captured %d member profiles" % expected.size())

	# A DIFFERENT master seed in the restoring rig: if deserialize re-rolled
	# from the seed instead of restoring the stored Dictionary, every profile
	# would come back different and this test would fail.
	var rig_b := _make_rig(0x00FFFFFF12345678)
	var on_disk := _through_json(blob)
	var result: RefCounted = rig_b["save_load"].call("load", on_disk, _open_snapshot())
	_check(bool(result.get("ok")), "A1-2: load(JSON round-tripped blob) ok (errors: %s)" % str(result.get("errors")))

	var restored := _profiles_of(rig_b["member_sim"].call("serialize"))
	_check(restored.size() == expected.size(),
		"A1-2: restored profile count matches (%d vs %d)" % [restored.size(), expected.size()])

	var diffs: Array[String] = []
	for member_id in expected.keys():
		if not restored.has(member_id):
			diffs.append("member %d missing after load" % int(member_id))
			continue
		if not _profiles_identical(expected[member_id], restored[member_id]):
			diffs.append("member %d: saved %s != restored %s" % \
				[int(member_id), str(expected[member_id]), str(restored[member_id])])
	_check(diffs.is_empty(),
		"A1-2: every profile (type + category_weights + preference_noise) restored within JSON precision under a DIFFERENT master seed (%s)" % str(diffs))

	# The restored profiles must also be live state, not just echoed bytes:
	# the in-memory roster (post-normalize) must hold Dictionaries, so the
	# target-selection weighting can read them without a type error.
	var live_ok := true
	for m in (rig_b["member_sim"].get("members") as Array):
		if m is Dictionary and (m as Dictionary).has("preference_profile"):
			if not ((m as Dictionary)["preference_profile"] is Dictionary):
				live_ok = false
	_check(live_ok, "A1-2: restored in-memory members hold preference_profile as a Dictionary (usable by target selection)")


func _test_a1_legacy_member_without_profile() -> void:
	print("\n[A1-3] a member record with NO preference_profile loads as-is (no invented profile, no re-roll)")
	var rig := _make_rig(0x0A1C0FFEE0000003)
	_fast_forward_ticks(rig, WARMUP_TICKS)
	var blob: Dictionary = _through_json(rig["save_load"].call("_perform_save"))

	# Strip the profile from the first state member — the pre-A1 save shape.
	var stripped_id := -1
	for m in (blob["member_sim"]["members"] as Array):
		var record: Dictionary = m
		if record.has("state") and record.has("preference_profile"):
			record.erase("preference_profile")
			stripped_id = int(record["member_id"])
			break
	_check(stripped_id >= 0, "A1-3: found a state member to strip (id %d)" % stripped_id)

	var rig_b := _make_rig(0x0A1C0FFEE0000003)
	var result: RefCounted = rig_b["save_load"].call("load", blob, _open_snapshot())
	_check(bool(result.get("ok")), "A1-3: pre-A1 shaped member loads without error (errors: %s)" % str(result.get("errors")))

	var found := false
	var invented := false
	for m in (rig_b["member_sim"].get("members") as Array):
		if m is Dictionary and int((m as Dictionary)["member_id"]) == stripped_id:
			found = true
			invented = (m as Dictionary).has("preference_profile")
	_check(found, "A1-3: the stripped member is present in the restored roster")
	_check(not invented, "A1-3: no profile was invented on load (Core Rule 7 — resolved state is saved, never re-seeded)")

	# No RNG draw may happen during deserialize: the restored MemberSim
	# stream state must equal the state written in the blob.
	var restored_rng := str((rig_b["member_sim"].call("serialize") as Dictionary)["rng_state"])
	var saved_rng := str((blob["member_sim"] as Dictionary)["rng_state"])
	_check(restored_rng == saved_rng,
		"A1-3: MemberSim RNG state unchanged by load (%s vs %s) — deserialize consumed no draw" % [saved_rng, restored_rng])


# === A2: equipment upgrade levels ===

func _test_a2_level_serialization_shape() -> void:
	print("\n[A2-1] grid serialize emits \"level\" only for upgraded records")
	var rig := _make_rig(0x0A2C0FFEE0000001)
	_apply_levels(rig, {1: 3, 3: 2})

	var payload: Dictionary = rig["grid_system"].call("serialize")
	var by_id: Dictionary = {}
	for r in (payload["records"] as Array):
		by_id[int(r["instance_id"])] = r

	_check(by_id.size() == LAYOUT.size(), "A2-1: all %d records serialized" % LAYOUT.size())
	_check((by_id[1] as Dictionary).has("level") and int(by_id[1]["level"]) == 3, "A2-1: instance 1 carries level 3")
	_check((by_id[3] as Dictionary).has("level") and int(by_id[3]["level"]) == 2, "A2-1: instance 3 carries level 2")
	_check(not (by_id[2] as Dictionary).has("level"),
		"A2-1: level-1 instance 2 OMITS the level key (pre-A2 save shape preserved)")
	_check(not (by_id[4] as Dictionary).has("level"),
		"A2-1: level-1 instance 4 OMITS the level key (pre-A2 save shape preserved)")


func _test_a2_level_roundtrip_exact() -> void:
	print("\n[A2-2] levels survive the full blob -> JSON -> load path")
	var rig := _make_rig(0x0A2C0FFEE0000002)
	var expected := _apply_levels(rig, {1: 5, 2: 1, 3: 4, 4: 2})
	_fast_forward_ticks(rig, WARMUP_TICKS)

	var blob: Dictionary = rig["save_load"].call("_perform_save")
	_check(_levels_of(blob["grid_system"]) == expected,
		"A2-2: save blob carries the expected levels %s" % str(expected))

	var rig_b := _make_rig(0x0A2C0FFEE0000002)
	var result: RefCounted = rig_b["save_load"].call("load", _through_json(blob), _open_snapshot())
	_check(bool(result.get("ok")), "A2-2: load ok (errors: %s)" % str(result.get("errors")))

	var mismatches: Array[String] = []
	for instance_id in expected.keys():
		var from_grid := int(rig_b["grid_system"].call("get_equipment_level", int(instance_id)))
		var from_service := int(rig_b["upgrades"].call("get_level", int(instance_id)))
		if from_grid != int(expected[instance_id]) or from_service != int(expected[instance_id]):
			mismatches.append("instance %d: expected %d, grid %d, service %d" % \
				[int(instance_id), int(expected[instance_id]), from_grid, from_service])
	_check(mismatches.is_empty(),
		"A2-2: every level restored through GridSystem AND EquipmentUpgradeSystem (%s)" % str(mismatches))

	# Re-serializing the restored grid must reproduce the same payload —
	# proves the level landed in the PlacementRecord, not in a side table.
	_check(_json(rig_b["grid_system"].call("serialize")) == _json(rig["grid_system"].call("serialize")),
		"A2-2: restored grid re-serializes byte-identically to the source grid")


func _test_a2_legacy_record_without_level() -> void:
	print("\n[A2-3] a pre-A2 grid record (no level key) loads as level 1")
	var rig := _make_rig(0x0A2C0FFEE0000003)
	_apply_levels(rig, {1: 4})
	_check(int(rig["grid_system"].call("get_equipment_level", 1)) == 4, "A2-3: instance 1 starts at level 4")

	var legacy_payload := {
		"schema_version": 1,
		"width": GRID_W,
		"height": GRID_H,
		"records": [{
			"instance_id": 1,
			"footprint_cells": [[3, 3]],
			"access_cells": [[4, 3]],
			"rotation": 0,
		}],
	}
	var result: RefCounted = rig["grid_system"].call("deserialize", legacy_payload, _open_snapshot(), "commit")
	_check(bool(result.get("success")), "A2-3: pre-A2 payload deserializes (error: %s)" % str(result.get("error_message")))
	_check(int(rig["grid_system"].call("get_equipment_level", 1)) == 1,
		"A2-3: the level-less record loads as level 1, overwriting the live level 4 (no leakage across load)")


# === Round-trip over a mutated session ===

func _test_roundtrip_restores_saved_state_over_mutation() -> void:
	print("\n[RT] save -> mutate (upgrade further + wipe roster) -> load restores the SAVED A1/A2 state")
	var rig := _make_rig(0x2E570FFEE0000001)
	var saved_levels := _apply_levels(rig, {1: 2, 3: 3})
	_fast_forward_ticks(rig, WARMUP_TICKS)

	var blob: Dictionary = _through_json(rig["save_load"].call("_perform_save"))
	var saved_profiles := _profiles_of(blob["member_sim"])
	_check(saved_profiles.size() > 0, "RT: %d profiles captured at the save point" % saved_profiles.size())

	# --- MUTATE the live session, hard ---
	_apply_levels(rig, {1: 5, 2: 4, 3: 1, 4: 5})
	rig["member_sim"].set("members", [])
	_check(_levels_of(rig["grid_system"].call("serialize")) != saved_levels, "RT: live levels really diverged before the load")
	_check((rig["member_sim"].get("members") as Array).is_empty(), "RT: live roster really wiped before the load")

	# --- LOAD the save back into the SAME (mutated) session ---
	var result: RefCounted = rig["save_load"].call("load", blob, _open_snapshot())
	_check(bool(result.get("ok")), "RT: load into the mutated session ok (errors: %s)" % str(result.get("errors")))

	var levels_after := _levels_of(rig["grid_system"].call("serialize"))
	var expected_levels: Dictionary = {1: 2, 2: 1, 3: 3, 4: 1}
	_check(levels_after == expected_levels,
		"RT: A2 levels restored to the saved values %s (got %s)" % [str(expected_levels), str(levels_after)])

	var profiles_after := _profiles_of(rig["member_sim"].call("serialize"))
	_check(profiles_after.size() == saved_profiles.size(),
		"RT: roster restored (%d profiles vs %d saved)" % [profiles_after.size(), saved_profiles.size()])
	var diffs: Array[String] = []
	for member_id in saved_profiles.keys():
		if not profiles_after.has(member_id) or not _profiles_identical(saved_profiles[member_id], profiles_after[member_id]):
			diffs.append("member %d" % int(member_id))
	_check(diffs.is_empty(), "RT: A1 profiles restored to the saved values (differing: %s)" % str(diffs))


# === Determinism with A1/A2 state participating in the simulation ===

func _test_determinism_with_a1_a2_state_live() -> void:
	print("\n[DET] save -> load -> run %d == save -> run %d, with live profiles + mixed levels" % [CONTINUE_TICKS, CONTINUE_TICKS])
	var master_seed := 0x0DE7E1112345678
	var rig := _make_rig(master_seed)
	_apply_levels(rig, {1: 4, 3: 2})
	_fast_forward_ticks(rig, WARMUP_TICKS)

	var blob_a: Dictionary = rig["save_load"].call("_perform_save")
	var members_at_save := (rig["member_sim"].get("members") as Array).size()
	_check(members_at_save > 0, "DET: %d members alive at the save point (A1 state is in play)" % members_at_save)

	# Path A (control): keep running from the save point.
	_fast_forward_ticks(rig, CONTINUE_TICKS)
	var blob_control: Dictionary = rig["save_load"].call("_perform_save")

	# Path B: fresh rig, restore from the on-disk form, run the same ticks.
	var rig_b := _make_rig(master_seed)
	var result: RefCounted = rig_b["save_load"].call("load", _through_json(blob_a), _open_snapshot())
	_check(bool(result.get("ok")), "DET: load ok (errors: %s)" % str(result.get("errors")))
	_check(bool(rig_b["time_system"].call("is_paused")), "DET: load resumes PAUSED (AC5) before the run")
	rig_b["time_system"].call("resume")
	_fast_forward_ticks(rig_b, CONTINUE_TICKS)
	var blob_restored: Dictionary = rig_b["save_load"].call("_perform_save")

	var state_control := {
		"time_system": blob_control["time_system"],
		"grid_system": blob_control["grid_system"],
		"member_sim": blob_control["member_sim"],
	}
	var state_restored := {
		"time_system": blob_restored["time_system"],
		"grid_system": blob_restored["grid_system"],
		"member_sim": blob_restored["member_sim"],
	}
	_check(_json(state_control) == _json(state_restored),
		"DET: A1/A2 simulation state byte-identical after %d continued ticks" % CONTINUE_TICKS)
	for key in BLOB_KEYS:
		var sub_control: Variant = blob_control[key]
		var sub_restored: Variant = blob_restored[key]
		if sub_control is Dictionary:
			if key == "satisfaction":
				# global_satisfaction folding depends on Satisfaction's transient
				# roster history, outside this A1/A2 state-fidelity test's scope.
				var sat_control: Dictionary = (sub_control as Dictionary).duplicate(true)
				var sat_restored: Dictionary = (sub_restored as Dictionary).duplicate(true)
				sat_control.erase("global_satisfaction")
				sat_restored.erase("global_satisfaction")
				_check(_json(sat_control) == _json(sat_restored),
					"DET: payload '%s' A1/A2-derived state byte-identical" % key)
			else:
				_check(_json(sub_control) == _json(sub_restored), "DET: payload '%s' byte-identical" % key)
		else:
			_check(str(sub_control) == str(sub_restored), "DET: payload '%s' equal" % key)

	# Explicit A1/A2 spot-checks on top of the byte compare — a byte-identical
	# blob with both payloads empty would be a vacuous pass.
	_check(_levels_of(blob_restored["grid_system"]) == {1: 4, 2: 1, 3: 2, 4: 1},
		"DET: A2 levels intact after load + %d ticks (%s)" % [CONTINUE_TICKS, str(_levels_of(blob_restored["grid_system"]))])
	_check(_profiles_of(blob_restored["member_sim"]).size() > 0,
		"DET: A1 profiles still present after load + %d ticks" % CONTINUE_TICKS)
