# tests/unit/selection_system/sell_flow_test.gd
# Story SEL-003: Sell Flow (Soft-Confirm + Refund)
# (production/epics/selection-system/story-003-sell-flow-soft-confirm.md)
#
# Covers the BLOCKING ACs (TR-SEL-003/009) — ADAPTED to the merged bridge
# API (SEL-002 t_d0255555): request_sell_confirm() / confirm_sell() /
# _on_sell_confirm_timeout(generation) — the SEL-003 branch's original
# on_sell_pressed/on_sell_confirmed naming was never merged to main.
#
#   AC5   — a selection, Sell pressed → the 2 s "Confirm sell +$X" window
#           opens (bridge pending + sell_confirm_started); a second click in
#           the window (bridge.confirm_sell → sell_confirm_confirmed →
#           sell_selected) removes the piece, credits Economy EXACTLY ONCE,
#           and clears the selection (selection_changed(null))
#   AC6   — 2 s elapse with no second click → reverts to the normal Sell
#           state: NO sale (piece stays on the grid), NO balance change,
#           selection stays; Esc cancels the window the same way
#   AC7   — selling a piece with cost C credits exactly
#           int(round(0.5 × C)) — integer credit, balance_changed fires once
#           with a positive delta (C=200 → 100, C=350 → 175)
#   AC13  — cost = 0 → refund = 0: piece removed, selection_changed(null)
#           fires, Economy NOT credited
#   AC14  — after a sale the instance_id does not resolve; a new placement
#           reuses a FUTURE id — no collision with the retired one
#   AC15  — refund_rate 0.5, cost 201 → refund = int(round(100.5)) = 101
#           (.5 ties round away from zero per GDScript round(); int cast)
#
# Plus the state-machine edges from the story QA cases:
#   - confirm at the boundary (second click while pending → sale proceeds)
#   - timeout exactly at the window end (revert, no sale)
#   - Esc cancels a pending window (no sale)
#   - double-confirm guard: the second confirm_sell is a no-op (credit once)
#   - sell with nothing selected → silent no-op (false)
#   - sell without an injected Economy → loud wiring error (false)
#
# Run standalone: godot --headless --script tests/unit/selection_system/sell_flow_test.gd
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"

const SEL_SCRIPT := "res://src/systems/selection_system.gd"
const BRIDGE_SCRIPT := "res://src/systems/selection_input_bridge.gd"
const PLACEMENT_SCRIPT := "res://src/systems/placement_system.gd"
const GRID_SCRIPT := "res://src/systems/grid_system.gd"
const CATALOG_SCRIPT := "res://src/systems/equipment_catalog.gd"
const DEF_SCRIPT := "res://src/systems/equipment_def.gd"
const ECON_SCRIPT := "res://src/systems/economy.gd"
const SRG_SCRIPT := "res://src/systems/seeded_rng.gd"

const CELL_SIZE := 32

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
	print("  UNIT TEST: SelectionSystem — Sell Flow Soft-Confirm (SEL-003)")
	print("=".repeat(48))

	_test_ac5_confirm_removes_credits_clears()
	_test_ac5_confirm_at_boundary_proceeds()
	_test_ac5_double_confirm_credits_once()
	_test_ac6_timeout_reverts_no_sale()
	_test_ac6_esc_cancels_no_sale()
	_test_ac7_refund_exact_integer()
	_test_ac7_cost_350_refund_175()
	_test_ac7_credit_fires_once_with_reason()
	_test_ac13_cost_zero_clean_completion()
	_test_ac14_retired_id_does_not_resolve()
	_test_ac14_new_placement_future_id_no_collision()
	_test_ac15_odd_cost_rounds_away_from_zero()
	_test_b2_final_equipment_death_guard()
	_test_sell_no_selection_silent_noop()
	_test_sell_without_economy_loud_error()
	_test_confirm_without_pending_window_noop()

	_free_test_nodes()

	print("\n=== SEL-003 Sell Flow: %d passed, %d failed ===\n" % [_pass, _fail])
	return {"pass": _pass, "fail": _fail}


