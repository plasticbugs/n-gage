// The CPU side of NGVM (rtl/ngvm_sys.sv: the CPU, its caches, the page table
// and the devices) in lockstep with Unicorn (docs/core-design.md 6).
//
// The bench is the memory behind the bus port: SDRAM and CRAM as flat
// arrays at their bus addresses, answering each request after a fixed
// latency.  Unicorn runs the same kernel, firmware and game from its own
// copy of NGVM's memory.  Each time the RTL retires an instruction, Unicorn
// executes one and the bench compares r0-r14 of the current mode, the CPSR
// and the next PC.  A stale cache line, a lost write-back or a wrong
// translation shows as the first difference after it.
//
// The devices are the RTL's (ngvm_io.sv), with real time: CPU_HZ cycles are
// a second.  Each value the RTL reads from a device is replayed to Unicorn's
// read of it; IRQ entries are matched as in sim/cpu/tb_cpu.cpp.  The bench
// pulses vblank at 60 Hz of cycles, which also starts the D-cache's clean.
//
//   obj_sys/Vngvm_sys --rom SYM.ROM --kernel build/kernel/kernel.elf
//       [--drive game.img] [--seconds S] [--no-uc] [--lat CYCLES]
//       [--frames-to DIR --frame-every N] [--keys "S:MASK ..."]
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
#include "Vngvm_sys.h"
#include "Vngvm_sys___024root.h"
#include "Vngvm_sys_ngvm_sys.h"
#include "Vngvm_sys_arm_cpu.h"
#include "Vngvm_sys_arm_regs.h"
#include "verilated.h"

#include "../../sw/include/ngvm_hw.h"

#ifndef SYS_HZ
#define SYS_HZ 80000000
#endif
static const uint64_t CPU_HZ = SYS_HZ;

static const uint32_t ROM_MAP_ALIGN = 0x10000;
static const uint32_t BUS_ROM = 0x2000000, BUS_KSEC = 0x3400000, BUS_DRIVE = 0x4000000;

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
        if (rd32(d, s + 4) != 2) continue;
        uint32_t off = rd32(d, s + 16), size = rd32(d, s + 20), link = rd32(d, s + 24);
        uint32_t stroff = rd32(d, shoff + link * shentsize + 16);
        for (uint32_t j = 0; j < size / 16; j++) {
            uint32_t name = rd32(d, off + j * 16), value = rd32(d, off + j * 16 + 4);
            std::string n((const char *)&d[stroff + name]);
            if (!n.empty()) syms[n] = value;
        }
    }
}

// Unicorn's copy of NGVM's memory
struct Mem {
    std::vector<uint8_t> ram, ksec, rom, drive;
    uint16_t pt[NGVM_PT_ENTRIES];
    Mem() : ram(NGVM_RAM_SIZE), ksec(NGVM_KSEC_SIZE), drive(NGVM_DRIVE_MAX) {
        for (auto &e : pt) e = NGVM_PT_NONE;
    }
};

struct Bench {
    Vngvm_sys *top;
    Mem ucm;
    std::vector<uint8_t> sdram, cram;               // the RTL's memory, at bus addresses
    uc_engine *uc = nullptr;
    bool use_uc = true;
    uint64_t cycles = 0, retired = 0, max_cycles = 0;
    uint32_t idle_pc = 0;
    uint64_t idle_retired = 0;
    size_t rom_size = 0, drive_size = 0;
    int exit_code = -1;
    std::string con;

    // the bus: one request, answered after a latency
    int lat_line = 40, lat_word = 20;
    int bus_wait = -1;                              // cycles to the answer; -1 idle
    bool bus_hold = false;                          // answered; waiting for bus_req to drop
    uint64_t nbus[4] = {};

    // frames
    uint64_t frame_period = CPU_HZ / 60, next_frame = CPU_HZ / 60, frames = 0;
    const char *frames_to = nullptr;
    int frame_every = 0;
    std::vector<std::pair<uint64_t, uint32_t>> keys;  // (cycle, mask)

    std::deque<std::pair<uint32_t, uint32_t>> io_reads;
    uint32_t uc_pt_index = 0;
    std::map<uint32_t, uint32_t> runs;

