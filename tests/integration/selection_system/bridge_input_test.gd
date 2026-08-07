# tests/integration/selection_system/bridge_input_test.gd
# Story SEL-002: Input Bridge Node + Keyboard Handling
# (production/epics/selection-system/story-002-input-bridge-node.md)
#
# Covers the BLOCKING ACs / QA cases:
#   TR-SEL-008 — after composition-root boot, SelectionInputBridge is a child
#                Node of SimulationOrchestrator (not the presentation layer);
#                a left-click on the grid is converted screen→cell and
#                forwarded as on_cell_clicked(cell) to the RefCounted
#                SelectionSystem — raw screen pixels never reach the system;
#                clicks OUTSIDE the grid are ignored (no conversion / no
#                forwarding).
#   AC3        — Esc with a selection → selection clears + selection_changed
#                (null) fires; Esc with no selection → no-op; Esc during a
#                pending sell-confirm → REVERT ONLY (selection stays — GDD
#                states table: pending | Esc | selected).
#   Core Rule 5 / TR-SEL-009 — Del triggers the SAME soft-confirm as clicking
#                Sell (request_sell_confirm): no instant destructive sale; Del
#                during pending → no double-morph; Del with no selection →
#                no-op.
#   Timer      — pending → 2s elapse (timeout handler) → reverts, no sale,
#                no confirmed signal; confirm within the window → confirmed
#                fires (Story 003 hooks the sale) and the now-stale timeout
#                cannot revert; timer is SceneTreeTimer process_always=true
#                (render-time, not tick-gated — fires while paused).
#   Move guard — is_move_blocked() true while PlacementSystem is DRAGGING
#                (story Implementation Notes / AC27).
#   Ownership  — bridge Node destroyed (scene transition) → SelectionSystem
#                NOT freed; composition root holds the strong reference.
#
# Design notes:
#   - The bridge is tested with SYNTHETIC InputEvent objects delivered through
#     its engine callbacks (_unhandled_input / _unhandled_key_input), plus
#     direct handler calls for the timer (the established headless pattern).
#   - Two construction paths:
#       (a) full composition-root boot (SimulationOrchestrator with a
#           pre-injected grid) — TR-SEL-008 ownership + AC bridge ownership;
#       (b) direct bridge construction with spy/real systems — precise
#           cell-vs-pixel, keyboard, and timer assertions.
#   - The timer's 2s timeout is driven deterministically via
#     _on_sell_confirm_timeout(generation) with the CURRENT generation (the
#     bridge is not in the tree in headless tests, so get_tree() is null and
#     no real timer is created); the timer WIRING (SceneTreeTimer with
#     process_always=true) is verified separately with the bridge attached to
#     the SceneTree root.
#   - "No sale / no balance change" on timeout is asserted as: no
#     sell_confirm_confirmed emission (the confirmed signal is the sale
#     trigger Story 003 hooks; the sale itself — Economy credit etc. — is
#     Story 003's scope, so balance assertions land in sell_flow_test.gd).
#
# Run standalone: godot --headless --script tests/integration/selection_system/bridge_input_test.gd
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"

const BRIDGE_SCRIPT_PATH := "res://src/systems/selection_input_bridge.gd"
const SEL_SCRIPT_PATH := "res://src/systems/selection_system.gd"
const PLACEMENT_SCRIPT_PATH := "res://src/systems/placement_system.gd"
const GRID_SCRIPT_PATH := "res://src/systems/grid_system.gd"
const CATALOG_SCRIPT_PATH := "res://src/systems/equipment_catalog.gd"
const DEF_SCRIPT_PATH := "res://src/systems/equipment_def.gd"

const CELL_SIZE := 32  # must match SimulationOrchestrator.PLACEMENT_CELL_SIZE

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
	print("  INTEGRATION TEST: SelectionInputBridge — Input Bridge + Keyboard (SEL-002)")
	print("=".repeat(48))

	_test_tr_sel_008_bridge_child_of_orchestrator()
	_test_tr_sel_008_forwards_parsed_calls()
	_test_tr_sel_008_screen_to_cell_never_raw_pixels()
	_test_tr_sel_008_oob_clicks_ignored()
	_test_tr_sel_008_real_click_selects_piece()
	_test_tr_sel_008_click_empty_floor_deselects()
	_test_ac3_esc_deselects()
	_test_ac3_esc_no_selection_noop()
	_test_ac3_esc_during_pending_revert_only()
	_test_core_rule_5_del_triggers_soft_confirm()
	_test_core_rule_5_del_no_selection_noop()
	_test_core_rule_5_del_during_pending_no_double_morph()
	_test_timer_timeout_reverts_no_sale()
	_test_timer_confirm_within_window_sale_proceeds()
	_test_timer_stale_timeout_cannot_kill_new_window()
	_test_timer_render_time_process_always()
	_test_keyboard_other_keys_ignored_and_echo()
	_test_click_away_reverts_pending_then_resolves()
	_test_move_blocked_during_drag()
	_test_external_invalidation_reverts_pending()
	_test_ownership_survives_bridge_free()
	_test_no_process_polling()
	_test_sell_confirm_duration_config_clamp()

	_free_test_nodes()

	print("\n=== SELECTION INPUT BRIDGE TEST: %d passed, %d failed ===\n" % [_pass, _fail])
	return {"pass": _pass, "fail": _fail}


