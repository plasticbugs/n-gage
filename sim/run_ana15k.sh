#!/bin/sh
# The Analogizer's 15 kHz converter on its own (sim/tb_ana15k.sv): every
# output dot against its source pair, Blend and Sharp, the output raster's
# line, vsync and frame timing, and the ring it reads from -- for the two
# boards it shipped on, Atari System 2 (25 kHz, 384 lines -> 192p) and
# Xenophobe (31 kHz, 480 lines -> 240p).  Each is then run again with DELAY
# just outside the window the first run measured, early (the output
# overtakes the source) and late (the source overwrites a pair before it is
# read): both must fail, or the bench is not seeing the ring.
#
# For a new board, add its line to CONFIGS (the bench's parameters as -G
# flags), run it, and set ana_15k's DELAY near the middle of the window it
# prints.  A few minutes a configuration.
set -e
here=$(cd "$(dirname "$0")" && pwd)
cd "$here"
verilator --version >/dev/null 2>&1 || { echo "verilator not found" >&2; exit 2; }

CONFIGS='
system2 -GHTOTAL=640 -GVTOTAL=416 -GW=512 -GH=384 -GDIV=6 -GDOT=10 -GDOTS=609 -GOLINES=262 -GHS0=524 -GHS1=569 -GVS0=219 -GVS1=222 -GRING=48 -GDELAY=336000
xenophobe -GHTOTAL=635 -GVTOTAL=525 -GW=512 -GH=480 -GDIV=2 -GDOT=4 -GDOTS=636 -GOLINES=262 -GHS0=527 -GHS1=574 -GVS0=243 -GVS1=246 -GRING=2 -GDELAY=1400
'

run() {     # run <name> <flags...>: build and run, the log in obj_<name>.run.log
    n=$1; shift
    verilator --binary --timing -j "${JOBS:-8}" -O2 -Wno-fatal -Wno-lint -Wno-style \
        --top-module tb_ana15k "$@" -Mdir "obj_$n" \
        ../target/pocket/ana_15k.sv tb_ana15k.sv > "obj_$n.log" 2>&1 \
        || { tail -40 "obj_$n.log"; exit 1; }
    "./obj_$n/Vtb_ana15k" > "obj_$n.run.log" 2>&1 || true
}

echo "$CONFIGS" | while read -r name flags; do
    [ -n "$name" ] || continue
    echo "== $name"
    run "ana15k_$name" $flags
    grep -v '^- ' "obj_ana15k_$name.run.log" | sed 's/^/  /'
    grep -q "^PASS" "obj_ana15k_$name.run.log" || { echo "FAILED: $name"; exit 1; }
    # the window the run measured, and a DELAY a line outside it each side
    lo=$(sed -n 's/^window: DELAY from \([0-9]*\) to.*/\1/p' "obj_ana15k_$name.run.log")
    hi=$(sed -n 's/^window: DELAY from [0-9]* to \([0-9]*\) clocks.*/\1/p' "obj_ana15k_$name.run.log")
    line=$(sed -n 's/.*output [0-9]* lines of \([0-9]*\)\/.*/\1/p' "obj_ana15k_$name.run.log")
    base=$(echo "$flags" | sed 's/ -GDELAY=[0-9]*//')
    early=$((lo - line)); [ "$early" -gt 0 ] || early=$((lo / 2))     # a window that opens within a line
    for d in $early $((hi + line)); do
        run "ana15k_m" $base -GDELAY=$d
        if grep -q "^PASS" obj_ana15k_m.run.log; then
            echo "MUTATION NOT CAUGHT: $name at DELAY $d passed"; exit 1
        fi
        echo "  mutation DELAY $d: $(grep -E '^ring:' obj_ana15k_m.run.log)"
    done
    echo "  both mutations caught"
done
echo "PASS: every configuration, and every mutation caught"
