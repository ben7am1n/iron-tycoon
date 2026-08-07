# tests/unit/build_shop_ui/drag_feedback_test.gd
# Story BSUI-004: Drag Handoff & Purchase Confirm + Silent-Cancel Cue
# (production/epics/build-shop-ui/story-004-drag-handoff-purchase-confirm.md)
#
# Covers the BLOCKING ACs (TR-BSUI-003 handoff part / TR-BSUI-005 cancel-cue
# part + shop-purchase.md Core Rule 4):
#   - AC7          a placement drag ends (commit/reject/cancel) -> the palette
#                  re-enables AND re-greys against the CURRENT balance.
#                  Edges: commit (balance dropped -> items re-grey);
#                  reject/cancel (balance unchanged -> same grey state).
#   - AC10         a purchase drag that ends in a SILENT cancel (Esc / OOB /
#                  focus-loss — no signal by design) -> the palette item
#                  returns to its idle-state visual with a lightweight
#                  return-to-palette cue (silent_cancel_cue signal + flash),
#                  zero spend. Edge: a gate-swallowed attempt (is_dragging()
#                  already true) never started a drag — no phantom cue.
#   - Core Rule 4  a purchase-initiated drag that successfully lands triggers
#                  the purchase-confirm cue on placement_committed — NOT on
#                  balance_changed. Edge: cost-0 purchase never fires
#                  balance_changed but still confirms; relocate commit (no
#                  palette gate) -> no confirm cue; reject -> no confirm.
#
# Run standalone: godot --headless --script tests/unit/build_shop_ui/drag_feedback_test.gd
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
const PLACEHOLDER_AVAIL_SCRIPT_PATH := "res://src/ui/placeholder_palette_availability.gd"
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
	print("  UNIT TEST: Build/Shop UI — Drag Handoff & Confirm Cues (Story BSUI-004)")
	print("=".repeat(48))

	# AC7 — drag ends -> palette re-enables + re-greys against current balance
	_test_ac7_commit_re_enables_and_regreys()
	_test_ac7_reject_re_enables_same_grey()
	_test_ac7_silent_cancel_re_enables_same_grey()

	# AC10 — silent cancel -> return-to-palette cue
	_test_ac10_esc_cancel_return_cue()
	_test_ac10_oob_drop_return_cue()
	_test_ac10_focus_loss_same_cue()
	_test_ac10_cue_decays_to_idle()
	_test_ac10_swallowed_attempt_no_false_cue()

	# shop-purchase.md Core Rule 4 — purchase-confirm cue on committed
	_test_cr4_commit_triggers_confirm_cue()
	_test_cr4_cost0_confirm_no_balance_changed()
	_test_cr4_relocate_commit_no_confirm()
	_test_cr4_reject_no_confirm()
	_test_cr4_confirm_cue_decays()
	_test_cr4_balance_change_alone_no_confirm()
	_test_cr4_mismatch_commit_no_confirm()

	# Guards / contract
	_test_placeholder_is_purchase_in_flight_false()
	_test_render_only_no_crash_cue_queries()

	_free_test_nodes()

	print("\n=== DRAG FEEDBACK TEST: %d passed, %d failed ===\n" % [_pass, _fail])
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


func _PLACEHOLDER() -> Script:
	return load(PLACEHOLDER_AVAIL_SCRIPT_PATH) as Script


## The PaletteTile.State enum values, read from the real script's constant
## map (never duplicated in the test — an enum reorder breaks the test).
var _tile_state_consts: Dictionary = {}


func _STATE() -> Dictionary:
	if _tile_state_consts.is_empty():
		var consts: Dictionary = _TILE().get_script_constant_map()
		_tile_state_consts = consts["State"]
	return _tile_state_consts


## Story-004 palette constants, read from the real script (CUE_DURATION,
## the modulate flash colors). Same anti-duplication pattern as _STATE().
var _palette_consts: Dictionary = {}


func _PC() -> Dictionary:
	if _palette_consts.is_empty():
		_palette_consts = _PALETTE().get_script_constant_map()
	return _palette_consts


func _cue_duration() -> float:
	return float(_PC()["CUE_DURATION"])


func _confirm_flash() -> Color:
	return _PC()["CONFIRM_CUE_MODULATE"] as Color


