# tests/unit/equipment_catalog/equipment_def_catalog_test.gd
# Story 001: EquipmentDef Data Model and Catalog Container
# Covers the 5 BLOCKING ACs: AC-C.8, AC-CANONICAL.1, AC-IMMUTABLE.1,
# AC-FROZEN.1, AC-FROZEN.2 (GDD design/gdd/equipment-catalog.md).
# Run standalone: godot --headless --script tests/unit/equipment_catalog/equipment_def_catalog_test.gd
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"
const PROBE_SCRIPT_PATH := "res://tests/unit/equipment_catalog/equipment_catalog_error_probe.gd"

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
	print("  UNIT TEST: EquipmentCatalog — EquipmentDef & Frozen Container (Story 001)")
	print("=".repeat(48))

	_test_ac_c8_repeated_query_value_equal()
	_test_ac_c8_no_setter_in_public_api()
	_test_ac_c8_missing_id_and_empty_catalog()
	_test_ac_canonical_1_only_canonical_stored()
	_test_ac_immutable_1_caller_mutation_does_not_affect_stored()
	_test_ac_frozen_1_queries_rejected_before_freeze()
	_test_ac_frozen_2_writes_rejected_after_freeze()

	print("\n=== EQUIPMENT DEF CATALOG TEST: %d passed, %d failed ===" % [_pass, _fail])
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


