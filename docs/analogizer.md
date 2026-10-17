# The Analogizer

[Analogizer](https://github.com/RndMnkIII/Analogizer) is RndMnkIII's adapter
for the Pocket's cartridge slot. It gives analog video out of a VGA connector
(RGBS, RGsB, YPbPr, Y/C, and a scandoubled RGBHV) and takes native controllers
through SNAC adapters. Its wiki is the authority on the adapter itself:
[specifications](https://github.com/RndMnkIII/Analogizer/wiki/Analogizer-Specifications),
[how to configure it](https://github.com/RndMnkIII/Analogizer/wiki/Supported-Cores-and-How-to-Configure-Them).

Every core built from this template supports it out of the box
(`USE_ANALOGIZER = 1` in `core_top.sv`). This page is what to change for your
board, what to tell the player, and what has been proven. A core's copy should
replace the template's numbers with its own; the places are marked **SET**.
For a core NOT built from this template, `docs/analogizer-retrofit.md` is the
step-by-step.

## For the player

**Settings are in the core's own menu**, under the game's other options,
like RndMnkIII's own "Pocket Menu" Analogizer cores (the wiki's list calls the
other kind, which reads a shared `analogizer.bin`, "Analogizer File"; a core
from this template does not read that file). The Pocket remembers them per
core.

| entry | options |
|---|---|
| Analogizer | Off (the default), On, On, Pocket off (the picture goes to the CRT only) |
| Analogizer Video | RGBS, RGsB, YPbPr, Y/C NTSC, Y/C PAL, Scandoubler, Scandoubler 25% / 50% / 75%, Scandoubler HQ2x |
| SNAC Adapter | None, DB15, NES, SNES, PCE 2-button, PCE 6-button, PCE Multitap, DB15 Fast, SNES A,B<->X,Y, PSX Digital, PSX Digital Fast, PSX Analog, PSX Analog Fast |
| SNAC Assignment | the six below |
| Analogizer H Position | ±16 dots in the skeleton (**SET** from the core's blanking); + moves the picture right |
| Analogizer V Position | ±2 lines in the skeleton (**SET**); + moves the picture down |
| Analogizer H Size | optional, for a core with menu room (the skeleton has none): percent, + wider; 15 kHz modes only |

With **Analogizer** off the core behaves exactly as it did without Analogizer
support. The adapter itself is set up as its wiki's
[How to use it](https://github.com/RndMnkIII/Analogizer/wiki/How-to-use-it%3F)
says: SNAC switch in position A, 5 V into its USB-C port, the SCART cable's
audio jack in the Pocket's headphone socket.

**Width.** An optional third slider, "Analogizer H Size", makes the
15 kHz picture narrower or wider about its centre, in percent. A CRT has no
digital width: the picture is as wide as its dots take to draw, so the
core plays each line back a little faster or slower. Many consumer sets
have no width control at all, and on a set stood on its side for a
vertical game the width is the game's height. There is no vertical
equivalent: a CRT's height is its sweep, and scaling lines would double
or drop whole scanlines. The scandoubler modes are left alone (a VGA
monitor has its own width control).

**Position.** The two sliders move the picture on the CRT, in the core's
own dots and lines, for a set whose picture sits off centre (the first one
tried with Moo Mesa showed it about 10 lines high). They move the syncs,
not the picture, so nothing is cropped and every mode follows; the size is
still the set's to adjust. 0 is the board's own timing.

**Video.** The core sends the board's own signal, at the board's own line
and frame rate -- the timing a 15 kHz arcade monitor or a PVM expects. (**SET**
the numbers in the core's copy: the skeleton's is 320 × 224 visible, 452 × 253
dots at 6.857 MHz, 15.17 kHz, 59.96 Hz.)

| mode | SOG switch | notes |
|---|---|---|
| RGBS | off | VGA-to-SCART or VGA-to-BNC |
| RGsB | on | R2/R3 adapters only |
| YPbPr | on | R2/R3 adapters only |
| Y/C NTSC, Y/C PAL | off | needs an active Y/C adapter on the VGA port |
| SC 0% / 25% / 50% / 75% / HQ2x | off | scandoubled for a VGA monitor: twice the line rate |

"On, Pocket off" turns the Pocket's own picture black while the CRT keeps
it.

**A board that is not 15 kHz.** Some boards drew a medium-resolution (25 kHz)
or VGA-rate (31 kHz) picture. Sent as it is, a 15 kHz monitor shows it as two
images side by side (Xenophobe, 31 kHz) or as a stack of overlapping copies
(Atari System 2, 25 kHz: seven). Such a core converts it (`ana_15k.sv`,
below): each CRT line is the average of two of the game's lines, progressive,
locked to the game's frame so nothing is dropped or torn, at half the game's
lines (240p from 480, 192p from 384). Its "Analogizer" list then reads Off /
On / On, Sharp / On, Pocket off / On, Sharp, Pocket off; Sharp shows each
pair's even line instead of the blend. An interlaced picture would keep every
line but flickers on a PVM; owners asked for the blend.

**Controllers.** SNAC pads (DB15, NES, SNES, PC Engine 2/6-button and
multitap, PlayStation) replace the Pocket's controls according to the
**SNAC Assignment** chosen in the menu:

| assignment | player 1 | player 2 | player 3 | player 4 |
|---|---|---|---|---|
| SNAC P1 → Pocket P1 | SNAC 1 | the Pocket's own controls | dock 3 | dock 4 |
| SNAC P1 → Pocket P2 | Pocket | SNAC 1 | dock 3 | dock 4 |
| SNAC P1,P2 → P1,P2 | SNAC 1 | SNAC 2 | dock 3 | dock 4 |
| SNAC P1,P2 → P2,P1 | SNAC 2 | SNAC 1 | dock 3 | dock 4 |
| SNAC P1,P2 → P3,P4 | Pocket | dock 2 | SNAC 1 | SNAC 2 |
| SNAC P1-P4 → P1-P4 | SNAC 1 | SNAC 2 | SNAC 3 | SNAC 4 |

Four SNAC players need the PC Engine multitap. A pad's buttons arrive as the
Pocket's own (SNAC's A is the Pocket's A, and so on), so they do whatever the
core maps those to. A PlayStation pad in analog mode steers with its left
stick.

**Cart power is on for everyone.** `core.json` declares the cartridge adapter,
so the Pocket powers the slot whether or not an Analogizer is in it. Do not
leave a game cartridge in the slot while this core runs.

Say in the core's README whether it has been tried on an Analogizer. What
the bench proves is listed under *What was measured* below. Send problems with
the adapter itself to the Analogizer project.

## For the developer

### The pieces

| file | what |
|---|---|
| `target/pocket/analogizer/` | RndMnkIII's `openFPGA_Pocket_Analogizer` and what it instantiates, **verbatim** but for the `USE_YC`/`USE_SD` switches, a marked local change (modules/VENDOR.md has the commit and the change). Its `analogizer.qip` is ours: only what is used. |
| `target/pocket/pocket_analogizer.sv` | the wrapper: clock hand-over, Y/C constants, SNAC → controller words. Core-agnostic; the same file in the template. |
| `target/pocket/core_top.sv` | `USE_ANALOGIZER`, the instance (after the bring-up panel; **SET** its `LINE_LEN`), `key1..key4` in place of `cont1..4_key`, the bridge read at `0xF7xxxxxx`, the Pocket-screen blank, and the cart pins' idle levels when it is off. |
| `core_pll` `outclk_4` | the Analogizer's 48 MHz, `clk_sys / 2` in phase; in the SDC's PLL group. |
| `pkg/.../interact.json` | the entries above: ids 70–73, each a masked field of the word at `0xF7000000`, and 74–75, signed sliders at `0xF7000004` and `0xF7000008` (**SET** their range). The enable and the Pocket-screen blank share one entry: with the skeleton's bring-up entries the menu is at Analogue's limit of 16. The firmware has a second, smaller limit on options, below |
| `pkg/.../core.json` | `"cartridge_adapter": 0` (powers the slot) |
| `sim/run_analogizer.sh` | the bench (below); **SET** the raster at the top of `sim/tb_analogizer.sv` |
| `target/pocket/ana_15k.sv` | not used by the skeleton: the 15 kHz converter for a 25 or 31 kHz board (below); `sim/run_ana15k.sh` is its bench |
| `tools/check_json.py` | fails if an entry writes outside its mask, none sets the enable, a position slider is not signed within ±127, a data slot also writes `0xF7000000`, the slot is not powered, or the menu has more options than the firmware takes |

### The settings word

One 32-bit word at `0xF7000000`, the layout RndMnkIII's adapter module (1.4)
decodes. Each menu entry is a list with a mask that keeps every bit but its
own field (or fields), so the four entries share the word:

| bits | field | values |
|---|---|---|
| 4:0 | SNAC type | 0 none, 1 DB15, 2 NES, 3 SNES, 4 PCE 2-button, 5 PCE 6-button, 6 PCE multitap, 9 DB15 fast, 0xB SNES A/B↔X/Y, 0xC–0xF PS/2 keyboard (+ pad; not in the menu, the wrapper does not wire the keyboard out), 0x10/0x11 PSX digital (125/250 kHz), 0x12/0x13 PSX analog. 16 and up select the adapter's B wiring. |
| 5 | enable | 0: the port stays idle and nothing else applies |
| 9:6 | SNAC assignment | 0–5 as in the table above |
| 13:10 | video | 0 RGBS, 1 RGsB, 2 YPbPr, 3 Y/C NTSC, 4 Y/C PAL, 5–9 scandoubler 0/25/50/75%/HQ2x |
| 14 | blank the Pocket screen | |
| 15 | OSD on the Analogizer output | not used by the template; no menu entry |

**Read-back.** The word is written as a number (the adapter module is told
`bridge_endian_little = 1`, so it does not byte-swap it as it would a file),
and `pocket_analogizer` keeps its own copy to read back, combinationally.
The Pocket's bridge (`io_bridge_peripheral.sv`) samples read data four clocks
after it presents the address and pulses `bridge_rd` only afterwards; the
adapter module updates its read-back on that pulse, so it would hand back
the *previous* read's value. The firmware merges a masked entry by
reading the word back (Analogue's interact.json docs: every entry not
`writeonly` is read back every frame), so that stale value would wipe the
other fields: in the bench, choosing a video mode turned the Analogizer off. RndMnkIII's menu
cores (Gauntlet) read the word back the same way, from a register.

**Picture position.** Two more words, each a whole signed slider value
(no mask): `0xF7000004` horizontal in dots, + right, and `0xF7000008`
vertical in lines, + down. `pocket_analogizer` reads the low 8 bits and
reads both words back. The adapter module stores them in a table it never
reads (`config_mem`). They move the syncs, not the picture: hsync n dots
earlier puts the picture n dots right, vsync n lines earlier puts it n
lines down. Earlier is built as a line (or frame) less n later: each sync
is re-made from the source's own rising edge after a delay counted in
dots, as wide as the source's, with the line and frame measured from the
source's syncs; the vsync's delay is whole lines, so its edges keep their
place in the line. RGB and blanking go through one clock later with them,
and at 0 each sync passes straight through.

A re-made sync starts only once it has been off at least as long as it is
on. The adapter module's `sync_fix` decides each sync's polarity afresh
every period, by whether the signal was high longer than low. A jump
between settings in one write (one "large" slider step, or a value loaded
at start) can put the next pulse just after the last one ends, and that
period reads as active-low: csync turned inside out for a frame (a line,
for hsync). With the rule such a jump skips one pulse instead.

**SET the range from the core's blanking.** Moving right, hsync may come
earlier until it meets the end of the picture; moving left, it may come
later until the Y/C colour burst, which ends about 3.5 µs after hsync
does (28 dots at 8 MHz), would reach the picture. Vsync may move either
way until it reaches a picture line. The skeleton's raster leaves 24 dots
before hsync and 2 lines before vsync, hence ±16 and ±2; Moo Mesa's gives
±24 and ±16. `sim/run_analogizer.sh` tries both ends of the range in
`interact.json` and fails if csync is low while a dot is drawn.

**Picture width.** `0xF700000C`, a signed slider in percent, scales the
15 kHz picture's width about its centre (`pocket_analogizer`'s width
stage). Each line's dots go into a two-line buffer, six bits a channel,
and the line before is read back during this one, `A × (100 + n) / 100`
clocks long where it was `A`, starting so its centre stays put: nearest
dot, the index advancing by `dots / clocks` (20 fractional bits, from a
divider run once a line) every clock. A dot is held `floor` or `ceil` of
its new length, so at 48 MHz and 8 MHz dots a 10% stretch holds them 6 or 7
clocks. All of a line's measures are the line before's. The picture comes
a line late, so vblank does too and the position stage delays vsync by a
line to match; the picture stays exactly where it was. Off (0), or in a
scandoubler mode, everything passes through as before.

The adapter module takes colour, blanks and syncs only on the *rising edge*
of its pixel enable (`openFPGA_Pocket_Analogizer.v`, "Fix video"). Fed the
source's enable, the scaled picture snapped back to the source's dots: the
bench measured every dot held 7 clocks at ±10%. Scaled, the wrapper makes
its own enable instead: a one-clock pulse whenever the dot, a blank or a
sync changes, delayed a clock if it would follow another directly so the
edge is still there. The bench now sees the 7/8 and 6/7 holds asked for.

A stretched line may run past the source's own next hsync (H Position can
have moved the output's later), so the read finishes the line from the
buffer and vblank latched at its start.

**Never into a sync.** Where H Position and H Size together would put
picture on hsync or on the colour burst after it, the wrapper crops the
picture's edge instead (`KEEP_CB`, from the previous line's hsync), so the
set never loses sync; a player sees an edge go missing and backs off.

**SET the width range from the blanking** with the picture centred: the
wider picture grows into both porches by half the increase, and a player
centres it with H Position first. The room is the line's whole free
blanking (less hsync and the burst), not just the shorter porch. The bench
centres the picture with H Position the way a player would (clamped to the
menu's range), tries both ends of the width range there (±10% where the
menu has no width entry) and fails if a line is the wrong length, off
centre, missing or reordering dots, a dot is held the wrong time, or the
picture moves vertically; then, at the largest width with H Position at
either end, it fails if csync is ever low while a dot is drawn or the
picture starts inside the colour burst.

**The file scheme, not used here.** The adapter module 1.4 was written for
`analogizer.bin`, a file Pupdate and AnalogizerConfigurator write to
`/Assets/analogizer/common/`, loaded through a data slot at the same address.
It needs a data slot naming the file, a second platform id `analogizer`
that the slot's parameters point at, and the file on the card before the
adapter does anything. A player who has never heard of the file has an
Analogizer that stays dark, so the template uses the menu. A data slot at
`0xF7000000` would load the file over the menu's word; `tools/check_json.py`
refuses one.

### The menu's size: "Error in interact"

Analogue documents 16 entries (20 with the data slots). The firmware has a
second limit on the options in the lists, and a core over it does not load:
the Pocket says "Error in interact" (then "error in core setup"). Measured on
hardware with these cores: Atari System 2 at 70 options and BBC Micro at 77
were refused; both load at 64; MSX2 loads at 68 options (80 options and
entries together). `tools/check_json.py` fails above 68 options or 80
options plus entries, the largest known to load. The Analogizer's four lists
are 32 options of that.

To make room, cut in this order, asking the core's owner each time:

1. the Analogizer lists' rarely used options: Y/C PAL, DB15 Fast, the PCE
   2/6-button and SNES A,B<->X,Y variants, the PSX Fast variants, the
   scandoubler's 25/50/75% (the template's lists are complete; trim a core's
   copy, keeping each option's value);
2. the core's own display extras the CRT makes redundant: Scanlines, Shadow
   Mask;
3. DIP switches nobody changes (demo sounds, a copyright notice, a
   difficulty-adjacent setting the owner names), left at their defaults;
4. "SNAC Assignment", for a core with one player (BBC Micro).

Compact the file's layout too (one option to a line): Atari System 2's
11,568-byte file loads, and `check_json.py`'s size limit is that.

### A board that is not 15 kHz: `ana_15k.sv`

The adapter passes the core's line rate through in every mode but the
scandoubler, and a 15 kHz set cannot show 25 or 31 kHz (above, *For the
player*). Note that the 31 kHz picture is *already* what the scandoubler
modes make for a VGA monitor, and 15 kHz is what owners of PVMs and arcade
monitors bought the adapter for.

`target/pocket/ana_15k.sv` makes a 15 kHz picture of half the source's lines.
Output line j shows source lines 2j and 2j+1, blended ((a + b) >> 1 a
channel, top 6 bits) or the even one alone ("Sharp"), its dots played out at
`DOT` clocks each so the picture keeps its shape. The output frame restarts
`DELAY` clocks after the source's first visible line, every frame, and its
lines add up to exactly the source frame (each line's last dot, deep in the
back porch, takes the spare clocks, spread a clock at a time), so it never
drops, repeats or tears a frame. Pairs wait in a ring the output reads. Two
boards shipped with it:

| | Atari System 2 (the defaults) | Xenophobe |
|---|---|---|
| source | 512 × 384 of 640 × 416, 6 clocks a dot (96 MHz), 25.0 kHz | 512 × 480 of 635 × 525, 2 clocks a dot (40 MHz), 31.5 kHz |
| output | 192p: `DOT` 10, `DOTS` 609, `LINES` 262; 15.75 kHz, 60.1 Hz | 240p: `DOT` 4, `DOTS` 636, `LINES` 262; 15.72 kHz, 60 Hz |
| `HS0`/`HS1`, `VS0`/`VS1` | 524/569, 219/222 | 527/574, 243/246 |
| `RING`, `DELAY` | 48 pairs (a pair, 80 µs, is longer than an output line, so the output starts late and catches up), 336,000 | 2 (a pair takes about as long as a line), 1,400 |
| `SRC_FRAME` | 1,597,440 | 666,750 |

For a new board:

1. Choose `DOT` so `DOTS × DOT` is close to `SRC_FRAME / LINES` (the line's
   clocks) with `DOTS` near the source's horizontal total times the source's
   clocks a dot over `DOT` (the same shape), and `LINES` 262 for 60 Hz.
   `HS0`..`HS1` is 4.7 µs a few dots after the picture; `VS0` a few lines
   after the last picture line (`SH / 2`), 3 lines long.
2. Add the board's line to `CONFIGS` in `sim/run_ana15k.sh` and run it. It
   checks every dot of six frames against its pair (Blend and Sharp), every
   line's length, vsync's line and the frame period, and every ring read,
   then prints the window `DELAY` may take. Set `DELAY` near its middle; the
   script reruns a line outside each side and fails if either passes.
3. Add `ana_15k.sv` to `core.qip` (the skeleton does not build it), and
   instance it on the core's clock, fed the picture as the Pocket gets it
   (`src_ce` the dot enable, `src_rgb`, `src_hb`, `src_vb`), and give its
   outputs to `pocket_analogizer` as the source: `clk_src` the same clock,
   `src_pix_ce = o_ce`, `src_hs/vs/hb/vb = o_*`, `LINE_LEN = DOTS`. The
   adapter clock stays near 48 MHz (Atari System 2: `clk_sys / 2`, the
   template's arrangement; Xenophobe: its 40 MHz `clk_sys` as both clocks
   with `SAME_CLK = 1` and `PIX_LAG = 1`, because its converter's 10 MHz
   dots come faster than the toggle hand-over takes).
4. Sharp: give the "Analogizer" list two more options with bit 16 set
   (`0x10020`, `0x14020`) and the mask `0xFFFEBFDF`. The adapter module
   ignores bit 16; decode it from the bridge write in `core_top`:

   ```verilog
   reg sharp_74 = 1'b0;     // "On, Sharp": bit 16 with the enable (bit 5)
   always @(posedge clk_74a)
       if (bridge_wr && bridge_addr == 32'hF7000000)
           sharp_74 <= bridge_wr_data[16] && bridge_wr_data[5];
   ```
   `ana_15k` synchronises `sharp` itself. (Xenophobe, which had a spare
   menu entry, has "Analogizer Lines: Blend / Sharp" instead; bit 16 costs
   no entry.)
5. Set the position sliders' range from the *converter's* blanking (Atari
   System 2: H -5..+12 dots, V -40..+27 lines), and the bench raster in
   `tb_analogizer.sv` to the converter's output.
6. Y/C becomes usable (the picture is now 15 kHz); the scandoubler modes
   double the converted picture to 31 kHz, which a VGA monitor takes.

Cost: the ring is `RING × 512 × 18` bits for a 512-dot line, so Atari
System 2's 48 pairs are 442 kbit, about 44 M10K blocks, and Xenophobe's two
pairs 2; the one-line buffer is 2 more. A board whose pair takes longer than an
output line needs about `SH/2 × (1 − 63.5 µs / pair time)` pairs.

### Fitting it: `USE_YC` and `USE_SD`

The adapter module has no switches, so this template's copy of
`openFPGA_Pocket_Analogizer.v` has two, `USE_YC` and `USE_SD` (default 1), a
local change marked LOCAL in it and recorded in `modules/VENDOR.md`.
`USE_YC = 0` leaves out `yc_out_legacy`; `USE_SD = 0` leaves out
`scandoubler_2` (and the `Hq2x` inside it) and `scanlines_analogizer`.
Their outputs are tied to the pass-through values and the video-type
selector maps their modes (3–4, 5–9) to RGBS, so RGBS, RGsB and YPbPr take
exactly the paths they did. With both at 1 the file builds exactly
RndMnkIII's 1.4. `pocket_analogizer` forwards both. Take the dropped modes
out of the core's "Analogizer Video" list. S.T.U.N. Runner needed 102% of
the FPGA with the whole module and fits with both at 0 (Gaiapolis and
Master of Weapon too); the scandoubler with HQ2x is the large part.

### Clocks

`openFPGA_Pocket_Analogizer` runs its logic on `i_clk`, puts `video_clk` on the
cartridge pin that clocks the ADV7123, and assumes that is `i_clk` too. The
scandoubler halves the pixel period, so the clock has to be at least four
times the dot rate. The shipped Analogizer cores use 42.95–48 MHz. The
template's system clock is 96 MHz, which is more than the cart's level
translators have been asked to pass, so the PLL's spare output gives 48 MHz,
in phase with `clk_sys`. `pocket_analogizer` takes each pixel `PIX_LAG` (2)
system clocks after the dot enable into a holding register and hands it over
with a toggle. The Analogizer side picks it up two or three of its clocks
later, well inside the dot. A core whose `clk_sys` is already 40–50 MHz can
pass `clk_sys` as both clocks, and should set `SAME_CLK = 1` if its dots come
faster than a quarter of that clock (the toggle cannot keep up): the pixel is
then taken directly, `PIX_LAG` clocks after its enable. A core with an unrelated video clock can too,
because the hand-over is a proper synchroniser, but the SDC then needs the two
in separate asynchronous groups.

The Y/C encoder's subcarrier step and colour-burst window are computed in
integers from `CLK_HZ`. The reals used elsewhere lose the bits past 32 in some
tools, and MSX2's hand-typed NTSC step is a few counts off.

### Using SNAC in the game's inputs

`pocket_analogizer` outputs `key1..key4`, the Pocket's controller words with
SNAC pads put in place by the assignment. SNAC's bit order is the Pocket's
(0 up, 1 down, 2 left, 3 right, 4 A, 5 B, 6 X, 7 Y, 8 L1, 9 R1, … 14 select,
15 start). They feed the `gamepad` helper and the direct player-3/4 reads in
place of `cont1..4_key`. **Wherever a core reads `cont*_key` directly**
(players 3 and 4 often are), read `key*` instead, or SNAC will not reach it.

### What was measured

- `sim/run_analogizer.sh`: the wrapper and the vendored module at the
  skeleton's raster and clocks, read at the cartridge pins as the DAC reads
  them. It passes at both the skeleton's raster (7 Analogizer clocks a dot)
  and Moo Mesa's (512 × 264, 6 clocks a dot), where it was first written.
  - With the menu at its defaults, every pin sits as on a core without the
    adapter, and the controller words pass through.
  - Every option of every Analogizer entry in the package's `interact.json`
    (32), set as the firmware sets a masked entry, read back the word as the
    bridge samples it, merged and written: the word, the adapter's copy and
    the enable each followed. With the adapter's own read-back in place of
    the wrapper's, the same run fails at the second entry.
  - RGBS: all 71,680 visible dots of a frame reach the DAC pins, in raster
    order, as their top six bits per channel, with 0 differing. Csync is one
    hsync-long pulse a line.
  - Scandoubler: 506 lines per frame (twice 253) at 1582 clocks, half the
    core's line.
  - YPbPr and Y/C NTSC/PAL: no unknown on any pin for a frame.
  - All six SNAC assignments, the analog stick, and type "none" map as
    tabled.
  - Position, at both ends of the shipped sliders: read back as written,
    the settings word untouched; at the pins csync moves by exactly the
    dots (in clocks) and lines asked, the picture is still every dot with
    0 differing, csync is never low while a dot is drawn, and the
    scandoubler's lines and period are unchanged; back at 0, csync is
    where it started. A jump written just after a pulse that puts the next
    right after it (V +2 to -2 here; first seen failing in this bench, a
    frame of inverted csync) leaves csync out of the picture for three
    frames.
  - Width, at +10% and -10% (no entry in the skeleton's menu), centred by
    H Position -13: 224 lines of 2,465 and 2,017 clocks (asked 2,464 and
    2,016), started 111 and 113 clocks earlier and later, centred to the
    clock; every dot from the
    first to the last in order, held 7 or 8 (6 or 7) clocks; the lines as
    far from vsync as at 0; scandoubler unchanged; at 0 exactly as before.
    At +10% with H Position at +16 and -16, csync is never low in the
    picture and the burst is clear. Without the vsync's line of delay, the
    picture comes a line low and the bench fails; with the source's pixel
    enable in place of the wrapper's, every dot is held 7 clocks and it
    fails; at +40% the corners stay clean with the crop and fail without
    it (csync low for 25,312 clocks of picture).
  - The blank bit, and enable off again returning the port to idle.
- `sim/run_ana15k.sh`: the converter at Atari System 2's and Xenophobe's
  parameters, every dot of six frames against its pair (Blend and Sharp,
  0 differ), every hsync period one of the two lengths with exactly the
  long ones a frame needs, vsync on its line, the frame period the
  source's, and every ring read the right pair; a `DELAY` a line outside
  the measured window on either side fails. Its Quartus 18.1 parse was
  checked inside Atari System 2 (`./build-local.sh map`).
- `sim/lint.sh`: the wrapper lints clean, as built and with `SAME_CLK`,
  `USE_YC = 0` and `USE_SD = 0`; so does `ana_15k`. The vendored files' warnings are
  dropped by path; their errors are not.
- Quartus: Moo Mesa compiles and closes timing with it, at a cost of 1,550
  ALMs, 13 RAM blocks and 2 DSP blocks. The template's own build is in the
  commit that added this.

**On hardware** (2026-10, one owner, a PVM): sixteen of plasticbugs' cores
carry this wrapper, retrofitted from this template, and all show their
picture on the PVM: Moo Mesa, NBA Jam, the Namco collection, Punch-Out!!
(its lower screen, the upper one filling the Pocket), Time Pilot, Time
Pilot '84, Cadash, BBC Micro, Smash T.V., Cloak & Dagger, S.T.U.N. Runner
(`USE_YC = USE_SD = 0`), Xenophobe (240p), Gaiapolis, Pleiads, Master of
Weapon and Atari System 2 (192p). A SNES pad over SNAC works in them. The
H Size slider shipped on the vertical games (Namco, the Time Pilots,
Cloak & Dagger).

**Not proven:** the template's skeleton itself on hardware; the SNAC
protocols other than SNES, which are the adapter module's and are forced
at its outputs in the bench rather than driven over the pins; the Y/C and
YPbPr encodings, which have no reference to compare against, only a run
without unknowns.

### Turning it off

Set `USE_ANALOGIZER = 0` in `core_top.sv`, remove `general[4]` from the PLL
group in the SDC (it would match nothing), and take the six menu entries
and `cartridge_adapter: 0` out of the JSON.
