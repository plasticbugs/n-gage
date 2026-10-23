// NGVM's CPU clock, on a PLL of its own.  The CPU side is asynchronous to
// the rest of the core by design (rtl/ngvm_xbus.sv, rtl/ngage_core.sv), so
// its frequency need not divide core_pll's VCO: it is the one number FREQ,
// which core_top.sv sets with the CPU_HZ it tells the core.  The PLL runs in
// fractional mode and picks its own VCO.
`timescale 1ns/10ps
module cpu_pll #(
    parameter FREQ = "80.000000 MHz"
) (
    input  wire refclk,     // 74.25 MHz
    input  wire rst,
    output wire outclk_0,
    output wire locked
);
    altera_pll #(
        .fractional_vco_multiplier("true"),
        .reference_clock_frequency("74.25 MHz"),
        .operation_mode("direct"),
        .number_of_clocks(1),
        .output_clock_frequency0(FREQ),
        .phase_shift0("0 ps"),
        .duty_cycle0(50),
        .pll_type("General"),
        .pll_subtype("General")
    ) altera_pll_i (
        .rst      (rst),
        .outclk   (outclk_0),
        .locked   (locked),
        .fboutclk (),
        .fbclk    (1'b0),
        .refclk   (refclk)
    );
endmodule
