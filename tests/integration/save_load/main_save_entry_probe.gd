## GA-002 real SceneTree lifecycle probe. Runs isolated named saves, never manual.sav.json.
extends SceneTree

const Main := preload("res://src/main.gd")
const Preflight := preload("res://src/bootstrap/resource_preflight.gd")
var _failures := 0
var _checks := 0
var _main

func _initialize() -> void:
	# A script error otherwise leaves an idle SceneTree and hangs the full runner.
	create_timer(15.0).timeout.connect(func() -> void: quit(1))
	_run.call_deferred()

func _check(value: bool, description: String) -> void:
	_checks += 1
	if not value:
		_failures += 1
		push_error(description)

func _run() -> void:
	_main = Main.new()
	root.add_child(_main)
	await process_frame
	# Point the save tree at an OS temp dir (SaveLoad test seam) so this probe
	# does not depend on write access to the OS user data directory.
	_main._save_load.call("set_save_root_override", OS.get_temp_dir().path_join("gym_manager_ga002_probe_saves"))
	_main._save_name = "ga002-main-probe"
	_main._orch.time_system.pause()
	_check(_main._save_entry.get_node("Actions/SaveButton").text.contains("保存"), "visible Chinese save button")
	_check(_main._save_entry.get_node("Actions/LoadButton").text.contains("读档"), "visible Chinese load button")
	_main._drag_drop(_main._orch.placement_system, "yoga_mat", Vector2i(3, 3))
	var before_tick: int = _main._orch.get_tick_count()
	_main._save_entry.get_node("Actions/SaveButton").pressed.emit()
	_check(_main._save_entry.get_feedback().contains("保存成功"), "save button synchronously saves while paused")
	_check(_main._orch.get_tick_count() == before_tick, "paused save does not advance tick")
	var balance: int = _main._econ.balance
	_main._econ.credit(19, "probe")
	_main._palette.on_tile_mouse_down("bike")
	_main._save_entry.get_node("Actions/LoadButton").pressed.emit()
	_check(_main._save_entry.get_feedback().contains("读档成功"), "actual main load succeeds")
	_check(_main._orch.time_system.is_paused(), "load pauses")
	_check(_main._econ.balance == balance, "economy restored")
	_check(_main._hud.get_money_label().text == _main._hud.format_money(balance), "paused load refreshes displayed balance")
	_check(not _main._orch.placement_system.is_dragging() and not _main._palette.is_drag_in_flight() and not _main._shop.is_purchase_in_flight(), "load clears drag/shop transients")
	var placed: Array = _main._grid.get_placed_instances()
	_check(placed.size() == 1 and _main._resolver().call(placed[0].instance_id) == "yoga_mat", "loaded resolver preserves yoga identity")
	_main._save_name = "ga002-missing-probe"
	_check(not _main.load_game(), "missing save fails")
	_check(_main._econ.balance == balance and _main._grid.get_placed_instances().size() == 1, "failed load does not mutate live game")
	_check(_main._save_entry.get_feedback().contains("读档失败"), "failure feedback remains visible")
	_check(not Preflight.check("res://tests/nonexistent-ga002-data").ok, "missing required data fails preflight")
	_check(Preflight.check().ok, "shipped resources pass preflight")
	DirAccess.remove_absolute(_main._save_load.call("get_save_path", "ga002-main-probe"))
	_main.queue_free()
	await process_frame
	print("GA-002 MAIN ENTRY: %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)
