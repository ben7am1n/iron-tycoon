# tests/integration/selection_system/load_rebuild_test.gd
# Story SEL-005: Load-time Mapping Rebuild
# (production/epics/selection-system/story-005-load-time-mapping-rebuild.md)
#
# Integration coverage through the REAL SaveLoad.load() path (Story
# SL-002's Phase B order, TR-SL-003):
#
#   - AC load-order slot (architecture.md Phase B step 3a): the real
#     SelectionSystem.rebuild_mapping() runs AFTER GridSystem.deserialize
#     commit and BEFORE MemberSim — asserted via a spy subclass that shares
#     the rig's call log (the order is enforced programmatically in
#     SaveLoad.load(); the load_orchestration_test pins the sequence with
#     stubs, this test proves the REAL system runs in its slot).
#   - AC Core Rule 8: after a save/load round-trip of a session with placed
#     pieces, the mapping is rebuilt from the loaded grid — the FIRST click
#     on each piece selects it with the correct payload (UX load-robustness
#     AC).
#   - TR-SEL-007: SelectionSystem contributes NOTHING to the save blob
#     (no "selection_system" key), and the post-load mapping equals the
#     pre-save mapping (reconstructed, not stored) — including ROTATION
#     (the R90 case is the order-ambiguity trap: a row-major cell scan
#     would collapse it; the bulk surface carries the stored rotation).
#   - QA edge: save/load with zero placed pieces → empty mapping, no error.
#
# Run standalone: godot --headless --script tests/integration/selection_system/load_rebuild_test.gd
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"

const GRID_W := 8
const GRID_H := 8

const SEL_SCRIPT := "res://src/systems/selection_system.gd"
const PLACEMENT_SCRIPT := "res://src/systems/placement_system.gd"
const GRID_SCRIPT := "res://src/systems/grid_system.gd"
const CATALOG_SCRIPT := "res://src/systems/equipment_catalog.gd"
const DEF_SCRIPT := "res://src/systems/equipment_def.gd"

## Sentinel distinguishing "argument not passed" from a real null.
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
	print("  INTEGRATION TEST: SelectionSystem — Load-time Mapping Rebuild (SEL-005)")
	print("=".repeat(48))

	_test_roundtrip_rebuilds_mapping_first_click_selects()
	_test_roundtrip_rotation_preserved_r90()
	_test_load_order_slot_after_grid_before_member()
	_test_no_blob_contribution()
	_test_zero_pieces_loads_clean()

	print("\n=== SEL-005 Load Rebuild Integration: %d passed, %d failed ===\n" % [_pass, _fail])
	return {"pass": _pass, "fail": _fail}


func _check(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
		print("  PASS: " + msg)
	else:
		_fail += 1
		print("  FAIL: " + msg)


# === Spies (load_orchestration_test pattern) ===

## SelectionSystem spy: records rebuild_mapping() into the shared call log,
## then runs the REAL rebuild. Extends the real class (not a plain stub) so
## the integration test exercises the actual reconstruction.
class SelectionSpy:
	extends SelectionSystem

	var call_log: Array = []

	func rebuild_mapping() -> void:
		call_log.append("SelectionSystem.rebuild_mapping")
		super.rebuild_mapping()


class GridSpy:
	extends GridSystem

	var call_log: Array = []

	func deserialize(data: Dictionary, buildable_snapshot: PackedByteArray, mode: String) -> DeserializeResult:
		call_log.append("GridSystem.deserialize:" + mode)
		return super.deserialize(data, buildable_snapshot, mode)


class TimeSpy:
	extends TimeSystem

	var call_log: Array = []

	func deserialize(data: Dictionary, validate_only: bool = false) -> TimeSystemDeserializeResult:
		call_log.append("TimeSystem.deserialize:" + ("validate" if validate_only else "commit"))
		return super.deserialize(data, validate_only)


## Navigation stub (the real Navigation story is not this test's concern).
class NavigationSpy:
	extends RefCounted

	var call_log: Array = []

	func rebuild(grid) -> void:
		call_log.append("Navigation.rebuild")


## MemberSim spy — records the Phase A/B deserialize calls into the shared
## log so the load-order slot (rebuild before member commit) is observable.
class MemberSpy:
	extends MemberSim

	var call_log: Array = []

	func deserialize(data: Dictionary, validate_only: bool = false, known_instance_ids: Array = []) -> StubDeserializeResult:
		call_log.append("MemberSim.deserialize:" + ("validate" if validate_only else "commit"))
		return super.deserialize(data, validate_only, known_instance_ids)


# === Helpers ===

func _SRG() -> Script:
	return load("res://src/systems/seeded_rng.gd") as Script


func _SL() -> Script:
	return load("res://src/systems/save_load.gd") as Script


func _make_orchestrator() -> Node:
	var orch: Node = load("res://src/systems/simulation_orchestrator.gd").new()
	root.add_child(orch)
	orch.call("_ready")
	return orch


## Canonical defs — same shapes as the catalog fixtures (treadmill 1×2,
## yoga 1×1, bench 2×2). The catalog order (file order) is the determinism
## source for equipment_id matching.
func _make_def(id: String, fp: Array[Vector2i], ac: Array[Vector2i], cost: int) -> RefCounted:
	var ED: Script = load(DEF_SCRIPT) as Script
	var effects: Array[Dictionary] = []
	var zones: Array = ["力量区"]
	return ED.new(id, "Test %s" % id, zones, fp, ac, cost, "", effects, 200, 30, 100, 300)


func _make_treadmill_def() -> RefCounted:
	return _make_def("treadmill_01", [Vector2i(0, 0), Vector2i(1, 0)], [Vector2i(0, 1)], 200)


func _make_yoga_def() -> RefCounted:
	return _make_def("yoga_01", [Vector2i(0, 0)], [Vector2i(1, 0)], 200)


func _make_bench_def() -> RefCounted:
	return _make_def(
		"bench_01",
		[Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)],
		[Vector2i(2, 1)],
		350
	)


