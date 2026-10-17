#!/bin/sh
# The Analogizer path on its own (sim/tb_analogizer.sv): the wrapper and the
# vendored adapter module, driven at this core's raster and clocks, read at
# the cartridge pins as the DAC reads them.  Run it after touching
# target/pocket/pocket_analogizer.sv or the vendored module, and before a
# flash that changes either.  About a minute.
set -e
here=$(cd "$(dirname "$0")" && pwd)
cd "$here"
verilator --version >/dev/null 2>&1 || { echo "verilator not found" >&2; exit 2; }
A=../target/pocket/analogizer
# The menu's Analogizer entries, read from the package's interact.json, so the
# bench drives the menu that ships: one menu_try() per option of every entry
# at 0xF7000000, in file order, and both ends of the position and width sliders.
mkdir -p obj_analogizer
python3 - ../pkg/pocket/Cores/*/interact.json > obj_analogizer/menu.svh <<'PY'
import json, sys
n = 0
print('task automatic menu_entries();')
for v in json.load(open(sys.argv[1]))['interact']['variables']:
    if str(v.get('address', '')).lower() != '0xf7000000':
        continue
    for o in v.get('options', []):
        print(f'    menu_try(32\'h{int(v["mask"], 16):08X}, 32\'h{int(str(o["value"]), 16):08X}, '
              f'"{v["name"]}: {o["name"]}");')
        n += 1
print('endtask')
print(f'localparam int MENU_OPTIONS = {n};')
# the position sliders' range, to try both ends of it
pos = {}
for v in json.load(open(sys.argv[1]))['interact']['variables']:
    a = str(v.get('address', '')).lower()
    if a in ('0xf7000004', '0xf7000008'):
        g = v['graphical']
        pos['H' if a.endswith('4') else 'V'] = (g['min'], g['max'])
    elif a == '0xf700000c':
        g = v['graphical']
        pos['S'] = (g['min'], g['max'])
for k in 'HV':
    lo, hi = pos.get(k, (0, 0))
    print(f'localparam int POS_{k}_MIN = {lo}, POS_{k}_MAX = {hi};')
lo, hi = pos.get('S', (0, 0))
print(f'localparam int SIZE_MIN = {lo}, SIZE_MAX = {hi};')
PY
verilator --binary --timing -j "${JOBS:-8}" -O2 -Wno-fatal -Wno-lint -Wno-style \
    -Wno-PROCASSWIRE -Wno-MULTIDRIVEN -Wno-TIMESCALEMOD \
    --top-module tb_analogizer -Mdir obj_analogizer -Iobj_analogizer \
    ../target/pocket/pocket_analogizer.sv ../platform/pocket/helpers/synch_3.sv \
    $A/*.v $A/*.sv ps2_keyboard_stub.v tb_analogizer.sv > obj_analogizer.log 2>&1 \
    || { tail -40 obj_analogizer.log; exit 1; }
./obj_analogizer/Vtb_analogizer | tee obj_analogizer/run.log
grep -q "^PASS" obj_analogizer/run.log