func _check(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
		print("  PASS: " + msg)
	else:
		_fail += 1
		print("  FAIL: " + msg)


# === Spies / helpers ===

## Spy grid — counts world_to_grid calls and delegates to the real
## GridSystem implementation (super). The count is the "conversion runs per
## click" evidence; the super delegation keeps all real grid behavior.
class SpyGrid extends GridSystem:
	var world_to_grid_calls := 0

	func world_to_grid(world_pos: Vector2, cell_size: int) -> Vector2i:
		world_to_grid_calls += 1
		return super.world_to_grid(world_pos, cell_size)


## Spy system — records the typeof() of every argument received across the
## forwarded methods, delegating to the real SelectionSystem (super). The
## recorded arg types are the "raw P never reaches the system" evidence: if
## the bridge ever forwarded a screen pixel (Vector2), it would show up here
## as TYPE_VECTOR2.
class SpySelectionSystem extends SelectionSystem:
	var received_types: Array = []  # typeof() of every forwarded arg
	var clicked_cells: Array = []  # every Vector2i cell forwarded
	var esc_presses := 0
	var del_presses := 0

	func on_cell_clicked(cell: Vector2i) -> void:
		clicked_cells.append(cell)
		received_types.append(typeof(cell))
		super.on_cell_clicked(cell)

	func on_esc_pressed() -> void:
		esc_presses += 1
		super.on_esc_pressed()


## RefCounted signal counter for the bridge's three sell-confirm signals.
class ConfirmSpy extends RefCounted:
	var started := 0
	var reverted := 0
	var confirmed := 0

	func on_started() -> void:
		started += 1

	func on_reverted() -> void:
		reverted += 1

	func on_confirmed() -> void:
		confirmed += 1


## RefCounted signal counter for SelectionSystem.selection_changed (S7).
class SelectionSpy extends RefCounted:
	var emissions: Array = []  # each: [a, b, c, d]

	func _on_selection_changed(a = null, b = null, c = null, d = null) -> void:
		emissions.append([a, b, c, d])

	func select_count() -> int:
		var n := 0
		for e in emissions:
			if e[0] != null:
				n += 1
		return n

	func deselect_count() -> int:
		var n := 0
		for e in emissions:
			if e[0] == null:
				n += 1
		return n


func _ED() -> Script:
	return load(DEF_SCRIPT_PATH) as Script


## Canonical-0° treadmill fixture def (1x2 footprint + 1 access cell).
func _make_def(ED: Script, id: String) -> RefCounted:
	var zone: Array = ["cardio"]
	var footprint: Array[Vector2i] = [Vector2i(0, 0), Vector2i(1, 0)]
	var access: Array[Vector2i] = [Vector2i(0, 1)]
	var effects: Array[Dictionary] = []
	return ED.new(
		id,
		"Test %s" % id,
		zone,
		footprint,
		access,
		200,
		"",
		effects,
		200,
		30,
		100,
		300,
	)


## Open-room grid (every cell buildable, frozen).
func _make_open_grid(width: int, height: int) -> GridSystem:
	var g: GridSystem = GridSystem.new()
	g.init(width, height)
	for y in height:
		for x in width:
			g.set_buildable(Vector2i(x, y), true)
	g.freeze_buildable()
	return g


## Catalog holding the given defs (via the internal loader API).
func _make_catalog(defs: Array) -> EquipmentCatalog:
	var cat: EquipmentCatalog = EquipmentCatalog.new()
	for d in defs:
		cat.call("_add_definition", d)
	cat.call("_freeze")
	return cat


## Direct bridge construction with the given system + grid. The bridge is a
## Node — it must be added to the tree to receive engine callbacks in a real
## run; for deterministic synthetic-event tests we invoke the callbacks
## directly on the instance (established headless pattern).
##
## NOTE: the returned bridge is a plain Node never added to the tree; tests
## must free() it before returning (tracked in _nodes_to_free for uniform
## teardown) to keep the headless run leak-free.
func _make_bridge(system: SelectionSystem, grid: GridSystem, placement: PlacementSystem = null) -> SelectionInputBridge:
	var B: Script = load(BRIDGE_SCRIPT_PATH) as Script
	var bridge: SelectionInputBridge = B.new()
	bridge.init(system, grid, CELL_SIZE, placement)
	_nodes_to_free.append(bridge)
	return bridge


## Every Node created by this test file that is NOT part of the SceneTree
## root (direct-constructed bridges) — freed in _free_test_nodes() so the
## process exits with zero leaks. Nodes owned by the tree (orchestrator boot
## tests) are freed via orch.free() in their own tests.
var _nodes_to_free: Array = []


func _free_test_nodes() -> void:
	for n in _nodes_to_free:
		if is_instance_valid(n):
			n.free()
	_nodes_to_free.clear()


## Places a treadmill via the REAL PlacementSystem flow at [anchor] R0,
## returning the allocated instance_id (mirrors selection_logic_test).
func _place_treadmill(ps: PlacementSystem, anchor: Vector2i) -> int:
	var id_before: int = ps.get_next_instance_id()
	ps.begin_drag("treadmill_01")
	ps.on_mouse_moved(anchor)
	ps.on_drop()
	return id_before


func _click(pos: Vector2) -> InputEventMouseButton:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = true
	ev.position = pos
	return ev


func _key(keycode: Key) -> InputEventKey:
	var ev := InputEventKey.new()
	ev.keycode = keycode
	ev.pressed = true
	return ev


## Bounds of a 10x10 open grid in CELL_SIZE pixels: (0,0)..(319,319).
func _cell_px(cell: Vector2i) -> Vector2:
	return Vector2(cell.x * CELL_SIZE, cell.y * CELL_SIZE)


## Drives the bridge's 2s timeout deterministically: the bridge is not in the
## tree in headless tests (get_tree() null → no real timer), so the timeout
## handler is invoked directly with the CURRENT generation — exactly the
## generation a real SceneTreeTimer would bind at creation.
func _fire_timeout(bridge: SelectionInputBridge) -> void:
	var gen: int = bridge.get("_timer_generation")
	bridge.call("_on_sell_confirm_timeout", gen)


## Scripts the bridge script defines. Used to prove _unhandled_input /
## _unhandled_key_input exist and _process does NOT (the polling path).
func _bridge_script_methods() -> Array:
	var script: Script = load(BRIDGE_SCRIPT_PATH) as Script
	var methods: Array = script.get_script_method_list()
	var names: Array = []
	for m in methods:
		names.append(m["name"])
	return names


## Builds the real-world fixture: open grid + catalog + real PlacementSystem
## + real SelectionSystem + bridge wired to them. Returns
## [grid, placement, selection, bridge].
func _make_real_world() -> Array:
	var grid := _make_open_grid(10, 10)
	var cat := _make_catalog([_make_def(_ED(), "treadmill_01")])
	var ps := PlacementSystem.new()
	ps.init(grid, cat)
	var sel := SelectionSystem.new()
	sel.init(grid, ps, cat)
	sel._post_init()
	var bridge := _make_bridge(sel, grid, ps)
	return [grid, ps, sel, bridge]


# === TR-SEL-008: bridge is a child of the composition root ===

func _test_tr_sel_008_bridge_child_of_orchestrator() -> void:
	print("\n[TR-SEL-008] composition-root boot → SelectionInputBridge is a child of SimulationOrchestrator")

	var grid := _make_open_grid(10, 10)
	var orch := SimulationOrchestrator.new()
	orch.grid_system = grid  # pre-inject BEFORE init() — LevelLoader story pending
	orch.init()  # explicit two-phase init (see note in placement bridge test)
	root.add_child(orch)

	var bridge: Node = orch.get_node_or_null("SelectionInputBridge")
	_check(bridge != null, "SelectionInputBridge node exists after boot")
	if bridge == null:
		orch.free()
		return
	_check(bridge.get_parent() == orch, "bridge parent is SimulationOrchestrator (not the presentation layer)")
	_check(orch.selection_system != null, "composition root holds selection_system as a RefCounted field")
	_check(
		bridge.get("_system") == orch.selection_system,
		"bridge forwards to the SAME SelectionSystem instance the composition root owns"
	)

	orch.free()


# === TR-SEL-008: input arrives as parsed method calls (cells, not pixels) ===

func _test_tr_sel_008_forwards_parsed_calls() -> void:
	print("\n[TR-SEL-008] on_cell_clicked(cell) forwarded to the RefCounted SelectionSystem")

	var grid := _make_open_grid(10, 10)
	var cat := _make_catalog([_make_def(_ED(), "treadmill_01")])
	var ps := PlacementSystem.new()
	ps.init(grid, cat)
	var sel := SpySelectionSystem.new()
	sel.init(grid, ps, cat)
	sel._post_init()
	var bridge := _make_bridge(sel, grid)

	bridge.on_cell_clicked(Vector2i(5, 3))
	_check(sel.clicked_cells == [Vector2i(5, 3)], "on_cell_clicked(Vector2i(5,3)) forwarded verbatim (got %s)" % [sel.clicked_cells])

	var has_pixels := false
	for t in sel.received_types:
		if t == TYPE_VECTOR2:
			has_pixels = true
	_check(not has_pixels, "raw screen pixels (TYPE_VECTOR2) NEVER reach the system (received %s)" % [sel.received_types])


# === AC(bridge): screen position P → cell world_to_grid(P), never raw P ===

func _test_tr_sel_008_screen_to_cell_never_raw_pixels() -> void:
	print("\n[TR-SEL-008] synthetic InputEventMouseButton at P → system receives on_cell_clicked(world_to_grid(P))")

	var grid := SpyGrid.new()
	grid.init(10, 10)
	for y in 10:
		for x in 10:
			grid.set_buildable(Vector2i(x, y), true)
	grid.freeze_buildable()
	var cat := _make_catalog([_make_def(_ED(), "treadmill_01")])
	var ps := PlacementSystem.new()
	ps.init(grid, cat)
	var sel := SpySelectionSystem.new()
	sel.init(grid, ps, cat)
	sel._post_init()
	var bridge := _make_bridge(sel, grid)

	# Synthetic press at screen position P over the grid.
	var p := Vector2(96, 160)  # /32 → cell (3,5)
	bridge.call("_unhandled_input", _click(p))

	_check(grid.world_to_grid_calls == 1, "world_to_grid ran exactly once for one click (got %d)" % grid.world_to_grid_calls)
	_check(sel.clicked_cells.size() == 1, "system received exactly one on_cell_clicked (got %d)" % sel.clicked_cells.size())
	if sel.clicked_cells.size() == 1:
		_check(
			sel.clicked_cells[0] == Vector2i(3, 5),
			"system received cell (3,5) == world_to_grid(P), NOT the raw position %s (got %s)" % [p, sel.clicked_cells[0]]
		)

	var has_pixels := false
	for t in sel.received_types:
		if t == TYPE_VECTOR2:
			has_pixels = true
	_check(not has_pixels, "raw P never reached the system (all args: %s)" % [sel.received_types])

	# Non-left buttons / releases do not forward.
	var right := _click(p)
	right.button_index = MOUSE_BUTTON_RIGHT
	bridge.call("_unhandled_input", right)
	var release := _click(p)
	release.pressed = false
	bridge.call("_unhandled_input", release)
	_check(sel.clicked_cells.size() == 1, "right-click and release are NOT forwarded (still 1 click)")


func _test_tr_sel_008_oob_clicks_ignored() -> void:
	print("\n[TR-SEL-008] edge: clicks outside the grid are ignored (no conversion / no forwarding)")

	var grid := SpyGrid.new()
	grid.init(10, 10)
	for y in 10:
		for x in 10:
			grid.set_buildable(Vector2i(x, y), true)
	grid.freeze_buildable()
	var cat := _make_catalog([_make_def(_ED(), "treadmill_01")])
	var ps := PlacementSystem.new()
	ps.init(grid, cat)
	var sel := SpySelectionSystem.new()
	sel.init(grid, ps, cat)
	sel._post_init()
	var bridge := _make_bridge(sel, grid)

	# Negative screen position → cell (-1,-1) → OOB → ignored.
	bridge.call("_unhandled_input", _click(Vector2(-5, -5)))
	_check(sel.clicked_cells.is_empty(), "click at (-5,-5) → OOB cell (-1,-1) → NOT forwarded (got %s)" % [sel.clicked_cells])

	# Position beyond the 10x10 grid (320px) → cell (10+, …) → OOB → ignored.
	bridge.call("_unhandled_input", _click(Vector2(400, 400)))
	_check(sel.clicked_cells.is_empty(), "click at (400,400) → OOB cell (12,12) → NOT forwarded (got %s)" % [sel.clicked_cells])

	# The grid's world_to_grid DID run (the conversion happens, then the
	# bounds check drops the result) — but nothing reached the system.
	_check(grid.world_to_grid_calls == 2, "conversion ran for OOB clicks (bounds-check is the gate): %d calls" % grid.world_to_grid_calls)


# === TR-SEL-008: real integration — click selects a placed piece ===

func _test_tr_sel_008_real_click_selects_piece() -> void:
	print("\n[TR-SEL-008] full flow: place treadmill → click at its screen cell → selection resolves + selection_changed fires")

	var parts := _make_real_world()
	var grid: GridSystem = parts[0]
	var ps: PlacementSystem = parts[1]
	var sel: SelectionSystem = parts[2]
	var bridge: SelectionInputBridge = parts[3]

	_place_treadmill(ps, Vector2i(1, 1))  # id 0, footprint (1,1)-(2,1)
	var spy := SelectionSpy.new()
	sel.selection_changed.connect(spy._on_selection_changed)

	# Click at the screen position of cell (1,1) — top-left pixel of the cell.
	bridge.call("_unhandled_input", _click(_cell_px(Vector2i(1, 1))))

	_check(sel.get_selected_instance_id() == 0, "click resolved selection to instance 0")
	_check(spy.select_count() == 1, "selection_changed fired exactly once (got %d)" % spy.select_count())
	if spy.select_count() == 1:
		var e: Array = spy.emissions[0]
		_check(e[0] == 0, "payload instance_id == 0")
		_check(e[1] != null and e[1].get("id") == "treadmill_01", "payload def id == 'treadmill_01'")
		_check(e[2] == Vector2i(1, 1), "payload cell == (1,1) (got %s)" % str(e[2]))
		_check(e[3] == 0, "payload rotation == R0")


func _test_tr_sel_008_click_empty_floor_deselects() -> void:
	print("\n[TR-SEL-008] click empty buildable floor → deselect (AC2 via bridge)")

	var parts := _make_real_world()
	var ps: PlacementSystem = parts[1]
	var sel: SelectionSystem = parts[2]
	var bridge: SelectionInputBridge = parts[3]

	_place_treadmill(ps, Vector2i(1, 1))
	bridge.call("_unhandled_input", _click(_cell_px(Vector2i(1, 1))))
	_check(sel.get_selected_instance_id() == 0, "precondition — piece selected")
	var spy := SelectionSpy.new()
	sel.selection_changed.connect(spy._on_selection_changed)

	bridge.call("_unhandled_input", _click(_cell_px(Vector2i(5, 5))))

	_check(sel.get_selected_instance_id() == -1, "click on empty floor cleared the selection")
	_check(spy.deselect_count() == 1, "selection_changed(null) fired exactly once (got %d)" % spy.deselect_count())


# === AC3: Esc ===

func _test_ac3_esc_deselects() -> void:
	print("\n[AC3] Esc with a selection → selection clears + selection_changed(null)")

	var parts := _make_real_world()
	var ps: PlacementSystem = parts[1]
	var sel: SelectionSystem = parts[2]
	var bridge: SelectionInputBridge = parts[3]

	_place_treadmill(ps, Vector2i(1, 1))
	bridge.call("_unhandled_input", _click(_cell_px(Vector2i(1, 1))))
	_check(sel.get_selected_instance_id() == 0, "precondition — piece selected")
	var spy := SelectionSpy.new()
	sel.selection_changed.connect(spy._on_selection_changed)

	bridge.call("_unhandled_key_input", _key(KEY_ESCAPE))

	_check(sel.get_selected_instance_id() == -1, "Esc cleared the selection")
	_check(spy.deselect_count() == 1, "selection_changed(null) fired exactly once (got %d)" % spy.deselect_count())


func _test_ac3_esc_no_selection_noop() -> void:
	print("\n[AC3] edge: Esc with no selection → no-op")

	var parts := _make_real_world()
	var sel: SelectionSystem = parts[2]
	var bridge: SelectionInputBridge = parts[3]
	var spy := SelectionSpy.new()
	sel.selection_changed.connect(spy._on_selection_changed)

	bridge.call("_unhandled_key_input", _key(KEY_ESCAPE))

	_check(sel.get_selected_instance_id() == -1, "still nothing selected")
	_check(spy.emissions.is_empty(), "no signal fired")


func _test_ac3_esc_during_pending_revert_only() -> void:
	print("\n[AC3] edge: Esc during pending sell-confirm → REVERT ONLY, selection stays (GDD states table)")

	var parts := _make_real_world()
	var ps: PlacementSystem = parts[1]
	var sel: SelectionSystem = parts[2]
	var bridge: SelectionInputBridge = parts[3]

	_place_treadmill(ps, Vector2i(1, 1))
	bridge.call("_unhandled_input", _click(_cell_px(Vector2i(1, 1))))
	_check(sel.get_selected_instance_id() == 0, "precondition — piece selected")
	var spy := SelectionSpy.new()
	sel.selection_changed.connect(spy._on_selection_changed)
	var confirm_spy := ConfirmSpy.new()
	bridge.sell_confirm_started.connect(confirm_spy.on_started)
	bridge.sell_confirm_reverted.connect(confirm_spy.on_reverted)
	bridge.sell_confirm_confirmed.connect(confirm_spy.on_confirmed)
	bridge.request_sell_confirm()
	_check(bridge.is_sell_confirm_pending(), "precondition — confirm window open")

	bridge.call("_unhandled_key_input", _key(KEY_ESCAPE))

	_check(not bridge.is_sell_confirm_pending(), "Esc closed the confirm window")
	_check(confirm_spy.reverted == 1, "sell_confirm_reverted fired exactly once (got %d)" % confirm_spy.reverted)
	_check(confirm_spy.confirmed == 0, "NO sell_confirm_confirmed — no sale")
	_check(sel.get_selected_instance_id() == 0, "selection STAYS (revert only — states table: pending | Esc | selected)")
	_check(spy.emissions.is_empty(), "no selection_changed emission (selection did not change)")

	# A second Esc (now no pending) deselects.
	bridge.call("_unhandled_key_input", _key(KEY_ESCAPE))
	_check(sel.get_selected_instance_id() == -1, "second Esc (no pending) deselects")
	_check(spy.deselect_count() == 1, "selection_changed(null) fired once after the second Esc")


# === Core Rule 5 / TR-SEL-009: Del ===

func _test_core_rule_5_del_triggers_soft_confirm() -> void:
	print("\n[Core Rule 5] Del with a selection → the SAME soft-confirm as clicking Sell (no instant sale)")

	var parts := _make_real_world()
	var ps: PlacementSystem = parts[1]
	var sel: SelectionSystem = parts[2]
	var bridge: SelectionInputBridge = parts[3]

	_place_treadmill(ps, Vector2i(1, 1))
	bridge.call("_unhandled_input", _click(_cell_px(Vector2i(1, 1))))
	_check(sel.get_selected_instance_id() == 0, "precondition — piece selected")
	var confirm_spy := ConfirmSpy.new()
	bridge.sell_confirm_started.connect(confirm_spy.on_started)
	bridge.sell_confirm_reverted.connect(confirm_spy.on_reverted)
	bridge.sell_confirm_confirmed.connect(confirm_spy.on_confirmed)

	bridge.call("_unhandled_key_input", _key(KEY_DELETE))

	_check(bridge.is_sell_confirm_pending(), "Del opened the soft-confirm window")
	_check(confirm_spy.started == 1, "sell_confirm_started fired exactly once (got %d)" % confirm_spy.started)
	_check(confirm_spy.confirmed == 0, "NO instant sale — sell_confirm_confirmed did NOT fire (keyboard never bypasses the confirm)")
	_check(sel.get_selected_instance_id() == 0, "selection unchanged — no destructive sell")


func _test_core_rule_5_del_no_selection_noop() -> void:
	print("\n[Core Rule 5] edge: Del with no selection → no-op")

	var parts := _make_real_world()
	var bridge: SelectionInputBridge = parts[3]
	var confirm_spy := ConfirmSpy.new()
	bridge.sell_confirm_started.connect(confirm_spy.on_started)
	bridge.sell_confirm_reverted.connect(confirm_spy.on_reverted)
	bridge.sell_confirm_confirmed.connect(confirm_spy.on_confirmed)

	bridge.call("_unhandled_key_input", _key(KEY_DELETE))

	_check(not bridge.is_sell_confirm_pending(), "no window opened")
	_check(confirm_spy.started == 0 and confirm_spy.reverted == 0 and confirm_spy.confirmed == 0, "no signals fired")


func _test_core_rule_5_del_during_pending_no_double_morph() -> void:
	print("\n[Core Rule 5] edge: Del during pending confirm → no double-morph")

	var parts := _make_real_world()
	var ps: PlacementSystem = parts[1]
	var sel: SelectionSystem = parts[2]
	var bridge: SelectionInputBridge = parts[3]

	_place_treadmill(ps, Vector2i(1, 1))
	bridge.call("_unhandled_input", _click(_cell_px(Vector2i(1, 1))))
	var confirm_spy := ConfirmSpy.new()
	bridge.sell_confirm_started.connect(confirm_spy.on_started)
	bridge.sell_confirm_reverted.connect(confirm_spy.on_reverted)
	bridge.sell_confirm_confirmed.connect(confirm_spy.on_confirmed)

	bridge.call("_unhandled_key_input", _key(KEY_DELETE))
	_check(bridge.is_sell_confirm_pending(), "precondition — window open")
	bridge.call("_unhandled_key_input", _key(KEY_DELETE))

	_check(bridge.is_sell_confirm_pending(), "window still open (Del during pending is a no-op)")
	_check(confirm_spy.started == 1, "sell_confirm_started fired ONCE — no double-morph (got %d)" % confirm_spy.started)
	_check(confirm_spy.confirmed == 0, "no sale triggered")


# === Timer: 2s timeout revert ===

func _test_timer_timeout_reverts_no_sale() -> void:
	print("\n[Timer] pending → 2s elapse with no second click → reverts; no sale; no confirmed signal")

	var parts := _make_real_world()
	var ps: PlacementSystem = parts[1]
	var sel: SelectionSystem = parts[2]
	var bridge: SelectionInputBridge = parts[3]

	_place_treadmill(ps, Vector2i(1, 1))
	bridge.call("_unhandled_input", _click(_cell_px(Vector2i(1, 1))))
	var confirm_spy := ConfirmSpy.new()
	bridge.sell_confirm_started.connect(confirm_spy.on_started)
	bridge.sell_confirm_reverted.connect(confirm_spy.on_reverted)
	bridge.sell_confirm_confirmed.connect(confirm_spy.on_confirmed)
	bridge.request_sell_confirm()
	_check(bridge.is_sell_confirm_pending(), "precondition — window open")

	_fire_timeout(bridge)

	_check(not bridge.is_sell_confirm_pending(), "timeout closed the window")
	_check(confirm_spy.reverted == 1, "sell_confirm_reverted fired exactly once (got %d)" % confirm_spy.reverted)
	_check(confirm_spy.confirmed == 0, "NO sell_confirm_confirmed — no sale (no destructive default)")
	_check(sel.get_selected_instance_id() == 0, "selection stays selected after the revert (states table: pending | 2s elapse | selected)")

	# A second timeout (stale) is a no-op.
	_fire_timeout(bridge)
	_check(confirm_spy.reverted == 1, "stale second timeout does not re-revert (still 1)")


func _test_timer_confirm_within_window_sale_proceeds() -> void:
	print("\n[Timer] edge: confirm clicked within the window → confirmed fires (sale proceeds — Story 003 hooks it)")

	var parts := _make_real_world()
	var ps: PlacementSystem = parts[1]
	var sel: SelectionSystem = parts[2]
	var bridge: SelectionInputBridge = parts[3]

	_place_treadmill(ps, Vector2i(1, 1))
	bridge.call("_unhandled_input", _click(_cell_px(Vector2i(1, 1))))
	var confirm_spy := ConfirmSpy.new()
	bridge.sell_confirm_started.connect(confirm_spy.on_started)
	bridge.sell_confirm_reverted.connect(confirm_spy.on_reverted)
	bridge.sell_confirm_confirmed.connect(confirm_spy.on_confirmed)
	bridge.request_sell_confirm()

	# "Confirm at 1.9s" is represented deterministically: confirm_sell() is
	# called BEFORE the timeout fires.
	bridge.confirm_sell()

	_check(not bridge.is_sell_confirm_pending(), "confirm closed the window")
	_check(confirm_spy.confirmed == 1, "sell_confirm_confirmed fired exactly once (got %d)" % confirm_spy.confirmed)
	_check(confirm_spy.reverted == 0, "NO revert — a confirmed sale never reverts")
	_check(confirm_spy.started == 1, "started fired once (got %d)" % confirm_spy.started)

	# The timeout firing AFTER the confirm is a no-op (the sale already proceeded).
	_fire_timeout(bridge)
	_check(confirm_spy.confirmed == 1, "stale timeout after confirm does not re-trigger (still 1 confirmed)")
	_check(confirm_spy.reverted == 0, "stale timeout after confirm does not revert")


func _test_timer_stale_timeout_cannot_kill_new_window() -> void:
	print("\n[Timer] edge: stale timeout from a CANCELLED window cannot revert a NEWER window")

	var parts := _make_real_world()
	var ps: PlacementSystem = parts[1]
	var sel: SelectionSystem = parts[2]
	var bridge: SelectionInputBridge = parts[3]

	_place_treadmill(ps, Vector2i(1, 1))
	bridge.call("_unhandled_input", _click(_cell_px(Vector2i(1, 1))))
	var confirm_spy := ConfirmSpy.new()
	bridge.sell_confirm_started.connect(confirm_spy.on_started)
	bridge.sell_confirm_reverted.connect(confirm_spy.on_reverted)
	bridge.sell_confirm_confirmed.connect(confirm_spy.on_confirmed)

	# Window A: request → Esc (revert only). Generation captured at A's start.
	bridge.request_sell_confirm()
	var gen_a: int = bridge.get("_timer_generation")
	bridge.on_esc_pressed()
	_check(not bridge.is_sell_confirm_pending(), "precondition — window A reverted")
	# NOTE: window A's Esc-revert is a LEGITIMATE sell_confirm_reverted
	# emission (count 1). The stale-timer invariant below is that A's
	# timeout does NOT add a second one.

	# Window B: a new request bumps the generation.
	bridge.request_sell_confirm()
	var gen_b: int = bridge.get("_timer_generation")
	_check(gen_b != gen_a, "new window bumped the generation (%d → %d)" % [gen_a, gen_b])
	_check(bridge.is_sell_confirm_pending(), "precondition — window B open")

	# Window A's stale timer fires with A's generation → must NOT kill B.
	var reverted_before: int = confirm_spy.reverted
	bridge.call("_on_sell_confirm_timeout", gen_a)
	_check(bridge.is_sell_confirm_pending(), "stale A-timeout did NOT close window B (generation guard)")
	_check(confirm_spy.reverted == reverted_before, "stale A-timeout added NO spurious revert (was %d, still %d)" % [reverted_before, confirm_spy.reverted])

	# B's own timeout (current generation) closes B.
	_fire_timeout(bridge)
	_check(not bridge.is_sell_confirm_pending(), "B's own timeout closed window B")
	_check(confirm_spy.reverted == reverted_before + 1, "revert fired exactly once for B (got %d)" % confirm_spy.reverted)


func _test_timer_render_time_process_always() -> void:
	print("\n[Timer] edge: timer wiring is render-time, not tick-gated (process_always=true, fires while paused)")

	# A live SceneTreeTimer cannot be created in a --script SceneTree _init
	# context (get_tree() is null for nodes there — probe-verified), so the
	# render-time wiring is verified by script-source inspection, the same
	# evidence pattern the placement bridge test uses for the _process
	# absence. The RUNTIME timer semantics (timeout → revert, confirm →
	# proceed, stale-timeout guard) are covered by the direct-call tests.
	var script: Script = load(BRIDGE_SCRIPT_PATH) as Script
	var source: String = script.source_code

	_check(
		source.contains("tree.create_timer(_sell_confirm_duration, true)"),
		"_start_sell_confirm_timer creates the timer with process_always=true (render-time — fires even while the sim is paused)"
	)
	_check(
		source.contains("timer.timeout.connect(_on_sell_confirm_timeout.bind(generation))"),
		"the timeout handler is connected with the generation bind (stale-timer guard)"
	)
	# The default value when the bridge is NOT in the tree: no timer object,
	# but the direct-call path remains fully functional (covered above).
	var parts := _make_real_world()
	var bridge: SelectionInputBridge = parts[3]
	_check(bridge.get("_sell_confirm_timer") == null, "no timer object when the bridge is not in the tree (headless direct-call path)")


# === Keyboard: focus-independent routing ===

func _test_keyboard_other_keys_ignored_and_echo() -> void:
	print("\n[keys] unrelated keys ignored; echo repeats ignored (dual-focus hotkeys)")

	var parts := _make_real_world()
	var ps: PlacementSystem = parts[1]
	var sel: SelectionSystem = parts[2]
	var bridge: SelectionInputBridge = parts[3]

	_place_treadmill(ps, Vector2i(1, 1))
	bridge.call("_unhandled_input", _click(_cell_px(Vector2i(1, 1))))
	var confirm_spy := ConfirmSpy.new()
	bridge.sell_confirm_started.connect(confirm_spy.on_started)
	bridge.sell_confirm_reverted.connect(confirm_spy.on_reverted)

	# Unrelated key A is ignored.
	bridge.call("_unhandled_key_input", _key(KEY_A))
	_check(not bridge.is_sell_confirm_pending(), "KEY_A does not open a confirm window")
	_check(sel.get_selected_instance_id() == 0, "selection unchanged by KEY_A")

	# Echo repeats of Esc are ignored (a held key must not re-trigger).
	var esc := _key(KEY_ESCAPE)
	esc.echo = true
	bridge.call("_unhandled_key_input", esc)
	_check(sel.get_selected_instance_id() == 0, "Esc echo repeat ignored — selection stays")

	# Echo repeats of Del are ignored.
	var del := _key(KEY_DELETE)
	del.echo = true
	bridge.call("_unhandled_key_input", del)
	_check(not bridge.is_sell_confirm_pending(), "Del echo repeat ignored — no window opened")

	# Key RELEASE (pressed=false) is ignored.
	var release := _key(KEY_ESCAPE)
	release.pressed = false
	bridge.call("_unhandled_key_input", release)
	_check(sel.get_selected_instance_id() == 0, "Esc key-release ignored — selection stays")


# === Click-away reverts pending, then resolves normally ===

func _test_click_away_reverts_pending_then_resolves() -> void:
	print("\n[click-away] grid click while pending → confirm reverts, then the click resolves (empty floor deselects)")

	var parts := _make_real_world()
	var ps: PlacementSystem = parts[1]
	var sel: SelectionSystem = parts[2]
	var bridge: SelectionInputBridge = parts[3]

	_place_treadmill(ps, Vector2i(1, 1))
	bridge.call("_unhandled_input", _click(_cell_px(Vector2i(1, 1))))
	var confirm_spy := ConfirmSpy.new()
	bridge.sell_confirm_started.connect(confirm_spy.on_started)
	bridge.sell_confirm_reverted.connect(confirm_spy.on_reverted)
	bridge.sell_confirm_confirmed.connect(confirm_spy.on_confirmed)
	bridge.request_sell_confirm()
	_check(bridge.is_sell_confirm_pending(), "precondition — window open")

	# Click empty floor while pending: revert + normal resolution (deselect).
	bridge.call("_unhandled_input", _click(_cell_px(Vector2i(5, 5))))

	_check(not bridge.is_sell_confirm_pending(), "click-away closed the confirm window")
	_check(confirm_spy.reverted == 1, "sell_confirm_reverted fired (click-away, got %d)" % confirm_spy.reverted)
	_check(confirm_spy.confirmed == 0, "no sale")
	_check(sel.get_selected_instance_id() == -1, "the empty-floor click ALSO resolved normally (deselect)")


# === Move-during-drag guard (AC27) ===

func _test_move_blocked_during_drag() -> void:
	print("\n[Move guard] is_move_blocked() true while PlacementSystem is DRAGGING (AC27)")

	var parts := _make_real_world()
	var ps: PlacementSystem = parts[1]
	var bridge: SelectionInputBridge = parts[3]

	_check(not bridge.is_move_blocked(), "not blocked when IDLE")

	ps.begin_drag("treadmill_01")
	_check(ps.is_dragging(), "precondition — drag in flight")
	_check(bridge.is_move_blocked(), "Move blocked while PlacementSystem is DRAGGING")

	ps.on_cancel()
	_check(not bridge.is_move_blocked(), "Move unblocked after the drag ends")


# === Ownership: bridge freed → system survives ===

# === External invalidation reverts pending (GDD states table / AC11) ===

func _test_external_invalidation_reverts_pending() -> void:
	print("\n[external] selected piece removed by another path while pending → confirm reverts (no sale)")

	var parts := _make_real_world()
	var grid: GridSystem = parts[0]
	var ps: PlacementSystem = parts[1]
	var sel: SelectionSystem = parts[2]
	var bridge: SelectionInputBridge = parts[3]

	var placed_id := _place_treadmill(ps, Vector2i(1, 1))
	bridge.call("_unhandled_input", _click(_cell_px(Vector2i(1, 1))))
	_check(sel.get_selected_instance_id() == placed_id, "precondition — piece selected")
	var confirm_spy := ConfirmSpy.new()
	bridge.sell_confirm_started.connect(confirm_spy.on_started)
	bridge.sell_confirm_reverted.connect(confirm_spy.on_reverted)
	bridge.sell_confirm_confirmed.connect(confirm_spy.on_confirmed)
	bridge.request_sell_confirm()
	_check(bridge.is_sell_confirm_pending(), "precondition — confirm window open")

	# External removal: GridSystem.clear() (a sale via another path, or a
	# load-time reconcile) → grid_changed → SelectionSystem clears selection
	# → selection_changed(null) fires (AC11).
	grid.clear(placed_id)

	_check(not bridge.is_sell_confirm_pending(), "external invalidation closed the confirm window")
	_check(confirm_spy.reverted == 1, "sell_confirm_reverted fired exactly once (got %d)" % confirm_spy.reverted)
	_check(confirm_spy.confirmed == 0, "NO sell_confirm_confirmed — no sale of a removed piece")
	_check(sel.get_selected_instance_id() == -1, "selection cleared by the system (AC11)")


func _test_ownership_survives_bridge_free() -> void:
	print("\n[AC bridge] bridge Node destroyed (scene transition) → SelectionSystem NOT freed, selection survives")

	var grid := _make_open_grid(10, 10)
	var cat := _make_catalog([_make_def(_ED(), "treadmill_01")])
	var orch := SimulationOrchestrator.new()
	orch.grid_system = grid
	orch.equipment_catalog = cat
	orch.init()
	root.add_child(orch)
	var bridge: Node = orch.get_node_or_null("SelectionInputBridge")
	_check(bridge != null, "composition root booted with selection bridge")
	if bridge == null:
		orch.free()
		return

	# Make a REAL selection through the bridge first.
	var ps: PlacementSystem = orch.placement_system
	_place_treadmill(ps, Vector2i(1, 1))
	bridge.call("_unhandled_input", _click(_cell_px(Vector2i(1, 1))))
	_check(orch.selection_system.get_selected_instance_id() == 0, "selection made through the bridge")

	# Simulate a scene transition: destroy the bridge Node.
	var system_ref: RefCounted = orch.selection_system
	bridge.free()

	_check(is_instance_valid(system_ref), "SelectionSystem still valid after bridge free (freed-object detection)")
	_check(system_ref.get_selected_instance_id() == 0, "selection state survives bridge destruction")
	_check(orch.selection_system == system_ref, "composition root still holds the SAME system instance")

	orch.free()


# === No _process polling ===

func _test_no_process_polling() -> void:
	print("\n[TR-SEL-008] the bridge is event-driven — no _process() polling path")

	var methods: Array = _bridge_script_methods()
	_check(methods.has("_unhandled_input"), "bridge defines _unhandled_input (mouse path)")
	_check(methods.has("_unhandled_key_input"), "bridge defines _unhandled_key_input (keyboard path)")
	_check(not methods.has("_process"), "bridge defines NO _process — no per-frame polling path exists")


# === Data-driven duration (clamped) ===

func _test_sell_confirm_duration_config_clamp() -> void:
	print("\n[config] sell_confirm_duration is data-driven and clamped to the GDD safe range (1.5–3.0s)")

	var grid := _make_open_grid(10, 10)
	var cat := _make_catalog([_make_def(_ED(), "treadmill_01")])
	var ps := PlacementSystem.new()
	ps.init(grid, cat)
	var sel := SelectionSystem.new()
	sel.init(grid, ps, cat)
	sel._post_init()

	var B: Script = load(BRIDGE_SCRIPT_PATH) as Script

	# Default 2.0s.
	var b1: SelectionInputBridge = B.new()
	b1.init(sel, grid, CELL_SIZE, ps)
	_check(absf(float(b1.get("_sell_confirm_duration")) - 2.0) < 0.001, "default duration is 2.0s (got %s)" % b1.get("_sell_confirm_duration"))
	_nodes_to_free.append(b1)

	# Too long → clamped to 3.0.
	var b2: SelectionInputBridge = B.new()
	b2.init(sel, grid, CELL_SIZE, ps, {"sell_confirm_duration": 10.0})
	_check(absf(float(b2.get("_sell_confirm_duration")) - 3.0) < 0.001, "10.0s clamped to 3.0s (got %s)" % b2.get("_sell_confirm_duration"))
	_nodes_to_free.append(b2)

	# Too short → clamped to 1.5.
	var b3: SelectionInputBridge = B.new()
	b3.init(sel, grid, CELL_SIZE, ps, {"sell_confirm_duration": 0.1})
	_check(absf(float(b3.get("_sell_confirm_duration")) - 1.5) < 0.001, "0.1s clamped to 1.5s (got %s)" % b3.get("_sell_confirm_duration"))
	_nodes_to_free.append(b3)

	# In-range value passes through.
	var b4: SelectionInputBridge = B.new()
	b4.init(sel, grid, CELL_SIZE, ps, {"sell_confirm_duration": 1.8})
	_check(absf(float(b4.get("_sell_confirm_duration")) - 1.8) < 0.001, "1.8s passes through unclamped (got %s)" % b4.get("_sell_confirm_duration"))
	_nodes_to_free.append(b4)
