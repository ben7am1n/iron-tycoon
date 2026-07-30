# SaveLoad (tick-boundary coordinator)

> **Status**: Designed (2026-07-20 design-review: B1 tick_completed 事实错误已更正 + B2 validate 模式传播路径已注明)
> **Author**: user + agents
> **Last Updated**: 2026-07-20
> **Implements Pillar**: Foundation — enables Pillar 2 (松弛不紧绷: "close the game, come back exactly where you left off" — no lost progress, no anxiety)
> **Creative Director Review (CD-GDD-ALIGN)**: Skipped — Lean review mode (not a PHASE-GATE at lean).

## Overview

SaveLoad is a **coordinator, not a state owner**. It holds no game state of its own; its whole job is to (a) collect each sim system's `serialize()` output into one save blob, (b) on load, call each system's `deserialize()` in the one correct order the dependency graph allows, (c) guarantee saves are taken only at **tick boundaries** (never mid-tick — leaning on TimeSystem's no-mid-tick-yield rule, so this is a free structural guarantee, not a runtime check), and (d) treat a load as **all-or-nothing** so a corrupt save can never half-apply and leave a Frankenstein session. It exists because a game whose simulation must reproduce deterministically after reload (seeded RNG, fixed tick order, integer grid paths) needs a single arbitrator of *what gets saved, in what order it comes back, and what happens when it doesn't* — scattering that across systems would guarantee load-order bugs and silent state corruption.

## Player Fantasy

SaveLoad has no fantasy of its own — its success is measured by *invisibility*. The player closes the game mid-rearrange, comes back tomorrow, and the gym is exactly as they left it: the same members mid-workout, the same money, the same reputation, the same layout — resumed **paused**, so nothing has run off without them. The feeling it protects is **trust**: the quiet confidence that the game will never lose your work or silently scramble it, which is a precondition for Pillar 2's calm (you can't relax in a game you don't trust to remember you). The only time the player should ever notice SaveLoad is when a save is genuinely incompatible — and even then, it fails gently with a clear message, never a crash.

## Detailed Design

### Core Rules

1. **Tick-boundary saves (structural, not polled).** SaveLoad never checks "are we mid-tick?" It defers a save request to fire from TimeSystem's `tick_completed(tick_count)` signal — which TimeSystem already emits at the end of each tick sequence (time-system.md Core Rule 5, AC5). Because TimeSystem forbids mid-tick yielding, "between ticks" is a clean, consistent snapshot for free. SaveLoad subscribes to this signal; no new interface is required from TimeSystem.

2. **Save composition — one ordered blob.** The blob is:
   ```
   save_blob = { version, master_seed,
     time_system, grid_system, member_sim, congestion, satisfaction, economy }
   ```
   Each field is that system's `serialize()` output. The *order of serialize calls doesn't matter for correctness* (each reads only its own state) but is kept stable for diff/migration tooling. `master_seed` is duplicated at top level for save-file introspection only — TimeSystem's copy is authoritative on load (read-only redundancy, not a second source of truth). ZoneRules, Navigation, PlacementSystem, and SelectionSystem contribute **nothing** (pure/derived — see load order).

3. **Load order (the critical rule — enforced programmatically, not by convention).**
   1. `TimeSystem.deserialize()` — restores RNG streams + `tick_count`; **forces `paused = true`** regardless of saved speed.
   2. `GridSystem.deserialize(data, buildable_snapshot)` — the geometric ground truth everything references. `buildable_snapshot` (level geometry) is supplied by the **level loader**, NOT from the save (see Dependencies).
   3. `PlacementSystem.rederive_counter()` — `max(occupant_id)+1` from the loaded grid; must run **after** GridSystem (it serializes nothing itself).
   3a. `SelectionSystem.rebuild_mapping()` — loads every occupied cell from GridSystem, reconstructs `instance_id → {equipment_id, anchor, rotation}` mapping; must run **after** GridSystem, **before** the session unpauses (Core Rule 8 of selection-system.md). SelectionSystem serializes nothing itself.
   4. `Navigation.rebuild(GridSystem occupancy)` — AStarGrid2D re-init; **after** GridSystem, **before** MemberSim (which needs path validity on resume).
   5. `MemberSim.deserialize()` — members reference `equipment_instance_id`s from step 2; rebuild the reservation map from members' serialized claims.
   6. `Congestion.deserialize()` — `prev` buffer + per-cell `smoothed`; `access_reachable` **recomputed** from the loaded grid, not deserialized.
   7. `Satisfaction.deserialize()` — `global_satisfaction` + `member_accumulators`.
   8. `Economy.deserialize()` — `balance`.
   Grid must land first and succeed before anything reads it; PlacementSystem/Navigation are pure *rebuild* steps wedged between Grid and its dependents; ZoneRules needs no step (stateless pure function).

4. **All-or-nothing integrity — stage-then-commit.**
   - **Phase A (validate, zero mutation)**: run each system's `deserialize()` in a **non-mutating validate/dry-run mode** in load order. Any failure (missing field; GridSystem's own `LEVEL_GEOMETRY_MISMATCH`/`CORRUPTED_SAVE_OVERLAP`; a member referencing an `equipment_instance_id` absent from the validated grid) aborts with **no mutation to any system** — the current session (or fresh-game state) is untouched.
   - **Phase B (commit)**: only after all systems report valid, re-run `deserialize()` for real, in order. A Phase B failure (should be impossible after Phase A) is treated as fatal-to-menu, never silent partial state.
   - This requires every system's `deserialize()` to support a non-mutating validate mode — a **cross-system handoff** to each owning GDD (see Open Questions). Stage-then-commit is preferred over load-into-fresh-instances-then-swap (swap transiently doubles memory and some systems, e.g. Navigation, aren't cheaply duplicable). **Propagation path**: the validate-mode requirement must be recorded in each coordinated system's GDD during `/create-architecture` (not here — SaveLoad only defines the protocol; each system defines its own contract). SelectionSystem (#13) additionally requires a load-time mapping rebuild step (see its Core Rule 8) in SaveLoad's Phase B order.

