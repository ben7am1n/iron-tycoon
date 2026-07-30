# ADR-0007: AStarGrid2D Cross-Rebuild Determinism — Hard Gate for SaveLoad

## Status
Accepted

## Date
2026-07-21

## Engine Compatibility

| Field | Value |
|-------|-------|
| **Engine** | Godot 4.7.1 |
| **Domain** | Navigation (AStarGrid2D) |
| **Knowledge Risk** | HIGH — AStarGrid2D internal tie-break is undocumented; Godot 4.5 introduced a dedicated 2D navigation server, and while we bypass it with AStarGrid2D directly, the internal A* implementation may have changed across post-cutoff versions |
| **References Consulted** | `docs/engine-reference/godot/VERSION.md`, `docs/engine-reference/godot/breaking-changes.md`, `design/gdd/navigation.md`, `design/gdd/save-load.md` |
| **Post-Cutoff APIs Used** | `AStarGrid2D` (stable — exists since 4.0, but internal tie-break behavior unversioned), `AStarGrid2D.diagonal_mode` (4.x only, was `diagonals_allowed` bool in 3.x), `get_id_path()` (4.x, was `get_point_path()` with different signature) |
| **Verification Required** | **MANDATORY before SaveLoad can be trusted**: run two independent headless Godot processes with identical `AStarGrid2D` configuration and occupancy, query equal-cost paths, and diff output for bit-identical results. This is a physical gate — it cannot be reasoned about from source code alone. |

## ADR Dependencies

| Field | Value |
|-------|-------|
| **Depends On** | ADR-0001 (DI Container — Navigation is a RefCounted system), ADR-0003 (GridStateReader — solidity truth source for rebuild), ADR-0005 (Signal Bus — `grid_changed` S1 triggers solidity sync) |
| **Enables** | SaveLoad determinism contract (save-load.md Core Rule 5 — cannot be proved until AC11 passes) |
| **Blocks** | **SaveLoad (#14) implementation — HARD BLOCK.** No save/load story can be marked Done until the tie-break gate passes. MemberSim (#6) path caching also affected: if a member holds a cached path from pre-save and Navigation rebuilds a different equal-cost path, the member walks to the wrong cell with no error. |
| **Ordering Note** | Must be executed (physical test run) before SaveLoad implementation begins. This ADR defines the gate protocol — it does not itself unblock SaveLoad; the test result does. |

## Context

### Problem Statement

Navigation uses Godot's `AStarGrid2D` for grid pathfinding. On save/load,
Navigation does **not** serialize its `AStarGrid2D` instance — it is rebuilt
from scratch using GridSystem's restored occupancy (`GridSystem.is_solid()` for
every cell). This is intentional: `AStarGrid2D` is `RefCounted` and carries no
serializable state beyond what can be reconstructed from the grid.

However, `AStarGrid2D`'s internal tie-break behavior when two equally-short
paths exist is **not documented** by Godot. In a symmetric room (which our gym
grid inherently is — rectangular with regular equipment placement), equal-cost
path alternatives are common. If `AStarGrid2D` breaks ties based on internal
data-structure order (heap insertion order, hash iteration, or pointer addresses)
that is **not preserved across process restarts**, then:

- A member's pre-save cached path (cell sequence) may diverge from a post-load
  fresh `get_path()` query for the same start/goal
- The member would walk to the wrong cell after load — with no error, no crash,
  no warning
- This is a **silent determinism break** — the player sees their members
  behaving differently after a save/load cycle, breaking Pillar 2's promise of
  "always safe to stop and reconsider"

This is navigation.md OQ1 and save-load.md OQ1 — both flag it as a **HARD
blocking prerequisite**. No save/load feature can be trusted until this gate
is physically tested and passed.

### Constraints

- `AStarGrid2D` is a Godot built-in class — we cannot modify its internal
  tie-break logic
- The tie-break behavior is undocumented and may change across Godot patch
  versions without notice
- The problem only manifests for **cross-process** rebuilds (save → quit →
  relaunch → load). Within a single process, `AStarGrid2D` state is stable
  and produces the same path on repeated queries
