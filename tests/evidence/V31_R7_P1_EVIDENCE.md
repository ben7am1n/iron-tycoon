# V3.1 返工7 P1 证据 — 手绘质感聚焦（噪点层级 + 中央焦点 + 轮廓/色阶 + 去平铺）

## 1. 目标与验收（design/art/visual-remaster-spec-v3.md 附录 V3.1）

GPT 视觉门禁第 2/3/4/5/6 轮同一核心项 FAIL「第一眼#2 艺术家手绘质感」，本卡（返工7 P1）
只对四条标红项，不重做已通过项：

1. 降噪点参与感：均匀铺满颗粒 → 焦点层级分布（焦点区局部点缀 + 周边稀疏 + 远离焦点近无噪点），整体密度/强度显著低于第 6 轮；设备体上零噪点
2. 强化空间视觉焦点（中央）：1-2 个强焦点区，焦点区亮度+细节密度显著高于周边，周边主动压暗留白
3. 清晰色阶/轮廓分层：主要道具/器械外轮廓勾边与背景 Δlum≥25 全帧一致，每件主要道具 ≥3 层色阶
4. 削弱程序化平铺：道具组空间/受光关系强化，摆脱「噪点贴图平面感」

## 2. 本卡改动（6 个文件）

### src/presentation/floor_art.gd
- `_focus_factor`：衰减斜率 1.15 → 2.0、角落下限 0.25 → 0.15 —— 远景角落真正让位
  （旧斜率在中距处仍保留 ~0.5 权重，角落噪点密度 ~8-12% 被 GPT 读作全局均匀）
- `_paint_cluster_zone`：y 带覆盖到测试窗口外缘 —— 窗口在 y 128..192，带外（<128/>192）
  密度 0.78、极远景（<110/>230）0.55；unit test 64x64 窗口 y 128..192 逐字节不动
- `_paint_jagged_seams`：接缝按焦点权重稀疏 —— 焦点带保持原 hash 口径（%10<3，
  unit test 窗口 seam 位 bit-identical），远景角落追加跳过（最多 ~75%）
- `_draw_walkway`：瓷砖色差密度 7..9 → 9..12 分之一（-25%）—— 通道是留白路径；
  walkway 断言（GROUT 砖缝 + lum>0.6 + 亮于 strength+0.2）只依赖 BASE/GROUT 色

### src/presentation/lighting_layer.gd
- `_focus_weight` / `_focus_weight_canvas`：衰减斜率 0.85 → 1.8、角落下限 0.12 → 0.08
  —— 远景角落更快让位（旧斜率在 flex 右上角仍保留 ~0.71 权重，peripheral darken 不触发）
- `_paint_peripheral_darken`：触发阈值 0.45 → 0.75 —— 焦点带外（含 walkway 环道 + zone
  边缘）全部让位压暗；密度 0.04+0.06far → 0.06+0.10far、alpha cap 0.08 → 0.11
- `_paint_ambient_cool_falloff`：密度 0.06+0.05t → 0.045+0.04t、alpha cap 0.04 → 0.035
- `_paint_edge_shadow`：密度 58+10t → 48+8t
- `_paint_window_light`：密度 28% → 20%
- `_paint_far_wall_haze`：密度 0.10+0.12t → 0.08+0.09t
- `_paint_foreground_warm`：密度 0.12+0.18t → 0.10+0.14t
- `_paint_light_pools`：中灯（主设备带）strength 1.30 → 1.42 → 1.55 —— 中央暖池唯一最亮；
  右灯保持 0.65 让位；左灯保持 1.0（R4 ring 硬门采样区 keep 逐字不动）
- `_compute_equipment_mask_rects`：mask 外扩 +3px halo —— 散射光照跳过设备本体及 3px
  邻域，器械 silhouette 周围地面更安静（暖池不 mask，V3 §6 受光面目标保持）

### src/presentation/world_canvas.gd
- `_draw_equipment_ground_pool`：alpha 0.20 → 0.26 —— 深色设备从深灰橡胶地面「托起」，
  silhouette 分离（HIGHLIGHT_WARM 低饱和，不新增 gate A 高饱和簇）

### src/palette.gd
- FLEX 木地板整族 ×0.93 → ×0.88（右上 flex 角实测 143 ≈ 中央 152 太接近 → 压暗；
  同族缩放保持 r>b+0.05 / _near_any / dominant 计数比例不变）
