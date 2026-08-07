# tests/unit/congestion_overlay/rejection_bucket_test.gd
# Story CFO-004: Rejection Tooltip — fail-code→bucket mapping + hold state
# (production/epics/congestion-flow-overlay/story-004-rejection-tooltip-layer-priority.md)
#
# BLOCKING ACs covered:
#   AC4  rejected drop with a footprint-bucket fail code, cursor holds
#        400 ms -> tooltip reads "Won't fit here", never a raw fail-code
#        string
#   AC5  rejected drop with an access-bucket fail code, cursor holds
#        400 ms -> tooltip reads "Blocks the path in"
#   Core Rule 6  5 fail codes collapse into 2 buckets (footprint vs
#        access), reusing the ghost's split
#   Flicker protection  tooltip only shows after the hold elapses while
#        still pending; a stale timer after dismiss is a no-op (fast sweep
#        -> no tooltip)
#   Pillar 2  no sound tied to rejection (structural source check)
#   Config knob  rejection_tooltip_hold_ms default 400, clamped 250–600
#
# Run standalone: godot --headless --script tests/unit/congestion_overlay/rejection_bucket_test.gd
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"

# FailCode mirror — MUST stay in sync with GridSystem.FailCode (TR-GS-015).
const VALID := 0
const OUT_OF_BOUNDS := 1
const BLOCKED_BY_ROOM_GEOMETRY := 2
const OVERLAPS_EXISTING_EQUIPMENT := 3
const ACCESS_OUT_OF_BOUNDS := 4
const ACCESS_BLOCKED_BY_ROOM_GEOMETRY := 5

const MESSAGE_FOOTPRINT := "Won't fit here"
const MESSAGE_ACCESS := "Blocks the path in"

var _pass := 0
var _fail := 0


func _init() -> void:
	if Engine.has_meta(RUNNER_META):
		return
	var result := run_all()
	quit(1 if int(result["fail"]) > 0 else 0)


func run_all() -> Dictionary:
	print("=".repeat(48))
	print("  UNIT TEST: Congestion Overlay — Rejection Tooltip Buckets (Story CFO-004)")
	print("=".repeat(48))

	_test_footprint_bucket_codes()
	_test_access_bucket_codes()
	_test_never_raw_fail_code()
	_test_hold_state_machine()
	_test_stale_timer_noop_after_dismiss()
	_test_re_arm_replaces_message()
	_test_hold_ms_config_knob()
	_test_hold_ms_config_clamp()
	_test_no_sound_structural()

	print("\n=== REJECTION BUCKET TEST: %d passed, %d failed ===\n" % [_pass, _fail])
	return {"pass": _pass, "fail": _fail}