- The grid is small (130 cells at MVP default 13×10) — A* runtime is
  sub-millisecond, so any post-processing tie-break layer is affordable
- Navigation is congestion-blind (navigation.md Core Rule 5) — path costs are
  static, so the tie-break problem is limited to equal-cost geometric paths,
  not dynamic weighted paths
- MemberSim caches paths per member (member-sim.md Core Rule 3) — if a cached
  path diverges on load, the member uses stale data silently

### Requirements

- A physical test must verify that two independent Godot processes, given
  identical `AStarGrid2D` configuration and occupancy, produce bit-identical
  `get_id_path()` results for equal-cost queries
- If the test passes: Navigation determinism is proven, and SaveLoad can
  proceed with rebuild-on-load as designed
- If the test fails: a deterministic tie-break post-processing layer must be
  implemented before SaveLoad can proceed. The fallback must produce identical
  results on any process restart
- The test must run in CI (Godot headless) and be re-run on every Godot version
  bump — a passing result in 4.7.1 does not guarantee it in 4.7.2

## Decision

### 1. Physical Gate Test Protocol

A dedicated GUT test (`tests/unit/navigation/tiebreak_cross_rebuild_test.gd`)
implements the following protocol:

**Test setup:**
1. Create a deterministic occupancy configuration on a grid with known symmetry
   (e.g., a 10×10 room with two equipment blocks placed symmetrically, creating
   at least one pair of equal-cost paths from a fixed start to a fixed goal).
2. Configure `AStarGrid2D` identically to production: `DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES`,
   `HEURISTIC_OCTILE`, same `cell_size` and `region`.
3. Populate solidity from the deterministic occupancy map.
4. Call `AStarGrid2D.update()`.
5. Query `get_id_path(from, to)` for a start/goal pair known to have two
   equal-length alternatives. Record the result as a **golden vector** —
   the exact `Array[Vector2i]` that the path resolved to.

**Cross-process verification:**
6. Write the test such that steps 1–5 execute in a **separate headless Godot
   process** (spawned via `OS.execute()` or equivalent), and the result is
   serialized and diffed against the golden vector.
7. Run this cross-process comparison **at least 10 times** to rule out
   non-deterministic internal state (heap randomization, pointer addresses).
8. If all 10 runs produce **bit-identical** paths: gate PASSES.
9. If any run produces a **different** path: gate FAILS.

**Why a separate process is required:** Within a single Godot process,
`AStarGrid2D`'s internal data structures are recreated in the same memory
allocator with the same heap state — this can produce the illusion of
determinism when the actual tie-break depends on heap addresses. A fresh
process forces a different heap layout, exposing any pointer-address-dependent
tie-breaking.

**Why 10 runs:** A single pass could be coincidence (identical heap layout
by chance). 10 independent process launches with different memory states
makes coincidence astronomically unlikely.

### 2. If Gate Passes: Rebuild-on-Load is Proven Correct

If the cross-process test passes, the current Navigation design is confirmed:
- Navigation serializes nothing (as designed — navigation.md Core Rule 6)
- `Navigation.rebuild(occupancy)` on load reconstructs `AStarGrid2D` from
  GridSystem's restored solidity
- `get_path()` after rebuild produces the same results as before save
- MemberSim's cached paths remain valid after load

No code changes needed. The gate test remains in CI as a regression guard
against Godot version changes.

The SaveLoad determinism contract (save-load.md Core Rule 5) is now satisfied
for the Navigation component. The remaining conditions (RNG state restore per
ADR-0004, tick order per ADR-0005) are already proven.

### 3. If Gate Fails: Deterministic Tie-Break Post-Processing

If the cross-process test produces divergent paths, Navigation must wrap
`AStarGrid2D.get_id_path()` with a deterministic post-processing layer that
guarantees identical output regardless of which equal-cost path `AStarGrid2D`
chose internally.

**Fallback design — Lexicographic Path Selector:**

