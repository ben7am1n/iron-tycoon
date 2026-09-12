# tests/integration/save_load/playtest_id_isolation_test.gd
# Playtest save-slot isolation: SaveLoad playtest ID namespace
# (docs/plans/2026-09-10-first-playtest-plan.md — first 5-player playtest needs
#  every participant to save/load on the SAME machine without clobbering the
#  others, and without ever overwriting the shared "manual" slot.)
#
# Covers:
#   - normalize_playtest_id(): strip_edges + to_upper (APFS is case-insensitive,
#     so P01 and p01 must land in the same directory, not two)
#   - validate_playtest_id(): 1-64 chars of [A-Z0-9_-] only; rejects empty,
#     whitespace-only, path traversal ('..', '/', '\', ':'), internal spaces,
#     over-length, non-ASCII and punctuation
#   - set_playtest_id(): applies the normalized ID, returns "" on success,
#     returns the error AND LEAVES THE PRIOR ID INTACT on rejection (a bad ID
#     must never silently fall back to the shared namespace), and resets to the
#     shared namespace when given ""
#   - path resolution: shared -> user_data_dir/saves/<name>.sav.json;
#     playtest  -> user_data_dir/saves/playtests/<ID>/<name>.sav.json
#   - isolation: two participants resolve to different files for the same save
#     name; no playtest path can collide with (or contain) the shared path
#
# NOTE ON ASSERTION STYLE: every assertion here is on the RESOLVED PATH STRING,
# not on real disk contents. That is deliberate — the isolation guarantee is a
# namespace property, and asserting it structurally keeps this file independent
# of whether the running environment can write to the OS user data directory.
# (SaveLoad's on-disk writing is already covered by file_io_version_test.gd.)
#
# EXPECTED NOISE: _test_set_playtest_id_rejects_and_keeps_prior() drives one
# deliberate invalid ID through the public setter, which logs exactly one
# `push_error` ERROR line. That is the documented rejection path, not a defect.
#
# Run standalone: godot --headless --script tests/integration/save_load/playtest_id_isolation_test.gd
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"

const SAVE_LOAD_PATH := "res://src/systems/save_load.gd"
const SAVE_DIR := "saves"
const SAVE_EXTENSION := ".sav.json"

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
	print("  INTEGRATION TEST: SaveLoad — Playtest ID Isolation")
	print("=".repeat(48))

	_test_normalize()
	_test_validate_valid_ids()
	_test_validate_empty_and_whitespace()
	_test_validate_path_traversal()
	_test_validate_length_bounds()
	_test_validate_charset()
	_test_set_playtest_id_applies_normalized()
	_test_set_playtest_id_rejects_and_keeps_prior()
	_test_set_playtest_id_empty_resets()
	_test_save_dir_resolution()
	_test_save_path_resolution()
	_test_two_participants_do_not_collide()
	_test_shared_slot_untouched_by_playtest()
	_test_switching_id_mid_session()
	_test_save_exists_no_crash()

	print("\n=== PLAYTEST ID ISOLATION TEST: %d passed, %d failed ===\n" % [_pass, _fail])
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


func _shared_dir() -> String:
	return OS.get_user_data_dir().path_join(SAVE_DIR)


func _expected_playtest_dir(id: String) -> String:
	return _shared_dir().path_join("playtests").path_join(id)


## Directory path with a trailing separator, for "is X inside dir Y" checks that
## must not be fooled by a raw string prefix ('.../P1' vs '.../P10/...').
func _dir_prefix(id: String) -> String:
	return _expected_playtest_dir(id) + "/"


func _expected_path(id: String, save_name: String) -> String:
	if id.is_empty():
		return _shared_dir().path_join(save_name + SAVE_EXTENSION)
	return _expected_playtest_dir(id).path_join(save_name + SAVE_EXTENSION)


## 64-char ID that satisfies the charset rule (the documented upper bound).
func _id_64() -> String:
	return "A".repeat(64)


