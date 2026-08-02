# Story 003: Round-Trip Determinism and Resume-Paused Enforcement

> **Epic**: save-load
> **Status**: Ready
> **Layer**: Foundation
> **Type**: Integration
> **Estimate**: [hours or t-shirt size — fill before sprint planning]
> **Manifest Version**: 2026-07-23
> **Last Updated**: [set by /dev-story when implementation begins]

## Context

**GDD**: `design/gdd/save-load.md`
**Requirements**: `TR-SL-006`, `TR-SL-001` (determinism portion), `TR-SL-005` (validate/dry-run contract verification)
*(Requirement text lives in `docs/architecture/tr-registry.yaml` — read fresh at review time)*

**ADRs Governing Implementation**: ADR-0005: Signal Bus & Event Routing, ADR-0007: AStarGrid2D Determinism, ADR-0002: Storage Format, ADR-0004: SeededRNG Architecture
**ADR Decision Summary**: A save→load→run→save2 round-trip must produce a byte-identical blob to continuing without the load. This depends on three conditions all being true: (a) TimeSystem restores RNG stream states exactly (ADR-0004 — `rng.state = hex_to_int()`, never re-derived), (b) tick order resumes identically (ADR-0005 — fixed dispatch order, no mid-tick yielding), (c) Navigation's AStarGrid2D tie-break is bit-identical across rebuild (ADR-0007 — gate PASSED 2026-07-21, 10/10 processes). Load always resumes paused regardless of saved speed (Core Rule 7). Resume-paused enforcement is part of the determinism contract: if the simulation auto-unpaused on load, the first tick would fire before the player could survey state — breaking Pillar 2's trust promise even if the tick sequence itself were identical.

**Engine**: Godot 4.7.1 | **Risk**: HIGH
**Engine Notes**: The round-trip test is the CANARY for all three determinism conditions. If this test ever fails after a Godot version bump, it means one of the conditions (likely AStarGrid2D tie-break) has changed — treat as a blocking regression, not a flaky test. ADR-0007 gate test must stay in CI and re-run on every version bump. The test harness needs to fast-forward ticks without real-time delay — use a direct tick loop, not `_process`.

**Control Manifest Rules (Foundation layer)**:
- Required: Round-trip test (AC2) must pass before merge — this is the determinism canary; resume-paused verified at load() return (not after first _process)
- Forbidden: Never auto-unpause on load; never skip RNG state restoration (re-derive from master_seed = lost draws = broken determinism)
- Guardrail: Round-trip blob comparison must use `JSON.stringify()` with `full_precision=true, sort_keys=true` for byte-identical output

---

## Acceptance Criteria

*From GDD `design/gdd/save-load.md`, scoped to this story:*

- [ ] AC2 [BLOCKING][Integration] GIVEN a saved game at tick_count=N, WHEN loaded and run N more ticks then saved again (save → load → run N → save2), THEN the second save blob is byte-identical to: save at tick_count=N, run N ticks without any intervening load, then save (save → run N → save_control). The two blobs (save2 vs save_control) must produce identical `JSON.stringify()` output.
- [ ] AC5 [BLOCKING][Integration] GIVEN any saved speed/paused state (1x/2x/3x/paused with paused=false, or paused=true), WHEN loaded via SaveLoad.load(), THEN immediately after load() returns, `TimeSystem.is_paused() == true` and `TimeSystem.speed_multiplier == 0` — regardless of the saved values
- [ ] AC7 [BLOCKING][Integration] GIVEN per-system RNG stream states in the save blob, WHEN load() completes, THEN calling `get_rng(name).randf()` on any registered system produces the next value the original session would have produced — every system's RNG state was restored directly (via `rng.state =`), NOT re-derived from master_seed alone (which would reset to the initial seed and produce different draws from tick 0)

---

## Implementation Notes

*Derived from ADR-0007 + ADR-0004 + GDD Core Rules 5, 7:*

