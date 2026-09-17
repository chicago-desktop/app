#!/usr/bin/env python3
"""Original Desktop Widgets pixel art. Rebuild with Python and Pillow."""
from pathlib import Path
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1] / 'src/app/widget_manager/images'
BLACK, WHITE, GRAY, NAVY = '#000000', '#ffffff', '#c0c0c0', '#000080'


def draw_icon(size):
    image = Image.new('RGBA', (size, size))
    d = ImageDraw.Draw(image)

    def panel(box, header):
        x, y, r, b = box
        d.rectangle(box, fill=GRAY, outline=BLACK)
        d.line([(x + 1, b - 1), (x + 1, y + 1), (r - 1, y + 1)], fill=WHITE)
        d.rectangle((x + 2, y + 2, r - 2, y + header), fill=NAVY)

    if size == 16:
        panel((0, 1, 8, 14), 3)
        d.rectangle((2, 6, 6, 10), fill='#ffff00')
        d.point([(3, 5), (5, 5), (1, 8), (7, 8), (3, 11), (5, 11)], fill='#808000')
        panel((8, 0, 15, 7), 2)
        d.line([(11, 3), (11, 5), (13, 5)], fill=BLACK)
        panel((6, 8, 15, 15), 2)
        d.line([(8, 13), (9, 12), (10, 13), (12, 11), (13, 12)], fill='#008000')
    else:
        panel((1, 3, 17, 28), 5)
        d.rectangle((4, 10, 14, 25), fill='#00ffff')
        d.ellipse((6, 12, 12, 18), fill='#ffff00', outline='#808000')
        d.line([(9, 10), (9, 11)], fill='#808000')
        d.line([(4, 15), (5, 15)], fill='#808000')
        d.rectangle((7, 20, 13, 22), fill=WHITE)
        d.rectangle((5, 21, 11, 23), fill=WHITE)
        panel((18, 1, 30, 14), 4)
        d.ellipse((21, 6, 27, 12), fill=WHITE, outline='#808080')
        d.line([(24, 7), (24, 9), (26, 9)], fill=BLACK)
        panel((13, 16, 30, 30), 4)
        d.rectangle((16, 22, 27, 27), fill=BLACK)
        d.line([(16, 26), (18, 26), (20, 23), (22, 26), (25, 23), (27, 24)], fill='#00ff00')
    return image


if __name__ == '__main__':
    for size in (16, 32):
        target = ROOT / str(size) / 'widgets.png'
        target.parent.mkdir(parents=True, exist_ok=True)
        draw_icon(size).save(target)
