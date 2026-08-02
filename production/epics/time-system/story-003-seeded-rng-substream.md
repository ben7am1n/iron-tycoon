# Story 003: SeededRNG and Sub-Stream Derivation

> **Epic**: time-system
> **Status**: Ready
> **Layer**: Foundation
> **Type**: Logic
> **Estimate**: [hours or t-shirt size — fill before sprint planning]
> **Manifest Version**: 2026-07-23
> **Last Updated**: [set by /dev-story when implementation begins]

## Context

**GDD**: `design/gdd/time-system.md`
**Requirements**: `TR-TS-005`, `TR-TS-006`, `TR-TS-007`, `TR-TS-011`
*(Requirement text lives in `docs/architecture/tr-registry.yaml` — read fresh at review time)*

**ADR Governing Implementation**: ADR-0004: SeededRNG Architecture
**ADR Decision Summary**: Per-system RNG sub-streams derived via FNV-1a64 → XOR with master_seed → SplitMix64 finaliser. register_system(name) called once per system (duplicate = hard error). get_rng(name) is idempotent (returns existing, never creates). lsr() helper mandatory because GDScript's >> is arithmetic (sign-extending), which would corrupt SplitMix64 avalanche for high-bit-set values. RNG state restored directly on load (draw-count-agnostic). Determinism contract: same master_seed + same tick sequence = bit-identical replay.

**Engine**: Godot 4.7.1 | **Risk**: HIGH
**Engine Notes**: GDScript int is 64-bit two's-complement — wraparound on multiply is guaranteed. GDScript >> is ARITHMETIC (sign-extending) — must implement lsr(z, k) = (z >> k) & ((1 << (64 - k)) - 1). Godot's built-in hash() is NOT contractually stable across engine versions — must NOT be used. RandomNumberGenerator.seed accepts full int64 range (including negative). OQ4: the AC13 golden-vector test must verify actual 4.7.1 behavior before merge.

**Control Manifest Rules (Foundation layer)**:
- Required: lsr() helper must exist and all SplitMix64 right-shifts must use it; register_system() once per system, double = assert; get_rng() never creates
- Forbidden: Never use Godot's hash() for seed derivation (not stable across engine versions); never use arithmetic >> for SplitMix64
- Guardrail: Golden-vector test (AC13) must pass before merge — verifies the entire derivation pipeline against known output

---

## Acceptance Criteria

*From GDD `design/gdd/time-system.md`, scoped to this story:*

- [ ] AC6 [BLOCKING][Logic] GIVEN register_system("MemberSim") called once, WHEN get_rng("MemberSim") called twice with no draws between, THEN both calls return the same already-registered generator (same instance and same state), no re-seeding or re-registration
- [ ] AC7 [BLOCKING][Logic] GIVEN master_seed=X, WHEN 1000 values drawn from "MemberSim" and "Congestion" sub-streams, THEN the two sequences are neither identical nor a fixed offset of each other
- [ ] AC13 [BLOCKING][Logic] GIVEN master_seed=12345, system_name="Economy", WHEN sub_seed computed via rng_subseed_derivation_formula, THEN it matches a hardcoded golden-vector constant every run
- [ ] AC15 [BLOCKING][Logic] GIVEN register_system("Economy") already called once, WHEN register_system("Economy") called a second time, THEN assert() fails — duplicate registration is a hard error (get_rng("Economy") repeated does NOT fail)
- [ ] AC-LSR-1 [BLOCKING][Logic] GIVEN an int64 with high bit set (e.g. 0x8000000000000000), WHEN lsr(0x8000000000000000, 30), THEN result is 0x0000000200000000 (logical shift, zero-filled) — NOT sign-extended

---

## Implementation Notes

*Derived from ADR-0004 + GDD Core Rule 6 + rng_subseed_derivation_formula:*

**lsr() helper:**
```gdscript
# Logical (zero-filling) right shift — mandatory because GDScript's native >>
# is arithmetic (sign-extending), which would corrupt SplitMix64 for ~50% of values.
static func lsr(value: int, shift: int) -> int:
    assert(shift > 0 and shift < 64, "lsr: shift %d out of range (1-63)" % shift)
    return (value >> shift) & ((1 << (64 - shift)) - 1)
```

**FNV-1a64 implementation:**
```gdscript
const FNV_OFFSET_BASIS := 0xCBF29CE484222325
const FNV_PRIME := 0x100000001B3

static func fnv1a64(data: String) -> int:
    var hash := FNV_OFFSET_BASIS
    for byte in data.to_utf8_buffer():
        hash = hash ^ byte
        hash = (hash * FNV_PRIME) & 0xFFFFFFFFFFFFFFFF  # 64-bit wrap
    return hash
```

**Sub-stream derivation:**
```gdscript
static func derive_sub_seed(master_seed: int, system_name: String) -> int:
    var name_hash := fnv1a64(system_name)
    var combined := master_seed ^ name_hash
    var z := combined
    z = (z ^ lsr(z, 30)) * 0xBF58476D1CE4E5B9
    z = (z ^ lsr(z, 27)) * 0x94D049BB133111EB
    return z ^ lsr(z, 31)
```

