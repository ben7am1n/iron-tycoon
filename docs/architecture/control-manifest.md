# Control Manifest

> **Engine**: Godot 4.7.1
> **Last Updated**: 2026-07-23
> **Manifest Version**: 2026-07-23
> **ADRs Covered**: ADR-0001, ADR-0002, ADR-0003, ADR-0004, ADR-0005, ADR-0006, ADR-0007
> **Status**: Active — regenerate with `/create-control-manifest update` when ADRs change

This manifest is a programmer's quick-reference extracted from all Accepted ADRs,
technical preferences, and engine reference docs. For the reasoning behind each
rule, see the referenced ADR.

---

## Foundation Layer Rules

*Applies to: scene management, event architecture, save/load, engine initialisation*

### Required Patterns

- **Use two-phase init for all simulation systems**: `init(...)` receives typed dependencies, `_post_init()` executes side effects after all systems exist. Exception: stateless systems with no post-init work (e.g. ZoneRules) may omit `_post_init()` override. — source: ADR-0001
- **`SimSystem` base class extends `RefCounted`** with a manual `_init()` guard. `@abstract` must **not** be used — verified non-functional on `RefCounted` in Godot 4.7.1 (Node/Control only). The guard fires `push_error` at runtime when `SimSystem.new()` is called directly. — source: ADR-0001
- **`init()` must only be called once** per system instance. Calling `init()` on an already-initialised system must trigger an assertion failure (debug) or logged error (release). — source: ADR-0001
- **Every public method on a `SimSystem` subclass must guard against use-before-init.** Assert that `init()` has been called before executing any logic. This prevents silent failures when a system is constructed but not wired. — source: ADR-0001 (Consequences / Negative)
- **`SimulationOrchestrator` is the single composition root Node.** It owns all 12 systems as `RefCounted` fields and all bridge Nodes as children. No scattered `add_child()` calls across multiple scenes. — source: ADR-0001
- **Initialisation order is enforced topologically** in `SimulationOrchestrator._ready()`. Tier 0 (leaf nodes) through Tier 7 (coordinator) — each tier completes fully before the next begins. — source: ADR-0001
- **Input-requiring systems receive input through thin bridge Nodes.** `PlacementInputBridge` for PlacementSystem, `SelectionInputBridge` for SelectionSystem. Bridges forward events as parsed method calls (grid cells, not screen pixels). — source: ADR-0001
- **Bridges convert screen coordinates to grid cells** before calling system methods. The `RefCounted` system never sees screen pixels. Coordinate conversion uses `GridSystem.world_to_grid()`. — source: ADR-0001, ADR-0005
- **Bridges use `_unhandled_input()` for mouse events, `_unhandled_key_input()` for keyboard shortcuts.** This respects Godot 4.6's dual-focus system (keyboard/gamepad focus separate from mouse/touch). — source: ADR-0005
- **Tick loop uses `_process(delta)` with accumulation**, not a `Timer` node. Handles frame spikes by catching up with multiple ticks per frame, capped at `MAX_TICKS_PER_FRAME = 8`. — source: ADR-0001
- **Tick dispatch is a hardcoded sequence of direct method calls**, NOT signal-driven. Fixed order: `MemberSim.on_tick()` → `Congestion.on_tick()` → `Satisfaction.on_tick()` → `Economy.on_tick()`. Direct calls prevent reentrancy and guarantee order. Note: individual systems may emit signals within their `on_tick()` (e.g. `congestion_updated`). — source: ADR-0005
- **`tick_completed(tick_count: int)` signal fires at the end of each tick sequence** (S2). This is the hook SaveLoad uses for tick-boundary saves. No `on_tick()` call occurs after it. — source: ADR-0005
- **`TickContext` passes `tick_count` + per-system `rng` to `on_tick()`.** Systems that registered for RNG receive a non-null `rng`; others receive `null`. — source: ADR-0005
- **All cross-system signals use Godot's native `signal` keyword on `RefCounted`.** No custom EventBus singleton, no string-based message dispatch. Every signal is catalogued in ADR-0005 §3 (S1–S8). — source: ADR-0005
- **Every signal emit must match the declared argument count exactly.** GDScript does not check arity at parse time — a mismatch crashes at runtime. Every signal (S1–S8) must have a GUT test verifying correct arity on emit. — source: ADR-0005
- **Save blob format: JSON** (`.sav.json`) with `format_version` envelope. Contains `master_seed` + 6 system payloads (GridSystem, TimeSystem, MemberSim, Congestion, Satisfaction, Economy). — source: ADR-0002
- **Equipment catalog format: JSON** (`.catalog.json`) — hand-authorable, VCS-diffable. Coordinates are normalised during load (shifted to `min == (0,0)`), not required to be normalised in the source file. — source: ADR-0002
- **Level geometry format: custom binary** (`.level.bin`) with 28-byte header (7 × int32 little-endian) + `width × height` bytes of buildable mask. — source: ADR-0002
- **`FileAccess.store_*()` methods return `bool` since Godot 4.4.** Every write call must check the return value and handle failure. Applies to both JSON and binary writers. — source: ADR-0002
- **All 64-bit integers in save JSON must be hex strings**, not JSON number literals. `String.num_int64(v, 16)` for signed, `String.num_uint64(v, 16)` for unsigned. Deserialise with `hex_to_int()`. — source: ADR-0002
- **`JSON.stringify()` must use `full_precision=true`** (4th parameter) for deterministic float round-trip. Systems serialising `float` values (Satisfaction, Economy) need this for bit-exact save/load. — source: ADR-0002
- **`FileAccess.flush()` must be called before `f.close()`** for crash safety. Reduces the window for data loss if the process is killed mid-write. — source: ADR-0002
- **Catalog loading uses `JSON.new(); json.parse()`** (not `JSON.parse_string()`) to get error line numbers for designer-facing validation errors. SaveLoad round-trip uses `JSON.parse_string()` — self-written JSON has no authoring errors. — source: ADR-0002
- **All load errors produce `LoadError` objects** with `category` (`"version_mismatch"`, `"parse_error"`, `"validation_failed"`, `"io_error"`), `message` (user-facing), and `detail` (developer-facing). — source: ADR-0002
- **`deserialize(data, mode)` — mode is `"validate"` (Phase A, zero mutation) or `"commit"` (Phase B, apply).** All-or-nothing: Phase B only begins after every system passes Phase A. — source: ADR-0002
- **`JSON.stringify()` sorts dictionary keys alphabetically by default** (`sort_keys=true`, 3rd parameter). `serialize()` methods must not depend on Dictionary key insertion order — it is not preserved in the JSON output. — source: ADR-0002

