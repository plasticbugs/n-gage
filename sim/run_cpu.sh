#!/bin/sh
# The CPU alone, in lockstep with Unicorn (sim/cpu/tb_cpu.cpp).
#   sim/run_cpu.sh --rom SYM.ROM [--drive game.img] [--insns N] [--no-uc]
# Builds into sim/obj_cpu; Unicorn comes from the project's .venv (the same
# library tools/ngvm/ngvm.py runs on).  OBJ=dir builds elsewhere, so a
# second build does not replace a binary that is still running.
set -e
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
UC=$("$root"/.venv/bin/python -c 'import unicorn, os; print(os.path.dirname(unicorn.__file__))')
[ -f "$UC/lib/libunicorn.a" ] || { echo "no libunicorn.a under $UC" >&2; exit 2; }
OBJ=${OBJ:-$here/obj_cpu}
make -s -C "$root"/sw/kernel >/dev/null
RTL="$root/rtl/arm_pkg.sv $(ls "$root"/rtl/arm_*.sv | grep -v _pkg.sv)"
verilator --cc --exe --build -O3 -j ${JOBS:-8} --top-module arm_cpu --public-flat-rw \
    -Wno-fatal -Wno-WIDTH -Wno-UNUSEDSIGNAL -Wno-DECLFILENAME \
    -Mdir "$OBJ" -CFLAGS "-O2 -I$UC/include -std=c++17" \
    -LDFLAGS "$UC/lib/libunicorn.a -lpthread -lm" \
    $RTL "$here/cpu/tb_cpu.cpp" >"$OBJ.log" 2>&1 || { tail -40 "$OBJ.log"; exit 1; }
cd "$root"
exec "$OBJ/Varm_cpu" --kernel "$root/build/kernel/kernel.elf" "$@"
