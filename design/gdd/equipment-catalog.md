# EquipmentCatalog

> **Status**: ✅ Approved（2026-07-19 独立复审；2026-07-20 文档陈旧性更新 + 双向一致性核对状态刷新）
> **Author**: user + agents
> **Last Updated**: 2026-07-20
> **Implements Pillar**: Pillar 1 (空间即玩法), Pillar 3 (一眼看懂，越品越深)

## Overview

EquipmentCatalog 是撸铁大亨的器械数据基础设施层：一份**不可变、只读**的器械定义集合。每条定义声明该器械的网格占位形状（`footprint_cells`）、使用位（`access_cells`）、购买成本、静态效果（区域协同/满意度加成等）与区域归属（zone membership）。

玩家不会直接"操作"这个系统——它是纯数据来源，被其他系统间接消费：PlacementSystem 在拖放时读取器械定义构造 `equipment_def` 传给 GridSystem 做占位校验；ZoneRules 读取它计算区域协同效果；Shop/Purchase 读取它展示价格与解锁状态；Equipment Info Panel（VS 阶段）读取它展示器械详情。

没有它，游戏里就不存在"这个世界上有哪些器械、每件占多大、多少钱、有什么效果"的单一权威来源——每个消费系统都得自己维护一份定义，必然导致数据分裂：同一件器械在商店浏览界面和放置预览里显示的效果可能对不上，直接破坏支柱3"一眼看懂"的可预测性承诺。

## Player Fantasy

EquipmentCatalog 本身没有独立的玩家幻想——它是纯基础设施，玩家从不会"感受"这份数据表本身。玩家感受到的是它支撑的下游体验：

- 通过 **PlacementSystem**：玩家拖放器械时看到的吸附形状、旋转行为，数据来源就是这里的 `footprint_cells`/`access_cells`；
- 通过 **Shop/Purchase**：玩家看到的价格标签、可负担性判断，数据来源是这里的 `cost`；
- 通过 **ZoneRules** 与 **Equipment Info Panel**：玩家看到的"+舒适度""区域协同"反馈，数据来源是这里的 `effects`/`zone_membership`。

这份 GDD 的成功标准不是"玩家喜欢这个系统"，而是"玩家从未意识到这个系统的存在，因为它让上面这些体验保持一致、可预测"——这正是支柱3"一眼看懂"成立的地基：如果同一件跑步机在商店里显示的效果和实际放置后的效果不一致，"一眼看懂"就会碎掉，而根源永远会追到这里。

## Detailed Design

### Core Rules

1. **数据形态（EquipmentDef）**——每条器械定义是一条不可变记录，包含以下字段：

| 字段 | 类型 | 说明 |
|---|---|---|
| `id` | String | 全局唯一稳定标识符，跨存档不变 |
| `display_name` | String | 玩家可见名称（UI 消费） |
| `zone_membership` | String / Array[String] | 器械所属区域（力量区/有氧区/…），供 ZoneRules 计算协同 |
| `footprint_cells` | Array[Vector2i] | canonical(0°) 占地格，见规则3 |
| `access_cells` | Array[Vector2i] | canonical(0°) 使用位，**固定 1 格**，见规则4 |
| `cost` | int | 购买价格（Shop/Purchase 消费） |
| `unlock_requirement` | String / null | 解锁条件标识符（如里程碑 id），`null` 表示从开局可用。**本字段只声明条件，不持有"当前是否已解锁"这个运行时状态**——那是 Progression/Unlocks（VS 阶段）或存档系统的职责 |
| `effects` | Array[{tag: String, magnitude: float}] | 静态效果的**抽象容器**。具体 tag 词表（如 `comfort`、`crowd_pressure`）由 ZoneRules GDD 定义并登记进 registry；本 GDD 只锁定容器形状，不预先枚举 tag 值 |
| `use_duration_mean_ticks` | int | 会员使用此器械的**平均**时长（tick，10 tick/s）。MemberSim #6 `use_duration` 公式的均值参数。MVP 锚点 150–250（15–25 s）。加载期校验见规则7 (e) |
| `use_duration_stddev_ticks` | int | 使用时长高斯抖动的标准差（tick）。MVP 锚点 ≈ 15–20% 的 mean。允许 0（确定性时长，无抖动） |
| `use_duration_min_ticks` | int | 使用时长**下限**（tick）；MemberSim `use_duration` 公式的 clamp 下界。MVP 锚点 ≈ 0.5×mean |
| `use_duration_max_ticks` | int | 使用时长**上限**（tick）；MemberSim `use_duration` 公式的 clamp 上界。MVP 锚点 ≈ 1.5×mean |

