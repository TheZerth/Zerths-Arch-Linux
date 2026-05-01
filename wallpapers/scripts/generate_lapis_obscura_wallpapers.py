#!/usr/bin/env python3
"""Generate Lapis Obscura wallpapers.

Custom procedural wallpaper generator for the Zerth Arch / Hyprland setup.
It uses the Lapis Obscura guide: dark basalt, Gruvbox mineral accents,
restrained cyberpunk sorcery, sacred geometry, old-machine dithering, and
minimal TUI/terminal geometry.

Outputs exact desktop sizes used by the installer:
- 3440x1440 ultrawide
- 2560x1440 landscape
- 1440x2560 portrait
"""

from __future__ import annotations

import argparse
import math
import random
from pathlib import Path

try:
    from PIL import Image, ImageDraw, ImageFilter
except Exception as exc:  # pragma: no cover - runtime dependency check
    raise SystemExit(
        "This generator needs Pillow. Install python-pillow or use the "
        "pre-generated wallpapers committed in wallpapers/lapis-obscura/.\n"
        f"Import error: {exc}"
    )

PALETTE = {
    "void": (5, 4, 8),
    "basalt": (9, 8, 18),
    "slab": (23, 21, 34),
    "ash": (85, 81, 93),
    "moon": (200, 200, 208),
    "gold": (216, 166, 87),
    "amber": (250, 189, 47),
    "moss": (152, 151, 26),
    "spirit": (131, 165, 152),
    "cyan": (142, 192, 124),
    "violet": (143, 125, 255),
    "rust": (204, 36, 29),
    "rose": (211, 134, 155),
}

BAYER_8 = (
    (0, 48, 12, 60, 3, 51, 15, 63),
    (32, 16, 44, 28, 35, 19, 47, 31),
    (8, 56, 4, 52, 11, 59, 7, 55),
    (40, 24, 36, 20, 43, 27, 39, 23),
    (2, 50, 14, 62, 1, 49, 13, 61),
    (34, 18, 46, 30, 33, 17, 45, 29),
    (10, 58, 6, 54, 9, 57, 5, 53),
    (42, 26, 38, 22, 41, 25, 37, 21),
)

SIZES = {
    "ultrawide": (3440, 1440),
    "landscape": (2560, 1440),
    "portrait": (1440, 2560),
}

VARIANTS = ("terminal-temple", "wire-oracle", "moon-gate")


def mix(a: tuple[int, int, int], b: tuple[int, int, int], t: float) -> tuple[int, int, int]:
    t = max(0.0, min(1.0, t))
    return tuple(int(a[i] * (1 - t) + b[i] * t) for i in range(3))


def add(a: tuple[int, int, int], v: int) -> tuple[int, int, int]:
    return tuple(max(0, min(255, c + v)) for c in a)


def make_background(w: int, h: int, seed: int) -> Image.Image:
    rng = random.Random(seed)
    img = Image.new("RGB", (w, h), PALETTE["void"])
    px = img.load()
    cx, cy = w * 0.54, h * 0.46
    max_d = math.hypot(cx, cy)
    for y in range(h):
        by = y / max(1, h - 1)
        for x in range(w):
            bx = x / max(1, w - 1)
            d = math.hypot(x - cx, y - cy) / max_d
            glow = max(0.0, 1.0 - d * 1.65)
            band = 0.5 + 0.5 * math.sin((bx * 7.0 + by * 2.5) * math.tau)
            base = mix(PALETTE["void"], PALETTE["basalt"], 0.55 + 0.18 * by)
            base = mix(base, PALETTE["slab"], glow * 0.42)
            base = mix(base, PALETTE["violet"], glow * 0.035)
            base = mix(base, PALETTE["spirit"], band * glow * 0.025)
            threshold = BAYER_8[y & 7][x & 7]
            n = rng.randrange(7) - 3
            dither = -5 if threshold < 22 else (3 if threshold > 48 else 0)
            px[x, y] = add(base, n + dither)
    return img


def line(draw: ImageDraw.ImageDraw, xy, fill, width=1):
    draw.line(xy, fill=fill, width=width, joint="curve")


def rect(draw: ImageDraw.ImageDraw, box, outline, width=1, fill=None):
    draw.rectangle(box, outline=outline, width=width, fill=fill)