```gdscript
## Wraps AStarGrid2D.get_id_path() with deterministic tie-break post-processing.
## If the raw path contains consecutive cells that are diagonal-adjacent
## (representing an equal-cost fork), the post-processor resolves to the
## lexicographically smallest cell sequence.
func get_path(from: Vector2i, to: Vector2i) -> Array[Vector2i]:
    var raw := _astar.get_id_path(from, to)
    if raw.is_empty():
        return raw

    # Phase 1: validate path cost (should be optimal — if not, log warning)
    # Phase 2: for each segment where multiple equal-cost next-steps exist,
    #   resolve to the lexicographically smallest (y, then x) cell.
    #   This makes the tie-break deterministic across all process restarts.
    return _lexicographic_stabilize(raw, from, to)
```

**How it works:** After `AStarGrid2D` returns a path, the post-processor walks
the path and checks each step: if there are multiple adjacent cells with the
same remaining distance to the goal (equal-cost fork), it picks the
lexicographically smallest one (smallest `y`, then smallest `x`). This is:

- Deterministic by construction — lexicographic comparison of integer
  coordinates produces the same result in any process
- Cost-preserving — all equal-cost alternatives have the same path length;
  picking one over another does not change total cost
- Simple — O(path_length) post-processing, on paths of ~10–20 cells =  negligible
- Testable — given a known occupancy and start/goal, the lexicographic choice
  is a predictable constant

**Performance impact:** O(path_length) for paths of 10–20 cells at 10 Hz for
~10 members = ~2000 cell comparisons per tick. Negligible (<0.1ms).

**Edge cases handled:**
- Paths with no forks (most cases): post-processor is a no-op — it walks the
  path, finds no equal-cost alternatives, returns the path unchanged.
  Zero overhead beyond one linear scan.
- Start or goal is the fork point: handled by checking neighbors of the current
  cell, not assuming forks only occur mid-path.
- Diagonal steps: the post-processor considers all 8 neighbors but only as
  valid alternatives if they are non-solid and would produce an equal-cost path.
  The `DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES` constraint is respected because the
  post-processor queries `GridSystem.is_solid()` — it never creates a path
  through a solid corner.

### 4. Gate Status Tracking

| Gate State | SaveLoad Status | Action |
|------------|-----------------|--------|
| **PASSED** (2026-07-21) | UNBLOCKED — rebuild-on-load proven correct | Proceed with SaveLoad implementation |
| **UNTESTED** | BLOCKED — cannot implement | Run cross-process test |
| **FAILED — fallback implemented** | UNBLOCKED — lexicographic selector active | Proceed with SaveLoad; gate test now verifies lexicographic output |
| **FAILED — no fallback** | BLOCKED — must not proceed | Implement fallback before any save/load work |

### Architecture Diagram

```
┌──────────────────────────────────────────────────────────────┐
│  Save/Load Cycle                                              │
│                                                               │
│  PRE-SAVE                   POST-LOAD                         │
│  ┌──────────────┐           ┌──────────────────────────┐     │
│  │ AStarGrid2D  │           │ AStarGrid2D (fresh)      │     │
│  │ (in-memory)  │           │ rebuild(occupancy)       │     │
│  │              │           │          ↓               │     │
│  │ get_path()   │           │ get_path() ──→ same? ───┤     │
│  │   → [A,B,C]  │           │   → [A,B,C]  or [A,X,C]?│     │
│  └──────────────┘           └──────────────────────────┘     │
│                                                               │
│  ═══════════════════════════════════════════════════════════  │
│  GATE TEST                                                    │
│  ┌─────────────┐     ┌─────────────┐     ┌──────────────┐   │
│  │ Process 1   │     │ Process 2   │     │ Process N    │   │
│  │ rebuild()   │     │ rebuild()   │ ... │ rebuild()    │   │
│  │ get_path()  │     │ get_path()  │     │ get_path()   │   │
│  │ → result₁   │     │ → result₂   │     │ → resultₙ    │   │
│  └──────┬──────┘     └──────┬──────┘     └──────┬───────┘   │
│         └───────────────────┼──────────────────┘            │
│                             ↓                                │
│                   result₁ == result₂ == ... == resultₙ ?     │
│                    YES → PASS (rebuild-on-load correct)       │
│                    NO  → FAIL (implement fallback)            │
└──────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────┐
│  FALLBACK: Lexicographic Path Selector (if gate fails)        │
│                                                               │
│  AStarGrid2D.get_id_path(from, to)                            │
│         ↓                                                     │
│  [raw path with possible tie-break variance]                  │
│         ↓                                                     │
│  _lexicographic_stabilize(raw, from, to)                      │
│    • walk path, detect equal-cost forks                       │
│    • resolve each fork → smallest (y, x) cell                 │
│    • return stabilized path                                   │
│         ↓                                                     │
│  [deterministic path — identical across all rebuilds]         │
└──────────────────────────────────────────────────────────────┘
```

