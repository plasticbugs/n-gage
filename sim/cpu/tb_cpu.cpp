// The CPU in lockstep with Unicorn (docs/core-design.md section 6).
//
// The RTL (rtl/arm_cpu.sv) runs on NGVM's memory map with ideal memories:
// every fetch hits, every data access completes in the next cycle.  Unicorn,
// the engine of tools/ngvm/ngvm.py, runs the same kernel and firmware from its
// own copy of every memory.  Each time the RTL retires an instruction,
// Unicorn executes one, and the bench compares r0-r14 of the current mode,
// the CPSR and the next PC.  The first difference stops the run with both
// states and the last instructions retired.
//
// Device timing is the RTL's: the bench's devices answer the RTL, and each
// value the RTL reads from a device is replayed to Unicorn's read of it.  When
// the RTL takes an IRQ, Unicorn is made to enter the same exception at the
// same instruction, as ngvm.py does.  Virtual time is instructions retired
// over --mips, as in ngvm.py, and the idle loop skips to the next event.
//
//   obj_cpu/Varm_cpu --rom SYM.ROM --kernel build/kernel/kernel.elf
//                    [--drive game.img] [--insns N] [--mips 100] [--no-uc]
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <string>
#include <vector>
#include <deque>
#include <map>
#include <chrono>
#include <unicorn/unicorn.h>
#include "Varm_cpu.h"
#include "Varm_cpu___024root.h"
#include "Varm_cpu_arm_cpu.h"
#include "Varm_cpu_arm_regs.h"
#include "verilated.h"

#include "../../sw/include/ngvm_hw.h"
#include "bpred.h"

static const uint32_t ROM_MAP_ALIGN = 0x10000;

// ------------------------------------------------------------ files
static std::vector<uint8_t> slurp(const char *path)
{
    FILE *f = fopen(path, "rb");
    if (!f) { perror(path); exit(2); }
    std::vector<uint8_t> d;
    uint8_t buf[65536];
    size_t n;
    while ((n = fread(buf, 1, sizeof buf, f)) > 0) d.insert(d.end(), buf, buf + n);
    fclose(f);
    return d;
}

struct Seg { uint32_t addr; std::vector<uint8_t> data; };

static uint32_t rd32(const std::vector<uint8_t> &d, size_t o) { return d[o] | d[o+1] << 8 | d[o+2] << 16 | (uint32_t)d[o+3] << 24; }
static uint16_t rd16(const std::vector<uint8_t> &d, size_t o) { return d[o] | d[o+1] << 8; }

static void load_elf(const char *path, std::vector<Seg> &segs, std::map<std::string, uint32_t> &syms)
{
    auto d = slurp(path);
    uint32_t phoff = rd32(d, 0x1C), shoff = rd32(d, 0x20);
    uint16_t phentsize = rd16(d, 0x2A), phnum = rd16(d, 0x2C);
    uint16_t shentsize = rd16(d, 0x2E), shnum = rd16(d, 0x30);
    for (int i = 0; i < phnum; i++) {
        size_t p = phoff + i * phentsize;
        uint32_t typ = rd32(d, p), off = rd32(d, p + 4), paddr = rd32(d, p + 12), filesz = rd32(d, p + 16);
        if (typ == 1 && filesz) segs.push_back({paddr, std::vector<uint8_t>(d.begin() + off, d.begin() + off + filesz)});
    }
    for (int i = 0; i < shnum; i++) {
        size_t s = shoff + i * shentsize;
        if (rd32(d, s + 4) != 2) continue;                       // SYMTAB
        uint32_t off = rd32(d, s + 16), size = rd32(d, s + 20), link = rd32(d, s + 24);
        uint32_t stroff = rd32(d, shoff + link * shentsize + 16);
        for (uint32_t j = 0; j < size / 16; j++) {
            uint32_t name = rd32(d, off + j * 16), value = rd32(d, off + j * 16 + 4);
            std::string n((const char *)&d[stroff + name]);
            if (!n.empty()) syms[n] = value;
        }
    }
}

