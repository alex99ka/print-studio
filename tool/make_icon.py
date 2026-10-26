"""Draws the app icon: an enclosed dual-nozzle printer (like Alex's X2D), palette A.

Writes assets/icon/icon.png (full square, for Windows/web/legacy Android),
assets/icon/foreground.png (transparent, inside the adaptive icon's 66% safe
circle) and assets/icon/logo.png (no background, for the app bar and portal).
Then: dart run flutter_launcher_icons
"""
from pathlib import Path

from PIL import Image, ImageDraw

GRAPHITE = (21, 23, 28)
BODY = (236, 238, 242)
BODY_EDGE = (160, 167, 179)
GLASS = (31, 35, 42)
BLUE = (47, 91, 234)
BLUE_LIGHT = (124, 155, 255)
GREEN = (4, 120, 87)
SPOOLS = [(47, 91, 234), (236, 238, 242), (4, 120, 87), (230, 160, 40)]

S = 4096  # drawn large, scaled down for smooth edges
OUT = Path(__file__).resolve().parent.parent / "assets" / "icon"


def printer(d: ImageDraw.ImageDraw, x0: float, y0: float, w: float) -> None:
    """The printer in a w-wide box at (x0, y0); it is about 1.05 w tall."""
    u = w / 100
    def r(a, b, c, e, **k):
        d.rounded_rectangle((x0 + a * u, y0 + b * u, x0 + c * u, y0 + e * u), **k)
    # filament box on top, four spools
    r(14, 0, 86, 16, radius=3 * u, fill=BODY, outline=BODY_EDGE, width=int(1.2 * u))
    for i, c in enumerate(SPOOLS):
        cx = 26 + i * 16
        d.ellipse((x0 + (cx - 5) * u, y0 + 3 * u, x0 + (cx + 5) * u, y0 + 13 * u), fill=c, outline=BODY_EDGE, width=int(0.8 * u))
    # body and the glass front
    r(0, 19, 100, 105, radius=7 * u, fill=BODY, outline=BODY_EDGE, width=int(1.2 * u))
    r(8, 27, 92, 90, radius=4 * u, fill=GLASS)
    # gantry and the dual-nozzle toolhead
    r(12, 36, 88, 40, radius=1.5 * u, fill=BODY_EDGE)
    r(36, 33, 64, 51, radius=3 * u, fill=BLUE)
    for nx in (43, 57):
        d.polygon([(x0 + (nx - 3.5) * u, y0 + 51 * u), (x0 + (nx + 3.5) * u, y0 + 51 * u), (x0 + nx * u, y0 + 57 * u)], fill=BLUE_LIGHT)
    # build plate with a print on it
    r(16, 80, 84, 84, radius=1.5 * u, fill=BODY_EDGE)
    r(42, 66, 58, 80, radius=2 * u, fill=GREEN)
    # foot strip under the door
    r(8, 94, 92, 99, radius=2 * u, fill=BODY_EDGE)


def render(bg: bool, scale: float) -> Image.Image:
    img = Image.new("RGBA", (S, S), GRAPHITE + (255,) if bg else (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    w = S * scale
    printer(d, (S - w) / 2, (S - w * 1.05) / 2, w)
    return img.resize((1024, 1024), Image.LANCZOS)


if __name__ == "__main__":
    OUT.mkdir(parents=True, exist_ok=True)
    render(True, 0.70).convert("RGB").save(OUT / "icon.png")
    render(False, 0.50).save(OUT / "foreground.png")  # about 0.5 x 0.53: inside the 66% circle
    render(False, 0.92).save(OUT / "logo.png")
    print("wrote", sorted(p.name for p in OUT.iterdir()))
