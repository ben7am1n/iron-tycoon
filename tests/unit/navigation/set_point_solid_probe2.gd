# Probe 2: AStarGrid2D dirty-flag mechanics + is_point_solid API (Godot 4.7.1)
# Follow-up to set_point_solid_probe.gd. The first probe showed set_point_solid
# takes effect IMMEDIATELY for get_id_path() after init update(). This probe
# determines WHY: does get_id_path() auto-apply pending changes (dirty flag),
# and is is_point_solid() exposed for the AC9 white-box hook?
#
# Run: godot --headless --script tests/unit/navigation/set_point_solid_probe2.gd
extends SceneTree

func _init() -> void:
	print("=== set_point_solid mechanics probe 2 (Godot %s) ===" % Engine.get_version_info().string)

	var astar := AStarGrid2D.new()
	astar.region = Rect2i(0, 0, 13, 10)
	astar.cell_size = Vector2.ONE
	astar.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	astar.default_compute_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	astar.default_estimate_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	astar.jumping_enabled = false
	astar.update()

	# 1. is_point_solid exposed?
	print("has is_point_solid method: ", astar.has_method("is_point_solid"))
	if astar.has_method("is_point_solid"):
		print("  is_point_solid((2,4)) before set: ", astar.call("is_point_solid", Vector2i(2, 4)))
		astar.set_point_solid(Vector2i(2, 4), true)
		print("  is_point_solid((2,4)) after set (no update): ", astar.call("is_point_solid", Vector2i(2, 4)))
		astar.update()
		print("  is_point_solid((2,4)) after set + update: ", astar.call("is_point_solid", Vector2i(2, 4)))

	# 2. is_dirty / get_solid_points / get_non_solid_points exposed?
	print("has is_dirty method: ", astar.has_method("is_dirty"))
	print("has get_solid_points method: ", astar.has_method("get_solid_points"))
	print("has get_non_solid_points method: ", astar.has_method("get_non_solid_points"))

	# 3. Does get_id_path() itself trigger an internal update (auto-clean of
	#    the dirty flag)? Observable: after set_point_solid, call get_id_path,
	#    then check is_dirty (if exposed).
	astar.set_point_solid(Vector2i(3, 3), true)
	if astar.has_method("is_dirty"):
		print("is_dirty right after set_point_solid: ", astar.call("is_dirty"))
		var p: Array[Vector2i] = astar.get_id_path(Vector2i(0, 0), Vector2i(5, 5))
		print("path after query: ", p)
		print("is_dirty after get_id_path: ", astar.call("is_dirty"))
	else:
		print("is_dirty NOT exposed — cannot observe auto-update mechanism directly")

	# 4. Critical for the handler contract: what does get_path see if we push
	#    solidity WITHOUT calling update()? (probe 1 answered: excluded).
	#    Re-verify with a query-order twist: query BEFORE pushing, then push,
	#    then query again without update.
	var base: Array[Vector2i] = astar.get_id_path(Vector2i(2, 2), Vector2i(2, 5))
	astar.set_point_solid(Vector2i(2, 4), true)
	var after_push: Array[Vector2i] = astar.get_id_path(Vector2i(2, 2), Vector2i(2, 5))
	print("query-before vs after-push(no update): ", base, " -> ", after_push)
	print("(2,4) excluded without update? ", not after_push.has(Vector2i(2, 4)))

	# 5. What if the FIRST update() is never called — set_point_solid before
	#    init? (The story says grid must be initialized. Probe the error.)
	var raw := AStarGrid2D.new()
	raw.region = Rect2i(0, 0, 5, 5)
	raw.cell_size = Vector2.ONE
	raw.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	raw.default_compute_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	raw.default_estimate_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	raw.jumping_enabled = false
	# NOTE: no update() before set_point_solid
	raw.set_point_solid(Vector2i(1, 1), true)
	print("set_point_solid before first update(): completed without script error (see stderr for engine warning)")

	# 6. If a second update() is called after a solid push, is the result
	#    identical to no-update? (idempotence check for handler design)
	var a1 := AStarGrid2D.new()
	a1.region = Rect2i(0, 0, 13, 10)
	a1.cell_size = Vector2.ONE
	a1.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	a1.default_compute_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	a1.default_estimate_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	a1.jumping_enabled = false
	a1.update()
	a1.set_point_solid(Vector2i(2, 4), true)
	var no_update: Array[Vector2i] = a1.get_id_path(Vector2i(2, 2), Vector2i(2, 5))
	a1.update()
	var with_update: Array[Vector2i] = a1.get_id_path(Vector2i(2, 2), Vector2i(2, 5))
	print("no-update path == with-update path? ", no_update == with_update, " (", no_update, " vs ", with_update, ")")

	quit(0)
