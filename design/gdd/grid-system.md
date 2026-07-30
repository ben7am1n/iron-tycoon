# GridSystem

> **Status**: In Design — 已过两轮对抗式评审（2026-07-16 首评、2026-07-17 复审），累计 7 项 blocking 全部已解决
> **Author**: user + agents
> **Last Updated**: 2026-07-17
> **Implements Pillar**: Pillar 1 (空间即玩法 / Space is the Game), Pillar 3 (一眼看懂 / Easy to Read)
> **Review**: `/design-review` full mode ×2。首评 5 specialists + creative-director；复审 systems-designer + qa-lead + creative-director（另 3 位因 API 配额中断，由主 session 补做非独立 pass）。评审记录见 `design/gdd/reviews/grid-system-review-log.md`
> **复审 creative-director 判定**：修订后**无需再跑一轮全评审** —— 残余全部是本文档已确立原则的机械应用，非新判断

## Overview

GridSystem is the single source of spatial truth for the gym floor. It owns cell occupancy, multi-cell equipment footprints, and rotation-to-footprint mapping for every cell in the room, and exposes both a query interface (is this cell/region free, what occupies it) and a controlled mutation interface (commit or clear occupancy) — plus the ability to produce a read-only snapshot of grid state for speculative use, such as placement previews. Every other spatial system in the game depends on GridSystem rather than on each other: PlacementSystem writes to it, Navigation reads its solidity to drive `AStarGrid2D`, ZoneRules reads snapshots of it to evaluate adjacency, and SelectionSystem reads it to resolve "what's at this cell." GridSystem exists because without a single arbitrator of "what's where," every consumer would need its own copy of spatial truth, guaranteeing desync bugs — centralizing it here is what makes deterministic saves, correct pathfinding, and consistent zone rules possible.

## Player Fantasy

> **玩家永远不会"感受到" GridSystem——这正是它成功的标志。**

GridSystem 服务的不是一种幻想，而是一种**前提**：玩家在支柱1"空间即玩法"里投入的每一次"再挪一下试试"，都建立在一个默契之上——**空间会诚实地回应我**。器械占了两格就是两格；旋转之后它该挡住的地方就挡住；两台器械之间留出的那条缝，小人就真的能穿过去。玩家不会为此赞美网格，但只要这个默契破一次（器械视觉上放下了却没占住格子、旋转后占用范围和画面对不上、小人从"明明摆满了"的地方穿了过去），玩家失去的不是一个功能，而是**"这个空间是我设计的"这一整个信念**——支柱1 随之崩塌。

因此本系统的情感目标是**沉默的可信度（silent trustworthiness）**：

- **玩家该感到的**：不假思索的笃定。他们盯着的是布局、是动线、是"这里会不会堵"，而不是"引擎有没有理解我放了什么"。认知预算 100% 花在设计上，0% 花在怀疑上。
- **玩家不该感到的**：任何一次"咦？"。惊讶是本系统唯一的失败模式——哪怕是正面的惊讶。
- **锚定的玩家瞬间**：玩家把跑步机拖到墙边，它"啪"地吸附到位；他们没有确认、没有检查、连想都没想，视线已经移向下一台器械。那个**没有发生的确认动作**，就是 GridSystem 交付的全部价值。

这也是支柱3"一眼看懂"的隐形地基：所有可视化（拥挤度、动线、区域效果）都只是网格真相的渲染。真相错了，再好的可视化只会更快、更自信地骗人。

**一句话总结**：GridSystem 的幻想不是"我在用一个很棒的网格"，而是"我压根没想过网格这回事"。

> ⚠️ `creative-director` 未咨询 —— Lean 模式。进入生产前请人工复核本节。

## Detailed Design

### Core Rules

#### 1. 坐标系与房间几何

- 整数格坐标 `(col, row)`；原点 `(0,0)` 在房间**包围盒左上角**，`col` 向右为正，`row` 向下为正（与 `TileMapLayer` 惯例一致）。
- **正交方格网格**（`CELL_SHAPE_SQUARE`）。"轻等距"观感纯由美术贴图与渲染排序制造，**不影响网格数学** —— 逻辑层永远是方格。
- 房间 = 包围盒 `Rect2i(0, 0, width, height)` + **每格 `buildable: bool`**。不规则房间（L 形等）由 `buildable=false` 标记墙/柱/门槛/窗表达。
- `buildable` 与 `occupancy` 是**两个正交维度**：前者是静态房间几何（关卡加载时确定，**MVP 阶段运行时只读**），后者是动态器械占用。

#### 2. 每格数据形状

| 字段 | 类型 | 语义 | 互斥性 |
|---|---|---|---|
| `buildable` | bool | 静态房间几何 | — |
| `occupant_id` | int | footprint 占用者，`-1` = 空 | **互斥单值** |
| `access_ids` | Array[int] | 使用位归属者集合 | **非互斥**，可多个 |

> **`occupant_id` 与 `access_ids` 必须是两个独立字段，不可合并。** 合并会导致"两台器械 access 重叠"（本设计明确允许）在数据层直接冲突——后写覆盖先写，且 `clear()` 会误清空另一台器械的 access 归属。

GridSystem **不**在 cell 里存 zone 归属或 EquipmentInstance 引用 —— 它只认整数 `occupant_id`，不认具体是什么器械。这让快照拷贝代价极小，且下游数据结构变化不会牵连 GridSystem。

**建议内部存储**（经 4.7.1 headless 实测支撑）：`occupant_id` → 扁平 `PackedInt32Array`（按 `y*width+x` 索引）；`buildable` → `PackedByteArray`；`access_ids` → 稀疏 `Dictionary`（大多数格为空，稠密存储浪费）。实测 3600 格 `PackedInt32Array.duplicate()` 仅 **0.04μs**，比 `Dictionary` 快约 3500 倍。

#### 3. 锚点约定

footprint / access 定义在 **canonical（0°）** 坐标系下，锚点固定为**声明包围盒左上角格 `(0,0)`**。放置时锚点格 = 玩家拖放确定的那一格。

选左上角而非"语义上有意义的格"（如跑步机头部）的理由：左上角在旋转下有唯一、可枚举的变换公式；语义锚点在非方形 footprint 转 90°/270° 后未必还落在新包围盒内，需 case-by-case 特判。

#### 4. footprint × rotation → cells 映射

> **🔴 最高危规则**：footprint 与 access **必须共用同一个"声明包围盒" `(W,H)`** 做旋转变换 —— `(W,H)` = `footprint_cells ∪ access_cells` 的**并集**包围盒宽高，**不是** footprint 自己的局部包围盒。

> **🔴 调用约定（契约的一部分，不是实现建议）**：`declared_bounds()`（D.5）**必须每个 `(equipment_def, rotation)` 变换调用点只求解一次 `(W,H)`**，得到的同一个 `(W,H)` **必须同时传给 footprint 变换与 access 变换**。
>
> > *措辞注*：`declared_bounds()` 的签名**只收 `equipment_def`**（见 D.5）—— `(W,H)` 是 canonical(0°) 声明包围盒，**与 rotation 无关**，旋转后的新包围盒由 D.1 公式在变换内部处理（90°/270° 时 W/H 对调）。因此本条约束的**不是**"按 rotation 分别缓存"，而是"**在任何一次 footprint+access 的成对变换中，两者必须收到同一个 `(W,H)` 值**"。
>
> **严禁**把 footprint 与 access 拆成两次独立的变换调用、各自在内部推导自己的 `(W,H)`：
>
> ```gdscript
> # ❌ 错误 —— 每次调用各自推导局部包围盒，重现本节最高危 bug
> var fp := _transform(equipment_def.footprint_cells, rotation)   # 内部算出 (W=1,H=2)
> var ac := _transform(equipment_def.access_cells, rotation)      # 内部算出 (W=1,H=1)
>
> # ✅ 正确 —— 并集包围盒算一次，两者共用
> var wh := declared_bounds(equipment_def)                        # (W=1,H=3)
> var fp := _transform(equipment_def.footprint_cells, rotation, wh)
> var ac := _transform(equipment_def.access_cells, rotation, wh)
> ```
>
> **为何单独列出**：上面那条规则约束的是**公式**，这条约束的是**调用方式**。一个实现者可以完全遵守"必须用并集包围盒"这句话，却仍然通过"两次独立调用"这个看似无害的代码组织方式重现同一个 bug —— 他的每次调用**单独看都是对的**，错的是"两次"本身。因此变换函数**不得**接受一个格集合就自行推导包围盒；`(W,H)` 必须是**显式入参**。
>
> 这也是为什么 `get_transformed_cells()` 的契约返回 `TransformedFootprint`（footprint + access 一次性算完的复合结果），而不是提供一个"转换任意格集合"的通用工具函数 —— **API 形状本身就是这条约定的第一道防线**。
>
> **🔴 但"第一道防线"不是"封死"—— 把地板写清楚**：API 形状挡住的是**外部消费者**（`declared_bounds()` 只收 `equipment_def`，不收裸格集合，因此 PlacementSystem 等**无法**请求一个 footprint-only 或 access-only 的包围盒）。它挡不住的是 **GridSystem 内部的实现者**：一个人完全可以在调用点手搓一个局部 bbox 助手、算出两个不同的 `(W,H)`、分别作为"显式入参"传进去 —— **字面上满足了本节每一个字，实质上重现了同一个 bug**。
>
> **真正的地板是 AC-C4.3**（跑步机 fixture 在 90°/270° 下 access 坐标两个分量必须 `>= 0` 的回归测试）—— 它是这条规则唯一"漏了一定会响"的机制。本节的防护栈因此是：
>
> | 层 | 机制 | 挡住谁 |
> |---|---|---|
> | 第一道防线 | API 形状（`declared_bounds()` 不收裸格集合；返回复合 `TransformedFootprint`） | 外部消费者 —— **结构性封死** |
> | 第二道 | 本节的调用约定 + 正误代码对照 | 内部实现者 —— **软约束，代码审查抓** |
> | **地板** | **AC-C4.3 回归测试** | 内部实现者 —— **漏了一定会响** |
>
> 这与 `GridStateReader` 一节的结论是**同一个原则的又一次应用**："软兜底可以接受，但它必须站在一个硬地板上。"**不要把第一道防线误读成地板** —— 若某次重构删掉了 AC-C4.3，这条最高危规则就退化成了纯纪律。

```
(x', y') = R_rotation(x, y; W, H)

R_0  (x,y;W,H) = (x, y)
R_90 (x,y;W,H) = (H-1-y, x)
R_180(x,y;W,H) = (W-1-x, H-1-y)
R_270(x,y;W,H) = (y, W-1-x)
```

最终格 = `anchor_cell + Vector2i(x', y')`。结果分量恒落在 `[0, new_W-1] × [0, new_H-1]` 内（90°/270° 时 W/H 对调），**天然不产生负值或越界，无需 clamp**。

**Worked example —— 1×2 跑步机**：`footprint = [(0,0),(0,1)]`，`access = [(0,2)]`（后方通道）。并集包围盒 **W=1, H=3**（不是 footprint 的 1×2）。

| rotation | footprint | access | new_size |
|---|---|---|---|
| 0° | `(0,0),(0,1)` | `(0,2)` | `(1,3)` |
| 90° | `(2,0),(1,0)` | `(0,0)` | `(3,1)` |
| 180° | `(0,2),(0,1)` | `(0,0)` | `(1,3)` |
| 270° | `(0,0),(1,0)` | `(2,0)` | `(3,1)` |

> 若误用 footprint 局部包围盒 `(W=1,H=2)` 去转 access 偏移 `(0,2)`，90° 会算出 `(-1,0)` —— **非法负坐标**。且 **0°/180° 测试无法暴露此 bug**（对称掩盖），只有 90°/270° 才炸。单元测试**必须**覆盖非方形 footprint 全 4 朝向的 access 精确坐标；上表可直接作为 fixture。

#### 5. 使用位（access cells）规则

| 问题 | 规则 | 理由 |
|---|---|---|
| access 算 solid 吗？ | **不算**。`access_ids` 不参与 solidity | 会员必须能站上去用器械；access 若 solid 则逻辑自相矛盾 |
| 两台器械 access 能重叠吗？ | **允许**，数据层完全不阻止 | 支柱2：不允许会导致"分开能放、放一起被拒"——拖拽被弹回是**操作层挫败**，而非"错过机会"的**观察层后果** |
| access 能压在不可建造格上吗？ | **不能，`can_place` 拒绝** | 墙/柱是**不可恢复**的几何硬约束，与"被别的器械挤住"（挪走即恢复）性质不同。允许放下但永远用不了 → 玩家费解，反而违反"沉默可信度" |
| access 被别的器械 footprint 压住？ | **允许放置，不阻塞**。器械进入运行时"访问受阻"状态 | 这正是"摆太挤→能放但没人用"的字面场景，是"再挪一下试试"的源头 |

> **分工原则**：GridSystem 只负责"数据对不对"（这格是否是这台器械的使用位 —— **静态归属事实**），**不负责"好不好用"**（此刻是否有会员能走到、是否有人正站着 —— **动态运行时语义**）。可用性判定完全下放 Navigation + MemberSim。

> **📋 `access` 重叠无上限 —— 已知的复杂度尾巴**：本规则允许任意多台器械的 access 共享同一格，**不设上限**。这让 `clear()` 的复杂度严格说是 **O(footprint + Σ_access k)**，其中 `k` = 该 access 格上的 id 数（从 `access_ids: Array[int]` 移除一个 id 需 O(k) 线性扫描 + 移位），**而非规则7 所说的 O(footprint + access 格数)**。
>
> **MVP 内非议题**（5–6 件器械 → k 恒为个位数），但**规则7 的复杂度声明应理解为"k 期望极小"下的简化**。若未来某个布局让大量器械 access 汇聚到同一格（长走廊共享通道），`k` 会随器械总数增长。**触发复审的信号**：单格 `access_ids` 长度经常 > 10。届时可考虑 `Dictionary` 代替 `Array` 做每格 id 集合 —— 但**不要现在做**：`Array` 在 k 极小时比 `Dictionary` 快，且当前设计的可读性收益远大于一个不存在的性能问题。

#### 6. `can_place` 判定序列

给定 `equipment_def`、`anchor_cell`、`rotation`：

1. 按规则 4 计算 `footprint_cells_transformed`、`access_cells_transformed`
2. 对每个 footprint 格 `fc`：
   a. 在包围盒内 → 否则 `FAIL: OUT_OF_BOUNDS`
   b. `buildable == true` → 否则 `FAIL: BLOCKED_BY_ROOM_GEOMETRY`
   c. `occupant_id == -1` → 否则 `FAIL: OVERLAPS_EXISTING_EQUIPMENT`
3. 对每个 access 格 `ac`：
   a. 在包围盒内 → 否则 `FAIL: ACCESS_OUT_OF_BOUNDS`
   b. `buildable == true` → 否则 `FAIL: ACCESS_BLOCKED_BY_ROOM_GEOMETRY`
   c. **不检查** `occupant_id` / `access_ids` —— 允许压在别的器械 footprint 或 access 上
4. 全过 → `{valid: true}`

> GridSystem **不产出 access 冲突警告**。"两台器械互相挡住使用位"的后果只在运行时由 Congestion/Overlay 可视化呈现，放置瞬间不打断心流（支柱2）。

#### 7. commit / clear

- `commit(instance_id, footprint_cells, access_cells)`：footprint 格 `occupant_id = instance_id`；access 格 `access_ids.append(instance_id)`；写入 `instance_id → PlacementRecord{footprint_cells, access_cells, rotation}` **反向索引**；发 `grid_changed`
- `clear(instance_id)`：查反向索引取占用格；footprint 格 `occupant_id = -1`；从各 `access_ids` 移除该 id；发 `grid_changed`
- **反向索引是契约的一部分，不可省** —— 没有它 `clear()` 退化为全网格扫描

#### 🔴 `instance_id` 生命周期契约（跨系统，必须显式点名）

GridSystem **不分配 `instance_id`，只消费它**。但它对这个 id 的取值有**硬契约**，因为整个下游都建立在这个契约上：

| 约束 | 规则 | 违反后果 |
|---|---|---|
| **归属** | 由**放置流程的调用方**（PlacementSystem / EquipmentInstance 注册表）分配，GridSystem 从不生成 | — |
| **取值域** | `>= 0` 的整数。**`-1` 是保留的"空"哨兵**，永不作为合法 id | 传 `-1` 会让该格在 `get_occupant_id()` 看来是空的 → 器械凭空消失且 `clear()` 再也清不掉 |
| **🔴 单调递增，会话内永不复用** | 分配器持有单调计数器；`clear()` **不把 id 归还池子** | 见下方 |
| **跨存档** | `serialize()` 原样写出 id；`deserialize()` 后分配器必须从 `max(已加载 id) + 1` 继续，**不得从 0 重启** | 新器械的 id 撞上已加载器械的 id → `commit` 被拒（走运）或索引冲突（不走运） |

> **🔴 为何"永不复用"是硬契约而不是建议**：SelectionSystem / Build UI / Info Panel 都自建 `id → EquipmentInstance` 映射（见"与其他系统的交互"一节）。如果分配器把已 `clear()` 的 id 回收再发给一台新器械，任何持有旧 id 的缓存（一个还开着的信息面板、一次未刷新的选中态）会**静默解析到完全不同的一台器械** —— 不报错、不崩溃、只是悄悄指错了人。
>
> 这正是 B 节点名的"**沉默的坏读取**"，而且是本 GDD 所有防御（越界检查、两阶段校验、互斥断言）**唯一漏掉的一类**：以上防御全都在问"这个数据合法吗"，而复用 id 的每一步**都是合法的**。唯一的防线是让这个状态**根本无法被构造出来** —— 即 id 永不复用。
>
> 单调递增计数器在 64 位 int 上的耗尽是非议题（每秒放置 100 万台器械需 ~29 万年）。**这条契约的成本是零，收益是消除一整类无法被测试捕获的 bug。**

