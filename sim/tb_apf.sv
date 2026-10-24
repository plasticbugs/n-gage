// The core's side of the APF bridge, for the benches, as core_top wires it:
// core_bridge_cmd (the host's and the target's command registers), the
// data_io that takes the slots' bytes at bridge 0x0xxxxxxx, and
// ngage_slots, which issues the save's writes and the drive's fetches.  The
// bridge's reads are answered through core_top's mux:
// 0x2xxxxxxx from the save's readout (sv_rd_data, ngage_save), 0xF8xxxxxx
// from core_bridge_cmd.  The bench plays the Pocket on the pins
// (sim/apf_host.h) and gates the bytes into ngage_mem as core_top does:
//
//   dl_open = io_download || fetching,  dl_we = dl_open && io_wr
//
// The parameters let a unit bench shorten the save's waits; the system
// bench keeps core_top's.  dcfifo_model.v and mf_datatable_model.v stand in
// for the megafunctions.
`default_nettype none

module tb_apf #(
    parameter logic [31:0] NV_BYTES  = 32'h100000,
    parameter int          SV_SETTLE = 148_500_000,
    parameter int          SV_BOOT   = 371_250_000
) (
    input  logic        clk_74a,
    input  logic        clk,                // clk_sys: data_io's memory side, ngage_mem's
    input  logic        setup_done,         // core_top's PLL lock: 0x0140 on its rise

    input  logic        bridge_wr,
    input  logic        bridge_rd,
    input  logic [31:0] bridge_addr,
    input  logic [31:0] bridge_wr_data,
    output logic [31:0] bridge_rd_data,
    input  logic [31:0] sv_rd_data,

    input  logic        save_t,
    input  logic        fetch_t,
    input  logic [31:0] fetch_src, fetch_dst, fetch_len,
    output logic        fetch_done_t,
    output logic  [2:0] fetch_err,

    output logic        io_wr,              // data_io's byte strobe (clk)
    output logic [26:0] io_addr,
    output logic  [7:0] io_data,
    output logic        io_download,
    output logic        fetching,           // ngage_slots: a fetch's bytes may come (clk)
    input  logic        dl_idle,            // ngage_mem's

    output logic        allcomplete,
    output logic        inmenu,
    output logic [31:0] fifo_overflows      // the loader's FIFO written while full
);
    wire        reset_n;
    wire [31:0] cmd_rd_data;
    wire        requestwrite;
    wire [15:0] requestwrite_id;
    wire        t_read, t_write, t_ack, t_done;
    wire  [2:0] t_err;
    wire [15:0] t_id;
    wire [31:0] t_offset, t_baddr, t_length;
    wire [31:0] datatable_q;

    core_bridge_cmd icb (
        .clk(clk_74a), .reset_n(reset_n),
        .bridge_endian_little(1'b0), .bridge_addr(bridge_addr), .bridge_rd(bridge_rd),
        .bridge_rd_data(cmd_rd_data), .bridge_wr(bridge_wr), .bridge_wr_data(bridge_wr_data),
        .status_boot_done(setup_done), .status_setup_done(setup_done), .status_running(reset_n),
        .dataslot_requestread(), .dataslot_requestread_id(),
        .dataslot_requestread_ack(1'b1), .dataslot_requestread_ok(1'b1),
        .dataslot_requestwrite(requestwrite), .dataslot_requestwrite_id(requestwrite_id),
        .dataslot_requestwrite_size(),
        .dataslot_requestwrite_ack(1'b1), .dataslot_requestwrite_ok(1'b1),
        .dataslot_update(), .dataslot_update_id(), .dataslot_update_size(),
        .dataslot_allcomplete(allcomplete),
        .rtc_epoch_seconds(), .rtc_date_bcd(), .rtc_time_bcd(), .rtc_valid(),
        .savestate_supported(1'b0), .savestate_addr(32'd0), .savestate_size(32'd0),
        .savestate_maxloadsize(32'd0),
        .savestate_start(), .savestate_start_ack(1'b0), .savestate_start_busy(1'b0),
        .savestate_start_ok(1'b0), .savestate_start_err(1'b0),
        .savestate_load(), .savestate_load_ack(1'b0), .savestate_load_busy(1'b0),
        .savestate_load_ok(1'b0), .savestate_load_err(1'b0),
        .osnotify_inmenu(inmenu), .osnotify_docked(),
        .target_dataslot_read(t_read), .target_dataslot_write(t_write),
        .target_dataslot_getfile(1'b0), .target_dataslot_openfile(1'b0),
        .target_dataslot_ack(t_ack), .target_dataslot_done(t_done), .target_dataslot_err(t_err),
        .target_dataslot_id(t_id), .target_dataslot_slotoffset(t_offset),
        .target_dataslot_bridgeaddr(t_baddr), .target_dataslot_length(t_length),
        .target_buffer_param_struct(32'd0), .target_buffer_resp_struct(32'd0),
        .datatable_addr(10'd9), .datatable_wren(1'b1), .datatable_data(NV_BYTES), .datatable_q(datatable_q)
    );

    always_comb
        casez (bridge_addr)
            32'h2???????: bridge_rd_data = sv_rd_data;
            32'hF8??????: bridge_rd_data = cmd_rd_data;
            default:      bridge_rd_data = 32'd0;
        endcase

    wire [15:0] io_index;
    data_io #(.MASK(4'h0), .AW(27), .DW(8), .DELAY(7), .HOLD(4)) pocket_data_io (
        .clk_74a(clk_74a), .clk_memory(clk),
        .dataslot_requestwrite(requestwrite), .dataslot_requestwrite_id(requestwrite_id),
        .dataslot_allcomplete(allcomplete),
        .bridge_endian_little(1'b0), .bridge_addr(bridge_addr), .bridge_wr(bridge_wr),
        .bridge_wr_data(bridge_wr_data),
        .ioctl_download(io_download), .ioctl_index(io_index), .ioctl_wr(io_wr),
        .ioctl_addr(io_addr), .ioctl_data(io_data)
    );
    assign fifo_overflows = pocket_data_io.data_loader_in.dcfifo_component.overflows;

    ngage_slots #(.NV_BYTES(NV_BYTES), .SV_SETTLE(SV_SETTLE), .SV_BOOT(SV_BOOT)) u_slots (
        .clk_74a(clk_74a), .dataslot_allcomplete(allcomplete), .osnotify_inmenu(inmenu),
        .save_t(save_t),
        .fetch_t(fetch_t), .fetch_src(fetch_src), .fetch_dst(fetch_dst), .fetch_len(fetch_len),
        .fetch_done_t(fetch_done_t), .fetch_err(fetch_err),
        .clk(clk), .dl_wr(io_wr), .dl_idle(dl_idle), .fetching(fetching),
        .target_dataslot_read(t_read), .target_dataslot_write(t_write),
        .target_dataslot_ack(t_ack), .target_dataslot_done(t_done), .target_dataslot_err(t_err),
        .target_dataslot_id(t_id), .target_dataslot_slotoffset(t_offset),
        .target_dataslot_bridgeaddr(t_baddr), .target_dataslot_length(t_length)
    );

    wire _unused = &{1'b0, datatable_q, io_index, 1'b0};
endmodule

`default_nettype wire
