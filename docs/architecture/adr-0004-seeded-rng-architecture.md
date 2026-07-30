# ADR-0004: Seeded RNG Architecture — Per-System Sub-Streams via FNV-1a64 + SplitMix64

## Status
Accepted

**Gate**: ADR-0001 Accepted, ADR-0002 Accepted (depends-on cleared) 2026-07-22. Pure GDScript integer arithmetic — no @abstract dependency.

## Date
2026-07-21

## Engine Compatibility

| Field | Value |
|-------|-------|
| **Engine** | Godot 4.7.1 |
| **Domain** | Core / Scripting (RNG, determinism) |
| **Knowledge Risk** | HIGH — version is 4 releases beyond LLM training cutoff |
| **References Consulted** | `docs/engine-reference/godot/VERSION.md`, `docs/engine-reference/godot/breaking-changes.md`, `docs/engine-reference/godot/current-best-practices.md` |
| **Post-Cutoff APIs Used** | `RandomNumberGenerator` (stable, no post-cutoff changes identified), GDScript `int` 64-bit two's-complement arithmetic (stable), `int >>` arithmetic shift (GDScript language spec, unchanged) |
| **Verification Required** | (1) 64-bit two's-complement wraparound of SplitMix64 multiplies (2) `lsr()` logical-shift helper correctness (3) `RandomNumberGenerator.state` serialization format stability across Godot 4.7.1 patch versions (4) FNV-1a64 golden-vector test (AC13 of time-system.md) |

## ADR Dependencies

| Field | Value |
|-------|-------|
| **Depends On** | ADR-0001 (DI Container — `register_system()` calls happen in `_post_init()` phase), ADR-0002 (Storage Format — hex encoding of 64-bit integers) |
| **Enables** | ADR-0006 (Economy credit interface — deterministic revenue needs reproducible RNG), ADR-0007 (Navigation determinism — SaveLoad reproducibility depends on RNG determinism as a prerequisite) |
| **Blocks** | SaveLoad determinism verification — can't prove full determinism without RNG architecture locked; TimeSystem implementation; any system that consumes RNG (MemberSim, Congestion if converted) |
| **Ordering Note** | Must be Accepted before TimeSystem implementation begins. All 12 systems' `init()` signatures assume this is decided — the `register_system()` call sites defined in ADR-0001 §System Wiring are the downstream consumers. |

## Context

### Problem Statement

The simulation engine requires reproducible randomness so that loading a save
produces a bit-identical continuation of gameplay (SavLoad Core Rule 5,
time-system.md Core Rule 8). A single shared RNG stream where each system draws
sequentially creates **order coupling**: if System A draws N values and System B
draws M values, the order they draw in determines which values each gets.
Renumbering ticks, adding a system, or reordering the call sequence silently
shifts everyone's draws — and a single misplaced draw in one system
contaminates every other system's randomness without a visible error.

The solution must: allow each system's randomness to be independent of every
other system's draw count; survive save/load with exact state restoration;
produce bit-identical replay given the same master seed and tick sequence; and
not depend on any Godot API whose behavior is undocumented across engine versions.

### Constraints

- Godot's `RandomNumberGenerator` is the per-system RNG engine — we do not
  implement our own PRNG for individual draws (SplitMix64 is used only for
  sub-seed derivation, not for per-draw generation). `RandomNumberGenerator.state`
  is serializable but its internal format is undocumented — we must serialize
  and restore it exactly without assuming its structure.
- GDScript's `>>` operator is **arithmetic** (sign-extending), not logical
  (zero-filling). SplitMix64 requires logical right-shift — a custom `lsr()`
  helper is mandatory.
- GDScript `int` is 64-bit two's-complement with wrapping on overflow. This is
  guaranteed by the language spec and is what SplitMix64 relies on.
- GDScript's built-in `hash()` is explicitly **not** contractually stable across
  engine versions — we cannot use it for deterministic seed derivation.
- Per ADR-0002: all 64-bit integer values (master_seed, RNG states) must be
  serialized as hexadecimal strings in JSON to avoid IEEE 754 truncation.