// ------------------------------------------------------------ one NGVM memory
// Both sides keep one of these: the RTL's is read through translate(),
// Unicorn's is mapped into Unicorn.
struct Mem {
    std::vector<uint8_t> ram, ksec, rom, drive;
    uint16_t pt[NGVM_PT_ENTRIES];
    Mem() : ram(NGVM_RAM_SIZE), ksec(NGVM_KSEC_SIZE), drive(NGVM_DRIVE_MAX) {
        for (auto &e : pt) e = NGVM_PT_NONE;
    }
    // host pointer for a virtual address, or null (an abort)
    uint8_t *translate(uint32_t va, bool write) {
        if (va < NGVM_KERN_SIZE) return &ram[va];
        if (va - NGVM_DATA_BASE < NGVM_DATA_SIZE) {
            uint16_t p = pt[NGVM_PT_CHUNK + ((va - NGVM_DATA_BASE) >> NGVM_PAGE_SHIFT)];
            return p == NGVM_PT_NONE ? nullptr : &ram[((uint32_t)p << NGVM_PAGE_SHIFT) | (va & (NGVM_PAGE_SIZE - 1))];
        }
        if (va - NGVM_PHYS_BASE < NGVM_RAM_SIZE) return &ram[va - NGVM_PHYS_BASE];
        if (va - NGVM_CHUNK_BASE < NGVM_CHUNK_SIZE) {
            uint16_t p = pt[(va - NGVM_CHUNK_BASE) >> NGVM_PAGE_SHIFT];
            return p == NGVM_PT_NONE ? nullptr : &ram[((uint32_t)p << NGVM_PAGE_SHIFT) | (va & (NGVM_PAGE_SIZE - 1))];
        }
        if (va - NGVM_ROM_BASE < rom.size()) return write ? nullptr : &rom[va - NGVM_ROM_BASE];
        if (va - NGVM_DRIVE_BASE < NGVM_DRIVE_MAX) return &drive[va - NGVM_DRIVE_BASE];
        if (va - NGVM_KSEC_BASE < NGVM_KSEC_SIZE) return &ksec[va - NGVM_KSEC_BASE];
        return nullptr;
    }
};

// ------------------------------------------------------------ the machine
struct Bench {
    Varm_cpu *top;
    Mem rtl, ucm;
    uc_engine *uc = nullptr;
    bool use_uc = true;
    uint32_t mips = 100;
    uint64_t insns = 0, cycles = 0, max_insns = 0;   // insns: virtual time, in instructions (idle skips included)
    uint64_t retired = 0, idle_cycles = 0;            // instructions executed; cycles spent on the idle loop
    uint32_t idle_pc = 0;
    uint64_t idle_retired = 0;
    BPred bp;

