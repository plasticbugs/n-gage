//------------------------------------------------------------------------------
// The instruction cache: 16 KB, two ways of 256 lines of 32 bytes, virtually
// tagged (docs/core-design.md 4).
//
// It answers the CPU's instruction port (arm_cpu.sv): an address at an edge
// is answered in the next cycle by ic_ok, or not, and the CPU asks again.
// So a miss costs the CPU nothing to handle: the cache starts the line's
// fill and says "not yet" until the line is in.  A hit for another line is
// answered while a fill is under way; a second miss waits.
//
// The tags and the data are block RAM read at every edge with the CPU's
// address.  The valid bits are flops, so IO_CACHE_FLUSH clears them in one
// cycle, and they are read at the same edge into flops of their own.  That
// copy can be a cycle stale, which is why the cache rests a cycle (S_WAIT)
// after it writes a line before it may start another fill.
//
// A fetch from an address with no mapping comes back from the miss handler
// as a fault.  The cache remembers that line and answers it with ic_abort,
// which the CPU turns into a prefetch abort if the instruction executes.
// A page-table write or a flush forgets it.
//------------------------------------------------------------------------------
`default_nettype none

module ngvm_icache
    import ngvm_pkg::*;
(
    input  logic         clk,
    input  logic         rst,

    input  logic         ic_req,
    input  logic  [31:0] ic_addr,
    output logic  [31:0] ic_data,
    output logic         ic_ok,
    output logic         ic_abort,

    input  logic   [5:0] win_id,
    input  logic         inv,           // pulse: forget every line (the end of a flush)
    input  logic         pt_wr,         // pulse: the page table changed

    // the miss handler (ngvm_mmu): fill_req is held until the line is written
    output logic         fill_req,
    output logic  [31:0] fill_va,
    input  logic         fill_done,     // pulse; fill_line holds while fill_req does
    input  logic         fill_fault,
    input  logic [255:0] fill_line
);
    // ------------------------------------------------------------ arrays
    logic [31:0]     dat0 [0:2047], dat1 [0:2047];
    logic [TAGW-1:0] tag0 [0:255],  tag1 [0:255];
    logic [255:0]    val0, val1;
    logic [255:0]    lru;               // the way to replace next

    logic [31:0]     q0, q1;
    logic [TAGW-1:0] t0, t1;
    logic            vq0, vq1;

    logic        dw_en, dw_way, tw_en;
    logic [10:0] dw_a;
    logic [31:0] dw_d;
    logic  [7:0] tw_a;
    logic [TAGW-1:0] tw_d;

    always_ff @(posedge clk) begin
        if (dw_en && !dw_way) dat0[dw_a] <= dw_d;
        if (dw_en &&  dw_way) dat1[dw_a] <= dw_d;
        if (tw_en && !dw_way) tag0[tw_a] <= tw_d;
        if (tw_en &&  dw_way) tag1[tw_a] <= tw_d;
        q0  <= dat0[ic_addr[12:2]];
        q1  <= dat1[ic_addr[12:2]];
        t0  <= tag0[ic_addr[12:5]];
        t1  <= tag1[ic_addr[12:5]];
        vq0 <= val0[ic_addr[12:5]];
        vq1 <= val1[ic_addr[12:5]];
    end

    // ------------------------------------------------------------ lookup
    logic        f2_req;
    logic [31:0] f2_va;
    always_ff @(posedge clk) begin
        f2_req <= !rst && ic_req;
        f2_va  <= ic_addr;
    end
    wire  [7:0]      f2_set = f2_va[12:5];
    wire  [TAGW-1:0] f2_tag = vtag_of(f2_va, win_id);
    wire             hit0   = vq0 && t0 == f2_tag;
    wire             hit1   = vq1 && t1 == f2_tag;
    wire             hit    = hit0 || hit1;

    logic        fv;                    // a fault remembered
    logic [26:0] fline;
    wire         fmatch = fv && f2_va[31:5] == fline;

    assign ic_ok    = f2_req && (hit || fmatch);
    assign ic_abort = !hit;
    assign ic_data  = hit1 ? q1 : q0;

    // ------------------------------------------------------------ fills
    typedef enum logic [1:0] { S_IDLE, S_FILL, S_WRITE, S_WAIT } st_t;
    st_t         st;
    logic [31:0] mva;
    logic [TAGW-1:0] mtag;
    logic        mway, discard;
    logic  [2:0] k;

    wire start = st == S_IDLE && f2_req && !hit && !fmatch;
    wire vict  = !val0[f2_set] ? 1'b0 : !val1[f2_set] ? 1'b1 : lru[f2_set];

    assign fill_req = st == S_FILL || st == S_WRITE;
    assign fill_va  = {mva[31:5], 5'd0};

    always_comb begin
        dw_en  = st == S_WRITE;
        dw_way = mway;
        dw_a   = {mva[12:5], k};
        dw_d   = fill_line[32*k +: 32];
        tw_en  = st == S_WRITE && k == 3'd7 && !discard;
        tw_a   = mva[12:5];
        tw_d   = mtag;
    end

    always_ff @(posedge clk) begin
        if (f2_req && hit && st != S_WRITE) lru[f2_set] <= hit0;
        case (st)
            S_IDLE: if (start) begin
                st   <= S_FILL;
                mva  <= f2_va;
                mtag <= f2_tag;
                mway <= vict;
                discard <= 1'b0;
                if (vict) val1[f2_set] <= 1'b0; else val0[f2_set] <= 1'b0;
            end
            S_FILL: if (fill_done) begin
                k  <= 3'd0;
                st <= fill_fault ? S_WAIT : S_WRITE;
            end
            S_WRITE: begin
                k <= k + 3'd1;
                if (k == 3'd7) begin
                    st <= S_WAIT;
                    if (!discard) begin
                        if (mway) val1[mva[12:5]] <= 1'b1; else val0[mva[12:5]] <= 1'b1;
                        lru[mva[12:5]] <= !mway;
                    end
                end
            end
            default: st <= S_IDLE;
        endcase

        // faults: remembered for the line, forgotten when anything changes
        if (st == S_FILL && fill_done && fill_fault) begin
            fv <= 1'b1; fline <= mva[31:5];
        end else if (start || pt_wr || inv) fv <= 1'b0;

        if (inv) begin
            val0 <= '0; val1 <= '0;
            discard <= 1'b1;
        end
        if (rst) begin
            st <= S_IDLE; val0 <= '0; val1 <= '0; lru <= '0; fv <= 1'b0;
        end
    end
endmodule

`default_nettype wire
