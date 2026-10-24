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
#define NGVM_DRIVE_MAX    0x02000000u   /* 32 MB: all of the Pocket's CRAM      */
#define NGVM_IO_BASE      0xF0000000u

/* The phone's internal drive, C:, where games keep their saves: the top
 * 1 MB of RAM, which the kernel never hands out and reaches only through
 * the physical alias, so what it writes is in RAM at once, not held in the
 * D-cache.  The Pocket loads the game's save file here before the CPU
 * starts (IO_SAVE_SIZE says how much), and writes it back from here when
 * the core asks it to, after IO_SAVE_DIRTY.                               */
#define NGVM_SAVE_BASE    0x01F00000u   /* RAM address                         */
#define NGVM_SAVE_SIZE    0x00100000u

/* Chunk space: where every heap, stack and loaded image lives.  Paged in
 * 16 KB pages by a table the kernel writes (IO_PT_*); an access to a page
 * with no entry is a data or prefetch abort.  There is one address space,
 * so the caches are virtually tagged and the table is read only on a miss.  */
#define NGVM_CHUNK_BASE   0x40000000u
#define NGVM_CHUNK_SIZE   0x10000000u   /* 256 MB of addresses, up to the ROM */
#define NGVM_PAGE_SHIFT   14
#define NGVM_PAGE_SIZE    (1u << NGVM_PAGE_SHIFT)
#define NGVM_PT_CHUNK     (NGVM_CHUNK_SIZE >> NGVM_PAGE_SHIFT)   /* 16384   */
#define NGVM_PT_ENTRIES   (NGVM_PT_CHUNK + (NGVM_DATA_SIZE >> NGVM_PAGE_SHIFT))
/* Table entries 0..16383 map chunk space; 16384..16639 the data window.
 * An entry holds a RAM page number p: RAM address p << NGVM_PAGE_SHIFT,
 * seen by the kernel at NGVM_PHYS_BASE + that.  Pages 0..63 are the
 * kernel's and are never handed out.                                       */
#define NGVM_PT_NONE      0xFFFFu

/* The low name of chunk space: 0x00800000-0x01FFFFFF is 0x40800000-
 * 0x41FFFFFF, through the same table entries (512-2047).  On the phone a
 * game's chunks ran low in EKA1's moving model, and some games keep
 * pointers in 24 or 25 bits (Colin McRae Rally 2005; the Airplay ports:
 * Tomb Raider, Tony Hawk's, Pandemonium), so the kernel gives the game's
 * processes their memory here.  It never uses these pages' high name: the
 * caches are virtually tagged, and one page under two tags would not stay
 * coherent.  The reference maps the low name only.                         */
#define NGVM_LOW_BASE     0x00800000u
#define NGVM_LOW_SIZE     0x01800000u

/* ---- devices, at NGVM_IO_BASE + offset, all 32-bit ---------------------- */
#define IO_DBG_PUTC       0x000  /* W: one byte to the debug console          */
#define IO_DBG_EXIT       0x004  /* W: stop the simulation with this code     */
#define IO_DBG_HEX        0x008  /* W: print a word in hex (debug console)    */
#define IO_DBG_FLAGS      0x00C  /* R: trace switches the host asks for (DBGF_*); read at each timer tick */
#define IO_TIMER_US       0x010  /* R: microseconds since reset, low word     */
#define IO_TIMER_US_HI    0x014  /* R: high word, latched by reading low      */
#define IO_TIMER_CMP      0x018  /* W: raise IRQ_TIMER when US >= this        */
#define IO_IRQ_STATUS     0x01C  /* R: pending; W: write 1s to clear          */
#define IO_IRQ_ENABLE     0x020  /* RW                                        */
#define IO_LCD_BASE       0x030  /* RW: framebuffer address, through NGVM_PHYS_BASE */
#define IO_LCD_CTRL       0x034  /* RW: bit 0 display on                      */
#define IO_LCD_FRAME      0x038  /* R: frames scanned out since reset         */
#define IO_LCD_SHOW       0x03C  /* W: show the framebuffer as it is now     */
#define IO_KEYS           0x040  /* R: KEY_* bits, 1 = pressed                */
#define IO_KEYMAP         0x044  /* R: the phone key each of A B X Y L R holds:
                                     4 bits a button, A in 3:0, R in 23:20;
                                     d+1 for digit key d, 0 for the default   */
