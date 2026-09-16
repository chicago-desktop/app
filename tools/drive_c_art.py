#!/usr/bin/env python3
"""Draw the two pictures that live on C: — a tiling pattern and a splash.

The pictures on the nostalgia drive are the shell's own pixel art, not
anyone's artwork: a rivet tile in the sixteen-colour palette, and a splash
with the word CHICAGO drawn from a hand-written 5x7 bitmap. Both are opened
by the picture viewer on the desktop, which is the point of putting them
there — a folder of text files is a folder; a folder with a picture in it is
a drive somebody lived on.

    python3 tools/drive_c_art.py

Writes drive_c/windows/RIVETS.PNG and drive_c/windows/CHICAGO.PNG.
"""

import os

from PIL import Image

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(HERE, "drive_c", "windows")

# The palette of the era: the eight dark tones and their bright halves. Only
# a few are used, but naming them all is how the file stays readable.
TEAL = (0, 128, 128)
DARK_TEAL = (0, 96, 96)
NAVY = (0, 0, 128)
BLUE = (0, 0, 168)
GREY = (192, 192, 192)
DARK_GREY = (128, 128, 128)
WHITE = (255, 255, 255)
BLACK = (0, 0, 0)

# A 5x7 bitmap, one string per row, for the seven letters the splash needs.
# Written by hand: a font file for seven letters would be a dependency, and
# the letters are the picture, not text that happens to be in it.
GLYPHS = {
    "C": ["01110", "10001", "10000", "10000", "10000", "10001", "01110"],
    "H": ["10001", "10001", "10001", "11111", "10001", "10001", "10001"],
    "I": ["01110", "00100", "00100", "00100", "00100", "00100", "01110"],
    "A": ["01110", "10001", "10001", "11111", "10001", "10001", "10001"],
    "G": ["01110", "10001", "10000", "10111", "10001", "10001", "01111"],
    "O": ["01110", "10001", "10001", "10001", "10001", "10001", "01110"],
}


def rivets(path, size=64):
    """A tile: a dark ground, a lighter grid, a rivet at every crossing."""
    image = Image.new("RGB", (size, size), NAVY)
    pixels = image.load()

    step = size // 4
    for x in range(size):
        for y in range(size):
            if x % step == 0 or y % step == 0:
                pixels[x, y] = BLUE

    # The rivet: three rows of three, lit from the top left as everything
    # on this desktop is lit.
    for cx in range(0, size, step):
        for cy in range(0, size, step):
            for dx, dy, colour in (
                (-1, -1, WHITE), (0, -1, WHITE), (1, -1, BLUE),
                (-1, 0, WHITE), (0, 0, GREY), (1, 0, DARK_GREY),
                (-1, 1, BLUE), (0, 1, DARK_GREY), (1, 1, DARK_GREY),
            ):
                pixels[(cx + dx) % size, (cy + dy) % size] = colour

    image.save(path)
    return image.size


def text_block(draw_pixel, word, left, top, scale, colour):
    """Draw `word` from the 5x7 bitmaps, each pixel a `scale` square."""
    x = left
    for letter in word:
        rows = GLYPHS[letter]
        for row_index, row in enumerate(rows):
            for column_index, bit in enumerate(row):
                if bit != "1":
                    continue
                for dx in range(scale):
                    for dy in range(scale):
                        draw_pixel(
                            x + column_index * scale + dx,
                            top + row_index * scale + dy,
                            colour,
                        )
        x += (len(rows[0]) + 1) * scale


def splash(path, width=256, height=192):
    """The splash: a teal ground, a raised panel, the word in it."""
    image = Image.new("RGB", (width, height), TEAL)
    pixels = image.load()

    def put(x, y, colour):
        if 0 <= x < width and 0 <= y < height:
            pixels[x, y] = colour

    # The panel, with the raised edge every window on this desktop has: light
    # on the top and left, dark on the bottom and right.
    px0, py0, px1, py1 = 24, 56, width - 25, height - 57
    for x in range(px0, px1 + 1):
        for y in range(py0, py1 + 1):
            pixels[x, y] = GREY
    for x in range(px0, px1 + 1):
        put(x, py0, WHITE)
        put(x, py1, DARK_GREY)
    for y in range(py0, py1 + 1):
        put(px0, y, WHITE)
        put(px1, y, DARK_GREY)

    scale = 4
    word = "CHICAGO"
    word_width = (len(word) * 6 - 1) * scale
    left = (width - word_width) // 2
    top = py0 + ((py1 - py0) - 7 * scale) // 2 - 6

    # The shadow first, then the letters over it: the same trick the logon
    # screen uses, and the reason the word reads on a grey panel at all.
    text_block(put, word, left + scale // 2, top + scale // 2, scale, DARK_GREY)
    text_block(put, word, left, top, scale, NAVY)

    # A rule under the word, raised the same way as the panel.
    rule_y = top + 7 * scale + 10
    for x in range(px0 + 12, px1 - 11):
        put(x, rule_y, DARK_GREY)
        put(x, rule_y + 1, WHITE)

    image.save(path)
    return image.size


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    print("RIVETS.PNG", rivets(os.path.join(OUT, "RIVETS.PNG")))
    print("CHICAGO.PNG", splash(os.path.join(OUT, "CHICAGO.PNG")))
