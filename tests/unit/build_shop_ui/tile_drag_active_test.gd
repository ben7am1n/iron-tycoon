# tests/unit/build_shop_ui/tile_drag_active_test.gd
# V3.1 返工 UI — PaletteTile「拖拽选中」像素角标契约（本卡新增 presentation
# 状态：建造条拖起中的 tile 显示黄色像素角标，V3 §14 Selected 语言）。
#
# Covers:
#   - palette.on_tile_mouse_down 通过购买闸门开始拖拽 → 该 tile
#     set_drag_active(true)（is_drag_active 查询）
#   - 拖拽解决（commit / silent cancel）→ tile 角标清除（set_drag_active(false)）
#   - 被闸门拒绝的 tile（greyed/locked）不会进入选中态（无拖拽 → 无角标）
#   - set_drag_active 幂等（重复设置同值不重绘/不报错）
#
# Run standalone: godot --headless --script tests/unit/build_shop_ui/tile_drag_active_test.gd
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"

const PALETTE_PATH := "res://src/ui/build_shop_palette.gd"
const PLACEMENT_PATH := "res://src/systems/placement_system.gd"
const SHOP_PATH := "res://src/ui/shop.gd"
const ED_PATH := "res://src/systems/equipment_def.gd"
const ECAT_PATH := "res://src/systems/equipment_catalog.gd"
const GRID_PATH := "res://src/systems/grid_system.gd"
const ECON_PATH := "res://src/systems/economy.gd"
const SRG_PATH := "res://src/systems/seeded_rng.gd"

var _pass := 0
var _fail := 0
var _nodes_to_free: Array = []


func _init() -> void:
	if Engine.has_meta(RUNNER_META):
		return
	var result := run_all()
	quit(1 if int(result["fail"]) > 0 else 0)


func run_all() -> Dictionary:
	print("=".repeat(48))
	print("  UNIT TEST: PaletteTile drag-active marker (V3.1 返工 UI)")
	print("=".repeat(48))

	_test_drag_start_sets_marker()
	_test_commit_clears_marker()
	_test_silent_cancel_clears_marker()
	_test_greyed_tile_never_marks()
	_test_set_drag_active_idempotent()

	_free_test_nodes()

	print("\n=== TILE DRAG-ACTIVE: %d passed, %d failed ===\n" % [_pass, _fail])
	return {"pass": _pass, "fail": _fail}


