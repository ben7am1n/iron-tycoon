# tests/unit/selection_system/toolbar_state_test.gd
# Story SEL-004: Contextual Toolbar & Selection Cue
# (production/epics/selection-system/story-004-contextual-toolbar-selection-cue.md)
#
# Covers the BLOCKING ACs / UX AC for the toolbar half:
#   AC4    — a selection, Move pressed → SelectionSystem's cue clears
#            (selection released, selection_changed(null) fires) AND
#            PlacementSystem's relocate-ghost appears at that instance's
#            position within one frame (begin_relocate synchronous →
#            DRAGGING state + grid cleared in the same call)
#   UX AC  — Inspect / Move / Sell visible near the piece when selected;
#            Move DISABLED during an active placement drag
#            (bridge.is_move_blocked() → PlacementSystem.is_dragging())
#   Core Rule 3 — Move hands off to PlacementSystem.begin_relocate;
#            SelectionSystem clears its own selection the INSTANT Move is
#            pressed (no dual-ownership ambiguity)
#   Sell morph — Sell pressed → bridge soft-confirm window opens
#            (sell_confirm_started → label "Confirm sell +$X" with the
#            EXACT refund); confirm → the sale completes via the
#            composition-root connection (sell_confirm_confirmed →
#            sell_selected); revert (timeout/Esc) → label back to "Sell"
#   Inspect  — always available → inspect_requested signal with the full
#            selection payload (the Info Panel #17 open hook)
#   reduced-motion — no enter/exit animation (instant show/hide)
#
# Plus the story QA edge: Move while PlacementSystem already dragging →
# button disabled (and the handler is a defensive no-op).
#
# Run standalone: godot --headless --script tests/unit/selection_system/toolbar_state_test.gd
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"

const TOOLBAR_SCRIPT := "res://src/ui/selection_toolbar.gd"
const SEL_SCRIPT := "res://src/systems/selection_system.gd"
const BRIDGE_SCRIPT := "res://src/systems/selection_input_bridge.gd"
const PLACEMENT_SCRIPT := "res://src/systems/placement_system.gd"
const GRID_SCRIPT := "res://src/systems/grid_system.gd"
const CATALOG_SCRIPT := "res://src/systems/equipment_catalog.gd"
const DEF_SCRIPT := "res://src/systems/equipment_def.gd"
const ECON_SCRIPT := "res://src/systems/economy.gd"
const UPGRADE_SCRIPT := "res://src/systems/equipment_upgrade_system.gd"
const SRG_SCRIPT := "res://src/systems/seeded_rng.gd"

const CELL_SIZE := 32
const VIEWPORT := Vector2(1280, 720)

## Sentinel distinguishing "argument not passed" from a real null — the
## deselect emit passes exactly ONE argument (TR-SEL-004 arity contract).
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
	print("  UNIT TEST: SelectionToolbar — Contextual Toolbar State (SEL-004)")
	print("=".repeat(48))

	_test_hidden_with_no_selection()
	_test_visible_when_selected()
	_test_upgrade_button_cost_and_purchase()
	_test_buttons_near_piece_anchor()
	_test_ac4_move_clears_selection_and_hands_off()
	_test_ac4_relocate_ghost_picks_up_piece()
	_test_move_disabled_during_drag()
	_test_move_during_drag_handler_noop()
	_test_move_with_no_selection_noop()
	_test_sell_morph_started_label_refund()
	_test_sell_confirm_completes_sale()
	_test_sell_revert_restores_label()
	_test_inspect_emits_hook()
	_test_swap_moves_toolbar_directly()
	_test_deselect_hides_toolbar()
	_test_reduced_motion_instant()
	_test_double_init_guard()

	_free_test_nodes()

	print("\n=== SEL-004 Toolbar State: %d passed, %d failed ===\n" % [_pass, _fail])
	return {"pass": _pass, "fail": _fail}


