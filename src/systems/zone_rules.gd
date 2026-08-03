## ZoneRules — stateless pure function scoring the static quality of a placed
## layout (zone-rules epic, Stories 001+002+003+004; TR-ZR-001..007; GDD
## Core Rules 1/3/4/5/6/7/8).
##
## Sole entry point: evaluate(snapshot, catalog) -> Dictionary. It reads ONLY
## the GridStateReader read contract (get_placed_instances) and the injected
## immutable EquipmentCatalog (get_definition). It holds no mutable state,
## performs no RNG, and never reads live member crowding data — the static /
## dynamic split is deliberate: this system measures the geometry of the
## layout, the dynamic half belongs to a separate system.
##
## STATELESS (ADR-0001 stateless-systems exception): this class extends
## RefCounted directly with NO SimSystem init machinery and NO fields — the
## snapshot AND the catalog arrive as call parameters (EPIC.md). Same input
## always produces bit-identical output (AC1); preview==commit equivalence
## (AC2, Story 004) falls out of this purity: a speculative GridSnapshot
## scores identically to the committed layout it predicts.
##
## INVALID EQUIPMENT (Story 004, AC15a/15b, GDD Edge Cases): an instance
## whose equipment_id has no catalog definition (stale/corrupt type id) is an
## upstream invariant violation, NOT a ZoneRules bug. It contributes
## comfort=0 and zone_synergy=0 for itself, is excluded from neighbors'
## n_same (its zone membership is empty), and its spaciousness is still
## computed geometrically. The anomaly is signaled through an INJECTED
## channel — config keys CONFIG_STRICT_MODE / CONFIG_ON_INVALID_EQUIPMENT,
## mirroring EquipmentCatalog's injectable strict_mode pattern — never a
## bare assert() (a bare assert is a no-op in release and untestable in
## headless CI). strict_mode=false returns normally with zeroed rows and the
## callback fired once per offender; strict_mode=true returns a structured
## error (see _invalid_equipment_error).
##
## EFFECT VOCABULARY (Core Rule 4, TR-ZR-003): exactly one catalog-authored
## input tag — `comfort`, read from the def's `effects` container (authored
## range [0.0, 1.0]). The other two tags are ZoneRules-computed outputs and
## are NEVER authored in the catalog:
##   - zone_synergy: computed output — Story 002 formula (Core Rules 5/6,
##     TR-ZR-004/006): S_max × (1 − e^(−k × r_i)), r_i = n_same_i / N_max_i
##   - spaciousness: computed output — Story 003 formula (implemented here):
##     C_max × (open_adj_i / total_adj_i)
## All three are non-negative by construction — this system never subtracts;
## a poor layout earns 0 on a tag, it is never punished (Pillar 2 enforced
## at the vocabulary level, not by a downstream clamp).
##
## ZONE SYNERGY (Core Rules 5/6, TR-ZR-004/006, Story 002):
##   - Same-zone iff two defs share ≥ 1 zone (OR-match — AC9). Equipment with
##     empty zone_membership never earns synergy and is never counted as a
##     same-zone neighbor (Core Rule 5).
##   - Adjacency is orthogonal edge-sharing only between footprint cells —
##     diagonal (corner-only) touching is NOT adjacency (AC3, TR-ZR-006).
##   - n_same_i counts DISTINCT neighboring instances, not shared edges
##     (AC5). N_max_i is the distinct orthogonal perimeter cell count of the
##     footprint, excluding own cells (1×1 → 4, 2×2 → 8).
##   - r_i = n_same_i / N_max_i; the perimeter normalization makes every
##     footprint size earn the same synergy at the same proportion of
##     zone-cohesive neighbors (AC4b).
##   - S_max and k are provisional MVP anchors (GDD Formulas — playtest
##     tuning); the optional [config] parameter overrides them via the
##     data-driven seam, mirroring the Economy pattern (ECON-001).
##   - Output is [0, S_max) — asymptotic, never reaches S_max (AC4:
##     r=1.0 → 1 − e^(−2.4) ≈ 0.909 < 1.0).
##
## OUTPUT SHAPE (Core Rule 7, AC14): Dictionary[instance_id -> {comfort,
## zone_synergy, spaciousness, total}], where total = comfort + zone_synergy +
## spaciousness (a pure sum of non-negative terms). The optional
## layout_summary convenience field is intentionally NOT emitted by this
## story — it is not the primary interface.
##
## DETERMINISM (Core Rule 8, AC16): iteration over placed instances runs in
## ascending instance_id order. Dictionary preserves insertion order but does
## NOT auto-sort — the implementation sorts explicitly.
##
## SERIALIZATION: none (TR-ZR-007, ADR-0002) — a pure function contributes
## nothing to the save file.
class_name ZoneRules extends RefCounted

