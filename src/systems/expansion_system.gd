## ExpansionSystem — A3 区域解锁 / 扩建（逻辑核心）.
##
## WHY THIS SYSTEM EXISTS
## The game-concept vision names one long-arc beat the MVP had no mechanism
## for: "攒够钱做一次大升级（扩建一间房 / 加一个新区域）→ 达到满意度里程碑 →
## 天然停手点". The B1 economy check (design/balance/balance-check-economy-
## 2026-08-09.md, P2) independently found the same hole from the other side —
## late-game money has no sink, so the balance drifts upward with nothing to
## spend on. One expansion purchase at $600–900 answers both.
##
## WHAT IT OWNS
##   - the ordered region table (data-driven, data/expansion.json)
##   - which regions are unlocked (the ONLY save state this system carries)
##   - the unlock gate: satisfaction milestone AND affordability
##   - the paid transaction: Economy.spend → GridSystem.resize, atomically
##
## WHAT IT DOES NOT OWN
##   - the grid's cell data (GridSystem)
##   - what a region *is* thematically — a region adds SPACE; zones are still
##     derived from the equipment placed in them (zone_rules.gd), so
##     "团课室" becomes a group-class room by what the player builds there.
##   - anything visual. A3 is the logic core; the presentation layer reads
##     GridSystem.get_dimensions() and reacts to grid_resized on its own
##     schedule (visual work is a separate task).
##
## GEOMETRY MODEL
## Regions unlock strictly in order and each one adds columns and/or rows to
## the world rectangle: dimensions = base + Σ(add_width, add_height) over the
## unlocked prefix. Sequential-prefix ordering is not decoration — it makes
## the unlocked set representable as a count, which is what keeps the save
## payload and the grid geometry impossible to desynchronise.
##
## DETERMINISM: no RNG, no tick. Every method is a pure function of config +
## unlocked prefix, except try_unlock() which is player-triggered.
class_name ExpansionSystem extends SimSystem

## Fired exactly once after a successful paid unlock, AFTER the grid has been
## resized (so a handler reading get_dimensions() sees the new world).
signal region_unlocked(region_id: String, cost: int, new_dimensions: Vector2i)

## Save payload schema version — independent of SaveLoad's blob version, same
## convention as GridSystem's records payload.
const SCHEMA_VERSION := 1

const CONFIG_SATISFACTION_THRESHOLD := "satisfaction_threshold"
const CONFIG_REGIONS := "regions"

const REGION_ID := "id"
const REGION_DISPLAY_NAME := "display_name"
const REGION_COST := "cost"
const REGION_ADD_WIDTH := "add_width"
const REGION_ADD_HEIGHT := "add_height"

## Unlock verdict codes returned by unlock_status(). Gameplay outcomes, not
## errors — the UI shows them as a disabled-button reason (same convention as
## GridSystem.can_place FAIL codes).
const STATUS_OK := "OK"
const STATUS_ALL_UNLOCKED := "ALL_REGIONS_UNLOCKED"
const STATUS_SATISFACTION_TOO_LOW := "SATISFACTION_TOO_LOW"
const STATUS_INSUFFICIENT_FUNDS := "INSUFFICIENT_FUNDS"
const STATUS_NOT_WIRED := "NOT_WIRED"

## Defensive fallback threshold. The playable build loads the authoritative
## value from data/expansion.json; tests inject the same shape directly.
## Mirrors EquipmentUpgradeSystem's config posture (A2).
const DEFAULT_SATISFACTION_THRESHOLD := 0.6

var _grid: GridSystem
var _satisfaction: Variant = null  # duck-typed: reads .global_satisfaction
var _base_dimensions: Vector2i = Vector2i.ZERO
var _satisfaction_threshold: float = DEFAULT_SATISFACTION_THRESHOLD
var _regions: Array[Dictionary] = []
var _unlocked: Array[String] = []


