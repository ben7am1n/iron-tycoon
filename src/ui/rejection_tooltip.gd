## RejectionTooltip — the placement-rejection feedback logic model (Story CFO-004).
##
## Story: production/epics/congestion-flow-overlay/story-004-rejection-tooltip-layer-priority.md
## Req:   TR-CFO-006 (placement rejection feedback: 400ms hold delay,
##        2-bucket messages, 5 FAIL codes collapsed, never a raw fail-code
##        string, no sound)
## ADR:   ADR-0005 (Signal Bus — S4 placement_rejected is the trigger;
##        typed signal connections only)
##
## CORE RULE 6 (GDD): the 5 GridSystem FailCode values collapse into 2
## buckets, reusing the placement ghost's existing footprint-vs-access split:
##   - Footprint bucket  (OUT_OF_BOUNDS, BLOCKED_BY_ROOM_GEOMETRY,
##     OVERLAPS_EXISTING_EQUIPMENT) -> "Won't fit here"
##   - Access bucket     (ACCESS_OUT_OF_BOUNDS,
##     ACCESS_BLOCKED_BY_ROOM_GEOMETRY) -> "Blocks the path in"
## A raw fail-code string is NEVER shown to the player (AC4/AC5). Five
## distinct messages would over-teach a zero-stakes, instantly-retriable
## action — calm, never alarm (Pillar 2). No sound is tied to rejection.
##
## HOLD DELAY (flicker protection): the tooltip is shown only AFTER the
## cursor holds ~400 ms over the invalid cell (knob 250–600 ms), so a fast
## sweep across invalid cells never flashes a tooltip. The 400 ms hold
## TIMER is UI-layer state — the overlay/bridge Node owns it via
## get_tree().create_timer() (ADR-0005 §5; RefCounted cannot create
## timers). This model is the RefCounted logic half: it tracks
## pending/visible state and exposes on_hold_elapsed(), which the owning
## node calls when its timer fires. A stale timer firing after dismiss()
## is a no-op (the flicker-protection contract lives here).
##
## NOT a SimSystem: presentation-layer logic component (overlay scene
## infra lives in src/ui/ per EPIC DoD). Follows the ADR-0001 two-phase
## init shape with a minimal _initialized guard.
class_name RejectionTooltip
extends RefCounted

## The two bucket messages (GDD Core Rule 6 / AC4 / AC5) — the ONLY strings
## this model ever produces. Localization-ready (OQ4 / /ux-design).
const MESSAGE_FOOTPRINT := "Won't fit here"
const MESSAGE_ACCESS := "Blocks the path in"

## Config keys (data-driven per Control Manifest — GDD anchors, not
## hardcoded).
const CONFIG_HOLD_MS := "rejection_tooltip_hold_ms"

const DEFAULT_HOLD_MS := 400.0
const HOLD_MS_MIN := 250.0
const HOLD_MS_MAX := 600.0

## Cross-script class alias (pinned caveat: class_name is NOT globally
## registered under headless load — reference via preload aliases).
const GridSystemScript := preload("res://src/systems/grid_system.gd")

var _hold_ms: float = DEFAULT_HOLD_MS

## True from on_placement_rejected() until dismiss() — the cursor is still
## over the invalid cell and the hold window is open. A hold-elapsed
## notification only shows the tooltip while this is true (flicker
## protection against stale timers).
var _pending: bool = false

## True once the hold has elapsed — the tooltip is currently displayed.
var _visible: bool = false

## The bucket message for the current/last rejection (MESSAGE_*).
var _message: String = ""

## The rejected anchor cell (cursor position at the rejected drop) — the
## renderer anchors the tooltip adjacent to it.
var _anchor: Vector2i = Vector2i.ZERO

## The rejected equipment id (diagnostic/white-box; not rendered).
var _equipment_id: String = ""

## The raw fail_code (white-box observable; NEVER rendered — Core Rule 6).
var _fail_code: int = -1

var _initialized: bool = false


