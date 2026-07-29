"""Tint the neutral background of an app icon while preserving glyph and bevel pixels.

Usage: python tint_icon.py SOURCE.png OUTPUT.png RRGGBB
"""

import argparse
from pathlib import Path

from PIL import Image

parser = argparse.ArgumentParser()
parser.add_argument("source", type=Path)
parser.add_argument("output", type=Path)
parser.add_argument("color", help="hex tint color, e.g. F28C28")
args = parser.parse_args()

tint = tuple(int(args.color.lstrip("#")[i : i + 2], 16) for i in (0, 2, 4))

image = Image.open(args.source).convert("RGBA")
pixels = []

for red, green, blue, alpha in image.getdata():
    maximum = max(red, green, blue)
    minimum = min(red, green, blue)
    luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue

    # Select the neutral, light background and its shadows. Dark glyph pixels,
    # colored bevels, and transparent exterior pixels remain byte-identical.
    neutrality = 1.0 - ((maximum - minimum) / max(maximum, 1))
    light_weight = max(0.0, min(1.0, (luminance - 118.0) / 82.0))
    neutral_weight = max(0.0, min(1.0, (neutrality - 0.72) / 0.24))
    weight = light_weight * neutral_weight

    if alpha and weight:
        shade = luminance / 255.0
        filtered = tuple(round(channel * shade) for channel in tint)
        red = round(red * (1.0 - weight) + filtered[0] * weight)
        green = round(green * (1.0 - weight) + filtered[1] * weight)
        blue = round(blue * (1.0 - weight) + filtered[2] * weight)

    pixels.append((red, green, blue, alpha))

image.putdata(pixels)
image.save(args.output, optimize=True)
