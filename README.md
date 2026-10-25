# N-Gage — Analogue Pocket core (openFPGA)

https://youtu.be/lo0pgil90-o

The Nokia N-Gage (2003) runs Symbian OS 6.1 on a 104 MHz ARM9. This core
does not rebuild the phone's board. It runs **NGVM**, a small machine with just
enough of an ARM phone for the Symbian user side of your own phone's firmware
to run unchanged. That machine has:

- an ARMv4T CPU of our own, in gateware;
- caches and a page table;
- a 176×208 LCD, a timer, the keys and an audio FIFO.

A small C kernel (`sw/kernel`) stands in for the phone's EKA1 kernel and
drivers.

> **No firmware or games are included, and none ever will be.** You supply
> the phone's firmware (`sym.rom`) and the games' memory cards, built by the
> page that comes with the core or by `mkdrive.py`: "What goes on the card",
> below, says where to get the firmware and where each file goes.

| part | implementation | verified by |
|---|---|---|
| CPU, ARMv4T + Thumb, 80 MHz on a PLL of its own | `rtl/arm_*.sv`: eight stages, branch prediction; 64 KB instruction and data caches | lockstep with Unicorn, instruction by instruction (`sim/run_cpu.sh`, `sim/run_sys.sh`); docs/core-design.md 6 |
| caches, page table, devices | `rtl/ngvm_{icache,dcache,mmu,io,sys}.sv` | lockstep with Unicorn behind ideal memories (`sim/run_sys.sh`) |
| the kernel | `sw/kernel` | the reference machine, `tools/ngvm/ngvm.py`; six of seven games reach their menus or play |
| RAM, firmware | Pocket SDRAM (`target/pocket/ngage_mem.sv`) | `sim/run_system.sh`: loaded at the loader's rate, read back byte for byte |
| memory card | Pocket CRAM (`target/pocket/cram_ctrl.sv`) | the same, with the chip's timing checked cycle by cycle (`sim/cram_model.sv`) |
| LCD | `rtl/ngvm_lcd.sv`: the framebuffer copied to block RAM when the firmware updates the display; a second raster with the picture turned, for the Analogizer | pixel-identical to the reference on the boot screens (`sim/run_system.sh`, 0 of 36,608 differ), and still: three consecutive frames identical; every dot and sync of both rasters, both ways round (`sim/run_lcd.sh`) |
| audio | the FIFO in `rtl/ngvm_io.sv`, 1,024 samples (32–64 ms) at the game's rate | sample-for-sample the reference over 9.2 s of Virtua Cop's music, at the FIFO's output (`sim/run_system.sh --wav`) |
| on-screen keypad | `rtl/ngage_osk.sv`, drawn by `tools/make_osk_panel.py` | every panel pixel matches the generator, each key presses its own bit, and nothing that drives it reaches the game (`sim/run_osk.sh`) |

## Status

**It runs on the Pocket**: the current release is v1.3.0, which runs
games larger than 32 MB: Pathway to Glory (59 MB) runs on a Pocket.
v1.2.0 kept each game's saves on the SD card and shipped a page, on the
card, that turns game zips into games. v1.1.0 added TATE for the
Analogizer, centred the Analogizer's picture on a CRT, and got Rifts:
Promise of Power past its cutscenes. The first flash (CPU at 64 MHz)
booted and ran Sonic N into gameplay, with sound. Since
then the CPU runs at 80 MHz on a clock of its own, both caches hold
64 KB, the picture is copied when the firmware updates the display, the
audio FIFO holds 32–64 ms, a cache miss restarts the CPU on the word it
missed, and SDRAM reads come at a word a clock, with no gap between
bursts. In simulation of the Pocket's hardware, Virtua Cop in play draws
about 1.7 times as many screens a second as in v0.3.1-alpha. On the
Pocket, Virtua Cop, SSX: Out of Bounds and Puzzle Bobble VS play on
v1.0.0. Colin McRae Rally 2005, Tony Hawk's Pro Skater, Ghost Recon,
Atari Masterpieces Vol. 1 and 2, Rayman 3, The Roots, The Sims Bustin'
Out, Pocket Kingdom, The Elder Scrolls Travels: Shadowkey and (slowly)
Call of Duty played on the alphas; `docs/release-notes.md` lists what
does not.
`docs/bringup.md` says what each build should show, and logs what each did.

What is proven, and by what:

- The CPU agrees with Unicorn, instruction by instruction:
  - 1,500 random programs;
  - the firmware's boot;
  - 15–30 s of Bomberman, Virtua Cop and Sonic N, with ideal memories.
