// VHDL is not something the lint or the benches can read.  The Analogizer's SNAC module
// instantiates the VHDL PS/2 keyboard receiver (target/pocket/analogizer/ps2_keyboard.vhd);
// this stands in for it in the lint and the benches, and reports no keys.
// Quartus builds the real one.
module ps2_keyboard #(parameter clk_freq = 50_000_000, parameter debounce_counter_size = 8) (
    input  wire       clk,
    input  wire       ps2_clk,
    input  wire       ps2_data,
    output wire       ps2_code_new,
    output wire [7:0] ps2_code
);
    assign ps2_code_new = 1'b0;
    assign ps2_code     = 8'h00;
endmodule
