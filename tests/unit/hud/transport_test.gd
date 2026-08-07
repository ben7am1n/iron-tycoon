# tests/unit/hud/transport_test.gd
# Story HUD-004: Pause/Speed Transport + Day/Time Display
# (production/epics/hud/story-004-pause-speed-transport-day-time.md)
#
# Covers the BLOCKING ACs / testable parts:
#   - AC1  fresh boot: Pause button shows the active cue, no speed button is
#         highlighted (TimeSystem starts paused).
#   - AC4  paused + Space -> resumes at the LAST-USED speed; that speed
#         button shows the active cue (exactly one speed active).
#   - AC5  1/2/3 -> speed changes immediately, implicitly unpausing (one
#         action); exactly one speed button active (or none when paused).
#   - Core Rule 4  pressing the already-active speed is a no-op (stays at
#         that speed, unpaused — no state change, no cue flicker).
#   - TR-HUD-005  hotkeys via _unhandled_key_input: Space/1/2/3 forwarded to
#         TimeSystem (pause()/resume()/set_speed()); echo repeats and key
#         releases ignored; other keys ignored.
#   - dual-focus (4.6+): transport buttons are FOCUS_NONE so a focused Button
#         can never swallow Space/1/2/3 (hotkeys focus-independent).
#   - Button clicks (mouse path) forward the same as hotkeys.
#   - Day/time display: time_of_day_icon() derivation (12-hour clock face,
#         icon/shape — never color alone); DayLabel + TimeOfDayLabel update
#         on tick_completed (S2).
#   - TR-HUD-006  transport is the ONLY simulation mutation the HUD makes.
#
# Run standalone: godot --headless --script tests/unit/hud/transport_test.gd
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"

const TICKS_PER_DAY := 1800  # provisional default (HUD GDD OQ1)
const ACTIVE_DOT := "• "

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
	print("  UNIT TEST: Hud — Transport + Day/Time (Story HUD-004)")
	print("=".repeat(48))

	_test_ac1_fresh_boot_paused_no_speed()
	_test_ac4_space_resumes_at_last_speed()
	_test_ac5_digit_hotkeys_immediate_speed()
	_test_ac5_digit_hotkey_unpauses_from_paused()
	_test_core_rule_4_same_speed_noop()
	_test_button_clicks_forward()
	_test_hotkey_echo_and_release_ignored()
	_test_other_keys_ignored()
	_test_focus_none_buttons()
	_test_exactly_one_speed_active_invariant()
	_test_active_cue_visual()
	_test_time_of_day_icon_pure()
	_test_day_time_label_updates_on_tick()
	_test_day_rollover_boundary()
	_test_transport_only_mutation()

	print("\n=== HUD TRANSPORT TEST: %d passed, %d failed ===\n" % [_pass, _fail])
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
	var srg: RefCounted = load("res://src/systems/seeded_rng.gd").new()
	srg.call("init", seed)
	var orch := _make_orchestrator()
	var econ: RefCounted = load("res://src/systems/economy.gd").new()
	econ.call("init", orch, srg)
	orch.set("economy", econ)
	var sat: RefCounted = load("res://src/systems/satisfaction.gd").new()
	sat.call("init", orch, srg)
	orch.set("satisfaction", sat)
	var ts: RefCounted = orch.get("time_system")
	var hud: Control = _HUD().new()
	root.add_child(hud)
	hud.call("init", econ, sat, ts, orch, config)
	return {"orch": orch, "srg": srg, "econ": econ, "sat": sat, "ts": ts, "hud": hud}


func _key(keycode: Key, pressed: bool = true, echo: bool = false) -> InputEventKey:
	var ev := InputEventKey.new()
	ev.keycode = keycode
	ev.pressed = pressed
	ev.echo = echo
	return ev


## Counts speed buttons currently showing the active cue (filled-dot prefix).
func _active_speed_count(hud: Control) -> int:
	var count := 0
	for i in range(1, 4):
		var btn: Button = hud.call("get_speed_button", i)
		if btn.text.begins_with(ACTIVE_DOT):
			count += 1
	return count


# === AC1: fresh boot shows paused, no speed highlighted ===

