## Congestion — per-equipment congestion scalar + EMA + double buffer (Story CG-001).
##
## Story: congestion / story-001-per-equipment-congestion-scalar-ema.md
## Req:   TR-CONG-001 (runs SECOND each tick after MemberSim; pure function
##        of member state, NO RNG), TR-CONG-002 (double-buffering: prev
##        read-only, next write target, single swap after all entities),
##        TR-CONG-003 (per-equipment congestion [0,1] = occupancy tier +
##        local density + EMA), TR-CONG-009 (EMA alpha=0.3, tau~3.3 ticks)
## ADR:   ADR-0005 (Signal Bus — S8 congestion_updated, zero payload, once
##        per tick after recompute; fixed tick order MemberSim -> Congestion
##        -> Satisfaction -> Economy)
##
## THIS FILE REPLACES THE SL-002 CORE-LAYER INTEGRATION STUB. The public
## contract surface SaveLoad depends on is preserved exactly:
##   - class_name Congestion extends SimSystem
##   - init(orchestrator, seeded_rng) — extra OPTIONAL parameters (grid,
##     member_sim, config) default to null/{} so pre-wiring call sites keep
##     working unchanged.
##   - system_name() == "Congestion"
##   - on_tick(tick_count: int) -> void  (the orchestrator's fixed dispatch)
##   - serialize() / deserialize(data, validate_only) two-phase protocol,
##     returning StubDeserializeResult. The serialize SHAPE ({counter,
##     rng_state}) is unchanged from the stub for this story — story-004
##     (determinism/serialization) extends it with the prev buffer.
##
## PRE-WIRING COMPATIBILITY PATH (documented, not silent): the SL-002
## save-load integration tests (roundtrip_determinism, load_orchestration)
## construct Congestion with ONLY init(orchestrator, seeded_rng) — no grid,
## no member_sim. Such an instance is NOT configured to compute anything
## (it has no state to measure), so on_tick() keeps the stub's observable
## behavior (counter += 1) and the serialized rng_state stays at its
## registered initial value. The real compute engages only when grid +
## member_sim are supplied. NOTE: unlike the stub, this system NEVER draws
## from its RNG sub-stream — TR-CONG-001 makes Congestion a pure function
## (story-004 AC2 static-greps for zero randi/randf calls). The sub-stream
## is still REGISTERED (SaveLoad's AC7 tests iterate get_rng() over all
## four systems), it just never advances; serializing the static state is
## deterministic and restores exactly.
##
## DOUBLE BUFFER (TR-CONG-002 / GDD Core Rule 2):
##   prev  — authoritative Congestion(t-1), read-only during tick t; the
##           ONLY buffer per_equipment_congestion(id) serves (AC5/AC6).
##   next  — write target for tick t; built from post-move member state;
##           after ALL entities are processed, a single swap prev <- next.
## Public queries therefore never see a half-written buffer (AC6).
##
## PER-EQUIPMENT SCALAR (TR-CONG-003 / GDD Formulas):
##   occ_i(t) = occupancy_state_i(t) / 2      # tier {0,1,2} -> {0,0.5,1.0}
##   dens_i(t) = clamp(N_i(t) / D_max, 0, 1)  # N_i = members within radius
##                                            # R of the access cell, EXCLUDING
##                                            # occupant/next_claimant (AC11)
##   raw_i(t)  = clamp(w_occ * occ_i + w_dense * dens_i, 0, 1)
##   Congestion_i(t) = clamp(alpha * raw_i + (1-alpha) * Congestion_i(t-1), 0, 1)
## Knobs (data-driven via the init [config] Dictionary): w_occ=0.7,
## w_dense=0.3, alpha=0.3, R=2, D_max=3.
##
## PER-CELL DENSITY FIELD (TR-CONG-004 / GDD Core Rule 4):
##   raw_cell(c,t)     = Σ_m kernel(c, cell_m(t))   # self 1.0, 4-neighbors w_n
##   smoothed(c,t)     = β · raw_cell(c,t) + (1 − β) · smoothed(c,t−1)
##   density_cell(c,t) = clamp(smoothed(c,t) / D_cell_max, 0, 1)
## Each member splats itself + in-bounds 4-neighbors (out-of-bounds dropped,
## not wrapped — AC15); per-cell EMA is O(1) memory per cell. The [0,1]
## field is exposed via per_cell_density(cell) for the overlay heatmap,
## rebuilt every tick BEFORE the S8 emit. Knobs: beta=0.4, w_n=0.25,
## D_cell_max=3. Keyed by flat row-major cell index (GridSystem.flat_index
## convention) so ascending flat index == ascending cell order.
##
## DETERMINISM (TR-CONG-007 / OQ2): equipment iteration runs in ASCENDING
## equipment_instance_id order (sorted ids from grid.get_placed_instances()),
## members splat in ASCENDING member_id order, cells EMA in ASCENDING flat
## index order — never Dictionary/hash order. The reservations map is read by
## KEYED access only — never iterated (TR-MS-006 convention).
##
## AC10 (queue cap): occupancy_state derives from MemberSim's reservation
## map (occupant + next_claimant, queue depth 1 MVP) -> max tier 2,
## defensively clamped.
##
## ACCESS_REACHABLE (story-003, TR-CONG-005 / GDD Core Rules 5-6):
##   access_reachable[E] = whether ANY path exists from the level's single
##   entrance_cell to E's first access cell (Navigation.get_path non-empty).
##   Recomputed ONLY when grid_changed fires — batch-flushed once per tick
##   (never once per event, never per tick), cached otherwise (AC12).
##   Removed equipment's prev/next/access_reachable entries are deleted the
##   same tick — never decayed (Core Rule 6 / AC9).
##
## S8 SIGNAL: congestion_updated — zero payload, emitted once per tick
## AFTER the swap completes (the moment prev is freshly finalized).
class_name Congestion extends SimSystem

