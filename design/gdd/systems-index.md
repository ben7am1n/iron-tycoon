# Systems Index: 撸铁大亨 (Iron Tycoon)

> **Status**: Draft
> **Created**: 2026-07-15
> **Last Updated**: 2026-07-21
> **Source Concept**: design/gdd/game-concept.md
> **Boundary Review**: TD-SYSTEM-BOUNDARY (technical-director, adversarial) — REJECT resolved; all findings adopted 2026-07-15.
> **Design Reviews**: 每个 GDD 的评审史见 `design/gdd/reviews/[system]-review-log.md`。GridSystem 已过**两轮** full-mode 对抗式评审（2026-07-16 首评 5 位专家 + creative-director；2026-07-17 复审 **APPROVED**）。2026-07-20/21 批量评审 #2/#13/#14/#15/#16 — 5 份 GDD 同时评审，blocking 全部当场修订。

> **⚠️ GridSystem 交出去的两条具名需求（下游设计时必须回读 `grid-system.md`）**：
> - **设计 #2 EquipmentCatalog 时** → 必须接住 OQ#13：加载期校验 footprint 非空 / 锚点 `min==(0,0)` / access 不与自身 footprint 重叠，并确认 access 数量上限 `N`。**未接住则 GridSystem 的 AC-D5.4 升级为 BLOCKING**（其"生产路径不做运行时防御"的决策前提失效）。
> - **设计 #7/#8 Congestion/Overlay 时** → 必须接住 OQ#9：呈现"access 受阻 / 零可达"状态，且**必须默认可见**（不能只藏在默认关闭的 overlay 开关后）。**这是 GridSystem "放置时不警告"这一设计成立的前提条件，非可选打磨项。**
>
> 两者是同一形状的风险：**交接只是一段文字，没有机制强制下游作者回读**。此处登记即为那个机制。

---

## Overview

《撸铁大亨》是一款治愈系桌面健身房经营游戏，核心是**空间优化**：玩家在网格上拖放器械，会员寻路使用器械，布局质量驱动拥挤/动线，进而驱动满意度与收入（支柱1"空间即玩法"、支柱2"松弛不紧绷"、支柱3"一眼看懂"、支柱4"看得见的蜕变"）。系统的关键设计原则来自对抗式边界审查：**空间真相归属 GridSystem 占用状态**（而非输入驱动的 Placement）；模拟由**固定顺序的编排器 + 种子 RNG** 驱动以保证存档可复现；寻路用 **AStarGrid2D**；"流动"通过 **Congestion(t-1) → 路由(t)** 的一帧延迟反馈成为真正的机制而非装饰。MVP 的目标是尽早验证"调布局让人流顺畅本身就好玩"，因此设计顺序把好玩验证垂直切片前置到第 8 步。

---

## Systems Enumeration

