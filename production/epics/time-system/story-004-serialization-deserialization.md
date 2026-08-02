# Story 004: Serialization, Deserialization, and Resume Behavior

> **Epic**: time-system
> **Status**: Ready
> **Layer**: Foundation
> **Type**: Integration
> **Estimate**: [hours or t-shirt size — fill before sprint planning]
> **Manifest Version**: 2026-07-23
> **Last Updated**: [set by /dev-story when implementation begins]

## Context

**GDD**: `design/gdd/time-system.md`
**Requirements**: `TR-TS-008`, `TR-TS-009`, `TR-TS-010`, `TR-TS-011`
*(Requirement text lives in `docs/architecture/tr-registry.yaml` — read fresh at review time)*

**ADRs Governing Implementation**: ADR-0002: Storage Format, ADR-0004: SeededRNG Architecture, ADR-0005: Signal Bus & Event Routing
**ADR Decision Summary**: Int64 values in save JSON must be hex strings (`0x` prefix). `JSON.stringify()` uses `full_precision=true` and `sort_keys=true`. RNG internal state restored directly via `rng.state = hex_to_int(state_hex)` — never re-derived from `master_seed` (re-deriving loses however many draws the system consumed pre-save). Load always resumes `paused=true` regardless of saved paused/speed fields (Core Rule 9). Missed required fields (master_seed, tick_count, per-system RNG entries) fail loudly with no invented defaults. Determinism contract: same master_seed + same tick sequence = bit-identical replay; pause duration and speed changes are explicitly NOT required inputs to this contract.

**Engine**: Godot 4.7.1 | **Risk**: MEDIUM
**Engine Notes**: `JSON.stringify()` requires `full_precision=true` in 4.7.1 to avoid float truncation for large ints. `int(some_int64)` in GDScript preserves full 64-bit range (no truncation). `RandomNumberGenerator.state` returns int64 — must be serialized as hex string per ADR-0002. `FileAccess.store_*()` returns `bool` since Godot 4.4 — always check the return value. GDScript `hex_to_int()` accepts `"0x"` prefix or bare hex. OQ2 caveat: if TICK_DURATION_SECONDS changes between save and load versions, existing saves' behavior is explicitly undefined for MVP.

**Control Manifest Rules (Foundation layer)**:
- Required: int64 serialized as hex strings; `full_precision=true` + `sort_keys=true`; RNG state restored directly (never re-derived); load always resumes PAUSED; two-phase validate-then-commit; missing fields = hard failure (no invented defaults)
- Forbidden: Never store int64 as bare decimal in JSON (JSON number precision is 53 bits, not 64); never re-derive RNG from master_seed on load; never auto-unpause on load
- Guardrail: round-trip test (AC8) must pass before merge; determinism test (AC9) must produce bit-identical output

---

## Acceptance Criteria

*From GDD `design/gdd/time-system.md`, scoped to this story:*

- [ ] AC8 [BLOCKING][Integration] GIVEN a running sim at tick_count=500 with distinct per-system RNG states, WHEN serialize() then deserialize() into a fresh TimeSystem instance, THEN tick_count, master_seed, speed_multiplier, paused, and the next 100 RNG draws per system are bit-identical to continuing the original instance (proves round-trip fidelity — the restored state IS the saved state)
- [ ] AC9 [BLOCKING][Integration] GIVEN two runs with identical master_seed to tick 1000, WHEN run A pauses 5s and run B pauses 300s at the same tick, THEN both produce bit-identical state/RNG output through tick 2000 after resuming (proves pause duration is NOT part of determinism contract)
- [ ] AC10 [BLOCKING][Integration] GIVEN a save with speed_multiplier=3, paused=false, WHEN deserialize() completes and the first _process() frame runs, THEN no ticks fire and paused == true, regardless of the saved paused/speed values (proves load-always-resumes-PAUSED — Core Rule 9)
- [ ] AC16 [BLOCKING][Logic] GIVEN a save blob missing one system's per_system_rng_states entry, WHEN deserialize() runs, THEN the entire load fails — no partial load, no silent re-derive-from-seed fallback
- [ ] AC17 [BLOCKING][Logic] GIVEN a save blob missing master_seed or tick_count, WHEN deserialize() runs, THEN the load fails loudly with no invented default

---

## Implementation Notes

*Derived from ADR-0002 + ADR-0004 + GDD Core Rules 7-9 + Formulas:*

**Serialize method on SeededRNG:**
```gdscript
# On SeededRNG (called by TimeSystem.serialize())
func serialize() -> Dictionary:
    var states := {}
    for system_name in _streams:
        states[system_name] = "0x%x" % _streams[system_name].state
    return {
        "master_seed": "0x%x" % master_seed,
        "per_system_rng_states": states,
    }
```