func _return_flash() -> Color:
	return _PC()["RETURN_CUE_MODULATE"] as Color


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


## SpendSpyEconomy — a real Economy subclass that records spend() calls then
## delegates to the real implementation. Proves the cost-0 Core Rule 2b skip
## (spend NOT called for free items) at the call site, which balance
## inspection alone cannot distinguish from a rejected call.
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


## Places a piece via the REAL PlacementSystem flow (begin_drag → mouse-move
## preview → drop) WITHOUT the palette gate — the "non-purchase" direct drag
## used to set up occupancy / relocate-commit scenarios.
func _place_direct(placement: RefCounted, equipment_id: String, anchor: Vector2i) -> int:
	var id_before: int = placement.call("get_next_instance_id")
	placement.call("begin_drag", equipment_id)
	placement.call("on_mouse_moved", anchor)
	placement.call("on_drop")
	return id_before


## Spends down the balance so an item becomes unaffordable: balance 500 →
## spend(400) → balance 100 → treadmill ($350) AND bench_press ($200) grey.
func _make_balance_100(economy: RefCounted) -> void:
	economy.call("spend", 400)


## Connects a spy to [palette]'s purchase_confirm_cue signal; returns the
## event array (each entry: the equipment_id String).
func _spy_confirm(palette) -> Array:
	var events: Array = []
	palette.connect("purchase_confirm_cue", func(eq: String) -> void: events.append(eq))
	return events


## Connects a spy to [palette]'s silent_cancel_cue signal; returns the event
## array (each entry: the equipment_id String).
func _spy_return(palette) -> Array:
	var events: Array = []
	palette.connect("silent_cancel_cue", func(eq: String) -> void: events.append(eq))
	return events


## SpendSpyEconomy — real Economy behavior + recorded spend() calls.
class SpendSpyEconomy:
	extends EconomyScript

	var spend_calls: Array = []

	func spend(amount: int) -> bool:
		spend_calls.append(amount)
		return super(amount)


# === AC7 — drag ends -> palette re-enables + re-greys ===

func _test_ac7_commit_re_enables_and_regreys() -> void:
	print("\n[AC7] commit resolves -> palette re-enables AND re-greys against the new balance")
	var rig := _make_standard_rig(0xB5401)
	var palette = rig["palette"]
	var placement: RefCounted = rig["placement"]
	var economy: RefCounted = rig["economy"]

	# Setup: both items affordable at balance 500.
	_check(int(palette.call("get_state", "treadmill_01")) == int(_STATE()["AFFORDABLE"]), "setup: treadmill AFFORDABLE at 500")
	_check(int(palette.call("get_state", "bench_press")) == int(_STATE()["AFFORDABLE"]), "setup: bench_press AFFORDABLE at 500")

	_check(bool(palette.call("on_tile_mouse_down", "treadmill_01")), "setup: treadmill drag starts (gate passes)")
	_check(bool(palette.call("is_drag_in_flight")), "setup: palette disabled (one-drag invariant active)")
	placement.call("on_mouse_moved", Vector2i(3, 3))
	placement.call("on_drop")  # commit: placement_committed -> Shop spend(350)

	_check(int(economy.get("balance")) == 150, "balance 500 - 350 == 150 (got %d)" % int(economy.get("balance")))

	# The drag resolved -> the poll must re-enable + re-grey.
	palette.call("_process", 0.016)

	_check(not bool(palette.call("is_drag_in_flight")), "AC7 — palette re-enabled after commit")
	_check(int(palette.call("get_state", "treadmill_01")) == int(_STATE()["UNAFFORDABLE"]), "AC7 — treadmill re-greyed (balance 150 < 350)")
	_check(int(palette.call("get_state", "bench_press")) == int(_STATE()["UNAFFORDABLE"]), "AC7 — bench_press re-greyed too (balance 150 < 200, was AFFORDABLE)")
	_check(int(palette.call("get_state", "free_dumbbell")) == int(_STATE()["AFFORDABLE"]), "AC7 — free_dumbbell stays full-tint (cost-0 always affordable)")

	# After the confirm cue decays the palette returns to idle white.
	palette.call("_process", _cue_duration() + 0.1)
	_check(palette.get("modulate") == Color.WHITE, "AC7 — palette modulate back to idle WHITE after cue decay")


