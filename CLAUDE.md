# CLAUDE.md — building an arcade core for the Analogue Pocket

You are building an openFPGA core for one arcade board. This repository starts
as a **working skeleton**: it compiles, closes timing, passes its memory gate,
and on a Pocket shows a test pattern with a cursor on the d-pad, a beep on
button 1 and a bring-up panel. Your job is to replace the inside of
`rtl/mycore_core.sv` with the machine, without ever breaking what already
works around it.

`METHODOLOGY.md` is the long form of everything below, written from five cores
that shipped. **Read it before you write RTL.** Sections 5.8 and 5.16–5.22 are
the ones learned most expensively. This file is the short form, the rules, and
the map.

## The method, in one paragraph

MAME is the oracle. A Python reference renderer, checked pixel-for-pixel
against MAME, is the executable specification. Frozen machine states captured
from MAME are the regression gate: load one into the RTL, render it, diff the
output against the reference. Measure before diagnosing, and suspect the
instrument first. Simulation proves the machine; it proves nothing about the
Pocket unless the bench talks to the core the way the Pocket does.

## Order of work

Do these in order. Each ends with something checkable; do not start the next
until it is checked, and commit at each one.

1. **`tools/init_core.py <shortname> "<Title>" [author]`** — stamps the names
   through the tree. Then fill in the header of `README.md`.
2. **Read MAME's driver and devices** into `ref/mame/` (verbatim, fetched) and
   write `docs/hardware.md` from them: memory map, I/O bit by bit, interrupts,
   clocks, the video chip's registers and draw order, the sound board. Use
   Ghidra on the program ROM for anything the driver leaves implicit. No RTL
   yet.
3. **The ROM image.** Write `mycore.mra`, build the image with
   `tools/mra_build.py` **and** the standard `mra` tool (`tools/check_mra.py`
   requires the same md5 from both), and write a `tools/verify_rom.py` (the pattern is in
   `tools/examples/`) that proves every region is byte-identical to what MAME
   hands the chips. Set the region bases in
   `target/pocket/mycore_mem.sv` and `sim/tb_mem.cpp` to match, and run
   `sim/run_mem.sh`.
4. **The reference renderer** — a Python model of the video hardware, in
   `tools/`, pixel-identical to MAME on captured frames that span boot, attract, gameplay and any special mode. Expect to get
   bit-plane order, scroll sign and frame alignment wrong once each.
5. **Video RTL against frozen states** — a bench that loads a dumped state and
   diffs palette indices against the renderer. Zero differing pixels, then
   measure the line and sprite budgets against a real memory latency.
6. **CPUs, then the whole machine** on the fast bench with ideal memories.
7. **The whole machine on the real memory glue** — `sim/run_system.sh`, which
   is in this template and already runs against the skeleton: real
   `mycore_mem`, real SDRAM controller and SRAM port, behavioural chips beyond
   the pins, image pushed in at the loader's rate. Keep the fast
   ideal-memory bench too, but this is the one to pass *before the first
   flash*.
8. **Sound**, compared with a MAME recording by band energy over a whole
   capture.
9. **Hardware.** Flash, and read `docs/bringup.md` with the person holding the
   Pocket. Then release from the tested build.

## Rules that are not negotiable

- **Never commit ROM data.** Not the romset, not the built image, not a hex
  dump of a region. `.gitignore` excludes them, `tools/check-no-roms.sh` checks
  the tracked set, `package-pocket.py` sweeps the package. Run the check before
  every push. Screenshots and machine-state dumps (RAM, not ROM) are fine.
- **Commit often, one logical change each, and say in the message what was
  measured** — and what was *not* proven. A message that claims more than was
  shown is a trap for the next fault that looks similar.
- **Put visual and audio output in `artifacts/`** where the user can look and
  listen. It is a bisection tool, not a courtesy.
- **Never push to find out whether timing closed.** `./build-local.sh compile`
  gives the same slack as CI to three decimals. Push when it is green locally.
- **Every change to RTL that draws pixels goes through the frozen-state gate
  before it is committed**, including "pure" timing refactors.
- **Correct yourself at once and in the open** when a measurement overturns
  something you said. Say what each build is predicted to change; when it
  changes nothing, drop the theory.
- **Do not make artwork.** `icon.bin` is the house icon, the same in every
  core, and ships with this template — never regenerate it. The platform image
  (`pkg/pocket/Platforms/_images/<shortname>.bin`) is made by the user and
  supplied when it is ready; the core works without one, so leave it out until
  then and do not generate a stand-in from screenshots.
- **Keep attribution intact and keep `CREDITS.md` current.** Never strip or
  rewrite an SPDX or copyright header in `platform/` or `modules/` — those
  headers are the licence. `platform/pocket/` is Marcus Andrade's
  OpenGateware `gateman-pocket` platform and the build runs in his
  `raetro/quartus:pocket` image; when you vendor a CPU or sound core, record
  it in `modules/VENDOR.md` and name its author in the README.
- When the user reports something from hardware, **believe it, and parse it**:
  "only during gameplay", "gone when the menu is open", "on alternate lines"
  are each half a diagnosis.

