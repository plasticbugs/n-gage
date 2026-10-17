//------------------------------------------------------------------------------
// The Pocket's memories behind the core's ports (docs/core-design.md section 2).
//
//   SDRAM   68000 program   512 KB   word 0x000000   single words, cached
//           Z80 program      64 KB   word 0x040000   single words, cached
//           graphics          1 MB   word 0x080000   single words for the line
//                                                    renderer, 64-word bursts
//                                                    for the sprite engine
//   SRAM    tilemap VRAM     64 KB   word 0x00000    single words, byte enables
//
// The image arrives from the Pocket as a stream of bytes in the order
// mycore.mra builds it, and is written into SDRAM a word at a time through
// the same controller the core reads it back through.
//
// The graphics ports are 32 bits wide where the SDRAM is 16, so each 32-bit
// word is two SDRAM words: the line renderer's port reads them one after the
// other, and the sprite engine's burst of 32 is a 64-word SDRAM burst.
//------------------------------------------------------------------------------
`default_nettype none

module mycore_mem (
    input  logic        clk,            // 96 MHz
    input  logic        clk_sdram,      // 96 MHz, phase shifted, drives the pin
    input  logic        init,           // hold to (re)initialise the SDRAM
    output logic        ready,

    input  logic        rd_late,        // SDRAM diagnostics, from the Pocket menu
    input  logic        burst_slow,
    input  logic        sram_slow,
    input  logic        sram_slow_wr,

    // the ROM image arriving from the Pocket
    input  logic        dl_we,
    input  logic [24:0] dl_addr,
    input  logic  [7:0] dl_data,
    input  logic        dl_active,

    // core ports
    input  logic        mrom_req,  input  logic [18:1] mrom_addr,
    output logic        mrom_ack,  output logic [15:0] mrom_q,

    input  logic        srom_req,  input  logic [15:0] srom_addr,
    output logic        srom_ack,  output logic  [7:0] srom_q,

    input  logic        gfxl_req,  input  logic [17:0] gfxl_addr,
    output logic        gfxl_ack,  output logic [31:0] gfxl_q,

    input  logic        gfxs_req,  input  logic [17:0] gfxs_addr,
    output logic        gfxs_ack,  output logic [31:0] gfxs_q,

    input  logic        vram_req,  input  logic        vram_we,
    input  logic [14:0] vram_addr, input  logic [15:0] vram_din,
    input  logic  [1:0] vram_ben,
    output logic        vram_ack,  output logic [15:0] vram_q,

    // SDRAM pins
    inout  wire  [15:0] SDRAM_DQ,
    output logic [12:0] SDRAM_A,
    output logic        SDRAM_DQML, SDRAM_DQMH,
    output logic  [1:0] SDRAM_BA,
    output logic        SDRAM_nCS, SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS,
    output logic        SDRAM_CKE, SDRAM_CLK,

    // SRAM pins
    output logic [16:0] sram_a,
    inout  wire  [15:0] sram_dq,
    output logic        sram_oe_n, sram_we_n, sram_ub_n, sram_lb_n
);
    // Where each region starts, as an SDRAM word address.  The bases are
    // powers of two and every region fits inside its own, so the offsets go
    // in with an OR and cost no adder.
    localparam logic [24:1] PROG_W = 24'h000000;
    localparam logic [24:1] SND_W  = 24'h040000;
    localparam logic [24:1] GFX_W  = 24'h080000;
    // and where each starts in the image, as a byte offset
    localparam logic [24:0] SND_B  = 25'h080000;
    localparam logic [24:0] GFX_B  = 25'h090000;

    // ------------------------------------------------------------ download
    // A byte at a time from the Pocket, paired into a 16-bit word because the
    // image is big-endian throughout.  The loader cannot be told to wait --
    // it sends a byte every eight clocks whatever the SDRAM is doing -- so
    // the words go into a FIFO deep enough to ride out a refresh or a row
    // change.  Nothing here may ever drop or alter a word.
    //
    // This was a single pending word, and it was wrong the way Cadash's was
    // before it: the even byte of the next word landed in the pending word's
    // high half while that word was still waiting for its write, so what
    // finally went out was this word's low byte under the next word's high
    // one.  The first words of every region read back right, which is what
    // the panel showed, and the image behind them was peppered with bad
    // words; the 68000 reached one within a few frames, took an address
    // error and never came back -- a black screen on the first hardware run.
    // The ideal-memory bench cannot see it.  sim/run_pocket.sh, at the
    // loader's rate, can: it crashed the same way before this and boots now.
    // Each byte is also taken once, on the rising edge of the strobe, which
    // the Pocket holds for several clocks.
    localparam int DLQ = 64;
    logic [39:0] dlq [DLQ];             // {word address [24:1], data [15:0]}
    logic  [6:0] dlq_wp, dlq_rp;
    logic  [7:0] dl_hi;
    logic        dl_we_d;
    wire         dlq_empty = (dlq_wp == dlq_rp);
    wire  [39:0] dlq_head  = dlq[dlq_rp[5:0]];
    wire         nb        = dl_we && !dl_we_d;   // one byte, once

    wire [24:1] dl_target = (dl_addr >= GFX_B) ? (GFX_W | 24'((dl_addr - GFX_B) >> 1))
                          : (dl_addr >= SND_B) ? (SND_W | 24'((dl_addr - SND_B) >> 1))
                                               : (PROG_W | 24'(dl_addr >> 1));

    always_ff @(posedge clk) begin
        dl_we_d <= dl_we;
        if (init) begin
            dlq_wp <= '0;
            dlq_rp <= '0;
        end else begin
            if (nb) begin
                if (!dl_addr[0]) dl_hi <= dl_data;
                else begin
                    dlq[dlq_wp[5:0]] <= {dl_target, dl_hi, dl_data};
                    dlq_wp <= dlq_wp + 7'd1;
                end
            end
            if (!dlq_empty && dl_ack) dlq_rp <= dlq_rp + 7'd1;
        end
    end

    // ---------------------------------------------------- SDRAM clients
    // 0 download (writes), 1 graphics for the line renderer, 2 the 68000,
    // 3 the Z80.  Fixed priority, first listed first: the download only runs
    // while the core is held in reset, and the line renderer has the tightest
    // deadline of the three that run.
    localparam int NCLI = 4;
    logic [24:1] c_addr  [NCLI];
    logic        c_req   [NCLI];
    logic        c_we    [NCLI];
    logic [15:0] c_wdata [NCLI];
    logic  [1:0] c_be    [NCLI];
    logic        c_ack   [NCLI];
    logic [15:0] rdata;

    wire dl_ack = c_ack[0];
    assign c_addr[0]  = dlq_head[39:16];
    assign c_req[0]   = !dlq_empty;
    assign c_we[0]    = 1'b1;
    assign c_wdata[0] = dlq_head[15:0];
    assign c_be[0]    = 2'b11;

    // Client 1 was the line renderer, reading each 32-bit image word as two
    // single accesses.  A single access is nine clocks of activate, read and
    // precharge, so a word cost twenty and a line of three layers' worth ran
    // to 5,700 of its 6,328 clocks in the real-memory bench -- and past them
    // on the panel, where the first hardware picture came out with every
    // other raster line stale beyond the point the renderer had reached.  The
    // word now comes as one two-word burst (below), and this client is idle.
    assign c_addr[1]  = '0;
    assign c_req[1]   = 1'b0;
    assign c_we[1]    = 1'b0;
    assign c_wdata[1] = 16'd0;
    assign c_be[1]    = 2'b11;

    assign c_addr[2]  = PROG_W | {6'd0, mrom_addr};
    assign c_req[2]   = mrom_req && !mrom_ack;
    assign c_we[2]    = 1'b0;
    assign c_wdata[2] = 16'd0;
    assign c_be[2]    = 2'b11;
    always_ff @(posedge clk) begin
        mrom_ack <= c_ack[2];
        if (c_ack[2]) mrom_q <= rdata;
    end

    // the Z80 reads bytes; the SDRAM holds them two to a word, high byte first
    assign c_addr[3]  = SND_W | {9'd0, srom_addr[15:1]};
    assign c_req[3]   = srom_req && !srom_ack;
    assign c_we[3]    = 1'b0;
    assign c_wdata[3] = 16'd0;
    assign c_be[3]    = 2'b11;
    logic srom_lo;
    always_ff @(posedge clk) begin
        srom_ack <= c_ack[3];
        if (c_req[3]) srom_lo <= srom_addr[0];
        if (c_ack[3]) srom_q <= srom_lo ? rdata[7:0] : rdata[15:8];
    end

    // ------------------------------------------------------ the burst port
    // Two users, never busy together by design -- the sprite engine paints in
    // vblank, the line renderer draws the visible lines -- but arbitrated all
    // the same: the sprite engine's 64-word tile (32 image words) goes first
    // if both ask, and whoever has the port keeps it to the end of the burst.
    // The controller wants b_req low for a clock between bursts (B_GAP).
    typedef enum logic [1:0] { B_IDLE, B_SPR, B_LINE, B_GAP } bown_t;
    bown_t       bown;
    logic [15:0] gs_hi, gl_hi;
    logic        b_wr, b_done;
    logic  [9:0] b_idx;
    logic [15:0] b_data;

    wire line_want = gfxl_req && !gfxl_ack;

    always_ff @(posedge clk) begin
        if (init) bown <= B_IDLE;
        else case (bown)
            B_IDLE: if (gfxs_req) bown <= B_SPR; else if (line_want) bown <= B_LINE;
            B_SPR:  if (!gfxs_req) bown <= B_GAP;
            B_LINE: if (b_done)    bown <= B_GAP;
            default:               bown <= B_IDLE;
        endcase
    end

    wire        b_req_m  = (bown == B_SPR) ? gfxs_req : (bown == B_LINE);
    wire [24:1] b_addr_m = GFX_W | {5'd0, ((bown == B_LINE) ? gfxl_addr : gfxs_addr), 1'b0};
    wire  [9:0] b_len_m  = (bown == B_LINE) ? 10'd2 : 10'd64;

    always_ff @(posedge clk) begin
        gfxs_ack <= 1'b0;
        gfxl_ack <= 1'b0;
        if (b_wr && bown == B_SPR) begin
            if (!b_idx[0]) gs_hi <= b_data;
            else begin gfxs_q <= {gs_hi, b_data}; gfxs_ack <= 1'b1; end
        end
        if (b_wr && bown == B_LINE) begin
            if (!b_idx[0]) gl_hi <= b_data;
            else begin gfxl_q <= {gl_hi, b_data}; gfxl_ack <= 1'b1; end
        end
    end

    // ------------------------------------------------------------- SDRAM
    sdram_ctrl #(.NCLI(NCLI)) u_sdram (
        .clk(clk), .clk_pin(clk_sdram), .init(init),
        .rd_late(rd_late), .burst_slow(burst_slow), .ready(ready),
        .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A),
        .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH), .SDRAM_BA(SDRAM_BA),
        .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE),
        .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS),
        .SDRAM_CKE(SDRAM_CKE), .SDRAM_CLK(SDRAM_CLK),
        .c_addr(c_addr), .c_req(c_req), .c_we(c_we), .c_wdata(c_wdata),
        .c_be(c_be), .c_ack(c_ack), .rdata(rdata),
        .b_addr(b_addr_m), .b_len(b_len_m),
        .b_req(b_req_m), .b_abort(1'b0),
        .b_wr(b_wr), .b_idx(b_idx), .b_data(b_data), .b_done(b_done),
        .b_we(1'b0), .b_wdata(16'd0), .b_be(2'b00), .b_widx()
    );

    // -------------------------------------------------------------- SRAM
    sram_port u_sram (
        .clk(clk), .reset(init), .slow(sram_slow), .slow_wr(sram_slow_wr),
        .req(vram_req && !dl_active), .we(vram_we), .addr({1'b0, vram_addr}),
        .be(vram_ben), .wdata(vram_din), .ack(vram_ack), .q(vram_q),
        .sram_a(sram_a), .sram_dq(sram_dq),
        .sram_oe_n(sram_oe_n), .sram_we_n(sram_we_n),
        .sram_ub_n(sram_ub_n), .sram_lb_n(sram_lb_n)
    );

    wire _unused = &{1'b0, c_ack[1], 1'b0};
endmodule

`default_nettype wire
