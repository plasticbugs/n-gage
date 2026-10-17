#!/usr/bin/env python3
"""Names for addresses in the firmware image.

Every ROM DLL's export table, read from the image, joined with ordinal ->
name tables (`<lib>.def`, `name @ ordinal NONAME` lines, GCC 2.9x mangled).
The tables are not in this repository: they are recovered from the Series 60
SDK's import libraries, which carry Symbian's copyright.  Point --defs (or
NGAGE_DEFS) at a directory of them.

    tools/ngvm/romsyms.py --rom SYM.ROM <address>...     name addresses
    tools/ngvm/romsyms.py --rom SYM.ROM --dump euser     list a library's exports

As a module: Syms(rom_path, defs_dir).name(addr) -> 'euser!RThread::Create+0x1c'
"""
import argparse, bisect, os, re, struct, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from romfs import RomFs  # noqa: E402

DEFAULT_DEFS = os.environ.get('NGAGE_DEFS', os.path.expanduser('~/work/n-gage-ref/defs/armi-ordinals'))


def demangle1(n):
    """Enough of GCC 2.9x demangling for reading traces: Class::method."""
    m = re.match(r'^(_?[A-Za-z0-9_]*?)__(Q(\d)|(\d+))?(.*)$', n)
    if not m or n.startswith('_GLOBAL_'):
        return n
    meth, rest = m.group(1), n[len(m.group(1)) + 2:]
    if rest.startswith('C'):            # const method: ...__C<class>
        rest = rest[1:]
    parts = []
    if rest.startswith('Q') and rest[1:2].isdigit():
        k, rest = int(rest[1]), rest[2:]
        for _ in range(k):
            mm = re.match(r'(\d+)', rest)
            if not mm:
                return n
            ln = int(mm.group(1)); rest = rest[len(mm.group(1)):]
            parts.append(rest[:ln]); rest = rest[ln:]
    else:
        mm = re.match(r'(\d+)', rest)
        if not mm:
            return meth or n       # a plain function: name__Fargs
        ln = int(mm.group(1)); rest = rest[len(mm.group(1)):]
        parts.append(rest[:ln])
    cls = '::'.join(parts)
    if not meth:                         # constructor
        meth = parts[-1]
    elif meth == '_':
        meth = '~' + parts[-1]
    return cls + '::' + meth


def demangle(names):
    return [demangle1(n) for n in names]


def read_def(path):
    out = {}
    for line in open(path, errors='replace'):
        m = re.match(r'\s*(\S+)\s+@\s+(\d+)', line)
        if m:
            out[int(m.group(2))] = m.group(1)
    return out


class Syms:
    def __init__(self, rom_path, defs_dir=DEFAULT_DEFS):
        self.fs = RomFs(rom_path)
        self.addrs, self.labels = [], []
        self.by_lib = {}
        entries = []
        for path, img in self.fs.images():
            lib = path.rsplit('\\', 1)[-1].rsplit('.', 1)[0].lower()
            exports = self.fs.exports(img)
            names = {}
            dp = os.path.join(defs_dir, lib + '.def')
            if os.path.exists(dp):
                names = read_def(dp)
            self.by_lib[lib] = (img, exports, names)
            for i, a in enumerate(exports):
                if a:
                    entries.append((a & ~1, lib, i + 1, names.get(i + 1)))
            entries.append((img['code'] & ~1, lib, 0, '<code>'))
        raw = sorted(set(e[3] for e in entries if e[3] and e[3] != '<code>'))
        dm = dict(zip(raw, demangle(raw)))
        entries.sort()
        for a, lib, o, n in entries:
            self.addrs.append(a)
            self.labels.append('%s!%s' % (lib, dm.get(n, n) if n else ('ord%d' % o)))

    def name(self, addr):
        i = bisect.bisect_right(self.addrs, addr & ~1) - 1
        if i < 0:
            return '%08x' % addr
        off = (addr & ~1) - self.addrs[i]
        return self.labels[i] + ('+0x%x' % off if off else '')

    def export(self, lib, ordinal):
        img, exports, names = self.by_lib[lib.lower()]
        return exports[ordinal - 1]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--rom', required=True)
    ap.add_argument('--defs', default=DEFAULT_DEFS)
    ap.add_argument('--dump')
    ap.add_argument('addr', nargs='*')
    a = ap.parse_args()
    s = Syms(a.rom, a.defs)
    if a.dump:
        img, exports, names = s.by_lib[a.dump.lower()]
        for i, x in enumerate(exports):
            print('%4d %08x %s' % (i + 1, x, s.name(x)))
    for x in a.addr:
        v = int(x, 16)
        print('%08x %s' % (v, s.name(v)))


if __name__ == '__main__':
    main()
