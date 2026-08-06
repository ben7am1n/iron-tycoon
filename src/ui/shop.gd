## Shop — the real purchase-gate query surface for the build palette
## (build-shop-ui epic, Story 002; TR-BSUI-003/005; shop-purchase.md Core
## Rules 1/2/2a/2b/5; ADR-0005 S3/S4/S6, ADR-0006).
##
## Story 002's deliverable: the minimal Shop surface shop-purchase.md
## specifies, implemented as presentation-layer integration glue over
## EquipmentCatalog (cost/unlock_requirement), Economy (can_afford/spend),
## and PlacementSystem (is_dragging/placement_committed/placement_rejected).
## It replaces PlaceholderPaletteAvailability as the palette's injected
## availability with ZERO palette changes (Story 001 handoff) — it extends
## the PaletteAvailability contract and implements every query the palette
## consumes, plus the drag-start gate and the spend-on-commit listener.
##
## CORE RULE 1 (can_purchase gate): can_purchase(id) = is_unlocked(id) AND
## (cost == 0 OR Economy.can_afford(cost)). The cost == 0 short-circuit is
## REQUIRED because Economy rejects can_afford(0) (Economy AC5) — a free
## item is trivially affordable without asking Economy.
##
## CORE RULE 5 (unlock MVP stub, fail-closed): is_unlocked(id) =
## (unlock_requirement == ""); any non-empty requirement → false. EquipmentDef
## stores unlock_requirement as String and uses "" (never null) for
## "always available" (equipment_def.gd header). No runtime unlock source
## exists yet — Progression/Unlocks (#19) replaces this branch later.
##
## CORE RULE 2 (deduct-on-commit — the ordering guarantee): money is spent
## ONLY on placement_committed, ONLY for purchase-initiated drags. The
## palette mouse-down calls begin_purchase_drag(id) BEFORE PlacementSystem
## begins the drag; Shop sets _purchase_in_flight = {equipment_id, cost}
## only when the gate passes (can_purchase AND is_dragging() false). The
## placement_committed listener then spends EXACTLY ONCE at commit, skipped
## for cost-0 items (Core Rule 2b), and clears the flag. A commit with no
## flag is a RELOCATE (Core Rule 2a) — ignored entirely. A commit whose
## equipment_id mismatches the flag is the defensive expected-unreachable
## branch (Core Rule 2 step 3) — flag untouched, no spend. placement_rejected
## and silent cancel (notify_silent_cancel, called by the palette when it
## detects a drag ended without a signal) clear the flag with zero spend.
##
## CORE RULE 3 (one-drag structural backstop): begin_purchase_drag checks
## PlacementSystem.is_dragging() — if a drag is already in flight (including
## a relocate), NO flag is set and no drag is attempted. This is the
## structural guarantee the money-safety proof relies on; the palette's UI
## disable is reinforcement only.
##
## Core Rule 4 (hover "Save $X more"): get_save_more_amount(id) derives
## X = cost - balance for an unlocked item; the palette formats the tooltip.
##
## Plain RefCounted query object (NOT a SimSystem — no tick, no save state,
## same standing as EquipmentCatalog/PaletteAvailability). Owns only the
## transient _purchase_in_flight flag (Core Rule 6), never serialized.
class_name Shop extends PaletteAvailability

## preload alias for the PlacementSystem cross-reference — the story's
## documented headless pattern (global class cache is editor-generated;
## preload works regardless).
const PlacementSystemScript := preload("res://src/systems/placement_system.gd")

## Immutable read-only catalog (owned by the composition root).
var _catalog: EquipmentCatalog

## The live balance ledger — affordability read via Economy.can_afford()
## (never a direct balance poke).
var _economy: Economy

## The drag state machine — queried for is_dragging() (Core Rule 2 step 1
## structural backstop) and the source of placement_committed /
## placement_rejected (S3/S4) this Shop subscribes to.
var _placement: PlacementSystemScript

