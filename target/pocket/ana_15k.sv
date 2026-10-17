//------------------------------------------------------------------------------
// A 15 kHz picture for the Analogizer from a board that is not 15 kHz: a
// medium-resolution (25 kHz) or VGA-rate (31 kHz) progressive frame shown as
// a progressive picture of half its lines, which a 15 kHz monitor or
// television takes.  Fed the board's raw 25/31 kHz picture, a 15 kHz CRT
// shows it as several overlapping copies, or two images side by side
// (docs/analogizer.md, "A board that is not 15 kHz").  The Pocket's own
// picture does not pass through here.
//
// From two cores that shipped with it (parameters for each in
// docs/analogizer.md): Atari System 2, 512 x 384 at 25 kHz -> 192p (the
// defaults below), and Xenophobe, 512 x 480 at 31 kHz -> 240p.
//
//   * Each output line shows one of the game's line pairs (source lines 2j
//     and 2j+1 on output line j), its SW dots at DOT clocks a dot, so the
//     picture keeps its shape when DOT is about the source's clocks a dot
//     times (source line rate / 15.7 kHz) / 2.  Blend (the default): each
//     dot is the average of the pair's two, per channel, on the full 8 bits
//     ((a + b) >> 1), kept to the 6 the DAC shows, so nothing one line thin
//     vanishes and nothing flickers.  Sharp: the pair's even line,
//     unblended.  A core usually offers both from its "Analogizer" menu list,
//     Sharp on a spare bit of the 0xF7000000 word (docs/analogizer.md).
//   * Frame-locked: the output frame restarts DELAY clocks after the
//     source's first visible line starts, every frame, and its LINES lines
//     add up to exactly the source's SRC_FRAME clocks, so it never drops,
//     repeats or tears a frame and vsync lands on the same output line every
//     frame.  Every dot is DOT clocks but each line's last (deep in the back
//     porch), which takes the line's spare clocks (PAD), and one more on LONG
//     of the LINES lines (a Bresenham spread): lines are LINE_CLK or
//     LINE_CLK + 1 clocks, never anything else -- an odd source line count
//     (525) is spread this way instead of interlaced.
//   * Pairs go into a ring of RING slots the output reads.  When a pair of
//     source lines takes longer than an output line (25 kHz: 80 us against
//     63.5), the output runs faster than the source and has to start late,
//     so that it finishes its last line after the source's last pair: the
//     ring then holds the ~SH/2 * (1 - 63.5/pair time) pairs it falls behind
//     (48 for System 2).  When the two are nearly equal (31 kHz: 2 x 31.75
//     us against 63.6), RING = 2 is enough.  DELAY sits between two limits:
//     late enough that the output never reads a dot before it is written,
//     early enough that the source never overwrites a slot before it is
//     read.  sim/run_ana15k.sh measures both margins for a set of parameters
//     and prints the window; set DELAY near its middle, and keep the bench's
//     run for your parameters next to the core.
//   * The even line of a pair waits in a one-line buffer while the odd one
//     arrives.
//   * Clock: any clock the source's dot enable is on (src_ce).  The core's
//     own clock is usual; the outputs then change on o_ce in that domain and
//     go to pocket_analogizer as its source (clk_src, src_pix_ce = o_ce).
//
// Constraints the parameters must meet (the bench checks the result):
// SH even; SRC_FRAME = the source's whole frame in `clk` clocks; DOTS * DOT
// <= SRC_FRAME / LINES; SW <= DOTS; SH / 2 <= VS0 < VS1 <= LINES;
// SW <= HS0 < HS1 <= DOTS.
//
// Every output changes at the end of the cycle its enable (o_ce) is high,
// as the core's own video does, so a consumer may sample one clock after.
//------------------------------------------------------------------------------
`default_nettype none

module ana_15k #(
    parameter int SW = 512,                  // source visible dots
    parameter int SH = 384,                  // source visible lines (even)
    parameter int SRC_FRAME = 1_597_440,     // source clocks a frame (640 * 6 * 416)
    parameter int DOT   = 10,                // clocks an output dot
    parameter int DOTS  = 609,               // output dots a line
    parameter int LINES = 262,               // output lines a frame
    parameter int HS0 = 524, HS1 = 569,      // output hsync [HS0, HS1): 4.7 us
    parameter int VS0 = 219, VS1 = 222,      // output vsync [VS0, VS1)
    parameter int RING  = 48,                // pairs the ring holds
    parameter int DELAY = 336_000            // source line 0 -> output line 0, clocks
) (
    input  wire         clk,
    input  wire         sharp,               // 1: the even line of each pair (any domain)

    // the core's picture, values changing on src_ce
    input  wire         src_ce,
    input  wire  [23:0] src_rgb,
    input  wire         src_hb,
    input  wire         src_vb,

    // the 15 kHz picture
    output logic        o_ce,
    output logic [23:0] o_rgb,
    output logic        o_hs,
    output logic        o_vs,
    output logic        o_hb,
    output logic        o_vb
);
    localparam int LINE_CLK = SRC_FRAME / LINES;            // a short line's clocks
    localparam int PAD  = LINE_CLK - DOTS * DOT;            // the last dot's extra clocks
    localparam int LONG = SRC_FRAME - LINES * LINE_CLK;     // lines one clock longer
    localparam int SLW  = (RING > 1) ? $clog2(RING) : 1;    // ring slot
    localparam int XW   = $clog2(SW);                       // source dot
    localparam int YW   = $clog2(SH);                       // source line
    localparam int DW   = $clog2(SRC_FRAME);                // DELAY count
    localparam int CW   = $clog2(DOT + PAD + 1);            // clock within an output dot
    localparam int OW   = $clog2(DOTS);                     // output dot
    localparam int LW   = $clog2(LINES);                    // output line
    localparam int LW1  = LW + 1;                           // Bresenham sum

    // initial values in initial blocks, and plain always: always_ff may not
    // share them (lint)
    logic [1:0] sharp_s;
    initial sharp_s = 2'b00;
    always @(posedge clk) sharp_s <= {sharp_s[0], sharp};

    // ------------------------------------------------------------ the source
    logic           p_hb, p_vb;
    logic [XW-1:0]  sx;
    logic [YW-1:0]  sy;
    logic [SLW-1:0] w_slot;                               // this pair's ring slot
    initial begin p_hb = 1'b1; p_vb = 1'b1; sx = '0; sy = '0; w_slot = '0; end
    wire            lstart = p_hb && !src_hb;             // a line's first dot
    wire            fstart = lstart && p_vb && !src_vb;   // the frame's first line
    wire [XW-1:0]   x_now = lstart ? '0 : sx;
    wire [YW-1:0]   y_now = !lstart ? sy : fstart ? '0 : sy + 1'd1;
    wire            vis = !src_hb && !src_vb;
    always @(posedge clk) if (src_ce) begin
        p_hb <= src_hb;
        p_vb <= src_vb;
        if (lstart) begin
            sy <= y_now;
            if (fstart) w_slot <= '0;
            else if (!y_now[0]) w_slot <= (w_slot == SLW'(RING - 1)) ? '0 : w_slot + 1'd1;
        end
        if (vis) sx <= x_now + 1'd1;
    end

    // the even line of a pair, held while the odd one comes
    logic [23:0] ebuf [0:(1 << XW)-1];
    logic [23:0] e_q;
    always_ff @(posedge clk) begin
        if (src_ce && vis && !y_now[0]) ebuf[x_now] <= src_rgb;
        e_q <= ebuf[x_now];
    end

    // ...and with it, one clock later, the pair's dot into the ring
    logic                st_v;
    logic [SLW+XW-1:0]   st_a;
    logic [23:0]         st_rgb;
    initial st_v = 1'b0;
    always @(posedge clk) begin
        st_v   <= src_ce && vis && y_now[0];
        st_a   <= {w_slot, x_now};
        st_rgb <= src_rgb;
    end
    function automatic [5:0] avg6(input [7:0] a, input [7:0] b);
        return 6'(({1'b0, a} + {1'b0, b}) >> 3);          // (a + b) >> 1, top 6 bits
    endfunction
    wire [17:0] pair = sharp_s[1] ? {e_q[23:18], e_q[15:10], e_q[7:2]}
                     : {avg6(e_q[23:16], st_rgb[23:16]), avg6(e_q[15:8], st_rgb[15:8]),
                        avg6(e_q[7:0], st_rgb[7:0])};
    logic [17:0]       ring [0:(1 << (SLW + XW))-1];
    logic [SLW+XW-1:0] p_ra;
    logic [17:0]       p_q;
    always_ff @(posedge clk) begin
        if (st_v) ring[st_a] <= pair;
        p_q <= ring[p_ra];
    end

    // ------------------------------------------------------------ the output
    // frame start: DELAY clocks after the source's first visible line starts
    logic [DW-1:0] dly;
    logic          dly_on;
    initial begin dly = '0; dly_on = 1'b0; end
    wire           go = dly_on && (dly == '0);
    always @(posedge clk) begin
        if (src_ce && fstart) begin dly <= DW'(DELAY - 1); dly_on <= 1'b1; end
        else if (dly_on) begin
            if (dly == '0) dly_on <= 1'b0;
            else dly <= dly - 1'd1;
        end
    end

    logic [CW-1:0]  cc;                      // clock within the dot
    logic [OW-1:0]  od;                      // dot within the line
    logic [LW-1:0]  ol;                      // line within the frame
    logic [SLW-1:0] r_slot;                  // the ring slot of this line's pair
    logic [LW-1:0]  acc;                     // Bresenham
    logic           long_l;                  // this line's last dot is a clock longer
    initial begin cc = '0; od = '0; ol = LW'(LINES - 1); r_slot = '0; acc = '0; long_l = 1'b0; end
    wire  [CW-1:0]  dot_last = (od != OW'(DOTS - 1)) ? CW'(DOT - 1)
                             : long_l ? CW'(DOT + PAD) : CW'(DOT + PAD - 1);
    wire  [LW:0]    acc_n = LW1'(acc) + LW1'(LONG);
    always @(posedge clk) begin
        o_ce <= (cc == CW'(1));
        if (cc == '0)                        // this dot's pixel: address, then data
            p_ra <= {r_slot, od[XW-1:0]};
        if (cc == CW'(2)) begin              // and show it
            o_rgb <= (od < OW'(SW) && ol < LW'(SH / 2))
                   ? {p_q[17:12], 2'b00, p_q[11:6], 2'b00, p_q[5:0], 2'b00} : 24'h0;
            o_hb  <= (od >= OW'(SW));
            o_vb  <= (ol >= LW'(SH / 2));
            o_hs  <= (od >= OW'(HS0)) && (od < OW'(HS1));
            o_vs  <= (ol >= LW'(VS0)) && (ol < LW'(VS1));
        end
        if (go) begin                        // frame start (the natural wrap, once locked)
            cc <= '0; od <= '0; ol <= '0; r_slot <= '0;
            long_l <= 1'b0;                  // line 0 short; LONG < LINES always
            acc <= LW'(LONG);
        end else if (cc == dot_last) begin
            cc <= '0;
            if (od == OW'(DOTS - 1)) begin
                od <= '0;
                if (ol == LW'(LINES - 1)) begin
                    ol <= '0; r_slot <= '0;
                end else begin
                    ol <= ol + 1'd1;
                    if (ol < LW'(SH / 2))    // past a picture line: the next pair's slot
                        r_slot <= (r_slot == SLW'(RING - 1)) ? '0 : r_slot + 1'd1;
                end
                long_l <= (acc_n >= LW1'(LINES));
                acc <= LW'((acc_n >= LW1'(LINES)) ? acc_n - LW1'(LINES) : acc_n);
            end else od <= od + 1'd1;
        end else cc <= cc + 1'd1;
    end
endmodule
