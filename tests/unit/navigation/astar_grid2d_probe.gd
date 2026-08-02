# Probe: AStarGrid2D API surface on Godot 4.7.1
# Run: godot --headless --script tests/probes/astar_grid2d_probe.gd
extends SceneTree

func _init() -> void:
	print("=== AStarGrid2D API probe (Godot %s) ===" % Engine.get_version_info().string)

	var astar := AStarGrid2D.new()
	print("has region prop: ", astar.get("region") != null)
	print("has diagonal_mode prop: ", astar.get("diagonal_mode") != null)
	print("has jumping_enabled prop: ", astar.get("jumping_enabled") != null)
	print("has default_compute_heuristic prop: ", astar.get("default_compute_heuristic") != null)
	print("has default_estimate_heuristic prop: ", astar.get("default_estimate_heuristic") != null)

	print("DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES = ", AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES)
	print("HEURISTIC_OCTILE = ", AStarGrid2D.HEURISTIC_OCTILE)
	print("default cell_size = ", astar.cell_size)
	print("has set_point_solid: ", astar.has_method("set_point_solid"))
	print("has get_id_path: ", astar.has_method("get_id_path"))
	print("has get_point_path: ", astar.has_method("get_point_path"))

	# Behavioral probe: empty 13x10 grid, straight line and diagonal
	astar.region = Rect2i(0, 0, 13, 10)
	astar.cell_size = Vector2.ONE
	astar.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	astar.default_compute_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	astar.default_estimate_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	astar.jumping_enabled = false
	astar.update()

	var path1: Array[Vector2i] = astar.get_id_path(Vector2i(2, 2), Vector2i(2, 5))
	print("AC1 straight (2,2)->(2,5): ", path1)

	var path2: Array[Vector2i] = astar.get_id_path(Vector2i(0, 0), Vector2i(3, 3))
	print("AC2 diagonal (0,0)->(3,3): ", path2, " size=", path2.size())

	var path3: Array[Vector2i] = astar.get_id_path(Vector2i(0, 0), Vector2i(3, 2))
	print("AC15 (0,0)->(3,2): ", path3, " size=", path3.size())

	# from == to
	var path4: Array[Vector2i] = astar.get_id_path(Vector2i(2, 2), Vector2i(2, 2))
	print("from==to (2,2)->(2,2): ", path4)

	# out of bounds
	var path5: Array[Vector2i] = astar.get_id_path(Vector2i(-1, -1), Vector2i(2, 2))
	print("OOB (-1,-1)->(2,2): ", path5)

	# set_point_solid then re-query — does it take effect immediately or need update()?
	astar.set_point_solid(Vector2i(2, 3), true)
	var path6: Array[Vector2i] = astar.get_id_path(Vector2i(2, 2), Vector2i(2, 5))
	print("after set_point_solid(2,3) NO update (2,2)->(2,5): ", path6)
	astar.update()
	var path7: Array[Vector2i] = astar.get_id_path(Vector2i(2, 2), Vector2i(2, 5))
	print("after set_point_solid(2,3) + update (2,2)->(2,5): ", path7)

	# jumping probe
	astar.jumping_enabled = true
	astar.update()
	var path8: Array[Vector2i] = astar.get_id_path(Vector2i(0, 0), Vector2i(5, 0))
	print("jumping_enabled=true (0,0)->(5,0): ", path8)
	astar.jumping_enabled = false
	astar.update()

	quit(0)
