/* NGVM: the machine this core implements.
 *
 * Not an N-Gage.  An ARMv4T CPU, memory at the addresses the N-Gage's ROM
 * code expects, and a handful of simple devices.  The Symbian user side runs
 * unchanged from the user's own firmware image; sw/kernel replaces the EKA1
 * kernel and every Nokia driver beneath it.
 *
 * This header is the contract between three implementations of the machine:
 * tools/ngvm (the software reference), the RTL, and the kernel that runs on
 * both.  Change it in all three or not at all.
 */
#ifndef NGVM_HW_H
#define NGVM_HW_H

/* ---- memory map ---------------------------------------------------------- */
#define NGVM_KERN_BASE    0x00000000u   /* the kernel: the first MB of RAM      */
#define NGVM_KERN_SIZE    0x00100000u
#define NGVM_DATA_BASE    0x00400000u   /* EXE static data window, paged, swapped */
#define NGVM_DATA_SIZE    0x00400000u   /* per process (EKA1's moving model)      */
#define NGVM_PHYS_BASE    0x20000000u   /* all of RAM, for the kernel's own use  */
#define NGVM_RAM_SIZE     0x02000000u   /* 32 MB                                */
#define NGVM_KSEC_BASE    0x80000000u   /* fixed processes' static data         */
#define NGVM_KSEC_SIZE    0x00400000u   /* (EFile 0x80100000, EwSrv 0x80200000) */
#define NGVM_ROM_BASE     0x50000000u   /* SYM.ROM, read-only, as linked        */
#define NGVM_ROM_MAX      0x01400000u   /* 20 MB                                */
#define NGVM_DRIVE_BASE   0x60000000u   /* the game's drive image (see below)   */
#define NGVM_DRIVE_MAX    0x01800000u   /* 24 MB                                */
#define NGVM_IO_BASE      0xF0000000u

/* Chunk space: where every heap, stack and loaded image lives.  Paged in
 * 16 KB pages by a table the kernel writes (IO_PT_*); an access to a page
 * with no entry is a data or prefetch abort.  There is one address space,
 * so the caches are virtually tagged and the table is read only on a miss.  */
#define NGVM_CHUNK_BASE   0x40000000u
#define NGVM_CHUNK_SIZE   0x08000000u   /* 128 MB of addresses               */
#define NGVM_PAGE_SHIFT   14
#define NGVM_PAGE_SIZE    (1u << NGVM_PAGE_SHIFT)
#define NGVM_PT_CHUNK     (NGVM_CHUNK_SIZE >> NGVM_PAGE_SHIFT)   /* 8192    */
#define NGVM_PT_ENTRIES   (NGVM_PT_CHUNK + (NGVM_DATA_SIZE >> NGVM_PAGE_SHIFT))
/* Table entries 0..8191 map chunk space; 8192..8447 map the data window.
 * An entry holds a RAM page number p: RAM address p << NGVM_PAGE_SHIFT,
 * seen by the kernel at NGVM_PHYS_BASE + that.  Pages 0..63 are the
 * kernel's and are never handed out.                                       */
#define NGVM_PT_NONE      0xFFFFu

/* ---- devices, at NGVM_IO_BASE + offset, all 32-bit ---------------------- */
#define IO_DBG_PUTC       0x000  /* W: one byte to the debug console          */
#define IO_DBG_EXIT       0x004  /* W: stop the simulation with this code     */
#define IO_DBG_HEX        0x008  /* W: print a word in hex (debug console)    */
#define IO_TIMER_US       0x010  /* R: microseconds since reset, low word     */
#define IO_TIMER_US_HI    0x014  /* R: high word, latched by reading low      */
#define IO_TIMER_CMP      0x018  /* W: raise IRQ_TIMER when US >= this        */
#define IO_IRQ_STATUS     0x01C  /* R: pending; W: write 1s to clear          */
#define IO_IRQ_ENABLE     0x020  /* RW                                        */
#define IO_LCD_BASE       0x030  /* RW: framebuffer address                   */
#define IO_LCD_CTRL       0x034  /* RW: bit 0 display on                      */
#define IO_LCD_FRAME      0x038  /* R: frames scanned out since reset         */
#define IO_KEYS           0x040  /* R: KEY_* bits, 1 = pressed                */
#define IO_AUDIO_DATA     0x050  /* W: one sample, L in 15:0, R in 31:16      */
#define IO_AUDIO_LEVEL    0x054  /* R: samples waiting in the FIFO            */
#define IO_AUDIO_RATE     0x058  /* RW: FIFO drain rate, Hz                   */
#define IO_AUDIO_SIZE     0x05C  /* R: FIFO capacity in samples               */
#define IO_PT_INDEX       0x060  /* W: chunk-space page number to set         */
#define IO_PT_DATA        0x064  /* W: RAM page for it, or NGVM_PT_NONE       */
#define IO_CACHE_FLUSH    0x068  /* W: write back and invalidate all caches   */
#define IO_DRIVE_SIZE     0x070  /* R: bytes loaded at NGVM_DRIVE_BASE        */
#define IO_ROM_SIZE       0x074  /* R: bytes loaded at NGVM_ROM_BASE          */

#define IRQ_TIMER         (1u << 0)
#define IRQ_VBLANK        (1u << 1)
#define IRQ_AUDIO         (1u << 2)   /* FIFO at or below half full           */

/* The LCD: 176 x 208, 16 bits a pixel, 0x0RGB (4 bits per channel), rows
 * of 176 halfwords, scanned from IO_LCD_BASE.  60 frames a second.          */
#define LCD_W             176
#define LCD_H             208

/* Pocket controls as the kernel sees them. */
#define KEY_UP     (1u << 0)
#define KEY_DOWN   (1u << 1)
#define KEY_LEFT   (1u << 2)
#define KEY_RIGHT  (1u << 3)
#define KEY_A      (1u << 4)
#define KEY_B      (1u << 5)
#define KEY_X      (1u << 6)
#define KEY_Y      (1u << 7)
#define KEY_L      (1u << 8)
#define KEY_R      (1u << 9)
#define KEY_SELECT (1u << 10)
#define KEY_START  (1u << 11)

#ifndef __ASSEMBLER__
#define IO(off) (*(volatile unsigned int *)(NGVM_IO_BASE + (off)))
#endif

#endif
