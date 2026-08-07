## SelectionInputBridge — the thin input-forwarding Node for SelectionSystem.
##
## Story: selection-system / story-002-input-bridge-node.md (SEL-002)
## Req:   TR-SEL-008 (bridge wired: screen→cell conversion + on_cell_clicked
##        forwarding), TR-SEL-009 (keyboard: Esc=deselect/cancel sell-confirm,
##        Del=triggers the same Sell soft-confirm — never an instant sale)
## ADR:   ADR-0001 §3 (Presentation Bridge Pattern — thin Node owned by the
##        composition root, zero logic, pure forwarding), ADR-0005 §5 (Input
##        Bridge Pattern — _unhandled_input() for mouse, _unhandled_key_input()
##        for keyboard, screen→cell conversion BEFORE any system call)
##
## SelectionSystem is RefCounted and cannot receive Godot input callbacks
## (_input/_unhandled_input/_unhandled_key_input are Node-only) nor create
## timers via get_tree(). This bridge is the presentation-layer bridge Node:
## it converts engine input events into the system's parsed method calls and
## OWNS the 2s sell-confirm timer — the timer and the pending flag are
## UI-layer state, never simulation state (GDD Core Rule 4, ADR-0005 §3
## "Timer signals" exclusion).
##
## OWNERSHIP (pinned): the bridge is created and attached by
## SimulationOrchestrator (the composition root, ADR-0001 §4) as a child Node —
## NOT a separate scene. The orchestrator holds SelectionSystem as a RefCounted
## field; this bridge holds a reference too, but MUST NEVER be the sole strong
## reference: if a scene transition destroys this Node, SelectionSystem must
## survive with selection state intact (mirrors the placement bridge).
##
## CONTRACT — forwarded methods (ADR-0005 §5 / story-002):
##   on_cell_clicked(cell)   → SelectionSystem.on_cell_clicked(cell)
##   on_esc_pressed()        → pending? revert only (selection stays, GDD
##                             states table) : SelectionSystem.on_esc_pressed()
##   on_del_pressed()        → request_sell_confirm() — the SAME soft-confirm
##                             path the Sell button uses (TR-SEL-009: the
##                             keyboard never bypasses the confirm)
##
## SELL-CONFIRM STATE (bridge-owned, UI-layer): the Sell button (Story 003's
## toolbar) and the Del key BOTH call request_sell_confirm(). While pending:
##   - second click within 2s  → confirm_sell() → emit sell_confirm_confirmed
##                               (Story 003 hooks this signal to perform the
##                               actual sale: remove piece, credit Economy,
##                               clear selection)
##   - 2s elapse               → timer timeout → revert, no sale
##   - Esc                     → revert only, selection stays
##   - grid click (click-away) → revert, then the click resolves normally
## Emitted signals: sell_confirm_started / sell_confirm_reverted /
## sell_confirm_confirmed — Story 004's toolbar listens for the button morph.
##
## EVENT ROUTING (Godot 4.6 dual-focus, ADR-0005 §5):
##   - Mouse: _unhandled_input() filtering InputEventMouseButton (left press).
##     Screen position → grid cell via GridSystem.world_to_grid() BEFORE any
##     system call; out-of-bounds clicks are ignored (the system's contract:
##     the bridge must not forward OOB cells). Clicks while PlacementSystem is
##     dragging reach the system but SelectionSystem.on_cell_clicked suppresses
##     them (AC12) — the two bridges need no coordination here.
##   - Keyboard (Esc/Del): _unhandled_key_input() — focus-independent. Echo
##     repeats are ignored (a held key must not re-trigger).
##   - Timer: SceneTreeTimer with process_always=true (create_timer's default
##     for that flag) — render-time, NOT tick-gated: the confirm window elapses
##     in real seconds and fires even while the sim is paused (story QA edge).
##
## TR-SEL-008 note: there is deliberately NO _process() override in this
## class — input is event-driven only (mirrors TR-PS-012's no-polling rule).
class_name SelectionInputBridge extends Node


