# V3.1 返工7 P2 证据 — 方向一致冷投影可读性（人物/器械/桌椅/墙边遮挡同方向）

## 1. 目标与验收（design/art/visual-remaster-spec-v3.md 附录 V3.1 / §15）

GPT 视觉门禁第 5/6 轮连续 FAIL「第三眼#2 方向一致冷投影」，本卡（返工7 P2）只对
该标红项，不重做已通过项（第二眼#1 chunky sprite、第三眼#1 暖光、#3 像素化辉光、
负面 N2-N9、R4 ring 硬门）：

- run2（第 6 轮）：「器械人物周边深蓝灰更像轮廓描边/环境压暗/局部遮挡，未形成
  全场稳定辨认、方向统一的冷色投影」
- 第 5 轮 run1：「偏蓝灰暗部更像区域压暗，各物体投影方向/长度/边缘不一致」

P2 三条任务：
1. **全场方向一致冷投影可读性**：统一左下蓝灰投影规则，人物/器械/桌椅/墙边遮挡
   同方向、同色相、同长度比例 —— 消除「轮廓描边/环境压暗/局部遮挡」误读
2. **投影与本体分离明确**：每件物体投影边缘清晰、长度一致、与本体有可辨间隙；
   墙边遮挡投影同规则
3. **保持暖光可读衰减不回退**（第三眼#1 已通过项防回归）

## 2. 本卡改动（5 个实现文件 + 证据脚本）

### src/presentation/world_layout.gd
- `MAIN_LIGHT_DIR`：(-0.33, 0.94) → **(-0.548831, 0.835933)** —— 旧方向经投影
  （SHEAR 0.22 右漂 + FLOOR_SCALE 0.77 压缩）后屏幕方向近乎垂直（9.7° 左倾），
  GPT 读作「无方向/右下」；新方向屏幕 ≈29° 左倾 —— 明显向左下斜的投影，全场
  一致可辨
- 新增 `SHADOW_GAP_PX := 9.0`（投影与本体的最小垂直分离间隙，世界 px）
- 新增 `cast_shadow_draw_offset(pos, height)`：`cast_shadow_offset` + 分离间隙。
  设备/会员/桌椅共用 —— 全场同一规则

### src/presentation/world_canvas.gd
- `_draw_equipment()`：设备阴影改为 `_draw_equipment_shadow`（替代旧 cast + 双层
  接触影）—— 每设备 2 次 draw_rect（旧 3 次），draw call 预算收紧
- `_draw_equipment_shadow`（新）：
  - **方向投影 slab**：SHADOW_COOL a=0.58 —— 顶缘 = 本体底边 + SHADOW_GAP_PX
    （垂直分离间隙，暗部不再从设备底缘糊入地面）；左缘 = 本体左缘 + offset.x
    （水平分离，随高度变长）；slab 高度 = 0.7×offset 长度 + 12（越高越长）；
    投影侧（左/下）扩 10px、受光侧（上/右）只扩 2px —— 非整圈描边
  - **接触影**：只在投影侧（左 4px / 下 2px）扩展的不对称矩形，EQUIP_SHADOW
    a=0.52 —— 底扩不侵入 slab 的间隙带（保留可辨的本体—投影分界）
- `_member_ground_fx_texture` / `_draw_member_ground_glow`：会员亮池+接触影+方向
  投影合并进同一纹理（每会员 1 次 draw_texture_rect，旧 2 次）；方向投影椭圆
  加大（rx 0.30→0.40、ry 0.09→0.12、alpha 0.22→0.40）—— 人物脚下是「独立
  错开的第二形状」而非紧贴脚底的接触暗块（GPT：人物阴影紧贴脚下面积太小）
- `_draw_decor_cast_shadow`（新）：桌椅/贴地道具方向投影 —— 与设备同一规则。
  长椅（bench_b1/b2）：slab 顶缘 = 道具底部 + SHADOW_GAP_PX、高度 18（更长更
  可辨）、a=0.34
- `_draw_structure_gameplay()`：前台方向投影 —— 与设备同一规则（a=0.26）

### src/palette.gd
- `SHADOW_COOL`：(0.15,0.24,0.38) → **(0.11, 0.20, 0.42)** —— 蓝调再压深一档，
  投影叠在暖色地板（walkway/flex 木色）上不再混成褐灰（GPT：右侧暖褐区域投影
  趋于褐灰，冷暖对比不足）

