//------------------------------------------------------------------------------
// The on-screen keypad: a phone's keys drawn over the picture, the Pocket's
// pad pressing them.
//
// The phone has more keys than the Pocket has buttons.  The menu can put A B
// X Y L R on any digit (IO_KEYMAP), but not all ten at once, and * and C
// nowhere.  So, as the BBC Micro core's keyboard does (its rtl/bbc_osk.sv is
// where this came from), the core draws the keys and the pad types on them:
//
//   SELECT + R    show the keypad, and dismiss it
//   d-pad         move the highlight; it wraps, and holding repeats
//   A or B        press the highlighted key: it is down while the button is,
//                 and at least MIN_HOLD frames
//   Y             move the keypad to the other end of the screen, to see
//                 what it covers
//
//   [ soft L ] [ C ] [ soft R ]       the layout, drawn by
//   [ 1 ]  [ 2 ]  [ 3 ]               tools/make_osk_panel.py into
//   [ 4 ]  [ 5 ]  [ 6 ]               rtl/osk/ngage_osk_panel.{mif,hex}
//   [ 7 ]  [ 8 ]  [ 9 ]
//   [ * ]  [ 0 ]  [ # ]
//
// What the machine sees (`keys`, IO_KEYS in sw/include/ngvm_hw.h):
//   - bits 0-11 are the pad, as before, while the keypad is down;
//   - while it is up, they are all 0: every button belongs to the keypad;
//   - bits 12-26 are the keypad's keys, one each (0-9, *, #, left soft,
//     right soft, C), and at most one at a time;
//   - SELECT and R reach the machine GUARD frames late, so that the chord
//     can be told from either button alone before either has been sent.
//     Once both are down neither is sent until both are up again, so the
//     chord never reaches the game as # or a soft key.
//
// Position is counted from the LCD's de and vsync, which it registers on
// cen_pix (rtl/ngvm_lcd.sv): during a dot, x is that dot's column, and the
// panel's pixel for the NEXT dot is looked up and registered on the cen_pix
// that starts it -- the same edge that registers the LCD's colour for it, so
// core_top's mux sees the two together, and both leave a fixed number of
// clocks before clk_vid samples them (projects/ngage_pocket.sdc).
//------------------------------------------------------------------------------
`default_nettype none

module ngage_osk #(
    parameter int X0     = 52,          // the panel's left edge: (176 - 72) / 2
    parameter int Y_LOW  = 124,         // its top edge at the bottom of the picture
    parameter int Y_HIGH = 4,           // ... and at the top (Y moves it)
    parameter int GUARD  = 4,           // frames SELECT and R are held back
    parameter int MIN_HOLD = 4,         // frames a key is down at the least
    parameter int GAP    = 2            // frames it is up before the next press
) (
    input  logic        clk,
    input  logic        rst,            // the core's: down, cursor on 5
    input  logic        cen_pix,
    input  logic        de, vsync,      // the LCD's, registered on cen_pix

    input  logic [11:0] pad,            // the Pocket's buttons, KEY_* order, 1 = pressed
    output logic [26:0] keys,           // IO_KEYS, registered

    output logic        visible,        // the keypad is up and has the pad
    output logic        active,         // this dot is the panel's,
    output logic        pix,            // it is lit,
    output logic        held,           // and its key is down

    // the same three for the turned raster (ngvm_lcd.sv, the Analogizer's
    // TATE picture), looked up by place: t_gx, t_gy are the picture's column
    // and row of the dot the next t_cen shows, and the outputs are
    // registered on that t_cen, as the turned raster's colour is
    input  logic        t_cen, t_vis,
    input  logic  [7:0] t_gx, t_gy,
    output logic        t_active, t_pix, t_held
);
    localparam int CW = 24, CH = 16;            // a cell
    localparam int PW = 3 * CW, PH = 5 * CH;    // the panel, 72 x 80
    localparam int K_UP = 0, K_DOWN = 1, K_LEFT = 2, K_RIGHT = 3, K_A = 4, K_B = 5;
    localparam int K_Y = 7, K_R = 9, K_SELECT = 10;

    // ------------------------------------------------------------- the bitmap
    // 72 x 80 at a bit a pixel, 9 bytes a row; the generator also puts its
    // key map at 0x2D0, which only the bench reads.
    // Loaded two ways from one generator output, as the BBC core does it:
    // Quartus through the RAM's init attribute (rtl/ is on its search path,
    // so "osk/..." resolves), the benches with $readmemh from the repository
    // root, where sim/run_osk.sh runs them.  ALTERA_RESERVED_QIS is defined
    // while Quartus synthesises.
    (* ram_init_file = "osk/ngage_osk_panel.mif" *) logic [7:0] rom [1024];
`ifndef ALTERA_RESERVED_QIS
    initial $readmemh("rtl/osk/ngage_osk_panel.hex", rom);
