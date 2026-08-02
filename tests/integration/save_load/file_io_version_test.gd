# tests/integration/save_load/file_io_version_test.gd
# Story SL-004: File I/O, JSON Encoding, and Version Checking
# (production/epics/save-load/story-004-file-io-json-version.md)
#
# Covers the BLOCKING ACs:
#   - AC6        version mismatch (higher/lower/wrong-type/missing) is rejected
#                gracefully in load_from_file() BEFORE any system is touched —
#                result.error mentions both versions; serialize counts stay 0
#   - AC-FILE-1  every FileAccess.store_*() return is checked: a mock
#                store_string() returning false makes save_to_file() error
#   - AC-FILE-2  flush() is called before close() (mock records call order);
#                close() is still called on the store_string-failure path
#   - AC-FILE-3  truncated/corrupt JSON -> "corrupted or truncated" with parse
#                line number; empty file; non-object JSON; missing version
#   - AC-FILE-4  save_to_file("my_save") writes user_data_dir/saves/my_save.sav.json
#                with parseable JSON matching the composed blob; overwrite works;
#                saves dir is created when missing; unsafe save names rejected
# plus the story QA edge cases (version as string, version=-1, version=0,
# special-char save names) and the JSON encoding contract (sort_keys=true
# deterministic output, full_precision=true via stringify).
#
# FileAccess itself is NOT mockable in GDScript (native class), so the write
# path is tested through the _file_access_factory seam: save_to_file() obtains
# its write handle from the factory when injected (duck-typed Object with
# store_string/flush/close — probe-verified in 4.7.1). Production wiring uses
# the real FileAccess; only the mock tests inject the factory.
#
# Run standalone: godot --headless --script tests/integration/save_load/file_io_version_test.gd
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"

# The four tick systems registered into SeededRNG (AC8's "all 4 registered").
const SYSTEMS_4: Array[String] = ["MemberSim", "Congestion", "Satisfaction", "Economy"]

# Orchestrator field name -> blob key name for the 5 spy-coordinated systems.
const SPY_FIELDS: Array[String] = [
	"grid_system", "member_sim", "congestion", "satisfaction", "economy",
]

## Mock write handle (duck-typed FileAccess replacement). Records the call
## order so AC-FILE-2 can assert flush-before-close, and lets the test
## simulate a failed store_string() (AC-FILE-1) or a failed open.
class MockHandle:
	extends RefCounted

	var order: Array[String] = []
	var store_result: bool = true

	func store_string(s: String) -> bool:
		order.append("store_string")
		return store_result

	func flush() -> void:
		order.append("flush")

	func close() -> void:
		order.append("close")


## Mock factory: returns a fresh MockHandle (or null for open-failure tests).
class MockFactory:
	extends RefCounted

	var handle: MockHandle
	var return_null: bool = false

	func open_write(file_path: String) -> Object:
		if return_null:
			return null
		handle = MockHandle.new()
		return handle


## Spy coordinated system: counts serialize() calls (AC6's "no system touched"
## is proven by serialize counts staying 0 through the whole load path).
class SerializeSpy:
	extends RefCounted

	var serialize_call_count: int = 0
	var payload: Dictionary = {}

	func serialize() -> Dictionary:
		serialize_call_count += 1
		return payload

	func on_tick(tick_count: int) -> void:
		pass


## TimeSystem subclass so its serialize() call count is observable.
class TimeSpy:
	extends TimeSystem

	var serialize_call_count: int = 0

	func serialize() -> Dictionary:
		serialize_call_count += 1
		return super.serialize()


var _pass := 0
var _fail := 0
var _created_files: Array[String] = []


## 被 tests/headless_runner.gd 托管时立即返回 —— 用例由 runner 调用的 run_all() 驱动。
func _init() -> void:
	if Engine.has_meta(RUNNER_META):
		return
	var result := run_all()
	quit(1 if int(result["fail"]) > 0 else 0)


