# tests/unit/selection_system/selection_cue_test.gd
# Story SEL-004: Contextual Toolbar & Selection Cue
# (production/epics/selection-system/story-004-contextual-toolbar-selection-cue.md)
#
# Covers the BLOCKING ACs for the cue half (Core Rule 2 / AC8):
#   Core Rule 2 — when a piece is selected the cue shows:
#       - a Soft Charcoal 2px outline around the selected footprint cells
#       - a subtle glow in the piece's own tint
#       - a small "selected" corner icon
#       - at most ONE slow ~1.5s breathe cycle — no harsh flash
#   AC8 — colorblind: the selection state is legible from outline shape +
#         icon alone with color desaturated (the outline color is fixed
#         Soft Charcoal and the corner icon is a shape glyph — NO state is
#         carried by color alone)
#   UX spec Reduced motion — reduced-motion ON: cue static (no breathe)
#   UX spec Transitions — swap moves the cue directly (no flicker);
#   deselect hides it
#
# Headless tests assert STATE (visible / rect / colors / breathe config),
# never pixels — the _draw() rendering is the thin draw of that state.
#
# Run standalone: godot --headless --script tests/unit/selection_system/selection_cue_test.gd
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"

const CUE_SCRIPT := "res://src/ui/selection_cue.gd"
const SEL_SCRIPT := "res://src/systems/selection_system.gd"
const PLACEMENT_SCRIPT := "res://src/systems/placement_system.gd"
const GRID_SCRIPT := "res://src/systems/grid_system.gd"
const CATALOG_SCRIPT := "res://src/systems/equipment_catalog.gd"
const DEF_SCRIPT := "res://src/systems/equipment_def.gd"

const CELL_SIZE := 32

const NO_ARG := "<NO_ARG>"

var _pass := 0
var _fail := 0
var _nodes_to_free: Array = []


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
	print("  UNIT TEST: SelectionCue — Selection Cue State (SEL-004)")
	print("=".repeat(48))

	_test_hidden_with_no_selection()
	_test_visible_when_selected()
	_test_outline_soft_charcoal()
	_test_footprint_rect_correct()
	_test_glow_tint_from_zone()
	_test_glow_tint_fallback_warm()
	_test_corner_icon_present()
	_test_breathe_single_cycle_config()
	_test_reduced_motion_static()
	_test_deselect_hides_cue()
	_test_swap_moves_cue_directly()
	_test_double_init_guard()

	_free_test_nodes()

	print("\n=== SEL-004 Selection Cue: %d passed, %d failed ===\n" % [_pass, _fail])
	return {"pass": _pass, "fail": _fail}


