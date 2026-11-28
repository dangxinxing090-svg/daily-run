#!/usr/bin/env python3
"""把 App 内的跑者轮廓输出为湖蓝留白桌面图标。

make_mark.py 从跑者母版提取闭合轮廓。桌面图标共用 App 内的轮廓数据，
用湖蓝面和等白的跑者，比例与设计稿品牌图标一致。

运行：cd app && python3 tool/make_icons.py
"""

import os
import re
import sys
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUILD = os.path.join(ROOT, "build", "icons")
CONTOURS = Path(ROOT) / "lib" / "widgets" / "runner_mark.dart"

BG = (13, 116, 206)
INK = (255, 255, 255)
SIZE = 1024


def runner_layer(ratio):
    # 高分辨率填充后再缩放，可以保持 48 网格轮廓在小图标中的圆边。
    render_size = SIZE * 3
    mask = Image.new("L", (render_size, render_size))
    draw = ImageDraw.Draw(mask)
    scale = render_size * ratio / 48
    inset = render_size * (1 - ratio) / 2
    for contour in re.findall(r"<double>\[([^\]]+)\]", CONTOURS.read_text()):
        values = [float(value) * scale + inset for value in contour.split(",")
                  if value.strip()]
        draw.polygon(list(zip(values[::2], values[1::2])), fill=255)
    mark = Image.new("RGBA", (SIZE, SIZE), (*INK, 0))
    mark.putalpha(mask.resize((SIZE, SIZE), Image.Resampling.LANCZOS))
    return mark


def badge(ratio):
    canvas = Image.new("RGBA", (SIZE, SIZE), (*BG, 255))
    canvas.alpha_composite(runner_layer(ratio))
    return canvas.convert("RGB")


def resize(master, size, path):
    img = master.resize((size, size), Image.LANCZOS)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    img.save(path)
    print("  ", os.path.relpath(path, ROOT), size)


def main():
    os.makedirs(BUILD, exist_ok=True)
    master = badge(20 / 28)
    foreground = runner_layer(0.50)
    master.save(os.path.join(BUILD, "icon-1024.png"))

    for bucket, scale in {"mdpi": 1, "hdpi": 1.5, "xhdpi": 2,
                          "xxhdpi": 3, "xxxhdpi": 4}.items():
        folder = os.path.join(ROOT, "android", "app", "src", "main", "res",
                              f"mipmap-{bucket}")
        resize(master, int(48 * scale), os.path.join(folder, "ic_launcher.png"))
        resize(foreground, int(108 * scale),
               os.path.join(folder, "ic_launcher_foreground.png"))

    ios = {
        "Icon-App-20x20@1x.png": 20,
        "Icon-App-20x20@2x.png": 40,
        "Icon-App-20x20@3x.png": 60,
        "Icon-App-29x29@1x.png": 29,
        "Icon-App-29x29@2x.png": 58,
        "Icon-App-29x29@3x.png": 87,
        "Icon-App-40x40@1x.png": 40,
        "Icon-App-40x40@2x.png": 80,
        "Icon-App-40x40@3x.png": 120,
        "Icon-App-60x60@2x.png": 120,
        "Icon-App-60x60@3x.png": 180,
        "Icon-App-76x76@1x.png": 76,
        "Icon-App-76x76@2x.png": 152,
        "Icon-App-83.5x83.5@2x.png": 167,
        "Icon-App-1024x1024@1x.png": 1024,
    }
    ios_dir = os.path.join(ROOT, "ios", "Runner", "Assets.xcassets",
                           "AppIcon.appiconset")
    for name, size in ios.items():
        resize(master, size, os.path.join(ios_dir, name))

    safe = badge(0.55)
    for name, size, src in [
        ("Icon-192.png", 192, master),
        ("Icon-512.png", 512, master),
        ("Icon-maskable-192.png", 192, safe),
        ("Icon-maskable-512.png", 512, safe),
    ]:
        resize(src, size, os.path.join(ROOT, "web", "icons", name))
    resize(master, 48, os.path.join(ROOT, "web", "favicon.png"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
