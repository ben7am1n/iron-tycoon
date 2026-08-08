# tests/unit/hud/hud_state_binding_test.gd
# Story HUD-001: Top-bar Layout & Read-only State Binding
# (production/epics/hud/story-001-top-bar-layout-state-binding.md)
#
# Covers the BLOCKING ACs / testable parts:
#   - GDD Formulas: day/time derivation from tick_count with the provisional
#     data-driven TICKS_PER_DAY (default 1800, HUD GDD OQ1) — derive_day,
#     derive_time_of_day, format_money, format_time_of_day (pure statics).
#   - AC8  load-state binding: a freshly-init'd HUD renders the paused state
#         and the LOADED money/satisfaction/day immediately — no stale
#         pre-load values (init() calls refresh_all()).
#   - S6   balance_changed(new, delta) subscription updates the money label
#         (typed connection, arity 2).
#   - S2   tick_completed refresh hook: satisfaction % + day/time re-read on
#         the 10 Hz cadence; day rolls over exactly at TICKS_PER_DAY.
#   - pause/speed state binding: PAUSED/RUNNING + speed multiplier labels.
#   - TR-HUD-006 read-only discipline: no popup/toast/badge nodes anywhere
#         in the HUD tree; HUD calls never mutate sim state (balance,
#         tick_count, paused unchanged by refresh/signal handling).
#   - Config: ticks_per_day + ui_scale data-driven overrides; double-init guard.
#
# Run standalone: godot --headless --script tests/unit/hud/hud_state_binding_test.gd
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
	print("  UNIT TEST: Hud — State Binding (Story HUD-001)")
	print("=".repeat(48))

	_test_derive_day_boundaries()
	_test_derive_time_of_day()
	_test_format_money()
	_test_format_time_of_day()
	_test_ac8_load_state_binding()
	_test_ac8_no_stale_values_after_refresh()
	_test_balance_changed_updates_money()
	_test_satisfaction_read_on_tick()
	_test_day_rollover_on_tick()
	_test_pause_speed_state_binding()
	_test_config_ticks_per_day_override()
	_test_config_ui_scale_override()
	_test_double_init_guard()
	_test_read_only_no_mutation()
	_test_no_popup_toast_badge_nodes()

	print("\n=== HUD STATE BINDING TEST: %d passed, %d failed ===\n" % [_pass, _fail])
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


# === Pure derivation functions (GDD Formulas) ===

func _test_derive_day_boundaries() -> void:
	print("\n[GDD Formulas] derive_day: 1 + floor(tick_count / TICKS_PER_DAY)")
	var hud_script: GDScript = _HUD()
	_check(int(hud_script.call("derive_day", 0, TICKS_PER_DAY)) == 1, "day(tick 0) == 1")
	_check(int(hud_script.call("derive_day", 1799, TICKS_PER_DAY)) == 1, "day(1799) == 1 (last tick of day 1)")
	_check(int(hud_script.call("derive_day", 1800, TICKS_PER_DAY)) == 2, "day(1800) == 2 (first tick of day 2)")
	_check(int(hud_script.call("derive_day", 3599, TICKS_PER_DAY)) == 2, "day(3599) == 2")
	_check(int(hud_script.call("derive_day", 3600, TICKS_PER_DAY)) == 3, "day(3600) == 3")
	_check(int(hud_script.call("derive_day", 0, 100)) == 1, "day(0) with config 100 == 1")
	_check(int(hud_script.call("derive_day", 100, 100)) == 2, "day(100) with config 100 == 2")
	_check(int(hud_script.call("derive_day", 5000, 0)) == 1, "defensive: ticks_per_day <= 0 -> day 1 (no div-by-zero)")


func _test_derive_time_of_day() -> void:
	print("\n[GDD Formulas] derive_time_of_day: (tick mod TICKS_PER_DAY) / TICKS_PER_DAY")
	var hud_script: GDScript = _HUD()
	var v: float = float(hud_script.call("derive_time_of_day", 0, TICKS_PER_DAY))
	_check(v == 0.0, "time_of_day(tick 0) == 0.0 (got %s)" % v)
	v = float(hud_script.call("derive_time_of_day", 900, TICKS_PER_DAY))
	_check(absf(v - 0.5) < 1e-9, "time_of_day(900) == 0.5 (got %s)" % v)
	v = float(hud_script.call("derive_time_of_day", 1799, TICKS_PER_DAY))
	_check(absf(v - (1799.0 / 1800.0)) < 1e-9, "time_of_day(1799) == 1799/1800 (got %s)" % v)
	v = float(hud_script.call("derive_time_of_day", 1800, TICKS_PER_DAY))
	_check(v == 0.0, "time_of_day(1800) wraps to 0.0 (got %s)" % v)
	v = float(hud_script.call("derive_time_of_day", 5000, 0))
	_check(v == 0.0, "defensive: ticks_per_day <= 0 -> 0.0 (got %s)" % v)