**Deserialize method on SeededRNG:**
```gdscript
# On SeededRNG (called by TimeSystem.deserialize())
# Two-phase: validate-then-commit — never mutate state in the validation phase.
func deserialize(data: Dictionary) -> DeserializeResult:
    var result := DeserializeResult.new()
    
    # Phase A: Validate (zero mutation)
    if not data.has("master_seed"):
        result.add_error("SeededRNG: missing 'master_seed' in save data")
        return result
    if not data.has("per_system_rng_states"):
        result.add_error("SeededRNG: missing 'per_system_rng_states' in save data")
        return result
    
    var master_seed_str: String = data["master_seed"]
    if not master_seed_str.begins_with("0x"):
        result.add_error("SeededRNG: master_seed must be hex string (0x prefix)")
        return result
    
    for system_name in _streams:
        if not data["per_system_rng_states"].has(system_name):
            result.add_error("SeededRNG: missing RNG state for system '%s'" % system_name)
            return result
    
    # Validate all hex strings parse before committing any state
    var parsed_states: Dictionary = {}
    for system_name in _streams:
        var state_hex: String = data["per_system_rng_states"][system_name]
        # hex_to_int returns 0 on garbage — validate prefix instead
        if not state_hex.begins_with("0x"):
            result.add_error("SeededRNG: RNG state for '%s' must be hex string (0x prefix)" % system_name)
            return result
        parsed_states[system_name] = state_hex.hex_to_int()
    
    # Phase B: Commit (only if all valid)
    master_seed = master_seed_str.hex_to_int()
    for system_name in parsed_states:
        _streams[system_name].state = parsed_states[system_name]
    
    result.ok = true
    return result
```

**Serialize method on TimeSystem:**
```gdscript
func serialize() -> Dictionary:
    var rng_data := _seeded_rng.serialize()
    return {
        "tick_count": tick_count,
        "tick_accumulator": tick_accumulator,
        "speed_multiplier": speed_multiplier,
        "paused": paused,
        "_last_speed": _last_speed,
        "master_seed": rng_data["master_seed"],
        "per_system_rng_states": rng_data["per_system_rng_states"],
    }
```

**Deserialize method on TimeSystem:**
```gdscript
class TimeSystemDeserializeResult extends RefCounted:
    var ok: bool = false
    var errors: Array[String] = []
    
    func add_error(msg: String) -> void:
        errors.append(msg)

func deserialize(data: Dictionary) -> TimeSystemDeserializeResult:
    var result := TimeSystemDeserializeResult.new()
    
    # Phase A: Validate (zero mutation)
    if not data.has("tick_count") or typeof(data["tick_count"]) != TYPE_INT:
        result.add_error("TimeSystem.deserialize: missing or invalid 'tick_count'")
        return result
    if not data.has("master_seed") or not data["master_seed"] is String:
        result.add_error("TimeSystem.deserialize: missing or invalid 'master_seed'")
        return result
    if not data.has("per_system_rng_states") or not data["per_system_rng_states"] is Dictionary:
        result.add_error("TimeSystem.deserialize: missing or invalid 'per_system_rng_states'")
        return result
    
    # Delegate RNG validation to SeededRNG (still Phase A — no mutation)
    var rng_result := _seeded_rng.deserialize({
        "master_seed": data["master_seed"],
        "per_system_rng_states": data["per_system_rng_states"],
    })
    if not rng_result.ok:
        for err in rng_result.errors:
            result.add_error(err)
        return result
    
    # Phase B: Commit (only if all valid)
    tick_count = data["tick_count"]
    tick_accumulator = data.get("tick_accumulator", 0.0)
    speed_multiplier = data.get("speed_multiplier", 1)
    _last_speed = data.get("_last_speed", 1)
    
    # Core Rule 9: load always resumes PAUSED
    paused = true
    speed_multiplier = 0
    
    # RNG state already committed by _seeded_rng.deserialize() above
    
    result.ok = true
    return result
```

**Key design decisions:**
- RNG state restored via `rng.state = hex_to_int()` — stores the exact advanced internal state, not the derived seed. This is draw-count-agnostic: it doesn't matter how many draws the RNG consumed pre-save, the restored state picks up exactly where the save left off.
- Load always sets `paused=true, speed_multiplier=0` *after* reading saved speed values into `_last_speed` — the player sees their last speed preserved but the sim is frozen (Core Rule 9, AC10).
- Two-phase deserialize pattern matches GridSystem's approach (ADR-0002): Phase A validates everything first (zero mutation), Phase B commits only if Phase A passed. This prevents partial-state corruption.
- All validation errors are collected — the first error does not short-circuit, so the caller sees all problems at once.
- `tick_accumulator` is optional in the deserialize payload (`data.get("tick_accumulator", 0.0)`) — a save at a tick boundary (the normal case) has `tick_accumulator ≈ 0.0`, and the fallback is safe.
- `JSON.stringify()` uses `full_precision=true, sort_keys=true` — but JSON serialization itself lives in SaveLoad (Story 004 of save-load). This story provides the `serialize()/deserialize()` methods that produce/consume native GDScript `Dictionary`; SaveLoad handles the JSON encoding.

