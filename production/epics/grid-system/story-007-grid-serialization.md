# Story 007: Serialization and Deserialization

> **Epic**: grid-system
> **Status**: Complete
> **Layer**: Foundation
> **Type**: Integration
> **Estimate**: M — 1 day (Sprint 1)
> **Manifest Version**: 2026-07-23
> **Last Updated**: 2026-08-02

## Context

**GDD**: `design/gdd/grid-system.md`
**Requirements**: `TR-GS-019`, `TR-GS-020`
*(Requirement text lives in `docs/architecture/tr-registry.yaml` — read fresh at review time)*

**ADR Governing Implementation**: ADR-0002: Storage Format
**ADR Decision Summary**: serialize() stores the reverse index (not the raw arrays), sorted by instance_id ascending for deterministic output. deserialize() is two-stage: Phase A validates all records against buildable_snapshot (zero mutation), Phase B commits only if all pass. buildable is NOT in the save file — injected separately by the level loader before deserialize. All-or-nothing: any record-level failure aborts the entire load. Schema versioning via "schema_version": 1 field (MVP exact-match only).

**Engine**: Godot 4.7.1 | **Risk**: MEDIUM
**Engine Notes**: JSON.stringify() with full_precision=true and sort_keys=true for deterministic output. PackedArray out-of-bounds writes must be prevented in validation phase (CORRUPTED_SAVE_OUT_OF_BOUNDS). Godot 4.7.1 PackedInt32Array is stable and performant. AStarGrid2D determinism gate PASSED (ADR-0007, 10/10 processes bit-identical) — Navigation rebuilds from occupancy on load, no serialization needed.

**Control Manifest Rules (Foundation layer)**:
- Required: Save blob format JSON with format_version envelope; all 64-bit integers as hex strings; deserialize(data, mode) where mode is "validate" (Phase A) or "commit" (Phase B); JSON.stringify() with full_precision=true and sort_keys=true
- Forbidden: Never use Godot Resources (.tres/.res) for runtime save data; never serialize AStarGrid2D internal state
- Guardrail: Save blob JSON parse < 1ms for ~50 KB; total load time < 5ms

---

## Acceptance Criteria

*From GDD `design/gdd/grid-system.md`, scoped to this story:*

