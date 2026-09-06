# GA-001 — Reliable equipment identity and save restoration

Status: In Progress
Last Updated: 2026-09-06
Layer: Foundation
Type: Integration
TR-ID: TR-SL-003, TR-SL-004, TR-SL-005, TR-SEL-005
ADR Governing Implementation: docs/architecture/adr-0002-storage-format.md
Related ADR: docs/architecture/adr-0003-grid-state-reader.md, docs/architecture/adr-0009-equipment-upgrade-instance-state.md
Manifest Version: 2026-07-23
Dependencies: Existing implemented sandbox systems; current runtime correctness repair.

## Scope

Persist equipment identity in the GridSystem placement record, restore derived placement and selection mappings in a fresh session, and preserve Satisfaction use-start snapshots. User authorized this prerequisite before first-day gameplay.

## Acceptance Criteria

- [ ] A yoga mat and bike with identical geometry retain their exact catalog IDs through a cold save/load; level, anchor and orientation survive.
- [ ] A restored item can be selected, moved, canceled and sold using its own definition and price; no footprint-only guessing for new saves.
- [ ] Unknown or inconsistent stored identity is rejected before any coordinated state mutates; legacy identity-free records only use a documented unambiguous recovery policy.
- [ ] An active exercise saved with one congestion snapshot finishes identically after load even if current congestion differs.
- [ ] Existing tests pass; add an integration regression at tests/integration/save_load/foundation_restore_test.gd and register it.

## Implementation Notes

Grid records own persistent instance state; Placement and Selection remain derived. Preserve existing public call signatures with optional appended identity arguments where practical. SaveLoad performs catalog-aware preflight before commit; do not mutate the catalog. Use-start congestion is historical input and belongs in Satisfaction serialization. Reject ambiguous legacy identity rather than silently choose the first catalog item. See the 2026-09-06 storage ADR addendum.

## Out of Scope

main.gd, presentation, new story gameplay, new art, unrelated untracked evidence. No commits.

## Test Evidence

tests/integration/save_load/foundation_restore_test.gd; relevant existing system suites and final full runner.
