//------------------------------------------------------------------------------
// SPDX-License-Identifier: MIT
// SPDX-FileType: SOURCE
// SPDX-FileCopyrightText: (c) 2023, OpenGateware authors and contributors
//------------------------------------------------------------------------------
//
// Copyright (c) 2023, Marcus Andrade <marcus@opengateware.org>
// Copyright (c) 2022, Analogue Enterprises Limited
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
//
//------------------------------------------------------------------------------
// Platform Specific top-level -- N-Gage
// Instantiated by the real top-level: apf_top
//
// The machine (rtl/ngage_core.sv) is platform-agnostic; this file is the APF
// glue: bridge, the three slots, the interact menu, video and audio hand-off,
// the memories, and the bring-up panel.  RAM, the kernel and SYM.ROM live in
// SDRAM, the game's drive image in the two CRAMs (target/pocket/ngage_mem.sv).
//
// Everything above the "@ The game" banner is the framework's and is the same
// in every core here.  Below it, the shapes are proven on hardware -- the
// reset chain, the SRAM self-test, the pause, the clock-domain hand-overs --
// and the contents are yours.  Read METHODOLOGY.md sections 5.4, 5.5, 5.8 and
// 5.16 to 5.21 before changing a shape.
//------------------------------------------------------------------------------

`default_nettype none

module core_top
    #(
         //! ------------------------------------------------------------------------
         //! System Configuration Parameters
         //! ------------------------------------------------------------------------
         // Memory
         parameter USE_SDRAM    = 1,       //! Enable SDRAM (RAM, the kernel, SYM.ROM)
         parameter USE_SRAM     = 1,       //! Enable SRAM (idle: its pins are driven quiet)
         parameter USE_CRAM0    = 1,       //! Cellular RAM #1: the drive image's first 16 MB
         parameter USE_CRAM1    = 1,       //! Cellular RAM #2: the rest of it
         // Cartridge port
         parameter USE_ANALOGIZER = 1,     //! Analogizer adapter (docs/analogizer.md)
         // Video
         parameter BPP_R        = 8,       //! Bits Per Pixel Red
         parameter BPP_G        = 8,       //! Bits Per Pixel Green
         parameter BPP_B        = 8,       //! Bits Per Pixel Blue
         // Audio
         parameter AUDIO_DW     = 16,      //! Audio Bits
         parameter AUDIO_S      = 1,       //! Signed Audio
         parameter STEREO       = 1,       //! Stereo Output
         parameter AUDIO_MIX    = 0,       //! [0] No Mix | [1] 25% | [2] 50% | [3] 100% (mono)
         // Gamepad/Joystick
         parameter JOY_PADS     = 2,       //! Total Number of Gamepads
         parameter JOY_ALT      = 0,       //! 2 Players Alternate
         // Data I/O - [MPU -> FPGA]
         parameter DIO_MASK     = 4'h0,    //! Upper 4 bits of address
         parameter DIO_AW       = 27,      //! Address Width
         parameter DIO_DW       = 8,       //! Data Width (8 or 16 bits)
         parameter DIO_DELAY    = 7,       //! Number of clock cycles to delay each write output
         parameter DIO_HOLD     = 4,       //! Number of clock cycles to hold the ioctl_wr signal high
         // HiScore I/O - [MPU <-> FPGA]
         parameter HS_AW        = 16,      //! Max size of game RAM address for highscores
         parameter HS_SW        = 8,       //! Max size of capture RAM For highscore data (default 8 = 256 bytes max)
         parameter HS_CFG_AW    = 2,       //! Max size of RAM address for highscore.dat entries (default 4 = 16 entries max)
         parameter HS_CFG_LW    = 2,       //! Max size of length for each highscore.dat entries (default 1 = 256 bytes max)
         parameter HS_CONFIG    = 2,       //! Dataslot index for config transfer
         parameter HS_DATA      = 3,       //! Dataslot index for save data transfer
         parameter HS_NVM_SZ    = 32'd93,  //! Number bytes required for Save
         parameter HS_MASK      = 4'h1,    //! Upper 4 bits of address
         parameter HS_WR_DELAY  = 4,       //! Number of clock cycles to delay each write output
         parameter HS_WR_HOLD   = 1,       //! Number of clock cycles to hold the nvram_wr signal high
         parameter HS_RD_DELAY  = 4,       //! Number of clock cycles it takes for a read to complete
         // Save I/O - [MPU <-> FPGA]
         parameter SIO_MASK     = 4'h1,    //! Upper 4 bits of address
         parameter SIO_AW       = 27,      //! Address Width
         parameter SIO_DW       = 8,       //! Data Width (8 or 16 bits)
         parameter SIO_WR_DELAY = 4,       //! Number of clock cycles to delay each write output
         parameter SIO_WR_HOLD  = 1,       //! Number of clock cycles to hold the nvram_wr signal high
         parameter SIO_RD_DELAY = 4,       //! Number of clock cycles it takes for a read to complete
         parameter SIO_SAVE_IDX = 2        //! Dataslot index for save data transfer
     ) (
         //! --------------------------------------------------------------------
         //! Clock Inputs 74.25mhz.
         //! Not Phase Aligned, Treat These Domains as Asynchronous
         //! --------------------------------------------------------------------
         input wire          clk_74a, // mainclk1
         input wire          clk_74b, // mainclk1

         //! --------------------------------------------------------------------
         //! Cartridge Interface
         //! --------------------------------------------------------------------
         inout  wire   [7:0] cart_tran_bank2,
         output wire         cart_tran_bank2_dir,
         inout  wire   [7:0] cart_tran_bank3,
         output wire         cart_tran_bank3_dir,
         inout  wire   [7:0] cart_tran_bank1,
         output wire         cart_tran_bank1_dir,
         inout  wire   [7:4] cart_tran_bank0,
         output wire         cart_tran_bank0_dir,
         inout  wire         cart_tran_pin30,
         output wire         cart_tran_pin30_dir,
         output wire         cart_pin30_pwroff_reset,
         inout  wire         cart_tran_pin31,
         output wire         cart_tran_pin31_dir,

         //! --------------------------------------------------------------------
         //! Infrared
         //! --------------------------------------------------------------------
         input  wire         port_ir_rx,
         output wire         port_ir_tx,
         output wire         port_ir_rx_disable,

         //! --------------------------------------------------------------------
         //! GBA link port
         //! --------------------------------------------------------------------
         inout  wire         port_tran_si,
         output wire         port_tran_si_dir,
         inout  wire         port_tran_so,
         output wire         port_tran_so_dir,
         inout  wire         port_tran_sck,
         output wire         port_tran_sck_dir,
         inout  wire         port_tran_sd,
         output wire         port_tran_sd_dir,

         //! --------------------------------------------------------------------
         //! Cellular PSRAM 0 and 1, two chips (64mbit x2 dual die per chip)
         //! --------------------------------------------------------------------
         output wire [21:16] cram0_a,
         inout  wire  [15:0] cram0_dq,
         input  wire         cram0_wait,
         output wire         cram0_clk,
         output wire         cram0_adv_n,
         output wire         cram0_cre,
         output wire         cram0_ce0_n,
         output wire         cram0_ce1_n,
         output wire         cram0_oe_n,
         output wire         cram0_we_n,
         output wire         cram0_ub_n,
         output wire         cram0_lb_n,

         output wire [21:16] cram1_a,
         inout  wire  [15:0] cram1_dq,
         input  wire         cram1_wait,
         output wire         cram1_clk,
         output wire         cram1_adv_n,
         output wire         cram1_cre,
         output wire         cram1_ce0_n,
         output wire         cram1_ce1_n,
         output wire         cram1_oe_n,
         output wire         cram1_we_n,
         output wire         cram1_ub_n,
         output wire         cram1_lb_n,

         //! --------------------------------------------------------------------
         //! SDRAM, 512mbit 16bit
         //! --------------------------------------------------------------------
         output wire  [12:0] dram_a,        // Address bus
         output wire   [1:0] dram_ba,       // Bank select (single bits)
         inout  wire  [15:0] dram_dq,       // Bidirectional data bus
         output wire   [1:0] dram_dqm,      // High/low byte mask
         output wire         dram_clk,      // Chip clock
         output wire         dram_cke,      // Clock enable
         output wire         dram_ras_n,    // Select row address (active low)
         output wire         dram_cas_n,    // Select column address (active low)
         output wire         dram_we_n,     // Write enable (active low)

         //! --------------------------------------------------------------------
         //! SRAM, 1mbit 16bit
         //! --------------------------------------------------------------------
         output wire  [16:0] sram_a,        // Address bus
         inout  wire  [15:0] sram_dq,       // Bidirectional data bus
         output wire         sram_oe_n,     // Output enable
         output wire         sram_we_n,     // Write enable
         output wire         sram_ub_n,     // Upper Byte Mask
         output wire         sram_lb_n,     // Lower Byte Mask

         //! --------------------------------------------------------------------
         //! vblank driven by dock for sync in a certain mode
         //! --------------------------------------------------------------------
         input  wire         vblank,

         //! --------------------------------------------------------------------
         //! I/O to 6515D breakout USB UART
         //! --------------------------------------------------------------------
         output wire         dbg_tx,
         input  wire         dbg_rx,

         //! --------------------------------------------------------------------
         //! I/O pads near jtag connector user can solder to
         //! --------------------------------------------------------------------
         output wire         user1,
         input  wire         user2,

         //! --------------------------------------------------------------------
         //! RFU internal i2c bus
         //! --------------------------------------------------------------------
         inout  wire         aux_sda,
         output wire         aux_scl,

         //! --------------------------------------------------------------------
         //! RFU, do not use !!!
         //! --------------------------------------------------------------------
         output wire         vpll_feed,

         //! --------------------------------------------------------------------
         //! Video Output to Scaler
         //! --------------------------------------------------------------------
         output wire  [23:0] video_rgb,
         output wire         video_rgb_clock,
         output wire         video_rgb_clock_90,
         output wire         video_hs,
         output wire         video_vs,
         output wire         video_de,
         output wire         video_skip,

         //! --------------------------------------------------------------------
         //! Audio
         //! --------------------------------------------------------------------
         output wire         audio_mclk,
         output wire         audio_lrck,
         output wire         audio_dac,
         input  wire         audio_adc,

         //! --------------------------------------------------------------------
         //! Bridge Bus Connection (synchronous to clk_74a)
         //! --------------------------------------------------------------------
         output wire         bridge_endian_little,
         input  wire  [31:0] bridge_addr,
         input  wire         bridge_rd,
         output reg   [31:0] bridge_rd_data,
         input  wire         bridge_wr,
         input  wire  [31:0] bridge_wr_data,

         //! --------------------------------------------------------------------
         //! Controller Data
         //! --------------------------------------------------------------------
         input  wire  [31:0] cont1_key,
         input  wire  [31:0] cont2_key,
         input  wire  [31:0] cont3_key,
         input  wire  [31:0] cont4_key,
         input  wire  [31:0] cont1_joy,
         input  wire  [31:0] cont2_joy,
         input  wire  [31:0] cont3_joy,
         input  wire  [31:0] cont4_joy,
         input  wire  [15:0] cont1_trig,
         input  wire  [15:0] cont2_trig,
         input  wire  [15:0] cont3_trig,
         input  wire  [15:0] cont4_trig
     );

    // not using the IR port, so turn off both the LED, and
    // disable the receive circuit to save power
    assign port_ir_tx         = 0;
    assign port_ir_rx_disable = 1;

    // bridge endianness
    assign bridge_endian_little = 0;

    // cart is unused unless the Analogizer has it (pocket_analogizer, below,
    // which holds these same levels until its menu entry enables it), so
    // set all level translators accordingly
    // directions are 0:IN, 1:OUT
    generate
        if(USE_ANALOGIZER == 0) begin
            assign cart_tran_bank3         = 8'hzz;
            assign cart_tran_bank3_dir     = 1'b0;
            assign cart_tran_bank2         = 8'hzz;
            assign cart_tran_bank2_dir     = 1'b0;
            assign cart_tran_bank1         = 8'hzz;
            assign cart_tran_bank1_dir     = 1'b0;
            assign cart_tran_bank0         = 4'hf;
            assign cart_tran_bank0_dir     = 1'b1;
            assign cart_tran_pin30         = 1'b0;  // reset or cs2, we let the hw control it by itself
            assign cart_tran_pin30_dir     = 1'bz;
            assign cart_pin30_pwroff_reset = 1'b0;  // hardware can control this
            assign cart_tran_pin31         = 1'bz;  // input
            assign cart_tran_pin31_dir     = 1'b0;  // input
        end
    endgenerate

    // link port is input only
    assign port_tran_so      = 1'bz;
    assign port_tran_so_dir  = 1'b0; // SO is output only
    assign port_tran_si      = 1'bz;
    assign port_tran_si_dir  = 1'b0; // SI is input only
    assign port_tran_sck     = 1'bz;
    assign port_tran_sck_dir = 1'b0; // clock direction can change
    assign port_tran_sd      = 1'bz;
    assign port_tran_sd_dir  = 1'b0; // SD is input and not used

    assign video_skip = 1'b0;

    assign dbg_tx    = 1'bZ;
    assign user1     = 1'bZ;
    assign aux_scl   = 1'bZ;
    assign vpll_feed = 1'bZ;

    // Tie off the memory the pins not being used
    generate
        if(USE_CRAM0 == 0) begin
            assign cram0_a     = 'h0;
            assign cram0_dq    = {16{1'bZ}};
            assign cram0_clk   = 0;
            assign cram0_adv_n = 1;
            assign cram0_cre   = 0;
            assign cram0_ce0_n = 1;
            assign cram0_ce1_n = 1;
            assign cram0_oe_n  = 1;
            assign cram0_we_n  = 1;
            assign cram0_ub_n  = 1;
            assign cram0_lb_n  = 1;
        end
        if(USE_CRAM1 == 0) begin
            assign cram1_a     = 'h0;
            assign cram1_dq    = {16{1'bZ}};
            assign cram1_clk   = 0;
            assign cram1_adv_n = 1;
            assign cram1_cre   = 0;
            assign cram1_ce0_n = 1;
            assign cram1_ce1_n = 1;
            assign cram1_oe_n  = 1;
            assign cram1_we_n  = 1;
            assign cram1_ub_n  = 1;
            assign cram1_lb_n  = 1;
        end
        if(USE_SDRAM == 0) begin
            assign dram_a     = 'h0;
            assign dram_ba    = 'h0;
            assign dram_dq    = {16{1'bZ}};
            assign dram_dqm   = 'h0;
            assign dram_clk   = 'h0;
            assign dram_cke   = 'h0;
            assign dram_ras_n = 'h1;
            assign dram_cas_n = 'h1;
            assign dram_we_n  = 'h1;
        end
        if(USE_SRAM == 0) begin
            assign sram_a    = 'h0;
            assign sram_dq   = {16{1'bZ}};
            assign sram_oe_n = 1;
            assign sram_we_n = 1;
            assign sram_ub_n = 1;
            assign sram_lb_n = 1;
        end
    endgenerate

    //! ------------------------------------------------------------------------
    //! Host/Target Command Handler
    //! ------------------------------------------------------------------------
    wire        reset_n;  // driven by host commands, can be used as core-wide reset
    wire [31:0] cmd_bridge_rd_data;

    // bridge host commands
    // synchronous to clk_74a
    wire        status_boot_done  = pll_core_locked_s;
    wire        status_setup_done = pll_core_locked_s; // rising edge triggers a target command
    wire        status_running    = reset_n;           // we are running as soon as reset_n goes high

    wire        dataslot_requestread;
    wire [15:0] dataslot_requestread_id;
    wire        dataslot_requestread_ack = 1;
    wire        dataslot_requestread_ok  = 1;

    wire        dataslot_requestwrite;
    wire [15:0] dataslot_requestwrite_id;
    wire [31:0] dataslot_requestwrite_size;
    wire        dataslot_requestwrite_ack = 1;
    wire        dataslot_requestwrite_ok  = 1;

    wire        dataslot_update;
    wire [15:0] dataslot_update_id;
    wire [31:0] dataslot_update_size;

    wire        dataslot_allcomplete;

    wire [31:0] rtc_epoch_seconds;
    wire [31:0] rtc_date_bcd;
    wire [31:0] rtc_time_bcd;
    wire        rtc_valid;

    wire        savestate_supported;
    wire [31:0] savestate_addr;
    wire [31:0] savestate_size;
    wire [31:0] savestate_maxloadsize;

    wire        savestate_start;
    wire        savestate_start_ack;
    wire        savestate_start_busy;
    wire        savestate_start_ok;
    wire        savestate_start_err;

    wire        savestate_load;
    wire        savestate_load_ack;
    wire        savestate_load_busy;
    wire        savestate_load_ok;
    wire        savestate_load_err;

    wire        osnotify_inmenu;

    // bridge target commands
    // synchronous to clk_74a; the save's and the drive's (ngage_slots, below)
    wire        target_dataslot_read;
    wire        target_dataslot_write;
    wire        target_dataslot_getfile  = 1'b0;   // require additional param/resp structs to be mapped
    wire        target_dataslot_openfile = 1'b0;   // require additional param/resp structs to be mapped

    wire        target_dataslot_ack;
    wire        target_dataslot_done;
    wire  [2:0] target_dataslot_err;

    wire [15:0] target_dataslot_id;
    wire [31:0] target_dataslot_slotoffset;
    wire [31:0] target_dataslot_bridgeaddr;
    wire [31:0] target_dataslot_length;

    wire [31:0] target_buffer_param_struct; // to be mapped/implemented when using some Target commands
    wire [31:0] target_buffer_resp_struct;  // to be mapped/implemented when using some Target commands

    // bridge data slot access
    // synchronous to clk_74a
    logic  [9:0] datatable_addr;
    logic        datatable_wren;
    logic [31:0] datatable_data;
    wire  [31:0] datatable_q;

    //! The save slot's size for the APF, written continuously as the NES
    //! core does, at entry position * 2 + 1 (METHODOLOGY 5.24).  The save is
    //! data.json's fifth slot (game list, kernel, firmware, drive, save), so
    //! entry 9: the game's C: drive, 1 MB (target/pocket/ngage_save.sv).
    localparam [31:0] NV_BYTES = 32'h100000;
    always_ff @(posedge clk_74a) begin
        datatable_wren <= 1'b1;
        datatable_addr <= 10'd9;
        datatable_data <= NV_BYTES;
    end

    core_bridge_cmd icb
    (
        .clk                        ( clk_74a                    ),
        .reset_n                    ( reset_n                    ),

        .bridge_endian_little       ( bridge_endian_little       ),
        .bridge_addr                ( bridge_addr                ),
        .bridge_rd                  ( bridge_rd                  ),
        .bridge_rd_data             ( cmd_bridge_rd_data         ),
        .bridge_wr                  ( bridge_wr                  ),
        .bridge_wr_data             ( bridge_wr_data             ),

        .status_boot_done           ( status_boot_done           ),
        .status_setup_done          ( status_setup_done          ),
        .status_running             ( status_running             ),

        .dataslot_requestread       ( dataslot_requestread       ),
        .dataslot_requestread_id    ( dataslot_requestread_id    ),
        .dataslot_requestread_ack   ( dataslot_requestread_ack   ),
        .dataslot_requestread_ok    ( dataslot_requestread_ok    ),

        .dataslot_requestwrite      ( dataslot_requestwrite      ),
        .dataslot_requestwrite_id   ( dataslot_requestwrite_id   ),
        .dataslot_requestwrite_size ( dataslot_requestwrite_size ),
        .dataslot_requestwrite_ack  ( dataslot_requestwrite_ack  ),
        .dataslot_requestwrite_ok   ( dataslot_requestwrite_ok   ),

        .dataslot_update            ( dataslot_update            ),
        .dataslot_update_id         ( dataslot_update_id         ),
        .dataslot_update_size       ( dataslot_update_size       ),

        .dataslot_allcomplete       ( dataslot_allcomplete       ),

        .rtc_epoch_seconds          ( rtc_epoch_seconds          ),
        .rtc_date_bcd               ( rtc_date_bcd               ),
        .rtc_time_bcd               ( rtc_time_bcd               ),
        .rtc_valid                  ( rtc_valid                  ),

        .savestate_supported        ( savestate_supported        ),
        .savestate_addr             ( savestate_addr             ),
        .savestate_size             ( savestate_size             ),
        .savestate_maxloadsize      ( savestate_maxloadsize      ),

        .savestate_start            ( savestate_start            ),
        .savestate_start_ack        ( savestate_start_ack        ),
        .savestate_start_busy       ( savestate_start_busy       ),
        .savestate_start_ok         ( savestate_start_ok         ),
        .savestate_start_err        ( savestate_start_err        ),

        .savestate_load             ( savestate_load             ),
        .savestate_load_ack         ( savestate_load_ack         ),
        .savestate_load_busy        ( savestate_load_busy        ),
        .savestate_load_ok          ( savestate_load_ok          ),
        .savestate_load_err         ( savestate_load_err         ),

        .osnotify_inmenu            ( osnotify_inmenu            ),

        .target_dataslot_read       ( target_dataslot_read       ),
        .target_dataslot_write      ( target_dataslot_write      ),
        .target_dataslot_getfile    ( target_dataslot_getfile    ),
        .target_dataslot_openfile   ( target_dataslot_openfile   ),

        .target_dataslot_ack        ( target_dataslot_ack        ),
        .target_dataslot_done       ( target_dataslot_done       ),
        .target_dataslot_err        ( target_dataslot_err        ),

        .target_dataslot_id         ( target_dataslot_id         ),
        .target_dataslot_slotoffset ( target_dataslot_slotoffset ),
        .target_dataslot_bridgeaddr ( target_dataslot_bridgeaddr ),
        .target_dataslot_length     ( target_dataslot_length     ),

        .target_buffer_param_struct ( target_buffer_param_struct ),
        .target_buffer_resp_struct  ( target_buffer_resp_struct  ),

        .datatable_addr             ( datatable_addr             ),
        .datatable_wren             ( datatable_wren             ),
        .datatable_data             ( datatable_data             ),
        .datatable_q                ( datatable_q                )
    );

    //! END OF APF /////////////////////////////////////////////////////////////

    //! ////////////////////////////////////////////////////////////////////////
    //! @ System Modules
    //! ////////////////////////////////////////////////////////////////////////

    //! ------------------------------------------------------------------------
    //! APF Bridge Read Data
    //! ------------------------------------------------------------------------
    wire [31:0] int_bridge_rd_data;
    wire [31:0] ana_bridge_rd_data;
    wire [31:0] km_bridge_rd_data;
    wire [31:0] sv_bridge_rd_data;
    always_comb begin
        casex(bridge_addr)
            32'h2xxxxxxx: begin bridge_rd_data <= sv_bridge_rd_data;    end // The save (slot 4)
            32'hF0000000: begin bridge_rd_data <= int_bridge_rd_data;   end // Reset
            32'hF0000010: begin bridge_rd_data <= int_bridge_rd_data;   end // Service Mode Switch
            32'hF1000000: begin bridge_rd_data <= int_bridge_rd_data;   end // DIP Switches
            32'hF2000000: begin bridge_rd_data <= int_bridge_rd_data;   end // Modifiers
            32'hF3000000: begin bridge_rd_data <= int_bridge_rd_data;   end // A/V Filters
            32'hF4000000: begin bridge_rd_data <= int_bridge_rd_data;   end // Extra DIP Switches
            32'hF50000xx: begin bridge_rd_data <= km_bridge_rd_data;    end // Phone keys for A B X Y L R
            32'hF7xxxxxx: begin bridge_rd_data <= ana_bridge_rd_data;   end // Analogizer settings (menu)
            32'hF8xxxxxx: begin bridge_rd_data <= cmd_bridge_rd_data;   end // APF Bridge (Reserved)
            32'hFA000000: begin bridge_rd_data <= int_bridge_rd_data;   end // Status Low  [31:0]
            32'hFB000000: begin bridge_rd_data <= int_bridge_rd_data;   end // Status High [63:32]
            default:      begin bridge_rd_data <= 0;                    end
        endcase
    end

    //! ------------------------------------------------------------------------
    //! Pause Core (Analogue OS Menu/Module Request)
    //! ------------------------------------------------------------------------
    wire pause_core, pause_req;
    pause_crtl core_pause
    (
        .clk_sys    ( clk_sys         ),
        .os_inmenu  ( osnotify_inmenu ),
        .pause_req  ( pause_req       ),
        .pause_core ( pause_core      )
    );

    //! ------------------------------------------------------------------------
    //! Interact: Dip Switches, Modifiers, Filters and Reset
    //! ------------------------------------------------------------------------
    wire  [7:0] dip_sw0, dip_sw1, dip_sw2, dip_sw3;
    wire  [7:0] ext_sw0, ext_sw1, ext_sw2, ext_sw3;
    wire  [7:0] mod_sw0, mod_sw1, mod_sw2, mod_sw3;
    wire  [3:0] scnl_sw, smask_sw, afilter_sw, vol_att;
    wire [63:0] status;
    wire        reset_sw, svc_sw, nvclear_sw;

    interact pocket_interact
    (
        // Clocks and Reset
        .clk_74a          ( clk_74a            ),
        .clk_sync         ( clk_sys            ),
        .reset_n          ( reset_n            ),
        // Pocket Bridge
        .bridge_addr      ( bridge_addr        ),
        .bridge_wr        ( bridge_wr          ),
        .bridge_wr_data   ( bridge_wr_data     ),
        .bridge_rd        ( bridge_rd          ),
        .bridge_rd_data   ( int_bridge_rd_data ),
        // Service Mode Switch
        .svc_sw           ( svc_sw             ),
        // DIP Switches
        .dip_sw0          ( dip_sw0            ),
        .dip_sw1          ( dip_sw1            ),
        .dip_sw2          ( dip_sw2            ),
        .dip_sw3          ( dip_sw3            ),
        // Extra DIP Switches
        .ext_sw0          ( ext_sw0            ),
        .ext_sw1          ( ext_sw1            ),
        .ext_sw2          ( ext_sw2            ),
        .ext_sw3          ( ext_sw3            ),
        // Modifiers
        .mod_sw0          ( mod_sw0            ),
        .mod_sw1          ( mod_sw1            ),
        .mod_sw2          ( mod_sw2            ),
        .mod_sw3          ( mod_sw3            ),
        // Status (Legacy Support)
        .status           ( status             ),
        // Filters Switches
        .scnl_sw          ( scnl_sw            ),
        .smask_sw         ( smask_sw           ),
        .afilter_sw       ( afilter_sw         ),
        .vol_att          ( vol_att            ),
        // Reset Switch
        .reset_sw         ( reset_sw           ),
        .nvclear_sw       ( nvclear_sw         )
    );

    //! ------------------------------------------------------------------------
    //! Audio
    //! ------------------------------------------------------------------------
    wire [AUDIO_DW-1:0] core_snd_l, core_snd_r; // Audio Mono/Left/Right

    audio_mixer #(.DW(AUDIO_DW),.STEREO(STEREO),.IIR(0)) pocket_audio_mixer
    (
        // Clocks and Reset
        .clk_74b    ( clk_74b    ),
        .reset      ( reset_sw   ),
        // Controls
        .afilter_sw ( afilter_sw ),
        .vol_att    ( vol_att    ),
        .mix        ( AUDIO_MIX  ),
        .pause_core ( pause_core ),
        // Audio From Core
        .is_signed  ( AUDIO_S    ),
        .core_l     ( core_snd_l ),
        .core_r     ( core_snd_r ),
        // I2S
        .audio_mclk ( audio_mclk ),
        .audio_lrck ( audio_lrck ),
        .audio_dac  ( audio_dac  )
    );

    //! ------------------------------------------------------------------------
    //! Video
    //! ------------------------------------------------------------------------
    wire       [2:0] video_preset;     // Video Preset Configuration
    wire [BPP_R-1:0] core_r;           // Video Red
    wire [BPP_G-1:0] core_g;           // Video Green
    wire [BPP_B-1:0] core_b;           // Video Blue
    wire             core_hs, core_hb; // Horizontal Sync/Blank
    wire             core_vs, core_vb; // Vertical Sync/Blank
    wire             core_de;          // Display Enable

    assign core_hb = 1'b0;
    assign core_vb = 1'b0;

    video_mixer #(.RW(BPP_R),.GW(BPP_G),.BW(BPP_B)) pocket_video_mixer
    (
        // Clocks
        .clk_74a                  ( clk_74a                  ),
        .clk_sys                  ( clk_sys                  ),
        .clk_vid                  ( clk_vid                  ),
        .clk_vid_90deg            ( clk_vid_90deg            ),
        // Input Controls
        .video_preset             ( video_preset             ),
        .scnl_sw                  ( scnl_sw                  ),
        .smask_sw                 ( smask_sw                 ),
        // Input Video from Core
        .core_r                   ( core_r                   ),
        .core_g                   ( core_g                   ),
        .core_b                   ( core_b                   ),
        .core_vs                  ( core_vs                  ),
        .core_hs                  ( core_hs                  ),
        .core_de                  ( core_de                  ),
        // Output to Display
        .video_rgb                ( video_rgb                ),
        .video_vs                 ( video_vs                 ),
        .video_hs                 ( video_hs                 ),
        .video_de                 ( video_de                 ),
        .video_rgb_clock          ( video_rgb_clock          ),
        .video_rgb_clock_90       ( video_rgb_clock_90       ),
        // Pocket Bridge Slots
        .dataslot_requestwrite    ( dataslot_requestwrite    ), // [i]
        .dataslot_requestwrite_id ( dataslot_requestwrite_id ), // [i]
        .dataslot_allcomplete     ( dataslot_allcomplete     ), // [i]
        // MPU -> FPGA (MPU Write to FPGA)
        // Pocket Bridge
        .bridge_endian_little     ( bridge_endian_little     ), // [i]
        .bridge_addr              ( bridge_addr              ), // [i]
        .bridge_wr                ( bridge_wr                ), // [i]
        .bridge_wr_data           ( bridge_wr_data           )  // [i]
    );

    //! ------------------------------------------------------------------------
    //! Data I/O
    //! ------------------------------------------------------------------------
    wire              ioctl_download;
    wire       [15:0] ioctl_index;
    wire              ioctl_wr;
    wire [DIO_AW-1:0] ioctl_addr;
    wire [DIO_DW-1:0] ioctl_data;

    data_io #(.MASK(DIO_MASK),.AW(DIO_AW),.DW(DIO_DW),.DELAY(DIO_DELAY),.HOLD(DIO_HOLD)) pocket_data_io
    (
        // Clocks and Reset
        .clk_74a                  ( clk_74a                  ),
        .clk_memory               ( clk_sys                  ),
        // Pocket Bridge Slots
        .dataslot_requestwrite    ( dataslot_requestwrite    ), // [i]
        .dataslot_requestwrite_id ( dataslot_requestwrite_id ), // [i]
        .dataslot_allcomplete     ( dataslot_allcomplete     ), // [i]
        // MPU -> FPGA (MPU Write to FPGA)
        // Pocket Bridge
        .bridge_endian_little     ( bridge_endian_little     ), // [i]
        .bridge_addr              ( bridge_addr              ), // [i]
        .bridge_wr                ( bridge_wr                ), // [i]
        .bridge_wr_data           ( bridge_wr_data           ), // [i]
        // Controller Interface
        .ioctl_download           ( ioctl_download           ), // [o]
        .ioctl_index              ( ioctl_index              ), // [o]
        .ioctl_wr                 ( ioctl_wr                 ), // [o]
        .ioctl_addr               ( ioctl_addr               ), // [o]
        .ioctl_data               ( ioctl_data               )  // [o]
    );

    //! The save (data.json slot 4) at bridge 0x20000000, with a loader of its
    //! own (METHODOLOGY 5.24); the dl mux below puts it at bus 0x1F00000.
    wire        nv_wr;
    wire [19:0] nv_addr;
    wire  [7:0] nv_data;

    data_io #(.MASK(4'h2),.AW(20),.DW(8),.DELAY(DIO_DELAY),.HOLD(DIO_HOLD)) pocket_nv_io
    (
        .clk_74a                  ( clk_74a                  ),
        .clk_memory               ( clk_sys                  ),
        .dataslot_requestwrite    ( dataslot_requestwrite    ), // [i]
        .dataslot_requestwrite_id ( dataslot_requestwrite_id ), // [i]
        .dataslot_allcomplete     ( dataslot_allcomplete     ), // [i]
        .bridge_endian_little     ( bridge_endian_little     ), // [i]
        .bridge_addr              ( bridge_addr              ), // [i]
        .bridge_wr                ( bridge_wr                ), // [i]
        .bridge_wr_data           ( bridge_wr_data           ), // [i]
        .ioctl_download           (                          ), // [o] as pocket_data_io's
        .ioctl_index              (                          ), // [o]
        .ioctl_wr                 ( nv_wr                    ), // [o]
        .ioctl_addr               ( nv_addr                  ), // [o]
        .ioctl_data               ( nv_data                  )  // [o]
    );

    //! ------------------------------------------------------------------------
    //! Gamepad/Analog Stick
    //! ------------------------------------------------------------------------
    // Player 1
    // - DPAD
    wire       p1_up,     p1_down,   p1_left,   p1_right;
    wire       p1_btn_y,  p1_btn_x,  p1_btn_b,  p1_btn_a;
    wire       p1_btn_l1, p1_btn_l2, p1_btn_l3;
    wire       p1_btn_r1, p1_btn_r2, p1_btn_r3;
    wire       p1_select, p1_start;
    // - Analog
    wire       j1_up,     j1_down,   j1_left,   j1_right;
    wire [7:0] j1_lx,     j1_ly,     j1_rx,     j1_ry;
    // Player 2
    // - DPAD
    wire       p2_up,     p2_down,   p2_left,   p2_right;
    wire       p2_btn_y,  p2_btn_x,  p2_btn_b,  p2_btn_a;
    wire       p2_btn_l1, p2_btn_l2, p2_btn_l3;
    wire       p2_btn_r1, p2_btn_r2, p2_btn_r3;
    wire       p2_select, p2_start;
    // - Analog
    wire       j2_up,     j2_down,   j2_left,   j2_right;
    wire [7:0] j2_lx,     j2_ly,     j2_rx,     j2_ry;
    // Single Player or Alternate 2 Players for Arcade (unused: both players are wired)
    wire m_start1, m_start2;
    wire m_coin1,  m_coin2, m_coin;
    wire m_up,     m_down,  m_left, m_right;
    wire m_btn1,   m_btn2,  m_btn3, m_btn4;
    wire m_btn5,   m_btn6,  m_btn7, m_btn8;

    //! The controller words the game reads: the Pocket's, or with the
    //! Analogizer enabled, SNAC pads put in their place (pocket_analogizer.sv,
    //! below).  Use key1..key4 wherever a core would read cont1..4_key.
    wire [31:0] key1, key2, key3, key4;

    gamepad #(.JOY_PADS(JOY_PADS),.JOY_ALT(JOY_ALT)) pocket_gamepad
    (
        .clk_sys   ( clk_sys   ),
        // Pocket PAD Interface
        .cont1_key ( key1      ), .cont1_joy ( cont1_joy ),
        .cont2_key ( key2      ), .cont2_joy ( cont2_joy ),
        .cont3_key ( key3      ), .cont3_joy ( cont3_joy ),
        .cont4_key ( key4      ), .cont4_joy ( cont4_joy ),
        // Player 1
        .p1_up     ( p1_up     ), .p1_down   ( p1_down   ),
        .p1_left   ( p1_left   ), .p1_right  ( p1_right  ),
        .p1_y      ( p1_btn_y  ), .p1_x      ( p1_btn_x  ),
        .p1_b      ( p1_btn_b  ), .p1_a      ( p1_btn_a  ),
        .p1_l1     ( p1_btn_l1 ), .p1_r1     ( p1_btn_r1 ),
        .p1_l2     ( p1_btn_l2 ), .p1_r2     ( p1_btn_r2 ),
        .p1_l3     ( p1_btn_l3 ), .p1_r3     ( p1_btn_r3 ),
        .p1_se     ( p1_select ), .p1_st     ( p1_start  ),
        .j1_up     ( j1_up     ), .j1_down   ( j1_down   ),
        .j1_left   ( j1_left   ), .j1_right  ( j1_right  ),
        .j1_lx     ( j1_lx     ), .j1_ly     ( j1_ly     ),
        .j1_rx     ( j1_rx     ), .j1_ry     ( j1_ry     ),
        // Player 2
        .p2_up     ( p2_up     ), .p2_down   ( p2_down   ),
        .p2_left   ( p2_left   ), .p2_right  ( p2_right  ),
        .p2_y      ( p2_btn_y  ), .p2_x      ( p2_btn_x  ),
        .p2_b      ( p2_btn_b  ), .p2_a      ( p2_btn_a  ),
        .p2_l1     ( p2_btn_l1 ), .p2_r1     ( p2_btn_r1 ),
        .p2_l2     ( p2_btn_l2 ), .p2_r2     ( p2_btn_r2 ),
        .p2_l3     ( p2_btn_l3 ), .p2_r3     ( p2_btn_r3 ),
        .p2_se     ( p2_select ), .p2_st     ( p2_start  ),
        .j2_up     ( j2_up     ), .j2_down   ( j2_down   ),
        .j2_left   ( j2_left   ), .j2_right  ( j2_right  ),
        .j2_lx     ( j2_lx     ), .j2_ly     ( j2_ly     ),
        .j2_rx     ( j2_rx     ), .j2_ry     ( j2_ry     ),
        // Single Player or Alternate 2 Players for Arcade
        .m_coin    ( m_coin    ),                           // Coinage P1 or P2
        .m_up      ( m_up      ), .m_down    ( m_down    ), // Up/Down
        .m_left    ( m_left    ), .m_right   ( m_right   ), // Left/Right
        .m_btn1    ( m_btn1    ), .m_btn4    ( m_btn4    ), // Y/X
        .m_btn2    ( m_btn2    ), .m_btn3    ( m_btn3    ), // B/A
        .m_btn5    ( m_btn5    ), .m_btn6    ( m_btn6    ), // L1/R1
        .m_btn7    ( m_btn7    ), .m_btn8    ( m_btn8    ), // L2/R2
        .m_coin1   ( m_coin1   ), .m_coin2   ( m_coin2   ), // P1/P2 Coin
        .m_start1  ( m_start1  ), .m_start2  ( m_start2  )  // P1/P2 Start
    );

    //! ------------------------------------------------------------------------
    //! Clocks
    //! ------------------------------------------------------------------------
    wire pll_core_locked, pll_core_locked_s;
    wire clk_sys;       // Memories, LCD: 96.0 MHz
    wire clk_vid;       // Video: 6.857 MHz dot clock, exactly clk_sys / 14, half a system cycle late
    wire clk_vid_90deg; // Video: 6.857 MHz @ 90deg (Pocket RGB clock pair)
    wire clk_sdram;     // SDRAM chip clock: 96.0 MHz, phase-shifted (see the SDC)
    wire clk_ana;       // Analogizer: 48.0 MHz, clk_sys / 2, in phase with it
    wire clk_cpu;       // NGVM's CPU side: CPU_HZ, from cpu_pll, asynchronous to the rest by design

    core_pll core_pll
    (
        .refclk   ( clk_74a ),
        .rst      ( 0       ),
        .outclk_0 ( clk_sys       ),
        .outclk_1 ( clk_vid       ),
        .outclk_2 ( clk_vid_90deg ),
        .outclk_3 ( clk_sdram     ),
        .outclk_4 ( clk_ana       ),
        .outclk_5 (               ),
        .locked   ( pll_core_locked )
    );

    // the CPU's clock: a PLL of its own, so its frequency is this one number
    localparam int CPU_HZ = 80_000_000;
    wire pll_cpu_locked, pll_cpu_locked_sys;
    cpu_pll #(.FREQ("80.000000 MHz")) cpu_pll
    (
        .refclk   ( clk_74a ),
        .rst      ( 0       ),
        .outclk_0 ( clk_cpu ),
        .locked   ( pll_cpu_locked )
    );

    // Synchronize pll_core_locked into clk_74a domain before usage
    synch_3 sync_lck(pll_core_locked, pll_core_locked_s, clk_74a);

    //! ------------------------------------------------------------------------
    //! @ The game
    //! ------------------------------------------------------------------------
    wire reset_sw_s;
    synch_3 sync_rst(reset_sw, reset_sw_s, clk_sys);
    wire pll_locked_sys;
    synch_3 sync_lck2(pll_core_locked, pll_locked_sys, clk_sys);
    synch_3 sync_lck3(pll_cpu_locked, pll_cpu_locked_sys, clk_sys);

    //! The SDRAM initialises on the hardware reset; the machine is held until
    //! the SDRAM is ready and the host's first "all complete" has been seen
    //! (sticky, because the bridge clears all-complete on any later slot
    //! request), and by the menu's reset switch.  A reset runs the kernel
    //! again over the memory as the last run left it: the kernel restores
    //! its own data at boot (sw/kernel/kernel.ld), nothing writes SYM.ROM,
    //! and what a game saved to its drive stays there, as on the phone.
    wire mem_init  = ~pll_locked_sys;
    wire mem_ready;
    logic loaded = 1'b0;
    wire  allc_s;
    synch_3 sync_allc(dataslot_allcomplete, allc_s, clk_sys);
    always_ff @(posedge clk_sys) if (allc_s) loaded <= 1'b1;
    wire  g_reset = reset_sw_s | ~loaded | ~mem_ready | ~pll_cpu_locked_sys;

    //! The slots (data.json) arrive at their bus addresses: the kernel at 0,
    //! SYM.ROM at 0x2000000, the game's drive image at 0x4000000, and the
    //! save (its own loader, bridge 0x20000000) at 0x1F00000, the top MB of
    //! NGVM's RAM.  ngage_mem.sv routes each by its address and takes a byte
    //! on its strobe's rising edge; change the two together.  A fetch into
    //! the drive's window (ngage_slots, below) comes the same way, with or
    //! without data_io's download raised: dl_fetch lets it in.
    wire        dl_fetch;
    wire        dl_open = ioctl_download || dl_fetch;
    wire        dl_we   = dl_open && (ioctl_wr || nv_wr);
    wire [26:0] dl_addr = nv_wr ? 27'h1F00000 + 27'(nv_addr) : ioctl_addr[26:0];
    wire  [7:0] dl_data = nv_wr ? nv_data : ioctl_data;

    //! Controls, as the kernel reads them (IO_KEYS, sw/include/ngvm_hw.h):
    //! bit 0 up, 1 down, 2 left, 3 right, 4 A, 5 B, 6 X, 7 Y, 8 L, 9 R,
    //! 10 select, 11 start, and 12-26 the on-screen keypad's phone keys;
    //! 1 = pressed.  The pad reaches IO_KEYS through the keypad
    //! (rtl/ngage_osk.sv, below the machine), which has it while it is up
    //! and keeps its SELECT + R chord from the machine.  The kernel maps
    //! them to the phone's keys (docs/hardware.md).
    wire [11:0] g_pad = {p1_start, p1_select, p1_btn_r1, p1_btn_l1,
                         p1_btn_y, p1_btn_x, p1_btn_b, p1_btn_a,
                         p1_right | j1_right, p1_left | j1_left,
                         p1_down  | j1_down,  p1_up   | j1_up};
    wire [26:0] g_keys;

    //! The phone key each of A, B, X, Y, L and R presses (IO_KEYMAP,
    //! sw/include/ngvm_hw.h): six sliders of interact.json, a word each at
    //! 0xF5000000 (A) to 0xF5000014 (R), 0-9 a digit key, 10 the default
    //! (sw/kernel/event.c).  IO_KEYMAP holds 4 bits a button, A in 3:0: the
    //! digit plus one, or 0 for the default, so that a bench which leaves
    //! the port at 0 has the default keys.  It starts at interact.json's
    //! defaults: A 5, B 7, Y 9.
    reg  [23:0] g_keymap;
    initial g_keymap = 24'h00A086;
    wire  [2:0] km_sel = bridge_addr[4:2];
    wire        km_hit = bridge_addr[31:24] == 8'hF5 && bridge_addr[23:5] == 19'd0 && km_sel < 3'd6;
    wire  [3:0] km_f   = (bridge_wr_data <= 32'd9) ? bridge_wr_data[3:0] + 4'd1 : 4'd0;
    always @(posedge clk_74a)
        if (bridge_wr && km_hit)
            case (km_sel)
                3'd0: g_keymap[3:0]   <= km_f;
                3'd1: g_keymap[7:4]   <= km_f;
                3'd2: g_keymap[11:8]  <= km_f;
                3'd3: g_keymap[15:12] <= km_f;
                3'd4: g_keymap[19:16] <= km_f;
                default: g_keymap[23:20] <= km_f;
            endcase
    //! read back as the slider wrote it
    wire  [3:0] km_rd_f = km_sel == 3'd0 ? g_keymap[3:0]   : km_sel == 3'd1 ? g_keymap[7:4]   :
                          km_sel == 3'd2 ? g_keymap[11:8]  : km_sel == 3'd3 ? g_keymap[15:12] :
                          km_sel == 3'd4 ? g_keymap[19:16] : g_keymap[23:20];
    assign km_bridge_rd_data = !km_hit ? 32'd0 : (km_rd_f == 4'd0) ? 32'd10 : {28'd0, km_rd_f - 4'd1};

    //! SDRAM switches from the modifier word (the "SDRAM" entries of
    //! interact.json): bit 4 catches read data at READ+4 instead of READ+3,
    //! 5 slows bursts to a READ every 5 clocks, 6 issues a burst's READs every
    //! 2 clocks instead of every clock, 7 a burst's WRITEs every 2 clocks
    //! instead of every clock.  Each bit is 0 at the setting tested on the
    //! Pocket (docs/bringup.md, log; bit 7's from NBA Jam, METHODOLOGY 5.28).  The menu no longer offers
    //! these, nor the bring-up panel (bit 3), since 0.2.0: their place went to
    //! the six key sliders (Analogue's limit is 16 entries).  An entry put
    //! back in interact.json sets its bit again.
    wire g_rd_late    =  mod_sw0[4];
    wire g_burst_slow =  mod_sw0[5];
    wire g_rd_fast    = ~mod_sw0[6];
    wire g_wr_fast    = ~mod_sw0[7];

    // NGVM's bus and the LCD's line fetch, between the machine and the memories
    wire         m_req, m_done;
    wire   [1:0] m_cmd;
    wire  [26:0] m_addr;
    wire  [26:5] m_waddr;
    wire  [31:0] m_be;
    wire [255:0] m_wdata, m_rdata;
    wire         m_free;
    wire   [3:0] m_cnt;
    wire         l_req, l_wr, l_done;
    wire  [25:1] l_addr;
    wire   [5:0] l_len;
    wire   [4:0] l_idx;
    wire  [15:0] l_data;
    wire  [31:0] rom_size, drive_size, save_size;
    wire         dl_idle;
    wire         c_l_req, c_l_wr, c_l_done;     // the LCD's side of ngage_save
    wire  [25:1] c_l_addr;
    wire   [5:0] c_l_len;
    wire   [4:0] c_l_idx;
    wire  [15:0] c_l_data;
    wire         save_t;
    wire         fetch_t, fetch_done_t;         // a fetch into the drive's window
    wire  [31:0] fetch_src, fetch_dst, fetch_len;
    wire   [2:0] fetch_err;

    ngage_mem u_mem (
        .clk(clk_sys), .clk_sdram(clk_sdram), .init(mem_init), .ready(mem_ready),
        .rd_late(g_rd_late), .burst_slow(g_burst_slow), .rd_fast(g_rd_fast), .wr_fast(g_wr_fast),
        .sram_slow(1'b0), .sram_slow_wr(1'b0),
        .dl_we(dl_we), .dl_addr(dl_addr), .dl_data(dl_data), .dl_active(dl_open),
        .dl_fetch(dl_fetch), .dl_idle(dl_idle),
        .rom_size(rom_size), .drive_size(drive_size), .save_size(save_size),
        .m_req(m_req), .m_cmd(m_cmd), .m_addr(m_addr), .m_waddr(m_waddr), .m_be(m_be), .m_wdata(m_wdata),
        .m_done(m_done), .m_rdata(m_rdata), .m_free(m_free), .m_cnt(m_cnt),
        .l_req(l_req), .l_addr(l_addr), .l_len(l_len),
        .l_wr(l_wr), .l_idx(l_idx), .l_data(l_data), .l_done(l_done),
        .vram_req(1'b0), .vram_we(1'b0), .vram_addr(15'd0), .vram_din(16'd0), .vram_ben(2'b00),
        .vram_ack(), .vram_q(),
        .SDRAM_DQ(dram_dq), .SDRAM_A(dram_a), .SDRAM_BA(dram_ba),
        .SDRAM_DQML(dram_dqm[0]), .SDRAM_DQMH(dram_dqm[1]),
        .SDRAM_CLK(dram_clk), .SDRAM_CKE(dram_cke),
        .SDRAM_nRAS(dram_ras_n), .SDRAM_nCAS(dram_cas_n), .SDRAM_nWE(dram_we_n),
        .SDRAM_nCS(),
        .cram0_a(cram0_a), .cram0_dq(cram0_dq), .cram0_clk(cram0_clk),
        .cram0_adv_n(cram0_adv_n), .cram0_cre(cram0_cre),
        .cram0_ce0_n(cram0_ce0_n), .cram0_ce1_n(cram0_ce1_n),
        .cram0_oe_n(cram0_oe_n), .cram0_we_n(cram0_we_n),
        .cram0_ub_n(cram0_ub_n), .cram0_lb_n(cram0_lb_n),
        .cram1_a(cram1_a), .cram1_dq(cram1_dq), .cram1_clk(cram1_clk),
        .cram1_adv_n(cram1_adv_n), .cram1_cre(cram1_cre),
        .cram1_ce0_n(cram1_ce0_n), .cram1_ce1_n(cram1_ce1_n),
        .cram1_oe_n(cram1_oe_n), .cram1_we_n(cram1_we_n),
        .cram1_ub_n(cram1_ub_n), .cram1_lb_n(cram1_lb_n),
        .sram_a(sram_a), .sram_dq(sram_dq),
        .sram_oe_n(sram_oe_n), .sram_we_n(sram_we_n),
        .sram_ub_n(sram_ub_n), .sram_lb_n(sram_lb_n)
    );

    //! ------------------------------------------------------------------
    //! The game's save: its C: drive, the top MB of NGVM's RAM, which the
    //! kernel keeps when the slot loaded an LFFS image into it and erases
    //! otherwise (sw/kernel/drive.c).  The Pocket reads it back through
    //! ngage_save, which shares the LCD's port to the memories.  Its
    //! buffers go stale on the save's own bytes, not on data_io's download:
    //! if the Pocket sends a request write (0x0082) before it answers a
    //! drive fetch, the download stays up until an all-complete that may
    //! never come, and the buffers would never be fetched again.
    //! ------------------------------------------------------------------
    ngage_save u_save (
        .clk_74a(clk_74a), .bridge_rd(bridge_rd), .bridge_endian_little(bridge_endian_little),
        .bridge_addr(bridge_addr), .bridge_rd_data(sv_bridge_rd_data),
        .clk(clk_sys), .rst(~mem_ready), .dl_active(nv_wr), .save_t(save_t),
        .a_req(c_l_req), .a_addr(c_l_addr), .a_len(c_l_len),
        .a_wr(c_l_wr), .a_idx(c_l_idx), .a_data(c_l_data), .a_done(c_l_done),
        .l_req(l_req), .l_addr(l_addr), .l_len(l_len),
        .l_wr(l_wr), .l_idx(l_idx), .l_data(l_data), .l_done(l_done)
    );

    //! ------------------------------------------------------------------
    //! The slots the core reads and writes itself (target/pocket/
    //! ngage_slots.sv), by APF target commands.  The save: the core has the
    //! Pocket write it (METHODOLOGY 5.24) 2 s after the kernel last wrote C:
    //! (IO_SAVE_DIRTY, save_t), when the Pocket's menu opens with a write
    //! pending, and once 5 s after the load, so that the file exists from the
    //! first run.  The drive: for an image larger than its 32 MB window, the
    //! kernel has blocks of the rest read into the window (IO_FETCH_*).
    //! ------------------------------------------------------------------
    ngage_slots #(.NV_BYTES(NV_BYTES)) u_slots (
        .clk_74a(clk_74a), .dataslot_allcomplete(dataslot_allcomplete), .osnotify_inmenu(osnotify_inmenu),
        .save_t(save_t),
        .fetch_t(fetch_t), .fetch_src(fetch_src), .fetch_dst(fetch_dst), .fetch_len(fetch_len),
        .fetch_done_t(fetch_done_t), .fetch_err(fetch_err),
        .clk(clk_sys), .dl_wr(ioctl_wr), .dl_idle(dl_idle), .fetching(dl_fetch),
        .target_dataslot_read(target_dataslot_read), .target_dataslot_write(target_dataslot_write),
        .target_dataslot_ack(target_dataslot_ack), .target_dataslot_done(target_dataslot_done),
        .target_dataslot_err(target_dataslot_err), .target_dataslot_id(target_dataslot_id),
        .target_dataslot_slotoffset(target_dataslot_slotoffset),
        .target_dataslot_bridgeaddr(target_dataslot_bridgeaddr),
        .target_dataslot_length(target_dataslot_length)
    );

    wire        g_pix_ce, g_hs, g_vs, g_de, g_vb, g_hb;
    wire [23:0] g_rgb;
    wire        t_cen, t_hs, t_vs, t_vb, t_hb, t_vis;
    wire [23:0] t_rgb;
    wire  [7:0] t_gx, t_gy;

    //! TATE: the "Analogizer" list's "On, TATE ..." options set bit 16 of
    //! the settings word, and bit 17 for a CRT turned anticlockwise.  The
    //! adapter module ignores both (docs/analogizer.md, the settings word);
    //! they are taken here from the bridge write, with the enable, and the
    //! LCD makes the turned raster the Analogizer then shows (ngvm_lcd.sv).
    reg  [1:0] tate_74 = 2'd0;
    always @(posedge clk_74a)
        if (bridge_wr && bridge_addr == 32'hF7000000)
            tate_74 <= !(bridge_wr_data[5] && bridge_wr_data[16]) ? 2'd0 : bridge_wr_data[17] ? 2'd2 : 2'd1;
    reg  [1:0] tate_m = 2'd0, tate_s = 2'd0;
    always @(posedge clk_sys) begin tate_m <= tate_74; tate_s <= tate_m; end
    wire [31:0] g_snd;
    wire        g_snd_tog;
    wire [31:0] g_dbg_pc, g_dbg_chars;
    wire        g_exited, g_lcd_on;

    //! The dot enable's phase is pinned to clk_vid: the clock's own toggle,
    //! seen through two system-clock flops, restarts the core's dot divider
    //! (clk_enables.sv), so the colour stage settles a fixed number of system
    //! clocks before the clk_vid edge that samples it -- margin by
    //! construction rather than by the luck of the reset phase.
    reg  vt = 1'b0;
    reg  vt_s, vt_d;
    always @(posedge clk_vid) vt <= ~vt;
    always @(posedge clk_sys) begin vt_s <= vt; vt_d <= vt_s; end
    wire pix_sync = vt_s ^ vt_d;

    ngage_core #(.CPU_HZ(CPU_HZ)) u_core (
        //! pause_core is the Pocket's menu being open.  NGVM does not use it
        //! yet: the game runs on behind the menu.  It must never be ORed into
        //! reset, which would boot the phone again when the menu closed.
        .clk(clk_sys), .clk_cpu(clk_cpu), .rst(g_reset), .pause(pause_core), .pix_sync(pix_sync),
        .m_req(m_req), .m_cmd(m_cmd), .m_addr(m_addr), .m_waddr(m_waddr), .m_be(m_be), .m_wdata(m_wdata),
        .m_done(m_done), .m_rdata(m_rdata), .m_free(m_free), .m_cnt(m_cnt),
        .l_req(c_l_req), .l_addr(c_l_addr), .l_len(c_l_len),
        .l_wr(c_l_wr), .l_idx(c_l_idx), .l_data(c_l_data), .l_done(c_l_done),
        .keys(g_keys), .keymap(g_keymap), .rom_size(rom_size), .drive_size(drive_size),
        .save_size(save_size), .save_t(save_t),
        .fetch_t(fetch_t), .fetch_src(fetch_src), .fetch_dst(fetch_dst), .fetch_len(fetch_len),
        .fetch_done_t(fetch_done_t), .fetch_err(fetch_err),
        .rgb(g_rgb), .hsync(g_hs), .vsync(g_vs),
        .hblank(g_hb), .vblank(g_vb), .pix_ce(g_pix_ce), .de(g_de),
        .tate(tate_s), .t_cen(t_cen), .t_rgb(t_rgb),
        .t_hsync(t_hs), .t_vsync(t_vs), .t_hblank(t_hb), .t_vblank(t_vb), .t_de(),
        .t_gx(t_gx), .t_gy(t_gy), .t_vis(t_vis),
        .snd(g_snd), .snd_tog(g_snd_tog),
        .dbg_pc(g_dbg_pc), .dbg_chars(g_dbg_chars), .dbg_exited(g_exited), .dbg_lcd_on(g_lcd_on)
    );

    //! Screen shape from the Interact menu.  The aspect in video.json
    //! describes the raster BEFORE the scaler rotates it, so with a rotation
    //! of 90 or 270 the shape that reaches the panel is aspect_h:aspect_w
    //! (METHODOLOGY section 5.5).  Preset 0 is the default and is what the
    //! core shows before the Pocket has written the menu word.
    wire [1:0] aspect_sel = mod_sw0[2:1];
    assign video_preset = (aspect_sel == 2'd1) ? 3'd1 : 3'd0;

    //! ------------------------------------------------------------------
    //! The on-screen keypad (rtl/ngage_osk.sv; README, "On-screen keypad"),
    //! after the BBC Micro core's keyboard.  SELECT + R shows a phone's keys
    //! over the picture -- the soft keys, C, 1-9, *, 0, # -- and dismisses
    //! them; the d-pad moves over them, A or B presses one (IO_KEYS bits
    //! 12-26), Y moves the keypad to the other end of the screen.  While it
    //! is up it has the pad: bits 0-11 read 0.  SELECT and R reach the
    //! machine four frames late, so the chord never does.  sim/run_osk.sh
    //! checks every panel pixel against tools/make_osk_panel.py, every key
    //! it presses, and that nothing that drives it reaches IO_KEYS.
    //! Its colour for a dot is registered on the cen_pix that registers the
    //! LCD's, so the mux below sees the two together.
    //! ------------------------------------------------------------------
    wire osk_visible, osk_active, osk_pix, osk_held;
    wire osk_t_active, osk_t_pix, osk_t_held;
    ngage_osk u_osk (
        .clk(clk_sys), .rst(g_reset), .cen_pix(g_pix_ce), .de(g_de), .vsync(g_vs),
        .pad(g_pad), .keys(g_keys),
        .visible(osk_visible), .active(osk_active), .pix(osk_pix), .held(osk_held),
        .t_cen(t_cen), .t_vis(t_vis), .t_gx(t_gx), .t_gy(t_gy),
        .t_active(osk_t_active), .t_pix(osk_t_pix), .t_held(osk_t_held)
    );
    //! white keys on black, the key being pressed amber
    wire [23:0] osk_rgb = !osk_pix ? 24'h000000 : osk_held ? 24'hFFC000 : 24'hFFFFFF;
    wire [23:0] pic_rgb = osk_active ? osk_rgb : g_rgb;
    //! and on the turned picture, which has no bring-up panel
    wire [23:0] osk_t_rgb = !osk_t_pix ? 24'h000000 : osk_t_held ? 24'hFFC000 : 24'hFFFFFF;
    wire [23:0] t_pic_rgb = osk_t_active ? osk_t_rgb : t_rgb;

    //! ------------------------------------------------------------------
    //! The bring-up panel (rtl/dbg_overlay.sv, METHODOLOGY section 5.21), on
    //! the modifier word's bit 3.  Four rows of 32 squares on the bottom
    //! sixteen lines, green = 1, bit 31 of each row leftmost.  The raster
    //! runs while the machine is held in reset, so a black Pocket can still
    //! be read.  KEEP docs/bringup.md IN STEP WITH THIS: it is what the
    //! person holding the Pocket reads from.
    //!   row 0  1010 1010 | frame count | pll locked, memory ready,
    //!          downloading, all-complete, loaded, core reset, kernel
    //!          panicked, LCD on | keys 7:0
    //!   row 1  an instruction the CPU retired lately (its address)
    //!   row 2  the last four characters the kernel printed
    //!   row 3  KB loaded at 0x2000000 (SYM.ROM) | KB loaded at 0x4000000 (drive)
    //! ------------------------------------------------------------------
    wire        ovl_en = mod_sw0[3];
    logic [7:0] ovl_frames;
    logic       vb_d;
    always_ff @(posedge clk_sys) begin
        vb_d <= g_vb;
        if (g_vb && !vb_d) ovl_frames <= ovl_frames + 8'd1;
    end

    wire [127:0] ovl_status = {
        // row 0: the marker first, so a reading can check its own alignment
        8'b1010_1010, ovl_frames,
        pll_locked_sys, mem_ready, ioctl_download, allc_s,
        loaded, g_reset, g_exited, g_lcd_on,
        g_keys[7:0],
        // row 1: where the CPU is
        g_dbg_pc,
        // row 2: what the kernel said last
        g_dbg_chars,
        // row 3: what the loader delivered, in KB
        rom_size[25:10], drive_size[25:10]
    };

    wire [7:0] ovl_r, ovl_g, ovl_b;
    dbg_overlay #(.SQW(5)) ovl (
        .clk(clk_sys), .cen_pix(g_pix_ce), .enable(ovl_en), .de(g_de), .vsync(g_vs),
        .r_in(pic_rgb[23:16]), .g_in(pic_rgb[15:8]), .b_in(pic_rgb[7:0]),
        .status(ovl_status), .r_out(ovl_r), .g_out(ovl_g), .b_out(ovl_b)
    );

    //! ------------------------------------------------------------------
    //! Video.  The core emits one pixel per 6.857 MHz enable in the 96 MHz
    //! domain and holds it for the fourteen cycles; clk_vid is the same
    //! 6.857 MHz from the same PLL, half a system cycle after a system edge,
    //! so the sample is taken well inside the held value.
    //! ------------------------------------------------------------------
    reg [7:0] vr_q, vg_q, vb_q;
    reg       vhs_q, vvs_q, vde_q;
    always @(posedge clk_vid) begin
        vr_q  <= ovl_r; vg_q <= ovl_g; vb_q <= ovl_b;
        vhs_q <= g_hs; vvs_q <= g_vs; vde_q <= g_de;
    end
    //! "Analogizer: On, Pocket off" in the menu: the
    //! picture goes to the CRT only.  Syncs and DE keep running for the scaler.
    wire ana_pocket_off;
    reg  [1:0] poff_s = 2'b00;
    always @(posedge clk_vid) poff_s <= {poff_s[0], ana_pocket_off};
    assign core_r  = poff_s[1] ? 8'd0 : vr_q;
    assign core_g  = poff_s[1] ? 8'd0 : vg_q;
    assign core_b  = poff_s[1] ? 8'd0 : vb_q;
    assign core_hs = vhs_q;
    assign core_vs = vvs_q;
    assign core_de = vde_q;

    //! ------------------------------------------------------------------
    //! The Analogizer (target/pocket/pocket_analogizer.sv, docs/analogizer.md).
    //! It takes the same picture the Pocket gets -- bring-up panel included,
    //! so the panel can be read off a CRT -- and is held idle until the game
    //! is loaded.  Set from the core's menu (interact.json, 0xF7000000): with
    //! "Analogizer" off, the default, the cartridge port stays as an unused one
    //! and key1..key4 are cont1..4_key.
    //! SET LINE_LEN to the core's whole line in dots, blanking included (the
    //! scandoubler's line buffer: too short and the right of every doubled
    //! line is lost), and CLK_HZ to clk_ana's frequency.  sim/tb_analogizer.sv
    //! carries the same raster at its top: change the two together.
    //! With TATE on, the source is the LCD's turned raster instead (382 dots
    //! a line, inside LINE_LEN), registered on its own enable as the upright
    //! one is on g_pix_ce; the switch is a frame's glitch on the CRT.
    //! ------------------------------------------------------------------
    wire        a_tate = tate_s != 2'd0;
    wire        a_ce   = a_tate ? t_cen : g_pix_ce;
    wire [23:0] a_rgb  = a_tate ? t_pic_rgb : {ovl_r, ovl_g, ovl_b};
    wire        a_hs   = a_tate ? t_hs : g_hs;
    wire        a_vs   = a_tate ? t_vs : g_vs;
    wire        a_hb   = a_tate ? t_hb : g_hb;
    wire        a_vb   = a_tate ? t_vb : g_vb;
    generate
        if(USE_ANALOGIZER == 1) begin : analogizer
            pocket_analogizer #(.CLK_HZ(48_000_000), .LINE_LEN(452)) u_analogizer (
                .clk_74a(clk_74a), .clk(clk_ana), .rst(g_reset),
                .clk_src(clk_sys), .src_pix_ce(a_ce),
                .src_rgb(a_rgb),
                .src_hs(a_hs), .src_vs(a_vs), .src_hb(a_hb), .src_vb(a_vb),
                .bridge_addr(bridge_addr),
                .bridge_rd(bridge_rd), .bridge_rd_data(ana_bridge_rd_data),
                .bridge_wr(bridge_wr), .bridge_wr_data(bridge_wr_data),
                .cont1_key(cont1_key), .cont2_key(cont2_key),
                .cont3_key(cont3_key), .cont4_key(cont4_key),
                .key1(key1), .key2(key2), .key3(key3), .key4(key4),
                .ena(), .pocket_off(ana_pocket_off),
                .ps2_code_new(), .ps2_code(),
                .cart_tran_bank2(cart_tran_bank2), .cart_tran_bank2_dir(cart_tran_bank2_dir),
                .cart_tran_bank3(cart_tran_bank3), .cart_tran_bank3_dir(cart_tran_bank3_dir),
                .cart_tran_bank1(cart_tran_bank1), .cart_tran_bank1_dir(cart_tran_bank1_dir),
                .cart_tran_bank0(cart_tran_bank0), .cart_tran_bank0_dir(cart_tran_bank0_dir),
                .cart_tran_pin30(cart_tran_pin30), .cart_tran_pin30_dir(cart_tran_pin30_dir),
                .cart_pin30_pwroff_reset(cart_pin30_pwroff_reset),
                .cart_tran_pin31(cart_tran_pin31), .cart_tran_pin31_dir(cart_tran_pin31_dir)
            );
        end else begin : no_analogizer
            assign key1 = cont1_key; assign key2 = cont2_key;
            assign key3 = cont3_key; assign key4 = cont4_key;
            assign ana_bridge_rd_data = 32'h0;
            assign ana_pocket_off = 1'b0;
        end
    endgenerate

    //! ------------------------------------------------------------------
    //! Audio clock domain crossing (METHODOLOGY section 5.4).  NGVM's audio
    //! device plays a sample at the game's rate and flips g_snd_tog each
    //! time it changes (rtl/ngvm_io.sv), in the CPU's clock; the sample then
    //! stands for at least 1 / 48,000 s, so the audio side takes it whole
    //! when it sees the flip through three of its own flops.  The mixer
    //! holds it to its 48 kHz.
    //! ------------------------------------------------------------------
    logic [2:0]  snd_tog_s = 3'd0;
    logic [31:0] snd_xfer = 32'd0;
    always_ff @(posedge clk_74b) begin
        snd_tog_s <= {snd_tog_s[1:0], g_snd_tog};
        if (snd_tog_s[2] != snd_tog_s[1]) snd_xfer <= g_snd;
    end
    assign core_snd_l = snd_xfer[15:0];
    assign core_snd_r = snd_xfer[31:16];

endmodule