- [x] AC-C8.1 [BLOCKING][Integration] (round-trip consistency) GIVEN an operation sequence (multiple commit/clear, including at least one rotation ≠ 0°) applied to grid A then serialized, WHEN using the returned Dictionary + same buildable_snapshot to deserialize into fresh instance B, THEN (a) per-cell occupant_id + access_ids equal for EVERY cell, AND (b) per-instance_id get_access_cells equal for every committed id, AND DeserializeResult.success == true
- [x] AC-C8.2 [BLOCKING][Logic] (rotation preserved) GIVEN an equipment committed with rotation=90°, WHEN serialize() then deserialize(), THEN reverse index PlacementRecord.rotation == 90
- [x] AC-C8.3 [BLOCKING][Logic] (deterministic output — full deep equality) GIVEN out-of-order instance_id insertions (e.g. commit 5 then commit 2), WHEN two independently constructed but identically-sequenced instances A/B each call serialize(), THEN A.serialize() == B.serialize() (full deep Dictionary equality), AND records sorted by instance_id ascending
- [x] AC-C8.3b [BLOCKING][Integration] (serialize output stable across round-trip) GIVEN grid A's serialize() output S_A, WHEN deserializing S_A into fresh B then B.serialize() to get S_B, THEN S_A == S_B (full deep equality)
- [x] AC-C8.4 [BLOCKING][Logic] (LEVEL_GEOMETRY_MISMATCH — footprint on wall) GIVEN a record whose footprint cell is buildable=false in the snapshot, WHEN deserialize(), THEN returns {success:false, errors:[...LEVEL_GEOMETRY_MISMATCH...]}, AND grid has no writes
- [x] AC-C8.5 [BLOCKING][Logic] (LEVEL_GEOMETRY_MISMATCH — access on wall) GIVEN a record whose access cell is buildable=false, WHEN deserialize(), THEN returns FAIL: LEVEL_GEOMETRY_MISMATCH, no writes
- [x] AC-C8.6 [BLOCKING][Logic] (LEVEL_GEOMETRY_MISMATCH — dimension mismatch) GIVEN data.width/height differs from current grid, WHEN deserialize(), THEN immediately returns FAIL: LEVEL_GEOMETRY_MISMATCH, no records processed
- [x] AC-C8.7 [BLOCKING][Logic] (CORRUPTED_SAVE_OUT_OF_BOUNDS) GIVEN a record with footprint or access coordinates outside [0,width)×[0,height), WHEN deserialize(), THEN returns FAIL: CORRUPTED_SAVE_OUT_OF_BOUNDS, intercepted BEFORE write phase — no PackedArray OOB writes
- [x] AC-C8.8 [BLOCKING][Logic] (CORRUPTED_SAVE_OVERLAP) GIVEN two records with overlapping footprint cells, WHEN deserialize(), THEN returns FAIL: CORRUPTED_SAVE_OVERLAP — access cell overlap does NOT error (allowed by design)
- [x] AC-C8.9 [BLOCKING][Logic] (no partial recovery) GIVEN 5 valid records + 1 triggering CORRUPTED_SAVE_OVERLAP, WHEN deserialize(), THEN first 5 do NOT take effect either — get_snapshot() shows initial empty state, not "5 committed, 6th failed"
- [x] AC-C8.10 [BLOCKING][Logic] (single signal emission) GIVEN save data with 3 valid records, WHEN deserialize() succeeds, THEN grid_changed fires exactly 1 time (not 3), payload covers union of all 3 records' cell sets

---

## Implementation Notes

*Derived from ADR-0002 + GDD §C.8:*

**serialize():**
```gdscript
func serialize() -> Dictionary:
    var records := []
    for instance_id in _reverse_index:
        var rec := _reverse_index[instance_id]
        records.append({
            "instance_id": instance_id,
            "footprint_cells": rec.footprint_cells,
            "access_cells": rec.access_cells,
            "rotation": rec.rotation
        })
    # Deterministic sort: ascending by instance_id
    records.sort_custom(func(a, b): return a["instance_id"] < b["instance_id"])
    
    # Deterministic cell ordering within each record: sort by (y, x) lexicographic
    for r in records:
        r["footprint_cells"].sort_custom(func(a, b): return a.y < b.y or (a.y == b.y and a.x < b.x))
        r["access_cells"].sort_custom(func(a, b): return a.y < b.y or (a.y == b.y and a.x < b.x))
    
    return {
        "schema_version": 1,
        "width": width,
        "height": height,
        "records": records
    }
```

**deserialize(data, buildable_snapshot, mode):**
- mode parameter: "validate" (Phase A — zero mutation) or "commit" (Phase B — apply)
- buildable_snapshot: PackedByteArray provided by level loader (NOT part of save data)