## Provisional MVP anchors (GDD Formulas — playtest tuning): the saturation
## ceiling and the growth rate of the zone_synergy curve.
const S_MAX := 1.0
const K := 2.4

## Data-driven config seam (coding standard: gameplay values never
## hardcoded). evaluate() reads these keys from the optional [config]
## Dictionary; absent keys fall back to the GDD anchors above. Mirrors the
## Economy init(config) seam — ZoneRules is a pure function with no init, so
## the seam rides the evaluate() call instead.
const CONFIG_S_MAX := "zone_synergy_s_max"
const CONFIG_K := "zone_synergy_k"

## Spaciousness ceiling C_max (GDD Formulas / Tuning Knobs — provisional MVP
## anchor; safe range 0.3–0.8). spaciousness_i = C_max × (open_adj_i /
## total_adj_i), clamped to [0, C_max] by construction: open_adj_i ≤
## total_adj_i, and total_adj_i == 0 → 0.0 (AC7 guard).
const C_MAX_SPACIOUSNESS := 0.5

## The four orthogonal neighbor offsets (共边 adjacency — diagonal never
## counts, consistent with the no-corner-cut movement rule, Core Rule 6).
const ORTHOGONAL_DIRS: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
]

## Invalid-equipment channel (Story 004, AC15a/15b, GDD Edge Cases — mirrors
## EquipmentCatalog's injectable strict_mode pattern). evaluate() reads these
## keys from the optional [config] Dictionary; absent keys keep the
## pure-function defaults (lenient + silent, exactly the ZR-001..003
## behavior). No bare assert() anywhere: a bare assert is a no-op in release
## and cannot be tested in headless CI, so both branches ride the injected
## channel instead.
const CONFIG_STRICT_MODE := "strict_mode"
const CONFIG_ON_INVALID_EQUIPMENT := "on_invalid_equipment"

## Structured-error kind emitted when strict_mode=true aborts evaluation
## (AC15b). The error shape is a return-type variant (OQ4-sanctioned):
## {"error": {"kind": ..., "offenders": [{"instance_id", "equipment_id"}, ...]}}
## — a normal result never carries an "error" key (its keys are int
## instance_ids), so a test harness can distinguish the two shapes
## deterministically without stderr capture, exit code, or assert().
const ERROR_KIND_INVALID_EQUIPMENT := "invalid_equipment"