- Per ADR-0001: all simulation systems are RefCounted; `register_system()` calls
  happen during the `_post_init()` phase after all systems are constructed.

### Requirements

- Each system that needs randomness gets its own `RandomNumberGenerator` instance,
  deterministically derived from `master_seed` and `system_name`
- Two different `system_name` values must produce statistically independent
  sub-streams (not just offset within a shared stream)
- Every sub-stream's complete internal state must survive a serialize/deserialize
  round-trip
- The derivation function must be self-contained in ~30 lines of GDScript with
  no external dependencies
- A golden-vector test must lock the derivation output for a known input so any
  engine or language-level change is caught immediately
- Duplicate registration of the same `system_name` must fail loudly (not silently
  share a stream)

## Decision

### 1. Sub-Stream Derivation: FNV-1a64 → XOR → SplitMix64 Finalizer

Each system's `RandomNumberGenerator` is seeded with a 64-bit integer derived from
`(master_seed, system_name)` through a three-stage pipeline:

**Stage 1 — FNV-1a 64-bit hash of system_name:**
```
FNV_offset_basis = 0xCBF29CE484222325
FNV_prime        = 0x100000001B3

name_hash = FNV_offset_basis
for each byte b in system_name.utf8():
    name_hash = (name_hash XOR b) * FNV_prime   # wraps at 64 bits
```

FNV-1a is chosen over GDScript's `hash()` because it is a published, language-agnostic
standard with pinned constants — the same input string produces the same 64-bit
hash in any language, making the sub-stream derivation reproducible even if ported.

**Stage 2 — XOR combine:**
```
combined = master_seed XOR name_hash
```

XOR is commutative and non-destructive — both inputs contribute full entropy.
This is simpler and faster than concatenation + re-hash and achieves the same
goal: any change to either `master_seed` or `system_name` flips an unpredictable
subset of bits in `combined`.

**Stage 3 — SplitMix64 finalizer:**
```
lsr(z, k) = (z >> k) & ((1 << (64 - k)) - 1)   # logical (zero-filling) right shift

z = combined
z = (z XOR lsr(z, 30)) * 0xBF58476D1CE4E5B9    # wraps at 64 bits
z = (z XOR lsr(z, 27)) * 0x94D049BB133111EB
sub_seed = z XOR lsr(z, 31)
```

SplitMix64 is a proven bijective avalanche finalizer — a single bit flip in
`combined` flips roughly half the bits in `sub_seed`. This ensures that even
similarly-named systems (e.g. "MemberSim" vs "MemberSim2") produce unrelated
sub-streams. The three constants are from the published SplitMix64 specification
and are not project-specific.

**The `lsr()` helper is mandatory.** GDScript's native `>>` on `int` is
arithmetic (sign-extending), which would corrupt the avalanche for the ~50%
of `combined` values with the high bit set. The `lsr()` helper pins the
logical-shift semantics required by SplitMix64.

### 2. Godot RandomNumberGenerator as Per-System PRNG Engine

The derived `sub_seed` is passed to `RandomNumberGenerator.seed`. Each system
holds a reference to its own `RandomNumberGenerator` instance (obtained via
`TimeSystem.get_rng(name)`). The system calls `.randf()`, `.randi()`, etc.
directly — no wrapper is needed, because:

- `RandomNumberGenerator` is self-contained: calling `.randf()` advances only
  that instance's internal state, with zero effect on any other instance.
- Each system owns exactly one instance, so there is no intra-system sharing
  either.
- The `RandomNumberGenerator.state` property exposes the complete internal state
  as an integer — this is what gets serialized (see §3).

We do **not** implement our own PRNG for per-draw generation. SplitMix64 is
used only for sub-seed derivation (called once per system at registration time).
For the tens of thousands of draws per session, Godot's built-in
`RandomNumberGenerator` is adequate and avoids shipping a second PRNG
implementation.

### 3. Serialization as Hexadecimal Strings

Per ADR-0002's mandatory rule for 64-bit integers in JSON:

```gdscript
# serialize
for name in registered_systems:
    rng = get_rng(name)
    per_system_rng_states[name] = "%x" % rng.state   # int64 → hex string

# deserialize
for name in data.per_system_rng_states:
    state = data[name].hex_to_int()    # hex string → int64
    rng = RandomNumberGenerator.new()
    rng.state = state
```