    // where the cycles go: tallied each cycle, charged to the busy or the
    // idle side when the next instruction retires
    enum { P_RETIRE, P_UOP, P_EMPTY, P_LDWAIT, P_MUL, P_MHOLD,
           P_DRED, P_ERED_BR, P_ERED_BX, P_ERED_ALU, P_ERED_EXC, P_ERED_OTHER, P_MRED, P_N };
    uint64_t prof_pend[P_N] = {}, prof_busy[P_N] = {};
    static uint32_t ebits(const VlWide<11> &w, int lsb, int n) {
        uint64_t v = w[lsb / 32] | (lsb / 32 + 1 < 11 ? (uint64_t)w[lsb / 32 + 1] << 32 : 0);
        return (uint32_t)(v >> (lsb % 32)) & ((1u << n) - 1);
    }
    void profile() {
        auto *c = top->rootp->arm_cpu;
        if (top->rt_valid && !top->rt_irq) prof_pend[P_RETIRE]++;
        if (c->d_issue && !c->d_last) prof_pend[P_UOP]++;
        if (!c->e_valid) prof_pend[P_EMPTY]++;
        if (c->e_ldwait) prof_pend[P_LDWAIT]++;
        else if (c->e_busy) prof_pend[P_MUL]++;
        if (c->m_hold) prof_pend[P_MHOLD]++;
        if (c->m_redirect) prof_pend[P_MRED]++;
        else if (c->e_redirect) {
            switch (ebits(c->e_u, 267, 4)) {     // uop_t.kind
            case 7:  prof_pend[P_ERED_BR]++; break;   // K_BRANCH
            case 8:  prof_pend[P_ERED_BX]++; break;   // K_BX
            case 1:  prof_pend[P_ERED_ALU]++; break;  // K_ALU
            case 11: prof_pend[P_ERED_EXC]++; break;  // K_EXC
            default: prof_pend[P_ERED_OTHER]++; break;
            }
        } else if (c->d_redirect) prof_pend[P_DRED]++;
    }
    void charge(bool idle) {
        if (!idle) for (int i = 0; i < P_N; i++) prof_busy[i] += prof_pend[i];
        memset(prof_pend, 0, sizeof prof_pend);
    }
    void print_profile(uint64_t busy) {
        static const char *name[P_N] = {
            "instructions retired", "extra uops (LDM/STM, SWP, long multiply)", "E empty",
            "E waits on a load", "E waits on the multiplier", "M waits on memory",
            "D redirects (B, BL)", "E redirects: conditional B", "E redirects: BX",
            "E redirects: ALU to PC", "E redirects: exceptions", "E redirects: other", "M redirects (load to PC)" };
        printf("busy cycles %llu, by what each cycle saw (they overlap; redirects are events):\n",
               (unsigned long long)busy);
        for (int i = 0; i < P_N; i++)
            printf("  %-42s %12llu  %6.3f per instruction\n", name[i], (unsigned long long)prof_busy[i],
                   prof_busy[P_RETIRE] ? (double)prof_busy[i] / prof_busy[P_RETIRE] : 0.0);
    }
    size_t rom_size = 0, drive_size = 0;

    // devices (the RTL's)
    uint32_t irq_status = 0, irq_enable = 0, lcd_base = 0, lcd_ctrl = 0, keys = 0;
    uint32_t audio_rate = 8000, pt_index = 0, timer_hi_latch = 0;
    bool timer_armed = false;
    uint32_t timer_cmp = 0;
    uint64_t frames = 0;
    double audio_fifo = 0;
    std::string con;
    int exit_code = -1;

    // device reads the RTL made, for Unicorn to replay
    std::deque<std::pair<uint32_t, uint32_t>> io_reads;
    // Unicorn's own page-table writes
    uint32_t uc_pt_index = 0;
    std::map<uint32_t, uint32_t> runs;          // first entry of a mapped run -> length

    // data port
    bool dc_pend = false;
    uint32_t dc_q = 0;
    bool dc_abt = false;

    // retirement history, for reports
    struct Ret { uint32_t pc, instr, cpsr; bool thumb, irq; };
    std::deque<Ret> hist;
    uint32_t uc_next_pc = 0;
    bool have_next = false;
    uint64_t mismatches = 0;
    bool failed = false;
    uint64_t last_retire_cycle = 0;
    bool bl_merged = false;                     // Unicorn ran a BL pair whose suffix the RTL has not retired
    uint32_t bl_after = 0;

    uint64_t now_us() const { return insns / mips; }
    uint64_t frame_period() const { return (uint64_t)mips * 1000000 / 60; }

    void update_devices() {
        uint64_t t = now_us();
        if (timer_armed && (uint32_t)((uint32_t)t - timer_cmp) < 0x80000000u) {
            irq_status |= IRQ_TIMER;
            timer_armed = false;
        }
        uint64_t f = insns / frame_period();
        while (frames < f) { frames++; irq_status |= IRQ_VBLANK; }
    }

    uint64_t next_event_insns() const {
        uint64_t n = (frames + 1) * frame_period();
        if (timer_armed) {
            uint64_t d = (uint32_t)(timer_cmp - (uint32_t)now_us());
            n = std::min(n, d * mips + insns);
        }
        return std::max(n, insns + 1);
    }

