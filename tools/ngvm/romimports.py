#!/usr/bin/env python3
"""What a ROM image calls: words in its code that point into another
image's export table (the `ldr ip,[pc]; ldr pc,[ip]; .word &table[n]`
veneers ROMBUILD writes), turned into names.

    tools/ngvm/romimports.py --rom SYM.ROM <path-substring>...
"""
import argparse, os, struct, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from romsyms import Syms, demangle1  # noqa: E402

ap = argparse.ArgumentParser()
ap.add_argument('--rom', required=True)
ap.add_argument('which', nargs='+')
a = ap.parse_args()
s = Syms(a.rom)
tables = []
for lib, (img, exports, names) in s.by_lib.items():
    if exports:
        tables.append((img['expdir'], img['expdir'] + 4 * len(exports), lib, names))
for path, img in s.fs.images():
    if not any(w.lower() in path.lower() for w in a.which):
        continue
    code = s.fs.read(img['code'], img['codesize'])
    seen = {}
    for i in range(0, len(code) - 3, 4):
        w, = struct.unpack_from('<I', code, i)
        for lo, hi, lib, names in tables:
            if lo <= w < hi and (w - lo) % 4 == 0:
                o = (w - lo) // 4 + 1
                seen[(lib, o)] = names.get(o)
    print('== %s: %d imports' % (path, len(seen)))
    for (lib, o), n in sorted(seen.items()):
        print('  %-10s %4d %s' % (lib, o, demangle1(n) if n else '?'))
