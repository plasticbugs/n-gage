//------------------------------------------------------------------------------
// Diagnostic overlay (METHODOLOGY section 4): when enabled, the bottom 16
// visible lines show four rows of 32 squares, 4 px tall, SQW px wide -- 10
// for this board's 320-pixel line, so the 32 fit it exactly. Bit set =
// green, clear = dark grey, so a hang can be read off the panel without a
// debugger. The rows' meaning is the platform's
// (target/pocket/core_top.sv).
//
// The panel is read by eye, off a picture the scaler has turned a quarter
// turn, so row 0 opens with a fixed 1010 1010: if that is not what the first
// eight squares show, the reading is misaligned and nothing after it can be
// trusted. That is worth eight squares.
//
// Carried over from the Gaiapolis core, with the square width made a
// parameter.
//------------------------------------------------------------------------------
`default_nettype none

module dbg_overlay #(
    parameter int SQW = 10              // pixels per square, the line's width / 32
) (
    input  logic        clk,
    input  logic        cen_pix,
    input  logic        enable,
    input  logic        de, vsync,
    input  logic [7:0]  r_in, g_in, b_in,
    input  logic [127:0] status,       // rows 0..3, 32 bits each, bit 31 of each leftmost
    output logic [7:0]  r_out, g_out, b_out
);
    logic [3:0] sq;                   // pixel within the square
    logic [5:0] col;                  // square within the line
    logic [8:0] y;
    logic       de_d, vs_d;
    logic [8:0] height;               // visible lines counted in the previous frame

    always_ff @(posedge clk) begin
        if (cen_pix) begin
            de_d <= de; vs_d <= vsync;
            if (vsync && !vs_d) begin height <= y; y <= 9'd0; end
            else if (de && !de_d) begin sq <= 4'd0; col <= 6'd0; end
            else if (de) begin
                if (sq == 4'(SQW - 1)) begin sq <= 4'd0; col <= col + 6'd1; end else sq <= sq + 4'd1;
            end
            if (!de && de_d) y <= y + 9'd1;            // end of a visible line
        end
    end

    wire [8:0]  y_from_bottom = height - y;             // 1 = last visible line
    wire        in_band = enable && de && (y_from_bottom <= 9'd16) && (y_from_bottom >= 9'd1);
    wire [1:0]  row  = (y_from_bottom > 9'd12) ? 2'd0 : (y_from_bottom > 9'd8) ? 2'd1
                     : (y_from_bottom > 9'd4)  ? 2'd2 : 2'd3;
    wire [31:0] word = (row == 2'd0) ? status[127:96] : (row == 2'd1) ? status[95:64]
                     : (row == 2'd2) ? status[63:32]  : status[31:0];
    wire        bitv = word[5'd31 - col[4:0]];
    wire        gap  = (sq == 4'(SQW - 1)) || (y_from_bottom == 9'd16) || (y_from_bottom == 9'd12)
                    || (y_from_bottom == 9'd8) || (y_from_bottom == 9'd4);

    always_comb begin
        if (in_band && col < 6'd32) begin
            if (gap)      {r_out, g_out, b_out} = 24'h000000;
            else if (bitv){r_out, g_out, b_out} = 24'h20e020;
            else          {r_out, g_out, b_out} = 24'h303030;
        end else begin
            {r_out, g_out, b_out} = {r_in, g_in, b_in};
        end
    end
endmodule
