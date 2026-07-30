# Tech Debt Register

Advisory deviations accepted at story-close time. Each entry records what was
accepted, why, and where it came from. Review with `/tech-debt`.

---

## Open

- **2026-07-25** (Story 001: Grid Core — Cell Data Model): `GridSystem extends SimSystem` rather than `GridStateReader`. ADR-0003's Migration Plan states GridSystem should subclass `GridStateReader` "from the start," but that class is not built until Story 006. Resolve when Story 006 inserts the intermediate base class — tracked from `production/epics/grid-system/story-001-grid-core-cell-data.md`
- **2026-07-25** (Story 001: Grid Core — Cell Data Model): `SimSystem` exposes `_mark_initialized()` and `_assert_initialized()`, which are not named in ADR-0001's Key Interfaces section. They implement ADR-mandated behaviour ("init() must only be called once"; "every public method must guard against use-before-init") under names the ADR does not specify. Consider a small ADR-0001 clarification recording the verified Godot 4.7.1 override-signature constraint that forced the naming, so the next 11 systems follow the same pattern deliberately — tracked from `production/epics/grid-system/story-001-grid-core-cell-data.md`
- **2026-07-25** (Story 001: Grid Core — Cell Data Model): Untyped `Array` parameters and return types violate the project's mandatory static-typing standard — `get_access_ids() -> Array` should be `Array[int]`; `set_buildable_bulk(cells: Array, ...)` and `get_transformed_cells(footprint: Array, access: Array, ...)` should be `Array[Vector2i]`. The untyped params also force manual `as Vector2i` casts in `get_transformed_cells()`. Low risk, mechanical fix — tracked from `production/epics/grid-system/story-001-grid-core-cell-data.md`
- **2026-07-25** (Story 001: Grid Core — Cell Data Model): `.gitignore:43` contains `!.godot/global_script_class_cache.cfg`, forcing an editor-generated cache file into version control. The file now holds genuine engine output (it previously held hand-written, partly fictional entries), but it will churn on every editor open. Decide whether headless CI genuinely needs it committed, or whether the CI job should run `godot --headless --editor --quit` to regenerate it — tracked from `production/epics/grid-system/story-001-grid-core-cell-data.md`

---

## Pre-existing issues surfaced during Story 001 review

Not caused by Story 001; verified against a clean baseline. Logged here so they
are not rediscovered from scratch.

- **2026-07-25** (found during Story 001 review): `tests/integration/core_loop/core_loop_test.gd` fails to load — every `preload()` uses a `res://../../prototypes/...` path that does not resolve. The test never runs, so `tests/headless_runner.gd` reports success while silently skipping it.
- **2026-07-25** (found during Story 001 review): `tests/headless_runner.gd`'s `_run_file()` calls `instance.run_all()`, but `run_all()` re-invokes `_init()` — which the engine already ran on `script.new()`. Every test file executes twice through the CI entry point, doubling reported assertion counts. Affects `core_smoke_test.gd` and `grid_core_cell_data_test.gd`.
- **2026-07-25** (found during Story 001 review): `tests/smoke/core_smoke_test.gd` preloads implementation files from `prototypes/gym-flow-vertical-slice/`, violating `.claude/rules/prototype-code.md` ("No production code may reference or import from `prototypes/`"). The smoke test should exercise the real `src/systems/` implementations instead. This coupling is also what caused the `class_name GridSystem` collision resolved in Story 001.
