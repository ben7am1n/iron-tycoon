# Story 001: SaveBlob Composition and Tick-Boundary Hook

> **Epic**: save-load
> **Status**: Complete
> **Layer**: Foundation
> **Type**: Integration
> **Estimate**: [hours or t-shirt size — fill before sprint planning]
> **Manifest Version**: 2026-07-23
> **Last Updated**: 2026-08-02

## Context

**GDD**: `design/gdd/save-load.md`
**Requirements**: `TR-SL-001`, `TR-SL-002`, `TR-SL-008`
*(Requirement text lives in `docs/architecture/tr-registry.yaml` — read fresh at review time)*

**ADRs Governing Implementation**: ADR-0002: Storage Format, ADR-0005: Signal Bus & Event Routing
**ADR Decision Summary**: SaveLoad is a pure coordinator (owns no state). Save blob is a flat Dictionary with one key per coordinated system: `{version, master_seed, time_system, grid_system, member_sim, congestion, satisfaction, economy}`. `master_seed` duplicated at top level for save-file introspection only — TimeSystem's copy is authoritative on load. Four systems contribute nothing: ZoneRules (stateless pure function), Navigation (rebuilt from GridSystem occupancy), PlacementSystem (instance_id counter re-derived from max occupant_id), SelectionSystem (mapping rebuilt from GridSystem). Tick-boundary saves are structural (not polled): SaveLoad subscribes to TimeSystem's `tick_completed(tick_count)` signal (S2), which fires at the end of each tick sequence. Because TimeSystem forbids mid-tick yielding, "between ticks" is a clean consistent snapshot for free — no runtime check needed.

**Engine**: Godot 4.7.1 | **Risk**: LOW
**Engine Notes**: `JSON.stringify()` requires `full_precision=true` in 4.7.1 — without it, large ints may be truncated. `JSON.parse_string()` is safe for self-written JSON (no authoring errors to catch with `JSON.new(); json.parse()`). `FileAccess.store_*()` returns `bool` since Godot 4.4 — every write must check the return value. `FileAccess.flush()` called before `f.close()` for durability.

**Control Manifest Rules (Foundation layer)**:
- Required: SaveLoad owns no state (pure coordinator); save blob is a flat Dictionary with one key per system; tick_completed signal subscription (not polling); 4 non-contributing systems must NOT appear in blob
- Forbidden: Never store Navigation/PlacementSystem/SelectionSystem/ZoneRules data in save blob; never call serialize() from anywhere other than a tick_completed handler (never mid-tick, never from _process directly)
- Guardrail: Save blob keys must be a fixed set — extra keys = load error (forward-compat gate); missing expected key = load error

---

## Acceptance Criteria

*From GDD `design/gdd/save-load.md`, scoped to this story:*

- [ ] AC1 [BLOCKING][Integration] GIVEN a save is requested (player action or autosave trigger), WHEN the save executes, THEN `serialize()` is called on all 6 coordinated systems only inside the `tick_completed` signal handler — verified by a spy that asserts no `serialize()` call occurs outside that handler (never mid-tick, never from `_process`, never from UI callback directly)
- [ ] AC-BLOB-1 [BLOCKING][Logic] GIVEN all 6 coordinated systems return valid serialize() data, WHEN SaveLoad.save() runs, THEN the returned blob has exactly keys `{version, master_seed, time_system, grid_system, member_sim, congestion, satisfaction, economy}` — no extra keys, none missing
- [ ] AC-BLOB-2 [BLOCKING][Logic] GIVEN SaveLoad.save() completes, WHEN the blob is inspected, THEN the top-level `master_seed` value matches `blob["time_system"]["master_seed"]` exactly (redundancy, not divergence)
- [ ] AC-BLOB-3 [BLOCKING][Logic] GIVEN SaveLoad.save() completes, WHEN the blob is inspected, THEN no key exists for `navigation`, `placement_system`, `selection_system`, or `zone_rules` — these 4 systems are absent from the blob entirely

---

## Implementation Notes

*Derived from ADR-0002 + ADR-0005 + GDD Core Rules 1-2:*