# === Case: normalize ===

func _test_normalize() -> void:
	print("\n[normalize] strip_edges + to_upper (APFS case-insensitivity safety)")
	var sl: RefCounted = _new_save_load()

	_check(sl.call("normalize_playtest_id", "p01") == "P01", "lowercase 'p01' -> 'P01'")
	_check(sl.call("normalize_playtest_id", "  p01  ") == "P01", "surrounding spaces stripped -> 'P01'")
	_check(sl.call("normalize_playtest_id", "\tP01\n") == "P01", "tab/newline stripped -> 'P01'")
	_check(sl.call("normalize_playtest_id", "Pilot_1") == "PILOT_1", "mixed case normalized -> 'PILOT_1'")
	_check(sl.call("normalize_playtest_id", "") == "", "empty stays empty")
	_check(sl.call("normalize_playtest_id", "p01-test") == "P01-TEST", "hyphen preserved, uppercased")


# === Case: valid IDs ===

func _test_validate_valid_ids() -> void:
	print("\n[validate] accepted IDs")
	var sl: RefCounted = _new_save_load()

	_check(sl.call("validate_playtest_id", "P01") == "", "'P01' accepted")
	_check(sl.call("validate_playtest_id", "PILOT_1") == "", "'PILOT_1' accepted")
	_check(sl.call("validate_playtest_id", "A") == "", "single character accepted (lower bound)")
	_check(sl.call("validate_playtest_id", "player-07") == "", "mix of letters/digits/hyphen accepted")
	_check(sl.call("validate_playtest_id", "p01") == "", "lowercase accepted (normalized before validation)")
	_check(sl.call("validate_playtest_id", _id_64()) == "", "64-char ID accepted (upper bound)")
	_check(sl.call("validate_playtest_id", "---") == "", "hyphen-only ID accepted (charset-legal)")


# === Case: empty / whitespace ===

func _test_validate_empty_and_whitespace() -> void:
	print("\n[validate] empty and whitespace-only rejected")
	var sl: RefCounted = _new_save_load()

	_check(not String(sl.call("validate_playtest_id", "")).is_empty(), "empty ID rejected")
	_check(not String(sl.call("validate_playtest_id", "   ")).is_empty(), "spaces-only ID rejected")
	_check(not String(sl.call("validate_playtest_id", "\t")).is_empty(), "tab-only ID rejected")
	_check(not String(sl.call("validate_playtest_id", "\n")).is_empty(), "newline-only ID rejected")
	_check(String(sl.call("validate_playtest_id", "")).contains("empty"), "empty-ID error says 'empty'")


# === Case: path traversal (the security-critical rule) ===

func _test_validate_path_traversal() -> void:
	print("\n[validate] path traversal rejected")
	var sl: RefCounted = _new_save_load()

	var traversal: Array[String] = [
		"..", "P01..", "..P01", "P..01",
		"../P01", "P01/../P02", "P01/", "/P01", "/",
		"P01\\", "\\P01", "P01\\..\\P02",
		"P01:P02", "P01:", "C:P01",
	]
	for raw in traversal:
		var err := String(sl.call("validate_playtest_id", raw))
		_check(not err.is_empty(), "traversal token rejected: '%s'" % raw)

	# A single '.' is legal in no position — it is outside the charset.
	_check(not String(sl.call("validate_playtest_id", ".")).is_empty(), "'.' rejected (outside charset)")
	_check(not String(sl.call("validate_playtest_id", "P.01")).is_empty(), "'.' inside ID rejected")

	# The traversal checks must run BEFORE charset normalization can hide them.
	_check(not String(sl.call("validate_playtest_id", "..")).is_empty(), "'..' rejected even as the whole ID")


# === Case: length bounds ===

