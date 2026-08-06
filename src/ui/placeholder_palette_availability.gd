## PlaceholderPaletteAvailability — Story-001 placeholder implementation of
## the Shop query surface (build-shop-ui epic, Story 001; TR-BSUI-001).
##
## Implements EXACTLY the shop-purchase.md Core Rule 1 / Core Rule 5 shape so
## Story 002's real Shop can extend PaletteAvailability and keep the same
## contract:
##   - can_purchase(id) = is_unlocked(id) AND (cost == 0 OR
##     Economy.can_afford(cost))   — the cost == 0 short-circuit is required
##     because Economy rejects can_afford(0) (Economy AC5) — a free item is
##     trivially affordable without asking Economy.
##   - is_unlocked(id) = (unlock_requirement == "")   — EquipmentDef stores
##     unlock_requirement as a String and uses "" (never null) for "always
##     available" (equipment_def.gd header); the loader normalizes null/missing
##     to "". MVP stub, fail-closed: any non-empty requirement → locked.
##
## This placeholder is the "占位 availability 状态" the story sanctions —
## the palette renders whatever this query layer reports. The real Shop
## (Story 002) swaps in as the injected PaletteAvailability.
class_name PlaceholderPaletteAvailability extends PaletteAvailability

## Immutable read-only catalog (owned by the composition root).
var _catalog: EquipmentCatalog

## The live balance ledger — affordability read via Economy.can_afford()
## (never a direct balance poke; the palette's balance_changed subscription
## is what re-queries this source).
var _economy: Economy

func _init(p_catalog: EquipmentCatalog, p_economy: Economy) -> void:
	_catalog = p_catalog
	_economy = p_economy


## shop-purchase.md Core Rule 1 — the full purchase gate: unlocked AND
## affordable. Pure query; never mutates balance and never emits a signal.
func can_purchase(equipment_id: String) -> bool:
	var def := _catalog.get_definition(equipment_id)
	if def == null:
		return false
	if def.unlock_requirement != "":
		return false
	if def.cost == 0:
		return true
	return _economy.can_afford(def.cost)


## shop-purchase.md Core Rule 5 (MVP stub, fail-closed): empty requirement
## string (normalized from null) means unlocked; any non-empty requirement
## means locked — no runtime unlock-state source exists yet.
func is_unlocked(equipment_id: String) -> bool:
	var def := _catalog.get_definition(equipment_id)
	if def == null:
		return false
	return def.unlock_requirement == ""


## Core Rule 4 hover derivation (Story 002's palette consumes it): X =
## cost - balance for an unlocked item; -1 when locked/unknown. Same
## derivation as the real Shop — this placeholder implements the query so
## story-001 rigs keep working when Story 002's palette formats tooltips.
func get_save_more_amount(equipment_id: String) -> int:
	var def := _catalog.get_definition(equipment_id)
	if def == null:
		return -1
	if def.unlock_requirement != "":
		return -1
	return def.cost - _economy.balance