## Traps this template already defuses — do not re-arm them

| Trap | Where it is handled | Section |
|---|---|---|
| The Pocket's loader cannot wait; a single pending download word corrupts the image | 64-word FIFO, edge-detected strobe, in `mycore_mem.sv`; `sim/run_mem.sh` fails without it | 5.16 |
| The write strobe is held 4 clocks; anything that counts on its level is wrong | the gate's `-hold` | 5.8 |
| A shared port's ack carries no name | latch the owner at grant; route the ack by it, never by who is asking when it lands | 5.17 |
| 2-D or non-power-of-two arrays of flops | one-dimensional, power-of-two RAMs only | 5.18 |
| The menu-open signal wired into reset | `pause` freezes `clk_enables.sv`; video keeps running | 5.5 |
| DIP register rewritten on menu close | `interact.sv` resets only on a changed value | 5.5 |
| Pixel hand-over to the video clock at a random phase | `pix_sync` pins the dot divider to `clk_vid` | 5.4 |
| Audio sampled across clock domains | 48 kHz hold + toggle hand-over in `core_top.sv` | 5.4 |
| A constraint that silently matches nothing | CI step "Check every constraint was applied" | 5.20 |
| SDRAM capture timing | the PLL phase is a dial between setup and hold; how to set it is in the SDC | 5.20 |
| Aspect ratio with a rotated picture | it describes the raster *before* rotation | 5.5 |
| **A picture that alternates between frames marks the Pocket's OLED** | `tools/check_frames.py` on three consecutive frames of a still screen, before the first flash | 5.23 |
| An interlaced CRTC faithfully alternating fields | keep the geometry, draw the same field every frame | 5.23 |
| `video.json` declaring a size the core does not emit | `tools/check_json.py --active WxH`; the symptom is three bugs at once | 5.23 |
| `interact.json` the firmware refuses with "General Error" | `tools/check_json.py`; ids unique, `defaultval` is an option INDEX, no value with bit 31 set | 5.23 |
| A power-on self-test overwriting what the loader just wrote -- and the panel still reading a pass | `sram_selftest.sv` reads its two words first, writes them back last, and runs after the load | 5.25 |
| A game list (instance JSONs) flagged by the checker for a slot with no filename | `tools/check_json.py` accepts it when every instance names the file | 5.26 |
| An `.mra` that only this repo's builder reads correctly (interleave `map` direction, padding bytes, merged sets) | `tools/check_mra.py <romdir>` builds each with `mra_build.py` and the standard `mra` tool and fails if they differ; maps are read right to left | 5.7 |
| A release zip and title named after another core | `tools/cut-release.sh` reads both from the package; it also takes the flashed bitstream directly | 5.6 |
| Analogizer support that the Pocket never configures: a menu entry writing outside its mask, no entry setting the enable, a file slot loading over the menu's word, cart slot unpowered | `tools/check_json.py` checks the entries at `0xF7000000`, the slots and `cartridge_adapter` | 5.30 |
| Analogizer menu entries wiping each other: the bridge samples read data before it pulses `bridge_rd`, so a read-back latched on the pulse is the previous read's | `pocket_analogizer.sv` reads the word back combinationally; `sim/run_analogizer.sh` sets every option by read-merge-write and fails without it | 5.30 |
| Analogizer scandoubler sized to the visible width, or fed no blanking | `LINE_LEN` is the whole line; `sim/run_analogizer.sh` counts the doubled lines | 5.30 |
| A menu the firmware refuses at load with "Error in interact": too many list options (70 and 77 refused, 64 and 68 load) | `tools/check_json.py` fails above 68 options or 80 options plus entries | 5.30 |
| A 25 or 31 kHz board on a 15 kHz CRT: two or seven copies of the picture | `target/pocket/ana_15k.sv`, a frame-locked half-line-count picture; `sim/run_ana15k.sh` checks it and prints its `DELAY` window | 5.30 |
| A release the core list shows under the previous release's date | `tools/cut-release.sh` refuses a `core.json` whose version is not the tag or whose `date_release` is not today | 5.32 |

Not defusable in code -- read these before you meet them:

- **Moving a data slot moves every slot id in `core_top`**, and the save has a
  write path *and* a load path; one missed, the file is written and never
  read back (5.24).
- **Frame drops do not show in CPU cycles per frame**; count the game's page
  flips against MAME's (5.27).
- **On the Pocket, SDRAM burst writes take one word a clock; burst reads may
  not** -- keep the pace a runtime choice per direction until hardware has
  chosen, with the tested setting as the all-clear default (5.28).
- **The Analogizer is built in** (`USE_ANALOGIZER`, docs/analogizer.md):
  set `LINE_LEN` in `core_top` and the raster at the top of
  `sim/tb_analogizer.sv` when the machine's raster replaces the skeleton's,
  read `key1..key4`, never `cont*_key`, wherever the game takes its
  controls, or SNAC pads will not reach it, and keep its six menu entries
  (ids 70-75, `0xF7000000`-`0xF7000008`) when you write the game's own into
  `interact.json` -- Analogue's limit is 16 entries, 20 with the data slots, and the
  firmware's is 68 list options (`tools/check_json.py`).
  Set the two position sliders' range from the new raster's blanking;
  the bench fails if a sync reaches the picture at either end (5.30).
