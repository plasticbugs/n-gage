# First flash: what to do and what to read

For the person holding the Pocket. Keep this exact — it is read from while
someone decodes squares off a screen.

## Before flashing

- `sim/lint.sh` clean; `sim/run_mem.sh` passes at `-gap 8 -hold 4`.
- The whole-machine bench on the real memory glue boots.
- **`tools/check_frames.py` passes on three CONSECUTIVE frames of a STILL
  picture** — snapshot the boot screen at, say, 2500, 2520 and 2540 ms and run
  it on the three. If neighbours differ while frames two apart are identical,
  the core is emitting alternating fields. The Pocket's panel is OLED and
  holds the difference between the two images — as retention that fades, and
  with enough hours as wear that does not. A core shipped this way and left a
  ghost on a user's screen; nothing else on this list touches their hardware.
  Do not flash until it passes (METHODOLOGY 5.23).
- `tools/check_json.py pkg/pocket --active <W>x<H>` clean — the firmware
  refuses a bad `interact.json` with nothing but "General Error", and a
  `video.json` that disagrees with the core comes out as three separate-looking
  picture faults.
- `./build-local.sh compile`: no negative slack in any corner
  (`projects/output_files/*.sta.summary`), no ignored constraints.
- The ROM image's md5 matches the MRA's.

## On the card

`release/pocket/` onto the card root, with `cp -X` from macOS. The ROM image
goes in `Assets/mycore/common/mycore.rom`. Verify the bitstream's md5 on the
card.

## The skeleton, before there is a game

A white crosshatch every 16 pixels with red, green and blue bars across the
middle, dark above bright. A cyan square moves with the d-pad, turns yellow on
button 1 (A or Y) and magenta on button 2 (B or X); button 1 also beeps. Every
grid cell the same size and every line unbroken means the raster, the video
hand-over, the scaler settings, the controls and the audio path all work.

## The panel

Menu → **Bring-up: panel**. Four rows of 32 squares along the bottom edge of
the picture (the *right* edge if the picture is rotated 270, read bottom to
top). Green is 1. Read each row from the end where row 0 shows `1010 1010`.

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
| 0 | 23 | CPU halted | 0 |
| 0 | 24 | watchdog has fired | 0 (expected 1 after the menu has been open a while) |
| 0 | 25–32 | system inputs, active low | `1111 1111` with nothing pressed |
| 1 | 1–8, 9–32 | first fault: vector, then the code address before it | all 0 |
| 2 | 1–16, 17–24, 25–32 | first program ROM word, first sound ROM byte, first graphics byte | *fill in from the image* |
| 3 | 1–16, 17–32 | SRAM self-test | `1010 0101 0101 1010`, `0101 1010 1010 0101` |

Row 2 proves the path, not the image; `sim/run_mem.sh` proves the image.

## If it is wrong

| symptom | look at |
|---|---|
| black, counter running, row 2 right, watchdog 1 | the image in SDRAM — rerun `sim/run_mem.sh`; section 5.16 |
| row 3 not the pattern | **Bring-up: SRAM** switches; then the SRAM port |
| row 2 wrong | **Bring-up: SDRAM** switches; then the PLL phase (SDC, section 5.20) |
| garbled picture | ask for the service-mode test pattern first; section 5.18 |
| glitches only while playing, gone in the menu | something the CPU shares with the video; section 5.17 |
| menu restarts the game | `pause` has reached a reset; section 5.5 |

## With an Analogizer

Only once the core itself is healthy on the Pocket's screen, and in this
order -- each step's reading tells the next where to look
(docs/analogizer.md):

1. **Menu "Analogizer: Off"** (the default).  The core must play exactly as
   without the adapter.  If it does not, the cart port is not idle: stop.
2. **Menu: Analogizer On, Video RGBS, SNAC Adapter None.**
   The same picture on the Pocket and the CRT, at the board's line and frame
   rate (a PVM's info screen shows them).  The bring-up panel shows on the
   CRT too.  No picture: say whether the CRT reports a signal (sync but no
   colour points at the DAC clock; nothing at all points at sync).
3. **Each other video mode in turn** (RGsB and YPbPr need the SOG switch on).
4. **SNAC**: one pad, assignment "SNAC P1 -> P1"; the Pocket's own
   controls are then player 2.
5. **The menu's memory**: change Video, quit the core and load it again.
   The setting, and Analogizer On, should still be there.  Then change one
   entry and check the others did not move (the bench's read-back check,
   on the real firmware).
6. **Position**: "Analogizer V Position" + should move the picture down
   by that many lines, + on "H Position" to the right, and both should be
   kept across a reload.  The slider showing a value other than the one
   set means the firmware is not reading 0xF7000004/8 back as written.  A
   picture that rolls or tears at either end of a slider means the range
   is too wide for that set (say which end, and which mode).

## Log

Date, build md5, what was seen, what it ruled out. One line each. The theories
that died belong here as much as the one that lived.
