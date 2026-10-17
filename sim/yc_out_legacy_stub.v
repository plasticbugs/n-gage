// Lint-only stand-in for yc_out_legacy.sv (RndMnkIII's vendored Y/C encoder,
// after Mike Simone's).  Its 256-entry sine table is a wire array declared
// with an initial value ('{...}), which Quartus and Verilator 5.050 take and
// CI's Verilator 5.020 cannot parse.  The lint is about the wrapper and how
// it drives the adapter module; the encoder itself is RndMnkIII's, verbatim,
// and is built by Quartus and by the Analogizer bench (sim/run_analogizer.sh),
// which use the real file.  Same ports; outputs tied off.
`default_nettype none
module yc_out_legacy (
    input  wire        clk,
    input  wire [39:0] PHASE_INC,
    input  wire        PAL_EN,
    input  wire [26:0] COLORBURST_RANGE,
    input  wire  [4:0] CHRADD,
    input  wire  [4:0] CHRMUL,
    input  wire        MULFLAG,
    input  wire        hsync,
    input  wire        vsync,
    input  wire        csync,
    input  wire [23:0] din,
    output wire [23:0] dout,
    output reg         hsync_o,
    output reg         vsync_o,
    output reg         csync_o
);
    assign dout = 24'h0;
    initial {hsync_o, vsync_o, csync_o} = 3'b111;
    wire unused = &{1'b0, clk, PHASE_INC, PAL_EN, COLORBURST_RANGE, CHRADD, CHRMUL,
                    MULFLAG, hsync, vsync, csync, din};
endmodule
`default_nettype wire
