# tests/unit/navigation/tiebreak_child.gd
# ADR-0007 gate test child process — NOT a *_test.gd file (headless_runner
# scans only *_test.gd, so this helper is never picked up as a test).
#
# Spawned by tiebreak_cross_rebuild_test.gd via OS.execute(). Repeats the
# ADR-0007 Decision §1 protocol steps 1–5 in a FRESH Godot process:
#   1. deterministic occupancy with a known symmetric equal-cost path pair
#   2. AStarGrid2D configured identically to production
#      (DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES, HEURISTIC_OCTILE, cell_size=ONE)
#   3. populate solidity from the deterministic occupancy map
#   4. update()
#   5. get_id_path(from, to) recorded
# It then serializes the path to a file passed on the command line (NOT
# stdout — the engine banner pollutes stdout; file handoff is robust across
# Godot versions, which matters because the gate re-runs on every bump).
#
# Heap perturbation: each child allocates varying dummy memory BEFORE
# AStarGrid2D construction (ADR-0007 risk mitigation — rules out
# pointer-address-dependent tie-breaking). The perturb seed comes from argv.
#
# Usage (spawned by the parent test):
#   godot --headless --path <project> --script res://tests/unit/navigation/tiebreak_child.gd \
#         -- <perturb_seed:int> <output_file:abs_path>
extends SceneTree

# Grid geometry — MUST stay in sync with the parent test's golden builder.
const GRID_SIZE := Vector2i(13, 10)
const FROM := Vector2i(2, 4)
const TO := Vector2i(10, 4)
# A single solid cell at the midline creates a symmetric equal-cost fork:
# the shortest path must go either above (y=3) or below (y=5), both length 9.
const SOLID_CELL := Vector2i(6, 4)


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var seed := 0
	var out_file := ""
	if args.size() >= 1:
		seed = int(args[0])
	if args.size() >= 2:
		out_file = args[1]

	var path: Array[Vector2i] = build_path(seed)

	var f := FileAccess.open(out_file, FileAccess.WRITE)
	if f == null:
		printerr("tiebreak_child: cannot open output file %s (err %d)" % [out_file, FileAccess.get_open_error()])
		quit(1)
		return
	f.store_string(serialize(path))
	f.close()
	quit(0)


## Builds the production-configured AStarGrid2D over the deterministic
## occupancy and returns get_id_path(FROM, TO). [perturb_seed] controls the
## dummy heap allocation performed BEFORE construction.
static func build_path(perturb_seed: int) -> Array[Vector2i]:
	_perturb_heap(perturb_seed)

	var astar := AStarGrid2D.new()
	astar.region = Rect2i(0, 0, GRID_SIZE.x, GRID_SIZE.y)
	astar.cell_size = Vector2.ONE
	astar.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	astar.default_compute_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	astar.default_estimate_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	astar.jumping_enabled = false
	astar.update()  # MUST precede set_point_solid — grid init (4.7.1 probed)
	for y in GRID_SIZE.y:
		for x in GRID_SIZE.x:
			astar.set_point_solid(Vector2i(x, y), _is_solid(Vector2i(x, y)))
	astar.update()
	return astar.get_id_path(FROM, TO)


## Deterministic occupancy — the "known symmetry" of ADR-0007 Decision §1.
## MUST stay in sync with the parent test's golden builder.
static func _is_solid(cell: Vector2i) -> bool:
	return cell == SOLID_CELL


## Allocates a variable amount of dummy memory to perturb heap layout so a
## pointer-address-dependent tie-break would surface as a different result.
static func _perturb_heap(seed: int) -> void:
	var junk: Array[PackedByteArray] = []
	var n := 50 + (seed % 150)
	for i in n:
		junk.append(PackedByteArray())
		junk[i].resize(100 + (i * 13 + seed * 17) % 4096)
	# junk stays alive until build_path returns — AStarGrid2D is constructed
	# against a perturbed allocator state.


## Bit-identical serialization: "x,y|x,y|..." or "EMPTY" for no path.
static func serialize(path: Array) -> String:
	if path.is_empty():
		return "EMPTY"
	var parts := PackedStringArray()
	for v in path:
		parts.append("%d,%d" % [v.x, v.y])
	return "|".join(parts)
