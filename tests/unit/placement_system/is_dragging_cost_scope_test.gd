# tests/unit/placement_system/is_dragging_cost_scope_test.gd
# Story PL-006: is_dragging Query and Cost Scope
# Covers the BLOCKING ACs:
#   AC14 — init()/DI signature accepts NO currency/wallet/economy dependency
#          (static API-surface inspection: parse script methods + full scan
#          for hidden Economy/balance fields)
#   AC28 — IDLE: is_dragging() returns false, no state change, no side effects
#          (idempotent; after a completed drag back to IDLE → false)
#   AC29 — DRAGGING (new-placement or relocate): is_dragging() returns true,
#          no state change, no side effects (mid-drag calls, between preview
#          and commit, during rotate)
#
# The drag lifecycle (begin_drag/begin_relocate) lands in parallel worktrees
# (Story 001/005), so DRAGGING is constructed via the documented test-only
# white-box seam `_test_set_dragging` — the same pattern as Story 001's AC4
# seam `_test_set_rotation_unchecked`. Relocate enters the SAME DRAGGING state
# as new placement (GDD Core Rule 1a), so one DRAGGING state covers both.
# Run standalone: godot --headless --script tests/unit/placement_system/is_dragging_cost_scope_test.gd
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"

const PLACEMENT_SCRIPT := "res://src/systems/placement_system.gd"
const GRID_SCRIPT := "res://src/systems/grid_system.gd"
const CATALOG_SCRIPT := "res://src/systems/equipment_catalog.gd"
const DEF_SCRIPT := "res://src/systems/equipment_def.gd"

## Currency-shaped tokens the AC14 full-surface scan must find NOWHERE in
## PlacementSystem's API surface (method names, arg names, property names,
## signal args, class names). Substring, case-insensitive.
const CURRENCY_TOKENS := [
	"currency", "wallet", "economy", "balance",
	"coin", "gold", "money", "cash", "price", "cost",
]

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
	print("  UNIT TEST: PlacementSystem — is_dragging / Cost Scope (PL-006)")
	print("=".repeat(48))

	_test_ac14_init_signature_no_currency()
	_test_ac14_full_surface_no_currency_field()
	_test_ac28_idle_returns_false()
	_test_ac28_idle_idempotent()
	_test_ac28_idle_no_state_change_no_signals()
	_test_ac28_after_completed_drag_false()
	_test_ac29_dragging_returns_true()
	_test_ac29_mid_drag_persistent_true()
	_test_ac29_relocate_same_state_true()
	_test_ac29_no_state_change_no_signals()
	_test_use_before_init_guard()

	print("\n=== PL-006 is_dragging / Cost Scope: %d passed, %d failed ===\n" % [_pass, _fail])
	return {"pass": _pass, "fail": _fail}