```gdscript
func deserialize(data: Dictionary, buildable_snapshot: PackedByteArray, mode: String) -> DeserializeResult:
    # Phase A: validate everything, mutate nothing
    # 1. Dimension check
    if data.width != width or data.height != height:
        return DeserializeResult.fail("LEVEL_GEOMETRY_MISMATCH", "grid dimensions differ")
    
    # 2. Per-record validation
    for record in data.records:
        var instance_id: int = record.instance_id
        
        # 2a. Bounds check (BEFORE any write — prevents PackedArray OOB)
        for cell in record.footprint_cells + record.access_cells:
            if not _in_bounds(cell):
                return DeserializeResult.fail("CORRUPTED_SAVE_OUT_OF_BOUNDS",
                    "cell %s out of bounds" % cell)
        
        # 2b. Buildable check (footprint AND access — both must be buildable)
        for cell in record.footprint_cells:
            if not buildable_snapshot[_flat_index(cell)]:
                return DeserializeResult.fail("LEVEL_GEOMETRY_MISMATCH",
                    "footprint on non-buildable cell %s" % cell)
        for cell in record.access_cells:
            if not buildable_snapshot[_flat_index(cell)]:
                return DeserializeResult.fail("LEVEL_GEOMETRY_MISMATCH",
                    "access on non-buildable cell %s" % cell)
    
    # 2c. Overlap check (footprint only — access overlap is allowed)
    var all_fp_cells := {}
    for record in data.records:
        for cell in record.footprint_cells:
            var key := "%d,%d" % [cell.x, cell.y]
            if all_fp_cells.has(key):
                return DeserializeResult.fail("CORRUPTED_SAVE_OVERLAP",
                    "footprint overlap at %s between ids %d and %d" % [cell, all_fp_cells[key], record.instance_id])
            all_fp_cells[key] = record.instance_id
    
    if mode == "validate":
        return DeserializeResult.ok()  # validated, no writes
    
    # Phase B: commit — all records validated, safe to write
    if mode == "commit":
        _clear_all()  # reset to empty
        var all_fp := []
        var all_ac := []
        for record in data.records:
            var fp := _cells_from_array(record.footprint_cells)
            var ac := _cells_from_array(record.access_cells)
            _write_record(record.instance_id, fp, ac, record.rotation)
            all_fp.append_array(fp)
            all_ac.append_array(ac)
        grid_changed.emit(all_fp, all_ac)  # single signal for entire load
        return DeserializeResult.ok()
    
    return DeserializeResult.fail("INTERNAL_ERROR", "unknown mode: %s" % mode)
```

**DeserializeResult:**
```gdscript
class DeserializeResult extends RefCounted:
    var success: bool
    var errors: Array[Dictionary]  # [{category, message, detail}]
    
    static func ok() -> DeserializeResult: ...
    static func fail(category: String, detail: String) -> DeserializeResult: ...
```

**Key design decisions:**
- buildable NOT in save file — level loader provides it separately (two independent data sources)
- serialize() dumps reverse index (not arrays) — rotation only lives in reverse index, guaranteed consistent
- Two-phase structure is structural: Phase A failure = nothing written = "no partial recovery" is guaranteed, not disciplined
- All-or-nothing: accepted risk (losing all 50 pieces if one record corrupts) — MVP scale makes this the right tradeoff (records ~5-6, not 500)
- Single grid_changed on deserialize — load consumers don't need per-record granularity

---

## Out of Scope

*Handled by neighbouring stories — do not implement here:*

- [Story 005]: commit/clear and reverse index — serialize reads the reverse index built here
- [Story 008]: grid_changed signal contract — the emit during deserialize follows the same contract
- [SaveLoad epic]: Cross-system load order, Phase A/B orchestration — GridSystem only implements its own serialize/deserialize; SaveLoad calls them in order

---

## QA Test Cases

- **AC-C8.1**: 往返一致性（逐格 + 按 id）
  - Given: operation sequence with multiple commit/clear + at least one rotation ≠ 0°
  - When: A.serialize() → deserialize into fresh B with same buildable_snapshot
  - Then: (a) per-cell occupant_id AND access_ids equal for every cell in [0,w)×[0,h); (b) per-instance_id get_access_cells equal for every committed id
  - Edge cases: include equipment with 0 access cells; include equipment rotated 90°/270°

- **AC-C8.2**: rotation 被保留
  - Given: equipment committed with rotation=90°
  - When: serialize → deserialize → check reverse index
  - Then: PlacementRecord.rotation == 90 (rotation only exists in reverse index — this proves it survived)
  - Edge cases: test all 4 rotation values; test round-trip when rotation was restored from a prior save