- The whole machine boots on the Pocket's memory glue in simulation
  (`sim/run_system.sh`). At 64 MHz it reaches Virtua Cop's title at 40 s
  of machine time, with no memory protocol error. Its screens and music
  match the reference emulator exactly.
- `sim/run_mem.sh`: every byte the loader sends reads back from SDRAM and
  CRAM, at the loader's fastest rate.

Saves: each game's saves are kept in
`Saves/ngage/plasticbugs.ngage/<game>.sav` on the card, its phone's C:
drive, written back a couple of seconds after the game saves and when the
Pocket's menu opens. Checked in simulation (the whole file read back
through the Pocket's bridge path, and the kernel keeping it on the next
boot), and reported working on a Pocket with v1.2.0's build.

What is not implemented:

- Pausing: the game runs on behind the Pocket's menu.
- Sleep, the link port.
- The phone's green, red, menu and pen keys. The on-screen keypad (below)
  leaves them out: the red and menu keys would take the phone out of the
  game, and the green and pen keys are for calls and for editing text.

## Controls

| Pocket | phone |
|---|---|
| d-pad | joystick |
| A, B | 5, 7 (the N-Gage's game keys) |
| X, start | OK |
| Y | 9 |
| L, R | left and right soft keys |
| select | # |
| **SELECT + R** | the on-screen keypad, and dismiss it |

The core's menu has a slider for each of A, B, X, Y, L and R. At 0 to 9
the button is that digit key of the phone; at 10 it is as in the table.
They start at 5, 7, 10, 9, 10 and 10, the table's own keys. A game that
asks for, say, 2 to pause or 0 for its map can then have it on a button.

### On-screen keypad

For everything the buttons do not reach, press **SELECT and R together**:
the phone's keypad comes up over the bottom of the picture, and the same
chord puts it away.

```
[ soft ] [ C ] [ soft ]
[  1  ]  [ 2 ]  [  3  ]
[  4  ]  [ 5 ]  [  6  ]
[  7  ]  [ 8 ]  [  9  ]
[  *  ]  [ 0 ]  [  #  ]
```

- **D-pad** moves the highlight a key at a time; it wraps at the edges,
  and holding a direction repeats.
- **A or B** presses the highlighted key. It is down for as long as the
  button is, so a long press works, and for at least four frames, so a
  quick tap always reaches the game. Tapping twice types twice, as on the
  phone's own keys. The key turns amber while it is down.
- **Y** moves the keypad to the top of the screen and back, to see what it
  covers (a phone's dialogs open at the bottom).
- The two keys with a bar are the left and right **soft keys**; what they
  do is written at the bottom corners of the game's screen. **C** is the
  clear key.
- The keypad opens where it was left, on 5 the first time.

While the keypad is up, all the buttons belong to it: the game sees only
the keys it presses. So that the chord itself never reaches the game,
SELECT and R on their own reach it four frames (67 ms) late; pressed
within 50 ms of each other, they are the chord, and the game sees
neither.

## Analogizer

The core supports RndMnkIII's [Analogizer](https://github.com/RndMnkIII/Analogizer)
adapter: the board's native picture out of the VGA port (RGBS, RGsB, YPbPr,
Y/C, or scandoubled for a VGA monitor), and SNAC controllers.  It is set up
in the core's own menu (Analogizer, Analogizer Video, SNAC Adapter, SNAC
Assignment, and H and V Position to centre the picture on the CRT); with
"Analogizer" off, the default, the core is unchanged.  The Pocket
powers the cartridge slot for this core: take any game cartridge out first.
`docs/analogizer.md` has the modes and the controller assignments.

The "Analogizer" list also has **TATE** options, for a CRT stood on its
side: the CRT gets the picture turned a quarter turn, filling the tube's
height, while the Pocket keeps it upright (or blank, with "Pocket off").
Choose "TATE CW" if the tube's top is turned to the right, "TATE CCW" if
to the left.

It has been tried on one owner's CRT. On v1.0.0 the CRT lost the
picture's bottom lines in its overscan. v1.1.0 puts the picture 13 lines
higher, centred as an NES's is, lets V Position move it 16 lines up or
12 down, and adds TATE; its owner reported it as great.

## What goes on the card

Unzip the release onto the SD card root. Then everything else goes in one
folder, next to the kernel:

```
SD card
└── Assets/
    └── ngage/
        └── common/
            ├── ngvm.bin    the kernel, already there from the release zip
            ├── sym.rom     the phone's firmware (the "BIOS")
            ├── sonic.img   one card image per game
            └── vcop.img    ...
```

