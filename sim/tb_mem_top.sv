// Bench wrapper for target/pocket/mycore_mem.sv: the Pocket memory subsystem
// with behavioural chips behind the pins.  sim/tb_mem.cpp pushes an image in
// through the download port at the APF loader's rate and reads every region
// back through the core's ports.
//
// This is the gate two cores shipped without (METHODOLOGY section 5.16): a
// whole-machine bench that answers the CPUs from arrays never exercises the
// controller, the arbiter, or the download path that fills it.
`default_nettype none
module tb_mem_top (
    input  logic        clk,
    input  logic        init,
    output logic        ready,
    input  logic        rd_late, burst_slow,
    input  logic        dl_we, input logic [24:0] dl_addr, input logic [7:0] dl_data,
    input  logic        dl_active,
    input  logic        mrom_req, input  logic [18:1] mrom_addr,
    output logic        mrom_ack, output logic [15:0] mrom_q,
    input  logic        srom_req, input  logic [15:0] srom_addr,
    output logic        srom_ack, output logic  [7:0] srom_q,
    input  logic        gfxl_req, input  logic [17:0] gfxl_addr,
    output logic        gfxl_ack, output logic [31:0] gfxl_q,
    input  logic        gfxs_req, input  logic [17:0] gfxs_addr,
    output logic        gfxs_ack, output logic [31:0] gfxs_q,
    input  logic        vram_req, input  logic        vram_we,
    input  logic [14:0] vram_addr, input logic [15:0] vram_din,
    input  logic  [1:0] vram_ben,
    output logic        vram_ack, output logic [15:0] vram_q
);
    wire [15:0] SDRAM_DQ; wire [12:0] SDRAM_A; wire [1:0] SDRAM_BA;
    wire        SDRAM_DQML, SDRAM_DQMH, SDRAM_nCS, SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS;
    wire        SDRAM_CKE, SDRAM_CLK;
    wire [16:0] sram_a; wire [15:0] sram_dq;
    wire        sram_oe_n, sram_we_n, sram_ub_n, sram_lb_n;

    mycore_mem dut (
        .clk(clk), .clk_sdram(clk), .init(init), .ready(ready),
        .rd_late(rd_late), .burst_slow(burst_slow), .sram_slow(1'b0), .sram_slow_wr(1'b0),
        .dl_we(dl_we), .dl_addr(dl_addr), .dl_data(dl_data), .dl_active(dl_active),
        .mrom_req(mrom_req), .mrom_addr(mrom_addr), .mrom_ack(mrom_ack), .mrom_q(mrom_q),
        .srom_req(srom_req), .srom_addr(srom_addr), .srom_ack(srom_ack), .srom_q(srom_q),
        .gfxl_req(gfxl_req), .gfxl_addr(gfxl_addr), .gfxl_ack(gfxl_ack), .gfxl_q(gfxl_q),
        .gfxs_req(gfxs_req), .gfxs_addr(gfxs_addr), .gfxs_ack(gfxs_ack), .gfxs_q(gfxs_q),
        .vram_req(vram_req), .vram_we(vram_we), .vram_addr(vram_addr),
        .vram_din(vram_din), .vram_ben(vram_ben), .vram_ack(vram_ack), .vram_q(vram_q),
        .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA),
        .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
        .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS),
        .SDRAM_CKE(SDRAM_CKE), .SDRAM_CLK(SDRAM_CLK),
        .sram_a(sram_a), .sram_dq(sram_dq),
        .sram_oe_n(sram_oe_n), .sram_we_n(sram_we_n), .sram_ub_n(sram_ub_n), .sram_lb_n(sram_lb_n)
    );

    sdram_model #(.AW(24)) chip (
        .clk(clk), .dq(SDRAM_DQ), .a(SDRAM_A), .ba(SDRAM_BA),
        .dqml(SDRAM_DQML), .dqmh(SDRAM_DQMH), .cs_n(SDRAM_nCS),
        .ras_n(SDRAM_nRAS), .cas_n(SDRAM_nCAS), .we_n(SDRAM_nWE), .cke(SDRAM_CKE)
    );
    sram_model sram (.clk(clk), .a(sram_a), .dq(sram_dq), .oe_n(sram_oe_n), .we_n(sram_we_n),
                     .ub_n(sram_ub_n), .lb_n(sram_lb_n));
    /* verilator lint_off UNUSEDSIGNAL */
    wire unused = ^{SDRAM_CLK};
    /* verilator lint_on UNUSEDSIGNAL */
endmodule
`default_nettype wire
