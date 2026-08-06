# Smoke Check Report — Sprint 4

**Date**: 2026-08-05
**Sprint**: Sprint 4（Feature 层收官：member-sim + congestion + zone-rules + satisfaction + economy）
**Engine**: Godot 4.7.1 (GDScript)
**QA Plan**: Sprint 4 QA 用例内嵌于各 story 文件 QA Test Cases 节（21/21 已回填）
**Argument**: sprint
**Runner**: `godot --headless --script tests/headless_runner.gd`（自定义 SceneTree runner，非 GDUnit4）

---

## Automated Tests

**Status**: PASS — 3428 tests, 3428 passing, 0 failed

```
TOTAL: 3428 passed, 0 failed
RESULT: PASSED
```

godot exit code 0；0 SCRIPT ERROR。ERROR/WARNING 输出均为**有意触发的负向守卫探针**（push_error 后跟 PASS 断言），非运行时故障。

## Test Coverage

| Epic | Stories | Test Files | Coverage |
|------|---------|-----------|----------|
| member-sim | MS-001..005 | 8（lifecycle/target_selection/reservation/path_invalidation/serialization + integration） | COVERED |
| congestion | CG-001..004 | 5（scalar/density/access_reachable/determinism/serialization） | COVERED |
| zone-rules | ZR-001..004 | 5（evaluate_purity/synergy/spaciousness/preview_equiv + fake reader） | COVERED |
| satisfaction | SAT-001..004 | 5（accumulators/penalty_caps/global/recovery_loop） | COVERED |
| economy | ECON-001..004 | 4（revenue/spend_gating/credit/serialization） | COVERED |

**Summary**: 21/21 COVERED（0 missing / 0 manual forced）— 全部 Logic/Integration story 的 BLOCKING 自动化证据门禁已满足。

## Core Loop Test

`tests/integration/core_loop/core_loop_test.gd` — **已解锁**（Sprint 4 门禁修复：preload 改写 src/ 真实实现 + 移入 TEST_FILES）
- 独立运行：**15 passed / 0 failed**
- 覆盖：会员生命周期 → 目标选择 → 寻路 → 排队 → 使用 → 离开全链路
- 69 files enabled / 1 pending（core_smoke_test 为 prototypes 正当隔离）

## Manual Smoke Checks

- [x] Headless 启动无崩溃 — PASS
- [x] 游戏核心循环端到端（core_loop_test 15 项）— PASS
- [x] 确定性（save-load + 多系统 round-trip 字节一致）— PASS
- [x] 性能（AC-PERF.3 阈值内，11062us vs 10953us 基线）— PASS

## Verdict

**PASS** — Sprint 4 全量测试全绿（3428/0），21/21 story 独立审查 PASS（21 张审查卡全部 done 有 PASS 证据），core_loop_test 完全解锁，Feature 层 5 epic 全绿。