## S8 in the ADR-0005 Signal Catalog — zero payload, once per tick after
## recompute+swap. Arity 0 (verified by unit test).
signal congestion_updated

## Von-Neumann 4-neighbor offsets for the density kernel splat (AC15).
const NEIGHBOR_DIRS: Array = [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]

## Config keys (data-driven per Control Manifest — defaults = GDD anchors).
const CONFIG_W_OCC := "w_occ"
const CONFIG_W_DENSE := "w_dense"
const CONFIG_ALPHA := "alpha"
const CONFIG_RADIUS := "R"
const CONFIG_D_MAX := "D_max"
const CONFIG_BETA := "beta"
const CONFIG_W_N := "w_n"
const CONFIG_D_CELL_MAX := "D_cell_max"

## Injected composition root (unused by this system; kept for signature
## symmetry with TimeSystem/MemberSim).
var _orchestrator: SimulationOrchestrator
## Injected SeededRNG registry — the sub-stream is registered here
## (ADR-0004) but NEVER drawn (TR-CONG-001 pure function).
var _seeded_rng: SeededRNG

## Hard upstream dependency (configured path): the typed grid read surface
## supplying placed instances + access cells (ADR-0003 — never duck-type).
var _grid: GridStateReader = null

## Hard upstream dependency (configured path): the MemberSim read surface.
## Duck-typed (mirroring MemberSim's own duck-typed `congestion_reader`
## seam) exposing exactly two public members:
##   reservations: Dictionary  equipment_instance_id -> {occupant: member_id?,
##                              next_claimant: member_id?}  (null = free)
##   members: Array            member records with "member_id", "state",
##                              "cell" (Vector2i) — post-move this tick
var _member_sim: Variant = null

## Story-003: injected Navigation for the event-driven access_reachable
## recompute (TR-CONG-005). Null in the pre-wiring / story-001 rigs —
## reachability simply does not engage (access_reachable stays empty).
var _navigation: Navigation = null

## Story-003: the level's single entrance cell — the path source for
## access_reachable (GDD Core Rule 5 / OQ4 single-entrance assumption,
## matching MemberSim). Vector2i(-1,-1) = not supplied (reachability off).
var _entrance_cell: Vector2i = Vector2i(-1, -1)

## Story-003: true when a grid_changed has arrived since the last batch
## flush. Consumed by _flush_grid_changes() at the start of the next
## on_tick — the batch boundary (AC16: never once per event).
var _grid_changed_pending: bool = false

