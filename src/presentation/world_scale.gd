# src/presentation/world_scale.gd — V3 §2 世界缩放常量（单一来源）
#
# V3 低分辨率管线：世界像素空间（CELL_SIZE=32）→ SubViewport（426×240）的
# 统一缩放。所有需要知道世界缩放的模块（main.gd 装配、WorldCanvas 描边、
# presentation 层描边）preload 本文件 —— 禁止各文件各写各的 0.75。
#
# 4.7.1 PITFALL（probe 验证）：CanvasItem 描边宽度随节点 transform 缩放。
# 在 scale=0.75 下，1 世界 px 的 draw_line/draw_rect 描边 = 0.75 viewport px，
# 小于一个像素 → 栅格化后完全消失（无抗锯齿时亚像素线宽不渲染）。
# 修复：描边宽度乘 STROKE_COMPENSATION（= 1/0.75），使有效宽度 = 1.0
# viewport px（= 3 screen px，nearest 放大后），描边稳定渲染。
const WORLD_SCALE := 0.75
## 描边宽度补偿系数：1.0 世界 px → 1.0 viewport px。
const STROKE_COMPENSATION := 1.0 / WORLD_SCALE