### Forbidden Approaches

- **Never use Autoload singletons for system access.** Systems must receive dependencies through typed `init()` parameters. Autoload coupling makes unit testing impossible without global-state teardown. — source: ADR-0001
- **Never use Godot Resources (`.tres`/`.res`) for runtime save data.** Editor-coupled, headless-CI-incompatible, not VCS-diffable. Only `FileAccess`-based formats are permitted. — source: ADR-0002
- **Never use `@abstract` on `RefCounted`-extending classes.** Non-functional in Godot 4.7.1 — instantiates silently with no enforcement. Use the manual `_init()` guard pattern instead. — source: ADR-0001
- **Never call `init()` twice on the same system.** Second call is a hard error (assertion in debug, logged in release). — source: ADR-0001
- **Never trigger side effects in `init()`.** `init()` stores references only. Side effects (signal connections, `register_system()` calls) go in `_post_init()`. — source: ADR-0001
- **Never use `_init()` with typed parameters on `RefCounted` for dependency injection.** GDScript `RefCounted._init()` has limited overloading. Use the separate `init()` method pattern. — source: ADR-0001, ADR-0004
- **Never expose GridSystem's internal `reverse_index` Dictionary or `_occupant_id` array as public API.** All reads go through `GridStateReader` typed methods. Internal representation changes must not break consumers. — source: ADR-0002, ADR-0003
- **Never use `yield()`** — use `await` (deprecated since Godot 4.0). — source: `docs/engine-reference/godot/deprecated-apis.md`
- **Never use `TileMap`** — use `TileMapLayer`, one node per layer (deprecated since Godot 4.3). — source: `docs/engine-reference/godot/VERSION.md`, deprecated-apis.md
- **Never use string-based `connect("signal", obj, "method")`** — use typed `signal.connect(callable)` (deprecated since Godot 4.0). — source: deprecated-apis.md
- **Never serialise `AStarGrid2D` internal state.** It has no public serialisation API. Rebuild from `GridSystem.is_solid()` occupancy on load instead. — source: ADR-0007

