# 撸铁大亨 (Iron Tycoon) — 项目进度速览

## 当前更新 — 2026-09-08

**《潜水员戴夫》动态美术核心差距全面收口与真实营业闭环验收通过**：全量测试 125 文件、**6,748 项断言全部通过、0 失败（100% 通过率）**。
1. **默认接入与显示校准**：
   - 32° 浅斜俯视舞台构图正式作为社区故事默认镜头装配进 `src/main.gd`，自适应动态视口逆投影，消除对测试脚本预设全局变量的依赖。
   - 确立统一像素倍率：32×40 原生像素资产在 `WorldRoot` 0.75 缩放下精准映射为 24×30 视口像素，并在 1280×720 屏幕下呈现 72×90 像素（3× 整数缩放）。
   - 角色移动彻底消除逐格跳跃：接入 `MemberSim` 连续亚格坐标 `position_xy`，角色脚底与投影随步长连续平滑位移并 `.round()` 对齐整数像素。
2. **器械精准接触与平滑上下机插值**：
   - 建立四大器械（跑步机、动感单车、卧推架、瑜伽垫）精准锚点表 `_build_community_equipment_anchors`。
   - 引入 4-tick 上下机平滑插值过渡（`t_mount` 与 `t_dismount`），消除瞬间闪现/瞬移，保持底层模拟计费与训练时长完全精确不变。
3. **一间房光影质感与环境精修**：
   - 夜间/打烊阶段（SERVICE/CLOSE）北墙窗外呈现深冷靛蓝夜景（`#162032`）与月色高光，强烈衬托室内钨丝暖光；顶灯光斑半径收紧至 42/28/15，消除地面泛白，清晰展现松木与橡胶地垫质感。
   - 彻底净化 `CommunityHUD` 英文程序状态文案，统一为高可读性本地化说明（`学员候课准备`、`团体课授课中`、`课程圆满结课`）。
4. **真实玩法证据链与声画闭环交付（区别于编排展示）**：
   - 交付 6 阶段真实日常营业里程碑截图与总览分镜 [natural-gameplay-storyboard.png](production/qa/evidence/2026-09-08-art-review/natural-gameplay-storyboard.png)。
   - 交付首个带完整声效（BGM + 环境白噪音 + 指导/开课/打烊音效）的 60 秒高清实机录像 [natural-gameplay-60s-with-audio.mp4](production/qa/evidence/2026-09-08-art-review/natural-gameplay-60s-with-audio.mp4)。


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
