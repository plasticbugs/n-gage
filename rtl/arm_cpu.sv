//------------------------------------------------------------------------------
// The NGVM CPU: an ARMv4T (ARM and Thumb), eight stages (docs/core-design.md 5).
//
//   F1  the fetch address goes to the instruction memory
//   F2  the word comes back (or "not yet": the fetch is replayed) and joins
//       the instruction buffer
//   D1  Thumb expansion and predecode, from the buffer's head
//   D2  decode, register read, IRQ injection; redirects for B, BL and the
//       Thumb BL pair, whose targets are known here
//   S   forwarding from the registered results of M and W; the shifter
//   A   late forwarding of unshifted operands; ALU, multiply, flags, CPSR
//       and SPSR, addresses; conditional branches, BX, exceptions
//   M   the data memory answers; loads aligned; ALU results to PC redirect
//   W   register write; loads to PC redirect; retirement
//
// Each stage starts from registers.  S cannot see the result of the uop in
// A, so an operand that only A needs (an unshifted register, the base,
// store data) is marked in S and picked up in A from M or W; an operand S
// itself needs (one to shift, a shift amount, a multiplier input) waits in S
// until the value is registered.  A load's value is registered only at W.
//
// Memory ports.  The instruction port is a pipelined read: an address with
// ic_req at a clock edge is answered in the next cycle by ic_ok (ic_data
// valid) or not, in which case the CPU asks again.  The data port is a
// request/complete handshake: a request is taken at an edge where the memory
// is idle or completing (dc_ok); dc_ok then says the oldest request is done
// (a load's word is valid in that cycle: dc_rdata1 if dc_rsel, else
// dc_rdata; a memory with one word leaves dc_rsel low).  ic_abort/dc_abort
// come with ok and mark the access as faulted.
//
// Architectural state changes at A (CPSR, SPSR) and at W (registers), in
// program order; anything younger than a redirect is killed before it
// reaches either.  The retire port gives the bench each instruction as it
// leaves W, with the CPSR it left behind.
//------------------------------------------------------------------------------
`default_nettype none

module arm_cpu
    import arm_pkg::*;
(
    input  logic        clk,
    input  logic        rst,
    input  logic        irq,

    output logic        ic_req,
    output logic [31:0] ic_addr,
    input  logic [31:0] ic_data,
    input  logic        ic_ok,
    input  logic        ic_abort,

    output logic        dc_req,
    output logic        dc_we,
    output logic [31:0] dc_addr,
    output logic [31:0] dc_wdata,
    output logic  [3:0] dc_be,
    output logic  [1:0] dc_size,
    input  logic [31:0] dc_rdata,
    input  logic [31:0] dc_rdata1,
    input  logic        dc_rsel,
    input  logic        dc_ok,
    input  logic        dc_abort,

    output logic        rt_valid,
    output logic        rt_irq,         // this retirement is an IRQ entry, not an instruction
    output logic [31:0] rt_pc,
    output logic [31:0] rt_instr,
    output logic        rt_thumb,
    output logic [31:0] rt_cpsr
);
    // ============================================================ state
    logic [31:0] cpsr /* verilator public */;
    logic [31:0] spsr_fiq, spsr_svc, spsr_abt, spsr_irq, spsr_und;

    function automatic logic [31:0] spsr_of(input logic [4:0] m);
        case (m)
            M_FIQ:   return spsr_fiq;
            M_SVC:   return spsr_svc;
            M_ABT:   return spsr_abt;
            M_IRQ:   return spsr_irq;
            M_UND:   return spsr_und;
            default: return cpsr;       // USR/SYS have none; reads are unpredictable
        endcase
    endfunction

    // The SPSR of the mode CPSR is in, a cycle behind both: its mux on the
    // mode bits was the slowest way into A's result at 80 MHz.  A cycle is
    // enough because every change of mode redirects, and an SPSR write
    // (MSR) holds a reader of it in S until the write is a cycle old.
    logic [31:0] spsr_cur;
    always_ff @(posedge clk) spsr_cur <= spsr_of(cpsr[4:0]);

    function automatic logic cond_ok(input logic [3:0] c, input logic [31:0] psr);
        logic n, z, cf, v;
        n = psr[31]; z = psr[30]; cf = psr[29]; v = psr[28];
        case (c)
            4'h0: return z;          4'h1: return !z;
            4'h2: return cf;         4'h3: return !cf;
            4'h4: return n;          4'h5: return !n;
            4'h6: return v;          4'h7: return !v;
            4'h8: return cf && !z;   4'h9: return !cf || z;
            4'hA: return n == v;     4'hB: return n != v;
            4'hC: return !z && (n == v);
            4'hD: return z || (n != v);
            4'hE: return 1'b1;
            default: return 1'b0;
        endcase
    endfunction

    // redirects, oldest first; each kills everything younger
    logic        w_redirect, m_redirect, a_redirect, d_redirect;
    logic        a_red_ask;                     // A's, before it commits (the BTB's index)
    logic [31:0] w_target, m_target, a_target, d_target;
    logic        w_tthumb, m_tthumb, a_tthumb;
    logic        kill_a, kill_s, kill_d2;       // the stage's uop is gone this cycle
    logic        kill_f;                        // D1, the buffer and F2
    // the return stack's repair by the uop that redirects (below W)
    logic        fix_push;
    logic  [2:0] fix_base, fix_sp;
    logic [31:0] fix_link;
    assign kill_a  = m_redirect || w_redirect;
    assign kill_s  = a_redirect || kill_a;
    assign kill_d2 = kill_s;
    assign kill_f  = d_redirect || kill_d2;

    // ============================================================ F1, F2, buffer
    // The buffer is a ring: an entry stays where F2 put it and D1 reads the
    // one at ib_r, so taking an instruction (the end of D2's handshake, which
    // starts at S's stall) only moves a pointer, and D1's decode starts from
    // flops.
    localparam int IB = 4;                      // instruction buffer entries
    typedef struct packed {
        logic [31:0] word;
        logic [31:0] pc;
        logic        thumb;
        logic        abt;
    } ibe_t;
    // The fetch's prediction for each buffered instruction (uop_t p_*),
    // beside it: D2 is its only reader, so D1's mux does not carry it.
    typedef struct packed {
        logic        ptaken;
        logic [31:0] pnext;
        logic        ptagm;
        logic  [1:0] pctr;
        logic  [2:0] psp;
    } pre_t;
    // flops: plain vectors, because Quartus splits a struct array before it
    // reads the attribute, and then makes it a RAM
    (* ramstyle = "logic" *) logic [$bits(pre_t)-1:0] pr [0:IB-1];
    logic  [1:0] ib_w, ib_r;                    // next to push, D1's
    pre_t        pr_d1;                         // D1's prediction
    assign pr_d1 = pre_t'(pr[ib_r]);
    pre_t        pr_f2;                         // F2's, to push

    logic        f1_thumb;
    logic [31:0] f1_pc;
    logic        f2_valid, f2_thumb;
    logic [31:0] f2_pc;
    logic        f2_ptaken, f2_ptagm;
    logic [31:0] f2_pnext;
    logic  [1:0] f2_pctr;
    logic  [2:0] f2_psp;
    // flops, not a block RAM: a RAM's read data comes late, and Quartus
    // would take its address from ib_r's next value, at the stall's end.
    // Each entry is a register of its own: as an array, even of plain
    // vectors with ramstyle "logic", Quartus made the buffer a block RAM,
    // and the stall chain into its read address was the slowest path at
    // 80 MHz (D-cache r_va -> hit -> stall -> ib_q, -0.283 ns).
    ibe_t        ib [0:IB-1];
    logic        f2_push;
    genvar ie;
    generate
        for (ie = 0; ie < IB; ie = ie + 1) begin : g_ib
            logic [$bits(ibe_t)-1:0] q;
            always_ff @(posedge clk)
                if (f2_push && ib_w == 2'(ie)) q <= {ic_data, f2_pc, f2_thumb, ic_abort};
            assign ib[ie] = ibe_t'(q);
        end
    endgenerate
    logic  [2:0] ib_n;                          // entries held
    logic        f2_miss, f1_go;

    // fetch only what the buffer can always take: what it holds, what is in
    // F2, and this one
    assign f1_go   = {1'b0, ib_n} + {3'd0, f2_valid} < 4'(IB);
    assign ic_req  = f1_go;
    assign ic_addr = {f1_pc[31:2], 2'b00};
    assign f2_push = f2_valid && ic_ok;
    assign f2_miss = f2_valid && !ic_ok;
    assign pr_f2   = '{ptaken: f2_ptaken, pnext: f2_pnext, ptagm: f2_ptagm, pctr: f2_pctr, psp: f2_psp};

    // ---- branch prediction: a BTB answering in F1's own cycle, and a return stack
    // The BTB is indexed by pc[BI:1] and read at the edge that loads f1_pc,
    // with f1_pc's next value (f1_bi, after M), so its entry for f1_pc is
    // there while F1 holds it.  A hit whose counter says taken sends F1 to
    // the stored target, or for a return to the return stack's top.  Every
    // prediction is checked downstream: direct branches in A, BX in A with
    // the redirect from M.
    // Loads and ALU writes to PC are not predicted (docs/core-design.md 5.6).
    localparam int BI   = 9;                    // index bits: pc[BI:1]
    localparam int BT   = 16;                   // tag bits: pc[BI+BT:BI+1]
    localparam int BTBN = 1 << BI;
    // A partial tag: a false hit is a prediction A finds wrong and refetches
    // after, as one on code another process has at the same address.  16 bits
    // compare in the two LUT levels 8 did, and the entry fits the same three
    // block RAMs; 8 aliased code 256 KB apart, 0.7% of Tony Hawk's play.
    typedef struct packed {
        logic [BT-1:0] tag;                     // pc[BI+BT:BI+1]
        logic [31:0] tgt;                       // {address[31:1], Thumb}
        logic  [1:0] kind;                      // BK_*
    } btbe_t;
    btbe_t       btb_e [0:BTBN-1];
    logic  [1:0] btb_c [0:BTBN-1];              // counters, apart, so a branch not taken
                                                // can count down without the target
    initial for (int e = 0; e < BTBN; e++) begin btb_e[e] = '0; btb_c[e] = 2'd0; end
    btbe_t       bq;                            // the entry for f1_pc
    logic  [1:0] bc;
    logic        bmis;                          // ... or for another: read for a redirect that did not go
    logic [31:0] ras [0:7];                     // return addresses, as LR holds them
    logic  [2:0] ras_sp;                        // pushes less pops, mod 8: the top is ras_sp - 1
    logic        rfix_v;                        // a redirect's push, written a cycle late
    logic  [2:0] rfix_base;
    logic [31:0] rfix_link;

    logic [31:0] f1_seq, f1_pnext, f1_pc_n;
    logic        f1_thumb_n, f1_tagm, f1_hit, any_redirect;
    assign f1_seq   = f1_pc + (f1_thumb ? 32'd2 : 32'd4);
    assign f1_tagm  = bq.tag == f1_pc[BI+BT:BI+1];
    assign f1_hit   = f1_tagm && bc[1] && !bmis;
    assign f1_pnext = bq.kind == BK_RET ? ras[ras_sp - 3'd1] : bq.tgt;
    assign any_redirect = w_redirect || m_redirect || a_redirect || d_redirect;

    always_comb begin
        f1_pc_n = f1_pc; f1_thumb_n = f1_thumb;
        if (rst) begin
            f1_pc_n = 32'd0; f1_thumb_n = 1'b0;
        end else if (any_redirect) begin
            f1_pc_n    = w_redirect ? w_target : m_redirect ? m_target : a_redirect ? a_target : d_target;
            f1_thumb_n = w_redirect ? w_tthumb : m_redirect ? m_tthumb : a_redirect ? a_tthumb : d2_thumb;
        end else if (f2_miss) begin                     // ask again for the one that missed
            f1_pc_n = f2_pc; f1_thumb_n = f2_thumb;
        end else if (f1_go) begin
            if (f1_hit) begin
                f1_pc_n = {f1_pnext[31:1], 1'b0}; f1_thumb_n = f1_pnext[0];
            end else f1_pc_n = f1_seq;
        end
    end

    // ============================================================ D1
    logic [15:0] d1_half;
    logic [31:0] t_arm, t_imm, d1_arm, d1_pc_op;
    logic        t_imm_en, t_align, t_bl, t_und;
    ibe_t        d1;
    assign d1      = ib[ib_r];
    assign d1_half = d1.pc[1] ? d1.word[31:16] : d1.word[15:0];
    arm_thumb u_thumb (
        .t(d1_half), .arm(t_arm), .imm_ovr_en(t_imm_en), .imm_ovr(t_imm),
        .pc_align(t_align), .bl_suffix(t_bl), .und(t_und)
    );
    assign d1_arm   = d1.thumb ? t_arm : d1.word;
    assign d1_pc_op = d1.thumb ? ((d1.pc + 32'd4) & (t_align ? 32'hFFFF_FFFC : 32'hFFFF_FFFF))
                               : d1.pc + 32'd8;

    // predecode: what D2 must know without waiting for the decoder
    function automatic logic [3:0] popcount8(input logic [7:0] x);  // a tree: pairs, nibbles
        logic [1:0] p0, p1, p2, p3;
        logic [2:0] n0, n1;
        p0 = {1'b0, x[0]} + {1'b0, x[1]};
        p1 = {1'b0, x[2]} + {1'b0, x[3]};
        p2 = {1'b0, x[4]} + {1'b0, x[5]};
        p3 = {1'b0, x[6]} + {1'b0, x[7]};
        n0 = {1'b0, p0} + {1'b0, p1};
        n1 = {1'b0, p2} + {1'b0, p3};
        return {1'b0, n0} + {1'b0, n1};
    endfunction
    function automatic logic two_or_more(input logic [15:0] x);  // no adder: by nibbles
        logic [3:0] any, two;
        for (int i = 0; i < 4; i++) begin
            any[i] = x[4*i +: 4] != 4'd0;
            two[i] = (x[4*i +: 4] & (x[4*i +: 4] - 4'd1)) != 4'd0;
        end
        return two != 4'd0 || (any & (any - 4'd1)) != 4'd0;
    endfunction
    function automatic logic [3:0] lowest(input logic [15:0] x);
        logic [3:0] l;
        l = 4'd0;
        for (int i = 15; i >= 0; i--) if (x[i]) l = i[3:0];
        return l;
    endfunction

    // The register list of an LDM/STM and its figures, for every buffer
    // entry beside the ring, so that D1's read of the ring comes after them:
    // the read, the Thumb half and the priority encoder in a row were the
    // slowest way to d2_ixl at 80 MHz.  Thumb's list comes from the raw
    // halfword (PUSH and POP add LR or PC), not through the expansion.  An
    // LDM/STM ^ without PC in the list moves user-bank registers.  (Don't
    // care for anything else.)
    logic  [3:0] ls_low  [0:IB-1];              // the lowest register in the list
    logic  [4:0] ls_ix   [0:IB-1];              // ... its register-file index
    logic  [4:0] ls_cnt  [0:IB-1];              // how many the list holds
    logic        ls_more [0:IB-1];              // two or more
    logic [15:0] ls_rest [0:IB-1];              // the list without the lowest
    logic  [4:0] ls_mode [0:IB-1];              // the mode its registers are in
    genvar gi;
    generate
        for (gi = 0; gi < IB; gi = gi + 1) begin : g_ls
            wire [15:0] h  = ib[gi].pc[1] ? ib[gi].word[31:16] : ib[gi].word[15:0];
            wire        pu = h[15:9] == 7'b1011_010;
            wire        po = h[15:9] == 7'b1011_110;
            wire [15:0] l  = ib[gi].thumb ? {po && h[8], pu && h[8], 6'd0, h[7:0]} : ib[gi].word[15:0];
            assign ls_mode[gi] = !ib[gi].thumb && ib[gi].word[22] && !(ib[gi].word[20] && ib[gi].word[15])
                               ? M_USR : cpsr[4:0];
            assign ls_low[gi]  = lowest(l);
            assign ls_ix[gi]   = phys(lowest(l), ls_mode[gi]);
            // the count from the word's bytes, so no mux stands in front of
            // the adders (Thumb's halfword and list through popcount16 were
            // 50 ps too slow into d2_nregs at 80 MHz): ARM's list is bytes 0
            // and 1, Thumb's the low byte of its halfword, and LR or PC
            wire [3:0] c0 = popcount8(ib[gi].word[7:0]);
            wire [3:0] c1 = popcount8(ib[gi].word[15:8]);
            wire [3:0] c2 = popcount8(ib[gi].word[23:16]);
            wire [3:0] ca = ib[gi].thumb && ib[gi].pc[1] ? c2 : c0;
            wire [3:0] cb = ib[gi].thumb ? {3'd0, (pu || po) && h[8]} : c1;
            assign ls_cnt[gi]  = {1'b0, ca} + {1'b0, cb};
            assign ls_more[gi] = two_or_more(l);
            assign ls_rest[gi] = l & (l - 16'd1);
        end
    endgenerate

    logic d1_plain, d1_ub, d1_blp, d1_lsm, d1_swp, d1_mlal;
    always_comb begin
        d1_plain = !d1.abt && !(d1.thumb && (t_und || t_bl)) && d1_arm[31:28] != 4'hF;
        d1_ub    = d1_plain && d1_arm[31:25] == 7'b1110_101;                 // B, BL always
        d1_blp   = d1.thumb && d1_half[15:11] == 5'b11110;                    // Thumb BL prefix
        d1_lsm   = d1_plain && d1_arm[27:25] == 3'b100;
        d1_swp   = d1_plain && d1_arm[27:23] == 5'b00010 && d1_arm[21:20] == 2'b00
                   && d1_arm[11:4] == 8'b0000_1001;
        d1_mlal  = d1_plain && d1_arm[27:23] == 5'b00001 && d1_arm[7:4] == 4'b1001 && d1_arm[21];
    end

    // the operand ports of the first step (see D2's ra_pc..sel_c); Quartus
    // keeps only these outputs of this decoder
    logic        d1_ra_pc, d1_rb_pc, d1_rc_pc, d1_sel_a_rd, d1_sel_b_31;
    logic  [2:0] d1_sel_c;
    uop_t        d1_u_x;
    logic        d1_more_x;
    logic [15:0] d1_rem_x;
    arm_decode u_dec1 (
        .instr(d1_arm), .thumb(d1.thumb), .thumb_raw(d1_half),
        .imm_ovr_en(d1.thumb && t_imm_en), .imm_ovr(t_imm),
        .bl_suffix(d1.thumb && t_bl), .t_und(d1.thumb && t_und), .pabt(d1.abt),
        .pc(d1.pc), .pc_op(d1_pc_op), .mode(cpsr[4:0]),
        .step(2'd0), .rem(16'd0), .k(5'd0), .lreg(ls_low[ib_r]), .nregs(ls_cnt[ib_r]),
        .u(d1_u_x), .ra_pc(d1_ra_pc), .rb_pc(d1_rb_pc), .rc_pc(d1_rc_pc),
        .more(d1_more_x), .rem_next(d1_rem_x),
        .sel_a_rd(d1_sel_a_rd), .sel_b_31(d1_sel_b_31), .sel_c(d1_sel_c)
    );

    // ============================================================ D2
    logic        d2_valid, d2_thumb, d2_abt;
    logic [31:0] d2_pc, d2_arm, d2_pc_op, d2_imm;
    logic [31:0] d2_link;                       // d2_pc's return address, for the stack's repair
    logic [15:0] d2_half;
    logic        d2_imm_en, d2_bl, d2_und;
    logic        d2_ub, d2_blp, d2_lsm, d2_swp, d2_mlal, d2_red_done;
    logic  [3:0] d2_lreg;                       // the register this LDM/STM step moves
    logic  [4:0] d2_nregs;                      // ... and how many the list holds
    logic        d2_lmore;                      // ... and whether another step follows
    logic [15:0] d2_rest;                       // ... and the list after this step
    logic  [4:0] d2_mode;                       // the mode D2 decodes in: CPSR's as the uop arrived
    logic  [4:0] d2_lmode;                      // ... and the LDM/STM register's: user for ^ without PC
    logic  [4:0] d2_ixn, d2_ixm, d2_ixs, d2_ixd, d2_ixl;   // register-file indices, from D1
    logic        d2_ptaken, d2_ptagm;           // the fetch's prediction
    logic [31:0] d2_pnext;
    logic  [1:0] d2_pctr;
    logic  [2:0] d2_psp;
    logic  [1:0] d2_step;
    logic  [4:0] d2_k;
    logic [15:0] d2_rem;
    logic        d2_after_blp;                  // the uop issued before this one was a BL prefix
    logic [31:0] d2_blp_lr;                     // ... and this is the LR it computes

    logic        d2_first;
    assign d2_first = d2_step == 2'd0 && d2_k == 5'd0;

    uop_t        dec_u;
    logic        dec_ra_pc, dec_rb_pc, dec_rc_pc, dec_more;
    logic [15:0] dec_rem_next, d2_rem_cur;
    logic        dec_sel_a_rd, dec_sel_b_31;
    logic  [2:0] dec_sel_c;
    assign d2_rem_cur = d2_first ? d2_arm[15:0] : d2_rem;
    arm_decode u_dec (
        .instr(d2_arm), .thumb(d2_thumb), .thumb_raw(d2_half),
        .imm_ovr_en(d2_imm_en), .imm_ovr(d2_imm),
        .bl_suffix(d2_bl), .t_und(d2_und), .pabt(d2_abt),
        .pc(d2_pc), .pc_op(d2_pc_op), .mode(d2_mode),
        .step(d2_step), .rem(d2_rem_cur), .k(d2_k), .lreg(d2_lreg), .nregs(d2_nregs),
        .u(dec_u), .ra_pc(dec_ra_pc), .rb_pc(dec_rb_pc), .rc_pc(dec_rc_pc),
        .more(dec_more), .rem_next(dec_rem_next),
        .sel_a_rd(dec_sel_a_rd), .sel_b_31(dec_sel_b_31), .sel_c(dec_sel_c)
    );

    // Which port each operand reads, and whether it is R15, in flops: D1
    // decodes them for the first step (u_dec1) and D2 moves them for the
    // rest, as it moves the step registers.  Through D2's decoder, from the
    // step registers to the operand muxes, they were the slowest way into
    // s_u.c at 80 MHz.  They are what the decoder says (asserted below).
    logic        ra_pc, rb_pc, rc_pc, sel_a_rd, sel_b_31;
    logic  [2:0] sel_c;
`ifdef VERILATOR
    always_ff @(posedge clk)
        if (!rst && d2_valid && {ra_pc, rb_pc, rc_pc, sel_a_rd, sel_b_31, sel_c}
                             != {dec_ra_pc, dec_rb_pc, dec_rc_pc, dec_sel_a_rd, dec_sel_b_31, dec_sel_c})
            $error("arm_cpu: D2's operand ports disagree with the decoder at %08x", d2_pc);