2. **不可变契约**：所有 `EquipmentDef` 在游戏/会话启动时从外部数据加载一次（符合 coding-standards"数据驱动，禁止硬编码数值"），加载完成后整个 Catalog **冻结**，运行时任何系统都不得写入。这是它能被多个高扇入下游系统（PlacementSystem/ZoneRules/Shop/InfoPanel）安全并发读取而不加锁的前提。
   - **执行机制**（设计层契约，不涉及具体存储技术选型）：Catalog 只对外暴露**只读查询接口**（如 `get_definition(id) -> EquipmentDef`）；不提供任何写入/修改方法，调用方无法通过公开 API 获得可变引用或修改已加载的定义。可验证性：对同一 `id` 反复查询必须返回值相等的结果；公开接口中不存在任何 setter/mutator。

3. **footprint 形状锁定**（交叉引用 art-bible.md:94）：`footprint_cells` 自身的包围盒必须恰好是以下三种矩形之一（不含空洞、不含 L 形——呼应 GridSystem OQ#11 的"矩形 AABB 是永久约束"）：
   - `1×1`：`{(0,0)}`
   - `1×2`：`{(0,0),(1,0)}`（横竖由旋转在运行时处理，canonical 定义只需是一条直线）
   - `2×2`：`{(0,0),(1,0),(0,1),(1,1)}`

4. **access cell 数量与相邻规则**（MVP 简化，直接决定 GridSystem 交接的 `N`）：
   - 每条器械定义**恰好 1 个** `access_cells` 条目（`N = 1`）。
   - 该 access cell 必须与 `footprint_cells` 中至少一个格子**正交相邻（共边）**——不允许对角相邻，也不允许任意远的坐标（防止 grid-system.md 中点名的"`footprint=[(0,0)]` 配 `access=[(5,5)]`"式的数据错误）。
   - **数学保证**：footprint 最大 `2×2`（规则3）+ access 与其正交相邻（最多向外扩 1 格）⇒ `footprint ∪ access` 的并集包围盒**恒 ≤ 3×3**。这正是 GridSystem `declared_bounds` 公式假设的上界，规则3+4 共同构成对该假设的**证明**，而不只是承诺。

5. **归一化/锚点规则**（接住 GridSystem 交接项 (b)）：`footprint_cells` 与 `access_cells` 在**同一局部坐标系**中定义（不要求 footprint 自身从 `(0,0)` 起——若 access 在 footprint 左侧/上方，access 才可能是 `(0,0)`）。加载期归一化算法：
   1. 计算并集 `footprint_cells ∪ access_cells` 的 `min_x`、`min_y`。
   2. 将 `footprint_cells` 与 `access_cells` 中每个坐标**同时**减去 `(min_x, min_y)`。
   3. 归一化后必须有 `min_x == 0 且 min_y == 0`——加载器对每条数据强制执行该算法，不依赖美术/策划手工对齐。

6. **加载期校验契约**（直接接住 grid-system.md Open Question #13 的三项要求，`/create-architecture` 阶段硬门禁核对）：加载器必须对每条 `EquipmentDef` 依次校验，任一失败即该条记录加载失败（具体失败处理见 Edge Cases）：
   - **(a)** `footprint_cells` 非空（规则3的矩形形状本身已保证非空，此处是防御性冗余校验，防手写数据绕过）
   - **(b)** 归一化后并集包围盒 `min == (0,0)`（规则5的直接校验）
   - **(c)** `access_cells ∩ footprint_cells == ∅`（器械不能站在自己身上被使用）
   - **(d)**（附带项）`len(access_cells) == 1`（规则4的直接校验，等价于确认 `N = 1`）

   **可测试性约定**：加载器的"debug 中止 / release 剔除单条"这一分支行为，**不得**通过硬编码判断 `OS.is_debug_build()` 实现，而应接受一个**注入的 `strict_mode: bool` 参数**（由调用方/测试 fixture 显式传入）。这样 GUT 测试能在 headless CI 中确定性地同时覆盖两种分支，符合 coding-standards"依赖注入优于单例"的要求，也符合本节 Edge Cases 对 debug/release 分歧行为的规定。

