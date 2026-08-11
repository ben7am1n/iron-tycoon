# V3.1 返工6 P3 证据记录（照明/第三眼）

## 目标（任务书 FAIL 点，来自返工5 P3 第三眼 run1）

1. **第三眼#1 可读暖光照明** → 暖池三档离散亮度环（核心实色→次圈中档→外圈低档）
2. **第三眼#2 方向一致冷投影** → 全局主光方向 MAIN_LIGHT_DIR + 方向接触影
3. **第三眼#4 空间层次/物体分离** → 人物接触影更小更纯 + 亮池微升 + 投影 alpha 提升
4. 已通过项防回归：R4 ring<0.95、辉光像素化形态、噪点降密、焦点簇 ≤18

## 改动清单

| 文件 | 改动 |
|---|---|
| `src/presentation/world_layout.gd` | 新增全局主光方向 `MAIN_LIGHT_DIR`（(-0.35,1.0) 归一化，向西南/screen 左下）；`cast_shadow_offset` 从「最近灯泡逐物体」改为「全局统一方向」—— 投影方向/长度/边缘规则全场一致（GPT：各物体投影方向/长度/边缘不一致，暗部读作区域压暗 → 定向投影） |
| `src/presentation/lighting_layer.gd` | 暖池 alpha 从「8×8 块 hash 三档随机拼花」改为「metric 离散亮度环」：热核 0.64 实色 / 次圈 0.46 / 外圈 0.40（GPT：核心实色、次圈稀疏抖动、外圈更稀疏，非整片随机噪点）；keep=0.85/0.80 热核行逐字不动（R4 ring 保持） |
| `src/presentation/world_canvas.gd` | ①设备接触影沿 MAIN_LIGHT_DIR 偏移（外层×5/内层×3，近物深硬远端软化）—— 不再居中团块；②会员投影 alpha 0.16→0.19（人物/地面层次拉开）；③会员脚底亮池 alpha 0.10→0.12 + 接触影 rx 0.34→0.28、alpha 0.30→0.36（更小更纯，人物落地明确） |
| `tests/evidence/v31_r6_p3_capture.gd/.tscn` | R6 P3 证据脚本：全场景 8 会员注入 + closeup 2.5x 设备带 + lightmap + projected-lightmap 导出；内嵌验证含暖光衰减三档、投影方向一致、R4 ring、投光关系、draw_calls |

## 验证结果（worktree 内）

- **headless**：`TOTAL: 6083 passed, 0 failed` ✓
- **gate PIL**：`V3.1 GATE PIL RESULT: PASS (8 passed, 0 failed)`；A 簇 = **17**（≤18）✓；low-sat 63.40%→63.39%（gate 口径）
- **R4 ring**：r=10 0.92 / r=22 0.85 / r=34 0.21 / r=44 0.21，全部 <0.95 ✓（热核 keep 0.85/0.80 逐字未动）
- **R4P3 辉光形态**：`P3 GLOW FORM RESULT: PASS`（外缘硬边 24/24、离散色阶 2 档、外圈硬边 12/24、ring、投光、阴影向南 7 项全 PASS）
- **R4P1 噪点/焦点**：`RESULT: PASS`；low-sat 0.6294 ≤ 0.6313 ✓；focal 142 > far 117 ✓
- **R2R2 / R3P3 / R4P2**：全部 PASS
- **R1B / R3P1 / R3P4 / R4P4 / R4**：FAIL 项与已提交 R6P4 帧逐项同数（既有采样瑕疵，非回归）
- **draw_calls**：199 < 200 ✓（与 main 基线同数，未新增 draw）
- 内嵌 capture 验证：暖光衰减（热核 0.412 > 中圈 0.342 > 外圈 0.071）、投影方向全场一致、R4 ring、投光关系、会员在场全 PASS

## GPT 视觉自检（gpt-5.6-terra，2026-08-12，v31-r6-p3-lighting.png）

- **暖光衰减**：PASS —— 明确亮核向外过渡黄褐/棕灰，不是全屏橙滤镜；中部颗粒偏重但层级可读
- **冷色投影一致性**：PASS —— 器械/人物/落地灯投影总体朝右下/下方，深蓝灰阴影与暖光受光冷热关系可辨；长度随高度成立
- **层次分离**：PASS —— 深色轮廓+蓝灰投影把器械从暖褐地面抠出；人物肤色/衣物与器械主体区分明确
- **辉光像素化**：边界项 —— 无平滑圆/软滤镜（保持），但外圈仍被散点打碎（与 R5 同口径；r4p3 硬门 7/7 保持；「受控像素阶梯」已由三档 metric 环承担）

结论：3 项任务书 FAIL 点全部 PASS；辉光项为既有口径的边界讨论（硬门 QA 保持）。

## 合并后 main 复验

- gate 帧（v31-gate-r2-final.png）+ R6 P3 证据帧在合并后 main 上重渲染，逐字节一致
- gate PIL 基于 main 新鲜帧复验（A ≤ 18 保持）
