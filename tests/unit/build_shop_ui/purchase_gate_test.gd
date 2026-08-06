# tests/unit/build_shop_ui/purchase_gate_test.gd
# Story BSUI-002: Purchase Gating & One-drag Invariant
# (production/epics/build-shop-ui/story-002-purchase-gating-one-drag-invariant.md)
#
# Covers the BLOCKING ACs (TR-BSUI-003/005 + shop-purchase.md Core Rules
# 1/2/2a/2b/3/5):
#   - AC4          affordable, unlocked item mouse-down -> Shop gate passes
#                  -> _purchase_in_flight set -> PlacementSystem drag begins.
#                  Edges: is_dragging() already true -> no flag, no drag;
#                  locked -> can_purchase false -> no drag.
#   - AC5          a purchase drag in flight blocks a second purchase
#                  (one-drag invariant: palette disabled + structural gate).
#                  Edge: second can_purchase pass during drag -> true no-op,
#                  no flag change.
#   - AC9          hover on greyed/unaffordable item -> "Save $X more" with
#                  X = cost - balance. Edge: X = 0 (just affordable) -> no
#                  tooltip; locked -> lock tooltip, not Save-$X.
#   - Core Rule 1  locked item (even cost-0) -> can_purchase false (unlock
#                  checked BEFORE the cost-0 affordability short-circuit).
#   - Core Rule 2b cost-0 drag commit -> NO Economy.spend(0) call (skipped);
#                  flag cleared; placement completes; money untouched.
#   - Core Rule 2  spend EXACTLY once on placement_committed for
#                  purchase-initiated drags; relocate commit (flag null) ->
#                  zero spend; equipment_id mismatch -> zero spend, flag
#                  untouched; placement_rejected / silent cancel -> flag
#                  cleared, zero spend.
#
# Run standalone: godot --headless --script tests/unit/build_shop_ui/purchase_gate_test.gd
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"

const DEF_SCRIPT_PATH := "res://src/systems/equipment_def.gd"
const CATALOG_SCRIPT_PATH := "res://src/systems/equipment_catalog.gd"
const ECON_SCRIPT_PATH := "res://src/systems/economy.gd"
const SRG_SCRIPT_PATH := "res://src/systems/seeded_rng.gd"
const GRID_SCRIPT_PATH := "res://src/systems/grid_system.gd"
const PLACEMENT_SCRIPT_PATH := "res://src/systems/placement_system.gd"
const PALETTE_SCRIPT_PATH := "res://src/ui/build_shop_palette.gd"
const TILE_SCRIPT_PATH := "res://src/ui/palette_tile.gd"
const AVAIL_SCRIPT_PATH := "res://src/ui/palette_availability.gd"
const SHOP_SCRIPT_PATH := "res://src/ui/shop.gd"

## preload aliases for inner class bases — the headless cross-script ref
## pattern (global class cache is editor-generated).
const EconomyScript := preload("res://src/systems/economy.gd")

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
	print("  UNIT TEST: Build/Shop UI — Purchase Gating & One-drag (Story BSUI-002)")
	print("=".repeat(48))

	# Shop.can_purchase gate (Core Rule 1 + cost-0 short-circuit)
	_test_can_purchase_affordable_true()
	_test_can_purchase_unaffordable_false()
	_test_can_purchase_locked_false()
	_test_can_purchase_unknown_false()
	_test_can_purchase_cost0_short_circuit_skips_can_afford()
	_test_core_rule_1_locked_cost0_false()

	# Shop.begin_purchase_drag gate (AC4 + structural backstop)
	_test_begin_drag_affordable_sets_flag()
	_test_begin_drag_locked_false()
	_test_begin_drag_unaffordable_false()
	_test_begin_drag_while_dragging_no_flag()
	_test_second_purchase_during_drag_flag_unchanged()

	# Palette gate (AC4/AC5)
	_test_palette_mouse_down_starts_drag_ac4()
	_test_palette_mouse_down_locked_inert()
	_test_palette_mouse_down_unaffordable_inert()
	_test_palette_one_drag_invariant_ac5()
	_test_palette_render_only_mode_no_placement()
	_test_palette_drag_resolution_silent_cancel()

	# Spend-on-commit (Core Rules 2/2a/2b)
	_test_commit_spend_exactly_once()
	_test_commit_cost0_no_spend_core_rule_2b()
	_test_relocate_commit_ignored_no_spend()
	_test_commit_mismatch_no_spend_flag_untouched()
	_test_reject_clears_flag_no_spend()
	_test_silent_cancel_clears_flag_no_spend()

	# Hover Save-$X (AC9)
	_test_hover_save_more_text()
	_test_hover_x0_just_affordable_no_tooltip()
	_test_hover_locked_lock_tooltip()
	_test_hover_affordable_no_tooltip()

	# Guards
	_test_shop_use_before_init_guard()
	_test_shop_init_twice_guard()
	_test_shop_save_more_before_init()

	_free_test_nodes()

	print("\n=== PURCHASE GATE TEST: %d passed, %d failed ===\n" % [_pass, _fail])
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