**GridSystem 侧的防御**：`commit()` 收到 `instance_id < 0` → `push_error()` 并拒绝提交（见 E 节与 AC-C7.7）。**GridSystem 无法检测"复用"** —— 一个被 `clear()` 过的 id 再次 `commit` 在 GridSystem 看来与一个全新 id 完全无法区分。**这条契约只能由分配器保证，GridSystem 不做也做不到二次校验。** 交接给 PlacementSystem GDD（设计顺序 #4）。

> **🔴 交接 PlacementSystem GDD（#4）—— 三条具名要求，不是"参考一下"**（见 Open Question #10）：
>
> 1. **必须有且只有一个分配器实例。** 上表的"单调递增计数器"隐含假设了这一点却从未写明 —— **两个分配器各持一个计数器，各自都"单调递增、从不复用"，合起来却会发出重复的 id**，而这个状态在两个分配器各自看来**都完全合法**。这正是本 GDD 对自己施加 DI-only / 严禁 Autoload / 建议 CI grep `[autoload]` 的**同一个结构性风险**，理由也完全相同。**本 GDD 对自己严格、对下游宽松是一处不对称，此条即为补齐。** 分配器的唯一实例应由 `SimulationOrchestrator` 持有并注入，与 GridSystem 同规格。
> 2. **撤销/重做（undo/redo）与"永不复用"的交互必须被显式决策。** MVP 未规划 undo，但"再挪一下试试"是支柱1 的核心心理钩子，undo 是这个品类高度可预期的需求。届时的冲突是真实的：redo 一次"重新放下"应当**复用**原 id（则违反本契约，且任何跨 undo 持有旧 id 的缓存会指错器械），还是**分配新 id**（则任何跨 undo 持有引用的东西会失效）？**两条路都有代价，必须选一条并写下来** —— 不能等实现时顺手决定。
> 3. **`max(已加载 id) + 1` 的续号必须在每次 `deserialize()` 时重新应用，而非仅开机一次。** 同一会话内切换存档槽（读档 → 玩 → 读另一个档）时，若分配器只在启动时初始化过一次计数器，新档的 id 空间会与当前计数器错位 → 新放置的器械 id 撞上已加载器械的 id。**上表"跨存档"那一行的措辞（"`deserialize()` 后分配器必须从 `max(已加载 id)+1` 继续"）已经蕴含了这一点，但"每次"这个词必须显式写出来** —— 它正是那种读起来完全同意、实现时却只在 `_ready()` 里写了一遍的要求。

#### 8. 序列化契约（serialize / deserialize）

**序列化的是反向索引，不是原始数组。** `occupant_id` / `access_ids` 数组是反向索引的**派生缓存**，`deserialize()` 从反向索引重放重建它们。

> **为何不存数组**：这是唯一**结构上不可能失步**的方案 —— 存两份表示（数组 + 索引）意味着任何一次"只写了数组忘了写索引"的 bug 都会在存档里产生静默的、加载后才暴露的不一致。而只存数组也不行：**`rotation` 无法恢复** —— 它不存在于任何数组里，只存在于反向索引中。
>
> 附带收益：体积正比于**已放置器械数**，而非总格数。

**`buildable` 不进存档。** 它属于关卡/房间几何数据（规则1，加载时固定），由调用方在 `deserialize()` 之前独立加载并作为参数注入。这与 E 节"存档与关卡几何不匹配"边界情况一致：两者本就是两个独立来源，`deserialize()` 的职责之一就是**交叉校验它们是否吻合**。

```gdscript
func serialize() -> Dictionary:
    return {
        "schema_version": 1,
        "width": width,
        "height": height,
        "records": _records_sorted_by_instance_id()  # 见下方确定性说明
    }
    # 每条 record: { instance_id: int, footprint_cells: Array[Vector2i],
    #                access_cells: Array[Vector2i], rotation: int }

func deserialize(data: Dictionary, buildable_snapshot: PackedByteArray) -> DeserializeResult:
    # ── 阶段一：全量校验（不写入任何东西）────────────────────────
    # 1. 校验 data.width/height 与当前关卡一致，否则 FAIL: LEVEL_GEOMETRY_MISMATCH
    # 2. 载入 buildable_snapshot（调用方独立提供，非本序列化输出的一部分）
    # 3. 对每条 record 的【每个 footprint 格 与 每个 access 格】：
    #      a. 校验坐标在 [0,width) × [0,height) 内
    #         否则 FAIL: CORRUPTED_SAVE_OUT_OF_BOUNDS
    #         🔴 必须在写入前拦截 —— 绝不能让越界坐标进入写入循环（PackedArray 越界写）
    #      b. 校验 buildable == true，否则 FAIL: LEVEL_GEOMETRY_MISMATCH
    #         🔴 footprint 与 access 都要查 —— 与 can_place（规则6 步骤 2b/3b）保持一致
    # 4. 校验各 record 的 footprint 格两两不重叠，否则 FAIL: CORRUPTED_SAVE_OVERLAP
    #    （access 格允许重叠，与规则5 一致）
    # 5. 【任何一条校验失败 → 立即返回，此时尚未写入任何东西 → 天然满足"不做部分恢复"】
    #
    # ── 阶段二：写入（此时所有 record 已确证合法）──────────────────
    # 6. 清空 occupant_id / access_ids / 反向索引
    # 7. 对每条 record：
    #      直接写 occupant_id[cell] = instance_id
    #        （绕过 can_place —— 反序列化没有 equipment_def 可用，也不需要重新判定合法性，
    #          只需重建已在阶段一确证的状态）
    #      直接写 access_ids[cell].append(instance_id)
    #      写入反向索引
    # 8. 发一次 grid_changed(全部 footprint_cells, 全部 access_cells)
    #    不是逐条 record 发信号（加载阶段没有订阅者关心"第几条记录"这种粒度）
    # 9. 返回 DeserializeResult{ success: true, errors: [] }
```

> **🔴 校验必须在写入之前全部完成（两阶段结构）。** 这不是风格偏好 —— 它同时解决三个问题：
> 1. **`CORRUPTED_SAVE_OUT_OF_BOUNDS` 必须在写入前拦截**，否则越界坐标直接进入写入循环 → `PackedArray` 越界写。这正是 D.2 越界契约最想防的事。
> 2. **"不做部分恢复"变成结构性保证，而非需要手写回滚的纪律** —— 阶段一失败时根本还没动过任何格子，无需回滚逻辑。
> 3. **access 格必须与 footprint 格同样校验 `buildable`**。规则5 明确规定"access 压在墙上 → `can_place` 拒绝"；若 `deserialize()` 不查 access，它就能造出一个**通过正常放置流程永远不可能存在**的状态 —— 一个使用位悄悄埋在墙里的场馆。这比空场馆更隐蔽、更危险："看起来完全正确"恰恰是 B 节"沉默可信度"最忌讳的失败模式。

**确定性写出**：`records` 数组按 `instance_id` **升序排序**后再写出，不依赖反向索引内部 `Dictionary` 的迭代顺序 —— 零成本的防御性写法。

**版本化**：MVP **不做**迁移逻辑，但现在就加 `schema_version: 1` 字段（零成本）。MVP 只有一个固定房间，不存在"旧存档 + 已变化的关卡版本"的兼容问题；Vertical Slice 引入扩建/多房间时字段已经在，届时只需加分支，不需要改格式。

> **🔴 不做部分恢复**：任何一条 record 失败 → 整个 `deserialize()` 失败。**半个正确的场馆比空场馆更危险** —— 玩家会以为这就是他们留下的样子。这直接服务于 B 节的"沉默可信度"。

**📋 已承认的取舍（accepted risk）：全失败策略的反向失败模式**

上面这条规则只论证了它防住的那一侧。为免未来读者以为这一侧是**唯一**一侧，这里显式写出它**没有**防住的那侧：

| | 失败模式 | 玩家体验 |
|---|---|---|
| **本设计防住的** | 加载出一个"看起来对、其实错"的场馆 | 玩家在错误的空间真相上继续经营，永远不知道 —— **静默的错** |
| **本设计接受的** | 一条 record 损坏 → **整个布局丢失**，无任何挽救路径 | 玩家几十小时的成果因为一个 bit 翻转而归零 —— **响亮的错** |

**决策：接受后者，维持全失败。** 理由：**在"沉默可信度"这个框架下，响亮的错严格优于静默的错。** 一个诚实报错的存档，玩家知道发生了什么、可以去找备份、可以报 bug；一个静默错误的场馆，玩家的每一个后续决策都建立在谎言上，且**永远不会发现**。这与 D.2 越界契约选择 `push_error` 而非静默返回、与 AC-D1.1 拒绝静默回退 0°，是**同一个原则的第三次应用**。

**但这个取舍是有前提的，前提失效则须重新决策**：

- **前提**：MVP 单房间、5–6 件器械 → `records` 数量在**个位数到十位数**。此规模下"整份存档因一条 record 报废"的概率与影响都极低。
- **🔴 复审触发条件**：当单份存档的 `records` 数**预期超过 ~200**（Vertical Slice 的多房间/扩建，或 Tier 2 的连锁），本决策**必须**重新评估。届时"一个 bit 毁掉一切"的期望损失显著上升，应考虑：每条 record 独立校验和 + 隔离损坏记录 + 明确告知玩家"N 台器械因存档损坏未能恢复"（**注意：这仍然不是静默部分恢复 —— 关键区别是"告知"**）。
- **不在 MVP 做的理由**：为一个当前规模下概率极低的问题引入分级恢复逻辑，会让本节最有价值的性质（**两阶段结构 = 结构性保证，无需回滚代码**）退化成需要手写、需要测试、需要维护的纪律。**先简单且正确，等规模真的到了再复杂。**

> **交接 SaveLoad GDD（设计顺序 #14）**：本决策的复审触发条件（records > ~200）应记入 SaveLoad 的风险表。GridSystem 只负责自己这一份 record 集合的全有全无语义，**跨系统的存档损坏策略归 SaveLoad**。

### States and Transitions

**GridSystem 没有行为状态机，这是刻意的。** cell 没有生命周期顺序，只有两个正交维度（`buildable` 近乎静态、`occupancy` 是空/占布尔翻转），没有需要 GridSystem 感知的中间过渡态。"拖拽预览中"是 UI 态，通过**推测性快照**（只读副本）处理，从不触碰真实存储 —— 也不存在"部分放置""待确认"的持久状态（与支柱2 一致）。

因此本节给出**合法值域表**而非转换表：

| buildable | occupant_id | access_ids | 含义 | 合法？ |
|---|---|---|---|---|
| false | -1 | [] | 墙/柱/门/窗 | ✅ 常态 |
| false | ≠-1 | any | 器械压在不可建造格上 | ❌ `can_place` 必须永远阻止 |
| true | -1 | [] | 空地 | ✅ |
| true | ≠-1 | [] | 被 footprint 占用，无 access 经过 | ✅ |
| true | -1 | [id,...] | 空地但被 1+ 个 access 覆盖 | ✅ 使用位核心场景 |
| true | ≠-1 | [id,...] | 被 footprint 占用，同时是别的器械的 access | ✅ **access_blocked 场景，运行时降级可用性，非数据错误** |

**操作契约**：

| 操作 | 前置条件 | 后置效果 |
|---|---|---|
| `commit(id, footprint, access)` | `can_place==true` 且 `id` 未被占用 | 见 Core Rule 7；发 `grid_changed` |
| `clear(id)` | `id` 存在于反向索引 | 见 Core Rule 7；发 `grid_changed` |
| `set_buildable(cell, bool)` | **MVP：仅关卡加载阶段可调，不在玩法循环中暴露** | 更新 `buildable`。若导致某 occupant footprint 落在新墙上，属加载时数据错误，应在加载校验阶段报错，不得运行时静默处理 |

### Interactions with Other Systems

**GridSystem 是 `extends RefCounted` 的纯 GDScript 类** —— 不是 Node，不是 Autoload 单例，不是 Resource。由 `SimulationOrchestrator` 持有唯一实例，通过构造函数/setter **注入**给各消费者；消费者不得用 `get_node()` 或全局单例"够"它。

> 依据：项目编码标准要求"DI 优于单例""public 方法必须可单元测试"。且 4.7.1 实测确认 `AStarGrid2D` 本身就是 `RefCounted`（`is Resource` 直接编译报错）—— GridSystem 沿用同样的设计哲学。
>
> **GridSystem 完全不知道 `TileMapLayer` 存在。** 两者之间隔一个表现层适配器（`GridVisualizer` Node 或等价物）订阅 `grid_changed` 再操作 `TileMapLayer`。这让 GridSystem 可脱离场景树被单测覆盖（`godot --headless`）。

#### 生命周期与持有契约

`RefCounted` 意味着 GridSystem 的存活由**引用计数**决定，而非场景树。它不在树里 → **没有 `tree_exited`、没有 `queue_free()`、没有任何引擎级的"我要没了"信号**。因此持有关系必须靠契约约束，而非靠引擎兜底：

| 角色 | 允许持有 | 说明 |
|---|---|---|
| `SimulationOrchestrator` | **唯一的长生命周期强引用**（owner） | 它的生命周期定义了 GridSystem 的生命周期 |
| 各模拟系统（Navigation / MemberSim / ZoneRules / Placement） | 注入的强引用，**生命周期不得长于 Orchestrator** | 它们本就由 Orchestrator 同期创建/销毁 |
| **UI / 表现层**（面板、Overlay、Visualizer） | **🔴 不得跨关卡缓存强引用** | 见下 |

> **🔴 换关卡 / 重开档时的风险**：当 Orchestrator 丢弃旧 GridSystem、构造新实例时，任何**仍持有旧引用**的对象（一个还开着的器械信息面板、一个 `@onready` 缓存了引用的 UI 节点）会让旧实例**因引用计数不归零而继续存活**。它不会崩溃、不会报错 —— 它会**继续老老实实地回答关于上一个关卡的问题**。这是"沉默的坏读取"在生命周期维度的版本，且没有任何引擎机制会提示你。
>
> **契约**：表现层/UI **每次使用时从 Orchestrator 取当前实例**，不缓存；或持有 `WeakRef`。**严禁** `@onready var grid := ...` 这种"取一次用一辈子"的写法。
>
> **MVP 内此条为纯文档性**（单房间、无关卡切换、无重开档流程），但**必须现在写**：Vertical Slice 引入"扩建/多房间"时，这条从纯文档性变成实际约束，而届时相关 UI 代码早已写完。交接架构阶段决定是否需要更硬的机制（如 generation-id：GridSystem 持有一个自增代号，消费者断言自己拿到的代号与 Orchestrator 当前代号一致）。

> **⚠️ DI 约束目前只有编码标准背书，没有机器强制。** 没有任何机制阻止未来某人加一个 Autoload 单例包住 GridSystem（那会同时摧毁可测试性与上面的生命周期契约）。**建议架构阶段加一条 CI 检查**：grep `project.godot` 的 `[autoload]` 段，断言其中不含 GridSystem。零成本，防的是一类几乎必然会在某个赶工的下午发生的事。

| 消费者 | 方向 | 接口 | 说明 |
|---|---|---|---|
| **PlacementSystem** | 写 | `can_place(def, anchor, rot) -> PlacementCheckResult`<br>`commit(id, def, anchor, rot) -> void`<br>`clear(id) -> void`<br>`get_transformed_cells(def, anchor, rot) -> TransformedFootprint`（纯函数，供预览高亮） | GridSystem 提供纯函数计算 + 合法性检查；Placement 自行决定何时 `commit`（松手确认时）。GridSystem 从不感知"正在拖拽" |
| **Navigation** | 读 | `is_solid(cell) -> bool`<br>`get_solidity_snapshot() -> PackedByteArray`<br>订阅 `grid_changed` | `is_solid(cell) = !buildable OR occupant_id != -1`（**access_ids 不参与**）。只用 `footprint_cells_changed` 做局部 `set_point_solid()` |
| **MemberSim** | 读 | `get_access_cells(instance_id) -> Array[Vector2i]`<br>`get_occupant_id(cell) -> int` | 见下方"静态归属 vs 动态占用" |
| **ZoneRules** | 读快照 | `get_snapshot() -> GridSnapshot`<br>`get_speculative_snapshot(deltas) -> GridSnapshot`<br>`evaluate(snapshot: GridStateReader)` | `evaluate()` 形参是**抽象基类**，故全程不知道快照是真是假 |
| **SelectionSystem** | 读 | `get_occupant_id(cell) -> int` | 自己维护 `id → EquipmentInstance` 映射；GridSystem 只认整数 |

#### 🔴 静态归属 vs 动态占用（必须显式点名）

`access_ids` 是"**这格是谁的使用位**"—— 静态归属事实。
"**此刻谁站在这个 access cell 上**"是动态运行时事实，由 MemberSim/Congestion 自建独立表管理，**绝不写回 GridSystem**。

混淆两层会污染快照语义：快照本应是"布局"的快照，若随会员走动每 tick 变化，ZoneRules 的静态评估就被会员位置污染了。

#### 快照语义

**深拷贝，非 COW。** 实测支撑：3600 格 `PackedInt32Array.duplicate()` = 0.04μs；`Dictionary`(access_ids) 3600 条目 = 141.71μs，按 MVP ~300 格比例约 12μs —— 仅占 16.6ms 帧预算的 **0.07%**，每帧拖放预览也不掉帧。

