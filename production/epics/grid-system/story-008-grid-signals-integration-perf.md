# Story 008: Signals, Integration, and Performance

> **Epic**: grid-system
> **Status**: Ready
> **Layer**: Foundation
> **Type**: Integration
> **Estimate**: [hours or t-shirt size — fill before sprint planning]
> **Manifest Version**: 2026-07-23
> **Last Updated**: [set by /dev-story when implementation begins]

## Context

**GDD**: `design/gdd/grid-system.md`
**Requirements**: `TR-GS-010`, `TR-GS-021`, `TR-GS-026`, `TR-GS-027`, `TR-GS-030`
*(Requirement text lives in `docs/architecture/tr-registry.yaml` — read fresh at review time)*

**ADR Governing Implementation**: ADR-0005: Signal Bus & Event Routing
**ADR Decision Summary**: grid_changed(footprint_cells_changed: Array[Vector2i], access_cells_changed: Array[Vector2i]) signal (S1 in the signal catalog). Emitted exactly once per commit()/clear() — never during drag preview. Subscribers read current state from the payload cells, not from signal direction. Access cells NOT in is_solid — Navigation ignores access_cells_changed entirely. Performance: commit-to-grid at 130 cells MVP must succeed; drag smoke test 300 speculative snapshots < 50ms total.

**Engine**: Godot 4.7.1 | **Risk**: MEDIUM
**Engine Notes**: Signal emission in Godot 4.7.1 is synchronous — all subscribers receive the signal before emit() returns. This means Navigation must keep its update-slot-shape logic fast enough to not stall the PlacementSystem. occupant_id = 0 is legal (first piece placed) — GDScript truthy checks are a common bug source (see AC-D3.4 in Story 002). Performance targets are extrapolated, not directly measured — AC-PERF.3 is the BLOCKING smoke test that must pass in CI.

**Control Manifest Rules (Foundation layer)**:
- Required: All public methods must guard against use-before-init; init() stores references only; every signal emit must match declared argument count exactly
- Forbidden: Never emit grid_changed during drag preview; never expose internal reverse_index Dictionary as public API; never use Autoload
- Guardrail: Commit-to-grid must succeed at 130 cells MVP; drag smoke test 300 calls < 50ms; signal frequency "once per placement action" — NOT per-frame

---

## Acceptance Criteria

*From GDD `design/gdd/grid-system.md`, scoped to this story:*

- [ ] AC-C7.4 [BLOCKING][Logic] GIVEN equipment A's footprint=[(1,1),(1,2)], access=[(1,3)], WHEN commit(A), THEN grid_changed emitted exactly once, footprint_cells_changed == [(1,1),(1,2)], access_cells_changed == [(1,3)] (no extra cells, no missing cells)
- [ ] AC-C7.5 [BLOCKING][Logic] (clear-side symmetry) GIVEN equipment A already committed (same fixture), WHEN clear(A), THEN grid_changed emitted exactly once, both arrays identical to commit side — field names carry no direction semantics. Test must explicitly assert post-signal is_solid((1,1)) == false (proves "re-query, don't guess direction" contract)
- [ ] AC-C7.6 [BLOCKING][Integration] (signal frequency isolation) GIVEN a drag-preview flow (multiple get_speculative_snapshot calls), WHEN preview loops repeatedly request snapshots, THEN grid_changed emission count == 0 until actual commit() fires, at which point count == 1
- [ ] AC-X.1 [BLOCKING][Integration] (Navigation consumes solidity, ignores access) GIVEN equipment A's access cell (2,2) has no footprint on it, WHEN Navigation reads that cell via get_solidity_snapshot(), THEN returns non-solid (0). Optional: verify path can traverse (2,2) with minimal AStarGrid2D fixture
- [ ] AC-X.4 [BLOCKING][Logic] (SelectionSystem only sees int id — negative) GIVEN equipment A committed, WHEN get_occupant_id(cell) called, THEN return value is pure int — GridSystem side does not parse or validate what EquipmentInstance this id maps to
- [ ] AC-NEG.1 [BLOCKING][Logic] GIVEN two different equipment ids declare the same access cell, WHEN query is_solid on that cell, THEN result is always false — not set to true due to "contention"
- [ ] AC-NEG.2 [BLOCKING][Logic] GIVEN equipment whose all access cells are completely surrounded by other equipment footprints (unreachable), WHEN each of the following public APIs is called, THEN none of their return values/error codes contain any reachability-related information:
  - can_place → {valid: true} (no FAIL due to "placement would be unusable", no warning field)
  - commit → succeeds normally, no push_error()
  - is_solid → determined ONLY by !buildable OR occupant_id != -1
  - get_occupant_id → returns int, no sentinel for "unreachable"
  - get_access_cells → returns ALL statically-owned access cells, no filtering of unreachable ones
  - get_snapshot / get_speculative_snapshot → snapshot structures contain no reachability fields
  - serialize → PlacementRecord output contains no reachability fields
  - clear → succeeds normally
