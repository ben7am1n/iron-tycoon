## GoalSystem — A4 short/mid-term goals for Achiever progression.
##
## Goal definitions are external data. Runtime state is limited to each goal's
## ACTIVE/COMPLETED/CLAIMED status, its last displayed progress, and cumulative
## positive Economy cash flow. There is no RNG: polling the same injected
## system state and replaying the same Economy/Expansion signals produces the
## same payload byte-for-byte.
class_name GoalSystem extends SimSystem

## Emitted only when a goal's visible progress or status changes.
signal goal_updated(goal: Dictionary)
## Emitted after every reward component succeeds and the goal becomes CLAIMED.
signal goal_claimed(goal_id: String, reward: Dictionary)

const SCHEMA_VERSION := 1

const STATUS_ACTIVE := "ACTIVE"
const STATUS_COMPLETED := "COMPLETED"
const STATUS_CLAIMED := "CLAIMED"

const TYPE_GUIDE := "GUIDE"
const TYPE_MILESTONE := "MILESTONE"
const TYPE_BUSINESS := "BUSINESS"
const TYPE_EXPANSION := "EXPANSION"

const METRIC_EQUIPMENT_COUNT := "EQUIPMENT_COUNT"
const METRIC_SATISFACTION := "SATISFACTION"
const METRIC_CUMULATIVE_INCOME := "CUMULATIVE_INCOME"
const METRIC_EXPANSION_COUNT := "EXPANSION_COUNT"

const VALID_TYPES := [TYPE_GUIDE, TYPE_MILESTONE, TYPE_BUSINESS, TYPE_EXPANSION]
const VALID_METRICS := [
	METRIC_EQUIPMENT_COUNT,
	METRIC_SATISFACTION,
	METRIC_CUMULATIVE_INCOME,
	METRIC_EXPANSION_COUNT,
]
const VALID_STATUSES := [STATUS_ACTIVE, STATUS_COMPLETED, STATUS_CLAIMED]

var _definitions: Array[Dictionary] = []
var _definitions_by_id: Dictionary = {}
var _states: Dictionary = {}
var _grid: Variant = null
var _satisfaction: Variant = null
var _economy: Variant = null
var _expansion: Variant = null
var _equipment_id_resolver: Callable = Callable()
var _cumulative_income: float = 0.0
var _granting_reward: bool = false


## Initializes goal definitions and injected read/write boundaries. The
## resolver maps GridSystem instance ids to equipment definition ids, allowing
## a guide to count only configured equipment types without changing GridSystem.
func init(
	config: Dictionary,
	grid: Variant,
	satisfaction: Variant,
	economy: Variant,
	expansion: Variant = null,
	equipment_id_resolver: Callable = Callable()
) -> void:
	if not _mark_initialized():
		return
	_grid = grid
	_satisfaction = satisfaction
	_economy = economy
	_expansion = expansion
	_equipment_id_resolver = equipment_id_resolver
	_definitions = _normalize_definitions(config.get("goals", []))
	for definition in _definitions:
		_definitions_by_id[str(definition["id"])] = definition
	_reset_state()


func system_name() -> String:
	return "GoalSystem"


