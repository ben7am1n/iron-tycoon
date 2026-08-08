# tests/unit/hud/satisfaction_meter_test.gd
# Story HUD-003: Satisfaction Meter (calm, never an alarm)
# (production/epics/hud/story-003-satisfaction-meter.md)
#
# Covers the BLOCKING ACs / testable parts:
#   - TR-HUD-002 fill RAMP: Sage (high) -> warm neutral (mid) -> soft muted
#     Dusty Rose ONLY at the very low end; NEVER saturated red, NEVER pulse.
#     Pure static function `satisfaction_fill_color(sat)` — every color in the
#     ramp has saturation < 0.4 and never reads as red/alarm.
#   - TR-HUD-003 colorblind-safe pairing: % label + shape-changing face icon
#     (filled vs outline) carry the state, never color alone. Pure static
#     `satisfaction_icon(sat)` (":)"/":|"/":(" — monochrome ASCII, PHASED-F:
#     macOS 彩色 emoji 忽略 font_color) + `satisfaction_icon_shape(sat)`
#     ("filled"/"outline").
#   - AC3: global_satisfaction change -> meter eases to new fill over ~1 s;
#     % + icon update WITH the fill (lockstep via _apply_satisfaction_display);
#     no color ever reads as red/alarm. Headless note: scene-tree-bound tweens
#     do NOT advance without frames, so tests verify the tween's target via
#     getters + drive the display callback directly (test seam
#     apply_satisfaction_display) to prove the lockstep contract.
#   - Core Rule 2 (rock bottom): meter shows a low muted warm tone (Dusty Rose
#     at sat=0), never red, never flashing, still paired with % + icon.
#   - Reduced-motion: static fill (no ease); config `reduced_motion` +
#     live setter.
#   - Config: satisfaction_ease_duration knob (0.5-1.5 s safe range).
#
# Run standalone: godot --headless --script tests/unit/hud/satisfaction_meter_test.gd
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"

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
	print("  UNIT TEST: Hud — Satisfaction Meter (Story HUD-003)")
	print("=".repeat(48))

	_test_fill_ramp_anchors()
	_test_fill_ramp_zone_boundaries()
	_test_fill_ramp_never_alarm()
	_test_fill_ramp_deterministic_no_pulse()
	_test_icon_glyph_zones()
	_test_icon_shape_colorblind_pairing()
	_test_ac3_ease_created_on_change()
	_test_ac3_lockstep_display()
	_test_ac3_no_restart_on_same_target()
	_test_ac3_retarget_mid_tween()
	_test_core_rule_2_rock_bottom_calm()
	_test_reduced_motion_static_fill()
	_test_reduced_motion_config_and_setter()
	_test_ease_duration_config()

	print("\n=== HUD SATISFACTION METER TEST: %d passed, %d failed ===\n" % [_pass, _fail])
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


func _sat(c: Color) -> float:
	# 4.7.1 Color has no get_s()/get_hsv() — compute saturation manually.
	var mx: float = maxf(c.r, maxf(c.g, c.b))
	var mn: float = minf(c.r, minf(c.g, c.b))
	if mx <= 0.0:
		return 0.0
	return (mx - mn) / mx


func _make_rig(seed: int = 0x0D1D0A7, config: Dictionary = {}) -> Dictionary:
	var srg: RefCounted = load("res://src/systems/seeded_rng.gd").new()
	srg.call("init", seed)
	var orch: Node = load("res://src/systems/simulation_orchestrator.gd").new()
	root.add_child(orch)
	orch.call("_ready")
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


func _fill_color(sat: float) -> Color:
	return _HUD().call("satisfaction_fill_color", sat) as Color


func _icon(sat: float) -> String:
	return str(_HUD().call("satisfaction_icon", sat))


func _shape(sat: float) -> String:
	return str(_HUD().call("satisfaction_icon_shape", sat))


# === TR-HUD-002: fill ramp ===