## Sole entry point — scores every placed instance in [snapshot].
##
## Reads ONLY [snapshot].get_placed_instances() and the EquipmentCatalog
## existence/read pair — [catalog].has_definition(id) (silent invalid-id
## probe, Story 004) and [catalog].get_definition(id) — no other API (AC13
## static-only guarantee: this file references no single-cell occupancy /
## access lookup and no live data accessor). Both inputs are treated as
## immutable; the function owns no state, so repeated calls on the same
## inputs are bit-identical (AC1).
##
## PREVIEW == COMMIT (Core Rule 2, AC2): the snapshot parameter is typed to
## the abstract GridStateReader, so evaluate() cannot tell a real committed
## grid from a speculative GridSnapshot — it scores whichever instance set
## the snapshot reports. A speculative snapshot containing hypothetical
## piece X (stable provisional instance_id P, its equipment_id carried
## through the snapshot) therefore scores bit-identically to the real
## snapshot after X is committed (same resulting instance set).
##
## [config] is an optional data-driven seam (Stories 002+004):
##   - keys CONFIG_S_MAX / CONFIG_K override the GDD anchors (Story 002);
##   - key CONFIG_STRICT_MODE (bool, default false) + key
##     CONFIG_ON_INVALID_EQUIPMENT (Callable(instance_id, equipment_id))
##     form the injected invalid-equipment channel (Story 004, AC15a/15b).
## The default empty Dictionary keeps the pure-function signature backward
## compatible — existing two-argument callers are unaffected (AC1/AC2 hold
## for the default config).
func evaluate(snapshot: GridStateReader, catalog: EquipmentCatalog, config: Dictionary = {}) -> Dictionary:
	var instances: Array[PlacedInstance] = snapshot.get_placed_instances()
	if instances.is_empty():
		# AC11 — an empty layout returns an empty Dictionary, no error.
		return {}
	# AC16 — work on an owned copy so the snapshot's array is never mutated
	# (purity: evaluate() has no side effects on its inputs), then sort in
	# ascending instance_id order.
	var sorted: Array[PlacedInstance] = []
	sorted.assign(instances)
	sorted.sort_custom(func(a: PlacedInstance, b: PlacedInstance) -> bool: return a.instance_id < b.instance_id)

	var s_max: float = float(config.get(CONFIG_S_MAX, S_MAX))
	var k: float = float(config.get(CONFIG_K, K))

	# Story 004 — invalid-equipment channel (AC15a/15b, GDD Edge Cases). An
	# instance whose equipment_id has no catalog definition is an upstream
	# invariant violation (PlacementSystem committed a type not in the
	# Catalog), not a ZoneRules bug: it contributes comfort=0 and
	# zone_synergy=0 for itself (empty zone membership → never a same-zone
	# neighbor), its spaciousness is still computed geometrically, and the
	# anomaly is signaled through the INJECTED channel — never a bare
	# assert(). Detection iterates in ascending instance_id order (Core Rule
	# 8) so the callback fires in a fixed, deterministic sequence.
	var strict_mode: bool = bool(config.get(CONFIG_STRICT_MODE, false))
	var on_invalid: Callable = config.get(CONFIG_ON_INVALID_EQUIPMENT, Callable()) as Callable
	var offenders: Array[Dictionary] = []
	# Precompute per-equipment validity ONCE: has_definition() is the SILENT
	# existence probe — get_definition() push_errors on a missing id, which
	# would leak the anomaly to stderr and defeat the "deterministically
	# observable without stderr" requirement (AC15b). Detection and the
	# later catalog reads all consult this table, so the anomaly is
	# observable ONLY through the injected channel.
	var valid_equipment := {}
	for inst in sorted:
		var valid: bool = catalog.has_definition(inst.equipment_id)
		valid_equipment[inst.equipment_id] = valid
		if not valid:
			offenders.append({
				"instance_id": inst.instance_id,
				"equipment_id": inst.equipment_id,
			})
			if on_invalid.is_valid():
				on_invalid.call(inst.instance_id, inst.equipment_id)

	# AC15b — strict_mode=true does NOT return a normal result. The injected
	# channel captures the structured error via the return-type variant
	# (OQ4): {"error": {kind, offenders}} — deterministically observable by
	# a test harness without stderr / exit-code / assert. Lenient mode
	# (strict_mode absent/false) falls through and returns the normal
	# per-instance dict with the invalid rows zeroed (AC15a).
	if strict_mode and not offenders.is_empty():
		return _invalid_equipment_error(offenders)

	# Precompute the per-instance zone membership and perimeter capacity ONCE:
	# catalog lookups return deep copies (EquipmentCatalog defensive posture)
	# and the perimeter scan is O(footprint × 4) — neither belongs in the
	# per-pair inner loop of _compute_zone_synergy.
	var zone_membership := {}
	var n_max := {}
	for inst in sorted:
		zone_membership[inst.instance_id] = _read_zone_membership(catalog, inst.equipment_id, valid_equipment)
		n_max[inst.instance_id] = _perimeter_cell_count(inst.footprint_cells)

	var result := {}
	for inst in sorted:
		var comfort: float = _read_comfort(catalog, inst.equipment_id, valid_equipment)
		var zone_synergy: float = _compute_zone_synergy(inst, sorted, zone_membership, n_max, s_max, k)
		# Story 003 owns the spaciousness formula — C_max × (open_adj / total_adj).
		var spaciousness := _compute_spaciousness(snapshot, inst)
		result[inst.instance_id] = {
			"comfort": comfort,
			"zone_synergy": zone_synergy,
			"spaciousness": spaciousness,
			"total": comfort + zone_synergy + spaciousness,
		}
	return result


