# Building an arcade-accurate openFPGA core

Method, tooling and hard-won lessons from the Analogue Pocket cores listed below.
Everything here was learned by doing it and getting it wrong first; the
sections marked **cost me time** are the ones worth reading twice.

The core names in brackets are where a lesson was paid for, and are left as
they are — a claim about what happened is worth less without the thing it
happened to. The template's `tools/init_core.py` deliberately does not rename
them.

* **Xenophobe** (Midway MCR, 68000) — the original document.
* **Time Pilot**, **Gaiapolis**, **Cadash** — along the way.
* **Pleiads / Phoenix** (Amstar, 8085, discrete sound) — §5.8 onward, and the
  recipes and list items marked the same way. Two games in one core, told
  apart by a checksum, which is how §5.8 came to be written.
* **Master of Weapon** (Taito B System: 68000, Z80, YM2203, TC0180VCU) —
  §5.16 onward. Its simulation was green for days before it met a Pocket, and
  its first four hardware runs found four faults no bench had shown. Those
  sections are about that gap, and the template was cut from it afterwards.
* **BBC Micro** — §5.23: a picture that alternated between frames, and the
  ghost it left on a Pocket's OLED.
* **Punch-Out!!** and **NBA Jam / Tournament Edition** (Midway T-unit:
  TMS34010, blitter, 6809 ADPCM sound board) — §5.24 onward: save RAM, a
  self-test that overwrote the program it was meant to protect, several games
  in one core, and the memory speed limits the Pocket imposes that no
  simulation shows.

---

## 1. The central idea

Three artefacts, in this order. Each one makes the next cheaper.

**MAME is the oracle.** Not a reference to read — a program to interrogate. Its
Lua interface can tap memory writes, force inputs, dump RAM, record audio and
snapshot frames. Nearly every question about "what does the real hardware do
here" is answerable in a few minutes with a Lua script, and the answer is
authoritative. Guessing instead is what cost me the most time on Xenophobe.

**A reference renderer is the executable spec.** Before writing video RTL, write
a Python program that reads a dumped machine state (VRAM, sprite RAM, palette)
and produces the exact frame MAME produces. Iterate until it is pixel-identical
on a spread of frames. Now you own a precise, readable statement of the video
hardware's semantics — priority rules, transparency, coordinate maths — and you
can consult it while writing RTL instead of re-deriving from MAME's C++.

**Frozen-state benches are the regression gate.** Load a dumped state directly
into the RTL's memories, render one frame in Verilator, diff against the
reference renderer. Roughly 30 seconds per run. Every video change gets checked
against a set of states before it goes near hardware. On Xenophobe this held at
zero differing pixels across seven states, including the heaviest sprite load
found in real play, and caught several "optimisations" that were wrong.

The pattern generalises: **make the correct answer cheap to compute, then check
against it constantly.**

---

## 2. Toolchain

| Tool | Role | Notes |
|---|---|---|
| MAME (`brew install mame`) | Oracle | `-video none -sound none -nothrottle -skip_gameinfo`, always `-cfg_directory`/`-nvram_directory` somewhere disposable, and the four flags below that keep it off the screen |
| MAME Lua (`-autoboot_script`) | Instrumentation | `install_write_tap`, `register_frame_done`, `ioport` fields, `machine.video:snapshot()`, `-wavwrite` |
| Verilator | RTL simulation | Fast enough for whole-frame and whole-second simulations |
| Quartus 18.1 in Docker | Synthesis | `raetro/quartus:pocket`, `--platform linux/amd64` on Apple silicon |
| Ghidra (optional, via MCP) | Disassembly | Only as far as needed to answer specific questions |
| Python 3 | Everything else | Reference renderer, image diffing, ROM building, audio analysis. No numpy needed |

**Keep MAME off the display** *(Master of Weapon)*. `-video none` stops MAME
rendering to a window but not creating one, and MAME's defaults are fullscreen
(`window 0`, `maximize 1`) — so on macOS the desktop jumps to another Space
every time a probe runs, which during a capture session is several times a
minute and lands on whatever the user was doing. Three measures, because they
fail independently:

```sh
SDL_VIDEODRIVER=dummy \            # SDL never opens the display; read before MAME parses anything
mame ... -videodriver dummy \      # the same instruction through MAME's own option
         -window -nomaximize       # and if a window appears anyway it steals no Space
```

Snapshots come out byte-identical, so nothing about the capture changes. Put
it in the wrapper script, not in each invocation, so no ad-hoc probe can
forget it.

Two Quartus habits worth keeping:

- `quartus_map` alone (~2 min) catches syntax and inference errors without a
  full fit. Run it before every push. I once pushed a "fix" that referenced a
  nonexistent bit and burned a CI cycle discovering it.
- The full compile runs in CI on every push. Builds take ~20 minutes, so treat
  a build as expensive and verify everything verifiable beforehand.

---

## 3. Workflow

**Phase 1 — map the hardware.** Read MAME's driver for memory maps, IRQ sources,
clock rates and input bit assignments. Write it into `docs/hardware.md` as you
go; you will consult it constantly. Record exact clock frequencies — they matter
more than you expect (see §5.3).

**Phase 2 — build the ROM path first.** Write the tool that turns the user's
MAME romset into whatever image the core loads, and verify each ROM's CRC while
doing it. Get this right early: every later test depends on having correct data
in the right place.

**Phase 3 — reference renderer.** Dump states from MAME with Lua, render them in
Python, diff against MAME's snapshots until pixel-identical. Expect to discover
non-obvious semantics here — Xenophobe's sprite priority turned out to be
first-wins per priority class, with pen 8 claiming a pixel invisibly, which no
amount of staring at RTL would have revealed.

**Phase 4 — RTL against the frozen bench.** Build the video core and check every
change against the reference renderer. Only then integrate into the platform.

**Phase 5 — full system.** Both CPUs, real memory paths, audio capture. Slower
(~20 min for a few hundred frames), so use it for integration questions, not
iteration.

**Phase 6 — hardware.** Reserve for faults that cannot be reproduced in
simulation. Add an on-screen diagnostic overlay before you need it.

---

## 4. Verification recipes

**Dump a machine state from MAME:**

```lua
local sp = manager.machine.devices[":maincpu"].spaces["program"]
local f = io.open("state.txt", "w")
f:write("VRAM\n")
for i = 0, 2047 do f:write(string.format("%04x\n", sp:read_u16(VRAM_BASE + i*2))) end
f:close()
manager.machine.video:snapshot()
```

**Drive the game to a specific situation** with `ioport` fields and a frame
counter — coin at frame N, start at N+20, and so on. This is how you reach
gameplay states worth capturing.

**Watch a value the CPU writes** with `install_write_tap` on the relevant range.
Note that a tap may not see accesses that go through an installed write handler;
if a tap comes back empty, instrument your own RTL instead.

**Compare audio against MAME** by sending the same sound command in both and
recording with `-wavwrite`. Compare peak, RMS and per-band energy. This is how I
proved our output was 6 dB low: same command, same window, ratio 2.06.

**Hold a CPU to MAME one bus transaction at a time** *(Pleiads/Phoenix)*. Log
every read and write — address, data, direction — from MAME with memory taps,
log the same from the RTL's bus strobe, and diff the two from reset. It needs no
test program and it localises a fault to the instruction that caused it: a
missing address line in the decode showed up as one write landing on the wrong
register at transaction 50,668. Check cycle counts separately, per instruction,
against the emulator's own table. Two things to know before trusting a
mismatch: MAME does not perform the operand reads of a conditional jump it does
not take, and its first frame starts at vblank rather than line 0. Anything the
CPU *polls* — a vblank bit, here — will eventually sample differently, and the
trace is only comparable up to there; say so in the bench rather than masking it.

**Compare audio where it sounds, with a metric that suits it** *(Pleiads/Phoenix)*.
Drive the game into play before recording; attract mode exercises a fraction of
the sound hardware. Then look at the whole capture second by second, not at one
window. Waveform correlation is the right measure when the CPU restarts the
oscillators on every note, because they stay phase-locked to the emulator's —
one game here held +1.0000 for twenty seconds. For anything free-running it is
the wrong one: two square-wave synthesisers with a sub-note timing offset are
spectrally identical and correlate at zero. Use band energy per second as a
ratio to the emulator, skip the seconds where the reference is silent, and
summarise as mean |log ratio| so that 0 means the same spectrum. See §5.9.

