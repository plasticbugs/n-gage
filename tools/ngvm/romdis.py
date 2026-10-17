#!/usr/bin/env python3
"""Disassemble firmware code with names.

    tools/ngvm/romdis.py --rom SYM.ROM <lib> <ordinal> [n]    an export
    tools/ngvm/romdis.py --rom SYM.ROM 0x<addr> [n]           an address (odd = Thumb)
"""
import argparse, os, re, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from romsyms import Syms  # noqa: E402
from capstone import Cs, CS_ARCH_ARM, CS_MODE_ARM, CS_MODE_THUMB

ap = argparse.ArgumentParser()
ap.add_argument('--rom', required=True)
ap.add_argument('what', nargs='+')
a = ap.parse_args()
s = Syms(a.rom)
if a.what[0].startswith('0x'):
    addr = int(a.what[0], 16); n = int(a.what[1]) if len(a.what) > 1 else 60
else:
    addr = s.export(a.what[0], int(a.what[1])); n = int(a.what[2]) if len(a.what) > 2 else 60
thumb = addr & 1
addr &= ~1
md = Cs(CS_ARCH_ARM, CS_MODE_THUMB if thumb else CS_MODE_ARM)
md.skipdata = True                       # literal pools: keep going
code = s.fs.read(addr, n * 4)
print('; %s %s' % (s.name(addr | thumb), 'thumb' if thumb else 'arm'))
count = 0
for ins in md.disasm(code, addr):
    note = ''
    m = re.match(r'#0x([0-9a-f]+)$', ins.op_str)
    if ins.mnemonic in ('bl', 'b', 'blx') and m:
        note = s.name(int(m.group(1), 16))
    elif ins.mnemonic == 'svc':
        note = 'EXEC'
    m2 = re.search(r'\[pc, #(0x[0-9a-f]+|\d+)\]', ins.op_str)
    if m2 and ins.mnemonic.startswith('ldr'):
        pa = ((ins.address + (4 if thumb else 8)) & ~3) + int(m2.group(1), 0)
        v = int.from_bytes(s.fs.read(pa, 4), 'little')
        note = '=%08x %s' % (v, s.name(v) if 0x50000000 <= v < 0x52000000 else '')
    print('%08x  %-8s %-28s %s' % (ins.address, ins.mnemonic, ins.op_str, ('; ' + note) if note else ''))
    count += 1
    if count >= n:
        break
