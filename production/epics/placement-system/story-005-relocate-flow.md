# Story 005: Relocate Flow

> **Epic**: placement-system
> **Status**: Ready
> **Layer**: Core
> **Type**: Logic
> **Estimate**: L — 3 sessions (≤6h)
> **Manifest Version**: 2026-07-23
> **Last Updated**: 2026-08-02

## Context

**GDD**: `design/gdd/placement-system.md`
**Requirements**: `TR-PS-001` (relocate half), `TR-PS-008`
*(Requirement text lives in `docs/architecture/tr-registry.yaml` — read fresh at review time)*

**ADR Governing Implementation**: ADR-0001: DI Container & Scene Bootstrap; ADR-0003: GridStateReader Contract; ADR-0005: Signal Bus & Event Routing
**ADR Decision Summary**: `begin_relocate(instance_id)` picks up an already-committed piece: it reads the instance's current `def`/`anchor`/`rotation`, **clears its occupancy from GridSystem** at drag-start (firing `grid_changed` — this lets in-use members repath exactly as in the sell path), and enters the same DRAGGING state seeded with the existing rotation. On a valid drop it **re-commits under the same `instance_id`** (never reallocated, counter untouched). On cancel / focus-loss / rejected drop it **restores the piece to its original anchor/rotation** via `GridSystem.commit(same_id, ...)` — relocation is never destructive to the grid. A rejected relocate-drop is a silent restoration (no `placement_rejected`), identical in outcome to a cancel.

**Engine**: Godot 4.7.1 | **Risk**: LOW
**Engine Notes**: Signal emit arity must match exactly — `grid_changed` (2 args) fires from GridSystem's commit/clear; `placement_committed` (3 args) fires for a successful relocate re-commit too (downstream identifies it as a relocate by the pre-existing instance_id). Use `RefCounted` counter spies for emit-count assertions, not lambda closures.

**Control Manifest Rules (Core layer)**:
- Required: `grid_changed` (S1) fires exactly once per `commit()` or `clear()` call
- Required: `instance_id` never reused within a session; relocate preserves the id
- Forbidden: Never call `spend(-refund)` as a credit workaround (not directly relevant here — relocate is cost-free)

---

## Acceptance Criteria

*From GDD `design/gdd/placement-system.md`, scoped to this story:*

- [ ] AC20 GIVEN PlacementSystem's public API surface, WHEN inspected, THEN it exposes **exactly one** entry point that starts from an already-committed `instance_id` — `begin_relocate(instance_id)` — and **no** method for *inspecting* or *selling* a placed instance (those remain SelectionSystem's). Static/API-surface check
- [ ] AC24 GIVEN a relocate started via `begin_relocate(N)` for a piece at `(anchor₀, rotation₀)`, WHEN the drag is cancelled (Esc / focus-loss / a rejected drop with no valid landing), THEN instance `N` is restored to `(anchor₀, rotation₀)` under the **same** `instance_id`, GridSystem occupancy matches the pre-relocate state cell-for-cell, and no `placement_committed`/`placement_rejected` is emitted for a *new* id
- [ ] AC25 GIVEN a relocate started via `begin_relocate(N)` for a piece at `(anchor₀, rotation₀)`, WHEN the drag drops on a **different** valid cell `anchor₁` (with possibly rotated `rotation₁`), THEN: (a) `GridSystem.commit(N, def, anchor₁, rotation₁)` is called (re-using the **same** `instance_id` N — no new allocation from the counter), (b) `grid_changed` fires exactly once for the new position, (c) `placement_committed(N, equipment_id, new_footprint_cells)` is emitted, (d) GridSystem occupancy shows N at `anchor₁` and `anchor₀` is clear, (e) the internal `next_instance_id` counter is unchanged (no increment)
- [ ] AC26 GIVEN a relocate started via `begin_relocate(N)` and the drag drops on the grid but `can_place` returns FAIL, WHEN the rejected drop resolves, THEN the piece is **restored** to `(anchor₀, rotation₀)` — a rejected relocate-drop is treated identically to a cancel (not left in limbo). `placement_rejected` does NOT fire
- [ ] AC27 GIVEN PlacementSystem is already in `DRAGGING` state (any source), WHEN `begin_relocate(instance_id)` is called, THEN it is a no-op: `push_error()` fires, state remains unchanged, the in-flight drag is not disrupted, and the piece identified by `instance_id` remains at its current grid position unaffected
- [ ] AC30 GIVEN a relocate is started via `begin_relocate(N)` for a piece a member is actively using, WHEN the drag begins, THEN occupancy clears immediately (Core Rule 1a), MemberSim's equipment-deleted-mid-use handling is triggered for that member, **and** — if the drag is subsequently cancelled or rejected — the member's displaced state is **not** reverted even though the piece's grid position is restored

---

## Implementation Notes