func _test_ac7_reject_re_enables_same_grey() -> void:
	print("\n[AC7 edge] rejected drop resolves -> palette re-enables, balance unchanged -> same grey state")
	var rig := _make_standard_rig(0xB5402)
	var palette = rig["palette"]
	var placement: RefCounted = rig["placement"]
	var economy: RefCounted = rig["economy"]

	# Occupy (1,1) so a later drag there is REJECTED (overlap).
	_place_direct(placement, "treadmill_01", Vector2i(1, 1))
	_check(not bool(palette.call("is_drag_in_flight")), "setup: direct placement did not touch the palette drag state")

	_check(bool(palette.call("on_tile_mouse_down", "bench_press")), "setup: bench_press drag starts (affordable)")
	placement.call("on_mouse_moved", Vector2i(1, 1))  # occupied cell -> preview invalid
	placement.call("on_drop")  # rejected: placement_rejected -> Shop clears flag

	_check(int(economy.get("balance")) == 500, "no spend on reject (balance 500)")

	palette.call("_process", 0.016)

	_check(not bool(palette.call("is_drag_in_flight")), "AC7 — palette re-enabled after reject")
	_check(int(palette.call("get_state", "bench_press")) == int(_STATE()["AFFORDABLE"]), "AC7 — bench_press still AFFORDABLE (balance unchanged 500 — same grey state)")
	_check(not bool(palette.call("is_return_cue_active")), "reject is a SIGNALLED resolution — no silent-cancel return cue")
	_check(not bool(palette.call("is_confirm_cue_active")), "reject is not a commit — no purchase-confirm cue")
	_check(palette.get("modulate") == Color.WHITE, "palette modulate idle WHITE after reject (no cue flash)")


func _test_ac7_silent_cancel_re_enables_same_grey() -> void:
	print("\n[AC7 edge] silent cancel resolves -> palette re-enables, balance unchanged -> same grey state (cue asserted in AC10 tests)")
	var rig := _make_standard_rig(0xB5403)
	var palette = rig["palette"]
	var placement: RefCounted = rig["placement"]
	var economy: RefCounted = rig["economy"]
	var shop: RefCounted = rig["shop"]

	_check(bool(palette.call("on_tile_mouse_down", "treadmill_01")), "setup: treadmill drag starts")
	placement.call("on_cancel")  # silent cancel — no signal of any kind
	palette.call("_process", 0.016)

	_check(not bool(palette.call("is_drag_in_flight")), "AC7 — palette re-enabled after silent cancel")
	_check(int(economy.get("balance")) == 500, "no spend on silent cancel (balance 500)")
	_check(not bool(shop.call("is_purchase_in_flight")), "Shop flag cleared via notify_silent_cancel")
	_check(int(palette.call("get_state", "treadmill_01")) == int(_STATE()["AFFORDABLE"]), "AC7 — treadmill still AFFORDABLE (balance unchanged — same grey state)")


# === AC10 — silent cancel -> return-to-palette cue ===

