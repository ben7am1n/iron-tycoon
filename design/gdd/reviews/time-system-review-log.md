# Review Log — TimeSystem + SimulationOrchestrator + SeededRNG

## Review — 2026-07-17 — Verdict: NEEDS REVISION
Depth: lean (independent subagent, cold context — no authoring history inherited)
Scope signal: L
Specialists: none (lean depth, single-agent analysis)
Blocking items: 3 | Recommended: 5

### Blocking items found
1. **`get_rng()` contract self-contradictory** — AC6 required a repeated `get_rng(name)` call to return the same stream; AC15 + the duplicate-name edge case required a second same-name call to fail. A single name-keyed accessor cannot do both.
2. **Pause/speed state machine contradicted its own edge case** — States table said "picks a speed → RUNNING" (unpauses), but the edge case + AC18 said a speed choice while paused is inert until an explicit resume.
3. **SplitMix64 uses logical shift; GDScript `>>` is arithmetic** — for ~half of seeds (high bit set), sign-extension breaks the "bijective avalanche / uniform" justification the formula rests on. Determinism survived, but the distribution rationale did not. AC13 golden-vector unauthorable until pinned.

### Recommended (not blocking, logged for a later pass)
- Godot PCG RNG streams are isolated but not statistically independent; AC7 weakly testable.
- No guard against a downstream system calling engine-global `randf()`/`randomize()` (determinism hole); suggest a grep check like Rule 5's.
- No max-accumulator / OS-sleep catch-up policy (a Pillar-2 fast-forward risk).
- FNV-1a constants not pinned (needed for AC13 reproducibility).
- Serialized `paused` is dead data (load always forces PAUSED).

### Fixes applied same session (2026-07-17)
- **Blocking 1**: split into `register_system(name)` (once; duplicate → hard error) + idempotent `get_rng(name)`. Rewrote Core Rule 6, the duplicate-registration edge case, AC6, AC15.
- **Blocking 2**: States table now has two PAUSED rows — "presses resume → RUNNING(last_speed)" and "picks a speed → stays PAUSED (records last_speed)". Consistent with edge case + AC18.
- **Blocking 3**: formula now specifies a mandatory `lsr()` logical-shift helper and pins FNV-1a constants (offset 0xCBF29CE484222325, prime 0x100000001B3); output-range note and OQ4 updated; registry `rng_subseed_derivation_formula` note updated to match.
- Recommended items 1–3 and 5 deliberately deferred to the next revision pass (not blocking); FNV pinning (item 4) done as part of Blocking 3.

Prior verdict resolved: First review.
Status: blocking items resolved in-session → **awaiting independent re-review** (run `/design-review design/gdd/time-system.md` in a fresh session).

---

## Review — 2026-07-19 — Verdict: **APPROVED**（独立复审确认）

**Depth**: lean-equivalent（独立上下文复审，非原作者 session）
**Scope signal**: L
**Specialists**: 单遍严格复审（game-designer / systems-designer / qa-lead / godot-specialist 视角合并执行；标注为等效独立 pass，非并行子代理编排）
**Prior verdict resolved**: ✅ Yes — 2026-07-17 三个 blocking 已在 session 内修订并写入文件，本轮独立核对修订本身成立。

### 独立复审结论（针对 2026-07-17 的 3 个 blocking）
| 原 blocking | 修订核对 | 结论 |
|---|---|---|
| B1 `get_rng()` 契约自相矛盾 | Core Rule 6 已拆为 `register_system(name)`（一次；重复→hard error）+ 幂等 `get_rng(name)`；重复注册 edge case、AC6、AC15 已对齐 | **成立，无需再改** |
| B2 暂停/变速状态机自相矛盾 | States 表已含两行 PAUSED（resume→RUNNING(last_speed) / picks speed→stays PAUSED 记 last_speed）；与 edge case + AC18 一致 | **成立，无需再改** |
| B3 SplitMix64 逻辑移位 | 已强制 `lsr()` 逻辑移位 helper 并钉死 FNV-1a 常量（offset 0xCBF29CE484222325 / prime 0x100000001B3）；Output Range 注记与 OQ4 已同步 | **成立，无需再改** |

### 本轮新发现（非 blocking，记为 contract-fidelity 提示）
- **Recommended**：`get_rng()` 返回 `RandomNumberGenerator` 实例，但 GDScript `RNG` 实例的 `seed` 属性（不是 `RandomNumberGenerator`）才接受 int64——`serialize()` 复原 `per_system_rng_states` 时须确认使用的是 `RandomNumberGenerator.seed`（接受 int64）而非 `RNG.seed`。属实现层细节，不影响 GDD 契约正确性，OQ4 已覆盖 golden-vector 锁定。
- **Recommended**：下游系统（MemberSim/Congestion 等）不得调用引擎全局 `randf()`/`randomize()`——建议加一条与 Core Rule 5 同类的静态 grep 检查（确定性的横向门禁）。GDD 本身正确，此为 OQ4 的自然延伸。

### 结论
三个旧 blocking 修订经独立核对均成立，无新 blocking。原"awaiting independent re-review"状态关闭。**Verdict: APPROVED**——建议将 systems-index 中 #3 状态由"In Review (blocking 已修，待复审)"更新为"Designed (待 /design-review)"或"Approved（独立复审通过）"。

> **独立度声明**：本轮复审由 Hermes（非 Claude Code 子代理编排）以单遍严格复审等效执行；game-designer / systems-designer / qa-lead / godot-specialist 四个视角合并于一次审查，非 4 个并行独立 session。其保真度低于 CCGS full 模式的 5-agent 并行对抗，但高于原 session 内"非独立补 pass"。如需 full 级独立度，可在 `/clear` 后由 Claude Code 子代理编排重跑 `/design-review` full。