func run_all() -> Dictionary:
	print("=".repeat(48))
	print("  INTEGRATION TEST: SaveLoad — File I/O, JSON Encoding & Version (Story SL-004)")
	print("=".repeat(48))

	_test_ac6_version_mismatch_higher()
	_test_ac6_version_mismatch_lower_and_negative()
	_test_ac6_version_wrong_type_string()
	_test_ac6_missing_version_field()
	_test_ac6_load_save_public_gate()
	_test_file1_store_string_failure_errors()
	_test_file1_store_string_success_ok()
	_test_file1_open_failure_errors()
	_test_file2_flush_before_close_order()
	_test_file2_close_still_called_on_write_failure()
	_test_file3_corrupt_json_errors()
	_test_file3_empty_file_errors()
	_test_file3_non_object_json_errors()
	_test_file4_writes_correct_path()
	_test_file4_parsed_json_matches_blob()
	_test_file4_overwrite_same_name()
	_test_file4_creates_save_dir()
	_test_file4_rejects_unsafe_save_names()
	_test_json_sort_keys_deterministic()
	_test_valid_roundtrip_version_match()

	_cleanup_files()

	print("\n=== FILE IO / VERSION TEST: %d passed, %d failed ===\n" % [_pass, _fail])
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


## Builds the SL-001 rig: real orchestrator + SeededRNG + TimeSpy + 5 spies +
## initialized SaveLoad. Returns the assembled rig for the test to drive.
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


## Resolves the on-disk path the same way save_to_file() does.
func _save_path(save_name: String) -> String:
	return OS.get_user_data_dir().path_join("saves").path_join(save_name + ".sav.json")


## Writes a raw string to a save slot on disk (test fixture — bypasses
## SaveLoad entirely so corrupt-file tests can plant arbitrary content).
func _plant_file(save_name: String, content: String) -> String:
	var path := _save_path(save_name)
	var dir := DirAccess.open("user://")
	if not dir.dir_exists(OS.get_user_data_dir().path_join("saves")):
		dir.make_dir_recursive(OS.get_user_data_dir().path_join("saves"))
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return ""
	f.store_string(content)
	f.flush()
	f.close()
	_created_files.append(path)
	return path


func _cleanup_files() -> void:
	for path in _created_files:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)
	_created_files.clear()


# === AC6: version mismatch → graceful rejection, no system touched ===

func _test_ac6_version_mismatch_higher() -> void:
	print("\n[AC6] version=99 (higher) -> rejected, error mentions BOTH versions, no system touched")
	var rig := _make_rig(12345)
	var path := _plant_file("sl004_v99", "{\"version\": 99, \"master_seed\": \"0x1\"}")
	_check(path != "", "planted version=99 save file")

	var arr: Array = rig["save_load"].call("load_from_file", "sl004_v99")
	var error: String = arr[1]
	_check(error != "", "version mismatch produces an error")
	_check(error.find("version mismatch") != -1, "error mentions 'version mismatch' (got: %s)" % error)
	_check(error.find("99") != -1 and error.find("1") != -1, "error mentions both versions 99 and 1 (got: %s)" % error)
	_check(arr[0].is_empty(), "no blob returned on version mismatch")
	_check(_total_serialize_calls(rig) == 0, "AC6: no system touched — zero serialize() calls (no Phase A even starts)")
	_check(int(rig["orchestrator"].call("get_tick_count")) == 0, "tick_count unchanged")


func _test_ac6_version_mismatch_lower_and_negative() -> void:
	print("\n[AC6] version=0 and version=-1 (lower/corrupt) -> both rejected")
	var rig := _make_rig(7)
	_plant_file("sl004_v0", "{\"version\": 0}")
	var arr0: Array = rig["save_load"].call("load_from_file", "sl004_v0")
	_check(arr0[1].find("version mismatch") != -1, "version=0 rejected with version-mismatch message")
	_check(arr0[1].find("0") != -1 and arr0[1].find("1") != -1, "version=0 message mentions 0 and 1 (got: %s)" % arr0[1])

	_plant_file("sl004_vneg", "{\"version\": -1}")
	var arrn: Array = rig["save_load"].call("load_from_file", "sl004_vneg")
	_check(arrn[1].find("version mismatch") != -1, "version=-1 rejected with version-mismatch message")
	_check(arrn[1].find("-1") != -1 and arrn[1].find("1") != -1, "version=-1 message mentions -1 and 1 (got: %s)" % arrn[1])


func _test_ac6_version_wrong_type_string() -> void:
	print("\n[AC6] version as STRING '1' -> rejected at type check, NO crash (GDScript String==int is a runtime error)")
	var rig := _make_rig(11)
	_plant_file("sl004_vstr", "{\"version\": \"1\"}")
	var arr: Array = rig["save_load"].call("load_from_file", "sl004_vstr")
	var error: String = arr[1]
	_check(error != "", "string version rejected (no crash)")
	_check(error.find("version mismatch") != -1, "string version produces a version-mismatch error (got: %s)" % error)
	_check(error.find("String") != -1, "error names the offending type (got: %s)" % error)
	_check(_total_serialize_calls(rig) == 0, "no system touched for wrong-type version")


