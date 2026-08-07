# tests/integration/build_shop_ui/mode_arbitration_test.gd
# Story BSUI-003: Build/Select Mode Arbitration
# (production/epics/build-shop-ui/story-003-build-select-mode-arbitration.md)
#
# Integration story — the full presentation wiring (catalog + economy +
# grid + placement + Shop + SelectionSystem + ModeArbitration + palette)
# covering the BLOCKING ACs (TR-BSUI-004 + GDD Core Rule 4):
#   - AC6          a piece selected (selection_changed non-null) → the
#                  new-placement ghost is suppressed (is_ghost_suppressed
#                  true); the palette is still visible (not hidden, not
#                  dimmed). Edge: selection cleared mid-hover →
#                  ghost allowed again immediately (synchronous handler).
#   - Core Rule 4  palette mouse-down while a piece is selected → the
#                  selection is cleared FIRST (build takes over), then the
#                  drag begins — no dual ghost. Edge: can_purchase false
#                  (locked / unaffordable) → no drag, selection UNCHANGED.
#   - Idle         no selection → drag begins, ghost renders normally
#                  (is_ghost_suppressed false).
#   - Pillar 3     the two suppression directions together guarantee no
#                  dual ghost: build drag active → selection suppressed
#                  (SEL-001 AC12 — clicks don't resolve during a drag);
#                  selection active → placement ghost suppressed (this
#                  story). Verified end-to-end here.
#   - Edge         selection_changed arrives MID-drag → ghost suppressed
#                  on the fly (the arbitration reacts to the emit at any
#                  time; unreachable via real input because AC12 suppresses
#                  clicks during a drag — tested by direct emit as a pure
#                  consumer-robustness check).
#
# Run standalone: godot --headless --script tests/integration/build_shop_ui/mode_arbitration_test.gd
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"

const DEF_SCRIPT_PATH := "res://src/systems/equipment_def.gd"
const CATALOG_SCRIPT_PATH := "res://src/systems/equipment_catalog.gd"
const ECON_SCRIPT_PATH := "res://src/systems/economy.gd"
const SRG_SCRIPT_PATH := "res://src/systems/seeded_rng.gd"
const GRID_SCRIPT_PATH := "res://src/systems/grid_system.gd"
const PLACEMENT_SCRIPT_PATH := "res://src/systems/placement_system.gd"
const SELECTION_SCRIPT_PATH := "res://src/systems/selection_system.gd"
const PALETTE_SCRIPT_PATH := "res://src/ui/build_shop_palette.gd"
const AVAIL_SCRIPT_PATH := "res://src/ui/palette_availability.gd"
const SHOP_SCRIPT_PATH := "res://src/ui/shop.gd"
const ARBITRATION_SCRIPT_PATH := "res://src/ui/mode_arbitration.gd"

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
	print("  INTEGRATION TEST: Build/Shop UI — Mode Arbitration (Story BSUI-003)")
	print("=".repeat(48))

	_test_ac6_selection_suppresses_ghost()
	_test_ac6_selection_does_not_dim_palette()
	_test_ac6_deselect_allows_ghost_immediately()
	_test_ac6_deselect_by_click_allows_ghost_immediately()
	_test_core_rule_4_build_takes_over()
	_test_core_rule_4_selection_changed_null_fired_on_takeover()
	_test_core_rule_4_failed_gate_leaves_selection_unchanged()
	_test_core_rule_4_locked_item_leaves_selection_unchanged()
	_test_idle_drag_renders_normally()
	_test_idle_full_drag_commits()
	_test_build_drag_suppresses_selection_ac12()
	_test_selection_arrives_mid_drag_suppresses_on_the_fly()
	_test_arbitration_use_before_init_guard()
	_test_arbitration_init_twice_guard()

	_free_test_nodes()

	print("\n=== MODE ARBITRATION TEST: %d passed, %d failed ===\n" % [_pass, _fail])
	return {"pass": _pass, "fail": _fail}