func _test_fill_ramp_anchors() -> void:
	print("\n[TR-HUD-002] fill ramp anchors: Sage (high) / warm neutral (mid) / Dusty Rose (very low)")
	# Anchor colors: Dusty Rose #E0A0A0, warm neutral, Sage #8FBF9F.
	var rose := Color("e0a0a0")
	var sage := Color("8fbf9f")
	var c0: Color = _fill_color(0.0)
	var c05: Color = _fill_color(0.5)
	var c10: Color = _fill_color(1.0)
	_check(c0.is_equal_approx(rose), "fill(0.0) == Dusty Rose #E0A0A0 (got %s)" % c0)
	_check(c10.is_equal_approx(sage), "fill(1.0) == Sage #8FBF9F (got %s)" % c10)
	# The mid zone anchor (0.33) is warm (red > blue), unlike the green high zone.
	var c33: Color = _fill_color(0.33)
	_check(c33.r > c33.b, "fill(0.33) is warm-toned (r > b) — warm neutral anchor (got %s)" % c33)
	_check(c33.r > c33.g, "fill(0.33) is NOT green-dominant (r > g) — distinct from Sage (got %s)" % c33)
	# Mid blend (0.5) sits between warm neutral and Sage: green-leaning but not
	# yet the pure Sage anchor.
	_check(c05.g > c05.r, "fill(0.5) is green-leaning (g > r) — transitioning toward Sage (got %s)" % c05)
	_check(not c05.is_equal_approx(sage), "fill(0.5) != Sage — still a blend, not the high anchor (got %s)" % c05)
	# Monotonic calm: low end is rose-ish (r > g), high end is sage-ish (g > r).
	_check(_fill_color(0.1).r > _fill_color(0.1).g, "fill(0.1) is rose-leaning (r > g) — very low end only")
	_check(_fill_color(0.9).g > _fill_color(0.9).r, "fill(0.9) is sage-leaning (g > r) — high end")


func _test_fill_ramp_zone_boundaries() -> void:
	print("\n[TR-HUD-002] ramp zone boundaries at 0.33 / 0.66 (icon changes exactly there)")
	var mid: float = 0.33
	var high: float = 0.66
	# Just below mid -> rose-leaning; at/above mid -> warm neutral.
	_check(_fill_color(mid - 0.01).r > _fill_color(mid - 0.01).g, "fill(0.32) still rose-leaning (r > g)")
	_check(_fill_color(mid).r > _fill_color(mid).b, "fill(0.33) reaches warm neutral (r > b)")
	_check(_fill_color(mid).r > _fill_color(mid).g, "fill(0.33) is warm (r > g) at the mid anchor")
	_check(_fill_color(high).is_equal_approx(Color("8fbf9f")), "fill(0.66) == Sage anchor exactly")
	_check(_fill_color(high + 0.01).is_equal_approx(Color("8fbf9f")), "fill(0.67) stays Sage above the zone")
	for i in range(0, 100):
		var a: Color = _fill_color(float(i) / 100.0)
		var b: Color = _fill_color(float(i + 1) / 100.0)
		if absf(a.r - b.r) > 0.05 or absf(a.g - b.g) > 0.05 or absf(a.b - b.b) > 0.05:
			_check(false, "ramp continuous at %d/100 (delta %s -> %s)" % [i, a, b])
			return
	_check(true, "ramp is continuous across 101 samples (max per-channel delta <= 0.05)")


