#!/bin/sh
# The CPU side (rtl/ngvm_sys.sv: CPU, caches, page table, devices) in
# lockstep with Unicorn, behind an ideal-latency bus (sim/sys/tb_sys.cpp).
#   sim/run_sys.sh --rom SYM.ROM [--drive game.img] [--seconds S] [--no-uc]
#                  [--lat CYCLES] [--frames-to DIR --frame-every N]
# Builds into sim/obj_sys (OBJ=dir elsewhere); CPU_HZ=n sets the clock the
# devices count time by (80 MHz by default); JOBS=n limits the build.
set -e
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
UC=$("$root"/.venv/bin/python -c 'import unicorn, os; print(os.path.dirname(unicorn.__file__))')
[ -f "$UC/lib/libunicorn.a" ] || { echo "no libunicorn.a under $UC" >&2; exit 2; }
OBJ=${OBJ:-$here/obj_sys}
HZ=${CPU_HZ:-80000000}
make -s -C "$root"/sw/kernel >/dev/null
RTL="$root/rtl/arm_pkg.sv $root/rtl/ngvm_pkg.sv $(ls "$root"/rtl/arm_*.sv | grep -v _pkg.sv) \
     $root/rtl/ngvm_icache.sv $root/rtl/ngvm_dcache.sv $root/rtl/ngvm_mmu.sv $root/rtl/ngvm_io.sv $root/rtl/ngvm_sys.sv"
verilator --cc --exe --build -O3 -j ${JOBS:-8} --top-module ngvm_sys --public-flat-rw -GCPU_HZ=$HZ \
    -Wno-fatal -Wno-WIDTH -Wno-UNUSEDSIGNAL -Wno-DECLFILENAME \
    -Mdir "$OBJ" -CFLAGS "-O2 -I$UC/include -std=c++17 -DSYS_HZ=$HZ" \
    -LDFLAGS "$UC/lib/libunicorn.a -lpthread -lm" \
    $RTL "$here/sys/tb_sys.cpp" >"$OBJ.log" 2>&1 || { tail -40 "$OBJ.log"; exit 1; }
cd "$root"
exec "$OBJ/Vngvm_sys" --kernel "$root/build/kernel/kernel.elf" "$@"
