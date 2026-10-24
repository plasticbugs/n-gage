#!/bin/sh
# The slots the core reads and writes itself: target/pocket/ngage_slots.sv
# with core_bridge_cmd and data_io, the drive's fetches and the save's
# writes against a Pocket host that varies what its firmware may
# (sim/tb_slots.cpp says what is checked).  Run it whenever ngage_slots, the
# fetch's path into ngage_mem, or core_top's gating of it changes.
#
#   sim/run_slots.sh [-n FETCHES] [-seed N]
set -e
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
cd "$here"
verilator --version >/dev/null 2>&1 || { echo "verilator not found" >&2; exit 2; }
P=$root/platform/pocket
# the platform is Marcus Andrade's, kept as he wrote it: waivers.sh waives it
. "$here/waivers.sh"
verilator --cc --exe --build -j "${JOBS:-8}" -O2 \
    -Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
    -Wno-PINCONNECTEMPTY -Wno-TIMESCALEMOD \
    -Wno-BLKSEQ -Wno-MULTIDRIVEN -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-SYNCASYNCNET \
    "$WAIVERS" --top-module tb_slots_top -Mdir obj_slots \
    "$P"/helpers/synch_3.sv "$P"/interface/data_loader.sv "$P"/support/data_io.sv \
    "$P"/peripherals/core_bridge_cmd.sv dcfifo_model.v mf_datatable_model.v \
    "$root"/target/pocket/ngage_slots.sv tb_apf.sv tb_slots_top.sv tb_slots.cpp > obj_slots.log 2>&1 \
    || { tail -40 obj_slots.log; exit 1; }
exec ./obj_slots/Vtb_slots_top "$@"
