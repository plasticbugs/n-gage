// Whole-machine bench, through the Pocket's real memory glue: ngage_core
// (NGVM: the CPU side on its own clock, the bus crossing, the LCD) against
// ngage_mem, sdram_ctrl and cram_ctrl, with behavioural chips beyond the
// pins and the three slots sent in through the download port at the APF
// loader's rate.
//
// This is the bench two shipped cores did without, and both paid for it: a
// whole-machine bench that answers the CPUs from plain arrays never exercises
// the memory controller, its arbiter, the refresh, or the download path that
// fills it, and all three faults that blacked out their first hardware runs
// lived there (METHODOLOGY section 5.16).  sim/run_sys.sh, the ideal-memory
// lockstep bench, proves the CPU side; this one is the gate before a flash.
//
// The C++ side is sim/tb_system.cpp.
`default_nettype none

module tb_system_top #(
    parameter int CPU_HZ = 73_846_154
) (
    input  logic        clk,            // 96 MHz
    input  logic        clk_cpu,
    input  logic        reset,

    // the slots, a byte at a time at their bus addresses
    input  logic        dl_we,
    input  logic [26:0] dl_addr,
    input  logic  [7:0] dl_data,
    input  logic        dl_active,

    input  logic [11:0] keys,
    input  logic        rd_fast,        // the menu's "SDRAM fast reads"

    output logic [23:0] rgb,
    output logic        de, pix_ce, vblank, hsync, vsync,
    output logic [31:0] snd,
    output logic        snd_tog,
    output logic        mem_ready,
    output logic [31:0] rom_size, drive_size,

    // the kernel's debug port, in clk_cpu's domain
    output logic        putc,
    output logic        dexit,
    output logic  [7:0] pchar,
    output logic [31:0] dbg_pc,

    // for measurement: an instruction retiring (clk_cpu), the LCD copying a frame
    output logic        retired,
    output logic        lcd_busy,
    // and what the CPU side waits on (clk_cpu): an I-cache fill, a D-cache
    // command to the miss handler (MC_*), the bus
    output logic        w_i, w_d, w_bus,
    output logic  [1:0] w_dcmd,
    output logic [15:0] a_lvl,          // samples in the audio FIFO
    output logic        w_m             // the bus request, crossed into clk
);
    logic         m_req, m_done;
    logic   [1:0] m_cmd;
    logic  [26:0] m_addr;
    logic  [31:0] m_be;
    logic [255:0] m_wdata, m_rdata;
    logic         l_req, l_wr, l_done;
    logic  [25:1] l_addr;
    logic   [5:0] l_len;
    logic   [4:0] l_idx;
    logic  [15:0] l_data;

    wire [15:0] dram_dq;  wire [12:0] dram_a;  wire [1:0] dram_ba;
    wire        dram_dqml, dram_dqmh, dram_clk, dram_cke;
    wire        dram_cs_n, dram_ras_n, dram_cas_n, dram_we_n;
    wire [16:0] sram_a;   wire [15:0] sram_dq;
    wire        sram_oe_n, sram_we_n, sram_ub_n, sram_lb_n;
    wire [21:16] c0_a, c1_a;  wire [15:0] c0_dq, c1_dq;
    wire        c0_adv_n, c0_ce0_n, c0_ce1_n, c0_oe_n, c0_we_n, c0_ub_n, c0_lb_n;
    wire        c1_adv_n, c1_ce0_n, c1_ce1_n, c1_oe_n, c1_we_n, c1_ub_n, c1_lb_n;

    // The SDRAM's power-up sequence has to finish before the loader's first
    // byte, exactly as it does on the Pocket, so it is counted out from the
    // driver's first reset rather than tied to it.
    logic [7:0] por;
    logic       seen_reset;
    always_ff @(posedge clk) begin
        if (reset && !seen_reset) begin seen_reset <= 1'b1; por <= '0; end
        else if (!(&por)) por <= por + 8'd1;
    end
    wire mem_init = !seen_reset || !(&por);

    ngage_mem u_mem (
        .clk(clk), .clk_sdram(clk), .init(mem_init), .ready(mem_ready),
        .rd_late(1'b1), .burst_slow(1'b0), .rd_fast(rd_fast), .sram_slow(1'b0), .sram_slow_wr(1'b0),
        .dl_we(dl_we), .dl_addr(dl_addr), .dl_data(dl_data), .dl_active(dl_active),
        .rom_size(rom_size), .drive_size(drive_size),
        .m_req(m_req), .m_cmd(m_cmd), .m_addr(m_addr), .m_be(m_be), .m_wdata(m_wdata),
        .m_done(m_done), .m_rdata(m_rdata),
        .l_req(l_req), .l_addr(l_addr), .l_len(l_len),
        .l_wr(l_wr), .l_idx(l_idx), .l_data(l_data), .l_done(l_done),
        .vram_req(1'b0), .vram_we(1'b0), .vram_addr(15'd0), .vram_din(16'd0), .vram_ben(2'b00),
        .vram_ack(), .vram_q(),
        .SDRAM_DQ(dram_dq), .SDRAM_A(dram_a), .SDRAM_BA(dram_ba),
        .SDRAM_DQML(dram_dqml), .SDRAM_DQMH(dram_dqmh),
        .SDRAM_nCS(dram_cs_n), .SDRAM_nWE(dram_we_n),
        .SDRAM_nRAS(dram_ras_n), .SDRAM_nCAS(dram_cas_n),
        .SDRAM_CKE(dram_cke), .SDRAM_CLK(dram_clk),
        .cram0_a(c0_a), .cram0_dq(c0_dq), .cram0_clk(), .cram0_adv_n(c0_adv_n), .cram0_cre(),
        .cram0_ce0_n(c0_ce0_n), .cram0_ce1_n(c0_ce1_n), .cram0_oe_n(c0_oe_n), .cram0_we_n(c0_we_n),
        .cram0_ub_n(c0_ub_n), .cram0_lb_n(c0_lb_n),
        .cram1_a(c1_a), .cram1_dq(c1_dq), .cram1_clk(), .cram1_adv_n(c1_adv_n), .cram1_cre(),
        .cram1_ce0_n(c1_ce0_n), .cram1_ce1_n(c1_ce1_n), .cram1_oe_n(c1_oe_n), .cram1_we_n(c1_we_n),
        .cram1_ub_n(c1_ub_n), .cram1_lb_n(c1_lb_n),
        .sram_a(sram_a), .sram_dq(sram_dq),
        .sram_oe_n(sram_oe_n), .sram_we_n(sram_we_n),
        .sram_ub_n(sram_ub_n), .sram_lb_n(sram_lb_n)
    );

    sdram_model #(.AW(25)) chip (
        .clk(clk), .dq(dram_dq), .a(dram_a), .ba(dram_ba),
        .dqml(dram_dqml), .dqmh(dram_dqmh), .cs_n(dram_cs_n),
        .ras_n(dram_ras_n), .cas_n(dram_cas_n), .we_n(dram_we_n), .cke(dram_cke)
    );
    cram_model cram0 (.clk(clk), .a(c0_a), .dq(c0_dq), .adv_n(c0_adv_n), .ce0_n(c0_ce0_n),
                      .ce1_n(c0_ce1_n), .oe_n(c0_oe_n), .we_n(c0_we_n), .ub_n(c0_ub_n), .lb_n(c0_lb_n));
    cram_model cram1 (.clk(clk), .a(c1_a), .dq(c1_dq), .adv_n(c1_adv_n), .ce0_n(c1_ce0_n),
                      .ce1_n(c1_ce1_n), .oe_n(c1_oe_n), .we_n(c1_we_n), .ub_n(c1_ub_n), .lb_n(c1_lb_n));
    sram_model sram (.clk(clk), .a(sram_a), .dq(sram_dq), .oe_n(sram_oe_n),
                     .we_n(sram_we_n), .ub_n(sram_ub_n), .lb_n(sram_lb_n));

    logic [23:0] rgb_c;
    logic        hblank;
    ngage_core #(.CPU_HZ(CPU_HZ)) u_core (
        .clk(clk), .clk_cpu(clk_cpu), .rst(reset | ~mem_ready), .pause(1'b0), .pix_sync(1'b0),
        .m_req(m_req), .m_cmd(m_cmd), .m_addr(m_addr), .m_be(m_be), .m_wdata(m_wdata),
        .m_done(m_done), .m_rdata(m_rdata),
        .l_req(l_req), .l_addr(l_addr), .l_len(l_len),
        .l_wr(l_wr), .l_idx(l_idx), .l_data(l_data), .l_done(l_done),
        .keys(keys), .rom_size(rom_size), .drive_size(drive_size),
        .rgb(rgb_c), .hsync(hsync), .vsync(vsync), .hblank(hblank), .vblank(vblank),
        .pix_ce(pix_ce), .de(de),
        .snd(snd), .snd_tog(snd_tog),
        .dbg_pc(dbg_pc), .dbg_chars(), .dbg_exited(), .dbg_lcd_on()
    );
    assign rgb   = rgb_c;
    assign putc  = u_core.dbg_putc;
    assign dexit = u_core.dbg_exit;
    assign pchar = u_core.dbg_data[7:0];
    assign retired  = u_core.rt_valid;
    assign lcd_busy = u_core.u_lcd.c_go;
    assign w_i    = u_core.u_sys.i_req;
    assign w_d    = u_core.u_sys.d_req;
    assign w_dcmd = u_core.u_sys.d_cmd;
    assign w_bus  = u_core.u_sys.bus_req;
    assign a_lvl  = 16'(u_core.u_sys.u_io.a_lvl);
    assign w_m    = m_req;
endmodule

`default_nettype wire