| # | System Name | Category | Priority | Status | Design Doc | Depends On |
|---|-------------|----------|----------|--------|------------|------------|
| 1 | GridSystem | Core | MVP | ✅ **Approved** (两轮对抗式评审，2026-07-17 复审通过) | [grid-system.md](grid-system.md) · [评审记录](reviews/grid-system-review-log.md) | — |
| 2 | EquipmentCatalog | Economy (data) | MVP | ✅ **Approved**（2026-07-19 独立复审通过，跨文档门禁闭合；2026-07-20 双向一致性核对状态刷新 + Dependencies 补 MemberSim） | [equipment-catalog.md](equipment-catalog.md) · [评审记录](reviews/equipment-catalog-review-log.md) | — |
| 3 | TimeSystem + SimulationOrchestrator + SeededRNG (inferred) | Core | MVP | ✅ **Approved** (独立复审通过，2026-07-19；旧 blocking 修订经独立核对成立) | [time-system.md](time-system.md) · [评审记录](reviews/time-system-review-log.md) | — |
| 4 | PlacementSystem | Gameplay | MVP | ✅ **Approved**（full-mode 对抗式评审 2026-07-20：独立复核 2026-07-19 的 7 项修订全部成立；本轮新增 7 blocking 已修——`is_dragging()` 缺失接口（Shop/Purchase 硬依赖）、Godot 4.7.1 `as Rotation` 强转"已验证"断言与实际原型代码不符、relocate 会员位移未文档化、AC4 白盒钩子未定义、AC14 断言空依赖、AC25(e) 与 Core Rule 7 矛盾、信号 arity 风险未覆盖全部信号） | [placement-system.md](placement-system.md) · [评审记录](reviews/placement-system-review-log.md) | GridSystem, EquipmentCatalog |
| 5 | Navigation (AStarGrid2D) (inferred) | Core | MVP | ✅ **Approved** (独立复审通过，2026-07-19；OQ1 tie-break 硬门禁正确登记) | [navigation.md](navigation.md) · [评审记录](reviews/navigation-review-log.md) | GridSystem (occupancy) |
| 6 | MemberSim + MemberActivity/usage | Gameplay | MVP | ✅ **Approved** (独立复审通过，2026-07-19；B1 entrance/exit 已修，B2 EquipmentCatalog 跨文档硬依赖登记) | [member-sim.md](member-sim.md) · [评审记录](reviews/member-sim-review-log.md) | TimeSystem, GridSystem, Navigation |
| 7 | Congestion (dynamic member density) (inferred) | Gameplay | MVP | ✅ **Approved** (独立复审通过，2026-07-19；OQ2 固定求和序硬门禁正确登记) | [congestion.md](congestion.md) · [评审记录](reviews/congestion-review-log.md) | Navigation, MemberSim |
| 8 | Congestion/Flow Overlay + Placement Feedback | UI | MVP | ✅ **Approved** (独立复审通过，2026-07-19；B1 access-blocked 默认可见已修，OQ#9 信任链闭合) | [congestion-flow-overlay.md](congestion-flow-overlay.md) · [评审记录](reviews/congestion-flow-overlay-review-log.md) | Congestion, PlacementSystem |
| 9 | ZoneRules (static adjacency/packing, pure fn) (inferred) | Gameplay | MVP | ✅ **Approved** (full-mode 对抗式评审 2026-07-20：4 blocking 已修，perimeter-normalized 公式) | [zone-rules.md](zone-rules.md) · [评审记录](reviews/zone-rules-review-log.md) | GridSystem, EquipmentCatalog |
| 10 | Satisfaction | Gameplay | MVP | ✅ **Approved** (full-mode 对抗式评审 2026-07-20：4 blocking 已修——Economy 接口对齐、n_fail/n_interrupt 加 cap、AC 结构拆分、total_i 范围更新) | [satisfaction.md](satisfaction.md) · [评审记录](reviews/satisfaction-review-log.md) | Congestion, ZoneRules, MemberSim |
| 11 | Economy | Economy | MVP | ✅ **Approved** (full-mode 对抗式评审 2026-07-20：4 blocking 已修——信号语义定义 quota-met only、spend() 负数防御、pacing 表修正、AC 结构拆分) | [economy.md](economy.md) · [评审记录](reviews/economy-review-log.md) | TimeSystem, MemberSim (Satisfaction *indirect* only — 见 GDD) |
| 12 | Shop / Purchase (inferred) | Economy | MVP | ✅ **Approved**（full-mode 对抗式评审 2026-07-20：3 blocking 已修——`_purchase_in_flight` 卡死死锁、`equipment_id` 不匹配分支未定义、AC8 缺 `get_definition`；同步补齐 sell-back 单调性风险追踪与 block-at-selection 悬停反馈要求） | [shop-purchase.md](shop-purchase.md) | Economy, EquipmentCatalog, PlacementSystem |
| 13 | SelectionSystem (inspect/move/sell placed items) (inferred) | UI | MVP | In Review（2026-07-20 第二轮修订：B1 加载映射重建已修 + R4/R8/R9 AC缺口/精度/意图区分已修；待独立复审） | [selection-system.md](selection-system.md) · [评审记录](reviews/selection-system-review-log.md) | GridSystem, EquipmentCatalog, Economy(credit), PlacementSystem, SaveLoad |
| 14 | SaveLoad (tick-boundary coordinator) (inferred) | Persistence | MVP | Designed（2026-07-20 首轮 design-review：B1 tick_completed 事实错误已更正 + B2 validate 模式传播已注明 + SelectionSystem 加载映射重建已注册入 load order） | [save-load.md](save-load.md) | all sim systems (serialize()) |
| 15 | Build/Shop UI (inferred) | UI | MVP | Designed（2026-07-20 首轮 design-review：B1 hover 反馈 AC 已补 + OQ3 可关闭） | [build-shop-ui.md](build-shop-ui.md) | PlacementSystem, Shop, SelectionSystem |
| 16 | HUD (money/satisfaction/time) (inferred) | UI | MVP | ✅ **Approved**（2026-07-20 design-review：无内部设计缺陷，两个 OQ 为跨系统缺口已正确记录） | [hud.md](hud.md) | Economy, Satisfaction, TimeSystem |
| 17 | Equipment Info Panel (inferred) | UI | Vertical Slice | Not Started | — | EquipmentCatalog, ZoneRules, SelectionSystem |
| 18 | Milestones (inferred) | Progression | Vertical Slice | Not Started | — | Satisfaction, Economy |
| 19 | Progression / Unlocks (inferred) | Progression | Vertical Slice | Not Started | — | Economy, Milestones |
| 20 | Onboarding / Tutorial (inferred) | Meta | Vertical Slice | Not Started | — | core MVP systems |
| 21 | Audio (music + SFX) (inferred) | Audio | Vertical Slice | Not Started | — | event/signal bus |
| 22 | Settings & Accessibility (colorblind/contrast) (inferred) | Meta | Vertical Slice | Not Started | — | UI |

> **Deferred (Tier 2 — Full Vision, not indexed as active work):** 多店连锁 Chain, 半挂机产出 IdleProduction, 城区人群差异, 场馆美化"出片"系统. Revisit after MVP fun-validation.

---

## Categories

| Category | Description | Systems here |
|----------|-------------|--------------|
| **Core** | Foundation everything depends on | GridSystem, TimeSystem/Orchestrator/RNG, Navigation |
| **Gameplay** | The systems that make the game fun | PlacementSystem, MemberSim/Activity, Congestion, ZoneRules, Satisfaction |
| **Economy** | Resource creation/consumption | EquipmentCatalog (data), Economy, Shop |
| **Progression** | How the player grows | Milestones, Progression/Unlocks |
| **Persistence** | Save state | SaveLoad |
| **UI** | Player-facing displays | Overlay/Feedback, SelectionSystem, Build/Shop UI, HUD, Info Panel |
| **Audio** | Sound & music | Audio |
| **Meta** | Outside core loop | Onboarding, Settings & Accessibility |

---

## Priority Tiers

| Tier | Definition | Target Milestone | Design Urgency |
|------|------------|------------------|----------------|
| **MVP** | Required to test "is tuning layout for flow fun?" | First playable prototype | Design FIRST |
| **Vertical Slice** | One complete, polished single-store experience | Vertical slice / demo | Design SECOND |
| **Alpha** | All features rough (chain/idle framework) | Alpha | Design THIRD |
| **Full Vision** | Chain empire, idle, beautification, polish | Beta / Release | As needed |

---

## Dependency Map

> **Boundary rule (from adversarial review):** Spatial truth is owned by **GridSystem occupancy**, not PlacementSystem. PlacementSystem is a *leaf writer* that mutates GridSystem and emits `grid_changed(cells)`. Navigation, ZoneRules, and Congestion subscribe to grid state — they do NOT depend on PlacementSystem. `ZoneRules.evaluate(grid_snapshot)` is a **pure function**, so placement previews pass a speculative snapshot (no cycle).

### Foundation Layer (no dependencies)
1. **GridSystem** — owns cell occupancy + multi-cell footprints + rotation mapping; single source of spatial truth.
2. **EquipmentCatalog** — immutable, read-only data (size, cost, effects, zone membership). Safe high-fan-in bottleneck iff never mutated at runtime.
3. **TimeSystem + SimulationOrchestrator + SeededRNG** — fixed-order tick loop (decoupled from render) + a central seeded RNG whose seed+state is serialized.

### Core Layer (depends on foundation)
1. **PlacementSystem** — depends on: GridSystem, EquipmentCatalog. Leaf writer; emits `grid_changed`.
2. **Navigation (AStarGrid2D)** — depends on: GridSystem (occupancy). Deterministic integer paths; flip a cell's solidity to "rebake".

### Feature Layer (depends on core)
1. **MemberSim + MemberActivity/usage** — depends on: TimeSystem, GridSystem, Navigation. Owns target selection + equipment-use lifecycle (where pillar-1 causality lives).
2. **Congestion** — depends on: Navigation, MemberSim. Dynamic member density/queues. Feeds routing at **t-1** (one-tick lag): `Congestion(t-1) → target/route selection(t)`.
3. **ZoneRules** — depends on: GridSystem, EquipmentCatalog. Pure function of grid snapshot; static adjacency/packing/synergy of placed equipment.
4. **Satisfaction** — depends on: Congestion, ZoneRules, MemberSim.
5. **Economy** — depends on: Satisfaction, TimeSystem.
6. **Shop / Purchase** — depends on: Economy, EquipmentCatalog.
7. **Progression / Unlocks** — depends on: Economy, Milestones.
8. **Milestones** — depends on: Satisfaction, Economy.

### Presentation Layer (depends on features)
1. **Congestion/Flow Overlay + Placement Feedback** — depends on: Congestion, PlacementSystem, ZoneRules. *(First fun-validation milestone lands here.)*
2. **SelectionSystem** — depends on: GridSystem. Emits `selection_changed` for inspect/move/sell of placed items.
3. **Build/Shop UI** — depends on: PlacementSystem, Shop, SelectionSystem.
4. **HUD** — depends on: Economy, Satisfaction, TimeSystem.
5. **Equipment Info Panel** — depends on: EquipmentCatalog, ZoneRules, SelectionSystem.

### Polish Layer (depends on everything)
1. **SaveLoad** — tick-boundary coordinator over per-system `serialize()/deserialize()`; never saves mid-tick. Developed incrementally alongside sim systems from step 3.
2. **Onboarding / Tutorial**, **Audio**, **Settings & Accessibility**.

---

## Recommended Design Order

> Front-loads the pillar-1 vertical slice. **Stop at order 8 and test the MVP hypothesis before building Economy/meta.**

| Order | System | Priority | Layer | Agent(s) | Est. Effort |
|-------|--------|----------|-------|----------|-------------|
| 1 | GridSystem | MVP | Foundation | game-designer + godot-specialist | M |
| 2 | EquipmentCatalog | MVP | Foundation | game-designer | S |
| 3 | TimeSystem + SimulationOrchestrator + SeededRNG | MVP | Foundation | game-designer + godot-specialist | M |
| 4 | PlacementSystem | MVP | Core | game-designer + godot-gdscript-specialist | M |
| 5 | Navigation (AStarGrid2D) | MVP | Core | godot-specialist | M |
| 6 | MemberSim + MemberActivity/usage | MVP | Feature | game-designer + ai-programmer | L |
| 7 | Congestion (+ t-1 routing feedback) | MVP | Feature | systems-designer | M |
| 8 | **Congestion/Flow Overlay + Placement Feedback** 🎯 | MVP | Presentation | technical-artist + ux-designer | M |
| — | **← FUN-VALIDATION MILESTONE: prototype & playtest the core loop here** | — | — | — | — |
| 9 | ZoneRules (pure, off Grid) | MVP | Feature | systems-designer | M |
| 10 | Satisfaction | MVP | Feature | systems-designer + economy-designer | M |
| 11 | Economy | MVP | Feature | economy-designer | M |
| 12 | Shop / Purchase | MVP | Feature | economy-designer | S |
| 13 | SelectionSystem | MVP | Presentation | ux-designer | S |
| 14 | Build/Shop UI | MVP | Presentation | ux-designer + ui-programmer | M |
| 15 | HUD | MVP | Presentation | ux-designer | S |
| 16 | Milestones | VS | Progression | game-designer | S |
| 17 | Progression / Unlocks | VS | Progression | economy-designer | M |
| 18 | Equipment Info Panel | VS | Presentation | ux-designer | S |
| 19 | Onboarding / Tutorial | VS | Meta | ux-designer | M |
| 20 | Audio | VS | Audio | audio-director | M |
| 21 | Settings & Accessibility | VS | Meta | accessibility-specialist | M |

> SaveLoad is developed **incrementally** from order 3 onward — each system implements `serialize()/deserialize()` as it lands; SaveLoad coordinates at tick boundaries.

Effort: S = 1 session, M = 2-3 sessions, L = 4+ sessions.

---

## Circular Dependencies

- **Placement ↔ ZoneRules (RESOLVED):** Placement's drag-preview needs zone effects while ZoneRules must not depend on Placement. Broken by making `ZoneRules.evaluate(grid_snapshot)` a **pure function** — the preview node (presentation layer) passes a speculative grid snapshot; committed placement passes real occupancy. No hard edge.
- **Congestion ↔ Routing (RESOLVED by design):** "Flow" requires congestion to influence routing, but Congestion depends on Navigation. Broken with a **one-tick lag**: routing/target-selection at tick `t` reads `Congestion(t-1)`. This is an intended feedback edge, not a cycle.

---

## High-Risk Systems

| System | Risk Type | Risk Description | Mitigation |
|--------|-----------|-----------------|------------|
| MemberSim + Congestion + Overlay (core loop) | Design | The whole MVP hypothesis — "tuning layout for flow is fun" — is unproven until these + overlay exist. | Front-loaded to order 6-8; **prototype & playtest at the order-8 milestone before building economy/meta**. |
| GridSystem | Technical/Scope | High fan-in; multi-cell footprint + rotation occupancy must be modeled correctly or every consumer breaks. | Design first (order 1); own footprint→cell mapping here, not in Placement. |
| Navigation | Technical | Wrong tool (NavigationServer2D) would cause async-bake stutter + non-deterministic saves. | Use **AStarGrid2D** off Grid occupancy (decided). |
| Simulation determinism | Technical | Without fixed tick order + seeded RNG, saves won't reproduce ("load ≠ where I left off"). | SimulationOrchestrator + serialized SeededRNG (order 3); save only at tick boundaries. |
| Congestion/Flow Overlay | Technical | `DrawableTexture2D` (Godot 4.7) is unverified against the installed engine. | Verify against local 4.7.1; fallback = shader sampling a per-cell `ImageTexture`, `CanvasItem._draw`, or `TileMapLayer` modulate. Non-blocking. |
| Satisfaction | Design | Numeric heart of "is layout meaningful"; must balance depth vs calm (pillar 2). | Tune during/after the fun-validation prototype; economy-designer involvement. |

---

## Progress Tracker

| Metric | Count |
|--------|-------|
| Total systems identified | 22 (+ 4 deferred Tier-2) |
| Design docs started | 16 |
| Design docs reviewed | ✅ **16 / 16**（#1–#16 全部至少完成首轮设计评审） |
| Design docs approved | ✅ **14**（#1 GridSystem + #3–#12 Place&#173;mentSystem 全部 Approved + #16 HUD Approved + #2 EquipmentCatalog Approved；#13 SelectionSystem 待独立复审） |
| Design docs designed / review-pending | 2（#13 SelectionSystem 第二轮修订待复审；#14 SaveLoad + #15 Build/Shop UI 首轮 blocking 已修） |
| MVP systems designed | ✅ **16 / 16 (全部完成)** |
| Vertical Slice systems designed | 0 / 6 |

> **🎯 全部 8 个"好玩验证里程碑"系统（#1–#8）现已设计完成且全部 Approved（2026-07-19 独立复审，Hermes 等效执行）。** 两个真实跨文档 blocking 已当场修订：MemberSim 的 `entrance_cell`/`exit_cell` 提升为对 GridSystem 的硬依赖（B1）；Overlay 的 `access_reachable` 默认可见写死为 scene-load 即显示（B1，闭合 GridSystem OQ#9 信任链）。**核心循环已具备端到端可原型条件。**
>
> **跨文档实现门禁已清（2026-07-19 收尾）：** EquipmentCatalog (#2) 的两条跨文档契约均闭合——(1) GridSystem OQ#13 三道加载期校验（`footprint` 非空 / 归一化后 `min==(0,0)` / `access` 不重叠）早已落实于 Core Rule 6 + AC-C.1/6/7；(2) MemberSim OQ2 所需的 4 个 `use_duration_*` 字段（mean/stddev/min/max_ticks）已于本日落实（字段表 + 规则7 加载期校验 (e)(f)(g)(h) + AC-U.1–4）。**核心循环 9 个系统（#1–#8 + EquipmentCatalog）现已设计完成且全部具备实现条件，进入 order-8 fun-validation 原型前不再有跨文档阻塞。** #2 本身仍建议补一次正式独立 `/design-review` 记录（非阻塞）。

> **Godot 4.7.1 引擎坑回填（2026-07-19）：** 竖切片实测纠正了 7 条 GDD 与 4.7.1 实际 API 的偏差，已回填进 #4 PlacementSystem、#5 Navigation、#8 Congestion/Flow Overlay 三份 GDD：每个文件顶部加「⚠️ Pinned engine: Godot 4.7.1」警示块 + 文末「Pinned Engine Caveats」详节（指向 skill godot-4x-gdscript-pitfalls）。其中 **#5 Navigation 两处事实错误已纠正**：(a) Core Rule 3 原称 set_point_solid「立即生效（verified 4.7.1）」，实测 4.7.1 必须调用 update() 才生效；(b) AC7 原测「无需 update() 立即排除」，已改为「handler 须调用 update() 后生效」。实现这三者前必须先读 caveat。

---

## Next Steps

- [ ] Design MVP-tier systems in order (use `/design-system GridSystem` first)
- [ ] Run `/design-review design/gdd/[system].md` on each completed GDD
- [ ] **At order 8, prototype & playtest the core loop before continuing** (`/prototype`, `/playtest-report`)
- [ ] Run `/gate-check pre-production` when MVP systems are designed
