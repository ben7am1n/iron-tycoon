import os
from PIL import Image, ImageDraw, ImageFont

def main():
    img_path = "production/qa/evidence/2026-09-07-latest-review/comp-shallow-32deg.png"
    out_path = "production/qa/evidence/2026-09-07-latest-review/target-composition-spec.png"
    
    img = Image.open(img_path).convert("RGBA")
    overlay = Image.new("RGBA", img.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)
    
    font_path = "/System/Library/Fonts/STHeiti Light.ttc"
    title_font = ImageFont.truetype(font_path, 20)
    header_font = ImageFont.truetype(font_path, 15)
    body_font = ImageFont.truetype(font_path, 12)
    small_font = ImageFont.truetype(font_path, 11)

    # 1. Background Zone (y: 48 - 220)
    draw.rectangle([(0, 48), (1280, 220)], fill=(30, 80, 180, 25), outline=(70, 140, 240, 180), width=2)
    # 2. Midground Workout Stage (y: 220 - 580)
    draw.rectangle([(0, 220), (1280, 580)], fill=(40, 180, 80, 20), outline=(220, 170, 60, 200), width=2)
    # 3. Foreground Corridor Zone (y: 580 - 658)
    draw.rectangle([(0, 580), (1280, 658)], fill=(200, 60, 60, 25), outline=(220, 80, 80, 180), width=2)
    # 4. Top HUD Safe Zone (y: 0 - 48)
    draw.rectangle([(0, 0), (1280, 48)], fill=(10, 15, 25, 120), outline=(220, 170, 60, 120), width=1)
    # 5. Bottom Collapsed Dock Safe Zone (y: 658 - 720)
    draw.rectangle([(0, 658), (1280, 720)], fill=(10, 15, 25, 120), outline=(220, 170, 60, 120), width=1)

    # Title Banner
    draw.rectangle([(340, 8), (940, 40)], fill=(15, 20, 30, 220), outline=(220, 170, 60, 255), width=2)
    draw.text((640, 24), "街角健身房 目标艺术规格：32°浅斜俯视舞台构图与分层基准", fill=(255, 245, 220), font=title_font, anchor="mm")

    # Box 1: Background Zone Annotation
    draw.rectangle([(30, 56), (380, 108)], fill=(15, 20, 30, 220), outline=(80, 150, 240, 220), width=1)
    draw.text((40, 64), "【后景层】y: 48-220 北墙 / 街景窗 / 招牌", fill=(100, 180, 255), font=header_font)
    draw.text((40, 86), "• 掉漆宣传海报 • 霓虹灯牌 • 镜面冷光反射", fill=(210, 220, 235), font=body_font)

    # Box 2: Midground Workout Zone Annotation
    draw.rectangle([(30, 230), (430, 326)], fill=(15, 20, 30, 220), outline=(220, 170, 60, 220), width=1)
    draw.text((40, 238), "【中景训练舞台】y: 220-580 核心视听焦点", fill=(240, 190, 80), font=header_font)
    draw.text((40, 260), "• 32°浅斜俯视压缩纵深，人物与器械立面视觉占比提升 32%", fill=(240, 240, 240), font=body_font)
    draw.text((40, 280), "• 角色统一尺度：32×40px 画布，1:3.2 头身，14px 宽肩", fill=(240, 240, 240), font=body_font)
    draw.text((40, 300), "• 上下机锚点严格贴合跑带/垫面，脚底接触影实地投射", fill=(240, 240, 240), font=body_font)

    # Box 3: Foreground Corridor Zone Annotation
    draw.rectangle([(30, 588), (380, 650)], fill=(15, 20, 30, 220), outline=(240, 100, 100, 220), width=1)
    draw.text((40, 594), "【前景走廊】y: 580-658 进出门道与动线", fill=(255, 140, 140), font=header_font)
    draw.text((40, 616), "• 饮水毛巾台 • 前台边缘 • 留出畅通无遮挡过道", fill=(235, 220, 220), font=body_font)
    draw.text((40, 632), "• 避免大型器械放置于此遮挡后方角色", fill=(200, 180, 180), font=small_font)

    # Box 4: Bottom HUD Collapse Info
    draw.rectangle([(380, 666), (900, 712)], fill=(15, 20, 30, 230), outline=(220, 170, 60, 200), width=1)
    draw.text((640, 682), "【常态收起底栏】50px 紧凑 Dock 释放 150px (21%) 纵向画面", fill=(255, 220, 150), font=header_font, anchor="mm")
    draw.text((640, 700), "完整对白卡仅在 [E交流/指导/日结] 时动态滑出，平常绝不遮挡下半场视线", fill=(220, 220, 220), font=small_font, anchor="mm")

    # Box 5: Unified Color Palette Legend (Right Side)
    px, py = 960, 56
    draw.rectangle([(px, py), (px + 290, py + 160)], fill=(15, 20, 30, 230), outline=(220, 170, 60, 220), width=1)
    draw.text((px + 14, py + 10), "色彩基准规范 (Unified Palette)", fill=(240, 190, 80), font=header_font)
    
    swatches = [
        ("程教练青绿外套 #2e7d6b", (46, 125, 107, 255)),
        ("室内松木地板 #4a3e2f", (74, 62, 47, 255)),
        ("重训橡胶地垫 #22262c", (34, 38, 44, 255)),
        ("室内暖灯主色 #ffdfa0", (255, 223, 160, 255)),
        ("窗外冷街景环境 #3a4e68", (58, 78, 104, 255)),
    ]
    for i, (name, col) in enumerate(swatches):
        sy = py + 38 + i * 23
        draw.rectangle([(px + 14, sy), (px + 32, sy + 15)], fill=col, outline=(200, 200, 200, 180), width=1)
        draw.text((px + 40, sy + 1), name, fill=(230, 230, 230), font=body_font)

    # Composite
    final_img = Image.alpha_composite(img, overlay)
    final_img.save(out_path)
    print(f"Generated {out_path} successfully!")

if __name__ == "__main__":
    main()
