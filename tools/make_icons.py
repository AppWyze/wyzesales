#!/usr/bin/env python3
"""Renders WyzeSales' "Signal Spark" brand mark (see
lib/shared/widgets/app_logo.dart's _SignalSparkPainter) as static PNGs for
the Flutter web scaffold's favicon + PWA manifest icons, since those are
plain image files Flutter's own CustomPainter-drawn in-app logo can't supply
directly.

Coordinates and colours are copied verbatim from _SignalSparkPainter's own
72x72 design grid and AppColors, so the browser-tab/PWA icon matches the
in-app logo exactly rather than being a fresh re-interpretation of it:
  - hex badge: filled navy (AppColors.lightText / navyDeep, #0A1620)
  - pulse line: brand gold (AppColors.teal, #FFB23E), stroke width 5.5 at
    the 72px design scale, round caps/joins

Regular icons (favicon, Icon-192/512) render on a transparent background,
matching how the in-app logo has no background of its own. Maskable icons
add a solid white background and shrink the mark so it sits safely inside
the ~80% "safe zone" every OS launcher icon mask respects, per the PWA
maskable-icon spec (Android/iOS can crop a maskable icon into a circle,
squircle, rounded square, etc. — anything outside the safe zone risks being
clipped).

Run with: python3 tools/make_icons.py <output_web_dir>
"""
import sys
from pathlib import Path
from PIL import Image, ImageDraw

NAVY = (10, 22, 32, 255)      # #0A1620 — AppColors.lightText / navyDeep
GOLD = (255, 178, 62, 255)    # #FFB23E — AppColors.teal
WHITE = (255, 255, 255, 255)

# Straight from _SignalSparkPainter's own 72x72 grid.
HEX_POINTS = [(36, 5), (64, 20), (64, 52), (36, 67), (8, 52), (8, 20)]
PULSE_POINTS = [(16, 42), (27, 42), (32, 30), (40, 48), (45, 38), (56, 38)]
PULSE_STROKE_AT_72 = 5.5

SUPERSAMPLE = 4  # render this many times larger, then downsample for AA


def draw_mark(canvas: Image.Image, origin: tuple[float, float], scale: float):
    """Draws the hex + pulse mark onto `canvas`, top-left of its 72x72
    design grid placed at `origin`, scaled by `scale`."""
    draw = ImageDraw.Draw(canvas)
    ox, oy = origin

    def pt(p):
        return (ox + p[0] * scale, oy + p[1] * scale)

    # Filled hex badge.
    draw.polygon([pt(p) for p in HEX_POINTS], fill=NAVY)

    # Pulse line: round caps/joins, approximated with a thick polyline plus
    # a circle at every vertex (including the two endpoints) so corners and
    # line ends come out rounded rather than mitered/flat like PIL's default.
    stroke_w = PULSE_STROKE_AT_72 * scale
    pulse = [pt(p) for p in PULSE_POINTS]
    draw.line(pulse, fill=GOLD, width=round(stroke_w), joint="curve")
    r = stroke_w / 2
    for x, y in pulse:
        draw.ellipse([x - r, y - r, x + r, y + r], fill=GOLD)


def render_icon(size: int, transparent: bool) -> Image.Image:
    """Regular (non-maskable) icon: the mark placed directly on a `size`x
    `size` canvas using the design grid's own built-in margin (the hex
    already spans x:8-64/y:5-67 of its own 0-72 grid, so ~10% padding on
    every side comes for free, no extra shrinking needed)."""
    big = size * SUPERSAMPLE
    bg = (0, 0, 0, 0) if transparent else WHITE
    canvas = Image.new("RGBA", (big, big), bg)
    draw_mark(canvas, origin=(0, 0), scale=big / 72)
    return canvas.resize((size, size), Image.LANCZOS)


def render_maskable(size: int) -> Image.Image:
    """Maskable icon: solid white background filling the entire canvas, the
    mark shrunk to ~62% and centered so it comfortably clears the ~80%
    safe-zone circle every OS mask respects, however the icon gets cropped."""
    big = size * SUPERSAMPLE
    canvas = Image.new("RGBA", (big, big), WHITE)
    mark_frac = 0.62
    mark_size = big * mark_frac
    origin = ((big - mark_size) / 2, (big - mark_size) / 2)
    draw_mark(canvas, origin=origin, scale=mark_size / 72)
    return canvas.resize((size, size), Image.LANCZOS)


def main():
    if len(sys.argv) != 2:
        print("usage: make_icons.py <path to web/ directory>", file=sys.stderr)
        sys.exit(1)
    web_dir = Path(sys.argv[1])
    icons_dir = web_dir / "icons"
    icons_dir.mkdir(parents=True, exist_ok=True)

    render_icon(64, transparent=True).save(web_dir / "favicon.png")
    render_icon(192, transparent=True).save(icons_dir / "Icon-192.png")
    render_icon(512, transparent=True).save(icons_dir / "Icon-512.png")
    render_maskable(192).save(icons_dir / "Icon-maskable-192.png")
    render_maskable(512).save(icons_dir / "Icon-maskable-512.png")
    print(f"Wrote favicon.png + 4 icons/ under {web_dir}")


if __name__ == "__main__":
    main()