## Data-driven config seam (coding standard: gameplay values never hardcoded).
## GDD Tuning Knob: sell-confirm window 2s, safe range 1.5–3.0s.
const CONFIG_SELL_CONFIRM_DURATION := "sell_confirm_duration"
const DEFAULT_SELL_CONFIRM_DURATION := 2.0
const SELL_CONFIRM_DURATION_MIN := 1.5
const SELL_CONFIRM_DURATION_MAX := 3.0


## Sell button morphed into "Confirm sell +$X" — a soft-confirm window opened
## (via Sell click OR Del). Story 004's toolbar listens to render the morph.
## Arity: 0 (UI-layer signal, not in the ADR-0005 S1–S8 catalog — timer
## signals are explicitly excluded there).
signal sell_confirm_started

## The window closed WITHOUT a sale (2s timeout / Esc / click-away). The
## toolbar reverts to the normal Sell button. Arity: 0.
signal sell_confirm_reverted

## The second click landed within the 2s window. Story 003's sell flow listens
## and performs the actual sale (piece removed, Economy credited refund,
## selection clears). This bridge only fires the signal — it never sells.
## Arity: 0.
signal sell_confirm_confirmed


## The RefCounted system this bridge forwards to. Injected by the composition
## root. Never null after init(); a null guard keeps the bridge safe during
## scene teardown ordering.
var _system: SelectionSystem

## The GridSystem used for screen→cell conversion (ADR-0005 §5: the bridge
## converts, the system never sees pixels). Injected by the composition root.
var _grid: GridSystem

## Presentation cell size for world_to_grid() — the same presentation value
## the placement bridge receives (one grid, one cell size). Injected by the
## composition root so GridSystem keeps its "never hardcoded" contract.
var _cell_size: int = 32

## PlacementSystem — injected for the Move-during-drag guard
## (story Implementation Notes): the toolbar must disable Move while
## PlacementSystem.is_dragging() is true (AC27). Optional (default null) so
## standalone bridge tests need not build a placement system; the
## composition root always injects it.
var _placement: PlacementSystem


## Sell-confirm window length in real seconds (GDD Tuning Knob: default 2.0s,
## safe range 1.5–3.0s). Data-driven via config["sell_confirm_duration"],
## clamped to the GDD safe range. UI-layer state, owned by this bridge.
var _sell_confirm_duration: float = DEFAULT_SELL_CONFIRM_DURATION

## True while a soft-confirm window is open (button showing "Confirm sell
## +$X"). Bridge-owned UI-layer state — never simulation state (ADR-0005 §3).
var _sell_confirm_pending: bool = false

## The live SceneTreeTimer for the open window; null when no window is open.
## Kept so the timeout callback can be guarded; SceneTreeTimer has no cancel
## API, so cancellation is handled by the generation counter below.
var _sell_confirm_timer: SceneTreeTimer = null

## Generation counter for the confirm timer. Bumped on every
## request_sell_confirm and every confirm/cancel; the timeout callback is
## bound to the generation at creation time, so a STALE timer from a
## cancelled window can never revert a NEWER window (the classic stale-timer
## bug: cancel window A, request window B, A's timeout must not kill B).
var _timer_generation: int = 0


## Composition-root injection (ADR-0001 §3 init pattern). Stores the system,
## the grid, the presentation cell size, the optional placement system, and
## applies the (clamped) data-driven config. Called once by
## SimulationOrchestrator right after add_child(). A second call re-injects —
## the bridge is stateless besides the confirm state, and re-injection is
## safe (mirrors the placement bridge's re-init).
func init(
	system: SelectionSystem,
	grid: GridSystem,
	cell_size: int,
	placement: PlacementSystem = null,
	config: Dictionary = {}
) -> void:
	_system = system
	_grid = grid
	_cell_size = cell_size
	_placement = placement
	apply_config(config)
	# Subscription: any deselect while a confirm is pending must revert the
	# window (GDD states table: "selected | selected instance removed
	# externally | none selected"). This covers external invalidation (AC11 —
	# the piece sold/removed by another path) that no bridge input path can
	# see. Guarded against double-connect for re-init safety.
	if _system != null and not _system.selection_changed.is_connected(_on_selection_changed):
		_system.selection_changed.connect(_on_selection_changed)


