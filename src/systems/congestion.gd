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
## DETERMINISM (TR-CONG-007 / OQ2): equipment iteration runs in ASCENDING
## equipment_instance_id order (sorted ids from grid.get_placed_instances()),
## never Dictionary/hash order. The reservations map is read by KEYED access
## only — never iterated (TR-MS-006 convention).
##
## AC10 (queue cap): occupancy_state derives from MemberSim's reservation
## map (occupant + next_claimant, queue depth 1 MVP) -> max tier 2,
## defensively clamped.
##
## S8 SIGNAL: congestion_updated — zero payload, emitted once per tick
## AFTER the swap completes (the moment prev is freshly finalized).
class_name Congestion extends SimSystem

## S8 in the ADR-0005 Signal Catalog — zero payload, once per tick after
## recompute+swap. Arity 0 (verified by unit test).
signal congestion_updated

## Config keys (data-driven per Control Manifest — defaults = GDD anchors).
const CONFIG_W_OCC := "w_occ"
const CONFIG_W_DENSE := "w_dense"
const CONFIG_ALPHA := "alpha"
const CONFIG_RADIUS := "R"
const CONFIG_D_MAX := "D_max"

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

# === Tuning values (GDD Tuning Knobs anchors; see class header) ===
var _w_occ: float = 0.7
var _w_dense: float = 0.3
var _alpha: float = 0.3
var _radius: int = 2
var _d_max: float = 3.0

## Double-buffer: prev = authoritative Congestion(t-1) (read-only during a
## tick; what per_equipment_congestion serves); next = write target for the
## current tick, swapped in once at the end. Keyed by equipment_instance_id
## -> float in [0,1]. Exposed (not underscore) so the white-box AC5/AC6
## tests can drive partial computation directly, matching the codebase's
## observable-state convention (MemberSim exposes members/reservations).
var prev: Dictionary = {}
var next: Dictionary = {}

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
func init(
	orchestrator: SimulationOrchestrator,
	seeded_rng: SeededRNG,
	grid: GridStateReader = null,
	member_sim: Variant = null,
	config: Dictionary = {}
) -> void:
	if not _mark_initialized():
		return
	_orchestrator = orchestrator
	_seeded_rng = seeded_rng
	_grid = grid
	_member_sim = member_sim
	_apply_config(config)
	_seeded_rng.register_system(system_name())


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


func system_name() -> String:
	return "Congestion"


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
func on_tick(tick_count: int) -> void:
	if not _assert_initialized():
		return
	counter += 1
	if not _is_configured():
		return  # pre-wiring compatibility — no state to measure, no draw

	next = {}
	for instance_id in _ascending_equipment_ids():
		next[instance_id] = _compute_equipment(instance_id)
	# Single swap AFTER all entities processed (TR-CONG-002 / AC6).
	prev = next
	next = {}
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