func _test_ac1_fresh_boot_paused_no_speed() -> void:
	print("\n[AC1] fresh boot: Pause active, no speed button highlighted")
	var rig := _make_rig()
	var hud: Control = rig["hud"]
	var ts: RefCounted = rig["ts"]
	var pause_btn: Button = hud.call("get_pause_button")
	_check(bool(ts.call("is_paused")), "TimeSystem starts paused (got %s)" % bool(ts.call("is_paused")))
	_check(bool(hud.call("is_pause_active")), "pause button shows the active cue (is_pause_active)")
	_check(pause_btn.text.begins_with(ACTIVE_DOT), "pause button text carries the filled-dot prefix (got '%s')" % pause_btn.text)
	_check(pause_btn.has_theme_stylebox_override("normal"), "pause button has the outline stylebox override (active cue)")
	_check(int(hud.call("get_active_speed")) == 0, "no speed active on boot (get_active_speed == 0, got %d)" % int(hud.call("get_active_speed")))
	_check(_active_speed_count(hud) == 0, "no speed button highlighted on boot (got %d)" % _active_speed_count(hud))


# === AC4: paused + Space resumes at last-used speed ===

func _test_ac4_space_resumes_at_last_speed() -> void:
	print("\n[AC4] paused + Space -> resumes at the last-used speed; that button highlights")
	var rig := _make_rig()
	var hud: Control = rig["hud"]
	var ts: RefCounted = rig["ts"]
	# Fresh TimeSystem's _last_speed defaults to 1×; verify resume at 1× first.
	hud.call("_unhandled_key_input", _key(KEY_SPACE))
	_check(not bool(ts.call("is_paused")), "Space while paused unpauses (got is_paused=%s)" % bool(ts.call("is_paused")))
	_check(int(ts.call("get_speed_multiplier")) == 1, "resumes at last-used speed 1× (got %d)" % int(ts.call("get_speed_multiplier")))
	_check(int(hud.call("get_active_speed")) == 1, "speed button 1× shows active (got %d)" % int(hud.call("get_active_speed")))
	_check(_active_speed_count(hud) == 1, "exactly one speed button active (got %d)" % _active_speed_count(hud))
	# Now: pause, select 3× while paused (records last speed), then Space -> 3×.
	hud.call("_unhandled_key_input", _key(KEY_SPACE))  # pause
	_check(bool(ts.call("is_paused")), "Space while running pauses")
	_check(_active_speed_count(hud) == 0, "paused -> no speed button active (got %d)" % _active_speed_count(hud))
	hud.call("_unhandled_key_input", _key(KEY_3))  # set speed while paused: AC5 one-action unpause
	_check(not bool(ts.call("is_paused")), "pressing 3 while paused implicitly unpauses (one action)")
	_check(int(ts.call("get_speed_multiplier")) == 3, "3× selected (got %d)" % int(ts.call("get_speed_multiplier")))
	hud.call("_unhandled_key_input", _key(KEY_SPACE))  # pause again
	hud.call("_unhandled_key_input", _key(KEY_SPACE))  # Space -> resume at last-used 3×
	_check(not bool(ts.call("is_paused")), "Space resumes from pause")
	_check(int(ts.call("get_speed_multiplier")) == 3, "resumed at the LAST-USED speed 3×, not 1× (got %d)" % int(ts.call("get_speed_multiplier")))
	var speed3: Button = hud.call("get_speed_button", 3)
	_check(speed3.text.begins_with(ACTIVE_DOT), "speed button 3× shows the active cue (got '%s')" % speed3.text)
	_check(_active_speed_count(hud) == 1, "exactly one speed button active after resume (got %d)" % _active_speed_count(hud))


# === AC5: 1/2/3 set speed immediately ===

