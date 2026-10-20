# First flash: what to do and what to read

For the person holding the Pocket. Keep this exact — it is read from while
someone decodes squares off a screen.

## Before flashing

- `sim/lint.sh` clean, and the same in CI's `verilator/verilator:v5.020`.
- `sim/run_mem.sh`: every byte the loader sends reads back through the bus,
  with the LCD fetching alongside, and masked line writes land in both
  memories.
- `sim/run_sys.sh` (the CPU side against Unicorn) agrees for the games' first
  seconds.
- `sim/run_system.sh` (the whole machine on the real memory glue) loads
  every byte in place and boots to the phone's start-up screens with no
  memory protocol error.
- **`tools/check_frames.py` passes on three CONSECUTIVE frames of a STILL
  picture** from `sim/run_system.sh` (`--snap N,N+1,N+2` on the Nokia logo).
  If neighbours differ while frames two apart are identical, the core is
  emitting alternating fields. The Pocket's panel is OLED and holds the
  difference between the two images — as retention that fades, and with
  enough hours as wear that does not. Do not flash until it passes
  (METHODOLOGY 5.23).
- `tools/check_json.py pkg/pocket --active 176x208` clean.
- `./build-local.sh compile`: no negative slack in any corner
  (`projects/output_files/*.sta.summary`), no ignored constraints.

| build | CPU | md5 of the packaged `bitstream.rbf_r` | worst slack, setup / hold |
|---|---|---|---|
| first flash | 64 MHz | `346512887beedbb39c6aa82c3d304ba3` | |
| second | 73.85 MHz | `42a6ceb0fc00f8e8a03dc8d806bd09cb` | +0.653 / +0.079 ns, both on the CPU's clock |

Each passed all of these, with one exception for the first: two of the
template's multicycles matched nothing. With one random-access client, the
pointer they relax is optimised away, so the paths were timed in one cycle
and met. The second build takes the two lines out, and its reports name
no constraint of ours as ignored.

## On the card

`python3 package-pocket.py`, then `Cores/`, `Platforms/` and `Assets/` from
`release/pocket/` onto the card root with `cp -X` from macOS (not the
package's own `README.md`, which would replace the card's), and remove the
`._*` files it leaves. Then, from the
user's own files, into `Assets/ngage/common/`:

| file | what |
|---|---|
| `ngvm.bin` | the core's kernel — already there from the package |
| `sym.rom` | the phone's firmware dump, 18,612,224 bytes for the one this was built on |
| `vcop.img`, ... | each game's card, `python3 mkdrive.py --from <game.zip> --out <name>.img` |

The game list (`Assets/ngage/plasticbugs.ngage/*.json`) names the `.img`
files. Verify the bitstream's md5 on the card.

## What should happen