*Derived from ADR-0001 + ADR-0003 + ADR-0005 Implementation Guidelines:*

**Relocate flow (Core Rule 1a):**
1. `begin_relocate(instance_id)` — read current `def`/`anchor`/`rotation` from GridSystem (via the granted read surface)
2. Clear occupancy from GridSystem immediately (`GridSystem.clear(instance_id)`) — fires `grid_changed` once; in-use members repath per MemberSim's equipment-deleted-mid-use handling
3. Enter DRAGGING with the piece's existing rotation (not R0 — relocate preserves facing)
4. Valid drop → `GridSystem.commit(N, def, anchor₁, rotation₁)` with the **same** id N; `grid_changed` fires once; emit `placement_committed(N, equipment_id, new_footprint_cells)`
5. Cancel / focus-loss / rejected drop → `GridSystem.commit(N, def, anchor₀, rotation₀)` restoring the original position, **same** id; no `placement_committed`/`placement_rejected` for a new id; relocate reject is silent restoration

**Key invariants:**
- Relocate re-commit NEVER touches the `next_instance_id` counter (AC25e)
- The piece is absent from the grid during the drag — this is the one case PlacementSystem holds transient knowledge of an existing instance_id, released when the drag resolves
- AC30's member displacement is a documented, accepted cost — not a bug; the test makes it observable (MemberSim handling fires at drag-start and is NOT reverted on cancel)

**Forbidden:**
- No new id allocation on relocate re-commit
- No `placement_rejected` on a rejected relocate drop (silent restore, unlike new-placement reject)

---

## Out of Scope

*Handled by neighbouring stories — do not implement here:*

- [Story 001]: new-placement drag lifecycle (relocate reuses DRAGGING but starts with existing rotation)
- [Story 002]: new-placement commit (relocate commits with same id — no counter increment)
- [Story 003]: new-placement reject/cancel (relocate reject is silent restore, not signal-emitting)
- [Story 007]: bridge wiring — `begin_relocate` is invoked by SelectionSystem's Move handoff, not directly by input
- [MemberSim epic]: the equipment-deleted-mid-use handling this story triggers

---

## QA Test Cases

*Written by qa-lead at story creation. The developer implements against these — do not invent new test cases during implementation.*

- **AC20**: API 表面检查
  - Given: PlacementSystem public API
  - When: inspected statically
  - Then: exactly one relocate entry point (`begin_relocate(instance_id)`); no inspect/sell methods
  - Edge cases: verify no method with "sell"/"inspect" semantics exists

- **AC24**: 取消恢复
  - Given: piece N at (anchor₀, rotation₀)
  - When: begin_relocate(N), then cancel (Esc)
  - Then: piece restored to (anchor₀, rotation₀) under same id; occupancy matches pre-relocate state cell-for-cell; no new-id signals
  - Edge cases: cancel via focus-loss; cancel via rejected drop (AC26); restore after rotation changed mid-drag

- **AC25**: 有效落点重提交
  - Given: piece N at (anchor₀, rotation₀)
  - When: begin_relocate(N), drop at valid anchor₁ with rotation₁
  - Then: commit(N, def, anchor₁, rotation₁) called; grid_changed fires once; placement_committed(N, eq_id, new_fp) emitted; occupancy shows N at anchor₁, anchor₀ clear; counter unchanged
  - Edge cases: drop at same cell as origin (relocate no-op still re-commits); drop after rotation to R90

- **AC26**: 拒绝落点静默恢复
  - Given: piece N at (anchor₀, rotation₀), can_place FAIL at drop cell
  - When: drop resolves
  - Then: piece restored to (anchor₀, rotation₀); placement_rejected does NOT fire; no new-id signals
  - Edge cases: all 5 FAIL codes produce identical restore

- **AC27**: 拖拽中 begin_relocate 为 no-op
  - Given: DRAGGING (any source), piece M on grid
  - When: begin_relocate(M)
  - Then: push_error() fires; state unchanged; drag A unaffected; piece M grid position unchanged
  - Edge cases: begin_relocate of the same piece currently being dragged (also no-op)

- **AC30**: 会员位移的可观测成本
  - Given: member actively using piece N
  - When: begin_relocate(N) (occupancy clears immediately), then cancel
  - Then: MemberSim equipment-deleted-mid-use handling triggered at drag-start; after cancel, piece's grid position restored but member's displaced state NOT reverted
  - Edge cases: verify via injected MemberSim spy that the displacement signal fires once at drag-start, not at cancel

---

## Test Evidence

**Story Type**: Logic
**Required evidence**:
- `tests/unit/placement_system/relocate_flow_test.gd` — must exist and pass

**Status**: [ ] Not yet created

---

## Dependencies

- Depends on: Story 002 (commit plumbing), Story 004 (counter correctness — relocate must not increment)
- Unlocks: SelectionSystem Move handoff (integration), Story 007 (bridge/input integration for the full loop)