func _test_fill_ramp_never_alarm() -> void:
	print("\n[TR-HUD-002] NEVER saturated red / alarm color at ANY fill (Pillar 2 absolute)")
	var worst_sat: float = 0.0
	for i in range(0, 101):
		var c: Color = _fill_color(float(i) / 100.0)
		var s: float = _sat(c)
		worst_sat = maxf(worst_sat, s)
		# Alarm-red test: not pure red, not high-saturation red.
		_check(c.r < 0.95, "fill(%d%%) r < 0.95 — no pure/alarm red (got %s)" % [i, c])
		if c.r >= 0.95:
			return
		_check(s < 0.45, "fill(%d%%) saturation < 0.45 — muted, calm (got %.3f)" % [i, s])
		if s >= 0.45:
			return
	_check(worst_sat < 0.4, "worst ramp saturation %.3f < 0.4 — entire ramp is muted" % worst_sat)


func _test_fill_ramp_deterministic_no_pulse() -> void:
	print("\n[TR-HUD-002] ramp is a pure static function — deterministic, no animation state")
	var a1: Color = _fill_color(0.42)
	var a2: Color = _fill_color(0.42)
	_check(a1.is_equal_approx(a2), "fill(0.42) is deterministic (same input, same output)")
	var b1: Color = _fill_color(0.0)
	var b2: Color = _fill_color(1.0)
	_check(not b1.is_equal_approx(b2), "fill(0.0) != fill(1.0) — ramp actually varies with value")


# === TR-HUD-003: icon + shape (colorblind-safe) ===

func _test_icon_glyph_zones() -> void:
	print("\n[TR-HUD-003] face icon glyphs: :) high / :| mid / :( very low")
	_check(_icon(1.0) == ":)", "icon(1.0) == :) (high, filled)")
	_check(_icon(0.66) == ":)", "icon(0.66) == :) (boundary inclusive)")
	_check(_icon(0.65) == ":|", "icon(0.65) == :| (mid)")
	_check(_icon(0.5) == ":|", "icon(0.5) == :| (mid)")
	_check(_icon(0.33) == ":|", "icon(0.33) == :| (mid boundary inclusive)")
	_check(_icon(0.32) == ":(", "icon(0.32) == :( (very low)")
	_check(_icon(0.0) == ":(", "icon(0.0) == :( (very low)")


func _test_icon_shape_colorblind_pairing() -> void:
	print("\n[TR-HUD-003] icon SHAPE carries state (filled vs outline) — readable without color")
	_check(_shape(0.66) == "filled", "shape(0.66) == filled")
	_check(_shape(0.5) == "filled", "shape(0.5) == filled (mid is still filled)")
	_check(_shape(0.33) == "filled", "shape(0.33) == filled (mid boundary inclusive)")
	_check(_shape(0.32) == "outline", "shape(0.32) == outline (very low)")
	_check(_shape(0.0) == "outline", "shape(0.0) == outline")
	# Colorblind pairing: the outline shape appears EXACTLY where the ramp is
	# rose-leaning (low zone) — a colorblind player sees shape change at the
	# same value a sighted player sees the color ramp change.
	for i in range(0, 101):
		var s: float = float(i) / 100.0
		var shape_matches: bool = (_shape(s) == "outline") == (s < 0.33)
		if not shape_matches:
			_check(false, "shape/ramp zone agree at %d%% (shape=%s)" % [i, _shape(s)])
			return
	_check(true, "icon shape and ramp zone agree across 101 samples — state never color-only")
	# Every zone has a distinct (glyph, shape) pair + the % label — three channels.
	var zone_a: Array = [_icon(0.9), _shape(0.9)]
	var zone_b: Array = [_icon(0.5), _shape(0.5)]
	var zone_c: Array = [_icon(0.1), _shape(0.1)]
	_check(zone_a != zone_b and zone_b != zone_c and zone_a != zone_c,
		"three zones have distinct (glyph, shape) pairs: %s / %s / %s" % [str(zone_a), str(zone_b), str(zone_c)])


# === AC3: ease + lockstep ===

