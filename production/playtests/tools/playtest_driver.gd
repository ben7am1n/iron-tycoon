# playtest_driver.gd — external playtest input driver for the UI playable build.
#
# External-tester session rig: instances the REAL production main scene
# (src/main.tscn) and drives it with genuine InputEvents injected via
# Input.parse_input_event() — the identical pipeline a human player's
# mouse/keyboard go through (Window -> Viewport -> GUI hit-test on Controls
# -> _unhandled_input on the placement/selection bridges -> systems).
#
# Evidence method (production/playtests README):
#   godot --path <repo> res://production/playtests/tools/playtest_driver.tscn \
#         --write-movie <out>/frame.png --fixed-fps 60
#
# The driver logs an action timeline to stdout (frame, action, VERIFIED
# state read 5 frames after each input — not self-reported assumptions)
# and the movie writer captures every rendered frame.
extends Node2D

const MAIN_SCENE := preload("res://src/main.tscn")

# ---- node handles ----
var _main: Node2D
var _palette
var _hud
var _toolbar
var _cue
var _grid
var _placement
var _selection
var _bridge_sel
var _econ
var _time_system

var _frame := 0
var _started := false
var _log: Array = []
var _last_pos := Vector2.ZERO
var _pending_actions: Array = []  # [frame, callable]


func _ready() -> void:
	_main = MAIN_SCENE.instantiate()
	add_child(_main)


func _process(_delta: float) -> void:
	_frame += 1
	if _frame == 5:
		_resolve_nodes()
		if _grid == null:
			push_error("driver: failed to resolve system nodes")
			get_tree().quit(1)
			return
		_started = true
		_dump_layout()
		_read_state("opening", "game loaded; expect PAUSED (GDD Core Rule 9)")
	if not _started:
		return
	# scheduled actions
	var i := 0
	while i < _pending_actions.size():
		if _frame >= _pending_actions[i][0]:
			var cb: Callable = _pending_actions[i][1]
			_pending_actions.remove_at(i)
			cb.call()
		else:
			i += 1
	# post-action verified reads: every action schedules a follow-up read
	match _frame:
		10:
			_read_state("t10", "baseline after load")
			_schedule(90, "unpause", _do_unpause)
		110:
			_read_state("t110", "after Space")
			_schedule(200, "palette-click", _do_palette_click)
		260:
			_read_state("t260", "after palette click")
			_schedule(300, "select-cell", _do_select_cell)
		360:
			_read_state("t360", "after select")
			_schedule(400, "move-click", _do_move_click)
		460:
			_read_state("t460", "after move")
			_schedule(500, "sell-click", _do_sell_click)
		560:
			_read_state("t560", "after sell-click-1")
			_schedule(590, "sell-click-2", _do_sell_click)
		650:
			_read_state("t650", "after sell-click-2")
			_finish()


func _schedule(f: int, tag: String, cb: Callable) -> void:
	_pending_actions.append([f, cb])


# === actions ===

func _do_unpause() -> void:
	_send_key(KEY_SPACE)
	print("  ACTION f=%d: Space (unpause)" % _frame)


func _do_palette_click() -> void:
	if _palette == null or not _palette.has_method("get_tile"):
		push_error("driver: palette unavailable")
		return
	var tile = _palette.get_tile("treadmill")
	if tile == null:
		push_error("driver: tile treadmill not found")
		return
	var center: Vector2 = tile.get_global_rect().get_center()
	print("  ACTION f=%d: palette click treadmill at %s (tile rect %s)" % [_frame, center, tile.get_global_rect()])
	_last_pos = center
	_mouse_event(true, center)


func _do_select_cell() -> void:
	var pos: Vector2 = _cell_center(Vector2i(9, 2))
	print("  ACTION f=%d: click cell (9,2) at %s" % [_frame, pos])
	_last_pos = pos
	_mouse_event(true, pos)
	_mouse_event(false, pos)


func _do_move_click() -> void:
	if _toolbar == null:
		push_error("driver: toolbar unavailable")
		return
	var btn = _toolbar.get_node_or_null("ToolbarRow/MoveButton")
	if btn == null:
		push_error("driver: MoveButton not found")
		return
	var center: Vector2 = btn.get_global_rect().get_center()
	print("  ACTION f=%d: click MoveButton at %s (btn rect %s, toolbar visible=%s)" % [_frame, center, btn.get_global_rect(), _toolbar.is_visible()])
	_last_pos = center
	_mouse_event(true, center)
	_mouse_event(false, center)


func _do_sell_click() -> void:
	if _toolbar == null:
		push_error("driver: toolbar unavailable")
		return
	var btn = _toolbar.get_node_or_null("ToolbarRow/SellButton")
	if btn == null:
		push_error("driver: SellButton not found")
		return
	var center: Vector2 = btn.get_global_rect().get_center()
	print("  ACTION f=%d: click SellButton at %s (btn rect %s, toolbar visible=%s, label=%s)" % [_frame, center, btn.get_global_rect(), _toolbar.is_visible(), btn.text])
	_last_pos = center
	_mouse_event(true, center)
	_mouse_event(false, center)