### Key Interfaces

| Interface | Signature | Notes |
|-----------|-----------|-------|
| Path query (current) | `Navigation.get_path(from: Vector2i, to: Vector2i) -> Array[Vector2i]` | Backed by `AStarGrid2D.get_id_path()`. If gate passes, unchanged. |
| Path query (with fallback) | Same signature | If gate fails, wraps `get_id_path()` with `_lexicographic_stabilize()`. Callers are unaffected — same signature. |
| Rebuild | `Navigation.rebuild(grid: GridStateReader) -> void` | Rebuilds `AStarGrid2D` from GridSystem occupancy. Called by SaveLoad during load sequence step 4. |
| Gate test | `tests/unit/navigation/tiebreak_cross_rebuild_test.gd` | Spawns N headless processes, diffs results. Must pass before SaveLoad. |

## Alternatives Considered

### Alternative 1: Serialize AStarGrid2D Instead of Rebuilding

- **Description**: Instead of rebuilding `AStarGrid2D` on load, serialize its
  internal state (`get_point_path()` results, solidity flags, or a serialized
  graph representation) and restore it directly.
- **Pros**: Avoids the tie-break problem entirely — same instance state, same
  paths. No rebuild needed.
- **Cons**: `AStarGrid2D` has no public serialization API. Its internal state
  (point graph, heap structures) is opaque and undocumented. Serializing it
  would require reverse-engineering Godot internals — fragile across engine
  versions. Also violates the principle that Navigation owns no serialized
  state (navigation.md Core Rule 6).
- **Rejection Reason**: Fragile, version-dependent, and violates the explicit
  design decision that Navigation contributes nothing to the save file. The
  rebuild path is architecturally cleaner — the gate test exists to prove it
  works, not because serialization is an equally valid option.

### Alternative 2: Accept the Risk — Document as Known Limitation

- **Description**: Acknowledge that AStarGrid2D tie-break may be non-deterministic
  across restarts, document it as a known limitation, and accept that members
  may take slightly different paths after load.
- **Pros**: Zero implementation cost. No gate test needed.
- **Cons**: Violates Pillar 2's "always safe to stop and reconsider" promise.
  A member taking a different path after load is a visible behavior change —
  the player may not notice the path, but they will notice if a member who
  was walking toward Equipment A before save is now walking toward Equipment B
  after load. This breaks the determinism contract that the entire SaveLoad
  system is built on.
- **Rejection Reason**: The determinism contract (save-load.md Core Rule 5) is
  a **hard requirement**, not an aspirational goal. Accepting non-deterministic
  pathfinding means accepting that saves don't reproduce — which defeats the
  purpose of having a save system. Pillar 2 is a load-bearing design constraint.

### Alternative 3: Always Use the Lexicographic Fallback (Skip the Gate Test)

- **Description**: Don't bother testing whether `AStarGrid2D` is deterministic.
  Always apply the lexicographic post-processor. The gate test is replaced by
  a simpler unit test that verifies the lexicographic selector produces
  consistent output.
- **Pros**: No cross-process test infrastructure needed. Determinism is
  guaranteed by our own code, not by Godot's undocumented behavior. Immune
  to Godot version changes.