## Builds the structured-error Dictionary returned by strict_mode=true when
## at least one instance has an equipment_id with no catalog definition
## (AC15b). [offenders] is the ascending-instance_id list of
## {"instance_id", "equipment_id"} pairs. Shape:
##   {"error": {"kind": "invalid_equipment", "offenders": [...]}}
## A normal result's keys are int instance_ids, so the "error" string key is
## unambiguous — a test harness asserts result.has("error") to distinguish
## the error variant deterministically (OQ4 return-type variant).
func _invalid_equipment_error(offenders: Array[Dictionary]) -> Dictionary:
	return {
		"error": {
			"kind": ERROR_KIND_INVALID_EQUIPMENT,
			"offenders": offenders.duplicate(),
		},
	}


## Computes the Story 002 zone_synergy for [inst] (Core Rules 5/6,
## TR-ZR-004/006): S_max × (1 − e^(−k × r_i)) with r_i = n_same_i / N_max_i.
##
## [zone_membership] / [n_max] are the precomputed per-instance tables built
## by evaluate(); [all_instances] is the id-ascending list so the neighbor
## scan runs in the mandated fixed order (Core Rule 8). Returns 0.0 when the
## instance carries no zone membership (Core Rule 5) or has an empty
## perimeter (degenerate footprint — also guards the division). n_same counts
## DISTINCT adjacent instances sharing ≥ 1 zone (AC5); a neighbor with empty
## zone membership is skipped (it can never be same-zone). All terms are
## non-negative — a cross-zone pair contributes exactly 0, never a penalty
## (AC10, Pillar 2).
func _compute_zone_synergy(inst: PlacedInstance, all_instances: Array[PlacedInstance], zone_membership: Dictionary, n_max: Dictionary, s_max: float, k: float) -> float:
	var own_zones: Array = zone_membership[inst.instance_id]
	var own_n_max: int = n_max[inst.instance_id]
	if own_zones.is_empty() or own_n_max <= 0:
		return 0.0

	var n_same := 0
	for other in all_instances:
		if other.instance_id == inst.instance_id:
			continue
		if not _are_adjacent(inst, other):
			continue
		var other_zones: Array = zone_membership[other.instance_id]
		if other_zones.is_empty():
			continue
		if _shares_zone(own_zones, other_zones):
			n_same += 1

	var r: float = float(n_same) / float(own_n_max)
	return s_max * (1.0 - exp(-k * r))


## True iff [a] and [b] share at least one zone (OR-match, Core Rule 5 —
## AC9). Both arrays hold String zone ids; an empty array shares nothing.
func _shares_zone(a: Array, b: Array) -> bool:
	for zone in a:
		if b.has(zone):
			return true
	return false


## True iff any footprint cell of [a] shares an orthogonal edge with any
## footprint cell of [b] (Core Rule 6, TR-ZR-006). Manhattan distance of
## exactly 1 between a pair of cells — diagonal (corner-only) contact is
## distance 2 and therefore NOT adjacency (AC3). Overlapping cells (distance
## 0) are not adjacency either — placement rules forbid overlap, and a
## defensive non-count is the safe behavior.
func _are_adjacent(a: PlacedInstance, b: PlacedInstance) -> bool:
	for ca in a.footprint_cells:
		for cb in b.footprint_cells:
			if abs(ca.x - cb.x) + abs(ca.y - cb.y) == 1:
				return true
	return false


## N_max_i (Core Rule 6): the number of DISTINCT cells orthogonally adjacent
## to [footprint_cells], excluding the instance's own cells. 1×1 → 4, 2×2 →
## 8, 1×3 → 8, etc. Deduplicated so a perimeter cell shared by two footprint
## cells counts once (AC5 — the count is of cells, not shared edges).
##
## NOTE: the GDD's full definition counts only in-bounds cells (AC17, grid
## boundary). The boundary check needs get_dimensions() on the reader, which
## arrives with the spaciousness story (ZR-003 — it extends the fake reader
## with is_solid/get_dimensions); until then the perimeter is computed
## geometrically, which matches every Story 002 fixture (all interior).
func _perimeter_cell_count(footprint_cells: Array[Vector2i]) -> int:
	var perimeter := {}
	for cell in footprint_cells:
		for step in ORTHOGONAL_DIRS:
			var neighbor: Vector2i = cell + step
			if not footprint_cells.has(neighbor) and not perimeter.has(neighbor):
				perimeter[neighbor] = true
	return perimeter.size()


