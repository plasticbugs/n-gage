#!/usr/bin/env python3
"""Random ARM programs for the CPU's lockstep bench (sim/cpu/tb_cpu.cpp --bin).

    sim/cpu/randprog.py SEED N OUT.bin

Writes N random instructions between a prologue that loads r0-r7 with
random values and an epilogue that writes IO_DBG_EXIT.  Every instruction
is one whose result ARMv4 defines, so the RTL and Unicorn must agree on
every retirement.  The mix is chosen for the pipeline's hazards: results
used at once, by the shifter, as a shift amount, as store data, as a
multiplier input; loads used at once; instructions that do not execute
between a producer and its consumer; flags set and read back to back;
redirects from each stage.

Registers: r0-r7 carry data; r8 is the base of a 4 KB scratch area and
never changes; r9 is a fixed offset (0x40); r10 is a base that moves
(write-back) and is put back to r8 now and then; r11 switches between ARM
and Thumb; sp is a stack in the scratch area for the subroutines' pushes.
Thumb blocks keep their own base in r7 and offset in r6.
"""
import random
import struct
import sys

SCRATCH = 0x80800           # r8: the middle of 0x80000-0x80fff
IO_BASE = 0xF0000000
IO_DBG_EXIT = 0x004


def cond(r):
    return 14 if r.random() < 0.55 else r.randrange(14)


def rot_imm(r):
    return (r.randrange(16) << 8) | r.randrange(256)


def mov_imm32(rd, v):
    """MOV/ORR sequence for a 32-bit constant."""
    out = [0xE3A00000 | rd << 12 | (v & 0xFF)]
    for k, rot in ((1, 12), (2, 8), (3, 4)):        # bytes 1..3, as imm8 ROR 24/16/8
        b = (v >> (8 * k)) & 0xFF
        if b:
            out.append(0xE3800000 | rd << 16 | rd << 12 | rot << 8 | b)
    return out


def dp(r, rd_ok=range(8)):
    op = r.randrange(16)
    s = 1 if 8 <= op <= 11 else r.randrange(2)
    rd = r.choice(rd_ok) if not 8 <= op <= 11 else 0
    rn = 0 if op in (13, 15) else r.randrange(8)        # MOV, MVN: Rn should be zero (QEMU insists)
    w = cond(r) << 28 | op << 21 | s << 20 | rn << 16 | rd << 12
    form = r.randrange(3)
    if form == 0:
        return w | 1 << 25 | rot_imm(r)
    rm = r.randrange(8)
    typ = r.randrange(4)
    if form == 1:
        return w | r.randrange(32) << 7 | typ << 5 | rm
    rs = r.randrange(8)
    return w | rs << 8 | typ << 5 | 1 << 4 | rm


def mul(r):
    rd = r.randrange(8)
    rm = r.choice([x for x in range(8) if x != rd])
    rs, rn = r.randrange(8), r.randrange(8)
    a, s = r.randrange(2), r.randrange(2)
    if not a:
        rn = 0                                          # MUL: Rn should be zero
    return cond(r) << 28 | a << 21 | s << 20 | rd << 16 | rn << 12 | rs << 8 | 0x90 | rm


def mull(r):
    lo, hi, rm = r.sample(range(8), 3)
    rs = r.randrange(8)
    u, a, s = r.randrange(2), r.randrange(2), r.randrange(2)
    return cond(r) << 28 | 1 << 23 | u << 22 | a << 21 | s << 20 | hi << 16 | lo << 12 | rs << 8 | 0x90 | rm


def ldst(r):
    l, b = r.randrange(2), r.randrange(2)
    rd = r.randrange(8)
    if r.random() < 0.3:                                # base r10, with write-back
        rn, p, wb = 10, r.randrange(2), 1
        off = r.randrange(0, 16) * 4
    else:
        rn, p, wb = 8, 1, 0
        off = r.randrange(0, 256) * 4
    if b and rn == 8:                                   # r10 stays word-aligned: unaligned
        off += r.randrange(4)                           # word accesses differ in QEMU
    u = r.randrange(2)
    w = cond(r) << 28 | 1 << 26 | p << 24 | u << 23 | b << 22 | (wb if p else 0) << 21 | l << 20 | rn << 16 | rd << 12
    if r.random() < 0.25 and not b:                     # register offset: r9, scaled
        return w | 1 << 25 | r.randrange(3) << 7 | 9
    return w | off


