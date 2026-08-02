# Story 002: Diagonal Mode and Corner Clipping Rules

> **Epic**: navigation
> **Status**: Ready
> **Layer**: Core
> **Type**: Logic
> **Estimate**: M — 2 sessions (≤4h)
> **Manifest Version**: 2026-07-23
> **Last Updated**: 2026-08-02

## Context

**GDD**: `design/gdd/navigation.md`
**Requirements**: `TR-NAV-001` (diagonal_mode clause)
*(Requirement text lives in `docs/architecture/tr-registry.yaml` — read fresh at review time)*

**ADR Governing Implementation**: ADR-0007: AStarGrid2D Cross-Rebuild Determinism
**ADR Decision Summary**: `DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES` allows diagonal movement only when **both** flanking orthogonal cells are open. This forbids clipping past even a *single* solid corner — stricter than `AT_LEAST_ONE_WALKABLE`, which still permits a single-corner clip. The mode is coupled to `HEURISTIC_OCTILE`: any change to diagonal movement must keep the heuristic consistent with the resulting step cost, or A* loses its shortest-path guarantee.

**Engine**: Godot 4.7.1 | **Risk**: MEDIUM
**Engine Notes**: AStarGrid2D diagonal-mode semantics are engine-provided; verify the 4-permutation flank matrix behavior in 4.7.1 headless (GDD AC3 is the exact spec). No runtime handling is needed for diagonal squeeze — it is structurally impossible under this mode.

**Control Manifest Rules (Core layer)**:
- Required: `AStarGrid2D` configuration: `DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES`, `HEURISTIC_OCTILE`
- Forbidden: Never serialise `AStarGrid2D` internal state
- Cross-cut: Equipment-placement rules must not rely on a diagonal 1-cell gap as an intended traffic route — `ONLY_IF_NO_OBSTACLES` makes such a gap impassable (documented in GDD Tuning Knobs)

---

## Acceptance Criteria

*From GDD `design/gdd/navigation.md`, scoped to this story:*

- [ ] AC3 GIVEN the full 4-permutation flank matrix around target `(1,1)` from `(0,0)` — (a) `(1,0)` solid / `(0,1)` open, (b) `(0,1)` solid / `(1,0)` open, (c) both flanks solid, (d) both open — WHEN `get_path((0,0),(1,1))` is called, THEN in cases (a)/(b) the path never steps directly `(0,0)→(1,1)` and routes around (length ≥ 3); in (c) it returns empty (no route); in (d) the direct diagonal is allowed (length 2)

---

## Implementation Notes

*Derived from ADR-0007 Implementation Guidelines:*

**Flank matrix semantics (Core Rule 1 + AC3):**
- `DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES` = diagonal step `(0,0)→(1,1)` is legal only when BOTH `(1,0)` and `(0,1)` are walkable
- Case (a) `(1,0)` solid / `(0,1)` open → no direct diagonal; route around via `(0,1)` (length ≥ 3)
- Case (b) `(0,1)` solid / `(1,0)` open → no direct diagonal; route around via `(1,0)` (length ≥ 3)
- Case (c) both flanks solid → target unreachable, empty path
- Case (d) both flanks open → direct diagonal allowed (length 2)

**Implementation note:**
- This behavior comes from the AStarGrid2D mode itself — no special handling code in Navigation. The test verifies the mode's semantics are what the GDD requires (Pillar 3: members never clip through corners)
- Do NOT switch to `AT_LEAST_ONE_WALKABLE` or `ALWAYS` to "fix" a test failure — those modes permit corner clipping and break the design

**Forbidden:**
- No per-query path post-processing to enforce corner rules (the mode already does this)
- Never change `diagonal_mode` without changing the heuristic accordingly (coupled pair)

---

## Out of Scope

*Handled by neighbouring stories — do not implement here:*

- [Story 001]: basic path queries on empty grid (diagonal usage at path level)
- [Story 003]: path query edge cases (enclosed target via walls, from==to)
- [Story 005]: determinism gate (the mode choice affects tie-break frequency — gate covers it)

---

## QA Test Cases

*Written by qa-lead at story creation. The developer implements against these — do not invent new test cases during implementation.*

- **AC3(a)**: 单侧阻塞（右邻 solid）
  - Given: (1,0) solid, (0,1) open, target (1,1)
  - When: get_path((0,0),(1,1))
  - Then: path never steps directly (0,0)→(1,1); routes around via (0,1); length ≥ 3
  - Edge cases: verify path passes through (0,1) and (0,0)→(1,0) diagonal never taken

- **AC3(b)**: 单侧阻塞（下邻 solid）
  - Given: (0,1) solid, (1,0) open, target (1,1)
  - When: get_path((0,0),(1,1))
  - Then: path never steps directly (0,0)→(1,1); routes around via (1,0); length ≥ 3
  - Edge cases: mirror of (a); verify route around via (1,0)

- **AC3(c)**: 双侧阻塞
  - Given: both (1,0) and (0,1) solid, target (1,1)
  - When: get_path((0,0),(1,1))
  - Then: returns empty array (no route)
  - Edge cases: target fully enclosed by solids (redundant with Story 003 AC4 but exercised here)

- **AC3(d)**: 双侧开放
  - Given: both (1,0) and (0,1) open, target (1,1)
  - When: get_path((0,0),(1,1))
  - Then: direct diagonal allowed; path length 2
  - Edge cases: longer diagonal runs (e.g. (0,0)→(5,5)) use diagonals throughout

---

## Test Evidence

**Story Type**: Logic
**Required evidence**:
- `tests/unit/navigation/diagonal_corner_rules_test.gd` — must exist and pass

**Status**: [ ] Not yet created

---

## Dependencies

- Depends on: Story 001 (AStarGrid2D configuration — the mode this story verifies)
- Unlocks: Story 004 (solidity sync interacts with diagonal rules)