    struct Ret { uint32_t pc, instr, cpsr; bool thumb, irq; };
    std::deque<Ret> hist;
    uint32_t uc_next_pc = 0;
    bool have_next = false;
    uint64_t mismatches = 0;
    bool failed = false;
    bool bl_merged = false;

    Bench() : sdram(0x4000000), cram(0x2000000) {}

    uint8_t *bus_at(uint32_t a) { return a & BUS_DRIVE ? &cram[a & 0x1FFFFFF] : &sdram[a & 0x3FFFFFF]; }

    // ---------------------------------------------------- Unicorn
    static uint32_t pt_virt(uint32_t i) {
        return i < NGVM_PT_CHUNK ? NGVM_CHUNK_BASE + (i << NGVM_PAGE_SHIFT)
                                 : NGVM_DATA_BASE + ((i - NGVM_PT_CHUNK) << NGVM_PAGE_SHIFT);
    }
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
    void uc_init() {
        uc_err e = uc_open(UC_ARCH_ARM, UC_MODE_ARM, &uc);
        if (e) { fprintf(stderr, "uc_open: %s\n", uc_strerror(e)); exit(3); }
        uc_ctl_set_cpu_model(uc, UC_CPU_ARM_TI925T);
        uc_mem_map_ptr(uc, NGVM_PHYS_BASE, NGVM_RAM_SIZE, UC_PROT_ALL, ucm.ram.data());
        uc_mem_map_ptr(uc, NGVM_KERN_BASE, NGVM_KERN_SIZE, UC_PROT_ALL, ucm.ram.data());
        uc_mem_map_ptr(uc, NGVM_KSEC_BASE, NGVM_KSEC_SIZE, UC_PROT_ALL, ucm.ksec.data());
        uc_mem_map_ptr(uc, NGVM_ROM_BASE, ucm.rom.size(), UC_PROT_READ | UC_PROT_EXEC, ucm.rom.data());
        uc_mem_map_ptr(uc, NGVM_DRIVE_BASE, NGVM_DRIVE_MAX, UC_PROT_ALL, ucm.drive.data());
        uc_mmio_map(uc, NGVM_IO_BASE, 0x1000, uc_io_read, this, uc_io_write, this);
        uc_hook h;
        uc_hook_add(uc, &h, UC_HOOK_INTR, (void *)uc_intr, this, 1, 0);
        uint32_t cpsr = 0xD3;
        uc_reg_write(uc, UC_ARM_REG_CPSR, &cpsr);
    }

