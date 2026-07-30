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

退出码 0 = 全部通过，1 = 有任何失败。CI 直接依赖此退出码。

### 单个测试文件
```bash
godot --headless --script tests/unit/grid_system/grid_core_cell_data_test.gd
```

## 测试文件契约

新增测试文件必须满足三条，否则 runner 会把它记为失败：

1. 实现 `run_all() -> Dictionary`，返回 `{"pass": int, "fail": int}`
2. `_init()` 开头检查 `Engine.has_meta(RUNNER_META)` 并立即 `return` —— 被 runner
   托管时用例由 `run_all()` 驱动；漏掉这一步会让每个用例跑两遍（`script.new()`
   已经触发过一次 `_init()`）
3. 被 runner 驱动时不要调用 `quit()` —— 进程退出码由 runner 统一决定

标准骨架：

```gdscript
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"

var _pass := 0
var _fail := 0


func _init() -> void:
	if Engine.has_meta(RUNNER_META):
		return
	var result := run_all()
	quit(1 if int(result["fail"]) > 0 else 0)


func run_all() -> Dictionary:
	_test_something()
	print("\n=== MY TEST: %d passed, %d failed ===" % [_pass, _fail])
	return {"pass": _pass, "fail": _fail}
```

写完后把路径追加到 `tests/headless_runner.gd` 的 `TEST_FILES`。**忘记注册会让
CI 失败** —— runner 会扫描 `tests/**/*_test.gd`，任何未在 `TEST_FILES` 或
`PENDING_FILES` 中登记的文件都记为失败，避免"写了测试但从未运行"。

runner 还会把以下情况判为失败，而不是放过：
- 脚本解析错误（`load()` 对解析失败的脚本仍返回非 null 对象）
- 注册路径在磁盘上不存在
- `run_all()` 报告 0 个断言（空测试不算通过）
- `run_all()` 返回值不是合法 Dictionary

## 隔离（SKIPPED）的测试

`headless_runner.gd` 的 `PENDING_FILES` 登记暂时不能运行的测试。它们每轮都会被
显式打印为 `SKIPPED` 并附原因与解锁条件 —— **隔离的测试绝不允许冒充通过**。
修好后把路径从 `PENDING_FILES` 移入 `TEST_FILES` 即可。

当前隔离：`tests/smoke/core_smoke_test.gd`、`tests/integration/core_loop/core_loop_test.gd`
（两者都从 `prototypes/` 导入实现代码，见文件头注释）。

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
A failed test suite blocks merging。workflow 下载官方 Godot 4.7.1 Linux 构建
（`Godot_v4.7.1-stable_linux.x86_64.zip`，带 actions/cache）后运行 runner，
以 runner 的退出码作为门禁。

## 历史来源

- `tests/smoke/core_smoke_test.gd` ← 迁自 `prototypes/gym-flow-vertical-slice/src/core/smoke_test.gd`
- `tests/integration/core_loop/core_loop_test.gd` ← 迁自 `prototypes/gym-flow-vertical-slice/src/sim/integration_test.gd`
- `tests/headless_runner.gd` ← 新建（统一 CI 入口）
