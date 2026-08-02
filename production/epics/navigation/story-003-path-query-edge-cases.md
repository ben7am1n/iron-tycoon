# Story 003: Path Query Edge Cases

> **Epic**: navigation
> **Status**: Ready
> **Layer**: Core
> **Type**: Logic
> **Estimate**: S — 1 session (≤2h)
> **Manifest Version**: 2026-07-23
> **Last Updated**: 2026-08-02

## Context

**GDD**: `design/gdd/navigation.md`
**Requirements**: `TR-NAV-002`
*(Requirement text lives in `docs/architecture/tr-registry.yaml` — read fresh at review time)*

**ADR Governing Implementation**: ADR-0007: AStarGrid2D Cross-Rebuild Determinism
**ADR Decision Summary**: `get_path(from, to)` returns an **empty array** (never `null`) when no path exists, including when `from`/`to` is solid or outside `region`. `from == to` returns a single-element array `[from]`. Out-of-region queries fail closed — `is_solid` returns true out-of-bounds, so such queries naturally return empty. MemberSim treats "unreachable" as go-idle-and-re-evaluate-next-tick, and must not retry the same query in a tight loop.

**Engine**: Godot 4.7.1 | **Risk**: MEDIUM
**Engine Notes**: Empty-array contract is enforced by the wrapper — `AStarGrid2D.get_id_path()` returns `PackedVector2Array`/`Array` shaped by the engine; Navigation's typed `Array[Vector2i]` return must convert and normalize (never `null`). `var x := VariantReturningCall()` fails inference — use explicit `: Type`.

**Control Manifest Rules (Core layer)**:
- Required: Cell-space only — `get_id_path` returns `Array[Vector2i]`; `get_point_path` forbidden
- Forbidden: Never serialise `AStarGrid2D` internal state

---

## Acceptance Criteria

*From GDD `design/gdd/navigation.md`, scoped to this story:*

- [ ] AC4 GIVEN a target fully enclosed by solid cells, WHEN `get_path` is called, THEN it returns an empty `Array[Vector2i]` (size 0), never `null`
- [ ] AC5 GIVEN any open cell `C`, WHEN `get_path(C, C)` is called, THEN it returns `[C]`
- [ ] AC14 GIVEN `from`/`to` outside the 13×10 bbox, WHEN `get_path` is called, THEN it returns an empty array without throwing, and `is_solid(out_of_bounds)` independently returns true

---

## Implementation Notes

*Derived from ADR-0007 Implementation Guidelines:*

**Empty-array contract (Core Rule 4):**
- No path exists → return empty `Array[Vector2i]`, never `null`
- Applies when: target enclosed by solids, `from`/`to` is solid, `from`/`to` outside `region`
- Debug-only assert: if the access cell itself came back solid, that signals an upstream invariant violation (access cells are never solid per GridSystem contract) — log, don't crash

**from == to (Edge Cases):**
- Return `[from]` — a single-element array
- MemberSim treats this as "already arrived"

**Out-of-bounds (Edge Cases):**
- `is_solid` returns true out-of-bounds (GridSystem contract), so out-of-region queries naturally fail closed → empty array
- No crash, no special-casing required beyond the natural solidity behavior

**Forbidden:**
- Never return `null` from `get_path` under any condition
- Never throw/crash on out-of-bounds coordinates

---

## Out of Scope

*Handled by neighbouring stories — do not implement here:*

- [Story 001]: basic path queries on empty grid
- [Story 002]: diagonal corner-clipping rules
- [Story 004]: solidity sync — mid-route solidification is handled there (MemberSim re-queries on grid_changed)
- [MemberSim epic]: unreachable handling (idle + re-evaluate next tick)

---

## QA Test Cases

*Written by qa-lead at story creation. The developer implements against these — do not invent new test cases during implementation.*

- **AC4**: 全封闭目标
  - Given: target fully enclosed by solid cells (e.g. walls on all 4 orthogonal sides + diagonal flanks)
  - When: get_path(from, target)
  - Then: returns empty Array[Vector2i] (size 0), never null
  - Edge cases: enclosure with a diagonal gap only (impassable under ONLY_IF_NO_OBSTACLES); from-cell itself enclosed

- **AC5**: 起点等于终点
  - Given: any open cell C
  - When: get_path(C, C)
  - Then: returns [C]
  - Edge cases: C at grid corner; C adjacent to solid cells

- **AC14**: 越界查询
  - Given: 13×10 bbox
  - When: get_path with from or to outside bounds (e.g. (-1,0), (13,0), (0,10))
  - Then: returns empty array without throwing; is_solid(out_of_bounds) independently returns true
  - Edge cases: both from and to out of bounds; from in-bounds to out-of-bounds and vice versa

---

## Test Evidence

**Story Type**: Logic
**Required evidence**:
- `tests/unit/navigation/path_query_edge_cases_test.gd` — must exist and pass

**Status**: [ ] Not yet created

---

## Dependencies

- Depends on: Story 001 (get_path wrapper + is_solid access)
- Unlocks: Story 005 (determinism gate reuses the query API), MemberSim path-caching integration
