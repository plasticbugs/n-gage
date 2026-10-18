//------------------------------------------------------------------------------
// Thumb (ARMv4T) to ARM: each Thumb instruction as the ARM instruction with
// the same effect, so one decoder serves both.  Where the Thumb immediate has
// no ARM encoding (offsets, branch displacements, ADD SP), the ARM word
// carries a placeholder and imm_ovr gives the value; pc_align marks the
// forms that read PC rounded down to a word (LDR [PC], ADD Rd, PC).  The BL
// suffix has no ARM equivalent at all and is flagged on its own.
//------------------------------------------------------------------------------
`default_nettype none

module arm_thumb (
    input  logic [15:0] t,
    output logic [31:0] arm,
    output logic        imm_ovr_en,
    output logic [31:0] imm_ovr,
    output logic        pc_align,
    output logic        bl_suffix,  // PC = LR + imm_ovr; LR = next | 1
    output logic        und
);
    logic [2:0] rd, rs, rn;
    logic [3:0] hd, hs;
    logic [7:0] imm8;
    logic [4:0] off5;

    always_comb begin
        rd = t[2:0]; rs = t[5:3]; rn = t[8:6];
        hd = {t[7], t[2:0]}; hs = {t[6], t[5:3]};
        imm8 = t[7:0]; off5 = t[10:6];
        arm = 32'hE1A00000;                 // MOV r0, r0
        imm_ovr_en = 1'b0; imm_ovr = 32'd0;
        pc_align = 1'b0; bl_suffix = 1'b0; und = 1'b0;

        casez (t[15:11])
            5'b000_??: if (t[12:11] != 2'b11)                       // shift by immediate
                    arm = 32'hE1B00000 | {16'd0, 1'b0, rd, off5, t[12:11], 1'b0, 1'b0, rs};
                else if (!t[10])                                     // ADD/SUB register
                    arm = (t[9] ? 32'hE0500000 : 32'hE0900000) | {12'd0, 1'b0, rs, 1'b0, rd, 9'd0, rn};
                else                                                 // ADD/SUB #3
                    arm = (t[9] ? 32'hE2500000 : 32'hE2900000) | {12'd0, 1'b0, rs, 1'b0, rd, 9'd0, rn};
            5'b001_??: case (t[12:11])                               // MOV/CMP/ADD/SUB #8
                    2'd0: arm = 32'hE3B00000 | {16'd0, 1'b0, t[10:8], 4'd0, imm8};
                    2'd1: arm = 32'hE3500000 | {12'd0, 1'b0, t[10:8], 8'd0, imm8};
                    2'd2: arm = 32'hE2900000 | {12'd0, 1'b0, t[10:8], 1'b0, t[10:8], 4'd0, imm8};
                    default: arm = 32'hE2500000 | {12'd0, 1'b0, t[10:8], 1'b0, t[10:8], 4'd0, imm8};
                endcase
            5'b010_00: if (!t[10]) begin                             // ALU operations
                    case (t[9:6])
                        4'h0: arm = 32'hE0100000 | {12'd0, 1'b0, rd, 1'b0, rd, 9'd0, rs};
                        4'h1: arm = 32'hE0300000 | {12'd0, 1'b0, rd, 1'b0, rd, 9'd0, rs};
                        4'h2: arm = 32'hE1B00010 | {16'd0, 1'b0, rd, 1'b0, rs, 4'd0, 1'b0, rd};
                        4'h3: arm = 32'hE1B00030 | {16'd0, 1'b0, rd, 1'b0, rs, 4'd0, 1'b0, rd};
                        4'h4: arm = 32'hE1B00050 | {16'd0, 1'b0, rd, 1'b0, rs, 4'd0, 1'b0, rd};
                        4'h5: arm = 32'hE0B00000 | {12'd0, 1'b0, rd, 1'b0, rd, 9'd0, rs};
                        4'h6: arm = 32'hE0D00000 | {12'd0, 1'b0, rd, 1'b0, rd, 9'd0, rs};
                        4'h7: arm = 32'hE1B00070 | {16'd0, 1'b0, rd, 1'b0, rs, 4'd0, 1'b0, rd};
                        4'h8: arm = 32'hE1100000 | {12'd0, 1'b0, rd, 13'd0, rs};
                        4'h9: arm = 32'hE2700000 | {12'd0, 1'b0, rs, 1'b0, rd, 12'd0};   // RSBS Rd, Rs, #0
                        4'hA: arm = 32'hE1500000 | {12'd0, 1'b0, rd, 13'd0, rs};
                        4'hB: arm = 32'hE1700000 | {12'd0, 1'b0, rd, 13'd0, rs};
                        4'hC: arm = 32'hE1900000 | {12'd0, 1'b0, rd, 1'b0, rd, 9'd0, rs};
                        4'hD: arm = 32'hE0100090 | {12'd0, 1'b0, rd, 5'd0, rs, 5'd0, rd}; // MULS Rd, Rd, Rs
                        4'hE: arm = 32'hE1D00000 | {12'd0, 1'b0, rd, 1'b0, rd, 9'd0, rs};
                        default: arm = 32'hE1F00000 | {16'd0, 1'b0, rd, 9'd0, rs};
                    endcase
                end else begin                                       // hi registers, BX
                    case (t[9:8])
                        2'd0: arm = 32'hE0800000 | {12'd0, hd, hd, 8'd0, hs};
                        2'd1: arm = 32'hE1500000 | {12'd0, hd, 12'd0, hs};
                        2'd2: arm = 32'hE1A00000 | {16'd0, hd, 8'd0, hs};
                        default: arm = 32'hE12FFF10 | {28'd0, hs};
                    endcase
                end
            5'b010_01: begin                                         // LDR Rd, [PC, #]
                    arm = 32'hE59F0000 | {16'd0, 1'b0, t[10:8], 12'd0};
                    imm_ovr_en = 1'b1; imm_ovr = {22'd0, imm8, 2'b00}; pc_align = 1'b1;
                end
            5'b010_1?: if (!t[9])                                    // LDR/STR[B] [Rb, Ro]
                    arm = 32'hE7800000 | {9'd0, t[10], 1'b0, t[11], 1'b0, rs, 1'b0, rd, 9'd0, rn};
                else case (t[11:10])                                 // STRH/LDRH/LDSB/LDSH [Rb, Ro]
                    2'd0: arm = 32'hE18000B0 | {12'd0, 1'b0, rs, 1'b0, rd, 9'd0, rn};
                    2'd1: arm = 32'hE19000D0 | {12'd0, 1'b0, rs, 1'b0, rd, 9'd0, rn};
                    2'd2: arm = 32'hE19000B0 | {12'd0, 1'b0, rs, 1'b0, rd, 9'd0, rn};
                    default: arm = 32'hE19000F0 | {12'd0, 1'b0, rs, 1'b0, rd, 9'd0, rn};
                endcase
            5'b011_??: begin                                         // LDR/STR[B] [Rb, #]
                    arm = 32'hE5800000 | {9'd0, t[12], 1'b0, t[11], 1'b0, rs, 1'b0, rd, 12'd0};
                    imm_ovr_en = 1'b1;
                    imm_ovr = t[12] ? {27'd0, off5} : {25'd0, off5, 2'b00};
                end
            5'b100_0?: begin                                         // LDRH/STRH [Rb, #]
                    arm = 32'hE1C000B0 | {11'd0, t[11], 1'b0, rs, 1'b0, rd, 12'd0};
                    imm_ovr_en = 1'b1; imm_ovr = {26'd0, off5, 1'b0};
                end
            5'b100_1?: begin                                         // LDR/STR [SP, #]
                    arm = 32'hE58D0000 | {11'd0, t[11], 4'd0, 1'b0, t[10:8], 12'd0};
                    imm_ovr_en = 1'b1; imm_ovr = {22'd0, imm8, 2'b00};
                end
            5'b101_0?: begin                                         // ADD Rd, PC/SP, #
                    arm = (t[11] ? 32'hE28D0000 : 32'hE28F0000) | {16'd0, 1'b0, t[10:8], 12'd0};
                    imm_ovr_en = 1'b1; imm_ovr = {22'd0, imm8, 2'b00}; pc_align = !t[11];
                end
            5'b101_1?: casez (t[11:8])
                    4'b0000: begin                                   // ADD/SUB SP, #
                        arm = t[7] ? 32'hE24DD000 : 32'hE28DD000;
                        imm_ovr_en = 1'b1; imm_ovr = {23'd0, t[6:0], 2'b00};
                    end
                    4'b010?: arm = 32'hE92D0000 | {17'd0, t[8], 6'd0, imm8};   // PUSH
                    4'b110?: arm = 32'hE8BD0000 | {16'd0, t[8], 7'd0, imm8};   // POP
                    default: und = 1'b1;
                endcase
            5'b110_0?:                                               // STMIA/LDMIA Rb!
                arm = 32'hE8A00000 | {11'd0, t[11], 1'b0, t[10:8], 8'd0, imm8};
            5'b110_1?: if (t[11:8] == 4'hF)                          // SWI
                    arm = 32'hEF000000 | {24'd0, imm8};
                else if (t[11:8] == 4'hE)
                    und = 1'b1;
                else begin                                           // B<cond>
                    arm = {t[11:8], 28'hA000000};
                    imm_ovr_en = 1'b1; imm_ovr = {{23{imm8[7]}}, imm8, 1'b0};
                end
            5'b111_00: begin                                         // B
                    arm = 32'hEA000000;
                    imm_ovr_en = 1'b1; imm_ovr = {{20{t[10]}}, t[10:0], 1'b0};
                end
            5'b111_10: begin                                         // BL prefix: LR = PC + off << 12
                    arm = 32'hE28FE000;
                    imm_ovr_en = 1'b1; imm_ovr = {{9{t[10]}}, t[10:0], 12'd0};
                end
            5'b111_11: begin                                         // BL suffix
                    bl_suffix = 1'b1;
                    imm_ovr_en = 1'b1; imm_ovr = {20'd0, t[10:0], 1'b0};
                end
            default: und = 1'b1;                                     // 11101: BLX (v5)
        endcase
    end
endmodule