func _PALETTE() -> Script:
	return load(PALETTE_SCRIPT_PATH) as Script


func _TILE() -> Script:
	return load(TILE_SCRIPT_PATH) as Script


func _SHOP() -> Script:
	return load(SHOP_SCRIPT_PATH) as Script


## The PaletteTile.State enum values, read from the real script's constant
## map (never duplicated in the test — an enum reorder breaks the test).
var _tile_state_consts: Dictionary = {}


func _STATE() -> Dictionary:
	if _tile_state_consts.is_empty():
		var consts: Dictionary = _TILE().get_script_constant_map()
		_tile_state_consts = consts["State"]
	return _tile_state_consts


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


## SpendSpyEconomy — a real Economy subclass that records spend() and
## can_afford() calls then delegates to the real implementation. Proves the
## cost-0 short-circuit (can_afford NOT called for free items) and the
## Core Rule 2b skip (spend NOT called for cost-0 commits) at the call site,
## which balance inspection alone cannot distinguish from a rejected call.
func _make_spy_economy(seed: int) -> RefCounted:
	var srg: RefCounted = _SRG().new()
	srg.call("init", seed)
	var orch := _make_orchestrator()
	var econ: RefCounted = SpendSpyEconomy.new()
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


## The real Shop (Story 002 query surface) wired to catalog/economy/placement.
func _make_shop(catalog: RefCounted, economy: RefCounted, placement: RefCounted) -> RefCounted:
	var shop: RefCounted = _SHOP().new()
	shop.call("init", catalog, economy, placement)
	return shop


## Builds a palette Node wired to catalog/economy/availability/placement and
## added to the root (tracked for teardown). Untyped return so tests can
## reach signals dynamically.
func _make_palette(catalog: RefCounted, economy: RefCounted, availability: RefCounted, placement: RefCounted = null):
	var palette = _PALETTE().new()
	if placement == null:
		palette.call("init", catalog, economy, availability)
	else:
		palette.call("init", catalog, economy, availability, placement)
	root.add_child(palette)
	_nodes_to_free.append(palette)
	return palette


## Standard 4-item catalog + fresh economy (balance 500) + real Shop +
## placement + palette rig:
##   treadmill_01 : $350, always available
##   bench_press  : $200, always available
##   yoga_mat     : $200, locked (milestone_a)
##   free_dumbbell: $0,   always available (cost-0 short-circuit fixture)
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
	var palette = _make_palette(catalog, economy, shop, placement)
	return {
		"catalog": catalog, "economy": economy, "grid": grid,
		"placement": placement, "shop": shop, "palette": palette,
	}


## SpendSpyEconomy — real Economy behavior + recorded spend/can_afford calls.
class SpendSpyEconomy:
	extends EconomyScript

	var spend_calls: Array = []
	var can_afford_calls: Array = []

	func spend(amount: int) -> bool:
		spend_calls.append(amount)
		return super(amount)

	func can_afford(amount: int) -> bool:
		can_afford_calls.append(amount)
		return super(amount)


