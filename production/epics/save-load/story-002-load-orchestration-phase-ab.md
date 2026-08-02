# Story 002: Load Orchestration — Phase A/B and Load Order

> **Epic**: save-load
> **Status**: Complete
> **Layer**: Foundation
> **Type**: Integration
> **Estimate**: [hours or t-shirt size — fill before sprint planning]
> **Manifest Version**: 2026-07-23
> **Last Updated**: 2026-08-02

## Context

**GDD**: `design/gdd/save-load.md`
**Requirements**: `TR-SL-003`, `TR-SL-004`, `TR-SL-005`
*(Requirement text lives in `docs/architecture/tr-registry.yaml` — read fresh at review time)*

**ADRs Governing Implementation**: ADR-0001: DI Container & Scene Bootstrap, ADR-0002: Storage Format, ADR-0007: AStarGrid2D Determinism
**ADR Decision Summary**: Load order is enforced programmatically in one method — not by convention or configuration. Two-phase load: Phase A (validate, zero mutation) runs every system's `deserialize()` in dry-run mode in load order; any failure aborts with no mutation to any system. Phase B (commit) re-runs `deserialize()` for real only after all Phase A validations pass. Load order: TimeSystem → GridSystem → PlacementSystem.rederive_counter → SelectionSystem.rebuild_mapping → Navigation.rebuild → MemberSim → Congestion → Satisfaction → Economy. GridSystem must land first (everything references its occupancy). PlacementSystem/Navigation/SelectionSystem are derivation/rebuild steps wedged between Grid and its dependents. ZoneRules needs no step (stateless pure function). Navigation's AStarGrid2D cross-rebuild determinism is proven (ADR-0007 gate PASSED, 10/10 processes bit-identical).

**Engine**: Godot 4.7.1 | **Risk**: MEDIUM
**Engine Notes**: ADR-0007 gate test must remain in CI and re-run on every Godot version bump — the AStarGrid2D tie-break being bit-identical is load-bearing for save determinism. Navigation rebuild via `set_point_solid()` + `update()` per cell — use the corrected pattern for 4.7.1 where `fill_solid_region`→`update()` was bugged (prefer per-cell `set_point_solid`). No new engine risk specific to SaveLoad.

**Control Manifest Rules (Foundation layer)**:
- Required: Load order hardcoded in one method (not data-driven, not convention-based); Phase A never mutates any system state; Phase A passes system data plus derived context (e.g., Phase B must pass `buildable_snapshot` to GridSystem); Phase B only runs if Phase A passes all systems
- Forbidden: Never skip Phase A (even for "simple" systems); never commit partial state (if Phase B step 3 fails, undo steps 1-2 — or better, validate so thoroughly in Phase A that Phase B failure is treated as fatal-to-menu); never load in an order that differs from the documented sequence
- Guardrail: Load must complete within 500ms for MVP grid (130 cells, ~20 equipment); Navigation's `update()` perf is documented in ADR-0007

---

## Acceptance Criteria

*From GDD `design/gdd/save-load.md`, scoped to this story:*

- [ ] AC3 [BLOCKING][Integration] GIVEN a save blob with any Phase-A validation failure (e.g., corrupt grid data, missing RNG state, member referencing absent equipment), WHEN load() runs, THEN the current/fresh session is left completely unmutated — all systems retain their pre-load state, no partial writes
- [ ] AC4 [BLOCKING][Integration] GIVEN the load sequence, WHEN it runs, THEN deserialize/rebuild order is enforced programmatically — PlacementSystem's counter re-derive and Navigation's rebuild cannot execute before GridSystem.deserialize() completes; a test that reorders the calls must fail at the assertion level (not just documentation)
- [ ] AC9 [BLOCKING][Logic] GIVEN a save blob where a member references an equipment_instance_id absent from the loaded/validated grid, WHEN Phase A validates MemberSim, THEN the whole load fails — no silent orphan member, no partial load (Core Rule 2 of save-load.md + AC9)

---

## Implementation Notes

*Derived from ADR-0001 + ADR-0002 + GDD Core Rules 3-4:*

