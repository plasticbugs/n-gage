// From the PC-88 core's bench (nec-pc88/sim/mf_datatable_model.v), unchanged below.
// Behavioural stand-in for platform/pocket/megafunctions/mf_datatable.v (an
// altsyncram Verilator cannot build): 256 words, two ports, address and
// output both registered as the megafunction is, so a read takes two clocks.
`default_nettype none

module mf_datatable (
    input  wire  [7:0] address_a,
    input  wire  [7:0] address_b,
    input  wire        clock_a,
    input  wire        clock_b,
    input  wire [31:0] data_a,
    input  wire [31:0] data_b,
    input  wire        wren_a,
    input  wire        wren_b,
    output reg  [31:0] q_a,
    output reg  [31:0] q_b
);
    reg [31:0] mem [0:255];
    reg  [7:0] ra, rb;
    integer i;
    initial for (i = 0; i < 256; i = i + 1) mem[i] = 32'd0;
    /* verilator lint_off MULTIDRIVEN */
    always @(posedge clock_a) begin
        ra <= address_a;
        if (wren_a) mem[address_a] <= data_a;
        q_a <= mem[ra];
    end
    always @(posedge clock_b) begin
        rb <= address_b;
        if (wren_b) mem[address_b] <= data_b;
        q_b <= mem[rb];
    end
    /* verilator lint_on MULTIDRIVEN */
endmodule