# === Shop.can_purchase gate (Core Rule 1 + cost-0 short-circuit) ===

func _test_can_purchase_affordable_true() -> void:
	print("\n[can_purchase] affordable, unlocked item -> true")
	var rig := _make_standard_rig(0xB5201)
	var shop: RefCounted = rig["shop"]

	_check(bool(shop.call("can_purchase", "treadmill_01")), "treadmill_01 ($350, balance 500) -> can_purchase true")
	_check(bool(shop.call("can_purchase", "bench_press")), "bench_press ($200, balance 500) -> can_purchase true")
	_check(bool(shop.call("can_purchase", "free_dumbbell")), "free_dumbbell ($0) -> can_purchase true (cost-0 trivially affordable)")


func _test_can_purchase_unaffordable_false() -> void:
	print("\n[can_purchase] unaffordable item -> false")
	var rig := _make_standard_rig(0xB5202)
	var shop: RefCounted = rig["shop"]
	var economy: RefCounted = rig["economy"]
	economy.call("spend", 400)  # balance 100

	_check(not bool(shop.call("can_purchase", "treadmill_01")), "treadmill_01 ($350, balance 100) -> can_purchase false")
	_check(not bool(shop.call("can_purchase", "bench_press")), "bench_press ($200, balance 100) -> can_purchase false too (200 > 100)")


func _test_can_purchase_locked_false() -> void:
	print("\n[can_purchase] locked item -> false even when affordable")
	var rig := _make_standard_rig(0xB5203)
	var shop: RefCounted = rig["shop"]

	_check(not bool(shop.call("can_purchase", "yoga_mat")), "yoga_mat (locked, $200, balance 500) -> can_purchase false (unlock fails)")
	_check(not bool(shop.call("is_unlocked", "yoga_mat")), "is_unlocked(yoga_mat) -> false (unlock_requirement != '')")


func _test_can_purchase_unknown_false() -> void:
	print("\n[can_purchase] unknown id -> false, no crash")
	var rig := _make_standard_rig(0xB5204)
	var shop: RefCounted = rig["shop"]

	_check(not bool(shop.call("can_purchase", "does_not_exist")), "unknown id -> can_purchase false")
	_check(not bool(shop.call("is_unlocked", "does_not_exist")), "unknown id -> is_unlocked false")


func _test_can_purchase_cost0_short_circuit_skips_can_afford() -> void:
	print("\n[can_purchase] cost-0 SHORT-CIRCUIT — Economy.can_afford NEVER called (it rejects 0)")
	var srg: RefCounted = _SRG().new()
	srg.call("init", 0xB5205)
	var orch := _make_orchestrator()
	var econ: RefCounted = SpendSpyEconomy.new()
	econ.call("init", orch, srg)
	orch.set("economy", econ)

	var defs: Array = [_make_def(_ED(), "free_dumbbell", "Free Dumbbell", 0, "")]
	var catalog := _make_catalog(defs)
	var grid := _make_open_grid(10, 10)
	var placement := _make_placement(grid, catalog)
	var shop := _make_shop(catalog, econ, placement)

	_check(bool(shop.call("can_purchase", "free_dumbbell")), "cost-0 unlocked item -> can_purchase true")
	_check(int(econ.get("can_afford_calls").size()) == 0, "can_afford() called ZERO times for a cost-0 item (short-circuit — got %d calls)" % int(econ.get("can_afford_calls").size()))


func _test_core_rule_1_locked_cost0_false() -> void:
	print("\n[Core Rule 1] locked item that is ALSO cost-0 -> can_purchase false (unlock checked FIRST)")
	var ED := _ED()
	var defs: Array = [
		_make_def(ED, "free_locked", "Free Locked", 0, "milestone_z"),
	]
	var catalog := _make_catalog(defs)
	var economy := _make_economy(0xB5206)
	var grid := _make_open_grid(10, 10)
	var placement := _make_placement(grid, catalog)
	var shop := _make_shop(catalog, economy, placement)

	_check(not bool(shop.call("can_purchase", "free_locked")), "cost-0 + locked -> can_purchase FALSE (unlock gate runs before the cost-0 short-circuit)")
	_check(not bool(shop.call("is_unlocked", "free_locked")), "is_unlocked(free_locked) -> false")


