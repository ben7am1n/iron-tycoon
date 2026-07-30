# Review Log — Navigation (AStarGrid2D)

## Review — 2026-07-19 — Verdict: **APPROVED**（首次独立复审）

**Depth**: lean-equivalent（独立上下文复审）
**Scope signal**: M
**Specialists**: 单遍严格复审（game-designer / systems-designer / qa-lead / godot-specialist 视角合并执行；等效独立 pass，非并行子代理编排）

### Completeness: 8/8 sections present
（Overview / Player Fantasy / Detailed Rules / Formulas / Edge Cases / Dependencies / Tuning Knobs / Acceptance Criteria 全部齐备）

### Dependency Graph
- ✓ GridSystem — exists (GDD approved, foundational). Interfaces used (`is_solid`, `get_dimensions`, `grid_changed`) are granted per GridSystem's per-consumer contract ✅
- Congestion (#7) — declared explicit non-dependency (Navigation does not read Congestion) ✅ 与 navigation.md / congestion.md 双向一致

### Required Before Implementation（BLOCKING）
**1. [Navigation self, OQ1 — HARD GATE]** AStarGrid2D 跨进程/重建后的 tie-break 稳定性（AC11）在 4.7.1 未验证。必须在任何 save/load 依赖 Navigation 确定性之前通过（两个独立 headless 进程 diff 输出）。若失败，需在 AStarGrid2D 之上强加确定性 tie-break（如字典序 cell 排序）。这是真实硬门禁——不是空洞承诺，由 AC11 的 HARD GATE 标注强制。
**2. [MemberSim #6 实现约束]** MemberSim 必须以稳定有序结构（按持久 `member_id` 升序，非 hash 序）迭代成员，否则 Core Rule 6 的"bit-identical paths given query order"确定性前提被打破。此为跨系统契约，navigation.md Core Rule 6 已正确标注为 residual risk 并硬门禁，但执行责任在 MemberSim 实现侧。

### Recommended Revisions（非 blocking）
- **R1 [systems-designer]**：`DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES` 使两 corner-adjacent 器械间的 1 格对角缝**不可通行**（OQ4）。此约束与 PlacementSystem 的 footprint/access 布局、ZoneRules (#9) 的相邻规则强相关——ZoneRules 设计时须显式禁止把对角 1 格缝当预期动线，否则玩家会"看见一条路却走不过去"。已记入 OQ4，建议 #9 落地时回读。
- **R2 [godot-specialist]**：`grid_changed` handler 对 `footprint_cells_changed` 与 `access_cells_changed` 两个数组都重推 solidity（Core Rule 3）。access cell 经 `is_solid` 自动解析为非 solid，但需确认 GridSystem 在"access 被 footprint 包围"的退化情形下仍返回 access 单元格自身非 solid（congestion.md Core Rule 5 假设如此）。属实现层交叉验证。
- **R3 [performance-analyst]**：AC7 验证"同帧无 `update()` 调用即生效"依赖 4.7.1 行为；该行为应在 OQ1 验证中原地复测，否则 handler 需加 `update()` 兜底。

### Specialist Disagreements
无。四视角结论一致：设计正确、边界清晰、确定性残留风险已妥善硬门禁。

### Nice-to-Have
- 房间 reshape（OQ3，`grid_resized`）清掉所有 solid 标志需全量 re-init——MVP 固定尺寸下仅为文档性，但 SaveLoad (#14) 设计时应预留 `grid_resized` 事件钩子。
- OQ2 假设 GridSystem origin `(0,0)`——`/create-architecture` 时应钉死 origin 约定，避免 Navigation 的 1:1 cell 假设在未来偏移。

### Scope Signal: M（producer should verify before sprint planning）
单一依赖（GridSystem）、2 公式、确定性门禁但无新 ADR（复用 AStarGrid2D）。

### Verdict: **APPROVED**
无设计层 blocking。唯一硬门禁（OQ1 tie-break）是已有且正确的实现期验证，不阻止设计落地。建议 systems-index 中 #5 状态由"Designed (待 /design-review)"更新为"Approved（独立复审通过）"。

> **独立度声明**：本轮复审由 Hermes 以单遍严格复审等效执行，4 个专家视角合并于一次审查，非并行独立 session。保真度低于 CCGS full 模式但高于原 session 内非独立补 pass。如需 full 级独立度，可在 `/clear` 后由 Claude Code 子代理编排重跑 `/design-review` full。
