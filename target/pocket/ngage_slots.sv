//------------------------------------------------------------------------------
// The data slots the core reads and writes itself, once the Pocket has loaded
// them, with APF target commands through core_bridge_cmd's one interface:
//
//   slot 4, the save: a write (0x0184) of C:, the top MB of NGVM's RAM, which
//   the bridge reads back through ngage_save.sv.  2 s after the kernel last
//   wrote C: (IO_SAVE_DIRTY, save_t), when the Pocket's menu opens with a
//   write pending, and once 5 s after the load, so that the file exists from
//   the first run (METHODOLOGY 5.24).
//
//   slot 3, the drive: a read (0x0180) of part of the image into the drive's
//   window, when the kernel asks (IO_FETCH_*, sw/include/ngvm_hw.h): for an
//   image larger than the window, of which the CRAM holds the first 32 MB.
//   The Pocket writes the bytes to the bridge address asked for, 0x04000000
//   plus the place in the window, and they come in as the load's do, through
//   data_io and ngage_mem.  data_io raises its download only for a load the
//   host starts, which a target read may not be, so `fetching` opens the
//   download path for them.
//
// One command at a time.  Whose it is is latched when it is issued, and the
// ack and done that follow are that one's (METHODOLOGY 5.17).  A fetch goes
// first when both wait, since the game waits for it.  The save's command
// waits for ack, then done, as it did before the fetch existed (proven on
// the Pocket in v1.2.0).  A fetch's waits for done to fall, the command
// taken, then to rise: the bridge raises ack only if the host says "busy"
// first, and nothing yet shows that it does for a read (pc88_slots.sv waits
// the same way).
//
// The host's "ok" does not end a fetch: bytes it wrote before it may still
// be in data_loader's FIFO or ngage_mem's.  A fetch ends once, after the
// "ok", DRAIN clocks of clk pass with no byte strobed in and with
// ngage_mem's queues empty.  Then fetch_done_t answers it, with the
// Pocket's error code in fetch_err.
//
// Clocks: the commands on clk_74a; the drain's watch on clk, ngage_mem's;
// the request (a toggle, its words held still until it is answered) from
// the CPU's clock, and the answer back to it (ngvm_io.sv).
//------------------------------------------------------------------------------
`default_nettype none

module ngage_slots #(
    parameter logic [31:0] NV_BYTES  = 32'h100000,      // the save: C:, 1 MB
    parameter int          SV_SETTLE = 148_500_000,     // 2 s of clk_74a
    parameter int          SV_BOOT   = 371_250_000,     // 5 s
    parameter int          DRAIN     = 255              // clocks of clk
) (
    input  logic        clk_74a,
    input  logic        dataslot_allcomplete,
    input  logic        osnotify_inmenu,

    input  logic        save_t,         // toggles, any clock: the kernel wrote C:

    input  logic        fetch_t,        // toggles, any clock: a fetch, its words held
    input  logic [31:0] fetch_src,      // byte offset in the image
    input  logic [31:0] fetch_dst,      // byte offset in the window
    input  logic [31:0] fetch_len,
    output logic        fetch_done_t,   // toggles to match fetch_t: the bytes are in
    output logic  [2:0] fetch_err,      // the Pocket's error, held with it

    input  logic        clk,            // ngage_mem's
    input  logic        dl_wr,          // a byte is strobed in (data_io's ioctl_wr)
    input  logic        dl_idle,        // ngage_mem has no byte waiting
    output logic        fetching,       // clk: a fetch's bytes may come

    output logic        target_dataslot_read,
    output logic        target_dataslot_write,
    input  logic        target_dataslot_ack,
    input  logic        target_dataslot_done,
    input  logic  [2:0] target_dataslot_err,
    output logic [15:0] target_dataslot_id,
    output logic [31:0] target_dataslot_slotoffset,
    output logic [31:0] target_dataslot_bridgeaddr,
    output logic [31:0] target_dataslot_length
);
    localparam int SW = $clog2(SV_SETTLE + 1), BW = $clog2(SV_BOOT + 1), QW = $clog2(DRAIN + 1);

    // ------------------------------------------------------------ crossings
    logic sv_dirty_s, fetch_s, drained, drained_s, drain_req, drain_s, fetch_74;
    synch_3 s_svd (.i(save_t),    .o(sv_dirty_s), .clk(clk_74a), .rise(), .fall());
    synch_3 s_fet (.i(fetch_t),   .o(fetch_s),    .clk(clk_74a), .rise(), .fall());
    synch_3 s_drd (.i(drained),   .o(drained_s),  .clk(clk_74a), .rise(), .fall());
    synch_3 s_drq (.i(drain_req), .o(drain_s),    .clk(clk),     .rise(), .fall());
    synch_3 s_fng (.i(fetch_74),  .o(fetching),   .clk(clk),     .rise(), .fall());

    // ------------------------------------------------------------ the drain's watch (clk)
    // drained rises DRAIN quiet clocks after drain_req does, and falls with it
    logic [QW-1:0] quiet;
    always_ff @(posedge clk) begin
        if (!drain_s || dl_wr || !dl_idle) quiet <= '0;
        else if (quiet != QW'(DRAIN)) quiet <= quiet + 1'b1;
        drained <= quiet == QW'(DRAIN);
    end

    // ------------------------------------------------------------ the save's triggers
    logic          sv_dirty_d, sv_menu_d, sv_pending, sv_loaded;
    logic          sv_go;                   // a save is to be written when the interface is free
    logic [SW-1:0] sv_timer;
    logic [BW-1:0] sv_boot;

    // ------------------------------------------------------------ the commands
    typedef enum logic [2:0] {
        T_IDLE, T_SAVE_ACK, T_SAVE_DONE, T_FETCH_TAKEN, T_FETCH_DONE, T_DRAIN, T_DRAIN_END
    } tstate_t;
    tstate_t ts;
    // `always`, not `always_ff`: the initial block gives the registers their
    // power-up values (the APF side has no reset), and always_ff may not
    // share a variable with it
    initial begin
        ts = T_IDLE;
        sv_dirty_d = 1'b0; sv_menu_d = 1'b0; sv_pending = 1'b0; sv_loaded = 1'b0; sv_go = 1'b0;
        sv_timer = '0; sv_boot = '0;
        target_dataslot_read = 1'b0; target_dataslot_write = 1'b0;
        fetch_done_t = 1'b0; fetch_err = 3'd0; drain_req = 1'b0; fetch_74 = 1'b0;
    end

    always @(posedge clk_74a) begin
        sv_dirty_d <= sv_dirty_s; sv_menu_d <= osnotify_inmenu;
        // all-complete cannot gate the writes: the bridge clears it when the
        // Pocket reads the slot for one of them.  Its first rising edge can.
        if (dataslot_allcomplete) sv_loaded <= 1'b1;
        if (sv_loaded && sv_boot != BW'(SV_BOOT)) sv_boot <= sv_boot + 1'b1;
        if (sv_dirty_s != sv_dirty_d) begin sv_pending <= 1'b1; sv_timer <= '0; end
        else if (sv_timer != SW'(SV_SETTLE)) sv_timer <= sv_timer + 1'b1;
        if ((sv_pending && sv_loaded && (sv_timer == SW'(SV_SETTLE) || (osnotify_inmenu && !sv_menu_d)))
            || sv_boot == BW'(SV_BOOT - 1)) begin
            sv_go <= 1'b1;
            sv_pending <= 1'b0;
        end

        case (ts)
            T_IDLE: begin
                target_dataslot_read  <= 1'b0;
                target_dataslot_write <= 1'b0;
                if (fetch_s != fetch_done_t) begin
                    // its rising edge starts the command
                    target_dataslot_read       <= 1'b1;
                    target_dataslot_id         <= 16'd3;
                    target_dataslot_slotoffset <= fetch_src;
                    target_dataslot_bridgeaddr <= 32'h0400_0000 + {7'd0, fetch_dst[24:0]};
                    target_dataslot_length     <= fetch_len;
                    fetch_74 <= 1'b1;
                    ts <= T_FETCH_TAKEN;
                end else if (sv_go) begin
                    target_dataslot_write      <= 1'b1;
                    target_dataslot_id         <= 16'd4;
                    target_dataslot_slotoffset <= 32'd0;
                    target_dataslot_bridgeaddr <= 32'h2000_0000;
                    target_dataslot_length     <= NV_BYTES;
                    sv_go <= 1'b0;
                    ts <= T_SAVE_ACK;
                end
            end
            T_SAVE_ACK:  if (target_dataslot_ack) begin target_dataslot_write <= 1'b0; ts <= T_SAVE_DONE; end
            T_SAVE_DONE: if (target_dataslot_done) ts <= T_IDLE;
            // done is held from the last command until the bridge takes this one
            T_FETCH_TAKEN: if (!target_dataslot_done) begin target_dataslot_read <= 1'b0; ts <= T_FETCH_DONE; end
            T_FETCH_DONE: if (target_dataslot_done) begin
                fetch_err <= target_dataslot_err;
                drain_req <= 1'b1;
                ts <= T_DRAIN;
            end
            T_DRAIN: if (drained_s) begin drain_req <= 1'b0; fetch_74 <= 1'b0; ts <= T_DRAIN_END; end
            T_DRAIN_END: if (!drained_s) begin fetch_done_t <= fetch_s; ts <= T_IDLE; end
            default: ts <= T_IDLE;
        endcase
    end

    wire _unused = &{1'b0, fetch_dst[31:25], 1'b0};
endmodule

`default_nettype wire
