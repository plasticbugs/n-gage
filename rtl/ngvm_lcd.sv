//------------------------------------------------------------------------------
// The LCD: NGVM's 176 x 208 framebuffer, copied out of SDRAM when it is shown
// and scanned onto a raster from that copy (sw/include/ngvm_hw.h,
// docs/core-design.md 5).
//
// The raster is the template's, 452 x 253 dots at 96 / 14 MHz (59.96 Hz,
// 15.17 kHz lines, so the Analogizer's 15 kHz path takes it as it is), with
// the picture in its top-left corner: dots 0-175 of lines VIS_Y0 on.
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

    // ------------------------------------------------------------ the picture
    // y and hpos hold for 14 clocks: the pixel is read long before the
    // cen_pix that shows it
    logic [15:0] row, ra;
    logic [11:0] q_lo, q_hi;
    logic        q_sel;
    always_ff @(posedge clk) begin
        row   <= 16'(y) * 16'(W);
        ra    <= row + 16'(hpos);
        q_lo  <= st_lo[ra[14:0]];
        q_hi  <= st_hi[ra[11:0]];
        q_sel <= ra[15];
    end
    wire [11:0] px = q_sel ? q_hi : q_lo;

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

    wire _unused = &{1'b0, base_s1[31:25], base_s1[0], l_data[15:12], 1'b0};
endmodule

`default_nettype wire
