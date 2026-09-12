# tests/integration/save_load/save_root_override_test.gd
# SaveLoad save-root override (test seam) + environment independence
#
# WHY THIS EXISTS: the save tree defaults to OS.get_user_data_dir(). In a
# sandboxed, containerised or HOME-less runner that directory may be read-only,
# which turned every disk-touching save assertion into a FALSE failure (16 of
# them on 2026-09-12, in file_io_version_test / first_day_playable_test /
# main_entry_process_test). The override lets a test root the whole save tree at
# an OS temp dir instead, so the suite's result no longer depends on where it
# runs.
#
# Covers:
#   - default root == OS.get_user_data_dir() (production is unaffected)
#   - get_save_dir()/get_save_path() honour the override
#   - the override composes with the playtest-ID namespace
#   - clearing the override restores the production default exactly
#   - the override is PER INSTANCE (no cross-instance leakage)
#   - a real write/read round trip succeeds under the override, and the same
#     slot is NOT created under the OS user data dir
#
# Run standalone: godot --headless --script tests/integration/save_load/save_root_override_test.gd
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"

const SAVE_LOAD_PATH := "res://src/systems/save_load.gd"
const SAVE_DIR := "saves"
const SAVE_EXTENSION := ".sav.json"

var _pass := 0
var _fail := 0
var _created_paths: Array[String] = []


## 被 tests/headless_runner.gd 托管时立即返回 —— 用例由 runner 调用的 run_all() 驱动。
func _init() -> void:
	if Engine.has_meta(RUNNER_META):
		return
	var result := run_all()
	quit(1 if int(result["fail"]) > 0 else 0)


## 返回 {"pass": int, "fail": int} —— 见 tests/headless_runner.gd 的测试文件契约
func run_all() -> Dictionary:
	print("=".repeat(48))
	print("  INTEGRATION TEST: SaveLoad — Save-Root Override (env independence)")
	print("=".repeat(48))

	_test_default_root()
	_test_override_changes_resolution()
	_test_override_composes_with_playtest_id()
	_test_clearing_override_restores_default()
	_test_override_is_per_instance()
	_test_real_write_read_under_override()
	_test_override_accepts_whitespace_trim()

	_cleanup()

	print("\n=== SAVE ROOT OVERRIDE TEST: %d passed, %d failed ===\n" % [_pass, _fail])
	return {"pass": _pass, "fail": _fail}