func _check(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
		print("  PASS: " + msg)
	else:
		_fail += 1
		print("  FAIL: " + msg)


# === Spies ===

## Spy on selection_changed — counts selects/deselects (arity contract).
class SelectionSpy:
	extends RefCounted
	var emissions: Array = []  # each: [a, b, c, d]

	func _on_selection_changed(a = NO_ARG, b = NO_ARG, c = NO_ARG, d = NO_ARG) -> void:
		emissions.append([a, b, c, d])

	func deselect_count() -> int:
		var n := 0
		for e in emissions:
			if e[0] == null:
				n += 1
		return n


## Spy on the toolbar's inspect_requested open hook — records the payload.
class InspectSpy:
	extends RefCounted
	var emissions: Array = []

	func _on_inspect_requested(instance_id: int, equipment_def, cell: Vector2i, rotation: int) -> void:
		emissions.append([instance_id, equipment_def, cell, rotation])


func _spy_for(sel: RefCounted) -> SelectionSpy:
	var spy := SelectionSpy.new()
	sel.connect("selection_changed", Callable(spy, "_on_selection_changed"))
	return spy


# === World builders (real systems, no mocks) ===

func _ED() -> Script:
	return load(DEF_SCRIPT) as Script


## 1×1 piece with the given cost + zone (tint derivation input for the cue;
## the toolbar only needs cost for the refund label).
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


func _make_economy(seed: int) -> RefCounted:
	var srg: RefCounted = (load(SRG_SCRIPT) as Script).new()
	srg.call("init", seed)
	var orch: Node = load("res://src/systems/simulation_orchestrator.gd").new()
	root.add_child(orch)
	orch.call("_ready")
	_nodes_to_free.append(orch)
	var econ: RefCounted = (load(ECON_SCRIPT) as Script).new()
	econ.call("init", orch, srg)
	orch.set("economy", econ)
	return econ


func _make_selection(grid: RefCounted, placement: RefCounted, catalog: RefCounted, economy: RefCounted) -> RefCounted:
	var sel: RefCounted = (load(SEL_SCRIPT) as Script).new()
	sel.call("init", grid, placement, catalog, economy)
	sel.call("_post_init")
	return sel


## Bridge wired like the composition root: merged init signature + the
## sell_confirm_confirmed → sell_selected typed connection.
func _make_bridge(sel: RefCounted, grid: RefCounted, placement: RefCounted):
	var bridge = (load(BRIDGE_SCRIPT) as Script).new()
	bridge.call("init", sel, grid, CELL_SIZE, placement)
	bridge.connect("sell_confirm_confirmed", Callable(sel, "sell_selected"))
	_nodes_to_free.append(bridge)
	return bridge


## The SelectionToolbar Control, added to the tree (so tweens/visibility
## behave like runtime) and init'd with the full rig. Returned untyped so
## tests can call its query surface dynamically.
func _make_toolbar(
	sel: RefCounted,
	bridge,
	placement: RefCounted,
	grid: RefCounted,
	economy: RefCounted,
	upgrade: RefCounted,
	config: Dictionary = {}
):
	var toolbar = (load(TOOLBAR_SCRIPT) as Script).new()
	root.add_child(toolbar)
	toolbar.call("init", sel, bridge, placement, grid, CELL_SIZE, config,
		Vector2.ZERO, VIEWPORT, Callable(), upgrade, economy)
	_nodes_to_free.append(toolbar)
	return toolbar


func _make_upgrade(grid: RefCounted) -> RefCounted:
	var upgrade: RefCounted = (load(UPGRADE_SCRIPT) as Script).new()
	upgrade.call("init", grid, {})
	return upgrade


## Places a piece via the REAL PlacementSystem flow → its instance_id.
func _place(ps: RefCounted, equipment_id: String, anchor: Vector2i) -> int:
	var id_before: int = ps.call("get_next_instance_id")
	ps.call("begin_drag", equipment_id)
	ps.call("on_mouse_moved", anchor)
	ps.call("on_drop")
	return id_before


## Standard rig: 12×10 open grid, catalog with the given defs, real
## selection + bridge + toolbar wired end-to-end.
func _make_world(costs: Array, zone: String = "cardio", config: Dictionary = {}) -> Dictionary:
	var defs: Array = []
	for c in costs:
		defs.append(_make_def(int(c), zone))
	var grid := _make_grid(12, 10)
	var catalog := _make_catalog(defs)
	var placement := _make_placement(grid, catalog)
	var economy := _make_economy(0x7004B)
	var upgrade := _make_upgrade(grid)
	var selection := _make_selection(grid, placement, catalog, economy)
	var bridge = _make_bridge(selection, grid, placement)
	var toolbar = _make_toolbar(selection, bridge, placement, grid, economy, upgrade, config)
	return {
		"grid": grid, "catalog": catalog, "placement": placement,
		"economy": economy, "selection": selection, "bridge": bridge,
		"toolbar": toolbar, "upgrade": upgrade,
	}


func _free_test_nodes() -> void:
	for n in _nodes_to_free:
		if is_instance_valid(n):
			n.free()
	_nodes_to_free.clear()


# === Visibility / anchoring ===

func _test_hidden_with_no_selection() -> void:
	print("\n[visibility] toolbar hidden with no selection")
	var w := _make_world([200])
	var toolbar = w["toolbar"]
	_check(not bool(toolbar.call("is_toolbar_active")), "visibility — toolbar not active before any selection")
	_check(not toolbar.visible, "visibility — Control.visible == false")


func _test_visible_when_selected() -> void:
	print("\n[visibility] selecting a piece shows the toolbar (Inspect/Move/Sell)")
	var w := _make_world([200])
	var placement: RefCounted = w["placement"]
	var selection: RefCounted = w["selection"]
	var toolbar = w["toolbar"]

	var id: int = _place(placement, "piece_200", Vector2i(3, 3))
	selection.call("on_cell_clicked", Vector2i(3, 3))
	_check(bool(toolbar.call("is_toolbar_active")), "visibility — toolbar active after selection")
	_check(int(toolbar.call("get_selected_instance_id")) == id, "visibility — toolbar holds the selected id")
	_check(toolbar.get_node("ToolbarRow/InspectButton") != null, "visibility — Inspect button built")
	_check(toolbar.get_node("ToolbarRow/UpgradeButton") != null, "visibility — Upgrade button built")
	_check(toolbar.get_node("ToolbarRow/MoveButton") != null, "visibility — Move button built")
	_check(toolbar.get_node("ToolbarRow/SellButton") != null, "visibility — Sell button built")


func _test_upgrade_button_cost_and_purchase() -> void:
	print("\n[A2] Upgrade button shows next level/cost and performs purchase")
	var w := _make_world([200])
	var id := _place(w["placement"], "piece_200", Vector2i(3, 3))
	w["selection"].call("on_cell_clicked", Vector2i(3, 3))
	_check(str(w["toolbar"].call("get_upgrade_label")) == "Upgrade L2 $100", "A2 — label shows L2 and $100 cost")
	_check(not bool(w["toolbar"].call("is_upgrade_disabled")), "A2 — affordable upgrade is enabled")
	w["toolbar"].call("_on_upgrade_pressed")
	_check(int(w["grid"].call("get_equipment_level", id)) == 2, "A2 — selected instance upgraded to L2")
	_check(int(w["economy"].get("balance")) == 400, "A2 — upgrade deducted $100")
	_check(str(w["toolbar"].call("get_upgrade_label")) == "Upgrade L3 $200", "A2 — label refreshes to next cost")


func _test_buttons_near_piece_anchor() -> void:
	print("\n[anchor] toolbar anchored near the piece, offset to a free side")
	var w := _make_world([200])
	var placement: RefCounted = w["placement"]
	var selection: RefCounted = w["selection"]
	var toolbar = w["toolbar"]

	# Piece at grid (3,3), cell 32 → footprint pixel rect x:[96,128) y:[96,128).
	_place(placement, "piece_200", Vector2i(3, 3))
	selection.call("on_cell_clicked", Vector2i(3, 3))
	var fp: Rect2 = toolbar.call("get_footprint_rect")
	_check(int(fp.position.x) == 96 and int(fp.position.y) == 96, "anchor — footprint rect at (96,96), got %s" % str(fp.position))
	# The toolbar is anchored to the RIGHT of the piece (the free side with
	# the most room in a 1280-wide viewport): its left edge is at the piece's
	# right edge + gap.
	var pos: Vector2 = toolbar.call("get_anchor_position")
	_check(pos.x >= 96 + 32 + 8, "anchor — toolbar sits right of the piece (x >= 136, got %.1f)" % pos.x)
	_check(pos.x < 96 + 32 + 64, "anchor — toolbar not far away (got %.1f)" % pos.x)
	_check(pos.y >= 96 - 8 and pos.y <= 96 + 32, "anchor — toolbar vertically aligned with the piece (y %.1f)" % pos.y)


# === AC4: Move handoff ===

func _test_ac4_move_clears_selection_and_hands_off() -> void:
	print("\n[AC4] Move pressed → selection cleared (cue released) + PlacementSystem owns the relocate")
	var w := _make_world([200])
	var placement: RefCounted = w["placement"]
	var selection: RefCounted = w["selection"]
	var toolbar = w["toolbar"]
	var spy := _spy_for(selection)

	var id: int = _place(placement, "piece_200", Vector2i(4, 4))
	selection.call("on_cell_clicked", Vector2i(4, 4))
	_check(int(selection.call("get_selected_instance_id")) == id, "AC4 — setup: piece selected")
	_check(not bool(placement.call("is_dragging")), "AC4 — setup: no drag in flight")

	# Press Move via the toolbar's handler (the button's pressed signal
	# routes here — Control Manifest typed connection).
	toolbar.call("_on_move_pressed")
	_check(int(selection.call("get_selected_instance_id")) == -1, "AC4 — selection cleared the INSTANT Move is pressed")
	_check(spy.deselect_count() == 1, "AC4 — selection_changed(null) fired once (cue released, got %d)" % spy.deselect_count())
	_check(bool(placement.call("is_dragging")), "AC4 — PlacementSystem is now DRAGGING (relocate in flight)")
	_check(not bool(toolbar.call("is_toolbar_active")), "AC4 — toolbar hidden after the handoff (no selection)")
	# The piece is off the grid during the relocate (picked up).
	_check(int(w["grid"].call("get_occupant_id", Vector2i(4, 4))) == -1, "AC4 — piece picked up from the grid (relocate ownership)")


func _test_ac4_relocate_ghost_picks_up_piece() -> void:
	print("\n[AC4] relocate-ghost appears at the instance's position within one frame (begin_relocate synchronous)")
	var w := _make_world([200])
	var placement: RefCounted = w["placement"]
	var selection: RefCounted = w["selection"]
	var toolbar = w["toolbar"]

	_place(placement, "piece_200", Vector2i(5, 5))
	selection.call("on_cell_clicked", Vector2i(5, 5))
	toolbar.call("_on_move_pressed")
	# begin_relocate is synchronous: the SAME call that clears the selection
	# also enters DRAGGING — so "within one frame" holds by construction.
	# The relocate holds the picked-up instance id (white-box: _relocate_id)
	# and the drag def — the ghost renders from PlacementSystem's drag state.
	_check(bool(placement.call("is_dragging")), "AC4 — ghost state: PlacementSystem DRAGGING after the handoff call returns")
	_check(int(placement.get("_relocate_id")) == 0, "AC4 — ghost state: relocate holds instance_id 0 (got %d)" % int(placement.get("_relocate_id")))
	_check(str(placement.get("_drag_def").id) == "piece_200", "AC4 — ghost state: drag def is the piece's def (got '%s')" % str(placement.get("_drag_def").id))


func _test_move_disabled_during_drag() -> void:
	print("\n[UX AC] Move disabled while PlacementSystem is dragging")
	var w := _make_world([200])
	var placement: RefCounted = w["placement"]
	var selection: RefCounted = w["selection"]
	var toolbar = w["toolbar"]

	# Select a piece, then start an unrelated placement drag (the palette
	# would have cleared the selection first per BSUI-003, but the toolbar
	# must still defend against a live drag — the UX AC).
	_place(placement, "piece_200", Vector2i(2, 2))
	selection.call("on_cell_clicked", Vector2i(2, 2))
	_check(not bool(toolbar.call("is_move_disabled")), "UX AC — Move enabled with no drag")
	placement.call("begin_drag", "piece_200")
	toolbar.call("_process", 0.0)  # per-frame poll (matches the runtime path)
	_check(bool(toolbar.call("is_move_disabled")), "UX AC — Move disabled while is_dragging() == true")
	# Drag ends → the next frame's poll re-enables Move (the per-frame poll
	# is ordering-independent: it re-queries AFTER the drag fully resolved).
	placement.call("on_mouse_moved", Vector2i(8, 8))
	placement.call("on_drop")
	_check(not bool(placement.call("is_dragging")), "UX AC — drag committed")
	toolbar.call("_process", 0.0)
	_check(not bool(toolbar.call("is_move_disabled")), "UX AC — Move re-enabled after the drag ends")


func _test_move_during_drag_handler_noop() -> void:
	print("\n[AC4 edge] Move pressed while a drag is in flight → handler is a defensive no-op")
	var w := _make_world([200])
	var placement: RefCounted = w["placement"]
	var selection: RefCounted = w["selection"]
	var toolbar = w["toolbar"]

	var id: int = _place(placement, "piece_200", Vector2i(2, 2))
	selection.call("on_cell_clicked", Vector2i(2, 2))
	placement.call("begin_drag", "piece_200")  # unrelated drag in flight
	var spy := _spy_for(selection)
	toolbar.call("_on_move_pressed")
	_check(int(selection.call("get_selected_instance_id")) == id, "AC4 edge — selection NOT cleared (no handoff during a drag)")
	_check(spy.deselect_count() == 0, "AC4 edge — no selection_changed(null) fired")
	_check(bool(placement.call("is_dragging")), "AC4 edge — the in-flight drag undisturbed")


func _test_move_with_no_selection_noop() -> void:
	print("\n[guard] Move with no selection → silent no-op")
	var w := _make_world([200])
	var selection: RefCounted = w["selection"]
	var placement: RefCounted = w["placement"]
	var toolbar = w["toolbar"]
	var spy := _spy_for(selection)

	toolbar.call("_on_move_pressed")
	_check(not bool(placement.call("is_dragging")), "guard — no drag started")
	_check(spy.emissions.size() == 0, "guard — no selection_changed emission")


# === Sell morph (Story 003 state machine rendered in the toolbar) ===

func _test_sell_morph_started_label_refund() -> void:
	print("\n[Sell] Sell pressed → button morphs to 'Confirm sell +$X' with the EXACT refund")
	var w := _make_world([350])
	var placement: RefCounted = w["placement"]
	var selection: RefCounted = w["selection"]
	var bridge = w["bridge"]
	var toolbar = w["toolbar"]

	_place(placement, "piece_350", Vector2i(3, 3))
	selection.call("on_cell_clicked", Vector2i(3, 3))
	_check(toolbar.call("get_sell_label") == "Sell", "Sell — label starts as 'Sell' (got '%s')" % toolbar.call("get_sell_label"))

	toolbar.call("_on_sell_pressed")
	_check(bool(bridge.call("is_sell_confirm_pending")), "Sell — bridge window opened (pending)")
	_check(toolbar.call("get_sell_label") == "Confirm sell +$175", "Sell — label morphed to 'Confirm sell +$175' (got '%s')" % toolbar.call("get_sell_label"))
	_check(bool(toolbar.call("is_sell_pending")), "Sell — is_sell_pending() true")


func _test_sell_confirm_completes_sale() -> void:
	print("\n[Sell] second click in the window → the sale completes (composition-root connection)")
	var w := _make_world([200])
	var grid: RefCounted = w["grid"]
	var placement: RefCounted = w["placement"]
	var economy: RefCounted = w["economy"]
	var selection: RefCounted = w["selection"]
	var bridge = w["bridge"]
	var toolbar = w["toolbar"]

	var id: int = _place(placement, "piece_200", Vector2i(2, 2))
	selection.call("on_cell_clicked", Vector2i(2, 2))
	toolbar.call("_on_sell_pressed")
	toolbar.call("_on_sell_pressed")  # second click → confirm
	_check(int(grid.call("get_occupant_id", Vector2i(2, 2))) == -1, "Sell — piece removed")
	_check(int(economy.get("balance")) == 600, "Sell — Economy credited refund 100 (balance %d)" % int(economy.get("balance")))
	_check(int(selection.call("get_selected_instance_id")) == -1, "Sell — selection cleared after the sale")
	_check(not bool(bridge.call("is_sell_confirm_pending")), "Sell — window closed")
	_check(not bool(toolbar.call("is_toolbar_active")), "Sell — toolbar hidden after the sale")


func _test_sell_revert_restores_label() -> void:
	print("\n[Sell] window reverts (Esc) → label back to 'Sell', no sale")
	var w := _make_world([200])
	var placement: RefCounted = w["placement"]
	var economy: RefCounted = w["economy"]
	var selection: RefCounted = w["selection"]
	var bridge = w["bridge"]
	var toolbar = w["toolbar"]

	_place(placement, "piece_200", Vector2i(3, 3))
	selection.call("on_cell_clicked", Vector2i(3, 3))
	toolbar.call("_on_sell_pressed")
	_check(toolbar.call("get_sell_label") != "Sell", "Sell — morphed before revert")
	bridge.call("on_esc_pressed")  # revert path (bridge owns the window)
	_check(toolbar.call("get_sell_label") == "Sell", "Sell — label restored to 'Sell' (got '%s')" % toolbar.call("get_sell_label"))
	_check(not bool(toolbar.call("is_sell_pending")), "Sell — no longer pending")
	_check(int(economy.get("balance")) == 500, "Sell — no sale (balance unchanged 500)")


# === Inspect (open hook) ===

func _test_inspect_emits_hook() -> void:
	print("\n[Inspect] Inspect pressed → inspect_requested with the full selection payload")
	var w := _make_world([200])
	var placement: RefCounted = w["placement"]
	var selection: RefCounted = w["selection"]
	var toolbar = w["toolbar"]
	var spy := InspectSpy.new()
	toolbar.connect("inspect_requested", Callable(spy, "_on_inspect_requested"))

	var id: int = _place(placement, "piece_200", Vector2i(4, 4))
	selection.call("on_cell_clicked", Vector2i(4, 4))
	toolbar.call("_on_inspect_pressed")
	_check(spy.emissions.size() == 1, "Inspect — inspect_requested fired once (got %d)" % spy.emissions.size())
	if spy.emissions.size() == 1:
		var payload: Array = spy.emissions[0]
		_check(int(payload[0]) == id, "Inspect — payload instance_id %d (got %d)" % [id, int(payload[0])])
		_check(payload[1] != null and str(payload[1].id) == "piece_200", "Inspect — payload carries the EquipmentDef")
		_check(payload[2] == Vector2i(4, 4), "Inspect — payload anchor cell (got %s)" % str(payload[2]))
		_check(int(payload[3]) == 0, "Inspect — payload rotation 0 (got %d)" % int(payload[3]))


# === Swap / deselect / reduced-motion ===

func _test_swap_moves_toolbar_directly() -> void:
	print("\n[swap] clicking a different piece moves the toolbar directly (no intermediate deselect)")
	var w := _make_world([200, 350])
	var placement: RefCounted = w["placement"]
	var selection: RefCounted = w["selection"]
	var toolbar = w["toolbar"]
	var spy := _spy_for(selection)

	_place(placement, "piece_200", Vector2i(2, 2))
	_place(placement, "piece_350", Vector2i(6, 6))
	selection.call("on_cell_clicked", Vector2i(2, 2))
	_check(int(toolbar.call("get_selected_instance_id")) == 0, "swap — first selection id 0")
	selection.call("on_cell_clicked", Vector2i(6, 6))  # direct swap
	_check(int(toolbar.call("get_selected_instance_id")) == 1, "swap — selection moved to id 1")
	_check(spy.deselect_count() == 0, "swap — NO intermediate selection_changed(null) (got %d)" % spy.deselect_count())
	_check(bool(toolbar.call("is_toolbar_active")), "swap — toolbar stays active through the swap")
	var fp: Rect2 = toolbar.call("get_footprint_rect")
	_check(int(fp.position.x) == 192, "swap — footprint rect moved to the new piece (x 192, got %s)" % str(fp.position.x))


func _test_deselect_hides_toolbar() -> void:
	print("\n[deselect] Esc / empty-floor deselect hides the toolbar")
	var w := _make_world([200])
	var placement: RefCounted = w["placement"]
	var selection: RefCounted = w["selection"]
	var toolbar = w["toolbar"]

	_place(placement, "piece_200", Vector2i(3, 3))
	selection.call("on_cell_clicked", Vector2i(3, 3))
	_check(bool(toolbar.call("is_toolbar_active")), "deselect — setup: active")
	selection.call("on_esc_pressed")
	_check(not bool(toolbar.call("is_toolbar_active")), "deselect — hidden after Esc")
	_check(int(toolbar.call("get_selected_instance_id")) == -1, "deselect — selection payload cleared")


func _test_reduced_motion_instant() -> void:
	print("\n[reduced-motion] cue/toolbar appear instantly (no animation tween)")
	var w := _make_world([200], "cardio", {"reduced_motion": true})
	var placement: RefCounted = w["placement"]
	var selection: RefCounted = w["selection"]
	var toolbar = w["toolbar"]

	_check(bool(toolbar.call("is_reduced_motion")), "reduced-motion — config applied")
	_place(placement, "piece_200", Vector2i(3, 3))
	selection.call("on_cell_clicked", Vector2i(3, 3))
	_check(toolbar.visible, "reduced-motion — toolbar visible immediately (no fade-in gating)")
	_check(bool(toolbar.call("is_toolbar_active")), "reduced-motion — active immediately")


func _test_double_init_guard() -> void:
	print("\n[guard] init() twice → loud no-op")
	var w := _make_world([200])
	var toolbar = w["toolbar"]
	toolbar.call("init", w["selection"], w["bridge"], w["placement"], w["grid"], CELL_SIZE)
	# The toolbar still works (first init state intact).
	var placement: RefCounted = w["placement"]
	var selection: RefCounted = w["selection"]
	_place(placement, "piece_200", Vector2i(4, 4))
	selection.call("on_cell_clicked", Vector2i(4, 4))
	_check(bool(toolbar.call("is_toolbar_active")), "guard — double init leaves the first wiring intact")