func _test_ac5_digit_hotkeys_immediate_speed() -> void:
	print("\n[AC5] 1/2/3 hotkeys change speed immediately; exactly one button active")
	var rig := _make_rig()
	var hud: Control = rig["hud"]
	var ts: RefCounted = rig["ts"]
	hud.call("_unhandled_key_input", _key(KEY_2))
	_check(int(ts.call("get_speed_multiplier")) == 2, "key 2 -> 2× immediately (got %d)" % int(ts.call("get_speed_multiplier")))
	_check(int(hud.call("get_active_speed")) == 2, "active speed reflects 2× (got %d)" % int(hud.call("get_active_speed")))
	hud.call("_unhandled_key_input", _key(KEY_1))
	_check(int(ts.call("get_speed_multiplier")) == 1, "key 1 -> 1× immediately (got %d)" % int(ts.call("get_speed_multiplier")))
	hud.call("_unhandled_key_input", _key(KEY_3))
	_check(int(ts.call("get_speed_multiplier")) == 3, "key 3 -> 3× immediately (got %d)" % int(ts.call("get_speed_multiplier")))
	_check(_active_speed_count(hud) == 1, "exactly one speed button active after hotkey chain (got %d)" % _active_speed_count(hud))
	_check(int(hud.call("get_active_speed")) == 3, "active speed is the last one pressed (got %d)" % int(hud.call("get_active_speed")))


func _test_ac5_digit_hotkey_unpauses_from_paused() -> void:
	print("\n[AC5] digit hotkey while paused -> immediate speed + implicit unpause (one action)")
	var rig := _make_rig()
	var hud: Control = rig["hud"]
	var ts: RefCounted = rig["ts"]
	_check(bool(ts.call("is_paused")), "rig starts paused")
	hud.call("_unhandled_key_input", _key(KEY_2))
	_check(not bool(ts.call("is_paused")), "pressing 2 while paused unpaused in the SAME action (got is_paused=%s)" % bool(ts.call("is_paused")))
	_check(int(ts.call("get_speed_multiplier")) == 2, "pressing 2 while paused landed at 2× (got %d)" % int(ts.call("get_speed_multiplier")))
	_check(_active_speed_count(hud) == 1, "exactly one speed button active (got %d)" % _active_speed_count(hud))
	_check(int(hud.call("get_active_speed")) == 2, "active speed is 2× (got %d)" % int(hud.call("get_active_speed")))


# === Core Rule 4: same speed again = no-op ===

func _test_core_rule_4_same_speed_noop() -> void:
	print("\n[Core Rule 4] pressing the already-active speed is a no-op (stays, unpaused)")
	var rig := _make_rig()
	var hud: Control = rig["hud"]
	var ts: RefCounted = rig["ts"]
	var orch: Node = rig["orch"]
	hud.call("_unhandled_key_input", _key(KEY_2))  # run at 2×
	_check(int(ts.call("get_speed_multiplier")) == 2, "setup: running at 2×")
	var tick_before: int = int(orch.call("get_tick_count"))
	var pause_before: bool = bool(ts.call("is_paused"))
	var speed2: Button = hud.call("get_speed_button", 2)
	var text_before: String = speed2.text
	hud.call("_unhandled_key_input", _key(KEY_2))  # same speed again
	_check(int(ts.call("get_speed_multiplier")) == 2, "still 2× after re-press")
	_check(bool(ts.call("is_paused")) == pause_before, "still unpaused after re-press")
	_check(int(orch.call("get_tick_count")) == tick_before, "no tick fired by the no-op (tick_count %d -> %d)" % [tick_before, int(orch.call("get_tick_count"))])
	_check(speed2.text == text_before, "no cue flicker: button text unchanged (got '%s')" % speed2.text)
	_check(_active_speed_count(hud) == 1, "exactly one speed button active after no-op (got %d)" % _active_speed_count(hud))


# === Mouse path: button clicks forward ===