func _test_format_money() -> void:
	print("\n[Display] format_money with thousands separators")
	var hud_script: GDScript = _HUD()
	_check(str(hud_script.call("format_money", 0)) == "$0", "format_money(0) == $0 (got %s)" % str(hud_script.call("format_money", 0)))
	_check(str(hud_script.call("format_money", 500)) == "$500", "format_money(500) == $500")
	_check(str(hud_script.call("format_money", 1240)) == "$1,240", "format_money(1240) == $1,240")
	_check(str(hud_script.call("format_money", 1234567)) == "$1,234,567", "format_money(1234567) == $1,234,567")
	_check(str(hud_script.call("format_money", -500)) == "-$500", "format_money(-500) == -$500 (defensive)")


func _test_format_time_of_day() -> void:
	print("\n[Display] format_time_of_day: [0,1) fraction -> HH:MM")
	var hud_script: GDScript = _HUD()
	_check(str(hud_script.call("format_time_of_day", 0.0)) == "00:00", "0.0 -> 00:00")
	_check(str(hud_script.call("format_time_of_day", 0.25)) == "06:00", "0.25 -> 06:00")
	_check(str(hud_script.call("format_time_of_day", 0.5)) == "12:00", "0.5 -> 12:00")
	_check(str(hud_script.call("format_time_of_day", 0.75)) == "18:00", "0.75 -> 18:00")
	_check(str(hud_script.call("format_time_of_day", 1.0)) == "23:59", "1.0 clamps -> 23:59")


# === AC8: load-state binding ===

func _test_ac8_load_state_binding() -> void:
	print("\n[AC8] Load-state binding: paused state + loaded values immediately (no stale)")
	var rig := _make_rig()
	var orch: Node = rig["orch"]
	var econ: RefCounted = rig["econ"]
	var sat: RefCounted = rig["sat"]
	var hud: Control = rig["hud"]
	# Loaded game state: balance $1,240; satisfaction 77%; tick_count 3600 -> Day 3
	econ.call("credit", 740, "test:load")  # 500 + 740 = 1240
	sat.set("global_satisfaction", 0.77)
	orch.call("_restore_tick_count", 3600)  # Story-004 write path (orchestrator-owned counter)
	hud.call("refresh_all")  # init() already did this; re-drive for the assertion
	var money_label: Label = hud.call("get_money_label")
	var sat_label: Label = hud.call("get_satisfaction_label")
	var day_label: Label = hud.call("get_day_label")
	_check(money_label.text == "$1,240", "money label shows loaded $1,240 (got '%s')" % money_label.text)
	_check(sat_label.text == "77%", "satisfaction label shows loaded 77%% (got '%s')" % sat_label.text)
	_check(day_label.text == "Day 3", "day label shows loaded Day 3 (got '%s')" % day_label.text)
	_check(bool(hud.call("is_pause_active")), "pause button active on load (TimeSystem loads paused — AC1/AC8)")
	_check(int(hud.call("get_active_speed")) == 0, "no speed button active on load (got %d)" % int(hud.call("get_active_speed")))


func _test_ac8_no_stale_values_after_refresh() -> void:
	print("\n[AC8] refresh_all() re-reads live state — no stale label caches")
	var rig := _make_rig()
	var econ: RefCounted = rig["econ"]
	var sat: RefCounted = rig["sat"]
	var orch: Node = rig["orch"]
	var hud: Control = rig["hud"]
	# Defaults at init: $500 / 50% / Day 1. Now change the world and refresh.
	econ.call("credit", 1000, "test")  # 1500
	sat.set("global_satisfaction", 0.9)
	orch.call("_restore_tick_count", 3600)
	hud.call("refresh_all")
	var money_label: Label = hud.call("get_money_label")
	var sat_label: Label = hud.call("get_satisfaction_label")
	var day_label: Label = hud.call("get_day_label")
	_check(money_label.text == "$1,500", "money refreshed to $1,500 (got '%s')" % money_label.text)
	_check(sat_label.text == "90%", "satisfaction refreshed to 90%% (got '%s')" % sat_label.text)
	_check(day_label.text == "Day 3", "day refreshed to Day 3 (got '%s')" % day_label.text)


