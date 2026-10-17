#!/usr/bin/env python3
"""Turn a 320x224 palette-index frame into a PNG, using a state's palette.

    idx2png.py <frame.idx> <state.bin> <out.png>
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pngio
import vcu_model as vcu


def main():
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    d = open(sys.argv[1], 'rb').read()
    idx = [int.from_bytes(d[2 * i:2 * i + 2], 'little') for i in range(vcu.W * vcu.H)]
    st = vcu.State(sys.argv[2])
    pngio.write(sys.argv[3], vcu.W, vcu.H, vcu.to_rgb(st, idx))


if __name__ == '__main__':
    main()