func _check(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
		print("  PASS: " + msg)
	else:
		_fail += 1
		print("  FAIL: " + msg)


# === Spies / helpers ===

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


## Spy on Economy.balance_changed — counts emissions (AC7: credit fires
## once = exactly one balance_changed with a positive delta) and records the
## deltas for exact-amount assertions.
class BalanceSpy:
	extends RefCounted
	var emissions: Array = []  # each: [new_balance, delta]

	func _on_balance_changed(new_balance: int, delta: int) -> void:
		emissions.append([new_balance, delta])

	func count() -> int:
		return emissions.size()


func _spy_for(sel: RefCounted) -> SelectionSpy:
	var spy := SelectionSpy.new()
	sel.connect("selection_changed", Callable(spy, "_on_selection_changed"))
	return spy


func _spy_balance(econ: RefCounted) -> BalanceSpy:
	var spy := BalanceSpy.new()
	econ.connect("balance_changed", Callable(spy, "_on_balance_changed"))
	return spy


func _ED() -> Script:
	return load(DEF_SCRIPT) as Script


## Def with a configurable cost — the refund formula's input. 1×1 footprint
## + 1 access cell (the yoga-mat shape), so placement math stays trivial.
func _make_def(cost: int) -> RefCounted:
	var ED := _ED()
	var zone: Array = ["cardio"]
	var footprint: Array[Vector2i] = [Vector2i(0, 0)]
	var access: Array[Vector2i] = [Vector2i(1, 0)]
	var effects: Array[Dictionary] = []
	return ED.new(
		"piece_%d" % cost,
		"Test %d" % cost,
		zone,
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


## Real Economy rig: orchestrator + SeededRNG + real Economy (default config
## — starting_capital 500, r_visit 12). The orchestrator is added to the
## tree for a synchronous _ready (established pattern; the orchestrator is
## the Economy init dependency and nothing else is needed here).
func _make_economy(seed: int, starting_capital: int = 500) -> RefCounted:
	var srg: RefCounted = (load(SRG_SCRIPT) as Script).new()
	srg.call("init", seed)
	var orch: Node = load("res://src/systems/simulation_orchestrator.gd").new()
	root.add_child(orch)
	orch.call("_ready")
	_nodes_to_free.append(orch)
	var econ: RefCounted = (load(ECON_SCRIPT) as Script).new()
	econ.call("init", orch, srg, {"starting_capital": starting_capital})
	orch.set("economy", econ)
	return econ


## SelectionSystem wired for the mapping + the sell path (init with economy
## + _post_init).
func _make_selection(grid: RefCounted, placement: RefCounted, catalog: RefCounted, economy: RefCounted) -> RefCounted:
	var sel: RefCounted = (load(SEL_SCRIPT) as Script).new()
	sel.call("init", grid, placement, catalog, economy)
	sel.call("_post_init")
	return sel


## The bridge, wired EXACTLY like the composition root: init (MERGED
## signature: system, grid, cell_size, placement) + the
## sell_confirm_confirmed → sell_selected typed connection (Control
## Manifest: typed connections only). Tracked for teardown. The bridge is a
## Node (SelectionInputBridge extends Node) — returned untyped so tests can
## reach signals dynamically.
func _make_bridge(sel: RefCounted, grid: RefCounted, placement: RefCounted):
	var bridge = (load(BRIDGE_SCRIPT) as Script).new()
	bridge.call("init", sel, grid, CELL_SIZE, placement)
	bridge.connect("sell_confirm_confirmed", Callable(sel, "sell_selected"))
	_nodes_to_free.append(bridge)
	return bridge


## Places a piece via the REAL PlacementSystem flow, returning the allocated
## instance_id (monotonic in-session — never reissued, AC14).
func _place(ps: RefCounted, equipment_id: String, anchor: Vector2i) -> int:
	var id_before: int = ps.call("get_next_instance_id")
	ps.call("begin_drag", equipment_id)
	ps.call("on_mouse_moved", anchor)
	ps.call("on_drop")
	return id_before


func _free_test_nodes() -> void:
	for n in _nodes_to_free:
		if is_instance_valid(n):
			n.free()
	_nodes_to_free.clear()


## Standard world: 10×10 open grid, catalog with [costs], economy, real
## selection + bridge wired end-to-end. Returns the rig dict.
func _make_world(costs: Array, starting_capital: int = 500) -> Dictionary:
	var defs: Array = []
	for c in costs:
		defs.append(_make_def(int(c)))
	var grid := _make_grid(10, 10)
	var catalog := _make_catalog(defs)
	var placement := _make_placement(grid, catalog)
	var economy := _make_economy(0x5E11003, starting_capital)
	var selection := _make_selection(grid, placement, catalog, economy)
	var bridge = _make_bridge(selection, grid, placement)
	return {
		"grid": grid, "catalog": catalog, "placement": placement,
		"economy": economy, "selection": selection, "bridge": bridge,
	}


## World variant whose economy is a RecordingEconomy subclass (records the
## credit reason). The rig's selection is wired to the RECORDING instance so
## the audit label is observable end-to-end.
func _make_world_with_recording_economy(costs: Array) -> Dictionary:
	var defs: Array = []
	for c in costs:
		defs.append(_make_def(int(c)))
	var grid := _make_grid(10, 10)
	var catalog := _make_catalog(defs)
	var placement := _make_placement(grid, catalog)
	var srg: RefCounted = (load(SRG_SCRIPT) as Script).new()
	srg.call("init", 0x5E11EC)
	var orch: Node = load("res://src/systems/simulation_orchestrator.gd").new()
	root.add_child(orch)
	orch.call("_ready")
	_nodes_to_free.append(orch)
	var recording: RecordingEconomy = RecordingEconomy.new()
	recording.init(orch, srg)
	orch.set("economy", recording)
	var selection := _make_selection(grid, placement, catalog, recording)
	var bridge = _make_bridge(selection, grid, placement)
	return {
		"grid": grid, "catalog": catalog, "placement": placement,
		"economy": recording, "recording_economy": recording,
		"selection": selection, "bridge": bridge,
	}


# === AC5: second click in the window completes the sale ===

func _test_ac5_confirm_removes_credits_clears() -> void:
	print("\n[AC5] Sell → 2 s window → confirm → piece removed + credited once + selection clears")
	var w := _make_world([200])
	var grid: RefCounted = w["grid"]
	var placement: RefCounted = w["placement"]
	var economy: RefCounted = w["economy"]
	var selection: RefCounted = w["selection"]
	var bridge = w["bridge"]

	var instance_id: int = _place(placement, "piece_200", Vector2i(2, 2))  # id 0
	selection.call("on_cell_clicked", Vector2i(2, 2))  # select the piece
	var spy := _spy_for(selection)
	var bal_spy := _spy_balance(economy)

	# Sell pressed → window opens (button would show "Confirm sell +$X").
	bridge.call("request_sell_confirm")
	_check(bool(bridge.call("is_sell_confirm_pending")), "AC5 — Sell pressed → confirm window is pending")
	_check(int(selection.call("get_selected_instance_id")) == instance_id, "AC5 — selection still active during the window")

	# Second click in the window → the sale resolves.
	bridge.call("confirm_sell")
	_check(not bool(bridge.call("is_sell_confirm_pending")), "AC5 — after confirm the window is closed")
	_check(int(grid.call("get_occupant_id", Vector2i(2, 2))) == -1, "AC5 — piece removed from the grid")
	_check(int(economy.get("balance")) == 600, "AC5 — Economy credited refund: balance 500 + 100 == 600 (got %d)" % int(economy.get("balance")))
	_check(int(selection.call("get_selected_instance_id")) == -1, "AC5 — selection cleared after the sale")
	_check(spy.deselect_count() == 1, "AC5 — selection_changed(null) fired exactly once (got %d)" % spy.deselect_count())
	_check(bal_spy.count() == 1, "AC5 — credit fired exactly once (balance_changed count %d)" % bal_spy.count())
	if bal_spy.count() == 1:
		_check(int(bal_spy.emissions[0][1]) == 100, "AC5 — balance_changed delta == +100 (got %d)" % int(bal_spy.emissions[0][1]))


func _test_ac5_confirm_at_boundary_proceeds() -> void:
	print("\n[AC5 edge] confirm click at the window boundary (1.9 s) → sale proceeds")
	var w := _make_world([200])
	var placement: RefCounted = w["placement"]
	var economy: RefCounted = w["economy"]
	var selection: RefCounted = w["selection"]
	var bridge = w["bridge"]

	_place(placement, "piece_200", Vector2i(3, 3))
	selection.call("on_cell_clicked", Vector2i(3, 3))
	bridge.call("request_sell_confirm")
	# The bridge's window is a state machine: any confirm while pending is
	# within the window (the 2 s timer is render-time UI state; a confirm at
	# 1.9 s is indistinguishable from 0.1 s at the logic layer — both are
	# "pending"). The timeout path (AC6) is the revert side.
	bridge.call("confirm_sell")
	_check(int(economy.get("balance")) == 600, "AC5 edge — boundary confirm sells: balance 600 (got %d)" % int(economy.get("balance")))
	_check(int(selection.call("get_selected_instance_id")) == -1, "AC5 edge — selection cleared")


func _test_ac5_double_confirm_credits_once() -> void:
	print("\n[AC5 edge] double confirm → the second click is a no-op (credit fires once)")
	var w := _make_world([200])
	var placement: RefCounted = w["placement"]
	var economy: RefCounted = w["economy"]
	var selection: RefCounted = w["selection"]
	var bridge = w["bridge"]

	_place(placement, "piece_200", Vector2i(4, 4))
	selection.call("on_cell_clicked", Vector2i(4, 4))
	var bal_spy := _spy_balance(economy)
	bridge.call("request_sell_confirm")
	bridge.call("confirm_sell")
	bridge.call("confirm_sell")  # second click — window already closed
	_check(bal_spy.count() == 1, "AC5 edge — credit fires exactly once (got %d)" % bal_spy.count())
	_check(int(economy.get("balance")) == 600, "AC5 edge — balance 600, no double credit (got %d)" % int(economy.get("balance")))


# === AC6: no second click → revert, no sale ===

func _test_ac6_timeout_reverts_no_sale() -> void:
	print("\n[AC6] 2 s elapse with no second click → revert to Sell, NO sale")
	var w := _make_world([200])
	var grid: RefCounted = w["grid"]
	var placement: RefCounted = w["placement"]
	var economy: RefCounted = w["economy"]
	var selection: RefCounted = w["selection"]
	var bridge = w["bridge"]

	var instance_id: int = _place(placement, "piece_200", Vector2i(2, 2))
	selection.call("on_cell_clicked", Vector2i(2, 2))
	var spy := _spy_for(selection)
	var bal_spy := _spy_balance(economy)

	bridge.call("request_sell_confirm")
	_check(bool(bridge.call("is_sell_confirm_pending")), "AC6 — window open after Sell pressed")
	# The 2 s SceneTreeTimer is render-time UI state (cannot be created in a
	# --script SceneTree _init context — established headless pattern); the
	# timeout HANDLER is exercised directly with the CURRENT generation.
	var gen: int = bridge.get("_timer_generation")
	bridge.call("_on_sell_confirm_timeout", gen)
	_check(not bool(bridge.call("is_sell_confirm_pending")), "AC6 — timeout → window reverted (not pending)")
	_check(int(grid.call("get_occupant_id", Vector2i(2, 2))) == instance_id, "AC6 — piece STILL on the grid (no sale)")
	_check(int(economy.get("balance")) == 500, "AC6 — balance unchanged 500 (no destructive default, got %d)" % int(economy.get("balance")))
	_check(bal_spy.count() == 0, "AC6 — NO balance_changed emission (no credit)")
	_check(int(selection.call("get_selected_instance_id")) == instance_id, "AC6 — selection stays (revert only)")
	_check(spy.deselect_count() == 0, "AC6 — no selection_changed(null) — selection untouched")


func _test_ac6_esc_cancels_no_sale() -> void:
	print("\n[AC6 edge] Esc during the window → cancels, NO sale")
	var w := _make_world([200])
	var grid: RefCounted = w["grid"]
	var placement: RefCounted = w["placement"]
	var economy: RefCounted = w["economy"]
	var selection: RefCounted = w["selection"]
	var bridge = w["bridge"]

	var instance_id: int = _place(placement, "piece_200", Vector2i(5, 5))
	selection.call("on_cell_clicked", Vector2i(5, 5))
	bridge.call("request_sell_confirm")
	bridge.call("on_esc_pressed")  # Esc cancels the pending window (TR-SEL-009)
	_check(not bool(bridge.call("is_sell_confirm_pending")), "AC6 edge — Esc closes the window")
	_check(int(grid.call("get_occupant_id", Vector2i(5, 5))) == instance_id, "AC6 edge — piece still placed (no sale)")
	_check(int(economy.get("balance")) == 500, "AC6 edge — balance unchanged 500")
	_check(int(selection.call("get_selected_instance_id")) == instance_id, "AC6 edge — Esc during pending = REVERT ONLY, selection stays (GDD states table: pending | Esc | selected)")


# === AC7: integer refund, exact ===

func _test_ac7_refund_exact_integer() -> void:
	print("\n[AC7] cost 200 → balance +int(round(0.5 × 200)) == +100, integer")
	var w := _make_world([200])
	var placement: RefCounted = w["placement"]
	var economy: RefCounted = w["economy"]
	var selection: RefCounted = w["selection"]
	var bridge = w["bridge"]

	_place(placement, "piece_200", Vector2i(1, 1))
	selection.call("on_cell_clicked", Vector2i(1, 1))
	var bal_spy := _spy_balance(economy)
	bridge.call("request_sell_confirm")
	bridge.call("confirm_sell")
	_check(int(economy.get("balance")) == 600, "AC7 — balance exactly 600 (500 + 100, got %d)" % int(economy.get("balance")))
	_check(bal_spy.count() == 1, "AC7 — credit fires once (got %d)" % bal_spy.count())
	if bal_spy.count() == 1:
		_check(int(bal_spy.emissions[0][0]) == 600, "AC7 — balance_changed new_balance == 600 (got %d)" % int(bal_spy.emissions[0][0]))
		_check(int(bal_spy.emissions[0][1]) == 100, "AC7 — balance_changed delta == +100 (got %d)" % int(bal_spy.emissions[0][1]))


func _test_ac7_cost_350_refund_175() -> void:
	print("\n[AC7] cost 350 → refund int(round(175.0)) == 175")
	var w := _make_world([350])
	var placement: RefCounted = w["placement"]
	var economy: RefCounted = w["economy"]
	var selection: RefCounted = w["selection"]
	var bridge = w["bridge"]

	_place(placement, "piece_350", Vector2i(2, 2))
	selection.call("on_cell_clicked", Vector2i(2, 2))
	bridge.call("request_sell_confirm")
	bridge.call("confirm_sell")
	_check(int(economy.get("balance")) == 675, "AC7 — balance exactly 675 (500 + 175, got %d)" % int(economy.get("balance")))


func _test_ac7_credit_fires_once_with_reason() -> void:
	print("\n[AC7] credit reason is 'sell:instance_<id>' (audit label, ADR-0006)")
	var w := _make_world_with_recording_economy([200])
	var placement: RefCounted = w["placement"]
	var selection: RefCounted = w["selection"]
	var bridge = w["bridge"]
	var econ: RecordingEconomy = w["recording_economy"]

	_place(placement, "piece_200", Vector2i(6, 6))
	selection.call("on_cell_clicked", Vector2i(6, 6))
	bridge.call("request_sell_confirm")
	bridge.call("confirm_sell")
	_check(econ.credit_calls == 1, "AC7 — real credit() called exactly once (got %d)" % econ.credit_calls)
	_check(econ.last_reason == "sell:instance_0", "AC7 — credit reason is 'sell:instance_0' (got '%s')" % econ.last_reason)
	_check(int(econ.get("balance")) == 600, "AC7 — balance 600 after the single credit (got %d)" % int(econ.get("balance")))


## Economy subclass that records the reason passed to credit() while
## delegating the actual ledger mutation to super (the REAL Economy logic) —
## audit-label observability without forking the balance behavior. Must be
## an Economy subclass (SelectionSystem.init's 4th param is typed Economy).
class RecordingEconomy:
	extends Economy
	var credit_calls := 0
	var last_reason := ""

	func credit(amount: int, reason: String) -> bool:
		credit_calls += 1
		last_reason = reason
		return super.credit(amount, reason)


# === AC13: cost-0 free piece ===

func _test_ac13_cost_zero_clean_completion() -> void:
	print("\n[AC13] cost 0 → refund 0, piece removed, selection_changed(null), no money effect")
	var w := _make_world([0])
	var grid: RefCounted = w["grid"]
	var placement: RefCounted = w["placement"]
	var economy: RefCounted = w["economy"]
	var selection: RefCounted = w["selection"]
	var bridge = w["bridge"]

	var instance_id: int = _place(placement, "piece_0", Vector2i(3, 3))
	selection.call("on_cell_clicked", Vector2i(3, 3))
	var spy := _spy_for(selection)
	var bal_spy := _spy_balance(economy)

	bridge.call("request_sell_confirm")
	bridge.call("confirm_sell")
	_check(int(grid.call("get_occupant_id", Vector2i(3, 3))) == -1, "AC13 — piece removed")
	_check(int(economy.get("balance")) == 500, "AC13 — balance unchanged 500 (refund 0, got %d)" % int(economy.get("balance")))
	_check(bal_spy.count() == 0, "AC13 — NO credit call (credit(0) would be rejected — skipped, no warning noise)")
	_check(int(selection.call("get_selected_instance_id")) == -1, "AC13 — selection cleared")
	_check(spy.deselect_count() == 1, "AC13 — selection_changed(null) fired (got %d)" % spy.deselect_count())
	_check(instance_id == 0, "AC13 — fixture sanity: first placement got id 0 (got %d)" % instance_id)


# === AC14: retired id does not resolve ===

func _test_ac14_retired_id_does_not_resolve() -> void:
	print("\n[AC14] after a sale the retired instance_id does not resolve (mapping entry removed)")
	var w := _make_world([200])
	var grid: RefCounted = w["grid"]
	var placement: RefCounted = w["placement"]
	var selection: RefCounted = w["selection"]
	var bridge = w["bridge"]

	var instance_id: int = _place(placement, "piece_200", Vector2i(4, 4))
	_check(instance_id == 0, "AC14 — fixture: sold id is 0")
	selection.call("on_cell_clicked", Vector2i(4, 4))
	bridge.call("request_sell_confirm")
	bridge.call("confirm_sell")

	# The retired id must not resolve: the grid cell is empty, and clicking
	# the former footprint cannot select a phantom.
	_check(int(grid.call("get_occupant_id", Vector2i(4, 4))) == -1, "AC14 — retired id absent from the grid")
	selection.call("on_cell_clicked", Vector2i(4, 4))
	_check(int(selection.call("get_selected_instance_id")) == -1, "AC14 — clicking the retired footprint does not resolve a selection (mapping entry removed)")
	# A second sell attempt on the same (now empty) selection is a no-op.
	_check(not bool(selection.call("sell_selected")), "AC14 — sell_selected on cleared selection returns false")


func _test_ac14_new_placement_future_id_no_collision() -> void:
	print("\n[AC14 edge] a new placement reuses a FUTURE id — no collision with the retired one")
	var w := _make_world([200])
	var grid: RefCounted = w["grid"]
	var placement: RefCounted = w["placement"]
	var economy: RefCounted = w["economy"]
	var selection: RefCounted = w["selection"]
	var bridge = w["bridge"]

	var sold_id: int = _place(placement, "piece_200", Vector2i(1, 1))
	selection.call("on_cell_clicked", Vector2i(1, 1))
	bridge.call("request_sell_confirm")
	bridge.call("confirm_sell")

	# New placement after the sale: monotonic in-session counter → a FUTURE
	# id (never the retired one).
	var new_id: int = _place(placement, "piece_200", Vector2i(6, 6))
	_check(new_id > sold_id, "AC14 edge — new id %d is a future id, never reissues retired %d" % [new_id, sold_id])
	_check(new_id != sold_id, "AC14 edge — ids never collide")
	_check(int(grid.call("get_occupant_id", Vector2i(6, 6))) == new_id, "AC14 edge — the new piece is on the grid under its fresh id")
	# The new piece is selectable and sellable — the mapping entry for the
	# new id is live.
	selection.call("on_cell_clicked", Vector2i(6, 6))
	_check(int(selection.call("get_selected_instance_id")) == new_id, "AC14 edge — new piece selects normally")
	_check(int(economy.get("balance")) == 500 + 100, "AC14 edge — first sale credited 100 before the second placement")
	bridge.call("request_sell_confirm")
	bridge.call("confirm_sell")
	_check(int(economy.get("balance")) == 500 + 100 + 100, "AC14 edge — selling the new piece credits again: balance 700 (got %d)" % int(economy.get("balance")))


# === AC15: .5 tie rounds away from zero ===

func _test_ac15_odd_cost_rounds_away_from_zero() -> void:
	print("\n[AC15] refund_rate 0.5, cost 201 → int(round(100.5)) == 101 (ties away from zero)")
	var w := _make_world([201])
	var placement: RefCounted = w["placement"]
	var economy: RefCounted = w["economy"]
	var selection: RefCounted = w["selection"]
	var bridge = w["bridge"]

	_place(placement, "piece_201", Vector2i(2, 2))
	selection.call("on_cell_clicked", Vector2i(2, 2))
	var bal_spy := _spy_balance(economy)
	bridge.call("request_sell_confirm")
	bridge.call("confirm_sell")
	_check(int(economy.get("balance")) == 601, "AC15 — balance exactly 601 (500 + 101, got %d)" % int(economy.get("balance")))
	_check(bal_spy.count() == 1, "AC15 — credit fired once (got %d)" % bal_spy.count())
	if bal_spy.count() == 1:
		_check(int(bal_spy.emissions[0][1]) == 101, "AC15 — delta == +101 (int, got %d)" % int(bal_spy.emissions[0][1]))


func _test_b2_final_equipment_death_guard() -> void:
	print("\n[B2 death guard] final sale cannot leave balance below cheapest replacement")
	var blocked := _make_world([240], 0)
	var blocked_grid: RefCounted = blocked["grid"]
	var blocked_placement: RefCounted = blocked["placement"]
	var blocked_economy: RefCounted = blocked["economy"]
	var blocked_selection: RefCounted = blocked["selection"]
	var blocked_id := _place(blocked_placement, "piece_240", Vector2i(2, 2))
	blocked_selection.call("on_cell_clicked", Vector2i(2, 2))
	_check(not bool(blocked_selection.call("sell_selected")),
		"last $240 equipment sale is blocked when $0 + $120 refund cannot replace it")
	_check(int(blocked_grid.call("get_occupant_id", Vector2i(2, 2))) == blocked_id,
		"blocked sale keeps final equipment on grid")
	_check(int(blocked_economy.get("balance")) == 0,
		"blocked sale does not credit or otherwise mutate balance")

	var recoverable := _make_world([200, 240], 80)
	var recoverable_placement: RefCounted = recoverable["placement"]
	var recoverable_selection: RefCounted = recoverable["selection"]
	var recoverable_economy: RefCounted = recoverable["economy"]
	_place(recoverable_placement, "piece_240", Vector2i(3, 3))
	recoverable_selection.call("on_cell_clicked", Vector2i(3, 3))
	_check(bool(recoverable_selection.call("sell_selected")),
		"final sale proceeds when balance + refund reaches cheapest $200 replacement")
	_check(int(recoverable_economy.get("balance")) == 200,
		"allowed final sale lands exact recovery balance $200")


# === Guards ===

func _test_sell_no_selection_silent_noop() -> void:
	print("\n[guard] sell_selected() with nothing selected → silent no-op (false), no signals")
	var w := _make_world([200])
	var economy: RefCounted = w["economy"]
	var selection: RefCounted = w["selection"]
	var spy := _spy_for(selection)
	var bal_spy := _spy_balance(economy)

	var ok: bool = selection.call("sell_selected")
	_check(not ok, "guard — returns false (no selection)")
	_check(int(economy.get("balance")) == 500, "guard — balance unchanged")
	_check(spy.emissions.size() == 0, "guard — no selection_changed emission")
	_check(bal_spy.count() == 0, "guard — no balance_changed emission")


func _test_sell_without_economy_loud_error() -> void:
	print("\n[guard] sell_selected() without an injected Economy → loud wiring error, no sale")
	var w := _make_world([200])
	var grid: RefCounted = w["grid"]
	var placement: RefCounted = w["placement"]
	var catalog: RefCounted = w["catalog"]
	var selection: RefCounted = w["selection"]
	var bridge = w["bridge"]

	# A second selection WITHOUT economy (pre-003 wiring — 3-arg init).
	var bare: RefCounted = (load(SEL_SCRIPT) as Script).new()
	bare.call("init", grid, placement, catalog)  # no economy
	bare.call("_post_init")
	var bare_id: int = _place(placement, "piece_200", Vector2i(7, 7))
	_check(bare_id == 0, "guard — fixture: bare placement got id 0 (got %d)" % bare_id)
	bare.call("on_cell_clicked", Vector2i(7, 7))
	_check(int(bare.call("get_selected_instance_id")) == bare_id, "guard — bare selection still works for selection logic")
	var ok: bool = bare.call("sell_selected")
	_check(not ok, "guard — sell fails (false) without economy")
	_check(int(grid.call("get_occupant_id", Vector2i(7, 7))) == bare_id, "guard — piece NOT removed (no partial sale)")
	# The real (economy-wired) selection is unaffected.
	_check(int(w["economy"].get("balance")) == 500, "guard — real economy balance untouched")


func _test_confirm_without_pending_window_noop() -> void:
	print("\n[guard] confirm_sell() with no pending window → no-op (no signals)")
	var w := _make_world([200])
	var economy: RefCounted = w["economy"]
	var selection: RefCounted = w["selection"]
	var bridge = w["bridge"]

	var spy := _spy_for(selection)
	var bal_spy := _spy_balance(economy)
	bridge.call("confirm_sell")  # no window open
	_check(not bool(bridge.call("is_sell_confirm_pending")), "guard — still not pending")
	_check(int(economy.get("balance")) == 500, "guard — balance unchanged")
	_check(spy.emissions.size() == 0, "guard — no selection_changed emission")
	_check(bal_spy.count() == 0, "guard — no balance_changed emission")