## Two-phase init (ADR-0001 shape). [config] carries data-driven knobs
## (CONFIG_* keys); missing keys fall back to the GDD anchors. The hold
## duration is clamped to the GDD safe range 250–600 ms.
func init(config: Dictionary = {}) -> void:
	if not _mark_initialized():
		return
	var raw: float = float(config.get(CONFIG_HOLD_MS, DEFAULT_HOLD_MS))
	_hold_ms = clampf(raw, HOLD_MS_MIN, HOLD_MS_MAX)


## The 5-to-2 bucket mapping (GDD Core Rule 6, AC4/AC5). Returns the bucket
## message for a GridSystem FailCode. NEVER returns a raw fail-code string.
##
## Access bucket: ACCESS_OUT_OF_BOUNDS (4), ACCESS_BLOCKED_BY_ROOM_GEOMETRY
## (5). Everything else — including the footprint codes (1/2/3) AND
## defensive fallbacks (VALID(0) or an unknown code that should never
## arrive via placement_rejected) — maps to the footprint message: a calm
## default is safer than a raw code, and a rejected drop can never carry
## VALID in practice (PlacementSystem only emits S4 on can_place FAIL).
func classify_fail_code(fail_code: int) -> String:
	if (
		fail_code == GridSystemScript.FailCode.ACCESS_OUT_OF_BOUNDS
		or fail_code == GridSystemScript.FailCode.ACCESS_BLOCKED_BY_ROOM_GEOMETRY
	):
		return MESSAGE_ACCESS
	return MESSAGE_FOOTPRINT


## S4 handler trigger (called by the owning overlay/bridge node on
## placement_rejected — arity 4, ADR-0005 catalog). Arms the hold window:
## the tooltip is NOT visible yet; it shows only after the hold elapses
## while still pending. A second rejection while one is pending replaces
## the previous message/anchor (single calm tooltip, never stacked).
func on_placement_rejected(equipment_id: String, anchor: Vector2i, rotation: int, fail_code: int) -> void:
	if not _assert_initialized():
		return
	_equipment_id = equipment_id
	_anchor = anchor
	_fail_code = fail_code
	_message = classify_fail_code(fail_code)
	_pending = true
	_visible = false


## Called by the owning overlay/bridge node when its hold timer fires
## (get_tree().create_timer(hold_ms) — ADR-0005 §5). Shows the tooltip ONLY
## if the rejection is still pending: if the cursor has since moved to a
## valid cell / the drag ended (dismiss() already ran), the stale timer is
## a no-op — the hold-delay flicker protection.
func on_hold_elapsed() -> void:
	if not _assert_initialized():
		return
	if not _pending:
		return  # stale timer after dismiss — no tooltip (flicker protection)
	_visible = true


## Hides the tooltip and clears the hold window. Called when the cursor
## moves to a valid cell (preview_validity_changed(valid=true)) or a drag
## begins/ends — per the GDD States table, the tooltip is hidden on
## "cursor moves to valid cell / drag ends".
func dismiss() -> void:
	if not _assert_initialized():
		return
	_pending = false
	_visible = false


## Whether the tooltip is currently displayed.
func is_visible() -> bool:
	if not _assert_initialized():
		return false
	return _visible


## Whether a rejection hold window is open (not yet shown, not yet
## dismissed) — the model half of "the 400 ms hold delay".
func is_pending() -> bool:
	if not _assert_initialized():
		return false
	return _pending


## The current bucket message (MESSAGE_FOOTPRINT or MESSAGE_ACCESS). Empty
## before the first rejection. Never a raw fail-code string.
func get_message() -> String:
	return _message


## The rejected anchor cell — the renderer draws the tooltip adjacent to it
## (cursor-adjacent, GDD Core Rule 6).
func get_anchor() -> Vector2i:
	return _anchor


## The hold delay in milliseconds (config knob, clamped to 250–600). The
## owning node uses this to size its SceneTreeTimer.
func get_hold_ms() -> float:
	return _hold_ms


## The raw fail code of the last rejection — white-box observable for
## tests. NEVER rendered (Core Rule 6: no raw code strings to the player).
func get_last_fail_code() -> int:
	return _fail_code


func _mark_initialized() -> bool:
	if _initialized:
		push_error("RejectionTooltip: init() called twice.")
		return false
	_initialized = true
	return true


func _assert_initialized() -> bool:
	if not _initialized:
		push_error("RejectionTooltip: method called before init().")
		return false
	return true
