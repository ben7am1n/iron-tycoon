## Runs real scene lifecycle and fail-fast startup in isolated Godot processes.
extends SceneTree
const RUNNER_META := "gym_manager_test_runner_active"
var _pass := 0
var _fail := 0

func _init() -> void:
	if Engine.has_meta(RUNNER_META):
		return
	var result := run_all()
	quit(1 if result.fail else 0)

## Process probes need their own SceneTree to exercise _ready and GUI signals.
func run_all() -> Dictionary:
	var output: Array = []
	var path := ProjectSettings.globalize_path("res://")
	var status := OS.execute(OS.get_executable_path(), ["--headless", "--path", path, "--script", "res://tests/integration/save_load/main_save_entry_probe.gd"], output, true)
	var pattern := RegEx.create_from_string("GA-002 MAIN ENTRY: ([0-9]+) checks, 0 failures")
	var summary := pattern.search(str(output))
	_check(status == 0 and str(output).contains("15 checks, 0 failures") and not str(output).contains("SCRIPT ERROR"), "real main save entry")
	output.clear()
	status = OS.execute(OS.get_executable_path(), ["--headless", "--path", path, "--", "--smoke", "--preflight-root=res://tests/nonexistent-ga002-data"], output, true)
	_check(status == 1 and str(output).contains("FAIL (resource preflight)") and not str(output).contains("RESULT: PASS"), "missing resources fail startup with nonzero exit")
	# Preflight fixture files live under an OS temp dir, not the user data dir,
	# so this assertion needs no write access outside the sandbox.
	var fixture_dir := OS.get_temp_dir().path_join("gym_manager_ga002_preflight_fixture")
	DirAccess.make_dir_recursive_absolute(fixture_dir)
	var files: Array = load("res://src/bootstrap/resource_preflight.gd").REQUIRED_FILES
	for filename: String in files:
		var source := FileAccess.get_file_as_string("res://data/" + filename)
		var file := FileAccess.open(fixture_dir.path_join(filename), FileAccess.WRITE)
		file.store_string("{invalid json" if filename == "equipment_upgrades.json" else source)
		file.close()
	output.clear()
	status = OS.execute(OS.get_executable_path(), ["--headless", "--path", path, "--", "--smoke", "--preflight-root=" + fixture_dir], output, true)
	_check(status == 1 and str(output).contains("FAIL (resource preflight)") and not str(output).contains("RESULT: PASS"), "malformed JSON fails startup before assembly")
	for filename: String in files:
		DirAccess.remove_absolute(fixture_dir.path_join(filename))
	DirAccess.remove_absolute(fixture_dir)
	return {"pass": _pass, "fail": _fail}

func _check(ok: bool, label: String) -> void:
	if ok:
		_pass += 1
	else:
		_fail += 1
		print("FAIL: " + label)
