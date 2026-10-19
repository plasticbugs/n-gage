# N-Gage — Analogue Pocket core (openFPGA)

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
> your phone's firmware dump (`sym.rom`) and the games' memory cards, built
> with `mkdrive.py` (below).

| part | implementation | verified by |
|---|---|---|
| CPU, ARMv4T + Thumb, 64 MHz (80 once its timing closes) | `rtl/arm_*.sv`: eight stages, branch prediction | lockstep with Unicorn, instruction by instruction (`sim/run_cpu.sh`, `sim/run_sys.sh`); docs/core-design.md 6 |
| caches, page table, devices | `rtl/ngvm_{icache,dcache,mmu,io,sys}.sv` | lockstep with Unicorn behind ideal memories (`sim/run_sys.sh`) |
| the kernel | `sw/kernel` | the reference machine, `tools/ngvm/ngvm.py`; six of seven games reach their menus or play |
| RAM, firmware | Pocket SDRAM (`target/pocket/ngage_mem.sv`) | `sim/run_system.sh`: loaded at the loader's rate, read back byte for byte |
| memory card | Pocket CRAM (`target/pocket/cram_ctrl.sv`) | the same, with the chip's timing checked cycle by cycle (`sim/cram_model.sv`) |
| LCD | `rtl/ngvm_lcd.sv`, scanned from RAM | pixel-identical to the reference on the boot screens (`sim/run_system.sh`, 0 of 36,608 differ), and still: three consecutive frames identical |
| audio | the FIFO in `rtl/ngvm_io.sv`, at the game's rate | sample-for-sample the reference over 9.2 s of Virtua Cop's music, at the FIFO's output (`sim/run_system.sh --wav`) |

## Status

**It has not run on a Pocket yet.** The first build for one meets timing on
every corner with the CPU at 64 MHz; `docs/bringup.md` says what it should
show.

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

What is not implemented:

- Pausing: the game runs on behind the Pocket's menu.
- Saving, sleep, the link port.
- The phone's own keypad layout. The Pocket's buttons map to the keys the
  games use (`sw/kernel/event.c`).

## Analogizer

The core supports RndMnkIII's [Analogizer](https://github.com/RndMnkIII/Analogizer)
adapter: the board's native picture out of the VGA port (RGBS, RGsB, YPbPr,
Y/C, or scandoubled for a VGA monitor), and SNAC controllers.  It is set up
in the core's own menu (Analogizer, Analogizer Video, SNAC Adapter, SNAC
Assignment, and H and V Position to centre the picture on the CRT); with
"Analogizer" off, the default, the core is unchanged.  The Pocket
powers the cartridge slot for this core: take any game cartridge out first.
`docs/analogizer.md` has the modes and the controller assignments.  *(Say
here whether it has been tried on an adapter.)*

## What goes on the card

`Assets/ngage/common/` takes three kinds of file
(`pkg/pocket/Assets/ngage/common/README.txt`):

- `ngvm.bin`, the kernel, from the release;
- `sym.rom`, your phone's firmware;
- one `.img` per game, built from the game's files:

```sh
python3 mkdrive.py --from vcop.zip --out vcop.img
```

`mkdrive.py` needs only Python 3. The game list
(`Assets/ngage/plasticbugs.ngage/*.json`) names each `.img`.

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
tools/ngvm/ngvm.py --rom SYM.ROM --drive game.img --frames-to DIR
                       # the reference machine, for frames and sound to compare with
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