def ldsth(r):
    kind = r.randrange(4)                               # STRH, LDRH, LDRSB, LDRSH
    l = 0 if kind == 0 else 1
    sh = {0: 1, 1: 1, 2: 2, 3: 3}[kind]
    rd = r.randrange(8)
    rn = r.choice([8, 10])
    p = 1 if rn == 8 else r.randrange(2)
    wb = 0 if rn == 8 else 1
    if rn == 10:
        off = r.randrange(0, 32) * 4
    else:
        off = r.randrange(0, 64) * 2 + (r.randrange(2) if kind == 2 else 0)
    u = r.randrange(2)
    return (cond(r) << 28 | p << 24 | u << 23 | 1 << 22 | (wb if p else 0) << 21 | l << 20 | rn << 16
            | rd << 12 | (off >> 4) << 8 | 1 << 7 | sh << 5 | 1 << 4 | (off & 15))


def ldm(r):
    l = r.randrange(2)
    pu = r.randrange(4)
    rn = r.choice([8, 10])
    wb = 1 if rn == 10 else 0
    regs = 0
    while not regs:
        regs = r.randrange(256)
    return cond(r) << 28 | 1 << 27 | pu << 23 | wb << 21 | l << 20 | rn << 16 | regs


def swp(r):
    b = r.randrange(2)
    rd, rm = r.randrange(8), r.randrange(8)
    return cond(r) << 28 | 1 << 24 | b << 22 | 8 << 16 | rd << 12 | 0x90 | rm


def psr(r):
    if r.randrange(2):                                  # MRS rd, CPSR
        return cond(r) << 28 | 0x010F0000 | r.randrange(8) << 12
    if r.randrange(2):                                  # MSR CPSR_f, rm
        return cond(r) << 28 | 0x0128F000 | r.randrange(8)
    return cond(r) << 28 | 0x0328F000 | 2 << 8 | r.randrange(16)   # MSR CPSR_f, #nibble ROR 4


# ---------------------------------------------------------------- Thumb
# Inside a Thumb block r7 is the scratch base (r7 = r8, put back now and
# then, as LDMIA r7! moves it) and r6 a fixed offset (r6 = r9); results go
# to r0-r5.