**SaveLoad class skeleton:**
```gdscript
class_name SaveLoad extends RefCounted

const SAVE_FORMAT_VERSION := 1

# Systems that contribute to the save blob (in stable serialize order)
var _time_system: TimeSystem
var _grid_system: GridSystem
var _member_sim  #: MemberSim — typed when GDD #6 exists
var _congestion  #: Congestion — typed when GDD #7 exists
var _satisfaction  #: Satisfaction — typed when GDD #10 exists
var _economy  #: Economy — typed when GDD #11 exists

# Systems that do NOT serialize but must be rebuilt on load
var _placement_system  # rederive_counter()
var _selection_system  # rebuild_mapping()
var _navigation  # rebuild(occupancy)

var _save_pending: bool = false
var _initialized: bool = false

func init(orchestrator: SimulationOrchestrator) -> void:
    if _initialized:
        assert(false, "SaveLoad.init() called twice")
        return
    _time_system = orchestrator.time_system
    _grid_system = orchestrator.grid_system
    _member_sim = orchestrator.member_sim
    _congestion = orchestrator.congestion
    _satisfaction = orchestrator.satisfaction
    _economy = orchestrator.economy
    _placement_system = orchestrator.placement_system
    _selection_system = orchestrator.selection_system
    _navigation = orchestrator.navigation
    _initialized = true

func _post_init() -> void:
    assert(_initialized, "SaveLoad._post_init() called before init()")
    # Subscribe to tick_completed for boundary-save guarantee
    if not _time_system.tick_completed.is_connected(_on_tick_completed):
        _time_system.tick_completed.connect(_on_tick_completed)
```

**Tick-boundary save hook:**
```gdscript
# Called by TimeSystem.tick_completed signal (S2) — at a tick boundary.
# Never called directly by UI or _process.
func _on_tick_completed(tick_count: int) -> void:
    if _save_pending:
        _save_pending = false
        _perform_save()
```

**Save request (public — called by UI):**
```gdscript
# Deferred save: sets a flag, actual save fires at next tick boundary.
# This is the ONLY public save entry point.
func request_save() -> void:
    _save_pending = true
    # If paused (no ticks will fire), save immediately — still at a boundary.
    if _time_system.is_paused():
        _save_pending = false
        _perform_save()

func _perform_save() -> Dictionary:
    assert(_initialized, "SaveLoad: not initialized")
    
    var blob := {
        "version": SAVE_FORMAT_VERSION,
        "master_seed": _time_system.serialize()["master_seed"],
        "time_system": _time_system.serialize(),
        "grid_system": _grid_system.serialize(),
        "member_sim": _member_sim.serialize(),
        "congestion": _congestion.serialize(),
        "satisfaction": _satisfaction.serialize(),
        "economy": _economy.serialize(),
    }
    return blob
```

**Systems that contribute NOTHING — verify at blob validation:**
```gdscript
const CONTRIBUTING_KEYS := [
    "version", "master_seed",
    "time_system", "grid_system",
    "member_sim", "congestion", "satisfaction", "economy",
]

const EXCLUDED_SYSTEMS := [
    "navigation", "placement_system", "selection_system", "zone_rules",
]

func _validate_blob_keys(blob: Dictionary) -> Array[String]:
    var errors: Array[String] = []
    
    # Required keys present
    for key in CONTRIBUTING_KEYS:
        if not blob.has(key):
            errors.append("SaveLoad: missing required key '%s' in save blob" % key)
    
    # Excluded systems absent
    for key in EXCLUDED_SYSTEMS:
        if blob.has(key):
            errors.append("SaveLoad: unexpected key '%s' in save blob — this system should not serialize" % key)
    
    # Master seed redundancy check
    if blob.has("master_seed") and blob.has("time_system"):
        if blob["master_seed"] != blob["time_system"]["master_seed"]:
            errors.append("SaveLoad: top-level master_seed diverges from TimeSystem's copy")
    
    return errors
```

