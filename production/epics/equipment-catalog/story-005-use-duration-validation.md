# Story 005: Use-Duration Field Validation

> **Epic**: equipment-catalog
> **Status**: Ready
> **Layer**: Foundation
> **Type**: Logic
> **Estimate**: [hours or t-shirt size — fill before sprint planning]
> **Manifest Version**: 2026-07-23
> **Last Updated**: 2026-08-02 (implementation by EC-005)

## Context

**GDD**: `design/gdd/equipment-catalog.md`
**Requirements**: `TR-EC-001`, `TR-EC-004`
*(Requirement text lives in `docs/architecture/tr-registry.yaml` — read fresh at review time)*

**ADR Governing Implementation**: ADR-0002: Storage Format
**ADR Decision Summary**: Load-time validation of use_duration_mean_ticks, use_duration_stddev_ticks, use_duration_min_ticks, use_duration_max_ticks fields. This is the cross-document contract with MemberSim (#6) OQ2: MemberSim's USING state timer depends on these 4 fields being within valid ranges. Validating here (single authority) rather than defensively in MemberSim prevents silent stuck-member bugs. strict_mode branching applies (same as footprint/access validation).

**Engine**: Godot 4.7.1 | **Risk**: LOW
**Engine Notes**: Pure integer range checks — no engine API risks. The 4 fields are consumed by MemberSim's SeededRNG sub-stream for use_duration Gaussian generation.

**Control Manifest Rules (Foundation layer)**:
- Required: All LoadError objects must reference the specific rule that failed ((e) through (h) from GDD Core Rule 7)
- Forbidden: Never assume defaults for missing use_duration fields — missing = validation failure
- Guardrail: use_duration_mean_ticks must be > 0 (0 or negative = infinite wait → member stuck)

---

## Acceptance Criteria

*From GDD `design/gdd/equipment-catalog.md` §use-duration + AC-U.1–U.4:*

- [x] AC-U.1 [BLOCKING][Logic] GIVEN a definition with use_duration_mean_ticks <= 0, WHEN Catalog loads with strict_mode=true, THEN assert() aborts with entry id in message (Core Rule 7 (e))
- [x] AC-U.2 [BLOCKING][Logic] GIVEN a definition with use_duration_stddev_ticks < 0, WHEN loaded, THEN validation fails (Core Rule 7 (f))
- [x] AC-U.3 [BLOCKING][Logic] GIVEN a definition with use_duration_min_ticks < 1 OR min > mean OR max < mean OR min > max, WHEN loaded, THEN validation fails (Core Rule 7 (g)/(h))
- [x] AC-U.4 [BLOCKING][Logic] GIVEN a valid definition (mean=200, stddev=35, min=100, max=300), WHEN load succeeds and get_definition(id) called, THEN returned EquipmentDef contains all 4 fields with exact values — proves fields landed and are consumable by MemberSim
- [x] AC-U.5 [BLOCKING][Logic] GIVEN a definition with use_duration_stddev_ticks = 0, WHEN loaded, THEN validation passes (deterministic duration is allowed)

---

## Implementation Notes

*Derived from ADR-0002 + GDD Core Rule 7:*

**use-duration validation:**
```gdscript
static func validate_use_duration(entry: Dictionary) -> ValidationResult:
    var mean: int = entry.get("use_duration_mean_ticks", 0)
    var stddev: int = entry.get("use_duration_stddev_ticks", 0)
    var min_val: int = entry.get("use_duration_min_ticks", 0)
    var max_val: int = entry.get("use_duration_max_ticks", 0)
    
    # (e) mean > 0
    if mean <= 0:
        return ValidationResult.fail("USE_DURATION_MEAN_INVALID",
            "use_duration_mean_ticks must be > 0; got %d" % mean)
    
    # (f) stddev >= 0
    if stddev < 0:
        return ValidationResult.fail("USE_DURATION_STDDEV_NEGATIVE",
            "use_duration_stddev_ticks must be >= 0; got %d" % stddev)
    
    # (g) min >= 1 AND min <= mean
    if min_val < 1:
        return ValidationResult.fail("USE_DURATION_MIN_TOO_LOW",
            "use_duration_min_ticks must be >= 1; got %d" % min_val)
    if min_val > mean:
        return ValidationResult.fail("USE_DURATION_MIN_EXCEEDS_MEAN",
            "use_duration_min_ticks (%d) must be <= mean (%d)" % [min_val, mean])
    
    # (h) max >= mean AND min <= max
    if max_val < mean:
        return ValidationResult.fail("USE_DURATION_MAX_BELOW_MEAN",
            "use_duration_max_ticks (%d) must be >= mean (%d)" % [max_val, mean])
    if min_val > max_val:
        return ValidationResult.fail("USE_DURATION_RANGE_INVALID",
            "use_duration_min (%d) must be <= max (%d)" % [min_val, max_val])
    
    return ValidationResult.ok()
```

**The formula these fields feed (in MemberSim, not implemented here):**
```
use_duration = clamp(gaussian_rng(mean, stddev), min, max)
```
If mean ≤ 0 → gaussian_rng center is 0 or negative → no positive duration possible.
If min < 1 → clamp allows 0 ticks → USING→SELECTING_TARGET fires without any time passing.
If min > max → clamp is nonsensical — MemberSim's guarantee of bounded duration breaks.

**MVP anchor values (from GDD):**
| Field | Typical Value | Range |
|-------|---------------|-------|
| mean | 200 ticks (20s) | 150–250 |
| stddev | 35 ticks (3.5s) | ~15–20% of mean |
| min | 100 ticks (10s) | ~0.5× mean |
| max | 300 ticks (30s) | ~1.5× mean |

**Key design decisions:**
- Validation accepts stddev=0 (deterministic duration) — some equipment may have fixed use time
- min=1 is the absolute lower bound (not 0) — a member must spend at least 1 tick using equipment
- These fields are validated here (Catalog load-time) and nowhere else — MemberSim trusts the Catalog output
- This is the cross-document contract with MemberSim #6 OQ2 — member of the GDD's "hard gate" list

---

## Out of Scope

*Handled by neighbouring stories — do not implement here:*

- [Story 001]: EquipmentDef stores these fields — this story validates them before storage
- [Story 004]: strict_mode pipeline integration — this validator is called from _validate_all()
- [MemberSim #6]: use_duration formula and Gaussian RNG — Catalog only provides the parameters; MemberSim computes

---

## QA Test Cases

- **AC-U.1**: mean ≤ 0 → abort (strict_mode)
  - Given: entry with use_duration_mean_ticks = 0
  - When: load with strict_mode=true
  - Then: assert() aborts with entry id
  - Edge cases: test mean = -1, mean = -100

- **AC-U.2**: stddev < 0 → fail
  - Given: entry with use_duration_stddev_ticks = -1
  - When: load with strict_mode=false
  - Then: entry excluded, USE_DURATION_STDDEV_NEGATIVE error
  - Edge cases: stddev = 0 passes (tested in AC-U.5)

- **AC-U.3**: 区间约束违反
  - Given: 4 sub-cases: (a) min=0, (b) min=250 > mean=200, (c) max=150 < mean=200, (d) min=300 > max=200
  - When: each sub-case loaded
  - Then: each fails with the specific error category matching the violated rule
  - Edge cases: test max == mean (should pass — "no variation allowed above mean"); test min == mean (should pass — "no variation allowed below mean")

- **AC-U.4**: 合法字段完整保留
  - Given: entry with mean=200, stddev=35, min=100, max=300
  - When: load succeeds
  - Then: get_definition(id) returns EquipmentDef with all 4 fields exactly matching input
  - Edge cases: verify no field was type-converted (int → float) during JSON parsing

- **AC-U.5**: stddev=0 合法
  - Given: entry with stddev=0
  - When: load
  - Then: validation passes — deterministic duration equipment is allowed
  - Edge cases: test with all fields at boundary values: mean=1, stddev=0, min=1, max=1

---

## Test Evidence

**Story Type**: Logic
**Required evidence**:
- `tests/unit/equipment_catalog/catalog_use_duration_validation_test.gd` — must exist and pass

**Status**: [x] Created and passing (2026-08-02)

**Test Evidence**: Full suite 951/951 (was 878). New files:
- `tests/unit/equipment_catalog/catalog_use_duration_validation_test.gd` — 73 assertions, 0 failures. AC-U.1 (mean=0 strict probe: assert fires, message names `mean_zero_rack` + USE_DURATION_MEAN_INVALID; mean=-1/-100 validator edges; non-strict: entry excluded, valid control loads, push_error probe confirms), AC-U.2 (stddev=-1: validator code USE_DURATION_STDDEV_NEGATIVE + loader path excludes `stddev_negative_bench`), AC-U.3 (4 sub-cases a-d through the range_invalid fixture: min=0 → MIN_TOO_LOW, min=250>mean → MIN_EXCEEDS_MEAN, max=150<mean → MAX_BELOW_MEAN, min=300>max=200 → fails via MIN_EXCEEDS_MEAN per ordered checks; boundary equalities max==mean / min==mean / min==max==mean all pass), AC-U.4 (valid def lands with EXACT values through load + get_definition; typeof == TYPE_INT for all 4 fields — no int→float conversion; boundary def mean=1/stddev=0/min=1/max=1 also lands), AC-U.5 (stddev=0 accepted at validator + loader level; boundary all-ones accepted), Control Manifest forbidden rule (missing use_duration_mean_ticks → structural INVALID_ENTRY, never a default).
- `tests/unit/equipment_catalog/catalog_use_duration_strict_probe.gd` — subprocess probe (not a _test.gd): `strict_mean_zero` + `nons_mean_zero_excludes` modes, same isolation pattern as Story 004's probe (10th use of the subprocess-isolation pattern).
- `tests/unit/equipment_catalog/fixtures/*.catalog.json` — 4 new committed fixtures (use_duration_mean_zero, use_duration_stddev_negative, use_duration_range_invalid, use_duration_stddev_zero), each with a `valid_control` entry to prove partial-load isolation.

**Decisions recorded at close**:
1. **Validator signature deviation — typed ints, not the sketch's `entry: Dictionary`.** The story sketch shows `validate_use_duration(entry: Dictionary) -> ValidationResult` reading `entry.get(...)`. The loader already parses the 4 fields into typed ints via `_field_int` (which fails structurally on missing/non-integer values — the Control Manifest "never assume defaults for missing use_duration fields" is enforced UPSTREAM at the structural layer, verified by the forbidden-rule test), so the validator takes `(mean, stddev, min_val, max_val)` like the Story 003 typed validators. `_validate_all` signature extended to pass them through in fixed order.
2. **AC-U.3 QA sub-case (d) `min=300 > max=200` reports MIN_EXCEEDS_MEAN, not RANGE_INVALID.** The ordered checks test `min > mean` (rule g) before `min > max` (rule h); with mean=200 the (g) violation fires first. RANGE_INVALID is documented as defensive dead code — it is mathematically unreachable because `min <= mean` (g) and `max >= mean` (h 1st clause) together imply `min <= max`. The AC only requires the entry to FAIL for `min > max`, which it does deterministically.
3. **`_validate_all` signature change rippled to the EC-004 test** — the pipeline test's two direct `_validate_all(empty_footprint, two_access)` calls now pass valid use-duration values (200/35/100/300) so the test still isolates footprint/access ordering (2 failures, unchanged assertions).
4. **stddev=0 and min==max==mean are valid** — AC-U.5 + boundary equality tests lock in the deterministic-duration contract (a member may spend exactly 1 tick, mean=1/stddev=0/min=1/max=1 loads).

---

## Dependencies

- Depends on: Story 001 (EquipmentDef stores these fields), Story 004 (validation pipeline consumes this validator)
- Unlocks: Story 007 (full edge case coverage), MemberSim #6 implementation
