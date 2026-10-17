#!/usr/bin/env python3
"""Compare two 320x224 palette-index frames, the RTL's against the model's.

    diff_index.py <rtl.idx> <model.idx>

Indices, not colours: a difference here is a difference in what the chip
decided, before the palette can hide it.
"""
import collections
import sys

W, H = 320, 224


def load(path):
    d = open(path, 'rb').read()
    if len(d) != W * H * 2:
        sys.exit(f'{path}: {len(d)} bytes, expected {W * H * 2}')
    return [int.from_bytes(d[2 * i:2 * i + 2], 'little') for i in range(W * H)]


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    a, b = load(sys.argv[1]), load(sys.argv[2])
    diffs = [i for i in range(W * H) if a[i] != b[i]]
    if not diffs:
        return 0
    rows = collections.Counter(i // W for i in diffs)
    cols = collections.Counter(i % W for i in diffs)
    print(f'{len(diffs)} of {W * H} indices differ; '
          f'{len(rows)} rows, {len(cols)} columns')
    for i in diffs[:8]:
        y, x = divmod(i, W)
        print(f'    ({x},{y + 16}) rtl 0x{a[i]:03x}  model 0x{b[i]:03x}')
    return 1


if __name__ == '__main__':
    sys.exit(main())
