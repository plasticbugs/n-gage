#!/bin/sh
# The save readout (target/pocket/ngage_save.sv) on its own: the Pocket
# reading the whole save slot back over the bridge, against a memory port
# that answers late and the LCD it shares the port with (sim/tb_save.cpp).
#
#   sim/run_save.sh [-gap MIN MAX] [-lat MAX]
#
# SRC=file reads another copy of the module (for a planted fault).  JOBS=n
# sets the build's parallelism (2 by default).
set -e
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
verilator --version >/dev/null 2>&1 || { echo "verilator not found" >&2; exit 2; }
OBJ=${OBJ:-$here/obj_save}
SRC=${SRC:-$root/target/pocket/ngage_save.sv}
cd "$here"
verilator --cc --exe --build -j "${JOBS:-2}" -O2 \
    -Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
    -Wno-PINCONNECTEMPTY -Wno-TIMESCALEMOD \
    --top-module ngage_save -Mdir "$OBJ" \
    "$SRC" tb_save.cpp > "$OBJ.log" 2>&1 \
    || { tail -30 "$OBJ.log"; exit 1; }
cd "$root"
exec "$OBJ"/Vngage_save "$@"