7. **use-duration 字段加载期校验**（接住 MemberSim #6 OQ2 的跨文档硬依赖）：加载器在 Core Rule 6 之后，对每条 `EquipmentDef` 的 4 个 `use_duration_*` 字段依次校验，任一失败即该条记录加载失败（走 Edge Cases 的同一致命失败路径）：
   - **(e)** `use_duration_mean_ticks > 0`（时长为 0 或负无意义，且会让会员的 `exercises_per_visit` 进度永远卡在 0，威胁 Pillar 2「永不卡死」）
   - **(f)** `use_duration_stddev_ticks >= 0`（允许 0 = 确定性时长；负标准差非法）
   - **(g)** `use_duration_min_ticks >= 1` 且 `use_duration_min_ticks <= use_duration_mean_ticks`（下界至少 1 tick，且不超过均值）
   - **(h)** `use_duration_max_ticks >= use_duration_mean_ticks` 且 `use_duration_min_ticks <= use_duration_max_ticks`（上界不低于均值，且下界不高于上界）
   - 理由：这 4 个字段是 MemberSim 状态机 **USING 状态计时**的真实输入。若缺省或越界，`use_duration` 公式可能产出 ≤0 或 min>max 的时长，使 USING→SELECTING_TARGET/LEAVING 转移在低概率下永不触发（成员卡在 USING）。与其在 MemberSim 内做防御，不如在 Catalog 加载期用单一权威来源拦下——与本 GDD「单一权威来源」原则一致。校验分支行为同样受 `strict_mode` 参数控制（与规则6 一致）。

### States and Transitions

EquipmentCatalog 没有玩法意义上的状态机——它只有一次性的**加载生命周期**：

| 状态 | 说明 | 转移 |
|---|---|---|
| `Unloaded` | 启动前，内存中无数据 | 游戏/会话启动 → `Validating` |
| `Validating` | 逐条对外部数据跑规则3-7 校验（含规则7 的 use-duration 字段校验） | 全部通过 → `Loaded`；任一致命失败 → `Load-Failed`（见 Edge Cases） |
| `Loaded` | 终态，整个会话期间**冻结不变** | 无——直到应用重启才回到 `Unloaded` |

不存在"部分器械已加载、部分未加载"的中间可玩状态；`Loaded` 是唯一对外可见的运行时状态。

### Interactions with Other Systems

| 系统 | 方向 | 读取的字段 | 关系性质 |
|---|---|---|---|
| **GridSystem** | 数据契约耦合（非系统依赖） | `footprint_cells` / `access_cells` 的字段形状 | GridSystem 从不持有 EquipmentCatalog 引用；`equipment_def` 由 PlacementSystem 作为参数传入。规则3-6 是本 GDD 对 GridSystem OQ#13 的正式接住 |
| **PlacementSystem** | 硬下游 | 全部字段（尤其 `footprint_cells`/`access_cells`/`cost`） | 拖放时按 `id` 查询定义，构造 `equipment_def` 传给 GridSystem 做占位校验 |
| **ZoneRules** | 硬下游 | `zone_membership`、`effects` | 纯函数消费者，按已放置器械的 `id` 查表计算协同 |
| **Shop / Purchase** | 硬下游 | `cost`、`unlock_requirement` | 展示价格与解锁门槛；"当前是否已解锁"的运行时判定逻辑归 Shop/Purchase 或 Progression/Unlocks，不归本系统 |
| **Equipment Info Panel**（VS 阶段） | 硬下游 | `display_name`、`effects`、`cost` | 详情展示 |
| **MemberSim**（#6） | 硬下游 | `use_duration_mean/stddev/min/max_ticks` | 状态机 USING 状态计时；读取这 4 个字段计算单次使用时长（接住 MemberSim OQ2 跨文档依赖） |

**实现层面的问题**（Resource vs Dictionary vs JSON 存储、Autoload 单例 vs DI 服务定位）不在本节讨论范围——按设计/实现边界规则，这些标记为 **→ 应成为 ADR**，留给 `/create-architecture` 阶段决定。

