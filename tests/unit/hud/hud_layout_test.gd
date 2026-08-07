# tests/unit/hud/hud_layout_test.gd
# Story HUD-001: Top-bar Layout & Read-only State Binding
# (production/epics/hud/story-001-top-bar-layout-state-binding.md)
#
# Covers the layout side of the BLOCKING ACs:
#   - Core Rule 1: the top bar shows money (Butter, coin icon) top-left,
#         satisfaction top-center, day/time + transport top-right — and
#         NOTHING else (no bottom bar, no side panels). The HUD root has
#         exactly one child (TopBar); TopBar is an HBoxContainer with the
#         F-pattern order [MoneyGroup, spacer, SatisfactionGroup, spacer,
#         TimeGroup] and the two spacers expand to push time to the right.
#   - AC7: text stays readable at minimum font size (>= 16px @1080p at
#         1.0× UI scale) and the top bar occupies <= ~8% of the vertical
#         screen height at 1080p (48px + 16px safe margin = 64px strip <=
#         86.4px). Safe margin >= 16px from screen edges at 1.0× UI scale.
#
# Headless-layout note (verified with layout_probe.gd on 4.7.1): containers
# do NOT sort children synchronously during run_all() — the HBox positions
# its children only after the main loop starts. The assertions below are
# therefore STRUCTURAL (node existence, child order, anchors/offsets, size
# flags, font overrides) — everything that is deterministic without a frame.
# Pixel positions are verified by the manual walkthrough in
# production/qa/evidence/hud-top-bar-layout-evidence.md.
#
# Run standalone: godot --headless --script tests/unit/hud/hud_layout_test.gd
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"

var _pass := 0
var _fail := 0


func _init() -> void:
	if Engine.has_meta(RUNNER_META):
		return
	var result := run_all()
	quit(1 if int(result["fail"]) > 0 else 0)


func run_all() -> Dictionary:
	print("=".repeat(48))
	print("  UNIT TEST: Hud — Layout (Story HUD-001)")
	print("=".repeat(48))

	_test_core_rule_1_single_top_bar()
	_test_core_rule_1_f_pattern_order()
	_test_core_rule_1_money_group()
	_test_core_rule_1_satisfaction_group()
	_test_core_rule_1_time_group_transport()
	_test_no_bottom_bar_no_side_panels()
	_test_ac7_font_size_readable()
	_test_ac7_top_bar_height_budget()
	_test_ac7_safe_margins()
	_test_input_transparent()

	print("\n=== HUD LAYOUT TEST: %d passed, %d failed ===\n" % [_pass, _fail])
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


## A bare HUD with init() called (systems are required by the signature, but
## layout assertions only inspect structure, so a minimal rig suffices).
func _make_hud() -> Control:
	var srg: RefCounted = load("res://src/systems/seeded_rng.gd").new()
	srg.call("init", 0x0A7)
	var orch: Node = load("res://src/systems/simulation_orchestrator.gd").new()
	root.add_child(orch)
	orch.call("_ready")
	var econ: RefCounted = load("res://src/systems/economy.gd").new()
	econ.call("init", orch, srg)
	var sat: RefCounted = load("res://src/systems/satisfaction.gd").new()
	sat.call("init", orch, srg)
	var hud: Control = _HUD().new()
	root.add_child(hud)
	hud.call("init", econ, sat, orch.get("time_system"), orch, {})
	return hud


# === Core Rule 1 ===

func _test_core_rule_1_single_top_bar() -> void:
	print("\n[Core Rule 1] single top bar, full width, top of screen")
	var hud := _make_hud()
	_check(hud.get_child_count() == 1, "HUD root has exactly one child (the top bar)")
	var top_bar: Control = hud.get_child(0)
	_check(top_bar.name == "TopBar", "the single child is TopBar (got %s)" % top_bar.name)
	_check(top_bar is HBoxContainer, "TopBar is an HBoxContainer (got %s)" % top_bar.get_class())
	_check(top_bar.anchor_left == 0.0 and top_bar.anchor_right == 1.0, "TopBar spans full width (anchors 0..1)")
	_check(top_bar.anchor_top == 0.0 and top_bar.anchor_bottom == 0.0, "TopBar anchored to the top edge")


func _test_core_rule_1_f_pattern_order() -> void:
	print("\n[Core Rule 1] F-pattern order: money | spacer | satisfaction | spacer | time")
	var hud := _make_hud()
	var top_bar: Control = hud.get_child(0)
	var names: Array[String] = []
	for child in top_bar.get_children():
		names.append(child.name)
	_check(names == ["MoneyGroup", "LeftSpacer", "SatisfactionGroup", "RightSpacer", "TimeGroup"],
		"TopBar child order is money/spacer/satisfaction/spacer/time (got %s)" % str(names))
	var left_spacer: Control = top_bar.get_node("LeftSpacer")
	var right_spacer: Control = top_bar.get_node("RightSpacer")
	_check(left_spacer.size_flags_horizontal & Control.SIZE_EXPAND_FILL != 0, "LeftSpacer expands (pushes time right)")
	_check(right_spacer.size_flags_horizontal & Control.SIZE_EXPAND_FILL != 0, "RightSpacer expands (pushes time right)")