func _test_ac10_esc_cancel_return_cue() -> void:
	print("\n[AC10] Esc-cancel (silent, no signal) -> palette item returns to idle visual WITH the return cue")
	var rig := _make_standard_rig(0xB5411)
	var palette = rig["palette"]
	var placement: RefCounted = rig["placement"]
	var economy: RefCounted = rig["economy"]
	var shop: RefCounted = rig["shop"]
	var confirm_events := _spy_confirm(palette)
	var return_events := _spy_return(palette)

	_check(bool(palette.call("on_tile_mouse_down", "treadmill_01")), "setup: treadmill drag starts (gate passes, flag set)")
	_check(bool(shop.call("is_purchase_in_flight")), "setup: purchase flag in flight")
	placement.call("on_cancel")  # Esc — PlacementSystem emits NOTHING

	palette.call("_process", 0.016)  # the poll detects the silent resolution

	_check(bool(palette.call("is_return_cue_active")), "AC10 — return cue ACTIVE (resolution is not invisible)")
	_check(palette.call("get_return_cue_equipment_id") == "treadmill_01", "AC10 — return cue names treadmill_01 (got '%s')" % palette.call("get_return_cue_equipment_id"))
	_check(return_events.size() == 1, "AC10 — silent_cancel_cue fired EXACTLY once (got %d)" % return_events.size())
	_check(return_events[0] == "treadmill_01", "AC10 — silent_cancel_cue payload == treadmill_01 (got '%s')" % return_events[0])
	_check(confirm_events.is_empty(), "AC10 — no purchase-confirm signal on a cancel")
	_check(not bool(palette.call("is_confirm_cue_active")), "AC10 — no confirm cue on a cancel")
	_check(not bool(shop.call("is_purchase_in_flight")), "Shop flag cleared (notify_silent_cancel — zero spend)")
	_check(int(economy.get("balance")) == 500, "money untouched on silent cancel")
	_check(not bool(palette.call("is_drag_in_flight")), "palette re-enabled")
	_check(int(palette.call("get_state", "treadmill_01")) == int(_STATE()["AFFORDABLE"]), "item returned to its idle-state visual (AFFORDABLE, full-tint)")
	_check(palette.get("modulate") == _return_flash(), "return flash modulate is the soft warm-white (got %s)" % str(palette.get("modulate")))


func _test_ac10_oob_drop_return_cue() -> void:
	print("\n[AC10 edge] out-of-bounds drop (silent cancel) -> same return cue, no spend")
	var rig := _make_standard_rig(0xB5412)
	var palette = rig["palette"]
	var placement: RefCounted = rig["placement"]
	var economy: RefCounted = rig["economy"]
	var return_events := _spy_return(palette)

	_check(bool(palette.call("on_tile_mouse_down", "bench_press")), "setup: bench_press drag starts")
	placement.call("on_mouse_moved", Vector2i(50, 50))  # way outside the 10x10 grid
	placement.call("on_drop")  # OOB drop -> silent cancel (AC8 — NO signal)
	palette.call("_process", 0.016)

	_check(bool(palette.call("is_return_cue_active")), "AC10 — return cue ACTIVE after OOB drop")
	_check(palette.call("get_return_cue_equipment_id") == "bench_press", "return cue names bench_press (got '%s')" % palette.call("get_return_cue_equipment_id"))
	_check(return_events.size() == 1, "silent_cancel_cue fired exactly once (got %d)" % return_events.size())
	_check(int(economy.get("balance")) == 500, "no spend on OOB silent cancel")
	_check(not bool(palette.call("is_drag_in_flight")), "palette re-enabled")


func _test_ac10_focus_loss_same_cue() -> void:
	print("\n[AC10 edge] focus-loss cancel (alt-tab etc.) -> same return cue (AC17 routes to the same silent-cancel path)")
	var rig := _make_standard_rig(0xB5413)
	var palette = rig["palette"]
	var placement: RefCounted = rig["placement"]
	var economy: RefCounted = rig["economy"]
	var return_events := _spy_return(palette)

	_check(bool(palette.call("on_tile_mouse_down", "treadmill_01")), "setup: treadmill drag starts")
	placement.call("on_focus_lost")
	palette.call("_process", 0.016)

	_check(bool(palette.call("is_return_cue_active")), "AC10 — return cue ACTIVE after focus-loss")
	_check(palette.call("get_return_cue_equipment_id") == "treadmill_01", "return cue names treadmill_01")
	_check(return_events.size() == 1, "silent_cancel_cue fired exactly once")
	_check(int(economy.get("balance")) == 500, "no spend on focus-loss cancel")


func _test_ac10_cue_decays_to_idle() -> void:
	print("\n[AC10 edge] the return cue is self-limiting — decays to idle after CUE_DURATION")
	var rig := _make_standard_rig(0xB5414)
	var palette = rig["palette"]
	var placement: RefCounted = rig["placement"]

	_check(bool(palette.call("on_tile_mouse_down", "treadmill_01")), "setup: drag starts")
	placement.call("on_cancel")
	palette.call("_process", 0.016)
	_check(bool(palette.call("is_return_cue_active")), "setup: return cue active")
	_check(palette.get("modulate") == _return_flash(), "setup: flash showing")

	palette.call("_process", _cue_duration() + 0.1)  # past the lifetime

	_check(not bool(palette.call("is_return_cue_active")), "return cue cleared after CUE_DURATION")
	_check(palette.call("get_return_cue_equipment_id") == "", "return equipment id cleared")
	_check(not bool(palette.call("is_confirm_cue_active")), "no confirm cue residue")
	_check(palette.get("modulate") == Color.WHITE, "modulate back to idle WHITE")