func _check(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
		print("  PASS: " + msg)
	else:
		_fail += 1
		print("  FAIL: " + msg)


# === Helpers（与 purchase_gate_test 同源 rig 模式） ===

func _STATE() -> Dictionary:
	return {
		"AFFORDABLE": 0,
		"UNAFFORDABLE": 1,
		"LOCKED": 2,
	}


func _make_def(ED: Script, id: String, name: String, cost: int, unlock: String) -> RefCounted:
	var zone: Array = ["strength"]
	var footprint: Array[Vector2i] = [Vector2i(0, 0)]
	var access: Array[Vector2i] = [Vector2i(1, 0)]
	var effects: Array[Dictionary] = []
	return ED.new(
		id, name, zone, footprint, access, cost, unlock, effects,
		200, 30, 100, 300,
	)


func _make_catalog(defs: Array) -> RefCounted:
	var cat: RefCounted = load(ECAT_PATH).new()
	for d in defs:
		cat.call("_add_definition", d)
	cat.call("_freeze")
	return cat


func _make_economy(seed: int) -> RefCounted:
	var srg: RefCounted = load(SRG_PATH).new()
	srg.call("init", seed)
	var econ: RefCounted = load(ECON_PATH).new()
	econ.call("init", null, srg)
	econ.set("balance", 500)
	return econ


func _make_grid() -> RefCounted:
	var g: RefCounted = load(GRID_PATH).new()
	g.call("init", 10, 10)
	for y in 10:
		for x in 10:
			g.call("set_buildable", Vector2i(x, y), true)
	g.call("freeze_buildable")
	return g


func _make_placement(grid: RefCounted, catalog: RefCounted) -> RefCounted:
	var p: RefCounted = load(PLACEMENT_PATH).new()
	p.call("init", grid, catalog)
	return p


func _make_shop(catalog: RefCounted, economy: RefCounted, placement: RefCounted) -> RefCounted:
	var shop: RefCounted = load(SHOP_PATH).new()
	shop.call("init", catalog, economy, placement)
	return shop


func _make_standard_rig() -> Dictionary:
	var ED: Script = load(ED_PATH)
	var defs: Array = [
		_make_def(ED, "treadmill_01", "Treadmill", 350, ""),
		_make_def(ED, "yoga_mat", "Yoga Mat", 200, "milestone_a"),
	]
	var catalog := _make_catalog(defs)
	var economy := _make_economy(0xB5201)
	var grid := _make_grid()
	var placement := _make_placement(grid, catalog)
	var shop := _make_shop(catalog, economy, placement)
	var palette = load(PALETTE_PATH).new()
	palette.call("init", catalog, economy, shop, placement)
	root.add_child(palette)
	_nodes_to_free.append(palette)
	return {
		"catalog": catalog, "economy": economy, "grid": grid,
		"placement": placement, "shop": shop, "palette": palette,
	}


func _free_test_nodes() -> void:
	for n in _nodes_to_free:
		if is_instance_valid(n):
			n.queue_free()
	_nodes_to_free.clear()


# === Tests ===

func _test_drag_start_sets_marker() -> void:
	print("\n[drag marker] purchase drag begins -> dragged tile shows the selected marker")
	var rig := _make_standard_rig()
	var palette = rig["palette"]
	var tile = palette.call("get_tile", "treadmill_01")
	_check(not bool(tile.call("is_drag_active")), "tile starts without the drag marker")
	var started: bool = palette.call("on_tile_mouse_down", "treadmill_01")
	_check(started, "purchase drag started (gate passed)")
	_check(bool(tile.call("is_drag_active")), "dragged tile shows the drag-active marker")
	_check(bool(palette.call("is_drag_in_flight")), "palette one-drag invariant active")


func _test_commit_clears_marker() -> void:
	print("\n[drag marker] commit resolves -> marker clears")
	var rig := _make_standard_rig()
	var palette = rig["palette"]
	var placement: RefCounted = rig["placement"]
	var tile = palette.call("get_tile", "treadmill_01")
	palette.call("on_tile_mouse_down", "treadmill_01")
	_check(bool(tile.call("is_drag_active")), "setup: marker on")
	placement.call("on_mouse_moved", Vector2i(3, 3))
	placement.call("on_drop")  # commit
	palette.call("_process", 0.016)
	_check(not bool(tile.call("is_drag_active")), "commit clears the drag marker")
	_check(not bool(palette.call("is_drag_in_flight")), "palette one-drag invariant released")


func _test_silent_cancel_clears_marker() -> void:
	print("\n[drag marker] silent cancel resolves -> marker clears")
	var rig := _make_standard_rig()
	var palette = rig["palette"]
	var placement: RefCounted = rig["placement"]
	var tile = palette.call("get_tile", "treadmill_01")
	palette.call("on_tile_mouse_down", "treadmill_01")
	_check(bool(tile.call("is_drag_active")), "setup: marker on")
	placement.call("on_cancel")  # Esc — emits NO signal (AC10)
	palette.call("_process", 0.016)
	_check(not bool(tile.call("is_drag_active")), "silent cancel clears the drag marker")


func _test_greyed_tile_never_marks() -> void:
	print("\n[drag marker] gate-rejected tile never enters the selected state")
	var rig := _make_standard_rig()
	var palette = rig["palette"]
	var tile = palette.call("get_tile", "yoga_mat")  # LOCKED (milestone_a)
	_check(int(tile.get("state")) == int(_STATE()["LOCKED"]), "setup: yoga_mat LOCKED")
	var started: bool = palette.call("on_tile_mouse_down", "yoga_mat")
	_check(not started, "locked tile drag gate rejects")
	_check(not bool(tile.call("is_drag_active")), "locked tile has no drag marker (gate never started the drag)")


func _test_set_drag_active_idempotent() -> void:
	print("\n[drag marker] set_drag_active is idempotent")
	var rig := _make_standard_rig()
	var tile = rig["palette"].call("get_tile", "treadmill_01")
	tile.call("set_drag_active", true)
	tile.call("set_drag_active", true)  # same value again — no error, no state flip
	_check(bool(tile.call("is_drag_active")), "marker stays on after duplicate set")
	tile.call("set_drag_active", false)
	tile.call("set_drag_active", false)
	_check(not bool(tile.call("is_drag_active")), "marker stays off after duplicate clear")