    uint32_t rtl_reg(int r, uint32_t mode) {
        auto &rf = top->rootp->ngvm_sys->u_cpu->u_regs->r;
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
        fprintf(stderr, "\n*** %s after %llu instructions (%llu cycles, %.3f s)\n", why,
                (unsigned long long)retired, (unsigned long long)cycles, (double)cycles / CPU_HZ);
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

    bool retire(const Ret &r) {
        hist.push_back(r);
        if (hist.size() > 24) hist.pop_front();
        if (!r.irq) retired++;
        if (!use_uc) return true;
        if (have_next && r.pc != uc_next_pc) {
            report("PC differs");
            fprintf(stderr, "RTL retired %08x where Unicorn is at %08x\n", r.pc, uc_next_pc);
            return false;
        }
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
            bl_merged = true;
            uc_next_pc = r.pc + 2;
            return true;
        }
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

    // the LCD as the gateware would scan it: from the bus memory, so only
    // what the D-cache has written back shows
    void dump_frame() {
        uint32_t base = top->lcd_base;
        char path[512];
        snprintf(path, sizeof path, "%s/f%05llu.ppm", frames_to, (unsigned long long)frames);
        FILE *f = fopen(path, "wb");
        if (!f) { perror(path); return; }
        fprintf(f, "P6\n%d %d\n255\n", LCD_W, LCD_H);
        for (int y = 0; y < LCD_H; y++)
            for (int x = 0; x < LCD_W; x++) {
                uint16_t p = 0;
                if (base - NGVM_PHYS_BASE < NGVM_RAM_SIZE && top->lcd_on) {
                    uint8_t *q = bus_at(base - NGVM_PHYS_BASE + (y * LCD_W + x) * 2);
                    p = q[0] | q[1] << 8;
                }
                uint8_t rgb[3] = {(uint8_t)(((p >> 8) & 15) * 17), (uint8_t)(((p >> 4) & 15) * 17), (uint8_t)((p & 15) * 17)};
                fwrite(rgb, 1, 3, f);
            }
        fclose(f);
    }

    // ---------------------------------------------------- the clock
    bool step() {
        // what this cycle presents, before the edge
        bool rt = top->rt_valid;
        Ret r = {top->rt_pc, top->rt_instr, top->rt_cpsr, (bool)top->rt_thumb, (bool)top->rt_irq};
        if (top->io_rd) io_reads.push_back({(uint32_t)top->io_rd_off * 4, top->io_rd_data});
        if (top->dbg_putc) {
            char c = (char)(top->dbg_data & 0xFF);
            if (c == 10) { printf("%s\n", con.c_str()); fflush(stdout); con.clear(); }
            else con.push_back(c);
        }
        if (top->dbg_hex) printf("[hex] %08x\n", top->dbg_data);
        if (top->dbg_exit) { if (!con.empty()) printf("%s\n", con.c_str()); exit_code = (int)top->dbg_data; }
        bool breq = top->bus_req;

        top->clk = 1;
        top->eval();
        cycles++;

        // the bus
        top->bus_done = 0;
        if (bus_hold) { if (!breq) bus_hold = false; }
        else if (bus_wait < 0 && breq) {
            bus_wait = (top->bus_cmd < 2 ? lat_line : lat_word) - 1;
        } else if (bus_wait > 0) bus_wait--;
        else if (bus_wait == 0) {
            uint32_t a = top->bus_addr, cmd = top->bus_cmd;
            nbus[cmd]++;
            uint8_t *p = bus_at(a);
            switch (cmd) {
            case 0: for (int i = 0; i < 8; i++) memcpy(&top->bus_rdata[i], p + 4 * i, 4); break;
            case 1:
                for (int i = 0; i < 32; i++)
                    if (top->bus_be >> i & 1) p[i] = (uint8_t)(top->bus_wdata[i / 4] >> (8 * (i % 4)));
                break;
            case 2: memcpy(&top->bus_rdata[0], p, 4); break;
            }
            top->bus_done = 1;
            bus_wait = -1;
            bus_hold = true;
        }

        // frames, keys
        top->vblank = 0;
        if (cycles >= next_frame) {
            next_frame += frame_period;
            frames++;
            top->vblank = 1;
            if (frames_to && frame_every && frames % frame_every == 0) dump_frame();
        }
        while (!keys.empty() && cycles >= keys.front().first) {
            top->keys = keys.front().second;
            keys.erase(keys.begin());
        }

        if (rt) {
            if (!retire(r)) { failed = true; return false; }
            if (!r.irq && r.pc == idle_pc) idle_retired++;
        }

        top->clk = 0;
        top->eval();
        return exit_code < 0;
    }
};

int main(int argc, char **argv)
{
    Verilated::commandArgs(argc, argv);
    const char *rom = nullptr, *kernel = "build/kernel/kernel.elf", *drive = nullptr;
    double seconds = 1.0;
    Bench b;
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        if (a == "--rom" && i + 1 < argc) rom = argv[++i];
        else if (a == "--kernel" && i + 1 < argc) kernel = argv[++i];
        else if (a == "--drive" && i + 1 < argc) drive = argv[++i];
        else if (a == "--seconds" && i + 1 < argc) seconds = atof(argv[++i]);
        else if (a == "--no-uc") b.use_uc = false;
        else if (a == "--lat" && i + 1 < argc) { b.lat_line = atoi(argv[++i]); b.lat_word = b.lat_line / 2 + 1; }
        else if (a == "--frames-to" && i + 1 < argc) b.frames_to = argv[++i];
        else if (a == "--frame-every" && i + 1 < argc) b.frame_every = atoi(argv[++i]);
        else if (a == "--keys" && i + 1 < argc) {
            // "S:MASK S:MASK ...": from S seconds, IO_KEYS reads MASK
            std::string s = argv[++i];
            size_t p = 0;
            while (p < s.size()) {
                size_t q = s.find(' ', p);
                std::string t = s.substr(p, q == std::string::npos ? std::string::npos : q - p);
                size_t c = t.find(':');
                if (c != std::string::npos)
                    b.keys.push_back({(uint64_t)(atof(t.substr(0, c).c_str()) * CPU_HZ),
                                      (uint32_t)strtoul(t.substr(c + 1).c_str(), nullptr, 0)});
                if (q == std::string::npos) break;
                p = q + 1;
            }
        }
        else if (a[0] != '+') { fprintf(stderr, "unknown argument %s\n", argv[i]); return 2; }
    }
    if (!rom) { fprintf(stderr, "usage: %s --rom SYM.ROM [--kernel kernel.elf] [--drive img] [--seconds S]\n", argv[0]); return 2; }
    b.max_cycles = (uint64_t)(seconds * CPU_HZ);