**Capture what the whole core does, not only what a block does when fed**
*(Pleiads/Phoenix)*. Give the system bench a mode that runs from reset, records
the core's own audio output, and logs the sound-command writes it makes in the
same format the emulator trace uses. Then the model can be run on *the core's
own commands* and compared sample for sample, with no dependence on the
emulator's recorded session matching yours. See §5.10.

**Diagnostic overlay on hardware:** a few rows of coloured squares on the bottom
scanlines, each a status bit, hidden behind a menu option. Cheap in logic, and
the only way to see inside a fault that only appears on real hardware.

---

## 5. Key learnings

### 5.1 Measure before you diagnose — and check the instrument

**Cost me time, repeatedly.** I announced confident causes three times on the
audio problem alone: bus contention, then downstream clipping, then a truncation
bug. Measurement killed all three. What eventually found it was one user
observation I could not explain away.

Worse, I once "fixed" a bug that existed only in my measurement harness:
Verilator exposes ports unsigned, so reading a signed 16-bit sample without a
cast made clean audio look railed and full of harmonics. **When a measurement
shows something shocking, suspect the harness first.**

Practical rules that emerged:

- A theory that explains only some of the observations is wrong, not incomplete.
- If a change is meant to fix something, predict the measurement it should move,
  and check that specific number.
- State plainly when you cannot reproduce something. Shipping a speculative fix
  costs the user a build cycle and teaches you nothing.

### 5.2 Budget bandwidth explicitly

Write down the cycle budget per scanline and what consumes it. On Xenophobe:
1270 clocks per line; a full sprite-table scan cost 512 of them; each sprite cost
~75 more (38 fetch, 32 blend, ~5 attribute reads). That arithmetic said ~10
sprites per line, and sampling real gameplay in MAME found lines needing 17. The
mismatch *was* the flicker — the engine ran out of time, skipped starting the
next line, and rendered sprites on alternating lines.

Two fixes, both measurable: snapshot sprite RAM during vblank and record the
highest used entry so the scan stops there; and overlap each sprite's fetch with
the previous sprite's blend so cost becomes `max(38, 32)` rather than the sum.
Worst line went from 1270 clocks and overrunning to 807 with room spare.

**For Time Pilot this whole category likely disappears** — see §6.

### 5.3 Sound boards have no slack

The Sounds Good board has no timer. Its only interrupt is a command handshake,
so the sound CPU's *execution rate is the sample rate*: bandwidth it loses
becomes pitch and tempo error, directly. Ours ran ~20% slow because its ROM
fetches crossed SDRAM with wait states that real hardware does not have.

Two general lessons:

- **Find out what paces the audio.** If it is a timer, CPU speed only affects
  whether it keeps up. If it is the CPU itself, every stall is audible.
- Game logic is usually frame-locked to the video interrupt, so it tolerates
  stalls invisibly. Audio does not. A core can feel perfect and still have
  audibly wrong sound.

Fix was a small direct-mapped cache over the sound ROM — trivially safe because
the ROM is read-only, so entries can never go stale. Restored 99.6–99.9% of
hardware rate.

### 5.4 Clock domain crossings — the bug that hid from everything

**The most valuable lesson here.** Audio conditioning ran on the 40 MHz core
clock; the Pocket's audio filter runs on a PLL derived from `clk_74b`. The
16-bit sample bus crossed between them unsynchronised. The audio side could latch
a mix of old and new bits, and a torn 16-bit sample is not a small error — one
flipped high bit throws the value across the range. Heard as clicks and static.

It defeated every measurement because **both sides were individually correct**.
Our rendering matched MAME within a few percent across 8 seconds of music; the
mixer measured at unity gain with no saturation. The fault existed only in the
handoff, which no simulation of either side can show.

Most cores never hit this: their audio changes only at the sound chip's sample
rate, so the bus is still between updates. Ours carried a filtered value moving
every 40 MHz cycle — never stable.

```systemverilog
// sample at ~48 kHz, hold, hand over with a toggle flag
always_ff @(posedge clk_sys) begin
    snd_div <= snd_div + 1'd1;
    if (snd_div == DIV_48K) begin
        snd_div <= '0; snd_hold <= snd_pcm; snd_tog <= ~snd_tog;
    end
end
always_ff @(posedge clk_74b) begin
    snd_tog_s <= {snd_tog_s[1:0], snd_tog};
    if (snd_tog_s[2] != snd_tog_s[1]) snd_xfer <= snd_hold;  // stable by now
end
```

**Audit every multi-bit signal that crosses a clock domain, at the start.** For
Time Pilot the AY-3-8910 outputs will cross exactly this boundary.

### 5.5 openFPGA platform traps

**`input.json` does not mean what it looks like.** List *position* selects the
physical button, in the order **B, A, X** (Game Boy convention, not A first).
The `key` field does **not** choose the button — it names the `cont1_key` bit the
core reads when that button is pressed. So an entry declaring `pad_btn_x` in
position 2 is correct and deliberate: A sits in position 2 and asserts the bit
the gateware routes to that function. Reordering entries changes which pad does
what; changing a key changes which game input it drives.

**The Pocket persists a per-`id` remap** in
`/Settings/<core>/Input/_core/input_persist.json`, binding entry ids to physical
buttons. Reuse an id whose meaning changed and the saved file silently overrides
your defaults — buttons appear rotated. **Give entries fresh ids whenever the
layout changes.** This cost several rounds of confusing hardware testing.

**Valid keycodes** are `pad_btn_a/b/x/y`, `pad_trig_l/r`, `pad_btn_start`,
`pad_btn_select`. `pad_select` is not one; an invalid key silently does nothing.

**`info.txt`** drives the core's detail page: max 32 lines, plain characters,
`*` for bullets.

**The framework names pad buttons by position, not by number** *(Pleiads/Phoenix)*:
`m_btn1` is Y, `m_btn2` is B, `m_btn3` is A, `m_btn4` is X. Taking them in
numeric order puts fire on Y.

**The Pocket shows `core.json`'s `version`, not your tag.** It sat at 0.1.0
through three releases here. Have the release script refuse a tag that
disagrees with it.

**Artwork is two raw files** *(Pleiads/Phoenix)*: `Cores/<id>/icon.bin`, 36×36,
and `Platforms/_images/<platform>.bin`, 521×165. Both are 16 bits per pixel
with brightness in the first byte, and both are stored rotated a quarter turn,
so the file is height-wide and width-tall. The sizes are therefore exactly 2,592
and 171,930 bytes, which is a quick check that a file is what it claims to be;
decode it to a PNG and look at it before shipping it.

**The aspect ratio in `video.json` describes the raster before the scaler
rotates it** *(Master of Weapon; Time Pilot found it first)*. With a `rotation`
of 90 or 270 the shape that reaches the panel is `aspect_h:aspect_w`. A vertical
game written the intuitive way round, `3:4`, comes out landscape. A mode that
fills the Pocket's 10:9 panel is written `9:10`.

**Do not list the d-pad in `input.json`** *(Master of Weapon)*. The Pocket's
controls menu showed "Up" and three blank rows. The core reads the pad from
`cont1_key` whether or not it is listed; list only what is worth remapping.

**`pause_core` is not a reset** *(Master of Weapon and Cadash)*. It is the
Pocket's menu being open. ORed into the core's reset it holds the board in
reset for as long as the menu is up and boots the game from scratch when it
closes. Freeze the clock-enable divider instead and mask the CPU and sound
enables with the same term, so that no pulse is skipped and none fires twice
and a two-phase CPU resumes in the order it stopped; leave the dot divider
running and the picture stays up behind the menu. Note what else counts
wall-clock time while the CPU is stopped — a watchdog will expire.

**Every menu entry is a claim that the gateware does something**
*(Master of Weapon)*. The DIP bank was transcribed whole from MAME, including
Cabinet and Flip Screen, which on this board both come down to a video-chip
bit the core never implemented. Toggle each entry on hardware once and watch
for its effect; remove what has none, or what has one nobody holding a Pocket
wants.

**Copying to the SD card from macOS** *(Master of Weapon)*: use `cp -X` with
`COPYFILE_DISABLE=1`, or the card fills with `._*` AppleDouble files. If you
clean them up afterwards, name the files; a `find -delete` aimed at
`Platforms/` sweeps every other core's as well.

**Byte-enable inference:** partial-select writes like `mem[a][7:0] <= x` fail to
infer byte enables in Quartus and explode into registers. Use 2D-packed
(`logic [1:0][7:0]`) and word-buffered writes.

### 5.6 Release engineering

