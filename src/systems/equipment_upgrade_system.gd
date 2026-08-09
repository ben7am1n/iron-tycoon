## EquipmentUpgradeSystem — deterministic A2 upgrade formulas and transaction.
##
## Runtime level state is owned by each GridSystem PlacementRecord so it
## naturally follows placement serialization. This service owns no save state;
## it centralizes cost/effect formulas and performs the player-triggered
## Economy.spend + level update transaction.
class_name EquipmentUpgradeSystem extends SimSystem

## Fired exactly once after a successful paid upgrade.
signal equipment_upgraded(instance_id: int, old_level: int, new_level: int, cost: int)

const CONFIG_MAX_LEVEL := "max_level"
const CONFIG_BASE_COST_RATIO := "base_cost_ratio"
const CONFIG_COST_GROWTH := "cost_growth"
const CONFIG_ATTRACTION_PER_LEVEL := "attraction_per_level"
const CONFIG_REVENUE_PER_LEVEL := "revenue_per_level"

# Defensive fallbacks. The playable build loads the authoritative values from
# data/equipment_upgrades.json; tests inject the same shape directly.
const DEFAULT_MAX_LEVEL := 5
const DEFAULT_BASE_COST_RATIO := 0.25
const DEFAULT_COST_GROWTH := 1.5
const DEFAULT_ATTRACTION_PER_LEVEL := 0.15
const DEFAULT_REVENUE_PER_LEVEL := 0.1667

var _grid: GridSystem
var _max_level: int = DEFAULT_MAX_LEVEL
var _base_cost_ratio: float = DEFAULT_BASE_COST_RATIO
var _cost_growth: float = DEFAULT_COST_GROWTH
var _attraction_per_level: float = DEFAULT_ATTRACTION_PER_LEVEL
var _revenue_per_level: float = DEFAULT_REVENUE_PER_LEVEL


## Initializes the stateless upgrade service with the instance-state owner and
## a data-driven tuning dictionary.
func init(grid: GridSystem, config: Dictionary = {}) -> void:
	if not _mark_initialized():
		return
	_grid = grid
	_max_level = clampi(int(config.get(CONFIG_MAX_LEVEL, _max_level)), 1, 10)
	_base_cost_ratio = clampf(float(config.get(CONFIG_BASE_COST_RATIO, _base_cost_ratio)), 0.01, 10.0)
	_cost_growth = clampf(float(config.get(CONFIG_COST_GROWTH, _cost_growth)), 1.0, 10.0)
	_attraction_per_level = clampf(float(config.get(CONFIG_ATTRACTION_PER_LEVEL, _attraction_per_level)), 0.0, 1.0)
	_revenue_per_level = clampf(float(config.get(CONFIG_REVENUE_PER_LEVEL, _revenue_per_level)), 0.0, 1.0)


func system_name() -> String:
	return "EquipmentUpgradeSystem"


## Loads a JSON tuning object. Invalid/missing files fail loudly and return an
## empty dictionary, causing init() to use its documented fallback anchors.
static func config_from_file(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		push_error("EquipmentUpgradeSystem: config file not found: %s" % path)
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (parsed is Dictionary):
		push_error("EquipmentUpgradeSystem: config root must be a Dictionary: %s" % path)
		return {}
	return (parsed as Dictionary).duplicate(true)


## Returns the configured maximum equipment level.
func get_max_level() -> int:
	if not _assert_initialized():
		return 1
	return _max_level


## Returns a placed instance's current level, or neutral level 1 for an
## unknown id.
func get_level(instance_id: int) -> int:
	if not _assert_initialized() or _grid == null:
		return 1
	return _grid.get_equipment_level(instance_id)


## Cost to upgrade from [current_level] to the next level:
## round(purchase_cost × base_cost_ratio × cost_growth^(level-1)).
## Returns 0 at/above max level or for an invalid purchase cost.
func upgrade_cost_for_level(purchase_cost: int, current_level: int) -> int:
	if not _assert_initialized():
		return 0
	if purchase_cost <= 0 or current_level < 1 or current_level >= _max_level:
		return 0
	var raw := float(purchase_cost) * _base_cost_ratio * pow(_cost_growth, current_level - 1)
	return maxi(1, int(round(raw)))


## Returns the next upgrade cost for a placed instance.
func get_upgrade_cost(instance_id: int, purchase_cost: int) -> int:
	if not _assert_initialized() or _grid == null:
		return 0
	if not _has_instance(instance_id):
		return 0
	return upgrade_cost_for_level(purchase_cost, get_level(instance_id))


## Attraction multiplier: 1 + 0.15 × (level-1) with default tuning.
func attraction_multiplier_for_level(level: int) -> float:
	if not _assert_initialized():
		return 1.0
	return 1.0 + _attraction_per_level * float(maxi(level, 1) - 1)


## Revenue multiplier: 1 + 0.1667 × (level-1) with default tuning.
func revenue_multiplier_for_level(level: int) -> float:
	if not _assert_initialized():
		return 1.0
	return 1.0 + _revenue_per_level * float(maxi(level, 1) - 1)


## Integer completed-visit revenue after applying a snapshotted level.
func revenue_for_visit(base_revenue: int, level: int) -> int:
	if not _assert_initialized():
		return base_revenue
	return revenue_for_visit_multiplier(base_revenue, revenue_multiplier_for_level(level))


## Integer completed-visit revenue using a multiplier already averaged and
## snapshotted by MemberSim across the visit's successfully completed uses.
func revenue_for_visit_multiplier(base_revenue: int, average_multiplier: float) -> int:
	if not _assert_initialized():
		return base_revenue
	return maxi(0, int(round(float(base_revenue) * maxf(average_multiplier, 0.0))))


## Player-triggered deterministic upgrade transaction. The method validates
## instance/cost/level and affordability before spending. If the impossible
## post-spend Grid write fails, the exact amount is credited back so final
## state remains atomic.
func try_upgrade(instance_id: int, purchase_cost: int, economy: Variant) -> bool:
	if not _assert_initialized() or _grid == null or economy == null:
		return false
	if not _has_instance(instance_id):
		return false
	var old_level := get_level(instance_id)
	var cost := upgrade_cost_for_level(purchase_cost, old_level)
	if cost <= 0 or not economy.has_method("can_afford") or not economy.has_method("spend"):
		return false
	if not bool(economy.can_afford(cost)):
		return false
	if not bool(economy.spend(cost)):
		return false
	var new_level := old_level + 1
	if not _grid.set_equipment_level(instance_id, new_level):
		if economy.has_method("credit"):
			economy.credit(cost, "upgrade_rollback:instance_%d" % instance_id)
		return false
	equipment_upgraded.emit(instance_id, old_level, new_level, cost)
	return true


func _has_instance(instance_id: int) -> bool:
	for placed in _grid.get_placed_instances():
		if int(placed.instance_id) == instance_id:
			return true
	return false
