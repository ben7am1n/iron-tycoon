## Economy — balance and flat-fee revenue (Story ECON-001).
##
## Story: economy / story-001-balance-flat-fee-revenue.md
## Req:   TR-ECON-001 (tick-driven, runs after Satisfaction; deterministic,
##        no RNG), TR-ECON-002 (balance: int; revenue = flat fee R_visit per
##        quota-met completed visit), TR-ECON-003 (only quota-met departures
##        earn revenue; walk-failure/patience-exhaust earn $0), TR-ECON-004
##        (revenue contains zero reference to satisfaction — single-channel
##        throughput decoupling), TR-ECON-005 (starting_capital = $500;
##        balance floor 0; no upkeep)
## ADR:   ADR-0005 (Signal Bus — S5 member_completed_visit subscription, the
##        SOLE revenue trigger; S6 balance_changed emission with signed delta),
##        ADR-0006 (Economy credit interface — credit() lands in Story 003;
##        spend() is the deduction counterpart this story's AC1 QA requires)
##
## THIS FILE REPLACES THE SL-002 CORE-LAYER INTEGRATION STUB. The public
## contract surface SaveLoad depends on is preserved exactly:
##   - class_name Economy extends SimSystem
##   - init(orchestrator, seeded_rng) — optional data-driven config param
##     (backward-compatible; the pre-wiring save-load rigs call init(orch, srg))
##   - system_name() == "Economy"
##   - on_tick(tick_count) -> void  (the orchestrator's fixed dispatch, last)
##   - serialize() / deserialize(data, validate_only) two-phase protocol
##     (Phase A zero-mutation validate, Phase B commit), returning
##     StubDeserializeResult. Story 004 owns the FINAL serialized shape:
##     {balance} ONLY (GDD Core Rule 7 — no derived state, a trivial exact
##     round-trip). The stub-era keys {counter, rng_state} are DROPPED from
##     the payload; deserialize still TOLERATES them when present so old
##     SL-002/SL-003-era blobs load unchanged.
##
## REVENUE ARCHITECTURE (ADR-0005 §3): income is signal-driven, NOT applied
## in on_tick(). MemberSim emits member_completed_visit (S5) synchronously
## while a quota-met member transitions to GONE during MemberSim's own tick;
## Economy's subscribed handler accrues immediately. Economy.on_tick() is
## therefore a no-op pass (the slot exists to satisfy the fixed dispatch
## order — GDD Core Rule 1). Because accrual is a pure commutative sum
## (balance += R_visit per event), multi-departure ticks need no fold order
## (AC9 — unlike Satisfaction's EMA).
##
## DETERMINISM (GDD Core Rule 1): no RNG draws anywhere in the revenue path.
## The "Economy" sub-stream is still REGISTERED in init() because the
## save-load AC7 tests read get_rng("Economy") and require its state to
## round-trip; it simply never advances. TimeSystem.serialize() carries ALL
## registered streams in per_system_rng_states (Economy included), so the
## AC7 round-trip is preserved through TimeSystem's payload — Economy's own
## {balance}-only payload needs no rng_state copy.
##
## PRE-WIRING COMPATIBILITY PATH (documented, not silent): the SL-002/003
## save-load integration tests construct Economy with init(orch, srg) and
## NEVER call _post_init() — so no S5 subscription exists in those rigs and
## balance stays exactly as the test set it (e.g. 500). The subscription
## engages only when the composition root wires _post_init() (or a test does).
class_name Economy extends SimSystem

## S6 in the ADR-0005 Signal Catalog. Fires after EVERY balance mutation
## (income, spend) with the signed delta — HUD animates direction from it
## (negative = spend, positive = revenue). Arity: exactly 2 ints.
signal balance_changed(new_balance: int, delta: int)

## GDD Core Rule 3 — enough for two 1×1 machines at $200 each.
const STARTING_CAPITAL := 500

## GDD Formulas — flat cash per completed visit (provisional anchor, safe
## 8–20). NO satisfaction multiplier (TR-ECON-004 — double-count guard).
const R_VISIT := 12

## Data-driven config seam (coding standard: gameplay values never hardcoded).
## init(orchestrator, seeded_rng, config) reads these; absent keys fall back
## to the GDD anchors above.
const CONFIG_R_VISIT := "r_visit"
const CONFIG_STARTING_CAPITAL := "starting_capital"

## Injected composition root — kept for the _post_init() S5 wiring (the
## orchestrator owns member_sim; ADR-0001).
var _orchestrator: SimulationOrchestrator
## Injected SeededRNG registry — the (never-advanced) sub-stream lives here
## (ADR-0004 / save-load AC7 contract).
var _seeded_rng: SeededRNG

## Per-tick progression counter — the stub-era observable, preserved as a
## RUNTIME-ONLY tick counter (the ECON-001 no-decay test reads it). NOT
## gameplay state and NOT serialized: the ledger's observable IS balance
## (Story 004 — the serialized payload is {balance} only).
var counter: int = 0

