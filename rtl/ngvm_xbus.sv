//------------------------------------------------------------------------------
// ngvm_sys's bus port carried from the CPU's clock into the memory's, by a
// toggle each way (docs/core-design.md 3).
//
// The CPU side holds bus_cmd, bus_addr, bus_waddr, bus_be and bus_wdata from
// the clock bus_req rises until bus_done, so the request flips a toggle and
// the memory side, seeing the flip two flops later, takes the fields as they
// have stood for several of its clocks -- or later, when m_free says the
// memory has finished what the last request left it to do (a write-back
// after its answer, ngage_mem.sv).  The answer goes back the same way: the
// memory side keeps its read data in a register that does not change until
// the next request has been taken, and flips a toggle; the CPU side reads
// that register as bus_rdata, which ngvm_sys's port allows to be held only
// from bus_done to the next request -- exactly how long the register stands.
//
// A line read's words land in that register one at a time, and the memory
// side counts each a clock after it lands, in Gray code, so the count
// crosses on two flops a bit at a time.  bus_cnt is that count in the CPU's
// clock: when it moves, the word it counts has stood for at least a memory
// clock and two of the CPU's, and stands until the next request is taken.
//
// The fields cross without synchronisers by design; the SDC times them as
// the asynchronous paths they are, and what makes them safe is that each is
// still for at least two clocks of the side that samples it before the
// toggle or the count that says it may be sampled.
//------------------------------------------------------------------------------
`default_nettype none

module ngvm_xbus (
    // the CPU's clock
    input  logic         clk_a,
    input  logic         rst_a,
    input  logic         bus_req,
    input  logic   [1:0] bus_cmd,
    input  logic  [26:0] bus_addr,
    input  logic  [26:5] bus_waddr,
    input  logic  [31:0] bus_be,
    input  logic [255:0] bus_wdata,
    output logic         bus_done,
    output logic [255:0] bus_rdata,
    output logic   [3:0] bus_cnt,       // words read in, binary, from any count

    // the memory's clock
    input  logic         clk_b,
    input  logic         rst_b,
    output logic         m_req,
    output logic   [1:0] m_cmd,
    output logic  [26:0] m_addr,
    output logic  [26:5] m_waddr,
    output logic  [31:0] m_be,
    output logic [255:0] m_wdata,
    input  logic         m_done,
    input  logic [255:0] m_rdata,
    input  logic         m_free,
    input  logic   [3:0] m_cnt          // Gray
);
    // The toggles and their synchronisers are never reset: both ends power up
    // at 0, and a reset of one end alone (the two resets are clocks apart)
    // would show the other a flip that is not a request.
    logic       req_t, done_t, req_k;
    logic [1:0] req_s;
    logic [2:0] done_s;

    // ---------------------------------------------------------- CPU side
    logic       pend;
    logic [3:0] cnt_s0, cnt_s1;
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

    always_ff @(posedge clk_a) begin
        cnt_s0  <= m_cnt;
        cnt_s1  <= cnt_s0;
        bus_cnt <= {cnt_s1[3], ^cnt_s1[3:2], ^cnt_s1[3:1], ^cnt_s1[3:0]};
    end

    // ------------------------------------------------------- memory side
    // req_k is the toggle as it stood when the last request was taken: a
    // request is waiting while the two differ
    always_ff @(posedge clk_b) begin
        req_s <= {req_s[0], req_t};
        if (req_s[1] != req_k && m_free && !m_req) begin
            req_k <= req_s[1];
            m_req <= 1'b1;
            m_cmd <= bus_cmd; m_addr <= bus_addr; m_waddr <= bus_waddr;
            m_be <= bus_be; m_wdata <= bus_wdata;
        end
        if (m_done) begin
            m_req <= 1'b0; done_t <= !done_t;
        end
        if (rst_b) m_req <= 1'b0;
    end
endmodule

`default_nettype wire
