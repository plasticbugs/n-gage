// Behavioural Pocket SRAM (128K x 16, 10 ns async): data one clock after the
// address settles (inverted before), writes take the bus while WE# is low.
`default_nettype none
module sram_model (
    input  logic        clk,
    input  logic [16:0] a,
    inout  wire  [15:0] dq,
    input  logic        oe_n, we_n, ub_n, lb_n
);
    logic [15:0] mem [131072] /*verilator public_flat_rw*/;
    logic [16:0] a_d;
    always_ff @(posedge clk) begin
        a_d <= a;
        if (!we_n) begin
            if (!ub_n) mem[a][15:8] <= dq[15:8];
            if (!lb_n) mem[a][7:0]  <= dq[7:0];
        end
    end
    wire drive = !oe_n && we_n;
    assign dq = drive ? ((a == a_d) ? mem[a] : ~mem[a]) : 16'bz;
endmodule