func _test_ac3_ease_created_on_change() -> void:
	print("\n[AC3] global_satisfaction change -> meter eases toward the new fill")
	var rig := _make_rig()
	var sat: RefCounted = rig["sat"]
	var orch: Node = rig["orch"]
	var hud: Control = rig["hud"]
	var meter: ProgressBar = hud.call("get_meter")
	# Init snaps to S_BASE 0.5 (load path — no ease).
	_check(not bool(hud.call("is_meter_animating")), "init load-snap: not animating")
	_check(absf(float(meter.value) - 50.0) < 1e-6, "init load-snap: meter == 50.0 (S_BASE)")
	_check(absf(float(hud.call("get_meter_tween_target")) - 50.0) < 1e-6, "init target recorded as 50.0")
	# Now the live tick path: satisfaction moves 0.5 -> 0.8.
	sat.set("global_satisfaction", 0.8)
	orch.call("_advance_tick")  # fires tick_completed -> _refresh_satisfaction
	_check(bool(hud.call("is_meter_animating")), "after tick with changed target: meter is animating")
	_check(absf(float(hud.call("get_meter_tween_target")) - 80.0) < 1e-6,
		"tween target == 80.0 (got %s)" % hud.call("get_meter_tween_target"))
	_check(absf(float(hud.call("get_satisfaction_ease_duration")) - 1.0) < 1e-9,
		"ease duration == default 1.0 s (GDD knob)")
	# Headless: no frames pass, so the displayed value still shows the OLD fill
	# — the tween is mid-flight. The label must NOT have snapped (lockstep).
	_check(absf(float(hud.call("get_displayed_satisfaction")) - 0.5) < 1e-9,
		"displayed satisfaction still 0.5 (tween mid-flight, no frame in headless)")
	_check(hud.call("get_satisfaction_label").text == "50%",
		"%% label still 50%% mid-ease — updates WITH the fill, not before (got '%s')" % hud.call("get_satisfaction_label").text)


func _test_ac3_lockstep_display() -> void:
	print("\n[AC3] apply_satisfaction_display drives meter + % + icon + fill color in lockstep")
	var rig := _make_rig()
	var hud: Control = rig["hud"]
	var meter: ProgressBar = hud.call("get_meter")
	var label: Label = hud.call("get_satisfaction_label")
	var face: Label = hud.get_node("TopBar/SatisfactionGroup/FaceIcon")
	# Drive the same callback the tween uses every step (test seam).
	hud.call("apply_satisfaction_display", 0.8)
	_check(absf(float(meter.value) - 80.0) < 1e-6, "meter.value == 80.0 after display(0.8)")
	_check(label.text == "80%", "%% label == 80%% (got '%s')" % label.text)
	_check(face.text == ":)", "icon == :) at 0.8 (got '%s')" % face.text)
	var fill_style: StyleBoxFlat = meter.get_theme_stylebox("fill")
	_check(fill_style != null, "meter has a fill stylebox override")
	if fill_style != null:
		_check(fill_style.bg_color.is_equal_approx(_fill_color(0.8)),
			"fill color == ramp(0.8) (got %s)" % fill_style.bg_color)
	# Mid value: icon + color change together.
	hud.call("apply_satisfaction_display", 0.5)
	_check(label.text == "50%", "label == 50%% at 0.5 (got '%s')" % label.text)
	_check(face.text == ":|", "icon == :| at 0.5 (got '%s')" % face.text)
	if fill_style != null:
		_check(fill_style.bg_color.is_equal_approx(_fill_color(0.5)),
			"fill color == ramp(0.5) at 0.5 (got %s)" % fill_style.bg_color)
	# Clamping: out-of-range values never break the display.
	hud.call("apply_satisfaction_display", 1.7)
	_check(label.text == "100%", "display(1.7) clamps to 100%% (got '%s')" % label.text)
	hud.call("apply_satisfaction_display", -0.3)
	_check(label.text == "0%", "display(-0.3) clamps to 0%% (got '%s')" % label.text)


