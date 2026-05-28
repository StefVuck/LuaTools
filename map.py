#!/usr/bin/env python3
"""
Convert a PNG map export into a Lua module for ComputerCraft.

Output format (map.lua):
    return {
        width = W, height = H,
        bbox = {minX=, minZ=, maxX=, maxZ=},
        dimension = "overworld" | "nether",
        palette = { [0]="#rrggbb", [1]=..., ... 16 entries },
        pixels = "hex string of length W*H",
    }

Usage:
    python map_convert.py input.png output.lua \
        --width 164 --height 81 \
        --bbox -2000 -2000 2000 2000 \
        --dimension overworld
"""

import argparse
from pathlib import Path
import numpy as np
from PIL import Image
from sklearn.cluster import KMeans


def quantise(img_array: np.ndarray, k: int = 16) -> tuple[np.ndarray, np.ndarray]:
    """k-means quantise an HxWx3 uint8 array to k colours.
    Returns (indices HxW uint8, palette kx3 uint8)."""
    h, w, _ = img_array.shape
    pixels = img_array.reshape(-1, 3).astype(np.float32)

    # Subsample for speed if image is large
    if len(pixels) > 50_000:
        sample = pixels[np.random.choice(len(pixels), 50_000, replace=False)]
    else:
        sample = pixels

    km = KMeans(n_clusters=k, n_init=4, random_state=0).fit(sample)
    palette = km.cluster_centers_.astype(np.uint8)

    # Assign every pixel to nearest centroid (full image, not sample)
    # Use chunked distance computation to avoid OOM on big images
    indices = np.empty(len(pixels), dtype=np.uint8)
    chunk = 100_000
    for i in range(0, len(pixels), chunk):
        block = pixels[i:i + chunk]
        d = np.linalg.norm(block[:, None, :] - palette[None, :, :].astype(np.float32), axis=2)
        indices[i:i + chunk] = np.argmin(d, axis=1).astype(np.uint8)

    return indices.reshape(h, w), palette


def emit_lua(indices: np.ndarray, palette: np.ndarray, bbox: tuple,
             dimension: str, out_path: Path) -> None:
    h, w = indices.shape

    # Indices 0-15 -> single hex char each
    hex_chars = "0123456789abcdef"
    flat = indices.flatten()
    pixel_str = "".join(hex_chars[i] for i in flat)

    pal_lines = []
    for i, (r, g, b) in enumerate(palette):
        pal_lines.append(f'  [{i}] = 0x{r:02x}{g:02x}{b:02x},')
    pal_block = "\n".join(pal_lines)

    minX, minZ, maxX, maxZ = bbox
    lua = f"""-- Auto-generated map data. Do not edit by hand.
return {{
  width = {w},
  height = {h},
  dimension = "{dimension}",
  bbox = {{ minX = {minX}, minZ = {minZ}, maxX = {maxX}, maxZ = {maxZ} }},
  palette = {{
{pal_block}
  }},
  pixels = "{pixel_str}",
}}
"""
    out_path.write_text(lua)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("input", type=Path)
    p.add_argument("output", type=Path)
    p.add_argument("--width", type=int, required=True)
    p.add_argument("--height", type=int, required=True)
    p.add_argument("--bbox", type=int, nargs=4, required=True,
                   metavar=("MINX", "MINZ", "MAXX", "MAXZ"))
    p.add_argument("--dimension", choices=["overworld", "nether"], required=True)
    p.add_argument("--colours", type=int, default=14)
    args = p.parse_args()

    img = Image.open(args.input).convert("RGB")

    # Crop to bbox-matching aspect if the source image doesn't already match.
    # We assume the source PNG already covers exactly the bbox region; user is
    # responsible for that. We just resize to target pixel dimensions.
    img = img.resize((args.width, args.height), Image.LANCZOS)
    arr = np.array(img)

    indices, palette = quantise(arr, k=args.colours)
    emit_lua(indices, palette, tuple(args.bbox), args.dimension, args.output)

    print(f"Wrote {args.output} ({args.width}x{args.height}, {args.colours} colours)")


if __name__ == "__main__":
    main()