Loading takes a while: about 35 MB go through the loader (the firmware and
a 16–18 MB card), and the screen stays black until the last byte is in.
Then, as `sim/run_system.sh` ran Virtua Cop with the CPU at 64 MHz, as
the first flash has it (machine time from the end of the load; the frames
are in `artifacts/system/vcop64/`, and every one from 10 to 25 s is
pixel-identical to the reference emulator's):

| time | screen | sound |
|---|---|---|
| 0–5 s | black: the LCD is still off | none |
| 10 s | the Nokia logo, on white (still there at 15 s) | none |
| 20 s | the N-Gage logo, on black | none |
| 25 s | the same, with Nokia's copyright under it | none |
| 30 s | SEGA | none |
| 35 s | X-Forge | the music starts at 35.9 s |
| 40 s | Virtua Cop's title, "press any key" | music |

The music the bench recorded is sample-for-sample the reference's
(`artifacts/system/vcop64/music_from_35.9s_16k.wav`). The bench stops at the
FIFO's output, though: the hand-over to the Pocket's audio clock is not in
it.

The reference emulator reaches the title at 30 s at 100 MIPS. On the
Pocket's memories the RTL delivers about 17–21 MIPS while the firmware
boots, most of it waiting on first-time cache misses. A stopwatch reading
of when the title appears on hardware is worth writing down. If it is far
from 40 s, the memories are slower or faster than the bench's models.

## The panel

Menu → **Bring-up: panel**. Four rows of 32 squares along the bottom of
the picture. Green is 1. Read each row from the end where row 0 shows
`1010 1010`. The squares are 5 pixels wide (the picture is 176).

| row | squares | meaning | healthy |
|---|---|---|---|
| 0 | 1–8 | alignment marker | `1010 1010` — if not, stop: the reading is misaligned |
| 0 | 9–16 | frame counter | changing |
| 0 | 17 | PLL locked | 1 |
| 0 | 18 | memory ready | 1 |
| 0 | 19 | downloading | 0 |
| 0 | 20 | all slots complete | 1 |
| 0 | 21 | loaded | 1 |
| 0 | 22 | core in reset | 0 |
| 0 | 23 | the kernel panicked (`IO_DBG_EXIT`) | 0 |
| 0 | 24 | the LCD is on (`IO_LCD_CTRL`) | 1 once the firmware draws |
| 0 | 25–32 | keys: Y X B A right left down up | 1 while held |
| 1 | 1–32 | an address the CPU executed lately (it changes about 15 times a second) | changing; see below |
| 2 | 1–32 | the last four characters the kernel printed, ASCII, oldest first | changing during boot |
| 3 | 1–16 | KB loaded at the firmware's address | `0100 0111 0000 0000` (18,176 KB) for an 18,612,224-byte `sym.rom` |
| 3 | 17–32 | KB loaded at the card's address | `0100 0000 0000 0000` (16,384) for a 16 MB card; Bomberman's is `0100 0100 0000 0000` |

Row 1:

- **Below `0x0010_0000`.** The kernel.
- **`0x5xxx_xxxx`.** The firmware, running from ROM.
- **`0x4xxx_xxxx` or `0x004x_xxxx`.** User code in RAM.
- **One value that never changes.** The CPU is stuck there; write it down.

## If it is wrong

| symptom | look at |
|---|---|
| row 0 square 21 stays 0 | the loader never finished: are all three files where the list says? |
| row 3 not the file sizes | the download path; `sim/run_system.sh --full` sends every byte the loader's way |
| black, rows 1 and 2 changing, square 24 0 | the firmware has not turned the LCD on yet: wait, then report row 2 |
| black, square 24 1 | the LCD's fetch: `IO_LCD_BASE` and the burst port (`rtl/ngvm_lcd.sv`) |
| row 1 frozen | the CPU stopped: report the address; then the clock crossing (`rtl/ngvm_xbus.sv`) |
| row 0 square 23 is 1 | the kernel panicked: row 2 holds the end of its message |
| picture wrong in a pattern | the SDRAM switches below, then the PLL phase (SDC, METHODOLOGY 5.20) |
| a moving picture combed, or old above a line and new below it on every frame | the copy on `IO_LCD_SHOW` (`rtl/ngvm_lcd.sv`): a copy that tears once is expected, one that tears every frame is not |
| menu restarts the game | `pause` has reached a reset; METHODOLOGY 5.5 |

Menu → **SDRAM read late** and **SDRAM slow bursts** change how the SDRAM
is read. Try each alone if the picture or the boot looks corrupt, and report
which changed anything.

Menu → **SDRAM fast reads** (second build on, off by default) issues a
burst's READs one a clock instead of one every two. On the bench it makes
a cache line's fetch 34 memory clocks instead of 47, and the CPU about 8%
faster through Virtua Cop's boot (726 against 673 million instructions in
its first 20 s; the Nokia logo at 6.5 s, the N-Gage logo at 16.0 s). The
bench's SDRAM model cannot say whether the Pocket's chip is read soundly at
that pace: on another core it was not (METHODOLOGY 5.28). Turn it on while
a game runs. If the game crashes, freezes or draws garbage, it is unsound:
turn it off and report what you saw. Leaving it on does not survive a
reload.

The game runs on while the menu is open: that is expected (NGVM does not
pause yet).

## With an Analogizer

Only once the core itself is healthy on the Pocket's screen, and in this
order — each step's reading tells the next where to look
(docs/analogizer.md):

1. **Menu "Analogizer: Off"** (the default). The core must play exactly as
   without the adapter. If it does not, the cart port is not idle: stop.
2. **Menu: Analogizer On, Video RGBS, SNAC Adapter None.**
   The same picture on the Pocket and the CRT, at 15.17 kHz and 59.96 Hz.
   The picture is 176 dots of a 452-dot line, so it is narrow on a CRT.
   The bring-up panel shows on the CRT too. No picture: say whether the CRT
   reports a signal (sync but no colour points at the DAC clock; nothing at
   all points at sync).
3. **Each other video mode in turn** (RGsB and YPbPr need the SOG switch on).
4. **SNAC**: one pad, assignment "SNAC P1 -> P1".
5. **The menu's memory**: change Video, quit the core and load it again.
   The setting, and Analogizer On, should still be there.
6. **Position**: "Analogizer V Position" + should move the picture down
   by that many lines, + on "H Position" to the right, and both should be
   kept across a reload.

## Log

Date, build md5, what was seen, what it ruled out. One line each. The theories
that died belong here as much as the one that lived.

- 2026-10-19, `346512887beedbb39c6aa82c3d304ba3` (64 MHz): boots and runs
  Sonic into gameplay, with sound. Seen: what looked like
  interlacing during motion, mostly Sonic's title screens and animations and
  not its gameplay; sound that felt late; a low frame rate. That the picture
  appeared at all rules out a gross fault in the loader, the SDRAM's capture
  phase, the CRAM and the clock crossing. The theory for the
  "interlacing": the LCD scanned the framebuffer while the game drew it, and
  the rows reached SDRAM out of order through the write-back cache. The
  reference emulator, shown only what the firmware sends the display, never
  has a frame of one parity alone (docs/hardware.md, LCD). The audio FIFO
  held 128-256 ms. The second build copies the picture on the firmware's
  update instead, holds 32-64 ms of sound and runs the CPU 15% faster. If
  it still combs, the theory is dead.