func _check(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
		print("  PASS: " + msg)
	else:
		_fail += 1
		print("  FAIL: " + msg)


# === Helpers ===

## Every Node created by this test file that is NOT part of the SceneTree
## root's permanent lifecycle — freed in _free_test_nodes() so the headless
## run exits leak-free.
var _nodes_to_free: Array = []


func _free_test_nodes() -> void:
	for n in _nodes_to_free:
		if is_instance_valid(n):
			n.free()
	_nodes_to_free.clear()


func _ED() -> Script:
	return load(DEF_SCRIPT_PATH) as Script


func _CAT() -> Script:
	return load(CATALOG_SCRIPT_PATH) as Script


func _EC() -> Script:
	return load(ECON_SCRIPT_PATH) as Script


func _SRG() -> Script:
	return load(SRG_SCRIPT_PATH) as Script


func _GRID() -> Script:
	return load(GRID_SCRIPT_PATH) as Script


func _PLACEMENT() -> Script:
	return load(PLACEMENT_SCRIPT_PATH) as Script


func _SELECTION() -> Script:
	return load(SELECTION_SCRIPT_PATH) as Script


func _PALETTE() -> Script:
	return load(PALETTE_SCRIPT_PATH) as Script


func _SHOP() -> Script:
	return load(SHOP_SCRIPT_PATH) as Script


func _ARBITRATION() -> Script:
	return load(ARBITRATION_SCRIPT_PATH) as Script


## Canonical def builder — all EquipmentDef fields populated with sane
## defaults; only id/name/cost/unlock vary per fixture.
func _make_def(ED: Script, id: String, name: String, cost: int, unlock: String) -> RefCounted:
	var zone: Array = ["cardio"]
	var footprint: Array[Vector2i] = [Vector2i(0, 0)]
	var access: Array[Vector2i] = [Vector2i(1, 0)]
	var effects: Array[Dictionary] = []
	return ED.new(
		id, name, zone, footprint, access, cost, unlock, effects,
		200, 30, 100, 300,
	)


## Frozen catalog holding the given defs (via the internal loader API).
func _make_catalog(defs: Array) -> RefCounted:
	var cat: RefCounted = _CAT().new()
	for d in defs:
		cat.call("_add_definition", d)
	cat.call("_freeze")
	return cat


## Initialized SimulationOrchestrator in the scene tree (delivers _ready()
## synchronously — same pattern as the save-load integration tests). The
## orchestrator is the Economy init dependency; nothing else is needed.
func _make_orchestrator() -> Node:
	var orch: Node = load("res://src/systems/simulation_orchestrator.gd").new()
	root.add_child(orch)
	orch.call("_ready")
	_nodes_to_free.append(orch)
	return orch


## Real Economy rig: orchestrator + SeededRNG + real Economy init'd with the
## default config (starting_capital 500, r_visit 12).
func _make_economy(seed: int) -> RefCounted:
	var srg: RefCounted = _SRG().new()
	srg.call("init", seed)
	var orch := _make_orchestrator()
	var econ: RefCounted = _EC().new()
	econ.call("init", orch, srg)
	orch.set("economy", econ)
	return econ


## Open 10x10 grid (all cells buildable, frozen) — the PlacementSystem drag
## rig's spatial truth.
func _make_open_grid(width: int, height: int) -> RefCounted:
	var gs: RefCounted = _GRID().new()
	gs.call("init", width, height)
	for y in height:
		for x in width:
			gs.call("set_buildable", Vector2i(x, y), true)
	gs.call("freeze_buildable")
	return gs


## PlacementSystem wired to [grid] + [catalog].
func _make_placement(grid: RefCounted, catalog: RefCounted) -> RefCounted:
	var p: RefCounted = _PLACEMENT().new()
	p.call("init", grid, catalog)
	return p


## SelectionSystem wired for the instance mapping (init + _post_init — the
## mapping subscriptions are side effects, ADR-0001: connections live in
## _post_init).
func _make_selection(grid: RefCounted, placement: RefCounted, catalog: RefCounted) -> RefCounted:
	var sel: RefCounted = _SELECTION().new()
	sel.call("init", grid, placement, catalog)
	sel.call("_post_init")
	return sel


## The real Shop (Story 002 query surface) wired to catalog/economy/placement.
func _make_shop(catalog: RefCounted, economy: RefCounted, placement: RefCounted) -> RefCounted:
	var shop: RefCounted = _SHOP().new()
	shop.call("init", catalog, economy, placement)
	return shop


## ModeArbitration (Story 003) wired to the SelectionSystem.
func _make_arbitration(selection: RefCounted) -> RefCounted:
	var arb: RefCounted = _ARBITRATION().new()
	arb.call("init", selection)
	return arb


## Builds a palette Node wired to catalog/economy/availability/placement/
## arbitration and added to the root (tracked for teardown). Untyped return
## so tests can reach signals dynamically.
func _make_palette(catalog: RefCounted, economy: RefCounted, availability: RefCounted, placement: RefCounted, arbitration: RefCounted):
	var palette = _PALETTE().new()
	palette.call("init", catalog, economy, availability, placement, arbitration)
	root.add_child(palette)
	_nodes_to_free.append(palette)
	return palette


## Standard 4-item catalog + fresh economy (balance 500) + real Shop +
## placement + SelectionSystem + arbitration + palette rig:
##   treadmill_01 : $350, always available
##   bench_press  : $200, always available
##   yoga_mat     : $200, locked (milestone_a)
##   free_dumbbell: $0,   always available (cost-0 fixture)
func _make_standard_rig(seed: int) -> Dictionary:
	var ED := _ED()
	var defs: Array = [
		_make_def(ED, "treadmill_01", "Treadmill", 350, ""),
		_make_def(ED, "bench_press", "Bench Press", 200, ""),
		_make_def(ED, "yoga_mat", "Yoga Mat", 200, "milestone_a"),
		_make_def(ED, "free_dumbbell", "Free Dumbbell", 0, ""),
	]
	var catalog := _make_catalog(defs)
	var economy := _make_economy(seed)
	var grid := _make_open_grid(10, 10)
	var placement := _make_placement(grid, catalog)
	var shop := _make_shop(catalog, economy, placement)
	var selection := _make_selection(grid, placement, catalog)
	var arbitration := _make_arbitration(selection)
	var palette = _make_palette(catalog, economy, shop, placement, arbitration)
	return {
		"catalog": catalog, "economy": economy, "grid": grid,
		"placement": placement, "shop": shop, "selection": selection,
		"arbitration": arbitration, "palette": palette,
	}


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


## Connects a spy to [selection]'s selection_changed and returns it.
func _spy_for(selection: RefCounted) -> SelectionSpy:
	var spy := SelectionSpy.new()
	selection.connect("selection_changed", Callable(spy, "_on_selection_changed"))
	return spy


## Places a piece via the REAL PlacementSystem flow (begin_drag → mouse-move
## preview → drop), returning the allocated instance_id.
func _place(placement: RefCounted, equipment_id: String, anchor: Vector2i) -> int:
	var id_before: int = placement.call("get_next_instance_id")
	placement.call("begin_drag", equipment_id)
	placement.call("on_mouse_moved", anchor)
	placement.call("on_drop")
	return id_before


# === AC6: selection suppresses the ghost ===

func _test_ac6_selection_suppresses_ghost() -> void:
	print("\n[AC6] a piece selected (selection_changed non-null) → new-placement ghost SUPPRESSED")
	var rig := _make_standard_rig(0xB5301)
	var placement: RefCounted = rig["placement"]
	var selection: RefCounted = rig["selection"]
	var arbitration: RefCounted = rig["arbitration"]

	_place(placement, "treadmill_01", Vector2i(1, 1))  # id 0
	var spy := _spy_for(selection)

	_check(not bool(arbitration.call("is_ghost_suppressed")), "before selection: ghost NOT suppressed (idle)")
	selection.call("on_cell_clicked", Vector2i(1, 1))  # select the placed piece

	_check(int(selection.call("get_selected_instance_id")) == 0, "selection resolved to instance 0")
	_check(bool(arbitration.call("is_selection_active")), "arbitration sees the active selection")
	_check(bool(arbitration.call("is_ghost_suppressed")), "AC6 — ghost SUPPRESSED while a piece is selected (no dual ghost)")
	_check(spy.select_count() == 1, "selection_changed select emission fired exactly once (got %d)" % spy.select_count())


func _test_ac6_selection_does_not_dim_palette() -> void:
	print("\n[AC6] selection active → palette still VISIBLE and full-tint (only a drag dims it)")
	var rig := _make_standard_rig(0xB5302)
	var placement: RefCounted = rig["placement"]
	var selection: RefCounted = rig["selection"]
	var palette = rig["palette"]

	_place(placement, "treadmill_01", Vector2i(1, 1))
	selection.call("on_cell_clicked", Vector2i(1, 1))

	_check(bool(palette.get("visible")), "palette still visible during a selection")
	_check(palette.get("modulate") == Color.WHITE, "palette NOT dimmed during a selection (drag-only dim, got %s)" % str(palette.get("modulate")))


func _test_ac6_deselect_allows_ghost_immediately() -> void:
	print("\n[AC6 edge] selection cleared (programmatic clear_selection — the build-take-over path) → ghost allowed IMMEDIATELY")
	var rig := _make_standard_rig(0xB5303)
	var placement: RefCounted = rig["placement"]
	var selection: RefCounted = rig["selection"]
	var arbitration: RefCounted = rig["arbitration"]

	_place(placement, "treadmill_01", Vector2i(1, 1))
	selection.call("on_cell_clicked", Vector2i(1, 1))
	_check(bool(arbitration.call("is_ghost_suppressed")), "setup: ghost suppressed")

	selection.call("clear_selection")

	_check(not bool(arbitration.call("is_ghost_suppressed")), "ghost allowed again immediately after clear_selection (synchronous)")
	_check(not bool(arbitration.call("is_selection_active")), "arbitration sees idle")


func _test_ac6_deselect_by_click_allows_ghost_immediately() -> void:
	print("\n[AC6 edge] selection cleared mid-hover (click empty buildable floor — the AC2 deselect path) → ghost allowed again immediately")
	var rig := _make_standard_rig(0xB5304)
	var placement: RefCounted = rig["placement"]
	var selection: RefCounted = rig["selection"]
	var arbitration: RefCounted = rig["arbitration"]

	_place(placement, "treadmill_01", Vector2i(1, 1))
	selection.call("on_cell_clicked", Vector2i(1, 1))
	_check(bool(arbitration.call("is_ghost_suppressed")), "setup: ghost suppressed")

	selection.call("on_cell_clicked", Vector2i(5, 5))  # empty buildable floor → deselect

	_check(not bool(arbitration.call("is_ghost_suppressed")), "ghost allowed again immediately after floor-click deselect")
	_check(int(selection.call("get_selected_instance_id")) == -1, "selection actually cleared")


# === Core Rule 4: build takes over ===

func _test_core_rule_4_build_takes_over() -> void:
	print("\n[Core Rule 4] palette mouse-down while a piece is selected → selection CLEARED FIRST, then drag begins (no dual ghost)")
	var rig := _make_standard_rig(0xB5311)
	var placement: RefCounted = rig["placement"]
	var selection: RefCounted = rig["selection"]
	var arbitration: RefCounted = rig["arbitration"]
	var palette = rig["palette"]

	_place(placement, "treadmill_01", Vector2i(1, 1))
	selection.call("on_cell_clicked", Vector2i(1, 1))
	_check(bool(arbitration.call("is_ghost_suppressed")), "setup: ghost suppressed (selection active)")

	_check(bool(palette.call("on_tile_mouse_down", "treadmill_01")), "palette mouse-down on affordable item -> true (drag began)")

	_check(int(selection.call("get_selected_instance_id")) == -1, "Core Rule 4 — selection cleared FIRST (get_selected_instance_id == -1)")
	_check(not bool(arbitration.call("is_selection_active")), "arbitration sees idle after the takeover")
	_check(not bool(arbitration.call("is_ghost_suppressed")), "ghost NOT suppressed during the new drag — no dual ghost")
	_check(bool(placement.call("is_dragging")), "PlacementSystem drag is in flight (build took over)")


func _test_core_rule_4_selection_changed_null_fired_on_takeover() -> void:
	print("\n[Core Rule 4] build-take-over emits selection_changed(null) exactly once (the deselect is observable)")
	var rig := _make_standard_rig(0xB5312)
	var placement: RefCounted = rig["placement"]
	var selection: RefCounted = rig["selection"]
	var palette = rig["palette"]

	_place(placement, "treadmill_01", Vector2i(1, 1))
	selection.call("on_cell_clicked", Vector2i(1, 1))
	var spy := _spy_for(selection)

	palette.call("on_tile_mouse_down", "treadmill_01")

	_check(spy.deselect_count() == 1, "exactly ONE selection_changed(null) on build-take-over (got %d)" % spy.deselect_count())
	_check(spy.select_count() == 0, "no new select emission on takeover (got %d)" % spy.select_count())


func _test_core_rule_4_failed_gate_leaves_selection_unchanged() -> void:
	print("\n[Core Rule 4 edge] can_purchase FALSE (unaffordable) while a piece is selected → no drag, selection UNCHANGED")
	var rig := _make_standard_rig(0xB5313)
	var placement: RefCounted = rig["placement"]
	var selection: RefCounted = rig["selection"]
	var arbitration: RefCounted = rig["arbitration"]
	var palette = rig["palette"]
	var economy: RefCounted = rig["economy"]

	_place(placement, "treadmill_01", Vector2i(1, 1))
	selection.call("on_cell_clicked", Vector2i(1, 1))
	economy.call("spend", 400)  # balance 100 → treadmill ($350) unaffordable
	var spy := _spy_for(selection)

	_check(not bool(palette.call("on_tile_mouse_down", "treadmill_01")), "palette mouse-down on unaffordable item -> false (no drag)")
	_check(not bool(placement.call("is_dragging")), "no drag began")
	_check(int(selection.call("get_selected_instance_id")) == 0, "Core Rule 4 edge — selection UNCHANGED (still instance 0)")
	_check(bool(arbitration.call("is_ghost_suppressed")), "ghost still suppressed (selection still active)")
	_check(spy.emissions.is_empty(), "no selection signal fired on the failed gate")


func _test_core_rule_4_locked_item_leaves_selection_unchanged() -> void:
	print("\n[Core Rule 4 edge] LOCKED item mouse-down while a piece is selected → no drag, selection UNCHANGED")
	var rig := _make_standard_rig(0xB5314)
	var placement: RefCounted = rig["placement"]
	var selection: RefCounted = rig["selection"]
	var arbitration: RefCounted = rig["arbitration"]
	var palette = rig["palette"]

	_place(placement, "treadmill_01", Vector2i(1, 1))
	selection.call("on_cell_clicked", Vector2i(1, 1))
	var spy := _spy_for(selection)

	_check(not bool(palette.call("on_tile_mouse_down", "yoga_mat")), "palette mouse-down on locked item -> false (no drag)")
	_check(not bool(placement.call("is_dragging")), "no drag began")
	_check(int(selection.call("get_selected_instance_id")) == 0, "Core Rule 4 edge — selection UNCHANGED (still instance 0)")
	_check(bool(arbitration.call("is_ghost_suppressed")), "ghost still suppressed")
	_check(spy.emissions.is_empty(), "no selection signal fired on the locked-item gate")


# === Idle: normal rendering ===

func _test_idle_drag_renders_normally() -> void:
	print("\n[Idle] no selection → palette mouse-down → drag begins, ghost renders normally (not suppressed)")
	var rig := _make_standard_rig(0xB5321)
	var placement: RefCounted = rig["placement"]
	var arbitration: RefCounted = rig["arbitration"]
	var palette = rig["palette"]

	_check(not bool(arbitration.call("is_ghost_suppressed")), "idle: ghost NOT suppressed before the drag")
	_check(bool(palette.call("on_tile_mouse_down", "bench_press")), "palette mouse-down -> true (drag began)")
	_check(bool(placement.call("is_dragging")), "PlacementSystem drag is in flight")
	_check(not bool(arbitration.call("is_ghost_suppressed")), "Idle — ghost NOT suppressed during the drag (renders normally)")
	_check(bool(palette.call("is_drag_in_flight")), "palette one-drag invariant active")


func _test_idle_full_drag_commits() -> void:
	print("\n[Idle full flow] no selection → drag → move → drop commits the placement; ghost never suppressed")
	var rig := _make_standard_rig(0xB5322)
	var placement: RefCounted = rig["placement"]
	var arbitration: RefCounted = rig["arbitration"]
	var palette = rig["palette"]
	var grid: RefCounted = rig["grid"]

	palette.call("on_tile_mouse_down", "bench_press")
	placement.call("on_mouse_moved", Vector2i(4, 4))
	placement.call("on_drop")

	_check(int(grid.call("get_occupant_id", Vector2i(4, 4))) == 0, "placement committed — grid holds the piece at (4,4)")
	_check(not bool(placement.call("is_dragging")), "drag resolved")
	_check(not bool(arbitration.call("is_ghost_suppressed")), "ghost never suppressed in the idle flow")


# === Pillar 3: both suppression directions ===

func _test_build_drag_suppresses_selection_ac12() -> void:
	print("\n[Pillar 3] build drag active → selection suppressed (SEL-001 AC12: clicks don't resolve during a drag) — the other half of no-dual-ghost")
	var rig := _make_standard_rig(0xB5331)
	var placement: RefCounted = rig["placement"]
	var selection: RefCounted = rig["selection"]
	var palette = rig["palette"]

	# Two pieces on the grid; select one, then build takes over with a drag.
	_place(placement, "treadmill_01", Vector2i(1, 1))   # id 0
	_place(placement, "bench_press", Vector2i(5, 5))    # id 1
	selection.call("on_cell_clicked", Vector2i(1, 1))   # select treadmill

	_check(bool(palette.call("on_tile_mouse_down", "treadmill_01")), "setup: build takes over (drag begins, selection cleared)")

	# Spy AFTER the takeover so the takeover's own selection_changed(null)
	# deselect emission is not attributed to the click under test.
	var spy := _spy_for(selection)

	# While the drag is in flight, clicking ANY grid cell (empty or placed)
	# must NOT resolve a selection — AC12. The drag owns the screen.
	selection.call("on_cell_clicked", Vector2i(5, 5))   # bench's cell — would select id 1 if it resolved
	_check(int(selection.call("get_selected_instance_id")) == -1, "AC12 — click during drag did NOT resolve a selection")
	_check(spy.emissions.is_empty(), "AC12 — no selection signal fired during the drag")
	_check(bool(placement.call("is_dragging")), "drag undisturbed by the click")


func _test_selection_arrives_mid_drag_suppresses_on_the_fly() -> void:
	print("\n[Edge] selection_changed arrives MID-drag → ghost suppressed ON THE FLY (consumer reacts to the emit at any time)")
	print("       (unreachable via real input — SEL-001 AC12 suppresses clicks during a drag — direct emit is a pure robustness check)")
	var rig := _make_standard_rig(0xB5332)
	var placement: RefCounted = rig["placement"]
	var selection: RefCounted = rig["selection"]
	var arbitration: RefCounted = rig["arbitration"]
	var palette = rig["palette"]

	_check(bool(palette.call("on_tile_mouse_down", "treadmill_01")), "setup: drag in flight")
	_check(not bool(arbitration.call("is_ghost_suppressed")), "ghost NOT suppressed at drag start (no selection)")

	# A selection_changed emit arrives mid-drag (direct emit — the arbitration
	# must not assume the emit cannot arrive while a drag is in flight).
	selection.emit_signal("selection_changed", 999, null, Vector2i.ZERO, 0)

	_check(bool(arbitration.call("is_ghost_suppressed")), "ghost SUPPRESSED on the fly mid-drag")
	_check(bool(arbitration.call("is_selection_active")), "arbitration sees the mid-drag selection")
	_check(bool(placement.call("is_dragging")), "the drag itself is undisturbed (suppression is presentation-only)")

	# And it releases again on the deselect emit — the same synchronous path.
	selection.emit_signal("selection_changed", null)
	_check(not bool(arbitration.call("is_ghost_suppressed")), "ghost allowed again on mid-drag deselect")


# === Guards ===

func _test_arbitration_use_before_init_guard() -> void:
	print("\n[guard] ModeArbitration public methods before init() → safe defaults, no crash")
	var arb: RefCounted = _ARBITRATION().new()

	_check(not bool(arb.call("is_selection_active")), "is_selection_active before init -> false (safe default)")
	_check(not bool(arb.call("is_ghost_suppressed")), "is_ghost_suppressed before init -> false (safe default)")
	arb.call("begin_build")  # must be a silent no-op — no crash, no error path
	_check(true, "begin_build before init -> silent no-op, no crash")


func _test_arbitration_init_twice_guard() -> void:
	print("\n[guard] ModeArbitration.init() twice → logged error, no crash, still functional")
	var rig := _make_standard_rig(0xB5333)
	var selection: RefCounted = rig["selection"]
	var arb: RefCounted = rig["arbitration"]
	arb.call("init", selection)

	_check(not bool(arb.call("is_selection_active")), "still answers queries after double init (idle)")
