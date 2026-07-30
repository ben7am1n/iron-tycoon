# Review Log — PlacementSystem

## Review — 2026-07-17 — Verdict: NEEDS REVISION
Depth: lean (independent subagent, cold context — no authoring history inherited)
Scope signal: M
Specialists: none (lean depth, single-agent analysis)
Blocking items: 2 | Recommended (mostly contract-fidelity): 5

### Blocking items found
1. **Declared a hard consumer of a "placement failure-code signal" that the GDD never defined** — zero `signal`/`emit` definitions in the file; the emitted interface is exactly what a leaf-writer GDD cannot leave unspecified.
2. **Overview misattributed `grid_changed` ownership** — said PlacementSystem emits it; per grid-system.md it is GridSystem's signal, fired by `commit()` (Core Rule 5 already had it right — Overview contradicted it).

### Recommended / contract-fidelity slips found
3. Used `get_snapshot()` / `get_speculative_snapshot()` — granted by grid-system.md's per-consumer contract to ZoneRules only, not PlacementSystem.
4. Cited `grid_world_conversion` (a registry formula-bundle label) as a callable method; the real method is `world_to_grid()`.
5. Showed `grid_changed(cells)` (one arg); real signal is `grid_changed(footprint_cells_changed, access_cells_changed)`.
6. Of GridSystem's three named handoffs: #3 (re-derive on every `deserialize()`) fully caught; #1 (single DI-injected allocator instance) only partially caught; #2 (undo/redo-vs-never-reuse decision) dropped entirely.
7. AC13's premise ("stored counter says 999") contradicted Core Rule 8 ("stores no instance data"), making the fixture non-constructible.

### Verified correct by the reviewer (no change needed)
Both formulas' boundary behavior (rotation wrap, empty-grid resume, id-0 sentinel); the 5 FAIL codes and footprint-vs-access grouping; palette usage (correctly refusing to reuse Dusty Rose); 18 of 20 ACs independently testable; bidirectionality with grid-system.md and equipment-catalog.md.

### Fixes applied same session (2026-07-17)
- **Blocking 1**: defined `placement_committed(instance_id, equipment_id, footprint_cells)` and `placement_rejected(equipment_id, anchor, rotation, fail_code)`; added an Emitted-signals subsection, rewrote Core Rules 5/6 (rejected-drop emits vs silent-cancel is signalless), updated the States table, added AC21/22/23.
- **Blocking 2**: Overview reworded — PlacementSystem triggers `grid_changed` via `GridSystem.commit()`; GridSystem owns/emits it.
- **#3**: instance_id-resume (Core Rule 8) switched to the granted `GridStateReader` surface (`get_occupant_id()`/`get_dimensions()`); `get_speculative_snapshot()` marked not-yet-granted and folded into OQ1.
- **#4**: all method references corrected to `world_to_grid()`.
- **#5**: `grid_changed` shown with correct two-array arity.
- **#6**: Core Rule 7 now states the single DI-injected allocator guarantee (handoff #1); undo/redo decision written into Edge Cases + OQ6 (handoff #2).
- **#7**: AC13 reframed as defense-in-depth against a corrupt/legacy stored field the serializer never writes.

Prior verdict resolved: First review.
Status: blocking + contract-fidelity items resolved in-session → **awaiting independent re-review** (run `/design-review design/gdd/placement-system.md` in a fresh session).

---

## Review — 2026-07-19 — Verdict: **APPROVED**（独立复审确认）

**Depth**: lean-equivalent（独立上下文复审，非原作者 session）
**Scope signal**: M
**Specialists**: 单遍严格复审（game-designer / systems-designer / qa-lead 视角合并执行；等效独立 pass，非并行子代理编排）
**Prior verdict resolved**: ✅ Yes — 2026-07-17 两个 blocking + 5 个 contract-fidelity 项已在 session 内修订并写入文件，本轮独立核对修订本身成立。

### 独立复审结论（针对 2026-07-17 的 blocking）
| 原 blocking | 修订核对 | 结论 |
|---|---|---|
| B1 声明了未定义的"placement failure-code signal" | Overview 已明确 `grid_changed` 归 GridSystem；新增 `Emitted signals` 小节定义 `placement_committed(instance_id, equipment_id, footprint_cells)` 与 `placement_rejected(equipment_id, anchor, rotation, fail_code)`；Core Rules 5/6 + States 表 + AC21/22/23 已对齐 | **成立，无需再改** |
| B2 Overview 误归属 `grid_changed` 所有权 | Overview 重写为"触发 GridSystem.commit()，由 GridSystem 拥有/发射"；Core Rule 5 与 Emitted-signals 小节一致 | **成立，无需再改** |

