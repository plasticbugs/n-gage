#!/usr/bin/env python3
"""Render the on-screen keypad's panel, and the key each of its cells presses.

The Pocket has twelve buttons and the phone has more keys than that, so the
core draws a phone keypad over the picture and the pad presses keys on it
(rtl/ngage_osk.sv, shown and dismissed by SELECT + R).  This writes what that
module reads:

  rtl/osk/ngage_osk_panel.mif   the panel bitmap, for the block RAM (Quartus)
  rtl/osk/ngage_osk_panel.hex   the same, for the benches ($readmemh)

and, with --png, a picture of it in artifacts/osk/panel.png to check by eye.

The layout is a phone's: a 3 x 5 grid of 24 x 16 cells, 72 x 80 pixels drawn
one for one on the 176 x 208 picture.

    [ left soft ] [ C ] [ right soft ]
    [ 1 ]  [ 2 ]  [ 3 ]
    [ 4 ]  [ 5 ]  [ 6 ]
    [ 7 ]  [ 8 ]  [ 9 ]
    [ * ]  [ 0 ]  [ # ]

The soft keys carry a bar, as a Nokia's keycaps do: what they mean is on the
phone's screen, at its bottom corners.

The image (1,024 bytes, one block RAM):
  0x000-0x2CF  the bitmap: 1 bit a pixel, MSB leftmost, 9 bytes a row, 80 rows
  0x2D0-0x2DE  for the bench only: the pad key each cell presses, cells in
               reading order (row * 3 + column), as IO_KEYS bit - 12
               (sw/include/ngvm_hw.h: 0-9 the digits, 10 *, 11 #, 12 left
               soft key, 13 right soft key, 14 C).  The RTL works the same
               out with logic of its own, so the bench checks two
               independent statements of the layout against each other.

Usage: tools/make_osk_panel.py [--preview] [--png]
"""
import os
import sys

COLS, ROWS = 3, 5
CELL_W, CELL_H = 24, 16
W, H = COLS * CELL_W, ROWS * CELL_H          # 72 x 80
STRIDE = W // 8                              # 9 bytes a row
MAP_BASE = STRIDE * H                        # 0x2D0
ROM_SIZE = 1024

# The glyphs, drawn at twice their size: rows top-down, MSB left.  The
# digits are a blocky 3 x 5, the shape that stays readable at this size;
# * and # are 5 x 5, because three columns cannot draw either.
FONT = {
    '0': "111 101 101 101 111", '1': "010 110 010 010 111",
    '2': "111 001 111 100 111", '3': "111 001 111 001 111",
    '4': "101 101 111 001 001", '5': "111 100 111 001 111",
    '6': "111 100 111 101 111", '7': "111 001 001 001 001",
    '8': "111 101 111 101 111", '9': "111 101 111 001 111",
    'C': "111 100 100 100 111",
    '*': "00100 10101 01110 10101 00100",
    '#': "01010 11111 01010 11111 01010",
}

# (label, row, column, pad key = IO_KEYS bit - 12)
LAYOUT = [
    ('LSOFT', 0, 0, 12), ('C', 0, 1, 14), ('RSOFT', 0, 2, 13),
    ('1', 1, 0, 1), ('2', 1, 1, 2), ('3', 1, 2, 3),
    ('4', 2, 0, 4), ('5', 2, 1, 5), ('6', 2, 2, 6),
    ('7', 3, 0, 7), ('8', 3, 1, 8), ('9', 3, 2, 9),
    ('*', 4, 0, 10), ('0', 4, 1, 0), ('#', 4, 2, 11),
]


def render():
    img = [[0] * W for _ in range(H)]
    keymap = [0xFF] * (COLS * ROWS)

    def put(x, y):
        img[y][x] = 1

    for label, row, col, key in LAYOUT:
        x0, y0 = col * CELL_W, row * CELL_H
        # the key: a 1-pixel outline from (1,1) to (22,14) of its cell, the
        # corners cut, so neighbours stand two pixels apart
        for x in range(x0 + 2, x0 + CELL_W - 2):
            put(x, y0 + 1)
            put(x, y0 + CELL_H - 2)
        for y in range(y0 + 2, y0 + CELL_H - 2):
            put(x0 + 1, y)
            put(x0 + CELL_W - 2, y)
        if label in ('LSOFT', 'RSOFT'):
            # a bar, 12 x 2, in the middle of the key
            for y in (y0 + 7, y0 + 8):
                for x in range(x0 + 6, x0 + 18):
                    put(x, y)
        else:
            # one glyph at twice the font's size, 6 or 10 x 10, centred
            rows = FONT[label].split()
            gw = len(rows[0])
            tx, ty = x0 + (CELL_W - 2 * gw) // 2, y0 + (CELL_H - 10) // 2
            for r in range(5):
                for c in range(gw):
                    if rows[r][c] == '1':
                        for dy in range(2):
                            for dx in range(2):
                                put(tx + 2 * c + dx, ty + 2 * r + dy)
        keymap[row * COLS + col] = key
    return img, keymap


def rom_bytes(img, keymap):
    data = bytearray(ROM_SIZE)
    for y in range(H):
        for xb in range(STRIDE):
            b = 0
            for i in range(8):
                b = (b << 1) | img[y][xb * 8 + i]
            data[y * STRIDE + xb] = b
    for i, k in enumerate(keymap):
        data[MAP_BASE + i] = k
    return data


def main():
    img, keymap = render()
    data = rom_bytes(img, keymap)
    root = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
    os.makedirs(os.path.join(root, 'rtl/osk'), exist_ok=True)
    with open(os.path.join(root, 'rtl/osk/ngage_osk_panel.hex'), 'w') as f:
        f.write('\n'.join(f'{b:02x}' for b in data) + '\n')
    with open(os.path.join(root, 'rtl/osk/ngage_osk_panel.mif'), 'w') as f:
        f.write(f"DEPTH = {ROM_SIZE};\nWIDTH = 8;\nADDRESS_RADIX = HEX;\n"
                "DATA_RADIX = HEX;\nCONTENT\nBEGIN\n")
        for a, b in enumerate(data):
            f.write(f"{a:03X} : {b:02X};\n")
        f.write("END;\n")
    print(f"osk panel: {W}x{H}, {len(LAYOUT)} keys in a {COLS}x{ROWS} grid, "
          f"{MAP_BASE} bytes of bitmap, the key map at 0x{MAP_BASE:03X}")

    if '--preview' in sys.argv:
        for y in range(H):
            print(''.join('#' if v else '.' for v in img[y]))

    if '--png' in sys.argv:
        sys.path.insert(0, os.path.join(root, 'tools'))
        import pngio
        scale = 4
        fg, bg = (255, 255, 255), (0, 0, 0)
        rgb = bytearray()
        for y in range(H * scale):
            for x in range(W * scale):
                rgb += bytes(fg if img[y // scale][x // scale] else bg)
        out = os.path.join(root, 'artifacts/osk')
        os.makedirs(out, exist_ok=True)
        path = os.path.join(out, 'panel.png')
        pngio.write(path, W * scale, H * scale, rgb)
        print(f"wrote {path} ({W * scale}x{H * scale})")


if __name__ == "__main__":
    main()