# === S6 balance_changed subscription ===

## Story 002 contract: balance_changed no longer snaps the label — it starts a
## count tween toward the new value. The label text only changes when the
## tween ticks (frames), so mid-tween it still shows the OLD value and the
## tween target holds the NEW one. Arity-2 subscription + rejected-spend
## no-signal behavior are still the assertions here (the tween itself gets
## dedicated coverage in money_tween_test.gd).
func _test_balance_changed_updates_money() -> void:
	print("\n[S6] balance_changed(new, delta) drives the money count tween")
	var rig := _make_rig()
	var econ: RefCounted = rig["econ"]
	var hud: Control = rig["hud"]
	var money_label: Label = hud.call("get_money_label")
	_check(money_label.text == "$500", "init balance $500 (got '%s')" % money_label.text)
	_check(not bool(hud.call("is_money_tween_active")), "no money tween before any balance change")
	econ.call("credit", 100, "test:income")
	_check(bool(hud.call("is_money_tween_active")), "credit(100) starts a money count tween (S6 arity 2)")
	_check(int(hud.call("get_money_tween_target")) == 600, "tween targets 600 (got %d)" % int(hud.call("get_money_tween_target")))
	_check(int(hud.call("get_displayed_balance")) == 500, "displayed stays 500 mid-tween — animates, does not snap (got %d)" % int(hud.call("get_displayed_balance")))
	_check(money_label.text == "$500", "label still $500 until the tween ticks (got '%s')" % money_label.text)
	econ.call("spend", 250)
	_check(int(hud.call("get_money_tween_target")) == 350, "spend re-targets tween to 350 (got %d)" % int(hud.call("get_money_tween_target")))
	_check(bool(hud.call("is_ack_tween_active")), "spend triggers the desaturation acknowledgment (never red)")
	econ.call("spend", 99999)  # rejected: no signal, no mutation
	_check(int(hud.call("get_money_tween_target")) == 350, "rejected overspend leaves tween target unchanged (got %d)" % int(hud.call("get_money_tween_target")))
	_check(money_label.text == "$500", "rejected overspend leaves label unchanged (got '%s')" % money_label.text)


# === S2 tick_completed refresh ===

func _test_satisfaction_read_on_tick() -> void:
	print("\n[S2] satisfaction target re-read on tick_completed (10 Hz cadence; Story 003 animates)")
	var rig := _make_rig()
	var sat: RefCounted = rig["sat"]
	var orch: Node = rig["orch"]
	var hud: Control = rig["hud"]
	var sat_label: Label = hud.call("get_satisfaction_label")
	var meter: ProgressBar = hud.call("get_meter")
	# Init snapped to S_BASE 0.5 (load path).
	_check(sat_label.text == "50%", "init label 50%% (S_BASE) (got '%s')" % sat_label.text)
	sat.set("global_satisfaction", 0.66)
	orch.call("_advance_tick")  # fires tick_completed -> _refresh_satisfaction (animated)
	# Story 003 contract: the tick registers the NEW target and starts an ease;
	# the displayed value catches up over ~1 s. Headless has no frames, so the
	# label/meter still show the pre-change value while the tween is mid-flight.
	_check(bool(hud.call("is_meter_animating")), "meter is animating after tick (Story 003 ease)")
	_check(absf(float(hud.call("get_meter_tween_target")) - 66.0) < 1e-6,
		"tween target == 66.0 (got %s)" % hud.call("get_meter_tween_target"))
	# Drive the tween's display callback to the target — same path the tween
	# takes each frame — and verify the AC3 lockstep result.
	hud.call("apply_satisfaction_display", 0.66)
	_check(sat_label.text == "66%", "satisfaction label updated to 66%% after display(0.66) (got '%s')" % sat_label.text)
	_check(absf(float(meter.value) - 66.0) < 1e-6, "meter value == 66.0 after display(0.66) (got %s)" % meter.value)