> **⚠️ 上面这段数字有两个已知的"测错形状"问题，引用时必须知道**（详见 H.17 与 Open Question #7）：
>
> 1. **`Dictionary` 那个数字很可能测的是稠密字典，而稀疏才是本设计的前提。** 选 `Dictionary` 存 `access_ids` 的**全部理由**就是"大多数格为空"（规则2）。但 141.71μs 测的是 **3600 个条目**的字典（几乎必然是配合 3600 格 `PackedInt32Array` 一起跑的稠密填充），再按格数**线性缩放**到 ~12μs。稀疏字典（130 格里填 10–20 条）与"稠密字典按比例缩小"是**两种不同的哈希分布与桶结构**，`Dictionary` 不保证这种线性。**这个数字的量级大概率是对的（且极可能高估，即偏保守），但它不是对生产数据形状的测量。**
> 2. **"0.07% 帧预算"是单次调用的成本，不是拖拽工况的成本。** 一次拖拽会**连续上百帧**每帧调 `get_speculative_snapshot()`，且真实路径不止 `duplicate()` —— 还有 N 次 `_commit_in_place` 的数组写、反向索引字典写、`access_ids` append。持续数秒的"每帧构造再丢弃整个快照对象"是一种**分配器压力模式**，单次微基准**在原理上无法**反映它（碎片化、分配开销方差）。
>
> **结论不变**（130 格规模下仍有约 3 个数量级的余量，深拷贝是对的选择），**但 H.17 的验证要求据此加严** —— 见 AC-PERF.3 的拖拽工况冒烟测试。

> *实现层可选优化（不写入契约）*：GDScript 的 `Packed*Array` 赋值自带 COW 语义，纯只读消费者（如 `ZoneRules.evaluate`）理论上可跳过显式 `.duplicate()`。但 GDD 契约按显式深拷贝写 —— 更不易被误用，且收益（0.04μs）不值得引入"这个快照能不能写"的心智负担。

#### `GridStateReader` —— 共享只读契约

`GridSystem`（真实存储）与 `GridSnapshot`（副本）**共享一个只读抽象基类**，写操作各自私有：

```gdscript
# 只读契约 —— GridSystem 与 GridSnapshot 都实现它
class_name GridStateReader extends RefCounted

@abstract func is_solid(cell: Vector2i) -> bool
@abstract func get_occupant_id(cell: Vector2i) -> int
@abstract func get_access_cells(instance_id: int) -> Array[Vector2i]
@abstract func get_dimensions() -> Vector2i   # (width, height)
```

- `GridSystem extends GridStateReader` + 私有的 `commit` / `clear` / `serialize` / `deserialize`
- `GridSnapshot extends GridStateReader` + 私有的 `_commit_in_place` / `_clear_in_place`
- **`ZoneRules.evaluate(snapshot: GridStateReader)` 的形参类型是抽象基类，不是具体的 `GridSnapshot`** —— 这样 `evaluate()` 天然不知道也不关心自己拿到的是真快照还是推测快照，两者对它而言是同一个类型。

> **为何是"共享只读基类 + 各自私有写方法"，而不是二选一**：若完全共用一个类（写方法也放基类），ZoneRules 就能拿到 `commit`/`clear`，违反其纯函数定位；若完全独立（两套无关的读接口），`get_speculative_snapshot()` 里"先拿真快照、再叠加假设"就没法对两种情况写同一套调用逻辑。这是唯一同时满足两个约束的结构。

> **⚠️ `@abstract` 是 Godot 4.5 新增**（见 `docs/engine-reference/godot/breaking-changes.md` 的 4.4→4.5 表）。**本项目尚未在本地 4.7.1 实测验证过它** —— 引擎参考文档记载它可用，风险低，但架构阶段必须验证一次（Open Question #3）。
>
> **🔴 但"退化为命名约定 + 代码审查"不是一个合格的兜底 —— 兜底必须有地板。** 本设计**依赖**"调用一个未被覆写的抽象方法是不可能的"这一保证：`ZoneRules.evaluate(snapshot: GridStateReader)` 只有在这个前提下才安全。若 `@abstract` 不可用，`GridStateReader` 就退化成一个**普通基类** —— 未来某次重构/合并冲突让 `GridSystem` 或 `GridSnapshot` 漏覆写一个方法时，GDScript 会**老老实实调用基类实现**。而本节的基类声明里**根本没有方法体**，结果要么静默返回默认值，要么在离真正 bug 很远的调用点抛错。**这正是 B 节称为唯一失败模式的"静默的错"。**
>
> **验证与兜底协议（架构阶段执行）**：
> 1. 跑 headless 复现：写一个故意漏覆写某方法的子类，调用它，**记录确切行为**（编译期报错 / 运行时报错 / 静默通过）到 D.7 的引擎交接点一节。
> 2. **若是硬报错**（编译期或运行时）→ `@abstract` 按本节原样使用，无需额外措施。
> 3. **若不是硬报错** → `GridStateReader` 的每个方法**必须**带 `push_error()` + 安全默认值的实体桩，**不得**只留裸声明：
>    ```gdscript
>    func is_solid(cell: Vector2i) -> bool:
>        push_error("GridStateReader.is_solid 未被子类覆写")
>        return true   # 安全默认：同 D.2 越界契约，"不确定就算实心"
>    ```
>    这样即便约定被破坏，失败也是**响亮的**（`push_error` + 保守值），而不是静默的。
>
> **决策原则**：软兜底（命名约定 + 代码审查）可以接受，但它必须**站在一个硬地板上**。地板就是"漏覆写一定会响"。

#### 推测性快照构造

```gdscript
func get_speculative_snapshot(deltas: Array[PlacementDelta]) -> GridSnapshot:
    var snap := get_snapshot()  # 深拷贝真实状态
    for delta in deltas:
        if delta.is_removal:
            snap._clear_in_place(delta.instance_id)
        else:
            snap._commit_in_place(delta.instance_id, delta.footprint_cells, delta.access_cells)
    return snap
```

只操作**副本**：不触碰真实存储、不发 `grid_changed`、不经过公开 `commit()` 路径。

> **🔴 关于误用防护的诚实边界**：`_commit_in_place` / `_clear_in_place` 的下划线前缀是**约定，不是运行时强制** —— GDScript 没有真正的访问控制。防护是两层"软"叠加：
> 1. **命名约定**（`_` 前缀）—— 代码审查能抓到误用
> 2. **类型收窄** —— 所有对外暴露快照的路径一律把形参声明为 `GridStateReader`，持有该类型引用的调用方在类型契约里根本看不到 `_commit_in_place`
>
> **这是 GDScript 语言能力内能做到的最强防护，不是密封保证。** 强转仍可绕过。如果未来发现有人绕过类型系统直接拿具体类调用 `_commit_in_place`，那是代码审查该抓的问题 —— 把这个边界写清楚，比假装"设计上不可能被误用"更诚实。

**为什么不产生循环依赖**：调用链单向 `Placement → GridSystem(纯函数) → 快照值 → ZoneRules(纯函数)`，无一环反向持有引用或订阅信号。

#### 信号设计

```gdscript
signal grid_changed(footprint_cells_changed: Array[Vector2i], access_cells_changed: Array[Vector2i])
```

拆两个数组的理由：Navigation 只关心 `footprint_cells_changed`（solidity 真正变化），可**完全忽略** `access_cells_changed`，避免无意义重烘焙/路径抖动；ZoneRules/Congestion 两者都关心。

**payload 语义 = "这些格子的状态变了，去重查"，不区分方向。** 两个字段描述的是"这次操作后，这些格子的 solidity / access 归属状态发生了变化"，**不区分是 `commit`（新占用/新归属）还是 `clear`（释放/移除归属）**。消费者收到信号后应重新查询这些格子的**当前值**（`is_solid()` / `get_occupant_id()` / `get_access_cells()`），而不是从字段名猜测变化方向。

> 这让 Navigation / ZoneRules 处理 commit 与 clear 的逻辑完全一致，不需要分支 —— **"变化了，重查"是唯一契约**。

> **对消费者的期望：增量消费，不要全量重建。** payload 精确携带了"哪些格变了"，**就是为了让消费者只更新这些格**。Navigation 的增量路径（只对 `footprint_cells_changed` 调 `set_point_solid()`）已在下文写明；这里把同样的期望**显式扩展到所有消费者**，尤其是表现层适配器（`GridVisualizer`）：
>
> - ✅ 期望：收到信号 → 只重画 payload 里的那几格
> - ❌ 反模式：收到信号 → `TileMapLayer.clear()` + 全房间重画
>
> **这不违反"本 GDD 不管视觉"的边界** —— 它不规定画成什么样，只说明**信号契约的意图**。payload 拆成两个精确数组是有成本的设计选择（相比一个简单的"变了"无参信号），若消费者一律全量重建，这个成本就白付了。**这是一条 advisory，不是 AC** —— GridSystem 无法也不该强制消费者怎么用它的信号。

> **🔴 `grid_changed` 只在真正落子提交时发一次，绝不在拖放预览的每帧发。** 预览走推测快照路径，不触碰真实 occupancy。实现时严禁把 `grid_changed` 塞进 `_process` 的拖放循环。按此设计信号频率是"每次放置动作一次"，开销非议题。

#### 4.7.1 引擎交接点

> 以下结论由 `godot-specialist` 在本地 `godot 4.7.1.stable.official` 上跑 headless 脚本**实测**得出，非训练数据回忆。

- ✅ **`set_point_solid()` 立即生效，无需调 `update()`** —— `is_dirty()` 压根不追踪 solidity 变化。单次 ≈ 0.14μs。Navigation 的增量重烘焙路径成立且极便宜。
- 🔴 **`update()` 只管结构性变更**（`region`/`size`/`offset`/`cell_size`/`cell_shape`），且是全量重建（400×400 ≈ 1815μs）。
- 🔴 **改 `region` 会清空所有已设 solid 标记**（实测：格 (3,3) 设 solid → 扩 region → `update()` → 变回 false）。故增量路径**仅在包围盒不变时成立**。房间改形必须从 occupancy 真相源全量重灌 —— 应走独立的 `grid_resized(new_region)` 事件，**不得混进 `grid_changed`**。
  > **MVP 内此条为纯文档性**：`buildable` 加载时固定、运行时只读 → region 永不变。为 Vertical Slice 的"扩建房间"铺路。
- ⚠️ **确定性实测通过 —— 但只覆盖了"相同顺序"这一半**：实测结论是"两个独立构造、**相同操作顺序**的 `AStarGrid2D` 实例返回完全相同路径"。**这不等于顺序无关性。**
  > **🔴 本项目实际需要的是后者**：`deserialize()` 按 `instance_id` **升序**重放 occupancy（C 节规则8"确定性写出"），而这个顺序**与玩家当初的放置顺序无关**。也就是说，读档后的 `AStarGrid2D` 与存档前的那个，其 `set_point_solid()` **调用顺序几乎必然不同** —— 只有当"最终 solid 状态相同 ⇒ 路径相同"（即顺序无关）成立时，读档才不会改变小人的走法。
  >
  > **此性质见 Open Question #6，标记为 MEDIUM 风险、推断但未直接实测**。原理上（扁平布尔数组按索引写入）应与顺序无关，且本 GDD 选用 `PackedInt32Array`/`PackedByteArray` 按索引写 occupancy 基本消除了该风险 —— **但"基本消除"不是"已验证"**。
  >
  > **不要把这一行的实测结论误读成覆盖了 OQ#6。** 架构阶段应补一次实测：两个实例，相同最终 solid 集合、**不同设置顺序**，断言路径相同。
- ✅ **`AStarGrid2D` 本身不参与序列化**：反序列化时重建新实例并重放 occupancy 即可（此结论不依赖上面那条的顺序无关性 —— 它只依赖"`AStarGrid2D` 是 `RefCounted`、其状态完全由 occupancy 决定"，已实测确认）。
- ⚠️ **交接 Navigation GDD**：`diagonal_mode` 默认 `ALWAYS`，实测会让小人从两个 solid 对角格的缝隙**斜穿过去**（"穿墙角"）。`ONLY_IF_NO_OBSTACLES` 实测能正确阻止。**此决策归 Navigation GDD（系统 #5），本 GDD 仅记录实测发现。** `jumping_enabled` 默认 false，开启后路径点从 10 降到 2（纯搜索优化，不影响正确性）—— 同归 Navigation。

## Formulas

> **关于本节的范围**：GridSystem 真正的"公式"很少 —— 大部分复杂度在 C 节已作为**规则**处理。本节收录 5 条够格的公式（有输入输出、可验证、被下游系统直接消费）。宁可 5 条扎实的，不凑数注水。
>
> **MVP 房间尺寸不是公式**，是参数，见 D.6（不计入公式编号）。

### D.1 旋转变换 `rotation_transform`

**诚实地写成 4 个分支，不硬塞成一条封闭式** —— 整数网格上"长宽互换"本质是分段的；伪装成连续公式（如复数旋转）反而会掩盖 90°/270° 与 0°/180° 输出值域不同这一事实。

```
R_rotation(x, y; W, H) =
  (x, y)              if rotation = 0
  (H-1-y, x)          if rotation = 90
  (W-1-x, H-1-y)      if rotation = 180
  (y, W-1-x)          if rotation = 270
```

**Variables:**

| Variable | Symbol | Type | Range | Description |
|---|---|---|---|---|
| 输入列偏移 | `x` | int | `0..W-1` | canonical(0°) 下相对声明包围盒左上角的列偏移 |
| 输入行偏移 | `y` | int | `0..H-1` | canonical(0°) 下相对声明包围盒左上角的行偏移 |
| 声明包围盒宽 | `W` | int | `>= 1` | `footprint_cells ∪ access_cells` 并集包围盒宽度（见 D.5） |
| 声明包围盒高 | `H` | int | `>= 1` | 同上，高度 |
| 旋转角度 | `rotation` | int（枚举） | `{0, 90, 180, 270}` | 顺时针旋转角度 |
| 输出列偏移 | `x'` | int | 0°/180°: `0..W-1`；90°/270°: `0..H-1` | 旋转后列偏移 |
| 输出行偏移 | `y'` | int | 0°/180°: `0..H-1`；90°/270°: `0..W-1` | 旋转后行偏移 |

**Output Range:** 结果分量恒落在合法包围盒内（90°/270° 时 W/H 对调），**不会产生负值或越界值，无需 clamp** —— 这正是选用此形式（而非各自局部包围盒旋转）的原因。

**Example:** 深蹲架，`footprint_cells=[(0,0)]`，`access_cells=[(0,1)]`（正面 1 格通道）。并集包围盒 `W=1, H=2`。

| rotation | footprint | access | new_size |
|---|---|---|---|
| 0° | `(0,0)` | `(0,1)` | `(1,2)` |
| 90° | `(1,0)` | `(0,0)` | `(2,1)` |
| 180° | `(0,1)` | `(0,0)` | `(1,2)` |
| 270° | `(0,0)` | `(1,0)` | `(2,1)` |

> 本例与 C 节的 1×2 跑步机例子互为交叉验证，两者一起构成建议的单元测试 fixture 集合。

### D.2 扁平索引 `flat_index`

`idx = row * width + col`

**Variables:**

| Variable | Symbol | Type | Range | Description |
|---|---|---|---|---|
| 列坐标 | `col` | int | `0..width-1` | 格子列坐标 |
| 行坐标 | `row` | int | `0..height-1` | 格子行坐标 |
| 网格宽 | `width` | int | 见 D.6 | 房间包围盒宽度，加载时固定 |
| 扁平索引 | `idx` | int | `0..(width*height-1)` | `PackedInt32Array`/`PackedByteArray` 的索引 |

**Output Range:** `[0, width*height-1]`，由构造保证 —— **前提是 `col`/`row` 本身在界内**。

**🔴 越界行为（必须显式规定）**：若调用方传入 `col<0`、`col>=width`、`row<0` 或 `row>=height`，GridSystem 的所有公开查询函数（`is_solid`、`get_occupant_id` 等）**必须先做边界检查**，禁止把非法 `idx` 直接喂给 `PackedArray` —— 那会导致引擎级越界崩溃，或更危险地**静默读到相邻行的数据**（这类"沉默的坏读取"正是 Player Fantasy 一节最忌讳的失败模式）。

契约：内部先过 `_in_bounds(col, row) -> bool`；越界立即 `push_error()` 并返回安全默认值；**`is_solid` 越界默认返回 `true`**（"墙外都算实心"，防止 `AStarGrid2D` 意外向界外寻路）。

**Example:** `width=13`，`col=5, row=3` → `idx = 3*13+5 = 44`。

### D.3 `is_solid(cell)`

`is_solid(cell) = NOT buildable(cell) OR occupant_id(cell) != -1`

**Variables:**

| Variable | Symbol | Type | Range | Description |
|---|---|---|---|---|
| 可建造标记 | `buildable` | bool | `{true, false}` | 该格是否为可建造地面（C 节规则1，静态） |
| 占用者 id | `occupant_id` | int | `{-1} ∪ [0, INT_MAX)` | 该格 footprint 占用者实例 id，`-1`=空（C 节规则2） |
| solid 判定 | `is_solid` | bool | `{true, false}` | 该格对 `AStarGrid2D` 是否不可通行 |

**Output Range:** 布尔值 —— 但**输出的排除项本身就是这条公式存在的理由**：`access_ids` **刻意不参与判定**。

> **为何单列成公式而非散在文字规则里**：这是 Navigation 消费的**唯一**契约（`AStarGrid2D.set_point_solid(cell, is_solid(cell))`）。若不把"排除 `access_ids`"钉死成公式，实现者极容易顺手把它纳入判断（字面上"这格有东西"），后果是**会员再也走不到任何使用位** —— 这是 C 节最高危规则的姊妹版本。
>
> **同时它是"两会员抢占同一 access cell"问题的第一道防线**：本公式必须保持"access 不算 solid"。运行时互斥留给 E 节解决，**严禁靠让 access 变 solid 来"顺便"解决** —— 那会把机会型冲突（可能没人排队）退化成**永久死锁**（谁都走不进去）。

**Example:**
- `buildable=true, occupant_id=-1`（空使用位格）→ `is_solid=false`（人能站上去）
- `buildable=true, occupant_id=7`（被 footprint 占）→ `is_solid=true`
- `buildable=false`（墙）→ `is_solid=true`，无论 `occupant_id`

### D.4 `grid_to_world` / `world_to_grid`

