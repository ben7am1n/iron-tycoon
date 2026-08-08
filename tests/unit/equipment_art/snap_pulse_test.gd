# tests/unit/equipment_art/snap_pulse_test.gd
# Phase B v2 — 吸附「咔哒」视觉反馈状态机单元测试
#
# 验证 SnapPulse（src/presentation/snap_pulse.gd）：
#   - 触发前 is_pulsing() == false
#   - pulse_at() 激活脉冲，progress() 从 0 开始
#   - _advance() 推进时间，progress 单调增长
#   - 超过 DURATION 后自动结束（is_pulsing() == false，幂等）
#   - 重复触发重置计时（最后一次为准）
#
# 不做像素断言（与 SelectionCue 同一约定：测试断言状态，不测像素）。
#
# Run standalone: godot --headless --script tests/unit/equipment_art/snap_pulse_test.gd
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"

const SnapPulseScript := preload("res://src/presentation/snap_pulse.gd")

var _pass := 0
var _fail := 0


func _init() -> void:
	if Engine.has_meta(RUNNER_META):
		return
	var result := run_all()
	quit(1 if int(result["fail"]) > 0 else 0)


func run_all() -> Dictionary:
	print("=".repeat(48))
	print("  UNIT TEST: SnapPulse visual click feedback (Phase B v2)")
	print("=".repeat(48))

	_test_idle_state()
	_test_trigger_activates()
	_test_advance_progresses()
	_test_auto_expire()
	_test_retrigger_resets()
	_test_advance_idle_noop()

	print("\n=== SNAP PULSE TEST: %d passed, %d failed ===\n" % [_pass, _fail])
	return {"pass": _pass, "fail": _fail}


func _check(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
		print("  PASS: " + msg)
	else:
		_fail += 1
		print("  FAIL: " + msg)


func _test_idle_state() -> void:
	var pulse = SnapPulseScript.new()
	_check(not pulse.is_pulsing(), "fresh node is not pulsing")
	_check(pulse.progress() == 0.0, "fresh node progress == 0")
	pulse.free()


func _test_trigger_activates() -> void:
	var pulse = SnapPulseScript.new()
	pulse.pulse_at(Vector2(100, 100))
	_check(pulse.is_pulsing(), "pulse_at() activates pulse")
	_check(pulse.progress() == 0.0, "progress starts at 0")
	_check(is_equal_approx(pulse.position.x, 0.0), "node position untouched (world pos is arg)")
	pulse.free()


func _test_advance_progresses() -> void:
	var pulse = SnapPulseScript.new()
	pulse.pulse_at(Vector2.ZERO)
	pulse._advance(SnapPulseScript.DURATION * 0.5)
	var p: float = pulse.progress()
	_check(is_equal_approx(p, 0.5), "half duration → progress 0.5 (got %s)" % p)
	_check(pulse.is_pulsing(), "still pulsing at half")
	pulse.free()


func _test_auto_expire() -> void:
	var pulse = SnapPulseScript.new()
	pulse.pulse_at(Vector2.ZERO)
	var still := pulse._advance(SnapPulseScript.DURATION + 0.01)
	_check(not still, "_advance past DURATION returns false")
	_check(not pulse.is_pulsing(), "auto-expires after DURATION")
	_check(pulse.progress() >= 1.0, "progress clamps to 1.0")
	# 幂等：已结束再 advance 无副作用
	var again := pulse._advance(0.5)
	_check(not again, "advance after expiry is no-op")
	pulse.free()


func _test_retrigger_resets() -> void:
	var pulse = SnapPulseScript.new()
	pulse.pulse_at(Vector2.ZERO)
	pulse._advance(SnapPulseScript.DURATION * 0.8)
	pulse.pulse_at(Vector2(50, 50))  # retrigger mid-pulse
	_check(pulse.is_pulsing(), "retrigger keeps pulsing")
	_check(is_equal_approx(pulse.progress(), 0.0), "retrigger resets progress to 0")
	pulse.free()


func _test_advance_idle_noop() -> void:
	var pulse = SnapPulseScript.new()
	var still := pulse._advance(0.5)
	_check(not still, "advance on idle node returns false (no phantom pulse)")
	pulse.free()
