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

A key script is a list of "SECONDS:KEYS" steps: at that virtual time the
pressed set becomes KEYS, names joined with '+' (up down left right a b x y
l r select start), or nothing for none.  "26:start 26.2: 30:a 30.2:" taps
start, then a.
"""
import argparse, array, bisect, ctypes, os, re, struct, sys, time

from unicorn import (Uc, UcError, UC_ARCH_ARM, UC_MODE_ARM, UC_HOOK_INTR,
                     UC_PROT_READ, UC_PROT_EXEC, UC_PROT_ALL, UC_HOOK_MEM_WRITE, UC_HOOK_MEM_READ, UC_HOOK_CODE,
                     UC_HOOK_BLOCK)
from unicorn.arm_const import *

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, 'tools'))
import pngio  # noqa: E402


def hw_constants():
    """The #defines of ngvm_hw.h, so this file cannot drift from the header.
    Values are C constant expressions over earlier ones; evaluated as Python."""
    out = {}
    for line in open(os.path.join(ROOT, 'sw', 'include', 'ngvm_hw.h')):
        m = re.match(r'#define\s+([A-Z_][A-Z0-9_]*)\s+(.*?)\s*(/\*.*)?$', line)
        if not m or not m.group(2):
            continue
        expr = re.sub(r'\b(0x[0-9A-Fa-f]+|\d+)u\b', r'\1', m.group(2))
        try:
            out[m.group(1)] = int(eval(expr, {'__builtins__': {}}, dict(out)))
        except Exception:
            pass
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
        self.runs = {}                 # first index of a mapped run -> its length
        self.run_starts = []           # sorted
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
        if args.brk:
            from romsyms import Syms
            self.romsyms = Syms(args.rom)
            self.brk_left = args.brk_count
            self.brk_r0 = None if args.brk_r0 is None else int(args.brk_r0, 16) & 0xFFFFFFFF
            for a in args.brk.split(','):
                a = int(a, 16) & ~1
                uc.hook_add(UC_HOOK_CODE, self.on_brk, begin=a, end=a)
        if args.watch:
            lo, hi = (int(x, 16) for x in args.watch.split(':'))
            self.watch_left = 3000
            uc.hook_add(UC_HOOK_MEM_READ, self.on_watch, begin=lo, end=hi)
            uc.hook_add(UC_HOOK_MEM_WRITE, self.on_watch_w, begin=lo, end=hi)

        # devices
        self.insns = 0                 # virtual time, in instructions
        self.irq_status = 0
        self.irq_enable = 0
        self.timer_cmp = None
        self.timer_hi_latch = 0
        self.lcd_base = 0
        self.lcd_ctrl = 0
        self.lcd_shown = None          # the framebuffer as IO_LCD_SHOW last copied it
        self.lcd_shows = 0
        self.lcd_stale = 0             # frames the framebuffer has differed from it
        self.lcd_stale_runs = []       # (virtual s, frames): those over 0.1 s
        self.frames = 0
        self.keys = 0
        self.key_steps = self.parse_keys(args.keys)
        self.audio = []                # samples (int16 L, int16 R)
        self.audio_rate = 8000
        self.audio_fifo = 0.0          # samples waiting, drained at audio_rate
        self.idle_at = []              # the kernel's idle_us, once a virtual second
        self.pc_hist = {}              # --profile: where slices end
        self.mt = None                 # --memtrace: (from, to, path), hooks, streams
        self.ram_peak = 0              # most distinct RAM pages mapped at once
        self.exit_code = None
        self.con = bytearray()
        self.slice_us = 0.0

        uc.reg_write(UC_ARM_REG_CPSR, 0xD3)
        self.pc = entry

    def rd32(self, a):
        return struct.unpack('<I', self.uc.mem_read(a, 4))[0]

    def kobj_name(self, o):
        """A kernel object's name (struct kobj: namelen at +2, UTF-16 name at +20)."""
        if not o:
            return '-'
        n = struct.unpack('<H', self.uc.mem_read(o + 2, 2))[0]
        return bytes(self.uc.mem_read(o + 20, 2 * min(n, 80))).decode('utf-16-le', 'replace')

    def on_brk(self, uc, addr, size, ud):
        """A breakpoint that only reports: registers, and the words on the
        stack that look like return addresses into the firmware."""
        if self.brk_left <= 0:
            return
        r = [uc.reg_read(x) for x in REGS]
        if self.brk_r0 is not None and r[0] != self.brk_r0:
            return
        self.brk_left -= 1
        print('[brk] %08x %s in %s at %.6f s' % (addr, self.romsyms.name(addr), self.kobj_name(self.rd32(self.syms['cur'])),
                                                self.insns / self.mips / 1e6))
        print('[brk]   r0=%08x r1=%08x r2=%08x r3=%08x lr=%08x %s' % (r[0], r[1], r[2], r[3], r[14], self.romsyms.name(r[14])))
        print('[brk]   ' + ' '.join('r%d=%08x' % (i, r[i]) for i in range(4, 13)) + ' sp=%08x' % r[13])
        for spec in (self.a.brk_mem or '').split(','):
            m = re.match(r'r(\d+)([+-]0x[0-9a-f]+|[+-]\d+)?:(\d+)$', spec.strip())
            if not m:
                continue
            a = (r[int(m.group(1))] + int(m.group(2) or '0', 0)) & 0xFFFFFFFF
            try:
                b = uc.mem_read(a, int(m.group(3)))
                print('[brk]   %s @%08x: %s' % (spec, a, ' '.join('%08x' % int.from_bytes(b[i:i + 4], 'little') for i in range(0, len(b) - 3, 4))))
            except Exception:
                print('[brk]   %s @%08x: unmapped' % (spec, a))
        sp, chain = r[13], []
        n = min(1024, NGVM_PAGE_SIZE - (sp & (NGVM_PAGE_SIZE - 1)))   # stay in the stack's page
        try:
            words = uc.mem_read(sp, n)
        except Exception:
            words = b''
        for i in range(0, len(words), 4):
            v = int.from_bytes(words[i:i + 4], 'little')
            if NGVM_ROM_BASE <= v < NGVM_ROM_BASE + 0x2000000 and len(chain) < 12:
                chain.append('%08x %s' % (v, self.romsyms.name(v)))
        for c in chain:
            print('[brk]     ' + c)

    def on_watch_w(self, uc, access, addr, size, value, ud):
        if self.watch_left > 0:
            self.watch_left -= 1
            pc = uc.reg_read(UC_ARM_REG_PC)
            print('[watch] pc %08x write %08x/%d = %x' % (pc, addr, size, value))

    def on_watch(self, uc, access, addr, size, value, ud):
        if self.watch_left > 0:
            self.watch_left -= 1
            v = int.from_bytes(uc.mem_read(addr, size), 'little')
            print('[watch] pc %08x read %08x/%d = %x' % (uc.reg_read(UC_ARM_REG_PC), addr, size, v))

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
        if off == IO_DBG_FLAGS:
            on = self.insns >= self.a.trace_from * self.mips * 1000000
            return self.a.trace if on else 0
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
            return AUDIO_FIFO_N
        if off == IO_DRIVE_SIZE:
            return self.drive_size
        if off == IO_ROM_SIZE:
            return self.rom_size
        return 0

    def io_write(self, uc, off, size, value, ud):
        try:
            self.io_write1(uc, off, size, value)
        except Exception as e:                 # Unicorn would hold it and skip later hooks
            import traceback
            traceback.print_exc()
            self.fault('in the IO write of %x = %x: %r' % (off, value, e))

    def io_write1(self, uc, off, size, value):
        if off == IO_DBG_PUTC:
            c = value & 0xFF
            if c == 10:
                line = self.con.decode('latin-1')
                if self.a.stamp:
                    line = '[%7.3f s] %s' % (self.now_us() / 1e6, line)
                print(line, flush=True)
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
        elif off == IO_LCD_SHOW:
            if self.lcd_base:
                self.lcd_shown = bytes(self.uc.mem_read(self.lcd_base, LCD_W * LCD_H * 2))
            self.lcd_shows += 1
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

    # Unicorn region per page would be simplest, but QEMU beneath it numbers
    # memory sections in the low bits of a TLB entry: past about a thousand
    # of them, accesses resolve to the wrong section (stores to the IO page
    # were lost, and a committed page read as unmapped).  So a run of table
    # entries that maps a run of RAM pages is one region.
    def run_at(self, i):
        k = bisect.bisect_right(self.run_starts, i) - 1
        if k >= 0:
            s = self.run_starts[k]
            if i < s + self.runs[s]:
                return s
        return None

    def pt_set(self, i, page):
        if i >= NGVM_PT_ENTRIES:
            return self.fault('page table index %d out of range' % i)
        if page != NGVM_PT_NONE and (page + 1) << NGVM_PAGE_SHIFT > NGVM_RAM_SIZE:
            return self.fault('page table entry %d -> RAM page %x beyond RAM' % (i, page))
        if self.pt.get(i, NGVM_PT_NONE) == page:
            return
        lo = hi = i
        for j in (i - 1, i, i + 1):            # the runs this entry can split or join
            s = self.run_at(j)
            if s is not None:
                n = self.runs.pop(s)
                self.run_starts.remove(s)
                self.uc.mem_unmap(self.pt_virt(s), n << NGVM_PAGE_SHIFT)
                lo, hi = min(lo, s), max(hi, s + n - 1)
        if page == NGVM_PT_NONE:
            self.pt.pop(i, None)
        else:
            self.pt[i] = page
        k = lo
        while k <= hi:
            if k not in self.pt:
                k += 1
                continue
            s = k
            while k + 1 <= hi and k + 1 != NGVM_PT_CHUNK and self.pt.get(k + 1) == self.pt[k] + 1:
                k += 1
            n = k - s + 1
            self.uc.mem_map_ptr(self.pt_virt(s), n << NGVM_PAGE_SHIFT, UC_PROT_ALL,
                                self.ram_addr + (self.pt[s] << NGVM_PAGE_SHIFT))
            self.runs[s] = n
            bisect.insort(self.run_starts, s)
            k += 1

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
        if self.audio_fifo <= AUDIO_FIFO_N // 2:
            self.irq_status |= IRQ_AUDIO

    def next_event_insns(self):
        """Instructions until something can raise an interrupt."""
        cands = [(self.frames + 1) * self.frame_period_insns()]
        if self.timer_cmp is not None:
            cands.append(((self.timer_cmp - (self.now_us() & 0xFFFFFFFF)) & 0xFFFFFFFF) * self.mips + self.insns)
        return max(min(cands), self.insns + 1)

    # ---- the LCD --------------------------------------------------------------
    def frame_rgb(self):
        """What the LCD shows: the framebuffer as IO_LCD_SHOW last copied it."""
        raw = self.lcd_shown or bytes(LCD_W * LCD_H * 2)
        rgb = bytearray(LCD_W * LCD_H * 3)
        for i, (p,) in enumerate(struct.iter_unpack('<H', raw)):
            rgb[i * 3] = ((p >> 8) & 15) * 17
            rgb[i * 3 + 1] = ((p >> 4) & 15) * 17
            rgb[i * 3 + 2] = (p & 15) * 17
        return rgb

    KEY_NAMES = ('up', 'down', 'left', 'right', 'a', 'b', 'x', 'y', 'l', 'r', 'select', 'start')

    @classmethod
    def parse_keys(cls, script):
        steps = []
        for step in (script or '').split():
            t, _, names = step.partition(':')
            mask = 0
            for n in filter(None, names.lower().split('+')):
                mask |= 1 << cls.KEY_NAMES.index(n)
            steps.append((float(t), mask))
        return sorted(steps)

    def on_frame(self):
        a = self.a
        if self.frames % 30 == 0:
            self.ram_peak = max(self.ram_peak, len(set(self.pt.values())))
        if self.frames % 60 == 0:
            rd = lambda name, n: struct.unpack('<Q' if n == 8 else '<I', self.uc.mem_read(self.syms[name], n))[0]
            idle = rd('idle_us', 8)
            if rd('cur', 4) == rd('idle_thread', 4):    # an idle stretch still running
                idle += self.now_us() - rd('idle_since', 8)
            self.idle_at.append(idle)
        now = self.insns / self.mips / 1e6
        while self.key_steps and self.key_steps[0][0] <= now:
            self.keys = self.key_steps.pop(0)[1]
        # a picture drawn and never shown: a program that expects the LCD to
        # read the framebuffer by itself, which this one does not
        if self.lcd_base and self.lcd_ctrl & 1:
            live = bytes(self.uc.mem_read(self.lcd_base, LCD_W * LCD_H * 2))
            if live != self.lcd_shown:
                self.lcd_stale += 1
            else:
                if self.lcd_stale > 6:
                    self.lcd_stale_runs.append((now - self.lcd_stale / 60, self.lcd_stale))
                self.lcd_stale = 0
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
        if self.a.fault_va:                    # what the page table says about an address
            va = int(self.a.fault_va, 16)
            i = (va - NGVM_CHUNK_BASE) >> NGVM_PAGE_SHIFT
            print('  %08x: pt[%d] = %s; %d pages mapped in %d regions' % (va, i, self.pt.get(i), len(self.pt), len(self.runs)))
            near = sorted(k for k in self.pt if abs(k - i) < 600)
            print('  mapped near it: %s' % (near and '%d..%d (%d)' % (near[0], near[-1], len(near))))
        try:                                   # the stack, raw: return addresses into RAM code too
            words = uc.mem_read(r[13], min(256, NGVM_PAGE_SIZE - (r[13] & (NGVM_PAGE_SIZE - 1))))
            for i in range(0, len(words) - 31, 32):
                print('  sp+%03x: %s' % (i, ' '.join('%08x' % int.from_bytes(words[j:j + 4], 'little') for j in range(i, i + 32, 4))))
        except Exception:
            pass
        self.exit_code = 99
        uc.emu_stop()

    def write_wav(self, path):
        """What the audio FIFO was given, as 16-bit stereo at its last rate."""
        import wave
        with wave.open(path, 'wb') as w:
            w.setnchannels(2)
            w.setsampwidth(2)
            w.setframerate(self.audio_rate)
            w.writeframes(struct.pack('<%dI' % len(self.audio), *self.audio))
        print('audio: %d samples at %d Hz to %s' % (len(self.audio), self.audio_rate, path))

    def report_load(self):
        """What the run asked of the machine: CPU MIPS outside the idle thread
        each virtual second (from the kernel's idle_us, so as fine as --slice),
        and the most RAM pages mapped at once."""
        idle = self.idle_at
        mips = [self.mips * (1 - (b - a) / 1e6) for a, b in zip(idle, idle[1:])]
        if mips:
            print('load: busy MIPS per second: ' + ' '.join('%.0f' % m for m in mips))
            print('load: mean %.1f, max %.1f MIPS of %d; RAM peak %d pages (%.1f MB)' % (
                sum(mips) / len(mips), max(mips), self.mips, self.ram_peak,
                self.ram_peak * NGVM_PAGE_SIZE / 1048576))

    def report_profile(self):
        """--profile: the commonest places slices ended, named from the ROM."""
        from romsyms import Syms
        syms = Syms(self.a.rom)
        total = sum(self.pc_hist.values()) or 1
        by_name = {}
        for pc, k in self.pc_hist.items():
            if NGVM_ROM_BASE <= pc < NGVM_ROM_BASE + NGVM_ROM_MAX:
                name = syms.name(pc)
                name = re.sub(r'\+0x[0-9a-f]+$', '', name)
            elif pc < NGVM_KERN_SIZE:
                below = [(a, n) for n, a in self.syms.items() if a <= pc]
                name = 'kernel!' + (max(below)[1] if below else '?')
            else:
                name = 'RAM %08x' % (pc & ~0xFFF)
            by_name[name] = by_name.get(name, 0) + k
        for name, k in sorted(by_name.items(), key=lambda x: -x[1])[:25]:
            print('profile: %5.1f%%  %s' % (100.0 * k / total, name))

    # --memtrace FROM:SECONDS:FILE: every instruction fetch (as basic blocks)
    # and every data access over that window of virtual time, for a cache
    # model (tools/ngvm/cachesim.py).  FILE gets a header line, then the
    # blocks as (addr, bytes) u32 pairs, then the data accesses as u32
    # (addr & ~1) | write -- byte addresses, so bit 0 is free only because
    # the model works in lines; the access size is not kept.
    def memtrace_step(self):
        mt, uc = self.mt, self.uc
        if mt['hooks'] is None and self.insns >= mt['from']:
            mt['blocks'], mt['data'], mt['insns0'] = array.array('I'), array.array('I'), self.insns
            b, d = mt['blocks'], mt['data']
            mt['hooks'] = [
                uc.hook_add(UC_HOOK_BLOCK, lambda u, a, n, _: b.extend((a, n))),
                uc.hook_add(UC_HOOK_MEM_READ, lambda u, t, a, n, v, _: d.append(a & ~1)),
                uc.hook_add(UC_HOOK_MEM_WRITE, lambda u, t, a, n, v, _: d.append((a & ~1) | 1)),
            ]
            # hooks are compiled into translated code: what was translated
            # before them would run unseen
            uc.ctl_flush_tb()
        elif mt['hooks'] and self.insns >= mt['to']:
            for h in mt['hooks']:
                uc.hook_del(h)
            with open(mt['path'], 'wb') as f:
                f.write(b'NGVMTRACE insns=%d blocks=%d data=%d\n' % (
                    self.insns - mt['insns0'], len(mt['blocks']) // 2, len(mt['data'])))
                mt['blocks'].tofile(f)
                mt['data'].tofile(f)
            print('[memtrace] %d insns, %d blocks, %d data accesses -> %s' % (
                self.insns - mt['insns0'], len(mt['blocks']) // 2, len(mt['data']), mt['path']))
            self.mt = None

    def run(self):
        uc = self.uc
        end = self.a.seconds * 1000000 * self.mips
        slice_insns = self.a.slice
        pc = self.pc
        t0 = time.time()
        if self.a.memtrace:
            f, d, path = self.a.memtrace.split(':')
            self.mt = {'from': float(f) * 1e6 * self.mips, 'to': (float(f) + float(d)) * 1e6 * self.mips,
                       'path': path, 'hooks': None}
        while self.exit_code is None and self.insns < end:
            if self.mt:
                self.memtrace_step()
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
            if self.a.profile and pc != self.idle_pc:
                self.pc_hist[pc & ~1] = self.pc_hist.get(pc & ~1, 0) + 1
            self.update_devices()
        dt = time.time() - t0
        self.report_load()
        runs = self.lcd_stale_runs + ([(self.insns / self.mips / 1e6 - self.lcd_stale / 60, self.lcd_stale)]
                                      if self.lcd_stale > 6 else [])
        print('lcd: %d updates; the framebuffer differed from the picture shown for over 0.1 s %d times%s' % (
            self.lcd_shows, len(runs),
            ''.join(', %d frames from %.2f s' % (n, t) for t, n in sorted(runs, key=lambda r: -r[1])[:5])))
        if self.a.profile:
            self.report_profile()
        if self.a.wav:
            self.write_wav(self.a.wav)
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
    ap.add_argument('--trace', type=lambda x: int(x, 0), default=0, help='DBGF_* bits for the kernel')
    ap.add_argument('--trace-from', type=float, default=0, help='trace only from this virtual second')
    ap.add_argument('--watch', help='lo:hi (hex): log reads of this range')
    ap.add_argument('--brk', help='addr[,addr] (hex): report registers and stack when reached')
    ap.add_argument('--brk-count', type=int, default=20, help='reports at most this many')
    ap.add_argument('--brk-r0', help='(hex) report only when r0 is this')
    ap.add_argument('--brk-mem', help='rN+off:len[,...]: words to dump at each report')
    ap.add_argument('--fault-va', help='(hex) at a fault, report the page table around this address')
    ap.add_argument('--frames-to')
    ap.add_argument('--frame-every', type=int, default=0)
    ap.add_argument('--profile', action='store_true', help='sample where the CPU spends its time')
    ap.add_argument('--wav', help='write what the audio FIFO was given to this WAV file')
    ap.add_argument('--stamp', action='store_true',
                    help="prefix each line the kernel prints with virtual time, as sim/run_system.sh does")
    ap.add_argument('--memtrace', help='FROM:SECONDS:FILE: record fetches and data accesses for a cache model')
    ap.add_argument('--keys', help='key script: "SECONDS:KEY[+KEY] ..." (see above)')
    a = ap.parse_args()
    m = Machine(a)
    sys.exit(m.run())


if __name__ == '__main__':
    main()
