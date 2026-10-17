#!/bin/sh
# The whole machine through the Pocket's real memory glue: mycore_core against
# mycore_mem, sdram_ctrl and sram_port with behavioural chips beyond the pins,
# and the ROM image pushed through the download port at the APF loader's rate.
#
#   sim/run_system.sh [rom] [-frames N] [-gap N] [-snap a,b,c] [-o DIR]
#
# Slower than a bench with ideal memories -- keep both -- but this is the one
# to run before a flash: it is the only simulation in which the arbiter, the
# refresh and the download exist at all (METHODOLOGY section 5.16).
set -e
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
cd "$here"
verilator --version >/dev/null 2>&1 || { echo "verilator not found" >&2; exit 2; }

. "$here/waivers.sh"
MODS=$(ls "$root"/modules/*/*.v "$root"/modules/*/*.sv 2>/dev/null || true)

# --no-assert-case: a CPU core may hold a `unique case` that does not match
# while it is still in reset, which Verilator would otherwise stop on.
verilator --cc --exe --build -j "${JOBS:-8}" -O2 \
    -Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
    -Wno-PINCONNECTEMPTY -Wno-TIMESCALEMOD --no-assert-case \
    -Wno-BLKSEQ -Wno-MULTIDRIVEN -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-SYNCASYNCNET \
    "$WAIVERS" --top-module tb_system_top -Mdir obj_system \
    "$root"/rtl/*.sv $MODS \
    "$root"/target/pocket/mycore_mem.sv "$root"/target/pocket/sdram_ctrl.sv \
    "$root"/target/pocket/sram_port.sv \
    sdram_model.sv sram_model.sv tb_system_top.sv tb_system.cpp > obj_system.log 2>&1 \
    || { tail -40 obj_system.log; exit 1; }

mkdir -p "$root/artifacts/system"
exec ./obj_system/Vtb_system_top "$@" -o "$root/artifacts/system"