### Performance Guardrails

- **All 12 systems + orchestrator initialisation**: < 1ms at boot. — source: ADR-0001
- **Tick dispatch overhead**: ≤ 0.1ms for 4 sequential `on_tick()` dispatch calls. — source: ADR-0001
- **Save blob JSON parse**: < 1ms for ~50 KB. — source: ADR-0002
- **Total load time for all 3 formats**: < 5ms (save + catalog + level). — source: ADR-0002
- **`MAX_TICKS_PER_FRAME = 8`** — catch-up cap to prevent death-spiral on frame spikes. — source: ADR-0001

---

## Core Layer Rules

*Applies to: core gameplay loop, main player systems, physics, collision, grid read surface*

### Required Patterns

- **`GridStateReader` defines the read-only contract**: `is_solid(cell)`, `get_occupant_id(cell)`, `get_access_cells(instance_id)`, `get_dimensions()`, `get_placed_instances()`. Extends `SimSystem`. Uses the same manual `_init()` guard pattern as `SimSystem` — `@abstract` is not functional on `RefCounted`. — source: ADR-0003
- **`GridSystem` subclasses `GridStateReader`.** Write methods (`commit()`, `clear()`, `can_place()`) exist **only** on `GridSystem`, not on `GridStateReader`. The type system enforces the read/write split. — source: ADR-0003
- **`PlacedInstance` is a typed `RefCounted` DTO**, not a `Dictionary`. Fields: `instance_id`, `equipment_id`, `anchor`, `rotation`, `footprint_cells`, `access_cells`. Typed `Array[PlacedInstance]` enables GDScript static analysis. — source: ADR-0003
- **`PlacedInstance` fields are immutable after construction.** Callers must **never** modify `footprint_cells`, `access_cells`, or any other field on a `PlacedInstance` returned by `get_placed_instances()`. `GridSnapshot` relies on shallow-copy safety — violating this corrupts both the base grid and all in-flight snapshots. Enforced by convention (GDScript has no `readonly` field modifier). — source: ADR-0003 (Risks)
- **`GridSnapshot` provides speculative grid views** via delta dictionaries (`_adds`, `_removes`). Constructed from a base `GridStateReader` + proposed additions/removals. Immutable after construction. — source: ADR-0003
- **ZoneRules is a stateless pure function**: receives `GridStateReader` as a parameter, does not hold a persistent reference. Same input always produces same output. — source: ADR-0001 (GDD table), architecture.md
- **RNG sub-stream derivation: FNV-1a64 → XOR with `master_seed` → SplitMix64 finaliser.** Pinned to published, language-agnostic constants — reproducible offline for verification. — source: ADR-0004
- **`lsr(z, k)` helper is MANDATORY for SplitMix64.** GDScript's native `>>` is arithmetic (sign-extending), which would corrupt the avalanche for values with the high bit set. The helper pins logical (zero-filling) right-shift semantics. — source: ADR-0004
- **`TimeSystem.register_system(name)` called exactly once per system during `_post_init()`.** Derives sub-seed, creates `RandomNumberGenerator` instance, stores it. Hard error on duplicate registration. — source: ADR-0004
- **`TimeSystem.get_rng(name)` is idempotent — returns existing instance, never creates.** Returns `null` for unregistered names (not a default-constructed RNG). The calling system gets an immediate null-reference error rather than a silently unseeded stream. — source: ADR-0004
- **RNG state is serialised as hex string and restored directly** (`rng.state = hex_to_int()`), not re-derived from `master_seed`. Draw-count-agnostic — adding/removing draws doesn't affect load correctness. — source: ADR-0004
- **`member_completed_visit(member_id: int)` signal (S5) triggers Economy revenue.** Owned by MemberSim, subscribed by Economy and Satisfaction. Fires only on quota-met departures, not on walk-failure or patience-exhaust. — source: ADR-0005, ADR-0006
- **`grid_changed(footprint_cells_changed: Array, access_cells_changed: Array)` signal (S1) fires exactly once per `commit()` or `clear()` call.** Never fires during drag preview. Both parameters are `Array[Vector2i]`. — source: ADR-0005
- **`balance_changed(new_balance: int, delta: int)` signal (S6) emitted after every balance mutation.** Signed `delta` lets HUD animate direction (+ for credit, − for spend). Emitted by both `credit()` and `spend()`. — source: ADR-0005, ADR-0006
- **`Economy.balance` has a floor of 0 (defensive `max(0, balance)`) but no ceiling.** There is no meaningful upper bound on how rich a player can get. Spend must check affordability; credit has no analogous cap. — source: ADR-0006
- **`instance_id` is allocated by PlacementSystem** via a monotonic `next_instance_id` counter. GridSystem stores it as `occupant_id` but never allocates. SelectionSystem reads it. No system may reuse a decommissioned id within a session. — source: architecture.md (cross-cutting ownership rule)

