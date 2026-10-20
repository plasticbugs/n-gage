//------------------------------------------------------------------------------
// NGVM's memory map as the gateware sees it: sw/include/ngvm_hw.h, in RTL.
// Change the two together (docs/hardware.md, "Change the header in all three
// or not at all").
//
// Every CPU address falls in one region.  The caches use the region to decide
// what is cached (docs/core-design.md 3), the miss handler to turn an address
// into a bus address, and anything outside every region is an abort, as in
// the lockstep bench's translate().
//
// Bus addresses are 27-bit byte addresses on the memory side:
//   0x0000000  RAM, 32 MB                     SDRAM
//   0x2000000  ROM (SYM.ROM), up to 20 MB     SDRAM
//   0x3400000  KSEC, 4 MB                     SDRAM
//   0x4000000  the drive image, up to 24 MB   CRAM
// The loader writes the Pocket's data slots to the same addresses.
//------------------------------------------------------------------------------
`default_nettype none

package ngvm_pkg;

typedef enum logic [3:0] {
    RG_NONE,            // nothing: an abort
    RG_KERN,            // 0x00000000, 1 MB: RAM pages 0-63, flat, cached
    RG_WIN,             // 0x00400000, 4 MB: the data window, paged, cached, tagged by IO_WIN_ID
    RG_PHYS,            // 0x20000000, 32 MB: all of RAM, flat, uncached
    RG_CHUNK,           // 0x40000000, 256 MB: paged, cached
    RG_ROM,             // 0x50000000, 20 MB: read-only, cached
    RG_DRIVE,           // 0x60000000, 24 MB: CRAM, uncached
    RG_KSEC,            // 0x80000000, 4 MB: flat, cached
    RG_IO               // 0xF0000000, 4 KB: the devices
} region_t;

function automatic region_t region_of(input logic [31:0] va);
    if (va[31:20] == 12'h000)                   return RG_KERN;
    if (va[31:22] == 10'h001)                   return RG_WIN;
    if (va[31:25] == 7'h10)                     return RG_PHYS;
    if (va[31:28] == 4'h4)                      return RG_CHUNK;
    if (va[31:28] == 4'h5 && va[27:20] < 8'h14) return RG_ROM;
    if (va[31:28] == 4'h6 && va[27:20] < 8'h18) return RG_DRIVE;
    if (va[31:22] == 10'h200)                   return RG_KSEC;
    if (va[31:12] == 20'hF0000)                 return RG_IO;
    return RG_NONE;
endfunction

function automatic logic cached_rg(input region_t r);
    return r == RG_KERN || r == RG_WIN || r == RG_CHUNK || r == RG_ROM || r == RG_KSEC;
endfunction

function automatic logic paged_rg(input region_t r);
    return r == RG_WIN || r == RG_CHUNK;
endfunction

// A cache tag: the virtual address above the 8 KB way, and for the data
// window the number of the process it belongs to (docs/core-design.md 4.2).
localparam int TAGW = 19 + 6;
function automatic logic [TAGW-1:0] vtag_of(input logic [31:0] va, input logic [5:0] win_id);
    return {va[31:13], va[31:22] == 10'h001 ? win_id : 6'd0};
endfunction

// the page-table index of a paged address
localparam int PT_CHUNK   = 16384;
localparam int PT_ENTRIES = 16640;
function automatic logic [14:0] pt_index_of(input logic [31:0] va);
    return va[31:22] == 10'h001 ? 15'(PT_CHUNK) + {7'd0, va[21:14]} : {1'b0, va[27:14]};
endfunction
localparam logic [15:0] PT_NONE = 16'hFFFF;

// the bus address of a flat region's byte (paged regions go through the table)
localparam logic [26:0] BUS_ROM   = 27'h2000000;
localparam logic [26:0] BUS_KSEC  = 27'h3400000;
localparam logic [26:0] BUS_DRIVE = 27'h4000000;
function automatic logic [26:0] bus_flat(input region_t r, input logic [31:0] va);
    case (r)
        RG_KERN:  return {7'd0, va[19:0]};
        RG_PHYS:  return {2'd0, va[24:0]};
        RG_ROM:   return BUS_ROM | {2'd0, va[24:0]};
        RG_KSEC:  return BUS_KSEC | {5'd0, va[21:0]};
        default:  return BUS_DRIVE | {2'd0, va[24:0]};
    endcase
endfunction
function automatic logic [26:0] bus_paged(input logic [15:0] page, input logic [31:0] va);
    return {2'd0, page[10:0], va[13:0]};
endfunction

// bus commands (ngvm_sys's port, ngage_mem's)
localparam logic [1:0] BC_RDLINE = 2'd0;    // 32 bytes, from the word [4:2] names, round
localparam logic [1:0] BC_WRLINE = 2'd1;    // ... the bytes a 32-bit mask marks
localparam logic [1:0] BC_RDWORD = 2'd2;    // 4 bytes, aligned
localparam logic [1:0] BC_RDWR   = 2'd3;    // a line read, then a full line written back

// device registers (ngvm_hw.h IO_*), as word offsets [11:2]
localparam logic [9:0] IO_DBG_PUTC    = 10'h000;
localparam logic [9:0] IO_DBG_EXIT    = 10'h001;
localparam logic [9:0] IO_DBG_HEX     = 10'h002;
localparam logic [9:0] IO_DBG_FLAGS   = 10'h003;
localparam logic [9:0] IO_TIMER_US    = 10'h004;
localparam logic [9:0] IO_TIMER_US_HI = 10'h005;
localparam logic [9:0] IO_TIMER_CMP   = 10'h006;
localparam logic [9:0] IO_IRQ_STATUS  = 10'h007;
localparam logic [9:0] IO_IRQ_ENABLE  = 10'h008;
localparam logic [9:0] IO_LCD_BASE    = 10'h00C;
localparam logic [9:0] IO_LCD_CTRL    = 10'h00D;
localparam logic [9:0] IO_LCD_FRAME   = 10'h00E;
localparam logic [9:0] IO_LCD_SHOW    = 10'h00F;
localparam logic [9:0] IO_KEYS        = 10'h010;
localparam logic [9:0] IO_AUDIO_DATA  = 10'h014;
localparam logic [9:0] IO_AUDIO_LEVEL = 10'h015;
localparam logic [9:0] IO_AUDIO_RATE  = 10'h016;
localparam logic [9:0] IO_AUDIO_SIZE  = 10'h017;
localparam logic [9:0] IO_PT_INDEX    = 10'h018;
localparam logic [9:0] IO_PT_DATA     = 10'h019;
localparam logic [9:0] IO_CACHE_FLUSH = 10'h01A;
localparam logic [9:0] IO_WIN_ID      = 10'h01B;
localparam logic [9:0] IO_DRIVE_SIZE  = 10'h01C;
localparam logic [9:0] IO_ROM_SIZE    = 10'h01D;

endpackage

`default_nettype wire