def t_one(r):
    """One random single-halfword Thumb instruction."""
    x = r.random()
    rd, rs = r.randrange(6), r.randrange(8)
    if x < 0.30:                                        # format 4: ALU
        op = r.randrange(16)
        if op == 13:                                    # MUL Rd, Rs: Rd != Rs
            rs = r.choice([v for v in range(8) if v != rd])
        return 0x4000 | op << 6 | rs << 3 | rd
    if x < 0.40:                                        # format 1: shift by immediate
        return r.randrange(3) << 11 | r.randrange(32) << 6 | rs << 3 | rd
    if x < 0.50:                                        # format 2: ADD/SUB register or #3
        return 0x1800 | r.randrange(4) << 9 | r.randrange(8) << 6 | rs << 3 | rd
    if x < 0.60:                                        # format 3: MOV/CMP/ADD/SUB #8
        op = r.randrange(4)
        return 0x2000 | op << 11 | (r.randrange(8) if op == 1 else rd) << 8 | r.randrange(256)
    if x < 0.66:                                        # format 5: with r8-r12
        hs = r.randrange(5)
        kind = r.randrange(4)
        if kind == 0: return 0x4640 | hs << 3 | rd     # MOV rd, r8+hs
        if kind == 1: return 0x4440 | hs << 3 | rd     # ADD rd, r8+hs
        if kind == 2: return 0x4540 | hs << 3 | rs     # CMP rs, r8+hs
        return 0x4680 | rs << 3 | r.randrange(3, 5)    # MOV r11/r12, rs
    if x < 0.70:                                        # format 6: LDR rd, [pc, #imm]
        return 0x4800 | rd << 8 | r.randrange(256)
    if x < 0.78:                                        # format 7/8: [r7, r6]
        if r.randrange(2):
            l, b = r.randrange(2), r.randrange(2)
            return 0x5000 | l << 11 | b << 10 | 6 << 6 | 7 << 3 | (rd if l else rs)
        hs = r.randrange(4)                             # STRH LDRSB LDRH LDRSH
        return 0x5200 | hs << 10 | 6 << 6 | 7 << 3 | (rs if hs == 0 else rd)
    if x < 0.88:                                        # format 9/10: [r7, #imm]
        l = r.randrange(2)
        k = r.randrange(3)
        if k == 2:
            return 0x8000 | l << 11 | r.randrange(32) << 6 | 7 << 3 | (rd if l else rs)
        return 0x6000 | k << 12 | l << 11 | r.randrange(32) << 6 | 7 << 3 | (rd if l else rs)
    if x < 0.92:                                        # format 12: ADD rd, pc/sp, #imm
        return 0xA000 | r.randrange(2) << 11 | rd << 8 | r.randrange(256)
    lst = 0
    while not lst:
        lst = r.randrange(64)
    return 0xC000 | r.randrange(2) << 11 | 7 << 8 | lst  # format 15: LDMIA/STMIA r7!, {r0-r5}


