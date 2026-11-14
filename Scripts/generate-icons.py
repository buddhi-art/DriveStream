#!/usr/bin/env python3
"""Generate DriveStream's macOS app icon and Finder volume icon.

Requires Pillow. Run from the repository root:

    python3 Scripts/generate-icons.py

The output is:
  Resources/DriveStream.icns
  Resources/VolumeIcon.icns
  docs/icon.png
"""

from __future__ import annotations

import math
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
RESOURCES = ROOT / "Resources"
DOCS = ROOT / "docs"
SIZE = 1024


def vertical_gradient(size: tuple[int, int], top: tuple[int, int, int], bottom: tuple[int, int, int]) -> Image.Image:
    width, height = size
    image = Image.new("RGBA", size)
    pixels = image.load()
    for y in range(height):
        t = y / max(height - 1, 1)
        # Ease the gradient slightly so the top stays deep and the bottom glows.
        t = t * t * (3 - 2 * t)
        color = tuple(round(top[i] + (bottom[i] - top[i]) * t) for i in range(3)) + (255,)
        for x in range(width):
            pixels[x, y] = color
    return image


def rounded_mask(size: int, inset: int, radius: int) -> Image.Image:
    mask = Image.new("L", (size, size), 0)
    draw = ImageDraw.Draw(mask)
    draw.rounded_rectangle(
        (inset, inset, size - inset, size - inset),
        radius=radius,
        fill=255,
    )
    return mask


def make_icon() -> Image.Image:
    canvas = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))

    # Soft drop shadow under the squircle.
    shadow = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    shadow_draw = ImageDraw.Draw(shadow)
    shadow_draw.rounded_rectangle((88, 104, 936, 960), radius=224, fill=(2, 8, 22, 150))
    shadow = shadow.filter(ImageFilter.GaussianBlur(26))
    canvas.alpha_composite(shadow)

    # Main squircle.
    mask = rounded_mask(SIZE, 64, 224)
    background = vertical_gradient((SIZE, SIZE), (6, 20, 43), (11, 69, 168))
    canvas.paste(background, (0, 0), mask)

    # Diagonal light sweep.
    sweep = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    sweep_draw = ImageDraw.Draw(sweep)
    sweep_draw.polygon(
        [(64, 430), (960, 40), (960, 220), (64, 660)],
        fill=(78, 164, 255, 34),
    )
    sweep = sweep.filter(ImageFilter.GaussianBlur(16))
    canvas.alpha_composite(Image.composite(sweep, Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0)), mask))

    # Inner top highlight.
    highlight = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    highlight_draw = ImageDraw.Draw(highlight)
    highlight_draw.rounded_rectangle((80, 80, 944, 944), radius=208, outline=(255, 255, 255, 54), width=3)
    canvas.alpha_composite(Image.composite(highlight, Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0)), mask))

    # Motion streaks behind the drive.
    streaks = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    streak_draw = ImageDraw.Draw(streaks)
    for index, (x, y, w, alpha) in enumerate(
        [(118, 420, 128, 80), (96, 492, 168, 46), (118, 566, 112, 28)]
    ):
        streak_draw.rounded_rectangle(
            (x, y, x + w, y + 16),
            radius=8,
            fill=(83, 225, 255, alpha),
        )
    streaks = streaks.filter(ImageFilter.GaussianBlur(1.2))
    canvas.alpha_composite(streaks)

    # Drive body shadow.
    drive_shadow = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    drive_shadow_draw = ImageDraw.Draw(drive_shadow)
    drive_shadow_draw.rounded_rectangle((222, 330, 806, 680), radius=82, fill=(1, 7, 20, 135))
    drive_shadow = drive_shadow.filter(ImageFilter.GaussianBlur(22))
    canvas.alpha_composite(drive_shadow)

    # Drive body with a cool white gradient.
    drive_mask = Image.new("L", (SIZE, SIZE), 0)
    drive_mask_draw = ImageDraw.Draw(drive_mask)
    drive_mask_draw.rounded_rectangle((210, 300, 790, 650), radius=76, fill=255)
    drive_gradient = vertical_gradient((SIZE, SIZE), (255, 255, 255), (196, 224, 255))
    canvas.paste(drive_gradient, (0, 0), drive_mask)

    drive_layer = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    drive_draw = ImageDraw.Draw(drive_layer)
    drive_draw.rounded_rectangle((210, 300, 790, 650), radius=76, outline=(255, 255, 255, 210), width=4)

    # Vent / connector line.
    drive_draw.rounded_rectangle((430, 566, 594, 590), radius=12, fill=(134, 178, 235, 150))
    drive_draw.rounded_rectangle((430, 566, 560, 590), radius=12, fill=(92, 150, 223, 180))

    # Status LED.
    drive_draw.ellipse((700, 336, 744, 380), fill=(63, 235, 168, 255))
    drive_draw.ellipse((708, 344, 736, 372), fill=(190, 255, 231, 210))

    # Engraved top seam.
    drive_draw.arc((278, 344, 722, 456), start=200, end=340, fill=(150, 190, 242, 130), width=3)
    canvas.alpha_composite(drive_layer)

    # Streaming badge.
    badge_shadow = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    badge_shadow_draw = ImageDraw.Draw(badge_shadow)
    badge_shadow_draw.ellipse((608, 548, 920, 860), fill=(0, 6, 18, 125))
    badge_shadow = badge_shadow.filter(ImageFilter.GaussianBlur(18))
    canvas.alpha_composite(badge_shadow)

    badge = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    badge_draw = ImageDraw.Draw(badge)
    badge_draw.ellipse((592, 528, 924, 860), fill=(248, 252, 255, 255))
    badge_draw.ellipse((610, 546, 906, 842), fill=(5, 31, 65, 255))

    # Badge gradient clipped to circle.
    badge_mask = Image.new("L", (SIZE, SIZE), 0)
    ImageDraw.Draw(badge_mask).ellipse((618, 554, 898, 834), fill=255)
    badge_gradient = vertical_gradient((SIZE, SIZE), (69, 234, 213), (26, 108, 255))
    badge.paste(badge_gradient, (0, 0), badge_mask)
    badge_draw = ImageDraw.Draw(badge)
    badge_draw.ellipse((620, 556, 896, 832), outline=(255, 255, 255, 68), width=4)

    # White lightning bolt.
    bolt = [
        (760, 574),
        (655, 724),
        (726, 724),
        (690, 816),
        (806, 658),
        (734, 658),
    ]
    badge_draw.polygon(bolt, fill=(255, 255, 255, 250))
    canvas.alpha_composite(badge)

    # Tiny corner highlight.
    glint = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    glint_draw = ImageDraw.Draw(glint)
    glint_draw.ellipse((110, 96, 310, 224), fill=(255, 255, 255, 26))
    glint = glint.filter(ImageFilter.GaussianBlur(28))
    canvas.alpha_composite(Image.composite(glint, Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0)), mask))

    return canvas


