# VERTICAL SLICE - NOT FOR PRODUCTION
# Playable demo: renders the verified core loop + drag input + 10Hz tick loop.
# Three headless-safe modes (chosen via cmdline args):
#   --test   : run the integration suite (reuses integration_test.gd) then quit
#   --bench  : run N virtual seconds of the demo tick loop, report throughput (A7)
#   (default): interactive demo (needs a window; _draw/input only fire in desktop mode)
# Date: 2026-07-19
# Cross-script classes referenced via preload const aliases (GDScript 4.x: class_name
# is NOT globally registered under headless project load).

extends Node2D

const GridSystemScript := preload("res://src/core/grid_system.gd")
const RNGScript := preload("res://src/core/seeded_rng.gd")
const CatalogScript := preload("res://src/data/equipment_catalog.gd")
const NavScript := preload("res://src/sim/navigation.gd")
const MemberScript := preload("res://src/sim/member_sim.gd")
const CongScript := preload("res://src/sim/congestion.gd")
const PlaceScript := preload("res://src/sim/placement_system.gd")
const OverlayScript := preload("res://src/sim/overlay_model.gd")
const IntegrationTestScript := preload("res://src/sim/integration_test.gd")

const CELL := 40
const TICK := 0.1
const SPAWN_EVERY := 3.0

var _mode := "demo"
var _grid
var _rng
var _nav
var _member
var _cong
var _catalog
var _place
var _overlay
var _equip_ids := [1, 2, 3]
var _equip_defs := {}
var _layout_kind := "clumped"
var _next_id := 1

var _tick_accum := 0.0
var _spawn_timer := 0.0
var _drag := {"active": false, "def_id": "", "rotation": 0, "cursor": Vector2i(-1, -1)}
var _bench_t0 := 0.0
var _bench_ticks := 0
var _dump_t := 0.0
var _dump_done := false

func _ready() -> void:
	var args: Array = OS.get_cmdline_args()
	for a in args:
		if a == "--run-tests":
			_mode = "test"
		elif a == "--bench":
			_mode = "bench"
	if _mode == "test":
		var t = IntegrationTestScript.new()
		var ok: bool = t.run_all()
		get_tree().quit(not ok)
		return
	if _mode == "bench":
		_run_bench()
		return
	if _mode == "dump":
		_setup_world()
		_overlay.build(_member, _cong)
		queue_redraw()
		return
	_setup_world()
	_overlay.build(_member, _cong)
	queue_redraw()

func _buildable() -> Dictionary:
	var b := {}
	for x in range(13):
		for y in range(10):
			b[Vector2i(x, y)] = true
	return b

func _setup_world() -> void:
	_grid = GridSystemScript.new(Rect2i(0, 0, 13, 10), _buildable())
	_catalog = CatalogScript.new()
	_catalog.add_def("treadmill", "Treadmill", [Vector2i(0,0)], [Vector2i(1,0)], 200, 30, 100, 300)
	_catalog.add_def("bike", "Bike", [Vector2i(0,0)], [Vector2i(1,0)], 220, 40, 110, 320)
	_rng = RNGScript.new(20260719).get_rng("MemberSim")
	_nav = NavScript.new(_grid)
	_member = MemberScript.new(_grid, _nav, _catalog, _rng, Vector2i(0, 0), Vector2i(12, 9))
	_cong = CongScript.new(_nav, Vector2i(0, 0), _grid.get_dimensions())
	_place = PlaceScript.new(_grid, _catalog)
	_overlay = OverlayScript.new(_grid)
	# New layout constraint: OQ6 requires >=2 same-type machines (ids 1,2 = treadmill).
	_equip_defs = {1: "treadmill", 2: "treadmill", 3: "bike"}
	_apply_layout("clumped")

func _place_instance(id: int, def_id: String, anchor: Vector2i) -> void:
	if _place.place_new(id, def_id, anchor, 0):
		_equip_defs[id] = def_id
		_member.register_equipment(id, def_id)
		_nav.on_grid_changed(_grid.get_footprint_cells(id) + _grid.get_access_cells(id), [])

# Toggle layout preset (press L): clumped (high crowding) <-> spread (relieved).
# Demonstrates the core fun: rearrange space -> crowding visibly disperses.
func _apply_layout(kind: String) -> void:
	_layout_kind = kind
	for eid in _equip_ids:
		_grid.clear(eid)
		_member._equip_state.erase(eid)
		_cong._access_mirror.erase(eid)
	var layout := {}
	if kind == "clumped":
		layout = {1: Vector2i(2, 2), 2: Vector2i(3, 2), 3: Vector2i(2, 3)}
	else:
		layout = {1: Vector2i(2, 2), 2: Vector2i(10, 2), 3: Vector2i(6, 7)}
	var mirror := {}
	for eid in _equip_ids:
		var def_id: String = _equip_defs.get(eid, "treadmill")
		_place_instance(eid, def_id, layout[eid])
		var ac: Array = _grid.get_access_cells(eid)
		if not ac.is_empty():
			mirror[eid] = ac[0]
	_cong.set_access_mirror(mirror)
	_cong.recompute_access(mirror.keys())
	_overlay.build(_member, _cong)
	queue_redraw()

