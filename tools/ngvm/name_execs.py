#!/usr/bin/env python3
"""Name every EKA1 exec call EUser makes, by the exported functions that call
each `svc` stub, and join EKA2L1's semantics where it has them.

    tools/ngvm/name_execs.py --rom SYM.ROM [--eka2l1 eka1_exec.csv] > docs/eka1_exec.md
"""
import argparse, csv, os, re, struct, subprocess, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from romsyms import Syms  # noqa: E402

ap = argparse.ArgumentParser()
ap.add_argument('--rom', required=True)
ap.add_argument('--eka2l1', default=os.path.expanduser('~/work/n-gage-ref/eka1_exec.csv'))
a = ap.parse_args()
s = Syms(a.rom)
img, exports, names = s.by_lib['euser']
code = s.fs.read(img['code'], img['codesize'])
base = img['code']
n = len(code) // 4
words = struct.unpack('<%dI' % n, code[:n * 4])
stubs = {}
for i, w in enumerate(words):
    if (w & 0xFF000000) == 0xEF000000:
        stubs[base + 4 * i] = w & 0xFFFFFF
callers = {k: set() for k in stubs}
# ARM BL
for i, w in enumerate(words):
    if (w & 0x0E000000) == 0x0A000000 and (w >> 28) != 0xF:
        off = w & 0xFFFFFF
        if off & 0x800000: off -= 0x1000000
        t = base + 4 * i + 8 + off * 4
        if t in callers: callers[t].add(base + 4 * i)
# Thumb BL pairs (EUser is ARM, but scan anyway) and BX-veneers are ignored
eka = {}
if os.path.exists(a.eka2l1):
    for row in csv.DictReader(open(a.eka2l1)):
        eka[int(row['svc'], 16)] = row
print('| svc | stub | called from | EKA2L1 |')
print('|---|---|---|---|')
for addr in sorted(stubs, key=lambda x: stubs[x] & 0x3FFFFF):
    num = stubs[addr]
    who = sorted(set(re.sub(r'\+0x[0-9a-f]+$', '', s.name(c)).replace('euser!', '') for c in callers[addr]))
    e = eka.get(num)
    print('| %06x | %08x | %s | %s |' % (num, addr, ', '.join(who[:4]) + (' ...' if len(who) > 4 else ''),
                                        (e['eka2l1_handler'] if e else '')))
