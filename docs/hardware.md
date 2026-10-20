# The machine

This core does not implement the N-Gage's board. It implements **NGVM**, a
small machine that has just enough of an ARM phone for the Symbian user side
in the owner's own firmware image (`SYM.ROM`) to run unchanged:

- an ARMv4T CPU;
- RAM at the addresses the firmware is linked for;
- a page table over the addresses where Symbian puts its chunks;
- five simple devices.

`sw/kernel` replaces the EKA1 kernel and every Nokia driver beneath it. It
models devices at the level of the logical device driver (LDD) channel, the
level the user side sees. Nothing below that level is emulated: no OMAP-style
SoC, no DSP, no Bluetooth chip, no UART.

`sw/include/ngvm_hw.h` is the contract. Three implementations share it:

| implementation | where | role |
|---|---|---|
| software reference | `tools/ngvm/ngvm.py` (Unicorn, TI925T model, ARMv4T) | the oracle: every RTL bench compares against it |
| gateware | `rtl/` | the core |
| kernel | `sw/kernel/` | runs on both, unchanged |

Change the header in all three or not at all. This file explains the header,
and what in the firmware made each choice necessary. Where it and the header
disagree, the header is right and this file is stale.

## 1. Why a virtual machine, not the board

The N-Gage (2003) is built on Nokia's UPP-family baseband ASIC:

- an ARM925T at 104 MHz;
- a TI DSP that runs audio;
- a 176×208 12-bit LCD;
- MMC as drive E:;
- Symbian OS 6.1 (EKA1) with Series 60 0.9.

The ASIC is undocumented. Its kernel-side drivers (`*.ldd` and `*.pdd` in the
ROM) talk to the DSP over ISI/Phonet and to radio, Bluetooth and power parts
that no game needs. Emulating them would mean emulating undocumented silicon
to keep code running whose only job is to be replaced. Symbian's user side
reaches the kernel only through executive calls (SWIs) and LDD channels, and
it is position-dependent but hardware-independent above that line, so the
line is where NGVM cuts.

## 2. CPU

| property | NGVM requires | why |
|---|---|---|
| ISA | ARMv4T: ARM and Thumb, `BX` interworking | the firmware and every game are built for ARM925T (v4T); games are mostly Thumb calling ARM libraries through `BX` veneers |
| modes | USR, SVC, IRQ, ABT, UND | the kernel runs in SVC; user threads in USR |
| FIQ | not used | |
| coprocessors | none | the ARM925T had no FPU, so the firmware and the games carry none |
| unaligned LDR | ARMv4 rotation | some ROM code relies on it; Unicorn does not rotate, a known gap of the reference |
| MMU | NGVM's own table (section 4), not ARM's | one address space; see section 4 |
| speed | ~100 MIPS of user work for the heaviest game | measured, section 9 |

Reaching the kernel:

- **SWI** reaches the kernel: an executive call, number in the SWI comment
  field, EKA1 calling convention (`docs/eka1_exec.md`).
- **Data abort and prefetch abort** occur on an unmapped page. The kernel
  either grows a chunk or panics the thread.
- **IRQ** comes from the device block (section 6).

## 3. Memory map

| range | size | what | access |
|---|---|---|---|
| `0x00000000` | 1 MB | the kernel's code, data and stacks (RAM pages 0–63) | kernel |
| `0x00400000` | 4 MB | the running EXE's static data, paged per process (EKA1's moving model) | user, through the table |
| `0x20000000` | 32 MB | all of RAM, flat, for the kernel's own use | kernel |
| `0x40000000` | 256 MB of addresses | chunk space: every heap, stack, DLL data and loaded image, paged in 16 KB pages | user, through the table |
| `0x50000000` | ≤ 20 MB | `SYM.ROM`, as linked; read-only | everyone |
| `0x60000000` | ≤ 32 MB | the game's drive image (FAT16, section 7) | kernel (the drive LDD) |
| `0x80000000` | 4 MB | fixed processes' static data (EFile `0x80100000`, EwSrv `0x80200000`) | user |
| `0xF0000000` | 4 KB | devices | kernel |

The ROM base, the fixed-process data addresses and the 4 MB EXE data window
come from the firmware's own linkage. NGVM puts memory where the code already
expects it, so nothing in `SYM.ROM` is relocated or patched.

## 4. Paging

One table of 16,640 16-bit entries:

- entries 0–16383 map chunk space (`0x40000000` + n × 16 KB);
- entries 16384–16639 map the 4 MB data window.

Each entry holds a 16 KB RAM page number, or `0xFFFF` for none. The kernel
writes entries through `IO_PT_INDEX`/`IO_PT_DATA` and never reads them back.
An access through an empty entry aborts.