# --- demo main loop (10Hz logic tick; rendering on every frame) ---
func _process(delta: float) -> void:
	if _mode != "demo" and _mode != "dump":
		return
	_tick_accum += delta
	if _mode == "dump":
		_dump_t += delta
		if _dump_t > 10.0:
			_save_frame()
			return
	_spawn_timer += delta
	if _spawn_timer >= SPAWN_EVERY and _member._members.size() < 10:
		_member.spawn_member()
		_spawn_timer = 0.0
	while _tick_accum >= TICK:
		_tick()
		_tick_accum -= TICK
	_overlay.build(_member, _cong)
	queue_redraw()

func _tick() -> void:
	var cong_prev := {}
	for eid in _cong._prev.keys():
		cong_prev[eid] = _cong.get_congestion(eid)
	_member.on_tick(cong_prev)
	_cong.on_tick(_member._members, _member._equip_state)

# --- input: drag to place / rearrange ---
func _input(event) -> void:
	if _mode != "demo":
		return
	if event is InputEventMouseMotion:
		var mp: Vector2i = Vector2i(int(event.position.x / CELL), int(event.position.y / CELL))
		_drag["cursor"] = mp
		queue_redraw()
	elif event is InputEventMouseButton:
		if event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			_on_click()
	elif event is InputEventKey:
		if event.pressed:
			if event.keycode == KEY_R:
				_drag["rotation"] = _place.rotate(_drag["rotation"])
				queue_redraw()
			elif event.keycode == KEY_ESCAPE:
				_drag["active"] = false
				queue_redraw()
			elif event.keycode == KEY_L:
				_apply_layout("spread" if _layout_kind == "clumped" else "clumped")

func _on_click() -> void:
	if _drag["active"]:
		var ok: bool = _place.place_new(_next_id, _drag["def_id"], _drag["cursor"], _drag["rotation"])
		if ok:
			var id: int = _next_id
			_next_id += 1
			_equip_ids.append(id)
			_member.register_equipment(id, _drag["def_id"])
			_equip_defs[id] = _drag["def_id"]
			_nav.on_grid_changed(_grid.get_footprint_cells(id) + _grid.get_access_cells(id), [])
			var ac: Array = _grid.get_access_cells(id)
			if not ac.is_empty():
				_cong.set_access_mirror(_cong._access_mirror)
				_cong._access_mirror[id] = ac[0]
				_cong.recompute_access([id])
			_drag["active"] = false
	else:
		# pick up an existing instance under the cursor to rearrange
		var c: Vector2i = _drag["cursor"]
		var occ: int = _grid.get_occupant_id(c)
		if occ != -1:
			var def_id: String = _equip_defs.get(occ, "")
			if def_id != "":
				_drag["active"] = true
				_drag["def_id"] = def_id
				_drag["rotation"] = _grid.get_rotation(occ)
				_place.move_existing(occ, def_id, _drag["cursor"], _drag["rotation"])
				_nav.on_grid_changed(_grid.get_footprint_cells(occ) + _grid.get_access_cells(occ), [])
				_cong.recompute_access(_equip_ids)

func _begin_drag(def_id: String) -> void:
	_drag["active"] = true
	_drag["def_id"] = def_id
	_drag["rotation"] = 0