func _test_validate_length_bounds() -> void:
	print("\n[validate] length bounds 1..64")
	var sl: RefCounted = _new_save_load()

	_check(sl.call("validate_playtest_id", "A".repeat(63)) == "", "63 chars accepted")
	_check(sl.call("validate_playtest_id", _id_64()) == "", "64 chars accepted (boundary)")
	var err65 := String(sl.call("validate_playtest_id", "A".repeat(65)))
	_check(not err65.is_empty(), "65 chars rejected (boundary)")
	_check(err65.contains("64"), "over-length error names the 64 limit")
	_check(not String(sl.call("validate_playtest_id", "A".repeat(512))).is_empty(), "512 chars rejected")
	# Length is measured AFTER strip_edges, so padding must not smuggle past the limit.
	_check(not String(sl.call("validate_playtest_id", "  " + "A".repeat(65) + "  ")).is_empty(),
		"65 chars with surrounding padding still rejected (length checked after normalize)")


# === Case: charset ===

func _test_validate_charset() -> void:
	print("\n[validate] charset is strictly [A-Z0-9_-]")
	var sl: RefCounted = _new_save_load()

	# Internal space (survives strip_edges, must still be rejected).
	_check(not String(sl.call("validate_playtest_id", "P 01")).is_empty(), "internal space rejected")

	var illegal: Array[String] = [
		"P01!", "P01@", "P01#", "P01$", "P01%", "P01*", "P01?", "P01|",
		"P01;", "P01,", "P01(", "P01)", "P01+", "P01=", "P01'", "P01\"",
		"P01<", "P01>", "P01~", "P01[", "P01]", "P01{", "P01}",
	]
	for raw in illegal:
		_check(not String(sl.call("validate_playtest_id", raw)).is_empty(),
			"punctuation rejected: '%s'" % raw)

	# Non-ASCII must not slip through to_upper().
	_check(not String(sl.call("validate_playtest_id", "プレイヤー")).is_empty(), "non-ASCII (Japanese) rejected")
	_check(not String(sl.call("validate_playtest_id", "选手01")).is_empty(), "non-ASCII (Chinese) rejected")
	_check(not String(sl.call("validate_playtest_id", "P01é")).is_empty(), "accented Latin rejected")
	_check(not String(sl.call("validate_playtest_id", "P01🙂")).is_empty(), "emoji rejected")


# === Case: setter applies normalized value ===

func _test_set_playtest_id_applies_normalized() -> void:
	print("\n[set] valid ID applied, normalized")
	var sl: RefCounted = _new_save_load()

	_check(sl.call("get_playtest_id") == "", "fresh instance has no playtest ID")
	_check(sl.call("set_playtest_id", "p01") == "", "set('p01') returns no error")
	_check(sl.call("get_playtest_id") == "P01", "stored ID is normalized to 'P01'")

	_check(sl.call("set_playtest_id", "  pilot_2  ") == "", "set with padding returns no error")
	_check(sl.call("get_playtest_id") == "PILOT_2", "stored ID is 'PILOT_2'")


# === Case: setter rejects without corrupting state ===

func _test_set_playtest_id_rejects_and_keeps_prior() -> void:
	print("\n[set] invalid ID rejected AND prior ID preserved (no silent fallback to shared namespace)")
	var sl: RefCounted = _new_save_load()

	sl.call("set_playtest_id", "P01")
	var err := String(sl.call("set_playtest_id", "../P02"))

	_check(not err.is_empty(), "set('../P02') returns an error")
	_check(sl.call("get_playtest_id") == "P01", "prior ID 'P01' survived the rejected set (got '%s')" % sl.call("get_playtest_id"))
	_check(sl.call("get_save_dir") == _expected_playtest_dir("P01"),
		"save dir still resolves to P01's playtest dir after rejection")

	# An invalid ID must never be interpreted as "reset to shared".
	_check(sl.call("get_save_dir") != _shared_dir(),
		"rejected ID did NOT fall back to the shared saves dir")


# === Case: setter resets on empty ===