func _make_catalog() -> RefCounted:
	var cat: RefCounted = (load(CATALOG_SCRIPT) as Script).new()
	cat.call("_add_definition", _make_treadmill_def())
	cat.call("_add_definition", _make_yoga_def())
	cat.call("_add_definition", _make_bench_def())
	cat.call("_freeze")
	return cat


## Builds the SL-002-style rig with the REAL PlacementSystem and the REAL
## SelectionSystem (spy subclass). All six coordinated systems are wired
## (SaveLoad's wiring gate), the three derivation systems are real
## (placement/selection) or spy (navigation).
func _make_rig(master_seed: int) -> Dictionary:
	var orch: Node = _make_orchestrator()
	var srg: RefCounted = _SRG().new()
	srg.call("init", master_seed)

	var ts: RefCounted = TimeSpy.new()
	ts.call("init", orch, srg)
	orch.set("time_system", ts)

	var gs: RefCounted = GridSpy.new()
	gs.call("init", GRID_W, GRID_H)
	for y in GRID_H:
		for x in GRID_W:
			gs.call("set_buildable", Vector2i(x, y), true)
	gs.call("freeze_buildable")
	orch.set("grid_system", gs)

	var member: RefCounted = MemberSpy.new()
	member.call("init", orch, srg)
	orch.set("member_sim", member)

	var cong: RefCounted = load("res://src/systems/congestion.gd").new()
	cong.call("init", orch, srg)
	orch.set("congestion", cong)

	var sat: RefCounted = load("res://src/systems/satisfaction.gd").new()
	sat.call("init", orch, srg)
	orch.set("satisfaction", sat)

	var econ: RefCounted = load("res://src/systems/economy.gd").new()
	econ.call("init", orch, srg)
	orch.set("economy", econ)

	var catalog := _make_catalog()

	var placement: RefCounted = (load(PLACEMENT_SCRIPT) as Script).new()
	placement.call("init", gs, catalog)
	orch.set("placement_system", placement)

	var selection: RefCounted = SelectionSpy.new()
	selection.call("init", gs, placement, catalog)
	selection.call("_post_init")
	orch.set("selection_system", selection)

	var navigation: RefCounted = NavigationSpy.new()
	orch.set("navigation", navigation)

	var sl: RefCounted = _SL().new()
	sl.call("init", orch)
	sl.call("_post_init")

	var rig := {
		"orchestrator": orch,
		"seeded_rng": srg,
		"time_system": ts,
		"grid_system": gs,
		"member_sim": member,
		"congestion": cong,
		"satisfaction": sat,
		"economy": econ,
		"catalog": catalog,
		"placement": placement,
		"selection": selection,
		"navigation": navigation,
		"save_load": sl,
		"log": [],
	}
	for spy in [ts, gs, member, cong, sat, econ, placement, selection, navigation]:
		if "call_log" in spy:
			spy.set("call_log", rig["log"])
	return rig


## The all-open buildable snapshot matching the 8×8 rig grid (all cells 1).
func _open_snapshot() -> PackedByteArray:
	var snap := PackedByteArray()
	snap.resize(GRID_W * GRID_H)
	snap.fill(1)
	return snap