5. **Determinism contract.** A load reproduces the exact resume point iff: (a) TimeSystem restores RNG stream states exactly, (b) tick order resumes identically, and (c) **Navigation's AStarGrid2D tie-break is bit-identical across rebuild** — ✅ **verified 2026-07-21** (ADR-0007 gate PASSED, 10/10 processes bit-identical).

6. **Versioning.** A `version` field; MVP is **exact-match only** — a mismatch is rejected with a user-facing "incompatible save" message, no crash, no partial load, no auto-migration. (Storage format — JSON/binary/Resource — is an ADR concern, not decided here.)

7. **Resume paused, always.** However the game was saved (1x/2x/3x/paused), load always resumes **paused** (TimeSystem's rule) — so the restored simulation never runs off before the player has their bearings (Pillar 2).

### States and Transitions

| From | Event | To | Notes |
|---|---|---|---|
| idle | save requested | deferred → fires at next tick boundary | never mid-tick |
| idle | load requested | Phase A (validate) | on any current session or fresh boot |
| Phase A | all systems valid | Phase B (commit) → loaded, paused | |
| Phase A | any validation failure | aborted, state untouched, error surfaced | all-or-nothing |
| any | version mismatch | rejected gracefully, no mutation | user-facing message |

### Interactions with Other Systems

- **Coordinates (calls serialize/deserialize on)**: TimeSystem, GridSystem, MemberSim, Congestion, Satisfaction, Economy. (PlacementSystem `rederive_counter`, SelectionSystem `rebuild_mapping`, and Navigation `rebuild` are derivation steps; ZoneRules untouched.)
- **TimeSystem**: needs a `tick_completed` hook for the tick-boundary save (handoff).
- **Level loader / scene bootstrap**: provides `buildable_snapshot` (level geometry) **before** `GridSystem.deserialize()` — GridSystem cannot proceed without it. In MVP (single fixed level) this is the compiled-in level definition.
- **Save/load UI**: a menu (main-menu / pause-menu) triggers save/load — not in the MVP systems index as its own entry; flagged.

## Formulas

SaveLoad performs **no numerical calculations** — it is a coordinator. The only decision predicate is the version check: `load_permitted = (save_blob.version == SAVE_FORMAT_VERSION)` (exact match for MVP). No variables beyond that boolean; no ranges, no tuning math.

## Edge Cases

- **Corrupt / truncated save**: fails at Phase A parse → no mutation → user-facing error.
- **Buildable mismatch** (save loaded against different level geometry): GridSystem's own `LEVEL_GEOMETRY_MISMATCH` in Phase A → whole load fails, nothing mutated.
- **Save with > ~200 grid records**: intersects GridSystem's unresolved OQ12 (full-fail policy re-review). SaveLoad must **not** assume all-or-nothing scales silently — flagged as a joint open question (see Open Questions).
- **Empty save / new game**: SaveLoad is bypassed entirely; systems init fresh (no `deserialize` call).
- **Version mismatch**: rejected per Core Rule 6, graceful, no crash.
- **A member referencing a missing `equipment_instance_id`**: Phase A validation failure in MemberSim's dry-run → whole load fails (never a silent orphan/drop — silently corrupting state would violate the trust Pillar 2 depends on).

## Dependencies

**Coordinates (hard — calls their serialize/deserialize)**:

| System | Interface | Nature |
|---|---|---|
| TimeSystem | `serialize()`/`deserialize()`; **`tick_completed` hook** for boundary save | Hard |
| GridSystem | `serialize()`/`deserialize(data, buildable_snapshot)` (all-or-nothing, validate mode) | Hard |
| MemberSim | `serialize()`/`deserialize()` (validate mode) | Hard |
| Congestion | `serialize()`/`deserialize()` (validate mode) | Hard |
| Satisfaction | `serialize()`/`deserialize()` (validate mode) | Hard |
| Economy | `serialize()`/`deserialize()` (validate mode) | Hard |
| PlacementSystem | `rederive_counter()` (derivation, after Grid) | Hard |
| SelectionSystem (#13) | `rebuild_mapping()` (derivation, after Grid, before unpause — see selection-system.md Core Rule 8) | Hard |
| Navigation | `rebuild(occupancy)` (derivation, after Grid) | Hard |
| Level loader | provides `buildable_snapshot` before Grid deserialize | Hard |

**Bidirectional consistency notes**: each coordinated system's GDD already defines what it serializes; this GDD only fixes the **order** and the **integrity protocol**. The two new asks — TimeSystem's `tick_completed` hook and every system's non-mutating validate mode — are handoffs (Open Questions). ZoneRules correctly serializes nothing. Verify at `/consistency-check`.

## Tuning Knobs

| Knob | Default | Safe Range | Notes |
|---|---|---|---|
| `SAVE_FORMAT_VERSION` | 1 | monotonic int | bump on any blob-shape change; MVP rejects mismatches |
| autosave policy | manual + on-exit (MVP) | — | periodic autosave cadence is a game-designer/producer UX call, not locked here |

## Visual/Audio Requirements

SaveLoad renders no world content. It needs only lightweight UI feedback (owned by the save/load menu, not here): a "Saved" confirmation and, on failure, the graceful "incompatible / corrupt save" message. No audio owned here (a soft save chime is a nice-to-have for audio-director).

## UI Requirements

A save/load menu (main-menu and/or pause-menu) invokes SaveLoad and surfaces its results (saved / loaded / rejected). That menu is not itself in the MVP systems index — flagged as a small UI dependency to add when the menu shell is built. SaveLoad exposes `save()`, `load()`, and result/error status for it to display.

## Acceptance Criteria

> SaveLoad is a **Logic/Integration** story — **BLOCKING** tests in `tests/integration/save_load/` (round-trip, atomicity) and `tests/unit/save_load/` (version, ordering).

1. **GIVEN** a save is requested, **WHEN** it executes, **THEN** it fires only between ticks (no `serialize` call can occur mid-tick-loop) — verified by asserting the save runs off the `tick_completed` hook.
2. **GIVEN** a saved game, **WHEN** it is loaded and both run N further ticks, **THEN** all coordinated systems' state is bit-identical to the pre-save continuation.
3. **GIVEN** a save with any Phase-A validation failure, **WHEN** load runs, **THEN** the current/fresh session is left completely unmutated (all-or-nothing).
4. **GIVEN** the load sequence, **WHEN** it runs, **THEN** deserialize order is enforced programmatically — PlacementSystem's counter re-derive and Navigation's rebuild cannot execute before `GridSystem.deserialize()`.
5. **GIVEN** any saved speed/paused state, **WHEN** loaded, **THEN** the game resumes `paused = true`.
6. **GIVEN** a save whose `version != SAVE_FORMAT_VERSION`, **WHEN** loaded, **THEN** it is rejected gracefully with a user-facing message, no crash, no mutation.
7. **GIVEN** per-system RNG stream states in the save, **WHEN** loaded, **THEN** each stream is restored exactly (never re-derived from `master_seed` alone).
8. **GIVEN** a save with > ~200 grid records, **WHEN** loaded, **THEN** it either loads correctly or is explicitly flagged as an untested boundary (must block ship, never silently mis-load).
9. **GIVEN** a member referencing an `equipment_instance_id` absent from the grid, **WHEN** Phase A validates, **THEN** the whole load fails (no silent orphan).

## Open Questions

| # | Question | Owner | Target Resolution |
|---|---|---|---|
| OQ1 | ✅ **RESOLVED (2026-07-21)**: Navigation OQ1 passed — ADR-0007 gate test verified AStarGrid2D cross-rebuild tie-break is bit-identical (10/10 independent processes). SaveLoad determinism contract condition (c) is now proven. | — | Closed |
| OQ2 | ✅ **RESOLVED (2026-07-20, design-review).** TimeSystem Core Rule 5 and AC5 already define `tick_completed(tick_count)` as a signal emitted at the end of each tick sequence → the boundary-save hook exists. SaveLoad subscribes to this signal; no new interface is needed from TimeSystem. | — | Closed |
| OQ3 | **Handoff**: every coordinated system's `deserialize()` must support a non-mutating **validate/dry-run mode** for Phase A. Confirm each system can do this (or accept two-pass cost). | Each coordinated system's owner + `/create-architecture` | At `/create-architecture` |
| OQ4 | **Joint with GridSystem OQ12**: the > ~200-record full-fail policy — does all-or-nothing scale, or does a large save need chunked/partial validation? | GridSystem + SaveLoad | When save sizes grow / before Vertical Slice |
| OQ5 | Storage format (JSON / binary / Godot Resource) and where saves live on disk. | `/create-architecture` | Architecture phase |
| OQ6 | `buildable_snapshot` provenance: confirm the level loader / scene bootstrap provides it before `GridSystem.deserialize()`. Trivial in MVP (single fixed level); matters when levels vary. | Level loader owner | When multiple levels exist |
| OQ7 | The save/load **menu** shell (main/pause menu) isn't in the MVP systems index — add it as a small UI task. | producer / ux-designer | Before a shippable build |