## Formulas

### anchor_normalization

The `anchor_normalization` formula is defined as:

`x' = x - min_x, y' = y - min_y` where `(min_x, min_y) = min{(x, y) : (x, y) ∈ footprint_cells ∪ access_cells}`

**Variables:**
| Variable | Symbol | Type | Range | Description |
|----------|--------|------|-------|-------------|
| 原始 footprint 坐标 | footprint_cells | Array[Vector2i] | 见规则3（1×1/1×2/2×2 矩形） | 加载前的原始局部坐标，与 access_cells 共享同一局部坐标系 |
| 原始 access 坐标 | access_cells | Array[Vector2i] | 恰好 1 个元素，见规则4 | 加载前的原始局部坐标 |
| 并集最小 x | min_x | int | 任意整数 | `footprint_cells ∪ access_cells` 中最小的 x 分量 |
| 并集最小 y | min_y | int | 任意整数 | `footprint_cells ∪ access_cells` 中最小的 y 分量 |
| 归一化后坐标 | x', y' | int | [0, 2]（每轴） | 减去 min 偏移后的最终坐标，写入 Catalog 的就是这一版 |

**Output Range:** 每轴 `[0, 2]`（即归一化后并集包围盒 ≤ 3×3）。此上界由规则3（footprint ≤ 2×2）+ 规则4（access 与 footprint 正交相邻、最多外扩 1 格）共同保证，是 grid-system.md `declared_bounds` 公式所依赖、但自身无法证明的上界——本公式 + 规则3/4 就是那份证明。

**Example:** 卧推架（bench press），原始 footprint = `{(1,0),(2,0)}`，原始 access = `{(0,0)}`。`min_x=0, min_y=0`，已经是归一化状态，无需平移；归一化后 footprint = `{(1,0),(2,0)}`，access = `{(0,0)}`，并集包围盒 = 3×1。反例：若某数据手误把 access 写成 `{(-1,0)}`（左侧一格但坐标带负号），则 `min_x=-1`，归一化后 access 变为 `{(0,0)}`，footprint 变为 `{(2,0),(3,0)}`——校验器据此发现"提交数据未做归一化"，在加载期即可拒绝（具体处理见 Edge Cases）。

### provisional_equipment_cost ⚠️ 临时值

> ⚠️ **本公式为 MVP 阶段的临时锚点，非最终经济平衡决策**——一旦 Economy/Shop GDD（设计顺序 #11/#12）落地，本公式**必须被其正式取代**，届时本条在 registry 中的状态改为 `deprecated` 并留痕。写在这里的唯一目的是不让 5-6 件 MVP 器械的价格成为无依据的裸数字（违反 coding-standards"balance values must link to source formula"）。

The `provisional_equipment_cost` formula is defined as:

`cost = base_cost + tier_step × (footprint_area − 1)`

**Variables:**
| Variable | Symbol | Type | Range | Description |
|----------|--------|------|-------|-------------|
| 器械占地面积 | footprint_area | int | {1, 2, 4} | `footprint_cells` 的格子数（对应 1×1/1×2/2×2） |
| 基础价格 | base_cost | int | ≥ 0，调参 | 1×1 器械（footprint_area=1）的价格下限 |
| 分级增量 | tier_step | int | ≥ 0，调参 | 每多 1 格 footprint 增加的价格 |
| 最终价格 | cost | int | 无理论上限（线性） | 写入 `EquipmentDef.cost` 的值 |

**Output Range:** MVP 建议 `base_cost = 200`, `tier_step = 150` → 1×1 = 200，1×2 = 350，2×2 = 650（最贵:最便宜 = 3.25:1，温和线性递增，符合支柱2"松弛不紧绷"——刻意不用指数级磨人曲线）。

**Example:** 6 件 MVP 器械假设 footprint 分布为 2×(1×1) + 2×(1×2) + 2×(2×2)：跑步机 200、瑜伽垫 200、卧推架 350、划船机 350、深蹲架 650、综合训练架 650。

## Edge Cases