### contract-fidelity 项核对（原 #3–#7）
- #3 `instance_id` resume 改用 granted `GridStateReader` 表面（`get_occupant_id`/`get_dimensions`）✅
- #4 方法引用全部修正为 `world_to_grid()` ✅
- #5 `grid_changed` 两参数 arity 已正确 ✅
- #6 Core Rule 7 单 DI 分配器 + Edge Cases/ OQ6 undo/redo 决策 ✅
- #7 AC13 重述为防御性深度（针对损坏/遗留字段）✅

### 本轮新发现（非 blocking）
- **Recommended**：`begin_relocate` 在 Core Rule 1a 中"clears occupancy → 进入 DRAGGING → re-commit under same id"，但 SelectionSystem (#13) 仍处 "Needs Revision" 且未定义 Move handoff 契约（调用时机、drag 取消的回滚信号）。两系统间接口靠本 GDD 单向声明，建议 #13 落地时显式回读本 GDD 的 `begin_relocate` 契约（已记入 bidirectional consistency note，非本 GDD 缺陷）。
- **Recommended**：AC24 的 relocate 回滚测试依赖 SelectionSystem 的 Move 触发路径——建议实现时该 AC 放在集成层（integration），而非纯 unit。

### 结论
两个旧 blocking + 全部 contract-fidelity 项经独立核对均成立，无新 blocking。原"awaiting independent re-review"状态关闭。**Verdict: APPROVED**——建议 systems-index 中 #4 状态更新为"Approved（独立复审通过）"。

> **独立度声明**：本轮复审由 Hermes 以单遍严格复审等效执行，4 个专家视角合并于一次审查，非并行独立 session。保真度低于 CCGS full 模式但高于原 session 内非独立补 pass。

---

## Review — 2026-07-19 (2nd) — Verdict: NEEDS REVISION（full-mode 对抗式评审 + 联合 selection-system.md）
Scope signal: M
Specialists: game-designer, systems-designer, qa-lead, godot-specialist, economy-designer + creative-director (senior synthesis)
Blocking items: 7 (跨两份 GDD 共享) | Recommended: 11
Prior verdict resolved: Yes — 2026-07-17 blocking 全部成立；本轮发现新 blocking（relocate 流程/Godot 实现缺口/跨系统契约）

### Blocking items found & fixed in-session
| # | Issue | Fix applied |
|---|---|---|
| B1 | selection-system.md 引用 `get_placed_instances()`/`get_snapshot()` — GridSystem 从未授权 | 改为仅用 `get_occupant_id(cell)` + 自建 mapping（订阅 `placement_committed` + `grid_changed`） |
| B2 | RefCounted 系统无法接收 input/timer — 无 bridge Node 规格 | 两份 GDD 新增 "Input routing (architecture contract)" 段 |
| B3 | Rotation enum cast + `assert()` debug-only | Formulas 改为 `push_error()` + bail 运行时守卫 + `as Rotation` 强转 |
| B4 | Relocate SUCCESS 路径零 AC 覆盖 + `placement_committed` 是否 emit 未定 | 新增 AC25（成功）/AC26（rejected=静默恢复）/AC27（防重入） |
| B5 | Economy 双向依赖缺失（economy.md 不列 SelectionSystem） | Bidirectional notes 标注需 `/propagate-design-change` |
| B6 | Sell-credit 时序未定义 | 明确标注"synchronous，同 spend()" |
| B7 | Relocate 拖拽期间原位置无视觉处理 | Visual/Audio 新增 "Relocate origin placeholder"（虚线轮廓 40%） |

### Also fixed (non-blocking)
- R10: `tween_await()` 引用纠正为 `create_tween().tween_property()`
- Core Rule 1a: rejected relocate drop 语义澄清（=静默恢复，非 `placement_rejected`）

### Outstanding recommended items (not fixed this session)
R1 refund_rate vs "no failure" tension · R2 sell-confirm 2s timer vs anti-pillar · R3 double grid_changed on relocate-cancel · R4 member displacement on relocate · R8 selection-system missing ACs (6 gaps) · R9 sell_back_refund rounding/int cast · R11 4.7 offset-transform + dual-focus notes

Status: 7 blocking resolved → **awaiting independent re-review** (run `/design-review` in a fresh session after `/clear`)