**Why state, not seed:** A system may have drawn thousands of values since
registration. Restoring only the original `sub_seed` and re-drawing would
require replaying every tick's RNG consumption — which is brittle and
order-dependent. Restoring `state` captures the exact post-draw position,
just like restoring `tick_count` captures the exact temporal position.

**Why not `randf()` position:** Counting draws and saving a "draw index" is
fragile — any code change that adds or removes a draw silently shifts all
subsequent draws. Saving the full internal state is draw-count-agnostic.

### 4. Registration vs. Access: Two-Method Split

```
register_system(name)  →  derives sub_seed, creates RNG instance, stores it
                           FAILS if name already registered (no silent sharing)
get_rng(name)          →  returns existing instance (idempotent, never creates)
```

The split exists because a single `get_or_create(name)` method cannot both be
safe to call repeatedly by the legitimate owner AND fail on a colliding second
registrant. `register_system()` is called exactly once per system during
`_post_init()`; `get_rng()` is called whenever the system needs to draw.

Systems that do not use randomness (ZoneRules, Congestion in current design,
Navigation, SelectionSystem, GridSystem) do not call `register_system()` at all
and have no entry in `per_system_rng_states`. The registered set is:
`MemberSim`, `Satisfaction` (if converted), `Economy` (if converted).

### Architecture Diagram

