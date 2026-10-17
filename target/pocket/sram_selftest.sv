//------------------------------------------------------------------------------
// The power-on SRAM test (docs/bringup.md, panel row 3).  From the Smash TV
// core, where it was written after its first release damaged a CMOS word;
// here the two addresses are parameters.
//
// Two known words go into the SRAM and come back out before the core is let
// out of reset, and what came back is shown on the panel: A55A 5AA5 is a pass.
// A55A and 5AA5 are each other's byte-swap and nibble inverse, so a stuck bit,
// a swapped byte lane and a dead bus all read differently from a pass.
//
// WHAT WAS THERE IS PUT BACK.  On NBA Jam the SRAM holds the sound CPU's
// program, written by the download just before this test runs, and every one
// of its 64K words is used.  The first hardware build wrote the test words to
// 0x1fffe/0x1ffff through a 16-bit port, so they landed on 0xfffe/0xffff --
// the 6809's NMI and RESET vectors -- and did not put them back: the sound
// CPU started at 0x5AA5 and the machine was silent, while the panel read a
// pass.  Here the originals are read first and written back last.
//
// A port that never acknowledges would leave the core in reset for good and
// the panel showing nothing, which looks the same as a memory that answers
// wrongly; so it gives up after a millisecond, the read-backs stay zero, and
// the core runs and says so.
//------------------------------------------------------------------------------
`default_nettype none
module sram_selftest #(
    parameter logic [16:0] A0 = 17'h00000,
    parameter logic [16:0] A1 = 17'h10000
) (
    input  logic        clk,
    input  logic        hold,           // the memories are not ready: start over
    output logic        req, we,
    output logic [16:0] addr,
    output logic [15:0] d,
    input  logic        ack,
    input  logic [15:0] q,
    output logic        done,
    output logic [15:0] rd0, rd1
);
    localparam logic [15:0] T0 = 16'hA55A, T1 = 16'h5AA5;

    logic  [3:0] st;                    // even: raise a request; odd: wait for its ack
    logic [15:0] o0, o1;                // what was there
    logic [16:0] tmo;

    always_ff @(posedge clk) begin
        if (hold) begin
            st <= 4'd0; done <= 1'b0; req <= 1'b0; we <= 1'b0;
            rd0 <= '0; rd1 <= '0; tmo <= '0;
        end else if (!done) begin
            tmo <= tmo + 17'd1;
            if (&tmo) begin done <= 1'b1; req <= 1'b0; end     // ~1.4 ms at 96 MHz
            else if (!st[0]) begin
                req <= 1'b1;
                unique case (st[3:1])
                    3'd0: begin we <= 1'b0; addr <= A0; end
                    3'd1: begin we <= 1'b0; addr <= A1; end
                    3'd2: begin we <= 1'b1; addr <= A0; d <= T0; end
                    3'd3: begin we <= 1'b1; addr <= A1; d <= T1; end
                    3'd4: begin we <= 1'b0; addr <= A0; end
                    3'd5: begin we <= 1'b0; addr <= A1; end
                    3'd6: begin we <= 1'b1; addr <= A0; d <= o0; end
                    3'd7: begin we <= 1'b1; addr <= A1; d <= o1; end
                endcase
                st <= st + 4'd1;
            end else if (ack) begin
                req <= 1'b0;
                unique case (st[3:1])
                    3'd0: o0  <= q;
                    3'd1: o1  <= q;
                    3'd4: rd0 <= q;
                    3'd5: rd1 <= q;
                    default: ;
                endcase
                if (st == 4'd15) done <= 1'b1;
                else             st <= st + 4'd1;
            end
        end
    end
endmodule
`default_nettype wire