## Story-003: the equipment ids present at the last observation (init or
## last grid_changed event). Diffed against the current placed set on each
## grid_changed to detect removals even when the payload says nothing about
## direction (S1 payload is cells, not ids).
var _last_known_ids: Dictionary = {}

# === Tuning values (GDD Tuning Knobs anchors; see class header) ===
var _w_occ: float = 0.7
var _w_dense: float = 0.3
var _alpha: float = 0.3
var _radius: int = 2
var _d_max: float = 3.0
var _beta: float = 0.4
var _w_n: float = 0.25
var _d_cell_max: float = 3.0

## Double-buffer: prev = authoritative Congestion(t-1) (read-only during a
## tick; what per_equipment_congestion serves); next = write target for the
## current tick, swapped in once at the end. Keyed by equipment_instance_id
## -> float in [0,1]. Exposed (not underscore) so the white-box AC5/AC6
## tests can drive partial computation directly, matching the codebase's
## observable-state convention (MemberSim exposes members/reservations).
var prev: Dictionary = {}
var next: Dictionary = {}

## Per-cell density field (Core Rule 4) — keyed by flat cell index
## (y * width + x, matching GridSystem.flat_index) so iteration in ascending
## flat index == ascending cell order, the fixed float-summation order.
##   raw_cells      — raw_cell(c,t) = Σ_m kernel(c, cell_m) for the CURRENT
##                    tick; transient (rebuilt every tick), exposed for the
##                    white-box AC15 kernel assertions.
##   smoothed_cells — smoothed(c,t) = β·raw + (1−β)·smoothed(c,t−1); the
##                    persistent EMA state story-004 serializes. Cells with
##                    no prior value start at 0.
##   density_cells  — density_cell(c,t) = clamp(smoothed/D_cell_max, 0, 1);
##                    the [0,1] output field the overlay reads.
var raw_cells: Dictionary = {}
var smoothed_cells: Dictionary = {}
var density_cells: Dictionary = {}

## Story-003: per-equipment access_reachable flag (TR-CONG-005) — keyed by
## equipment_instance_id -> bool. Event-driven: recomputed ONLY when
## grid_changed fires (batch-flushed once per tick), cached otherwise
## (AC12 zero path queries on a quiet tick). Removed equipment's entry is
## deleted the same tick (Core Rule 6). Exposed (not underscore) for the
## white-box AC13/AC16 tests, matching prev/next's convention.
var access_reachable: Dictionary = {}

## Per-tick counter. Kept from the SL-002 stub as an observable stand-in;
## the pre-wiring compatibility path increments it every tick (integration
## tests rely on the exact stub behaviour). Serialized with the blob.
var counter: int = 0


## Two-phase init (ADR-0001). Registers the Congestion RNG sub-stream
## exactly once (SeededRNG.register_system is the hard gate) — registration
## is kept because SaveLoad's AC7 tests iterate get_rng() over all four
## systems; the stream is never drawn from (TR-CONG-001).
##
## [grid] / [member_sim] are the state machine's hard upstream dependencies
## (configured path). Both optional with null defaults so the SL-002-era
## call sites `init(orchestrator, seeded_rng)` keep working — an instance
## without them is NOT configured and runs the pre-wiring compatibility
## path (see class header).
##
## [config] carries the data-driven tuning values (CONFIG_* keys); missing
## keys fall back to the GDD anchors.
##
## [navigation] / [entrance_cell] are story-003's reachability deps
## (TR-CONG-005). Both optional with null / (-1,-1) defaults so story-001
## rigs and the SL-002-era call sites keep working — reachability engages
## only when navigation + entrance_cell are supplied (plus grid).
func init(
	orchestrator: SimulationOrchestrator,
	seeded_rng: SeededRNG,
	grid: GridStateReader = null,
	member_sim: Variant = null,
	config: Dictionary = {},
	navigation: Navigation = null,
	entrance_cell: Vector2i = Vector2i(-1, -1)
) -> void:
	if not _mark_initialized():
		return
	_orchestrator = orchestrator
	_seeded_rng = seeded_rng
	_grid = grid
	_member_sim = member_sim
	_navigation = navigation
	_entrance_cell = entrance_cell
	_apply_config(config)
	_seeded_rng.register_system(system_name())
	_last_known_ids = _current_equipment_id_set() if _grid != null else {}
	# One-shot initial population (GDD Core Rule 7: "one-shot recompute on
	# load" allowance). Without it, equipment placed BEFORE init would read
	# access_reachable=false (flag absent) until the first grid_changed —
	# the overlay would misreport every machine as walled off at boot.
	if _can_compute_reachability():
		_recompute_access_reachable()


