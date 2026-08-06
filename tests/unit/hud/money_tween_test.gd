# tests/unit/hud/money_tween_test.gd
# Story HUD-002: Money Count Tween
# (production/epics/hud/story-002-money-count-tween.md)
#
# Covers the BLOCKING ACs / Edge Cases (TR-HUD-004):
#   - AC2   balance_changed -> the money number animates old->new over ~0.3s
#         (TRANS_QUAD EASE_OUT throughout — "Butter motion"), no red/error
#         flash on decrease. Headless cannot tick engine tweens (no frames
#         iterate under the runner), so the ANIMATION is verified two ways:
#         (a) tween-existence + target + from-state assertions (the tween is
#             in flight, label has NOT snapped), and (b) the deterministic
#             easing math via Tween.interpolate_value() with the exact
#             trans/ease/duration constants the HUD uses — monotonic, no
#             overshoot, reaches the target exactly at duration.
#   - Edge  rapid balance changes: re-target mid-tween — the OLD tween is
#         killed (is_valid() == false) and exactly ONE new tween runs toward
#         the LATEST value; no queue backlog (assert via captured tween refs).
#   - Edge  paused: a sell refund during pause still animates — the tween is
#         render-time (create_tween on the scene tree), created and running
#         while TimeSystem is paused, with zero tick advance.
#   - reduced-motion: snap to the final value immediately, no tween, no
#         desaturation acknowledgment.
#   - spend acknowledgment: on delta < 0 the Butter coin desaturates
#         (hue-preserving lerp toward gray — spend_ack_color(), NEVER red) and
#         a settle tween restores Butter; the NUMBER label color never changes.
#   - duration knob: default 0.3s, config override clamped to GDD 0.2-0.5s.
#
# Run standalone: godot --headless --script tests/unit/hud/money_tween_test.gd
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"

const TICKS_PER_DAY := 1800  # provisional default (HUD GDD OQ1)

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
	print("  UNIT TEST: Hud — Money Count Tween (Story HUD-002)")
	print("=".repeat(48))

	_test_ac2_tween_created_on_balance_changed()
	_test_ac2_easing_math_income()
	_test_ac2_easing_math_spend()
	_test_ac2_no_red_on_spend()
	_test_edge_rapid_retarget_no_backlog()
	_test_edge_paused_still_animates()
	_test_reduced_motion_snap()
	_test_reduced_motion_spend_no_ack()
	_test_duration_knob_default()
	_test_duration_knob_config_clamp()
	_test_refresh_all_snaps_and_kills_tween()
	_test_apply_money_display_rounds_and_formats()
	_test_spend_ack_color_pure()

	print("\n=== HUD MONEY TWEEN TEST: %d passed, %d failed ===\n" % [_pass, _fail])
	return {"pass": _pass, "fail": _fail}