### Forbidden Approaches

- **Never use duck-typing for the grid read surface.** Consumers must depend on the typed `GridStateReader` parameter, not an ad-hoc "object with `is_solid()`." A typo in a method name is a runtime crash discovered only when that code path runs. — source: ADR-0003
- **Never use GDScript's built-in `hash()` for deterministic seed derivation.** `hash()` is explicitly not contractually stable across engine versions. A 4.7→4.8 upgrade could change hash values and break all existing saves. — source: ADR-0004
- **Never use addition instead of XOR + SplitMix64 for sub-seed derivation.** Addition does not avalanche — similarly-named systems produce correlated sub-seeds. — source: ADR-0004
- **Never serialise 64-bit RNG state as a JSON number literal.** IEEE 754 double has 53 bits of mantissa — SplitMix64 uses 64-bit state. Must be hex string. — source: ADR-0004
- **Never re-derive RNG from `master_seed` on load.** Must restore `RandomNumberGenerator.state` directly. Re-derivation would require replaying every tick's RNG consumption — brittle and order-dependent. — source: ADR-0004
- **Never call `spend(-refund)` as a credit workaround.** `spend()` guards against `amount ≤ 0` — this workaround is blocked by design. Use `credit(amount, reason)` instead. — source: ADR-0006
- **Never put the refund formula in Economy.** Economy is a pure ledger — it validates arithmetic properties (amount > 0) but not business rules (refund rate). The refund rate (`REFUND_RATE = 0.5`) is owned by SelectionSystem. — source: ADR-0006

### Performance Guardrails

- **`get_placed_instances()` full scan**: < 0.1ms for 200 instances on a 10,000-cell grid. — source: ADR-0003
- **`GridSnapshot` construction**: < 0.01ms per speculative preview (~500 bytes allocated, disposable). — source: ADR-0003
- **Sub-seed derivation**: ~4 systems × ~30 integer operations each = negligible at init time. — source: ADR-0004
- **Signal emit cost**: O(subscribers) — all signals in the catalog have 1–4 subscribers. Negligible per emit (< 1µs). — source: ADR-0005

---

## Feature Layer Rules

*Applies to: secondary mechanics, AI systems, secondary features*

### Required Patterns

