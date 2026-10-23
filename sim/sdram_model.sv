// Behavioural SDR SDRAM (MT48LC32M16-ish, 4 banks) for simulation.
// Derived from the Punch-Out!! core's model; extended with four independent
// banks and reads without auto-precharge (open-row bursts). CL2 only.
//
// PHASE_LAG 0 models the Pocket's chip: CL2 read data for a READ registered
// at edge N is on the bus during [N+2, N+3), so the controller's sample at
// N+3 is the good one.  That is the capture the SDC's timing analysis
// checks, and the Pocket agrees: a READ every clock plays caught at READ+3
// and crashes at once caught at READ+4 (docs/bringup.md, log, 2026-10-19).
// PHASE_LAG 1 is the template's chip clocked in phase with the controller,
// its data a clock later, caught at READ+4.  With it the bench passed what
// the Pocket crashed on.
//
// The bus floats the clock after a word.  The Pocket's keeps the last word
// until the next, so READ+4 at two clocks a READ fails here and played on
// every build before the third: stricter than the chip, never looser.
//
// The command spacing is checked too, in clocks of the 96 MHz the core runs
// the chip at, against the slowest grade it might be (-7: tRCD and tRP 20 ns,
// tRAS 45, tRC 67.5, tRFC 66, tWR 2 clocks).  Not after an auto-precharge,
// which only the loader's single writes use: the chip times that precharge
// itself, not on a clock edge, and the controller's wait after it is the
// template's, proven on the Pocket.
`default_nettype none

module sdram_model #(parameter PHASE_LAG = 0, parameter AW = 22,
                     parameter T_RCD = 2, T_RP = 2, T_RAS = 5, T_RC = 7, T_RFC = 7, T_WR = 2) (
    input  logic        clk,
    inout  wire  [15:0] dq,
    input  logic [12:0] a,
    input  logic [1:0]  ba,
    input  logic        dqml, dqmh,
    input  logic        cs_n, ras_n, cas_n, we_n,
    input  logic        cke
);
    logic [15:0] mem [0:(1<<AW)-1] /*verilator public_flat_rw*/;

    logic [12:0] row_open [0:3];
    logic        row_active [0:3];
    logic [15:0] pipe_q1, pipe_q2;
    logic        pipe_v1, pipe_v2;
    integer      errors /*verilator public_flat_rw*/;

    wire [3:0] cmd = {cs_n, ras_n, cas_n, we_n};
    localparam CMD_ACT = 4'b0011, CMD_READ = 4'b0101, CMD_WRIT = 4'b0100,
               CMD_PRE = 4'b0010, CMD_REF = 4'b0001;

    // when each bank was last activated, precharged and written, and the
    // last refresh, in clocks
    longint      now, t_act [0:3], t_pre [0:3], t_wr [0:3], t_ref;
    task automatic spacing(input string what, input longint since, input int need);
        if (now - since < longint'(need)) begin
            $display("SDRAM-TIMING-ERROR: %s after %0d clocks, needs %0d (clock %0d)", what, now - since, need, now);
            errors++;
        end
    endtask

    logic [15:0] dq_out;
    logic        dq_oe;
    assign dq = dq_oe ? dq_out : 16'hzzzz;

    // word index = {bank, row, col}: matches sdram_ctrl's a[25:24], a[23:11], a[10:1]
    wire [24:0] widx_full = {ba, row_open[ba], a[9:0]};
    wire [AW-1:0] widx = widx_full[AW-1:0];

    initial begin
        errors = 0;
        for (int i = 0; i < 4; i++) begin row_active[i] = 1'b0; row_open[i] = '0; end
        now = 0; t_ref = -100;
        for (int i = 0; i < 4; i++) begin t_act[i] = -100; t_pre[i] = -100; t_wr[i] = -100; end
    end

    always_ff @(posedge clk) begin
        pipe_q2 <= pipe_q1;
        pipe_v2 <= pipe_v1;
        dq_out  <= PHASE_LAG ? pipe_q2 : pipe_q1;
        dq_oe   <= PHASE_LAG ? pipe_v2 : pipe_v1;
        pipe_v1 <= 1'b0;

        now <= now + 1;
        case (cmd)
            CMD_ACT: begin
                spacing("ACTIVATE after PRECHARGE (tRP)", t_pre[ba], T_RP);
                spacing("ACTIVATE after ACTIVATE (tRC)", t_act[ba], T_RC);
                spacing("ACTIVATE after AUTO REFRESH (tRFC)", t_ref, T_RFC);
                t_act[ba] <= now;
                if (row_active[ba]) begin
                    $display("SDRAM-PROTOCOL-ERROR: ACTIVATE bank %0d row %0d while row %0d open", ba, a, row_open[ba]);
                    errors++;
                end
                row_open[ba]   <= a;
                row_active[ba] <= 1'b1;
            end
            CMD_READ: begin
                if (!row_active[ba]) begin $display("SDRAM-PROTOCOL-ERROR: READ with no open row"); errors++; end
                spacing("READ after ACTIVATE (tRCD)", t_act[ba], T_RCD);
                pipe_q1 <= mem[widx];
                pipe_v1 <= 1'b1;
                if (a[10]) row_active[ba] <= 1'b0;
            end
            CMD_WRIT: begin
                if (!row_active[ba]) begin $display("SDRAM-PROTOCOL-ERROR: WRITE with no open row"); errors++; end
                spacing("WRITE after ACTIVATE (tRCD)", t_act[ba], T_RCD);
                t_wr[ba] <= now;
                if (!dqml) mem[widx][7:0]  <= dq[7:0];
                if (!dqmh) mem[widx][15:8] <= dq[15:8];
                if (a[10]) row_active[ba] <= 1'b0;
            end
            CMD_PRE: begin
                for (int i = 0; i < 4; i++)
                    if ((a[10] || ba == 2'(i)) && row_active[i]) begin
                        spacing("PRECHARGE after ACTIVATE (tRAS)", t_act[i], T_RAS);
                        spacing("PRECHARGE after WRITE (tWR)", t_wr[i], T_WR);
                    end
                if (a[10]) for (int i = 0; i < 4; i++) begin row_active[i] <= 1'b0; t_pre[i] <= now; end
                else begin row_active[ba] <= 1'b0; t_pre[ba] <= now; end
            end
            CMD_REF: begin
                for (int i = 0; i < 4; i++) begin
                    if (row_active[i]) begin $display("SDRAM-PROTOCOL-ERROR: AUTO REFRESH with bank %0d open", i); errors++; end
                    spacing("AUTO REFRESH after PRECHARGE (tRP)", t_pre[i], T_RP);
                end
                spacing("AUTO REFRESH after AUTO REFRESH (tRFC)", t_ref, T_RFC);
                t_ref <= now;
            end
            default: ;
        endcase
    end
endmodule
