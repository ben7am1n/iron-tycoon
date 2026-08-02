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
# Not a _test.gd file — it is a helper loaded by the zone_rules tests and
# must NOT be registered in headless_runner.gd TEST_FILES (same pattern as
# commit_spy_grid.gd and the *_probe.gd subprocess helpers elsewhere).
extends "res://src/systems/grid_state_reader.gd"

## The placed-instance list get_placed_instances() returns. Tests assign this
## directly (plain test stub — no init machinery, no two-phase lifecycle).
var placed_instances: Array[PlacedInstance] = []


func get_placed_instances() -> Array[PlacedInstance]:
	return placed_instances
