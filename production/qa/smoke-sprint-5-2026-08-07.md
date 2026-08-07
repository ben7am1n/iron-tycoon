# Smoke Check Report — Sprint 5

**Date**: 2026-08-07
**Sprint**: Sprint 5（Presentation 层收官：hud + congestion-flow-overlay + selection-system + build-shop-ui）
**Engine**: Godot 4.7.1 (GDScript)
**QA Plan**: Sprint 5 QA 用例内嵌于各 story 文件 QA Test Cases 节（17/17 已回填）
**Argument**: sprint
**Runner**: `godot --headless --script tests/headless_runner.gd`（自定义 SceneTree runner，非 GDUnit4）

---

## Automated Tests

**Status**: PASS — 5028 tests, 5028 passing, 0 failed

```
TOTAL: 5028 passed, 0 failed
RESULT: PASSED
```

godot exit code 0；0 SCRIPT ERROR。ERROR/WARNING 输出均为**有意触发的负向守卫探针**（push_error 后跟 PASS 断言），非运行时故障。泄漏 218 ObjectDB / 12 resources 与既有基线一致。

## Test Coverage

| Epic | Stories | Test Files | Coverage |
|------|---------|-----------|----------|
| hud | 4/4 | 5（state_binding/money_tween/satisfaction_meter/transport + 集成） | COVERED |
| congestion-flow-overlay | 4/4 | heatmap/glyph/access_blocked/rejection_tooltip | COVERED |
| selection-system | 5/5 | 7（logic/bridge/sell/toolbar/rebuild + probes） | COVERED |
| build-shop-ui | 4/4 | 4（palette/gating/arbitration/handoff） | COVERED |

**Summary**: 17/17 COVERED（0 missing / 0 manual forced）— 全部 Logic/Integration/UI story 的 BLOCKING 证据门禁已满足。
**UI 证据**: `production/qa/evidence/` 15 份文档齐备（palette/gating/handoff/arbitration/feedback 等）。

## Manual Smoke Checks

- [x] Headless 启动无崩溃 — PASS
- [x] UI 组件端到端（集成测试 + 15 份 evidence 文档）— PASS
- [x] 交互逻辑（拖放/购买/出售/搬移/模式仲裁）— PASS
- [x] 性能（AC-PERF 阈值内）— PASS

## Playable Build Note

UI 组件端到端已由集成测试验证，但根 `project.godot` 尚无 `run/main_scene` / 组装场景（src/ 为 .gd 脚本，无 .tscn）。可玩入口现存于 `prototypes/gym-flow-vertical-slice/`。**Playable Build 组装属后续任务**（playtest 卡 t_41c2a396 已 blocked 等待），不构成本 sprint 缺陷。

## Verdict

**PASS** — Sprint 5 全量测试全绿（5028/0），17/17 story 独立审查 PASS（17 张审查卡全部 done 有 PASS 证据），15 份 UI 证据齐备，Presentation 层 4 epic 全绿。