# === Shop.begin_purchase_drag gate (AC4 + structural backstop) ===

func _test_begin_drag_affordable_sets_flag() -> void:
	print("\n[AC4] affordable, unlocked item -> begin_purchase_drag true; flag set with equipment_id + cost")
	var rig := _make_standard_rig(0xB5211)
	var shop: RefCounted = rig["shop"]

	_check(bool(shop.call("begin_purchase_drag", "treadmill_01")), "begin_purchase_drag(treadmill_01) -> true (gate passes)")
	_check(bool(shop.call("is_purchase_in_flight")), "_purchase_in_flight set")
	_check(shop.call("get_purchase_equipment_id") == "treadmill_01", "flag equipment_id == treadmill_01 (got '%s')" % shop.call("get_purchase_equipment_id"))
	_check(int(shop.call("get_purchase_cost")) == 350, "flag cost == 350 (got %d)" % int(shop.call("get_purchase_cost")))


func _test_begin_drag_locked_false() -> void:
	print("\n[AC4 edge] locked item -> begin_purchase_drag false; no flag")
	var rig := _make_standard_rig(0xB5212)
	var shop: RefCounted = rig["shop"]

	_check(not bool(shop.call("begin_purchase_drag", "yoga_mat")), "begin_purchase_drag(yoga_mat) -> false (can_purchase false)")
	_check(not bool(shop.call("is_purchase_in_flight")), "no flag set")


func _test_begin_drag_unaffordable_false() -> void:
	print("\n[AC4 edge] unaffordable item -> begin_purchase_drag false; no flag")
	var rig := _make_standard_rig(0xB5213)
	var shop: RefCounted = rig["shop"]
	var economy: RefCounted = rig["economy"]
	economy.call("spend", 400)  # balance 100

	_check(not bool(shop.call("begin_purchase_drag", "treadmill_01")), "begin_purchase_drag(treadmill_01) at balance 100 -> false")
	_check(not bool(shop.call("is_purchase_in_flight")), "no flag set")


func _test_begin_drag_while_dragging_no_flag() -> void:
	print("\n[AC4 edge] PlacementSystem already DRAGGING (e.g. relocate) -> no flag, no drag attempt (structural backstop)")
	var rig := _make_standard_rig(0xB5214)
	var shop: RefCounted = rig["shop"]
	var placement: RefCounted = rig["placement"]
	placement.call("_test_set_dragging", true)

	_check(bool(shop.call("can_purchase", "treadmill_01")), "can_purchase still true (affordability unchanged during a drag)")
	_check(not bool(shop.call("begin_purchase_drag", "treadmill_01")), "begin_purchase_drag -> false (is_dragging() true — Core Rule 2 step 1)")
	_check(not bool(shop.call("is_purchase_in_flight")), "no flag set — the swallowed attempt never poisons _purchase_in_flight")
	# Palette level: mouse-down also inert.
	var palette = rig["palette"]
	_check(not bool(palette.call("on_tile_mouse_down", "treadmill_01")), "palette mouse-down during an existing drag -> false, no drag attempt")


func _test_second_purchase_during_drag_flag_unchanged() -> void:
	print("\n[AC5 edge] purchase drag in flight -> second begin_purchase_drag on ANY item -> false, flag NOT overwritten")
	var rig := _make_standard_rig(0xB5215)
	var shop: RefCounted = rig["shop"]
	var placement: RefCounted = rig["placement"]

	# First purchase passes the gate; begin the real placement drag.
	_check(bool(shop.call("begin_purchase_drag", "treadmill_01")), "setup: treadmill purchase starts (flag set)")
	placement.call("begin_drag", "treadmill_01")

	# Second attempt while the drag is in flight — can_purchase passes, gate blocks.
	_check(bool(shop.call("can_purchase", "bench_press")), "second item's can_purchase is true (no-op query)")
	_check(not bool(shop.call("begin_purchase_drag", "bench_press")), "second begin_purchase_drag -> false (one-drag)")
	_check(shop.call("get_purchase_equipment_id") == "treadmill_01", "flag NOT overwritten — still treadmill_01 (got '%s')" % shop.call("get_purchase_equipment_id"))
	_check(int(shop.call("get_purchase_cost")) == 350, "flag cost still 350")


