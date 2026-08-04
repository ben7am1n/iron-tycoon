# Story 003: access_reachable and grid_changed Handling

> **Epic**: congestion
> **Status**: Complete — 2026-08-02
> **Layer**: Feature
> **Type**: Logic
> **Estimate**: M — 1 session (≤3h)
> **Manifest Version**: 2026-07-23
> **Last Updated**: 2026-08-02

## Context

**GDD**: `design/gdd/congestion.md`
**Requirement**: `TR-CONG-005`
*(Requirement text lives in `docs/architecture/tr-registry.yaml` — read fresh at review time)*

**ADR Governing Implementation**: ADR-0003 (GridStateReader Contract); ADR-0005 (Signal Bus & Event Routing)
**ADR Decision Summary**: `access_reachable` flag = whether any path exists from the level `entrance_cell` to an equipment's access cell (`Navigation.get_path(entrance_cell, access_cell)` non-empty). Recomputed ONLY when `grid_changed` fires (not per-tick — reachability only changes when layout changes), cached otherwise. This is Congestion's answer to GridSystem's handoff (OQ#9): the overlay must surface `access_reachable == false` as default-visible.

**Engine**: Godot 4.7.1 | **Risk**: LOW
**Engine Notes**: GridSystem's `grid_changed(footprint_cells_changed, access_cells_changed)` (S1) fires exactly once per commit/clear — never during drag preview.

**Control Manifest Rules (Feature layer)**:
- Required: subscribe to `grid_changed` (S1); recompute reachability event-driven
- Required: `congestion_updated()` (S8) emitted once per tick
- Forbidden: no RNG; no per-tick path queries when nothing changed

---

## Acceptance Criteria

*From GDD `design/gdd/congestion.md`, scoped to this story:*

- [x] AC9 GIVEN equipment E has active entries and a `grid_changed` removes E during tick `t`, WHEN tick `t+1` begins, THEN querying E's id returns "not found," never a stale float
- [x] AC12 [WB] GIVEN no `grid_changed` fires during tick `t`, WHEN Congestion runs its normal per-tick update, THEN zero `Navigation.get_path` queries occur that tick (call-count spy)
- [x] AC13 GIVEN a `grid_changed` severs the only path from `entrance_cell` to E's access cell, WHEN `access_reachable` recomputes, THEN `access_reachable[E] == false`
- [x] AC16 GIVEN two `grid_changed` events affecting the same equipment E in one tick, WHEN they are processed, THEN `access_reachable[E]` is recomputed exactly once, against the final post-batch grid state

---

## Implementation Notes

*Derived from ADR-0003 + ADR-0005 Implementation Guidelines:*

**Core Rule 5 — event-driven reachability:**
- For each equipment: `access_reachable[E] = (Navigation.get_path(entrance_cell, access_cell) != [])`
- Recomputed ONLY on `grid_changed` — cached otherwise (AC12: zero path queries on a quiet tick)
- Path source: the level's single `entrance_cell` (matching MemberSim's single-entrance assumption, OQ4)

**Core Rule 6 — equipment removal (AC9):**
- When an equipment is removed (`grid_changed`): its `prev`/`next`/`access_reachable` entries are **deleted the same tick** — not decayed
- A stale congestion entry for nonexistent equipment is a correctness bug, not a leak (MemberSim must never read a value for a nonexistent machine)

**AC13 — severed path:**
- `grid_changed` that walls off E's access cell → recompute → `access_reachable[E] == false`
- Congestion still computes the scalar (trends to 0 as no one can reach it), but the flag is the overlay's signal

**AC16 — batch dedupe:**
- Multiple `grid_changed` events in one tick: apply all occupancy deltas first, de-duplicate affected equipment set, recompute `access_reachable` **once per affected equipment** — never once per event
- Reachability computed against the final post-batch grid state, never an intermediate

---

## Out of Scope

*Handled by neighbouring stories — do not implement here:*

- [Story 001]: per-equipment congestion scalar (this story adds the flag around it)
- [Story 002]: per-cell density field
- [Story 004]: serialization — access_reachable is NOT serialized (recomputed on load)

---

## QA Test Cases

*Written by qa-lead at story creation. The developer implements against these — do not invent new test cases during implementation.*