## Reads a JSON goal catalog. Invalid roots fail closed to an empty catalog.
static func config_from_file(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		push_error("GoalSystem: config file not found: %s" % path)
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (parsed is Dictionary):
		push_error("GoalSystem: config root must be a Dictionary: %s" % path)
		return {}
	return (parsed as Dictionary).duplicate(true)


## Connects event-driven income/expansion metrics. Equipment and satisfaction
## remain tick-polled because those systems already have a deterministic fixed
## cadence and need no new cross-layer signals.
func _post_init() -> void:
	if not _assert_initialized():
		return
	if _economy != null and (_economy as Object).has_signal("balance_changed"):
		var balance_callback := Callable(self, "_on_balance_changed")
		if not (_economy as Object).is_connected("balance_changed", balance_callback):
			(_economy as Object).connect("balance_changed", balance_callback)
	if _expansion != null and (_expansion as Object).has_signal("region_unlocked"):
		var expansion_callback := Callable(self, "_on_region_unlocked")
		if not (_expansion as Object).is_connected("region_unlocked", expansion_callback):
			(_expansion as Object).connect("region_unlocked", expansion_callback)


## Fixed-tick polling entry point. tick_count is intentionally unused: every
## progress value is derived from the injected state snapshot, never from time.
func on_tick(_tick_count: int) -> void:
	if not _assert_initialized():
		return
	for definition in _definitions:
		_refresh_goal(definition)


## Returns the ordered goal list with runtime status/progress merged in.
func get_goals() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if not _assert_initialized():
		return out
	for definition in _definitions:
		out.append(_goal_view(definition))
	return out


## Returns one merged goal view, or an empty Dictionary for an unknown id.
func get_goal(goal_id: String) -> Dictionary:
	if not _assert_initialized() or not _definitions_by_id.has(goal_id):
		return {}
	return _goal_view(_definitions_by_id[goal_id])


## Selects the HUD goal deterministically: a completed/unclaimed reward takes
## priority, otherwise the first active definition in data order is shown.
func get_current_goal() -> Dictionary:
	if not _assert_initialized():
		return {}
	for definition in _definitions:
		var id := str(definition["id"])
		if str((_states[id] as Dictionary)["status"]) == STATUS_COMPLETED:
			return _goal_view(definition)
	for definition in _definitions:
		var id := str(definition["id"])
		if str((_states[id] as Dictionary)["status"]) == STATUS_ACTIVE:
			return _goal_view(definition)
	return {}


## Total positive Economy cash flow observed since the new game/save baseline.
## Starting capital and GoalSystem's own rewards are deliberately excluded.
func get_cumulative_income() -> float:
	if not _assert_initialized():
		return 0.0
	return _cumulative_income


## Claims a completed goal exactly once. Unlock rewards route through
## ExpansionSystem.grant_unlock(); money routes through Economy.credit(). The
## status changes only after all configured reward components succeed.
func claim_goal(goal_id: String) -> bool:
	if not _assert_initialized() or not _definitions_by_id.has(goal_id):
		return false
	var state: Dictionary = _states[goal_id]
	if str(state["status"]) != STATUS_COMPLETED:
		return false
	var definition: Dictionary = _definitions_by_id[goal_id]
	var reward: Dictionary = (definition["reward"] as Dictionary).duplicate(true)
	var money := int(reward.get("money", 0))
	var unlock_region := str(reward.get("unlock_region", ""))

	if money > 0 and (_economy == null or not (_economy as Object).has_method("credit")):
		return false
	if not unlock_region.is_empty() and (
		_expansion == null or not (_expansion as Object).has_method("grant_unlock")
	):
		return false

	_granting_reward = true
	var ok := true
	if not unlock_region.is_empty():
		ok = bool((_expansion as Object).call("grant_unlock", unlock_region))
	if ok and money > 0:
		ok = bool((_economy as Object).call("credit", money, "goal_reward:%s" % goal_id))
	_granting_reward = false
	if not ok:
		return false

	state["status"] = STATUS_CLAIMED
	_states[goal_id] = state
	goal_updated.emit(_goal_view(definition))
	goal_claimed.emit(goal_id, reward)
	return true


## JSON-safe persistent state. Definitions stay in data/goals.json; the save
## stores only mutable progress and cumulative income.
func serialize() -> Dictionary:
	if not _assert_initialized():
		return {"schema_version": SCHEMA_VERSION, "cumulative_income": 0, "goals": []}
	var goal_states: Array[Dictionary] = []
	for definition in _definitions:
		var id := str(definition["id"])
		var state: Dictionary = _states[id]
		goal_states.append({
			"id": id,
			"status": str(state["status"]),
			"progress": state["progress"],
		})
	return {
		"schema_version": SCHEMA_VERSION,
		"cumulative_income": _cumulative_income,
		"goals": goal_states,
	}


## Two-phase save restore. An empty payload is the optional pre-A4 state:
## every configured goal ACTIVE and cumulative income zero.
func deserialize(data: Dictionary, validate_only: bool = false) -> StubDeserializeResult:
	var result := StubDeserializeResult.new()
	if not _assert_initialized():
		result.errors.append("GoalSystem: deserialize() called before init()")
		return result
	if data.is_empty():
		if not validate_only:
			_reset_state()
		result.ok = true
		return result

	if not data.has("schema_version") or int(data.get("schema_version", -1)) != SCHEMA_VERSION:
		result.errors.append("GoalSystem: schema_version must be %d; got %s" % [
			SCHEMA_VERSION, str(data.get("schema_version", "<missing>"))
		])
	if not _is_non_negative_number(data.get("cumulative_income", null)):
		result.errors.append("GoalSystem: missing or invalid 'cumulative_income'")
	if not (data.get("goals", null) is Array):
		result.errors.append("GoalSystem: missing or invalid 'goals' array")
	if not result.errors.is_empty():
		return result

	var restored_states: Dictionary = {}
	for entry: Variant in (data["goals"] as Array):
		if not (entry is Dictionary):
			result.errors.append("GoalSystem: goal state entry is not a Dictionary")
			continue
		var record: Dictionary = entry
		var id := str(record.get("id", ""))
		var status := str(record.get("status", ""))
		var progress: Variant = record.get("progress", null)
		if id.is_empty() or not _definitions_by_id.has(id):
			result.errors.append("GoalSystem: unknown goal id '%s'" % id)
			continue
		if restored_states.has(id):
			result.errors.append("GoalSystem: duplicate goal state '%s'" % id)
			continue
		if status not in VALID_STATUSES:
			result.errors.append("GoalSystem: invalid status '%s' for goal '%s'" % [status, id])
			continue
		if not _is_non_negative_number(progress):
			result.errors.append("GoalSystem: invalid progress for goal '%s'" % id)
			continue
		restored_states[id] = {"status": status, "progress": float(progress)}

	if not result.errors.is_empty():
		return result
	result.ok = true
	if validate_only:
		return result

	_reset_state()
	_cumulative_income = float(data["cumulative_income"])
	for id: String in restored_states:
		_states[id] = restored_states[id]
	return result


func _on_balance_changed(_new_balance: int, delta: int) -> void:
	if delta <= 0 or _granting_reward:
		return
	_cumulative_income += float(delta)
	_refresh_metric(METRIC_CUMULATIVE_INCOME)


func _on_region_unlocked(_region_id: String, _cost: int, _new_dimensions: Vector2i) -> void:
	_refresh_metric(METRIC_EXPANSION_COUNT)


func _refresh_metric(metric: String) -> void:
	for definition in _definitions:
		if str(definition["metric"]) == metric:
			_refresh_goal(definition)


func _refresh_goal(definition: Dictionary) -> void:
	var id := str(definition["id"])
	var state: Dictionary = _states[id]
	if str(state["status"]) != STATUS_ACTIVE:
		return
	var target := float(definition["target"])
	var progress := minf(_read_metric(definition), target)
	var changed := not is_equal_approx(float(state["progress"]), progress)
	state["progress"] = progress
	if progress >= target:
		state["status"] = STATUS_COMPLETED
		changed = true
	_states[id] = state
	if changed:
		goal_updated.emit(_goal_view(definition))


func _read_metric(definition: Dictionary) -> float:
	match str(definition["metric"]):
		METRIC_EQUIPMENT_COUNT:
			return float(_count_equipment(definition))
		METRIC_SATISFACTION:
			if _satisfaction == null:
				return 0.0
			var value: Variant = (_satisfaction as Object).get("global_satisfaction")
			return maxf(float(value), 0.0) if value is float or value is int else 0.0
		METRIC_CUMULATIVE_INCOME:
			return _cumulative_income
		METRIC_EXPANSION_COUNT:
			if _expansion != null and (_expansion as Object).has_method("get_unlocked_count"):
				return float((_expansion as Object).call("get_unlocked_count"))
	return 0.0


func _count_equipment(definition: Dictionary) -> int:
	if _grid == null or not (_grid as Object).has_method("get_placed_instances"):
		return 0
	var allowed: Array = definition.get("equipment_ids", [])
	var count := 0
	for instance: Variant in (_grid as Object).call("get_placed_instances"):
		if allowed.is_empty():
			count += 1
			continue
		if not _equipment_id_resolver.is_valid():
			continue
		var instance_id := -1
		if instance is Dictionary:
			instance_id = int((instance as Dictionary).get("instance_id", -1))
		elif instance is Object:
			instance_id = int((instance as Object).get("instance_id"))
		if allowed.has(str(_equipment_id_resolver.call(instance_id))):
			count += 1
	return count


func _goal_view(definition: Dictionary) -> Dictionary:
	var view := definition.duplicate(true)
	var id := str(definition["id"])
	var state: Dictionary = _states[id]
	var target := float(definition["target"])
	view["status"] = str(state["status"])
	view["progress"] = float(state["progress"])
	view["progress_ratio"] = clampf(float(state["progress"]) / target, 0.0, 1.0)
	return view


func _reset_state() -> void:
	_cumulative_income = 0.0
	_states.clear()
	for definition in _definitions:
		_states[str(definition["id"])] = {"status": STATUS_ACTIVE, "progress": 0.0}


func _normalize_definitions(raw: Variant) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if not (raw is Array):
		push_error("GoalSystem: 'goals' must be an Array")
		return out
	var seen: Dictionary = {}
	for entry: Variant in (raw as Array):
		if not (entry is Dictionary):
			push_error("GoalSystem: goal entry is not a Dictionary")
			continue
		var source: Dictionary = entry
		var id := str(source.get("id", "")).strip_edges()
		var type := str(source.get("type", ""))
		var metric := str(source.get("metric", ""))
		var target: Variant = source.get("target", null)
		if id.is_empty() or seen.has(id):
			push_error("GoalSystem: goal id is empty or duplicated: '%s'" % id)
			continue
		if type not in VALID_TYPES or metric not in VALID_METRICS:
			push_error("GoalSystem: goal '%s' has invalid type/metric" % id)
			continue
		if not _is_positive_number(target):
			push_error("GoalSystem: goal '%s' target must be positive" % id)
			continue
		var reward_source: Variant = source.get("reward", {})
		if not (reward_source is Dictionary):
			push_error("GoalSystem: goal '%s' reward must be a Dictionary" % id)
			continue
		var money := int((reward_source as Dictionary).get("money", 0))
		if money < 0:
			push_error("GoalSystem: goal '%s' reward money cannot be negative" % id)
			continue
		var equipment_ids: Array[String] = []
		var raw_equipment_ids: Variant = source.get("equipment_ids", [])
		if raw_equipment_ids is Array:
			for equipment_id: Variant in (raw_equipment_ids as Array):
				equipment_ids.append(str(equipment_id))
		seen[id] = true
		out.append({
			"id": id,
			"title": str(source.get("title", id)),
			"type": type,
			"metric": metric,
			"target": float(target),
			"equipment_ids": equipment_ids,
			"reward": {
				"money": money,
				"unlock_region": str((reward_source as Dictionary).get("unlock_region", "")),
			},
		})
	return out


static func _is_positive_number(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and float(value) > 0.0


static func _is_non_negative_number(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and float(value) >= 0.0
