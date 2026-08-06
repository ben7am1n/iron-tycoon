# tests/unit/selection_system/selection_logic_test.gd
# Story SEL-001: Selection Logic Core + Instance Mapping
# (production/epics/selection-system/story-001-selection-logic-core.md)
#
# Covers the BLOCKING ACs:
#   AC1   — click a placed instance → selection resolves + selection_changed
#           (instance_id, def, cell, rotation) fires with the correct payload
#   AC2   — click empty BUILDABLE floor → deselect + selection_changed(null);
#           edge: click NON-buildable floor → no deselect
#   AC9   — click a different placed piece → DIRECT swap, no intermediate
#           deselect emission
#   AC10  — click the already-selected piece → no-op (no signal, selection
#           stays; NOT a toggle-off)
#   AC11  — selected piece removed externally → selection clears +
#           selection_changed(null); removal of a NON-selected piece → no
#           signal, selection untouched
#   AC12  — PlacementSystem is_dragging() true → click does not resolve
# plus Core Rule 1 (Esc deselect logic), TR-SEL-005 (instance mapping via
# placement_committed + grid_changed, rotation/anchor derivation), and the
# signal arity contract (TR-SEL-004 / ADR-0005 S7: 4 args on select, exactly
# ONE null arg on deselect — GDScript dispatches exactly the args passed to
# emit(); the spy proves the arity by sentinel defaults).
#
# Run standalone: godot --headless --script tests/unit/selection_system/selection_logic_test.gd
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"

const SEL_SCRIPT := "res://src/systems/selection_system.gd"
const PLACEMENT_SCRIPT := "res://src/systems/placement_system.gd"
const GRID_SCRIPT := "res://src/systems/grid_system.gd"
const CATALOG_SCRIPT := "res://src/systems/equipment_catalog.gd"
const DEF_SCRIPT := "res://src/systems/equipment_def.gd"

## Sentinel distinguishing "argument not passed" from a real null — the
## deselect emit passes exactly ONE argument, so b/c/d keep this value.
const NO_ARG := "<NO_ARG>"

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
	print("  UNIT TEST: SelectionSystem — Selection Logic Core (SEL-001)")
	print("=".repeat(48))

	_test_ac1_click_selects_and_emits_payload()
	_test_ac1_any_footprint_cell_selects()
	_test_ac1_gap_cell_no_resolution_when_nothing_selected()
	_test_ac2_click_empty_buildable_deselects()
	_test_ac2_click_non_buildable_no_deselect()
	_test_ac2_click_empty_floor_with_no_selection_no_signal()
	_test_ac9_direct_swap_no_intermediate_deselect()
	_test_ac10_reclick_selected_noop()
	_test_ac11_external_removal_clears_selection()
	_test_ac11_removal_of_unselected_piece_no_signal()
	_test_ac12_drag_suppresses_resolution()
	_test_core_rule_1_esc_deselects()
	_test_mapping_rotation_derived_r90()
	_test_mapping_rotation_derived_r180()
	_test_mapping_relocate_recommit_updates_entry()
	_test_signal_arity_select_four_args()
	_test_signal_arity_deselect_one_null_arg()
	_test_mapping_missing_entry_loud_noop()
	_test_use_before_init_guard()

	print("\n=== SEL-001 Selection Logic Core: %d passed, %d failed ===\n" % [_pass, _fail])
	return {"pass": _pass, "fail": _fail}


