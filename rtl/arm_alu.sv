//------------------------------------------------------------------------------
// ARM data-processing ALU: the sixteen opcodes, and the flags they would set.
// Logical operations take C from the shifter and leave V; arithmetic ones
// take both from the adder.  Whether the flags are written is the caller's.
//
// An arithmetic Z does not wait for the sum: x + y + ci is zero exactly when
// every carry into a bit equals that bit's x ^ y, and then the carry out of
// each bit is x | y, so the test is (x ^ y) == {(x | y) << 1, ci}, with no
// carry chain.  The ALU, its result mux and a 32-bit zero test into CPSR.Z
// was the slowest way into A's flags at 80 MHz.
//------------------------------------------------------------------------------
`default_nettype none

module arm_alu (
    input  logic  [3:0] op,
    input  logic [31:0] a,          // Rn
    input  logic [31:0] b,          // shifter output
    input  logic        cin,        // CPSR.C
    input  logic        shc,        // shifter carry out
    input  logic        vin,        // CPSR.V
    output logic [31:0] res,
    output logic  [3:0] nzcv
);
    logic [32:0] sum;
    logic [31:0] x, y, lres;
    logic        ci, arith, c, v, z;

    always_comb begin
        // every arithmetic opcode is x + y + ci
        x = a; y = b; ci = 1'b0; arith = 1'b1;
        case (op)
            4'h2, 4'hA: begin y = ~b; ci = 1'b1; end   // SUB, CMP
            4'h3:       begin x = b; y = ~a; ci = 1'b1; end  // RSB
            4'h4, 4'hB: ;                               // ADD, CMN
            4'h5:       ci = cin;                       // ADC
            4'h6:       begin y = ~b; ci = cin; end     // SBC
            4'h7:       begin x = b; y = ~a; ci = cin; end   // RSC
            default:    arith = 1'b0;
        endcase
        sum = {1'b0, x} + {1'b0, y} + {32'd0, ci};

        case (op)
            4'h0, 4'h8: lres = a & b;                   // AND, TST
            4'h1, 4'h9: lres = a ^ b;                   // EOR, TEQ
            4'hC:       lres = a | b;                   // ORR
            4'hD:       lres = b;                       // MOV
            4'hE:       lres = a & ~b;                  // BIC
            default:    lres = ~b;                      // MVN
        endcase
        res = arith ? sum[31:0] : lres;

        c = arith ? sum[32] : shc;
        v = arith ? ((x[31] == y[31]) && (sum[31] != x[31])) : vin;
        z = arith ? (x ^ y) == {x[30:0] | y[30:0], ci} : lres == 32'd0;
        nzcv = {res[31], z, c, v};
    end
endmodule