- **Release the bitstream you tested**, not a fresh compile of the same source.
  Quartus is not reproducible, and a rebuild is an unverified artefact.
  `tools/cut-release.sh <tag> <run-id>` pulls the bitstream from a named CI run
  and takes everything else from the working tree — which also means a
  definition-only change ships without a rebuild.
- **Never ship ROMs.** A gitignored test ROM in the package directory nearly went
  into a published zip; the release script's final check caught it. Exclude at
  the copy step *and* keep the check as a backstop.
- **Releases are immutable.** Tools track assets by tag; replacing a file leaves
  people holding a stale copy silently. Cut a new tag.
- Verify the published zip by downloading it: version, bitstream checksum, no
  ROM, expected files present.
- *(Pleiads/Phoenix)* **Anchor `.gitignore` patterns.** `pleiads/`, meant for
  the romset directory at the root, matches a directory of that name at *any*
  depth, and it swallowed the package's asset folder and both directories of
  captured reference states. CI failed or skipped for the project's first ten
  pushes as a result. Write `/pleiads/` and `/*.bin`.
- *(Master of Weapon)* **A rebuild is never byte-identical, even when the fit
  is.** The same container and the same source gave the same slack to three
  decimals on my machine and in CI, every time — and a different bitstream,
  because the framework stamps the date, the time and a random id into
  `build_id.mif` on every compile. So "CI rebuilt it and timing passed" is a
  twin of the binary you tested, not that binary. I released twins twice here;
  the first bullet of this section is still the right rule.
- *(Master of Weapon)* **Because the fit is deterministic, never push to find
  out whether timing closed.** A local compile answers the same question with
  the same numbers, and can be interrogated with `quartus_sta` afterwards.
  Eleven CI runs were spent learning what local builds would have said.
- *(Pleiads/Phoenix)* **Decide the pre-release flag from the tag**, not by
  hard-coding it. A script that always passes `--prerelease` is right until the
  first release that isn't one, and then mislabels it silently.

### 5.7 ROM distribution

A core is FPGA gateware — it cannot unzip a romset or run a script. The ROM must
be assembled on a computer. Ship an **MRA file** (the arcade standard, so
existing tools work) plus a dependency-free Python builder that reads the MAME
zip directly, checks each CRC, and verifies the finished image against a known
checksum.

**MRA's `map` attribute is read right to left** *(corrected after NBA Jam)*:
each digit is one byte of the output word, the **rightmost digit the word's
first byte**, and its value is the 1-based byte of the input part that lands
there, 0 for none. That is how mra-tools-c, the standard tool, reads it
(`get_pattern_from_map` walks the string from the end, and it sorts parts by
that position, so their order in the file does not matter).

This document used to say *left to right*, inferred from one MRA's `map="10"`
on an even-offset ROM, and every core built from it followed: its
`mra_build.py` read maps left to right and its `.mra` files were written to
match. Both agreed with each other, so every image verified -- and the
standard tool, which is what the people who build ROMs for the updaters use,
built a scrambled image from every core that interleaves (bytes reversed in
each word), with only an "md5 mismatch" warning. A user reported it; the fix
touched eleven cores.

- **Build the image with both tools** and require the same md5:
  `tools/check_mra.py <romdir>` does it for every `.mra`. An inference about
  a format is not the format; the other implementation is the check.
- **An `<interleave>` must fill the whole output word.** mra-tools-c has no
  padding: 32-bit words from three byte-wide ROMs are an error there
  ("interleaved group width do not match total bytes"), and a filler part
  inside an interleave cannot use `repeat`. Lay the image out so every byte of
  a word comes from a ROM (Smash TV's graphics words carry a zero byte, so its
  `.mra` still needs `mra_build.py`).
- **Merged romsets keep clones' same-named files in subdirectories** (MAME's
  `sldh`): `nbajamte.zip` holds the parent's `ug12` and, in `nbajamte4/`, the
  clone's. Pick files by CRC, not by bare name -- mra-tools-c tries the CRC
  first, and `mra_build.py` now does too. Test with a merged-style zip.
- `crc="a|b"` (either dump) is standard; `md5="a|b"` is not -- mra-tools-c
  warns on it, though it builds the right image.
- Name the output after `<setname>` (the standard tool does), and make those
  the names the core's instance JSONs give the updaters.

### 5.8 The bench must talk to the core the way the platform does

**Cost me the most on Pleiads/Phoenix, and hid behind a green everything.**
Two games shared one core, told apart by a checksum summed over the program
region as the ROM loaded. Every bench strobed each byte's write enable for one
clock. The Pocket's `data_io` holds it for four, with address and data stable
underneath. A RAM write repeated four times is harmless, so the image always
loaded and the picture was always perfect. A sum repeated four times is four
times the sum, and matched neither game.

On hardware, then, nothing was ever recognised. One game worked because
"unrecognised" happened to fall through to it. The other ran its program on the
wrong sound board — no music, only beeps — and I spent a day improving a sound
section that was correct and had never once been selected. Every hardware
report in that time was a report about a different circuit from the one I was
fixing.

What generalises:

- **The benches were exact about the machine and approximate about the
  platform boundary.** Make the bench's loader, reset sequencing and strobes
  match the framework's real timing by default — hold lengths, gaps, the order
  things deassert — and keep the idealised version as the override, not the
  other way round.
- **Ask of every signal crossing in from the platform: is what I do with it
  idempotent?** Writes are. Counters, checksums, toggles, FIFO pushes and
  edge-triggered state are not. Count an event on the strobe's rising edge or
  an address change, never on its level.
- **A fallback that is itself a valid configuration hides the failure that
  triggers it.** If detection can fail, make failure look like failure — a
  status bit on the overlay, a refusal to start — and test the detector at
  several strobe lengths, since the framework's is a parameter someone can
  change.
- **Before fixing what the hardware does, establish which configuration the
  hardware is in.** One overlay square for "game recognised" would have ended
  this in a minute.

### 5.9 A number is a claim about a window, and a metric is a choice

The first Phoenix release went out on a measured correlation of +0.889 against
MAME. It was taken over the first four seconds of the capture. The game starts
at 3.4 s. The figure described attract mode, the bench never looked past seven
seconds, and the in-game effects were at about a sixth of their proper energy.

Then, chasing that, waveform correlation sent me after the melody for most of a
day — it collapsed to zero mid-capture — when the melody was spectrally exact
and merely out of phase (§4). And when I finally wrote the per-second spectral
check into the bench, it printed a row that could not be true: RMS 2900, band
energy 1e-23. The band-energy function had always taken a single 8192-sample
frame from the *start* of whatever window it was handed. Every "4 s window"
figure in the project had covered 0.17 s.

- State the window with the number, every time. If it does not cover the thing
  the user will hear, it is not evidence about that thing.
- §5.1 says suspect the harness when a result is shocking. Suspect it also when
  a result is *reassuring* and cheap.
- When a bench gains a new check, run it on old known-good data first. An
  impossible row there is the fastest instrument audit there is.
- Keep a metric that makes the bad version look bad. Rebuild the previously
  shipped gateware from git and measure it with the final instrument: that gave
  0.883 → 0.050, and is the only before/after worth quoting.

### 5.10 A replayed trace proves the block, not the core — and only what the trace reached

Feeding a sound block the emulator's recorded command stream is the right way
to iterate on it. Know what it leaves unproven:

- **That the core issues those commands, and that the platform selects that
  block at all.** §5.8 is what that gap looks like. Close it with a whole-core
  capture (§4): the core's own command log matched MAME's to six significant
  figures in value and time, and its audio matched the model run on those
  commands, which is the check on the wiring rather than on the filter.
- **Anything the captured session never exercised.** One of the two effect
  generators sat at its "off" code for the entire twenty-second capture. Its
  sweep constants were computed for the wrong sample rate *and* paired with the
  wrong targets, and replaying that trace forever would never have shown it.
  List which inputs a capture actually moves, and treat the rest as unverified
  in writing until a capture moves them.
- **A script that defaults to one target verifies one target.** The end-to-end
  script defaulted to one game and I reported its result as covering both.
  Loop over every target by default; make the narrow run the option.

### 5.11 "Timing met" is a statement about the constraints

Sound generators that do a burst of wide arithmetic once per sample are a
legitimate multicycle. Two ways that went wrong, in opposite directions:

- **A constraint scoped to a module does not cover a path that starts outside
  it.** Three builds in a row failed on paths that entered the audio section
  from the core — a control latch into a counter, the game-select into a rate
  constant — matching neither end of `-from audio -to audio`. Register every
  input once at the boundary of the constrained region, so that what the SDC
  describes and what exists are the same set of paths.