func _test_button_clicks_forward() -> void:
	print("\n[Mouse] transport button clicks forward pause/speed (same as hotkeys)")
	var rig := _make_rig()
	var hud: Control = rig["hud"]
	var ts: RefCounted = rig["ts"]
	var pause_btn: Button = hud.call("get_pause_button")
	var speed2: Button = hud.call("get_speed_button", 2)
	_check(bool(ts.call("is_paused")), "setup: paused")
	pause_btn.pressed.emit()  # click pause while paused -> resume
	_check(not bool(ts.call("is_paused")), "pause button click while paused resumes")
	speed2.pressed.emit()  # click 2× -> 2×
	_check(int(ts.call("get_speed_multiplier")) == 2, "2× button click -> 2× (got %d)" % int(ts.call("get_speed_multiplier")))
	pause_btn.pressed.emit()  # click pause while running -> pause
	_check(bool(ts.call("is_paused")), "pause button click while running pauses")
	_check(_active_speed_count(hud) == 0, "paused -> no speed button active (got %d)" % _active_speed_count(hud))
	pause_btn.pressed.emit()  # click pause again -> resume at last speed (2×)
	_check(not bool(ts.call("is_paused")), "pause button click resumes")
	_check(int(ts.call("get_speed_multiplier")) == 2, "resumed at last-used speed 2× (got %d)" % int(ts.call("get_speed_multiplier")))


# === Hotkey hygiene: echo / release / other keys ===

func _test_hotkey_echo_and_release_ignored() -> void:
	print("\n[Hotkeys] echo repeats and key releases are ignored")
	var rig := _make_rig()
	var hud: Control = rig["hud"]
	var ts: RefCounted = rig["ts"]
	_check(bool(ts.call("is_paused")), "setup: paused")
	# NOTE: fresh TimeSystem is paused with speed_multiplier field at its 1
	# default (pause() zeroes it only when called) — compare against snapshots
	# rather than asserting an absolute multiplier.
	var speed_before: int = int(ts.call("get_speed_multiplier"))
	hud.call("_unhandled_key_input", _key(KEY_SPACE, true, true))  # echo repeat
	_check(bool(ts.call("is_paused")), "echo Space does NOT toggle pause")
	hud.call("_unhandled_key_input", _key(KEY_SPACE, false))  # key release
	_check(bool(ts.call("is_paused")), "Space release does NOT toggle pause")
	hud.call("_unhandled_key_input", _key(KEY_2, true, true))  # echo digit
	_check(bool(ts.call("is_paused")), "echo 2 does NOT set speed / unpause")
	hud.call("_unhandled_key_input", _key(KEY_2, false))  # digit release
	_check(bool(ts.call("is_paused")), "2 release does NOT set speed / unpause")
	_check(int(ts.call("get_speed_multiplier")) == speed_before, "speed multiplier untouched by echo/release (got %d, before %d)" % [int(ts.call("get_speed_multiplier")), speed_before])


func _test_other_keys_ignored() -> void:
	print("\n[Hotkeys] non-transport keys are ignored")
	var rig := _make_rig()
	var hud: Control = rig["hud"]
	var ts: RefCounted = rig["ts"]
	var speed_before: int = int(ts.call("get_speed_multiplier"))
	var keys: Array[Key] = [KEY_A, KEY_ENTER, KEY_ESCAPE, KEY_TAB, KEY_0, KEY_4, KEY_9]
	for k in keys:
		hud.call("_unhandled_key_input", _key(k))
	_check(bool(ts.call("is_paused")), "paused state unchanged by non-transport keys (got %s)" % bool(ts.call("is_paused")))
	_check(int(ts.call("get_speed_multiplier")) == speed_before, "speed unchanged by non-transport keys (got %d, before %d)" % [int(ts.call("get_speed_multiplier")), speed_before])


# === dual-focus: buttons can never swallow the hotkeys ===

func _test_focus_none_buttons() -> void:
	print("\n[dual-focus] transport buttons are FOCUS_NONE — hotkeys stay focus-independent")
	var rig := _make_rig()
	var hud: Control = rig["hud"]
	var pause_btn: Button = hud.call("get_pause_button")
	_check(pause_btn.focus_mode == Control.FOCUS_NONE, "PauseButton focus_mode == FOCUS_NONE (got %d)" % pause_btn.focus_mode)
	for i in range(1, 4):
		var btn: Button = hud.call("get_speed_button", i)
		_check(btn.focus_mode == Control.FOCUS_NONE, "SpeedButton%d focus_mode == FOCUS_NONE (got %d)" % [i, btn.focus_mode])


# === Invariant: exactly one speed active (or none when paused) ===

