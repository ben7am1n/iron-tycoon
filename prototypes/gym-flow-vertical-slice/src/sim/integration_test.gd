# VERTICAL SLICE - NOT FOR PRODUCTION
# Headless integration test: full core loop (Grid + Nav + MemberSim + Congestion).
# Runs as the project's main scene (Node). All cross-script classes are referenced via
# preload const aliases (GDScript class_name is NOT globally registered under headless
# project load, so .new() must go through the preloaded const).
# Run: godot --headless  (from project dir, main_scene = this)
extends Node

const GridSystemScript := preload("res://src/core/grid_system.gd")
const RNGScript := preload("res://src/core/seeded_rng.gd")
const CatalogScript := preload("res://src/data/equipment_catalog.gd")
const NavScript := preload("res://src/sim/navigation.gd")
const MemberScript := preload("res://src/sim/member_sim.gd")
const CongScript := preload("res://src/sim/congestion.gd")
const PlaceScript := preload("res://src/sim/placement_system.gd")
const OverlayScript := preload("res://src/sim/overlay_model.gd")

var _pass := 0
var _fail := 0

class SigCounter extends RefCounted:
	var n := 0
	func on_changed(_f, _a) -> void:
		n += 1

# Exposed so main.gd can run the suite headless (--test) without duplicating assertions.
func run_all() -> bool:
	_test_determinism()
	_test_layout_matters()
	_test_access_blocked()
	_test_catalog_fields()
	_test_placement()
	_test_overlay()
	print("\n=== INTEGRATION TEST: %d passed, %d failed ===" % [_pass, _fail])
	return _fail == 0

func _ready() -> void:
	run_all()
	get_tree().quit(_fail > 0)