func _check(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
		print("  PASS: " + msg)
	else:
		_fail += 1
		print("  FAIL: " + msg)


# === Helpers ===

func _HUD() -> Script:
	return load("res://src/ui/hud.gd") as Script


func _EC() -> Script:
	return load("res://src/systems/economy.gd") as Script


func _SAT() -> Script:
	return load("res://src/systems/satisfaction.gd") as Script


func _SRG() -> Script:
	return load("res://src/systems/seeded_rng.gd") as Script


## Creates an initialized SimulationOrchestrator in the scene tree (delivers
## _ready() synchronously — same pattern as the save-load integration tests).
func _make_orchestrator() -> Node:
	var orch: Node = load("res://src/systems/simulation_orchestrator.gd").new()
	root.add_child(orch)
	orch.call("_ready")
	return orch


## Builds the HUD test rig: real orchestrator + SeededRNG + real Economy +
## real Satisfaction + real TimeSystem (from the orchestrator) + a real Hud
## node wired via init(). Returns every handle so tests can drive state.
func _make_rig(seed: int = 0x0D1D0A7, config: Dictionary = {}) -> Dictionary:
	var srg: RefCounted = _SRG().new()
	srg.call("init", seed)
	var orch := _make_orchestrator()
	var econ: RefCounted = _EC().new()
	econ.call("init", orch, srg)
	orch.set("economy", econ)
	var sat: RefCounted = _SAT().new()
	sat.call("init", orch, srg)
	orch.set("satisfaction", sat)
	var ts: RefCounted = orch.get("time_system")
	var hud: Control = _HUD().new()
	root.add_child(hud)
	hud.call("init", econ, sat, ts, orch, config)
	return {"orch": orch, "srg": srg, "econ": econ, "sat": sat, "ts": ts, "hud": hud}


# === AC2: tween created on balance_changed ===

func _test_ac2_tween_created_on_balance_changed() -> void:
	print("\n[AC2] balance_changed starts a count tween old->new (does not snap)")
	var rig := _make_rig()
	var econ: RefCounted = rig["econ"]
	var hud: Control = rig["hud"]
	var money_label: Label = hud.call("get_money_label")
	_check(not bool(hud.call("is_money_tween_active")), "no tween before any change")
	_check(int(hud.call("get_displayed_balance")) == 500, "displayed balance == 500 at init")
	econ.call("credit", 100, "test:income")  # 500 -> 600, delta +100
	_check(bool(hud.call("is_money_tween_active")), "credit starts a count tween (in flight)")
	_check(int(hud.call("get_money_tween_target")) == 600, "tween target == 600 (got %d)" % int(hud.call("get_money_tween_target")))
	_check(int(hud.call("get_displayed_balance")) == 500, "displayed still 500 mid-tween — animating, NOT snapped (got %d)" % int(hud.call("get_displayed_balance")))
	_check(money_label.text == "$500", "label text still $500 until the tween ticks (got '%s')" % money_label.text)
	# A fresh in-tree tween must be running (not already finished/killed).
	_check(bool(hud.call("is_money_tween_active")), "fresh tween reports is_running() == true")


# === AC2: easing math (deterministic, headless) ===

func _test_ac2_easing_math_income() -> void:
	print("\n[AC2] easing: TRANS_QUAD EASE_OUT 500 -> 600 over 0.3s, monotonic, no overshoot")
	var hud_script: GDScript = _HUD()
	var trans: int = int(hud_script.get("MONEY_TWEEN_TRANS"))
	var ease: int = int(hud_script.get("MONEY_TWEEN_EASE"))
	var duration: float = float(hud_script.get("DEFAULT_MONEY_COUNT_DURATION"))
	_check(trans == Tween.TRANS_QUAD, "HUD uses TRANS_QUAD (got %d)" % trans)
	_check(ease == Tween.EASE_OUT, "HUD uses EASE_OUT (got %d)" % ease)
	_check(absf(duration - 0.3) < 1e-9, "default duration 0.3s (got %s)" % duration)
	var start: float = float(Tween.interpolate_value(500.0, 100.0, 0.0, duration, trans, ease))
	var end: float = float(Tween.interpolate_value(500.0, 100.0, duration, duration, trans, ease))
	_check(start == 500.0, "t=0 -> 500 (got %s)" % start)
	_check(end == 600.0, "t=duration -> exactly 600 (got %s)" % end)
	# Monotonic + no overshoot at 11 sample points.
	var prev := 500.0
	var monotonic := true
	var within_range := true
	for i in range(1, 11):
		var t: float = duration * float(i) / 10.0
		var v: float = float(Tween.interpolate_value(500.0, 100.0, t, duration, trans, ease))
		if v < prev:
			monotonic = false
		if v < 500.0 or v > 600.0:
			within_range = false
		prev = v
	_check(monotonic, "count is monotonic non-decreasing (never counts backwards)")
	_check(within_range, "count never overshoots past [500, 600]")


func _test_ac2_easing_math_spend() -> void:
	print("\n[AC2] easing: TRANS_QUAD EASE_OUT 600 -> 350 over 0.3s (spend direction)")
	var hud_script: GDScript = _HUD()
	var trans: int = int(hud_script.get("MONEY_TWEEN_TRANS"))
	var ease: int = int(hud_script.get("MONEY_TWEEN_EASE"))
	var duration: float = float(hud_script.get("DEFAULT_MONEY_COUNT_DURATION"))
	var start: float = float(Tween.interpolate_value(600.0, -250.0, 0.0, duration, trans, ease))
	var end: float = float(Tween.interpolate_value(600.0, -250.0, duration, duration, trans, ease))
	_check(start == 600.0, "spend: t=0 -> 600 (got %s)" % start)
	_check(end == 350.0, "spend: t=duration -> exactly 350 (got %s)" % end)
	var prev := 600.0
	var monotonic := true
	var within_range := true
	for i in range(1, 11):
		var t: float = duration * float(i) / 10.0
		var v: float = float(Tween.interpolate_value(600.0, -250.0, t, duration, trans, ease))
		if v > prev:
			monotonic = false
		if v < 350.0 or v > 600.0:
			within_range = false
		prev = v
	_check(monotonic, "spend count is monotonic non-increasing")
	_check(within_range, "spend count never undershoots past [350, 600]")


# === AC2: spend acknowledgment — NEVER red ===

func _test_ac2_no_red_on_spend() -> void:
	print("\n[AC2] spend: desaturation acknowledgment, number label NEVER red")
	var rig := _make_rig()
	var econ: RefCounted = rig["econ"]
	var hud: Control = rig["hud"]
	var money_label: Label = hud.call("get_money_label")
	var ack: Color = _HUD().call("spend_ack_color")
	# Hue-preserving desaturation: Butter hue (~0.128, yellow family), saturation drops.
	var butter: Color = _HUD().get("COLOR_BUTTER")
	_check(absf(ack.h - butter.h) < 1e-6, "ack hue preserved (yellow family, got h=%.4f)" % ack.h)
	_check(ack.s < butter.s, "ack saturation lower than Butter — desaturated (got s=%.4f)" % ack.s)
	_check(ack.r > ack.b, "ack is NOT red-dominant (r=%.3f > b=%.3f — yellow family)" % [ack.r, ack.b])
	econ.call("spend", 250)  # 500 -> 350, delta -250
	_check(bool(hud.call("is_ack_tween_active")), "spend starts the settle tween (desaturation half applied)")
	var coin_color: Color = hud.call("get_coin_icon_color")
	_check(coin_color == ack, "coin icon color == desaturated Butter right after spend (got %s)" % coin_color)
	var number_color: Color = money_label.get_theme_color("font_color")
	_check(number_color == _HUD().get("COLOR_CHARCOAL"), "NUMBER label color unchanged (charcoal — never red, got %s)" % number_color)


# === Edge: rapid changes re-target, no queue ===

func _test_edge_rapid_retarget_no_backlog() -> void:
	print("\n[Edge] rapid balance changes: re-target to latest, old tween killed, no queue")
	var rig := _make_rig()
	var econ: RefCounted = rig["econ"]
	var hud: Control = rig["hud"]
	econ.call("credit", 50, "test:1")   # 550
	var first_tween: Tween = hud.call("get_money_tween")
	_check(first_tween != null and bool(first_tween.is_valid()), "tween #1 exists and is valid")
	_check(int(hud.call("get_money_tween_target")) == 550, "target #1 == 550 (got %d)" % int(hud.call("get_money_tween_target")))
	econ.call("credit", 30, "test:2")   # 580
	_check(not bool(first_tween.is_valid()), "tween #1 KILLED on re-target (is_valid() == false — no queue backlog)")
	var second_tween: Tween = hud.call("get_money_tween")
	_check(second_tween != null and bool(second_tween.is_valid()), "tween #2 exists and is valid")
	_check(int(hud.call("get_money_tween_target")) == 580, "target #2 == 580 (got %d)" % int(hud.call("get_money_tween_target")))
	econ.call("credit", 80, "test:3")   # 660
	_check(not bool(second_tween.is_valid()), "tween #2 KILLED on re-target")
	var third_tween: Tween = hud.call("get_money_tween")
	_check(third_tween != null and bool(third_tween.is_valid()), "tween #3 exists and is valid")
	_check(int(hud.call("get_money_tween_target")) == 660, "target #3 == 660 (latest, got %d)" % int(hud.call("get_money_tween_target")))
	_check(int(hud.call("get_displayed_balance")) == 500, "displayed still 500 — count continues from where it was (got %d)" % int(hud.call("get_displayed_balance")))
	# Exactly one live tween at the end.
	var live_count := 0
	if bool(first_tween.is_valid()):
		live_count += 1
	if bool(second_tween.is_valid()):
		live_count += 1
	if bool(third_tween.is_valid()):
		live_count += 1
	_check(live_count == 1, "exactly ONE live tween after three rapid changes (got %d)" % live_count)


# === Edge: paused still animates (render-time) ===

func _test_edge_paused_still_animates() -> void:
	print("\n[Edge] money changes while paused: tween still animates (render-time)")
	var rig := _make_rig()
	var ts: RefCounted = rig["ts"]
	var econ: RefCounted = rig["econ"]
	var hud: Control = rig["hud"]
	ts.call("pause")
	_check(bool(ts.call("is_paused")), "TimeSystem paused for the test")
	var tick_before: int = int(rig["orch"].call("get_tick_count"))
	econ.call("credit", 100, "test:refund")  # sell refund during pause -> balance_changed
	_check(bool(hud.call("is_money_tween_active")), "count tween created and RUNNING while paused")
	_check(int(hud.call("get_money_tween_target")) == 600, "tween targets the refunded balance 600 (got %d)" % int(hud.call("get_money_tween_target")))
	var tick_after: int = int(rig["orch"].call("get_tick_count"))
	_check(tick_after == tick_before, "ZERO ticks advanced — the tween is render-time, not tick-gated (ticks %d -> %d)" % [tick_before, tick_after])


# === Reduced-motion: snap ===

func _test_reduced_motion_snap() -> void:
	print("\n[Reduced-motion] snap to final value, no tween")
	var rig := _make_rig(0, {"reduced_motion": true})
	var econ: RefCounted = rig["econ"]
	var hud: Control = rig["hud"]
	var money_label: Label = hud.call("get_money_label")
	_check(bool(hud.call("is_reduced_motion")), "reduced_motion flag read from config")
	econ.call("credit", 100, "test:income")
	_check(not bool(hud.call("is_money_tween_active")), "NO tween under reduced-motion")
	_check(int(hud.call("get_displayed_balance")) == 600, "displayed snapped to 600 (got %d)" % int(hud.call("get_displayed_balance")))
	_check(money_label.text == "$600", "label snapped to $600 (got '%s')" % money_label.text)


func _test_reduced_motion_spend_no_ack() -> void:
	print("\n[Reduced-motion] spend: snap only — no desaturation acknowledgment")
	var rig := _make_rig(0, {"reduced_motion": true})
	var econ: RefCounted = rig["econ"]
	var hud: Control = rig["hud"]
	econ.call("spend", 200)  # 500 -> 300, delta -200
	_check(not bool(hud.call("is_ack_tween_active")), "no settle tween under reduced-motion")
	var coin_color: Color = hud.call("get_coin_icon_color")
	_check(coin_color == _HUD().get("COLOR_BUTTER"), "coin stays full Butter under reduced-motion (got %s)" % coin_color)
	_check(int(hud.call("get_displayed_balance")) == 300, "displayed snapped to 300 (got %d)" % int(hud.call("get_displayed_balance")))


# === Duration knob ===

func _test_duration_knob_default() -> void:
	print("\n[Knob] money_count_duration default 0.3s")
	var rig := _make_rig()
	var hud: Control = rig["hud"]
	_check(absf(float(hud.call("get_money_count_duration")) - 0.3) < 1e-9, "default duration 0.3s (got %s)" % hud.call("get_money_count_duration"))


func _test_duration_knob_config_clamp() -> void:
	print("\n[Knob] money_count_duration config override clamped to GDD 0.2-0.5s")
	var rig_a := _make_rig(0, {"money_count_duration": 0.45})
	_check(absf(float(rig_a["hud"].call("get_money_count_duration")) - 0.45) < 1e-9, "0.45 config honored (got %s)" % rig_a["hud"].call("get_money_count_duration"))
	var rig_b := _make_rig(0, {"money_count_duration": 0.1})
	_check(absf(float(rig_b["hud"].call("get_money_count_duration")) - 0.2) < 1e-9, "0.1 clamped UP to 0.2 (got %s)" % rig_b["hud"].call("get_money_count_duration"))
	var rig_c := _make_rig(0, {"money_count_duration": 0.9})
	_check(absf(float(rig_c["hud"].call("get_money_count_duration")) - 0.5) < 1e-9, "0.9 clamped DOWN to 0.5 (got %s)" % rig_c["hud"].call("get_money_count_duration"))


# === refresh_all snaps (load path) ===

func _test_refresh_all_snaps_and_kills_tween() -> void:
	print("\n[Load] refresh_all() snaps money and kills any in-flight tween")
	var rig := _make_rig()
	var econ: RefCounted = rig["econ"]
	var hud: Control = rig["hud"]
	var money_label: Label = hud.call("get_money_label")
	econ.call("credit", 100, "test:income")  # tween in flight toward 600
	_check(bool(hud.call("is_money_tween_active")), "tween in flight before refresh")
	hud.call("refresh_all")  # load path: render loaded balance immediately
	_check(not bool(hud.call("is_money_tween_active")), "refresh_all kills the in-flight tween")
	_check(int(hud.call("get_displayed_balance")) == 600, "displayed snaps to current balance 600 (got %d)" % int(hud.call("get_displayed_balance")))
	_check(money_label.text == "$600", "label shows loaded balance $600 (got '%s')" % money_label.text)


# === Tween callback: rounding + formatting ===

func _test_apply_money_display_rounds_and_formats() -> void:
	print("\n[Callback] _apply_money_display rounds to int and formats with separators")
	var rig := _make_rig()
	var hud: Control = rig["hud"]
	var money_label: Label = hud.call("get_money_label")
	hud.call("_apply_money_display", 1234.7)
	_check(money_label.text == "$1,235", "1234.7 -> '$1,235' (got '%s')" % money_label.text)
	_check(int(hud.call("get_displayed_balance")) == 1235, "displayed_balance == 1235 (got %d)" % int(hud.call("get_displayed_balance")))
	hud.call("_apply_money_display", 999.4)
	_check(money_label.text == "$999", "999.4 -> '$999' (got '%s')" % money_label.text)
	hud.call("_apply_money_display", 600.0)
	_check(money_label.text == "$600", "600.0 -> '$600' (got '%s')" % money_label.text)


# === Pure function: spend_ack_color ===

func _test_spend_ack_color_pure() -> void:
	print("\n[Pure] spend_ack_color(): hue-preserving desaturation, deterministic")
	var hud_script: GDScript = _HUD()
	var ack: Color = hud_script.call("spend_ack_color")
	var butter: Color = hud_script.get("COLOR_BUTTER")
	var gray := Color(0.5, 0.5, 0.5)
	var amount: float = float(hud_script.get("SPEND_DESATURATE_AMOUNT"))
	var expected: Color = butter.lerp(gray, amount)
	_check(ack == expected, "ack == Butter.lerp(gray, SPEND_DESATURATE_AMOUNT) — deterministic")
	_check(absf(ack.h - butter.h) < 1e-6, "hue preserved (yellow family) — never red")
	_check(ack.s < butter.s, "saturation reduced")