# === verified state read ===

func _read_state(tag: String, note: String) -> void:
	var members: int = 0
	var members_raw = _member_count()
	if members_raw is Array:
		members = members_raw.size()
	var placed: int = 0
	if _grid != null and _grid.has_method("get_placed_instances"):
		placed = _grid.get_placed_instances().size()
	var balance: int = -1
	if _econ != null:
		balance = _econ.balance
	var paused: String = "?"
	if _time_system != null:
		paused = str(_time_system.is_paused())
	var sel_id: int = -1
	if _selection != null and _selection.has_method("get_selected_instance_id"):
		sel_id = _selection.get_selected_instance_id()
	var dragging: String = "?"
	if _placement != null:
		dragging = str(_placement.is_dragging())
	var toolbar_vis: String = "n/a"
	if _toolbar != null:
		toolbar_vis = str(_toolbar.is_visible())
	var sell_label: String = "n/a"
	if _toolbar != null and _toolbar.has_method("get_sell_label"):
		sell_label = str(_toolbar.get_sell_label())
	var line := "f=%d [%s] %s | members=%d placed=%d balance=%d paused=%s sel=%d dragging=%s toolbar=%s sellLabel=%s" % [
		_frame, tag, note, members, placed, balance, paused, sel_id, dragging, toolbar_vis, sell_label,
	]
	_log.append(line)
	print(line)


func _dump_layout() -> void:
	print("  LAYOUT: grid=%s palette=%s hud=%s toolbar=%s cue=%s" % [
		_grid.get_dimensions() if _grid != null and _grid.has_method("get_dimensions") else "?",
		_palette.get_global_rect() if _palette != null else "?",
		_hud.get_global_rect() if _hud != null else "?",
		_toolbar.get_global_rect() if _toolbar != null else "?",
		_cue.get_global_rect() if _cue != null else "?",
	])
	if _palette != null and _palette.has_method("get_tile"):
		for eid in ["treadmill", "bike", "bench_press", "yoga_mat"]:
			var t = _palette.get_tile(eid)
			if t != null:
				print("  TILE %s rect=%s" % [eid, t.get_global_rect()])


# === node resolution ===

func _resolve_nodes() -> void:
	for child in _main.get_children():
		var script_path := ""
		if child.get_script() != null:
			script_path = child.get_script().resource_path
		match script_path:
			"res://src/ui/build_shop_palette.gd":
				_palette = child
			"res://src/ui/hud.gd":
				_hud = child
			"res://src/ui/selection_toolbar.gd":
				_toolbar = child
			"res://src/ui/selection_cue.gd":
				_cue = child
	if _palette == null:
		_palette = _main.get_node_or_null("BuildShopPalette")
	if _hud == null:
		_hud = _main.get_node_or_null("Hud")
	if _toolbar == null:
		_toolbar = _main.get_node_or_null("SelectionToolbar")
	if _cue == null:
		_cue = _main.get_node_or_null("SelectionCue")
	var orch = _find_orch()
	if orch != null:
		_grid = orch.grid_system
		_placement = orch.placement_system
		_selection = orch.selection_system
		_bridge_sel = orch.get_node_or_null("SelectionInputBridge")
		_econ = orch.economy
		_time_system = orch.time_system


func _find_orch():
	for child in _main.get_children():
		if child.get_script() != null and child.get_script().resource_path == "res://src/systems/simulation_orchestrator.gd":
			return child
	return null


func _member_count():
	var orch = _find_orch()
	if orch == null or orch.member_sim == null:
		return []
	if orch.member_sim.has_method("get_members"):
		return orch.member_sim.get_members()
	if "members" in orch.member_sim:
		return orch.member_sim.members
	return []


# === input injection ===

func _send_key(keycode: int) -> void:
	var ev := InputEventKey.new()
	ev.keycode = keycode
	ev.pressed = true
	Input.parse_input_event(ev)
	var rel := InputEventKey.new()
	rel.keycode = keycode
	rel.pressed = false
	Input.parse_input_event(rel)


func _mouse_event(pressed: bool, pos: Vector2) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = pressed
	ev.position = pos
	ev.global_position = pos
	Input.parse_input_event(ev)


func _mouse_move(pos: Vector2) -> void:
	var ev := InputEventMouseMotion.new()
	ev.position = pos
	ev.global_position = pos
	Input.parse_input_event(ev)


func _cell_center(cell: Vector2i) -> Vector2:
	return Vector2(cell.x * 32.0 + 16.0, cell.y * 32.0 + 16.0)


func _finish() -> void:
	print("=".repeat(56))
	print("  PLAYTEST DRIVER TIMELINE")
	for line in _log:
		print("  " + line)
	print("=".repeat(56))
	get_tree().quit(0)
