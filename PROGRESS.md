# 撸铁大亨 (Iron Tycoon) — 项目进度速览

> 治愈系桌面健身房经营游戏（Godot 4.7.1 / GDScript / macOS 桌面）。
> 这份文件是项目自身的进度速览；工作室模板说明见 `README.md`。

## 一句话概念
在网格上拖放器械、规划空间，让像素小人顺畅锻炼，把破旧小馆养成连锁帝国。核心是**空间优化**，基调**治愈、无失败**。

## 四条支柱
1. 空间即玩法　2. 松弛不紧绷　3. 一眼看懂越品越深　4. 看得见的蜕变

## 已完成（Design-First 流程）
| 阶段 | 产出 | 文件 |
|---|---|---|
| ✅ 头脑风暴 → 概念 | 游戏概念文档 | [design/gdd/game-concept.md](design/gdd/game-concept.md) |
| ✅ 引擎配置 | Godot 4.7.1 / GDScript | [CLAUDE.md](CLAUDE.md)、[.claude/docs/technical-preferences.md](.claude/docs/technical-preferences.md)、[docs/engine-reference/godot/VERSION.md](docs/engine-reference/godot/VERSION.md) |
| ✅ 艺术圣经 | 治愈像素风视觉标准（9 节） | [design/art/art-bible.md](design/art/art-bible.md) |
| ✅ 系统拆解 | 22 系统 + 依赖图 + 设计顺序 | [design/gdd/systems-index.md](design/gdd/systems-index.md) |

系统索引经 **technical-director 子代理对抗审查**（TD-SYSTEM-BOUNDARY）修订后定稿。

**设计债清理（2026-07-19）**：#3/#4 的上一轮 blocking 已独立复审确认成立（旧 blocking 修订写入文件，无可再改）；#5–#8 完成首次独立复审，全部 Approved。两个真实跨文档 blocking 已当场修订（MemberSim entrance/exit 硬依赖、Overlay access-blocked 默认可见）。**#1–#8 全部 Approved（8/8）。**

**跨文档实现门禁收尾（2026-07-19）**：EquipmentCatalog (#2) 两条跨文档契约闭合——GridSystem OQ#13 三道加载期校验早已落实；MemberSim OQ2 的 4 个 `use_duration_*` 字段本日落实（字段表 + 规则7 校验 + AC-U.1–4）。**核心循环 9 系统（#1–#8 + EquipmentCatalog）现已全部具备实现条件，无跨文档阻塞。**

## 关键架构决定（务必遵守）
- **GridSystem 是空间真相的唯一所有者**（占用/多格占位/旋转映射）。PlacementSystem 只是"叶子写入器"，改完发 `grid_changed` 信号；Navigation/ZoneRules/Congestion 订阅 grid 状态，**不依赖 Placement**。
- 寻路用 **`AStarGrid2D`**（不用 NavigationServer2D）。
- 加 **SimulationOrchestrator + 种子 RNG**，固定 tick 顺序、只在 tick 边界存档 → 保证存档可复现。
- `ZoneRules.evaluate(grid_snapshot)` 是**纯函数**（消除 Placement↔ZoneRules 循环）。
- **`Congestion(t-1) → 路由(t)`** 一帧延迟反馈——让"调布局改善人流"成为真机制。
- 渲染用 **`TileMapLayer`**（⛔ 4.7 已弃用 `TileMap`）。

## 当前阶段：Production —— 实现中

设计与架构阶段已全部完成（16 个 MVP GDD、7 个 ADR、控制清单、两个原型均 PROCEED）。
2026-07-30 起进入编码实现，走 **story 驱动**流程：
`/dev-story` → `/code-review` → `/story-done`，每个 story 必须有通过的自动化测试。

### Sprint 1（2026-07-31 → 2026-08-13）✅ 完成
GridSystem 收尾 + equipment-catalog 追加：14/14 story Complete，测试 1040 全绿，QA APPROVED。

### Sprint 2（2026-08-04 → 2026-08-15）✅ 完成
Foundation 层收官：time-system（4 story）+ save-load（4 story）8/8 Complete，测试 1789 全绿，QA 门禁 PASS。

**Foundation 层 4 个 epic 全部 Complete**（grid-system / equipment-catalog / time-system / save-load）。
**Core 层**：placement-system（7 stories）+ navigation（6 stories）epic 已创建，待开工。

### 下一步
1. Core 层实现（PlacementSystem + Navigation + MemberSim + Congestion）—— 游戏核心循环成形
2. `/create-epics layer: core` 已由 gate 首批事项完成；`core_loop_test` 待 Core 层实现后解锁

| Story | 内容 | 状态 |
|---|---|---|
| GRID-001 | 单元格数据模型（occupant_id / buildable / access_ids） | ✅ Complete |
| GRID-002 | 实体性公式 `is_solid` + 坐标换算 | ✅ Complete |
| GRID-003 | 旋转变换 + 声明包围盒 | ✅ Complete |
| GRID-004 | `can_place` 放置校验 | ✅ Complete |
| GRID-005 | commit / clear + 反向索引 | ✅ Complete |
| GRID-006 | GridStateReader + GridSnapshot | ✅ Complete |
| GRID-007 | 序列化 / 反序列化 | ✅ Complete |
| GRID-008 | 信号 + 集成 + 性能冒烟 | ✅ Complete |

**测试**：1789 个断言全绿（Sprint 1 基线 1040 → Sprint 2 收官 1789），CI 已在 GitHub Actions 实测通过。
**Foundation 层**：4 个 epic 全部 Complete（grid-system 8 / equipment-catalog 7 / time-system 4 / save-load 4）。
**Core 层**：placement-system（7 stories）+ navigation（6 stories）epic 已创建，待开工。

## 实现中确认的引擎事实（Godot 4.7.1，代价换来的）
- **`assert(false)` 会中止当前函数栈帧的剩余部分**，但不终止进程。值类型返回会静默变成零值，**对象类型返回会变成 `null` 并让调用方崩溃** —— 因此公开 API 的守卫用 `push_error()`，不用 `assert()`。
- `@abstract` 在 `RefCounted` 上无效，改用手写 `_init()` 守卫。
- 子类覆写父类同名方法时参数列表不同会**解析期硬报错**，因此 `SimSystem` 不声明公共 `init()`。

详见 [docs/tech-debt-register.md](docs/tech-debt-register.md)。

## 评审模式
`lean`（见 `production/review-mode.txt`）——门禁只在阶段转换时评审。

## 会话状态
最近进度记录：[production/session-state/active.md](production/session-state/active.md)