- **Anything you later put inside that boundary inherits the relaxation.** A
  reverb whose state machine reads block RAM on consecutive clocks, placed in
  the audio module for tidiness, would have been given eight clocks per path,
  met timing on paper, and been free to fail on hardware. It went outside, and
  the clock-domain handover that has to follow it moved out too.

The analyser can only tell you the design meets what you told it. When a region
is relaxed, write down *why everything in it qualifies*, and re-read that before
adding to it. It is the same shape of fault as §5.4 and §5.8: every tool reports
success.

### 5.12 Read the emulator's step function, not the netlist's comments

Porting MAME's discrete-sound and helper layers, the mistakes were almost all
in what I assumed a macro meant:

- `DISCRETE_SWITCH(node, enable, switch, in0, in1)` is `switch ? in1 : in0`. I
  had an amplitude select backwards, halving the level where it should double.
- `DISCRETE_NOTE` does not count at all while its preload equals its maximum,
  so that code is *silence*, not the fastest tone. Both generators sit there
  for most of a game; running them anyway put 128× too much energy above 4 kHz.
- A resistor mixer is Millman **with the feedback resistor in the denominator**.
  Leaving it out is why I concluded the netlist's final gain "could not be
  reasoned about" and fitted one instead. The fit was 1.95× short, and being a
  fit it quietly absorbed the inverted switch above as well.
- Defaults are part of the semantics: a palette normaliser's range defaults made
  every colour a fifth too dark; a tile layout's bit offsets counted from the
  MSB, mirroring every tile while 89% of pixels still matched.
- A 555 is high for (R1+R2)/(R1+2·R2), never half; and resets — of capacitors,
  of filters — are to zero, not to the resting value.

**Derive, do not fit.** A fitted constant is a place for other errors to hide,
and it has to be refitted every time one of them is found. If the emulator
computes a level from component values, so can you.

And model by frequency only what is *heard* only as frequency. A 555 clocking a
divider can be a lookup table and a phase accumulator. The oscillators upstream
that shape its control voltage cannot, when the game switches their timing
capacitor ten times a second: the emulator carries the capacitor's voltage
across the switch and a phase accumulator carries the fraction of a cycle, which
is a different waveform every time.

### 5.13 Fixed point: five ways it lies without a warning

All of these linted clean, and none produced an error anywhere.

- **A small coefficient truncates to zero and the filter never moves.** A
  1 Hz oscillator stepping 5 ppm of the way to its rail per tick computes
  `(delta * k) >> 24` as 0, forever. Keep a residue accumulator and commit only
  whole units: `acc += delta * k; v += acc >> 24; acc &= mask`. Write each step
  as two branches with a non-negative difference so the residue never needs a
  sign.
- **`a + b * c >>> 8` is `(a + b * c) >>> 8`.** Shifts bind looser than
  addition in SystemVerilog. It turned an interpolator into a differentiator,
  and the only symptom was one source missing from a mix.
- **`4096 * 1000000` overflows 32 bits** in a constant expression and goes
  negative. Use sized 64-bit literals for anything rate-like.
- **Python's `//` floors; C's `/` truncates.** They differ for negatives, and
  it was the *reference model* that was wrong. When the two disagree, neither
  is presumed innocent.
- **A task with `inout` arguments silently dropped its results** in synthesis;
  a function returning a packed `{counter, level}` did not.

And on cost: `x / 48000`, `i % 6` and `sum / voices` each infer a real divider
— one was 14,335 logic elements. Multiply by a reciprocal, and **verify the
reciprocal exhaustively over the operand's real range**, not the range you
tested: one was exact to 699,119 and wrong above it, with live values reaching
1.5 million. When DSP blocks run out and logic is spare, `DSP_BLOCK_BALANCING`
per entity moved 79 blocks' worth of multipliers to 23.

### 5.14 A module proven in another core is proven on that core's signal

The cabinet reverb was ported from cores where it has shipped for months, with
a bit-exact integer model to hold the port to. It matched on every sample and
was wrong for this board: the mix carries a DC offset, as MAME's does, and a
feedback comb has a gain of 1/(1−g) at 0 Hz. Three combs turned −2118 into
−6431 and put one sample in eight into the rails on the louder game.

Bit-exactness proves the port, not the fit. When reusing a block, measure it on
*this* core's signal for the things its original host never presented — DC,
full-scale peaks, sample rate, duty — and count samples at the rails as
routinely as you count differing pixels. The fix kept the block's sound: remove
DC from the send into the combs only and leave the dry path alone. And make
"off" provably off — the input returned sample for sample, the whole core
byte-identical to a capture taken before the feature existed — so the option
can never be the reason the default sounds different.

### 5.15 Give the user ears, and take their words literally

Publishing the simulator's output where the user could play it turned out to be
a bisection tool, not a courtesy. "In the artifacts I hear the correct music",
next to "on the Pocket it is silent and then beeps", cut the problem in half in
one sentence: the sound section was right, so the fault was in whether the
hardware ever used it. A picture did the rest — the same gateware rendered with
and without the game-select, the second being exactly what the user had
described.

That description was precise, and I had been treating reports like it as
impressions. "No intro tune, silent, then just beeps" is not "the audio is
bad"; it names which generator is absent and which is present. §8 item 9 says
to believe the report. Also *parse* it.

### 5.16 The platform's memory glue is part of the machine, and needs its own bench *(Master of Weapon)*

**Cost me the first hardware run, and would have cost a week without a sibling
core to diff against.** The whole-machine bench answered the CPUs from plain
arrays after a settable delay. It booted, drew the attract mode and ran for
minutes. On the Pocket: a black screen, frame counter running.

The Pocket's loader sends a byte every eight clocks and *cannot be told to
wait*. The download path held one pending word; when an SDRAM write sat behind
a refresh, the even byte of the next word landed in the high half of the word
still waiting, and what finally went out was this word's low byte under the
next word's high one. The image came out peppered with bad words. §5.8 is the
same family — the bench idealised the platform boundary — but this is the
half it does not say: **a client that cannot stall needs a FIFO, and the bench
has to push at the client's real rate.** My first real-memory run passed,
because I had guessed twelve clocks a byte. At eight it crashed exactly as the
hardware did, down to the number on the diagnostic panel.

What generalises:

- **Keep two whole-machine benches.** The fast one with ideal memories, for the
  game; and one with the real memory module, the real SDRAM controller and SRAM
  port, and behavioural chips beyond the pins, with the image sent through the
  download port. The second is slow. It is also the only simulation in which
  the arbitration, the download and the refresh exist at all.
- **Everything between the core's ports and the pins is unverified until that
  second bench exists.** Say so in the README rather than "the machine boots".
- **When a working sibling core exists, diff the platform layer against it
  before theorising.** The fault, the fix and a paragraph explaining both were
  sitting in the Cadash core's memory module. I found them after three wrong
  theories and one remark from the user. `diff` first.
- **A family of cores shares its bugs.** Cadash had inherited its menu-reset
  bug from this core's `core_top`, and this core had been cut from Cadash's
  memory module before its download fix. When you fix something in a file that
  was copied, grep the siblings for the same line the same day.

### 5.17 A shared port's acknowledge must say whose it is *(Master of Weapon)*

Tilemap RAM was one SRAM port shared by the 68000 and the line renderer. The
port answered with a single ack pulse, decided the clock *before* it was
visible: it acknowledged only if the request still standing then was the one
it had begun. The arbiter routed that pulse by the request lines of the clock
it *arrived* in. When the renderer raised its request on the very clock a CPU
access was acknowledged, the renderer took the ack, and the CPU's word as its
tile code, and drew sixteen pixels of the wrong tile.

It needs the CPU writing tilemaps while lines are being built, so: never on the
title screen, only in play, on one raster line at a time, sliding along it, and
gone when the menu paused the CPU. That last observation, from the user, was
the whole diagnosis — it said "caused by CPU activity" in one sentence.

- **Route a response by who owned the resource when the response was decided**,
  not by who is asking when it arrives. Latch the owner at grant. An untagged
  pulse on a shared port is a race with a very small window, which is the worst
  kind: rare enough to pass every bench and common enough to see on a screen.
- **Count the coincidence in the bench.** A one-line checker — ack high, the
  other requester's line rising — found the race inside 200 frames of the
  quietest screen in the game. Add one for every shared port; zero is not the
  expected answer, surviving it is.
