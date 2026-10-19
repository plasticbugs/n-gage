//------------------------------------------------------------------------------
// ARM barrel shifter: operand 2 of a data-processing instruction, and the
// scaled register offset of LDR/STR.  ARMv4 semantics, carry out included.
//
//   imm_form = 1: the amount is the instruction's 5-bit field, where LSR #0
//                 and ASR #0 mean 32 and ROR #0 means RRX;
//   imm_form = 0: the amount is the bottom byte of Rs, where 0 means no
//                 shift (carry unchanged) and 32 or more has its own rules.
//
// One right rotator does every type: LSL n is a rotate by 32 - n with the
// bits below n cleared, LSR and ASR a rotate by n with the top n bits
// filled.  The rotate amount, the mask and the fill depend only on the type
// and amount, which are registered where this is used, so only the rotate
// and one select stand between the value and the result.
//------------------------------------------------------------------------------
`default_nettype none

module arm_shift (
    input  logic [31:0] val,
    input  logic  [1:0] typ,        // 0 LSL, 1 LSR, 2 ASR, 3 ROR
    input  logic  [7:0] amt,
    input  logic        imm_form,
    input  logic        cin,
    output logic [31:0] res,
    output logic        cout
);
    typedef enum logic [1:0] { F_ZERO, F_SIGN, F_CIN } fill_t;
    typedef enum logic [1:0] { C_CIN, C_ROT0, C_ROT31, C_ZERO } carry_t;

    logic  [4:0] r;                 // rotate right by
    logic [31:0] keep;              // bits of the rotation kept; the rest are the fill
    fill_t       fsel;
    carry_t      csel;
    logic  [5:0] n;                 // the amount, 1..32, where it is one
    logic        big;               // by register, more than 32

    always_comb begin
        r = 5'd0; keep = 32'hFFFF_FFFF; fsel = F_ZERO; csel = C_CIN;
        big = !imm_form && amt > 8'd32;
        n = (imm_form && amt[4:0] == 5'd0) ? 6'd32 : amt[5:0];
        if (imm_form && amt[4:0] == 5'd0 && typ == 2'd0) ;            // LSL #0: as is
        else if (imm_form && amt[4:0] == 5'd0 && typ == 2'd3) begin    // RRX
            r = 5'd1; keep = 32'h7FFF_FFFF; fsel = F_CIN; csel = C_ROT31;
        end else if (!imm_form && amt == 8'd0) ;                       // by register, 0
        else case (typ)
            2'd0: begin                                                 // LSL
                r = 5'd0 - n[4:0];
                keep = big ? 32'd0 : 32'hFFFF_FFFF << n;
                csel = big ? C_ZERO : C_ROT0;
            end
            2'd1: begin                                                 // LSR
                r = n[4:0];
                keep = big ? 32'd0 : 32'hFFFF_FFFF >> n;
                csel = big ? C_ZERO : C_ROT31;
            end
            2'd2: begin                                                 // ASR: 32 or more is all sign
                r = (big || n == 6'd32) ? 5'd0 : n[4:0];
                keep = (big || n == 6'd32) ? 32'd0 : 32'hFFFF_FFFF >> n;
                fsel = F_SIGN; csel = C_ROT31;
            end
            default: begin                                              // ROR
                r = amt[4:0];
                csel = C_ROT31;
            end
        endcase
    end

    logic [63:0] dbl;
    logic [31:0] rot;
    logic        fill;
    always_comb begin
        dbl  = {val, val} >> r;
        rot  = dbl[31:0];
        case (fsel)
            F_SIGN:  fill = val[31];
            F_CIN:   fill = cin;
            default: fill = 1'b0;
        endcase
        res = (rot & keep) | ({32{fill}} & ~keep);
        case (csel)
            C_ROT0:  cout = rot[0];
            C_ROT31: cout = rot[31];
            C_ZERO:  cout = 1'b0;
            default: cout = cin;
        endcase
    end
endmodule
