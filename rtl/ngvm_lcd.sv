//------------------------------------------------------------------------------
// The LCD: NGVM's 176 x 208 framebuffer, copied out of SDRAM when it is shown
// and scanned onto a raster from that copy (sw/include/ngvm_hw.h,
// docs/core-design.md 5).
//
// The raster is the template's, 452 x 253 dots at 96 / 14 MHz (59.96 Hz,
// 15.17 kHz lines, so the Analogizer's 15 kHz path takes it as it is), with
// the picture in its top-left corner: dots 0-175 of lines VIS_Y0 on.
// Vsync comes 16 lines after the picture and 29 before it, which puts the
// picture's middle 53% of the way down a CRT's scan, where an NES's is: with
// vsync 3 lines after it, as the template had it, a CRT lost the bottom
// lines to its overscan.
//
// A second raster, for the Analogizer only, shows the picture turned a
// quarter turn, for a CRT standing on its side (TATE): 208 dots a line, one
// for each of the picture's rows, and 176 lines, one for each column, from
// the same store.  382 x 262 dots at 96 / 16 MHz (15.71 kHz, 59.95 Hz), the
// dot near the square one on a 4:3 tube, the picture in the middle of the
// scan both ways.  `tate` 1 is for a CRT turned clockwise (its top to the
// right: the first line is the picture's right column, read top to bottom),
// 2 for one turned anticlockwise (the left column, bottom to top).  The two
// rasters take turns at the store's read port, a clock each: a dot is 14 or
// 16 clocks, and either one's pixel is read within 6 of its address.
//
// The phone's display keeps its own copy of the picture, which the firmware
// sends it when the window server updates the screen (sw/kernel/chan.c).
// So does this one.  `show` (IO_LCD_SHOW, once the D-cache has written its
// dirty lines back) starts a copy of the whole frame into a frame store of
// block RAM: 36,608 halfwords in one run from lcd_base, in bursts of at most
// 32, so the CPU's own bursts never wait long behind one (ngage_mem.sv).
// The raster reads only the store.  A copy takes about a millisecond; a
// frame scanned meanwhile shows the old picture above one line and the new
// below it, once.  A `show` during a copy starts another when it ends.
//
// Scanning the framebuffer itself, as the first flash did, showed the
// game's drawing half done, and through the write-back D-cache a moving
// picture's rows reached SDRAM out of order: on the Pocket, combing.
//
// The store is two RAMs, of 32K and 4K pixels of 12 bits, each one-
// dimensional and a power of two deep (METHODOLOGY 5.18), addressed together
// by y * 176 + x.
//
// `frame` pulses at the first line of vertical blanking: NGVM's vblank.
// lcd_base and lcd_on cross from the CPU's clock through two flops; lcd_on is
// taken once a frame, at that pulse, and lcd_base when a copy starts.
//------------------------------------------------------------------------------
`default_nettype none

module ngvm_lcd (
    input  logic        clk,            // 96 MHz
    input  logic        rst,
    input  logic        cen_pix,

    input  logic [31:0] lcd_base,       // the CPU's clock: synchronised here
    input  logic        lcd_on,
    input  logic        show,           // pulse: copy the framebuffer
    output logic        frame,          // pulse: vertical blanking begins

    // the copy (ngage_mem.sv)
    output logic        l_req,
    output logic [25:1] l_addr,
    output logic  [5:0] l_len,
    input  logic        l_wr,
    input  logic  [4:0] l_idx,
    input  logic [15:0] l_data,
    input  logic        l_done,

    output logic [23:0] rgb,
    output logic        hsync, vsync, hblank, vblank, de,

    // the turned raster (header), for the Analogizer: everything changes on
    // t_cen, and t_gx, t_gy are the picture's column and row for the dot
    // that the next t_cen shows, for the on-screen keypad (ngage_osk.sv)
    input  logic  [1:0] tate,           // 1 clockwise, 2 anticlockwise; static
    output logic        t_cen,
    output logic [23:0] t_rgb,
    output logic        t_hsync, t_vsync, t_hblank, t_vblank, t_de,
    output logic  [7:0] t_gx, t_gy,
    output logic        t_vis           // that dot is in the picture
);
    localparam int HTOTAL = 452, VTOTAL = 253;
    localparam int W = 176, H = 208;
    localparam int VIS_Y0 = 24, VIS_Y1 = VIS_Y0 + H - 1;
    localparam int HS0 = 300, HS1 = 332;            // hsync, dots
    localparam int VS0 = VIS_Y1 + 17, VS1 = VS0 + 3; // vsync, lines (header)
    // the turned raster: lines and dots from the picture's first
    localparam int T_DIV = 16, T_HTOTAL = 382, T_VTOTAL = 262;
    localparam int T_HS0 = 271, T_HS1 = 299;        // 4.7 us
    localparam int T_VS0 = 212, T_VS1 = 215;

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
    logic [31:0] base_s0, base_s1;
    logic  [1:0] on_s;
    logic        on;
    always_ff @(posedge clk) begin
        base_s0 <= lcd_base; base_s1 <= base_s0;
        on_s    <= {on_s[0], lcd_on};
        frame   <= line0 && vpos == 9'(VIS_Y1);
        if (frame) on <= on_s[1];
        if (rst) begin on <= 1'b0; frame <= 1'b0; end
    end

    // ------------------------------------------------------------ the copy
    logic [25:1] c_addr;                // the next burst's halfword address
    logic [15:0] c_pos, c_left;         // its first pixel's number; pixels still to fetch
    logic        c_go, c_gap, c_again, shown;
    wire  [5:0]  c_n = c_left > 16'd32 ? 6'd32 : 6'(c_left);

    assign l_addr = c_addr;
    assign l_len  = c_n;
    assign l_req  = c_go && !c_gap;

    always_ff @(posedge clk) begin
        c_gap <= 1'b0;
        if (l_done) begin
            c_addr <= c_addr + 25'(c_n);
            c_pos  <= c_pos + 16'(c_n);
            c_left <= c_left - 16'(c_n);
            c_gap  <= 1'b1;             // l_req falls for a clock between bursts
            if (c_left == 16'(c_n)) begin c_go <= 1'b0; shown <= 1'b1; end
        end
        if (show && c_go) c_again <= 1'b1;
        if ((show || c_again) && !c_go) begin
            c_addr  <= {1'b0, base_s1[24:1]};
            c_pos   <= 16'd0;
            c_left  <= 16'(W * H);
            c_go    <= 1'b1;
            c_again <= 1'b0;
        end
        if (rst) begin c_go <= 1'b0; c_gap <= 1'b0; c_again <= 1'b0; shown <= 1'b0; end
    end

    // ------------------------------------------------------------ the store
    logic [11:0] st_lo [0:32767];       // pixels 0-32767
    logic [11:0] st_hi [0:4095];        // pixels 32768-36607
    wire  [15:0] wa = c_pos + 16'(l_idx);
    always_ff @(posedge clk) begin
        if (l_wr && !wa[15]) st_lo[wa[14:0]] <= l_data[11:0];
        if (l_wr &&  wa[15]) st_hi[wa[11:0]] <= l_data[11:0];
    end

    // ------------------------------------------------------- the turned raster
    logic [3:0] t_div;
    logic [8:0] t_h, t_v;
    assign t_cen = t_div == 4'(T_DIV - 1);
    always_ff @(posedge clk) begin
        if (rst) begin t_div <= '0; t_h <= '0; t_v <= '0; end
        else begin
            t_div <= t_div + 4'd1;
            if (t_cen) begin
                if (t_h == 9'(T_HTOTAL - 1)) begin
                    t_h <= '0;
                    t_v <= (t_v == 9'(T_VTOTAL - 1)) ? 9'd0 : t_v + 9'd1;
                end else t_h <= t_h + 9'd1;
            end
        end
    end
    wire t_vis_x = t_h < 9'(H), t_vis_y = t_v < 9'(W);
    // the dot's place in the picture: a line is a column, a dot a row
    always_ff @(posedge clk) begin
        t_gx  <= tate[1] ? 8'(t_v) : 8'(9'(W - 1) - t_v);
        t_gy  <= tate[1] ? 8'(9'(H - 1) - t_h) : 8'(t_h);
        t_vis <= t_vis_x && t_vis_y;
    end

    // ------------------------------------------------------------ the picture
    // y and hpos hold for 14 clocks, t_gx and t_gy for 16: each pixel is read
    // long before the enable that shows it.  The read port is the upright
    // raster's on even clocks and the turned one's on odd.
    logic [15:0] row, ra, ta, rd_a;
    logic [11:0] q_lo, q_hi, px, t_px;
    logic        q_sel, ph, rd_t, q_t;
    always_ff @(posedge clk) begin
        row   <= 16'(y) * 16'(W);
        ra    <= row + 16'(hpos);
        ta    <= 16'(t_gy) * 16'(W) + 16'(t_gx);
        ph    <= ~ph;
        rd_a  <= ph ? ta : ra;
        rd_t  <= ph;
        q_lo  <= st_lo[rd_a[14:0]];
        q_hi  <= st_hi[rd_a[11:0]];
        q_sel <= rd_a[15];
        q_t   <= rd_t;
        if (q_t) t_px <= q_sel ? q_hi : q_lo;
        else     px   <= q_sel ? q_hi : q_lo;
    end

    always_ff @(posedge clk) begin
        if (t_cen) begin
            t_rgb    <= (t_vis && on && shown) ? {t_px[11:8], t_px[11:8], t_px[7:4], t_px[7:4], t_px[3:0], t_px[3:0]}
                                               : 24'h000000;
            t_de     <= t_vis;
            t_hblank <= !t_vis_x;
            t_hsync  <= t_h >= 9'(T_HS0) && t_h < 9'(T_HS1);
            t_vblank <= !t_vis_y;
            t_vsync  <= t_v >= 9'(T_VS0) && t_v < 9'(T_VS1);
        end
    end

    always_ff @(posedge clk) begin
        if (cen_pix) begin
            rgb    <= (vis_x && vis_y && on && shown) ? {px[11:8], px[11:8], px[7:4], px[7:4], px[3:0], px[3:0]}
                                                      : 24'h000000;
            de     <= vis_x && vis_y;
            hblank <= !vis_x;
            hsync  <= hpos >= 9'(HS0) && hpos < 9'(HS1);
            vblank <= !vis_y;
            vsync  <= vpos >= 9'(VS0) && vpos < 9'(VS1);
        end
    end

    wire _unused = &{1'b0, base_s1[31:25], base_s1[0], l_data[15:12], tate[0], 1'b0};
endmodule

`default_nettype wire
