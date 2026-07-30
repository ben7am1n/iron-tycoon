# Architecture Review Report

**日期**: 2026-07-21 | **引擎**: Godot 4.7.1
**GDD 已审阅**: 17（16 系统 + concept） | **ADR 已审阅**: 7
**审查模式**: full | **Verdict**: CONCERNS ⚠️

---

## Traceability 摘要

| 系统 | TR 计数 | ADR 覆盖 | 缺口 |
|------|---------|----------|------|
| GridSystem | 15 | ADR-0001,0002,0003,0005 | 0 ✅ |
| EquipmentCatalog | 10 | ADR-0002 | 0 ✅ |
| TimeSystem | 8 | ADR-0001,0004,0005 | 0 ✅ |
| PlacementSystem | 12 | ADR-0001,0003,0005 | 0 ✅ |
| Navigation | 8 | ADR-0001,0003,0005,0007 | 0 ✅ |
| MemberSim | 14 | ADR-0001,0004,0005 | 0 ✅ |
| Congestion | 9 | ADR-0001,0003,0005 | 0 ✅ |
| Congestion/Flow Overlay | 11 | ADR-0005 | 0 ✅ |
| ZoneRules | 7 | ADR-0003 | 0 ✅ |
| Satisfaction | 10 | ADR-0001,0004,0005 | 0 ✅ |
| Economy | 9 | ADR-0001,0005,0006 | 0 ✅ |
| Shop/Purchase | 7 | ADR-0001,0005,0006 | 0 ✅ |
| SelectionSystem | 10 | ADR-0001,0005,0006 | 0 ✅ |
| SaveLoad | 8 | ADR-0001,0002,0004,0005,0007 | 0 ✅ |
| Build/Shop UI | 6 | ADR-0005 | 0 ✅ |
| HUD | 5 | ADR-0005 | 0 ✅ |
| **总计** | **149** | **149 已覆盖** | **0 缺口** |

**覆盖率**: 149/149 = **100%**
**状态**: ✅ 全部覆盖 | ⚠️ 部分: 0 | ❌ 缺口: 0

---

## 交叉 ADR 冲突检测

**结果**: **0 冲突** — 全部 7 份 ADR 相互一致。

### 逐对比较

| ADR Pair | 检测类别 | 结果 |
|----------|---------|------|
| 0001 ↔ 0002 | 集成契约 (init 签名 → 存储格式) | ✅ 一致 — ADR-0002 使用 0001 定义的 `init()` 签名 |
| 0001 ↔ 0003 | 类型层次 (SimSystem → GridStateReader) | ✅ 一致 — GridStateReader 正确扩展 SimSystem |
| 0001 ↔ 0005 | Tick Loop 定义 vs 信号编目 | ✅ 一致 — ADR-0005 细化 TickContext 与 0001 的硬编码序列 |
| 0002 ↔ 0004 | 数据编码 (64-bit hex → RNG 序列化) | ✅ 一致 — 统一使用 hex 字符串编码 |
| 0003 ↔ 0005 | 只读契约 vs grid_changed S1 | ✅ 一致 — 消费者类型正确匹配 |
| 0003 ↔ 0007 | is_solid() → rebuild 接口 | ✅ 一致 — GridSystem IS-A GridStateReader |
| 0005 ↔ 0006 | balance_changed S6 → credit() | ✅ 一致 — 扩展互补，无冲突 |

### 数据所有权验证

| 数据字段 | 拥有者 | 声明 ADR | 冲突？ |
|----------|--------|----------|--------|
| `occupant_id` | GridSystem | ADR-0001/0003 | ✅ 单一拥有者 |
| `balance` | Economy | ADR-0001/0005/0006 | ✅ 单一拥有者 |
| `tick_count` | TimeSystem | ADR-0001/0004/0005 | ✅ 单一拥有者 |
| `master_seed` | TimeSystem | ADR-0004 | ✅ 单一拥有者 |
| `instance_id` | PlacementSystem (分配), GridSystem (存储) | ADR-0001/0003 | ✅ 所有权明确分工 |
| `member_id` | MemberSim | ADR-0001 | ✅ 单一拥有者 |

### ADR 依赖顺序（拓扑排序）

```
Foundation:
  1. ADR-0001: DI Container & Scene Bootstrap（无上游依赖）
  2. ADR-0002: Storage Format（依赖 0001）

Core Contracts:
  3. ADR-0003: GridStateReader Contract（依赖 0001, 0002）
  4. ADR-0004: Seeded RNG Architecture（依赖 0001, 0002）
  5. ADR-0005: Signal Bus & Event Routing（依赖 0001, 0004）

Feature:
  6. ADR-0006: Economy Credit Interface（依赖 0005）
  7. ADR-0007: AStarGrid2D Determinism（依赖 0001, 0003, 0005）
```

**循环检测**: 无 ✅
**未解决的依赖**: 无 ✅
**状态为 Proposed 的依赖**: 全部 7 份 ADR 均为 Proposed（首次审查，无 Accepted ADR）

---

## GDD 修订标记（架构 → 设计反馈）

**结果**: **0 项** — 所有 GDD 假设与已验证的引擎行为一致。

