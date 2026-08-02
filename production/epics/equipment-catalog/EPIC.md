# Epic: EquipmentCatalog

> **Layer**: Foundation
> **GDD**: design/gdd/equipment-catalog.md
> **Architecture Module**: EquipmentCatalog — immutable, read-only data (`EquipmentDef` records)
> **Status**: Complete
> **Stories**: 7 stories completed — see below

## Stories

| # | Story | Type | Status | ADR |
|---|-------|------|--------|-----|
| 001 | EquipmentDef Data Model and Catalog Container | Logic | Complete | ADR-0001, ADR-0002 |
| 002 | JSON Loading and Anchor Normalization | Logic | Complete | ADR-0002 |
| 003 | Footprint Shape and Access Cell Validation | Logic | Complete | ADR-0002 |
| 004 | Validation Pipeline, strict_mode, and Duplicate ID Detection | Logic | Complete | ADR-0001, ADR-0002 |
| 005 | Use-Duration Field Validation | Logic | Complete | ADR-0002 |
| 006 | Provisional Cost Formula | Logic | Complete | ADR-0002 |
| 007 | Edge Cases — Empty Catalog, Unlock Requirements, and Cost Boundary | Integration | Complete | ADR-0001 |

## Overview

EquipmentCatalog is the gym's equipment data infrastructure layer: an immutable, read-only set of equipment definitions. Each definition declares footprint shape (`footprint_cells`), use position (`access_cells` — exactly 1 cell, MVP), purchase cost, static effects (zone synergy/satisfaction tags), zone membership, and use-duration parameters (`use_duration_mean_ticks`, `stddev`, `min`, `max`). Players never interact with this system directly — it is a pure data source consumed indirectly by PlacementSystem (drag shape/rotation), Shop/Purchase (price/unlock status), ZoneRules (zone effects), MemberSim (use durations), and Equipment Info Panel (VS phase details).

The catalog is loaded once at startup from a JSON file (`.catalog.json` — hand-authorable, VCS-diffable) and frozen for the session. A load-time validation step (`strict_mode: bool`, injectable for testability) enforces the cross-document contracts required by GridSystem and MemberSim: footprint non-empty, anchor normalized to `min==(0,0)`, access disjoint from footprint, exactly 1 access cell (MVP `N=1`), and all four `use_duration_*` fields within valid ranges. Without this system, every downstream consumer would maintain its own copy of equipment data — guaranteeing data-split bugs where shop display, placement preview, and runtime effects disagree.

## Governing ADRs

| ADR | Decision Summary | Engine Risk |
|-----|-----------------|-------------|
| ADR-0001: DI Container & Scene Bootstrap | Catalog loaded once at startup via DI injection into `SimulationOrchestrator`. No Autoload. `strict_mode` parameter injected (not `OS.is_debug_build()` check) — GUT tests can control both branches. | LOW |
| ADR-0002: Storage Format | Equipment catalog format: JSON (`.catalog.json`), hand-authorable, VCS-diffable. Coordinates normalized during load (shift to `min==(0,0)`). `JSON.new(); json.parse()` for designer-facing error line numbers. All load errors produce `LoadError` objects. | LOW |

## GDD Requirements

| TR-ID | Requirement | ADR Coverage |
|-------|-------------|--------------|
| TR-EC-001 | EquipmentDef immutable record: id, display_name, zone_membership, footprint_cells, access_cells, cost, unlock_requirement, effects, use_duration_mean/stddev/min/max_ticks | ADR-0002 ✅ |
| TR-EC-002 | footprint_cells shapes locked to 1×1, 1×2, 2×2 rectangular AABB; access_cells = exactly 1 cell orthogonally adjacent | ADR-0002 ✅ |
| TR-EC-003 | anchor_normalization at load: subtract (min_x, min_y) from union bbox; result must have min == (0,0) | ADR-0002 ✅ |
| TR-EC-004 | Load-time validation: footprint non-empty, anchor normalized, access∩footprint empty, access count==1, use_duration fields valid | ADR-0002 ✅ |
| TR-EC-005 | Catalog frozen after load; no runtime writes, only get_definition(id) read-only query | ADR-0001 ✅ |
| TR-EC-006 | strict_mode injectable boolean controls debug-abort vs release-skip-and-push_error behavior | ADR-0001 ✅ |
| TR-EC-007 | 4 pre-rotated variants per equipment explicitly forbidden; only canonical 0° stored | ADR-0002 ✅ |
| TR-EC-008 | provisional_equipment_cost = base_cost + tier_step × (footprint_area − 1); MVP values: 200/350/650 | ADR-0002 ✅ |
| TR-EC-009 | effects container = Array[{tag: String, magnitude: float}]; tag vocabulary owned by ZoneRules | ADR-0002 ✅ |
| TR-EC-010 | Catalog loaded once at startup via DI injection; no Autoload | ADR-0001 ✅ |

## Definition of Done

This epic is complete when:
- All stories are implemented, reviewed, and closed via `/story-done`
- All acceptance criteria from `design/gdd/equipment-catalog.md` are verified
- All Logic and Integration stories have passing test files in `tests/`
- Load-time validation tested in both `strict_mode=true` (abort) and `strict_mode=false` (skip+push_error) branches
- `footprint ∪ access` union bounding box ≤ 3×3 proven for every catalog entry (mathematical guarantee from footprint max 2×2 + access orthogonally adjacent)
- GridSystem OQ#13 cross-document contract verified: (a) footprint non-empty, (b) anchor normalized, (c) access∩footprint empty
- MemberSim OQ2 cross-document contract verified: all 4 use_duration fields within valid ranges
- All Visual/Feel and UI stories have evidence docs with sign-off in `production/qa/evidence/`

## Next Step

Run `/create-stories equipment-catalog` to break this epic into implementable stories.
