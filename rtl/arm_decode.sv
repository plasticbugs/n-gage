//------------------------------------------------------------------------------
// ARMv4 decode: one step of an instruction as a micro-op (arm_uop.svh), with
// registers already mapped to physical indices for the current mode.
//
// Most instructions are one step.  The others are walked by the D stage,
// which feeds back `step` and, for LDM/STM, the registers still to transfer
// (`rem`) and how many have gone (`k`):
//   LDM/STM            one step per register, lowest first; the first also
//                      latches the base and writes it back
//   SWP                load to the temporary, store Rm, move the temporary
//   UMLAL/SMLAL        multiply into the product register, then add RdHi:RdLo
//
// Operand values are not read here.  ra_pc/rb_pc/rc_pc say an operand is
// R15, whose value D supplies (the address plus 8, or plus 4 in Thumb, and
// rounded down to a word where pc_align says so).
//------------------------------------------------------------------------------
`default_nettype none

module arm_decode
    import arm_pkg::*;
(
    input  logic [31:0] instr,          // ARM, or arm_thumb's expansion
    input  logic        thumb,
    input  logic [15:0] thumb_raw,      // the Thumb halfword, for the trace
    input  logic        imm_ovr_en,
    input  logic [31:0] imm_ovr,
    input  logic        bl_suffix,
    input  logic        t_und,
    input  logic        pabt,           // the fetch faulted
    input  logic [31:0] pc,
    input  logic [31:0] pc_op,          // R15 as an operand: pc + 8 or + 4 (aligned if asked)
    input  logic  [4:0] mode,
    input  logic  [1:0] step,
    input  logic [15:0] rem,            // LDM/STM registers still to go (all of them at step 0)
    input  logic  [4:0] k,              // LDM/STM registers already gone
    output uop_t        u,
    output logic        ra_pc, rb_pc, rc_pc,
    output logic        more,           // another step follows this one
    output logic [15:0] rem_next
);
    function automatic logic [4:0] phys(input logic [3:0] r, input logic [4:0] m);
        logic [4:0] p;
        p = {1'b0, r};
        if (r >= 4'd8 && r != 4'd15) begin
            if (m == M_FIQ) p = 5'd16 + {1'b0, r} - 5'd8;
            else if (r >= 4'd13) begin
                case (m)
                    M_SVC: p = (r == 4'd13) ? 5'd23 : 5'd24;
                    M_ABT: p = (r == 4'd13) ? 5'd25 : 5'd26;
                    M_IRQ: p = (r == 4'd13) ? 5'd27 : 5'd28;
                    M_UND: p = (r == 4'd13) ? 5'd29 : 5'd30;
                    default: ;
                endcase
            end
        end
        return p;
    endfunction

    function automatic logic [31:0] ror32(input logic [31:0] x, input logic [4:0] n);
        logic [63:0] w;
        w = {x, x} >> n;
        return w[31:0];
    endfunction

    function automatic logic [4:0] popcount16(input logic [15:0] x);
        logic [4:0] n;
        n = 5'd0;
        for (int i = 0; i < 16; i++) n = n + {4'd0, x[i]};
        return n;
    endfunction

    logic [3:0]  rn, rd, rs, rm, lreg;
    logic [31:0] rot_imm, ilen, link;
    logic [4:0]  nregs;
    logic [31:0] lsm_start;
    logic        lsm_user;

    always_comb begin
        rn = instr[19:16]; rd = instr[15:12]; rs = instr[11:8]; rm = instr[3:0];
        rot_imm = ror32({24'd0, instr[7:0]}, {instr[11:8], 1'b0});
        ilen = thumb ? 32'd2 : 32'd4;
        link = pc + ilen;

        // LDM/STM: the register this step moves, and the block's geometry
        lreg = 4'd0;
        for (int i = 15; i >= 0; i--) if (rem[i]) lreg = i[3:0];
        rem_next = rem & ~(16'd1 << lreg);
        nregs = popcount16(instr[15:0]);
        case ({instr[24], instr[23]})                   // P U
            2'b01:   lsm_start = 32'd0;                                  // IA
            2'b11:   lsm_start = 32'd4;                                  // IB
            2'b00:   lsm_start = 32'd4 - {25'd0, nregs, 2'b00};          // DA
            default: lsm_start = 32'd0 - {25'd0, nregs, 2'b00};          // DB
        endcase
        lsm_user = instr[22] && !(instr[20] && instr[15]);   // ^ without a PC load: user bank

        u = '0;
        u.valid = 1'b1;
        u.pc = pc;
        u.thumb = thumb;
        u.instr = thumb ? {16'd0, thumb_raw} : instr;
        u.first = (step == 2'd0) && (k == 5'd0);
        u.cond = thumb ? (instr[27:25] == 3'b101 ? instr[31:28] : 4'hE) : instr[31:28];
        u.kind = K_NOP;
        ra_pc = 1'b0; rb_pc = 1'b0; rc_pc = 1'b0;
        more = 1'b0;

        if (pabt || t_und) begin
            // fetch abort, or an undefined Thumb encoding
            u.kind = K_EXC;
            u.cond = 4'hE;
            u.exc_vec = pabt ? 3'd3 : 3'd1;
            u.exc_mode = pabt ? M_ABT : M_UND;
            u.exc_lr = pabt ? pc + 32'd4 : link;
            u.exc_lr_reg = phys(4'd14, pabt ? M_ABT : M_UND);
        end else if (bl_suffix) begin
            u.kind = K_BRANCH;
            u.cond = 4'hE;
            u.ra = phys(4'd14, mode); u.ra_rd = 1'b1;
            u.imm = imm_ovr;
            u.wa_en = 1'b1; u.wa = phys(4'd14, mode);
        end else if (instr[31:28] == 4'hF) begin
            u.kind = K_EXC; u.cond = 4'hE;              // no unconditional space in v4
            u.exc_vec = 3'd1; u.exc_mode = M_UND; u.exc_lr = link; u.exc_lr_reg = phys(4'd14, M_UND);
        end else if (instr[27:25] == 3'b000 && instr[7] && instr[4] && instr[6:5] != 2'b00) begin
            // LDRH/STRH/LDRSB/LDRSH; the store forms of SB/SH are v5's LDRD/STRD
            if (!instr[20] && instr[6]) und();
            else begin
                u.kind = instr[20] ? K_LOAD : K_STORE;
                u.msize = instr[5] ? 2'd1 : 2'd0;
                u.msigned = instr[6];
                u.pre = instr[24]; u.up = instr[23];
                u.ra = phys(rn, mode); u.ra_rd = 1'b1; ra_pc = rn == 4'd15;
                if (instr[22]) begin
                    u.use_imm = 1'b1;
                    u.imm = imm_ovr_en ? imm_ovr : {24'd0, instr[11:8], instr[3:0]};
                end else begin
                    u.rb = phys(rm, mode); u.rb_rd = 1'b1; rb_pc = rm == 4'd15;
                end
                if (instr[20]) begin
                    u.wa_en = 1'b1; u.wa = phys(rd, mode); u.wa_pc = rd == 4'd15;
                end else begin
                    u.rc = phys(rd, mode); u.rc_rd = 1'b1; rc_pc = rd == 4'd15;
                end
                if (!instr[24] || instr[21]) begin u.wb_en = 1'b1; u.wb = phys(rn, mode); end
            end
        end else
        /* verilator lint_off CASEOVERLAP */      // first match wins, by design
        casez (instr[27:20])
            // ---------------------------------------------------- multiplies, SWP
            8'b0000_00??: if (instr[7:4] == 4'b1001) begin                  // MUL, MLA
                    u.kind = K_MUL;
                    u.rb = phys(rm, mode); u.rb_rd = 1'b1;
                    u.rc = phys(rs, mode); u.rc_rd = 1'b1;
                    u.mul_acc = instr[21];
                    u.ra = phys(rd, mode); u.ra_rd = instr[21];             // Rn of MLA is bits 15:12
                    u.wa_en = 1'b1; u.wa = phys(rn, mode);                  // Rd is bits 19:16
                    u.setflags = instr[20];
                    ra_pc = instr[21] && rd == 4'd15;
                    rb_pc = rm == 4'd15; rc_pc = rs == 4'd15;
                end else dp();
            8'b0000_1???: if (instr[7:4] == 4'b1001) begin                  // UMULL..SMLAL
                    u.mul_signed = instr[22];
                    u.mul_acc = instr[21];
                    if (step == 2'd0) begin
                        u.kind = K_MULL;
                        u.rb = phys(rm, mode); u.rb_rd = 1'b1;
                        u.rc = phys(rs, mode); u.rc_rd = 1'b1;
                        rb_pc = rm == 4'd15; rc_pc = rs == 4'd15;
                        if (!instr[21]) begin
                            u.wa_en = 1'b1; u.wa = phys(rd, mode);          // RdLo
                            u.wb_en = 1'b1; u.wb = phys(rn, mode);          // RdHi
                            u.setflags = instr[20];
                        end else more = 1'b1;
                    end else begin
                        u.kind = K_MULH;
                        u.ra = phys(rd, mode); u.ra_rd = 1'b1;              // RdLo
                        u.rc = phys(rn, mode); u.rc_rd = 1'b1;              // RdHi
                        u.wa_en = 1'b1; u.wa = phys(rd, mode);
                        u.wb_en = 1'b1; u.wb = phys(rn, mode);
                        u.setflags = instr[20];
                    end
                end else dp();
            8'b0001_0?00: if (instr[11:4] == 8'b0000_1001) begin            // SWP, SWPB
                    u.msize = instr[22] ? 2'd0 : 2'd2;
                    u.ra = phys(rn, mode); u.ra_rd = step != 2'd2;
                    u.pre = 1'b1; u.up = 1'b1; u.use_imm = 1'b1;
                    case (step)
                        2'd0: begin u.kind = K_LOAD; u.wa_en = 1'b1; u.wa = 5'd31; more = 1'b1; end
                        2'd1: begin u.kind = K_STORE; u.rc = phys(rm, mode); u.rc_rd = 1'b1; more = 1'b1; end
                        default: begin
                            u.kind = K_ALU; u.alu_op = 4'hD;
                            u.rb = 5'd31; u.rb_rd = 1'b1;
                            u.wa_en = 1'b1; u.wa = phys(rd, mode);
                        end
                    endcase
                end else if (instr[7:4] == 4'b0000 && !instr[21]) begin    // MRS
                    u.kind = K_MRS;
                    u.psr_spsr = instr[22];
                    u.wa_en = 1'b1; u.wa = phys(rd, mode);
                end else dp();
            8'b0001_0?10: if (instr[7:4] == 4'b0000) begin                  // MSR register
                    u.kind = K_MSR;
                    u.psr_spsr = instr[22];
                    u.msr_mask = instr[19:16];
                    u.rb = phys(rm, mode); u.rb_rd = 1'b1;
                end else if (instr[27:4] == 24'h12FFF1) begin               // BX
                    u.kind = K_BX;
                    u.rb = phys(rm, mode); u.rb_rd = 1'b1; rb_pc = rm == 4'd15;
                end else dp();
            8'b0011_0?10: begin                                             // MSR immediate
                    u.kind = K_MSR;
                    u.psr_spsr = instr[22];
                    u.msr_mask = instr[19:16];
                    u.imm = rot_imm; u.use_imm = 1'b1;
                end
            8'b00??_????: dp();
            // ---------------------------------------------------- LDR/STR
            8'b01??_????: if (instr[25] && instr[4]) und();
                else begin
                    u.kind = instr[20] ? K_LOAD : K_STORE;
                    u.msize = instr[22] ? 2'd0 : 2'd2;
                    u.pre = instr[24]; u.up = instr[23];
                    u.ra = phys(rn, mode); u.ra_rd = 1'b1; ra_pc = rn == 4'd15;
                    if (instr[25]) begin
                        u.rb = phys(rm, mode); u.rb_rd = 1'b1; rb_pc = rm == 4'd15;
                        u.sh_typ = instr[6:5]; u.sh_amt = instr[11:7];
                    end else begin
                        u.use_imm = 1'b1;
                        u.imm = imm_ovr_en ? imm_ovr : {20'd0, instr[11:0]};
                    end
                    if (instr[20]) begin
                        u.wa_en = 1'b1; u.wa = phys(rd, mode); u.wa_pc = rd == 4'd15;
                    end else begin
                        u.rc = phys(rd, mode); u.rc_rd = 1'b1; rc_pc = rd == 4'd15;
                    end
                    if (!instr[24] || instr[21]) begin u.wb_en = 1'b1; u.wb = phys(rn, mode); end
                end
            // ---------------------------------------------------- LDM/STM
            8'b100?_????: begin
                    u.kind = instr[20] ? K_LOAD : K_STORE;
                    u.msize = 2'd2; u.pre = 1'b1; u.up = 1'b1;
                    u.lsm = 1'b1;
                    u.lsm_latch = k == 5'd0;
                    u.imm = lsm_start + {25'd0, k, 2'b00};
                    u.lsm_wb = instr[23] ? {25'd0, nregs, 2'b00} : 32'd0 - {25'd0, nregs, 2'b00};
                    u.ra = phys(rn, mode); u.ra_rd = k == 5'd0;
                    if (k == 5'd0 && instr[21]) begin u.wb_en = 1'b1; u.wb = phys(rn, mode); end
                    if (instr[20]) begin
                        u.wa_en = 1'b1;
                        u.wa = phys(lreg, lsm_user ? M_USR : mode);
                        u.wa_pc = lreg == 4'd15;
                        u.restore = lreg == 4'd15 && instr[22];
                    end else begin
                        u.rc = phys(lreg, lsm_user ? M_USR : mode); u.rc_rd = 1'b1;
                        rc_pc = lreg == 4'd15;
                    end
                    more = rem_next != 16'd0;
                end
            // ---------------------------------------------------- B, BL
            8'b101?_????: begin
                    u.kind = K_BRANCH;
                    u.imm = pc_op + (imm_ovr_en ? imm_ovr : {{6{instr[23]}}, instr[23:0], 2'b00});
                    if (instr[24]) begin u.wa_en = 1'b1; u.wa = phys(4'd14, mode); end
                end
            // ---------------------------------------------------- SWI
            8'b1111_????: begin
                    u.kind = K_EXC;
                    u.exc_vec = 3'd2; u.exc_mode = M_SVC;
                    u.exc_lr = link; u.exc_lr_reg = phys(4'd14, M_SVC);
                end
            default: und();                             // coprocessor space
        endcase
        /* verilator lint_on CASEOVERLAP */
        u.last = !more;
    end

    // data processing, register or immediate operand 2
    // These tasks write u and ra_pc..rc_pc, and only the one always_comb
    // calls them.  The lint of version 5.020 counts a task's write as a
    // second driver; later versions do not.
    /* verilator lint_off MULTIDRIVEN */
    task automatic dp();
        logic [3:0] op;
        op = instr[24:21];
        if (op[3:2] == 2'b10 && !instr[20]) und();                     // TST..CMN without S
        else dp_ok(op);
    endtask

    task automatic dp_ok(input logic [3:0] op);
        u.kind = K_ALU;
        u.alu_op = op;
        u.setflags = instr[20] && !(rd == 4'd15 && op[3:2] != 2'b10);
        u.restore = instr[20] && rd == 4'd15 && op[3:2] != 2'b10;
        if (op != 4'hD && op != 4'hF) begin
            u.ra = phys(rn, mode); u.ra_rd = 1'b1; ra_pc = rn == 4'd15;
        end
        if (instr[25]) begin
            u.use_imm = 1'b1;
            u.imm = imm_ovr_en ? imm_ovr : rot_imm;
            u.imm_rot = !imm_ovr_en && instr[11:8] != 4'd0;
        end else begin
            u.rb = phys(rm, mode); u.rb_rd = 1'b1; rb_pc = rm == 4'd15;
            u.sh_typ = instr[6:5];
            if (instr[4]) begin
                u.sh_reg = 1'b1;
                u.rc = phys(rs, mode); u.rc_rd = 1'b1; rc_pc = rs == 4'd15;
            end else
                u.sh_amt = instr[11:7];
        end
        if (op[3:2] != 2'b10) begin
            u.wa_en = 1'b1; u.wa = phys(rd, mode); u.wa_pc = rd == 4'd15;
        end
    endtask

    task automatic und();
        u = '0;
        u.valid = 1'b1; u.pc = pc; u.thumb = thumb;
        u.instr = thumb ? {16'd0, thumb_raw} : instr;
        u.first = 1'b1; u.cond = 4'hE;
        u.kind = K_EXC;
        u.exc_vec = 3'd1; u.exc_mode = M_UND; u.exc_lr = link; u.exc_lr_reg = phys(4'd14, M_UND);
        ra_pc = 1'b0; rb_pc = 1'b0; rc_pc = 1'b0;
    endtask
    /* verilator lint_on MULTIDRIVEN */
endmodule
