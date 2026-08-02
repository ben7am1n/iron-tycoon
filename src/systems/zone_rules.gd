## ZoneRules — stateless pure function scoring the static quality of a placed
## layout (zone-rules epic, Story 001; TR-ZR-001/002/003; GDD Core Rules
## 1/3/4/7/8).
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
##   - zone_synergy: computed output — Story 002 formula; 0.0 in this story
##   - spaciousness: computed output — Story 003 formula; 0.0 in this story
## All three are non-negative by construction — this system never subtracts;
## a poor layout earns 0 on a tag, it is never punished (Pillar 2 enforced
## at the vocabulary level, not by a downstream clamp).
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


## Sole entry point — scores every placed instance in [snapshot].
##
## Reads ONLY [snapshot].get_placed_instances() and
## [catalog].get_definition(id) — no other API (AC13 static-only guarantee:
## this file references no single-cell occupancy / access lookup and no live
## data accessor). Both inputs are treated as immutable; the function owns no
## state, so repeated calls on the same inputs are bit-identical (AC1).
func evaluate(snapshot: GridStateReader, catalog: EquipmentCatalog) -> Dictionary:
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

	var result := {}
	for inst in sorted:
		var comfort: float = _read_comfort(catalog, inst.equipment_id)
		# Story 002 owns the zone_synergy formula — placeholder 0.0 here.
		var zone_synergy := 0.0
		# Story 003 owns the spaciousness formula — placeholder 0.0 here.
		var spaciousness := 0.0
		result[inst.instance_id] = {
			"comfort": comfort,
			"zone_synergy": zone_synergy,
			"spaciousness": spaciousness,
			"total": comfort + zone_synergy + spaciousness,
		}
	return result


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
