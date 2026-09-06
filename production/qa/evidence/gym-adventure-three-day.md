# GA-006 — 三天内容与进阶事件扩展验证

日期：2026-09-06。
覆盖目标：`production/epics/gym-adventure/story-006-three-day-content.md` (GA-006)。
设计基线：`docs/plans/2026-09-06-gym-adventure/experience-and-content.md` 与 `design/gdd/gym-adventure.md`。

## 验证结论

- **自动化与多日逻辑验证**：`tests/integration/gym_adventure/three_day_progression_test.gd`（**51 passed, 0 failed**）。
- **全量无头自动化回归套件**：`tests/headless_runner.gd`（**118 个测试文件，6,382 断言全量 passed，0 failed**）。
- **零沙盒污染**：沙盒模式与社区故事模式完全隔离，存读档相互独立，原有自由沙盒全量测试 100% 保持通过。

## 详细验收项对照

### 1. 课程选择与设备依赖 (GA-R04 / AC1)
- `select_course` 命令支持在 `course_endurance_intro`（新手耐力循环）与 `course_strength_intro`（基础力量循环）之间切换。
- **设备完整性校验**：未在场馆放置卧推架时，选择力量课严格返回错误提示（`"需要先购买并摆放卧推架"`）；成功放置卧推架（`bench_press`）与瑜伽垫（`yoga_mat`）后，切换成功并动态绑定对应器械实例 `[primary_id, secondary_id]`。
- **基础布局恢复兼容**：执行 `restore_layout` 恢复基础布局时，课程自动平滑回退至借用的新手耐力循环（实例 `[0, 1]`），无残留越界设备引用。

### 2. 林师傅场馆改造与美术联动 (GA-R08 / AC2 / AC6)
- **费用与账本原子扣款**：`renovate_gym` 命令检查当前现金，严格验证 `balance >= 120`；通过 `Economy.spend(120)` 扣除款项，提交 `gym_renovated` 永久事件。
- **幂等性与资金门禁**：已改造状态下再次调用严格拒绝（`"场馆已经改造过了"`）；资金不足时拒绝操作，不锁死主线故事推进。
- **视觉光照与招牌表现**：`LightingLayer` 接入 `set_renovation_provider`，在改造完成后于场馆入口门头（`Vector2(56, 28)`）呈现林师傅修复的霓虹青蓝光晕（`Color(0.18, 0.85, 0.95, 0.16)`）与强化的前台氛围光斑（`Color(1.0, 0.94, 0.78, 0.12)`）。

### 3. 第二天动线建议、阿洛对白与包场邀请 (GA-R09 / AC3)
- **首日动线反馈**：第二天准备阶段（Day 2 PREP）客观引用首日实际换站到站数据（`last_course_arrivals`），给出动线优化建议。
- **公园第二日对话**：阿洛在第二天公园探索中带来慢歌副歌新台词（`"阿洛：今天我换了段慢歌的副歌，感觉能跟上呼吸了。"`）。
- **打烊包场邀请**：在达成 `aluo_first_class` 且日序 `>= 2` 时，第二天打烊自动提交 `band_invitation`，并展开阿洛乐队四人来馆的对白与林师傅的改造提议。

### 4. 第三天乐队包场、到场事实与切片达成 (GA-R09 / AC4 / AC5)
- **四席乐队替换**：当 `band_invitation` 已激活且未完成时，第三天课程名册四席自动替换为乐队完整阵容（`singer_aluo`、`band_bass_aming`、`band_guitar_dawei`、`band_drum_xiaokai`）。
- **到场与开班事实**：课程准时开班时原子提交 `band_event_attended` 事件。
- **门槛判定与切片圆满**：四个训练块完成时，核验四位乐手各自训练时长均达到 75% 门槛（`>= 30s`），原子提交 `band_event_complete`，并在第三天打烊展现完整的乐队合影对白（程教练、阿洛、老邱三人对白），标志三天切片圆满达成。

### 5. 永久事件幂等性与跨日存读档 (GA-R10 / AC7)
- 永久事件集合 `[aluo_met, aluo_first_class, band_invitation, band_event_attended, band_event_complete, gym_renovated]` 具有严格集合去重保障，无重复发放。
- 经过完整 Day 1 -> Day 2 -> Day 3 推进并在任意打烊/阶段切换点序列化保存后，反序列化冷启动能 100% 精确复现日序、阶段、改造状态、选中课程与故事事件。