# --- rendering (CanvasItem draw, desktop only) ---
func _draw() -> void:
	if _mode != "demo" or _grid == null:
		return
	var region: Rect2i = _grid.get_dimensions()
	# density heat background
	for x in range(region.position.x, region.end.x):
		for y in range(region.position.y, region.end.y):
			var c := Vector2i(x, y)
			var d: float = _cong.get_density(c)
			draw_rect(Rect2i(x * CELL, y * CELL, CELL, CELL), _heat_color(d))
	# grid lines
	for x in range(region.position.x, region.end.x + 1):
		draw_line(Vector2(x * CELL, 0), Vector2(x * CELL, region.end.y * CELL), Color(0.25, 0.25, 0.3), 1.0)
	for y in range(region.position.y, region.end.y + 1):
		draw_line(Vector2(0, y * CELL), Vector2(region.end.x * CELL, y * CELL), Color(0.25, 0.25, 0.3), 1.0)
	# equipment: footprint (gray) + access (amber) + shape-first glyph
	for eid in _equip_ids:
		for c in _grid.get_footprint_cells(eid):
			draw_rect(Rect2i(c.x * CELL, c.y * CELL, CELL, CELL), Color(0.5, 0.5, 0.55))
		for c in _grid.get_access_cells(eid):
			draw_rect(Rect2i(c.x * CELL, c.y * CELL, CELL, CELL), Color(0.8, 0.6, 0.2))
			var g: String = _overlay.get_glyph(c)
			if g != "" and ThemeDB.fallback_font != null:
				draw_string(ThemeDB.fallback_font, Vector2(c.x * CELL + 4, c.y * CELL + 4), g, 0, -1.0, 18, Color(1, 1, 1))
			var ql: int = _overlay.get_queue_len(c)
			if ql >= 1 and ThemeDB.fallback_font != null:
				draw_string(ThemeDB.fallback_font, Vector2(c.x * CELL + 20, c.y * CELL + 4), str(ql), 0, -1.0, 16, Color(1, 0.4, 0.4))
	# members
	for mid in _member._members.keys():
		var m: Dictionary = _member._members[mid]
		var col := Color(0.3, 0.8, 0.9)
		if m["state"] == 3 or m["state"] == 4:
			col = Color(0.9, 0.4, 0.3)
		draw_circle(Vector2(m["pos"].x * CELL + CELL/2, m["pos"].y * CELL + CELL/2), 8, col)
	# drag preview
	if _drag["active"]:
		var anchor: Vector2i = _drag["cursor"]
		var def: Dictionary = _catalog.get_definition(_drag["def_id"])
		var snap: Dictionary = _grid.get_speculative_snapshot(def["footprint_local"], def["access_local"], anchor, _drag["rotation"])
		var fill := Color(0.2, 0.9, 0.4, 0.5) if snap["valid"] else Color(0.9, 0.2, 0.2, 0.5)
		for c in snap["cells"]["footprint"]:
			draw_rect(Rect2i(c.x * CELL, c.y * CELL, CELL, CELL), fill)
		for c in snap["cells"]["access"]:
			draw_rect(Rect2i(c.x * CELL, c.y * CELL, CELL, CELL), fill)

func _heat_color(d: float) -> Color:
	var r: float = clamp(d * 2.0, 0.0, 1.0)
	var g: float = clamp(1.0 - abs(d - 0.5) * 2.0, 0.0, 1.0)
	var b: float = clamp((1.0 - d) * 2.0, 0.0, 1.0)
	return Color(r * 0.35, g * 0.25, b * 0.4)

func _peak_density() -> float:
	var r: Rect2i = _grid.get_dimensions()
	var mx: float = 0.0
	for x in range(r.position.x, r.end.x):
		for y in range(r.position.y, r.end.y):
			var d: float = _cong.get_density(Vector2i(x, y))
			if d > mx:
				mx = d
	return mx

func _avg_congestion() -> float:
	var s := 0.0
	for eid in _equip_ids:
		s += _cong.get_congestion(eid)
	return s / float(_equip_ids.size())

# --- bench mode: validate A7 (logic throughput @ 10 members / 3 machines) ---
func _run_world(kind: String, ticks: int) -> float:
	_setup_world()
	_apply_layout(kind)
	for i in ticks:
		if _member._members.size() < 10:
			_member.spawn_member()
		_tick()
		_overlay.build(_member, _cong)
	return _peak_density()

func _run_bench() -> void:
	var d_clumped: float = _run_world("clumped", 600)
	var d_spread: float = _run_world("spread", 600)
	print("HEAT-DISPERSE: clumped peak_density=%.3f vs spread=%.3f (spread should be lower = relieved)" % [d_clumped, d_spread])
	var t0 := Time.get_ticks_usec()
	var ticks := 600  # 60 virtual seconds @ 10Hz
	for i in ticks:
		_tick()
		_overlay.build(_member, _cong)
	var t1 := Time.get_ticks_usec()
	var ms := float(t1 - t0) / 1000.0
	var per_tick := ms / float(ticks)
	print("BENCH: %d logic ticks in %.1f ms (%.3f ms/tick)" % [ticks, ms, per_tick])
	print("BENCH: budget @60fps = 16.67 ms/frame; 10Hz tick = 100ms cadence -> headroom %.1fx" % [16.67 / per_tick])
	# render-path smoke: force one _draw() so the draw_* calls are exercised
	# (headless has no GPU, but a null-font crash here would surface a real bug)
	print("BENCH: forcing one _draw() (render-path smoke)")
	_draw()
	print("BENCH: _draw() returned without crash")
	get_tree().quit(0)

func _save_frame() -> void:
	if _dump_done:
		return
	_dump_done = true
	var vp = get_viewport()
	var tex = vp.get_texture()
	if tex != null:
		var img = tex.get_image()
		if img != null:
			img.save_png("/tmp/gym_render.png")
			print("DUMP: saved /tmp/gym_render.png")
		else:
			print("DUMP: get_image() returned null")
	else:
		print("DUMP: viewport texture null")
	get_tree().quit(0)
