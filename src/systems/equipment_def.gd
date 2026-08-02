## EquipmentDef — immutable data-transfer record for one equipment definition
## (equipment-catalog epic, Story 001; TR-EC-001; GDD Core Rule 1).
##
## Plain data object: holds no logic, performs no validation. All 12 fields
## are populated at _init() time and there are NO public setters — immutability
## is by convention (GDScript has no readonly modifier), enforced by:
##   1. no setter methods (static-code-checkable), and
##   2. defensive duplication in _init() — the instance OWNS its arrays, so a
##      caller that mutates its own scratch arrays after construction cannot
##      corrupt the record.
##
## Only canonical 0° orientation is stored (TR-EC-007 / GDD Edge Case "4 预旋转
## 变体明确禁止"): there is deliberately NO rotation field and no 90°/180°/270°
## variant arrays — 4-way rotation is GridSystem's runtime computation.
##
## unlock_requirement is a plain String (empty string = always available;
## null is NOT used) per the Story 001 implementation notes — avoids GDScript
## null-reference pitfalls.
class_name EquipmentDef extends RefCounted

## Globally unique stable identifier, immutable across saves.
var id: String

## Player-visible name (consumed by UI).
var display_name: String

## Zones this equipment belongs to (力量区/有氧区/...), consumed by ZoneRules
## for synergy. Declared as untyped Array per the Story 001 sketch; elements
## are Strings (Array[String]).
var zone_membership: Array

## Canonical (0°) footprint cells in local coordinates. One of the three
## locked shapes 1×1 / 1×2 / 2×2 (GDD Core Rule 3). Stored exactly as given —
## shape validation is the loader's job (Story 003), not this DTO's.
var footprint_cells: Array[Vector2i]

## Canonical (0°) access cells — exactly 1 cell at MVP (GDD Core Rule 4).
## Same local coordinate system as footprint_cells.
var access_cells: Array[Vector2i]

## Purchase price (Shop/Purchase consumes). Loader validates cost >= 0.
var cost: int

## Unlock requirement identifier (e.g. milestone id); empty string = always
## available. Declares the requirement only — never holds runtime unlock state.
var unlock_requirement: String

## Static effect container, Array[{tag: String, magnitude: float}]. The tag
## vocabulary is owned by ZoneRules; this DTO only locks the container shape
## (TR-EC-009).
var effects: Array[Dictionary]

## MemberSim #6 use_duration Gaussian mean (ticks, 10 tick/s). Loader
## validates > 0 (GDD Core Rule 7 (e)).
var use_duration_mean_ticks: int

## Use-duration Gaussian stddev (ticks); 0 allowed = deterministic duration.
## Loader validates >= 0 (GDD Core Rule 7 (f)).
var use_duration_stddev_ticks: int

## Use-duration clamp lower bound (ticks). Loader validates >= 1 and <= mean
## (GDD Core Rule 7 (g)).
var use_duration_min_ticks: int

## Use-duration clamp upper bound (ticks). Loader validates >= mean and
## >= min (GDD Core Rule 7 (h)).
var use_duration_max_ticks: int

func _init(
	p_id: String,
	p_display_name: String,
	p_zone_membership: Array,
	p_footprint_cells: Array[Vector2i],
	p_access_cells: Array[Vector2i],
	p_cost: int,
	p_unlock_requirement: String,
	p_effects: Array[Dictionary],
	p_use_duration_mean: int,
	p_use_duration_stddev: int,
	p_use_duration_min: int,
	p_use_duration_max: int,
) -> void:
	id = p_id
	display_name = p_display_name
	zone_membership = p_zone_membership.duplicate()  # shallow copy guard (String elements)
	footprint_cells = p_footprint_cells.duplicate()
	access_cells = p_access_cells.duplicate()
	cost = p_cost
	unlock_requirement = p_unlock_requirement
	effects = p_effects.duplicate(true)  # deep copy guard ({tag, magnitude} Dictionaries)
	use_duration_mean_ticks = p_use_duration_mean
	use_duration_stddev_ticks = p_use_duration_stddev
	use_duration_min_ticks = p_use_duration_min
	use_duration_max_ticks = p_use_duration_max


## Returns a deep copy of this definition (same field values, fully owned
## arrays). Used by EquipmentCatalog.get_definition() so callers can never
## mutate the stored record — mutating the returned copy is harmless
## (AC-IMMUTABLE.1: "deep copy or immutable-by-convention").
func duplicate_def() -> EquipmentDef:
	return EquipmentDef.new(
		id,
		display_name,
		zone_membership,
		footprint_cells,
		access_cells,
		cost,
		unlock_requirement,
		effects,
		use_duration_mean_ticks,
		use_duration_stddev_ticks,
		use_duration_min_ticks,
		use_duration_max_ticks,
	)