    uint32_t io_read(uint32_t off) {
        switch (off) {
        case IO_TIMER_US: { uint64_t t = now_us(); timer_hi_latch = t >> 32; return (uint32_t)t; }
        case IO_TIMER_US_HI: return timer_hi_latch;
        case IO_IRQ_STATUS: return irq_status;
        case IO_IRQ_ENABLE: return irq_enable;
        case IO_DBG_FLAGS: return 0;
        case IO_LCD_BASE: return lcd_base;
        case IO_LCD_CTRL: return lcd_ctrl;
        case IO_LCD_FRAME: return (uint32_t)frames;
        case IO_KEYS: return keys;
        case IO_AUDIO_LEVEL: return (uint32_t)audio_fifo;
        case IO_AUDIO_RATE: return audio_rate;
        case IO_AUDIO_SIZE: return 4096;
        case IO_DRIVE_SIZE: return (uint32_t)drive_size;
        case IO_ROM_SIZE: return (uint32_t)rom_size;
        default: return 0;
        }
    }

    void io_write(uint32_t off, uint32_t v) {
        switch (off) {
        case IO_DBG_PUTC:
            if ((v & 0xFF) == 10) { printf("%s\n", con.c_str()); fflush(stdout); con.clear(); }
            else con.push_back((char)(v & 0xFF));
            break;
        case IO_DBG_HEX: printf("[hex] %08x\n", v); break;
        case IO_DBG_EXIT: if (!con.empty()) printf("%s\n", con.c_str()); exit_code = (int)v; break;
        case IO_TIMER_CMP: timer_cmp = v; timer_armed = true; break;
        case IO_IRQ_STATUS: irq_status &= ~v; break;
        case IO_IRQ_ENABLE: irq_enable = v; break;
        case IO_LCD_BASE: lcd_base = v; break;
        case IO_LCD_CTRL: lcd_ctrl = v; break;
        case IO_AUDIO_DATA: audio_fifo += 1; break;
        case IO_AUDIO_RATE: audio_rate = v ? v : 8000; break;
        case IO_PT_INDEX: pt_index = v; break;
        case IO_PT_DATA:
            if (pt_index < NGVM_PT_ENTRIES) rtl.pt[pt_index] = (uint16_t)v;
            break;
        default: break;
        }
    }

    // ---------------------------------------------------- Unicorn's side
    static uint32_t pt_virt(uint32_t i) {
        return i < NGVM_PT_CHUNK ? NGVM_CHUNK_BASE + (i << NGVM_PAGE_SHIFT)
                                 : NGVM_DATA_BASE + ((i - NGVM_PT_CHUNK) << NGVM_PAGE_SHIFT);
    }
    // ngvm.py's runs: a run of entries mapping a run of RAM pages is one
    // Unicorn region (QEMU misbehaves past about a thousand regions)
    int64_t run_at(uint32_t i) {
        auto it = runs.upper_bound(i);
        if (it == runs.begin()) return -1;
        --it;
        return i < it->first + it->second ? (int64_t)it->first : -1;
    }
    void uc_pt_set(uint32_t i, uint32_t page) {
        if (i >= NGVM_PT_ENTRIES) return;
        if (ucm.pt[i] == page) return;
        uint32_t lo = i, hi = i;
        for (int64_t j = (int64_t)i - 1; j <= (int64_t)i + 1; j++) {
            if (j < 0) continue;
            int64_t s = run_at((uint32_t)j);
            if (s >= 0) {
                uint32_t n = runs[(uint32_t)s];
                runs.erase((uint32_t)s);
                uc_mem_unmap(uc, pt_virt((uint32_t)s), (size_t)n << NGVM_PAGE_SHIFT);
                lo = std::min(lo, (uint32_t)s);
                hi = std::max(hi, (uint32_t)s + n - 1);
            }
        }
        ucm.pt[i] = (uint16_t)page;
        for (uint32_t k = lo; k <= hi; k++) {
            if (ucm.pt[k] == NGVM_PT_NONE) continue;
            uint32_t s = k;
            while (k + 1 <= hi && k + 1 != NGVM_PT_CHUNK && ucm.pt[k + 1] == ucm.pt[k] + 1) k++;
            uint32_t n = k - s + 1;
            uc_err e = uc_mem_map_ptr(uc, pt_virt(s), (size_t)n << NGVM_PAGE_SHIFT, UC_PROT_ALL,
                                      &ucm.ram[(size_t)ucm.pt[s] << NGVM_PAGE_SHIFT]);
            if (e) { fprintf(stderr, "uc_mem_map_ptr %08x: %s\n", pt_virt(s), uc_strerror(e)); exit(3); }
            runs[s] = n;
        }
    }

