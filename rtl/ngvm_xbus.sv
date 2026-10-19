//------------------------------------------------------------------------------
// ngvm_sys's bus port carried from the CPU's clock into the memory's, by a
// toggle each way (docs/core-design.md 3).
//
// The CPU side holds bus_cmd, bus_addr, bus_be and bus_wdata from the clock
// bus_req rises until bus_done, so the request flips a toggle and the memory
// side, seeing the flip two flops later, takes the fields as they have stood
// for several of its clocks.  The answer goes back the same way: the memory
// side keeps its read data in a register that does not change until the
// next request has been taken, and flips a toggle; the CPU side reads that
// register as bus_rdata, which ngvm_sys's port allows to be held only from
// bus_done to the next request -- exactly how long the register stands.
//
// The fields cross without synchronisers by design; the SDC times them as
// the asynchronous paths they are, and what makes them safe is that each is
// still for at least two clocks of the side that samples it before the
// toggle that says it may be sampled.
//------------------------------------------------------------------------------
`default_nettype none

module ngvm_xbus (
    // the CPU's clock
    input  logic         clk_a,
    input  logic         rst_a,
    input  logic         bus_req,
    input  logic   [1:0] bus_cmd,
    input  logic  [26:0] bus_addr,
    input  logic  [31:0] bus_be,
    input  logic [255:0] bus_wdata,
    output logic         bus_done,
    output logic [255:0] bus_rdata,

    // the memory's clock
    input  logic         clk_b,
    input  logic         rst_b,
    output logic         m_req,
    output logic   [1:0] m_cmd,
    output logic  [26:0] m_addr,
    output logic  [31:0] m_be,
    output logic [255:0] m_wdata,
    input  logic         m_done,
    input  logic [255:0] m_rdata
);
    // The toggles and their synchronisers are never reset: both ends power up
    // at 0, and a reset of one end alone (the two resets are clocks apart)
    // would show the other a flip that is not a request.
    logic       req_t, done_t;
    logic [2:0] req_s, done_s;

    // ---------------------------------------------------------- CPU side
    logic       pend;
    always_ff @(posedge clk_a) begin
        done_s   <= {done_s[1:0], done_t};
        bus_done <= 1'b0;
        if (bus_req && !pend && !bus_done) begin
            req_t <= !req_t; pend <= 1'b1;
        end
        if (pend && done_s[2] != done_s[1]) begin
            bus_done <= 1'b1; pend <= 1'b0;
        end
        if (rst_a) begin
            pend <= 1'b0; bus_done <= 1'b0;
        end
    end
    assign bus_rdata = m_rdata;          // held: see above

    // ------------------------------------------------------- memory side
    always_ff @(posedge clk_b) begin
        req_s <= {req_s[1:0], req_t};
        if (req_s[2] != req_s[1]) begin
            m_req <= 1'b1;
            m_cmd <= bus_cmd; m_addr <= bus_addr; m_be <= bus_be; m_wdata <= bus_wdata;
        end
        if (m_done) begin
            m_req <= 1'b0; done_t <= !done_t;
        end
        if (rst_b) m_req <= 1'b0;
    end
endmodule

`default_nettype wire
