"""The app icon from Alex's printer picture (assets/icon/source.png, white background).

Cuts the white background out (only white connected to the edges, so the light
parts inside the printer stay), turning the anti-aliased edge and the floor
shadow into soft transparency. Writes:
  icon.png        transparent square: Windows, web, legacy Android
  foreground.png  smaller, inside the Android adaptive icon's 66% safe circle
  logo.png        the app bar and the client's page
Then: dart run flutter_launcher_icons
"""
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

ICON = Path(__file__).resolve().parent.parent / "assets" / "icon"
LIGHT = 150  # brighter than this (every channel) can be background; the dark outline stops the fill


def cut_out(src: Image.Image) -> Image.Image:
    rgb = np.asarray(src.convert("RGB")).astype(float)
    # .copy(): an image made straight from an array is read-only and floodfill would silently do nothing.
    light = Image.fromarray(((rgb.min(2) > LIGHT) * 255).astype(np.uint8)).copy()
    for seed in ((0, 0), (light.width - 1, 0), (0, light.height - 1), (light.width - 1, light.height - 1)):
        ImageDraw.floodfill(light, seed, 128)
    bg = np.asarray(light) == 128
    # Colour to alpha against white: a pixel w% white becomes (1 - w) opaque, with its colour un-mixed.
    alpha = np.where(bg, (255 - rgb.min(2)) / 255, 1.0)
    keep = alpha > 0.02
    colour = np.where(keep[..., None], (rgb - 255 * (1 - alpha[..., None])) / np.maximum(alpha, 0.02)[..., None], 0)
    out = np.dstack([np.clip(colour, 0, 255), np.where(keep, alpha * 255, 0)]).astype(np.uint8)
    img = Image.fromarray(out, "RGBA")
    return img.crop(img.getchannel("A").point(lambda a: 255 if a > 40 else 0).getbbox())


def square(img: Image.Image, size: int, fill: float) -> Image.Image:
    """img centred on a transparent size x size square, its longer side = fill x size."""
    s = fill * size / max(img.size)
    art = img.resize((round(img.width * s), round(img.height * s)), Image.LANCZOS)
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    out.paste(art, ((size - art.width) // 2, (size - art.height) // 2), art)
    return out


if __name__ == "__main__":
    art = cut_out(Image.open(ICON / "source.png"))
    square(art, 1024, 0.96).save(ICON / "icon.png")
    square(art, 1024, 0.62).save(ICON / "foreground.png")  # a 0.62 box fits inside the 66% circle
    square(art, 512, 1.0).save(ICON / "logo.png")
    print("wrote", sorted(p.name for p in ICON.iterdir()))
