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
| `0x00800000` | 24 MB | the low name of chunk space's `0x40800000`–`0x41FFFFFF`: the game's memory | user, through the table |
| `0x20000000` | 32 MB | all of RAM, flat, for the kernel's own use | kernel |
| `0x40000000` | 256 MB of addresses | chunk space: every heap, stack, DLL data and loaded image, paged in 16 KB pages | user, through the table |
| `0x50000000` | ≤ 20 MB | `SYM.ROM`, as linked; read-only | everyone |
| `0x60000000` | ≤ 32 MB | the game's drive image (FAT16, section 7) | kernel (the drive LDD) |
| `0x80000000` | 4 MB | fixed processes' static data (EFile `0x80100000`, EwSrv `0x80200000`) | user |
| `0xF0000000` | 4 KB | devices | kernel |

The ROM base, the fixed-process data addresses and the 4 MB EXE data window
come from the firmware's own linkage. NGVM puts memory where the code already
expects it, so nothing in `SYM.ROM` is relocated or patched.

**The low name.** On the phone a game's chunks ran low, in its moving
process's data section, and some games rely on it: they keep pointers in 24
or 25 bits. Colin McRae Rally 2005 masks to 24 bits; the Ideaworks Airplay
ports (Tomb Raider, Tony Hawk's Pro Skater, Pandemonium) pack an 8-bit tag
above a pointer and keep it in 25. With every chunk at `0x40000000` and up,
each faulted on its first masked pointer (`0x46f74b8c` read as `0x00f74b8c`).
So `0x00800000`–`0x01FFFFFF` is a second name for chunk space's
`0x40800000`–`0x41FFFFFF`, through the same table entries (512–2047), and the
kernel reserves the game's memory there first (`vm_reserve_for`): the stacks,
chunks and RAM code of the process the launcher starts, of every EXE loaded
from the card, and of whatever those processes start. The rest of the system
reserves around those pages and never uses their high name, because the
caches are virtually tagged and one page under two tags would not stay
coherent. The reference maps the low name only, so a use of the high name
faults there and in the lockstep bench. The low name fills from the bottom,
so a game's first 8 MB of reservations are under 16 MB.

## 4. Paging

One table of 16,640 16-bit entries:

- entries 0–16383 map chunk space (`0x40000000` + n × 16 KB); 512–2047 map
  `0x00800000` + (n − 512) × 16 KB as well, the low name (section 3);
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
- A user's `RTimer::After`, `At` or `User::After` ends no sooner than
  1 ms after it is asked, and otherwise when asked (`user_expiry`). EKA1
  ended a short wait at its next 1/64 s tick (the 15,625 µs HAL reports as
  `TickPeriod`), so the threads below the waiter ran meanwhile. To the
  microsecond, Atari Masterpieces Vol. 1 polled with `After(1)` 807 times
  a second and never let the threads it waited on run, and Rayman 3, with
  `After(0)`, starved the view server until it panicked `ViewSrv 11`. The
  tick itself costs frames: Virtua Cop waits `After(1000)` between frames,
  and at 30 MIPS, rounded to the tick, it drew 24% fewer of them in 45 s
  (Ashen 30%, Colin McRae 32%, whose threads wait `After(0)`).
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
mapping is the kernel's choice, not hardware's, and these are its
defaults:

| Pocket | phone | scan code |
|---|---|---|
| d-pad | joystick | `EStdKey{Up,Down,Left,Right}Arrow` |
| A, B | 5, 7 (the N-Gage's game keys) | `'5'`, `'7'` |
| X, start | OK | `EStdKeyDevice3` (0xA7) |
| Y | 9 | `'9'` |
| L, R | left and right soft keys | 0xA4, 0xA5 |
| select | # | 0x7F |

`IO_KEYMAP` moves A, B, X, Y, L and R: 4 bits each, A in bits 3:0 to R in
23:20, `d + 1` for digit key `d` (scan code `'0' + d`) and 0 for the
default above. On the Pocket it is six menu sliders (0xF5000000 to
0xF5000014, `target/pocket/core_top.sv`), 0-9 a digit and 10 the default;
in the reference, `--keymap`. The kernel reads both registers at each
vblank and keeps the set of phone keys held, so a phone key that two
buttons hold goes up only when both are let go (`sw/kernel/event.c`);
X and start, both OK, did otherwise before.

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
  `0xE8`, the protocol `SoundDevice.mda` speaks), including its stop
  (`0x2a`, answered `0x2b`), which a game sends between screens.
- Key clicks and tones go to the DSP's tone player (ISI resource `0x1F`).
  SoundDevice holds the audio device from a tone's start (`0x01`) until
  the DSP says it has ended (`0x03`), and refuses every game stream of
  lower priority meanwhile (`KErrInUse`). There is no tone generator, so
  the kernel ends each tone as it starts it. Without that, one key press
  in a game's menus silenced Puzzle Bobble for good and held it at 5
  frames a second, retrying its stream every 117 ms.
- A game that falls behind its stream can drop it for good. Puyo Pop
  updates its sound once a frame (game code `0x43c5c9a8`). Each update
  turns the stream's position into samples played, and if that exceeds
  what the game has written, the update `User::Leave`s with -39
  (`0x43c5cb20`). Nothing calls MediaServer for that stream again. The
  position counts the silence SoundDevice writes when a slot is asked for
  and the game has written nothing. CPU-bound at 30 MIPS, Puyo updates
  every 70–330 ms; its 50 ms writes run dry, and the attract and dialogue
  music stop at their first gap (the reference: 39.5 s and 52.9 s, keys
  every 2 s from 20 s). At 35, 40, 60 and 100 MIPS no update leaves, and
  Stage 1 plays its music to 110 s. The Pocket's ~29 MIPS gives the
  first. Asking for a slot as it starts to play rather than as it enters
  the FIFO (`dsp_pump`) would put the position 32–64 ms later, which is
  not enough (1,200 played against 800 written at 52.9 s).
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
- NOSDRIVER, as an ISI/Phonet router that answers the DSP's PCM player
  and ends its tones at once. It also answers energy management (resource
  `0x17`): the charger is not connected (message `0x08` answered by `0x09`,
  subblock `0x13`), and the battery is full at 7 bars (`0x0A` answered by
  `0x0B`, subblock `0x16`). Nokia.dsy turns these replies into the System
  Agent's charger and battery states. Without the charger's, Xanadu Next
  exits at start and System Rush stops after its first screens. Snakes
  lost its music with it, until the current-call state below was
  published too.
  Accessory mode (`0x1C`) is answered "none", and any other service
  "service not identified";
- the mute and vibra controls;
- every other channel any boot opens, with its minimum answer: open and
  never complete, or complete with `KErrNotSupported`.

The Phone application publishes the System Agent's current-call state
(`0x100052CB`) once its call engine is up, which needs the modem. Here it
never is, so `RSystemAgent::GetState` answered `KErrUnknown` (-19), and
games read that as a call in progress. Snakes paused its music at start,
and played it only when a message-server event happened to resume it:
entries changed at boot while the game started, which stopped happening
once the charger reply moved the boot's timing. So the
launcher (`sw/kernel/launch.c`) publishes "no call" (`ESACallNone`, 0)
itself, with the message `RSAVarChangeNotify::NotifySaVarChangeL` sends,
before it starts the game.

The Starter's list (`Starter_Arm.RSC`) has a second half that waits for
the same idle state: FaxModem, NcnList, Satsvr, CalenSvr, clknitzmdls,
CbsServer, BtServer, UNIPERTAR, UnlockMMC, Emon, Notes. None of it ever
starts here. Games use BtServer: Ghost Recon's profile screen connects to
it through `BTSrvClient.dll`, which starts the server itself when it is not
running, but asks the loader for UID3 0x10005999 (the client's own) where
`BtServer.exe` is 0x10005950. EFile's loader compares the two after
loading (`0x503d9a28`) and answers `KErrNotSupported`, and the game waits
for ever with its music playing. The launcher starts
`Z:\System\Programs\BtServer.exe`, with no UIDs asked for, before the game.
At 30 MIPS that delays a game's start by some 0.6 s.

EikSrv's notifier server runs with no plugins. It looks for them in
`Z:\System\Libs\EikSrv.dll\system\notifiers\`, because the kernel's
`UserSvr::DllFileName` gives ROM code its whole path, where EKA1 gave the
drive alone. EikSrv appends `\system\notifiers\` and `\System\Libs\` to a Z:
name as it is, and cuts any other down to its drive first (0x5063bb6c,
0x5063e576). With the drive alone the plugins load (AknNotifyPlugin,
SecurityNotifier, btnotif, ...), and with them the phone's global notes over
the game: "App. closed Main" for AudioServer's panic, and Startup's "Device
start-up failed. Contact the retailer." So the path stays as it is. A
request for an unknown notifier completes `KErrNone` with its reply
untouched. The one reply a game was found to read is the keylock's.
`RAknKeyLock::IsKeyLockEnabled` starts `KAknKeyLockNotifierUid`
(0x100059B0) with reason 4 (inquire), and returns the reply's second word,
which without a plugin is its own uninitialised stack. Atari Masterpieces
Vol. 2 read "locked" there and closed at once. The kernel answers that
inquiry itself, "not locked" (`sw/kernel/ipc.c`).

Characters are the kernel's on EKA1: exec 0x4F-0x53 fold, collate, change
case and give a character's category (`TChar::GetCategory`, behind
estlib's `isalnum` and the rest of `ctype.h`). `sw/kernel/misc.c` answers
Latin-1 as the firmware's own tables do (euser's `TUnicode` data, read from
SYM.ROM: all 256 codes agree). Above that it knows only what is no
character: surrogates are Cs, private use Co, U+FFFE, U+FFFF and anything
past 16 bits Cn, and a value past 16 bits maps to itself, as the firmware
has them. Every other code above U+00FF is a letter (Lo), which the marks,
digits, symbols and punctuation of other scripts and 7,827 unassigned codes
are not. EOF is where this showed: `isalnum(-1)` asks for 0xFFFFFFFF's
category, and while the kernel took that for U+FFFF and a letter, the Lua
5.0 lexer in Requiem of Hell read past the end of a script whose last word
ends the file (GameWorld.lua's `end`) into the stale rest of its 1 KB
buffer. The script failed to compile, the game printed the error to
stderr, and the console estlib opened for it (the process renamed STDOUT,
a thread UI00) panicked with E32USER-CBase 46: back to the N-Gage logo at
"Start New Game".

`RDebug::ReadMemory` and `WriteMemory` (exec 0x97, opcodes 8 and 9) read
and write a thread's memory: chunk space for any thread, the data window
for the caller's own process. Asphalt Urban GT 2 decrypts its code with
`WriteMemory`, 0x1C0 bytes at a time from `cwivenc.dat`, and calls it at
once. Answered `KErrNotSupported`, it ran the ciphertext, which is no code
in either state.

A process's first thread has a 16 KB page mapped above its stack's top.
The Sims Bustin' Out saves with an `fwrite` of 8 KB from 0x164 bytes under
its stack's top; with nothing mapped above, the copy faulted at
`0x00830000` at 29 s and the game stopped on its loading screen. With the
page it reaches "Press 5 to start" (60 s at 30 MIPS).

**Not modelled, and what it costs:**

- adspserver's MADI link to the DSP over Comm unit 0. AudioServer panics
  ("SS Audio Server 4"). Key clicks and the tone player are silent (their
  tones are ended at once, above). No game's music or effects go this way.
- Bluetooth HCI. Snakes' multiplayer cannot start; single player runs.
- The radio side, SIM, telephony, the camera, IrDA and USB.
- The memory card's own interface (`MmcIf`): the drive is an image, with no
  card behind it to identify. Opened, it is absent (`KErrNotFound`).
  Asphalt Urban GT 2's copy protection asks there for the card it was
  installed on, and stops (an unmapped read, 22.7 s at 30 MIPS).

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

- Whether `0x2b` is also how the DSP ends a stream after its last buffer
  (the kernel sends it then), and whether `0x46` means 16 kHz.
- Snakes imports no stream library.
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
- The scheduler lends the CPU, which EKA1 never does. After 50 ms with
  neither the idle thread nor a lent slice run, the ready thread at
  priority 1-100 (EPriorityAbsoluteVeryLow and below) that has waited
  longest, and is its process's highest ready thread, gets 2 ms
  (`LEND_US`, `sw/kernel/sched.c`). NGVM is slower than the phone, and a
  game that left the phone's CPU idle part of the time can leave NGVM's
  none: on the RTL, Tony Hawk's Pro Skater ran not one instruction in
  the idle loop from 30 s to 60 s. A thread the firmware runs only in
  spare time then never runs. MediaServer's task thread is one, at
  EPriorityAbsoluteVeryLow (100), and it finishes creating a game's audio
  stream; Tony Hawk and Pandemonium were silent. Nothing above 100 is
  lent, nor anything at 0: a first version lent to every thread below
  the top, and so started the game's launcher (priority 0, `launch.c`)
  during the boot. On the Pocket, Sonic N, Virtua Cop, Bomberman and
  Worms then never got past the N-Gage logo; in the reference at 30 MIPS,
  Sonic N had opened its window before the phone's splash screen, which
  covered it for good.
  How much idle time the phone had, and so how close 2 ms in 50 comes to
  it, is not known.