    static uint64_t uc_io_read(uc_engine *, uint64_t off, unsigned, void *ud) {
        Bench *b = (Bench *)ud;
        if (b->io_reads.empty()) {
            fprintf(stderr, "Unicorn read IO %03x that the RTL did not\n", (unsigned)off);
            b->mismatches++;
            return 0;
        }
        auto r = b->io_reads.front();
        b->io_reads.pop_front();
        if (r.first != off) {
            fprintf(stderr, "Unicorn read IO %03x where the RTL read %03x\n", (unsigned)off, r.first);
            b->mismatches++;
        }
        return r.second;
    }
    static void uc_io_write(uc_engine *, uint64_t off, unsigned, uint64_t v, void *ud) {
        Bench *b = (Bench *)ud;
        if (off == IO_PT_INDEX) b->uc_pt_index = (uint32_t)v;
        else if (off == IO_PT_DATA) b->uc_pt_set(b->uc_pt_index, (uint32_t)v);
    }
    void uc_enter(uint32_t vector, uint32_t mode, uint32_t ret) {
        uint32_t cpsr;
        uc_reg_read(uc, UC_ARM_REG_CPSR, &cpsr);
        uint32_t n = (cpsr & ~0x3Fu) | 0x80 | mode;
        uc_reg_write(uc, UC_ARM_REG_CPSR, &n);
        uc_reg_write(uc, UC_ARM_REG_SPSR, &cpsr);
        uc_reg_write(uc, UC_ARM_REG_LR, &ret);
        uc_reg_write(uc, UC_ARM_REG_PC, &vector);
    }
    static void uc_intr(uc_engine *u, uint32_t intno, void *ud) {
        Bench *b = (Bench *)ud;
        if (intno == 2) {
            uint32_t pc;
            uc_reg_read(u, UC_ARM_REG_PC, &pc);
            b->uc_enter(0x08, 0x13, pc);
        } else {
            fprintf(stderr, "Unicorn: CPU exception %u\n", intno);
            b->mismatches++;
            uc_emu_stop(u);
        }
    }

    void uc_init(const std::vector<Seg> &segs) {
        uc_err e = uc_open(UC_ARCH_ARM, UC_MODE_ARM, &uc);
        if (e) { fprintf(stderr, "uc_open: %s\n", uc_strerror(e)); exit(3); }
        uc_ctl_set_cpu_model(uc, UC_CPU_ARM_TI925T);
        uc_mem_map_ptr(uc, NGVM_PHYS_BASE, NGVM_RAM_SIZE, UC_PROT_ALL, ucm.ram.data());
        uc_mem_map_ptr(uc, NGVM_KERN_BASE, NGVM_KERN_SIZE, UC_PROT_ALL, ucm.ram.data());
        uc_mem_map_ptr(uc, NGVM_KSEC_BASE, NGVM_KSEC_SIZE, UC_PROT_ALL, ucm.ksec.data());
        ucm.rom.resize((rom_size + ROM_MAP_ALIGN - 1) & ~(size_t)(ROM_MAP_ALIGN - 1));
        uc_mem_map_ptr(uc, NGVM_ROM_BASE, ucm.rom.size(), UC_PROT_READ | UC_PROT_EXEC, ucm.rom.data());
        uc_mem_map_ptr(uc, NGVM_DRIVE_BASE, NGVM_DRIVE_MAX, UC_PROT_ALL, ucm.drive.data());
        uc_mmio_map(uc, NGVM_IO_BASE, 0x1000, uc_io_read, this, uc_io_write, this);
        uc_hook h;
        uc_hook_add(uc, &h, UC_HOOK_INTR, (void *)uc_intr, this, 1, 0);
        uint32_t cpsr = 0xD3;                   // the RTL's reset state (QEMU's sets Z and A)
        uc_reg_write(uc, UC_ARM_REG_CPSR, &cpsr);
        (void)segs;
    }

