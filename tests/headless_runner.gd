# Godot 4.7.1 Headless Test Runner
# 不依赖 GdUnit4 插件 — 纯 SceneTree + 自定义 assert 辅助函数
# Usage: godot --headless --script tests/headless_runner.gd
extends SceneTree

# === 测试文件注册表 ===
# 添加新测试文件时在此数组中追加即可

const TEST_FILES := [
	"tests/smoke/core_smoke_test.gd",
	"tests/integration/core_loop/core_loop_test.gd",
	"tests/unit/grid_system/grid_core_cell_data_test.gd",
]

# === 测试结果 ===
var _total_pass := 0
var _total_fail := 0
var _file_results: Array[Dictionary] = []


func _init() -> void:
	print("=".repeat(64))
	print("  Godot %s — Headless Test Suite" % Engine.get_version_info().string)
	print("  %d test file(s) registered" % TEST_FILES.size())
	print("=".repeat(64))

	for path in TEST_FILES:
		_run_file(path)

	_print_summary()
	quit(_total_fail > 0)


func _run_file(path: String) -> void:
	print("\n── %s ──" % path)
	var script = load("res://%s" % path)
	if script == null:
		printerr("  ERROR: failed to load %s" % path)
		_total_fail += 1
		_file_results.append({"path": path, "pass": 0, "fail": 1, "error": "load failed"})
		return

	var instance = script.new()
	if not instance.has_method("run_all"):
		printerr("  ERROR: %s missing run_all() entry point" % path)
		_total_fail += 1
		_file_results.append({"path": path, "pass": 0, "fail": 1, "error": "no run_all"})
		return

	# 调用测试文件的 run_all() — 每个文件自行管理 pass/fail 计数
	var ok: bool = instance.run_all()
	# stdout 中 grep 解析 PASS/FAIL 统计行
	# 格式: === SMOKE TEST: N passed, M failed === 或 === INTEGRATION TEST: N passed, M failed ===


func _print_summary() -> void:
	print("\n" + "=".repeat(64))
	print("  SUITE COMPLETE")
	print("=".repeat(64))