func _check(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
		print("  PASS: " + msg)
	else:
		_fail += 1
		print("  FAIL: " + msg)


# === Helpers ===

## Spy on selection_changed. Records each emission as an args array; the
## four params ALL have sentinel defaults so the handler accepts 1..4 args
## (GDScript dispatches exactly the emitted count — a 1-arg deselect emit
## leaves b/c/d at the sentinel, proving the arity).
class SelectionSpy:
	extends RefCounted
	var emissions: Array = []  # each: [a, b, c, d]

	func _on_selection_changed(a = NO_ARG, b = NO_ARG, c = NO_ARG, d = NO_ARG) -> void:
		emissions.append([a, b, c, d])

	func select_count() -> int:
		var n := 0
		for e in emissions:
			if e[0] != null:  # selects always carry a non-null instance_id (0 is legal)
				n += 1
		return n

	func deselect_count() -> int:
		var n := 0
		for e in emissions:
			if e[0] == null:  # deselects pass exactly one null arg
				n += 1
		return n


func _spy_for(sel: RefCounted) -> SelectionSpy:
	var spy := SelectionSpy.new()
	sel.connect("selection_changed", Callable(spy, "_on_selection_changed"))
	return spy


## Open grid (all buildable) with optional non-buildable cells — set before
## freeze_buildable(), matching the level-load lifecycle.
func _make_grid(width: int, height: int, non_buildable: Array[Vector2i] = []) -> RefCounted:
	var GS: Script = load(GRID_SCRIPT) as Script
	var gs: RefCounted = GS.new()
	gs.call("init", width, height)
	for y in height:
		for x in width:
			gs.call("set_buildable", Vector2i(x, y), true)
	for cell in non_buildable:
		gs.call("set_buildable", cell, false)
	gs.call("freeze_buildable")
	return gs


## Canonical treadmill: 1×2 footprint (0,0)-(1,0), access (0,1).
func _make_treadmill_def() -> RefCounted:
	return _make_def("treadmill_01", [Vector2i(0, 0), Vector2i(1, 0)], [Vector2i(0, 1)], 200)


## Canonical yoga mat: 1×1 footprint, access (1,0).
func _make_yoga_def() -> RefCounted:
	return _make_def("yoga_01", [Vector2i(0, 0)], [Vector2i(1, 0)], 200)


## Canonical bench: 2×2 footprint, access (2,1).
func _make_bench_def() -> RefCounted:
	return _make_def(
		"bench_01",
		[Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)],
		[Vector2i(2, 1)],
		350
	)


func _make_def(id: String, fp: Array[Vector2i], ac: Array[Vector2i], cost: int) -> RefCounted:
	var ED: Script = load(DEF_SCRIPT) as Script
	var effects: Array[Dictionary] = []
	var zones: Array = ["力量区"]
	return ED.new(id, "Test %s" % id, zones, fp, ac, cost, "", effects, 200, 30, 100, 300)


func _make_catalog() -> RefCounted:
	var cat: RefCounted = (load(CATALOG_SCRIPT) as Script).new()
	cat.call("_add_definition", _make_treadmill_def())
	cat.call("_add_definition", _make_yoga_def())
	cat.call("_add_definition", _make_bench_def())
	cat.call("_freeze")
	return cat


func _make_placement(grid: RefCounted, catalog: RefCounted) -> RefCounted:
	var ps: RefCounted = (load(PLACEMENT_SCRIPT) as Script).new()
	ps.call("init", grid, catalog)
	return ps


## SelectionSystem wired for the mapping (init + _post_init).
func _make_selection(grid: RefCounted, placement: RefCounted, catalog: RefCounted) -> RefCounted:
	var sel: RefCounted = (load(SEL_SCRIPT) as Script).new()
	sel.call("init", grid, placement, catalog)
	sel.call("_post_init")
	return sel


func _make_world() -> Array:
	var grid := _make_grid(8, 8)
	var catalog := _make_catalog()
	var placement := _make_placement(grid, catalog)
	var selection := _make_selection(grid, placement, catalog)
	return [grid, catalog, placement, selection]


## Places a piece via the REAL PlacementSystem flow (begin_drag → rotate →
## mouse-move preview → drop), returning the allocated instance_id.
func _place(ps: RefCounted, equipment_id: String, anchor: Vector2i, rotate_count: int) -> int:
	var id_before: int = ps.call("get_next_instance_id")
	ps.call("begin_drag", equipment_id)
	for i in rotate_count:
		ps.call("on_rotate_pressed")
	ps.call("on_mouse_moved", anchor)
	ps.call("on_drop")
	return id_before


