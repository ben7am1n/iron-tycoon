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

- ~~**2026-07-25** (found during Story 001 review): `tests/integration/core_loop/core_loop_test.gd` fails to load — every `preload()` uses a `res://../../prototypes/...` path that does not resolve. The test never runs, so `tests/headless_runner.gd` reports success while silently skipping it.~~ → **2026-07-30 部分解决**：不再冒充通过。文件已登记进 runner 的 `PENDING_FILES`，每轮显式打印为 `SKIPPED` 并附解锁条件。preload 路径本身仍未修 —— 需等 core 层 epic（PlacementSystem / Navigation / MemberSim / Congestion）的 `src/` 实现产出后按真实 API 重写，见文件头注释。
- ~~**2026-07-25** (found during Story 001 review): `tests/headless_runner.gd`'s `_run_file()` calls `instance.run_all()`, but `run_all()` re-invokes `_init()` — which the engine already ran on `script.new()`. Every test file executes twice through the CI entry point, doubling reported assertion counts.~~ → **2026-07-30 已解决**：测试文件契约改为 `run_all() -> Dictionary`，`_init()` 检测 `RUNNER_META` 后立即返回。实测断言数由 130 回落到真实的 65。
- ~~**2026-07-25** (found during Story 001 review): `tests/smoke/core_smoke_test.gd` preloads implementation files from `prototypes/gym-flow-vertical-slice/`, violating `.claude/rules/prototype-code.md`.~~ → **2026-07-30 部分解决**：已登记进 `PENDING_FILES`，不再运行、不再计入通过。仍需按 `src/` API 重写 —— 解锁条件为 grid-system story-002/004/005/006 + time-system story-003。

### 2026-07-30 修 runner 时新发现并当场解决的问题

- **2026-07-30**（严重）：`tests/headless_runner.gd` 从不汇总各文件的 pass/fail —— `_total_fail` 只在 load 失败时自增，`instance.run_all()` 的返回值被赋给未使用的 `ok` 变量，`_print_summary()` 不打印任何数字。**结果是任何测试失败仍以退出码 0 结束**，`.github/workflows/tests.yml` 声称的"测试失败阻止合并"门禁完全无效。已用一个故意失败的探针实测确认（EXIT = 0），修复后同样探针得到 EXIT = 1。
- **2026-07-30**：`.github/workflows/tests.yml` 本身无法运行 —— 同一 step 里同时写了 `uses: ./`（仓库根目录并无 action.yml）和 `run:`，属非法 Actions 语法，且完全没有安装 Godot 的步骤。已重写为下载官方 `Godot_v4.7.1-stable_linux.x86_64.zip`（带 actions/cache）后执行 runner。**尚未在真实 CI 上跑过 —— 需一次 push 或 PR 才能验证。**
- **2026-07-30**：解析失败的脚本 `load()` 仍返回非 null 的 GDScript 对象，随后的 `script.new()` 以运行时脚本错误中止 `_run_file()`，导致该文件从报告中彻底消失（探针实测：`probe_broken.gd` 既不在汇总里也不影响退出码）。已加 `script.can_instantiate()` 前置检查。
- **2026-07-30**：孤儿测试文件无人发现 —— 写了测试但忘记加进 `TEST_FILES` 时，CI 会一片绿。已加 `_check_registry_coverage()`：扫描 `tests/**/*_test.gd`，任何未在 `TEST_FILES` / `PENDING_FILES` 登记的文件记为失败。同时把"`run_all()` 报告 0 个断言"也判为失败。
- **2026-07-30**（顺带）：测试脚本多为 `extends SceneTree`（非 RefCounted），runner 从不释放实例，每轮留下 32 个 ObjectDB 泄漏 + Canvas/Viewport RID 泄漏警告。已加 `_release()`，警告消失。
