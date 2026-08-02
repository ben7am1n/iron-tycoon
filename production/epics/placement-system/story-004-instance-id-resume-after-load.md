# Story 004: instance_id Resume After Load

> **Epic**: placement-system
> **Status**: Ready
> **Layer**: Core
> **Type**: Logic
> **Estimate**: S — 1 session (≤2h)
> **Manifest Version**: 2026-07-23
> **Last Updated**: 2026-08-02

## Context

**GDD**: `design/gdd/placement-system.md`
**Requirements**: `TR-PS-006`, `TR-PS-007`
*(Requirement text lives in `docs/architecture/tr-registry.yaml` — read fresh at review time)*

**ADR Governing Implementation**: ADR-0001: DI Container & Scene Bootstrap; ADR-0002: Storage Format
**ADR Decision Summary**: PlacementSystem stores NO data of its own in the save file. On every `deserialize()` — not just boot — it recomputes `next_instance_id = max(all occupant_ids currently on the grid) + 1` (0 if empty) by scanning `GridSystem.get_occupant_id(cell)` across `get_dimensions()`. The resume runs **after** GridSystem's own `deserialize()` completes; ordering is enforced by the composition root (`SimulationOrchestrator`). The counter is self-healing — it never trusts a separately-stored counter value.

**Engine**: Godot 4.7.1 | **Risk**: LOW
**Engine Notes**: `0` is a fully legal `instance_id` (the first-ever placed item). Comparing `occupant_id(c) != -1` is correct, but an implementation must never slip into GDScript's truthy-check idiom (`if occupant_id:`) — that treats a legitimate `0` as empty. Full grid scan (trivial at 130 cells) is the only contract-compliant way to compute S — `GridStateReader` exposes no "list all ids" method.

**Control Manifest Rules (Core layer)**:
- Required: `instance_id` allocated by PlacementSystem via a monotonic counter; no system may reuse a decommissioned id within a session
- Required: Systems that don't hold serializable state omit `serialize()`/`deserialize()` — PlacementSystem contributes nothing to the save file
- Forbidden: Never call `init()` twice on the same system; the resume ordering is enforced by the composition root, not by convention

---

## Acceptance Criteria

*From GDD `design/gdd/placement-system.md`, scoped to this story:*

- [ ] AC11 GIVEN a loaded snapshot with zero occupants, WHEN `deserialize()` completes, THEN `next_instance_id = 0`
- [ ] AC12 GIVEN loaded occupant_ids = {0, 2, 5} (no `-1` sentinels among them), WHEN `deserialize()` completes, THEN `next_instance_id = 6` — specifically confirming id `0` is counted as present, not treated as empty
- [ ] AC13 GIVEN a save that (via corruption or a legacy/hand-edited field) carries a stray stored counter value of 999, while the grid's actual max occupant id is 3, WHEN `deserialize()` completes, THEN `next_instance_id = 4` — re-derived from grid occupancy, ignoring the stray 999 entirely (defense-in-depth: the resume trusts grid state, never a stored counter)

---

## Implementation Notes

*Derived from ADR-0001 + ADR-0002 Implementation Guidelines:*

**Resume formula (Core Rule 8 + Formula):**
- `next_instance_id = 0` if `S = ∅`; else `max(S) + 1`, where `S = {occupant_id(c) : c ∈ cells, occupant_id(c) ≠ -1}`
- The empty-set case must be an explicit branch — `max()` over an empty set is undefined, not a fallthrough
- Scan via `GridStateReader.get_occupant_id(cell)` for every cell in `get_dimensions()` — the only contract-compliant way to compute S

**Ordering contract:**
- Resume runs after GridSystem's `deserialize()` completes — enforced by `SimulationOrchestrator` (composition root), documented here, never assumed
- Runs on **every** load, not just at boot

**Truth source:**
- Trust grid occupancy, never a stored counter value — a bad save edit cannot desync the counter
- `occupant_id = 0` is legal and must be counted as present — use `!= -1`, never truthiness

**Forbidden:**
- Never store the counter in the save blob
- Never re-derive from a separately-serialized "next id" value

---

## Out of Scope

*Handled by neighbouring stories — do not implement here:*

- [Story 002]: counter increments on successful new-placement commit
- [Story 005]: relocate re-commit reuses an existing id without touching the counter
- [grid-system story-007]: GridSystem's own serialize/deserialize (the state this story reads)
- [save-load epic]: the load orchestration sequence that guarantees ordering

---

## QA Test Cases

*Written by qa-lead at story creation. The developer implements against these — do not invent new test cases during implementation.*

- **AC11**: 空网格恢复
  - Given: loaded grid with zero occupants (all -1)
  - When: PlacementSystem resume runs after GridSystem deserialize
  - Then: next_instance_id == 0
  - Edge cases: brand-new game boot vs loaded empty-grid save both yield 0

- **AC12**: id 0 被正确计数
  - Given: loaded occupant_ids = {0, 2, 5}
  - When: resume runs
  - Then: next_instance_id == 6 (id 0 counted as present)
  - Edge cases: occupant_ids = {0} alone → next = 1 (not 0); ids {1, 2} with no 0 → next = 3

- **AC13**: 忽略残留计数器值
  - Given: stray stored counter 999 (corruption/legacy), grid max occupant id 3
  - When: resume runs
  - Then: next_instance_id == 4, stray 999 ignored
  - Edge cases: stray value smaller than reality (stray 1, actual max 5 → next 6) — always trusts grid

---

## Test Evidence

**Story Type**: Logic
**Required evidence**:
- `tests/unit/placement_system/instance_id_resume_test.gd` — must exist and pass

**Status**: [ ] Not yet created

---

## Dependencies

- Depends on: grid-system story-007 (GridSystem serialize/deserialize — the read surface this story scans)
- Unlocks: Story 005 (relocate re-commit relies on correct counter state), save-load integration (load ordering test)