## Applies data-driven config values (Control Manifest: gameplay values are
## never hardcoded). Missing keys keep the GDD anchors. sell_confirm_duration
## is clamped to the GDD safe range (1.5–3.0s) so a bad config value can
## never produce an instant or sluggish confirm window.
func apply_config(config: Dictionary) -> void:
	if config.has(CONFIG_SELL_CONFIRM_DURATION):
		_sell_confirm_duration = clampf(
			float(config[CONFIG_SELL_CONFIRM_DURATION]),
			SELL_CONFIRM_DURATION_MIN,
			SELL_CONFIRM_DURATION_MAX
		)


# === Forwarded calls (ADR-0005 §5 contract) ===

## Grid cell clicked — the bridge's click entry point. A grid click while a
## sell-confirm is pending is a CLICK-AWAY: the window reverts (no sale),
## then the click resolves normally (empty floor deselects, another piece
## swaps — GDD states table: pending | click-away | selected | reverts).
## Callers (this bridge's _unhandled_input) MUST convert screen position to
## cell via world_to_grid() BEFORE calling — the system never sees pixels.
func on_cell_clicked(cell: Vector2i) -> void:
	if _sell_confirm_pending:
		_revert_sell_confirm()
	if _system == null:
		return
	_system.on_cell_clicked(cell)


## Escape — deselect OR cancel the pending confirm (Core Rule 5, AC3, GDD
## states table). Two distinct behaviors:
##   - a soft-confirm is pending → REVERT ONLY: the window closes, no sale,
##     and the selection STAYS (states table: pending | Esc | selected).
##     The pending flag is bridge-owned UI state, so Esc never reaches the
##     RefCounted system in this branch.
##   - no pending confirm → forward to SelectionSystem.on_esc_pressed(),
##     which deselects (or no-ops when nothing is selected — Story 001).
func on_esc_pressed() -> void:
	if _sell_confirm_pending:
		_revert_sell_confirm()
		return
	if _system == null:
		return
	_system.on_esc_pressed()


## Delete key — triggers the SAME soft-confirm as clicking Sell
## (TR-SEL-009 / Core Rule 5). The keyboard never bypasses the confirm: Del
## routes through request_sell_confirm(), the identical path the Sell button
## uses, so there is no instant destructive sell. No selection → no-op;
## already pending → no-op (no double-morph).
func on_del_pressed() -> void:
	request_sell_confirm()


# === Sell-confirm state (bridge-owned, UI-layer) ===

## Opens the 2s soft-confirm window — the SHARED entry point for the Sell
## button (Story 003's toolbar) and the Del key. Returns true when the window
## opened; false when it is a no-op: nothing selected, or a window is already
## open (no double-morph). On open: pending flag set, timer started
## (generation-bumped), sell_confirm_started emitted.
func request_sell_confirm() -> bool:
	if _system == null:
		return false
	if _sell_confirm_pending:
		return false  # no double-morph (QA edge: Del during pending)
	if _system.get_selected_instance_id() == -1:
		return false  # no selection — Del/Sell is a no-op
	_sell_confirm_pending = true
	_timer_generation += 1
	_start_sell_confirm_timer(_timer_generation)
	sell_confirm_started.emit()
	return true


## Second click within the window — the confirm. Cancels the pending state
## (bumping the generation invalidates any in-flight timer) and emits
## sell_confirm_confirmed. The ACTUAL sale is Story 003's job — this bridge
## only fires the signal; the sale logic (piece removal, Economy credit,
## selection clear) hooks sell_confirm_confirmed. No-op when no window is
## open.
func confirm_sell() -> void:
	if not _sell_confirm_pending:
		return
	_sell_confirm_pending = false
	_sell_confirm_timer = null
	_timer_generation += 1  # invalidate the pending window's timer
	sell_confirm_confirmed.emit()


## True while a soft-confirm window is open (Story 003/004 query this to
## decide the toolbar's button label / morph state).
func is_sell_confirm_pending() -> bool:
	return _sell_confirm_pending


## Move-during-drag guard (story Implementation Notes, PlacementSystem AC27):
## the toolbar must disable the Move button while PlacementSystem is
## DRAGGING (a relocate during an active drag is a no-op; the UI should not
## offer it). The bridge owns this query so Story 004's toolbar asks one
## place. No placement injected → not blocked (safe default; the composition
## root always injects it).
func is_move_blocked() -> bool:
	if _placement == null:
		return false
	return _placement.is_dragging()