Why 16 KB pages, and why not ARM's MMU:

- **One address space.** Symbian EKA1 (moving model) gives every process the
  same view, apart from the data window, which the kernel swaps on a process
  switch. There is nothing for ASIDs, domains or per-process tables to do.
- **Virtually tagged caches.** With one address space they are correct, and
  the table is read only on a cache miss. A switch that swaps the data window
  must flush. `IO_CACHE_FLUSH` writes back and invalidates.
- **16 KB** gives 16,640 entries, which fit in block RAM (≈ 33 KB). With 4 KB
  pages the table would need SDRAM and a TLB in front of it. Allocation waste
  is small, because Symbian chunks grow in 4 KB steps that the kernel rounds
  to whole 16 KB pages.

Permissions are not modelled. User code can write the ROM's window and the
write is dropped. A user write to the kernel's 1 MB is not stopped. The games
do neither (no stray-write faults in any run so far), but this is a
difference from the phone, not a proof.

## 5. RAM use, measured

Distinct 16 KB pages mapped at any one time, sampled every 30 frames for
60 virtual seconds, kernel included (`ngvm.py`, `ram_peak`):

| game | peak |
|---|---|
| Puzzle Bobble VS | 8.6 MB |
| Bomberman | 12.6 MB |
| Sonic N | 10.7 MB |
| Puyo Pop | 10.6 MB |
| Super Monkey Ball | 13.1 MB |
| Snakes | 15.1 MB |
| Virtua Cop | 17.0 MB |

The phone had 16 MB of RAM, part of it taken by the radio side. NGVM's
32 MB leaves room for the kernel's coarser pages and for allocation
patterns not seen yet.

## 6. Devices

All registers are 32-bit, at `0xF0000000` + offset. The header gives every
register; what follows is behaviour the header cannot say.

### Timer and interrupts

- `IO_TIMER_US` is microseconds since reset. Reading the low word latches
  the high word.
- Writing `IO_TIMER_CMP` arms a one-shot: when the low word of `US`
  reaches it (modular comparison), `IRQ_TIMER` is set in the status and the
  compare disarms.
- The kernel arms it for the earliest of three things: the end of the
  20 ms time slice, the next timer-queue expiry, and a pending launch
  (`sw/kernel/sched.c`).
- `IO_IRQ_STATUS`: writing 1s clears.
- `IRQ_VBLANK` is set at the start of each LCD frame.
- `IRQ_AUDIO` is a level: the FIFO is at or below half full.
- One IRQ line reaches the CPU: the OR of `STATUS & ENABLE`.

### LCD

- 176 × 208 pixels, 16 bits each (`0x0RGB`, 4 bits per channel), at 60 Hz.
- Rows are 176 halfwords, from `IO_LCD_BASE`.
- The firmware's own screen driver composes into a buffer the kernel
  allocates (`lcd_buffer`, `sw/kernel/misc.c`) and points `IO_LCD_BASE` at.
- **The picture changes only when it is sent.** The phone's display keeps
  its own copy, and the LCD LDD's control 8194 sends it the buffer, always
  lines 0–208 (`{0xa, 0, 0xd0}` at its argument). The window server calls
  it 30 times a second while anything moves; X-Forge games (Virtua Cop)
  call it themselves after each frame they draw, 75–240 times a second at
  100 MIPS. The kernel answers it with `IO_LCD_SHOW`: the D-cache writes
  its dirty lines back, then the LCD copies the frame into its own memory
  and shows that until the next.
- Scanning the buffer itself, as the first flash did, shows drawing half
  done. Over 70 s of each of the seven games (`ngvm.py`, with keys), the
  buffer never differed from the picture last sent for more than 0.1 s,
  but once, 117 ms, in Super Monkey Ball: nothing draws without sending.
- There is no palette, no layer and no scaling: the scaler belongs to the
  Pocket side (`docs/core-design.md`).
- `IO_LCD_FRAME` counts frames scanned out, for pacing.

### Keys

`IO_KEYS` holds Pocket buttons, 1 = pressed. The kernel turns them into
Symbian scan codes (`EStdKey*`) and raw events for the window server. The
mapping is the kernel's choice, not hardware's:

