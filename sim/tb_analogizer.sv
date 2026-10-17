// The Analogizer path on its own: target/pocket/pocket_analogizer.sv with the
// vendored adapter module behind it, driven the way core_top drives it -- the
// core's raster, the 48 MHz Analogizer clock in phase with the system clock,
// and the settings word written over the bridge as the core's menu writes it.
// The raster is set at the top of the module: change it with the core's.  It
// reads the cartridge pins as the ADV7123 would and checks:
//
//   idle    menu default: every cartridge pin as on a core without an
//           Analogizer, and the controller words pass through
//   menu    every option of every Analogizer entry in the package's
//           interact.json, set the way the firmware sets a masked entry
//           (read the word back as the bridge samples it, merge, write):
//           the word, the adapter's copy of it and the enable each follow
//   RGBS    every visible pixel of a frame reaches the DAC pins, in order,
//           as its top six bits per channel; csync once a line, hsync-long
//   position  both ends of the menu's position sliders: csync moves by the
//           dots and lines asked and stays out of the picture and the Y/C
//           colour burst, the picture is unchanged, and a jump between
//           settings never inverts csync
//   width   both ends of the width slider: every line is as long as asked,
//           centred where it was, and holds every dot (stretched) or an
//           even subset of them (squashed), in order; the lines stay where
//           they were and the scandoubler is untouched
//   SVGA    the scandoubler: twice the lines per frame, at half the period
//   YPbPr, Y/C  run without an unknown on any pin (no reference to compare)
//   SNAC    each assignment puts pads where AnalogizerConfigurator says
//   blank   "blank the Pocket screen" reaches pocket_off
//
// sim/run_analogizer.sh builds and runs it.
`timescale 1ps/1ps
`default_nettype none

