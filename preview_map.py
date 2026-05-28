#!/usr/bin/env python3
"""
Preview a generated map_*.lua file as a scaled PNG.
Usage: python preview_map.py map_overworld.lua [--scale 4]
"""

import argparse
import re
import subprocess
import sys
from pathlib import Path
from PIL import Image


def parse_lua_map(path: Path) -> dict:
    text = path.read_text()

    width  = int(re.search(r'width\s*=\s*(\d+)', text).group(1))
    height = int(re.search(r'height\s*=\s*(\d+)', text).group(1))

    palette = {}
    for m in re.finditer(r'\[(\d+)\]\s*=\s*0x([0-9a-fA-F]+)', text):
        idx = int(m.group(1))
        v   = int(m.group(2), 16)
        palette[idx] = ((v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF)

    m = re.search(r'pixels\s*=\s*"([0-9a-f]+)"', text)
    if not m:
        sys.exit("ERROR: could not find pixels string in the Lua file")
    pixels = m.group(1)

    expected = width * height
    if len(pixels) != expected:
        print(f"WARNING: pixel string length {len(pixels)} != {width}*{height}={expected}")

    return {"width": width, "height": height, "palette": palette, "pixels": pixels}


def render(data: dict, scale: int) -> Image.Image:
    w, h   = data["width"], data["height"]
    pal    = data["palette"]
    pixels = data["pixels"]

    img = Image.new("RGB", (w * scale, h * scale))
    px  = img.load()

    for y in range(h):
        for x in range(w):
            char      = pixels[y * w + x]
            color_idx = int(char, 16)
            rgb       = pal.get(color_idx, (255, 0, 255))  # magenta = missing palette entry
            for dy in range(scale):
                for dx in range(scale):
                    px[x * scale + dx, y * scale + dy] = rgb

    return img


def main():
    p = argparse.ArgumentParser(description="Preview a CC map_*.lua file")
    p.add_argument("input", type=Path, help="Path to map_*.lua")
    p.add_argument("--scale", type=int, default=4, help="Pixel scale factor (default 4)")
    p.add_argument("--out",   type=Path, default=None, help="Output PNG (default: <input>.preview.png)")
    args = p.parse_args()

    data = parse_lua_map(args.input)
    print(f"Parsed: {data['width']}x{data['height']}, {len(data['palette'])} palette entries")

    img = render(data, args.scale)

    out = args.out or args.input.with_suffix("").with_suffix(".preview.png")
    img.save(out)
    print(f"Saved: {out}  ({img.width}x{img.height} px)")

    # Open in default viewer
    try:
        if sys.platform == "win32":
            subprocess.Popen(["start", str(out)], shell=True)
        elif sys.platform == "darwin":
            subprocess.Popen(["open", str(out)])
        else:
            subprocess.Popen(["xdg-open", str(out)])
    except Exception:
        pass  # viewer launch is best-effort


if __name__ == "__main__":
    main()
