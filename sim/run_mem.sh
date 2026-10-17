#!/bin/sh
# Pocket memory gate: target/pocket/mycore_mem.sv, the real SDRAM controller and
# the real SRAM port against behavioural chips.  An image goes in through the
# download port the way the Pocket sends it and every region is read back
# through the core's ports.  Run it whenever the memory module changes, and
# before the first flash.
#
#   sim/run_mem.sh [rom] [-gap N] [-hold N] [-quick]
set -e
here=$(cd "$(dirname "$0")" && pwd)
cd "$here"
verilator --version >/dev/null 2>&1 || { echo "verilator not found" >&2; exit 2; }
verilator --cc --exe --build -j "${JOBS:-8}" -O2 \
    -Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
    -Wno-PINCONNECTEMPTY -Wno-TIMESCALEMOD \
    -Wno-BLKSEQ -Wno-MULTIDRIVEN -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-SYNCASYNCNET \
    --top-module tb_mem_top -Mdir obj_mem \
    ../target/pocket/mycore_mem.sv ../target/pocket/sdram_ctrl.sv ../target/pocket/sram_port.sv \
    sdram_model.sv sram_model.sv tb_mem_top.sv tb_mem.cpp > obj_mem.log 2>&1 \
    || { tail -40 obj_mem.log; exit 1; }
exec ./obj_mem/Vtb_mem_top "$@"
