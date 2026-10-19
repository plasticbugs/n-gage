//------------------------------------------------------------------------------
// The CPU's register file: 31 ARM registers and a temporary, as physical
// indices (arm_pkg.sv): 0-14 the user bank, 16-22 r8-r14 of FIQ, 23-30 r13
// and r14 of SVC, ABT, IRQ and UND, 31 the temporary.  15 is never written
// (R15 is the PC, held by the pipeline).
//
// Flops, not block RAM: five read ports and two write ports, read
// combinationally, written at W.  The read ports follow the instruction's
// register fields (Rn, Rm, Rs, Rd) and the LDM/STM register, so a read
// starts from D2's registers rather than from the decoder; the decoder only
// says which port each operand takes.  r31 is read on its own.  A read of a
// register being written in the same cycle returns the new value.
//------------------------------------------------------------------------------
`default_nettype none

module arm_regs (
    input  logic        clk,
    input  logic  [4:0] rn, rm, rs, rd, rl,
    output logic [31:0] qn, qm, qs, qd, ql, q31,
    input  logic        wa_en, input logic [4:0] wa, input logic [31:0] da,
    input  logic        wb_en, input logic [4:0] wb, input logic [31:0] db
);
    logic [31:0] r [0:31] /* verilator public */;

    always_ff @(posedge clk) begin
        if (wb_en) r[wb] <= db;
        if (wa_en) r[wa] <= da;     // A wins: a loaded base beats its write-back (LDM {Rn..}!)
    end

    function automatic logic [31:0] rd_(input logic [4:0] i);
        if (wa_en && wa == i) return da;
        if (wb_en && wb == i) return db;
        return r[i];
    endfunction

    always_comb begin
        qn  = rd_(rn);
        qm  = rd_(rm);
        qs  = rd_(rs);
        qd  = rd_(rd);
        ql  = rd_(rl);
        q31 = rd_(5'd31);
    end
endmodule
