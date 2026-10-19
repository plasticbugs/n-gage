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
// The D-cache goes first when both ask.
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
    input  logic  [31:0] d_va,
    input  logic  [26:0] d_pa,
    input  logic  [31:0] d_be,
    input  logic [255:0] d_wline,
    output logic         d_done,
    output logic         d_fault,
    output logic  [26:0] d_fill_pa,

    output logic [255:0] rline,         // the answer to either, from the bus

    // the bus (ngvm_sys's port): bus_req held until bus_done
    output logic         bus_req,
    output logic   [1:0] bus_cmd,       // BC_*
    output logic  [26:0] bus_addr,
    output logic  [31:0] bus_be,
    output logic [255:0] bus_wdata,
    input  logic         bus_done,
    input  logic [255:0] bus_rdata
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
    typedef enum logic [2:0] { S_IDLE, S_XLATE, S_PT, S_BUS, S_RESP, S_HOLD } st_t;
    st_t         st;
    logic        who_d, fault;
    logic  [1:0] cmd;
    logic [31:0] va;
    region_t     rg;
    assign rg = region_of(va);

    // what a fetch may come from: anything cached, and RAM by its alias
    wire  i_ok_rg = cached_rg(rg) || rg == RG_PHYS;
    wire  d_ok_rg = cmd == MC_FILL ? cached_rg(rg) : rg == RG_PHYS || rg == RG_DRIVE;
    wire  ok_rg   = who_d ? d_ok_rg : i_ok_rg;

    assign pt_ra   = pt_index_of(va);
    assign rline   = bus_rdata;
    assign bus_req = st == S_BUS;
    assign bus_be  = cmd == MC_WCB ? d_be : 32'hFFFF_FFFF;
    assign bus_wdata = d_wline;
    always_comb begin
        case (cmd)
            MC_WB:   bus_cmd = BC_WRLINE;
            MC_WCB:  bus_cmd = BC_WRLINE;
            MC_URD:  bus_cmd = BC_RDWORD;
            default: bus_cmd = BC_RDLINE;
        endcase
    end

    assign i_done    = st == S_RESP && !who_d;
    assign d_done    = st == S_RESP &&  who_d;
    assign i_fault   = fault;
    assign d_fault   = fault;
    assign d_fill_pa = bus_addr;

    always_ff @(posedge clk) begin
        case (st)
            S_IDLE: if (ready) begin
                if (d_req) begin
                    who_d <= 1'b1; cmd <= d_cmd; va <= d_va; fault <= 1'b0;
                    if (d_cmd == MC_WB) begin
                        bus_addr <= {d_pa[26:5], 5'd0};
                        st <= S_BUS;
                    end else st <= S_XLATE;
                end else if (i_req) begin
                    who_d <= 1'b0; cmd <= MC_FILL; va <= i_va; fault <= 1'b0;
                    st <= S_XLATE;
                end
            end
            S_XLATE: begin
                // the table is read at this edge whether or not it is needed
                if (!ok_rg) begin
                    fault <= 1'b1; st <= S_RESP;
                end else if (paged_rg(rg)) st <= S_PT;
                else begin
                    bus_addr <= bus_flat(rg, va);
                    st <= S_BUS;
                end
            end
            S_PT: begin
                if (pt_q == PT_NONE) begin
                    fault <= 1'b1; st <= S_RESP;
                end else begin
                    bus_addr <= bus_paged(pt_q, va);
                    st <= S_BUS;
                end
            end
            S_BUS: if (bus_done) st <= S_RESP;
            S_RESP: st <= S_HOLD;
            S_HOLD: if (who_d ? !d_req : !i_req) st <= S_IDLE;
            default: st <= S_IDLE;
        endcase
        // line commands go out aligned to the line, word commands to the word
        if (st == S_XLATE || st == S_PT)
            if (cmd == MC_URD) bus_addr[1:0] <= 2'd0; else bus_addr[4:0] <= 5'd0;
        if (rst) st <= S_IDLE;
    end
endmodule

`default_nettype wire
