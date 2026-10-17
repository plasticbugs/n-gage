#!/usr/bin/env python3
"""Check the .rom image the .mra builds against MAME's own loaded regions.

MAME is the oracle for the ROM path too: tools/dump_regions.lua writes out the
bytes MAME hands to each chip, and this compares them with the corresponding
slice of the image, undoing the interleaving the .mra applies.  A mismatch
here means the core would be fed different bytes than the game expects, which
is the cheapest possible bug to find and the most expensive to find later.

Usage:
    verify_rom.py <image.rom> <region_dir>
"""
import sys

PROG_BASE, PROG_LEN = 0x000000, 0x080000
SND_BASE,  SND_LEN  = 0x080000, 0x010000
GFX_BASE,  GFX_LEN  = 0x090000, 0x100000


def fail(msg):
    print(f'FAIL: {msg}')
    sys.exit(1)


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    image = open(sys.argv[1], 'rb').read()
    d = sys.argv[2].rstrip('/')
    maincpu = open(f'{d}/maincpu.bin', 'rb').read()
    audiocpu = open(f'{d}/audiocpu.bin', 'rb').read()
    gfx = open(f'{d}/tc0180vcu.bin', 'rb').read()

    if len(image) != GFX_BASE + GFX_LEN:
        fail(f'image is {len(image)} bytes, expected {GFX_BASE + GFX_LEN}')

    # 68000 program: MAME's maincpu region is already big-endian byte order
    # (even ROM at offset 0 = high byte), so the .mra interleave must give
    # exactly the same bytes.
    if len(maincpu) != PROG_LEN:
        fail(f'maincpu region is {len(maincpu)} bytes, expected {PROG_LEN}')
    if image[PROG_BASE:PROG_BASE + PROG_LEN] != maincpu:
        i = next(k for k in range(PROG_LEN) if image[PROG_BASE + k] != maincpu[k])
        fail(f'68000 program differs at 0x{i:06x}: image {image[PROG_BASE+i]:02x}, '
             f'MAME {maincpu[i]:02x}')
    print(f'  68000 program  {PROG_LEN:7d} bytes  identical to MAME')

    if len(audiocpu) != SND_LEN:
        fail(f'audiocpu region is {len(audiocpu)} bytes, expected {SND_LEN}')
    if image[SND_BASE:SND_BASE + SND_LEN] != audiocpu:
        i = next(k for k in range(SND_LEN) if image[SND_BASE + k] != audiocpu[k])
        fail(f'Z80 program differs at 0x{i:06x}')
    print(f'  Z80 program    {SND_LEN:7d} bytes  identical to MAME')

    # Graphics: the .mra interleaves the two 512 KB halves two bytes at a time,
    # so image word 4k..4k+3 is gfx[2k], gfx[2k+1], gfx[0x80000+2k],
    # gfx[0x80000+2k+1].
    half = GFX_LEN // 2
    if len(gfx) != GFX_LEN:
        fail(f'tc0180vcu region is {len(gfx)} bytes, expected {GFX_LEN}')
    img = image[GFX_BASE:GFX_BASE + GFX_LEN]
    for k in range(half // 2):
        w = img[4 * k:4 * k + 4]
        want = bytes((gfx[2 * k], gfx[2 * k + 1], gfx[half + 2 * k], gfx[half + 2 * k + 1]))
        if w != want:
            fail(f'graphics differ at word {k} (image offset 0x{GFX_BASE + 4*k:06x}): '
                 f'{w.hex()} vs {want.hex()}')
    print(f'  graphics       {GFX_LEN:7d} bytes  identical to MAME (de-interleaved)')

    print('OK: the image carries exactly the bytes MAME loads')


if __name__ == '__main__':
    main()
