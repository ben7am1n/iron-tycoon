# V3.1 返工7 P3 证据 — 空间层次 / 物体分离（终版）

- 分支/提交：`wt/t_b64d105b` → main `a758f97`（含 P4 合并 `b6d94d3`）
- 复验口径：**本卡合并到 main 后，在 main 上重新渲染的新鲜帧**
  （branch-base-lag；工作树渲染帧与 main 渲染帧 md5 一致，均通过全部门禁）
- 帧：`tests/evidence/v31-r7-p3-space.png`（md5 `58d856c4f537baa348159c1fe4d9c431`，
  两次独立渲染字节一致 —— 确定性）
- 渲染：`tests/evidence/v31_r7_p3_capture.gd/.tscn`（8 会员在场注入，V3.1 全链路，
  复用 v31_gate_r2_capture 注入列表 —— 门禁最终帧字节一致）

## 任务书三线（FAIL 第三眼#4 → 修复）

1. **纵深分层**（前景/中景/背景梯度）：
   - 背景墙带退暗：LIGHT_WINDOW_COOL 空气透视密度 0.08+0.09t → 0.16+0.18t、
     alpha cap 0.06 → 0.12（墙带 mean 128 > 地板 117 的旧纵深倒挂消除）。
   - 自检：mid 0.522 > bg 0.393（中景亮于背景墙带）；fore 0.471 ≥ bg−0.01
     （r3p3 同口径）；r3p3 独立门 wall 100.2 < mid 133.1、fore 123.8 ≥ wall−1 PASS。
2. **物体分离**（深色器械/暖色地面，Δlum≥25 硬门）：
   - 设备正面再压暗一档 0.55 → 0.62（EQUIP_SHADOW_TONE lerp；顶面受光不暗化）
     —— bike(2,5) 前缘 Δlum 0.129 ≥ 0.098（≈33/255）、treadmill 0.204、
     yoga_mat 0.213、bench_press 0.183、会员 m9002 0.310 / m9004 0.117、
     bench_b1 0.320 / bench_b2 0.333 —— 全过 25 硬门。
   - 暖池 0.26 + 接触影 0.52 + slab 0.58（P4 值回退，见 low-sat 三轮回退记录）。
3. **层次叠加**：CLOSEUP USING 会员锚定设备之上 PASS；设备顶面受光带不横切腰胯。

## 门禁结果（main 渲染帧）

| 门禁 | 结果 |
|---|---|
| qa_v31gate_independent | PASS 8/8（A 簇 18 ≤ 18；low-sat 62.75% ≤ 63.45%） |
| qa_v31r4_independent | PASS（ring 0.92/0.85/0.27/0.27 < 0.95） |
| qa_v31r4p1_independent | PASS（near 0.093 < far 0.102；low-sat 0.6249 ≤ 0.6313） |
| qa_v31r3p3_independent | PASS（三层景深 + 前景 ≥ 背景−1） |
| qa_v31r2r2_independent | PASS 9/9 |
| qa_v31r3_independent | PASS 9/9 |
| qa_v31r4p2_independent | PASS |
| qa_v31r4p4_independent | PASS 21/21 |
| headless 全量 | **TOTAL: 6083 passed, 0 failed** |
| 性能 | draw_calls=197 < 200（V3 §15） |
| 确定性 | space md5 `58d856c4…` 两次渲染一致 |

## 三轮 low-sat 回退记录（r4p1 基线 0.6313 硬门）

P3 首版尝试「strength 地板整族提亮（78.7→92.8）拉明度差」—— 提亮后左灯
暖池叠在更亮灰蓝底上 sat 0.26→0.235 翻入 low-sat，且 r4p1 近带噪点升。
三轮回退最终回到 P4 值组合：
1. 地板提亮 → 回退原色阶（palette.gd 注释保留决策记录）。
2. 左灯池 strength 1.28/1.18 → 1.0；halo 6px → 3px；前景暖带 0.14+0.18t → 0.10+0.14t。
3. slab 0.54 → 0.58、接触影 0.46 → 0.52（低 alpha 放出 sat<0.25 底色翻入
   low-sat —— 采样 (264,258) cur=(80,88,103) sat 0.223 vs P4 0.267）。
   分离改由设备正面压暗 0.62 单独承担（bike Δlum 0.129 ≥ 0.098 保持）。

最终 low-sat 0.6249（P4 帧同值）—— P3 净贡献：设备正面压暗 + 墙带退暗，
不抬 low-sat、不抬噪点、不碰 A 簇（18 保持）。

## 已知非正式反馈（GPT 视觉自检，2026-08-13，仅咨询）

- 纵深已有前中后层；器械/人物大多可分离。
- 左侧/中央深蓝阴影仍偏重、局部吞轮廓；右侧橙棕区偏亮偏噪 —— 已在
  门禁约束内处理（slab/接触影回退是 low-sat 硬门的强制结果；影子方向
  一致门与物体分离自检保持）。正式门禁为契约，本项不作为阻塞项。

## 文件

- `src/palette.gd` — FLOOR_STRENGTH 注释（决策记录；值回退 P4）
- `src/presentation/equipment_art.gd` — 正面压暗 0.55→0.62
- `src/presentation/lighting_layer.gd` — 墙带空气透视密度/alpha 提升；
  左灯池、halo、前景暖带回退 P4
- `src/presentation/world_canvas.gd` — slab/接触影回退 P4（注释记录）
- `tests/evidence/v31_r7_p3_capture.gd/.tscn` — P3 证据捕获 + 自检
- `tests/evidence/v31-r7-p3-space.png` / `-closeup.png` — 全场景帧/特写
- `tests/evidence/v31-r7-lightmap.png` / `-projected-lightmap.png` — 灯光图
