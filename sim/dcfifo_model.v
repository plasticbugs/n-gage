// Behavioural stand-in for Altera's dcfifo, as data_loader instantiates it
// (lpm_showahead "OFF": q a clock after rdreq).  Each side sees the other's
// pointer through its *sync_delaypipe flops, so a word written is seen by the
// reader that many read clocks later, and a word read frees its place that
// many write clocks later, as in the megafunction.  That latency is what a
// drain after the host's "ok" has to outlast (target/pocket/ngage_slots.sv),
// so it is modelled rather than passed straight across.  Overflow and
// underflow are not checked, as data_loader asks; a write into a full FIFO
// is counted in `overflows` for the bench to read.
`default_nettype none

module dcfifo #(
    parameter clocks_are_synchronized = "FALSE",
    parameter intended_device_family  = "Cyclone V",
    parameter lpm_numwords            = 4,
    parameter lpm_showahead           = "OFF",
    parameter lpm_type                = "dcfifo",
    parameter lpm_width               = 8,
    parameter lpm_widthu              = 2,
    parameter overflow_checking       = "OFF",
    parameter rdsync_delaypipe        = 5,
    parameter underflow_checking      = "OFF",
    parameter use_eab                 = "OFF",
    parameter wrsync_delaypipe        = 5
) (
    input  wire [lpm_width-1:0] data,
    input  wire                 rdclk,
    input  wire                 rdreq,
    input  wire                 wrclk,
    input  wire                 wrreq,
    output reg  [lpm_width-1:0] q,
    output wire                 rdempty
);
    localparam PW = lpm_widthu + 1;
    reg [lpm_width-1:0] mem [0:lpm_numwords-1];
    reg [PW-1:0] wptr, rptr;
    reg [PW-1:0] wsync [0:rdsync_delaypipe-1];      // wptr, in the read clock
    reg [PW-1:0] rsync [0:wrsync_delaypipe-1];      // rptr, in the write clock
    reg [31:0]   overflows;
    integer i;
    initial begin
        q = 0; wptr = 0; rptr = 0; overflows = 0;
        for (i = 0; i < rdsync_delaypipe; i = i + 1) wsync[i] = 0;
        for (i = 0; i < wrsync_delaypipe; i = i + 1) rsync[i] = 0;
    end

    wire [PW-1:0] r_wptr = wsync[rdsync_delaypipe-1];
    wire [PW-1:0] w_rptr = rsync[wrsync_delaypipe-1];
    assign rdempty = r_wptr == rptr;
    wire wrfull = wptr[PW-2:0] == w_rptr[PW-2:0] && wptr[PW-1] != w_rptr[PW-1];

    always @(posedge wrclk) begin
        rsync[0] <= rptr;
        for (i = 1; i < wrsync_delaypipe; i = i + 1) rsync[i] <= rsync[i-1];
        if (wrreq) begin
            if (wrfull) overflows <= overflows + 1;
            mem[wptr[PW-2:0]] <= data;
            wptr <= wptr + 1'b1;
        end
    end
    always @(posedge rdclk) begin
        wsync[0] <= wptr;
        for (i = 1; i < rdsync_delaypipe; i = i + 1) wsync[i] <= wsync[i-1];
        if (rdreq && !rdempty) begin
            q <= mem[rptr[PW-2:0]];
            rptr <= rptr + 1'b1;
        end
    end
endmodule

`default_nettype wire
