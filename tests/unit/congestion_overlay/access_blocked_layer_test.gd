# tests/unit/congestion_overlay/access_blocked_layer_test.gd
# Story CFO-003: Access-Blocked Layer (Default-Visible)
# (production/epics/congestion-flow-overlay/story-003-access-blocked-layer.md)
#
# BLOCKING ACs covered (TR-CFO-001 access-blocked / TR-CFO-005 / TR-CFO-011):
#   Core Rule 5 (load-bearing) — scene loads with already-unreachable
#        equipment -> layer.configure() materializes a STATIC icon for every
#        access_reachable==false entry IMMEDIATELY: no event gate, no
#        "fade-in on false" trigger, no intervening tick. Edge: multiple
#        walled-off machines -> each own icon, never merged / stack-counted.
#   AC2  heatmap off + access_reachable flips false -> barricade icon appears
#        (single fade-in once, then static). Edge: flickers true<->false
#        across quick edits — event-driven, no strobe within a stable layout.
#   AC12 access_reachable false + heatmap toggle OFF -> icon still visible
#        (always-on layer independent of the toggle). Edge: toggle ON/OFF
#        mid-render — icon unaffected.
#   AC8  any state rendered over 10s -> no flash, no loop pulse, no failure
#        sound: fade state machine is TERMINAL (fading_in -> static, no code
#        path returns), quiet ticks leave the icon set untouched, and the
#        layer source contains no audio reference.
#   Plus (story contract surface):
#   - equipment removed while icon showing -> icon removed same frame
#     (grid_changed handler, before any tick)
#   - access_reachable -> true -> icon removed (S8 reconcile, one tick)
#   - flag-absence semantics: reachability machinery off (no navigation) ->
#     ZERO icons (never misreport every machine as walled off)
#   - fixed UI-layer scale: set_camera_zoom() inverse-scales glyph size only;
#     icon anchor positions never move
#   - one-line hover tooltip state machine (visible / hidden), fixed copy
#   - reconfigure() idempotent: no duplicate typed signal connections
#
# Run standalone: godot --headless --script tests/unit/congestion_overlay/access_blocked_layer_test.gd
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"

const GRID_W := 10
const GRID_H := 8
const R0 := 0
const ENTRANCE := Vector2i(0, 0)
const CELL_SIZE := 32  # must match the layer's anchor math (half cell above center)

const LAYER_SCRIPT_PATH := "res://src/presentation/access_blocked_layer.gd"

var _pass := 0
var _fail := 0


func _init() -> void:
	if Engine.has_meta(RUNNER_META):
		return
	var result := run_all()
	quit(1 if int(result["fail"]) > 0 else 0)


func run_all() -> Dictionary:
	print("=".repeat(48))
	print("  UNIT TEST: AccessBlockedLayer — default-visible, always-on (CFO-003)")
	print("=".repeat(48))

	_test_core_rule_5_default_visible_on_entry()
	_test_core_rule_5_multiple_walled_off_no_merge()
	_test_core_rule_5_reachable_equipment_no_icon()
	_test_ac12_toggle_independence()
	_test_ac2_flip_false_fade_in_once_then_static()
	_test_ac2_fade_terminal_no_loop_pulse()
	_test_reachable_true_removes_icon()
	_test_equipment_removed_icon_same_frame()
	_test_quiet_ticks_no_strobe()
	_test_flag_absence_machinery_off_no_icons()
	_test_camera_zoom_fixed_ui_scale()
	_test_hover_tooltip_state()
	_test_ac8_no_audio_no_flash_structural()
	_test_reconfigure_idempotent_no_duplicate_connections()

	print("\n=== ACCESS-BLOCKED LAYER TEST: %d passed, %d failed ===\n" % [_pass, _fail])
	return {"pass": _pass, "fail": _fail}