- **AC9**: 删除同 tick 生效
  - Given: equipment E has active entries; grid_changed removes E during tick t
  - When: tick t+1 begins
  - Then: querying E's id returns "not found," never a stale float
  - Edge cases: E removed and re-added in same tick (new entry, fresh state)

- **AC12**: 安静 tick 零查询
  - Given: no grid_changed fires during tick t
  - When: Congestion runs normal per-tick update
  - Then: zero Navigation.get_path queries that tick (call-count spy)
  - Edge cases: tick with member movement only (no layout change) — still zero queries

- **AC13**: 通路被切断
  - Given: grid_changed severs the only path from entrance_cell to E's access cell
  - When: access_reachable recomputes
  - Then: access_reachable[E] == false
  - Edge cases: path exists via a narrow corridor; corridor blocked by new placement

- **AC16**: 批量去重
  - Given: two grid_changed events affecting same equipment E in one tick
  - When: processed
  - Then: access_reachable[E] recomputed exactly once, against final post-batch grid state
  - Edge cases: events arrive mid-computation; intermediate state never used for reachability

---

## Test Evidence

**Story Type**: Logic
**Required evidence**:
- `tests/unit/congestion/access_reachable_test.gd` — must exist and pass

**Status**: [x] Complete — 2026-08-02 (30 assertions, all green)

```
=== ACCESS_REACHABLE TEST: 30 passed, 0 failed ===
```

**Verification**:
- Full headless suite: **2721 passed, 0 failed** (baseline 2691 + 30 new), 0 SCRIPT ERROR, run 3x bit-identical
- `access_reachable_test.gd` registered in `tests/headless_runner.gd` TEST_FILES
- Coverage: AC9 (main + remove/re-add same tick + removal without navigation), AC12 (quiet tick + member-movement-only), AC13 (full sever + narrow-corridor edge), AC16 (exactly-once spy: 3 get_path calls not 6, final post-batch state), init one-shot population, unknown-id read defaults

### Deviations / Interpretations (documented, not silent)

1. **Init-time one-shot recompute** (GDD Core Rule 7 allowance): access_reachable is populated once at `init()` when navigation + entrance_cell are supplied — otherwise equipment placed before init would read `false` until the first grid_changed and the overlay would misreport every machine as walled off at boot. Not a per-tick query (AC12 unaffected); matches the GDD's "one-shot recompute on load" escape hatch.

2. **"Affected set" = all current equipment**: on a grid_changed batch, `access_reachable` is recomputed for EVERY currently placed equipment (ascending-id order), because the S1 payload is cells-not-ids and any layout change can sever any path (AC13's corridor case proves a payload-local affected set is insufficient). AC16's "once per affected equipment" is satisfied — one get_path per equipment per batch, never once per event.

3. **AC9 "not found" semantics**: removed equipment's `prev`/`next`/`access_reachable` entries are deleted the same tick (white-box observable: the dicts no longer contain the id). `per_equipment_congestion(id)` returns the documented neutral `0.0` for an absent entry (unchanged CG-001 contract — MemberSim's `_congestion_value` treats 0.0 as "no congestion"); the guarantee is *never a stale float*, i.e. never the pre-removal value.

4. **Reachability source cell**: uses `access_cells[0]` (first access cell) — matching MemberSim's arrival semantics and CG-001's `_nearby_count` anchor, so reachability and density measure the same cell.

5. **Subscription in `_post_init()`** (ADR-0001 Phase 2): the grid_changed subscription lives in `_post_init()` like Navigation's, guarded by `is_connected` (idempotent). Story-001 / pre-wiring rigs never call `_post_init` — reachability stays inert there (no subscription, `access_reachable` empty), preserving the CG-001 contract exactly.

6. **`access_reachable` NOT serialized** (story-004 scope): `serialize()` shape `{counter, rng_state}` unchanged. On load the init one-shot recomputes the flag from the restored grid (deviations #1).

---

## Dependencies

- Depends on: Story 001 (per-equipment structures), navigation epic (`get_path`, `is_reachable`), grid-system epic (`grid_changed` S1 subscription, entrance_cell)
- Unlocks: Story 004 (serialization — flag recomputed on load), congestion-flow-overlay (presentation layer later)
