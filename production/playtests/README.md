# Production Playtests — 管道协议

外部 playtest 的记录、证据与复用工具。目标：用独立于开发者的真实会话，验证
「看着好玩 → 上手好玩」这一核心假设（gate-production-2026-08-02.md 首批事项 #6）。

## 会话索引

| Date | Build | Tester | Build Type | Verdict | Report |
|------|-------|--------|-----------|---------|--------|
| 2026-08-02 | main @ 013c010 | qa-tester (external) | 垂直切片（无 UI） | PASS（机制验证） | [playtest-2026-08-02-external-vertical-slice.md](playtest-2026-08-02-external-vertical-slice.md) |
| 2026-08-07 | main @ 8257484 | qa-tester (external) | 首个带 UI 的可玩 build | **NOT PASS**（2 BLOCKING + 2 HIGH 视觉缺陷） | [playtest-2026-08-07-external-ui-build.md](playtest-2026-08-07-external-ui-build.md) |

## 证据方法（复用基线，父任务 t_805d6523 建立）

1. **运行验证**：`godot --headless --path . -- --smoke`（600 帧无崩溃）+ 窗口模式 `--quit-after` EXIT=0
2. **渲染帧采集**：Godot Movie Maker 模式（Metal 真实渲染，非 headless dummy）
   ```
   godot --path . --write-movie <out>/frame.png --fixed-fps 60 --quit-after N
   ```
   产出 PNG 序列（1280×720），按需挑选关键帧入 evidence/
3. **像素分析**：PIL 按颜色/位置验证画面内容（会员圆点、设备矩形、access cell、
   UI 布局是否在预期区域）——见各报告「证据」小节
4. **外部会话驱动**（新增于 2026-08-07）：`tools/playtest_driver.gd/.tscn`
   实例化真实 main scene，用 `Input.parse_input_event()` 注入与真人完全相同的
   InputEvent（GUI hit-test → bridge → system），同步读取系统状态（placed/
   balance/paused/selection/toolbar），配合 --write-movie 逐帧留证
5. **集成/回归**：`tests/headless_runner.gd` 全量（2026-08-07 基线 5028 passed / 0 failed）

## 模板

`template-playtest-report.md` —— 新会话从模板复制，填 Session Info / Test Focus /
First Impressions / Gameplay Flow / Bugs / Feature Feedback / Quantitative /
Overall / Top 3。

## 规则

- 测试者必须独立于开发者（本管道当前测试者 = qa-tester）
- 每条结论必须有真实运行证据（帧、像素、状态读取）；无法验证就写「无法验证」，不编造
- BLOCKING 缺陷 = 会话 verdict NOT PASS，并路由修复卡；修复后重新 playtest 直到 PASS
- 会话记录 + 证据 + 工具必须提交入 main（2026-08-02 教训：untracked 文件随 worktree
  清理丢失，2026-08-07 起强制入库）