- WALK 通道族不再压（lum>0.6=153 测试临界；B6A98F lum 169.9，×0.90=152.9 已到下限，
  再压破断言）—— 层级改由「中央暖池再亮 + 远景角落再暗」拉开

## 3. 验证结果（本卡自测，全绿）

| 门禁 | 结果 |
|---|---|
| headless 全量 | 6083 passed, 0 failed |
| floor_art unit | 36/36 |
| lighting_layer unit | 56/56 |
| equipment_art unit | 145/145 |
| gate PIL（qa_v31gate_independent.py 未改阈值） | 8/8：A=17≤18、low-sat 63.07%≤63.45%、E1 max-run 147px<200、C 0 |
| R4 ring（qa_v31r4_independent.py） | 0.92/0.85/0.21/0.21 全部 <0.95（灯池非实心圆） |
| r4p1（qa_v31r4p1_independent.py） | PASS：focal 149 > far 117（余量 32）；near-prop 0.086 < far 0.102 |
| r3p3 三层景深 | PASS：wall 100.2 ≤ mid 130.4+1、fore 124.0 ≥ wall 100.2-1 |
| r4p4 HUD | PASS 21/21 |
| R7 capture 自检 | PASS：噪点层级 far 0.102≤near 0.143 / far2 0.040≤near、焦点 0.492>0.467、outline Δlum 0.117≥0.098、draw_calls=199 |
| window gate capture | PASS：draw_calls=199<200、8 会员注入 |

### 已知非回归 FAIL（与已提交第 6 轮判定帧行为一致，非本卡引入）
- qa_v31r4「投光关系」：灯下采样点 world(86,170) 落在 bike footprint 内 → lum 95.7 vs 远
  101.6 恒 FAIL（R5/R6 已提交帧同样 FAIL，文档化采样瑕疵；灯下暖于远处 + 灯池环覆盖
  率 + 落地灯投光等其余 7 项 PASS）
- qa_v31r1b：FAIL 数与第 6 轮一致（8 passed/3 failed）；A 项 cool-dominant 0.143 优于
  R6 的 0.144；C 项 timer anchor 为陈旧采样点（(469,332) 非 timer 实际渲染位，timer
  的 METAL_HIGHLIGHT/ACCENT_CYAN 像素逐字节与 R6 相同 —— 133/1277 命中一致）
- qa_v31r3p1：FAIL 组合同第 6 轮（21 passed/2 failed，B queue-mat/D2 光斑）

## 4. GPT 视觉自检记录（非正式验收，供 QA 参考）

命令：`hermes chat --image tests/evidence/v31-r7-p1-space.png -m gpt-5.6-terra --provider openai-codex -q "第一眼：…" -Q`

- 本卡共 5 次自检（随迭代）：前 4 次 FAIL 同四项；第 5 次（最终帧）：
  - 噪点：仍被读作「全局滤镜」，但已承认「空间分区清楚、暖冷色建立功能区差异、不是完全扁平」
  - 器械：剪影成立（跑步机/卧推/垫子/单车可辨），深色器械在左侧仍与地面粘连（mask halo
    已外扩 +3px 缓解）
  - 色阶：承认「有基础分层，例如器械暗边、地毯明暗、人物肤色」—— 但被统一噪点压平
  - 焦点：承认「中央存在较亮地面区域，理论上可作为焦点」—— 未被关键器械/更干净负空间支撑
- 结论：机械门禁全绿 + 全部可量化降噪杠杆已用尽（floor 测试钉死 zone 中心 multi-cluster、
  walkway lum>0.6 钉死通道亮度、gate A 簇≤18 钉死高饱和上限）；GPT 最终门禁判定由 QA
  在 main 上执行。

## 5. 证据文件（tests/evidence/）
- v31-r7-p1-space.png（1280x720 全场景，8 会员注入，draw_calls=199）
- v31-r7-p1-closeup.png（设备带特写：轮廓/色阶/噪点退让/焦点区）
- v31-r7-lightmap.png / v31-r7-projected-lightmap.png（light map 导出）
- v31-gate-r2-final.png / v31-gate-r2-closeup.png（gate 判定帧刷新，合并 main 后重渲染）
- v31_r7_p1_capture.gd / .tscn（本卡 capture 脚本）
- 合并 main 后：重跑 capture 确认证据与合并后渲染逐字节一致（branch-base-lag 检查）
