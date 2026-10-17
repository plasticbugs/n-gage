#!/usr/bin/env python3
"""Pixel-diff two PNGs and report where they differ.

Zero differing pixels is the gate the reference renderer and, later, the RTL
have to pass. When it is not zero, the per-cell hotspot map usually says what
kind of mistake it is at a glance: a whole-image miss is colour, a regular grid
is tile decode, a band is scroll or rotation.

Usage: diff_frames.py <a.png> <b.png> [diff.png]
"""
import sys, zlib, struct


def read_png(path):
    d = open(path, 'rb').read()
    assert d[:8] == b'\x89PNG\r\n\x1a\n', f'{path}: not a PNG'
    pos, idat, w = 8, b'', None
    while pos < len(d):
        ln = struct.unpack('>I', d[pos:pos + 4])[0]
        tag = d[pos + 4:pos + 8]
        data = d[pos + 8:pos + 8 + ln]
        if tag == b'IHDR':
            w, h, depth, ctype = struct.unpack('>IIBB', data[:10])
            assert depth == 8, f'{path}: {depth}-bit not supported'
            assert ctype in (2, 6), f'{path}: colour type {ctype} not supported'
            nch = 3 if ctype == 2 else 4
        elif tag == b'IDAT':
            idat += data
        elif tag == b'IEND':
            break
        pos += 12 + ln
    raw = zlib.decompress(idat)
    stride = w * nch
    out = bytearray(w * h * 3)
    prev = bytearray(stride)
    p = 0
    for y in range(h):
        ft = raw[p]; p += 1
        line = bytearray(raw[p:p + stride]); p += stride
        if ft == 1:
            for i in range(nch, stride):
                line[i] = (line[i] + line[i - nch]) & 0xFF
        elif ft == 2:
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 0xFF
        elif ft == 3:
            for i in range(stride):
                a = line[i - nch] if i >= nch else 0
                line[i] = (line[i] + ((a + prev[i]) >> 1)) & 0xFF
        elif ft == 4:
            for i in range(stride):
                a = line[i - nch] if i >= nch else 0
                b = prev[i]
                c = prev[i - nch] if i >= nch else 0
                pp = a + b - c
                pa, pb, pc = abs(pp - a), abs(pp - b), abs(pp - c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 0xFF
        elif ft != 0:
            raise ValueError(f'{path}: filter {ft}')
        for x in range(w):
            out[(y * w + x) * 3:(y * w + x) * 3 + 3] = line[x * nch:x * nch + 3]
        prev = line
    return w, h, bytes(out)


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    a, b = sys.argv[1], sys.argv[2]
    wa, ha, pa = read_png(a)
    wb, hb, pb = read_png(b)
    if (wa, ha) != (wb, hb):
        print(f'SIZE MISMATCH: {a} is {wa}x{ha}, {b} is {wb}x{hb}')
        sys.exit(2)

    ndiff = 0
    cells = {}
    worst = (0, None)
    for y in range(ha):
        for x in range(wa):
            o = (y * wa + x) * 3
            if pa[o:o + 3] != pb[o:o + 3]:
                ndiff += 1
                cells[(x >> 3, y >> 3)] = cells.get((x >> 3, y >> 3), 0) + 1
                d = max(abs(pa[o + i] - pb[o + i]) for i in range(3))
                if d > worst[0]:
                    worst = (d, (x, y, tuple(pa[o:o + 3]), tuple(pb[o:o + 3])))

    total = wa * ha
    print(f'{a} vs {b}: {ndiff}/{total} pixels differ ({100.0 * ndiff / total:.3f}%)')
    if ndiff:
        top = sorted(cells.items(), key=lambda kv: -kv[1])[:10]
        print('  worst 8x8 cells (col,row)=count: ' +
              ' '.join(f'({c[0]},{c[1]})={n}' for c, n in top))
        d, w = worst
        print(f'  largest channel delta {d} at ({w[0]},{w[1]}): {w[2]} vs {w[3]}')
        if len(sys.argv) > 3:
            out = bytearray(total * 3)
            for i in range(total):
                if pa[i * 3:i * 3 + 3] != pb[i * 3:i * 3 + 3]:
                    out[i * 3] = 255
                else:
                    g = (pa[i * 3] + pa[i * 3 + 1] + pa[i * 3 + 2]) // 6
                    out[i * 3:i * 3 + 3] = bytes((g, g, g))
            raw = b''.join(b'\x00' + bytes(out[y * wa * 3:(y + 1) * wa * 3]) for y in range(ha))
            def chunk(t, dd):
                c = t + dd
                return struct.pack('>I', len(dd)) + c + struct.pack('>I', zlib.crc32(c))
            open(sys.argv[3], 'wb').write(
                b'\x89PNG\r\n\x1a\n'
                + chunk(b'IHDR', struct.pack('>IIBBBBB', wa, ha, 8, 2, 0, 0, 0))
                + chunk(b'IDAT', zlib.compress(bytes(raw), 9)) + chunk(b'IEND', b''))
            print(f'  wrote {sys.argv[3]} (red = differing)')
    sys.exit(0 if ndiff == 0 else 1)


if __name__ == '__main__':
    main()