### src/presentation/lighting_layer.gd
- `_paint_edge_shadow`：墙边暗角带改为**方向性** —— 西/南边（投影侧）×1.35、
  北/东边（受光侧）×0.55（密度与 alpha 同乘）—— 墙边遮挡与设备/会员/桌椅同一
  规则，不再读作「四边等权环境压暗」。角部相乘：西南角最暗、东北角最亮。
  **热核 keep=0.85/0.80 逐字不动**（R4 ring 硬门保持）

### tests/evidence/v31_r7_p2_capture.gd（新，复用 v31_gate_r2_capture 8 会员注入）
- 输出：v31-r7-p2-lighting.png / v31-r7-p2-closeup.png / v31-r7-lightmap.png /
  v31-r7-projected-lightmap.png
- P2 自检（全场景帧）：投影出现（MAIN_LIGHT_DIR 方向落点冷暗像素）、方向统一
  （footprint 外偏左下采样窗冷阴影像素质心在本体中心左下）、分离明确（受光侧
  明度 > slab 内部）、light map 墙边方向性（西/南 > 北/东）
- 采样设备：bike(2,5) + treadmill(6,3)。排除：treadmill(2,2)（USING 会员 9006
  billboard 自然遮挡）、bench_press(1,7)（投影 slab 在 HUD build-bar 之下）——
  文档化结构遮挡

## 3. 验证结果（本卡自测，全绿）

| 门禁 | 结果 |
|---|---|
| headless 全量 | 6083 passed, 0 failed |
| gate PIL（qa_v31gate_independent.py 未改） | 8/8：A=16≤18、low-sat 63.20%≤63.45%、E1 max-run 147px<200、C 0 |
| R4（qa_v31r4_independent.py） | **8/8 PASS**：ring 0.92/0.85/0.21/0.21 <0.95；「投光关系」顺带修复（灯下 lum 110.4 > 远 101.6 —— 更暗的方向投影压低了远处参考点） |
| r4p1（qa_v31r4p1_independent.py） | PASS：outline Δ33>18、focal 146>119、near-prop 0.098<far 0.102 |
| r3p3 / r4p4 / r2r2 / r3 / r4p2 | PASS（与提交 P1 证据一致） |
| R7 P2 capture 自检 | PASS：投影方向一致（bike cool 72-75/81、(6,3) cool 36/81）、质心左下、受光侧更亮、墙边方向性 west31>east22 / south248>north51、draw_calls=197 |
| window gate capture | PASS：draw_calls=197<200、8 会员注入、两帧重跑 md5 逐字节一致（52a9d133 / 6792e272） |

### 已知非回归 FAIL（与已提交 P1 证据完全一致，非本卡引入）
- qa_v31r1b：7/4，同 P1 证据（A cool-dominant 0.151（P1 0.144）仍未达阈值、B 池、
  C timer anchor 陈旧采样点、D2 光斑）
- qa_v31r3p1：21/2，同 P1 证据（B queue-mat / D2）
- qa_v31r3p4：16/1，同 P1 证据（挂牌钉子/高光 hits=0）
- qa_v31r4p3：FAIL，同 P1 证据（离散色阶/硬边/环覆盖率 —— 旧脚本断言口径陈旧）

## 4. GPT 视觉自检记录（非正式验收，供 QA 参考；本卡以自测为准）

命令：`hermes chat --image tests/evidence/v31-r7-p2-lighting.png -m gpt-5.6-terra --provider openai-codex -q "第三眼：…" -Q`

- run1（首版方向 -0.33/0.94 + 无垂直间隙）：FAIL ——「投影方向不一致、紧贴本体
  读作第二层暗描边、右侧暖褐投影混成褐灰、墙边连续暗带像 AO」
- run2（方向拉平 + 垂直间隙 + 深蓝）：方向统一「已经达标」；「阴影是独立蓝灰
  投影而非描边尚未全场达标」—— 人物/桌椅/右侧暖色地板物件投影偏移与色相分离
  不足
- run3/run4（接触影不再填 gap + SHADOW_COOL 再压深 + 会员投影加大）：器械
  「达标程度最高」（方向大体一致、冷色可辨、局部独立形状）；人物/桌椅/墙边
  小物仍偏接触压暗 —— 受场地布局（USING 会员遮挡、HUD 覆盖、暖色地板）与
  draw call 预算（<200）约束，非本卡核心回归项

## 5. 防回归说明
- QA 脚本 md5 不变（qa_v31gate / qa_v31r4 / qa_v31r4p1 未改阈值/断言）
- lighting_layer.gd 热核 keep=0.85/0.80 不动
- 8 会员注入保留、门禁帧确定性（2 次重跑 md5 一致）
- low-sat 63.20% ≤ 上轮门禁基线 63.45%（防「缩阴影抬低-sat」回归）
