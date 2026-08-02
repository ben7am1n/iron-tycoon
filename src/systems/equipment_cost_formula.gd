# ⚠️ PROVISIONAL — will be replaced when Economy/Shop GDD (#11/#12) lands
# See AC-D.4 in design/gdd/equipment-catalog.md and GDD Open Question #2.
#
# provisional_equipment_cost — TEMPORARY anchor for MVP equipment pricing.
# This is NOT a final economy balance decision: the instant Economy/Shop GDD
# (design order #11/#12) lands, this class must be deprecated in favor of the
# official economy system and the PROVISIONAL markers removed. AC-D.4 is the
# mandatory re-evaluation checkpoint; this formula must not silently persist
# as final.
#
# formula: cost = base_cost + tier_step * (footprint_area - 1)
#   footprint_area = footprint_cells.size() ∈ {1, 2, 4} (1×1 / 1×2 / 2×2) —
#   guaranteed by footprint shape validation (Story 003) before this runs.
# MVP defaults: base_cost=200, tier_step=150 → 1×1=200, 1×2=350, 2×2=650
# (GDD Formulas §provisional_equipment_cost, TR-EC-008).
#
# Deliberately a STATIC utility class, not a method on EquipmentCatalog or
# EquipmentDef:
#   - EquipmentCatalog's public API is pinned by AC-C.8 (Story 001 test) to
#     exactly the 3 read-only queries — any public method, static or not,
#     would appear in get_script_method_list() and break that static check.
#   - EquipmentDef is a logic-free DTO ("holds no logic, performs no
#     validation").
# The JSON loader (Story 002) calls compute_provisional_cost() at EquipmentDef
# construction time when a JSON entry omits "cost" — the formula applies at
# construction, not during loading (Story 002 Out of Scope).
#
# Guardrails (Control Manifest, Foundation layer):
#   - cost >= 0 always: with footprint_area ∈ {1,2,4} and non-negative
#     parameters the output is >= base_cost >= 0. Negative-cost validation is
#     the loader/Story 007's job (AC-E.2), not this formula's.
#   - cost depends ONLY on footprint area in MVP — never on effects or
#     zone_membership.
#   - No per-equipment cost values are hardcoded here or may be hardcoded in
#     catalog JSON — cost is formula-derived (AC-PROV.1).
class_name EquipmentCostFormula extends RefCounted

## PROVISIONAL base cost — the price of a 1×1 equipment (footprint_area=1).
## Tuning Knob (GDD Tuning Knobs table): MVP suggestion 100–300, default 200.
## ⚠️ PROVISIONAL — Economy GDD owns the final value; this constant is a
## temporary anchor that must be removed when that GDD lands.
const PROVISIONAL_BASE_COST := 200

## PROVISIONAL tier step — additional price per extra footprint cell beyond
## the first (footprint_area - 1). Tuning Knob: MVP suggestion 100–200,
## default 150. ⚠️ PROVISIONAL — same deprecation obligation as
## PROVISIONAL_BASE_COST.
const PROVISIONAL_TIER_STEP := 150

## Computes the provisional purchase cost for one equipment definition.
##
## cost = base_cost + tier_step * (footprint_area - 1), where footprint_area
## is the number of cells in footprint_cells. Pure function — no state, no
## side effects, safe to call from the loader at construction time.
##
## PRECONDITION: footprint_cells must be a validated canonical footprint whose
## area ∈ {1, 2, 4} (guaranteed by Story 003's shape validation BEFORE this
## formula runs — the formula itself does not re-validate, matching the Story
## 006 implementation sketch).
##
## base_cost and tier_step are parameterized (NOT magic numbers in the formula
## body) — AC-PROV.2 verifies alternate values work without recompilation.
static func compute_provisional_cost(
	footprint_cells: Array[Vector2i],
	base_cost: int = PROVISIONAL_BASE_COST,
	tier_step: int = PROVISIONAL_TIER_STEP,
) -> int:
	var area := footprint_cells.size()
	# area ∈ {1, 2, 4} — guaranteed by footprint shape validation (Story 003)
	return base_cost + tier_step * (area - 1)