func _test_set_playtest_id_empty_resets() -> void:
	print("\n[set] empty ID resets to the shared namespace")
	var sl: RefCounted = _new_save_load()

	sl.call("set_playtest_id", "P01")
	_check(sl.call("get_save_dir") == _expected_playtest_dir("P01"), "playtest dir active")

	_check(sl.call("set_playtest_id", "") == "", "set('') returns no error")
	_check(sl.call("get_playtest_id") == "", "ID cleared")
	_check(sl.call("get_save_dir") == _shared_dir(), "save dir back to the shared saves dir")

	# Whitespace-only must be treated as a REJECTION, not as a reset.
	sl.call("set_playtest_id", "P01")
	var err := String(sl.call("set_playtest_id", "   "))
	_check(not err.is_empty(), "set('   ') is rejected, not treated as reset")
	_check(sl.call("get_playtest_id") == "P01", "prior ID survived the whitespace-only set")


# === Case: save directory resolution ===

func _test_save_dir_resolution() -> void:
	print("\n[resolve] save directory")
	var sl: RefCounted = _new_save_load()

	var shared := String(sl.call("get_save_dir"))
	_check(shared == _shared_dir(), "default save dir is user_data_dir/saves (got '%s')" % shared)
	_check(shared.ends_with(SAVE_DIR), "default save dir ends with 'saves'")

	sl.call("set_playtest_id", "P07")
	var pt := String(sl.call("get_save_dir"))
	_check(pt == _expected_playtest_dir("P07"), "playtest save dir is user_data_dir/saves/playtests/P07")
	_check(pt.begins_with(shared), "playtest dir is nested UNDER the shared saves dir")
	_check(pt.contains("playtests"), "playtest dir lives in a 'playtests' subdir")


# === Case: save path resolution ===

func _test_save_path_resolution() -> void:
	print("\n[resolve] save path carries the .sav.json extension and the namespace")
	var sl: RefCounted = _new_save_load()

	_check(sl.call("get_save_path", "manual") == _expected_path("", "manual"),
		"shared path resolves to user_data_dir/saves/manual.sav.json (got '%s')" % sl.call("get_save_path", "manual"))

	sl.call("set_playtest_id", "p07")
	_check(sl.call("get_save_path", "manual") == _expected_path("P07", "manual"),
		"playtest path resolves to user_data_dir/saves/playtests/P07/manual.sav.json")
	_check(String(sl.call("get_save_path", "manual")).ends_with("manual" + SAVE_EXTENSION),
		"playtest path keeps the .sav.json extension")

	# The public accessor must agree with the internal resolver.
	_check(String(sl.call("get_save_path", "manual")) == String(sl.call("_save_path", "manual")),
		"get_save_path() == _save_path() (accessor agrees with internal resolver)")


# === Case: the actual isolation guarantee ===

func _test_two_participants_do_not_collide() -> void:
	print("\n[isolation] two participants, same save name -> different files")
	var sl_a: RefCounted = _new_save_load()
	var sl_b: RefCounted = _new_save_load()

	sl_a.call("set_playtest_id", "P01")
	sl_b.call("set_playtest_id", "P02")

	var path_a := String(sl_a.call("get_save_path", "manual"))
	var path_b := String(sl_b.call("get_save_path", "manual"))

	_check(path_a != path_b, "P01 and P02 resolve 'manual' to different files")
	_check(path_a == _expected_path("P01", "manual"), "P01 path is under playtests/P01")
	_check(path_b == _expected_path("P02", "manual"), "P02 path is under playtests/P02")
	_check(not path_a.begins_with(_dir_prefix("P02")), "P01 path is not inside P02's dir")
	_check(not path_b.begins_with(_dir_prefix("P01")), "P02 path is not inside P01's dir")

	# A prefix relationship between two IDs must not create a parent/child overlap.
	# (Compared against the dir + separator — a raw string prefix would match
	# '.../playtests/P1' against '.../playtests/P10/...' and report a false nest.)
	sl_a.call("set_playtest_id", "P1")
	sl_b.call("set_playtest_id", "P10")
	var short_path := String(sl_a.call("get_save_path", "manual"))
	var long_path := String(sl_b.call("get_save_path", "manual"))
	_check(short_path != long_path, "prefix IDs 'P1' vs 'P10' resolve to different files")
	_check(not long_path.begins_with(_dir_prefix("P1")), "'P10' path is not nested inside 'P1' dir")
	_check(not short_path.begins_with(_dir_prefix("P10")), "'P1' path is not nested inside 'P10' dir")

	# Case-insensitive IDs must share one namespace (APFS), not split into two.
	sl_a.call("set_playtest_id", "p01")
	sl_b.call("set_playtest_id", "P01")
	_check(sl_a.call("get_save_path", "manual") == sl_b.call("get_save_path", "manual"),
		"'p01' and 'P01' resolve to the SAME file (case-insensitive filesystems)")


