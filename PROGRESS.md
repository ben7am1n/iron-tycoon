# 撸铁大亨 (Iron Tycoon) — 项目进度速览

## 当前更新 — 2026-09-07

**M3 三日社区故事闭环与《潜水员戴夫》动态美术样板（Step A–E + 阶段二四大拓展）全量验收通过**：全量测试 125 文件、**6,725 项断言全部通过、0 失败（100% 通过率）**。
1. **三日完整故事与进阶事件闭环（M3）**：完成首日循环、两门核心课程（跑步机间歇训练与瑜伽核心力量）、阿洛/老邱/林师傅三人专属支线故事、门头改造、打烊乐队邀请与包场事件；修复了模式切换状态隔离、器械收纳取回安全、嵌套损坏存档校验与补充营业日推进。
2. **音频系统全链路接入**：11 项专属音效与 BGM 资产（移动、放置、指导、踩节拍、打烊铜钟、保存提示、日落外出、成功 chime）全部完成与业务流的契约接线。
3. **《潜水员戴夫》艺术风格动态样板全流程交付（Step A–E）**：
   - **Step A（构图与透视）**：选定 32° 浅斜俯视立体透视，视口立面居中放大，常态 HUD 收缩保护安全区，空间与网格逻辑无缝对齐（`comp-side-by-side.png`, `target-composition-spec.png`）。
   - **Step B（原生像素角色图集）**：32×40px 原生视口像素，程教练（宽肩银发挑染）、通用会员、阿洛（三种对白表情），双器械（跑步机/瑜伽垫）上下机与锻炼循环（`test-step-b-characters.png`）。
   - **Step C（环境重构与四时段光影）**：地面通道与器械底板降噪留白，前台黄铜面板与平板，北墙奖旗与霓虹灯牌；白天/暮色/夜间/打烊四态光照与改造前后清晰对比（`phase-prep-daylight.png`, `renovation-before-after.png` 等）。
   - **Step D（2-3秒角色幽默演出）**：程教练节拍拍掌、阿洛大汗喘气后开怀笑、老邱赞许点头，配合粒子特效、对白展开与音效反馈（`feedback-sequence-composite.png`）。
   - **Step E（60秒实机录像与分镜大图交付）**：覆盖“等待、行走、使用、指导、成功反馈”完整闭环。交付超高清 60 秒实机录像 [gameplay-60s-showcase.mp4](production/qa/evidence/2026-09-07-latest-review/gameplay-60s-showcase.mp4) 与 6 阶段分镜总览 [gameplay-60s-storyboard.png](production/qa/evidence/2026-09-07-latest-review/gameplay-60s-storyboard.png)。
4. **阶段二美术纵深四大拓展（器械/场景/角色/环境）**：
   - **器械动画拓展**：接入四大器械（动感单车、卧推架、瑜伽垫、跑步机）专用 32×40 动画图集，支持多体型会员锻炼。
   - **公园场景重构**：暮色渐变天空、多层次树冠、石界石塑胶跑道、维多利亚路灯暖光池、木条长椅、阿洛吉他水壶与自动 HUD 折叠（`park-before-after.png`）。
   - **老邱与林师傅 NPC 图集与互动**：老邱前台迎宾倚靠值守与点头鼓劲，林师傅钴蓝工装安全帽巡检与点赞。
   - **室内绿植生活细节**：改造后新增陶土盆栽龟背竹与全员同框实机渲染样板 [gym-full-roster-equipment.png](production/qa/evidence/2026-09-07-latest-review/gym-full-roster-equipment.png)。

---

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