# === Palette gate (AC4/AC5) ===

func _test_palette_mouse_down_starts_drag_ac4() -> void:
	print("\n[AC4] palette mouse-down on affordable item -> gate passes -> PlacementSystem drag begins")
	var rig := _make_standard_rig(0xB5221)
	var palette = rig["palette"]
	var placement: RefCounted = rig["placement"]
	var shop: RefCounted = rig["shop"]

	_check(bool(palette.call("on_tile_mouse_down", "treadmill_01")), "palette.on_tile_mouse_down(treadmill_01) -> true (drag started)")
	_check(bool(placement.call("is_dragging")), "PlacementSystem.is_dragging() == true — drag began for the item")
	_check(bool(shop.call("is_purchase_in_flight")), "Shop._purchase_in_flight set (purchase drag in flight)")
	_check(bool(palette.call("is_drag_in_flight")), "palette one-drag invariant active")


func _test_palette_mouse_down_locked_inert() -> void:
	print("\n[AC4 edge] palette mouse-down on locked item -> inert, no drag")
	var rig := _make_standard_rig(0xB5222)
	var palette = rig["palette"]
	var placement: RefCounted = rig["placement"]

	_check(not bool(palette.call("on_tile_mouse_down", "yoga_mat")), "palette.on_tile_mouse_down(yoga_mat) -> false (locked)")
	_check(not bool(placement.call("is_dragging")), "no drag began")


func _test_palette_mouse_down_unaffordable_inert() -> void:
	print("\n[AC4 edge] palette mouse-down on unaffordable item -> inert, no drag")
	var rig := _make_standard_rig(0xB5223)
	var palette = rig["palette"]
	var placement: RefCounted = rig["placement"]
	var economy: RefCounted = rig["economy"]
	economy.call("spend", 400)  # balance 100

	_check(not bool(palette.call("on_tile_mouse_down", "treadmill_01")), "palette.on_tile_mouse_down(treadmill_01) at balance 100 -> false")
	_check(not bool(placement.call("is_dragging")), "no drag began")


func _test_palette_one_drag_invariant_ac5() -> void:
	print("\n[AC5] purchase drag in flight -> second palette mouse-down blocked (palette disabled + structural gate)")
	var rig := _make_standard_rig(0xB5224)
	var palette = rig["palette"]
	var placement: RefCounted = rig["placement"]
	var shop: RefCounted = rig["shop"]

	_check(bool(palette.call("on_tile_mouse_down", "treadmill_01")), "setup: treadmill drag starts")
	_check(not bool(palette.call("on_tile_mouse_down", "bench_press")), "second mouse-down on bench_press -> false (palette disabled)")
	_check(bool(placement.call("is_dragging")), "the in-flight drag is undisturbed")
	_check(shop.call("get_purchase_equipment_id") == "treadmill_01", "flag still treadmill_01 — no second purchase")
	_check(bool(palette.call("is_drag_in_flight")), "one-drag invariant still active")
	_check(not bool(palette.call("on_tile_mouse_down", "treadmill_01")), "even the SAME item's mouse-down is blocked while dragging")


func _test_palette_render_only_mode_no_placement() -> void:
	print("\n[compat] palette without placement injection (story-001 render-only) -> mouse-down inert, no crash")
	var ED := _ED()
	var defs: Array = [_make_def(ED, "treadmill_01", "Treadmill", 350, "")]
	var catalog := _make_catalog(defs)
	var economy := _make_economy(0xB5225)
	var shop := _make_shop(catalog, economy, _make_placement(_make_open_grid(10, 10), catalog))
	var palette = _make_palette(catalog, economy, shop)

	_check(not bool(palette.call("on_tile_mouse_down", "treadmill_01")), "render-only palette mouse-down -> false (no placement wired)")
	_check(not bool(palette.call("is_drag_in_flight")), "no drag invariant active")


