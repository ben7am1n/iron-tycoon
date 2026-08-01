# tests/integration/grid_system/grid_perf_drag_smoke_test.gd
# Story 008: Signals, Integration, and Performance
# Covers AC-PERF.3 [BLOCKING]: drag-workload smoke test.
#
#   GIVEN MVP room (13×10=130 cells) with:
#     - 5-6 placed equipment
#     - 10-20 non-empty access cells scattered (~8-15% fill rate)
#     - anchor_cell varying per call along a realistic mouse trajectory
#       (NOT repeating the same delta 300 times)
#   WHEN 300 consecutive get_speculative_snapshot(deltas) calls
#        (~5s @60fps) with 1 equipment's real deltas per call,
#   THEN total < 50ms AND per-call max < 5ms
#        (first call MAY be excluded from per-call max but STILL counts
#        toward total).
#
# The threshold is deliberately loose — this is a regression alarm, not a
# performance budget (GDD H.17: "慢了 1000 倍" not "慢了 10%"). It must pass
# on the CI runner (godot --headless) and must NOT be relaxed locally.
# Run standalone: godot --headless --script tests/integration/grid_system/grid_perf_drag_smoke_test.gd
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"

# AC-PERF.3 thresholds — BLOCKING, do not relax (GDD H.17).
const MAX_TOTAL_MS := 50.0
const MAX_SINGLE_USEC := 5000  # 5ms

# Fixture constraints (GDD H.17 table — each one is load-bearing):
const GRID_W := 13
const GRID_H := 10
const CALL_COUNT := 300

var _pass := 0
var _fail := 0


## 被 tests/headless_runner.gd 托管时立即返回 —— 用例由 runner 调用的 run_all() 驱动。
## 否则 script.new() 触发的 _init() 与随后的 run_all() 会让每个用例跑两遍。
func _init() -> void:
	if Engine.has_meta(RUNNER_META):
		return
	var result := run_all()
	quit(1 if int(result["fail"]) > 0 else 0)


## 返回 {"pass": int, "fail": int} —— 见 tests/headless_runner.gd 的测试文件契约
func run_all() -> Dictionary:
	print("=".repeat(48))
	print("  INTEGRATION TEST: GridSystem — Drag Perf Smoke (Story 008)")
	print("=".repeat(48))

	_test_ac_perf_3_drag_smoke()

	print("\n=== GRID PERF DRAG SMOKE TEST: %d passed, %d failed ===\n" % [_pass, _fail])
	return {"pass": _pass, "fail": _fail}


