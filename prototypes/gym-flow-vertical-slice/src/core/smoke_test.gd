# VERTICAL SLICE - NOT FOR PRODUCTION
# Headless smoke test for the deterministic core (GridSystem + SeededRNG).
# Run: godot --headless --script res://src/core/smoke_test.gd  (from project dir)
extends SceneTree

const SeededRNGScript := preload("res://src/core/seeded_rng.gd")
const GridSystemScript := preload("res://src/core/grid_system.gd")

var _pass := 0
var _fail := 0

# Reference-typed signal counter — method callback mutates instance field (visible to caller).
class SignalCounter:
	extends RefCounted
	var count := 0
	func on_changed(_f: Array, _a: Array) -> void:
		count += 1

func _initialize() -> void:
	_test_rng()
	_test_grid()
	print("\n=== SMOKE TEST: %d passed, %d failed ===" % [_pass, _fail])
	quit(_fail > 0)

func _check(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
		print("  PASS: " + msg)
	else:
		_fail += 1
		print("  FAIL: " + msg)

func _test_rng() -> void:
	print("[SeededRNG]")
	var r1 := SeededRNGScript.new(12345)
	var r2 := SeededRNGScript.new(12345)
	_check(r1.get_sub_seed("MemberSim") == r2.get_sub_seed("MemberSim"), "same master+name -> identical sub_seed")
	_check(r1.get_sub_seed("MemberSim") != r1.get_sub_seed("Congestion"), "different names -> different sub_seeds")
	var a := SeededRNGScript.new(999)
	var b := SeededRNGScript.new(1000)
	_check(a.get_sub_seed("MemberSim") != b.get_sub_seed("MemberSim"), "different master -> different sub_seeds")
	var rng_a := r1.get_rng("MemberSim")
	var rng_b := r2.get_rng("MemberSim")
	var seq_match := true
	for i in 100:
		if rng_a.randf() != rng_b.randf():
			seq_match = false
			break
	_check(seq_match, "100-draw RNG stream bit-identical across two instances")

func _test_grid() -> void:
	print("[GridSystem]")
	var region := Rect2i(0, 0, 13, 10)
	var buildable := {}
	for x in range(13):
		for y in range(10):
			buildable[Vector2i(x, y)] = true
	var grid := GridSystemScript.new(region, buildable)
	_check(grid.is_solid(Vector2i(-1, 0)) == true, "out-of-bounds cell is solid")
	_check(grid.is_solid(Vector2i(2, 2)) == false, "empty buildable cell is not solid")
	_check(grid.is_solid(Vector2i(13, 0)) == true, "beyond-width cell is solid")

	var fp := [Vector2i(0,0), Vector2i(1,0)]
	var ac := [Vector2i(2,0)]
	_check(grid.commit(1, fp, ac, Vector2i(0,0), 0), "first commit succeeds")
	_check(grid.is_solid(Vector2i(0,0)) == true, "occupied footprint cell is solid")
	_check(grid.is_solid(Vector2i(2,0)) == false, "access-only cell is NOT solid (no member trap)")
	_check(grid.can_place(fp, ac, Vector2i(0,0), 0) == false, "overlap commit rejected by can_place")
	_check(grid.commit(1, fp, ac, Vector2i(0,0), 0) == false, "duplicate id commit rejected")

	# Highest-risk rule: union bbox (W=3,H=1) for footprint(0,0),(1,0)+access(2,0).
	# 90deg: (x,y)->(H-1-y, x) = (0-y, x). anchor(5,5) -> access at (5,7), not (7,5).
	grid.clear(1)
	_check(grid.commit(2, fp, ac, Vector2i(5,5), 90), "rotated commit succeeds")
	var rec: Dictionary = grid._instances[2]
	_check(rec["access"].has(Vector2i(5,7)), "rotation uses UNION bbox (access at (5,7), not (7,5))")
	_check(not rec["access"].has(Vector2i(7,5)), "rotation does NOT use footprint-local bbox")

	_check(grid.can_place([Vector2i(12,9), Vector2i(13,9)], [Vector2i(14,9)], Vector2i(12,9), 0) == false, "out-of-bounds placement rejected")

	# grid_changed fires exactly once per commit / clear (method callback, ref-typed counter)
	var sc := SignalCounter.new()
	grid.grid_changed.connect(sc.on_changed)
	_check(grid.commit(3, [Vector2i(0,0)], [Vector2i(1,0)], Vector2i(8,8), 0), "commit(3) at empty cells succeeds")
	_check(sc.count == 1, "grid_changed fires exactly once per commit")
	grid.clear(3)
	_check(sc.count == 2, "grid_changed fires once on clear too")

	# Speculative snapshot never mutates state or emits
	var before := grid.get_occupant_id(Vector2i(3,3))
	var snap := grid.get_speculative_snapshot([Vector2i(3,3)], [Vector2i(4,3)], Vector2i(3,3), 0)
	_check(snap["valid"] == true, "speculative snapshot reports valid")
	_check(grid.get_occupant_id(Vector2i(3,3)) == before, "speculative snapshot leaves state untouched")