    // ---------------------------------------------------- comparison
    uint32_t rtl_reg(int r, uint32_t mode) {
        auto &rf = top->rootp->arm_cpu->u_regs->r;
        int p = r;
        if (r >= 8 && r <= 14) {
            if (mode == 0x11) p = 16 + r - 8;
            else if (r >= 13) {
                switch (mode) {
                case 0x13: p = r == 13 ? 23 : 24; break;
                case 0x17: p = r == 13 ? 25 : 26; break;
                case 0x12: p = r == 13 ? 27 : 28; break;
                case 0x1B: p = r == 13 ? 29 : 30; break;
                default: break;
                }
            }
        }
        return rf[p];
    }

    void report(const char *why) {
        fprintf(stderr, "\n*** %s after %llu instructions (%llu cycles)\n", why,
                (unsigned long long)insns, (unsigned long long)cycles);
        fprintf(stderr, "last retired:\n");
        for (auto &r : hist)
            fprintf(stderr, "  %08x %s %0*x  cpsr %08x%s\n", r.pc, r.thumb ? "T" : "A",
                    r.thumb ? 4 : 8, r.instr, r.cpsr, r.irq ? "  (IRQ entry)" : "");
        if (!hist.empty() && use_uc) {
            uint32_t mode = hist.back().cpsr & 0x1F;
            fprintf(stderr, "reg   RTL       Unicorn\n");
            static const int ucr[15] = {UC_ARM_REG_R0, UC_ARM_REG_R1, UC_ARM_REG_R2, UC_ARM_REG_R3,
                UC_ARM_REG_R4, UC_ARM_REG_R5, UC_ARM_REG_R6, UC_ARM_REG_R7, UC_ARM_REG_R8,
                UC_ARM_REG_R9, UC_ARM_REG_R10, UC_ARM_REG_R11, UC_ARM_REG_R12, UC_ARM_REG_R13, UC_ARM_REG_R14};
            for (int i = 0; i < 15; i++) {
                uint32_t u;
                uc_reg_read(uc, ucr[i], &u);
                uint32_t r = rtl_reg(i, mode);
                fprintf(stderr, "r%-3d  %08x  %08x%s\n", i, r, u, r != u ? "  <--" : "");
            }
            uint32_t ucpsr, upc;
            uc_reg_read(uc, UC_ARM_REG_CPSR, &ucpsr);
            uc_reg_read(uc, UC_ARM_REG_PC, &upc);
            fprintf(stderr, "cpsr  %08x  %08x%s\n", hist.back().cpsr, ucpsr, hist.back().cpsr != ucpsr ? "  <--" : "");
            fprintf(stderr, "next pc (Unicorn) %08x\n", upc);
        }
    }

    // the instruction (or IRQ entry) that has just written its registers
    bool retire(const Ret &r) {
        hist.push_back(r);
        if (hist.size() > 24) hist.pop_front();
        if (!r.irq) { insns++; retired++; }
        bp.retire(r.pc, r.instr, r.thumb, r.irq);
        if (!use_uc) return true;
        if (have_next && r.pc != uc_next_pc) {
            report("PC differs");
            fprintf(stderr, "RTL retired %08x where Unicorn is at %08x\n", r.pc, uc_next_pc);
            return false;
        }
        // QEMU runs a Thumb BL prefix and its suffix as one instruction when
        // both are on one 1 KB page, else as two.  Step Unicorn on the prefix
        // and see which it did; if it ran both, the suffix is not stepped.
        if (bl_merged) {
            bl_merged = false;
            if (!(r.thumb && (r.instr & 0xF800) == 0xF800)) { report("BL pair split"); return false; }
        } else if (r.irq) {
            uc_enter(0x18, 0x12, r.pc + 4);
        } else {
            uint32_t cpsr;
            uc_reg_read(uc, UC_ARM_REG_CPSR, &cpsr);
            uc_err e = uc_emu_start(uc, r.pc | ((cpsr >> 5) & 1), 0xFFFFFFFF, 0, 1);
            if (e) {
                report("Unicorn stopped");
                fprintf(stderr, "uc_emu_start: %s\n", uc_strerror(e));
                return false;
            }
        }
        uc_reg_read(uc, UC_ARM_REG_PC, &uc_next_pc);
        have_next = true;
        if (r.thumb && !r.irq && (r.instr & 0xF800) == 0xF000 && uc_next_pc != r.pc + 2) {
            bl_merged = true;               // Unicorn is past the suffix: wait for it
            bl_after = uc_next_pc;
            uc_next_pc = r.pc + 2;
            return true;
        }
        // compare
        uint32_t mode = r.cpsr & 0x1F, ucpsr;
        uc_reg_read(uc, UC_ARM_REG_CPSR, &ucpsr);
        bool bad = ucpsr != r.cpsr || mismatches;
        static const int ucr[15] = {UC_ARM_REG_R0, UC_ARM_REG_R1, UC_ARM_REG_R2, UC_ARM_REG_R3,
            UC_ARM_REG_R4, UC_ARM_REG_R5, UC_ARM_REG_R6, UC_ARM_REG_R7, UC_ARM_REG_R8,
            UC_ARM_REG_R9, UC_ARM_REG_R10, UC_ARM_REG_R11, UC_ARM_REG_R12, UC_ARM_REG_R13, UC_ARM_REG_R14};
        for (int i = 0; i < 15 && !bad; i++) {
            uint32_t u;
            uc_reg_read(uc, ucr[i], &u);
            if (u != rtl_reg(i, mode)) bad = true;
        }
        if (bad) { report("state differs"); return false; }
        return true;
    }