func _test_ac6_missing_version_field() -> void:
	print("\n[AC6] missing version field -> rejected, no system touched")
	var rig := _make_rig(13)
	_plant_file("sl004_nover", "{\"master_seed\": \"0x1\"}")
	var arr: Array = rig["save_load"].call("load_from_file", "sl004_nover")
	_check(arr[1].find("missing version") != -1, "missing version field error (got: %s)" % arr[1])
	_check(_total_serialize_calls(rig) == 0, "no system touched for missing version")


func _test_ac6_load_save_public_gate() -> void:
	print("\n[AC6] load_save() public API -> ok=false, errors non-empty, no system touched")
	var rig := _make_rig(19)
	_plant_file("sl004_public", "{\"version\": 99}")
	var result: Dictionary = rig["save_load"].call("load_save", "sl004_public", PackedByteArray())
	_check(bool(result["ok"]) == false, "load_save ok == false on version mismatch")
	_check((result["errors"] as Array).size() > 0, "load_save errors non-empty")
	_check(str(result["errors"][0]).find("version mismatch") != -1, "load_save error mentions version mismatch")
	_check(_total_serialize_calls(rig) == 0, "no system touched through the public load path")


# === AC-FILE-1: every store_*() return value checked ===

func _test_file1_store_string_failure_errors() -> void:
	print("\n[AC-FILE-1] mock store_string() -> false: save_to_file() returns an error, not silent success")
	var rig := _make_rig(21)
	var factory := MockFactory.new()
	rig["save_load"].set("_file_access_factory", Callable(factory, "open_write"))
	factory.handle.store_result = false  # simulate disk-full / failed write

	var err: String = rig["save_load"].call("save_to_file", "sl004_failwrite")
	_check(err != "", "save_to_file returned an error when store_string() failed")
	_check(err.find("failed to write") != -1, "error mentions the write failure (got: %s)" % err)
	_check(factory.handle.order.has("close"), "close() still called on write failure (cleanup not skipped)")


func _test_file1_store_string_success_ok() -> void:
	print("\n[AC-FILE-1] mock store_string() -> true: no error")
	var rig := _make_rig(23)
	var factory := MockFactory.new()
	rig["save_load"].set("_file_access_factory", Callable(factory, "open_write"))
	var err: String = rig["save_load"].call("save_to_file", "sl004_okwrite")
	_check(err == "", "successful mock write returns empty error (got: '%s')" % err)


func _test_file1_open_failure_errors() -> void:
	print("\n[AC-FILE-1] mock open() -> null: save_to_file() reports the open failure")
	var rig := _make_rig(29)
	var factory := MockFactory.new()
	factory.return_null = true
	rig["save_load"].set("_file_access_factory", Callable(factory, "open_write"))
	var err: String = rig["save_load"].call("save_to_file", "sl004_openfail")
	_check(err != "", "open failure produces an error")
	_check(err.find("failed to open") != -1, "error mentions the open failure (got: %s)" % err)


# === AC-FILE-2: flush() before close() ===

func _test_file2_flush_before_close_order() -> void:
	print("\n[AC-FILE-2] mock records call order: store_string -> flush -> close (flush before close, exactly once each)")
	var rig := _make_rig(31)
	var factory := MockFactory.new()
	rig["save_load"].set("_file_access_factory", Callable(factory, "open_write"))
	var err: String = rig["save_load"].call("save_to_file", "sl004_order")
	_check(err == "", "mock write succeeded")
	var order: Array = factory.handle.order
	_check(order == ["store_string", "flush", "close"], "call order is exactly [store_string, flush, close] (got: %s)" % str(order))
	_check(order.count("flush") == 1, "flush() called exactly once")
	_check(order.count("close") == 1, "close() called exactly once")
	_check(order.find("flush") < order.find("close"), "flush() strictly before close()")


func _test_file2_close_still_called_on_write_failure() -> void:
	print("\n[AC-FILE-2] store_string fails -> close() is STILL called (cleanup not skipped on error)")
	var rig := _make_rig(37)
	var factory := MockFactory.new()
	rig["save_load"].set("_file_access_factory", Callable(factory, "open_write"))
	factory.handle.store_result = false
	var err: String = rig["save_load"].call("save_to_file", "sl004_orderfail")
	_check(err != "", "write failure surfaced as an error")
	_check(factory.handle.order.has("close"), "close() called on the failure path (got order: %s)" % str(factory.handle.order))


