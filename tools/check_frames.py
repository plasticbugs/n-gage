#!/usr/bin/env python3
"""Fail if the picture alternates between frames.

    tools/check_frames.py <dir|frame.rgb ...> [-w 640] [-h 256] [-quiet]

Capture three or more CONSECUTIVE frames of a still picture -- a boot screen,
an attract mode paused, a test pattern -- and run this on them.  It compares
each frame with the next, and with the one after that.  If neighbours differ
while frames two apart are identical, the core is emitting alternating
fields, and it exits non-zero.

**Why this is a gate and not a nicety.**  The Analogue Pocket has an OLED
panel.  A core whose picture alternates at 25 Hz is drawing two different
images into the same pixels forever, and OLED burn-in is permanent.  This
check exists because a core shipped that way and marked a user's screen.  The
core was correct in the sense that mattered to the benches -- every frame
matched the emulator, the memory gate passed, timing closed -- because no
bench had ever compared one frame with the NEXT one.

The usual cause is honest emulation of an interlaced display.  A CRTC
programmed for interlace puts the field number into the low bit of the
scanline address and delays one field's vsync by half a line, so alternate
frames draw different scanlines from a different vertical origin.  A CRT's
phosphor and a viewer's eye merge the two; a fixed-pixel panel cannot, and
shows it as a shimmer -- "like looking at a CRT" is exactly what a user
reports, because it is the same signal.

The fix is not to stop emulating interlace but to stop ALTERNATING: keep the
geometry the machine asks for and draw the same field every frame.

Frames are raw RGB triples, width x height, the format the benches dump.
"""
import os
import sys


def load(path, w, h):
    d = open(path, 'rb').read()
    if len(d) != w * h * 3:
        sys.exit(f'{path}: {len(d)} bytes is not {w}x{h}x3 ({w*h*3})')
    return d


def differing(a, b):
    return sum(1 for i in range(0, len(a), 3) if a[i:i + 3] != b[i:i + 3])


def main(argv):
    w, h, quiet, args = 640, 256, False, []
    i = 1
    while i < len(argv):
        if argv[i] == '-w':
            i += 1; w = int(argv[i])
        elif argv[i] == '-h':
            i += 1; h = int(argv[i])
        elif argv[i] == '-quiet':
            quiet = True
        else:
            args.append(argv[i])
        i += 1
    if not args:
        print(__doc__)
        return 2

    files = []
    for a in args:
        if os.path.isdir(a):
            files += [os.path.join(a, f) for f in sorted(os.listdir(a))
                      if f.endswith('.rgb')]
        else:
            files.append(a)
    files.sort()
    if len(files) < 3:
        print(f'need at least three consecutive frames, got {len(files)}')
        return 2

    frames = [load(f, w, h) for f in files]
    total = w * h
    near = [differing(frames[i], frames[i + 1]) for i in range(len(frames) - 1)]
    far = [differing(frames[i], frames[i + 2]) for i in range(len(frames) - 2)]

    if not quiet:
        for i, f in enumerate(files):
            line = f'  {os.path.basename(f)}'
            if i < len(near):
                line += f'   vs next: {near[i]:>8,}'
            if i < len(far):
                line += f'   vs next but one: {far[i]:>8,}'
            print(line)

    alternating = all(n > 0 for n in near) and all(f == 0 for f in far)
    if alternating:
        pct = 100.0 * max(near) / total
        print(f'\nFAIL  the picture alternates: every frame differs from its '
              f'neighbour ({max(near):,} pixels, {pct:.2f}% of the picture) '
              f'while frames two apart are identical.')
        print('      That is an interlaced field reaching a fixed-pixel panel. '
              'On an OLED it burns in.')
        return 1
    if all(n == 0 for n in near):
        print(f'\nPASS  {len(frames)} consecutive frames of a still picture are '
              f'identical')
        return 0
    print(f'\nPASS  the picture changes, but not in an alternating pattern '
          f'(something on screen is moving; use a still picture for this check)')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