    std::vector<Seg> segs;
    std::map<std::string, uint32_t> syms;
    load_elf(kernel, segs, syms);
    b.idle_pc = syms.count("idle_loop") ? syms["idle_loop"] : 0xFFFFFFFFu;
    auto romd = slurp(rom);
    b.rom_size = romd.size();
    b.ucm.rom = romd;
    b.ucm.rom.resize((romd.size() + ROM_MAP_ALIGN - 1) & ~(size_t)(ROM_MAP_ALIGN - 1));
    memcpy(&b.sdram[BUS_ROM], romd.data(), romd.size());
    for (auto &s : segs) {
        if (s.addr >= NGVM_KERN_SIZE) { fprintf(stderr, "kernel segment at %08x\n", s.addr); return 2; }
        memcpy(&b.ucm.ram[s.addr], s.data.data(), s.data.size());
        memcpy(&b.sdram[s.addr], s.data.data(), s.data.size());
    }
    if (drive) {
        auto d = slurp(drive);
        if (d.size() > NGVM_DRIVE_MAX) { fprintf(stderr, "drive image too large\n"); return 2; }
        b.drive_size = d.size();
        memcpy(b.ucm.drive.data(), d.data(), d.size());
        memcpy(b.cram.data(), d.data(), d.size());
    }
    if (b.use_uc) b.uc_init();

    b.top = new Vngvm_sys;
    b.top->rom_size = (uint32_t)b.rom_size;
    b.top->drive_size = (uint32_t)b.drive_size;
    b.top->keys = 0;
    b.top->vblank = 0;
    b.top->bus_done = 0;
    b.top->clk = 0; b.top->rst = 1;
    b.top->eval();
    for (int i = 0; i < 4; i++) { b.top->clk = 1; b.top->eval(); b.top->clk = 0; b.top->eval(); }
    b.top->rst = 0;
    b.top->eval();

    auto t0 = std::chrono::steady_clock::now();
    uint64_t last_report = 0;
    while (b.step()) {
        if (b.cycles >= b.max_cycles) break;
        if (b.cycles - last_report >= 50000000) {
            last_report = b.cycles;
            fprintf(stderr, "[%.2f s: %llu instructions, %llu line reads, %llu line writes, %llu word reads]\n",
                    (double)b.cycles / CPU_HZ, (unsigned long long)b.retired,
                    (unsigned long long)b.nbus[0], (unsigned long long)b.nbus[1],
                    (unsigned long long)b.nbus[2]);
        }
        if (b.cycles > 100000 && b.hist.empty()) { fprintf(stderr, "nothing retires\n"); return 1; }
    }
    bool ok = !b.failed && (b.exit_code < 0 || b.exit_code == 0);
    double host = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
    printf("%s: %.3f s at %d MHz; %llu instructions in %llu cycles (%llu in the idle loop); "
           "bus: %llu line reads, %llu line writes, %llu word reads; %.0f s on the host%s\n",
           ok ? "ok" : "stopped", (double)b.cycles / CPU_HZ, (int)(CPU_HZ / 1000000),
           (unsigned long long)b.retired, (unsigned long long)b.cycles, (unsigned long long)b.idle_retired,
           (unsigned long long)b.nbus[0], (unsigned long long)b.nbus[1], (unsigned long long)b.nbus[2],
           host, b.use_uc ? ", lockstep with Unicorn" : "");
    delete b.top;
    return ok && !b.mismatches ? 0 : 1;
}