class Prog:
    def __init__(self):
        self.h = []                                     # halfwords

    def here(self):
        return 2 * len(self.h)

    def arm(self, w):
        assert len(self.h) % 2 == 0
        self.h += [w & 0xFFFF, (w >> 16) & 0xFFFF]

    def thumb(self, t):
        self.h.append(t & 0xFFFF)

    def patch_arm(self, at, w):
        self.h[at // 2] = w & 0xFFFF
        self.h[at // 2 + 1] = (w >> 16) & 0xFFFF

    def bytes(self):
        return b"".join(struct.pack("<H", x) for x in self.h)


def arm_b(frm, to, link=False, c=14):
    return c << 28 | 0x0A000000 | link << 24 | ((to - frm - 8) >> 2) & 0xFFFFFF


def thumb_bl(frm, to):
    off = to - (frm + 4)
    return 0xF000 | (off >> 12) & 0x7FF, 0xF800 | (off >> 1) & 0x7FF


def thumb_block(r, p, n):
    """ARM -> Thumb, n random Thumb instructions, -> ARM."""
    p.arm(0xE28FB001)                                   # ADD r11, pc, #1
    p.arm(0xE12FFF1B)                                   # BX r11
    p.thumb(0x4647)                                     # MOV r7, r8
    p.thumb(0x464E)                                     # MOV r6, r9
    since_r7 = 0
    for _ in range(n):
        x = r.random()
        since_r7 += 1
        if since_r7 > 12:
            p.thumb(0x4647); since_r7 = 0
        elif x < 0.75:
            p.thumb(t_one(r))
        elif x < 0.85:                                  # Bcc forward over 0-3
            k = r.randrange(4)
            p.thumb(0xD000 | r.randrange(14) << 8 | (k - 1) & 0xFF)
            for _ in range(k):
                p.thumb(t_one(r))
        elif x < 0.88:                                  # B forward over 0-2
            k = r.randrange(3)
            p.thumb(0xE000 | (k - 1) & 0x7FF)
            for _ in range(k):
                p.thumb(t_one(r))
        else:                                           # BL to a subroutine, and back
            call = p.here()
            p.thumb(0); p.thumb(0)                      # BL sub, patched below
            over = p.here()
            p.thumb(0)                                  # B after, patched below
            sub = p.here()
            ret = r.randrange(3)
            if ret == 2:
                p.thumb(0xB500)                         # PUSH {lr}
            for _ in range(r.randrange(6)):
                p.thumb(t_one(r))
            if ret == 0: p.thumb(0x4770)                # BX lr
            elif ret == 1: p.thumb(0x46F7)              # MOV pc, lr
            else: p.thumb(0xBD00)                       # POP {pc}
            after = p.here()
            hi, lo = thumb_bl(call, sub)
            p.h[call // 2], p.h[call // 2 + 1] = hi, lo
            p.h[over // 2] = 0xE000 | ((after - over - 4) >> 1) & 0x7FF
    if p.here() % 4:
        p.thumb(0x46C0)                                 # MOV r8, r8
    p.thumb(0x4778)                                     # BX pc: ARM at here + 4
    p.thumb(0x46C0)


def arm_one(r, p):
    x = r.random()
    if x < 0.40: p.arm(dp(r))
    elif x < 0.45: p.arm(mul(r))
    elif x < 0.49: p.arm(mull(r))
    elif x < 0.63: p.arm(ldst(r))
    elif x < 0.70: p.arm(ldsth(r))
    elif x < 0.76: p.arm(ldm(r))
    elif x < 0.78: p.arm(swp(r))
    elif x < 0.82: p.arm(psr(r))
    elif x < 0.90:                                      # Bcc forward over 0-3 instructions
        k = r.randrange(4)
        p.arm(cond(r) << 28 | 0x0A000000 | (k - 1) & 0xFFFFFF)
        for _ in range(k):
            p.arm(dp(r))
    elif x < 0.93:                                      # ADDcc pc, pc, #4k: skip k+1 (M redirect)
        k = r.randrange(3)
        p.arm(cond(r) << 28 | 0x028FF000 | 4 * k)
        for _ in range(k + 1):
            p.arm(dp(r))
    elif x < 0.96:                                      # LDRcc pc, [pc] over a literal (W redirect)
        here = p.here()
        p.arm(cond(r) << 28 | 0x059FF000)               # LDRcc pc, [pc, #0]: the word at here+8
        p.arm(0xEA000000)                               # B here+12
        p.arm(here + 12)                                # .word here+12
    else:                                               # BL to a subroutine, and back
        call = p.here()
        p.arm(0)
        over = p.here()
        p.arm(0)
        sub = p.here()
        ret = r.randrange(3)
        regs = r.randrange(16)
        if ret == 2:
            p.arm(0xE92D4000 | regs)                    # STMDB sp!, {.., lr}
        for _ in range(r.randrange(6)):
            p.arm(dp(r))
        if ret == 0: p.arm(0xE12FFF1E)                  # BX lr
        elif ret == 1: p.arm(0xE1A0F00E)                # MOV pc, lr
        else: p.arm(0xE8BD8000 | regs)                  # LDMIA sp!, {.., pc}
        after = p.here()
        p.patch_arm(call, arm_b(call, sub, link=True))
        p.patch_arm(over, arm_b(over, after))


def program(seed, n):
    r = random.Random(seed)
    p = Prog()
    for rd in range(8):
        for w in mov_imm32(rd, r.getrandbits(32)):
            p.arm(w)
    for w in mov_imm32(8, SCRATCH) + mov_imm32(9, 0x40):
        p.arm(w)
    p.arm(0xE1A0A008)                                   # MOV r10, r8
    p.arm(0xE288DC06)                                   # ADD sp, r8, #0x600
    since_r10 = 0
    while p.here() < 4 * n:
        if since_r10 > 24:
            p.arm(0xE1A0A008); since_r10 = 0; continue
        since_r10 += 1
        if r.random() < 0.03:
            thumb_block(r, p, r.randrange(10, 80))
        else:
            arm_one(r, p)
    for w in mov_imm32(11, IO_BASE):
        p.arm(w)
    p.arm(0xE3A0C000)                                   # MOV r12, #0
    p.arm(0xE58BC000 | IO_DBG_EXIT)                     # STR r12, [r11, #IO_DBG_EXIT]
    p.arm(0xEAFFFFFE)                                   # B .
    return p.bytes()


if __name__ == "__main__":
    seed, n, out = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
    with open(out, "wb") as f:
        f.write(program(seed, n))