- **AC-C8.3**: 确定性写出（全量深相等）
  - Given: two identical-spec instances A and B, same sequence of commits (out of order: commit 5 then 2)
  - When: A.serialize() and B.serialize()
  - Then: entire Dictionary deep-equal; records sorted by instance_id ascending; within each record, footprint_cells/access_cells sorted by (y,x) lexicographic
  - Edge cases: identical grid built from two different commit sequences (e.g. A commits 1,2,3 vs B commits 3,1,2) — may NOT produce identical serialize because reverse index insertion order differs, but AC-C8.1(b) verifies state equality

- **AC-C8.3b**: 往返后逐字节相同
  - Given: A.serialize() → S_A
  - When: deserialize S_A into B → B.serialize() → S_B
  - Then: S_A == S_B full deep equality
  - Edge cases: this is the "save → load → save" test — ensures the serialized output is stable, not just the grid state

- **AC-C8.4**: footprint 落墙 → LEVEL_GEOMETRY_MISMATCH
  - Given: save with one record having footprint_ci=buildable=false
  - When: deserialize
  - Then: success=false, errors contain LEVEL_GEOMETRY_MISMATCH, grid unchanged
  - Edge cases: verify the rejection is per-cell buildable check, not per-record assumption

- **AC-C8.5**: access 落墙 → LEVEL_GEOMETRY_MISMATCH
  - Given: save with one record having access cell on buildable=false
  - When: deserialize
  - Then: FAIL: LEVEL_GEOMETRY_MISMATCH (SAME error as footprint — both are geometry mismatch)
  - Edge cases: verify this creates a state that normal can_place could never produce (access-blocked-by-wall)

- **AC-C8.6**: 尺寸不符
  - Given: data.width=10 but grid is 13×10
  - When: deserialize
  - Then: immediately LEVEL_GEOMETRY_MISMATCH, no records processed at all
  - Edge cases: test width match/height mismatch, height match/width mismatch, both mismatch

- **AC-C8.7**: 越界坐标 → CORRUPTED_SAVE_OUT_OF_BOUNDS
  - Given: save with record containing col=20 (beyond width=13)
  - When: deserialize
  - Then: FAIL before write phase begins — must verify NO PackedArray writes occurred
  - Edge cases: test negative coordinate, coordinate at exactly width (off-by-one)

- **AC-C8.8**: footprint 重叠 → CORRUPTED_SAVE_OVERLAP
  - Given: two records share a footprint cell
  - When: deserialize
  - Then: CORRUPTED_SAVE_OVERLAP
  - Edge cases: verify access cell overlap does NOT fail (two records sharing access cell is legal); verify partial overlap vs full overlap

- **AC-C8.9**: 不做部分恢复
  - Given: 5 valid records + 1 bad (overlap)
  - When: deserialize
  - Then: get_snapshot() shows empty grid (NOT 5 records committed)
  - Edge cases: this tests the structural two-phase guarantee — Phase A prevents Phase B entirely

- **AC-C8.10**: 单次信号发射
  - Given: save with 3 records
  - When: deserialize succeeds
  - Then: grid_changed emitted exactly 1 time, payload = union of all footprint/access cells
  - Edge cases: verify signal count with 1 record, 0 records (empty save — should it emit? no, no change)

---

## Test Evidence

**Story Type**: Integration
**Required evidence**:
- `tests/integration/grid_system/grid_serialization_test.gd` — must exist and pass

**Status**: [x] Created and passing — 82 assertions, 0 failures (2026-08-02)

**Test Evidence**: Integration — `tests/integration/grid_system/grid_serialization_test.gd` (82 assertions, 0 failures; full suite 480/480, up from 398; zero unexpected ERROR/SCRIPT ERROR lines from the new code path). Covers all 10 blocking ACs (AC-C8.1..C8.10), plus validate-mode zero-mutation contract, JSON blob round-trip through `JSON.stringify(_, "", true, true)` → `JSON.parse_string` (float coercion), unknown-mode INTERNAL_ERROR, schema_version exact-match, structural strengtheners (negative/duplicate ids, illegal rotation, empty footprint, malformed cells, short snapshot), and signal-quiet failure paths.

