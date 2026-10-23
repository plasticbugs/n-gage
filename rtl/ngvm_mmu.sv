//------------------------------------------------------------------------------
// The miss handler: the page table, the translation of a virtual address to a
// bus address, and the one bus request at a time that both caches share
// (docs/core-design.md 3, 4).
//
// The table is NGVM's (docs/hardware.md 4): 16,640 entries of a 16 KB RAM
// page each, in block RAM, written by the kernel through IO_PT_INDEX and
// IO_PT_DATA.  After reset it is all NGVM_PT_NONE: `ready` stays low while a
// counter writes every entry, and ngvm_sys holds the CPU until it rises, so
// a core reset never leaves the last run's mappings behind.
//
// A requester holds its req until it has used the answer; the handler waits
// for the drop before it takes the next, so the bus's read data (held until
// the next bus request) is still there while a cache copies a line out of it.
// The D-cache goes first when both ask.  The answer is the bus's done itself,
// the next request is taken at the edge the last one is let go, and the
// table is read at the edge that takes a request, so a paged address is on
// the bus two clocks after it is taken, as a flat one is.
//
// A fill asks for its line at the word the cache missed on, which the bus
// brings first, and i_words / d_words count the words of the line that are
// in rline so far (the critical word first, then on round the line), from
// the bus request until the requester lets go.  A D-cache fill with d_wb
// also writes d_wline back to d_pa's line, after the read (BC_RDWR).
//------------------------------------------------------------------------------
`default_nettype none

module ngvm_mmu
    import ngvm_pkg::*;
(
    input  logic         clk,
    input  logic         rst,
    output logic         ready,         // the table is cleared

    input  logic         pt_we,
    input  logic  [14:0] pt_idx,
    input  logic  [15:0] pt_data,

    // the I-cache: line fills
    input  logic         i_req,
    input  logic  [31:0] i_va,
    output logic         i_done,
    output logic         i_fault,

    // the D-cache: fills, write-backs, uncached loads, its combining buffer (MC_*)
    input  logic         d_req,
    input  logic   [1:0] d_cmd,
    input  logic         d_wb,          // MC_FILL: write d_wline back to d_pa's line, after
    input  logic         d_wbrdy,       // d_wline is whole (the D-cache reads it during the fill)
    input  logic  [31:0] d_va,
    input  logic  [26:0] d_pa,
    input  logic  [31:0] d_be,
    input  logic [255:0] d_wline,
    output logic         d_done,
    output logic         d_fault,
    output logic  [26:0] d_fill_pa,
    output logic         d_xok,         // a D-cache request is on the bus: translated, no fault

    output logic [255:0] rline,         // the answer to either, from the bus
    output logic   [3:0] i_words,       // words of a fill's line in rline, 0-8
    output logic   [3:0] d_words,

    // the bus (ngvm_sys's port): bus_req held until bus_done
    output logic         bus_req,
    output logic   [1:0] bus_cmd,       // BC_*
    output logic  [26:0] bus_addr,
    output logic  [26:5] bus_waddr,     // BC_RDWR's write-back
    output logic  [31:0] bus_be,
    output logic [255:0] bus_wdata,
    input  logic         bus_done,
    input  logic [255:0] bus_rdata,
    input  logic   [3:0] bus_cnt        // words read in, from any count (ngvm_xbus.sv)
);
    localparam logic [1:0] MC_FILL = 2'd0, MC_WB = 2'd1, MC_URD = 2'd2, MC_WCB = 2'd3;

    // ------------------------------------------------------------ the table
    logic [15:0] pt [0:PT_ENTRIES-1];
    logic [14:0] clr;                   // the entry reset is clearing
    logic [14:0] pt_ra;
    logic [15:0] pt_q;
    always_ff @(posedge clk) begin
        if (!ready)     pt[clr] <= PT_NONE;
        else if (pt_we) pt[pt_idx] <= pt_data;
        pt_q <= pt[pt_ra];
    end
    always_ff @(posedge clk) begin
        if (rst) begin
            clr <= 15'd0; ready <= 1'b0;
        end else if (!ready) begin
            clr <= clr + 15'd1;
            if (clr == 15'(PT_ENTRIES - 1)) ready <= 1'b1;
        end
    end

    // ------------------------------------------------------------ requests
    typedef enum logic [2:0] { S_IDLE, S_XLATE, S_BUS, S_RESP, S_HOLD } st_t;
    st_t         st;
    logic        who_d, fault, wb;
    logic  [1:0] cmd;
    logic [31:0] va;
    region_t     rg;
    assign rg = region_of(va);

    // what a fetch may come from: anything cached, and RAM by its alias
    wire  i_ok_rg = cached_rg(rg) || rg == RG_PHYS;
    wire  d_ok_rg = cmd == MC_FILL ? cached_rg(rg) : rg == RG_PHYS || rg == RG_DRIVE;
    wire  ok_rg   = who_d ? d_ok_rg : i_ok_rg;

    // a request is taken when idle, or as the one answered is let go
    wire  take    = ready && (st == S_IDLE || (st == S_HOLD && (who_d ? !d_req : !i_req)));
    assign pt_ra  = pt_index_of(take ? (d_req ? d_va : i_va) : va);
    assign rline   = bus_rdata;
    // A fill's victim must be whole before the bus is asked: the memory side
    // takes the fields when it takes the request (ngvm_xbus.sv), and the
    // D-cache reads the victim out while the address is translated.
    assign bus_req = st == S_BUS && !(wb && !d_wbrdy);
    assign bus_be  = cmd == MC_WCB ? d_be : 32'hFFFF_FFFF;
    assign bus_wdata = d_wline;
    always_comb begin
        case (cmd)
            MC_WB:   bus_cmd = BC_WRLINE;
            MC_WCB:  bus_cmd = BC_WRLINE;
            MC_URD:  bus_cmd = BC_RDWORD;
            default: bus_cmd = wb ? BC_RDWR : BC_RDLINE;
        endcase
    end

    // the words in so far: the count since the request went out
    logic [3:0] wbase;
    wire        on_bus = st == S_BUS || st == S_RESP || st == S_HOLD;
    always_ff @(posedge clk) if (!on_bus || take) wbase <= bus_cnt;
    wire  [3:0] words  = on_bus ? bus_cnt - wbase : 4'd0;
    assign i_words = who_d ? 4'd0 : words;
    assign d_words = who_d ? words : 4'd0;

    wire   done      = st == S_RESP || (st == S_BUS && bus_done);
    assign i_done    = done && !who_d;
    assign d_done    = done &&  who_d;
    assign i_fault   = fault;
    assign d_fault   = fault;
    assign d_fill_pa = bus_addr;
    assign d_xok     = st == S_BUS && who_d;

    always_ff @(posedge clk) begin
        case (st)
            S_IDLE, S_HOLD: if (take) begin
                st <= S_IDLE;
                if (d_req) begin
                    who_d <= 1'b1; cmd <= d_cmd; va <= d_va; fault <= 1'b0;
                    wb <= d_cmd == MC_FILL && d_wb; bus_waddr <= d_pa[26:5];
                    if (d_cmd == MC_WB) begin
                        bus_addr <= {d_pa[26:5], 5'd0};
                        st <= S_BUS;
                    end else st <= S_XLATE;
                end else if (i_req) begin
                    who_d <= 1'b0; cmd <= MC_FILL; va <= i_va; fault <= 1'b0; wb <= 1'b0;
                    st <= S_XLATE;
                end
            end
            S_XLATE: begin
                // the table was read at the edge that took the request
                if (!ok_rg || (paged_rg(rg) && pt_q == PT_NONE)) begin
                    fault <= 1'b1; st <= S_RESP;
                end else if (paged_rg(rg)) begin
                    bus_addr <= bus_paged(pt_q, va);
                    st <= S_BUS;
                end else begin
                    bus_addr <= bus_flat(rg, va);
                    st <= S_BUS;
                end
            end
            S_BUS: if (bus_done) st <= S_HOLD;      // answered (done)
            S_RESP: st <= S_HOLD;                   // a fault, answered
            default: st <= S_IDLE;
        endcase
        // a fill goes out at the word missed on, a write aligned to its line,
        // a word read to its word
        if (st == S_XLATE)
            if (cmd == MC_URD || cmd == MC_FILL) bus_addr[1:0] <= 2'd0; else bus_addr[4:0] <= 5'd0;
        if (rst) st <= S_IDLE;
    end
endmodule

`default_nettype wire
