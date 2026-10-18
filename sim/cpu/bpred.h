// Branch prediction, measured on the instruction stream the RTL retires:
// what each scheme would cost, in cycles lost per instruction, without
// building it.  The costs are the pipeline's (arm_cpu.sv): a redirect from
// D loses 2 cycles, from E 3, from M 4.
//
//   now     what arm_cpu.sv does: unconditional B/BL redirect in D, the rest
//           in E (conditional B, BX, ALU to PC) or M (loads to PC)
//   btfn    as now, but a conditional branch backwards is taken in D and
//           undone in E if it falls through
//   btbN/k  btfn, plus an N-entry direct-mapped branch target buffer read in
//           F1 with 2-bit counters and an 8-deep return stack; a correct
//           prediction loses k cycles (0: the target goes straight back to
//           F1; 1: one cycle later), a wrong one what the resolving stage
//           loses
#pragma once
#include <cstdint>
#include <cstdio>
#include <vector>

struct BPred {
    enum Kind { NONE, UB, CB, RET, IND };
    struct Br { Kind kind; int stage; bool link; uint32_t target; };   // stage: 1 D, 2 E, 3 M

    static Br classify(uint32_t pc, uint32_t in, bool thumb) {
        Br b = {NONE, 2, false, 0};
        if (thumb) {
            uint32_t h = in & 0xffff;
            if ((h & 0xf000) == 0xd000 && (h & 0x0e00) != 0x0e00) {
                b.kind = CB; b.target = pc + 4 + ((uint32_t)(int32_t)(int8_t)(h & 0xff) << 1);
            } else if ((h & 0xf800) == 0xe000) {
                b.kind = UB; b.stage = 1;
                b.target = pc + 4 + ((uint32_t)((int32_t)(h << 21) >> 21) << 1);
            } else if ((h & 0xf800) == 0xf800) {
                b.kind = UB; b.stage = 1; b.link = true;     // target known from the pair only
            } else if ((h & 0xff80) == 0x4700) {
                b.kind = ((h >> 3) & 15) == 14 ? RET : IND;
            } else if ((h & 0xff00) == 0xbd00) {
                b.kind = RET; b.stage = 3;
            } else if ((h & 0xfc00) == 0x4400 && (h & 0x0300) != 0x0100 && (h & 0x0300) != 0x0300
                       && (((h >> 4) & 8) | (h & 7)) == 15) {
                b.kind = IND;
            }
            return b;
        }
        uint32_t cond = in >> 28;
        if (cond == 15) return b;
        if ((in & 0x0e000000) == 0x0a000000) {
            b.kind = cond == 14 ? UB : CB; b.stage = cond == 14 ? 1 : 2;
            b.link = in >> 24 & 1;
            b.target = pc + 8 + ((uint32_t)((int32_t)(in << 8) >> 8) << 2);
        } else if ((in & 0x0ffffff0) == 0x012fff10) {
            b.kind = (in & 15) == 14 ? RET : IND;
        } else if ((in & 0x0e108000) == 0x08108000) {
            b.kind = RET; b.stage = 3;
        } else if ((in & 0x0c10f000) == 0x0410f000) {
            b.kind = IND; b.stage = 3;
        } else if ((in & 0x0c000000) == 0 && ((in >> 12) & 15) == 15
                   && !((in & 0x01900000) == 0x01000000)                 // TST..CMN without S: MRS/MSR/BX
                   && !((in & 0x0e000090) == 0x00000090)) {              // multiply, halfword transfers
            uint32_t op = in >> 21 & 15;
            if (op < 8 || op > 11) b.kind = (in & 0x0fffffff) == 0x01a0f00e ? RET : IND;
        }
        return b;
    }

    struct Btb {
        int n, hit_cost;
        std::vector<uint32_t> tag, tgt;
        std::vector<uint8_t> ctr, ret;
        uint32_t ras[8] = {};
        int sp = 0;
        uint64_t lost = 0;
        Btb(int n, int k) : n(n), hit_cost(k), tag(n, 1), tgt(n), ctr(n), ret(n) {}
    };

    uint64_t n_insns = 0, now = 0, btfn = 0, seen[5] = {}, taken[5] = {};
    std::vector<Btb> btbs;
    bool pend = false;
    uint32_t p_pc, p_in, p_size;
    bool p_thumb;
    uint32_t idle_pc = 0;

    BPred() { for (int n : {16, 64, 256}) for (int k : {0, 1}) btbs.emplace_back(n, k); }

    static int cost(int stage) { return stage == 1 ? 2 : stage == 2 ? 3 : 4; }

    void feed(uint32_t pc, uint32_t in, bool thumb, uint32_t next) {
        Br b = classify(pc, in, thumb);
        bool tk = next != pc + (thumb ? 2 : 4);
        if (b.kind == NONE) return;
        seen[b.kind]++; if (tk) taken[b.kind]++;
        if (b.target == 0) b.target = next;
        uint32_t link = pc + (thumb ? 2 : 4);
        bool back = b.target <= pc;
        // now
        int c_now = tk ? cost(b.stage) : 0;
        now += c_now;
        // btfn
        int c_btfn = c_now;
        if (b.kind == CB && back) c_btfn = tk ? 2 : 3;
        btfn += c_btfn;
        // btb
        for (auto &t : btbs) {
            uint32_t i = (pc >> 1) & (t.n - 1);
            bool hit = t.tag[i] == pc && t.ctr[i] >= 2;
            int c = c_btfn;
            if (hit) {
                uint32_t pred = t.ret[i] ? t.ras[(t.sp - 1) & 7] : t.tgt[i];
                c = tk && pred == next ? t.hit_cost : cost(b.stage);
            }
            t.lost += c;
            if (b.link) { t.ras[t.sp] = link; t.sp = (t.sp + 1) & 7; }
            if (b.kind == RET) t.sp = (t.sp - 1) & 7;
            if (t.tag[i] != pc) {
                if (tk) { t.tag[i] = pc; t.tgt[i] = next; t.ctr[i] = 2; t.ret[i] = b.kind == RET; }
            } else {
                if (tk && t.ctr[i] < 3) t.ctr[i]++;
                if (!tk && t.ctr[i] > 0) t.ctr[i]--;
                if (tk) t.tgt[i] = next;
            }
        }
    }

    // each retired instruction; an IRQ entry in between drops the pending one
    void retire(uint32_t pc, uint32_t in, bool thumb, bool irq) {
        if (irq) { pend = false; return; }
        if (pend) feed(p_pc, p_in, p_thumb, pc);
        pend = pc != idle_pc;
        if (pend) n_insns++;
        p_pc = pc; p_in = in; p_thumb = thumb;
    }

    void report() {
        if (!n_insns) return;
        static const char *kn[5] = {"", "B/BL", "conditional B", "return", "other indirect"};
        printf("branches per instruction (taken):");
        for (int k = 1; k < 5; k++)
            printf(" %s %.3f (%.3f)", kn[k], (double)seen[k] / n_insns, (double)taken[k] / n_insns);
        printf("\ncycles lost to branches per instruction: now %.3f, btfn %.3f",
               (double)now / n_insns, (double)btfn / n_insns);
        for (auto &t : btbs) printf(", btb%d/%d %.3f", t.n, t.hit_cost, (double)t.lost / n_insns);
        printf("\n");
    }
};