```
world_to_grid(world_pos)   = floor(world_pos / cell_size)
grid_to_world_corner(cell) = cell * cell_size
grid_to_world_center(cell) = cell * cell_size + cell_size / 2
```

**Variables:**

| Variable | Symbol | Type | Range | Description |
|---|---|---|---|---|
| 世界坐标 | `world_pos` | Vector2 (px) | 房间包围盒对应的连续区间 | 引擎世界空间坐标 |
| 格坐标 | `cell` | Vector2i | `(0..width-1, 0..height-1)` | 见 D.2 |
| 单格边长 | `cell_size` | int (px) | **⚠️ 交接点 —— 本 GDD 不定，待架构阶段确定**；候选 16 或 32 | 正方形格边长（已确认 `CELL_SHAPE_SQUARE`，故为单一标量而非宽高分开） |

**Output Range:** `world_to_grid` 输出 `Vector2i`，理论范围 `[0,width-1]×[0,height-1]`（`world_pos` 落在包围盒内时）。`grid_to_world_*` 输出连续 `Vector2`，范围 `[0, width*cell_size] × [0, height*cell_size]`。

**🔴 `world_to_grid` 的越界输出契约（与 D.2 不同，必须单独规定）**：

`world_to_grid` **如实返回数学结果，不 clamp、不报错、不返回哨兵** —— 界外输入产出界外格坐标（如 `world_to_grid((-10, -10))` 在 `cell_size=32` 时返回 `(-1, -1)`）。

> **为何这里的处理与 D.2 相反**（D.2 是 `push_error()` + 安全默认值）：**两者的输入可信度与用途完全不同。**
>
> - D.2 的 `is_solid`/`get_occupant_id` 是**查询**，它们的越界输入意味着**有人正要读一块不存在的内存** —— 必须响亮地拦下。
> - `world_to_grid` 是**换算**，且它的越界输入是**完全正常的**：玩家把鼠标拖出房间边缘每一帧都会产生界外 `world_pos`。若它对每次界外拖拽都 `push_error()`，日志会被刷爆，而这根本不是错误；若它 clamp 到边缘，调用方就**无法区分"贴着边"和"已经拖出去了"**，拖放预览会在房间外沿产生一个诡异的吸附假象 —— 一次教科书级的"咦？"。
>
> **🔴 因此契约的另一半是对调用方的**：`world_to_grid` 的输出**不保证在界内**，调用方**必须**在把它喂给 `flat_index` / `is_solid` / `can_place` 之前自行判界（或依赖后者自己的 D.2 拦截 —— 那会 `push_error()`）。**正常的拖拽预览应当在 `world_to_grid` 之后、查询之前就判断"鼠标在房间外" 并直接不显示预览，而不是让一个界外格一路走到 D.2 的错误日志里。**
>
> 这条**不是** D.2 契约的延伸，而是它的**对偶** —— 一并读才完整：D.2 管的是"非法坐标不许进存储"，本条管的是"界外坐标可以合法地被算出来，但不许被当成格坐标使用"。

**Example:**（`cell_size` 仅为演示占位值 32px，**不构成最终决定**）`cell=(5,3)` → `grid_to_world_corner = (160, 96)`px；`grid_to_world_center = (176, 112)`px。反向：`world_to_grid((170, 100)) = floor((170,100)/32) = (5, 3)`。

> **交接说明**：`cell_size` 不由本 GDD 决定 —— `design/art/art-bible.md` §8 原文已写"32×32 或 16×16 逻辑像素，在架构阶段最终确定"。本节只钉死公式形态，数值留给架构阶段。
>
> GridSystem 内部逻辑（occupancy / solidity / rotation）**完全不依赖 `cell_size` 的具体值** —— 这条公式是 GridSystem 唯一需要这个数字的地方，且只服务于"格坐标 ↔ 世界坐标"的表现层换算，不影响空间真相本身。

### D.5 声明包围盒推导 `declared_bounds`

```
W = max{x : (x,y) ∈ footprint_cells ∪ access_cells} + 1
H = max{y : (x,y) ∈ footprint_cells ∪ access_cells} + 1
```

**Variables:**

| Variable | Symbol | Type | Range | Description |
|---|---|---|---|---|
| footprint 格集合 | `footprint_cells` | Array[Vector2i] | 受 art-bible 约束：整体 footprint 只能是 `1×1`/`1×2`/`2×2` | canonical(0°) 器械占地格，来自 EquipmentCatalog |
| access 格集合 | `access_cells` | Array[Vector2i] | 固定 `N=1` 格（**已由 EquipmentCatalog GDD 确认**，见其 Core Rule 4 / registry `access_cell_count_max`） | canonical(0°) 使用位格，来自 EquipmentCatalog |
| 声明包围盒宽/高 | `W, H` | int | MVP 实际预期不超过 `3×3` | 供 D.1 旋转公式使用 |

**Output Range:** `W >= 1, H >= 1`。上界由 EquipmentCatalog 的 footprint 上限（`2×2`）与 access 扩展幅度共同决定 —— **本公式本身没有上界约束力，上界来自 EquipmentCatalog 的数据契约**。

> **⚠️ "MVP 实际预期不超过 `3×3`"是一个假设，不是一个被强制的约束 —— 且它承载的重量比它看起来的大。**
>
> 本公式对 `W,H` **没有任何上界约束力**：`footprint=[(0,0)]` 配一个远离的 `access_cells=[(5,5)]` 会算出 `W=6, H=6`，公式本身不会退化、不会报错，**它会老老实实地给出一个正确答案**。真正的门是 EquipmentCatalog 的数据契约。
>
> **✅ 更新（2026-07-17，`/consistency-check`）**：EquipmentCatalog GDD（设计顺序 #2）**已落地**（`design/gdd/equipment-catalog.md`），并把 access 数量上限正式确认为 **`N=1`**（其 Core Rule 4），同时用"footprint ≤ 2×2 + access 正交相邻"证明了并集包围盒**恒 ≤ 3×3**——不再是本 GDD 单方面的假设，而是有对偶证明支撑的结论。`/create-architecture` 阶段仍需核对**实现**是否忠实执行了 EquipmentCatalog 的加载期校验（Open Question #13），但"EquipmentCatalog 是否会做这件事"这一悬念已解除。
>
> **为何这不只是一个理论洁癖**：`~3×3` 这个数字并非只在本节出现 —— **D.6 的房间尺寸论证隐含地建立在它之上**（"MVP 房间 13×10 vs 器械上限 ~3×3，不会发生"，见 E 节"器械声明包围盒大于整个房间"一条），G 节的调参安全范围同理。

**前置校验规则（EquipmentCatalog 交接点）**：并集中必须存在 `x=0` 的元素与 `y=0` 的元素（即 `min_x=0, min_y=0`），否则说明该器械数据没有把 `(0,0)` 定义为并集包围盒左上角，违反 C 节规则3 的锚点约定。

> **此校验应由 EquipmentCatalog 在加载/编辑期做。** GridSystem 本身不存储 canonical 定义，只在拿到 `equipment_def` 时调用本公式 —— 校验失败不该拖到 GridSystem 这一层才发现。

**GridSystem 侧的防御性 assert（debug-only，release 零成本）**：`get_transformed_cells()` / `declared_bounds()` 在计算前对传入的 `equipment_def` 做 `assert`（而非 `if...push_error...return`）：

```gdscript
assert(_min_offset(footprint_cells + access_cells) == Vector2i.ZERO,
    "equipment_def 违反锚点约定：并集包围盒必须从 (0,0) 开始")
assert(footprint_cells.size() > 0,
    "equipment_def 的 footprint_cells 不能为空")
```

> **这不是把校验职责从 EquipmentCatalog 挪到 GridSystem。** Godot 的 `assert()` 在导出的 release 构建中被**编译期剔除、零成本**（只在 debug/editor 生效）—— 生产环境里这两行代码不存在，真正的校验依然完全归 EquipmentCatalog。
>
> 它的唯一作用是让**手搓的测试 fixture**（不经过 EquipmentCatalog 校验）在开发时立刻爆炸，而不是产出一个静默错误的旋转结果。`assert()` 本质上就是"信任生产 + 校验 debug"的标准组合 —— 不需要在"完全信任"和"运行时防御"之间二选一。

#### 🔴 Release 构建下的未定义行为（显式承认的已知缺口）

`assert()` 在 release 被剔除，且本 GDD 明确规定 GridSystem 生产路径**不做运行时防御**。这两条合起来意味着：**以下输入在 release 构建下行为未定义**。这里显式写出来，是为了让它成为**被承认的取舍**，而不是一个被沉默掩盖的洞：

| 非法输入 | debug 构建 | release 构建 | 谁是真正的门 |
|---|---|---|---|
| `footprint_cells == []` | `assert()` 中止（AC-D5.3） | **未定义** —— `declared_bounds` 的 `max{}` 在空集上无意义；可能返回 `(0,0)` 或引擎级报错 | EquipmentCatalog 加载期 |
| 并集包围盒 `min != (0,0)` | `assert()` 中止（AC-D5.2） | **未定义** —— 产出一个静默错误的旋转结果 | EquipmentCatalog 加载期 |
| `rotation ∉ {0, 90, 180, 270}`（如 `45`、`-90`） | **无防御** —— `rotation` 名义上是枚举，但 GDScript 不强制 | **未定义** —— D.1 的 4 个分支无一匹配，落入实现的 `else` 分支（行为取决于实现者怎么写） | 调用方（PlacementSystem）；见下 |

> **为何接受这个缺口而不加运行时防御**：GridSystem 是**每次拖拽预览每帧都要跑**的热路径（见"快照语义"与 H.17）。为一个"只可能由调用方 bug 或手搓 fixture 触发、且在 debug/CI 里必然被 assert 抓到"的输入，在生产路径上永久付出检查成本，不划算。**这与 D.2 越界检查的处理不同是有意的**：越界坐标可能来自**存档损坏**（外部不可信输入），而非法 `equipment_def` 只可能来自**代码或数据 bug**（内部可信输入，且有 EquipmentCatalog 这道加载期门）。
>
> **`rotation` 是这张表里唯一没有上游门的一行**，因此额外要求：`rotation` 在实现中**必须**用 GDScript `enum`（`enum Rotation { R0 = 0, R90 = 90, R180 = 180, R270 = 270 }`）而非裸 `int` 声明，把校验交给类型系统而不是运行时。D.1 的实现**必须**写成穷举 4 分支 + `_:` 兜底 `assert(false, "非法 rotation")`，**不得**用 `else` 静默回退到 0°（那会把一个调用方 bug 变成一台朝向错误的器械 —— 又一个"沉默的坏读取"）。
>
> **🔴 归一化归调用方，GridSystem 不做 `% 360`（交接 PlacementSystem #4）**：`rotation = 360` 按本设计是**非法值**（命中 `_:` 兜底 assert），**不会**被规范化为 `0`。这是刻意的 —— 静默接受 `360` 就等于接受"调用方没搞清自己的旋转状态"，而下一个 `450` 或 `-90` 同样会来。
>
> **但这条决定给调用方留了一个现实的坑，必须点名**：一个最朴素的旋转 UI —— "每按一次 R 键 `rotation += 90`" —— 在**第四次按键时就会产生 `360`**，直接命中上表那行"未定义行为"（debug 下 assert 中止，release 下未定义）。这不是一个牵强的边界，这是**任何人都会先写出来的那版代码**。
>
> **因此 PlacementSystem 的契约是：在调用 GridSystem 之前完成归一化**（`rotation = (rotation + 90) % 360`，或直接在 4 个 enum 值上循环）。GridSystem 收到的必须已经是 `{0, 90, 180, 270}` 之一。**GridSystem 不替调用方做这件事的理由**：`% 360` 能把 `360` 修成 `0`，但它同样会把一个**真正的 bug**（比如某处把角度和格数搞混了，传进来 `1080`）悄悄修成一个看起来合理的 `0` —— 那正是本 GDD 反复拒绝的"静默修正"。**归一化是调用方对自己旋转状态的责任，不是 GridSystem 的容错义务。**

**测试要求**：见 AC-D5.4（release 未定义行为的显式 ADVISORY 记录）与 AC-D1.1（`rotation` 枚举兜底）。

**Example:** 2×2 深蹲力量架 + 1 格前方 access：`footprint_cells=[(0,0),(1,0),(0,1),(1,1)]`，`access_cells=[(0,2)]`。并集 `x∈{0,1}, y∈{0,1,2}` → `W=1+1=2`，`H=2+1=3`。结果 `(W,H)=(2,3)`，与"2×2 footprint + 1 行 access"的直觉一致。

### D.6 MVP 房间尺寸（参数，非公式）

**决定：包围盒 `width=13, height=10`（130 格）—— MVP 假设值，待 `/prototype` 校准。**

这是 D.2 / D.4 公式的输入常量，故在此交代，但不计入公式编号。**它同时列在 G 节 Tuning Knobs**，作为带安全范围的调参项。

> **注意**：13×10 是**包围盒**数字，不是可用地板数字。不规则房间的墙/柱/门/窗（`buildable=false`）会再吃掉约 10–15% → 估算 **~110–115 可建造格**。

选型依据（MVP = 5–6 种器械，footprint 限 `1×1`/`1×2`/`2×2`）：

| 候选 | 包围盒 | 估算可建造格 | 支柱1（空间深度） | 支柱2（松弛感） |
|---|---|---|---|---|
| A. 紧凑 | 10×8=80 | ~68-72 | 信号最强：几乎必然拥堵 | 风险高：L 形侵蚀后可能"怎么摆都挤"甚至逼近无解 |
| **B. 均衡（起点，待验证）** | **13×10=130** | **~110-115** | 推测足够密度制造 1-2 个真实拥堵点 —— 核心假设能被触发**且有解** | 推测留有绕行/留白空间，不规则墙体仍有意义但不处处逼仄 |
| C. 宽敞 | 16×12=192 | ~165-170 | 推测 5-6 件器械在 192 格里大概率**不会**产生任何拥堵 —— 核心假设因"根本不需要调"而验证不充分 | 最舒适，绝无局促感 |

> **⚠️ 上表全部是推理，没有一格是玩出来的。** 三列"支柱"评估都建立在同一个**未经验证**的假设上 —— "5–6 件器械 + ~110 格会产生恰到好处的拥堵"。**B 的论证与它要验证的命题是同一个命题**，这是一个循环：不能用它来证明 B 是对的。
>
> 本表的作用**仅**是"我们为什么从 13×10 起步"的可追溯记录，**不是**一个结论。原始版本在 B 行标了 ✅ 并给 A/C 标了 ❌ —— 那是**过度自信的呈现方式**：它会让读到这里的原型设计者（可能是几周后的我们自己）默认 130 是已定的，转而去**确认**它，而不是**测试**它。

> **🔴 对 `/prototype` 的明确要求：必须探到 A 和 C 的边界，不能只测 B。**
>
> `design/gdd/game-concept.md` 的 Risks 一节把"空间优化深度 vs 松弛感平衡"列为**最高设计风险**，并明确写明"这个平衡只能靠原型验证"。房间尺寸是这个平衡最直接的旋钮 —— 那么原型的任务就**不是**"验证 13×10 好不好玩"，而是**"找到拥堵感消失的上界和松弛感消失的下界"**。只测 B 得到的是一个"还行"，那既不能证明 B 是最优，也发现不了真正的边界在哪。
>
> 具体：原型应可运行时调整房间尺寸，至少覆盖 10×8 / 13×10 / 16×12 三档并**记录每档的主观拥堵感与解法数量**。若 C（宽敞）依然有拥堵 → 说明我们低估了器械密度的影响，MVP 房间可以更大；若 A（紧凑）依然松弛 → 说明"逼仄=焦虑"的担忧被高估了。**这两个发现中的任何一个都比"B 感觉还行"有价值得多。**

## Edge Cases

> **格式**：每条 = **若 [条件]** → [确切结果]。无"妥善处理"式模糊表述。
>
> ⚠️ `systems-designer` 未就本节单独咨询 —— Lean 模式。但本节大量条目源自它与 `godot-specialist` 在 C/D 节的产出，非凭空生成。

### 放置合法性边界

- **若 access cell 落在不可建造格（墙/柱/门/窗）上** → `can_place` 返回 `FAIL: ACCESS_BLOCKED_BY_ROOM_GEOMETRY`，**拒绝放置**。理由：墙是不可恢复的几何硬约束，与"被别的器械挤住"（挪走即恢复）性质不同；允许放下但永远用不了会让玩家费解，违反"沉默可信度"。
- **若 access cell 被别的器械 footprint 压住** → **允许放置**，器械进入运行时"访问受阻"状态。这不是错误 —— 这是"摆太挤→能放但没人用"的设计意图本身。
- **若两台器械的 access cells 完全重叠** → **允许放置，GridSystem 完全不预警**。后果只在运行时由 Congestion/Overlay 可视化呈现。
- **若 footprint 越出房间包围盒** → `FAIL: OUT_OF_BOUNDS`。
- **若 access cell 越出房间包围盒** → `FAIL: ACCESS_OUT_OF_BOUNDS`。与 footprint 越界分开报，因为 UI 提示语不同（"器械放不下" vs "留出的通道超出房间"）。
- **若 footprint 与已有器械重叠** → `FAIL: OVERLAPS_EXISTING_EQUIPMENT`。这是唯一因"被别的器械挡住"而拒绝放置的情况 —— footprint 互斥是物理事实，非机会型冲突。

### 越界与非法输入