**SeededRNG class:**
```gdscript
class_name SeededRNG extends RefCounted

var master_seed: int
var _streams: Dictionary = {}  # String -> RandomNumberGenerator

func init(p_master_seed: int) -> void:
    master_seed = p_master_seed

func register_system(system_name: String) -> void:
    if _streams.has(system_name):
        assert(false, "SeededRNG: system '%s' already registered" % system_name)
        return
    
    var sub_seed := derive_sub_seed(master_seed, system_name)
    var rng := RandomNumberGenerator.new()
    rng.seed = sub_seed
    _streams[system_name] = rng

func get_rng(system_name: String) -> RandomNumberGenerator:
    if not _streams.has(system_name):
        push_error("SeededRNG: system '%s' not registered — call register_system() first" % system_name)
        return null
    return _streams[system_name]
```

**Golden-vector test (AC13):**
```gdscript
# This MUST be the first test written for this story — before any other test passes.
# If this golden value fails on 4.7.1, the entire derivation formula needs re-evaluation.
func test_golden_vector() -> void:
    var result := SeededRNG.derive_sub_seed(12345, "Economy")
    # Expected value to be filled in by the first implementer running on 4.7.1:
    # 1. Implement derive_sub_seed + lsr + fnv1a64
    # 2. Run once with master_seed=12345, system_name="Economy"
    # 3. Record the output as GOLDEN_ECONOMY_SUBSEED constant
    # 4. Write the assertion: assert(result == GOLDEN_ECONOMY_SUBSEED)
    assert(result == GOLDEN_ECONOMY_SUBSEED, 
        "Golden vector mismatch: got %d, expected %d" % [result, GOLDEN_ECONOMY_SUBSEED])
```

**Key design decisions:**
- FNV-1a64 uses published constants — no magic, no RNG in derivation
- lsr() uses bitmask `(1 << (64 - k)) - 1` rather than unsigned casting — portable across GDScript versions
- register_system() vs get_rng() split: the two-method split exists because a single name-keyed accessor cannot both be safe to call repeatedly by the legitimate owner AND fail on a colliding second registrant
- Golden-vector test is the FIRST test — if it fails on 4.7.1, the formula must be adjusted before any other RNG test can be meaningful

---

## Out of Scope

*Handled by neighbouring stories — do not implement here:*

- [Story 001]: register_system() calls happen in _post_init() — Orchestrator wires them
- [Story 002]: Tick loop — RNG calls happen inside on_tick() of individual systems
- [Story 004]: RNG state serialization — this story handles derivation; serialization stores the advanced state
- [Individual systems]: Actual on_tick() logic that consumes rng.randf() / rng.randi() — this story only provides the RNG

---

## QA Test Cases

*Sourced from `production/qa/qa-plan-sprint-2-2026-08-02.md` — Automated Tests Required (TS-003). Authoritative test files: `tests/unit/time_system/seeded_rng_substream_test.gd` + `tests/unit/time_system/lsr_helper_test.gd` (~40 assertions + 子进程 probe).*

**What to test**:
- AC-LSR-1: lsr(0x8000000000000000, 30) == 0x0000000200000000（逻辑右移，非符号扩展）
- FNV-1a64 → XOR → SplitMix64 子流派生公式（钉死常量）
- register_system(name) 恰一次；重复注册 = 硬错误
- get_rng(name) 幂等：返回同一实例（携带已推进状态），绝不创建/重播种
- 不同 system 子流独立（不因调用顺序互相影响）

**Edge cases**: 高位 set 的种子值、空名注册、子流种子碰撞验证

**Estimated assertions**: ~40 + 子进程 probe

- **AC6**: get_rng 等幂
  - Given: register_system("MemberSim"), no draws
  - When: get_rng("MemberSim") called twice
  - Then: both returns same instance; state identical (seed value checked); no re-registration
  - Edge cases: call get_rng before register_system → push_error + null

- **AC7**: 子流独立
  - Given: same master_seed
  - When: draw 1000 values from "MemberSim" and "Congestion" streams
  - Then: sequences are different (not identical, not offset by fixed amount)
  - Edge cases: verify with multiple system names; verify with different master_seed produces different sequences

- **AC13**: 金向量测试
  - Given: master_seed=12345, system_name="Economy"
  - When: derive_sub_seed() called
  - Then: result == GOLDEN_ECONOMY_SUBSEED (hardcoded after first 4.7.1 run)
  - Edge cases: this is a CANARY test — if values change across engine versions, this catches it

- **AC15**: 重复注册断言
  - Given: register_system("Economy") already called
  - When: register_system("Economy") called again
  - Then: assert() fires
  - Edge cases: verify get_rng("Economy") repeated does NOT fail — only register_system checks for duplicates

- **AC-LSR-1**: lsr 逻辑右移
  - Given: 0x8000000000000000 (high bit set)
  - When: lsr(value, 30)
  - Then: 0x0000000200000000 (NOT sign-extended to 0xFFFFFFFFE0000000)
  - Edge cases: test lsr with shift=1 (high bit); test lsr with shift=63; test lsr with all-zeros input

---

## Test Evidence

**Story Type**: Logic
**Required evidence**:
- `tests/unit/time_system/seeded_rng_substream_test.gd` — must exist and pass (AC6, AC7, AC13, AC15)
- `tests/unit/time_system/lsr_helper_test.gd` — must exist and pass (AC-LSR-1)

**Status**: [ ] Not yet created

---

## Dependencies

- Depends on: Story 001 (Orchestrator _post_init() for registration timing)
- Unlocks: Story 004 (serialization needs RNG state to serialize/restore), all downstream system on_tick() implementations (they consume get_rng())