## Helper: assert the spy received exactly one select emission whose payload
## matches (instance_id, equipment_id, cell, rotation).
func _check_single_select(spy: SelectionSpy, expected_id: int, expected_eq: String, expected_cell: Vector2i, expected_rot: int, label: String) -> void:
	_check(spy.select_count() == 1, "%s — exactly one select emission (got %d)" % [label, spy.select_count()])
	if spy.select_count() != 1:
		return
	var e: Array = spy.emissions[0]
	var def_ok: bool = e[1] != null and e[1].get("id") == expected_eq
	_check(e[0] == expected_id, "%s — payload instance_id == %d (got %s)" % [label, expected_id, str(e[0])])
	_check(def_ok, "%s — payload def id == '%s' (got %s)" % [label, expected_eq, str(e[1].get("id") if e[1] != null else "<null>")])
	_check(e[2] == expected_cell, "%s — payload cell == %s (got %s)" % [label, expected_cell, str(e[2])])
	_check(e[3] == expected_rot, "%s — payload rotation == %d (got %s)" % [label, expected_rot, str(e[3])])


# === AC1: click a placed instance → select ===

func _test_ac1_click_selects_and_emits_payload() -> void:
	print("\n[AC1] click a placed instance → selection resolves + selection_changed fires")
	var parts := _make_world()
	var grid: RefCounted = parts[0]
	var placement: RefCounted = parts[2]
	var selection: RefCounted = parts[3]

	_place(placement, "treadmill_01", Vector2i(1, 1), 0)  # id 0, footprint (1,1)-(2,1)
	var spy := _spy_for(selection)

	selection.call("on_cell_clicked", Vector2i(1, 1))

	_check(selection.call("get_selected_instance_id") == 0, "AC1 — selection resolves to instance 0")
	_check_single_select(spy, 0, "treadmill_01", Vector2i(1, 1), 0, "AC1")


func _test_ac1_any_footprint_cell_selects() -> void:
	print("\n[AC1 edge] clicking ANY footprint cell of a multi-cell piece selects it")
	var parts := _make_world()
	var placement: RefCounted = parts[2]
	var selection: RefCounted = parts[3]

	_place(placement, "treadmill_01", Vector2i(1, 1), 0)  # footprint (1,1)-(2,1)
	var spy := _spy_for(selection)

	selection.call("on_cell_clicked", Vector2i(2, 1))  # second footprint cell

	_check(selection.call("get_selected_instance_id") == 0, "AC1 edge — second footprint cell selects the same instance")
	_check_single_select(spy, 0, "treadmill_01", Vector2i(1, 1), 0, "AC1 edge")


func _test_ac1_gap_cell_no_resolution_when_nothing_selected() -> void:
	print("\n[AC1 edge] click empty floor (access cell) with nothing selected → no resolution, no signal")
	var parts := _make_world()
	var placement: RefCounted = parts[2]
	var selection: RefCounted = parts[3]

	_place(placement, "treadmill_01", Vector2i(1, 1), 0)  # access cell (1,2)
	var spy := _spy_for(selection)

	selection.call("on_cell_clicked", Vector2i(1, 2))  # access cell — empty floor

	_check(selection.call("get_selected_instance_id") == -1, "AC1 edge — no selection resolved")
	_check(spy.emissions.is_empty(), "AC1 edge — no signal fired")


# === AC2: click empty buildable floor → deselect ===

