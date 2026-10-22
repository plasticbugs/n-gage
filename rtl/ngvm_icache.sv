//------------------------------------------------------------------------------
// The instruction cache: 32 KB, two ways of 512 lines of 32 bytes, virtually
// tagged (docs/core-design.md 4).
//
// It answers the CPU's instruction port (arm_cpu.sv): an address at an edge
// is answered in the next cycle by ic_ok, or not, and the CPU asks again.
// So a miss costs the CPU nothing to handle: the cache starts the line's
// fill and says "not yet" until the word is in.  A hit for another line is
// answered while a fill is under way; a second miss waits.
//
// The line comes from the word missed on, then round (ngvm_mmu.sv), and
// each word is written to the RAM as it arrives.  A fetch from the line is
// answered once its word was written before the edge that read the RAM
// (f2_have), so the CPU runs on down the line as it comes in.  The tag, with
// its valid bit, is written when the last word is.
//
// The tags and the data are block RAM read at every edge with the CPU's
// address, and each tag word carries its line's valid bit.  The bits were
// flops until the cache had 256 sets, so a flush could clear them at once;
// at 512 sets the mux that read them sat on the fetch address, and their
// clear on the D-cache's flush walk.  A flush (inv) now sweeps the tag RAMs,
// a set a cycle, 512 cycles in which no fetch is answered; flushes come
// when code is loaded, a few times a game.  A miss marks its victim invalid
// at the edge after it starts, from flops (the victim's choice, through LRU
// and the hit, was the slowest way into the tag RAM's write).  A lookup
// may hit the victim for two cycles more, which is harmless: its first new
// word comes after the miss handler's translation and the memory, several
// cycles on.
//
// The tag RAMs can be read a cycle stale after a write, which is why the
// cache rests a cycle (S_WAIT) after it writes a line before it may start
// another fill, and answers from the line just written meanwhile (fhit).
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
    input  logic [255:0] fill_line,
    input  logic   [3:0] fill_words     // how many of its words are in fill_line
);
    localparam int SB = 9;              // set bits: va[13:5]

    // ------------------------------------------------------------ arrays
    logic [31:0]     dat0 [0:(8<<SB)-1], dat1 [0:(8<<SB)-1];
    logic [TAGW:0]   tag0 [0:(1<<SB)-1], tag1 [0:(1<<SB)-1];   // {valid, tag}
    logic [(1<<SB)-1:0] lru;            // the way to replace next

    logic [31:0]     q0, q1;
    logic [TAGW:0]   t0, t1;

    logic        dw_en, dw_way;
    logic  [2:0] dw_w;
    logic [SB+2:0] dw_a;
    logic [31:0] dw_d;
    logic        tw0, tw1;
    logic [SB-1:0] tw_a;
    logic [TAGW:0] tw_d;

    always_ff @(posedge clk) begin
        if (dw_en && !dw_way) dat0[dw_a] <= dw_d;
        if (dw_en &&  dw_way) dat1[dw_a] <= dw_d;
        q0 <= dat0[ic_addr[SB+4:2]];
        q1 <= dat1[ic_addr[SB+4:2]];
    end
    always_ff @(posedge clk) begin
        if (tw0) tag0[tw_a] <= tw_d;
        if (tw1) tag1[tw_a] <= tw_d;
        t0 <= tag0[ic_addr[SB+4:5]];
        t1 <= tag1[ic_addr[SB+4:5]];
    end

    // ------------------------------------------------------------ lookup
    logic        f2_req;
    logic [31:0] f2_va;
    always_ff @(posedge clk) begin
        f2_req <= !rst && ic_req;
        f2_va  <= ic_addr;
    end
    wire  [SB-1:0]   f2_set = f2_va[SB+4:5];
    wire  [TAGW-1:0] f2_tag = vtag_of(f2_va, win_id);
    wire             vq0    = t0[TAGW];
    wire             vq1    = t1[TAGW];
    wire             hit0   = vq0 && t0[TAGW-1:0] == f2_tag;
    wire             hit1   = vq1 && t1[TAGW-1:0] == f2_tag;
    wire             hit    = hit0 || hit1;

    logic        fv;                    // a fault remembered
    logic [26:0] fline;
    wire         fmatch = fv && f2_va[31:5] == fline;

    // ------------------------------------------------------------ fills
    typedef enum logic [1:0] { S_IDLE, S_FILL, S_WAIT, S_SWEEP } st_t;
    st_t         st;
    logic [31:0] mva;
    logic [TAGW-1:0] mtag;
    logic        mway, discard, fdone;
    logic  [3:0] wk;                    // words written, 0-8
    logic  [7:0] have, f2_have;         // which; and which were, when the RAM read
    logic        sweep_pend;            // a flush came: sweep when idle
    logic        kill_v, kill_w;        // the victim to mark invalid, a cycle after the miss
    logic [SB-1:0] kill_a;
    logic [SB-1:0] sw;                  // the set being swept

    // the line coming in: a fetch from it whose word was written before the
    // RAM read it (and the cycle after the line is done, while the tag the
    // lookup reads may be a cycle stale)
    wire  fhit = f2_req && (st == S_FILL || st == S_WAIT) && !discard && f2_tag == mtag
              && f2_set == mva[SB+4:5] && f2_have[f2_va[4:2]];

    wire  blind = sweep_pend || st == S_SWEEP;  // lines a flush has forgotten may still read valid
    assign ic_ok    = f2_req && !blind && (hit || fhit || fmatch);
    assign ic_abort = !(hit || fhit);
    assign ic_data  = hit1 || (fhit && mway) ? q1 : q0;

    wire start = st == S_IDLE && !blind && f2_req && !hit && !fmatch;
    wire vict  = !vq0 ? 1'b0 : !vq1 ? 1'b1 : lru[f2_set];
    wire fw    = st == S_FILL && wk < fill_words;          // a word to write
    wire fend  = st == S_FILL && (fdone || fill_done) && wk == 4'd8;

    assign fill_req = st == S_FILL;
    assign fill_va  = {mva[31:2], 2'd0};

    always_comb begin
        dw_w   = mva[4:2] + wk[2:0];    // the word missed on came first
        dw_en  = fw;
        dw_way = mway;
        dw_a   = {mva[SB+4:5], dw_w};
        dw_d   = fill_line[32*dw_w +: 32];
        // a tag write: the sweep's (both ways), a fill's last word, or a
        // victim's invalidation the cycle after its fill starts (never the
        // cycle a fill ends)
        tw0 = 1'b0; tw1 = 1'b0; tw_a = mva[SB+4:5]; tw_d = {1'b1, mtag};
        if (st == S_SWEEP) begin
            tw0 = 1'b1; tw1 = 1'b1; tw_a = sw; tw_d = '0;
        end else if (fend && !discard) begin
            tw0 = !mway; tw1 = mway;
        end else if (kill_v) begin
            tw0 = !kill_w; tw1 = kill_w; tw_a = kill_a; tw_d = '0;
        end
    end

    always_ff @(posedge clk) begin
        f2_have <= start ? '0 : have;   // a new line has nothing in yet
        kill_v <= start; kill_w <= vict; kill_a <= f2_set;
        if (f2_req && hit) lru[f2_set] <= hit0;
        case (st)
            S_IDLE: if (sweep_pend) begin
                st <= S_SWEEP; sw <= '0; sweep_pend <= 1'b0;
            end else if (start) begin
                st   <= S_FILL;
                mva  <= f2_va;
                mtag <= f2_tag;
                mway <= vict;
                discard <= 1'b0;
                wk <= 4'd0; have <= '0; fdone <= 1'b0;
            end
            S_FILL: begin
                if (fw) begin wk <= wk + 4'd1; have[dw_w] <= 1'b1; end
                if (fill_done) fdone <= 1'b1;
                if (fill_done && fill_fault) st <= S_WAIT;
                else if (fend) begin
                    st <= S_WAIT;
                    if (!discard) lru[mva[SB+4:5]] <= !mway;
                end
            end
            S_SWEEP: begin
                sw <= sw + 1'b1;
                if (&sw) st <= S_IDLE;
            end
            default: st <= S_IDLE;
        endcase

        // faults: remembered for the line, forgotten when anything changes
        if (st == S_FILL && fill_done && fill_fault) begin
            fv <= 1'b1; fline <= mva[31:5];
        end else if (start || pt_wr || inv) fv <= 1'b0;

        if (inv) begin
            sweep_pend <= 1'b1;
            discard <= 1'b1;
        end
        if (rst) begin
            st <= S_SWEEP; sw <= '0; sweep_pend <= 1'b0;   // the tags start unknown
            lru <= '0; fv <= 1'b0; have <= '0; discard <= 1'b0; kill_v <= 1'b0;
        end
    end
endmodule

`default_nettype wire