`endif

    // the last step, from registers rather than through the decoder
    logic d2_more;
    always_comb begin
        if (d2_lsm)       d2_more = d2_lmore;
        else if (d2_swp)  d2_more = d2_step != 2'd2;
        else if (d2_mlal) d2_more = d2_step == 2'd0;
        else              d2_more = 1'b0;
    end
`ifdef VERILATOR
    always_ff @(posedge clk)
        if (!rst && d2_valid && d2_more != dec_more)
            $error("arm_cpu: D2's last step disagrees with the decoder at %08x", d2_pc);
`endif

    // register file: read in D2 by the instruction's fields, written at W
    logic [31:0] qa, qb, qc, qn, qm, qs, qd, ql, q31;
    logic  [4:0] ix_n, ix_m, ix_s, ix_d, ix_l;
    logic        rf_wa_en, rf_wb_en;
    logic  [4:0] rf_wa, rf_wb;
    logic [31:0] rf_da, rf_db;
    // The indices are worked out in D1, in the mode of that moment.  Every
    // change of mode (MSR to the control field, an exception, a return from
    // one) redirects and so kills D2, so no uop that survives sees a stale one.
    assign ix_n = d2_ixn;
    assign ix_m = d2_ixm;
    assign ix_s = d2_ixs;
    assign ix_d = d2_ixd;
    assign ix_l = d2_ixl;
    arm_regs u_regs (
        .clk(clk),
        .rn(ix_n), .rm(ix_m), .rs(ix_s), .rd(ix_d), .rl(ix_l),
        .qn(qn), .qm(qm), .qs(qs), .qd(qd), .ql(ql), .q31(q31),
        .wa_en(rf_wa_en), .wa(rf_wa), .da(rf_da),
        .wb_en(rf_wb_en), .wb(rf_wb), .db(rf_db)
    );
    always_comb begin
        qa = sel_a_rd ? qd : qn;
        qb = sel_b_31 ? q31 : qm;
        case (sel_c)
            SC_RD:   qc = qd;
            SC_RM:   qc = qm;
            SC_RN:   qc = qn;
            SC_RL:   qc = ql;
            default: qc = qs;
        endcase
    end
`ifdef VERILATOR
    // each port read the register the decoder named
    always_ff @(posedge clk)
        if (!rst && d2_valid && !d2_inject) begin
            if (dec_u.ra_rd && !ra_pc && dec_u.ra != (sel_a_rd ? ix_d : ix_n))
                $error("arm_cpu: operand a read the wrong port at %08x", d2_pc);
            if (dec_u.rb_rd && !rb_pc && dec_u.rb != (sel_b_31 ? 5'd31 : ix_m))
                $error("arm_cpu: operand b read the wrong port at %08x", d2_pc);
            if (dec_u.rc_rd && !rc_pc && dec_u.rc != (sel_c == SC_RD ? ix_d : sel_c == SC_RM ? ix_m :
                                                      sel_c == SC_RN ? ix_n : sel_c == SC_RL ? ix_l : ix_s))
                $error("arm_cpu: operand c read the wrong port at %08x", d2_pc);
        end
`endif

    // the uop D2 offers: the decoded step, or an IRQ in place of a new instruction
    uop_t d2_u;
    logic d2_bls;                               // a Thumb BL suffix straight after its prefix
    // *_nk: the same handshakes without the kills.  Data registers load on
    // those; a kill only clears valid bits, so it reaches a few flops rather
    // than every enable in D1, D2, S and A.
    logic d2_inject, d2_last, d2_issue, d2_free, d1_take;
    logic d2_issue_nk, d2_free_nk, d1_take_nk;
    logic s_free, s_free_nk;
    always_comb begin
        // never between the halves of a Thumb BL (QEMU, and so the bench, runs
        // the pair as one instruction; ARM allows either)
        d2_inject = d2_valid && d2_first && irq && !cpsr[7] && !d2_after_blp;
        d2_u = dec_u;
        d2_u.a = ra_pc ? d2_pc_op : qa;
        d2_u.b = rb_pc ? d2_pc_op : qb;
        d2_u.c = rc_pc ? d2_pc_op : qc;
        if (ra_pc) d2_u.ra_rd = 1'b0;
        if (rb_pc) d2_u.rb_rd = 1'b0;
        if (rc_pc) d2_u.rc_rd = 1'b0;
        // a Thumb BL pair seen whole is a plain BL from here on
        if (d2_bls) begin d2_u.imm = d_target; d2_u.ra_rd = 1'b0; end
        d2_u.p_taken = d2_ptaken && !d2_more;
        d2_u.p_next  = d2_pnext;
        d2_u.p_tagm  = d2_ptagm;
        d2_u.p_ctr   = d2_pctr;
        d2_u.p_sp    = d2_psp;
        d2_u.br_call = dec_u.kind == K_BRANCH && dec_u.wa_en;
        d2_u.br_ret  = (dec_u.kind == K_BX && d2_arm[3:0] == 4'hE)
                    || d2_arm[27:0] == 28'h1A0_F00E                       // MOV pc, lr
                    || (d2_lsm && d2_arm[20] && d2_arm[15]);              // LDM, POP with pc
        if (d2_inject) begin
            d2_u = '0;
            d2_u.valid = 1'b1;
            d2_u.pc = d2_pc; d2_u.thumb = d2_thumb;
            d2_u.first = 1'b1; d2_u.last = 1'b1;
            d2_u.cond = 4'hE;
            d2_u.kind = K_EXC;
            d2_u.exc_vec = 3'd6; d2_u.exc_mode = M_IRQ;
            d2_u.exc_lr = d2_pc + 32'd4; d2_u.exc_lr_reg = 5'd28;
            d2_u.irq = 1'b1;
            d2_u.p_sp = d2_psp;
        end
    end
    assign d2_last     = d2_inject || !d2_more;
    assign d2_issue_nk = d2_valid && s_free_nk;
    assign d2_free_nk  = !d2_valid || (d2_issue_nk && d2_last);
    assign d1_take_nk  = ib_n != 3'd0 && d2_free_nk;
    assign d2_issue    = d2_issue_nk && !kill_d2;
    assign d2_free     = !d2_valid || (d2_issue && d2_last);
    assign d1_take     = ib_n != 3'd0 && d2_free && !kill_f;

    // B and BL redirect from here; so does a Thumb BL suffix straight after
    // its prefix, whose LR D2 computed as the prefix went by
    assign d2_bls     = d2_bl && d2_after_blp;
    assign d_redirect = d2_valid && !d2_red_done && (d2_ub || d2_bls) && !d2_ptaken && !kill_d2;
    assign d_target   = d2_bls ? ((d2_blp_lr + d2_imm) & 32'hFFFF_FFFE) : dec_u.imm;

    always_ff @(posedge clk) begin
        if (rst) begin
            d2_valid <= 1'b0; d2_red_done <= 1'b0;
            d2_step <= 2'd0; d2_k <= 5'd0; d2_rem <= 16'd0;
            d2_after_blp <= 1'b0; d2_blp_lr <= 32'd0;
        end else begin
            if (kill_d2) d2_after_blp <= 1'b0;
            else if (d2_issue) begin
                d2_after_blp <= !d2_inject && d2_blp;
                d2_blp_lr    <= d2_pc_op + d2_imm;     // the prefix's LR
            end
            if (kill_d2)                         d2_valid <= 1'b0;
            else if (d2_issue && !d2_last)       ;
            else if (d1_take)                    d2_valid <= 1'b1;
            else if (d2_issue)                   d2_valid <= 1'b0;      // last step gone, nothing to take
            // the steps of the one in D2, or a fresh start (a killed one's
            // steps are never looked at: valid is clear)
            if (d_redirect) d2_red_done <= 1'b1;
            if (d1_take_nk) begin
                d2_red_done <= 1'b0; d2_step <= 2'd0; d2_k <= 5'd0;
            end else if (d2_issue_nk && !d2_last) begin
                {ra_pc, rb_pc, rc_pc, sel_a_rd, sel_b_31} <= '0;
                if (d2_lsm) begin
                    d2_k <= d2_k + 5'd1; d2_rem <= dec_rem_next; d2_lreg <= lowest(d2_rest);
                    d2_ixl <= phys(lowest(d2_rest), d2_lmode);
                    d2_lmore <= two_or_more(d2_rest);
                    d2_rest <= d2_rest & (d2_rest - 16'd1);
                    rc_pc <= !d2_arm[20] && lowest(d2_rest) == 4'd15;    // STM: the next register
                    sel_c <= d2_arm[20] ? SC_RS : SC_RL;
                end else begin
                    d2_step <= d2_step + 2'd1;
                    if (d2_swp) begin                                    // store Rm, then move r31
                        sel_b_31 <= d2_step == 2'd1;
                        sel_c <= d2_step == 2'd0 ? SC_RM : SC_RS;
                    end else begin                                       // UMLAL/SMLAL: add RdHi:RdLo
                        sel_a_rd <= 1'b1;
                        sel_c <= SC_RN;
                    end
                end
            end
        end
        if (d1_take_nk) begin
            {ra_pc, rb_pc, rc_pc, sel_a_rd, sel_b_31, sel_c}
                <= {d1_ra_pc, d1_rb_pc, d1_rc_pc, d1_sel_a_rd, d1_sel_b_31, d1_sel_c};
            d2_lreg <= ls_low[ib_r];
            d2_nregs <= ls_cnt[ib_r];
            d2_lmore <= ls_more[ib_r];
            d2_rest <= ls_rest[ib_r];
            d2_ptaken <= pr_d1.ptaken; d2_pnext <= pr_d1.pnext; d2_ptagm <= pr_d1.ptagm;
            d2_pctr <= pr_d1.pctr; d2_psp <= pr_d1.psp;
            d2_mode <= cpsr[4:0];
            d2_lmode <= ls_mode[ib_r];
            d2_ixn <= phys(d1_arm[19:16], cpsr[4:0]);
            d2_ixm <= phys(d1_arm[3:0], cpsr[4:0]);
            d2_ixs <= phys(d1_arm[11:8], cpsr[4:0]);
            d2_ixd <= phys(d1_arm[15:12], cpsr[4:0]);
            d2_ixl <= ls_ix[ib_r];
            d2_pc <= d1.pc; d2_thumb <= d1.thumb; d2_abt <= d1.abt;
            d2_link <= d1.pc + (d1.thumb ? 32'd3 : 32'd4);
            d2_arm <= d1_arm; d2_half <= d1_half; d2_pc_op <= d1_pc_op;
            d2_imm_en <= d1.thumb && t_imm_en; d2_imm <= t_imm;
            d2_bl <= d1.thumb && t_bl; d2_und <= d1.thumb && t_und;
            d2_ub <= d1_ub; d2_blp <= d1_blp;
            d2_lsm <= d1_lsm; d2_swp <= d1_swp; d2_mlal <= d1_mlal;
        end
    end

    // ============================================================ F/buffer sequencing
    always_ff @(posedge clk) begin
        rfix_v <= !rst && any_redirect && fix_push;
        rfix_base <= fix_base; rfix_link <= fix_link;
        if (rst) begin
            f1_pc <= 32'd0; f1_thumb <= 1'b0;
            f2_valid <= 1'b0; f2_pc <= 32'd0; f2_thumb <= 1'b0;
            ib_n <= 3'd0; ib_w <= 2'd0; ib_r <= 2'd0;
            ras_sp <= 3'd0;
        end else begin
            f1_pc <= f1_pc_n; f1_thumb <= f1_thumb_n;
            if (any_redirect || f2_miss) f2_valid <= 1'b0;
            else begin
                f2_valid <= f1_go;
                if (f1_go) begin
                    f2_pc <= f1_pc; f2_thumb <= f1_thumb;
                    f2_ptaken <= f1_hit; f2_pnext <= f1_pnext;
                    f2_ptagm <= f1_tagm; f2_pctr <= bc; f2_psp <= ras_sp;
                end
            end
            // the return stack: repaired by a redirect, rewound when F2's
            // fetch is asked again, else moved by what F1 predicts
            if (any_redirect) ras_sp <= fix_sp;
            else if (f2_miss) ras_sp <= f2_psp;
            else if (f1_go && f1_hit && bq.kind == BK_CALL) ras_sp <= ras_sp + 3'd1;
            else if (f1_go && f1_hit && bq.kind == BK_RET) ras_sp <= ras_sp - 3'd1;
            // Its entries wait on nothing that waits on the D-cache's hit:
            // that hit, through M's stall into every redirect and on to the
            // enables of all 256 flops here, was 191 of the 200 slowest paths
            // at 73.85 MHz.  F1 writes its push whether or not a redirect or
            // a refetch discards it, which can only put a wrong-path address
            // where a later return predicts from (every prediction is
            // checked); a redirect's own push is written a cycle late, from
            // flops, after anything F1 writes.
            if (f1_go && f1_hit && bq.kind == BK_CALL) ras[ras_sp] <= {f1_seq[31:1], f1_thumb};
            if (rfix_v) ras[rfix_base] <= rfix_link;
            if (kill_f) begin
                ib_n <= 3'd0; ib_w <= 2'd0; ib_r <= 2'd0;
            end else begin
                ib_n <= ib_n + {2'd0, f2_push} - {2'd0, d1_take};
                ib_w <= ib_w + {1'b0, f2_push};
                ib_r <= ib_r + {1'b0, d1_take};
            end
        end
        if (f2_push) pr[ib_w] <= pr_f2;
    end

    // ============================================================ S
    logic        s_valid, s_dred;
    logic        s_amt_ok;                      // a register shift amount has settled in s_u.c
    uop_t        s_u;
    logic        a_valid, a_dred;
    uop_t        a_u;
    logic [31:0] a_link;                        // a_u.pc's return address, for the stack's repair
    logic        m_valid, m_exec, m_mem;
    logic        m_vx, m_ldx;                   // valid and executed; ... and a load (flops, for the stall)
    uop_t        m_u;
    logic [31:0] m_ra, m_rb;
    logic        w_valid, w_exec;
    logic        w_vx, w_ldpc;                  // valid and executed; ... and a load to PC
    uop_t        w_u;
    logic [31:0] w_ra, w_rb;

    // forwarding from registered results: M's (but not a load's, which is
    // not back yet) and W's
    // Each S operand carries its matches against the destinations of the
    // uops in A, M and W, worked out a cycle early (s_tag_next), so that
    // forwarding and the stall start from flops rather than from 5-bit
    // compares.  Valid and exec bits are applied here, where they are
    // registered too.
    typedef struct packed { logic a_wa, a_wb, m_wa, m_wb, w_wa, w_wb; } tag_t;
    tag_t s_ta, s_tb, s_tc;

    function automatic logic [31:0] sfwd(input tag_t t, input logic en, input logic [31:0] v);
        if (!en) return v;
        if (m_vx && t.m_wa && !m_ldx) return m_ra;
        if (m_vx && t.m_wb) return m_rb;
        if (w_vx && t.w_wa) return w_ra;
        if (w_vx && t.w_wb) return w_rb;
        return v;
    endfunction

    // producers S cannot see yet
    function automatic logic in_a(input tag_t t);                  // anything A writes
        return a_valid && (t.a_wa || t.a_wb);
    endfunction
    function automatic logic load_in_a(input tag_t t);
        return a_valid && a_u.kind == K_LOAD && t.a_wa;
    endfunction
    function automatic logic load_in_m(input tag_t t);
        return m_ldx && t.m_wa;
    endfunction

    // where A finds an operand S could not
    typedef enum logic [1:0] { L_NONE, L_MRA, L_MRB, L_WRA } late_t;
    function automatic late_t late_of(input tag_t t, input logic en);
        if (!en) return L_NONE;
        if (a_valid && t.a_wa && a_u.kind != K_LOAD) return L_MRA;
        if (a_valid && t.a_wb) return L_MRB;
        if (load_in_m(t)) return L_WRA;
        return L_NONE;
    endfunction

    logic [31:0] sa, sb, sc;
    logic        s_blate, s_clate, s_rrx, s_cpass, s_stall, s_adv;
    logic        s_psrrd;                       // S's uop reads the SPSR (MRS, MSR, a restore)
    logic        a_free, a_wflags;
    always_comb begin
        sa = sfwd(s_ta, s_u.ra_rd, s_u.a);
        sb = sfwd(s_tb, s_u.rb_rd, s_u.b);
        sc = sfwd(s_tc, s_u.rc_rd, s_u.c);
        // operands A may pick up late: unshifted, not a shift amount, not
        // a multiplier input (those go to the DSP block from here)
        s_blate = !s_u.use_imm && !s_u.sh_reg && s_u.sh_typ == 2'd0 && s_u.sh_amt == 5'd0
                  && s_u.kind != K_MUL && s_u.kind != K_MULL;
        s_clate = !s_u.sh_reg && s_u.kind != K_MUL && s_u.kind != K_MULL;
        s_rrx   = !s_u.use_imm && !s_u.sh_reg && s_u.sh_typ == 2'd3 && s_u.sh_amt == 5'd0;
        // the shifter's carry out is CPSR.C, which A reads itself
        s_cpass = s_u.use_imm ? !s_u.imm_rot
                              : (s_u.sh_reg ? s_u.c[7:0] == 8'd0 : (s_u.sh_typ == 2'd0 && s_u.sh_amt == 5'd0));
        s_stall = s_valid && (
              (s_u.ra_rd && load_in_a(s_ta))
           || (s_psrrd && a_wflags)
           || (s_u.rb_rd && (s_blate ? load_in_a(s_tb) : (in_a(s_tb) || load_in_m(s_tb))))
           || (s_u.rc_rd && (s_clate ? load_in_a(s_tc) : (in_a(s_tc) || load_in_m(s_tc))))
           || (s_rrx && a_wflags)
           || (s_u.sh_reg && !s_amt_ok));
    end
`ifdef VERILATOR
    // for the bench's profile: why S waits.  0 a load's value, 1 a result
    // in A needed shifted, 2 ... by the multiplier, 3 a shift by register's
    // extra cycle, 4 an RRX or an SPSR read behind a PSR write
    logic [4:0] s_why /* verilator public */;
    always_comb begin
        s_why = 5'd0;
        s_why[0] = (s_u.ra_rd && load_in_a(s_ta))
                || (s_u.rb_rd && (load_in_a(s_tb) || (!s_blate && load_in_m(s_tb))))
                || (s_u.rc_rd && (load_in_a(s_tc) || (!s_clate && load_in_m(s_tc))));
        s_why[1] = (s_u.kind != K_MUL && s_u.kind != K_MULL)
                && ((s_u.rb_rd && !s_blate && in_a(s_tb) && !load_in_a(s_tb))
                 || (s_u.rc_rd && !s_clate && in_a(s_tc) && !load_in_a(s_tc)));
        s_why[2] = (s_u.kind == K_MUL || s_u.kind == K_MULL)
                && ((s_u.rb_rd && in_a(s_tb) && !load_in_a(s_tb)) || (s_u.rc_rd && in_a(s_tc) && !load_in_a(s_tc)));
        s_why[3] = s_u.sh_reg && !s_amt_ok;
        s_why[4] = (s_rrx || s_psrrd) && a_wflags;
    end
`endif
    assign s_adv     = s_valid && !s_stall && a_free && !kill_s;
    assign s_free    = !s_valid || s_adv;
    assign s_free_nk = !s_valid || (!s_stall && a_free);

    logic [31:0] sh_res, s_op2;
    logic        sh_c, s_op2_c;
    arm_shift u_shift (
        .val(sb), .typ(s_u.sh_typ), .amt(s_u.sh_reg ? s_u.c[7:0] : {3'd0, s_u.sh_amt}),
        .imm_form(!s_u.sh_reg), .cin(cpsr[29]), .res(sh_res), .cout(sh_c)
    );
    always_comb begin
        s_op2   = s_u.use_imm ? s_u.imm : sh_res;
        s_op2_c = s_u.use_imm ? s_u.imm[31] : sh_c;
    end

    // ============================================================ A
    logic [31:0] a_op2;
    logic        a_op2_c, a_cpass, a_blate;
    logic        a_tgt_ok;                      // a direct branch's target is the one predicted
    late_t       a_la, a_lb, a_lc;

    logic        a_wa_fb, a_wb_fb, a_wc_fb;

    // A's view of an operand S marked late.  When the uop that was in A
    // turns out not to have executed, the value is the next older one: the
    // load that was in M (wfb), or what S had.
    function automatic logic [31:0] afwd(input late_t l, input logic wfb, input logic [31:0] v);
        case (l)
            L_MRA:   return m_exec ? m_ra : (wfb ? w_ra : v);
            L_MRB:   return m_exec ? m_rb : (wfb ? w_ra : v);
            L_WRA:   return w_ra;
            default: return v;
        endcase
    endfunction

    logic [31:0] ea, eb, ec, op2;
    logic        op2_c;
    always_comb begin
        ea = afwd(a_la, a_wa_fb, a_u.a);
        eb = afwd(a_lb, a_wb_fb, a_u.b);
        ec = afwd(a_lc, a_wc_fb, a_u.c);
        op2   = a_blate ? eb : a_op2;
        op2_c = (a_blate || a_cpass) ? cpsr[29] : a_op2_c;
    end

    logic [31:0] alu_res;
    logic  [3:0] alu_nzcv;
    arm_alu u_alu (
        .op(a_u.alu_op), .a(ea), .b(op2), .cin(cpsr[29]), .shc(op2_c), .vin(cpsr[28]),
        .res(alu_res), .nzcv(alu_nzcv)
    );

    // flags A may write: what an RRX in S has to wait for
    assign a_wflags = a_valid && (a_u.setflags || a_u.restore || a_u.kind == K_MSR);

    // multiplier: two pipeline stages in the DSP blocks, the first taken
    // from S's operands at the edge that moves the multiply into A (S waits
    // until a multiplier input needs nothing late, so sb and sc are final
    // there), the second in A's first cycle, which holds A one cycle
    logic        a_adv, a_busy, a_commit, a_pass;
    logic        mcnt;                      // A's multiply has had its first cycle
    logic [65:0] mp1, mp2;
    logic [63:0] mprod;                     // the product register (K_MULL -> K_MULH)
    logic        a_is_mul;
    assign a_is_mul = a_valid && (a_u.kind == K_MUL || a_u.kind == K_MULL);
    assign a_busy   = a_is_mul && !mcnt;
    always_ff @(posedge clk) begin
        mp1 <= $signed({s_u.mul_signed && sb[31], sb}) * $signed({s_u.mul_signed && sc[31], sc});
        if (!mcnt) mp2 <= mp1;              // a multiply's own product, then held
        if (rst || !a_valid || a_adv) mcnt <= 1'b0;
        else if (a_busy) mcnt <= 1'b1;
    end

    // LDM/STM base, latched by the first element
    logic [31:0] lsm_base;

    // what this uop does, if its condition passes
    logic [31:0] a_cpsr_n, a_ra, a_rb, a_addr, a_base, a_ea, a_wdata, a_spsr_cur;
    logic  [3:0] a_be;
    logic        a_wa_en, a_wb_en, a_mem;
    logic  [4:0] a_wa;
    logic [63:0] a_long;
    logic        a_spsr_we;
    logic [31:0] a_spsr_n;
    logic  [4:0] a_spsr_mode;
    logic [31:0] msr_mask, msr_v;
    logic        a_mred;                    // redirect from M next cycle: ALU to PC, BL suffix
    logic [31:0] a_mtarget;
    logic        a_mthumb;
    logic        a_brtaken;                     // a branch, BX or return by load in A, taken
    logic        a_ldret;                       // a return by load: LDM/POP with pc, not ^
    assign a_ldret = a_u.kind == K_LOAD && a_u.wa_pc && a_u.br_ret && !a_u.restore;

    always_comb begin
        a_spsr_cur = spsr_cur;
        a_pass   = cond_ok(a_u.cond, cpsr);
        a_cpsr_n = cpsr;
        a_ra = alu_res; a_rb = 32'd0;
        a_wa_en = a_u.wa_en; a_wa = a_u.wa; a_wb_en = a_u.wb_en;
        a_redirect = 1'b0; a_target = 32'd0; a_tthumb = cpsr[5];
        a_mred = 1'b0; a_mtarget = 32'd0; a_mthumb = cpsr[5];
        a_spsr_we = 1'b0; a_spsr_n = cpsr; a_spsr_mode = cpsr[4:0];
        a_long = 64'd0;
        msr_v = a_u.use_imm ? a_u.imm : eb;
        msr_mask = {{8{a_u.msr_mask[3]}}, {8{a_u.msr_mask[2]}}, {8{a_u.msr_mask[1]}}, {8{a_u.msr_mask[0]}}}
                   & 32'hF000_00FF;     // v4: only NZCV and the control byte exist

        // addresses
        a_base = a_u.lsm ? (a_u.lsm_latch ? ea : lsm_base) : ea;
        a_ea   = a_u.lsm ? a_base + a_u.imm : (a_u.up ? a_base + op2 : a_base - op2);
        a_addr = (a_u.lsm || a_u.pre) ? a_ea : a_base;
        a_mem  = a_u.kind == K_LOAD || a_u.kind == K_STORE;
        case (a_u.msize)
            2'd0:    begin a_wdata = {4{ec[7:0]}};  a_be = 4'b0001 << a_addr[1:0]; end
            2'd1:    begin a_wdata = {2{ec[15:0]}}; a_be = a_addr[1] ? 4'b1100 : 4'b0011; end
            default: begin a_wdata = ec;            a_be = 4'b1111; end
        endcase

        case (a_u.kind)
            K_ALU: begin
                if (a_u.setflags) a_cpsr_n[31:28] = alu_nzcv;
                if (a_u.wa_pc) begin
                    a_mred = 1'b1;
                    if (a_u.restore) begin
                        a_cpsr_n = a_spsr_cur;
                        a_mthumb = a_spsr_cur[5];
                    end
                    a_mtarget = alu_res & (a_mthumb ? 32'hFFFF_FFFE : 32'hFFFF_FFFC);
                    a_wa_en = 1'b0;
                end
            end
            K_MUL: begin
                a_ra = mp2[31:0] + (a_u.mul_acc ? ea : 32'd0);
                if (a_u.setflags) a_cpsr_n[31:30] = {a_ra[31], a_ra == 32'd0};
            end
            K_MULL: begin
                a_long = mp2[63:0];
                a_ra = a_long[31:0]; a_rb = a_long[63:32];
                if (a_u.setflags) a_cpsr_n[31:30] = {a_long[63], a_long == 64'd0};
            end
            K_MULH: begin
                a_long = mprod + {ec, ea};
                a_ra = a_long[31:0]; a_rb = a_long[63:32];
                if (a_u.setflags) a_cpsr_n[31:30] = {a_long[63], a_long == 64'd0};
            end
            K_LOAD, K_STORE: begin
                a_rb = a_u.lsm ? a_base + a_u.lsm_wb : a_ea;
                if (a_u.kind == K_LOAD && a_u.restore) a_cpsr_n = a_spsr_cur;   // LDM^ with PC
            end
            K_BRANCH: begin
                a_ra = a_u.pc + (a_u.thumb ? 32'd2 : 32'd4) + {31'd0, a_u.thumb};
                if (a_u.ra_rd) begin                    // a Thumb BL suffix D2 did not see whole: LR + offset
                    a_mred = !a_dred;
                    a_mtarget = (ea + a_u.imm) & 32'hFFFF_FFFE;
                end else begin                          // unless D2 went, or F1 went right
                    a_redirect = !a_dred && !(a_u.p_taken && a_tgt_ok);
                    a_target = a_u.imm & (cpsr[5] ? 32'hFFFF_FFFE : 32'hFFFF_FFFC);
                end
            end
            K_BX: begin
                a_tthumb = eb[0];
                a_target = eb & (eb[0] ? 32'hFFFF_FFFE : 32'hFFFF_FFFC);
                a_cpsr_n[5] = eb[0];
                if (!a_u.p_taken) a_redirect = 1'b1;
                else if (a_u.p_next != {a_target[31:1], eb[0]}) begin   // predicted wrong: from M,
                    a_mred = 1'b1;                                     // so the compare ends at a flop
                    a_mtarget = a_target; a_mthumb = eb[0];
                end
            end
            K_MRS: a_ra = a_u.psr_spsr ? a_spsr_cur : cpsr;
            K_MSR: begin
                // fields: f 31:24, s 23:16, x 15:8, c 7:0; T is never written; in
                // user mode only the flags are
                if (a_u.psr_spsr) begin
                    a_spsr_we = cpsr[4:0] != M_USR && cpsr[4:0] != M_SYS;
                    a_spsr_n = (a_spsr_cur & ~msr_mask) | (msr_v & msr_mask);
                end else begin
                    if (cpsr[4:0] == M_USR) msr_mask = msr_mask & 32'hFF00_0000;
                    msr_mask = msr_mask & ~32'h0000_0020;
                    a_cpsr_n = (cpsr & ~msr_mask) | (msr_v & msr_mask);
                    if (msr_mask[7:0] != 8'd0) begin   // mode may have changed: refetch
                        a_redirect = 1'b1;
                        a_target = a_u.pc + (a_u.thumb ? 32'd2 : 32'd4);
                    end
                end
            end
            K_EXC: begin
                if (a_u.irq && cpsr[7]) begin           // masked since D2: just refetch
                    a_redirect = 1'b1;
                    a_target = a_u.pc; a_tthumb = a_u.thumb;
                    a_wa_en = 1'b0;
                end else begin
                    a_spsr_we = 1'b1; a_spsr_mode = a_u.exc_mode; a_spsr_n = cpsr;
                    a_cpsr_n = {cpsr[31:8], 1'b1, cpsr[6], 1'b0, a_u.exc_mode};
                    a_redirect = 1'b1;
                    a_target = {27'd0, a_u.exc_vec, 2'b00};
                    a_tthumb = 1'b0;
                    a_wa_en = 1'b1; a_wa = a_u.exc_lr_reg; a_ra = a_u.exc_lr;
                end
            end
            default: ;
        endcase

        if (!a_pass) begin
            a_cpsr_n = cpsr; a_redirect = 1'b0; a_mred = 1'b0; a_spsr_we = 1'b0;
            a_wa_en = 1'b0; a_wb_en = 1'b0; a_mem = 1'b0;
        end
        // F1 went to a target here, but no branch was taken: refetch what follows
        a_brtaken = a_pass && (a_u.kind == K_BRANCH || a_u.kind == K_BX || a_ldret);
        if (a_u.p_taken && !a_brtaken && a_u.kind != K_EXC) begin
            a_redirect = 1'b1;
            a_target = a_u.pc + (a_u.thumb ? 32'd2 : 32'd4);
            a_tthumb = a_u.thumb;
        end
        a_red_ask  = a_redirect;
        a_redirect = a_redirect && a_commit;
    end

    // A load to PC in M may redirect from W next cycle -- unless it is a
    // return the fetch predicted and the word loaded is where it went -- so
    // nothing behind it commits: A holds for that cycle, and W's redirect
    // kills what it holds or the hold ends.
    logic m_pcload;
    assign m_pcload = m_ldx && m_u.wa_pc;

    logic m_hold, m_dabt_take;
    assign a_adv    = a_valid && !m_hold && !a_busy && !m_pcload;
    assign a_commit = a_adv && !kill_a;
    // free only while M moves too: a uop entering A may be told to find a
    // load's value in W next cycle, so the load must get there
    assign a_free   = !m_hold && !m_pcload && (!a_valid || !a_busy);
`ifdef VERILATOR
    always_ff @(posedge clk)
        if (!rst && a_commit && (a_u.restore || ((a_u.kind == K_MRS || a_u.kind == K_MSR) && a_u.psr_spsr))
            && spsr_cur != spsr_of(cpsr[4:0]))
            $error("arm_cpu: a stale SPSR read at %08x", a_u.pc);
`endif

    // S's tags for next cycle.  Then A holds S's uop if A is free now, else
    // its own; M holds A's unless M is held; W holds M's.  (A clears a
    // destination that does not execute, but m_exec says so too; an
    // exception, a redirect from M or W, or a data abort kills S, so the
    // tags do not matter then.)
    function automatic logic dst_a(input logic [4:0] r, input uop_t u);
        return u.wa_en && !u.wa_pc && u.wa == r;
    endfunction
    function automatic logic dst_b(input logic [4:0] r, input uop_t u);
        return u.wb_en && u.wb == r;
    endfunction
    function automatic tag_t s_tag_next(input logic [4:0] r);
        tag_t t;
        t.a_wa = a_free ? dst_a(r, s_u) : dst_a(r, a_u);
        t.a_wb = a_free ? dst_b(r, s_u) : dst_b(r, a_u);
        t.m_wa = m_hold ? dst_a(r, m_u) : dst_a(r, a_u);
        t.m_wb = m_hold ? dst_b(r, m_u) : dst_b(r, a_u);
        t.w_wa = dst_a(r, m_u);
        t.w_wb = dst_b(r, m_u);
        return t;
    endfunction
    tag_t d2_ta, d2_tb, d2_tc;
    always_comb begin
        d2_ta = sel_a_rd ? s_tag_next(ix_d) : s_tag_next(ix_n);
        d2_tb = sel_b_31 ? s_tag_next(5'd31) : s_tag_next(ix_m);
        case (sel_c)
            SC_RD:   d2_tc = s_tag_next(ix_d);
            SC_RM:   d2_tc = s_tag_next(ix_m);
            SC_RN:   d2_tc = s_tag_next(ix_n);
            SC_RL:   d2_tc = s_tag_next(ix_l);
            default: d2_tc = s_tag_next(ix_s);
        endcase
    end

`ifdef VERILATOR
    // the tags are the compares they replace, wherever a use can see them:
    // valid stages, and in M and W only uops that executed
    function automatic tag_t tag_vis(input tag_t t);
        tag_t v;
        v.a_wa = t.a_wa && a_valid;            v.a_wb = t.a_wb && a_valid;
        v.m_wa = t.m_wa && m_valid && m_exec;  v.m_wb = t.m_wb && m_valid && m_exec;
        v.w_wa = t.w_wa && w_valid && w_exec;  v.w_wb = t.w_wb && w_valid && w_exec;
        return v;
    endfunction
    function automatic tag_t tag_now(input logic [4:0] r);
        tag_t t;
        t.a_wa = dst_a(r, a_u); t.a_wb = dst_b(r, a_u);
        t.m_wa = dst_a(r, m_u); t.m_wb = dst_b(r, m_u);
        t.w_wa = dst_a(r, w_u); t.w_wb = dst_b(r, w_u);
        return tag_vis(t);
    endfunction
    always_ff @(posedge clk)
        if (!rst && s_valid) begin
            if (s_u.ra_rd && tag_vis(s_ta) != tag_now(s_u.ra)) $error("arm_cpu: S tag a wrong at %08x", s_u.pc);
            if (s_u.rb_rd && tag_vis(s_tb) != tag_now(s_u.rb)) $error("arm_cpu: S tag b wrong at %08x", s_u.pc);
            if (s_u.rc_rd && tag_vis(s_tc) != tag_now(s_u.rc)) $error("arm_cpu: S tag c wrong at %08x", s_u.pc);
        end
`endif

    assign dc_req   = a_valid && a_mem && a_commit;
    assign dc_we    = a_u.kind == K_STORE;
    assign dc_addr  = a_addr;
    assign dc_wdata = a_wdata;
    assign dc_be    = a_be;
    assign dc_size  = a_u.msize;

    always_ff @(posedge clk) begin
        if (rst) begin
            cpsr <= 32'h0000_00D3;
            spsr_fiq <= 32'd0; spsr_svc <= 32'd0; spsr_abt <= 32'd0; spsr_irq <= 32'd0; spsr_und <= 32'd0;
            s_valid <= 1'b0; s_dred <= 1'b0; s_amt_ok <= 1'b0; s_u <= '0; s_psrrd <= 1'b0;
            s_ta <= '0; s_tb <= '0; s_tc <= '0;
            a_valid <= 1'b0; a_dred <= 1'b0; a_u <= '0;
            a_op2 <= 32'd0; a_op2_c <= 1'b0; a_cpass <= 1'b0; a_blate <= 1'b0;
            a_la <= L_NONE; a_lb <= L_NONE; a_lc <= L_NONE;
            a_wa_fb <= 1'b0; a_wb_fb <= 1'b0; a_wc_fb <= 1'b0;
            lsm_base <= 32'd0; mprod <= 64'd0;
        end else begin
            // ---- A commits: CPSR, SPSR, the product and base registers
            if (a_commit) begin
                cpsr <= a_cpsr_n;
                if (a_spsr_we)
                    case (a_spsr_mode)
                        M_FIQ: spsr_fiq <= a_spsr_n;
                        M_SVC: spsr_svc <= a_spsr_n;
                        M_ABT: spsr_abt <= a_spsr_n;
                        M_IRQ: spsr_irq <= a_spsr_n;
                        M_UND: spsr_und <= a_spsr_n;
                        default: ;
                    endcase
                if (a_u.kind == K_MULL) mprod <= mp2[63:0];
                if (a_u.lsm && a_u.lsm_latch) lsm_base <= ea;
            end
            if (m_dabt_take) begin                      // a data abort, from M
                cpsr <= {cpsr[31:8], 1'b1, cpsr[6], 1'b0, M_ABT};
                spsr_abt <= cpsr;
            end

            // ---- S -> A
            if (kill_s)        a_valid <= 1'b0;
            else if (a_free)   a_valid <= s_adv;
            if (a_free) begin
                a_u <= s_u;
                a_link <= s_u.pc + (s_u.thumb ? 32'd3 : 32'd4);
                a_u.a <= sa; a_u.b <= sb; a_u.c <= sc;
                a_dred <= s_dred;
                a_op2 <= s_op2; a_op2_c <= s_op2_c; a_cpass <= s_cpass; a_blate <= s_blate;
                a_tgt_ok <= s_u.p_next == {s_u.imm[31:1], s_u.thumb};
                a_la <= late_of(s_ta, s_u.ra_rd);
                a_lb <= late_of(s_tb, s_u.rb_rd);
                a_lc <= late_of(s_tc, s_u.rc_rd);
                a_wa_fb <= s_u.ra_rd && load_in_m(s_ta);
                a_wb_fb <= s_u.rb_rd && load_in_m(s_tb);
                a_wc_fb <= s_u.rc_rd && load_in_m(s_tc);
            end else begin
                // held: settle the late operands while their producers are in view
                a_u.a <= ea; a_u.b <= eb; a_u.c <= ec;
                a_la <= L_NONE; a_lb <= L_NONE; a_lc <= L_NONE;
            end

            // ---- D2 -> S
            if (kill_s)        s_valid <= 1'b0;
            else if (s_free)   s_valid <= d2_issue;
            if (s_free_nk) begin
                s_u <= d2_u;
                s_dred <= !d2_inject && (d2_ub || d2_bls) && !d2_ptaken;
                s_psrrd <= ((d2_u.kind == K_MRS || d2_u.kind == K_MSR) && d2_u.psr_spsr) || d2_u.restore;
                s_amt_ok <= 1'b0;
                s_ta <= d2_ta; s_tb <= d2_tb; s_tc <= d2_tc;
            end else begin
                // held: keep the operands current as older results retire.
                // A shift by a register takes this extra cycle so that the
                // shifter's amount comes from s_u.c, not the forwarding mux
                s_u.a <= sa; s_u.b <= sb; s_u.c <= sc;
                s_amt_ok <= !(s_u.rc_rd && (in_a(s_tc) || load_in_m(s_tc)));
                s_ta <= s_tag_next(s_u.ra); s_tb <= s_tag_next(s_u.rb); s_tc <= s_tag_next(s_u.rc);
            end
        end
    end

    // ============================================================ M
    logic [31:0] m_addr, m_cpsr, m_tgt;
    logic [31:0] m_wa0, m_wa1;                  // W's ra if the word is dc_rdata, dc_rdata1
    logic        m_red, m_tth, m_pok;
    // a load's value from a word: aligned, rotated, extended
    function automatic logic [31:0] align(input logic [31:0] d);
        logic [31:0] r;
        case (m_u.msize)
            2'd0: begin
                r = {24'd0, d[{m_addr[1:0], 3'b000} +: 8]};
                if (m_u.msigned) r = {{24{r[7]}}, r[7:0]};
            end
            2'd1: begin
                r = {16'd0, m_addr[1] ? d[31:16] : d[15:0]};
                if (m_u.msigned) r = {{16{r[15]}}, r[15:0]};
            end
            default: r = (d >> {m_addr[1:0], 3'b000}) | (d << (6'd32 - {1'b0, m_addr[1:0], 3'b000}));
        endcase
        if (m_addr[1:0] == 2'd0 && m_u.msize == 2'd2) r = d;
        return r;
    endfunction
    // a return by load that the fetch predicted: is the word loaded the
    // address it went to?  (ARMv4T does not interwork on a load, so the
    // state is the load's own.)  Compared from the cache's word, beside the
    // alignment, so that W's redirect starts at a flop.
    function automatic logic pok(input logic [31:0] d);
        return m_u.p_taken && m_u.br_ret && m_u.lsm && !m_u.restore && m_addr[1:0] == 2'd0
            && d[31:2] == m_u.p_next[31:2] && m_u.p_next[0] == m_u.thumb
            && (m_u.thumb ? d[1] == m_u.p_next[1] : !m_u.p_next[1]);
    endfunction
    always_comb begin
        m_hold = m_valid && m_mem && !dc_ok;
        // both of the D-cache's words are aligned, and the way picked last:
        // dc_rsel comes from its tag compare, the latest signal into W
        m_wa0 = m_u.kind == K_LOAD ? align(dc_rdata)  : m_ra;
        m_wa1 = m_u.kind == K_LOAD ? align(dc_rdata1) : m_ra;
        m_pok = dc_rsel ? pok(dc_rdata1) : pok(dc_rdata);
        m_dabt_take = m_valid && m_mem && dc_ok && dc_abort && !w_redirect;
        m_redirect  = !w_redirect && ((m_valid && m_red) || m_dabt_take);
        m_tthumb    = m_dabt_take ? 1'b0 : m_tth;
        m_target    = m_dabt_take ? 32'h0000_0010 : m_tgt;
    end

    // The BTB is read with f1_pc_n's index (F1 above), but from the
    // redirects as they are asked for, not as they commit: whether M holds
    // (dc_ok, through m_hold and a_commit) and a data abort are the latest
    // signals in the CPU, and they were on the slowest path, into the BTB's
    // own address.  A redirect asked for that waits, or never comes, has F1
    // fetch meanwhile what is younger than it, which is killed; and the
    // entry read for it predicts nothing (bmis).
    logic [BI:1] f1_bi;
    always_comb begin
        if (rst)                                  f1_bi = '0;
        else if (w_redirect)                      f1_bi = w_target[BI:1];
        else if (m_valid && m_red)                f1_bi = m_tgt[BI:1];
        else if (a_red_ask)                       f1_bi = a_target[BI:1];
        else if (d2_valid && !d2_red_done && (d2_ub || d2_bls) && !d2_ptaken)
                                                  f1_bi = d_target[BI:1];
        else if (f2_miss)                         f1_bi = f2_pc[BI:1];
        else if (f1_go && f1_hit)                 f1_bi = f1_pnext[BI:1];
        else if (f1_go)                           f1_bi = f1_seq[BI:1];
        else                                      f1_bi = f1_pc[BI:1];
    end
    always_ff @(posedge clk) begin
        bq <= btb_e[f1_bi];
        bc <= btb_c[f1_bi];
        // f1_bi and f1_pc_n part only where A asked and did not commit, or M
        // took a data abort: then the entry read is another address's, and
        // its tag, which leaves out the index, may still match
        bmis <= !w_redirect && !(m_valid && m_red) && ((a_red_ask && !a_redirect) || m_dabt_take);
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            m_valid <= 1'b0; m_exec <= 1'b0; m_mem <= 1'b0; m_u <= '0;
            m_ra <= 32'd0; m_rb <= 32'd0; m_addr <= 32'd0; m_cpsr <= 32'd0;
            m_red <= 1'b0; m_tgt <= 32'd0; m_tth <= 1'b0; m_vx <= 1'b0; m_ldx <= 1'b0;
        end else if (w_redirect) begin
            m_valid <= 1'b0; m_red <= 1'b0; m_vx <= 1'b0; m_ldx <= 1'b0;
        end else if (!m_hold) begin
            m_valid <= a_commit;
            m_vx  <= a_commit && a_pass;
            m_ldx <= a_commit && a_pass && a_u.kind == K_LOAD;
            m_u <= a_u;
            m_u.wa_en <= a_wa_en; m_u.wa <= a_wa; m_u.wb_en <= a_wb_en;
            m_exec <= a_pass;
            m_mem <= a_mem;
            m_ra <= a_ra; m_rb <= a_rb;
            m_addr <= a_addr;
            m_cpsr <= a_cpsr_n;
            m_red <= a_commit && a_mred;
            m_tgt <= a_mtarget; m_tth <= a_mthumb;
        end
    end

    // ============================================================ W
    logic [31:0] w_cpsr;
    logic        w_pok;                         // a return by load, predicted right
    always_ff @(posedge clk) begin
        if (rst) begin
            w_valid <= 1'b0; w_exec <= 1'b0; w_u <= '0; w_ra <= 32'd0; w_rb <= 32'd0; w_cpsr <= 32'd0;
            w_pok <= 1'b0; w_vx <= 1'b0; w_ldpc <= 1'b0;
        end else begin
            w_valid <= m_valid && !m_hold && !w_redirect;
            w_vx    <= m_vx && !m_hold && !w_redirect;
            w_ldpc  <= m_pcload && !m_hold && !w_redirect && !m_dabt_take;
            w_u <= m_u;
            w_exec <= m_exec;
            w_pok <= m_pok;
            w_ra <= dc_rsel ? m_wa1 : m_wa0;
            w_rb <= m_rb;
            w_cpsr <= m_cpsr;
            // the aborted access writes nothing but LR_abt, by port B: the
            // abort is known late (dc_ok), and w_ra's input is the loaded
            // word's, the slowest way into W
            if (m_dabt_take) begin
                w_u.wa_en <= 1'b0; w_u.wa_pc <= 1'b0; w_u.wb_en <= 1'b1; w_u.wb <= 5'd26;
                w_rb <= m_u.pc + 32'd8;
                w_cpsr <= {cpsr[31:8], 1'b1, cpsr[6], 1'b0, M_ABT};
            end
        end
    end

`ifdef VERILATOR
    // for the bench's profile, which should not know uop_t's layout
    logic [3:0] a_kind /* verilator public */;
    assign a_kind = a_u.kind;
`endif

    // ============================================================ BTB update, return stack repair
    // A writes the BTB as each branch, BX or return by load (LDM/POP with
    // pc, whose entry says "return": the target is the stack's) commits: a
    // taken one allocates
    // (counter 2) or retargets its entry, and the counter of an entry it
    // held moves towards what happened.  The write lands a cycle later, from
    // flops, so A's forwarding and adders stop at a register; a fetch in
    // between sees the old entry, which is checked like any other.
    logic       bw_e, bw_c, bwq_e, bwq_c;
    btbe_t      bw_d, bwq_d;
    logic [1:0] bw_ctr, bwq_ctr;
    logic [BI-1:0] bwq_i;
    always_comb begin
        bw_d.tag  = a_u.pc[BI+BT:BI+1];
        bw_d.kind = a_u.br_call ? BK_CALL : a_u.br_ret ? BK_RET : BK_PLAIN;
        if (a_u.kind == K_BX)  bw_d.tgt = {a_target[31:1], eb[0]};
        else if (a_u.ra_rd)    bw_d.tgt = {a_mtarget[31:1], 1'b1};
        else                   bw_d.tgt = {a_u.imm[31:1], a_u.thumb};
        bw_c = a_commit && a_u.last && (a_u.kind == K_BRANCH || a_u.kind == K_BX || a_ldret)
               && (a_u.p_tagm || a_brtaken);
        bw_e = bw_c && a_brtaken;
        if (!a_u.p_tagm)   bw_ctr = 2'd2;
        else if (a_brtaken) bw_ctr = a_u.p_ctr == 2'd3 ? 2'd3 : a_u.p_ctr + 2'd1;
        else               bw_ctr = a_u.p_ctr == 2'd0 ? 2'd0 : a_u.p_ctr - 2'd1;
    end
    always_ff @(posedge clk) begin
        bwq_e <= !rst && bw_e; bwq_c <= !rst && bw_c;
        bwq_d <= bw_d; bwq_ctr <= bw_ctr; bwq_i <= a_u.pc[BI:1];
        if (bwq_e) btb_e[bwq_i] <= bwq_d;
        if (bwq_c) btb_c[bwq_i] <= bwq_ctr;
    end

    // The stack as it was before the redirecting instruction, plus that
    // instruction's own push or pop if it was a call or return that went.
    // Which case applies waits on the D-cache's hit (M's stall and abort), so
    // each case's return address is ready in a flop: an adder behind the
    // choice put the hit 2.2 ns past 80 MHz (docs/core-design.md 5.4).
    always_comb begin
        fix_push = 1'b0; fix_link = 32'd0;
        if (w_redirect) begin                           // a load to PC
            fix_base = w_u.p_sp;
            fix_sp   = w_u.br_ret ? w_u.p_sp - 3'd1 : w_u.p_sp;
        end else if (m_redirect) begin                  // ALU to PC, BX predicted wrong, BL suffix, abort
            fix_base = m_u.p_sp;
            fix_push = !m_dabt_take && m_u.br_call;
            fix_link = m_ra;
            fix_sp   = m_dabt_take ? m_u.p_sp : m_u.br_call ? m_u.p_sp + 3'd1
                     : m_u.br_ret ? m_u.p_sp - 3'd1 : m_u.p_sp;
        end else if (a_redirect) begin
            fix_base = a_u.p_sp;
            fix_push = a_brtaken && a_u.br_call;
            fix_link = a_link;
            fix_sp   = fix_push ? a_u.p_sp + 3'd1 : (a_brtaken && a_u.br_ret) ? a_u.p_sp - 3'd1 : a_u.p_sp;
        end else begin                                  // D2: B, BL, a Thumb BL pair
            fix_base = d2_psp;                          // a call, from flops rather than the decoder
            fix_push = d2_bls || (d2_ub && d2_arm[24]);
            fix_link = d2_link;
            fix_sp   = fix_push ? d2_psp + 3'd1 : d2_psp;
        end
    end

    // loads to PC: ARMv4T does not interwork on a load, so T stays as it is.
    // A return the fetch predicted right goes on without one.
    assign w_redirect = w_ldpc && !w_pok;
    assign w_tthumb   = cpsr[5];
    assign w_target   = w_ra & (cpsr[5] ? 32'hFFFF_FFFE : 32'hFFFF_FFFC);

    assign rf_wa_en = w_vx && w_u.wa_en && !w_u.wa_pc;
    assign rf_wa    = w_u.wa;
    assign rf_da    = w_ra;
    assign rf_wb_en = w_vx && w_u.wb_en;
    assign rf_wb    = w_u.wb;
    assign rf_db    = w_rb;

    assign rt_valid = w_valid && (w_u.irq ? w_u.wa_en : w_u.last);   // a masked IRQ is no event
    assign rt_irq   = w_u.irq && w_u.wa_en;
    assign rt_pc    = w_u.pc;
    assign rt_instr = w_u.instr;
    assign rt_thumb = w_u.thumb;
    assign rt_cpsr  = w_cpsr;
endmodule
