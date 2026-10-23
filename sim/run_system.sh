#!/bin/sh
# The whole machine through the Pocket's real memory glue: ngage_core against
# ngage_mem, sdram_ctrl and cram_ctrl with behavioural chips beyond the pins,
# and the three slots pushed through the download port at the APF loader's
# rate (sim/tb_system.cpp says how much of each).
#
#   sim/run_system.sh --rom SYM.ROM [--drive game.img] [--frames N]
#                     [--snap a,b,c] [--gap N] [--dl BYTES | --full]
#
# Slower than the lockstep bench with ideal memories (sim/run_sys.sh) -- keep
# both -- but this is the one to run before a flash: it is the only
# simulation in which the clock crossing, the arbiter, the refresh, the
# PSRAM and the download exist at all (METHODOLOGY section 5.16).
# CPU_HZ=n sets the CPU's clock (80 MHz by default, as core_top's PLL);
# OBJ=dir builds elsewhere than sim/obj_system, JOBS=n limits the build.
set -e
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
cd "$here"
verilator --version >/dev/null 2>&1 || { echo "verilator not found" >&2; exit 2; }
HZ=${CPU_HZ:-80000000}
OBJ=${OBJ:-$here/obj_system}
make -s -C "$root"/sw/kernel >/dev/null

. "$here/waivers.sh"
MODS=$(ls "$root"/modules/*/*.v "$root"/modules/*/*.sv 2>/dev/null || true)
PKGS=$(ls "$root"/rtl/*_pkg.sv)
SRCS="$PKGS $(ls "$root"/rtl/*.sv | grep -v '_pkg\.sv$')"

# --no-assert-case: a CPU core may hold a `unique case` that does not match
# while it is still in reset, which Verilator would otherwise stop on.
verilator --cc --exe --build -j "${JOBS:-8}" -O2 \
    -Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
    -Wno-PINCONNECTEMPTY -Wno-TIMESCALEMOD --no-assert-case \
    -Wno-BLKSEQ -Wno-MULTIDRIVEN -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-SYNCASYNCNET \
    "$WAIVERS" --top-module tb_system_top -GCPU_HZ=$HZ -CFLAGS "-O2 -DSYS_HZ=$HZ" -Mdir "$OBJ" \
    $SRCS $MODS \
    "$root"/target/pocket/ngage_mem.sv "$root"/target/pocket/sdram_ctrl.sv \
    "$root"/target/pocket/cram_ctrl.sv "$root"/target/pocket/sram_port.sv \
    sdram_model.sv cram_model.sv sram_model.sv tb_system_top.sv tb_system.cpp > "$OBJ.log" 2>&1 \
    || { tail -40 "$OBJ.log"; exit 1; }

mkdir -p "$root/artifacts/system"
cd "$root"
exec "$OBJ"/Vtb_system_top --kernel "$root/build/kernel/kernel.bin" -o "$root/artifacts/system" "$@"