func _test_core_rule_1_money_group() -> void:
	print("\n[Core Rule 1] money group: Butter coin icon + value label (top-left)")
	var hud := _make_hud()
	var money_group: Control = hud.get_child(0).get_node("MoneyGroup")
	_check(money_group.get_child_count() == 2, "MoneyGroup has exactly 2 children (coin icon + label)")
	var coin: Label = money_group.get_node("CoinIcon")
	var value: Label = money_group.get_node("MoneyLabel")
	_check(coin is Label and coin.text == "🪙", "CoinIcon present with the coin glyph (got '%s')" % coin.text)
	_check(value is Label, "MoneyLabel present")
	_check(int(value.get_theme_font_size("font_size")) >= 16, "money text >= 16px @1080p")


func _test_core_rule_1_satisfaction_group() -> void:
	print("\n[Core Rule 1] satisfaction group: face icon + quiet meter + % label (top-center)")
	var hud := _make_hud()
	var sat_group: Control = hud.get_child(0).get_node("SatisfactionGroup")
	_check(sat_group.get_child_count() == 3, "SatisfactionGroup has exactly 3 children (face + meter + %)")
	var face: Label = sat_group.get_node("FaceIcon")
	var meter: ProgressBar = sat_group.get_node("Meter")
	var pct: Label = sat_group.get_node("SatisfactionLabel")
	_check(face is Label, "FaceIcon present")
	_check(meter is ProgressBar, "Meter is a quiet ProgressBar (not a health-bar metaphor)")
	_check(absf(float(meter.max_value) - 100.0) < 1e-9 and absf(float(meter.min_value)) < 1e-9, "meter range 0..100")
	_check(not meter.show_percentage, "meter shows no built-in percentage (own % label carries it)")
	_check(pct is Label, "SatisfactionLabel present")
	_check(int(pct.get_theme_font_size("font_size")) >= 16, "satisfaction % text >= 16px @1080p")


func _test_core_rule_1_time_group_transport() -> void:
	print("\n[Core Rule 1] day/time + transport cluster (top-right)")
	var hud := _make_hud()
	var time_group: Control = hud.get_child(0).get_node("TimeGroup")
	var day: Label = time_group.get_node("DayLabel")
	var tod: Label = time_group.get_node("TimeOfDayLabel")
	var transport: Control = time_group.get_node("TransportCluster")
	_check(day is Label and day.text.begins_with("Day "), "DayLabel present showing 'Day N' (got '%s')" % day.text)
	_check(tod is Label, "TimeOfDayLabel present (clock-position icon, Story 004)")
	_check(transport is HBoxContainer, "TransportCluster present as a grouped cluster")
	_check(transport.get_child_count() == 4, "TransportCluster has exactly 4 buttons (pause + 3 speeds) — got %d" % transport.get_child_count())
	var pause_btn: Control = transport.get_node("PauseButton")
	var speed1: Control = transport.get_node("SpeedButton1")
	var speed2: Control = transport.get_node("SpeedButton2")
	var speed3: Control = transport.get_node("SpeedButton3")
	_check(pause_btn is Button, "PauseButton is a Button (Story 004 transport surface)")
	_check(speed1 is Button and speed2 is Button and speed3 is Button, "SpeedButton1/2/3 are Buttons")
	_check((pause_btn as Button).text.ends_with("‖"), "PauseButton label is ‖ (with optional active-dot prefix, got '%s')" % (pause_btn as Button).text)
	_check((speed1 as Button).text.ends_with("1×") and (speed2 as Button).text.ends_with("2×") and (speed3 as Button).text.ends_with("3×"),
		"speed button labels are 1×/2×/3× (got %s/%s/%s)" % [(speed1 as Button).text, (speed2 as Button).text, (speed3 as Button).text])


func _test_no_bottom_bar_no_side_panels() -> void:
	print("\n[Core Rule 1] nothing else on the HUD — no bottom bar, no side panels")
	var hud := _make_hud()
	_check(hud.get_child_count() == 1, "root has exactly ONE child (TopBar) — got %d" % hud.get_child_count())
	var top_bar: Control = hud.get_child(0)
	_check(top_bar.get_child_count() == 5, "TopBar has exactly 5 children (3 groups + 2 spacers) — got %d" % top_bar.get_child_count())


# === AC7 ===