GDD 已通过 prototype 验证回灌（#4 PlacementSystem、#5 Navigation、#8 Congestion/Flow Overlay 均已含 4.7.1 caveat 节）。无双重计数矛盾、无废弃 API 依赖。

---

## 引擎兼容性问题

**引擎**: Godot 4.7.1 | **ADRs 具备引擎兼容性节**: 7/7 ✅

| 严重度 | ADR | 问题 | 状态 |
|--------|-----|------|------|
| 🔴 HARD GATE | 0007 | AStarGrid2D 跨进程 tie-break 确定性**未经实测** — 10 个单独 headless 进程必须产生相同路径 | **BLOCKED UNTIL TESTED** |
| ⚠️ HIGH | 0001, 0003 | `@abstract` on RefCounted — 在 4.7.1 的 `RefCounted` 上未经实测。若失败则回退至手动 `_init()` 守卫 | **需在首个具体系统前实测** |
| ✅ LOW | 0002 | `FileAccess.store_*` return-bool (4.4+ breaking change) — ADR 正确检查返回值 | 已处理 |
| ✅ LOW | 0004 | GDScript `>>` 算术移位 — ADR-0004 定义 `lsr()` helper | 已处理 |
| ✅ LOW | 0005 | 双焦点输入系统 (4.6+) — bridge Node 使用 `_unhandled_key_input` 实现 focus-independent | 已处理 |

### 废弃 API 引用

**0 项** — 无 ADR 引用 `TileMap`、`yield()`、`Navigation2D` 或任何列出的废弃 API ✅

### 版本引用一致性

**7/7 ADR 一致引用 Godot 4.7.1** ✅ — 无陈旧版本引用

### Post-Cutoff API 冲突

**0 项** — 无两份 ADR 对同一 post-cutoff API 作矛盾假设

---

## 架构文档覆盖

来源: `docs/architecture/architecture.md`（v1.0, 2026-07-21）

### 系统映射完成度

全部 16 个 MVP 系统均出现于架构的 5 层之中 ✅

### 过时内容

| 位置 | 问题 | 影响 |
|------|------|------|
| ADR Audit 节（L323-332） | 声明 "No ADR files exist" — 实际已有 7 份 | 信息过时，对阅读者产生误导 |
| Traceability Coverage（L328-331） | 声明 "tr-registry.yaml is empty" — 技术上正确（`requirements: []`），但暗示可用性不足 | 需更新措辞为"就绪待填充" |

### 孤儿架构

**无** — architecture.md 中的所有模块均有对应 GDD ✅

### 缺失系统

**无** — systems-index.md 中所有 16 个 MVP 系统均在 architecture.md 中有模块条目 ✅

---

## Verdict: CONCERNS ⚠️

**不是 PASS** — 两项高风险项目待解决：
1. 🔴 **AStarGrid2D 跨进程确定性未经实测**（ADR-0007 HARD GATE）— 在门禁测试通过前 SaveLoad 不得开始
2. ⚠️ **`@abstract` on RefCounted 未经实测**（ADR-0001/0003）— 在写入首个具体系统前必须验证

**不是 FAIL** — 无 Coverage Gap、无交叉 ADR 冲突、无废弃 API 引用、无 GDD 修订标记。全部 149 项技术要求均已对应到 ADR。两项阻塞项均为范围明确、可操作的实测门禁，非架构缺陷。

---

## 阻塞性问题

| # | 问题 | 阻止 | 操作 |
|---|------|------|------|
| B1 | AStarGrid2D 跨进程 tie-break 稳定性**尚未实测** | SaveLoad (#14) 实现、MemberSim 路径缓存 | 编写并运行 `tests/unit/navigation/tiebreak_cross_rebuild_test.gd`（10 个单独 headless 进程） |
| B2 | `@abstract` on RefCounted **在 4.7.1 上未经实测** | 所有 `src/` 代码（SimSystem、GridStateReader 基类） | 在开始首个具体系统前于 headless 环境下测试 `SimSystem.new()` 和 `GridStateReader.new()` |

---

## 必需 ADR

全部 7 份必需 ADR 已完成。无缺失。无建议的新 ADR（当前全部已覆盖）。

---

## Phase 9: Handoff

### 立即行动

1. **编写并运行 `tiebreak_cross_rebuild_test.gd`**（unblock SaveLoad）
2. **验证 `@abstract` on RefCounted 在 Godot 4.7.1 headless 中的行为**（unblock 所有 src/ 代码）
3. **更新 architecture.md**：已过时的 ADR Audit 节和 Traceability Coverage 节

### Pre-Gate Checklist

| 检查项 | 状态 | 操作 |
|--------|------|------|
| `tests/unit/` 目录 | ❌ 不存在 | 运行 `/test-setup` |
| `tests/integration/` 目录 | ❌ 不存在 | 运行 `/test-setup` |
| `.github/workflows/tests.yml` | ❌ 不存在 | 运行 `/test-setup` |
| `design/accessibility-requirements.md` | ❌ 不存在 | 运行 `/ux-design` |
| `design/ux/interaction-patterns.md` | ❌ 不存在 | 运行 `/ux-design` |

### 重新运行触发器

"编写每个新 ADR 之后重新运行 `/architecture-review`，以验证覆盖率持续改善。"