    // ---------------------------------------------------- the clock
    // One cycle.  The ports' inputs for this cycle are already applied; the
    // CPU's outputs (after the last eval) are this cycle's requests.
    bool step() {
        // what the memories take at this edge
        bool ireq = top->ic_req;
        uint32_t iaddr = top->ic_addr;
        bool dreq = top->dc_req && (!dc_pend || top->dc_ok);
        uint32_t daddr = top->dc_addr, dwdata = top->dc_wdata;
        bool dwe = top->dc_we;
        uint32_t dbe = top->dc_be;
        bool rt = top->rt_valid;
        profile();
        Ret r = {top->rt_pc, top->rt_instr, top->rt_cpsr, (bool)top->rt_thumb, (bool)top->rt_irq};

        top->clk = 1;
        top->eval();
        cycles++;

        // data port: the request taken at this edge is answered next cycle
        if (top->dc_ok || !dc_pend) dc_pend = false;
        if (dreq) {
            dc_pend = true;
            dc_abt = false;
            dc_q = 0;
            uint32_t a = daddr & ~3u;
            if (a - NGVM_IO_BASE < 0x1000) {
                uint32_t off = a - NGVM_IO_BASE;
                if (dwe) io_write(off, dwdata);
                else { dc_q = io_read(off); io_reads.push_back({off, dc_q}); }
            } else {
                uint8_t *p = rtl.translate(a, dwe);
                if (!p) {
                    dc_abt = true;
                    fprintf(stderr, "RTL data abort at %08x (%s)\n", daddr, dwe ? "write" : "read");
                } else if (dwe) {
                    for (int i = 0; i < 4; i++) if (dbe >> i & 1) p[i] = (uint8_t)(dwdata >> (8 * i));
                } else
                    memcpy(&dc_q, p, 4);
            }
        }
        // instruction port
        uint32_t iw = 0;
        bool iabt = false;
        if (ireq) {
            uint8_t *p = rtl.translate(iaddr, false);
            if (p) memcpy(&iw, p, 4); else iabt = true;
        }
        top->ic_ok = ireq;
        top->ic_data = iw;
        top->ic_abort = iabt;
        top->dc_ok = dc_pend;
        top->dc_rdata = dc_q;
        top->dc_abort = dc_abt;

        if (rt) {
            uint64_t since = cycles - last_retire_cycle;  // what this retirement cost
            last_retire_cycle = cycles;
            if (!retire(r)) { failed = true; return false; }
            bool idle = !r.irq && r.pc == idle_pc;
            charge(idle);
            if (idle) {
                idle_cycles += since;
                idle_retired++;
                uint64_t n = next_event_insns();
                if (n > insns) insns = n;
            }
        }
        update_devices();
        top->irq = (irq_status & irq_enable) != 0;

        top->clk = 0;
        top->eval();
        return exit_code < 0;
    }
};