func _test_palette_drag_resolution_silent_cancel() -> void:
	print("\n[AC7/AC4] drag resolves (silent cancel) -> palette re-enables AND Shop flag cleared via notify_silent_cancel")
	var rig := _make_standard_rig(0xB5226)
	var palette = rig["palette"]
	var placement: RefCounted = rig["placement"]
	var shop: RefCounted = rig["shop"]
	var economy: RefCounted = rig["economy"]

	_check(bool(palette.call("on_tile_mouse_down", "treadmill_01")), "setup: treadmill drag starts")
	_check(bool(shop.call("is_purchase_in_flight")), "flag set")
	var balance_before: int = int(economy.get("balance"))

	# Silent cancel: PlacementSystem emits NOTHING (AC8/AC9). The palette's
	# per-frame poll detects the drag left DRAGGING without a signal.
	placement.call("on_cancel")
	palette.call("_process", 0.016)

	_check(not bool(palette.call("is_drag_in_flight")), "palette re-enabled after resolution")
	_check(not bool(shop.call("is_purchase_in_flight")), "Shop flag cleared (notify_silent_cancel path)")
	_check(int(economy.get("balance")) == balance_before, "money untouched (no spend on silent cancel — got %d, expected %d)" % [int(economy.get("balance")), balance_before])


# === Spend-on-commit (Core Rules 2/2a/2b) ===

func _test_commit_spend_exactly_once() -> void:
	print("\n[Core Rule 2] full purchase drag -> commit -> Economy.spend(cost) EXACTLY ONCE; flag cleared")
	var rig := _make_standard_rig(0xB5231)
	var palette = rig["palette"]
	var placement: RefCounted = rig["placement"]
	var shop: RefCounted = rig["shop"]
	var economy: RefCounted = rig["economy"]

	# balance_changed spy — spend success emits S6 exactly once with -350.
	var balance_events: Array = []
	economy.connect("balance_changed", func(new_balance: int, delta: int) -> void: balance_events.append([new_balance, delta]))

	_check(bool(palette.call("on_tile_mouse_down", "treadmill_01")), "setup: treadmill drag starts (gate passes)")
	placement.call("on_mouse_moved", Vector2i(3, 3))
	placement.call("on_drop")

	_check(int(economy.get("balance")) == 150, "balance 500 - 350 == 150 (got %d)" % int(economy.get("balance")))
	_check(balance_events.size() == 1, "balance_changed fired exactly once (got %d)" % balance_events.size())
	_check(not bool(shop.call("is_purchase_in_flight")), "flag cleared after commit")
	# Placement completed — the grid actually holds the piece.
	_check(int(rig["grid"].call("get_occupant_id", Vector2i(3, 3))) == 0, "grid holds the placed piece at (3,3)")


func _test_commit_cost0_no_spend_core_rule_2b() -> void:
	print("\n[Core Rule 2b] cost-0 drag commits -> NO Economy.spend(0) call; flag cleared; placement completes; money untouched")
	var ED := _ED()
	var defs: Array = [_make_def(ED, "free_dumbbell", "Free Dumbbell", 0, "")]
	var catalog := _make_catalog(defs)
	var economy := _make_spy_economy(0xB5232)
	var grid := _make_open_grid(10, 10)
	var placement := _make_placement(grid, catalog)
	var shop := _make_shop(catalog, economy, placement)
	var palette = _make_palette(catalog, economy, shop, placement)

	_check(bool(palette.call("on_tile_mouse_down", "free_dumbbell")), "setup: cost-0 drag starts (gate trivially passes)")
	placement.call("on_mouse_moved", Vector2i(2, 2))
	placement.call("on_drop")

	_check(int(economy.get("spend_calls").size()) == 0, "spend() called ZERO times for cost-0 commit (Core Rule 2b — got %d calls)" % int(economy.get("spend_calls").size()))
	_check(int(economy.get("balance")) == 500, "balance untouched (500) after cost-0 commit")
	_check(not bool(shop.call("is_purchase_in_flight")), "flag cleared — placement complete")
	_check(int(grid.call("get_occupant_id", Vector2i(2, 2))) == 0, "placement COMPLETED — grid holds the free piece at (2,2)")