## The player's cash — the system's entire gameplay state. int (never float,
## GDD Core Rule 1 — no drift/rounding across ticks and saves). Floor 0,
## no ceiling. Starts at STARTING_CAPITAL (AC11).
var balance: int = STARTING_CAPITAL

## Per-visit flat fee — configurable via config["r_visit"], defaults to the
## GDD anchor.
var _r_visit: int = R_VISIT


## Two-phase init (ADR-0001). Stores the injected dependencies, applies the
## optional data-driven config, and registers the "Economy" RNG sub-stream
## exactly once (assert on duplicate — SeededRNG.register_system is the hard
## gate). The stream is registered for the save-load AC7 contract but NEVER
## drawn from: revenue is fully deterministic (GDD Core Rule 1).
func init(orchestrator: SimulationOrchestrator, seeded_rng: SeededRNG, config: Dictionary = {}) -> void:
	if not _mark_initialized():
		return
	_orchestrator = orchestrator
	_seeded_rng = seeded_rng
	_apply_config(config)
	_seeded_rng.register_system(system_name())


## Reads the [config] Dictionary into the tuning fields. Missing keys keep
## the GDD anchors (see class header). Coerced with int() so a future JSON
## config file maps onto this shape directly.
func _apply_config(config: Dictionary) -> void:
	_r_visit = int(config.get(CONFIG_R_VISIT, _r_visit))
	if config.has(CONFIG_STARTING_CAPITAL):
		balance = int(config[CONFIG_STARTING_CAPITAL])


func system_name() -> String:
	return "Economy"


## Cross-system wiring (ADR-0005 §3): subscribes to MemberSim's S5
## member_completed_visit — the SOLE revenue trigger. Runs at orchestrator
## Phase 2 after all systems exist. Null-safe: pre-wiring rigs that never
## supply member_sim simply skip the subscription (their balance stays as
## set — the documented save-load compatibility path).
func _post_init() -> void:
	if _orchestrator == null or _orchestrator.member_sim == null:
		return
	_orchestrator.member_sim.member_completed_visit.connect(on_member_completed_visit)


## Per-tick entry point — LAST in the orchestrator's FIXED_TICK_ORDER
## (MemberSim → Congestion → Satisfaction → Economy; GDD Core Rule 1).
## No gameplay work here: income already accrued synchronously via S5 during
## MemberSim's tick. counter advances so the stub-era serialize shape stays
## deterministic and byte-identical across control/restored runs.
func on_tick(tick_count: int) -> void:
	if not _assert_initialized():
		return
	counter += 1


## S5 handler — revenue accrual (TR-ECON-002, AC8/AC9/AC13).
##
## MemberSim guarantees this fires ONLY for quota-met departures (walk-failure
## and patience-exhausted never emit S5 — ADR-0005 §3), so this single entry
## point IS the AC14 gate: non-quota departures earn $0 because they never
## reach Economy. balance += R_visit is a pure commutative sum, so N events
## on one tick produce exactly N × R_visit with no fold order (AC9).
func on_member_completed_visit(member_id: int) -> void:
	if not _assert_initialized():
		return
	balance += _r_visit
	balance_changed.emit(balance, _r_visit)


## Affordability query (GDD Core Rule 5 / AC5) — the Shop pre-check gate in
## spend()'s triple-gating chain (defense in depth). Pure read: returns
## whether [amount] could be spent right now. NEVER mutates balance and never
## emits balance_changed (no signal — it is a query, not a transaction).
## Rejects amount <= 0 (returns false) — mirrors spend()'s gate (a), so
## can_afford(-100) can never be misread as "the balance could absorb a
## negative spend".
func can_afford(amount: int) -> bool:
	if not _assert_initialized():
		return false
	if amount <= 0:
		return false
	return balance >= amount


## Spend interface (GDD Core Rule 5 / AC2–AC5) — the deduction counterpart to
## ADR-0006's credit() (which lands in Story 003). Economy-side gates:
##   (a) amount > 0          — rejects zero/negative (prevents the
##                             negative-amount exploit where spend(-100) would
##                             pass amount <= balance and INCREASE the balance)
##   (b) amount <= balance    — the affordability gate (AC2: overspend returns
##                             false, balance unchanged)
##   (c) Shop pre-checks can_afford() before calling — the third gate in the
##                             chain, owned by the caller (defense in depth;
##                             AC5 pins the can_afford/spend consistency)
## On success: balance -= amount, emit balance_changed(new, -amount). On any
## rejection: returns false with ZERO mutation and NO signal.
func spend(amount: int) -> bool:
	if not _assert_initialized():
		return false
	if amount <= 0:
		return false
	if amount > balance:
		return false
	balance = maxi(balance - amount, 0)  # defensive floor (GDD Core Rule 3) —
	# unreachable: the affordability gate guarantees balance - amount >= 0
	balance_changed.emit(balance, -amount)
	return true