`endif

    // --------------------------------------------------------- where we are
    logic       de_d, vs_d;
    logic [7:0] x, y;                   // the dot's column (during it) and line
    wire        frame = cen_pix && vsync && !vs_d;

    always_ff @(posedge clk) begin
        if (cen_pix) begin
            de_d <= de;
            vs_d <= vsync;
            x <= de ? x + 8'd1 : 8'd0;
            if (vsync && !vs_d)  y <= 8'd0;
            else if (!de && de_d) y <= y + 8'd1;
        end
    end

    // ------------------------------------------------------------ the chord
    // Seen at any clock, acted on at the next frame, so the panel appears and
    // goes whole.  `chorded` holds SELECT and R off the machine from the
    // moment both are down until both are up.
    wire  sel = pad[K_SELECT], r = pad[K_R];
    wire  chord = sel && r;
    logic chord_d, flip, chorded;

    always_ff @(posedge clk) begin
        chord_d <= chord;
        if (chord && !chord_d) flip <= 1'b1;
        if (frame && flip) begin visible <= !visible; flip <= 1'b0; end
        if (chord) chorded <= 1'b1;
        else if (!sel && !r) chorded <= 1'b0;
        if (rst) begin visible <= 1'b0; flip <= 1'b0; end
    end

    // SELECT and R, GUARD frames late: a frame's worth of each in a shift
    // register, emptied by the chord, so the first of the two pressed has
    // not reached the machine when the second arrives.
    logic [GUARD-1:0] sel_q, r_q;
    always_ff @(posedge clk) begin
        if (rst || chord || chorded || visible) begin
            sel_q <= '0;
            r_q   <= '0;
        end else if (frame) begin
            sel_q <= {sel_q[GUARD-2:0], sel};
            r_q   <= {r_q[GUARD-2:0], r};
        end
    end

    // ------------------------------------------------------------ the cursor
    // Opens where it was left, on 5 the first time.  A direction moves at the
    // next frame, again after 18 frames held, then every 6.
    logic [1:0] cx;
    logic [2:0] cy;
    logic [4:0] rpt;
    wire        dir = pad[K_UP] || pad[K_DOWN] || pad[K_LEFT] || pad[K_RIGHT];

    always_ff @(posedge clk) begin
        if (!visible) rpt <= 5'd0;
        else if (frame) begin
            if (!dir) rpt <= 5'd0;
            else if (rpt <= 5'd1) begin
                rpt <= (rpt == 5'd0) ? 5'd18 : 5'd6;
                if (pad[K_UP])    cy <= (cy == 3'd0) ? 3'd4 : cy - 3'd1;
                if (pad[K_DOWN])  cy <= (cy == 3'd4) ? 3'd0 : cy + 3'd1;
                if (pad[K_LEFT])  cx <= (cx == 2'd0) ? 2'd2 : cx - 2'd1;
                if (pad[K_RIGHT]) cx <= (cx == 2'd2) ? 2'd0 : cx + 2'd1;
            end else rpt <= rpt - 5'd1;
        end
        if (rst) begin cx <= 2'd1; cy <= 3'd2; end
    end

    // Y, taken a frame at a time, so the panel moves between frames
    logic y_d, top;
    always_ff @(posedge clk) begin
        if (frame) begin
            y_d <= pad[K_Y];
            if (visible && pad[K_Y] && !y_d) top <= !top;
        end
        if (rst) top <= 1'b0;
    end

    // ------------------------------------------------------------ the press
    // The kernel reads IO_KEYS once a frame (sw/kernel/event.c), so a key is
    // down for at least MIN_HOLD frames -- a tap shorter than a frame is not
    // lost between two reads -- and up for at least GAP before the next, so
    // two taps of one key read as two (as typing letters on a phone's keys
    // needs).  A press that comes during either waits, and is then made on
    // the key the cursor was on when it came.  `own` is the button that made
    // the press still being down: a later press does not lengthen it.
    function automatic logic [3:0] key_of(input logic [2:0] row, input logic [1:0] col);
        case (row)
            3'd0:    key_of = (col == 2'd0) ? 4'd12 : (col == 2'd1) ? 4'd14 : 4'd13;  // soft L, C, soft R
            3'd4:    key_of = (col == 2'd0) ? 4'd10 : (col == 2'd1) ? 4'd0  : 4'd11;  // *, 0, #
            default: key_of = 4'({row, 1'b0} + {1'b0, row}) - 4'd2 + 4'(col);       // 1-9
        endcase
    endfunction

    wire        press = pad[K_A] || pad[K_B];
    logic       press_d, down, own, pend;
    logic [2:0] krow, prow;
    logic [1:0] kcol, pcol;
    logic [2:0] minf;
    logic [1:0] gapf;
    wire        hit = press && !press_d;

    always_ff @(posedge clk) begin
        press_d <= press;
        if (!press) own <= 1'b0;
        if (rst || !visible) begin
            down <= 1'b0; pend <= 1'b0; gapf <= 2'd0; minf <= 3'd0;
        end else begin
            if (down) begin
                if (frame && minf != 3'd0) minf <= minf - 3'd1;
                if (!own && minf == 3'd0) begin down <= 1'b0; gapf <= 2'(GAP); end
            end else if (gapf != 2'd0) begin
                if (frame) gapf <= gapf - 2'd1;
            end else if (pend || hit) begin
                down <= 1'b1;
                krow <= pend ? prow : cy;
                kcol <= pend ? pcol : cx;
                own  <= press;
                minf <= 3'(MIN_HOLD);
                pend <= 1'b0;
            end
            if (hit && (down || gapf != 2'd0)) begin
                pend <= 1'b1; prow <= cy; pcol <= cx;
            end
        end
    end

    // ------------------------------------------------------- the machine's keys
    wire [3:0]  dkey = key_of(krow, kcol);
    wire [11:0] own_keys = visible ? 12'd0
                         : {pad[11], sel_q[GUARD-1], r_q[GUARD-1], pad[8:0]};
    always_ff @(posedge clk)
        keys <= {(down ? 15'd1 << dkey : 15'd0), own_keys};

    // ----------------------------------------------------------- the picture
    // The next dot's place in the panel, its byte of the bitmap a clock later
    // (the address is registered first: there are fourteen clocks to a dot),
    // and everything registered on the cen_pix that starts it.
    wire  [8:0] xn   = {1'b0, x} + 9'd1;
    wire  [8:0] yt   = top ? 9'(Y_HIGH) : 9'(Y_LOW);
    wire        in_x = (xn >= 9'(X0)) && (xn < 9'(X0 + PW));
    wire        in_y = ({1'b0, y} >= yt) && ({1'b0, y} < yt + 9'(PH));
    wire  [6:0] px   = 7'(xn - 9'(X0));                 // 0-71
    wire  [6:0] py   = 7'({1'b0, y} - yt);              // 0-79
    logic [9:0] rom_a;
    logic [7:0] rom_q;
    always_ff @(posedge clk) begin
        rom_a <= {py, 3'b000} + {3'b000, py} + {6'd0, px[6:3]};   // py * 9 + px / 8
        rom_q <= rom[rom_a];
    end

    // which cell, and where in it: the highlight fills the key inside its
    // outline (2-21 across, 2-13 down), and the glyph shows through dark
    wire [1:0] col   = (px < 7'(CW)) ? 2'd0 : (px < 7'(2 * CW)) ? 2'd1 : 2'd2;
    wire [6:0] lx    = px - ({2'b00, col, 3'b000} + {1'b0, col, 4'b0000});   // px - col * 24
    wire [2:0] row   = py[6:4];
    wire [3:0] ly    = py[3:0];
    wire       inner = (lx >= 7'd2) && (lx <= 7'd21) && (ly >= 4'd2) && (ly <= 4'd13);
    wire       on_cursor = (row == cy) && (col == cx);
    wire       on_down   = down && (row == krow) && (col == kcol);
    wire       bit_      = rom_q[3'd7 - px[2:0]];

    always_ff @(posedge clk) begin
        if (cen_pix) begin
            active <= visible && de && in_x && in_y;
            pix    <= bit_ ^ (inner && on_cursor);
            held   <= on_down;
        end
    end

    // ------------------------------------------------ the turned picture's
    // The same lookup at the turned raster's place (its own read of the
    // bitmap), for the dot this one's own column and row name
    wire  [8:0] t_xn   = {1'b0, t_gx};
    wire        t_in_x = (t_xn >= 9'(X0)) && (t_xn < 9'(X0 + PW));
    wire        t_in_y = ({1'b0, t_gy} >= yt) && ({1'b0, t_gy} < yt + 9'(PH));
    wire  [6:0] t_px   = 7'(t_xn - 9'(X0));
    wire  [6:0] t_py   = 7'({1'b0, t_gy} - yt);
    logic [9:0] t_rom_a;
    logic [7:0] t_rom_q;
    always_ff @(posedge clk) begin
        t_rom_a <= {t_py, 3'b000} + {3'b000, t_py} + {6'd0, t_px[6:3]};
        t_rom_q <= rom[t_rom_a];
    end
    wire [1:0] t_col   = (t_px < 7'(CW)) ? 2'd0 : (t_px < 7'(2 * CW)) ? 2'd1 : 2'd2;
    wire [6:0] t_lx    = t_px - ({2'b00, t_col, 3'b000} + {1'b0, t_col, 4'b0000});
    wire [2:0] t_row   = t_py[6:4];
    wire [3:0] t_ly    = t_py[3:0];
    wire       t_inner = (t_lx >= 7'd2) && (t_lx <= 7'd21) && (t_ly >= 4'd2) && (t_ly <= 4'd13);
    wire       t_on_cursor = (t_row == cy) && (t_col == cx);
    wire       t_on_down   = down && (t_row == krow) && (t_col == kcol);
    wire       t_bit       = t_rom_q[3'd7 - t_px[2:0]];

    always_ff @(posedge clk) begin
        if (t_cen) begin
            t_active <= visible && t_vis && t_in_x && t_in_y;
            t_pix    <= t_bit ^ (t_inner && t_on_cursor);
            t_held   <= t_on_down;
        end
    end
endmodule

`default_nettype wire
