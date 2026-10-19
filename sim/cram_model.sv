// Behavioural Pocket cellular RAM (AS1C8M16PL-70: 8M x 16 as two 4M halves
// on CE0#/CE1#) in its power-up mode -- asynchronous, address multiplexed
// onto DQ and latched while ADV# is low -- with the -70 part's access times
// checked against the controller's clock (96 MHz, 10.4 ns a cycle).
//
// The pins only move on the controller's clock edges, so time is counted
// in whole cycles of it:
//   a read drives the word only once ADV# fell 7 or more cycles ago (tAADV
//   70 ns) and OE# 2 or more (tOE 20 ns), and its inverse before, so a
//   sample taken too early reads wrong;
//   a write is taken as WE# rises, and is an error unless WE# was low 5
//   cycles (tWP 45 ns), CE# 7 (tCW 70 ns) and the data still 2 (tDW 20 ns).
// Anything wrong is counted in `errors` and printed.
`default_nettype none

module cram_model (
    input  logic        clk,
    input  logic [21:16] a,
    inout  wire  [15:0] dq,
    input  logic        adv_n, ce0_n, ce1_n, oe_n, we_n, ub_n, lb_n
);
    logic [15:0] mem [0:(1<<23)-1] /*verilator public_flat_rw*/;
    integer      errors /*verilator public_flat_rw*/;
    initial errors = 0;

    wire        ce_n = ce0_n && ce1_n;
    logic       half;
    logic [21:0] la;                    // the latched address
    logic  [3:0] n_ce, n_oe, n_we, n_dq;
    logic [15:0] dq_d;
    logic        we_d;

    wire  [22:0] wa = {half, la};
    wire         rd = !ce_n && !oe_n && we_n;
    wire         ok = n_ce >= 4'd7 && n_oe >= 4'd2;
    assign dq = rd ? (ok ? mem[wa] : ~mem[wa]) : 16'hZZZZ;

    always_ff @(posedge clk) begin
        n_ce <= ce_n ? 4'd0 : (n_ce == 4'd15 ? n_ce : n_ce + 4'd1);
        n_oe <= oe_n ? 4'd0 : (n_oe == 4'd15 ? n_oe : n_oe + 4'd1);
        n_we <= we_n ? 4'd0 : (n_we == 4'd15 ? n_we : n_we + 4'd1);
        dq_d <= dq;
        n_dq <= (dq !== dq_d) ? 4'd1 : (n_dq == 4'd15 ? n_dq : n_dq + 4'd1);
        we_d <= we_n;
        if (!ce_n && !adv_n) begin la <= {a, dq}; half <= ce0_n; end
        if (!ce0_n && !ce1_n) begin $display("CRAM-ERROR: both halves selected"); errors++; end
        if (!oe_n && !we_n && !ce_n) begin $display("CRAM-ERROR: OE# and WE# both low"); errors++; end
        // WE# rising: the cycle just gone was its last one low
        if (!we_n && !ce_n) begin
            if (!adv_n) begin $display("CRAM-ERROR: write while ADV# low"); errors++; end
        end
        if (we_n && !we_d && !ce_n) begin
            if (n_we < 4'd5 || n_ce < 4'd7 || n_dq < 4'd2) begin
                $display("CRAM-ERROR: write to %06x: WE# low %0d, CE# low %0d, data held %0d cycles",
                         wa, n_we, n_ce, n_dq);
                errors++;
            end
            if (!ub_n) mem[wa][15:8] <= dq_d[15:8];
            if (!lb_n) mem[wa][7:0]  <= dq_d[7:0];
        end
    end
endmodule
