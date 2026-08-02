# Smoke Check Report — Sprint 3

**Date**: 2026-08-02
**Sprint**: Sprint 3（Core 层收官：placement-system 7 story + navigation 6 story）
**Engine**: Godot 4.7.1 (GDScript)
**QA Plan**: 13 张逐 story review 卡（qa-tester，全 PASS）—— Sprint 3 编排未单独产出 qa-plan 文件，QA 用例内嵌于各 story 文件 QA Test Cases 节
**Argument**: sprint
**Runner**: `godot --headless --script tests/headless_runner.gd`（自定义 SceneTree runner，非 GDUnit4）
**Tree**: main @ a181af3（gate t_fd3c84bc 集成：804d0fb PL 链 + c494268 NV union + a20912e/877302e/a181af3 NV 独立合并）

---

## Automated Tests

**Status**: PASS — 2394 tests, 2394 passing, 0 failed

```
TOTAL: 2394 passed, 0 failed
RESULT: PASSED
```

godot exit code 0；0 SCRIPT ERROR。ERROR 输出均为**有意触发的负向守卫探针**（GridSystem 冻结、SimSystem 二次 init/before-init、AC14 OOB is_solid 等），是测试断言的一部分，非运行时故障。

### 逐文件结果（Sprint 3 新增 14 个测试文件 + 既有基线）

| 测试文件 | 断言 | 结果 |
|---------|-----:|------|
| tests/unit/placement_system/drag_lifecycle_test.gd | 91 | PASS |
| tests/unit/placement_system/commit_success_test.gd | 36 | PASS |
| tests/unit/placement_system/reject_cancel_test.gd | 97 | PASS |
| tests/unit/placement_system/instance_id_resume_test.gd | 20 | PASS |
| tests/unit/placement_system/relocate_flow_test.gd | 88 | PASS |
| tests/unit/placement_system/is_dragging_cost_scope_test.gd | 30 | PASS |
| tests/integration/placement_system/input_bridge_test.gd | 46 | PASS |
| tests/unit/navigation/config_basic_paths_test.gd | 14 | PASS |
| tests/unit/navigation/diagonal_corner_rules_test.gd | 17 | PASS |
| tests/unit/navigation/path_query_edge_cases_test.gd | 78 | PASS |
| tests/unit/navigation/solidity_sync_test.gd | 27 | PASS |
| tests/unit/navigation/determinism_congestion_blind_test.gd | 19 | PASS |
| tests/unit/navigation/tiebreak_cross_rebuild_test.gd | 13 | PASS |
| tests/integration/navigation/rebuild_load_cell_size_test.gd | 29 | PASS |
| （既有基线 27 文件，grid/time/equipment/save-load） | 1789 | PASS |

**合计：2394 passed / 0 failed**（Sprint 2 基线 1789 → +605，超过预期 2200+）

## Test Coverage

- placement-system 7/7 story 对应 7 个测试文件（unit ×6 + integration ×1），全部注册 TEST_FILES
- navigation 6/6 story 对应 7 个测试文件（unit ×6 + integration ×1，NV-005 含 tiebreak_child 子进程门禁），全部注册 TEST_FILES
- 全部 41 个测试文件注册于 `tests/headless_runner.gd` TEST_FILES（registry coverage 检查通过，exit 0）

## Pending Tests（隔离，不冒充通过）

- `tests/smoke/core_smoke_test.gd` — 测原型实现，违反 prototype-code.md；待 Core 层迁移后重写
- `tests/integration/core_loop/core_loop_test.gd` — **条件解锁**：Core 层 2 epic（PlacementSystem + Navigation）已落地，但测试 preload 原型路径（res://../../prototypes/...）且依赖 MemberSim/Congestion **真实**实现（现为 SL-002 stub）；Feature 层落地后将 preload 指向 src/、按真实 API 重写断言并移入 TEST_FILES

## Verdict

**PASS** — Sprint 3 全量测试全绿（2394/0），13/13 story 独立审查 PASS，集成树（PL-001..007 链 + NV-001..006 链）无回归。Core 层 2 epic 全绿 → 解锁 Feature 层（MemberSim 等）。