int main(int argc, char **argv)
{
    Verilated::commandArgs(argc, argv);
    const char *rom = nullptr, *kernel = "build/kernel/kernel.elf", *drive = nullptr;
    Bench b;
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        if (a == "--rom" && i + 1 < argc) rom = argv[++i];
        else if (a == "--kernel" && i + 1 < argc) kernel = argv[++i];
        else if (a == "--drive" && i + 1 < argc) drive = argv[++i];
        else if (a == "--insns" && i + 1 < argc) b.max_insns = strtoull(argv[++i], nullptr, 0);
        else if (a == "--mips" && i + 1 < argc) b.mips = (uint32_t)strtoul(argv[++i], nullptr, 0);
        else if (a == "--no-uc") b.use_uc = false;
        else if (a[0] != '+') { fprintf(stderr, "unknown argument %s\n", argv[i]); return 2; }
    }
    if (!rom) { fprintf(stderr, "usage: %s --rom SYM.ROM [--kernel kernel.elf] [--drive img] [--insns N]\n", argv[0]); return 2; }

    std::vector<Seg> segs;
    std::map<std::string, uint32_t> syms;
    load_elf(kernel, segs, syms);
    b.idle_pc = syms.count("idle_loop") ? syms["idle_loop"] : 0;
    b.bp.idle_pc = b.idle_pc;
    auto romd = slurp(rom);
    b.rom_size = romd.size();
    for (Mem *m : {&b.rtl, &b.ucm}) {
        m->rom = romd;
        m->rom.resize((romd.size() + ROM_MAP_ALIGN - 1) & ~(size_t)(ROM_MAP_ALIGN - 1));
        for (auto &s : segs) memcpy(m->translate(s.addr, true), s.data.data(), s.data.size());
    }
    if (drive) {
        auto d = slurp(drive);
        if (d.size() > NGVM_DRIVE_MAX) { fprintf(stderr, "drive image too large\n"); return 2; }
        b.drive_size = d.size();
        memcpy(b.rtl.drive.data(), d.data(), d.size());
        memcpy(b.ucm.drive.data(), d.data(), d.size());
    }
    if (b.use_uc) b.uc_init(segs);

    b.top = new Varm_cpu;
    b.top->clk = 0; b.top->rst = 1; b.top->irq = 0;
    b.top->ic_ok = 0; b.top->dc_ok = 0; b.top->ic_abort = 0; b.top->dc_abort = 0;
    b.top->eval();
    for (int i = 0; i < 4; i++) { b.top->clk = 1; b.top->eval(); b.top->clk = 0; b.top->eval(); }
    b.top->rst = 0;
    b.top->eval();

    auto t0 = std::chrono::steady_clock::now();
    uint64_t last_report = 0;
    while (b.step()) {
        if (b.max_insns && b.insns >= b.max_insns) break;
        if (b.cycles - last_report >= 50000000) {
            last_report = b.cycles;
            fprintf(stderr, "[%llu cycles, %llu instructions executed, %.2f virtual s]\n",
                    (unsigned long long)b.cycles, (unsigned long long)b.retired, b.insns / (b.mips * 1e6));
        }
        if (b.cycles > 200 && b.hist.empty() && b.cycles > 10000) { fprintf(stderr, "nothing retires\n"); return 1; }
    }
    bool ok = !b.failed && (b.exit_code < 0 || b.exit_code == 0);
    double host = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
    uint64_t busy = b.cycles - b.idle_cycles;
    printf("%s: %.3f virtual s; %llu instructions executed in %llu cycles, %llu of them outside the idle loop "
           "(CPI %.3f there, ideal memories); %.0f s on the host%s\n",
           ok ? "ok" : "stopped", b.insns / (b.mips * 1e6), (unsigned long long)b.retired,
           (unsigned long long)b.cycles, (unsigned long long)busy,
           b.retired > b.idle_retired ? (double)busy / (b.retired - b.idle_retired) : 0.0, host,
           b.use_uc ? ", lockstep with Unicorn" : "");
    b.print_profile(busy);
    b.bp.report();
    delete b.top;
    return ok && !b.mismatches ? 0 : 1;
}