func _test_ac3_no_restart_on_same_target() -> void:
	print("\n[AC3] tick re-reading the SAME target does NOT restart the tween (10 Hz no-op)")
	var rig := _make_rig()
	var sat: RefCounted = rig["sat"]
	var orch: Node = rig["orch"]
	var hud: Control = rig["hud"]
	sat.set("global_satisfaction", 0.8)
	orch.call("_advance_tick")
	_check(bool(hud.call("is_meter_animating")), "animating after first change")
	var target_after_first: float = float(hud.call("get_meter_tween_target"))
	# Same value, second tick — must not restart (target stays, tween stays valid).
	orch.call("_advance_tick")
	_check(bool(hud.call("is_meter_animating")), "still animating after same-target tick (tween not killed)")
	_check(absf(float(hud.call("get_meter_tween_target")) - target_after_first) < 1e-9,
		"target unchanged after same-target tick (%.1f)" % hud.call("get_meter_tween_target"))


func _test_ac3_retarget_mid_tween() -> void:
	print("\n[AC3] re-target mid-tween: kill + new tween from CURRENT displayed value (no queue backlog)")
	var rig := _make_rig()
	var sat: RefCounted = rig["sat"]
	var orch: Node = rig["orch"]
	var hud: Control = rig["hud"]
	sat.set("global_satisfaction", 0.8)
	orch.call("_advance_tick")
	_check(bool(hud.call("is_meter_animating")), "animating toward 0.8")
	# Satisfaction changes again before the first ease completes.
	sat.set("global_satisfaction", 0.6)
	orch.call("_advance_tick")
	_check(absf(float(hud.call("get_meter_tween_target")) - 60.0) < 1e-6,
		"tween re-targeted to 60.0 (got %s)" % hud.call("get_meter_tween_target"))
	_check(bool(hud.call("is_meter_animating")), "still animating (new tween, not queued)")
	# The re-targeted tween starts from the CURRENT displayed value, not 0.8.
	_check(absf(float(hud.call("get_displayed_satisfaction")) - 0.5) < 1e-9,
		"displayed value still 0.5 — new tween starts from current displayed (no jump)")


# === Core Rule 2: rock bottom ===

func _test_core_rule_2_rock_bottom_calm() -> void:
	print("\n[Core Rule 2] satisfaction at rock bottom: muted warm tone, never red, never flashing")
	var rose := Color("e0a0a0")
	var bottom: Color = _fill_color(0.0)
	_check(bottom.is_equal_approx(rose), "rock bottom fill == Dusty Rose (muted warm) — got %s" % bottom)
	_check(_sat(bottom) < 0.4, "rock bottom saturation %.3f < 0.4 — muted, not alarm red" % _sat(bottom))
	_check(bottom.r < 0.95, "rock bottom r %.3f < 0.95 — no pure red" % bottom.r)
	_check(_icon(0.0) == ":(" and _shape(0.0) == "outline",
		"rock bottom icon is :( outline — state readable without color")
	# Still paired with % + icon on the live HUD.
	var rig := _make_rig()
	var sat: RefCounted = rig["sat"]
	var hud: Control = rig["hud"]
	var meter: ProgressBar = hud.call("get_meter")
	var face: Label = hud.get_node("TopBar/SatisfactionGroup/FaceIcon")
	sat.set("global_satisfaction", 0.0)
	hud.call("refresh_all")  # load-snap path (also what a rock-bottom save shows)
	_check(hud.call("get_satisfaction_label").text == "0%", "rock bottom %% label == 0%% (got '%s')" % hud.call("get_satisfaction_label").text)
	_check(absf(float(meter.value)) < 1e-6, "rock bottom meter == 0.0")
	_check(face.text == ":(", "rock bottom icon == :( (got '%s')" % face.text)
	_check(not bool(hud.call("is_meter_animating")), "rock bottom load-snap: no animation/pulse")
	# No pulse even on the live path: a single change creates ONE finite tween
	# (default loop count = plays once; 4.7.1 exposes get_loops_left()).
	sat.set("global_satisfaction", 0.2)
	var orch: Node = rig["orch"]
	orch.call("_advance_tick")
	_check(bool(hud.call("is_meter_animating")), "live path animates once toward 0.2")
	var tween: Tween = hud.call("get_meter_tween")
	_check(tween != null, "meter tween exists")
	if tween != null:
		_check(int(tween.get_loops_left()) == 1,
			"meter tween plays once (loops_left == 1) — no repeating pulse/animation (got %d)" % int(tween.get_loops_left()))