func _test_relocate_commit_ignored_no_spend() -> void:
	print("\n[Core Rule 2a] relocate commit (no flag) -> zero spend, no flag change")
	var rig := _make_standard_rig(0xB5233)
	var placement: RefCounted = rig["placement"]
	var shop: RefCounted = rig["shop"]
	var economy: RefCounted = rig["economy"]

	# A drag that is NOT a purchase: begin_drag directly (SelectionSystem's
	# relocate path never calls Shop.begin_purchase_drag).
	placement.call("begin_drag", "treadmill_01")
	placement.call("on_mouse_moved", Vector2i(1, 1))
	placement.call("on_drop")

	_check(not bool(shop.call("is_purchase_in_flight")), "flag never set (relocate path)")
	_check(int(economy.get("balance")) == 500, "no spend on relocate commit (balance 500)")
	# After the relocate commit the drag is over — a fresh purchase gate works
	# and the flag is set for the NEXT drag only (never confused by the
	# relocate commit that already passed through).
	_check(bool(shop.call("begin_purchase_drag", "bench_press")), "a fresh purchase gate works after a relocate commit")
	_check(shop.call("get_purchase_equipment_id") == "bench_press", "new flag is bench_press — relocate commit left no residue")


func _test_commit_mismatch_no_spend_flag_untouched() -> void:
	print("\n[Core Rule 2 step 3] flag set for A, commit arrives for B -> no spend, flag UNTOUCHED (defensive, expected unreachable)")
	var rig := _make_standard_rig(0xB5234)
	var placement: RefCounted = rig["placement"]
	var shop: RefCounted = rig["shop"]
	var economy: RefCounted = rig["economy"]

	_check(bool(shop.call("begin_purchase_drag", "treadmill_01")), "setup: purchase flag for treadmill_01")
	var events: Array = []
	economy.connect("balance_changed", func(new_balance: int, delta: int) -> void: events.append(delta))

	# Emit a commit carrying the WRONG equipment_id — the defensive branch.
	placement.emit_signal("placement_committed", 7, "bench_press", [Vector2i(0, 0)])

	_check(events.is_empty(), "zero balance_changed emissions (no spend)")
	_check(shop.call("get_purchase_equipment_id") == "treadmill_01", "flag UNTOUCHED — still treadmill_01 (got '%s')" % shop.call("get_purchase_equipment_id"))
	_check(int(shop.call("get_purchase_cost")) == 350, "flag cost still 350")


func _test_reject_clears_flag_no_spend() -> void:
	print("\n[Core Rule 2 step 3] placement_rejected -> flag cleared, zero spend")
	var rig := _make_standard_rig(0xB5235)
	var placement: RefCounted = rig["placement"]
	var shop: RefCounted = rig["shop"]
	var economy: RefCounted = rig["economy"]

	_check(bool(shop.call("begin_purchase_drag", "treadmill_01")), "setup: purchase flag set")
	var events: Array = []
	economy.connect("balance_changed", func(new_balance: int, delta: int) -> void: events.append(delta))

	placement.emit_signal("placement_rejected", "treadmill_01", Vector2i(3, 3), 0, 1)

	_check(events.is_empty(), "zero balance_changed emissions (no spend)")
	_check(not bool(shop.call("is_purchase_in_flight")), "flag cleared after reject")


func _test_silent_cancel_clears_flag_no_spend() -> void:
	print("\n[Core Rule 2 step 3] notify_silent_cancel -> flag cleared, zero spend")
	var rig := _make_standard_rig(0xB5236)
	var shop: RefCounted = rig["shop"]
	var economy: RefCounted = rig["economy"]

	_check(bool(shop.call("begin_purchase_drag", "treadmill_01")), "setup: purchase flag set")
	var events: Array = []
	economy.connect("balance_changed", func(new_balance: int, delta: int) -> void: events.append(delta))

	shop.call("notify_silent_cancel")

	_check(events.is_empty(), "zero balance_changed emissions (no spend)")
	_check(not bool(shop.call("is_purchase_in_flight")), "flag cleared after silent cancel")