- **若查询坐标越出包围盒** → `_in_bounds()` 拦截，`push_error()`，返回安全默认值。**严禁**把非法 `idx` 喂给 `PackedArray`（引擎级崩溃，或更糟：静默读到相邻行数据）。
- **若 `is_solid()` 被查询越界坐标** → 返回 **`true`**（"墙外都算实心"），防止 `AStarGrid2D` 向界外寻路。
- **若 `clear(instance_id)` 的 id 不在反向索引中** → `push_error()`，**不修改任何格子**，不发 `grid_changed`。静默成功是最危险的选项 —— 调用方会以为清掉了。
- **若 `commit()` 的 `instance_id` 已存在于反向索引** → `push_error()` 并**拒绝提交**。id 复用是调用方 bug；覆盖旧记录会导致旧占用格永久泄漏（反向索引丢失 → 再也 `clear` 不掉）。
- **若 `commit()` 的 `instance_id < 0`**（含 `-1`）→ `push_error()` 并**拒绝提交**，不修改任何格子。`-1` 是 `occupant_id` 的"空"哨兵（规则2）；放行会让该格在 `get_occupant_id()` 眼里**仍然是空的** —— 器械凭空消失，且永远无法被 `clear` 掉。见规则7 的 `instance_id` 生命周期契约与 AC-C7.7。
- **若 `commit()` 的 `instance_id` 是一个曾被 `clear()` 过的旧 id**（分配器复用）→ **GridSystem 正常接受，检测不到**。复用的 id 与全新 id 在本层完全无法区分。**这是分配器的契约（规则7"会话内永不复用"），不是 GridSystem 能防的** —— 后果是下游缓存（SelectionSystem 的 `id → EquipmentInstance` 映射）静默指向错误的器械。交接 PlacementSystem GDD（#4）。见 AC-C7.8。

### 器械数据边界（EquipmentCatalog 交接）

- **若器械声明 0 个 access cells**（如纯装饰物、储物柜）→ **合法**。`can_place` 的 access 检查段落自然跳过；该器械永不进入"访问受阻"状态。
- **若器械声明 0 个 footprint cells** → **非法**。EquipmentCatalog 加载期拒绝该数据 —— art-bible 已锁定 footprint 下限为 `1×1`，任何可放置物体天然占至少 1 格；0 格意味着"占据空气"。
  > 与"0 个 access cells 合法"性质**不同**：那是"不需要人站的位置"，这是"不占用任何空间" —— 后者违反本系统存在的前提（GridSystem 是空间真相的仲裁者，一个不占空间的实体没有空间真相可言）。
  >
  > GridSystem 不做运行时防御性检查（生产路径信任调用方），仅 debug 构建下 assert `footprint_cells.size() > 0`（见 D.5）。
- **若器械的 access cells 与自己的 footprint 重叠** → **加载期数据错误**，由 EquipmentCatalog 校验拒绝。器械不可能站在自己身上被使用。GridSystem 不做此校验（它不存储 canonical 定义）。
- **若器械 canonical 定义的并集包围盒 `min_x != 0` 或 `min_y != 0`** → 违反 D.5 锚点约定，**EquipmentCatalog 加载期报错**。
- **若器械的声明包围盒大于整个房间** → `can_place` 在任何锚点都返回 `FAIL: OUT_OF_BOUNDS`。这是数据/关卡配置问题；MVP 房间 13×10 vs 器械上限 ~3×3，不会发生，不做特殊处理。

### 加载期与房间几何

- **若加载的存档中某器械 footprint 落在 `buildable=false` 的格上** → `deserialize()` 返回 `FAIL: LEVEL_GEOMETRY_MISMATCH`，**整体失败**，不得运行时静默处理。这意味着存档与关卡几何不匹配（关卡被改过）。
- **若加载的存档中某器械 access 格落在 `buildable=false` 的格上** → `FAIL: LEVEL_GEOMETRY_MISMATCH`，**整体失败**。与 footprint 同等对待 —— 规则5 规定 access 压墙时 `can_place` 拒绝，若 `deserialize()` 放行，就能造出一个正常放置流程永远不可能产生的状态（使用位埋在墙里）。
- **若 `deserialize()` 收到的 `records` 中两条记录的 footprint 格重叠** → `FAIL: CORRUPTED_SAVE_OVERLAP`，**整体失败**。（access 格重叠是允许的，与规则5 一致，不报错。）
- **若 `deserialize()` 收到的 `width`/`height` 与当前关卡不一致** → `FAIL: LEVEL_GEOMETRY_MISMATCH`，**整体失败**。
- **若 `deserialize()` 收到的 record 内坐标越界**（存档被截断/篡改）→ `FAIL: CORRUPTED_SAVE_OUT_OF_BOUNDS`，**在写入前的校验阶段拦截**，绝不让越界坐标进入写入循环（否则 `PackedArray` 越界写）。
  > **🔴 以上五条一律不做部分恢复。** 半个正确的场馆比空场馆更危险 —— 玩家会以为这就是他们留下的样子。C 节规则8 的**两阶段结构**（先全量校验、后统一写入）让这一点成为结构性保证，而非需要手写回滚的纪律。
- **若 MVP 阶段有代码调用 `set_buildable()`** → 违反契约。`buildable` 加载时固定、运行时只读。
- **若房间包围盒（`region`）在运行时变化** → **MVP 不允许发生**。若 Vertical Slice 引入扩建：必须走独立的 `grid_resized(new_region)` 事件并从 occupancy 真相源**全量重灌** solidity —— 因为实测证明改 `region` 会清空 `AStarGrid2D` 所有已设 solid 标记。**严禁**混进 `grid_changed` 的增量路径。

### 明确不归 GridSystem 管的边界

> 本小节是**划界**，防止实现者"顺手解决"越权问题。

- **若两个会员想同时占用同一个 access cell** → **不是 GridSystem 的问题**。这是运行时**预定/释放**语义，归 MemberSim（或专门的预定系统）。
  > 🔴 **严禁**用"让 access cell 变 solid"来解决 —— 那会把机会型冲突（可能没人排队）退化成**永久死锁**（谁都走不进去）。D.3 `is_solid` 公式必须永远保持"access 不参与 solidity"。
- **若某器械当前无任何可达 access cell**（被围死）→ **不是 GridSystem 的问题**。GridSystem 只答"这格是谁的使用位"（静态归属），不答"此刻有没有人能走到"（动态可达性）。归 Navigation + MemberSim。
  > **🔴 但"不归我管"不等于"没人管"—— 这是本 GDD 必须交出去的一个需求，不能就这么落地。**
  >
  > 本 GDD 的设计逻辑是：放置时不警告（支柱2：不打断心流），**后果交由运行时可视化呈现**。这条链子只有在**下游真的接住**时才成立。而目前：
  > - GridSystem 明确不产出任何可达性信号（AC-NEG.2 把这一点钉死了）
  > - `systems-index.md` 里 Congestion 的依赖是 `Navigation, MemberSim`，**没有任何系统被指派"告诉玩家这台器械没人能用"**
  >
  > 于是存在一个真实的空洞：一台器械可以**永远无人可用**，而**没有任何系统有义务让玩家发现**。这是 B 节意义上最纯粹的"咦？"—— 不是延迟发现，是**永不发现**。
  >
  > **交接 Congestion/Overlay GDD（设计顺序 #7 / #8）—— 具名需求，两条**：
  > 1. **必须有系统负责呈现"access 受阻 / 零可达"状态。** 这是 GridSystem 允许该状态静默存在的**前提条件**，不是一个可选的打磨项。
  > 2. **🔴 呈现必须是环境性的（ambient），不能只藏在一个需要玩家主动打开的开关后面。** 若拥挤度/动线 overlay 做成了默认关闭的切换项（本品类常见 —— Two Point Hospital 的热力图就是这样），那么对于**从不打开它的玩家**，"放置时不警告、真相稍后可见"这套策略**根本没有第二步**，等于什么都没说。器械上一个常驻的小图标、一次放置后的轻微提示 —— 具体形式归 UX，但"默认可见"这个约束**归本条**。
  >
  > **为何写在 GridSystem 而不是留给下游自己想起来**：因为这个空洞是**本 GDD 的设计选择造成的**。是我们选了"不警告"，那么"确保有人接住"就是我们的责任的一部分 —— 哪怕实现不在我们这一层。
- **若快照在模拟 tick 中途被请求** → 不会发生。模拟由 SimulationOrchestrator 单线程固定顺序驱动，存档只在 tick 边界。GridSystem 不做并发防护。

## Dependencies

### 上游依赖（本系统依赖谁）

**无。** 这是刻意的，也是对抗式边界审查（TD-SYSTEM-BOUNDARY）的核心结论：GridSystem 是空间真相的**唯一仲裁者**，如果它依赖任何东西，那个东西就成了事实上的空间真相持有者。

> ⚠️ **一个需要点名的灰色地带**：D.5 `declared_bounds` 消费 `footprint_cells` / `access_cells`，它们来自 EquipmentCatalog。但这**不构成系统依赖** —— GridSystem 从不"够"到 EquipmentCatalog 去读数据，`equipment_def` 始终由调用方（PlacementSystem）**作为参数传入**。
>
> 这是**数据契约耦合**（GridSystem 认识 `EquipmentDef` 的字段形状），不是**系统依赖**（GridSystem 不持有 EquipmentCatalog 引用、不订阅它的信号、不需要它先初始化）。
>
> 这个区分不是文字游戏：它决定了单元测试能否用一个手搓的 `EquipmentDef` 字面量构造 GridSystem 测试，而不必先起一个 EquipmentCatalog。

### 下游依赖（谁依赖本系统）

| 系统 | 方向 | 硬/软 | 数据接口 | 谁负责什么 |
|---|---|---|---|---|
| **PlacementSystem** | 依赖本系统 | **硬** | 传入 `equipment_def, anchor_cell, rotation`；调用 `can_place` / `commit` / `clear` / `get_transformed_cells` | GridSystem 提供合法性判定 + 纯函数计算；Placement 决定**何时**提交（松手确认）。GridSystem 从不感知"正在拖拽" |
| **Navigation** | 依赖本系统 | **硬** | 读 `is_solid(cell)` / `get_solidity_snapshot()`；订阅 `grid_changed` | GridSystem 提供 solidity 真相；Navigation 自己维护 `AStarGrid2D` 并决定增量重烘焙策略。**GridSystem 完全不知道 `AStarGrid2D` 存在** |
| **ZoneRules** | 依赖本系统 | **硬** | `get_snapshot()` / `get_speculative_snapshot(deltas)` | GridSystem 提供快照值；ZoneRules 是纯函数，全程不知道快照是真是假 |
| **MemberSim** | 依赖本系统 | **硬** | `get_access_cells(id)` / `get_occupant_id(cell)` | GridSystem 提供**静态归属**；MemberSim 自建表管理**动态占用**（谁此刻站在哪），绝不写回 |
| **SelectionSystem** | 依赖本系统 | **硬** | `get_occupant_id(cell)` | GridSystem 只答整数 id；Selection 自己维护 `id → EquipmentInstance` 映射 |
| **SaveLoad** | 依赖本系统 | **硬** | `serialize()` / `deserialize()` —— **契约见 C 节规则8** | GridSystem 产出确定性序列；SaveLoad 只在 tick 边界协调，不理解内容。注意 `buildable` **不在序列化输出内**，由调用方独立注入 |
| **表现层适配器**（`GridVisualizer` 等） | 依赖本系统 | **软** | 订阅 `grid_changed`，再去操作 `TileMapLayer` | **GridSystem 完全不知道 `TileMapLayer` 存在。** 适配器可以不存在（headless 测试），GridSystem 照常工作 |
| **Congestion / Overlay** | 依赖本系统 | **软** | 经 `grid_changed` 的 `access_cells_changed` 得知使用位变化 | GridSystem 只广播事实；"这台机没人用"的判定与可视化完全归下游 |
| **EquipmentCatalog** | **数据契约耦合，非系统依赖** | — | `EquipmentDef` 的字段形状（`footprint_cells` / `access_cells`） | EquipmentCatalog 负责加载期校验（锚点约定、access 不与自身 footprint 重叠、footprint 上限）；GridSystem 只在拿到 `equipment_def` 时用它 |

### 双向一致性检查

对照 `design/gdd/systems-index.md`：

| 索引中的声明 | 本 GDD | 一致？ |
|---|---|---|
| GridSystem "Depends On: —" | 本节声明无上游依赖 | ✅ |
| PlacementSystem depends on GridSystem, EquipmentCatalog | 本节列 Placement 为硬下游 | ✅ |
| Navigation depends on GridSystem (occupancy) | 本节列 Navigation 为硬下游，明确 solidity 契约 | ✅ |
| MemberSim depends on TimeSystem, GridSystem, Navigation | 本节列 MemberSim 为硬下游 | ✅ |
| ZoneRules depends on GridSystem, EquipmentCatalog | 本节列 ZoneRules 为硬下游，快照纯函数 | ✅ |
| SelectionSystem depends on GridSystem | 本节列 Selection 为硬下游 | ✅ |
| SaveLoad depends on all sim systems (`serialize()`) | 本节列 SaveLoad 为硬下游 | ✅ |
| Congestion depends on Navigation, MemberSim（**不直接依赖 GridSystem**） | 本节列为**软**依赖（只经 `grid_changed` 感知使用位变化） | ⚠️ **索引未列此边** |

> **⚠️ 与索引的一处偏差**：索引里 Congestion 的依赖是 `Navigation, MemberSim`，没有 GridSystem。本 GDD 把它列为**软**依赖（订阅 `grid_changed` 的 `access_cells_changed`）。两种解读都说得通 —— 也可以让 Congestion 完全经由 MemberSim 间接得知。
>
> **这条留给 Congestion GDD（设计顺序 #7）定夺**；若它选择直接订阅，需回头更新索引的依赖表。本 GDD 不单方面改索引。

### 循环依赖状态

| 潜在环 | 状态 | 打破方式 |
|---|---|---|
| Placement ↔ ZoneRules | ✅ 已解 | `ZoneRules.evaluate(snapshot)` 是纯函数；预览传推测快照。调用链单向 `Placement → GridSystem(纯函数) → 快照值 → ZoneRules(纯函数)`，无一环反向持有引用或订阅信号 |
| Congestion ↔ Routing | ✅ 设计内解决 | Congestion(t-1) → routing(t) 一帧延迟。**与 GridSystem 无关** —— GridSystem 不参与该反馈环 |

**GridSystem 本身不参与任何环** —— 它是有向依赖图的汇点（只被依赖，不依赖）。这正是"空间真相唯一仲裁者"这一定位的结构性保证。

## Tuning Knobs

> **GridSystem 是基础设施，几乎没有调参项。** 它的"数值"只有房间尺寸和房间形状 —— 其余全是规则与契约，改了就是改设计，不是调参。本节不凑数。

| 参数 | 当前值 | 安全范围 | 调高的效果 | 调低的效果 |
|---|---|---|---|---|
| `grid_width` | **13**（MVP 假设值） | 10–16 | 更多可建造格 → 拥堵更难自然产生 → **核心假设可能验证不充分**（"根本不需要调布局"）。>16 时 5–6 件器械几乎必然毫无压力 | 空间更紧 → 拥堵信号更强；但 <10 时 L 形侵蚀后可能"怎么摆都挤"甚至逼近无解 → **违反支柱2** |
| `grid_height` | **10**（MVP 假设值） | 8–12 | 同上 | 同上 |
| `buildable` 布局（房间形状） | 关卡数据 | — | 墙/柱/门/窗越多 → 可用面积越小、空间谜题越硬。**这是关卡设计的旋钮，不是数值旋钮** | 全可建造 = 退化为纯矩形，失去不规则房间的设计价值 |

> **🔴 `grid_width` / `grid_height` 是 prototype 阶段第一优先级要验的调参项。**
>
> `design/gdd/game-concept.md` 的 Risks 一节把"空间优化深度 vs 松弛感平衡"列为**最高设计风险**，并明确写明"这个平衡只能靠原型验证"。房间尺寸是这个平衡最直接、最粗粒度的旋钮 —— 在 `/prototype` 之前，13×10 只是一个**有理由的起点**，不是结论。

### 旋钮交互

`grid_width` × `grid_height` × `buildable` 密度 **三者共同决定唯一真正重要的量：可建造格总数**。它们不是独立旋钮 —— 把 13×10 改成 10×13 对玩法几乎无影响（除非房间形状随之改变）；而保持 13×10 但把墙加倍，效果等同于显著缩小房间。

> **调参建议**：先固定房间形状，只调 `width`/`height` 找到拥堵与松弛的平衡点；确定总格数后，再用 `buildable` 布局做**质的**调整（走廊在哪、柱子逼出什么动线）。反过来同时调两者会让原型数据无法解读。

### 明确不是本系统旋钮的东西

| 值 | 归属 | 为什么不在这 |
|---|---|---|
| `cell_size`（16 / 32 px） | **架构阶段** | art-bible §8 原文写明"架构阶段最终确定"。且 GridSystem 内部逻辑完全不依赖它的值 —— 只有 D.4 的表现层换算用得到 |
| 器械 footprint / access 形状 | **EquipmentCatalog** | GridSystem 不存储 canonical 定义，只消费传入的 `equipment_def` |
| `diagonal_mode` / `jumping_enabled` | **Navigation GDD** | 寻路行为参数，非空间真相参数 |
| 拥挤度阈值、满意度权重 | **Congestion / Satisfaction GDD** | GridSystem 只提供事实，不做任何评价 |

## Visual/Audio Requirements

**无。GridSystem 不产出任何视觉或听觉反馈 —— 这是刻意的，也是它的边界定义之一。**

它是 `extends RefCounted` 的纯数据类，**完全不知道 `TileMapLayer` 存在**，也不知道自己被渲染成什么样。所有与网格相关的视觉表现均归他处：

