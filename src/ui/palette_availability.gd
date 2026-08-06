## PaletteAvailability — the Shop query surface contract consumed by the
## BuildShopPalette (build-shop-ui epic, Story 001; TR-BSUI-001).
##
## GDD Core Rule 1 (design/gdd/build-shop-ui.md) requires the palette to
## query Shop for each catalog item: `can_purchase(id)` and `is_unlocked(id)`.
## The real Shop query layer is Story 002's deliverable — this card renders
## against a PLACEHOLDER availability state (story-001 implementation notes:
## "本卡可先对占位 availability 状态渲染"). This base class is the typed seam
## Story 002's Shop will extend; the story-001 placeholder ships as
## PlaceholderPaletteAvailability.
##
## Plain RefCounted query object (NOT a SimSystem — no tick, no save state,
## same standing as EquipmentCatalog). Typed injection keeps the palette
## headless-testable with a fake availability source, per the Control
## Manifest rule: typed dependencies, never duck-typed consumers.
##
## The @abstract keyword is NOT used — verified non-functional on RefCounted
## in Godot 4.7.1 (ADR-0001 §2). The manual guard below (push_error + safe
## default) is the established pattern.
class_name PaletteAvailability extends RefCounted

## Whether the item could be purchased RIGHT NOW (unlocked AND affordable,
## per shop-purchase.md Core Rule 1). Pure query — no mutation, no signal.
func can_purchase(equipment_id: String) -> bool:
	push_error("PaletteAvailability.can_purchase() is not implemented — subclass must override")
	return false

## Whether the item is unlocked (shop-purchase.md Core Rule 5: any
## non-empty unlock_requirement → locked). Pure query — no mutation.
func is_unlocked(equipment_id: String) -> bool:
	push_error("PaletteAvailability.is_unlocked() is not implemented — subclass must override")
	return false

## The drag-start gate (shop-purchase.md Core Rule 2 step 1, Story 002):
## sets the purchase-in-flight flag when the item is purchasable AND no
## drag is already in flight, returning whether a PlacementSystem drag may
## begin. Pure gate with transient flag state — no spend, no signal.
func begin_purchase_drag(equipment_id: String) -> bool:
	push_error("PaletteAvailability.begin_purchase_drag() is not implemented — subclass must override")
	return false

## Silent cancel resolution (shop-purchase.md Core Rule 2 step 3, Story 002):
## clears the purchase-in-flight flag with zero spend. Called by the palette
## when it detects a palette-initiated drag ended without a commit/reject
## signal. Idempotent.
func notify_silent_cancel() -> void:
	push_error("PaletteAvailability.notify_silent_cancel() is not implemented — subclass must override")

## Core Rule 4 hover derivation (TR-BSUI-005, Story 002): X = cost - balance
## for an unlocked item (>= 1 unaffordable, 0 just-affordable); -1 when
## locked or unknown. The palette formats "Save $X more". Pure query.
func get_save_more_amount(equipment_id: String) -> int:
	push_error("PaletteAvailability.get_save_more_amount() is not implemented — subclass must override")
	return -1