# === Hover Save-$X (AC9) ===

func _test_hover_save_more_text() -> void:
	print("\n[AC9] hover on greyed/unaffordable item -> 'Save $X more' with X = cost - balance")
	var rig := _make_standard_rig(0xB5241)
	var palette = rig["palette"]
	var economy: RefCounted = rig["economy"]
	economy.call("spend", 400)  # balance 100; treadmill 350 -> X = 250

	_check(palette.call("get_hover_tooltip", "treadmill_01") == "Save $250 more", "treadmill ($350, balance 100) tooltip == 'Save $250 more' (got '%s')" % palette.call("get_hover_tooltip", "treadmill_01"))
	var tile: Node = palette.call("get_tile", "treadmill_01")
	_check(String(tile.get("tooltip_text")) == "Save $250 more", "tile.tooltip_text wired to the Save-$X text (got '%s')" % String(tile.get("tooltip_text")))


func _test_hover_x0_just_affordable_no_tooltip() -> void:
	print("\n[AC9 edge] X == 0 (balance just meets cost) -> full-tint, NO tooltip")
	var rig := _make_standard_rig(0xB5242)
	var palette = rig["palette"]
	var economy: RefCounted = rig["economy"]
	economy.call("spend", 150)  # balance 350 == treadmill cost

	_check(palette.call("get_hover_tooltip", "treadmill_01") == "", "balance == cost -> no tooltip (X=0 just-affordable edge)")
	var tile: Node = palette.call("get_tile", "treadmill_01")
	_check(int(tile.get("state")) == int(_STATE()["AFFORDABLE"]), "tile full-tint (AFFORDABLE) — the state matches the no-tooltip decision")


func _test_hover_locked_lock_tooltip() -> void:
	print("\n[AC9 edge] locked item -> lock tooltip, NOT Save-$X (Core Rule 5 distinct affordance)")
	var rig := _make_standard_rig(0xB5243)
	var palette = rig["palette"]

	_check(palette.call("get_hover_tooltip", "yoga_mat") == "Locked", "locked tooltip == 'Locked' (got '%s')" % palette.call("get_hover_tooltip", "yoga_mat"))


func _test_hover_affordable_no_tooltip() -> void:
	print("\n[AC9 edge] affordable item -> no tooltip")
	var rig := _make_standard_rig(0xB5244)
	var palette = rig["palette"]

	_check(palette.call("get_hover_tooltip", "bench_press") == "", "affordable item tooltip == '' (got '%s')" % palette.call("get_hover_tooltip", "bench_press"))


# === Guards ===

func _test_shop_use_before_init_guard() -> void:
	print("\n[guard] Shop public methods before init() -> safe defaults, no crash")
	var shop: RefCounted = _SHOP().new()

	_check(not bool(shop.call("can_purchase", "treadmill_01")), "can_purchase before init -> false (safe default)")
	_check(not bool(shop.call("begin_purchase_drag", "treadmill_01")), "begin_purchase_drag before init -> false")
	_check(not bool(shop.call("is_unlocked", "treadmill_01")), "is_unlocked before init -> false")


func _test_shop_init_twice_guard() -> void:
	print("\n[guard] Shop.init() twice -> logged error, no crash, still functional")
	var rig := _make_standard_rig(0xB5245)
	var shop: RefCounted = rig["shop"]
	shop.call("init", rig["catalog"], rig["economy"], rig["placement"])

	_check(bool(shop.call("can_purchase", "treadmill_01")), "still answers queries after double init")


func _test_shop_save_more_before_init() -> void:
	print("\n[guard] get_save_more_amount before init -> -1 (safe default)")
	var shop: RefCounted = _SHOP().new()
	_check(int(shop.call("get_save_more_amount", "treadmill_01")) == -1, "get_save_more_amount before init -> -1")
