# Sprint 3 — 2026-08-17 to 2026-08-28

## Sprint Goal
实现 Core 层两个 epic（placement-system 7 story + navigation 6 story，共 13 张），让「拖放建造 + 确定性寻路」闭环落地——游戏核心循环真正成形，解锁被隔离的 `core_loop_test`。

## Capacity
- Total days: 10（2 周）
- Buffer (20%): 2 days
- Available: 8 days（任务合计 12.5d——两链并行 + Kanban 自动化速度吸收；用户确认按计划推进）

## Tasks

### Must Have (Critical Path)

**PlacementSystem 链（7 story，LOW 风险）**

| ID | Task | Agent/Owner | Est. Days | Dependencies | Acceptance Criteria |
|----|------|-------------|-----------|-------------|-------------------|
| PL-001 | Drag Lifecycle — Start, Preview, Rotation | godot-coder | 1.0 | grid-system 001-006, equipment-catalog 001 | 拖拽→实时 can_place 预览（零变更）；旋转归一化 0/90/180/270 |
| PL-002 | Commit-on-Drop — Success Path | godot-coder | 1.0 | PL-001 | 有效 drop → GridSystem 原子 commit + 新 instance_id |
| PL-003 | Rejected Drop and Silent Cancel | godot-coder | 1.0 | PL-002 | FAIL 分支静默取消；零写入；placement_rejected 信号 |
| PL-004 | instance_id Resume After Load | godot-coder | 0.5 | grid-system 007 | 加载后计数器从 max occupant_id 重派生 |
| PL-005 | Relocate Flow | godot-coder | 1.5 | PL-002, PL-004 | 搬移同 id 重提交；取消/失败静默恢复；不递增计数器 |
| PL-006 | is_dragging Query and Cost Scope | godot-coder | 0.5 | PL-001 | 同步查询；Shop/Purchase 消费；成本作用域正确 |
| PL-007 | Input Bridge and Event Forwarding | godot-coder | 1.0 | PL-005, PL-006 | 屏幕坐标→网格转换；桥接 Node 转发；placement_committed/rejected |

**Navigation 链（6 story，MEDIUM 风险）**

| ID | Task | Agent/Owner | Est. Days | Dependencies | Acceptance Criteria |
|----|------|-------------|-----------|-------------|-------------------|
| NV-001 | AStarGrid2D Configuration and Basic Paths | godot-coder | 1.0 | grid-system 002, 006 | DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES + HEURISTIC_OCTILE + jumping=false |
| NV-002 | Diagonal Mode and Corner Clipping Rules | godot-coder | 1.0 | NV-001 | 对角仅当两侧正交开阔；不裁剪实心角 |
| NV-003 | Path Query Edge Cases | godot-coder | 0.5 | NV-001 | 空路径/同格/不可达→空数组 |
| NV-004 | Solidity Sync via grid_changed | godot-coder | 1.0 | NV-001 | set_point_solid + update() 顺序（4.7.1 修正）；订阅 S1 |
| NV-005 | Determinism Gate and Congestion Blindness | godot-coder | 1.0 | NV-003 | ADR-0007 门禁复验；路径仅静态占用 |
| NV-006 | Rebuild-on-Load and cell_size Independence | godot-coder | 1.0 | NV-004 | 加载后从占用重建；不序列化 AStarGrid2D |

**Must Have 合计：12.5 days**

### Should Have / Nice to Have
（无 — 范围决策为"仅 Core 两 epic"）

## Carryover from Previous Sprint
| Task | Reason | New Estimate |
|------|--------|-------------|
| — | Sprint 2 全部 8 story 完成（time-system 4 + save-load 4），Foundation 4 epic 全绿 | — |

## Risks
| Risk | Probability | Impact | Mitigation |
|------|------------|--------|------------|
| NV-002 对角模式/角裁剪语义 | Medium | Medium | ADR-0007 钉死配置；AStarGrid2D 已实测（ADR-0007 门禁 PASSED） |
| PL-005 Relocate 不递增 instance_id | Low | Medium | AC 明确；与 PL-004 计数器语义衔接 |
| 容量 12.5d vs 8d 可用 | High | High | 两链并行（PL ∥ NV）；Kanban 自动化推进；必要时 PL-007 延后 |
| `core_loop_test` 解锁依赖全部 Core 系统 | Medium | Medium | 测试已写好待解锁（隔离设计）；本 sprint 完成即解锁 |

## Dependencies on External Factors
- MemberSim/Congestion/Satisfaction/Economy（Feature 层）在 SL-003 用 stub 标记的集成点——Core 层完成后进入 Feature 层实现
- `core_loop_test` / `core_smoke_test` 解锁条件 = Core 层 epic 实现

## Definition of Done for this Sprint
- [ ] placement-system 7/7 + navigation 6/6 story Complete
- [ ] 全量测试增长（1789 → 预计 2200+）
- [ ] `core_loop_test` 解锁通过
- [ ] QA plan exists (`production/qa/qa-plan-sprint-3.md`)
- [ ] All Logic/Integration stories have passing unit/integration tests
- [ ] Smoke check passed (`/smoke-check sprint`)
- [ ] QA sign-off report: APPROVED or APPROVED WITH CONDITIONS (`/team-qa sprint`)
- [ ] No S1 or S2 bugs in delivered features
- [ ] Code reviewed and merged
- [ ] Core 层 2 epic 全绿 → 解锁 Feature 层（MemberSim 等）
