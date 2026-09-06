# GA-004 — 首日可玩主场景与控制呈现验证

日期：2026-09-06。
覆盖目标：`production/epics/gym-adventure/story-004-first-day-playable.md` (GA-004)。

## 验证结论

- **全量测试套件**：116 个测试文件全部通过，**6306 passed, 0 failed**（Headless Runner 驱动）。
- **可玩集成探针**：`tests/integration/gym_adventure/first_day_playable_test.gd`（45 passed, 0 failed）。
- **真实窗口渲染截图**：经 Godot 4.7.1 Metal Forward+ 渲染生成 4 张阶段视口证据（非伪造、非画板模拟）：
  - `gym-adventure-prep.png`（备店阶段：程教练站立、借用设备与底部布置栏控制）
  - `gym-adventure-park.png`（外出阶段：红陶土跑道、阿洛位置、体力量表与走/慢跑/冲刺配速控制）
  - `gym-adventure-service.png`（营业阶段：首日 4 会员按课表到馆在真实器械上训练、程教练在场浮动提示）
  - `gym-adventure-close.png`（打烊阶段：结算对话、专属存档保存与读档）

## 详细验收项对照

1. **入口与存档隔离 (AC1 / AC6)**：
   - `src/main.gd` 支持 `--community` / `--sandbox` CLI 参数与右上角模式切换按钮。
   - 社区故事使用独立槽位 `user://saves/gym-adventure.sav.json`，沙盒使用 `manual.sav.json`。
   - `SaveLoad` 校验 `mode_id`：沙盒加载器拒绝社区存档，社区模式加载器拒绝沙盒存档，零串存与零覆盖。
2. **首日完整循环控制 (AC2 / AC4)**：
   - **PREP**：程教练在馆内 2.5D 斜投影空间受 WASD 移动；按 B 或“进入布置”打开购买底栏；购买设备可放置；借用设备（id 0, 1）受保护禁止出售；支持“恢复基础布局”。
   - **OUTING**：点击“出发前往公园”切至公园视图；按 E 与阿洛交谈记录 `aluo_met` 剧情事件；开启挑战后 1/2/3 键控制走、慢跑、冲刺配速；消耗体力推进米数；点击“返回拳馆”结束挑战。
   - **SERVICE**：外出阶段与营业阶段全面禁用布置模式（按 B 无效，按钮隐藏）；4 名预约会员按时到馆并在真实器械（跑步机/单车）上训练；程教练头顶冒出 `[E 指导]` 交互气泡；数字键 1/2/3 进行课中指导选择与节奏确认。
   - **CLOSE**：营业倒计时结束自动进入打烊阶段；弹出收工结算对话；自动保存进度；支持按次日按钮进入第二天 PREP。
3. **中文无遮挡 HUD 与世界呈现 (AC3 / AC5)**：
   - `src/ui/community_hud.gd` 呈现中文阶段标牌、当前目标、时间流速与体力量表，不使用遮挡中央画面的调试大面板。
   - `src/presentation/coach_layer.gd`：斜投影程教练（深青色夹克、脚底阴影、面朝向、指导气泡）。
   - `src/presentation/park_view.gd`：三段式红陶土跑步道、距离门标、阿洛角色（吉他与对话提示）、冲刺残影条纹。
4. **存读档冷恢复 (AC6 / AC7)**：
   - 读档后自动进入显式暂停（PAUSED），清空未决交互与拖放态，完整恢复体力、金币、设备布局与课表进度。

## 视口截图证据索引

- 备店阶段：[gym-adventure-prep.png](gym-adventure-prep.png)
- 外出阶段：[gym-adventure-park.png](gym-adventure-park.png)
- 营业阶段：[gym-adventure-service.png](gym-adventure-service.png)
- 打烊阶段：[gym-adventure-close.png](gym-adventure-close.png)