func _test_ac2_click_empty_buildable_deselects() -> void:
	print("\n[AC2] click empty buildable floor → selection clears + selection_changed(null)")
	var parts := _make_world()
	var placement: RefCounted = parts[2]
	var selection: RefCounted = parts[3]

	_place(placement, "treadmill_01", Vector2i(1, 1), 0)
	selection.call("on_cell_clicked", Vector2i(1, 1))
	var spy := _spy_for(selection)

	selection.call("on_cell_clicked", Vector2i(5, 5))  # empty buildable floor

	_check(selection.call("get_selected_instance_id") == -1, "AC2 — selection cleared")
	_check(spy.deselect_count() == 1, "AC2 — selection_changed(null) fired exactly once (got %d)" % spy.deselect_count())


func _test_ac2_click_non_buildable_no_deselect() -> void:
	print("\n[AC2 edge] click NON-buildable floor → NO deselect (only buildable floor deselects)")
	var parts := _make_world()
	var grid: RefCounted = parts[0]
	var placement: RefCounted = parts[2]
	var selection: RefCounted = parts[3]
	# Rebuild with a non-buildable cell — the world helper freezes buildable.
	var gs := _make_grid(8, 8, [Vector2i(7, 7)])
	var cat: RefCounted = parts[1]
	var ps := _make_placement(gs, cat)
	var sel := _make_selection(gs, ps, cat)

	_place(ps, "treadmill_01", Vector2i(1, 1), 0)
	sel.call("on_cell_clicked", Vector2i(1, 1))
	var spy := _spy_for(sel)

	sel.call("on_cell_clicked", Vector2i(7, 7))  # non-buildable floor

	_check(sel.call("get_selected_instance_id") == 0, "AC2 edge — selection NOT cleared by non-buildable click")
	_check(spy.emissions.is_empty(), "AC2 edge — no signal fired")


func _test_ac2_click_empty_floor_with_no_selection_no_signal() -> void:
	print("\n[AC2 edge] click empty floor with NO selection → no-op, no signal")
	var parts := _make_world()
	var selection: RefCounted = parts[3]
	var spy := _spy_for(selection)

	selection.call("on_cell_clicked", Vector2i(5, 5))

	_check(selection.call("get_selected_instance_id") == -1, "AC2 edge — still nothing selected")
	_check(spy.emissions.is_empty(), "AC2 edge — no signal fired")


# === AC9: direct swap ===

func _test_ac9_direct_swap_no_intermediate_deselect() -> void:
	print("\n[AC9] click a different placed piece → direct swap, no intermediate deselect")
	var parts := _make_world()
	var placement: RefCounted = parts[2]
	var selection: RefCounted = parts[3]

	_place(placement, "treadmill_01", Vector2i(1, 1), 0)  # id 0
	_place(placement, "yoga_01", Vector2i(4, 4), 0)      # id 1
	selection.call("on_cell_clicked", Vector2i(1, 1))    # select treadmill
	var spy := _spy_for(selection)

	selection.call("on_cell_clicked", Vector2i(4, 4))    # click yoga

	_check(selection.call("get_selected_instance_id") == 1, "AC9 — selection swapped to instance 1")
	_check(spy.deselect_count() == 0, "AC9 — NO intermediate deselect emission")
	_check_single_select(spy, 1, "yoga_01", Vector2i(4, 4), 0, "AC9")


# === AC10: re-click no-op ===

func _test_ac10_reclick_selected_noop() -> void:
	print("\n[AC10] click the already-selected piece → no-op (no signal, no toggle-off)")
	var parts := _make_world()
	var placement: RefCounted = parts[2]
	var selection: RefCounted = parts[3]

	_place(placement, "treadmill_01", Vector2i(1, 1), 0)
	selection.call("on_cell_clicked", Vector2i(1, 1))  # select
	var spy := _spy_for(selection)

	selection.call("on_cell_clicked", Vector2i(1, 1))  # re-click the SAME piece

	_check(selection.call("get_selected_instance_id") == 0, "AC10 — selection stays on instance 0")
	_check(spy.emissions.is_empty(), "AC10 — no signal fired (re-click is not a toggle-off)")


# === AC11: external removal ===