- **若某条 `EquipmentDef` 未通过加载期校验（Core Rule 6 的 (a)/(b)/(c)/(d) 任一项，或规则7 的 (e)/(f)/(g)/(h) 任一项）**：区分构建类型处理——**编辑器/debug 构建**下 `assert()` 立即中止并报出具体 `id` + 未通过的具体规则编号，强制在提交前修复（这是内容 bug，不是玩家可达状态）；**release 构建**下作为纵深防御，仅将该条记录从 Catalog 中剔除并 `push_error()` 记录，**不影响其余记录的加载**——不允许因一条坏数据让整个游戏无法启动（呼应支柱2"永不让玩家承受失败"，即便理想情况下这种数据错误在 debug 阶段就该被拦下，不该流入 release）。

- **若两条 `EquipmentDef` 共享同一个 `id`**：这是 Core Rule 6 未覆盖的额外加载期校验，本节在此补充——加载器必须额外校验 `id` 全局唯一。检测到重复时，保留**首次出现**的定义，后出现的视为该条记录校验失败（走上一条的失败处理路径）。理由：`id` 是跨系统引用的唯一句柄（PlacementSystem/存档都靠它查表），重复 `id` 若不处理会让"查到哪个定义"变成加载顺序的隐藏依赖。

- **若 `cost` 为负数**：加载期校验失败（走同上失败处理路径）。`cost = 0` **允许**——保留"开局免费器械"的设计空间（如新手引导阶段的起始器械）。

- **若 `unlock_requirement` 引用的里程碑 id 在当前不存在对应定义**（Milestones/Progression GDD 目前均未设计）：EquipmentCatalog **不做**该引用的存在性校验——它只把 `unlock_requirement` 当作不透明字符串存储，不解析其含义。真正的存在性校验归 Progression/Unlocks GDD 落地时补充的跨文档一致性检查（`/consistency-check` 覆盖范围）。见 Open Questions。

- **若有人尝试为同一器械存储 4 个预旋转（0°/90°/180°/270°）的 `footprint_cells`/`access_cells` 变体**：**明确禁止**。EquipmentCatalog 只存 canonical(0°) 一份定义；4 向旋转完全是运行时消费方（GridSystem `rotation_transform`）的计算职责。存 4 份会引入"4 份数据互相漂移不同步"的维护风险，且违反"单一权威来源"这一本系统存在的全部意义（见 Overview）。

- **若 `access_cells` 在运行时被墙体（`buildable=false`）压住，或被其他已放置器械占用**：**不是本系统的校验范围**。EquipmentCatalog 只声明 canonical 局部形状；access 格在具体某次放置后是否可达，完全是 GridSystem `is_solid`/运行时降级逻辑的职责（见 grid-system.md）。本系统的加载期校验只保证"access 不与**自身** footprint 重叠"这一静态、与放置位置无关的性质。

- **若加载后 Catalog 中最终条目数为 0**（如数据文件为空，或全部条目都校验失败）：这是一个致命配置错误——游戏中将不存在任何可放置器械，MVP 核心循环无法运行。**Debug/编辑器构建（`strict_mode=true`）下 `assert()` 中止**；**release 构建（`strict_mode=false`）下与单条记录失败的处理保持对称**——不崩溃，只 `push_error()` 记录，Catalog 就是空的。此时"游戏里没有任何器械可买"是一个空数据状态，其呈现（如 Shop 显示"暂无可用器械"）由下游系统负责优雅处理，不是本 GDD 的失败模式。

## Dependencies

**上游依赖（本系统依赖谁）**：无。EquipmentCatalog 是 Foundation 层——systems-index 对它的 "Depends On" 就是"—"，本 GDD 也没有引入新的系统依赖。它只需要一个外部数据源（数据文件）供加载，这是内容管线问题，不是系统依赖。

**下游依赖（谁依赖本系统）**：

