# Adding the Analogizer to a core not built from the current template

A handoff for whoever, person or agent, adds
[Analogizer](https://github.com/RndMnkIII/Analogizer) support to an existing
Pocket core that predates it in this template. A core started from the
template today already has it; `docs/analogizer.md` describes that, and
should be read first. This file is the order of work and the traps, written
from adding it to Moo Mesa (2026-10; `plasticbugs/moomesa`, branch
`analogizer`, a complete worked example of every step below; its commit
`72271e8` used the settings file, `c631ff4` moved it to the menu, and
`8187bfe` added the position sliders)
and from the MSX2 core, where RndMnkIII and plasticbugs added it by hand
(2026-08). Fifteen more of plasticbugs' cores followed this file in
2026-10 and are on hardware (`docs/analogizer.md`, *On hardware*); what
they taught is folded in below.

The template is the source for every file named here. Copy from it rather
than from another core: the copies in other cores drift, and RndMnkIII keeps
editing his module per core (the copy in MiraxPocket carries two lines marked
"FIX ONLY FOR XAIN'D SLEENA").

## 0. Decide before touching anything

Answer these from the core's own source, and write the answers into the
commit message:

1. **The dot rate and the whole line.** Total dots per line, blanking
   included, at the core's pixel enable. That is `LINE_LEN`. Using the visible
   width is the trap: the MSX2 core first shipped with 290 on a 684-dot line,
   and the right half of every scandoubled line was lost.
2. **Real H and V blanking.** The scandoubler times every output line from
   the H-blank edges. If the core only has a combined DE, derive
   `hblank = !visible_x` and `vblank = !visible_y` from its counters. The MSX2
   hook first tied them to 0: syncs and blanking came out garbage in every
   scandoubled mode, and RGBS lost its blanking.
3. **The clock to give the Analogizer.** It clocks the DAC through the
   cartridge pins, so keep it near 48 MHz (cores ship at 42.95-48 MHz) and at
   least 4x the dot rate.
   - `clk_sys` is already 40-50 MHz: pass it as both `clk` and `clk_src`.
   - `clk_sys` is faster (this template's is 96 MHz): use a spare PLL output at
     `clk_sys / 2`, phase 0. Check which `outclk_N` is free in
     `core_pll_0002.v`.
   - Video on its own unrelated clock: `clk_src` is that clock and `clk` any
     ~48 MHz. The hand-over is a real synchroniser, but put the two in separate
     asynchronous clock groups in the SDC.
4. **The pixel's settling time after the dot enable.** That is `PIX_LAG`
   (default 2 source clocks). If the colour reaches its final register more
   than two clocks after the enable, raise it.
5. **Where the core reads controllers.** Every place that reads
   `cont1_key..cont4_key` must read `key1..key4` instead, including direct
   reads for players 3 and 4 that bypass the `gamepad` helper.
6. **Free resources.** On Moo Mesa (LINE_LEN 512) the Analogizer cost
   **1,550 ALMs, 13 RAM blocks and 2 DSP blocks** (265 → 278 of 308 blocks).
   The scandoubler's and HQ2x's line buffers scale with `LINE_LEN`. A core
   within ~15 blocks of 308 may not fit, so check the last fit summary before
   starting. If it does not fit, the module's local `USE_YC = 0` and
   `USE_SD = 0` leave out the Y/C encoder and the scandoubler with HQ2x
   (`docs/analogizer.md`, *Fitting it*): S.T.U.N. Runner went from 102% to a
   fit with both, Gaiapolis and Master of Weapon the same. Ask the owner
   first; those modes leave the menu.
7. **Bridge address `0xF7xxxxxx` is free.** Grep the core for anything
   decoding it, including a `casex` with `32'hFxxxxxxx`. The menu writes the
   settings word there.
8. **Does the core already have an Analogizer?** If it does (MSX2 does), this
   is a replacement. Keep its settings scheme (menu or file, section 4) and
   its SNAC mapping until the user says otherwise.
9. **Room in the menu.** The Analogizer adds six `interact.json` entries
   (four lists with 32 options, two sliders). Analogue allows 16 entries,
   20 with the data slots, and the firmware refuses a menu with too many
   options, with "Error in interact" at load: 70 and 77 were refused on
   hardware, 64 and 68 load. `tools/check_json.py` fails above 68 options,
   80 options plus entries, or 11,568 bytes. Count the core's own before
   starting. If it is short of room, compact the file's layout (one option
   to a line), then trim, asking the owner: the Analogizer lists' rarely
   used options, then the core's Scanlines / Shadow Mask, then DIPs nobody
   changes (`docs/analogizer.md`, *The menu's size*).
10. **The line rate.** If the board is not 15 kHz (a 25 kHz medium-res or
   a 31 kHz VGA-rate monitor), a 15 kHz CRT shows its picture as two or
   more copies. Plan `target/pocket/ana_15k.sv` between the core and the
   wrapper (`docs/analogizer.md`, *A board that is not 15 kHz*), with its
   bench, before anything goes to hardware. Xenophobe and Atari System 2
   both went out without it first and came back doubled and in seven.
11. **The blanking, for the position range.** How many dots between the
   end of the picture and hsync, and between hsync's end and the next
   picture; how many lines between the picture and vsync on each side.
   They set the two position sliders' range (section 4); with `ana_15k`,
   the converter's blanking.

## 1. Copy the files

From the template into the core, unchanged:

```
target/pocket/analogizer/            RndMnkIII's module, 15 files + our analogizer.qip
target/pocket/pocket_analogizer.sv   the wrapper
sim/ps2_keyboard_stub.v              Verilator stand-in for the one VHDL file
sim/yc_out_legacy_stub.v             stand-in for yc_out_legacy.sv in lint (CI's Verilator 5.020)
sim/tb_analogizer.sv                 the bench (set its raster, step 7)
sim/run_analogizer.sh
tools/check_json.py                  or merge its Analogizer block, if the core's copy differs
docs/analogizer.md                   then set the core's numbers in it
```

and, for a board that is not 15 kHz (step 0.10):

```
target/pocket/ana_15k.sv             the converter
sim/tb_ana15k.sv sim/run_ana15k.sh   its bench; add the board's line to CONFIGS
```

If the core's layout differs (`src/fpga/...`), put the two Verilog pieces
next to its `core_top` and adjust the paths in `run_analogizer.sh` and the
lint. Do **not** put the module under `modules/` if `tools/gen_qip.sh` or the
lint globs `modules/*`. It would be swept into every lint and into the qip
twice. Do **not** add the upstream `sync_fix.v` either: the top file already
defines `sync_fix`.

## 2. Quartus

- `core.qip` (or the qsf): add `pocket_analogizer.sv` and
  `QIP_FILE analogizer/analogizer.qip`.
- The PLL (if step 0.3 said so): set `output_clock_frequency<N>` to
  `"48.000000 MHz"`, phase 0, in `core_pll_0002.v`. Name it `clk_ana` where
  `core_top` takes the output.
- The SDC: add that output's `general[N].gpll~PLL_OUTPUT_COUNTER|divclk` to
  the core PLL's clock group. If the core's CI checks that every constraint
  applied, a name that matches nothing fails it, which is the point.

## 3. `core_top.sv`

Take the template's `core_top.sv` as the reference and search for
`USE_ANALOGIZER`, `key1`, `ana_bridge_rd_data`, `ana_pocket_off` and
`pocket_analogizer`. In order:

1. Parameter `USE_ANALOGIZER = 1`.
2. Wrap the core's "cart is unused" `assign`s to `cart_tran_*` in
   `generate if (USE_ANALOGIZER == 0)`. The wrapper drives the pins
   otherwise, and holds them at exactly those levels until the menu enables
   it.
3. The bridge read mux: `32'hF7xxxxxx: bridge_rd_data <= ana_bridge_rd_data;`.
4. `wire [31:0] key1..key4`, and every `cont*_key` read changed to `key*`
   (step 0.5). Joystick and trigger words are unchanged.
5. Blank the Pocket screen: bring `ana_pocket_off` into the video clock
   domain with two flops and zero the RGB *going to the Pocket's scaler only*.
   The Analogizer is fed from before that point.
6. The instance, inside `generate if (USE_ANALOGIZER == 1)`, with the
   `else` branch tying `key* = cont*_key`, `ana_bridge_rd_data = 0` and
   `ana_pocket_off = 0`. Connect:
   - `clk`, `CLK_HZ`, `clk_src`: step 0.3. `LINE_LEN`: step 0.1.
   - `rst`: the core's reset, held through the ROM load. Any domain.
   - `src_pix_ce`, `src_rgb`, `src_hs/vs/hb/vb`: the core's dot enable and
     the picture **as the Pocket gets it, before any scaler-side blanking**.
     Syncs and blanks active high; the module corrects sync polarity itself,
     but the blanks must be active high. Use the bring-up panel's output if
     the core has one, so the panel can be read off a CRT.
   - The bridge signals, `cont1..4_key`, and every `cart_*` pin straight
     through.

## 4. Settings: the menu, not the file

Copy the template's four entries (ids 70–73, all at `0xF7000000`) into the
core's `interact.json`: "Analogizer" (enable, and the Pocket-screen blank),
"Analogizer Video", "SNAC Adapter", "SNAC Assignment". Each is a list whose
mask keeps every bit but its own field, `defaultval` 0, `persist` true.
Change an id only if the core already uses it. The bit layout is in
`docs/analogizer.md`.

Then the two position sliders, ids 74–75: "Analogizer H Position" at
`0xF7000004` and "Analogizer V Position" at `0xF7000008`, `slider_u32`,
`signed`, `defaultval` 0, no mask. Set their range from step 0.10:
rightward, hsync can come earlier until it meets the picture; leftward,
later until the Y/C colour burst (it ends about 3.5 µs after hsync does)
would; vertically, until vsync reaches a picture line. The template's
skeleton gives ±16 dots and ±2 lines, Moo Mesa ±24 and ±16. The bench
tries both ends.

Optionally, where the menu has room (vertical games most of all: with the
CRT on its side, width is the game's height), "Analogizer H Size", id 76,
at `0xF700000C`, a signed slider in percent. Its range comes from the
line's whole free blanking with the picture centred (Namco and the Time
Pilots ship ±20%); the bench centres it with H Position before measuring.

The adapter module 1.4 was written to read `analogizer.bin` instead, a file
Pupdate and AnalogizerConfigurator write to `/Assets/analogizer/common/`.
The first version of this handoff said to use it. Do not: the adapter's
*How to use it* page never mentions the file, players do not have it, and
their other Analogizer cores are set from the menu (the wiki's "Pocket
Menu" kind). With the file, a player who installs the core has an adapter
that stays dark and no way to find out why.

Two things about the word, both already in `pocket_analogizer.sv`:

- The module is told `bridge_endian_little = 1`. Menu values are numbers;
  the byte swap it does for a file would move every field.
- The word is read back from the wrapper's own register, combinationally,
  not from the module's read-back. The bridge samples read data before it
  pulses `bridge_rd`, so the module's latched value is the previous read's,
  and masked entries merged from it wipe each other. The bench fails at the
  second menu entry with the module's read-back.

If the core already reads `analogizer.bin` (an earlier retrofit, or the
first Moo Mesa branch), remove its data slot, the `analogizer` platform id
and the slot's `parameters`; a slot left at `0xF7000000` would load a file
over the menu's word at every start, and `tools/check_json.py` refuses it.

## 5. The package

- `interact.json`: the six entries (section 4).
- `core.json`: `"cartridge_adapter": 0`. The platform ids stay the core's
  own; no `analogizer` id is needed without the file.
- `info.txt`: one paragraph. Settings are in the core's menu ("Analogizer:
  On"), and the cartridge slot is powered, so remove any game cartridge
  first.
- `tools/check_json.py pkg/pocket --active WxH` fails if an entry writes
  outside its mask, no entry sets the enable, a data slot writes
  `0xF7000000`, the slot is not powered, or the menu is larger than any
  installed core's.

## 6. Credit

`CREDITS.md`, the README and `modules/VENDOR.md` (or the core's equivalent):
RndMnkIII for the adapter and module, with the authors his module carries:
Mike Simone (Y/C), Sorgelig and Ludvig Strigeus (scandoubler, HQ2x), and the
SNAC controller code he credits. Copy the template's rows and change nothing
but paths.

## 7. Prove it, in this order

1. `sim/lint.sh` with the Analogizer block from the template's `lint.sh`,
   and once more as CI runs it: CI's Verilator is 5.020, older than a
   Mac's, and cannot parse the vendored `yc_out_legacy.sv` (the template's
   lint uses `sim/yc_out_legacy_stub.v` in its place) or lint the SNAC
   module without `-Wno-BLKANDNBLK`. Every Analogizer push failed CI until
   that was found.

   ```sh
   docker run --rm --platform linux/amd64 -v "$PWD":/w -w /w \
       --entrypoint sh verilator/verilator:v5.020 -c ./sim/lint.sh
   ```
2. `sim/run_analogizer.sh`, after setting the raster at the top of
   `sim/tb_analogizer.sv` to the core's: system clocks per dot, totals,
   visible window, sync positions, `CLK_HZ`. It must print `PASS`, and the
   RGBS line must show `0 differ`, every visible dot and line, and the
   scandoubler at exactly twice the lines and half the line period. A
   scandoubler line count off by a few means `LINE_LEN` or the blanking is
   wrong (step 0.1, 0.2). The `menu:` line must count every option of the
   four list entries (32). The `position` lines must show csync moving
   by the dots and lines asked at both ends of the sliders, never low
   inside the picture, and the two `at once` lines 0 clocks: a range too
   wide for the core's blanking fails here. The script reads them from
   `pkg/pocket/Cores/*/interact.json`; point it at the core's own package if
   that lives elsewhere (`dist/Cores/...`).
3. The core's own gates, unchanged: frozen states, memory, system bench.
   With the menu at its default nothing in the machine changed, and they
   show that.
4. `./build-local.sh compile` (or the core's build). Read the fit summary for
   RAM blocks and ALMs, and the timing summary for every corner. Put both,
   before and after, in the commit message. **Expect the SDRAM capture to
   move.** A new PLL output and 1,500 more ALMs reshuffle the fit, and
   `dram_dq -> dq_in` hold is the first thing to go negative. It did on the
   template's skeleton: -0.058 ns at fast 0C, fixed by re-balancing the
   SDRAM clock phase as the SDC describes (METHODOLOGY 5.20), not by touching
   the Analogizer. Moo Mesa kept +0.080 ns at the old phase; the Namco
   collection went to -0.011 ns and needed 5,990 -> 6,120 ps; S.T.U.N.
   Runner moved to 6,376 ps.

   **Before every push of RTL, run a Quartus map or compile**, even for a
   rewrite that only satisfies the linter: a lint fix (`-12'(dh)` for
   `12'(-dh)`) that Verilator accepted broke Quartus 18.1 in six repos at
   once, because it was pushed without a map. `12'd0 - 12'(dh)` satisfies
   both.
5. On hardware, `docs/bringup.md`'s "With an Analogizer" order: first with
   "Analogizer: Off" (the core must be exactly as before), then RGBS, then
   each mode, then SNAC, then that the menu remembers its settings across a
   reload and that changing one entry leaves the others alone, then the
   position sliders.

## 8. Release

Release the bitstream that was on the card when the owner confirmed it, not
a rebuild (`tools/cut-release.sh <tag> <bitstream.rbf_r>`). Bump
`"version"` **and** `"date_release"` in `core.json` together: updaters and
the openFPGA core library read both from the zip's `core.json`, not from
the tag, and fifteen Analogizer releases went out with the new version and
the old date, listed as weeks old until a patch release fixed the date.
The template's `cut-release.sh` refuses a `core.json` whose version is not
the tag or whose date is not today; a core with an older copy should take
that check. Release notes: Analogizer support, the modes, the sliders, any
menu entries removed to make room, and the hardware it was seen on.

## 9. Commit message

Say what was measured (the bench's lines, lint, the fit and timing numbers)
and what was **not**: no hardware, no CRT, SNAC protocols only as the
adapter's module implements them. If the core has no maintainer with an
adapter, the README says so too.