## Reads the [config] Dictionary into the tuning fields. Missing keys keep
## the GDD-anchor defaults (see class header). Values are coerced with
## float()/int() so a future JSON config file maps onto this shape directly.
## Guardrails: alpha and the weights are clamped to [0,1] (a misconfigured
## value must never break the EMA's output range — AC3); D_max gets a
## positive floor so a zero divisor can never produce NaN (GDD Edge Case:
## divide-by-zero guard); R is floored at 0.
func _apply_config(config: Dictionary) -> void:
	_w_occ = clampf(float(config.get(CONFIG_W_OCC, _w_occ)), 0.0, 1.0)
	_w_dense = clampf(float(config.get(CONFIG_W_DENSE, _w_dense)), 0.0, 1.0)
	_alpha = clampf(float(config.get(CONFIG_ALPHA, _alpha)), 0.0, 1.0)
	_radius = maxi(int(config.get(CONFIG_RADIUS, _radius)), 0)
	_d_max = maxf(float(config.get(CONFIG_D_MAX, _d_max)), 0.001)
	_beta = clampf(float(config.get(CONFIG_BETA, _beta)), 0.0, 1.0)
	_w_n = clampf(float(config.get(CONFIG_W_N, _w_n)), 0.0, 1.0)
	_d_cell_max = maxf(float(config.get(CONFIG_D_CELL_MAX, _d_cell_max)), 0.001)


func system_name() -> String:
	return "Congestion"


## Cross-system wiring phase (ADR-0001 two-phase init, Phase 2). Called by
## the orchestrator AFTER every system exists — subscribes to GridSystem's
## grid_changed (S1 in the ADR-0005 Signal Catalog) so access_reachable
## recomputes on layout change (story-003 / TR-CONG-005). Same pattern as
## Navigation._post_init(): the is_connected guard makes it idempotent.
##
## Subscription lifecycle: systems live for the session lifetime
## (orchestrator owns them), so no disconnect is needed (ADR-0005 negative
## consequence mitigation). Pre-wiring / story-001 rigs never call
## _post_init — reachability stays inert there (no subscription, no
## grid_changed handling).
func _post_init() -> void:
	assert(_initialized, "Congestion._post_init() called before init()")
	if _grid != null and not _grid.grid_changed.is_connected(_on_grid_changed):
		_grid.grid_changed.connect(_on_grid_changed)


## Story-003 S1 handler (grid_changed). The payload is CELLS, not ids, and
## says nothing about direction — so removals are detected by diffing the
## last-known id set against the current placed set (Core Rule 6 / AC9).
##
## CORE RULE 6 (AC9) — same-tick deletion: removed equipment's
## prev/next/access_reachable entries are erased HERE, immediately — not
## decayed, not deferred. The batch boundary only governs the (expensive)
## access_reachable RECOMPUTE, never the deletion: a removed-and-re-added id
## within one tick still gets a fresh entry (AC9 edge case), because the
## stale entry was already dropped by this handler.
##
## BATCHING (AC16): recompute happens in _flush_grid_changes() at the start
## of the next on_tick. Two grid_changed events in one tick therefore
## recompute access_reachable exactly once, against the final post-batch
## grid state — never once per event, never an intermediate state.
func _on_grid_changed(_footprint_cells_changed: Array, _access_cells_changed: Array) -> void:
	if not _assert_initialized():
		return
	_grid_changed_pending = true
	var current := _current_equipment_id_set()
	for instance_id in _last_known_ids:
		if not current.has(instance_id):
			# Core Rule 6: dropped the same tick — never decayed.
			prev.erase(instance_id)
			next.erase(instance_id)
			access_reachable.erase(instance_id)
	_last_known_ids = current


