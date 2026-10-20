// Bench wrapper for target/pocket/ngage_mem.sv: the Pocket memory subsystem
// with behavioural chips behind the pins.  sim/tb_mem.cpp pushes an image in
// through the download port at the APF loader's rate and reads every region
// back through NGVM's bus port, while an LCD agent fetches lines through the
// burst port it shares.
//
// This is the gate two cores shipped without (METHODOLOGY section 5.16): a
// whole-machine bench that answers the CPUs from arrays never exercises the
// controller, the arbiter, or the download path that fills it.
`default_nettype none
module tb_mem_top (
    input  logic         clk,
    input  logic         init,
    output logic         ready,
    input  logic         rd_late, burst_slow, rd_fast,
    input  logic         dl_we, input logic [26:0] dl_addr, input logic [7:0] dl_data,
    input  logic         dl_active,
    output logic  [31:0] rom_size, drive_size,
    input  logic         m_req,
    input  logic   [1:0] m_cmd,
    input  logic  [26:0] m_addr,
    input  logic  [31:0] m_be,
    input  logic [255:0] m_wdata,
    output logic         m_done,
    output logic [255:0] m_rdata,
    input  logic         l_req,
    input  logic  [25:1] l_addr,
    input  logic   [5:0] l_len,
    output logic         l_wr,
    output logic   [4:0] l_idx,
    output logic  [15:0] l_data,
    output logic         l_done,
    input  logic         vram_req, input  logic        vram_we,
    input  logic  [14:0] vram_addr, input logic [15:0] vram_din,
    input  logic   [1:0] vram_ben,
    output logic         vram_ack, output logic [15:0] vram_q,
    output logic  [31:0] errors         // the chip models' protocol errors
);
    wire [15:0] SDRAM_DQ; wire [12:0] SDRAM_A; wire [1:0] SDRAM_BA;
    wire        SDRAM_DQML, SDRAM_DQMH, SDRAM_nCS, SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS;
    wire        SDRAM_CKE, SDRAM_CLK;
    wire [16:0] sram_a; wire [15:0] sram_dq;
    wire        sram_oe_n, sram_we_n, sram_ub_n, sram_lb_n;
    wire [21:16] c0_a, c1_a;  wire [15:0] c0_dq, c1_dq;
    wire        c0_adv_n, c0_ce0_n, c0_ce1_n, c0_oe_n, c0_we_n, c0_ub_n, c0_lb_n;
    wire        c1_adv_n, c1_ce0_n, c1_ce1_n, c1_oe_n, c1_we_n, c1_ub_n, c1_lb_n;

    ngage_mem dut (
        .clk(clk), .clk_sdram(clk), .init(init), .ready(ready),
        .rd_late(rd_late), .burst_slow(burst_slow), .rd_fast(rd_fast), .sram_slow(1'b0), .sram_slow_wr(1'b0),
        .dl_we(dl_we), .dl_addr(dl_addr), .dl_data(dl_data), .dl_active(dl_active),
        .rom_size(rom_size), .drive_size(drive_size),
        .m_req(m_req), .m_cmd(m_cmd), .m_addr(m_addr), .m_be(m_be), .m_wdata(m_wdata),
        .m_done(m_done), .m_rdata(m_rdata),
        .l_req(l_req), .l_addr(l_addr), .l_len(l_len),
        .l_wr(l_wr), .l_idx(l_idx), .l_data(l_data), .l_done(l_done),
        .vram_req(vram_req), .vram_we(vram_we), .vram_addr(vram_addr),
        .vram_din(vram_din), .vram_ben(vram_ben), .vram_ack(vram_ack), .vram_q(vram_q),
        .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA),
        .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
        .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS),
        .SDRAM_CKE(SDRAM_CKE), .SDRAM_CLK(SDRAM_CLK),
        .cram0_a(c0_a), .cram0_dq(c0_dq), .cram0_clk(), .cram0_adv_n(c0_adv_n), .cram0_cre(),
        .cram0_ce0_n(c0_ce0_n), .cram0_ce1_n(c0_ce1_n), .cram0_oe_n(c0_oe_n), .cram0_we_n(c0_we_n),
        .cram0_ub_n(c0_ub_n), .cram0_lb_n(c0_lb_n),
        .cram1_a(c1_a), .cram1_dq(c1_dq), .cram1_clk(), .cram1_adv_n(c1_adv_n), .cram1_cre(),
        .cram1_ce0_n(c1_ce0_n), .cram1_ce1_n(c1_ce1_n), .cram1_oe_n(c1_oe_n), .cram1_we_n(c1_we_n),
        .cram1_ub_n(c1_ub_n), .cram1_lb_n(c1_lb_n),
        .sram_a(sram_a), .sram_dq(sram_dq),
        .sram_oe_n(sram_oe_n), .sram_we_n(sram_we_n), .sram_ub_n(sram_ub_n), .sram_lb_n(sram_lb_n)
    );

    sdram_model #(.AW(25)) chip (
        .clk(clk), .dq(SDRAM_DQ), .a(SDRAM_A), .ba(SDRAM_BA),
        .dqml(SDRAM_DQML), .dqmh(SDRAM_DQMH), .cs_n(SDRAM_nCS),
        .ras_n(SDRAM_nRAS), .cas_n(SDRAM_nCAS), .we_n(SDRAM_nWE), .cke(SDRAM_CKE)
    );
    cram_model cram0 (.clk(clk), .a(c0_a), .dq(c0_dq), .adv_n(c0_adv_n), .ce0_n(c0_ce0_n),
                      .ce1_n(c0_ce1_n), .oe_n(c0_oe_n), .we_n(c0_we_n), .ub_n(c0_ub_n), .lb_n(c0_lb_n));
    cram_model cram1 (.clk(clk), .a(c1_a), .dq(c1_dq), .adv_n(c1_adv_n), .ce0_n(c1_ce0_n),
                      .ce1_n(c1_ce1_n), .oe_n(c1_oe_n), .we_n(c1_we_n), .ub_n(c1_ub_n), .lb_n(c1_lb_n));
    sram_model sram (.clk(clk), .a(sram_a), .dq(sram_dq), .oe_n(sram_oe_n), .we_n(sram_we_n),
                     .ub_n(sram_ub_n), .lb_n(sram_lb_n));
    assign errors = 32'(chip.errors) + 32'(cram0.errors) + 32'(cram1.errors);
    /* verilator lint_off UNUSEDSIGNAL */
    wire unused = ^{SDRAM_CLK};
    /* verilator lint_on UNUSEDSIGNAL */
endmodule
`default_nettype wire