# === Engine event handlers ===

## Mouse routing (ADR-0005 §5): _unhandled_input() filters
## InputEventMouseButton. Left press → screen→cell via
## GridSystem.world_to_grid() BEFORE any system call — the RefCounted system
## never sees raw screen pixels. Out-of-bounds clicks are silently ignored
## (story QA edge: click outside the grid → no conversion / no forwarding —
## world_to_grid's no-clamp contract would otherwise feed negative/large
## cells into the system). Clicks consumed by Controls (shop palette, HUD,
## toolbar) never reach _unhandled_input.
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			if _system == null or _grid == null:
				return
			var cell: Vector2i = _grid.world_to_grid(mb.position, _cell_size)
			if not _grid.is_in_bounds(cell):
				return  # OOB — ignore silently (bridge never forwards OOB)
			on_cell_clicked(cell)


## Keyboard routing (Godot 4.6 dual-focus, ADR-0005 §5): Esc and Del arrive
## via _unhandled_key_input() — focus-independent, so the hotkeys work while
## any Control has keyboard focus (dual-focus: keyboard focus is separate
## from mouse focus in 4.6+). Echo repeats are ignored (a held key must not
## re-trigger).
func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey:
		var key := event as InputEventKey
		if not key.pressed or key.echo:
			return
		if key.keycode == KEY_ESCAPE:
			on_esc_pressed()
		elif key.keycode == KEY_DELETE:
			on_del_pressed()


# === Timer internals ===

## Starts the 2s SceneTreeTimer for the open window. process_always=true
## (create_timer's default for that flag, passed explicitly here) means the
## timer is RENDER-time, not tick-gated: it elapses in real seconds and fires
## even while the sim is paused (story QA edge: "timer fires while paused").
## The callback is bound to [generation] so a stale timer can never revert a
## newer window. When the bridge is not in the tree (headless direct-call
## tests), no timer can be created — tests drive _on_sell_confirm_timeout()
## directly with the current generation.
func _start_sell_confirm_timer(generation: int) -> void:
	if not is_inside_tree():
		return  # not in the tree (standalone headless test) — timeout via direct call
	var tree := get_tree()
	var timer := tree.create_timer(_sell_confirm_duration, true)
	_sell_confirm_timer = timer
	timer.timeout.connect(_on_sell_confirm_timeout.bind(generation))


## The timer fired — 2s elapsed with no second click. Reverts the window
## (no sale — the "no destructive default" guarantee, QA Timer case).
## Stale-timer protection: the bound generation must match the CURRENT
## generation AND a window must still be pending — a timer from a cancelled
## or confirmed window is a silent no-op.
func _on_sell_confirm_timeout(generation: int) -> void:
	if not _sell_confirm_pending:
		return
	if generation != _timer_generation:
		return  # stale timer from a cancelled/confirmed window
	_revert_sell_confirm()


## Closes the pending window WITHOUT selling: flag cleared, timer dropped,
## sell_confirm_reverted emitted (toolbar reverts the button morph). Shared
## by timeout / Esc / click-away. Generation is NOT bumped here — the timer
## that called this is the current one; a stale timer's bound generation
## already mismatches, so the guard in _on_sell_confirm_timeout is enough.
func _revert_sell_confirm() -> void:
	if not _sell_confirm_pending:
		return
	_sell_confirm_pending = false
	_sell_confirm_timer = null
	sell_confirm_reverted.emit()


## SelectionSystem.selection_changed subscriber (S7 arity contract: the
## deselect emit passes EXACTLY ONE null argument; the select emit passes
## four — the handler accepts 1..4 with defaults). ANY deselect while a
## confirm is pending reverts the window without selling — this is the
## external-invalidation path (AC11: the selected piece removed by another
## path fires selection_changed(null) with no bridge input involved). A
## deselect with no pending window is a silent no-op.
func _on_selection_changed(
	instance_id = null,
	equipment_def = null,
	cell = null,
	rotation = null
) -> void:
	if instance_id == null and _sell_confirm_pending:
		_revert_sell_confirm()