def write_icns(image: Image.Image, destination: Path) -> None:
    with tempfile.TemporaryDirectory() as temporary:
        iconset = Path(temporary) / "DriveStream.iconset"
        iconset.mkdir()
        mappings = [
            (16, "icon_16x16.png"),
            (32, "icon_16x16@2x.png"),
            (32, "icon_32x32.png"),
            (64, "icon_32x32@2x.png"),
            (128, "icon_128x128.png"),
            (256, "icon_128x128@2x.png"),
            (256, "icon_256x256.png"),
            (512, "icon_256x256@2x.png"),
            (512, "icon_512x512.png"),
            (1024, "icon_512x512@2x.png"),
        ]
        for size, filename in mappings:
            resized = image.resize((size, size), Image.Resampling.LANCZOS)
            resized.save(iconset / filename, format="PNG")
        subprocess.run(["/usr/bin/iconutil", "-c", "icns", str(iconset), "-o", str(destination)], check=True)


def main() -> int:
    RESOURCES.mkdir(exist_ok=True)
    DOCS.mkdir(exist_ok=True)
    icon = make_icon()
    write_icns(icon, RESOURCES / "DriveStream.icns")
    shutil.copyfile(RESOURCES / "DriveStream.icns", RESOURCES / "VolumeIcon.icns")
    icon.resize((512, 512), Image.Resampling.LANCZOS).save(DOCS / "icon.png", format="PNG")
    print(f"Wrote {RESOURCES / 'DriveStream.icns'}")
    print(f"Wrote {RESOURCES / 'VolumeIcon.icns'}")
    print(f"Wrote {DOCS / 'icon.png'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
