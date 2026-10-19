// Branch prediction, measured on the instruction stream the RTL retires:
// what each scheme would cost, in cycles lost per instruction, without
// building it.  Each branch resolves at a point in the pipeline; a redirect
// from there costs what the pipeline loses refilling behind it.
//
//   six stages (F1 F2 D E M W):        D 2, E 3, M 4
//   eight stages (F1 F2 D1 D2 S A M W): D2 3, A 5, M 6, W 7
//
// where B and BL resolve in D/D2, conditional branches and BX in E/A, ALU
// writes to PC in E (six) or M (eight), loads to PC in M (six) or W
// (eight), and the Thumb BL suffix in E (six) or D2 (eight).
//
//   none    no prediction: every taken branch costs its redirect
//   btbN/k  an N-entry direct-mapped branch target buffer read in F1 with
//           2-bit counters and an 8-deep return stack; a correct prediction
//           loses k cycles (0: the target goes straight back to F1; 1: one
//           cycle later), a wrong one what the resolving stage loses
//   btbN/kB as btbN/k, but only branches and BX are predicted: a load or ALU
//           write to PC always costs its redirect (arm_cpu.sv as built)
#pragma once
#include <cstdint>
#include <cstdio>
#include <vector>

struct BPred {
    enum Kind { NONE, UB, CB, RET, IND };
    enum Point { P_D, P_E, P_ALUPC, P_LDPC, P_BLS, P_NPOINT };
    struct Br { Kind kind; Point at; bool link; uint32_t target; };

    struct Pipe { const char *name; int cost[P_NPOINT]; };
    static constexpr Pipe pipes[2] = {
        {"six stages",   {2, 3, 3, 4, 3}},
        {"eight stages", {3, 5, 6, 7, 3}},
    };

    static Br classify(uint32_t pc, uint32_t in, bool thumb) {
        Br b = {NONE, P_E, false, 0};
        if (thumb) {
            uint32_t h = in & 0xffff;
            if ((h & 0xf000) == 0xd000 && (h & 0x0e00) != 0x0e00) {
                b.kind = CB; b.target = pc + 4 + ((uint32_t)(int32_t)(int8_t)(h & 0xff) << 1);
            } else if ((h & 0xf800) == 0xe000) {
                b.kind = UB; b.at = P_D;
                b.target = pc + 4 + ((uint32_t)((int32_t)(h << 21) >> 21) << 1);
            } else if ((h & 0xf800) == 0xf800) {
                b.kind = UB; b.at = P_BLS; b.link = true;    // target known from the pair only
            } else if ((h & 0xff80) == 0x4700) {
                b.kind = ((h >> 3) & 15) == 14 ? RET : IND;
            } else if ((h & 0xff00) == 0xbd00) {
                b.kind = RET; b.at = P_LDPC;
            } else if ((h & 0xfc00) == 0x4400 && (h & 0x0300) != 0x0100 && (h & 0x0300) != 0x0300
                       && (((h >> 4) & 8) | (h & 7)) == 15) {
                b.kind = IND; b.at = P_ALUPC;
            }
            return b;
        }
        uint32_t cond = in >> 28;
        if (cond == 15) return b;
        if ((in & 0x0e000000) == 0x0a000000) {
            b.kind = cond == 14 ? UB : CB; b.at = cond == 14 ? P_D : P_E;
            b.link = in >> 24 & 1;
            b.target = pc + 8 + ((uint32_t)((int32_t)(in << 8) >> 8) << 2);
        } else if ((in & 0x0ffffff0) == 0x012fff10) {
            b.kind = (in & 15) == 14 ? RET : IND;
        } else if ((in & 0x0e108000) == 0x08108000) {
            b.kind = RET; b.at = P_LDPC;
        } else if ((in & 0x0c10f000) == 0x0410f000) {
            b.kind = IND; b.at = P_LDPC;
        } else if ((in & 0x0c000000) == 0 && ((in >> 12) & 15) == 15
                   && !((in & 0x01900000) == 0x01000000)                 // TST..CMN without S: MRS/MSR/BX
                   && !((in & 0x0e000090) == 0x00000090)) {              // multiply, halfword transfers
            uint32_t op = in >> 21 & 15;
            if (op < 8 || op > 11) { b.kind = (in & 0x0fffffff) == 0x01a0f00e ? RET : IND; b.at = P_ALUPC; }
        }
        return b;
    }

    struct Btb {
        int n, hit_cost;
        bool pc_writes;                 // predict loads and ALU writes to PC too
        std::vector<uint32_t> tag, tgt;
        std::vector<uint8_t> ctr, ret;
        uint32_t ras[8] = {};
        int sp = 0;
        uint64_t lost[2] = {};
        Btb(int n, int k, bool w = true) : n(n), hit_cost(k), pc_writes(w), tag(n, 1), tgt(n), ctr(n), ret(n) {}
    };

    uint64_t n_insns = 0, none[2] = {}, seen[5] = {}, taken[5] = {};
    std::vector<Btb> btbs;
    bool pend = false;
    uint32_t p_pc, p_in;
    bool p_thumb;
    uint32_t idle_pc = 0;

    BPred() {
        for (int n : {64, 256, 1024}) for (int k : {0, 1}) btbs.emplace_back(n, k);
        btbs.emplace_back(256, 0, false);
    }

    void feed(uint32_t pc, uint32_t in, bool thumb, uint32_t next) {
        Br b = classify(pc, in, thumb);
        bool tk = next != pc + (thumb ? 2 : 4);
        if (b.kind == NONE) return;
        seen[b.kind]++; if (tk) taken[b.kind]++;
        if (b.target == 0) b.target = next;
        uint32_t link = pc + (thumb ? 2 : 4);
        for (int p = 0; p < 2; p++) none[p] += tk ? pipes[p].cost[b.at] : 0;
        bool pcw = b.at == P_ALUPC || b.at == P_LDPC;
        for (auto &t : btbs) {
            uint32_t i = (pc >> 1) & (t.n - 1);
            bool predict = t.pc_writes || !pcw;
            bool hit = predict && t.tag[i] == pc && t.ctr[i] >= 2;
            bool right = false;
            if (hit) {
                uint32_t pred = t.ret[i] ? t.ras[(t.sp - 1) & 7] : t.tgt[i];
                right = tk && pred == next;
            }
            for (int p = 0; p < 2; p++) {
                int c = pipes[p].cost[b.at];
                t.lost[p] += hit ? (right ? t.hit_cost : c) : (tk ? c : 0);
            }
            if (b.link) { t.ras[t.sp] = link; t.sp = (t.sp + 1) & 7; }
            if (b.kind == RET) t.sp = (t.sp - 1) & 7;
            if (!predict) continue;
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
        printf("\n");
        for (int p = 0; p < 2; p++) {
            printf("cycles lost to branches per instruction, %s: none %.3f", pipes[p].name,
                   (double)none[p] / n_insns);
            for (auto &t : btbs) printf(", btb%d/%d%s %.3f", t.n, t.hit_cost, t.pc_writes ? "" : "B",
                                        (double)t.lost[p] / n_insns);
            printf("\n");
        }
    }
};
