//------------------------------------------------------------------------------
// ARM barrel shifter: operand 2 of a data-processing instruction, and the
// scaled register offset of LDR/STR.  ARMv4 semantics, carry out included.
//
//   imm_form = 1: the amount is the instruction's 5-bit field, where LSR #0
//                 and ASR #0 mean 32 and ROR #0 means RRX;
//   imm_form = 0: the amount is the bottom byte of Rs, where 0 means no
//                 shift (carry unchanged) and 32 or more has its own rules.
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
    logic [63:0] dbl;
    logic  [4:0] n;

    always_comb begin
        res  = val;
        cout = cin;
        n    = amt[4:0];
        dbl  = 64'd0;
        if (imm_form && amt[4:0] == 5'd0) begin
            case (typ)
                2'd0: ;                                             // LSL #0: as is
                2'd1: begin res = 32'd0; cout = val[31]; end        // LSR #32
                2'd2: begin res = {32{val[31]}}; cout = val[31]; end // ASR #32
                default: begin res = {cin, val[31:1]}; cout = val[0]; end // RRX
            endcase
        end else if (!imm_form && amt == 8'd0) begin
            ;                                                       // by register, 0
        end else begin
            case (typ)
                2'd0:                                               // LSL
                    if (amt > 8'd32)       begin res = 32'd0; cout = 1'b0; end
                    else if (amt == 8'd32) begin res = 32'd0; cout = val[0]; end
                    else begin
                        dbl  = {32'd0, val} << n;
                        res  = dbl[31:0];
                        cout = dbl[32];
                    end
                2'd1:                                               // LSR
                    if (amt > 8'd32)       begin res = 32'd0; cout = 1'b0; end
                    else if (amt == 8'd32) begin res = 32'd0; cout = val[31]; end
                    else begin
                        dbl  = {val, 32'd0} >> n;
                        res  = dbl[63:32];
                        cout = dbl[31];
                    end
                2'd2:                                               // ASR
                    if (amt >= 8'd32)      begin res = {32{val[31]}}; cout = val[31]; end
                    else begin
                        dbl  = $signed({val, 32'd0}) >>> n;
                        res  = dbl[63:32];
                        cout = dbl[31];
                    end
                default:                                            // ROR
                    if (n == 5'd0) begin res = val; cout = val[31]; end  // by a multiple of 32
                    else begin
                        dbl  = {val, val} >> n;
                        res  = dbl[31:0];
                        cout = dbl[31];
                    end
            endcase
        end
    end
endmodule