- **"It stops when X is paused" is a bisection.** Give the user a way to freeze
  half the machine (the menu pause does it for free) and ask what changes.

### 5.18 Prefer structures that can only be synthesised one way *(Master of Weapon)*

The two line buffers were `logic [11:0] linebuf [0:1][0:319]` — a
two-dimensional, non-power-of-two array, which became 7,000 flops, a 640-way
write decode and a read multiplexer that needed a multicycle to close. Every
bench drew it correctly. Timing analysis passed it. On the panel one of the two
buffers lost its writes in three 32-pixel blocks of the line, and stale pixels
from lines drawn earlier showed through on alternate raster lines.

I never proved why. The replacement was one 1024-entry RAM addressed
`{buffer, x}`, which Quartus infers as a block RAM and which fixed it outright.

- **A simulator indexes an array exactly as written; a synthesiser has to
  flatten it.** Give it nothing to decide: one dimension, a power of two deep,
  addresses built by concatenation. It is usually smaller and faster as well —
  this removed the slowest path in the video output.
- **When hardware and simulation disagree and the analyser is clean, replace
  the structure whose synthesis is an interpretation**, before instrumenting
  it. And write down that the root cause is unproven. A commit message that
  claims more than was shown is a trap for the next fault that looks similar.
- **A regular test pattern turns "garbled" into coordinates.** Two photographs
  of gameplay supported three different theories. The game's own service-mode
  crosshatch showed in one frame that the damage was in blocks 3, 6 and 9 of
  the line, in one buffer, and was *stale data* rather than shifted data —
  the white bar's pixels standing as comb teeth in cells the bar never touches.
  Ask for the test pattern first.

### 5.19 An instrument must survive the event it measures *(Master of Weapon)*

The line renderer reported how many clocks its slowest line took. It restarted
at every line start whether or not it had finished — and the restart reset the
counter. So a line that overran, the one case the number existed for, threw its
count away: the panel read a comfortable 321 over a striped picture, and 6,143
on another day. I built a theory on those two numbers and a fix on the theory.

- **A budget counter must saturate or latch on the miss**, not be cleared by
  it. Make "missed the deadline" its own sticky, unmistakable reading (all
  ones), and keep the worst case since reset, not since the last frame.
- **A deadline-driven stage should say when it misses**, not show what it has.
  An unfinished line went on screen looking like a rendering bug.
- Same family as §5.1: check the instrument. But the specific habit is new —
  *ask what the instrument does at the moment of the failure it is there to
  catch.*

### 5.20 Interface timing is a balance, and the report you did not read is the one that matters *(Master of Weapon)*

CI failed eleven times on setup slack. I spent most of them pipelining
arithmetic in the sprite engine, because that is where the failing paths had
been at the start. By the end every violated path was the same one: the SDRAM
data pins into the controller's capture register. The logic had been closing
for days.

- **Re-read the worst paths after every fix.** The list changes character, and
  the summary line does not tell you.
- **A source-synchronous capture is a dial, not a path.** Setup on the SDRAM
  read gets `2T - shift` and hold gets `T - shift`: a nanosecond off the clock
  phase is a nanosecond onto one and off the other. Measure both slacks at two
  phase values, at the corner where each is worst (slow for setup, *fast* for
  hold), solve for where they meet, and round to a step the PLL can make. I
  moved it on a setup measurement alone, reasoned that hold was safe, and
  bought a hold violation and a wasted build. A phase value inherited from
  another core is a starting point; the board is the same but the fit is not.
- **Make the report script emit every corner it will ever be asked about.**
  Mine matched the cold corner with `*0C*`, which also matches the *fast* 0C
  model; that ran second and overwrote the file with paths that were never the
  problem. It reported hold on the slow model only, where hold is never worst.
  And CI uploaded one of the six files the script wrote.
- **Fail the build on an ignored constraint.** A multicycle aimed at a register
  that Quartus had merged into a block RAM's output matched nothing, was
  dropped with a warning nobody reads (332174 / 332049), and sat in the SDC for
  weeks claiming a relaxation the analyser never granted. Grep the fit and
  timing reports for those two warnings against your own SDC file and refuse
  the build. It is the converse of §5.11: there, the constraint covered more
  than you meant; here, it covered nothing.

### 5.21 A bring-up panel, designed to be read by a person *(Master of Weapon)*

§8 item 7 says to add the overlay early. This is what it needed once someone
was reading it to me square by square, off a picture the scaler had rotated.

- **Open with a fixed marker.** Row 0 begins `1010 1010`. The first reading
  from hardware could not be decoded, because the reader had reasonably skipped
  the frame counter and I had assumed he had not; a contradiction in one bit
  (an input tied high reading low) was the only reason I noticed. Eight squares
  buy a reading that checks its own alignment.
- **Check the widths add up to the bus.** A concatenation narrower than the
  status word zero-extends on the left and shifts every field, silently.
- **Report the first fault, not the current state.** A snapshot taken when the
  watchdog expired said where the CPU happened to be. A capture that freezes on
  the first exception vector a healthy run never fetches, with the two code
  addresses before it, says where it went wrong — and whether that address is
  the same on every power-up separates a logic fault from a marginal memory.
  **Prove the detector quiet on a healthy boot and firing on a sick one in
  simulation before it costs a flash cycle.**
- **Self-test every external memory before the core leaves reset**: two
  patterns that are each other's byte swap and nibble inverse, so that a stuck
  bit, a swapped lane and a dead bus read differently from a pass and from each
  other. Give it a timeout, or a port that never acknowledges holds the core in
  reset and "dead" looks exactly like "wrong".
- **Reading back the first word of each ROM region proves the path, not the
  image.** All three were right while the image behind them was peppered with
  bad words. If the load can corrupt, show a checksum of the whole image.
- **Count things that should happen often.** Watchdog kicks since reset turned
  "the CPU is not halted" into "the CPU dies within three kicks of boot".
- Leave all of it in the gateware for release, and take it off the menu.

### 5.22 When the fix changes nothing, the theory is dead — say so *(Master of Weapon)*

I fixed the striped picture twice before I fixed it. The first fix (fetch
graphics in bursts, so lines finish in time) was well reasoned, verified in
simulation, improved a real number — and the user's report was "still the
same". That sentence is worth more than the reasoning: a change that large to
the fetch path, with *no* change to the symptom, means the symptom does not
come from the fetch path. I had also presented a simulation-versus-hardware
difference as evidence without checking what the bench modelled; it modelled
graphics latency as a flat number with no contention, so the difference proved
nothing.

- **Before citing a sim-versus-hardware gap as evidence, read what the bench
  models for that quantity.** If it is an idealisation, the gap is expected.
- **State the prediction before the build**: "if I am right, the stripes go and
  the panel reads under 6,328; if the panel reads a number and the stripes
  stay, this theory is wrong." Then the report decides it in one line.
- **Correct yourself in the open, at once, with the reason.** Four times here
  I told the user something a later measurement overturned — a graphics
  read-back I had computed from the wrong offset, an SRAM theory, a timing
  exception, the overrun. Each correction cost a paragraph. Building on any of
  them would have cost a day.
- **Derive expected values from the constants the RTL uses**, not from memory.
  The "wrong" read-back was correct; my expectation used a region base that was
  never in the design.

### 5.23 The panel is not a CRT, and burn-in is permanent *(BBC Micro)*

A BBC Micro core shipped a picture that alternated between two images at
25 Hz. The user reported "a 60Hz vertical jitter, almost like looking at a
CRT — the flicker is in the onscreen text", and by the time it was diagnosed
it had left a **visible ghost on their Pocket's OLED**. That one faded after
a few hours of other games — it was image retention, not burn-in — but OLED
wear is cumulative and the margin between the two is exposure. Nothing else
in this document risks the reader's hardware at all.

The cause was honest emulation. The machine's CRTC is programmed for
interlace sync and video, so the field number becomes the low bit of the
scanline address and one field's vsync is delayed by half a line
(`RA <= line_counter(4 downto 1) & odd_field`). Alternate frames genuinely
draw different scanlines of every character from a different vertical
origin. A CRT's phosphor and a viewer's eye merge the two fields; that is
what interlace is *for*. A fixed-pixel panel fed one field per frame merges
nothing, and an OLED fed the difference forever keeps it.

Every gate this project had passed. Frames matched MAME. The memory gate
passed, timing closed, the frozen states agreed. **No bench had ever compared
one frame with the next one** — every comparison was against an emulator's
frame or against another run's frame *at the same time*, which is exactly the
comparison that cannot see an alternation.