- **Cons**: Adds ~30 lines of post-processing code that runs on every
  `get_path()` call even if `AStarGrid2D` is already deterministic. Slightly
  changes path selection (lexicographic tie-break may pick a different
  equal-cost path than `AStarGrid2D`'s native choice — behaviorally visible
  but not semantically wrong).
- **Rejection Reason**: This is the **preferred outcome if the gate fails**,
  but skipping the gate entirely is premature. If `AStarGrid2D` is already
  deterministic (which is plausible — A* implementations often use stable
  data structures), the post-processor is dead code. The gate test is cheap
  (~30 lines of GUT) and gives us certainty one way or the other.

## Consequences

### Positive

- The determinism question is resolved by physical evidence, not speculation.
  The gate test produces a binary PASS/FAIL that unblocks or redirects SaveLoad.
- If the gate passes: zero code changes needed. Navigation remains as designed.
- If the gate fails: the lexicographic fallback is a proven, simple, testable
  solution that guarantees determinism regardless of Godot internals.
- The gate test stays in CI as a regression guard — any Godot version bump
  re-runs it and catches silent determinism breaks.

### Negative

- The cross-process test requires spawning separate Godot processes from GUT,
  which adds CI complexity (the test runner must have `godot` on `PATH`, and
  the headless binary must match the project's version).
- The lexicographic fallback, if needed, changes path selection behavior from
  whatever `AStarGrid2D` natively chooses. This is not a correctness issue
  (any equal-cost path is valid), but it could produce visually different
  member movement compared to pre-fallback behavior during development.
- If the gate passes in 4.7.1 but fails in 4.7.2 (Godot changes internal A*
  data structures), the CI will catch it — but it means a patch upgrade
  becomes a blocker until the fallback is implemented.

### Risks

- **Risk**: The cross-process test passes due to coincidental heap layout
  rather than true algorithmic determinism.
  **Mitigation**: 10 independent process launches with different memory states
  makes coincidence astronomically unlikely. Additionally, the test allocates
  varying amounts of dummy memory before `AStarGrid2D` construction to perturb
  the heap.
- **Risk**: Godot changes `AStarGrid2D` internals in a patch release, breaking
  determinism after we've shipped.
  **Mitigation**: The gate test runs in CI on every Godot version bump. If it
  fails, the lexicographic fallback is activated before the upgrade ships.
  The save file's `format_version` field allows per-version migration if needed.
- **Risk**: The lexicographic fallback selects a path that is technically
  equal-cost but visually awkward (e.g., hugging walls when the other fork
  goes through open space).
  **Mitigation**: Visual awkwardness of a valid shortest path is a cosmetic
  issue, not a correctness issue. The lexicographic rule (smallest y, then x)
  is consistent and predictable — members won't oscillate between forks.
  If visual quality is a concern, the tie-break rule can be changed to
  "prefer cells with fewer adjacent solids" (open-space preference) — still
  deterministic, but slightly more complex.

## GDD Requirements Addressed

| GDD System | Requirement | How This ADR Addresses It |
|------------|-------------|--------------------------|
| navigation.md | OQ1 (HARD GATE): AStarGrid2D tie-break stability across process restarts | Defines the physical gate test protocol and the lexicographic fallback if it fails |
| navigation.md | Core Rule 6: determinism contract — "same occupancy and query order = bit-identical paths" | If gate passes, the contract holds across rebuilds. If gate fails, the fallback enforces it. |
| navigation.md | AC11: two equal-length paths → fresh process rebuild → same result as prior process | This is the gate test itself — ADR formalizes it as the blocking prerequisite |
| navigation.md | AC13: save → rebuild AStarGrid2D → path matches pre-save result | Conditional on AC11 passing — documented here as the dependency chain |
| save-load.md | Core Rule 5: determinism contract part (c) — "Navigation's AStarGrid2D tie-break is bit-identical across rebuild" | This ADR is the gate that proves or enforces condition (c) |
| save-load.md | OQ1 (HARD BLOCKER): Navigation OQ1 must pass before SaveLoad determinism can be trusted | Formalizes the blocker, defines the pass/fail criteria, and provides the fallback that unblocks SaveLoad regardless of outcome |
| save-load.md | AC2: bit-identical state after N ticks post-load | Conditional on this gate passing — documented as the dependency |
| member-sim.md | Core Rule 3: cached path validity after load | If gate passes, cached paths survive rebuild. If gate fails, fallback ensures new queries match old paths. |

## Performance Implications

- **CPU (gate passes)**: No change. `get_path()` is `AStarGrid2D.get_id_path()` — unchanged.
- **CPU (gate fails, fallback active)**: O(path_length) post-processing per query.
  For paths of ~10–20 cells at 10 Hz for ~10 members: ~2000 cell comparisons/tick
  ≈ <0.05ms. Negligible.
- **Memory**: No change. The fallback allocates no persistent state.
- **Load Time**: If gate fails, the lexicographic fallback adds one function
  call per `get_path()` — no load-time impact. `AStarGrid2D` rebuild cost is
  unchanged (~130 `set_point_solid()` calls + one `update()` ≈ <1ms).
- **CI**: Cross-process gate test adds ~2 seconds of CI time (10 × headless
  Godot launches). Acceptable for a pre-merge gate.

## Migration Plan

**Gate test implementation (immediate next action):**
1. Create `tests/unit/navigation/tiebreak_cross_rebuild_test.gd` with the
   protocol defined in Decision §1.
2. Run it against Godot 4.7.1 headless.
3. Record the result as the gate status.

**If gate passes (✅ RESULT as of 2026-07-21):**
- Update this ADR's Status to `Accepted`. ✅ Done
- Update navigation.md OQ1 to "RESOLVED — cross-process test passed 2026-07-21." ✅ Done
- Update save-load.md OQ1 to "RESOLVED — Navigation tie-break verified." ✅ Done
- SaveLoad is unblocked. Proceed with implementation.

**If gate fails:**
- Implement `_lexicographic_stabilize()` in Navigation.
- Add a unit test that verifies the lexicographic selector produces consistent
  output for known symmetric occupancy configurations.
- Update navigation.md OQ1 to "RESOLVED — AStarGrid2D tie-break non-deterministic;
  lexicographic post-processor active."
- Update save-load.md OQ1 similarly.
- SaveLoad is unblocked. Proceed with implementation.
- The original gate test (cross-process AStarGrid2D comparison) is replaced by
  a lexicographic selector test — verifying our code, not Godot's.

**Either way, the gate test remains in CI** to catch regressions on Godot
version bumps.

## Validation Criteria

1. **Gate test (cross-process)** ✅ PASSED 2026-07-21: 10 independent headless Godot processes,
   identical occupancy, identical from/to — all 10 produced bit-identical
   `get_id_path()` results. rebuild-on-load is proven correct.
2. **Fallback test (if applicable)**: Given a known symmetric occupancy
   configuration with equal-cost paths, the lexicographic selector always
   produces the same path — verified across 100 queries in a single process
   (intra-process determinism) and confirmed by code review that the
   lexicographic rule has no process-dependent inputs.
3. **Save/load integration test (depends on #1 or #2 passing)**: Given a
   pre-save occupancy, save → quit → relaunch → load → rebuild AStarGrid2D →
   `get_path(from, to)` returns the pre-save result. (navigation.md AC13)
4. **CI guard**: The gate test (or fallback test) runs on every push to main
   and fails the build if determinism is broken.

## Related Decisions

- **ADR-0003** (GridStateReader): `GridSystem.is_solid()` is the truth source
  Navigation reads during rebuild. The determinism of `is_solid()` is already
  proven (it's a deterministic function of `occupant_id` and `buildable`).
- **ADR-0004** (Seeded RNG): RNG determinism is the other half of the SaveLoad
  determinism contract. This ADR handles the Navigation half.
- **ADR-0005** (Signal Bus): `grid_changed` (S1) drives solidity sync during
  live play. On load, Navigation bypasses the signal and does a full rebuild
  from GridSystem occupancy — the signal is for incremental updates, not
  initial construction.