## The transient purchase flag (shop-purchase.md Core Rule 6): the single
## piece of state Shop owns. {equipment_id: String, cost: int} while a
## purchase drag is in flight; EMPTY Dictionary (not null — GDScript
## null-deref hygiene) otherwise. Set by begin_purchase_drag; cleared by
## commit/reject/silent cancel. Never serialized, never read by other systems.
var _purchase_in_flight: Dictionary = {}

var _initialized: bool = false


## Two-phase init (mirrors the palette's guard pattern with push_error, not
## assert — testable and release-safe). Stores injected dependencies and
## subscribes to PlacementSystem's S3 placement_committed + S4
## placement_rejected with TYPED signal connections (Control Manifest:
## string-based connects forbidden). A second init() call is a hard error.
func init(p_catalog: EquipmentCatalog, p_economy: Economy, p_placement: PlacementSystemScript) -> void:
	if _initialized:
		push_error("Shop.init() called twice")
		return
	_initialized = true
	_catalog = p_catalog
	_economy = p_economy
	_placement = p_placement
	_placement.placement_committed.connect(_on_placement_committed)
	_placement.placement_rejected.connect(_on_placement_rejected)


## shop-purchase.md Core Rule 1 — the full purchase gate: unlocked AND
## affordable, with the REQUIRED cost-0 short-circuit (Economy rejects
## can_afford(0) — Economy AC5; a free item is trivially affordable without
## asking Economy). Unlock is checked FIRST (Core Rule 1): a locked item is
## unbuyable even when cost == 0. Pure query — never mutates balance, never
## emits a signal.
func can_purchase(equipment_id: String) -> bool:
	if not _guard_initialized():
		return false
	var def := _catalog.get_definition(equipment_id)
	if def == null:
		return false
	if def.unlock_requirement != "":
		return false
	if def.cost == 0:
		return true
	return _economy.can_afford(def.cost)


## shop-purchase.md Core Rule 5 (MVP stub, fail-closed): empty requirement
## string (the loader normalizes null/missing to "") means unlocked; any
## non-empty requirement means locked — no runtime unlock-state source
## exists yet. Pure query.
func is_unlocked(equipment_id: String) -> bool:
	if not _guard_initialized():
		return false
	var def := _catalog.get_definition(equipment_id)
	if def == null:
		return false
	return def.unlock_requirement == ""


## The drag-start gate (shop-purchase.md Core Rule 2 step 1 — block-at-
## selection, TR-BSUI-003). The palette mouse-down calls this BEFORE it
## asks PlacementSystem to begin the drag.
##
## Returns true (and sets _purchase_in_flight = {equipment_id, cost}) ONLY
## when BOTH hold:
##   (a) can_purchase(equipment_id) — unlocked AND affordable (cost-0
##       short-circuit included), and
##   (b) PlacementSystem.is_dragging() is false — the structural backstop.
##       If a drag is ALREADY in flight (e.g. a relocate), Shop does NOT set
##       the flag and returns false; the palette must NOT attempt a drag.
##
## If either gate fails: false with ZERO state change (no flag). The palette
## then treats the item as inert (greyed/locked) — fail clearly before the
## gesture, Pillar 3.
func begin_purchase_drag(equipment_id: String) -> bool:
	if not _guard_initialized():
		return false
	if not can_purchase(equipment_id):
		return false
	if _placement.is_dragging():
		return false
	var def := _catalog.get_definition(equipment_id)
	_purchase_in_flight = {"equipment_id": equipment_id, "cost": def.cost}
	return true


