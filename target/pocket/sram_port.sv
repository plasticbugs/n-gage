`default_nettype none

//------------------------------------------------------------------------------
// The Pocket's asynchronous SRAM, which this core uses for the tilemap VRAM
// (docs/core-design.md section 2).
//
// Carried over from the Gaiapolis core, where it is proven on hardware. Every
// pin is a register in its IO cell (projects/mycore_pocket.qsf) so the pin
// timing is the same on every build; `slow` and `slow_wr` stretch the read
// capture and the write strobe by a clock and are exposed in the Pocket menu
// as diagnostics.
module sram_port (
    input  logic        clk,
    input  logic        reset,
    input  logic        slow,           // capture one clock later
    input  logic        slow_wr,        // WE low one clock longer, data held one longer
    input  logic        req,
    input  logic        we,
    input  logic [15:0] addr,
    input  logic  [1:0] be,
    input  logic [15:0] wdata,
    output logic        ack,
    output logic [15:0] q,

    output logic [16:0] sram_a,
    inout  wire  [15:0] sram_dq,
    output logic        sram_oe_n, sram_we_n, sram_ub_n, sram_lb_n
);
    typedef enum logic [3:0] { S_IDLE, S_R1, S_R2, S_R3, S_R4, S_R5, S_RCAP, S_W0, S_W1, S_W1B, S_W2, S_W3, S_W3B, S_ACK } st_t;
    st_t         st;
    logic [15:0] addr_l, dq_out;
    logic        we_l, dq_oe;
    logic [15:0] dq_in;
    assign sram_dq = dq_oe ? dq_out : 16'bz;

    always_ff @(posedge clk) begin
        dq_in <= sram_dq;
        ack   <= 1'b0;
        if (reset) begin
            st <= S_IDLE; sram_oe_n <= 1'b1; sram_we_n <= 1'b1; sram_ub_n <= 1'b1; sram_lb_n <= 1'b1;
            dq_oe <= 1'b0; sram_a <= '0;
        end else case (st)
            S_IDLE: if (req && !ack) begin      // not the request being acked right now
                addr_l <= addr; we_l <= we;
                sram_a <= {1'b0, addr};
                if (we) begin
                    dq_out <= wdata; dq_oe <= 1'b1;
                    sram_ub_n <= ~be[1]; sram_lb_n <= ~be[0]; sram_oe_n <= 1'b1;
                    st <= S_W0;
                end else begin
                    sram_ub_n <= 1'b0; sram_lb_n <= 1'b0; sram_oe_n <= 1'b0;
                    st <= S_R1;
                end
            end
            // read: address and OE out, data back through the input register
            S_R1: st <= S_R2;
            S_R2: st <= S_R3;
            S_R3: st <= S_R4;
            S_R4: st <= slow ? S_R5 : S_RCAP;
            S_R5: st <= S_RCAP;
            S_RCAP: begin q <= dq_in; sram_oe_n <= 1'b1; sram_ub_n <= 1'b1; sram_lb_n <= 1'b1; st <= S_ACK; end
            // write: address and data settle, WE low for two cycles, data held after
            S_W0: begin sram_we_n <= 1'b0; st <= S_W1; end
            S_W1: st <= slow_wr ? S_W1B : S_W2;
            S_W1B: st <= S_W2;
            S_W2: begin sram_we_n <= 1'b1; st <= slow_wr ? S_W3B : S_W3; end
            S_W3B: st <= S_W3;
            S_W3: begin dq_oe <= 1'b0; sram_ub_n <= 1'b1; sram_lb_n <= 1'b1; st <= S_ACK; end
            S_ACK: begin
                if (req && addr == addr_l && we == we_l) ack <= 1'b1;
                st <= S_IDLE;
            end
            default: st <= S_IDLE;
        endcase
    end
endmodule

`default_nettype wire