func _test_exactly_one_speed_active_invariant() -> void:
	print("\n[Invariant] across a full pause/resume/speed chain: 0 or 1 speed button active")
	var rig := _make_rig()
	var hud: Control = rig["hud"]
	var ts: RefCounted = rig["ts"]
	var states: Array = []
	for action in ["space", "2", "3", "1", "space", "space", "2", "space", "3", "3"]:
		match action:
			"space":
				hud.call("_unhandled_key_input", _key(KEY_SPACE))
			"1":
				hud.call("_unhandled_key_input", _key(KEY_1))
			"2":
				hud.call("_unhandled_key_input", _key(KEY_2))
			"3":
				hud.call("_unhandled_key_input", _key(KEY_3))
		var active: int = _active_speed_count(hud)
		var pause_active: bool = bool(hud.call("is_pause_active"))
		if bool(ts.call("is_paused")):
			states.append("paused:active=%d" % active)
			_check(active == 0, "paused -> 0 speed buttons active (got %d)" % active)
			_check(pause_active, "paused -> pause button active")
		else:
			states.append("running:active=%d" % active)
			_check(active == 1, "running -> exactly 1 speed button active (got %d)" % active)
			_check(not pause_active, "running -> pause button NOT active")
	_check(true, "invariant held across chain: %s" % str(states))


# === Active cue visual (outline + filled dot, never color alone) ===

func _test_active_cue_visual() -> void:
	print("\n[Visual] active cue = outline stylebox + filled-dot prefix (icon/shape, not color)")
	var rig := _make_rig()
	var hud: Control = rig["hud"]
	var ts: RefCounted = rig["ts"]
	var pause_btn: Button = hud.call("get_pause_button")
	var speed1: Button = hud.call("get_speed_button", 1)
	# Fresh: paused -> pause active, speed 1 inactive.
	_check(pause_btn.text.begins_with(ACTIVE_DOT) and pause_btn.has_theme_stylebox_override("normal"),
		"paused: pause button has dot + outline")
	_check(not speed1.text.begins_with(ACTIVE_DOT) and not speed1.has_theme_stylebox_override("normal"),
		"paused: speed 1 button has NO cue")
	# Resume -> speed 1 active, pause inactive.
	ts.call("resume")
	hud.call("refresh_all")
	_check(not pause_btn.text.begins_with(ACTIVE_DOT) and not pause_btn.has_theme_stylebox_override("normal"),
		"running: pause button loses the cue")
	_check(speed1.text.begins_with(ACTIVE_DOT) and speed1.has_theme_stylebox_override("normal"),
		"running: speed 1 button gains dot + outline")
	# The cue is NOT color-only: the active cue is a shape (dot) + outline;
	# assert both parts are present and the inactive button has neither.
	var sb: StyleBoxFlat = speed1.get_theme_stylebox("normal")
	_check(sb is StyleBoxFlat and int(sb.border_width_left) > 0, "active cue stylebox has a visible border (outline)")


# === Day/time: icon derivation + label updates ===

func _test_time_of_day_icon_pure() -> void:
	print("\n[Day/Time] time_of_day_icon: 12-hour clock face from the [0,1) fraction")
	var hud_script: GDScript = _HUD()
	_check(str(hud_script.call("time_of_day_icon", 0.0)) == "🕛", "fraction 0.0 (midnight) -> 🕛 (got %s)" % str(hud_script.call("time_of_day_icon", 0.0)))
	_check(str(hud_script.call("time_of_day_icon", 0.25)) == "🕕", "fraction 0.25 (06:00) -> 🕕 (got %s)" % str(hud_script.call("time_of_day_icon", 0.25)))
	_check(str(hud_script.call("time_of_day_icon", 0.5)) == "🕛", "fraction 0.5 (noon) -> 🕛 (got %s)" % str(hud_script.call("time_of_day_icon", 0.5)))
	_check(str(hud_script.call("time_of_day_icon", 0.75)) == "🕕", "fraction 0.75 (18:00) -> 🕕 (got %s)" % str(hud_script.call("time_of_day_icon", 0.75)))
	_check(str(hud_script.call("time_of_day_icon", 0.999)) == "🕚", "fraction ~23:58 -> 🕚 (got %s)" % str(hud_script.call("time_of_day_icon", 0.999)))
	# Icon carries state by SHAPE, never color alone — the mapping must be
	# injective across day quarters (0, 0.25, 0.5, 0.75 produce distinct faces).
	_check(str(hud_script.call("time_of_day_icon", 0.0)) != str(hud_script.call("time_of_day_icon", 0.25)),
		"midnight icon differs from 06:00 icon (shape-based state)")
	# Defensive clamps.
	_check(str(hud_script.call("time_of_day_icon", -0.5)) == "🕛", "negative fraction clamps to 0.0")
	_check(str(hud_script.call("time_of_day_icon", 1.0)) == "🕚", "fraction 1.0 clamps to last hour (got %s)" % str(hud_script.call("time_of_day_icon", 1.0)))