| 系统 | 接口 | 硬/软依赖 |
|---|---|---|
| PlacementSystem | 按 `id` 读取完整 `EquipmentDef`；构造 `equipment_def` 参数传给 GridSystem | 硬 |
| ZoneRules | 读取 `zone_membership`、`effects` | 硬 |
| Shop / Purchase | 读取 `cost`、`unlock_requirement` | 硬 |
| MemberSim (#6) | 读取 `use_duration_mean/stddev/min/max_ticks` — USING 状态计时 | 硬 |
| Equipment Info Panel（VS 阶段） | 读取 `display_name`、`effects`、`cost` | 硬 |

**数据契约耦合（非系统依赖）**：GridSystem 通过 PlacementSystem 传入的 `equipment_def` 参数消费 `footprint_cells`/`access_cells` 的字段形状——GridSystem 从不直接引用 EquipmentCatalog。完整论证见 Detailed Design → Interactions with Other Systems。

**双向一致性核对（2026-07-20 更新）**：
- ✅ **PlacementSystem (#4)** — GDD 存在（Approved），Dependencies 表已列出 EquipmentCatalog 为硬上游。
- ✅ **ZoneRules (#9)** — GDD 存在（Approved），Dependencies 表已列出 EquipmentCatalog 为硬上游。
- ✅ **Shop/Purchase (#12)** — GDD 存在（Approved），Dependencies 表已列出 EquipmentCatalog 为硬上游。
- ✅ **MemberSim (#6)** — GDD 存在（Approved），已声明 `use_duration_*` 字段依赖（OQ2 跨文档门禁闭合）。
- ⏳ **Equipment Info Panel (#17, VS)** — GDD 尚不存在，待 VS 阶段双边核对。

**交接备注**（economy-designer 在 Formulas 节提出）：`unlock_requirement` 只声明解锁门槛字符串，不与 `provisional_equipment_cost` 的价格分级做任何关联。未来设计 Progression/Unlocks（设计顺序 #19）时，应回头核对其解锁曲线是否与本 GDD 的价格分级顺序大致吻合，避免"便宜器械很晚解锁、贵器械开局即可用"的节奏错位。**这里只是留一个具名交接，不在本 GDD 内做决定**。

## Tuning Knobs

| Knob | 归属 | 安全范围 | 太低会怎样 | 太高会怎样 |
|---|---|---|---|---|
| `base_cost` | EquipmentCatalog（临时值；Economy GDD 落地后正式接管） | ≥ 0，MVP 建议 100–300 | 器械形同免费，购买决策失去意义，破坏"攒钱再优化"的经济钩子 | 开局器械买不起，堵住核心循环第一步（拖放→反馈→微调），违反支柱2 |
| `tier_step` | EquipmentCatalog（临时值；Economy GDD 落地后正式接管） | ≥ 0，MVP 建议 100–200 | 大小器械价格趋同，抹平"占地大小 vs 价格"的空间权衡，削弱支柱1"空间即玩法" | 大器械价格过高，玩家可能永久回避 2×2 器械，实质缩小可用的布局设计空间 |
| `effects` 各 tag 的 magnitude | **本 GDD 只锁定容器形状** `{tag, magnitude}`，具体数值待 ZoneRules GDD 定义 tag 词表后才可调 | 待定（ZoneRules GDD 拥有） | — | — |
| access cell 数量（当前锁定 `N = 1`） | Core Rule 4（设计层锁定值，非运行时可调旋钮） | 固定为 1（MVP） | — | 若未来拥挤度设计需要"多人同时使用同一器械"作为设计杠杆，需回到本 GDD 重新开放此值——目前是**刻意锁死**，不是遗漏 |

## Visual/Audio Requirements

*本系统类别（Economy/data）不在 Visual/Audio 强制要求列表内；用户在设计会话中选择跳过，留待后续按需补充。footprint 尺寸与美术资源的对应关系已由 art-bible.md:94 锁定（1×1/1×2/2×2），具体每件器械的美术规格交给 `/asset-spec` 在 art-bible 之后生成。*

## UI Requirements

*用户在设计会话中选择跳过——本系统无直接 UI 呈现，UI 需求由消费方（Shop/Purchase、Equipment Info Panel）的各自 GDD 承载。*

## Acceptance Criteria

### Core Rules 覆盖

- **AC-C.1 [BLOCKING]** GIVEN 一条声明 `footprint_cells = []`（空）的器械定义，WHEN Catalog 以 `strict_mode=true` 加载，THEN 加载在该条记录处 `assert()` 中止，错误信息包含该条目的 `id`。
- **AC-C.2 [BLOCKING]** GIVEN 同上的非法定义，WHEN Catalog 以 `strict_mode=false` 加载，THEN 该条记录被剔除并触发 `push_error()`，其余合法记录仍正常加载进最终 Catalog。
- **AC-C.3 [BLOCKING]** GIVEN 一条 `footprint_cells` 不是 1×1/1×2/2×2 三种矩形之一的定义（如 3 格 L 形），WHEN 加载，THEN 判定为校验失败，走 AC-C.1/C.2 的分支处理。
- **AC-C.4 [BLOCKING]** GIVEN 一条 `access_cells` 含 2 个及以上条目的定义，WHEN 加载，THEN 判定为校验失败（`len(access_cells) != 1`）。
- **AC-C.5 [BLOCKING]** GIVEN 一条 `access_cells` 与 `footprint_cells` 仅对角相邻（不共边）的定义，WHEN 加载，THEN 判定为校验失败。
- **AC-C.6 [BLOCKING]** GIVEN 一条 `access_cells` 与 `footprint_cells` 重叠的定义，WHEN 加载，THEN 判定为校验失败（接住 GridSystem OQ#13 的 (c) 项）。
- **AC-C.7 [BLOCKING]** GIVEN 一条 `footprint_cells`/`access_cells` 未预先归一化（并集 `min != (0,0)`）的定义，WHEN 加载器执行 `anchor_normalization`，THEN 归一化后的坐标写入最终 `EquipmentDef`，且归一化后并集 `min == (0,0)`（接住 GridSystem OQ#13 的 (b) 项）。
- **AC-C.8 [BLOCKING]** GIVEN 已成功加载的 Catalog，WHEN 任意系统对同一 `id` 重复调用 `get_definition(id)`，THEN 两次返回的值相等；且 Catalog 的公开接口中不存在任何 setter/mutator 方法（静态代码检查即可验证）。

### Formulas 覆盖

- **AC-D.1 [BLOCKING]** GIVEN `footprint_cells={(1,0),(2,0)}, access_cells={(0,0)}`，WHEN 执行 `anchor_normalization`，THEN 输出 `footprint_cells={(1,0),(2,0)}, access_cells={(0,0)}`（已归一化，无平移）。
- **AC-D.2 [BLOCKING]** GIVEN 任意通过 AC-C.3/C.4/C.5 校验的合法器械定义，WHEN 执行 `anchor_normalization`，THEN 输出坐标的每个分量都落在 `[0, 2]` 范围内（边界性断言，独立于"计算是否正确"）。
- **AC-D.3 [BLOCKING]** GIVEN `footprint_area ∈ {1, 2, 4}` 且 `base_cost=200, tier_step=150`，WHEN 计算 `provisional_equipment_cost`，THEN 分别输出 `200/350/650`。
- **AC-D.4 [ADVISORY]** GIVEN `provisional_equipment_cost` 公式仍标记为临时值，WHEN Economy/Shop GDD（#11/#12）落地，THEN 本组 AC 必须被重新审视——不得在无人知晓的情况下被静默继续采信为终值。

### Edge Cases 覆盖

- **AC-E.1 [BLOCKING]** GIVEN 两条器械定义共享同一个 `id`（测试 fixture 固定加载顺序：A 先于 B），WHEN 加载，THEN 最终 Catalog 中该 `id` 对应 A 的定义，B 被判定为校验失败。
- **AC-E.2 [BLOCKING]** GIVEN `cost = -1` 的定义，WHEN 加载，THEN 判定为校验失败；GIVEN `cost = 0`，WHEN 加载，THEN 正常加载成功。
- **AC-E.3 [ADVISORY]** GIVEN 一条 `unlock_requirement` 指向当前不存在的里程碑 id 的定义，WHEN Catalog 加载，THEN 加载成功、不报错——本系统不解析该字符串的语义（存在性校验留给未来 `/consistency-check`）。
- **AC-E.4 [ADVISORY]** GIVEN 一件器械的 `access_cells` 在某次具体放置中被墙体或其他器械阻挡，WHEN 查询该器械的 `EquipmentDef`，THEN Catalog 仍返回该定义且不报告任何错误——可达性判定完全在 GridSystem/PlacementSystem 侧，不在本系统的校验范围内。
- **AC-E.5 [BLOCKING]** GIVEN 全部条目都加载失败或数据源为空，WHEN Catalog 以 `strict_mode=true` 加载，THEN `assert()` 中止；WHEN 以 `strict_mode=false` 加载，THEN 不崩溃，`push_error()` 记录，最终 Catalog 条目数为 0。

### use-duration 字段覆盖（接住 MemberSim #6 OQ2）
- **AC-U.1 [BLOCKING]** GIVEN 一条 `use_duration_mean_ticks <= 0` 的器械定义，WHEN Catalog 以 `strict_mode=true` 加载，THEN 加载在该条记录处 `assert()` 中止，错误信息包含该条 `id`（规则7 (e)）。
- **AC-U.2 [BLOCKING]** GIVEN 一条 `use_duration_stddev_ticks < 0` 的定义，WHEN 加载，THEN 判定为校验失败（规则7 (f)）。
- **AC-U.3 [BLOCKING]** GIVEN 一条 `use_duration_min_ticks < 1` 或 `min > mean` 或 `max < mean` 或 `min > max` 的定义，WHEN 加载，THEN 判定为校验失败（规则7 (g)/(h)）。
- **AC-U.4 [BLOCKING]** GIVEN 一条合法定义（`mean=200, stddev=35, min=100, max=300`），WHEN 加载成功且 `get_definition(id)` 被调用，THEN 返回的 `EquipmentDef` 包含这 4 个字段且值精确匹配（验证字段已落地、可被 MemberSim 消费）。

### 性能（轻量，非热路径）

- **AC-PERF.1 [ADVISORY]** GIVEN MVP 规模的 ~6 条器械定义，WHEN 游戏启动时加载+校验整个 Catalog，THEN 完成时间应远小于典型 loading screen 预算——本系统只在启动时跑一次，不是每帧路径，不需要严格的性能预算，此处仅作为未来回归警报的锚点。

## Open Questions

| # | 问题 | 归属 | 触发/目标解决时机 | 备注 |
|---|------|------|-------------------|------|
| 1 | `effects` 的具体 tag 词表（如 `comfort`/`crowd_pressure`）是什么？ | ZoneRules GDD（设计顺序 #9） | ZoneRules GDD 落地时 | 本 GDD 只锁定 `{tag, magnitude}` 容器形状，不预先枚举 tag 值，避免与尚不存在的 ZoneRules 产生冲突 |
| 2 | `provisional_equipment_cost` 何时被正式取代？ | Economy GDD（#11）/ Shop-Purchase GDD（#12） | 二者任一落地时 | 届时本公式在 registry 中状态改为 `deprecated`，AC-D.4 是这一交接的强制检查点 |
| 3 | `unlock_requirement` 引用的里程碑 id 存在性谁来校验？ | Progression/Unlocks GDD（#19） | Progression/Unlocks GDD 落地后，跑一次 `/consistency-check` | 本系统不解析该字符串语义（见 AC-E.3），存在性校验是跨文档一致性问题 |
| 4 | 解锁曲线与价格分级的节奏是否吻合？ | Progression/Unlocks GDD（#19） | 该 GDD 设计时 | economy-designer 提醒的具名交接（见 Dependencies 节）——避免"便宜器械很晚解锁"的错位，非本 GDD 决定范围 |
| 5 | access cell 数量是否应从固定 `N=1` 放开为可变旋钮？ | 本 GDD 自身 | Congestion GDD（#7）设计时，或 fun-validation 原型/playtest（设计顺序第8步节点）发现拥挤度需要"多人同时使用"作为设计杠杆时 | 目前是刻意锁死（见 Tuning Knobs），不是遗漏；重开需要重新验证 3×3 包围盒上界证明是否仍然成立 |
| 6 | 数据存储格式（Resource / Dictionary / JSON）与加载方式（Autoload 单例 vs DI 服务定位）？ | `/create-architecture` | 架构阶段 | 全文档多处标记为"→ 应成为 ADR"，设计层不预判技术选型 |
| 7 | MemberSim #6 所需的 4 个 `use_duration_*` 字段（`mean/stddev/min/max_ticks`）是否已加入 EquipmentDef？ | 本 GDD（✅ 2026-07-19 已落实） | 已解决 — 见 Core Rule 1 字段表 + 规则7 加载期校验 + AC-U.1–U.4 | 跨文档门禁闭合：MemberSim 现可在 `/dev-story` 前获得合法字段；原 OQ2 的 `/propagate-design-change` 路径已通过本修订完成，无需另跑 |
