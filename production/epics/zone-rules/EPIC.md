# Epic: ZoneRules

> **Layer**: Feature
> **GDD**: design/gdd/zone-rules.md
> **Architecture Module**: ZoneRules — stateless pure function; owns nothing; exposes `evaluate(snapshot: GridStateReader) -> Dictionary`
> **Status**: Ready
> **Stories**: 4 stories created — see below

## Stories

| # | Story | Type | Status | ADR |
|---|-------|------|--------|-----|
| 001 | Pure evaluate() and Effect Vocabulary | Logic | Ready | ADR-0003 |
| 002 | zone_synergy with Perimeter Normalization | Logic | Ready | ADR-0003 |
| 003 | spaciousness Formula | Logic | Ready | ADR-0003 |
| 004 | Preview==Commit Equivalence and Invalid Equipment | Logic | Ready | ADR-0001, ADR-0003 |

## Overview

ZoneRules is the **pure function** that scores the static quality of a placed layout. Given a read-only snapshot of the gym floor, it computes, for every placed equipment instance, non-negative effect bonuses — `zone_synergy` (reward for putting same-function equipment orthogonally adjacent), `spaciousness` (reward for leaving open breathing room), and passes through each equipment's authored `comfort` — and returns them per instance. It owns **no state and no randomness**: `evaluate(snapshot)` depends only on its inputs, so the *same* function scores both a committed layout (real snapshot) and a placement preview (speculative snapshot) — the `preview == commit` equivalence that makes drag-preview synergy feedback possible with no dependency cycle back to PlacementSystem. ZoneRules is static and member-independent: the dynamic half belongs to Congestion.

**No replacement stub** — `src/systems/zone_rules.gd` does not exist yet. Create it as `class_name ZoneRules extends RefCounted` (stateless; per ADR-0001 the stateless-systems exception means it may omit the SimSystem init machinery — it takes the snapshot + catalog as call parameters). It contributes NOTHING to the save file (TR-ZR-007).

## Governing ADRs

| ADR | Decision Summary | Engine Risk |
|-----|-----------------|-------------|
| ADR-0001: DI Container & Scene Bootstrap | ZoneRules is a stateless pure function: receives `GridStateReader` as a parameter, does not hold a persistent reference, may omit `_post_init()` (stateless-systems exception). No lifecycle, no RNG, no serialization. | LOW |
| ADR-0003: GridStateReader Contract | Requires `get_placed_instances() -> Array[PlacedInstance]` on the read surface (already added — TR-ZR-002 satisfied). Reads `is_solid`, `get_dimensions` for spaciousness. Consumes `EquipmentCatalog.get_definition(id)` for `zone_membership` + authored `comfort` (immutable, injected). Never duck-types the grid read surface. | LOW |

## GDD Requirements

| TR-ID | Requirement | ADR Coverage |
|-------|-------------|--------------|
| TR-ZR-001 | Pure function evaluate(snapshot: GridStateReader) -> Dictionary; no mutable state, no RNG | ADR-0001, ADR-0003 ✅ |
| TR-ZR-002 | Requires GridStateReader to expose get_placed_instances() -> Array[PlacedInstance] (hard prerequisite) | ADR-0003 ✅ |
| TR-ZR-003 | Effect-tag vocabulary: comfort (Catalog-authored), zone_synergy (computed), spaciousness (computed); all non-negative | ADR-0003 ✅ |
| TR-ZR-004 | zone_synergy = S_max * (1 - e^(-k * r_i)) where r_i = n_same_i / N_max_i (perimeter-normalized) | ADR-0003 ✅ |
| TR-ZR-005 | spaciousness = C_max * (open_adj_i / total_adj_i); reads only static solidity, no member data | ADR-0003 ✅ |
| TR-ZR-006 | Adjacency = orthogonal edge-sharing only (no diagonal), consistent with Navigation no-corner-cut rule | ADR-0003 ✅ |
| TR-ZR-007 | ZoneRules has NO serialization; stateless pure function | ADR-0001 ✅ |

## Definition of Done

This epic is complete when:
- All stories are implemented, reviewed, and closed via `/story-done`
- All acceptance criteria from `design/gdd/zone-rules.md` are verified (AC1–AC17, incl. AC2 preview==commit)
- `src/systems/zone_rules.gd` exists as a stateless pure function; no serialization, no RNG, no member-state reads (enforced by static check AC13)
- All Logic stories have passing test files in `tests/unit/zone_rules/` (fake GridStateReader / EquipmentCatalog stubs)
- Preview==commit equivalence (AC2) passes — the single most important test

## Next Step

Work through stories in order — each story's `Depends on:` field tells what must be DONE before it can start.