func _test_day_time_label_updates_on_tick() -> void:
	print("\n[S2] DayLabel + TimeOfDayLabel update on tick_completed")
	var rig := _make_rig()
	var orch: Node = rig["orch"]
	var hud: Control = rig["hud"]
	var day_label: Label = hud.call("get_day_label")
	var tod_label: Label = hud.call("get_time_of_day_label")
	_check(day_label.text == "Day 1", "boot: Day 1 (got '%s')" % day_label.text)
	_check(tod_label.text == str(_HUD().call("time_of_day_icon", 0.0)), "boot: midnight icon (got '%s')" % tod_label.text)
	orch.call("_restore_tick_count", 900)  # half a day: time_of_day == 0.5
	hud.call("refresh_all")
	_check(day_label.text == "Day 1", "tick 900 still Day 1 (got '%s')" % day_label.text)
	_check(tod_label.text == "🕛", "tick 900 -> noon icon 🕛 (got '%s')" % tod_label.text)
	orch.call("_restore_tick_count", 450)  # quarter day: 06:00
	hud.call("refresh_all")
	_check(tod_label.text == "🕕", "tick 450 -> 06:00 icon 🕕 (got '%s')" % tod_label.text)


func _test_day_rollover_boundary() -> void:
	print("\n[S2] day rolls over exactly at TICKS_PER_DAY (icon wraps with it)")
	var rig := _make_rig()
	var orch: Node = rig["orch"]
	var hud: Control = rig["hud"]
	var day_label: Label = hud.call("get_day_label")
	var tod_label: Label = hud.call("get_time_of_day_label")
	orch.call("_restore_tick_count", TICKS_PER_DAY - 1)
	hud.call("refresh_all")
	_check(day_label.text == "Day 1", "tick 1799 -> Day 1 (got '%s')" % day_label.text)
	orch.call("_advance_tick")  # -> 1800
	_check(day_label.text == "Day 2", "tick 1800 -> Day 2 (got '%s')" % day_label.text)
	_check(tod_label.text == str(_HUD().call("time_of_day_icon", 0.0)), "new day starts at midnight icon (got '%s')" % tod_label.text)


# === TR-HUD-006: transport is the ONLY sim mutation ===

func _test_transport_only_mutation() -> void:
	print("\n[TR-HUD-006] transport forwards touch ONLY TimeSystem pause/speed")
	var rig := _make_rig()
	var hud: Control = rig["hud"]
	var ts: RefCounted = rig["ts"]
	var econ: RefCounted = rig["econ"]
	var orch: Node = rig["orch"]
	var sat: RefCounted = rig["sat"]
	var balance_before: int = int(econ.get("balance"))
	var tick_before: int = int(orch.call("get_tick_count"))
	var sat_before: float = float(sat.get("global_satisfaction"))
	hud.call("_unhandled_key_input", _key(KEY_2))  # unpause at 2×
	hud.call("_unhandled_key_input", _key(KEY_SPACE))  # pause
	_check(int(econ.get("balance")) == balance_before, "balance untouched by transport (got %d)" % int(econ.get("balance")))
	_check(int(orch.call("get_tick_count")) == tick_before, "tick_count untouched by transport (got %d)" % int(orch.call("get_tick_count")))
	_check(absf(float(sat.get("global_satisfaction")) - sat_before) < 1e-9, "global_satisfaction untouched by transport")
	_check(bool(ts.call("is_paused")), "TimeSystem pause state DID change (the one allowed mutation)")
