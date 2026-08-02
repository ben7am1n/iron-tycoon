## ZoneRules — stateless pure function scoring the static quality of a placed
## layout (zone-rules epic, Stories 001+002; TR-ZR-001/002/003/004/006; GDD
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
## EFFECT VOCABULARY (Core Rule 4, TR-ZR-003): exactly one catalog-authored
## input tag — `comfort`, read from the def's `effects` container (authored
## range [0.0, 1.0]). The other two tags are ZoneRules-computed outputs and
## are NEVER authored in the catalog:
##   - zone_synergy: computed output — Story 002 formula (Core Rules 5/6,
##     TR-ZR-004/006): S_max × (1 − e^(−k × r_i)), r_i = n_same_i / N_max_i
##   - spaciousness: computed output — Story 003 formula; 0.0 in this story
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

## The four orthogonal neighbor offsets — edge-sharing only, no diagonals
## (TR-ZR-006, consistent with the Navigation no-corner-cut rule).
const _ORTHOGONAL_STEPS := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]


## Sole entry point — scores every placed instance in [snapshot].
##
## Reads ONLY [snapshot].get_placed_instances() and
## [catalog].get_definition(id) — no other API (AC13 static-only guarantee:
## this file references no single-cell occupancy / access lookup and no live
## data accessor). Both inputs are treated as immutable; the function owns no
## state, so repeated calls on the same inputs are bit-identical (AC1).
##
## [config] is an optional data-driven tuning seam (Story 002, Core Rules
## 5/6): keys CONFIG_S_MAX / CONFIG_K override the GDD anchors. The default
## empty Dictionary keeps the pure-function signature backward compatible —
## existing two-argument callers are unaffected (AC1/AC2 hold for the default
## config).
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

	# Precompute the per-instance zone membership and perimeter capacity ONCE:
	# catalog lookups return deep copies (EquipmentCatalog defensive posture)
	# and the perimeter scan is O(footprint × 4) — neither belongs in the
	# per-pair inner loop of _compute_zone_synergy.
	var zone_membership := {}
	var n_max := {}
	for inst in sorted:
		zone_membership[inst.instance_id] = _read_zone_membership(catalog, inst.equipment_id)
		n_max[inst.instance_id] = _perimeter_cell_count(inst.footprint_cells)

	var result := {}
	for inst in sorted:
		var comfort: float = _read_comfort(catalog, inst.equipment_id)
		var zone_synergy: float = _compute_zone_synergy(inst, sorted, zone_membership, n_max, s_max, k)
		# Story 003 owns the spaciousness formula — placeholder 0.0 here.
		var spaciousness := 0.0
		result[inst.instance_id] = {
			"comfort": comfort,
			"zone_synergy": zone_synergy,
			"spaciousness": spaciousness,
			"total": comfort + zone_synergy + spaciousness,
		}
	return result


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
		for step in _ORTHOGONAL_STEPS:
			var neighbor: Vector2i = cell + step
			if not footprint_cells.has(neighbor) and not perimeter.has(neighbor):
				perimeter[neighbor] = true
	return perimeter.size()


## Reads the catalog-authored `zone_membership` for [equipment_id] from the
## def (Core Rule 5 — consumed by the synergy formula).
##
## Returns [] when the id has no catalog definition (stale/corrupt type id —
## that instance contributes zone_synergy=0 for itself and, with an empty
## membership, is never counted as a same-zone neighbor; Story 004 owns the
## strict_mode reporting channel) or when the def declares no zones.
func _read_zone_membership(catalog: EquipmentCatalog, equipment_id: String) -> Array:
	var def: EquipmentDef = catalog.get_definition(equipment_id)
	if def == null:
		return []
	return def.zone_membership


## Reads the catalog-authored `comfort` magnitude for [equipment_id] from the
## def's `effects` container (tag vocabulary owned by ZoneRules, Core Rule 4).
##
## Returns 0.0 when the id has no catalog definition (stale/corrupt type id —
## that row contributes comfort=0 and is never negative; Story 004 owns the
## strict_mode reporting channel) or when the def carries no `comfort` tag (a
## piece with no comfort simply earns 0). comfort is catalog-validated to
## [0.0, 1.0] at load time by the equipment-catalog epic; reading never
## subtracts, so the returned value is non-negative by construction (AC8).
func _read_comfort(catalog: EquipmentCatalog, equipment_id: String) -> float:
	var def: EquipmentDef = catalog.get_definition(equipment_id)
	if def == null:
		return 0.0
	for effect in def.effects:
		if effect["tag"] == "comfort":
			return float(effect["magnitude"])
	return 0.0
