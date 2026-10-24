//------------------------------------------------------------------------------
// The Pocket's memories behind NGVM's bus (docs/core-design.md 3).
//
//   bus 0x0000000  RAM, 32 MB           SDRAM  word 0x0000000
//       0x2000000  ROM, up to 20 MB     SDRAM  word 0x1000000
//       0x3400000  KSEC, 4 MB           SDRAM  word 0x1A00000
//       0x4000000  the drive, 32 MB     CRAM0 then CRAM1, 16 bits a halfword
//
// SDRAM word addresses are bus byte addresses over two, so the bus maps onto
// the chip with no adder.  The loader's three slots (data.json) write the
// same bus addresses: the kernel at 0, SYM.ROM at 0x2000000, the drive at
// 0x4000000, and the game's save, C:, into the top MB of RAM at 0x1F00000
// (NGVM_SAVE_BASE).  A drive image larger than the CRAM's 32 MB still
// arrives whole, at bus 0x4000000 to 0x7FFFFFF: its first 32 MB go to the
// CRAM, the rest is counted into drive_size and dropped, and the kernel
// fetches it from the SD card when the game reads it (ngage_slots.sv).  A
// fetch's bytes come the same way (dl_fetch), into the CRAM, and are not
// counted.
//
// The bus port is ngvm_sys's, crossed into this clock (ngvm_xbus.sv): one
// request at a time, held until m_done.  A line read is one 16-halfword
// SDRAM burst that starts at the word m_addr[4:2] names and wraps, a line
// write the same burst writing, with DQM masking the halfwords and bytes the
// mask leaves out, and a word read a 2-halfword burst.  The drive is
// uncached, so CRAM sees word reads and masked line writes (the D-cache's
// combining buffer): those go a halfword at a time, and a line write skips
// the halfwords with nothing to write.
//
// A line read's words reach m_rdata one at a time, and m_cnt, a Gray count
// of the line words read in since power-on, rises a clock after each, so
// the CPU side can use the line while the rest of it comes (ngvm_xbus.sv).
//
// BC_RDWR is a fill that evicts a dirty line: the line at m_addr is read,
// m_done answers it, and only then is m_wdata written to m_waddr's line,
// while the CPU goes on.  m_free stays low until that write is done, so the
// next request waits for it, and so does the LCD: its copy, which follows a
// D-cache clean, must not read a line that is still on its way out.  If the
// two lines are the same, the write goes first.
//
// The LCD's line fetch shares the burst port.  Neither user can be cut off
// mid-burst, so the two take turns when both are waiting: a burst of the
// LCD's is 32 halfwords at most, and the CPU waits no longer than that.
//------------------------------------------------------------------------------
`default_nettype none

module ngage_mem (
    input  logic         clk,           // 96 MHz
    input  logic         clk_sdram,     // 96 MHz, phase shifted, drives the pin
    input  logic         init,          // hold to (re)initialise the SDRAM
    output logic         ready,

    input  logic         rd_late,       // SDRAM diagnostics, from the Pocket menu
    input  logic         burst_slow,
    input  logic         rd_fast,
    input  logic         wr_fast,
    input  logic         sram_slow,
    input  logic         sram_slow_wr,

    // the slots arriving from the Pocket, a byte at a time at their bus address
    input  logic         dl_we,
    input  logic  [26:0] dl_addr,
    input  logic   [7:0] dl_data,
    input  logic         dl_active,
    input  logic         dl_fetch,      // the bytes are a fetch's: drive_size stays
    output logic         dl_idle,       // no byte is waiting for its memory
    output logic  [31:0] rom_size,      // bytes loaded from 0x2000000 on
    output logic  [31:0] drive_size,    // bytes loaded from 0x4000000 on: the image's size
    output logic  [31:0] save_size,     // bytes loaded from 0x1F00000 on, below the ROM

    // NGVM's bus (ngvm_sys.sv), level request held until the done pulse
    input  logic         m_req,
    input  logic   [1:0] m_cmd,
    input  logic  [26:0] m_addr,
    input  logic  [26:5] m_waddr,       // BC_RDWR: the line to write back
    input  logic  [31:0] m_be,
    input  logic [255:0] m_wdata,
    output logic         m_done,
    output logic [255:0] m_rdata,       // held from m_done to the next request
    output logic         m_free,        // a new request may be taken
    output logic   [3:0] m_cnt,         // Gray: words read in, a clock after each

    // the LCD's line fetch: up to 32 halfwords of SDRAM, held until l_done
    input  logic         l_req,
    input  logic  [25:1] l_addr,
    input  logic   [5:0] l_len,
    output logic         l_wr,          // one halfword: l_data for index l_idx
    output logic   [4:0] l_idx,
    output logic  [15:0] l_data,
    output logic         l_done,

    // the SRAM, for core_top's self-test only
    input  logic         vram_req,  input  logic        vram_we,
    input  logic  [14:0] vram_addr, input  logic [15:0] vram_din,
    input  logic   [1:0] vram_ben,
    output logic         vram_ack,  output logic [15:0] vram_q,

    // SDRAM pins
    inout  wire   [15:0] SDRAM_DQ,
    output logic  [12:0] SDRAM_A,
    output logic         SDRAM_DQML, SDRAM_DQMH,
    output logic   [1:0] SDRAM_BA,
    output logic         SDRAM_nCS, SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS,
    output logic         SDRAM_CKE, SDRAM_CLK,

    // CRAM pins
    output logic [21:16] cram0_a,
    inout  wire   [15:0] cram0_dq,
    output logic         cram0_clk, cram0_adv_n, cram0_cre,
    output logic         cram0_ce0_n, cram0_ce1_n, cram0_oe_n, cram0_we_n,
    output logic         cram0_ub_n, cram0_lb_n,
    output logic [21:16] cram1_a,
    inout  wire   [15:0] cram1_dq,
    output logic         cram1_clk, cram1_adv_n, cram1_cre,
    output logic         cram1_ce0_n, cram1_ce1_n, cram1_oe_n, cram1_we_n,
    output logic         cram1_ub_n, cram1_lb_n,

    // SRAM pins
    output logic  [16:0] sram_a,
    inout  wire   [15:0] sram_dq,
    output logic         sram_oe_n, sram_we_n, sram_ub_n, sram_lb_n
);
    localparam logic [1:0] BC_RDLINE = 2'd0, BC_WRLINE = 2'd1, BC_RDWORD = 2'd2, BC_RDWR = 2'd3;
    localparam logic [26:0] BUS_ROM = 27'h2000000, BUS_DRIVE = 27'h4000000, BUS_SAVE = 27'h1F00000;

    // ------------------------------------------------------------ download
    // A byte at a time, paired into little-endian halfwords: the even byte
    // waits for the odd one.  The loader cannot be told to wait, so the
    // halfwords go into a FIFO deep enough to ride out a refresh, a burst or
    // a row change (METHODOLOGY 5.16), one for each memory.  Each byte is
    // taken once, on the rising edge of the strobe, which the loader holds
    // for several clocks.  An even byte still waiting when the download ends
    // (a file of odd length) is written alone.  A halfword at drive offset
    // 32 MB or more has no place in the CRAM, and is dropped: kept, its
    // address would wrap onto the drive's first sector.
    localparam int DLQ = 64;
    logic        dl_we_d, dl_act_d, lo_v;
    logic  [7:0] lo_b;
    logic [26:1] lo_a;
    wire         nb      = dl_we && !dl_we_d;
    wire         dl_end  = dl_act_d && !dl_active;

    logic        q_push;
    logic [43:0] q_word;                // {be, halfword address [26:1], data}
    always_comb begin
        q_push = 1'b0; q_word = '0;
        if (nb && dl_addr[0])
            begin q_push = 1'b1; q_word = {2'b11, dl_addr[26:1], dl_data, lo_b}; end
        else if (nb && lo_v)            // a new even byte with the last one unpaired
            begin q_push = 1'b1; q_word = {2'b01, lo_a, 8'h00, lo_b}; end
        else if (dl_end && lo_v)
            begin q_push = 1'b1; q_word = {2'b01, lo_a, 8'h00, lo_b}; end
    end

    always_ff @(posedge clk) begin
        dl_we_d <= dl_we; dl_act_d <= dl_active;
        if (nb && !dl_addr[0]) begin lo_v <= 1'b1; lo_b <= dl_data; lo_a <= dl_addr[26:1]; end
        else if (q_push) lo_v <= 1'b0;
        // the sizes: one past the last byte loaded into each region
        if (nb && !dl_fetch) begin
            if (dl_addr >= BUS_DRIVE) drive_size <= {5'd0, dl_addr - BUS_DRIVE} + 32'd1;
            else if (dl_addr >= BUS_ROM) rom_size <= {5'd0, dl_addr - BUS_ROM} + 32'd1;
            else if (dl_addr >= BUS_SAVE) save_size <= {5'd0, dl_addr - BUS_SAVE} + 32'd1;
        end
        if (init) begin lo_v <= 1'b0; rom_size <= '0; drive_size <= '0; save_size <= '0; end
    end
    wire q_cram = q_word[41];           // halfword address 26:1 >= 0x2000000
    wire q_tail = q_word[41] && q_word[40];     // drive offset >= 32 MB: dropped

    // SDRAM side
    logic [43:0] sq [DLQ];
    logic  [6:0] sq_wp, sq_rp;
    wire         sq_empty = sq_wp == sq_rp;
    wire  [43:0] sq_head  = sq[sq_rp[5:0]];
    // CRAM side
    logic [43:0] cq [DLQ];
    logic  [6:0] cq_wp, cq_rp;
    wire         cq_empty = cq_wp == cq_rp;
    wire  [43:0] cq_head  = cq[cq_rp[5:0]];
    logic        sq_pop, cq_pop;
    assign       dl_idle  = sq_empty && cq_empty;
    always_ff @(posedge clk) begin
        if (q_push && !q_cram) begin sq[sq_wp[5:0]] <= q_word; sq_wp <= sq_wp + 7'd1; end
        if (q_push &&  q_cram && !q_tail) begin cq[cq_wp[5:0]] <= q_word; cq_wp <= cq_wp + 7'd1; end
        if (sq_pop) sq_rp <= sq_rp + 7'd1;
        if (cq_pop) cq_rp <= cq_rp + 7'd1;
        if (init) begin sq_wp <= '0; sq_rp <= '0; cq_wp <= '0; cq_rp <= '0; end
    end

    // ---------------------------------------------------- SDRAM random port
    // Client 0 is the download's writes; nothing else needs a single access.
    localparam int NCLI = 1;
    logic [25:1] c_addr  [NCLI];
    logic        c_req   [NCLI];
    logic        c_we    [NCLI];
    logic [15:0] c_wdata [NCLI];
    logic  [1:0] c_be    [NCLI];
    logic        c_ack   [NCLI];
    logic [15:0] rdata;
    assign c_addr[0]  = sq_head[40:16];
    assign c_req[0]   = !sq_empty;
    assign c_we[0]    = 1'b1;
    assign c_wdata[0] = sq_head[15:0];
    assign c_be[0]    = sq_head[43:42];
    assign sq_pop     = !sq_empty && c_ack[0];

    // ------------------------------------------------------ the bus request
    // m_req rises and the request is taken once; m_done ends it, and m_req
    // must fall before the next is taken (ngvm_xbus.sv drops it the clock
    // after m_done).
    logic        m_busy, m_seen;
    wire         m_new  = m_req && !m_busy && !m_seen;
    wire         m_cram = m_addr >= BUS_DRIVE;
    logic        sd_req;                // the CPU's request wants the burst port
    logic        sd_wr;                 // ... for a write: BC_WRLINE, or BC_RDWR's write-back
    logic        sd_two;                // BC_RDWR's second burst is next
    logic        sd_post;               // BC_RDWR answered; its write-back still to go
    logic        c_busy;                // ... or is CRAM's, halfword c_n next
    assign       m_free = !m_busy;

    // --------------------------------------------------------- burst port
    typedef enum logic [1:0] { B_IDLE, B_LCD, B_CPU } bown_t;
    bown_t       bown;
    logic        last_lcd;              // whose turn it was last
    logic        b_wr, b_done, b_we, b_req;
    logic        b_wrap;
    logic  [9:0] b_idx, b_widx, b_len;
    logic [15:0] b_data, b_wdata;
    logic  [1:0] b_be;
    logic [25:1] b_addr;

    wire lcd_want = l_req && !l_done;
    // the CPU's request wants the port from the clock it is taken, sd_wr and
    // sd_two being set at the same edge as bown
    wire sd_want  = sd_req || (m_new && !m_cram);
    always_ff @(posedge clk) begin
        if (init) begin bown <= B_IDLE; last_lcd <= 1'b0; end
        else case (bown)
            B_IDLE: if (lcd_want && !sd_post && (!sd_want || !last_lcd)) begin bown <= B_LCD; last_lcd <= 1'b1; end
                    else if (sd_want) begin bown <= B_CPU; last_lcd <= 1'b0; end
            // B_IDLE's clock, b_req low, is the one the controller wants
            // between bursts
            B_LCD, B_CPU: if (b_done) bown <= B_IDLE;
            default: bown <= B_IDLE;
        endcase
    end

    assign b_req  = bown == B_LCD || bown == B_CPU;
    assign b_we   = bown == B_CPU && sd_wr;
    assign b_addr = bown == B_LCD ? l_addr : sd_wr && m_cmd == BC_RDWR ? {m_waddr[25:5], 4'd0} : m_addr[25:1];
    assign b_len  = bown == B_LCD ? 10'(l_len) : m_cmd == BC_RDWORD ? 10'd2 : 10'd16;
    assign b_wrap = bown == B_CPU && !sd_wr && m_cmd != BC_RDWORD;

    // a write burst's halfword b_widx, in the clock the controller asks for it
    // (sdram_ctrl.sv: a WRITE a clock with wr_fast); m_wdata holds until m_done
    assign b_wdata = m_wdata[16*int'(b_widx[3:0]) +: 16];
    assign b_be    = m_be[2*int'(b_widx[3:0]) +: 2];

    assign l_wr   = b_wr && bown == B_LCD;
    assign l_idx  = b_idx[4:0];
    assign l_data = b_data;
    assign l_done = b_done && bown == B_LCD;

    // ------------------------------------------------------------- CRAM
    logic        cr_take, cr_ack, cr_dl, c_pend;
    logic [15:0] cr_q;
    logic  [3:0] c_n;
    wire         c_word = m_cmd == BC_RDWORD;
    wire   [3:0] c_last = c_word ? 4'd1 : 4'd15;
    wire   [1:0] c_bee  = m_be[2*int'(c_n) +: 2];
    // a line write's halfword with no byte to write is passed over
    wire         c_skip = m_cmd == BC_WRLINE && c_bee == 2'b00;
    // drive halfword h: h[23] the chip, h[22] its half (cram_ctrl.sv)
    wire  [23:0] c_ha   = c_word ? {m_addr[24:2], c_n[0]} : {m_addr[24:5], c_n};

    // The download's halfwords first, then the CPU's, one at a time.  The
    // CPU is held in reset through the load; a fetch's halfwords come while
    // it runs, and its accesses wait between them.  The download's are taken
    // back to back, straight from the FIFO, so the CRAM keeps ahead of the
    // loader (cram_ctrl.sv).
    wire         cr_dlreq  = !cq_empty;
    wire         cr_cpureq = c_busy && !c_pend && !c_skip;
    wire         cr_req    = cr_dlreq || cr_cpureq;
    wire         cr_we     = cr_dlreq || m_cmd == BC_WRLINE;
    wire  [23:0] cr_addr   = cr_dlreq ? cq_head[39:16] : c_ha;
    wire  [15:0] cr_wdata  = cr_dlreq ? cq_head[15:0]  : m_wdata[16*int'(c_n) +: 16];
    wire   [1:0] cr_be     = cr_dlreq ? cq_head[43:42] : c_bee;
    assign       cq_pop    = cr_take && cr_dlreq;

    // ------------------------------------------------------------- sequencing
    logic  [3:0] m_wn;                  // m_cnt in binary; never reset, like the
                                        // CPU side's copy (ngvm_xbus.sv)
    always_ff @(posedge clk) begin
        m_done <= 1'b0;
        if (!m_req) m_seen <= 1'b0;
        if (m_new) begin
            m_busy <= 1'b1;
            if (m_cram) begin c_busy <= 1'b1; c_n <= 4'd0; end
            else begin
                sd_req <= 1'b1;
                sd_wr  <= m_cmd == BC_WRLINE || (m_cmd == BC_RDWR && m_waddr == m_addr[26:5]);
                sd_two <= m_cmd == BC_RDWR;
            end
        end

        // SDRAM: the burst brings each halfword in (or takes it out); the
        // second of a line's word counts it
        if (bown == B_CPU && b_wr) m_rdata[16*int'(b_idx[3:0]) +: 16] <= b_data;
        if (bown == B_CPU && b_wr && b_idx[0] && m_cmd != BC_RDWORD) m_wn <= m_wn + 4'd1;
        m_cnt <= m_wn ^ (m_wn >> 1);
        if (bown == B_CPU && b_done) begin
            if (sd_two) begin
                // BC_RDWR's first burst: the other goes next; a read is answered now
                sd_two <= 1'b0; sd_wr <= !sd_wr;
                if (!sd_wr) begin sd_post <= 1'b1; m_seen <= 1'b1; m_done <= 1'b1; end
            end else begin
                sd_req <= 1'b0; m_busy <= 1'b0; sd_post <= 1'b0;
                if (!sd_post) begin m_seen <= 1'b1; m_done <= 1'b1; end
            end
        end

        // CRAM: whose access is in flight, and the CPU's halfwords as each
        // is done or passed over
        if (cr_take) begin cr_dl <= cr_dlreq; if (!cr_dlreq) c_pend <= 1'b1; end
        if (c_busy && ((c_pend && cr_ack && !cr_dl) || (!c_pend && c_skip))) begin
            if (c_pend) m_rdata[16*int'(c_n) +: 16] <= cr_q;
            c_pend <= 1'b0;
            c_n <= c_n + 4'd1;
            if (c_n == c_last) begin
                c_busy <= 1'b0; m_busy <= 1'b0; m_seen <= 1'b1; m_done <= 1'b1;
            end
        end

        if (init) begin
            m_busy <= 1'b0; m_seen <= 1'b0; sd_req <= 1'b0; c_busy <= 1'b0; c_pend <= 1'b0;
            sd_two <= 1'b0; sd_post <= 1'b0;
        end
    end

    // ------------------------------------------------------------- SDRAM
    sdram_ctrl #(.NCLI(NCLI)) u_sdram (
        .clk(clk), .clk_pin(clk_sdram), .init(init),
        .rd_late(rd_late), .burst_slow(burst_slow), .rd_fast(rd_fast), .wr_fast(wr_fast), .ready(ready),
        .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A),
        .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH), .SDRAM_BA(SDRAM_BA),
        .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE),
        .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS),
        .SDRAM_CKE(SDRAM_CKE), .SDRAM_CLK(SDRAM_CLK),
        .c_addr(c_addr), .c_req(c_req), .c_we(c_we), .c_wdata(c_wdata),
        .c_be(c_be), .c_ack(c_ack), .rdata(rdata),
        .b_addr(b_addr), .b_len(b_len),
        .b_req(b_req), .b_wrap(b_wrap), .b_abort(1'b0),
        .b_wr(b_wr), .b_idx(b_idx), .b_data(b_data), .b_done(b_done),
        .b_we(b_we), .b_wdata(b_wdata), .b_be(b_be), .b_widx(b_widx)
    );

    // ------------------------------------------------------------- CRAM
    cram_ctrl u_cram (
        .clk(clk), .rst(init),
        .req(cr_req), .we(cr_we), .addr(cr_addr), .wdata(cr_wdata), .be(cr_be),
        .take(cr_take), .ack(cr_ack), .q(cr_q),
        .cram0_a(cram0_a), .cram0_dq(cram0_dq), .cram0_clk(cram0_clk),
        .cram0_adv_n(cram0_adv_n), .cram0_cre(cram0_cre),
        .cram0_ce0_n(cram0_ce0_n), .cram0_ce1_n(cram0_ce1_n),
        .cram0_oe_n(cram0_oe_n), .cram0_we_n(cram0_we_n),
        .cram0_ub_n(cram0_ub_n), .cram0_lb_n(cram0_lb_n),
        .cram1_a(cram1_a), .cram1_dq(cram1_dq), .cram1_clk(cram1_clk),
        .cram1_adv_n(cram1_adv_n), .cram1_cre(cram1_cre),
        .cram1_ce0_n(cram1_ce0_n), .cram1_ce1_n(cram1_ce1_n),
        .cram1_oe_n(cram1_oe_n), .cram1_we_n(cram1_we_n),
        .cram1_ub_n(cram1_ub_n), .cram1_lb_n(cram1_lb_n)
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

    wire _unused = &{1'b0, rdata, b_widx[9:4], b_idx[9:5], m_addr[26], 1'b0};
endmodule

`default_nettype wire