func _test_ac10_swallowed_attempt_no_false_cue() -> void:
	print("\n[AC10 edge] gate-swallowed attempt (is_dragging() already true) — nothing ever started, so NO phantom cue")
	print("       (the item never left its idle visual; a return flash on an inert item would be noise, not feedback)")
	var rig := _make_standard_rig(0xB5415)
	var palette = rig["palette"]
	var placement: RefCounted = rig["placement"]
	var confirm_events := _spy_confirm(palette)
	var return_events := _spy_return(palette)

	# Simulate an existing drag (e.g. a relocate in flight via SelectionSystem).
	placement.call("_test_set_dragging", true)

	_check(not bool(palette.call("on_tile_mouse_down", "treadmill_01")), "palette mouse-down blocked by Shop's is_dragging() backstop (Core Rule 2 step 1)")
	_check(not bool(palette.call("is_drag_in_flight")), "no drag invariant set — nothing started")
	_check(not bool(palette.call("is_return_cue_active")), "no return cue — the item never left idle")
	_check(not bool(palette.call("is_confirm_cue_active")), "no confirm cue")
	_check(confirm_events.is_empty(), "no purchase_confirm_cue signal")
	_check(return_events.is_empty(), "no silent_cancel_cue signal")
	_check(palette.get("modulate") == Color.WHITE, "palette never dimmed — still idle WHITE")

	placement.call("_test_set_dragging", false)


# === shop-purchase.md Core Rule 4 — purchase-confirm cue on committed ===

func _test_cr4_commit_triggers_confirm_cue() -> void:
	print("\n[Core Rule 4] purchase-initiated drag lands -> purchase-confirm cue triggers ON placement_committed")
	var rig := _make_standard_rig(0xB5421)
	var palette = rig["palette"]
	var placement: RefCounted = rig["placement"]
	var economy: RefCounted = rig["economy"]
	var shop: RefCounted = rig["shop"]
	var confirm_events := _spy_confirm(palette)

	_check(bool(palette.call("on_tile_mouse_down", "treadmill_01")), "setup: treadmill purchase drag starts")
	placement.call("on_mouse_moved", Vector2i(3, 3))
	placement.call("on_drop")  # commit

	_check(bool(palette.call("is_confirm_cue_active")), "Core Rule 4 — confirm cue ACTIVE after the commit")
	_check(palette.call("get_confirm_cue_equipment_id") == "treadmill_01", "confirm cue names treadmill_01 (got '%s')" % palette.call("get_confirm_cue_equipment_id"))
	_check(confirm_events.size() == 1, "purchase_confirm_cue fired EXACTLY once (got %d)" % confirm_events.size())
	_check(confirm_events[0] == "treadmill_01", "purchase_confirm_cue payload == treadmill_01 (got '%s')" % confirm_events[0])
	_check(int(economy.get("balance")) == 150, "paid purchase spent exactly once (balance 150)")
	_check(not bool(shop.call("is_purchase_in_flight")), "Shop flag cleared at commit")
	_check(not bool(palette.call("is_return_cue_active")), "no return cue on a commit")


