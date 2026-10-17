//------------------------------------------------------------------------------
// First-fault capture for hardware bring-up.
//
// Watches the 68000's bus from outside and freezes on the first exception
// vector it fetches that a healthy run never does: anything in the vector
// table other than the reset pair (0x00-0x07) and the two autovectors the
// board uses, level 4 and 5 (0x70-0x77).  What is kept is which vector it
// was, the two program addresses fetched just before it -- the prefetch runs
// a word or two ahead, so the faulting instruction is at or just behind them
// -- and the last address touched outside the ROM and main RAM.
//
// Whether those come out the same on every power-up is the point: the same
// place every time is a logic or timing fault at one instruction, a different
// place each time is a memory that misreads now and then.
//------------------------------------------------------------------------------
`default_nettype none

module dbg_fault (
    input  logic        clk,
    input  logic        rst,
    input  logic [23:1] addr,
    input  logic        bus,            // a bus cycle is in progress
    output logic        hit,            // something was caught
    output logic  [7:0] vec,            // low byte of the vector's address
    output logic [23:0] pc0, pc1,       // latest and previous code fetch
    output logic [23:0] io,             // last address outside ROM and RAM
    output logic  [7:0] faults          // vector fetches since, saturating
);
    logic        bus_d;
    logic [23:0] h0, h1, hio;
    wire         start   = bus && !bus_d;
    wire [23:0]  a       = {addr, 1'b0};
    wire         is_rom  = (addr[23:19] == 5'd0);
    wire         is_ram  = (addr[23:14] == 10'b00_1000_0000);
    wire         is_vec  = is_rom && (a[18:8] == 11'd0);
    wire         benign  = (a[7:3] == 5'd0) || (a[7:3] == 5'b01110);   // 00-07, 70-77
    wire         bad     = start && is_vec && !benign;

    always_ff @(posedge clk) begin
        bus_d <= bus;
        if (rst) begin
            hit <= 1'b0; faults <= '0; h0 <= '0; h1 <= '0; hio <= '0;
            vec <= '0; pc0 <= '0; pc1 <= '0; io <= '0;     // a clean panel reads all zeros
        end else begin
            if (start) begin
                if (is_rom && !is_vec) begin h1 <= h0; h0 <= a; end
                else if (!is_rom && !is_ram) hio <= a;
            end
            // a vector is two words; count it once, on the even one
            if (bad && !a[1] && !(&faults)) faults <= faults + 8'd1;
            if (bad && !hit) begin
                hit <= 1'b1; vec <= a[7:0]; pc0 <= h0; pc1 <= h1; io <= hio;
            end
        end
    end
endmodule

`default_nettype wire
