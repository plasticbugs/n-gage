# Vendored modules

Third-party HDL cores copied into the tree — no submodules, so the build is
self-contained and reproducible. Each keeps its own LICENSE alongside.
`tools/vendor.sh <name>` fetches one from its upstream at a pinned commit,
with its licence; run it with no arguments to see what it knows about, or give
it a url and ref for anything else. `tools/gen_qip.sh` then lists everything
under `modules/` for Quartus.

| module | what it is | upstream | commit | licence |
|---|---|---|---|---|
| *(none yet)* | | | | |
| `target/pocket/analogizer/` | RndMnkIII's Analogizer adapter module (`openFPGA_Pocket_Analogizer` 1.4) and the 14 files it instantiates, verbatim but for one marked local change (below); `analogizer.qip` is ours | https://github.com/RndMnkIII/MiraxPocket, `src/fpga/analogizer/` | 9dfdd2b9bec79fe5ea10e154a0613a0c9d4fe37f | GPL-3.0-or-later (the host core's); `hq2x.sv`, `scandoubler_2.v`, `yc_out_legacy.sv` carry their own GPL headers |

**Local change (not upstream).** `openFPGA_Pocket_Analogizer.v` gains two
parameters, `USE_YC` and `USE_SD`, default 1.  0 leaves out the Y/C encoder
(`yc_out_legacy`), or the scandoubler (`scandoubler_2`, with `Hq2x`) and the
VGA scanlines (`scanlines_analogizer`), with their outputs tied to the
pass-through values and their video modes mapped to RGBS.  Why: S.T.U.N.
Runner fills 90 % of the FPGA, and with the whole module it needed 102 %.
The change adds the parameters, three generate blocks and one selector
line, each marked `LOCAL`, and a note under RndMnkIII's header, which is
otherwise untouched; with both parameters at 1 the module is the upstream
1.4 exactly.  `pocket_analogizer.sv` forwards both (default 1).

The Analogizer module lives under `target/pocket/` rather than `modules/`
because it is the Pocket's cartridge port, not the machine, and so that
`tools/gen_qip.sh` and the per-module lint do not sweep it in: `core.qip`
includes its own `analogizer.qip`, and `sim/lint.sh` lints it behind
`target/pocket/pocket_analogizer.sv` with a stand-in for its one VHDL file
(`sim/ps2_keyboard_stub.v`).  The copy is from MiraxPocket, RndMnkIII's
newest arcade core (2026-09); his main Analogizer repository's
`analogizer/` folder is the older 1.2 and has no settings-file support.
Left out: `scandoubler.v`, `scanlines.v`, `yc_out.sv`, `psPAD_top.v`,
`psx_control.v`, `csync.v`, `sync_fix.v` (also defined inside the top file),
`two_button_press_detector.v`, `uart_tx.v` and `sine_lut.mem` -- nothing
instantiates them.  In this copy the SNAC module declares PS/2 mouse outputs
that it does not yet drive; the wrapper leaves them unconnected.

For each module record what it is, its upstream repository and the exact
commit, its licence, and anything it needs that is not obvious — jt12's
`hdl/` has to be taken whole, for instance, because `jt12_top` instantiates
its ADPCM files outside a generate guard, so they must exist even when ADPCM
is disabled.

Written here rather than vendored: list the custom chips reimplemented from
MAME's device models, and where their behaviour is documented.

To update one: re-copy from upstream at the new commit and record it here.