func _check(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
		print("  PASS: " + msg)
	else:
		_fail += 1
		print("  FAIL: " + msg)

func _make_grid():
	var region := Rect2i(0, 0, 13, 10)
	var buildable := {}
	for x in range(13):
		for y in range(10):
			buildable[Vector2i(x, y)] = true
	return GridSystemScript.new(region, buildable)

func _make_catalog():
	var cat = CatalogScript.new()
	cat.add_def("treadmill", "Treadmill", [Vector2i(0,0)], [Vector2i(1,0)], 200, 30, 100, 300)
	cat.add_def("bike", "Bike", [Vector2i(0,0)], [Vector2i(1,0)], 220, 40, 110, 320)
	return cat

func _make_orchestrator(grid, cat, master_seed: int, layout: Array):
	var rng = RNGScript.new(master_seed).get_rng("MemberSim")
	var nav = NavScript.new(grid)
	var entrance := Vector2i(0, 0)
	var exit := Vector2i(12, 9)
	var member = MemberScript.new(grid, nav, cat, rng, entrance, exit)
	var cong = CongScript.new(nav, entrance, grid.get_dimensions())
	var access_mirror := {}
	for item in layout:
		var fp: Array = cat.get_definition(item["def_id"])["footprint_local"]
		var ac: Array = cat.get_definition(item["def_id"])["access_local"]
		grid.commit(item["id"], fp, ac, item["anchor"], item["rotation"])
		nav.on_grid_changed(grid.get_footprint_cells(item["id"]) + grid.get_access_cells(item["id"]), [])
		member.register_equipment(item["id"], item["def_id"])
		var ac_abs: Array = grid.get_access_cells(item["id"])
		access_mirror[item["id"]] = ac_abs[0] if not ac_abs.is_empty() else entrance
	cong.set_access_mirror(access_mirror)
	cong.recompute_access(access_mirror.keys())
	var placement = PlaceScript.new(grid, cat)
	var overlay = OverlayScript.new(grid)
	return {"grid": grid, "nav": nav, "member": member, "cong": cong, "access_mirror": access_mirror, "entrance": entrance, "placement": placement, "overlay": overlay}

func _run_ticks(o: Dictionary, ticks: int, spawn_every: int) -> void:
	var member = o["member"]
	var cong = o["cong"]
	var spawn_count := 0
	for t in ticks:
		if t % spawn_every == 0 and spawn_count < 8:
			member.spawn_member()
			spawn_count += 1
		var cong_prev := {}
		for eid in cong._prev.keys():
			cong_prev[eid] = cong.get_congestion(eid)
		member.on_tick(cong_prev)
		cong.on_tick(member._members, member._equip_state)

func _snapshot_members(o: Dictionary):
	var out := {}
	for mid in o["member"]._members.keys():
		var m: Dictionary = o["member"]._members[mid]
		out[mid] = {"pos": m["pos"], "state": m["state"], "ex": m["exercises"]}
	return out

func _avg_congestion(o: Dictionary) -> float:
	var cong = o["cong"]
	var s := 0.0
	var n := 0
	for eid in cong._prev.keys():
		s += cong.get_congestion(eid)
		n += 1
	return s / float(n)

func _avg_density(o: Dictionary) -> float:
	var cong = o["cong"]
	var region: Rect2i = o["grid"].get_dimensions()
	var s := 0.0
	var n := 0
	for x in range(region.position.x, region.end.x):
		for y in range(region.position.y, region.end.y):
			s += cong.get_density(Vector2i(x, y))
			n += 1
	return s / float(n)

func _test_determinism() -> void:
	print("[determinism]")
	var cat = _make_catalog()
	var layout := [
		{"id": 1, "def_id": "treadmill", "anchor": Vector2i(3,3), "rotation": 0},
		{"id": 2, "def_id": "treadmill", "anchor": Vector2i(3,6), "rotation": 0},
		{"id": 3, "def_id": "bike", "anchor": Vector2i(9,4), "rotation": 0},
	]
	var o1 = _make_orchestrator(_make_grid(), cat, 4242, layout)
	_run_ticks(o1, 300, 20)
	var s1 = _snapshot_members(o1)
	var o2 = _make_orchestrator(_make_grid(), cat, 4242, layout)
	_run_ticks(o2, 300, 20)
	var s2 = _snapshot_members(o2)
	_check(_dict_eq(s1, s2), "identical seed+layout -> bit-identical member states over 300 ticks")

func _test_layout_matters() -> void:
	print("[layout matters]")
	var cat = _make_catalog()
	var clumped := [
		{"id": 1, "def_id": "treadmill", "anchor": Vector2i(2,2), "rotation": 0},
		{"id": 2, "def_id": "treadmill", "anchor": Vector2i(4,2), "rotation": 0},
		{"id": 3, "def_id": "bike", "anchor": Vector2i(3,4), "rotation": 0},
	]
	var spread := [
		{"id": 1, "def_id": "treadmill", "anchor": Vector2i(2,2), "rotation": 0},
		{"id": 2, "def_id": "treadmill", "anchor": Vector2i(10,2), "rotation": 0},
		{"id": 3, "def_id": "bike", "anchor": Vector2i(6,7), "rotation": 0},
	]
	var oc = _make_orchestrator(_make_grid(), cat, 777, clumped)
	_run_ticks(oc, 400, 15)
	var cc = _avg_congestion(oc)
	var os = _make_orchestrator(_make_grid(), cat, 777, spread)
	_run_ticks(os, 400, 15)
	var cs = _avg_congestion(os)
	print("  [info] clumped avg congestion=%.4f, spread avg congestion=%.4f" % [cc, cs])
	_check(cc > cs, "clumped layout yields HIGHER per-equipment congestion than spread (fun core: spreading relieves crowding)")

func _test_access_blocked() -> void:
	print("[access blocked]")
	var cat = _make_catalog()
	var layout := [{"id": 1, "def_id": "treadmill", "anchor": Vector2i(6,5), "rotation": 0}]
	var o = _make_orchestrator(_make_grid(), cat, 1, layout)
	_check(o["cong"].is_access_reachable(1), "machine reachable at start")
	var grid = o["grid"]
	grid.commit(91, cat.get_definition("bike")["footprint_local"], cat.get_definition("bike")["access_local"], Vector2i(7,4), 0)
	grid.commit(92, cat.get_definition("bike")["footprint_local"], cat.get_definition("bike")["access_local"], Vector2i(7,6), 0)
	grid.commit(93, cat.get_definition("bike")["footprint_local"], cat.get_definition("bike")["access_local"], Vector2i(8,5), 0)
	o["nav"].on_grid_changed([Vector2i(7,4), Vector2i(7,6), Vector2i(8,5)], [])
	o["cong"].recompute_access([1])
	_check(not o["cong"].is_access_reachable(1), "machine walled off -> access_reachable false after grid_changed")

func _test_catalog_fields() -> void:
	print("[catalog fields]")
	var cat = _make_catalog()
	_check(cat.has_def("treadmill"), "catalog has treadmill def")
	var d = cat.get_use_duration("treadmill")
	_check(d["mean"] == 200 and d["min"] == 100 and d["max"] == 300, "use_duration fields read by MemberSim")
	var bad = CatalogScript.new()
	_check(bad.add_def("x", "X", [Vector2i(0,0)], [Vector2i(1,0)], 0, 0, 0, 0) == false, "catalog rejects mean<=0 (rule 7e)")

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

func _test_placement() -> void:
	print("[placement / drag-snap]")
	var cat = _make_catalog()
	var grid = _make_grid()
	var place = PlaceScript.new(grid, cat)
	var a1 = place.snap_anchor(Vector2i(3, 3))
	var a2 = place.snap_anchor(Vector2i(3, 3))
	var a3 = place.snap_anchor(Vector2i(3, 3))
	_check(a1 == a2 and a2 == a3 and a1 == Vector2i(3, 3), "snap_anchor is deterministic, no RNG")
	_check(place.rotate(0) == 90 and place.rotate(90) == 180 and place.rotate(270) == 0, "rotate cycles 0/90/180/270")
	var cnt = SigCounter.new()
	grid.grid_changed.connect(cnt.on_changed)
	_check(place.place_new(1, "treadmill", Vector2i(2, 2), 0), "place_new commits valid anchor")
	_check(cnt.n == 1, "place_new emits grid_changed exactly once")
	var before: int = cnt.n
	_check(place.place_new(2, "treadmill", Vector2i(12, 9), 0) == false, "place_new rejects out-of-bounds anchor")
	_check(cnt.n == before, "rejected placement emits nothing")
	var nav = NavScript.new(grid)
	nav.on_grid_changed(grid.get_footprint_cells(1) + grid.get_access_cells(1), [])
	var reachable_before: bool = nav.get_path(Vector2i(0,0), grid.get_access_cells(1)[0]).size() > 0
	_check(place.move_existing(1, "treadmill", Vector2i(9, 7), 0), "move_existing relocates instance")
	nav.on_grid_changed(grid.get_footprint_cells(1) + grid.get_access_cells(1), [])
	var reachable_after: bool = nav.get_path(Vector2i(0,0), grid.get_access_cells(1)[0]).size() > 0
	_check(reachable_before and reachable_after, "after re-layout, access still pathable (no broken nav)")
	_check(cnt.n == before + 1, "move_existing emits grid_changed exactly once (clear+commit merged)")
	var fp_before: Array = grid.get_footprint_cells(1).duplicate()
	_check(place.move_existing(1, "treadmill", Vector2i(12, 9), 0) == false, "move_existing rejects invalid target")
	_check(grid.get_footprint_cells(1) == fp_before, "failed move leaves instance untouched (rollback)")

func _test_overlay() -> void:
	print("[overlay / shape-first readability]")
	var cat = _make_catalog()
	var clumped := [
		{"id": 1, "def_id": "treadmill", "anchor": Vector2i(2,2), "rotation": 0},
		{"id": 2, "def_id": "treadmill", "anchor": Vector2i(4,2), "rotation": 0},
		{"id": 3, "def_id": "bike", "anchor": Vector2i(3,4), "rotation": 0},
	]
	var oc = _make_orchestrator(_make_grid(), cat, 4242, clumped)
	_run_ticks(oc, 500, 12)
	oc["overlay"].build(oc["member"], oc["cong"])
	var sc = oc["overlay"].access_summary(oc["member"])
	var pk_c: float = oc["overlay"].peak_congestion(oc["member"])
	var spread := [
		{"id": 1, "def_id": "treadmill", "anchor": Vector2i(2,2), "rotation": 0},
		{"id": 2, "def_id": "treadmill", "anchor": Vector2i(10,2), "rotation": 0},
		{"id": 3, "def_id": "bike", "anchor": Vector2i(6,7), "rotation": 0},
	]
	var os = _make_orchestrator(_make_grid(), cat, 4242, spread)
	_run_ticks(os, 500, 12)
	os["overlay"].build(os["member"], os["cong"])
	var ss = os["overlay"].access_summary(os["member"])
	var pk_s: float = os["overlay"].peak_congestion(os["member"])
	print("  [info] clumped peak-congestion=%.3f, spread peak-congestion=%.3f" % [pk_c, pk_s])
	_check(pk_c > pk_s, "shape-first overlay: clumped PEAK congestion > spread (fun core visible through readability layer)")
	var some_hot_cell := Vector2i(-1, -1)
	for eid in sc.keys():
		if sc[eid]["hot"]:
			some_hot_cell = oc["grid"].get_access_cells(eid)[0]
			break
	if some_hot_cell.x >= 0:
		var g: String = oc["overlay"].get_glyph(some_hot_cell)
		var ql: int = oc["overlay"].get_queue_len(some_hot_cell)
		print("  [info] hot cell glyph='%s' queue_len=%d" % [g, ql])
		_check(g != "" and ql >= 2, "HOT cell is shape-first: explicit glyph + queue_len readable at a glance")