# === AC-FILE-3: corrupted / truncated / empty / wrong-structure files ===

func _test_file3_corrupt_json_errors() -> void:
	print("\n[AC-FILE-3] truncated JSON -> 'corrupted or truncated', parse line reported, no crash/partial parse")
	var rig := _make_rig(41)
	_plant_file("sl004_corrupt", "{this is not valid JSON")
	var arr: Array = rig["save_load"].call("load_from_file", "sl004_corrupt")
	var error: String = arr[1]
	_check(error.find("corrupted or truncated") != -1, "error includes 'corrupted or truncated' (got: %s)" % error)
	_check(error.find("line") != -1, "parse error line number is reported (got: %s)" % error)
	_check(arr[0].is_empty(), "no partial parse — blob is empty on corruption")
	_check(_total_serialize_calls(rig) == 0, "no system mutated by corrupt file")


func _test_file3_empty_file_errors() -> void:
	print("\n[AC-FILE-3] empty file -> 'is empty' error")
	var rig := _make_rig(43)
	_plant_file("sl004_empty", "")
	var arr: Array = rig["save_load"].call("load_from_file", "sl004_empty")
	_check(arr[1].find("is empty") != -1, "empty file error (got: %s)" % arr[1])


func _test_file3_non_object_json_errors() -> void:
	print("\n[AC-FILE-3] valid JSON but an ARRAY -> 'not a JSON object'")
	var rig := _make_rig(47)
	_plant_file("sl004_array", "[1, 2, 3]")
	var arr: Array = rig["save_load"].call("load_from_file", "sl004_array")
	_check(arr[1].find("not a JSON object") != -1, "array structure error (got: %s)" % arr[1])


# === AC-FILE-4: correct path, parseable JSON, overwrite, dir creation, safe names ===

func _test_file4_writes_correct_path() -> void:
	print("\n[AC-FILE-4] save_to_file('sl004_mysave') -> user_data_dir/saves/sl004_mysave.sav.json exists")
	var rig := _make_rig(53)
	var err: String = rig["save_load"].call("save_to_file", "sl004_mysave")
	_check(err == "", "save_to_file succeeded (got: '%s')" % err)
	var expected := _save_path("sl004_mysave")
	_check(FileAccess.file_exists(expected), "file exists at user_data_dir/saves/sl004_mysave.sav.json")
	_created_files.append(expected)


func _test_file4_parsed_json_matches_blob() -> void:
	print("\n[AC-FILE-4] written file is parseable JSON and matches the composed blob")
	var rig := _make_rig(59)
	rig["time_system"].call("resume")
	rig["time_system"].call("process", 0.1)  # one tick so TimeSystem has real state
	var blob_before: Dictionary = rig["save_load"].call("_perform_save")

	var err: String = rig["save_load"].call("save_to_file", "sl004_match")
	_check(err == "", "save_to_file succeeded")

	var path := _save_path("sl004_match")
	_created_files.append(path)
	var f := FileAccess.open(path, FileAccess.READ)
	_check(f != null, "written file opens for reading")
	if f == null:
		return
	var raw := f.get_as_text()
	f.close()

	var json := JSON.new()
	var parse_error := json.parse(raw)
	_check(parse_error == OK, "written file content parses as JSON")
	if parse_error != OK:
		return
	var parsed: Dictionary = json.get_data()
	_check(int(parsed["version"]) == 1, "parsed version == SAVE_FORMAT_VERSION (1)")
	_check(str(parsed["master_seed"]) == str(blob_before["master_seed"]), "parsed master_seed matches the blob")
	_check(parsed.size() == blob_before.size(), "parsed key set size matches the blob (%d == %d)" % [parsed.size(), blob_before.size()])
	# JSON parses integer literals as FLOAT (1 -> 1.0) — compare numerically.
	_check(float(parsed["time_system"]["tick_count"]) == float(blob_before["time_system"]["tick_count"]), "parsed tick_count matches (%.0f == %.0f)" % [float(parsed["time_system"]["tick_count"]), float(blob_before["time_system"]["tick_count"])])