- [ ] AC-PERF.3 [BLOCKING][Integration] (drag smoke test) GIVEN MVP room (13×10=130 cells) with {5-6 placed equipment, 10-20 non-empty access cells scattered (~8-15% fill rate), anchor_cell varying per call along a realistic mouse trajectory (NOT repeating the same delta 300 times)}, WHEN 300 consecutive get_speculative_snapshot(deltas) calls (~5s @60fps) with 1 equipment's real deltas per call, THEN total < 50ms AND per-call max < 5ms (first call MAY be excluded from per-call max but STILL counts toward total)

---

## Implementation Notes

*Derived from ADR-0005 + GDD "信号设计" section + H.15/H.16/H.17:*

**grid_changed signal declaration:**
```gdscript
signal grid_changed(footprint_cells_changed: Array[Vector2i], access_cells_changed: Array[Vector2i])
```

**Payload semantics — "changed, re-query" not "direction":**
- Two separate arrays: footprint_cells_changed (for Navigation — solidity updates) and access_cells_changed (for Overlay/ZoneRules — access state updates)
- Navigation ignores access_cells_changed entirely → avoids unnecessary AStarGrid2D re-baking
- Field names do not encode direction — subscribers MUST re-query current state (is_solid, get_occupant_id, get_access_cells) rather than infer from field names
- This makes commit and clear handling identical for all consumers — no branching

**Emission rules (enforced, not advisory):**
- commit() → emit exactly once, with the specific cells that changed
- clear() → emit exactly once, same cells as were committed (from reverse index)
- deserialize() success → emit exactly once, union of all records' cells (not per-record)
- deserialize() failure → NO emission (no writes occurred)
- Drag preview / get_speculative_snapshot() → NEVER emit (speculative only)
- can_place() → NEVER emit (pure read-only)

**Signal frequency contract:**
- "Once per placement action" — NOT per-frame, NOT per-cell
- A player placing 5 pieces in rapid succession = 5 signal emissions
- Drag preview with 300 frames of speculative snapshots = 0 signal emissions

**Integration with Navigation (AC-X.1):**
```gdscript
# Navigation subscribes to grid_changed, consumes only footprint_cells_changed:
func _on_grid_changed(footprint_cells: Array[Vector2i], _access_cells: Array[Vector2i]) -> void:
    for cell in footprint_cells:
        _astar.set_point_solid(cell.x, cell.y, _grid.is_solid(cell))
    # access_cells_changed is IGNORED — Navigation doesn't need it
```

**Integration with GridVisualizer (advisory, not tested here):**
- Subscribe to grid_changed → re-draw ONLY the payload cells (incremental, not full-room clear+redraw)
- The payload was split into two arrays precisely FOR incremental consumption

**Negative boundary tests (AC-NEG.1, AC-NEG.2):**
- These are GUARDRAILS, not feature tests — they prevent future developers from "fixing" problems by adding logic to the wrong system
- AC-NEG.2 must assert on ALL 8 listed public API surfaces — partial coverage defeats the guardrail purpose
- New public methods added later must be reviewed against this list

**Performance smoke test (AC-PERF.3):**
```gdscript
# Fixture setup:
# - 13×10 grid with 5-6 placed equipment
# - 10-20 non-empty access cells, scattered (sparse, NOT dense)
# - Varying anchor_cell per call (simulate mouse drag trajectory)
# - 300 calls, measure total time

func test_drag_smoke() -> void:
    var deltas := _build_deltas_for_equipment(some_def, _trajectory_anchors())
    var timer := Time.get_ticks_usec()
    var max_single := 0
    for i in range(300):
        var call_start := Time.get_ticks_usec()
        var snap := _grid.get_speculative_snapshot(deltas)
        var call_usec := Time.get_ticks_usec() - call_start
        if i > 0:  # exclude first call from max (cold start)
            max_single = max(max_single, call_usec)
    var total_ms := (Time.get_ticks_usec() - timer) / 1000.0
    assert(total_ms < 50.0, "300 speculative snapshots took %.1fms" % total_ms)
    assert(max_single < 5000, "max single call %dμs exceeds 5ms" % max_single)
```

**Key design decisions:**
- **Why split into two arrays**: Navigation only needs footprint_cells_changed — if access changes were mixed in, Navigation would waste cycles on cells whose solidity didn't change. The split is a zero-cost optimization for the most frequent consumer.
- **Why "re-query" not "direction"**: commit and clear are semantically opposite but structurally identical — both change cells, both require consumers to re-read. If signal carried direction, every consumer would need a branch. "Changed, go check" is simpler, faster, and correct.
- **Why AC-PERF.3 excludes first call from max**: first call may trigger cold allocation overhead (first Dictionary creation, first Array resize). It's real cost (counts toward total), but single-frame spikes from allocation init are not the regression this test hunts — it hunts for per-frame steady-state degradation.
- **Why smoke test threshold is loose (50ms/300 calls)**: this is a regression alarm, not a performance budget. Hardware differences (local dev vs CI) can cause 2-3× variance. The test is designed to catch "1000× slower", not "10% slower."

