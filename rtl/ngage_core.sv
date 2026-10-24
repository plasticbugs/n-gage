//------------------------------------------------------------------------------
// N-Gage -- the machine, platform-agnostic: NGVM (docs/core-design.md).
//
// Two clocks.  The CPU side -- the ARMv4T, its caches, the miss handler and
// the devices (ngvm_sys.sv) -- runs on clk_cpu, as fast as it closes timing.
// Memory and video run on the platform's 96 MHz: the bus crosses by a
// toggle handshake (ngvm_xbus.sv), and so does everything else that crosses,
// each the simplest way that is safe for what it carries:
//
//   words read     96 MHz -> CPU   a Gray count on two flops (ngvm_xbus.sv)
//   rst            96 MHz -> CPU   two flops; the CPU side is held in reset
//                                  a further 16,640 clocks clearing its page
//                                  table, which is far longer than the bus
//                                  takes to finish anything in flight
//   frame          96 MHz -> CPU   a toggle: NGVM's vblank, one pulse a frame
//   keys           96 MHz -> CPU   two flops; each bit is a button or a keypad
//                                  key on its own, registered on 96 MHz
//   keymap         96 MHz -> CPU   two flops: set from the menu, so it holds
//                                  still for seconds; a read across a change
//                                  can mix the two settings for one press
//   rom/drive size 96 MHz -> CPU   none: set by the load, before reset ends
//   lcd_base, on   CPU -> 96 MHz   two flops, taken once a frame (ngvm_lcd.sv)
//   show           CPU -> 96 MHz   a toggle: the D-cache has written back what
//                                  IO_LCD_SHOW is to show; the LCD copies it
//   snd, snd_tog   CPU -> audio    the sample and a toggle, to core_top, which
//                                  hands them to the audio clock
//   dbg_*          CPU -> 96 MHz   a snapshot and a toggle, sixteen times a
//                                  second or so: for the bring-up panel
//
// `pause` is not used yet: with the Pocket's menu open the game runs on.
//------------------------------------------------------------------------------
`default_nettype none

module ngage_core #(
    parameter int CPU_HZ = 64_000_000
) (
    input  logic         clk,           // 96 MHz
    input  logic         clk_cpu,       // CPU_HZ
    input  logic         rst,
    input  logic         pause,
    input  logic         pix_sync,      // see clk_enables.sv

    // ---------------- NGVM's bus, in clk's domain (target/pocket/ngage_mem.sv)
    output logic         m_req,
    output logic   [1:0] m_cmd,
    output logic  [26:0] m_addr,
    output logic  [26:5] m_waddr,
    output logic  [31:0] m_be,
    output logic [255:0] m_wdata,
    input  logic         m_done,
    input  logic [255:0] m_rdata,
    input  logic         m_free,
    input  logic   [3:0] m_cnt,

    // ---------------- the LCD's line fetch, the same
    output logic         l_req,
    output logic  [25:1] l_addr,
    output logic   [5:0] l_len,
    input  logic         l_wr,
    input  logic   [4:0] l_idx,
    input  logic  [15:0] l_data,
    input  logic         l_done,

    input  logic  [26:0] keys,          // IO_KEYS: KEY_* (ngvm_hw.h), 1 = pressed
    input  logic  [23:0] keymap,        // IO_KEYMAP (ngvm_hw.h); 0 = the default keys
    input  logic  [31:0] rom_size,
    input  logic  [31:0] drive_size,

    // ---------------- video, one pixel per pix_ce in the clk domain
    output logic  [23:0] rgb,
    output logic         hsync, vsync, hblank, vblank,
    output logic         pix_ce, de,

    // ---------------- the picture turned, for the Analogizer (ngvm_lcd.sv)
    input  logic   [1:0] tate,          // 0 off, 1 clockwise, 2 anticlockwise
    output logic         t_cen,
    output logic  [23:0] t_rgb,
    output logic         t_hsync, t_vsync, t_hblank, t_vblank, t_de,
    output logic   [7:0] t_gx, t_gy,
    output logic         t_vis,

    // ---------------- sound, in clk_cpu's domain: L 15:0, R 31:16, signed
    output logic  [31:0] snd,
    output logic         snd_tog,

    // ---------------- bring-up, in clk's domain
    output logic  [31:0] dbg_pc,        // an instruction retired lately
    output logic  [31:0] dbg_chars,     // the last four characters of IO_DBG_PUTC
    output logic         dbg_exited,    // IO_DBG_EXIT written: the kernel panicked
    output logic         dbg_lcd_on
);
    // ------------------------------------------------------------ clocks
    logic cen_phi1, cen_phi2, cen_z80, cen_ym, cen_pix;
    clk_enables u_cen (
        .clk(clk), .rst(rst), .pause(1'b0), .pix_sync(pix_sync),
        .cen_phi1(cen_phi1), .cen_phi2(cen_phi2), .cen_z80(cen_z80),
        .cen_ym(cen_ym), .cen_pix(cen_pix)
    );
    assign pix_ce = cen_pix;

    // ------------------------------------------------------------ reset
    logic [1:0] rst_s;
    always_ff @(posedge clk_cpu) rst_s <= {rst_s[0], rst};
    wire rst_c = rst_s[1];

    // ------------------------------------------------------------ the CPU side
    logic         bus_req, bus_done;
    logic   [1:0] bus_cmd;
    logic  [26:0] bus_addr;
    logic  [26:5] bus_waddr;
    logic   [3:0] bus_cnt;
    logic  [31:0] bus_be;
    logic [255:0] bus_wdata, bus_rdata;
    logic  [31:0] lcd_base;
    logic         lcd_on, vb_c;
    logic         show_t;           // a toggle: never reset (ngvm_xbus.sv)
    logic  [26:0] keys_s0, keys_s1;
    logic  [23:0] keymap_s0, keymap_s1;
    logic         dbg_putc, dbg_exit, dbg_hex;
    logic  [31:0] dbg_data;
    logic         rt_valid, rt_irq, rt_thumb, io_rd;
    logic  [31:0] rt_pc, rt_instr, rt_cpsr, io_rd_data;
    logic   [9:0] io_rd_off;

    always_ff @(posedge clk_cpu) begin keys_s0 <= keys; keys_s1 <= keys_s0; end
    always_ff @(posedge clk_cpu) begin keymap_s0 <= keymap; keymap_s1 <= keymap_s0; end

    ngvm_sys #(.CPU_HZ(CPU_HZ)) u_sys (
        .clk(clk_cpu), .rst(rst_c),
        .bus_req(bus_req), .bus_cmd(bus_cmd), .bus_addr(bus_addr), .bus_waddr(bus_waddr), .bus_be(bus_be),
        .bus_wdata(bus_wdata), .bus_done(bus_done), .bus_rdata(bus_rdata), .bus_cnt(bus_cnt),
        .lcd_base(lcd_base), .lcd_on(lcd_on), .lcd_show_t(show_t), .vblank(vb_c), .keys(keys_s1), .keymap(keymap_s1),
        .rom_size(rom_size), .drive_size(drive_size),
        .snd(snd), .snd_tog(snd_tog),
        .dbg_putc(dbg_putc), .dbg_exit(dbg_exit), .dbg_hex(dbg_hex), .dbg_data(dbg_data),
        .rt_valid(rt_valid), .rt_irq(rt_irq), .rt_pc(rt_pc), .rt_instr(rt_instr),
        .rt_thumb(rt_thumb), .rt_cpsr(rt_cpsr),
        .io_rd(io_rd), .io_rd_off(io_rd_off), .io_rd_data(io_rd_data)
    );

    ngvm_xbus u_xbus (
        .clk_a(clk_cpu), .rst_a(rst_c),
        .bus_req(bus_req), .bus_cmd(bus_cmd), .bus_addr(bus_addr), .bus_waddr(bus_waddr), .bus_be(bus_be),
        .bus_wdata(bus_wdata), .bus_done(bus_done), .bus_rdata(bus_rdata), .bus_cnt(bus_cnt),
        .clk_b(clk), .rst_b(rst),
        .m_req(m_req), .m_cmd(m_cmd), .m_addr(m_addr), .m_waddr(m_waddr), .m_be(m_be), .m_wdata(m_wdata),
        .m_done(m_done), .m_rdata(m_rdata), .m_free(m_free), .m_cnt(m_cnt)
    );

    // ------------------------------------------------------------ the LCD
    logic frame, frame_t;          // toggles: never reset (ngvm_xbus.sv)
    logic       show;
    logic [2:0] show_s;
    always_ff @(posedge clk) begin
        show_s <= {show_s[1:0], show_t};
        show   <= show_s[2] != show_s[1];
    end
    ngvm_lcd u_lcd (
        .clk(clk), .rst(rst), .cen_pix(cen_pix),
        .lcd_base(lcd_base), .lcd_on(lcd_on), .show(show), .frame(frame),
        .l_req(l_req), .l_addr(l_addr), .l_len(l_len),
        .l_wr(l_wr), .l_idx(l_idx), .l_data(l_data), .l_done(l_done),
        .rgb(rgb), .hsync(hsync), .vsync(vsync), .hblank(hblank), .vblank(vblank), .de(de),
        .tate(tate), .t_cen(t_cen), .t_rgb(t_rgb),
        .t_hsync(t_hsync), .t_vsync(t_vsync), .t_hblank(t_hblank), .t_vblank(t_vblank), .t_de(t_de),
        .t_gx(t_gx), .t_gy(t_gy), .t_vis(t_vis)
    );
    always_ff @(posedge clk) if (frame) frame_t <= !frame_t;

    logic [2:0] frame_s;
    always_ff @(posedge clk_cpu) begin
        frame_s <= {frame_s[1:0], frame_t};
        vb_c    <= frame_s[2] != frame_s[1];
    end

    // ------------------------------------------------------------ bring-up
    logic [31:0] pc_c, chars_c, pc_h, chars_h;
    logic        exit_c, exit_h, on_h, snap_t;
    logic [19:0] snap_n;
    always_ff @(posedge clk_cpu) begin
        if (rt_valid) pc_c <= rt_pc;
        if (dbg_putc) chars_c <= {chars_c[23:0], dbg_data[7:0]};
        if (dbg_exit) exit_c <= 1'b1;
        snap_n <= snap_n + 20'd1;
        if (snap_n == 20'd0) begin
            pc_h <= pc_c; chars_h <= chars_c; exit_h <= exit_c; on_h <= lcd_on;
            snap_t <= !snap_t;
        end
        if (rst_c) begin pc_c <= '0; chars_c <= '0; exit_c <= 1'b0; end
    end
    logic [2:0] snap_s;
    always_ff @(posedge clk) begin
        snap_s <= {snap_s[1:0], snap_t};
        if (snap_s[2] != snap_s[1]) begin
            dbg_pc <= pc_h; dbg_chars <= chars_h; dbg_exited <= exit_h; dbg_lcd_on <= on_h;
        end
    end

    wire _unused = &{1'b0, pause, cen_phi1, cen_phi2, cen_z80, cen_ym, dbg_hex, rt_irq,
                     rt_instr, rt_thumb, rt_cpsr, io_rd, io_rd_off, io_rd_data, 1'b0};
endmodule

`default_nettype wire