# === reduced-motion ===

func _test_reduced_motion_static_fill() -> void:
	print("\n[Reduced-motion] static fill: value + % + icon snap, NO tween")
	var rig := _make_rig(0, {"reduced_motion": true})
	var sat: RefCounted = rig["sat"]
	var orch: Node = rig["orch"]
	var hud: Control = rig["hud"]
	var meter: ProgressBar = hud.call("get_meter")
	_check(bool(hud.call("get_reduced_motion")), "reduced_motion active from config")
	_check(not bool(hud.call("is_meter_animating")), "init: not animating")
	sat.set("global_satisfaction", 0.77)
	orch.call("_advance_tick")
	_check(not bool(hud.call("is_meter_animating")), "tick with reduced-motion: NO tween created (static fill)")
	_check(absf(float(meter.value) - 77.0) < 1e-6, "meter snapped to 77.0 immediately (got %s)" % meter.value)
	_check(hud.call("get_satisfaction_label").text == "77%", "%% label snapped to 77%% (got '%s')" % hud.call("get_satisfaction_label").text)
	_check(hud.get_node("TopBar/SatisfactionGroup/FaceIcon").text == ":)", "icon snapped to :) at 0.77")


func _test_reduced_motion_config_and_setter() -> void:
	print("\n[Reduced-motion] config default + live setter")
	var rig := _make_rig()  # no config -> auto-detect (headless: no OS preference -> false)
	var hud: Control = rig["hud"]
	_check(not bool(hud.call("get_reduced_motion")), "headless auto-detect: reduced_motion off (no OS pref)")
	hud.call("set_reduced_motion", true)
	_check(bool(hud.call("get_reduced_motion")), "set_reduced_motion(true) flips the flag")
	var rig2 := _make_rig(1, {"reduced_motion": false})
	_check(not bool(rig2["hud"].call("get_reduced_motion")), "config reduced_motion=false overrides auto-detect")


# === config ===

func _test_ease_duration_config() -> void:
	print("\n[Config] satisfaction_ease_duration knob (GDD safe range 0.5-1.5 s)")
	var rig := _make_rig(0, {"satisfaction_ease_duration": 1.5})
	_check(absf(float(rig["hud"].call("get_satisfaction_ease_duration")) - 1.5) < 1e-9,
		"config 1.5 -> ease duration 1.5 (got %s)" % rig["hud"].call("get_satisfaction_ease_duration"))
	var rig_low := _make_rig(2, {"satisfaction_ease_duration": 0.1})
	_check(absf(float(rig_low["hud"].call("get_satisfaction_ease_duration")) - 0.5) < 1e-9,
		"config 0.1 clamps to safe minimum 0.5 (got %s)" % rig_low["hud"].call("get_satisfaction_ease_duration"))
	var rig_high := _make_rig(3, {"satisfaction_ease_duration": 9.0})
	_check(absf(float(rig_high["hud"].call("get_satisfaction_ease_duration")) - 1.5) < 1e-9,
		"config 9.0 clamps to safe maximum 1.5 (got %s)" % rig_high["hud"].call("get_satisfaction_ease_duration"))
	var rig_default := _make_rig(4, {})
	_check(absf(float(rig_default["hud"].call("get_satisfaction_ease_duration")) - 1.0) < 1e-9,
		"no config -> default 1.0 (got %s)" % rig_default["hud"].call("get_satisfaction_ease_duration"))
