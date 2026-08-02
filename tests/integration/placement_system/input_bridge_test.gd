# tests/integration/placement_system/input_bridge_test.gd
# Story PL-007: Input Bridge and Event Forwarding
# Covers the BLOCKING ACs:
#   TR-PS-011 — after composition-root boot, PlacementInputBridge is a child
#               Node of SimulationOrchestrator (not the presentation layer)
#               and forwards input events as parsed method calls (grid cells,
#               never screen pixels).
#   TR-PS-012 — mouse-move preview forwarding uses InputEventMouseMotion;
#               can_place()/world_to_grid() fire only when the hovered cell
#               actually changes, never via _process() polling.
#   AC(bridge) — screen position P → PlacementSystem receives the grid cell
#                GridSystem.world_to_grid(P); raw P never reaches the system.
#   AC(bridge) — bridge Node destroyed/recreated (scene transition) →
#                PlacementSystem NOT silently freed; composition root holds
#                the strong reference; DRAGGING state survives (verified via
#                freed-object detection).
#
# Design notes:
#   - The bridge is tested with SYNTHETIC InputEvent objects delivered through
#     its engine callbacks (_unhandled_input / _unhandled_key_input /
#     _notification), matching the story's "headless SceneTree with a
#     simulated event" requirement.
#   - Two construction paths are exercised:
#       (a) full composition-root boot (SimulationOrchestrator with a
#           pre-injected grid) — TR-PS-011 ownership + AC bridge ownership;
#       (b) direct bridge construction with spy system/grid — precise
#           cell-vs-pixel and no-polling assertions.
#   - "No _process() polling" evidence is two-fold:
#       (1) script-method inspection: the bridge script defines
#           _unhandled_input but NOT _process (a _process override would be
#           the polling path);
#       (2) spy counters: can_place re-fires only on cell change;
#           world_to_grid fires per motion EVENT, never per frame (there is
#           no per-frame path to call it).
#   - Raw-pixel exclusion evidence: a SpyPlacementSystem records the typeof()
#   of every argument received across the 6 forwarded methods — the suite
#   asserts no TYPE_VECTOR2 ever arrives (the system's cell-typed API is the
#   final gate; the bridge never even attempts a pixel call).
# Run standalone: godot --headless --script tests/integration/placement_system/input_bridge_test.gd
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"

const BRIDGE_SCRIPT_PATH := "res://src/systems/placement_input_bridge.gd"
const PS_SCRIPT_PATH := "res://src/systems/placement_system.gd"
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
	print("  INTEGRATION TEST: PlacementInputBridge — Event Forwarding (PL-007)")
	print("=".repeat(48))

	_test_tr_ps_011_bridge_child_of_orchestrator()
	_test_tr_ps_011_forwards_parsed_calls()
	_test_ac_bridge_screen_to_cell_never_raw_pixels()
	_test_ac_bridge_screen_to_cell_boundary_and_oob()
	_test_tr_ps_012_motion_no_polling_cell_change_only()
	_test_tr_ps_012_same_cell_no_refire()
	_test_bridge_keyboard_esc_r()
	_test_bridge_focus_loss()
	_test_ac_bridge_ownership_survives_bridge_free()
	_test_all_six_forwarded_methods_exist()

	_free_test_nodes()

	print("\n=== INPUT BRIDGE TEST: %d passed, %d failed ===\n" % [_pass, _fail])
	return {"pass": _pass, "fail": _fail}


