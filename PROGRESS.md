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

## 下一步
设计债已清：#1–#8 全部 Approved（2026-07-19）。仅剩一个跨文档实现门禁——EquipmentCatalog (#2) 须落实 MemberSim 的 4 个 `use_duration_*` 字段（OQ2）+ GridSystem OQ#13 三道加载期校验。

按 CCGS 流程，下一步是 **order-8 fun-validation 里程碑**：先 `/prototype` + `/playtest-report` 验证"调布局让人流顺畅本身就好玩"，再继续 #9 起的经济/元系统。

- `/prototype 网格拖放布局+会员寻路+拥挤热力` — 验证核心循环（建议先用 concept 原型已验证的 PROCEED 结论，补完整 #1–#8 端到端）
- `/design-review design/gdd/equipment-catalog.md` — 清 #2 跨文档门禁（OQ2 + OQ#13）
- `/design-review design/gdd/zone-rules.md` — #9，设计时需回读 GridSystem OQ#13 与 Navigation OQ4（对角缝不可通行）
- `/gate-check pre-production` — MVP 设计就绪度门禁

## 评审模式
`lean`（见 `production/review-mode.txt`）——门禁只在阶段转换时评审。

## 会话状态
最近进度记录：[production/session-state/active.md](production/session-state/active.md)
