# Sprint 2 — 2026-08-04 to 2026-08-15

## Sprint Goal
完成 Foundation 层最后两个 epic（time-system + save-load，8 张 story），让「确定性时钟 + 存档读档」闭环落地，解锁 Core 层实现。

## Capacity
- Total days: 10（2 周）
- Buffer (20%): 2 days
- Available: 8 days（任务合计 8.5d，0.5d 由 buffer 吸收）

## Tasks

### Must Have (Critical Path)

| ID | Task | Agent/Owner | Est. Days | Dependencies | Acceptance Criteria |
|----|------|-------------|-----------|-------------|-------------------|
| TS-001 | SimulationOrchestrator and Tick Dispatch | godot-coder | 1.0 | — | AC-INIT-1/2, AC-NO-AWAIT；拓扑初始化 Tier 0-7；tick 顺序固定；tick_completed 信号 |
| TS-002 | Tick Accumulator, Speed Control, and Pause | godot-coder | 0.5 | TS-001 | 固定步进 10Hz；MAX_TICKS_PER_FRAME=8 catch-up；speed/pause 语义 |
| TS-003 | SeededRNG and Sub-Stream Derivation | godot-coder | 1.0 | TS-001 | AC-LSR-1（逻辑右移）；FNV-1a64→XOR→SplitMix64；get_rng 幂等；register_system 恰一次 |
| TS-004 | Serialization, Deserialization, and Resume | godot-coder | 1.0 | TS-001, 002, 003 | RNG state 直接恢复（hex_to_int）；tick_count/speed/pause 序列化 |
| SL-001 | SaveBlob Composition and Tick-Boundary Hook | godot-coder | 1.0 | TS-004 | AC-BLOB-1/2/3（8 键完整、master_seed 一致、4 系统缺席） |
| SL-002 | Load Orchestration — Phase A/B and Load Order | godot-coder | 1.5 | SL-001 | 两阶段 validate-then-commit；加载顺序程序化强制；all-or-nothing |
| SL-003 | Round-Trip Determinism and Resume-Paused | godot-coder | 1.5 | SL-002, TS-004 | 保存→加载→运行→再保存字节一致；加载后始终暂停（Core Rule 7） |
| SL-004 | File I/O, JSON Encoding, and Version Checking | godot-coder | 1.0 | SL-001 | AC-FILE-1/2/3/4（store_* 返回值检查、flush→close、损坏文件、版本 exact-match） |

**Must Have 合计：8.5 days**

### Should Have
（无 — 范围决策为"仅 Foundation 收官"，不并行其他 epic）

### Nice to Have
（无）

## Carryover from Previous Sprint
| Task | Reason | New Estimate |
|------|--------|-------------|
| — | Sprint 1 全部 14 story 完成（GridSystem 8 + EquipmentCatalog 7，含 EC-INTEGRATE） | — |

## Risks
| Risk | Probability | Impact | Mitigation |
|------|------------|--------|------------|
| TS-003 GDScript `>>` 算术移位陷阱 | Medium | High | ADR-0004 钉死 lsr() 辅助函数；垂直切片有已实现参考；AC-LSR-1 专项测试 |
| SL-003 Round-Trip 字节一致性 | Medium | High | ADR-0007 确定性门禁已 PASSED（10/10 位一致）；依赖系统 stub 协调 |
| 线性依赖链（TS-001→…→SL-004） | Low | High | 按序实现；TS-003 HIGH 风险先行验证节奏 |
| save-load 依赖 6 系统 serialize/deserialize | Medium | Medium | grid-system story-007 已提供 GridSystem 序列化；time-system story-004 先行 |

## Dependencies on External Factors
- MemberSim/Congestion/Satisfaction/Economy 的 serialize/deserialize 尚未实现（Core/Feature 层）——SL-003 测试用 stub 代替，标记为后续集成点

## Definition of Done for this Sprint
- [x] time-system 4/4 + save-load 4/4 story Complete
- [x] 全量测试增长（1040 → 1789）
- [x] QA plan exists (`production/qa/qa-plan-sprint-2-2026-08-02.md`)
- [x] All Logic/Integration stories have passing unit/integration tests
- [x] Smoke check passed (`production/qa/smoke-sprint-2-2026-08-02.md`)
- [x] QA sign-off report: APPROVED — 8/8 review cards PASS（qa-tester，每张独立 ff-merge + 独立 probe）
- [x] No S1 or S2 bugs in delivered features
- [x] Design documents updated for any deviations（各 story 文件头文档化）
- [x] Code reviewed and merged（gate t_e320fc1e 集成 04eba3c）
- [x] Foundation 层 4 epic 全绿 → 解锁 Core 层（placement-system + navigation）