func _check(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
		print("  PASS: " + msg)
	else:
		_fail += 1
		print("  FAIL: " + msg)


# === Helpers ===

func _make_open_grid(width: int, height: int) -> RefCounted:
	var GS: Script = load("res://src/systems/grid_system.gd") as Script
	var gs: RefCounted = GS.new()
	gs.call("init", width, height)
	for y in height:
		for x in width:
			gs.call("set_buildable", Vector2i(x, y), true)
	gs.call("freeze_buildable")
	return gs


## Builds the AC-PERF.3 background state:
##   - 6 placed equipment with multi-cell footprints
##   - 13 non-empty access cells scattered across the 130-cell room
##     (10% fill — inside the required 8-15% band)
## Returns the grid.
func _build_perf_fixture() -> RefCounted:
	var gs := _make_open_grid(GRID_W, GRID_H)

	# 6 pieces — footprints + access, deliberately NOT dense.
	# Piece 1: 2-cell footprint, 2 access cells.
	var f1: Array[Vector2i] = [Vector2i(1, 1), Vector2i(2, 1)]
	var a1: Array[Vector2i] = [Vector2i(1, 2), Vector2i(2, 2)]
	gs.call("commit", 1, f1, a1, 0)
	# Piece 2: 1-cell footprint, 1 access.
	var f2: Array[Vector2i] = [Vector2i(4, 1)]
	var a2: Array[Vector2i] = [Vector2i(4, 2)]
	gs.call("commit", 2, f2, a2, 0)
	# Piece 3: 2-cell footprint, 2 access (rotated piece).
	var f3: Array[Vector2i] = [Vector2i(6, 1), Vector2i(6, 2)]
	var a3: Array[Vector2i] = [Vector2i(7, 1), Vector2i(7, 2)]
	gs.call("commit", 3, f3, a3, 90)
	# Piece 4: 1-cell footprint, 1 access.
	var f4: Array[Vector2i] = [Vector2i(9, 1)]
	var a4: Array[Vector2i] = [Vector2i(9, 2)]
	gs.call("commit", 4, f4, a4, 0)
	# Piece 5: 3-cell footprint, 2 access.
	var f5: Array[Vector2i] = [Vector2i(11, 1), Vector2i(11, 2), Vector2i(11, 3)]
	var a5: Array[Vector2i] = [Vector2i(10, 1), Vector2i(10, 3)]
	gs.call("commit", 5, f5, a5, 0)
	# Piece 6: 2-cell footprint, 1 access (deeper in the room).
	var f6: Array[Vector2i] = [Vector2i(1, 4), Vector2i(2, 4)]
	var a6: Array[Vector2i] = [Vector2i(3, 4)]
	gs.call("commit", 6, f6, a6, 0)

	# Access cells so far: (1,2),(2,2),(4,2),(7,1),(7,2),(9,2),(10,1),
	# (10,3),(3,4) = 9. Add 4 more scattered pieces with lone access cells
	# to reach 13 non-empty access cells (10% of 130 — inside 8-15% band).
	var f7: Array[Vector2i] = [Vector2i(6, 4)]
	var a7: Array[Vector2i] = [Vector2i(7, 4)]
	gs.call("commit", 7, f7, a7, 0)
	var f8: Array[Vector2i] = [Vector2i(9, 4)]
	var a8: Array[Vector2i] = [Vector2i(10, 4)]
	gs.call("commit", 8, f8, a8, 0)
	var f9: Array[Vector2i] = [Vector2i(4, 6)]
	var a9: Array[Vector2i] = [Vector2i(5, 6)]
	gs.call("commit", 9, f9, a9, 0)
	var f10: Array[Vector2i] = [Vector2i(8, 6)]
	var a10: Array[Vector2i] = [Vector2i(9, 6)]
	gs.call("commit", 10, f10, a10, 0)

	# 10 placed equipment, 13 non-empty access cells (10% fill).
	return gs


## Generates 300 anchor cells along a realistic mouse trajectory — a
## full-room serpentine sweep (left→right across row, right→left next row,
## dropping a row each pass), covering ~all walkable cells before wrapping
## (NOT the same delta repeated 300 times, per the AC's explicit
## constraint). Consecutive anchors always differ — the anti-clause the AC
## bans is "same delta 300 times"; the room's own size caps how many
## distinct anchors a realistic in-room drag can visit.
func _trajectory_anchors(count: int) -> Array[Vector2i]:
	var anchors: Array[Vector2i] = []
	# Serpentine over columns 0..12 (13) × rows 0..8 (9) = 117 unique cells;
	# the access cell of the dragged piece sits one row below the anchor,
	# so anchor rows stay ≤ 8 to keep the access cell in bounds.
	var cols := GRID_W       # 13
	var rows := GRID_H - 1   # 9 (anchor rows 0..8)
	for i in count:
		var row := (i / cols) % rows
		var col := i % cols
		if row % 2 == 1:
			col = cols - 1 - col
		anchors.append(Vector2i(col, row))
	return anchors


## Builds the deltas for one speculative placement of the "dragged" piece —
## a 1-cell footprint + 1 access cell at the given anchor. The anchor
## changes every call (real drag trajectory).
func _delta_at(anchor: Vector2i, instance_id: int) -> PlacementDelta:
	var fp: Array[Vector2i] = [anchor]
	var ac: Array[Vector2i] = [anchor + Vector2i(0, 1)]
	return PlacementDelta.new(false, instance_id, fp, ac)


# === AC-PERF.3: 拖拽工况冒烟测试 ===

func _test_ac_perf_3_drag_smoke() -> void:
	print("\n[AC-PERF.3] 300 speculative snapshots on 13x10 grid, varying anchor — total < 50ms, per-call max < 5ms")
	print("  fixture: %dx%d, 10 placed equipment, 13 non-empty access cells (10%% fill)" % [GRID_W, GRID_H])

	var gs := _build_perf_fixture()
	var anchors := _trajectory_anchors(CALL_COUNT)
	_check(
		anchors.size() == CALL_COUNT,
		"trajectory has %d anchors" % CALL_COUNT
	)
	# Verify the trajectory actually varies (AC's anti-clause: NOT the same
	# delta 300 times). Bar: no consecutive repeats AND broad coverage —
	# the serpentine covers 117 of the 130 cells, so a well-varied
	# trajectory must have far more distinct anchors than repeated ones.
	var distinct: Dictionary = {}
	var consecutive_repeats := 0
	for i in anchors.size():
		distinct[anchors[i]] = true
		if i > 0 and anchors[i] == anchors[i - 1]:
			consecutive_repeats += 1
	_check(
		distinct.size() >= 100,
		"anchor varies along the trajectory — %d distinct anchors out of %d (full-room serpentine)" % [distinct.size(), CALL_COUNT]
	)
	_check(
		consecutive_repeats == 0,
		"no two consecutive calls use the same delta — consecutive_repeats=%d (anti: same delta 300x)" % consecutive_repeats
	)

	var timer := Time.get_ticks_usec()
	var max_single_usec := 0
	var first_call_usec := 0
	var sanity_failures := 0

	for i in CALL_COUNT:
		var delta := _delta_at(anchors[i], 900 + i)
		var deltas: Array[PlacementDelta] = [delta]
		var call_start := Time.get_ticks_usec()
		var snap: RefCounted = gs.call("get_speculative_snapshot", deltas)
		var call_usec := Time.get_ticks_usec() - call_start
		if i == 0:
			first_call_usec = call_usec
		else:
			max_single_usec = max(max_single_usec, call_usec)
		# Sanity: the snapshot reflects the speculative delta (a 1-cell
		# footprint at the anchor) — prevents a degenerate fast path that
		# skips the actual work.
		if snap == null or snap.call("is_solid", anchors[i]) != true:
			sanity_failures += 1

	_check(
		sanity_failures == 0,
		"all %d snapshots reflect their delta — no degenerate fast path (sanity failures=%d)" % [CALL_COUNT, sanity_failures]
	)

	var total_usec := Time.get_ticks_usec() - timer
	var total_ms := total_usec / 1000.0

	print("  total=%dus (%.2fms) | first=%dus | max_single=%dus" % [total_usec, total_ms, first_call_usec, max_single_usec])

	_check(
		total_ms < MAX_TOTAL_MS,
		"300 speculative snapshots took %.2fms total < %.1fms (AC-PERF.3)" % [total_ms, MAX_TOTAL_MS]
	)
	_check(
		max_single_usec < MAX_SINGLE_USEC,
		"per-call max %dus < 5000us (5ms) — first call excluded, still counts toward total" % max_single_usec
	)
	# First call DOES count toward total — the total assertion already
	# includes it. This check documents that the exclusion only applies to
	# the per-call max.
	_check(
		first_call_usec <= total_usec,
		"first call (%dus) included in the total (%dus) — exclusion applies to per-call max only" % [first_call_usec, total_usec]
	)
