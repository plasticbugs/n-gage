//------------------------------------------------------------------------------
// The LCD: NGVM's 176 x 208 framebuffer scanned out of SDRAM onto a raster
// (sw/include/ngvm_hw.h, docs/core-design.md 5).
//
// The raster is the template's, 452 x 253 dots at 96 / 14 MHz (59.96 Hz,
// 15.17 kHz lines, so the Analogizer's 15 kHz path takes it as it is), with
// the picture in its top-left corner: dots 0-175 of lines VIS_Y0 on.
//
// Each line is fetched during the line before it into one half of a line
// buffer while the other half is shown: 176 halfwords from
//   lcd_base (an address in NGVM's physical alias) + 352 * y
// in bursts of at most 32, so the CPU's own bursts never wait long behind
// one (ngage_mem.sv).  The fetch has a whole line, 6,328 clocks, for what
// takes about 450.  A pixel is 0x0RGB; each 4-bit channel becomes 8 by
// repeating it.
//
// `frame` pulses at the first line of vertical blanking: NGVM's vblank, which
// the D-cache answers by writing its dirty lines back so the next frame
// scanned is the one the CPU finished.  lcd_base and lcd_on cross from the
// CPU's clock through two flops and are taken once a frame, at that pulse.
//------------------------------------------------------------------------------
`default_nettype none

module ngvm_lcd (
    input  logic        clk,            // 96 MHz
    input  logic        rst,
    input  logic        cen_pix,

    input  logic [31:0] lcd_base,       // the CPU's clock: synchronised here
    input  logic        lcd_on,
    output logic        frame,          // pulse: vertical blanking begins

    // the line fetch (ngage_mem.sv)
    output logic        l_req,
    output logic [25:1] l_addr,
    output logic  [5:0] l_len,
    input  logic        l_wr,
    input  logic  [4:0] l_idx,
    input  logic [15:0] l_data,
    input  logic        l_done,

    output logic [23:0] rgb,
    output logic        hsync, vsync, hblank, vblank, de
);
    localparam int HTOTAL = 452, VTOTAL = 253;
    localparam int W = 176, H = 208;
    localparam int VIS_Y0 = 24, VIS_Y1 = VIS_Y0 + H - 1;
    localparam int HS0 = 300, HS1 = 332;            // hsync, dots
    localparam int VS0 = VIS_Y1 + 4, VS1 = VS0 + 3; // vsync, lines

    // ------------------------------------------------------------ raster
    logic [8:0] hpos, vpos;
    always_ff @(posedge clk) begin
        if (rst) begin hpos <= '0; vpos <= '0; end
        else if (cen_pix) begin
            if (hpos == 9'(HTOTAL - 1)) begin
                hpos <= '0;
                vpos <= (vpos == 9'(VTOTAL - 1)) ? 9'd0 : vpos + 9'd1;
            end else hpos <= hpos + 9'd1;
        end
    end
    wire       vis_x = hpos < 9'(W);
    wire       vis_y = vpos >= 9'(VIS_Y0) && vpos <= 9'(VIS_Y1);
    wire [8:0] y     = vpos - 9'(VIS_Y0);
    wire       line0 = cen_pix && hpos == 9'(HTOTAL - 1);  // the next line starts

    // ------------------------------------------------------- the registers
    logic [31:0] base_s0, base_s1, base;
    logic  [1:0] on_s;
    logic        on;
    always_ff @(posedge clk) begin
        base_s0 <= lcd_base; base_s1 <= base_s0;
        on_s    <= {on_s[0], lcd_on};
        frame   <= line0 && vpos == 9'(VIS_Y1);
        if (frame) begin base <= base_s1; on <= on_s[1]; end
        if (rst) begin on <= 1'b0; frame <= 1'b0; end
    end

    // ------------------------------------------------------------ the fetch
    // As each line starts, the 176 halfwords of the line after it, into the
    // half of the buffer the line now ending has finished with.  The address
    // comes from the line's number, so a fetch that overran (none should:
    // see above) costs that line and no other.
    logic [15:0] lbuf [0:511];
    logic [25:1] f_addr, l_off;         // halfword addresses: the next burst, the line's offset
    logic  [7:0] f_left, f_pos;
    logic        f_bank, f_go, f_gap;
    wire  [8:0]  ty   = vpos + 9'd2 - 9'(VIS_Y0);   // the line the fetch is for
    wire         tvis = vpos + 9'd2 >= 9'(VIS_Y0) && vpos + 9'd2 <= 9'(VIS_Y1);
    wire  [7:0]  f_n  = f_left > 8'd32 ? 8'd32 : f_left;

    assign l_addr = f_addr;
    assign l_len  = 6'(f_n);
    assign l_req  = f_go && !f_gap;

    always_ff @(posedge clk) begin
        l_off <= 25'(ty) * 25'(W);     // vpos holds for 14 clocks: always settled
        f_gap <= 1'b0;
        if (l_wr) lbuf[{f_bank, f_pos + {3'd0, l_idx}}] <= l_data;
        if (l_done) begin
            f_addr <= f_addr + 25'(f_n);
            f_pos  <= f_pos + f_n;
            f_left <= f_left - f_n;
            f_gap  <= 1'b1;             // l_req falls for a clock between bursts
            if (f_left == f_n) f_go <= 1'b0;
        end
        if (line0 && !f_go && on && tvis) begin
            f_addr <= {1'b0, base[24:1]} + l_off;
            f_left <= 8'(W); f_pos <= 8'd0; f_bank <= ty[0]; f_go <= 1'b1;
        end
        if (rst) begin f_go <= 1'b0; f_gap <= 1'b0; end
    end

    // ------------------------------------------------------------ the picture
    logic [15:0] px;
    always_ff @(posedge clk) px <= lbuf[{y[0], hpos[7:0]}];

    always_ff @(posedge clk) begin
        if (cen_pix) begin
            rgb    <= (vis_x && vis_y && on) ? {px[11:8], px[11:8], px[7:4], px[7:4], px[3:0], px[3:0]}
                                             : 24'h000000;
            de     <= vis_x && vis_y;
            hblank <= !vis_x;
            hsync  <= hpos >= 9'(HS0) && hpos < 9'(HS1);
            vblank <= !vis_y;
            vsync  <= vpos >= 9'(VS0) && vpos < 9'(VS1);
        end
    end

    wire _unused = &{1'b0, base[31:25], base[0], px[15:12], 1'b0};
endmodule

`default_nettype wire
