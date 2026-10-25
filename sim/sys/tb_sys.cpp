// The CPU side of NGVM (rtl/ngvm_sys.sv: the CPU, its caches, the page table
// and the devices) in lockstep with Unicorn (docs/core-design.md 6).
//
// The bench is the memory behind the bus port: SDRAM and CRAM as flat
// arrays at their bus addresses, answering each request after a fixed
// latency.  A line read's words come one at a time from the word asked for,
// as the Pocket's do (ngage_mem.sv): the first at 2/5 of the latency, the
// last at 9/10, each counted on bus_cnt.  A fill's write-back (BC_RDWR)
// lands after the answer and keeps the memory busy for 3/4 of the latency
// more, which the next request waits out.  Unicorn runs the same kernel, firmware and game from its own
// copy of NGVM's memory.  Each time the RTL retires an instruction, Unicorn
// executes one and the bench compares r0-r14 of the current mode, the CPSR
// and the next PC.  A stale cache line, a lost write-back or a wrong
// translation shows as the first difference after it.
//
// The devices are the RTL's (ngvm_io.sv), with real time: CPU_HZ cycles are
// a second.  Each value the RTL reads from a device is replayed to Unicorn's
// read of it; IRQ entries are matched as in sim/cpu/tb_cpu.cpp.  The bench
// pulses vblank at 60 Hz of cycles; the D-cache's clean is the kernel's
// (IO_LCD_SHOW).  A drive larger than its window (up to NGVM_IMAGE_MAX) has
// its first 32 MB there, and the bench answers each fetch (IO_FETCH_*) as
// tools/ngvm/ngvm.py's default does, 1 ms and then 4 bytes a microsecond
// later: the image's bytes into both copies of the window at once, then
// the answer.  --fetch-fail CODE answers the first fetch with that error
// and no bytes, or, with 0, never: the screen the kernel paints then is
// written to --frames-to when it stops.
//
//   obj_sys/Vngvm_sys --rom SYM.ROM --kernel build/kernel/kernel.elf
//       [--drive game.img] [--seconds S] [--no-uc] [--lat CYCLES]
//       [--frames-to DIR --frame-every N] [--keys "S:MASK ..."] [--keymap HEX]
//       [--watch-pc ADDR,ADDR,...]  (hex; prints when each retires, its first 20 times)
//       [--profile FROM]  (where the cycles go from FROM seconds, the idle loop's apart)
//       [--restore FILE]  (start from tools/ngvm/ngvm.py --save-at's machine; see below)
//       [--save-at S:FILE]  (the machine, at an IRQ entry from S seconds, for ngvm.py --restore)
//
// --restore starts the machine where the reference saved it, so a run can
// begin in a game's play rather than at power-on.  The file holds, little-
// endian: "NGVMCKP1"; the virtual time (double, s), PC and CPSR; the 32
// registers in arm_regs.sv's physical numbering; the SPSRs of FIQ, SVC, ABT,
// IRQ and UND; the microsecond clock (u64), then IRQ status and enable, the
// timer's compare and whether it is armed, the clock's latched high word,
// LCD base and control, the frame count, the keys, the audio rate, the data
// window's number and the drive's size (u32 each); the page table (u16 an
// entry); RAM, the fixed processes' section and the drive.  The bench loads
// memory and Unicorn from it, and once the CPU's reset ends (cpu_rst, after
// the page table's clear) sets the RTL's registers, CPSR, SPSRs, fetch
// address, devices and table to it, before the CPU's first clock.  The
// caches, the BTB and the audio FIFO start empty.  Times given to --seconds,
// --keys and --profile stay times since power-on.
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <string>
#include <vector>
#include <deque>
#include <map>
#include <chrono>
#include <algorithm>
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
    bool keymap_seen = false;
    uint64_t cycles = 0, retired = 0, max_cycles = 0;
    uint32_t idle_pc = 0;
    uint64_t idle_retired = 0;
    size_t rom_size = 0, drive_size = 0;
    std::vector<uint8_t> image;                     // the whole drive, for fetches
    bool fetch_seen = false;
    uint64_t fetch_end = ~0ull, fetches = 0;
    uint32_t f_src = 0, f_dst = 0, f_len = 0;
    int fetch_fail = -1;                            // --fetch-fail: the first fetch's answer
    int exit_code = -1;
    std::string con;
    double t_base = 0;                              // virtual s at cycle 0 (--restore)
    double vt() const { return t_base + (double)cycles / CPU_HZ; }

    // the bus: one request, answered after a latency
    int lat_line = 40, lat_word = 20;
    int bus_t = -1;                                 // cycles into the request; -1 idle
    int bus_lat = 0, bus_got = 0;                   // its latency; line words in so far
    uint64_t mem_busy = 0;                          // a write-back until this cycle
    bool bus_hold = false;                          // answered; waiting for bus_req to drop
    uint8_t bus_cnt = 0;
    uint64_t nbus[4] = {};                          // by BC_*; a BC_RDWR also counts as 0 and 1
    int word_at(int i) const {                      // when a line's i-th word comes
        int first = std::max(1, lat_line * 2 / 5), last = std::max(first, lat_line * 9 / 10);
        return first + (last - first) * i / 7;
    }

    // frames
    uint64_t frame_period = CPU_HZ / 60, next_frame = CPU_HZ / 60, frames = 0;
    const char *frames_to = nullptr;
    int frame_every = 0;
    std::vector<std::pair<uint64_t, uint32_t>> keys;  // (cycle, mask)
    std::vector<std::pair<double, uint32_t>> key_s;   // (virtual s, mask), as given

    std::deque<std::pair<uint32_t, uint32_t>> io_reads;
    uint32_t uc_pt_index = 0;
    std::map<uint32_t, uint32_t> runs;

    struct Ret { uint32_t pc, instr, cpsr; bool thumb, irq; };
    std::deque<Ret> hist;
    uint32_t uc_next_pc = 0;
    bool have_next = false;
    uint64_t mismatches = 0;
    bool failed = false;

    // --profile: what each cycle saw, as sim/cpu/tb_cpu.cpp tallies it, with
    // the stalls the caches cause split out; charged to the busy or the idle
    // side when the next instruction retires
    enum { P_RETIRE, P_UOP, P_EMPTY, P_EMPTY_IF, P_F2MISS, P_SWAIT, P_SW_LOAD, P_SW_SHIFT, P_SW_MUL,
           P_SW_SHREG, P_SW_RRX, P_MUL, P_MHOLD,
           P_MH_CMP, P_MH_LDFILL, P_MH_STFILL, P_MH_FILLOTHER, P_MH_REPLAY, P_MH_WALK, P_MH_UNC,
           P_MH_WCF, P_MH_OTHER,
           P_DRED, P_ARED_BR, P_ARED_BX, P_ARED_EXC, P_ARED_OTHER, P_MRED, P_WRED, P_N };
    uint64_t prof_from = UINT64_MAX, prof_pend[P_N] = {}, prof_busy[P_N] = {}, prof_cyc[2] = {};
    void profile() {
        auto *c = top->rootp->ngvm_sys->u_cpu;
        if (top->rt_valid && !top->rt_irq) prof_pend[P_RETIRE]++;
        if (c->d2_issue && !c->d2_last) prof_pend[P_UOP]++;
        if (!c->a_valid) {
            prof_pend[P_EMPTY]++;
            if (!c->s_valid && !c->d2_valid && c->ib_n == 0) prof_pend[P_EMPTY_IF]++;
        }
        if (c->f2_miss) prof_pend[P_F2MISS]++;
        if (c->s_valid && c->s_stall && c->a_free) {
            prof_pend[P_SWAIT]++;
            for (int k = 0; k < 5; k++) if (c->s_why >> k & 1) prof_pend[P_SW_LOAD + k]++;
        }
        if (c->a_busy) prof_pend[P_MUL]++;
        if (c->m_hold) {
            // what the D-cache is doing meanwhile (ngvm_dcache.sv st_t)
            auto *s = top->rootp->ngvm_sys;           // u_dc is flattened into it
            prof_pend[P_MHOLD]++;
            int k;
            switch (s->u_dc__DOT__st) {
            case 0:  k = P_MH_CMP; break;                               // S_IDLE: the compare
            case 5:  k = !s->u_dc__DOT__r_v ? P_MH_FILLOTHER            // S_FILL
                         : s->u_dc__DOT__mtag == s->u_dc__DOT__r_tag && s->u_dc__DOT__mset == s->u_dc__DOT__r_set
                           ? (s->u_dc__DOT__r_we ? P_MH_STFILL : P_MH_LDFILL) : P_MH_FILLOTHER; break;
            case 1:  case 7: k = P_MH_REPLAY; break;                    // S_REPLAY, S_DONE
            case 2:  case 3: case 8: case 9: k = P_MH_WALK; break;      // S_WBRD, S_WB, S_WALK, S_WTAG
            case 6:  k = P_MH_UNC; break;
            case 10: k = P_MH_WCF; break;
            default: k = P_MH_OTHER; break;                             // S_GAP, S_SWEEP
            }
            prof_pend[k]++;
        }
        if (c->w_redirect) prof_pend[P_WRED]++;
        else if (c->m_redirect) prof_pend[P_MRED]++;
        else if (c->a_redirect) {
            switch (c->a_kind) {
            case 7:  prof_pend[P_ARED_BR]++; break;
            case 8:  prof_pend[P_ARED_BX]++; break;
            case 11: prof_pend[P_ARED_EXC]++; break;
            default: prof_pend[P_ARED_OTHER]++; break;
            }
        } else if (c->d_redirect) prof_pend[P_DRED]++;
        pend_cyc++;
    }
    uint64_t pend_cyc = 0;
    void charge(bool idle) {
        prof_cyc[idle] += pend_cyc; pend_cyc = 0;
        if (!idle) for (int i = 0; i < P_N; i++) prof_busy[i] += prof_pend[i];
        memset(prof_pend, 0, sizeof prof_pend);
    }
    void print_profile() {
        static const char *name[P_N] = {
            "instructions retired", "extra uops (LDM/STM, SWP, long multiply)", "A empty",
            "  ... with S, D2 and the buffer empty too", "F2 waits on the I-cache", "S waits on an operand",
            "  ... a load's value", "  ... a result in A, to shift", "  ... a result in A, to multiply",
            "  ... a shift by register's extra cycle", "  ... an RRX behind a flag write", "A waits on the multiplier",
            "M waits on memory",
            "  ... the D-cache's compare", "  ... a load's own line coming in", "  ... a store's own line, not on the bus yet",
            "  ... another line coming in", "  ... a replay or S_DONE", "  ... a clean or flush walk",
            "  ... an uncached access", "  ... the combining buffer going out", "  ... other (S_GAP, S_SWEEP)", "D2 redirects (B, BL, Thumb BL pair)", "A redirects: conditional B",
            "A redirects: BX", "A redirects: exceptions", "A redirects: other (MSR)",
            "M redirects (ALU to PC, BL suffix)", "W redirects (load to PC)" };
        printf("profile from %.2f s: %llu busy cycles, %llu idle; by what each cycle saw (they overlap; redirects are events):\n",
               t_base + (double)prof_from / CPU_HZ, (unsigned long long)prof_cyc[0], (unsigned long long)prof_cyc[1]);
        for (int i = 0; i < P_N; i++)
            printf("  %-42s %12llu  %6.3f per instruction\n", name[i], (unsigned long long)prof_busy[i],
                   prof_busy[P_RETIRE] ? (double)prof_busy[i] / prof_busy[P_RETIRE] : 0.0);
        if (prof_busy[P_RETIRE])
            printf("  CPI (busy) %.3f\n", (double)prof_cyc[0] / prof_busy[P_RETIRE]);
    }
    bool bl_merged = false;

    Bench() : sdram(0x4000000), cram(0x2000000) {}

    uint8_t *bus_at(uint32_t a) { return a & BUS_DRIVE ? &cram[a & 0x1FFFFFF] : &sdram[a & 0x3FFFFFF]; }
    // BC_RDWR's whole line, to bus_waddr's line
    void write_back() {
        uint8_t *p = bus_at(top->bus_waddr << 5);
        for (int i = 0; i < 32; i++) p[i] = (uint8_t)(top->bus_wdata[i / 4] >> (8 * (i % 4)));
    }

    // ---------------------------------------------------- Unicorn
    // entries LOW_FIRST..LOW_END-1 at the low name only, as ngvm.py maps them
    static constexpr uint32_t LOW_FIRST = NGVM_LOW_BASE >> NGVM_PAGE_SHIFT;
    static constexpr uint32_t LOW_END = (NGVM_LOW_BASE + NGVM_LOW_SIZE) >> NGVM_PAGE_SHIFT;
    static uint32_t pt_virt(uint32_t i) {
        if (i >= LOW_FIRST && i < LOW_END) return i << NGVM_PAGE_SHIFT;
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
            while (k + 1 <= hi && k + 1 != NGVM_PT_CHUNK && k + 1 != LOW_FIRST && k + 1 != LOW_END &&
                   ucm.pt[k + 1] == ucm.pt[k] + 1) k++;
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
    // A user-mode instruction Unicorn refuses that the N-Gage's ARM920T runs:
    // the 26-bit APCS returns, MOVS pc, lr (a data-processing op with S set
    // and pc its destination) and LDM with ^ and pc.  User mode has no SPSR;
    // the RTL reads the CPSR in its place (arm_cpu.sv, spsr_of), so the CPSR
    // is unchanged and the instruction is a plain write to pc.  As
    // tools/ngvm/ngvm.py's on_invalid; anything else stays a fault.
    static inline unsigned long long n_invalid;   // how often it was met
    static bool uc_invalid(uc_engine *u, void *) {
        static const int R[16] = {UC_ARM_REG_R0, UC_ARM_REG_R1, UC_ARM_REG_R2, UC_ARM_REG_R3,
            UC_ARM_REG_R4, UC_ARM_REG_R5, UC_ARM_REG_R6, UC_ARM_REG_R7, UC_ARM_REG_R8, UC_ARM_REG_R9,
            UC_ARM_REG_R10, UC_ARM_REG_R11, UC_ARM_REG_R12, UC_ARM_REG_SP, UC_ARM_REG_LR, UC_ARM_REG_PC};
        uint32_t cpsr, pc, i;
        uc_reg_read(u, UC_ARM_REG_CPSR, &cpsr);
        uc_reg_read(u, UC_ARM_REG_PC, &pc);
        if ((cpsr & 0x20) || (cpsr & 0x1F) != 0x10 || uc_mem_read(u, pc, &i, 4)) return false;
        bool n = cpsr >> 31 & 1, z = cpsr >> 30 & 1, c = cpsr >> 29 & 1, v = cpsr >> 28 & 1;
        const bool cs[16] = {z, !z, c, !c, n, !n, v, !v, c && !z, !c || z, n == v, n != v,
                             !z && n == v, z || n != v, true, false};
        bool cond = cs[i >> 28];
        auto reg = [&](unsigned r) { uint32_t x = pc + 8; if (r != 15) uc_reg_read(u, R[r], &x); return x; };
        uint32_t next = pc + 4;
        unsigned op = i >> 21 & 15;
        if ((i & 0x0C10F000) == 0x0010F000 && (i & 0x02000090) != 0x90 && !(op >= 8 && op <= 11)) {
            uint32_t op2;
            if (i & (1u << 25)) {
                unsigned rot = (i >> 8 & 15) * 2, imm = i & 0xFF;
                op2 = rot ? (imm >> rot) | (imm << (32 - rot)) : imm;
            } else if (i & 0x10) {
                return false;                  // shifted by a register: not met
            } else {
                uint32_t rm = reg(i & 15); unsigned typ = i >> 5 & 3, sh = i >> 7 & 31;
                if (typ == 0) op2 = rm << sh;
                else if (typ == 1) op2 = sh ? rm >> sh : 0;
                else if (typ == 2) op2 = (uint32_t)((int32_t)rm >> (sh ? sh : 31)) ;
                else op2 = sh ? (rm >> sh) | (rm << (32 - sh)) : ((uint32_t)c << 31) | (rm >> 1);
            }
            uint32_t rn = reg(i >> 16 & 15), res = 0;
            switch (op) {
            case 0: res = rn & op2; break;           case 1: res = rn ^ op2; break;
            case 2: res = rn - op2; break;           case 3: res = op2 - rn; break;
            case 4: res = rn + op2; break;           case 5: res = rn + op2 + c; break;
            case 6: res = rn - op2 - 1 + c; break;   case 7: res = op2 - rn - 1 + c; break;
            case 12: res = rn | op2; break;          case 13: res = op2; break;
            case 14: res = rn & ~op2; break;         default: res = ~op2; break;
            }
            if (cond) next = res & ~3u;
            uc_reg_write(u, UC_ARM_REG_PC, &next);
            n_invalid++;
            return true;
        }
        if ((i & 0x0E508000) == 0x08508000) {  // LDM, ^, pc in the list
            if (cond) {
                unsigned rn = i >> 16 & 15, cnt = 0;
                for (int r = 0; r < 16; r++) cnt += i >> r & 1;
                uint32_t base = reg(rn), up = i >> 23 & 1, pre = i >> 24 & 1;
                uint32_t a = up ? base + (pre ? 4 : 0) : base - 4 * cnt + (pre ? 0 : 4);
                uint32_t vals[16];
                if (uc_mem_read(u, a, vals, 4 * cnt)) return false;
                if ((i >> 21 & 1) && !(i >> rn & 1)) {
                    uint32_t wb = up ? base + 4 * cnt : base - 4 * cnt;
                    uc_reg_write(u, R[rn], &wb);
                }
                for (int r = 0, k = 0; r < 16; r++)
                    if (i >> r & 1) {
                        uint32_t x = vals[k++];
                        if (r == 15) next = x & ~3u; else uc_reg_write(u, R[r], &x);
                    }
            }
            uc_reg_write(u, UC_ARM_REG_PC, &next);
            n_invalid++;
            return true;
        }
        return false;
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
        uc_hook_add(uc, &h, UC_HOOK_INSN_INVALID, (void *)uc_invalid, this, 1, 0);
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
                (unsigned long long)retired, (unsigned long long)cycles, vt());
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

    // ---------------------------------------------------- --restore
    struct Ckpt {
        double t = 0;
        uint32_t pc = 0, cpsr = 0, regs[32] = {}, spsr[5] = {};    // SPSR: FIQ SVC ABT IRQ UND
        uint64_t us = 0;
        uint32_t irq_status = 0, irq_enable = 0, timer_cmp = 0, timer_armed = 0, hi_latch = 0,
                 lcd_base = 0, lcd_ctrl = 0, frames = 0, keys = 0, audio_rate = 0, win_id = 0,
                 drive_size = 0;
        std::vector<uint16_t> pt;
    } ck;
    bool restore_pending = false;
    void load_ckpt(const char *path) {
        auto d = slurp(path);
        size_t o = 8;
        auto take = [&](void *p, size_t n) {
            if (o + n > d.size()) { fprintf(stderr, "%s: short\n", path); exit(2); }
            memcpy(p, &d[o], n); o += n;
        };
        if (d.size() < 8 || memcmp(d.data(), "NGVMCKP1", 8)) { fprintf(stderr, "%s: not a checkpoint\n", path); exit(2); }
        take(&ck.t, 8); take(&ck.pc, 4); take(&ck.cpsr, 4);
        take(ck.regs, sizeof ck.regs); take(ck.spsr, sizeof ck.spsr); take(&ck.us, 8);
        uint32_t *dev[] = {&ck.irq_status, &ck.irq_enable, &ck.timer_cmp, &ck.timer_armed, &ck.hi_latch,
                           &ck.lcd_base, &ck.lcd_ctrl, &ck.frames, &ck.keys, &ck.audio_rate, &ck.win_id,
                           &ck.drive_size};
        for (auto *v : dev) take(v, 4);
        ck.pt.resize(NGVM_PT_ENTRIES);
        take(ck.pt.data(), 2 * NGVM_PT_ENTRIES);
        take(ucm.ram.data(), NGVM_RAM_SIZE);
        take(ucm.ksec.data(), NGVM_KSEC_SIZE);
        if (ck.drive_size > NGVM_IMAGE_MAX) { fprintf(stderr, "%s: drive too large\n", path); exit(2); }
        // the window as it was; of a larger drive the rest is --drive's
        size_t held = std::min<size_t>(ck.drive_size, NGVM_DRIVE_MAX);
        if (ck.drive_size > held && image.size() != ck.drive_size) {
            fprintf(stderr, "%s: a drive of %u bytes, larger than its window: --drive must give it\n", path, ck.drive_size);
            exit(2);
        }
        take(ucm.drive.data(), held);
        memcpy(&sdram[0], ucm.ram.data(), NGVM_RAM_SIZE);
        memcpy(&sdram[BUS_KSEC], ucm.ksec.data(), NGVM_KSEC_SIZE);
        memcpy(&cram[0], ucm.drive.data(), held);
        drive_size = ck.drive_size;
        t_base = ck.t;
        restore_pending = true;
        printf("[restore] %.3f s: pc %08x cpsr %08x from %s\n", ck.t, ck.pc, ck.cpsr, path);
    }
    // ---------------------------------------------------- --save-at
    // The machine in --restore's format, for tools/ngvm/ngvm.py --restore:
    // the reference then goes on from the RTL's machine, whose memory layout
    // the reference's own timing does not reproduce.  Taken from Unicorn's
    // copy (lockstep only), which holds every register bank and memory as
    // the program left them, with no cache in the way, at the first IRQ entry
    // or idle-loop retirement from save_s on with no fetch in flight: an IRQ
    // entry flushes the pipeline, so no device write is under way there, and
    // the devices are the RTL's.  A game that never idles still takes the
    // timer's IRQ every few ms.
    double save_s = -1;
    const char *save_path = nullptr;
    void save_ckpt() {
        static const int R[15] = {UC_ARM_REG_R0, UC_ARM_REG_R1, UC_ARM_REG_R2, UC_ARM_REG_R3,
            UC_ARM_REG_R4, UC_ARM_REG_R5, UC_ARM_REG_R6, UC_ARM_REG_R7, UC_ARM_REG_R8,
            UC_ARM_REG_R9, UC_ARM_REG_R10, UC_ARM_REG_R11, UC_ARM_REG_R12, UC_ARM_REG_R13, UC_ARM_REG_R14};
        static const struct { uint32_t mode; int lo, hi, phys, spsr; } banks[] = {
            {0x1F, 0, 14, 0, -1}, {0x11, 8, 14, 16, 0}, {0x13, 13, 14, 23, 1},
            {0x17, 13, 14, 25, 2}, {0x12, 13, 14, 27, 3}, {0x1B, 13, 14, 29, 4}};
        uint32_t cpsr, regs[32] = {}, spsr[5] = {};
        uc_reg_read(uc, UC_ARM_REG_CPSR, &cpsr);
        for (auto &b : banks) {
            uint32_t m = (cpsr & ~0x1Fu) | b.mode;
            uc_reg_write(uc, UC_ARM_REG_CPSR, &m);
            for (int r = b.lo; r <= b.hi; r++) uc_reg_read(uc, R[r], &regs[b.phys + r - b.lo]);
            if (b.spsr >= 0) uc_reg_read(uc, UC_ARM_REG_SPSR, &spsr[b.spsr]);
        }
        uc_reg_write(uc, UC_ARM_REG_CPSR, &cpsr);
        auto *s = top->rootp->ngvm_sys;
        double t = vt();
        uint32_t pc = uc_next_pc;
        uint64_t us = s->u_io__DOT__us;
        uint32_t dev[12] = {(uint32_t)s->u_io__DOT__status, (uint32_t)s->u_io__DOT__enable,
                            (uint32_t)s->u_io__DOT__cmp, (uint32_t)s->u_io__DOT__armed,
                            (uint32_t)s->u_io__DOT__hi_latch, (uint32_t)s->u_io__DOT__lcd_base,
                            (uint32_t)s->u_io__DOT__lcd_on, (uint32_t)s->u_io__DOT__lcd_frame,
                            (uint32_t)top->keys, (uint32_t)s->u_io__DOT__a_rate,
                            (uint32_t)s->u_io__DOT__win_id, (uint32_t)drive_size};
        FILE *f = fopen(save_path, "wb");
        if (!f) { perror(save_path); exit(2); }
        fwrite("NGVMCKP1", 1, 8, f);
        fwrite(&t, 8, 1, f); fwrite(&pc, 4, 1, f); fwrite(&cpsr, 4, 1, f);
        fwrite(regs, 4, 32, f); fwrite(spsr, 4, 5, f); fwrite(&us, 8, 1, f); fwrite(dev, 4, 12, f);
        fwrite(ucm.pt, 2, NGVM_PT_ENTRIES, f);
        fwrite(ucm.ram.data(), 1, NGVM_RAM_SIZE, f);
        fwrite(ucm.ksec.data(), 1, NGVM_KSEC_SIZE, f);
        fwrite(ucm.drive.data(), 1, std::min<size_t>(drive_size, NGVM_DRIVE_MAX), f);
        fclose(f);
        printf("[save] %.3f s: pc %08x cpsr %08x, clock %llu us, to %s\n", t, pc, cpsr,
               (unsigned long long)us, save_path);
        save_path = nullptr;
    }

    // after the edge that ends the CPU's reset, before its first clock: the
    // caches sweep their tags for hundreds of cycles first, so a fetch or
    // access that started from a value set here before it settled misses
    void restore_rtl() {
        auto *s = top->rootp->ngvm_sys;
        auto *c = s->u_cpu;
        for (int i = 0; i < 31; i++) c->u_regs->r[i] = ck.regs[i];
        c->cpsr = ck.cpsr;
        c->spsr_fiq = ck.spsr[0]; c->spsr_svc = ck.spsr[1]; c->spsr_abt = ck.spsr[2];
        c->spsr_irq = ck.spsr[3]; c->spsr_und = ck.spsr[4];
        switch (ck.cpsr & 0x1F) {
        case 0x11: c->spsr_cur = ck.spsr[0]; break;
        case 0x13: c->spsr_cur = ck.spsr[1]; break;
        case 0x17: c->spsr_cur = ck.spsr[2]; break;
        case 0x12: c->spsr_cur = ck.spsr[3]; break;
        case 0x1B: c->spsr_cur = ck.spsr[4]; break;
        default:   c->spsr_cur = ck.cpsr; break;
        }
        c->f1_pc = ck.pc & ~1u;
        c->f1_thumb = ck.cpsr >> 5 & 1;
        for (uint32_t i = 0; i < NGVM_PT_ENTRIES; i++) s->u_mmu__DOT__pt[i] = ck.pt[i];
        s->u_io__DOT__us = ck.us;
        s->u_io__DOT__us_frac = 0;
        s->u_io__DOT__status = ck.irq_status & 3;          // timer, vblank; audio is a level
        s->u_io__DOT__enable = ck.irq_enable;
        s->u_io__DOT__cmp = ck.timer_cmp;
        s->u_io__DOT__armed = ck.timer_armed & 1;
        s->u_io__DOT__hi_latch = ck.hi_latch;
        s->u_io__DOT__lcd_base = ck.lcd_base;
        s->u_io__DOT__lcd_on = ck.lcd_ctrl & 1;
        s->u_io__DOT__lcd_frame = ck.frames;
        s->u_io__DOT__a_rate = ck.audio_rate ? ck.audio_rate : 8000;
        s->u_io__DOT__win_id = ck.win_id & 0x3F;
    }
    void uc_restore() {
        static const int R[15] = {UC_ARM_REG_R0, UC_ARM_REG_R1, UC_ARM_REG_R2, UC_ARM_REG_R3,
            UC_ARM_REG_R4, UC_ARM_REG_R5, UC_ARM_REG_R6, UC_ARM_REG_R7, UC_ARM_REG_R8,
            UC_ARM_REG_R9, UC_ARM_REG_R10, UC_ARM_REG_R11, UC_ARM_REG_R12, UC_ARM_REG_R13, UC_ARM_REG_R14};
        // each mode's bank in turn (Unicorn banks on a write of the CPSR), as ngvm.py's save
        static const struct { uint32_t mode; int lo, hi, phys, spsr; } banks[] = {
            {0x1F, 0, 14, 0, -1}, {0x11, 8, 14, 16, 0}, {0x13, 13, 14, 23, 1},
            {0x17, 13, 14, 25, 2}, {0x12, 13, 14, 27, 3}, {0x1B, 13, 14, 29, 4}};
        for (auto &b : banks) {
            uint32_t m = (ck.cpsr & ~0x1Fu) | b.mode;
            uc_reg_write(uc, UC_ARM_REG_CPSR, &m);
            for (int r = b.lo; r <= b.hi; r++) uc_reg_write(uc, R[r], &ck.regs[b.phys + r - b.lo]);
            if (b.spsr >= 0) uc_reg_write(uc, UC_ARM_REG_SPSR, &ck.spsr[b.spsr]);
        }
        uc_reg_write(uc, UC_ARM_REG_CPSR, &ck.cpsr);
        uint32_t pc = ck.pc & ~1u;
        uc_reg_write(uc, UC_ARM_REG_PC, &pc);
        for (uint32_t i = 0; i < NGVM_PT_ENTRIES; i++)
            if (ck.pt[i] != NGVM_PT_NONE) uc_pt_set(i, ck.pt[i]);
        uc_next_pc = pc;
        have_next = true;
    }

    // the LCD as the gateware shows it: the bus memory as it was when the
    // D-cache had written back what IO_LCD_SHOW asked for (lcd_show_t)
    std::vector<uint16_t> shown = std::vector<uint16_t>(LCD_W * LCD_H, 0);
    bool show_d = false;
    uint64_t shows = 0;                      // IO_LCD_SHOWs taken: the game's screen updates
    // the audio FIFO's output: samples played, those not silent, the first of them
    bool snd_d = false;
    uint64_t snd_n = 0, snd_loud = 0, snd_first = 0;
    std::map<uint32_t, uint64_t> watch;      // --watch-pc: retirements of each
    void take_frame() {
        uint32_t base = top->lcd_base;
        if (base - NGVM_PHYS_BASE >= NGVM_RAM_SIZE) return;
        for (int i = 0; i < LCD_W * LCD_H; i++) {
            uint8_t *q = bus_at(base - NGVM_PHYS_BASE + i * 2);
            shown[i] = q[0] | q[1] << 8;
        }
    }
    void dump_frame() {
        char path[512];
        snprintf(path, sizeof path, "%s/f%05llu.ppm", frames_to, (unsigned long long)frames);
        FILE *f = fopen(path, "wb");
        if (!f) { perror(path); return; }
        fprintf(f, "P6\n%d %d\n255\n", LCD_W, LCD_H);
        for (int y = 0; y < LCD_H; y++)
            for (int x = 0; x < LCD_W; x++) {
                uint16_t p = top->lcd_on ? shown[y * LCD_W + x] : 0;
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
        if (rt && !watch.empty()) {
            auto w = watch.find(r.pc & ~1u);
            if (w != watch.end() && w->second++ < 20)
                printf("[watch] %08x at %.6f s\n", w->first, vt());
        }
        if (top->io_rd) io_reads.push_back({(uint32_t)top->io_rd_off * 4, top->io_rd_data});
        if (top->io_rd && top->io_rd_off * 4 == IO_KEYMAP && !keymap_seen) {
            keymap_seen = true;            // the menu's setting, as the kernel first reads it
            printf("[keymap] IO_KEYMAP reads %06x at %.6f s\n", top->io_rd_data, vt());
        }
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
        if (restore_pending && !top->rootp->ngvm_sys->cpu_rst) {
            restore_rtl();
            restore_pending = false;
            printf("[restore] the CPU starts at cycle %llu\n", (unsigned long long)cycles);
        }

        // a fetch: asked, then answered
        if (top->fetch_t != fetch_seen) {
            fetch_seen = top->fetch_t;
            f_src = top->fetch_src; f_dst = top->fetch_dst; f_len = top->fetch_len;
            fetch_end = cycles + CPU_HZ / 1000 + (uint64_t)f_len * CPU_HZ / 4000000;
        }
        if (cycles == fetch_end && fetch_fail >= 0 && !fetches) {
            fetch_end = ~0ull;
            fetches++;
            if (fetch_fail) { top->fetch_err = fetch_fail; top->fetch_done_t = fetch_seen; }
            printf("[fetch] the first answered %s\n", fetch_fail ? ("with error " + std::to_string(fetch_fail)).c_str() : "never");
        }
        if (cycles == fetch_end) {
            fetch_end = ~0ull;
            if ((f_src | f_dst | f_len) & 3 || (uint64_t)f_src + f_len > image.size() || (uint64_t)f_dst + f_len > NGVM_DRIVE_MAX) {
                printf("[fetch] FAIL  %x bytes from %x to %x: not a span of the image and the window\n", f_len, f_src, f_dst);
                top->fetch_err = 2;
            } else {
                memcpy(&cram[f_dst], &image[f_src], f_len);
                memcpy(&ucm.drive[f_dst], &image[f_src], f_len);
                if (uc) uc_ctl_remove_cache(uc, NGVM_DRIVE_BASE + f_dst, NGVM_DRIVE_BASE + f_dst + f_len);
                top->fetch_err = 0;
            }
            top->fetch_done_t = fetch_seen;
            fetches++;
        }

        // the bus
        top->bus_done = 0;
        if (bus_hold) { if (!breq) bus_hold = false; }
        else if (bus_t < 0 && breq && cycles >= mem_busy) {
            uint32_t cmd = top->bus_cmd;
            bus_t = 0; bus_got = 0;
            bus_lat = cmd == 1 || cmd == 2 ? (cmd == 1 ? lat_line : lat_word) : lat_line;
            // a write-back to the line being read goes first
            if (cmd == 3 && (top->bus_waddr << 5) == (top->bus_addr & ~31u)) write_back();
        } else if (bus_t >= 0) {
            bus_t++;
            uint32_t a = top->bus_addr, cmd = top->bus_cmd;
            if (cmd == 0 || cmd == 3)
                while (bus_got < 8 && bus_t >= word_at(bus_got)) {
                    int w = (a >> 2) + bus_got & 7;
                    memcpy(&top->bus_rdata[w], bus_at((a & ~31u) + 4 * w), 4);
                    bus_got++;
                    bus_cnt = (bus_cnt + 1) & 15;
                }
            if (bus_t >= bus_lat) {
                nbus[cmd]++;
                uint8_t *p = bus_at(a);
                switch (cmd) {
                case 1:
                    for (int i = 0; i < 32; i++)
                        if (top->bus_be >> i & 1) p[i] = (uint8_t)(top->bus_wdata[i / 4] >> (8 * (i % 4)));
                    break;
                case 2: memcpy(&top->bus_rdata[0], p, 4); break;
                case 3:
                    nbus[0]++; nbus[1]++;
                    if ((top->bus_waddr << 5) != (a & ~31u)) write_back();
                    mem_busy = cycles + lat_line * 3 / 4;
                    break;
                }
                top->bus_done = 1;
                bus_t = -1;
                bus_hold = true;
            }
        }
        top->bus_cnt = bus_cnt;

        // frames, keys
        if (top->lcd_show_t != show_d) { show_d = top->lcd_show_t; take_frame(); shows++; }
        if (top->snd_tog != snd_d) {
            snd_d = top->snd_tog;
            snd_n++;
            if (top->snd && !snd_loud++) snd_first = cycles;
        }
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

        if (cycles >= prof_from) {
            profile();
            if (rt && !r.irq) charge(r.pc == idle_pc);
        }
        if (rt) {
            if (!retire(r)) { failed = true; return false; }
            if (!r.irq && r.pc == idle_pc) idle_retired++;
            if (save_path && (r.irq || r.pc == idle_pc) && !bl_merged && fetch_end == ~0ull && vt() >= save_s)
                save_ckpt();
        }

        top->clk = 0;
        top->eval();
        return exit_code < 0;
    }
};

int main(int argc, char **argv)
{
    Verilated::commandArgs(argc, argv);
    const char *rom = nullptr, *kernel = "build/kernel/kernel.elf", *drive = nullptr, *restore = nullptr;
    double seconds = 1.0, prof_s = -1;
    uint32_t keymap = 0;
    Bench b;
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        if (a == "--rom" && i + 1 < argc) rom = argv[++i];
        else if (a == "--kernel" && i + 1 < argc) kernel = argv[++i];
        else if (a == "--drive" && i + 1 < argc) drive = argv[++i];
        else if (a == "--seconds" && i + 1 < argc) seconds = atof(argv[++i]);
        else if (a == "--no-uc") b.use_uc = false;
        else if (a == "--profile" && i + 1 < argc) prof_s = atof(argv[++i]);
        else if (a == "--restore" && i + 1 < argc) restore = argv[++i];
        else if (a == "--save-at" && i + 1 < argc) {
            std::string v = argv[++i];
            size_t c = v.find(':');
            if (c == std::string::npos) { fprintf(stderr, "--save-at SECONDS:FILE\n"); return 2; }
            b.save_s = atof(v.substr(0, c).c_str());
            b.save_path = strdup(v.substr(c + 1).c_str());
        }
        else if (a == "--lat" && i + 1 < argc) { b.lat_line = atoi(argv[++i]); b.lat_word = b.lat_line / 2 + 1; }
        else if (a == "--frames-to" && i + 1 < argc) b.frames_to = argv[++i];
        else if (a == "--frame-every" && i + 1 < argc) b.frame_every = atoi(argv[++i]);
        else if (a == "--fetch-fail" && i + 1 < argc) b.fetch_fail = atoi(argv[++i]);
        else if (a == "--watch-pc" && i + 1 < argc) {
            for (char *t = strtok(argv[++i], ","); t; t = strtok(nullptr, ","))
                b.watch[(uint32_t)strtoul(t, nullptr, 16) & ~1u] = 0;
        }
        else if (a == "--keymap" && i + 1 < argc) keymap = (uint32_t)strtoul(argv[++i], nullptr, 16);  // IO_KEYMAP
        else if (a == "--keys" && i + 1 < argc) {
            // "S:MASK S:MASK ...": from S seconds, IO_KEYS reads MASK
            std::string s = argv[++i];
            size_t p = 0;
            while (p < s.size()) {
                size_t q = s.find(' ', p);
                std::string t = s.substr(p, q == std::string::npos ? std::string::npos : q - p);
                size_t c = t.find(':');
                if (c != std::string::npos)
                    b.key_s.push_back({atof(t.substr(0, c).c_str()),
                                       (uint32_t)strtoul(t.substr(c + 1).c_str(), nullptr, 0)});
                if (q == std::string::npos) break;
                p = q + 1;
            }
        }
        else if (a[0] != '+') { fprintf(stderr, "unknown argument %s\n", argv[i]); return 2; }
    }
    if (!rom) { fprintf(stderr, "usage: %s --rom SYM.ROM [--kernel kernel.elf] [--drive img] [--seconds S]\n", argv[0]); return 2; }

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
        b.image = slurp(drive);
        if (b.image.size() > NGVM_IMAGE_MAX) { fprintf(stderr, "drive image too large\n"); return 2; }
        b.drive_size = b.image.size();
        size_t held = std::min<size_t>(b.drive_size, NGVM_DRIVE_MAX);
        memcpy(b.ucm.drive.data(), b.image.data(), held);
        memcpy(b.cram.data(), b.image.data(), held);
    }
    if (restore) b.load_ckpt(restore);
    if (seconds <= b.t_base) { fprintf(stderr, "--seconds %.3f is not after the checkpoint's %.3f\n", seconds, b.t_base); return 2; }
    b.max_cycles = (uint64_t)((seconds - b.t_base) * CPU_HZ);
    if (prof_s >= 0) b.prof_from = prof_s > b.t_base ? (uint64_t)((prof_s - b.t_base) * CPU_HZ) : 0;
    uint32_t keys0 = 0;                     // the keys held at the start
    for (auto &k : b.key_s) {
        if (k.first <= b.t_base) keys0 = k.second;
        else b.keys.push_back({(uint64_t)((k.first - b.t_base) * CPU_HZ), k.second});
    }
    if (b.use_uc) {
        b.uc_init();
        if (restore) b.uc_restore();
    } else if (b.save_path) { fprintf(stderr, "--save-at takes its machine from Unicorn: not with --no-uc\n"); return 2; }

    b.top = new Vngvm_sys;
    b.top->rom_size = (uint32_t)b.rom_size;
    b.top->drive_size = (uint32_t)b.drive_size;
    b.top->fetch_done_t = 0; b.top->fetch_err = 0;
    b.top->keys = keys0;
    b.top->keymap = keymap;
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
            fprintf(stderr, "[%.2f s: %llu instructions (%llu idle), %llu line reads, %llu line writes, %llu word reads, %llu screen updates, %llu fetches]\n",
                    b.vt(), (unsigned long long)b.retired, (unsigned long long)b.idle_retired,
                    (unsigned long long)b.nbus[0], (unsigned long long)b.nbus[1],
                    (unsigned long long)b.nbus[2], (unsigned long long)b.shows, (unsigned long long)b.fetches);
        }
        if (b.cycles > 100000 && b.hist.empty()) { fprintf(stderr, "nothing retires\n"); return 1; }
    }
    if (b.exit_code >= 0 && b.frames_to) b.dump_frame();     // what the screen was left showing
    bool ok = !b.failed && (b.exit_code < 0 || b.exit_code == 0);
    double host = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
    printf("%s: %.3f s at %d MHz; %llu instructions in %llu cycles (%llu in the idle loop); "
           "bus: %llu line reads, %llu line writes (%llu behind a fill), %llu word reads; %.0f s on the host%s\n",
           ok ? "ok" : "stopped", b.vt(), (int)(CPU_HZ / 1000000),
           (unsigned long long)b.retired, (unsigned long long)b.cycles, (unsigned long long)b.idle_retired,
           (unsigned long long)b.nbus[0], (unsigned long long)b.nbus[1], (unsigned long long)b.nbus[3],
           (unsigned long long)b.nbus[2],
           host, b.use_uc ? ", lockstep with Unicorn" : "");
    if (Bench::n_invalid)
        printf("%llu user-mode MOVS pc / LDM ^ met, run by the RTL as plain writes to pc\n", Bench::n_invalid);
    for (auto &w : b.watch) printf("[watch] %08x retired %llu times\n", w.first, (unsigned long long)w.second);
    if (b.prof_from != UINT64_MAX) b.print_profile();
    if (b.fetches) printf("drive: %llu fetches from the image beyond the window\n", (unsigned long long)b.fetches);
    printf("audio: %llu samples played, %llu not silent", (unsigned long long)b.snd_n, (unsigned long long)b.snd_loud);
    if (b.snd_loud) printf(", the first at %.3f s", b.t_base + (double)b.snd_first / CPU_HZ);
    printf("\n");
    delete b.top;
    return ok && !b.mismatches ? 0 : 1;
}