**Load orchestration — Phase A + Phase B in one method:**
```gdscript
class LoadResult extends RefCounted:
    var ok: bool = false
    var errors: Array[String] = []

class_name SaveLoad extends RefCounted
# ... (continued from Story 001) ...

# buildable_snapshot is provided by the level loader — never from the save blob.
func load(save_blob: Dictionary, buildable_snapshot: PackedByteArray) -> LoadResult:
    var result := LoadResult.new()
    assert(_initialized, "SaveLoad: not initialized")
    
    # --- Phase A: Validate (zero mutation) ---
    var phase_a_errors := _validate_all(save_blob, buildable_snapshot)
    if not phase_a_errors.is_empty():
        for err in phase_a_errors:
            result.errors.append(err)
        return result  # no mutation
    
    # --- Phase B: Commit (all validations passed) ---
    # Order is load-bearing — see GDD Core Rule 3.
    
    # 1. TimeSystem — restores RNG streams + tick_count; forces paused=true
    var ts_result := _time_system.deserialize(save_blob["time_system"])
    if not ts_result.ok:
        # Should not happen after Phase A — treat as fatal
        result.errors.append("FATAL: TimeSystem Phase B failed after Phase A passed")
        return result
    
    # 2. GridSystem — geometric ground truth; needs buildable from level loader
    var gs_result := _grid_system.deserialize(save_blob["grid_system"], buildable_snapshot)
    if not gs_result.ok:
        result.errors.append("FATAL: GridSystem Phase B failed after Phase A passed")
        return result
    
    # 3. PlacementSystem — re-derive instance_id counter from loaded grid
    _placement_system.rederive_counter()
    
    # 3a. SelectionSystem — rebuild instance_id→equipment mapping from grid
    _selection_system.rebuild_mapping()
    
    # 4. Navigation — rebuild AStarGrid2D from GridSystem occupancy
    _navigation.rebuild(_grid_system)
    
    # 5. MemberSim — members reference equipment_instance_ids from step 2
    var ms_result := _member_sim.deserialize(save_blob["member_sim"])
    if not ms_result.ok:
        result.errors.append("FATAL: MemberSim Phase B failed after Phase A passed")
        return result
    
    # 6. Congestion — prev buffer + per-cell smoothed; access_reachable recomputed
    var cong_result := _congestion.deserialize(save_blob["congestion"])
    if not cong_result.ok:
        result.errors.append("FATAL: Congestion Phase B failed after Phase A passed")
        return result
    
    # 7. Satisfaction — global_satisfaction + member_accumulators
    var sat_result := _satisfaction.deserialize(save_blob["satisfaction"])
    if not sat_result.ok:
        result.errors.append("FATAL: Satisfaction Phase B failed after Phase A passed")
        return result
    
    # 8. Economy — balance
    var econ_result := _economy.deserialize(save_blob["economy"])
    if not econ_result.ok:
        result.errors.append("FATAL: Economy Phase B failed after Phase A passed")
        return result
    
    result.ok = true
    return result
```

**Phase A validation — collects ALL errors, never mutates:**
```gdscript
func _validate_all(save_blob: Dictionary, buildable_snapshot: PackedByteArray) -> Array[String]:
    var errors: Array[String] = []
    
    # Blob structure validation (from Story 001)
    var blob_errors := _validate_blob_keys(save_blob)
    errors.append_array(blob_errors)
    if not errors.is_empty():
        return errors  # can't proceed without valid keys
    
    # 1. TimeSystem — validate (dry-run)
    #    Each system's deserialize() is called with validate_only=true in Phase A.
    #    The contract: when validate_only=true, the system checks all fields but
    #    mutates NOTHING. Returns the same result shape as real deserialize.
    var ts_errors := _time_system.deserialize(save_blob["time_system"], true).errors \
        if _time_system.has_method("deserialize") else ["TimeSystem missing deserialize()"]
    errors.append_array(ts_errors)
    if not errors.is_empty():
        return errors  # TimeSystem must pass — nothing else can be validated without it
    
    # 2. GridSystem — validate with buildable
    var gs_errors := _grid_system.deserialize(save_blob["grid_system"], buildable_snapshot, true).errors
    errors.append_array(gs_errors)
    if not errors.is_empty():
        return errors  # GridSystem must pass — nothing references its occupancy without it
    
    # 3-8. Remaining systems — each called with validate_only=true
    var ms_errors := _member_sim.deserialize(save_blob["member_sim"], true).errors
    errors.append_array(ms_errors)
    
    var cong_errors := _congestion.deserialize(save_blob["congestion"], true).errors
    errors.append_array(cong_errors)
    
    var sat_errors := _satisfaction.deserialize(save_blob["satisfaction"], true).errors
    errors.append_array(sat_errors)
    
    var econ_errors := _economy.deserialize(save_blob["economy"], true).errors
    errors.append_array(econ_errors)
    
    return errors
```

**Load order enforcement — programmatic assertion:**
```gdscript
# The load() method above hardcodes the order. To verify it's never
# accidentally reordered, the test (AC4) should:
# 1. Spy on each system's deserialize/rebuild method
# 2. Call load()
# 3. Assert call order matches the documented sequence
# 4. Assert no call to a dependent system occurs before its prerequisite

func _verify_load_order() -> void:
    # This is a test helper, not production code.
    # In the real code, the order is enforced by being hardcoded in load().
    # This function exists so AC4 can assert the order without mocking.
    pass  # Test verifies via spy/mock on load() calls
```

