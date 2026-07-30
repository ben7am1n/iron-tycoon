# Test Infrastructure

**Engine**: Godot 4.7.1
**Test Framework**: SceneTree headless runner（不依赖 GdUnit4 插件）
**CI**: `.github/workflows/tests.yml`
**Setup date**: 2026-07-22

## Directory Layout

```
tests/
  unit/               # 独立单元测试（公式、状态机、逻辑）
  integration/        # 跨系统测试 + 存档/读档往返
  smoke/              # 关键路径烟雾测试清单
  evidence/           # 截图日志与手动测试签字记录
  headless_runner.gd  # SceneTree runner（CI 入口，零插件依赖）
```

## Running Tests

### 全量测试（CI / 本地）
```bash
godot --headless --script tests/headless_runner.gd
```

### 单个测试文件
```bash
godot --headless --script tests/smoke/core_smoke_test.gd
```

### 垂直切片项目内测试（原型）
```bash
godot --headless --path prototypes/gym-flow-vertical-slice \
  --script res://src/core/smoke_test.gd
```

## Test Naming

- **Files**: `[system]_[feature]_test.gd`
- **Functions**: `test_[scenario]_[expected]`
- **Example**: `grid_system_placement_test.gd` → `test_rotate_90deg_access_cell_uses_union_bbox()`

## Story Type → Test Evidence

| Story Type | Required Evidence | Location |
|---|---|---|
| Logic | Automated unit test — must pass | `tests/unit/[system]/` |
| Integration | Integration test OR playtest doc | `tests/integration/[system]/` |
| Visual/Feel | Screenshot + lead sign-off | `tests/evidence/` |
| UI | Manual walkthrough OR interaction test | `tests/evidence/` |
| Config/Data | Smoke check pass | `production/qa/smoke-*.md` |

## CI

Tests run automatically on every push to `main` and on every pull request.
A failed test suite blocks merging.

## 历史来源

- `tests/smoke/core_smoke_test.gd` ← 迁自 `prototypes/gym-flow-vertical-slice/src/core/smoke_test.gd`
- `tests/integration/core_loop/core_loop_test.gd` ← 迁自 `prototypes/gym-flow-vertical-slice/src/sim/integration_test.gd`
- `tests/headless_runner.gd` ← 新建（统一 CI 入口）