func _test_cr4_cost0_confirm_no_balance_changed() -> void:
	print("\n[Core Rule 4 edge] cost-0 purchase commits -> confirm cue fires even though NO balance_changed ever fires")
	print("       (Core Rule 2b skips spend(0); the confirm lives on placement_committed, not on the balance signal)")
	var ED := _ED()
	var defs: Array = [_make_def(ED, "free_dumbbell", "Free Dumbbell", 0, "")]
	var catalog := _make_catalog(defs)
	var economy := _make_spy_economy(0xB5422)
	var grid := _make_open_grid(10, 10)
	var placement := _make_placement(grid, catalog)
	var shop := _make_shop(catalog, economy, placement)
	var palette = _make_palette(catalog, economy, shop, placement)
	var confirm_events := _spy_confirm(palette)
	var balance_events: Array = []
	economy.connect("balance_changed", func(new_balance: int, delta: int) -> void: balance_events.append([new_balance, delta]))

	_check(bool(palette.call("on_tile_mouse_down", "free_dumbbell")), "setup: cost-0 drag starts (gate trivially passes)")
	placement.call("on_mouse_moved", Vector2i(2, 2))
	placement.call("on_drop")

	_check(int(economy.get("spend_calls").size()) == 0, "Core Rule 2b — spend() NOT called for cost-0 (got %d calls)" % int(economy.get("spend_calls").size()))
	_check(balance_events.is_empty(), "no balance_changed fired for the cost-0 purchase (got %d)" % balance_events.size())
	_check(bool(palette.call("is_confirm_cue_active")), "Core Rule 4 — confirm cue STILL fires (on committed, not balance_changed)")
	_check(palette.call("get_confirm_cue_equipment_id") == "free_dumbbell", "confirm cue names free_dumbbell")
	_check(confirm_events.size() == 1, "purchase_confirm_cue fired exactly once (got %d)" % confirm_events.size())
	_check(int(economy.get("balance")) == 500, "money untouched for the free item")
	_check(int(grid.call("get_occupant_id", Vector2i(2, 2))) == 0, "placement COMPLETED — grid holds the free piece at (2,2)")


func _test_cr4_relocate_commit_no_confirm() -> void:
	print("\n[Core Rule 4 edge] RELOCATE commit (no palette gate) -> NO purchase-confirm cue (Core Rule 2a)")
	var rig := _make_standard_rig(0xB5423)
	var palette = rig["palette"]
	var placement: RefCounted = rig["placement"]
	var confirm_events := _spy_confirm(palette)

	# A real relocate: place a piece (direct, not via palette), then relocate it.
	var placed_id: int = _place_direct(placement, "treadmill_01", Vector2i(1, 1))
	placement.call("begin_relocate", placed_id)
	placement.call("on_mouse_moved", Vector2i(2, 2))
	placement.call("on_drop")  # re-commit under the SAME instance_id -> placement_committed

	_check(not bool(palette.call("is_confirm_cue_active")), "Core Rule 4 — relocate commit produces NO confirm cue")
	_check(confirm_events.is_empty(), "no purchase_confirm_cue signal for a relocate")
	_check(not bool(palette.call("is_drag_in_flight")), "palette never tracked the relocate")


func _test_cr4_reject_no_confirm() -> void:
	print("\n[Core Rule 4 edge] rejected drop -> NO confirm cue (only a commit confirms)")
	var rig := _make_standard_rig(0xB5424)
	var palette = rig["palette"]
	var placement: RefCounted = rig["placement"]
	var confirm_events := _spy_confirm(palette)
	var return_events := _spy_return(palette)

	_place_direct(placement, "treadmill_01", Vector2i(1, 1))
	_check(bool(palette.call("on_tile_mouse_down", "bench_press")), "setup: bench_press drag starts")
	placement.call("on_mouse_moved", Vector2i(1, 1))  # occupied -> reject
	placement.call("on_drop")
	palette.call("_process", 0.016)

	_check(not bool(palette.call("is_confirm_cue_active")), "no confirm cue on a reject")
	_check(confirm_events.is_empty(), "no purchase_confirm_cue signal on a reject")
	_check(not bool(palette.call("is_return_cue_active")), "no return cue on a reject either (reject is signalled — CFO-004 owns reject feedback)")


func _test_cr4_confirm_cue_decays() -> void:
	print("\n[Core Rule 4 edge] the confirm cue is self-limiting — decays to idle after CUE_DURATION")
	var rig := _make_standard_rig(0xB5425)
	var palette = rig["palette"]
	var placement: RefCounted = rig["placement"]

	_check(bool(palette.call("on_tile_mouse_down", "treadmill_01")), "setup: drag starts")
	placement.call("on_mouse_moved", Vector2i(3, 3))
	placement.call("on_drop")
	_check(bool(palette.call("is_confirm_cue_active")), "setup: confirm cue active")
	_check(palette.get("modulate") == _confirm_flash(), "setup: confirm flash showing (got %s)" % str(palette.get("modulate")))

	palette.call("_process", _cue_duration() + 0.1)

	_check(not bool(palette.call("is_confirm_cue_active")), "confirm cue cleared after CUE_DURATION")
	_check(palette.call("get_confirm_cue_equipment_id") == "", "confirm equipment id cleared")
	_check(palette.get("modulate") == Color.WHITE, "modulate back to idle WHITE")