- **`Economy.credit(amount: int, reason: String) -> bool`** — the symmetric counterpart to `spend()`. Adds `amount` to balance. Rejects `amount ≤ 0`. Emits `balance_changed` with positive delta. `reason` is audit-only (e.g. `"sell:instance_5"`). — source: ADR-0006
- **Refund formula owned by SelectionSystem, not Economy.** SelectionSystem computes `floor(0.5 × original_cost)` and passes the result to `Economy.credit()`. Economy never knows equipment costs or refund rates. — source: ADR-0006
- **Navigation `AStarGrid2D` determinism gate: PASSED 2026-07-21.** Cross-process test (10 independent headless Godot launches) confirmed bit-identical `get_id_path()` results for equal-cost paths. Rebuild-on-load is proven correct — Navigation serialises nothing, rebuilds from occupancy on load. — source: ADR-0007
- **Navigation rebuilds `AStarGrid2D` from `GridSystem.is_solid()` occupancy on load.** Incremental sync during live play via `grid_changed` (S1) subscription; full rebuild during load sequence step 4. — source: ADR-0007
- **Determinism gate test stays in CI** and re-runs on every Godot version bump. A passing result in 4.7.1 does not guarantee it in 4.7.2. — source: ADR-0007
- **Lexicographic path stabiliser (`_lexicographic_stabilize()`) is defined as a fallback** if a future Godot version breaks `AStarGrid2D` determinism. Not active in 4.7.1 (gate passed), but implemented and ready to activate. — source: ADR-0007
- **`AStarGrid2D` configuration**: `DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES`, `HEURISTIC_OCTILE`, matching `cell_size` and `region` to grid dimensions. — source: ADR-0007

### Forbidden Approaches

- **Never serialise `AStarGrid2D` internal state** — opaque, undocumented, version-dependent. Rebuild from grid occupancy instead. — source: ADR-0007
- **Never accept non-deterministic pathfinding as a known limitation.** The determinism contract (save-load.md Core Rule 5) is a hard requirement — "accepting" it means saves don't reproduce, defeating the purpose of having a save system. — source: ADR-0007
- **Never skip the cross-process gate test on Godot version bumps.** A passing result in one version does not guarantee it in the next. The test must run in CI on every version change. — source: ADR-0007

### Performance Guardrails

- **`Economy.credit()` / `spend()` cost**: one integer operation + one signal emit — < 1µs each. Identical cost. — source: ADR-0006
- **Lexicographic stabiliser (if activated)**: O(path_length) post-processing. ~2000 cell comparisons/tick for 10 members × ~20-cell paths — < 0.05ms. — source: ADR-0007
- **Gate test CI time**: ~2s (10 × headless Godot process launches). — source: ADR-0007

---

## Presentation Layer Rules

*Applies to: rendering, audio, UI, VFX, shaders, animations*

### Required Patterns

- **Use `TileMapLayer` for grid/floor rendering** — one node per layer. `TileMap` is deprecated since Godot 4.3. — source: `docs/engine-reference/godot/VERSION.md`, deprecated-apis.md
- **Use `DrawableTexture2D` for congestion/flow heatmap overlays.** Draw directly onto the texture without viewport gymnastics. — source: VERSION.md
- **Use `Control` offset transforms for animated UI** without breaking container layout. Opt-in whether the visual offset affects input. — source: VERSION.md
- **Use `tween_await()` for UI/feedback sequencing** — tweens can await signals. — source: VERSION.md
- **For crisp 2D pixel-art**: texture filter = Nearest on sprites and import settings. (Nearest-neighbour viewport scaling is 3D-only in 4.7 — does not affect 2D.) — source: VERSION.md
- **Use typed signal connections only**: `signal.connect(callable)`, never string-based. — source: deprecated-apis.md

### Forbidden Approaches