func _test_ac11_external_removal_clears_selection() -> void:
	print("\n[AC11] selected piece removed externally → selection clears + selection_changed(null)")
	var parts := _make_world()
	var grid: RefCounted = parts[0]
	var placement: RefCounted = parts[2]
	var selection: RefCounted = parts[3]

	_place(placement, "treadmill_01", Vector2i(1, 1), 0)
	selection.call("on_cell_clicked", Vector2i(1, 1))  # select id 0
	var spy := _spy_for(selection)

	grid.call("clear", 0)  # external removal → grid_changed fires

	_check(selection.call("get_selected_instance_id") == -1, "AC11 — selection cleared")
	_check(spy.deselect_count() == 1, "AC11 — selection_changed(null) fired exactly once (got %d)" % spy.deselect_count())


func _test_ac11_removal_of_unselected_piece_no_signal() -> void:
	print("\n[AC11 edge] removal of a NON-selected piece → no signal, selection untouched")
	var parts := _make_world()
	var grid: RefCounted = parts[0]
	var placement: RefCounted = parts[2]
	var selection: RefCounted = parts[3]

	_place(placement, "treadmill_01", Vector2i(1, 1), 0)  # id 0
	_place(placement, "yoga_01", Vector2i(4, 4), 0)      # id 1
	selection.call("on_cell_clicked", Vector2i(1, 1))    # select treadmill
	var spy := _spy_for(selection)

	grid.call("clear", 1)  # remove the UNselected yoga

	_check(selection.call("get_selected_instance_id") == 0, "AC11 edge — selection still on instance 0")
	_check(spy.emissions.is_empty(), "AC11 edge — no signal fired")
	# The removed piece's mapping entry must be gone — clicking its cell is
	# empty floor now and must NOT resolve.
	selection.call("on_cell_clicked", Vector2i(4, 4))
	_check(selection.call("get_selected_instance_id") == -1, "AC11 edge — old cell reads empty; click deselects")


# === AC12: drag suppression ===

func _test_ac12_drag_suppresses_resolution() -> void:
	print("\n[AC12] PlacementSystem is_dragging() → click does not resolve a new selection")
	var parts := _make_world()
	var placement: RefCounted = parts[2]
	var selection: RefCounted = parts[3]

	_place(placement, "treadmill_01", Vector2i(1, 1), 0)  # id 0
	placement.call("begin_drag", "yoga_01")              # a drag is now in flight
	var spy := _spy_for(selection)

	selection.call("on_cell_clicked", Vector2i(1, 1))    # click the placed treadmill

	_check(placement.call("is_dragging") == true, "AC12 — drag still active")
	_check(selection.call("get_selected_instance_id") == -1, "AC12 — click did NOT resolve a selection")
	_check(spy.emissions.is_empty(), "AC12 — no signal fired")

	# After the drag ends, clicks resolve normally again.
	placement.call("on_cancel")
	selection.call("on_cell_clicked", Vector2i(1, 1))
	_check(selection.call("get_selected_instance_id") == 0, "AC12 — after drag ends, click resolves normally")


# === Core Rule 1: Esc deselects ===

func _test_core_rule_1_esc_deselects() -> void:
	print("\n[Core Rule 1] Esc → selection clears + selection_changed(null); Esc with no selection → no-op")
	var parts := _make_world()
	var placement: RefCounted = parts[2]
	var selection: RefCounted = parts[3]

	_place(placement, "treadmill_01", Vector2i(1, 1), 0)
	selection.call("on_cell_clicked", Vector2i(1, 1))  # select
	var spy := _spy_for(selection)

	selection.call("on_esc_pressed")

	_check(selection.call("get_selected_instance_id") == -1, "Esc — selection cleared")
	_check(spy.deselect_count() == 1, "Esc — selection_changed(null) fired exactly once (got %d)" % spy.deselect_count())

	selection.call("on_esc_pressed")  # already deselected
	_check(spy.deselect_count() == 1, "Esc — second press with no selection is a no-op (still 1 emission)")


