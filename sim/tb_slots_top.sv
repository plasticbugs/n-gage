// Bench wrapper for target/pocket/ngage_slots.sv with what it talks to on the
// APF side (sim/tb_apf.sv: core_bridge_cmd, data_io, and the megafunctions'
// models), the save's waits shortened.  sim/tb_slots.cpp plays the Pocket's
// host on the bridge, the kernel on the fetch registers, and ngage_mem on
// the bytes: it takes each on its strobe's rise, as ngage_mem does, and
// writes it to its memory a varying time later, with dl_idle low until then.
`default_nettype none

module tb_slots_top (
    input  logic        clk_74a,
    input  logic        clk,
    input  logic        setup_done,

    input  logic        bridge_wr,
    input  logic        bridge_rd,
    input  logic [31:0] bridge_addr,
    input  logic [31:0] bridge_wr_data,
    output logic [31:0] bridge_rd_data,

    input  logic        save_t,
    input  logic        fetch_t,
    input  logic [31:0] fetch_src, fetch_dst, fetch_len,
    output logic        fetch_done_t,
    output logic  [2:0] fetch_err,

    output logic        dl_we,              // as core_top gates them into ngage_mem
    output logic [26:0] dl_addr,
    output logic  [7:0] dl_data,
    output logic        dl_open,
    output logic        io_wr,              // data_io's strobe, ungated
    input  logic        dl_idle,

    output logic        allcomplete,
    output logic        inmenu,
    output logic        io_download,
    output logic        fetching,
    output logic [31:0] fifo_overflows
);
    tb_apf #(.NV_BYTES(32'h400), .SV_SETTLE(20_000), .SV_BOOT(60_000)) apf (
        .clk_74a(clk_74a), .clk(clk), .setup_done(setup_done),
        .bridge_wr(bridge_wr), .bridge_rd(bridge_rd), .bridge_addr(bridge_addr),
        .bridge_wr_data(bridge_wr_data), .bridge_rd_data(bridge_rd_data),
        .sv_rd_data(32'h5A00_0000 | {8'd0, bridge_addr[23:0]}),
        .save_t(save_t), .fetch_t(fetch_t), .fetch_src(fetch_src), .fetch_dst(fetch_dst),
        .fetch_len(fetch_len), .fetch_done_t(fetch_done_t), .fetch_err(fetch_err),
        .io_wr(io_wr), .io_addr(dl_addr), .io_data(dl_data), .io_download(io_download),
        .fetching(fetching), .dl_idle(dl_idle),
        .allcomplete(allcomplete), .inmenu(inmenu), .fifo_overflows(fifo_overflows)
    );
    assign dl_open = io_download || fetching;
    assign dl_we   = dl_open && io_wr;
endmodule

`default_nettype wire