```
┌─────────────────────────────────────────────────────────────┐
│  TimeSystem                                                  │
│  ┌───────────────────────────────────────────────────────┐  │
│  │  master_seed: int64                                    │  │
│  │  rng_registry: Dictionary[String → RNG]                │  │
│  │                                                        │  │
│  │  register_system(name):                                │  │
│  │    1. assert name not in rng_registry                  │  │
│  │    2. name_hash = FNV1A64(name)                        │  │
│  │    3. combined = master_seed XOR name_hash             │  │
│  │    4. sub_seed = SplitMix64_finalize(combined)         │  │
│  │    5. rng = RandomNumberGenerator.new()                │  │
│  │    6. rng.seed = sub_seed                              │  │
│  │    7. rng_registry[name] = rng                         │  │
│  │                                                        │  │
│  │  get_rng(name) → RandomNumberGenerator:                │  │
│  │    return rng_registry[name]  # idempotent, no create  │  │
│  │                                                        │  │
│  │  serialize():                                          │  │
│  │    per_system_rng_states[name] = hex(rng.state)        │  │
│  │                                                        │  │
│  │  deserialize(data):                                    │  │
│  │    for name, hex_state:                                │  │
│  │      rng_registry[name].state = hex_state.hex_to_int() │  │
│  └───────────────────────────────────────────────────────┘  │
│                                                              │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────────┐ │
│  │MemberSim │  │Congestion│  │Satisfact.│  │Economy       │ │
│  │rng.randf │  │(no RNG)  │  │(no RNG)  │  │(no RNG)      │ │
│  │rng.randi │  │          │  │          │  │              │ │
│  └──────────┘  └──────────┘  └──────────┘  └──────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

### Key Interfaces

| Interface | Signature | Notes |
|-----------|-----------|-------|
| Register | `TimeSystem.register_system(name: String) -> void` | Called once per system in `_post_init()`. Hard error on duplicate. |
| Access | `TimeSystem.get_rng(name: String) -> RandomNumberGenerator` | Idempotent. Returns already-registered instance. |
| Serialize | RNG state → `"<int64 as hex string>"` | Per ADR-0002 mandatory hex rule. One entry per registered system. |
| Deserialize | `"<hex string>"` → `rng.state = hex_to_int()` | Restores exact internal state (not re-derives from seed). Missing entry = load failure. |
| Derivation | `derive_sub_seed(master_seed: int, name: String) -> int` | Pure function. FNV-1a64 → XOR → SplitMix64. Only called by `register_system()`. |

## Alternatives Considered

### Alternative 1: Shared master RNG stream with sequential draws

- **Description**: One `RandomNumberGenerator` seeded with `master_seed`.
  Each system draws from it sequentially. No sub-streams.
- **Pros**: Simplest possible implementation (~5 lines of code).
- **Cons**: Every system's randomness depends on every other system's draw count.
  Adding a new draw to Economy silently shifts MemberSim's entire sequence.
  Adding a new system re-seeds everyone differently. A bug in one system's draw
  count contaminates everyone.
- **Rejection Reason**: Order coupling makes the system fragile to any code
  change. The determinism contract requires that a save from version N produces
  the same continuation in version N+1 — shared-stream sequential draws make
  that impossible unless every version's draw count is perfectly frozen.

### Alternative 2: `master_seed + hash(name)` without SplitMix64 finalizer

- **Description**: `sub_seed = master_seed + hash(system_name.to_utf8_buffer())`
  using GDScript's built-in `hash()`.
- **Pros**: One line. No custom hash implementation.
- **Cons**: GDScript's `hash()` is explicitly not contractually stable across
  engine versions (documented in GDScript reference). A 4.7→4.8 upgrade could
  change hash values and break all existing saves. Also, addition (as opposed
  to XOR + SplitMix64) does not avalanche — similarly-named systems like
  "MemberSim" and "MemberSimV2" would produce correlated sub-seeds.
- **Rejection Reason**: Relies on an undocumented, unstable hash function.
  Would break save compatibility on engine upgrades.

### Alternative 3: Per-system `randi()` range offset within a single RNG

- **Description**: Allocate a fixed range of the master RNG's output space to
  each system (e.g. MemberSim gets draws 0–999, Congestion gets 1000–1999),
  seek to the right offset before drawing.
- **Pros**: Only one `RandomNumberGenerator` instance.
- **Cons**: Requires advance knowledge of each system's draw count. A system
  that runs out of its allocation either crashes or wraps into another system's
  range. Seeking via drawing-and-discarding is O(draws) on init. `randi() %
  range` introduces modulo bias unless the range divides `0xFFFFFFFF` evenly.
- **Rejection Reason**: Binds each system to a pre-allocated draw budget —
  any balance change that increases draws breaks the scheme. The allocation
  problem is strictly harder than per-system instances.

## Consequences

### Positive

- Each system's RNG stream is fully independent — adding, removing, or
  reordering draws in one system has zero effect on any other system.
- The derivation function is pinned to published, language-agnostic constants
  (FNV-1a64, SplitMix64) — reproducible in any language, testable offline.
- Save compatibility is robust: restoring `RNG.state` is draw-count-agnostic.
  Code changes that add/remove draws don't affect load correctness.
- Duplicate registration is caught at init time, not after hours of divergent
  simulation.
- The `lsr()` requirement forces implementors to confront GDScript's arithmetic
  shift behavior upfront, rather than discovering it as a heisenbug.

### Negative

- `RandomNumberGenerator.state` is an undocumented internal format. If Godot
  changes it in a patch release, all saves break. Mitigation: a GUT test that
  round-trips `state` → hex → `state` for known seed/draw sequences, run in CI
  on every Godot version update.
- FNV-1a64 + SplitMix64 adds ~30 lines of custom hash code — more surface area
  to review and bug-fix than a one-liner. Mitigation: the `lsr()` helper and
  all constants are pinned in the golden-vector test (AC13 of time-system.md).
- Systems must remember to call `get_rng()` rather than constructing their own
  `RandomNumberGenerator` — but ADR-0001's DI pattern means systems don't have
  access to `RandomNumberGenerator.new()` anyway (they receive their RNG through
  `TickContext`, not direct construction).

### Risks

- **Risk**: `RandomNumberGenerator.state` format changes in a Godot patch.
  **Mitigation**: CI test on every Godot version bump; document the exact
  Godot version in save file header so a migration path exists.
- **Risk**: 64-bit multiply wrapping behaves differently on future GDScript
  backends (e.g., a JIT compiler).
  **Mitigation**: The golden-vector test (AC13) locks the output — any change
  in wrapping semantics fails the test immediately.
- **Risk**: A future system needs RNG but forgets to call `register_system()`
  and instead calls `get_rng()`.
  **Mitigation**: `get_rng()` on an unregistered name returns `null` (not a
  default-constructed RNG). The calling system gets an immediate null-reference
  error rather than a silently independent unseeded stream.

## GDD Requirements Addressed

| GDD System | Requirement | How This ADR Addresses It |
|------------|-------------|--------------------------|
| time-system.md | Core Rule 6: RNG sub-streams — register + access, FNV-1a64 + SplitMix64 derivation | Formalizes the derivation pipeline, the register/get split, and the `lsr()` requirement |
| time-system.md | Core Rule 7: serialization contract — `per_system_rng_states` as hex strings | Defines the hex encoding format and the state-based (not seed-based) restore strategy |
| time-system.md | Core Rule 8: determinism contract — same seed + same ticks = bit-identical replay | Guarantees that per-system RNG independence + state restore = replay without draw-count fragility |
| time-system.md | AC13: golden-vector test for sub-seed derivation | Pins FNV and SplitMix64 constants; makes the golden-vector test a CI gate |
| time-system.md | AC17: duplicate register_system() must fail | The two-method split enforces this at the API level |
| member-sim.md | `get_rng("MemberSim")` for arrival rolls and target selection | MemberSim receives its RNG through TickContext, derived as defined here |
| save-load.md | Core Rule 5: determinism contract — RNG stream states restored exactly | RNG state restore via `rng.state = hex_to_int()` is the mechanism that fulfills this contract |
| save-load.md | AC7: per-system RNG stream states restored, never re-derived from master_seed | Explicitly prohibits re-derivation — `deserialize()` must restore state, not seed |

## Performance Implications

- **CPU**: Sub-seed derivation runs once per registered system at init time
  (~4 systems × ~30 integer operations each = negligible). Per-draw cost is
  `RandomNumberGenerator.randf()` which is the same as any other approach.
- **Memory**: One `RandomNumberGenerator` instance per RNG-using system
  (~4 instances × ~100 bytes = ~400 bytes). Negligible.
- **Load Time**: Hex string → int64 parsing for ~4 RNG states is <1µs.
- **Network**: N/A (single-player, no networking).

## Migration Plan

This is a greenfield decision — no existing code to migrate.

If a future version adds a new RNG-consuming system: add a `register_system()`
call in the SimulationOrchestrator's `_post_init()` for that system. Existing
saves load correctly (the new system's RNG doesn't appear in old saves because
`per_system_rng_states` is keyed by system name — old saves simply lack the
entry, and the new system registers fresh on load if no state is found, or
the orchestrator can require the entry and fail loads that predate the system).

If Godot changes `RandomNumberGenerator.state` format: add a migration path in
SaveLoad that detects the Godot version from the save header and converts old
state values to the new format. This is a SaveLoad concern, not an RNG concern.

## Validation Criteria

1. Golden-vector test (time-system.md AC13): `derive_sub_seed(12345, "Economy")`
   produces a known constant, verified by an independent implementation (Python
   or Rust reference).
2. Cross-system independence test (time-system.md AC7): 1000 draws from
   "MemberSim" and "Congestion" are neither identical nor offset-related.
3. Serialization round-trip test (time-system.md AC8): after serialize →
   deserialize, the next 100 draws per system match the uninterrupted
   continuation.
4. `lsr()` correctness test: for a set of 64-bit values with the high bit set,
   `lsr(v, k)` produces the expected zero-filled result (verified against
   Python's `>>` which is logical for unsigned).
5. Duplicate registration test (time-system.md AC15): second
   `register_system("Economy")` asserts.

## Related Decisions

- **ADR-0001** (DI Container): defines where `register_system()` is called
  (`_post_init()` phase) and how systems receive their RNG references
  (`TickContext.rng`).
- **ADR-0002** (Storage Format): mandates hex encoding of 64-bit integers in
  JSON, which this ADR applies to `RNG.state` and `master_seed`.
- **ADR-0007** (pending, Navigation Determinism): RNG determinism is a
  prerequisite for proving full SaveLoad determinism — Navigation's
  AStarGrid2D tie-break is the other half of that proof.