- **An emulator's saved settings are hidden state**: give each investigation
  its own `-cfg_directory` / `-nvram_directory` (5.29).
- **Lua's `set_value` on an analog field writes the raw port value, clamped
  and not inverted** -- not what a player's press gives the game. Read the
  port the game reads before trusting a trace's input (5.31).
- **CI runs Verilator 5.020 and Quartus 18.1, both older than yours**: before
  pushing RTL, lint in the `verilator/verilator:v5.020` container and run
  `./build-local.sh map`; a fix for one has broken the other (5.30).

## The map

```
CLAUDE.md METHODOLOGY.md README.md      read in that order (README is the core's own after init)
CREDITS.md                              whose work this sits on; extend, never trim
docs/hardware.md                        the board, from MAME and the ROM — write first
docs/core-design.md                     how it maps onto the Pocket, and the budgets
docs/bringup.md                         what to do and read at the first flash
ref/mame/                               MAME sources this was written against, verbatim
rtl/mycore_core.sv                      THE MACHINE.  skeleton now; ports are the contract
rtl/clk_enables.sv                      CPU/sound/dot enables, with pause and pix_sync
rtl/dbg_overlay.sv  rtl/dbg_fault.sv    the bring-up panel and the first-fault capture
modules/                                vendored CPUs and sound chips; VENDOR.md says from where
target/pocket/core_top.sv               APF glue; game-specific only below "@ The game"
target/pocket/mycore_mem.sv             SDRAM clients, download FIFO, burst arbiter, SRAM
target/pocket/sdram_ctrl.sv sram_port.sv   proven on hardware; do not edit casually
target/pocket/pocket_analogizer.sv     the Analogizer: clock hand-over, Y/C, SNAC -> key1..4
target/pocket/ana_15k.sv               a 15 kHz picture from a 25/31 kHz board, for the Analogizer
target/pocket/analogizer/              RndMnkIII's adapter module, verbatim (docs/analogizer.md)
projects/                               Quartus project, SDC, report_worst.tcl
platform/pocket/                        OpenGateware's gateman-pocket (Marcus Andrade) — leave alone
pkg/pocket/                             what goes on the SD card (never a ROM)
sim/lint.sh                             every module linted on its own
sim/run_mem.sh                          the memory gate: an image in at the loader's rate, and back out
sim/run_system.sh                       the whole machine through that same glue — pass before flashing
tools/                                  MAME wrappers, ROM builder, pixel diff, ROM guard, release
tools/examples/                         game-specific tools from Master of Weapon, as patterns
build-local.sh  package-pocket.py       Quartus 18.1 in Docker; the SD-card package
.github/workflows/compile.yml           lint, compile, constraint check, timing check
```

## Commands

```sh
tools/init_core.py galaga "Galaga" <github-handle>   # once, before anything else
sim/lint.sh                  # seconds; before every commit
tools/check_frames.py artifacts/still -w W -h H   # THREE CONSECUTIVE frames of a
                             # still screen.  A picture that alternates leaves a
                             # ghost on the Pocket's OLED -- before the first flash
tools/check_json.py pkg/pocket --active WxH       # what the firmware silently refuses
sim/run_mem.sh -quick        # a minute; after touching mycore_mem.sv (drop -quick before a flash)
sim/run_system.sh -frames 10 # the whole machine through the real memory glue
sim/run_analogizer.sh        # the Analogizer path, read at the cartridge pins
sim/run_ana15k.sh            # the 15 kHz converter, if the board is not 15 kHz
tools/vendor.sh              # list the CPU and sound cores it can fetch from upstream
./build-local.sh map         # two minutes; catches what Verilator cannot
./build-local.sh compile     # 10-25 minutes; then read projects/output_files/*.sta.summary
docker run --rm --platform linux/amd64 -v "$PWD":/build -w /build \
    raetro/quartus:pocket quartus_sta -t projects/report_worst.tcl   # worst paths, every corner
tools/check_mra.py <romdir>  # every .mra, built by mra_build.py AND the standard mra tool
tools/check-no-roms.sh       # before every push
tools/gen_qip.sh             # after adding a file to rtl/ or modules/
```

MAME may be shared with other sessions on this machine and a headless run can
be killed mid-way: always pass `-seconds_to_run`, write results from a stop
notifier, and check the run reached its target frame (`tools/mame.sh`).

## Working with the person holding the Pocket

They are your only instrument on hardware, and each reading costs them
minutes. Before every build say what you expect to change and what reading
would prove you wrong. Ask for the game's own test pattern (service mode)
before a photograph of gameplay. Keep `docs/bringup.md` exact, because they
read the panel from it. Ask once whether they want every build put on the SD
card as soon as it compiles: some people test on hardware faster than you can
simulate, and then waiting to be asked costs a round (a test once ran on the
previous build because the new one was never copied). Copy with `cp -X`,
remove the `._*` files it still leaves in the folders you wrote, verify the
md5 on the card, and never touch their ROM.