## True when every hard upstream dependency has been supplied, i.e. the
## real compute can run: a grid read surface (placed instances + access
## cells) and a MemberSim read surface (reservations + members). Until then
## on_tick() runs the pre-wiring compatibility path (class header).
func _is_configured() -> bool:
	return _grid != null and _member_sim != null


## Per-tick entry point — invoked SECOND in the orchestrator's fixed
## dispatch (FIXED_TICK_ORDER, after MemberSim, before Satisfaction).
## No await / yield inside: the tick boundary stays a safe save point
## (TR-TS-004).
##
## UNCONFIGURED PATH (pre-wiring compatibility, see class header): keeps
## the SL-002 stub's observable behavior (counter += 1; the rng_state stays
## at its registered initial value — this system never draws). NO RNG draw
## (TR-CONG-001 pure function).
##
## CONFIGURED PATH (Core Rules 1-3): reads the just-updated member state of
## tick t, computes each equipment's raw_i(t), EMA-blends it against
## prev[i], writes into next[i]; after ALL entities are processed, a single
## swap prev <- next; then emits congestion_updated (S8) exactly once.
##
## STORY-003 (TR-CONG-005): the tick start is the batch boundary for
## pending grid_changed events — _flush_grid_changes() drops removed
## equipment's entries and recomputes access_reachable once against the
## final grid state (AC9/AC13/AC16). A quiet tick (no grid_changed) makes
## flush a no-op and performs ZERO Navigation.get_path queries (AC12).
func on_tick(tick_count: int) -> void:
	if not _assert_initialized():
		return
	counter += 1
	_flush_grid_changes()
	if not _is_configured():
		return  # pre-wiring compatibility — no state to measure, no draw

	next = {}
	for instance_id in _ascending_equipment_ids():
		next[instance_id] = _compute_equipment(instance_id)
	# Single swap AFTER all entities processed (TR-CONG-002 / AC6).
	prev = next
	next = {}
	# Per-cell density field (Core Rule 4) — recompute completes BEFORE the
	# S8 emit so the overlay's signal handler reads the fresh field.
	_recompute_cell_density()
	congestion_updated.emit()


## The MemberSim-facing read surface (TR-CONG-003 / AC5 / AC6): returns the
## PREVIOUS tick's value from the `prev` buffer — never `next`, never a
## prev/next mix mid-computation. Unknown equipment ids (no entry yet, or
## equipment removed before story-003's grid_changed handling) read as 0.0
## (idle — the neutral starting value MemberSim's _congestion_value treats
## as "no congestion"). Defensively clamped to [0,1].
func per_equipment_congestion(instance_id: int) -> float:
	if not _assert_initialized():
		return 0.0
	return clampf(float(prev.get(instance_id, 0.0)), 0.0, 1.0)


## The overlay-facing read surface (Core Rule 4 / TR-CONG-004): returns the
## per-cell density in [0,1] for [cell] from the CURRENT tick's field (the
## state emitted via S8). Out-of-bounds cells and cells never touched read
## as 0.0. Defensively clamped.
func per_cell_density(cell: Vector2i) -> float:
	if not _assert_initialized():
		return 0.0
	if _grid == null:
		return 0.0
	var dims: Vector2i = _grid.get_dimensions()
	if cell.x < 0 or cell.x >= dims.x or cell.y < 0 or cell.y >= dims.y:
		return 0.0
	var idx := _cell_index(cell, dims.x)
	return clampf(float(density_cells.get(idx, 0.0)), 0.0, 1.0)


## Story-003 public read (TR-CONG-005): whether equipment [instance_id] has
## ANY path from the level entrance_cell to its first access cell
## (Navigation.get_path non-empty). Cached — recomputed only on grid_changed
## (see _flush_grid_changes). Unknown ids (removed equipment, never-seen)
## read as false — "not found" is a flag absence, not a stale value.
## This is the flag the Congestion/Flow Overlay (#8) surfaces
## default-visible when false.
func is_access_reachable(instance_id: int) -> bool:
	if not _assert_initialized():
		return false
	return bool(access_reachable.get(instance_id, false))


