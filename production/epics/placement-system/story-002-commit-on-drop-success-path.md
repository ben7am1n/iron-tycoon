# Story 002: Commit-on-Drop — Success Path

> **Epic**: placement-system
> **Status**: Ready
> **Layer**: Core
> **Type**: Logic
> **Estimate**: M — 2 sessions (≤4h)
> **Manifest Version**: 2026-07-23
> **Last Updated**: 2026-08-02

## Context

**GDD**: `design/gdd/placement-system.md`
**Requirements**: `TR-PS-003`, `TR-PS-006`
*(Requirement text lives in `docs/architecture/tr-registry.yaml` — read fresh at review time)*

**ADR Governing Implementation**: ADR-0001: DI Container & Scene Bootstrap; ADR-0003: GridStateReader Contract; ADR-0005: Signal Bus & Event Routing
**ADR Decision Summary**: Commit-on-drop calls `GridSystem.can_place()` first; on success allocates a new `instance_id` from a single monotonically-increasing counter, calls `GridSystem.commit(id, def, anchor, rotation)`, and emits `placement_committed(instance_id, equipment_id, footprint_cells)` exactly once after `commit()` returns. `grid_changed` is GridSystem's signal (S1), fired by GridSystem — PlacementSystem does not own or emit it. The `instance_id` counter is incremented **only** on successful new-placement commit — never at drag-start, never for canceled/failed drags, and never for relocate re-commits.

**Engine**: Godot 4.7.1 | **Risk**: LOW
**Engine Notes**: Signal emit arity must exactly match the declared signal — `placement_committed` takes 3 args (instance_id, equipment_id, footprint_cells); write all args explicitly at every `.emit()` call site. Lambda closures do NOT write back to outer-scope locals — use a `RefCounted` counter class when asserting "emitted exactly once" (AC6, AC21).

**Control Manifest Rules (Core layer)**:
- Required: `grid_changed` (S1) fires exactly once per `commit()` or `clear()` call — never during drag preview; both parameters are `Array[Vector2i]`
- Required: `instance_id` is allocated by PlacementSystem via a monotonic `next_instance_id` counter; GridSystem stores it as `occupant_id` but never allocates; no system may reuse a decommissioned id within a session
- Forbidden: Never call `init()` twice on the same system; never trigger side effects in `init()`

---

## Acceptance Criteria

*From GDD `design/gdd/placement-system.md`, scoped to this story:*

- [ ] AC6 GIVEN DRAGGING and `can_place`=true for the current cell, WHEN mouse-up over it, THEN a new `instance_id` is allocated, `commit(id, def, anchor, rotation)` is called exactly once with those args, and `grid_changed` fires exactly once
- [ ] AC10 GIVEN counter=N and 3 prior cancelled drags, WHEN a 4th drag commits successfully, THEN the allocated id is N (cancellations never consumed an id) and the counter becomes N+1
- [ ] AC21 GIVEN a successful commit of `equipment_id="treadmill_01"` allocated as `instance_id` N, WHEN the commit completes, THEN `placement_committed(N, "treadmill_01", footprint_cells)` is emitted exactly once, after `GridSystem.commit()` returns, and no `placement_rejected` fires

---

## Implementation Notes

*Derived from ADR-0001 + ADR-0003 + ADR-0005 Implementation Guidelines:*

**Commit sequence (Core Rule 5):**
1. `can_place(def, anchor, rotation)` — on FAIL, delegate to Story 003's reject path
2. Allocate `instance_id` from the internal counter (Core Rule 7)
3. Call `GridSystem.commit(id, def, anchor, rotation)` — GridSystem fires `grid_changed` exactly once (PlacementSystem does NOT emit it)
4. Emit `placement_committed(instance_id, equipment_id, footprint_cells)` — exactly once, after `commit()` returns
5. Clear drag state; the new instance belongs to SelectionSystem's domain

**instance_id allocation (Core Rule 7):**
- Single internal monotonically-increasing counter, dependency-injected (no Autoload) — exactly one allocator instance exists
- Incremented and consumed **only** at the moment of a successful new-placement commit — never at drag-start, never for canceled/failed drags
- Relocate re-commits (Story 005) are explicitly excluded from the increment — they reuse the piece's existing id

**Signal semantics (ADR-0005 S3):**
- `placement_committed(instance_id: int, equipment_id: String, footprint_cells: Array[Vector2i])` — 3 args, emitted once per successful commit
- Arity must match exactly: `placement_committed.emit(id, eq_id, fp_cells)`, never `emit(id, eq_id, fp_cells + extra)` or a single array
- Test with a `RefCounted` counter class connected as a spy — a lambda closure cannot write back the count

**Forbidden:**
- Never emit `grid_changed` from PlacementSystem — that signal belongs to GridSystem
- Never allocate an `instance_id` at drag-start or on a failed/canceled drag

---

## Out of Scope

*Handled by neighbouring stories — do not implement here:*

- [Story 001]: drag start, live preview, rotation normalization (feeds the commit)
- [Story 003]: rejected drop (`placement_rejected` + fail_code) and silent cancel paths
- [Story 004]: `instance_id` resume after load
- [Story 005]: relocate re-commit path (same id, no counter increment)
- [Story 006]: `is_dragging()` query and cost-scope guarantees

---

## QA Test Cases

*Written by qa-lead at story creation. The developer implements against these — do not invent new test cases during implementation.*

- **AC6**: 成功提交完整序列
  - Given: DRAGGING treadmill_01, can_place=true at current cell
  - When: mouse-up (drop)
  - Then: new instance_id allocated; commit(id, def, anchor, rotation) called exactly once; grid_changed fires exactly once; placement_committed emitted after commit returns
  - Edge cases: drop with zero mouse moves since drag start; drop at exact grid corner cell

- **AC10**: 取消不消耗 id
  - Given: counter=N, 3 prior cancelled drags (Esc/out-of-bounds/reject)
  - When: 4th drag commits successfully
  - Then: allocated id == N; counter becomes N+1
  - Edge cases: mix of cancel types; failed drags also don't consume

- **AC21**: placement_committed 语义
  - Given: successful commit allocates instance_id N for treadmill_01
  - When: commit completes
  - Then: placement_committed(N, "treadmill_01", footprint_cells) emitted exactly once, after GridSystem.commit() returns; placement_rejected never fires
  - Edge cases: verify argument order (id, equipment_id, cells); verify footprint_cells matches commit's footprint

---

## Test Evidence

**Story Type**: Logic
**Required evidence**:
- `tests/unit/placement_system/commit_success_test.gd` — must exist and pass

**Status**: [ ] Not yet created

---

## Dependencies

- Depends on: Story 001 (drag lifecycle — drag state, preview)
- Unlocks: Story 003 (reject/cancel paths share the commit decision point), Story 005 (relocate re-commit reuses commit plumbing)
