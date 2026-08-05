# tests/integration/core_loop/core_loop_test.gd
# 迁自 prototypes/gym-flow-vertical-slice/src/sim/integration_test.gd
# 覆盖：Grid + Nav + MemberSim + Congestion + Placement 全核心循环
# Run: godot --headless --script tests/integration/core_loop/core_loop_test.gd
#
# 【2026-08-05 Sprint 4 门禁修复解锁】preload 由原型路径改写为 src/ 真实实现：
#   - GridSystem / Navigation / EquipmentCatalog / EquipmentDef / SeededRNG /
#     MemberSim / Congestion / PlacementSystem 全部来自 src/systems/
#   - 断言按 src/ 真实 API 重写（SimSystem.init 注入架构、members 为 Array、
#     per_equipment_congestion 读 prev 缓冲、access_reachable 由 on_tick flush）
#   - 原 overlay 部分（src/ 无 overlay 系统）替换为 Congestion.per_cell_density
#     的 shape-first 峰值密度检查 —— 保留"布局形状肉眼可读"的核心规格
# 断言本身（决定性、布局影响人流、access 阻塞）是垂直切片验证过的核心循环
# 规格，予以保留。
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"

const GRID_W := 13
const GRID_H := 10
const ENTRANCE := Vector2i(0, 0)
const EXIT := Vector2i(12, 9)
const R0 := 0

var _pass := 0
var _fail := 0


func _init() -> void:
	if Engine.has_meta(RUNNER_META):
		return
	var result := run_all()
	quit(1 if int(result["fail"]) > 0 else 0)


## 返回 {"pass": int, "fail": int} —— 见 tests/headless_runner.gd 的测试文件契约
func run_all() -> Dictionary:
	print("=".repeat(48))
	print("  INTEGRATION TEST: Full Core Loop")
	print("=".repeat(48))

	_test_determinism()
	_test_layout_matters()
	_test_access_blocked()
	_test_catalog_fields()
	_test_placement()
	_test_density_shape_first()

	print("\n=== INTEGRATION TEST: %d passed, %d failed ===" % [_pass, _fail])
	return {"pass": _pass, "fail": _fail}


