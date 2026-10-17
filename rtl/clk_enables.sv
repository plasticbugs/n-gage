//------------------------------------------------------------------------------
// Clock enables from the 96 MHz system clock (docs/core-design.md section 1).
//
// Every clock on the board's 24 MHz side is an exact divider of 96 MHz, so
// these are plain counters with no fractional accumulator anywhere:
//
//   cen_phi1 / cen_phi2   fx68k's two phases, alternating, 12 MHz apiece
//   cen_z80               6 MHz
//   cen_ym                3 MHz
//   cen_pix               the video dot clock, 96 / 14 = 6.857 MHz
//
// The dot clock is the one thing that is not the board's: see the table in
// docs/core-design.md for why, and what the raster totals do about it.
//------------------------------------------------------------------------------
`default_nettype none

module clk_enables (
    input  logic clk,
    input  logic rst,
    // One pulse just after each edge of the platform's video clock, which
    // restarts the dot divider.  Without it the dot enable would sit at
    // whatever phase the reset left it in, and the pixel handed to the video
    // clock could be sampled while it changes (METHODOLOGY section 5.4).
    input  logic pix_sync,
    input  logic pause,     // hold both CPUs and the sound chip; see below
    output logic cen_phi1,
    output logic cen_phi2,
    output logic cen_z80,
    output logic cen_ym,
    output logic cen_pix
);
    logic [4:0] div;        // 0..31: the 68000, Z80 and YM2203 all divide this
    logic [3:0] dpix;       // 0..13

    always_ff @(posedge clk) begin
        if (rst) begin
            div  <= 5'd0;
            dpix <= 4'd0;
        end else begin
            if (!pause) div <= div + 5'd1;
            if (pix_sync)         dpix <= 4'd0;
            else if (dpix == 4'd13) dpix <= 4'd0;
            else                  dpix <= dpix + 4'd1;
        end
    end

    // 96 / 8 = 12 MHz, the two phases half a CPU clock apart
    // Pausing freezes the divider and masks the enables with the same signal,
    // so every count still produces exactly one pulse: nothing is skipped and
    // nothing fires twice, and fx68k's two phases come back in the order they
    // stopped.  The dot divider is separate and keeps running, which is what
    // leaves the picture on the screen behind the Pocket's menu.  (Cadash's
    // fix, for Cadash's bug: the menu-open signal used to be ORed into reset,
    // so opening the menu rebooted the game.)
    wire run = !pause;
    assign cen_phi1 = run && (div[2:0] == 3'd0);
    assign cen_phi2 = run && (div[2:0] == 3'd4);
    assign cen_z80  = run && (div[3:0] == 4'd2);    // 96 / 16 = 6 MHz
    assign cen_ym   = run && (div      == 5'd6);    // 96 / 32 = 3 MHz
    assign cen_pix  = (dpix     == 4'd0);       // 96 / 14 = 6.857 MHz
endmodule

`default_nettype wire
