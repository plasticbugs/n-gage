//------------------------------------------------------------------------------
// The Analogizer (RndMnkIII's cartridge-slot adapter): analog video out of the
// VGA connector and SNAC controllers in, through the Pocket's cartridge port.
// The adapter's own module is vendored verbatim in target/pocket/analogizer/
// (modules/VENDOR.md); this wrapper is what a core needs around it, and is the
// same in every core built from this template.  docs/analogizer.md is the
// long form.
//
//   * Settings come from the core's own menu: interact.json entries that
//     write fields of one word at bridge 0xF7000000 (RndMnkIII's "Pocket
//     Menu" kind; the Pocket keeps them per core).  The layout is the one
//     the adapter module decodes, bit 5 the master enable.  With it off --
//     the default -- the cartridge port stays in its idle state and the core
//     is exactly what it was without an Analogizer.  The word is read back
//     from a register here, combinationally: the Pocket's bridge samples read
//     data four clocks after the address and before it pulses bridge_rd, and
//     the adapter module only updates its own read-back on that pulse.
//   * Two more menu entries, signed sliders at 0xF7000004 (horizontal, +
//     is right) and 0xF7000008 (vertical, + is down), move the picture on
//     the CRT, in dots and lines, by moving the syncs.  The core's own
//     range for them is set in interact.json, from its blanking.
//   * A third, at 0xF700000C (percent, + wider), scales the width of the
//     15 kHz picture about its centre: each line is played back one line
//     later from a line buffer, a little faster or slower.  For a core whose
//     CRT stands on its side (a vertical game) that is the game's height.
//   * The picture is handed over from the core's clock to `clk`, the
//     Analogizer's, one pixel per `src_pix_ce`.  `clk` also clocks the DAC
//     through the cartridge port, so keep it at 48 MHz or so (the rate the
//     shipped Analogizer cores use) and at least four times the dot rate:
//     the scandoubler halves the pixel period.
//   * SNAC pads come out as replacement controller words in the Pocket's own
//     format (cont*_key: 0 up 1 down 2 left 3 right 4 A 5 B 6 X 7 Y 8 L1 9 R1
//     10 L2 11 R2 12 L3 13 R3 14 select 15 start -- SNAC's order is the same),
//     so the core's input logic does not change: feed key1..key4 to it where
//     it took cont1_key..cont4_key.
//------------------------------------------------------------------------------
`default_nettype none

module pocket_analogizer #(
    parameter int CLK_HZ   = 48_000_000, // frequency of `clk`
    parameter int LINE_LEN = 512,        // dots per whole line, blanking included
    parameter int PIX_LAG  = 2,          // source clocks from src_pix_ce to a settled pixel
    parameter bit SAME_CLK = 1'b0,       // clk_src IS clk: no hand-over (below)
    // leave out the adapter module's Y/C encoder, or its scandoubler (with
    // HQ2x and the VGA scanlines), for a core with no room: their modes then
    // show RGBS.  A local change to the vendored module (modules/VENDOR.md);
    // 1, the default, is the module as RndMnkIII wrote it.
    parameter int USE_YC   = 1,
    parameter int USE_SD   = 1
) (
    input  wire         clk_74a,
    input  wire         clk,             // the Analogizer's clock, and the DAC's
    input  wire         rst,             // active high, any domain: holds the port idle

    // the picture, in the core's clock domain, one pixel per src_pix_ce
    input  wire         clk_src,
    input  wire         src_pix_ce,
    input  wire  [23:0] src_rgb,
    input  wire         src_hs,          // syncs and blanks active high
    input  wire         src_vs,
    input  wire         src_hb,
    input  wire         src_vb,

    // bridge (clk_74a): the menu writes the settings word to 0xF7000000
    input  wire  [31:0] bridge_addr,
    input  wire         bridge_rd,
    output wire  [31:0] bridge_rd_data,
    input  wire         bridge_wr,
    input  wire  [31:0] bridge_wr_data,

    // controllers (clk_74a): the Pocket's words in, the words to use out
    input  wire  [31:0] cont1_key,
    input  wire  [31:0] cont2_key,
    input  wire  [31:0] cont3_key,
    input  wire  [31:0] cont4_key,
    output logic [31:0] key1,
    output logic [31:0] key2,
    output logic [31:0] key3,
    output logic [31:0] key4,

    // settings (clk_74a)
    output wire         ena,             // the file's master enable
    output wire         pocket_off,      // "blank the Pocket screen", and enabled

    // a PS/2 keyboard on the SNAC port (clk), for the cores that want one
    output wire         ps2_code_new,
    output wire   [7:0] ps2_code,

    // the cartridge port, straight to core_top's pins
    inout  wire   [7:0] cart_tran_bank2,
    output wire         cart_tran_bank2_dir,
    inout  wire   [7:0] cart_tran_bank3,
    output wire         cart_tran_bank3_dir,
    inout  wire   [7:0] cart_tran_bank1,
    output wire         cart_tran_bank1_dir,
    inout  wire   [7:4] cart_tran_bank0,
    output wire         cart_tran_bank0_dir,
    inout  wire         cart_tran_pin30,
    output wire         cart_tran_pin30_dir,
    output wire         cart_pin30_pwroff_reset,
    inout  wire         cart_tran_pin31,
    output wire         cart_tran_pin31_dir
);
    // ------------------------------------------------------------------ reset
    logic [2:0] rst_s;
    initial rst_s = 3'b111;          // the port starts idle
    always @(posedge clk) rst_s <= {rst_s[1:0], rst};
    wire a_rst = rst_s[2];

    // ------------------------------------------------- the pixel hand-over
    // A pixel is taken PIX_LAG source clocks after its enable, when every
    // stage behind src_rgb has settled, and handed over with a toggle.  The
    // Analogizer side takes it two or three of its clocks later, well inside
    // the pixel (CLK_HZ >= 4x the dot rate), and makes its own enable from
    // the toggle, so the two arrive together.
    //
    // SAME_CLK is for a core whose dots come faster than CLK_HZ / 4 (a 20 MHz
    // dot, say; or a 15 kHz converter's output, ana_15k.sv, run on the
    // Analogizer's own clock): the toggle could not keep up, so the core
    // passes one clock as both `clk` and `clk_src` and the pixel is taken
    // directly, PIX_LAG clocks after its enable (it must still be inside the
    // dot).  From Xenophobe's core.
    logic [PIX_LAG-1:0] ce_sh;
    logic        a_ce;
    logic [27:0] a_pix;
    always_ff @(posedge clk_src) ce_sh <= PIX_LAG'({ce_sh, src_pix_ce});
    generate if (SAME_CLK) begin : g_same
        always_ff @(posedge clk) begin
            a_ce <= ce_sh[PIX_LAG-1];
            if (ce_sh[PIX_LAG-1]) a_pix <= {src_rgb, src_hs, src_vs, src_hb, src_vb};
        end
    end else begin : g_handover
        logic        h_tog;
        logic [27:0] h_pix;
        always_ff @(posedge clk_src)
            if (ce_sh[PIX_LAG-1]) begin
                h_pix <= {src_rgb, src_hs, src_vs, src_hb, src_vb};
                h_tog <= ~h_tog;
            end
        logic [2:0]  a_tog;
        always_ff @(posedge clk) begin
            a_tog <= {a_tog[1:0], h_tog};
            a_ce  <= a_tog[2] ^ a_tog[1];
            if (a_tog[2] ^ a_tog[1]) a_pix <= h_pix;
        end
    end endgenerate
    wire       a_hs = a_pix[3], a_vs = a_pix[2];

    // --------------------------------------------------- the settings words
    // as the menu last wrote them, for the firmware to read back (header):
    // 0xF7000000 the adapter's word, 0xF7000004 and 0xF7000008 the picture
    // position, 0xF700000C its width (below).  The adapter module keeps its
    // own copy of the last three in a table it never reads.
    logic [31:0] menu_word, pos_h, pos_v, size_h;
    initial begin menu_word = 32'h0; pos_h = 32'h0; pos_v = 32'h0; size_h = 32'h0; end
    always @(posedge clk_74a)
        if (bridge_wr && bridge_addr[31:24] == 8'hF7)
            case (bridge_addr[3:0])
                4'h0: menu_word <= bridge_wr_data;
                4'h4: pos_h     <= bridge_wr_data;
                4'h8: pos_v     <= bridge_wr_data;
                4'hC: size_h    <= bridge_wr_data;
                default: ;
            endcase
    assign bridge_rd_data = (bridge_addr[3:0] == 4'h0) ? menu_word :
                            (bridge_addr[3:0] == 4'h4) ? pos_h :
                            (bridge_addr[3:0] == 4'h8) ? pos_v :
                            (bridge_addr[3:0] == 4'hC) ? size_h : 32'h0;

    // the width slider and the video mode, which the position stage needs too
    wire [3:0] a_video_type;
    logic [7:0] size_m, size_q;
    always_ff @(posedge clk) begin size_m <= size_h[7:0]; size_q <= size_m; end
    wire signed [7:0] sz = size_q;
    wire        sz_on = (sz != 8'sd0) && (a_video_type < 4'h5);  // 15 kHz modes only

    // ------------------------------------------------- picture position
    // The menu's two sliders (header) move the picture on the CRT by moving
    // the syncs, never the picture: hsync n dots earlier puts the picture n
    // dots right, vsync n lines earlier puts it n lines down.  Earlier is the
    // same as a line (or a frame) less n later, and later is what can be
    // built: each sync is re-made from the source's own rising edge after a
    // delay counted in dots, as wide as the source's.  The vsync's delay is
    // whole lines from the vsync itself, so its edges keep their place in
    // the line.  Pixels and blanking pass untouched, one clock later with
    // the syncs; at 0 the source's sync passes straight through.  The range
    // is the menu's: interact.json keeps both syncs inside the blanking.
    // A re-made sync starts only after it has been off at least as long as
    // it is on: the adapter's sync_fix decides polarity afresh every period
    // by whether it was more high than low, and a jump in the offset (+2 to
    // -2 lines in one slider step) would otherwise put two pulses a line
    // apart and turn csync inside out for a frame.  Such a jump skips one
    // pulse instead.
    logic [7:0] pos_h_m, pos_h_q, pos_v_m, pos_v_q;     // from clk_74a; static
    always_ff @(posedge clk) begin
        pos_h_m <= pos_h[7:0]; pos_h_q <= pos_h_m;
        pos_v_m <= pos_v[7:0]; pos_v_q <= pos_v_m;
    end
    wire signed [7:0] dh = pos_h_q, dv = pos_v_q;

    logic        p_hs, p_vs;                // the previous dot's
    logic [11:0] hc, line_len, hs_len;      // dots from hsync's rise
    logic [11:0] vd;                        // dots, lines and dots
    logic [10:0] vl, frame_lines;           //   from vsync's rise
    logic [19:0] fc, vs_len;
    logic [11:0] o_hcnt, o_hgap;            // dots on, and dots off
    logic [19:0] o_vcnt, o_vgap;
    logic        o_hs, o_vs, b_ce;
    logic [27:0] b_pix;
    initial begin
        {p_hs, p_vs, o_hs, o_vs, b_ce} = '0;
        {hc, line_len, hs_len, vd, vl, frame_lines, fc, vs_len, o_hcnt, o_vcnt} = '0;
        {o_hgap, o_vgap} = '0;
    end

    wire        h_rise = a_hs && !p_hs, v_rise = a_vs && !p_vs;
    wire [11:0] hc_now = h_rise ? 12'd0 : hc + 12'd1;
    wire        vd_wrap = (vd == line_len - 12'd1);
    wire [11:0] vd_now = (v_rise || vd_wrap) ? 12'd0 : vd + 12'd1;
    wire [10:0] vl_now = v_rise ? 11'd0 : vl + 11'(vd_wrap);
    wire [19:0] fc_now = v_rise ? 20'd0 : fc + 20'd1;
    wire [11:0] h_at = (dh > 0) ? line_len - 12'(dh) : 12'd0 - 12'(dh);
    wire [10:0] v_pos = (dv > 0) ? frame_lines - 11'(dv) : 11'd0 - 11'(dv);
    // with the width stage on, the picture comes a line late: so does vsync
    wire [10:0] v_at = !sz_on ? v_pos : (v_pos + 11'd1 == frame_lines) ? 11'd0 : v_pos + 11'd1;

    always @(posedge clk) begin     // not always_ff, which may not share the initial block
        b_ce  <= a_ce;
        b_pix <= a_pix;
        if (a_ce) begin
            p_hs <= a_hs;
            p_vs <= a_vs;
            hc <= hc_now;
            vd <= vd_now;
            vl <= vl_now;
            fc <= fc_now;
            if (h_rise) line_len <= hc + 12'd1;
            if (p_hs && !a_hs) hs_len <= hc_now;
            if (v_rise) frame_lines <= vl + 11'd1;
            if (p_vs && !a_vs) vs_len <= fc_now;

            o_hgap <= o_hs ? 12'd0 : o_hgap + 12'(o_hgap != '1);
            o_vgap <= o_vs ? 20'd0 : o_vgap + 20'(o_vgap != '1);
            if (hc_now == h_at && o_hgap > hs_len) begin o_hs <= 1'b1; o_hcnt <= hs_len - 12'd1; end
            else if (o_hcnt != 12'd0) o_hcnt <= o_hcnt - 12'd1;
            else o_hs <= 1'b0;
            if (vl_now == v_at && vd_now == 12'd0 && o_vgap > vs_len) begin
                o_vs <= 1'b1; o_vcnt <= vs_len - 20'd1;
            end
            else if (o_vcnt != 20'd0) o_vcnt <= o_vcnt - 20'd1;
            else o_vs <= 1'b0;
            // At 0 each sync is the source's, under the same off-time rule:
            // a large slider step to 0 would otherwise put the source's
            // vsync a line after the last re-made one (found on Time Pilot,
            // whose vsync is 3 lines and whose large step is 4)
            if (dh == 8'sd0) begin
                if (h_rise) o_hs <= o_hs || (o_hgap > hs_len);
                else if (!a_hs) o_hs <= 1'b0;
            end
            if (dv == 8'sd0 && !sz_on) begin
                if (v_rise) o_vs <= o_vs || (o_vgap > vs_len);
                else if (!a_vs) o_vs <= 1'b0;
            end
        end
    end
    wire [7:0] b_r = b_pix[27:20], b_g = b_pix[19:12], b_b = b_pix[11:4];
    wire       b_hb = b_pix[1], b_vb = b_pix[0];

    // ------------------------------------------------- picture width
    // Each line's dots go into a two-line buffer as they come, six bits a
    // channel (the DAC's), and the line before is read back during this
    // one, A * (100 + sz) / 100 clocks long where it was A, centred where it
    // was: nearest dot, stepping step = dots / clocks (20 fractional bits,
    // from a divider that runs once a line) every clock.  The measures are
    // the previous line's, so a line's geometry is never used while it is
    // being taken.  Vblank comes a line late with the picture, and vsync
    // too (position stage); hsync, the same every line, does not move.
    // Off, or in a scandoubler mode, everything passes through as it was,
    // one clock later.  The range is the menu's: interact.json keeps the
    // picture clear of hsync and of the Y/C colour burst after it.
    localparam int XW = $clog2(LINE_LEN);
    logic [17:0] lbuf [0:(2 << XW) - 1];
    logic [17:0] l_q;
    logic        s_hs_p, s_hb_p, wsel, vb_w, vb_r;
    logic [13:0] tc, act_s, act_e;          // clocks from the source hsync's rise
    logic [XW-1:0] wx, wdots;               // dots written; the last line's count
    initial begin
        {s_hs_p, s_hb_p, wsel, vb_w} = '0; vb_r = 1'b1;
        {tc, act_s, act_e} = '0; {wx, wdots} = '0;
    end
    wire s_hs = b_pix[3], s_hb = b_pix[1], s_vb = b_pix[0];
    wire s_rise = s_hs && !s_hs_p;
    wire l_we = b_ce && !s_hb;
    always @(posedge clk) begin     // not always_ff, which may not share the initial block
        s_hs_p <= s_hs;
        s_hb_p <= s_hb;
        tc <= s_rise ? 14'd0 : tc + 14'd1;
        if (s_rise) begin wsel <= ~wsel; vb_r <= vb_w; end
        if (!s_hb && s_hb_p) begin act_s <= tc; vb_w <= s_vb; end
        if (s_hb && !s_hb_p) begin act_e <= tc; wdots <= wx; wx <= '0; end
        else if (l_we) wx <= wx + 1'd1;
    end

    // the output's length and start, from the last line
    wire [13:0] act_a = act_e - act_s;
    wire signed [8:0] sz_pct = 9'sd100 + 9'(sz);       // 100 + n, the new width in percent
    logic [34:0] w_prod;
    logic [14:0] w_out;                     // the scaled length, in clocks
    logic signed [16:0] w_start;
    always_ff @(posedge clk) begin
        w_prod  <= 35'(act_a) * 35'(sz_pct) * 35'd10486;          // / 100 = * 10486 / 2^20
        w_out   <= 15'(w_prod >> 20);
        w_start <= $signed({3'b0, act_s}) + (($signed({3'b0, act_a}) - $signed({2'b0, w_out})) >>> 1);
    end
    // step = (wdots << 20) / w_out: restoring, 32 clocks, restarted every line
    logic [31:0] dv_n, dv_qt, dv_r, step_u;
    logic [5:0]  dv_i;
    logic signed [16:0] start_u;
    logic [XW-1:0] dots_u;
    initial begin {dv_n, dv_qt, dv_r, step_u} = '0; dv_i = '0; start_u = '0; dots_u = '0; end
    wire [32:0] dv_t = {dv_r, dv_n[31]};
    always @(posedge clk) begin     // not always_ff, which may not share the initial block
        if (s_rise) begin
            step_u  <= dv_qt;               // the last line's quotient
            start_u <= w_start;
            dots_u  <= wdots;
            dv_n    <= 32'(wdots) << 20;
            dv_r    <= '0;
            dv_i    <= 6'd32;
        end else if (dv_i != 6'd0) begin
            dv_n <= dv_n << 1;
            dv_i <= dv_i - 6'd1;
            if (dv_t >= 33'(w_out)) begin dv_r <= 32'(dv_t - 33'(w_out)); dv_qt <= {dv_qt[30:0], 1'b1}; end
            else                    begin dv_r <= dv_t[31:0];             dv_qt <= {dv_qt[30:0], 1'b0}; end
        end
    end

    // read back: from start_u, a dot index that advances step_u a clock, to
    // the line's last dot -- past the source's next hsync if the line is
    // stretched that far (H Position may have moved the output's later), so
    // the buffer and vblank are those latched at the start
    logic [20+XW:0] acc;
    logic        rd_on, c_on, rsel, vb_s;
    initial begin acc = '0; {rd_on, c_on, rsel} = '0; vb_s = 1'b1; end
    wire [XW:0] rx = acc[20+XW:20];
    wire        rd_act = rd_on && (rx < {1'b0, dots_u});

    // Never into a sync: where the picture would reach hsync, or the colour
    // burst after it (H Position and H Size together can ask for that), it
    // is cropped instead.  Hsync's place in the line is the line before's,
    // like everything else here; KEEP_CB is the burst's end (CB_NTSC, the
    // later of the two) with a few clocks to spare either side.
    localparam int KEEP_CB = int'((64'(CLK_HZ) * 64'd11176 + 64'd1575000000) / 64'd3150000000) + 4;
    logic        ko_hs_p, ko_in;
    logic [13:0] ko_r, ko_f, line_c;        // hsync's rise and fall, and the line, in clocks
    initial begin {ko_hs_p, ko_in} = '0; {ko_r, ko_f, line_c} = '0; end
    wire [13:0] ko_len = ((ko_f >= ko_r) ? ko_f - ko_r : ko_f + line_c - ko_r) + 14'(8 + KEEP_CB);
    wire [14:0] ko_x0  = {1'b0, tc} + {1'b0, line_c} - {1'b0, ko_r} + 15'd4;
    wire [14:0] ko_x1  = (ko_x0 >= {1'b0, line_c}) ? ko_x0 - {1'b0, line_c} : ko_x0;
    wire [14:0] ko_x   = (ko_x1 >= {1'b0, line_c}) ? ko_x1 - {1'b0, line_c} : ko_x1;
    always @(posedge clk) begin     // not always_ff, which may not share the initial block
        ko_hs_p <= o_hs;
        if (s_rise) line_c <= tc + 14'd1;
        if (o_hs && !ko_hs_p) ko_r <= tc;
        if (!o_hs && ko_hs_p) ko_f <= tc;
        ko_in <= (ko_x < {1'b0, ko_len});
    end
    wire        rd_show = rd_act && !ko_in;
    always @(posedge clk) begin     // not always_ff, which may not share the initial block
        if ($signed({3'b0, tc}) == start_u) begin
            rd_on <= 1'b1; acc <= '0; rsel <= ~wsel; vb_s <= vb_r;
        end
        else if (rd_on && !rd_act) rd_on <= 1'b0;    // past the last dot
        else if (rd_on) acc <= acc + (21+XW)'(step_u);
        c_on <= rd_show;
    end
    always @(posedge clk) begin
        if (l_we) lbuf[{wsel, wx}] <= {b_r[7:2], b_g[7:2], b_b[7:2]};
        l_q <= lbuf[{rsel, rx[XW-1:0]}];
    end

    // to the adapter, one clock after the stages above either way
    logic        c_ce, c_hs, c_vs, c_hb, c_vb;
    logic [23:0] c_rgb;
    logic [XW:0] c_rx;
    always_ff @(posedge clk) begin
        c_ce  <= b_ce;
        c_hs  <= o_hs;
        c_vs  <= o_vs;
        c_hb  <= sz_on ? !rd_show : b_hb;
        c_vb  <= sz_on ? vb_s : b_vb;
        c_rgb <= {b_r, b_g, b_b};
        c_rx  <= rx;
    end
    // The adapter takes everything -- colour, blanks, syncs -- on the rising
    // edge of its pixel enable only.  Scaled, the enable is a one-clock pulse
    // whenever any of them changes, so each lands on its own clock; one that
    // would follow a pulse directly waits a clock, to leave the edge it needs.
    logic        p_chs, p_cvs, p_chb, p_cvb, w_ce, w_pend;
    logic [XW:0] p_crx;
    initial {p_chs, p_cvs, p_chb, p_cvb, w_ce, w_pend, p_crx} = '0;
    wire w_chg = (c_hs != p_chs) || (c_vs != p_cvs) || (c_hb != p_chb) ||
                 (c_vb != p_cvb) || (c_rx != p_crx);
    wire w_pulse = (w_chg || w_pend) && !w_ce;
    always @(posedge clk) begin     // not always_ff, which may not share the initial block
        {p_chs, p_cvs, p_chb, p_cvb, p_crx} <= {c_hs, c_vs, c_hb, c_vb, c_rx};
        w_ce   <= w_pulse;
        w_pend <= (w_chg || w_pend) && w_ce;
    end
    wire [7:0] c_r = !sz_on ? c_rgb[23:16] : c_on ? {l_q[17:12], l_q[17:16]} : 8'd0;
    wire [7:0] c_g = !sz_on ? c_rgb[15:8]  : c_on ? {l_q[11:6],  l_q[11:10]} : 8'd0;
    wire [7:0] c_b = !sz_on ? c_rgb[7:0]   : c_on ? {l_q[5:0],   l_q[5:4]}   : 8'd0;

    // --------------------------------------------------- Y/C subcarrier
    // The encoder's 40-bit phase step, f_sc * 2^40 / CLK_HZ, from
    // f_sc = num / den Hz in integers (the reals the other Analogizer cores
    // use lose the low bits past 32 in some tools), and its colour-burst
    // window in clocks: start at 3.7 subcarrier cycles, 9 cycles long for
    // NTSC and 10 for PAL, as Mike Simone's encoder expects.
    function automatic logic [39:0] sc_step(input logic [63:0] num, input logic [63:0] den);
        logic [63:0] d, q1, r1, q2;
        d  = den * 64'(CLK_HZ);
        q1 = (num << 24) / d;
        r1 = (num << 24) % d;
        q2 = (r1 << 16) / d;
        return 40'((q1 << 16) | q2);
    endfunction
    function automatic logic [63:0] rdiv(input logic [63:0] num, input logic [63:0] den);
        return (2 * num + den) / (2 * den);
    endfunction
    localparam logic [39:0] NTSC_STEP = sc_step(64'd315_000_000, 64'd88);  // 3.579545 MHz
    localparam logic [39:0] PAL_STEP  = sc_step(64'd17_734_475, 64'd4);    // 4.43361875 MHz
    localparam logic [63:0] CB_START  = rdiv(64'(CLK_HZ) * 64'd3256, 64'd3_150_000_000);
    localparam logic [63:0] CB_NTSC   = rdiv(64'(CLK_HZ) * 64'd792, 64'd315_000_000) + CB_START;
    localparam logic [63:0] CB_PAL    = rdiv(64'(CLK_HZ) * 64'd40, 64'd17_734_475) + CB_START;
    localparam logic [26:0] CB_RANGE  = {CB_START[6:0], CB_NTSC[9:0], CB_PAL[9:0]};

    wire        pal = (a_video_type == 4'h4);   // Y/C PAL


    // ------------------------------------------------------------ the adapter
    wire        a_ena, a_blank;
    wire  [4:0] a_cont_type;
    wire  [3:0] a_cont_assign;
    wire [15:0] p1_btn, p2_btn, p3_btn, p4_btn;
    wire [31:0] p1_joy, p2_joy;

    openFPGA_Pocket_Analogizer #(
        .MASTER_CLK_FREQ(CLK_HZ), .LINE_LENGTH(LINE_LEN), .ADDRESS_ANALOGIZER_CONFIG(8'hF7),
        .USE_YC(USE_YC), .USE_SD(USE_SD)
    ) u_analogizer (
        .clk_74a(clk_74a), .i_clk(clk), .i_rst_apf(a_rst), .i_rst_core(a_rst),
        .video_clk(clk),
        .R(c_r), .G(c_g), .B(c_b), .Hblank(c_hb), .Vblank(c_vb), .Hsync(c_hs), .Vsync(c_vs),
        // the menu writes numbers, not file bytes: no byte swap either way
        .bridge_endian_little(1'b1), .bridge_addr(bridge_addr),
        .bridge_rd(bridge_rd), .analogizer_bridge_rd_data(),
        .bridge_wr(bridge_wr), .bridge_wr_data(bridge_wr_data),
        .analogizer_ena_out(a_ena), .snac_game_cont_type_out(a_cont_type),
        .snac_cont_assignment_out(a_cont_assign), .analogizer_video_type_out(a_video_type),
        .SC_fx_out(), .pocket_blank_screen_out(a_blank), .analogizer_osd_out(),
        .CHROMA_PHASE_INC(pal ? PAL_STEP : NTSC_STEP), .COLORBURST_RANGE(CB_RANGE),
        .CHROMA_ADD(5'd0), .CHROMA_MUL(5'd0), .PALFLAG(pal),
        .ce_pix(sz_on ? w_pulse : c_ce), .scandoubler(1'b1),
        .p1_btn_state(p1_btn), .p1_joy_state(p1_joy),
        .p2_btn_state(p2_btn), .p2_joy_state(p2_joy),
        .p3_btn_state(p3_btn), .p4_btn_state(p4_btn),
        .i_VIB_SW1(2'b00), .i_VIB_DAT1(8'h00), .i_VIB_SW2(2'b00), .i_VIB_DAT2(8'h00),
        .busy(),
        .cart_tran_bank2(cart_tran_bank2), .cart_tran_bank2_dir(cart_tran_bank2_dir),
        .cart_tran_bank3(cart_tran_bank3), .cart_tran_bank3_dir(cart_tran_bank3_dir),
        .cart_tran_bank1(cart_tran_bank1), .cart_tran_bank1_dir(cart_tran_bank1_dir),
        .cart_tran_bank0(cart_tran_bank0), .cart_tran_bank0_dir(cart_tran_bank0_dir),
        .cart_tran_pin30(cart_tran_pin30), .cart_tran_pin30_dir(cart_tran_pin30_dir),
        .cart_pin30_pwroff_reset(cart_pin30_pwroff_reset),
        .cart_tran_pin31(cart_tran_pin31), .cart_tran_pin31_dir(cart_tran_pin31_dir),
        .DBG_TX(), .o_stb(),
        .o_ps2_code_new(ps2_code_new), .o_ps2_code(ps2_code),
        .o_mouse_valid(), .o_mouse_btn(), .o_mouse_dx(), .o_mouse_dy(), .o_mouse_dz(),
        .o_mouse_ready()
    );

    // ------------------------------------------------ SNAC into clk_74a
    // Each bit on its own: a pad's buttons are independent of each other, and
    // the settings change only when the file is loaded.
    localparam int SW = 4 * 16 + 2 * 16 + 1 + 1 + 5 + 4;
    wire  [SW-1:0] s_in = {p1_btn, p2_btn, p3_btn, p4_btn, p1_joy[15:0], p2_joy[15:0],
                           a_ena, a_blank, a_cont_type, a_cont_assign};
    logic [SW-1:0] s_m, s_q;
    always_ff @(posedge clk_74a) begin s_m <= s_in; s_q <= s_m; end
    wire [15:0] s1 = s_q[SW-1 -: 16], s2 = s_q[SW-17 -: 16];
    wire [15:0] s3 = s_q[SW-33 -: 16], s4 = s_q[SW-49 -: 16];
    wire [15:0] j1 = s_q[SW-65 -: 16], j2 = s_q[SW-81 -: 16];
    wire        s_ena = s_q[10], s_blank = s_q[9];
    wire  [4:0] s_type = s_q[8:4];
    wire  [3:0] s_assign = s_q[3:0];

    assign ena        = s_ena;
    assign pocket_off = s_ena && s_blank;

    // A PlayStation pad in analog mode (types 0x12, 0x13) steers with its
    // left stick: X in bits 7:0 and Y in 15:8, 0x00 up/left to 0xFF
    // down/right, centred near 0x7F; a quarter of the travel is a press.
    wire analog = (s_type == 5'h12) || (s_type == 5'h13);
    function automatic [15:0] pad(input [15:0] btn, input [15:0] joy, input use_stick);
        pad = use_stick ? {btn[15:4], joy[7:0] > 8'hC0, joy[7:0] < 8'h40,
                                      joy[15:8] > 8'hC0, joy[15:8] < 8'h40}
                        : btn;
    endfunction
    wire [15:0] n1 = pad(s1, j1, analog), n2 = pad(s2, j2, analog);

    // Assignments, as AnalogizerConfigurator numbers them.  When SNAC takes
    // player 1 the Pocket's own controls move to player 2, as in every other
    // Analogizer core.  Type 0x0F is a PS/2 keyboard with no pad: nothing to map.
    wire snac_on = s_ena && (s_type != 5'h00) && (s_type != 5'h0F);
    always_ff @(posedge clk_74a) begin
        key1 <= cont1_key; key2 <= cont2_key; key3 <= cont3_key; key4 <= cont4_key;
        if (snac_on) case (s_assign)
            4'd0: begin key1[15:0] <= n1;       key2 <= cont1_key;       end // SNAC P1 -> P1
            4'd1: begin key2[15:0] <= n1;                                end // SNAC P1 -> P2
            4'd2: begin key1[15:0] <= n1;       key2[15:0] <= n2;        end // P1,P2 -> P1,P2
            4'd3: begin key1[15:0] <= n2;       key2[15:0] <= n1;        end // P1,P2 -> P2,P1
            4'd4: begin key3[15:0] <= n1;       key4[15:0] <= n2;        end // P1,P2 -> P3,P4
            4'd5: begin key1[15:0] <= n1;       key2[15:0] <= n2;            // P1-P4 -> P1-P4
                        key3[15:0] <= s3;       key4[15:0] <= s4;        end
            default: ;
        endcase
    end
endmodule