# === Mapping: rotation derivation ===

func _test_mapping_rotation_derived_r90() -> void:
	print("\n[TR-SEL-005] rotation derived from footprint match — R90 placement reports rotation 90")
	var parts := _make_world()
	var placement: RefCounted = parts[2]
	var selection: RefCounted = parts[3]

	# treadmill at (2,2) rotated 90: footprint offsets (1,0),(1,1) → cells (3,2),(3,3)
	_place(placement, "treadmill_01", Vector2i(2, 2), 1)
	var spy := _spy_for(selection)

	selection.call("on_cell_clicked", Vector2i(3, 2))

	_check(selection.call("get_selected_instance_id") == 0, "R90 — selection resolves")
	_check_single_select(spy, 0, "treadmill_01", Vector2i(2, 2), 90, "R90")


func _test_mapping_rotation_derived_r180() -> void:
	print("\n[TR-SEL-005] rotation derived from footprint match — R180 placement reports rotation 180 + min-union anchor")
	var parts := _make_world()
	var placement: RefCounted = parts[2]
	var selection: RefCounted = parts[3]

	# treadmill at (2,2) rotated 180: footprint offsets (1,1),(0,1) → cells (3,3),(2,3);
	# access offset (1,0); union min (0,0) → payload anchor (2,2)
	# (PlacedInstance min-offset-of-fp∪ac convention, AC-D5.2)
	_place(placement, "treadmill_01", Vector2i(2, 2), 2)
	var spy := _spy_for(selection)

	selection.call("on_cell_clicked", Vector2i(3, 3))

	_check(selection.call("get_selected_instance_id") == 0, "R180 — selection resolves")
	_check_single_select(spy, 0, "treadmill_01", Vector2i(2, 2), 180, "R180")


# === Mapping: relocate re-commit updates the entry ===

func _test_mapping_relocate_recommit_updates_entry() -> void:
	print("\n[TR-SEL-005] relocate re-commit updates the mapping under the SAME instance_id")
	var parts := _make_world()
	var grid: RefCounted = parts[0]
	var placement: RefCounted = parts[2]
	var selection: RefCounted = parts[3]

	_place(placement, "treadmill_01", Vector2i(1, 1), 0)  # id 0 at (1,1) R0
	selection.call("on_cell_clicked", Vector2i(1, 1))     # select id 0
	var spy_pickup := _spy_for(selection)

	placement.call("begin_relocate", 0)  # pickup → grid_changed → selection clears

	_check(selection.call("get_selected_instance_id") == -1, "relocate — selection cleared at pickup (Move clears selection)")
	_check(spy_pickup.deselect_count() == 1, "relocate — selection_changed(null) fired at pickup")

	placement.call("on_mouse_moved", Vector2i(5, 5))
	placement.call("on_rotate_pressed")  # R90
	placement.call("on_drop")            # re-commit under id 0

	# R90 at (5,5): footprint cells (6,5),(6,6) → click (6,5). Fresh spy so
	# the payload assert sees only the post-recommit select (the pickup
	# deselect already fired into spy_pickup).
	var spy := _spy_for(selection)
	selection.call("on_cell_clicked", Vector2i(6, 5))

	_check(selection.call("get_selected_instance_id") == 0, "relocate — click after re-commit selects the SAME instance 0")
	_check_single_select(spy, 0, "treadmill_01", Vector2i(5, 5), 90, "relocate re-commit")


# === Signal arity (TR-SEL-004 / ADR-0005 S7) ===

