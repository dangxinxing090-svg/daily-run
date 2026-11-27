#!/usr/bin/env python3
"""从母版出全套 launcher 图标。

母版 tool/assets/runner-master.png 是唯一的图形来源（1024×1024 平涂），
App 内的按钮图标由 tool/make_mark.py 从同一张母版抽轮廓，
两边不会走样。

运行：cd app && python3 tool/make_icons.py
"""

import os
import sys

from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUILD = os.path.join(ROOT, "build", "icons")
MASTER = os.path.join(ROOT, "tool", "assets", "runner-master.png")

BG = (13, 116, 206)
# maskable 图标会被系统裁成圆形，图形要收进安全区
MASKABLE_INSET = 0.80


def load_master():
    img = Image.open(MASTER).convert("RGB")
    if img.size != (1024, 1024):
        img = img.resize((1024, 1024), Image.LANCZOS)
    return img


def maskable(master):
    """把图形缩进安全区，四周补底色。"""
    size = master.size[0]
    inner = int(size * MASKABLE_INSET)
    small = master.resize((inner, inner), Image.LANCZOS)
    canvas = Image.new("RGB", (size, size), BG)
    off = (size - inner) // 2
    canvas.paste(small, (off, off))
    return canvas


def resize(master, size, path):
    img = master.resize((size, size), Image.LANCZOS)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    img.save(path)
    print("  ", os.path.relpath(path, ROOT), size)


def main():
    os.makedirs(BUILD, exist_ok=True)
    master = load_master()
    master.save(os.path.join(BUILD, "icon-1024.png"))

    for bucket, size in {"mdpi": 48, "hdpi": 72, "xhdpi": 96,
                         "xxhdpi": 144, "xxxhdpi": 192}.items():
        resize(master, size, os.path.join(
            ROOT, "android", "app", "src", "main", "res",
            f"mipmap-{bucket}", "ic_launcher.png"))

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

    safe = maskable(master)
    for name, size, src in [
        ("Icon-192.png", 192, master),
        ("Icon-512.png", 512, master),
        ("Icon-maskable-192.png", 192, safe),
        ("Icon-maskable-512.png", 512, safe),
    ]:
        resize(src, size, os.path.join(ROOT, "web", "icons", name))

    print("master: tool/assets/runner-master.png")
    return 0


if __name__ == "__main__":
    sys.exit(main())