- **Compare consecutive frames of a still picture, before the first flash.**
  `tools/check_frames.py` does it: neighbours differing while frames two apart
  are identical is an alternation, and it exits non-zero. Three frames of a
  boot screen is enough. Put it in the pre-flash list beside `run_mem.sh`.
- **A user saying "like a CRT" is naming the mechanism, not reaching for a
  simile.** Interlace shimmer looks like interlace shimmer. Parse it as a
  diagnosis (5.15).
- **Do not stop emulating interlace — stop alternating.** Keep the geometry
  the machine asks for, ten scanlines a row and 312 lines at 50 Hz, and draw
  the *same* field every frame. In the vendored `mc6845` that is three lines:
  hold `odd_field` at zero, always select the even field's vsync, and let a
  new frame start every field instead of every second one.
- **Any output that alternates is a burn-in risk, not only interlace.** A
  dither that toggles per frame, a flashing cursor implemented as
  frame-alternation, a "blend two frames for transparency" trick from a
  console core — the panel holds all of them. If the machine's own display
  relied on persistence to merge something, the core has to do the merging.
- **When a picture fault reaches a user, tell them to stop running the core
  before the next build.** The cost of a wrong frame on an OLED is not a
  wasted flash cycle, and the fix arriving twenty minutes later is twenty
  minutes of exposure that did not need to happen.

A second, unrelated fault in the same core produced three symptoms that
looked like three bugs: `video.json` declared `320x224` from the arcade
template while the core emitted `640x256`. The picture was squished
horizontally, the bottom 32 lines — where the on-screen keyboard draws — were
cut off, and the scaler flickered because it had nothing to settle on.
`tools/check_json.py` reads the window constants out of the RTL and fails if
`video.json` disagrees, along with the rest of what the Pocket's firmware
silently refuses.

### 5.24 Save RAM: the core writes it, and the load and the write are two paths *(Punch-Out, NBA Jam)*

A nonvolatile data slot is the core's job, not the platform's. Five rules,
each of which cost a hardware round on one core or another:

- **The core issues `target_dataslot_write` itself** — a couple of seconds
  after the game last touches its battery RAM, when the menu opens, and once a
  few seconds after loading. The Pocket only writes back a slot it *loaded*, so
  the exit-time flush can never create the first file.
- **Put the slot at bridge address `0x20000000`** with its own `data_io`
  (upper-nibble mask 2) and its own unloader. `0x10000000` hangs the load the
  moment a file exists.
- **Write the slot's size into the data-slot table**, entry
  `position * 2 + 1`, where *position* is the slot's place in `data.json`
  (NBA Jam: game JSON, ROM, save → the save is position 2 → entry 5, and the
  file appeared). If the entry is zero, nothing is written.
- **Set parameters bit 5** (initialise-on-load), or a never-loaded slot has no
  filename for the core's write.
- Saves land in `Saves/<platform>/<core id>/<filename>`, and reinstalling the
  core does not touch them.

**A slot's id appears in the RTL more than once, and moving it moves all of
them.** Adding a game list (§5.26) turns the ROM from slot 0 into slot 1 and
the save from 1 into 2. In `core_top` that is four places: the ROM loader's
`ioctl_index` test, the *save loader's* `ioctl_index` test, the table entry,
and `target_dataslot_id`. NBA Jam moved three. The save file kept being
written, 16 KB, with the edited settings in it, and every restart came up with
factory settings, because the loader still took slot 1 and ignored slot 2.

- **Grep for every slot id and every `ioctl_index` comparison** when
  `data.json` changes. The write path and the load path are separate code and
  fail separately.
- **Verify a save on hardware in three steps**, each read off the card: the
  file exists; its contents differ from the factory image where the change was
  made (compare it with MAME's own `nvram` for the set); and after quitting
  and relaunching the core the change is still there. The first two passing
  and the third failing is exactly the loader bug above.

### 5.25 A power-on self-test must not touch what the loader just wrote *(NBA Jam)*

The template's SRAM self-test writes two words and reads them back before the
core leaves reset, so a dead SRAM shows on the panel instead of as a silent
machine. On NBA Jam the SRAM holds the sound CPU's program, which the
download writes *just before* the test runs. The test's addresses,
`0x1fffe`/`0x1ffff`, were written for a 17-bit port; this core's port was 16
bits, so they landed on `0xfffe`/`0xffff` — the last two words of the 6809
program, its NMI and RESET vectors. The sound CPU started at the test pattern,
the machine was silent apart from clicks, and **the panel read a pass**,
because two distinct words did go in and come back out.

- **A test that says "pass" proves only what it looks at.** Here it looked at
  its own two words, not the program around them.
- **Put back what the test overwrites**: read the words first, write them back
  last (`sram_selftest.sv` in Smash TV and NBA Jam). Or test only memory
  nothing else has filled yet.
- **Give the test's addresses the port's width**, and check it: a mismatched
  width truncates silently.
- **Logic that lives only in `core_top` is in no bench.** Move it into a small
  module the memory gate instantiates, and run it there *in the platform's
  order* — download, then self-test, then read every byte of what the core
  will execute. Put the old behaviour back once to see the gate fail on the
  bytes you expect.

### 5.26 One core, several games: the list, the recognition, and what differs *(Pleiads, Punch-Out, NBA Jam)*

When a family of sets runs on one board (NBA Jam and Tournament Edition),
**read how MAME tells them apart before planning anything**: here it was one
init routine with a single switch, changing a protection table and where the
sound board's hidden RAM sits. That is an afternoon, not a second core.

- **The game list is instance JSONs**: `data.json` slot 0 "Arcade Game"
  (`json`, parameters `0x113`, no filename), slot 1 the ROM (`0x108`), slot 2
  the save; one `Assets/<platform>/<core id>/<Game>.json` per game naming its
  ROM and its save. The Pocket lists the games by name, and updaters fetch every
  file an instance names. Then see §5.24 for what moves in the RTL.
- **The core recognises the game from the image as it loads**: sum a region's
  bytes and compare with the known totals, defaulting to the first game.
  Count **each byte once** — the loader holds its strobe several clocks, and a
  sum taken on the level matches nothing (Pleiads' Phoenix played with the
  wrong sound board for exactly this). Test recognition in the memory gate at
  strobe holds of 1, 4 and 7.
- **Re-run the whole method for the second game**, cheaply: its own MRA
  checked against MAME's regions, its own frozen states through the models and
  the RTL, the CPU from reset against MAME, and — for protection — every
  question and answer of its boot logged in MAME and in the bench and diffed.
  Parametrise the tools by set name early (`GAME=...`); every script that
  hard-codes the first set's name is a trap for the second.

### 5.27 Count what the game finishes, not what the CPU executes *(NBA Jam)*

"Frame drops when a basket is in view" had no trace in the number we had been
watching, CPU cycles per frame, which sat at 99%: a CPU waiting for the
blitter still spends its cycles, busy-polling. The measurement that saw it
counts **page flips** — writes to the display-start register — per frame, in
MAME and in the bench over the same stretch of play: MAME flipped on 975
frames of 1000, the core on 796, and on alternate frames only through the
busiest scenes, where the blitter was busy 94% of every frame.

- Pick the metric that the symptom lives in. For smoothness it is frames the
  game completes; for sound it is loudness over time (§5.15); for speed it is
  how far the timeline has moved against the oracle's.
- **Run the bench in the configuration the hardware runs.** The first long
  run used the fast memory setting the Pocket could not use; its numbers were
  comfortable and irrelevant.
- The oracle's own count is the baseline: the arcade drops frames too (25 in
  1000 here). The question is only whether the core drops *more*.

### 5.28 On the Pocket, SDRAM writes and reads have different speed limits *(NBA Jam)*

Bursts at one word a clock were exact in every simulation and garbled the
palette byte on hardware; one word every two clocks was clean but too slow for
the busiest scenes. Splitting the pace by direction settled it in one test:
**writes at one a clock are sound; reads at one a clock are not** (at the
default capture phase). Writes are most of a blitter's traffic, so fast
writes with half-rate reads was both clean and smooth.

- **Make a hardware-only speed a runtime choice**, per direction, while it is
  unproven, so one flash can try every combination. The person holding the
  Pocket bisects faster than any recompile.
- **Make the all-clear value of every such switch the tested setting.** Then
  taking the switches off the release menu changes nothing, and a firmware
  that never writes a default cannot select an untested mode.
- A symptom confined to one byte of a word ("colours wrong, shapes right")
  names the byte lane before it names the cause; say so, and design the next
  test to split it.