## Story-003 batch flush (AC9/AC13/AC16): processes the pending grid_changed
## batch at the tick boundary. Called at the start of on_tick — the one
## place grid-driven state converges, exactly once per tick.
##
## AC13/AC16: recompute access_reachable for the CURRENT equipment set
## exactly once per equipment, against the final post-batch grid state —
## never once per event, never an intermediate state. (Removal deletion
## already happened in the handler — Core Rule 6 same-tick.)
##
## Zero get_path calls when nothing is pending (AC12 — a quiet tick never
## touches Navigation). Reachability also requires navigation + entrance
## (story-001 rigs have neither); without them nothing happens here.
func _flush_grid_changes() -> void:
	if not _grid_changed_pending:
		return
	_grid_changed_pending = false
	if _can_compute_reachability():
		_recompute_access_reachable()


## Whether the reachability machinery is live: a grid read surface, a
## Navigation, and a real entrance cell all supplied. Story-001 rigs and
## pre-wiring instances fail this check — access_reachable stays empty.
func _can_compute_reachability() -> bool:
	return _grid != null and _navigation != null and _entrance_cell != Vector2i(-1, -1)


## Recomputed access_reachable for EVERY currently placed equipment — the
## affected set is the whole grid because any layout change can sever any
## path (a new wall anywhere can wall off a distant machine, AC13). One
## get_path per equipment, ascending-id order (fixed summation order, OQ2).
func _recompute_access_reachable() -> void:
	access_reachable = {}
	for instance_id in _ascending_equipment_ids():
		access_reachable[instance_id] = _equipment_reachable(instance_id)


## Single-equipment reachability: a non-empty Navigation.get_path from the
## level's single entrance_cell to the equipment's FIRST access cell
## (matching MemberSim's arrival semantics — access_cells[0]). Equipment
## with no access cell is never reachable.
func _equipment_reachable(instance_id: int) -> bool:
	var access_cells: Array[Vector2i] = _grid.get_access_cells(instance_id)
	if access_cells.is_empty():
		return false
	var path: Array[Vector2i] = _navigation.get_path(_entrance_cell, access_cells[0])
	return not path.is_empty()


## The current placed equipment id set (for removal diffing). Dictionary
## membership, never iteration order — determinism-safe.
func _current_equipment_id_set() -> Dictionary:
	var ids: Dictionary = {}
	if _grid == null:
		return ids
	for inst in _grid.get_placed_instances():
		ids[int(inst.instance_id)] = true
	return ids


## Returns the placed equipment ids in ASCENDING order — the fixed
## float-summation order TR-CONG-007 / OQ2 mandates (never hash/scene
## order). Iterates grid.get_placed_instances() and sorts the ids.
func _ascending_equipment_ids() -> Array[int]:
	var ids: Array[int] = []
	for inst in _grid.get_placed_instances():
		ids.append(int(inst.instance_id))
	ids.sort()
	return ids


## Computes Congestion_i(t) for one equipment instance (Core Rule 3):
##   occ_i = occupancy_state / 2; dens_i = clamp(N_i / D_max);
##   raw_i  = clamp(w_occ * occ_i + w_dense * dens_i);
##   result = clamp(alpha * raw_i + (1-alpha) * prev[i])
## AC3: with all inputs clamped [0,1] at every step the result is always a
## finite float in [0,1] (never NaN/negative/>1).
func _compute_equipment(instance_id: int) -> float:
	var occ_tier := _occupancy_state(instance_id)
	var n_i := _nearby_count(instance_id)
	var occ_f := float(occ_tier) / 2.0
	var dens := clampf(float(n_i) / _d_max, 0.0, 1.0)
	var raw := clampf(_w_occ * occ_f + _w_dense * dens, 0.0, 1.0)
	var c_prev := clampf(float(prev.get(instance_id, 0.0)), 0.0, 1.0)
	return clampf(_alpha * raw + (1.0 - _alpha) * c_prev, 0.0, 1.0)


## Occupancy tier for [instance_id] from MemberSim's reservation map
## (AC10): 0 free, 1 in-use (occupant), 2 in-use+queued (occupant +
## next_claimant). Queue depth is capped at 1 by MemberSim's claim rule, so
## the tier is structurally <= 2; clamped defensively anyway. Absent
## reservation record -> 0 (free). KEYED access only — never iterates the
## map (TR-MS-006 determinism).
func _occupancy_state(instance_id: int) -> int:
	var rec: Variant = null
	if _member_sim != null and (_member_sim.get("reservations") is Dictionary):
		rec = (_member_sim.get("reservations") as Dictionary).get(instance_id)
	if not (rec is Dictionary):
		return 0
	var tier := 0
	if rec.get("occupant", null) != null:
		tier += 1
	if rec.get("next_claimant", null) != null:
		tier += 1
	return clampi(tier, 0, 2)


