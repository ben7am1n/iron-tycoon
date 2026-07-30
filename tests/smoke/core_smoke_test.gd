# tests/smoke/core_smoke_test.gd
# 迁自 prototypes/gym-flow-vertical-slice/src/core/smoke_test.gd
# 覆盖：GridSystem + SeededRNG 基础正确性
# Run: godot --headless --script tests/smoke/core_smoke_test.gd
extends SceneTree

const SEEDED_RNG := preload("res://prototypes/gym-flow-vertical-slice/src/core/seeded_rng.gd")
const GRID_SYSTEM := preload("res://prototypes/gym-flow-vertical-slice/src/core/grid_system.gd")

var _pass := 0
var _fail := 0


class SignalCounter extends RefCounted:
	var count := 0

	func on_changed(_f: Array, _a: Array) -> void:
		count += 1


func _init() -> void:
	print("=".repeat(48))
	print("  SMOKE TEST: GridSystem + SeededRNG")
	print("=".repeat(48))
	_test_rng()
	_test_grid()
	print("\n=== SMOKE TEST: %d passed, %d failed ===" % [_pass, _fail])
	quit(_fail > 0)


func run_all() -> bool:
	_init()
	return _fail == 0


func _check(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
		print("  PASS: " + msg)
	else:
		_fail += 1
		print("  FAIL: " + msg)


func _test_rng() -> void:
	print("\n[SeededRNG]")

	var r1 := SEEDED_RNG.new(12345)
	var r2 := SEEDED_RNG.new(12345)

	_check(
		r1.get_sub_seed("MemberSim") == r2.get_sub_seed("MemberSim"),
		"same master+name → identical sub_seed"
	)
	_check(
		r1.get_sub_seed("MemberSim") != r1.get_sub_seed("Congestion"),
		"different names → different sub_seeds"
	)

	var a := SEEDED_RNG.new(999)
	var b := SEEDED_RNG.new(1000)
	_check(
		a.get_sub_seed("MemberSim") != b.get_sub_seed("MemberSim"),
		"different master_seed → different sub_seeds"
	)

	var rng_a := r1.get_rng("MemberSim")
	var rng_b := r2.get_rng("MemberSim")
	var seq_match := true
	for _i in 100:
		if rng_a.randf() != rng_b.randf():
			seq_match = false
			break
	_check(seq_match, "100-draw RNG stream bit-identical across two instances")


func _test_grid() -> void:
	print("\n[GridSystem]")

	var region := Rect2i(0, 0, 13, 10)
	var buildable: Dictionary = {}
	for x in range(13):
		for y in range(10):
			buildable[Vector2i(x, y)] = true

	var grid := GRID_SYSTEM.new(region, buildable)

	_check(grid.is_solid(Vector2i(-1, 0)), "out-of-bounds cell is solid")
	_check(not grid.is_solid(Vector2i(2, 2)), "empty buildable cell is not solid")
	_check(grid.is_solid(Vector2i(13, 0)), "beyond-width cell is solid")

	var fp := [Vector2i(0, 0), Vector2i(1, 0)]
	var ac := [Vector2i(2, 0)]
	_check(grid.commit(1, fp, ac, Vector2i(0, 0), 0), "first commit succeeds")
	_check(grid.is_solid(Vector2i(0, 0)), "occupied footprint cell is solid")
	_check(not grid.is_solid(Vector2i(2, 0)), "access-only cell is NOT solid (no member trap)")
	_check(not grid.can_place(fp, ac, Vector2i(0, 0), 0), "overlap commit rejected by can_place")
	_check(not grid.commit(1, fp, ac, Vector2i(0, 0), 0), "duplicate id commit rejected")

	# 最高危规则: union bbox (W=3,H=1) for footprint(0,0),(1,0)+access(2,0)
	# 90°: (x,y)→(H-1-y, x) = (0-y, x). anchor(5,5) → access at (5,7), not (7,5)
	grid.clear(1)
	_check(grid.commit(2, fp, ac, Vector2i(5, 5), 90), "rotated commit succeeds")

	var rec: Dictionary = grid._instances[2]
	_check(
		rec["access"].has(Vector2i(5, 7)),
		"rotation uses UNION bbox (access at (5,7), not (7,5))"
	)
	_check(
		not rec["access"].has(Vector2i(7, 5)),
		"rotation does NOT use footprint-local bbox"
	)

	var fp_oob := [Vector2i(12, 9), Vector2i(13, 9)]
	var ac_oob := [Vector2i(14, 9)]
	_check(
		not grid.can_place(fp_oob, ac_oob, Vector2i(12, 9), 0),
		"out-of-bounds placement rejected"
	)

	# grid_changed fires exactly once per commit / clear
	var sc := SignalCounter.new()
	grid.grid_changed.connect(sc.on_changed)
	_check(grid.commit(3, [Vector2i(0, 0)], [Vector2i(1, 0)], Vector2i(8, 8), 0), "commit(3) at empty cells succeeds")
	_check(sc.count == 1, "grid_changed fires exactly once per commit")
	grid.clear(3)
	_check(sc.count == 2, "grid_changed fires once on clear too")

	# Speculative snapshot never mutates state or emits
	var before := grid.get_occupant_id(Vector2i(3, 3))
	var snap := grid.get_speculative_snapshot([Vector2i(3, 3)], [Vector2i(4, 3)], Vector2i(3, 3), 0)
	_check(snap["valid"], "speculative snapshot reports valid")
	_check(grid.get_occupant_id(Vector2i(3, 3)) == before, "speculative snapshot leaves state untouched")
