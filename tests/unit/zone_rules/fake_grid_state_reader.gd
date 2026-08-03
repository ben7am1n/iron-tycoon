# tests/unit/zone_rules/fake_grid_state_reader.gd
# Test-only GridStateReader stub for the zone-rules epic (Story 001+).
#
# Returns a settable placed-instance list and nothing else — the story's
# required fake-GridStateReader test approach: constructing a real grid +
# placement stack is too heavy for pure-function unit tests. The stub never
# fires the base class's not-overridden push_error() guards because the only
# read method ZoneRules.evaluate() touches in Story 001 is
# get_placed_instances(); is_solid()/get_dimensions() arrive with the
# spaciousness story (ZR-003) and this stub will grow then.
#
# ZR-003 (spaciousness) growth: the stub now also answers is_solid() and
# get_dimensions() from two settable fields — grid_dimensions and
# solid_cells. DEFAULT is a zero-size grid (every cell out-of-bounds), which
# makes spaciousness compute 0.0 for fixtures that never set dimensions —
# exactly the Story-001 placeholder behavior, so the purity tests' fixtures
# (which don't set dimensions) keep passing unchanged. Spaciousness
# fixtures set grid_dimensions explicitly and mark solid cells via
# solid_cells.
#
# Not a _test.gd file — it is a helper loaded by the zone_rules tests and
# must NOT be registered in headless_runner.gd TEST_FILES (same pattern as
# commit_spy_grid.gd and the *_probe.gd subprocess helpers elsewhere).
extends "res://src/systems/grid_state_reader.gd"

## The placed-instance list get_placed_instances() returns. Tests assign this
## directly (plain test stub — no init machinery, no two-phase lifecycle).
var placed_instances: Array[PlacedInstance] = []

## Grid size get_dimensions() reports. Default Vector2i.ZERO: every cell is
## out-of-bounds, so spaciousness computes 0.0 (Story-001 placeholder
## behavior preserved for fixtures that don't set dimensions).
var grid_dimensions: Vector2i = Vector2i.ZERO

## Cells is_solid() reports as solid (static solidity: walls + placed
## footprints). Tests assign this directly. Keys are Vector2i; a missing key
## means "not solid" (open).
var solid_cells: Dictionary = {}


func get_placed_instances() -> Array[PlacedInstance]:
	return placed_instances


func get_dimensions() -> Vector2i:
	return grid_dimensions


func is_solid(cell: Vector2i) -> bool:
	return solid_cells.has(cell)