| 视觉表现 | 归属 | 与本系统的关系 |
|---|---|---|
| 地板 / 墙 / 柱 / 窗的 tile 绘制 | 表现层适配器（`GridVisualizer` 等） | 订阅 `grid_changed`，自行操作 `TileMapLayer` |
| 拖放时的格子吸附高亮 | PlacementSystem / Build UI | 调用 `get_transformed_cells()`（纯函数）取格集合，自行决定怎么画 |
| 非法位置的柔和玫瑰色提示 | PlacementSystem / Build UI | 消费 `can_place()` 的 `FAIL` 码，自行决定文案与配色（art-bible §"拖放交互反馈"：非法位置用柔和玫瑰色而非刺眼红） |
| 拥挤度 / 动线热力图 | Congestion / Overlay | 不消费 GridSystem 的视觉输出，只消费其数据 |
| 器械放置成功的星光 + 吸附咔哒 | PlacementSystem / Audio | GridSystem 的 `commit()` 只改数据、发信号，不触发任何 SFX |

> **这条边界是可测的**：GridSystem 必须能在 `godot --headless`、无场景树、无 `TileMapLayer` 实例的环境下被完整单测覆盖（见 H 节全部 BLOCKING 标准）。**若某天 GridSystem 的测试开始需要起一个场景树，说明这条边界已被破坏。**

## UI Requirements

**无。GridSystem 不向玩家显示任何信息。**

它不拥有任何屏幕元素、不产出任何面向玩家的文案。它只提供数据与错误码；**如何呈现完全归调用方**：

| 玩家看到的东西 | 谁负责 | GridSystem 提供什么 |
|---|---|---|
| "这里放不下"的提示 | Build/Shop UI | 仅 `FAIL` 码（`OUT_OF_BOUNDS` / `BLOCKED_BY_ROOM_GEOMETRY` / `OVERLAPS_EXISTING_EQUIPMENT` / `ACCESS_OUT_OF_BOUNDS` / `ACCESS_BLOCKED_BY_ROOM_GEOMETRY`）。**文案由 UI 决定** |
| "这台器械没人能用" | Congestion / Overlay | 什么都不提供 —— GridSystem 不做可用性判定（见 E 节划界） |
| 存档加载失败的说明 | SaveLoad / UI | 仅 `DeserializeResult.errors`（`LEVEL_GEOMETRY_MISMATCH` / `CORRUPTED_SAVE_OVERLAP` / `CORRUPTED_SAVE_OUT_OF_BOUNDS`）。玩家可读文案由上层决定 |

> **`FAIL` 码分得细，正是为了服务 UI 文案** —— C 节规则6 特意把 footprint 越界与 access 越界分成两个码，就是因为"器械放不下"和"留出的通道超出房间"对玩家是两件不同的事。**GridSystem 的职责止于把这个区别如实传上去，不替 UI 决定怎么说。**

## Acceptance Criteria

> **格式**：每条 = **GIVEN** 初始状态 **WHEN** 触发动作 **THEN** 可测量结果。每条标注 **[BLOCKING/ADVISORY]** 与 **[Logic/Integration]**。
>
> BLOCKING = 自动化单测未过，故事不得标记 Complete（见 `.claude/docs/coding-standards.md`，Logic/Integration 类型硬门禁）。
>
> 本节按 C 节规则与 D 节公式逐条映射组织，外加跨系统集成标准与负向标准（划界）。

### H.1 坐标系与房间几何（C 节规则1）

**AC-C1.1** [BLOCKING][Logic] GIVEN 一个 5×5 网格，格 `(2,2)` 的 `buildable=false`（墙），WHEN 查询 `get_occupant_id((2,2))`，THEN 返回 `-1` —— `buildable` 与 `occupancy` 互不影响对方的读取结果。

**AC-C1.2** [BLOCKING][Logic] GIVEN 一个已初始化的 GridSystem 实例（MVP 模式），WHEN 在关卡加载完成后调用 `set_buildable()`，THEN 调用被拒绝并 `push_error()`，网格 `buildable` 状态不变。

### H.2 每格数据形状（C 节规则2）

**AC-C2.1** [BLOCKING][Logic] GIVEN 空网格，WHEN 对同一格先 `commit(id=1, footprint=[cell])` 成功后不 `clear`，直接 `commit(id=2, footprint=[cell])`，THEN 第二次 `commit` 被拒绝，该格 `occupant_id` 仍为 `1` —— 验证互斥单值语义。

**AC-C2.2** [BLOCKING][Logic] GIVEN 空网格，WHEN `commit(id=1, access=[cell])` 后再 `commit(id=2, access=[cell])`（同一 access 格，不同 footprint），THEN 两次都成功，该格 `access_ids` 返回 `[1, 2]` —— 验证非互斥多值语义。

### H.3 锚点约定（C 节规则3）

**AC-C3.1** [BLOCKING][Logic] GIVEN `footprint=[(0,0),(1,0),(0,1),(1,1)]`、`access=[(0,2)]`，`anchor_cell=(5,5)`，`rotation=0°`，WHEN 调用 `get_transformed_cells`，THEN footprint 世界格恰为 `{(5,5),(6,5),(5,6),(6,6)}`，access 为 `{(5,7)}`。

### H.4 footprint × rotation 映射（C 节规则4 🔴 最高危）

**AC-C4.1（1×2 跑步机，非方形 footprint，穷举 4 朝向）** [BLOCKING][Logic]
GIVEN `footprint=[(0,0),(0,1)]`、`access=[(0,2)]`，声明包围盒 `(W=1,H=3)`，anchor=`(0,0)`，WHEN 分别以 `{0°,90°,180°,270°}` 调用 `get_transformed_cells`，THEN 结果精确等于：

| rotation | footprint | access |
|---|---|---|
| 0° | `{(0,0),(0,1)}` | `{(0,2)}` |
| 90° | `{(2,0),(1,0)}` | `{(0,0)}` |
| 180° | `{(0,2),(0,1)}` | `{(0,0)}` |
| 270° | `{(0,0),(1,0)}` | `{(2,0)}` |

**AC-C4.2（1×1 深蹲架 + access，交叉验证 fixture）** [BLOCKING][Logic]
GIVEN `footprint=[(0,0)]`、`access=[(0,1)]`，声明包围盒 `(W=1,H=2)`，WHEN 同测 4 朝向，THEN 结果精确等于 D.1 表格（0°→access `(0,1)`；90°→access `(0,0)`；180°→access `(0,0)`；270°→access `(1,0)`）。

**AC-C4.3（负向 —— 捕获"局部包围盒 vs 并集包围盒"这个具体 bug）** [BLOCKING][Logic]
GIVEN AC-C4.1 的跑步机 fixture，WHEN 90° 或 270° 旋转，THEN access 格坐标两个分量必须都 `>= 0`。

> **🔴 测试套件若只测 0°/180° 就判定通过，本条本身就不合格** —— 必须包含 90°/270°，因为 C 节明确指出这是唯一能暴露该 bug 的朝向（0°/180° 被对称掩盖）。

### H.5 access cells 规则（C 节规则5）

**AC-C5.1** [BLOCKING][Logic] 与 D.3 共享同一断言，见 AC-D3.1。

**AC-C5.2** [BLOCKING][Logic] GIVEN 空网格，WHEN 两次 `commit` 使用完全相同的 access 格但不同 footprint，THEN 两次都成功（`can_place` 不因 access 重叠 FAIL）。

**AC-C5.3** [BLOCKING][Logic] GIVEN 格 `(3,3)` `buildable=false`，WHEN `can_place` 的 access 集合包含 `(3,3)`，THEN 返回 `FAIL: ACCESS_BLOCKED_BY_ROOM_GEOMETRY`，且不产生任何格子写入。

**AC-C5.4** [BLOCKING][Logic] GIVEN 器械 A 的 footprint 已占据格 `(4,4)`，WHEN 器械 B 的 access 集合包含 `(4,4)`，THEN `can_place` 返回 `{valid:true}`，`commit` 成功，`(4,4)` 的 `occupant_id` 仍为 A，`access_ids` 包含 B。

**AC-C5.5（0 个 access cells 合法）** [BLOCKING][Logic]
GIVEN 一个 `access_cells=[]` 的器械（如储物柜、纯装饰物），WHEN 调用 `can_place` 与 `commit`，THEN 两者都成功；`grid_changed` 的 `access_cells_changed` 为**空数组**（不是 null）；`get_access_cells(id)` 返回**空数组**；该器械永不进入"访问受阻"状态。
> E 节"器械数据边界"已用文字规定这是合法的，但此前无任何 AC 覆盖 —— 补上。**注意与 AC-D5.3（空 `footprint_cells` → assert 中止）的对照**：空 access **合法**（"不需要人站的位置"），空 footprint **非法**（"不占据任何空间"）。这两条测试放在一起，正好把这个刻意的不对称钉死。

### H.6 `can_place` 判定序列（C 节规则6）

**AC-C6.1** [BLOCKING][Logic] GIVEN footprint 有一格越界 → `FAIL: OUT_OF_BOUNDS`（必须先于其他检查触发）。
**AC-C6.2** [BLOCKING][Logic] GIVEN footprint 在界内但压在 `buildable=false` 格上 → `FAIL: BLOCKED_BY_ROOM_GEOMETRY`。
**AC-C6.3** [BLOCKING][Logic] GIVEN footprint 合法但与已有 occupant 重叠 → `FAIL: OVERLAPS_EXISTING_EQUIPMENT`。
**AC-C6.4** [BLOCKING][Logic] GIVEN access 越界 → `FAIL: ACCESS_OUT_OF_BOUNDS`（必须与 footprint 越界返回**不同**错误码）。
**AC-C6.5** [BLOCKING][Logic] GIVEN 任意一次 `can_place` 调用，WHEN 调用完成，THEN 调用前后网格全量快照必须**完全相等** —— `can_place` 是纯只读判定，不允许任何副作用。

### H.7 commit / clear（C 节规则7）

**AC-C7.1** [BLOCKING][Logic] GIVEN `commit(id=9, ...)` 成功，WHEN 立刻 `clear(9)`，THEN 相关格子 `occupant_id` 变回 `-1`、`access_ids` 移除 `9` —— 验证反向索引被正确使用。

**AC-C7.2** [BLOCKING][Logic] GIVEN id=9 已在反向索引中，WHEN 再次 `commit(9, ...)`（不同格子），THEN 调用被拒绝并 `push_error()`，旧记录不被覆盖，旧格子状态不变。

**AC-C7.3** [BLOCKING][Logic] GIVEN id=99 从未 commit 过，WHEN 调用 `clear(99)`，THEN `push_error()` 触发，**修改前后网格全量快照完全相等**，且不发出 `grid_changed`。
> 必须用快照比较断言，不能只看返回值 —— 静默成功正是这条要防的失败模式。

**AC-C7.4** [BLOCKING][Logic] GIVEN 器械 A 的 footprint=`[(1,1),(1,2)]`、access=`[(1,3)]`，WHEN `commit(A)`，THEN `grid_changed` 触发恰好一次，`footprint_cells_changed == [(1,1),(1,2)]`，`access_cells_changed == [(1,3)]`（不多不少，不含未变化的格子）。

**AC-C7.5（clear 侧对称）** [BLOCKING][Logic]
GIVEN 器械 A 已 commit（同上），WHEN `clear(A)`，THEN `grid_changed` 触发恰好一次，两个数组内容**与 commit 侧相同** —— 字段名不携带方向语义。
> 测试必须显式断言"重查而非猜方向"这一契约本身可测：信号触发后 `is_solid((1,1))` 已变回 `false`。

**AC-C7.6（信号频率隔离）** [BLOCKING][Integration]
GIVEN 一次拖拽预览流程（多次调用 `get_speculative_snapshot`），WHEN 预览过程中反复触发快照请求，THEN `grid_changed` 触发次数为 **0**，直到真正 `commit()` 才触发 1 次。

**AC-C7.7（负 `instance_id` 被拒 —— 保护 `-1` 哨兵）** [BLOCKING][Logic]
GIVEN 空网格，WHEN 调用 `commit(instance_id=-1, ...)` 或 `commit(instance_id=-5, ...)`，THEN 每种情况都 `push_error()` 并**拒绝提交**，修改前后网格全量快照完全相等，不发 `grid_changed`。
> **为何单列**：`-1` 是 `occupant_id` 的"空"哨兵（C 节规则2）。若 `commit(-1)` 被放行，该格在 `get_occupant_id()` 眼里**仍然是空的** —— 器械凭空消失，且因为 `clear(-1)` 查不到有意义的反向索引记录，这个状态**永远无法被清除**。这是 C 节规则7 `instance_id` 生命周期契约"取值域 `>= 0`"那一行的可执行版本。

**AC-C7.8（`instance_id` 复用 —— 显式记录为不可测）** [ADVISORY][代码审查]
GIVEN 一个已 `commit` 后又 `clear` 的 id，WHEN 用同一个 id 再次 `commit` 一台**不同的**器械，THEN GridSystem **正常接受**（这是预期行为，不是 bug）。
> **本条不是一个通过标准，而是一条显式记录的能力边界**：GridSystem **无法**区分"复用的旧 id"与"全新的 id" —— 两者在它看来完全一样。C 节规则7 的"永不复用"契约**只能由分配器保证**，本层做不了二次校验。写成 AC 是为了让未来任何"给 GridSystem 加复用检测"的提议先读到这句话：**它需要 GridSystem 记住所有历史 id，与"反向索引只记录当前占用"的设计直接冲突。** 真正的门在 PlacementSystem GDD（#4）。

### H.8 序列化契约（C 节规则8）

**AC-C8.1（往返一致性）** [BLOCKING][Integration]
GIVEN 一组操作序列（多次 commit/clear，**含至少一个 rotation ≠ 0° 的器械**）应用于网格 A 后 `serialize()`，WHEN 用返回的 `Dictionary` 加同一份 `buildable_snapshot` 对全新实例 B 调用 `deserialize()`，THEN 以下**两条独立断言**均成立，且 `DeserializeResult.success == true`：

| # | 断言 | 比较口径 |
|---|---|---|
| **a** | **逐格状态相等** —— 对 `[0,width)×[0,height)` 内**每一格**，`B.get_occupant_id(cell) == A.get_occupant_id(cell)` 且 `B` 与 `A` 该格的 `access_ids` 内容相同 | **按格**遍历 |
| **b** | **反向索引相等** —— 对 A 中每个已 commit 的 `instance_id`，`B.get_access_cells(id) == A.get_access_cells(id)` | **按 `instance_id`** 遍历，**不是**按格 |

> **🔴 为何拆成两条而不是一句"逐格相等"**：原文写的是"`occupant_id`/`access_ids`/**反向索引**与 A 的 `get_snapshot()` **逐格**相等"—— 这是一个**范畴错配**：反向索引是**按 `instance_id` 索引**的（`id → PlacementRecord`），根本没有"格"这个维度可以逐。两个实现者会据此写出两种不同的测试（一个从 `occupant_id` 数组反推 id 集合，一个直接拿 `serialize()` 的输出比 —— 而后者与 AC-C8.3b 完全重复，等于这条 AC 白写）。
>
> **`rotation` 的往返由 AC-C8.2 单独覆盖**，本条不重复断言 —— `get_access_cells()` 是 `GridStateReader` 上唯一的按 id 公开读接口（见"与其他系统的交互"表），它足以验证反向索引的**格归属**部分；`rotation` 不在任何公开读接口上暴露，故 AC-C8.2 用的是索引内部状态。

**AC-C8.2（rotation 被保留）** [BLOCKING][Logic]
GIVEN 一个以 `rotation=90°` 提交的器械，WHEN `serialize()` 后 `deserialize()`，THEN 反向索引中 `PlacementRecord.rotation == 90`。
> 这条验证"只存反向索引不存数组"这一设计决策达到了它声称的目的 —— rotation 只存在于索引里，方案 C（只存数组）会丢失它。

**AC-C8.3（确定性写出 —— 全量深相等，不只是 record 顺序）** [BLOCKING][Logic]
GIVEN 以乱序插入的多个 instance_id（如先 commit id=5，再 commit id=2），WHEN 在两个独立构造、相同操作顺序的实例 A/B 上各调用 `serialize()`，THEN **`A.serialize() == B.serialize()` 全量深相等**（不仅是 `records` 数组顺序相同），且 `records` 按 `instance_id` 升序。

> **🔴 断言必须是整个 `Dictionary` 深相等，不能只查 record 顺序。** 只断言"records 按 id 排序"会漏掉**同一个 bug 的下一层**：每条 record 内部的 `footprint_cells` / `access_cells` 数组元素顺序。若实现里这些格集合在写出前经过 `Dictionary`/`Set`（例如为了去重），它们的元素顺序可能**独立于 record 顺序**发生变化 —— 与 C 节规则8"不依赖 Dictionary 迭代顺序"要防的是**同一类 bug，只是深了一层**。
>
> **实现约束**：每条 record 内的 `footprint_cells` / `access_cells` 也必须**确定性排序**（建议按 `(y, x)` 字典序），与 records 按 `instance_id` 排序同理 —— 同为零成本的防御性写法。

**AC-C8.3b（往返后仍逐字节相同）** [BLOCKING][Integration]
GIVEN 网格 A 的 `serialize()` 输出 `S_A`，WHEN 用 `S_A` 对全新实例 B 调用 `deserialize()` 后再调用 `B.serialize()` 得到 `S_B`，THEN **`S_A == S_B` 全量深相等**。
> **这条才是"确定性存档"真正的保证**，AC-C8.1 只验证了网格**状态**等价（逐格 `occupant_id` 相同），没有验证**序列化输出本身**稳定。两者的差别在实践中很要命：状态等价但字节不等价意味着"存档 → 读档 → 存档"会产生一个 diff 不同的文件 —— 对存档比对、云同步冲突检测、以及任何未来的回放/调试工具都是坏消息。
>
> 这也是唯一能捕获"`deserialize()` 重建反向索引时改变了 cells 顺序"这类 bug 的断言。

**AC-C8.4（LEVEL_GEOMETRY_MISMATCH —— footprint 落墙）** [BLOCKING][Logic]
GIVEN 某条 record 的 footprint 格在 `buildable_snapshot` 中为 `false`，WHEN `deserialize()`，THEN 返回 `{success:false, errors:[...LEVEL_GEOMETRY_MISMATCH...]}`，且网格**不发生任何写入**。

