//------------------------------------------------------------------------------
// My Core -- the machine, platform-agnostic.
//
// THIS IS THE SKELETON.  It is a whole, working core that contains no game: a
// raster, a test pattern, a cursor on the d-pad, a beep on button 1, and one
// read from each ROM region so the bring-up panel has something to show.  It
// exists so that the first thing a new core does on a Pocket is work -- the
// PLL, the SDRAM, the SRAM, the download, the video hand-over, the controls
// and the audio path are all proven before there is a CPU to blame.
//
// Replace the inside; keep the outside.  The port list is the contract with
// target/pocket/core_top.sv and with the benches in sim/, and it is shaped
// the way these boards usually are: a 16-bit program ROM, a byte-wide sound
// ROM, graphics read a word at a time by a line renderer and a tile at a time
// by a sprite engine, and a tilemap RAM in the Pocket's SRAM.  Drop what the
// board does not have; add nothing the platform side does not already carry
// without reading docs/core-design.md first.
//------------------------------------------------------------------------------
`default_nettype none

module mycore_core (
    input  logic        clk,            // 96 MHz
    input  logic        rst,
    input  logic        pause,          // freeze the CPUs and sound, keep the picture
    input  logic        pix_sync,       // see clk_enables.sv

    // ---------------- memory, all through target/pocket/mycore_mem.sv
    output logic        mrom_req,  output logic [18:1] mrom_addr,
    input  logic        mrom_ack,  input  logic [15:0] mrom_q,
    output logic        srom_req,  output logic [15:0] srom_addr,
    input  logic        srom_ack,  input  logic  [7:0] srom_q,
    output logic        gfxl_req,  output logic [17:0] gfxl_addr,
    input  logic        gfxl_ack,  input  logic [31:0] gfxl_q,
    output logic        gfxs_req,  output logic [17:0] gfxs_addr,
    input  logic        gfxs_ack,  input  logic [31:0] gfxs_q,
    output logic        vram_req,  output logic        vram_we,
    output logic [14:0] vram_addr, output logic [15:0] vram_din,
    output logic  [1:0] vram_ben,
    input  logic        vram_ack,  input  logic [15:0] vram_q,

    // ---------------- inputs, active low as arcade boards read them
    input  logic  [7:0] dswa, dswb,
    input  logic  [7:0] in0, in1, in2,  // bit 0 up, 1 down, 2 left, 3 right, 4 b1, 5 b2

    // ---------------- video, one pixel per pix_ce in the clk domain
    output logic [23:0] rgb,
    output logic        hsync, vsync, hblank, vblank,
    output logic        pix_ce, de,

    output logic signed [15:0] snd,

    // ---------------- bring-up (rtl/dbg_fault.sv, the panel in core_top)
    output logic        dbg_halted,
    output logic [23:1] dbg_addr,
    output logic        dbg_bus, dbg_wait,
    output logic        watchdog_reset
);
    // ------------------------------------------------------------ clocks
    logic cen_phi1, cen_phi2, cen_z80, cen_ym, cen_pix;
    clk_enables u_cen (
        .clk(clk), .rst(rst), .pause(pause), .pix_sync(pix_sync),
        .cen_phi1(cen_phi1), .cen_phi2(cen_phi2), .cen_z80(cen_z80),
        .cen_ym(cen_ym), .cen_pix(cen_pix)
    );
    assign pix_ce = cen_pix;

    // ------------------------------------------------------------ raster
    // 452 x 253 at 96/14 MHz is 59.96 Hz; 320 x 224 of it is picture.
    localparam int HTOTAL = 452, VTOTAL = 253;
    localparam int W = 320, VIS_Y0 = 16, VIS_Y1 = 239;
    logic [9:0] hpos;
    logic [8:0] vpos;
    always_ff @(posedge clk) begin
        if (rst) begin hpos <= '0; vpos <= '0; end
        else if (cen_pix) begin
            if (hpos == 10'(HTOTAL - 1)) begin
                hpos <= '0;
                vpos <= (vpos == 9'(VTOTAL - 1)) ? 9'd0 : vpos + 9'd1;
            end else hpos <= hpos + 10'd1;
        end
    end
    wire vis_x = (hpos < 10'(W));
    wire vis_y = (vpos >= 9'(VIS_Y0)) && (vpos <= 9'(VIS_Y1));

    // ------------------------------------------------------------ pattern
    // A crosshatch every 16 pixels with colour bars across the middle: a
    // regular pattern turns "the picture is garbled" into coordinates
    // (METHODOLOGY section 5.18).  The cursor proves the controls and their
    // polarity; its colour proves the two buttons.
    logic [8:0] cx, cy;
    logic       vb_d;
    wire        frame_tick = vblank && !vb_d;
    always_ff @(posedge clk) begin
        vb_d <= vblank;
        if (rst) begin cx <= 9'd152; cy <= 9'd104; end
        else if (frame_tick && !pause) begin
            if (!in0[0] && cy != 9'd0)   cy <= cy - 9'd1;
            if (!in0[1] && cy != 9'd208) cy <= cy + 9'd1;
            if (!in0[2] && cx != 9'd0)   cx <= cx - 9'd1;
            if (!in0[3] && cx != 9'd304) cx <= cx + 9'd1;
        end
    end

    wire [8:0] x = hpos[8:0];
    wire [8:0] y = vpos - 9'(VIS_Y0);
    wire grid   = (x[3:0] == 4'd0) || (y[3:0] == 4'd0) || (x == 9'd319) || (y == 9'd223);
    wire in_bar = (y >= 9'd80) && (y < 9'd144) && (x >= 9'd64) && (x < 9'd256);
    wire [1:0] bar = 2'((x - 9'd64) >> 6);      // three 64-pixel bars
    wire bright = (y >= 9'd112);
    wire in_cur = (x >= cx) && (x < cx + 9'd16) && (y >= cy) && (y < cy + 9'd16);

    logic [23:0] px;
    always_comb begin
        px = grid ? 24'hFFFFFF : 24'h000000;
        if (in_bar) begin
            case (bar)
                2'd0:    px = bright ? 24'hFF0000 : 24'h800000;
                2'd1:    px = bright ? 24'h00FF00 : 24'h008000;
                default: px = bright ? 24'h0000FF : 24'h000080;
            endcase
        end
        if (in_cur) px = !in0[4] ? 24'hFFFF00 : !in0[5] ? 24'hFF00FF : 24'h00FFFF;
    end

    always_ff @(posedge clk) begin
        if (cen_pix) begin
            rgb    <= (vis_x && vis_y) ? px : 24'h000000;
            de     <= vis_x && vis_y;
            hblank <= !vis_x;
            hsync  <= (hpos >= 10'd344) && (hpos < 10'd376);
        end
    end
    assign vblank = !vis_y;
    assign vsync  = (vpos >= 9'(VIS_Y1 + 3)) && (vpos < 9'(VIS_Y1 + 6));

    // ------------------------------------------------------------ sound
    // Button 1 beeps, so the audio path is heard before there is a sound
    // board: 96 MHz / 2^17 / 2 is 366 Hz.  Small: it goes straight to the DAC.
    logic [17:0] tone;
    always_ff @(posedge clk) if (!pause) tone <= tone + 18'd1;
    assign snd = in0[4] ? 16'sd0 : (tone[17] ? 16'sd3000 : -16'sd3000);

    // ------------------------------------------------------------ memory
    // One read from each ROM region after reset, so the panel's read-back row
    // shows the first word of each -- which proves the path, not the image;
    // sim/run_mem.sh proves the image.  A real core's CPUs and video engines
    // drive these ports instead.
    typedef enum logic [2:0] { M_PROG, M_SND, M_GFXL, M_IDLE } mst_t;
    mst_t mst;
    always_ff @(posedge clk) begin
        if (rst) begin
            mst <= M_PROG; mrom_req <= 1'b0; srom_req <= 1'b0; gfxl_req <= 1'b0;
        end else case (mst)
            M_PROG: begin mrom_req <= 1'b1; if (mrom_ack) begin mrom_req <= 1'b0; mst <= M_SND;  end end
            M_SND:  begin srom_req <= 1'b1; if (srom_ack) begin srom_req <= 1'b0; mst <= M_GFXL; end end
            M_GFXL: begin gfxl_req <= 1'b1; if (gfxl_ack) begin gfxl_req <= 1'b0; mst <= M_IDLE; end end
            default: ;
        endcase
    end
    assign mrom_addr = '0;
    assign srom_addr = '0;
    assign gfxl_addr = '0;
    assign gfxs_req  = 1'b0;
    assign gfxs_addr = '0;
    assign vram_req  = 1'b0;
    assign vram_we   = 1'b0;
    assign vram_addr = '0;
    assign vram_din  = '0;
    assign vram_ben  = 2'b00;

    // no CPU yet: nothing to halt, nothing on the bus, nothing to watch
    assign dbg_halted     = 1'b0;
    assign dbg_addr       = '0;
    assign dbg_bus        = 1'b0;
    assign dbg_wait       = 1'b0;
    assign watchdog_reset = 1'b0;

    wire _unused = &{1'b0, cen_phi1, cen_phi2, cen_z80, cen_ym, dswa, dswb, in1, in2,
                     mrom_q, srom_q, gfxl_q, gfxs_ack, gfxs_q, vram_ack, vram_q, 1'b0};
endmodule

`default_nettype wire
