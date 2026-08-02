# tests/probes/path_edge_probe.gd
# Story 003 probe — verify AStarGrid2D 4.7.1 edge behaviors in isolation:
#   1. get_id_path(from, from) on an OPEN cell -> [from]?
#   2. get_id_path(from, to) where to is SOLID -> []?
#   3. get_id_path with a fully-enclosed target -> []?
#   4. is_point_solid() exists and mirrors seeded solidity?
#   5. get_id_path typed return (Array[Vector2i])?
#   6. get_id_path with OOB -> engine ERROR? (we guard in the wrapper)
extends SceneTree

func _init() -> void:
	var GS: Script = load("res://src/systems/grid_system.gd") as Script
	var gs: RefCounted = GS.new()
	gs.call("init", 13, 10)
	for y in 10:
		for x in 13:
			gs.call("set_buildable", Vector2i(x, y), true)
	gs.call("freeze_buildable")

	var astar := AStarGrid2D.new()
	astar.region = Rect2i(0, 0, 13, 10)
	astar.cell_size = Vector2.ONE
	astar.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	astar.default_compute_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	astar.default_estimate_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	astar.jumping_enabled = false
	astar.update()
	for y in 10:
		for x in 13:
			astar.set_point_solid(Vector2i(x, y), gs.call("is_solid", Vector2i(x, y)))
	astar.update()

	print("PROBE has_method is_point_solid: ", astar.has_method("is_point_solid"))
	print("PROBE is_point_solid(2,2) open: ", astar.is_point_solid(Vector2i(2, 2)))

	# 1. from == to on open cell
	var self_path: Variant = astar.get_id_path(Vector2i(2, 2), Vector2i(2, 2))
	print("PROBE self_path type: ", type_string(typeof(self_path)), " value: ", self_path)

	# 4. solid destination
	var fp: Array[Vector2i] = [Vector2i(5, 5)]
	var ac: Array[Vector2i] = []
	gs.call("commit", 1, fp, ac, 0)
	astar.set_point_solid(Vector2i(5, 5), true)
	astar.update()
	print("PROBE is_point_solid(5,5) solid: ", astar.is_point_solid(Vector2i(5, 5)))
	var to_solid: Variant = astar.get_id_path(Vector2i(0, 0), Vector2i(5, 5))
	print("PROBE to_solid: ", to_solid, " is_empty=", to_solid.is_empty())

	# 4b. solid from endpoint + solid from==to
	var from_solid: Variant = astar.get_id_path(Vector2i(5, 5), Vector2i(0, 0))
	print("PROBE from_solid: ", from_solid, " is_empty=", from_solid.is_empty())
	var solid_self: Variant = astar.get_id_path(Vector2i(5, 5), Vector2i(5, 5))
	print("PROBE solid from==to: ", solid_self, " is_empty=", solid_self.is_empty())

	# 2. enclosed target: ring of 8 solids around (3,3)
	var ring: Array[Vector2i] = [
		Vector2i(2, 2), Vector2i(3, 2), Vector2i(4, 2),
		Vector2i(2, 3), Vector2i(4, 3),
		Vector2i(2, 4), Vector2i(3, 4), Vector2i(4, 4),
	]
	for i in ring.size():
		var ring_fp: Array[Vector2i] = [ring[i]]
		var ring_ac: Array[Vector2i] = []
		gs.call("commit", 100 + i, ring_fp, ring_ac, 0)
		astar.set_point_solid(ring[i], true)
	astar.update()
	var enclosed: Variant = astar.get_id_path(Vector2i(0, 0), Vector2i(3, 3))
	print("PROBE enclosed (3,3): ", enclosed, " is_empty=", enclosed.is_empty())

	# 5. typed return
	var typed: Array[Vector2i] = astar.get_id_path(Vector2i(0, 0), Vector2i(2, 0))
	print("PROBE typed assign ok, builtin=", typed.get_typed_builtin(), " value=", typed)

	# 6. OOB behavior
	var oob: Variant = astar.get_id_path(Vector2i(-1, 0), Vector2i(2, 0))
	print("PROBE oob from: ", oob, " is_empty=", oob.is_empty())

	print("PROBE_DONE")
	quit(0)