func _test_file4_overwrite_same_name() -> void:
	print("\n[AC-FILE-4] saving twice to the same name OVERWRITES the previous content")
	var rig := _make_rig(61)
	_check(rig["save_load"].call("save_to_file", "sl004_over") == "", "first save ok")
	# Run one tick so the second blob differs (tick_count advances).
	rig["time_system"].call("resume")
	rig["time_system"].call("process", 0.1)
	_check(rig["save_load"].call("save_to_file", "sl004_over") == "", "second save ok")

	var path := _save_path("sl004_over")
	_created_files.append(path)
	var f := FileAccess.open(path, FileAccess.READ)
	var raw := f.get_as_text()
	f.close()
	var json := JSON.new()
	json.parse(raw)
	_check(int(json.get_data()["time_system"]["tick_count"]) == 1, "overwritten file holds the NEW content (tick_count==1)")


func _test_file4_creates_save_dir() -> void:
	print("\n[AC-FILE-4] save dir is created when missing (make_dir_recursive)")
	var rig := _make_rig(67)
	var save_dir := OS.get_user_data_dir().path_join("saves")
	# Remove the dir if present so we prove creation (safe: only our sl004_ files live there from this run).
	if DirAccess.dir_exists_absolute(save_dir):
		for leftover in _created_files:
			if FileAccess.file_exists(leftover):
				DirAccess.remove_absolute(leftover)
		_created_files.clear()
		DirAccess.remove_absolute(save_dir)
	_check(not DirAccess.dir_exists_absolute(save_dir), "save dir absent before save")

	var err: String = rig["save_load"].call("save_to_file", "sl004_dircreate")
	_check(err == "", "save_to_file succeeded with missing dir")
	_check(DirAccess.dir_exists_absolute(save_dir), "save dir exists after save (make_dir_recursive)")
	var expected := _save_path("sl004_dircreate")
	_check(FileAccess.file_exists(expected), "file exists after dir auto-creation")
	_created_files.append(expected)


func _test_file4_rejects_unsafe_save_names() -> void:
	print("\n[AC-FILE-4] special/path-traversal save names are REJECTED")
	var rig := _make_rig(71)
	var err_empty: String = rig["save_load"].call("save_to_file", "")
	_check(err_empty.find("must not be empty") != -1, "empty save name rejected (got: '%s')" % err_empty)

	var err_slash: String = rig["save_load"].call("save_to_file", "../escape")
	_check(err_slash.find("invalid save name") != -1, "path-traversal save name rejected (got: '%s')" % err_slash)

	var err_backslash: String = rig["save_load"].call("save_to_file", "..\\escape")
	_check(err_backslash.find("invalid save name") != -1, "backslash save name rejected (got: '%s')" % err_backslash)
	_check(not FileAccess.file_exists(_save_path("../escape")), "no file escaped the saves dir")


# === JSON encoding contract ===

func _test_json_sort_keys_deterministic() -> void:
	print("\n[JSON] output uses sort_keys=true (deterministic key order for diffing)")
	var rig := _make_rig(73)
	_check(rig["save_load"].call("save_to_file", "sl004_sorted") == "", "save ok")
	var path := _save_path("sl004_sorted")
	_created_files.append(path)
	var f := FileAccess.open(path, FileAccess.READ)
	var raw := f.get_as_text()
	f.close()
	# Alphabetically, "congestion" is the first CONTRIBUTING_KEYS key and
	# "version" the last — sort_keys=true means the file opens with it.
	_check(raw.begins_with("{\n  \"congestion\""), "top-level keys are sorted alphabetically (starts with 'congestion', got: %s)" % raw.substr(0, 40))
	_check(raw.find("\"version\"") > raw.find("\"congestion\""), "version key appears after congestion (sorted)")


func _test_valid_roundtrip_version_match() -> void:
	print("\n[roundtrip] valid save with version=1 loads back with NO error (exact match)")
	var rig := _make_rig(79)
	rig["time_system"].call("resume")
	rig["time_system"].call("process", 0.1)
	_check(rig["save_load"].call("save_to_file", "sl004_roundtrip") == "", "save ok")
	var path := _save_path("sl004_roundtrip")
	_created_files.append(path)

	var arr: Array = rig["save_load"].call("load_from_file", "sl004_roundtrip")
	_check(arr[1] == "", "round-trip load has NO error (got: '%s')" % arr[1])
	var blob: Dictionary = arr[0]
	_check(not blob.is_empty(), "round-trip returns a blob")
	_check(float(blob["version"]) == 1.0, "round-trip blob version == 1 (float 1.0 from JSON == int 1 numerically)")
	_check(blob.has("master_seed") and blob.has("time_system") and blob.has("grid_system"), "round-trip blob has the key structure")
