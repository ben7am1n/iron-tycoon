# Test-only GridSystem subclass that records every commit() call and exposes a
# "commit returned" flag, so commit_success_test.gd can assert:
#   - AC6:  commit(id, def, anchor, rotation) called exactly once with the
#           exact args PlacementSystem computed
#   - AC21: placement_committed fires only AFTER GridSystem.commit() returns
#           (commit_returned is false while commit() is mid-flight, true after
#           super.commit() completes)
#
# Not a _test.gd file — it is a helper loaded by commit_success_test.gd and
# must NOT be registered in headless_runner.gd TEST_FILES (same pattern as the
# *_probe.gd subprocess helpers elsewhere in tests/).
extends "res://src/systems/grid_system.gd"

var commit_calls: Array = []
var commit_entered: bool = false
var commit_returned: bool = false


func commit(instance_id: int, footprint_cells: Array[Vector2i], access_cells: Array[Vector2i], rotation: Rotation) -> void:
	commit_entered = true
	commit_returned = false
	commit_calls.append({
		"instance_id": instance_id,
		"footprint_cells": footprint_cells.duplicate(),
		"access_cells": access_cells.duplicate(),
		"rotation": rotation,
	})
	super.commit(instance_id, footprint_cells, access_cells, rotation)
	commit_returned = true