module tb_analogizer;
    // ------------------------------------------- the core's raster: SET THESE
    // to the core's (its video module, and core_top's pocket_analogizer
    // parameters).  The template: rtl/mycore_core.sv, 6.857 MHz dots from 96 MHz.
    localparam int DIV    = 14;           // system clocks a dot
    localparam int HTOTAL = 452, VTOTAL = 253;
    localparam int X0 = 0,   X1 = 319;    // visible dots, inclusive
    localparam int Y0 = 16,  Y1 = 239;    // visible lines, inclusive
    localparam int HS0 = 344, HS1 = 376;  // hsync [HS0, HS1)
    localparam int VS0 = 242, VS1 = 245;  // vsync [VS0, VS1)
    localparam int CLK_HZ = 48_000_000;   // the Analogizer's clock: clk_sys / 2
    localparam int W = X1 - X0 + 1, H = Y1 - Y0 + 1;
    localparam int APD = DIV / 2;         // Analogizer clocks a dot
    // the end of the Y/C colour burst after hsync ends, in Analogizer clocks
    // (pocket_analogizer's CB_NTSC; NTSC's is the later)
    localparam int CB_END = (2 * (CLK_HZ * 3256.0 / 3150000000.0) + 1) / 2
                          + (2 * (CLK_HZ * 792.0 / 315000000.0) + 1) / 2;
    localparam int FRAME = HTOTAL * VTOTAL * APD;

    // ------------------------------------------------------------- clocks
    logic clk_src = 1'b0, clk = 1'b0, clk_74a = 1'b0;
    always #5208 clk_src = ~clk_src;      // 96 MHz (10.416 ns)
    always #10416 clk = ~clk;             // 48 MHz, edges on clk_src's
    always #6734 clk_74a = ~clk_74a;      // 74.25 MHz, unrelated

    // ------------------------------------------------- the core's raster
    int         div = 0;
    logic [9:0] hpos = 10'd0, vpos = 10'd0;
    logic       pix_ce = 1'b0;
    logic       hs, vs, hb, vb;
    logic [23:0] rgb;
    always_ff @(posedge clk_src) begin
        div    <= (div == DIV - 1) ? 0 : div + 1;
        pix_ce <= (div == DIV - 1);
        if (pix_ce) begin
            if (hpos == 10'(HTOTAL - 1)) begin
                hpos <= 10'd0;
                vpos <= (vpos == 10'(VTOTAL - 1)) ? 10'd0 : vpos + 10'd1;
            end else hpos <= hpos + 10'd1;
        end
    end
    wire vis_x = (hpos >= 10'(X0)) && (hpos <= 10'(X1));
    wire vis_y = (vpos >= 10'(Y0)) && (vpos <= 10'(Y1));
    // a colour every dot can be told apart by, even at the DAC's six bits a
    // channel: x[8:3] in red, x[5:0] in blue, y in green
    function automatic [23:0] colour(input [9:0] x, input [9:0] y);
        colour = {x[8:3], 2'b00, y[7:0], x[5:0], 2'b00};
    endfunction
    function automatic int dac_x(input [5:0] r, input [5:0] b);
        dac_x = {r[5:3], b};
    endfunction
    always_ff @(posedge clk_src) if (pix_ce) begin
        hb  <= !vis_x;  vb <= !vis_y;
        hs  <= (hpos >= 10'(HS0)) && (hpos < 10'(HS1));
        vs  <= (vpos >= 10'(VS0)) && (vpos < 10'(VS1));
        rgb <= (vis_x && vis_y) ? colour(hpos, vpos) : 24'h0;
    end

    // ------------------------------------------------------------- bridge
    logic [31:0] bridge_addr = 32'h0, bridge_wr_data = 32'h0;
    logic        bridge_wr = 1'b0, bridge_rd = 1'b0;
    wire  [31:0] bridge_rd_data;
    // the whole word, as a firmware that merges the menu's fields itself
    // writes it: a number, no byte swap
    logic [31:0] last_word = 32'h0;          // the word as last written
    task automatic write_settings(input [31:0] v);
        last_word = v;
        write_word(32'hF7000000, v);
    endtask
    task automatic write_word(input [31:0] a, input [31:0] v);
        @(posedge clk_74a);
        bridge_addr    <= a;
        bridge_wr_data <= v;
        bridge_wr      <= 1'b1;
        @(posedge clk_74a);
        bridge_wr      <= 1'b0;
        repeat (200) @(posedge clk);         // into the Analogizer's domain and back
    endtask
    function automatic [31:0] settings(input ena, input [4:0] snac, input [3:0] assign_,
                                       input [3:0] video, input blank);
        settings = {16'h0, 1'b0, blank, video, assign_, ena, snac};
    endfunction

    // a read as io_bridge_peripheral does one: the address, then the data
    // sampled four clocks later, and only then the bridge_rd pulse
    task automatic read_settings(output [31:0] v);
        read_word(32'hF7000000, v);
    endtask
    task automatic read_word(input [31:0] a, output [31:0] v);
        @(posedge clk_74a);
        bridge_addr <= a;
        repeat (4) @(posedge clk_74a);
        v = bridge_rd_data;
        bridge_rd <= 1'b1;
        @(posedge clk_74a);
        bridge_rd <= 1'b0;
    endtask
    // one menu option, as the firmware sets a masked entry, and checked
    logic [31:0] menu_model = 32'h0;
    task automatic menu_try(input [31:0] mask, input [31:0] value, input string what);
        logic [31:0] w;
        if ((value & mask) != 0) begin
            $display("  %s: value %08h has bits outside its field", what, value);
            fail("menu: an option writes outside its mask");
        end
        read_settings(w);
        if (w !== menu_model) begin
            $display("  %s: read back %08h, menu holds %08h", what, w, menu_model);
            fail("menu: the word does not read back");
        end
        menu_model = (menu_model & mask) | value;
        write_settings((w & mask) | value);
        if (dut.u_analogizer.analogizer_config_s[30:0] !== menu_model[30:0] ||
            ena !== menu_model[5]) begin
            $display("  %s: adapter has %08h ena %b, menu wrote %08h", what,
                     dut.u_analogizer.analogizer_config_s, ena, menu_model);
            fail("menu: the adapter does not see the menu's word");
        end
    endtask
`include "menu.svh"

    // --------------------------------------------------------- controllers
    logic [31:0] cont1_key = 32'h1000_0001, cont2_key = 32'h2000_0002;
    logic [31:0] cont3_key = 32'h3000_0004, cont4_key = 32'h4000_0008;
    wire  [31:0] key1, key2, key3, key4;
    wire         ena, pocket_off;

    // ----------------------------------------------------------- cartridge
    wire [7:0] bank3, bank2, bank1;
    wire [7:4] bank0;
    wire       pin30, pin31;
    wire       bank3_dir, bank2_dir, bank1_dir, bank0_dir, pin30_dir, pin31_dir, pin30_pwroff;

    logic rst = 1'b1;

    pocket_analogizer #(.CLK_HZ(CLK_HZ), .LINE_LEN(HTOTAL)) dut (
        .clk_74a(clk_74a), .clk(clk), .rst(rst),
        .clk_src(clk_src), .src_pix_ce(pix_ce), .src_rgb(rgb),
        .src_hs(hs), .src_vs(vs), .src_hb(hb), .src_vb(vb),
        .bridge_addr(bridge_addr), .bridge_rd(bridge_rd),
        .bridge_rd_data(bridge_rd_data), .bridge_wr(bridge_wr), .bridge_wr_data(bridge_wr_data),
        .cont1_key(cont1_key), .cont2_key(cont2_key), .cont3_key(cont3_key), .cont4_key(cont4_key),
        .key1(key1), .key2(key2), .key3(key3), .key4(key4),
        .ena(ena), .pocket_off(pocket_off), .ps2_code_new(), .ps2_code(),
        .cart_tran_bank2(bank2), .cart_tran_bank2_dir(bank2_dir),
        .cart_tran_bank3(bank3), .cart_tran_bank3_dir(bank3_dir),
        .cart_tran_bank1(bank1), .cart_tran_bank1_dir(bank1_dir),
        .cart_tran_bank0(bank0), .cart_tran_bank0_dir(bank0_dir),
        .cart_tran_pin30(pin30), .cart_tran_pin30_dir(pin30_dir),
        .cart_pin30_pwroff_reset(pin30_pwroff),
        .cart_tran_pin31(pin31), .cart_tran_pin31_dir(pin31_dir)
    );

    // the DAC's view of the pins (openFPGA_Pocket_Analogizer.v, end)
    wire [5:0] dac_r = bank3[7:2], dac_g = bank2[5:0];
    wire [5:0] dac_b = {bank1[4:0], bank2[7]};
    wire       dac_hs = bank3[1], dac_vs = bank3[0], dac_blank_n = bank2[6];

    int errors = 0;
    task automatic fail(input string what);
        $display("FAIL: %s", what);
        errors++;
    endtask

    // wait for the start of a frame as the core makes it
    task automatic frame_start();
        @(posedge clk_src iff (pix_ce && hpos == 10'(HTOTAL - 1) && vpos == 10'(VTOTAL - 1)));
    endtask

    // ------------------------------------------------------------- checks
    // RGBS: collect the visible pixels as the DAC samples them (on clk) and
    // compare them, in order, with the frame the core drew
    task automatic check_rgbs();
        int n, bad, line_px, lines, cs_lo, cs_runs, cs_bad;
        logic [17:0] want, got, prev;
        logic        was_blank, cs_prev;
        int          x, y, run;
        // the expected stream: visible dots in raster order
        logic [17:0] exp_q[$];
        for (y = Y0; y <= Y1; y++)
            for (x = X0; x <= X1; x++) begin
                logic [23:0] c = colour(10'(x), 10'(y));
                exp_q.push_back({c[23:18], c[15:10], c[7:2]});
            end
        frame_start();
        repeat (2000) @(posedge clk);       // the pipeline's own latency, well inside vblank
        n = 0; bad = 0; run = 0; prev = 18'h3ffff; line_px = 0; lines = 0;
        was_blank = 1'b1; cs_prev = 1'b1; cs_lo = 0; cs_runs = 0; cs_bad = 0;
        // one frame of the Analogizer's clock
        repeat (FRAME) begin
            @(negedge clk);
            if (dac_blank_n) begin
                got = {dac_r, dac_g, dac_b};
                // a dot is held APD clocks: take it once, on its first
                if (was_blank || run == APD) begin
                    if (n < exp_q.size()) begin
                        if (got !== exp_q[n]) begin
                            if (bad < 5) $display("  dot %0d (line %0d, x %0d): got %05h want %05h",
                                                  n, n / W, n % W, got, exp_q[n]);
                            bad++;
                        end
                    end
                    n++; run = 1; line_px++;
                end else run++;
            end else if (!was_blank) begin
                if (line_px != W) cs_bad++;
                line_px = 0; lines++; run = 0;
            end
            was_blank = !dac_blank_n;
            // csync: active low, the hsync's length on a line outside vsync
            if (!dac_hs) cs_lo++;
            else if (!cs_prev) begin
                if (cs_lo == (HS1 - HS0) * APD) cs_runs++;
                cs_lo = 0;
            end
            cs_prev = dac_hs;
        end
        $display("RGBS: %0d visible dots in %0d lines, %0d differ; %0d short lines; %0d csync pulses of %0d dots",
                 n, lines, bad, cs_bad, cs_runs, HS1 - HS0);
        if (n != W * H) fail("RGBS: wrong number of visible dots");
        if (lines != H) fail("RGBS: wrong number of visible lines");
        if (bad != 0) fail("RGBS: pixels differ from what the core drew");
        if (cs_bad != 0) fail("RGBS: a line without every visible dot");
        if (cs_runs < VTOTAL - (VS1 - VS0) - 2) fail("RGBS: csync not one hsync-long pulse a line");
        if (dac_vs !== 1'b1) fail("RGBS: VGA vsync pin not high");
    endtask

    // the position sliders, as the menu writes them (whole words, signed),
    // and read back as the firmware reads them every frame
    task automatic set_position(input int h, input int v);
        logic [31:0] rh, rv;
        write_word(32'hF7000004, 32'(h));
        write_word(32'hF7000008, 32'(v));
        read_word(32'hF7000004, rh);
        read_word(32'hF7000008, rv);
        if (rh !== 32'(h) || rv !== 32'(v)) begin
            $display("  position %0d,%0d: read back %08h %08h", h, v, rh, rv);
            fail("position: the sliders do not read back");
        end
        read_word(32'hF7000000, rh);
        if (rh !== last_word) fail("position: a slider changed the settings word");
        repeat (20) @(posedge clk);
    endtask

    // RGBS, at the pins: csync's fall to the first visible dot of the frame
    // after the vsync, in whole lines (gv), and of a line, in clocks (gh);
    // and for how many clocks csync is low while a dot is being drawn: a
    // sync moved out of the blanking (an hsync, or a vsync, during which
    // csync is low all line)
    task automatic measure_position(output int gh, output int gv, output int in_pic);
        int t, run, vs_t;
        logic cs_p, bl_p;
        frame_start();
        repeat (2000) @(posedge clk);
        in_pic = 0;
        repeat (FRAME) begin
            @(negedge clk);
            if (dac_blank_n && !dac_hs) in_pic++;
        end
        // start from an ordinary hsync, never partway through a vsync (a
        // slider can put vsync at the top of the frame)
        run = 0;
        forever begin
            @(negedge clk);
            if (!dac_hs) run++;
            else if (run > 0 && run <= (HS1 - HS0) * APD + 4) break;
            else run = 0;
        end
        // the vsync: the first low run on csync longer than two hsyncs
        run = 0; t = 0;
        while (run < 2 * (HS1 - HS0) * APD) begin
            @(negedge clk); t++;
            run = dac_hs ? 0 : run + 1;
        end
        vs_t = t - run;
        do begin bl_p = dac_blank_n; @(negedge clk); t++; end while (bl_p || !dac_blank_n);
        gv = (t - vs_t + HTOTAL * APD / 2) / (HTOTAL * APD);
        // a line: csync's fall to the next visible dot
        do begin cs_p = dac_hs; @(negedge clk); end while (!cs_p || dac_hs);
        t = 0;
        do begin bl_p = dac_blank_n; @(negedge clk); t++; end while (bl_p || !dac_blank_n);
        gh = t;
    endtask

    // the width slider, as the menu writes it, read back
    task automatic set_size(input int p);
        logic [31:0] r;
        write_word(32'hF700000C, 32'(p));
        read_word(32'hF700000C, r);
        if (r !== 32'(p)) fail("width: the slider does not read back");
        repeat (20) @(posedge clk);
    endtask

    // one frame at the pins, RGBS: each visible line's start (clocks from
    // csync's fall), length, and the dots it shows, decoded from the colour
    task automatic check_width(input int p, input int st0);
        int t, st, len, lines, bad_seq, bad_len, bad_hold, bad_ctr, run, x, px, holds_lo, holds_hi;
        int want_len, lo, hi;
        logic cs_p, bl_p, in_line;
        real hold;
        frame_start();
        repeat (2000) @(posedge clk);
        // start inside vertical blanking: a whole line with no picture (a
        // board that draws on its last line has it a line late here)
        begin
            int dark = 0;
            while (dark < HTOTAL * APD) begin
                @(negedge clk);
                dark = dac_blank_n ? 0 : dark + 1;
            end
        end
        want_len = (W * APD * (100 + p) + 50) / 100;
        hold = APD * (100.0 + p) / 100.0;
        lo = $floor(hold); hi = $ceil(hold);
        lines = 0; bad_seq = 0; bad_len = 0; bad_hold = 0; bad_ctr = 0;
        holds_lo = 0; holds_hi = 0;
        t = 0; in_line = 0; cs_p = 1; bl_p = 0;
        repeat (FRAME) begin
            @(negedge clk); t++;
            if (cs_p && !dac_hs) t = 0;               // csync falls: a line starts
            cs_p = dac_hs;
            if (dac_blank_n) begin
                x = dac_x(dac_r, dac_b);
                if (!bl_p) begin                        // the line's first dot
                    in_line = 1; st = t; len = 0; run = 0; px = x;
                    if (x != X0) bad_seq++;
                end
                len++;
                if (x == px) run++;
                else begin
                    if (x < px || x > px + ((p < 0) ? 2 : 1)) bad_seq++;
                    if (px != X0 && (run < lo || run > hi)) bad_hold++;
                    if (run == lo) holds_lo++; else if (run == hi) holds_hi++;
                    run = 1; px = x;
                end
            end else if (bl_p && in_line) begin         // the line's end
                in_line = 0; lines++;
                if (px != X1) bad_seq++;
                if (len < want_len - 2 || len > want_len + 2) bad_len++;
                // centred: the start moves by half the change in length
                if ((st - st0) * 2 + (len - W * APD) > 4 || (st - st0) * 2 + (len - W * APD) < -4) bad_ctr++;
            end
            bl_p = dac_blank_n;
        end
        $display("width %0d%%: %0d lines, %0d clocks a line (want %0d), start %0d (%0d at 0); dots held %0d or %0d clocks (%0d, %0d times); %0d out of order, %0d long or short, %0d off centre, %0d held wrongly",
                 p, lines, len, want_len, st, st0, lo, hi, holds_lo, holds_hi, bad_seq, bad_len, bad_ctr, bad_hold);
        if (lines != H) fail("width: wrong number of lines");
        if (bad_seq != 0) fail("width: dots missing or out of order");
        if (bad_len != 0) fail("width: a line is not the length asked");
        if (bad_ctr != 0) fail("width: the picture is not centred where it was");
        if (bad_hold != 0) fail("width: a dot held for the wrong time");
        if (st - (HS1 - HS0) * APD < CB_END) fail("width: the picture starts inside the Y/C colour burst");
    endtask

    // a slider jump, written just after a pulse at the old setting, that
    // puts the next one a dot (a line) after it ends: csync must not be low
    // while a dot is drawn in the three frames around it (header of
    // pocket_analogizer: sync_fix and the off-time rule)
    task automatic check_jump(input logic vert, input int from, input int to);
        int bad = 0;
        if (vert) set_position(0, from); else set_position(from, 0);
        repeat (FRAME) @(posedge clk);
        fork
            begin
                if (vert) begin
                    @(negedge dut.o_vs);
                    write_word(32'hF7000008, 32'(to));
                end else begin
                    @(negedge dut.o_hs iff !dut.b_vb);     // on a line with a picture
                    write_word(32'hF7000004, 32'(to));
                end
            end
            repeat (3 * FRAME) begin
                @(negedge clk);
                if (dac_blank_n && !dac_hs) bad++;
            end
        join
        $display("position: %s %0d to %0d at once: csync low for %0d clocks of picture",
                 vert ? "V" : "H", from, to, bad);
        if (bad != 0) fail("position: a jump in a slider turns csync inside out");
    endtask

    // the scandoubler: hsync pulses between two like vsync edges, and the
    // line period (either polarity: only like edges are compared)
    task automatic check_svga();
        int hs_n, period, last, t;
        logic hs_p, vs_p, vs_edge;
        frame_start();
        repeat (2000) @(posedge clk);
        vs_p = dac_vs;
        @(negedge clk iff dac_vs !== vs_p);
        vs_edge = dac_vs; vs_p = dac_vs; hs_p = dac_hs;
        hs_n = 0; last = 0; period = 0; t = 0;
        while (t < 2 * FRAME) begin
            @(negedge clk); t++;
            if (!hs_p && dac_hs) begin hs_n++; period = t - last; last = t; end
            hs_p = dac_hs;
            if (dac_vs !== vs_p && dac_vs === vs_edge) break;
            vs_p = dac_vs;
        end
        $display("SVGA: %0d hsync pulses in a frame of %0d clocks, line period %0d clocks", hs_n, t, period);
        if (hs_n != 2 * VTOTAL) fail("SVGA: not twice the core's lines");
        if (period * 2 != HTOTAL * APD) fail("SVGA: line period is not half the core's");
        if (t != FRAME) fail("SVGA: frame period is not the core's");
    endtask

    // no unknown on any output pin for a whole frame
    task automatic check_known(input string mode);
        int unk = 0, changes = 0;
        logic [17:0] prev = '0;
        frame_start();
        repeat (2000) @(posedge clk);
        repeat (FRAME) begin
            @(negedge clk);
            if ($isunknown({bank3, bank2, bank1[5:0]})) unk++;
            if ({dac_r, dac_g, dac_b} != prev) changes++;
            prev = {dac_r, dac_g, dac_b};
        end
        $display("%s: %0d clocks with an unknown pin, %0d colour changes", mode, unk, changes);
        if (unk != 0) fail({mode, ": unknown on the pins"});
        if (changes < 1000) fail({mode, ": the picture does not move"});
    endtask

    task automatic check_idle();
        if (bank3_dir !== 1'b0 || bank2_dir !== 1'b0 || bank1_dir !== 1'b0)
            fail("idle: a video bank is driven");
        if (bank0 !== 4'hf || bank0_dir !== 1'b1) fail("idle: bank0 not 4'hf, out");
        if (pin30_dir !== 1'b0 || pin31_dir !== 1'b0 || pin30_pwroff !== 1'b0)
            fail("idle: pin30/31 not as an unused port");
        // (the banks' own values are not checked: the simulator resolves a
        // released inout to 0, and with the translators set to input the
        // FPGA side drives nothing onto the port whatever it holds)
        if (key1 !== cont1_key || key2 !== cont2_key || key3 !== cont3_key || key4 !== cont4_key)
            fail("idle: controller words do not pass through");
        if (ena !== 1'b0 || pocket_off !== 1'b0) fail("idle: enabled by default");
    endtask

    // SNAC: the pads, forced at the adapter module's outputs (the serial
    // protocols are the adapter's and are not this bench's business)
    task automatic check_snac();
        logic [15:0] s1 = 16'h8011, s2 = 16'h4022, s3 = 16'h0044, s4 = 16'h0088;
        force dut.p1_btn = s1; force dut.p2_btn = s2;
        force dut.p3_btn = s3; force dut.p4_btn = s4;
        force dut.p1_joy = 32'h0000_7F7F; force dut.p2_joy = 32'h0000_7F7F;
        // type 1 (DB15), each assignment
        for (int a = 0; a <= 5; a++) begin
            logic [15:0] w1, w2, w3, w4;
            write_settings(settings(1'b1, 5'h01, 4'(a), 4'h0, 1'b0));
            repeat (10) @(posedge clk_74a);
            case (a)
                0: {w1, w2, w3, w4} = {s1, cont1_key[15:0], cont3_key[15:0], cont4_key[15:0]};
                1: {w1, w2, w3, w4} = {cont1_key[15:0], s1, cont3_key[15:0], cont4_key[15:0]};
                2: {w1, w2, w3, w4} = {s1, s2, cont3_key[15:0], cont4_key[15:0]};
                3: {w1, w2, w3, w4} = {s2, s1, cont3_key[15:0], cont4_key[15:0]};
                4: {w1, w2, w3, w4} = {cont1_key[15:0], cont2_key[15:0], s1, s2};
                default: {w1, w2, w3, w4} = {s1, s2, s3, s4};
            endcase
            if ({key1[15:0], key2[15:0], key3[15:0], key4[15:0]} !== {w1, w2, w3, w4}) begin
                $display("  assignment %0d: got %04h %04h %04h %04h want %04h %04h %04h %04h", a,
                         key1[15:0], key2[15:0], key3[15:0], key4[15:0], w1, w2, w3, w4);
                fail("SNAC: assignment maps the pads wrongly");
            end
        end
        // a PlayStation pad in analog mode: the left stick is the d-pad
        force dut.p1_joy = 32'h0000_FF10;     // Y full down, X full left
        write_settings(settings(1'b1, 5'h13, 4'd0, 4'h0, 1'b0));
        repeat (10) @(posedge clk_74a);
        if (key1[3:0] !== 4'b0110) fail("SNAC: analog stick is not down+left");
        // SNAC type none: pass-through even when enabled
        write_settings(settings(1'b1, 5'h00, 4'd2, 4'h0, 1'b0));
        repeat (10) @(posedge clk_74a);
        if (key1 !== cont1_key || key2 !== cont2_key) fail("SNAC: type none does not pass through");
        release dut.p1_btn; release dut.p2_btn; release dut.p3_btn; release dut.p4_btn;
        release dut.p1_joy; release dut.p2_joy;
        $display("SNAC: assignments 0-5, analog stick, none: checked");
    endtask

    initial begin
        repeat (50) @(posedge clk);
        check_idle();
        rst = 1'b0;
        repeat (50) @(posedge clk);
        check_idle();                         // out of reset, still no file
        $display("idle: checked");

        menu_entries();                       // every option, in file order
        if (MENU_OPTIONS < 20) fail("menu: interact.json has too few Analogizer options");
        write_settings(32'h0);                // back to the default
        repeat (10) @(posedge clk);
        check_idle();
        $display("menu: %0d options set by read-merge-write, each seen by the adapter", MENU_OPTIONS);

        write_settings(settings(1'b1, 5'h00, 4'd0, 4'h0, 1'b0));   // RGBS
        if (ena !== 1'b1) fail("enable bit not seen");
        if (bank3_dir !== 1'b1 || bank2_dir !== 1'b1 || bank1_dir !== 1'b1) fail("RGBS: video banks not driven");
        check_rgbs();

        // the position sliders: each end of the range the menu ships.  The
        // picture itself must not change, csync must move by exactly the
        // dots and lines asked, and stay out of the picture
        begin
            int gh0, gv0, e0, gh, gv, e;
            int hs[2] = '{POS_H_MAX, POS_H_MIN}, vs_[2] = '{POS_V_MAX, POS_V_MIN};
            if (POS_H_MAX <= 0 || POS_V_MAX <= 0 || POS_H_MIN >= 0 || POS_V_MIN >= 0)
                fail("position: interact.json has no position sliders at 0xF7000004/8");
            measure_position(gh0, gv0, e0);
            if (e0 != 0) fail("position: csync low inside the picture at 0,0");
            for (int i = 0; i < 2; i++) begin
                set_position(hs[i], vs_[i]);
                check_rgbs();
                measure_position(gh, gv, e);
                $display("position %0d,%0d: csync to picture %0d clocks (%0d at 0), %0d lines (%0d at 0), csync low for %0d clocks of picture",
                         hs[i], vs_[i], gh, gh0, gv, gv0, e);
                if (gh - gh0 != hs[i] * APD) fail("position: the picture did not move by the dots asked");
                if (gv - gv0 != vs_[i]) fail("position: the picture did not move by the lines asked");
                if (e != 0) fail("position: a sync moved into the picture");
                if (gh - (HS1 - HS0) * APD < CB_END) begin
                    $display("  %0d clocks from hsync's end to the picture, the colour burst needs %0d",
                             gh - (HS1 - HS0) * APD, CB_END);
                    // a board whose own timing already puts the burst on the
                    // picture (Y/C only) is noted, not failed
                    if (gh0 - (HS1 - HS0) * APD >= CB_END)
                        fail("position: the picture starts inside the Y/C colour burst");
                    else $display("  note: the board's own timing already does (%0d clocks at 0); Y/C only",
                                  gh0 - (HS1 - HS0) * APD);
                end
                write_settings(settings(1'b1, 5'h00, 4'd0, 4'h5, 1'b0));
                check_svga();
                write_settings(settings(1'b1, 5'h00, 4'd0, 4'h0, 1'b0));
            end
            check_jump(1'b1, POS_V_MAX, (POS_V_MAX - (VS1 - VS0) - 1 < POS_V_MIN) ? POS_V_MIN
                                        : POS_V_MAX - (VS1 - VS0) - 1);
            check_jump(1'b0, POS_H_MAX, (POS_H_MAX - (HS1 - HS0) - 1 < POS_H_MIN) ? POS_H_MIN
                                        : POS_H_MAX - (HS1 - HS0) - 1);
            // and a large step down to 0, which hands the sync back to the
            // source's: one sync's width plus one past it, where the range has it
            check_jump(1'b1, (VS1 - VS0 + 1 <= POS_V_MAX) ? VS1 - VS0 + 1 : POS_V_MAX, 0);
            check_jump(1'b0, (HS1 - HS0 + 1 <= POS_H_MAX) ? HS1 - HS0 + 1 : POS_H_MAX, 0);
            set_position(0, 0);
            measure_position(gh, gv, e);
            if (gh != gh0 || gv != gv0) fail("position: 0,0 is not where it started");
        end

        // the width slider: each end of the menu's range (a default range
        // where the menu has no width entry, to keep the stage proven), with
        // the picture centred between the syncs by H Position as a player
        // would; then at the worst corners, where it may be cropped but must
        // never reach a sync or the colour burst
        begin
            int gh0, gv0, e0, gh, gv, e, dh_c, front, back;
            int ps[2] = '{(SIZE_MAX > 0) ? SIZE_MAX : 10, (SIZE_MIN < 0) ? SIZE_MIN : -10};
            int cs[2] = '{POS_H_MAX, POS_H_MIN};
            if (SIZE_MAX == 0) $display("width: no width slider in interact.json; trying +-10%%");
            front = ((HS0 - X1 - 1) % HTOTAL + HTOTAL) % HTOTAL;
            back  = ((X0 - HS1) % HTOTAL + HTOTAL) % HTOTAL - (CB_END + APD - 1) / APD;
            dh_c  = (front - back) / 2;
            dh_c  = (dh_c < POS_H_MIN) ? POS_H_MIN : (dh_c > POS_H_MAX) ? POS_H_MAX : dh_c;
            $display("width: %0d dots before hsync, %0d clear after it; centred at H Position %0d", front, back, dh_c);
            set_position(dh_c, 0);
            measure_position(gh0, gv0, e0);
            for (int i = 0; i < 2; i++) begin
                set_size(ps[i]);
                check_width(ps[i], gh0);
                measure_position(gh, gv, e);
                $display("width %0d%%: %0d lines from vsync to the picture (%0d at 0), csync low for %0d clocks of picture",
                         ps[i], gv, gv0, e);
                if (gv != gv0) fail("width: the picture moved vertically");
                if (e != 0) fail("width: the picture reaches a sync");
                write_settings(settings(1'b1, 5'h00, 4'd0, 4'h5, 1'b0));
                check_svga();                        // a scandoubler mode: untouched
                write_settings(settings(1'b1, 5'h00, 4'd0, 4'h0, 1'b0));
            end
            set_size(0);
            measure_position(gh, gv, e);
            if (gh != gh0 || gv != gv0) fail("width: 0 is not where it started");
            for (int i = 0; i < 2; i++) begin
                set_position(cs[i], 0);
                set_size(ps[0]);
                measure_position(gh, gv, e);
                $display("width %0d%% at H Position %0d: csync low for %0d clocks of picture, %0d clocks from hsync's end to the picture (burst %0d)",
                         ps[0], cs[i], e, gh - (HS1 - HS0) * APD, CB_END);
                if (e != 0) fail("width: the picture reaches a sync at a corner");
                if (gh - (HS1 - HS0) * APD < CB_END) fail("width: the picture reaches the colour burst at a corner");
                set_size(0);
            end
            set_position(0, 0);
            check_rgbs();
        end

        write_settings(settings(1'b1, 5'h00, 4'd0, 4'h5, 1'b0));   // SC 0% RGBHV
        check_svga();
        write_settings(settings(1'b1, 5'h00, 4'd0, 4'h2, 1'b0));   // YPbPr
        check_known("YPbPr");
        write_settings(settings(1'b1, 5'h00, 4'd0, 4'h3, 1'b0));   // Y/C NTSC
        check_known("Y/C NTSC");
        write_settings(settings(1'b1, 5'h00, 4'd0, 4'h4, 1'b0));   // Y/C PAL
        check_known("Y/C PAL");

        write_settings(settings(1'b1, 5'h00, 4'd0, 4'h0, 1'b1));
        if (pocket_off !== 1'b1) fail("blank: pocket_off not set");
        write_settings(settings(1'b0, 5'h00, 4'd0, 4'h0, 1'b1));
        if (pocket_off !== 1'b0) fail("blank: pocket_off set with the Analogizer off");
        repeat (10) @(posedge clk);
        check_idle();
        $display("blank, and off again: checked");

        check_snac();

        if (errors == 0) $display("PASS");
        else $display("FAILED: %0d", errors);
        $finish;
    end
endmodule
