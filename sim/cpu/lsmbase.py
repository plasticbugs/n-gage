#!/usr/bin/env python3
"""LDM/STM with the base register in the list and write-back, for the CPU's
lockstep bench (sim/cpu/tb_cpu.cpp --bin).

    sim/cpu/lsmbase.py OUT.bin

ARMv4 leaves these UNPREDICTABLE, so randprog.py never makes them, but games
use them: Glimmerati's span drawer opens with STMDB sp!, {r4-r12, sp, lr}
and closes with LDMIA sp!, {r4-r12, sp, lr}, and on the phone that pair
leaves sp where it was.  So an STM stores the base as it was before the
instruction, wherever the base is in the list, and an LDM leaves the base
holding the word it loaded, not the written-back address: what Unicorn
(QEMU) does, and what the pair needs.

Each STM is followed by plain LDRs of every word it stored, from a copy of
the base made before it, so a stored value the RTL and Unicorn differ on
shows at the LDR's retirement.  ARM: each of IA, IB, DA and DB, with the
base first, in the middle and last in the list, sp among r4-r14 as the game
has it, and the LDMs back.  Thumb: STMIA Rb! with Rb first and not first,
and LDMIA Rb! with Rb in the list.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from randprog import IO_BASE, IO_DBG_EXIT, Prog, mov_imm32  # noqa: E402

SCRATCH = 0x80800           # 0x80000-0x80fff is the bench's scratch RAM
COPY = 11                   # holds the base's value before each STM


def seed_regs(p, skip=()):
    for rd in range(15):
        if rd != COPY and rd not in skip:
            for w in mov_imm32(rd, 0x11111111 * (rd + 1) ^ 0x5A5A0000):
                p.arm(w)


def arm_lsm(load, mode, rn, regs):
    """LDM/STM{IA,IB,DA,DB} rn!, regs."""
    pu = {"DA": 0b00, "IA": 0b01, "DB": 0b10, "IB": 0b11}[mode]
    w = 0xE8000000 | (pu >> 1) << 24 | (pu & 1) << 23 | 1 << 21 | load << 20 | rn << 16
    for r in regs:
        w |= 1 << r
    return w


def first_word(mode, n):
    """the offset from the base of the lowest word an LDM/STM moves"""
    return {"IA": 0, "IB": 4, "DA": 4 - 4 * n, "DB": -4 * n}[mode]


def arm_case(p, mode, rn, regs):
    seed_regs(p)
    base = SCRATCH + 0x200
    for w in mov_imm32(rn, base):
        p.arm(w)
    p.arm(0xE1A00000 | COPY << 12 | rn)                          # MOV r11, rn
    p.arm(arm_lsm(0, mode, rn, regs))                             # STMxx rn!, {regs}
    off = first_word(mode, len(regs))
    for k in range(len(regs)):                                    # LDR r0, [r11, #off]
        o = off + 4 * k
        p.arm(0xE5100000 | (o >= 0) << 23 | COPY << 16 | abs(o))
    # and back, from where it stored them: the loaded base wins over the write-back
    for w in mov_imm32(rn, base):
        p.arm(w)
    p.arm(arm_lsm(1, mode, rn, regs))                             # LDMxx rn!, {regs}


def thumb_one(p, t):
    """one Thumb instruction between ARM code: in by BX, out by BX pc, which
    must sit on a word, ARM going on at the word after it"""
    p.arm(0xE28FC001)                                             # ADD r12, pc, #1
    p.arm(0xE12FFF1C)                                             # BX r12
    p.thumb(t)
    p.thumb(0x46C0)                                               # NOP (MOV r8, r8)
    p.thumb(0x4778)                                               # BX pc
    p.thumb(0x46C0)


def thumb_case(p, rb, regs):
    """STMIA rb!, {regs} and LDMIA rb!, {regs}, in Thumb, low registers only"""
    seed_regs(p)
    base = SCRATCH + 0x300
    for w in mov_imm32(rb, base):
        p.arm(w)
    p.arm(0xE1A00000 | COPY << 12 | rb)                           # MOV r11, rb
    lst = 0
    for r in regs:
        lst |= 1 << r
    thumb_one(p, 0xC000 | rb << 8 | lst)                          # STMIA rb!, {regs}
    for k in range(len(regs)):
        p.arm(0xE5900000 | COPY << 16 | 4 * k)                    # LDR r0, [r11, #4k]
    for w in mov_imm32(rb, base):
        p.arm(w)
    thumb_one(p, 0xC800 | rb << 8 | lst)                          # LDMIA rb!, {regs}


def program():
    p = Prog()
    for mode in ("IA", "IB", "DA", "DB"):
        for rn, regs in ((0, [0, 1, 2, 3]),                  # the base first
                         (5, [0, 3, 5, 7, 9]),               # in the middle
                         (7, [1, 2, 4, 7]),                  # last
                         (13, list(range(4, 15)))):          # sp among r4-r14
            arm_case(p, mode, rn, regs)
    thumb_case(p, 0, [0, 1, 2])                              # first
    thumb_case(p, 2, [0, 1, 2, 3])                           # not first
    thumb_case(p, 7, [3, 5, 7])                              # last
    for w in mov_imm32(COPY, IO_BASE):
        p.arm(w)
    p.arm(0xE3A0C000)                                        # MOV r12, #0
    p.arm(0xE58BC000 | IO_DBG_EXIT)                          # STR r12, [r11, #IO_DBG_EXIT]
    p.arm(0xEAFFFFFE)                                        # B .
    return p.bytes()


if __name__ == "__main__":
    with open(sys.argv[1], "wb") as f:
        f.write(program())
