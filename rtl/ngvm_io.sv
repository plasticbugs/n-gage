//------------------------------------------------------------------------------
// NGVM's devices (docs/hardware.md 6, sw/include/ngvm_hw.h): the timer and
// the interrupt status, the LCD's registers, the keys, the audio FIFO, the
// page table's write port, the data window's number and the debug port.
//
// The D-cache presents an access in its compare cycle (io_req); a read's
// value is combinational from the registers, and a write takes effect at the
// edge that ends the cycle.
//
// Time is real here: the microsecond counter and the FIFO's drain both step
// by fractions of CPU_HZ, so they keep time at whatever clock the CPU side
// runs.  The lockstep bench replays every value read here to Unicorn, so
// none of this has to agree with ngvm.py's virtual time.
//------------------------------------------------------------------------------
`default_nettype none

module ngvm_io
    import ngvm_pkg::*;
#(
    parameter int CPU_HZ   = 80_000_000,
    parameter int AUDIO_N  = 1024       // FIFO samples: AUDIO_FIFO_N in ngvm_hw.h
) (
    input  logic        clk,
    input  logic        rst,

    input  logic        io_req,
    input  logic        io_we,
    input  logic  [9:0] io_off,
    input  logic [31:0] io_wdata,
    output logic [31:0] io_rdata,

    output logic        irq,

    output logic        pt_we,
    output logic [14:0] pt_idx,
    output logic [15:0] pt_data,
    output logic  [5:0] win_id,

    output logic [31:0] lcd_base,
    output logic        lcd_on,
    output logic        lcd_show,       // pulse: IO_LCD_SHOW was written
    input  logic        vblank,         // pulse, in this domain: a frame starts

    input  logic [26:0] keys,           // KEY_*, 1 = pressed: the pad 11:0, the keypad 26:12
    input  logic [23:0] keymap,         // IO_KEYMAP: the phone key for A B X Y L R
    input  logic [31:0] rom_size,
    input  logic [31:0] drive_size,

    output logic [31:0] snd,            // the sample playing: L 15:0, R 31:16
    output logic        snd_tog,        // toggles when it changes

    output logic        dbg_putc,       // pulses with dbg_data
    output logic        dbg_exit,
    output logic        dbg_hex,
    output logic [31:0] dbg_data
);
    localparam int AW = $clog2(AUDIO_N);

    // ------------------------------------------------------------ time
    logic [63:0] us;
    logic [31:0] us_frac;               // CPU_HZ counts a microsecond
    logic [31:0] hi_latch, cmp;
    logic        armed;
    always_ff @(posedge clk) begin
        if (us_frac + 32'd1_000_000 >= 32'(CPU_HZ)) begin
            us_frac <= us_frac + 32'd1_000_000 - 32'(CPU_HZ);
            us <= us + 64'd1;
        end else us_frac <= us_frac + 32'd1_000_000;
        if (rst) begin us <= 64'd0; us_frac <= 32'd0; end
    end

    // ------------------------------------------------------------ audio
    logic [31:0] afifo [0:AUDIO_N-1];
    logic [AW-1:0] a_wp, a_rp;
    logic [AW:0]   a_lvl;
    logic [31:0]   a_rate, a_frac, a_q;
    logic          a_pop;
    wire           a_push = io_req && io_we && io_off == IO_AUDIO_DATA && a_lvl != (AW+1)'(AUDIO_N);
    always_ff @(posedge clk) begin
        if (a_push) afifo[a_wp] <= io_wdata;
        a_q <= afifo[a_rp];
    end
    always_ff @(posedge clk) begin
        a_pop <= 1'b0;
        if (a_frac + a_rate >= 32'(CPU_HZ)) begin
            a_frac <= a_frac + a_rate - 32'(CPU_HZ);
            a_pop  <= a_lvl != '0;
        end else a_frac <= a_frac + a_rate;
        // a_rp moves one cycle after the pop, when a_q holds the sample
        if (a_pop) a_rp <= a_rp + 1'b1;
        if (a_push) a_wp <= a_wp + 1'b1;
        a_lvl <= a_lvl + (AW+1)'(a_push) - (AW+1)'(a_pop);
        if (a_pop) begin snd <= a_q; snd_tog <= !snd_tog; end
        if (rst) begin
            a_wp <= '0; a_rp <= '0; a_lvl <= '0; a_frac <= 32'd0; a_pop <= 1'b0;
            snd <= 32'd0; snd_tog <= 1'b0;
        end
    end

    // ------------------------------------------------------------ registers
    logic  [1:0] status;                // timer, vblank; audio is a level
    logic [31:0] enable, lcd_frame;
    logic [14:0] pt_index;
    logic        pt_index_ok;
    wire         audio_low = a_lvl <= (AW+1)'(AUDIO_N / 2);
    wire  [31:0] status_r  = {29'd0, audio_low, status};

    always_comb begin
        case (io_off)
            IO_TIMER_US:    io_rdata = us[31:0];
            IO_TIMER_US_HI: io_rdata = hi_latch;
            IO_IRQ_STATUS:  io_rdata = status_r;
            IO_IRQ_ENABLE:  io_rdata = enable;
            IO_LCD_BASE:    io_rdata = lcd_base;
            IO_LCD_CTRL:    io_rdata = {31'd0, lcd_on};
            IO_LCD_FRAME:   io_rdata = lcd_frame;
            IO_KEYS:        io_rdata = {5'd0, keys};
            IO_KEYMAP:      io_rdata = {8'd0, keymap};
            IO_AUDIO_LEVEL: io_rdata = 32'(a_lvl);
            IO_AUDIO_RATE:  io_rdata = a_rate;
            IO_AUDIO_SIZE:  io_rdata = 32'(AUDIO_N);
            IO_WIN_ID:      io_rdata = {26'd0, win_id};
            IO_DRIVE_SIZE:  io_rdata = drive_size;
            IO_ROM_SIZE:    io_rdata = rom_size;
            default:        io_rdata = 32'd0;
        endcase
    end

    wire wr   = io_req && io_we;
    // the compare is armed from US's low word, as ngvm.py's: (US - CMP) < 2^31
    wire fire = armed && us[31:0] - cmp < 32'h8000_0000;
    always_ff @(posedge clk) begin
        pt_we    <= 1'b0;
        lcd_show <= 1'b0;
        dbg_putc <= 1'b0;
        dbg_exit <= 1'b0;
        dbg_hex  <= 1'b0;
        if (io_req && !io_we && io_off == IO_TIMER_US) hi_latch <= us[63:32];
        // a source setting its bit wins over a write clearing it
        status <= status & ~(wr && io_off == IO_IRQ_STATUS ? io_wdata[1:0] : 2'b00) | {vblank, fire};
        if (fire) armed <= 1'b0;
        if (vblank) lcd_frame <= lcd_frame + 32'd1;
        if (wr) case (io_off)
            IO_DBG_PUTC:   begin dbg_putc <= 1'b1; dbg_data <= io_wdata; end
            IO_DBG_EXIT:   begin dbg_exit <= 1'b1; dbg_data <= io_wdata; end
            IO_DBG_HEX:    begin dbg_hex  <= 1'b1; dbg_data <= io_wdata; end
            IO_TIMER_CMP:  begin cmp <= io_wdata; armed <= 1'b1; end
            IO_IRQ_ENABLE: enable <= io_wdata;
            IO_LCD_BASE:   lcd_base <= io_wdata;
            IO_LCD_CTRL:   lcd_on <= io_wdata[0];
            IO_LCD_SHOW:   lcd_show <= 1'b1;
            IO_AUDIO_RATE: a_rate <= io_wdata == 32'd0 ? 32'd8000 : io_wdata;
            IO_PT_INDEX:   begin pt_index <= io_wdata[14:0]; pt_index_ok <= io_wdata < 32'(PT_ENTRIES); end
            IO_PT_DATA:    begin pt_we <= pt_index_ok; pt_idx <= pt_index; pt_data <= io_wdata[15:0]; end
            IO_WIN_ID:     win_id <= io_wdata[5:0];
            default: ;
        endcase
        irq <= (status_r & enable) != 32'd0;
        if (rst) begin
            status <= 2'b00; enable <= 32'd0; armed <= 1'b0; cmp <= 32'd0; hi_latch <= 32'd0;
            lcd_base <= 32'd0; lcd_on <= 1'b0; lcd_frame <= 32'd0; a_rate <= 32'd8000;
            pt_index <= 15'd0; pt_index_ok <= 1'b0; win_id <= 6'd0; irq <= 1'b0;
        end
    end
endmodule

`default_nettype wire
