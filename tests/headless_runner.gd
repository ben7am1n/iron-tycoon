# Godot 4.7.1 Headless Test Runner
# 不依赖 GdUnit4 插件 — 纯 SceneTree + 自定义 assert 辅助函数
# Usage: godot --headless --script tests/headless_runner.gd
#
# 测试文件契约：
#   1. 必须实现 `run_all() -> Dictionary`，返回 {"pass": int, "fail": int}
#   2. `_init()` 中若检测到 RUNNER_META 必须立即 return —— 由 runner 调用 run_all()，
#      否则测试会跑两遍（`script.new()` 已触发过 `_init()`）
#   3. 被 runner 驱动时不得调用 `quit()` —— 进程退出码由 runner 统一决定
extends SceneTree

## runner 在加载任何测试脚本前设置此 Engine meta 标记，测试文件据此判断自己是否被托管运行
const RUNNER_META := "gym_manager_test_runner_active"

# === 启用的测试文件 ===
# 添加新测试文件时在此数组中追加即可

const TEST_FILES := [
	"tests/unit/grid_system/grid_core_cell_data_test.gd",
	"tests/unit/grid_system/grid_solidity_coords_test.gd",
	"tests/unit/grid_system/grid_rotation_test.gd",
	"tests/unit/grid_system/grid_can_place_test.gd",
	"tests/unit/grid_system/grid_commit_clear_test.gd",
	"tests/unit/grid_system/grid_state_reader_snapshot_test.gd",
	"tests/unit/grid_system/grid_system_signals_test.gd",
	"tests/unit/grid_system/grid_system_guardrail_test.gd",
	"tests/unit/time_system/orchestrator_tick_dispatch_test.gd",
	"tests/unit/time_system/tick_accumulator_test.gd",
	"tests/unit/time_system/lsr_helper_test.gd",
	"tests/unit/time_system/seeded_rng_substream_test.gd",
	"tests/unit/time_system/time_serialization_test.gd",
	"tests/unit/equipment_catalog/equipment_def_catalog_test.gd",
	"tests/unit/equipment_catalog/catalog_json_loading_test.gd",
	"tests/unit/equipment_catalog/catalog_footprint_access_validation_test.gd",
	"tests/unit/equipment_catalog/catalog_pipeline_strict_mode_test.gd",
	"tests/unit/equipment_catalog/catalog_use_duration_validation_test.gd",
	"tests/unit/equipment_catalog/catalog_cost_formula_test.gd",
	"tests/integration/equipment_catalog/catalog_edge_cases_test.gd",
	"tests/integration/grid_system/grid_serialization_test.gd",
	"tests/integration/grid_system/grid_navigation_solidity_test.gd",
	"tests/integration/grid_system/grid_perf_drag_smoke_test.gd",
	"tests/integration/save_load/saveblob_composition_test.gd",
	"tests/integration/save_load/load_orchestration_test.gd",
	"tests/integration/save_load/roundtrip_determinism_test.gd",
	"tests/integration/save_load/file_io_version_test.gd",
]

# === 隔离的测试文件 ===
# 不运行，但每轮都显式打印为 SKIPPED —— 隔离的测试绝不允许冒充通过。
# 修复其 reason 后把 path 移入 TEST_FILES 即可重新启用。

const PENDING_FILES := [
	{
		"path": "tests/smoke/core_smoke_test.gd",
		"reason": "从 prototypes/ preload 实现代码，违反 .claude/rules/prototype-code.md；且测的是原型 API，与 src/ 不一致",
		"unblocked_by": "grid-system story-002(is_solid)/004(can_place)/005(commit·clear)/006(snapshot) + time-system story-003(SeededRNG)",
	},
	{
		"path": "tests/integration/core_loop/core_loop_test.gd",
		"reason": "preload 路径 res://../../prototypes/... 无法解析，脚本从未加载成功；且测的是原型实现",
		"unblocked_by": "core 层 epic —— PlacementSystem + Navigation + MemberSim + Congestion 的 src/ 实现",
	},
]

# === 测试结果 ===
var _total_pass := 0
var _total_fail := 0
var _file_results: Array[Dictionary] = []


func _init() -> void:
	# 必须在 load() 之前设置 —— 测试脚本的 _init() 在 script.new() 时立即读取此标记
	Engine.set_meta(RUNNER_META, true)

	print("=".repeat(64))
	print("  Godot %s — Headless Test Suite" % Engine.get_version_info().string)
	print("  %d enabled, %d pending" % [TEST_FILES.size(), PENDING_FILES.size()])
	print("=".repeat(64))

	for path in TEST_FILES:
		_run_file(path)

	_check_registry_coverage()
	_report_pending()
	_print_summary()
	quit(1 if _total_fail > 0 else 0)