### 5.29 The instrument's hidden state *(NBA Jam)*

Two measurements here were wrong for reasons that had nothing to do with the
core:

- **A persisted emulator setting.** A service-mode capture left the test
  switch on in MAME's saved `cfg`; every later run sat in the test menu, and a
  five-minute census of the blitter reported 457 blits and "zero" of what it
  was looking for. Give each investigation its own `-cfg_directory` and
  `-nvram_directory`, and sanity-check a census against a known rate (a busy
  frame has hundreds of blits) before believing its zero.
- **A bench that dies on a missing output directory** looks like a bench that
  ran and found nothing. Create the directory in the bench, or refuse loudly.

---

### 5.30 The Analogizer: a second picture, and settings the player can find *(MSX2, Moo Mesa, and fifteen retrofits)*

RndMnkIII's Analogizer takes the core's own picture out of the cartridge slot
to a CRT, and native pads in through SNAC. The template carries it on by
default (`target/pocket/pocket_analogizer.sv` around his vendored module;
`docs/analogizer.md`), and `docs/analogizer-retrofit.md` is the order of work
for a core that predates it. Ten lessons cost a round each:

- **The scandoubler needs the whole line and real blanking.** It sizes its
  line buffer from `LINE_LEN` and times every output line from the H-blank
  edges. MSX2 first gave it the visible width and no blanking. Every
  scandoubled line lost its right half, and its syncs were garbage, with
  nothing wrong on the Pocket's screen to point at it. The bench counts the
  doubled lines and their period, so a wrong `LINE_LEN` or a missing blank
  fails there, not on a VGA monitor.