func _test_cr4_balance_change_alone_no_confirm() -> void:
	print("\n[Core Rule 4 discriminator] a balance change WITHOUT a commit fires NO confirm cue — the cue is commit-driven")
	var rig := _make_standard_rig(0xB5426)
	var palette = rig["palette"]
	var economy: RefCounted = rig["economy"]
	var confirm_events := _spy_confirm(palette)

	economy.call("spend", 50)  # balance_changed fires (S6) — palette re-greys, but no placement happened

	_check(not bool(palette.call("is_confirm_cue_active")), "no confirm cue on balance_changed alone")
	_check(confirm_events.is_empty(), "no purchase_confirm_cue signal on balance_changed alone")
	_check(not bool(palette.call("is_return_cue_active")), "no return cue either")


func _test_cr4_mismatch_commit_no_confirm() -> void:
	print("\n[Core Rule 4 defensive] commit for a DIFFERENT equipment_id while a palette drag is in flight -> no confirm cue (flag-style mismatch guard)")
	var rig := _make_standard_rig(0xB5427)
	var palette = rig["palette"]
	var placement: RefCounted = rig["placement"]
	var confirm_events := _spy_confirm(palette)

	_check(bool(palette.call("on_tile_mouse_down", "treadmill_01")), "setup: treadmill drag in flight")
	# Typed array — emit_signal passes Variants and a raw Array literal would
	# fail the Array[Vector2i] handler conversion (handler never called, which
	# would make this test vacuous).
	var fp: Array[Vector2i] = [Vector2i(0, 0)]
	placement.emit_signal("placement_committed", 7, "bench_press", fp)  # wrong equipment

	_check(not bool(palette.call("is_confirm_cue_active")), "mismatched commit -> NO confirm cue (defensive)")
	_check(confirm_events.is_empty(), "no purchase_confirm_cue signal for the mismatch")

	# Clean up the drag (silent cancel) so the rig tears down cleanly.
	placement.call("on_cancel")
	palette.call("_process", 0.016)
	_check(not bool(palette.call("is_drag_in_flight")), "teardown: drag resolved")


# === Guards / contract ===

func _test_placeholder_is_purchase_in_flight_false() -> void:
	print("\n[contract] PlaceholderPaletteAvailability.is_purchase_in_flight() -> false (the placeholder never sets a flag)")
	var defs: Array = [_make_def(_ED(), "treadmill_01", "Treadmill", 350, "")]
	var catalog := _make_catalog(defs)
	var economy := _make_economy(0xB5431)
	var placeholder: RefCounted = _PLACEHOLDER().new(catalog, economy)

	_check(not bool(placeholder.call("is_purchase_in_flight")), "placeholder is_purchase_in_flight() == false")


func _test_render_only_no_crash_cue_queries() -> void:
	print("\n[compat] render-only palette (no placement injection) -> _process + cue queries safe, no crash")
	var defs: Array = [_make_def(_ED(), "treadmill_01", "Treadmill", 350, "")]
	var catalog := _make_catalog(defs)
	var economy := _make_economy(0xB5432)
	var placeholder: RefCounted = _PLACEHOLDER().new(catalog, economy)
	var palette = _make_palette(catalog, economy, placeholder)

	palette.call("_process", 0.016)

	_check(not bool(palette.call("is_drag_in_flight")), "no drag invariant in render-only mode")
	_check(not bool(palette.call("is_confirm_cue_active")), "confirm cue query false")
	_check(not bool(palette.call("is_return_cue_active")), "return cue query false")
	_check(palette.call("get_confirm_cue_equipment_id") == "", "confirm equipment id empty")
	_check(palette.call("get_return_cue_equipment_id") == "", "return equipment id empty")
	_check(palette.get("modulate") == Color.WHITE, "modulate idle WHITE")