func _run_file(path: String) -> void:
	print("\n── %s ──" % path)

	if not FileAccess.file_exists("res://%s" % path):
		_record_error(path, "注册的路径在磁盘上不存在")
		return

	var script := load("res://%s" % path) as Script
	if script == null:
		_record_error(path, "load 失败 —— 路径无法解析为 Script")
		return

	# 解析失败的脚本 load() 仍返回非 null 的 GDScript 对象，但 new() 会以运行时
	# 脚本错误中止本函数 —— 那样文件会从报告里彻底消失。必须先挡住。
	if not script.can_instantiate():
		_record_error(path, "脚本存在解析错误，无法实例化 —— 见上方 Parse Error")
		return

	var instance: Object = script.new()
	if instance == null:
		_record_error(path, "script.new() 返回 null")
		return

	if not instance.has_method("run_all"):
		_record_error(path, "缺少 run_all() 入口")
		_release(instance)
		return

	var result: Variant = instance.run_all()
	_release(instance)

	if typeof(result) != TYPE_DICTIONARY or not (result.has("pass") and result.has("fail")):
		_record_error(path, "run_all() 必须返回 {\"pass\": int, \"fail\": int}，实际返回 %s" % type_string(typeof(result)))
		return

	var passed := int(result["pass"])
	var failed := int(result["fail"])

	# 零断言视为失败 —— 否则一个静默跳过所有用例的测试文件会被当成通过
	if passed + failed == 0:
		_record_error(path, "run_all() 报告 0 个断言 —— 空测试不算通过")
		return

	_total_pass += passed
	_total_fail += failed
	_file_results.append({"path": path, "pass": passed, "fail": failed, "error": ""})


## 磁盘上存在但两个注册表都没收录的测试文件 —— 未注册就等于从未运行，必须记为失败，
## 否则"写完测试忘了注册"会以一片绿色的 CI 结束
func _check_registry_coverage() -> void:
	var registered: Dictionary = {}
	for path in TEST_FILES:
		registered[path] = true
	for entry in PENDING_FILES:
		registered[entry["path"]] = true

	for path in _scan_test_files("tests"):
		if not registered.has(path):
			_record_error(path, "测试文件存在于磁盘但未在 TEST_FILES / PENDING_FILES 注册 —— 未注册即从未运行")


## 递归收集 `tests/` 下所有 `*_test.gd`，返回项目相对路径
func _scan_test_files(dir_path: String) -> Array[String]:
	var found: Array[String] = []
	var dir := DirAccess.open("res://%s" % dir_path)
	if dir == null:
		return found

	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		var child := "%s/%s" % [dir_path, entry]
		if dir.current_is_dir():
			found.append_array(_scan_test_files(child))
		elif entry.ends_with("_test.gd"):
			found.append(child)
		entry = dir.get_next()
	dir.list_dir_end()

	return found


## 测试脚本多数 extends SceneTree/Node（非 RefCounted），不手动释放会残留在 ObjectDB
func _release(instance: Object) -> void:
	if instance is RefCounted:
		return
	if instance is Node:
		(instance as Node).queue_free()
	else:
		instance.free()


func _record_error(path: String, message: String) -> void:
	printerr("  ERROR: %s — %s" % [path, message])
	_total_fail += 1
	_file_results.append({"path": path, "pass": 0, "fail": 1, "error": message})


func _report_pending() -> void:
	if PENDING_FILES.is_empty():
		return

	print("\n" + "-".repeat(64))
	print("  SKIPPED — %d 个隔离测试（不计入 pass/fail）" % PENDING_FILES.size())
	print("-".repeat(64))
	for entry in PENDING_FILES:
		print("  SKIPPED: %s" % entry["path"])
		print("      原因: %s" % entry["reason"])
		print("      解锁条件: %s" % entry["unblocked_by"])


func _print_summary() -> void:
	print("\n" + "=".repeat(64))
	print("  SUITE SUMMARY")
	print("=".repeat(64))

	for r in _file_results:
		var failed_file: bool = r["fail"] > 0 or r["error"] != ""
		var status := "FAIL" if failed_file else "ok  "
		if r["error"] != "":
			print("  [%s] %s — %s" % [status, r["path"], r["error"]])
		else:
			print("  [%s] %s — %d passed, %d failed" % [status, r["path"], r["pass"], r["fail"]])

	print("-".repeat(64))
	print("  TOTAL: %d passed, %d failed" % [_total_pass, _total_fail])
	print("  RESULT: %s" % ("FAILED" if _total_fail > 0 else "PASSED"))
	print("=".repeat(64))