**AC-C8.5（LEVEL_GEOMETRY_MISMATCH —— access 落墙）** [BLOCKING][Logic]
GIVEN 某条 record 的 **access** 格在 `buildable_snapshot` 中为 `false`（关卡改过导致使用位冲进墙里），WHEN `deserialize()`，THEN 返回 `FAIL: LEVEL_GEOMETRY_MISMATCH`，网格不发生任何写入。
> 与 AC-C8.4 同等对待。若放行，`deserialize()` 就能造出一个**通过正常放置流程（规则5 / AC-C5.3）永远不可能存在**的状态。

**AC-C8.6（LEVEL_GEOMETRY_MISMATCH —— 尺寸不符）** [BLOCKING][Logic]
GIVEN `data.width`/`data.height` 与当前网格尺寸不一致，WHEN `deserialize()`，THEN 立即返回 `FAIL: LEVEL_GEOMETRY_MISMATCH`，不处理任何 record。

**AC-C8.7（CORRUPTED_SAVE_OUT_OF_BOUNDS）** [BLOCKING][Logic]
GIVEN 某条 record 的 footprint 或 access 坐标超出 `[0,width) × [0,height)`（存档被截断/篡改），WHEN `deserialize()`，THEN 返回 `FAIL: CORRUPTED_SAVE_OUT_OF_BOUNDS`，且**在写入阶段开始前就被拦截**。
> 测试须验证没有发生任何 `PackedArray` 越界写入 —— 这正是 D.2 越界契约最想防的事。

**AC-C8.8（CORRUPTED_SAVE_OVERLAP）** [BLOCKING][Logic]
GIVEN 两条 record 的 footprint 格重叠，WHEN `deserialize()`，THEN 返回 `FAIL: CORRUPTED_SAVE_OVERLAP`。（access 格重叠**不得**报错 —— 与规则5 一致。）

**AC-C8.9（不做部分恢复的强断言）** [BLOCKING][Logic]
GIVEN 5 条合法 record + 第 6 条触发 `CORRUPTED_SAVE_OVERLAP`，WHEN `deserialize()`，THEN 前 5 条**也不生效** —— `get_snapshot()` 显示网格为初始空状态，而非"前 5 条已提交、第 6 条失败"的半成品。
> 规则8 的两阶段结构（先全量校验、后统一写入）让这条成为结构性保证，无需手写回滚。

**AC-C8.10（单次信号发射）** [BLOCKING][Logic]
GIVEN 一份含 3 条合法 record 的存档数据，WHEN `deserialize()` 成功，THEN `grid_changed` 触发**恰好 1 次**（不是 3 次），payload 覆盖全部 3 条 record 的格集合并集。

### H.9 越界与非法输入（D.2）

**AC-D2.1（数据不泄漏）** [BLOCKING][Logic]
GIVEN `width=13,height=10`，格 `(6,3)` 有已知值，WHEN 写入 `(5,3)` 后读取 `(6,3)`，THEN `(6,3)` 的值不变 —— 验证 `flat_index` 不会算错索引导致跨行写串。

**AC-D2.2（越界拦截，不崩溃不泄漏）** [BLOCKING][Logic]
GIVEN `width=13,height=10`，WHEN 对任意公开查询函数传入 `col=-1`、`col=13`、`row=-1`、`row=10`，THEN 每种情况都 `push_error()` 并返回文档规定的安全默认值，且**不能返回相邻行/列的真实数据**。
> 须构造"越界一格恰好有数据"的场景验证不泄漏，而不仅是检查是否抛异常。

**AC-D2.3（`is_solid` 越界默认 `true`）** [BLOCKING][Logic]
GIVEN 越界坐标，WHEN 调用 `is_solid(cell)`，THEN 返回 `true`。
> 必须单独验证 —— 这条与直觉相反（越界≠"未知"/false），极易被写反。

### H.10 `is_solid` 公式（D.3 🔴 access 排除）

**AC-D3.1** [BLOCKING][Logic] GIVEN `buildable=true, occupant_id=-1, access_ids=[7]`，WHEN 查询 `is_solid`，THEN 返回 `false`。
> **本系统第二高危断言** —— 若实现者把非空 `access_ids` 也算"有东西"，本测试必须失败并暴露问题。

**AC-D3.2** [BLOCKING][Logic] GIVEN `buildable=true, occupant_id=7`，WHEN 查询 `is_solid`（无论该格 `access_ids` 是否非空），THEN 恒返回 `true` —— 双向验证 `access_ids` 完全不参与判定。

**AC-D3.3** [BLOCKING][Logic] GIVEN `buildable=false`，WHEN 查询 `is_solid`（无论 `occupant_id` 为何），THEN 恒返回 `true`。

**AC-D3.4（🔴 `occupant_id = 0` —— GDScript falsy 陷阱）** [BLOCKING][Logic]
GIVEN `buildable=true`，格 `(2,2)` 被 **`instance_id = 0`** 的器械 footprint 占用（`commit(0, footprint=[(2,2)], access=[])`），WHEN 查询 `is_solid((2,2))`，THEN 返回 **`true`**；且 `get_occupant_id((2,2))` 返回 **`0`**（不是 `-1`）。

> **🔴 为何必须单列且必须用 id=0**：`0` 是**完全合法的 `instance_id`** —— 按规则7 的生命周期契约（单调递增、从 0 起、`>= 0`），它正是**整局游戏第一台被放下的器械**。但 D.3 公式 `occupant_id != -1` 有一个 GDScript 特有的手滑写法：
>
> ```gdscript
> # ❌ 错误 —— 在 GDScript 里 0 是 falsy
> if occupant_id:              # id=0 时为 false → 这格被判定为"空"
>     return true
>
> # ✅ 正确 —— 必须与哨兵显式比较
> if occupant_id != -1:
> ```
>
> 后果是**整局第一台放下的器械对 `is_solid` 完全隐形** —— 小人径直穿过它，而它在画面上明明就在那儿。这是 B 节"沉默的坏读取"的教科书级实例：不报错、不崩溃，且**只影响一台器械**（第二台起 id≥1 是 truthy，行为完全正常）—— 这种"只有第一个坏"的形状极难在手动试玩中被归因。
>
> **本 GDD 其余所有 AC 的 fixture 一律使用 `id=7` / `id=9` 等非零值，因此在本条之前，这个 bug 对整个测试套件是完全不可见的。** 本条的成本是一个 fixture 常量，收益是消除一整类静默失败。**新增测试时应优先考虑 id=0 作为 fixture 值。**

### H.11 坐标换算（D.4）

**AC-D4.1** [BLOCKING][Logic] GIVEN `cell_size=32`（**测试占位值，与最终架构决策无关**），`cell=(5,3)`，WHEN 调用 `grid_to_world_corner` / `grid_to_world_center` / `world_to_grid`，THEN 分别返回 `(160,96)`、`(176,112)`，且 `world_to_grid((170,100)) == (5,3)` —— 三者往返一致性一次覆盖。

### H.12 声明包围盒 + debug assert（D.5）

> #### 🔴 assert 类 AC 的捕获机制（AC-D5.2 / AC-D5.3 / AC-D1.1 共用前提）
>
> 以下三条 BLOCKING AC（**AC-D5.2、AC-D5.3、以及 H.12b 的 AC-D1.1**）都要求断言"`assert()` 被触发"。**但 Godot 的 `assert()` 失败会中止脚本执行 —— 一个朴素的 GUT 测试写法会让整个测试进程崩溃，而不是记录一次"预期内的失败"。** 本 GDD 此前只说了"THEN assert() 触发"，没说**测试框架该如何观测到它** —— 两个实现者会据此造出互不兼容的 harness（一个把崩溃当成通过，一个完全不知道怎么写而跳过该检查）。
>
> **🔴 因此：这三条 AC 的捕获机制归架构阶段统一决定，且必须在写第一个 GridSystem 测试之前定下来。** 见 **Open Question #14**。可选路径（架构阶段择一，不在此预判）：
>
> 1. **GUT 的错误捕获辅助**（如 `assert_script_error` 类 API，若 GUT 当前版本提供）—— 首选，若可用
> 2. **子进程隔离**：在独立的 `godot --headless` 子进程里跑该调用，断言其**退出码与 stderr 内容**，主测试进程不受影响
> 3. **把三条 assert AC 降级为 `[ADVISORY][代码审查]`** —— 仅当 1、2 都不可行时的兜底：断言"实现中存在该 assert 语句"由代码审查覆盖
>
> **在 OQ#14 解决之前，这三条 AC 的 BLOCKING 状态成立、但其测试写法未定** —— 实现者**不得**自行发明一套 harness，须先解决 OQ#14。**这不是拖延**：三条 AC 依赖同一个机制，各写各的必然产生三种不兼容写法，而这正是"建议的测试文件组织"一节把它们隔离进 `grid_system_debug_assert_test.gd` 单独文件的原因 —— 那个文件的存在本就预设了它有一套自己的规矩。

**AC-D5.1** [BLOCKING][Logic] GIVEN `footprint=[(0,0),(1,0),(0,1),(1,1)]`、`access=[(0,2)]`，WHEN 调用 `declared_bounds`，THEN 返回 `(W=2,H=3)`。

**AC-D5.2（debug assert —— 锚点约定）** [BLOCKING][Logic]
GIVEN 一个违反锚点约定的手搓 `equipment_def`（`min_offset != (0,0)`），WHEN 在 **debug/editor 构建**下调用 `get_transformed_cells` 或 `declared_bounds`，THEN `assert()` 触发并中止执行（而非返回一个错误的旋转结果）。
> **测试环境要求**：`godot --headless` 默认跑非导出构建，`assert()` 生效 —— 本条在 CI 里可正常跑。**但不得在导出的 release 构建上跑这条**（`assert` 在 release 被编译期剔除，属预期行为，不是回归）。

**AC-D5.3（debug assert —— 空 footprint）** [BLOCKING][Logic]
GIVEN `footprint_cells=[]`，WHEN 在 debug 构建下调用 `get_transformed_cells`，THEN `assert()` 触发。

**AC-D5.4（release 未定义行为 —— 显式记录，非通过标准）** [ADVISORY][文档]
GIVEN 一个 release（导出）构建，WHEN 以 `footprint_cells=[]` 或违反锚点约定的 `equipment_def` 调用 `get_transformed_cells`，THEN 行为**未定义** —— 本条**不断言任何具体结果**。
> **本条是一条被承认的缺口记录，不是一个测试。** 见 D.5"Release 构建下的未定义行为"表：`assert()` 在 release 被编译期剔除，且 GridSystem 生产路径有意不做运行时防御（热路径成本 vs. 一个只能由内部 bug 触发、且必被 debug/CI assert 抓到的输入）。真正的门是 **EquipmentCatalog 加载期校验**。
>
> **写成 AC 的唯一目的**：让这个取舍在验收清单里**可见**。若未来 EquipmentCatalog 的加载期校验被削弱或绕过（如引入运行时生成的 `equipment_def`），本条即刻升级为 BLOCKING，届时必须补运行时防御。**不得因为"debug 测试都过了"就认为这一类输入是安全的。**
>
> **🔴 但"若校验被削弱则升级"这句话本身需要一个探测机制，否则它只是散文。** 上一句话把本 AC 的有效性完全押在一个**尚不存在的 GDD**（EquipmentCatalog，设计顺序 #2）会做某件事上 —— 而**没有任何机制**会在那件事没做时通知任何人。这与 OQ#7（性能回填）是**同一类缺陷**："一个没有门的要求不是要求"—— 而 OQ#7 已被判定必须加硬门禁。**本文档不能对自己的两个同类缺口给两个标准。**
>
> **因此本条的真正的门是 Open Question #13**：EquipmentCatalog GDD **必须**携带本 GDD 的对偶要求（加载期校验 `footprint_cells` 非空、锚点约定 `min == (0,0)`、`access` 不与自身 footprint 重叠），且该要求在 `/create-architecture` 阶段被逐条核对。**若 EquipmentCatalog GDD 未接住这三条，本 AC 立即升级为 BLOCKING，GridSystem 必须补运行时防御** —— 届时"热路径成本"的论证不再成立，因为它的前提（"有 EquipmentCatalog 这道加载期门"）已经不成立了。

### H.12b `rotation` 取值域（D.1）

**AC-D1.1（非法 rotation 不得静默回退）** [BLOCKING][Logic]
GIVEN 一个非法 `rotation` 值（如 `45`、`-90`、`360`），WHEN 在 debug 构建下调用 `get_transformed_cells`，THEN 兜底分支的 `assert(false, "非法 rotation")` **触发**。
> **🔴 必须显式断言"不是静默回退到 0°"**：D.1 的 4 个分支无一匹配非法值时，实现里一个顺手的 `else: return (x, y)` 会把一个调用方 bug 变成**一台朝向错误但看起来完全正常的器械** —— 玩家看到的是"我明明转了 90° 它却没转"，而系统一声不吭。这是 B 节"沉默可信度"的教科书级违反。
>
> **实现约束**（见 D.5）：`rotation` 必须声明为 GDScript `enum Rotation { R0 = 0, R90 = 90, R180 = 180, R270 = 270 }` 而非裸 `int`，让类型系统先拦一道；本 AC 覆盖的是类型系统被绕过后（如从存档/字典读进来的裸 int）的兜底行为。

**AC-D1.2（4 个合法值全覆盖）** [BLOCKING][Logic]
已由 AC-C4.1 / AC-C4.2 覆盖（两个 fixture 各穷举 4 朝向），此处不重复。

### H.13 `GridStateReader` 接口一致性

**AC-GSR.1（多态一致性）** [BLOCKING][Logic]
GIVEN 相同的底层网格状态，一份来自 `GridSystem` 本体、一份来自它的 `get_snapshot()`，WHEN 对两者调用同一组 `is_solid`/`get_occupant_id`/`get_access_cells`/`get_dimensions`，THEN 返回值逐一相等。
> 这也验证 `ZoneRules.evaluate(snapshot: GridStateReader)` 换成传真实 `GridSystem` 实例同样能工作 —— 这正是抽象基类要保证的。

**AC-GSR.2（`get_dimensions`）** [BLOCKING][Logic]
GIVEN `width=13,height=10` 的网格，WHEN 调用 `get_dimensions()`，THEN 返回 `Vector2i(13,10)`，且 `get_snapshot()` 之后维度不变。

**AC-GSR.3（写方法不可从基类访问）** [ADVISORY][代码审查]
GIVEN 一个类型声明为 `GridStateReader` 的变量持有 `GridSnapshot` 实例，WHEN 静态检查该变量的可调用方法集合，THEN `_commit_in_place`/`_clear_in_place` 不在 `GridStateReader` 声明的方法列表中。
> **本条用 GDScript 静态类型检查或代码审查清单覆盖，不写成 GUT 断言** —— GDScript 无真正访问控制，C 节自己已承认这是"软防护"。把它伪装成运行时可测的硬门禁反而不诚实。

### H.14 快照语义与推测快照隔离

**AC-X.2（深拷贝语义）** [BLOCKING][Logic]
GIVEN 一个 `get_snapshot()` 结果，WHEN 之后对真实网格执行 `commit`/`clear`，THEN 之前取到的快照对象的值**不发生变化**。

**AC-X.3（推测快照不触碰真实存储）** [BLOCKING][Logic]
GIVEN 真实网格状态 S，WHEN 调用 `get_speculative_snapshot(deltas)` 并对返回快照执行任意 `_commit_in_place`/`_clear_in_place`，THEN 真实网格状态仍为 S（用 `get_snapshot()` 复核），且未发出 `grid_changed`。

### H.15 跨系统集成

**AC-X.1（Navigation 消费 solidity，不感知 access）** [BLOCKING][Integration]
GIVEN 器械 A 的 access 格 `(2,2)` 无 footprint 覆盖，WHEN Navigation 通过 `get_solidity_snapshot()` 读取该格，THEN 返回值表示"非 solid"（`0`）。可选：联动最小 `AStarGrid2D` fixture 验证路径可穿过 `(2,2)`。

**AC-X.4（SelectionSystem 只拿整数 id —— 负向）** [BLOCKING][Logic]
GIVEN 器械 A 已 commit，WHEN `get_occupant_id(cell)` 被调用，THEN 返回值是纯 `int`，GridSystem 侧不解析、不校验这个 id 对应什么 `EquipmentInstance`。

### H.16 负向标准（锁死"不归 GridSystem 管"的边界）

**AC-NEG.1** [BLOCKING][Logic] GIVEN 两个不同 id 的器械声明同一个 access cell 为使用位，WHEN 查询该格 `is_solid`，THEN 结果**恒为 `false`** —— 不因"有争用"被判定为 solid。
> 这条是防止未来有人"顺手"在 GridSystem 里加锁/仲裁逻辑的护栏。

**AC-NEG.2** [BLOCKING][Logic] GIVEN 一个器械的所有 access cell 都被其他器械 footprint 完全包围（不可达），WHEN **逐一**调用下列**穷举的**公开接口，THEN 每个的返回值/错误码中**都不含任何可达性相关的信息**：

| 接口 | 断言 |
|---|---|
| `can_place(def, anchor, rot)` | 返回 `{valid: true}`（不因"放下去就没人能用"而 FAIL，也不含 warning 字段） |
| `commit(id, ...)` | 正常成功，不 `push_error()` |
| `is_solid(cell)` | 仅由 `!buildable OR occupant_id != -1` 决定，与可达性无关 |
| `get_occupant_id(cell)` | 返回 int，无特殊哨兵表示"不可达" |
| `get_access_cells(id)` | 返回**全部**静态归属 access 格，**不过滤**掉不可达的 |
| `get_snapshot()` / `get_speculative_snapshot()` | 快照结构中不含任何可达性字段 |
| `serialize()` | 输出的 `PlacementRecord` 不含可达性字段 |
| `clear(id)` | 正常成功 |