## Credit interface (ADR-0006 §1 / Story ECON-003) — the symmetric counterpart
## to spend(): ADDS [amount] to balance (Path B: SelectionSystem's sell refund,
## milestone rewards, debug commands — anything that puts money IN).
##   (a) amount > 0        — rejects zero/negative (symmetric with spend()'s
##                           gate; prevents the negative-amount exploit where
##                           credit(-100) would be a hidden deduction)
##   (b) no affordability gate — credit has no upper bound by design (the
##       asymmetry in ADR-0006 §2: spend checks affordability because the
##       player must HAVE the money; credit has no "can this be credited?"
##       check because balance has no ceiling)
## On success: balance += amount, emit balance_changed(new, +amount) with a
## POSITIVE delta (HUD animates direction from the sign). On rejection:
## push_warning + return false with ZERO mutation and NO signal.
## [reason] is a debug/audit-only label (e.g. "sell:instance_5") — NO
## gameplay effect. Economy never computes refunds: the refund formula
## (floor(0.5 × original_cost), REFUND_RATE = 0.5) belongs to
## SelectionSystem's sell logic (ADR-0006 §3) — Economy accepts whatever
## amount the caller provides and never knows equipment prices or fees.
## Never call spend(-refund) as a credit workaround — spend()'s amount <= 0
## guard already blocks it (the guard above makes a negative spend a no-op).
func credit(amount: int, reason: String) -> bool:
	if not _assert_initialized():
		return false
	if amount <= 0:
		push_warning("Economy.credit() rejected: amount=%d must be > 0 (reason: %s)" % [amount, reason])
		return false
	balance += amount
	balance_changed.emit(balance, +amount)
	return true


## Returns the ENTIRE ledger state as a JSON-safe Dictionary:
##   { balance: int }
## GDD Core Rule 7 / Story 004 — serialize ONLY balance: no derived state,
## a trivial exact round-trip (no reconstruction ambiguity). The stub-era
## keys {counter, rng_state} are deliberately absent (counter is a runtime
## tick observable, not gameplay state; the Economy RNG stream never
## advances and round-trips through TimeSystem's per_system_rng_states).
## Pure read — no draws, no mutation (SL-001 AC1 counts serialize calls, so
## serialize stays side-effect free).
func serialize() -> Dictionary:
	if not _assert_initialized():
		return {}
	return {
		"balance": balance,
	}


## Two-phase deserialize (TR-SL-005, ADR-0002).
## Phase A validates EVERYTHING with zero mutation; Phase B commits only if
## Phase A passed. Failures are returned, never push_error'd (corrupt save =
## normal outcome). [validate_only] runs Phase A and returns the verdict
## without committing (SaveLoad Phase A protocol).
## Required field (hard failure, no invented defaults):
##   balance (int — or float for JSON ints, see below).
## The stub-era keys {counter, rng_state} are TOLERATED if present (old
## SL-002/SL-003-era blobs load unchanged — Story 004 schema change is
## coordinated with the save-load integration tests), but they are NOT
## committed: counter is a runtime observable that restarts from 0, and the
## RNG stream state is owned by TimeSystem's per_system_rng_states.
## balance accepts int|float: JSON.parse returns integer literals as float
## in 4.7.1 (verified — the save-load file tests' JSON round-trip), so a
## saved balance 500 arrives as 500.0. A float with a fractional part is
## REJECTED (balance is whole currency units — GDD Core Rule 1).
func deserialize(data: Dictionary, validate_only: bool = false) -> StubDeserializeResult:
	var result := StubDeserializeResult.new()
	if not _assert_initialized():
		return StubDeserializeResult.fail("Economy.deserialize(): called before init()")

	# --- Phase A: validate (zero mutation) ---
	if not data.has("balance") or not _is_valid_balance(data["balance"]):
		result.errors.append("Economy: missing or invalid 'balance'")

	if not result.errors.is_empty():
		return result  # Phase A failed — NOTHING was mutated

	result.ok = true
	if validate_only:
		return result  # validated, NOT committed (SaveLoad Phase A)

	# --- Phase B: commit (only if all valid) ---
	balance = int(data["balance"])
	return result


## True when [v] is a valid balance: an int, or a float that is finite and
## integral (JSON.parse returns integer literals as float in 4.7.1 — the
## file round-trip shape). A fractional float (e.g. 12.5) is REJECTED:
## balance is whole currency units (GDD Core Rule 1) and silently truncating
## a corrupt save would be an invented value, not a restore.
func _is_valid_balance(v: Variant) -> bool:
	if typeof(v) == TYPE_INT:
		return true
	if typeof(v) == TYPE_FLOAT:
		var f := float(v)
		return is_finite(f) and f == floor(f)
	return false
