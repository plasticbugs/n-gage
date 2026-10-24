#!/bin/sh
# The LCD (rtl/ngvm_lcd.sv) on its own: its frame store filled through the
# copy port, and every dot of both rasters it scans from it, upright and
# turned for the Analogizer, against what they must be (sim/tb_lcd.cpp).
#
#   sim/run_lcd.sh [-out DIR] [-pic FILE]
#
# Writes the test card through both rasters to artifacts/lcd.  JOBS=n sets
# the build's parallelism (2 by default).
set -e
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
verilator --version >/dev/null 2>&1 || { echo "verilator not found" >&2; exit 2; }
OBJ=${OBJ:-$here/obj_lcd}
cd "$here"
verilator --cc --exe --build -j "${JOBS:-2}" -O2 \
    -Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
    -Wno-PINCONNECTEMPTY -Wno-TIMESCALEMOD \
    --top-module ngvm_lcd -Mdir "$OBJ" \
    "$root"/rtl/ngvm_lcd.sv tb_lcd.cpp > "$OBJ.log" 2>&1 \
    || { tail -30 "$OBJ.log"; exit 1; }
cd "$root"
exec "$OBJ"/Vngvm_lcd "$@"