---

## Out of Scope

*Handled by neighbouring stories — do not implement here:*

- [Story 003]: RNG sub-stream derivation — deserialize() restores state directly, never calls derive_sub_seed()
- [Story 001]: Two-phase init enforcement — deserialize() assumes _init() already completed
- [Story 002]: Tick accumulator and speed state machine — deserialize() restores their state but doesn't re-implement them
- [SaveLoad epic]: JSON encoding/decoding, file I/O, version checking — SaveLoad calls TimeSystem.serialize()/deserialize() as a coordination step; the JSON layer is SaveLoad's responsibility
- [Individual systems]: Downstream system deserialize() methods (GridSystem, MemberSim, etc.) — this story only covers TimeSystem + SeededRNG

---

## QA Test Cases

*Sourced from `production/qa/qa-plan-sprint-2-2026-08-02.md` — Automated Tests Required (TS-004). Authoritative test file: `tests/unit/time_system/time_serialization_test.gd` (~35 assertions).*

**What to test**:
- serialize() 输出 `{tick_count, master_seed, per_system_rng_states: {name: state}, speed_multiplier, paused}` 完整键
- deserialize() 恢复 RNG 内部状态（`rng.state = hex_to_int()` 直接恢复，非重派生）
- tick_count/speed_multiplier/paused 恢复
- Core Rule 9: 加载后始终 paused（无论存档 speed）
- 状态恢复后继续 tick 与未保存状态一致

**Edge cases**: RNG 状态已推进多步、paused=true 存档、speed=2x 存档

**Estimated assertions**: ~35

- **AC8**: 往返序列化保真度
  - Given: sim at tick_count=500 with all 4 tick systems registered and each having consumed draws from their RNG
  - When: `serialize()`, then construct a fresh TimeSystem with same registered systems, call `deserialize(data)`
  - Then: tick_count==500; master_seed identical; paused==true (load-always-paused); next 100 RNG draws per system match continuing the original (no deserialize); _last_speed preserved from saved speed_multiplier
  - Edge cases: test with 0 ticks (fresh sim); test with only 1 registered system vs all 4; test with tick_count at max safe int; verify that RNG state after deserialize produces identical next-draw to original

- **AC9**: 暂停时长不影响确定性
  - Given: two identical seeds, both run to tick 1000
  - When: run A pauses 5s equivalent (5 real seconds of _process with paused=true), run B pauses 300s equivalent (300s of paused _process); both resume
  - Then: at tick 2000, both have identical tick_count, identical per-system RNG states, identical accumulator values
  - Edge cases: test pause at different tick counts (not just 1000); test pause+speed-change while paused; test multiple pause/resume cycles

- **AC10**: 加载总是暂停
  - Given: save blob with speed_multiplier=3, paused=false
  - When: deserialize() completes, then first _process(delta) runs
  - Then: paused==true immediately after deserialize; speed_multiplier==0; no ticks fire during first _process; _last_speed==3 (preserved). Resume → ticks proceed at speed 3
  - Edge cases: test with saved speed=0, paused=true → still stays paused; test with saved speed=1, paused=true → last_speed=1; test resume() without ever having called set_speed → defaults to 1

- **AC16**: 缺失 RNG 子流状态 → 加载失败
  - Given: save blob where per_system_rng_states has "MemberSim" but is missing "Economy" (Economy was registered)
  - When: deserialize(data)
  - Then: result.ok == false; errors include "missing RNG state for system 'Economy'"; no RNG state mutated; tick_count unchanged; all existing RNG states untouched
  - Edge cases: test with empty per_system_rng_states ({}); test with extra unknown system entry in states (should be ignored, not an error — validates registered systems, not the dictionary keys)

- **AC17**: 缺失必需字段 → 加载失败
  - Given: save blob missing "master_seed" (but has tick_count and per_system_rng_states)
  - When: deserialize(data)
  - Then: result.ok == false; errors include "missing or invalid 'master_seed'"; no state mutated
  - Edge cases: test missing "tick_count"; test missing "per_system_rng_states"; test with master_seed=null; test with tick_count="string" (wrong type)

---

## Test Evidence

**Story Type**: Integration (crosses TimeSystem ↔ SeededRNG boundary) + Logic (AC16, AC17 are pure validation)
**Required evidence**:
- `tests/unit/time_system/time_serialization_test.gd` — must exist and pass (AC8, AC9, AC10, AC16, AC17)

**Status**: [ ] Not yet created

---

## Dependencies

- Depends on: Story 001 (Orchestrator container for _post_init wiring), Story 002 (tick_count + accumulator + speed state), Story 003 (SeededRNG registration — deserialize() restores state for already-registered systems)
- Unlocks: SaveLoad epic (SaveLoad calls TimeSystem.serialize()/deserialize() as the first step in its own save/load pipeline)