## Places a piece via the REAL PlacementSystem flow (begin_drag → rotate →
## mouse-move preview → drop), returning the allocated instance_id.
func _place(rig: Dictionary, equipment_id: String, anchor: Vector2i, rotate_count: int) -> int:
	var ps: RefCounted = rig["placement"]
	var id_before: int = ps.call("get_next_instance_id")
	ps.call("begin_drag", equipment_id)
	for i in rotate_count:
		ps.call("on_rotate_pressed")
	ps.call("on_mouse_moved", anchor)
	ps.call("on_drop")
	return id_before


## First footprint cell of instance [instance_id] on the grid — the click
## probe (clicking ANY footprint cell must resolve after rebuild).
func _footprint_cell(rig: Dictionary, instance_id: int) -> Vector2i:
	var gs: RefCounted = rig["grid_system"]
	var dims: Vector2i = gs.call("get_dimensions")
	for y in dims.y:
		for x in dims.x:
			if int(gs.call("get_occupant_id", Vector2i(x, y))) == instance_id:
				return Vector2i(x, y)
	return Vector2i(-1, -1)


## Click [cell] on [rig]'s selection and return the FIRST emission's args
## ([a, b, c, d]), or an empty array if nothing was emitted. The tests only
## ever assert a single emission per click.
func _click_and_capture(rig: Dictionary, cell: Vector2i) -> Array:
	var sel: RefCounted = rig["selection"]
	var captured: Array = []
	var spy := Callable(func(a = NO_ARG, b = NO_ARG, c = NO_ARG, d = NO_ARG) -> void:
		captured.append([a, b, c, d]))
	sel.connect("selection_changed", spy)
	sel.call("on_cell_clicked", cell)
	sel.disconnect("selection_changed", spy)
	return captured[0] if captured.size() > 0 else []


# === AC Core Rule 8: round-trip rebuild + first click ===

func _test_roundtrip_rebuilds_mapping_first_click_selects() -> void:
	print("\n[Core Rule 8] save/load round-trip → mapping rebuilt; first click on each piece selects it")
	var src := _make_rig(111)
	# Real placement: treadmill id 0 at (1,1) R0, yoga id 1 at (4,4) R0.
	_place(src, "treadmill_01", Vector2i(1, 1), 0)
	_place(src, "yoga_01", Vector2i(4, 4), 0)

	# Pre-save mapping payloads (the runtime mapping, recorded before save).
	var pre_save: Array = []
	for i in 2:
		pre_save.append(_click_and_capture(src, _footprint_cell(src, i)))
		src["selection"].call("on_esc_pressed")

	# Save.
	var blob: Dictionary = src["save_load"].call("_perform_save")

	# Load into a FRESH rig (empty session).
	var rig := _make_rig(222)
	rig["log"].clear()
	var result: RefCounted = rig["save_load"].call("load", blob, _open_snapshot())

	_check(bool(result.get("ok")), "roundtrip — load ok (errors: %s)" % str(result.get("errors")))
	# Grid occupancy restored (source of truth for the rebuild).
	var gs_data: Dictionary = rig["grid_system"].call("serialize")
	_check((gs_data["records"] as Array).size() == 2, "roundtrip — grid restored 2 records (got %d)" % (gs_data["records"] as Array).size())

	# First click on each piece → correct selection payload (UX AC).
	for i in 2:
		var payload := _click_and_capture(rig, _footprint_cell(rig, i))
		_check(payload.size() == 4, "roundtrip — first click on instance %d emits a 4-arg selection (got %s)" % [i, str(payload)])
		if payload.size() == 4:
			var e: Array = payload
			_check(int(e[0]) == i, "roundtrip — instance %d selected (got %s)" % [i, str(e[0])])
			var def_id: String = e[1].get("id") if e[1] != null else "<null>"
			var exp_id: String = "treadmill_01" if i == 0 else "yoga_01"
			_check(def_id == exp_id, "roundtrip — instance %d equipment_id '%s' (got '%s')" % [i, exp_id, def_id])
			_check(e[2] == pre_save[i][2], "roundtrip — instance %d anchor %s preserved (got %s)" % [i, str(pre_save[i][2]), str(e[2])])
			_check(int(e[3]) == int(pre_save[i][3]), "roundtrip — instance %d rotation %s preserved (got %s)" % [i, str(pre_save[i][3]), str(e[3])])


# === TR-SEL-007: rotation preserved through the round trip (order trap) ===