func _test_day_rollover_on_tick() -> void:
	print("\n[S2] day rolls over exactly at TICKS_PER_DAY on tick_completed")
	var rig := _make_rig()
	var orch: Node = rig["orch"]
	var hud: Control = rig["hud"]
	var day_label: Label = hud.call("get_day_label")
	orch.call("_restore_tick_count", 1799)
	hud.call("refresh_all")
	_check(day_label.text == "Day 1", "tick 1799 -> Day 1 (got '%s')" % day_label.text)
	orch.call("_advance_tick")  # -> 1800
	_check(day_label.text == "Day 2", "tick 1800 -> Day 2 after rollover (got '%s')" % day_label.text)
	orch.call("_advance_tick")  # -> 1801
	_check(day_label.text == "Day 2", "tick 1801 still Day 2 (got '%s')" % day_label.text)


# === pause/speed state binding ===

func _test_pause_speed_state_binding() -> void:
	print("\n[Transport] pause/speed state read-only binding (Story-001 scope)")
	var rig := _make_rig()
	var ts: RefCounted = rig["ts"]
	var orch: Node = rig["orch"]
	var hud: Control = rig["hud"]
	var pause_button: Button = hud.call("get_pause_button")
	var speed1: Button = hud.call("get_speed_button", 1)
	var speed3: Button = hud.call("get_speed_button", 3)
	_check(bool(hud.call("is_pause_active")), "fresh TimeSystem is paused -> pause button active (got %s)" % bool(hud.call("is_pause_active")))
	_check(int(hud.call("get_active_speed")) == 0, "fresh paused -> no speed active (got %d)" % int(hud.call("get_active_speed")))
	ts.call("resume")
	orch.call("_advance_tick")  # refresh cadence
	_check(not bool(hud.call("is_pause_active")), "after resume -> pause button inactive")
	_check(int(hud.call("get_active_speed")) == 1, "resume defaults to 1× (got %d)" % int(hud.call("get_active_speed")))
	ts.call("set_speed", 3)
	orch.call("_advance_tick")
	_check(int(hud.call("get_active_speed")) == 3, "after set_speed(3) -> 3× (got %d)" % int(hud.call("get_active_speed")))
	ts.call("pause")
	orch.call("_advance_tick")  # tick_completed still fires while paused (external drive in test)
	_check(bool(hud.call("is_pause_active")), "after pause -> pause button active")
	_check(int(hud.call("get_active_speed")) == 0, "paused -> no speed active (got %d)" % int(hud.call("get_active_speed")))
	# Buttons are the Story-004 surface; Story-001 only binds state via the getters.
	_check(pause_button is Button, "transport cluster exposes a pause Button")
	_check(speed1 is Button and speed3 is Button, "transport cluster exposes speed Buttons")


# === config ===

func _test_config_ticks_per_day_override() -> void:
	print("\n[Config] ticks_per_day data-driven override")
	var rig := _make_rig(0, {"ticks_per_day": 100})
	var hud: Control = rig["hud"]
	_check(int(hud.call("get_ticks_per_day")) == 100, "get_ticks_per_day() == 100")
	var hud_script: GDScript = _HUD()
	_check(int(hud_script.call("derive_day", 100, 100)) == 2, "day(100) with 100-tick day == 2")
	_check(int(hud_script.call("derive_day", 199, 100)) == 2, "day(199) with 100-tick day == 2")
	_check(int(hud_script.call("derive_day", 200, 100)) == 3, "day(200) with 100-tick day == 3")


func _test_config_ui_scale_override() -> void:
	print("\n[Config] ui_scale data-driven override")
	var rig := _make_rig(0, {"ui_scale": 1.5})
	var hud: Control = rig["hud"]
	_check(absf(float(hud.call("get_ui_scale")) - 1.5) < 1e-9, "get_ui_scale() == 1.5")
	var top_bar: Control = hud.call("get_top_bar")
	# 16 * 1.5 = 24 safe margin; TOP_BAR_HEIGHT_PX * 1.5 = top bar height
	# （V3 §15 UI 降级：顶栏 48→44px，测试从常量派生期望值，不硬编码 72）
	var expected_bar: int = int(round(44.0 * 1.5))
	_check(int(top_bar.offset_left) == 24, "safe margin scales: offset_left == 24 (got %d)" % int(top_bar.offset_left))
	_check(int(top_bar.offset_right) == -24, "safe margin scales: offset_right == -24 (got %d)" % int(top_bar.offset_right))
	_check(int(top_bar.offset_bottom) == expected_bar, "top bar height scales: offset_bottom == %d (got %d)" % [expected_bar, int(top_bar.offset_bottom)])
	var money_label: Label = hud.call("get_money_label")
	_check(int(money_label.get_theme_font_size("font_size")) == 30, "font size scales: 20 * 1.5 == 30 (title level, got %d)" % int(money_label.get_theme_font_size("font_size")))