func _test_signal_arity_select_four_args() -> void:
	print("\n[arity] select emits EXACTLY FOUR arguments")
	var parts := _make_world()
	var placement: RefCounted = parts[2]
	var selection: RefCounted = parts[3]

	_place(placement, "treadmill_01", Vector2i(1, 1), 0)
	var spy := _spy_for(selection)
	selection.call("on_cell_clicked", Vector2i(1, 1))

	_check(spy.emissions.size() == 1, "arity — one emission")
	if spy.emissions.size() == 1:
		var e: Array = spy.emissions[0]
		# A 4-arg emit delivers four REAL values; a short emit would leave the
		# trailing args at the String sentinel. typeof distinguishes them
		# without mixed-type == errors (GDScript rejects int vs String compare).
		_check(typeof(e[0]) != TYPE_STRING, "arity — arg 1 (instance_id) passed: %s" % str(e[0]))
		_check(typeof(e[1]) != TYPE_STRING, "arity — arg 2 (def) passed")
		_check(typeof(e[2]) != TYPE_STRING, "arity — arg 3 (cell) passed: %s" % str(e[2]))
		_check(typeof(e[3]) != TYPE_STRING, "arity — arg 4 (rotation) passed: %s" % str(e[3]))


func _test_signal_arity_deselect_one_null_arg() -> void:
	print("\n[arity] deselect emits EXACTLY ONE argument (null) — b/c/d stay at the sentinel")
	var parts := _make_world()
	var placement: RefCounted = parts[2]
	var selection: RefCounted = parts[3]

	_place(placement, "treadmill_01", Vector2i(1, 1), 0)
	selection.call("on_cell_clicked", Vector2i(1, 1))
	var spy := _spy_for(selection)

	selection.call("on_cell_clicked", Vector2i(5, 5))  # deselect

	_check(spy.emissions.size() == 1, "arity — one deselect emission")
	if spy.emissions.size() == 1:
		var e: Array = spy.emissions[0]
		_check(e[0] == null, "arity — arg 1 is null (the TR-SEL-004 selection_changed(null) payload)")
		_check(e[1] == NO_ARG, "arity — arg 2 NOT passed (sentinel kept) → emit passed exactly 1 arg")
		_check(e[2] == NO_ARG, "arity — arg 3 NOT passed (sentinel kept)")
		_check(e[3] == NO_ARG, "arity — arg 4 NOT passed (sentinel kept)")


# === Mapping edge: click an instance with no mapping entry ===

func _test_mapping_missing_entry_loud_noop() -> void:
	print("\n[mapping edge] click resolving an instance with NO mapping entry → loud no-op (no crash, no selection)")
	var parts := _make_world()
	var grid: RefCounted = parts[0]
	var catalog: RefCounted = parts[1]
	var placement: RefCounted = parts[2]

	_place(placement, "treadmill_01", Vector2i(1, 1), 0)  # id 0 placed...
	# ...but a SelectionSystem built WITHOUT _post_init() never saw the
	# placement_committed/grid_changed events — mapping stays empty (the
	# pre-load-rebuild data-consistency state, Story 005's job).
	var sel: RefCounted = (load(SEL_SCRIPT) as Script).new()
	sel.call("init", grid, placement, catalog)
	var spy := _spy_for(sel)

	sel.call("on_cell_clicked", Vector2i(1, 1))

	_check(sel.call("get_selected_instance_id") == -1, "mapping edge — no selection resolved")
	_check(spy.emissions.is_empty(), "mapping edge — no signal fired")


# === Control Manifest: use-before-init guard ===

func _test_use_before_init_guard() -> void:
	print("\n[GUARD] public methods before init() return safe defaults without crashing")
	var sel: RefCounted = (load(SEL_SCRIPT) as Script).new()
	# Deliberately skip init() — every public method must push_error + safe
	# default per the Control Manifest guard contract.
	var r: int = sel.call("get_selected_instance_id")
	_check(r == -1, "GUARD — get_selected_instance_id() before init() returns -1 (safe default)")
	sel.call("on_cell_clicked", Vector2i(1, 1))  # must not crash
	sel.call("on_esc_pressed")                    # must not crash
	_check(true, "GUARD — on_cell_clicked()/on_esc_pressed() before init() did not crash")