func _check(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
		print("  PASS: " + msg)
	else:
		_fail += 1
		print("  FAIL: " + msg)


# === Helpers (mirror tests/unit/congestion/access_reachable_test.gd) ===

func _GS() -> Script:
	return load("res://src/systems/grid_system.gd") as Script


func _MS() -> Script:
	return load("res://src/systems/member_sim.gd") as Script


func _SRG() -> Script:
	return load("res://src/systems/seeded_rng.gd") as Script


func _NAV() -> Script:
	return load("res://src/systems/navigation.gd") as Script


func _LAYER() -> Script:
	return load(LAYER_SCRIPT_PATH) as Script


func _make_orchestrator() -> Node:
	var orch: Node = load("res://src/systems/simulation_orchestrator.gd").new()
	root.add_child(orch)
	orch.call("_ready")
	return orch


## Real GridSystem: 10x8 all buildable, frozen, with the given equipment
## committed. Each entry: {id, fp: Vector2i|Array, ac: Vector2i}.
## NOTE: ids 1+ are the test equipment; the WALL is committed separately by
## the tests that need it (id 2, row y=1 full width, access cell on row 0 so
## the wall itself stays reachable).
func _make_grid(equipment: Array) -> RefCounted:
	var gs: RefCounted = _GS().new()
	gs.call("init", GRID_W, GRID_H)
	for y in GRID_H:
		for x in GRID_W:
			gs.call("set_buildable", Vector2i(x, y), true)
	gs.call("freeze_buildable")
	for eq in equipment:
		_commit(gs, int(eq["id"]), eq["fp"], eq["ac"])
	return gs


func _commit(gs: RefCounted, id: int, fp: Variant, ac: Vector2i) -> void:
	# commit() takes typed Array[Vector2i] params — build them explicitly
	# (a bare `[ac]` literal is an untyped Array and would fail the type check).
	var fp_arr: Array[Vector2i] = []
	if fp is Vector2i:
		fp_arr.append(fp)
	else:
		for c in fp:
			fp_arr.append(c)
	var ac_arr: Array[Vector2i] = [ac]
	gs.call("commit", id, fp_arr, ac_arr, R0)


func _clear(gs: RefCounted, id: int) -> void:
	gs.call("clear", id)


## Real MemberSim instance — NOT init'd; congestion only needs its public
## members/reservations vars (empty), the same data shape the configured
## system exposes (precedent: access_reachable_test).
func _make_member_sim() -> RefCounted:
	return _MS().new()


## Real Navigation built on [gs], with _post_init called so its AStarGrid2D
## stays in sync with grid_changed (solidity update on commit/clear).
func _make_real_navigation(gs: RefCounted) -> RefCounted:
	var nav: RefCounted = _NAV().new()
	nav.call("init", gs)
	nav.call("_post_init")
	return nav


## Real Congestion, configured with the real grid + member_sim + navigation +
## entrance_cell (+ _post_init to subscribe grid_changed). Returns the rig.
func _make_congestion(
	gs: RefCounted,
	ms: RefCounted,
	nav: RefCounted = null,
	entrance: Vector2i = ENTRANCE,
	config: Dictionary = {}
) -> Dictionary:
	var srg: RefCounted = _SRG().new()
	srg.call("init", 0xCAFE003)
	var orch := _make_orchestrator()
	var cong: RefCounted = (load("res://src/systems/congestion.gd") as Script).new()
	cong.call("init", orch, srg, gs, ms, config, nav, entrance)
	if gs != null:
		cong.call("_post_init")
	return {"congestion": cong, "seeded_rng": srg, "orchestrator": orch}


## Real AccessBlockedLayer configured against [cong]/[gs]. Added to the root
## so it behaves like an in-scene node; frames never iterate during the
## headless _init run, so fades are driven deterministically via
## _advance_fade() calls.
func _make_layer(cong: RefCounted, gs: RefCounted, config: Dictionary = {}) -> Node2D:
	var layer: Node2D = _LAYER().new()
	root.add_child(layer)
	layer.call("configure", cong, gs, CELL_SIZE, config)
	return layer


## The canonical rig: equipment 1 (below the wall line — walled off when the
## wall is present) + equipment 4 (row 0, always reachable) + the wall id 2
## (row y=1 full width, access cell on row 0). Returns {grid, congestion,
## layer, nav, member_sim}. When [with_wall] is false the wall is omitted.
func _make_rig(with_wall: bool = true) -> Dictionary:
	var equipment: Array = [
		{"id": 1, "fp": Vector2i(2, 2), "ac": Vector2i(3, 2)},
		{"id": 4, "fp": Vector2i(3, 0), "ac": Vector2i(2, 0)},
	]
	var gs := _make_grid(equipment)
	if with_wall:
		var wall_fp: Array[Vector2i] = []
		for x in GRID_W:
			wall_fp.append(Vector2i(x, 1))
		_commit(gs, 2, wall_fp, Vector2i(1, 0))
	var ms := _make_member_sim()
	var nav := _make_real_navigation(gs)
	var cong_rig := _make_congestion(gs, ms, nav)
	var cong: RefCounted = cong_rig["congestion"]
	var layer := _make_layer(cong, gs)
	return {
		"grid": gs, "congestion": cong, "layer": layer, "nav": nav,
		"member_sim": ms,
	}


# === Core Rule 5 (load-bearing): default-visible on entry ===

func _test_core_rule_5_default_visible_on_entry() -> void:
	print("\n[CORE RULE 5] scene loads with already-unreachable equipment -> icon materializes immediately (no event gate)")
	var rig := _make_rig(true)
	var layer: Node2D = rig["layer"]
	var icons: Dictionary = layer.get("icons")

	_check(icons.has(1), "CR5: equipment 1 (walled off at load) has an icon immediately after configure()")
	var e1: Dictionary = icons.get(1, {})
	_check(e1["state"] == "static", "CR5: on-entry icon is STATIC (default-visible — no fade-in-on-false trigger)")
	_check(is_equal_approx(float(e1["alpha"]), 1.0), "CR5: on-entry icon is at full alpha (visible now, not fading)")
	_check(Vector2i(e1["cell"]) == Vector2i(3, 2), "CR5: icon anchored at equipment 1's FIRST access cell")

	# No event gate: not a single congestion tick has run — the icon exists
	# purely from configure() reading the current access_reachable set.
	var cong: RefCounted = rig["congestion"]
	_check(int(cong.get("counter")) == 0, "CR5: zero ticks elapsed — icons came from the set read, not from any event")


func _test_core_rule_5_multiple_walled_off_no_merge() -> void:
	print("\n[CORE RULE 5 edge] multiple walled-off machines -> each own icon, never merged/count-alarmed")
	var equipment: Array = [
		{"id": 1, "fp": Vector2i(2, 2), "ac": Vector2i(3, 2)},
		{"id": 3, "fp": Vector2i(5, 2), "ac": Vector2i(6, 2)},
	]
	var gs := _make_grid(equipment)
	var wall_fp: Array[Vector2i] = []
	for x in GRID_W:
		wall_fp.append(Vector2i(x, 1))
	_commit(gs, 2, wall_fp, Vector2i(1, 0))
	var ms := _make_member_sim()
	var nav := _make_real_navigation(gs)
	var cong: RefCounted = _make_congestion(gs, ms, nav)["congestion"]
	var layer := _make_layer(cong, gs)

	var icons: Dictionary = layer.get("icons")
	_check(icons.size() == 2, "CR5-edge: exactly 2 icons for 2 walled-off machines (got %d)" % icons.size())
	_check(icons.has(1) and icons.has(3), "CR5-edge: icons keyed by instance_id — one per machine")
	var p1: Vector2 = icons.get(1, {}).get("pos", Vector2.ZERO)
	var p3: Vector2 = icons.get(3, {}).get("pos", Vector2.ZERO)
	_check(p1 != p3, "CR5-edge: icons anchored at distinct access cells, never merged")
	_check(not icons.has("count") and not icons.has("total"),
		"CR5-edge: no aggregate 'N blocked' entry exists (Pillar 2 — no alarm)")


func _test_core_rule_5_reachable_equipment_no_icon() -> void:
	print("\n[CORE RULE 5 edge] reachable equipment (flag present & true) -> no icon")
	var rig := _make_rig(true)
	var layer: Node2D = rig["layer"]
	var icons: Dictionary = layer.get("icons")
	_check(not icons.has(4), "CR5-edge: reachable equipment 4 (row 0) has NO barricade icon")
	_check(bool(rig["congestion"].call("is_access_reachable", 4)) == true,
		"CR5-edge: baseline — congestion confirms equipment 4 IS reachable")


# === AC12: always-on layer independent of the heatmap toggle ===

func _test_ac12_toggle_independence() -> void:
	print("\n[AC12] access_reachable false + heatmap toggle OFF -> barricade icon still visible (toggle-independent)")
	var rig := _make_rig(true)
	var layer: Node2D = rig["layer"]
	var version_before: int = int(layer.get("set_version"))

	layer.call("set_heatmap_enabled", false)
	var icons: Dictionary = layer.get("icons")
	_check(icons.has(1), "AC12: icon present while heatmap toggle is OFF")
	_check(int(layer.get("set_version")) == version_before,
		"AC12: toggling OFF never mutates the icon set (version unchanged)")

	layer.call("set_heatmap_enabled", true)
	icons = layer.get("icons")
	_check(icons.has(1), "AC12 edge: toggling ON mid-render leaves the icon unaffected")
	var e1: Dictionary = icons.get(1, {})
	_check(e1["state"] == "static" and is_equal_approx(float(e1["alpha"]), 1.0),
		"AC12 edge: icon stays static/full — the toggle never dims or hides it")
	_check(int(layer.get("set_version")) == version_before,
		"AC12 edge: toggle ON also leaves the icon set untouched")


# === AC2: event flip appears (single fade-in, then static) ===

func _test_ac2_flip_false_fade_in_once_then_static() -> void:
	print("\n[AC2] heatmap off + access_reachable flips false -> icon fades in ONCE then holds static")
	var rig := _make_rig(false)  # no wall yet — equipment 1 reachable
	var layer: Node2D = rig["layer"]
	var gs: RefCounted = rig["grid"]
	var cong: RefCounted = rig["congestion"]
	var version_before: int = int(layer.get("set_version"))

	_check(not (layer.get("icons") as Dictionary).has(1),
		"AC2: before the flip, equipment 1 (reachable) has no icon")
	var icons_before: Dictionary = layer.get("icons")

	# The wall severs the path -> grid_changed -> Congestion batch-recomputes
	# at the next tick -> S8 -> the layer reconciles the icon in.
	var wall_fp: Array[Vector2i] = []
	for x in GRID_W:
		wall_fp.append(Vector2i(x, 1))
	_commit(gs, 2, wall_fp, Vector2i(1, 0))
	cong.call("on_tick", 1)

	var icons: Dictionary = layer.get("icons")
	_check(icons.has(1), "AC2: after the flip is processed, the barricade icon appears")
	_check(icons[1]["state"] == "fading_in", "AC2: post-entry false transition starts as a single fade-in")
	_check(is_equal_approx(float(icons[1]["alpha"]), 0.0), "AC2: fade-in begins at alpha 0")
	_check(int(layer.get("set_version")) == version_before + 1,
		"AC2: exactly one set mutation for the flip (version +1)")

	# Drive the fade to completion deterministically (headless: no frames
	# iterate during _init — fade_duration_s default 0.25).
	layer.call("_advance_fade", 0.125)
	icons = layer.get("icons")
	_check(is_equal_approx(float(icons[1]["alpha"]), 0.5), "AC2: mid-fade alpha 0.5 after half the duration")
	_check(icons[1]["state"] == "fading_in", "AC2: still fading at alpha 0.5")
	layer.call("_advance_fade", 0.125)
	icons = layer.get("icons")
	_check(is_equal_approx(float(icons[1]["alpha"]), 1.0) and icons[1]["state"] == "static",
		"AC2: fade completes to STATIC at full alpha — then holds")


func _test_ac2_fade_terminal_no_loop_pulse() -> void:
	print("\n[AC2 edge / AC8] fade state machine is TERMINAL — extra time never re-fades, no loop pulse")
	var rig := _make_rig(false)
	var layer: Node2D = rig["layer"]
	var gs: RefCounted = rig["grid"]
	var cong: RefCounted = rig["congestion"]

	var wall_fp: Array[Vector2i] = []
	for x in GRID_W:
		wall_fp.append(Vector2i(x, 1))
	_commit(gs, 2, wall_fp, Vector2i(1, 0))
	cong.call("on_tick", 1)
	layer.call("_advance_fade", 0.25)  # complete the one-time fade
	var icons: Dictionary = layer.get("icons")
	_check(icons[1]["state"] == "static" and is_equal_approx(float(icons[1]["alpha"]), 1.0),
		"AC8: after one fade, icon is static at full alpha")
	var version_after_fade: int = int(layer.get("set_version"))

	# 9 more seconds of simulated time — a pulse/loop would re-enter fading
	# and re-bump the version; the terminal state must not.
	for i in 36:
		layer.call("_advance_fade", 0.25)
	icons = layer.get("icons")
	_check(icons[1]["state"] == "static", "AC8: 9s later the icon is STILL static (no loop pulse)")
	_check(is_equal_approx(float(icons[1]["alpha"]), 1.0), "AC8: 9s later alpha still 1.0 (no flash)")
	_check(int(layer.get("set_version")) == version_after_fade,
		"AC8: no set mutations across the whole observation window (no strobe)")


# === Dynamics: removal paths ===

func _test_reachable_true_removes_icon() -> void:
	print("\n[DYN] access_reachable -> true -> icon removed (S8 reconcile after the recompute tick)")
	var rig := _make_rig(true)
	var layer: Node2D = rig["layer"]
	var gs: RefCounted = rig["grid"]
	var cong: RefCounted = rig["congestion"]
	_check((layer.get("icons") as Dictionary).has(1), "DYN: baseline — walled-off icon present")

	var version_before: int = int(layer.get("set_version"))
	_clear(gs, 2)  # remove the wall -> grid_changed
	cong.call("on_tick", 2)  # recompute flips equipment 1 reachable -> S8

	var icons: Dictionary = layer.get("icons")
	_check(not icons.has(1), "DYN: after the true-flip is processed, the icon is removed")
	_check(int(layer.get("set_version")) == version_before + 1,
		"DYN: exactly one set mutation for the removal (version +1)")


func _test_equipment_removed_icon_same_frame() -> void:
	print("\n[DYN] equipment removed while icon showing -> icon removed SAME FRAME (grid_changed handler, zero ticks)")
	var rig := _make_rig(true)
	var layer: Node2D = rig["layer"]
	var gs: RefCounted = rig["grid"]
	var cong: RefCounted = rig["congestion"]
	_check((layer.get("icons") as Dictionary).has(1), "DYN-edge: baseline — walled-off icon present")

	var version_before: int = int(layer.get("set_version"))
	_clear(gs, 1)  # remove equipment 1 itself -> grid_changed fires
	var icons: Dictionary = layer.get("icons")
	_check(not icons.has(1), "DYN-edge: icon gone immediately after clear() — BEFORE any congestion tick")
	_check(int(cong.get("counter")) == 0, "DYN-edge: zero ticks elapsed — removal was event-driven, not tick-driven")
	_check(int(layer.get("set_version")) == version_before + 1,
		"DYN-edge: one set mutation for the same-frame removal")


# === Flicker protection: quiet ticks ===

func _test_quiet_ticks_no_strobe() -> void:
	print("\n[AC8 edge] quiet ticks (no grid change) -> icon set untouched, no strobe within a stable layout")
	var rig := _make_rig(true)
	var layer: Node2D = rig["layer"]
	var cong: RefCounted = rig["congestion"]
	var version_before: int = int(layer.get("set_version"))

	cong.call("on_tick", 0)
	cong.call("on_tick", 1)
	var icons: Dictionary = layer.get("icons")
	_check(icons.size() == 1 and icons.has(1), "AC8-edge: icon set identical after two quiet ticks")
	_check(icons[1]["state"] == "static", "AC8-edge: still static (no re-fade on quiet ticks)")
	_check(int(layer.get("set_version")) == version_before,
		"AC8-edge: zero set mutations across quiet ticks (reconcile is idempotent — event-driven, never per-tick strobe)")


# === Flag-absence semantics ===

func _test_flag_absence_machinery_off_no_icons() -> void:
	print("\n[FLAG] reachability machinery off (no navigation) -> ZERO icons — absence never reads as walled-off")
	var equipment: Array = [{"id": 1, "fp": Vector2i(2, 2), "ac": Vector2i(3, 2)}]
	var gs := _make_grid(equipment)
	var ms := _make_member_sim()
	# Congestion WITHOUT navigation/entrance: access_reachable stays empty.
	var cong: RefCounted = _make_congestion(gs, ms, null, Vector2i(-1, -1))["congestion"]
	var layer := _make_layer(cong, gs)

	_check((cong.get("access_reachable") as Dictionary).is_empty(),
		"FLAG: congestion reports an empty access_reachable set (machinery off)")
	_check((layer.get("icons") as Dictionary).is_empty(),
		"FLAG: layer shows NO icons — flag absence never misreports every machine as walled off")
	_check(not (layer.get("icons") as Dictionary).has(999),
		"FLAG: never-seen id 999 has no icon")


# === Fixed UI-layer scale ===

func _test_camera_zoom_fixed_ui_scale() -> void:
	print("\n[ZOOM] camera zoom changes -> glyph draw size inverse-scaled (fixed UI layer), anchor positions never move")
	var rig := _make_rig(true)
	var layer: Node2D = rig["layer"]
	var icons: Dictionary = layer.get("icons")
	var pos_before: Vector2 = icons[1]["pos"]

	_check(is_equal_approx(float(layer.call("glyph_scale")), 1.0),
		"ZOOM: default zoom 1.0 -> glyph scale 1.0")
	layer.call("set_camera_zoom", 2.0)
	_check(is_equal_approx(float(layer.call("glyph_scale")), 0.5),
		"ZOOM: zoom 2.0 -> glyph drawn at 0.5x world size (constant on screen)")
	layer.call("set_camera_zoom", 0.5)
	_check(is_equal_approx(float(layer.call("glyph_scale")), 2.0),
		"ZOOM: zoom 0.5 -> glyph drawn at 2.0x world size")
	icons = layer.get("icons")
	_check(Vector2(icons[1]["pos"]) == pos_before,
		"ZOOM: icon ANCHOR (access-cell world position) never moves with zoom")
	layer.call("set_camera_zoom", 0.0)
	_check(is_equal_approx(float(layer.call("glyph_scale")), 2.0),
		"ZOOM: non-positive zoom rejected — scale unchanged")


# === Hover tooltip ===

func _test_hover_tooltip_state() -> void:
	print("\n[TOOLTIP] one-line hover tooltip state machine + fixed copy")
	var rig := _make_rig(true)
	var layer: Node2D = rig["layer"]
	var icons: Dictionary = layer.get("icons")
	var pos: Vector2 = icons[1]["pos"]

	layer.call("notify_pointer_world_position", pos)
	_check(bool(layer.get("tooltip_visible")) == true, "TOOLTIP: pointer on glyph -> tooltip visible")
	_check(int(layer.get("tooltip_instance_id")) == 1, "TOOLTIP: tooltip targets the hovered instance")
	# Constants are not Object properties — read via the script constant map.
	var layer_consts: Dictionary = (_LAYER() as GDScript).get_script_constant_map()
	_check(layer_consts.get("TOOLTIP_TEXT") == "Can't be reached — check for a blocked path",
		"TOOLTIP: copy is the fixed one-liner — never ERROR/exclamation")

	layer.call("notify_pointer_world_position", pos + Vector2(500, 500))
	_check(bool(layer.get("tooltip_visible")) == false, "TOOLTIP: pointer leaves glyph -> tooltip hidden")
	_check(int(layer.get("tooltip_instance_id")) == -1, "TOOLTIP: hidden state clears the target id")


# === AC8 structural: silence ===

func _test_ac8_no_audio_no_flash_structural() -> void:
	print("\n[AC8] structural — the layer has no audio path (silence, Pillar 2)")
	var source: String = FileAccess.get_file_as_string(LAYER_SCRIPT_PATH)
	_check(not source.contains("AudioStream"), "AC8: layer source contains no AudioStream reference (no failure sound)")
	_check(not source.contains(".play("), "AC8: layer source contains no audio play() call")
	_check(not source.contains("create_tween") and not source.contains("Timer"),
		"AC8: layer source contains no repeating animation machinery (a loop pulse would need a tween/timer)")


# === Reconfigure idempotency ===

func _test_reconfigure_idempotent_no_duplicate_connections() -> void:
	print("\n[RECONF] configure() twice -> no duplicate typed signal connections, icons rebuilt correctly")
	var rig := _make_rig(true)
	var layer: Node2D = rig["layer"]
	var cong: RefCounted = rig["congestion"]
	var gs: RefCounted = rig["grid"]

	layer.call("configure", cong, gs, CELL_SIZE, {})
	var icons: Dictionary = layer.get("icons")
	_check(icons.has(1) and icons.size() == 1,
		"RECONF: after re-configure the icon set is rebuilt correctly (1 walled-off machine)")

	var s8_count := 0
	for conn in cong.get("congestion_updated").get_connections():
		var cb: Callable = conn["callable"]
		if cb.get_object() == layer and cb.get_method() == "_on_congestion_updated":
			s8_count += 1
	_check(s8_count == 1, "RECONF: congestion_updated has exactly ONE connection to the layer (got %d)" % s8_count)

	var s1_count := 0
	for conn in gs.get("grid_changed").get_connections():
		var cb: Callable = conn["callable"]
		if cb.get_object() == layer and cb.get_method() == "_on_grid_changed":
			s1_count += 1
	_check(s1_count == 1, "RECONF: grid_changed has exactly ONE connection to the layer (got %d)" % s1_count)

	# A quiet tick after reconfigure: idempotent reconcile, no extra mutation.
	var version_before: int = int(layer.get("set_version"))
	cong.call("on_tick", 5)
	_check(int(layer.get("set_version")) == version_before,
		"RECONF: quiet tick after reconfigure leaves the set untouched (single connection, single reconcile)")
