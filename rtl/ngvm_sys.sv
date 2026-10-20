//------------------------------------------------------------------------------
// The CPU side of NGVM, in one clock domain: the CPU, its two caches, the
// miss handler with the page table, and the devices (docs/core-design.md 1).
//
// Its only connection to memory is the bus port, one request at a time:
//   bus_req   held from the request until bus_done
//   bus_cmd   BC_RDLINE (32 bytes, the word bus_addr[4:2] names first),
//             BC_WRLINE (32 bytes, aligned; only the bytes bus_be[31:0]
//             marks), BC_RDWORD (4 bytes, aligned), BC_RDWR (a line read
//             as BC_RDLINE, then a whole line written to bus_waddr's line)
//   bus_addr  a byte address on the bus (ngvm_pkg.sv)
//   bus_wdata word i of a line in bits 32i+31:32i; a word in word 0
//   bus_done  a pulse; bus_rdata is the answer from then until the next
//             request (word 0 for a word)
//   bus_cnt   counts words read in, from any value: a line read's word w
//             is in bus_rdata, to stay, once the count has moved past it
//             (words come in order from bus_addr[4:2], round the line)
// so it takes a clock-domain crossing (ngvm_xbus.sv) without changing.
//
// The CPU is held in reset until the page table is cleared.
//------------------------------------------------------------------------------
`default_nettype none

module ngvm_sys
    import ngvm_pkg::*;
#(
    parameter int CPU_HZ = 80_000_000
) (
    input  logic         clk,
    input  logic         rst,

    output logic         bus_req,
    output logic   [1:0] bus_cmd,
    output logic  [26:0] bus_addr,
    output logic  [26:5] bus_waddr,
    output logic  [31:0] bus_be,
    output logic [255:0] bus_wdata,
    input  logic         bus_done,
    input  logic [255:0] bus_rdata,
    input  logic   [3:0] bus_cnt,

    output logic  [31:0] lcd_base,
    output logic         lcd_on,
    output logic         lcd_show_t,    // toggles: the LCD may copy the frame now
    input  logic         vblank,        // pulse in this domain: a frame starts
    input  logic  [11:0] keys,
    input  logic  [23:0] keymap,
    input  logic  [31:0] rom_size,
    input  logic  [31:0] drive_size,
    output logic  [31:0] snd,
    output logic         snd_tog,

    output logic         dbg_putc,
    output logic         dbg_exit,
    output logic         dbg_hex,
    output logic  [31:0] dbg_data,

    // each instruction as it retires (arm_cpu.sv), and each device read:
    // for the lockstep bench and the bring-up panel
    output logic         rt_valid,
    output logic         rt_irq,
    output logic  [31:0] rt_pc,
    output logic  [31:0] rt_instr,
    output logic         rt_thumb,
    output logic  [31:0] rt_cpsr,
    output logic         io_rd,
    output logic   [9:0] io_rd_off,
    output logic  [31:0] io_rd_data
);
    logic        mmu_ready, cpu_rst, irq;
    always_ff @(posedge clk) cpu_rst <= rst || !mmu_ready;

    logic        ic_req, ic_ok, ic_abort;
    logic [31:0] ic_addr, ic_data;
    logic        dc_req, dc_we, dc_ok, dc_abort;
    logic [31:0] dc_addr, dc_wdata, dc_rdata;
    logic  [3:0] dc_be;
    logic  [1:0] dc_size;

    arm_cpu u_cpu (
        .clk(clk), .rst(cpu_rst), .irq(irq),
        .ic_req(ic_req), .ic_addr(ic_addr), .ic_data(ic_data), .ic_ok(ic_ok), .ic_abort(ic_abort),
        .dc_req(dc_req), .dc_we(dc_we), .dc_addr(dc_addr), .dc_wdata(dc_wdata), .dc_be(dc_be),
        .dc_size(dc_size), .dc_rdata(dc_rdata), .dc_ok(dc_ok), .dc_abort(dc_abort),
        .rt_valid(rt_valid), .rt_irq(rt_irq), .rt_pc(rt_pc), .rt_instr(rt_instr),
        .rt_thumb(rt_thumb), .rt_cpsr(rt_cpsr)
    );

    logic  [5:0] win_id;
    logic        pt_we, inv_i;
    logic [14:0] pt_idx;
    logic [15:0] pt_data;

    logic        i_req, i_done, i_fault;
    logic [31:0] i_va;
    logic        d_req, d_done, d_fault, d_wb;
    logic  [3:0] i_words, d_words;
    logic  [1:0] d_cmd;
    logic [31:0] d_va;
    logic [26:0] d_pa, d_fill_pa;
    logic [31:0] d_be;
    logic [255:0] d_wline, rline;

    ngvm_icache u_ic (
        .clk(clk), .rst(cpu_rst),
        .ic_req(ic_req), .ic_addr(ic_addr), .ic_data(ic_data), .ic_ok(ic_ok), .ic_abort(ic_abort),
        .win_id(win_id), .inv(inv_i), .pt_wr(pt_we),
        .fill_req(i_req), .fill_va(i_va), .fill_done(i_done), .fill_fault(i_fault), .fill_line(rline),
        .fill_words(i_words)
    );

    logic        io_req, io_we;
    logic  [9:0] io_off;
    logic [31:0] io_wdata, io_rdata;

    // IO_LCD_SHOW: the D-cache writes its dirty lines back, then the LCD is
    // told it may copy the framebuffer (ngvm_lcd.sv)
    logic        lcd_show, cleaned;
    always_ff @(posedge clk) if (cleaned) lcd_show_t <= !lcd_show_t;  // never reset (ngvm_xbus.sv)

    ngvm_dcache u_dc (
        .clk(clk), .rst(cpu_rst),
        .dc_req(dc_req), .dc_we(dc_we), .dc_addr(dc_addr), .dc_wdata(dc_wdata), .dc_be(dc_be),
        .dc_rdata(dc_rdata), .dc_ok(dc_ok), .dc_abort(dc_abort),
        .win_id(win_id),
        .io_req(io_req), .io_we(io_we), .io_off(io_off), .io_wdata(io_wdata), .io_rdata(io_rdata),
        .clean(lcd_show), .cleaned(cleaned), .inv_i(inv_i),
        .m_req(d_req), .m_cmd(d_cmd), .m_wb(d_wb), .m_va(d_va), .m_pa(d_pa), .m_be(d_be), .m_wline(d_wline),
        .m_done(d_done), .m_fault(d_fault), .m_fill_pa(d_fill_pa), .m_rline(rline), .m_words(d_words)
    );

    ngvm_mmu u_mmu (
        .clk(clk), .rst(rst), .ready(mmu_ready),
        .pt_we(pt_we), .pt_idx(pt_idx), .pt_data(pt_data),
        .i_req(i_req), .i_va(i_va), .i_done(i_done), .i_fault(i_fault),
        .d_req(d_req), .d_cmd(d_cmd), .d_wb(d_wb), .d_va(d_va), .d_pa(d_pa), .d_be(d_be), .d_wline(d_wline),
        .d_done(d_done), .d_fault(d_fault), .d_fill_pa(d_fill_pa),
        .rline(rline), .i_words(i_words), .d_words(d_words),
        .bus_req(bus_req), .bus_cmd(bus_cmd), .bus_addr(bus_addr), .bus_waddr(bus_waddr), .bus_be(bus_be),
        .bus_wdata(bus_wdata), .bus_done(bus_done), .bus_rdata(bus_rdata), .bus_cnt(bus_cnt)
    );

    ngvm_io #(.CPU_HZ(CPU_HZ)) u_io (
        .clk(clk), .rst(cpu_rst),
        .io_req(io_req), .io_we(io_we), .io_off(io_off), .io_wdata(io_wdata), .io_rdata(io_rdata),
        .irq(irq),
        .pt_we(pt_we), .pt_idx(pt_idx), .pt_data(pt_data), .win_id(win_id),
        .lcd_base(lcd_base), .lcd_on(lcd_on), .lcd_show(lcd_show), .vblank(vblank),
        .keys(keys), .keymap(keymap), .rom_size(rom_size), .drive_size(drive_size),
        .snd(snd), .snd_tog(snd_tog),
        .dbg_putc(dbg_putc), .dbg_exit(dbg_exit), .dbg_hex(dbg_hex), .dbg_data(dbg_data)
    );

    assign io_rd      = io_req && !io_we;
    assign io_rd_off  = io_off;
    assign io_rd_data = io_rdata;

    wire _unused = &{1'b0, dc_size, 1'b0};
endmodule

`default_nettype wire