---

## Out of Scope

*Handled by neighbouring stories — do not implement here:*

- [Story 001–005]: Individual commit/clear/snapshot implementations — this story wires them together and tests the contract
- [Story 007]: Serialization round-trip signal count (AC-C8.10) — deserialize signal contract is tested there
- [Navigation epic]: AStarGrid2D incremental update logic — GridSystem only provides the signal; Navigation's subscription handler lives in its own story
- [Congestion/Overlay epic]: Access-blocked visualization — GridSystem only emits access_cells_changed; visualizing what it means is downstream

---

## QA Test Cases

- **AC-C7.4**: commit 信号精确载荷
  - Given: equipment with footprint=[(1,1),(1,2)], access=[(1,3)]
  - When: commit(id, fp, ac)
  - Then: grid_changed emitted exactly once; footprint_cells_changed == [(1,1),(1,2)]; access_cells_changed == [(1,3)]; no extra cells
  - Edge cases: verify signal count with multiple sequential commits (should be 1 per commit)

- **AC-C7.5**: clear 侧信号对称
  - Given: equipment committed (same fixture as C7.4)
  - When: clear(id)
  - Then: grid_changed exactly once, both arrays identical to commit side; post-signal is_solid((1,1)) == false (proves re-query contract)
  - Edge cases: test with 2×2 footprint; test with rotation=90°

- **AC-C7.6**: 拖拽预览不发射信号
  - Given: any grid state
  - When: N calls to get_speculative_snapshot(deltas) during simulated drag, then 1 commit()
  - Then: signal count = 0 during preview phase, = 1 after commit
  - Edge cases: verify with get_snapshot() too (pure read, no signal); verify speculative snapshot with removal deltas

- **AC-X.1**: Navigation 消费 solidity，无视 access
  - Given: equipment A with access cell (2,2) and no footprint there
  - When: Navigation calls get_solidity_snapshot() or equivalent solidity query on (2,2)
  - Then: cell is non-solid (0 / false)
  - Edge cases: verify path can traverse the access cell; verify with multiple overlapping access cells

- **AC-X.4**: SelectionSystem 只拿到 int
  - Given: equipment with id=7 committed
  - When: get_occupant_id(occupied_cell)
  - Then: returns 7 (int), GridSystem does NOT validate what equipment type this is
  - Edge cases: verify with id=0 (first piece); verify with id that was cleared (should return -1)

- **AC-NEG.1**: access 争用不改变 solidity
  - Given: two equipments with shared access cell
  - When: is_solid(shared_access_cell)
  - Then: false — solidity unchanged by access contention
  - Edge cases: test with 3+, 5+ equipments sharing same access cell

- **AC-NEG.2**: 可达性信息不出现在任何公开 API
  - Given: equipment whose all access cells are surrounded by other footprints
  - When: enumerate all 8 public API surfaces (can_place, commit, is_solid, get_occupant_id, get_access_cells, get_snapshot, get_speculative_snapshot, serialize)
  - Then: none return reachability information — can_place returns valid=true, commit succeeds, get_access_cells returns ALL cells unfiltered, etc.
  - Edge cases: this is a guardrail test — adding a new public method must be reviewed against this list

- **AC-PERF.3**: 拖拽冒烟测试
  - Given: 13×10 grid, 5-6 placed equipment, 10-20 scattered access cells (sparse), varying anchor along a trajectory
  - When: 300 consecutive get_speculative_snapshot(deltas) calls
  - Then: total < 50ms, per-call max < 5ms (excluding first call from max, but including in total)
  - Edge cases: run in CI (godot --headless); verify fixture uses sparse access_ids (NOT dense); verify anchor varies (NOT same delta 300 times)

---

## Test Evidence

**Story Type**: Integration
**Required evidence**:
- `tests/integration/grid_system/grid_navigation_solidity_test.gd` — must exist and pass (AC-X.1)
- `tests/integration/grid_system/grid_perf_drag_smoke_test.gd` — must exist and pass (AC-PERF.3)
- `tests/unit/grid_system/grid_system_signals_test.gd` — must exist and pass (AC-C7.4, AC-C7.5, AC-C7.6)
- Code review checklist for AC-NEG.1, AC-NEG.2, AC-X.4 guardrail verification

**Status**: [ ] Not yet created

---

## Dependencies

- Depends on: Story 001 (cell data), Story 002 (is_solid), Story 005 (commit/clear emits signals), Story 006 (GridSnapshot for preview isolation), Story 007 (deserialize signal count verified there)
- Unlocks: Navigation epic (consumes grid_changed for AStarGrid2D), Overlay epic (consumes access_cells_changed), ZoneRules (consumes snapshots without signals)
