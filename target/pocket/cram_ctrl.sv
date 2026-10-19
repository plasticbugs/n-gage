//------------------------------------------------------------------------------
// The Pocket's two cellular RAMs (CRAM0, CRAM1: PSRAM, 16 MB each as two
// 8 MB halves on CE0#/CE1#), one 16-bit access at a time, in the chips'
// power-up mode: asynchronous, with the low address multiplexed onto DQ and
// latched by ADV# (docs/core-design.md 3: the drive image lives here).
//
// Halfword address h[23:0]: h[23] picks the chip, h[22] the half, h[21:0]
// the word.  A request is taken (`take`) on any clock the controller is
// idle, so a stream of them runs back to back; `ack` ends each one.
//
// Timing, in 96 MHz cycles of 10.4 ns at the pins, against the -70 parts'
// asynchronous limits:
//
//   write  0-1 ADV# low, address out   2 ADV# high, address held
//          3-7 data out, WE# low (52 ns, tWP 45; data before WE# rises 52 ns,
//          tDW 20)   8 WE# high, data held (CE# low to WE# high 83 ns, tCW 70)
//          9 CE# high, and the next access may start at 10: 10 cycles
//   read   0-1 ADV# low, address out   2 ADV# high, address held
//          3 DQ released   4 OE# low   ... DQ taken at the end of 8 (ADV#
//          low to there 94 ns, tAADV 70; OE# low 52 ns, tOE 20)   11 OE#,
//          CE# high, and the next access may start at 12: 12 cycles
//
// The download writes a halfword every 14 clocks at the loader's fastest
// (a byte every 7), so a write takes 10 to leave it room (ngage_mem.sv).
// A read keeps a cycle of margin over the chip's access time for the pins'
// own delays, out and back.
//
// Each pin is driven from its own flop, a clock behind the state, so all of
// them move on the same clock as the steps above and no select can glitch
// as `chip` changes.  The flops hold each strobe active high and the pins
// are their inverses, so the chips see nothing selected from configuration
// on, before any reset.  DQ is taken into a flop as well.
//------------------------------------------------------------------------------
`default_nettype none

module cram_ctrl (
    input  logic        clk,            // 96 MHz
    input  logic        rst,

    input  logic        req,            // a request is waiting...
    input  logic        we,
    input  logic [23:0] addr,           // halfword
    input  logic [15:0] wdata,
    input  logic  [1:0] be,             // writes: [1] the high byte
    output logic        take,           // ... and is taken at this edge
    output logic        ack,            // pulse: done; q valid with it for a read
    output logic [15:0] q,

    // pins, both chips
    output logic [21:16] cram0_a,
    inout  wire  [15:0] cram0_dq,
    output logic        cram0_clk, cram0_adv_n, cram0_cre,
    output logic        cram0_ce0_n, cram0_ce1_n, cram0_oe_n, cram0_we_n,
    output logic        cram0_ub_n, cram0_lb_n,
    output logic [21:16] cram1_a,
    inout  wire  [15:0] cram1_dq,
    output logic        cram1_clk, cram1_adv_n, cram1_cre,
    output logic        cram1_ce0_n, cram1_ce1_n, cram1_oe_n, cram1_we_n,
    output logic        cram1_ub_n, cram1_lb_n
);
    logic  [3:0] t;                     // the step
    logic        busy, w, chip, half;
    logic [15:0] dq_o, wd;
    logic        dq_oe, adv, oe, wr, ce, ub, lb;    // 1: the pin is low
    logic  [5:0] a_hi;
    logic [15:0] dq0_i, dq1_i;

    assign take = req && !busy;

    // ------------------------------------------------------------ pins
    logic        p0_oe, p1_oe, p0_adv, p1_adv, p0_rd, p1_rd, p0_wr, p1_wr;
    logic        p0_ce0, p0_ce1, p1_ce0, p1_ce1, p_ub, p_lb;
    logic [15:0] p_dq;
    logic  [5:0] p_a;
    always_ff @(posedge clk) begin
        p0_oe  <= dq_oe && !chip;  p1_oe  <= dq_oe && chip;
        p0_adv <= adv && !chip;    p1_adv <= adv && chip;
        p0_rd  <= oe && !chip;     p1_rd  <= oe && chip;
        p0_wr  <= wr && !chip;     p1_wr  <= wr && chip;
        p0_ce0 <= ce && !chip && !half;  p0_ce1 <= ce && !chip && half;
        p1_ce0 <= ce &&  chip && !half;  p1_ce1 <= ce &&  chip && half;
        p_ub   <= ub;  p_lb <= lb;
        p_dq   <= dq_o;
        p_a    <= a_hi;
    end

    assign cram0_dq = p0_oe ? p_dq : 16'hZZZZ;
    assign cram1_dq = p1_oe ? p_dq : 16'hZZZZ;
    always_ff @(posedge clk) begin dq0_i <= cram0_dq; dq1_i <= cram1_dq; end

    assign cram0_clk = 1'b0;  assign cram1_clk = 1'b0;
    assign cram0_cre = 1'b0;  assign cram1_cre = 1'b0;
    assign cram0_a = p_a;      assign cram1_a = p_a;
    assign cram0_adv_n = !p0_adv;  assign cram1_adv_n = !p1_adv;
    assign cram0_oe_n  = !p0_rd;   assign cram1_oe_n  = !p1_rd;
    assign cram0_we_n  = !p0_wr;   assign cram1_we_n  = !p1_wr;
    assign cram0_ub_n  = !p_ub;    assign cram1_ub_n  = !p_ub;
    assign cram0_lb_n  = !p_lb;    assign cram1_lb_n  = !p_lb;
    assign cram0_ce0_n = !p0_ce0;  assign cram0_ce1_n = !p0_ce1;
    assign cram1_ce0_n = !p1_ce0;  assign cram1_ce1_n = !p1_ce1;

    // ------------------------------------------------------------ steps
    always_ff @(posedge clk) begin
        ack <= 1'b0;
        if (take) begin
            busy <= 1'b1; t <= 4'd0; w <= we;
            chip <= addr[23]; half <= addr[22];
            a_hi <= addr[21:16]; dq_o <= addr[15:0]; dq_oe <= 1'b1;
            ce <= 1'b1; adv <= 1'b1;
            ub <= we ? be[1] : 1'b1; lb <= we ? be[0] : 1'b1;
            wd <= wdata;
        end else if (busy) begin
            t <= t + 4'd1;
            if (w) case (t)
                4'd1: adv <= 1'b0;
                4'd2: begin dq_o <= wd; wr <= 1'b1; end
                4'd7: wr <= 1'b0;
                4'd8: begin ce <= 1'b0; dq_oe <= 1'b0; ack <= 1'b1; busy <= 1'b0; end
                default: ;
            endcase
            else case (t)
                4'd1: adv <= 1'b0;
                4'd2: dq_oe <= 1'b0;
                4'd3: oe <= 1'b1;
                4'd10: begin
                    q <= chip ? dq1_i : dq0_i;
                    oe <= 1'b0; ce <= 1'b0; ack <= 1'b1; busy <= 1'b0;
                end
                default: ;
            endcase
        end
        if (rst) begin
            busy <= 1'b0; ack <= 1'b0; ce <= 1'b0; adv <= 1'b0; oe <= 1'b0; wr <= 1'b0;
            dq_oe <= 1'b0; ub <= 1'b0; lb <= 1'b0;
        end
    end
endmodule

`default_nettype wire