## N_i(t): members within Chebyshev radius R of the equipment's FIRST
## access cell (matching MemberSim's arrival semantics — access_cells[0]),
## EXCLUDING the equipment's occupant and next_claimant (AC11 — no
## double-count even when they are physically within R), and excluding
## GONE members (removed at end of tick) and legacy roster entries without
## a state/cell. Count is an integer — order-independent by construction.
## Equipment with no access cell contributes no density (0).
func _nearby_count(instance_id: int) -> int:
	var access_cells: Array[Vector2i] = _grid.get_access_cells(instance_id)
	if access_cells.is_empty():
		return 0
	var anchor: Vector2i = access_cells[0]

	# AC11 exclusion set: this equipment's occupant + next_claimant ids.
	var excluded: Dictionary = {}
	var rec: Variant = null
	if _member_sim != null and (_member_sim.get("reservations") is Dictionary):
		rec = (_member_sim.get("reservations") as Dictionary).get(instance_id)
	if rec is Dictionary:
		if rec.get("occupant", null) != null:
			excluded[int(rec["occupant"])] = true
		if rec.get("next_claimant", null) != null:
			excluded[int(rec["next_claimant"])] = true

	var count := 0
	var members: Variant = _member_sim.get("members") if _member_sim != null else []
	if not (members is Array):
		return 0
	for m in members:
		if not (m is Dictionary) or not m.has("state") or not m.has("cell"):
			continue
		if str(m["state"]) == "GONE":
			continue
		var member_id := int(m["member_id"])
		if excluded.has(member_id):
			continue
		if _chebyshev(m["cell"] as Vector2i, anchor) <= _radius:
			count += 1
	return count


## Chebyshev distance (cells) — the same metric MemberSim uses for its
## density radius (_dist_cells) and the flow-hypothesis double.
static func _chebyshev(a: Vector2i, b: Vector2i) -> int:
	return maxi(absi(a.x - b.x), absi(a.y - b.y))


## Flat row-major cell index — MUST match GridSystem.flat_index (used by
## story-004 serialization); ascending flat index == ascending cell order.
static func _cell_index(cell: Vector2i, width: int) -> int:
	return cell.y * width + cell.x


## Per-cell density field recompute (Core Rule 4 / TR-CONG-004):
##   raw_cell(c,t)     = Σ_m kernel(c, cell_m(t))
##   kernel(c, c_m)    = 1 if c == c_m; w_n if c is a 4-neighbor; else 0
##   smoothed(c,t)     = β · raw_cell(c,t) + (1 − β) · smoothed(c,t−1)
##   density_cell(c,t) = clamp(smoothed(c,t) / D_cell_max, 0, 1)
##
## DETERMINISM (TR-CONG-007 / OQ2): members are splatted in ASCENDING
## member_id order (never the live array order), and the EMA pass iterates
## cells in ASCENDING flat index order — fixed float-summation order.
## A cell that receives no splat this tick still decays via the EMA term
## (smoothed = (1−β)·prev), so the field eases toward 0 instead of snapping
## (GDD Edge Case: zero members).
func _recompute_cell_density() -> void:
	var dims: Vector2i = _grid.get_dimensions()
	var width: int = dims.x
	var height: int = dims.y
	if width <= 0 or height <= 0:
		return

	# 1) Splat members (self + in-bounds 4-neighbors) in ascending id order.
	raw_cells = {}
	var members := _members_ascending()
	for m in members:
		_splat_member(m, width, height)

	# 2) EMA blend + normalize per cell, ascending flat index.
	for y in height:
		for x in width:
			var idx := y * width + x
			var raw := float(raw_cells.get(idx, 0.0))
			var prev_smoothed := float(smoothed_cells.get(idx, 0.0))
			var smoothed := _beta * raw + (1.0 - _beta) * prev_smoothed
			smoothed_cells[idx] = smoothed
			density_cells[idx] = clampf(smoothed / _d_cell_max, 0.0, 1.0)