def circle(draw: ImageDraw.ImageDraw, cx, cy, r, outline, width=1, fill=None):
    draw.ellipse((cx - r, cy - r, cx + r, cy + r), outline=outline, width=width, fill=fill)


def triangle(draw: ImageDraw.ImageDraw, cx, cy, r, outline, width=1):
    pts = []
    for i in range(3):
        a = -math.pi / 2 + i * math.tau / 3
        pts.append((cx + math.cos(a) * r, cy + math.sin(a) * r))
    draw.line([*pts, pts[0]], fill=outline, width=width)


def hexagon(draw: ImageDraw.ImageDraw, cx, cy, r, outline, width=1):
    pts = []
    for i in range(6):
        a = math.pi / 6 + i * math.tau / 6
        pts.append((cx + math.cos(a) * r, cy + math.sin(a) * r))
    draw.line([*pts, pts[0]], fill=outline, width=width)


def draw_cable_field(draw: ImageDraw.ImageDraw, w: int, h: int, rng: random.Random, density: int):
    colors = [PALETTE["moss"], PALETTE["spirit"], PALETTE["gold"], PALETTE["violet"], PALETTE["ash"]]
    for _ in range(density):
        side = rng.choice(["top", "left", "right", "bottom"])
        if side == "top":
            x, y = rng.randrange(w), rng.randrange(-80, 80)
        elif side == "bottom":
            x, y = rng.randrange(w), h + rng.randrange(-80, 80)
        elif side == "left":
            x, y = rng.randrange(-80, 80), rng.randrange(h)
        else:
            x, y = w + rng.randrange(-80, 80), rng.randrange(h)
        pts = [(x, y)]
        steps = rng.randrange(4, 9)
        for _i in range(steps):
            x += rng.randrange(-w // 8, w // 8)
            y += rng.randrange(-h // 8, h // 8)
            x = max(-100, min(w + 100, x))
            y = max(-100, min(h + 100, y))
            pts.append((x, y))
        col = mix(rng.choice(colors), PALETTE["void"], rng.uniform(0.15, 0.55))
        line(draw, pts, col, rng.choice([1, 1, 1, 2]))
        for px, py in pts[1:-1:2]:
            if rng.random() < 0.55:
                circle(draw, px, py, rng.randrange(2, 6), mix(col, PALETTE["moon"], 0.15), 1)


def draw_terminal_slabs(draw: ImageDraw.ImageDraw, w: int, h: int, rng: random.Random, count: int):
    for _ in range(count):
        rw = rng.randrange(max(90, w // 22), max(120, w // 8))
        rh = rng.randrange(max(36, h // 28), max(64, h // 9))
        x = rng.randrange(-rw // 4, w - rw + rw // 4)
        y = rng.randrange(-rh // 4, h - rh + rh // 4)
        outline = mix(PALETTE["ash"], PALETTE["void"], rng.uniform(0.15, 0.55))
        fill = mix(PALETTE["basalt"], PALETTE["void"], rng.uniform(0.1, 0.55))
        rect(draw, (x, y, x + rw, y + rh), outline, 1, fill)
        # small terminal ticks
        for j in range(rng.randrange(2, 8)):
            yy = y + 8 + j * rng.randrange(5, 12)
            if yy >= y + rh - 6:
                break
            xx = x + 8
            ln = rng.randrange(15, max(16, rw - 16))
            line(draw, (xx, yy, xx + ln, yy), mix(outline, PALETTE["gold"], rng.uniform(0.0, 0.22)), 1)


def draw_sacred_geometry(draw: ImageDraw.ImageDraw, w: int, h: int, rng: random.Random, focus: tuple[int, int], scale: float):
    cx, cy = focus
    r = int(min(w, h) * scale)
    col = mix(PALETTE["gold"], PALETTE["void"], 0.22)
    ghost = mix(PALETTE["violet"], PALETTE["void"], 0.42)
    spirit = mix(PALETTE["spirit"], PALETTE["void"], 0.35)
    for k in range(5):
        circle(draw, cx, cy, int(r * (0.22 + k * 0.16)), mix(col, PALETTE["ash"], k / 7), 1)
    triangle(draw, cx, cy, int(r * 0.7), col, 2)
    hexagon(draw, cx, cy, int(r * 0.52), spirit, 1)
    line(draw, (cx - int(r * 0.95), cy, cx + int(r * 0.95), cy), ghost, 1)
    line(draw, (cx, cy - int(r * 0.95), cx, cy + int(r * 0.95)), ghost, 1)
    for a in [0, math.tau / 3, 2 * math.tau / 3, math.pi / 3, math.pi, 5 * math.pi / 3]:
        x = cx + math.cos(a) * r * 0.62
        y = cy + math.sin(a) * r * 0.62
        circle(draw, x, y, max(2, int(r * 0.018)), col, 1, mix(col, PALETTE["void"], 0.55))


def draw_halftone_moon(draw: ImageDraw.ImageDraw, w: int, h: int, rng: random.Random, cx: int, cy: int, r: int):
    for yy in range(cy - r, cy + r, 10):
        for xx in range(cx - r, cx + r, 10):
            d = math.hypot(xx - cx, yy - cy)
            if d < r:
                t = 1 - d / r
                dot = max(1, int(4 * t))
                color = mix(PALETTE["moon"], PALETTE["void"], 0.32 + 0.45 * (1 - t))
                circle(draw, xx, yy, dot, color, 1, color)
    circle(draw, cx, cy, r, mix(PALETTE["moon"], PALETTE["void"], 0.3), 1)
    circle(draw, cx + int(r * 0.22), cy - int(r * 0.02), int(r * 0.88), PALETTE["void"], 1)


def variant_terminal_temple(w: int, h: int, seed: int) -> Image.Image:
    rng = random.Random(seed)
    img = make_background(w, h, seed)
    draw = ImageDraw.Draw(img, "RGBA")
    draw_terminal_slabs(draw, w, h, rng, 74 if w > h else 58)
    draw_cable_field(draw, w, h, rng, 95 if w > h else 76)
    focus = (int(w * (0.62 if w > h else 0.52)), int(h * 0.48))
    draw_sacred_geometry(draw, w, h, rng, focus, 0.28 if w > h else 0.36)
    # basalt pillars / megaliths
    for i, x in enumerate([int(w * 0.09), int(w * 0.18), int(w * 0.84), int(w * 0.92)]):
        bw = int(w * rng.uniform(0.012, 0.026))
        rect(draw, (x - bw, int(h * 0.12), x + bw, int(h * 0.91)), mix(PALETTE["ash"], PALETTE["void"], 0.45), 1, (*mix(PALETTE["basalt"], PALETTE["void"], 0.2), 95))
        line(draw, (x, int(h * 0.14), x, int(h * 0.89)), mix(PALETTE["gold"], PALETTE["void"], 0.55), 1)
    return img.filter(ImageFilter.UnsharpMask(radius=1.0, percent=115, threshold=3))


def variant_wire_oracle(w: int, h: int, seed: int) -> Image.Image:
    rng = random.Random(seed)
    img = make_background(w, h, seed + 17)
    draw = ImageDraw.Draw(img, "RGBA")
    draw_cable_field(draw, w, h, rng, 180 if w > h else 135)
    draw_terminal_slabs(draw, w, h, rng, 44 if w > h else 36)
    # ghost portrait / oracle silhouette, abstract not character-specific
    cx, cy = int(w * (0.70 if w > h else 0.50)), int(h * (0.52 if w > h else 0.38))
    head_r = int(min(w, h) * 0.095)
    halo_r = int(head_r * 1.75)
    circle(draw, cx, cy, halo_r, mix(PALETTE["rose"], PALETTE["void"], 0.32), 2)
    circle(draw, cx, cy, head_r, mix(PALETTE["moon"], PALETTE["void"], 0.18), 1, (*mix(PALETTE["ash"], PALETTE["void"], 0.2), 150))
    for i in range(34):
        x = cx - head_r + i * head_r * 2 / 33
        line(draw, (x, cy - head_r * 1.2, x + rng.randrange(-12, 13), cy + head_r * 1.65), mix(PALETTE["moon"], PALETTE["void"], rng.uniform(0.1, 0.55)), 1)
    line(draw, (cx - head_r * 0.34, cy - head_r * 0.05, cx - head_r * 0.08, cy - head_r * 0.04), PALETTE["void"], 2)
    line(draw, (cx + head_r * 0.08, cy - head_r * 0.04, cx + head_r * 0.34, cy - head_r * 0.05), PALETTE["void"], 2)
    # red/rust cloak as low noisy mass
    for _ in range(180):
        x = cx + rng.randrange(-head_r * 3, head_r * 3)
        y = cy + rng.randrange(head_r, head_r * 5)
        r = rng.randrange(10, max(11, head_r // 2))
        color = mix(rng.choice([PALETTE["rust"], PALETTE["rose"], PALETTE["violet"]]), PALETTE["void"], rng.uniform(0.18, 0.62))
        triangle(draw, x, y, r, color, rng.choice([1, 1, 2]))
    draw_sacred_geometry(draw, w, h, rng, (int(w * 0.28), int(h * 0.56)), 0.22 if w > h else 0.28)
    return img.filter(ImageFilter.UnsharpMask(radius=0.8, percent=130, threshold=3))


def variant_moon_gate(w: int, h: int, seed: int) -> Image.Image:
    rng = random.Random(seed)
    img = make_background(w, h, seed + 31)
    draw = ImageDraw.Draw(img, "RGBA")
    # sparse white/black mythic negative-space figure, but mineralized dark
    cx, cy = int(w * 0.50), int(h * 0.50)
    gate_r = int(min(w, h) * (0.30 if w > h else 0.34))
    draw_halftone_moon(draw, w, h, rng, cx, cy, gate_r)
    # black central spirit/portal
    body_w, body_h = int(gate_r * 0.86), int(gate_r * 1.25)
    draw.ellipse((cx - body_w // 2, cy - body_h // 2, cx + body_w // 2, cy + body_h // 2), fill=(*PALETTE["void"], 222), outline=(*mix(PALETTE["ash"], PALETTE["void"], 0.18), 180), width=2)
    circle(draw, cx - body_w * 0.18, cy - body_h * 0.19, max(3, gate_r // 34), PALETTE["moon"], 1, PALETTE["moon"])
    circle(draw, cx + body_w * 0.18, cy - body_h * 0.19, max(3, gate_r // 34), PALETTE["moon"], 1, PALETTE["moon"])
    draw.ellipse((cx - body_w * 0.13, cy - body_h * 0.04, cx + body_w * 0.13, cy + body_h * 0.25), fill=(*mix(PALETTE["moon"], PALETTE["void"], 0.12), 210))
    for _ in range(170 if w > h else 130):
        x = rng.randrange(w)
        y = rng.randrange(h)
        if math.hypot(x - cx, y - cy) < gate_r * 0.72:
            continue
        if rng.random() < 0.55:
            line(draw, (x, y, x + rng.randrange(-60, 61), y + rng.randrange(-60, 61)), mix(PALETTE["ash"], PALETTE["void"], 0.15), 1)
        else:
            triangle(draw, x, y, rng.randrange(4, 16), mix(rng.choice([PALETTE["gold"], PALETTE["moss"], PALETTE["violet"]]), PALETTE["void"], 0.35), 1)
    draw_terminal_slabs(draw, w, h, rng, 22 if w > h else 18)
    return img.filter(ImageFilter.UnsharpMask(radius=1.2, percent=110, threshold=4))


def generate(out_dir: Path, variant: str, size_name: str, overwrite: bool = False) -> Path:
    w, h = SIZES[size_name]
    seed = abs(hash((variant, size_name, "lapis-obscura"))) & 0xFFFFFFFF
    if variant == "terminal-temple":
        img = variant_terminal_temple(w, h, seed)
    elif variant == "wire-oracle":
        img = variant_wire_oracle(w, h, seed)
    elif variant == "moon-gate":
        img = variant_moon_gate(w, h, seed)
    else:
        raise ValueError(variant)
    out_dir.mkdir(parents=True, exist_ok=True)
    path = out_dir / f"lapis-obscura-{variant}-{w}x{h}.png"
    if path.exists() and not overwrite:
        return path
    img.save(path, optimize=True, compress_level=9)
    return path


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, default=Path("wallpapers/lapis-obscura"))
    parser.add_argument("--variant", choices=[*VARIANTS, "all"], default="all")
    parser.add_argument("--size", choices=[*SIZES.keys(), "all"], default="all")
    parser.add_argument("--overwrite", action="store_true")
    args = parser.parse_args()

    variants = VARIANTS if args.variant == "all" else (args.variant,)
    sizes = tuple(SIZES) if args.size == "all" else (args.size,)
    for variant in variants:
        for size in sizes:
            path = generate(args.out, variant, size, args.overwrite)
            print(path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
