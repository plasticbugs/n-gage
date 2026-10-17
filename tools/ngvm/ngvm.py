#!/usr/bin/env python3
"""NGVM, the software reference for the machine this core implements.

An ARMv4T (Unicorn) with the memory map and devices of sw/include/ngvm_hw.h,
running the NGVM kernel and, above it, the user's own N-Gage firmware.  The
RTL implements the same machine; this is what it is checked against.

    tools/ngvm/ngvm.py --rom SYM.ROM [--drive game.img] [--seconds 10]
                       [--frames-to DIR --frame-every N] [--keys SCRIPT]

Time is virtual: MIPS instructions are one microsecond (default 100), so a
run is reproducible instruction for instruction, whatever the host's speed.
The idle thread's loop is recognised by address and skipped to the next
interrupt.
"""
import argparse, ctypes, os, re, struct, sys, time

from unicorn import (Uc, UcError, UC_ARCH_ARM, UC_MODE_ARM, UC_HOOK_INTR,
                     UC_PROT_READ, UC_PROT_EXEC, UC_PROT_ALL, UC_HOOK_MEM_WRITE)
from unicorn.arm_const import *

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, 'tools'))
import pngio  # noqa: E402


def hw_constants():
    """The #defines of ngvm_hw.h, so this file cannot drift from the header."""
    out = {}
    for line in open(os.path.join(ROOT, 'sw', 'include', 'ngvm_hw.h')):
        m = re.match(r'#define\s+(\w+)\s+(\(1u << (\d+)\)|0x[0-9A-Fa-f]+u?|\d+)(?=\s|$)', line)
        if m:
            out[m.group(1)] = (1 << int(m.group(3))) if m.group(3) else int(m.group(2).rstrip('u'), 0)
    return out


HW = hw_constants()
G = globals()
G.update(HW)

REGS = [UC_ARM_REG_R0 + i for i in range(13)] + [UC_ARM_REG_SP, UC_ARM_REG_LR, UC_ARM_REG_PC]