## Returns the member records eligible for the density field, sorted by
## ASCENDING member_id (the fixed float-summation order). Records without a
## state/cell/member_id (legacy roster entries) and GONE members (removed at
## end of tick) are excluded — consistent with _nearby_count. The live
## MemberSim array is never mutated — a sorted COPY is returned.
func _members_ascending() -> Array:
	var members: Variant = _member_sim.get("members") if _member_sim != null else []
	if not (members is Array):
		return []
	var valid: Array = []
	for m in members:
		if not (m is Dictionary) or not m.has("state") or not m.has("cell") \
				or not m.has("member_id"):
			continue
		if str(m["state"]) == "GONE":
			continue
		valid.append(m)
	valid.sort_custom(func(a, b): return int(a["member_id"]) < int(b["member_id"]))
	return valid


## Splats ONE member's kernel into raw_cells (Core Rule 4): self gets 1.0,
## each IN-BOUNDS von-Neumann 4-neighbor gets w_n. Out-of-bounds neighbors
## are DROPPED — not wrapped, not clamped to the edge cell (AC15 / GDD Edge
## Case). The member's own cell is always on-grid (defensive skip otherwise).
func _splat_member(m: Dictionary, width: int, height: int) -> void:
	var cell: Vector2i = m["cell"] as Vector2i
	if cell.x < 0 or cell.x >= width or cell.y < 0 or cell.y >= height:
		return
	var idx := _cell_index(cell, width)
	raw_cells[idx] = float(raw_cells.get(idx, 0.0)) + 1.0
	for dir in NEIGHBOR_DIRS:
		var neighbor: Vector2i = cell + dir
		if neighbor.x < 0 or neighbor.x >= width or neighbor.y < 0 or neighbor.y >= height:
			continue
		var nidx := _cell_index(neighbor, width)
		raw_cells[nidx] = float(raw_cells.get(nidx, 0.0)) + _w_n


## Returns the full observable state as a JSON-safe Dictionary:
##   { counter: int, rng_state: "0x…" }
## The SHAPE is unchanged from the SL-002 stub for this story — story-004
## extends it with the prev buffer. The rng_state is the registered
## sub-stream's state; this system never draws, so it is the deterministic
## initial value (restores exactly). Pure read — no draws, no mutation.
func serialize() -> Dictionary:
	if not _assert_initialized():
		return {}
	return {
		"counter": counter,
		"rng_state": SeededRNG.int64_to_hex(_seeded_rng.get_rng(system_name()).state),
	}


## Two-phase deserialize (TR-SL-005, ADR-0002).
## Phase A validates EVERYTHING with zero mutation; Phase B commits only if
## Phase A passed. Failures are returned, never push_error'd (corrupt save =
## normal outcome). [validate_only] runs Phase A and returns the verdict
## without committing (SaveLoad Phase A protocol).
## Required fields (hard failure, no invented defaults):
##   counter (int), rng_state ("0x" hex string).
func deserialize(data: Dictionary, validate_only: bool = false) -> StubDeserializeResult:
	var result := StubDeserializeResult.new()
	if not _assert_initialized():
		return StubDeserializeResult.fail("Congestion.deserialize(): called before init()")

	# --- Phase A: validate (zero mutation) ---
	if not data.has("counter") or typeof(data["counter"]) != TYPE_INT:
		result.errors.append("Congestion: missing or invalid 'counter'")
	if not data.has("rng_state") or not data["rng_state"] is String:
		result.errors.append("Congestion: missing or invalid 'rng_state'")
	elif not str(data["rng_state"]).begins_with("0x") or not str(data["rng_state"]).is_valid_hex_number(true):
		result.errors.append("Congestion: rng_state must be a 0x hex string")

	if not result.errors.is_empty():
		return result  # Phase A failed — NOTHING was mutated

	result.ok = true
	if validate_only:
		return result  # validated, NOT committed (SaveLoad Phase A)

	# --- Phase B: commit (only if all valid) ---
	counter = int(data["counter"])
	_seeded_rng.get_rng(system_name()).state = SeededRNG.hex_to_int64(str(data["rng_state"]))
	return result
