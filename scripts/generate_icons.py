#!/usr/bin/env python3
"""Regenerates Resources/AppIcon.icns and the menu bar template PNGs from the
source marks in Resources/brand/. Run this after replacing either source logo.

    python3 scripts/generate_icons.py
    iconutil -c icns /tmp/minions-icon.iconset -o Resources/AppIcon.icns   (done automatically below)

Requires Pillow (`pip install pillow`) and macOS's `iconutil`.
"""
import subprocess
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
BRAND = ROOT / "Resources" / "brand"
COLOR_LOGO = BRAND / "logo-color.png"
MONO_LOGO = BRAND / "logo-mono.png"


def make_app_icon(iconset_dir: Path) -> None:
    """Composites the color mark onto a macOS-style rounded-square card."""
    logo = Image.open(COLOR_LOGO).convert("RGBA")
    logo = logo.crop(logo.getbbox())

    canvas_size = 1024
    card = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))
    radius = int(canvas_size * 0.224)  # approximates the macOS Big Sur+ squircle
    ImageDraw.Draw(card).rounded_rectangle(
        [0, 0, canvas_size - 1, canvas_size - 1], radius=radius, fill=(250, 246, 238, 255)
    )

    target_w = int(canvas_size * 0.64)  # HIG margin for a full-bleed card icon
    scale = target_w / logo.width
    target_h = int(logo.height * scale)
    logo_resized = logo.resize((target_w, target_h), Image.LANCZOS)
    x, y = (canvas_size - target_w) // 2, (canvas_size - target_h) // 2
    card.alpha_composite(logo_resized, (x, y))

    sizes = {16: "16x16", 32: "32x32", 64: "32x32@2x", 128: "128x128", 256: "256x256", 512: "512x512", 1024: "512x512@2x"}
    for s, name in sizes.items():
        card.resize((s, s), Image.LANCZOS).save(iconset_dir / f"icon_{name}.png")
    card.resize((256, 256), Image.LANCZOS).save(iconset_dir / "icon_128x128@2x.png")
    card.resize((512, 512), Image.LANCZOS).save(iconset_dir / "icon_256x256@2x.png")


def make_menu_bar_icon() -> None:
    """Exports the black mark at menu-bar scale as an AppKit template image
    (plain black-on-transparent), which macOS then tints automatically for
    light/dark menu bars and the selected state."""
    logo = Image.open(MONO_LOGO).convert("RGBA")
    logo = logo.crop(logo.getbbox())
    out_dir = ROOT / "Sources" / "MinionsApp" / "Resources"
    out_dir.mkdir(parents=True, exist_ok=True)
    for scale, suffix in [(1, ""), (2, "@2x"), (3, "@3x")]:
        h = 18 * scale
        w = int(logo.width * (h / logo.height))
        logo.resize((w, h), Image.LANCZOS).save(out_dir / f"MenuBarIcon{suffix}.png")


def main() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        iconset = Path(tmp) / "AppIcon.iconset"
        iconset.mkdir()
        make_app_icon(iconset)
        dest = ROOT / "Resources" / "AppIcon.icns"
        subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(dest)], check=True)
        print(f"wrote {dest}")
    make_menu_bar_icon()
    print(f"wrote {ROOT / 'Sources/MinionsApp/Resources'}/MenuBarIcon*.png")


if __name__ == "__main__":
    main()