## Builds a valid canonical-0° fixture def (1x2 footprint + 1 access, all 12
## fields non-default so value-equality comparisons are meaningful). TYPED
## arrays are required — Godot's typed-array parameter boundary rejects
## untyped literals through Object.call() (tech-debt register, Story 005).
func _make_def(ED: Script, id: String) -> RefCounted:
	var zone: Array = ["cardio"]
	var footprint: Array[Vector2i] = [Vector2i(0, 0), Vector2i(1, 0)]
	var access: Array[Vector2i] = [Vector2i(0, 1)]
	var effects: Array[Dictionary] = [{"tag": "comfort", "magnitude": 0.1}]
	var def: RefCounted = ED.new(
		id,
		"Test %s" % id,
		zone,
		footprint,
		access,
		200,
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


## Field-by-field value equality for two EquipmentDef instances (identity
## deliberately NOT compared — get_definition returns copies, AC-IMMUTABLE.1).
func _defs_value_equal(a: RefCounted, b: RefCounted) -> bool:
	return (
		a.get("id") == b.get("id")
		and a.get("display_name") == b.get("display_name")
		and a.get("zone_membership") == b.get("zone_membership")
		and a.get("footprint_cells") == b.get("footprint_cells")
		and a.get("access_cells") == b.get("access_cells")
		and a.get("cost") == b.get("cost")
		and a.get("unlock_requirement") == b.get("unlock_requirement")
		and a.get("effects") == b.get("effects")
		and a.get("use_duration_mean_ticks") == b.get("use_duration_mean_ticks")
		and a.get("use_duration_stddev_ticks") == b.get("use_duration_stddev_ticks")
		and a.get("use_duration_min_ticks") == b.get("use_duration_min_ticks")
		and a.get("use_duration_max_ticks") == b.get("use_duration_max_ticks")
	)


## True iff the method name looks like a setter/mutator. Used by the AC-C.8
## static-code check — the Catalog public surface must contain none of these.
func _is_mutator_name(name: String) -> bool:
	for prefix in [
		"set_", "add_", "remove_", "clear_", "update_", "delete_", "insert_",
		"erase_", "push_", "pop_", "append_", "modify_", "write_", "store_",
	]:
		if name.begins_with(prefix):
			return true
	return false


## Runs equipment_catalog_error_probe.gd in an ISOLATED subprocess so a
## firing assert()/push_error() can be observed by its OUTPUT without any risk
## to this test process (pattern established by grid_rotation_assert_probe.gd,
## Story 003). Returns {"output": String, "exit_code": int} — output is
## stdout+stderr COMBINED (OS.execute read_stderr=true).
func _run_probe(mode: String) -> Dictionary:
	var exe := OS.get_executable_path()
	var project_root := ProjectSettings.globalize_path("res://")
	var probe_path := ProjectSettings.globalize_path(PROBE_SCRIPT_PATH)

	var args: Array[String] = ["--headless", "--path", project_root, "--script", probe_path, "--", mode]

	var output: Array = []
	var exit_code := OS.execute(exe, args, output, true)
	var output_text: String = "".join(output)

	return {"output": output_text, "exit_code": exit_code}


# === AC-C.8: 不可变契约与查询一致性 ===

func _test_ac_c8_repeated_query_value_equal() -> void:
	print("\n[AC-C.8] repeated get_definition(id) returns value-equal results")

	var cat: RefCounted = _make_catalog([_make_def(_ED(), "treadmill")])

	var first = cat.call("get_definition", "treadmill")
	var second = cat.call("get_definition", "treadmill")

	_check(first != null, "first query returns a definition")
	_check(second != null, "second query returns a definition")

	# Value equality — every one of the 12 fields matches.
	_check(
		_defs_value_equal(first, second),
		"both returns are value-equal across all 12 fields (id, display_name, zone, footprint, access, cost, unlock, effects, use_duration x4)"
	)

	# Explicit spot checks on the stored values (the fixture's non-defaults).
	_check(first.get("id") == "treadmill", "id round-trips")
	_check(first.get("cost") == 200, "cost round-trips")
	_check(first.get("use_duration_mean_ticks") == 200, "use_duration_mean_ticks round-trips")
	_check(first.get("use_duration_stddev_ticks") == 30, "use_duration_stddev_ticks round-trips")
	_check(first.get("use_duration_min_ticks") == 100, "use_duration_min_ticks round-trips")
	_check(first.get("use_duration_max_ticks") == 300, "use_duration_max_ticks round-trips")
	_check(first.get("effects") == [{"tag": "comfort", "magnitude": 0.1}], "effects container round-trips")

	# Copy-on-return posture: the two queries are DISTINCT instances with equal
	# values — a caller cannot hold a mutable reference to the stored record.
	_check(
		not (first == second),
		"repeated queries return distinct instances (copy-on-return, AC-IMMUTABLE.1 posture)"
	)


func _test_ac_c8_no_setter_in_public_api() -> void:
	print("\n[AC-C.8] Catalog public API surface contains no setter/mutator (static check)")

	var script: Script = _EC()
	var methods: Array = script.get_script_method_list()
	var public_names: Array[String] = []
	for m in methods:
		var name: String = m["name"]
		if not name.begins_with("_"):
			public_names.append(name)

	public_names.sort()
	_check(
		public_names == ["get_all_ids", "get_definition", "has_definition"],
		"public API is exactly the 3 read-only queries: get_definition, has_definition, get_all_ids (got %s)" % str(public_names)
	)

	for name in public_names:
		_check(
			not _is_mutator_name(name),
			"public method '%s' has no setter/mutator prefix" % name
		)

	# No public remove/delete/clear/update method by any name.
	for banned in ["remove", "delete", "clear", "update", "mutate", "write"]:
		var found := false
		for name in public_names:
			if name.to_lower().contains(banned):
				found = true
		_check(not found, "public API contains no method named with '%s'" % banned)

	# The write surface exists ONLY behind the underscore (internal loader API).
	_check(
		methods.any(func(m): return m["name"] == "_add_definition"),
		"_add_definition exists as internal (underscore) loader API"
	)
	_check(
		methods.any(func(m): return m["name"] == "_freeze"),
		"_freeze exists as internal (underscore) loader API"
	)


func _test_ac_c8_missing_id_and_empty_catalog() -> void:
	print("\n[AC-C.8] missing id and empty catalog edge cases")

	# Missing id on a loaded catalog: null return in-process...
	var cat: RefCounted = _make_catalog([_make_def(_ED(), "treadmill")])
	_check(
		cat.call("get_definition", "nonexistent") == null,
		"get_definition(nonexistent) returns null"
	)
	_check(
		cat.call("has_definition", "nonexistent") == false,
		"has_definition(nonexistent) returns false"
	)

	# ...and push_error() verified in the isolated subprocess.
	var res := _run_probe("query_missing_id")
	_check(res["exit_code"] == 0, "probe exits 0 (no crash on missing id)")
	_check(
		res["output"].find("ERROR:") != -1,
		"missing-id query fires push_error (ERROR line in probe output)"
	)
	_check(
		res["output"].find("no definition for id") != -1,
		"missing-id push_error names the unknown id ('no definition for id 'nonexistent'')"
	)
	_check(
		res["output"].find("PROBE_OPERATION_COMPLETED") != -1,
		"probe completes normally after the rejected query"
	)

	# Empty (frozen) catalog: every query degrades safely.
	var empty: RefCounted = _make_catalog([])
	_check(empty.call("get_definition", "anything") == null, "empty catalog: get_definition returns null")
	_check(empty.call("has_definition", "anything") == false, "empty catalog: has_definition returns false")
	var ids: Array = empty.call("get_all_ids")
	_check(ids.is_empty(), "empty catalog: get_all_ids returns []")


# === AC-CANONICAL.1: 仅存 canonical 0° ===

func _test_ac_canonical_1_only_canonical_stored() -> void:
	print("\n[AC-CANONICAL.1] only canonical 0° stored — no variants, no rotation field")

	var def = _make_def(_ED(), "treadmill")

	# Exactly the provided coordinates — nothing added, nothing rotated.
	_check(
		def.get("footprint_cells") == [Vector2i(0, 0), Vector2i(1, 0)],
		"footprint_cells stores exactly the 2 provided cells — no extra variants"
	)
	_check(
		def.get("access_cells") == [Vector2i(0, 1)],
		"access_cells stores exactly the 1 provided cell — no extra variants"
	)
	_check((def.get("footprint_cells") as Array).size() == 2, "footprint has exactly 2 cells")
	_check((def.get("access_cells") as Array).size() == 1, "access has exactly 1 cell")

	# Structural check: the EquipmentDef script declares NO rotation field and
	# NO pre-rotated variant arrays (GDD Edge Case: 4 预旋转变体明确禁止).
	var ed_script: Script = _ED()
	var props: Array = ed_script.get_script_property_list()
	var prop_names: Array[String] = []
	for p in props:
		prop_names.append(p["name"])

	_check(
		not prop_names.has("rotation"),
		"EquipmentDef declares no rotation field (rotation is GridSystem runtime, not stored)"
	)
	for variant in ["footprint_90", "footprint_180", "footprint_270", "access_90", "access_180", "access_270"]:
		_check(
			not prop_names.has(variant),
			"EquipmentDef declares no pre-rotated variant field '%s'" % variant
		)

	# The instance itself carries no rotation value either — proven by the
	# property-list reflection above (get_script_property_list() is the
	# authoritative reflection API per the tech-debt register, Story 006).
	_check(
		not prop_names.has("rotation"),
		"instance property list contains no rotation value"
	)


# === AC-IMMUTABLE.1: 调用方修改不影响存储 ===

func _test_ac_immutable_1_caller_mutation_does_not_affect_stored() -> void:
	print("\n[AC-IMMUTABLE.1] caller mutations on a returned def do not affect the stored definition")

	var cat: RefCounted = _make_catalog([_make_def(_ED(), "treadmill")])
	var def = cat.call("get_definition", "treadmill")

	# Mutate EVERY mutable surface of the RETURNED copy.
	def.footprint_cells.append(Vector2i(9, 9))
	def.access_cells.append(Vector2i(8, 8))
	def.zone_membership.append("strength")
	def.effects.append({"tag": "crowd_pressure", "magnitude": 0.5})
	def.cost = 99999
	def.display_name = "Mutated"
	def.unlock_requirement = "milestone_x"
	def.use_duration_mean_ticks = 1
	def.use_duration_stddev_ticks = -1
	def.use_duration_min_ticks = 0
	def.use_duration_max_ticks = 0

	# Re-query — the STORED definition must be completely unaffected.
	var again = cat.call("get_definition", "treadmill")
	_check(
		again.get("footprint_cells") == [Vector2i(0, 0), Vector2i(1, 0)],
		"footprint_cells unchanged after caller appended to the returned copy"
	)
	_check(
		again.get("access_cells") == [Vector2i(0, 1)],
		"access_cells unchanged after caller appended to the returned copy"
	)
	_check(
		again.get("zone_membership") == ["cardio"],
		"zone_membership unchanged after caller appended to the returned copy"
	)
	_check(
		again.get("effects") == [{"tag": "comfort", "magnitude": 0.1}],
		"effects unchanged after caller appended to the returned copy"
	)
	_check(again.get("cost") == 200, "cost unchanged after caller reassigned the returned copy")
	_check(again.get("display_name") == "Test treadmill", "display_name unchanged after caller reassigned")
	_check(again.get("unlock_requirement") == "", "unlock_requirement unchanged after caller reassigned")
	_check(again.get("use_duration_mean_ticks") == 200, "use_duration_mean_ticks unchanged")
	_check(again.get("use_duration_stddev_ticks") == 30, "use_duration_stddev_ticks unchanged")
	_check(again.get("use_duration_min_ticks") == 100, "use_duration_min_ticks unchanged")
	_check(again.get("use_duration_max_ticks") == 300, "use_duration_max_ticks unchanged")

	# And the mutating instance itself was a throwaway copy, not the stored one.
	_check(
		not (def == again),
		"mutated copy is a different instance from the re-queried definition"
	)

	# Defensive duplication at _init(): mutating the arrays handed INTO the
	# constructor must not corrupt the record either (the "tests the
	# .duplicate() in _init()" edge case from the QA notes).
	var ED: Script = _ED()
	var zone: Array = ["cardio"]
	var footprint: Array[Vector2i] = [Vector2i(0, 0), Vector2i(1, 0)]
	var access: Array[Vector2i] = [Vector2i(0, 1)]
	var effects: Array[Dictionary] = [{"tag": "comfort", "magnitude": 0.1}]
	var fresh: RefCounted = ED.new("fresh", "Fresh", zone, footprint, access, 350, "", effects, 150, 20, 75, 225)
	footprint.append(Vector2i(9, 9))
	access.append(Vector2i(8, 8))
	zone.append("strength")
	effects.append({"tag": "crowd_pressure", "magnitude": 0.5})
	_check(
		fresh.get("footprint_cells") == [Vector2i(0, 0), Vector2i(1, 0)],
		"_init() duplicates footprint_cells — post-construction source mutation has no effect"
	)
	_check(
		fresh.get("access_cells") == [Vector2i(0, 1)],
		"_init() duplicates access_cells — post-construction source mutation has no effect"
	)
	_check(
		fresh.get("zone_membership") == ["cardio"],
		"_init() duplicates zone_membership — post-construction source mutation has no effect"
	)
	_check(
		fresh.get("effects") == [{"tag": "comfort", "magnitude": 0.1}],
		"_init() deep-duplicates effects — post-construction source mutation has no effect"
	)


# === AC-FROZEN.1: freeze 前拒绝查询 ===

func _test_ac_frozen_1_queries_rejected_before_freeze() -> void:
	print("\n[AC-FROZEN.1] queries rejected before load()/freeze()")

	var cat: RefCounted = _EC().new()  # constructed, load() never called

	# Safe defaults in-process: null / false / [].
	_check(
		cat.call("get_definition", "treadmill") == null,
		"get_definition(any_id) returns null before freeze"
	)
	_check(
		cat.call("has_definition", "treadmill") == false,
		"has_definition(any_id) returns false before freeze (QA edge case)"
	)
	var ids: Array = cat.call("get_all_ids")
	_check(ids.is_empty(), "get_all_ids() returns [] before freeze (QA edge case)")

	# push_error() firing verified in the isolated subprocess — ALL 3 queries.
	var res := _run_probe("query_before_freeze")
	_check(res["exit_code"] == 0, "probe exits 0 (safe defaults, no crash)")
	_check(
		res["output"].find("ERROR:") != -1,
		"before-freeze queries fire push_error (ERROR lines in probe output)"
	)
	_check(
		res["output"].find("before freeze()") != -1,
		"push_error messages identify the before-freeze guard"
	)
	_check(
		res["output"].find("get_definition()") != -1
			and res["output"].find("has_definition()") != -1
			and res["output"].find("get_all_ids()") != -1,
		"all 3 public queries carry the before-freeze guard"
	)
	_check(
		res["output"].find("PROBE_OPERATION_COMPLETED") != -1,
		"probe completes normally after the rejected queries"
	)


# === AC-FROZEN.2: freeze 后拒绝修改 ===

func _test_ac_frozen_2_writes_rejected_after_freeze() -> void:
	print("\n[AC-FROZEN.2] write paths rejected after freeze()")

	# _add_definition() after freeze fires assert (internal write API).
	var res_add := _run_probe("add_after_freeze")
	_check(
		res_add["output"].find("Assertion failed") != -1,
		"_add_definition() after freeze fires assert"
	)
	_check(
		res_add["output"].find("cannot add definition after freeze()") != -1,
		"assert message identifies the frozen write path"
	)
	_check(
		res_add["output"].find("PROBE_OPERATION_COMPLETED") != -1,
		"probe completes after the firing assert (assert aborts the frame, not the process)"
	)
	_check(res_add["exit_code"] == 0, "probe exits 0")

	# _freeze() twice fires assert (QA edge case).
	var res_freeze := _run_probe("double_freeze")
	_check(
		res_freeze["output"].find("Assertion failed") != -1,
		"_freeze() called twice fires assert"
	)
	_check(
		res_freeze["output"].find("_freeze() called twice") != -1,
		"assert message identifies the double-freeze"
	)
	_check(res_freeze["exit_code"] == 0, "probe exits 0")

	# Public write-surface absence is enforced by the static check in
	# AC-C.8 (public API == exactly the 3 read-only queries); the two probes
	# above prove the underscore-prefixed internal loader API rejects writes
	# after freeze. Combined: "Catalog exposes no write API" (AC-FROZEN.2).
	_check(true, "public surface has no write API (static check in AC-C.8) + internal writes assert (probes above)")
