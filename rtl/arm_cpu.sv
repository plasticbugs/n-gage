//------------------------------------------------------------------------------
// The NGVM CPU: an ARMv4T (ARM and Thumb), six stages (docs/core-design.md 5).
//
//   F1  the fetch address goes to the instruction memory
//   F2  the word comes back (or "not yet": the fetch is replayed)
//   D   Thumb expansion, decode, register read, IRQ injection, B/BL redirect
//   E   forwarding, shifter, ALU, multiply, flags, CPSR/SPSR, addresses,
//       branch resolution, exception entry
//   M   the data memory answers; loads aligned; loads to PC redirect
//   W   register write; retirement
//
// Memory ports.  The instruction port is a pipelined read: an address with
// ic_req at a clock edge is answered in the next cycle by ic_ok (ic_data
// valid) or not, in which case the CPU asks again.  The data port is a
// request/complete handshake: a request is taken at an edge where the memory
// is idle or completing (dc_ok); dc_ok then says the oldest request is done
// (a load's dc_rdata is valid in that cycle).  ic_abort/dc_abort come with
// ok and mark the access as faulted.
//
// Architectural state changes at E (CPSR, SPSR) and at W (registers), in
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
    logic        m_redirect, e_redirect, d_redirect;
    logic [31:0] m_target, e_target, d_target;
    logic        m_tthumb, e_tthumb;

    // ============================================================ F1, F2
    logic        f1_valid, f1_thumb;
    logic [31:0] f1_pc;
    logic        f2_valid, f2_thumb;
    logic [31:0] f2_pc;
    logic        skid_valid, skid_abt;
    logic [31:0] skid;

    assign ic_req  = f1_valid;
    assign ic_addr = {f1_pc[31:2], 2'b00};

    logic        f2_has, f2_miss, f2_abt;
    logic [31:0] f2_word;
    assign f2_has  = f2_valid && (skid_valid || ic_ok);
    assign f2_miss = f2_valid && !skid_valid && !ic_ok;
    assign f2_word = skid_valid ? skid : ic_data;
    assign f2_abt  = skid_valid ? skid_abt : ic_abort;

    // ============================================================ D
    logic        d_valid, d_thumb, d_abt;
    logic [31:0] d_pc, d_word;
    logic  [1:0] d_step;
    logic  [4:0] d_k;
    logic [15:0] d_rem;

    logic [15:0] d_half;
    logic [31:0] t_arm, t_imm, d_arm, pc_op;
    logic        t_imm_en, t_align, t_bl, t_und;
    assign d_half = d_pc[1] ? d_word[31:16] : d_word[15:0];
    arm_thumb u_thumb (
        .t(d_half), .arm(t_arm), .imm_ovr_en(t_imm_en), .imm_ovr(t_imm),
        .pc_align(t_align), .bl_suffix(t_bl), .und(t_und)
    );
    assign d_arm = d_thumb ? t_arm : d_word;
    assign pc_op = d_thumb ? ((d_pc + 32'd4) & (t_align ? 32'hFFFF_FFFC : 32'hFFFF_FFFF))
                           : d_pc + 32'd8;

    logic        d_first;
    assign d_first = d_step == 2'd0 && d_k == 5'd0;

    uop_t        dec_u;
    logic        ra_pc, rb_pc, rc_pc, d_more;
    logic [15:0] d_rem_next;
    arm_decode u_dec (
        .instr(d_arm), .thumb(d_thumb), .thumb_raw(d_half),
        .imm_ovr_en(d_thumb && t_imm_en), .imm_ovr(t_imm),
        .bl_suffix(d_thumb && t_bl), .t_und(d_thumb && t_und), .pabt(d_abt),
        .pc(d_pc), .pc_op(pc_op), .mode(cpsr[4:0]),
        .step(d_step), .rem(d_first ? d_arm[15:0] : d_rem), .k(d_k),
        .u(dec_u), .ra_pc(ra_pc), .rb_pc(rb_pc), .rc_pc(rc_pc),
        .more(d_more), .rem_next(d_rem_next)
    );

    // register file: read in D, written at W
    logic [31:0] qa, qb, qc;
    logic        rf_wa_en, rf_wb_en;
    logic  [4:0] rf_wa, rf_wb;
    logic [31:0] rf_da, rf_db;
    logic [31:0] unused_dbg;
    arm_regs u_regs (
        .clk(clk),
        .ra(dec_u.ra), .rb(dec_u.rb), .rc(dec_u.rc),
        .qa(qa), .qb(qb), .qc(qc),
        .wa_en(rf_wa_en), .wa(rf_wa), .da(rf_da),
        .wb_en(rf_wb_en), .wb(rf_wb), .db(rf_db),
        .dbg_r(5'd0), .dbg_q(unused_dbg)
    );

    // the uop D offers: the decoded step, or an IRQ in place of a new instruction
    uop_t d_u;
    logic d_inject;
    // never between the halves of a Thumb BL (QEMU, and so the bench, runs
    // the pair as one instruction; ARM allows either)
    logic d_after_blp;
    always_comb begin
        d_inject = d_valid && d_first && irq && !cpsr[7] && !d_after_blp;
        d_u = dec_u;
        d_u.a = ra_pc ? pc_op : qa;
        d_u.b = rb_pc ? pc_op : qb;
        d_u.c = rc_pc ? pc_op : qc;
        if (ra_pc) d_u.ra_rd = 1'b0;
        if (rb_pc) d_u.rb_rd = 1'b0;
        if (rc_pc) d_u.rc_rd = 1'b0;
        if (d_inject) begin
            d_u = '0;
            d_u.valid = 1'b1;
            d_u.pc = d_pc; d_u.thumb = d_thumb;
            d_u.first = 1'b1; d_u.last = 1'b1;
            d_u.cond = 4'hE;
            d_u.kind = K_EXC;
            d_u.exc_vec = 3'd6; d_u.exc_mode = M_IRQ;
            d_u.exc_lr = d_pc + 32'd4; d_u.exc_lr_reg = 5'd28;
            d_u.irq = 1'b1;
        end
    end

    // ============================================================ E (declared here, used by D)
    logic        e_valid, e_dred;
    uop_t        e_u;
    logic        e_adv, e_busy, e_ldwait;
    logic        m_hold, m_dabt_take;

    logic e_free, d_issue, d_last, d_take;
    assign e_free  = !e_valid || e_adv;
    assign d_last  = d_inject || dec_u.last;
    assign d_issue = d_valid && e_free && !e_redirect && !m_redirect;
    assign d_redirect = d_issue && !d_inject && dec_u.kind == K_BRANCH && !dec_u.ra_rd
                        && dec_u.cond == 4'hE;
    assign d_target = dec_u.imm;
    assign d_take = f2_has && (!d_valid || (d_issue && d_last))
                    && !d_redirect && !e_redirect && !m_redirect;

    // ============================================================ F/D sequencing
    always_ff @(posedge clk) begin
        if (rst) begin
            f1_valid <= 1'b1; f1_pc <= 32'd0; f1_thumb <= 1'b0;
            f2_valid <= 1'b0; f2_pc <= 32'd0; f2_thumb <= 1'b0;
            skid_valid <= 1'b0; skid <= 32'd0; skid_abt <= 1'b0;
            d_valid <= 1'b0; d_pc <= 32'd0; d_thumb <= 1'b0; d_word <= 32'd0; d_abt <= 1'b0;
            d_step <= 2'd0; d_k <= 5'd0; d_rem <= 16'd0; d_after_blp <= 1'b0;
        end else begin
            if (e_redirect || m_redirect) d_after_blp <= 1'b0;
            else if (d_issue) d_after_blp <= !d_inject && d_thumb && d_half[15:11] == 5'b11110;
            // ---- D
            if (e_redirect || m_redirect) begin
                d_valid <= 1'b0; d_step <= 2'd0; d_k <= 5'd0;
            end else if (d_issue && !d_last) begin
                if (dec_u.lsm) begin d_k <= d_k + 5'd1; d_rem <= d_rem_next; end
                else d_step <= d_step + 2'd1;
            end else if (d_take) begin
                d_valid <= 1'b1; d_pc <= f2_pc; d_thumb <= f2_thumb;
                d_word <= f2_word; d_abt <= f2_abt;
                d_step <= 2'd0; d_k <= 5'd0;
            end else if (d_issue) begin                 // last step gone, nothing to take
                d_valid <= 1'b0; d_step <= 2'd0; d_k <= 5'd0;
            end

            // ---- F1, F2
            if (m_redirect || e_redirect || d_redirect) begin
                f1_valid <= 1'b1;
                f1_pc    <= m_redirect ? m_target : e_redirect ? e_target : d_target;
                f1_thumb <= m_redirect ? m_tthumb : e_redirect ? e_tthumb : d_thumb;
                f2_valid <= 1'b0; skid_valid <= 1'b0;
            end else if (f2_miss) begin                 // ask again for the one that missed
                f1_pc <= f2_pc; f1_thumb <= f2_thumb;
                f2_valid <= 1'b0;
            end else if (!f2_valid || d_take) begin     // F1 moves on
                f2_valid <= f1_valid; f2_pc <= f1_pc; f2_thumb <= f1_thumb;
                f1_pc <= f1_pc + (f1_thumb ? 32'd2 : 32'd4);
                skid_valid <= 1'b0;
            end else if (!skid_valid) begin             // D is busy: keep what came back
                skid_valid <= 1'b1; skid <= ic_data; skid_abt <= ic_abort;
            end
        end
    end

    // ============================================================ E
    // forwarding: the newest older value of each operand
    logic        m_valid, m_exec, m_mem;
    uop_t        m_u;
    logic [31:0] m_ra, m_rb;
    logic        w_valid, w_exec;
    uop_t        w_u;
    logic [31:0] w_ra, w_rb;

    function automatic logic [31:0] fwd(input logic [4:0] r, input logic en, input logic [31:0] v);
        if (!en) return v;
        if (m_valid && m_exec && m_u.wa_en && !m_u.wa_pc && m_u.wa == r && m_u.kind != K_LOAD) return m_ra;
        if (m_valid && m_exec && m_u.wb_en && m_u.wb == r) return m_rb;
        if (w_valid && w_exec && w_u.wa_en && !w_u.wa_pc && w_u.wa == r) return w_ra;
        if (w_valid && w_exec && w_u.wb_en && w_u.wb == r) return w_rb;
        return v;
    endfunction

    logic [31:0] ea, eb, ec;
    always_comb begin
        ea = fwd(e_u.ra, e_u.ra_rd, e_u.a);
        eb = fwd(e_u.rb, e_u.rb_rd, e_u.b);
        ec = fwd(e_u.rc, e_u.rc_rd, e_u.c);
    end

    // a load in M that this uop needs: wait for it to reach W
    function automatic logic needs(input logic [4:0] r);
        return (e_u.ra_rd && e_u.ra == r) || (e_u.rb_rd && e_u.rb == r) || (e_u.rc_rd && e_u.rc == r);
    endfunction
    assign e_ldwait = e_valid && m_valid && m_exec && m_u.kind == K_LOAD && m_u.wa_en
                      && !m_u.wa_pc && needs(m_u.wa);

    // shifter and ALU
    logic [31:0] sh_res, op2;
    logic        sh_c, op2_c;
    arm_shift u_shift (
        .val(eb), .typ(e_u.sh_typ), .amt(e_u.sh_reg ? ec[7:0] : {3'd0, e_u.sh_amt}),
        .imm_form(!e_u.sh_reg), .cin(cpsr[29]), .res(sh_res), .cout(sh_c)
    );
    always_comb begin
        op2   = e_u.use_imm ? e_u.imm : sh_res;
        op2_c = e_u.use_imm ? (e_u.imm_rot ? e_u.imm[31] : cpsr[29]) : sh_c;
    end
    logic [31:0] alu_res;
    logic  [3:0] alu_nzcv;
    arm_alu u_alu (
        .op(e_u.alu_op), .a(ea), .b(op2), .cin(cpsr[29]), .shc(op2_c), .vin(cpsr[28]),
        .res(alu_res), .nzcv(alu_nzcv)
    );

    // multiplier: two pipeline stages in the DSP blocks, E holds meanwhile
    logic  [1:0] mcnt;
    logic [65:0] mp1, mp2;
    logic [63:0] mprod;                     // the product register (K_MULL -> K_MULH)
    logic        e_is_mul;
    assign e_is_mul = e_valid && (e_u.kind == K_MUL || e_u.kind == K_MULL);
    assign e_busy   = e_is_mul && mcnt != 2'd2;
    always_ff @(posedge clk) begin
        mp1 <= $signed({e_u.mul_signed && eb[31], eb}) * $signed({e_u.mul_signed && ec[31], ec});
        mp2 <= mp1;
        if (rst || !e_valid || e_adv) mcnt <= 2'd0;
        else if (e_busy && !e_ldwait) mcnt <= mcnt + 2'd1;
    end

    // LDM/STM base, latched by the first element
    logic [31:0] lsm_base;

    // what this uop does, if its condition passes
    logic        e_pass, e_commit;
    logic [31:0] e_cpsr_n, e_ra, e_rb, e_addr, e_base, e_off, e_ea, e_wdata, e_spsr_cur;
    logic  [3:0] e_be;
    logic        e_wa_en, e_wb_en, e_mem;
    logic  [4:0] e_wa;
    logic [63:0] e_long;
    logic        e_spsr_we;
    logic [31:0] e_spsr_n;
    logic  [4:0] e_spsr_mode;
    logic [31:0] msr_mask, msr_v;

    always_comb begin
        e_spsr_cur = spsr_of(cpsr[4:0]);
        e_pass   = cond_ok(e_u.cond, cpsr);
        e_cpsr_n = cpsr;
        e_ra = alu_res; e_rb = 32'd0;
        e_wa_en = e_u.wa_en; e_wa = e_u.wa; e_wb_en = e_u.wb_en;
        e_redirect = 1'b0; e_target = 32'd0; e_tthumb = cpsr[5];
        e_spsr_we = 1'b0; e_spsr_n = cpsr; e_spsr_mode = cpsr[4:0];
        e_long = 64'd0;
        msr_v = e_u.use_imm ? e_u.imm : eb;
        msr_mask = {{8{e_u.msr_mask[3]}}, {8{e_u.msr_mask[2]}}, {8{e_u.msr_mask[1]}}, {8{e_u.msr_mask[0]}}}
                   & 32'hF000_00FF;     // v4: only NZCV and the control byte exist

        // addresses
        e_off  = e_u.use_imm ? e_u.imm : sh_res;
        e_base = e_u.lsm ? (e_u.lsm_latch ? ea : lsm_base) : ea;
        e_ea   = e_u.lsm ? e_base + e_u.imm : (e_u.up ? e_base + e_off : e_base - e_off);
        e_addr = (e_u.lsm || e_u.pre) ? e_ea : e_base;
        e_mem  = e_u.kind == K_LOAD || e_u.kind == K_STORE;
        case (e_u.msize)
            2'd0:    begin e_wdata = {4{ec[7:0]}};  e_be = 4'b0001 << e_addr[1:0]; end
            2'd1:    begin e_wdata = {2{ec[15:0]}}; e_be = e_addr[1] ? 4'b1100 : 4'b0011; end
            default: begin e_wdata = ec;            e_be = 4'b1111; end
        endcase

        case (e_u.kind)
            K_ALU: begin
                if (e_u.setflags) e_cpsr_n[31:28] = alu_nzcv;
                if (e_u.wa_pc) begin
                    e_redirect = 1'b1;
                    if (e_u.restore) begin
                        e_cpsr_n = e_spsr_cur;
                        e_tthumb = e_spsr_cur[5];
                    end
                    e_target = alu_res & (e_tthumb ? 32'hFFFF_FFFE : 32'hFFFF_FFFC);
                    e_wa_en = 1'b0;
                end
            end
            K_MUL: begin
                e_ra = mp2[31:0] + (e_u.mul_acc ? ea : 32'd0);
                if (e_u.setflags) e_cpsr_n[31:30] = {e_ra[31], e_ra == 32'd0};
            end
            K_MULL: begin
                e_long = mp2[63:0];
                e_ra = e_long[31:0]; e_rb = e_long[63:32];
                if (e_u.setflags) e_cpsr_n[31:30] = {e_long[63], e_long == 64'd0};
            end
            K_MULH: begin
                e_long = mprod + {ec, ea};
                e_ra = e_long[31:0]; e_rb = e_long[63:32];
                if (e_u.setflags) e_cpsr_n[31:30] = {e_long[63], e_long == 64'd0};
            end
            K_LOAD, K_STORE: begin
                e_rb = e_u.lsm ? e_base + e_u.lsm_wb : e_ea;
                if (e_u.kind == K_LOAD && e_u.restore) e_cpsr_n = e_spsr_cur;   // LDM^ with PC
            end
            K_BRANCH: begin
                e_target = (e_u.ra_rd ? ea : 32'd0) + e_u.imm;
                e_target = e_target & (cpsr[5] ? 32'hFFFF_FFFE : 32'hFFFF_FFFC);
                e_redirect = !e_dred;
                e_ra = e_u.pc + (e_u.thumb ? 32'd2 : 32'd4) + {31'd0, e_u.thumb};
            end
            K_BX: begin
                e_redirect = 1'b1;
                e_tthumb = eb[0];
                e_target = eb & (eb[0] ? 32'hFFFF_FFFE : 32'hFFFF_FFFC);
                e_cpsr_n[5] = eb[0];
            end
            K_MRS: e_ra = e_u.psr_spsr ? e_spsr_cur : cpsr;
            K_MSR: begin
                // fields: f 31:24, s 23:16, x 15:8, c 7:0; T is never written; in
                // user mode only the flags are
                if (e_u.psr_spsr) begin
                    e_spsr_we = cpsr[4:0] != M_USR && cpsr[4:0] != M_SYS;
                    e_spsr_n = (e_spsr_cur & ~msr_mask) | (msr_v & msr_mask);
                end else begin
                    if (cpsr[4:0] == M_USR) msr_mask = msr_mask & 32'hFF00_0000;
                    msr_mask = msr_mask & ~32'h0000_0020;
                    e_cpsr_n = (cpsr & ~msr_mask) | (msr_v & msr_mask);
                    if (msr_mask[7:0] != 8'd0) begin   // mode may have changed: refetch
                        e_redirect = 1'b1;
                        e_target = e_u.pc + (e_u.thumb ? 32'd2 : 32'd4);
                    end
                end
            end
            K_EXC: begin
                if (e_u.irq && cpsr[7]) begin           // masked since D: just refetch
                    e_redirect = 1'b1;
                    e_target = e_u.pc; e_tthumb = e_u.thumb;
                    e_wa_en = 1'b0;
                end else begin
                    e_spsr_we = 1'b1; e_spsr_mode = e_u.exc_mode; e_spsr_n = cpsr;
                    e_cpsr_n = {cpsr[31:8], 1'b1, cpsr[6], 1'b0, e_u.exc_mode};
                    e_redirect = 1'b1;
                    e_target = {27'd0, e_u.exc_vec, 2'b00};
                    e_tthumb = 1'b0;
                    e_wa_en = 1'b1; e_wa = e_u.exc_lr_reg; e_ra = e_u.exc_lr;
                end
            end
            default: ;
        endcase

        if (!e_pass) begin
            e_cpsr_n = cpsr; e_redirect = 1'b0; e_spsr_we = 1'b0;
            e_wa_en = 1'b0; e_wb_en = 1'b0; e_mem = 1'b0;
        end
        e_redirect = e_redirect && e_commit;
    end

    assign e_adv    = e_valid && !m_hold && !e_busy && !e_ldwait;
    assign e_commit = e_adv && !m_redirect;

    assign dc_req   = e_valid && e_mem && e_commit;
    assign dc_we    = e_u.kind == K_STORE;
    assign dc_addr  = e_addr;
    assign dc_wdata = e_wdata;
    assign dc_be    = e_be;
    assign dc_size  = e_u.msize;

    always_ff @(posedge clk) begin
        if (rst) begin
            cpsr <= 32'h0000_00D3;
            spsr_fiq <= 32'd0; spsr_svc <= 32'd0; spsr_abt <= 32'd0; spsr_irq <= 32'd0; spsr_und <= 32'd0;
            e_valid <= 1'b0; e_dred <= 1'b0; e_u <= '0;
            lsm_base <= 32'd0; mprod <= 64'd0;
        end else begin
            // ---- E commits: CPSR, SPSR, the product and base registers
            if (e_commit) begin
                cpsr <= e_cpsr_n;
                if (e_spsr_we)
                    case (e_spsr_mode)
                        M_FIQ: spsr_fiq <= e_spsr_n;
                        M_SVC: spsr_svc <= e_spsr_n;
                        M_ABT: spsr_abt <= e_spsr_n;
                        M_IRQ: spsr_irq <= e_spsr_n;
                        M_UND: spsr_und <= e_spsr_n;
                        default: ;
                    endcase
                if (e_u.kind == K_MULL) mprod <= mp2[63:0];
                if (e_u.lsm && e_u.lsm_latch) lsm_base <= ea;
            end
            if (m_dabt_take) begin                      // a data abort, from M
                cpsr <= {cpsr[31:8], 1'b1, cpsr[6], 1'b0, M_ABT};
                spsr_abt <= cpsr;
            end

            // ---- D -> E
            if (e_redirect || m_redirect || m_dabt_take) begin
                e_valid <= 1'b0;
            end else if (e_free) begin
                e_valid <= d_issue;
                e_u <= d_u;
                e_dred <= d_redirect;
            end else begin
                // held: keep the operands current as older results retire
                e_u.a <= ea; e_u.b <= eb; e_u.c <= ec;
            end
        end
    end

    // ============================================================ M
    logic [31:0] m_addr, m_cpsr, m_ld;
    always_comb begin
        m_hold = m_valid && m_mem && !dc_ok;
        // load alignment
        case (m_u.msize)
            2'd0: begin
                m_ld = {24'd0, dc_rdata[{m_addr[1:0], 3'b000} +: 8]};
                if (m_u.msigned) m_ld = {{24{m_ld[7]}}, m_ld[7:0]};
            end
            2'd1: begin
                m_ld = {16'd0, m_addr[1] ? dc_rdata[31:16] : dc_rdata[15:0]};
                if (m_u.msigned) m_ld = {{16{m_ld[15]}}, m_ld[15:0]};
            end
            default: m_ld = (dc_rdata >> {m_addr[1:0], 3'b000}) | (dc_rdata << (6'd32 - {1'b0, m_addr[1:0], 3'b000}));
        endcase
        if (m_addr[1:0] == 2'd0 && m_u.msize == 2'd2) m_ld = dc_rdata;
        m_dabt_take = m_valid && m_mem && dc_ok && dc_abort;
        m_redirect = (m_valid && m_mem && dc_ok && m_exec && m_u.kind == K_LOAD && m_u.wa_pc) || m_dabt_take;
        m_tthumb = m_dabt_take ? 1'b0 : cpsr[5];
        m_target = m_dabt_take ? 32'h0000_0010 : (m_ld & (cpsr[5] ? 32'hFFFF_FFFE : 32'hFFFF_FFFC));
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            m_valid <= 1'b0; m_exec <= 1'b0; m_mem <= 1'b0; m_u <= '0;
            m_ra <= 32'd0; m_rb <= 32'd0; m_addr <= 32'd0; m_cpsr <= 32'd0;
        end else if (!m_hold) begin
            m_valid <= e_commit;
            m_u <= e_u;
            m_u.wa_en <= e_wa_en; m_u.wa <= e_wa; m_u.wb_en <= e_wb_en;
            m_exec <= e_pass;
            m_mem <= e_mem;
            m_ra <= e_ra; m_rb <= e_rb;
            m_addr <= e_addr;
            m_cpsr <= e_cpsr_n;
        end
    end

    // ============================================================ W
    logic [31:0] w_cpsr;
    always_ff @(posedge clk) begin
        if (rst) begin
            w_valid <= 1'b0; w_exec <= 1'b0; w_u <= '0; w_ra <= 32'd0; w_rb <= 32'd0; w_cpsr <= 32'd0;
        end else begin
            w_valid <= m_valid && !m_hold;
            w_u <= m_u;
            w_exec <= m_exec;
            w_ra <= (m_u.kind == K_LOAD) ? m_ld : m_ra;
            w_rb <= m_rb;
            w_cpsr <= m_cpsr;
            if (m_dabt_take) begin                      // the aborted access writes nothing but LR_abt
                w_u.wa_en <= 1'b1; w_u.wa <= 5'd26; w_u.wa_pc <= 1'b0; w_u.wb_en <= 1'b0;
                w_ra <= m_u.pc + 32'd8;
                w_cpsr <= {cpsr[31:8], 1'b1, cpsr[6], 1'b0, M_ABT};
            end
        end
    end

    assign rf_wa_en = w_valid && w_exec && w_u.wa_en && !w_u.wa_pc;
    assign rf_wa    = w_u.wa;
    assign rf_da    = w_ra;
    assign rf_wb_en = w_valid && w_exec && w_u.wb_en;
    assign rf_wb    = w_u.wb;
    assign rf_db    = w_rb;

    assign rt_valid = w_valid && (w_u.irq ? w_u.wa_en : w_u.last);   // a masked IRQ is no event
    assign rt_irq   = w_u.irq && w_u.wa_en;
    assign rt_pc    = w_u.pc;
    assign rt_instr = w_u.instr;
    assign rt_thumb = w_u.thumb;
    assign rt_cpsr  = w_cpsr;
endmodule