- **Put the settings in the core's menu, not in a file.** The adapter
  module 1.4 reads `analogizer.bin`, a shared file Pupdate writes, and this
  template first followed it: a data slot at `0xF7000000`, a second platform
  id `analogizer` for the folder, the master enable in the file. It was
  right by the module and wrong for the player. The adapter's own *How to
  use it* page never mentions the file, the first person to install the core
  had no file and an empty `Assets/analogizer/common/`, and their other
  Analogizer cores all set it from the menu (the wiki's "Pocket Menu" kind:
  RndMnkIII's arcade and console ports). The core now writes the same word
  from four masked `interact.json` entries, off by default, and
  `tools/check_json.py` refuses an entry outside its mask, a menu with no
  enable, a data slot over the word, or an unpowered slot. Earlier versions
  of this section and of the retrofit handoff called the menu scheme
  obsolete; it is not, it is what players have.
- **A read-back latched on `bridge_rd` is the previous read's.** The bridge
  (`io_bridge_peripheral.sv`) presents the address, samples the read data
  four clocks later, and only then pulses `bridge_rd`. The adapter module,
  like `interact.sv`, updates its read data on that pulse. Masked entries
  share one word, so a firmware that merges them by reading the word back
  gets a stale value and wipes the other fields: on the bench, choosing a
  video mode turned the Analogizer off. `pocket_analogizer.sv` reads its own
  copy back combinationally, as RndMnkIII's menu cores do, and the bench
  sets every option by read-merge-write at the bridge's timing. Analogue's
  interact.json documentation says the firmware does read back: every
  entry not marked `writeonly`, every frame, and a masked entry is written
  as that read merged with its field. (Earlier versions of this section
  said that was not known.)
- **The DAC clock is a cartridge pin.** The module clocks the ADV7123 with
  its own clock, so that clock leaves the FPGA through the slot's level
  translators. Shipped cores use 42.95-48 MHz. A 96 MHz core gives it a 48 MHz
  PLL output, in phase, and hands the pixel over, rather than asking the
  translators for a rate no one has tried.
- **Centring the picture on a CRT is moving the syncs, and the adapter
  re-reads their polarity every period.** The first CRT showed Moo Mesa
  about 10 lines high. Two signed sliders (`0xF7000004`, `0xF7000008`) now
  re-make hsync and vsync earlier or later from the source's own edges, and
  the picture, blanking and every mode follow untouched. The module's
  `sync_fix` decides each sync's polarity afresh from whether the last
  period was more high than low, so a jump between settings that puts two
  pulses close together turns csync inside out for a frame: the template's
  bench caught it at +2 to -2 lines. A re-made pulse now waits until it has
  been off as long as it is on. The range is the core's, from its blanking;
  the bench fails if a sync reaches the picture at either end.
- **The adapter takes everything on its pixel enable's rising edge.**
  Colour, blanks and syncs are all latched there and nowhere else. An
  optional width slider plays each line back faster or slower from a line
  buffer, and fed the source's enable the picture snapped straight back to
  the source's dots: at ±10% the bench measured every dot held exactly 7
  clocks. Anything that changes the picture's timing inside the wrapper
  has to make its own enable, here a pulse on every change.
- **A board that is not 15 kHz shows copies of itself on a 15 kHz CRT.**
  Xenophobe (31 kHz) came back as two playfields side by side, each cut at
  its edges; Atari System 2 (25 kHz medium-res) as seven interlaced copies.
  Nothing on the Pocket or in the bench, which checked the board's own
  raster at the pins, pointed at it: the bench proved the signal was the
  board's, and the board's is not what a PVM takes. `ana_15k.sv` now makes
  a frame-locked progressive picture of half the lines, each line a blend of
  a pair (or, "Sharp", the even one); a 480i picture would keep every line
  and was rejected by the owner for its flicker on a PVM. Ask the line rate
  before the first flash (`docs/analogizer-retrofit.md` 0.10).
- **The firmware's menu limit is on options, and smaller than any
  documented one.** Analogue documents 16 entries; the firmware also
  refuses a menu with too many list options, with "Error in interact" and
  then "error in core setup" at load. Atari System 2 at 70 options and BBC
  Micro at 77 were refused, both load at 64, MSX2 at 68. `check_json.py`'s
  earlier limit, 52, was a survey of installed cores, not a measurement; it
  now fails above 68 options and 80 options plus entries, the largest seen
  to load. Cut the Analogizer lists' rare options and the core's own
  display extras before the game's settings.
- **CI's tools are older than the Mac's, in two directions.** CI's
  Verilator 5.020 cannot parse the vendored Y/C encoder's sine table and
  will not lint the SNAC module without a waiver, so every Analogizer push
  failed CI until a stub and the waiver went in; Quartus 18.1 cannot parse
  `-12'(dh)`, which the lint fix introduced and pushed to six repos without
  a map. Run the 5.020 container's lint *and* a Quartus map before pushing
  RTL (`docs/analogizer-retrofit.md` 7).
- **The cores that fill the FPGA need the module trimmed.** S.T.U.N.
  Runner needed 102% with the whole adapter module; `USE_YC = 0` and
  `USE_SD = 0` (a local, marked change to the vendored module) leave out the
  Y/C encoder and the scandoubler with HQ2x, and it fits (Gaiapolis and
  Master of Weapon too). Pole Position, at 103%, is without it so far.

On hardware (2026-10, a PVM) the sixteen cores carrying it all show their
picture, and a SNES pad over SNAC works in them.

The picture the Analogizer gets is the one the Pocket gets, before the
scaler-side blanking, bring-up panel included. A panel readable on a CRT is
worth having the day the Pocket's screen is blanked on purpose.

### 5.31 A Lua write to an analog port is not a player's input *(Atari System 2)*

Atari System 2's pedals are MAME `IPT_PEDAL` fields, `PORT_MINMAX(0,0x3f)
PORT_INVERT` over an 8-bit port: a player's pedal reads 0xff up and 0xc0
floored, because MAME inverts the field's 0..0x3f within its mask. The
traces drove the pedal with Lua's `field:set_value(n)`, and that writes the
port's raw value, **clamped to the field's range and not inverted**:
`set_value(63)`, `set_value(192)` and `set_value(255)` all give the game
0x3f. A later change read those traces as "0x3f is the pedal up" and fed
every game 0x3f released. APB was right with it; Super Sprint and
Championship Sprint read 0x3f as floored, and for four releases their cars
drove off on their own -- with or without the Analogizer the owner had
just plugged in, which is what pointed away from the new work.

Before believing a trace's input, read the port the game reads
(`manager.machine.ioport.ports[":ADC0"]:read()`) with the field untouched
and with it set, and compare the game's behaviour at both against a
keyboard press in MAME. A measurement here took two headless runs: untouched,
the port read 0xff and the track-select screen waited for the pedal; set to
anything, it read 0x3f and the race started by itself.

### 5.32 The core list reads `core.json`, not the tag *(fifteen releases)*

Updaters and the openFPGA core library take a core's version **and its
release date** from the `core.json` inside the release zip. Fifteen
Analogizer releases bumped `"version"` and left `"date_release"` at the
previous release's: the library listed them under dates weeks old, and the
owner's updater did not surface them. A patch release of each, the same
bitstream with today's date, fixed it. `tools/cut-release.sh` now refuses a
`core.json` whose version is not the tag or whose date is not today.

A second effect, not a fault: a Pocket whose card already has the build
(copied for testing) shows no update for the release of that build, because
its installed `core.json` already says that version.

## 6. Sizing the board: what changes the plan

Read these off `mame -listxml <set>` and the driver before writing anything.
Each one moves the work substantially.

**Total ROM size against ~400 KB of block RAM.** This is the biggest fork in
the road. A board whose ROMs fit entirely in BRAM needs no SDRAM at all — and
with it goes the arbiter, the fetch latency, the bandwidth budget, the
download FIFO and a whole class of first-hardware-run faults (§5.16, §5.17).
Every access becomes single-cycle and deterministic. **If it fits, do it**, and
delete the SDRAM clients from `<core>_mem.sv` rather than leaving them unused.
A 1.6 MB board has no choice; a 53 KB board would be foolish to use SDRAM.

**The CPUs.** Use a proven core: fx68k (68000), T80 or tv80 (Z80), and so on.
Write one only if none exists, and then write it against MAME's cycle table
with a bus-trace bench as its test (§5.12). Vendor with `tools/vendor.sh` and
record it in `modules/VENDOR.md`.

**What paces the audio.** A board with a real sound chip takes its tempo from
that chip's own clock, so §5.3's starvation trap does not apply — but §5.4
does, because its output still crosses into the Pocket's audio domain. A board
with a software DAC on a CPU is the opposite: the CPU's cycle budget *is* the
tempo, and losing a few percent of it is audible. Find out which you have
before designing the memory system.

**Colour PROMs.** Many boards resolve palette and tile/sprite colour through
small PROMs. Model them in the reference renderer first; they are a common
source of "the picture is right but every colour is wrong".

**Rotation.** A vertical monitor is normal in arcade hardware and the Pocket
handles it, but settle the orientation early: it changes how you compare
against MAME's snapshots, and the aspect ratio in `video.json` describes the
raster *before* the scaler rotates it (§5.5).

**Explicit filters.** Where MAME models RC filters, read the coefficients from
the driver rather than approximating. Standing three one-pole sections in for
a five-pole design left one core measurably darker in the passband and leakier
above it.

A workable order for most boards: ROM builder → reference renderer → tilemaps
→ sprites → frozen-state gate → CPU and memory map → sound → platform
integration → hardware.

---

## 7. What the template already gives you

Built in, working, and checked — so none of it has to be written again or
fetched from another repository.

| Path | What it does |
|---|---|
| `rtl/<core>_core.sv` | the skeleton machine: raster, test pattern, cursor, beep, one read per ROM region. Replace its inside; keep its ports |
| `rtl/clk_enables.sv` | CPU/sound/dot enables, with the pause that freezes the machine and leaves the picture up (§5.5) |
| `rtl/dbg_overlay.sv` | the bring-up panel: four rows of 32 squares, alignment marker first (§5.21) |
| `rtl/dbg_fault.sv` | first-fault capture — the first exception vector a healthy run never fetches, and where it was |
| `target/pocket/core_top.sv` | APF glue, SRAM self-test before reset, panel wiring, audio clock-domain hand-over (§5.4) |
| `target/pocket/<core>_mem.sv` | SDRAM clients, the download FIFO that a non-stallable loader needs (§5.16), the burst arbiter, the SRAM port |
| `target/pocket/sdram_ctrl.sv`, `sram_port.sv` | the controllers, proven on hardware |
| `projects/*.sdc` | the constraints, and how to set the SDRAM capture phase (§5.20) |
| `projects/report_worst.tcl` | worst paths at every corner, setup *and* fast-corner hold |
| `sim/run_mem.sh` | the memory gate: an image through the download port at the loader's rate and back out (§5.16) |
| `sim/run_system.sh` | the whole machine through the real memory glue — the bench two cores shipped without |
| `sim/lint.sh` | every module linted alone, with a waiver file built to match the installed Verilator |
| `sim/sdram_model.sv`, `sram_model.sv` | behavioural chips beyond the pins |
| `tools/mra_build.py` | MRA interpreter; builds and CRC-checks the ROM image |
| `tools/diff_frames.py` | pixel diff with per-cell hotspots — the shape of the error usually names the mistake |
| `tools/compare_audio.py` | peak, RMS, correlation and band energy across a whole capture (§5.9) |
| `tools/check-no-roms.sh` | refuses to let ROM data be committed, and aborts rather than passing when it cannot check |
| `tools/cut-release.sh` | publishes the bitstream a named CI run produced, not a fresh compile (§5.6) |
| `tools/vendor.sh` | fetches a vendored CPU or sound core from its upstream, pinned |
| `tools/examples/` | worked tools from a shipped core, as patterns for the ones only you can write |
| `.github/workflows/compile.yml` | lint, compile, **every constraint applied**, timing closed, package, tag-triggered release |
| `target/pocket/pocket_analogizer.sv`, `target/pocket/analogizer/` | Analogizer support: CRT video and SNAC pads, built in, set from the core's menu (four entries, and two to centre the picture on the CRT), off until the player turns it on (§5.30) |
| `sim/run_analogizer.sh` | the Analogizer path read at the cartridge pins: every visible dot, the scandoubler's lines, each SNAC assignment |

What is *not* here, because only the board can say: the reference renderer, the
frozen-state video bench, the MAME state dumper, and the RTL of the machine
itself. `tools/examples/` holds one core's versions of the first three.

---

## 8. If I were starting again

1. Read MAME's driver properly and write `docs/hardware.md` first.
2. Build the ROM path and CRC-check it.
3. Get the reference renderer pixel-perfect before writing video RTL.
4. Put everything in BRAM if it fits. It removes entire categories of bugs.
5. Audit clock-domain crossings before integration, not after.
6. Find out what paces the audio, and verify its rate against MAME early.
7. Add the diagnostic overlay before you think you need it.
8. Verify anything verifiable before spending a 20-minute build.
9. When a user reports something you cannot reproduce, believe the report and
   distrust the theory.

Added after Pleiads / Phoenix:

10. Make the bench deliver the ROM, reset and strobes exactly as the platform
    does, and ask of everything crossing that boundary whether it is
    idempotent. (§5.8)
11. If the core can be in more than one configuration, put which one on the
    overlay, and never let "unrecognised" fall through to something that works.
12. Capture audio in play, judge it across the whole capture, and pick the
    metric to the signal: correlation if phase-locked, band energy if not.
13. State the window with every number, and audit a new instrument on old data
    before believing it.
14. Derive levels and time constants from the emulator's arithmetic; a fitted
    constant hides the next bug.
15. Register every input at the edge of a relaxed timing region, and keep
    everything that is not paced like the rest of it outside.
16. List what each captured stimulus actually exercises, and write down the
    rest as unverified.
17. Publish the simulator's output where the user can hear it next to the
    hardware. It bisects.

Added after Master of Weapon:

18. Build the second whole-machine bench — real memory glue, behavioural
    chips, the image pushed at the loader's real rate — before the first
    flash, and call everything beyond the core's ports unverified until it
    exists. (§5.16)
19. If a sibling core works on hardware, diff the platform layer against it
    before forming a theory; and when you fix a copied file, grep the siblings.
20. Latch the owner of every shared port at grant and route the ack by it;
    count request/ack coincidences in the bench. (§5.17)
21. One-dimensional, power-of-two RAMs. Nothing a synthesiser has to interpret.
    (§5.18)
22. Every budget counter saturates on a miss and survives the restart that the
    miss causes. (§5.19)
23. Never push to learn whether timing closed; re-read the worst paths after
    every fix; report setup at the slow corners and hold at the fast ones; fail
    the build on an ignored constraint. (§5.20)
24. The panel opens with a marker, captures the first fault rather than the
    current state, and self-tests the memories — and its detectors are proven
    in simulation on a healthy run and a sick one. (§5.21)
25. Ask for the game's own test pattern before asking for a photograph of
    gameplay.
26. Say what each build is predicted to change, and when it changes nothing,
    drop the theory rather than extend it. (§5.22)