| Pocket | phone | scan code |
|---|---|---|
| d-pad | joystick | `EStdKey{Up,Down,Left,Right}Arrow` |
| A, B | 5, 7 (the N-Gage's game keys) | `'5'`, `'7'` |
| X, start | OK | `EStdKeyDevice3` (0xA7) |
| Y | 9 | `'9'` |
| L, R | left and right soft keys | 0xA4, 0xA5 |
| select | # | 0x7F |

The kernel reads `IO_KEYS` at each vblank (`sw/kernel/event.c`).

### Audio

- A stereo sample FIFO: `IO_AUDIO_DATA` takes L in bits 15:0, R in 31:16.
- It drains at `IO_AUDIO_RATE` Hz.
- `IO_AUDIO_SIZE` gives the capacity; `IO_AUDIO_LEVEL` the samples waiting.
- The capacity is 1,024 samples (`AUDIO_FIFO_N`). `IRQ_AUDIO` holds while
  it is half empty and the kernel tops it up to full, so the FIFO delays
  sound by 32–64 ms at 16 kHz. It was 4,096 for the first flash, which
  put 128–256 ms between a game's sound and its picture (256–512 ms at
  8 kHz).
- The kernel fills it from its model of the DSP's PCM player (ISI resource
  `0xE8`, the protocol `SoundDevice.mda` speaks).
- Rates seen so far: 8 kHz and 16 kHz, mono. The rate codes are read from
  the start message; the 16 kHz reading is by ear and not yet proven.

### Debug

`IO_DBG_*`: a console, an exit code and trace switches. They are
implemented by the reference. The gateware has the console and the exit
code, which the RTL benches use, and the switches read 0.

## 7. The drive image

The game's MMC card, built by `tools/mkdrive.py` from the game's files:

- a FAT16 volume with no partition table, mounted as E: by the real EFile
  through the kernel's drive LDD;
- the boot sector's boot-code area holds the launch record (`NGVMRUN`, then
  the `.app` path), which the kernel reads to start the game;
- writes land in the loaded image in memory and are lost at power-off,
  so high scores and saves do not survive (a save slot is future work).

## 8. What the firmware needs, and does not

Taken from the boot traces (`ngvm.py --trace 1`) on all seven cards.

**Modelled** (`sw/kernel/chan.c`):

- the LCD;
- keys (EKeyboard);
- the drive (MMC);
- Audioldd's shared buffer;
- NOSDRIVER, as an ISI/Phonet router that answers the DSP's PCM player;
- the mute and vibra controls;
- every other channel any boot opens, with its minimum answer: open and
  never complete, or complete with `KErrNotSupported`.

**Not modelled, and what it costs:**

- adspserver's MADI link to the DSP over Comm unit 0. AudioServer panics
  ("SS Audio Server 4"), so key clicks and the tone player are silent. No
  game's music or effects go this way.
- Bluetooth HCI. Snakes' multiplayer cannot start; single player runs.
- The radio side, SIM, telephony, the camera, IrDA and USB.

## 9. CPU load, measured

Busy MIPS out of a 100 MIPS virtual CPU:

- measured as the time outside the idle thread, from the kernel's own
  accounting (`idle_us`);
- sampled each virtual second over 60 s, after boot;
- `ngvm.py --slice 10000`.

| game | typical | peak |
|---|---|---|
| Puzzle Bobble VS | 11 | |
| Snakes | 18 | |
| Bomberman | 20 | |
| Puyo Pop | 47 | |
| Super Monkey Ball | 50 | |
| Sonic N | 50 | 97 |
| Virtua Cop | 93 | |

A boot with no game is busy for about 7 s, then idle. These are
instructions, not cycles. On a real CPU, each one costs one cycle plus its
share of cache misses, branch penalties and multi-cycle instructions;
`docs/core-design.md` turns this into a clock requirement.

## 10. Open questions

- The meaning of the DSP's `0x2b` message, and whether `0x46` means 16 kHz.
- Whether Puzzle Bobble's sound is silent because of the AudioServer path.
  Snakes imports no stream library.
- Sonic N's intro timing changed when sound started.
- Process priorities the EKA1 kernel assigns itself:
  - The file server runs at 750 (EPriorityFileServer). EFile's ROM header
    says 350, as `ekern`'s does, and nothing in the firmware sets 750. At
    350, the phone client's start-a-server-if-none window lasted a whole
    process load, and a second PhoneServer was started (PhSrvFault 2).
    At 750 it still could be. On the RTL at the tested SDRAM pace, and in
    the reference with `--trace 1`, a second client missed "Phone Server"
    while the first one's copy was still being created and started its
    own. The copy panicked (PhSrvFault 2), and its client after it
    (PhSrvTest 1). On Sonic N the screen was then updated 4 times in 60 s.
    The kernel now remembers a missed name for 2 s, or until the thread
    that missed it dies. Another thread missing the same name in that time
    waits, and connects when the server takes the name
    (`sw/kernel/exec.c`, "a server being started"). Whether EKA1 closes
    this window some other way, or the phone was simply fast enough, is
    not known.
  - Whether the window server should be at 650 is unchecked.
- The scheduler picks the least recently run of the highest-priority
  threads; EKA1 keeps a FIFO ready queue. They can differ with three or
  more threads ready.
