#!/usr/bin/env python3
"""Draws the app icon and writes Resources/AppIcon.icns (plus a 1024px PNG preview).

Requires Pillow and numpy:  python3 -m pip install pillow numpy
Usage: python3 scripts/make-icon.py
"""
import io
import struct
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
OUT_DIR = ROOT / "Resources"
SCALE = 4                      # draw at 4x and downsample for smooth edges
SIZE = 1024 * SCALE


def s(value):
    return int(value * SCALE)


def gradient(width, height, top_left, bottom_right):
    """Diagonal linear gradient as an RGBA image."""
    y, x = np.mgrid[0:height, 0:width].astype(np.float32)
    t = ((x / width) + (y / height)) / 2
    a = np.array(top_left, dtype=np.float32)
    b = np.array(bottom_right, dtype=np.float32)
    rgb = a + (b - a) * t[..., None]
    alpha = np.full((height, width, 1), 255, dtype=np.float32)
    return Image.fromarray(np.concatenate([rgb, alpha], axis=2).astype(np.uint8), "RGBA")


def vertical_gradient(width, height, top, bottom):
    t = np.linspace(0, 1, height, dtype=np.float32)[:, None, None]
    a = np.array(top, dtype=np.float32)
    b = np.array(bottom, dtype=np.float32)
    rgba = np.broadcast_to(a + (b - a) * t, (height, width, 4))
    return Image.fromarray(rgba.astype(np.uint8), "RGBA")


def rounded_mask(size, box, radius):
    mask = Image.new("L", size, 0)
    ImageDraw.Draw(mask).rounded_rectangle(box, radius=radius, fill=255)
    return mask


def paste_with_mask(canvas, layer, mask):
    """Composites `layer` through `mask` (multiplying alpha, so edges don't darken)."""
    layer = layer.copy()
    alpha = np.asarray(layer.getchannel("A"), dtype=np.float32) * (np.asarray(mask, dtype=np.float32) / 255)
    layer.putalpha(Image.fromarray(alpha.astype(np.uint8), "L"))
    canvas.alpha_composite(layer)


def draw_icon():
    canvas = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))

    # Body: macOS icon grid — 824 x 824 rounded square centered on a 1024 canvas.
    body = (s(100), s(100), s(924), s(924))
    radius = s(185)

    # Soft drop shadow under the body.
    shadow = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(
        (body[0], body[1] + s(14), body[2], body[3] + s(14)), radius=radius, fill=(20, 10, 60, 110)
    )
    canvas.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(s(18))))

    background = gradient(SIZE, SIZE, (72, 118, 255), (138, 63, 252))
    paste_with_mask(canvas, background, rounded_mask(canvas.size, body, radius))

    # Subtle top highlight on the body, fading out smoothly.
    highlight = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    fade = vertical_gradient(SIZE, s(560), (255, 255, 255, 56), (255, 255, 255, 0))
    highlight.paste(fade, (0, body[1]))
    paste_with_mask(canvas, highlight, rounded_mask(canvas.size, body, radius))

    # Folder: back panel with tab, then front panel.
    back = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    draw = ImageDraw.Draw(back)
    draw.rounded_rectangle((s(232), s(300), s(470), s(470)), radius=s(36), fill=(214, 226, 255, 255))   # tab (bottom hidden behind the front)
    draw.rounded_rectangle((s(232), s(345), s(792), s(700)), radius=s(48), fill=(214, 226, 255, 255))   # back
    canvas.alpha_composite(back)

    front_shadow = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    ImageDraw.Draw(front_shadow).rounded_rectangle(
        (s(222), s(420), s(802), s(742)), radius=s(48), fill=(40, 20, 120, 90)
    )
    canvas.alpha_composite(front_shadow.filter(ImageFilter.GaussianBlur(s(12))))

    front = vertical_gradient(SIZE, SIZE, (255, 255, 255, 255), (236, 241, 255, 255))
    front_box = (s(212), s(405), s(812), s(732))
    paste_with_mask(canvas, front, rounded_mask(canvas.size, front_box, s(48)))

    # Arrow on the folder front: the "move it here" gesture this app is about.
    arrow_layer = gradient(SIZE, SIZE, (72, 118, 255), (138, 63, 252))
    arrow_mask = Image.new("L", (SIZE, SIZE), 0)
    adraw = ImageDraw.Draw(arrow_mask)
    cy = s(568)
    adraw.rounded_rectangle((s(340), cy - s(34), s(600), cy + s(34)), radius=s(34), fill=255)   # shaft
    adraw.polygon([(s(552), cy - s(112)), (s(692), cy), (s(552), cy + s(112))], fill=255)       # head
    paste_with_mask(canvas, arrow_layer, arrow_mask)

    return canvas.resize((1024, 1024), Image.LANCZOS)


def png_bytes(image, size):
    buffer = io.BytesIO()
    image.resize((size, size), Image.LANCZOS).save(buffer, format="PNG")
    return buffer.getvalue()


def write_icns(image, path):
    # PNG-backed icon types understood by macOS 10.7+.
    types = [
        (b"icp4", 16), (b"icp5", 32), (b"icp6", 64), (b"ic07", 128), (b"ic08", 256),
        (b"ic09", 512), (b"ic10", 1024), (b"ic11", 32), (b"ic12", 64), (b"ic13", 256), (b"ic14", 512),
    ]
    chunks = b""
    for code, size in types:
        data = png_bytes(image, size)
        chunks += code + struct.pack(">I", len(data) + 8) + data
    path.write_bytes(b"icns" + struct.pack(">I", len(chunks) + 8) + chunks)


if __name__ == "__main__":
    OUT_DIR.mkdir(exist_ok=True)
    icon = draw_icon()
    icon.save(OUT_DIR / "AppIcon.png")
    write_icns(icon, OUT_DIR / "AppIcon.icns")
    print(f"Wrote {OUT_DIR / 'AppIcon.icns'} and {OUT_DIR / 'AppIcon.png'}")