func _test_ac7_font_size_readable() -> void:
	print("\n[AC7] minimum font size readable at 1.0× UI scale (>= 16px @1080p)")
	var hud := _make_hud()
	var labels: Array[Label] = [
		hud.get_child(0).get_node("MoneyGroup/CoinIcon"),
		hud.get_child(0).get_node("MoneyGroup/MoneyLabel"),
		hud.get_child(0).get_node("SatisfactionGroup/FaceIcon"),
		hud.get_child(0).get_node("SatisfactionGroup/SatisfactionLabel"),
		hud.get_child(0).get_node("TimeGroup/DayLabel"),
		hud.get_child(0).get_node("TimeGroup/TimeOfDayLabel"),
	]
	var min_seen: int = 99999
	for label in labels:
		var size: int = int(label.get_theme_font_size("font_size"))
		min_seen = mini(min_seen, size)
	_check(min_seen >= 16, "every HUD label font size >= 16px (min seen %d)" % min_seen)
	var buttons: Array[Button] = [
		hud.get_child(0).get_node("TimeGroup/TransportCluster/PauseButton"),
		hud.get_child(0).get_node("TimeGroup/TransportCluster/SpeedButton1"),
		hud.get_child(0).get_node("TimeGroup/TransportCluster/SpeedButton2"),
		hud.get_child(0).get_node("TimeGroup/TransportCluster/SpeedButton3"),
	]
	var min_btn: int = 99999
	for btn in buttons:
		var size: int = int(btn.get_theme_font_size("font_size"))
		min_btn = mini(min_btn, size)
	_check(min_btn >= 16, "every transport button font size >= 16px (min seen %d)" % min_btn)


func _test_ac7_top_bar_height_budget() -> void:
	print("\n[AC7] top bar occupies <= ~8% of 1080p vertical height (48+16=64px <= 86.4px)")
	var hud := _make_hud()
	var top_bar: Control = hud.get_child(0)
	var height: int = int(top_bar.offset_bottom - top_bar.offset_top)
	# 8% of 1080 = 86.4px; the bar strip is 48px + 16px safe margin = 64px.
	_check(height <= 86, "top bar height %d <= 86.4px (8%% of 1080p)" % height)
	_check(height <= 64, "top bar strip incl. margin within the 48-64px design budget (got %d)" % height)


func _test_ac7_safe_margins() -> void:
	print("\n[AC7] safe margin >= 16px from screen edges at 1.0× UI scale")
	var hud := _make_hud()
	var top_bar: Control = hud.get_child(0)
	_check(int(top_bar.offset_left) >= 16, "left safe margin %d >= 16px" % int(top_bar.offset_left))
	_check(int(top_bar.offset_right) <= -16, "right safe margin %d <= -16px" % int(top_bar.offset_right))
	# The three groups sit INSIDE the margin (children of TopBar; offsets relative
	# to the bar's own content rect are >= 0 by construction of the HBox layout).
	_check(top_bar.offset_top == 0, "top bar starts at the very top edge (offset_top 0)")


func _test_input_transparent() -> void:
	print("\n[Read-only] HUD never blocks the play area (only the 4 transport buttons capture input)")
	var hud := _make_hud()
	_check(hud.mouse_filter == Control.MOUSE_FILTER_IGNORE, "HUD root mouse_filter == IGNORE (never steals clicks)")
	var top_bar: Control = hud.get_child(0)
	_check(top_bar.mouse_filter == Control.MOUSE_FILTER_IGNORE, "TopBar mouse_filter == IGNORE")
	# Story 004: the 4 transport buttons are MOUSE_FILTER_STOP (clickable) —
	# the ONLY input-capturing descendants in the tree. Everything else stays IGNORE.
	var offenders: Array = []
	var expected_stop: Array[String] = ["PauseButton", "SpeedButton1", "SpeedButton2", "SpeedButton3"]
	_scan_input_offenders(hud, offenders, expected_stop)
	_check(offenders.is_empty(), "only the 4 transport buttons capture mouse input (unexpected: %s)" % str(offenders))
	# Every transport button is STOP, and no other descendant is.
	var stops: Array = []
	_scan_all_stops(hud, stops)
	_check(stops.size() == 4, "exactly 4 STOP controls in the whole HUD tree (got %d: %s)" % [stops.size(), str(stops)])


func _scan_input_offenders(node: Node, offenders: Array, allowed_stop: Array[String]) -> void:
	if node is Control and (node as Control).mouse_filter == Control.MOUSE_FILTER_STOP:
		if node.name not in allowed_stop:
			offenders.append(node.name)
	for child in node.get_children():
		_scan_input_offenders(child, offenders, allowed_stop)


func _scan_all_stops(node: Node, stops: Array) -> void:
	if node is Control and (node as Control).mouse_filter == Control.MOUSE_FILTER_STOP:
		stops.append(node.name)
	for child in node.get_children():
		_scan_all_stops(child, stops)