## S3 placement_committed listener — the deduct-on-commit heart (Core Rule 2).
## Fires when PlacementSystem commits ANY drag (new placement or relocate —
## the same signal, Core Rule 2a). Three-way branch:
##   - flag null (relocate commit)      → ignore entirely: no spend, no flag
##                                        change (Core Rule 2a).
##   - flag set, equipment_id matches   → Economy.spend(cost) EXACTLY ONCE
##                                        using the cost captured at gate-time
##                                        (never re-checks can_afford — AC5),
##                                        skipped when cost == 0 (Core Rule
##                                        2b); then clear the flag.
##   - flag set, equipment_id MISMATCH  → defensive, expected unreachable
##                                        under the one-drag invariant (Core
##                                        Rule 2 step 3): no spend, flag
##                                        UNTOUCHED.
##
## Exactly-once: the flag is cleared in the match branch, so a second commit
## for the same drag is a relocate (flag null) and can never double-spend.
func _on_placement_committed(_instance_id: int, equipment_id: String, _footprint_cells: Array[Vector2i]) -> void:
	if not _guard_initialized():
		return
	if _purchase_in_flight.is_empty():
		return  # relocate commit — not a purchase (Core Rule 2a)
	if _purchase_in_flight["equipment_id"] != equipment_id:
		return  # mismatch — defensive branch, flag untouched, no spend
	var cost: int = _purchase_in_flight["cost"]
	if cost > 0:
		_economy.spend(cost)  # exactly once; cost-0 skips spend entirely (2b)
	_purchase_in_flight = {}


## S4 placement_rejected listener — a rejected drop resolves the purchase
## drag with ZERO spend (Core Rule 2 step 3). Clears the flag regardless of
## whether it was set (clearing an empty flag is a no-op, so relocate
## rejects are harmless too). No balance_changed, no spend call.
func _on_placement_rejected(_equipment_id: String, _anchor: Vector2i, _rotation: int, _fail_code: int) -> void:
	if not _guard_initialized():
		return
	_purchase_in_flight = {}


## Silent cancel (Esc / out-of-bounds drop / focus loss) produces NO signal
## from PlacementSystem (AC8/AC9/AC17/AC23) — the palette is the observer
## that detects a palette-initiated drag ended without a signal, and it
## calls this to clear the flag with ZERO spend (Core Rule 2 step 3).
## Idempotent: clearing an already-empty flag is a no-op, so calling it
## after a commit/reject resolution is harmless.
func notify_silent_cancel() -> void:
	if not _guard_initialized():
		return
	_purchase_in_flight = {}


## True while a purchase drag is in flight (the flag is set). The palette's
## one-drag UI disable is reinforcement; this query lets tests and the UI
## observe the structural state.
func is_purchase_in_flight() -> bool:
	return not _purchase_in_flight.is_empty()


## The equipment_id of the purchase drag currently in flight, or "" when
## idle. Read query for tests/UI.
func get_purchase_equipment_id() -> String:
	return _purchase_in_flight.get("equipment_id", "")


## The cost captured at gate-time of the purchase drag in flight, or -1 when
## idle. Read query for tests/UI.
func get_purchase_cost() -> int:
	return _purchase_in_flight.get("cost", -1)


## Core Rule 4 derivation for the hover "Save $X more" tooltip (TR-BSUI-005,
## AC9): X = cost - balance, sourced from EquipmentCatalog + Economy (both
## exposed). Returns:
##   - cost - balance for an UNLOCKED item (>= 1 when unaffordable; 0 when
##     balance exactly meets cost — the "just affordable" edge, full-tint,
##     no tooltip),
##   - -1 when locked (the palette shows the lock tooltip instead — a
##     distinct affordance, Core Rule 5) or the id is unknown.
## Pure derivation — no mutation, no signal.
func get_save_more_amount(equipment_id: String) -> int:
	if not _guard_initialized():
		return -1
	var def := _catalog.get_definition(equipment_id)
	if def == null:
		return -1
	if def.unlock_requirement != "":
		return -1
	return def.cost - _economy.balance


## Control Manifest use-before-init guard (push_error + safe default, never
## assert — verified engine fact: assert aborts the frame and corrupts
## Object-typed returns).
func _guard_initialized() -> bool:
	if not _initialized:
		push_error("Shop: method called before init()")
		return false
	return true