**Round-trip test strategy (integration test, not production code):**
```gdscript
# tests/integration/save_load/roundtrip_determinism_test.gd

func test_roundtrip_determinism() -> void:
    # 1. Set up fresh simulation with known master_seed
    var master_seed := 0xDEADBEEF_CAFE1234
    var orchestrator := _build_orchestrator(master_seed)
    
    # 2. Run to tick N (e.g., 200) — warm up the RNGs
    _fast_forward_ticks(orchestrator, 200)
    
    # 3. Save at tick 200
    var blob_a := orchestrator.save_load._perform_save()
    
    # 4. Path A (control): continue running to tick 300, save
    _fast_forward_ticks(orchestrator, 100)  # now at tick 300
    var blob_control := orchestrator.save_load._perform_save()
    
    # 5. Path B (load): restore from blob_a, run to tick 300, save
    var orchestrator_b := _build_orchestrator(master_seed)  # fresh
    var load_result := orchestrator_b.save_load.load(blob_a, _buildable())
    assert(load_result.ok, "Load failed: %s" % load_result.errors)
    assert(orchestrator_b.time_system.is_paused(), "Load must resume paused")
    orchestrator_b.time_system.resume()
    _fast_forward_ticks(orchestrator_b, 100)  # from tick 200 to 300
    var blob_restored := orchestrator_b.save_load._perform_save()
    
    # 6. Compare: blob_control == blob_restored byte-for-byte
    var control_json := JSON.stringify(blob_control, "  ", false, true)  # indent, sort_keys, full_precision
    var restored_json := JSON.stringify(blob_restored, "  ", false, true)
    assert(control_json == restored_json,
        "Round-trip determinism FAILED:\nControl:\n%s\n\nRestored:\n%s" % [control_json, restored_json])

func _fast_forward_ticks(orchestrator: SimulationOrchestrator, n: int) -> void:
    # Direct tick loop — bypass _process accumulator for test speed.
    # Each on_tick() still runs synchronously; no real-time delay.
    for _i in range(n):
        orchestrator._advance_tick()
```

**Resume-paused enforcement (in load() from Story 002 — verify here):**
```gdscript
# The resume-paused guarantee is implemented in Story 002 (load method).
# This story VERIFIES it with AC5 and documents the design rationale.

# Key contract: after load() returns, TimeSystem.paused == true ALWAYS.
# This is NOT configurable per save file — even if the save says speed=3, paused=false.
# Rationale (GDD Core Rule 7): player needs a beat to survey restored state
# before the simulation resumes affecting it (Pillar 2: 松弛不紧绷).

# Verification in AC5 test:
func test_resume_always_paused() -> void:
    var test_cases := [
        {"speed": 1, "paused": false},
        {"speed": 2, "paused": false},
        {"speed": 3, "paused": false},
        {"speed": 0, "paused": true},
        {"speed": 1, "paused": true},
    ]
    for tc in test_cases:
        var blob := _make_save_with_speed(tc.speed, tc.paused)
        var orchestrator := _build_orchestrator(12345)
        orchestrator.save_load.load(blob, _buildable())
        assert(orchestrator.time_system.is_paused(),
            "Load did NOT resume paused for saved speed=%d, paused=%s" % [tc.speed, tc.paused])
        assert(orchestrator.time_system.speed_multiplier == 0,
            "speed_multiplier should be 0 after load (paused)")
```

**RNG state restoration verification (AC7):**
```gdscript
func test_rng_state_restored_exactly() -> void:
    var master_seed := 0x1234567890ABCDEF
    var orchestrator := _build_orchestrator(master_seed)
    
    # Register systems and draw some values
    _fast_forward_ticks(orchestrator, 100)
    
    # Capture next N draws from each system's RNG (post-tick-100 state)
    var expected_draws := {}
    for sys_name in ["MemberSim", "Congestion", "Satisfaction", "Economy"]:
        var rng := orchestrator.time_system.get_rng(sys_name)
        expected_draws[sys_name] = []
        for _i in range(20):
            expected_draws[sys_name].append(rng.randf())
    
    # Save + load into fresh orchestrator
    var blob := orchestrator.save_load._perform_save()
    var orchestrator2 := _build_orchestrator(master_seed)
    orchestrator2.save_load.load(blob, _buildable())
    
    # Draw from restored RNGs — must match expected exactly
    for sys_name in expected_draws:
        var rng := orchestrator2.time_system.get_rng(sys_name)
        for i in range(expected_draws[sys_name].size()):
            var actual := rng.randf()
            var expected := expected_draws[sys_name][i]
            assert(abs(actual - expected) < 1e-15,
                "RNG draw mismatch for %s[%d]: expected %f, got %f" % [sys_name, i, expected, actual])
```