func _check(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
		print("  PASS: " + msg)
	else:
		_fail += 1
		print("  FAIL: " + msg)


# === Helpers ===

func _RT() -> Script:
	return load("res://src/ui/rejection_tooltip.gd") as Script


func _make_tooltip(config: Dictionary = {}) -> RefCounted:
	var tooltip: RefCounted = _RT().new()
	tooltip.call("init", config)
	return tooltip


# === AC4: footprint bucket ===

func _test_footprint_bucket_codes() -> void:
	print("\n[AC4] footprint bucket -> \"Won't fit here\" (OUT_OF_BOUNDS / BLOCKED_BY_ROOM_GEOMETRY / OVERLAPS_EXISTING_EQUIPMENT)")
	var tooltip := _make_tooltip()
	for code in [OUT_OF_BOUNDS, BLOCKED_BY_ROOM_GEOMETRY, OVERLAPS_EXISTING_EQUIPMENT]:
		var msg: String = tooltip.call("classify_fail_code", code)
		_check(msg == MESSAGE_FOOTPRINT,
			"AC4: fail_code %d -> \"%s\" (got \"%s\")" % [code, MESSAGE_FOOTPRINT, msg])


# === AC5: access bucket ===

func _test_access_bucket_codes() -> void:
	print("\n[AC5] access bucket -> \"Blocks the path in\" (ACCESS_OUT_OF_BOUNDS / ACCESS_BLOCKED_BY_ROOM_GEOMETRY)")
	var tooltip := _make_tooltip()
	for code in [ACCESS_OUT_OF_BOUNDS, ACCESS_BLOCKED_BY_ROOM_GEOMETRY]:
		var msg: String = tooltip.call("classify_fail_code", code)
		_check(msg == MESSAGE_ACCESS,
			"AC5: fail_code %d -> \"%s\" (got \"%s\")" % [code, MESSAGE_ACCESS, msg])


# === Core Rule 6: never a raw fail-code string ===

func _test_never_raw_fail_code() -> void:
	print("\n[CR6] every one of the 5 codes maps to a bucket message — never a raw fail-code string")
	var tooltip := _make_tooltip()
	var raw_names := ["OUT_OF_BOUNDS", "BLOCKED_BY_ROOM_GEOMETRY", "OVERLAPS_EXISTING_EQUIPMENT",
		"ACCESS_OUT_OF_BOUNDS", "ACCESS_BLOCKED_BY_ROOM_GEOMETRY"]
	var all_bucket := true
	for code in [OUT_OF_BOUNDS, BLOCKED_BY_ROOM_GEOMETRY, OVERLAPS_EXISTING_EQUIPMENT,
			ACCESS_OUT_OF_BOUNDS, ACCESS_BLOCKED_BY_ROOM_GEOMETRY]:
		var msg: String = tooltip.call("classify_fail_code", code)
		if msg != MESSAGE_FOOTPRINT and msg != MESSAGE_ACCESS:
			all_bucket = false
		for raw in raw_names:
			if msg == raw or msg.contains(raw):
				all_bucket = false
	_check(all_bucket, "CR6: all 5 fail codes map to one of the two bucket messages (0 raw codes leaked)")

	# End-to-end: a rejected drop arms the tooltip with the bucket message.
	tooltip.call("on_placement_rejected", "treadmill_01", Vector2i(3, 3), 0, OVERLAPS_EXISTING_EQUIPMENT)
	_check(tooltip.call("get_message") == MESSAGE_FOOTPRINT,
		"CR6: placement_rejected(OVERLAPS) -> tooltip message is the bucket text")
	_check(not (tooltip.call("get_message") as String).contains("OVERLAPS"),
		"CR6: raw fail-code name never appears in the tooltip message")


# === Hold state machine (400 ms delay, flicker protection) ===

func _test_hold_state_machine() -> void:
	print("\n[HOLD] placement_rejected -> pending (hidden); hold elapsed -> visible")
	var tooltip := _make_tooltip()

	_check(not tooltip.call("is_visible"), "HOLD: fresh tooltip hidden")
	_check(not tooltip.call("is_pending"), "HOLD: fresh tooltip not pending")

	tooltip.call("on_placement_rejected", "treadmill_01", Vector2i(5, 5), 90, OUT_OF_BOUNDS)
	_check(not tooltip.call("is_visible"), "HOLD: after rejection — still hidden (hold delay)")
	_check(tooltip.call("is_pending"), "HOLD: after rejection — pending (hold window open)")
	_check(tooltip.call("get_anchor") == Vector2i(5, 5), "HOLD: anchor recorded for cursor-adjacent drawing")
	_check(tooltip.call("get_message") == MESSAGE_FOOTPRINT, "HOLD: message set to the footprint bucket")

	tooltip.call("on_hold_elapsed")
	_check(tooltip.call("is_visible"), "HOLD: after hold elapses — tooltip visible (AC4: 'Won't fit here')")
	_check(tooltip.call("get_message") == MESSAGE_FOOTPRINT, "HOLD: visible message is the bucket text, never the code")

	tooltip.call("dismiss")
	_check(not tooltip.call("is_visible"), "HOLD: dismiss -> hidden")
	_check(not tooltip.call("is_pending"), "HOLD: dismiss -> hold window closed")


func _test_stale_timer_noop_after_dismiss() -> void:
	print("\n[HOLD edge] fast sweep: dismiss before the hold elapses -> stale timer is a NO-OP (no tooltip flicker)")
	var tooltip := _make_tooltip()

	tooltip.call("on_placement_rejected", "treadmill_01", Vector2i(2, 2), 0, BLOCKED_BY_ROOM_GEOMETRY)
	tooltip.call("dismiss")  # cursor moved to a valid cell / drag ended before 400 ms
	tooltip.call("on_hold_elapsed")  # the stale timer fires
	_check(not tooltip.call("is_visible"),
		"HOLD-edge: stale hold-elapsed after dismiss does NOT show the tooltip (sweep flicker protection)")
	_check(not tooltip.call("is_pending"), "HOLD-edge: hold window stays closed")


func _test_re_arm_replaces_message() -> void:
	print("\n[HOLD edge] second rejection while pending -> replaces the message (single calm tooltip, never stacked)")
	var tooltip := _make_tooltip()

	tooltip.call("on_placement_rejected", "treadmill_01", Vector2i(1, 1), 0, OVERLAPS_EXISTING_EQUIPMENT)
	_check(tooltip.call("get_message") == MESSAGE_FOOTPRINT, "RE-ARM: first rejection -> footprint bucket")

	tooltip.call("on_placement_rejected", "dumbbell_01", Vector2i(4, 4), 0, ACCESS_BLOCKED_BY_ROOM_GEOMETRY)
	_check(tooltip.call("get_message") == MESSAGE_ACCESS, "RE-ARM: second rejection -> access bucket (replaces)")
	_check(tooltip.call("get_anchor") == Vector2i(4, 4), "RE-ARM: anchor updated to the newest rejection")
	_check(not tooltip.call("is_visible"), "RE-ARM: still hidden — the new 400 ms window is open")

	tooltip.call("on_hold_elapsed")
	_check(tooltip.call("is_visible") and tooltip.call("get_message") == MESSAGE_ACCESS,
		"RE-ARM: after hold — newest message shown")


# === Config knob ===

func _test_hold_ms_config_knob() -> void:
	print("\n[CONFIG] rejection_tooltip_hold_ms default 400; override via config")
	var tooltip := _make_tooltip()
	_check(absf(float(tooltip.call("get_hold_ms")) - 400.0) < 1e-9,
		"CONFIG: default hold_ms == 400 (got %s)" % str(tooltip.call("get_hold_ms")))

	var tooltip300 := _make_tooltip({"rejection_tooltip_hold_ms": 300})
	_check(absf(float(tooltip300.call("get_hold_ms")) - 300.0) < 1e-9,
		"CONFIG: override hold_ms == 300 (got %s)" % str(tooltip300.call("get_hold_ms")))


func _test_hold_ms_config_clamp() -> void:
	print("\n[CONFIG] hold_ms clamped to the GDD safe range 250–600")
	var tooltip_low := _make_tooltip({"rejection_tooltip_hold_ms": 100})
	_check(absf(float(tooltip_low.call("get_hold_ms")) - 250.0) < 1e-9,
		"CONFIG: hold_ms 100 clamped up to 250 (got %s)" % str(tooltip_low.call("get_hold_ms")))

	var tooltip_high := _make_tooltip({"rejection_tooltip_hold_ms": 1000})
	_check(absf(float(tooltip_high.call("get_hold_ms")) - 600.0) < 1e-9,
		"CONFIG: hold_ms 1000 clamped down to 600 (got %s)" % str(tooltip_high.call("get_hold_ms")))


# === Pillar 2: silence ===

func _test_no_sound_structural() -> void:
	print("\n[PILLAR 2] rejection tooltip source contains no audio machinery (silence, not a failure buzz)")
	var f := FileAccess.open("res://src/ui/rejection_tooltip.gd", FileAccess.READ)
	_check(f != null, "PILLAR2: production file readable")
	if f == null:
		return
	var src := f.get_as_text()
	_check(not src.contains("AudioStream") and not src.contains(".play(") and not src.contains("AudioStreamPlayer"),
		"PILLAR2: no AudioStream/play() in the tooltip source (silence)")
