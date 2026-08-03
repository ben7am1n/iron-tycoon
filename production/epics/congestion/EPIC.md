# Epic: Congestion

> **Layer**: Feature
> **GDD**: design/gdd/congestion.md
> **Architecture Module**: Congestion — owns `prev` buffer, per-cell `smoothed`, per-equipment scalar; exposes `per_equipment_congestion(id)`, `per_cell_density(cell)`, `access_reachable` flag
> **Status**: Complete — 2026-08-03 (all 4 stories Complete)
> **Stories**: 4 stories created — see below

## Stories

| # | Story | Type | Status | ADR |
|---|-------|------|--------|-----|
| 001 | Per-Equipment Congestion Scalar + EMA | Logic | Complete — 2026-08-02 | ADR-0005 |
| 002 | Per-Cell Density Field | Logic | Complete — 2026-08-02 | ADR-0005 |
| 003 | access_reachable and grid_changed Handling | Logic | Complete — 2026-08-02 | ADR-0003, ADR-0005 |
| 004 | Determinism and Serialization | Integration | Complete — 2026-08-03 | ADR-0002, ADR-0005 |

## Overview

Congestion turns raw member movement into the "flow" signal the entire MVP hypothesis rests on. Running **second** each tick (after MemberSim has moved everyone), it produces: (1) a per-equipment-instance congestion scalar in [0,1] that MemberSim reads one tick later (`Congestion(t-1)`) to steer members away from crowded machines; (2) a per-cell density field in [0,1] that the Congestion/Flow Overlay renders as a heatmap; and (3) a per-equipment `access_reachable` flag (event-driven, recomputed only when the grid changes) that surfaces when the player has accidentally walled a machine off. It is a pure, deterministic function of member positions and states (no RNG) with EMA temporal smoothing so the signal doesn't flicker.

**✅ Real implementation landed (2026-08-02/03)**: `src/systems/congestion.gd` is the full Congestion (CG-001..004) replacing the SL-002 core-layer integration stub. The public contract surface is preserved exactly: `class_name Congestion extends SimSystem`, `init(orchestrator, seeded_rng)` (extra OPTIONAL grid/member_sim/config/navigation/entrance_cell params default so pre-wiring call sites keep working), `system_name() -> "Congestion"`, `serialize()` / `deserialize(data, validate_only)` two-phase protocol. The real system uses NO RNG (GDD Core Rule 1) — the sub-stream is still registered (SaveLoad AC7 iterates get_rng() over all systems) but never drawn. Serialize shape is now `{counter, rng_state, prev, smoothed_cells}` with floats hex-encoded (story-004 deviation — engine-verified; see story-004 Test Evidence).

## Governing ADRs

| ADR | Decision Summary | Engine Risk |
|-----|-----------------|-------------|
| ADR-0003: GridStateReader Contract | Congestion reads access-cell locations and placed-instance geometry through the typed read surface; subscribes to `grid_changed` (S1) for equipment removal and reachability recompute. | LOW |
| ADR-0005: Signal Bus & Event Routing | Congestion is the second system in the hardcoded tick dispatch (after MemberSim). Emits `congestion_updated()` (S8) — zero payload, once per tick after recompute, for overlay consumption. Double-buffer `prev`/`next` with a single swap after all entities processed = the `Congestion(t-1) → routing(t)` mechanism. | LOW |

## GDD Requirements

| TR-ID | Requirement | ADR Coverage |
|-------|-------------|--------------|
| TR-CONG-001 | Runs SECOND each tick after MemberSim; pure function of member state, NO RNG | ADR-0005 ✅ |
| TR-CONG-002 | Double-buffering: prev (read-only) and next (write target); single swap after all entities processed | ADR-0005 ✅ |
| TR-CONG-003 | Per-equipment congestion [0,1] = occupancy tier + local density + EMA smoothing (alpha=0.3) | ADR-0005 ✅ |
| TR-CONG-004 | Per-cell density field [0,1]: kernel splat (self=1.0, 4-neighbors=w_n) + EMA (beta=0.4) + normalization | ADR-0005 ✅ |
| TR-CONG-005 | access_reachable flag: event-driven recompute on grid_changed via Navigation.get_path | ADR-0003, ADR-0005 ✅ |
| TR-CONG-006 | Serialize prev + per-cell smoothed; next transient; access_reachable recomputed on load | ADR-0002 ✅ |
| TR-CONG-007 | Determinism requires fixed float-summation order (ascending cell index / ascending equipment_instance_id) | ADR-0005 ✅ |
| TR-CONG-008 | Emit congestion_updated signal (10 Hz) for overlay consumption | ADR-0005 ✅ |
| TR-CONG-009 | EMA smoothing: alpha=0.3 gives tau~3.3 ticks; prevents thrash | ADR-0005 ✅ |

## Definition of Done

This epic is complete when:
- All stories are implemented, reviewed, and closed via `/story-done`
- All acceptance criteria from `design/gdd/congestion.md` are verified (AC1–AC16)
- `src/systems/congestion.gd` stub is fully replaced by the real double-buffered system, preserving the SaveLoad contract surface
- All Logic stories have passing test files in `tests/unit/congestion/`
- Signal emit arity verified for `congestion_updated` (0 args) via GUT spy test
- Congestion tick order verified: runs after MemberSim in `SimulationOrchestrator._advance_tick()`
- AC1 determinism (bit-identical run-to-run) and AC14 serialization round-trip pass

## Next Step

Work through stories in order — each story's `Depends on:` field tells what must be DONE before it can start.