## Reads the catalog-authored `zone_membership` for [equipment_id] from the
## def (Core Rule 5 — consumed by the synergy formula).
##
## [valid_equipment] is the precomputed per-equipment validity table built by
## evaluate() (equipment_id -> bool, probed SILENTLY via has_definition).
## Returns [] when the id has no catalog definition (stale/corrupt type id —
## that instance contributes zone_synergy=0 for itself and, with an empty
## membership, is never counted as a same-zone neighbor; the Story 004
## strict_mode channel reports it) or when the def declares no zones. The
## validity check happens BEFORE get_definition() so an invalid id never
## triggers the catalog's push_error — the anomaly stays observable only
## through the injected channel (AC15b).
func _read_zone_membership(catalog: EquipmentCatalog, equipment_id: String, valid_equipment: Dictionary) -> Array:
	if not valid_equipment.get(equipment_id, false):
		return []
	var def: EquipmentDef = catalog.get_definition(equipment_id)
	if def == null:
		return []
	return def.zone_membership


## Reads the catalog-authored `comfort` magnitude for [equipment_id] from the
## def's `effects` container (tag vocabulary owned by ZoneRules, Core Rule 4).
##
## [valid_equipment] is the precomputed per-equipment validity table built by
## evaluate() (equipment_id -> bool, probed SILENTLY via has_definition).
## Returns 0.0 when the id has no catalog definition (stale/corrupt type id —
## that row contributes comfort=0 and is never negative; the Story 004
## strict_mode channel reports it) or when the def carries no `comfort` tag
## (a piece with no comfort simply earns 0). The validity check happens
## BEFORE get_definition() so an invalid id never triggers the catalog's
## push_error — the anomaly stays observable only through the injected
## channel (AC15b). comfort is catalog-validated to [0.0, 1.0] at load time
## by the equipment-catalog epic; reading never subtracts, so the returned
## value is non-negative by construction (AC8).
func _read_comfort(catalog: EquipmentCatalog, equipment_id: String, valid_equipment: Dictionary) -> float:
	if not valid_equipment.get(equipment_id, false):
		return 0.0
	var def: EquipmentDef = catalog.get_definition(equipment_id)
	if def == null:
		return 0.0
	for effect in def.effects:
		if effect["tag"] == "comfort":
			return float(effect["magnitude"])
	return 0.0


## Spaciousness (Story 003, TR-ZR-005, GDD Formulas): the open-breathing-room
## bonus for instance i:
##
##     spaciousness_i = C_max × (open_adj_i / total_adj_i)
##
## total_adj_i counts DISTINCT in-bounds cells orthogonally adjacent to i's
## footprint_cells ∪ access_cells, excluding i's own cells (AC17: out-of-
## bounds cells are dropped entirely — never counted as solid or open; a
## neighbor cell shared by two own cells counts once, dedupe via a set).
## open_adj_i is the subset where the snapshot reports is_solid == false —
## STATIC solidity only (walls + placed footprints). This reads no member
## data: the static/dynamic split is deliberate (Core Rule 1), so this
## function has zero overlap with the dynamic density field.
##
## Output ∈ [0, C_max]. total_adj_i == 0 (fully walled in — should not occur
## under placement rules) is guarded to 0.0, never a divide-by-zero (AC7).
func _compute_spaciousness(snapshot: GridStateReader, inst: PlacedInstance) -> float:
	var dims: Vector2i = snapshot.get_dimensions()

	# i's own cells = footprint ∪ access. Excluding own cells from the
	# adjacency set is part of the formula (GDD "excluding i's own cells").
	var own: Dictionary = {}
	for c in inst.footprint_cells:
		own[c] = true
	for c in inst.access_cells:
		own[c] = true

	# Distinct in-bounds orthogonal neighbors of the own-cell set.
	var adjacent: Dictionary = {}
	for key in own:
		var cell: Vector2i = key
		for dir in ORTHOGONAL_DIRS:
			var n: Vector2i = cell + dir
			# AC17 — out-of-bounds cells excluded (not solid, not open).
			if n.x < 0 or n.y < 0 or n.x >= dims.x or n.y >= dims.y:
				continue
			# Exclude i's own cells (footprint ∪ access).
			if own.has(n):
				continue
			adjacent[n] = true

	var total_adj: int = adjacent.size()
	if total_adj == 0:
		# AC7 — guard, never divide by zero.
		return 0.0

	var open_adj := 0
	for key in adjacent:
		var cell: Vector2i = key
		if not snapshot.is_solid(cell):
			open_adj += 1

	return C_MAX_SPACIOUSNESS * (float(open_adj) / float(total_adj))