- **Never use `TileMap`** — deprecated since Godot 4.3. Use `TileMapLayer`. — source: VERSION.md, deprecated-apis.md
- **Never use `VisibilityNotifier2D`** — use `VisibleOnScreenNotifier2D` (renamed in Godot 4.0). — source: deprecated-apis.md

---

## Global Rules (All Layers)

### Naming Conventions

| Element | Convention | Example |
|---------|-----------|---------|
| Classes | PascalCase | `GymFloor` |
| Variables | snake_case | `move_speed` |
| Signals/Events | snake_case past tense | `equipment_placed` |
| Files | snake_case matching class | `gym_floor.gd` |
| Scenes/Prefabs | PascalCase matching root node | `GymFloor.tscn` |
| Constants | UPPER_SNAKE_CASE | `MAX_MEMBERS` |

Source: `.claude/docs/technical-preferences.md`

### Performance Budgets

| Target | Value |
|--------|-------|
| Framerate | 60 fps |
| Frame budget | 16.6 ms |
| Draw calls | < 200 typical scene |
| Memory ceiling | [TO BE CONFIGURED] |

Source: `.claude/docs/technical-preferences.md`

### Approved Libraries / Addons

- [None configured yet — add as dependencies are approved]

### Forbidden APIs (Godot 4.7.1)

These APIs are deprecated or unverified for Godot 4.7.1:

| Deprecated | Use Instead | Since |
|------------|-------------|-------|
| `TileMap` | `TileMapLayer` | 4.3 |
| `VisibilityNotifier2D` | `VisibleOnScreenNotifier2D` | 4.0 |
| `VisibilityNotifier3D` | `VisibleOnScreenNotifier3D` | 4.0 |
| `YSort` | `Node2D.y_sort_enabled` | 4.0 |
| `Navigation2D` / `Navigation3D` | `NavigationServer2D` / `NavigationServer3D` | 4.0 |
| `yield()` | `await signal` | 4.0 |
| `connect("signal", obj, "method")` | `signal.connect(callable)` | 4.0 |
| `instance()` / `PackedScene.instance()` | `instantiate()` | 4.0 |
| `get_world()` | `get_world_3d()` | 4.0 |
| `OS.get_ticks_msec()` | `Time.get_ticks_msec()` | 4.0 |
| `duplicate()` for nested resources | `duplicate_deep()` | 4.5 |

Source: `docs/engine-reference/godot/deprecated-apis.md`

### Forbidden Patterns

| Pattern | Replacement | Why |
|---------|-------------|-----|
| String-based `connect()` | Typed signal connections | Type-safe, refactor-friendly |
| `$NodePath` in `_process()` | `@onready var` cached reference | Performance: path lookup every frame |
| Untyped `Array` / `Dictionary` | `Array[Type]`, typed variables | GDScript compiler optimisations |

Source: `docs/engine-reference/godot/deprecated-apis.md`

### Cross-Cutting Constraints

- **All gameplay values must be data-driven** — configurable in external files, never hardcoded in source. — source: `.claude/docs/coding-standards.md`
- **All public methods must be unit-testable** — dependency injection over singletons. — source: `.claude/docs/coding-standards.md`
- **System methods should avoid `await`.** Use signal-based sequencing (`tick_completed`, `placement_committed`) or timer callbacks instead. If a system method must use `await`, it must hold a `var _keep = self` local before the await point to prevent premature `RefCounted` free. — source: ADR-0001 (Risks)
- **`TimeSystem` starts paused.** The tick clock does not run until explicitly resumed. This affects startup, load, and test behaviour. — source: ADR-0001 (Decision §5, post-init)
- **Systems that don't hold serialisable state omit `serialize()`/`deserialize()`.** ZoneRules, Navigation, PlacementSystem, and SelectionSystem contribute nothing to the save file — their state is either pure-function or derived from GridSystem on load. — source: ADR-0002
- **No hardcoded `OS.is_debug_build()` checks for behaviour differences.** Use injected parameters (e.g. `strict_mode: bool` for catalog validation) so tests can control the mode explicitly. — source: ADR-0002, coding-standards.md