## Two-phase init (ADR-0001). [grid] is the geometry owner AND the source of
## the base dimensions: whatever size the level loader built is tier 0, so the
## base can never drift out of sync with a hardcoded constant.
## [satisfaction] is read-only and duck-typed (its .global_satisfaction float)
## — passing null yields a system that can never unlock, which is the correct
## safe posture for a rig that has no satisfaction meter.
func init(grid: GridSystem, config: Dictionary = {}, satisfaction: Variant = null) -> void:
	if not _mark_initialized():
		return
	_grid = grid
	_satisfaction = satisfaction
	_base_dimensions = grid.get_dimensions() if grid != null else Vector2i.ZERO
	_satisfaction_threshold = clampf(
		float(config.get(CONFIG_SATISFACTION_THRESHOLD, DEFAULT_SATISFACTION_THRESHOLD)), 0.0, 1.0
	)
	_regions = _normalize_regions(config.get(CONFIG_REGIONS, []))


func system_name() -> String:
	return "ExpansionSystem"


## Loads a JSON tuning object. Invalid/missing files fail loudly and return an
## empty dictionary, so init() falls back to "no regions configured" — an
## expansion-less but fully playable game, never a half-configured one.
static func config_from_file(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		push_error("ExpansionSystem: config file not found: %s" % path)
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (parsed is Dictionary):
		push_error("ExpansionSystem: config root must be a Dictionary: %s" % path)
		return {}
	return (parsed as Dictionary).duplicate(true)


## Validates and normalizes the raw region table. Rejected entries are dropped
## LOUDLY (push_error) rather than silently repaired — a malformed region would
## otherwise produce a world of the wrong size for the rest of the session.
## Rejection rules: non-Dictionary, empty/duplicate id, negative cost, and
## "adds nothing" (both deltas <= 0 — a region that costs money and grows the
## world by zero cells is a data bug, not a design choice).
func _normalize_regions(raw: Variant) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if not (raw is Array):
		if raw != null:
			push_error("ExpansionSystem: '%s' must be an Array." % CONFIG_REGIONS)
		return out
	var seen: Dictionary = {}
	for entry: Variant in (raw as Array):
		if not (entry is Dictionary):
			push_error("ExpansionSystem: region entry is not a Dictionary: %s" % str(entry))
			continue
		var region: Dictionary = entry
		var id := str(region.get(REGION_ID, "")).strip_edges()
		if id.is_empty():
			push_error("ExpansionSystem: region entry has no 'id' — dropped.")
			continue
		if seen.has(id):
			push_error("ExpansionSystem: duplicate region id '%s' — later entry dropped." % id)
			continue
		var cost := int(region.get(REGION_COST, 0))
		if cost < 0:
			push_error("ExpansionSystem: region '%s' has negative cost %d — dropped." % [id, cost])
			continue
		var add_width := int(region.get(REGION_ADD_WIDTH, 0))
		var add_height := int(region.get(REGION_ADD_HEIGHT, 0))
		if add_width < 0 or add_height < 0:
			push_error("ExpansionSystem: region '%s' has negative growth (%d, %d) — dropped." % [id, add_width, add_height])
			continue
		if add_width == 0 and add_height == 0:
			push_error("ExpansionSystem: region '%s' adds no space — dropped." % id)
			continue
		seen[id] = true
		out.append({
			REGION_ID: id,
			REGION_DISPLAY_NAME: str(region.get(REGION_DISPLAY_NAME, id)),
			REGION_COST: cost,
			REGION_ADD_WIDTH: add_width,
			REGION_ADD_HEIGHT: add_height,
			CONFIG_SATISFACTION_THRESHOLD: clampf(
				float(region.get(CONFIG_SATISFACTION_THRESHOLD, _satisfaction_threshold)), 0.0, 1.0
			),
		})
	return out


# === Read surface ===

## The configured region table, in unlock order. Returns copies — callers
## cannot mutate the tuning data through this.
func get_regions() -> Array[Dictionary]:
	if not _assert_initialized():
		return []
	var out: Array[Dictionary] = []
	for region in _regions:
		out.append(region.duplicate())
	return out


func get_region_count() -> int:
	if not _assert_initialized():
		return 0
	return _regions.size()


## Ids of the unlocked regions, in unlock order (a prefix of get_regions()).
func get_unlocked_ids() -> Array[String]:
	if not _assert_initialized():
		return []
	return _unlocked.duplicate()


func get_unlocked_count() -> int:
	if not _assert_initialized():
		return 0
	return _unlocked.size()


func is_unlocked(region_id: String) -> bool:
	if not _assert_initialized():
		return false
	return _unlocked.has(region_id)


## The next region the player can buy, or {} when everything is unlocked.
func get_next_region() -> Dictionary:
	if not _assert_initialized():
		return {}
	if _unlocked.size() >= _regions.size():
		return {}
	return _regions[_unlocked.size()].duplicate()


## Cost of the next region, or 0 when there is none.
func get_next_cost() -> int:
	var region := get_next_region()
	return int(region.get(REGION_COST, 0)) if not region.is_empty() else 0


## The world size at tier 0 — the dimensions the level loader built.
func get_base_dimensions() -> Vector2i:
	if not _assert_initialized():
		return Vector2i.ZERO
	return _base_dimensions


## World dimensions after unlocking the first [unlocked_count] regions.
## Out-of-range counts clamp — this is a pure geometry query, not a gate.
func dimensions_for(unlocked_count: int) -> Vector2i:
	if not _assert_initialized():
		return Vector2i.ZERO
	var dimensions := _base_dimensions
	var limit := clampi(unlocked_count, 0, _regions.size())
	for i in limit:
		dimensions.x += int(_regions[i][REGION_ADD_WIDTH])
		dimensions.y += int(_regions[i][REGION_ADD_HEIGHT])
	return dimensions


## World dimensions implied by the CURRENT unlocked set. Invariant: equals
## _grid.get_dimensions() at all times outside a load's Phase B.
func get_current_dimensions() -> Vector2i:
	return dimensions_for(get_unlocked_count())


## World dimensions implied by a SAVE PAYLOAD, without touching this system's
## state. SaveLoad calls this in its zero-mutation geometry pre-phase to learn
## what size grid the save expects before any system is committed.
## The payload must already have passed deserialize(validate_only = true).
func dimensions_for_data(data: Dictionary) -> Vector2i:
	if not _assert_initialized():
		return Vector2i.ZERO
	return dimensions_for(_unlocked_ids_from(data).size())


## Live global satisfaction, or 0.0 when no meter is wired (fails closed —
## an unwired rig can never satisfy the milestone gate).
func get_global_satisfaction() -> float:
	if not _assert_initialized() or _satisfaction == null:
		return 0.0
	var value: Variant = (_satisfaction as Object).get("global_satisfaction")
	if typeof(value) != TYPE_FLOAT and typeof(value) != TYPE_INT:
		return 0.0
	return float(value)


## The satisfaction milestone the next region requires, or 0.0 when there is
## no next region.
func get_next_threshold() -> float:
	var region := get_next_region()
	return float(region.get(CONFIG_SATISFACTION_THRESHOLD, _satisfaction_threshold)) if not region.is_empty() else 0.0


## Full unlock verdict for the next region — the single source of truth for
## both try_unlock() and any future UI affordance. Never mutates.
##
## Returns:
##   available    bool    — true only when status == STATUS_OK
##   status       String  — one of the STATUS_* codes
##   region_id    String  — "" when nothing is left to unlock
##   cost         int
##   satisfaction float   — the live value that was compared
##   threshold    float   — the milestone it was compared against
##   dimensions   Vector2i— the world size this unlock would produce
func unlock_status(economy: Variant) -> Dictionary:
	var verdict := {
		"available": false,
		"status": STATUS_ALL_UNLOCKED,
		"region_id": "",
		"cost": 0,
		"satisfaction": 0.0,
		"threshold": 0.0,
		"dimensions": Vector2i.ZERO,
	}
	if not _assert_initialized():
		verdict["status"] = STATUS_NOT_WIRED
		return verdict
	verdict["satisfaction"] = get_global_satisfaction()
	verdict["dimensions"] = get_current_dimensions()

	var region := get_next_region()
	if region.is_empty():
		return verdict

	verdict["region_id"] = str(region[REGION_ID])
	verdict["cost"] = int(region[REGION_COST])
	verdict["threshold"] = float(region[CONFIG_SATISFACTION_THRESHOLD])
	verdict["dimensions"] = dimensions_for(_unlocked.size() + 1)

	if _grid == null or economy == null or not (economy as Object).has_method("can_afford"):
		verdict["status"] = STATUS_NOT_WIRED
		return verdict

	# Milestone first, money second: the design intent is "满意度里程碑 →
	# 天然停手点", so a player who is merely rich must still earn the beat.
	# Reporting the milestone as the blocking reason (rather than the price)
	# is what makes that legible in the UI.
	if float(verdict["satisfaction"]) < float(verdict["threshold"]):
		verdict["status"] = STATUS_SATISFACTION_TOO_LOW
		return verdict

	if not bool(economy.can_afford(int(verdict["cost"]))):
		verdict["status"] = STATUS_INSUFFICIENT_FUNDS
		return verdict

	verdict["available"] = true
	verdict["status"] = STATUS_OK
	return verdict


# === Write path ===

## Player-triggered expansion purchase. Validates through unlock_status(),
## spends, then grows the grid.
##
## Atomicity: the grid write is the step that can still fail after the money
## is gone (resize() refuses to orphan placements), so a failed resize credits
## the exact amount back — the same rollback shape as
## EquipmentUpgradeSystem.try_upgrade(). Either the player has the region and
## paid for it, or has neither.
##
## Returns true only when the region is now unlocked.
func try_unlock(economy: Variant) -> bool:
	if not _assert_initialized():
		return false
	var verdict := unlock_status(economy)
	if not bool(verdict["available"]):
		return false
	if not (economy as Object).has_method("spend"):
		return false

	var region_id := str(verdict["region_id"])
	var cost := int(verdict["cost"])
	var target: Vector2i = verdict["dimensions"]

	if cost > 0 and not bool(economy.spend(cost)):
		return false

	if not _grid.resize(target.x, target.y, true):
		if cost > 0 and (economy as Object).has_method("credit"):
			economy.credit(cost, "expansion_rollback:%s" % region_id)
		push_error("ExpansionSystem: grid resize to %s failed — region '%s' not unlocked." % [target, region_id])
		return false

	_unlocked.append(region_id)
	region_unlocked.emit(region_id, cost, target)
	return true


## Reward-triggered unlock used by GoalSystem. Rewards may grant only the next
## configured region, preserving the sequential-prefix geometry invariant.
## Granting an already-unlocked id is idempotently successful so a completed
## goal remains claimable if the player bought that region before claiming.
func grant_unlock(region_id: String) -> bool:
	if not _assert_initialized():
		return false
	if is_unlocked(region_id):
		return true
	var region := get_next_region()
	if region.is_empty() or str(region[REGION_ID]) != region_id or _grid == null:
		return false
	var target := dimensions_for(_unlocked.size() + 1)
	if not _grid.resize(target.x, target.y, true):
		push_error("ExpansionSystem: reward unlock resize to %s failed for region '%s'." % [target, region_id])
		return false
	_unlocked.append(region_id)
	region_unlocked.emit(region_id, 0, target)
	return true


# === Serialization (SaveLoad contract) ===

## Save payload. The unlocked ID LIST is stored rather than a count: ids
## survive a config reorder, a count does not, and deserialize() re-derives
## the geometry from the ids anyway.
##
## Before-init safe default: a schema-versioned empty payload, matching
## GridSystem.serialize()'s posture.
func serialize() -> Dictionary:
	if not _assert_initialized():
		return {"schema_version": SCHEMA_VERSION, "unlocked": []}
	return {
		"schema_version": SCHEMA_VERSION,
		"unlocked": _unlocked.duplicate(),
	}


## Two-mode deserialization matching the Core-layer convention
## (validate_only = true → collect every error, mutate nothing).
##
## Validation rules:
##   1. schema_version exact match (MVP, no migration — ADR-0002)
##   2. 'unlocked' present and an Array of strings
##   3. every id exists in the configured region table
##   4. no duplicates
##   5. the list is a PREFIX of the region order — regions unlock
##      sequentially, so ["protein_bar"] without "group_class_room" describes
##      a world geometry this system could never have produced. Accepting it
##      would silently invent a different grid size than the save's grid
##      records were validated against.
##
## An EMPTY payload ({}) is accepted as "no regions unlocked": pre-A3 saves
## have no expansion key at all, and SaveLoad passes {} for them.
func deserialize(data: Dictionary, validate_only: bool = false) -> StubDeserializeResult:
	var result := StubDeserializeResult.new()
	if not _assert_initialized():
		result.errors.append("ExpansionSystem: deserialize() called before init()")
		return result

	if data.is_empty():
		if not validate_only:
			_unlocked = []
		result.ok = true
		return result

	if not data.has("schema_version") or int(data.get("schema_version", -1)) != SCHEMA_VERSION:
		result.errors.append("ExpansionSystem: schema_version must be %d; got %s" % [
			SCHEMA_VERSION, str(data.get("schema_version", "<missing>"))
		])
		return result

	if not data.has("unlocked") or not (data["unlocked"] is Array):
		result.errors.append("ExpansionSystem: missing or invalid 'unlocked' array")
		return result

	var ids: Array[String] = []
	var seen: Dictionary = {}
	for entry: Variant in (data["unlocked"] as Array):
		if typeof(entry) != TYPE_STRING and typeof(entry) != TYPE_STRING_NAME:
			result.errors.append("ExpansionSystem: 'unlocked' entry is not a String: %s" % str(entry))
			return result
		var id := str(entry)
		if seen.has(id):
			result.errors.append("ExpansionSystem: duplicate unlocked region '%s'" % id)
			return result
		seen[id] = true
		ids.append(id)

	if ids.size() > _regions.size():
		result.errors.append("ExpansionSystem: save unlocks %d regions but only %d are configured" % [
			ids.size(), _regions.size()
		])
		return result

	for i in ids.size():
		var expected := str(_regions[i][REGION_ID])
		if ids[i] != expected:
			result.errors.append(
				"ExpansionSystem: unlocked region %d is '%s' but regions unlock in order (expected '%s')" % [
					i, ids[i], expected
				]
			)
			return result

	if not validate_only:
		_unlocked = ids

	result.ok = true
	return result


## Extracts the unlocked ids from a payload WITHOUT validating — private
## helper for dimensions_for_data(), which documents that its input has
## already been validated.
func _unlocked_ids_from(data: Dictionary) -> Array[String]:
	var ids: Array[String] = []
	if not (data.get("unlocked", null) is Array):
		return ids
	for entry: Variant in (data["unlocked"] as Array):
		ids.append(str(entry))
	return ids


## Remaps a level's buildable mask from [from_dimensions] to [to_dimensions],
## preserving every overlapping cell and marking newly created cells buildable
## (an unlocked region is buildable ground — the same rule
## GridSystem.resize() applies to its own mask).
##
## Static and grid-free on purpose: SaveLoad must produce the expanded mask
## during its ZERO-MUTATION geometry pre-phase, before any system is allowed
## to change shape. Returns [snapshot] unchanged when its size does not match
## [from_dimensions] — GridSystem.deserialize() then reports the size mismatch
## as INTERNAL_ERROR with its existing (better) message.
static func remap_buildable_snapshot(
	snapshot: PackedByteArray, from_dimensions: Vector2i, to_dimensions: Vector2i
) -> PackedByteArray:
	if from_dimensions == to_dimensions:
		return snapshot
	if to_dimensions.x <= 0 or to_dimensions.y <= 0:
		return snapshot
	if snapshot.size() != from_dimensions.x * from_dimensions.y:
		return snapshot

	var remapped := PackedByteArray()
	remapped.resize(to_dimensions.x * to_dimensions.y)
	remapped.fill(1)
	var copy_width := mini(from_dimensions.x, to_dimensions.x)
	var copy_height := mini(from_dimensions.y, to_dimensions.y)
	for y in copy_height:
		for x in copy_width:
			remapped[y * to_dimensions.x + x] = snapshot[y * from_dimensions.x + x]
	return remapped
