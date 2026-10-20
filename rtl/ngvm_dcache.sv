//------------------------------------------------------------------------------
// The data cache: 16 KB, two ways of 256 lines of 32 bytes, virtually tagged,
// write-back and write-allocate (docs/core-design.md 4).  Each line keeps the
// bus address it came from, so a write-back never reads the page table.
//
// It answers the CPU's data port (arm_cpu.sv).  The CPU asks only when the
// port is idle or completing, so every request is taken; the cache reads its
// RAMs with the address at that edge and in the next cycle (the compare)
// either completes it -- a hit, a device, an abort -- or keeps it and goes
// to fetch what it needs, reading the RAMs again for it when that is done
// (S_REPLAY).  The request waits in r_* meanwhile, and the CPU holds M.
//
// A store hit writes its word at the edge that ends the compare, which is
// the edge that reads for the next request: if that is the same word, the
// next compare merges the store's bytes over what the RAM gave (byp_*).
//
// What is not cached:
//   * the devices (RG_IO): ngvm_io answers in the compare cycle;
//   * the physical alias and the drive: a load is one word through the miss
//     handler.  A store completes at once into the write-combining buffer
//     (wc_*), one line with a byte mask, which goes out as one masked line
//     write when a store needs another line.  The kernel zeroes every page
//     it hands out through the alias, which a word at a time took most of
//     the boot.  The buffer is written out before anything else this cache
//     sends the bus -- an uncached load, a fill, a write-back, a walk -- so
//     a read of the same RAM through a cached address cannot pass it;
//   * IO_CACHE_FLUSH: a walk that writes back every dirty line, forgets every
//     line here and in the I-cache, and then completes the store.
// And between requests, `clean` (the LCD's frame start) asks for a walk that
// writes back every dirty line and keeps it, so the picture the LCD reads
// from SDRAM is what the CPU has drawn.  A request arriving meanwhile waits.
//------------------------------------------------------------------------------
`default_nettype none

module ngvm_dcache
    import ngvm_pkg::*;
(
    input  logic         clk,
    input  logic         rst,

    input  logic         dc_req,
    input  logic         dc_we,
    input  logic  [31:0] dc_addr,
    input  logic  [31:0] dc_wdata,
    input  logic   [3:0] dc_be,
    output logic  [31:0] dc_rdata,
    output logic         dc_ok,
    output logic         dc_abort,

    input  logic   [5:0] win_id,

    // the devices: io_req in the compare cycle, io_rdata in the same cycle
    output logic         io_req,
    output logic         io_we,
    output logic   [9:0] io_off,
    output logic  [31:0] io_wdata,
    input  logic  [31:0] io_rdata,

    input  logic         clean,         // pulse: write back every dirty line
    output logic         inv_i,         // pulse: a flush is done; the I-cache forgets too

    // the miss handler (ngvm_mmu): m_req is held until the answer is used
    output logic         m_req,
    output logic   [1:0] m_cmd,         // MC_*
    output logic  [31:0] m_va,          // a fill's, an uncached load's, the buffer's line
    output logic  [26:0] m_pa,          // a write-back's line
    output logic  [31:0] m_be,          // the buffer's byte mask
    output logic [255:0] m_wline,       // a write-back's line, or the buffer's
    input  logic         m_done,        // pulse
    input  logic         m_fault,
    input  logic  [26:0] m_fill_pa,
    input  logic [255:0] m_rline        // a fill's line; word 0 an uncached load's
);
    localparam logic [1:0] MC_FILL = 2'd0, MC_WB = 2'd1, MC_URD = 2'd2, MC_WCB = 2'd3;
    localparam int PAW = 22;            // a line's bus address, [26:5]

    // ------------------------------------------------------------ arrays
    // data: a RAM per way, with byte enables; tags: {vtag, bus line}.  The
    // data RAMs are written in Intel's byte-enable template (a packed array
    // of bytes, one `if` per byte, the RAM alone in its block): a loop over
    // slices of an unpacked word is not inferred by Quartus 18.1, which then
    // builds 131,072 flops instead of 16 block RAMs.
    logic [3:0][7:0]     dat0 [0:2047], dat1 [0:2047];
    logic [TAGW+PAW-1:0] tag0 [0:255],  tag1 [0:255];
    logic [255:0]        val0, val1, dty0, dty1;
    logic [255:0]        lru;           // the way to replace next

    logic [10:0] rd_a;                  // what the RAMs read at this edge
    logic [31:0] q0, q1;
    logic [TAGW+PAW-1:0] t0, t1;
    logic [15:0] vg0, vg1;              // the valid bits of 16 sets, read with the tags

    logic        dw_en, dw_way;
    logic [10:0] dw_a;
    logic [31:0] dw_d;
    logic  [3:0] dw_be;
    logic        tw_en;
    logic  [7:0] tw_a;
    logic [TAGW+PAW-1:0] tw_d;

    always_ff @(posedge clk) begin
        if (dw_en && !dw_way) begin
            if (dw_be[0]) dat0[dw_a][0] <= dw_d[7:0];
            if (dw_be[1]) dat0[dw_a][1] <= dw_d[15:8];
            if (dw_be[2]) dat0[dw_a][2] <= dw_d[23:16];
            if (dw_be[3]) dat0[dw_a][3] <= dw_d[31:24];
        end
        q0 <= dat0[rd_a];
    end
    always_ff @(posedge clk) begin
        if (dw_en && dw_way) begin
            if (dw_be[0]) dat1[dw_a][0] <= dw_d[7:0];
            if (dw_be[1]) dat1[dw_a][1] <= dw_d[15:8];
            if (dw_be[2]) dat1[dw_a][2] <= dw_d[23:16];
            if (dw_be[3]) dat1[dw_a][3] <= dw_d[31:24];
        end
        q1 <= dat1[rd_a];
    end
    always_ff @(posedge clk) begin
        if (tw_en && !dw_way) tag0[tw_a] <= tw_d;
        if (tw_en &&  dw_way) tag1[tw_a] <= tw_d;
        t0 <= tag0[rd_a[10:3]];
        t1 <= tag1[rd_a[10:3]];
    end
    // The valid bits are flops, so a flush can clear them all at once, but
    // the compare takes them half as it takes the tags.  The edge before it
    // reads the 16 sets the request's address picks with [12:9], and the
    // compare picks its set from those with r_va[8:5], beside the tag
    // compare.  Indexed by r_va in the compare cycle alone, the bits were a
    // 256-to-1 mux in front of the hit, the stall and everything behind it,
    // 2.2 ns too slow at 80 MHz; read whole at the edge before, the same mux
    // sat behind the CPU's address adder, 0.4 ns too slow.  None of them
    // changes at an edge that reads one for a compare: a fill sets its bit
    // the edge before S_REPLAY reads, a flush clears them the edge before
    // S_DONE takes the next request, and a miss clears its victim's in a
    // compare that takes none.
    always_ff @(posedge clk) begin
        vg0 <= val0[16*int'(rd_a[10:7]) +: 16];
        vg1 <= val1[16*int'(rd_a[10:7]) +: 16];
    end

    // ------------------------------------------------------------ the request
    typedef enum logic [3:0] {
        S_IDLE,         // compare when `look`
        S_REPLAY,       // read the RAMs again for r_*; compare next
        S_WBRD,         // read a line to write back, word by word
        S_WB,           // write it back
        S_GAP,          // m_req low for a cycle between two requests
        S_FILL,         // fetch the line
        S_FWR,          // write it, word by word
        S_UNC,          // an uncached word
        S_DONE,         // complete r_* from u_q / u_flt
        S_WALK,         // a clean or a flush: the next set with a dirty line
        S_WTAG,         // its tags are out
        S_WCF           // write the combining buffer out, then `after`
    } st_t;
    st_t st;

    logic        r_v, r_we, r_abt, look;
    logic [31:0] r_va, r_wd;
    logic  [3:0] r_be;
    region_t     r_rg;
    wire  [7:0]  r_set = r_va[12:5];

    // ------------------------------------------------------------ compare
    wire [TAGW-1:0] r_tag = vtag_of(r_va, win_id);
    wire  hit0 = vg0[r_va[8:5]] && t0[TAGW+PAW-1:PAW] == r_tag;
    wire  hit1 = vg1[r_va[8:5]] && t1[TAGW+PAW-1:PAW] == r_tag;
    wire  hit  = hit0 || hit1;

    // the store bypass: the word written at the edge that read this one
    logic        byp_v, byp_w;
    logic [10:0] byp_a;
    logic  [3:0] byp_be;
    logic [31:0] byp_d;
    function automatic logic [31:0] merge(input logic [31:0] old, input logic [3:0] be, input logic [31:0] d);
        for (int b = 0; b < 4; b++) if (be[b]) old[8*b +: 8] = d[8*b +: 8];
        return old;
    endfunction
    wire  byp   = byp_v && byp_a == r_va[12:2];
    wire [31:0] q0m = byp && !byp_w ? merge(q0, byp_be, byp_d) : q0;
    wire [31:0] q1m = byp &&  byp_w ? merge(q1, byp_be, byp_d) : q1;

    logic        clean_pend, flushing, walking;
    wire  cmp     = st == S_IDLE && look && !clean_pend;
    wire  is_io   = r_rg == RG_IO;
    wire  is_fl   = is_io && r_we && r_va[11:2] == IO_CACHE_FLUSH;
    wire  is_unc  = r_rg == RG_PHYS || r_rg == RG_DRIVE;
    wire  is_c    = !r_abt && !is_io && !is_unc;
    wire  st_hit  = cmp && is_c && hit && r_we;

    logic [31:0] u_q;
    logic        u_flt;

    // ------------------------------------------------------------ the combining buffer
    logic         wc_v;
    logic  [26:0] wc_line;              // va[31:5]
    logic [255:0] wc_d;
    logic  [31:0] wc_m;
    wire  wc_hit  = wc_v && wc_line == r_va[31:5];
    wire  unc_st  = is_unc && r_we;
    wire  unc_now = unc_st && (!wc_v || wc_hit);      // a store the buffer takes now
    wire  [31:0] be_line = 32'(r_be) << {r_va[4:2], 2'b00};

    // what follows S_WCF
    typedef enum logic [2:0] { A_STORE, A_UNC, A_MISS, A_CLEAN, A_FLUSH } after_t;
    after_t after;

    always_comb begin
        dc_ok    = 1'b0;
        dc_abort = 1'b0;
        dc_rdata = hit1 ? q1m : q0m;
        if (st == S_DONE) begin
            dc_ok = 1'b1; dc_abort = u_flt; dc_rdata = u_q;
        end else if (cmp) begin
            if (r_abt)                    begin dc_ok = 1'b1; dc_abort = 1'b1; end
            else if (is_io)               begin dc_ok = !is_fl; dc_rdata = io_rdata; end
            else if (is_c)                dc_ok = hit;
            else                          dc_ok = unc_now;
        end
    end

    assign io_req   = cmp && is_io && !r_abt && !is_fl;
    assign io_we    = r_we;
    assign io_off   = r_va[11:2];
    assign io_wdata = r_wd;

    // ------------------------------------------------------------ the miss side
    logic        mway;              // the way being filled or written back
    logic        mdty;              // ... and whether it is to be written back first
    logic  [7:0] mset;
    logic [PAW-1:0] mpa;            // its bus line, for a write-back
    logic [255:0] wb_d;             // the line to write back
    logic  [3:0] k;                 // word counter, 0..8
    logic  [7:0] ws;                // the walk's set
    st_t         gap_next;          // where S_GAP goes

    wire  vict  = !val0[r_set] ? 1'b0 : !val1[r_set] ? 1'b1 : lru[r_set];
    wire  vdty  = vict ? val1[r_set] && dty1[r_set] : val0[r_set] && dty0[r_set];

    assign m_req = st == S_WB || st == S_FILL || st == S_FWR || st == S_UNC || st == S_WCF;
    always_comb begin
        case (st)
            S_WB:    m_cmd = MC_WB;
            S_UNC:   m_cmd = MC_URD;
            S_WCF:   m_cmd = MC_WCB;
            default: m_cmd = MC_FILL;
        endcase
        m_va    = st == S_WCF ? {wc_line, 5'd0} : r_va;
        m_pa    = {mpa, 5'd0};
        m_be    = wc_m;
        m_wline = st == S_WCF ? wc_d : wb_d;
    end

    // the RAMs' read address: the new request's, else the one the state needs
    always_comb begin
        case (st)
            S_REPLAY: rd_a = r_va[12:2];
            S_WBRD:   rd_a = {mset, k[2:0]};
            S_WALK:   rd_a = {ws, 3'd0};
            default:  rd_a = dc_addr[12:2];
        endcase
    end

    // writes: a store hit, or a fill
    always_comb begin
        dw_en  = st_hit || st == S_FWR;
        dw_way = st == S_FWR ? mway : hit1;
        dw_a   = st == S_FWR ? {mset, k[2:0]} : r_va[12:2];
        dw_d   = st == S_FWR ? m_rline[32*k[2:0] +: 32] : r_wd;
        dw_be  = st == S_FWR ? 4'hF : r_be;
        tw_en  = st == S_FWR && k == 4'd7;
        tw_a   = mset;
        tw_d   = {vtag_of(r_va, win_id), m_fill_pa[26:5]};
    end

    wire  dsome = dty0[ws] || dty1[ws];
    wire  [2:0] kp = 3'(k - 4'd1);      // the word S_WBRD has out

    // a miss: its victim, and where it goes first
    task automatic start_miss();
        mway <= vict; mset <= r_set; mdty <= vdty;
        mpa  <= vict ? t1[PAW-1:0] : t0[PAW-1:0];
        if (vict) val1[r_set] <= 1'b0; else val0[r_set] <= 1'b0;
        k <= 4'd0;
    endtask

    always_ff @(posedge clk) begin
        // ---- taking a request: always, the CPU asks only when it may
        if (dc_req) begin
            r_v <= 1'b1; r_we <= dc_we; r_va <= dc_addr; r_wd <= dc_wdata; r_be <= dc_be;
            r_rg  <= region_of(dc_addr);
            r_abt <= region_of(dc_addr) == RG_NONE || (region_of(dc_addr) == RG_ROM && dc_we);
        end else if (dc_ok) r_v <= 1'b0;
        // a compare next cycle if the RAMs read for it now and nothing else is due
        look <= (dc_req && (st == S_DONE || (st == S_IDLE && !clean_pend))) || st == S_REPLAY;

        if (clean) clean_pend <= 1'b1;

        // store hits: the bypass, dirty, LRU
        byp_v <= st_hit;
        if (st_hit) begin
            byp_a <= r_va[12:2]; byp_w <= hit1; byp_be <= r_be; byp_d <= r_wd;
            if (hit1) dty1[r_set] <= 1'b1; else dty0[r_set] <= 1'b1;
        end
        if (cmp && is_c && hit) lru[r_set] <= hit0;

        // an uncached store into the buffer, now or after it is written out
        if ((cmp && unc_now && !r_abt) || (st == S_WCF && m_done && after == A_STORE)) begin
            if (!wc_hit || st == S_WCF) begin
                wc_line <= r_va[31:5]; wc_m <= be_line;
            end else wc_m <= wc_m | be_line;
            wc_v <= 1'b1;
            for (int b = 0; b < 4; b++)
                if (r_be[b]) wc_d[32*int'(r_va[4:2]) + 8*b +: 8] <= r_wd[8*b +: 8];
        end

        case (st)
            S_IDLE: begin
                if (cmp && is_fl) begin
                    ws <= 8'd0; flushing <= 1'b1; walking <= 1'b1;
                    if (wc_v) begin st <= S_WCF; after <= A_FLUSH; end
                    else st <= S_WALK;
                end else if (cmp && is_unc && !r_abt && !unc_now) begin
                    // a load, or a store for another line: the buffer goes first
                    if (wc_v) begin st <= S_WCF; after <= unc_st ? A_STORE : A_UNC; end
                    else st <= S_UNC;
                end else if (cmp && is_c && !hit) begin
                    start_miss();
                    if (wc_v) begin st <= S_WCF; after <= A_MISS; end
                    else st <= vdty ? S_WBRD : S_FILL;
                end else if (clean_pend) begin
                    // a request in its compare is kept, and read again after
                    ws <= 8'd0; flushing <= 1'b0; walking <= 1'b1;
                    if (wc_v) begin st <= S_WCF; after <= A_CLEAN; end
                    else st <= S_WALK;
                end
            end
            S_REPLAY: st <= S_IDLE;
            S_WCF: if (m_done) begin
                wc_v <= after == A_STORE;
                case (after)
                    A_STORE: st <= S_DONE;
                    A_UNC:   begin st <= S_GAP; gap_next <= S_UNC; end
                    A_MISS:  begin st <= S_GAP; gap_next <= mdty ? S_WBRD : S_FILL; end
                    default: st <= S_WALK;
                endcase
            end
            S_WBRD: begin
                // read word k at this edge; word k-1 is out now
                if (k != 4'd0) wb_d[32*kp +: 32] <= mway ? q1 : q0;
                k <= k + 4'd1;
                if (k == 4'd8) st <= S_WB;
            end
            S_WB: if (m_done) begin
                st <= S_GAP;
                gap_next <= walking ? S_WALK : S_FILL;
                if (mway) dty1[mset] <= 1'b0; else dty0[mset] <= 1'b0;
            end
            S_GAP: begin st <= gap_next; k <= 4'd0; end
            S_FILL: if (m_done) begin
                k <= 4'd0;
                if (m_fault) begin u_flt <= 1'b1; u_q <= 32'd0; st <= S_DONE; end
                else st <= S_FWR;
            end
            S_FWR: begin
                k <= k + 4'd1;
                if (k == 4'd7) begin
                    if (mway) begin val1[mset] <= 1'b1; dty1[mset] <= 1'b0; end
                    else      begin val0[mset] <= 1'b1; dty0[mset] <= 1'b0; end
                    lru[mset] <= !mway;
                    st <= S_REPLAY;
                end
            end
            S_UNC: if (m_done) begin
                u_q <= m_rline[31:0]; u_flt <= m_fault; st <= S_DONE;
            end
            S_DONE: begin
                st <= S_IDLE; u_flt <= 1'b0;
            end
            S_WALK: begin
                // the tags of set ws are read at this edge
                if (dsome) st <= S_WTAG;
                else if (ws != 8'd255) ws <= ws + 8'd1;
                else begin
                    // the walk is over
                    clean_pend <= 1'b0; walking <= 1'b0;
                    if (flushing) begin
                        val0 <= '0; val1 <= '0; dty0 <= '0; dty1 <= '0;
                        flushing <= 1'b0;
                        st <= S_DONE;
                    end else st <= r_v ? S_REPLAY : S_IDLE;
                end
            end
            S_WTAG: begin
                mway <= !dty0[ws]; mset <= ws;
                mpa  <= dty0[ws] ? t0[PAW-1:0] : t1[PAW-1:0];
                k <= 4'd0;
                st <= S_WBRD;
            end
            default: st <= S_IDLE;
        endcase

        if (rst) begin
            st <= S_IDLE; r_v <= 1'b0; look <= 1'b0; byp_v <= 1'b0; wc_v <= 1'b0;
            val0 <= '0; val1 <= '0; dty0 <= '0; dty1 <= '0; lru <= '0;
            clean_pend <= 1'b0; flushing <= 1'b0; walking <= 1'b0; u_flt <= 1'b0;
        end
    end
    assign inv_i = st == S_WALK && !dsome && ws == 8'd255 && flushing;
endmodule

`default_nettype wire