> **原文写的是"查询任意公开接口"—— 那是不可测的**（"任意"无法穷举，一个通用负向断言不构成测试）。上表把它收敛成一个**有限、可执行**的清单：这就是 GridSystem 的**全部**公开 API 面，逐个断言即可。
>
> **本条的真正作用是护栏**：它锁死的不是某个 bug，而是**未来某人"顺手"在 GridSystem 里加可达性判断**的冲动。若有人新增一个公开方法并让它返回可达性信息，本表就必须相应扩表 —— **那一刻正是代码审查该问"这真的归 GridSystem 管吗"的时刻**（答案见 E 节划界：不归）。

### H.17 性能标准（数值系外推 —— 但工况冒烟测试为 BLOCKING）

> ⚠️ **AC-PERF.1 / AC-PERF.2 的具体数值为 ADVISORY，不阻塞故事 Complete。AC-PERF.3 是 BLOCKING。**
>
> C 节记录的实测数字（`PackedInt32Array.duplicate()` 3600格=0.04μs；`set_point_solid()` 单次=0.14μs）测的是**别的操作** —— 前者是快照底层的拷贝原语，后者是 **Navigation 调 `AStarGrid2D` 的开销，不是 GridSystem 自己的方法**。GridSystem 真正暴露的 `get_snapshot()`/`commit()`/`clear()`/`can_place()` **没有任何直接实测数字**。以下 PERF.1/2 是**外推**，不是承诺值。

**AC-PERF.1** [ADVISORY] GIVEN MVP 房间规模（13×10=130 格，~5-6 件已放置器械），WHEN 调用 `get_snapshot()`，THEN 期望单次 < 100μs（外推自 C 节记录的"~300 格约 12μs"，留 8 倍安全余量）。

**AC-PERF.2** [ADVISORY] GIVEN MVP 器械声明包围盒上限 ~3×3=9 格，WHEN 调用单次 `commit()`/`clear()`，THEN 期望 < 50μs（外推自 `set_point_solid()` 单格 0.14μs 的量级，同为"写单个 PackedArray 槽位"操作）。

**AC-PERF.3（拖拽工况冒烟测试）** [BLOCKING][Integration]
GIVEN MVP 房间规模（13×10=130 格）且**背景状态必须满足以下三条 fixture 约束**：

| fixture 约束 | 要求 | 为何这条不可省 |
|---|---|---|
| **已放置器械数** | 5–6 件 | MVP 规模 |
| **🔴 `access_ids` 稀疏度** | **10–20 个非空 access 格，散布在 130 格中**（即 ~8–15% 填充率），**不得**用稠密填充的字典 | 见下方 🔴 |
| **🔴 拖拽路径** | 300 次调用的 `deltas` 中 **anchor_cell 必须逐次变化**，沿一条真实的鼠标轨迹移动（如横穿房间的折线），**不得**重复同一个 delta 300 次 | 见下方 🔴 |

WHEN 模拟一次真实拖拽 —— **连续 300 次** `get_speculative_snapshot(deltas)` 调用（≈5 秒 @60fps），每次带 1 件器械的真实 deltas —— THEN **全部 300 次总耗时 < 50ms**，且**单次最大耗时 < 5ms**（**第 1 次调用可从"单次最大"断言中排除**，冷启动/首次分配不代表稳态工况；但它**仍计入总耗时**）。

> **🔴 为何 fixture 的稀疏度约束是这条 AC 成立的前提，而不是一个细节**：选 `Dictionary` 存 `access_ids` 的**全部理由**就是"大多数格为空"（规则2）。若本测试用一个稠密填充的网格做 fixture，它就**在原理上无法失败于它被创造出来要抓的那个缺陷** —— 一条测不到自己目标的 AC 不是一条宽松的 AC，是一条**缺陷 AC**。这也正是"快照语义"一节 ⚠️ 注里点名的"测错数据形状"问题在 AC 层的对偶：那一节批评现有基准测的是稠密字典，若这条 AC 自己也用稠密 fixture，就把同一个错误又犯了一遍。
>
> **🔴 为何 anchor 必须逐次变化**：重复同一个 delta 300 次会让每次调用的写入落在**同一批格子**上，这是分支预测与缓存的最优情况，且可能让实现里任何形式的缓存/短路生效 —— 那测的是"重复调用同一输入"的开销，不是拖拽。真实拖拽每帧写的是**不同的格子**。

> **测试环境基线**：本条在 `godot --headless` 下跑，**以 CI runner 为基准环境**。**门槛刻意定得极松正是为了容纳硬件差异** —— 若某台开发机上跑出 60ms 而 CI 上是 20ms，那不是回归；本条要抓的是"慢了 1000 倍"，不是 3 倍的机器差异。**不得因为本地机器慢就放宽阈值** —— 以 CI 结果为准。

> **🔴 为何这一条是 BLOCKING 而其余是 ADVISORY**：B 节把拖拽时的任何一次"咦？"定为本系统**唯一**的失败模式，而 `get_snapshot()` 在快速拖拽下的开销是全文档**最贴近玩家感知**的性能路径 —— 它直接决定那个"啪地吸附到位、玩家想都没想"的锚定瞬间成不成立。把它**只**挂在一个"记得以后补测"的 Open Question 上（无强制机制），意味着一次真实的性能回归可以**静默上线**。
>
> **门槛刻意定得很松**（50ms / 300 次 = 平均 167μs/次，比 AC-PERF.1 的外推值还宽 1.6 倍；单次 5ms 是帧预算的 30%）。**这不是性能预算，是回归警报** —— 它的作用不是证明快，而是保证"慢了 1000 倍"这种事在 CI 里会响。精确预算等 Open Question #7 的实测数字回填后再作为 ADVISORY 收紧。
>
> **必须测"连续 N 次"而非"单次"**：单次微基准在原理上无法反映持续每帧构造/丢弃快照对象的分配器压力（碎片化、分配开销方差）—— 而那正是拖拽的真实工况。**"单次最大耗时"这个断言就是专门用来抓方差的**：若某一帧因为分配器抖动飙到 5ms，玩家会看到一次卡顿，而平均值会把它藏起来。

> **🔴 首次实现后须跑一次 `godot --headless` 基准脚本补实测数字并回填 PERF.1/2**（Open Question #7，**硬截止：Vertical Slice 门禁之前**），而非长期采信此处的外推值。基准脚本须覆盖：
> - `get_snapshot()` / `commit()` / `clear()` / `can_place()` 各自的单次实测
> - **`access_ids` 字典在 MVP 真实稀疏度下的 `duplicate()` 开销**（130 格中填 10–20 条），而非现有的"3600 稠密条目按比例缩放"—— 见"快照语义"一节的 ⚠️ 注

### 建议的测试文件组织

```
tests/unit/grid_system/
├── grid_system_rotation_test.gd        # AC-C4.1~4.3（最高优先级）
├── grid_system_solidity_test.gd        # AC-D3.1~3.4, AC-C5.1（含 AC-D3.4 的 id=0 fixture）
├── grid_system_bounds_test.gd          # AC-D2.x
├── grid_system_placement_test.gd       # AC-C6.x, AC-C5.2~5.4
├── grid_system_commit_clear_test.gd    # AC-C7.1~7.3, AC-C2.x
├── grid_system_snapshot_test.gd        # AC-X.2, AC-X.3
├── grid_system_signals_test.gd         # AC-C7.4~7.6
├── grid_system_coords_test.gd          # AC-D4.1, AC-D5.1
├── grid_system_serialization_test.gd   # AC-C8.1~8.10
├── grid_system_state_reader_test.gd    # AC-GSR.1~GSR.2
└── grid_system_debug_assert_test.gd    # AC-D5.2~5.3, AC-D1.1（debug-only；🔴 捕获机制待 OQ#14）

tests/integration/grid_system/
├── grid_navigation_solidity_test.gd    # AC-X.1
└── grid_perf_drag_smoke_test.gd        # AC-PERF.3（🔴 fixture 须满足稀疏度 + 真实拖拽路径约束）
```

> **`grid_system_rotation_test.gd` 与 `grid_system_solidity_test.gd` 独立成文件**：这两组对应全 GDD 标红的两个最高危点，独立文件让 CI 失败信息一眼定位到具体风险，而不是淹没在几百行的大文件里。
>
> **`grid_system_debug_assert_test.gd` 独立成文件**：这是唯一一组"预期行为依赖构建配置（debug vs release）"的测试。混进其他文件的话，未来某次 CI 配置调整（如误用导出模板跑测试）会产生难以定位的假失败。

## Open Questions

| # | 问题 | Owner | 目标解决时点 | 现状 |
|---|---|---|---|---|
| 1 | **`cell_size` 取 16 还是 32 逻辑像素？** | architecture | `/create-architecture` | art-bible §8 已写明"架构阶段最终确定"。本 GDD 只钉死 D.4 的公式形态，不填数值。GridSystem 内部逻辑完全不依赖它的值 |
| 2 | **`grid_width=13` / `grid_height=10` 是否是对的？** | prototype | `/prototype` 的 fun-validation 里程碑（设计顺序 #8 之后） | MVP 假设值，**非终值**。game-concept 已把"空间深度 vs 松弛感"列为最高设计风险且写明"只能靠原型验证"。房间尺寸是这个平衡最直接的旋钮（见 G 节） |
| 3 | **`@abstract`（用于 `GridStateReader`）在 4.7.1 是否真的可用？** | architecture | **`/create-architecture`（硬门禁）** | `breaking-changes.md` 记载它是 4.5 新增，风险低 —— **但本项目尚未在本地 4.7.1 实测验证过**。**兜底不是"退化为命名约定"就完事**：见"`GridStateReader`"一节的三步验证与兜底协议 —— 若漏覆写不是硬报错，基类**必须**带 `push_error()` + 安全默认值的实体桩 |
| 4 | **Congestion 是否直接订阅 `grid_changed`？** | Congestion GDD | 设计顺序 #7 | 本 GDD 列为**软**依赖；但 systems-index 里 Congestion 的依赖只有 `Navigation, MemberSim`，未列 GridSystem。两种解读都成立。若 Congestion GDD 选择直接订阅，**需回头更新索引的依赖表**。本 GDD 不单方面改索引 |
| 5 | **`AStarGrid2D` 的 `diagonal_mode` / `jumping_enabled` 取值？** | Navigation GDD | 设计顺序 #5 | 实测：`diagonal_mode` 默认 `ALWAYS` 会让小人从两个 solid 对角格的缝隙**斜穿过去**（"穿墙角"）；`ONLY_IF_NO_OBSTACLES` 能正确阻止。`jumping_enabled` 默认 false，开启后路径点从 10 降到 2（纯搜索优化）。**决策归 Navigation，本 GDD 只记录实测发现** |
| 6 | **`AStarGrid2D` 的 `set_point_solid()` 设置顺序是否绝对不影响最终路径？** | Navigation GDD | 设计顺序 #5 | **MEDIUM 风险，推断但未直接实测**。⚠️ **注意 D.7 的 ✅ 实测结论并不覆盖本条** —— 它测的是"相同顺序 → 相同路径"，本条问的是"**不同顺序、相同最终状态** → 相同路径"。后者才是读档所需（`deserialize()` 按 `instance_id` 升序重放，与玩家原始放置顺序无关）。原理上（扁平布尔数组按索引写）应与顺序无关，且本 GDD 用 `PackedInt32Array`/`PackedByteArray` 按索引写基本消除该风险 —— **但"基本消除"不是"已验证"** |
| 7 | **GridSystem 自身方法的真实性能数字？** | 首次实现者 | **🔴 硬截止：Vertical Slice 门禁之前**（不是"想起来再说"） | H.17 的 PERF.1/2 全是**外推**，不是实测 —— C 节记录的两个实测数字测的是别的操作，且 `Dictionary` 那个很可能测的是稠密形状而非生产的稀疏形状。须跑 `godot --headless` 基准脚本补实测并回填。**注意 AC-PERF.3（拖拽工况冒烟）已是 BLOCKING，不等本条** —— 本条只影响 PERF.1/2 精确预算的收紧 |
| 8 | **MVP 阶段房间包围盒是否允许在放置器械之后被改变？** | game-designer | Vertical Slice 规划时 | **MVP 答案是"否"**（Q3 已定：`buildable` 加载时固定、运行时只读）。故 C 节"改 `region` 会清空 solid 标记"那条在 MVP 内是纯文档性的。VS 引入"扩建一间房"时此问题转为实际约束，届时需实现 `grid_resized` 全量重建路径 |
| 9 | **"access 受阻 / 零可达"由谁向玩家呈现，且是否默认可见？** | Congestion / Overlay GDD | 设计顺序 #7–#8 | **本 GDD 交出去的具名需求**（见 E 节"明确不归 GridSystem 管的边界"）。本 GDD 选择放置时不警告，前提是**下游必须接住**且呈现必须是**环境性的**（不能只藏在一个默认关闭的 overlay 开关后）。**这不是打磨项，是本设计成立的前提条件** |
| 10 | **`instance_id` 分配器的具体归属与实现？** | PlacementSystem GDD | 设计顺序 #4 | 本 GDD 规定了**硬契约**（`>= 0`、单调递增、会话内永不复用、读档后从 `max(已加载 id)+1` 续）见 C 节规则7。**GridSystem 无法二次校验"复用"**（复用的 id 与全新 id 在它看来完全一样，见 AC-C7.8）—— 这条只能由分配器保证 |
| 11 | **矩形（AABB）footprint 这一永久约束是否要立 ADR？** | architecture | `/create-architecture` | 本 GDD 的旋转/包围盒机制建立在"footprint 是矩形集合"之上。作为依赖图的根，这实际上**为整个项目排除了 L 形/非矩形器械**。MVP（5–6 件器械）完全够用，**但这应是一个被选择的约束，而不是被发现的约束** —— 建议立 ADR 记录取舍（vs. 支柱1 的长期空间深度） |
| 12 | **存档 `records` 规模增长后是否维持"全失败"策略？** | SaveLoad GDD | **触发条件：预期 records > ~200 时** | MVP 决策：**维持全失败**（见 C 节规则8 的 accepted-risk 表 —— 响亮的错优于静默的错）。但该决策的前提是 records 数在个位到十位。VS 的多房间/扩建或 Tier 2 连锁会打破这个前提，届时须重评（每条 record 独立校验和 + 隔离损坏记录 + **明确告知玩家**，而非静默部分恢复） |
| 13 | **EquipmentCatalog 是否接住了 GridSystem 交出去的三条加载期校验？** | EquipmentCatalog GDD | ✅ **规则层已接住（2026-07-17）**；`/create-architecture`（硬门禁，核对**实现**是否忠实执行） | **本 GDD "生产路径不做运行时防御"这一决策成立的前提条件。** D.5 的"Release 构建下的未定义行为"表把三类非法 `equipment_def` 的真正的门指给了 EquipmentCatalog 加载期校验：（a）`footprint_cells` 非空；（b）并集包围盒 `min == (0,0)`（锚点约定）；（c）`access` 不与自身 footprint 重叠。**EquipmentCatalog GDD（`design/gdd/equipment-catalog.md`）已逐条接住**（其 Core Rule 6 (a)(b)(c)(d)），并将附带项 access 数量上限确认为 **`N=1`**（其 Core Rule 4）。若 `/create-architecture` 阶段发现实现未忠实执行这些规则，AC-D5.4 仍会升级为 BLOCKING —— 门禁性质从"规则是否存在"变为"实现是否合规" |
| 14 | **`assert()` 触发在 GUT 里如何被捕获为"预期内失败"而非进程崩溃？** | architecture | **`/create-architecture`（硬门禁，须早于第一个 GridSystem 测试）** | **三条 BLOCKING AC（AC-D5.2 / AC-D5.3 / AC-D1.1）共同依赖这一个未定义的机制。** Godot 的 `assert()` 失败中止脚本执行；朴素写法会让整个测试进程崩溃。见 H.12 顶部的捕获机制说明：候选路径为（1）GUT 的错误捕获辅助（若当前版本提供）；（2）子进程隔离 + 断言退出码/stderr；（3）兜底 —— 降级为 `[ADVISORY][代码审查]`。**实现者不得自行发明 harness** —— 三条 AC 各写各的必然产生三种不兼容写法 |

> **无阻塞项。** 以上均为交接点或待校准项 —— 没有一条阻止 GridSystem 进入架构或实现阶段。
>
> **但 #3 / #7 / #9 / #13 / #14 有硬门禁，不是"有空再说"**：
> - **#3**（`@abstract` 实测）在 `/create-architecture` 前必须实测并按协议兜底
> - **#7**（性能回填）在 Vertical Slice 门禁前必须补实测
> - **#9**（可达性呈现）是本 GDD "放置时不警告"这一设计成立的**前提条件**，必须在 Congestion/Overlay GDD 里被接住
> - **#13**（EquipmentCatalog 对偶校验）是本 GDD "生产路径不做运行时防御"这一决策成立的**前提条件**——✅ 规则层已由 `design/gdd/equipment-catalog.md` 接住，`/create-architecture` 阶段核对的是**实现**是否忠实执行；若实现未合规，AC-D5.4 仍升级为 BLOCKING
> - **#14**（assert 捕获机制）须早于第一个 GridSystem 测试解决，否则三条 BLOCKING AC 无法被一致地实现
>
> **#9 与 #13 曾是同一个形状的东西**：两者都是"本 GDD 的某个设计选择制造了一个空洞，并把填补它的责任交给了下游 GDD"。#9 交出去的是**玩家可见性**（Congestion/Overlay GDD 尚未落地，风险仍在）；#13 交出去的是**数据合法性**（EquipmentCatalog GDD 已落地并接住规则，风险从"下游会不会做"降级为"实现会不会忠实执行"）。两者剩余的共同风险：**交接只是一段文字，没有任何机制强制下游作者回读本文档**——这正是它们必须留在硬门禁列表、并在 `/create-architecture` 阶段逐条核对的原因。