func _test_double_init_guard() -> void:
	print("\n[Guard] init() twice -> push_error + ignored")
	var rig := _make_rig()
	var hud: Control = rig["hud"]
	var econ: RefCounted = rig["econ"]
	var sat: RefCounted = rig["sat"]
	var ts: RefCounted = rig["ts"]
	var orch: Node = rig["orch"]
	hud.call("init", econ, sat, ts, orch, {})  # second call must be a no-op
	var money_label: Label = hud.call("get_money_label")
	_check(money_label.text == "$500", "double init leaves state untouched (label $500, got '%s')" % money_label.text)


# === TR-HUD-006 read-only discipline ===

func _test_read_only_no_mutation() -> void:
	print("\n[TR-HUD-006] HUD operations never mutate sim state (except the transport forward)")
	var rig := _make_rig()
	var orch: Node = rig["orch"]
	var econ: RefCounted = rig["econ"]
	var sat: RefCounted = rig["sat"]
	var ts: RefCounted = rig["ts"]
	var hud: Control = rig["hud"]
	var balance_before: int = int(econ.get("balance"))
	var tick_before: int = int(orch.call("get_tick_count"))
	var sat_before: float = float(sat.get("global_satisfaction"))
	# Drive every HUD refresh path + a balance_changed handler run.
	hud.call("refresh_all")
	orch.call("_advance_tick")
	hud.call("refresh_all")
	_check(int(econ.get("balance")) == balance_before, "balance unchanged by HUD operations")
	_check(int(orch.call("get_tick_count")) == tick_before + 1, "tick_count advanced ONLY by the explicit _advance_tick (not by HUD)")
	_check(absf(float(sat.get("global_satisfaction")) - sat_before) < 1e-9, "global_satisfaction unchanged by HUD")
	# Story 004: the transport forward exists and is the ONLY sim mutation the
	# HUD makes — pause/speed change TimeSystem state, everything else stays put.
	var paused_before: bool = bool(ts.call("is_paused"))
	hud.call("set_paused", not paused_before)
	_check(bool(ts.call("is_paused")) != paused_before, "set_paused() forwards to TimeSystem (the ONE allowed mutation)")
	_check(int(econ.get("balance")) == balance_before, "balance unchanged after transport forward")
	_check(int(orch.call("get_tick_count")) == tick_before + 1, "tick_count unchanged after transport forward")
	_check(absf(float(sat.get("global_satisfaction")) - sat_before) < 1e-9, "global_satisfaction unchanged after transport forward")
	_check(hud.has_method("set_paused"), "HUD exposes set_paused() (Story 004 transport surface)")
	_check(hud.has_method("set_speed"), "HUD exposes set_speed() (Story 004 transport surface)")
	# No OTHER sim-mutating entry points: the HUD must not expose economy/grid/sat
	# mutation methods beyond the transport pair.
	_check(not hud.has_method("credit") and not hud.has_method("spend"), "no economy mutation methods on HUD")
	_check(not hud.has_method("commit") and not hud.has_method("clear"), "no grid mutation methods on HUD")


func _test_no_popup_toast_badge_nodes() -> void:
	print("\n[TR-HUD-006] no popups / toasts / badges anywhere in the HUD tree")
	var rig := _make_rig()
	var hud: Control = rig["hud"]
	var banned: Array[String] = ["popup", "toast", "badge", "dialog", "acceptdialog"]
	var offenders: Array = []
	_scan_banned(hud, banned, offenders)
	_check(offenders.is_empty(), "no popup/toast/badge/dialog nodes found (found: %s)" % str(offenders))
	# Structural: exactly one child (the top bar) — no bottom bar, no side panels.
	_check(hud.get_child_count() == 1, "HUD root has exactly one child (the top bar) — got %d" % hud.get_child_count())
	_check(hud.get_child(0).name == "TopBar", "the single child is TopBar")


func _scan_banned(node: Node, banned: Array[String], offenders: Array) -> void:
	var lower_name: String = node.name.to_lower()
	for word in banned:
		if lower_name.contains(word):
			offenders.append("%s (%s)" % [node.name, node.get_class()])
			break
	if node is Popup or node is Window or node is AcceptDialog or node is ConfirmationDialog:
		offenders.append("node class %s" % node.get_class())
	for child in node.get_children():
		_scan_banned(child, banned, offenders)