**Key design decisions:**
- `request_save()` defers to next tick boundary via `_save_pending` flag — never calls serialize() directly. When paused (no ticks fire), saves immediately because the sim is already frozen at a tick boundary.
- `_on_tick_completed` is a private method connected via signal — no external code can trigger a save mid-tick.
- Save blob keys are a fixed set. Extra keys (future version added a system) = load error in Story 002's validation — forward-compat gate.
- `master_seed` redundancy: top-level copy is for save-file introspection only (readable without parsing TimeSystem's dict). TimeSystem's copy is authoritative — Story 002's load path reads from TimeSystem.
- The 4 excluded systems are verified at blob validation time, not just by convention — AC-BLOB-3 tests this.

---

## Out of Scope

*Handled by neighbouring stories — do not implement here:*

- [Story 002]: Load order, Phase A/B orchestration, validate/dry-run mode — this story only handles save composition
- [Story 003]: Round-trip determinism, resume-paused enforcement, RNG stream restoration — this story only collects serialize() output
- [Story 004]: File I/O (FileAccess), JSON encoding, version mismatch handling — this story produces a Dictionary; Story 004 writes it to disk
- [Individual systems]: Each system's serialize() implementation — SaveLoad only calls methods that already exist

---

## QA Test Cases

*Sourced from `production/qa/qa-plan-sprint-2-2026-08-02.md` — Automated Tests Required (SL-001). Authoritative test file: `tests/integration/save_load/saveblob_composition_test.gd` (~25 assertions).*

**What to test**:
- AC-BLOB-1: 返回 blob 恰有 8 键 `{version, master_seed, time_system, grid_system, member_sim, congestion, satisfaction, economy}` — 无多无缺
- AC-BLOB-2: 顶层 master_seed 与 time_system.master_seed 一致（冗余非分歧）
- AC-BLOB-3: navigation/placement_system/selection_system/zone_rules 4 系统缺席
- 保存仅在 tick 边界（TimeSystem no-mid-tick-yield 结构性保证）

**Edge cases**: 空状态保存、6 系统 serialize 部分失败

**Estimated assertions**: ~25

- **AC1**: 保存仅在 tick 边界执行
  - Given: spy on each coordinated system's serialize() method
  - When: request_save() called from UI; sim is running at 1x speed
  - Then: serialize() is NOT called inside request_save(); serialize() IS called inside _on_tick_completed() (or inside _perform_save when paused); called exactly once per save request
  - Edge cases: test save while paused (serialize called immediately in request_save — still at a boundary); test save→save without a tick between (should still work); test save during 8-tick clamp frame (serialize called after all 8 ticks complete, once)

- **AC-BLOB-1**: 保存 blob 键值完整
  - Given: all 6 systems return valid data
  - When: _perform_save() runs
  - Then: returned dict has exactly 8 keys (version, master_seed, time_system, grid_system, member_sim, congestion, satisfaction, economy)
  - Edge cases: test with a system returning empty dict (still valid — key exists); test key count after future system added (should catch extra key)

- **AC-BLOB-2**: master_seed 一致性
  - Given: save completes
  - When: blob inspected
  - Then: `blob.master_seed == blob.time_system.master_seed`
  - Edge cases: none — this is a strict equality check

- **AC-BLOB-3**: 不应序列化的系统
  - Given: save completes
  - When: blob inspected
  - Then: no key "navigation", "placement_system", "selection_system", "zone_rules"
  - Edge cases: verify that GridSystem (which IS included) didn't accidentally serialize Navigation data — separate concern tested in grid-system story-007

---

## Test Evidence

**Story Type**: Integration (crosses SaveLoad ↔ TimeSystem for signal hook, SaveLoad ↔ all 6 systems for blob composition)
**Required evidence**:
- `tests/integration/save_load/saveblob_composition_test.gd` — must exist and pass (AC1, AC-BLOB-1, AC-BLOB-2, AC-BLOB-3)

**Status**: [x] Created and passing — saveblob_composition_test.gd — 108 assertions, 0 failures; full suite 1789/0, exit 0 (2026-08-02)

---

## Dependencies

- Depends on: All 6 coordinated systems having serialize() methods (grid-system story-007, equipment-catalog loads once — no serialize needed, time-system story-004). TimeSystem tick_completed signal (time-system story-001).
- Unlocks: Story 002 (load orchestration needs the blob structure defined here)