# === Case: shared slot cannot be reached from a playtest session ===

func _test_shared_slot_untouched_by_playtest() -> void:
	print("\n[isolation] a playtest session can never resolve to the shared slot")
	var sl: RefCounted = _new_save_load()
	# Capture BOTH shared paths while no playtest ID is active — the point is
	# that activating one changes nothing about the shared namespace.
	var shared_path := String(sl.call("get_save_path", "manual"))
	var shared_other := String(sl.call("get_save_path", "sl004_probe"))

	sl.call("set_playtest_id", "P01")
	var pt_path := String(sl.call("get_save_path", "manual"))
	var pt_other := String(sl.call("get_save_path", "sl004_probe"))

	_check(pt_path != shared_path, "playtest path differs from the shared path")
	_check(not shared_path.begins_with(_dir_prefix("P01")),
		"the shared slot is not inside any playtest directory")
	_check(shared_path == _shared_dir().path_join("manual" + SAVE_EXTENSION),
		"the shared slot path is unchanged by setting a playtest ID")

	# Same guarantee for a name other than the default slot.
	_check(shared_other == _shared_dir().path_join("sl004_probe" + SAVE_EXTENSION),
		"other shared slot names are also unaffected")
	_check(pt_other != shared_other, "the other slot name is namespaced too")


# === Case: switching IDs mid-session ===

func _test_switching_id_mid_session() -> void:
	print("\n[switch] changing the ID mid-session re-resolves immediately")
	var sl: RefCounted = _new_save_load()

	sl.call("set_playtest_id", "P01")
	var first := String(sl.call("get_save_path", "manual"))
	sl.call("set_playtest_id", "P02")
	var second := String(sl.call("get_save_path", "manual"))
	sl.call("set_playtest_id", "")
	var third := String(sl.call("get_save_path", "manual"))

	_check(first != second, "P01 -> P02 changed the resolved path")
	_check(second != third, "P02 -> shared changed the resolved path")
	_check(third == _expected_path("", "manual"), "clearing the ID restored the exact shared path")
	_check(first == _expected_path("P01", "manual"), "first path was P01's")


# === Case: save_exists is namespace-aware and never crashes ===

func _test_save_exists_no_crash() -> void:
	print("\n[exists] save_exists() answers per-namespace without crashing")
	var sl: RefCounted = _new_save_load()

	var shared_absent := bool(sl.call("save_exists", "zzz_playtest_isolation_probe_absent"))
	sl.call("set_playtest_id", "P01")
	var playtest_absent := bool(sl.call("save_exists", "zzz_playtest_isolation_probe_absent"))

	_check(shared_absent == false, "shared namespace reports an absent probe as false")
	_check(playtest_absent == false, "playtest namespace reports the same absent probe as false")
	_check(String(sl.call("get_save_path", "zzz_playtest_isolation_probe_absent")) != _shared_dir().path_join("zzz_playtest_isolation_probe_absent" + SAVE_EXTENSION),
		"the probe resolves to a different file once a playtest ID is active")
