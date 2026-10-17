#!/usr/bin/env python3
"""Compare the core's audio with MAME's, over the same window.

    compare_audio.py <mame.wav> <core.wav> [seconds]

Reports peak, RMS and the energy in five bands for each, and the ratios
between them.  A ratio near 1 in every band means the same sound at the same
level; a flat ratio away from 1 is a gain error; a ratio that varies with
frequency is a filter or a mix error.

No dependencies: the DFT is a plain Goertzel over a few hundred bins, which is
plenty to compare two recordings of the same thing.

MAME writes stereo at 48 kHz; the core is mono, and the two channels of
MAME's are the same for this board (its speaker is mono), so the left channel
is used.
"""
import math
import struct
import sys


def read_wav(path):
    d = open(path, 'rb').read()
    if d[:4] != b'RIFF' or d[8:12] != b'WAVE':
        sys.exit(f'{path}: not a WAV')
    i = 12
    fmt = None
    while i + 8 <= len(d):
        cid = d[i:i + 4]
        n = struct.unpack('<I', d[i + 4:i + 8])[0]
        body = d[i + 8:i + 8 + n]
        if cid == b'fmt ':
            fmt = struct.unpack('<HHIIHH', body[:16])
        elif cid == b'data':
            chans, rate = fmt[1], fmt[2]
            k = len(body) // 2
            s = struct.unpack(f'<{k}h', body[:2 * k])
            return list(s[::chans]), rate      # left channel
        i += 8 + n + (n & 1)
    sys.exit(f'{path}: no data chunk')


def rms(s):
    return math.sqrt(sum(float(v) * v for v in s) / len(s)) if s else 0.0


def band_energy(s, rate, lo, hi, bins=24):
    """Goertzel over `bins` frequencies spread through the band."""
    total = 0.0
    n = len(s)
    for b in range(bins):
        f = lo * (hi / lo) ** (b / max(bins - 1, 1))
        w = 2.0 * math.pi * f / rate
        c = 2.0 * math.cos(w)
        s1 = s2 = 0.0
        for v in s:
            s0 = v + c * s1 - s2
            s2, s1 = s1, s0
        total += (s1 * s1 + s2 * s2 - c * s1 * s2) / (n * n)
    return math.sqrt(total / bins)


BANDS = [(40, 120), (120, 400), (400, 1200), (1200, 4000), (4000, 12000)]


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    a, ra = read_wav(sys.argv[1])
    b, rb = read_wav(sys.argv[2])
    secs = float(sys.argv[3]) if len(sys.argv) > 3 else 8.0
    if ra != rb:
        print(f'note: {ra} Hz vs {rb} Hz; comparing the same number of seconds')
    na, nb = int(ra * secs), int(rb * secs)
    a, b = a[:na], b[:nb]
    if not a or not b:
        sys.exit('one of the recordings is shorter than the window asked for')

    print(f'{"":14}{"MAME":>12}{"core":>12}{"ratio":>10}')
    pa, pb = max(abs(v) for v in a), max(abs(v) for v in b)
    ra_, rb_ = rms(a), rms(b)
    print(f'{"peak":14}{pa:12d}{pb:12d}{(pb / pa if pa else 0):10.3f}')
    print(f'{"rms":14}{ra_:12.1f}{rb_:12.1f}{(rb_ / ra_ if ra_ else 0):10.3f}')
    # a coarse decimation keeps the Goertzel affordable on a few seconds
    step = max(1, len(a) // 48000)
    aa, bb = a[::step], b[::step]
    sa, sb = ra // step, rb // step
    for lo, hi in BANDS:
        if hi >= sa // 2 or hi >= sb // 2:
            continue
        ea = band_energy(aa, sa, lo, hi)
        eb = band_energy(bb, sb, lo, hi)
        print(f'{f"{lo}-{hi} Hz":14}{ea:12.2f}{eb:12.2f}{(eb / ea if ea else 0):10.3f}')


if __name__ == '__main__':
    main()