**The firmware, `sym.rom`.** Dump it from your own N-Gage, or get
`bios/Nokia/N-Gage/SYM.ROM` from the
[retrobios](https://github.com/Abdess/retrobios) repository on GitHub. That
file is byte-for-byte the firmware this core was built and tested on:

- 18,612,224 bytes;
- md5 `64a95a4a884cf4cc15a566b856603193`.

Rename it to `sym.rom`, in lower case, and put it in
`Assets/ngage/common/`. Other firmware versions have not been tried.

**The games.** One `.img` per game, built from the game's files. The easy
way is the page that comes with the core,
`Assets/ngage/common/Add N-Gage games.html`. Open it from the SD card in
Microsoft Edge or Google Chrome, on Windows or a Mac, choose the card's
`Assets` folder, and drop the games' `.zip` files or folders on it, as many
at once as you like:

- it builds each game's `.img` and saves it to the card, with an entry in
  the Pocket's game list named after the game;
- it checks a dropped `SYM.ROM` and saves it as `sym.rom`;
- it never overwrites a file already on the card;
- it works offline, and nothing leaves the computer.

Other browsers download the files instead, for you to copy across. A short
narrated film on the page shows every step.

Or, with Python 3:

```sh
python3 mkdrive.py --from vcop.zip --out vcop.img
```

The page and `mkdrive.py` make the same bytes from the same game:
`tools/check_mkdrive.py` builds every case with both and fails on any
difference.

A game's card holds up to 64 MB. The core's drive is 32 MB, and a card
larger than that (Pathway to Glory and its Ikusa Islands, of the retail
games) is read from the SD card as the game needs it: new in v1.3.0.
Pathway to Glory runs on a Pocket; Ikusa Islands has been checked only in
simulation (`docs/bringup.md`).
Glimmerati, which also needs more than 32 MB, does not run: its copy
protection checks the memory card itself. The game list
(`Assets/ngage/plasticbugs.ngage/*.json`) names each `.img`. The page writes
these entries for you. By hand, copy one of the files, name the copy after
the game, and change its `filename` to the game's `.img`.

## Building the core

`./build-local.sh` compiles with Quartus 18.1 in Docker and leaves the SD-card
package in `release/pocket/`. `./build-local.sh map` runs analysis and synthesis
only — a couple of minutes, and it catches what Verilator cannot.

## Checking it

```sh
sim/lint.sh            # every module on its own
sim/run_cpu.sh --bin P # the CPU alone in lockstep with Unicorn (sim/cpu/randprog.py writes P)
sim/run_sys.sh --rom SYM.ROM --drive game.img --seconds 15
                       # CPU, caches, page table and devices in lockstep with Unicorn
sim/run_mem.sh         # the Pocket's memories: every byte in at the loader's rate and back
sim/run_system.sh --rom SYM.ROM --drive game.img --frames 600 --snap 600
                       # the whole machine on the real memory glue, frames to artifacts/system/
sim/run_analogizer.sh  # the Analogizer path, read at the cartridge pins
sim/run_osk.sh         # the on-screen keypad against its generator, pictures to artifacts/osk/
sim/run_lcd.sh         # the LCD's two rasters, upright and turned, pictures to artifacts/lcd/
tools/ngvm/ngvm.py --rom SYM.ROM --drive game.img --frames-to DIR
                       # the reference machine, for frames and sound to compare with
tools/check_mkdrive.py --games DIR --rom SYM.ROM
                       # the card page's builder against mkdrive.py, byte for byte
node tools/check_mkdrive_page.mjs --games DIR --rom SYM.ROM
                       # the card page in headless Chrome: a batch onto a stand-in SD card
```

## Credits

`CREDITS.md` is the full list, and a core should extend it with its own. The
short of it: **Marcus Andrade**
([@boogermann](https://github.com/boogermann),
[OpenGateware](https://github.com/opengateware) /
[Raetro](https://github.com/raetro)) wrote everything between the arcade
hardware and the Pocket — `platform/pocket/` is OpenGateware's
`gateman-pocket` platform, 41 of its 63 files are his, `projects/` came from
his Gateman CLI, `target/pocket/core_top.sv` starts from his template, and
every build here runs in his `raetro/quartus:pocket` Docker image.

Then: the Unicorn Engine and QEMU, which run the reference machine and
check the CPU in every lockstep bench; RndMnkIII, for the Analogizer and its
module; and Analogue, for the APF. The CPU, caches, devices and kernel are
this core's own; `modules/VENDOR.md` lists what is vendored.