#define IO_AUDIO_DATA     0x050  /* W: one sample, L in 15:0, R in 31:16      */
#define IO_AUDIO_LEVEL    0x054  /* R: samples waiting in the FIFO            */
#define IO_AUDIO_RATE     0x058  /* RW: FIFO drain rate, Hz                   */
#define IO_AUDIO_SIZE     0x05C  /* R: FIFO capacity in samples               */
#define IO_PT_INDEX       0x060  /* W: chunk-space page number to set         */
#define IO_PT_DATA        0x064  /* W: RAM page for it, or NGVM_PT_NONE       */
#define IO_CACHE_FLUSH    0x068  /* W: write back and invalidate all caches   */
#define IO_WIN_ID         0x06C  /* W: the number of the process whose data the
                                     window maps (1-63; 0 none): the caches tag
                                     window lines with it                    */
#define IO_DRIVE_SIZE     0x070  /* R: bytes loaded at NGVM_DRIVE_BASE        */
#define IO_ROM_SIZE       0x074  /* R: bytes loaded at NGVM_ROM_BASE          */
#define IO_SAVE_SIZE      0x078  /* R: bytes of save loaded at NGVM_SAVE_BASE */
#define IO_SAVE_DIRTY     0x07C  /* W: C: has changed; the core writes the save
                                     back once a couple of seconds pass with
                                     no further write                        */

/* IO_DBG_FLAGS bits */
#define DBGF_EXEC         (1u << 0)   /* log every exec call                    */
#define DBGF_SCHED        (1u << 1)   /* log thread switches                    */
#define DBGF_IPC          (1u << 2)   /* log messages                           */
#define DBGF_DUMP         (1u << 3)   /* dump every thread when a server is missing */
#define DBGF_THREADS      (1u << 4)   /* dump every thread once, as the bit is set */

#define IRQ_TIMER         (1u << 0)
#define IRQ_VBLANK        (1u << 1)
#define IRQ_AUDIO         (1u << 2)   /* FIFO at or below half full           */

/* The audio FIFO's capacity (IO_AUDIO_SIZE; ngvm_io.sv's AUDIO_N).  The
 * kernel tops it up whenever it is half empty, so it delays sound by half to
 * all of this: 32-64 ms at 16 kHz, on top of SoundDevice's own buffers. */
#define AUDIO_FIFO_N      1024

/* The LCD: 176 x 208, 16 bits a pixel, 0x0RGB (4 bits per channel), rows
 * of 176 halfwords at IO_LCD_BASE.  As on the phone, whose display keeps
 * its own copy, the picture changes only when it is sent: a write to
 * IO_LCD_SHOW makes the D-cache write its dirty lines back and then the
 * LCD copy the framebuffer into its own memory, about a millisecond later,
 * and it shows that copy at 60 frames a second until the next.  The
 * gateware reads RAM, so IO_LCD_BASE is an address in the physical alias
 * over contiguous pages; the CPU may draw through any other mapping.
 *
 * Caching (docs/core-design.md 4.2): everything is cached but the physical
 * alias, the drive and the devices.  Tags are virtual; the data window's
 * lines carry IO_WIN_ID.  A page must be flushed (IO_CACHE_FLUSH) between
 * being unmapped and being handed out again.                                */
#define LCD_W             176
#define LCD_H             208

/* The game's drive image is a FAT16 volume with no partition table
 * (tools/mkdrive.py).  Its boot sector's boot-code area, which FAT never
 * reads, holds the launch record: NGVM_LAUNCH_MAGIC, then the .app to run
 * ("E:\\System\\Apps\\X\\X.app"), ASCII, NUL-terminated.  No record: the
 * phone boots and runs nothing.                                             */
#define NGVM_LAUNCH_OFF   0x40
#define NGVM_LAUNCH_MAGIC "NGVMRUN"   /* 8 bytes with its NUL                  */
#define NGVM_LAUNCH_MAX   0x1B6       /* bytes of path, NUL included           */

/* IO_KEYS.  Bits 0-11 are the Pocket's controls.  Bits 12-26 are the phone
 * keys of the on-screen keypad (SELECT + R; rtl/ngage_osk.sv), one bit a
 * key, held while the keypad presses it.  While the keypad is up it has the
 * pad, and bits 0-11 read 0.  Nothing reads above bit 26.                    */
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
#define KEY_PAD_0     (1u << 12)   /* digit d is KEY_PAD_0 << d, to bit 21    */
#define KEY_PAD_STAR  (1u << 22)
#define KEY_PAD_HASH  (1u << 23)
#define KEY_PAD_LSOFT (1u << 24)   /* the left soft key                       */
#define KEY_PAD_RSOFT (1u << 25)   /* the right soft key                      */
#define KEY_PAD_CLEAR (1u << 26)   /* C                                       */
#define KEY_BITS   27

#ifndef __ASSEMBLER__
#define IO(off) (*(volatile unsigned int *)(NGVM_IO_BASE + (off)))
#endif

#endif
