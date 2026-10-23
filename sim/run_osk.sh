#!/bin/sh
# The on-screen keypad (rtl/ngage_osk.sv) on its own, against the panel the
# generator drew (tools/make_osk_panel.py), with the LCD's raster around it.
#
#   sim/run_osk.sh [-out DIR]
#
# Runs from the repository root, because that is where the RTL's $readmemh
# path is relative to -- the same file Quartus reads through the RAM's init
# attribute.  JOBS=n sets the build's parallelism (2 by default).
set -e
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
verilator --version >/dev/null 2>&1 || { echo "verilator not found" >&2; exit 2; }
OBJ=${OBJ:-$here/obj_osk}
cd "$here"
verilator --cc --exe --build -j "${JOBS:-2}" -O2 \
    -Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
    -Wno-PINCONNECTEMPTY -Wno-TIMESCALEMOD \
    --top-module ngage_osk -Mdir "$OBJ" \
    "$root"/rtl/ngage_osk.sv tb_osk.cpp > "$OBJ.log" 2>&1 \
    || { tail -30 "$OBJ.log"; exit 1; }
cd "$root"
mkdir -p artifacts/osk
exec "$OBJ"/Vngage_osk "$@"