**Decisions recorded at close** (see docs/tech-debt-register.md for the full audit trail):
1. **serialize() emits cells as [x, y] int arrays, NOT raw Vector2i** — verified empirically in 4.7.1 that `JSON.stringify()` renders Vector2i as the string `"(1, 2)"` and `JSON.parse_string()` returns that string back, so raw Vector2i cannot survive a JSON round-trip. The Control Manifest requires the save blob to be JSON with `JSON.stringify(full_precision, sort_keys)` — cells as `[x, y]` arrays (matching ADR-0002's catalog format) are the only encoding that satisfies both the manifest and AC-C8.3/3b byte-determinism. deserialize() accepts BOTH encodings (Vector2i for in-memory round-trips, [x,y] arrays from JSON files).
2. **deserialize() signature is 3-arg: `deserialize(data, buildable_snapshot, mode)`** — the story sketch's form, reconciling ADR-0002's `(data, mode)` contract with GDD §C.8's `(data, buildable_snapshot)` form. buildable MUST be injected separately (TR-GS-020); mode is "validate" (Phase A only) or "commit" (Phase A + Phase B). Return type is DeserializeResult (a typed DTO, not ADR-0002's sketch `Dictionary`), consistent with the typed-DTO posture of PlacementCheckResult/PlacementRecord.
3. **Error taxonomy extends GDD's three categories with CORRUPTED_SAVE and INTERNAL_ERROR** — the GDD enumerates LEVEL_GEOMETRY_MISMATCH / CORRUPTED_SAVE_OUT_OF_BOUNDS / CORRUPTED_SAVE_OVERLAP for SaveLoad/UI display; structural corruption (schema_version mismatch, negative/duplicate ids, illegal rotation, empty footprint, malformed cells) and programming errors (unknown mode, short buildable_snapshot) need distinct categories so the UI never mis-labels a bad-schema save as a geometry problem.
4. **Strengthening validation beyond the sketch** — negative instance_id (collides with the -1 sentinel, same class as commit()'s AC-C7.7), duplicate instance_id (would orphan the first record's cells, same class as AC-C7.2), illegal rotation (would store a state normal can_place() can never produce), empty footprint (AC-D5.3), and malformed cells are all rejected as CORRUPTED_SAVE. This preserves the GDD's core rule: deserialize must never create states the normal placement flow could not produce.
5. **Signal emission on commit** — single grid_changed after the whole load (AC-C8.10), payload = union of all committed cells. Deviation from the sketch's unconditional emit: a completely empty load into an already-empty grid emits NOTHING (nothing changed — Story 007 QA edge case); emptying a populated grid DOES emit (the clear is a real change). Failed loads never emit.
6. **Cell-order determinism across round-trip** — serialize sorts cells (y,x) lexicographic per record; deserialize replays records in the save's ascending-instance_id order, so per-cell access_ids insertion order may differ from the original commit order (multi-value set semantics per GDD C.5). Tests compare access_ids and get_access_cells as sorted sets ("格归属" membership — GDD's own framing of AC-C8.1(b)).
7. **JSON.parse_string returns floats for all numbers** in 4.7.1 (probed) — deserialize coerces ids/rotations/cells through `int()` so a JSON-parsed blob (float ids, float coordinates) loads identically to an in-memory Dictionary round-trip. Verified by the JSON blob test.

---

## Dependencies

- Depends on: Story 005 (commit/clear builds reverse index — serialize reads it), Story 006 (GridStateReader — deserialize needs grid read surface for verification)
- Unlocks: SaveLoad epic (save-load coordinates GridSystem.serialize/deserialize in load order)
