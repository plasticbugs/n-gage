#!/bin/sh
# Pocket memory gate: target/pocket/ngage_mem.sv, the real SDRAM and CRAM
# controllers and the real SRAM port against behavioural chips.  An image goes
# in through the download port the way the Pocket sends it and every byte is
# read back through NGVM's bus port, with the LCD's fetch alongside; then
# masked line writes.  Run it whenever the memory module changes, and before
# the first flash.  JOBS=n limits the build.
#
#   sim/run_mem.sh [-gap N] [-hold N] [-quick]
set -e
here=$(cd "$(dirname "$0")" && pwd)
cd "$here"
verilator --version >/dev/null 2>&1 || { echo "verilator not found" >&2; exit 2; }
verilator --cc --exe --build -j "${JOBS:-8}" -O2 \
    -Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
    -Wno-PINCONNECTEMPTY -Wno-TIMESCALEMOD \
    -Wno-BLKSEQ -Wno-MULTIDRIVEN -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-SYNCASYNCNET \
    --top-module tb_mem_top -Mdir obj_mem \
    ../target/pocket/ngage_mem.sv ../target/pocket/sdram_ctrl.sv ../target/pocket/cram_ctrl.sv \
    ../target/pocket/sram_port.sv sdram_model.sv cram_model.sv sram_model.sv \
    tb_mem_top.sv tb_mem.cpp > obj_mem.log 2>&1 \
    || { tail -40 obj_mem.log; exit 1; }
exec ./obj_mem/Vtb_mem_top "$@"