**Key design decisions:**
- The round-trip test is an integration test, not production code — it lives in `tests/integration/` and exercises the full save→load→run pipeline
- `_fast_forward_ticks()` bypasses `_process` accumulator for test speed — calls `_advance_tick()` directly N times. This is safe because tick dispatch is synchronous.
- Byte-identical comparison uses `JSON.stringify()` with deterministic options (`sort_keys=true, full_precision=true`) — not Dict.hash() or manual field comparison, which would miss float-precision and ordering differences
- Resume-paused is tested with a matrix of {speed} × {paused} — every combination must produce paused=true after load
- RNG restoration test (AC7) captures 20 draws per system post-load and asserts exact float equality — not "approximately equal," because the RNG state was restored to the exact internal state

---

## Out of Scope

*Handled by neighbouring stories — do not implement here:*

- [Story 001]: Save blob composition — this story consumes the blob, doesn't define it
- [Story 002]: Load pipeline implementation — this story VERIFIES the pipeline's determinism, doesn't build it
- [Story 004]: File I/O (actual disk read/write) — this story works with in-memory blobs only
- [Individual systems]: Each system's RNG state restoration — TimeSystem story-004 implemented that; this story verifies it works end-to-end

---

## QA Test Cases

*Sourced from `production/qa/qa-plan-sprint-2-2026-08-02.md` — Automated Tests Required (SL-003). Authoritative test file: `tests/integration/save_load/roundtrip_determinism_test.gd` (~25 assertions + 确定性 probe).*

**What to test**:
- save→load→run→save2 与直接续跑 → save2 字节一致
- 三条件：(a) RNG 流状态精确恢复 (b) tick 顺序一致 (c) Navigation AStarGrid2D tie-break 位一致（ADR-0007 门禁已 PASSED）
- 加载后强制 paused（无论存档 speed）— Core Rule 7

**Stub 方案**: 全部 6 协调系统 stub 覆盖；Navigation rebuild 用 ADR-0007 已验证路径

**Edge cases**: 长时间运行后存档、多个 RNG 子流、paused 存档 round-trip

**Estimated assertions**: ~25 + 确定性 probe

- **AC2**: 往返确定性
  - Given: simulation with known master_seed, run to tick 200
  - When: save → load into fresh instance → run to tick 300 → save (produces blob_restored); compare to: continue original → run to tick 300 → save (produces blob_control)
  - Then: `JSON.stringify(blob_control) == JSON.stringify(blob_restored)` — byte-identical
  - Edge cases: test with tick_count=0 (fresh sim, no ticks); test with different tick counts (50, 500, 1000); test with members mid-walk (in motion at save time); verify the comparison is structural (not just top-level key count)

- **AC5**: 恢复后始终暂停
  - Given: save blobs with all combinations of {speed: 0/1/2/3} × {paused: true/false}
  - When: load() each
  - Then: TimeSystem.is_paused() == true, speed_multiplier == 0 after EVERY load
  - Edge cases: test that _last_speed is preserved correctly (set_speed(3) before save → load → resume → ticks at 3x); test that calling resume() after load correctly uses _last_speed; test that pausing during load (interrupted by something) doesn't corrupt state

- **AC7**: RNG 状态精确恢复
  - Given: sim at tick 100 with all 4 systems' RNGs having consumed draws
  - When: save → load into fresh orchestrator
  - Then: next 20 randf() draws from each system's RNG match continuing the original (no load) exactly (float equality, not approximate)
  - Edge cases: test with zero draws consumed (RNG at its seeded initial state — should still restore correctly); test with one system's RNG having consumed many more draws than another's (draw counts diverge naturally); verify each system's RNG is restored independently (not all from one master stream)

---

## Test Evidence

**Story Type**: Integration (end-to-end determinism pipeline spanning SaveLoad → TimeSystem → GridSystem → all tick systems)
**Required evidence**:
- `tests/integration/save_load/roundtrip_determinism_test.gd` — must exist and pass (AC2, AC5, AC7)

**Status**: [ ] Not yet created

---

## Dependencies

- Depends on: Story 002 (load pipeline must exist to test round-trip). TimeSystem story-004 (RNG state serialization/deserialization). All 6 coordinated systems must have working serialize/deserialize + on_tick implementations (or at least stubs that advance RNG state and mutate a counter).
- Unlocks: Story 004 (file I/O can be added once the in-memory pipeline is proven deterministic)