func _check(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
		print("  PASS: " + msg)
	else:
		_fail += 1
		print("  FAIL: " + msg)


# === World builders (real systems) ===

func _ED() -> Script:
	return load(DEF_SCRIPT) as Script


func _make_def(cost: int, zone: String = "cardio") -> RefCounted:
	var ED := _ED()
	var footprint: Array[Vector2i] = [Vector2i(0, 0)]
	var access: Array[Vector2i] = [Vector2i(1, 0)]
	var effects: Array[Dictionary] = []
	return ED.new(
		"piece_%d" % cost,
		"Test %d" % cost,
		[zone],
		footprint,
		access,
		cost,
		"",
		effects,
		200,
		30,
		100,
		300,
	)


func _make_catalog(defs: Array) -> RefCounted:
	var cat: RefCounted = (load(CATALOG_SCRIPT) as Script).new()
	for d in defs:
		cat.call("_add_definition", d)
	cat.call("_freeze")
	return cat


func _make_grid(width: int, height: int) -> RefCounted:
	var gs: RefCounted = (load(GRID_SCRIPT) as Script).new()
	gs.call("init", width, height)
	for y in height:
		for x in width:
			gs.call("set_buildable", Vector2i(x, y), true)
	gs.call("freeze_buildable")
	return gs


func _make_placement(grid: RefCounted, catalog: RefCounted) -> RefCounted:
	var ps: RefCounted = (load(PLACEMENT_SCRIPT) as Script).new()
	ps.call("init", grid, catalog)
	return ps


func _make_selection(grid: RefCounted, placement: RefCounted, catalog: RefCounted) -> RefCounted:
	var sel: RefCounted = (load(SEL_SCRIPT) as Script).new()
	sel.call("init", grid, placement, catalog)
	sel.call("_post_init")
	return sel


## The SelectionCue Control, added to the tree (so tweens/visibility behave
## like runtime) and init'd with the rig.
func _make_cue(sel: RefCounted, grid: RefCounted, config: Dictionary = {}):
	var cue = (load(CUE_SCRIPT) as Script).new()
	root.add_child(cue)
	cue.call("init", sel, grid, CELL_SIZE, config, Vector2.ZERO)
	_nodes_to_free.append(cue)
	return cue


func _place(ps: RefCounted, equipment_id: String, anchor: Vector2i) -> int:
	var id_before: int = ps.call("get_next_instance_id")
	ps.call("begin_drag", equipment_id)
	ps.call("on_mouse_moved", anchor)
	ps.call("on_drop")
	return id_before


func _make_world(costs: Array, zone: String = "cardio", config: Dictionary = {}) -> Dictionary:
	var defs: Array = []
	for c in costs:
		defs.append(_make_def(int(c), zone))
	var grid := _make_grid(12, 10)
	var catalog := _make_catalog(defs)
	var placement := _make_placement(grid, catalog)
	var selection := _make_selection(grid, placement, catalog)
	var cue = _make_cue(selection, grid, config)
	return {
		"grid": grid, "catalog": catalog, "placement": placement,
		"selection": selection, "cue": cue,
	}


func _free_test_nodes() -> void:
	for n in _nodes_to_free:
		if is_instance_valid(n):
			n.free()
	_nodes_to_free.clear()


# === Visibility / geometry ===

func _test_hidden_with_no_selection() -> void:
	print("\n[visibility] cue hidden with no selection")
	var w := _make_world([200])
	var cue = w["cue"]
	_check(not bool(cue.call("is_cue_active")), "visibility — cue not active before any selection")
	_check(not cue.visible, "visibility — Control.visible == false")


func _test_visible_when_selected() -> void:
	print("\n[Core Rule 2] selecting a piece shows the cue")
	var w := _make_world([200])
	var placement: RefCounted = w["placement"]
	var selection: RefCounted = w["selection"]
	var cue = w["cue"]

	_place(placement, "piece_200", Vector2i(3, 3))
	selection.call("on_cell_clicked", Vector2i(3, 3))
	_check(bool(cue.call("is_cue_active")), "Core Rule 2 — cue active after selection")
	_check(cue.visible, "Core Rule 2 — Control.visible == true")


func _test_outline_soft_charcoal() -> void:
	print("\n[Core Rule 2 / AC8] outline is Soft Charcoal #3C3A42 (fixed, not per-piece)")
	var w := _make_world([200])
	var cue = w["cue"]
	var outline: Color = cue.call("get_outline_color")
	_check(outline.to_html(false).to_lower() == "3c3a42", "Core Rule 2 — outline Soft Charcoal (got #%s)" % outline.to_html(false))


func _test_footprint_rect_correct() -> void:
	print("\n[Core Rule 2] cue rect covers the selected footprint cells (grid → pixel)")
	var w := _make_world([200])
	var placement: RefCounted = w["placement"]
	var selection: RefCounted = w["selection"]
	var cue = w["cue"]

	# Piece at (3,3), 1×1 cell, cell_size 32 → pixel rect x:[96,128) y:[96,128).
	_place(placement, "piece_200", Vector2i(3, 3))
	selection.call("on_cell_clicked", Vector2i(3, 3))
	var fp: Rect2 = cue.call("get_footprint_rect")
	_check(int(fp.position.x) == 96 and int(fp.position.y) == 96, "Core Rule 2 — rect at (96,96), got %s" % str(fp.position))
	_check(int(fp.size.x) == 32 and int(fp.size.y) == 32, "Core Rule 2 — rect size 32×32, got %s" % str(fp.size))


func _test_glow_tint_from_zone() -> void:
	print("\n[glow] cardio zone → Sky tint (art-bible semantic color)")
	var w := _make_world([200], "cardio")
	var placement: RefCounted = w["placement"]
	var selection: RefCounted = w["selection"]
	var cue = w["cue"]

	_place(placement, "piece_200", Vector2i(3, 3))
	selection.call("on_cell_clicked", Vector2i(3, 3))
	var tint: Color = cue.call("get_tint")
	_check(tint.to_html(false).to_lower() == "8ec5e8", "glow — cardio tint Sky #8EC5E8 (got #%s)" % tint.to_html(false))


func _test_glow_tint_fallback_warm() -> void:
	print("\n[glow] strength zone → Sage tint; unknown zone → warm-neutral fallback")
	var w := _make_world([200], "strength")
	var placement: RefCounted = w["placement"]
	var selection: RefCounted = w["selection"]
	var cue = w["cue"]

	_place(placement, "piece_200", Vector2i(3, 3))
	selection.call("on_cell_clicked", Vector2i(3, 3))
	var sage: Color = cue.call("get_tint")
	_check(sage.to_html(false).to_lower() == "8fbf9f", "glow — strength tint Sage #8FBF9F (got #%s)" % sage.to_html(false))

	# Unknown zone → warm-neutral fallback (never a color alone carrying
	# state — AC8: outline shape + icon carry the selection).
	var w2 := _make_world([200], "mystery_zone")
	var placement2: RefCounted = w2["placement"]
	var selection2: RefCounted = w2["selection"]
	var cue2 = w2["cue"]
	_place(placement2, "piece_200", Vector2i(2, 2))
	selection2.call("on_cell_clicked", Vector2i(2, 2))
	var warm: Color = cue2.call("get_tint")
	_check(warm.to_html(false).to_lower() == "c9a87c", "glow — unknown zone fallback warm-neutral #C9A87C (got #%s)" % warm.to_html(false))


func _test_corner_icon_present() -> void:
	print("\n[AC8] the corner 'selected' icon is a SHAPE glyph (colorblind-safe, never color alone)")
	var w := _make_world([200])
	var placement: RefCounted = w["placement"]
	var selection: RefCounted = w["selection"]
	var cue = w["cue"]

	_place(placement, "piece_200", Vector2i(3, 3))
	selection.call("on_cell_clicked", Vector2i(3, 3))
	# The icon is a fixed glyph constant in Soft Charcoal — the same color as
	# the outline. State is carried by SHAPE, not color (AC8).
	var icon: String = cue.get("CORNER_ICON_GLYPH")
	_check(icon != "" and icon != " ", "AC8 — corner icon glyph is a visible shape ('%s')" % icon)
	_check(cue.get("CORNER_ICON_SIZE") >= 8, "AC8 — corner icon is legibly sized (%d)" % int(cue.get("CORNER_ICON_SIZE")))
	_check(cue.get("CORNER_ICON_SIZE") <= 16, "AC8 — corner icon stays small (not dominating the cue)")


func _test_breathe_single_cycle_config() -> void:
	print("\n[Core Rule 2] breathe is ONE slow ~1.5s cycle, no harsh flash")
	var w := _make_world([200])
	var placement: RefCounted = w["placement"]
	var selection: RefCounted = w["selection"]
	var cue = w["cue"]

	_place(placement, "piece_200", Vector2i(3, 3))
	selection.call("on_cell_clicked", Vector2i(3, 3))
	_check(bool(cue.call("is_breathe_active")), "breathe — tween running after selection")
	var dur: float = cue.call("get_breathe_duration")
	_check(dur >= 1.2 and dur <= 2.0, "breathe — duration in the GDD safe range 1.2–2.0s (got %.2f)" % dur)
	# Config override is honored and clamped.
	var w2 := _make_world([200], "cardio", {"cue_breathe_duration": 0.1})
	var cue2 = w2["cue"]
	var clamped: float = cue2.call("get_breathe_duration")
	_check(clamped == 1.2, "breathe — 0.1 config clamped to the 1.2s min (got %.2f)" % clamped)


func _test_reduced_motion_static() -> void:
	print("\n[reduced-motion] cue static (no breathe) when reduced_motion is ON")
	var w := _make_world([200], "cardio", {"reduced_motion": true})
	var placement: RefCounted = w["placement"]
	var selection: RefCounted = w["selection"]
	var cue = w["cue"]

	_check(bool(cue.call("is_reduced_motion")), "reduced-motion — config applied")
	_place(placement, "piece_200", Vector2i(3, 3))
	selection.call("on_cell_clicked", Vector2i(3, 3))
	_check(bool(cue.call("is_cue_active")), "reduced-motion — cue still visible")
	_check(not bool(cue.call("is_breathe_active")), "reduced-motion — NO breathe tween (static)")


func _test_deselect_hides_cue() -> void:
	print("\n[deselect] Esc hides the cue")
	var w := _make_world([200])
	var placement: RefCounted = w["placement"]
	var selection: RefCounted = w["selection"]
	var cue = w["cue"]

	_place(placement, "piece_200", Vector2i(3, 3))
	selection.call("on_cell_clicked", Vector2i(3, 3))
	_check(bool(cue.call("is_cue_active")), "deselect — setup: active")
	selection.call("on_esc_pressed")
	_check(not bool(cue.call("is_cue_active")), "deselect — hidden after Esc")
	_check(not bool(cue.call("is_breathe_active")), "deselect — breathe tween killed")


func _test_swap_moves_cue_directly() -> void:
	print("\n[swap] clicking a different piece moves the cue directly (no flicker)")
	var w := _make_world([200, 350])
	var placement: RefCounted = w["placement"]
	var selection: RefCounted = w["selection"]
	var cue = w["cue"]

	_place(placement, "piece_200", Vector2i(2, 2))
	_place(placement, "piece_350", Vector2i(6, 6))
	selection.call("on_cell_clicked", Vector2i(2, 2))
	_check(bool(cue.call("is_cue_active")), "swap — first selection active")
	var fp1: Rect2 = cue.call("get_footprint_rect")
	_check(int(fp1.position.x) == 64, "swap — first rect at x 64 (got %s)" % str(fp1.position.x))
	selection.call("on_cell_clicked", Vector2i(6, 6))  # direct swap
	_check(bool(cue.call("is_cue_active")), "swap — cue stays active through the swap")
	var fp2: Rect2 = cue.call("get_footprint_rect")
	_check(int(fp2.position.x) == 192, "swap — rect moved to x 192 (got %s)" % str(fp2.position.x))


func _test_double_init_guard() -> void:
	print("\n[guard] init() twice → loud no-op")
	var w := _make_world([200])
	var cue = w["cue"]
	cue.call("init", w["selection"], w["grid"], CELL_SIZE)
	var placement: RefCounted = w["placement"]
	var selection: RefCounted = w["selection"]
	_place(placement, "piece_200", Vector2i(4, 4))
	selection.call("on_cell_clicked", Vector2i(4, 4))
	_check(bool(cue.call("is_cue_active")), "guard — double init leaves the first wiring intact")
