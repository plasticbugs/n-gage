# Pocket arcade core template

A starting point for building an **arcade core for the Analogue Pocket**
(openFPGA). It is not an empty scaffold: it is a **core that already works,
with no game in it yet**.

Flash it as it stands and the Pocket shows a crosshatch test pattern with
colour bars, a cursor you move with the d-pad, a beep on button 1, and a
bring-up panel reporting the PLL, the memories and the ROM load. The PLL,
SDRAM, SRAM, ROM download, video hand-over, controls and audio path are all
in place and proven before you write a line of game logic — so when something
does break, it is something you wrote.

Around that skeleton sits everything these cores need and usually only grow
after the first painful bring-up: a memory subsystem with the download FIFO
and burst arbiter, a memory bench that pushes a ROM image in at the Pocket's
real loader rate, per-module linting, a diagnostic overlay and first-fault
capture, CI that refuses a build whose timing fails or whose constraints
silently matched nothing, a guard against ever committing ROM data, and
release tooling that ships the bitstream you tested.

`METHODOLOGY.md` is the long form: the method, and what six cores learned
the expensive way. `CLAUDE.md` is the short form, written to steer an LLM
through building a core without re-learning it.

## What is verified, and what is not

| | |
|---|---|
| `sim/lint.sh` | clean, every module on its own |
| `sim/run_mem.sh` | passes — 851,968 words pushed through the download port at the loader's rate and read back through the core's ports, then the SRAM with byte enables |
| the bench has teeth | it **fails** the pre-fix memory module that blacked out a real core's first hardware run |
| Quartus 18.1 full compile | succeeds; no negative slack in any corner; no ignored constraints |
| a stamped copy | lints, passes the bench and synthesises |
| `sim/run_analogizer.sh` | passes — every visible dot of a frame reaches the Analogizer's DAC pins unchanged, the scandoubler doubles the lines at half the period, each SNAC assignment maps as the configurator numbers it |
| **on a Pocket** | **the skeleton itself has not been flashed.** Everything around it is running code from a shipped core; its own raster and test pattern are new. Flash it, then fix this line. |

## What you need

* **Docker** — the build runs in `raetro/quartus:pocket`, Marcus Andrade's
  Quartus Prime 18.1 Lite image. No local Quartus install. On Apple silicon it
  runs under `--platform linux/amd64`, which `build-local.sh` passes for you.
  Give Docker ~8 GB; the fitter is memory-hungry under emulation.
* **Verilator** and a C++ toolchain, for the benches. `brew install verilator`.
* **Python 3**, standard library only.
* **MAME**, if you want to capture reference frames and machine states — which
  you do, because it is the oracle the whole method rests on.
* **An Analogue Pocket**, an SD card, and **your own ROMs.** None are included
  here and none ever will be; the tooling builds an image from a romset you
  already own.
* Optionally **`gh`**, for the release tooling.

## Start a core

On GitHub press **Use this template**, or:

```sh
gh repo create galaga --private --template plasticbugs/pocket-core-template
git clone https://github.com/YOU/galaga.git && cd galaga
```

Then stamp your names through the tree and check it:

```sh
tools/init_core.py galaga "Galaga" YOU     # setname, title, your GitHub handle
tools/gen_qip.sh && sim/lint.sh && sim/run_mem.sh -quick
./build-local.sh map                       # ~2 min: Quartus reads it all
```

`init_core.py` renames every file and rewrites every reference — the RTL
modules, the Quartus project, `Cores/<you>.<setname>`, `Assets/<setname>/`,
the MRA, the docs — then swaps this page for the core's own README stub and
removes the template's notes. The third argument is your GitHub handle; leave
it out and you get `plasticbugs`, which is probably not what you want. It
refuses to run twice, so a mistyped name means starting from a fresh clone.

Cloning locally instead of from GitHub works the same way, but use
`git clone` rather than `cp -R`: the working tree accumulates a Quartus build
database that a copy would drag into the new core.

## Then what

Read **`CLAUDE.md`**. It opens with the order of work — MAME's driver into
`docs/hardware.md` first, then the ROM image, then a reference renderer, then
video RTL against frozen states, then the CPUs, then the whole machine against
the *real* memory glue, then sound, then hardware — and each step ends with
something checkable. It also lists the traps this template already defuses, so
you do not re-arm them.

If you are driving an LLM, point it at `CLAUDE.md` and let it work through
that order. It is written for exactly that.

## You supply the artwork

The core icon (`icon.bin`) ships here and is the same in every core. The
platform image (`pkg/pocket/Platforms/_images/<setname>.bin`) is yours to
make — 521×165, RGB565 big-endian, stored rotated. A core runs perfectly well
without one, so leave it out until you have it.

## Analogizer

Cores built from this template support RndMnkIII's
[Analogizer](https://github.com/RndMnkIII/Analogizer) adapter out of the box:
the board's native 15 kHz video to a CRT, and native controllers through
SNAC, configured in the core's own menu (off by default), with sliders to
centre the picture on the CRT.
Set `USE_ANALOGIZER = 0` in `core_top.sv` to
leave it out. `docs/analogizer.md` covers what to set for your board, and
`docs/analogizer-retrofit.md` is the handoff for adding it to a core that
predates the template's support.

## Licence and credit

The skeleton, benches, tooling and documentation here are yours to use. What
sits underneath them is other people's, and **`CREDITS.md` says whose** —
above all **Marcus Andrade** ([OpenGateware](https://github.com/opengateware) /
[Raetro](https://github.com/raetro)), who wrote essentially everything between
the arcade hardware and the Pocket: `platform/pocket/` (41 of its 63 files),
the Quartus project, the framework half of `core_top.sv`, and the Docker image
every build runs in.

Licensing is per-file and the SPDX headers are authoritative — mostly MIT,
some GPL-3.0-or-later, some CC0-1.0. **Never strip a licence header**, and
extend `CREDITS.md` in your core rather than trimming it. Your own arcade RTL
is yours; be aware that vendoring a GPL CPU core has the consequences you
would expect.
