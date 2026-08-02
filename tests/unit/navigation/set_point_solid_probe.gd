# Probe: AStarGrid2D set_point_solid() semantics on Godot 4.7.1
# Question: after the initial update() that initializes the grid, does a
# subsequent set_point_solid(cell, true) take effect IMMEDIATELY for
# get_id_path(), or does it require a SECOND update()?
#
# This decides the AC7 negative control in story-004:
#   - integration test grid_navigation_solidity_test.gd claims immediate
#     effect (no trailing update() needed) — "probed"
#   - story-004 / navigation.md claims set_point_solid has NO effect until
#     update() is called again ("corrected for 4.7.1")
#
# Run: godot --headless --script tests/unit/navigation/set_point_solid_probe.gd
extends SceneTree

func _init() -> void:
	print("=== set_point_solid semantics probe (Godot %s) ===" % Engine.get_version_info().string)

	var astar := AStarGrid2D.new()
	astar.region = Rect2i(0, 0, 13, 10)
	astar.cell_size = Vector2.ONE
	astar.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	astar.default_compute_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	astar.default_estimate_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	astar.jumping_enabled = false

	# 1. INIT update() — builds the point graph
	astar.update()
	print("after init update():")

	# 2. baseline path — clear
	var p0: Array[Vector2i] = astar.get_id_path(Vector2i(2, 2), Vector2i(2, 5))
	print("  baseline (2,2)->(2,5): ", p0)

	# 3. set_point_solid WITHOUT a trailing update()
	astar.set_point_solid(Vector2i(2, 4), true)
	var p1: Array[Vector2i] = astar.get_id_path(Vector2i(2, 2), Vector2i(2, 5))
	print("  after set_point_solid((2,4), true), NO update(): ", p1)
	print("  (2,4) in path? ", p1.has(Vector2i(2, 4)))

	# 4. now call update() and re-query
	astar.update()
	var p2: Array[Vector2i] = astar.get_id_path(Vector2i(2, 2), Vector2i(2, 5))
	print("  after set_point_solid + update(): ", p2)
	print("  (2,4) in path? ", p2.has(Vector2i(2, 4)))

	# 5. clear it back — set_point_solid(cell, false) semantics
	astar.set_point_solid(Vector2i(2, 4), false)
	var p3: Array[Vector2i] = astar.get_id_path(Vector2i(2, 2), Vector2i(2, 5))
	print("  after set_point_solid((2,4), false), NO update(): ", p3)
	print("  (2,4) in path? ", p3.has(Vector2i(2, 4)))

	astar.update()
	var p4: Array[Vector2i] = astar.get_id_path(Vector2i(2, 2), Vector2i(2, 5))
	print("  after set_point_solid(false) + update(): ", p4)
	print("  (2,4) in path? ", p4.has(Vector2i(2, 4)))

	# 6. corner case: solidity that does NOT change (idempotent re-push, AC8)
	astar.set_point_solid(Vector2i(2, 4), false)  # already non-solid
	astar.update()
	var p5: Array[Vector2i] = astar.get_id_path(Vector2i(2, 2), Vector2i(2, 5))
	print("  after re-push same value (false) + update(): ", p5)
	astar.set_point_solid(Vector2i(2, 4), true)
	astar.update()
	var p6: Array[Vector2i] = astar.get_id_path(Vector2i(2, 2), Vector2i(2, 5))
	astar.set_point_solid(Vector2i(2, 4), true)  # re-push same value
	astar.update()
	var p7: Array[Vector2i] = astar.get_id_path(Vector2i(2, 2), Vector2i(2, 5))
	print("  after solid->same-solid re-push + update(): ", p7)
	print("  re-push identical result? ", p6 == p7)

	quit(0)
