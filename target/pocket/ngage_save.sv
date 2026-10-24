//------------------------------------------------------------------------------
// The game's save, C: (sw/include/ngvm_hw.h, NGVM_SAVE_BASE), read out to
// the Pocket when it writes the save slot back (data.json slot 4, bridge
// address 0x20000000).  The save is the top MB of NGVM's RAM, in SDRAM; the
// kernel reaches it uncached, so SDRAM holds what was last written.
//
// The bridge reads a word a transaction, and samples the answer to one read
// early in the next (io_bridge_peripheral.sv; the template's data_unloader
// answers the same way): too soon for a read queued behind the CPU's and the
// LCD's bursts, and the bridge cannot be made to wait.  So every word is
// fetched before it is asked for, 32 halfwords a burst, and each read is
// answered from a buffer:
//
//   - the head, words 0-63, always held, so a readout's first reads are
//     answered at once wherever the last readout stopped;
//   - the ring, the 2^RB words from the last read on, from word 64: fetched
//     ahead as the readout goes, and kept where it is when the Pocket
//     pauses partway.  256 words carry a readout over some 100 us of a
//     memory port that does not answer (sim/run_save.sh).
//
// Both are fetched again once a write to C: (save_t, or a load into the
// slot) has had SETTLE clocks to land in SDRAM and no read has come for
// QUIET clocks: not while a readout streams, which would empty the ring
// under it.  A readout that a write overtakes gets a word as it was before
// the write or after, as a file copied while it is written does; the core
// writes the slot again once the write has settled (core_top).  A read the
// buffers do not hold (none, in a readout that runs from word 0 up) moves
// the ring there, and is answered when its burst is in: late, if the bridge
// has not waited.
//
// The fetches share the LCD's port to ngage_mem (l_*): the owner is latched
// at grant and l_done routed by it (METHODOLOGY 5.17), turn about.
//------------------------------------------------------------------------------
`default_nettype none

module ngage_save #(
    parameter logic [25:1] BASE   = 25'h0F80000,  // the save's first halfword: bus 0x1F00000
    parameter int          WORDS  = 262144,       // 1 MB
    parameter int          RB     = 8,            // the ring: 2^RB words
    parameter int          SETTLE = 4096,         // clocks from a write to C: to fetching it
    parameter int          QUIET  = 2048          // clocks without a read before then
) (
    // the APF bridge
    input  logic        clk_74a,
    input  logic        bridge_rd,
    input  logic        bridge_endian_little,
    input  logic [31:0] bridge_addr,
    output logic [31:0] bridge_rd_data,

    input  logic        clk,                // ngage_mem's
    input  logic        rst,                // the memories', not the core's: a readout
                                            // may come while the core is held in reset
    input  logic        dl_active,          // a slot is loading (clk)
    input  logic        save_t,             // toggles at each write to C: (any domain)

    // the LCD's port, passed through
    input  logic        a_req,
    input  logic [25:1] a_addr,
    input  logic  [5:0] a_len,
    output logic        a_wr,
    output logic  [4:0] a_idx,
    output logic [15:0] a_data,
    output logic        a_done,

    // to ngage_mem's l_* port
    output logic        l_req,
    output logic [25:1] l_addr,
    output logic  [5:0] l_len,
    input  logic        l_wr,
    input  logic  [4:0] l_idx,
    input  logic [15:0] l_data,
    input  logic        l_done
);
    localparam int WB = $clog2(WORDS) + 1;  // word numbers, with room above WORDS
    localparam int RING = 1 << RB;

    // ------------------------------------------------------------ the bridge
    // a read at 0x2xxxxxxx asks for its word; the word number is held until
    // the next read, microseconds later
    logic          rd_d, q_t;                // power up at 0, as every flop here
    logic [WB-2:0] q_w;
    always_ff @(posedge clk_74a) begin
        rd_d <= bridge_rd;
        if (bridge_rd && !rd_d && bridge_addr[31:28] == 4'h2) begin
            q_w <= bridge_addr[WB:2];
            q_t <= !q_t;
        end
    end
    // the answer, then a toggle; the answer holds still while the toggle crosses
    logic [31:0] ans;
    logic        ans_t;
    logic  [2:0] ans_s;
    always_ff @(posedge clk_74a) begin
        ans_s <= {ans_s[1:0], ans_t};
        if (ans_s[2] != ans_s[1])
            bridge_rd_data <= bridge_endian_little ? ans : {ans[7:0], ans[15:8], ans[23:16], ans[31:24]};
    end

    // ------------------------------------------------------------ the port
    typedef enum logic [1:0] { O_NONE, O_LCD, O_SAVE } own_t;
    own_t own;
    logic last_save, busy;
    logic [WB-1:0] bb;                      // the burst's first word
    // between bursts the turn's request goes out in the clock it is chosen,
    // so that with no save to fetch the port sees the LCD's own signals
    wire  pick_lcd  = a_req && (!busy || last_save);
    wire  as_save   = own == O_SAVE || (own == O_NONE && !pick_lcd && busy);
    always_ff @(posedge clk) begin
        if (rst) begin own <= O_NONE; last_save <= 1'b0; end
        else case (own)
            O_NONE: if (pick_lcd) begin own <= O_LCD; last_save <= 1'b0; end
                    else if (busy) begin own <= O_SAVE; last_save <= 1'b1; end
            default: if (l_done) own <= O_NONE;
        endcase
    end
    assign l_req  = as_save || (own != O_SAVE && a_req);
    assign l_addr = as_save ? BASE + 25'({bb[WB-2:0], 1'b0}) : a_addr;
    assign l_len  = as_save ? 6'd32 : a_len;
    assign a_wr   = l_wr && own == O_LCD;
    assign a_idx  = l_idx;
    assign a_data = l_data;
    assign a_done = l_done && own == O_LCD;
    wire   s_wr   = l_wr && own == O_SAVE;
    wire   s_done = l_done && own == O_SAVE;

    // ------------------------------------------------------------ the buffers
    // entry {1, x} holds head word x, {0, x mod 2^RB} ring word x; the
    // halfword at the lower address is the word's low half (the file's
    // byte order)
    logic        bk;                        // the burst fills the head
    logic [15:0] buf_lo [0:2*RING-1], buf_hi [0:2*RING-1];
    wire  [RB:0] wi = {bk, RB'(bb) + RB'(l_idx[4:1])};
    always_ff @(posedge clk) begin
        if (s_wr && !l_idx[0]) buf_lo[wi] <= l_data;
        if (s_wr &&  l_idx[0]) buf_hi[wi] <= l_data;
    end

    // ------------------------------------------------------------ fetching
    logic  [2:0]   q_s, sv_s;
    logic [WB-1:0] f, lo, want, w, rs;      // the ring holds [lo, f); kept to want + 2^RB - 1
    logic  [6:0]   hf;                      // the head holds [0, hf) as SDRAM has it
    logic          ask, restart, dirty, rd_v, rd_v2;
    logic [12:0]   settle_n;
    logic [11:0]   quiet_n;
    logic  [RB:0]  rd_a;
    logic [15:0]   q_lo, q_hi;
    wire           new_q = q_s[2] != q_s[1];
    wire [WB-1:0]  qw    = {1'b0, q_w};
    wire [WB-1:0]  qt    = qw < WB'(64) ? WB'(64) : qw;    // where the ring must be for it
    wire           head  = w < WB'(64);
    wire           hit   = head ? {1'b0, w[5:0]} < hf : !restart && w >= lo && w < f;
    always_ff @(posedge clk) begin
        q_s  <= {q_s[1:0], q_t};
        sv_s <= {sv_s[1:0], save_t};
        if (settle_n != 13'(SETTLE)) settle_n <= settle_n + 13'd1;
        if (quiet_n != 12'(QUIET)) quiet_n <= quiet_n + 12'd1;
        if (dl_active || sv_s[2] != sv_s[1]) begin dirty <= 1'b1; settle_n <= '0; end

        // a read: answered from the buffers, at once or when its burst is in
        if (new_q) begin
            w <= qw; ask <= 1'b1; want <= qt; quiet_n <= '0;
            if (qt < lo || qt >= f + WB'(32)) begin restart <= 1'b1; rs <= qt; end
        end
        rd_v <= 1'b0;
        if (ask && !new_q && hit) begin rd_a <= head ? {1'b1, RB'(w[5:0])} : {1'b0, w[RB-1:0]}; rd_v <= 1'b1; ask <= 1'b0; end
        q_lo  <= buf_lo[rd_a];
        q_hi  <= buf_hi[rd_a];
        rd_v2 <= rd_v;
        if (rd_v2) begin ans <= {q_hi, q_lo}; ans_t <= !ans_t; end

        // one burst at a time.  Once a write to C: has landed, both buffers
        // again; then a move of the ring, the ring's next words, the head,
        // and the ring ahead
        if (s_done) begin
            busy <= 1'b0;
            if (bk) hf <= hf + 7'd16;
            else    f  <= f + WB'(16);
        end
        if (!busy && !new_q) begin
            if (dirty && settle_n == 13'(SETTLE) && quiet_n == 12'(QUIET) && !ask) begin
                dirty <= 1'b0; hf <= '0; restart <= 1'b1; rs <= want;
            end
            else if (restart) begin f <= rs; lo <= rs; restart <= 1'b0; end
            else if (!hf[6] && !(f < want + WB'(16) && f < WB'(WORDS))) begin
                busy <= 1'b1; bk <= 1'b1; bb <= WB'(hf);
            end
            else if (f < want + WB'(RING - 16) && f < WB'(WORDS)) begin
                busy <= 1'b1; bk <= 1'b0; bb <= f;
                if (f + WB'(16) - lo > WB'(RING)) lo <= f + WB'(16) - WB'(RING);
            end
        end

        if (rst) begin
            f <= WB'(64); lo <= WB'(64); want <= WB'(64); hf <= '0;
            busy <= 1'b0; ask <= 1'b0; restart <= 1'b0; dirty <= 1'b0;
            settle_n <= 13'(SETTLE); quiet_n <= 12'(QUIET); rd_v <= 1'b0; rd_v2 <= 1'b0;
        end
    end
endmodule

`default_nettype wire
