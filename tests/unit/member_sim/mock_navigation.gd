# tests/unit/member_sim/mock_navigation.gd
# Story MS-004 white-box test double: a Navigation subclass whose get_path()
# counts calls (AC17 — "re-queried exactly once that tick") and can script
# results (AC18 — scripted empty for the bounded-retry exhaustion).
#
# NOT a *_test.gd file: the headless runner only registers *_test.gd under
# tests/, so this helper is never auto-run — it is load()'d by path from
# path_invalidation_test.gd.
#
# CONTRACT: MemberSim only ever calls _navigation.get_path(...), so the mock
# overrides exactly that. It never calls the base A* (init() may be skipped
# entirely — the base get_path's _assert_initialized() is bypassed by the
# override). Must be a Navigation subclass so the typed init parameter
# `navigation: Navigation` accepts it (project test contract — load by path).
extends "res://src/systems/navigation.gd"

## Number of get_path() invocations since construction / reset.
var get_path_call_count: int = 0

## When non-empty, get_path() returns this array verbatim (duplicated) —
## the scripted result. When empty (default), returns [] (scripted blocked).
var scripted_result: Array = []

## Optional real Navigation to delegate to when scripted_result is empty AND
## delegate is set. For tests that need realistic paths plus call counting.
var delegate: Object = null


func get_path(from: Vector2i, to: Vector2i) -> Array[Vector2i]:
	get_path_call_count += 1
	var out: Array[Vector2i] = []
	if not scripted_result.is_empty():
		for v in scripted_result:
			out.append(Vector2i(v))
		return out
	if delegate != null:
		return delegate.get_path(from, to)
	return out


func reset_call_count() -> void:
	get_path_call_count = 0