def load_elf(path):
    d = open(path, 'rb').read()
    assert d[:4] == b'\x7fELF'
    entry, phoff = struct.unpack_from('<II', d, 0x18)[0], struct.unpack_from('<I', d, 0x1C)[0]
    phentsize, phnum = struct.unpack_from('<HH', d, 0x2A)
    segs, syms = [], {}
    for i in range(phnum):
        typ, off, vaddr, paddr, filesz, memsz = struct.unpack_from('<6I', d, phoff + i * phentsize)
        if typ == 1 and filesz:
            segs.append((paddr, d[off:off + filesz]))
    # symbol table, for naming the idle loop and for reports
    shoff, = struct.unpack_from('<I', d, 0x20)
    shentsize, shnum, shstrndx = struct.unpack_from('<HHH', d, 0x2E)
    sh = [struct.unpack_from('<10I', d, shoff + i * shentsize) for i in range(shnum)]
    for s in sh:
        if s[1] == 2:  # SYMTAB
            strtab = sh[s[6]]
            for j in range(s[5] // 16):
                name, value, size, info, other, shndx = struct.unpack_from('<IIIBBH', d, s[4] + j * 16)
                n = d[strtab[4] + name:d.index(b'\0', strtab[4] + name)].decode()
                if n:
                    syms[n] = value
    return entry, segs, syms


class Machine:
    def __init__(self, args):
        self.a = args
        self.mips = args.mips
        self.uc = uc = Uc(UC_ARCH_ARM, UC_MODE_ARM)
        uc.ctl_set_cpu_model(UC_CPU_ARM_TI925T)    # ARMv4T, as the firmware was built for
        # RAM is one host buffer, seen at NGVM_PHYS_BASE, its first MB at
        # NGVM_KERN_BASE, and its pages wherever the page table puts them.
        self.ram = (ctypes.c_ubyte * NGVM_RAM_SIZE)()
        self.ram_addr = ctypes.addressof(self.ram)
        uc.mem_map_ptr(NGVM_PHYS_BASE, NGVM_RAM_SIZE, UC_PROT_ALL, self.ram_addr)
        uc.mem_map_ptr(NGVM_KERN_BASE, NGVM_KERN_SIZE, UC_PROT_ALL, self.ram_addr)
        self.pt = {}                   # table index -> RAM page
        uc.mem_map(NGVM_KSEC_BASE, NGVM_KSEC_SIZE, UC_PROT_ALL)
        rom = open(args.rom, 'rb').read()
        if len(rom) > NGVM_ROM_MAX:
            sys.exit('ROM larger than NGVM_ROM_MAX')
        uc.mem_map(NGVM_ROM_BASE, (len(rom) + 0xFFFF) & ~0xFFFF, UC_PROT_READ | UC_PROT_EXEC)
        uc.mem_write(NGVM_ROM_BASE, rom)
        uc.mem_map(NGVM_DRIVE_BASE, NGVM_DRIVE_MAX, UC_PROT_ALL)
        self.rom_size = len(rom)
        self.drive_size = 0
        if args.drive:
            img = open(args.drive, 'rb').read()
            self.drive_size = len(img)
            if len(img) > NGVM_DRIVE_MAX:
                sys.exit('drive image larger than NGVM_DRIVE_MAX')
            uc.mem_write(NGVM_DRIVE_BASE, img)
        uc.mmio_map(NGVM_IO_BASE, 0x1000, self.io_read, None, self.io_write, None)

        entry, segs, self.syms = load_elf(args.kernel)
        for addr, data in segs:
            uc.mem_write(addr, data)
        self.idle_pc = self.syms['idle_loop']
        uc.hook_add(UC_HOOK_INTR, self.on_intr)

        # devices
        self.insns = 0                 # virtual time, in instructions
        self.irq_status = 0
        self.irq_enable = 0
        self.timer_cmp = None
        self.timer_hi_latch = 0
        self.lcd_base = 0
        self.lcd_ctrl = 0
        self.frames = 0
        self.keys = 0
        self.audio = []                # samples (int16 L, int16 R)
        self.audio_rate = 8000
        self.audio_fifo = 0.0          # samples waiting, drained at audio_rate
        self.exit_code = None
        self.con = bytearray()
        self.slice_us = 0.0

        uc.reg_write(UC_ARM_REG_CPSR, 0xD3)
        self.pc = entry

    # ---- time ---------------------------------------------------------------
    def now_us(self):
        return self.insns // self.mips

    def frame_period_insns(self):
        return self.mips * 1000000 // 60

    # ---- devices ------------------------------------------------------------
    def io_read(self, uc, off, size, ud):
        if off == IO_TIMER_US:
            t = self.now_us()
            self.timer_hi_latch = t >> 32
            return t & 0xFFFFFFFF
        if off == IO_TIMER_US_HI:
            return self.timer_hi_latch
        if off == IO_IRQ_STATUS:
            return self.irq_status
        if off == IO_IRQ_ENABLE:
            return self.irq_enable
        if off == IO_LCD_BASE:
            return self.lcd_base
        if off == IO_LCD_CTRL:
            return self.lcd_ctrl
        if off == IO_LCD_FRAME:
            return self.frames
        if off == IO_KEYS:
            return self.keys
        if off == IO_AUDIO_LEVEL:
            return int(self.audio_fifo)
        if off == IO_AUDIO_RATE:
            return self.audio_rate
        if off == IO_AUDIO_SIZE:
            return 4096
        if off == IO_DRIVE_SIZE:
            return self.drive_size
        if off == IO_ROM_SIZE:
            return self.rom_size
        return 0

    def io_write(self, uc, off, size, value, ud):
        if off == IO_DBG_PUTC:
            c = value & 0xFF
            if c == 10:
                print(self.con.decode('latin-1'), flush=True)
                self.con = bytearray()
            else:
                self.con.append(c)
        elif off == IO_DBG_HEX:
            print('[hex] %08x' % value, flush=True)
        elif off == IO_DBG_EXIT:
            if self.con:
                print(self.con.decode('latin-1'), flush=True)
            self.exit_code = value
            uc.emu_stop()
        elif off == IO_TIMER_CMP:
            self.timer_cmp = value
        elif off == IO_IRQ_STATUS:
            self.irq_status &= ~value
        elif off == IO_IRQ_ENABLE:
            self.irq_enable = value
        elif off == IO_LCD_BASE:
            self.lcd_base = value
        elif off == IO_LCD_CTRL:
            self.lcd_ctrl = value
        elif off == IO_AUDIO_DATA:
            self.audio.append(value)
            self.audio_fifo += 1
        elif off == IO_AUDIO_RATE:
            self.audio_rate = value or 8000
        elif off == IO_PT_INDEX:
            self.pt_index = value
        elif off == IO_PT_DATA:
            self.pt_set(self.pt_index, value)
        elif off == IO_CACHE_FLUSH:
            pass

    def pt_virt(self, i):
        if i < NGVM_PT_CHUNK:
            return NGVM_CHUNK_BASE + (i << NGVM_PAGE_SHIFT)
        return NGVM_DATA_BASE + ((i - NGVM_PT_CHUNK) << NGVM_PAGE_SHIFT)

    def pt_set(self, i, page):
        if i >= NGVM_PT_ENTRIES:
            return self.fault('page table index %d out of range' % i)
        v = self.pt_virt(i)
        if i in self.pt:
            self.uc.mem_unmap(v, NGVM_PAGE_SIZE)
            del self.pt[i]
        if page != NGVM_PT_NONE:
            if (page + 1) << NGVM_PAGE_SHIFT > NGVM_RAM_SIZE:
                return self.fault('page table entry %d -> RAM page %x beyond RAM' % (i, page))
            self.uc.mem_map_ptr(v, NGVM_PAGE_SIZE, UC_PROT_ALL, self.ram_addr + (page << NGVM_PAGE_SHIFT))
            self.pt[i] = page

    # ---- exceptions -----------------------------------------------------------
    def enter(self, vector, mode, ret):
        uc = self.uc
        cpsr = uc.reg_read(UC_ARM_REG_CPSR)
        uc.reg_write(UC_ARM_REG_CPSR, (cpsr & ~0x3F) | 0x80 | mode)   # ARM state, IRQ off
        uc.reg_write(UC_ARM_REG_SPSR, cpsr)
        uc.reg_write(UC_ARM_REG_LR, ret)
        uc.reg_write(UC_ARM_REG_PC, vector)

    def on_intr(self, uc, intno, ud):
        if intno == 2:      # SWI: Unicorn has already stepped past it
            self.enter(0x08, 0x13, uc.reg_read(UC_ARM_REG_PC))
        else:
            self.fault('CPU exception %d' % intno)

    def irq_line(self):
        return self.irq_status & self.irq_enable

    def update_devices(self):
        t = self.now_us()
        if self.timer_cmp is not None and (t & 0xFFFFFFFF) - self.timer_cmp < 0x80000000:
            self.irq_status |= IRQ_TIMER
            self.timer_cmp = None
        f = self.insns // self.frame_period_insns()
        while self.frames < f:
            self.frames += 1
            self.irq_status |= IRQ_VBLANK
            self.on_frame()
        # the audio FIFO drains at its rate
        self.audio_fifo = max(0.0, self.audio_fifo - self.audio_rate * self.slice_us)
        if self.audio_fifo <= 2048:
            self.irq_status |= IRQ_AUDIO

    def next_event_insns(self):
        """Instructions until something can raise an interrupt."""
        cands = [(self.frames + 1) * self.frame_period_insns()]
        if self.timer_cmp is not None:
            cands.append(((self.timer_cmp - (self.now_us() & 0xFFFFFFFF)) & 0xFFFFFFFF) * self.mips + self.insns)
        return max(min(cands), self.insns + 1)

    # ---- the LCD --------------------------------------------------------------
    def frame_rgb(self):
        raw = self.uc.mem_read(self.lcd_base, LCD_W * LCD_H * 2) if self.lcd_base else bytes(LCD_W * LCD_H * 2)
        rgb = bytearray(LCD_W * LCD_H * 3)
        for i, (p,) in enumerate(struct.iter_unpack('<H', raw)):
            rgb[i * 3] = ((p >> 8) & 15) * 17
            rgb[i * 3 + 1] = ((p >> 4) & 15) * 17
            rgb[i * 3 + 2] = (p & 15) * 17
        return rgb

    def on_frame(self):
        a = self.a
        if a.frames_to and a.frame_every and self.frames % a.frame_every == 0:
            os.makedirs(a.frames_to, exist_ok=True)
            pngio.write(os.path.join(a.frames_to, 'f%05d.png' % self.frames), LCD_W, LCD_H, self.frame_rgb())

    # ---- running ----------------------------------------------------------------
    def fault(self, why):
        uc = self.uc
        r = [uc.reg_read(x) for x in REGS]
        print('FAULT: %s' % why)
        print('  ' + ' '.join('r%d=%08x' % (i, v) for i, v in enumerate(r[:8])))
        print('  ' + ' '.join('r%d=%08x' % (i + 8, v) for i, v in enumerate(r[8:13])) +
              ' sp=%08x lr=%08x pc=%08x cpsr=%08x' % (r[13], r[14], r[15], uc.reg_read(UC_ARM_REG_CPSR)))
        self.exit_code = 99
        uc.emu_stop()

    def run(self):
        uc = self.uc
        end = self.a.seconds * 1000000 * self.mips
        slice_insns = self.a.slice
        pc = self.pc
        t0 = time.time()
        while self.exit_code is None and self.insns < end:
            # deliver an interrupt if the line is up and the CPU will take it
            cpsr = uc.reg_read(UC_ARM_REG_CPSR)
            if self.irq_line() and not (cpsr & 0x80):
                uc.reg_write(UC_ARM_REG_PC, pc | ((cpsr >> 5) & 1))
                self.enter(0x18, 0x12, pc + 4)
                pc = 0x18
            if pc == self.idle_pc:
                n = self.next_event_insns() - self.insns
            else:
                n = min(slice_insns, self.next_event_insns() - self.insns)
            thumb = uc.reg_read(UC_ARM_REG_CPSR) & 0x20
            try:
                if pc == self.idle_pc:
                    pass
                else:
                    uc.emu_start(pc | (1 if thumb else 0), 0xFFFFFFFF, count=n)
            except UcError as e:
                self.fault(str(e))
                break
            self.slice_us = n / self.mips / 1e6
            self.insns += n
            pc = uc.reg_read(UC_ARM_REG_PC)
            self.update_devices()
        dt = time.time() - t0
        print('ran %.3f virtual s (%d insns) in %.1f host s; %d frames; exit %s' % (
            self.insns / self.mips / 1e6, self.insns, dt, self.frames, self.exit_code))
        return self.exit_code or 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--rom', required=True)
    ap.add_argument('--kernel', default=os.path.join(ROOT, 'build', 'kernel', 'kernel.elf'))
    ap.add_argument('--drive')
    ap.add_argument('--seconds', type=float, default=10)
    ap.add_argument('--mips', type=int, default=100)
    ap.add_argument('--slice', type=int, default=200000)
    ap.add_argument('--frames-to')
    ap.add_argument('--frame-every', type=int, default=0)
    a = ap.parse_args()
    m = Machine(a)
    sys.exit(m.run())


if __name__ == '__main__':
    main()