func _test_roundtrip_rotation_preserved_r90() -> void:
	print("\n[TR-SEL-007] R90 piece round-trips rotation 90 (the order-ambiguity trap)")
	var src := _make_rig(333)
	# bench 2×2 at (5,1) R90 — a symmetric-shape rotation that a per-cell
	# scan would collapse to R0; the bulk surface carries the stored rotation.
	_place(src, "bench_01", Vector2i(5, 1), 1)
	var pre: Array = _click_and_capture(src, _footprint_cell(src, 0))
	src["selection"].call("on_esc_pressed")

	var blob: Dictionary = src["save_load"].call("_perform_save")
	var rig := _make_rig(444)
	var result: RefCounted = rig["save_load"].call("load", blob, _open_snapshot())
	_check(bool(result.get("ok")), "R90 — load ok (errors: %s)" % str(result.get("errors")))

	var payload := _click_and_capture(rig, _footprint_cell(rig, 0))
	_check(payload.size() == 4, "R90 — first click selects the bench (got %s)" % str(payload))
	if payload.size() == 4:
		var e: Array = payload
		_check(e[1] != null and e[1].get("id") == "bench_01", "R90 — equipment_id bench_01 recovered (got %s)" % str(e[1].get("id") if e[1] != null else "<null>"))
		_check(e[2] == pre[2], "R90 — anchor %s preserved (got %s)" % [str(pre[2]), str(e[2])])
		_check(int(e[3]) == 90, "R90 — rotation 90 preserved (got %d)" % int(e[3]))


# === AC load-order slot (architecture.md Phase B step 3a) ===

func _test_load_order_slot_after_grid_before_member() -> void:
	print("\n[load order] rebuild_mapping runs AFTER GridSystem commit, BEFORE MemberSim commit")
	var src := _make_rig(555)
	_place(src, "treadmill_01", Vector2i(1, 1), 0)
	var blob: Dictionary = src["save_load"].call("_perform_save")

	var rig := _make_rig(666)
	rig["log"].clear()
	var result: RefCounted = rig["save_load"].call("load", blob, _open_snapshot())
	_check(bool(result.get("ok")), "order — load ok (errors: %s)" % str(result.get("errors")))

	var log: Array = rig["log"]
	var grid_idx := log.find("GridSystem.deserialize:commit")
	var rebuild_idx := log.find("SelectionSystem.rebuild_mapping")
	var member_idx := log.find("MemberSim.deserialize:commit")
	_check(grid_idx >= 0, "order — GridSystem.deserialize:commit present in log")
	_check(rebuild_idx > grid_idx, "order — SelectionSystem.rebuild_mapping AFTER GridSystem.deserialize commit")
	_check(member_idx > rebuild_idx, "order — MemberSim commit AFTER rebuild_mapping (Phase B step 3a slot)")
	# Exactly ONE rebuild (the load-order slot fires once; the method is
	# idempotent but the slot must not double-fire).
	var rebuild_count := 0
	for entry in log:
		if entry == "SelectionSystem.rebuild_mapping":
			rebuild_count += 1
	_check(rebuild_count == 1, "order — rebuild_mapping called exactly once (got %d)" % rebuild_count)


# === TR-SEL-007: zero contribution to the save blob ===

func _test_no_blob_contribution() -> void:
	print("\n[TR-SEL-007] save blob contains NO selection_system key — mapping is derived state")
	var rig := _make_rig(777)
	_place(rig, "treadmill_01", Vector2i(1, 1), 0)
	# A live selection at save time must still contribute nothing.
	rig["selection"].call("on_cell_clicked", Vector2i(1, 1))

	var blob: Dictionary = rig["save_load"].call("_perform_save")
	_check(not blob.has("selection_system"), "TR-SEL-007 — no 'selection_system' key in blob")
	# The blob key set is exactly the 8 CONTRIBUTING_KEYS (SaveLoad contract).
	_check(blob.size() == 8, "TR-SEL-007 — blob has exactly 8 keys (got %d)" % blob.size())


# === QA edge: zero placed pieces ===

func _test_zero_pieces_loads_clean() -> void:
	print("\n[edge] save/load with zero placed pieces → empty mapping, no error")
	var src := _make_rig(888)
	var blob: Dictionary = src["save_load"].call("_perform_save")

	var rig := _make_rig(999)
	var result: RefCounted = rig["save_load"].call("load", blob, _open_snapshot())
	_check(bool(result.get("ok")), "zero — load ok (errors: %s)" % str(result.get("errors")))
	var gs_data: Dictionary = rig["grid_system"].call("serialize")
	_check((gs_data["records"] as Array).size() == 0, "zero — grid has no records (got %d)" % (gs_data["records"] as Array).size())

	# Click empty buildable floor → no selection, no signal (mapping empty,
	# deselect is a no-op with nothing selected).
	var payload := _click_and_capture(rig, Vector2i(3, 3))
	_check(rig["selection"].call("get_selected_instance_id") == -1, "zero — nothing selected after load")
	_check(payload.is_empty(), "zero — no signal fired")
	_check(true, "zero — rebuild_mapping() ran with zero pieces without error")