**Key design decisions:**
- Load order is hardcoded in one method — not configurable, not data-driven, not convention-based. A test (AC4) verifies the order programmatically.
- Phase A does NOT create temporary copies of systems — it calls each system's `deserialize()` in dry-run mode (`validate_only=true`). This is cheaper than duplicating state and avoids the memory cost of "validate into fresh instances then swap."
- Phase B failures after Phase A passes are treated as `FATAL` — they should be impossible (Phase A validated everything). If they occur, it's a bug, not a recoverable error.
- `buildable_snapshot` is a parameter to `load()` — it comes from the level loader, never from the save blob. This keeps level geometry out of save files (TR-GS-020).
- Navigation rebuild uses `_navigation.rebuild(_grid_system)` — a single method that iterates all cells and calls `set_point_solid()` — to avoid the 4.7.1 `fill_solid_region`→`update()` bug documented in ADR-0007.

---

## Out of Scope

*Handled by neighbouring stories — do not implement here:*

- [Story 001]: Save blob composition — load() consumes the blob structure defined there
- [Story 003]: Round-trip determinism verification — this story implements the load pipeline; Story 003 verifies it produces identical state
- [Story 004]: File I/O, JSON encoding, version checking — load() receives an already-parsed Dictionary
- [Individual systems]: Each system's validate-only deserialize() implementation — SaveLoad defines the protocol; each system implements it

---

## QA Test Cases

*Sourced from `production/qa/qa-plan-sprint-2-2026-08-02.md` — Automated Tests Required (SL-002). Authoritative test file: `tests/integration/save_load/load_orchestration_test.gd` (~30 assertions).*

**What to test**:
- Phase A: 所有系统 validate-only 模式零变更运行
- Phase B: 全部通过后按序提交
- 加载顺序程序化强制（TimeSystem → GridSystem → Placement.rederive → Selection.rebuild → Navigation.rebuild → MemberSim → Congestion → Satisfaction → Economy）
- 任一失败 → 整体中止，当前会话零变更（all-or-nothing）
- Phase B 失败 → fatal-to-menu（不应发生）

**Stub 方案**: MemberSim/Congestion/Satisfaction/Economy 用最小 serialize/deserialize stub（推进 RNG 状态 + 递增计数），标记为 Core 层集成点

**Edge cases**: 中间系统 validate 失败、网格数据冲突、引用不存在的 equipment_instance_id

**Estimated assertions**: ~30

- **AC3**: 全有或全无——验证失败则零变异
  - Given: fresh session with known state; corrupt save blob (missing MemberSim RNG state, or GridSystem Phase A fails)
  - When: load(corrupt_blob, buildable)
  - Then: result.ok == false; result.errors non-empty; ALL 6 systems retain pre-load state (tick_count, grid occupancy, member count, balance — all unchanged)
  - Edge cases: test with TimeSystem validation failing (should abort before GridSystem is called); test with GridSystem validation failing (should abort before MemberSim is called); test with only Economy validation failing (all prior steps pass Phase A, but commit never reaches them); test that a validation failure in system 5 does not leave systems 1-4 partially committed

- **AC4**: 加载顺序程序化强制执行
  - Given: spy/mock on all system deserialize/rebuild methods
  - When: load() called with valid blob
  - Then: recorded call sequence = [TimeSystem.deserialize, GridSystem.deserialize, PlacementSystem.rederive_counter, SelectionSystem.rebuild_mapping, Navigation.rebuild, MemberSim.deserialize, Congestion.deserialize, Satisfaction.deserialize, Economy.deserialize]; no call appears before its prerequisite
  - Edge cases: this test should FAIL if the order in load() is ever rearranged — that's the point

- **AC9**: 成员引用缺失的设备 → 加载失败
  - Given: save blob where MemberSim has a member with equipment_instance_id=99, but GridSystem's occupant_id data has no instance 99
  - When: Phase A validates MemberSim
  - Then: MemberSim's validate-only deserialize() returns error "member X references unknown equipment_instance_id 99"; Phase A collects this; load() returns result.ok=false; no system mutated
  - Edge cases: test with member referencing instance_id that exists but is not in the grid (should also fail — the grid is the source of truth); test with zero members (empty MemberSim — should pass)

---

## Test Evidence

**Story Type**: Integration (crosses SaveLoad ↔ all 8 coordinated systems in load sequence)
**Required evidence**:
- `tests/integration/save_load/load_orchestration_test.gd` — must exist and pass (AC3, AC4, AC9)

**Status**: [x] Created and passing — load_orchestration_test.gd — 87 assertions, 0 failures; full suite 1789/0, exit 0 (2026-08-02)

---

## Dependencies

- Depends on: Story 001 (blob structure — load() reads the keys defined there). All 6 coordinated systems having deserialize() with validate_only mode (grid-system story-007, time-system story-004, member-sim, congestion, satisfaction, economy). PlacementSystem.rederive_counter(), SelectionSystem.rebuild_mapping(), Navigation.rebuild().
- Unlocks: Story 003 (round-trip test needs load pipeline to exist)
