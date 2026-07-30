# Review Log — Congestion (+ one-tick routing feedback)

## Review — 2026-07-19 — Verdict: **APPROVED**（首次独立复审）

**Depth**: lean-equivalent（独立上下文复审）
**Scope signal**: M
**Specialists**: 单遍严格复审（game-designer / systems-designer / qa-lead / godot-specialist 视角合并执行；等效独立 pass，非并行子代理编排）

### Completeness: 8/8 sections present

### Dependency Graph
- ✓ TimeSystem (#3) — exists, Approved
- ✓ MemberSim (#6) — exists, Approved（同日复审）；`Congestion(t-1)` `[0,1]` 接口假设已双向对齐 ✅
- ✓ GridSystem (#1) — exists, Approved
- ✓ Navigation (#5) — exists, Approved
- ✓ EquipmentCatalog (#2) — exists (Designed)

### Required Before Implementation（BLOCKING）
**1. [Congestion self, OQ2 — HARD GATE]** 比特级确定性（AC1）依赖**固定浮点求和顺序**：per-cell 与 per-equipment 迭代必须以升序 cell index / `equipment_instance_id` 进行，绝不用 hash/scene 序，否则浮点非结合性破坏 bit-identical。此门禁必须在 `/dev-story` 时以静态/实现约束强制执行；若仍咬人，降级为 epsilon-tolerance 确定性断言。属真硬门禁，已由 OQ2 + AC1/AC6（mid-loop 读数 hook）强制。
**2. [Congestion self, OQ1 → Overlay #8]** `access_reachable == false` 的**默认可见**要求（来自 GridSystem OQ#9 + 本 GDD Core Rule 5）必须由 Overlay #8 落地——本轮已在 Overlay #8 Core Rule 5 显式写死"scene load 即对已不可达机器显示，无事件门"，消除原状态表的可读歧义。此要求现双向闭合（Congestion 产出 flag，Overlay 保证默认可见）。

### Recommended Revisions（非 blocking）
- **R1 [systems-designer]**：`per_equipment_congestion` 的 `occ_i = occupancy_state/2` 把 tier {0,1,2} 映射到 {0, 0.5, 1.0}——当 queue cap=1（MemberSim OQ4）时 tier 2 是可达上限，映射正确。但若未来 queue cap >1（OQ4 留口），tier 需重定义，否则 `occ_i` 越界。建议 OQ4 放宽时同步修订本公式。
- **R2 [qa-lead]**：AC8 检验 EMA 衰减到 <0.05（α=0.3，9+ ticks）——该断言验证了"零成员时不瞬切"的 Pillar 2 行为，好。但建议补充 AC：单 tick 内 `raw_i` 在 [0,1] 抖动时 `Congestion_i` 的逐 tick 变化量上限 = α·Δraw ≤ α（已由 AC7 覆盖单极端，建议加中值抖动的回归）。
- **R3 [godot-specialist]**：`access_reachable` 事件驱动（仅 `grid_changed`）——Core Rule 5 与 Edge Case "multiple grid_changed in one tick → recompute once per affected equipment" 已正确去重。但 `grid_changed` 的 `footprint_cells_changed`/`access_cells_changed` 两个数组是否包含"足以判定 reachability 变化"的全部受影响的 equipment，依赖 GridSystem 的发射契约；建议在 #14 SaveLoad 或 architecture 阶段交叉确认 GridSystem 的 `grid_changed` payload 覆盖 reachability 计算所需的最小单元。

### Specialist Disagreements
无。四视角一致：双缓冲（prev/next swap）的 one-tick lag 机制正确、EMA 平滑合理、`access_reachable` 事件驱动避免 per-tick pathfinding 正确。唯一硬门禁（OQ2 固定求和序）已妥善标注。

### Nice-to-Have
- OQ3（Satisfaction #10 可能读 per-equipment congestion）的接口（同 `[0,1]` scalar 还是聚合）应在 #10 设计时确认——当前 Congestion 已按 `[0,1]` scalar 提供，兼容性好。
- OQ4（多 entrance）为 post-MVP，文档性正确。

### Scope Signal: M
5 上游依赖、2 公式、确定性门禁无新 ADR。

### Verdict: **APPROVED**
无设计层 blocking。两个硬门禁（OQ2 固定求和序、OQ1→Overlay 默认可见）均正确登记或已闭合。建议 systems-index 中 #7 状态更新为"Approved（独立复审通过）"。

> **独立度声明**：本轮复审由 Hermes 以单遍严格复审等效执行，4 个专家视角合并于一次审查，非并行独立 session。保真度低于 CCGS full 模式但高于原 session 内非独立补 pass。