func _check(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
		print("  PASS: " + msg)
	else:
		_fail += 1
		print("  FAIL: " + msg)


# === Helpers ===

func _new_save_load() -> RefCounted:
	return (load(SAVE_LOAD_PATH) as Script).new()


## Unique temp root per run so repeated runs never see each other's leftovers.
func _temp_root() -> String:
	return OS.get_temp_dir().path_join("gym_manager_save_root_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()])


func _cleanup() -> void:
	for p in _created_paths:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)
	_created_paths.clear()


# === Case: production default is untouched ===

func _test_default_root() -> void:
	print("\n[default] with no override, the save tree is the OS user data dir")
	var sl: RefCounted = _new_save_load()

	_check(sl.call("get_save_root_override") == "", "fresh instance has no override")
	_check(sl.call("get_save_root") == OS.get_user_data_dir(),
		"get_save_root() == OS.get_user_data_dir() with no override")
	_check(sl.call("get_save_dir") == OS.get_user_data_dir().path_join(SAVE_DIR),
		"get_save_dir() resolves under the OS user data dir (production behaviour unchanged)")
	_check(sl.call("get_save_path", "manual") == OS.get_user_data_dir().path_join(SAVE_DIR).path_join("manual" + SAVE_EXTENSION),
		"get_save_path() resolves under the OS user data dir")


# === Case: override changes resolution ===

func _test_override_changes_resolution() -> void:
	print("\n[override] the save tree follows the injected root")
	var root := _temp_root()
	var sl: RefCounted = _new_save_load()
	sl.call("set_save_root_override", root)

	_check(sl.call("get_save_root_override") == root, "override is stored verbatim")
	_check(sl.call("get_save_root") == root, "get_save_root() returns the override")
	_check(sl.call("get_save_dir") == root.path_join(SAVE_DIR), "get_save_dir() is <root>/saves")
	_check(sl.call("get_save_path", "manual") == root.path_join(SAVE_DIR).path_join("manual" + SAVE_EXTENSION),
		"get_save_path() is <root>/saves/manual.sav.json")
	_check(not String(sl.call("get_save_dir")).begins_with(OS.get_user_data_dir()),
		"the resolved dir is OUTSIDE the OS user data dir")


# === Case: override composes with the playtest namespace ===

func _test_override_composes_with_playtest_id() -> void:
	print("\n[compose] override + playtest ID nest correctly")
	var root := _temp_root()
	var sl: RefCounted = _new_save_load()
	sl.call("set_save_root_override", root)
	sl.call("set_playtest_id", "p01")

	var expected := root.path_join(SAVE_DIR).path_join("playtests").path_join("P01")
	_check(sl.call("get_save_dir") == expected, "override + ID -> <root>/saves/playtests/P01")
	_check(sl.call("get_save_path", "manual") == expected.path_join("manual" + SAVE_EXTENSION),
		"save path nests under the overridden playtest dir")

	# Order independence: override first vs ID first must agree.
	var sl2: RefCounted = _new_save_load()
	sl2.call("set_playtest_id", "p01")
	sl2.call("set_save_root_override", root)
	_check(sl2.call("get_save_dir") == expected, "setting the override after the ID agrees")

	# Clearing the ID keeps the override active.
	sl.call("set_playtest_id", "")
	_check(sl.call("get_save_dir") == root.path_join(SAVE_DIR),
		"clearing the playtest ID keeps the override root")


# === Case: clearing the override restores production exactly ===

func _test_clearing_override_restores_default() -> void:
	print("\n[restore] clearing the override returns to the production default")
	var root := _temp_root()
	var sl: RefCounted = _new_save_load()

	sl.call("set_save_root_override", root)
	_check(sl.call("get_save_dir") == root.path_join(SAVE_DIR), "override active")

	sl.call("set_save_root_override", "")
	_check(sl.call("get_save_root_override") == "", "override cleared")
	_check(sl.call("get_save_root") == OS.get_user_data_dir(), "root is the OS user data dir again")
	_check(sl.call("get_save_dir") == OS.get_user_data_dir().path_join(SAVE_DIR),
		"save dir is the exact production path again")


# === Case: the override is per instance ===

func _test_override_is_per_instance() -> void:
	print("\n[scope] the override does not leak between instances")
	var root := _temp_root()
	var a: RefCounted = _new_save_load()
	var b: RefCounted = _new_save_load()

	a.call("set_save_root_override", root)

	_check(a.call("get_save_root") == root, "instance A uses the override")
	_check(b.call("get_save_root_override") == "", "instance B has no override")
	_check(b.call("get_save_root") == OS.get_user_data_dir(), "instance B still uses the OS user data dir")


# === Case: the actual payoff — a real round trip inside the override root ===

func _test_real_write_read_under_override() -> void:
	print("\n[proof] a real save/read round trip works under the override, and never touches user_data_dir")
	var root := _temp_root()
	var sl: RefCounted = _new_save_load()
	sl.call("set_save_root_override", root)

	var saves_dir: String = sl.call("get_save_dir")
	var payload := "{\"probe\":true,\"value\":42}"

	# Create the tree and write through the resolved path, exactly as save_to_file does.
	var mk := DirAccess.make_dir_recursive_absolute(saves_dir)
	_check(mk == OK, "save dir created under the override root (err %d)" % mk)

	var file_path: String = sl.call("get_save_path", "override_probe")
	var f := FileAccess.open(file_path, FileAccess.WRITE)
	_check(f != null, "opened the overridden save path for writing")
	if f == null:
		return
	f.store_string(payload)
	f.flush()
	f.close()
	_created_paths.append(file_path)

	_check(FileAccess.file_exists(file_path), "file exists at the overridden path")

	var r := FileAccess.open(file_path, FileAccess.READ)
	_check(r != null, "reopened the overridden save path for reading")
	if r != null:
		var got := r.get_as_text()
		r.close()
		_check(got == payload, "round-tripped content matches (wrote %d bytes, read %d)" % [payload.length(), got.length()])

	# The same slot name must NOT have been created under the OS user data dir.
	var user_data_slot := OS.get_user_data_dir().path_join(SAVE_DIR).path_join("override_probe" + SAVE_EXTENSION)
	_check(not FileAccess.file_exists(user_data_slot),
		"the OS user data dir was NOT touched by the overridden write")

	# save_exists() must answer against the override, not the production root.
	_check(bool(sl.call("save_exists", "override_probe")), "save_exists() sees the overridden file")

	var plain: RefCounted = _new_save_load()
	_check(not bool(plain.call("save_exists", "override_probe")),
		"a default-root instance does NOT see it (proves the override is what made the difference)")


func _test_override_accepts_whitespace_trim() -> void:
	print("\n[input] surrounding whitespace in the override is trimmed")
	var root := _temp_root()
	var sl: RefCounted = _new_save_load()

	sl.call("set_save_root_override", "  " + root + "  ")
	_check(sl.call("get_save_root_override") == root, "whitespace-padded override is trimmed")
	_check(sl.call("get_save_dir") == root.path_join(SAVE_DIR), "trimmed override resolves correctly")

	# Whitespace-only must be treated as "no override" (production default).
	sl.call("set_save_root_override", "   ")
	_check(sl.call("get_save_root_override") == "", "whitespace-only override normalises to empty")
	_check(sl.call("get_save_root") == OS.get_user_data_dir(), "whitespace-only override falls back to production")
