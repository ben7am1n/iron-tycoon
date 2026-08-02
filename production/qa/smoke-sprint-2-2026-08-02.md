# Smoke Check Report — Sprint 2

**Date**: 2026-08-02
**Sprint**: Sprint 2（2026-08-04 → 08-15，Foundation 收官：time-system + save-load）
**Engine**: Godot 4.7.1 (GDScript)
**QA Plan**: `production/qa/qa-plan-sprint-2-2026-08-02.md`
**Argument**: sprint
**Runner**: `godot --headless --script tests/headless_runner.gd`（自定义 SceneTree runner，非 GDUnit4）
**Tree**: main @ 04eba3c（gate t_e320fc1e 集成：TS-001..SL-003 mainline + SL-004 兄弟分支合并）

---

## Automated Tests

**Status**: PASS — 1789 tests, 1789 passing, 0 failed

```
TOTAL: 1789 passed, 0 failed
RESULT: PASSED
```

godot exit code 0；0 SCRIPT ERROR。139 条 ERROR 输出全部为**有意触发的负向守卫探针**（GridSystem 冻结守卫、SimSystem 二次 init、before-init 调用），是测试断言的一部分，非运行时故障。

### 逐文件结果

| 测试文件 | 断言 | 结果 |
|---------|-----:|------|
| tests/unit/grid_system/grid_core_cell_data_test.gd | 69 | PASS |
| tests/unit/grid_system/grid_solidity_coords_test.gd | 80 | PASS |
| tests/unit/grid_system/grid_rotation_test.gd | 43 | PASS |
| tests/unit/grid_system/grid_can_place_test.gd | 64 | PASS |
| tests/unit/grid_system/grid_commit_clear_test.gd | 59 | PASS |
| tests/unit/grid_system/grid_state_reader_snapshot_test.gd | 83 | PASS |
| tests/unit/grid_system/grid_system_signals_test.gd | 64 | PASS |
| tests/unit/grid_system/grid_system_guardrail_test.gd | 34 | PASS |
| tests/unit/time_system/orchestrator_tick_dispatch_test.gd | 50 | PASS |
| tests/unit/time_system/tick_accumulator_test.gd | 65 | PASS |
| tests/unit/time_system/lsr_helper_test.gd | 30 | PASS |
| tests/unit/time_system/seeded_rng_substream_test.gd | 60 | PASS |
| tests/unit/time_system/time_serialization_test.gd | 129 | PASS |
| tests/unit/equipment_catalog/equipment_def_catalog_test.gd | 76 | PASS |
| tests/unit/equipment_catalog/catalog_json_loading_test.gd | 82 | PASS |
| tests/unit/equipment_catalog/catalog_footprint_access_validation_test.gd | 69 | PASS |
| tests/unit/equipment_catalog/catalog_pipeline_strict_mode_test.gd | 55 | PASS |
| tests/unit/equipment_catalog/catalog_use_duration_validation_test.gd | 73 | PASS |
| tests/unit/equipment_catalog/catalog_cost_formula_test.gd | 25 | PASS |
| tests/integration/equipment_catalog/catalog_edge_cases_test.gd | 61 | PASS |
| tests/integration/grid_system/grid_serialization_test.gd | 82 | PASS |
| tests/integration/grid_system/grid_navigation_solidity_test.gd | 14 | PASS |
| tests/integration/grid_system/grid_perf_drag_smoke_test.gd | 7 | PASS |
| tests/integration/save_load/saveblob_composition_test.gd | 108 | PASS |
| tests/integration/save_load/load_orchestration_test.gd | 87 | PASS |
| tests/integration/save_load/roundtrip_determinism_test.gd | 152 | PASS |
| tests/integration/save_load/file_io_version_test.gd | 68 | PASS |

**合计：1789 passed / 0 failed**（Sprint 1 基线 1040 → +749，超过预期 1500+）

## Test Coverage

- time-system 4/4 story 对应 6 个测试文件（orchestrator、accumulator、lsr、substream、serialization + error probe）
- save-load 4/4 story 对应 4 个测试文件（composition、orchestration、roundtrip、file-io）
- 全部 27 个测试文件注册于 `tests/headless_runner.gd` TEST_FILES（含两分支联合后的 4 个 save_load 测试）

## Pending Tests（隔离，不冒充通过）

- `tests/smoke/core_smoke_test.gd` — 测原型实现，违反 prototype-code.md；解锁条件已满足（grid + time-system），待 Core 层迁移
- `tests/integration/core_loop/core_loop_test.gd` — preload 原型路径无法解析；解锁条件 = Core 层 epic（PlacementSystem + Navigation + MemberSim + Congestion）

## Verdict

**PASS** — Sprint 2 全量测试全绿，8/8 story 独立审查 PASS，集成树（SL-002/003 与 SL-004 两兄弟分支合并）无回归。