func _check(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
		print("  PASS: " + msg)
	else:
		_fail += 1
		print("  FAIL: " + msg)


# === Script loaders ===

func _GS() -> Script:
	return load("res://src/systems/grid_system.gd") as Script


func _NAV() -> Script:
	return load("res://src/systems/navigation.gd") as Script


func _SRG() -> Script:
	return load("res://src/systems/seeded_rng.gd") as Script


func _EC() -> Script:
	return load("res://src/systems/equipment_catalog.gd") as Script


func _ED() -> Script:
	return load("res://src/systems/equipment_def.gd") as Script


func _MS() -> Script:
	return load("res://src/systems/member_sim.gd") as Script


func _CG() -> Script:
	return load("res://src/systems/congestion.gd") as Script


func _PS() -> Script:
	return load("res://src/systems/placement_system.gd") as Script


func _make_orchestrator() -> Node:
	var orch: Node = load("res://src/systems/simulation_orchestrator.gd").new()
	root.add_child(orch)
	orch.call("_ready")
	return orch


## Open 13x10 grid, all buildable + frozen, with the given layout committed.
## layout item: {id, def_id, anchor: Vector2i, rotation: int}
func _make_grid(layout: Array) -> RefCounted:
	var gs: RefCounted = _GS().new()
	gs.call("init", GRID_W, GRID_H)
	for y in GRID_H:
		for x in GRID_W:
			gs.call("set_buildable", Vector2i(x, y), true)
	gs.call("freeze_buildable")
	for item in layout:
		var def: Dictionary = _def_for(item)
		var fp: Array[Vector2i] = def["fp"]
		var ac: Array[Vector2i] = def["ac"]
		gs.call("commit", int(item["id"]), fp, ac, int(item.get("rotation", R0)))
	return gs


## Catalog: treadmill + bike, 1x1 footprint + 1 access cell, SHORT use
## durations so members cycle and queues form within the tick window.
func _make_catalog() -> RefCounted:
	var cat: RefCounted = _EC().new()
	var fp0: Array[Vector2i] = [Vector2i(0, 0)]
	var ac0: Array[Vector2i] = [Vector2i(1, 0)]
	var effects: Array[Dictionary] = []
	var def_t: RefCounted = _ED().new(
		"treadmill", "Treadmill", ["cardio"],
		fp0, ac0, 200, "", effects, 40, 8, 20, 80
	)
	var def_b: RefCounted = _ED().new(
		"bike", "Bike", ["cardio"],
		fp0, ac0, 220, "", effects, 40, 8, 20, 80
	)
	cat.call("_add_definition", def_t)
	cat.call("_add_definition", def_b)
	cat.call("_freeze")
	return cat


func _def_for(item: Dictionary) -> Dictionary:
	# GridSystem.commit() takes ABSOLUTE footprint/access cells (no anchor
	# argument). 1x1 footprint at the anchor + 1 access cell to the right.
	var anchor: Vector2i = item["anchor"]
	var fp: Array[Vector2i] = [anchor]
	var ac: Array[Vector2i] = [anchor + Vector2i(1, 0)]
	return {"fp": fp, "ac": ac}


func _make_orchestrator_rig(
	master_seed: int,
	layout: Array,
	config: Dictionary = {}
) -> Dictionary:
	var grid := _make_grid(layout)
	var nav: RefCounted = _NAV().new()
	nav.call("init", grid)
	nav.call("_post_init")
	var cat := _make_catalog()

	var srg: RefCounted = _SRG().new()
	srg.call("init", master_seed)
	var orch := _make_orchestrator()

	# Real MemberSim instance (not yet init'd) — Congestion's init reads the
	# reservations/members surface, which is structurally present.
	var ms: RefCounted = _MS().new()
	var cong: RefCounted = _CG().new()
	cong.call("init", orch, srg, grid, ms, config, nav, ENTRANCE)
	cong.call("_post_init")

	# instance_id -> equipment_id resolver (MemberSim reads per-equipment
	# use-duration fields, TR-MS-009).
	var instance_to_def: Dictionary = {}
	for item in layout:
		instance_to_def[int(item["id"])] = str(item["def_id"])
	var resolver := func(instance_id: int) -> String:
		return str(instance_to_def.get(instance_id, "treadmill"))

	var ms_config: Dictionary = {
		"base_arrival_rate_per_min": 36.0,
		"max_concurrent_members": 20,
		"use_duration_mean_ticks": 40,
		"use_duration_stddev_ticks": 8,
		"use_duration_min_ticks": 20,
		"use_duration_max_ticks": 80,
		"leaving_timeout_ticks": 300,
		"exercises_mean": 1.0,
		"exercises_stddev": 0.0,
		"exercises_min": 1,
		"exercises_max": 1,
		"patience_min_ticks": 30,
		"patience_max_ticks": 80,
		"k_congestion": 5.0,
		"k_proximity": 0.2,
		"D_max": 16,
		"top_k": 4,
	}
	ms.call("init", orch, srg, grid, nav, cat, ENTRANCE, EXIT, ms_config, cong, resolver)

	var placement: RefCounted = _PS().new()
	placement.call("init", grid, cat)

	return {
		"grid": grid, "nav": nav, "member": ms, "cong": cong,
		"orchestrator": orch, "placement": placement,
	}


## Real tick loop: MemberSim FIRST (reads cong prev buffer), Congestion SECOND
## (computes next + swaps) — the ADR-0005 fixed dispatch order.
func _run_ticks(o: Dictionary, ticks: int) -> void:
	var member = o["member"]
	var cong = o["cong"]
	for t in ticks:
		member.call("on_tick", t)
		cong.call("on_tick", t)


func _snapshot_members(o: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	var members: Array = o["member"].get("members")
	for m in members:
		if not (m is Dictionary) or not m.has("state") or not m.has("cell"):
			continue
		out[int(m["member_id"])] = {
			"pos": m["cell"],
			"state": m["state"],
			"ex": m.get("exercises_done", 0),
		}
	return out


func _avg_congestion(o: Dictionary) -> float:
	var cong = o["cong"]
	var total := 0.0
	var n := 0
	for eid in (cong.get("prev") as Dictionary).keys():
		total += float(cong.call("per_equipment_congestion", int(eid)))
		n += 1
	return total / float(n) if n > 0 else 0.0


func _count_hot_cells(o: Dictionary, threshold: float = 0.5) -> int:
	var cong = o["cong"]
	var n := 0
	var dims: Vector2i = o["grid"].call("get_dimensions")
	for y in dims.y:
		for x in dims.x:
			if float(cong.call("per_cell_density", Vector2i(x, y))) >= threshold:
				n += 1
	return n


func _dict_eq(a: Dictionary, b: Dictionary) -> bool:
	if a.keys().size() != b.keys().size():
		return false
	for k in a.keys():
		if not b.has(k):
			return false
		var av: Dictionary = a[k]
		var bv: Dictionary = b[k]
		if av["pos"] != bv["pos"] or av["state"] != bv["state"] or av["ex"] != bv["ex"]:
			return false
	return true


# === Test Cases ===

func _test_determinism() -> void:
	print("\n[determinism]")
	var layout := [
		{"id": 1, "def_id": "treadmill", "anchor": Vector2i(3, 3)},
		{"id": 2, "def_id": "treadmill", "anchor": Vector2i(3, 6)},
		{"id": 3, "def_id": "bike", "anchor": Vector2i(9, 4)},
	]
	var o1 := _make_orchestrator_rig(4242, layout)
	_run_ticks(o1, 300)
	var s1 := _snapshot_members(o1)

	var o2 := _make_orchestrator_rig(4242, layout)
	_run_ticks(o2, 300)
	var s2 := _snapshot_members(o2)

	_check(
		_dict_eq(s1, s2),
		"identical seed+layout → bit-identical member states over 300 ticks"
	)


func _test_layout_matters() -> void:
	print("\n[layout matters]")
	var clumped := [
		{"id": 1, "def_id": "treadmill", "anchor": Vector2i(2, 2)},
		{"id": 2, "def_id": "treadmill", "anchor": Vector2i(4, 2)},
		{"id": 3, "def_id": "bike", "anchor": Vector2i(3, 4)},
	]
	var spread := [
		{"id": 1, "def_id": "treadmill", "anchor": Vector2i(2, 2)},
		{"id": 2, "def_id": "treadmill", "anchor": Vector2i(10, 2)},
		{"id": 3, "def_id": "bike", "anchor": Vector2i(6, 7)},
	]

	var oc := _make_orchestrator_rig(777, clumped)
	_run_ticks(oc, 400)
	var cc := _avg_congestion(oc)

	var os := _make_orchestrator_rig(777, spread)
	_run_ticks(os, 400)
	var cs := _avg_congestion(os)

	print("  [info] clumped avg congestion=%.4f, spread avg congestion=%.4f" % [cc, cs])
	_check(
		cc > cs,
		"clumped layout yields HIGHER congestion than spread (fun core validated)"
	)


func _test_access_blocked() -> void:
	print("\n[access blocked]")
	var layout := [
		{"id": 1, "def_id": "treadmill", "anchor": Vector2i(6, 5)}
	]
	var o := _make_orchestrator_rig(1, layout)
	_check(bool(o["cong"].call("is_access_reachable", 1)), "machine reachable at start")

	var grid = o["grid"]
	# Wall off machine 1: 1x1 bikes whose footprints block the access cell
	# (machine 1 at (6,5) has access cell (7,5); three bikes seal it).
	var fp_w: Array[Vector2i] = [Vector2i(7, 4)]
	var ac_w1: Array[Vector2i] = [Vector2i(8, 4)]
	grid.call("commit", 91, fp_w, ac_w1, R0)
	var fp_w2: Array[Vector2i] = [Vector2i(7, 6)]
	var ac_w2: Array[Vector2i] = [Vector2i(8, 6)]
	grid.call("commit", 92, fp_w2, ac_w2, R0)
	var fp_w3: Array[Vector2i] = [Vector2i(8, 5)]
	var ac_w3: Array[Vector2i] = [Vector2i(9, 5)]
	grid.call("commit", 93, fp_w3, ac_w3, R0)
	# grid_changed fires via commit(); cong's handler marks pending; the next
	# on_tick flushes and recomputes access_reachable against final state.
	o["cong"].call("on_tick", 0)
	_check(
		not bool(o["cong"].call("is_access_reachable", 1)),
		"machine walled off → access_reachable false after grid_changed"
	)


func _test_catalog_fields() -> void:
	print("\n[catalog fields]")
	var cat := _make_catalog()
	_check(bool(cat.call("has_definition", "treadmill")), "catalog has treadmill def")

	var def = cat.call("get_definition", "treadmill")
	_check(
		int(def.get("use_duration_mean_ticks")) == 40
			and int(def.get("use_duration_min_ticks")) == 20
			and int(def.get("use_duration_max_ticks")) == 80,
		"use_duration fields readable by MemberSim (TR-MS-009)"
	)

	_check(
		not bool(cat.call("has_definition", "x")),
		"catalog rejects unknown id (has_definition false)"
	)


func _test_placement() -> void:
	print("\n[placement / drag-snap]")
	var cat := _make_catalog()
	var grid := _make_grid([])
	# ONE PlacementSystem session — relocate/_instance_equipment and
	# _next_instance_id are session state; splitting across instances would
	# leave relocate unable to resolve its own piece.
	var place: RefCounted = _PS().new()
	place.call("init", grid, cat)

	# Drag lifecycle: begin -> move -> drop at R0 (no rotation) so the
	# instance footprint stays exactly at the anchor for the overlap checks.
	place.call("begin_drag", "treadmill")
	place.call("on_mouse_moved", Vector2i(2, 2))
	place.call("on_drop")

	var placed: Array = grid.call("get_placed_instances")
	_check(placed.size() == 1, "drop commits exactly one instance")
	_check(
		int(place.get("_next_instance_id")) == 1,
		"next_instance_id consumed exactly once (Core Rule 7)"
	)

	# Rotation cycles 0/90/180/270 (white-box read of the drag rotation),
	# ended with a silent cancel — no commit, no signal.
	place.call("begin_drag", "bike")
	place.call("on_mouse_moved", Vector2i(6, 6))
	place.call("on_rotate_pressed")
	var rot1: int = int(place.get("_rotation"))
	place.call("on_rotate_pressed")
	var rot2: int = int(place.get("_rotation"))
	place.call("on_rotate_pressed")
	var rot3: int = int(place.get("_rotation"))
	_check(
		rot1 == 90 and rot2 == 180 and rot3 == 270,
		"rotate cycles 90/180/270 from R0"
	)
	place.call("on_cancel")

	# Out-of-bounds anchor drop is a SILENT CANCEL (AC8) — no commit.
	place.call("begin_drag", "treadmill")
	place.call("on_mouse_moved", Vector2i(13, 0))  # x=13 is outside 13x10
	place.call("on_drop")
	var placed_after: Array = grid.call("get_placed_instances")
	_check(placed_after.size() == 1, "out-of-bounds anchor drop commits nothing (silent cancel)")

	# Rejected in-bounds drop (overlap) emits placement_rejected once, no commit.
	place.call("begin_drag", "treadmill")
	place.call("on_mouse_moved", Vector2i(2, 2))  # overlaps instance 0's footprint
	place.call("on_drop")
	var placed_final: Array = grid.call("get_placed_instances")
	_check(placed_final.size() == 1, "rejected overlap drop commits nothing")

	# Relocate: pick up instance 0 (the first drop's id), move it, drop —
	# same id, new anchor.
	place.call("begin_relocate", 0)
	place.call("on_mouse_moved", Vector2i(9, 7))
	place.call("on_drop")
	var placed_reloc: Array = grid.call("get_placed_instances")
	_check(placed_reloc.size() == 1, "relocate keeps exactly one instance (same id)")
	var inst: RefCounted = placed_reloc[0]
	_check(
		int(inst.get("instance_id")) == 0 and inst.get("anchor") == Vector2i(9, 7),
		"relocate moved instance 0 to new anchor"
	)


func _test_density_shape_first() -> void:
	print("\n[density / shape-first readability]")
	var clumped := [
		{"id": 1, "def_id": "treadmill", "anchor": Vector2i(2, 2)},
		{"id": 2, "def_id": "treadmill", "anchor": Vector2i(4, 2)},
		{"id": 3, "def_id": "bike", "anchor": Vector2i(3, 4)},
	]
	var oc := _make_orchestrator_rig(4242, clumped)
	_run_ticks(oc, 500)
	var hot_c := _count_hot_cells(oc)

	var spread := [
		{"id": 1, "def_id": "treadmill", "anchor": Vector2i(2, 2)},
		{"id": 2, "def_id": "treadmill", "anchor": Vector2i(10, 2)},
		{"id": 3, "def_id": "bike", "anchor": Vector2i(6, 7)},
	]
	var os := _make_orchestrator_rig(4242, spread)
	_run_ticks(os, 500)
	var hot_s := _count_hot_cells(os)

	print("  [info] clumped hot cells=%d, spread hot cells=%d (density>=0.5)" % [hot_c, hot_s])
	_check(
		hot_c > hot_s,
		"shape-first: clumped HOT cells > spread (layout shape readable at a glance)"
	)