func _check(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
		print("  PASS: " + msg)
	else:
		_fail += 1
		print("  FAIL: " + msg)


# === Spies / helpers ===

## Spy grid — counts world_to_grid + can_place calls and delegates to the real
## GridSystem implementation (super). The counts are the TR-PS-012
## "fires only when the cell changes / never per-frame" evidence; the
## super delegation keeps all real grid behavior.
class SpyGrid extends GridSystem:
	var world_to_grid_calls := 0
	var can_place_calls := 0

	func world_to_grid(world_pos: Vector2, cell_size: int) -> Vector2i:
		world_to_grid_calls += 1
		return super.world_to_grid(world_pos, cell_size)

	func can_place(
		footprint_cells: Array[Vector2i],
		access_cells: Array[Vector2i],
		anchor: Vector2i,
		rotation: Rotation
	) -> PlacementCheckResult:
		can_place_calls += 1
		return super.can_place(footprint_cells, access_cells, anchor, rotation)


## Spy system — records the typeof() of every argument received across the 6
## forwarded methods, delegating to the real PlacementSystem (super). The
## recorded arg types are the "raw P never reaches the system" evidence: if
## the bridge ever forwarded a screen pixel (Vector2), it would show up here
## as TYPE_VECTOR2. RefCounted class (NOT lambda closures — Godot 4.7.1
## pitfall: lambdas cannot write back outer-scope locals).
class SpyPlacementSystem extends PlacementSystem:
	var received_types: Array = []  # typeof() of every forwarded arg
	var mouse_moved_cells: Array = []  # every Vector2i cell forwarded
	var drag_starts: Array = []
	var rotate_presses := 0
	var drops := 0
	var cancels := 0
	var focus_losses := 0

	func begin_drag(equipment_id: String) -> void:
		drag_starts.append(equipment_id)
		received_types.append(typeof(equipment_id))
		super.begin_drag(equipment_id)

	func on_mouse_moved(cell: Vector2i) -> void:
		mouse_moved_cells.append(cell)
		received_types.append(typeof(cell))
		super.on_mouse_moved(cell)

	func on_rotate_pressed() -> void:
		rotate_presses += 1
		super.on_rotate_pressed()

	func on_drop() -> void:
		drops += 1
		super.on_drop()

	func on_cancel() -> void:
		cancels += 1
		super.on_cancel()

	func on_focus_lost() -> void:
		focus_losses += 1
		super.on_focus_lost()


## RefCounted signal counter for preview_validity_changed.
class PreviewCounter extends RefCounted:
	var emissions := 0
	var last_valid := false

	func on_preview(valid: bool) -> void:
		emissions += 1
		last_valid = valid


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
func _make_bridge(system: PlacementSystem, grid: GridSystem) -> PlacementInputBridge:
	var B: Script = load(BRIDGE_SCRIPT_PATH) as Script
	var bridge: PlacementInputBridge = B.new()
	bridge.init(system, grid, CELL_SIZE)
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


func _motion(pos: Vector2) -> InputEventMouseMotion:
	var ev := InputEventMouseMotion.new()
	ev.position = pos
	return ev


func _button(pos: Vector2, pressed: bool) -> InputEventMouseButton:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = pressed
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


## Scripts the bridge script defines. Used to prove _unhandled_input exists
## and _process does NOT (the polling path).
func _bridge_script_methods() -> Array:
	var script: Script = load(BRIDGE_SCRIPT_PATH) as Script
	var methods: Array = script.get_script_method_list()
	var names: Array = []
	for m in methods:
		names.append(m["name"])
	return names


# === TR-PS-011: bridge is a child of the composition root ===

func _test_tr_ps_011_bridge_child_of_orchestrator() -> void:
	print("\n[TR-PS-011] composition-root boot → PlacementInputBridge is a child of SimulationOrchestrator")

	var grid := _make_open_grid(10, 10)
	var orch := SimulationOrchestrator.new()
	orch.grid_system = grid  # pre-inject BEFORE init() — LevelLoader story pending
	# NOTE: in a SceneTree test script _ready() never fires synchronously
	# (the tree does not iterate inside _init()/run_all()), so init() is
	# called explicitly — the ADR-0001 two-phase entry point. _ready() would
	# do the same in a live game boot.
	orch.init()
	root.add_child(orch)

	var bridge: Node = orch.get_node_or_null("PlacementInputBridge")
	_check(bridge != null, "PlacementInputBridge node exists after boot")
	if bridge == null:
		orch.free()
		return
	_check(bridge.get_parent() == orch, "bridge parent is SimulationOrchestrator (not the presentation layer)")
	_check(orch.placement_system != null, "composition root holds placement_system as a RefCounted field")
	_check(
		bridge.get("_system") == orch.placement_system,
		"bridge forwards to the SAME PlacementSystem instance the composition root owns"
	)

	orch.free()


# === TR-PS-011: input arrives as parsed method calls (cells, not pixels) ===

func _test_tr_ps_011_forwards_parsed_calls() -> void:
	print("\n[TR-PS-011] input events arrive as parsed method calls — cells, not pixels")

	var grid := _make_open_grid(10, 10)
	var cat := _make_catalog([_make_def(_ED(), "treadmill_01")])
	var sys := SpyPlacementSystem.new()
	sys.init(grid, cat)
	var bridge := _make_bridge(sys, grid)

	# Drag start arrives as on_drag_start(equipment_id) — a String id, never a pixel.
	bridge.on_drag_start("treadmill_01")
	_check(sys.drag_starts == ["treadmill_01"], "on_drag_start(equipment_id) forwarded begin_drag with the id")

	# Mouse motion at screen P arrives as on_mouse_moved(world_to_grid(P)) — a cell.
	var p := Vector2(170, 100)  # world_to_grid(170,100)/32 == (5,3) per GDD D.4 example
	bridge.on_mouse_moved(grid.world_to_grid(p, CELL_SIZE))
	_check(sys.mouse_moved_cells.size() == 1, "on_mouse_moved(cell) forwarded once")
	if sys.mouse_moved_cells.size() == 1:
		_check(
			sys.mouse_moved_cells[0] == Vector2i(5, 3),
			"system received the CELL (5,3) for screen P=(170,100), not raw pixels (got %s)" % sys.mouse_moved_cells[0]
		)

	# The 6 parsed calls all land on the system as the right arg shapes.
	bridge.on_rotate_pressed()
	_check(sys.rotate_presses == 1, "on_rotate_pressed() forwarded")
	bridge.on_drop()
	_check(sys.drops == 1, "on_drop() forwarded")
	bridge.on_cancel()
	_check(sys.cancels == 1, "on_cancel() forwarded")
	bridge.on_focus_lost()
	_check(sys.focus_losses == 1, "on_focus_lost() forwarded")

	# No TYPE_VECTOR2 (raw pixels) anywhere in what the system received.
	var has_pixels := false
	for t in sys.received_types:
		if t == TYPE_VECTOR2:
			has_pixels = true
	_check(not has_pixels, "raw screen pixels (TYPE_VECTOR2) NEVER reach the system (received %s)" % [sys.received_types])


# === AC(bridge): screen position P → cell world_to_grid(P), never raw P ===

func _test_ac_bridge_screen_to_cell_never_raw_pixels() -> void:
	print("\n[AC bridge] synthetic InputEventMouseButton at P → system receives world_to_grid(P)")

	var grid := _make_open_grid(10, 10)
	var cat := _make_catalog([_make_def(_ED(), "treadmill_01")])
	var sys := SpyPlacementSystem.new()
	sys.init(grid, cat)
	var bridge := _make_bridge(sys, grid)
	bridge.on_drag_start("treadmill_01")

	# Synthetic press at screen position P over the grid.
	var p := Vector2(96, 160)  # /32 → cell (3,5)
	bridge.call("_unhandled_input", _button(p, true))

	_check(sys.mouse_moved_cells.size() == 1, "press at P forwarded one cell call (got %d)" % sys.mouse_moved_cells.size())
	if sys.mouse_moved_cells.size() == 1:
		_check(
			sys.mouse_moved_cells[0] == Vector2i(3, 5),
			"system received cell (3,5) == world_to_grid(P), NOT the raw position %s" % p
		)

	# Release at the same P → on_drop (mouse-up commits).
	bridge.call("_unhandled_input", _button(p, false))
	_check(sys.drops == 1, "mouse-up at P forwarded on_drop()")

	# Every forwarded arg across the whole exchange is a cell/id — never a pixel.
	var has_pixels := false
	for t in sys.received_types:
		if t == TYPE_VECTOR2:
			has_pixels = true
	_check(not has_pixels, "raw P never reached the system (all args: %s)" % [sys.received_types])


func _test_ac_bridge_screen_to_cell_boundary_and_oob() -> void:
	print("\n[AC bridge] edge: P at grid boundary; P outside grid")

	var grid := _make_open_grid(10, 10)
	var cat := _make_catalog([_make_def(_ED(), "treadmill_01")])
	var sys := SpyPlacementSystem.new()
	sys.init(grid, cat)
	var bridge := _make_bridge(sys, grid)
	bridge.on_drag_start("treadmill_01")

	# P at the exact bottom-right boundary (319,319) → cell (9,9) — in-bounds.
	bridge.call("_unhandled_input", _motion(Vector2(319, 319)))
	_check(
		sys.mouse_moved_cells.size() == 1 and sys.mouse_moved_cells[0] == Vector2i(9, 9),
		"P=(319,319) → in-bounds cell (9,9) (got %s)" % [sys.mouse_moved_cells]
	)

	# P outside the grid (negative) → out-of-bounds cell (-1,-1) reaches the
	# system (world_to_grid's documented no-clamp contract); the system's own
	# drop handling decides cancel-vs-reject. raw P still never arrives.
	bridge.call("_unhandled_input", _motion(Vector2(-5, -5)))
	_check(
		sys.mouse_moved_cells.size() == 2 and sys.mouse_moved_cells[1] == Vector2i(-1, -1),
		"P=(-5,-5) → out-of-bounds cell (-1,-1) (world_to_grid no-clamp; got %s)" % [sys.mouse_moved_cells]
	)

	var has_pixels := false
	for t in sys.received_types:
		if t == TYPE_VECTOR2:
			has_pixels = true
	_check(not has_pixels, "no raw pixels across boundary/OOB events")


# === TR-PS-012: InputEventMouseMotion, no _process polling, cell-change only ===

func _test_tr_ps_012_motion_no_polling_cell_change_only() -> void:
	print("\n[TR-PS-012] mouse-move preview via InputEventMouseMotion — no _process() polling")

	var grid := SpyGrid.new()
	grid.init(10, 10)
	for y in 10:
		for x in 10:
			grid.set_buildable(Vector2i(x, y), true)
	grid.freeze_buildable()
	var cat := _make_catalog([_make_def(_ED(), "treadmill_01")])
	var sys := SpyPlacementSystem.new()
	sys.init(grid, cat)
	var counter := PreviewCounter.new()
	sys.preview_validity_changed.connect(counter.on_preview)
	var bridge := _make_bridge(sys, grid)
	bridge.on_drag_start("treadmill_01")

	# Mouse moves to cell (3,3) → one can_place, one preview.
	bridge.call("_unhandled_input", _motion(_cell_px(Vector2i(3, 3))))
	_check(grid.can_place_calls == 1, "first motion into (3,3) ran can_place once (got %d)" % grid.can_place_calls)
	_check(counter.emissions == 1, "preview_validity_changed emitted once")

	# Mouse moves to cell (4,3) → new cell → can_place fires again exactly once.
	bridge.call("_unhandled_input", _motion(_cell_px(Vector2i(4, 3))))
	_check(grid.can_place_calls == 2, "motion into (4,3) ran can_place once more (got %d)" % grid.can_place_calls)

	# Script-method evidence: the bridge defines _unhandled_input but NOT _process.
	var methods: Array = _bridge_script_methods()
	_check(methods.has("_unhandled_input"), "bridge script defines _unhandled_input (the motion path)")
	_check(not methods.has("_process"), "bridge script defines NO _process — no per-frame polling path exists")

	# world_to_grid fires per motion EVENT (the conversion must run to know the
	# cell), and never per-frame — there is no _process override to call it.
	_check(grid.world_to_grid_calls == 2, "world_to_grid fired per motion event only (got %d)" % grid.world_to_grid_calls)


func _test_tr_ps_012_same_cell_no_refire() -> void:
	print("\n[TR-PS-012] edge: mouse moves within the same cell → no re-fire")

	var grid := SpyGrid.new()
	grid.init(10, 10)
	for y in 10:
		for x in 10:
			grid.set_buildable(Vector2i(x, y), true)
	grid.freeze_buildable()
	var cat := _make_catalog([_make_def(_ED(), "treadmill_01")])
	var sys := SpyPlacementSystem.new()
	sys.init(grid, cat)
	var counter := PreviewCounter.new()
	sys.preview_validity_changed.connect(counter.on_preview)
	var bridge := _make_bridge(sys, grid)
	bridge.on_drag_start("treadmill_01")

	# Three motions INSIDE cell (3,3): (3*32+1, 3*32+1), (3*32+10, 3*32+20), (3*32+31, 3*32+31).
	bridge.call("_unhandled_input", _motion(Vector2(97, 97)))
	bridge.call("_unhandled_input", _motion(Vector2(106, 116)))
	bridge.call("_unhandled_input", _motion(Vector2(127, 127)))
	_check(grid.can_place_calls == 1, "3 same-cell motions → can_place ran exactly once (got %d)" % grid.can_place_calls)
	_check(counter.emissions == 1, "3 same-cell motions → preview emitted exactly once (got %d)" % counter.emissions)
	_check(sys.mouse_moved_cells.size() == 1, "system received exactly one on_mouse_moved for the whole cell (got %d)" % sys.mouse_moved_cells.size())

	# A later motion to a NEW cell still fires.
	bridge.call("_unhandled_input", _motion(_cell_px(Vector2i(5, 3))))
	_check(grid.can_place_calls == 2, "motion to a new cell after same-cell spam → can_place fires again (got %d)" % grid.can_place_calls)


# === Keyboard (Godot 4.6 dual-focus): Esc cancel, R rotate ===

func _test_bridge_keyboard_esc_r() -> void:
	print("\n[keys] _unhandled_key_input: Esc → on_cancel, R → on_rotate_pressed")

	var grid := _make_open_grid(10, 10)
	var cat := _make_catalog([_make_def(_ED(), "treadmill_01")])
	var sys := SpyPlacementSystem.new()
	sys.init(grid, cat)
	var bridge := _make_bridge(sys, grid)
	bridge.on_drag_start("treadmill_01")

	bridge.call("_unhandled_key_input", _key(KEY_R))
	_check(sys.rotate_presses == 1, "R key forwarded on_rotate_pressed()")

	bridge.call("_unhandled_key_input", _key(KEY_ESCAPE))
	_check(sys.cancels == 1, "Esc key forwarded on_cancel()")

	# Echo repeats are ignored (held key must not re-trigger).
	var echo := _key(KEY_ESCAPE)
	echo.echo = true
	bridge.call("_unhandled_key_input", echo)
	_check(sys.cancels == 1, "Esc echo repeat ignored (still 1 cancel)")

	# Other keys are ignored.
	bridge.call("_unhandled_key_input", _key(KEY_A))
	_check(sys.rotate_presses == 1 and sys.cancels == 1, "unrelated key A ignored")


# === Focus loss → on_focus_lost ===

func _test_bridge_focus_loss() -> void:
	print("\n[focus] NOTIFICATION_WM_WINDOW_FOCUS_OUT → on_focus_lost()")

	var grid := _make_open_grid(10, 10)
	var cat := _make_catalog([_make_def(_ED(), "treadmill_01")])
	var sys := SpyPlacementSystem.new()
	sys.init(grid, cat)
	var bridge := _make_bridge(sys, grid)

	bridge.call("_notification", Node.NOTIFICATION_WM_WINDOW_FOCUS_OUT)
	_check(sys.focus_losses == 1, "focus-out notification forwarded on_focus_lost()")

	# Other notifications do not forward.
	bridge.call("_notification", Node.NOTIFICATION_WM_WINDOW_FOCUS_IN)
	_check(sys.focus_losses == 1, "focus-IN notification does not forward on_focus_lost()")


# === AC(bridge): bridge freed → system survives, DRAGGING state intact ===

func _test_ac_bridge_ownership_survives_bridge_free() -> void:
	print("\n[AC bridge] bridge Node destroyed (scene transition) → PlacementSystem NOT freed, DRAGGING survives")

	var grid := _make_open_grid(10, 10)
	var cat := _make_catalog([_make_def(_ED(), "treadmill_01")])

	# Boot the REAL composition root so the orchestrator field is the strong ref.
	var orch := SimulationOrchestrator.new()
	orch.grid_system = grid
	orch.equipment_catalog = cat  # prepared catalog with the treadmill def
	orch.init()  # explicit two-phase init (see note in boot test above)
	root.add_child(orch)
	var bridge: Node = orch.get_node_or_null("PlacementInputBridge")
	_check(bridge != null, "composition root booted with bridge")
	if bridge == null:
		orch.free()
		return

	# Start a REAL drag through the bridge → DRAGGING.
	bridge.call("on_drag_start", "treadmill_01")
	_check(orch.placement_system.is_dragging(), "drag started via bridge — system is DRAGGING")

	# Simulate a scene transition: destroy the bridge Node.
	var system_ref: RefCounted = orch.placement_system
	bridge.free()

	# Freed-object detection: the system must still be alive...
	_check(is_instance_valid(system_ref), "PlacementSystem still valid after bridge free (freed-object detection)")
	# ...and its DRAGGING state must survive.
	_check(system_ref.is_dragging(), "DRAGGING state survives bridge destruction")

	# The composition root still holds the strong reference.
	_check(orch.placement_system == system_ref, "composition root still holds the SAME system instance")

	orch.free()


# === All 6 forwarded methods exist on the bridge ===

func _test_all_six_forwarded_methods_exist() -> void:
	print("\n[TR-PS-011 edge] all 6 forwarded calls exist on the bridge")

	var grid := _make_open_grid(10, 10)
	var cat := _make_catalog([_make_def(_ED(), "treadmill_01")])
	var sys := SpyPlacementSystem.new()
	sys.init(grid, cat)
	var bridge := _make_bridge(sys, grid)

	_check(bridge.has_method("on_drag_start"), "on_drag_start(equipment_id) exists")
	_check(bridge.has_method("on_mouse_moved"), "on_mouse_moved(cell) exists")
	_check(bridge.has_method("on_rotate_pressed"), "on_rotate_pressed() exists")
	_check(bridge.has_method("on_drop"), "on_drop() exists")
	_check(bridge.has_method("on_cancel"), "on_cancel() exists")
	_check(bridge.has_method("on_focus_lost"), "on_focus_lost() exists")