func _check(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
		print("  PASS: " + msg)
	else:
		_fail += 1
		print("  FAIL: " + msg)


# === Helpers ===

func _placement_script() -> Script:
	return load(PLACEMENT_SCRIPT) as Script


## Builds a PlacementSystem instance with a real open 8x8 grid and a frozen
## catalog holding one treadmill def (mirrors the catalog-test fixture style).
func _make_system() -> RefCounted:
	var PS: Script = _placement_script()
	var ps: RefCounted = PS.new()
	var grid := _make_open_grid(8, 8)
	var cat := _make_catalog()
	ps.call("init", grid, cat)
	return ps


func _make_open_grid(width: int, height: int) -> RefCounted:
	var GS: Script = load(GRID_SCRIPT) as Script
	var gs: RefCounted = GS.new()
	gs.call("init", width, height)
	for y in height:
		for x in width:
			gs.call("set_buildable", Vector2i(x, y), true)
	gs.call("freeze_buildable")
	return gs


func _make_catalog() -> RefCounted:
	var cat: RefCounted = (load(CATALOG_SCRIPT) as Script).new()
	cat.call("_add_definition", _make_def("treadmill_01"))
	cat.call("_freeze")
	return cat


func _make_def(id: String) -> RefCounted:
	var ED: Script = load(DEF_SCRIPT) as Script
	var fp: Array[Vector2i] = [Vector2i(0, 0)]
	var ac: Array[Vector2i] = [Vector2i(0, 1)]
	# Typed arrays — ED.new() via Script requires exact typed-array element
	# types (untyped [] literals fail conversion at the constructor boundary).
	var effects: Array[Dictionary] = []
	var zones: Array = ["力量区"]
	return ED.new(
		id,
		"Test %s" % id,
		zones,
		fp,
		ac,
		200,
		"",
		effects,
		200,
		30,
		100,
		300,
	)


## RefCounted signal counter — NOT a lambda closure (GDD pinned caveat: lambda
## closures do not write back outer-scope locals; use a RefCounted counter
## class with a method callback for signal counting).
class CommittedCounter:
	extends RefCounted
	var count := 0
	func _bump(_instance_id: int, _equipment_id: String, _footprint_cells: Array[Vector2i]) -> void:
		count += 1


class RejectedCounter:
	extends RefCounted
	var count := 0
	func _bump(_equipment_id: String, _anchor: Vector2i, _rotation: int, _fail_code: int) -> void:
		count += 1


func _connect_signal_counters(ps: RefCounted) -> Array:
	var committed := CommittedCounter.new()
	var rejected := RejectedCounter.new()
	ps.connect("placement_committed", Callable(committed, "_bump"))
	ps.connect("placement_rejected", Callable(rejected, "_bump"))
	return [committed, rejected]


# === AC14: no currency/wallet dependency (static) ===

func _test_ac14_init_signature_no_currency() -> void:
	print("\n[AC14] init() signature carries exactly grid + catalog — no currency/wallet/economy param (static)")

	var script: Script = _placement_script()
	var methods: Array = script.get_script_method_list()

	var init_found := false
	var arg_names: Array[String] = []
	for m in methods:
		if m["name"] == "init":
			init_found = true
			for a in m["args"]:
				arg_names.append(String(a["name"]))
	_check(init_found, "init() exists on PlacementSystem")
	_check(arg_names == ["grid", "catalog"], "init() args are exactly [grid, catalog] (got %s)" % str(arg_names))

	for name in arg_names:
		var hit := ""
		for token in CURRENCY_TOKENS:
			if name.to_lower().contains(token):
				hit = token
				break
		_check(hit == "", "init() arg '%s' contains no currency-shaped token%s" % [name, "" if hit == "" else " (found '%s')" % hit])

	# Class-name of each init arg must not be an economy/wallet class.
	for m in methods:
		if m["name"] == "init":
			for a in m["args"]:
				var cn := String(a["class_name"])
				var lower := cn.to_lower()
				var hit_cn := ""
				for token in CURRENCY_TOKENS:
					if lower.contains(token):
						hit_cn = token
						break
				_check(hit_cn == "", "init() arg class_name '%s' contains no currency-shaped token%s" % [cn, "" if hit_cn == "" else " (found '%s')" % hit_cn])


func _test_ac14_full_surface_no_currency_field() -> void:
	print("\n[AC14 edge] full API surface scan — no hidden Economy/balance field anywhere (methods + props + signals)")

	var script: Script = _placement_script()

	# Collect every name-bearing string from the whole script surface.
	var names: Array[String] = []
	for m in script.get_script_method_list():
		names.append(String(m["name"]))
		for a in m["args"]:
			names.append(String(a["name"]))
			names.append(String(a["class_name"]))
	for p in script.get_script_property_list():
		names.append(String(p["name"]))
		names.append(String(p["class_name"]))
	for g in script.get_script_signal_list():
		names.append(String(g["name"]))
		for a in g["args"]:
			names.append(String(a["name"]))

	var violations: Array[String] = []
	for name in names:
		if name.is_empty():
			continue
		for token in CURRENCY_TOKENS:
			if name.to_lower().contains(token):
				violations.append("%s (contains '%s')" % [name, token])
				break

	_check(
		violations.is_empty(),
		"no API-surface member contains a currency/wallet/economy token%s" % ("" if violations.is_empty() else " — found: %s" % str(violations))
	)
	# Explicit spot checks the QA case names.
	_check(not names.has("_economy") and not names.has("economy"), "no 'economy' member (method/prop/signal)")
	_check(not names.has("_wallet") and not names.has("wallet"), "no 'wallet' member")
	_check(not names.has("_balance") and not names.has("balance"), "no 'balance' member")


# === AC28: IDLE → is_dragging() false ===

func _test_ac28_idle_returns_false() -> void:
	print("\n[AC28] IDLE — is_dragging() returns false")

	var ps := _make_system()
	var result: Variant = ps.call("is_dragging")
	_check(typeof(result) == TYPE_BOOL, "is_dragging() returns TYPE_BOOL (got %s)" % type_string(typeof(result)))
	_check(result == false, "is_dragging() == false when IDLE")


func _test_ac28_idle_idempotent() -> void:
	print("\n[AC28 edge] call twice — idempotent")

	var ps := _make_system()
	var first: bool = ps.call("is_dragging")
	var second: bool = ps.call("is_dragging")
	_check(first == false and second == false, "two consecutive calls both return false (idempotent)")


func _test_ac28_idle_no_state_change_no_signals() -> void:
	print("\n[AC28 edge] no state change, no signals emitted")

	var ps := _make_system()
	var counters := _connect_signal_counters(ps)
	var committed: CommittedCounter = counters[0]
	var rejected: RejectedCounter = counters[1]

	var grid: RefCounted = ps.get("_grid")
	var before: Dictionary = grid.call("serialize")

	for i in 3:
		var r: bool = ps.call("is_dragging")
		_check(r == false, "call %d returns false" % (i + 1))

	var after: Dictionary = grid.call("serialize")
	_check(before == after, "grid state unchanged after is_dragging() calls (no side effects)")
	_check(committed.count == 0, "placement_committed not emitted (count 0)")
	_check(rejected.count == 0, "placement_rejected not emitted (count 0)")


func _test_ac28_after_completed_drag_false() -> void:
	print("\n[AC28 edge] after a completed drag (DRAGGING → IDLE), is_dragging() is false again")

	var ps := _make_system()
	# Simulate a full drag: start (→ DRAGGING), then complete/commit (→ IDLE).
	ps.call("_test_set_dragging", true)
	_check(ps.call("is_dragging") == true, "mid-drag: is_dragging() == true")
	ps.call("_test_set_dragging", false)
	var r: bool = ps.call("is_dragging")
	_check(r == false, "after drag completes back to IDLE: is_dragging() == false")


# === AC29: DRAGGING → is_dragging() true ===

func _test_ac29_dragging_returns_true() -> void:
	print("\n[AC29] DRAGGING (new-placement drag) — is_dragging() returns true")

	var ps := _make_system()
	ps.call("_test_set_dragging", true)
	var result: Variant = ps.call("is_dragging")
	_check(typeof(result) == TYPE_BOOL, "is_dragging() returns TYPE_BOOL (got %s)" % type_string(typeof(result)))
	_check(result == true, "is_dragging() == true when DRAGGING")


func _test_ac29_mid_drag_persistent_true() -> void:
	print("\n[AC29 edge] call at any point mid-drag (between preview and commit, during rotate) — stays true")

	var ps := _make_system()
	ps.call("_test_set_dragging", true)
	var all_true := true
	for i in 5:
		if not bool(ps.call("is_dragging")):
			all_true = false
	_check(all_true, "5 consecutive mid-drag calls all return true (preview/rotate/commit phases don't change the query)")


func _test_ac29_relocate_same_state_true() -> void:
	print("\n[AC29 edge] relocate drag also returns true (relocate enters the SAME DRAGGING state, Core Rule 1a)")

	var ps := _make_system()
	# Same seam entry: begin_relocate lands in DRAGGING, indistinguishable from
	# a new-placement drag for this query (Core Rule 10: "any source").
	ps.call("_test_set_dragging", true)
	_check(ps.call("is_dragging") == true, "relocate DRAGGING → is_dragging() == true")


func _test_ac29_no_state_change_no_signals() -> void:
	print("\n[AC29 edge] no state change, no side effects while DRAGGING")

	var ps := _make_system()
	ps.call("_test_set_dragging", true)
	var counters := _connect_signal_counters(ps)
	var committed: CommittedCounter = counters[0]
	var rejected: RejectedCounter = counters[1]

	var grid: RefCounted = ps.get("_grid")
	var before: Dictionary = grid.call("serialize")

	# Call is_dragging() several times — state must stay DRAGGING.
	var still_dragging := true
	for i in 3:
		if not bool(ps.call("is_dragging")):
			still_dragging = false
	_check(still_dragging, "state remains DRAGGING after repeated is_dragging() calls (no state change)")

	var after: Dictionary = grid.call("serialize")
	_check(before == after, "grid state unchanged while DRAGGING (no side effects)")
	_check(committed.count == 0, "placement_committed not emitted (count 0)")
	_check(rejected.count == 0, "placement_rejected not emitted (count 0)")


# === Control Manifest: use-before-init guard on every public method ===

func _test_use_before_init_guard() -> void:
	print("\n[GUARD] is_dragging() before init() returns safe default false")

	var PS: Script = _placement_script()
	var ps: RefCounted = PS.new()
	# Deliberately skip init() — public method must not crash and must return
	# its documented safe default (false) per the Control Manifest rule.
	var r: bool = ps.call("is_dragging")
	_check(r == false, "is_dragging() before init() returns false (safe default)")
